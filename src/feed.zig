//! The feed atop the orchestrator's column: the human's move as babylon gives it, and nothing
//! else; the tickets in flight are Plan's.
const std = @import("std");
const tickets = @import("board.zig");
const Card = tickets.Card;
const runcheck = @import("runcheck.zig");

pub const Kind = enum { move_head, quiet, item, buttons, refused, more, try_head, try_title, try_machine, try_step, try_buttons };

/// The age past which a to-try tile's age is in the "you" colour.
pub const stale_days = 7;

/// The rows of the column's pane that Your move leaves.
const min_pane = 6;

/// babylon's refusal of what was asked of a Your move item, by the item's id: said in place of
/// its buttons.
/// What babylon refused, or arena says of a check it runs: a row a line, at most `note_rows`.
pub const Refusal = struct { id: []const u8, text: []const u8 };

pub const note_rows = 9;

/// The options of Claude Code's own question box on a ticket's pane, read off its screen.
pub const Box = struct { ticket: u32, options: []const []const u8 };

/// Something in the feed the pick can be on: a Your move item, its whole first line.
pub const Item = struct {
    line: usize,
    ticket: ?u32 = null,
    /// Its place in babylon's needs_you.
    need: ?usize = null,
    /// Of a to-try tile's item: its place in the need's steps; none while it has no open step.
    step: ?usize = null,
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
    /// A to-try tile's title its age, and its machine line the button its picked tile has.
    alt: []const u8 = "",
};

/// Lines and the text they point into.
const Part = struct {
    lines: [160]Line = undefined,
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

    /// `chips` laid along at most `rows` lines of `width` cells, three spaces apart, then `+N`
    /// for those left over.
    fn flow(p: *Part, kind: Kind, chips: []const []const u8, rows: usize, width: usize) void {
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
            p.add(kind, false, "{s}", .{w.buffered()});
        }
    }
};

pub const Feed = struct {
    move: Part = .{},
    /// The lines of Your move shown, and the items shown of it.
    shown: usize = 0,
    items_shown: usize = 0,
    more: [32]u8 = undefined,

    /// How many lines it takes in the column, where the pane starts under them.
    pub fn height(f: *const Feed) usize {
        return f.shown + @intFromBool(f.cut());
    }

    /// How many lines it draws.
    pub fn count(f: *const Feed) usize {
        return f.height();
    }

    /// Line `i` of it, from the top.
    pub fn line(f: *const Feed, i: usize) Line {
        if (i < f.shown) return f.move.lines[i];
        return .{ .kind = .more, .text = f.moreText() };
    }

    fn cut(f: *const Feed) bool {
        return f.items_shown < f.move.total;
    }

    /// How many things the pick can be on.
    pub fn itemCount(f: *const Feed) usize {
        return f.items_shown;
    }

    /// The `i`th thing the pick can be on: Your move's items.
    pub fn item(f: *const Feed, i: usize) ?Item {
        if (i >= f.items_shown) return null;
        return .{ .line = f.move.starts[i], .ticket = f.move.tickets[i], .need = f.move.need_at[i], .step = f.move.step_at[i] };
    }

    fn moreText(f: *const Feed) []const u8 {
        const buf: *[32]u8 = @constCast(&f.more);
        return std.fmt.bufPrint(buf, "↓ {d} more", .{f.move.total - f.items_shown}) catch "";
    }
};

/// The feed for `board`, its lines `width` cells wide in a column `rows` tall, as of `epoch`. Your
/// move keeps its head and first item and takes what a pane of `min_pane` rows leaves; the rest of
/// it is cut to whole items. An item babylon refused says why in place of its buttons.
pub fn build(f: *Feed, board: *const tickets.Board, refused: []const Refusal, width: usize, rows: usize, epoch: i64) void {
    buildPicked(f, board, refused, &.{}, width, rows, epoch, std.math.maxInt(usize));
}

