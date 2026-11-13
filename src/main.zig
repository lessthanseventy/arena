const std = @import("std");
const vt = @import("ghostty-vt");
const control = @import("control.zig");
const layout = @import("layout.zig");
const theme = @import("theme.zig");
const keys = @import("keys.zig");
const menu = @import("menu.zig");
const color = @import("color.zig");
const posix = std.posix;
const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;

const Window = struct {
    id: u32,
    pane: u32,
    name: []u8,
    term: vt.Terminal,
    stream: vt.TerminalStream,
    render: vt.RenderState = .empty,
    /// Output is dropped until the pane's captured screen has been fed in: the capture holds it.
    seeded: bool = false,

    fn create(app: *App, id: u32, pane: u32, cols: u16, rows: u16) !*Window {
        const win = try app.gpa.create(Window);
        errdefer app.gpa.destroy(win);
        win.* = .{
            .id = id,
            .pane = pane,
            .name = &.{},
            .term = try .init(app.io, app.gpa, .{ .cols = cols, .rows = rows, .max_scrollback_bytes = 8 << 20 }),
            .stream = undefined,
        };
        win.stream = win.term.vtStream();
        return win;
    }

    fn destroy(win: *Window, gpa: Allocator) void {
        win.render.deinit(gpa);
        win.stream.deinit();
        win.term.deinit(gpa);
        gpa.free(win.name);
        gpa.destroy(win);
    }
};

const Session = struct { id: u32, name: []u8 };

const Pending = union(enum) {
    ignore,
    windows,
    sessions,
    modes: u32,
    capture: u32,
    cursor: u32,
};

