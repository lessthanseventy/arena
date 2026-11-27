//! The repos view in the middle column, as lazygit lays out its branches: each repo's main
//! against its origin on the left, the picked repo's commits to push on the right, and the keys
//! in the foot.
const std = @import("std");
const bench = @import("parts.zig");
const draw = @import("draw.zig");
const tickets = @import("board.zig");
const app_mod = @import("app.zig");
const App = app_mod.App;
const Writer = std.Io.Writer;
const anyKey = app_mod.anyKey;

const Repos = [app_mod.max_repos]tickets.RepoState;

/// The repos the view lists, in order of name: those with a card on the board, then any babylon
/// says a push of that has none.
pub fn list(app: *const App, out: *Repos) []tickets.RepoState {
    const b = &(app.board orelse return out[0..0]);
    var names: [app_mod.max_repos][]const u8 = undefined;
    const n = b.repos(&names);
    var count: usize = 0;
    for (names[0..n]) |name| {
        out[count] = b.repoState(name);
        count += 1;
    }
    for (b.repo_states) |s| {
        if (count == out.len) break;
        const known = for (out[0..count]) |had| {
            if (std.mem.eql(u8, had.repo, s.repo)) break true;
        } else false;
        if (known) continue;
        out[count] = s;
        count += 1;
    }
    return out[0..count];
}

pub fn open(app: *App) !void {
    const view = &app.home.?;
    view.repos = true;
    view.repos_pick = 0;
    view.repos_commit = null;
    view.repos_diff = false;
    view.repos_confirm = false;
    view.detail_scroll = 0;
    app.dirty = true;
    try ask(app);
}

/// The commits to push of the picked repo, asked for into the detail beside the board.
fn ask(app: *App) !void {
    const view = &app.home.?;
    app.detail.clearRetainingCapacity();
    var rows: Repos = undefined;
    const repos = list(app, &rows);
    if (view.repos_pick >= repos.len or repos[view.repos_pick].ahead == 0) return;
    try runGit(app, repos[view.repos_pick].repo, "log --oneline origin/main..main");
}

fn runGit(app: *App, repo: []const u8, comptime git: []const u8) !void {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = app.detailPath(0, &buf) orelse return;
    std.Io.Dir.cwd().deleteFile(app.io, path) catch {};
    if (app.detail_asked.items.len == 16) _ = app.detail_asked.orderedRemove(0);
    try app.detail_asked.append(app.gpa, 0);
    try app.send(.ignore, "run-shell -b \"git -C \\\"\\$HOME/projects/{s}\\\" " ++ git ++ " >'{s}.part' 2>&1; mv '{s}.part' '{s}'\"", .{ repo, path, path, path });
}

fn commitCount(app: *const App) usize {
    var n: usize = 0;
    var lines = std.mem.splitScalar(u8, app.detail.items, '\n');
    while (lines.next()) |line| n += @intFromBool(line.len > 0);
    return n;
}

fn commitAt(app: *const App, at: usize) ?[]const u8 {
    var n: usize = 0;
    var lines = std.mem.splitScalar(u8, app.detail.items, '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        if (n == at) return line;
        n += 1;
    }
    return null;
}

fn say(app: *App, bad: bool, comptime fmt: []const u8, args: anytype) void {
    const text = std.fmt.bufPrint(&app.repos_said, fmt, args) catch app.repos_said[0..0];
    app.repos_said_len = text.len;
    app.repos_bad = bad;
}

/// `babylon push` run for `state`'s repo; how it went is said when the answer comes.
fn push(app: *App, state: tickets.RepoState) !void {
    if (state.ahead == 0) return;
    const id = try std.fmt.allocPrint(app.gpa, "repos:{s}:{d}", .{ state.repo, state.ahead });
    errdefer app.gpa.free(id);
    try app.repos_pushing.append(app.gpa, id);
    _ = try app.runWith(id, &.{ "babylon", "push", state.repo }, true);
    say(app, false, "pushing {s}…", .{state.repo});
}

