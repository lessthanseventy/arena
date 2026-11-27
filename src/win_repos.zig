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
const CommitFiles = app_mod.CommitFiles;

/// How often every repo is read again while the board is up, in milliseconds.
const refresh_ms = 30_000;

/// The sections of the picked repo, in `tab` order.
const sections = [_][]const u8{ "Status", "Worktrees", "Commits" };

/// What git said of a checkout, from `git status --porcelain=v2 --branch`.
const Checkout = struct { path: []const u8 = "", branch: []const u8 = "", ahead: u32 = 0, behind: u32 = 0, changed: u32 = 0 };

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
    c.path = lines.next() orelse "";
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
    const hash = std.hash.Wyhash.hash(0, repo);
    if (askedOut(app, hash)) return;
    const fetch = if (fetched) "git fetch -q origin main 2>/dev/null; " else "";
    try app.send(.ignore, "run-shell -b \"cd \\\"\\$HOME/projects/{s}\\\" && {s}(git worktree list --porcelain | sed -n 's/^worktree //p' | while read d; do echo --wt; echo \\$d; git --no-optional-locks -C \\$d status --porcelain=v2 --branch; echo --ahead; git -C \\$d rev-list --count main..HEAD; done; echo --stash; git stash list | wc -l; echo --today; date -d 00:00 +%s; echo --unpushed; git log --format=%h origin/main..main; echo --log; git log -n 200 --format='%h %ct %s ‖ %(trailers:valueonly,separator=%x20)' main) >'{s}.part' 2>&1; mv '{s}.part' '{s}'\"", .{ repo, fetch, path, path, path });
    if (app.status_out_n < app.status_out.len) {
        app.status_out[app.status_out_n] = .{ .repo = hash, .at = app.now };
        app.status_out_n += 1;
    }
}

/// How long an ask with no answer blocks the next, in milliseconds.
const ask_lost_ms = 120_000;

/// Whether a status ask of `repo`'s hash is out and not yet answered: one job per repo writes
/// its file at a time.
fn askedOut(app: *const App, hash: u64) bool {
    for (app.status_out[0..app.status_out_n]) |a| {
        if (a.repo == hash and app.now - a.at < ask_lost_ms) return true;
    }
    return false;
}

fn answered(app: *App, hash: u64) void {
    var i: usize = 0;
    while (i < app.status_out_n) {
        if (app.status_out[i].repo == hash) {
            app.status_out_n -= 1;
            app.status_out[i] = app.status_out[app.status_out_n];
        } else i += 1;
    }
}

fn gitBad(app: *const App, repo: []const u8) bool {
    for (app.repo_git[0..app.repo_git_n]) |g| if (std.mem.eql(u8, g.name[0..g.len], repo)) return g.bad;
    return false;
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
        const read = std.Io.Dir.cwd().readFileAlloc(app.io, path, app.gpa, .limited(1 << 20));
        if (read) |_| {} else |err| if (err == error.FileNotFound) continue;
        std.Io.Dir.cwd().deleteFile(app.io, path) catch {};
        answered(app, std.hash.Wyhash.hash(0, s.repo));
        const text = read catch app.gpa.alloc(u8, 0) catch continue;
        const bad = text.len == 0;
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
            g.bad = false;
            break :blk app.repo_git_n - 1;
        };
        const g = &app.repo_git[slot];
        app.gpa.free(g.text);
        g.text = text;
        g.bad = bad;
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

/// The commits of a worktree's branch that main has not: ticket branches have no upstream for
/// `# branch.ab` to count against.
fn aheadOf(text: []const u8, n: usize) u32 {
    return std.fmt.parseInt(u32, std.mem.trim(u8, part(text, "ahead", n + 1) orelse "", " \n"), 10) catch 0;
}

/// The ticket a babylon branch `t<N>-…` is of.
fn ticketOf(branch: []const u8) ?u32 {
    if (branch.len < 3 or branch[0] != 't') return null;
    var end: usize = 1;
    while (end < branch.len and std.ascii.isDigit(branch[end])) end += 1;
    if (end == 1 or end == branch.len or branch[end] != '-') return null;
    return std.fmt.parseInt(u32, branch[1..end], 10) catch null;
}

/// The `n`th worktree besides the main checkout, as the answer lists them.
fn treeAt(text: []const u8, n: usize) ?Tree {
    var co = checkoutOf(part(text, "wt", n + 1) orelse return null);
    co.ahead = aheadOf(text, n);
    return .{ .co = co, .ticket = ticketOf(co.branch) };
}

fn detached(t: Tree) bool {
    return std.mem.eql(u8, t.co.branch, "(detached)");
}

/// How many worktrees besides the main checkout are on a branch, and how many are detached.
const Trees = struct { branched: usize, loose: usize };

fn treesOf(text: []const u8) Trees {
    var t: Trees = .{ .branched = 0, .loose = 0 };
    var n: usize = 0;
    while (treeAt(text, n)) |tree| : (n += 1) {
        if (detached(tree)) t.loose += 1 else t.branched += 1;
    }
    return t;
}

/// The `n`th worktree in the order shown: those on a branch, then the detached ones.
fn treeShown(text: []const u8, n: usize) ?Tree {
    const t = treesOf(text);
    const want_loose = n >= t.branched;
    var skip = if (want_loose) n - t.branched else n;
    var k: usize = 0;
    while (treeAt(text, k)) |tree| : (k += 1) {
        if (detached(tree) != want_loose) continue;
        if (skip == 0) return tree;
        skip -= 1;
    }
    return null;
}

/// How many rows the worktrees take: two for each on a branch, then a heading and one each for
/// the detached.
fn treeRows(text: []const u8) usize {
    const t = treesOf(text);
    return t.branched * 2 + if (t.loose > 0) 1 + t.loose else 0;
}

/// The worktree (in the order shown) on row `d` of its rows, none on the detached heading.
fn treeOnRow(text: []const u8, d: usize) ?usize {
    const t = treesOf(text);
    if (d < t.branched * 2) return d / 2;
    if (d == t.branched * 2) return null;
    const n = t.branched + (d - t.branched * 2 - 1);
    return if (n < t.branched + t.loose) n else null;
}

