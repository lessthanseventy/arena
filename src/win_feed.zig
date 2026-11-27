const std = @import("std");
const keys = @import("keys.zig");
const feed = @import("feed.zig");
const app_mod = @import("app.zig");
const tickets = @import("board.zig");
const draw = @import("draw.zig");
const win_goals = @import("win_goals.zig");
const win_board = @import("win_board.zig");
const App = app_mod.App;
const anyKey = app_mod.anyKey;
const cellCount = draw.cellCount;
const clip = draw.clip;
const repoHue = draw.repoHue;
const vt = @import("ghostty-vt");
const color = @import("color.zig");
const theme = @import("theme.zig");
const Writer = std.Io.Writer;

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
        for (b.cards()) |card| if (card.id == id) if (card.holder()) |pane| try app.openClaude(pane);
        return true;
    };
    const need = b.needsYou()[at];
    if (std.mem.eql(u8, need.kind, "pane")) {
        if (!std.mem.eql(u8, named, "⏎")) return false;
        const win = std.fmt.parseInt(u32, need.id["pane:".len..], 10) catch return true;
        for (app.sessions.items) |s| for (s.wins.items) |w| if (w.id == win) try app.openClaude(w.agent_pane);
        return true;
    }
    if (std.mem.eql(u8, need.kind, "stuck")) {
        if (!std.mem.eql(u8, named, "⏎")) return false;
        const given = b.plan() orelse return true;
        for (given.now, 0..) |row, i| if (row.ticket == need.ticket) {
            try win_board.act(app, &.{ .kind = .now, .ticket = row.ticket, .item = i });
            break;
        };
        return true;
    }
    if (std.mem.eql(u8, need.kind, "draft") and anyKey(key, &.{" "})) {
        app.openDraft(need.ticket orelse return true);
        return true;
    }
    if (item.step) |s| if (s < need.steps.len) {
        if (anyKey(key, &.{"o"})) {
            const step = need.steps[s];
            if (step.doc) |doc| {
                var of_step = need;
                of_step.doc = doc;
                return app.openDoc(of_step);
            }
            if (feed.isLook(step)) return app.lookAtDiff(need, step);
        }
        if (anyKey(key, &.{"d"}) and feed.isLook(need.steps[s])) return app.lookAtDiff(need, need.steps[s]);
        if (need.ticket) |ticket| {
            const step = need.steps[s];
            if (anyKey(key, &.{"r"}) and try app.checkOffer(ticket, step.n, step.text)) return true;
            if (std.mem.eql(u8, named, "⏎")) if (app.checkRunOf(ticket, step.n)) |run| if (run.pane) |pane| {
                try app.openClaude(pane);
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
    if (std.mem.eql(u8, need.kind, "drive") and found == null and std.mem.eql(u8, named, "⏎")) {
        win_goals.openPlanning(app);
        return true;
    }
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
        .try_buttons => {
            if (line.failed) return true;
            const chip = feed.chipKeyAt(line.text, col, true) orelse return true;
            _ = try act(app, item, chip);
        },
        else => {},
    }
    return true;
}

/// Cells written one after another on a feed row, `room` of them left.
const RowOut = struct {
    w: *Writer,
    pen: *draw.Pen,
    room: usize,
    bg: color.RGB,

    fn say(o: *RowOut, fg: color.RGB, bold: bool, text: []const u8) !void {
        var buf: [256]u8 = undefined;
        const t = draw.clipMark(&buf, text, o.room);
        if (t.len == 0) return;
        try o.pen.set(o.w, draw.paintStyle(fg, o.bg, bold), null);
        try o.w.writeAll(t);
        o.room -= cellCount(t);
    }

    /// `▎label `: a lead bar and the words on raised, or, `filled`, `lead` the face and ink the words.
    fn chip(o: *RowOut, r: theme.Roles, lead: color.RGB, label: []const u8, filled: bool) !void {
        if (o.room < cellCount(label) + 2) return;
        try o.pen.set(o.w, draw.paintStyle(lead, if (filled) lead else r.raised, false), null);
        try o.w.writeAll("▎");
        try o.pen.set(o.w, draw.paintStyle(if (filled) r.on_accent else r.text, if (filled) lead else r.raised, filled), null);
        try o.w.writeAll(label);
        try o.w.writeAll(" ");
        o.room -= cellCount(label) + 2;
    }

    /// ` key label ` raised with its shadow's `▌` after it, or filled amber when `primary`.
    fn button(o: *RowOut, r: theme.Roles, key: []const u8, label: []const u8, primary: bool) !void {
        if (o.room < cellCount(key) + cellCount(label) + 5) return;
        const face = if (primary) r.accent else r.raised;
        try o.pen.set(o.w, draw.paintStyle(if (primary) r.on_accent else r.accent, face, primary), null);
        try o.w.writeAll(" ");
        try o.w.writeAll(key);
        try o.pen.set(o.w, draw.paintStyle(if (primary) r.on_accent else r.text, face, primary), null);
        try o.w.writeAll(" ");
        try o.w.writeAll(label);
        try o.w.writeAll(" ");
        try o.pen.set(o.w, draw.paintStyle(r.well, o.bg, false), null);
        try o.w.writeAll("▌ ");
        o.room -= cellCount(key) + cellCount(label) + 5;
    }

    fn finish(o: *RowOut) !void {
        try o.say(o.bg, false, spaceRun(o.room));
    }
};

const space_run: [512]u8 = @splat(' ');

fn spaceRun(n: usize) []const u8 {
    return space_run[0..@min(n, space_run.len)];
}

/// Workbench's row of the feed for the lines that are tiles or buttons: a Your move item a tile
/// led by its kind's chip, its buttons raised, the pick lit raised.
fn benchFeedRow(app: *const App, w: *Writer, pen: *draw.Pen, r: theme.Roles, f: *const feed.Feed, row: usize, inner: u16) !void {
    const line = f.line(row);
    const on = app.feedLitItem(f);
    const strong = app.feedLit() == .focused;
    var head = row;
    if (line.kind == .buttons or line.kind == .refused) {
        while (head > 0 and f.line(head).kind != .item) head -= 1;
    }
    const tiled = line.kind == .item or line.kind == .buttons or line.kind == .refused;
    const lit = if (on) |o| tiled and o.line == head else false;
    var o: RowOut = .{ .w = w, .pen = pen, .room = inner, .bg = if (!tiled) r.panel else if (lit) r.raised else r.tile };
    try o.say(r.text, false, " ");
    switch (line.kind) {
        .item => {
            try o.say(if (strong) r.accent else r.dim, true, if (lit) "▌ " else "  ");
            const need = if (line.need) |at| app.board.?.needsYou()[at] else null;
            const kind = if (need) |n| n.kind else "";
            const eql = std.mem.eql;
            if (eql(u8, kind, "ask")) try o.chip(r, r.you, "asks", true) else if (eql(u8, kind, "sent_back") or eql(u8, kind, "sendback")) try o.chip(r, r.failed, "sent back", true) else if (eql(u8, kind, "proposal")) try o.chip(r, r.accent, "proposal", true) else if (kind.len > 0) try o.chip(r, r.dim, kind, false);
            if (need) |n| if (n.ticket) |id| if (std.mem.indexOfScalar(u8, line.text, '#') == null) {
                var buf: [64]u8 = undefined;
                try o.say(repoHue(r, n.repo).hue, true, std.fmt.bufPrint(&buf, "#{d} {s} ", .{ id, n.repo }) catch "");
            };
            try o.say(r.text, false, line.text);
        },
        .buttons => {
            try o.say(if (strong) r.accent else r.dim, true, if (lit) "▌ " else "  ");
            var primary = true;
            var pieces = std.mem.splitSequence(u8, line.text, "   ");
            while (pieces.next()) |piece| {
                const space = std.mem.indexOfScalar(u8, piece, ' ') orelse piece.len;
                const key = piece[0..space];
                const mine = primary and std.mem.eql(u8, key, "⏎");
                if (mine) primary = false;
                try o.button(r, key, std.mem.trimStart(u8, piece[space..], " "), mine);
            }
        },
        .refused => {
            try o.say(if (strong) r.accent else r.dim, true, if (lit) "▌ " else "  ");
            try o.say(r.failed, false, line.text);
        },
        .move_head => {
            const cut = std.mem.lastIndexOfScalar(u8, line.text, ' ') orelse 0;
            try o.say(r.you, true, line.text[0..cut]);
            try o.say(r.text, false, " ");
            try o.chip(r, r.dim, line.text[@min(cut + 1, line.text.len)..], false);
        },
        else => {},
    }
    try o.finish();
}

/// Workbench's rows of a to-try tile: the rule over the section, the title with its chip and age,
/// the machine's line, a row for each wrapped line of a check, and the buttons under the picked
/// one. The picked check lit raised.
fn benchTryRow(app: *const App, w: *Writer, pen: *draw.Pen, r: theme.Roles, f: *const feed.Feed, row: usize, inner: u16) !void {
    const line = f.line(row);
    const on = app.feedLitItem(f);
    const strong = app.feedLit() == .focused;
    const lit = if (on) |o| line.need != null and o.need == line.need and line.step != null and o.step == line.step else false;
    var o: RowOut = .{ .w = w, .pen = pen, .room = inner, .bg = if (line.kind == .try_head) r.panel else if (lit) r.raised else r.tile };
    try o.say(r.text, false, " ");
    switch (line.kind) {
        .try_head => {
            try o.say(r.dim, false, line.text);
            while (o.room > 0) try o.say(r.dim, false, "─");
        },
        .try_title => {
            try o.say(r.text, false, "  ");
            try o.chip(r, r.you, "try", true);
            const age = line.alt;
            const room = o.room -| (cellCount(age) + 2);
            var title_buf: [256]u8 = undefined;
            const text = draw.clipMark(&title_buf, line.text, room);
            try o.say(r.text, false, text);
            try o.say(r.text, false, spaceRun(o.room -| (cellCount(age) + 1)));
            try o.say(if (line.old) r.you else r.dim, line.old, age);
        },
        .try_machine => {
            try o.say(r.text, false, "  ");
            try o.say(r.dim, false, line.text);
        },
        .try_step => {
            try o.say(if (strong) r.accent else r.dim, true, if (lit) "▌ " else "  ");
            const room = o.room -| (if (line.settled) @as(usize, 2) else 0);
            var step_buf: [256]u8 = undefined;
            const text = draw.clipMark(&step_buf, line.text, room);
            try o.say(if (line.settled) r.dim else r.text, false, text);
            if (line.settled) {
                try o.say(r.text, false, spaceRun(o.room -| 1));
                try o.say(r.dim, false, "✓");
            }
        },
        .try_buttons => {
            if (line.failed) {
                try o.say(r.failed, false, "    ");
                try o.say(r.failed, false, line.text);
            } else {
                try o.say(r.text, false, "  ");
                var primary = true;
                var pieces = std.mem.splitSequence(u8, line.text, "   ");
                while (pieces.next()) |piece| {
                    const space = std.mem.indexOfScalar(u8, piece, ' ') orelse piece.len;
                    try o.button(r, piece[0..space], std.mem.trimStart(u8, piece[space..], " "), primary and strong);
                    primary = false;
                }
            }
        },
        else => {},
    }
    try o.finish();
}

/// Row `row` of the feed atop the orchestrator's column, `inner` cells wide: its line, or past
/// them, the rule under it.
pub fn feedRow(app: *const App, w: *Writer, pen: *draw.Pen, f: *const feed.Feed, row: usize, inner: u16) !void {
    const dim = draw.ink(app, "dim", 8);
    if (row < f.count()) if (app.roles) |r| switch (f.line(row).kind) {
        .item, .buttons, .refused, .move_head => return benchFeedRow(app, w, pen, r, f, row, inner),
        .try_head, .try_title, .try_machine, .try_step, .try_buttons => return benchTryRow(app, w, pen, r, f, row, inner),
        else => {},
    };
    if (row >= f.count()) {
        try pen.set(w, draw.onPanel(app, dim), null);
        for (0..inner) |_| try w.writeAll("─");
        return;
    }
    const line = f.line(row);
    try pen.set(w, draw.onPanel(app, .{}), null);
    try w.writeAll(" ");
    var room: usize = inner -| 1;
    const bar = if (line.failed) draw.ink(app, "emberdim", 1) else draw.ink(app, "amber", 4);
    const lead: []const u8 = switch (line.kind) {
        .item => "▌ ",
        .buttons, .refused => "▌     ",
        .try_step => "  ",
        .try_buttons => "      ",
        else => "",
    };
    if (lead.len > 0 and room > cellCount(lead)) {
        try pen.set(w, draw.onPanel(app, bar), null);
        try w.writeAll(lead);
        room -= cellCount(lead);
    }
    var bold = draw.heading(app);
    bold.flags.bold = true;
    const style: vt.Style = switch (line.kind) {
        .move_head => bold,
        .quiet, .more, .buttons, .try_head, .try_machine => dim,
        .refused => draw.ink(app, "emberdim", 1),
        .try_buttons => if (line.failed) draw.ink(app, "emberdim", 1) else dim,
        .item, .try_title, .try_step => .{},
    };
    if (room == 0) return;
    var lit = false;
    var shown = line.text;
    var marked: [256]u8 = undefined;
    // without Workbench's raised cells, a settled check ends on its mark
    if (line.kind == .try_step and line.settled) shown = std.fmt.bufPrint(&marked, "{s}  ✓", .{line.text}) catch shown;
    if (app.feedLitItem(f)) |on| lit = on.line == row;
    var cut_buf: [256]u8 = undefined;
    const text = draw.clipMark(&cut_buf, shown, room);
    const used = cellCount(text);
    try pen.set(w, draw.onPanel(app, if (lit) (if (app.feedLit() == .focused) draw.chip(app) else draw.dimLit(app)) else style), null);
    try w.writeAll(text);
    try pen.set(w, draw.onPanel(app, style), null);
    for (used..room) |_| try w.writeAll(" ");
}
