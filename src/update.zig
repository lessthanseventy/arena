//! arena replacing itself: it notices its own executable changed, and runs it again in place,
//! carrying the view across in a small text file named for its pid, which an exec keeps.
const std = @import("std");
const app_mod = @import("app.zig");
const BoardView = app_mod.BoardView;
const Writer = std.Io.Writer;
const posix = std.posix;

/// How long the build's own executable must stay as it is before arena runs it: an install
/// writes it for a while, and a half-written file is not one to run.
pub const settle_ms = 1000;
/// How long "arena updated" stays in the foot strip.
pub const notice_ms = 4000;

pub const Stamp = struct {
    inode: std.Io.File.INode,
    size: u64,
    mtime: i96,

    fn of(io: std.Io, path: []const u8) ?Stamp {
        const stat = std.Io.Dir.cwd().statFile(io, path, .{}) catch return null;
        return .{ .inode = stat.inode, .size = stat.size, .mtime = stat.mtime.nanoseconds };
    }

    fn eql(a: Stamp, b: Stamp) bool {
        return a.inode == b.inode and a.size == b.size and a.mtime == b.mtime;
    }
};

/// Whether the executable at `path` is no longer the one that started.
pub const Watch = struct {
    path: []const u8,
    started: ?Stamp,
    pending: ?Stamp = null,

    pub fn init(io: std.Io, path: []const u8) Watch {
        return .{ .path = path, .started = Stamp.of(io, path) };
    }

    /// True once the file has changed and been the same on two checks running.
    pub fn changed(watch: *Watch, io: std.Io) bool {
        return watch.step(Stamp.of(io, watch.path));
    }

    fn step(watch: *Watch, now: ?Stamp) bool {
        const started = watch.started orelse return false;
        const there = now orelse {
            watch.pending = null;
            return false;
        };
        if (there.eql(started)) {
            watch.pending = null;
            return false;
        }
        if (watch.pending) |before| if (before.eql(there)) return true;
        watch.pending = there;
        return false;
    }
};

/// What a restarted arena finds waiting: the home it left, and the ticket the install named.
pub const Arrival = struct { kept: ?app_mod.App.Kept = null, ticket: ?u32 = null };

/// Where the files are: beside what babylon keeps, under arena's name.
fn dirPath(gpa: std.mem.Allocator, env: *const std.process.Environ.Map) !?[]u8 {
    if (env.get("XDG_RUNTIME_DIR")) |dir| return try std.fs.path.join(gpa, &.{ dir, "arena" });
    if (env.get("XDG_STATE_HOME")) |dir| return try std.fs.path.join(gpa, &.{ dir, "arena" });
    if (env.get("HOME")) |home| return try std.fs.path.join(gpa, &.{ home, ".local/state/arena" });
    return null;
}

fn statePath(gpa: std.mem.Allocator, dir: []const u8) ![]u8 {
    const pid: usize = @intCast(posix.system.getpid());
    const name = try std.fmt.allocPrint(gpa, "restart-{d}", .{pid});
    defer gpa.free(name);
    return std.fs.path.join(gpa, &.{ dir, name });
}

/// The ticket number the install left in `installed`, when it did.
fn installed(gpa: std.mem.Allocator, io: std.Io, dir: []const u8) ?u32 {
    const path = std.fs.path.join(gpa, &.{ dir, "installed" }) catch return null;
    defer gpa.free(path);
    const text = std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(64)) catch return null;
    defer gpa.free(text);
    return std.fmt.parseInt(u32, std.mem.trim(u8, text, " #\n"), 10) catch null;
}

/// Removes `installed`, so a later restart does not name the same ticket again.
fn clearInstalled(gpa: std.mem.Allocator, io: std.Io, dir: []const u8) void {
    const path = std.fs.path.join(gpa, &.{ dir, "installed" }) catch return;
    defer gpa.free(path);
    std.Io.Dir.cwd().deleteFile(io, path) catch {};
}

/// Writes the view for the arena that replaces this one, which has this pid too.
pub fn save(init: std.process.Init, kept: ?app_mod.App.Kept) !void {
    const gpa = init.gpa;
    const dir = try dirPath(gpa, init.environ_map) orelse return;
    defer gpa.free(dir);
    var text: Writer.Allocating = .init(gpa);
    defer text.deinit();
    try encode(&text.writer, .{ .kept = kept, .ticket = installed(gpa, init.io, dir) });
    try std.Io.Dir.cwd().createDirPath(init.io, dir);
    const path = try statePath(gpa, dir);
    defer gpa.free(path);
    try std.Io.Dir.cwd().writeFile(init.io, .{ .sub_path = path, .data = text.written() });
}

/// What `save` left for this pid, taken: a file is read once, so a restart never repeats.
pub fn arrive(init: std.process.Init) Arrival {
    const gpa = init.gpa;
    const dir = (dirPath(gpa, init.environ_map) catch return .{}) orelse return .{};
    defer gpa.free(dir);
    const path = statePath(gpa, dir) catch return .{};
    defer gpa.free(path);
    const text = std.Io.Dir.cwd().readFileAlloc(init.io, path, gpa, .limited(1 << 12)) catch return .{};
    defer gpa.free(text);
    std.Io.Dir.cwd().deleteFile(init.io, path) catch {};
    const arrival = decode(text);
    if (arrival.ticket != null) clearInstalled(gpa, init.io, dir);
    return arrival;
}

