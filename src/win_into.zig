const std = @import("std");
const theme = @import("theme.zig");
const bench = @import("parts.zig");
const app_mod = @import("app.zig");
const draw = @import("draw.zig");
const sheets = @import("plan.zig");
const win_goals = @import("win_goals.zig");
const win_plan = @import("win_plan.zig");
const keys = @import("keys.zig");
const anyKey = app_mod.anyKey;
const App = app_mod.App;
const Writer = std.Io.Writer;
const clip = draw.clip;

/// The most goals the picker lists: the rest are one `babylon update N --epic M` away.
const max_rows = 32;

/// A place a ticket can go: an open goal, or none.
pub const Place = struct { epic: ?u32, title: []const u8, landed: u32 = 0, total: u32 = 0 };

/// The places of the picker: the open goals, the driven one first, then no goal.
pub fn places(app: *const App, out: *[max_rows + 1]Place) []Place {
    const given = (app.board orelse return out[0..0]).plan() orelse return out[0..0];
    var n: usize = 0;
    for ([_]bool{ true, false }) |driven| for (given.goals) |goal| {
        if ((given.driving == goal.epic) != driven or n == max_rows) continue;
        out[n] = .{ .epic = goal.epic, .title = goal.name(), .landed = goal.landed, .total = goal.total };
        n += 1;
    };
    out[n] = .{ .epic = null, .title = "no goal" };
    return out[0 .. n + 1];
}

/// The picker's frame in the middle column: a title bar, a row a place, a blank and the buttons.
pub fn rect(app: *const App) ?App.ModalRect {
    const col = app.columnRect() orelse return null;
    var found: [max_rows + 1]Place = undefined;
    const h: u16 = @intCast(places(app, &found).len + 4);
    if (col.w < 30 or col.h < h) return null;
    return .{ .x = col.x, .y = col.y, .w = col.w, .h = h };
}

/// `into which goal?` for ticket `id`, the pick on its place now.
pub fn open(app: *App, id: u32) void {
    const view = &app.home.?;
    var found: [max_rows + 1]Place = undefined;
    const all = places(app, &found);
    const now = if (app.cardById(id)) |card| card.epic_id else null;
    var at: usize = 0;
    for (all, 0..) |place, i| if (place.epic == now) {
        at = i;
        break;
    };
    view.into = id;
    view.into_pick = at;
    app.dirty = true;
}

/// `babylon update N --epic M`, or `--epic none`: ticket `id` moved into goal `to`, or out of its goal.
pub fn move(app: *App, id: u32, to: ?u32) !void {
    var ticket: [12]u8 = undefined;
    var epic: [12]u8 = undefined;
    var said: [24]u8 = undefined;
    const number = std.fmt.bufPrint(&ticket, "{d}", .{id}) catch return;
    const goal = if (to) |m| std.fmt.bufPrint(&epic, "{d}", .{m}) catch return else "none";
    const refusal = std.fmt.bufPrint(&said, "epic:{d}", .{id}) catch return;
    _ = try app.runNeed(refusal, &.{ "babylon", "update", number, "--epic", goal });
}

/// Ticket `id` let go on `hit` of the plan: into the goal under it, or out of its goal over no
/// goal. False where the spot is neither, for the caller to read.
pub fn drop(app: *App, sheet: *const sheets.Sheet, hit: win_plan.PlanHit, id: u32) !bool {
    const place: ?u32 = switch (hit.win) {
        .goals => if (hit.title) return true else win_goals.epicOf(app, &sheet.rows[hit.row orelse return true]) orelse return true,
        .no_goal => if (hit.title) return true else null,
        else => return false,
    };
    const card = app.cardById(id) orelse return true;
    if (card.epic_id != place) try move(app, id, place);
    return true;
}