/// `build` with the pick known: the item `pick` of Your move, which a to-try tile shows its
/// buttons under.
pub fn buildPicked(f: *Feed, board: *const tickets.Board, refused: []const Refusal, boxes: []const Box, width: usize, rows: usize, epoch: i64, pick: usize) void {
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
            const room = 3 + 3 * need.steps.len + 2 + @intFromBool(!rule) + note_rows;
            if (f.move.items + @max(1, openSteps(need)) > f.move.starts.len or f.move.n + room > f.move.lines.len) break :groups;
            if (!rule) f.move.add(.try_head, false, "── to try {d} ", .{tries});
            rule = true;
            var title = need.text;
            if (need.ticket) |id| for (board.cards()) |*card| if (card.id == id) {
                title = card.changed() orelse need.text;
            };
            tile(&f.move, need, title, need_at, refused, width, epoch, pick);
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
        const draft = std.mem.eql(u8, need.kind, "draft");
        f.move.add(.item, failed, "{s}{s}{s}", .{ if (draft) "draft · " else "", need.text, if (marked) " ¶" else "" });
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
        // a question box on the holder's pane: its options, answered by their number
        if (need.ticket) |id| for (boxes) |box| if (box.ticket == id) {
            for (box.options, 1..) |option, number| {
                if (n == chips.len) break;
                chips[n] = std.fmt.bufPrint(&bufs[n], "{d} {s}", .{ number, option }) catch continue;
                n += 1;
            }
        };
        // reading a draft is arena's own too: its modal
        if (draft and n < chips.len) {
            chips[n] = "space read it";
            n += 1;
        }
        const before = f.move.n;
        f.move.flow(.buttons, chips[0..n], 4, width -| 4);
        for (f.move.lines[before..f.move.n]) |*l| {
            l.failed = failed;
        }
    };

    // Your move may grow, the one block that does, but not into the last rows of the pane
    const room = rows -| min_pane;
    const floor = if (f.move.items > 0) @min(f.move.n, f.move.starts[0] + 2) else f.move.n;
    var want = @max(floor, room);
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
}

/// Whether `step` is read off a diff: its change is there to be looked at with `o`.
pub fn isLook(step: tickets.TryStep) bool {
    return std.mem.eql(u8, step.kind, "look") and step.range.len > 0;
}

/// Whether `step` has something `o` opens: its doc, or the landed change of a look.
pub fn opens(step: tickets.TryStep) bool {
    return step.doc != null or isLook(step);
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
fn tile(p: *Part, need: tickets.Need, title: []const u8, need_at: usize, refused: []const Refusal, width: usize, epoch: i64, pick: usize) void {
    const first = p.items;
    const count = @max(1, openSteps(need));
    const picked = pick >= first and pick < first + count;
    const since = tickets.epochOf(need.since);
    p.add(.try_title, false, "{s}", .{title});
    var age_buf: [8]u8 = undefined;
    p.alt("{s}", .{age(&age_buf, epoch, since)});
    p.lines[p.n - 1].old = if (since) |at| epoch - at >= stale_days * 86400 else false;
    p.lines[p.n - 1].need = need_at;
    p.add(.try_machine, false, "{s}", .{need.machine});
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
        var rows = std.mem.splitScalar(u8, why, '\n');
        while (rows.next()) |row| {
            p.add(.try_buttons, true, "{s}", .{row});
            p.lines[p.n - 1].need = need_at;
        }
    }
}

