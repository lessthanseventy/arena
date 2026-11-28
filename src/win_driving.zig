const std = @import("std");
const theme = @import("theme.zig");
const bench = @import("parts.zig");
const app_mod = @import("app.zig");
const sheets = @import("plan.zig");
const tickets = @import("board.zig");
const draw = @import("draw.zig");
const App = app_mod.App;
const Writer = std.Io.Writer;
const cellCount = draw.cellCount;
const goalHue = draw.goalHue;
const goalChips = draw.goalChips;

/// Cells of driving towards' bar, before its `N/M  P%`.
const bar_cells = 14;

/// Heading for, one row `ww` cells wide from `x0` and no body: `◆ heading for  #N title`, the
/// goal's repos, its bar and `N/M  P%` at the right edge. Its pick is the row itself.
pub fn paint(app: *App, w: *Writer, r: theme.Roles, sheet: *const sheets.Sheet, at: usize, y: u16, x0: usize, ww: usize, lit: bool) !void {
    const b = &app.board.?;
    const given = b.plan().?;
    const row = sheet.rows[at];
    const picked = lit and app.planRowLit(row);
    const face = if (picked) r.raised else r.tile;
    try bench.fill(w, x0, y, ww, face);
    if (picked) try bench.say(w, x0, y, "▌", if (app.columnFocused()) r.dim else r.accent, face, true);
    try bench.say(w, x0 + 1, y, "◆", if (picked) r.accent else r.dim, face, false);
    switch (row.kind) {
        .focal => {
            const goal = given.goals[row.item];
            var head: [32]u8 = undefined;
            const towards = std.fmt.bufPrint(&head, "heading for  #{d} ", .{goal.epic}) catch "";
            var label: [32]u8 = undefined;
            const count = std.fmt.bufPrint(&label, "{d}/{d}  {d}%", .{ goal.landed, goal.total, if (goal.total == 0) 0 else goal.landed * 100 / goal.total }) catch "";
            const room = bar_cells + 1 + cellCount(count);
            const bar_x = x0 + ww -| (room + 3);
            const shares = try goalChips(w, r, b, goal, bar_x -| 1, y);
            try draw.goalBar(w, r, bar_x, y, room, goal, goalHue(b, r, goal), face, r.text, "", r.dim);
            try bench.say(w, x0 + 3, y, towards, r.dim, face, false);
            const title_x = x0 + 3 + cellCount(towards);
            try draw.sayCut(w, title_x, y, goal.name(), (bar_x -| shares -| 1) -| title_x, r.accent, face, true);
        },
        .drove => try draw.sayCut(w, x0 + 3, y, row.text, ww -| 4, r.text, face, true),
        else => {
            const lead = "heading for  ";
            try bench.say(w, x0 + 3, y, lead, r.dim, face, false);
            try draw.sayCut(w, x0 + 3 + cellCount(lead), y, row.text, ww -| (4 + cellCount(lead)), r.dim, face, false);
        },
    }
}

/// What is moving in `project`: `3 building · 1 landing`, `1 stuck`, `2 paused`, or `idle`.
fn movingWords(buf: []u8, b: *const tickets.Board, given: *const tickets.Plan, project: usize) []const u8 {
    var building: usize = 0;
    var landing: usize = 0;
    var stuck: usize = 0;
    var paused: usize = 0;
    var waits: usize = 0;
    for (given.now) |item| {
        if (!b.inProject(project, item.repo orelse "")) continue;
        if (item.paused) {
            paused += 1;
        } else if (item.waiting_on != null) {
            waits += 1;
        } else if (item.stalled != null) {
            stuck += 1;
        } else if (std.mem.eql(u8, item.state, "building")) {
            building += 1;
        } else landing += 1;
    }
    var out: Writer = .fixed(buf);
    for ([_]struct { n: usize, word: []const u8 }{ .{ .n = building, .word = "building" }, .{ .n = landing, .word = "landing" }, .{ .n = stuck, .word = "stuck" }, .{ .n = waits, .word = "waiting" }, .{ .n = paused, .word = "paused" } }) |part| {
        if (part.n == 0) continue;
        out.print("{s}{d} {s}", .{ if (out.end > 0) " · " else "", part.n, part.word }) catch {};
    }
    return if (out.end == 0) "idle" else out.buffered();
}

const project_name_w = App.scope_label_w + 2;
const moving_w = 24;
const auto_w = 10;

/// A project's row on all: its name, the goal it drives with its bar and count, its auto word and
/// what is moving in it.
pub fn paintProject(app: *App, w: *Writer, r: theme.Roles, sheet: *const sheets.Sheet, at: usize, y: u16, x0: usize, ww: usize, lit: bool) !void {
    const b = &app.board.?;
    const given = b.plan().?;
    const row = sheet.rows[at];
    const project = b.projects()[row.item];
    const picked = lit and app.planRowLit(row);
    const bg = if (picked) r.raised else r.panel;
    try bench.fill(w, x0, y, ww, bg);
    if (picked) try bench.say(w, x0, y, "▌", if (app.columnFocused()) r.dim else r.accent, bg, true);
    try draw.sayCut(w, x0 + 2, y, project.name, App.scope_label_w, r.accent, bg, true);
    var moving_buf: [64]u8 = undefined;
    const moving = movingWords(&moving_buf, b, given, row.item);
    const stuck = std.mem.indexOf(u8, moving, "stuck") != null;
    const moving_x = x0 + ww -| (moving_w + 1);
    const auto_x = moving_x -| auto_w;
    try draw.sayCut(w, moving_x, y, moving, moving_w, if (stuck) r.failed else r.dim, bg, false);
    const global = if (b.autoState()) |state| state.on else false;
    try bench.say(w, auto_x, y, project.autoWord(global), r.dim, bg, false);
    const goal = project.goal orelse return bench.say(w, x0 + 2 + project_name_w, y, "nothing driven", r.dim, bg, false);
    const bar_room = bar_cells + 1 + 9;
    const bar_x = auto_x -| (bar_room + 2);
    try draw.goalBar(w, r, bar_x, y, bar_room, .{ .epic = goal.id, .title = goal.title, .landed = goal.landed, .total = goal.total }, r.building, bg, r.text, "", r.dim);
    var id_buf: [16]u8 = undefined;
    const id = std.fmt.bufPrint(&id_buf, "#{d}", .{goal.id}) catch "";
    const id_x = x0 + 2 + project_name_w;
    try bench.say(w, id_x, y, id, r.dim, bg, false);
    const title_x = id_x + cellCount(id) + 1;
    try draw.sayCut(w, title_x, y, goal.title, (bar_x -| 1) -| title_x, r.text, bg, false);
}

/// `babylon drive N`: the goal Plan drives towards.
pub fn drive(app: *App, epic: u32) !void {
    app.dirty = true;
    try app.send(.ignore, app_mod.captured("babylon drive {d}"), .{epic});
}