/// The answers of the pushes run, which babylon's own or git's words said into files beside the
/// board: `ok`, or why not.
pub fn polled(app: *App) void {
    var i = app.repos_pushing.items.len;
    while (i > 0) {
        i -= 1;
        const id = app.repos_pushing.items[i];
        var buf: [std.fs.max_path_bytes]u8 = undefined;
        const path = app.refusalPath(id, &buf) orelse continue;
        const text = std.Io.Dir.cwd().readFileAlloc(app.io, path, app.gpa, .limited(1 << 12)) catch continue;
        defer app.gpa.free(text);
        std.Io.Dir.cwd().deleteFile(app.io, path) catch {};
        var parts = std.mem.splitScalar(u8, id["repos:".len..], ':');
        const repo = parts.next() orelse "";
        const n = parts.next() orelse "";
        const line = std.mem.trim(u8, text[0 .. std.mem.indexOfScalar(u8, text, '\n') orelse text.len], " ");
        if (std.mem.eql(u8, line, "ok")) {
            say(app, false, "pushed {s}: {s} commits", .{ repo, n });
        } else {
            say(app, true, "{s}: {s}", .{ repo, if (line.len > 0) line else "push failed" });
        }
        app.gpa.free(id);
        _ = app.repos_pushing.orderedRemove(i);
        app.dirty = true;
    }
}

pub fn key(app: *App, pressed: []const u8) !void {
    const view = &app.home.?;
    app.dirty = true;
    var rows: Repos = undefined;
    const repos = list(app, &rows);
    view.repos_pick = @min(view.repos_pick, repos.len -| 1);
    var ahead: usize = 0;
    for (repos) |s| ahead += @intFromBool(s.ahead > 0);

    if (view.repos_confirm) {
        view.repos_confirm = false;
        if (anyKey(pressed, &.{"y"})) for (repos) |s| try push(app, s);
        return;
    }
    if (anyKey(pressed, &.{ "\x1b", "q" })) {
        if (view.repos_diff) {
            view.repos_diff = false;
            view.detail_scroll = 0;
            return ask(app);
        }
        if (view.repos_commit != null) {
            view.repos_commit = null;
            return;
        }
        view.repos = false;
        app.detail.clearRetainingCapacity();
        return;
    }
    if (anyKey(pressed, &.{ "j", "\x1b[B", "\x1bOB" })) {
        if (view.repos_diff) {
            view.detail_scroll += 1;
        } else if (view.repos_commit) |at| {
            view.repos_commit = @min(at + 1, commitCount(app) -| 1);
        } else if (view.repos_pick + 1 < repos.len) {
            view.repos_pick += 1;
            try ask(app);
        }
        return;
    }
    if (anyKey(pressed, &.{ "k", "\x1b[A", "\x1bOA" })) {
        if (view.repos_diff) {
            view.detail_scroll -|= 1;
        } else if (view.repos_commit) |at| {
            view.repos_commit = at -| 1;
        } else if (view.repos_pick > 0) {
            view.repos_pick -= 1;
            try ask(app);
        }
        return;
    }
    if (anyKey(pressed, &.{"\r"})) {
        if (view.repos_diff or repos.len == 0) return;
        const at = view.repos_commit orelse {
            if (commitCount(app) > 0) view.repos_commit = 0;
            return;
        };
        const line = commitAt(app, at) orelse return;
        const sha = line[0 .. std.mem.indexOfScalar(u8, line, ' ') orelse line.len];
        for (sha) |c| if (!std.ascii.isHex(c)) return;
        view.repos_diff = true;
        view.detail_scroll = 0;
        app.detail.clearRetainingCapacity();
        return diff(app, repos[view.repos_pick].repo, sha);
    }
    if (anyKey(pressed, &.{"P"})) {
        if (view.repos_pick < repos.len) try push(app, repos[view.repos_pick]);
        return;
    }
    if (anyKey(pressed, &.{"A"})) {
        view.repos_confirm = ahead > 0;
        return;
    }
    if (anyKey(pressed, &.{"f"})) {
        for (repos) |s| try runGit(app, s.repo, "fetch -q origin main");
        say(app, false, "fetching {d} repos", .{repos.len});
        return ask(app);
    }
}

fn diff(app: *App, repo: []const u8, sha: []const u8) !void {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = app.detailPath(0, &buf) orelse return;
    std.Io.Dir.cwd().deleteFile(app.io, path) catch {};
    if (app.detail_asked.items.len == 16) _ = app.detail_asked.orderedRemove(0);
    try app.detail_asked.append(app.gpa, 0);
    try app.send(.ignore, "run-shell -b \"git -C \\\"\\$HOME/projects/{s}\\\" show --stat --patch {s} >'{s}.part' 2>&1; mv '{s}.part' '{s}'\"", .{ repo, sha, path, path, path });
}

