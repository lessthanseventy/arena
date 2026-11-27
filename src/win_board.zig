//! The board: Doing's one list across every repo, ordered by time. Landed today lies above the
//! `now` line; below it the pipeline, what is being built, and next. Each row is its state word,
//! `#id`, short name, repo, `◆` when the ticket is a step of the goal driven, one wait word, and
//! its age.
const std = @import("std");
const color = @import("color.zig");
const theme = @import("theme.zig");
const bench = @import("parts.zig");
const app_mod = @import("app.zig");
const tickets = @import("board.zig");
const sheets = @import("plan.zig");
const draw = @import("draw.zig");
const text_mod = @import("text.zig");
const win_detail = @import("win_detail.zig");
const win_next = @import("win_next.zig");
const App = app_mod.App;
const Writer = std.Io.Writer;
const cellCount = draw.cellCount;
const repoHue = draw.repoHue;

const state_x = 2;
const state_w = 13;
/// Where a row's `#id` starts, and so what an opened row's block is indented to.
pub const id_x = state_x + state_w + 1;
const name_x = id_x + 7;
const repo_w = 10;
const wait_w = 14;

const Scratch = struct {
    state: [40]u8 = undefined,
    wait: [64]u8 = undefined,
    age: [16]u8 = undefined,
    place: [16]u8 = undefined,
    said: [64]u8 = undefined,
};

/// What a board row says of its ticket.
const Facts = struct {
    id: u32,
    state: []const u8,
    lead: color.RGB,
    repo: ?[]const u8,
    name: []const u8,
    wait: []const u8 = "",
    wait_lead: color.RGB,
    age: []const u8 = "",
};

/// Whether ticket `id` is a step of the goal being driven.
fn inDrivenGoal(given: *const tickets.Plan, id: u32) bool {
    const epic = given.driving orelse return false;
    for (given.goals) |goal| if (goal.epic == epic) for (goal.steps) |step| {
        if (step.ticket == id) return true;
    };
    return false;
}

/// A ticket babylon sent back (stage `failed`): whether its Claude is at work on it, why it came
/// back, when, and what it waits on before anyone has to act: its `waiting_on`, else an open blocker.
pub const Back = struct { fixing: bool, idle: bool, cause: []const u8, at: ?[]const u8, waits: ?tickets.WaitingOn = null };

pub fn sentBack(app: *const App, item: tickets.NowItem) ?Back {
    if (!std.mem.eql(u8, item.stage orelse "", "failed")) return null;
    const card = app.cardById(item.ticket);
    const win = if (item.holder()) |held| app.paneWindow(held) else null;
    const mark: app_mod.Mark = if (win) |at| at.session.wins.items[at.index].claude else .waiting;
    return .{
        .fixing = mark == .working or mark == .background,
        .idle = win != null and mark != .waiting and mark != .working and mark != .background,
        .cause = if (card) |c| text_mod.sentBackCause(c.stage_note) else "",
        .at = if (card) |c| c.stage_at orelse item.since else item.since,
        .waits = item.waiting_on orelse if (card) |c| c.waiting_on orelse
            if (c.blocked_by.len > 0) tickets.WaitingOn{ .ticket = c.blocked_by[0] } else null else null,
    };
}

