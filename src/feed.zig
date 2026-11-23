//! The feed atop the orchestrator's column: the human's move as babylon gives it, then what is
//! landing and building, and how many landed today.
const std = @import("std");
const tickets = @import("board.zig");
const Card = tickets.Card;

pub const Kind = enum { move_head, quiet, item, buttons, more, head, chips, landed };

pub const Line = struct {
    kind: Kind,
    /// Of a send-back of Your move: drawn in a send-back's colour.
    failed: bool = false,
    text: []const u8,
};

/// Lines and the text they point into: Your move's, or what follows it.
const Part = struct {
    lines: [48]Line = undefined,
    n: usize = 0,
    /// The line each Your move item starts on.
    starts: [24]usize = undefined,
    items: usize = 0,
    buf: [4096]u8 = undefined,
    used: usize = 0,

    fn add(p: *Part, kind: Kind, failed: bool, comptime fmt: []const u8, args: anytype) void {
        if (p.n == p.lines.len) return;
        const text = std.fmt.bufPrint(p.buf[p.used..], fmt, args) catch return;
        p.used += text.len;
        p.lines[p.n] = .{ .kind = kind, .failed = failed, .text = text };
        p.n += 1;
    }

    /// `chips` laid along at most `rows` lines of `width` cells, three spaces apart, then `+N`
    /// for those left over.
    fn flow(p: *Part, chips: []const []const u8, rows: usize, width: usize) void {
        var at: usize = 0;
        for (0..rows) |row| {
            if (at == chips.len) return;
            const last = row + 1 == rows;
            var line: [256]u8 = undefined;
            var w: std.Io.Writer = .fixed(&line);
            var cells: usize = 0;
            while (at < chips.len) : (at += 1) {
                // a chip whose age babylon has no time for ends without one
                const text = std.mem.trimEnd(u8, chips[at], " ");
                const chip = cellCount(text);
                const gap: usize = if (cells == 0) 0 else 3;
                // the last row keeps room for the count of those that do not fit
                const keep: usize = if (last and at + 1 < chips.len) 6 else 0;
                if (cells > 0 and cells + gap + chip + keep > width) break;
                w.splatByteAll(' ', gap) catch break;
                w.writeAll(text) catch break;
                cells += gap + chip;
            }
            if (last and at < chips.len) w.print("   +{d}", .{chips.len - at}) catch {};
            p.add(.chips, false, "{s}", .{w.buffered()});
        }
    }
};

pub const Feed = struct {
    move: Part = .{},
    rest: Part = .{},
    /// The lines of Your move shown, and the items shown of it.
    shown: usize = 0,
    items_shown: usize = 0,
    more: [32]u8 = undefined,

    /// How many lines it takes.
    pub fn count(f: *const Feed) usize {
        return f.shown + @intFromBool(f.cut()) + f.rest.n;
    }

    /// Line `i` of it, from the top.
    pub fn line(f: *const Feed, i: usize) Line {
        if (i < f.shown) return f.move.lines[i];
        if (f.cut() and i == f.shown) return .{ .kind = .more, .text = f.moreText() };
        return f.rest.lines[i - f.shown - @intFromBool(f.cut())];
    }

    fn cut(f: *const Feed) bool {
        return f.items_shown < f.move.items;
    }

    fn moreText(f: *const Feed) []const u8 {
        const buf: *[32]u8 = @constCast(&f.more);
        return std.fmt.bufPrint(buf, "↓ {d} more", .{f.move.items - f.items_shown}) catch "";
    }
};