/// The buttons of check `at` of `need`, as babylon gives their keys and labels.
fn buttons(p: *Part, need: tickets.Need, at: usize) void {
    var line: [96]u8 = undefined;
    var w: std.Io.Writer = .fixed(&line);
    const step = need.steps[at];
    var found: [512]u8 = undefined;
    const runs = runcheck.find(step.text, &found).len > 0;
    const looks = opens(step);
    if (looks) w.writeAll("o open") catch {};
    // a look with a doc has its diff on `d`; one with no doc opens its diff on `o`
    if (step.doc != null and isLook(step)) w.writeAll("   d diff") catch {};
    if (runs) w.print("{s}r run", .{if (looks) "   " else ""}) catch {};
    for (step.actions, 0..) |action, k| {
        w.print("{s}{s} {s}", .{ if (k == 0 and !looks and !runs) "" else "   ", action.key, action.label }) catch break;
    }
    p.add(.try_buttons, false, "{s}", .{w.buffered()});
    p.lines[p.n - 1].need = p.lines[p.n - 2].need;
    p.lines[p.n - 1].step = at;
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

test "the feed draws babylon's needs_you as given, and nothing under it: no tabs, no lists of tickets" {
    var b = try tickets.Board.parse(std.testing.allocator, sample);
    defer b.deinit();
    var f: Feed = undefined;
    build(&f, &b, &.{}, 56, 80, now);
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
    try std.testing.expectEqual(move.len, got.len);
    for (move, got) |w, g| try std.testing.expectEqualStrings(w, g);
    try std.testing.expect(f.line(5).failed and f.line(6).failed and f.line(6).kind == .buttons);
    try std.testing.expect(!f.line(1).failed);
}

test "a short column cuts Your move to whole items and says how many more, and keeps the rest" {
    var b = try tickets.Board.parse(std.testing.allocator, sample);
    defer b.deinit();
    var f: Feed = undefined;
    build(&f, &b, &.{}, 56, 9, now);
    try std.testing.expectEqual(@as(usize, 4), f.count());
    try std.testing.expectEqualStrings("⏎ go   x no", f.line(2).text);
    try std.testing.expectEqualStrings("↓ 2 more", f.line(3).text);
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
    build(&f, &b, &.{}, 56, 400, now);
    try std.testing.expect(f.items_shown < 60);
    var want: [16]u8 = undefined;
    try std.testing.expectEqualStrings(try std.fmt.bufPrint(&want, "↓ {d} more", .{60 - f.items_shown}), f.line(f.shown).text);
    try std.testing.expectEqualStrings("1 A", f.line(f.shown - 1).text);
}

test "with nothing that needs the human, the feed is one dim line" {
    var b = try tickets.Board.parse(std.testing.allocator,
        \\{"tickets":[{"id":1,"title":"a","status":"todo"}],"needs_you":[]}
    );
    defer b.deinit();
    var f: Feed = undefined;
    build(&f, &b, &.{}, 56, 40, now);
    try std.testing.expectEqual(@as(usize, 1), f.count());
    try std.testing.expectEqual(Kind.quiet, f.line(0).kind);
}

test "the pick goes through Your move's items, where each is drawn" {
    var b = try tickets.Board.parse(std.testing.allocator, sample);
    defer b.deinit();
    var f: Feed = undefined;
    build(&f, &b, &.{}, 56, 80, now);
    try std.testing.expectEqual(@as(usize, 3), f.itemCount());
    try std.testing.expectEqual(Item{ .line = 1, .ticket = 7, .need = 0 }, f.item(0).?);
    try std.testing.expectEqual(Item{ .line = 5, .ticket = 12, .need = 2 }, f.item(2).?);
    try std.testing.expectEqual(@as(?Item, null), f.item(3));
}

test "an item babylon refused says why in place of its buttons" {
    var b = try tickets.Board.parse(std.testing.allocator, sample);
    defer b.deinit();
    var f: Feed = undefined;
    build(&f, &b, &.{.{ .id = "ask:3", .text = "babylon: no session to answer" }}, 56, 80, now);
    try std.testing.expectEqualStrings("#16 arena  asks: Blue?", f.line(3).text);
    try std.testing.expectEqual(Kind.refused, f.line(4).kind);
    try std.testing.expectEqualStrings("babylon: no session to answer", f.line(4).text);
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
    build(&f, &b, &.{}, 56, 80, now);
    var out: [64][]const u8 = undefined;
    const got = texts(&f, &out);
    try std.testing.expectEqualStrings("#307 tlon  asks: A or B? ¶", got[1]);
    try std.testing.expectEqualStrings("o open   1 A", got[2]);
    try std.testing.expectEqualStrings("#308 tlon  asks: C or D?", got[3]);
    try std.testing.expectEqualStrings("1 C", got[4]);
}

test "a draft is a tile with a draft chip, babylon's go and reply, and space to read it" {
    var b = try tickets.Board.parse(std.testing.allocator,
        \\{"tickets":[],"needs_you":[
        \\{"id":"ask:61","kind":"draft","ticket":830,"repo":"","text":"#830 money on the desktop bar\n7 steps in 3 repos: tlon 3, ficciones 3, babylon 1","doc":null,
        \\ "actions":[{"key":"y","label":"go","argv":["babylon","adopt","830"]},{"key":"r","label":"reply","argv":["babylon","answer","61","--words"],"needs":"words"}]}]}
    );
    defer b.deinit();
    var f: Feed = undefined;
    build(&f, &b, &.{}, 90, 80, now);
    var out: [64][]const u8 = undefined;
    const got = texts(&f, &out);
    try std.testing.expectEqualStrings("draft · #830 money on the desktop bar 7 steps in 3 repos: tlon 3, ficciones 3, babylon 1", got[1]);
    try std.testing.expectEqualStrings("y go   r reply   space read it", got[2]);
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
    build(&f, &b, &.{}, 56, 80, now);
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

test "a landed drive item's buttons in Your move are babylon's alone" {
    var b = try tickets.Board.parse(std.testing.allocator,
        \\{"tickets":[],"needs_you":[{"id":"drive:14","kind":"drive","ticket":14,"repo":"","text":"goal landed",
        \\"actions":[{"key":"1","label":"the board","argv":["babylon","drive","326"]}]}]}
    );
    defer b.deinit();
    var f: Feed = undefined;
    build(&f, &b, &.{}, 56, 40, now);
    var row: usize = 0;
    while (f.line(row).kind != .buttons) row += 1;
    try std.testing.expectEqualStrings("1 the board", f.line(row).text);
}

test "to try is a section after the decisions and before the send-backs, a tile for each ticket, a row for each check" {
    var b = try tickets.Board.parse(std.testing.allocator, try_sample);
    defer b.deinit();
    var f: Feed = undefined;
    build(&f, &b, &.{}, 56, 80, now);
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

test "only the picked check shows its buttons, and no tile has a close untried button" {
    var b = try tickets.Board.parse(std.testing.allocator, try_sample);
    defer b.deinit();
    var f: Feed = undefined;
    build(&f, &b, &.{}, 56, 80, now);
    try std.testing.expectEqual(@as(usize, 0), kindsOf(&f, .try_buttons));

    buildPicked(&f, &b, &.{}, &.{}, 56, 80, now, 2);
    try std.testing.expectEqual(@as(usize, 1), kindsOf(&f, .try_buttons));
    var row: usize = 0;
    while (f.line(row).kind != .try_buttons) row += 1;
    try std.testing.expectEqualStrings("y ✓   n ✗", f.line(row).text);
    try std.testing.expectEqual(@as(?usize, 2), f.line(row).step);
    try std.testing.expectEqual(f.item(2).?.line + 1, row);
    for (0..f.shown) |i| try std.testing.expectEqualStrings("", if (f.line(i).kind == .try_machine) f.line(i).alt else "");
}

test "a stopped session whose pane shows Claude Code's question box lists its options as buttons" {
    var b = try tickets.Board.parse(std.testing.allocator,
        \\{"tickets":[],"needs_you":[{"id":"stop:915","kind":"stopped","ticket":915,"repo":"arena","text":"stopped #915 29m","actions":[]}]}
    );
    defer b.deinit();
    var f: Feed = undefined;
    buildPicked(&f, &b, &.{}, &.{.{ .ticket = 915, .options = &.{ "Narrow", "Wide" } }}, 56, 80, now, 0);
    try std.testing.expectEqualStrings("stopped #915 29m", f.line(1).text);
    try std.testing.expectEqualStrings("1 Narrow   2 Wide", f.line(2).text);
    try std.testing.expectEqualStrings("1", chipKeyAt(f.line(2).text, 4, true).?);
    try std.testing.expectEqualStrings("2", chipKeyAt(f.line(2).text, 20, true).?);
    buildPicked(&f, &b, &.{}, &.{}, 56, 80, now, 0);
    try std.testing.expectEqual(@as(usize, 0), kindsOf(&f, .buttons));
}

test "the feed holds only Your move: what is building, queued, next or landed has no line in it" {
    var b = try tickets.Board.parse(std.testing.allocator,
        \\{"tickets":[{"id":14,"repo":"arena","title":"building one","status":"doing","claimed_by":"%3","claimed_at":"2026-11-21T10:00:00Z"},
        \\{"id":17,"repo":"arena","title":"queued one","status":"review","stage":"queued","submitted_at":"2026-11-21T11:30:00Z"},
        \\{"id":9,"repo":"arena","title":"landed one","status":"done","stage":"landed","closed_at":"2026-11-21T11:30:00Z"}],
        \\"needs_you":[{"id":"ask:3","kind":"ask","ticket":16,"repo":"arena","text":"#16 arena  asks: Blue?","actions":[]}],
        \\"auto":{"on":true,"cap":6,"working":4,"idle":{"slots":2,"why":"next empty"}},
        \\"plan":{"next":[{"ticket":655,"repo":"arena","title":"Typing","why":"third","set_by":"human"}]}}
    );
    defer b.deinit();
    var f: Feed = undefined;
    build(&f, &b, &.{}, 56, 80, now);
    try std.testing.expectEqual(@as(usize, 1), f.itemCount());
    for (0..f.count()) |i| {
        for ([_][]const u8{ "building", "queued", "landed", "Typing", "idle", "next", "today" }) |gone| {
            try std.testing.expect(std.mem.indexOf(u8, f.line(i).text, gone) == null);
        }
    }
}
