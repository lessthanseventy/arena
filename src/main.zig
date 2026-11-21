const std = @import("std");
const layout = @import("layout.zig");
const color = @import("color.zig");
const draw = @import("draw.zig");
const keys = @import("keys.zig");
const Theme = @import("theme.zig").Theme;
const App = @import("app.zig").App;
const posix = std.posix;
const Writer = std.Io.Writer;

const spin_frame_ms = 100;
const spin_turn_ms = 6000;
/// The least time between two whole frames: a window pouring out text is drawn at this rate,
/// not once for every read of it.
const frame_ms = 8;
const theme_check_ms = 1000;
/// How often tmux is asked what its windows are up to, for their marks.
const list_ms = 2000;
/// The longest the loop sleeps. A resize sets a flag from its signal, and is seen at the next
/// wake: poll, unlike ppoll, is on every system arena builds for, and is not cut short by one.
const idle_ms = 100;

var winch = std.atomic.Value(bool).init(true);

fn onWinch(_: posix.SIG) callconv(.c) void {
    winch.store(true, .release);
}

fn winsize() ?posix.winsize {
    var ws: posix.winsize = undefined;
    if (posix.system.ioctl(posix.STDOUT_FILENO, posix.T.IOCGWINSZ, @intFromPtr(&ws)) != 0) return null;
    if (ws.col == 0 or ws.row == 0) return null;
    return ws;
}

/// The machine palette, read again whenever its file changes, so a theme switch reaches a
/// running arena. The terminal is asked for its colours again then too.
const ThemeFile = struct {
    path: ?[]u8,
    text: []u8 = &.{},
    /// The terminal may take the new theme after the file changes: it is asked once more.
    ask_again: bool = false,

    fn check(file: *ThemeFile, app: *App, tty: std.Io.File) !void {
        const path = file.path orelse return;
        if (file.ask_again) try tty.writeStreamingAll(app.io, color.Palette.query);
        file.ask_again = false;
        const text = std.Io.Dir.cwd().readFileAlloc(app.io, path, app.gpa, .limited(1 << 16)) catch return;
        if (std.mem.eql(u8, text, file.text)) return app.gpa.free(text);
        app.gpa.free(file.text);
        file.text = text;
        app.theme = Theme.parse(text);
        app.dirty = true;
        file.ask_again = true;
        try tty.writeStreamingAll(app.io, color.Palette.query);
    }

    fn deinit(file: *ThemeFile, app: *App) void {
        app.gpa.free(file.text);
        if (file.path) |path| app.gpa.free(path);
    }
};

/// babylon's board, read again with the theme, and handed to arena when it changed.
/// Where babylon writes its board: the runtime dir, or beside its database where there is none (the Mac).
fn boardPath(gpa: std.mem.Allocator, env: *const std.process.Environ.Map) !?[]u8 {
    if (env.get("XDG_RUNTIME_DIR")) |dir| return try std.fs.path.join(gpa, &.{ dir, "babylon/board.json" });
    if (env.get("XDG_STATE_HOME")) |dir| return try std.fs.path.join(gpa, &.{ dir, "babylon/board.json" });
    if (env.get("HOME")) |home| return try std.fs.path.join(gpa, &.{ home, ".local/state/babylon/board.json" });
    return null;
}

test boardPath {
    const gpa = std.testing.allocator;
    var env: std.process.Environ.Map = .init(gpa);
    defer env.deinit();
    try std.testing.expectEqual(null, try boardPath(gpa, &env));
    try env.put("HOME", "/Users/a");
    const mac = (try boardPath(gpa, &env)).?;
    defer gpa.free(mac);
    try std.testing.expectEqualStrings("/Users/a/.local/state/babylon/board.json", mac);
    try env.put("XDG_RUNTIME_DIR", "/run/user/1000");
    const linux = (try boardPath(gpa, &env)).?;
    defer gpa.free(linux);
    try std.testing.expectEqualStrings("/run/user/1000/babylon/board.json", linux);
}

