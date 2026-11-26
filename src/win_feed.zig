const std = @import("std");
const keys = @import("keys.zig");
const feed = @import("feed.zig");
const app_mod = @import("app.zig");
const tickets = @import("board.zig");
const draw = @import("draw.zig");
const App = app_mod.App;
const anyKey = app_mod.anyKey;
const cellCount = draw.cellCount;

/// A key on the feed, while the orchestrator's column has the keys in normal mode: `j` `k`
/// move the pick through Your move's items and `]` `[` from need to need, the picked card lit
/// on the board; an action's key runs it as babylon gives it. Whether the key was the feed's.
pub fn press(app: *App, key: []const u8) !bool {
    var f: feed.Feed = undefined;
    if (!app.feedOf(&f)) return false;
    const view = &app.home.?;
    const n = f.itemCount();
    if (n == 0) return false;
    view.pick = @min(view.pick, n - 1);
    const moves = f.items_shown;
    const was = view.pick;
    if (anyKey(key, &.{ "j", "\x1b[B", "\x1bOB" })) {
        view.pick = @min(view.pick + 1, n - 1);
    } else if (anyKey(key, &.{ "k", "\x1b[A", "\x1bOA" })) {
        view.pick -|= 1;
    } else if (anyKey(key, &.{"]"})) {
        if (moves > 0) view.pick = nextTile(&f, view.pick, moves);
    } else if (anyKey(key, &.{"["})) {
        if (moves > 0) view.pick = prevTile(&f, view.pick, moves);
    } else if (anyKey(key, &.{" "})) {
        const id = f.item(view.pick).?.ticket orelse return true;
        if (f.item(view.pick).?.need) |at| if (std.mem.eql(u8, app.board.?.needsYou()[at].kind, "draft")) {
            app.openDraft(id);
            return true;
        };
        app.pickPlan(id);
        _ = try app.openDetail(id);
    } else if (anyKey(key, &.{"Y"}) and try copy(app, f.item(view.pick).?)) {
        return true;
    } else return act(app, f.item(view.pick).?, key);
    app.dirty = true;
    if (view.pick != was) if (f.item(view.pick).?.ticket) |id| {
        app.pickPlan(id);
    };
    return true;
}

/// The first of the `moves` items of Your move that is of the need after `at`'s, or the first.
fn nextTile(f: *const feed.Feed, at: usize, moves: usize) usize {
    if (at >= moves) return 0;
    var to = at + 1;
    while (to < moves and f.item(to).?.need == f.item(at).?.need) to += 1;
    return if (to < moves) to else 0;
}

/// The first item of the need before `at`'s, or of the last when `at` is of the first or is
/// not of Your move.
fn prevTile(f: *const feed.Feed, at: usize, moves: usize) usize {
    var to = moves - 1;
    if (at < moves) {
        var from = at;
        while (from > 0 and f.item(from - 1).?.need == f.item(from).?.need) from -= 1;
        if (from > 0) to = from - 1;
    }
    while (to > 0 and f.item(to - 1).?.need == f.item(to).?.need) to -= 1;
    return to;
}

/// Copies the picked check of a to-try tile, whole. Whether the pick was one.
fn copy(app: *App, item: feed.Item) !bool {
    const b = if (app.board) |*b| b else return false;
    const need = b.needsYou()[item.need orelse return false];
    const step = item.step orelse return false;
    if (step >= need.steps.len) return false;
    try app.copyText(need.steps[step].text);
    return true;
}

