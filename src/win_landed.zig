const std = @import("std");
const color = @import("color.zig");
const theme = @import("theme.zig");
const bench = @import("parts.zig");
const app_mod = @import("app.zig");
const tickets = @import("board.zig");
const sheets = @import("plan.zig");
const draw = @import("draw.zig");
const win_detail = @import("win_detail.zig");
const App = app_mod.App;
const Writer = std.Io.Writer;
const clip = draw.clip;
const cellCount = draw.cellCount;
const repoHue = draw.repoHue;

/// Where a landed row's name starts and the cells it has before its age, in a window `ww` cells
/// wide.
pub fn titleRoom(app: *const App, id: u32, ww: usize) struct { x: usize, room: usize, name: []const u8 } {
    const card = app.cardById(id) orelse return .{ .x = 0, .room = 0, .name = "" };
    var idb: [16]u8 = undefined;
    var age: [16]u8 = undefined;
    const how = sheets.ago(&age, card.closed_at, app.epoch);
    const title_x = 5 + cellCount(std.fmt.bufPrint(&idb, "#{d}", .{id}) catch "");
    const how_x = ww -| (cellCount(how) + 1);
    const end = if (how.len > 0 and how_x > title_x + 4) how_x else ww;
    return .{ .x = title_x, .room = end -| title_x -| 1, .name = card.name() };
}

/// The block under an opened landed row, in a window `ww` cells wide: when it landed.
pub fn detail(app: *const App, row: sheets.Row, ww: usize, lines: *sheets.Lines) void {
    const id = row.ticket orelse return;
    const at = titleRoom(app, id, ww);
    var age: [16]u8 = undefined;
    const closed = sheets.ago(&age, if (app.cardById(id)) |card| card.closed_at else null, app.epoch);
    const stage = lines.print("landed{s}{s}", .{ if (closed.len > 0) " · " else "", closed });
    win_detail.fill(app, lines, .{ .ticket = id, .title = at.name, .stage = stage }, ww, @intCast(at.x));
}

pub fn paint(app: *App, w: *Writer, r: theme.Roles, sheet: *const sheets.Sheet, at: usize, y: u16, x0: usize, ww: usize, lit: bool) !void {
    const b = &app.board.?;
    const row = sheet.rows[at];
    const picked = lit and app.planRowLit(row);
    const mark = if (app.columnFocused()) r.dim else r.accent;
    const bg = if (picked) r.raised else r.panel;
    switch (row.kind) {
        .landed => {
            const id = row.ticket.?;
            const card = for (b.cards()) |*card| {
                if (card.id == id) break card;
            } else null;
            const repo = repoHue(r, if (card) |c| c.repo else null);
            try bench.fill(w, x0, y, ww, bg);
            if (picked) try bench.say(w, x0, y, "▌", mark, bg, true);
            var idb: [16]u8 = undefined;
            const text = std.fmt.bufPrint(&idb, "#{d}", .{id}) catch "";
            try bench.say(w, x0 + 1, y, "▌", repo.hue, bg, false);
            try bench.say(w, x0 + 2, y, "✓", r.landed, bg, false);
            try bench.say(w, x0 + 4, y, text, repo.hue, bg, true);
            var age: [16]u8 = undefined;
            const how = sheets.ago(&age, if (card) |c| c.closed_at else null, app.epoch);
            const title_x = x0 + 5 + cellCount(text);
            const how_x = x0 + ww -| (cellCount(how) + 1);
            if (how.len > 0 and how_x > title_x + 4) try bench.say(w, how_x, y, how, r.dim, bg, false);
            if (card) |c| {
                try draw.sayCut(w, title_x, y, c.name(), titleRoom(app, id, ww).room, r.text, bg, false);
            }
        },
        else => {},
    }
}

/// Enter on a landed row: the ticket's whole detail.
pub fn act(app: *App, row: *const sheets.Row) !void {
    if (row.ticket) |id| {
        _ = try app.openDetail(id);
    }
}
