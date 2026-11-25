//! The feed atop the orchestrator's column: the human's move as babylon gives it, then a strip of
//! chips, one for each of next, building, landing, today's landings and auto. A chip opens its list
//! as a popover over the column's pane.
const std = @import("std");
const tickets = @import("board.zig");
const Card = tickets.Card;

pub const Kind = enum { move_head, quiet, item, buttons, refused, next_refused, more, strip, next_head, next_item, landing_head, building_head, landing_chips, building_chips, landed, try_head, try_title, try_machine, try_step, try_buttons };

/// The age past which a to-try tile's age is in the "you" colour.
pub const stale_days = 7;

/// The lists a chip of the strip opens.
pub const Section = enum { next, landing, building, landed };

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
    /// Of a to-try tile's item: its place in the need's steps; none while it has no open step.
    step: ?usize = null,
    /// Its place in next, for a ticket there.
    next: ?usize = null,
    /// The list a chip of the strip opens; none on the auto chip, which opens auto's settings.
    chip: bool = false,
    section: ?Section = null,
};

/// A chip of the strip, `w` cells of its line from `at`.
const Chip = struct { line: usize, at: usize, w: usize, section: ?Section };

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
    /// Of a to-try tile's row of a check: its place in the need's steps.
    step: ?usize = null,
    /// Of a check's row: it is settled.
    settled: bool = false,
    /// Of a to-try tile's first row: it has waited stale_days or more.
    old: bool = false,
    /// What a line of next says in place of its title while it is the pick; a to-try tile's title
    /// its age, and its machine line the button its picked tile has.
    alt: []const u8 = "",
};

