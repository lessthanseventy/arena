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
            const title_room = (if (how.len > 0) how_x else x0 + ww) -| title_x -| 1;
            if (card) |c| try draw.sayCut(w, title_x, y, c.title, title_room, r.text, bg, false);
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
