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
const goalHue = draw.goalHue;
const goalChips = draw.goalChips;
const stepChip = draw.stepChip;

pub fn paint(app: *App, w: *Writer, r: theme.Roles, sheet: *const sheets.Sheet, at: usize, y: u16, x0: usize, ww: usize, lit: bool) !void {
    const b = &app.board.?;
    const given = b.plan().?;
    const row = sheet.rows[at];
    const picked = lit and app.planRowLit(row);
    const mark = if (app.columnFocused()) r.dim else r.accent;
    const bg = if (picked) r.raised else r.panel;
    const room = ww - 4;
    switch (row.kind) {
        .idea => {
            const idea = given.ideas[row.item];
            const state = sheets.Sheet.ideaState(idea);
            try bench.fill(w, x0, y, ww, bg);
            if (picked) try bench.say(w, x0, y, "▌", mark, bg, true);
            const lead = switch (state) {
                .idea => r.dim,
                .planning => r.building,
                .draft => r.you,
            };
            var idb: [16]u8 = undefined;
            const id = std.fmt.bufPrint(&idb, "#{d}", .{idea.epic}) catch "";
            try bench.say(w, x0 + 2, y, sheets.Sheet.ideaMark(state), lead, bg, false);
            try bench.say(w, x0 + 4, y, id, r.dim, bg, true);
            var lbuf: [64]u8 = undefined;
            const label = sheets.Sheet.ideaLabel(&lbuf, idea, app.epoch);
            const asks = state == .planning and idea.asks > 0;
            const ask_text = "▲ asks you";
            const right = x0 + ww -| 1;
            const chip_x = right -| (cellCount(label) + 2) -| (if (asks) cellCount(ask_text) + 1 else 0);
            const title_x = x0 + 5 + cellCount(id);
            if (asks) try bench.say(w, right -| cellCount(ask_text), y, ask_text, r.you, bg, true);
            if (chip_x > title_x + 4) {
                _ = try bench.chipInk(w, r, chip_x, y, label, lead, r.text, false);
                try bench.say(w, title_x, y, clip(idea.title, chip_x - title_x - 1), if (row.dim) r.dim else r.text, bg, false);
            } else try bench.say(w, title_x, y, clip(idea.title, right -| title_x), if (row.dim) r.dim else r.text, bg, false);
        },
        .ideas_more => {
            try bench.fill(w, x0, y, ww, bg);
            if (picked) try bench.say(w, x0, y, "▌", mark, bg, true);
            try bench.say(w, x0 + 2, y, clip(std.mem.trim(u8, row.text, " "), room), r.dim, bg, false);
        },
        .card_top, .goal, .goal_bar, .goal_next, .goal_block => {
            const goal = given.goals[row.item];
            const base = at - @as(usize, switch (row.kind) {
                .card_top => @as(usize, 0),
                .goal => 1,
                .goal_bar => 2,
                .goal_next => 3,
                else => 4,
            });
            const card_picked = lit and sheet.rows[base + 1].pick == app.board_view.?.plan_pick;
            const face = if (card_picked) r.raised else r.tile;
            try bench.fill(w, x0, y, ww, r.panel);
            const cx = x0 + 1;
            const cw = ww - 2;
            try bench.say(w, x0 + ww, y, "▌", r.well, r.ground, false);
            switch (row.kind) {
                .card_top => try bench.bevel(w, cx, y, cw, if (card_picked) r.text.mix(face, 0.5) else r.raised, face),
                .goal => {
                    try bench.fill(w, cx, y, cw, face);
                    if (card_picked) try bench.say(w, cx + 1, y, "▌", mark, face, true);
                    var idb: [16]u8 = undefined;
                    const id = std.fmt.bufPrint(&idb, "#{d} ", .{goal.epic}) catch "";
                    const hue = goalHue(b, r, goal);
                    const shares = try goalChips(w, r, b, goal, cx + cw, y);
                    try bench.say(w, cx + 2, y, id, hue, face, true);
                    try bench.say(w, cx + 2 + cellCount(id), y, clip(goal.title, cw -| 4 -| cellCount(id) -| shares), if (row.dim) r.dim else r.text, face, true);
                },
                .goal_bar => {
                    try bench.fill(w, cx, y, cw, face);
                    var buf: [32]u8 = undefined;
                    const pct: u32 = if (goal.total == 0) 0 else goal.landed * 100 / goal.total;
                    const label = std.fmt.bufPrint(&buf, "{d}/{d}  {d}%", .{ goal.landed, goal.total, pct }) catch "";
                    const trying = sheets.goalTrying(goal);
                    var tb: [24]u8 = undefined;
                    const words = if (trying > 0) std.fmt.bufPrint(&tb, "▲ {d} to try", .{trying}) catch "" else "";
                    const bar_w = cw -| 4 -| cellCount(label) -| (if (words.len > 0) cellCount(words) + 2 else 0);
                    try bench.bar(w, r, cx + 2, y, bar_w, goal.landed, goal.total, goalHue(b, r, goal));
                    try bench.say(w, cx + 3 + bar_w, y, label, r.dim, face, false);
                    if (words.len > 0) try bench.say(w, cx + 3 + bar_w + cellCount(label) + 2, y, words, r.you, face, false);
                },
                .goal_next => {
                    try bench.fill(w, cx, y, cw, face);
                    try bench.say(w, cx + 2, y, "next", r.dim, face, false);
                    if (sheets.goalNext(goal)) |step| _ = try stepChip(w, r, cx + 10, y, step) else try bench.say(w, cx + 10, y, "nothing", r.dim, face, false);
                },
                else => {
                    try bench.fill(w, cx, y, cw, face);
                    try bench.say(w, cx + 2, y, "blocked", r.dim, face, false);
                    if (sheets.goalBlock(goal)) |block| {
                        var buf: [40]u8 = undefined;
                        _ = try bench.chipInk(w, r, cx + 10, y, std.fmt.bufPrint(&buf, "\u{f0c1} #{d} waits on #{d}", .{ block.step, block.on }) catch "", r.dim, r.dim, false);
                    } else try bench.say(w, cx + 10, y, "nothing", r.dim, face, false);
                },
            }
            if (row.kind != .card_top) try bench.say(w, cx, y, "▌", goalHue(b, r, goal), face, false);
        },
        else => {},
    }
}