/// The first row of worktree `n` (in the order shown), and how many rows it takes.
fn treeSpan(text: []const u8, n: usize) struct { at: usize, len: usize } {
    const t = treesOf(text);
    return if (n < t.branched) .{ .at = n * 2, .len = 2 } else .{ .at = t.branched * 2 + 1 + (n - t.branched), .len = 1 };
}

pub const Commit = struct { sha: []const u8, rest: []const u8, ct: i64 };

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

/// How many rows the commits take: a rule over each of today's and the earlier ones, when there are some.
fn commitRows(log: Log) usize {
    const earlier = log.shown - log.today;
    return @as(usize, @intFromBool(log.today > 0)) + log.today + if (earlier > 0) 1 + earlier else 0;
}

/// The first row of commit `i`.
fn commitSpan(log: Log, i: usize) usize {
    const top: usize = @intFromBool(log.today > 0);
    return if (i < log.today) top + i else top + log.today + 1 + (i - log.today);
}

/// The commit on row `d` of the commits' rows, none on a rule.
fn commitOnRow(log: Log, d: usize) ?usize {
    const top: usize = @intFromBool(log.today > 0);
    if (d < top) return null;
    if (d < top + log.today) return d - top;
    if (d == top + log.today) return null;
    const i = d - top - 1;
    return if (i < log.shown) i else null;
}

