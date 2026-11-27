//! Home's plan: babylon's `plan` laid out as rows to draw, and the pick over the rows that can be
//! picked. Everything shown is what babylon gave; the only thing worked out here is how it folds.
const std = @import("std");
const tickets = @import("board.zig");
const text_mod = @import("text.zig");

pub const max_rows = 320;

/// The pipeline's stages in the order in flight lists them; queued goes by place.
const stages = [_][]const u8{ "landing", "reviewing", "verifying", "queued" };
/// The tickets of next that are drawn; the rest are `+N`.
const next_shown = 7;
/// Rows kept past the goals for the foot: a gap, not planned's head and row, a gap, landed.
const foot_rows = 5;
/// Rows kept past the goals for the ideas: a gap, their rule, and three rows or the fold.
const idea_rows = 5;
/// Ideas shown a row each; past it they fold to one row.
const ideas_shown = 3;
/// The bit of `unfolded` that holds the ideas open.
pub const ideas_fold: u3 = 0;

pub const Kind = enum { head, blank, other, need, now, next, why, more, goals_more, goal, goal_ticket, landed, unplanned, chips, todo, backlog, focal, drove, idea, ideas_more, note, buttons, detail };
pub const Style = enum { normal, dim, heading, attention };

/// The plan is two screens: Doing, what needs the human and what is moving, and Planning, where
/// tickets are arranged.
pub const Screen = enum { doing, planning };

/// Workbench's plan is windows, each a fixed slot of the screen it is on.
pub const Window = enum {
    move,
    driving,
    now,
    next,
    goals,
    no_goal,
    backlog,
    landed,

    pub fn title(win: Window) []const u8 {
        return switch (win) {
            .move => "your move",
            .driving => "driving towards",
            .now => "in flight",
            .no_goal => "no goal",
            else => @tagName(win),
        };
    }

    /// Whether `win` is drawn on `screen`: next is on both.
    pub fn on(win: Window, screen: Screen) bool {
        return switch (win) {
            .move, .driving, .now, .landed => screen == .doing,
            .goals, .no_goal, .backlog => screen == .planning,
            .next => true,
        };
    }
};

/// The most detail lines an opened row holds.
pub const max_detail = 24;

/// A line of an opened row's block: its text, where its label ends (the label is drawn dim) and
/// how many cells in it starts.
pub const Line = struct { text: []const u8 = "", label: usize = 0, indent: u8 = 0 };

/// The detail lines of one opened row, which a window's `detail` fills.
pub const Lines = struct {
    items: [max_detail]Line = undefined,
    n: usize = 0,
    buf: [2048]u8 = undefined,
    used: usize = 0,

    pub fn add(l: *Lines, line: Line) void {
        if (l.n == l.items.len) return;
        l.items[l.n] = line;
        l.n += 1;
    }

    /// `fmt` printed into the lines' own space.
    pub fn print(l: *Lines, comptime fmt: []const u8, args: anytype) []const u8 {
        const out = std.fmt.bufPrint(l.buf[l.used..], fmt, args) catch return "";
        const start = l.used;
        l.used += out.len;
        return l.buf[start..l.used];
    }

    /// `text` broken at words into lines of `room` cells, each `indent` cells in.
    pub fn wrap(l: *Lines, text: []const u8, room: usize, indent: u8) void {
        var rest = text;
        while (rest.len > 0) {
            const part = text_mod.breakLine(rest, room);
            l.add(.{ .text = part.line, .indent = indent });
            rest = part.rest;
        }
    }

    /// `label` then the value `fmt` prints, the values lined up.
    pub fn field(l: *Lines, indent: u8, label: []const u8, comptime fmt: []const u8, args: anytype) void {
        l.add(.{ .text = l.print("{s: <9}" ++ fmt, .{label} ++ args), .label = 9, .indent = indent });
    }
};

pub const Rect = struct { x: u16, y: u16, w: u16, h: u16 };

/// Rows of a window's slot that are not its body: the title bar, and the shadow's row.
pub const window_chrome = 2;
/// Driving towards is one row: a title bar with no body.
const driving_h = 1;
/// The blank rows between two windows of a column; it comes out of the lower window's height.
pub const gap = 1;

/// Under this many rows the windows above the lists keep one body row each, so not planned and
/// the rest keep rows of theirs.
const short_area = 26;

/// Rows Your move's slot shows at full width: whatever it holds, its slot is this tall.
pub const move_rows_full = 5;

/// Where `win` sits on a plan area `w` by `h` cells of `screen`: its top border, body and bottom
/// border; nothing for a window the screen does not have. Worked out from the area alone, so
/// nothing in a window or its fold moves another; in one column (`stack`) from the area and the
/// rows each window holds.
pub fn slot(win: Window, screen: Screen, w: u16, h: u16, stack: bool, rows: Rows) Rect {
    if (!win.on(screen)) return .{ .x = 0, .y = 0, .w = 0, .h = 0 };
    if (stack) return stacked(win, screen, w, h, rows);
    if (screen == .planning) {
        const left = w * 3 / 5;
        return switch (win) {
            .goals => .{ .x = 0, .y = 0, .w = left, .h = h * 6 / 10 },
            .no_goal => .{ .x = 0, .y = h * 6 / 10 + gap, .w = left, .h = h -| (h * 6 / 10 + gap) },
            .next => .{ .x = left, .y = 0, .w = w - left, .h = h * 4 / 10 },
            else => .{ .x = left, .y = h * 4 / 10 + gap, .w = w - left, .h = h -| (h * 4 / 10 + gap) },
        };
    }
    const move_rows = move_rows_full;
    // on a short screen Your move gives rows to the windows under it, down to one
    const shown: u16 = if (h < short_area) @as(u16, 1) else move_rows;
    const move_h = @min(shown + window_chrome, h);
    const drive_y = @min(move_h + gap, h);
    const drive_h = @min(@as(u16, driving_h), h - drive_y);
    const top = @min(drive_y + drive_h + gap, h);
    const rest = h - top;
    const half = w * 3 / 5;
    const now_h = rest * 6 / 10;
    return switch (win) {
        .move => .{ .x = 0, .y = 0, .w = w, .h = move_h },
        .driving => .{ .x = 0, .y = drive_y, .w = w, .h = drive_h },
        .now => .{ .x = 0, .y = top, .w = half, .h = now_h },
        .next => .{ .x = 0, .y = top + now_h + gap, .w = half, .h = rest -| (now_h + gap) },
        else => .{ .x = half, .y = top, .w = w - half, .h = rest },
    };
}

/// The rows each window holds, counted before a pick adds any.
pub const Rows = std.EnumArray(Window, usize);

/// The most body rows a window of the one column takes of its own rows.
fn stackedCap(win: Window) usize {
    return switch (win) {
        .move => 5,
        .now => 6,
        .next => 7,
        .no_goal => 4,
        .landed => 5,
        .goals => 8,
        .backlog => 5,
        .driving => 0,
    };
}

/// The windows of the one column, top to bottom.
fn stackOrder(screen: Screen) []const Window {
    return switch (screen) {
        .doing => &.{ .move, .driving, .now, .next, .landed },
        .planning => &.{ .goals, .next, .no_goal, .backlog },
    };
}

/// One column, top to bottom: on Doing your move, driving towards, in flight, next and landed; on
/// Planning goals, next, no goal and backlog. Each window is as tall as its rows, up to its cap;
/// spare height goes to the windows whose rows don't fit, in that order, and what is left lies
/// under the last window. Too little height takes from the last windows first, down to one body
/// row.
fn stacked(win: Window, screen: Screen, w: u16, h: u16, rows: Rows) Rect {
    const order = stackOrder(screen);
    var heights: [8]usize = undefined;
    var total: usize = gap * (order.len - 1);
    for (order, 0..) |each, i| {
        heights[i] = if (each == .driving) driving_h else window_chrome + @max(1, @min(rows.get(each), stackedCap(each)));
        total += heights[i];
    }
    var at = order.len;
    while (total > h and at > 0) {
        at -= 1;
        if (order[at] == .driving) continue;
        const cut = @min(total - h, heights[at] - (window_chrome + 1));
        heights[at] -= cut;
        total -= cut;
    }
    for (order, 0..) |each, i| {
        if (total >= h) break;
        if (each == .driving) continue;
        const room = window_chrome + rows.get(each) -| heights[i];
        const give = @min(room, h - total);
        heights[i] += give;
        total += give;
    }
    var y: usize = 0;
    for (order, 0..) |each, i| {
        const top = @min(y, h);
        const rows_h = @min(heights[i], h - top);
        if (each == win) return .{ .x = 0, .y = @intCast(top), .w = w, .h = @intCast(rows_h) };
        y += heights[i] + gap;
    }
    unreachable;
}

