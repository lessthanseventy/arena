//! The repos view in the middle column, as lazygit lays out its panels: one row per repo on the
//! left, and the picked repo's changed files, worktrees and today's commits on the right.
//! Everything shown comes from one answer per repo, which a single shell job writes into a file
//! of its own (`repos-<repo>.status`) and `parse` reads on every draw; the diffs are asked for
//! one at a time.
const std = @import("std");
const bench = @import("parts.zig");
const draw = @import("draw.zig");
const tickets = @import("board.zig");
const app_mod = @import("app.zig");
const App = app_mod.App;
const Writer = std.Io.Writer;
const anyKey = app_mod.anyKey;

const Repos = [app_mod.max_repos]tickets.RepoState;

/// How often every repo is read again while the board is up, in milliseconds.
const refresh_ms = 30_000;

/// The sections of the picked repo, in `tab` order.
const sections = [_][]const u8{ "Status", "Worktrees", "Commits" };

/// What git said of a checkout, from `git status --porcelain=v2 --branch`.
const Checkout = struct { branch: []const u8 = "", ahead: u32 = 0, behind: u32 = 0, changed: u32 = 0 };

/// A repo as its answer reads: its main checkout's branch and state, the worktrees besides it and
/// its stashes.
pub const Summary = struct { checkout: Checkout = .{}, worktrees: u32 = 0, stashes: u32 = 0 };

/// The lines of `text` after the `n`th line `--name`, up to the next line that starts `--`.
fn part(text: []const u8, name: []const u8, n: usize) ?[]const u8 {
    var seen: usize = 0;
    var from: ?usize = null;
    var at: usize = 0;
    while (at < text.len) {
        const end = std.mem.indexOfScalarPos(u8, text, at, '\n') orelse text.len;
        const line = text[at..end];
        const next = @min(end + 1, text.len);
        if (std.mem.startsWith(u8, line, "--")) {
            if (from) |f| return text[f..at];
            if (std.mem.eql(u8, line[2..], name)) {
                if (seen == n) from = next;
                seen += 1;
            }
        }
        at = next;
    }
    return if (from) |f| text[f..] else null;
}

/// A worktree's block: its path, then its status.
fn checkoutOf(block: []const u8) Checkout {
    var c: Checkout = .{};
    var lines = std.mem.splitScalar(u8, block, '\n');
    _ = lines.next();
    while (lines.next()) |line| {
        if (std.mem.startsWith(u8, line, "# branch.head ")) {
            c.branch = line["# branch.head ".len..];
        } else if (std.mem.startsWith(u8, line, "# branch.ab ")) {
            var it = std.mem.tokenizeScalar(u8, line["# branch.ab ".len..], ' ');
            c.ahead = std.fmt.parseInt(u32, std.mem.trimStart(u8, it.next() orelse "", "+"), 10) catch 0;
            c.behind = std.fmt.parseInt(u32, std.mem.trimStart(u8, it.next() orelse "", "-"), 10) catch 0;
        } else if (line.len > 2 and line[1] == ' ' and std.mem.indexOfScalar(u8, "12u?", line[0]) != null) {
            c.changed += 1;
        }
    }
    return c;
}

/// What `text`, a repo's answer, says; null while it has none.
pub fn parse(text: []const u8) ?Summary {
    const main = part(text, "wt", 0) orelse return null;
    var s: Summary = .{ .checkout = checkoutOf(main) };
    while (part(text, "wt", s.worktrees + 1) != null) s.worktrees += 1;
    const stash = std.mem.trim(u8, part(text, "stash", 0) orelse "", " \n");
    s.stashes = std.fmt.parseInt(u32, stash, 10) catch 0;
    return s;
}

/// Whether the main checkout is dirty or is not on `main`: a stray edit in the shared checkout.
fn stray(s: Summary) bool {
    return s.checkout.changed > 0 or !std.mem.eql(u8, s.checkout.branch, "main");
}

