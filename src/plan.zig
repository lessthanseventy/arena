//! Home's plan: babylon's `plan` laid out as rows to draw, and the pick over the rows that can be
//! picked. Everything shown is what babylon gave; the only thing worked out here is how it folds.
const std = @import("std");
const tickets = @import("board.zig");
const text_mod = @import("text.zig");

pub const max_rows = 160;

/// The stages whose tickets fold into one row past the first two of them, in the order of the
/// bits `unfolded` holds; queued folds from its first.
pub const folds = [_][]const u8{ "verifying", "reviewing", "landing", "queued" };
const queued_fold = folds.len - 1;
/// Tickets of one stage kept as rows of their own before the rest fold.
const unfolded_rows = 2;
/// The tickets of next that are drawn; the rest are `+N`.
const next_shown = 7;
/// The tickets of next a folded window names.
const next_summary = 5;

/// Rows kept past the goals for the foot: a gap, not planned's head and row, a gap, landed.
const foot_rows = 5;
/// Rows kept past the goals for the ideas: a gap, their rule, and three rows or the fold.
const idea_rows = 5;
/// Ideas shown a row each; past it they fold to one row.
const ideas_shown = 3;
/// The bit of `unfolded` that holds the ideas open, past the pipeline's folds.
pub const ideas_fold: u3 = folds.len;

pub const Kind = enum { head, blank, now, folded, next, why, more, goals_more, goal, landed, unplanned, focal, card_top, goal_bar, goal_next, goal_block, idea, ideas_more, summary, note };
pub const Style = enum { normal, dim, heading, attention };

/// Workbench's plan is seven windows, each a fixed slot of the screen.
pub const Window = enum {
    driving,
    now,
    landing,
    next,
    goals,
    unplanned,
    landed,

    pub fn title(win: Window) []const u8 {
        return switch (win) {
            .driving => "driving towards",
            .unplanned => "not planned",
            else => @tagName(win),
        };
    }
};

pub const Shut = std.EnumSet(Window);

pub const Rect = struct { x: u16, y: u16, w: u16, h: u16 };

/// Rows of a window's slot that are not its body: the title bar, and the shadow's row.
pub const window_chrome = 2;
const driving_h = 5;

/// Where `win` sits on a plan area `w` by `h` cells: its title bar, body and shadow. Worked out
/// from the area alone, so nothing in a window or its fold moves another.
pub fn slot(win: Window, w: u16, h: u16) Rect {
    const top = @min(driving_h, h);
    const rest = h - top;
    const half = w / 2;
    return switch (win) {
        .driving => .{ .x = 0, .y = 0, .w = w, .h = top },
        .now => .{ .x = 0, .y = top, .w = half, .h = rest * 3 / 10 },
        .landing => .{ .x = 0, .y = top + rest * 3 / 10, .w = half, .h = rest * 3 / 10 },
        .next => .{ .x = 0, .y = top + rest * 6 / 10, .w = half, .h = rest - rest * 6 / 10 },
        .goals => .{ .x = half, .y = top, .w = w - half, .h = rest * 4 / 10 },
        .unplanned => .{ .x = half, .y = top + rest * 4 / 10, .w = w - half, .h = rest * 3 / 10 },
        .landed => .{ .x = half, .y = top + rest * 7 / 10, .w = w - half, .h = rest - rest * 7 / 10 },
    };
}

/// The first of `len` rows a window of `body` rows shows, the row at `at` kept in view with the
/// rest of its card (two rows) below it.
pub fn windowTop(at: usize, len: usize, body: usize) usize {
    return @min((at + 3) -| body, len -| body);
}

pub const Row = struct {
    kind: Kind,
    /// Its place among the rows that can be picked; none for a heading, a why line or a gap.
    pick: ?usize = null,
    ticket: ?u32 = null,
    /// Of a folded row: which stage's fold it is, as a bit of `unfolded`.
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
};