test "in one column each window is as tall as its rows up to its cap, and what is left lies under the last" {
    const eq = std.testing.expectEqual;
    var rows = Rows.initFill(1);
    rows.set(.now, 1);
    try eq(@as(u16, window_chrome + 1), slot(.now, .doing, 103, 50, true, rows).h);
    rows.set(.now, 30);
    rows.set(.move, 2);
    try eq(@as(u16, window_chrome + 2), slot(.move, .doing, 103, 50, true, rows).h);
    var y: u16 = 0;
    for (stackOrder(.doing)) |win| {
        const at = slot(win, .doing, 103, 50, true, rows);
        try eq(y, at.y);
        y += at.h + gap;
    }
    try std.testing.expect(y - gap <= 50);
    var spare = Rows.initFill(1);
    spare.set(.now, 40);
    spare.set(.next, 40);
    try std.testing.expect(slot(.now, .doing, 103, 50, true, spare).h > window_chrome + 6);
    try eq(@as(u16, window_chrome + 7), slot(.next, .doing, 103, 50, true, spare).h);
}

test "each window of a column starts one blank row below the one above, at both widths on both screens" {
    const sizes = [_][2]u16{ .{ 220, 51 }, .{ 110, 51 } };
    for ([_]Screen{ .doing, .planning }) |screen| {
        for (sizes) |size| {
            for ([_]bool{ false, true }) |stack| {
                const rows = Rows.initFill(30);
                for (std.enums.values(Window)) |win| {
                    const a = slot(win, screen, size[0], size[1], stack, rows);
                    if (a.h == 0) continue;
                    var below: ?Rect = null;
                    for (std.enums.values(Window)) |other| {
                        const b = slot(other, screen, size[0], size[1], stack, rows);
                        if (b.h == 0 or b.x != a.x or b.y <= a.y) continue;
                        if (below == null or b.y < below.?.y) below = b;
                    }
                    if (below) |b| try std.testing.expectEqual(a.y + a.h + gap, b.y);
                    // a window is drawn one cell narrower than its rect, so side by side a column is blank
                    for (std.enums.values(Window)) |other| {
                        const b = slot(other, screen, size[0], size[1], stack, rows);
                        if (b.h == 0 or b.x <= a.x or b.y >= a.y + a.h or a.y >= b.y + b.h) continue;
                        try std.testing.expect(a.x + a.w - 1 < b.x);
                    }
                }
            }
        }
    }
}

test "each screen has its own windows, and next is on both" {
    const eq = std.testing.expectEqual;
    for (std.enums.values(Window)) |win| {
        const on_doing = win.on(.doing);
        const on_planning = win.on(.planning);
        try eq(win == .next, on_doing and on_planning);
        try eq(on_doing, slot(win, .doing, 220, 49, false, Rows.initFill(0)).h > 0);
        try eq(on_planning, slot(win, .planning, 220, 49, false, Rows.initFill(0)).h > 0);
    }
    const goals = slot(.goals, .planning, 220, 49, false, Rows.initFill(0));
    const no_goal = slot(.no_goal, .planning, 220, 49, false, Rows.initFill(0));
    try eq(goals.y + goals.h + gap, no_goal.y);
    try eq(@as(u16, 49), no_goal.y + no_goal.h);
    const landed = slot(.landed, .doing, 220, 49, false, Rows.initFill(0));
    try eq(@as(u16, 220 * 3 / 5), landed.x);
    try eq(@as(u16, 49), landed.y + landed.h);
}

/// The first of `len` rows a window of `body` rows shows, the row at `at` kept in view with the
/// `card` rows of its card below it; a body too short for both keeps the row itself.
pub fn windowTop(at: usize, len: usize, body: usize, card: usize) usize {
    return @min((at + 1 + card) -| body, at, len -| body);
}

test "windowTop keeps the picked row in view, with its card below it when the body has room" {
    try std.testing.expectEqual(@as(usize, 0), windowTop(0, 10, 5, 2));
    try std.testing.expectEqual(@as(usize, 3), windowTop(5, 10, 5, 2));
    try std.testing.expectEqual(@as(usize, 5), windowTop(5, 10, 1, 2));
    try std.testing.expectEqual(@as(usize, 5), windowTop(5, 10, 2, 2));
    try std.testing.expectEqual(@as(usize, 4), windowTop(9, 10, 6, 2));
    try std.testing.expectEqual(@as(usize, 2), windowTop(2, 10, 5, 4));
}

pub const Row = struct {
    kind: Kind,
    /// Its place among the rows that can be picked; none for a heading, a why line or a gap.
    pick: ?usize = null,
    ticket: ?u32 = null,
    /// Of a row that unfolds more: which bit of `unfolded` it is.
    fold: ?u3 = null,
    style: Style = .normal,
    text: []const u8 = "",
    /// Where `text`'s tail begins, drawn in `tail_style`: the state of a now row, what a next
    /// item waits on.
    tail_at: usize = std.math.maxInt(usize),
    tail_style: Style = .dim,
    /// Workbench's rows are drawn from the plan itself: the index of the item among its list
    /// (now, next or goals), which of a focal window's rows this is, and a head's count.
    item: usize = 0,
    part: u8 = 0,
    count: usize = 0,
    /// Workbench's window the row is in.
    win: Window = .now,
    /// A row `narrow` left in place but that does not hold what is found: drawn dim, never picked.
    dim: bool = false,
};

/// The goal Home puts in the focal window: the one the human picked to drive towards; with no
/// pick, the first with a step being built, else the first not yet landed whole.
pub fn focalGoal(given: *const tickets.Plan) ?usize {
    const goals = given.goals;
    if (given.driving) |epic| for (goals, 0..) |goal, i| {
        if (goal.epic == epic) return i;
    };
    for (goals, 0..) |goal, i| for (goal.steps) |step| {
        if (std.mem.eql(u8, step.state, "building")) return i;
    };
    for (goals, 0..) |goal, i| if (goal.landed < goal.total) return i;
    return null;
}

/// The Your move item asking for the next goal, when the goal driven towards has landed: it is
/// driving, no longer among the open goals, and babylon asks.
pub fn driveLanded(given: *const tickets.Plan, b: *const tickets.Board) ?*const tickets.Need {
    const epic = given.driving orelse return null;
    for (given.goals) |goal| if (goal.epic == epic) return null;
    return b.driveNeed();
}

fn drivenTitle(b: *const tickets.Board, need: *const tickets.Need, epic: u32) []const u8 {
    for (b.cards()) |card| if (card.id == epic) return card.title;
    return need.text;
}

/// Whether a step is moving, next, or sent back, as opposed to landed or still waiting.
pub fn inFlight(step: tickets.Step) bool {
    const mark = Sheet.stepMark(step.state);
    return !std.mem.eql(u8, mark, "✓") and !std.mem.eql(u8, mark, "○");
}

/// How many of a goal's steps have landed and wait on the human to try.
pub fn goalTrying(goal: tickets.Goal) usize {
    var n: usize = 0;
    for (goal.steps) |step| n += @intFromBool(std.mem.eql(u8, step.state, "to_try"));
    return n;
}

/// The place from 1 of ticket `id` in next, none when it is not in it.
pub fn nextPlace(given: *const tickets.Plan, id: u32) ?usize {
    for (given.next, 1..) |item, place_n| if (item.ticket == id) return place_n;
    return null;
}

/// What the plan shows: the screen, the repos folded to their chips in no goal, and the goals
/// whose tickets are folded away.
pub const See = struct {
    screen: Screen = .doing,
    repos_shut: []const []const u8 = &.{},
    goals_shut: []const u32 = &.{},
};

pub const max_chips = 16;

/// A chip of no goal's top row: a repo's with its count of todo tickets.
pub const Chip = struct { x: usize, w: usize, repo: []const u8, n: usize };

/// The chips of no goal's top row, from `x0`, as many as fit in `width` cells.
pub fn chipsAt(given: *const tickets.Plan, x0: usize, width: usize, out: []Chip) []Chip {
    var n: usize = 0;
    var x = x0;
    const not = given.not_planned;
    for (not.by_repo.map.keys(), not.by_repo.map.values()) |name, count| {
        const w = chipWidth(name, count);
        if (n == out.len or x + w > x0 + width) break;
        out[n] = .{ .x = x, .w = w, .repo = name, .n = count };
        n += 1;
        x += w + 1;
    }
    return out[0..n];
}

/// A chip's cells: its icon and name and count, and the chip's own two.
fn chipWidth(name: []const u8, count: usize) usize {
    var digits: [12]u8 = undefined;
    const n = std.fmt.bufPrint(&digits, "{d}", .{count}) catch "";
    return 2 + text_mod.cells(name) + 1 + n.len + 2;
}