fn gitText(app: *const App, repo: []const u8) []const u8 {
    for (app.repo_git[0..app.repo_git_n]) |g| if (std.mem.eql(u8, g.name[0..g.len], repo)) return g.text;
    return "";
}

/// Whether any repo's main checkout is dirty or off main, as the head's chip says.
pub fn anyStray(app: *const App) bool {
    for (app.repo_git[0..app.repo_git_n]) |g| if (parse(g.text)) |s| {
        if (stray(s)) return true;
    };
    return false;
}

/// The repos the view lists, in order of name: those with a card on the board, then any babylon
/// says a push of that has none. Each is as git counted it, else as babylon says.
pub fn list(app: *const App, out: *Repos) []tickets.RepoState {
    const b = &(app.board orelse return out[0..0]);
    var names: [app_mod.max_repos][]const u8 = undefined;
    const n = b.repos(&names);
    var n_rows: usize = 0;
    for (names[0..n]) |name| {
        out[n_rows] = b.repoState(name);
        n_rows += 1;
    }
    for (b.repo_states) |s| {
        if (n_rows == out.len) break;
        const known = for (out[0..n_rows]) |had| {
            if (std.mem.eql(u8, had.repo, s.repo)) break true;
        } else false;
        if (known) continue;
        out[n_rows] = s;
        n_rows += 1;
    }
    for (out[0..n_rows]) |*s| if (parse(gitText(app, s.repo))) |sum| {
        s.ahead = sum.checkout.ahead;
        s.behind = sum.checkout.behind;
    };
    return out[0..n_rows];
}

fn statusPath(app: *const App, repo: []const u8, buf: []u8) ?[]const u8 {
    const dir = app.board_dir orelse return null;
    return std.fmt.bufPrint(buf, "{s}/repos-{s}.status", .{ dir, repo }) catch null;
}

/// Asks git for everything the view shows of `repo`, after a fetch with `fetched`, into the
/// repo's own file: no other job writes it. The first worktree listed is the main checkout.
fn askStatus(app: *App, repo: []const u8, comptime fetched: bool) !void {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = statusPath(app, repo, &buf) orelse return;
    const fetch = if (fetched) "git fetch -q origin main 2>/dev/null; " else "";
    try app.send(.ignore, "run-shell -b \"cd \\\"\\$HOME/projects/{s}\\\" && {s}(git worktree list --porcelain | sed -n 's/^worktree //p' | while read d; do echo --wt; echo \\$d; git -C \\$d status --porcelain=v2 --branch; done; echo --stash; git stash list | wc -l; echo --today; date -d 00:00 +%s; echo --unpushed; git log --format=%h origin/main..main; echo --log; git log -n 200 --format='%h %ct %s ‖ %(trailers:valueonly,separator=%x20)' main) >'{s}.part' 2>&1; mv '{s}.part' '{s}'\"", .{ repo, fetch, path, path, path });
}

fn askAll(app: *App, comptime fetched: bool) !void {
    var rows: Repos = undefined;
    for (list(app, &rows)) |s| try askStatus(app, s.repo, fetched);
}

fn takeStatus(app: *App) void {
    var rows: Repos = undefined;
    for (list(app, &rows)) |s| {
        var buf: [std.fs.max_path_bytes]u8 = undefined;
        const path = statusPath(app, s.repo, &buf) orelse continue;
        const text = std.Io.Dir.cwd().readFileAlloc(app.io, path, app.gpa, .limited(1 << 20)) catch continue;
        std.Io.Dir.cwd().deleteFile(app.io, path) catch {};
        if (s.repo.len > 48) {
            app.gpa.free(text);
            continue;
        }
        const slot = for (app.repo_git[0..app.repo_git_n], 0..) |g, i| {
            if (std.mem.eql(u8, g.name[0..g.len], s.repo)) break i;
        } else blk: {
            if (app.repo_git_n == app.repo_git.len) {
                app.gpa.free(text);
                continue;
            }
            app.repo_git_n += 1;
            const g = &app.repo_git[app.repo_git_n - 1];
            @memcpy(g.name[0..s.repo.len], s.repo);
            g.len = @intCast(s.repo.len);
            g.text = &.{};
            break :blk app.repo_git_n - 1;
        };
        const g = &app.repo_git[slot];
        app.gpa.free(g.text);
        g.text = text;
        app.dirty = true;
    }
}