const App = struct {
    gpa: Allocator,
    io: std.Io,
    tmux_in: std.Io.File,
    wins: std.ArrayList(*Window) = .empty,
    focus: usize = 0,
    scroll: i32 = 0,
    sessions: std.ArrayList(Session) = .empty,
    session: ?u32 = null,
    /// Set by a session change until its windows are listed; `slide` is the way it went.
    switched: bool = false,
    slide: i32 = 0,
    /// Rows the strip still has to travel to its place after a session change.
    yoff: i32 = 0,
    menu: ?menu.Menu = null,
    palette: color.Palette = .{},
    /// Set when arena asks tmux for a new window, so focus goes to it when it is listed.
    follow_active: bool = false,
    term_w: u16 = 80,
    /// The strip's width: the terminal's, less the session rail and its gap.
    view_w: u16 = 80,
    view_h: u16 = 24,
    pending: std.ArrayList(Pending) = .empty,
    in_block: bool = false,
    block: std.ArrayList(u8) = .empty,
    listed: bool = false,
    dirty: bool = true,
    quit: bool = false,
    theme: ?theme.Theme = null,
    /// Off under ARENA_REDUCED_MOTION: the border stands still and the strip jumps.
    motion: bool = true,
    phase: f32 = 0,

    fn deinit(app: *App) void {
        for (app.wins.items) |win| win.destroy(app.gpa);
        app.wins.deinit(app.gpa);
        for (app.sessions.items) |s| app.gpa.free(s.name);
        app.sessions.deinit(app.gpa);
        app.pending.deinit(app.gpa);
        app.block.deinit(app.gpa);
    }

    fn send(app: *App, kind: Pending, comptime fmt: []const u8, args: anytype) !void {
        var buf: [256]u8 = undefined;
        var w = app.tmux_in.writerStreaming(app.io, &buf);
        try w.interface.print(fmt ++ "\n", args);
        try w.interface.flush();
        try app.pending.append(app.gpa, kind);
    }

    fn colW(app: *const App) u16 {
        return layout.colWidth(app.view_w, app.wins.items.len);
    }

    fn target(app: *const App) i32 {
        return layout.scrollTarget(app.view_w, app.colW(), app.focus);
    }

    /// The session rail's width: the longest name, to 14 cells, and a space either side. A
    /// terminal too narrow for it has none.
    fn railW(app: *const App) u16 {
        if (app.term_w < 40 or app.sessions.items.len == 0) return 0;
        var longest: usize = 1;
        for (app.sessions.items) |s| longest = @max(longest, std.unicode.utf8CountCodepoints(s.name) catch s.name.len);
        return @as(u16, @max(rail_button.len, @min(longest, 14))) + 2;
    }

    fn fit(app: *App) void {
        const rail = app.railW();
        app.view_w = app.term_w - if (rail > 0) rail + 1 else 0;
    }

    fn byPane(app: *App, pane: u32) ?*Window {
        for (app.wins.items) |win| if (win.pane == pane) return win;
        return null;
    }

    /// Sizes every window, here and in tmux, to the inside of its column.
    fn relayout(app: *App) !void {
        const cols = @max(1, app.colW() -| 2);
        const rows = @max(1, app.view_h -| 2);
        for (app.wins.items) |win| {
            if (win.term.cols == cols and win.term.rows == rows) continue;
            try win.term.resize(app.gpa, .{ .cols = cols, .rows = rows });
            try app.send(.ignore, "refresh-client -C @{d}:{d}x{d}", .{ win.id, cols, rows });
        }
        app.dirty = true;
    }

    fn onLine(app: *App, line: []u8) !void {
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
                const win = app.byPane(out.pane) orelse return;
                if (!win.seeded) return;
                win.stream.nextSlice(control.unescape(@constCast(out.data)));
                app.dirty = true;
            },
            .windows_changed => try app.listWindows(),
            .sessions_changed => try app.listSessions(),
            .session_changed => |id| {
                app.session = id;
                app.switched = true;
                try app.listWindows();
            },
            .exit => app.quit = true,
            .other => {},
        }
    }

    fn listWindows(app: *App) !void {
        try app.send(.windows, "list-windows -F '#{{window_id}} #{{pane_id}} #{{window_active}} #{{window_name}}'", .{});
    }

    fn listSessions(app: *App) !void {
        try app.send(.sessions, "list-sessions -F '#{{session_id}} #{{session_name}}'", .{});
    }

    fn onSessions(app: *App, body: []const u8) !void {
        for (app.sessions.items) |s| app.gpa.free(s.name);
        app.sessions.clearRetainingCapacity();
        var lines = std.mem.tokenizeScalar(u8, body, '\n');
        while (lines.next()) |line| {
            const space = std.mem.indexOfScalar(u8, line, ' ') orelse continue;
            const id = std.fmt.parseInt(u32, line[1..space], 10) catch continue;
            try app.sessions.append(app.gpa, .{ .id = id, .name = try app.gpa.dupe(u8, line[space + 1 ..]) });
        }
        app.fit();
        if (app.listed) {
            try app.relayout();
            app.scroll = app.target();
        }
        app.dirty = true;
    }

    fn sessionBy(app: *App, delta: i32) !void {
        const current = app.session orelse return;
        const at = for (app.sessions.items, 0..) |s, i| {
            if (s.id == current) break i;
        } else return;
        const next = @as(i32, @intCast(at)) + delta;
        if (next < 0 or next >= app.sessions.items.len) return;
        try app.sessionTo(@intCast(next));
    }

    fn sessionTo(app: *App, index: usize) !void {
        const to = app.sessions.items[index];
        if (to.id == app.session) return;
        const at = for (app.sessions.items, 0..) |s, i| {
            if (s.id == app.session) break i;
        } else index;
        app.slide = if (index > at) 1 else -1;
        try app.send(.ignore, "switch-client -t '${d}'", .{to.id});
    }

    fn onReply(app: *App, kind: Pending, body: []const u8) !void {
        switch (kind) {
            .ignore => {},
            .windows => try app.onWindows(body),
            .sessions => try app.onSessions(body),
            // What the program set before arena was watching, which no capture shows: without
            // these a running editor would get no mouse and draw outside the alternate screen.
            .modes => |pane| {
                const win = app.byPane(pane) orelse return;
                var flags = std.mem.tokenizeAny(u8, body, " \n");
                for (mode_sets) |set| {
                    if (std.mem.eql(u8, flags.next() orelse return, "1")) win.stream.nextSlice(set);
                }
            },
            .capture => |pane| {
                const win = app.byPane(pane) orelse return;
                win.stream.nextSlice("\x1b[H\x1b[2J");
                // Every row is kept, blank ones too: the last screenful has to land as the screen.
                var lines = std.mem.splitScalar(u8, body[0..body.len -| 1], '\n');
                var first = true;
                while (lines.next()) |line| {
                    if (!first) win.stream.nextSlice("\r\n");
                    first = false;
                    win.stream.nextSlice(line);
                }
                win.stream.nextSlice("\x1b[0m");
                win.seeded = true;
                app.dirty = true;
            },
            .cursor => |pane| {
                const win = app.byPane(pane) orelse return;
                var it = std.mem.tokenizeAny(u8, body, " \n");
                const x = std.fmt.parseInt(u16, it.next() orelse return, 10) catch return;
                const y = std.fmt.parseInt(u16, it.next() orelse return, 10) catch return;
                var buf: [32]u8 = undefined;
                win.stream.nextSlice(try std.fmt.bufPrint(&buf, "\x1b[{d};{d}H", .{ y + 1, x + 1 }));
                app.dirty = true;
            },
        }
    }

    fn onWindows(app: *App, body: []const u8) !void {
        const focused_id: ?u32 = if (app.focus < app.wins.items.len) app.wins.items[app.focus].id else null;
        var old = app.wins;
        app.wins = .empty;
        var active: usize = 0;

        var lines = std.mem.tokenizeScalar(u8, body, '\n');
        while (lines.next()) |line| {
            var it = std.mem.tokenizeScalar(u8, line, ' ');
            const id = try std.fmt.parseInt(u32, (it.next() orelse continue)[1..], 10);
            const pane = try std.fmt.parseInt(u32, (it.next() orelse continue)[1..], 10);
            if (std.mem.eql(u8, it.next() orelse continue, "1")) active = app.wins.items.len;
            const name = it.rest();

            const win = for (old.items, 0..) |w, i| {
                if (w.id == id and w.pane == pane) break old.swapRemove(i);
            } else try Window.create(app, id, pane, 1, 1);
            app.gpa.free(win.name);
            win.name = try app.gpa.dupe(u8, name);
            try app.wins.append(app.gpa, win);
        }
        for (old.items) |win| win.destroy(app.gpa);
        old.deinit(app.gpa);

        if (app.wins.items.len == 0) {
            app.quit = true;
            return;
        }
        app.focus = active;
        if (!app.follow_active) if (focused_id) |id| for (app.wins.items, 0..) |win, i| {
            if (win.id == id) app.focus = i;
        };
        app.follow_active = false;
        try app.relayout();
        for (app.wins.items) |win| {
            if (win.seeded) continue;
            try app.send(.{ .modes = win.pane }, "display-message -p -t %{d} '" ++ mode_flags ++ "'", .{win.pane});
            try app.send(.{ .capture = win.pane }, "capture-pane -p -e -S -{d} -t %{d}", .{ history_lines, win.pane });
            try app.send(.{ .cursor = win.pane }, "display-message -p -t %{d} '#{{cursor_x}} #{{cursor_y}}'", .{win.pane});
        }
        if (!app.listed or app.switched) app.scroll = app.target();
        if (app.switched and app.motion) app.yoff = app.slide * @divTrunc(@as(i32, app.view_h), 3);
        app.switched = false;
        app.slide = 0;
        app.listed = true;
    }

    fn focusBy(app: *App, delta: i32) !void {
        const next = @as(i32, @intCast(app.focus)) + delta;
        if (next < 0 or next >= app.wins.items.len) return;
        try app.focusTo(@intCast(next));
    }

    fn focusTo(app: *App, index: usize) !void {
        app.focus = index;
        try app.send(.ignore, "select-window -t @{d}", .{app.wins.items[index].id});
        app.dirty = true;
    }

    /// A click on a session, another column or a dot goes there. Inside the focused window the
    /// mouse is its program's when it asked for one; otherwise the wheel scrolls its history.
    /// A right click nothing else took opens the menu; with the menu open, a click picks from it
    /// or, outside it, closes it.
    fn onMouse(app: *App, m: keys.Mouse) !void {
        if (app.menu) |open| {
            if (!m.leftPress() and !m.rightPress()) return;
            const box = app.menuBox(open);
            const inside = m.x >= box.x and m.x < box.x + menu.width and m.y >= box.y and m.y < box.y + open.height();
            try app.menuResult(if (inside and m.leftPress()) open.click(m.x - box.x, m.y - box.y) else .close);
            return;
        }
        if (!try app.mouseHit(m) and m.rightPress()) app.openMenu(&menu.main);
    }

    /// Whether the mouse event was for something: a session, another column, a dot, or the
    /// focused window's program or history.
    fn mouseHit(app: *App, m: keys.Mouse) !bool {
        const ox = app.term_w - app.view_w;
        if (m.x < ox) {
            if (!m.leftPress()) return false;
            if (m.y == 0) app.openMenu(&menu.main);
            if (m.y >= 1 and m.y - 1 < app.sessions.items.len) try app.sessionTo(m.y - 1);
            return true;
        }
        if (app.yoff != 0) return false;
        const col_w = app.colW();
        const at = @as(i32, m.x) - ox + app.scroll;
        if (at < 0) return false;
        const stride = @as(i32, col_w) + layout.gap;
        const index: usize = @intCast(@divTrunc(at, stride));
        const cx: usize = @intCast(@mod(at, stride));
        if (index >= app.wins.items.len or cx >= col_w) return false;
        if (index != app.focus) {
            if (m.leftPress()) try app.focusTo(index);
            return m.leftPress();
        }
        if (m.y == app.view_h - 1) {
            const dot = layout.dotAt(col_w, app.wins.items.len, cx) orelse return false;
            if (m.leftPress()) try app.focusTo(dot);
            return m.leftPress();
        }
        if (cx == 0 or cx == col_w - 1 or m.y == 0) return false;
        const win = app.wins.items[index];
        if (try app.mouseToWindow(win, m, cx - 1, m.y - 1)) return true;
        if (!m.wheel()) return false;
        win.term.scrollViewport(.{ .delta = if (m.code & 1 == 0) -3 else 3 });
        app.dirty = true;
        return true;
    }

    fn openMenu(app: *App, items: []const menu.Item) void {
        app.menu = .{ .items = items };
        app.dirty = true;
    }

    /// Where the open menu's top left corner is: the box is centred over the strip.
    fn menuBox(app: *const App, open: menu.Menu) struct { x: u16, y: u16 } {
        return .{
            .x = app.term_w - app.view_w + (app.view_w -| menu.width) / 2,
            .y = (app.view_h -| open.height()) / 2,
        };
    }

    fn menuKeys(app: *App, text: []const u8) !void {
        var i: usize = 0;
        while (i < text.len) {
            const open = &(app.menu orelse return);
            // an arrow is ESC and two more; anything else is a key a byte
            const len: usize = if (text[i] == 0x1b and text.len - i >= 3) 3 else 1;
            try app.menuResult(open.press(text[i..][0..len]));
            i += len;
        }
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
                    .close_window => app.openMenu(&menu.confirm),
                    .confirm_close => try app.closeWindow(),
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
        if (app.focus >= app.wins.items.len) return;
        const id = app.wins.items[app.focus].id;
        if (app.wins.items.len == 1 and app.sessions.items.len > 1) {
            const at = for (app.sessions.items, 0..) |s, i| {
                if (s.id == app.session) break i;
            } else 0;
            try app.sessionTo(if (at + 1 < app.sessions.items.len) at + 1 else at - 1);
        }
        try app.send(.ignore, "kill-window -t @{d}", .{id});
    }

    fn swapBy(app: *App, delta: i32) !void {
        const next = @as(i32, @intCast(app.focus)) + delta;
        if (next < 0 or next >= app.wins.items.len) return;
        const from = app.wins.items[app.focus].id;
        const to = app.wins.items[@intCast(next)].id;
        try app.send(.ignore, "swap-window -d -s @{d} -t @{d}", .{ from, to });
        try app.listWindows();
    }

    fn onChord(app: *App, letter: u8) !void {
        if (app.menu != null) {
            app.menu = null;
            app.dirty = true;
            return;
        }
        switch (letter) {
            'h' => try app.focusBy(-1),
            'l' => try app.focusBy(1),
            'j' => try app.sessionBy(1),
            'k' => try app.sessionBy(-1),
            'H' => try app.swapBy(-1),
            'L' => try app.swapBy(1),
            'x' => app.openMenu(&menu.confirm),
            'm' => app.openMenu(&menu.main),
            'q' => app.quit = true,
            '\r' => try app.newWindow(),
            else => if (letter - '1' < app.wins.items.len) try app.focusTo(letter - '1'),
        }
    }

    /// Reports the mouse to the window's program in the mode and format it asked tmux for; false
    /// when it asked for none.
    fn mouseToWindow(app: *App, win: *Window, m: keys.Mouse, x: usize, y: usize) !bool {
        const mode = win.term.flags.mouse_event;
        if (mode == .none) return false;
        if (m.motion() and mode != .button and mode != .any) return true;
        if (m.release and mode == .x10) return true;
        var buf: [32]u8 = undefined;
        switch (win.term.flags.mouse_format) {
            .sgr, .sgr_pixels => {
                const end: u8 = if (m.release) 'm' else 'M';
                try app.forward(try std.fmt.bufPrint(&buf, "\x1b[<{d};{d};{d}{c}", .{ m.code, x + 1, y + 1, end }));
            },
            else => {
                // one byte a coordinate, offset by 32: cells past 222 cannot be said
                if (x > 222 or y > 222) return true;
                const code = if (m.release) m.code | 3 else m.code;
                buf[0..3].* = "\x1b[M".*;
                buf[3] = @intCast(code + 32);
                buf[4] = @intCast(x + 33);
                buf[5] = @intCast(y + 33);
                try app.forward(buf[0..6]);
            },
        }
        return true;
    }

    /// With Alt: h and l move along the strip, j and k between sessions, 1 to 9 go to a window,
    /// H and L move the window, Enter opens one, x closes it, m opens the menu and q leaves. Everything else is
    /// the focused window's, or the menu's while it is open. Alt is ESC and the letter together,
    /// which a typed Escape then a letter rarely is.
    /// Returns how many bytes at the end of `bytes` to pass again in front of the next read.
    fn onInput(app: *App, bytes: []const u8) !usize {
        var rest = bytes;
        while (rest.len > 0 and !app.quit) {
            const part = keys.next(rest);
            rest = part.rest;
            if (app.menu != null) try app.menuKeys(part.text) else try app.forward(part.text);
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
        if (bytes.len == 0 or app.focus >= app.wins.items.len) return;
        app.wins.items[app.focus].term.scrollViewport(.bottom);
        app.dirty = true;
        var cmd: Writer.Allocating = .init(app.gpa);
        defer cmd.deinit();
        try cmd.writer.print("send-keys -H -t %{d}", .{app.wins.items[app.focus].pane});
        for (bytes) |b| try cmd.writer.print(" {x:0>2}", .{b});
        try app.send(.ignore, "{s}", .{cmd.written()});
    }
};

