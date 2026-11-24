//! The feed atop the orchestrator's column: the human's move as babylon gives it, then what is
//! landing and building, and how many landed today.
const std = @import("std");
const tickets = @import("board.zig");
const Card = tickets.Card;

pub const Kind = enum { move_head, quiet, item, buttons, refused, next_refused, more, next_head, next_item, landing_head, building_head, landing_chips, building_chips, landed };

/// babylon's refusal of what was asked of a Your move item, by the item's id: said in place of
/// its buttons.
pub const Refusal = struct { id: []const u8, text: []const u8 };

/// Something in the feed the pick can be on: a Your move item, its whole first line, a ticket in
/// next, or a ticket landing or building, `w` cells of its line from `at`.
pub const Item = struct {
    line: usize,
    at: usize = 0,
    w: usize = 0,
    ticket: ?u32 = null,
    /// Its place in babylon's needs_you, for a Your move item.
    need: ?usize = null,
    /// Its place in next, for a ticket there.
    next: ?usize = null,
};

/// What the pick can be on in the rest of the feed: a ticket's chip on a line of landing or
/// building, or a ticket of next.
const Spot = struct {
    line: usize,
    at: usize = 0,
    w: usize = 0,
    ticket: ?u32 = null,
    next: ?usize = null,
};

pub const Line = struct {
    kind: Kind,
    /// Of a send-back of Your move: drawn in a send-back's colour.
    failed: bool = false,
    text: []const u8,
    /// Of a Your move item's row: its place in babylon's needs_you.
    need: ?usize = null,
    /// What a line of next says in place of its title while it is the pick.
    alt: []const u8 = "",
};

/// Lines and the text they point into: Your move's, or what follows it.
const Part = struct {
    lines: [48]Line = undefined,
    n: usize = 0,
    /// The line each Your move item starts on, and its ticket.
    starts: [24]usize = undefined,
    tickets: [24]?u32 = undefined,
    items: usize = 0,
    /// How many items babylon gave, of which `items` are held.
    total: usize = 0,
    buf: [4096]u8 = undefined,
    used: usize = 0,
    spots: [96]Spot = undefined,
    n_spots: usize = 0,

    fn add(p: *Part, kind: Kind, failed: bool, comptime fmt: []const u8, args: anytype) void {
        if (p.n == p.lines.len) return;
        const text = std.fmt.bufPrint(p.buf[p.used..], fmt, args) catch return;
        p.used += text.len;
        p.lines[p.n] = .{ .kind = kind, .failed = failed, .text = text };
        p.n += 1;
    }

    fn alt(p: *Part, comptime fmt: []const u8, args: anytype) void {
        if (p.n == 0) return;
        const text = std.fmt.bufPrint(p.buf[p.used..], fmt, args) catch return;
        p.used += text.len;
        p.lines[p.n - 1].alt = text;
    }

    fn spot(p: *Part, s: Spot) void {
        if (p.n_spots == p.spots.len) return;
        p.spots[p.n_spots] = s;
        p.n_spots += 1;
    }

    /// `chips` laid along at most `rows` lines of `width` cells, three spaces apart, then `+N`
    /// for those left over. With `ids`, each chip laid is a spot for that ticket.
    fn flow(p: *Part, kind: Kind, chips: []const []const u8, ids: []const u32, rows: usize, width: usize) void {
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
                if (at < ids.len and p.n_spots < p.spots.len) {
                    p.spots[p.n_spots] = .{ .line = p.n, .at = cells + gap, .w = chip, .ticket = ids[at] };
                    p.n_spots += 1;
                }
                cells += gap + chip;
            }
            if (last and at < chips.len) w.print("   +{d}", .{chips.len - at}) catch {};
            p.add(kind, false, "{s}", .{w.buffered()});
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
        return f.items_shown < f.move.total;
    }

    /// How many things the pick can be on.
    pub fn itemCount(f: *const Feed) usize {
        var n = f.items_shown;
        for (f.rest.spots[0..f.rest.n_spots]) |spot| n += @intFromBool(spot.line < f.rest.n);
        return n;
    }

    /// The `i`th thing the pick can be on: Your move's items first, then next's, then landing,
    /// then building.
    pub fn item(f: *const Feed, i: usize) ?Item {
        if (i < f.items_shown) return .{ .line = f.move.starts[i], .ticket = f.move.tickets[i], .need = i };
        const at = i - f.items_shown;
        if (at >= f.rest.n_spots) return null;
        const spot = f.rest.spots[at];
        if (spot.line >= f.rest.n) return null;
        return .{
            .line = f.shown + @intFromBool(f.cut()) + spot.line,
            .at = spot.at,
            .w = spot.w,
            .ticket = spot.ticket,
            .next = spot.next,
        };
    }

    fn moreText(f: *const Feed) []const u8 {
        const buf: *[32]u8 = @constCast(&f.more);
        return std.fmt.bufPrint(buf, "↓ {d} more", .{f.move.total - f.items_shown}) catch "";
    }
};