pub fn open(app: *App) !void {
    const view = &app.home.?;
    view.repos = true;
    view.repos_pick = 0;
    view.repos_in = false;
    view.repos_section = 0;
    pickRows(view, 0, 0, 0);
    view.repos_diff = false;
    view.repos_confirm = false;
    view.detail_scroll = 0;
    app.detail.clearRetainingCapacity();
    nextRequest(app);
    app.dirty = true;
    try askAll(app, false);
}

const File = struct { staged: bool, code: [2]u8, path: []const u8 };

fn skipFields(line: []const u8, n: usize) []const u8 {
    var rest = line;
    for (0..n) |_| rest = rest[(std.mem.indexOfScalar(u8, rest, ' ') orelse return "") + 1 ..];
    return rest;
}

fn fileIn(line: []const u8) ?File {
    if (line.len < 4) return null;
    switch (line[0]) {
        '?' => return .{ .staged = false, .code = "??".*, .path = line[2..] },
        '1', '2', 'u' => {
            const rest = skipFields(line, switch (line[0]) {
                '1' => 8,
                '2' => 9,
                else => 10,
            });
            const staged = line[2] != '.';
            return .{ .staged = staged, .code = .{ if (staged) line[2] else line[3], ' ' }, .path = rest[0 .. std.mem.indexOfScalar(u8, rest, '\t') orelse rest.len] };
        },
        else => return null,
    }
}

/// The `n`th changed file of the main checkout, the staged ones first.
fn fileAt(text: []const u8, n: usize) ?File {
    const block = part(text, "wt", 0) orelse return null;
    var seen: usize = 0;
    for ([_]bool{ true, false }) |want| {
        var lines = std.mem.splitScalar(u8, block, '\n');
        _ = lines.next();
        while (lines.next()) |line| {
            const f = fileIn(line) orelse continue;
            if (f.staged != want) continue;
            if (seen == n) return f;
            seen += 1;
        }
    }
    return null;
}

const Tree = struct { co: Checkout, ticket: ?u32 };

/// The ticket a babylon branch `t<N>-…` is of.
fn ticketOf(branch: []const u8) ?u32 {
    if (branch.len < 3 or branch[0] != 't') return null;
    var end: usize = 1;
    while (end < branch.len and std.ascii.isDigit(branch[end])) end += 1;
    if (end == 1 or end == branch.len or branch[end] != '-') return null;
    return std.fmt.parseInt(u32, branch[1..end], 10) catch null;
}

/// The `n`th worktree besides the main checkout.
fn treeAt(text: []const u8, n: usize) ?Tree {
    const co = checkoutOf(part(text, "wt", n + 1) orelse return null);
    return .{ .co = co, .ticket = ticketOf(co.branch) };
}

const Commit = struct { sha: []const u8, rest: []const u8, ct: i64 };

fn commitIn(line: []const u8) ?Commit {
    const a = std.mem.indexOfScalar(u8, line, ' ') orelse return null;
    const b = std.mem.indexOfScalarPos(u8, line, a + 1, ' ') orelse return null;
    for (line[0..a]) |c| if (!std.ascii.isHex(c)) return null;
    return .{ .sha = line[0..a], .ct = std.fmt.parseInt(i64, line[a + 1 .. b], 10) catch return null, .rest = line[b + 1 ..] };
}

const Log = struct { today: usize, shown: usize };