const Pen = struct {
    style: vt.Style = .{},
    dimmed: bool = false,
    fresh: bool = true,

    /// `dim` is the palette to dim against, for an unfocused window's cells. The terminal's own
    /// faint is not used for that: one keeping a minimum contrast repaints faint colours white.
    fn set(pen: *Pen, w: *Writer, given: vt.Style, dim: ?*const color.Palette) !void {
        if (!pen.fresh and pen.dimmed == (dim != null) and @as(u128, @bitCast(pen.style)) == @as(u128, @bitCast(given))) return;
        pen.* = .{ .style = given, .dimmed = dim != null, .fresh = false };
        var style = given;
        if (dim) |palette| {
            var fg = resolve(palette, style.fg_color) orelse palette.fg;
            var bg = resolve(palette, style.bg_color);
            if (style.flags.inverse) {
                const was = fg;
                fg = bg orelse palette.bg;
                bg = was;
                style.flags.inverse = false;
            }
            if (bg) |c| bg = color.dimBg(c, palette.bg);
            fg = color.dimFg(fg, bg orelse palette.bg);
            style.fg_color = .rgb(.{ .r = fg.r, .g = fg.g, .b = fg.b });
            style.bg_color = if (bg) |c| .rgb(.{ .r = c.r, .g = c.g, .b = c.b }) else .none;
        }
        try w.writeAll("\x1b[0");
        if (style.flags.bold) try w.writeAll(";1");
        if (style.flags.faint) try w.writeAll(";2");
        if (style.flags.italic) try w.writeAll(";3");
        if (style.flags.underline != .none) try w.writeAll(";4");
        if (style.flags.inverse) try w.writeAll(";7");
        if (style.flags.strikethrough) try w.writeAll(";9");
        try sgrColor(w, 38, style.fg_color);
        try sgrColor(w, 48, style.bg_color);
        try w.writeAll("m");
    }

    fn resolve(palette: *const color.Palette, c: vt.Style.Color) ?color.RGB {
        return switch (c.value()) {
            .none => null,
            .palette => |idx| palette.colors[idx],
            .rgb => |rgb| .{ .r = rgb.r, .g = rgb.g, .b = rgb.b },
        };
    }

    /// Palette colours stay palette indices, so the outer terminal's theme shows through.
    fn sgrColor(w: *Writer, base: u8, c: vt.Style.Color) !void {
        switch (c.value()) {
            .none => {},
            .palette => |idx| try w.print(";{d};5;{d}", .{ base, idx }),
            .rgb => |rgb| try w.print(";{d};2;{d};{d};{d}", .{ base, rgb.r, rgb.g, rgb.b }),
        }
    }
};