const BoardFile = struct {
    path: ?[]u8,
    text: ?[]u8 = null,

    fn check(file: *BoardFile, app: *App) void {
        const path = file.path orelse return;
        const text = std.Io.Dir.cwd().readFileAlloc(app.io, path, app.gpa, .limited(1 << 22)) catch null;
        const same = if (text) |now| (if (file.text) |was| std.mem.eql(u8, now, was) else false) else file.text == null;
        if (same) {
            if (text) |now| app.gpa.free(now);
            return;
        }
        if (file.text) |was| app.gpa.free(was);
        file.text = text;
        app.setBoard(text);
    }

    /// The detail of the card the board shows, once babylon has written it beside the board.
    /// Each detail asked for is taken in, the open card's read: none is left beside the board,
    /// whichever way its box closed, one written after it closed too.
    fn checkDetail(file: *BoardFile, app: *App) void {
        _ = file;
        const open = if (app.board_view) |view| view.detail else null;
        var i: usize = 0;
        while (i < app.detail_asked.items.len) {
            const id = app.detail_asked.items[i];
            var buf: [std.fs.max_path_bytes]u8 = undefined;
            const path = app.detailPath(id, &buf) orelse return;
            if (id == open) readDetail(app, path);
            if (std.Io.Dir.cwd().deleteFile(app.io, path)) {
                _ = app.detail_asked.orderedRemove(i);
            } else |_| i += 1;
        }
    }

    fn readDetail(app: *App, path: []const u8) void {
        const text = std.Io.Dir.cwd().readFileAlloc(app.io, path, app.gpa, .limited(1 << 20)) catch return;
        defer app.gpa.free(text);
        var clean: std.ArrayList(u8) = .empty;
        @import("app.zig").appendClean(&clean, app.gpa, text) catch {
            clean.deinit(app.gpa);
            return;
        };
        if (std.mem.eql(u8, clean.items, app.detail.items)) return clean.deinit(app.gpa);
        app.detail.deinit(app.gpa);
        app.detail = clean;
        app.dirty = true;
    }

    fn deinit(file: *BoardFile, app: *App) void {
        for (app.detail_asked.items) |id| {
            var buf: [std.fs.max_path_bytes]u8 = undefined;
            if (app.detailPath(id, &buf)) |path| std.Io.Dir.cwd().deleteFile(app.io, path) catch {};
        }
        if (file.text) |was| app.gpa.free(was);
        if (file.path) |path| app.gpa.free(path);
    }
};

pub fn main(init: std.process.Init) !void {
    if (try run(init)) return;
    try std.Io.File.stderr().writeStreamingAll(init.io, "arena: tmux gave no session to show\n");
    std.process.exit(1);
}

fn hasSession(init: std.process.Init, tmux: []const []const u8) !bool {
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(init.gpa);
    try argv.appendSlice(init.gpa, tmux);
    try argv.append(init.gpa, "has-session");
    const has = try std.process.run(init.gpa, init.io, .{ .argv = argv.items });
    init.gpa.free(has.stdout);
    init.gpa.free(has.stderr);
    return has.term.success();
}

/// Runs until the user leaves or tmux has no session left; false when none was ever shown.
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
    const tmux = try gpa.dupe([]const u8, argv.items);
    defer gpa.free(tmux);
    if (session) |name| {
        try argv.appendSlice(gpa, &.{ "-C", "new-session", "-A", "-s", name });
    } else {
        try argv.appendSlice(gpa, &.{ "-C", if (try hasSession(init, tmux)) "attach" else "new-session" });
    }

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
    raw.cc[@backingInt(posix.V.MIN)] = 1;
    raw.cc[@backingInt(posix.V.TIME)] = 0;
    try posix.tcsetattr(posix.STDIN_FILENO, .FLUSH, raw);
    defer posix.tcsetattr(posix.STDIN_FILENO, .FLUSH, saved) catch {};
    // 1003: presses, releases and every move of the pointer, for its shape over what it can
    // take hold of; 1006: the SGR report format, which has no column limit; >1s: shift clicks
    // come here, not to the terminal's own selection
    try tty.writeStreamingAll(io, "\x1b[?1049h\x1b[?1003h\x1b[?1006h\x1b[>1s");
    defer tty.writeStreamingAll(io, "\x1b[>0s\x1b[?1006l\x1b[?1003l\x1b]22;default\x1b\\\x1b[0m\x1b[?25h\x1b[?1049l") catch {};

    posix.sigaction(.WINCH, &.{ .handler = .{ .handler = onWinch }, .mask = posix.sigemptyset(), .flags = 0 }, null);

    // tmux ends a client whose session ends, as when the last shell in it exits. While there
    // are other sessions that is no reason to leave: arena attaches again, to the most recent.
    var shown = false;
    while (true) {
        switch (try attached(init, argv.items, tty)) {
            .left => return true,
            .never => return shown,
            .lost => shown = true,
        }
        if (!try hasSession(init, tmux)) return true;
        argv.items.len = tmux.len;
        try argv.appendSlice(gpa, &.{ "-C", "attach" });
    }
}

const Outcome = enum { left, lost, never };

