const std = @import("std");
const theme = @import("theme.zig");
const bench = @import("parts.zig");
const app_mod = @import("app.zig");
const sheets = @import("plan.zig");
const draw = @import("draw.zig");
const menu = @import("menu.zig");
const win_detail = @import("win_detail.zig");
const anyKey = app_mod.anyKey;
const captured = app_mod.captured;
const App = app_mod.App;
const Writer = std.Io.Writer;
const clip = draw.clip;
const sayCut = draw.sayCut;
const cellCount = draw.cellCount;
const repoHue = draw.repoHue;

/// The block under an opened backlog row, in a window `ww` cells wide: its priority and age.
pub fn detail(app: *const App, row: sheets.Row, ww: usize, lines: *sheets.Lines) void {
    const id = row.ticket orelse return;
    const card = app.cardById(id) orelse return;
    var age: [16]u8 = undefined;
    const filed = sheets.ago(&age, card.inserted_at, app.epoch);
    const stage = lines.print("backlog · {s}{s}{s}", .{ card.priority, if (filed.len > 0) " · filed " else "", filed });
    var idb: [16]u8 = undefined;
    win_detail.fill(app, lines, .{ .ticket = id, .title = card.title, .stage = stage }, ww, @intCast(5 + cellCount(std.fmt.bufPrint(&idb, "#{d}", .{id}) catch "")));
}

pub fn paint(app: *App, w: *Writer, r: theme.Roles, sheet: *const sheets.Sheet, at: usize, y: u16, x0: usize, ww: usize, lit: bool) !void {
    const given = app.board.?.plan().?;
    const row = sheet.rows[at];
    const picked = lit and app.planRowLit(row);
    const mark = if (app.columnFocused()) r.dim else r.accent;
    const bg = if (picked) r.raised else r.panel;
    try bench.fill(w, x0, y, ww, bg);
    if (picked) try bench.say(w, x0, y, "▌", mark, bg, true);
    switch (row.kind) {
        .idea => {
            const idea = given.ideas[row.item];
            const state = sheets.Sheet.ideaState(idea);
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
                try sayCut(w, title_x, y, idea.name(), chip_x - title_x - 1, if (row.dim) r.dim else r.text, bg, false);
            } else try sayCut(w, title_x, y, idea.name(), right -| title_x, if (row.dim) r.dim else r.text, bg, false);
        },
        .backlog => {
            const card = app.cardById(row.ticket orelse return) orelse return;
            const repo = repoHue(r, card.repo);
            var idb: [16]u8 = undefined;
            const id = std.fmt.bufPrint(&idb, "#{d}", .{card.id}) catch "";
            try bench.say(w, x0 + 1, y, "▌", repo.hue, bg, false);
            try bench.say(w, x0 + 2, y, repo.glyph, repo.hue, bg, false);
            try bench.say(w, x0 + 4, y, id, repo.hue, bg, true);
            var age: [16]u8 = undefined;
            const how = sheets.ago(&age, card.inserted_at, app.epoch);
            const label = how;
            const label_x = x0 + ww -| (cellCount(label) + 1);
            const title_x = x0 + 5 + cellCount(id);
            try bench.say(w, label_x, y, label, r.dim, bg, false);
            try sayCut(w, title_x, y, card.name(), label_x -| title_x -| 1, if (row.dim) r.dim else r.text, bg, false);
        },
        else => {},
    }
}

/// Enter on an idea: plans it, or goes to the Claude planning it.
pub fn act(app: *App, row: *const sheets.Row) !void {
    const given = app.board.?.plan().?;
    const idea = given.ideas[row.item];
    switch (sheets.Sheet.ideaState(idea)) {
        .idea => try app.send(.ignore, captured("babylon idea {d} --plan"), .{idea.epic}),
        .planning => if (idea.holder()) |held| if (app.paneWindow(held) != null) return app.openClaude(held),
        .draft => unreachable,
    }
}

/// `e` and `x` on an idea row: a kept idea's text edited in $EDITOR as a card's is, or the idea
/// withdrawn. One with a Claude on it or a draft is left to its own keys.
pub fn ideaKey(app: *App, row: *const sheets.Row, key: []const u8) !void {
    const idea = app.board.?.plan().?.ideas[row.item];
    if (sheets.Sheet.ideaState(idea) != .idea) return;
    if (anyKey(key, &.{"e"})) return app.ticketWindow("babylon edit {d}", .{idea.epic});
    if (anyKey(key, &.{"x"})) try app.send(.ignore, captured("babylon withdraw {d}"), .{idea.epic});
}

/// `x` on a backlog row: a line for why it is closed, which Enter sends with the close.
pub fn openClose(app: *App, id: u32) void {
    var prompt: menu.Prompt = .{ .what = .why };
    const said = std.fmt.bufPrint(&prompt.target, "close:{d}", .{id}) catch return;
    prompt.target_len = said.len;
    app.prompt = prompt;
    app.normal = false;
    app.dirty = true;
}
