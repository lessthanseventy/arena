const std = @import("std");
const theme = @import("theme.zig");
const bench = @import("parts.zig");
const app_mod = @import("app.zig");
const tickets = @import("board.zig");
const sheets = @import("plan.zig");
const feed = @import("feed.zig");
const draw = @import("draw.zig");
const win_feed = @import("win_feed.zig");
const win_goals = @import("win_goals.zig");
const App = app_mod.App;
const Writer = std.Io.Writer;
const clip = draw.clip;
const cellCount = draw.cellCount;
const repoHue = draw.repoHue;

pub fn paint(app: *App, w: *Writer, r: theme.Roles, sheet: *const sheets.Sheet, at: usize, y: u16, x0: usize, ww: usize, lit: bool) !void {
    const row = sheet.rows[at];
    if (row.kind != .need) return;
    const need = app.board.?.needsYou()[row.item];
    const opened = isOpen(app, row);
    const picked = (lit and app.planRowLit(row)) or opened;
    const mark = if (app.columnFocused()) r.dim else r.accent;
    const bg = if (picked) r.raised else r.panel;
    try bench.fill(w, x0, y, ww, bg);
    if (picked) try bench.say(w, x0, y, "▌", mark, bg, true);
    if (opened) try bench.say(w, x0 + 1, y, "▸", r.accent, bg, true);
    const failed = isSendBack(need);
    const text_row = isSuggestion(need);
    try bench.say(w, x0 + 2, y, if (text_row) "◆" else if (failed) "✗" else "▲", if (text_row) r.accent else if (failed) r.failed else r.you, bg, true);
    var x = x0 + 4;
    if (need.orch) {
        try bench.say(w, x, y, "◆ orch", r.accent, bg, true);
        x += cellCount("◆ orch") + 1;
    }
    if (text_row) {
        try bench.say(w, x, y, tell, r.accent, bg, false);
        x += cellCount(tell);
    }
    if (need.ticket) |id| if (std.mem.indexOfScalar(u8, need.text, '#') == null) {
        var buf: [64]u8 = undefined;
        const label = std.fmt.bufPrint(&buf, "#{d} {s}", .{ id, need.repo }) catch "";
        try bench.say(w, x, y, label, repoHue(r, need.repo).hue, bg, true);
        x += cellCount(label) + 2;
    };
    var age_buf: [8]u8 = undefined;
    const age = sheets.ago(&age_buf, need.since, app.epoch);
    const right = x0 + ww -| (cellCount(age) + 1);
    try bench.say(w, right, y, age, r.dim, bg, false);
    var end = right;
    if (text_row) {
        const hint = if (app.orchestratorWindow() == null) "orchestrator off" else "⏎ type";
        const at_x = right -| (cellCount(hint) + 2);
        if (at_x > x + 8) {
            try bench.say(w, at_x, y, hint, if (picked) r.text else r.dim, bg, false);
            end = at_x;
        }
    } else if (need.actions.len > 0 and !opened) {
        var hint_buf: [96]u8 = undefined;
        const hint = if (isDrive(need)) "⏎ planning" else std.fmt.bufPrint(&hint_buf, "{s} {s}", .{ need.actions[0].key, need.actions[0].label }) catch "";
        const at_x = right -| (cellCount(hint) + 2);
        if (at_x > x + 8) {
            try bench.say(w, at_x, y, hint, if (picked) r.text else r.dim, bg, false);
            end = at_x;
        }
    }
    try bench.say(w, x, y, clip(need.text, end -| x -| 1), if (failed) r.failed else r.text, bg, false);
}

/// Whether `need` is the landed goal's item, asking for the next goal to drive.
pub fn isDrive(need: tickets.Need) bool {
    return std.mem.eql(u8, need.kind, "drive");
}

/// Whether `row`'s item is the one open: its ticket's card is shown in the middle column.
pub fn isOpen(app: *const App, row: sheets.Row) bool {
    const view = app.home orelse return false;
    const id = row.ticket orelse return row.kind == .need and app.itemNeed() == row.item;
    return view.detail == id and !view.gate;
}

const tell = "tell the orchestrator: ";

/// Whether `need` is a line the orchestrator suggests saying to it, not one of babylon's items.
pub fn isSuggestion(need: tickets.Need) bool {
    return std.mem.eql(u8, need.kind, "suggest");
}

/// A text suggestion's line typed into the orchestrator's prompt, unsent, and the drawer opened
/// in insert for the human to edit it. With the orchestrator off, nothing is typed.
fn typeIn(app: *App, need: tickets.Need) !void {
    const win = app.orchestratorWindow() orelse return;
    if (win.panes.items.len == 0) return;
    var buf: [1024]u8 = undefined;
    var w: Writer = .fixed(&buf);
    for (need.text) |c| {
        if (c == '\'') try w.writeAll("'\\''") else try w.writeByte(c);
    }
    try app.send(.ignore, "send-keys -t %{d} -l -- '{s}'", .{ win.panes.items[0].id, w.buffered() });
    try app.openDrawer();
}

fn isSendBack(need: tickets.Need) bool {
    return std.mem.eql(u8, need.kind, "sendback") or std.mem.eql(u8, need.kind, "sent_back");
}

/// The item of Your move that `need` (the `at`th of babylon's) is, for the feed's actions.
pub fn itemOf(need: tickets.Need, at: usize, step: ?usize) feed.Item {
    return .{ .line = 0, .ticket = need.ticket, .need = at, .step = step };
}

/// A key on a Your move row: an action babylon gives the item, as on the feed, before the
/// plan's own keys. Whether the key was one.
pub fn answer(app: *App, row: *const sheets.Row, pressed: []const u8) !bool {
    const need = app.board.?.needsYou()[row.item];
    var unsettled: ?usize = null;
    for (need.steps, 0..) |step, i| if (step.result == null) {
        unsettled = i;
        break;
    };
    return win_feed.act(app, itemOf(need, row.item, unsettled), pressed);
}

/// Space, ⏎ or a click on a Your move row: its ticket's card opens in the middle column, with
/// its checks and the item's buttons; a draft opens its own modal.
pub fn open(app: *App, row: *const sheets.Row) !void {
    const need = app.board.?.needsYou()[row.item];
    if (isDrive(need)) return win_goals.openPlanning(app);
    if (isSuggestion(need)) return typeIn(app, need);
    if (std.mem.eql(u8, need.kind, "draft")) {
        _ = try win_feed.act(app, itemOf(need, row.item, null), " ");
        return;
    }
    if (row.ticket) |id| _ = try app.openDetail(id) else try app.openItem(row.item);
}

/// The Your move item of ticket `id` whose buttons its card carries: the first that is not an
/// ask, whose options the card has of its own.
pub fn needOf(app: *const App, id: u32) ?usize {
    const b = if (app.board) |*b| b else return null;
    for (b.needsYou(), 0..) |need, at| {
        if (need.ticket == id and !std.mem.eql(u8, need.kind, "ask")) return at;
    }
    return null;
}

/// Action `i` of the Your move item of the card open, pressed from the card.
pub fn press(app: *App, i: u8) !void {
    const id = app.home.?.detail orelse return;
    const at = needOf(app, id) orelse return;
    const need = app.board.?.needsYou()[at];
    if (i >= need.actions.len) return;
    _ = try win_feed.act(app, itemOf(need, at, null), need.actions[i].key);
}