/// One tmux client's life: until the user leaves (`left`) or tmux ends it, after showing a
/// session (`lost`) or before (`never`).
fn attached(init: std.process.Init, argv: []const []const u8, tty: std.Io.File) !Outcome {
    const gpa = init.gpa;
    const io = init.io;
    var child = try std.process.spawn(io, .{ .argv = argv, .stdin = .pipe, .stdout = .pipe });
    defer _ = child.wait(io) catch {};
    defer if (child.stdin) |stdin| {
        stdin.close(io);
        child.stdin = null;
    };

    var app: App = .{ .gpa = gpa, .io = io, .tmux_in = child.stdin.? };
    defer app.deinit();
    app.motion = init.environ_map.get("ARENA_REDUCED_MOTION") == null;
    var theme_file: ThemeFile = .{
        .path = if (init.environ_map.get("HOME")) |home| try std.fs.path.join(gpa, &.{ home, ".config/ficciones/theme/palette.sh" }) else null,
    };
    defer theme_file.deinit(&app);
    var board_file: BoardFile = .{
        .path = try boardPath(gpa, init.environ_map),
    };
    defer board_file.deinit(&app);
    app.board_dir = if (board_file.path) |path| std.fs.path.dirname(path) else null;
    winch.store(true, .release);
    try tty.writeStreamingAll(io, color.Palette.query);

    var fds = [_]posix.pollfd{
        .{ .fd = posix.STDIN_FILENO, .events = posix.POLL.IN, .revents = 0 },
        .{ .fd = child.stdout.?.handle, .events = posix.POLL.IN, .revents = 0 },
    };
    var typed: std.ArrayList(u8) = .empty;
    var held_at: i64 = 0;
    defer typed.deinit(gpa);
    var line: std.ArrayList(u8) = .empty;
    defer line.deinit(gpa);
    var frame: Writer.Allocating = .init(gpa);
    defer frame.deinit();
    var buf: [65536]u8 = undefined;
    var last_spin: i64 = 0;
    var last_frame: i64 = 0;
    var theme_checked: i64 = -theme_check_ms;
    var listed_at: i64 = 0;

    while (!app.quit) {
        const now = std.Io.Timestamp.now(io, .awake).toMilliseconds();
        app.now = now;
        app.epoch = std.Io.Timestamp.now(io, .real).toSeconds();
        if (now - listed_at >= list_ms) {
            listed_at = now;
            app.want_list = true;
        }
        if (winch.swap(false, .acq_rel)) if (winsize()) |ws| try app.resized(ws.col, ws.row, ws.xpixel / ws.col, ws.ypixel / ws.row);
        if (now - theme_checked >= theme_check_ms) {
            theme_checked = now;
            try theme_file.check(&app, tty);
            board_file.check(&app);
            board_file.checkDetail(&app);
        }
        if (app.want_list and !app.listing) try app.requestList();

        if (app.yoff != 0) {
            app.yoff = layout.step(app.yoff, 0);
            app.dirty = true;
        }
        const strip = app.cur();
        if (strip) |s| if (s.placed and s.scroll != app.target(s)) {
            s.scroll = if (app.motion) layout.step(s.scroll, app.target(s)) else app.target(s);
            app.dirty = true;
        };
        const moving = app.yoff != 0 or (strip != null and strip.?.scroll != app.target(strip.?));

        const spins = app.motion and (app.theme != null or app.working()) and app.yoff == 0;
        const whole = app.dirty and now - last_frame >= frame_ms;
        const turn = spins and !app.dirty and now - last_spin >= spin_frame_ms;
        if (app.listed and (whole or turn)) {
            if (spins) {
                app.phase = @as(f32, @floatFromInt(@mod(now, spin_turn_ms))) / spin_turn_ms;
                last_spin = now;
            }
            // the menu lies over the border, so a border-only frame would cut through it
            const what: draw.What = if (whole or app.overlay() or app.peek) .all else .focused_border;
            if (whole) last_frame = now;
            app.dirty = false;
            frame.clearRetainingCapacity();
            try draw.frame(&app, &frame.writer, what);
            try tty.writeStreamingAll(io, frame.written());
        }
        if (app.out.items.len > 0) {
            try tty.writeStreamingAll(io, app.out.items);
            app.out.clearRetainingCapacity();
        }

        const wait_ms: i64 = if (app.dirty)
            @max(1, frame_ms - (now - last_frame))
        else if (moving)
            16
        else if (spins)
            @max(1, spin_frame_ms - (now - last_spin))
        else
            idle_ms;
        const lone = keys.lone(typed.items);
        _ = try posix.poll(&fds, @intCast(@min(wait_ms, idle_ms, @max(1, app.dwell()), if (lone) @as(i64, keys.lone_wait_ms) else idle_ms)));

        if (fds[0].revents & posix.POLL.IN != 0) {
            const n = try posix.read(posix.STDIN_FILENO, &buf);
            if (n == 0) return .left;
            try typed.appendSlice(gpa, buf[0..n]);
            const held = try app.onInput(typed.items);
            std.mem.copyForwards(u8, typed.items[0..held], typed.items[typed.items.len - held ..]);
            typed.items.len = held;
            if (held > 0) held_at = std.Io.Timestamp.now(io, .awake).toMilliseconds();
        } else if (lone and std.Io.Timestamp.now(io, .awake).toMilliseconds() - held_at >= keys.lone_wait_ms) {
            try app.typedAlone(typed.items);
            typed.items.len = 0;
        }
        if (fds[1].revents & (posix.POLL.IN | posix.POLL.HUP) != 0) {
            const n = try posix.read(fds[1].fd, &buf);
            if (n == 0) {
                app.ended = true;
                break;
            }
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

    if (!app.ended) return .left;
    return if (app.listed) .lost else .never;
}

test {
    _ = @import("app.zig");
    _ = @import("control.zig");
    _ = @import("theme.zig");
    _ = @import("board.zig");
    _ = @import("keys.zig");
    _ = @import("menu.zig");
    _ = @import("pass.zig");
    _ = color;
    _ = layout;
}