fn put(w: *Writer, cp: u21) !void {
    var buf: [4]u8 = undefined;
    const n = std.unicode.utf8Encode(cp, &buf) catch return w.writeAll(" ");
    try w.writeAll(buf[0..n]);
}

fn rgbStyle(c: theme.RGB) vt.Style {
    return .{ .fg_color = .rgb(.{ .r = c.r, .g = c.g, .b = c.b }) };
}

const Column = struct {
    app: *const App,
    index: usize,
    w: u16,
    focused: bool,
    title: []const u21,

    /// The border cell at (`cx`, `y`) of the column: the frame, the title in its top edge, and
    /// in the focused column's bottom edge a dot per window, the filled one being this one.
    fn border(col: Column, pen: *Pen, w: *Writer, cx: usize, y: u16) !void {
        const app = col.app;
        const h = app.view_h;
        const top = y == 0;
        const bottom = y == h - 1;

        if (top and cx >= 2 and cx - 2 < col.title.len) {
            var style: vt.Style = if (app.theme) |t| rgbStyle(if (col.focused) t.ink else t.dim) else .{ .fg_color = .palette(8) };
            if (col.focused) {
                style.flags.bold = true;
                if (app.theme) |t| {
                    style.bg_color = .rgb(.{ .r = t.amber.r, .g = t.amber.g, .b = t.amber.b });
                } else {
                    style.fg_color = .palette(4);
                    style.flags.inverse = true;
                }
            }
            try pen.set(w, style, null);
            return put(w, col.title[cx - 2]);
        }

        const count = app.wins.items.len;
        if (bottom and col.focused and layout.inDots(col.w, count, cx)) {
            const dot = layout.dotAt(col.w, count, cx);
            const here = dot == app.focus;
            try pen.set(w, if (app.theme) |t| rgbStyle(if (here) t.amber else t.dim) else .{ .fg_color = .palette(if (here) 4 else 8) }, null);
            return put(w, if (dot == null) ' ' else if (here) '●' else '○');
        }

        const style: vt.Style = if (app.theme) |t| rgbStyle(theme.gradient(
            if (col.focused) t.amber else t.amberdim,
            if (col.focused) t.violet else t.emberdim,
            theme.around(col.w, h, cx, y),
            if (col.focused) app.phase else 0,
        )) else .{ .fg_color = .palette(if (col.focused) 4 else 8) };
        try pen.set(w, style, null);
        const left = cx == 0;
        const right = cx == col.w - 1;
        try put(w, if (top) (if (left) '╭' else if (right) '╮' else '─') else if (bottom) (if (left) '╰' else if (right) '╯' else '─') else '│');
    }
};

