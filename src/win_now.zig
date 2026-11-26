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
const sayCut = draw.sayCut;
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
                try sayCut(w, title_x, y, item.title, chip_x - title_x - 1, if (row.dim) r.dim else r.text, bg, false);
            } else try sayCut(w, title_x, y, item.title, x0 + ww -| title_x -| 1, if (row.dim) r.dim else r.text, bg, false);
        },
        .other => {
            const claude = app.otherAt(row.item) orelse return;
            const win = claude.win;
            try bench.fill(w, x0, y, ww, bg);
            if (picked) try bench.say(w, x0, y, "▌", mark, bg, true);
            const repo = repoHue(r, app_mod.App.pathRepo(win.text(.path)));
            try bench.say(w, x0 + 1, y, "▌", repo.hue, bg, false);
            try bench.say(w, x0 + 2, y, repo.glyph, repo.hue, bg, false);
            const lead = switch (win.claude) {
                .stalled => r.failed,
                .waiting => r.you,
                .done => r.landed,
                .working, .background => r.building,
                .none => r.dim,
            };
            var mark_buf: [4]u8 = undefined;
            const n = std.unicode.utf8Encode(draw.agentGlyph(app, win), &mark_buf) catch 0;
            try bench.say(w, x0 + 5, y, mark_buf[0..n], lead, bg, true);
            var place_buf: [64]u8 = undefined;
            const place = std.fmt.bufPrint(&place_buf, "{s}:{d}", .{ app.sessions.items[claude.session].name, win.index }) catch "";
            var age_buf: [16]u8 = undefined;
            const age = draw.ago(&age_buf, app.epoch, win.since);
            const age_x = x0 + ww -| (cellCount(age) + 1);
            const place_x = age_x -| (cellCount(place) + 2);
            try bench.say(w, age_x, y, age, r.dim, bg, false);
            try bench.say(w, place_x, y, place, r.dim, bg, false);
            try sayCut(w, x0 + 7, y, win.label(), place_x -| (x0 + 8), r.text, bg, false);
            try bench.say(w, x0 + ww, y, "▌", r.well, r.ground, false);
        },
        else => {},
    }
}

/// Enter on an in flight row: to the Claude building it, or with none and nothing moving it,
/// starts one; to the gate for a ticket in the pipeline.
pub fn act(app: *App, row: *const sheets.Row) !void {
    const given = app.board.?.plan().?;
    const id = row.ticket orelse return;
    const item = for (given.now) |item| {
        if (item.ticket == id) break item;
    } else return;
    const pane = if (item.holder()) |held| (if (app.paneWindow(held) != null) held else null) else null;
    if (pane) |held| return app.showPane(held);
    if (item.stalled != null) return app.send(.ignore, app_mod.captured("babylon start {d}"), .{id});
    if (!std.mem.eql(u8, item.state, "building")) try app.openGate(id);
}

/// A click on a held row: the pane holding the ticket, shown.
pub fn heldClick(app: *App, row: sheets.Row) !void {
    const pane = app.board.?.plan().?.now[row.item].holder() orelse return;
    return app.showPane(pane);
}