/// How many commits show: all of today's, and at least the last ten.
fn logOf(text: []const u8) Log {
    const since = std.fmt.parseInt(i64, std.mem.trim(u8, part(text, "today", 0) orelse "", " \n"), 10) catch std.math.maxInt(i64);
    var today: usize = 0;
    var total: usize = 0;
    var lines = std.mem.splitScalar(u8, part(text, "log", 0) orelse "", '\n');
    while (lines.next()) |line| {
        const c = commitIn(line) orelse continue;
        total += 1;
        if (c.ct >= since) today += 1;
    }
    return .{ .today = today, .shown = @max(today, @min(total, 10)) };
}

fn commitAt(text: []const u8, n: usize) ?Commit {
    var seen: usize = 0;
    var lines = std.mem.splitScalar(u8, part(text, "log", 0) orelse "", '\n');
    while (lines.next()) |line| {
        const c = commitIn(line) orelse continue;
        if (seen == n) return c;
        seen += 1;
    }
    return null;
}

fn isUnpushed(text: []const u8, sha: []const u8) bool {
    var lines = std.mem.splitScalar(u8, part(text, "unpushed", 0) orelse "", '\n');
    while (lines.next()) |line| if (line.len > 0 and std.mem.eql(u8, line, sha)) return true;
    return false;
}

/// How many rows section `s` of the picked repo has.
fn rowCount(text: []const u8, s: usize) usize {
    const sum = parse(text) orelse return 0;
    return switch (s) {
        0 => sum.checkout.changed,
        1 => sum.worktrees,
        else => logOf(text).shown,
    };
}

/// Makes the answers of every request so far stale; the ids start above any ticket's.
fn nextRequest(app: *App) void {
    app.repos_req = 0x8000_0000 | ((app.repos_req +% 1) & 0x7fff_ffff);
}

/// Runs `git` in `repo`, its answer into a file of its own.
pub fn runGit(app: *App, repo: []const u8, git: []const u8) !void {
    nextRequest(app);
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = app.detailPath(app.repos_req, &buf) orelse return;
    std.Io.Dir.cwd().deleteFile(app.io, path) catch {};
    const hash = std.hash.Wyhash.hash(0, repo);
    for (app.repos_asked.items, 0..) |*old, i| {
        if (old.dropped or old.repo != hash) continue;
        var old_buf: [std.fs.max_path_bytes]u8 = undefined;
        const gone = if (app.detailPath(old.id, &old_buf)) |old_path|
            if (std.Io.Dir.cwd().deleteFile(app.io, old_path)) |_| true else |_| false
        else
            true;
        if (gone) _ = app.repos_asked.orderedRemove(i) else old.dropped = true;
        break;
    }
    try app.repos_asked.append(app.gpa, .{ .id = app.repos_req, .repo = hash });
    try app.send(.ignore, "run-shell -b \"git -C \\\"\\$HOME/projects/{s}\\\" {s} >'{s}.part' 2>&1; mv '{s}.part' '{s}'\"", .{ repo, git, path, path, path });
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
    _ = try app.runWith(id, &.{ "babylon", "push", state.repo }, true);
    try app.repos_pushing.append(app.gpa, id);
    say(app, false, "pushing {s}…", .{state.repo});
}

/// The answers of the pushes run, which babylon's own or git's words said into files beside the
/// board: `ok`, or why not. Also takes in the repos' status answers, and asks for them again
/// every `refresh_ms` while the board is up, so the head can say a checkout is dirty.
pub fn polled(app: *App) void {
    if (app.board != null and app.now >= app.repos_next) {
        app.repos_next = app.now + refresh_ms;
        askAll(app, false) catch {};
    }
    takeStatus(app);
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
            askStatus(app, repo, false) catch {};
        } else {
            say(app, true, "{s}: {s}", .{ repo, if (line.len > 0) line else "push failed" });
        }
        app.gpa.free(id);
        _ = app.repos_pushing.orderedRemove(i);
        app.dirty = true;
    }
}

fn safePath(path: []const u8) bool {
    if (path.len == 0 or path.len > 200) return false;
    for (path) |c| if (!std.ascii.isAlphanumeric(c) and std.mem.indexOfScalar(u8, "._-/", c) == null) return false;
    return true;
}