pub fn commitAt(text: []const u8, n: usize) ?Commit {
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
    takeFiles(app);
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
            const id = (treeShown(text, row) orelse return).ticket orelse return;
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

/// A commit's subject, then the `#N` its trailers name when the subject names none.
fn commitSubject(buf: []u8, c: Commit) []const u8 {
    const split = std.mem.lastIndexOf(u8, c.rest, trailer_mark) orelse c.rest.len;
    const subject = c.rest[0..split];
    const trailers = if (split < c.rest.len) c.rest[split + trailer_mark.len ..] else "";
    const extra = if (ticketIn(subject) == null) ticketIn(trailers) else null;
    return std.fmt.bufPrint(buf, "{s}{s}{s}", .{ subject, if (extra != null) "  " else "", extra orelse "" }) catch subject;
}

/// A commit's own subject, whole.
pub fn subjectOf(c: Commit) []const u8 {
    return c.rest[0 .. std.mem.lastIndexOf(u8, c.rest, trailer_mark) orelse c.rest.len];
}

/// The ticket a commit names, in its subject or its trailers.
pub fn ticketNamed(c: Commit) ?u32 {
    const tag = ticketIn(c.rest) orelse return null;
    return std.fmt.parseInt(u32, tag[1..], 10) catch null;
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

/// Whether a repo is even with its upstream, clean, on main and has no worktrees: its row is dim.
fn isLevel(s: tickets.RepoState, sum: ?Summary) bool {
    const m = sum orelse return s.ahead == 0 and s.behind == 0;
    return s.ahead == 0 and s.behind == 0 and !stray(m) and m.worktrees == 0;
}

fn cells(text: []const u8) usize {
    var n: usize = 0;
    for (text) |c| n += @intFromBool(c & 0xC0 != 0x80);
    return n;
}

const RGB = @import("color.zig").RGB;

/// A count's ink: `lit` when there is something, dim when it is zero.
fn countInk(r: anytype, n: u32, lit: RGB) RGB {
    return if (n == 0) r.dim else lit;
}

/// The rows a section holds, its empty line counted: a clean Status is one.
fn bodyRows(text: []const u8, s: usize) usize {
    const sum = parse(text) orelse return 1;
    const rows = switch (s) {
        0 => sum.checkout.changed,
        1 => treeRows(text),
        else => commitRows(logOf(text)),
    };
    return @max(1, rows);
}

const Box = struct { y: usize, h: usize };

/// Where the three boxes of a column `body` rows tall from `top` go, a blank row between: each as
/// tall as what it holds, Status and Worktrees up to a share of the column, Commits the rest.
fn boxesOf(text: []const u8, top: usize, body: usize) [3]Box {
    const avail = body -| 2;
    const h0 = @min(bodyRows(text, 0) + 2, @max(3, avail / 4));
    const h1 = @min(bodyRows(text, 1) + 2, @max(3, avail * 3 / 8));
    const h2 = @min(bodyRows(text, 2) + 2, avail -| (h0 + h1));
    return .{ .{ .y = top, .h = h0 }, .{ .y = top + h0 + 1, .h = h1 }, .{ .y = top + h0 + h1 + 2, .h = h2 } };
}

/// Where the repos view puts things, as the paint and a click on it both need.
const Geo = struct {
    x0: usize,
    inner: usize,
    left: usize,
    right_x: usize,
    right_w: usize,
    top: usize,
    body_end: usize,
    foot: usize,
    boxes: [3]Box,

    fn of(app: *const App, text: []const u8) ?Geo {
        const rect = app.columnRect() orelse return null;
        const inner: usize = app_mod.detailWidth(app.columnRoom()).inner;
        const x0: usize = rect.x + 2;
        const foot: usize = rect.y + rect.h - 1;
        const left: usize = @min(42, inner / 2);
        const top: usize = rect.y + 1;
        const body_end = foot - 1;
        return .{
            .x0 = x0,
            .inner = inner,
            .left = left,
            .right_x = x0 + left + 2,
            .right_w = inner -| (left + 2),
            .top = top,
            .body_end = body_end,
            .foot = foot,
            .boxes = boxesOf(text, top, body_end -| top),
        };
    }

    /// The rows inside box `s`: its first row's y and how many there are.
    fn inside(g: Geo, s: usize) struct { y: usize, n: usize } {
        return .{ .y = g.boxes[s].y + 1, .n = g.boxes[s].h -| 2 };
    }
};

/// The repo rows' columns: the name's width, the branch's.
const name_cap = 12;
const branch_w = 8;
const count_w = 4;

fn nameWidth(repos: []const tickets.RepoState) usize {
    var n: usize = 4;
    for (repos) |s| n = @max(n, @min(cells(s.repo), name_cap));
    return n;
}

/// One repo's row of the list at (`x`, `y`), `room` cells wide on `bg`: its `▌` and glyph and name in
/// its own colour, its branch dim on main and amber off it, and each count lit only when it is not zero.
fn paintRepo(w: *Writer, r: anytype, x: usize, y: usize, room: usize, bg: RGB, name_w: usize, s: tickets.RepoState, sum: ?Summary, bad: bool, picked: bool) !void {
    const hue = draw.repoHue(r, s.repo);
    try bench.fill(w, x - 1, y, room + 1, bg);
    try bench.say(w, x - 1, y, "▌", hue.hue, bg, true);
    var at = x;
    const end = x + room;
    try bench.say(w, at, y, hue.glyph, hue.hue, bg, false);
    at += 2;
    var nb: [64]u8 = undefined;
    try bench.say(w, at, y, draw.clipMark(&nb, s.repo, @min(name_w, end -| at)), hue.hue, bg, picked or !isLevel(s, sum));
    at += name_w + 1;
    const branch = if (sum) |m| m.checkout.branch else "main";
    if (at + branch_w <= end) {
        const on_main = std.mem.eql(u8, branch, "main");
        var bb: [64]u8 = undefined;
        try bench.say(w, at, y, draw.clipMark(&bb, branch, branch_w), if (on_main) r.dim else r.building, bg, !on_main);
    }
    at += branch_w + 1;
    const counts = [_]struct { glyph: []const u8, n: u32, lit: RGB }{
        .{ .glyph = "↑", .n = s.ahead, .lit = r.building },
        .{ .glyph = "↓", .n = s.behind, .lit = r.checking },
        .{ .glyph = "●", .n = if (sum) |m| m.checkout.changed else 0, .lit = r.building },
        .{ .glyph = "⎇", .n = if (sum) |m| m.worktrees else 0, .lit = r.text },
        .{ .glyph = "≡", .n = if (sum) |m| m.stashes else 0, .lit = r.text },
    };
    for (counts, 0..) |c, i| {
        if (at + count_w > end + 1) break;
        var cb: [16]u8 = undefined;
        if (i == 2 and sum == null) {
            if (bad) try bench.say(w, at, y, "●?", r.failed, bg, false);
        } else if (i == 4 and c.n == 0) {
            // no stash is no column of zeros
        } else if (i < 2 or sum != null) {
            try bench.say(w, at, y, std.fmt.bufPrint(&cb, "{s}{d}", .{ c.glyph, c.n }) catch c.glyph, countInk(r, c.n, c.lit), bg, c.n > 0);
        }
        at += count_w;
    }
}

/// A changed file's row: its code in the colour of what it did, then its path.
fn paintFile(w: *Writer, r: anytype, x: usize, y: usize, room: usize, bg: RGB, f: File) !void {
    const code = f.code[0];
    const hue = switch (code) {
        'M' => r.building,
        'A' => r.landed,
        'D' => r.failed,
        '?' => r.dim,
        else => r.text,
    };
    try bench.say(w, x, y, f.code[0..if (code == '?') 2 else 1], hue, bg, code != '?');
    try bench.say(w, x + 3, y, cut(f.path, room -| 3), if (code == '?') r.dim else r.text, bg, false);
}

/// A worktree's row: `line` 0 is its ticket's `#N` and short name, and its state at the right; 1
/// is its branch under it, dim. One on no ticket names its branch, then its folder; a detached one,
/// its folder, on a row of its own.
fn paintTree(w: *Writer, r: anytype, x: usize, y: usize, room: usize, bg: RGB, t: Tree, card: ?*const tickets.Card, line: usize) !void {
    const folder = std.fs.path.basename(t.co.path);
    if (line == 1) {
        return bench.say(w, x + 2, y, cut(if (t.ticket != null) t.co.branch else folder, room -| 2), r.dim, bg, false);
    }
    const stale = if (card) |c| c.status == .done else false;
    const holds = if (card) |c| c.status == .doing and c.claimed_by != null else false;
    var ahead: [16]u8 = undefined;
    var dirty: [16]u8 = undefined;
    const all = [_]struct { on: bool, text: []const u8, ink: RGB }{
        .{ .on = holds, .text = "● claude", .ink = r.landed },
        .{ .on = stale, .text = "stale", .ink = r.dim },
        .{ .on = t.co.ahead > 0, .text = std.fmt.bufPrint(&ahead, "↑{d}", .{t.co.ahead}) catch "↑", .ink = r.building },
        .{ .on = t.co.changed > 0, .text = std.fmt.bufPrint(&dirty, "●{d}", .{t.co.changed}) catch "●", .ink = r.building },
    };
    var state_w: usize = 0;
    for (all) |m| {
        if (m.on) state_w += cells(m.text) + 2;
    }
    state_w -|= 2;
    const name_room = room -| (state_w + if (state_w > 0) @as(usize, 2) else 0);
    var at = x;
    if (t.ticket) |id| {
        var nb: [16]u8 = undefined;
        const tag = std.fmt.bufPrint(&nb, "#{d}", .{id}) catch "#";
        try bench.say(w, at, y, tag, r.accent, bg, true);
        at += cells(tag) + 1;
        const name = if (card) |c| (c.short orelse c.title) else t.co.branch;
        try bench.say(w, at, y, cut(name, name_room -| (at - x)), if (stale) r.dim else r.text, bg, false);
    } else {
        try bench.say(w, at, y, cut(if (detached(t)) folder else t.co.branch, name_room), if (detached(t)) r.dim else r.text, bg, false);
    }
    var sx = x + room - state_w;
    for (all) |m| {
        if (!m.on) continue;
        try bench.say(w, sx, y, m.text, m.ink, bg, false);
        sx += cells(m.text) + 2;
    }
}

/// A commit's row: a lit `↑` when it is not pushed, its hash dim, its subject with each `#N` in
/// the accent, the whole subject dim when it is a review fix, so the real changes stand out.
fn paintCommit(w: *Writer, r: anytype, x: usize, y: usize, room: usize, bg: RGB, c: Commit, unpushed: bool) !void {
    if (unpushed) try bench.say(w, x, y, "↑", r.building, bg, true);
    try bench.say(w, x + 2, y, c.sha, r.dim, bg, false);
    var sub: [400]u8 = undefined;
    const subject = commitSubject(&sub, c);
    const review = std.mem.startsWith(u8, subject, "Review fixes");
    const ink = if (review) r.dim else r.text;
    const shown = cut(subject, room -| (2 + cells(c.sha) + 2));
    var at = x + 2 + cells(c.sha) + 2;
    var i: usize = 0;
    while (i < shown.len) {
        const hash = std.mem.indexOfScalarPos(u8, shown, i, '#') orelse shown.len;
        var end = hash + 1;
        while (hash < shown.len and end < shown.len and std.ascii.isDigit(shown[end])) end += 1;
        const tag = hash < shown.len and end > hash + 1;
        const plain = shown[i..if (tag) hash else shown.len];
        if (plain.len > 0) {
            try bench.say(w, at, y, plain, ink, bg, false);
            at += cells(plain);
        }
        if (!tag) break;
        try bench.say(w, at, y, shown[hash..end], if (review) r.dim else r.accent, bg, false);
        at += end - hash;
        i = end;
    }
}

/// A rule over a group of commits: `── today ──`.
fn paintRule(w: *Writer, r: anytype, x: usize, y: usize, room: usize, bg: RGB, word: []const u8) !void {
    var buf: [64]u8 = undefined;
    try bench.say(w, x, y, cut(std.fmt.bufPrint(&buf, "── {s} ──", .{word}) catch word, room), r.dim, bg, false);
}

/// The row of box `s` that is picked, which sits in view.
fn pickedRow(text: []const u8, view: anytype, s: usize) usize {
    const sel = switch (s) {
        0 => view.repos_file,
        1 => view.repos_tree,
        else => view.repos_commit,
    };
    return switch (s) {
        0 => sel,
        1 => {
            const span = treeSpan(text, sel);
            return span.at + span.len - 1;
        },
        else => commitSpan(logOf(text), sel),
    };
}

/// The first row of box `s` that shows.
fn firstRow(text: []const u8, view: anytype, s: usize, body: usize) usize {
    const focused = view.repos_in and view.repos_section == s;
    return windowStart(if (focused) pickedRow(text, view, s) else 0, body);
}

/// The item of box `s` on row `d` of its rows, none on a rule or past the end.
fn itemOnRow(text: []const u8, s: usize, d: usize) ?usize {
    const sum = parse(text) orelse return null;
    return switch (s) {
        0 => if (d < sum.checkout.changed) d else null,
        1 => treeOnRow(text, d),
        else => commitOnRow(logOf(text), d),
    };
}

fn boxTitle(buf: []u8, s: usize) []const u8 {
    return std.fmt.bufPrint(buf, "{s}", .{switch (s) {
        0 => "status",
        1 => "worktrees",
        else => "commits",
    }}) catch "";
}

/// Box `s` of the picked repo: a window with its count, its rows under it, the picked one lit
/// when the box is focused, and the row under the pointer lit lighter.
fn paintBox(app: *App, w: *Writer, r: anytype, view: anytype, text: []const u8, g: Geo, s: usize) !void {
    const box = g.boxes[s];
    if (box.h < 2) return;
    const sum = parse(text);
    const focused = view.repos_in and view.repos_section == s;
    var tb: [16]u8 = undefined;
    const count: ?usize = if (sum) |m| switch (s) {
        0 => m.checkout.changed,
        1 => m.worktrees,
        else => logOf(text).shown,
    } else null;
    try bench.window(w, r, g.right_x, box.y, g.right_w, box.h, boxTitle(&tb, s), count, focused);
    const body = g.inside(s);
    if (body.n == 0) return;
    const tx = g.right_x + 2;
    const room = g.right_w -| 4;
    if (sum == null) return bench.say(w, tx, body.y, "…", r.dim, r.panel, false);
    const rows = bodyRows(text, s);
    const empty = switch (s) {
        0 => sum.?.checkout.changed == 0,
        1 => sum.?.worktrees == 0,
        else => logOf(text).shown == 0,
    };
    if (empty) {
        return bench.say(w, tx, body.y, switch (s) {
            0 => "✓ clean",
            1 => "no worktrees",
            else => "no commits",
        }, r.dim, r.panel, false);
    }
    const from = firstRow(text, view, s, body.n);
    const sel = switch (s) {
        0 => view.repos_file,
        1 => view.repos_tree,
        else => view.repos_commit,
    };
    var d = from;
    while (d < rows and d - from < body.n) : (d += 1) {
        const y = body.y + d - from;
        const item = itemOnRow(text, s, d);
        const marked = focused and item != null and item.? == sel;
        const over = app.pointer.y == y and app.pointer.x >= g.right_x + 1 and app.pointer.x < g.right_x + g.right_w - 1 and item != null;
        const bg = if (marked) r.raised else if (over) r.tile else r.panel;
        if (marked or over) try bench.fill(w, g.right_x + 1, y, g.right_w - 2, bg);
        if (marked) try bench.say(w, g.right_x + 1, y, "▌", r.accent, bg, true);
        switch (s) {
            0 => try paintFile(w, r, tx, y, room, bg, fileAt(text, d) orelse continue),
            1 => if (item) |i| {
                const t = treeShown(text, i) orelse continue;
                const card = if (t.ticket) |id| app.ticketCard(id) else null;
                const span = treeSpan(text, i);
                try paintTree(w, r, tx, y, room, bg, t, card, d - span.at);
            } else {
                var hb: [32]u8 = undefined;
                try bench.say(w, tx, y, std.fmt.bufPrint(&hb, "detached · {d}", .{treesOf(text).loose}) catch "detached", r.dim, bg, false);
            },
            else => if (item) |i| {
                const c = commitAt(text, i) orelse continue;
                try paintCommit(w, r, tx, y, room, bg, c, isUnpushed(text, c.sha));
            } else {
                const log = logOf(text);
                try paintRule(w, r, tx, y, room, bg, if (log.today > 0 and d == 0) "today" else "earlier");
            },
        }
    }
}

/// A key of the foot: what it presses when clicked, if it is a button.
const FootKey = struct { key: []const u8, label: []const u8, press: ?[]const u8 };

/// The foot's keys for the mode the view is in.
fn footKeys(view: anytype, buf: []u8, n_ahead: usize, out: *[8]FootKey) []const FootKey {
    if (view.repos_confirm) {
        out[0] = .{ .key = "", .label = std.fmt.bufPrint(buf, "push {d} repos?", .{n_ahead}) catch "push?", .press = null };
        out[1] = .{ .key = "y", .label = "push", .press = "y" };
        out[2] = .{ .key = "n", .label = "cancel", .press = "n" };
        return out[0..3];
    }
    if (view.repos_diff) {
        out[0] = .{ .key = "j k", .label = "scroll", .press = null };
        out[1] = .{ .key = "esc", .label = "back", .press = "\x1b" };
        return out[0..2];
    }
    if (view.repos_in) {
        out[0] = .{ .key = "j k", .label = "move", .press = null };
        out[1] = .{ .key = "tab", .label = "section", .press = "\t" };
        out[2] = .{ .key = "⏎", .label = "open", .press = "\r" };
        out[3] = .{ .key = "h", .label = "repos", .press = "h" };
        out[4] = .{ .key = "P", .label = "push", .press = "P" };
        out[5] = .{ .key = "esc", .label = "back", .press = "\x1b" };
        return out[0..6];
    }
    out[0] = .{ .key = "j k", .label = "pick", .press = null };
    out[1] = .{ .key = "tab", .label = "sections", .press = "\t" };
    out[2] = .{ .key = "P", .label = "push", .press = "P" };
    out[3] = .{ .key = "A", .label = "push all", .press = "A" };
    out[4] = .{ .key = "f", .label = "fetch", .press = "f" };
    out[5] = .{ .key = "esc", .label = "close", .press = "\x1b" };
    return out[0..6];
}

/// The cells key `k` of the foot takes: a space, its key, a space, its label, a space.
fn footWidth(k: FootKey) usize {
    return (if (k.key.len > 0) cells(k.key) + 1 else 0) + cells(k.label) + 2;
}

/// The key of the foot at column `x`, from `x0`: where it starts, and what it presses if it is a button.
fn footAt(view: anytype, n_ahead: usize, x0: usize, x: usize) ?struct { at: usize, press: ?[]const u8 } {
    var buf: [48]u8 = undefined;
    var keys: [8]FootKey = undefined;
    var at = x0;
    for (footKeys(view, &buf, n_ahead, &keys)) |k| {
        const width = footWidth(k);
        if (x >= at and x < at + width) return .{ .at = at, .press = k.press };
        at += width + 1;
    }
    return null;
}

/// The item of box `s` on screen row `y`, none on a rule, a border or past the end.
fn itemAtY(text: []const u8, view: anytype, g: Geo, s: usize, y: usize) ?usize {
    const body = g.inside(s);
    if (y < body.y or y >= body.y + body.n) return null;
    return itemOnRow(text, s, firstRow(text, view, s, body.n) + (y - body.y));
}

/// What the pointer at (`x`, `y`) is on that lights under it: a repo's row, a row of a box, or a
/// button of the foot; 0 for nothing. Two cells with one answer light the same thing.
pub fn hovered(app: *const App, x: u16, y: u16) u64 {
    const view = app.home orelse return 0;
    if (!view.repos or view.detail != null) return 0;
    var rows: Repos = undefined;
    const repos = list(app, &rows);
    const pick = @min(view.repos_pick, repos.len -| 1);
    const text = if (pick < repos.len) gitText(app, repos[pick].repo) else "";
    const g = Geo.of(app, text) orelse return 0;
    if (y == g.foot) {
        var n_ahead: usize = 0;
        for (repos) |s| n_ahead += @intFromBool(s.ahead > 0);
        const hit = footAt(view, n_ahead, g.x0, x) orelse return 0;
        return if (hit.press != null) @as(u64, 3) << 32 | hit.at else 0;
    }
    if (x >= g.x0 and x < g.x0 + g.left and y >= g.top and y < g.top + repos.len and y < g.body_end) return @as(u64, 1) << 32 | y;
    if (view.repos_diff or pick >= repos.len or x < g.right_x + 1 or x + 1 >= g.right_x + g.right_w) return 0;
    for (0..3) |s| if (itemAtY(text, view, g, s, y) != null) return @as(u64, 2) << 32 | y;
    return 0;
}

fn filesPath(app: *const App, repo: []const u8, sha: []const u8, buf: []u8) ?[]const u8 {
    const dir = app.board_dir orelse return null;
    return std.fmt.bufPrint(buf, "{s}/files-{s}-{s}", .{ dir, repo, sha }) catch null;
}

fn filesFor(app: *const App, repo: []const u8, sha: []const u8) ?*CommitFiles {
    for (app.commit_files.items) |*c| {
        if (std.mem.eql(u8, c.repo[0..c.repo_len], repo) and std.mem.eql(u8, c.sha[0..c.sha_len], sha)) return c;
    }
    return null;
}

/// How many commits' files are kept; the oldest asked goes first.
const files_kept = 32;

/// Asks git for the files of the commit on row `row` of repo `repo`'s list, once: its answer is
/// kept by repo and hash, so the status refresh stays as it is.
pub fn askFiles(app: *App, repo: usize, row: usize) !void {
    var rows: Repos = undefined;
    const repos = list(app, &rows);
    if (repo >= repos.len) return;
    const name = repos[repo].repo;
    const c = commitAt(gitText(app, name), row) orelse return;
    if (c.sha.len > 40 or name.len > 48 or filesFor(app, name, c.sha) != null) return;
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = filesPath(app, name, c.sha, &buf) orelse return;
    if (app.commit_files.items.len == files_kept) {
        if (app.commit_files.items[0].text) |text| app.gpa.free(text);
        _ = app.commit_files.orderedRemove(0);
    }
    var e: CommitFiles = .{ .repo = undefined, .repo_len = @intCast(name.len), .sha = undefined, .sha_len = @intCast(c.sha.len) };
    @memcpy(e.repo[0..name.len], name);
    @memcpy(e.sha[0..c.sha.len], c.sha);
    try app.commit_files.append(app.gpa, e);
    try app.send(.ignore, "run-shell -b \"git -C \\\"\\$HOME/projects/{s}\\\" show --stat --format= {s} >'{s}.part' 2>&1; mv '{s}.part' '{s}'\"", .{ name, c.sha, path, path, path });
}

/// Takes in the answers of the files asked for.
fn takeFiles(app: *App) void {
    for (app.commit_files.items) |*c| {
        if (c.text != null) continue;
        var buf: [std.fs.max_path_bytes]u8 = undefined;
        const path = filesPath(app, c.repo[0..c.repo_len], c.sha[0..c.sha_len], &buf) orelse continue;
        const text = std.Io.Dir.cwd().readFileAlloc(app.io, path, app.gpa, .limited(1 << 16)) catch continue;
        std.Io.Dir.cwd().deleteFile(app.io, path) catch {};
        c.text = text;
        app.dirty = true;
    }
}

/// The `--stat` of the commit on row `row` of repo `repo`'s list; null until it answers.
pub fn filesOf(app: *const App, repo: usize, row: usize) ?[]const u8 {
    var rows: Repos = undefined;
    const repos = list(app, &rows);
    if (repo >= repos.len) return null;
    const name = repos[repo].repo;
    const c = commitAt(gitText(app, name), row) orelse return null;
    return (filesFor(app, name, c.sha) orelse return null).text;
}

/// A `--stat`'s file lines, the first `out.len` of them, how many more there are, and its summary line.
pub fn statOf(text: []const u8, out: [][]const u8) struct { n: usize, more: usize, summary: []const u8 } {
    var files: usize = 0;
    var summary: []const u8 = "";
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \r");
        if (line.len == 0) continue;
        if (std.mem.indexOf(u8, line, " changed") != null and std.mem.indexOfScalar(u8, line, '|') == null) {
            summary = line;
            continue;
        }
        if (files < out.len) out[files] = line;
        files += 1;
    }
    return .{ .n = @min(files, out.len), .more = files -| out.len, .summary = summary };
}

fn paintFoot(app: *const App, w: *Writer, r: anytype, view: anytype, g: Geo, n_ahead: usize) !void {
    var buf: [48]u8 = undefined;
    var keys: [8]FootKey = undefined;
    var at = g.x0;
    for (footKeys(view, &buf, n_ahead, &keys)) |k| {
        const width = footWidth(k);
        if (at + width > g.x0 + g.inner) break;
        const over = k.press != null and app.pointer.y == g.foot and app.pointer.x >= at and app.pointer.x < at + width;
        const bg = if (over) r.tile else r.panel;
        try bench.fill(w, at, g.foot, width, bg);
        var x = at + 1;
        if (k.key.len > 0) {
            try bench.say(w, x, g.foot, k.key, r.accent, bg, true);
            x += cells(k.key) + 1;
        }
        try bench.say(w, x, g.foot, k.label, if (k.press != null) r.text else r.dim, bg, false);
        at += width + 1;
    }
}

pub fn paint(app: *App, w: *Writer) !void {
    const r = app.roles orelse bench.roles();
    const rect = app.columnRect() orelse return;
    const view = app.home.?;
    var rows: Repos = undefined;
    const repos = list(app, &rows);
    const pick = @min(view.repos_pick, repos.len -| 1);
    const text = if (pick < repos.len) gitText(app, repos[pick].repo) else "";
    const g = Geo.of(app, text) orelse return;
    app.grab.window(.{ .x = @intCast(g.x0), .y = rect.y + 1, .w = @intCast(g.inner), .h = rect.h -| 2 });
    try bench.window(w, r, rect.x, rect.y, rect.w - 1, rect.h + 1, "repos", null, true);

    var y = g.top;
    while (y < g.body_end) : (y += 1) try bench.say(w, g.x0 + g.left, y, "│", r.dim, r.panel, false);

    const name_w = nameWidth(repos);
    y = g.top;
    for (repos, 0..) |s, i| {
        if (y >= g.body_end) break;
        const picked = i == view.repos_pick;
        const over = app.pointer.y == y and app.pointer.x >= g.x0 and app.pointer.x < g.x0 + g.left;
        const bg = if (picked) r.raised else if (over) r.tile else r.panel;
        try paintRepo(w, r, g.x0, y, g.left, bg, name_w, s, parse(gitText(app, s.repo)), gitBad(app, s.repo), picked);
        y += 1;
    }

    if (view.repos_diff) {
        y = g.top;
        if (app.detail.items.len == 0) try bench.say(w, g.right_x, y, "…", r.dim, r.panel, false);
        var n: usize = 0;
        var lines = std.mem.splitScalar(u8, app.detail.items, '\n');
        while (lines.next()) |line| : (n += 1) {
            if (n < view.detail_scroll) continue;
            if (y >= g.body_end) break;
            try bench.say(w, g.right_x, y, cut(line, g.right_w), r.text, r.panel, false);
            y += 1;
        }
    } else if (pick < repos.len) {
        for (0..3) |s| try paintBox(app, w, r, view, text, g, s);
    }

    if (app.repos_said_len > 0) {
        try bench.say(w, g.x0, g.body_end, cut(app.repos_said[0..app.repos_said_len], g.inner), if (app.repos_bad) r.failed else r.dim, r.panel, false);
    }
    var n_ahead: usize = 0;
    for (repos) |s| n_ahead += @intFromBool(s.ahead > 0);
    try paintFoot(app, w, r, view, g, n_ahead);
}

/// A click on the repos view: a repo's row picks it, a box focuses, a row of one picks it and
/// the picked one opens, and a key of the foot is pressed.
pub fn click(app: *App, m: @import("keys.zig").Mouse) !void {
    const view = &app.home.?;
    var rows: Repos = undefined;
    const repos = list(app, &rows);
    const pick = @min(view.repos_pick, repos.len -| 1);
    const text = if (pick < repos.len) gitText(app, repos[pick].repo) else "";
    const g = Geo.of(app, text) orelse return;
    var n_ahead: usize = 0;
    for (repos) |s| n_ahead += @intFromBool(s.ahead > 0);
    if (m.y == g.foot) {
        if (footAt(view.*, n_ahead, g.x0, m.x)) |hit| if (hit.press) |press| try key(app, press);
        return;
    }
    if (view.repos_confirm or view.repos_diff) return;
    if (m.x >= g.x0 and m.x < g.x0 + g.left and m.y >= g.top and m.y < g.top + repos.len and m.y < g.body_end) {
        const was = view.repos_pick;
        view.repos_pick = m.y - g.top;
        view.repos_in = false;
        if (view.repos_pick != was) pickRows(view, 0, 0, 0);
        return;
    }
    if (pick >= repos.len) return;
    for (0..3) |s| {
        const box = g.boxes[s];
        if (m.x < g.right_x or m.x >= g.right_x + g.right_w or m.y < box.y or m.y >= box.y + box.h) continue;
        const was_focused = view.repos_in and view.repos_section == s;
        view.repos_in = true;
        view.repos_section = @intCast(s);
        const body = g.inside(s);
        if (m.y < body.y or m.y >= body.y + body.n) return;
        const d = firstRow(text, view.*, s, body.n) + (m.y - body.y);
        const item = itemOnRow(text, s, d) orelse return;
        const row = rowOf(view, s);
        const was_row = row.*;
        row.* = item;
        if (was_focused and was_row == item) try enter(app, repos[pick].repo);
        return;
    }
}

/// What the pointer at (`x`, `y`) rests on in the repos view: a worktree's ticket or a commit.
pub fn lookAt(app: *const App, x: u16, y: u16) ?App.Look {
    const view = app.home orelse return null;
    if (!view.repos or view.detail != null or view.repos_diff) return null;
    var rows: Repos = undefined;
    const repos = list(app, &rows);
    const pick = @min(view.repos_pick, repos.len -| 1);
    if (pick >= repos.len) return null;
    const text = gitText(app, repos[pick].repo);
    const g = Geo.of(app, text) orelse return null;
    for (1..3) |s| {
        const box = g.boxes[s];
        if (x < g.right_x + 1 or x + 1 >= g.right_x + g.right_w or y < box.y or y >= box.y + box.h) continue;
        const body = g.inside(s);
        if (y < body.y or y >= body.y + body.n) return null;
        const d = firstRow(text, view, s, body.n) + (y - body.y);
        const item = itemOnRow(text, s, d) orelse return null;
        if (s == 1) {
            const id = (treeShown(text, item) orelse return null).ticket orelse return null;
            return if (app.ticketCard(id) != null) .{ .ticket = id } else null;
        }
        return .{ .commit = .{ .repo = @intCast(pick), .row = @intCast(item) } };
    }
    return null;
}

/// The box `s` of the picked repo's answer is at, for a test to aim at.
pub fn boxAt(app: *const App, s: usize) ?struct { x: usize, y: usize, w: usize, h: usize } {
    var rows: Repos = undefined;
    const repos = list(app, &rows);
    const view = app.home orelse return null;
    const text = if (view.repos_pick < repos.len) gitText(app, repos[view.repos_pick].repo) else "";
    const g = Geo.of(app, text) orelse return null;
    return .{ .x = g.right_x, .y = g.boxes[s].y, .w = g.right_w, .h = g.boxes[s].h };
}

/// The column of the foot's button that presses `press`, and the repo rows' column and first row.
pub fn footColumn(app: *const App, press: []const u8) ?usize {
    const view = app.home orelse return null;
    const g = Geo.of(app, "") orelse return null;
    var buf: [48]u8 = undefined;
    var keys: [8]FootKey = undefined;
    var at = g.x0;
    for (footKeys(view, &buf, 0, &keys)) |k| {
        if (k.press) |p| if (std.mem.eql(u8, p, press)) return at + 1;
        at += footWidth(k) + 1;
    }
    return null;
}

/// The cell of the repo list's first row.
pub fn listAt(app: *const App) ?struct { x: usize, y: usize } {
    const g = Geo.of(app, "") orelse return null;
    return .{ .x = g.x0, .y = g.top };
}

/// The commit a peek of `repo`'s row `row` is of.
pub fn commitOf(app: *const App, repo: usize, row: usize) ?Commit {
    var rows: Repos = undefined;
    const repos = list(app, &rows);
    if (repo >= repos.len) return null;
    return commitAt(gitText(app, repos[repo].repo), row);
}

const fixture = "--wt\n/p/arena\n# branch.head main\n# branch.ab +2 -1\n" ++
    "1 .M N... 100644 100644 100644 a b src/late.zig\n1 A. N... 000000 100644 100644 a b src/staged.zig\n? notes.txt\n--ahead\n0\n" ++
    "--wt\n/p/arena/.worktrees/t42-x\n# branch.head t42-x\n--ahead\n1\n--stash\n1\n--today\n1000\n--unpushed\naaa1111\n" ++
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
    try std.testing.expectEqual(@as(u32, 1), treeAt(fixture, 0).?.co.ahead);
    const clean = parse("--wt\n/p/a\n# branch.head main\n# branch.ab +0 -0\n--stash\n0\n").?;
    try std.testing.expect(isLevel(.{ .repo = "a" }, clean));
    try std.testing.expect(!isLevel(.{ .repo = "a", .ahead = 1 }, clean));
    try std.testing.expect(!isLevel(.{ .repo = "a" }, parse(fixture)));
    try std.testing.expect(!isLevel(.{ .repo = "a" }, parse("--wt\n/p/a\n# branch.head topic\n").?));
    try std.testing.expect(!isLevel(.{ .repo = "a" }, parse("--wt\n/p/a\n# branch.head main\n? x\n").?));
    try std.testing.expectEqual(Log{ .today = 1, .shown = 2 }, logOf(fixture));
    try std.testing.expect(isUnpushed(fixture, "aaa1111") and !isUnpushed(fixture, "bbb2222"));
    try std.testing.expect(parse("") == null);
}

