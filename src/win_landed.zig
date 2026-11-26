const std = @import("std");
const color = @import("color.zig");
const theme = @import("theme.zig");
const bench = @import("parts.zig");
const app_mod = @import("app.zig");
const tickets = @import("board.zig");
const sheets = @import("plan.zig");
const draw = @import("draw.zig");
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

/// What of a landed row's name goes on a second line, in a window `ww` cells wide.
pub fn wrapRest(app: *const App, row: sheets.Row, ww: usize) ?[]const u8 {
    const at = titleRoom(app, row.ticket orelse return null, ww);
    return draw.wrapRest(at.name, at.room);
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
                const name = if (at + 1 < sheet.n and sheet.rows[at + 1].kind == .wrap) draw.wrapHead(c.name(), sheet.rows[at + 1].text) else c.name();
                try draw.sayCut(w, title_x, y, name, titleRoom(app, id, ww).room, r.text, bg, false);
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
