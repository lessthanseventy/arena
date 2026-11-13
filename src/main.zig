const std = @import("std");
const vt = @import("ghostty-vt");
const control = @import("control.zig");
const layout = @import("layout.zig");
const theme = @import("theme.zig");
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
            .term = try .init(app.io, app.gpa, .{ .cols = cols, .rows = rows }),
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

const Pending = union(enum) {
    ignore,
    windows,
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
            .exit => app.quit = true,
            .other => {},
        }
    }

    fn listWindows(app: *App) !void {
        try app.send(.windows, "list-windows -F '#{{window_id}} #{{pane_id}} #{{window_active}} #{{window_name}}'", .{});
    }

    fn onReply(app: *App, kind: Pending, body: []const u8) !void {
        switch (kind) {
            .ignore => {},
            .windows => try app.onWindows(body),
            .capture => |pane| {
                const win = app.byPane(pane) orelse return;
                win.stream.nextSlice("\x1b[H\x1b[2J");
                var lines = std.mem.splitScalar(u8, std.mem.trimEnd(u8, body, "\n"), '\n');
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
        if (focused_id) |id| for (app.wins.items, 0..) |win, i| {
            if (win.id == id) app.focus = i;
        };
        try app.relayout();
        for (app.wins.items) |win| {
            if (win.seeded) continue;
            try app.send(.{ .capture = win.pane }, "capture-pane -p -e -t %{d}", .{win.pane});
            try app.send(.{ .cursor = win.pane }, "display-message -p -t %{d} '#{{cursor_x}} #{{cursor_y}}'", .{win.pane});
        }
        if (!app.listed) app.scroll = app.target();
        app.listed = true;
    }

    fn focusBy(app: *App, delta: i32) !void {
        const next = @as(i32, @intCast(app.focus)) + delta;
        if (next < 0 or next >= app.wins.items.len) return;
        app.focus = @intCast(next);
        try app.send(.ignore, "select-window -t @{d}", .{app.wins.items[app.focus].id});
        app.dirty = true;
    }

    /// Alt+h and Alt+l move along the strip and Alt+q leaves; everything else is the focused
    /// window's. Alt is ESC and the letter in one read, which a typed Escape then a letter is not.
    fn onInput(app: *App, bytes: []const u8) !void {
        if (bytes.len == 2 and bytes[0] == 0x1b) switch (bytes[1]) {
            'h' => return app.focusBy(-1),
            'l' => return app.focusBy(1),
            'q' => {
                app.quit = true;
                return;
            },
            else => {},
        };
        if (app.focus >= app.wins.items.len) return;
        var cmd: Writer.Allocating = .init(app.gpa);
        defer cmd.deinit();
        try cmd.writer.print("send-keys -H -t %{d}", .{app.wins.items[app.focus].pane});
        for (bytes) |b| try cmd.writer.print(" {x:0>2}", .{b});
        try app.send(.ignore, "{s}", .{cmd.written()});
    }
};

const Pen = struct {
    style: vt.Style = .{},
    faint: bool = false,
    fresh: bool = true,

    fn set(pen: *Pen, w: *Writer, style: vt.Style, faint: bool) !void {
        if (!pen.fresh and pen.faint == faint and @as(u128, @bitCast(pen.style)) == @as(u128, @bitCast(style))) return;
        pen.* = .{ .style = style, .faint = faint, .fresh = false };
        try w.writeAll("\x1b[0");
        if (style.flags.bold) try w.writeAll(";1");
        if (style.flags.faint or faint) try w.writeAll(";2");
        if (style.flags.italic) try w.writeAll(";3");
        if (style.flags.underline != .none) try w.writeAll(";4");
        if (style.flags.inverse) try w.writeAll(";7");
        if (style.flags.strikethrough) try w.writeAll(";9");
        try color(w, 38, style.fg_color);
        try color(w, 48, style.bg_color);
        try w.writeAll("m");
    }

    /// Palette colours stay palette indices, so the outer terminal's theme shows through.
    fn color(w: *Writer, base: u8, c: vt.Style.Color) !void {
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
            try pen.set(w, style, false);
            return put(w, col.title[cx - 2]);
        }

        const count = app.wins.items.len;
        const dots = count * 2 + 1;
        if (bottom and col.focused and count > 1 and dots + 4 <= col.w) {
            const start = (col.w - dots) / 2;
            if (cx >= start and cx < start + dots) {
                const at = cx - start;
                const here = at / 2 == app.focus;
                try pen.set(w, if (app.theme) |t| rgbStyle(if (here) t.amber else t.dim) else .{ .fg_color = .palette(if (here) 4 else 8) }, false);
                return put(w, if (at % 2 == 0) ' ' else if (here) '●' else '○');
            }
        }

        const style: vt.Style = if (app.theme) |t| rgbStyle(theme.gradient(
            if (col.focused) t.amber else t.amberdim,
            if (col.focused) t.violet else t.emberdim,
            theme.around(col.w, h, cx, y),
            if (col.focused) app.phase else 0,
        )) else .{ .fg_color = .palette(if (col.focused) 4 else 8) };
        try pen.set(w, style, false);
        const left = cx == 0;
        const right = cx == col.w - 1;
        try put(w, if (top) (if (left) '╭' else if (right) '╮' else '─') else if (bottom) (if (left) '╰' else if (right) '╯' else '─') else '│');
    }
};