fn facts(app: *const App, r: theme.Roles, row: sheets.Row, s: *Scratch) ?Facts {
    const given = app.board.?.plan().?;
    switch (row.kind) {
        .landed => {
            const id = row.ticket.?;
            const card = app.cardById(id);
            return .{
                .id = id,
                .state = "✓ landed",
                .lead = r.landed,
                .repo = if (card) |c| c.repo else null,
                .name = if (card) |c| c.name() else "",
                .wait_lead = r.dim,
                .age = sheets.ago(&s.age, if (card) |c| c.closed_at else null, app.epoch),
            };
        },
        .now => {
            const item = given.now[row.item];
            const stage = item.stage orelse item.state;
            const eql = std.mem.eql;
            const back = sentBack(app, item);
            const state: []const u8, const lead: color.RGB = if (back) |b|
                (if (b.fixing) .{ "↺ fixing", r.building } else .{ "↺ sent back", r.failed })
            else if (item.stalled != null)
                .{ "◇ stuck", r.failed }
            else if (eql(u8, stage, "queued"))
                .{ if (item.place) |n| std.fmt.bufPrint(&s.state, "» queued {s}", .{sheets.place(n, &s.place)}) catch "» queued" else "» queued", r.queued }
            else if (eql(u8, item.state, "landing"))
                .{ std.fmt.bufPrint(&s.state, "◒ {s}", .{stage}) catch stage, r.checking }
            else
                .{ std.fmt.bufPrint(&s.state, "◐ {s}", .{stage}) catch stage, r.building };
            return .{
                .id = item.ticket,
                .state = state,
                .lead = lead,
                .repo = item.repo,
                .name = item.name(),
                .wait = if (back) |b| if (b.waits) |on| on.say(&s.wait) else b.cause else if (item.waiting_on) |on| on.say(&s.wait) else "",
                .wait_lead = r.dim,
                .age = sheets.ago(&s.age, if (back) |b| b.at else item.since, app.epoch),
            };
        },
        .next => {
            const item = given.next[row.item];
            const word = win_next.nextLabel(item, &s.wait);
            const ready = item.held == null and tickets.Wait.first(item.waits_on) == null;
            return .{
                .id = item.ticket,
                .state = "· up next",
                .lead = r.dim,
                .repo = item.repo,
                .name = item.name(),
                .wait = word,
                .wait_lead = if (ready) r.landed else r.dim,
            };
        },
        else => return null,
    }
}

/// `text` in `room` cells, cut at a word with `…` when it does not fit.
fn cutWord(buf: []u8, text: []const u8, room: usize) []const u8 {
    if (cellCount(text) <= room) return text;
    const hard = text_mod.cut(buf, text, room);
    const body = if (std.mem.endsWith(u8, hard, "…")) hard[0 .. hard.len - "…".len] else hard;
    const at = std.mem.lastIndexOfScalar(u8, body, ' ') orelse return hard;
    if (at < 4) return hard;
    const kept = std.mem.trimEnd(u8, body[0..at], " ");
    const mark = std.fmt.bufPrint(buf[kept.len..], "…", .{}) catch return hard;
    return buf[0 .. kept.len + mark.len];
}

fn nameRoom(ww: usize) usize {
    return @max(8, @min(40, ww * 2 / 9));
}

pub fn paint(app: *App, w: *Writer, r: theme.Roles, sheet: *const sheets.Sheet, at: usize, y: u16, x0: usize, ww: usize, lit: bool) !void {
    const row = sheet.rows[at];
    const picked = lit and app.planRowLit(row);
    const mark = if (app.columnFocused()) r.dim else r.accent;
    const bg = if (picked) r.raised else r.panel;
    try bench.fill(w, x0, y, ww, bg);
    if (row.kind == .now_line) {
        try draw.repeat(w, x0 + 1, y, "─", ww -| 2, r.dim, bg);
        try bench.say(w, x0 + ww / 2 -| 2, y, " now ", r.dim, bg, false);
        return;
    }
    if (picked) try bench.say(w, x0, y, "▌", mark, bg, true);
    var scratch: Scratch = .{};
    const f = facts(app, r, row, &scratch) orelse return;
    try bench.say(w, x0 + state_x, y, f.state, f.lead, bg, false);
    const hue = repoHue(r, f.repo);
    var idb: [16]u8 = undefined;
    const id = std.fmt.bufPrint(&idb, "#{d}", .{f.id}) catch "";
    try bench.say(w, x0 + id_x, y, id, hue.hue, bg, true);
    const room = nameRoom(ww);
    var cut_buf: [256]u8 = undefined;
    try bench.say(w, x0 + name_x, y, cutWord(&cut_buf, f.name, room), if (row.dim) r.dim else r.text, bg, false);
    const end = x0 + ww -| 1;
    const repo_x = x0 + name_x + room + 1;
    var rb: [32]u8 = undefined;
    if (repo_x + repo_w <= end) {
        try bench.say(w, repo_x, y, text_mod.cut(&rb, f.repo orelse "", repo_w - 1), hue.hue, bg, false);
        if (inDrivenGoal(app.board.?.plan().?, f.id)) try bench.say(w, repo_x + repo_w, y, "◆", r.accent, bg, false);
    }
    const age_x = end -| (cellCount(f.age) + 1);
    if (f.age.len > 0 and age_x > repo_x + repo_w) try bench.say(w, age_x, y, f.age, r.dim, bg, false);
    const wait_x = repo_x + repo_w + 3;
    if (f.wait.len > 0 and wait_x + cellCount(f.wait) < (if (f.age.len > 0) age_x else end)) try bench.say(w, wait_x, y, f.wait, f.wait_lead, bg, false);
}