fn paintOf(buf: []u8, comptime paint_fn: anytype, args: anytype) ![]const u8 {
    var w: Writer = .fixed(buf);
    try @call(.auto, paint_fn, .{&w} ++ args);
    return w.buffered();
}

test "a repo's row has its colour, a dim main, and lit counts only where they are not zero" {
    const r = bench.roles();
    var buf: [4096]u8 = undefined;
    const sum = parse("--wt\n/p/arena\n# branch.head main\n# branch.ab +0 -0\n1 .M N... 100644 100644 100644 a b x\n--stash\n0\n").?;
    const f = try paintOf(&buf, paintRepo, .{ r, 4, 2, 38, r.panel, 6, tickets.RepoState{ .repo = "arena", .ahead = 78 }, @as(?Summary, sum), false, false });
    try bench.expectCell(f, 3, 2, '▌', r.repo[0], r.panel);
    try bench.expectCell(f, 6, 2, 'a', r.repo[0], r.panel);
    try bench.expectCell(f, 13, 2, 'm', r.dim, r.panel);
    try bench.expectCell(f, 22, 2, '↑', r.building, r.panel);
    try bench.expectCell(f, 26, 2, '↓', r.dim, r.panel);
    try bench.expectCell(f, 27, 2, '0', r.dim, r.panel);
    try bench.expectCell(f, 30, 2, '●', r.building, r.panel);
    try bench.expectCell(f, 34, 2, '⎇', r.dim, r.panel);

    const off = parse("--wt\n/p/arena\n# branch.head topic\n").?;
    const g = try paintOf(&buf, paintRepo, .{ r, 4, 2, 38, r.panel, 6, tickets.RepoState{ .repo = "arena" }, @as(?Summary, off), false, false });
    try bench.expectCell(g, 13, 2, 't', r.building, r.panel);
}