pub const Sheet = struct {
    rows: [max_rows]Row = undefined,
    n: usize = 0,
    picks: usize = 0,
    /// Half a screen's plan: the pipeline folded to counts, next without its whys, goals without names.
    narrow: bool = false,
    /// Workbench's rows: a goal a card of rows, and the focal window first.
    bench: bool = false,
    buf: [32 * 1024]u8 = undefined,
    used: usize = 0,
    /// The window rows are being added to.
    cur: Window = .driving,
    from: usize = 0,

    /// The rows of `win`: where they start and how many.
    pub fn span(s: *const Sheet, win: Window) struct { start: usize, len: usize } {
        var start: usize = s.n;
        var len: usize = 0;
        for (s.rows[0..s.n], 0..) |row, i| if (row.win == win) {
            if (len == 0) start = i;
            len += 1;
        };
        return .{ .start = start, .len = len };
    }

    /// The picked ticket row opens in place: under it the detail lines `ctx.detail` gives for it,
    /// then a row of the card's keys as the block's last row. `ctx.opens` says which rows open. It
    /// is no pick, so the picks stay where they were.
    pub fn withOpen(s: *Sheet, ctx: anytype) void {
        var i: usize = 0;
        while (i < s.n) : (i += 1) {
            const owner = s.rows[i];
            if (owner.pick == null or owner.ticket == null or !ctx.opens(owner)) continue;
            var lines: Lines = .{};
            ctx.detail(owner, &lines);
            const extra = lines.n + 1;
            if (s.n + extra > max_rows) return;
            std.mem.copyBackwards(Row, s.rows[i + 1 + extra .. s.n + extra], s.rows[i + 1 .. s.n]);
            for (lines.items[0..lines.n], i + 1..) |line, at| {
                s.rows[at] = .{ .kind = .detail, .ticket = owner.ticket, .item = owner.item, .win = owner.win, .text = s.print("{s}", .{line.text}), .tail_at = line.label, .part = line.indent };
            }
            s.rows[i + extra] = .{ .kind = .buttons, .ticket = owner.ticket, .win = owner.win };
            s.n += extra;
            i += extra;
        }
    }

    /// A rule `other Claudes N` and a pick for each of the `n` Claudes with no ticket, at the foot
    /// of in flight's rows, where its `none` stood. `item` of a row is its place among them. A
    /// Claude holds no title, so a `find` leaves its row dim and out of the picks.
    pub fn withOthers(s: *Sheet, n: usize, find: []const u8) void {
        if (n == 0 or !s.bench) return;
        var foot: usize = 0;
        for (s.rows[0..s.n], 0..) |row, i| {
            if (row.win == .now) foot = i + 1;
        }
        const placeholder = foot > 0 and s.rows[foot - 1].kind == .note and s.rows[foot - 1].win == .now;
        if (placeholder) foot -= 1;
        const dropped = @intFromBool(placeholder);
        if (s.n + 1 + n - dropped > max_rows) return;
        var rows: [max_rows]Row = undefined;
        @memcpy(rows[0..foot], s.rows[0..foot]);
        rows[foot] = .{ .kind = .head, .text = "other Claudes", .count = n, .win = .now };
        const found = find.len > 0;
        for (0..n) |i| rows[foot + 1 + i] = .{ .kind = .other, .pick = if (found) null else 0, .dim = found, .item = i, .win = .now };
        const rest = s.rows[foot + dropped .. s.n];
        @memcpy(rows[foot + 1 + n ..][0..rest.len], rest);
        s.n = foot + 1 + n + rest.len;
        @memcpy(s.rows[0..s.n], rows[0..s.n]);
        s.picks = 0;
        for (s.rows[0..s.n]) |*row| if (row.pick != null) {
            row.pick = s.picks;
            s.picks += 1;
        };
    }

    /// Workbench's rows narrowed to the repo `repo` (none for every one) and to what `find` holds.
    /// Another repo's rows are left out of their windows; a row that does not hold `find` stays,
    /// dim and out of the picks, so nothing moves. A window left with no row says so.
    pub fn narrowTo(s: *Sheet, given: *const tickets.Plan, b: *const tickets.Board, repo: []const u8, find: []const u8) void {
        if (!s.bench or (repo.len == 0 and find.len == 0)) return;
        var rows: [max_rows]Row = undefined;
        var n: usize = 0;
        var in_win: ?Window = null;
        var had: bool = false;
        var kept_in_win: bool = false;
        var last: Verdict = .keep;
        for (s.rows[0..s.n]) |row| {
            if (in_win != row.win) {
                if (in_win) |win| if (had and !kept_in_win and n < rows.len) {
                    rows[n] = .{ .kind = .note, .style = .dim, .text = "no match", .win = win };
                    n += 1;
                };
                in_win = row.win;
                had = false;
                kept_in_win = false;
            }
            had = true;
            const verdict: Verdict = if (row.kind == .why) last else s.verdictOf(given, b, row, repo, find);
            last = verdict;
            if (verdict == .hide or n == rows.len) continue;
            rows[n] = row;
            if (verdict == .dim) {
                rows[n].dim = true;
                rows[n].pick = null;
            }
            kept_in_win = true;
            n += 1;
        }
        if (in_win) |win| if (had and !kept_in_win and n < rows.len) {
            rows[n] = .{ .kind = .note, .style = .dim, .text = "no match", .win = win };
            n += 1;
        };
        s.picks = 0;
        for (rows[0..n]) |*row| if (row.pick != null) {
            row.pick = s.picks;
            s.picks += 1;
        };
        @memcpy(s.rows[0..n], rows[0..n]);
        s.n = n;
    }

    const Verdict = enum { keep, dim, hide };

    fn verdictOf(s: *const Sheet, given: *const tickets.Plan, b: *const tickets.Board, row: Row, repo: []const u8, find: []const u8) Verdict {
        _ = s;
        const id, const title, const repo_of, const in_repo = switch (row.kind) {
            .now => .{ given.now[row.item].ticket, given.now[row.item].title, given.now[row.item].repo orelse "", std.mem.eql(u8, given.now[row.item].repo orelse "", repo) },
            .next => .{ given.next[row.item].ticket, given.next[row.item].title, given.next[row.item].repo orelse "", std.mem.eql(u8, given.next[row.item].repo orelse "", repo) },
            .goal => .{ given.goals[row.item].epic, given.goals[row.item].title, "", goalIn(b, given.goals[row.item], repo) },
            .goal_ticket => blk: {
                const card = for (b.cards()) |*card| {
                    if (card.id == row.ticket.?) break card;
                } else return .keep;
                break :blk .{ card.id, card.title, card.repo orelse "", std.mem.eql(u8, card.repo orelse "", repo) };
            },
            .idea => .{ given.ideas[row.item].epic, given.ideas[row.item].title, "", true },
            else => return .keep,
        };
        if (repo.len > 0 and !in_repo) return .hide;
        return if (tickets.holds(find, id, title, repo_of)) .keep else .dim;
    }

    /// Whether a step of `goal` is a ticket of `repo`.
    fn goalIn(b: *const tickets.Board, goal: tickets.Goal, repo: []const u8) bool {
        if (repo.len == 0) return true;
        for (goal.steps) |step| for (b.cards()) |card| {
            if (card.id == step.ticket and std.mem.eql(u8, card.repo orelse "", repo)) return true;
        };
        return false;
    }

    /// The picks of `win`: the first and how many.
    pub fn pickRange(s: *const Sheet, win: Window) ?struct { first: usize, n: usize } {
        var first: ?usize = null;
        var n: usize = 0;
        for (s.rows[0..s.n]) |row| if (row.win == win) if (row.pick) |p| {
            if (first == null) first = p;
            n += 1;
        };
        return if (first) |f| .{ .first = f, .n = n } else null;
    }

    /// The row picked as `pick`.
    pub fn picked(s: *const Sheet, pick: usize) ?*const Row {
        for (s.rows[0..s.n]) |*row| if (row.pick == pick) return row;
        return null;
    }

    /// The index of the row picked as `pick`.
    pub fn rowOf(s: *const Sheet, pick: usize) ?usize {
        for (s.rows[0..s.n], 0..) |row, i| if (row.pick == pick) return i;
        return null;
    }

    fn add(s: *Sheet, row: Row) void {
        if (s.n == s.rows.len) return;
        var r = row;
        r.win = s.cur;
        if (r.pick != null) {
            r.pick = s.picks;
            s.picks += 1;
        }
        s.rows[s.n] = r;
        s.n += 1;
    }

    fn print(s: *Sheet, comptime fmt: []const u8, args: anytype) []const u8 {
        const out = std.fmt.bufPrint(s.buf[s.used..], fmt, args) catch return "";
        const start = s.used;
        s.used += out.len;
        return s.buf[start..s.used];
    }

    /// `left` and `right` on a row `width` cells wide, `right` against the edge; `left`, cut to
    /// make room when it must be, ends in `…`.
    fn spread(s: *Sheet, width: usize, left: []const u8, right: []const u8) struct { text: []const u8, tail_at: usize } {
        const right_w = text_mod.cells(right);
        const room = width -| right_w -| 1;
        var buf: [256]u8 = undefined;
        const shown = text_mod.cut(&buf, left, room);
        const pad = width -| text_mod.cells(shown) -| right_w;
        const text = s.print("{s}{s}{s}", .{ shown, spaces(pad), right });
        return .{ .text = text, .tail_at = shown.len + pad };
    }

    fn clipped(s: *Sheet, width: usize, line: []const u8) []const u8 {
        if (text_mod.cells(line) <= width) return line;
        var buf: [256]u8 = undefined;
        return s.print("{s}", .{text_mod.cut(&buf, line, width)});
    }

    /// The plan as rows `width` cells wide, `epoch` the time now, the stages in `unfolded` shown
    /// a row to a ticket.
    pub fn build(s: *Sheet, given: *const tickets.Plan, b: *const tickets.Board, width: usize, epoch: i64, unfolded: u8, narrow: bool, bench: bool, see: See) void {
        s.narrow = narrow;
        s.bench = bench;
        s.n = 0;
        s.picks = 0;
        s.used = 0;
        if (bench) return s.windowRows(given, b, width, epoch, see);
        s.nowRows(given, width, epoch);
        s.nextRows(given, width);
        s.goalRows(given, width);
        s.ideaRows(given, width, epoch, unfolded);
        s.add(.{ .kind = .blank });
        s.landedRow(given, b, width);
        s.unplannedRow(given, width);
    }

    /// Starts `win`'s rows.
    fn begin(s: *Sheet, win: Window) void {
        s.cur = win;
        s.from = s.n;
    }

    /// Ends a window's rows; a window with none says `empty`.
    fn end(s: *Sheet, empty: []const u8) void {
        if (s.n == s.from) s.add(.{ .kind = .note, .style = .dim, .text = empty });
    }

    /// Workbench's plan: the rows of each window of the screen, in the order the pick walks them.
    fn windowRows(s: *Sheet, given: *const tickets.Plan, b: *const tickets.Board, width: usize, epoch: i64, see: See) void {
        switch (see.screen) {
            .doing => s.doingRows(given, b, width, epoch),
            .planning => s.planningRows(given, b, width, epoch, see),
        }
    }

    fn planningRows(s: *Sheet, given: *const tickets.Plan, b: *const tickets.Board, width: usize, epoch: i64, see: See) void {
        s.begin(.goals);
        s.goalTicketRows(given, see);
        s.end("no goals");
        s.begin(.no_goal);
        s.noGoalRows(given, b, width, epoch, see);
        s.end("none");
        s.begin(.next);
        s.nextRows(given, width);
        s.end("none");
        s.begin(.backlog);
        s.ideaRows(given, width, epoch, 0);
        for (b.backlog()) |*card| if (!card.isEpic()) s.ticketRow(.backlog, card, width, epoch);
        s.end("the backlog is empty");
    }

    fn doingRows(s: *Sheet, given: *const tickets.Plan, b: *const tickets.Board, width: usize, epoch: i64) void {
        s.begin(.move);
        for (b.needsYou(), 0..) |need, at| {
            s.add(.{ .kind = .need, .pick = 0, .ticket = need.ticket, .item = at });
        }
        s.end("✓ nothing needs you");
        s.begin(.driving);
        if (driveLanded(given, b)) |need| {
            const title = drivenTitle(b, need, given.driving.?);
            s.add(.{ .kind = .drove, .pick = 0, .ticket = given.driving, .text = s.print("✓ #{d} {s} landed · pick the next goal on planning", .{ given.driving.?, title }) });
        } else if (focalGoal(given)) |at| {
            s.add(.{ .kind = .focal, .item = at, .pick = 0, .ticket = given.goals[at].epic });
        }
        s.end("towards no goal · pick one on planning");
        s.begin(.now);
        s.buildingRows(given, width, epoch);
        s.pipelineRows(given, width, epoch);
        s.end("none");
        s.begin(.next);
        s.nextRows(given, width);
        s.end("none");
        s.begin(.landed);
        for (given.landed_today.newest, 0..) |id, at| {
            s.add(.{ .kind = .landed, .pick = 0, .ticket = id, .item = at });
        }
        s.end("none");
    }

    fn headRow(s: *Sheet, name: []const u8, count: usize) void {
        const text = if (s.bench) name else s.print("{s} {d}", .{ name, count });
        s.add(.{ .kind = .head, .style = .heading, .text = text, .count = count });
    }

    fn building(item: tickets.NowItem) bool {
        return std.mem.eql(u8, item.state, "building");
    }

    fn nowRows(s: *Sheet, given: *const tickets.Plan, width: usize, epoch: i64) void {
        s.headRow("in flight", given.now.len);
        s.buildingRows(given, width, epoch);
        s.pipelineRows(given, width, epoch);
    }

    fn buildingRows(s: *Sheet, given: *const tickets.Plan, width: usize, epoch: i64) void {
        for (given.now, 0..) |item, i| if (building(item)) s.nowRow(item, i, width, epoch);
    }

    /// The pipeline's tickets, a row to each: landing first, then reviewing, verifying and
    /// queued by place.
    fn pipelineRows(s: *Sheet, given: *const tickets.Plan, width: usize, epoch: i64) void {
        var order: [max_rows]u16 = undefined;
        var n: usize = 0;
        for (given.now, 0..) |item, i| if (!building(item) and n < order.len) {
            order[n] = @intCast(i);
            n += 1;
        };
        std.mem.sort(u16, order[0..n], given, pipelineBefore);
        for (order[0..n]) |i| s.nowRow(given.now[i], i, width, epoch);
    }

    fn stageRank(item: tickets.NowItem) usize {
        for (stages, 0..) |name, rank| if (std.mem.eql(u8, item.stage orelse "", name)) return rank;
        return stages.len;
    }

    fn pipelineBefore(given: *const tickets.Plan, a: u16, b: u16) bool {
        const left = given.now[a];
        const right = given.now[b];
        if (stageRank(left) != stageRank(right)) return stageRank(left) < stageRank(right);
        if ((left.place orelse 0) != (right.place orelse 0)) return (left.place orelse 0) < (right.place orelse 0);
        return a < b;
    }

    fn nowRow(s: *Sheet, item: tickets.NowItem, at: usize, width: usize, epoch: i64) void {
        const queued = std.mem.eql(u8, item.stage orelse "", "queued");
        const mark: []const u8 = if (item.stalled != null) "◇" else if (item.waiting_on != null) "◷" else if (building(item)) "◐" else if (queued) "»" else "◒";
        var age: [16]u8 = undefined;
        const how = ago(&age, item.since, epoch);
        var th: [16]u8 = undefined;
        const state = if (queued and item.place != null) s.print("queued {s}", .{place(item.place.?, &th)}) else item.stage orelse item.state;
        var said: [96]u8 = undefined;
        const right = if (item.stalled) |why|
            s.print("stalled · {s}", .{why})
        else if (item.waiting_on) |wait|
            s.print("{s}", .{wait.say(&said)})
        else if (how.len > 0) s.print("{s} · {s}", .{ state, how }) else s.print("{s}", .{state});
        const left = s.print(" {s} #{d} {s: <8} {s}", .{ mark, item.ticket, text_mod.clip(item.repo orelse "", 8), item.name() });
        const both = s.spread(width, left, right);
        s.add(.{
            .kind = .now,
            .pick = 0,
            .ticket = item.ticket,
            .item = at,
            .text = both.text,
            .tail_at = both.tail_at,
            .tail_style = if (item.stalled != null) .attention else .normal,
        });
    }

    fn nextRows(s: *Sheet, given: *const tickets.Plan, width: usize) void {
        if (!s.bench) {
            s.add(.{ .kind = .blank });
            s.headRow("next", given.next.len);
        }
        const shown = if (s.bench) given.next.len else @min(given.next.len, next_shown);
        for (given.next[0..shown], 1..) |item, place_n| {
            if (s.bench) {
                s.add(.{ .kind = .next, .pick = 0, .ticket = item.ticket, .item = place_n - 1 });
                continue;
            }
            const right = s.waits(item.waits_on);
            const left = s.print(" {d} #{d} {s: <8} {s}", .{ place_n, item.ticket, text_mod.clip(item.repo orelse "", 8), item.name() });
            const both = s.spread(width, left, right);
            s.add(.{ .kind = .next, .pick = 0, .ticket = item.ticket, .text = both.text, .tail_at = both.tail_at });
            if (item.why.len > 0 and !s.narrow) s.add(.{ .kind = .why, .style = .dim, .text = s.clipped(width, s.print("      {s}", .{item.why})) });
        }
        if (shown < given.next.len) s.add(.{ .kind = .more, .style = .dim, .text = s.print("  +{d}", .{given.next.len - shown}) });
    }

    /// What an item waits on, as babylon says it: a ticket, or its repo's lane until one lands.
    fn waits(s: *Sheet, on: []const tickets.Wait) []const u8 {
        const start = s.used;
        for (on) |wait| {
            const sep: []const u8 = if (s.used == start) "← " else ", ";
            if (wait.ticket) |t| {
                _ = s.print("{s}needs #{d}", .{ sep, t });
            } else if (wait.until) |until| if (wait.lane) |lane| {
                _ = s.print("{s}after #{d} lands: one {s}", .{ sep, until, lane });
            };
        }
        if (s.used == start) return "free now";
        return s.buf[start..s.used];
    }

    fn goalRows(s: *Sheet, given: *const tickets.Plan, width: usize) void {
        if (!s.bench) {
            s.add(.{ .kind = .blank });
            s.headRow("goals", given.goals.len);
        }
        var name_w: usize = 0;
        if (!s.narrow) for (given.goals) |goal| {
            name_w = @max(name_w, @min(text_mod.cells(goal.name()), 26));
        };
        const ideas_room: usize = if (given.ideas.len == 0) 0 else idea_rows;
        const room_rows = max_rows -| s.n -| foot_rows -| ideas_room;
        const shown = if (given.goals.len <= room_rows) given.goals.len else room_rows -| 1;
        for (given.goals[0..shown]) |goal| {
            var extra: [96]u8 = undefined;
            const trying = goalTrying(goal);
            const after = if (trying > 0)
                s.print("  {d} of {d}  {s}{s}▲ {d} to try", .{ goal.landed, goal.total, goalExtra(goal, &extra), if (goalExtra(goal, &extra).len > 0) "  " else "", trying })
            else
                s.print("  {d} of {d}  {s}", .{ goal.landed, goal.total, goalExtra(goal, &extra) });
            const name = text_mod.clip(goal.name(), name_w);
            const head = s.print(" {s}{s}  #{d}  ", .{ name, spaces(name_w -| text_mod.cells(name)), goal.epic });
            const room = width -| text_mod.cells(head) -| text_mod.cells(after);
            const start = s.used;
            var marks: usize = 0;
            for (goal.steps) |step| {
                if (marks + 1 > room) break;
                _ = s.print("{s}", .{stepMark(step.state)});
                marks += 1;
            }
            if (marks < goal.steps.len and marks > 0) {
                const last = stepMark(goal.steps[marks - 1].state);
                s.used -= last.len;
                _ = s.print("…", .{});
            }
            const strip = s.buf[start..s.used];
            const line = s.print("{s}{s}{s}", .{ head, strip, after });
            s.add(.{ .kind = .goal, .pick = 0, .ticket = goal.epic, .text = s.clipped(width, line) });
        }
        if (shown < given.goals.len) s.add(.{ .kind = .goals_more, .pick = 0, .style = .dim, .text = s.print("  +{d} more goals", .{given.goals.len - shown}) });
    }

    /// Planning's goals, the one driven first, then babylon's order: a row to each, then a row
    /// to each of its tickets that has not landed, unless the goal is folded.
    fn goalTicketRows(s: *Sheet, given: *const tickets.Plan, see: See) void {
        for ([_]bool{ true, false }) |driven| for (given.goals, 0..) |goal, i| {
            if ((given.driving == goal.epic) != driven) continue;
            const shut = std.mem.indexOfScalar(u32, see.goals_shut, goal.epic) != null;
            s.add(.{ .kind = .goal, .pick = 0, .ticket = goal.epic, .item = i, .part = @intFromBool(shut) });
            if (shut) continue;
            for (goal.steps, 0..) |step, at| {
                if (std.mem.eql(u8, step.state, "landed")) continue;
                s.add(.{ .kind = .goal_ticket, .pick = 0, .ticket = step.ticket, .item = i, .count = at });
            }
        };
    }

    /// Under a rule, a row to each idea in the order babylon gives them, oldest first; past
    /// three, one row that unfolds them. In a window of its own they are all rows.
    fn ideaRows(s: *Sheet, given: *const tickets.Plan, width: usize, epoch: i64, unfolded: u8) void {
        if (given.ideas.len == 0) return;
        if (!s.bench) {
            s.add(.{ .kind = .blank });
            s.headRow("ideas", given.ideas.len);
        }
        if (!s.bench and given.ideas.len > ideas_shown and unfolded & (@as(u8, 1) << ideas_fold) == 0) {
            s.add(.{ .kind = .ideas_more, .pick = 0, .fold = ideas_fold, .style = .dim, .text = s.print(" +{d} ideas", .{given.ideas.len}) });
            return;
        }
        for (given.ideas, 0..) |idea, i| {
            const state = ideaState(idea);
            var said: [64]u8 = undefined;
            const label = ideaLabel(&said, idea, epoch);
            const asks = state == .planning and idea.asks > 0;
            const right = if (asks) s.print("{s}  ▲ asks you", .{label}) else label;
            const left = s.print(" {s} #{d} {s}", .{ ideaMark(state), idea.epic, idea.name() });
            const both = s.spread(width, left, right);
            s.add(.{
                .kind = .idea,
                .pick = 0,
                .ticket = idea.epic,
                .item = i,
                .text = both.text,
                .tail_at = both.tail_at,
                .tail_style = if (asks) .attention else .dim,
            });
        }
    }

    pub const IdeaState = enum { idea, planning, draft };

    /// An idea's state as one of the three drawn; one babylon names otherwise is a plain idea.
    pub fn ideaState(idea: tickets.Idea) IdeaState {
        return std.meta.stringToEnum(IdeaState, idea.state) orelse .idea;
    }

    pub fn ideaMark(state: IdeaState) []const u8 {
        return switch (state) {
            .idea => "◇",
            .planning => "◐",
            .draft => "✎",
        };
    }

    /// What an idea says of itself on its row, in `buf`: its state, and how long a Claude has
    /// been planning it.
    pub fn ideaLabel(buf: []u8, idea: tickets.Idea, epoch: i64) []const u8 {
        var age: [16]u8 = undefined;
        const out = switch (ideaState(idea)) {
            .idea => std.fmt.bufPrint(buf, "idea", .{}),
            .planning => blk: {
                const how = ago(&age, idea.since, epoch);
                break :blk std.fmt.bufPrint(buf, "planning{s}{s}", .{ if (how.len > 0) " " else "", how });
            },
            .draft => std.fmt.bufPrint(buf, "draft", .{}),
        };
        return out catch "";
    }

    pub fn stepMark(state: []const u8) []const u8 {
        const marks = [_][2][]const u8{
            .{ "landed", "✓" },
            .{ "building", "◐" },
            .{ "landing", "◒" },
            .{ "next", "●" },
            .{ "to_try", "▲" },
            .{ "failed", "✗" },
            .{ "sent_back", "✗" },
        };
        for (marks) |pair| if (std.mem.eql(u8, state, pair[0])) return pair[1];
        return "○";
    }

    /// The steps of a goal that are moving or next, by number, else what its first waiting step
    /// waits on.
    fn goalExtra(goal: tickets.Goal, buf: []u8) []const u8 {
        var used: usize = 0;
        var moving: usize = 0;
        for (goal.steps) |step| {
            const mark = stepMark(step.state);
            if (std.mem.eql(u8, mark, "✓") or std.mem.eql(u8, mark, "○") or std.mem.eql(u8, mark, "✗") or std.mem.eql(u8, mark, "▲")) continue;
            if (moving == 3) break;
            const out = std.fmt.bufPrint(buf[used..], "{s}{s} #{d}", .{ if (moving > 0) " " else "", mark, step.ticket }) catch break;
            used += out.len;
            moving += 1;
        }
        if (moving > 0) return buf[0..used];
        for (goal.steps) |step| {
            if (!std.mem.eql(u8, stepMark(step.state), "○")) continue;
            const out = if (step.waits_on.len > 0 and step.waits_on[0].ticket != null)
                std.fmt.bufPrint(buf, "○ #{d} waits on #{d}", .{ step.ticket, step.waits_on[0].ticket.? })
            else
                std.fmt.bufPrint(buf, "○ #{d}", .{step.ticket});
            return out catch "";
        }
        return "";
    }

    fn landedRow(s: *Sheet, given: *const tickets.Plan, b: *const tickets.Board, width: usize) void {
        const today = given.landed_today;
        const start = s.used;
        _ = s.print("landed today {d}", .{today.count});
        for (today.newest, 0..) |id, i| {
            _ = s.print("{s}", .{if (i == 0) "   " else " · "});
            const card = for (b.cards()) |*card| {
                if (card.id == id) break card;
            } else null;
            if (card) |c| {
                _ = s.print("#{d} {s} {s}", .{ id, c.repo orelse "", c.name() });
            } else _ = s.print("#{d}", .{id});
        }
        s.add(.{ .kind = .landed, .pick = 0, .text = s.clipped(width, s.buf[start..s.used]) });
    }

    fn repoShut(see: See, repo: ?[]const u8) bool {
        for (see.repos_shut) |name| if (std.mem.eql(u8, name, repo orelse "")) return true;
        return false;
    }

    /// Whether `card` is a step of a goal.
    fn inGoal(given: *const tickets.Plan, card: *const tickets.Card) bool {
        const epic = card.epic_id orelse return false;
        for (given.goals) |goal| if (goal.epic == epic) return true;
        return false;
    }

    /// No goal's rows: the chip row, then the open repos' todo tickets that are in no goal in
    /// babylon's order (those that can start before those that wait).
    fn noGoalRows(s: *Sheet, given: *const tickets.Plan, b: *const tickets.Board, width: usize, epoch: i64, see: See) void {
        s.add(.{ .kind = .chips, .pick = 0, .count = given.not_planned.count });
        const rows_from = s.n;
        for ([_]bool{ false, true }) |waiting| for (b.cards()) |*card| {
            if (card.status != .todo or card.isEpic() or (card.blocked_by.len > 0) != waiting) continue;
            if (repoShut(see, card.repo) or inGoal(given, card)) continue;
            s.ticketRow(.todo, card, width, epoch);
        };
        if (s.n != rows_from) return;
        const repos = given.not_planned.by_repo.map.count();
        const text = if (repos > 0 and see.repos_shut.len >= repos) "every repo is folded: ⏎ on a chip opens it" else "nothing to do in the open repos";
        s.add(.{ .kind = .note, .style = .dim, .text = text });
    }

    /// A todo or backlog ticket's row: its number and title, and on the right its priority and
    /// what it waits on, or in the backlog its age.
    fn ticketRow(s: *Sheet, kind: Kind, card: *const tickets.Card, width: usize, epoch: i64) void {
        var age: [16]u8 = undefined;
        const how = ago(&age, card.inserted_at, epoch);
        const right = if (card.blocked_by.len > 0)
            s.print("{s}  ← #{d}", .{ card.priority, card.blocked_by[0] })
        else if (kind == .backlog and how.len > 0) s.print("{s}  {s}", .{ card.priority, how }) else s.print("{s}", .{card.priority});
        const left = s.print(" #{d} {s}", .{ card.id, card.name() });
        const both = s.spread(width, left, right);
        s.add(.{ .kind = kind, .pick = 0, .ticket = card.id, .text = both.text, .tail_at = both.tail_at, .tail_style = .dim });
    }

    fn unplannedRow(s: *Sheet, given: *const tickets.Plan, width: usize) void {
        const not = given.not_planned;
        const start = s.used;
        _ = s.print("not planned {d}, {d} follow-ups   ", .{ not.count, not.follow_ups });
        for (not.by_repo.map.keys(), not.by_repo.map.values(), 0..) |repo, n, i| {
            _ = s.print("{s}{s} {d}", .{ if (i == 0) "" else " · ", repo, n });
        }
        s.add(.{ .kind = .unplanned, .pick = 0, .text = s.clipped(width, s.buf[start..s.used]) });
    }
};

