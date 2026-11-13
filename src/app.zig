const std = @import("std");
const vt = @import("ghostty-vt");
const control = @import("control.zig");
const layout = @import("layout.zig");
const keys = @import("keys.zig");
const menu = @import("menu.zig");
const color = @import("color.zig");
const Theme = @import("theme.zig").Theme;
const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;

pub const rail_button = "≡ menu";
pub const rail_new = "+ new";
const history_lines = 5000;
/// Wheel and swipe steps that move between windows or sessions are taken this far apart.
const nav_gap_ms = 150;

/// Two clicks on a name this close together ask to rename it.
const double_click_ms = 400;
/// A window with output this recent is still at it.
const busy_ms = 3000;

/// tmux has no order of sessions to change, so arena keeps each one's place in an option on it.
const session_format = "#{{session_id}} #{{?@arena_order,#{{@arena_order}},-}} #{{session_name}}";
const pane_format = "#{{session_id}} #{{window_id}} #{{pane_id}} #{{window_width}} #{{window_height}} " ++
    "#{{pane_left}} #{{pane_top}} #{{pane_width}} #{{pane_height}} #{{pane_active}} #{{window_active}} " ++
    "#{{window_activity}} #{{window_bell_flag}} #{{?@arena_width,#{{@arena_width}},0}} #{{window_name}}";

/// The least and the most of the view a window's column is given, in hundredths, and how much
/// one press of narrower or wider changes it.
const min_share = 20;
const max_share = 100;
const share_step = 10;

/// What a window not being looked at has to say: it is putting out text, it has put some out
/// and stopped, or it rang the bell. In rising order of how much it wants looking at.
pub const Mark = enum { none, busy, unseen, bell };
const mode_flags = "#{{alternate_on}} #{{?cursor_flag,0,1}} #{{mouse_standard_flag}} #{{mouse_button_flag}} #{{mouse_all_flag}} #{{mouse_sgr_flag}}";
/// What to feed a pane's terminal for each of `mode_flags` that is 1, in the same order.
const mode_sets = [_][]const u8{ "\x1b[?1049h", "\x1b[?25l", "\x1b[?1000h", "\x1b[?1002h", "\x1b[?1003h", "\x1b[?1006h" };

pub const Pane = struct {
    id: u32,
    /// Where the pane sits in its window, in cells.
    x: u16 = 0,
    y: u16 = 0,
    term: vt.Terminal,
    stream: vt.TerminalStream,
    render: vt.RenderState = .empty,
    /// A pane's output is dropped until its captured screen has been fed in: the capture holds
    /// it. `wanted` again when arena comes back to a session, whose output it was not sent.
    seed: enum { wanted, asked, done } = .wanted,
    /// What the pane's program had set when last asked, by `mode_sets`.
    modes: [mode_sets.len]bool = @splat(false),

    fn create(app: *App, id: u32, cols: u16, rows: u16) !*Pane {
        const pane = try app.gpa.create(Pane);
        errdefer app.gpa.destroy(pane);
        pane.* = .{
            .id = id,
            .term = try .init(app.io, app.gpa, .{ .cols = @max(1, cols), .rows = @max(1, rows), .max_scrollback_bytes = 8 << 20 }),
            .stream = undefined,
        };
        pane.stream = pane.term.vtStream();
        return pane;
    }

    fn destroy(pane: *Pane, gpa: Allocator) void {
        pane.render.deinit(gpa);
        pane.stream.deinit();
        pane.term.deinit(gpa);
        gpa.destroy(pane);
    }

    /// Feeds the pane's program's output to its terminal, as tmux would take it. Where a
    /// character has just filled the last column, tmux holds the cursor one past it, so a step
    /// back lands on the last column; this terminal, like xterm, steps to the one before.
    /// Programs under tmux draw by tmux's rule.
    fn feed(pane: *Pane, bytes: []const u8) void {
        var rest = bytes;
        while (std.mem.indexOfAny(u8, rest, "\x08\x1b")) |at| {
            pane.stream.nextSlice(rest[0..at]);
            rest = rest[at..];
            const cursor = &pane.term.screens.active.cursor;
            const back = backBy(rest);
            if (!cursor.pending_wrap or back.len == 0) {
                pane.stream.nextSlice(rest[0..1]);
                rest = rest[1..];
                continue;
            }
            cursor.pending_wrap = false;
            if (back.cells > 1) {
                var buf: [16]u8 = undefined;
                pane.stream.nextSlice(std.fmt.bufPrint(&buf, "\x1b[{d}D", .{back.cells - 1}) catch unreachable);
            }
            rest = rest[back.len..];
        }
        pane.stream.nextSlice(rest);
    }

    /// The step back `bytes` starts with, a backspace or `CSI n D`: its length, 0 when it is
    /// neither, and how many cells it goes.
    fn backBy(bytes: []const u8) struct { len: usize, cells: u16 } {
        if (bytes[0] == 0x08) return .{ .len = 1, .cells = 1 };
        if (!std.mem.startsWith(u8, bytes, "\x1b[")) return .{ .len = 0, .cells = 0 };
        var end: usize = 2;
        while (end < bytes.len and std.ascii.isDigit(bytes[end])) end += 1;
        if (end == bytes.len or bytes[end] != 'D') return .{ .len = 0, .cells = 0 };
        const cells = if (end == 2) 1 else std.fmt.parseInt(u16, bytes[2..end], 10) catch return .{ .len = 0, .cells = 0 };
        return .{ .len = end + 1, .cells = @max(1, cells) };
    }

    fn contains(pane: *const Pane, x: usize, y: usize) bool {
        return x >= pane.x and x < pane.x + pane.term.cols and y >= pane.y and y < pane.y + pane.term.rows;
    }
};

pub const Window = struct {
    id: u32,
    name: []u8 = &.{},
    panes: std.ArrayList(*Pane) = .empty,
    active: usize = 0,
    /// The size tmux has the window at, which is arena's column unless another client holds it.
    w: u16 = 0,
    h: u16 = 0,
    /// The size arena last asked tmux for, so one tmux will not give is asked for once.
    asked_w: u16 = 0,
    asked_h: u16 = 0,
    /// The hundredths of the view its column is given, kept in tmux as @arena_width; 0 until
    /// it is made narrower or wider, when the column has the width every such one has.
    share: u8 = 0,
    /// When tmux last saw output in the window, and when arena last had it in view, both in
    /// seconds of the wall clock.
    activity: i64 = 0,
    seen: i64 = 0,
    /// When, on arena's clock, `activity` was last found to have moved.
    changed_at: i64 = 0,
    bell: bool = false,
    listed: bool = false,

    pub fn activePane(win: *const Window) ?*Pane {
        return if (win.active < win.panes.items.len) win.panes.items[win.active] else null;
    }

    pub fn paneAt(win: *const Window, x: usize, y: usize) ?*Pane {
        for (win.panes.items) |pane| if (pane.contains(x, y)) return pane;
        return null;
    }

    fn destroy(win: *Window, gpa: Allocator) void {
        gpa.free(win.name);
        win.panes.deinit(gpa);
        gpa.destroy(win);
    }
};

pub const Session = struct {
    id: u32,
    name: []u8 = &.{},
    /// Its place on the rail, as arena last left it in tmux; none for a session not yet moved.
    order: u32 = std.math.maxInt(u32),
    wins: std.ArrayList(*Window) = .empty,
    focus: usize = 0,
    scroll: i32 = 0,
    /// False until its strip has been put in place once, and again after a resize.
    placed: bool = false,
    /// Columns take the whole view, with no neighbour peeking.
    full: bool = false,

    pub fn focused(s: *const Session) ?*Window {
        return if (s.focus < s.wins.items.len) s.wins.items[s.focus] else null;
    }
};

const Pending = union(enum) {
    ignore,
    sessions,
    panes,
    modes: u32,
    capture: u32,
    cursor: u32,
};