/// The window's title bar's tally, as `3 landed today · 5 moving · 3 next`, drawn after its name.
pub fn tally(app: *const App, w: *Writer, r: theme.Roles, sheet: *const sheets.Sheet, x: u16, y: u16, ww: usize) !void {
    const mine = sheet.span(.board);
    var landed: usize = 0;
    var moving: usize = 0;
    var next: usize = 0;
    for (sheet.rows[mine.start..][0..mine.len]) |row| switch (row.kind) {
        .landed => landed += 1,
        .now => moving += 1,
        .next => next += 1,
        else => {},
    };
    const whole = app.planScope().len == 0 and app.findText().len == 0;
    if (whole) landed = app.board.?.plan().?.landed_today.count;
    var buf: [96]u8 = undefined;
    const text = std.fmt.bufPrint(&buf, " │ {d} landed today · {d} moving · {d} next ", .{ landed, moving, next }) catch return;
    const from = x + 3 + 2 + cellCount("board");
    if (from + cellCount(text) + 1 > x + ww) return;
    try bench.say(w, from, y, text, r.dim, r.panel, false);
}

fn claudeLine(app: *const App, lines: *sheets.Lines, item: tickets.NowItem) []const u8 {
    const held = item.holder() orelse return "";
    const at = app.paneWindow(held) orelse return "";
    const win = at.session.wins.items[at.index];
    const word: []const u8 = switch (win.claude) {
        .working, .background => "working",
        .waiting => "waiting on you",
        .stalled => "stopped",
        .done => "done",
        .none => "idle",
    };
    return lines.print("{s} · {s}:{d}", .{ word, at.session.name, win.index });
}

/// The block under an opened board row, in a window `ww` cells wide: the title whole, its goal,
/// why, what it waits on, its stage and Claude, and its checks.
pub fn detail(app: *const App, row: sheets.Row, ww: usize, lines: *sheets.Lines) void {
    const given = app.board.?.plan().?;
    const indent: u8 = id_x;
    switch (row.kind) {
        .now => {
            const item = given.now[row.item];
            var age: [16]u8 = undefined;
            const since = sheets.ago(&age, item.since, app.epoch);
            const stage = if (sentBack(app, item)) |b| blk: {
                var back_age: [16]u8 = undefined;
                const when = sheets.ago(&back_age, b.at, app.epoch);
                const ago_word = if (when.len == 0 or std.mem.eql(u8, when, "now")) "" else " ago";
                break :blk lines.print("sent back{s}{s}{s}{s}{s}", .{ if (when.len > 0) " " else "", when, ago_word, if (b.cause.len > 0) " · " else "", b.cause });
            } else lines.print("{s}{s}{s}", .{ item.stage orelse item.state, if (since.len > 0) " · " else "", since });
            var said: [64]u8 = undefined;
            const wait = if (item.stalled) |why| lines.print("stalled · {s}", .{why}) else if (item.waiting_on) |on| lines.print("{s}", .{on.say(&said)}) else "";
            win_detail.fill(app, lines, .{ .ticket = item.ticket, .title = item.name(), .wait = wait, .stage = stage, .claude = claudeLine(app, lines, item) }, ww, indent);
        },
        .next => win_next.detail(app, row, ww, lines),
        .landed => {
            const id = row.ticket orelse return;
            const card = app.cardById(id);
            var age: [16]u8 = undefined;
            const closed = sheets.ago(&age, if (card) |c| c.closed_at else null, app.epoch);
            const stage = lines.print("landed{s}{s}", .{ if (closed.len > 0) " · " else "", closed });
            win_detail.fill(app, lines, .{ .ticket = id, .title = if (card) |c| c.name() else "", .stage = stage }, ww, indent);
        },
        else => {},
    }
}