const blank: [256]u8 = @splat(' ');

fn spaces(n: usize) []const u8 {
    return blank[0..@min(n, blank.len)];
}

/// `1st`, `2nd`, `3rd`, `4th`: a place in a queue, in `buf`.
pub fn place(n: u32, buf: []u8) []const u8 {
    const word: []const u8 = if (n % 100 >= 11 and n % 100 <= 13) "th" else switch (n % 10) {
        1 => "st",
        2 => "nd",
        3 => "rd",
        else => "th",
    };
    return std.fmt.bufPrint(buf, "{d}{s}", .{ n, word }) catch "";
}

/// How long ago `since` was, as `6m` or `1h05`; nothing when babylon does not say.
pub fn ago(buf: []u8, since: ?[]const u8, epoch: i64) []const u8 {
    const then = tickets.epochOf(since) orelse return "";
    const mins = @divFloor(@max(epoch - then, 0), 60);
    if (mins < 1) return "now";
    if (mins < 60) return std.fmt.bufPrint(buf, "{d}m", .{mins}) catch "";
    return std.fmt.bufPrint(buf, "{d}h{d:0>2}", .{ @divFloor(mins, 60), @mod(mins, 60) }) catch "";
}

const sample =
    \\{"tickets":[{"id":322,"repo":"arena","title":"held card e2e","status":"done"}],
    \\"plan":{
    \\"now":[
    \\{"ticket":600,"repo":"arena","title":"Design","state":"building","since":"2026-11-23T07:04:00Z","pane":"%757"},
    \\{"ticket":510,"repo":"tlon","title":"Money","state":"building","since":"2026-11-23T07:02:00Z","pane":"%575","stalled":"idle 9m"},
    \\{"ticket":587,"repo":"arena","title":"Seams","state":"landing","stage":"verifying","since":"2026-11-23T06:50:00Z"},
    \\{"ticket":591,"repo":"arena","title":"Hook","state":"landing","stage":"verifying","since":"2026-11-23T06:55:00Z"},
    \\{"ticket":560,"repo":"arena","title":"Third","state":"landing","stage":"verifying","since":"2026-11-23T06:56:00Z"},
    \\{"ticket":588,"repo":"babylon","title":"Queued","state":"landing","stage":"queued","place":1,"since":"2026-11-23T06:57:00Z"},
    \\{"ticket":429,"repo":"babylon","title":"Queued two","state":"landing","stage":"queued","place":2,"since":"2026-11-23T06:57:00Z"}],
    \\"next":[
    \\{"ticket":589,"repo":"babylon","title":"babylon start N","why":"the seams' verb","waits_on":[{"lane":"babylon","until":588}]},
    \\{"ticket":594,"repo":"arena","title":"the board's start","why":"stops typing","waits_on":[{"ticket":589}]},
    \\{"ticket":453,"repo":"arena","title":"Normal mode 2","why":"","waits_on":[]}],
    \\"goals":[{"epic":452,"title":"normal mode","total":3,"landed":1,"steps":[{"ticket":1,"state":"landed"},{"ticket":453,"state":"next"},{"ticket":454,"state":"waiting","waits_on":[{"ticket":453}]}]},
    \\{"epic":9,"title":"quiet","total":2,"landed":1,"steps":[{"ticket":1,"state":"landed"},{"ticket":3,"state":"waiting","waits_on":[{"ticket":2}]}]}],
    \\"landed_today":{"count":2,"newest":[322,999]},
    \\"not_planned":{"count":5,"follow_ups":3,"by_repo":{"arena":3,"tlon":2}}}}
