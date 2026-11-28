const std = @import("std");
const app_mod = @import("app.zig");
const sheets = @import("plan.zig");
const keys = @import("keys.zig");
const draw = @import("draw.zig");
const color = @import("color.zig");
const theme = @import("theme.zig");
const bench = @import("parts.zig");
const tickets = @import("board.zig");
const grab_mod = @import("grab.zig");
const win_board = @import("win_board.zig");
const win_driving = @import("win_driving.zig");

const win_move = @import("win_move.zig");
const win_next = @import("win_next.zig");
const win_goals = @import("win_goals.zig");
const win_unplanned = @import("win_unplanned.zig");
const win_backlog = @import("win_backlog.zig");
const Writer = std.Io.Writer;
const clip = draw.clip;
const repoHue = draw.repoHue;
const repeat = draw.repeat;
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
    const order = [_]CardAction{ .go, .open, .gate, .give, .handoff, .edit, .priority, .close, .reopen, .to_todo, .to_next, .goal };
    var x = rect.x + 3;
    const right = rect.x + rect.w -| 3;
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
    if (win == .driving and !sheet.hasProjects()) {
        if (rect.h == 0 or x < rect.x or x + 1 >= rect.x + rect.w or y != rect.y) return null;
        const span = sheet.span(win);
        return .{ .win = win, .row = if (span.len > 0) span.start else null };
    }
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
    const from = app.planSlot(here);
    for (std.enums.values(sheets.Window)) |win| {
        const rect = app.planSlot(win);
        const beside = if (right) rect.x >= from.x + from.w else rect.x + rect.w <= from.x;
        if (rect.h == 0 or !beside) continue;
        if (from.y >= rect.y and from.y < rect.y + rect.h) return (sheet.pickRange(win) orelse return null).first;
    }
    return null;
}

/// A click on the buttons row at `at`: the button under it pressed on its ticket, which the
/// pick moves to first, the keys acting on the pick.
pub fn planButtonClick(app: *App, sheet: *const sheets.Sheet, at: usize, m: keys.Mouse) !void {
    var buttons: [12]PlanButton = undefined;
    for (planButtons(app, sheet, at, &buttons)) |button| {
        if (m.y != button.y or m.x < button.x or m.x >= button.x + button.w) continue;
        var from = at - 1;
        while (sheet.rows[from].kind == .detail) from -= 1;
        const owner = sheet.rows[from];
        app.home.?.plan_pick = owner.pick orelse return;
        return app.act(button.action);
    }
}

pub fn windowCount(b: *const tickets.Board, given: *const tickets.Plan, win: sheets.Window) ?usize {
    return switch (win) {
        .driving => if (b.projects().len > 0) b.projects().len else null,
        .board => null,
        .move => b.needsYou().len,
        .next => given.next.len,
        .goals => given.goals.len,
        .no_goal => given.not_planned.count,
        .backlog => blk: {
            var n = given.ideas.len;
            for (b.backlog()) |*card| n += @intFromBool(!card.isEpic());
            break :blk n;
        },
    };
}

/// `win` in its slot (or the modal, when it is the one shown whole): its frame and the rows from the one that keeps the pick in view. `lit` is whether the pick is drawn.
pub fn benchWindow(app: *App, w: *Writer, r: theme.Roles, sheet: *const sheets.Sheet, view: app_mod.HomeView, win: sheets.Window, lit: bool) !void {
    const rect = app.planRect(win);
    const whole = lit and view.whole == win;
    if (win == .driving and !sheet.hasProjects()) {
        const mine = sheet.span(win);
        if (rect.h == 0 or rect.w < 16 or mine.len == 0) return;
        if (lit) {
            app.grab.pane(.{ .x = rect.x, .y = rect.y, .w = rect.w - 1, .h = 1 });
            bench.tap = .{ .grab = &app.grab, .gpa = app.gpa };
        }
        defer bench.tap = null;
        return win_driving.paint(app, w, r, sheet, mine.start, rect.y, rect.x, rect.w - 1, lit);
    }
    if (rect.h <= sheets.window_chrome or rect.w < 16) return;
    const given = app.board.?.plan().?;
    const ww: usize = rect.w - 1;
    const body: usize = rect.h - sheets.window_chrome;
    const mine = sheet.span(win);
    const picked_at = if (lit) sheet.rowOf(view.plan_pick) else null;
    const focused = !app.columnFocused() and (if (picked_at) |at| sheet.rows[at].win == win else false);
    try bench.window(w, r, rect.x, rect.y, ww, rect.h, if (win == .driving) "projects" else win.title(), windowCount(&app.board.?, given, win), focused);
    const bar = r.panel;
    if (win == .board) try win_board.tally(app, w, r, sheet, rect.x, rect.y, ww);
    if (whole) {
        try bench.say(w, rect.x + ww - 10, rect.y, " q close ", r.dim, bar, false);
    }
    if (win == .no_goal and !whole) try win_unplanned.frame(app, w, r);
    if (win == .goals and !whole) try win_goals.frame(app, w, r);
    if (lit) {
        const text_area: grab_mod.Area = .{ .x = rect.x + 1, .y = rect.y + 1, .w = @intCast(ww - 2), .h = @intCast(body) };
        if (whole) app.grab.window(text_area) else app.grab.pane(text_area);
        bench.tap = .{ .grab = &app.grab, .gpa = app.gpa };
    }
    defer bench.tap = null;
    for (0..body) |line| {
        const at = if (lit) planRowOnLine(app, sheet, win, body, line) else line;
        if (at >= mine.len) break;
        try benchPlanRow(app, w, r, sheet, mine.start + at, rect.y + 1 + @as(u16, @intCast(line)), rect.x + 1, ww - 2, lit);
    }
}