const Draw = enum { all, focused_border };

/// The sessions, one to a row down the left edge, the current one a chip as a focused title is.
fn drawRail(app: *const App, w: *Writer) !void {
    const rail = app.railW();
    if (rail == 0) return;
    var pen: Pen = .{};
    try w.writeAll("\x1b[1;1H");
    try pen.set(w, if (app.theme) |t| rgbStyle(t.dim) else .{ .fg_color = .palette(8) }, null);
    try w.writeAll(" " ++ rail_button);
    for (app.sessions.items, 0..) |s, i| {
        if (i + 2 >= app.view_h) break;
        const current = s.id == app.session;
        var style: vt.Style = if (app.theme) |t| rgbStyle(if (current) t.ink else t.dim) else .{ .fg_color = .palette(8) };
        if (current) {
            style.flags.bold = true;
            if (app.theme) |t| {
                style.bg_color = .rgb(.{ .r = t.amber.r, .g = t.amber.g, .b = t.amber.b });
            } else {
                style.fg_color = .palette(4);
                style.flags.inverse = true;
            }
        }
        try w.print("\x1b[{d};1H", .{i + 2});
        try pen.set(w, style, null);
        try w.writeAll(" ");
        var cells: usize = 1;
        var name = std.unicode.Utf8View.initUnchecked(s.name).iterator();
        while (name.nextCodepoint()) |cp| : (cells += 1) {
            if (cells + 1 >= rail) break;
            try put(w, cp);
        }
        while (cells < rail) : (cells += 1) try w.writeAll(" ");
    }
}