;

fn rowText(s: *const Sheet, kind: Kind, nth: usize) ?[]const u8 {
    var seen: usize = 0;
    for (s.rows[0..s.n]) |row| if (row.kind == kind) {
        if (seen == nth) return row.text;
        seen += 1;
    };
    return null;
}

test "in flight: building first, then the pipeline a row to a ticket, landing before reviewing before verifying before queued by place, each said as babylon gives it" {
    var b = try tickets.Board.parse(std.testing.allocator, sample);
    defer b.deinit();
    var s: Sheet = undefined;
    const epoch = tickets.epochOf("2026-11-23T07:10:00Z").?;
    s.build(b.plan().?, &b, 100, epoch, 0, false, false, .{});
    const eq = std.testing.expectEqualStrings;
    const ok = std.testing.expect;
    try eq("in flight 7", rowText(&s, .head, 0).?);
    try ok(std.mem.startsWith(u8, rowText(&s, .now, 0).?, " ◐ #600 arena    Design"));
    try ok(std.mem.endsWith(u8, rowText(&s, .now, 0).?, "building · 6m"));
    try ok(std.mem.indexOf(u8, rowText(&s, .now, 1).?, "◇ #510") != null);
    try ok(std.mem.endsWith(u8, rowText(&s, .now, 1).?, "stalled · idle 9m"));
    try ok(std.mem.endsWith(u8, rowText(&s, .now, 2).?, "verifying · 20m"));
    try ok(std.mem.indexOf(u8, rowText(&s, .now, 3).?, "#591") != null);
    try ok(std.mem.indexOf(u8, rowText(&s, .now, 4).?, "#560") != null);
    try ok(std.mem.indexOf(u8, rowText(&s, .now, 5).?, "» #588") != null);
    try ok(std.mem.endsWith(u8, rowText(&s, .now, 5).?, "queued 1st · 13m"));
    try ok(std.mem.indexOf(u8, rowText(&s, .now, 6).?, "» #429") != null);
    try ok(std.mem.endsWith(u8, rowText(&s, .now, 6).?, "queued 2nd · 13m"));
    try std.testing.expectEqual(@as(?[]const u8, null), rowText(&s, .now, 7));
}