pub const App = struct {
    gpa: Allocator,
    io: std.Io,
    tmux_in: std.Io.File,
    sessions: std.ArrayList(*Session) = .empty,
    current: ?u32 = null,
    /// The session being left while its strip slides out.
    prev: ?u32 = null,
    /// The way the next session change goes, when arena asked for it: 1 down, -1 up.
    slide: i32 = 0,
    /// Rows the current strip still has to travel to its place.
    yoff: i32 = 0,
    menu: ?menu.Menu = null,
    /// A name being typed, over everything else.
    prompt: ?menu.Prompt = null,
    /// The window picked in the overview, while it is open in place of the strip.
    overview: ?Spot = null,
    /// Set when the session's current window changed in tmux, so focus goes to it when listed.
    follow_active: bool = false,
    palette: color.Palette = .{},
    theme: ?Theme = null,
    /// Off under ARENA_REDUCED_MOTION: the border stands still and strips jump.
    motion: bool = true,
    phase: f32 = 0,
    term_w: u16 = 80,
    /// The strip's width: the terminal's, less the session rail and its gap.
    view_w: u16 = 80,
    view_h: u16 = 24,
    pending: std.ArrayList(Pending) = .empty,
    in_block: bool = false,
    block: std.ArrayList(u8) = .empty,
    want_list: bool = true,
    listing: bool = false,
    listed: bool = false,
    dirty: bool = true,
    quit: bool = false,
    /// tmux ended the client, as it does when the session it was on ends.
    ended: bool = false,
    /// Milliseconds on a clock that only goes forward, set each turn of the loop.
    now: i64 = 0,
    /// What the held left button is moving: the line after a pane, to resize it, a window by
    /// its title, along the strip, or a session by its name, along the rail.
    drag: union(enum) {
        none,
        divider: struct { pane: u32, upright: bool, asked: i32 = -1 },
        /// A column by one of its sides, to make its window narrower or wider, from where the
        /// pointer took hold and the width the column had then.
        edge: struct { win: u32, right: bool, x: u16, w: u16 },
        title: u32,
        /// A window by its picture in the overview.
        thumb: u32,
        session: u32,
        /// Text being selected in a pane, from the cell of it the button went down on.
        select: struct { pane: u32, x: u16, y: u16 },
    } = .none,
    /// The session the open menu asks about closing.
    doomed: u32 = 0,
    /// The pointer's shape, as the terminal was last told.
    shape: []const u8 = "default",
    /// Where the mouse last was.
    pointer: struct { x: u16 = 0, y: u16 = 0 } = .{},
    /// Bytes for the terminal arena runs in, written out after the next frame.
    out: std.ArrayList(u8) = .empty,
    /// The name last clicked, a window's or a session's, and when.
    clicked: ?Name = null,
    clicked_at: i64 = 0,
    /// Seconds of the wall clock, as tmux stamps a window's activity.
    wall: i64 = 0,
    nav_at: i64 = 0,
    /// Until then output is arena's own doing, windows redrawing at a new size, and marks nothing.
    hush_until: i64 = 0,

    pub fn deinit(app: *App) void {
        for (app.sessions.items) |s| app.destroySession(s);
        app.sessions.deinit(app.gpa);
        app.pending.deinit(app.gpa);
        app.block.deinit(app.gpa);
        app.out.deinit(app.gpa);
    }

    fn destroySession(app: *App, s: *Session) void {
        for (s.wins.items) |win| {
            for (win.panes.items) |pane| pane.destroy(app.gpa);
            win.destroy(app.gpa);
        }
        s.wins.deinit(app.gpa);
        app.gpa.free(s.name);
        app.gpa.destroy(s);
    }

    pub fn send(app: *App, kind: Pending, comptime fmt: []const u8, args: anytype) !void {
        var buf: [256]u8 = undefined;
        var w = app.tmux_in.writerStreaming(app.io, &buf);
        try w.interface.print(fmt ++ "\n", args);
        try w.interface.flush();
        try app.pending.append(app.gpa, kind);
    }

    pub fn sessionById(app: *const App, id: ?u32) ?*Session {
        for (app.sessions.items) |s| if (s.id == id) return s;
        return null;
    }

    pub fn cur(app: *const App) ?*Session {
        return app.sessionById(app.current);
    }

    fn sessionIndex(app: *const App, id: ?u32) ?usize {
        for (app.sessions.items, 0..) |s, i| if (s.id == id) return i;
        return null;
    }

    fn paneById(app: *App, id: u32) ?*Pane {
        for (app.sessions.items) |s| for (s.wins.items) |win| for (win.panes.items) |pane| {
            if (pane.id == id) return pane;
        };
        return null;
    }

    pub fn colW(app: *const App, s: *const Session, win: *const Window) u16 {
        if (s.full) return app.view_w;
        if (win.share == 0) return layout.colWidth(app.view_w, s.wins.items.len);
        return layout.shareWidth(app.view_w, win.share);
    }

    /// The left edge of column `index` on the strip; of one past the last, where another would go.
    pub fn colX(app: *const App, s: *const Session, index: usize) i32 {
        var x: i32 = 0;
        for (s.wins.items[0..index]) |win| x += @as(i32, app.colW(s, win)) + layout.gap;
        return x;
    }

    pub const ColHit = struct { index: usize, cx: usize };

    /// The column at cell `at` of the strip, and which cell of it; none between two or past the end.
    pub fn colAt(app: *const App, s: *const Session, at: i32) ?ColHit {
        var x: i32 = 0;
        for (s.wins.items, 0..) |win, index| {
            const w = app.colW(s, win);
            if (at >= x and at < x + w) return .{ .index = index, .cx = @intCast(at - x) };
            x += @as(i32, w) + layout.gap;
        }
        return null;
    }

    pub fn target(app: *const App, s: *const Session) i32 {
        const win = s.focused() orelse return 0;
        const strip = app.colX(s, s.wins.items.len) - layout.gap;
        return layout.scrollTarget(app.view_w, app.colX(s, s.focus), app.colW(s, win), strip);
    }

    /// Gives a window's column `share` hundredths of the view, within what is worth having,
    /// and has tmux keep it.
    fn setShare(app: *App, s: *Session, win: *Window, share: i32) !void {
        const to: u8 = @intCast(std.math.clamp(share, min_share, max_share));
        if (to == win.share and !s.full) return;
        s.full = false;
        win.share = to;
        try app.send(.ignore, "set-option -w -t @{d} @arena_width {d}", .{ win.id, to });
        app.hush_until = app.now + busy_ms;
        app.want_list = true;
        app.dirty = true;
    }

    /// The hundredths of the view a column `w` cells wide takes, to the nearest.
    fn shareOf(app: *const App, w: i32) i32 {
        return @divTrunc(w * 100 + app.view_w / 2, @max(1, app.view_w));
    }

    /// Makes the focused window's column narrower or wider by `delta` hundredths of the view.
    fn widenBy(app: *App, delta: i32) !void {
        const s = app.cur() orelse return;
        const win = s.focused() orelse return;
        const from = if (win.share != 0 and !s.full) win.share else app.shareOf(app.colW(s, win));
        try app.setShare(s, win, from + delta);
    }

    /// What `win` of `s` has to say; nothing when it is the window in view.
    pub fn mark(app: *const App, s: *const Session, win: *const Window) Mark {
        if (s.id == app.current and s.focused() == win) return .none;
        if (win.bell) return .bell;
        if (win.activity <= win.seen) return .none;
        return if (app.now - win.changed_at < busy_ms) .busy else .unseen;
    }

    /// The most pressing mark among a session's windows.
    pub fn sessionMark(app: *const App, s: *const Session) Mark {
        var most: Mark = .none;
        for (s.wins.items) |win| {
            const found = app.mark(s, win);
            if (@intFromEnum(found) > @intFromEnum(most)) most = found;
        }
        return most;
    }

    /// The window in view has been seen up to now.
    fn see(app: *App) void {
        if (app.cur()) |s| if (s.focused()) |win| {
            win.seen = app.wall;
        };
    }

    fn toggleFull(app: *App) void {
        const s = app.cur() orelse return;
        s.full = !s.full;
        app.hush_until = app.now + busy_ms;
        app.want_list = true;
        app.dirty = true;
    }

    /// The session rail's width: its border, the longest name, to 14 cells, and each session's
    /// count of windows. A terminal too narrow for it has none.
    pub fn railW(app: *const App) u16 {
        if (app.term_w < 48 or app.sessions.items.len == 0) return 0;
        var longest: usize = 1;
        for (app.sessions.items) |s| longest = @max(longest, std.unicode.utf8CountCodepoints(s.name) catch s.name.len);
        return @as(u16, @max(7, @min(longest, 14))) + 7;
    }

    pub fn fit(app: *App) void {
        const rail = app.railW();
        app.view_w = app.term_w - if (rail > 0) rail + 1 else 0;
    }

    /// A new terminal size: every strip is put in place again once tmux has been told.
    pub fn resized(app: *App, cols: u16, rows: u16) !void {
        app.term_w = cols;
        app.view_h = rows;
        app.fit();
        try app.send(.ignore, "refresh-client -C {d}x{d}", .{ cols, rows });
        for (app.sessions.items) |s| s.placed = false;
        app.hush_until = app.now + busy_ms;
        app.want_list = true;
    }

    pub fn requestList(app: *App) !void {
        app.want_list = false;
        app.listing = true;
        try app.send(.sessions, "list-sessions -F '" ++ session_format ++ "'", .{});
        try app.send(.panes, "list-panes -a -F '" ++ pane_format ++ "'", .{});
    }

    pub fn onLine(app: *App, line: []u8) !void {
        switch (control.parse(line, app.in_block)) {
            .begin => {
                app.in_block = true;
                app.block.clearRetainingCapacity();
            },
            .body => |body| {
                try app.block.appendSlice(app.gpa, body);
                try app.block.append(app.gpa, '\n');
            },
            .end => {
                app.in_block = false;
                const kind: Pending = if (app.pending.items.len > 0) app.pending.orderedRemove(0) else .ignore;
                try app.onReply(kind, app.block.items);
            },
            .output => |out| {
                const pane = app.paneById(out.pane) orelse return;
                if (pane.seed != .done) return;
                pane.feed(control.unescape(@constCast(out.data)));
                app.dirty = true;
            },
            .changed => app.want_list = true,
            .window_selected => |session| {
                if (session == app.current) app.follow_active = true;
                app.want_list = true;
            },
            .session_changed => |id| app.onSessionChanged(id),
            .exit => {
                app.ended = true;
                app.quit = true;
            },
            .other => {},
        }
    }

    /// The strip of the session left slides out as the new one slides in. The new session's
    /// panes are captured afresh: tmux sent arena none of their output while it was elsewhere.
    fn onSessionChanged(app: *App, id: u32) void {
        const from = app.current;
        app.current = id;
        if (from != null and from != id and app.motion) {
            const way: i32 = if (app.slide != 0) app.slide else blk: {
                const a = app.sessionIndex(from) orelse 0;
                const b = app.sessionIndex(id) orelse 0;
                break :blk if (b >= a) 1 else -1;
            };
            app.prev = from;
            app.yoff = way * @as(i32, app.view_h);
        }
        app.slide = 0;
        if (app.sessionById(id)) |s| for (s.wins.items) |win| for (win.panes.items) |pane| {
            pane.seed = .wanted;
        };
        app.want_list = true;
        app.dirty = true;
    }

    fn onReply(app: *App, kind: Pending, body: []const u8) !void {
        switch (kind) {
            .ignore => {},
            .sessions => try app.onSessions(body),
            .panes => try app.onPanes(body),
            // What the program set before arena was watching, which no capture shows: without
            // these a running editor would get no mouse and draw outside the alternate screen.
            .modes => |id| {
                const pane = app.paneById(id) orelse return;
                var flags = std.mem.tokenizeAny(u8, body, " \n");
                for (&pane.modes) |*set| set.* = std.mem.eql(u8, flags.next() orelse "0", "1");
            },
            .capture => |id| {
                const pane = app.paneById(id) orelse return;
                pane.stream.nextSlice("\x1bc");
                for (pane.modes, mode_sets) |set, sequence| if (set) pane.stream.nextSlice(sequence);
                // Every row is kept, blank ones too: the last screenful has to land as the screen.
                var lines = std.mem.splitScalar(u8, body[0..body.len -| 1], '\n');
                var first = true;
                while (lines.next()) |line| {
                    if (!first) pane.stream.nextSlice("\r\n");
                    first = false;
                    pane.stream.nextSlice(line);
                }
                pane.stream.nextSlice("\x1b[0m");
                pane.seed = .done;
                app.dirty = true;
            },
            .cursor => |id| {
                const pane = app.paneById(id) orelse return;
                var it = std.mem.tokenizeAny(u8, body, " \n");
                const x = std.fmt.parseInt(u16, it.next() orelse return, 10) catch return;
                const y = std.fmt.parseInt(u16, it.next() orelse return, 10) catch return;
                var buf: [32]u8 = undefined;
                pane.stream.nextSlice(try std.fmt.bufPrint(&buf, "\x1b[{d};{d}H", .{ y + 1, x + 1 }));
                app.dirty = true;
            },
        }
    }

    fn onSessions(app: *App, body: []const u8) !void {
        var old = app.sessions;
        defer old.deinit(app.gpa);
        app.sessions = .empty;
        var lines = std.mem.tokenizeScalar(u8, body, '\n');
        while (lines.next()) |line| {
            const space = std.mem.indexOfScalar(u8, line, ' ') orelse continue;
            const id = std.fmt.parseInt(u32, line[1..space], 10) catch continue;
            const rest = line[space + 1 ..];
            const name = std.mem.indexOfScalar(u8, rest, ' ') orelse continue;
            // A place is read once: after that arena's own is the newer, and a list asked for
            // before a move would put the old one back.
            const s = for (old.items, 0..) |known, i| {
                if (known.id == id) break old.swapRemove(i);
            } else blk: {
                const made = try app.gpa.create(Session);
                made.* = .{ .id = id, .order = std.fmt.parseInt(u32, rest[0..name], 10) catch std.math.maxInt(u32) };
                break :blk made;
            };
            app.gpa.free(s.name);
            s.name = try app.gpa.dupe(u8, rest[name + 1 ..]);
            try app.sessions.append(app.gpa, s);
        }
        for (old.items) |s| app.destroySession(s);
        std.sort.insertion(*Session, app.sessions.items, {}, struct {
            fn before(_: void, a: *Session, b: *Session) bool {
                return a.order < b.order;
            }
        }.before);
        app.fit();
    }

    /// Rebuilds every session's windows and panes from tmux's list, keeping the terminals of the
    /// panes that are still there.
    fn onPanes(app: *App, body: []const u8) !void {
        app.listing = false;
        var old_wins: std.ArrayList(*Window) = .empty;
        defer old_wins.deinit(app.gpa);
        var old_panes: std.ArrayList(*Pane) = .empty;
        defer old_panes.deinit(app.gpa);
        var focus_ids: std.ArrayList(?u32) = .empty;
        defer focus_ids.deinit(app.gpa);
        for (app.sessions.items) |s| {
            try focus_ids.append(app.gpa, if (s.focused()) |win| win.id else null);
            for (s.wins.items) |win| {
                try old_wins.append(app.gpa, win);
                try old_panes.appendSlice(app.gpa, win.panes.items);
                win.panes.clearRetainingCapacity();
            }
            s.wins.clearRetainingCapacity();
            s.focus = 0;
        }

        var lines = std.mem.tokenizeScalar(u8, body, '\n');
        while (lines.next()) |line| {
            var it = std.mem.tokenizeScalar(u8, line, ' ');
            var n: [14]u32 = undefined;
            for (&n, 0..) |*field, i| {
                const token = it.next() orelse break;
                field.* = std.fmt.parseInt(u32, token[@intFromBool(i < 3)..], 10) catch break;
            } else {
                const s = app.sessionById(n[0]) orelse continue;
                const last = s.wins.getLastOrNull();
                const win = if (last != null and last.?.id == n[1]) last.? else blk: {
                    const win = for (old_wins.items, 0..) |known, i| {
                        if (known.id == n[1]) break old_wins.swapRemove(i);
                    } else made: {
                        const made = try app.gpa.create(Window);
                        made.* = .{ .id = n[1] };
                        break :made made;
                    };
                    app.gpa.free(win.name);
                    win.name = try app.gpa.dupe(u8, it.rest());
                    win.w = @intCast(n[3]);
                    win.h = @intCast(n[4]);
                    if (win.listed and n[11] != win.activity) win.changed_at = app.now;
                    win.activity = n[11];
                    if (!win.listed or app.now < app.hush_until) win.seen = win.activity;
                    win.bell = n[12] == 1;
                    // Read once: after that arena's own is the newer, and a list asked for
                    // before a change would put the old one back.
                    if (!win.listed) win.share = @intCast(@min(n[13], max_share));
                    win.listed = true;
                    if (n[10] == 1) s.focus = s.wins.items.len;
                    try s.wins.append(app.gpa, win);
                    break :blk win;
                };
                const pane = for (old_panes.items, 0..) |known, i| {
                    if (known.id == n[2]) break old_panes.swapRemove(i);
                } else try Pane.create(app, n[2], @intCast(n[7]), @intCast(n[8]));
                pane.x = @intCast(n[5]);
                pane.y = @intCast(n[6]);
                // tmux wraps a pane's history again at its new width; the copy here, fed in as
                // rows, cannot, so it is taken afresh.
                if (pane.term.cols != n[7] or pane.term.rows != n[8]) {
                    try pane.term.resize(app.gpa, .{ .cols = @intCast(@max(1, n[7])), .rows = @intCast(@max(1, n[8])) });
                    pane.seed = .wanted;
                }
                if (n[9] == 1) win.active = win.panes.items.len;
                try win.panes.append(app.gpa, pane);
            }
        }
        for (old_panes.items) |pane| pane.destroy(app.gpa);
        for (old_wins.items) |win| win.destroy(app.gpa);

        for (app.sessions.items, 0..) |s, i| {
            const follow = app.follow_active and s.id == app.current;
            if (!follow and i < focus_ids.items.len) if (focus_ids.items[i]) |id| for (s.wins.items, 0..) |win, at| {
                if (win.id == id) s.focus = at;
            };
            if (!s.placed) s.scroll = app.target(s);
            s.placed = true;
        }
        app.follow_active = false;
        app.see();
        try app.settle();
        if (app.cur()) |s| app.listed = app.listed or s.wins.items.len > 0;
        app.dirty = true;
    }

    /// Asks tmux to size the current session's windows to their columns, and for the screen of
    /// every pane not yet captured. A window just asked to change size is captured after tmux
    /// reports the new layout, at the size it will be drawn.
    fn settle(app: *App) !void {
        for (app.sessions.items) |s| {
            const rows = @max(1, app.view_h -| 2);
            for (s.wins.items) |win| {
                const cols = @max(1, app.colW(s, win) -| 2);
                const fits = win.w == cols and win.h == rows;
                const asked = win.asked_w == cols and win.asked_h == rows;
                if (s.id == app.current and !fits and !asked) {
                    win.asked_w = cols;
                    win.asked_h = rows;
                    app.hush_until = app.now + busy_ms;
                    try app.send(.ignore, "refresh-client -C @{d}:{d}x{d}", .{ win.id, cols, rows });
                    continue;
                }
                for (win.panes.items) |pane| {
                    if (pane.seed != .wanted) continue;
                    pane.seed = .asked;
                    try app.send(.{ .modes = pane.id }, "display-message -p -t %{d} '" ++ mode_flags ++ "'", .{pane.id});
                    try app.send(.{ .capture = pane.id }, "capture-pane -p -e -S -{d} -t %{d}", .{ history_lines, pane.id });
                    try app.send(.{ .cursor = pane.id }, "display-message -p -t %{d} '#{{cursor_x}} #{{cursor_y}}'", .{pane.id});
                }
            }
        }
    }

    fn sessionBy(app: *App, delta: i32) !void {
        const at = app.sessionIndex(app.current) orelse return;
        const next = @as(i32, @intCast(at)) + delta;
        if (next < 0 or next >= app.sessions.items.len) return;
        try app.sessionTo(@intCast(next));
    }

    fn sessionTo(app: *App, index: usize) !void {
        const to = app.sessions.items[index];
        if (to.id == app.current) return;
        app.see();
        app.slide = if (index > app.sessionIndex(app.current) orelse index) 1 else -1;
        try app.send(.ignore, "switch-client -t '${d}'", .{to.id});
    }

    fn focusBy(app: *App, delta: i32) !void {
        const s = app.cur() orelse return;
        const next = @as(i32, @intCast(s.focus)) + delta;
        if (next < 0 or next >= s.wins.items.len) return;
        try app.focusTo(@intCast(next));
    }

    fn focusTo(app: *App, index: usize) !void {
        const s = app.cur() orelse return;
        app.see();
        s.focus = index;
        try app.send(.ignore, "select-window -t @{d}", .{s.wins.items[index].id});
        app.dirty = true;
    }

    const Name = union(enum) { window: u32, session: u32, pane: u32 };

    /// What ends a word picked by two clicks.
    const word_ends = [_]u21{ ' ', '\t', '\'', '"', '`', '|', '│', ':', ';', ',', '(', ')', '[', ']', '{', '}', '<', '>', '$' };

    /// Puts the pane's selected text on the system clipboard, through the terminal.
    fn copy(app: *App, pane: *Pane) !void {
        const screen = pane.term.screens.active;
        const sel = screen.selection orelse return;
        const text = try screen.selectionString(app.gpa, .{ .sel = sel, .trim = true });
        defer app.gpa.free(text);
        if (text.len == 0) return;
        const encoder = std.base64.standard.Encoder;
        try app.out.appendSlice(app.gpa, "\x1b]52;c;");
        _ = encoder.encode(try app.out.addManyAsSlice(app.gpa, encoder.calcSize(text.len)), text);
        try app.out.append(app.gpa, 0x07);
    }

    /// Opens the search prompt. Anything selected is let go, so the search starts from the newest.
    fn openSearch(app: *App) void {
        if (app.cur()) |s| if (s.focused()) |win| if (win.activePane()) |pane| {
            pane.term.screens.active.clearSelection();
        };
        app.prompt = .{ .what = .search };
        app.dirty = true;
    }

    /// Finds the prompt's text in the active pane's history, the match before the one last
    /// found, selects it and brings it into view. Past the oldest it starts again from the newest.
    fn searchNext(app: *App) !void {
        const prompt = &app.prompt.?;
        const s = app.cur() orelse return;
        const win = s.focused() orelse return;
        const pane = win.activePane() orelse return;
        const query = prompt.text();
        if (query.len == 0) return;
        const screen = pane.term.screens.active;
        const bottom = screen.pages.pin(.{ .active = .{ .x = 0, .y = pane.term.rows - 1 } }) orelse return;
        var passes: u2 = if (screen.selection == null) 1 else 2;
        var at: ?vt.Pin = if (screen.selection) |sel| sel.start().up(1) else bottom;
        var buf: [1024]u8 = undefined;
        while (passes > 0) : ({
            passes -= 1;
            at = bottom;
        }) {
            while (at) |pin| : (at = pin.up(1)) {
                var row: Writer = .fixed(&buf);
                var whole = pin;
                whole.x = 0;
                const last = pane.term.cols - 1;
                var row_end = whole;
                row_end.x = last;
                screen.dumpString(&row, .{ .tl = whole, .br = row_end, .unwrap = false }) catch {};
                const text = row.buffered();
                const found = std.ascii.findIgnoreCase(text, query) orelse continue;
                var start = whole;
                start.x = @intCast(@min(last, std.unicode.utf8CountCodepoints(text[0..found]) catch found));
                var end = whole;
                end.x = @intCast(@min(last, start.x + (std.unicode.utf8CountCodepoints(query) catch query.len) - 1));
                try screen.select(vt.Selection.init(start, end, false));
                if (screen.pages.pointFromPin(.screen, whole)) |point| {
                    // near the top, clear of the prompt in the middle
                    pane.term.scrollViewport(.{ .row = point.coord().y -| 2 });
                }
                prompt.missed = false;
                return;
            }
        }
        prompt.missed = true;
    }

    /// A window by where it is: which session of the list, which window of the session.
    pub const Spot = struct { session: usize, win: usize };

    /// The outer size of a window's picture in the overview.
    pub const thumb_w = 26;
    pub const thumb_h = 7;

    /// The row a session's name is on in the overview, its windows' pictures in the rows under
    /// it; null when it is off the screen. As many sessions show as fit, the picked one among them.
    pub fn overviewRow(app: *const App, session: usize) ?u16 {
        const spot = app.overview orelse return null;
        const block = thumb_h + 1;
        const shown: usize = @max(1, app.view_h / block);
        const first = if (spot.session >= shown) spot.session - shown + 1 else 0;
        if (session < first or session >= first + shown) return null;
        return @intCast((session - first) * block);
    }

    /// The top left corner of a window's picture in the overview; null when it is off the screen.
    pub fn thumbAt(app: *const App, at: Spot) ?struct { x: u16, y: u16 } {
        const spot = app.overview orelse return null;
        const row = app.overviewRow(at.session) orelse return null;
        const stride = thumb_w + 1;
        const across: usize = @max(1, (app.view_w + 1) / stride);
        const first = if (at.session == spot.session and spot.win >= across) spot.win - across + 1 else 0;
        if (at.win < first or at.win >= first + across) return null;
        return .{ .x = @intCast(app.term_w - app.view_w + (at.win - first) * stride), .y = row + 1 };
    }

    /// Opens the overview on the window in view. The other sessions' panes are captured again,
    /// so their pictures are of now and not of when arena was last there.
    fn openOverview(app: *App) void {
        const at = app.sessionIndex(app.current) orelse return;
        app.overview = .{ .session = at, .win = app.sessions.items[at].focus };
        for (app.sessions.items) |s| {
            if (s.id == app.current) continue;
            for (s.wins.items) |win| for (win.panes.items) |pane| {
                if (pane.seed == .done) pane.seed = .wanted;
            };
        }
        app.want_list = true;
        app.dirty = true;
    }

    /// A key in the overview: h, j, k, l and the arrows move, Enter goes to the window picked,
    /// Escape and q close.
    fn overviewKey(app: *App, key: []const u8) !void {
        app.dirty = true;
        const count = app.sessions.items.len;
        if (count == 0) {
            app.overview = null;
            return;
        }
        const spot = &app.overview.?;
        spot.session = @min(spot.session, count - 1);
        const is = struct {
            fn any(pressed: []const u8, names: []const []const u8) bool {
                for (names) |name| if (std.mem.eql(u8, pressed, name)) return true;
                return false;
            }
        }.any;
        if (is(key, &.{ "h", "\x1b[D", "\x1bOD" })) spot.win -|= 1;
        if (is(key, &.{ "l", "\x1b[C", "\x1bOC" })) spot.win += 1;
        if (is(key, &.{ "k", "\x1b[A", "\x1bOA" })) spot.session -|= 1;
        if (is(key, &.{ "j", "\x1b[B", "\x1bOB" }) and spot.session + 1 < count) spot.session += 1;
        const s = app.sessions.items[spot.session];
        spot.win = @min(spot.win, s.wins.items.len -| 1);
        if (is(key, &.{ "\x1b", "q" })) app.overview = null;
        if (is(key, &.{"\r"}) and s.wins.items.len > 0) {
            const win = spot.win;
            app.overview = null;
            try app.jumpTo(s, win);
        }
    }

    /// The mouse in the overview: a click on a picture goes to its window; a picture dragged
    /// onto another takes its place, in whichever session, and onto the rest of a session's
    /// row goes to that session's end; a click anywhere else closes the overview; and the
    /// wheel moves between sessions.
    fn overviewMouse(app: *App, m: keys.Mouse) !void {
        if (m.wheel()) {
            if (app.navStep()) try app.overviewKey(if (m.code & 1 == 0) "k" else "j");
            return;
        }
        if (app.drag == .thumb) {
            app.dirty = true;
            if (m.motion() and !m.hover()) return;
            const id = app.drag.thumb;
            const drop = app.overviewDrop();
            app.drag = .none;
            if (m.release) try app.dropThumb(id, drop orelse return);
            return;
        }
        if (!m.leftPress() and !m.rightPress()) return;
        app.dirty = true;
        if (m.leftPress()) if (app.thumbUnder(m.x, m.y)) |spot| {
            app.drag = .{ .thumb = app.sessions.items[spot.session].wins.items[spot.win].id };
            return;
        };
        app.overview = null;
    }

    /// The window whose picture in the overview is at (`x`, `y`) of the terminal.
    fn thumbUnder(app: *const App, x: u16, y: u16) ?Spot {
        for (app.sessions.items, 0..) |s, si| for (s.wins.items, 0..) |_, wi| {
            const at = app.thumbAt(.{ .session = si, .win = wi }) orelse continue;
            if (x >= at.x and x < at.x + thumb_w and y >= at.y and y < at.y + thumb_h) return .{ .session = si, .win = wi };
        };
        return null;
    }

    /// Where a window held by its picture would go, let go now: the place of the window whose
    /// picture is under the pointer, or with no `win` the end of the session whose row it is.
    pub const ThumbDrop = struct { session: usize, win: ?usize };

    pub fn overviewDrop(app: *const App) ?ThumbDrop {
        if (app.drag != .thumb) return null;
        const at = app.pointer;
        if (app.thumbUnder(at.x, at.y)) |spot| return .{ .session = spot.session, .win = spot.win };
        if (at.x < app.term_w - app.view_w) return null;
        for (app.sessions.items, 0..) |_, si| {
            const row = app.overviewRow(si) orelse continue;
            if (at.y >= row and at.y <= row + thumb_h) return .{ .session = si, .win = null };
        }
        return null;
    }

    /// The window `id`, held by its picture, was let go on `drop`: on its own picture that
    /// was a click, and goes to it.
    fn dropThumb(app: *App, id: u32, drop: ThumbDrop) !void {
        const to = app.sessions.items[drop.session];
        for (app.sessions.items) |s| for (s.wins.items, 0..) |win, from| {
            if (win.id != id) continue;
            const onto = drop.win orelse {
                if (s != to) try app.sendWin(s, from, to, null);
                return;
            };
            if (s != to) return app.sendWin(s, from, to, to.wins.items[onto].id);
            if (onto != from) return app.moveWin(s, from, onto);
            app.overview = null;
            return app.jumpTo(s, from);
        };
    }

    pub const Hit = struct { session: *Session, index: usize };

    /// The windows of every session whose "session window" answers `query`, the closest first,
    /// into `out`. Returns how many.
    pub fn jumpHits(app: *const App, query: []const u8, out: []Hit) usize {
        var n: usize = 0;
        for ([_]u1{ 0, 1 }) |rank| for (app.sessions.items) |s| for (s.wins.items, 0..) |win, i| {
            if (n == out.len) return n;
            var buf: [160]u8 = undefined;
            const text = std.fmt.bufPrint(&buf, "{s} {s}", .{ s.name, win.name }) catch continue;
            if (menu.fuzzy(query, text) == rank) {
                out[n] = .{ .session = s, .index = i };
                n += 1;
            }
        };
        return n;
    }

    /// Goes to a window of any session.
    fn jumpTo(app: *App, s: *Session, index: usize) !void {
        if (s.id == app.current) return app.focusTo(index);
        s.focus = index;
        try app.send(.ignore, "select-window -t @{d}", .{s.wins.items[index].id});
        try app.sessionTo(app.sessionIndex(s.id) orelse return);
    }

    /// Whether this click on a name is the second of a pair.
    fn doubleClick(app: *App, name: Name) bool {
        const again = std.meta.eql(app.clicked, @as(?Name, name)) and app.now - app.clicked_at < double_click_ms;
        app.clicked = if (again) null else name;
        app.clicked_at = app.now;
        return again;
    }

    /// The held button moved to `m`, or let go, wherever the pointer is by then.
    fn dragTo(app: *App, m: keys.Mouse) !void {
        const s = app.cur() orelse {
            app.drag = .none;
            return;
        };
        if (m.release or !m.motion() or m.hover()) {
            const held = app.drag;
            const drop = app.dropAt();
            app.drag = .none;
            app.dirty = true;
            switch (held) {
                .select => |from| if (app.paneById(from.pane)) |pane| try app.copy(pane),
                .title => |id| if (m.release) try app.dropWindow(s, id, drop),
                else => {},
            }
            return;
        }
        const ox: i32 = app.term_w - app.view_w;
        switch (app.drag) {
            .none, .thumb => {},
            // Past the pane's top or bottom the history scrolls under the pointer.
            .select => |from| {
                const pane = app.paneById(from.pane) orelse return;
                const screen = pane.term.screens.active;
                const left = ox + app.colX(s, s.focus) - s.scroll + 1 + pane.x;
                const x = std.math.clamp(m.x - left, 0, pane.term.cols - 1);
                var y = @as(i32, m.y) - 1 - pane.y;
                if (y < 0 or y >= pane.term.rows) pane.term.scrollViewport(.{ .delta = if (y < 0) -1 else 1 });
                y = std.math.clamp(y, 0, pane.term.rows - 1);
                const end = screen.pages.pin(.{ .viewport = .{ .x = @intCast(x), .y = @intCast(y) } }) orelse return;
                const start = if (screen.selection) |sel|
                    sel.start()
                else
                    screen.pages.pin(.{ .viewport = .{ .x = from.x, .y = from.y } }) orelse return;
                try screen.select(vt.Selection.init(start, end, false));
                app.dirty = true;
            },
            .divider => |*line| {
                const win = s.focused() orelse return;
                const pane = for (win.panes.items) |pane| {
                    if (pane.id == line.pane) break pane;
                } else {
                    app.drag = .none;
                    return;
                };
                const inside = ox + app.colX(s, s.focus) - s.scroll + 1;
                const want: i32 = if (line.upright) m.x - inside - pane.x else @as(i32, m.y) - 1 - pane.y;
                if (want < 1 or want == line.asked) return;
                line.asked = want;
                const axis: u8 = if (line.upright) 'x' else 'y';
                try app.send(.ignore, "resize-pane -t %{d} -{c} {d}", .{ pane.id, axis, want });
            },
            // The width is what it was when taken hold of and how far the pointer has gone
            // since: the strip moves under the pointer as the column grows, so where the edge
            // is now says nothing.
            .edge => |held| {
                const win = for (s.wins.items) |win| {
                    if (win.id == held.win) break win;
                } else return;
                const moved = @as(i32, m.x) - held.x;
                try app.setShare(s, win, app.shareOf(held.w + if (held.right) moved else -moved));
            },
            // Nothing moves until it is let go: where it would go is drawn.
            .title => app.dirty = true,
            .session => |id| try app.dragSession(id, m),
        }
    }

    /// Where a window held by its title would go, let go now: the place of the column under
    /// the pointer, or a session on the rail.
    pub const Drop = union(enum) { none, column: usize, session: usize };

    pub fn dropAt(app: *const App) Drop {
        if (app.drag != .title) return .none;
        const s = app.cur() orelse return .none;
        const ox = app.term_w - app.view_w;
        if (app.pointer.x < ox) {
            const row = app.railSession(app.pointer.y) orelse return .none;
            return if (app.sessions.items[row].id == s.id) .none else .{ .session = row };
        }
        const hit = app.colAt(s, @as(i32, app.pointer.x) - ox + s.scroll) orelse return .none;
        return if (s.wins.items[hit.index].id == app.drag.title) .none else .{ .column = hit.index };
    }

    /// Which session is on row `y` of the rail.
    fn railSession(app: *const App, y: u16) ?usize {
        if (y < 1 or y + 3 >= app.view_h or y - 1 >= app.sessions.items.len) return null;
        return y - 1;
    }

    fn dropWindow(app: *App, s: *Session, id: u32, drop: Drop) !void {
        const from = for (s.wins.items, 0..) |win, index| {
            if (win.id == id) break index;
        } else return;
        // a press that moved a window was not the first of two on its name
        if (drop != .none) app.clicked = null;
        switch (drop) {
            .none => {},
            .column => |to| try app.moveWin(s, from, to),
            .session => |to| try app.sendWin(s, from, app.sessions.items[to], null),
        }
    }

    /// Moves a window of `s` to another's place, the ones between shifting along: tmux swaps
    /// two at a time.
    fn moveWin(app: *App, s: *const Session, from: usize, to: usize) !void {
        const id = s.wins.items[from].id;
        var at = from;
        while (at != to) {
            at = if (to > at) at + 1 else at - 1;
            try app.send(.ignore, "swap-window -d -s @{d} -t @{d}", .{ id, s.wins.items[at].id });
        }
        app.want_list = true;
    }

    /// Moves a window of `s` to another session: in front of its window `before`, or to its
    /// end. A session's last window takes the session with it, and tmux would detach arena
    /// from a session that ends, so arena goes with the window.
    fn sendWin(app: *App, s: *const Session, from: usize, to: *const Session, before: ?u32) !void {
        if (s.id == app.current and s.wins.items.len == 1) {
            try app.sessionTo(app.sessionIndex(to.id) orelse return);
        }
        const id = s.wins.items[from].id;
        if (before) |next| {
            try app.send(.ignore, "move-window -b -s @{d} -t @{d}", .{ id, next });
        } else try app.send(.ignore, "move-window -s @{d} -t '${d}:'", .{ id, to.id });
        app.want_list = true;
    }

    /// The held button moved to `m` with a session, which goes to the row under the pointer.
    fn dragSession(app: *App, id: u32, m: keys.Mouse) !void {
        const at = app.sessionIndex(id) orelse return;
        const shown = @min(app.sessions.items.len, app.view_h -| 4);
        const over = @min(shown -| 1, m.y -| 1);
        if (over != at) try app.moveSession(at, over);
    }

    /// Puts the session at `at` of the rail at `to`, and has tmux keep every session's place.
    fn moveSession(app: *App, at: usize, to: usize) !void {
        app.sessions.insertAssumeCapacity(to, app.sessions.orderedRemove(at));
        for (app.sessions.items, 1..) |s, place| {
            s.order = @intCast(place);
            try app.send(.ignore, "set-option -t '${d}' @arena_order {d}", .{ s.id, place });
        }
        app.dirty = true;
    }

    /// Moves the current session up or down the rail.
    fn sessionSwapBy(app: *App, delta: i32) !void {
        const at = app.sessionIndex(app.current) orelse return;
        const next = @as(i32, @intCast(at)) + delta;
        if (next < 0 or next >= app.sessions.items.len) return;
        try app.moveSession(at, @intCast(next));
    }

    /// The row of the rail a click on makes a session, under the last of them; none when the
    /// rail is full.
    pub fn railNewRow(app: *const App) ?u16 {
        const y = app.sessions.items.len + 1;
        return if (y + 3 < app.view_h) @intCast(y) else null;
    }

    /// Ends a session and every window in it. tmux would detach arena from the session it is
    /// on when that ends, so arena moves to a neighbour first.
    fn closeSession(app: *App, id: u32) !void {
        const at = app.sessionIndex(id) orelse return;
        const count = app.sessions.items.len;
        if (id == app.current and count > 1) try app.sessionTo(if (at + 1 < count) at + 1 else at - 1);
        try app.send(.ignore, "kill-session -t '${d}'", .{id});
    }

    /// What can be taken hold of to resize: a column by one of its sides, or the line after a
    /// pane of the focused window.
    pub const Grip = union(enum) {
        edge: struct { index: usize, right: bool },
        divider: struct { pane: u32, upright: bool },
    };

    pub fn gripAt(app: *const App, x: u16, y: u16) ?Grip {
        const s = app.cur() orelse return null;
        const ox = app.term_w - app.view_w;
        if (x < ox or y == 0 or y + 1 >= app.view_h or app.yoff != 0) return null;
        const hit = app.colAt(s, @as(i32, x) - ox + s.scroll) orelse return null;
        const win = s.wins.items[hit.index];
        const last = app.colW(s, win) - 1;
        if (hit.cx == 0 or hit.cx == last) return .{ .edge = .{ .index = hit.index, .right = hit.cx == last } };
        if (hit.index != s.focus) return null;
        const tx = hit.cx - 1;
        const ty = y - 1;
        if (win.paneAt(tx, ty) != null) return null;
        if (tx > 0) if (win.paneAt(tx - 1, ty)) |before| return .{ .divider = .{ .pane = before.id, .upright = true } };
        if (ty > 0) if (win.paneAt(tx, ty - 1)) |above| return .{ .divider = .{ .pane = above.id, .upright = false } };
        return null;
    }

    /// Has the terminal show the pointer as what it is over, or holds, can be dragged: by
    /// name, as OSC 22 takes them.
    fn pointAs(app: *App, m: keys.Mouse) !void {
        const sideways = "ew-resize";
        const upright = "ns-resize";
        const shape: []const u8 = switch (app.drag) {
            .edge => sideways,
            .divider => |line| if (line.upright) sideways else upright,
            .none => if (app.overlay()) "default" else if (app.gripAt(m.x, m.y)) |grip| switch (grip) {
                .edge => sideways,
                .divider => |line| if (line.upright) sideways else upright,
            } else "default",
            else => "default",
        };
        if (shape.ptr == app.shape.ptr) return;
        app.shape = shape;
        try app.out.print(app.gpa, "\x1b]22;{s}\x1b\\", .{shape});
    }

    /// True when a wheel or swipe step may move between windows or sessions: they come in
    /// bursts, and each burst is one step.
    fn navStep(app: *App) bool {
        if (app.now - app.nav_at < nav_gap_ms) return false;
        app.nav_at = app.now;
        return true;
    }

    /// A right click nothing else took opens the menu; with the menu open, a click picks from it
    /// or, outside it, closes it.
    fn onMouse(app: *App, m: keys.Mouse) !void {
        app.pointer = .{ .x = m.x, .y = m.y };
        try app.pointAs(m);
        if (app.overview != null) return app.overviewMouse(m);
        if (app.prompt) |*prompt| {
            if (!m.leftPress() and !m.rightPress()) return;
            app.dirty = true;
            const at = app.box(prompt.height());
            const first = at.y + menu.Prompt.list_row;
            const listed = prompt.what == .jump and m.leftPress() and m.x > at.x and m.x + 1 < at.x + menu.width and
                m.y >= first and m.y < first + menu.jump_rows;
            if (!listed) {
                app.prompt = null;
                return;
            }
            prompt.selected = m.y - first;
            return app.commit();
        }
        if (app.menu) |open| {
            if (!m.leftPress() and !m.rightPress()) return;
            const at = app.box(open.height());
            const inside = m.x >= at.x and m.x < at.x + menu.width and m.y >= at.y and m.y < at.y + open.height();
            try app.menuResult(if (inside and m.leftPress()) open.click(m.x - at.x, m.y - at.y) else .close);
            return;
        }
        if (!try app.mouseHit(m) and m.rightPress()) app.openMenu(&menu.main);
    }

    /// Whether the mouse event was for something. On the rail: a click picks a session or the
    /// menu, a second one on the current session renames it, one under the last makes a new
    /// one, a session is dragged to move it and middle clicked to close it, the wheel steps
    /// through sessions.
    /// On the strip: a click goes to that window, dot or pane; a title is dragged onto another
    /// column, to take its place, or onto a session of the rail, to go there, clicked twice to
    /// rename its window, middle clicked to close it; the line between panes is dragged to
    /// resize them, and a column's side to resize its window; a sideways wheel steps through
    /// windows; and anything inside a pane is its program's or scrolls it.
    fn mouseHit(app: *App, m: keys.Mouse) !bool {
        const ox = app.term_w - app.view_w;
        if (app.drag != .none and !m.wheel()) {
            try app.dragTo(m);
            return true;
        }
        if (m.x < ox) {
            if (m.wheel()) {
                if (app.navStep()) try app.sessionBy(if (m.code & 1 == 0) -1 else 1);
                return true;
            }
            if (m.middlePress()) if (app.railSession(m.y)) |row| {
                app.doomed = app.sessions.items[row].id;
                app.openMenu(&menu.confirm_session);
                return true;
            };
            if (!m.leftPress()) return false;
            if (m.y + 2 == app.view_h) app.openMenu(&menu.main);
            if (m.y == app.railNewRow()) try app.send(.ignore, "new-session", .{});
            if (app.railSession(m.y)) |row| {
                const id = app.sessions.items[row].id;
                if (app.doubleClick(.{ .session = id }) and id == app.current) {
                    app.prompt = .{ .what = .session };
                    app.dirty = true;
                } else {
                    try app.sessionTo(row);
                    app.drag = .{ .session = id };
                }
            }
            return true;
        }
        const s = app.cur() orelse return false;
        if (app.yoff != 0) return false;
        if (m.sideways()) {
            if (app.navStep()) try app.focusBy(if (m.code & 1 == 0) -1 else 1);
            return true;
        }
        if (m.leftPress()) if (app.gripAt(m.x, m.y)) |grip| {
            app.drag = switch (grip) {
                .edge => |edge| .{ .edge = .{ .win = s.wins.items[edge.index].id, .right = edge.right, .x = m.x, .w = app.colW(s, s.wins.items[edge.index]) } },
                .divider => |line| .{ .divider = .{ .pane = line.pane, .upright = line.upright } },
            };
            return true;
        };
        const hit = app.colAt(s, @as(i32, m.x) - ox + s.scroll) orelse return false;
        const index = hit.index;
        const cx = hit.cx;
        const win = s.wins.items[index];
        const col_w = app.colW(s, win);
        const focused = index == s.focus;
        if (m.y == 0 and m.middlePress()) {
            try app.focusTo(index);
            app.openMenu(&menu.confirm);
            return true;
        }
        if (m.y == 0 and m.leftPress()) {
            if (!focused) try app.focusTo(index);
            if (app.doubleClick(.{ .window = win.id })) {
                app.prompt = .{ .what = .window };
                app.dirty = true;
            } else app.drag = .{ .title = win.id };
            return true;
        }
        if (!focused and !m.wheel()) {
            if (m.leftPress()) try app.focusTo(index);
            return m.leftPress();
        }
        if (m.y == app.view_h - 1) {
            const dot = layout.dotAt(col_w, s.wins.items.len, cx) orelse return false;
            if (focused and m.leftPress()) try app.focusTo(dot);
            return focused and m.leftPress();
        }
        if (cx == 0 or cx == col_w - 1 or m.y == 0) return false;
        const pane = win.paneAt(cx - 1, m.y - 1) orelse return false;
        if (focused) {
            if (m.leftPress() and pane != win.activePane()) {
                win.active = std.mem.indexOfScalar(*Pane, win.panes.items, pane).?;
                try app.send(.ignore, "select-pane -t %{d}", .{pane.id});
                app.dirty = true;
            }
            const px: u16 = @intCast(cx - 1 - pane.x);
            const py: u16 = @intCast(m.y - 1 - pane.y);
            if (try app.mouseToPane(pane, m, px, py)) return true;
            // The program takes no mouse: the button selects text, which is copied when it is
            // let go, and two clicks pick a word.
            if (m.leftPress()) {
                const screen = pane.term.screens.active;
                screen.clearSelection();
                app.dirty = true;
                if (!app.doubleClick(.{ .pane = pane.id })) {
                    app.drag = .{ .select = .{ .pane = pane.id, .x = px, .y = py } };
                    return true;
                }
                const pin = screen.pages.pin(.{ .viewport = .{ .x = px, .y = py } }) orelse return true;
                try screen.select(screen.selectWord(pin, &word_ends) orelse return true);
                try app.copy(pane);
                return true;
            }
        }
        if (!m.wheel()) return false;
        const up = m.code & 1 == 0;
        // A full-screen program with no mouse of its own has no history to scroll: the wheel is
        // its arrow keys, as terminals do.
        if (focused and pane.term.screens.active_key == .alternate) {
            const app_keys = pane.term.modes.get(.cursor_keys);
            const arrow: []const u8 = if (app_keys) (if (up) "\x1bOA" else "\x1bOB") else if (up) "\x1b[A" else "\x1b[B";
            for (0..3) |_| try app.sendKeys(pane, arrow);
            return true;
        }
        pane.term.scrollViewport(.{ .delta = if (up) -3 else 3 });
        app.dirty = true;
        return true;
    }

    /// Reports the mouse to the pane's program in the mode and format it asked tmux for; false
    /// when it asked for none.
    fn mouseToPane(app: *App, pane: *Pane, m: keys.Mouse, x: usize, y: usize) !bool {
        const mode = pane.term.flags.mouse_event;
        if (mode == .none) return false;
        if (m.motion() and mode != .button and mode != .any) return true;
        if (m.hover() and mode != .any) return true;
        if (m.release and mode == .x10) return true;
        var buf: [32]u8 = undefined;
        switch (pane.term.flags.mouse_format) {
            .sgr, .sgr_pixels => {
                const end: u8 = if (m.release) 'm' else 'M';
                try app.sendKeys(pane, try std.fmt.bufPrint(&buf, "\x1b[<{d};{d};{d}{c}", .{ m.code, x + 1, y + 1, end }));
            },
            else => {
                // one byte a coordinate, offset by 32: cells past 222 cannot be said
                if (x > 222 or y > 222) return true;
                const code = if (m.release) m.code | 3 else m.code;
                buf[0..3].* = "\x1b[M".*;
                buf[3] = @intCast(code + 32);
                buf[4] = @intCast(x + 33);
                buf[5] = @intCast(y + 33);
                try app.sendKeys(pane, buf[0..6]);
            },
        }
        return true;
    }

    fn openMenu(app: *App, items: []const menu.Item) void {
        app.menu = .{ .items = items };
        app.dirty = true;
    }

    /// Whether the menu, a prompt or the overview has the keys and lies over the strip.
    pub fn overlay(app: *const App) bool {
        return app.menu != null or app.prompt != null or app.overview != null;
    }

    /// Where the top left corner of a menu or prompt `height` rows tall is: centred over the strip.
    pub fn box(app: *const App, height: u16) struct { x: u16, y: u16 } {
        return .{
            .x = app.term_w - app.view_w + (app.view_w -| menu.width) / 2,
            .y = (app.view_h -| height) / 2,
        };
    }

    fn menuKeys(app: *App, text: []const u8) !void {
        var i: usize = 0;
        while (i < text.len) {
            // an arrow is ESC and two more; anything else is a key a byte
            const len: usize = if (text[i] == 0x1b and text.len - i >= 3) 3 else 1;
            const key = text[i..][0..len];
            i += len;
            if (app.overview != null) {
                try app.overviewKey(key);
            } else if (app.prompt) |*prompt| {
                app.dirty = true;
                switch (prompt.press(key)) {
                    .none => {},
                    .cancel => app.prompt = null,
                    .commit => try app.commit(),
                    .up => prompt.selected -|= 1,
                    .down => {
                        var hits: [menu.jump_rows]Hit = undefined;
                        if (prompt.selected + 1 < app.jumpHits(prompt.text(), &hits)) prompt.selected += 1;
                    },
                }
            } else if (app.menu) |*open| try app.menuResult(open.press(key)) else return;
        }
    }

    /// Enter in the prompt: goes to the window picked, or gives the focused window or the
    /// session the name typed, an empty one changing nothing.
    fn commit(app: *App) !void {
        const prompt = app.prompt orelse return;
        if (prompt.what == .search) return app.searchNext();
        app.prompt = null;
        const s = app.cur() orelse return;
        var cmd: Writer.Allocating = .init(app.gpa);
        defer cmd.deinit();
        switch (prompt.what) {
            .jump => {
                var hits: [menu.jump_rows]Hit = undefined;
                const n = app.jumpHits(prompt.text(), &hits);
                if (prompt.selected < n) try app.jumpTo(hits[prompt.selected].session, hits[prompt.selected].index);
                return;
            },
            .search => return,
            .window => try cmd.writer.print("rename-window -t @{d} -- '", .{(s.focused() orelse return).id}),
            .session => try cmd.writer.print("rename-session -t '${d}' -- '", .{s.id}),
        }
        if (prompt.len == 0) return;
        for (prompt.text()) |byte| {
            if (byte == '\'') try cmd.writer.writeAll("'\\''") else try cmd.writer.writeByte(byte);
        }
        try cmd.writer.writeAll("'");
        try app.send(.ignore, "{s}", .{cmd.written()});
    }

    /// Closes the active pane, asking first when it is the window's only one.
    fn closePane(app: *App) !void {
        const s = app.cur() orelse return;
        const win = s.focused() orelse return;
        const pane = win.activePane() orelse return;
        if (win.panes.items.len == 1) return app.openMenu(&menu.confirm);
        try app.send(.ignore, "kill-pane -t %{d}", .{pane.id});
    }

    fn menuResult(app: *App, result: menu.Menu.Result) !void {
        app.dirty = true;
        switch (result) {
            .none => {},
            .close => app.menu = null,
            .act => |action| {
                app.menu = null;
                switch (action) {
                    .new_window => try app.newWindow(),
                    .rename_window => app.prompt = .{ .what = .window },
                    .rename_session => app.prompt = .{ .what = .session },
                    .move_left => try app.swapBy(-1),
                    .move_right => try app.swapBy(1),
                    .full_width => app.toggleFull(),
                    .jump => app.prompt = .{ .what = .jump },
                    .overview => app.openOverview(),
                    .split_right => try app.send(.ignore, "split-window -h -c '#{{pane_current_path}}'", .{}),
                    .split_below => try app.send(.ignore, "split-window -v -c '#{{pane_current_path}}'", .{}),
                    .close_pane => try app.closePane(),
                    .search => app.openSearch(),
                    .close_window => app.openMenu(&menu.confirm),
                    .confirm_close => try app.closeWindow(),
                    .confirm_close_session => try app.closeSession(app.doomed),
                    .new_session => try app.send(.ignore, "new-session", .{}),
                    .detach => app.quit = true,
                    .cancel => {},
                }
            },
        }
    }

    /// A window after the focused one, in its directory, and focus on it.
    fn newWindow(app: *App) !void {
        app.follow_active = true;
        try app.send(.ignore, "new-window -a -c '#{{pane_current_path}}'", .{});
    }

    /// Closes the focused window. A session's last window takes the session with it, and tmux
    /// would detach arena from a session that ends, so arena moves to a neighbour first.
    fn closeWindow(app: *App) !void {
        const s = app.cur() orelse return;
        const win = s.focused() orelse return;
        const id = win.id;
        if (s.wins.items.len == 1 and app.sessions.items.len > 1) {
            const at = app.sessionIndex(s.id) orelse 0;
            try app.sessionTo(if (at + 1 < app.sessions.items.len) at + 1 else at - 1);
        }
        try app.send(.ignore, "kill-window -t @{d}", .{id});
    }

    fn swapBy(app: *App, delta: i32) !void {
        const s = app.cur() orelse return;
        const next = @as(i32, @intCast(s.focus)) + delta;
        if (next < 0 or next >= s.wins.items.len) return;
        try app.moveWin(s, s.focus, @intCast(next));
    }

    fn onChord(app: *App, letter: u8) !void {
        if (app.overlay()) {
            app.menu = null;
            app.prompt = null;
            app.overview = null;
            app.dirty = true;
            return;
        }
        switch (letter) {
            'h' => try app.focusBy(-1),
            'l' => try app.focusBy(1),
            'j' => try app.sessionBy(1),
            'k' => try app.sessionBy(-1),
            'J' => try app.sessionSwapBy(1),
            'K' => try app.sessionSwapBy(-1),
            'H' => try app.swapBy(-1),
            'L' => try app.swapBy(1),
            'x' => app.openMenu(&menu.confirm),
            'm' => app.openMenu(&menu.main),
            'q' => app.quit = true,
            'z' => app.toggleFull(),
            ';' => try app.widenBy(-share_step),
            '\'' => try app.widenBy(share_step),
            'o' => app.openOverview(),
            '/' => app.openSearch(),
            'p' => {
                app.prompt = .{ .what = .jump };
                app.dirty = true;
            },
            '\r' => try app.newWindow(),
            else => if (app.cur()) |s| {
                if (letter - '1' < s.wins.items.len) try app.focusTo(letter - '1');
            },
        }
    }

    /// With Alt: h and l move along the strip, j and k between sessions, 1 to 9 go to a window,
    /// J and K move the session down and up the rail,
    /// H and L move the window, ; and ' make it narrower and wider, Enter opens one, x closes
    /// it, z gives it the whole width, p asks
    /// for a window to jump to, o shows every session's windows at once, / searches the pane's
    /// history, m opens the menu and q leaves.
    /// Everything else is the focused pane's, or the menu's while it is open. Alt is ESC and the
    /// letter together, which a typed Escape then a letter rarely is.
    ///
    /// Returns how many bytes at the end of `bytes` to pass again in front of the next read.
    pub fn onInput(app: *App, bytes: []const u8) !usize {
        var rest = bytes;
        while (rest.len > 0 and !app.quit) {
            const part = keys.next(rest);
            rest = part.rest;
            if (app.overlay()) try app.menuKeys(part.text) else try app.forward(part.text);
            switch (part.event orelse return part.held.len) {
                .mouse => |m| try app.onMouse(m),
                .chord => |letter| try app.onChord(letter),
                .osc => |body| {
                    app.palette.answer(body);
                    app.dirty = true;
                },
            }
        }
        return 0;
    }

    fn forward(app: *App, bytes: []const u8) !void {
        const s = app.cur() orelse return;
        const win = s.focused() orelse return;
        const pane = win.activePane() orelse return;
        if (bytes.len == 0) return;
        pane.term.screens.active.clearSelection();
        pane.term.scrollViewport(.bottom);
        app.dirty = true;
        try app.sendKeys(pane, bytes);
    }

    fn sendKeys(app: *App, pane: *const Pane, bytes: []const u8) !void {
        var cmd: Writer.Allocating = .init(app.gpa);
        defer cmd.deinit();
        try cmd.writer.print("send-keys -H -t %{d}", .{pane.id});
        for (bytes) |b| try cmd.writer.print(" {x:0>2}", .{b});
        try app.send(.ignore, "{s}", .{cmd.written()});
    }
};
