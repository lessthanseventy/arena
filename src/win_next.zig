const std = @import("std");
const color = @import("color.zig");
const theme = @import("theme.zig");
const bench = @import("parts.zig");
const app_mod = @import("app.zig");
const tickets = @import("board.zig");
const sheets = @import("plan.zig");
const draw = @import("draw.zig");
const win_detail = @import("win_detail.zig");
const win_board = @import("win_board.zig");
const anyKey = app_mod.anyKey;
const App = app_mod.App;
const Writer = std.Io.Writer;
const sayCut = draw.sayCut;
const cellCount = draw.cellCount;
const repoHue = draw.repoHue;

/// The chip of a next row: why it has not started, from babylon's `held`, else what it waits on.
pub fn nextLabel(item: tickets.Next, lbuf: []u8) []const u8 {
    if (item.held) |h| {
        var wbuf: [32]u8 = undefined;
        return std.fmt.bufPrint(lbuf, "{s}", .{h.word(&wbuf)}) catch "held";
    }
    const first = tickets.Wait.first(item.waits_on);
    return if (first) |wt| if (wt.ticket) |t|
        std.fmt.bufPrint(lbuf, "\u{f0c1} waits #{d}", .{t}) catch "waits"
    else
        std.fmt.bufPrint(lbuf, "\u{f0c1} after #{d}", .{wt.until.?}) catch "waits" else "ready";
}

/// Where a next row's name starts and the cells it has before its chip, in a window `ww` cells
/// wide.
pub fn titleRoom(item: tickets.Next, ww: usize) struct { x: usize, room: usize } {
    var idb: [16]u8 = undefined;
    const id = std.fmt.bufPrint(&idb, "#{d}", .{item.ticket}) catch "";
    var lbuf: [48]u8 = undefined;
    const chip_x = ww -| (cellCount(nextLabel(item, &lbuf)) + 3);
    const title_x = 7 + cellCount(id);
    return .{ .x = title_x, .room = chip_x -| title_x -| 1 };
}

/// The block under an opened next row, in a window `ww` cells wide: its why, what it waits on and
/// its place in next.
pub fn detail(app: *const App, row: sheets.Row, ww: usize, lines: *sheets.Lines) void {
    const item = app.board.?.plan().?.next[row.item];
    var age: [16]u8 = undefined;
    const filed = sheets.ago(&age, if (app.cardById(item.ticket)) |card| card.inserted_at else null, app.epoch);
    const stage = lines.print("todo{s} · next {d}{s}{s}", .{ if (item.pinned()) " · pinned" else "", row.item + 1, if (filed.len > 0) " · filed " else "", filed });
    const indent: u8 = if (row.win == .board) win_board.id_x else @intCast(titleRoom(item, ww).x);
    win_detail.fill(app, lines, .{ .ticket = item.ticket, .title = item.name(), .why = item.why, .wait = win_detail.waitWords(lines, item.waits_on), .stage = stage }, ww, indent);
}

pub fn paint(app: *App, w: *Writer, r: theme.Roles, sheet: *const sheets.Sheet, at: usize, y: u16, x0: usize, ww: usize, lit: bool) !void {
    const given = app.board.?.plan().?;
    const row = sheet.rows[at];
    const picked = lit and app.planRowLit(row);
    const mark = if (app.columnFocused()) r.dim else r.accent;
    const bg = if (picked) r.raised else r.panel;
    switch (row.kind) {
        .next => {
            const item = given.next[row.item];
            try bench.fill(w, x0, y, ww, bg);
            if (picked) try bench.say(w, x0, y, "▌", mark, bg, true);
            var nb: [16]u8 = undefined;
            try bench.say(w, x0 + 2, y, std.fmt.bufPrint(&nb, "{d}", .{row.item + 1}) catch "", r.dim, bg, false);
            const repo = repoHue(r, item.repo);
            var idb: [16]u8 = undefined;
            const id = std.fmt.bufPrint(&idb, "#{d}", .{item.ticket}) catch "";
            try bench.say(w, x0 + 1, y, "▌", repo.hue, bg, false);
            try bench.say(w, x0 + 4, y, repo.glyph, repo.hue, bg, false);
            try bench.say(w, x0 + 6, y, id, repo.hue, bg, true);
            var lbuf: [48]u8 = undefined;
            const ready = if (item.held) |_| false else tickets.Wait.first(item.waits_on) == null;
            const label = nextLabel(item, &lbuf);
            const chip_x = x0 + ww -| (cellCount(label) + 3);
            const title_x = x0 + 7 + cellCount(id);

            _ = try bench.chipInk(w, r, chip_x, y, label, if (ready) r.landed else r.dim, if (ready) r.text else r.dim, false);
            try sayCut(w, title_x, y, item.name(), titleRoom(item, ww).room, if (row.dim) r.dim else r.text, bg, false);
        },
        else => {},
    }
}