test "a landing ticket is listed before reviewing, verifying and queued, whatever order babylon gives" {
    var b = try tickets.Board.parse(std.testing.allocator,
        \\{"tickets":[],"plan":{"now":[
        \\{"ticket":1,"repo":"arena","title":"q2","state":"landing","stage":"queued","place":2},
        \\{"ticket":2,"repo":"arena","title":"v","state":"landing","stage":"verifying"},
        \\{"ticket":3,"repo":"arena","title":"l","state":"landing","stage":"landing"},
        \\{"ticket":4,"repo":"arena","title":"q1","state":"landing","stage":"queued","place":1},
        \\{"ticket":5,"repo":"arena","title":"r","state":"landing","stage":"reviewing"},
        \\{"ticket":6,"repo":"arena","title":"b","state":"building"}]}}
    );
    defer b.deinit();
    var s: Sheet = undefined;
    s.build(b.plan().?, &b, 100, 0, 0, false, true, .{});
    const want = [_]u32{ 6, 3, 5, 2, 4, 1 };
    var at: usize = 0;
    for (s.rows[0..s.n]) |row| if (row.kind == .now) {
        try std.testing.expectEqual(want[at], row.ticket.?);
        at += 1;
    };
    try std.testing.expectEqual(want.len, at);
}

test "a wait with no ticket and no landing to wait for is no wait" {
    const bare = [_]tickets.Wait{ .{ .lane = "arena" }, .{} };
    try std.testing.expect(tickets.Wait.first(&bare) == null);
    const mixed = [_]tickets.Wait{ .{ .lane = "arena" }, .{ .lane = "arena", .until = 818 } };
    try std.testing.expectEqual(@as(?u32, 818), tickets.Wait.first(&mixed).?.until);
    var s: Sheet = undefined;
    s.used = 0;
    try std.testing.expectEqualStrings("free now", s.waits(&bare));
}