/// Removes what `save` left, when the new build did not start.
pub fn discard(init: std.process.Init) void {
    const gpa = init.gpa;
    const dir = (dirPath(gpa, init.environ_map) catch return) orelse return;
    defer gpa.free(dir);
    const path = statePath(gpa, dir) catch return;
    defer gpa.free(path);
    std.Io.Dir.cwd().deleteFile(init.io, path) catch {};
}

fn put(w: *Writer, comptime name: []const u8, value: anytype) !void {
    switch (@typeInfo(@TypeOf(value))) {
        .optional => if (value) |v| try put(w, name, v) else try w.print(name ++ "=-\n", .{}),
        .bool => try w.print(name ++ "={d}\n", .{@intFromBool(value)}),
        .int => try w.print(name ++ "={d}\n", .{value}),
        .@"enum" => try w.print(name ++ "={s}\n", .{@tagName(value)}),
        else => @compileError("a view field of a kind the restart file cannot carry: " ++ name),
    }
}

fn take(comptime T: type, text: []const u8) error{Bad}!T {
    switch (@typeInfo(T)) {
        .optional => |o| return if (std.mem.eql(u8, text, "-")) null else try take(o.child, text),
        .bool => return if (std.mem.eql(u8, text, "1")) true else if (std.mem.eql(u8, text, "0")) false else error.Bad,
        .int => return std.fmt.parseInt(T, text, 10) catch error.Bad,
        .@"enum" => return std.meta.stringToEnum(T, text) orelse error.Bad,
        else => @compileError("a view field of a kind the restart file cannot carry"),
    }
}

fn encode(w: *Writer, arrival: Arrival) !void {
    if (arrival.ticket) |id| try put(w, "ticket", id);
    const kept = arrival.kept orelse return;
    try put(w, "folded", kept.folded);
    inline for (@typeInfo(BoardView).@"struct".field_names) |name| try put(w, "view." ++ name, @field(kept.view, name));
}

/// A line the new build does not know, or cannot read, is left out: a view across two builds
/// that differ is what it can be, never a failure to start.
fn decode(text: []const u8) Arrival {
    var arrival: Arrival = .{};
    var view: BoardView = .{};
    var folded = false;
    var seen = false;
    var lines = std.mem.tokenizeScalar(u8, text, '\n');
    while (lines.next()) |line| {
        const eq = std.mem.indexOfScalar(u8, line, '=') orelse continue;
        const key = line[0..eq];
        const value = line[eq + 1 ..];
        if (std.mem.eql(u8, key, "ticket")) arrival.ticket = take(u32, value) catch null;
        if (std.mem.eql(u8, key, "folded")) {
            seen = true;
            folded = take(bool, value) catch false;
        }
        inline for (@typeInfo(BoardView).@"struct".field_names, @typeInfo(BoardView).@"struct".field_types) |name, T| {
            if (std.mem.eql(u8, key, "view." ++ name)) {
                if (take(T, value)) |v| @field(view, name) = v else |_| {}
            }
        }
    }
    if (seen) arrival.kept = .{ .view = view, .folded = folded };
    return arrival;
}

test "a view and a ticket come back as they went" {
    var text: Writer.Allocating = .init(std.testing.allocator);
    defer text.deinit();
    const view: BoardView = .{ .focus = .orchestrator, .back = 7, .col = 2, .row = 3, .repo = 1, .plan = true, .pick = 4, .unfolded = 5, .alone = false };
    try encode(&text.writer, .{ .kept = .{ .view = view, .folded = true }, .ticket = 822 });
    const back = decode(text.written());
    try std.testing.expectEqual(@as(?u32, 822), back.ticket);
    try std.testing.expect(back.kept.?.folded);
    try std.testing.expectEqualDeep(view, back.kept.?.view);
}

test "the installed ticket file is removed once taken, so the next restart finds none" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = buf[0..try tmp.dir.realPath(std.testing.io, &buf)];
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "installed", .data = "#872\n" });
    try std.testing.expectEqual(@as(?u32, 872), installed(std.testing.allocator, std.testing.io, dir));
    clearInstalled(std.testing.allocator, std.testing.io, dir);
    try std.testing.expectEqual(@as(?u32, null), installed(std.testing.allocator, std.testing.io, dir));
}

test "no view is no kept home, and a stranger's lines are skipped" {
    try std.testing.expectEqual(@as(?app_mod.App.Kept, null), decode("ticket=9\n").kept);
    const back = decode("folded=0\nview.col=x\nview.row=3\nview.nothing=1\nnonsense\n");
    try std.testing.expectEqual(@as(usize, 0), back.kept.?.view.col);
    try std.testing.expectEqual(@as(usize, 3), back.kept.?.view.row);
}

test "the build is run again only once it has stopped changing" {
    var watch: Watch = .{ .path = "", .started = .{ .inode = 1, .size = 10, .mtime = 100 } };
    try std.testing.expect(!watch.step(.{ .inode = 1, .size = 10, .mtime = 100 }));
    try std.testing.expect(!watch.step(.{ .inode = 1, .size = 4, .mtime = 200 }));
    try std.testing.expect(!watch.step(.{ .inode = 1, .size = 8, .mtime = 300 }));
    try std.testing.expect(!watch.step(null));
    try std.testing.expect(!watch.step(.{ .inode = 2, .size = 12, .mtime = 400 }));
    try std.testing.expect(watch.step(.{ .inode = 2, .size = 12, .mtime = 400 }));
}
