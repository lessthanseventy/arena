//! The feed atop the orchestrator's column: the human's move as babylon gives it, then what is
//! landing and building, and how many landed today.
const std = @import("std");
const tickets = @import("board.zig");
const Card = tickets.Card;

pub const Kind = enum { move_head, quiet, item, buttons, refused, more, next_head, auto_line, auto_repos, next_item, landing_head, building_head, landing_chips, building_chips, landed };

/// babylon's refusal of what was asked of a Your move item, by the item's id: said in place of
/// its buttons.
pub const Refusal = struct { id: []const u8, text: []const u8 };

/// Something in the feed the pick can be on: a Your move item, its whole first line, a ticket in
/// next, auto's line with one of its repos lit, or a ticket landing or building, `w` cells of its
/// line from `at`.
pub const Item = struct {
    line: usize,
    at: usize = 0,
    w: usize = 0,
    ticket: ?u32 = null,
    /// Its place in babylon's needs_you, for a Your move item.
    need: ?usize = null,
    /// Its place in next, for a ticket there.
    next: ?usize = null,
    /// Auto's line, and the repo of its caps that is lit, in the order babylon gives them.
    auto: bool = false,
    repo: usize = 0,
};

/// What the pick can be on in the rest of the feed: a ticket's chip on a line of landing or
/// building, a ticket of next, or auto's line.
const Spot = struct {
    line: usize,
    at: usize = 0,
    w: usize = 0,
    ticket: ?u32 = null,
    next: ?usize = null,
    auto: bool = false,
    repo: usize = 0,
};

pub const Line = struct {
    kind: Kind,
    /// Of a send-back of Your move: drawn in a send-back's colour. Of auto's line: hold is on.
    failed: bool = false,
    text: []const u8,
    /// What a line of next says in place of its title while it is the pick.
    alt: []const u8 = "",
    /// Of auto's line, its parts, split at ` · `: those drawn dim and those drawn as paused.
    dimmed: u16 = 0,
    paused: u16 = 0,
};

/// Lines and the text they point into: Your move's, or what follows it.
const Part = struct {
    lines: [48]Line = undefined,
    n: usize = 0,
    /// The line each Your move item starts on, and its ticket.
    starts: [24]usize = undefined,
    tickets: [24]?u32 = undefined,
    items: usize = 0,
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
        return f.items_shown < f.move.items;
    }

    /// How many things the pick can be on.
    pub fn itemCount(f: *const Feed) usize {
        var n = f.items_shown;
        for (f.rest.spots[0..f.rest.n_spots]) |spot| n += @intFromBool(spot.line < f.rest.n);
        return n;
    }

    /// The `i`th thing the pick can be on: Your move's items first, then next's, auto's line at its
    /// top, then landing, then building.
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
            .auto = spot.auto,
            .repo = spot.repo,
        };
    }

    fn moreText(f: *const Feed) []const u8 {
        const buf: *[32]u8 = @constCast(&f.more);
        return std.fmt.bufPrint(buf, "↓ {d} more", .{f.move.items - f.items_shown}) catch "";
    }
};