/// A key in the picker: `j` `k` pick, `⏎` moves the ticket, `esc` or `q` puts it away.
pub fn key(app: *App, pressed: []const u8) !void {
    const view = &app.home.?;
    const ticket = view.into orelse return;
    var found: [max_rows + 1]Place = undefined;
    const all = places(app, &found);
    app.dirty = true;
    if (anyKey(pressed, &.{ "\x1b", "q" })) view.into = null;
    if (anyKey(pressed, &.{ "j", "\x1b[B", "\x1bOB" })) view.into_pick = @min(view.into_pick + 1, all.len -| 1);
    if (anyKey(pressed, &.{ "k", "\x1b[A", "\x1bOA" })) view.into_pick -|= 1;
    if (!anyKey(pressed, &.{"\r"}) or view.into_pick >= all.len) return;
    view.into = null;
    try move(app, ticket, all[view.into_pick].epic);
}

/// A click in the picker: its ✕ or outside it puts it away, a place moves the ticket there.
pub fn click(app: *App, m: keys.Mouse) !void {
    const view = &app.home.?;
    if (view.into == null) return;
    const box = rect(app) orelse {
        view.into = null;
        return;
    };
    const close = m.y == box.y and m.x + 4 >= box.x + box.w and m.x + 2 <= box.x + box.w;
    if (close or !box.contains(m.x, m.y)) {
        view.into = null;
        return;
    }
    var found: [max_rows + 1]Place = undefined;
    const all = places(app, &found);
    const foot = box.y + box.h - 2;
    if (m.y > box.y and m.y < box.y + 1 + all.len) {
        view.into_pick = m.y - box.y - 1;
        return key(app, "\r");
    }
    if (m.y != foot) return;
    if (m.x < box.x + 16) return key(app, "\r");
    return key(app, "\x1b");
}

pub fn paint(app: *App, w: *Writer) !void {
    const view = app.home orelse return;
    const ticket = view.into orelse return;
    const r = app.roles orelse return;
    const box = rect(app) orelse return;
    var found: [max_rows + 1]Place = undefined;
    const all = places(app, &found);
    const now = if (app.cardById(ticket)) |card| card.epic_id else null;
    var title: [48]u8 = undefined;
    try bench.window(w, r, box.x, box.y, box.w - 1, box.h, std.fmt.bufPrint(&title, "#{d} into which goal?", .{ticket}) catch "into which goal?", null, true);
    try bench.say(w, box.x + box.w - 5, box.y, " × ", r.text, r.panel, true);
    const inner: usize = box.w - 5;
    for (all, 0..) |place, i| {
        const y = box.y + 1 + @as(u16, @intCast(i));
        const picked = i == view.into_pick;
        const bg = if (picked) r.raised else r.panel;
        try bench.fill(w, box.x + 1, y, box.w - 3, bg);
        if (picked) try bench.say(w, box.x + 1, y, "❯", r.accent, bg, true);
        var count: [24]u8 = undefined;
        const tail = if (place.epic == now)
            "✓ here"
        else if (place.epic != null)
            std.fmt.bufPrint(&count, "{d}/{d}", .{ place.landed, place.total }) catch ""
        else
            "";
        var head: [16]u8 = undefined;
        const id = if (place.epic) |epic| std.fmt.bufPrint(&head, "◆ #{d} ", .{epic}) catch "" else "";
        try bench.say(w, box.x + 3, y, id, r.accent, bg, false);
        const x = box.x + 3 + draw.cellCount(id);
        try bench.say(w, x, y, clip(place.title, inner -| (x - box.x) -| draw.cellCount(tail) -| 2), r.text, bg, picked);
        try bench.say(w, box.x + box.w - 3 - draw.cellCount(tail), y, tail, r.dim, bg, false);
    }
    const foot = box.y + box.h - 2;
    try bench.headButton(w, r, box.x + 3, foot, " ⏎ move it ", r.accent, true);
    try bench.headButton(w, r, box.x + 17, foot, " esc cancel ", r.dim, false);
}