/// The feed for `board`, its lines `width` cells wide and at most `room` of them, as of `epoch`, in
/// a day that began at `today`. Your move keeps its head and first item; the rest of it is cut to
/// whole items, and what follows is cut to what is left.
pub fn build(f: *Feed, board: *const tickets.Board, width: usize, room: usize, epoch: i64, today: i64) void {
    f.* = .{};
    const needs = board.needsYou();
    if (needs.len == 0) f.move.add(.quiet, false, "nothing needs you", .{});
    if (needs.len > 0) f.move.add(.move_head, false, "▲ your move {d}", .{needs.len});
    for (needs) |need| {
        if (f.move.items == f.move.starts.len) break;
        const failed = std.mem.eql(u8, need.kind, "sendback");
        f.move.starts[f.move.items] = f.move.n;
        f.move.items += 1;
        f.move.add(.item, failed, "{s}", .{need.text});
        var chips: [12][]const u8 = undefined;
        var bufs: [12][96]u8 = undefined;
        var n: usize = 0;
        for (need.actions) |action| {
            if (n == chips.len) break;
            chips[n] = std.fmt.bufPrint(&bufs[n], "{s} {s}", .{ action.key, action.label }) catch continue;
            n += 1;
        }
        const before = f.move.n;
        f.move.flow(chips[0..n], 4, width -| 4);
        for (f.move.lines[before..f.move.n]) |*l| {
            l.kind = .buttons;
            l.failed = failed;
        }
    }

    landing(&f.rest, board, width, epoch);
    building(&f.rest, board, width, epoch);
    var landed: usize = 0;
    for (board.cards()) |card| {
        const stage = card.stage orelse continue;
        if (std.mem.eql(u8, stage, "landed") and (tickets.epochOf(card.closed_at) orelse 0) >= today) landed += 1;
    }
    f.rest.add(.landed, false, "✓ landed today {d}", .{landed});

    const floor = if (f.move.items > 0) @min(f.move.n, f.move.starts[0] + 2) else f.move.n;
    var want = @max(floor, room -| f.rest.n);
    if (f.move.n <= want) {
        f.shown = f.move.n;
        f.items_shown = f.move.items;
    } else {
        // whole items only, and a line kept for how many more there are
        want -|= 1;
        var k = f.move.items - 1;
        while (k > 1 and f.move.starts[k] > want) k -= 1;
        f.items_shown = @max(1, k);
        f.shown = if (f.items_shown < f.move.items) f.move.starts[f.items_shown] else f.move.n;
    }
    f.rest.n = @min(f.rest.n, room -| (f.count() - f.rest.n));
}

fn landing(p: *Part, board: *const tickets.Board, width: usize, epoch: i64) void {
    var queue: [64]*const Card = undefined;
    var n: usize = 0;
    for (board.cards()) |*card| {
        if (card.status != .review or isFailed(card) or n == queue.len) continue;
        queue[n] = card;
        n += 1;
    }
    if (n == 0) return;
    // board.json carries no queue order: the pipeline takes tickets in the order they were handed
    // in, those it is working on first
    std.mem.sort(*const Card, queue[0..n], {}, struct {
        fn before(_: void, a: *const Card, z: *const Card) bool {
            if (running(a) != running(z)) return running(a);
            return handedIn(a) < handedIn(z) or (handedIn(a) == handedIn(z) and a.id < z.id);
        }
    }.before);
    p.add(.head, false, "◒ landing {d}", .{n});
    var chips: [64][]const u8 = undefined;
    var bufs: [64][80]u8 = undefined;
    var queued: usize = 0;
    for (queue[0..n], 0..) |card, i| {
        var when: [8]u8 = undefined;
        const at = age(&when, epoch, tickets.epochOf(card.submitted_at));
        chips[i] = if (running(card))
            std.fmt.bufPrint(&bufs[i], "#{d} {s} {s} {s}", .{ card.id, card.repo orelse "", card.stage.?, at }) catch ""
        else blk: {
            queued += 1;
            break :blk std.fmt.bufPrint(&bufs[i], "#{d} {s} queued {d}{s}", .{ card.id, card.repo orelse "", queued, ordinal(queued) }) catch "";
        };
    }
    p.flow(chips[0..n], 2, width);
}