/// Lines and the text they point into: Your move's, or what follows it.
const Part = struct {
    lines: [128]Line = undefined,
    n: usize = 0,
    /// The line each Your move item starts on, its ticket, and its place in needs_you and, for a
    /// check, the need's steps.
    starts: [48]usize = undefined,
    tickets: [48]?u32 = undefined,
    need_at: [48]usize = undefined,
    step_at: [48]?usize = undefined,
    items: usize = 0,
    /// How many items babylon gave, of which `items` are held.
    total: usize = 0,
    buf: [8192]u8 = undefined,
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
    strip: Part = .{},
    chips: [5]Chip = undefined,
    n_chips: usize = 0,
    /// The list open as a popover, the lines of `rest` it starts at and how many are shown.
    open: ?Section = null,
    pop_from: usize = 0,
    pop: usize = 0,
    ranges: [4][2]usize = @splat(.{ 0, 0 }),
    /// The lines of Your move shown, and the items shown of it.
    shown: usize = 0,
    items_shown: usize = 0,
    more: [32]u8 = undefined,

    /// How many lines it takes in the column, where the pane starts under them.
    pub fn height(f: *const Feed) usize {
        return f.shown + @intFromBool(f.cut()) + f.strip.n;
    }

    /// How many lines it draws: its height, and the popover over the pane when one is open.
    pub fn count(f: *const Feed) usize {
        return f.height() + f.pop;
    }

    /// Line `i` of it, from the top.
    pub fn line(f: *const Feed, i: usize) Line {
        if (i < f.shown) return f.move.lines[i];
        if (f.cut() and i == f.shown) return .{ .kind = .more, .text = f.moreText() };
        const at = i - f.shown - @intFromBool(f.cut());
        if (at < f.strip.n) return f.strip.lines[at];
        return f.rest.lines[f.pop_from + at - f.strip.n];
    }

    fn popSpots(f: *const Feed) []const Spot {
        var from: usize = 0;
        while (from < f.rest.n_spots and f.rest.spots[from].line < f.pop_from) from += 1;
        var to = from;
        while (to < f.rest.n_spots and f.rest.spots[to].line < f.pop_from + f.pop) to += 1;
        return f.rest.spots[from..to];
    }

    fn cut(f: *const Feed) bool {
        return f.items_shown < f.move.total;
    }

    /// How many things the pick can be on.
    pub fn itemCount(f: *const Feed) usize {
        return f.items_shown + f.n_chips + f.popSpots().len;
    }

    /// The `i`th thing the pick can be on: Your move's items first, then the strip's chips, then
    /// the open list's tickets.
    pub fn item(f: *const Feed, i: usize) ?Item {
        if (i < f.items_shown) return .{ .line = f.move.starts[i], .ticket = f.move.tickets[i], .need = f.move.need_at[i], .step = f.move.step_at[i] };
        const top = f.shown + @intFromBool(f.cut());
        const spots = f.popSpots();
        // the open list's tickets follow its own chip
        var open_at: usize = f.n_chips;
        for (f.chips[0..f.n_chips], 0..) |chip, k| {
            if (f.open != null and chip.section == f.open) open_at = k;
        }
        var at = i - f.items_shown;
        if (at > open_at and at <= open_at + spots.len) return f.popItem(spots[at - open_at - 1]);
        if (at > open_at) at -= spots.len;
        if (at >= f.n_chips) return null;
        const chip = f.chips[at];
        return .{ .line = top + chip.line, .at = chip.at, .w = chip.w, .chip = true, .section = chip.section };
    }

    fn popItem(f: *const Feed, spot: Spot) Item {
        const top = f.shown + @intFromBool(f.cut());
        return .{
            .line = top + f.strip.n + spot.line - f.pop_from,
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

/// The feed for `board`, its lines `width` cells wide in a column `rows` tall, as of `epoch`, in a
/// day that began at `today`. Your move keeps its head and first item and takes at most half the
/// column with the strip under it; the rest of it is cut to whole items. The list `open` is
/// drawn under the strip, over the pane, as far as the column goes. An item babylon refused says
/// why in place of its buttons.
pub fn build(f: *Feed, board: *const tickets.Board, refused: []const Refusal, width: usize, rows: usize, epoch: i64, today: i64, open: ?Section) void {
    buildPicked(f, board, refused, width, rows, epoch, today, open, std.math.maxInt(usize));
}

/// `build` with the pick known: the item `pick` of Your move, which a to-try tile shows its
/// buttons under, and whose tile has its close untried button.
pub fn buildPicked(f: *Feed, board: *const tickets.Board, refused: []const Refusal, width: usize, rows: usize, epoch: i64, today: i64, open: ?Section, pick: usize) void {
    f.* = .{};
    const needs = board.needsYou();
    if (needs.len == 0) f.move.add(.quiet, false, "nothing needs you", .{});
    if (needs.len > 0) f.move.add(.move_head, false, "▲ your move {d}", .{needs.len});
    var tries: usize = 0;
    for (needs) |need| {
        if (isTry(need)) {
            tries += 1;
            f.move.total += @max(1, openSteps(need));
        } else f.move.total += 1;
    }
    // the decisions, then what is to try, then the send-backs
    var rule = false;
    groups: for ([_]u8{ 0, 1, 2 }) |group| for (needs, 0..) |need, need_at| {
        const mine: u8 = if (isTry(need)) 1 else if (std.mem.eql(u8, need.kind, "sendback")) 2 else 0;
        if (mine != group) continue;
        if (mine == 1) {
            const room = 3 + 3 * need.steps.len + 2 + @intFromBool(!rule);
            if (f.move.items + @max(1, openSteps(need)) > f.move.starts.len or f.move.n + room > f.move.lines.len) break :groups;
            if (!rule) f.move.add(.try_head, false, "── to try {d} ", .{tries});
            rule = true;
            tile(&f.move, need, need_at, refused, width, epoch, pick);
            continue;
        }
        // an item is held whole or not at all: its row, a refusal or up to four rows of buttons
        if (f.move.items == f.move.starts.len or f.move.n + 5 > f.move.lines.len) break :groups;
        const failed = mine == 2;
        f.move.starts[f.move.items] = f.move.n;
        f.move.tickets[f.move.items] = need.ticket;
        f.move.need_at[f.move.items] = need_at;
        f.move.step_at[f.move.items] = null;
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
    };

    var counts: [4]usize = undefined;
    var mark = f.rest.n;
    counts[0] = next(&f.rest, board, refused);
    f.ranges[0] = .{ mark, f.rest.n };
    mark = f.rest.n;
    counts[1] = landing(&f.rest, board, width, epoch);
    f.ranges[1] = .{ mark, f.rest.n };
    mark = f.rest.n;
    counts[2] = building(&f.rest, board, width, epoch);
    f.ranges[2] = .{ mark, f.rest.n };
    mark = f.rest.n;
    counts[3] = landedToday(&f.rest, board, today);
    f.ranges[3] = .{ mark, f.rest.n };
    stripOf(f, board, width, counts);

    const room = rows / 2;
    const floor = if (f.move.items > 0) @min(f.move.n, f.move.starts[0] + 2) else f.move.n;
    var want = @max(floor, room -| f.strip.n);
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
    f.open = open;
    if (open) |section| {
        const range = f.ranges[@backingInt(section)];
        f.pop_from = range[0];
        f.pop = @min(range[1] - range[0], rows -| (f.height() + 1));
    }
}

fn isTry(need: tickets.Need) bool {
    return std.mem.eql(u8, need.kind, "try");
}

fn openSteps(need: tickets.Need) usize {
    var n: usize = 0;
    for (need.steps) |step| n += @intFromBool(step.result == null);
    return n;
}

/// The rows of `text` in `cells` cells, cut at spaces, at most `rows` of them, the last ending in
/// `…` when it holds no more: the first row and what is left.
fn wrapRow(text: []const u8, cells: usize, last: bool) struct { row: []const u8, rest: []const u8 } {
    if (cellCount(text) <= cells) return .{ .row = text, .rest = "" };
    var end: usize = 0;
    var seen: usize = 0;
    var space: ?usize = null;
    var at: usize = 0;
    while (at < text.len) {
        const len = std.unicode.utf8ByteSequenceLength(text[at]) catch 1;
        if (seen == cells) break;
        if (text[at] == ' ') space = at;
        at += len;
        seen += 1;
        end = at;
    }
    const cut = if (last) end else space orelse end;
    return .{ .row = std.mem.trimEnd(u8, text[0..cut], " "), .rest = std.mem.trimStart(u8, text[cut..], " ") };
}

/// A to-try need as a tile: its title and age, the machine's line, and a row for each check,
/// the open ones items; the picked check has its buttons under it.
fn tile(p: *Part, need: tickets.Need, need_at: usize, refused: []const Refusal, width: usize, epoch: i64, pick: usize) void {
    const first = p.items;
    const count = @max(1, openSteps(need));
    const picked = pick >= first and pick < first + count;
    const since = tickets.epochOf(need.since);
    p.add(.try_title, false, "{s}", .{need.text});
    var age_buf: [8]u8 = undefined;
    p.alt("{s}", .{age(&age_buf, epoch, since)});
    p.lines[p.n - 1].old = if (since) |at| epoch - at >= stale_days * 86400 else false;
    p.lines[p.n - 1].need = need_at;
    p.add(.try_machine, false, "{s}", .{need.machine});
    if (picked) for (need.actions) |action| if (std.mem.eql(u8, action.key, "x")) p.alt("{s} {s}", .{ action.key, action.label });
    p.lines[p.n - 1].need = need_at;
    var open: usize = 0;
    // the number and the margin take six cells of the row
    const room = width -| 8;
    for (need.steps, 0..) |step, at| {
        const settled = step.result != null;
        const mine = !settled;
        if (mine) {
            p.starts[p.items] = p.n;
            p.tickets[p.items] = need.ticket;
            p.need_at[p.items] = need_at;
            p.step_at[p.items] = at;
            p.items += 1;
        }
        var rest: []const u8 = step.text;
        var row: usize = 0;
        while (row < 3) : (row += 1) {
            const cut = wrapRow(rest, room, row == 2);
            const ellipsis = row == 2 and cut.rest.len > 0;
            if (row == 0) {
                p.add(.try_step, false, "{d} {s}{s}", .{ step.n, cut.row, if (ellipsis) "…" else "" });
            } else p.add(.try_step, false, "  {s}{s}", .{ cut.row, if (ellipsis) "…" else "" });
            p.lines[p.n - 1].need = need_at;
            p.lines[p.n - 1].step = at;
            p.lines[p.n - 1].settled = settled;
            rest = cut.rest;
            if (rest.len == 0 or ellipsis) break;
        }
        if (mine) {
            if (picked and first + open == pick) buttons(p, need, at);
            open += 1;
        }
    }
    if (count > open) {
        // a tile with no open check is still one item, for its own keys
        p.starts[p.items] = p.n - 1;
        p.tickets[p.items] = need.ticket;
        p.need_at[p.items] = need_at;
        p.step_at[p.items] = null;
        p.items += 1;
    }
    if (refusalOf(refused, need.id)) |why| {
        p.add(.try_buttons, true, "{s}", .{why});
        p.lines[p.n - 1].need = need_at;
    }
}

/// The buttons of check `at` of `need`, as babylon gives their keys and labels.
fn buttons(p: *Part, need: tickets.Need, at: usize) void {
    var line: [96]u8 = undefined;
    var w: std.Io.Writer = .fixed(&line);
    for (need.steps[at].actions, 0..) |action, k| {
        w.print("{s}{s} {s}", .{ if (k == 0) "" else "   ", action.key, action.label }) catch break;
    }
    p.add(.try_buttons, false, "{s}", .{w.buffered()});
    p.lines[p.n - 1].need = p.lines[p.n - 2].need;
    p.lines[p.n - 1].step = at;
}

/// Today's landings: a head and a line for each ticket. The count of them.
fn landedToday(p: *Part, board: *const tickets.Board, today: i64) usize {
    var n: usize = 0;
    for (board.cards()) |card| {
        const stage = card.stage orelse continue;
        if (std.mem.eql(u8, stage, "landed") and (tickets.epochOf(card.closed_at) orelse 0) >= today) n += 1;
    }
    p.add(.landed, false, "✓ landed today {d}", .{n});
    var shown: usize = 0;
    for (board.cards()) |card| {
        const stage = card.stage orelse continue;
        if (!std.mem.eql(u8, stage, "landed") or (tickets.epochOf(card.closed_at) orelse 0) < today) continue;
        if (shown == 12) break;
        p.add(.next_item, false, "#{d} {s}  {s}", .{ card.id, card.repo orelse "", card.title });
        p.spot(.{ .line = p.n - 1, .ticket = card.id });
        shown += 1;
    }
    return n;
}

/// The strip: a chip for each list with something in it, and for auto, in at most two lines of
/// `width` cells, three spaces apart. `counts` are the lists' sizes, in `Section` order.
fn stripOf(f: *Feed, board: *const tickets.Board, width: usize, counts: [4]usize) void {
    const Entry = struct { text: [40]u8 = undefined, len: usize = 0, section: ?Section };
    var entries: [5]Entry = undefined;
    var n: usize = 0;
    const order = [_]Section{ .next, .building, .landing, .landed };
    for (order) |section| {
        const count = counts[@backingInt(section)];
        const range = f.ranges[@backingInt(section)];
        if (range[1] == range[0] or (count == 0 and section != .landed)) continue;
        entries[n] = .{ .section = section };
        const text = switch (section) {
            .next => std.fmt.bufPrint(&entries[n].text, "▷ next {d}", .{count}),
            .building => std.fmt.bufPrint(&entries[n].text, "◐ building {d}", .{count}),
            .landing => std.fmt.bufPrint(&entries[n].text, "◒ landing {d}", .{count}),
            .landed => std.fmt.bufPrint(&entries[n].text, "✓ {d} today", .{count}),
        } catch continue;
        entries[n].len = text.len;
        n += 1;
    }
    if (board.autoState()) |auto| {
        entries[n] = .{ .section = null };
        const text = (if (auto.on)
            std.fmt.bufPrint(&entries[n].text, "auto {d}/{d}", .{ auto.working, auto.cap })
        else
            std.fmt.bufPrint(&entries[n].text, "auto off", .{})) catch "auto";
        entries[n].len = text.len;
        n += 1;
    }
    var at: usize = 0;
    while (at < n and f.strip.n < 2) {
        var line: [160]u8 = undefined;
        var w: std.Io.Writer = .fixed(&line);
        var cells: usize = 0;
        const row = f.strip.n;
        while (at < n) : (at += 1) {
            const text = entries[at].text[0..entries[at].len];
            const chip = cellCount(text);
            const gap: usize = if (cells == 0) 0 else 3;
            if (cells > 0 and cells + gap + chip > width) break;
            w.splatByteAll(' ', gap) catch break;
            w.writeAll(text) catch break;
            f.chips[f.n_chips] = .{ .line = row, .at = cells + gap, .w = chip, .section = entries[at].section };
            f.n_chips += 1;
            cells += gap + chip;
        }
        f.strip.add(.strip, false, "{s}", .{w.buffered()});
    }
}

/// Next, a line for each ticket in it, the pin of the human's in front. A line says its why in
/// place of the title while it is the pick. How many tickets it has.
fn next(p: *Part, board: *const tickets.Board, refused: []const Refusal) usize {
    const plan = board.next();
    const auto = board.autoState();
    if (plan.len == 0 and auto == null) return 0;
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
    return plan.len;
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

fn landing(p: *Part, board: *const tickets.Board, width: usize, epoch: i64) usize {
    var queue: [64]*const Card = undefined;
    var n: usize = 0;
    for (board.cards()) |*card| {
        if (card.status != .review or isFailed(card) or n == queue.len) continue;
        queue[n] = card;
        n += 1;
    }
    if (n == 0) return 0;
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
    return n;
}

fn building(p: *Part, board: *const tickets.Board, width: usize, epoch: i64) usize {
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
    if (n == 0) return 0;
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
    return n;
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

/// The key of the chip of a buttons line drawn under cell `col` of the row's cells after its
/// margin: as draw.zig lays them, as raised buttons of `key label` and five cells more with
/// `raised`, else as the text after a six-cell lead.
pub fn chipKeyAt(text: []const u8, col: usize, raised: bool) ?[]const u8 {
    var cells: usize = if (raised) 2 else 6;
    var parts = std.mem.splitSequence(u8, text, "   ");
    while (parts.next()) |chip| {
        const space = std.mem.indexOfScalar(u8, chip, ' ') orelse chip.len;
        const key = chip[0..space];
        const w = if (raised) cellCount(key) + cellCount(std.mem.trimStart(u8, chip[space..], " ")) + 5 else cellCount(chip);
        if (col >= cells and col < cells + w) return key;
        cells += w + if (raised) 0 else @as(usize, 3);
    }
    return null;
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

test "the feed draws babylon's needs_you as given, then a strip of chips, and a chip's list is a popover under it" {
    var b = try tickets.Board.parse(std.testing.allocator, sample);
    defer b.deinit();
    var f: Feed = undefined;
    build(&f, &b, &.{}, 56, 80, now, now - 12 * 3600, null);
    var out: [64][]const u8 = undefined;
    const move = [_][]const u8{
        "▲ your move 3",
        "P4 Start #7: Next in line",
        "⏎ go   x no",
        "#16 arena  asks: Blue?",
        "1 Blue   c in words",
        "✗ #12 arena  sent back, free: red",
        "G give   ⏎ start",
    };
    const got = texts(&f, &out);
    try std.testing.expectEqual(move.len + 1, got.len);
    for (move, got[0..move.len]) |w, g| try std.testing.expectEqualStrings(w, g);
    try std.testing.expectEqualStrings("◐ building 5   ◒ landing 3   ✓ 1 today", got[move.len]);
    try std.testing.expectEqual(Kind.strip, f.line(move.len).kind);
    try std.testing.expect(f.line(5).failed and f.line(6).failed and f.line(6).kind == .buttons);
    try std.testing.expect(!f.line(1).failed);

    build(&f, &b, &.{}, 56, 80, now, now - 12 * 3600, .landing);
    const in_landing = texts(&f, &out);
    try std.testing.expectEqual(move.len + 4, in_landing.len);
    try std.testing.expectEqualStrings("◒ landing 3", in_landing[move.len + 1]);
    try std.testing.expectEqualStrings("#15 babylon reviewing 2m   #18 tlon queued 1st", in_landing[move.len + 2]);
    try std.testing.expectEqualStrings("#17 arena queued 2nd", in_landing[move.len + 3]);
    try std.testing.expectEqual(move.len + 1, f.height());

    build(&f, &b, &.{}, 56, 80, now, now - 12 * 3600, .building);
    const in_building = texts(&f, &out);
    try std.testing.expectEqualStrings("◐ building 5", in_building[move.len + 1]);
    try std.testing.expectEqualStrings("#21 tlon ○ 2d   #16 arena ▲ 3h   #14 arena 2h", in_building[move.len + 2]);
    try std.testing.expectEqualStrings("✗ #495 arena 1h   ✗ #362 arena waits on #361", in_building[move.len + 3]);

    build(&f, &b, &.{}, 56, 80, now, now - 12 * 3600, .landed);
    const landed = texts(&f, &out);
    try std.testing.expectEqualStrings("✓ landed today 1", landed[move.len + 1]);
    try std.testing.expectEqualStrings("#9 arena  Landed today", landed[move.len + 2]);
}

test "with 8 in next and 5 building, the block is Your move and a strip of at most two lines" {
    var json: std.ArrayList(u8) = .empty;
    defer json.deinit(std.testing.allocator);
    try json.appendSlice(std.testing.allocator, "{\"tickets\":[");
    for (0..5) |i| {
        if (i > 0) try json.append(std.testing.allocator, ',');
        try json.print(std.testing.allocator, "{{\"id\":{d},\"repo\":\"arena\",\"title\":\"t\",\"status\":\"doing\",\"claimed_by\":\"%{d}\",\"claimed_at\":\"2026-11-21T10:00:00Z\"}}", .{ i + 1, i + 1 });
    }
    try json.appendSlice(std.testing.allocator, "],\"needs_you\":[],\"auto\":{\"on\":true,\"cap\":6,\"working\":5},\"plan\":{\"next\":[");
    for (0..8) |i| {
        if (i > 0) try json.append(std.testing.allocator, ',');
        try json.print(std.testing.allocator, "{{\"ticket\":{d},\"repo\":\"arena\",\"title\":\"n\",\"why\":\"\",\"set_by\":\"orchestrator\"}}", .{i + 100});
    }
    try json.appendSlice(std.testing.allocator, "]}}");
    var b = try tickets.Board.parse(std.testing.allocator, json.items);
    defer b.deinit();
    var f: Feed = undefined;
    build(&f, &b, &.{}, 56, 40, now, 0, null);
    try std.testing.expect(f.height() <= 3);
    try std.testing.expectEqual(Kind.strip, f.line(f.height() - 1).kind);
    var out: [64][]const u8 = undefined;
    const got = texts(&f, &out);
    try std.testing.expectEqualStrings("▷ next 8   ◐ building 5   ✓ 0 today   auto 5/6", got[got.len - 1]);

    const height = f.height();
    build(&f, &b, &.{}, 56, 40, now, 0, .next);
    try std.testing.expectEqual(height, f.height());
    try std.testing.expect(f.count() > height);
}

test "a short column cuts Your move to whole items and says how many more, and keeps the rest" {
    var b = try tickets.Board.parse(std.testing.allocator, sample);
    defer b.deinit();
    var f: Feed = undefined;
    build(&f, &b, &.{}, 56, 12, now, 0, null);
    try std.testing.expectEqual(@as(usize, 5), f.count());
    try std.testing.expectEqualStrings("⏎ go   x no", f.line(2).text);
    try std.testing.expectEqualStrings("↓ 2 more", f.line(3).text);
    try std.testing.expectEqual(Kind.strip, f.line(4).kind);
}

test "more items than the feed holds are counted in ↓ N more, and only whole items are shown" {
    var json: std.ArrayList(u8) = .empty;
    defer json.deinit(std.testing.allocator);
    try json.appendSlice(std.testing.allocator, "{\"tickets\":[],\"needs_you\":[");
    for (0..60) |i| {
        if (i > 0) try json.append(std.testing.allocator, ',');
        try json.print(std.testing.allocator, "{{\"id\":\"ask:{d}\",\"kind\":\"ask\",\"ticket\":{d},\"repo\":\"arena\",\"text\":\"#{d} arena  asks: Q?\"," ++
            "\"actions\":[{{\"key\":\"1\",\"label\":\"A\",\"argv\":[\"babylon\",\"answer\",\"{d}\",\"1\"]}}]}}", .{ i, i + 100, i + 100, i });
    }
    try json.appendSlice(std.testing.allocator, "]}");
    var b = try tickets.Board.parse(std.testing.allocator, json.items);
    defer b.deinit();
    var f: Feed = undefined;
    build(&f, &b, &.{}, 56, 400, now, 0, null);
    try std.testing.expect(f.items_shown < 60);
    var want: [16]u8 = undefined;
    try std.testing.expectEqualStrings(try std.fmt.bufPrint(&want, "↓ {d} more", .{60 - f.items_shown}), f.line(f.shown).text);
    try std.testing.expectEqualStrings("1 A", f.line(f.shown - 1).text);
}

test "with nothing that needs the human, the feed shrinks to one dim line above the rest" {
    var b = try tickets.Board.parse(std.testing.allocator,
        \\{"tickets":[{"id":1,"title":"a","status":"todo"}],"needs_you":[]}
    );
    defer b.deinit();
    var f: Feed = undefined;
    build(&f, &b, &.{}, 56, 40, now, 0, null);
    try std.testing.expectEqual(@as(usize, 2), f.count());
    try std.testing.expectEqual(Kind.quiet, f.line(0).kind);
    try std.testing.expectEqualStrings("✓ 0 today", f.line(1).text);
}

test "the pick goes through Your move's items, then the strip's chips, then the open list's tickets, where each is drawn" {
    var b = try tickets.Board.parse(std.testing.allocator, sample);
    defer b.deinit();
    var f: Feed = undefined;
    build(&f, &b, &.{}, 56, 80, now, 0, null);
    try std.testing.expectEqual(@as(usize, 6), f.itemCount());
    try std.testing.expectEqual(Item{ .line = 1, .ticket = 7, .need = 0 }, f.item(0).?);
    try std.testing.expectEqual(Item{ .line = 5, .ticket = 12, .need = 2 }, f.item(2).?);
    try std.testing.expectEqual(Item{ .line = 7, .at = 0, .w = 12, .chip = true, .section = .building }, f.item(3).?);
    try std.testing.expectEqual(Item{ .line = 7, .at = 15, .w = 11, .chip = true, .section = .landing }, f.item(4).?);
    try std.testing.expectEqual(@as(?Item, null), f.item(6));

    build(&f, &b, &.{}, 56, 80, now, 0, .landing);
    try std.testing.expectEqual(@as(usize, 9), f.itemCount());
    try std.testing.expectEqual(Item{ .line = 9, .at = 0, .w = 24, .ticket = 15 }, f.item(5).?);
    try std.testing.expectEqual(Item{ .line = 9, .at = 27, .w = 19, .ticket = 18 }, f.item(6).?);
    try std.testing.expectEqual(@as(?u32, 17), f.item(7).?.ticket);
    try std.testing.expectEqual(@as(?Section, .landed), f.item(8).?.section);
}

test "an item babylon refused says why in place of its buttons" {
    var b = try tickets.Board.parse(std.testing.allocator, sample);
    defer b.deinit();
    var f: Feed = undefined;
    build(&f, &b, &.{.{ .id = "ask:3", .text = "babylon: no session to answer" }}, 56, 80, now, 0, null);
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
    build(&f, &b, &.{}, 70, 80, now, 0, .next);
    var out: [64][]const u8 = undefined;
    const got = texts(&f, &out);
    try std.testing.expectEqualStrings("▷ next 2   ◐ building 2   ✓ 0 today   auto 4/6", got[1]);
    try std.testing.expectEqualStrings("▷ next 2 · 2 slots idle", got[2]);
    try std.testing.expectEqualStrings("▪ #655 arena  Typing reaches no pane", got[3]);
    try std.testing.expectEqualStrings("#656 babylon  Held lines", got[4]);
    try std.testing.expectEqualStrings("▪ #655 arena  third sighting", f.line(3).alt);
}

test "babylon's refusal of a next key is said under that ticket's row" {
    var b = try tickets.Board.parse(std.testing.allocator, planned);
    defer b.deinit();
    var f: Feed = undefined;
    const refused = [_]Refusal{.{ .id = "next:656", .text = "refused: ticket #656 is claimed by pane %1010" }};
    build(&f, &b, &refused, 70, 80, now, 0, .next);
    var out: [64][]const u8 = undefined;
    const got = texts(&f, &out);
    try std.testing.expectEqualStrings("#656 babylon  Held lines", got[4]);
    try std.testing.expectEqualStrings("refused: ticket #656 is claimed by pane %1010", got[5]);
    try std.testing.expectEqual(Kind.next_refused, f.line(5).kind);
    try std.testing.expectEqual(@as(?u32, 656), f.item(2).?.ticket);
}

test "the pick goes through next's tickets" {
    var b = try tickets.Board.parse(std.testing.allocator, planned);
    defer b.deinit();
    var f: Feed = undefined;
    build(&f, &b, &.{}, 70, 80, now, 0, .next);
    try std.testing.expectEqual(@as(?usize, 0), f.item(1).?.next);
    try std.testing.expectEqual(@as(?u32, 655), f.item(1).?.ticket);
    try std.testing.expectEqual(@as(?usize, 1), f.item(2).?.next);
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
    build(&f, &b, &.{}, 56, 80, now, 0, null);
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
    build(&f, &b, &.{}, 56, 80, now, 0, null);
    var out: [64][]const u8 = undefined;
    const got = texts(&f, &out);
    try std.testing.expectEqualStrings("#307 tlon  look at: docs/asterion.md", got[1]);
    try std.testing.expectEqualStrings("o open   y looks good   c change", got[2]);
}

pub const try_sample =
    \\{"tickets":[],"needs_you":[
    \\{"id":"ask:3","kind":"ask","ticket":16,"repo":"arena","text":"#16 arena  asks: Blue?","actions":[]},
    \\{"id":"sendback:12","kind":"sendback","ticket":12,"repo":"arena","text":"✗ #12 arena  sent back","actions":[]},
    \\{"id":"try:825","kind":"try","ticket":825,"repo":"tlon","text":"#825 tlon  house soak day","since":"2026-11-21T10:00:00Z",
    \\ "machine":"soak day ✓  gate ✓  review ✓   landed f962a56",
    \\ "steps":[
    \\  {"n":1,"text":"remind me in two minutes: it is told, with buttons","result":null,"actions":[
    \\   {"key":"y","label":"✓","argv":["babylon","tried","825","1","ok"]},
    \\   {"key":"n","label":"✗","argv":["babylon","tried","825","1","no"],"needs":"words"}]},
    \\  {"n":2,"text":"how much have I spent this week","result":"ok","actions":[]},
    \\  {"n":3,"text":"add a to-do from the phone","result":null,"actions":[
    \\   {"key":"y","label":"✓","argv":["babylon","tried","825","3","ok"]},
    \\   {"key":"n","label":"✗","argv":["babylon","tried","825","3","no"],"needs":"words"}]}],
    \\ "actions":[{"key":"x","label":"close untried","argv":["babylon","tried","825","skip"]}]},
    \\{"id":"try:811","kind":"try","ticket":811,"repo":"arena","text":"#811 arena  plan · board tabs","since":"2026-11-10T10:00:00Z",
    \\ "machine":"gate ✓  review ✓   landed 3c1e9a0",
    \\ "steps":[{"n":1,"text":"click plan","result":null,"actions":[
    \\   {"key":"y","label":"✓","argv":["babylon","tried","811","1","ok"]},
    \\   {"key":"n","label":"✗","argv":["babylon","tried","811","1","no"],"needs":"words"}]}],
    \\ "actions":[{"key":"x","label":"close untried","argv":["babylon","tried","811","skip"]}]}
    \\]}
;

fn kindsOf(f: *const Feed, kind: Kind) usize {
    var n: usize = 0;
    for (0..f.shown) |i| n += @intFromBool(f.line(i).kind == kind);
    return n;
}

test "to try is a section after the decisions and before the send-backs, a tile for each ticket, a row for each check" {
    var b = try tickets.Board.parse(std.testing.allocator, try_sample);
    defer b.deinit();
    var f: Feed = undefined;
    build(&f, &b, &.{}, 56, 80, now, 0, null);
    const eq = std.testing.expectEqual;
    const eql = std.testing.expectEqualStrings;

    try eq(Kind.move_head, f.line(0).kind);
    try eq(Kind.item, f.line(1).kind);
    try eq(Kind.try_head, f.line(2).kind);
    try eql("── to try 2 ", f.line(2).text);
    try eq(Kind.try_title, f.line(3).kind);
    try eql("#825 tlon  house soak day", f.line(3).text);
    try eql("2h", f.line(3).alt);
    try std.testing.expect(!f.line(3).old);
    try eq(Kind.try_machine, f.line(4).kind);
    try eql("soak day ✓  gate ✓  review ✓   landed f962a56", f.line(4).text);
    try eq(@as(usize, 5), kindsOf(&f, .try_step));
    try std.testing.expect(f.line(f.shown - 1).failed);

    // the wrapped check keeps its number on its first row, a settled one is marked
    try eql("1 remind me in two minutes: it is told, with", f.line(5).text);
    try eql("  buttons", f.line(6).text);
    try std.testing.expect(!f.line(5).settled);
    try std.testing.expect(f.line(7).settled);
    try eql("2 how much have I spent this week", f.line(7).text);

    // a ticket waiting a week or more says so, and the tile is one item for each open check
    try eql("11d", f.line(f.shown - 4).alt);
    try std.testing.expect(f.line(f.shown - 4).old);
    try eq(@as(usize, 5), f.items_shown);
    try eq(@as(?usize, 0), f.item(1).?.step);
    try eq(@as(?usize, 2), f.item(2).?.step);
    try eq(@as(?usize, 0), f.item(3).?.step);
    try eq(@as(?u32, 825), f.item(2).?.ticket);
    try eq(@as(?usize, 2), f.item(2).?.need);
    try eq(@as(?usize, 1), f.item(4).?.need);
}

test "only the picked check shows its buttons, and only its tile the close untried button" {
    var b = try tickets.Board.parse(std.testing.allocator, try_sample);
    defer b.deinit();
    var f: Feed = undefined;
    build(&f, &b, &.{}, 56, 80, now, 0, null);
    try std.testing.expectEqual(@as(usize, 0), kindsOf(&f, .try_buttons));

    buildPicked(&f, &b, &.{}, 56, 80, now, 0, null, 2);
    try std.testing.expectEqual(@as(usize, 1), kindsOf(&f, .try_buttons));
    var row: usize = 0;
    while (f.line(row).kind != .try_buttons) row += 1;
    try std.testing.expectEqualStrings("y ✓   n ✗", f.line(row).text);
    try std.testing.expectEqual(@as(?usize, 2), f.line(row).step);
    try std.testing.expectEqual(f.item(2).?.line + 1, row);
    var close: usize = 0;
    for (0..f.shown) |i| if (f.line(i).kind == .try_machine and f.line(i).alt.len > 0) {
        close += 1;
        try std.testing.expectEqualStrings("x close untried", f.line(i).alt);
        try std.testing.expectEqual(@as(?usize, 2), f.line(i).need);
    };
    try std.testing.expectEqual(@as(usize, 1), close);
}
