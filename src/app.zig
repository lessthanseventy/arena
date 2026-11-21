const std = @import("std");
const vt = @import("ghostty-vt");
const control = @import("control.zig");
const layout = @import("layout.zig");
const keys = @import("keys.zig");
const menu = @import("menu.zig");
const color = @import("color.zig");
const Theme = @import("theme.zig").Theme;
const Pass = @import("pass.zig").Pass;
const tickets = @import("board.zig");
const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;

pub const rail_button = "≡ menu";
pub const rail_new = "+ new";
const history_lines = 5000;
const rail_wide = 36;
const rail_narrow = 8;
/// How long the pointer rests on the narrow rail before it is drawn wide over the strip.
const dwell_ms = 300;
const quiet_s = 600;
const stir_s = 60;
pub const max_tabs = 32;
pub const tab_name = 16;
/// Wheel and swipe steps that move between windows or sessions are taken this far apart.
const nav_gap_ms = 150;
/// A sideways swipe steps once it has gone this many wheel events one way.
const swipe_events = 3;

/// Two clicks on a name this close together ask to rename it.
const double_click_ms = 400;

/// tmux has no order of sessions to change, so arena keeps each one's place in an option on it.
const session_format = "#{{session_id}} #{{?@arena_order,#{{@arena_order}},-}} #{{session_name}}";
/// A pane's @arena_claude, set by Claude Code's hooks, comes as its `Mark`'s number.
const claude_state = "#{{?#{{==:#{{@arena_claude}},background}},1,#{{?#{{==:#{{@arena_claude}},working}},2," ++
    "#{{?#{{==:#{{@arena_claude}},done}},3,#{{?#{{==:#{{@arena_claude}},waiting}},4,0}}}}}}}}";
/// A pane's @arena_review, set from its branch's code review, comes as its `Review`'s number.
const review_state = "#{{?#{{==:#{{@arena_review}},landed}},1,#{{?#{{==:#{{@arena_review}},reviewed}},2," ++
    "#{{?#{{==:#{{@arena_review}},queued}},3,#{{?#{{==:#{{@arena_review}},changes}},4,0}}}}}}}}";
const pane_format = "#{{session_id}} #{{window_id}} #{{pane_id}} #{{window_width}} #{{window_height}} " ++
    "#{{pane_left}} #{{pane_top}} #{{pane_width}} #{{pane_height}} #{{pane_active}} #{{window_active}} " ++
    claude_state ++ " #{{window_cell_width}} #{{window_cell_height}} #{{?@arena_width,#{{@arena_width}},0}} " ++
    review_state ++ " #{{?@arena_claude_since,#{{@arena_claude_since}},0}} " ++
    "#{{?@arena_claude_tokens,#{{@arena_claude_tokens}},0}} #{{?@arena_claude_at,#{{@arena_claude_at}},0}} " ++
    "#{{?@arena_claude_took,#{{@arena_claude_took}},0}} #{{?@arena_claude_ctx,#{{@arena_claude_ctx}},0}} " ++
    "#{{?@arena_claude_stirred,#{{@arena_claude_stirred}},0}} #{{?window_bell_flag,2,#{{?window_activity_flag,1,0}}}} " ++
    "#{{@arena_claude_doing}}\t#{{@arena_claude_prompt}}\t#{{@arena_claude_title}}\t#{{@arena_claude_said}}\t" ++
    "#{{@arena_claude_branch}}\t#{{@arena_claude_background}}\t#{{window_name}}";

/// The least and the most of the view a window's column is given, in hundredths, and how much
/// one press of narrower or wider changes it.
const min_share = 20;
const max_share = 100;
const share_step = 10;