test "a clean Status takes one row, and a section is as tall as what it holds" {
    try std.testing.expectEqual(@as(usize, 1), bodyRows("--wt\n/p/a\n# branch.head main\n", 0));
    try std.testing.expectEqual(@as(usize, 3), bodyRows(fixture, 0));
    const clean = "--wt\n/p/a\n# branch.head main\n--log\n";
    const boxes = boxesOf(clean, 5, 40);
    try std.testing.expectEqual(@as(usize, 3), boxes[0].h);
    try std.testing.expectEqual(boxes[0].y + boxes[0].h + 1, boxes[1].y);
    try std.testing.expect(boxes[2].y + boxes[2].h <= 5 + 40);
}

test "a worktree on t42-x draws #42 in the accent with its ticket's short name, and what holds it in green" {
    const r = bench.roles();
    var buf: [4096]u8 = undefined;
    const card: tickets.Card = .{ .id = 42, .title = "A long title", .short = "tidy up", .status = .doing, .claimed_by = "%1" };
    const t = treeAt(fixture, 0).?;
    const f = try paintOf(&buf, paintTree, .{ r, 4, 2, 40, r.panel, t, @as(?*const tickets.Card, &card), @as(usize, 0) });
    try bench.expectCell(f, 4, 2, '#', r.accent, r.panel);
    try bench.expectCell(f, 8, 2, 't', r.text, r.panel);
    try bench.expectCell(f, 32, 2, '●', r.landed, r.panel);
    try bench.expectCell(f, 34, 2, 'c', r.landed, r.panel);
    try bench.expectCell(f, 42, 2, '↑', r.building, r.panel);
    const under = try paintOf(&buf, paintTree, .{ r, 4, 3, 40, r.panel, t, @as(?*const tickets.Card, &card), @as(usize, 1) });
    try bench.expectCell(under, 6, 3, 't', r.dim, r.panel);
}

