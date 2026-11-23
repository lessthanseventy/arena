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

pub const Kind = enum { head, blank, now, folded, next, why, more, goal, landed, unplanned };
pub const Style = enum { normal, dim, heading, attention };

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
};

pub const Sheet = struct {
    rows: [max_rows]Row = undefined,
    n: usize = 0,
    picks: usize = 0,
    buf: [32 * 1024]u8 = undefined,
    used: usize = 0,

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
    pub fn build(s: *Sheet, given: *const tickets.Plan, b: *const tickets.Board, width: usize, epoch: i64, unfolded: u8) void {
        s.n = 0;
        s.picks = 0;
        s.used = 0;
        s.nowRows(given, width, epoch, unfolded);
        s.nextRows(given, width);
        s.goalRows(given, width);
        s.add(.{ .kind = .blank });
        s.landedRow(given, b, width);
        s.unplannedRow(given, width);
    }

    fn headRow(s: *Sheet, name: []const u8, count: usize) void {
        s.add(.{ .kind = .head, .style = .heading, .text = s.print("{s} {d}", .{ name, count }) });
    }

    fn building(item: tickets.NowItem) bool {
        return std.mem.eql(u8, item.state, "building");
    }

    fn nowRows(s: *Sheet, given: *const tickets.Plan, width: usize, epoch: i64, unfolded: u8) void {
        s.headRow("now", given.now.len);
        for (given.now) |item| if (building(item)) s.nowRow(item, width, epoch);
        // the pipeline's tickets, a stage at a time in the order babylon first names them
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
        const open = if (fold) |bit| unfolded & (@as(u8, 1) << bit) != 0 else true;
        const first: usize = if (fold) |bit| (if (bit == queued_fold) 0 else unfolded_rows) else count;
        var seen: usize = 0;
        for (given.now) |item| {
            if (!inStage(item, name)) continue;
            if (open or seen < first) s.nowRow(item, width, epoch);
            seen += 1;
        }
        if (open or count <= first) return;
        s.foldedRow(given, name, count - first, first, width);
    }

    fn nowRow(s: *Sheet, item: tickets.NowItem, width: usize, epoch: i64) void {
        const queued = std.mem.eql(u8, item.stage orelse "", "queued");
        const mark: []const u8 = if (item.stalled != null) "◇" else if (building(item)) "◐" else if (queued) "»" else "◒";
        var age: [16]u8 = undefined;
        const how = ago(&age, item.since, epoch);
        const state = item.stage orelse item.state;
        const right = if (item.stalled) |why|
            s.print("stalled · {s}", .{why})
        else if (how.len > 0) s.print("{s} · {s}", .{ state, how }) else s.print("{s}", .{state});
        const left = s.print(" {s} #{d} {s: <8} {s}", .{ mark, item.ticket, text_mod.clip(item.repo, 8), item.title });
        const both = s.spread(width, left, right);
        s.add(.{
            .kind = .now,
            .pick = 0,
            .ticket = item.ticket,
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
        s.add(.{ .kind = .blank });
        s.headRow("next", given.next.len);
        for (given.next[0..@min(given.next.len, next_shown)], 1..) |item, place_n| {
            const right = s.waits(item.waits_on);
            const left = s.print(" {d} #{d} {s: <8} {s}", .{ place_n, item.ticket, text_mod.clip(item.repo, 8), item.title });
            const both = s.spread(width, left, right);
            s.add(.{ .kind = .next, .pick = 0, .ticket = item.ticket, .text = both.text, .tail_at = both.tail_at });
            if (item.why.len > 0) s.add(.{ .kind = .why, .style = .dim, .text = s.clipped(width, s.print("      {s}", .{item.why})) });
        }
        if (given.next.len > next_shown) s.add(.{ .kind = .more, .style = .dim, .text = s.print("  +{d}", .{given.next.len - next_shown}) });
    }

    /// What an item waits on, as babylon says it: a ticket, or its repo's lane until one lands.
    fn waits(s: *Sheet, on: []const tickets.Wait) []const u8 {
        if (on.len == 0) return "free now";
        const start = s.used;
        for (on, 0..) |wait, i| {
            const sep: []const u8 = if (i == 0) "← " else ", ";
            if (wait.ticket) |t| {
                _ = s.print("{s}needs #{d}", .{ sep, t });
            } else if (wait.lane) |lane| {
                _ = s.print("{s}after #{d} lands: one {s}", .{ sep, wait.until orelse 0, lane });
            }
        }
        return s.buf[start..s.used];
    }

    fn goalRows(s: *Sheet, given: *const tickets.Plan, width: usize) void {
        s.add(.{ .kind = .blank });
        s.headRow("goals", given.goals.len);
        var name_w: usize = 0;
        for (given.goals) |goal| name_w = @max(name_w, @min(text_mod.cells(goal.title), 26));
        for (given.goals) |goal| {
            var extra: [96]u8 = undefined;
            const after = s.print("  {d} of {d}  {s}", .{ goal.landed, goal.total, goalExtra(goal, &extra) });
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
    }

    fn stepMark(state: []const u8) []const u8 {
        const marks = [_][2][]const u8{
            .{ "landed", "✓" },
            .{ "building", "◐" },
            .{ "landing", "◒" },
            .{ "next", "●" },
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
            if (std.mem.eql(u8, mark, "✓") or std.mem.eql(u8, mark, "○") or std.mem.eql(u8, mark, "✗")) continue;
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
fn ago(buf: []u8, since: ?[]const u8, epoch: i64) []const u8 {
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
    s.build(b.plan().?, &b, 100, epoch, 0);
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
    s.build(b.plan().?, &b, 100, 0, 1 << queued_fold);
    try std.testing.expect(rowText(&s, .folded, 1) == null);
    try std.testing.expect(std.mem.indexOf(u8, rowText(&s, .now, 5).?, "» #429") != null);
}

test "next says what each waits on and why, goals their steps, and the picks run through every row that can be" {
    var b = try tickets.Board.parse(std.testing.allocator, sample);
    defer b.deinit();
    var s: Sheet = undefined;
    s.build(b.plan().?, &b, 100, 0, 0);
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

test "a row too wide is cut, its right side kept" {
    var b = try tickets.Board.parse(std.testing.allocator, sample);
    defer b.deinit();
    var s: Sheet = undefined;
    s.build(b.plan().?, &b, 40, 0, 0);
    for (s.rows[0..s.n]) |row| try std.testing.expect(text_mod.cells(row.text) <= 40);
    try std.testing.expect(std.mem.endsWith(u8, rowText(&s, .now, 0).?, "building · now"));
}
