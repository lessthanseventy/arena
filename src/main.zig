const std = @import("std");
const build_options = @import("build_options");
const layout = @import("layout.zig");
const color = @import("color.zig");
const draw = @import("draw.zig");
const keys = @import("keys.zig");
const control = @import("control.zig");
const update = @import("update.zig");
const Theme = @import("theme.zig").Theme;
const Roles = @import("theme.zig").Roles;
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

const tty_restore = "\x1b[>4;0m\x1b[>0s\x1b[?2004l\x1b[?1006l\x1b[?1003l\x1b]22;default\x1b\\\x1b[0m\x1b[?25h\x1b[?1049l";

/// The terminal as it was, set once arena has taken it over: what a panic gives back, as a clean
/// quit does, so a crash leaves no mouse reports typed into the shell.
var saved_tty: ?posix.termios = null;

pub const panic = std.debug.FullPanic(panicRestoring);

fn panicRestoring(msg: []const u8, first_trace_addr: ?usize) noreturn {
    if (saved_tty) |saved| {
        saved_tty = null;
        _ = posix.system.write(posix.STDOUT_FILENO, tty_restore, tty_restore.len);
        posix.tcsetattr(posix.STDIN_FILENO, .FLUSH, saved) catch {};
    }
    std.debug.defaultPanic(msg, first_trace_addr);
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
        app.roles = Roles.parse(text);
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

/// Where reports are saved: beside the state babylon keeps, under arena's name.
fn reportsPath(gpa: std.mem.Allocator, env: *const std.process.Environ.Map) !?[]u8 {
    if (env.get("XDG_STATE_HOME")) |dir| return try std.fs.path.join(gpa, &.{ dir, "arena/reports" });
    if (env.get("HOME")) |home| return try std.fs.path.join(gpa, &.{ home, ".local/state/arena/reports" });
    return null;
}

/// Where the folded repos are kept, beside the reports.
fn foldsPath(gpa: std.mem.Allocator, env: *const std.process.Environ.Map) !?[]u8 {
    if (env.get("XDG_STATE_HOME")) |dir| return try std.fs.path.join(gpa, &.{ dir, "arena/folded" });
    if (env.get("HOME")) |home| return try std.fs.path.join(gpa, &.{ home, ".local/state/arena/folded" });
    return null;
}

const BoardFile = struct {
    path: ?[]u8,
    text: ?[]u8 = null,

    fn check(file: *BoardFile, app: *App) !void {
        const path = file.path orelse return;
        const text = std.Io.Dir.cwd().readFileAlloc(app.io, path, app.gpa, .limited(1 << 22)) catch null;
        const same = if (text) |now| (if (file.text) |was| std.mem.eql(u8, now, was) else false) else file.text == null;
        if (same) {
            if (text) |now| app.gpa.free(now);
            return;
        }
        if (file.text) |was| app.gpa.free(was);
        file.text = text;
        try app.setBoard(text);
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
        @import("text.zig").appendClean(&clean, app.gpa, text) catch {
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

/// babylon's refusals of what the feed ran, written beside its board, taken in for the feed to say.
fn checkRefusals(app: *App) !void {
    try takeRefusal(app, "report");
    const b = if (app.board) |*b| b else return;
    for (b.needsYou()) |need| try takeRefusal(app, need.id);
    var wanted = app.auto_wants.list.items.len;
    while (wanted > 0) {
        wanted -= 1;
        const want = app.auto_wants.list.items[wanted];
        if (want.due != 0) continue;
        var id: [96]u8 = undefined;
        try takeRefusal(app, want.id(&id));
    }
    for (b.next()) |item| {
        var id: [24]u8 = undefined;
        try takeRefusal(app, std.fmt.bufPrint(&id, "next:{d}", .{item.ticket}) catch continue);
    }
    try takeRefusal(app, "start");
    try takeRefusal(app, "move");
    try takeRefusal(app, "goal");
}

fn takeRefusal(app: *App, id: []const u8) !void {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = app.refusalPath(id, &buf) orelse return;
    const text = std.Io.Dir.cwd().readFileAlloc(app.io, path, app.gpa, .limited(1 << 12)) catch return;
    defer app.gpa.free(text);
    std.Io.Dir.cwd().deleteFile(app.io, path) catch {};
    if (std.mem.startsWith(u8, id, "auto:")) return app.autoRefused(id, text);
    if (std.mem.eql(u8, id, "start")) return app.startAnswered(text);
    if (std.mem.eql(u8, id, "report")) return app.reportAnswered(text);
    if (std.mem.eql(u8, id, "goal")) return app.goalAnswered(text);
    if (std.mem.eql(u8, id, "move")) {
        var said: [256]u8 = undefined;
        return app.reportAnswered(std.fmt.bufPrint(&said, "no {s}", .{text}) catch "no babylon refused the move");
    }
    try app.refuse(id, text);
}

pub fn main(init: std.process.Init) !void {
    const exe: ?[:0]u8 = std.process.executablePathAlloc(init.io, init.gpa) catch null;
    defer if (exe) |path| init.gpa.free(path);
    switch (try run(init, exe)) {
        .shown => return,
        .none => {
            try std.Io.File.stderr().writeStreamingAll(init.io, "arena: tmux gave no session to show\n");
            std.process.exit(1);
        },
        .update => try replaceSelf(init, exe.?),
    }
}

/// Runs the build now at `exe` in this process's place, with the arguments it was given. The
/// new one starts its own watch from what it is, so one install is one restart.
fn replaceSelf(init: std.process.Init, exe: []const u8) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    const argv = try init.arena.allocator().dupe([]const u8, args);
    argv[0] = exe;
    const failed = std.process.replace(init.io, .{ .argv = argv });
    update.discard(init);
    var said: [256]u8 = undefined;
    try std.Io.File.stderr().writeStreamingAll(init.io, std.fmt.bufPrint(&said, "arena: the new build would not start: {t}\n", .{failed}) catch "arena: the new build would not start\n");
    std.process.exit(1);
}

fn hasSession(init: std.process.Init, tmux: []const []const u8, target: ?[]const u8) !bool {
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(init.gpa);
    try argv.appendSlice(init.gpa, tmux);
    try argv.append(init.gpa, "has-session");
    if (target) |t| try argv.appendSlice(init.gpa, &.{ "-t", t });
    const has = try std.process.run(init.gpa, init.io, .{ .argv = argv.items });
    init.gpa.free(has.stdout);
    init.gpa.free(has.stderr);
    return has.term.success();
}

/// The server option each arena adds its client's name to: a control-mode client not named
/// there, as iTerm's, is no arena. A name outlives its client there, so it marks only a
/// client still on the server.
const clients_option = "@arena_clients";

const usage =
    \\usage: arena [-L socket] [session]
    \\       arena --version
    \\       arena [-L socket] plan <ticket>          the plan with its pick on that ticket
    \\       arena [-L socket] board <ticket>         the same: board is its old name
    \\       arena [-L socket] show <%pane|#ticket>   that pane, or the Claude holding that ticket, in front
    \\       arena [-L socket] inbox                  home, with what needs you
    \\
    \\plan, board, show and inbox tell the arena that is running; with none, plan starts one,
    \\and show and inbox exit 3.
    \\
;

/// The exit status of `arena show` and `arena inbox` when no arena is running: the caller opens one.
const no_arena = 3;

/// Whether `target` names a pane (`%290`) or a ticket (`#324`).
fn showTarget(target: []const u8) bool {
    return target.len > 1 and (target[0] == '%' or target[0] == '#') and ticketId(target[1..]) != null;
}

/// Whether `arg` is one of arena's verbs, which are reserved: never a session's name.
fn isVerb(arg: []const u8) bool {
    return std.mem.eql(u8, arg, "plan") or std.mem.eql(u8, arg, "board") or std.mem.eql(u8, arg, "show") or std.mem.eql(u8, arg, "inbox");
}

/// Whether `verb` is given what it takes as its next argument, `next` (null at the end).
fn verbArgOk(verb: []const u8, next: ?[]const u8) bool {
    if (std.mem.eql(u8, verb, "inbox")) return next == null;
    const arg = next orelse return false;
    if (std.mem.eql(u8, verb, "plan") or std.mem.eql(u8, verb, "board")) return ticketId(arg) != null;
    return showTarget(arg);
}

test showTarget {
    try std.testing.expect(showTarget("%290"));
    try std.testing.expect(showTarget("#324"));
    try std.testing.expect(!showTarget("#"));
    try std.testing.expect(!showTarget("%"));
    try std.testing.expect(!showTarget("324"));
    try std.testing.expect(!showTarget("#x"));
    try std.testing.expect(!showTarget("#-1"));
}

test isVerb {
    try std.testing.expect(isVerb("plan"));
    try std.testing.expect(isVerb("board"));
    try std.testing.expect(isVerb("show"));
    try std.testing.expect(isVerb("inbox"));
    try std.testing.expect(!isVerb("-h"));
    try std.testing.expect(!isVerb("work"));
}

test verbArgOk {
    try std.testing.expect(verbArgOk("inbox", null));
    try std.testing.expect(!verbArgOk("inbox", "foo"));
    try std.testing.expect(verbArgOk("plan", "12"));
    try std.testing.expect(!verbArgOk("plan", null));
    try std.testing.expect(verbArgOk("board", "12"));
    try std.testing.expect(!verbArgOk("board", "foo"));
    try std.testing.expect(!verbArgOk("board", null));
    try std.testing.expect(verbArgOk("show", "#12"));
    try std.testing.expect(verbArgOk("show", "%290"));
    try std.testing.expect(!verbArgOk("show", "foo"));
    try std.testing.expect(!verbArgOk("show", null));
}

/// Has every arena on the server take `message`, and says whether one was told.
fn tell(init: std.process.Init, tmux: []const []const u8, message: []const u8) !bool {
    const gpa = init.gpa;
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(gpa);
    try argv.appendSlice(gpa, tmux);
    const arenas = "#{&&:#{client_control_mode},#{m:* #{client_name} *,#{" ++ clients_option ++ "}}}";
    try argv.appendSlice(gpa, &.{ "list-clients", "-F", "#{client_name}", "-f", arenas });
    const clients = try std.process.run(gpa, init.io, .{ .argv = argv.items });
    defer gpa.free(clients.stdout);
    defer gpa.free(clients.stderr);
    if (!clients.term.success()) return false;
    // display-message runs its text through strftime: a pane's % would be taken for a conversion
    const escaped = try std.mem.replaceOwned(u8, gpa, message, "%", "%%");
    defer gpa.free(escaped);
    var told = false;
    var lines = std.mem.tokenizeScalar(u8, clients.stdout, '\n');
    while (lines.next()) |client| {
        argv.items.len = tmux.len;
        try argv.appendSlice(gpa, &.{ "display-message", "-c", client, escaped });
        const said = try std.process.run(gpa, init.io, .{ .argv = argv.items });
        gpa.free(said.stdout);
        gpa.free(said.stderr);
        told = told or said.term.success();
    }
    return told;
}

const Ended = enum { shown, none, update };

/// Runs until the user leaves or tmux has no session left, or a new build is installed: `none`
/// when no session was ever shown.
fn run(init: std.process.Init, exe: ?[]const u8) !Ended {
    const gpa = init.gpa;
    const io = init.io;

    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(gpa);
    try argv.append(gpa, "tmux");
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    var session: ?[]const u8 = null;
    var card: ?u32 = null;
    var door: ?[]const u8 = null;
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "-h") or std.mem.eql(u8, args[i], "--help")) {
            try std.Io.File.stdout().writeStreamingAll(io, usage);
            return .shown;
        } else if (std.mem.eql(u8, args[i], "--version")) {
            try std.Io.File.stdout().writeStreamingAll(io, "arena " ++ build_options.commit ++ "\n");
            return .shown;
        } else if (std.mem.eql(u8, args[i], "-L") and i + 1 < args.len) {
            try argv.appendSlice(gpa, &.{ "-L", args[i + 1] });
            i += 1;
        } else if (isVerb(args[i])) {
            const next: ?[]const u8 = if (i + 1 < args.len) args[i + 1] else null;
            if (!verbArgOk(args[i], next)) {
                try std.Io.File.stderr().writeStreamingAll(io, usage);
                std.process.exit(2);
            }
            if (std.mem.eql(u8, args[i], "plan") or std.mem.eql(u8, args[i], "board")) {
                card = ticketId(next.?);
                i += 1;
            } else if (std.mem.eql(u8, args[i], "show")) {
                door = try std.fmt.allocPrint(init.arena.allocator(), control.show_message ++ "{s}", .{next.?});
                i += 1;
            } else door = control.inbox_message;
        } else session = args[i];
    }
    if (door) |message| {
        if (try tell(init, argv.items, message)) return .shown;
        try std.Io.File.stderr().writeStreamingAll(io, "arena: none is running there\n");
        std.process.exit(no_arena);
    }
    if (card) |id| {
        const message = try std.fmt.allocPrint(gpa, control.card_message ++ "{d}", .{id});
        defer gpa.free(message);
        if (try tell(init, argv.items, message)) return .shown;
    }
    // A named session is attached or made. With no name, the most recent one, or a first one
    // when there is none: starting the server is what lets tmux's own restore bring sessions back.
    const tmux = try gpa.dupe([]const u8, argv.items);
    defer gpa.free(tmux);
    if (session) |name| {
        try argv.appendSlice(gpa, &.{ "-C", "new-session", "-A", "-s", name });
    } else {
        try argv.appendSlice(gpa, &.{ "-C", if (try hasSession(init, tmux, null)) "attach" else "new-session" });
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
    saved_tty = saved;
    // 1003: presses, releases and every move of the pointer, for its shape over what it can
    // take hold of; 1006: the SGR report format, which has no column limit; >1s: shift clicks
    // come here, not to the terminal's own selection
    try tty.writeStreamingAll(io, "\x1b[?1049h\x1b[?1003h\x1b[?1006h\x1b[>1s");
    defer tty.writeStreamingAll(io, tty_restore) catch {};
    if (init.environ_map.get("ARENA_TEST_PANIC") != null) @panic("ARENA_TEST_PANIC");

    posix.sigaction(.WINCH, &.{ .handler = .{ .handler = onWinch }, .mask = posix.sigemptyset(), .flags = 0 }, null);

    // tmux ends a client whose session ends, as when the last shell in it exits. While there
    // are other sessions that is no reason to leave: arena attaches again, to the most recent.
    var shown = false;
    // with no session named, arena opens home
    var open: Open = if (card) |id| .{ .card = id } else if (session == null) .home else .as_is;
    // an arena that replaced itself opens where the one before it left off, and says so once
    const arrival = update.arrive(init);
    if (arrival.kept) |was| open = .{ .kept = was };
    var told_of: ?update.Arrival = if (arrival.kept != null or arrival.ticket != null) arrival else null;
    var watch: ?update.Watch = if (exe) |path| update.Watch.init(io, path) else null;
    var target_buf: [16]u8 = undefined;
    while (true) {
        var kept: ?App.Kept = null;
        const outcome = try attached(init, argv.items, tty, open, &kept, if (watch) |*w| w else null, told_of);
        told_of = null;
        switch (outcome) {
            .left => return .shown,
            .never => return if (shown) .shown else .none,
            .lost => shown = true,
            .update => {
                try update.save(init, kept);
                return .update;
            },
        }
        open = if (kept) |was| .{ .kept = was } else .as_is;
        if (!try hasSession(init, tmux, null)) return .shown;
        argv.items.len = tmux.len;
        try argv.appendSlice(gpa, &.{ "-C", "attach" });
        // home stays where the human was, not in the session tmux would pick
        if (kept) |was| if (was.view.back) |id| {
            const target = try std.fmt.bufPrint(&target_buf, "${d}", .{id});
            if (try hasSession(init, tmux, target)) try argv.appendSlice(gpa, &.{ "-t", target });
        };
    }
}

fn ticketId(arg: []const u8) ?u32 {
    return std.fmt.parseInt(u32, arg, 10) catch null;
}

const Outcome = enum { left, lost, never, update };

/// What a client opens once tmux's sessions are known: as tmux shows it, the board on a ticket,
/// home, or home as the client before it left it.
const Open = union(enum) { as_is, card: u32, home, kept: App.Kept };

/// One tmux client's life: until the user leaves (`left`) or tmux ends it, after showing a
/// session (`lost`) or before (`never`). With `card`, the board opens on that ticket once
/// tmux's sessions are known.
fn attached(init: std.process.Init, argv: []const []const u8, tty: std.Io.File, open: Open, kept: *?App.Kept, watch: ?*update.Watch, arrived: ?update.Arrival) !Outcome {
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
    try app.send(.ignore, "set-option -saF " ++ clients_option ++ " ' #{{client_name}} '", .{});
    app.motion = init.environ_map.get("ARENA_REDUCED_MOTION") == null;
    if (init.environ_map.get("ARENA_LOOK_MS")) |ms| app.look_after = try std.fmt.parseInt(i64, ms, 10);
    var theme_file: ThemeFile = .{
        .path = if (init.environ_map.get("HOME")) |home| try std.fs.path.join(gpa, &.{ home, ".config/ficciones/theme/palette.sh" }) else null,
    };
    defer theme_file.deinit(&app);
    var board_file: BoardFile = .{
        .path = try boardPath(gpa, init.environ_map),
    };
    defer board_file.deinit(&app);
    app.board_dir = if (board_file.path) |path| std.fs.path.dirname(path) else null;
    const reports_dir = try reportsPath(gpa, init.environ_map);
    defer if (reports_dir) |dir| gpa.free(dir);
    app.reports_dir = reports_dir;
    const folds_path = try foldsPath(gpa, init.environ_map);
    defer if (folds_path) |path| gpa.free(path);
    app.folds_path = folds_path;
    if (folds_path) |path| {
        const text = std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(1 << 16)) catch null;
        if (text) |t| {
            defer gpa.free(t);
            app.loadFolds(t);
        }
    }
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
    var open_wanted = open;
    var typed_at: i64 = 0;
    if (arrived) |was| try app.updated(was.ticket, std.Io.Timestamp.now(io, .awake).toMilliseconds() + update.notice_ms);

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
            try board_file.check(&app);
            board_file.checkDetail(&app);
            try checkRefusals(&app);
            if (watch) |w| if (w.changed(io) and app.quiet() and typed.items.len == 0 and now - typed_at >= update.settle_ms) {
                kept.* = app.kept();
                return .update;
            };
        }
        if (app.report_until != 0 and now >= app.report_until) {
            app.report_until = 0;
            app.clearReportSaid();
        }
        if (app.want_list and !app.listing) try app.requestList();
        if (app.listed and open_wanted != .as_is) {
            switch (open_wanted) {
                .as_is => {},
                .card => |id| try app.showPlan(id),
                .home => try app.goHome(),
                .kept => |was| try app.restore(was),
            }
            open_wanted = .as_is;
        }

        if (app.yoff != 0) {
            app.yoff = layout.step(app.yoff, 0);
            app.dirty = true;
        }
        if (app.auto_armed_until != 0 and now >= app.auto_armed_until) {
            app.auto_armed_until = 0;
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
            const what: draw.What = if (whole or app.overlay() or app.peek or app.look != null) .all else .focused_border;
            if (whole) last_frame = now;
            app.dirty = false;
            frame.clearRetainingCapacity();
            try draw.frame(&app, &frame.writer, what);
            try tty.writeStreamingAll(io, frame.written());
        }
        if (app.listed and app.out.items.len > 0) app.dirty = true;

        const wait_ms: i64 = if (app.dirty)
            @max(1, frame_ms - (now - last_frame))
        else if (moving)
            16
        else if (spins)
            @max(1, spin_frame_ms - (now - last_spin))
        else
            idle_ms;
        const lone = keys.lone(typed.items);
        const pick_ms = try app.pickStep();
        const auto_ms = try app.sendAuto();
        _ = try posix.poll(&fds, @intCast(@min(wait_ms, idle_ms, @max(1, app.dwell()), @max(1, pick_ms), @max(1, auto_ms), if (lone) @as(i64, keys.lone_wait_ms) else idle_ms)));

        if (fds[0].revents & posix.POLL.IN != 0) {
            const n = try posix.read(posix.STDIN_FILENO, &buf);
            if (n == 0) return .left;
            typed_at = now;
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
                // an Escape held to tell it from Alt was typed before what the command line says after it
                if (keys.lone(typed.items) and control.told(line.items)) {
                    try app.typedAlone(typed.items);
                    typed.items.len = 0;
                }
                try app.onLine(line.items);
                line.clearRetainingCapacity();
                rest = rest[nl + 1 ..];
            }
            try line.appendSlice(gpa, rest);
        }
    }

    if (!app.ended) return .left;
    kept.* = app.kept();
    return if (app.listed) .lost else .never;
}

test {
    _ = @import("app.zig");
    _ = @import("draw.zig");
    _ = @import("control.zig");
    _ = @import("theme.zig");
    _ = @import("parts.zig");
    _ = @import("board.zig");
    _ = @import("feed.zig");
    _ = @import("auto.zig");
    _ = @import("plan.zig");
    _ = @import("keys.zig");
    _ = @import("grab.zig");
    _ = @import("menu.zig");
    _ = @import("pass.zig");
    _ = @import("report.zig");
    _ = @import("text.zig");
    _ = @import("update.zig");
    _ = color;
    _ = layout;
}
