const std = @import("std");
const color = @import("color.zig");
const theme = @import("theme.zig");
const bench = @import("parts.zig");
const app_mod = @import("app.zig");
const tickets = @import("board.zig");
const sheets = @import("plan.zig");
const draw = @import("draw.zig");
const anyKey = app_mod.anyKey;
const App = app_mod.App;
const Writer = std.Io.Writer;
const sayCut = draw.sayCut;
const cellCount = draw.cellCount;
const repoHue = draw.repoHue;

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
            const first = tickets.Wait.first(item.waits_on);
            const label = if (first) |wt| if (wt.ticket) |t|
                std.fmt.bufPrint(&lbuf, "\u{f0c1} waits #{d}", .{t}) catch "waits"
            else
                std.fmt.bufPrint(&lbuf, "\u{f0c1} after #{d}", .{wt.until.?}) catch "waits" else "ready";
            const chip_x = x0 + ww -| (cellCount(label) + 3);
            const title_x = x0 + 7 + cellCount(id);
            const pin_w: usize = if (item.pinned()) 2 else 0;
            _ = try bench.chipInk(w, r, chip_x, y, label, if (first == null) r.landed else r.dim, if (first == null) r.text else r.dim, false);
            if (item.pinned()) try bench.say(w, chip_x -| 2, y, "\u{f08d}", r.accent, bg, false);
            try sayCut(w, title_x, y, item.title, chip_x -| title_x -| 1 -| pin_w, if (row.dim) r.dim else r.text, bg, false);
            try bench.say(w, x0 + ww, y, "▌", r.well, r.ground, false);
        },
        else => {},
    }
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