/// The feed for `board`, its lines `width` cells wide and at most `room` of them, as of `epoch`, in
/// a day that began at `today`. Your move keeps its head and first item; the rest of it is cut to
/// whole items, and what follows is cut to what is left. An item babylon refused says why in place
/// of its buttons.
pub fn build(f: *Feed, board: *const tickets.Board, refused: []const Refusal, width: usize, room: usize, epoch: i64, today: i64) void {
    f.* = .{};
    const needs = board.needsYou();
    if (needs.len == 0) f.move.add(.quiet, false, "nothing needs you", .{});
    if (needs.len > 0) f.move.add(.move_head, false, "▲ your move {d}", .{needs.len});
    f.move.total = needs.len;
    for (needs, 0..) |need, need_at| {
        // an item is held whole or not at all: its row, a refusal or up to four rows of buttons
        if (f.move.items == f.move.starts.len or f.move.n + 5 > f.move.lines.len) break;
        const failed = std.mem.eql(u8, need.kind, "sendback");
        f.move.starts[f.move.items] = f.move.n;
        f.move.tickets[f.move.items] = need.ticket;
        f.move.items += 1;
        // a look's text already names its doc; any other row with one wears a mark
        const marked = need.doc != null and !std.mem.eql(u8, need.kind, "look");
        f.move.add(.item, failed, "{s}{s}", .{ need.text, if (marked) " ¶" else "" });
        f.move.lines[f.move.n - 1].need = need_at;
        if (refusalOf(refused, need.id)) |why| {
            f.move.add(.refused, failed, "{s}", .{why});
            continue;
        }
        var chips: [12][]const u8 = undefined;
        var bufs: [12][96]u8 = undefined;
        var n: usize = 0;
        // opening the doc is arena's own: babylon's actions are only what it answers with
        if (need.doc != null) {
            chips[0] = "o open";
            n = 1;
        }
        for (need.actions) |action| {
            if (n == chips.len) break;
            chips[n] = std.fmt.bufPrint(&bufs[n], "{s} {s}", .{ action.key, action.label }) catch continue;
            n += 1;
        }
        const before = f.move.n;
        f.move.flow(.buttons, chips[0..n], &.{}, 4, width -| 4);
        for (f.move.lines[before..f.move.n]) |*l| {
            l.failed = failed;
        }
    }

    next(&f.rest, board, refused);
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
    if (f.move.n <= want and f.move.items == f.move.total) {
        f.shown = f.move.n;
        f.items_shown = f.move.items;
    } else {
        // whole items only, and a line kept for how many more there are
        want -|= 1;
        var k = f.move.items;
        while (k > 1 and (if (k < f.move.items) f.move.starts[k] else f.move.n) > want) k -= 1;
        f.items_shown = k;
        f.shown = if (k < f.move.items) f.move.starts[k] else f.move.n;
    }
    f.rest.n = @min(f.rest.n, room -| (f.count() - f.rest.n));
}

