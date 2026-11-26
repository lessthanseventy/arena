const std = @import("std");
const theme = @import("theme.zig");
const bench = @import("parts.zig");
const app_mod = @import("app.zig");
const tickets = @import("board.zig");
const sheets = @import("plan.zig");
const feed = @import("feed.zig");
const draw = @import("draw.zig");
const win_feed = @import("win_feed.zig");
const App = app_mod.App;
const Writer = std.Io.Writer;
const clip = draw.clip;
const cellCount = draw.cellCount;
const repoHue = draw.repoHue;

const chip_gap = "   ";

pub fn paint(app: *App, w: *Writer, r: theme.Roles, sheet: *const sheets.Sheet, at: usize, y: u16, x0: usize, ww: usize, lit: bool) !void {
    const row = sheet.rows[at];
    const need = app.board.?.needsYou()[row.item];
    const picked = lit and app.planRowLit(row);
    const mark = if (app.columnFocused()) r.dim else r.accent;
    const bg = if (picked) r.raised else r.panel;
    try bench.fill(w, x0, y, ww, bg);
    switch (row.kind) {
        .need => {
            if (picked) try bench.say(w, x0, y, "▌", mark, bg, true);
            const failed = isSendBack(need);
            try bench.say(w, x0 + 2, y, if (failed) "✗" else "▲", if (failed) r.failed else r.you, bg, true);
            var x = x0 + 4;
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
            const open = if (row.ticket) |id| app.plan_open.get(.move) == id else false;
            if (need.actions.len > 0 and !open) {
                var hint_buf: [96]u8 = undefined;
                const hint = std.fmt.bufPrint(&hint_buf, "{s} {s}", .{ need.actions[0].key, need.actions[0].label }) catch "";
                const at_x = right -| (cellCount(hint) + 2);
                if (at_x > x + 8) {
                    try bench.say(w, at_x, y, hint, if (picked) r.text else r.dim, bg, false);
                    end = at_x;
                }
            }
            try bench.say(w, x, y, clip(need.text, end -| x -| 1), if (failed) r.failed else r.text, bg, false);
        },
        .need_card => {
            const steps = need.steps.len;
            const room = ww -| 4;
            switch (row.part) {
                1 => try bench.say(w, x0 + 2, y, clip(need.machine, room), r.dim, bg, false),
                2 => if (app.refusalOf(need.id)) |why| {
                    try bench.say(w, x0 + 2, y, clip(why, room), r.failed, bg, false);
                } else {
                    var buf: [512]u8 = undefined;
                    var x = x0 + 2;
                    var pieces = std.mem.splitSequence(u8, chips(app, need, &buf), chip_gap);
                    var primary = true;
                    while (pieces.next()) |piece| {
                        if (piece.len == 0) continue;
                        const split = splitChip(piece);
                        if (x + cellCount(split.key) + cellCount(split.label) + 3 > x0 + ww) break;
                        x += try bench.button(w, r, x, y, split.key, split.label, primary and std.mem.eql(u8, split.key, "⏎"), null);
                        if (std.mem.eql(u8, split.key, "⏎")) primary = false;
                    }
                },
                else => if (row.part - 3 < steps) {
                    const step = need.steps[row.part - 3];
                    var buf: [16]u8 = undefined;
                    const n = std.fmt.bufPrint(&buf, "{d} ", .{step.n}) catch "";
                    const indent = x0 + 2 + cellCount(n);
                    var lines: [sheets.Sheet.check_lines_max][]const u8 = undefined;
                    const count = sheets.Sheet.checkText(step, ww, &lines);
                    if (row.count >= count) {
                        var x = indent;
                        for (step.actions) |action| x += try bench.button(w, r, x, y, action.key, action.label, false, null);
                        return;
                    }
                    const settled = step.result != null;
                    if (row.count == 0) try bench.say(w, x0 + 2, y, n, r.dim, bg, false);
                    if (row.count == 0 and settled) try bench.say(w, x0 + ww -| 2, y, "✓", r.dim, bg, false);
                    try bench.say(w, indent, y, lines[row.count], if (settled) r.dim else r.text, bg, false);
                },
            }
        },
        else => {},
    }
}

fn splitChip(piece: []const u8) struct { key: []const u8, label: []const u8 } {
    const space = std.mem.indexOfScalar(u8, piece, ' ') orelse piece.len;
    return .{ .key = piece[0..space], .label = std.mem.trimStart(u8, piece[space..], " ") };
}

fn isSendBack(need: tickets.Need) bool {
    return std.mem.eql(u8, need.kind, "sendback") or std.mem.eql(u8, need.kind, "sent_back");
}