test "each held reason draws its word; no held draws as before" {
    const cases = [_]struct { why: []const u8, by: ?u32, word: []const u8 }{
        .{ .why = "blocked", .by = 7, .word = "waits #7" },
        .{ .why = "repo cap", .by = 1186, .word = "after #1186" },
        .{ .why = "overlap", .by = 1172, .word = "after #1172" },
        .{ .why = "cap", .by = null, .word = "cap full" },
        .{ .why = "off", .by = null, .word = "auto off" },
        .{ .why = "starting", .by = null, .word = "starting" },
        .{ .why = "asked", .by = 4, .word = "asked" },
        .{ .why = "sent back", .by = null, .word = "needs you" },
        .{ .why = "repo not ready", .by = null, .word = "no repo dir" },
        .{ .why = "queued", .by = null, .word = "queued" },
        .{ .why = "not todo", .by = null, .word = "not todo" },
        .{ .why = "project held", .by = null, .word = "held" },
        .{ .why = "project off", .by = null, .word = "manual" },
        .{ .why = "project cap", .by = null, .word = "cap full" },
    };
    var lbuf: [48]u8 = undefined;
    for (cases) |c| {
        const item: tickets.Next = .{ .ticket = 1, .held = .{ .why = c.why, .by = c.by } };
        try std.testing.expectEqualStrings(c.word, nextLabel(item, &lbuf));
    }
    try std.testing.expectEqualStrings("ready", nextLabel(.{ .ticket = 1 }, &lbuf));
    var waits = [_]tickets.Wait{.{ .ticket = 3 }};
    try std.testing.expect(std.mem.endsWith(u8, nextLabel(.{ .ticket = 1, .waits_on = &waits }, &lbuf), "waits #3"));
}

/// Enter on a row of next: starts its ticket.
pub fn act(app: *App, row: *const sheets.Row) !void {
    if (row.ticket) |id| try app.send(.ignore, app_mod.captured("babylon start {d}"), .{id});
}

/// A key on a ticket of next, the `at`th: `J` and `K` move it down and up, `x` drops it from
/// next and `p` pins it where it is. Each goes through babylon as the human, which marks the
/// ticket as the human's, so the orchestrator moves it only with a proposal.
pub fn nextKey(app: *App, at: usize, pick: *usize, key: []const u8) !bool {
    const b = if (app.board) |*b| b else return false;
    const plan = b.next();
    if (at >= plan.len) return false;
    var id: [12]u8 = undefined;
    var place: [12]u8 = undefined;
    const ticket = std.fmt.bufPrint(&id, "{d}", .{plan[at].ticket}) catch return true;
    var said: [24]u8 = undefined;
    const refusal = std.fmt.bufPrint(&said, "next:{d}", .{plan[at].ticket}) catch return true;
    if (anyKey(key, &.{"x"})) return app.runNeed(refusal, &.{ "babylon", "next", ticket, "--drop" });
    if (anyKey(key, &.{"p"})) {
        const here = std.fmt.bufPrint(&place, "{d}", .{at + 1}) catch return true;
        return app.runNeed(refusal, &.{ "babylon", "next", ticket, "--at", here });
    }
    const down = anyKey(key, &.{"J"});
    if (!down and !anyKey(key, &.{"K"})) return false;
    if (if (down) at + 1 >= plan.len else at == 0) return true;
    const to = std.fmt.bufPrint(&place, "{d}", .{if (down) at + 2 else at}) catch return true;
    pick.* = if (down) pick.* + 1 else pick.* - 1;
    return app.runNeed(refusal, &.{ "babylon", "next", ticket, "--at", to });
}

/// A press on the next row at `at`: it is held, to be dragged to another place or opened where it was pressed.
pub fn nextPress(app: *App, sheet: *const sheets.Sheet, at: usize) void {
    app.drag = .{ .next_row = .{ .from = App.nextPlace(sheet, at), .opens = true } };
}