/// What the Claude in a window not being looked at is doing: between turns with work of its own
/// running in the background, working, done and not yet looked at, or waiting on an answer. In
/// rising order of how much it wants looking at.
pub const Mark = enum { none, background, working, done, waiting };
/// What tmux saw in a window out of view: output, where `monitor-activity` is on, or a bell.
pub const Alert = enum { none, activity, bell };
/// Where the branch a window's panes are on stands in code review: landed, approved, in the
/// merge queue, or with changes requested. In rising order of how much it wants looking at.
pub const Review = enum {
    none,
    landed,
    reviewed,
    queued,
    changes,

    /// The state tmux's `review_state` gave as a number; anything else is `none`.
    pub fn of(n: u32) Review {
        return if (n <= @backingInt(Review.changes)) @fromBackingInt(@intCast(n)) else .none;
    }
};
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
    pass: Pass = .{},
    /// A pane's output is dropped until its captured screen has been fed in: the capture holds
    /// it. `wanted` again when arena comes back to a session, whose output it was not sent.
    seed: enum { wanted, asked, done } = .wanted,
    /// The `App.colors_known` this pane's colours were last told to tmux at, 0 for never.
    colors_told: u32 = 0,
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
        pane.pass.deinit(gpa);
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
    /// The size of a cell in pixels, as tmux tells the window's programs.
    cell_w: u16 = 16,
    cell_h: u16 = 32,
    /// The size arena last asked tmux for, so one tmux will not give is asked for once.
    asked_w: u16 = 0,
    asked_h: u16 = 0,
    /// The hundredths of the view its column is given, kept in tmux as @arena_width; 0 until
    /// it is made narrower or wider, when the column has the width every such one has.
    share: u8 = 0,
    /// The most pressing state of the Claudes in its panes, the one it had at the list before,
    /// null for a window new to arena, and the pane of the Claude it is marked by.
    claude: Mark = .none,
    was: ?Mark = null,
    agent_pane: u32 = 0,
    review: Review = .none,
    alert: Alert = .none,
    listed: bool = false,
    /// About the Claude it is marked by, as its hook set it, 0 and empty where no hook has: when
    /// its state began and when it or a subagent of its last did anything, in seconds since the
    /// epoch, the tokens of its context and the share of its budget they are, as its status line
    /// set it, how long its last turn took, and its `Info` between tabs.
    since: u32 = 0,
    at: u32 = 0,
    tokens: u32 = 0,
    ctx: u32 = 0,
    took: u32 = 0,
    info: []u8 = &.{},

    pub const Info = enum { doing, prompt, title, said, branch, background };

    pub fn text(win: *const Window, field: Info) []const u8 {
        var it = std.mem.splitScalar(u8, win.info, '\t');
        for (0..@backingInt(field)) |_| _ = it.next();
        return it.next() orelse "";
    }

    /// What a list of Claudes calls it: its conversation's title, or the window's name before
    /// it has one.
    pub fn label(win: *const Window) []const u8 {
        const title = win.text(.title);
        return if (title.len > 0) title else win.name;
    }

    /// What a list of Claudes says its session itself is doing, under it: the tool it is on or
    /// what it waits for, or the first line of its last answer; else what it was last asked.
    pub fn detail(win: *const Window) []const u8 {
        const now = switch (win.claude) {
            .working, .waiting => win.text(.doing),
            .background, .done, .none => win.text(.said),
        };
        return if (now.len > 0) now else win.text(.prompt);
    }

    /// Whether a Claude runs in it, one done and looked at included.
    pub fn agent(win: *const Window) bool {
        return win.since != 0 or win.claude != .none;
    }

    fn know(win: *Window, gpa: Allocator, since: u32, tokens: u32, at: u32, took: u32, ctx: u32, info: []const u8) !void {
        gpa.free(win.info);
        win.info = &.{};
        win.since = since;
        win.tokens = tokens;
        win.at = at;
        win.took = took;
        win.ctx = ctx;
        win.info = try gpa.dupe(u8, info);
    }

    /// Whether it has been working with nothing heard from it, nor any subagent of its, for
    /// `quiet_s`: a tool hung, or a call that will not come back.
    pub fn quiet(win: *const Window, epoch: i64) bool {
        return win.claude == .working and win.at != 0 and epoch - win.at >= quiet_s;
    }

    pub fn activePane(win: *const Window) ?*Pane {
        return if (win.active < win.panes.items.len) win.panes.items[win.active] else null;
    }

    pub fn paneAt(win: *const Window, x: usize, y: usize) ?*Pane {
        for (win.panes.items) |pane| if (pane.contains(x, y)) return pane;
        return null;
    }

    fn destroy(win: *Window, gpa: Allocator) void {
        gpa.free(win.name);
        gpa.free(win.info);
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

    /// babylon's own session, where its pipeline runs gates: kept last, off the rail and the
    /// agents, and reached from the board.
    pub fn gate(s: *const Session) bool {
        return std.mem.eql(u8, s.name, "babylon");
    }

    /// The orchestrator's session (`babylon orchestrator` starts it): kept off the rail with the gate.
    pub fn orchestrator(s: *const Session) bool {
        return std.mem.eql(u8, s.name, "orchestrator");
    }

    pub fn offRail(s: *const Session) bool {
        return s.gate() or s.orchestrator();
    }

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

pub const BoardView = struct {
    /// The column and the card in it picked.
    col: usize = 0,
    row: usize = 0,
    /// The repo it is narrowed to: 0 for every one, else its place in the board's repos from 1.
    repo: usize = 0,
    /// The backlog shown as the one column, in place of the four.
    backlog: bool = false,
    /// The picked card's question shown over the board, waiting on its answer's number.
    answering: bool = false,
    /// The ticket whose whole detail is shown over the board, and how far down it is scrolled.
    detail: ?u32 = null,
    detail_scroll: usize = 0,
    /// The board's keys shown over it, until the next key.
    help: bool = false,
};

/// The cards a column of the board can hold, and the repos it can be narrowed to.
pub const max_cards = 256;
const max_repos = 32;

fn anyKey(pressed: []const u8, names: []const []const u8) bool {
    for (names) |name| if (std.mem.eql(u8, pressed, name)) return true;
    return false;
}

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
    /// babylon's board, as its file was last read; null while there is none.
    board: ?tickets.Board = null,
    /// The board while it is open in place of the strip.
    board_view: ?BoardView = null,
    /// The orchestrator was asked to start: gone to as soon as its session shows.
    orchestrating: bool = false,
    rail: enum { wide, narrow } = .wide,
    /// The narrow rail drawn wide over the strip, while the pointer is on it.
    peek: bool = false,
    /// The pointer is on the row under the strip, which then has the windows' names for dots.
    over_dots: bool = false,
    agent_sort: AgentSort = .urgency,
    /// When the pointer came to rest on the narrow rail; 0 while it is elsewhere.
    hover_at: i64 = 0,
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
    /// The strip's height: the terminal's, less the row of dots under it.
    view_h: u16 = 23,
    pending: std.ArrayList(Pending) = .empty,
    /// The open reply's guard, its time and number, which its end repeats.
    guard: std.ArrayList(u8) = .empty,
    in_block: bool = false,
    /// Whether the open reply answers a command arena sent: tmux also writes replies to
    /// commands it ran itself for the client, as the attach, which answer nothing pending.
    block_mine: bool = false,
    block: std.ArrayList(u8) = .empty,
    /// The text of the ticket the board shows the detail of, as babylon gave it.
    detail: std.ArrayList(u8) = .empty,
    /// Where babylon keeps its board file, and where a card's detail is written to be read.
    board_dir: ?[]const u8 = null,
    /// The tickets whose detail babylon was asked to write and arena has yet to take in.
    detail_asked: std.ArrayList(u32) = .empty,
    want_list: bool = true,
    listing: bool = false,
    listed: bool = false,
    dirty: bool = true,
    quit: bool = false,
    /// tmux ended the client, as it does when the session it was on ends.
    ended: bool = false,
    /// Milliseconds on a clock that only goes forward, set each turn of the loop.
    now: i64 = 0,
    /// Seconds since the epoch, set each turn of the loop.
    epoch: i64 = 0,
    /// What the held left button is moving: the line after a pane, to resize it, a window by
    /// its title, along the strip, or a session by its name, along the rail.
    drag: union(enum) {
        none,
        divider: struct { pane: u32, upright: bool, asked: i32 = -1 },
        title: u32,
        /// A window by its picture in the overview.
        thumb: u32,
        session: u32,
        /// Text being selected in a pane, from the cell of it the button went down on.
        select: struct { pane: u32, x: u16, y: u16 },
        /// A click that focused a window: its program gets none of it, not even the let go.
        focus,
    } = .none,
    /// The session the open menu asks about closing.
    doomed: u32 = 0,
    /// The pointer's shape, as the terminal was last told.
    shape: []const u8 = "default",
    /// Where the mouse last was.
    pointer: struct { x: u16 = 0, y: u16 = 0 } = .{},
    /// Bytes for the terminal arena runs in, written out after the next frame.
    out: std.ArrayList(u8) = .empty,
    /// A piece of a pane's output without what it passes to the terminal, between `Pass` and the pane.
    plain: std.ArrayList(u8) = .empty,
    /// The pane that last sent a graphics command, which the terminal's replies go back to: the
    /// terminal does not say which pane asked.
    asker: u32 = std.math.maxInt(u32),
    /// Counts the terminal's answers for its foreground and background; 0 until the first.
    colors_known: u32 = 0,
    /// The name last clicked, a window's or a session's, and when.
    clicked: ?Name = null,
    clicked_at: i64 = 0,
    nav_at: i64 = 0,
    /// When the wheel last went up or down.
    vertical_at: i64 = 0,
    /// The swipe going sideways now: when its last event came, how far it has gone, signed, and
    /// whether it has stepped.
    sideways_at: i64 = 0,
    sideways_run: i32 = 0,
    swiped: bool = false,

    pub fn deinit(app: *App) void {
        for (app.sessions.items) |s| app.destroySession(s);
        app.sessions.deinit(app.gpa);
        app.pending.deinit(app.gpa);
        app.block.deinit(app.gpa);
        app.detail.deinit(app.gpa);
        app.detail_asked.deinit(app.gpa);
        app.guard.deinit(app.gpa);
        app.out.deinit(app.gpa);
        app.plain.deinit(app.gpa);
        if (app.board) |*b| b.deinit();
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
        return win.claude;
    }

    /// The most pressing mark among a session's windows, the one in view included.
    pub fn sessionMark(s: *const Session) Mark {
        var most: Mark = .none;
        for (s.wins.items) |win| {
            if (@backingInt(win.claude) > @backingInt(most)) most = win.claude;
        }
        return most;
    }

    /// How many of a session's windows have its most pressing mark.
    pub fn sessionCount(s: *const Session) usize {
        const most = sessionMark(s);
        var count: usize = 0;
        for (s.wins.items) |win| count += @intFromBool(win.claude == most);
        return count;
    }

    /// The most pressing alert among a session's windows.
    pub fn sessionAlert(s: *const Session) Alert {
        var most: Alert = .none;
        for (s.wins.items) |win| {
            if (@backingInt(win.alert) > @backingInt(most)) most = win.alert;
        }
        return most;
    }

    /// The most pressing review state among a session's windows.
    pub fn sessionReview(s: *const Session) Review {
        var most: Review = .none;
        for (s.wins.items) |win| {
            if (@backingInt(win.review) > @backingInt(most)) most = win.review;
        }
        return most;
    }

    pub const Agent = struct { session: usize, win: *Window };
    /// How lists of agents are ordered: the one that most wants looking at first, or the one
    /// heard from last.
    pub const AgentSort = enum { urgency, recent };

    /// The windows with a Claude, as many as `out` holds, grouped by session, as `agent_sort`
    /// has them: the session with the first of its Claudes first, then in the rail's order.
    pub fn agents(app: *const App, out: []Agent) usize {
        var n: usize = 0;
        for (app.sessions.items, 0..) |s, si| for (s.wins.items) |win| {
            if (s.offRail()) break;
            if (!win.agent() or n == out.len) continue;
            out[n] = .{ .session = si, .win = win };
            n += 1;
        };
        std.sort.insertion(Agent, out[0..n], app, agentBefore);
        return n;
    }

    fn agentBefore(app: *const App, a: Agent, b: Agent) bool {
        if (a.session != b.session) {
            const ra = app.sessionRank(a.session);
            const rb = app.sessionRank(b.session);
            return ra > rb or (ra == rb and a.session < b.session);
        }
        return app.agentRank(a.win) > app.agentRank(b.win);
    }

    /// Where a Claude goes in a list, as `agent_sort` has it: the higher, the sooner.
    fn agentRank(app: *const App, win: *const Window) u64 {
        // a Claude never heard from counts as the newest
        const last = @max(win.at, win.since);
        return switch (app.agent_sort) {
            .urgency => urgency(win),
            .recent => if (last == 0) std.math.maxInt(u32) else last,
        };
    }

    /// The more pressing its state, the higher; of those alike, the longer in it.
    fn urgency(win: *const Window) u64 {
        const since: u64 = if (win.since == 0) std.math.maxInt(u32) else win.since;
        return @as(u64, @backingInt(win.claude)) << 32 | (std.math.maxInt(u32) - since);
    }

    fn sessionRank(app: *const App, si: usize) u64 {
        var best: u64 = 0;
        for (app.sessions.items[si].wins.items) |win| if (win.agent()) {
            best = @max(best, app.agentRank(win));
        };
        return best;
    }

    /// A row of a list of agents: a session's name over its own, a window with a Claude, its
    /// `Window.detail`, its branch, review and context, what it has running in the background, or
    /// how many more there are than rows.
    pub const AgentLine = union(enum) { session: usize, agent: Agent, detail: Agent, meta: Agent, background: Agent, more: usize };

    /// The agents in at most `room` rows of `out`, as `agents` orders them, with each one's
    /// detail, its branch, review and context, and its background under it when `details`, where
    /// it has them.
    pub fn agentLines(app: *const App, out: []AgentLine, room: usize, details: bool) usize {
        var found: [64]Agent = undefined;
        const count = app.agents(&found);
        const rows = @min(out.len, room);
        if (rows == 0) return 0;
        var n: usize = 0;
        var last: ?usize = null;
        for (found[0..count]) |a| {
            if (n == rows) break;
            // a Claude's rows go together: past the first, one they do not all fit is left to the count
            const rest = @as(usize, @intFromBool(details and a.win.detail().len > 0)) +
                @intFromBool(details and (a.win.text(.branch).len > 0 or a.win.review != .none or a.win.tokens > 0)) +
                @intFromBool(details and a.win.text(.background).len > 0);
            if (n > 0 and n + @intFromBool(last != a.session) + 1 + rest > rows) break;
            if (last != a.session) {
                out[n] = .{ .session = a.session };
                n += 1;
                last = a.session;
            }
            if (n == rows) break;
            out[n] = .{ .agent = a };
            n += 1;
            if (details and n < rows and a.win.detail().len > 0) {
                out[n] = .{ .detail = a };
                n += 1;
            }
            if (details and n < rows and (a.win.text(.branch).len > 0 or a.win.review != .none or a.win.tokens > 0)) {
                out[n] = .{ .meta = a };
                n += 1;
            }
            if (details and n < rows and a.win.text(.background).len > 0) {
                out[n] = .{ .background = a };
                n += 1;
            }
        }
        var shown: usize = 0;
        for (out[0..n]) |line| shown += @intFromBool(line == .agent);
        if (shown < count) {
            if (n == rows) {
                if (out[n - 1] == .agent) shown -= 1;
                n -= 1;
            }
            out[n] = .{ .more = count - shown };
            n += 1;
        }
        return n;
    }

    /// The rail's agents, as many as have rows, with their details while the rail is drawn wide.
    pub fn railAgents(app: *const App, out: []AgentLine) usize {
        return app.agentLines(out, app.railAgentRows(), app.railDrawnW() == app.railWideW());
    }

    /// The row of the rail's agents at row `y`, null for any other row.
    fn railAgentAt(app: *const App, y: u16) ?AgentLine {
        var lines: [64]AgentLine = undefined;
        const n = app.railAgents(&lines);
        const top = app.railAgentsRow() + 1;
        return if (y >= top and y - top < n) lines[y - top] else null;
    }

    fn goAgent(app: *App, a: Agent) !void {
        app.dirty = true;
        const s = app.sessions.items[a.session];
        const index = std.mem.indexOfScalar(*Window, s.wins.items, a.win) orelse return;
        try app.jumpTo(s, index);
    }

    /// Steps `by` through the Claudes waiting or done, the one that most wants looking at first:
    /// from the one in view to the next or the one before, round; from any other window, to the
    /// first or the last.
    fn stepAgent(app: *App, by: i32) !void {
        var found: [64]Agent = undefined;
        var n: usize = 0;
        for (app.sessions.items, 0..) |s, si| for (s.wins.items) |win| {
            if ((win.claude != .waiting and win.claude != .done) or n == found.len) continue;
            found[n] = .{ .session = si, .win = win };
            n += 1;
        };
        if (n == 0) return;
        std.sort.insertion(Agent, found[0..n], {}, struct {
            fn before(_: void, a: Agent, b: Agent) bool {
                return urgency(a.win) > urgency(b.win);
            }
        }.before);
        const s = app.cur();
        const here = for (found[0..n], 0..) |a, i| {
            if (s != null and app.sessions.items[a.session] == s.? and s.?.focused() == a.win) break i;
        } else null;
        const len: i32 = @intCast(n);
        const to: i32 = if (here) |i| @mod(@as(i32, @intCast(i)) + by, len) else if (by > 0) 0 else len - 1;
        try app.goAgent(found[@intCast(to)]);
    }

    fn toggleRail(app: *App) void {
        app.rail = if (app.rail == .wide) .narrow else .wide;
        app.peek = false;
        app.fit();
        app.want_list = true;
        app.dirty = true;
    }

    fn toggleSort(app: *App) void {
        app.agent_sort = if (app.agent_sort == .urgency) .recent else .urgency;
        app.dirty = true;
    }

    /// The pointer moved with no button held: resting on the narrow rail draws it wide over the
    /// strip, after `dwell`, and leaving it draws it narrow again.
    fn hoverRail(app: *App, x: u16) void {
        if (app.rail == .wide or app.railW() == 0) return;
        if (x < app.railDrawnW()) {
            if (app.hover_at == 0 and !app.peek) app.hover_at = app.now;
            return;
        }
        app.hover_at = 0;
        if (app.peek) {
            app.peek = false;
            app.dirty = true;
        }
    }

    /// Draws the narrow rail wide once the pointer has rested on it long enough. Returns how
    /// long until it would.
    pub fn dwell(app: *App) i64 {
        if (app.hover_at == 0 or app.overlay()) return std.math.maxInt(i64);
        const left = app.hover_at + dwell_ms - app.now;
        if (left > 0) return left;
        app.hover_at = 0;
        app.peek = true;
        app.dirty = true;
        return std.math.maxInt(i64);
    }

    /// Whether a Claude is working in any window, its mark spinning.
    pub fn working(app: *const App) bool {
        for (app.sessions.items) |s| for (s.wins.items) |win| if (win.claude == .working) return true;
        return false;
    }

    /// A Claude done in the window in view has been looked at: its pane's state is cleared in
    /// tmux, unless a hook has moved it on since.
    fn see(app: *App) !void {
        const s = app.cur() orelse return;
        const win = s.focused() orelse return;
        if (win.claude != .done) return;
        win.claude = .none;
        // Not `if`: a command it runs has a reply of its own, which arena would take for the
        // reply to the next command it sent.
        for (win.panes.items) |pane| try app.send(
            .ignore,
            "set -pF -t %{d} @arena_claude '#{{?#{{==:#{{@arena_claude}},done}},,#{{@arena_claude}}}}'",
            .{pane.id},
        );
    }

    fn toggleFull(app: *App) void {
        const s = app.cur() orelse return;
        s.full = !s.full;
        app.want_list = true;
        app.dirty = true;
    }

    /// The session rail's width, the same whatever its names, so the strip does not move when a
    /// Claude comes or goes. A terminal too narrow for it has none.
    /// Narrow, the rail shows a session by two letters, and a Claude by its mark and time.
    pub fn railW(app: *const App) u16 {
        if (app.term_w < 48 or app.sessions.items.len == 0) return 0;
        return if (app.rail == .wide) app.railWideW() else rail_narrow;
    }

    pub fn railWideW(app: *const App) u16 {
        return @min(rail_wide, @max(rail_narrow, app.term_w / 3));
    }

    /// The rail's width as drawn, which a narrow one peeking is not.
    pub fn railDrawnW(app: *const App) u16 {
        return if (app.peek and app.railW() > 0) app.railWideW() else app.railW();
    }

    pub fn fit(app: *App) void {
        const rail = app.railW();
        app.view_w = app.term_w - if (rail > 0) rail + 1 else 0;
    }

    /// A new terminal size, with its cells' in pixels when the terminal says (0 when not):
    /// every strip is put in place again once tmux has been told.
    pub fn resized(app: *App, cols: u16, rows: u16, cell_w: u16, cell_h: u16) !void {
        app.term_w = cols;
        app.view_h = @max(1, rows -| 1);
        app.fit();
        // A tmux without the pixels patch refuses the second, and keeps the first.
        try app.send(.ignore, "refresh-client -C {d}x{d}", .{ cols, rows });
        if (cell_w > 0 and cell_h > 0)
            try app.send(.ignore, "refresh-client -C {d}x{d},{d}x{d}", .{ cols, rows, cell_w, cell_h });
        for (app.sessions.items) |s| s.placed = false;
        app.want_list = true;
    }

    pub fn requestList(app: *App) !void {
        app.want_list = false;
        app.listing = true;
        try app.send(.sessions, "list-sessions -F '" ++ session_format ++ "'", .{});
        try app.send(.panes, "list-panes -a -F '" ++ pane_format ++ "'", .{});
    }

    pub fn onLine(app: *App, line: []u8) !void {
        switch (control.parse(line, if (app.in_block) app.guard.items else null)) {
            .begin => |open| {
                app.in_block = true;
                app.block_mine = open.mine;
                app.guard.clearRetainingCapacity();
                try app.guard.appendSlice(app.gpa, open.guard);
                app.block.clearRetainingCapacity();
            },
            .body => |body| {
                try app.block.appendSlice(app.gpa, body);
                try app.block.append(app.gpa, '\n');
            },
            .end => {
                app.in_block = false;
                if (!app.block_mine) return;
                const kind: Pending = if (app.pending.items.len > 0) app.pending.orderedRemove(0) else .ignore;
                try app.onReply(kind, app.block.items);
            },
            .output => |out| {
                const pane = app.paneById(out.pane) orelse return;
                app.plain.clearRetainingCapacity();
                const before = app.out.items.len;
                try pane.pass.feed(app.gpa, control.unescape(@constCast(out.data)), &app.out, &app.plain);
                if (app.out.items.len > before) app.asker = pane.id;
                if (pane.seed != .done) return;
                pane.feed(app.plain.items);
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
                if (a.offRail() != b.offRail()) return b.offRail();
                // tmux lists sessions by name: with no place of their own, the oldest first
                return a.order < b.order or (a.order == b.order and a.id < b.id);
            }
        }.before);
        app.fit();
        if (app.orchestrating) if (app.orchestratorSession()) |at| {
            app.orchestrating = false;
            try app.sessionTo(at);
        };
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
            var n: [23]u32 = undefined;
            for (&n, 0..) |*field, i| {
                const token = it.next() orelse break;
                field.* = std.fmt.parseInt(u32, token[@intFromBool(i < 3)..], 10) catch break;
            } else {
                const rest = it.rest();
                var tabs: usize = 0;
                const cut = for (rest, 0..) |c, i| {
                    tabs += @intFromBool(c == '\t');
                    if (tabs == std.enums.values(Window.Info).len) break i;
                } else rest.len;
                const info = rest[0..cut];
                const name = if (cut < rest.len) rest[cut + 1 ..] else "";
                const s = app.sessionById(n[0]) orelse continue;
                const last = s.wins.getLastOrNull();
                const win = if (last != null and last.?.id == n[1]) last.? else blk: {
                    const win = for (old_wins.items, 0..) |known, i| {
                        if (known.id == n[1]) {
                            known.was = known.claude;
                            break old_wins.swapRemove(i);
                        }
                    } else made: {
                        const made = try app.gpa.create(Window);
                        made.* = .{ .id = n[1] };
                        break :made made;
                    };
                    app.gpa.free(win.name);
                    win.name = try app.gpa.dupe(u8, name);
                    win.w = @intCast(n[3]);
                    win.h = @intCast(n[4]);
                    win.cell_w = @intCast(n[12]);
                    win.cell_h = @intCast(n[13]);
                    win.claude = .none;
                    win.review = .none;
                    win.alert = @fromBackingInt(@intCast(@min(n[22], @backingInt(Alert.bell))));
                    try win.know(app.gpa, 0, 0, 0, 0, 0, "");
                    // Read once: after that arena's own is the newer, and a list asked for
                    // before a change would put the old one back.
                    if (!win.listed) win.share = @intCast(@min(n[14], max_share));
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
                const said: Mark = @fromBackingInt(@intCast(@min(n[11], @backingInt(Mark.waiting))));
                // between turns with a subagent of its at work is working: only a shell left running is not
                const claude: Mark = if (said == .background and n[21] != 0 and app.epoch - n[21] < stir_s) .working else said;
                const agent = n[16] != 0 or claude != .none;
                if (agent and (!win.agent() or @backingInt(claude) > @backingInt(win.claude))) {
                    try win.know(app.gpa, n[16], n[17], n[18], n[19], n[20], info);
                    win.agent_pane = n[2];
                }
                if (@backingInt(claude) > @backingInt(win.claude)) win.claude = claude;
                const review = Review.of(n[15]);
                if (@backingInt(review) > @backingInt(win.review)) win.review = review;
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
        try app.tellColors();
        for (old_wins.items) |win| win.destroy(app.gpa);

        for (app.sessions.items, 0..) |s, i| {
            const follow = app.follow_active and s.id == app.current;
            if (!follow and i < focus_ids.items.len) if (focus_ids.items[i]) |id| for (s.wins.items, 0..) |win, at| {
                if (win.id == id) s.focus = at;
            };
            if (!s.placed) s.scroll = app.target(s);
            s.placed = true;
        }
        try app.notify();
        app.follow_active = false;
        try app.see();
        try app.settle();
        if (app.cur()) |s| app.listed = app.listed or s.wins.items.len > 0;
        app.dirty = true;
    }

    /// A desktop notification for each Claude come to wait on an answer or done since the list
    /// before, other than the one in view: notify-send, where there is one, run by tmux, which
    /// quotes the hook's text for the shell itself.
    fn notify(app: *App) !void {
        for (app.sessions.items) |s| for (s.wins.items) |win| {
            const was = win.was orelse continue;
            if (win.claude == was or (win.claude != .waiting and win.claude != .done)) continue;
            if (s.id == app.current and s.focused() == win) continue;
            try app.send(.ignore, "run-shell -b -t %{d} \"command -v notify-send >/dev/null && notify-send -a arena -- " ++
                "#{{?@arena_claude_title,#{{q:@arena_claude_title}},#{{q:window_name}}}} {s}\"", .{
                win.agent_pane,
                if (win.claude == .waiting) "#{q:@arena_claude_doing}" else "#{q:@arena_claude_said}",
            });
        };
    }

    /// The cells of each window's tab on the row under the strip: its number, a space, its name
    /// cut to `tab_name`, a space and a cell for its mark. Empty past `max_tabs` windows.
    pub fn tabWidths(s: *const Session, out: *[max_tabs]usize) []const usize {
        if (s.wins.items.len > max_tabs) return &.{};
        for (s.wins.items, 0..) |win, i| {
            const name = std.unicode.utf8CountCodepoints(win.name) catch win.name.len;
            out[i] = std.fmt.count("{d}", .{i + 1}) + 1 + @min(name, tab_name) + 2;
        }
        return out[0..s.wins.items.len];
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
                    try app.send(.ignore, "refresh-client -C @{d}:{d}x{d}", .{ win.id, cols, rows });
                    continue;
                }
                for (win.panes.items) |pane| {
                    if (pane.seed != .wanted) continue;
                    pane.seed = .asked;
                    // One list, which tmux runs without reading the pane between: output it read
                    // between the capture and the cursor would be drawn here at the wrong place.
                    try app.send(.{ .modes = pane.id }, "display-message -p -t %{d} '" ++ mode_flags ++ "' ; " ++
                        "capture-pane -p -e -S -{d} -t %{d} ; " ++
                        "display-message -p -t %{d} '#{{cursor_x}} #{{cursor_y}}'", .{ pane.id, history_lines, pane.id, pane.id });
                    try app.pending.append(app.gpa, .{ .capture = pane.id });
                    try app.pending.append(app.gpa, .{ .cursor = pane.id });
                }
            }
        }
    }

    fn sessionBy(app: *App, delta: i32) !void {
        const at = app.sessionIndex(app.current) orelse return;
        const next = @as(i32, @intCast(at)) + delta;
        if (next < 0 or next >= app.railSessions()) return;
        try app.sessionTo(@intCast(next));
    }

    fn sessionTo(app: *App, index: usize) !void {
        const to = app.sessions.items[index];
        if (to.id == app.current) return;
        try app.see();
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
        try app.see();
        s.focus = index;
        try app.send(.ignore, "select-window -t @{d}", .{s.wins.items[index].id});
        app.dirty = true;
    }

    const Name = union(enum) { window: u32, session: u32, pane: u32 };

    /// What ends a word picked by two clicks.
    const word_ends = [_]u21{ ' ', '\t', '\'', '"', '`', '|', '│', ':', ';', ',', '(', ')', '[', ']', '{', '}', '<', '>', '$' };

    /// Puts the pane's selected text on the system clipboard and the primary selection, through
    /// the terminal.
    fn copy(app: *App, pane: *Pane) !void {
        const screen = pane.term.screens.active;
        const sel = screen.selection orelse return;
        const text = try screen.selectionString(app.gpa, .{ .sel = sel, .trim = true });
        defer app.gpa.free(text);
        if (text.len == 0) return;
        const encoder = std.base64.standard.Encoder;
        for ([_][]const u8{ "\x1b]52;c;", "\x1b]52;p;" }) |intro| {
            try app.out.appendSlice(app.gpa, intro);
            _ = encoder.encode(try app.out.addManyAsSlice(app.gpa, encoder.calcSize(text.len)), text);
            try app.out.append(app.gpa, 0x07);
        }
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
        if (session < first or session >= first + shown or session >= app.railSessions()) return null;
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
        const count = app.railSessions();
        if (count == 0) {
            app.overview = null;
            return;
        }
        const spot = &app.overview.?;
        spot.session = @min(spot.session, count - 1);
        const is = anyKey;
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

    /// The board file's text as read now: the board it holds takes the place of the one before;
    /// there is none when there is no file or it does not parse.
    pub fn setBoard(app: *App, text: ?[]const u8) void {
        if (app.board) |*b| b.deinit();
        app.board = if (text) |t| tickets.Board.parse(app.gpa, t) catch null else null;
        if (app.board == null) app.board_view = null;
        app.dirty = true;
    }

    fn toggleBoard(app: *App) void {
        app.board_view = if (app.board_view != null or app.board == null) null else .{};
        app.dirty = true;
    }

    /// The repo the open board is narrowed to; null for every one.
    pub fn boardRepo(app: *const App) ?[]const u8 {
        const view = app.board_view orelse return null;
        if (view.repo == 0 or view.backlog) return null;
        const b = if (app.board) |*b| b else return null;
        var repos: [max_repos][]const u8 = undefined;
        const n = b.repos(&repos);
        return if (view.repo <= n) repos[view.repo - 1] else null;
    }

    /// The rows the card's detail takes in its box.
    pub fn detailRows(app: *const App) usize {
        var lines = DetailLines.init(if (app.detail.items.len > 0) app.detail.items else "…", detailWidth(app.view_w).inner);
        var n: usize = 0;
        while (lines.next()) |_| n += 1;
        return n;
    }

    /// Where babylon writes ticket `id`'s detail for the board to read.
    pub fn detailPath(app: *const App, id: u32, buf: []u8) ?[]const u8 {
        const dir = app.board_dir orelse return null;
        return std.fmt.bufPrint(buf, "{s}/detail-{d}.txt", .{ dir, id }) catch null;
    }

    /// The cards of the board's column `col` as it is narrowed, as many as fit in `out`; the
    /// count of them all.
    pub fn boardColumn(app: *const App, col: usize, out: []*const tickets.Card) usize {
        const b = if (app.board) |*b| b else return 0;
        if (app.boardBacklog()) {
            for (b.backlog(), 0..) |*card, i| if (i < out.len) {
                out[i] = card;
            };
            return b.backlog().len;
        }
        return b.column(tickets.statuses[col], app.boardRepo(), out);
    }

    fn boardBacklog(app: *const App) bool {
        const view = app.board_view orelse return false;
        return view.backlog;
    }

    /// The columns the open board shows: the four statuses, or the backlog alone.
    pub fn boardCols(app: *const App) usize {
        return if (app.boardBacklog()) 1 else tickets.statuses.len;
    }

    /// The cards in `status` on the whole board, whatever it is narrowed to.
    pub fn boardCount(app: *const App, status: tickets.Status) usize {
        const b = if (app.board) |*b| b else return 0;
        return b.column(status, null, &.{});
    }

    pub fn boardCard(app: *const App, col: usize, row: usize) ?*const tickets.Card {
        var out: [max_cards]*const tickets.Card = undefined;
        const n = app.boardColumn(col, &out);
        return if (row < @min(n, max_cards)) out[row] else null;
    }

    /// The board's four columns side by side under a row of its own; in each, a card is two
    /// rows with one between, from the second row inside its border.
    pub fn boardColW(app: *const App) u16 {
        return app.view_w / @as(u16, @intCast(app.boardCols()));
    }

    pub fn boardShown(app: *const App) usize {
        return @max(1, (app.view_h -| 2) / 3);
    }

    /// The first card column `col` shows: the picked card's column scrolls to keep it in view.
    pub fn boardFirst(app: *const App, col: usize) usize {
        const view = app.board_view orelse return 0;
        const shown = app.boardShown();
        return if (col == view.col and view.row >= shown) view.row - shown + 1 else 0;
    }

    fn boardCardAt(app: *const App, x: u16, y: u16) ?struct { col: usize, row: usize } {
        const ox = app.term_w - app.view_w;
        if (x < ox or y < 2) return null;
        const col: usize = (x - ox) / @max(1, app.boardColW());
        const k: usize = (y - 2) / 3;
        if (col >= app.boardCols() or (y - 2) % 3 == 2 or k >= app.boardShown()) return null;
        const row = app.boardFirst(col) + k;
        return if (row < app.boardColumn(col, &.{})) .{ .col = col, .row = row } else null;
    }

    /// The window with pane `id` in it, and that window's place in its session.
    pub fn paneWindow(app: *const App, id: u32) ?struct { session: *Session, index: usize } {
        for (app.sessions.items) |s| for (s.wins.items, 0..) |win, wi| for (win.panes.items) |pane| {
            if (pane.id == id) return .{ .session = s, .index = wi };
        };
        return null;
    }

    /// Goes to the Claude holding the card picked, closing the board; nothing when none does.
    fn goCard(app: *App) !void {
        const view = app.board_view orelse return;
        const card = app.boardCard(view.col, view.row) orelse return;
        const pane = card.holder() orelse {
            if (!startable(card)) return;
            const repo = card.repo.?;
            var named: [64]u8 = undefined;
            const session = sessionNamed(repo, &named);
            // tmux reads # as a format in run-shell's command: ## is one #. A second go before the
            // claim shows finds the window the first made
            try app.send(.ignore, "run-shell -b \"tmux has-session -t ={s} 2>/dev/null || tmux new-session -d -s {s} -c $HOME/projects/{s}; " ++
                "tmux list-windows -t ={s} -F '##{{window_name}}' | grep -qx t{d} || " ++
                "tmux new-window -t ={s}: -n t{d} -c $HOME/projects/{s} claude 'Claim ticket ##{d} with claim_ticket, run the start command its answer gives, and work it to submit_ticket.'\"", .{ session, session, repo, session, card.id, session, card.id, repo, card.id });
            app.board_view = null;
            app.dirty = true;
            return;
        };
        const at = app.paneWindow(pane) orelse return;
        app.board_view = null;
        app.dirty = true;
        try app.send(.ignore, "select-pane -t %{d}", .{pane});
        try app.jumpTo(at.session, at.index);
    }

    /// A key on the board: h, l and the arrows go between columns, j and k along one, r narrows
    /// it to the next repo and from the last back to every one, Enter goes to the Claude holding
    /// the card picked or starts one on a free todo card, Escape and q close.
    fn boardKey(app: *App, key: []const u8) !void {
        app.dirty = true;
        const view = &app.board_view.?;
        const is = anyKey;
        if (view.answering) return app.answerKey(key);
        if (view.help) {
            view.help = false;
            return;
        }
        if (view.detail != null) {
            if (is(key, &.{ "\x1b", "q", " " })) view.detail = null;
            if (is(key, &.{ "j", "\x1b[B", "\x1bOB" }) and view.detail_scroll + 1 < app.detailRows()) view.detail_scroll += 1;
            if (is(key, &.{ "k", "\x1b[A", "\x1bOA" })) view.detail_scroll -|= 1;
            return;
        }
        var buf: [std.fs.max_path_bytes]u8 = undefined;
        if (is(key, &.{" "})) if (app.boardCard(view.col, view.row)) |card| if (app.detailPath(card.id, &buf)) |path| {
            // tmux gives a control client run-shell's output outside its reply, so it comes by a file
            std.Io.Dir.cwd().deleteFile(app.io, path) catch {};
            if (app.detail_asked.items.len == 16) _ = app.detail_asked.orderedRemove(0);
            try app.detail_asked.append(app.gpa, card.id);
            view.detail = card.id;
            view.detail_scroll = 0;
            app.detail.clearRetainingCapacity();
            try app.send(.ignore, "run-shell -b \"babylon detail {d} >'{s}.part' 2>&1; mv '{s}.part' '{s}'\"", .{ card.id, path, path, path });
            return;
        };
        if (is(key, &.{"?"})) {
            view.help = true;
            return;
        }
        if (is(key, &.{"a"})) return app.act(.answer);
        if (is(key, &.{ "h", "\x1b[D", "\x1bOD" })) view.col -|= 1;
        if (is(key, &.{ "l", "\x1b[C", "\x1bOC" }) and view.col + 1 < app.boardCols()) view.col += 1;
        if (is(key, &.{ "k", "\x1b[A", "\x1bOA" })) view.row -|= 1;
        if (is(key, &.{ "j", "\x1b[B", "\x1bOB" })) view.row += 1;
        if (is(key, &.{"r"})) {
            var repos: [max_repos][]const u8 = undefined;
            const n = if (app.board) |*b| b.repos(&repos) else 0;
            if (view.backlog) {
                view.backlog = false;
                view.repo = 0;
            } else if (view.repo == n) {
                view.backlog = true;
                view.col = 0;
            } else view.repo += 1;
            view.row = 0;
        }
        view.row = @min(view.row, app.boardColumn(view.col, &.{}) -| 1);
        if (is(key, &.{ "\x1b", "q" })) app.board_view = null;
        if (is(key, &.{"g"})) return app.toGate();
        if (is(key, &.{"o"})) return app.toOrchestrator();
        if (is(key, &.{"n"})) return app.newTicket();
        const keyed = [_]struct { []const u8, CardAction }{
            .{ "\r", .go },    .{ "e", .edit }, .{ "p", .priority }, .{ ">", .close },
            .{ "<", .reopen }, .{ "J", .down }, .{ "K", .up },       .{ "t", .to_todo },
        };
        for (keyed) |pair| if (std.mem.eql(u8, key, pair[0])) return app.act(pair[1]);
    }

    fn toGate(app: *App) !void {
        const at = app.gateSession() orelse return;
        app.board_view = null;
        try app.sessionTo(at);
    }

    /// To the orchestrator, started first when it is not running and gone to once its session shows.
    fn toOrchestrator(app: *App) !void {
        app.board_view = null;
        app.dirty = true;
        if (app.orchestratorSession()) |at| return app.sessionTo(at);
        app.orchestrating = true;
        try app.send(.ignore, "run-shell -b \"babylon orchestrator\"", .{});
    }

    fn newTicket(app: *App) !void {
        var buf: [80]u8 = undefined;
        const narrowed = if (app.boardRepo()) |r| (if (plainName(r)) std.fmt.bufPrint(&buf, " --repo {s}", .{r}) catch "" else "") else "";
        try app.ticketWindow("babylon new{s}", .{narrowed});
    }

    /// What can be done to a card from the board, by its key or its chip.
    pub const CardAction = enum {
        go,
        answer,
        edit,
        priority,
        close,
        reopen,
        to_todo,
        up,
        down,

        pub fn label(action: CardAction) []const u8 {
            return switch (action) {
                .go => "go",
                .answer => "answer",
                .edit => "edit",
                .priority => "priority",
                .close => "close",
                .reopen => "reopen",
                .to_todo => "to todo",
                .up => "↑",
                .down => "↓",
            };
        }
    };

    /// The actions `card` has: go while a Claude holds it, answer while it asks, close while still to
    /// do and reopen once done, to todo while in the backlog, and edit and priority always, and
    /// moving it along its column but in the backlog.
    pub fn cardActions(card: *const tickets.Card, out: *[8]CardAction) []CardAction {
        var n: usize = 0;
        const all = [_]struct { CardAction, bool }{
            .{ .go, card.holder() != null or startable(card) }, .{ .answer, card.ask != null },    .{ .edit, true },
            .{ .priority, true },                               .{ .close, card.status == .todo }, .{ .reopen, card.status == .done },
            .{ .to_todo, card.status == .backlog },             .{ .up, card.status != .backlog }, .{ .down, card.status != .backlog },
        };
        for (all) |pair| if (pair[1]) {
            out[n] = pair[0];
            n += 1;
        };
        return out[0..n];
    }

    /// Edit opens $EDITOR in a window of its own; priority goes from low up to high and round;
    /// close and reopen move a ticket between to do and done, the columns between being a claim's
    /// and the pipeline's; up and down move it along its column, the pick going with it. Each
    /// through babylon's command line. An action the picked card has not does nothing.
    fn act(app: *App, action: CardAction) !void {
        const view = if (app.board_view) |*open| open else return;
        const card = app.boardCard(view.col, view.row) orelse return;
        var have: [8]CardAction = undefined;
        if (std.mem.indexOfScalar(CardAction, cardActions(card, &have), action) == null) return;
        var buf: [80]u8 = undefined;
        const narrowed = if (app.boardRepo()) |r| (if (plainName(r)) std.fmt.bufPrint(&buf, " --repo {s}", .{r}) catch "" else "") else "";
        switch (action) {
            .go => try app.goCard(),
            .answer => view.answering = true,
            .edit => try app.ticketWindow("babylon edit {d}", .{card.id}),
            .priority => {
                const eql = std.mem.eql;
                const next = if (eql(u8, card.priority, "low")) "med" else if (eql(u8, card.priority, "med")) "high" else "low";
                try app.send(.ignore, "run-shell -b \"babylon update {d} --priority {s}\"", .{ card.id, next });
            },
            .close => try app.send(.ignore, "run-shell -b \"babylon update {d} --status done\"", .{card.id}),
            .reopen, .to_todo => try app.send(.ignore, "run-shell -b \"babylon update {d} --status todo\"", .{card.id}),
            .up, .down => {
                const down = action == .down;
                try app.send(.ignore, "run-shell -b \"babylon move {d} {s}{s}\"", .{ card.id, if (down) "down" else "up", narrowed });
                view.row = if (down) @min(view.row + 1, app.boardColumn(view.col, &.{}) -| 1) else view.row -| 1;
            },
        }
    }

    /// A button on the board, where it is drawn and clicked: 0-based, as the mouse has it.
    pub const Button = struct {
        what: union(enum) { repo: usize, backlog, gate, orchestrator, new, card: CardAction },
        x: u16,
        y: u16,
        w: u16,
    };

    pub fn buttonLabel(app: *const App, what: @FieldType(Button, "what"), buf: []u8) []const u8 {
        return switch (what) {
            .repo => |i| blk: {
                if (i == 0) break :blk " every ";
                var repos: [max_repos][]const u8 = undefined;
                const n = if (app.board) |*b| b.repos(&repos) else 0;
                break :blk if (i <= n) std.fmt.bufPrint(buf, " {s} ", .{repos[i - 1]}) catch " ? " else " ? ";
            },
            .backlog => " backlog ",
            .gate => " gate ",
            .orchestrator => " orch ",
            .new => " + ",
            .card => |action| std.fmt.bufPrint(buf, " {s} ", .{action.label()}) catch " ? ",
        };
    }

    pub const board_title = " board ";

    /// The board's buttons: the repos as tabs and the gate beside them on its first row, a + on
    /// the to-do column's top edge, and the picked card's actions on the row under it, each kept
    /// to the room it has.
    pub fn boardButtons(app: *const App, out: []Button) []Button {
        const view = app.board_view orelse return out[0..0];
        const ox = app.term_w - app.view_w;
        const cw = app.boardColW();
        var n: usize = 0;
        var buf: [64]u8 = undefined;
        var repos: [max_repos][]const u8 = undefined;
        const count = if (app.board) |*b| b.repos(&repos) else 0;
        var x: u16 = ox + @as(u16, @intCast(cellCount(board_title))) + 1;
        const right = ox + app.view_w;
        for (0..count + 4) |i| {
            const what: @FieldType(Button, "what") = if (i <= count) .{ .repo = i } else if (i == count + 1) .backlog else if (i == count + 2) .gate else .orchestrator;
            if (what == .gate and app.gateSession() == null) continue;
            const w: u16 = @intCast(cellCount(app.buttonLabel(what, &buf)));
            if (what == .gate or (what == .orchestrator and app.gateSession() == null)) x += 2;
            if (x + w > right or n == out.len) break;
            out[n] = .{ .what = what, .x = x, .y = 0, .w = w };
            n += 1;
            x += w + 1;
        }
        if (cw >= 12 and n < out.len) {
            out[n] = .{ .what = .new, .x = ox + cw - 4, .y = 1, .w = 3 };
            n += 1;
        }
        const card = app.boardCard(view.col, view.row) orelse return out[0..n];
        const y: u16 = @intCast(2 + 3 * (view.row - app.boardFirst(view.col)) + 2);
        if (y + 1 >= app.view_h) return out[0..n];
        var have: [8]CardAction = undefined;
        x = ox + @as(u16, @intCast(view.col)) * cw + 2;
        const edge = ox + @as(u16, @intCast(view.col + 1)) * cw -| 1;
        for (cardActions(card, &have)) |action| {
            const w: u16 = @intCast(cellCount(app.buttonLabel(.{ .card = action }, &buf)));
            if (x + w > edge or n == out.len) break;
            out[n] = .{ .what = .{ .card = action }, .x = x, .y = y, .w = w };
            n += 1;
            x += w + 1;
        }
        return out[0..n];
    }

    fn pressButton(app: *App, button: Button) !void {
        const view = &app.board_view.?;
        switch (button.what) {
            .repo => |i| {
                view.repo = i;
                view.backlog = false;
                view.row = 0;
            },
            .backlog => {
                view.backlog = true;
                view.col = 0;
                view.row = 0;
            },
            .gate => try app.toGate(),
            .orchestrator => try app.toOrchestrator(),
            .new => try app.newTicket(),
            .card => |action| try app.act(action),
        }
    }

    /// A command over a ticket that wants the terminal, as $EDITOR does: in a window by the
    /// focused one, kept open on a refusal to be read.
    fn ticketWindow(app: *App, comptime cmd: []const u8, args: anytype) !void {
        app.board_view = null;
        try app.send(.ignore, "new-window -a -n ticket \"" ++ cmd ++ " || read _\"", args);
    }

    /// A key while a question is shown: its option's number answers it through babylon, which
    /// types the answer into the asking session; Esc puts it away unanswered.
    fn answerKey(app: *App, key: []const u8) !void {
        const view = &app.board_view.?;
        if (anyKey(key, &.{ "\x1b", "q" })) view.answering = false;
        if (key.len != 1 or key[0] < '1' or key[0] > '9') return;
        const card = app.boardCard(view.col, view.row) orelse return;
        const ask = card.ask orelse return;
        const choice = key[0] - '0';
        if (choice > ask.options.len) return;
        // babylon's refusal (the session that asked is gone) is said, or the ask stays with no word why
        try app.send(.ignore, "run-shell -b \"out=\\$(babylon answer {d} {d} 2>&1) || " ++
            "{{ command -v notify-send >/dev/null && notify-send -a arena -- \\\"\\$out\\\"; }}\"", .{ ask.id, choice });
        view.answering = false;
    }

    /// The mouse on the board: a click on a card picks it, and on the card picked goes to the
    /// Claude holding it; the wheel moves along the column. Whether it was the board's: on the
    /// rail it is the rail's, and closes the board but for its own row there.
    fn boardMouse(app: *App, m: keys.Mouse) !bool {
        if (m.x < app.term_w - app.view_w) {
            if (m.leftPress() and m.y != 1) app.board_view = null;
            app.dirty = true;
            return false;
        }
        if (m.wheel()) {
            if (app.navStep()) try app.boardKey(if (m.code & 1 == 0) "k" else "j");
            return true;
        }
        if (!m.leftPress()) return true;
        app.dirty = true;
        const open = &app.board_view.?;
        // a box over the board takes the click, as a key would, so nothing hidden under it is pressed
        if (open.help or open.detail != null or open.answering) {
            open.help = false;
            open.detail = null;
            open.answering = false;
            return true;
        }
        var buttons: [48]Button = undefined;
        for (app.boardButtons(&buttons)) |button| if (m.y == button.y and m.x >= button.x and m.x < button.x + button.w) {
            try app.pressButton(button);
            return true;
        };
        const at = app.boardCardAt(m.x, m.y) orelse return true;
        const view = &app.board_view.?;
        view.answering = false;
        if (view.col == at.col and view.row == at.row) {
            try app.goCard();
        } else view.* = .{ .col = at.col, .row = at.row, .repo = view.repo, .backlog = view.backlog };
        return true;
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
            .none, .thumb, .focus => {},
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

    /// The rail's rows: its sessions one under another from the second, then a rule over the button
    /// for a new session and the menu button, above its bottom border.
    pub fn railRuleRow(app: *const App) u16 {
        return app.view_h -| 4;
    }

    pub fn railNewRow(app: *const App) u16 {
        return app.view_h -| 3;
    }

    pub fn railMenuRow(app: *const App) u16 {
        return app.view_h -| 2;
    }

    /// How many sessions fit above the rule, with a row free under the last.
    pub fn railShown(app: *const App) usize {
        const room = app.railRuleRow() -| 1;
        return @min(app.railSessions(), room -| 2);
    }

    /// The sessions the rail and the overview list: all but babylon's, which sorts last.
    pub fn railSessions(app: *const App) usize {
        var n: usize = 0;
        while (n < app.sessions.items.len and !app.sessions.items[n].offRail()) n += 1;
        return n;
    }

    /// Where babylon's session is, when it is there.
    pub fn gateSession(app: *const App) ?usize {
        for (app.railSessions()..app.sessions.items.len) |i| if (app.sessions.items[i].gate()) return i;
        return null;
    }

    /// Where the orchestrator's session is, when it is running.
    pub fn orchestratorSession(app: *const App) ?usize {
        for (app.railSessions()..app.sessions.items.len) |i| if (app.sessions.items[i].orchestrator()) return i;
        return null;
    }

    /// The rule over the rail's agents, a row free under the last session, and the rows they can
    /// have under it, with one free over the rule at its foot.
    pub fn railAgentsRow(app: *const App) u16 {
        return @intCast(2 + app.railShown() + 1);
    }

    pub fn railAgentRows(app: *const App) u16 {
        return app.railRuleRow() -| 1 -| (app.railAgentsRow() + 1);
    }

    /// Which session is on row `y` of the rail.
    fn railSession(app: *const App, y: u16) ?usize {
        if (y < 2) return null;
        const index = y - 2;
        return if (index < app.railShown()) index else null;
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
        const over = @min(app.railShown() -| 1, m.y -| 2);
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
        if (at >= app.railSessions() or next < 0 or next >= app.railSessions()) return;
        try app.moveSession(at, @intCast(next));
    }

    /// Ends a session and every window in it. tmux would detach arena from the session it is
    /// on when that ends, so arena moves to a neighbour first.
    fn closeSession(app: *App, id: u32) !void {
        const at = app.sessionIndex(id) orelse return;
        const count = app.sessions.items.len;
        if (id == app.current and count > 1) try app.sessionTo(if (at + 1 < count) at + 1 else at - 1);
        try app.send(.ignore, "kill-session -t '${d}'", .{id});
    }

    /// The line after a pane of the focused window, which is taken hold of to resize the pane.
    pub const Line = struct { pane: u32, upright: bool };

    pub fn lineAt(app: *const App, x: u16, y: u16) ?Line {
        const s = app.cur() orelse return null;
        const ox = app.term_w - app.view_w;
        if (x < ox or y == 0 or y + 1 >= app.view_h or app.yoff != 0) return null;
        const hit = app.colAt(s, @as(i32, x) - ox + s.scroll) orelse return null;
        const win = s.wins.items[hit.index];
        if (hit.index != s.focus or hit.cx == 0 or hit.cx == app.colW(s, win) - 1) return null;
        const tx = hit.cx - 1;
        const ty = y - 1;
        if (win.paneAt(tx, ty) != null) return null;
        if (tx > 0) if (win.paneAt(tx - 1, ty)) |before| return .{ .pane = before.id, .upright = true };
        if (ty > 0) if (win.paneAt(tx, ty - 1)) |above| return .{ .pane = above.id, .upright = false };
        return null;
    }

    /// Has the terminal show the pointer as what it is over, or holds, can be dragged: by
    /// name, as OSC 22 takes them.
    fn pointAs(app: *App, m: keys.Mouse) !void {
        const upright: ?bool = switch (app.drag) {
            .divider => |line| line.upright,
            .none => if (app.overlay()) null else if (app.lineAt(m.x, m.y)) |line| line.upright else null,
            else => null,
        };
        const shape: []const u8 = if (upright) |is| (if (is) "ew-resize" else "ns-resize") else "default";
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

    /// A sideways swipe steps one window, once it has gone `swipe_events` one way with no up or
    /// down among them, and no more however long its momentum runs.
    fn swipe(app: *App, by: i32) !void {
        if (app.now - app.sideways_at >= nav_gap_ms) {
            app.sideways_run = 0;
            app.swiped = false;
        }
        app.sideways_at = app.now;
        // A trackpad's swipe up or down drifts, and the sideways events among its own are not steps.
        if (app.now - app.vertical_at < nav_gap_ms) {
            app.sideways_run = 0;
            return;
        }
        if (app.sideways_run * by < 0) app.sideways_run = 0;
        app.sideways_run += by;
        if (app.swiped or @abs(app.sideways_run) < swipe_events) return;
        app.swiped = true;
        try app.focusBy(by);
    }

    /// A right click nothing else took opens the menu; with the menu open, a click picks from it
    /// or, outside it, closes it.
    fn onMouse(app: *App, m: keys.Mouse) !void {
        app.pointer = .{ .x = m.x, .y = m.y };
        try app.pointAs(m);
        if (m.hover()) app.hoverRail(m.x);
        const over_dots = m.y == app.view_h and m.x >= app.term_w - app.view_w;
        if (over_dots != app.over_dots) {
            app.over_dots = over_dots;
            app.dirty = true;
        }
        if (app.overview != null) return app.overviewMouse(m);
        if (app.board_view != null) if (try app.boardMouse(m)) return;
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
    /// resize them; a sideways wheel steps through windows; and anything inside a pane is its
    /// program's or scrolls it, but for a shift drag, which selects, a middle click, which
    /// pastes the primary selection, and a hover.
    fn mouseHit(app: *App, m: keys.Mouse) !bool {
        const ox = app.term_w - app.view_w;
        if (m.wheel() and !m.sideways()) app.vertical_at = app.now;
        if (app.drag != .none and !m.wheel()) {
            try app.dragTo(m);
            return true;
        }
        if (m.x < @max(ox, app.railDrawnW())) {
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
            if (app.railAgentAt(m.y)) |line| {
                switch (line) {
                    .agent, .detail, .meta, .background => |a| try app.goAgent(a),
                    .session => |si| try app.sessionTo(si),
                    .more => {},
                }
                return true;
            }
            if (m.y == app.railAgentsRow() and app.railAgentAt(m.y + 1) != null) {
                app.toggleSort();
                return true;
            }
            if (m.y == 0) {
                app.toggleRail();
                return true;
            }
            if (m.y == 1 and app.board != null) {
                app.toggleBoard();
                return true;
            }
            if (m.y == app.railMenuRow()) app.openMenu(&menu.main);
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
        if (m.y == app.view_h) {
            if (m.wheel() and !m.sideways()) {
                if (app.navStep()) try app.focusBy(if (m.code & 1 == 0) -1 else 1);
                return true;
            }
            var widths: [max_tabs]usize = undefined;
            const tabs = tabWidths(s, &widths);
            const at = (if (tabs.len > 0) layout.tabAt(app.view_w, tabs, m.x - ox) else null) orelse
                layout.dotAt(app.view_w, s.wins.items.len, m.x - ox) orelse return false;
            if (m.leftPress()) try app.focusTo(at);
            return m.leftPress();
        }
        if (m.sideways()) {
            try app.swipe(if (m.code & 1 == 0) -1 else 1);
            return true;
        }
        if (m.leftPress()) if (app.lineAt(m.x, m.y)) |line| {
            app.drag = .{ .divider = .{ .pane = line.pane, .upright = line.upright } };
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
            if (!m.leftPress()) return false;
            try app.focusTo(index);
            app.drag = .focus;
            return true;
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
            if (m.code & (3 | 32 | 64) == 1) {
                if (!m.release) try app.send(.ignore, "run-shell -b \"wl-paste -p -n | tmux load-buffer -b arena-primary - && tmux paste-buffer -p -d -b arena-primary -t %{d}\"", .{pane.id});
                return true;
            }
            const shift = m.code & 4 != 0 and !m.wheel();
            if (!shift and try app.mouseToPane(win, pane, m, px, py)) return true;
            // The program takes no mouse, or shift is held: the button selects text, which is
            // copied when it is let go, and two clicks pick a word.
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
    fn mouseToPane(app: *App, win: *const Window, pane: *Pane, m: keys.Mouse, x: usize, y: usize) !bool {
        const mode = pane.term.flags.mouse_event;
        if (mode == .none) return false;
        if (m.motion() and mode != .button and mode != .any) return true;
        if (m.hover()) return true;
        if (m.release and mode == .x10) return true;
        var buf: [32]u8 = undefined;
        switch (pane.term.flags.mouse_format) {
            .sgr => {
                const end: u8 = if (m.release) 'm' else 'M';
                try app.sendKeys(pane, try std.fmt.bufPrint(&buf, "\x1b[<{d};{d};{d}{c}", .{ m.code, x + 1, y + 1, end }));
            },
            .sgr_pixels => {
                // the middle of the cell, in the pixels tmux tells the program its cells are
                const end: u8 = if (m.release) 'm' else 'M';
                const px = x * win.cell_w + win.cell_w / 2;
                const py = y * win.cell_h + win.cell_h / 2;
                try app.sendKeys(pane, try std.fmt.bufPrint(&buf, "\x1b[<{d};{d};{d}{c}", .{ m.code, px, py, end }));
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
        return app.menu != null or app.prompt != null or app.overview != null or app.board_view != null;
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
            } else if (app.board_view != null) {
                try app.boardKey(key);
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
                    .board => app.toggleBoard(),
                    .rail_width => app.toggleRail(),
                    .split_right => try app.send(.ignore, "split-window -h -c '#{{pane_current_path}}'", .{}),
                    .split_below => try app.send(.ignore, "split-window -v -c '#{{pane_current_path}}'", .{}),
                    .browser => {
                        app.follow_active = true;
                        // without the variable a new tab opens terminal-browser.com
                        try app.send(.ignore, "new-window -a -n browser -e TERMINAL_BROWSER_START_PAGE=1 -c '#{{pane_current_path}}' terminal-browser terminal-browser://start", .{});
                    },
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
            app.board_view = null;
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
            'b' => app.toggleBoard(),
            'w' => app.toggleRail(),
            'n' => try app.stepAgent(1),
            'N' => try app.stepAgent(-1),
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
    /// for a window to jump to, o shows every session's windows at once, b babylon's board, /
    /// searches the pane's history, m opens the menu and q leaves.
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
                    if (std.mem.startsWith(u8, body, "10;") or std.mem.startsWith(u8, body, "11;")) {
                        app.colors_known += 1;
                        try app.tellColors();
                    }
                },
                .graphics => |reply| if (app.paneById(app.asker)) |pane| try app.sendKeys(pane, reply),
            }
        }
        return 0;
    }

    /// Held input that turned out to be all there was, typed as it is.
    pub fn typedAlone(app: *App, bytes: []const u8) !void {
        if (app.overlay()) try app.menuKeys(bytes) else try app.forward(bytes);
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

    /// tmux answers a program's question for its foreground and background with what the client
    /// reported for the pane, and a control client that reported nothing gets black for both.
    fn tellColors(app: *App) !void {
        if (app.colors_known == 0) return;
        const fg = app.palette.fg;
        const bg = app.palette.bg;
        for (app.sessions.items) |s| for (s.wins.items) |win| for (win.panes.items) |pane| {
            if (pane.colors_told == app.colors_known) continue;
            pane.colors_told = app.colors_known;
            try app.send(.ignore, "refresh-client -r \"%{d}:\\033]10;rgb:{x:0>2}/{x:0>2}/{x:0>2}\\033\\\\\"", .{ pane.id, fg.r, fg.g, fg.b });
            try app.send(.ignore, "refresh-client -r \"%{d}:\\033]11;rgb:{x:0>2}/{x:0>2}/{x:0>2}\\033\\\\\"", .{ pane.id, bg.r, bg.g, bg.b });
        };
    }

    fn sendKeys(app: *App, pane: *const Pane, bytes: []const u8) !void {
        var cmd: Writer.Allocating = .init(app.gpa);
        defer cmd.deinit();
        try cmd.writer.print("send-keys -H -t %{d}", .{pane.id});
        for (bytes) |b| try cmd.writer.print(" {x:0>2}", .{b});
        try app.send(.ignore, "{s}", .{cmd.written()});
    }
};

/// The detail box's width, and the text's within its border.
pub fn detailWidth(view_w: u16) struct { box: u16, inner: u16 } {
    const box = @min(view_w -| 4, 100);
    return .{ .box = box, .inner = box -| 4 };
}

/// A card's detail as the box shows it: each of its lines cut to `inner` characters and run on
/// under one another, the space at a cut dropped.
pub const DetailLines = struct {
    lines: std.mem.SplitIterator(u8, .scalar),
    rest: ?[]const u8 = null,
    inner: usize,

    pub fn init(text: []const u8, inner: usize) DetailLines {
        return .{ .lines = std.mem.splitScalar(u8, std.mem.trimEnd(u8, text, "\n"), '\n'), .inner = inner };
    }

    pub fn next(it: *DetailLines) ?[]const u8 {
        const rest = it.rest orelse it.lines.next() orelse return null;
        var cut = std.unicode.Utf8View.initUnchecked(rest).iterator();
        var n: usize = 0;
        while (n < it.inner) : (n += 1) _ = cut.nextCodepointSlice() orelse break;
        const line = rest[0..cut.i];
        const after = std.mem.trimStart(u8, rest[cut.i..], " ");
        it.rest = if (after.len > 0 and line.len > 0) after else null;
        return line;
    }
};

/// `text` made safe to draw: escape sequences and control characters but newlines dropped, a tab
/// a space, and a byte that is not UTF-8 a `?`.
pub fn appendClean(out: *std.ArrayList(u8), gpa: Allocator, text: []const u8) !void {
    var i: usize = 0;
    while (i < text.len) {
        const b = text[i];
        if (b == 0x1b) {
            i += 1;
            if (i < text.len and text[i] == '[') {
                i += 1;
                while (i < text.len and (text[i] < 0x40 or text[i] > 0x7e)) i += 1;
            } else if (i < text.len and text[i] == ']') {
                while (i < text.len and text[i] != 0x07 and !(text[i] == 0x1b and i + 1 < text.len and text[i + 1] == '\\')) i += 1;
                if (i < text.len and text[i] == 0x1b) i += 1;
            }
            i += 1;
        } else if (b == '\t') {
            try out.append(gpa, ' ');
            i += 1;
        } else if (b < 0x20 and b != '\n' or b == 0x7f) {
            i += 1;
        } else if (b < 0x80) {
            try out.append(gpa, b);
            i += 1;
        } else {
            const len = std.unicode.utf8ByteSequenceLength(b) catch 0;
            const whole = len > 0 and i + len <= text.len and (if (std.unicode.utf8Decode(text[i .. i + len])) |_| true else |_| false);
            if (whole) try out.appendSlice(gpa, text[i .. i + len]) else try out.append(gpa, '?');
            i += if (whole) len else 1;
        }
    }
}

/// The cells `text` takes, a character a cell.
pub fn cellCount(text: []const u8) usize {
    return std.unicode.utf8CountCodepoints(text) catch text.len;
}

/// A repo's name safe in a tmux command unquoted, as directory names are.
/// A todo card no Claude holds, waiting on nothing, of a repo that can name a session and a folder.
fn startable(card: *const tickets.Card) bool {
    const repo = card.repo orelse return false;
    return card.holder() == null and card.status == .todo and card.blocked_by.len == 0 and plainName(repo);
}

test "a Claude is started only on a free todo card of a plain repo" {
    const free: tickets.Card = .{ .id = 1, .repo = "tlon", .title = "a", .status = .todo };
    try std.testing.expect(startable(&free));
    var c = free;
    c.blocked_by = &.{2};
    try std.testing.expect(!startable(&c));
    c = free;
    c.claimed_by = "%3";
    try std.testing.expect(!startable(&c));
    c = free;
    c.status = .doing;
    try std.testing.expect(!startable(&c));
    c = free;
    c.repo = "a b";
    try std.testing.expect(!startable(&c));
    c = free;
    c.repo = null;
    try std.testing.expect(!startable(&c));
}

/// The tmux session named for `repo`: tmux makes a . in a session name a _.
fn sessionNamed(repo: []const u8, buf: []u8) []const u8 {
    const out = buf[0..@min(repo.len, buf.len)];
    for (out, repo[0..out.len]) |*to, from| to.* = if (from == '.') '_' else from;
    return out;
}

test "a repo's session is named as tmux would have it, a dot a _" {
    var buf: [16]u8 = undefined;
    try std.testing.expectEqualStrings("a_b-c", sessionNamed("a.b-c", &buf));
    try std.testing.expectEqualStrings("tlon", sessionNamed("tlon", &buf));
}

fn plainName(name: []const u8) bool {
    for (name) |c| if (!std.ascii.isAlphanumeric(c) and c != '-' and c != '_' and c != '.') return false;
    return name.len > 0;
}

test "text to draw loses its escapes and controls, and a byte not UTF-8 is a ?" {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(std.testing.allocator);
    try appendClean(&out, std.testing.allocator, "\x1b[31mred\x1b[0m\tok\x07\n\xff é \x1b]0;title\x07end\xe2\x82");
    try std.testing.expectEqualStrings("red ok\n? é end??", out.items);
}

test "a card's detail runs its long lines on, cut at the box's width" {
    var lines = DetailLines.init("#3 Title\n\none two three four\n", 8);
    const want = [_][]const u8{ "#3 Title", "", "one two ", "three fo", "ur" };
    for (want) |line| try std.testing.expectEqualStrings(line, lines.next().?);
    try std.testing.expectEqual(null, lines.next());
}

test "a review state is read from its number, and what is not one is none" {
    try std.testing.expectEqual(Review.none, Review.of(0));
    try std.testing.expectEqual(Review.landed, Review.of(1));
    try std.testing.expectEqual(Review.reviewed, Review.of(2));
    try std.testing.expectEqual(Review.queued, Review.of(3));
    try std.testing.expectEqual(Review.changes, Review.of(4));
    try std.testing.expectEqual(Review.none, Review.of(5));
}

test "babylon's own session, sorted last, is off the list and lists no agents" {
    var gate: Window = .{ .id = 1, .claude = .working };
    var mine: Window = .{ .id = 2, .claude = .working };
    var gates = [_]*Window{&gate};
    var mines = [_]*Window{&mine};
    var babylon: Session = .{ .id = 1, .name = @constCast("babylon") };
    babylon.wins = .fromOwnedSlice(&gates);
    var work: Session = .{ .id = 2, .name = @constCast("work") };
    work.wins = .fromOwnedSlice(&mines);
    var sessions = [_]*Session{ &work, &babylon };
    var app: App = .{ .gpa = std.testing.allocator, .io = undefined, .tmux_in = undefined };
    app.sessions = .fromOwnedSlice(&sessions);
    try std.testing.expectEqual(@as(usize, 1), app.railSessions());
    try std.testing.expectEqual(@as(?usize, 1), app.gateSession());
    var found: [4]App.Agent = undefined;
    try std.testing.expectEqual(@as(usize, 1), app.agents(&found));
    try std.testing.expectEqual(@as(u32, 2), found[0].win.id);
    try std.testing.expectEqual(@as(?usize, null), app.orchestratorSession());

    var orch: Session = .{ .id = 3, .name = @constCast("orchestrator") };
    var three = [_]*Session{ &work, &babylon, &orch };
    app.sessions = .fromOwnedSlice(&three);
    try std.testing.expectEqual(@as(usize, 1), app.railSessions());
    try std.testing.expectEqual(@as(?usize, 1), app.gateSession());
    try std.testing.expectEqual(@as(?usize, 2), app.orchestratorSession());
}

test "a session shows the review state that most wants looking at" {
    var a: Window = .{ .id = 1 };
    var b: Window = .{ .id = 2 };
    var c: Window = .{ .id = 3 };
    var wins = [_]*Window{ &a, &b, &c };
    var s: Session = .{ .id = 1 };
    s.wins = .fromOwnedSlice(&wins);
    try std.testing.expectEqual(Review.none, App.sessionReview(&s));
    a.review = .landed;
    try std.testing.expectEqual(Review.landed, App.sessionReview(&s));
    b.review = .reviewed;
    try std.testing.expectEqual(Review.reviewed, App.sessionReview(&s));
    c.review = .queued;
    try std.testing.expectEqual(Review.queued, App.sessionReview(&s));
    a.review = .changes;
    try std.testing.expectEqual(Review.changes, App.sessionReview(&s));
}