test "next says what each waits on and why, goals their steps, and the picks run through every row that can be" {
    var b = try tickets.Board.parse(std.testing.allocator, sample);
    defer b.deinit();
    var s: Sheet = undefined;
    s.build(b.plan().?, &b, 100, 0, 0, false, false, .{});
    const has = std.mem.indexOf;
    const ok = std.testing.expect;
    try ok(std.mem.endsWith(u8, rowText(&s, .next, 0).?, "← after #588 lands: one babylon"));
    try ok(std.mem.endsWith(u8, rowText(&s, .next, 1).?, "← needs #589"));
    try ok(std.mem.endsWith(u8, rowText(&s, .next, 2).?, "free now"));
    var whys: usize = 0;
    for (s.rows[0..s.n]) |row| whys += @intFromBool(row.kind == .why);
    try std.testing.expectEqual(@as(usize, 2), whys);
    try ok(has(u8, rowText(&s, .goal, 0).?, "#452  ✓●○  1 of 3  ● #453") != null);
    try ok(has(u8, rowText(&s, .goal, 1).?, "1 of 2  ○ #3 waits on #2") != null);
    try ok(has(u8, rowText(&s, .landed, 0).?, "landed today 2   #322 arena held card e2e · #999") != null);
    try ok(has(u8, rowText(&s, .unplanned, 0).?, "not planned 5, 3 follow-ups   arena 3 · tlon 2") != null);
    // 2 building and 5 pipeline rows, 3 next, 2 goals, landed, not planned
    try std.testing.expectEqual(@as(usize, 2 + 5 + 3 + 2 + 2), s.picks);
    try std.testing.expectEqual(s.picks - 1, s.rows[s.rowOf(s.picks - 1).?].pick.?);
}

test "ideas draw a row each under their rule, one in each state, and fold past three" {
    const ok = std.testing.expect;
    const given = try tickets.Board.parse(std.testing.allocator,
        \\{"tickets":[],"plan":{"ideas":[
        \\{"epic":830,"title":"money","state":"planning","plan_ticket":839,"pane":"%12","asks":1,"since":"2026-11-24T20:00:00Z"},
        \\{"epic":831,"title":"retro","state":"draft","steps":7,"since":"2026-11-24T10:00:00Z"},
        \\{"epic":829,"title":"garden","state":"idea","since":"2026-11-22T10:00:00Z"}]}}
    );
    var b = given;
    defer b.deinit();
    var s: Sheet = undefined;
    s.build(b.plan().?, &b, 80, tickets.epochOf("2026-11-24T20:04:00Z").?, 0, false, false, .{});
    try ok(std.mem.eql(u8, rowText(&s, .head, 3).?, "ideas 3"));
    const planning = rowText(&s, .idea, 0).?;
    try ok(std.mem.indexOf(u8, planning, "◐ #830 money") != null);
    try ok(std.mem.indexOf(u8, planning, "planning 4m  ▲ asks you") != null);
    try ok(std.mem.indexOf(u8, rowText(&s, .idea, 1).?, "✎ #831 retro") != null);
    try ok(std.mem.endsWith(u8, rowText(&s, .idea, 1).?, "draft"));
    try ok(std.mem.indexOf(u8, rowText(&s, .idea, 2).?, "◇ #829 garden") != null);
    try ok(std.mem.endsWith(u8, rowText(&s, .idea, 2).?, "idea"));
    try ok(rowText(&s, .ideas_more, 0) == null);

    var four = try tickets.Board.parse(std.testing.allocator,
        \\{"tickets":[],"plan":{"ideas":[
        \\{"epic":1,"title":"a"},{"epic":2,"title":"b"},{"epic":3,"title":"c"},{"epic":4,"title":"d"}]}}
    );
    defer four.deinit();
    s.build(four.plan().?, &four, 80, 0, 0, false, false, .{});
    try ok(rowText(&s, .idea, 0) == null);
    try ok(std.mem.eql(u8, rowText(&s, .ideas_more, 0).?, " +4 ideas"));
    s.build(four.plan().?, &four, 80, 0, @as(u8, 1) << ideas_fold, false, false, .{});
    try ok(rowText(&s, .ideas_more, 0) == null);
    try ok(rowText(&s, .idea, 3) != null);
}

test "a goal with a step to try reads ▲ N to try, and the step is neither next nor moving" {
    var b = try tickets.Board.parse(std.testing.allocator,
        \\{"tickets":[],"plan":{"now":[],"next":[],
        \\"goals":[{"epic":9,"title":"g","total":2,"landed":1,"steps":[{"ticket":1,"state":"to_try"},{"ticket":2,"state":"waiting"}]}],
        \\"landed_today":{"count":0,"newest":[]},"not_planned":{"count":0,"follow_ups":0,"by_repo":{}}}}
    );
    defer b.deinit();
    var s: Sheet = undefined;
    s.build(b.plan().?, &b, 100, 0, 0, false, false, .{});
    try std.testing.expect(std.mem.indexOf(u8, rowText(&s, .goal, 0).?, "1 of 2  ○ #2  ▲ 1 to try") != null);
}

test "a row too wide is cut, its right side kept" {
    var b = try tickets.Board.parse(std.testing.allocator, sample);
    defer b.deinit();
    var s: Sheet = undefined;
    s.build(b.plan().?, &b, 40, 0, 0, false, false, .{});
    for (s.rows[0..s.n]) |row| try std.testing.expect(text_mod.cells(row.text) <= 40);
    try std.testing.expect(std.mem.endsWith(u8, rowText(&s, .now, 0).?, "building · now"));
}

test "the focal goal is the first with a step being built, and Doing has no goals window" {
    var b = try tickets.Board.parse(std.testing.allocator, sample);
    defer b.deinit();
    const given = b.plan().?;
    try std.testing.expectEqual(@as(?usize, 0), focalGoal(given));

    var s: Sheet = undefined;
    s.build(given, &b, 100, 0, 0, false, true, .{});
    const at = s.span(.driving).start;
    try std.testing.expectEqual(Kind.focal, s.rows[at].kind);
    try std.testing.expectEqual(@as(usize, 0), s.rows[at].pick.?);
    try std.testing.expectEqual(@as(usize, 0), s.span(.goals).len);
    try std.testing.expectEqual(@as(usize, 0), s.span(.no_goal).len);
    try std.testing.expectEqual(@as(usize, 0), s.span(.backlog).len);
}

test "the focal window follows plan.driving, is one row, and asks what next when that goal has landed" {
    const open =
        \\{"tickets":[{"id":14,"repo":"arena","kind":"epic","status":"done","title":"The house"},{"id":15,"repo":"arena","status":"done","title":"a step","epic_id":14}],
        \\"needs_you":[{"id":"drive:14","kind":"drive","ticket":14,"repo":"","text":"goal landed",
        \\"actions":[{"key":"1","label":"the board","argv":["babylon","drive","326"]},{"key":"2","label":"the orchestrator","argv":["babylon","drive","500"]}]}],
        \\"plan":{
    ;
    const goals =
        \\"goals":[
        \\{"epic":410,"title":"menard","landed":2,"total":7,"steps":[{"ticket":592,"state":"todo"}]},
        \\{"epic":326,"title":"board","landed":1,"total":2,"steps":[{"ticket":760,"state":"building"}]}]}}
    ;
    var s: Sheet = undefined;
    for ([_]struct { driving: []const u8, epic: ?u32 }{
        .{ .driving = "", .epic = 326 },
        .{ .driving = "\"driving\":410,", .epic = 410 },
    }) |case| {
        const text = try std.fmt.allocPrint(std.testing.allocator, "{s}{s}{s}", .{ open, case.driving, goals });
        defer std.testing.allocator.free(text);
        var b = try tickets.Board.parse(std.testing.allocator, text);
        defer b.deinit();
        const given = b.plan().?;
        try std.testing.expectEqual(@as(?u32, case.epic), given.goals[focalGoal(given).?].epic);
        try std.testing.expect(driveLanded(given, &b) == null);
        s.build(given, &b, 100, 0, 0, false, true, .{});
        try std.testing.expectEqual(@as(usize, 1), s.span(.driving).len);
        for (s.rows[0..s.n]) |row| try std.testing.expect(row.kind != .goal and row.kind != .goal_ticket);
    }

    const text = try std.fmt.allocPrint(std.testing.allocator, "{s}\"driving\":14,{s}", .{ open, goals });
    defer std.testing.allocator.free(text);
    var b = try tickets.Board.parse(std.testing.allocator, text);
    defer b.deinit();
    const given = b.plan().?;
    try std.testing.expect(driveLanded(given, &b) != null);
    s.build(given, &b, 100, 0, 0, false, true, .{});
    const at = s.span(.driving).start;
    try std.testing.expectEqual(@as(usize, 1), s.span(.driving).len);
    try std.testing.expectEqualStrings("✓ #14 The house landed · pick the next goal on planning", s.rows[at].text);
}