/// The feed for `board`, its lines `width` cells wide and at most `room` of them, as of `epoch`, in
/// a day that began at `today`. Your move keeps its head and first item; the rest of it is cut to
/// whole items, and what follows is cut to what is left. An item babylon refused says why in place
/// of its buttons.
pub fn build(f: *Feed, board: *const tickets.Board, refused: []const Refusal, width: usize, room: usize, epoch: i64, today: i64, repo_sel: usize) void {
    f.* = .{};
    const needs = board.needsYou();
    if (needs.len == 0) f.move.add(.quiet, false, "nothing needs you", .{});
    if (needs.len > 0) f.move.add(.move_head, false, "▲ your move {d}", .{needs.len});
    for (needs) |need| {
        if (f.move.items == f.move.starts.len) break;
        const failed = std.mem.eql(u8, need.kind, "sendback");
        f.move.starts[f.move.items] = f.move.n;
        f.move.tickets[f.move.items] = need.ticket;
        f.move.items += 1;
        f.move.add(.item, failed, "{s}", .{need.text});
        if (refusalOf(refused, need.id)) |why| {
            f.move.add(.refused, failed, "{s}", .{why});
            continue;
        }
        var chips: [12][]const u8 = undefined;
        var bufs: [12][96]u8 = undefined;
        var n: usize = 0;
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

    next(&f.rest, board, repo_sel, width);
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

/// Next, under its head auto's line, then a line for each ticket in it, the pin of the human's
/// in front. A line says its why in place of the title while it is the pick. `repo_sel` is the
/// repo of auto's caps that is lit.
fn next(p: *Part, board: *const tickets.Board, repo_sel: usize, width: usize) void {
    const plan = board.next();
    const auto = board.autoState();
    if (plan.len == 0 and auto == null) return;
    const idle = if (auto) |a| (if (a.idle) |i| i.slots else 0) else 0;
    if (idle > 0) {
        p.add(.next_head, false, "▷ next {d} · {d} slot{s} idle", .{ plan.len, idle, if (idle == 1) "" else "s" });
    } else p.add(.next_head, false, "▷ next {d}", .{plan.len});
    if (auto) |a| autoLine(p, board, a, repo_sel, width);
    for (plan, 0..) |item, i| {
        const pin: []const u8 = if (item.pinned()) "▪ " else "";
        p.add(.next_item, false, "{s}#{d} {s}  {s}", .{ pin, item.ticket, item.repo, item.title });
        if (item.why.len > 0) p.alt("{s}#{d} {s}  {s}", .{ pin, item.ticket, item.repo, item.why });
        p.spot(.{ .line = p.n - 1, .next = i, .ticket = item.ticket });
    }
}

/// Which of auto's parts a line says.
const AutoPart = enum { all, head, repos };

/// `auto on · 5 of 6 · arena 3 · babylon 2 · tlon paused · hold off`, or its `head` or `repos`:
/// a repo at cap 0 reads paused, and one with its cap's worth working is dimmed. `dimmed` and
/// `paused` have a bit for each part, split at ` · `, and the repo lit is where `lit_at` says.
const AutoText = struct {
    buf: [256]u8 = undefined,
    len: usize = 0,
    dimmed: u16 = 0,
    paused: u16 = 0,
    lit_at: usize = 0,
    lit_w: usize = 0,

    fn text(t: *const AutoText) []const u8 {
        return t.buf[0..t.len];
    }
};

fn autoText(board: *const tickets.Board, auto: tickets.Auto, repo_sel: usize, which: AutoPart) AutoText {
    var t: AutoText = .{};
    var w: std.Io.Writer = .fixed(&t.buf);
    var part: u4 = 0;
    const sep = " · ";
    if (which != .repos) {
        w.print("auto {s}{s}{d} of {d}", .{ if (auto.on) "on" else "off", sep, auto.working, auto.cap }) catch {};
        if (!auto.on) t.dimmed |= 1;
        part = 2;
    }
    if (which != .head) {
        const caps = auto.repo_caps.map;
        const sel = if (caps.count() == 0) 0 else @min(repo_sel, caps.count() - 1);
        for (caps.keys(), caps.values(), 0..) |repo, cap, i| {
            if (w.buffered().len > 0) w.writeAll(sep) catch {};
            const from = cellCount(w.buffered());
            if (cap == 0) {
                w.print("{s} paused", .{repo}) catch {};
                t.paused |= @as(u16, 1) << part;
            } else {
                w.print("{s} {d}", .{ repo, cap }) catch {};
                if (working(board, repo) >= cap) t.dimmed |= @as(u16, 1) << part;
            }
            if (i == sel) {
                t.lit_at = from;
                t.lit_w = cellCount(w.buffered()) - from;
            }
            part +|= 1;
        }
    }
    if (which != .repos) w.print("{s}hold {s}", .{ sep, if (board.hold()) "on" else "off" }) catch {};
    t.len = w.buffered().len;
    return t;
}

/// Auto's line, on one line when it fits `width` and else as two: its state and hold, then its
/// repos, where the pick is lit.
fn autoLine(p: *Part, board: *const tickets.Board, auto: tickets.Auto, repo_sel: usize, width: usize) void {
    const sel = if (auto.repo_caps.map.count() == 0) 0 else @min(repo_sel, auto.repo_caps.map.count() - 1);
    const whole = autoText(board, auto, repo_sel, .all);
    const split = cellCount(whole.text()) > width -| 1 and auto.repo_caps.map.count() > 0;
    const shown = if (split) autoText(board, auto, repo_sel, .head) else whole;
    p.add(.auto_line, board.hold(), "{s}", .{shown.text()});
    p.lines[p.n - 1].dimmed = shown.dimmed;
    p.lines[p.n - 1].paused = shown.paused;
    if (!split) return p.spot(.{ .line = p.n - 1, .at = whole.lit_at, .w = whole.lit_w, .auto = true, .repo = sel });
    const repos = autoText(board, auto, repo_sel, .repos);
    p.add(.auto_repos, false, "{s}", .{repos.text()});
    p.lines[p.n - 1].dimmed = repos.dimmed;
    p.lines[p.n - 1].paused = repos.paused;
    p.spot(.{ .line = p.n - 1, .at = repos.lit_at, .w = repos.lit_w, .auto = true, .repo = sel });
}

/// The Claudes working a repo's tickets.
fn working(board: *const tickets.Board, repo: []const u8) u32 {
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
    build(&f, &b, &.{}, 56, 40, now, now - 12 * 3600, 0);
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
    build(&f, &b, &.{}, 56, 11, now, 0, 0);
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
    build(&f, &b, &.{}, 56, 20, now, 0, 0);
    try std.testing.expectEqual(@as(usize, 2), f.count());
    try std.testing.expectEqual(Kind.quiet, f.line(0).kind);
    try std.testing.expectEqualStrings("✓ landed today 0", f.line(1).text);
}

test "the pick goes through Your move's items, then each ticket landing and building, where each is drawn" {
    var b = try tickets.Board.parse(std.testing.allocator, sample);
    defer b.deinit();
    var f: Feed = undefined;
    build(&f, &b, &.{}, 56, 40, now, 0, 0);
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
    build(&f, &b, &.{.{ .id = "ask:3", .text = "babylon: no session to answer" }}, 56, 40, now, 0, 0);
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

test "next says its idle slots, then auto's line with a paused repo and one at its cap, then each ticket" {
    var b = try tickets.Board.parse(std.testing.allocator, planned);
    defer b.deinit();
    var f: Feed = undefined;
    build(&f, &b, &.{}, 70, 40, now, 0, 1);
    var out: [64][]const u8 = undefined;
    const got = texts(&f, &out);
    try std.testing.expectEqualStrings("▷ next 2 · 2 slots idle", got[1]);
    try std.testing.expectEqualStrings("auto on · 4 of 6 · arena 2 · babylon 3 · tlon paused · hold on", got[2]);
    try std.testing.expectEqualStrings("▪ #655 arena  Typing reaches no pane", got[3]);
    try std.testing.expectEqualStrings("#656 babylon  Held lines", got[4]);
    const auto = f.line(2);
    try std.testing.expect(auto.kind == .auto_line and auto.failed);
    // arena has its cap's worth working: dimmed (part 2); tlon is paused (part 4)
    try std.testing.expectEqual(@as(u16, 1 << 2), auto.dimmed);
    try std.testing.expectEqual(@as(u16, 1 << 4), auto.paused);
    try std.testing.expectEqualStrings("▪ #655 arena  third sighting", f.line(3).alt);
}

test "the pick goes to auto's line, lit on the repo picked, then to next's tickets" {
    var b = try tickets.Board.parse(std.testing.allocator, planned);
    defer b.deinit();
    var f: Feed = undefined;
    build(&f, &b, &.{}, 70, 40, now, 0, 1);
    const on_auto = f.item(0).?;
    try std.testing.expect(on_auto.auto and on_auto.repo == 1);
    // "auto on · 4 of 6 · " is 19 cells, "arena 2 · " another 10: babylon's part starts at 29
    try std.testing.expectEqual(@as(usize, 29), on_auto.at);
    try std.testing.expectEqual(@as(usize, 9), on_auto.w);
    try std.testing.expectEqual(@as(?usize, 0), f.item(1).?.next);
    try std.testing.expectEqual(@as(?u32, 655), f.item(1).?.ticket);
    try std.testing.expectEqual(@as(?usize, 1), f.item(2).?.next);
    // a repo picked past the last is the last
    build(&f, &b, &.{}, 70, 40, now, 0, 9);
    try std.testing.expectEqual(@as(usize, 2), f.item(0).?.repo);
}

test "auto's line is two when one does not fit: its state and hold, then its repos, where the pick is lit" {
    var b = try tickets.Board.parse(std.testing.allocator, planned);
    defer b.deinit();
    var f: Feed = undefined;
    build(&f, &b, &.{}, 40, 40, now, 0, 2);
    try std.testing.expectEqualStrings("auto on · 4 of 6 · hold on", f.line(2).text);
    try std.testing.expectEqualStrings("arena 2 · babylon 3 · tlon paused", f.line(3).text);
    try std.testing.expect(f.line(3).kind == .auto_repos);
    const on = f.item(0).?;
    try std.testing.expectEqual(@as(usize, 3), on.line);
    try std.testing.expectEqual(@as(usize, 22), on.at);
    try std.testing.expectEqual(@as(usize, 11), on.w);
    try std.testing.expectEqual(@as(?usize, 0), f.item(1).?.next);
}