fn chip(app: *const App) vt.Style {
    var style: vt.Style = .{};
    style.flags.bold = true;
    if (app.theme) |t| {
        style.fg_color = .rgb(.{ .r = t.ink.r, .g = t.ink.g, .b = t.ink.b });
        style.bg_color = .rgb(.{ .r = t.amber.r, .g = t.amber.g, .b = t.amber.b });
    } else {
        style.fg_color = .palette(4);
        style.flags.inverse = true;
    }
    return style;
}

/// The open menu, a box over the middle of the strip: an item a row, its key at the right, the
/// selected one a chip.
fn drawMenu(app: *const App, w: *Writer, open: menu.Menu) !void {
    const box = app.menuBox(open);
    const edge: vt.Style = if (app.theme) |t| rgbStyle(t.amber) else .{ .fg_color = .palette(4) };
    var title_buf: [menu.width]u8 = undefined;
    const title: []const u8 = if (open.items.ptr == &menu.confirm and app.focus < app.wins.items.len)
        std.fmt.bufPrint(&title_buf, " Close {s}? ", .{app.wins.items[app.focus].name}) catch " Close? "
    else
        " arena ";
    const title_cells = std.unicode.utf8CountCodepoints(title) catch title.len;
    var pen: Pen = .{};

    try w.print("\x1b[{d};{d}H", .{ box.y + 1, box.x + 1 });
    try pen.set(w, edge, null);
    try w.writeAll("╭─");
    try w.writeAll(title);
    for (0..menu.width -| (3 + title_cells)) |_| try w.writeAll("─");
    try w.writeAll("╮");
    for (open.items, 0..) |item, i| {
        try w.print("\x1b[{d};{d}H", .{ box.y + 2 + i, box.x + 1 });
        try pen.set(w, edge, null);
        try w.writeAll("│");
        try pen.set(w, if (i == open.selected) chip(app) else .{}, null);
        try w.print(" {s}", .{item.label});
        for (0..menu.width - 5 - item.label.len) |_| try w.writeAll(" ");
        try w.print("{c} ", .{item.key});
        try pen.set(w, edge, null);
        try w.writeAll("│");
    }
    try w.print("\x1b[{d};{d}H", .{ box.y + 2 + open.items.len, box.x + 1 });
    try w.writeAll("╰");
    for (0..menu.width - 2) |_| try w.writeAll("─");
    try w.writeAll("╯");
}

fn draw(app: *App, w: *Writer, what: Draw) !void {
    try w.writeAll("\x1b[?2026h\x1b[?25l\x1b[0m");
    const ox = app.term_w - app.view_w;
    if (what == .all) {
        try w.writeAll("\x1b[2J");
        try drawRail(app, w);
    }
    const col_w = app.colW();
    var cursor: ?struct { x: i32, y: i32 } = null;

    for (app.wins.items, 0..) |win, i| {
        const focused = i == app.focus;
        if (what == .focused_border and !focused) continue;
        const x0 = layout.colX(col_w, i) - app.scroll;
        const x1 = x0 + col_w - 1;
        const lo: i32 = @max(x0, 0);
        const hi: i32 = @min(x1 + 1, app.view_w);
        if (lo >= hi) continue;
        try win.render.update(app.gpa, &win.term);
        const rows = win.render.row_data.items(.cells)[win.render.viewportStart()..];

        var title_buf: [64]u8 = undefined;
        const title = std.fmt.bufPrint(&title_buf, " {d} {s} ", .{ i + 1, win.name }) catch title_buf[0..0];
        var title_cps: [64]u21 = undefined;
        var title_len: usize = 0;
        var view = std.unicode.Utf8View.initUnchecked(title).iterator();
        while (view.nextCodepoint()) |cp| : (title_len += 1) title_cps[title_len] = cp;
        if (title_len + 4 > col_w) title_len = 0;
        const col: Column = .{ .app = app, .index = i, .w = col_w, .focused = focused, .title = title_cps[0..title_len] };

        var pen: Pen = .{};
        var y: u16 = 0;
        while (y < app.view_h) : (y += 1) {
            const sy = y + app.yoff;
            if (sy < 0 or sy >= app.view_h) continue;
            if (y == 0 or y == app.view_h - 1) {
                try w.print("\x1b[{d};{d}H", .{ sy + 1, ox + lo + 1 });
                var sx = lo;
                while (sx < hi) : (sx += 1) try col.border(&pen, w, @intCast(sx - x0), y);
                continue;
            }
            if (x0 >= 0) {
                try w.print("\x1b[{d};{d}H", .{ sy + 1, ox + x0 + 1 });
                try col.border(&pen, w, 0, y);
            }
            if (x1 < app.view_w) {
                try w.print("\x1b[{d};{d}H", .{ sy + 1, ox + x1 + 1 });
                try col.border(&pen, w, col_w - 1, y);
            }
            if (what == .focused_border) continue;

            const row = rows[y - 1];
            const in_lo: i32 = @max(lo, x0 + 1);
            const in_hi: i32 = @min(hi, x1);
            if (in_lo >= in_hi) continue;
            try w.print("\x1b[{d};{d}H", .{ sy + 1, ox + in_lo + 1 });
            var sx = in_lo;
            while (sx < in_hi) : (sx += 1) {
                const tx: usize = @intCast(sx - x0 - 1);
                const raw = row.items(.raw)[tx];
                var style: vt.Style = if (raw.style_id != 0) row.items(.style)[tx] else .{};
                switch (raw.content_tag) {
                    .bg_color_palette => style.bg_color = .palette(raw.content.color_palette.data),
                    .bg_color_rgb => style.bg_color = .rgb(.{ .r = raw.content.color_rgb.r, .g = raw.content.color_rgb.g, .b = raw.content.color_rgb.b }),
                    else => {},
                }
                try pen.set(w, style, if (focused) null else &app.palette);
                // Half of a wide character at a clipped edge is drawn as a space.
                const whole = switch (raw.wide) {
                    .wide => sx + 1 < in_hi,
                    .spacer_tail => sx > in_lo,
                    else => true,
                };
                if (raw.wide == .spacer_tail and whole) continue;
                if (!whole or !raw.hasText()) {
                    try w.writeAll(" ");
                    continue;
                }
                try put(w, raw.content.codepoint.data);
                if (raw.content_tag == .codepoint_grapheme) {
                    for (row.items(.grapheme)[tx]) |cp| try put(w, cp);
                }
            }
        }

        if (focused and win.render.cursor.visible) if (win.render.cursor.viewport) |at| {
            const sx = x0 + 1 + at.x;
            if (sx >= lo and sx < hi and app.yoff == 0) cursor = .{ .x = ox + sx, .y = at.y + 1 };
        };
    }

    if (app.menu) |open| {
        try drawMenu(app, w, open);
        cursor = null;
    }
    try w.writeAll("\x1b[0m");
    if (cursor) |at| try w.print("\x1b[{d};{d}H\x1b[?25h", .{ at.y + 1, at.x + 1 });
    try w.writeAll("\x1b[?2026l");
}

