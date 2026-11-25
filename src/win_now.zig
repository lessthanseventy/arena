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
const stepHue = draw.stepHue;

pub fn paint(app: *App, w: *Writer, r: theme.Roles, sheet: *const sheets.Sheet, at: usize, y: u16, x0: usize, ww: usize, lit: bool) !void {
    const given = app.board.?.plan().?;
    const row = sheet.rows[at];
    const picked = lit and app.planRowLit(row);
    const mark = if (app.columnFocused()) r.dim else r.accent;
    const bg = if (picked) r.raised else r.panel;
    switch (row.kind) {
        .now => {
            const item = given.now[row.item];
            try bench.fill(w, x0, y, ww, bg);
            if (picked) try bench.say(w, x0, y, "▌", mark, bg, true);
            const repo = repoHue(r, item.repo);
            var idb: [16]u8 = undefined;
            const id = std.fmt.bufPrint(&idb, "#{d}", .{item.ticket}) catch "";
            try bench.say(w, x0 + 1, y, "▌", repo.hue, bg, false);
            try bench.say(w, x0 + 2, y, repo.glyph, repo.hue, bg, false);
            try bench.say(w, x0 + 4, y, id, repo.hue, bg, true);
            var age: [16]u8 = undefined;
            var lbuf: [64]u8 = undefined;
            const how = sheets.ago(&age, item.since, app.epoch);
            const state = item.stage orelse item.state;
            var said: [24]u8 = undefined;
            var th: [16]u8 = undefined;
            const shown = if (item.place) |n| (if (std.mem.eql(u8, state, "queued")) (std.fmt.bufPrint(&said, "queued {s}", .{sheets.place(n, &th)}) catch state) else state) else state;
            const label = if (item.stalled) |why|
                std.fmt.bufPrint(&lbuf, "stalled · {s}", .{why}) catch "stalled"
            else if (item.waiting_on) |wait| wait.say(&lbuf) else if (how.len > 0) std.fmt.bufPrint(&lbuf, "{s} · {s}", .{ shown, how }) catch shown else shown;
            const lead = if (item.stalled != null) r.failed else if (item.waiting_on != null) r.dim else stepHue(r, state).lead;
            const chip_w = cellCount(label) + 2;
            const chip_x = x0 + ww -| (chip_w + 1);
            const title_x = x0 + 5 + cellCount(id);
            if (chip_x > title_x + 4) {
                _ = try bench.chipInk(w, r, chip_x, y, label, lead, if (item.stalled != null) r.on_accent else r.text, item.stalled != null);
                try bench.say(w, title_x, y, clip(item.title, chip_x - title_x - 1), if (row.dim) r.dim else r.text, bg, false);
            } else try bench.say(w, title_x, y, clip(item.title, x0 + ww -| title_x -| 1), if (row.dim) r.dim else r.text, bg, false);
        },
        else => {},
    }
}