test "a review fix draws dim, a real change in the text ink with its #N in the accent" {
    const r = bench.roles();
    var buf: [4096]u8 = undefined;
    const real = commitAt("--log\naaa1111 2000 Add the view for #12 ‖ \n", 0).?;
    const f = try paintOf(&buf, paintCommit, .{ r, 4, 2, 40, r.panel, real, true });
    try bench.expectCell(f, 4, 2, '↑', r.building, r.panel);
    try bench.expectCell(f, 6, 2, 'a', r.dim, r.panel);
    try bench.expectCell(f, 15, 2, 'A', r.text, r.panel);
    try bench.expectCell(f, 15 + 17, 2, '#', r.accent, r.panel);
    const fix = commitAt("--log\nbbb2222 2000 Review fixes for #12 ‖ \n", 0).?;
    const g = try paintOf(&buf, paintCommit, .{ r, 4, 2, 40, r.panel, fix, false });
    try bench.expectCell(g, 15, 2, 'R', r.dim, r.panel);
    try bench.expectCell(g, 15 + 17, 2, '#', r.dim, r.panel);
}

test "detached worktrees go last, and the rows of worktrees and commits map back to their items" {
    const text = "--wt\n/p/a\n# branch.head main\n--wt\n/p/a/.worktrees/x\n# branch.head (detached)\n--wt\n/p/a/.worktrees/t5-y\n# branch.head t5-y\n--ahead\n0\n--ahead\n0\n--ahead\n0\n--today\n1000\n--log\naaa1111 2000 a ‖ \nbbb2222 900 b ‖ \n";
    try std.testing.expectEqualStrings("t5-y", treeShown(text, 0).?.co.branch);
    try std.testing.expectEqualStrings("(detached)", treeShown(text, 1).?.co.branch);
    try std.testing.expectEqual(@as(usize, 4), treeRows(text));
    try std.testing.expectEqual(@as(?usize, 0), treeOnRow(text, 1));
    try std.testing.expectEqual(@as(?usize, null), treeOnRow(text, 2));
    try std.testing.expectEqual(@as(?usize, 1), treeOnRow(text, 3));
    const log = logOf(text);
    try std.testing.expectEqual(@as(usize, 4), commitRows(log));
    try std.testing.expectEqual(@as(?usize, null), commitOnRow(log, 0));
    try std.testing.expectEqual(@as(?usize, 0), commitOnRow(log, 1));
    try std.testing.expectEqual(@as(?usize, null), commitOnRow(log, 2));
    try std.testing.expectEqual(@as(?usize, 1), commitOnRow(log, 3));
}

test "a stat reads as its files, how many more there are, and its summary" {
    var out: [2][]const u8 = undefined;
    const s = statOf(" a | 1 +\n b | 2 ++\n c | 3 +++\n 3 files changed, 6 insertions(+)\n", &out);
    try std.testing.expectEqual(@as(usize, 2), s.n);
    try std.testing.expectEqual(@as(usize, 1), s.more);
    try std.testing.expectEqualStrings("a | 1 +", out[0]);
    try std.testing.expectEqualStrings("3 files changed, 6 insertions(+)", s.summary);
    try std.testing.expectEqual(@as(usize, 0), statOf("", &out).n);
}