var cut_scratch: [512]u8 = undefined;

fn cut(text: []const u8, room: usize) []const u8 {
    return draw.clipMark(&cut_scratch, text, room);
}

pub fn paint(app: *App, w: *Writer) !void {
    const r = app.roles orelse bench.roles();
    const rect = app.columnRect() orelse return;
    const view = app.home.?;
    var rows: Repos = undefined;
    const repos = list(app, &rows);
    const inner = app_mod.detailWidth(app.columnRoom()).inner;
    const x0 = rect.x + 2;
    const foot = rect.y + rect.h - 1;
    app.grab.window(.{ .x = x0, .y = rect.y + 1, .w = inner, .h = rect.h -| 2 });
    try bench.window(w, r, rect.x, rect.y, rect.w - 1, rect.h + 1, "repos", null, true);

    const left: u16 = @intCast(@min(@as(usize, 26), inner / 2));
    const right_x = x0 + left + 2;
    const right_w: usize = inner -| (left + 2);
    const body_end = foot - 1;
    var y = rect.y + 1;
    while (y < body_end) : (y += 1) try bench.say(w, x0 + left, y, "│", r.dim, r.panel, false);

    var line: [128]u8 = undefined;
    y = rect.y + 1;
    for (repos, 0..) |s, i| {
        if (y >= body_end) break;
        const text = std.fmt.bufPrint(&line, "{s}  main  ↑{d} ↓{d}", .{ s.repo, s.ahead, s.behind }) catch s.repo;
        const picked = i == view.repos_pick;
        const level = s.ahead == 0 and s.behind == 0;
        if (picked) try bench.say(w, rect.x + 1, y, "▌", r.accent, r.panel, true);
        try bench.say(w, x0, y, cut(text, left), if (level and !picked) r.dim else r.text, r.panel, picked);
        y += 1;
    }

    y = rect.y + 1;
    const picked_repo: ?tickets.RepoState = if (view.repos_pick < repos.len) repos[view.repos_pick] else null;
    if (picked_repo) |s| if (s.ahead == 0 and !view.repos_diff) {
        try bench.say(w, right_x, y, "nothing to push", r.dim, r.panel, false);
    } else if (app.detail.items.len == 0) {
        try bench.say(w, right_x, y, "…", r.dim, r.panel, false);
    } else {
        var n: usize = 0;
        var lines = std.mem.splitScalar(u8, app.detail.items, '\n');
        while (lines.next()) |text| {
            if (text.len == 0 and !view.repos_diff) continue;
            defer n += 1;
            if (n < view.detail_scroll and view.repos_diff) continue;
            if (y >= body_end) break;
            const marked = !view.repos_diff and view.repos_commit == n;
            if (marked) try bench.say(w, right_x - 1, y, "▌", r.accent, r.panel, true);
            const shown = if (view.repos_diff) text else (if (std.mem.indexOfScalar(u8, text, ' ')) |sp| std.fmt.bufPrint(&line, "{s}  {s}", .{ text[0..sp], text[sp + 1 ..] }) catch text else text);
            try bench.say(w, right_x, y, cut(shown, right_w), r.text, r.panel, marked);
            y += 1;
        }
    };

    if (app.repos_said_len > 0) {
        try bench.say(w, x0, body_end, cut(app.repos_said[0..app.repos_said_len], inner), if (app.repos_bad) r.failed else r.dim, r.panel, false);
    }
    var hint: [96]u8 = undefined;
    var n_ahead: usize = 0;
    for (repos) |s| n_ahead += @intFromBool(s.ahead > 0);
    const keys = if (view.repos_confirm)
        std.fmt.bufPrint(&hint, " push {d} repos? y/n ", .{n_ahead}) catch ""
    else if (view.repos_diff)
        " j k scroll   esc back "
    else
        " j k pick   ⏎ commits   P push   A push all   f fetch   esc close ";
    try bench.say(w, x0, foot, cut(keys, inner), r.dim, r.panel, false);
}