fn leaveDiff(app: *App) void {
    const view = &app.home.?;
    view.repos_diff = false;
    view.detail_scroll = 0;
    app.detail.clearRetainingCapacity();
    nextRequest(app);
}

/// ⏎ on the picked row of the picked section: a file's or a commit's diff, a worktree's ticket card.
fn enter(app: *App, repo: []const u8) !void {
    const view = &app.home.?;
    const text = gitText(app, repo);
    const row = rowOf(view, view.repos_section).*;
    switch (view.repos_section) {
        0 => {
            const f = fileAt(text, row) orelse return;
            if (!safePath(f.path)) return;
            var cmd: [256]u8 = undefined;
            const git = if (std.mem.eql(u8, &f.code, "??"))
                std.fmt.bufPrint(&cmd, "diff --no-index -- /dev/null '{s}'", .{f.path})
            else
                std.fmt.bufPrint(&cmd, "diff HEAD -- '{s}'", .{f.path});
            try showDiff(app, repo, git catch return);
        },
        1 => {
            const id = (treeAt(text, row) orelse return).ticket orelse return;
            view.repos = false;
            app.detail.clearRetainingCapacity();
            nextRequest(app);
            _ = try app.openDetail(id);
        },
        else => {
            const c = commitAt(text, row) orelse return;
            if (c.sha.len > 40) return;
            var cmd: [64]u8 = undefined;
            try showDiff(app, repo, std.fmt.bufPrint(&cmd, "show --stat --patch {s}", .{c.sha}) catch return);
        },
    }
}

fn showDiff(app: *App, repo: []const u8, git: []const u8) !void {
    const view = &app.home.?;
    view.repos_diff = true;
    view.detail_scroll = 0;
    app.detail.clearRetainingCapacity();
    try runGit(app, repo, git);
}

pub fn key(app: *App, pressed: []const u8) !void {
    const view = &app.home.?;
    app.dirty = true;
    var rows: Repos = undefined;
    const repos = list(app, &rows);
    view.repos_pick = @min(view.repos_pick, repos.len -| 1);
    var ahead: usize = 0;
    for (repos) |s| ahead += @intFromBool(s.ahead > 0);
    const text = if (view.repos_pick < repos.len) gitText(app, repos[view.repos_pick].repo) else "";

    if (view.repos_confirm) {
        view.repos_confirm = false;
        if (anyKey(pressed, &.{"y"})) for (repos) |s| try push(app, s);
        return;
    }
    if (anyKey(pressed, &.{ "\x1b", "q" })) {
        if (view.repos_diff) return leaveDiff(app);
        if (view.repos_in) {
            view.repos_in = false;
            return;
        }
        view.repos = false;
        app.detail.clearRetainingCapacity();
        nextRequest(app);
        return;
    }
    const down = anyKey(pressed, &.{ "j", "\x1b[B", "\x1bOB" });
    const up = anyKey(pressed, &.{ "k", "\x1b[A", "\x1bOA" });
    if (down or up) {
        const s = view.repos_section;
        if (view.repos_diff) {
            if (down) view.detail_scroll += 1 else view.detail_scroll -|= 1;
        } else if (view.repos_in) {
            const row = rowOf(view, s);
            if (down) row.* = @min(row.* + 1, rowCount(text, s) -| 1) else row.* -|= 1;
        } else {
            const was = view.repos_pick;
            if (down) view.repos_pick = @min(was + 1, repos.len -| 1) else view.repos_pick -|= 1;
            if (view.repos_pick != was) pickRows(view, 0, 0, 0);
        }
        return;
    }
    if (anyKey(pressed, &.{"\t"})) {
        if (view.repos_diff) return;
        if (view.repos_in) view.repos_section = (view.repos_section + 1) % 3 else view.repos_in = true;
        return;
    }
    if (anyKey(pressed, &.{"l"})) {
        if (!view.repos_diff) view.repos_in = true;
        return;
    }
    if (anyKey(pressed, &.{"h"})) {
        if (!view.repos_diff) view.repos_in = false;
        return;
    }
    if (anyKey(pressed, &.{"\r"})) {
        if (view.repos_diff or repos.len == 0) return;
        if (!view.repos_in) {
            view.repos_in = true;
            return;
        }
        return enter(app, repos[view.repos_pick].repo);
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
        try askAll(app, true);
        say(app, false, "fetching {d} repos", .{repos.len});
        return;
    }
}

