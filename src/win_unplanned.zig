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
    const given = app.board.?.plan().?;
    const row = sheet.rows[at];
    const picked = lit and app.planRowLit(row);
    const mark = if (app.columnFocused()) r.dim else r.accent;
    const bg = if (picked) r.raised else r.panel;
    switch (row.kind) {
        .unplanned => {
            const not = given.not_planned;
            try bench.fill(w, x0, y, ww, bg);
            if (picked) try bench.say(w, x0, y, "▌", mark, bg, true);
            var x = x0 + 2;
            for (not.by_repo.map.keys(), not.by_repo.map.values()) |name, n| {
                var buf: [64]u8 = undefined;
                const look = repoHue(r, name);
                const label = std.fmt.bufPrint(&buf, "{s} {s} {d}", .{ look.glyph, name, n }) catch "";
                if (x + cellCount(label) + 2 > x0 + ww) break;
                x += try bench.chipInk(w, r, x, y, label, look.hue, r.text, false) + 1;
            }
            var buf: [32]u8 = undefined;
            const follow = std.fmt.bufPrint(&buf, "· {d} follow-ups", .{not.follow_ups}) catch "";
            if (x + cellCount(follow) < x0 + ww) try bench.say(w, x, y, follow, r.dim, bg, false);
            try bench.say(w, x0 + ww, y, "▌", r.well, r.ground, false);
        },
        .chips => {
            try bench.fill(w, x0, y, ww, bg);
            if (picked) try bench.say(w, x0, y, "▌", mark, bg, true);
            var chips_buf: [sheets.max_chips]sheets.Chip = undefined;
            const view = app.board_view.?;
            const chips_n = app.chipsOf(&chips_buf).len;
            for (chips_buf[0..chips_n], 0..) |c, i| {
                var buf: [64]u8 = undefined;
                const name = c.repo orelse "backlog";
                const look = repoHue(r, c.repo);
                const label = if (c.repo != null)
                    std.fmt.bufPrint(&buf, "{s} {s} {d}", .{ look.glyph, name, c.n }) catch ""
                else
                    std.fmt.bufPrint(&buf, "{s} {d}", .{ name, c.n }) catch "";
                const open = if (c.repo) |repo| !app.folded(repo) else view.plan_backlog;
                const hue = if (c.repo == null) r.accent else look.hue;
                _ = try bench.chipInk(w, r, c.x, y, label, if (open) hue else r.dim, if (open) r.on_accent else r.dim, open);
                if (picked and view.plan_chip == i) try bench.say(w, c.x + c.w, y, "◂", mark, bg, true);
            }
            var buf: [32]u8 = undefined;
            const follow = std.fmt.bufPrint(&buf, "· {d} follow-ups", .{given.not_planned.follow_ups}) catch "";
            const after = x0 + ww -| cellCount(follow) -| 1;
            const used = for (0..chips_n) |i| {
                if (i + 1 == chips_n) break chips_buf[i].x + chips_buf[i].w + 2;
            } else x0 + 2;
            if (after > used) try bench.say(w, after, y, follow, r.dim, bg, false);
            try bench.say(w, x0 + ww, y, "▌", r.well, r.ground, false);
        },
        .todo, .backlog => {
            const card = app.cardById(row.ticket orelse return) orelse return;
            try bench.fill(w, x0, y, ww, bg);
            if (picked) try bench.say(w, x0, y, "▌", mark, bg, true);
            const repo = repoHue(r, card.repo);
            var idb: [16]u8 = undefined;
            const id = std.fmt.bufPrint(&idb, "#{d}", .{card.id}) catch "";
            try bench.say(w, x0 + 1, y, "▌", repo.hue, bg, false);
            try bench.say(w, x0 + 2, y, repo.glyph, repo.hue, bg, false);
            try bench.say(w, x0 + 4, y, id, repo.hue, bg, true);
            var lbuf: [64]u8 = undefined;
            var age: [16]u8 = undefined;
            const how = sheets.ago(&age, card.inserted_at, app.epoch);
            const label = if (card.blocked_by.len > 0)
                std.fmt.bufPrint(&lbuf, "{s}  ← #{d}", .{ card.priority, card.blocked_by[0] }) catch card.priority
            else if (row.kind == .backlog and how.len > 0) std.fmt.bufPrint(&lbuf, "{s}  {s}", .{ card.priority, how }) catch card.priority else card.priority;
            const label_x = x0 + ww -| (cellCount(label) + 1);
            const title_x = x0 + 5 + cellCount(id);
            const dim = card.blocked_by.len > 0;
            try bench.say(w, label_x, y, label, if (dim) r.dim else if (std.mem.eql(u8, card.priority, "high")) r.you else r.dim, bg, false);
            try bench.say(w, title_x, y, clip(card.title, label_x -| title_x -| 1), if (dim) r.dim else r.text, bg, false);
            try bench.say(w, x0 + ww, y, "▌", r.well, r.ground, false);
        },
        else => {},
    }
}

/// Enter on a row of not planned: the board on its first lane for the summary, a chip's repo
/// toggled for the chips, and a todo row's ticket gone to.
pub fn act(app: *App, row: *const sheets.Row) !void {
    const view = &app.board_view.?;
    switch (row.kind) {
        .chips => try app.toggleChip(view.plan_chip),
        .todo => try app.act(.go),
        .unplanned => {
            try app.toBoard();
            const bv = &app.board_view.?;
            bv.repo = 0;
            bv.backlog = false;
            bv.row = 0;
            bv.lane = app.firstLane();
            bv.col = 0;
        },
        else => {},
    }
}
