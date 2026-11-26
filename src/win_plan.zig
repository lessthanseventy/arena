const std = @import("std");
const app_mod = @import("app.zig");
const sheets = @import("plan.zig");
const keys = @import("keys.zig");
const draw = @import("draw.zig");
const App = app_mod.App;
const CardAction = App.CardAction;
const cellCount = draw.cellCount;

/// A button of an open ticket's row on the plan, where it is drawn and clicked.
pub const PlanButton = struct { action: CardAction, key: []const u8, word: []const u8, x: u16, y: u16, w: u16 };

pub const PlanHit = struct { win: sheets.Window, row: ?usize = null, title: bool = false };

/// The buttons of the `.buttons` row at `at` of `sheet`: the card's actions that are no
/// modal's (answer and no stay there) and no list's (up and down are J and K), `open` last.
pub fn planButtons(app: *const App, sheet: *const sheets.Sheet, at: usize, out: []PlanButton) []PlanButton {
    const row = sheet.rows[at];
    const card = app.cardById(row.ticket orelse return out[0..0]) orelse return out[0..0];
    const rect = app.planRect(row.win);
    const body = rect.h -| sheets.window_chrome;
    const top = app.planWindowTop(sheet, row.win, body);
    const line = at - sheet.span(row.win).start;
    const pin = App.planPinned(row.win);
    if (line < top or line >= top + body -| pin) return out[0..0];
    const y = rect.y + 1 + @as(u16, @intCast(pin + line - top));
    var have: [12]CardAction = undefined;
    const actions = App.cardActions(card, &have);
    const order = [_]CardAction{ .go, .open, .give, .handoff, .edit, .priority, .close, .reopen, .to_todo, .to_next };
    var x = rect.x + 2;
    const right = rect.x + rect.w -| 2;
    var n: usize = 0;
    for (order) |action| {
        if (action != .open and std.mem.indexOfScalar(CardAction, actions, action) == null) continue;
        const key = action.key();
        const word = App.cardWord(card, action);
        const w: u16 = @intCast(cellCount(key) + cellCount(word) + 3);
        if (x + w > right or n == out.len) break;
        out[n] = .{ .action = action, .key = key, .word = word, .x = x, .y = y, .w = w };
        n += 1;
        x += w + 1;
    }
    return out[0..n];
}

/// The row of `win` (from 0) drawn on body line `line`.
pub fn planRowOnLine(app: *const App, sheet: *const sheets.Sheet, win: sheets.Window, body: usize, line: usize) usize {
    const pin = App.planPinned(win);
    return if (line < pin) line else app.planWindowTop(sheet, win, body) + line - pin;
}

/// What is under (`x`, `y`) of the plan: a window's title bar or a row.
pub fn planHit(app: *const App, sheet: *const sheets.Sheet, x: u16, y: u16) ?PlanHit {
    const view = app.home orelse return null;
    if (view.whole) |win| return hitIn(app, sheet, win, app.planWhole(), x, y);
    for (std.enums.values(sheets.Window)) |win| if (hitIn(app, sheet, win, app.planSlot(win), x, y)) |hit| return hit;
    return null;
}

pub fn hitIn(app: *const App, sheet: *const sheets.Sheet, win: sheets.Window, rect: sheets.Rect, x: u16, y: u16) ?PlanHit {
    if (rect.h <= sheets.window_chrome or x < rect.x or x + 1 >= rect.x + rect.w or y < rect.y or y + 1 >= rect.y + rect.h) return null;
    if (y == rect.y) return .{ .win = win, .title = true };
    const body = rect.h - sheets.window_chrome;
    const span = sheet.span(win);
    const line = planRowOnLine(app, sheet, win, body, y - rect.y - 1);
    return .{ .win = win, .row = if (line < span.len) span.start + line else null };
}

/// The first pick of the window beside the picked row's, to the right or the left, in the
/// other column at the same height; null where there is none or it holds nothing to pick.
pub fn planBeside(app: *const App, sheet: *const sheets.Sheet, right: bool) ?usize {
    const view = app.home.?;
    const here = (sheet.picked(view.plan_pick) orelse return null).win;
    const left_col = here == .now or here == .next;
    if (here == .driving or left_col != right) return null;
    const at = app.planSlot(here).y;
    const side: []const sheets.Window = if (right) &.{ .goals, .unplanned, .landed } else &.{ .now, .next };
    for (side) |win| {
        const rect = app.planSlot(win);
        if (at >= rect.y and at < rect.y + rect.h) return (sheet.pickRange(win) orelse return null).first;
    }
    return null;
}

/// A click on the buttons row at `at`: the button under it pressed on its ticket, which the
/// pick moves to first, the keys acting on the pick.
pub fn planButtonClick(app: *App, sheet: *const sheets.Sheet, at: usize, m: keys.Mouse) !void {
    var buttons: [12]PlanButton = undefined;
    for (planButtons(app, sheet, at, &buttons)) |button| {
        if (m.y != button.y or m.x < button.x or m.x >= button.x + button.w) continue;
        const owner = sheet.rows[at - 1 - @as(usize, @intFromBool(sheet.rows[at - 1].kind == .why or sheet.rows[at - 1].kind == .held))];
        app.home.?.plan_pick = owner.pick orelse return;
        return app.act(button.action);
    }
}