/// Next, a line for each ticket in it, the pin of the human's in front. A line says its why in
/// place of the title while it is the pick.
fn next(p: *Part, board: *const tickets.Board, refused: []const Refusal) void {
    const plan = board.next();
    const auto = board.autoState();
    if (plan.len == 0 and auto == null) return;
    const idle = if (auto) |a| (if (a.idle) |i| i.slots else 0) else 0;
    if (idle > 0) {
        p.add(.next_head, false, "▷ next {d} · {d} slot{s} idle", .{ plan.len, idle, if (idle == 1) "" else "s" });
    } else p.add(.next_head, false, "▷ next {d}", .{plan.len});
    for (plan, 0..) |item, i| {
        const pin: []const u8 = if (item.pinned()) "▪ " else "";
        p.add(.next_item, false, "{s}#{d} {s}  {s}", .{ pin, item.ticket, item.repo, item.title });
        if (item.why.len > 0) p.alt("{s}#{d} {s}  {s}", .{ pin, item.ticket, item.repo, item.why });
        p.spot(.{ .line = p.n - 1, .next = i, .ticket = item.ticket });
        var id: [24]u8 = undefined;
        if (refusalOf(refused, std.fmt.bufPrint(&id, "next:{d}", .{item.ticket}) catch "")) |why| p.add(.next_refused, false, "{s}", .{why});
    }
}

/// The Claudes working a repo's tickets.
pub fn working(board: *const tickets.Board, repo: []const u8) u32 {
    var n: u32 = 0;
    for (board.cards()) |card| {
        if (card.status == .doing and card.holder() != null and std.mem.eql(u8, card.repo orelse "", repo)) n += 1;
    }
    return n;
}