const Draw = enum { all, focused_border };

fn draw(app: *App, w: *Writer, what: Draw) !void {
    try w.writeAll("\x1b[?2026h\x1b[?25l\x1b[0m");
    if (what == .all) try w.writeAll("\x1b[2J");
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
            if (y == 0 or y == app.view_h - 1) {
                try w.print("\x1b[{d};{d}H", .{ y + 1, lo + 1 });
                var sx = lo;
                while (sx < hi) : (sx += 1) try col.border(&pen, w, @intCast(sx - x0), y);
                continue;
            }
            if (x0 >= 0) {
                try w.print("\x1b[{d};{d}H", .{ y + 1, x0 + 1 });
                try col.border(&pen, w, 0, y);
            }
            if (x1 < app.view_w) {
                try w.print("\x1b[{d};{d}H", .{ y + 1, x1 + 1 });
                try col.border(&pen, w, col_w - 1, y);
            }
            if (what == .focused_border) continue;

            const row = rows[y - 1];
            const in_lo: i32 = @max(lo, x0 + 1);
            const in_hi: i32 = @min(hi, x1);
            if (in_lo >= in_hi) continue;
            try w.print("\x1b[{d};{d}H", .{ y + 1, in_lo + 1 });
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
                try pen.set(w, style, !focused);
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
            if (sx >= lo and sx < hi) cursor = .{ .x = sx, .y = at.y + 1 };
        };
    }

    try w.writeAll("\x1b[0m");
    if (cursor) |at| try w.print("\x1b[{d};{d}H\x1b[?25h", .{ at.y + 1, at.x + 1 });
    try w.writeAll("\x1b[?2026l");
}

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
    app.view_w = ws.col;
    app.view_h = ws.row;
}

pub fn main(init: std.process.Init) !void {
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
    try argv.appendSlice(gpa, &.{ "-C", "attach" });
    if (session) |name| try argv.appendSlice(gpa, &.{ "-t", name });

    var child = try std.process.spawn(io, .{ .argv = argv.items, .stdin = .pipe, .stdout = .pipe });
    defer _ = child.wait(io) catch {};

    // The attach itself answers with one block before anything we send.
    var app: App = .{ .gpa = gpa, .io = io, .tmux_in = child.stdin.? };
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
    try tty.writeStreamingAll(io, "\x1b[?1049h");
    defer tty.writeStreamingAll(io, "\x1b[0m\x1b[?25h\x1b[?1049l") catch {};

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
            try app.send(.ignore, "refresh-client -C {d}x{d}", .{ app.view_w, app.view_h });
            if (app.listed) try app.relayout() else try app.listWindows();
            if (app.listed) app.scroll = app.target();
        }
        const spins = app.motion and app.theme != null;
        const now = std.Io.Timestamp.now(io, .awake).toMilliseconds();
        if (app.listed and app.scroll != app.target()) {
            app.scroll = if (app.motion) layout.step(app.scroll, app.target()) else app.target();
            app.dirty = true;
        }
        if (app.listed and (app.dirty or (spins and now - last_spin >= spin_frame_ms))) {
            if (spins) {
                app.phase = @as(f32, @floatFromInt(@mod(now, spin_turn_ms))) / spin_turn_ms;
                last_spin = now;
            }
            const what: Draw = if (app.dirty) .all else .focused_border;
            app.dirty = false;
            frame.clearRetainingCapacity();
            try draw(&app, &frame.writer, what);
            try tty.writeStreamingAll(io, frame.written());
        }

        const moving = app.listed and app.scroll != app.target();
        const wait_ms: isize = if (moving) 16 else if (spins) @max(1, spin_frame_ms - (now - last_spin)) else 1000;
        const timeout: posix.timespec = .{ .sec = @divTrunc(wait_ms, 1000), .nsec = @mod(wait_ms, 1000) * std.time.ns_per_ms };
        _ = posix.ppoll(&fds, &timeout, null) catch |err| switch (err) {
            error.SignalInterrupt => continue,
            else => return err,
        };

        if (fds[0].revents & posix.POLL.IN != 0) {
            const n = try posix.read(posix.STDIN_FILENO, &buf);
            if (n == 0) break;
            try app.onInput(buf[0..n]);
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
}

test {
    _ = control;
    _ = theme;
    _ = layout;
}