const rail_button = "≡ menu";
const history_lines = 5000;
const mode_flags = "#{{alternate_on}} #{{?cursor_flag,0,1}} #{{mouse_standard_flag}} #{{mouse_button_flag}} #{{mouse_all_flag}} #{{mouse_sgr_flag}}";
/// What to feed a window's terminal for each of `mode_flags` that is 1, in the same order.
const mode_sets = [_][]const u8{ "\x1b[?1049h", "\x1b[?25l", "\x1b[?1000h", "\x1b[?1002h", "\x1b[?1003h", "\x1b[?1006h" };
const spin_frame_ms = 100;
const spin_turn_ms = 6000;

var resized = std.atomic.Value(bool).init(true);

fn onWinch(_: posix.SIG) callconv(.c) void {
    resized.store(true, .release);
}

fn winsize(app: *App) void {
    var ws: posix.winsize = undefined;
    if (posix.system.ioctl(posix.STDOUT_FILENO, posix.T.IOCGWINSZ, @intFromPtr(&ws)) != 0) return;
    if (ws.col == 0 or ws.row == 0) return;
    app.term_w = ws.col;
    app.fit();
    app.view_h = ws.row;
}

pub fn main(init: std.process.Init) !void {
    if (try run(init)) return;
    try std.Io.File.stderr().writeStreamingAll(init.io, "arena: tmux gave no session to show\n");
    std.process.exit(1);
}