fn building(p: *Part, board: *const tickets.Board, width: usize, epoch: i64) void {
    var held: [64]*const Card = undefined;
    var n: usize = 0;
    for (board.cards()) |*card| {
        if (std.mem.eql(u8, card.kind, "epic") or n == held.len) continue;
        const sent_back = isFailed(card) and card.status != .done;
        // a free send-back is the human's move, not building
        const doing = if (sent_back) card.holder() != null or card.blocked_by.len > 0 else card.status == .doing;
        if (!doing) continue;
        held[n] = card;
        n += 1;
    }
    if (n == 0) return;
    std.mem.sort(*const Card, held[0..n], {}, struct {
        fn before(_: void, a: *const Card, z: *const Card) bool {
            const at_a = a.claimedAt() orelse std.math.maxInt(i64);
            const at_z = z.claimedAt() orelse std.math.maxInt(i64);
            return at_a < at_z or (at_a == at_z and a.id < z.id);
        }
    }.before);
    p.add(.head, false, "◐ building {d}", .{n});
    var chips: [64][]const u8 = undefined;
    var bufs: [64][80]u8 = undefined;
    for (held[0..n], 0..) |card, i| {
        var when: [8]u8 = undefined;
        const at = age(&when, epoch, card.claimedAt());
        const repo = card.repo orelse "";
        chips[i] = (if (isFailed(card) and card.holder() == null)
            std.fmt.bufPrint(&bufs[i], "✗ #{d} {s} waits on #{d}", .{ card.id, repo, card.blocked_by[0] })
        else if (isFailed(card))
            std.fmt.bufPrint(&bufs[i], "✗ #{d} {s} {s}", .{ card.id, repo, at })
        else if (card.ask != null)
            std.fmt.bufPrint(&bufs[i], "#{d} {s} ▲ {s}", .{ card.id, repo, at })
        else if (card.holder() == null)
            std.fmt.bufPrint(&bufs[i], "#{d} {s} ○ {s}", .{ card.id, repo, at })
        else
            std.fmt.bufPrint(&bufs[i], "#{d} {s} {s}", .{ card.id, repo, at })) catch "";
    }
    p.flow(chips[0..n], 2, width);
}

fn isFailed(card: *const Card) bool {
    return std.mem.eql(u8, card.stage orelse "", "failed");
}

fn running(card: *const Card) bool {
    const stage = card.stage orelse return false;
    for ([_][]const u8{ "verifying", "reviewing", "landing" }) |busy| if (std.mem.eql(u8, stage, busy)) return true;
    return false;
}

fn handedIn(card: *const Card) i64 {
    return tickets.epochOf(card.submitted_at) orelse card.claimedAt() orelse 0;
}

fn ordinal(n: usize) []const u8 {
    if (n % 100 >= 11 and n % 100 <= 13) return "th";
    return switch (n % 10) {
        1 => "st",
        2 => "nd",
        3 => "rd",
        else => "th",
    };
}

fn age(buf: []u8, epoch: i64, since: ?i64) []const u8 {
    const at = since orelse return "";
    const s = @max(0, epoch - at);
    return (if (s < 3600)
        std.fmt.bufPrint(buf, "{d}m", .{@divFloor(s, 60)})
    else if (s < 86400)
        std.fmt.bufPrint(buf, "{d}h", .{@divFloor(s, 3600)})
    else
        std.fmt.bufPrint(buf, "{d}d", .{@min(99, @divFloor(s, 86400))})) catch "";
}

fn cellCount(text: []const u8) usize {
    return std.unicode.utf8CountCodepoints(text) catch text.len;
}

const now = 1795262400; // 2026-11-21T12:00:00Z

