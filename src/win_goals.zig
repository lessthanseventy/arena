const std = @import("std");
const theme = @import("theme.zig");
const bench = @import("parts.zig");
const app_mod = @import("app.zig");
const tickets = @import("board.zig");
const sheets = @import("plan.zig");
const draw = @import("draw.zig");
const App = app_mod.App;
const Writer = std.Io.Writer;
const sayCut = draw.sayCut;
const cellCount = draw.cellCount;
const goalHue = draw.goalHue;
const repoHue = draw.repoHue;

/// The cells a goal's bar and its count take against the right edge.
fn barCells(ww: usize) usize {
    return if (ww >= 70) 28 else 22;
}

pub fn paint(app: *App, w: *Writer, r: theme.Roles, sheet: *const sheets.Sheet, at: usize, y: u16, x0: usize, ww: usize, lit: bool) !void {
    const b = &app.board.?;
    const given = b.plan().?;
    const row = sheet.rows[at];
    const picked = lit and app.planRowLit(row);
    const mark = if (app.columnFocused()) r.dim else r.accent;
    const bg = if (picked) r.raised else r.panel;
    try bench.fill(w, x0, y, ww, bg);
    if (picked) try bench.say(w, x0, y, "▌", mark, bg, true);
    switch (row.kind) {
        .goal => {
            const goal = given.goals[row.item];
            const hue = goalHue(b, r, goal);
            const driving = given.driving == goal.epic;
            try bench.say(w, x0 + 2, y, if (row.part == 1) "▸" else "▾", r.dim, bg, false);
            var x = x0 + 4;
            if (driving) {
                try bench.say(w, x, y, "◆", hue, bg, true);
                x += 2;
            }
            var idb: [16]u8 = undefined;
            const id = std.fmt.bufPrint(&idb, "#{d}", .{goal.epic}) catch "";
            try bench.say(w, x, y, id, hue, bg, true);
            x += cellCount(id) + 1;
            const bar = barCells(ww);
            const word = "◆ driving";
            const word_w = if (driving) cellCount(word) + 2 else 0;
            const title_room = ww -| (x - x0) -| bar -| word_w -| 1;
            try sayCut(w, x, y, goal.name(), title_room, if (row.dim) r.dim else r.accent, bg, true);
            if (driving) try bench.say(w, x0 + ww - bar - word_w, y, word, hue, bg, false);
            try draw.goalBar(w, r, x0 + ww - bar, y, bar - 2, goal, hue, bg, r.dim, "", r.you);
        },
        .goal_ticket => {
            const card = app.cardById(row.ticket orelse return) orelse return;
            const step = given.goals[row.item].steps[row.count];
            const repo = repoHue(r, card.repo);
            var idb: [16]u8 = undefined;
            const id = std.fmt.bufPrint(&idb, "#{d}", .{card.id}) catch "";
            try bench.say(w, x0 + 4, y, "▌", repo.hue, bg, false);
            try bench.say(w, x0 + 5, y, repo.glyph, repo.hue, bg, false);
            try bench.say(w, x0 + 8, y, id, repo.hue, bg, true);
            var lbuf: [64]u8 = undefined;
            const state = stateWords(&lbuf, step);
            const label_x = x0 + ww -| (cellCount(state.text) + 1);
            try bench.say(w, label_x, y, state.text, if (state.attention) r.you else r.dim, bg, false);
            const title_x = x0 + 9 + cellCount(id);
            try sayCut(w, title_x, y, card.name(), label_x -| title_x -| 1, if (row.dim) r.dim else r.text, bg, false);
        },
        else => {},
    }
}

/// What a goal's ticket says of itself on the right: where it is in the pipeline, `← #N` while it
/// waits on one.
fn stateWords(buf: []u8, step: tickets.Step) struct { text: []const u8, attention: bool } {
    for (step.waits_on) |wait| if (wait.ticket) |on| {
        return .{ .text = std.fmt.bufPrint(buf, "○ ← #{d}", .{on}) catch "", .attention = false };
    };
    const word = switch (std.meta.stringToEnum(enum { building, landing, reviewing, verifying, to_try, failed, sent_back, other }, step.state) orelse .other) {
        .building => "building",
        .landing => "landing",
        .reviewing => "reviewing",
        .verifying => "verifying",
        .to_try => "to try",
        .failed, .sent_back => "sent back",
        .other => "",
    };
    if (word.len == 0) return .{ .text = "○ todo", .attention = false };
    const attention = std.mem.eql(u8, step.state, "to_try") or std.mem.eql(u8, step.state, "failed") or std.mem.eql(u8, step.state, "sent_back");
    return .{ .text = std.fmt.bufPrint(buf, "{s} {s}", .{ sheets.Sheet.stepMark(step.state), word }) catch "", .attention = attention };
}

/// Enter on a goal or one of its tickets: its card, in the middle column.
pub fn act(app: *App, row: *const sheets.Row) !void {
    _ = try app.openDetail(row.ticket orelse return);
}

/// Planning shown with the pick on goals' first row, where `d` drives one and `+` makes one.
pub fn openPlanning(app: *App) void {
    app.showScreen(.planning);
    var sheet: sheets.Sheet = undefined;
    if (!app.planSheet(&sheet)) return;
    const range = sheet.pickRange(.goals) orelse return;
    app.home.?.plan_pick = range.first;
    app.dirty = true;
}

/// The epic of the goal a row of the goals window is, or is a ticket of.
pub fn epicOf(app: *const App, row: *const sheets.Row) ?u32 {
    return switch (row.kind) {
        .goal => row.ticket,
        .goal_ticket => (app.board.?.plan() orelse return null).goals[row.item].epic,
        else => null,
    };
}

/// A click on the title bar: on `+ goal`, a new goal.
pub fn titleClick(app: *App, x: u16) !bool {
    const head = app.goalHead();
    if (x < head.x or x >= head.x + head.w) return false;
    try app.openGoal();
    return true;
}

/// The goals window's title-bar extra: its `+ goal` button.
pub fn frame(app: *App, w: *Writer, r: theme.Roles) !void {
    const head = app.goalHead();
    try bench.headButton(w, r, head.x, head.y, " + goal ", r.accent, false);
}

/// `z` on a goal or one of its tickets: that goal's tickets folded away, or listed again.
pub fn fold(app: *App, epic: u32) void {
    if (std.mem.indexOfScalar(u32, app.goals_shut[0..app.goals_shut_n], epic)) |at| {
        app.goals_shut[at] = app.goals_shut[app.goals_shut_n - 1];
        app.goals_shut_n -= 1;
    } else if (app.goals_shut_n < app.goals_shut.len) {
        app.goals_shut[app.goals_shut_n] = epic;
        app.goals_shut_n += 1;
    }
    app.dirty = true;
}