fn refusalOf(refused: []const Refusal, id: []const u8) ?[]const u8 {
    for (refused) |r| if (std.mem.eql(u8, r.id, id)) return r.text;
    return null;
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
    p.add(.landing_head, false, "◒ landing {d}", .{n});
    var chips: [64][]const u8 = undefined;
    var bufs: [64][80]u8 = undefined;
    var ids: [64]u32 = undefined;
    var queued: usize = 0;
    for (queue[0..n], 0..) |card, i| {
        ids[i] = card.id;
        var when: [8]u8 = undefined;
        const at = age(&when, epoch, tickets.epochOf(card.submitted_at));
        chips[i] = if (running(card))
            std.fmt.bufPrint(&bufs[i], "#{d} {s} {s} {s}", .{ card.id, card.repo orelse "", card.stage.?, at }) catch ""
        else blk: {
            queued += 1;
            break :blk std.fmt.bufPrint(&bufs[i], "#{d} {s} queued {d}{s}", .{ card.id, card.repo orelse "", queued, ordinal(queued) }) catch "";
        };
    }
    p.flow(.landing_chips, chips[0..n], ids[0..n], 2, width);
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
    p.add(.building_head, false, "◐ building {d}", .{n});
    var chips: [64][]const u8 = undefined;
    var bufs: [64][80]u8 = undefined;
    var ids: [64]u32 = undefined;
    for (held[0..n], 0..) |card, i| {
        ids[i] = card.id;
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
    p.flow(.building_chips, chips[0..n], ids[0..n], 2, width);
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
    build(&f, &b, &.{}, 56, 40, now, now - 12 * 3600);
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
    build(&f, &b, &.{}, 56, 11, now, 0);
    try std.testing.expectEqual(@as(usize, 11), f.count());
    try std.testing.expectEqualStrings("⏎ go   x no", f.line(2).text);
    try std.testing.expectEqualStrings("↓ 2 more", f.line(3).text);
    try std.testing.expectEqualStrings("◒ landing 3", f.line(4).text);
    try std.testing.expectEqualStrings("✓ landed today 2", f.line(10).text);
}

test "more items than the feed holds are counted in ↓ N more, and only whole items are shown" {
    var json: std.ArrayList(u8) = .empty;
    defer json.deinit(std.testing.allocator);
    try json.appendSlice(std.testing.allocator, "{\"tickets\":[],\"needs_you\":[");
    for (0..30) |i| {
        if (i > 0) try json.append(std.testing.allocator, ',');
        try json.print(std.testing.allocator, "{{\"id\":\"ask:{d}\",\"kind\":\"ask\",\"ticket\":{d},\"repo\":\"arena\",\"text\":\"#{d} arena  asks: Q?\"," ++
            "\"actions\":[{{\"key\":\"1\",\"label\":\"A\",\"argv\":[\"babylon\",\"answer\",\"{d}\",\"1\"]}}]}}", .{ i, i + 100, i + 100, i });
    }
    try json.appendSlice(std.testing.allocator, "]}");
    var b = try tickets.Board.parse(std.testing.allocator, json.items);
    defer b.deinit();
    var f: Feed = undefined;
    build(&f, &b, &.{}, 56, 200, now, 0);
    try std.testing.expect(f.items_shown < 30);
    var want: [16]u8 = undefined;
    try std.testing.expectEqualStrings(try std.fmt.bufPrint(&want, "↓ {d} more", .{30 - f.items_shown}), f.line(f.shown).text);
    try std.testing.expectEqualStrings("1 A", f.line(f.shown - 1).text);
}

test "with nothing that needs the human, the feed shrinks to one dim line above the rest" {
    var b = try tickets.Board.parse(std.testing.allocator,
        \\{"tickets":[{"id":1,"title":"a","status":"todo"}],"needs_you":[]}
    );
    defer b.deinit();
    var f: Feed = undefined;
    build(&f, &b, &.{}, 56, 20, now, 0);
    try std.testing.expectEqual(@as(usize, 2), f.count());
    try std.testing.expectEqual(Kind.quiet, f.line(0).kind);
    try std.testing.expectEqualStrings("✓ landed today 0", f.line(1).text);
}

test "the pick goes through Your move's items, then each ticket landing and building, where each is drawn" {
    var b = try tickets.Board.parse(std.testing.allocator, sample);
    defer b.deinit();
    var f: Feed = undefined;
    build(&f, &b, &.{}, 56, 40, now, 0);
    try std.testing.expectEqual(@as(usize, 11), f.itemCount());
    try std.testing.expectEqual(Item{ .line = 1, .ticket = 7, .need = 0 }, f.item(0).?);
    try std.testing.expectEqual(Item{ .line = 5, .ticket = 12, .need = 2 }, f.item(2).?);
    try std.testing.expectEqual(Item{ .line = 8, .at = 0, .w = 24, .ticket = 15 }, f.item(3).?);
    try std.testing.expectEqual(Item{ .line = 8, .at = 27, .w = 19, .ticket = 18 }, f.item(4).?);
    try std.testing.expectEqual(Item{ .line = 12, .at = 18, .w = 26, .ticket = 362 }, f.item(10).?);
    try std.testing.expectEqual(@as(?Item, null), f.item(11));
}

test "an item babylon refused says why in place of its buttons" {
    var b = try tickets.Board.parse(std.testing.allocator, sample);
    defer b.deinit();
    var f: Feed = undefined;
    build(&f, &b, &.{.{ .id = "ask:3", .text = "babylon: no session to answer" }}, 56, 40, now, 0);
    try std.testing.expectEqualStrings("#16 arena  asks: Blue?", f.line(3).text);
    try std.testing.expectEqual(Kind.refused, f.line(4).kind);
    try std.testing.expectEqualStrings("babylon: no session to answer", f.line(4).text);
}

const planned =
    \\{"tickets":[
    \\{"id":14,"repo":"arena","title":"A pane","status":"doing","claimed_by":"%3","claimed_at":"2026-11-21T10:00:00Z"},
    \\{"id":15,"repo":"arena","title":"Another","status":"doing","claimed_by":"%4","claimed_at":"2026-11-21T10:00:00Z"}],
    \\"needs_you":[],"hold":true,
    \\"auto":{"on":true,"cap":6,"working":4,"idle":{"slots":2,"why":"next empty"},"repo_caps":{"arena":2,"babylon":3,"tlon":0}},
    \\"plan":{"next":[
    \\{"ticket":655,"repo":"arena","title":"Typing reaches no pane","why":"third sighting","set_by":"human"},
    \\{"ticket":656,"repo":"babylon","title":"Held lines","why":"","set_by":"orchestrator"}]}}
;

test "next says its idle slots, then each ticket, and no line of auto's" {
    var b = try tickets.Board.parse(std.testing.allocator, planned);
    defer b.deinit();
    var f: Feed = undefined;
    build(&f, &b, &.{}, 70, 40, now, 0);
    var out: [64][]const u8 = undefined;
    const got = texts(&f, &out);
    try std.testing.expectEqualStrings("▷ next 2 · 2 slots idle", got[1]);
    try std.testing.expectEqualStrings("▪ #655 arena  Typing reaches no pane", got[2]);
    try std.testing.expectEqualStrings("#656 babylon  Held lines", got[3]);
    try std.testing.expectEqualStrings("▪ #655 arena  third sighting", f.line(2).alt);
}

test "babylon's refusal of a next key is said under that ticket's row" {
    var b = try tickets.Board.parse(std.testing.allocator, planned);
    defer b.deinit();
    var f: Feed = undefined;
    const refused = [_]Refusal{.{ .id = "next:656", .text = "refused: ticket #656 is claimed by pane %1010" }};
    build(&f, &b, &refused, 70, 40, now, 0);
    var out: [64][]const u8 = undefined;
    const got = texts(&f, &out);
    try std.testing.expectEqualStrings("#656 babylon  Held lines", got[3]);
    try std.testing.expectEqualStrings("refused: ticket #656 is claimed by pane %1010", got[4]);
    try std.testing.expectEqual(Kind.next_refused, f.line(4).kind);
    try std.testing.expectEqual(@as(?u32, 656), f.item(1).?.ticket);
}

test "the pick goes through next's tickets" {
    var b = try tickets.Board.parse(std.testing.allocator, planned);
    defer b.deinit();
    var f: Feed = undefined;
    build(&f, &b, &.{}, 70, 40, now, 0);
    try std.testing.expectEqual(@as(?usize, 0), f.item(0).?.next);
    try std.testing.expectEqual(@as(?u32, 655), f.item(0).?.ticket);
    try std.testing.expectEqual(@as(?usize, 1), f.item(1).?.next);
}

test "a decision that names a doc keeps its place, wears a mark and says o opens it; one without says nothing of it" {
    var b = try tickets.Board.parse(std.testing.allocator,
        \\{"tickets":[],"needs_you":[
        \\{"id":"ask:6","kind":"ask","ticket":307,"repo":"tlon","text":"#307 tlon  asks: A or B?","doc":"docs/plan.md",
        \\ "actions":[{"key":"1","label":"A","argv":["babylon","answer","6","1"]}]},
        \\{"id":"ask:7","kind":"ask","ticket":308,"repo":"tlon","text":"#308 tlon  asks: C or D?","doc":null,
        \\ "actions":[{"key":"1","label":"C","argv":["babylon","answer","7","1"]}]}]}
    );
    defer b.deinit();
    var f: Feed = undefined;
    build(&f, &b, &.{}, 56, 40, now, 0);
    var out: [64][]const u8 = undefined;
    const got = texts(&f, &out);
    try std.testing.expectEqualStrings("#307 tlon  asks: A or B? ¶", got[1]);
    try std.testing.expectEqualStrings("o open   1 A", got[2]);
    try std.testing.expectEqualStrings("#308 tlon  asks: C or D?", got[3]);
    try std.testing.expectEqualStrings("1 C", got[4]);
}

test "a look at says it can be opened, then babylon's own actions, and names its doc" {
    var b = try tickets.Board.parse(std.testing.allocator,
        \\{"tickets":[],"needs_you":[
        \\{"id":"ask:6","kind":"look","ticket":307,"repo":"tlon","text":"#307 tlon  look at: docs/asterion.md","doc":"docs/asterion.md",
        \\ "actions":[{"key":"y","label":"looks good","argv":["babylon","call","answer_ask","{\"id\":6}"]},{"key":"c","label":"change","argv":null,"needs":"words"}]}]}
    );
    defer b.deinit();
    try std.testing.expectEqualStrings("docs/asterion.md", b.needsYou()[0].doc.?);
    var f: Feed = undefined;
    build(&f, &b, &.{}, 56, 40, now, 0);
    var out: [64][]const u8 = undefined;
    const got = texts(&f, &out);
    try std.testing.expectEqualStrings("#307 tlon  look at: docs/asterion.md", got[1]);
    try std.testing.expectEqualStrings("o open   y looks good   c change", got[2]);
}