/// Runs until the user leaves or tmux does; false when no session was ever shown.
fn run(init: std.process.Init) !bool {
    const gpa = init.gpa;
    const io = init.io;

    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(gpa);
    try argv.append(gpa, "tmux");
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    var session: ?[]const u8 = null;
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "-L") and i + 1 < args.len) {
            try argv.appendSlice(gpa, &.{ "-L", args[i + 1] });
            i += 1;
        } else session = args[i];
    }
    // A named session is attached or made. With no name, the most recent one, or a first one
    // when there is none: starting the server is what lets tmux's own restore bring sessions back.
    if (session) |name| {
        try argv.appendSlice(gpa, &.{ "-C", "new-session", "-A", "-s", name });
    } else {
        try argv.append(gpa, "has-session");
        const has = try std.process.run(gpa, io, .{ .argv = argv.items });
        gpa.free(has.stdout);
        gpa.free(has.stderr);
        argv.items.len -= 1;
        try argv.appendSlice(gpa, &.{ "-C", if (has.term.success()) "attach" else "new-session" });
    }

    var child = try std.process.spawn(io, .{ .argv = argv.items, .stdin = .pipe, .stdout = .pipe });
    defer _ = child.wait(io) catch {};

    // The attach itself answers with one block before anything we send.
    var app: App = .{ .gpa = gpa, .io = io, .tmux_in = child.stdin.? };
    defer app.deinit();
    try app.pending.append(gpa, .ignore);
    app.motion = init.environ_map.get("ARENA_REDUCED_MOTION") == null;
    if (init.environ_map.get("HOME")) |home| {
        const path = try std.fs.path.join(gpa, &.{ home, ".config/ficciones/theme/palette.sh" });
        defer gpa.free(path);
        if (std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(1 << 16))) |text| {
            defer gpa.free(text);
            app.theme = .parse(text);
        } else |_| {}
    }
    var last_spin: i64 = 0;

    const tty = std.Io.File.stdout();
    const saved = try posix.tcgetattr(posix.STDIN_FILENO);
    var raw = saved;
    raw.lflag.ECHO = false;
    raw.lflag.ICANON = false;
    raw.lflag.ISIG = false;
    raw.lflag.IEXTEN = false;
    raw.iflag.IXON = false;
    raw.iflag.ICRNL = false;
    raw.oflag.OPOST = false;
    raw.cc[@intFromEnum(posix.V.MIN)] = 1;
    raw.cc[@intFromEnum(posix.V.TIME)] = 0;
    try posix.tcsetattr(posix.STDIN_FILENO, .FLUSH, raw);
    defer posix.tcsetattr(posix.STDIN_FILENO, .FLUSH, saved) catch {};
    // 1002: presses, releases and drags; 1006: the SGR report format, which has no column limit
    try tty.writeStreamingAll(io, "\x1b[?1049h\x1b[?1002h\x1b[?1006h" ++ color.Palette.query);
    var typed: std.ArrayList(u8) = .empty;
    defer typed.deinit(gpa);
    defer tty.writeStreamingAll(io, "\x1b[?1006l\x1b[?1002l\x1b[0m\x1b[?25h\x1b[?1049l") catch {};

    posix.sigaction(.WINCH, &.{ .handler = .{ .handler = onWinch }, .mask = posix.sigemptyset(), .flags = 0 }, null);

    var fds = [_]posix.pollfd{
        .{ .fd = posix.STDIN_FILENO, .events = posix.POLL.IN, .revents = 0 },
        .{ .fd = child.stdout.?.handle, .events = posix.POLL.IN, .revents = 0 },
    };
    var line: std.ArrayList(u8) = .empty;
    defer line.deinit(gpa);
    var frame: Writer.Allocating = .init(gpa);
    defer frame.deinit();
    var buf: [65536]u8 = undefined;

    while (!app.quit) {
        if (resized.swap(false, .acq_rel)) {
            winsize(&app);
            try app.send(.ignore, "refresh-client -C {d}x{d}", .{ app.term_w, app.view_h });
            if (app.sessions.items.len == 0) try app.listSessions();
            if (app.listed) try app.relayout() else try app.listWindows();
            if (app.listed) app.scroll = app.target();
        }
        const spins = app.motion and app.theme != null;
        const now = std.Io.Timestamp.now(io, .awake).toMilliseconds();
        if (app.yoff != 0) {
            app.yoff = layout.step(app.yoff, 0);
            app.dirty = true;
        }
        if (app.listed and app.scroll != app.target()) {
            app.scroll = if (app.motion) layout.step(app.scroll, app.target()) else app.target();
            app.dirty = true;
        }
        if (app.listed and (app.dirty or (spins and now - last_spin >= spin_frame_ms))) {
            if (spins) {
                app.phase = @as(f32, @floatFromInt(@mod(now, spin_turn_ms))) / spin_turn_ms;
                last_spin = now;
            }
            // the menu lies over the border, so a border-only frame would cut through it
            const what: Draw = if (app.dirty or app.menu != null) .all else .focused_border;
            app.dirty = false;
            frame.clearRetainingCapacity();
            try draw(&app, &frame.writer, what);
            try tty.writeStreamingAll(io, frame.written());
        }

        const moving = app.listed and (app.scroll != app.target() or app.yoff != 0);
        const wait_ms: isize = if (moving) 16 else if (spins) @max(1, spin_frame_ms - (now - last_spin)) else 1000;
        const timeout: posix.timespec = .{ .sec = @divTrunc(wait_ms, 1000), .nsec = @mod(wait_ms, 1000) * std.time.ns_per_ms };
        _ = posix.ppoll(&fds, &timeout, null) catch |err| switch (err) {
            error.SignalInterrupt => continue,
            else => return err,
        };

        if (fds[0].revents & posix.POLL.IN != 0) {
            const n = try posix.read(posix.STDIN_FILENO, &buf);
            if (n == 0) break;
            try typed.appendSlice(gpa, buf[0..n]);
            const held = try app.onInput(typed.items);
            std.mem.copyForwards(u8, typed.items[0..held], typed.items[typed.items.len - held ..]);
            typed.items.len = held;
        }
        if (fds[1].revents & (posix.POLL.IN | posix.POLL.HUP) != 0) {
            const n = try posix.read(fds[1].fd, &buf);
            if (n == 0) break;
            var rest: []const u8 = buf[0..n];
            while (std.mem.indexOfScalar(u8, rest, '\n')) |nl| {
                try line.appendSlice(gpa, rest[0..nl]);
                try app.onLine(line.items);
                line.clearRetainingCapacity();
                rest = rest[nl + 1 ..];
            }
            try line.appendSlice(gpa, rest);
        }
    }

    child.stdin.?.close(io);
    child.stdin = null;
    return app.listed;
}

test {
    _ = control;
    _ = theme;
    _ = keys;
    _ = menu;
    _ = color;
    _ = layout;
}