const sample =
    \\{"tickets":[
    \\{"id":7,"repo":"arena","title":"A todo card","status":"todo"},
    \\{"id":14,"repo":"arena","title":"A pane","status":"doing","claimed_by":"%3","claimed_at":"2026-11-21T10:00:00Z"},
    \\{"id":16,"repo":"arena","title":"Which colour","status":"doing","claimed_by":"%4","claimed_at":"2026-11-21T09:00:00Z","ask":{"id":3,"question":"Blue?"}},
    \\{"id":21,"repo":"tlon","title":"Nobody","status":"doing","claimed_at":"2026-11-19T09:00:00Z"},
    \\{"id":495,"repo":"arena","title":"Held after a send-back","status":"doing","claimed_by":"%610","claimed_at":"2026-11-21T11:00:00Z","stage":"failed"},
    \\{"id":362,"repo":"arena","title":"Blocked after a send-back","status":"todo","stage":"failed","blocked_by":[361]},
    \\{"id":12,"repo":"arena","title":"Free after a send-back","status":"todo","stage":"failed"},
    \\{"id":17,"repo":"arena","title":"Queued later","status":"review","stage":"queued","submitted_at":"2026-11-21T11:30:00Z"},
    \\{"id":18,"repo":"tlon","title":"Queued first","status":"review","stage":"queued","submitted_at":"2026-11-21T11:10:00Z"},
    \\{"id":15,"repo":"babylon","title":"Reviewing","status":"review","stage":"reviewing","submitted_at":"2026-11-21T11:58:00Z"},
    \\{"id":20,"repo":"arena","title":"An epic","kind":"epic","status":"doing"},
    \\{"id":9,"repo":"arena","title":"Landed today","status":"done","stage":"landed","closed_at":"2026-11-21T11:30:00Z"},
    \\{"id":8,"repo":"arena","title":"Landed long ago","status":"done","stage":"landed","closed_at":"2026-11-19T08:00:00Z"}],
    \\"needs_you":[
    \\{"id":"proposal:4","kind":"proposal","ticket":7,"repo":"arena","text":"P4 Start #7: Next in line",
    \\ "actions":[{"key":"⏎","label":"go","argv":["babylon","go","4"]},{"key":"x","label":"no","argv":["babylon","no","4"]}]},
    \\{"id":"ask:3","kind":"ask","ticket":16,"repo":"arena","text":"#16 arena  asks: Blue?",
    \\ "actions":[{"key":"1","label":"Blue","argv":["babylon","answer","3","1"]},{"key":"c","label":"in words","argv":null,"needs":"words"}]},
    \\{"id":"sendback:12","kind":"sendback","ticket":12,"repo":"arena","text":"✗ #12 arena  sent back, free: red",
    \\ "actions":[{"key":"G","label":"give","argv":null,"needs":"pick"},{"key":"⏎","label":"start","argv":null,"needs":"surface"}]}]}
;

fn texts(f: *const Feed, out: [][]const u8) [][]const u8 {
    for (0..f.count()) |i| out[i] = f.line(i).text;
    return out[0..f.count()];
}

test "the feed draws babylon's needs_you as given, then landing in queue order, building and today's landings" {
    var b = try tickets.Board.parse(std.testing.allocator, sample);
    defer b.deinit();
    var f: Feed = undefined;
    build(&f, &b, 56, 40, now, now - 12 * 3600);
    var out: [64][]const u8 = undefined;
    const want = [_][]const u8{
        "▲ your move 3",
        "P4 Start #7: Next in line",
        "⏎ go   x no",
        "#16 arena  asks: Blue?",
        "1 Blue   c in words",
        "✗ #12 arena  sent back, free: red",
        "G give   ⏎ start",
        "◒ landing 3",
        "#15 babylon reviewing 2m   #18 tlon queued 1st",
        "#17 arena queued 2nd",
        "◐ building 5",
        "#21 tlon ○ 2d   #16 arena ▲ 3h   #14 arena 2h",
        "✗ #495 arena 1h   ✗ #362 arena waits on #361",
        "✓ landed today 1",
    };
    const got = texts(&f, &out);
    try std.testing.expectEqual(want.len, got.len);
    for (want, got) |w, g| try std.testing.expectEqualStrings(w, g);
    try std.testing.expect(f.line(5).failed and f.line(6).failed and f.line(6).kind == .buttons);
    try std.testing.expect(!f.line(1).failed);
}

test "a short column cuts Your move to whole items and says how many more, and keeps the rest" {
    var b = try tickets.Board.parse(std.testing.allocator, sample);
    defer b.deinit();
    var f: Feed = undefined;
    build(&f, &b, 56, 11, now, 0);
    try std.testing.expectEqual(@as(usize, 11), f.count());
    try std.testing.expectEqualStrings("⏎ go   x no", f.line(2).text);
    try std.testing.expectEqualStrings("↓ 2 more", f.line(3).text);
    try std.testing.expectEqualStrings("◒ landing 3", f.line(4).text);
    try std.testing.expectEqualStrings("✓ landed today 2", f.line(10).text);
}

test "with nothing that needs the human, the feed shrinks to one dim line above the rest" {
    var b = try tickets.Board.parse(std.testing.allocator,
        \\{"tickets":[{"id":1,"title":"a","status":"todo"}],"needs_you":[]}
    );
    defer b.deinit();
    var f: Feed = undefined;
    build(&f, &b, 56, 20, now, 0);
    try std.testing.expectEqual(@as(usize, 2), f.count());
    try std.testing.expectEqual(Kind.quiet, f.line(0).kind);
    try std.testing.expectEqualStrings("✓ landed today 0", f.line(1).text);
}