/// The goal Home puts in the focal window: the first with a step being built, else the first not
/// yet landed whole.
pub fn focalGoal(goals: []const tickets.Goal) ?usize {
    for (goals, 0..) |goal, i| for (goal.steps) |step| {
        if (std.mem.eql(u8, step.state, "building")) return i;
    };
    for (goals, 0..) |goal, i| if (goal.landed < goal.total) return i;
    return null;
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

/// A goal's next step: the first being built, else landing, else next, else the first waiting.
pub fn goalNext(goal: tickets.Goal) ?tickets.Step {
    for ([_][]const u8{ "◐", "◒", "●", "○" }) |want| for (goal.steps) |step| {
        if (std.mem.eql(u8, Sheet.stepMark(step.state), want)) return step;
    };
    return null;
}

/// The first step of a goal that waits on a ticket, and that ticket.
pub fn goalBlock(goal: tickets.Goal) ?struct { step: u32, on: u32 } {
    for (goal.steps) |step| for (step.waits_on) |wait| if (wait.ticket) |on| return .{ .step = step.ticket, .on = on };
    return null;
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
    /// Workbench's windows folded to their summary, and the one rows are being added to.
    shut: Shut = undefined,
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
        var shown = left;
        var cut = false;
        if (text_mod.cells(left) > room) {
            shown = text_mod.clip(left, room -| 1);
            cut = true;
        }
        const ellipsis: []const u8 = if (cut) "…" else "";
        const pad = width -| text_mod.cells(shown) -| @intFromBool(cut) -| right_w;
        const text = s.print("{s}{s}{s}{s}", .{ shown, ellipsis, spaces(pad), right });
        return .{ .text = text, .tail_at = shown.len + ellipsis.len + pad };
    }

    fn clipped(s: *Sheet, width: usize, line: []const u8) []const u8 {
        if (text_mod.cells(line) <= width) return line;
        return s.print("{s}…", .{text_mod.clip(line, width -| 1)});
    }

    /// The plan as rows `width` cells wide, `epoch` the time now, the stages in `unfolded` shown
    /// a row to a ticket.
    pub fn build(s: *Sheet, given: *const tickets.Plan, b: *const tickets.Board, width: usize, epoch: i64, unfolded: u8, narrow: bool, bench: bool, shut: Shut) void {
        s.narrow = narrow;
        s.bench = bench;
        s.shut = shut;
        s.n = 0;
        s.picks = 0;
        s.used = 0;
        if (bench) return s.windowRows(given, b, width, epoch);
        s.nowRows(given, width, epoch, unfolded);
        s.nextRows(given, width);
        s.goalRows(given, width);
        s.ideaRows(given, width, epoch, unfolded);
        s.add(.{ .kind = .blank });
        s.landedRow(given, b, width);
        s.unplannedRow(given, width);
    }

    /// Starts `win`'s rows; true when it is folded, and its summary is all it holds.
    fn begin(s: *Sheet, win: Window) bool {
        s.cur = win;
        s.from = s.n;
        return s.shut.contains(win);
    }

    fn summaryRow(s: *Sheet, text: []const u8) void {
        s.add(.{ .kind = .summary, .pick = 0, .style = .dim, .text = text });
    }

    /// Ends a window's rows; a window with none says `empty`.
    fn end(s: *Sheet, empty: []const u8) void {
        if (s.n == s.from) s.add(.{ .kind = .note, .style = .dim, .text = empty });
    }

    /// Workbench's plan: each window's rows, in the order the pick walks them.
    fn windowRows(s: *Sheet, given: *const tickets.Plan, b: *const tickets.Board, width: usize, epoch: i64) void {
        if (s.begin(.driving)) s.summaryRow(s.drivingSummary(given)) else if (focalGoal(given.goals)) |at| {
            s.add(.{ .kind = .focal, .item = at, .part = 1, .pick = 0, .ticket = given.goals[at].epic });
            s.add(.{ .kind = .focal, .item = at, .part = 2 });
            s.add(.{ .kind = .focal, .item = at, .part = 3 });
        }
        s.end("no goal yet");
        if (s.begin(.now)) s.summaryRow(s.nowSummary(given)) else s.buildingRows(given, width, epoch);
        s.end("none");
        if (s.begin(.landing)) s.summaryRow(s.landingSummary(given)) else s.pipelineRows(given, width, epoch, 0);
        s.end("none");
        if (s.begin(.next)) s.summaryRow(s.nextSummary(given)) else s.nextRows(given, width);
        s.end("none");
        if (s.begin(.goals)) s.summaryRow(s.goalsSummary(given)) else {
            s.goalRows(given, width);
            s.ideaRows(given, width, epoch, 0);
        }
        s.end("none");
        if (s.begin(.unplanned)) s.summaryRow(s.unplannedSummary(given)) else s.unplannedRow(given, width);
        s.end("none");
        if (s.begin(.landed)) s.summaryRow(s.landedSummary(given, b)) else s.landedRow(given, b, width);
        s.end("none");
    }

    fn drivingSummary(s: *Sheet, given: *const tickets.Plan) []const u8 {
        const goal = given.goals[focalGoal(given.goals) orelse return "no goal yet"];
        return s.print("#{d} {s}  {d}/{d}", .{ goal.epic, goal.title, goal.landed, goal.total });
    }

    fn nowSummary(s: *Sheet, given: *const tickets.Plan) []const u8 {
        var working: usize = 0;
        var stalled: usize = 0;
        for (given.now) |item| if (building(item)) {
            if (item.stalled != null) stalled += 1 else working += 1;
        };
        if (stalled == 0) return s.print("◐ {d} building", .{working});
        return s.print("◐ {d} building · ◇ {d} stalled", .{ working, stalled });
    }

    fn landingSummary(s: *Sheet, given: *const tickets.Plan) []const u8 {
        const start = s.used;
        var done: [8][]const u8 = undefined;
        var stages: usize = 0;
        for (given.now) |item| {
            if (building(item)) continue;
            const name = item.stage orelse "";
            const seen = for (done[0..stages]) |was| {
                if (std.mem.eql(u8, was, name)) break true;
            } else false;
            if (seen or stages == done.len) continue;
            done[stages] = name;
            stages += 1;
            var count: usize = 0;
            for (given.now) |other| count += @intFromBool(inStage(other, name));
            _ = s.print("{s}{s} {d}", .{ if (stages == 1) "◒ " else " · ", name, count });
        }
        if (stages == 0) return "◒ none";
        return s.buf[start..s.used];
    }

    fn nextSummary(s: *Sheet, given: *const tickets.Plan) []const u8 {
        if (given.next.len == 0) return "none";
        const start = s.used;
        for (given.next[0..@min(given.next.len, next_summary)], 1..) |item, place_n| {
            _ = s.print("{s}{d} #{d}", .{ if (place_n == 1) "" else " · ", place_n, item.ticket });
        }
        if (given.next.len > next_summary) _ = s.print(" …", .{});
        return s.buf[start..s.used];
    }

    fn goalsSummary(s: *Sheet, given: *const tickets.Plan) []const u8 {
        if (given.goals.len == 0) return "none";
        const start = s.used;
        for (given.goals, 0..) |goal, i| {
            const pct: u32 = if (goal.total == 0) 0 else goal.landed * 100 / goal.total;
            _ = s.print("{s}#{d} {d}%", .{ if (i == 0) "" else " · ", goal.epic, pct });
        }
        return s.buf[start..s.used];
    }

    fn unplannedSummary(s: *Sheet, given: *const tickets.Plan) []const u8 {
        const not = given.not_planned;
        const start = s.used;
        for (not.by_repo.map.keys(), not.by_repo.map.values()) |repo, n| _ = s.print("{s} {d} · ", .{ repo, n });
        _ = s.print("{d} follow-ups", .{not.follow_ups});
        return s.buf[start..s.used];
    }

    fn landedSummary(s: *Sheet, given: *const tickets.Plan, b: *const tickets.Board) []const u8 {
        var trying: usize = 0;
        for (b.cards()) |card| trying += @intFromBool(card.status == .@"try");
        return s.print("▲ {d} to try · ✓ {d} today", .{ trying, given.landed_today.count });
    }

    fn headRow(s: *Sheet, name: []const u8, count: usize) void {
        const text = if (s.bench) name else s.print("{s} {d}", .{ name, count });
        s.add(.{ .kind = .head, .style = .heading, .text = text, .count = count });
    }

    fn building(item: tickets.NowItem) bool {
        return std.mem.eql(u8, item.state, "building");
    }

    fn nowRows(s: *Sheet, given: *const tickets.Plan, width: usize, epoch: i64, unfolded: u8) void {
        s.headRow("now", given.now.len);
        s.buildingRows(given, width, epoch);
        s.pipelineRows(given, width, epoch, unfolded);
    }

    fn buildingRows(s: *Sheet, given: *const tickets.Plan, width: usize, epoch: i64) void {
        for (given.now, 0..) |item, i| if (building(item)) s.nowRow(item, i, width, epoch);
    }

    /// The pipeline's tickets, a stage at a time in the order babylon first names them; in
    /// Workbench's landing window a row to each, which scrolls.
    fn pipelineRows(s: *Sheet, given: *const tickets.Plan, width: usize, epoch: i64, unfolded: u8) void {
        var done: [8][]const u8 = undefined;
        var stages: usize = 0;
        for (given.now) |item| {
            if (building(item)) continue;
            const name = item.stage orelse "";
            const seen = for (done[0..stages]) |was| {
                if (std.mem.eql(u8, was, name)) break true;
            } else false;
            if (seen or stages == done.len) continue;
            done[stages] = name;
            stages += 1;
            s.stageRows(given, name, width, epoch, unfolded);
        }
    }

    fn foldOf(name: []const u8) ?u3 {
        for (folds, 0..) |known, bit| if (std.mem.eql(u8, known, name)) return @intCast(bit);
        return null;
    }

    fn inStage(item: tickets.NowItem, name: []const u8) bool {
        return !building(item) and std.mem.eql(u8, item.stage orelse "", name);
    }

    fn stageRows(s: *Sheet, given: *const tickets.Plan, name: []const u8, width: usize, epoch: i64, unfolded: u8) void {
        var count: usize = 0;
        for (given.now) |item| count += @intFromBool(inStage(item, name));
        const fold = foldOf(name);
        const open = s.bench or if (fold) |bit| unfolded & (@as(u8, 1) << bit) != 0 else true;
        const first: usize = if (fold) |bit| (if (bit == queued_fold or s.narrow) 0 else unfolded_rows) else count;
        var seen: usize = 0;
        for (given.now, 0..) |item, i| {
            if (!inStage(item, name)) continue;
            if (open or seen < first) s.nowRow(item, i, width, epoch);
            seen += 1;
        }
        if (open or count <= first) return;
        s.foldedRow(given, name, count - first, first, width);
    }

    fn nowRow(s: *Sheet, item: tickets.NowItem, at: usize, width: usize, epoch: i64) void {
        const queued = std.mem.eql(u8, item.stage orelse "", "queued");
        const mark: []const u8 = if (item.stalled != null) "◇" else if (item.waiting_on != null) "◷" else if (building(item)) "◐" else if (queued) "»" else "◒";
        var age: [16]u8 = undefined;
        const how = ago(&age, item.since, epoch);
        const state = item.stage orelse item.state;
        var said: [96]u8 = undefined;
        const right = if (item.stalled) |why|
            s.print("stalled · {s}", .{why})
        else if (item.waiting_on) |wait|
            s.print("{s}", .{wait.say(&said)})
        else if (how.len > 0) s.print("{s} · {s}", .{ state, how }) else s.print("{s}", .{state});
        const left = s.print(" {s} #{d} {s: <8} {s}", .{ mark, item.ticket, text_mod.clip(item.repo, 8), item.title });
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

    fn foldedRow(s: *Sheet, given: *const tickets.Plan, name: []const u8, count: usize, skip: usize, width: usize) void {
        const queued = std.mem.eql(u8, name, "queued");
        const start = s.used;
        _ = s.print(" {s} {s} {d}", .{ if (queued) "»" else "◒", name, count });
        var seen: usize = 0;
        var shown: usize = 0;
        for (given.now) |item| {
            if (!inStage(item, name)) continue;
            seen += 1;
            if (seen <= skip) continue;
            var chip: [96]u8 = undefined;
            var th: [16]u8 = undefined;
            const text = if (queued and item.place != null)
                std.fmt.bufPrint(&chip, "  #{d} {s} {s}", .{ item.ticket, item.repo, place(item.place.?, &th) }) catch ""
            else
                std.fmt.bufPrint(&chip, "  #{d} {s}", .{ item.ticket, item.repo }) catch "";
            if (text_mod.cells(s.buf[start..s.used]) + text_mod.cells(text) + 6 > width) break;
            _ = s.print("{s}", .{text});
            shown += 1;
        }
        if (shown < count) _ = s.print("  +{d}", .{count - shown});
        s.add(.{ .kind = .folded, .pick = 0, .fold = foldOf(name), .text = s.buf[start..s.used] });
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
                if (item.why.len > 0 and !s.narrow) s.add(.{ .kind = .why, .style = .dim, .text = s.clipped(width, item.why) });
                continue;
            }
            const right = s.waits(item.waits_on);
            const left = s.print(" {d} #{d} {s: <8} {s}", .{ place_n, item.ticket, text_mod.clip(item.repo, 8), item.title });
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
            name_w = @max(name_w, @min(text_mod.cells(goal.title), 26));
        };
        const per: usize = if (s.bench) 5 else 1;
        const ideas_room: usize = if (given.ideas.len == 0) 0 else idea_rows;
        const room_rows = max_rows -| s.n -| foot_rows -| ideas_room;
        const shown = if (given.goals.len * per <= room_rows) given.goals.len else (room_rows -| 1) / per;
        for (given.goals[0..shown], 0..) |goal, i| {
            if (s.bench) {
                inline for (.{ .card_top, .goal, .goal_bar, .goal_next, .goal_block }) |kind| {
                    s.add(.{ .kind = kind, .item = i, .pick = if (kind == .goal) 0 else null, .ticket = if (kind == .goal) goal.epic else null });
                }
                continue;
            }
            var extra: [96]u8 = undefined;
            const trying = goalTrying(goal);
            const after = if (trying > 0)
                s.print("  {d} of {d}  {s}{s}▲ {d} to try", .{ goal.landed, goal.total, goalExtra(goal, &extra), if (goalExtra(goal, &extra).len > 0) "  " else "", trying })
            else
                s.print("  {d} of {d}  {s}", .{ goal.landed, goal.total, goalExtra(goal, &extra) });
            const name = text_mod.clip(goal.title, name_w);
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

    /// Under a rule, a row to each idea in the order babylon gives them, oldest first; past
    /// three, one row that unfolds them.
    fn ideaRows(s: *Sheet, given: *const tickets.Plan, width: usize, epoch: i64, unfolded: u8) void {
        if (given.ideas.len == 0) return;
        if (!s.bench) s.add(.{ .kind = .blank });
        s.headRow("ideas", given.ideas.len);
        if (given.ideas.len > ideas_shown and unfolded & (@as(u8, 1) << ideas_fold) == 0) {
            s.add(.{ .kind = .ideas_more, .pick = 0, .fold = ideas_fold, .style = .dim, .text = s.print(" +{d} ideas", .{given.ideas.len}) });
            return;
        }
        for (given.ideas, 0..) |idea, i| {
            const state = ideaState(idea);
            var said: [64]u8 = undefined;
            const label = ideaLabel(&said, idea, epoch);
            const asks = state == .planning and idea.asks > 0;
            const right = if (asks) s.print("{s}  ▲ asks you", .{label}) else label;
            const left = s.print(" {s} #{d} {s}", .{ ideaMark(state), idea.epic, idea.title });
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
            .idea => "○",
            .planning => "◐",
            .draft => "☐",
        };
    }

    /// What an idea says of itself on its row, in `buf`: kept for how long, planning for how
    /// long, or its steps drafted and waiting on a look.
    pub fn ideaLabel(buf: []u8, idea: tickets.Idea, epoch: i64) []const u8 {
        var age: [16]u8 = undefined;
        const out = switch (ideaState(idea)) {
            .idea => std.fmt.bufPrint(buf, "idea · kept {s}", .{kept(&age, idea.since, epoch)}),
            .planning => blk: {
                const how = ago(&age, idea.since, epoch);
                break :blk std.fmt.bufPrint(buf, "planning{s}{s}", .{ if (how.len > 0) " · " else "", how });
            },
            .draft => std.fmt.bufPrint(buf, "draft · {d} steps · look", .{idea.steps}),
        };
        return out catch "";
    }

    /// How long an idea has been kept, in whole days once past one.
    fn kept(buf: []u8, since: ?[]const u8, epoch: i64) []const u8 {
        const then = tickets.epochOf(since) orelse return "";
        const days = @divFloor(@max(epoch - then, 0), 86400);
        if (days >= 1) return std.fmt.bufPrint(buf, "{d}d", .{days}) catch "";
        return ago(buf, since, epoch);
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
                _ = s.print("#{d} {s} {s}", .{ id, c.repo orelse "", c.title });
            } else _ = s.print("#{d}", .{id});
        }
        s.add(.{ .kind = .landed, .pick = 0, .text = s.clipped(width, s.buf[start..s.used]) });
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
fn place(n: u32, buf: []u8) []const u8 {
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

test "the plan's rows: building first, a stage's first two tickets, the rest and the queued folded, each said as babylon gives it" {
    var b = try tickets.Board.parse(std.testing.allocator, sample);
    defer b.deinit();
    var s: Sheet = undefined;
    const epoch = tickets.epochOf("2026-11-23T07:10:00Z").?;
    s.build(b.plan().?, &b, 100, epoch, 0, false, false, .empty);
    const eq = std.testing.expectEqualStrings;
    const ok = std.testing.expect;
    try eq("now 7", rowText(&s, .head, 0).?);
    try ok(std.mem.startsWith(u8, rowText(&s, .now, 0).?, " ◐ #600 arena    Design"));
    try ok(std.mem.endsWith(u8, rowText(&s, .now, 0).?, "building · 6m"));
    try ok(std.mem.indexOf(u8, rowText(&s, .now, 1).?, "◇ #510") != null);
    try ok(std.mem.endsWith(u8, rowText(&s, .now, 1).?, "stalled · idle 9m"));
    try ok(std.mem.endsWith(u8, rowText(&s, .now, 2).?, "verifying · 20m"));
    try std.testing.expectEqual(@as(?[]const u8, null), rowText(&s, .now, 4));
    try eq(" ◒ verifying 1  #560 arena", rowText(&s, .folded, 0).?);
    try eq(" » queued 2  #588 babylon 1st  #429 babylon 2nd", rowText(&s, .folded, 1).?);
}

test "an unfolded stage is a row to a ticket" {
    var b = try tickets.Board.parse(std.testing.allocator, sample);
    defer b.deinit();
    var s: Sheet = undefined;
    s.build(b.plan().?, &b, 100, 0, 1 << queued_fold, false, false, .empty);
    try std.testing.expect(rowText(&s, .folded, 1) == null);
    try std.testing.expect(std.mem.indexOf(u8, rowText(&s, .now, 5).?, "» #429") != null);
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
    s.build(b.plan().?, &b, 100, 0, 0, false, false, .empty);
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
    // 2 building, 2 verifying rows, 2 folded, 3 next, 2 goals, landed, not planned
    try std.testing.expectEqual(@as(usize, 2 + 2 + 2 + 3 + 2 + 2), s.picks);
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
    s.build(b.plan().?, &b, 80, tickets.epochOf("2026-11-24T20:04:00Z").?, 0, false, false, .empty);
    try ok(std.mem.eql(u8, rowText(&s, .head, 3).?, "ideas 3"));
    const planning = rowText(&s, .idea, 0).?;
    try ok(std.mem.indexOf(u8, planning, "◐ #830 money") != null);
    try ok(std.mem.indexOf(u8, planning, "planning · 4m  ▲ asks you") != null);
    try ok(std.mem.indexOf(u8, rowText(&s, .idea, 1).?, "☐ #831 retro") != null);
    try ok(std.mem.indexOf(u8, rowText(&s, .idea, 1).?, "draft · 7 steps · look") != null);
    try ok(std.mem.indexOf(u8, rowText(&s, .idea, 2).?, "○ #829 garden") != null);
    try ok(std.mem.indexOf(u8, rowText(&s, .idea, 2).?, "idea · kept 2d") != null);
    try ok(rowText(&s, .ideas_more, 0) == null);

    var four = try tickets.Board.parse(std.testing.allocator,
        \\{"tickets":[],"plan":{"ideas":[
        \\{"epic":1,"title":"a"},{"epic":2,"title":"b"},{"epic":3,"title":"c"},{"epic":4,"title":"d"}]}}
    );
    defer four.deinit();
    s.build(four.plan().?, &four, 80, 0, 0, false, false, .empty);
    try ok(rowText(&s, .idea, 0) == null);
    try ok(std.mem.eql(u8, rowText(&s, .ideas_more, 0).?, " +4 ideas"));
    s.build(four.plan().?, &four, 80, 0, @as(u8, 1) << ideas_fold, false, false, .empty);
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
    s.build(b.plan().?, &b, 100, 0, 0, false, false, .empty);
    try std.testing.expect(std.mem.indexOf(u8, rowText(&s, .goal, 0).?, "1 of 2  ○ #2  ▲ 1 to try") != null);
    try std.testing.expectEqual(@as(u32, 2), goalNext(b.plan().?.goals[0]).?.ticket);
}

test "a row too wide is cut, its right side kept" {
    var b = try tickets.Board.parse(std.testing.allocator, sample);
    defer b.deinit();
    var s: Sheet = undefined;
    s.build(b.plan().?, &b, 40, 0, 0, false, false, .empty);
    for (s.rows[0..s.n]) |row| try std.testing.expect(text_mod.cells(row.text) <= 40);
    try std.testing.expect(std.mem.endsWith(u8, rowText(&s, .now, 0).?, "building · now"));
}

test "the focal goal is the first with a step being built, a card is five rows, and its next and blocker are its steps" {
    var b = try tickets.Board.parse(std.testing.allocator, sample);
    defer b.deinit();
    const given = b.plan().?;
    try std.testing.expectEqual(@as(?usize, 0), focalGoal(given.goals));
    try std.testing.expectEqual(@as(u32, 453), goalNext(given.goals[0]).?.ticket);
    try std.testing.expectEqual(@as(u32, 454), goalBlock(given.goals[0]).?.step);
    try std.testing.expectEqual(@as(u32, 453), goalBlock(given.goals[0]).?.on);
    var s: Sheet = undefined;
    s.build(given, &b, 100, 0, 0, false, true, .empty);
    try std.testing.expectEqual(Kind.focal, s.rows[0].kind);
    try std.testing.expectEqual(@as(usize, 0), s.rows[0].pick.?);
    var cards: usize = 0;
    for (s.rows[0..s.n]) |row| cards += @intFromBool(row.kind == .card_top);
    try std.testing.expectEqual(@as(usize, 2), cards);
}

test "goals past what fits fold into one row, and landed and not planned keep theirs" {
    var buf: [8192]u8 = undefined;
    var used = (try std.fmt.bufPrint(&buf, "{{\"tickets\":[],\"plan\":{{\"now\":[],\"next\":[],\"goals\":[", .{})).len;
    for (0..30) |i| {
        used += (try std.fmt.bufPrint(buf[used..], "{s}{{\"epic\":{d},\"title\":\"g{d}\",\"total\":2,\"landed\":1,\"steps\":[{{\"ticket\":1,\"state\":\"landed\"}},{{\"ticket\":2,\"state\":\"next\"}}]}}", .{ if (i > 0) "," else "", 100 + i, i })).len;
    }
    used += (try std.fmt.bufPrint(buf[used..], "],\"landed_today\":{{\"count\":0,\"newest\":[]}},\"not_planned\":{{\"count\":0,\"follow_ups\":0,\"by_repo\":{{}}}}}}}}", .{})).len;
    var b = try tickets.Board.parse(std.testing.allocator, buf[0..used]);
    defer b.deinit();
    var s: Sheet = undefined;
    s.build(b.plan().?, &b, 100, 0, 0, false, true, .empty);
    try std.testing.expect(rowText(&s, .landed, 0) != null);
    try std.testing.expect(rowText(&s, .unplanned, 0) != null);
    try std.testing.expect(std.mem.indexOf(u8, rowText(&s, .goals_more, 0).?, "more goals") != null);
}

test "a now row waiting on a ticket says so, with its own mark, and is not drawn as stalled" {
    var b = try tickets.Board.parse(std.testing.allocator,
        \\{"tickets":[],"plan":{"now":[
        \\{"ticket":505,"repo":"arena","title":"Parked","state":"building","since":"2026-11-23T07:00:00Z","pane":"%580","waiting_on":{"ticket":829,"for":null,"since":"2026-11-23T07:01:00Z"}}]}}
    );
    defer b.deinit();
    var s: Sheet = undefined;
    s.build(b.plan().?, &b, 100, tickets.epochOf("2026-11-23T07:10:00Z").?, 0, false, false, .empty);
    const row = rowText(&s, .now, 0).?;
    try std.testing.expect(std.mem.indexOf(u8, row, "◷ #505") != null);
    try std.testing.expect(std.mem.endsWith(u8, row, "◷ waiting on #829"));
    try std.testing.expect(std.mem.indexOf(u8, row, "stalled") == null);
}