const trailer_mark = " ‖ ";

/// The first `#N` in `text`.
fn ticketIn(text: []const u8) ?[]const u8 {
    var from: usize = 0;
    while (std.mem.indexOfPos(u8, text, from, "#")) |at| : (from = at + 1) {
        var end = at + 1;
        while (end < text.len and std.ascii.isDigit(text[end])) end += 1;
        if (end > at + 1) return text[at..end];
    }
    return null;
}

/// A commit as shown, `sha  subject`, with the `#N` its trailers name when its subject names none.
fn commitShown(buf: []u8, c: Commit) []const u8 {
    const split = std.mem.lastIndexOf(u8, c.rest, trailer_mark) orelse c.rest.len;
    const subject = c.rest[0..split];
    const trailers = if (split < c.rest.len) c.rest[split + trailer_mark.len ..] else "";
    const extra = if (ticketIn(subject) == null) ticketIn(trailers) else null;
    return std.fmt.bufPrint(buf, "{s}  {s}{s}{s}", .{ c.sha, subject, if (extra != null) "  " else "", extra orelse "" }) catch c.sha;
}

var cut_scratch: [512]u8 = undefined;

fn cut(text: []const u8, room: usize) []const u8 {
    return draw.clipMark(&cut_scratch, text, room);
}

fn rowOf(view: anytype, s: usize) *usize {
    return switch (s) {
        0 => &view.repos_file,
        1 => &view.repos_tree,
        else => &view.repos_commit,
    };
}

fn pickRows(view: anytype, file: usize, tree: usize, commit: usize) void {
    view.repos_file = file;
    view.repos_tree = tree;
    view.repos_commit = commit;
}

/// The first row of a window `h` rows tall that shows row `sel`.
fn windowStart(sel: usize, h: usize) usize {
    return if (sel < h) 0 else sel + 1 - h;
}