/// Enter on a landed or pipeline row: its card. On a building or stuck row it goes to the Claude
/// on it; a stuck one with no Claude starts one. An up next row is started by next's own `act`.
pub fn act(app: *App, row: *const sheets.Row) !void {
    const id = row.ticket orelse return;
    if (row.kind == .landed) {
        _ = try app.openDetail(id);
        return;
    }
    const given = app.board.?.plan().?;
    const item = for (given.now) |item| {
        if (item.ticket == id) break item;
    } else return;
    const pane = if (item.holder()) |held| (if (app.paneWindow(held) != null) held else null) else null;
    const building = std.mem.eql(u8, item.state, "building");
    if (pane) |held| if (building or item.stalled != null) return app.openClaude(held);
    if (item.stalled != null) return app.send(.ignore, app_mod.captured("babylon start {d}"), .{id});
    if (!building) _ = try app.openDetail(id);
}

test "the board's rows say their state, a ◆ for the driven goal's step, and one wait word each" {
    var board = try tickets.Board.parse(std.testing.allocator,
        \\{"tickets":[{"id":1,"repo":"arena","title":"one","status":"done"},{"id":2,"repo":"arena","title":"two","status":"done"}],
        \\"plan":{"driving":10,
        \\"now":[
        \\{"ticket":3,"repo":"arena","title":"r","state":"landing","stage":"reviewing"},
        \\{"ticket":4,"repo":"arena","title":"d","state":"building"}],
        \\"next":[{"ticket":5,"repo":"arena","title":"e","held":{"why":"repo cap","by":3}},{"ticket":6,"repo":"menard","title":"f"}],
        \\"goals":[{"epic":10,"title":"g","total":1,"landed":0,"steps":[{"ticket":4,"state":"building"}]}],
        \\"landed_today":{"count":2,"newest":[1,2]}}}
    );
    defer board.deinit();
    var app: App = .{ .gpa = std.testing.allocator, .io = undefined, .tmux_in = undefined };
    app.board = board;
    const r = bench.roles();
    const given = app.board.?.plan().?;
    var s: Scratch = .{};
    const eq = std.testing.expectEqualStrings;
    try eq("◒ reviewing", facts(&app, r, .{ .kind = .now, .item = 0, .ticket = 3 }, &s).?.state);
    try eq("◐ building", facts(&app, r, .{ .kind = .now, .item = 1, .ticket = 4 }, &s).?.state);
    try eq("· up next", facts(&app, r, .{ .kind = .next, .item = 0, .ticket = 5 }, &s).?.state);
    try eq("after #3", facts(&app, r, .{ .kind = .next, .item = 0, .ticket = 5 }, &s).?.wait);
    try eq("ready", facts(&app, r, .{ .kind = .next, .item = 1, .ticket = 6 }, &s).?.wait);
    try std.testing.expect(inDrivenGoal(given, 4));
    try std.testing.expect(!inDrivenGoal(given, 3));
}