test "Planning lists every goal with its open ticket, and Doing keeps landed" {
    var buf: [8192]u8 = undefined;
    var used = (try std.fmt.bufPrint(&buf, "{{\"tickets\":[],\"plan\":{{\"now\":[],\"next\":[],\"goals\":[", .{})).len;
    for (0..32) |i| {
        used += (try std.fmt.bufPrint(buf[used..], "{s}{{\"epic\":{d},\"title\":\"g{d}\",\"total\":2,\"landed\":1,\"steps\":[{{\"ticket\":1,\"state\":\"landed\"}},{{\"ticket\":2,\"state\":\"next\"}}]}}", .{ if (i > 0) "," else "", 100 + i, i })).len;
    }
    used += (try std.fmt.bufPrint(buf[used..], "],\"landed_today\":{{\"count\":1,\"newest\":[1]}},\"not_planned\":{{\"count\":0,\"follow_ups\":0,\"by_repo\":{{}}}}}}}}", .{})).len;
    var b = try tickets.Board.parse(std.testing.allocator, buf[0..used]);
    defer b.deinit();
    var s: Sheet = undefined;
    s.build(b.plan().?, &b, 100, 0, 0, false, true, .{});
    try std.testing.expect(rowText(&s, .landed, 0) != null);
    try std.testing.expectEqual(@as(usize, 0), s.span(.goals).len);
    s.build(b.plan().?, &b, 100, 0, 0, false, true, .{ .screen = .planning });
    try std.testing.expect(rowText(&s, .chips, 0) != null);
    try std.testing.expectEqual(@as(usize, 64), s.span(.goals).len);
    try std.testing.expect(rowText(&s, .goals_more, 0) == null);
}

test "a now row waiting on a ticket says so, with its own mark, and is not drawn as stalled" {
    var b = try tickets.Board.parse(std.testing.allocator,
        \\{"tickets":[],"plan":{"now":[
        \\{"ticket":505,"repo":"arena","title":"Parked","state":"building","since":"2026-11-23T07:00:00Z","pane":"%580","waiting_on":{"ticket":829,"for":null,"since":"2026-11-23T07:01:00Z"}}]}}
    );
    defer b.deinit();
    var s: Sheet = undefined;
    s.build(b.plan().?, &b, 100, tickets.epochOf("2026-11-23T07:10:00Z").?, 0, false, false, .{});
    const row = rowText(&s, .now, 0).?;
    try std.testing.expect(std.mem.indexOf(u8, row, "◷ #505") != null);
    try std.testing.expect(std.mem.endsWith(u8, row, "◷ waiting on #829"));
    try std.testing.expect(std.mem.indexOf(u8, row, "stalled") == null);
}

test "landed is a row to each of today's tickets, newest first" {
    var b = try tickets.Board.parse(std.testing.allocator,
        \\{"tickets":[{"id":5,"title":"Five","status":"done"},{"id":6,"title":"Six","status":"done"}],"plan":{"now":[],"next":[],"goals":[],
        \\"landed_today":{"count":23,"newest":[6,5]},"not_planned":{"count":0,"follow_ups":0,"by_repo":{}}}}
    );
    defer b.deinit();
    var s: Sheet = undefined;
    s.build(b.plan().?, &b, 100, 0, 0, false, true, .{});
    var tickets_seen: [2]u32 = undefined;
    var n: usize = 0;
    for (s.rows[0..s.n]) |row| if (row.kind == .landed) {
        tickets_seen[n] = row.ticket.?;
        n += 1;
    };
    try std.testing.expectEqual(@as(usize, 2), n);
    try std.testing.expectEqualSlices(u32, &.{ 6, 5 }, &tickets_seen);
}

test "no goal holds the open repos' todo tickets that are in no goal, startable first, and the backlog is a window of its own" {
    var b = try tickets.Board.parse(std.testing.allocator,
        \\{"tickets":[
        \\{"id":1,"repo":"arena","title":"blocked","status":"todo","blocked_by":[9]},
        \\{"id":2,"repo":"arena","title":"free","status":"todo","priority":"high"},
        \\{"id":3,"repo":"tlon","title":"folded repo","status":"todo"},
        \\{"id":4,"repo":"arena","title":"in next","status":"todo"},
        \\{"id":5,"repo":"arena","title":"doing","status":"doing"},
        \\{"id":8,"repo":"arena","title":"a step","status":"todo","epic_id":20}],
        \\"backlog":[{"id":6,"repo":"arena","title":"later","status":"backlog","kind":"ticket"},{"id":7,"title":"an idea","status":"backlog","kind":"epic"}],
        \\"plan":{"next":[{"ticket":4,"repo":"arena","title":"in next","why":""}],
        \\"goals":[{"epic":20,"title":"goal","total":1,"landed":0,"steps":[{"ticket":8,"state":"todo"}]}],
        \\"ideas":[{"epic":7,"title":"an idea"}],
        \\"not_planned":{"count":3,"follow_ups":0,"by_repo":{"arena":2,"tlon":1}}}}
    );
    defer b.deinit();
    var s: Sheet = undefined;
    const shut = [_][]const u8{"tlon"};
    s.build(b.plan().?, &b, 100, 0, 0, false, true, .{ .screen = .planning, .repos_shut = &shut });
    const win = s.span(.no_goal);
    try std.testing.expectEqual(Kind.chips, s.rows[win.start].kind);
    try std.testing.expectEqual(@as(usize, 4), win.len);
    try std.testing.expectEqual(@as(?u32, 2), s.rows[win.start + 1].ticket);
    try std.testing.expectEqual(@as(?u32, 4), s.rows[win.start + 2].ticket);
    try std.testing.expectEqual(@as(?u32, 1), s.rows[win.start + 3].ticket);
    try std.testing.expect(std.mem.endsWith(u8, s.rows[win.start + 3].text, "med  ← #9"));
    const back = s.span(.backlog);
    try std.testing.expectEqual(@as(usize, 2), back.len);
    try std.testing.expectEqual(Kind.idea, s.rows[back.start].kind);
    try std.testing.expectEqual(Kind.backlog, s.rows[back.start + 1].kind);
    try std.testing.expectEqual(@as(?u32, 6), s.rows[back.start + 1].ticket);
    var chips: [max_chips]Chip = undefined;
    const got = chipsAt(b.plan().?, 10, 80, &chips);
    try std.testing.expectEqual(@as(usize, 2), got.len);
    try std.testing.expect(got[1].x == got[0].x + got[0].w + 1);
}

test "Planning lists each open goal's tickets under it, the one driven first, and a folded goal lists none" {
    var b = try tickets.Board.parse(std.testing.allocator,
        \\{"tickets":[],"plan":{"driving":9,"next":[],
        \\"goals":[{"epic":8,"title":"first","total":2,"landed":1,"steps":[{"ticket":1,"state":"landed"},{"ticket":2,"state":"todo"}]},
        \\{"epic":9,"title":"driven","total":3,"landed":1,"steps":[{"ticket":3,"state":"landed"},{"ticket":4,"state":"building"},{"ticket":5,"state":"todo","waits_on":[{"ticket":4}]}]}]}}
    );
    defer b.deinit();
    var s: Sheet = undefined;
    s.build(b.plan().?, &b, 100, 0, 0, false, true, .{ .screen = .planning });
    const win = s.span(.goals);
    const want = [_]struct { Kind, u32 }{ .{ .goal, 9 }, .{ .goal_ticket, 4 }, .{ .goal_ticket, 5 }, .{ .goal, 8 }, .{ .goal_ticket, 2 } };
    try std.testing.expectEqual(want.len, win.len);
    for (want, s.rows[win.start..][0..want.len]) |expect, row| {
        try std.testing.expectEqual(expect[0], row.kind);
        try std.testing.expectEqual(@as(?u32, expect[1]), row.ticket);
    }
    const shut = [_]u32{9};
    s.build(b.plan().?, &b, 100, 0, 0, false, true, .{ .screen = .planning, .goals_shut = &shut });
    try std.testing.expectEqual(@as(usize, 3), s.span(.goals).len);
    try std.testing.expectEqual(@as(u8, 1), s.rows[s.span(.goals).start].part);
}