/// Section `s` of the picked repo at (`x`, `y`), `h` rows tall counting its heading.
fn paintSection(app: *App, w: *Writer, r: anytype, view: anytype, text: []const u8, s: usize, x: usize, y0: usize, room: usize, h: usize) !void {
    if (h == 0) return;
    const sum = parse(text);
    const focused = view.repos_in and view.repos_section == s;
    var head: [48]u8 = undefined;
    const title = switch (s) {
        0 => std.fmt.bufPrint(&head, "{s}  ●{d}", .{ sections[s], if (sum) |m| m.checkout.changed else 0 }),
        1 => std.fmt.bufPrint(&head, "{s}  ⎇{d}", .{ sections[s], if (sum) |m| m.worktrees else 0 }),
        else => std.fmt.bufPrint(&head, "{s}", .{sections[s]}),
    } catch sections[s];
    try bench.say(w, x, y0, cut(title, room), if (focused) r.accent else r.dim, r.panel, focused);
    const body = h - 1;
    const count = rowCount(text, s);
    if (sum == null) return bench.say(w, x, y0 + 1, "…", r.dim, r.panel, false);
    if (count == 0 and body > 0) {
        const none = switch (s) {
            0 => "clean",
            1 => "no worktrees",
            else => "no commits",
        };
        return bench.say(w, x, y0 + 1, none, r.dim, r.panel, false);
    }
    const log = logOf(text);
    const rows = if (s == 2) count + 1 else count;
    const sel = switch (s) {
        0 => view.repos_file,
        1 => view.repos_tree,
        else => view.repos_commit,
    };
    const picked_row = if (s == 2 and sel >= log.today) sel + 1 else sel;
    const from = windowStart(if (focused) picked_row else 0, body);
    var line: [512]u8 = undefined;
    var d = from;
    while (d < rows and d - from < body) : (d += 1) {
        const y = y0 + 1 + d - from;
        if (s == 2 and d == log.today) {
            try bench.say(w, x, y, "✓ today", r.dim, r.panel, false);
            continue;
        }
        const i = if (s == 2 and d > log.today) d - 1 else d;
        const marked = focused and i == sel;
        if (marked) try bench.say(w, x - 1, y, "▌", r.accent, r.panel, true);
        var ink = r.text;
        const shown: []const u8 = switch (s) {
            0 => blk: {
                const f = fileAt(text, i) orelse break :blk "";
                break :blk std.fmt.bufPrint(&line, "{s}  {s}", .{ f.code, f.path }) catch f.path;
            },
            1 => blk: {
                const t = treeAt(text, i) orelse break :blk "";
                const card = if (t.ticket) |id| app.ticketCard(id) else null;
                const stale = if (card) |c| c.status == .done else false;
                const holds = if (card) |c| c.status == .doing and c.claimed_by != null else false;
                if (stale) ink = r.dim;
                var named: [200]u8 = undefined;
                const name = if (t.ticket) |id|
                    std.fmt.bufPrint(&named, "#{d} {s}", .{ id, if (card) |c| c.short orelse c.title else t.co.branch }) catch ""
                else
                    t.co.branch;
                break :blk std.fmt.bufPrint(&line, "{s}  ●{d} ↑{d}{s}{s}", .{ name, t.co.changed, t.co.ahead, if (holds) "  claude" else "", if (stale) "  stale" else "" }) catch name;
            },
            else => blk: {
                const c = commitAt(text, i) orelse break :blk "";
                var sub: [400]u8 = undefined;
                const up = isUnpushed(text, c.sha);
                break :blk std.fmt.bufPrint(&line, "{s} {s}", .{ if (up) "↑" else " ", commitShown(&sub, c) }) catch c.sha;
            },
        };
        try bench.say(w, x, y, cut(shown, room), if (marked) r.text else ink, r.panel, marked);
    }
}