test "a sent-back ticket reads ↺ fixing while its Claude works, and ↺ sent back with its cause when none does" {
    var board = try tickets.Board.parse(std.testing.allocator,
        \\{"tickets":[
        \\{"id":1,"repo":"arena","title":"a","status":"doing","stage":"failed","stage_note":"the review asked for changes.\nfix it","stage_at":"2026-11-27T10:00:00Z"},
        \\{"id":2,"repo":"arena","title":"b","status":"doing","stage":"failed","stage_note":"the gate is red (exit 1); its whole output is in /x","stage_at":"2026-11-27T10:00:00Z"},
        \\{"id":3,"repo":"arena","title":"c","status":"todo","stage":"failed","stage_note":"it does not rebase onto main cleanly; conflicts in: a","stage_at":"2026-11-27T10:00:00Z"},
        \\{"id":4,"repo":"arena","title":"d","status":"doing","stage":"failed","stage_note":"the gate is red (exit 1)","blocked_by":[1370]},
        \\{"id":5,"repo":"arena","title":"e","status":"doing","stage":"failed","stage_note":"the gate is red (exit 1)"}],
        \\"plan":{"now":[
        \\{"ticket":1,"repo":"arena","title":"a","state":"building","stage":"failed","pane":"%11","since":"2026-11-27T09:00:00Z"},
        \\{"ticket":2,"repo":"arena","title":"b","state":"building","stage":"failed","pane":"%12","since":"2026-11-27T09:00:00Z"},
        \\{"ticket":3,"repo":"arena","title":"c","state":"building","stage":"failed","since":"2026-11-27T09:00:00Z"},
        \\{"ticket":4,"repo":"arena","title":"d","state":"building","stage":"failed"},
        \\{"ticket":5,"repo":"arena","title":"e","state":"building","stage":"failed","waiting_on":{"for":"the flaky test's fix"}}],
        \\"next":[],"goals":[],"landed_today":{"count":0,"newest":[]}}}
    );
    defer board.deinit();
    var app: App = .{ .gpa = std.testing.allocator, .io = undefined, .tmux_in = undefined };
    app.board = board;
    const busy = try app_mod.Pane.create(&app, 11, 80, 24);
    defer busy.destroy(std.testing.allocator);
    const quiet = try app_mod.Pane.create(&app, 12, 80, 24);
    defer quiet.destroy(std.testing.allocator);
    var working: app_mod.Window = .{ .id = 1, .name = @constCast("w"), .claude = .working };
    defer working.panes.deinit(std.testing.allocator);
    try working.panes.append(std.testing.allocator, busy);
    var idle: app_mod.Window = .{ .id = 2, .name = @constCast("i"), .claude = .none };
    defer idle.panes.deinit(std.testing.allocator);
    try idle.panes.append(std.testing.allocator, quiet);
    var s: app_mod.Session = .{ .id = 1, .name = @constCast("s") };
    var wins = [_]*app_mod.Window{ &working, &idle };
    s.wins = .fromOwnedSlice(&wins);
    var sessions = [_]*app_mod.Session{&s};
    app.sessions = .fromOwnedSlice(&sessions);
    const r = bench.roles();
    var sc: Scratch = .{};
    const eq = std.testing.expectEqualStrings;
    const fixing = facts(&app, r, .{ .kind = .now, .item = 0, .ticket = 1 }, &sc).?;
    try eq("↺ fixing", fixing.state);
    try eq("review asked", fixing.wait);
    try std.testing.expectEqual(r.building, fixing.lead);
    const waiting = facts(&app, r, .{ .kind = .now, .item = 1, .ticket = 2 }, &sc).?;
    try eq("↺ sent back", waiting.state);
    try eq("gate red", waiting.wait);
    try std.testing.expectEqual(r.failed, waiting.lead);
    const nobody = facts(&app, r, .{ .kind = .now, .item = 2, .ticket = 3 }, &sc).?;
    try eq("↺ sent back", nobody.state);
    try eq("rebase conflict", nobody.wait);
    try eq("◷ waiting on #1370", facts(&app, r, .{ .kind = .now, .item = 3, .ticket = 4 }, &sc).?.wait);
    try eq("◷ waiting for the flaky test's fix", facts(&app, r, .{ .kind = .now, .item = 4, .ticket = 5 }, &sc).?.wait);
    const given = app.board.?.plan().?;
    try std.testing.expect(!sentBack(&app, given.now[0]).?.idle);
    try std.testing.expect(sentBack(&app, given.now[1]).?.idle);
    try std.testing.expect(!sentBack(&app, given.now[2]).?.idle);
}