/// The buttons of an open item as `key label` joined by three spaces: opening its doc, what
/// babylon answers with, the options of a question box on its holder's pane and reading a draft.
pub fn chips(app: *const App, need: tickets.Need, buf: []u8) []const u8 {
    var out: Writer = .fixed(buf);
    var first = true;
    const add = struct {
        fn one(o: *Writer, is_first: *bool, comptime fmt: []const u8, args: anytype) void {
            o.writeAll(if (is_first.*) "" else chip_gap) catch return;
            o.print(fmt, args) catch return;
            is_first.* = false;
        }
    }.one;
    if (need.doc != null) add(&out, &first, "o open", .{});
    for (need.actions) |action| add(&out, &first, "{s} {s}", .{ action.key, action.label });
    var asks: [App.box_max]App.Asked = undefined;
    var boxes: [App.box_max]feed.Box = undefined;
    const n = app.questionBoxes(&asks, &boxes);
    if (need.ticket) |id| for (boxes[0..n]) |box| if (box.ticket == id) {
        for (box.options, 1..) |option, number| add(&out, &first, "{d} {s}", .{ number, option });
    };
    if (std.mem.eql(u8, need.kind, "draft")) add(&out, &first, "space read it", .{});
    return out.buffered();
}

/// The key of the button under cell `x` of the buttons row that starts at `x0`.
fn keyAt(text: []const u8, x0: usize, x: usize) ?[]const u8 {
    var at = x0 + 2;
    var pieces = std.mem.splitSequence(u8, text, chip_gap);
    while (pieces.next()) |piece| {
        if (piece.len == 0) continue;
        const split = splitChip(piece);
        const width = cellCount(split.key) + cellCount(split.label) + 3;
        if (x >= at and x < at + width) return split.key;
        at += width + 1;
    }
    return null;
}

/// The key a click on a button stands for.
fn named(label: []const u8) []const u8 {
    if (std.mem.eql(u8, label, "⏎")) return "\r";
    if (std.mem.eql(u8, label, "space")) return " ";
    return label;
}

/// A click on a row of an open item's card: a button of its row of buttons or of a check does
/// what its key does.
pub fn click(app: *App, sheet: *const sheets.Sheet, at: usize, m: anytype) !void {
    const row = sheet.rows[at];
    const need = app.board.?.needsYou()[row.item];
    const rect = app.planRect(.move);
    const view = &app.home.?;
    const owner = for (sheet.rows[0..at]) |prior| {
        if (prior.kind == .need and prior.item == row.item) break prior;
    } else return;
    view.plan_pick = owner.pick orelse return;
    app.dirty = true;
    if (row.part == 2) {
        var buf: [512]u8 = undefined;
        const hit = keyAt(chips(app, need, &buf), rect.x, m.x) orelse return;
        _ = try win_feed.act(app, itemOf(need, row.item, null), named(hit));
        return;
    }
    if (row.part < 3 or row.part - 3 >= need.steps.len) return;
    const step = row.part - 3;
    var lines: [sheets.Sheet.check_lines_max][]const u8 = undefined;
    if (row.count != sheets.Sheet.checkText(need.steps[step], rect.w -| 1, &lines)) return;
    var buf: [16]u8 = undefined;
    var at_x = rect.x + 2 + cellCount(std.fmt.bufPrint(&buf, "{d} ", .{need.steps[step].n}) catch "");
    for (need.steps[step].actions) |action| {
        const used = cellCount(action.key) + cellCount(action.label) + 3;
        if (m.x >= at_x and m.x < at_x + used) {
            _ = try win_feed.act(app, itemOf(need, row.item, step), action.key);
            return;
        }
        at_x += used + 1;
    }
}

/// The item of Your move that `need` (the `at`th of babylon's) is, for the feed's actions.
pub fn itemOf(need: tickets.Need, at: usize, step: ?usize) feed.Item {
    return .{ .line = 0, .ticket = need.ticket, .need = at, .step = step };
}

/// A key on a Your move row: an action babylon gives the item, as on the feed, before the
/// plan's own keys. Whether the key was one.
pub fn answer(app: *App, row: *const sheets.Row, pressed: []const u8) !bool {
    const need = app.board.?.needsYou()[row.item];
    var open: ?usize = null;
    for (need.steps, 0..) |step, i| if (step.result == null) {
        open = i;
        break;
    };
    return win_feed.act(app, itemOf(need, row.item, open), pressed);
}

/// Enter on a Your move item nothing of babylon's answers: goes to the pane that holds its ticket.
pub fn act(app: *App, row: *const sheets.Row) !void {
    const id = row.ticket orelse return;
    for (app.board.?.cards()) |card| if (card.id == id) if (card.holder()) |pane| try app.showPane(pane);
}