fn cells(text: []const u8) usize {
    var n: usize = 0;
    for (text) |c| n += @intFromBool(c & 0xC0 != 0x80);
    return n;
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

    const left: u16 = @intCast(@min(@as(usize, 38), inner / 2));
    const right_x = x0 + left + 2;
    const right_w: usize = inner -| (left + 2);
    const body_end = foot - 1;
    var y = rect.y + 1;
    while (y < body_end) : (y += 1) try bench.say(w, x0 + left, y, "│", r.dim, r.panel, false);

    var line: [512]u8 = undefined;
    y = rect.y + 1;
    for (repos, 0..) |s, i| {
        if (y >= body_end) break;
        const sum = parse(gitText(app, s.repo));
        const picked = i == view.repos_pick;
        var prefix_buf: [128]u8 = undefined;
        const prefix = std.fmt.bufPrint(&prefix_buf, "{s}  {s}  ↑{d} ↓{d}  ", .{ s.repo, if (sum) |m| m.checkout.branch else "main", s.ahead, s.behind }) catch s.repo;
        var stash: [16]u8 = undefined;
        const text = if (sum) |m|
            std.fmt.bufPrint(&line, "{s}●{d}  ⎇{d}{s}", .{ prefix, m.checkout.changed, m.worktrees, if (m.stashes > 0) std.fmt.bufPrint(&stash, "  ≡{d}", .{m.stashes}) catch "" else "" }) catch s.repo
        else
            std.fmt.bufPrint(&line, "{s}  main  ↑{d} ↓{d}", .{ s.repo, s.ahead, s.behind }) catch s.repo;
        const level = s.ahead == 0 and s.behind == 0 and (if (sum) |m| !stray(m) and m.checkout.changed == 0 and m.worktrees == 0 else true);
        if (picked) try bench.say(w, rect.x + 1, y, "▌", r.accent, r.panel, true);
        try bench.say(w, x0, y, cut(text, left), if (level and !picked) r.dim else r.text, r.panel, picked);
        if (sum) |m| {
            const dirty_x = x0 + cells(prefix);
            if (m.checkout.changed > 0 and cells(prefix) + 2 <= left) {
                var chip: [16]u8 = undefined;
                try bench.say(w, dirty_x, y, std.fmt.bufPrint(&chip, "●{d}", .{m.checkout.changed}) catch "●", r.building, r.panel, picked);
            }
            if (!std.mem.eql(u8, m.checkout.branch, "main")) {
                const bx = x0 + cells(s.repo) + 2;
                if (cells(s.repo) + 2 + cells(m.checkout.branch) <= left) try bench.say(w, bx, y, m.checkout.branch, r.building, r.panel, picked);
            }
        }
        y += 1;
    }

    y = rect.y + 1;
    if (view.repos_diff) {
        if (app.detail.items.len == 0) try bench.say(w, right_x, y, "…", r.dim, r.panel, false);
        var n: usize = 0;
        var lines = std.mem.splitScalar(u8, app.detail.items, '\n');
        while (lines.next()) |text| : (n += 1) {
            if (n < view.detail_scroll) continue;
            if (y >= body_end) break;
            try bench.say(w, right_x, y, cut(text, right_w), r.text, r.panel, false);
            y += 1;
        }
    } else if (view.repos_pick < repos.len) {
        const text = gitText(app, repos[view.repos_pick].repo);
        const body: usize = body_end -| y;
        const small = body / 4;
        const hs = [3]usize{ small, small, body - 2 * small };
        var at: usize = y;
        for (hs, 0..) |h, s| {
            try paintSection(app, w, r, view, text, s, right_x, at, right_w, h);
            at += h;
        }
    }

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
    else if (view.repos_in)
        " j k move   tab section   ⏎ open   h repos   P push   esc back "
    else
        " j k pick   tab sections   P push   A push all   f fetch   esc close ";
    try bench.say(w, x0, foot, cut(keys, inner), r.dim, r.panel, false);
}

const fixture = "--wt\n/p/arena\n# branch.head main\n# branch.ab +2 -1\n" ++
    "1 .M N... 100644 100644 100644 a b src/late.zig\n1 A. N... 000000 100644 100644 a b src/staged.zig\n? notes.txt\n" ++
    "--wt\n/p/arena/.worktrees/t42-x\n# branch.head t42-x\n--stash\n1\n--today\n1000\n--unpushed\naaa1111\n" ++
    "--log\naaa1111 2000 new ‖ \nbbb2222 900 old ‖ \n";

test "an answer reads as a summary, its staged files first, and its log as today's and the last ten" {
    const sum = parse(fixture).?;
    try std.testing.expectEqual(@as(u32, 3), sum.checkout.changed);
    try std.testing.expectEqual(@as(u32, 2), sum.checkout.ahead);
    try std.testing.expectEqual(@as(u32, 1), sum.checkout.behind);
    try std.testing.expectEqual(@as(u32, 1), sum.worktrees);
    try std.testing.expectEqual(@as(u32, 1), sum.stashes);
    try std.testing.expect(stray(sum));
    try std.testing.expectEqualStrings("src/staged.zig", fileAt(fixture, 0).?.path);
    try std.testing.expectEqualStrings("??", &fileAt(fixture, 2).?.code);
    try std.testing.expectEqual(@as(?u32, 42), treeAt(fixture, 0).?.ticket);
    try std.testing.expectEqual(Log{ .today = 1, .shown = 2 }, logOf(fixture));
    try std.testing.expect(isUnpushed(fixture, "aaa1111") and !isUnpushed(fixture, "bbb2222"));
    try std.testing.expect(parse("") == null);
}