/// The row at `at` of the plan, drawn on row `y`, in the `ww` cells from `x0` between a
/// window's side borders.
pub fn benchPlanRow(app: *App, w: *Writer, r: theme.Roles, sheet: *const sheets.Sheet, at: usize, y: u16, x0: usize, ww: usize, lit: bool) !void {
    const row = sheet.rows[at];
    const picked = lit and app.planRowLit(row);
    const mark = if (app.columnFocused()) r.dim else r.accent;
    const bg = if (picked) r.raised else r.panel;
    const room = ww - 4;
    switch (row.kind) {
        .blank => {},
        .buttons => {
            try bench.fill(w, x0, y, ww, r.raised);
            var buttons: [12]PlanButton = undefined;
            for (planButtons(app, sheet, at, &buttons), 0..) |button, i| {
                _ = try bench.button(w, r, button.x, button.y, button.key, button.word, i == 0, null);
            }
        },
        .detail => {
            const under = if (lit) r.raised else r.panel;
            try bench.fill(w, x0, y, ww, under);
            if (lit) try bench.say(w, x0, y, "▌", mark, under, true);
            const label = row.text[0..@min(row.tail_at, row.text.len)];
            const at_x = x0 + row.part;
            if (label.len > 0) try bench.say(w, at_x, y, label, r.dim, under, false);
            try draw.sayCut(w, at_x + cellCount(label), y, row.text[label.len..], ww -| row.part -| cellCount(label) -| 1, r.text, under, false);
        },
        .head => {
            try bench.fill(w, x0, y, ww, r.panel);
            var buf: [48]u8 = undefined;
            const label = std.fmt.bufPrint(&buf, "── {s} {d} ", .{ row.text, row.count }) catch "";
            try bench.say(w, x0 + 1, y, label, r.dim, r.panel, false);
            try repeat(w, x0 + 1 + cellCount(label), y, "─", ww -| 2 -| cellCount(label), r.dim, r.panel);
        },
        .note => {
            try bench.fill(w, x0, y, ww, bg);
            if (picked) try bench.say(w, x0, y, "▌", mark, bg, true);
            try draw.sayCut(w, x0 + 2, y, row.text, room, r.dim, bg, false);
        },
        .need => try win_move.paint(app, w, r, sheet, at, y, x0, ww, lit),
        .focal, .drove => {},
        .project => try win_driving.paintProject(app, w, r, sheet, at, y, x0, ww, lit),
        .now, .now_line, .landed, .stack => try win_board.paint(app, w, r, sheet, at, y, x0, ww, lit),
        .next => if (row.win == .board) try win_board.paint(app, w, r, sheet, at, y, x0, ww, lit) else try win_next.paint(app, w, r, sheet, at, y, x0, ww, lit),
        .goal, .goal_ticket => try win_goals.paint(app, w, r, sheet, at, y, x0, ww, lit),
        .idea, .backlog => try win_backlog.paint(app, w, r, sheet, at, y, x0, ww, lit),
        .ideas_more => {
            try bench.fill(w, x0, y, ww, bg);
            if (picked) try bench.say(w, x0, y, "▌", mark, bg, true);
            try draw.sayCut(w, x0 + 2, y, std.mem.trim(u8, row.text, " "), room, r.dim, bg, false);
        },
        .why, .more, .goals_more => {
            try bench.fill(w, x0, y, ww, r.panel);
            try draw.sayCut(w, x0 + 7, y, std.mem.trim(u8, row.text, " "), room -| 5, r.dim, r.panel, false);
        },
        .unplanned, .chips, .todo => try win_unplanned.paint(app, w, r, sheet, at, y, x0, ww, lit),
    }
}
