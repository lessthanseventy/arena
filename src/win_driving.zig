const std = @import("std");
const theme = @import("theme.zig");
const bench = @import("parts.zig");
const app_mod = @import("app.zig");
const sheets = @import("plan.zig");
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
            var head: [24]u8 = undefined;
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

/// `babylon drive N`: the goal Plan drives towards.
pub fn drive(app: *App, epic: u32) !void {
    app.dirty = true;
    try app.send(.ignore, app_mod.captured("babylon drive {d}"), .{epic});
}