pub fn act(app: *App, item: feed.Item, key: []const u8) !bool {
    const b = if (app.board) |*b| b else return false;
    const named: []const u8 = if (std.mem.eql(u8, key, "\r")) "⏎" else key;

    if (app.check_ask) |ask| {
        var same = false;
        if (item.need) |at| if (item.step) |s| {
            const need = b.needsYou()[at];
            same = s < need.steps.len and need.ticket == ask.ticket and need.steps[s].n == ask.n;
        };
        if (same and std.mem.eql(u8, named, "⏎")) {
            try app.checkStart();
            return true;
        }
        app.checkCancel();
        if (anyKey(key, &.{"\x1b"})) return true;
    }
    const at = item.need orelse {
        if (!std.mem.eql(u8, named, "⏎")) return false;
        const id = item.ticket orelse return true;
        for (b.cards()) |card| if (card.id == id) if (card.holder()) |pane| try app.showPane(pane);
        return true;
    };
    const need = b.needsYou()[at];
    if (std.mem.eql(u8, need.kind, "pane")) {
        if (!std.mem.eql(u8, named, "⏎")) return false;
        const win = std.fmt.parseInt(u32, need.id["pane:".len..], 10) catch return true;
        for (app.sessions.items) |s| for (s.wins.items) |w| if (w.id == win) try app.showPane(w.agent_pane);
        return true;
    }
    if (std.mem.eql(u8, need.kind, "drive") and anyKey(key, &.{"+"})) {
        try app.openGoal();
        return true;
    }
    if (std.mem.eql(u8, need.kind, "draft") and anyKey(key, &.{" "})) {
        app.openDraft(need.ticket orelse return true);
        return true;
    }
    if (item.step) |s| if (s < need.steps.len) {
        if (anyKey(key, &.{"o"}) and feed.isLook(need.steps[s])) return app.lookAtDiff(need, need.steps[s]);
        if (need.ticket) |ticket| {
            const step = need.steps[s];
            if (anyKey(key, &.{"r"}) and try app.checkOffer(ticket, step.n, step.text)) return true;
            if (std.mem.eql(u8, named, "⏎")) if (app.checkRunOf(ticket, step.n)) |run| if (run.pane) |pane| {
                try app.showPane(pane);
                return true;
            };
        }
    };
    if (item.step) |s| if (s < need.steps.len) for (need.steps[s].actions) |action| {
        if (!std.mem.eql(u8, action.key, named)) continue;
        if (action.needs) |needs| if (std.mem.eql(u8, needs, "words")) {
            var id: [32]u8 = undefined;
            return app.openWords(std.fmt.bufPrint(&id, "{s}#{d}", .{ need.id, need.steps[s].n }) catch return true);
        };
        if (action.argv) |argv| return app.runNeed(need.id, argv);
        return true;
    };
    const found = for (need.actions) |action| {
        if (std.mem.eql(u8, action.key, named)) break action;
    } else null;
    // an action on a key is babylon's: opening the doc only has the keys it leaves
    if (need.doc != null and found == null and anyKey(key, &.{ "o", "\r" })) return app.openDoc(need);
    const action = found orelse return app.answerBox(need, key);
    if (action.needs) |needs| if (std.mem.eql(u8, needs, "words")) return app.openWords(need.id);
    if (action.argv) |argv| return app.runNeed(need.id, argv);
    const ticket = need.ticket orelse return true;
    const needs = action.needs orelse return true;
    if (std.mem.eql(u8, needs, "surface")) {
        var id_buf: [12]u8 = undefined;
        return app.runNeed(need.id, &.{ "babylon", "start", std.fmt.bufPrint(&id_buf, "{d}", .{ticket}) catch return true });
    }
    if (std.mem.eql(u8, needs, "pick")) {
        app.pickPlan(ticket);
        app.home.?.giving = 0;
        app.dirty = true;
    }
    return true;
}

/// A click on the feed's Your move: its item is the pick, and on a button, what the button's
/// key does. Whether the click was on one of its items.
pub fn click(app: *App, m: keys.Mouse) !bool {
    if (!app.sided() or m.y < 1) return false;
    const left = app.term_w - app.view_w;
    if (m.x < left + 2 or m.x + 2 > app.term_w) return false;
    var f: feed.Feed = undefined;
    if (!app.feedOf(&f)) return false;
    const row = m.y - 1;
    if (row >= f.shown) return false;
    if (App.isTryRow(f.line(row).kind) or f.line(row).kind == .try_head) return tryClick(app, &f, row, m.x - (left + 2));
    var at: ?usize = null;
    for (0..f.items_shown) |i| {
        if (f.item(i).?.line <= row) at = i;
    }
    const i = at orelse return false;
    const view = &app.home.?;
    view.focus = .orchestrator;
    if (app.sideDue()) app.normal = true;
    view.pick = i;
    app.dirty = true;
    const item = f.item(i).?;
    if (item.ticket) |id| {
        app.pickPlan(id);
    }
    const line = f.line(row);
    if (line.kind != .buttons) return true;
    const chip = feed.chipKeyAt(line.text, m.x - (left + 2), app.roles != null) orelse return true;
    const key: []const u8 = if (std.mem.eql(u8, chip, "⏎")) "\r" else if (std.mem.eql(u8, chip, "space")) " " else chip;
    _ = try act(app, item, key);
    return true;
}

/// A click on a to-try tile, `col` cells from the feed's text: a check's row picks that check,
/// a button does what its key does, and the tile's number and title open its modal.
fn tryClick(app: *App, f: *const feed.Feed, row: usize, col: usize) !bool {
    const line = f.line(row);
    if (line.kind == .try_head) return true;
    const view = &app.home.?;
    const need_at = line.need orelse return true;
    // the item it picks: the check's own, else the tile's, the one picked already when it is in it
    var first: ?usize = null;
    var mine: ?usize = null;
    for (0..f.items_shown) |i| {
        const item = f.item(i).?;
        if (item.need != need_at) continue;
        if (first == null) first = i;
        if (line.step != null and item.step == line.step) mine = i;
        if (line.step == null and i == view.pick) mine = i;
    }
    const i = mine orelse (if (first) |k| (if (view.pick >= k and f.item(view.pick) != null and f.item(view.pick).?.need == need_at) view.pick else k) else return true);
    view.focus = .orchestrator;
    if (app.sideDue()) app.normal = true;
    view.pick = i;
    app.dirty = true;
    const item = f.item(i).?;
    if (item.ticket) |id| {
        app.pickPlan(id);
    }
    const inner = app.view_w -| 2;
    switch (line.kind) {
        .try_title => {
            const id = item.ticket orelse return true;
            // the chip takes the cells before the title, the age those after it
            if (col + 1 >= 8 and col + 1 + line.alt.len + 2 < inner) _ = try app.openDetail(id);
        },
        .try_machine => {
            if (line.alt.len > 0 and col + 1 + cellCount(line.alt) + 5 >= inner) return act(app, item, "x");
        },
        .try_buttons => {
            if (line.failed) return true;
            const chip = feed.chipKeyAt(line.text, col, true) orelse return true;
            _ = try act(app, item, chip);
        },
        else => {},
    }
    return true;
}
