//! What every opened row shows under it, whatever window it is in: its title whole, a blank row,
//! then the lines a window gives it and the ones every ticket has (its goal, its checks).
const std = @import("std");
const app_mod = @import("app.zig");
const tickets = @import("board.zig");
const sheets = @import("plan.zig");
const App = app_mod.App;

/// What a window knows of its row that the card does not: next's why and what it waits on, the
/// stage line, in `words` and `wait` when it has them.
pub const Window = struct {
    ticket: u32,
    title: []const u8,
    why: []const u8 = "",
    wait: []const u8 = "",
    stage: []const u8 = "",
};

/// The block under an opened row, `indent` cells in a window `ww` cells wide: the title wrapped, a
/// blank row, then goal, why, waits, stage and checks, each only when there is one.
pub fn fill(app: *const App, lines: *sheets.Lines, row: Window, ww: usize, indent: u8) void {
    const card = app.cardById(row.ticket);
    lines.wrap(if (card) |c| c.title else row.title, @max(ww -| @as(usize, indent) -| 2, 8), indent);
    lines.add(.{});
    if (card) |c| if (c.epic_id) |epic| if (app.cardById(epic)) |goal| lines.field(indent, "goal", "◆ #{d} {s}", .{ goal.id, goal.name() });
    if (row.why.len > 0) lines.field(indent, "why", "{s}", .{row.why});
    if (row.wait.len > 0) lines.field(indent, "waits", "{s}", .{row.wait});
    if (row.stage.len > 0) lines.field(indent, "stage", "{s}", .{row.stage});
    const c = card orelse return;
    for (c.checks, 0..) |check, i| {
        const sign: []const u8 = if (check.result) |result| (if (std.mem.eql(u8, result, "ok")) "✓" else "✗") else "○";
        lines.field(indent, if (i == 0) "checks" else "", "{s} {s}", .{ sign, check.text });
    }
}

/// `waits #N` or `after #N`, for the first wait of `on`; empty for none.
pub fn waitWords(lines: *sheets.Lines, on: []const tickets.Wait) []const u8 {
    const first = tickets.Wait.first(on) orelse return "";
    return if (first.ticket) |t| lines.print("waits #{d}", .{t}) else lines.print("after #{d}", .{first.until.?});
}
