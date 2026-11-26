const std = @import("std");
const color = @import("color.zig");
const theme = @import("theme.zig");
const bench = @import("parts.zig");
const app_mod = @import("app.zig");
const tickets = @import("board.zig");
const sheets = @import("plan.zig");
const menu = @import("menu.zig");
const draw = @import("draw.zig");
const keys = @import("keys.zig");
const anyKey = app_mod.anyKey;
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
        },
        .chips => {
            try bench.fill(w, x0, y, ww, bg);
            if (picked) try bench.say(w, x0, y, "▌", mark, bg, true);
            var chips_buf: [sheets.max_chips]sheets.Chip = undefined;
            const view = app.home.?;
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
            try draw.sayCut(w, title_x, y, card.name(), label_x -| title_x -| 1, if (dim) r.dim else r.text, bg, false);
        },
        else => {},
    }
}

/// Enter on a row of not planned: a chip's repo toggled for the chips, and a todo row's ticket
/// gone to.
pub fn act(app: *App, row: *const sheets.Row) !void {
    const view = &app.home.?;
    switch (row.kind) {
        .chips => try toggleChip(app, view.plan_chip),
        .todo => try app.act(.go),
        else => {},
    }
}

/// `J` `K` on a todo row: it moves down or up its repo's order, `babylon move N down|up --repo R`,
/// and the pick goes with it while the next row is a todo one.
pub fn moveTodo(app: *App, sheet: *const sheets.Sheet, row: *const sheets.Row, down: bool) !void {
    const view = &app.home.?;
    const card = app.cardById(row.ticket orelse return) orelse return;
    const repo = card.repo orelse return;
    if (!app_mod.plainName(repo)) return;
    try app.send(.ignore, app_mod.captured("babylon move {d} {s} --repo {s}"), .{ card.id, if (down) "down" else "up", repo });
    const to = if (down) view.plan_pick + 1 else view.plan_pick -| 1;
    if (sheet.picked(to)) |near| if (near.kind == .todo) {
        view.plan_pick = to;
    };
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

/// A click on the title bar: on `+ new`, a new ticket.
pub fn titleClick(app: *App, x: u16) !bool {
    const new = app.newHead() orelse return false;
    if (x < new.x or x >= new.x + new.w) return false;
    try app.newTicket();
    return true;
}

/// The not planned window's title-bar extra: its `+ new` button.
pub fn frame(app: *App, w: *Writer, r: theme.Roles) !void {
    const head = app.newHead() orelse return;
    try bench.headButton(w, r, head.x, head.y, " + new ", r.accent, false);
}

/// The chip row's own keys: `h` `l` from chip to chip, `Z` opening only the chip's repo. False
/// for the rest, and past the first or last chip, for the window beside to take.
pub fn chipKey(app: *App, key: []const u8) !bool {
    const view = &app.home.?;
    var chips: [sheets.max_chips]sheets.Chip = undefined;
    const all = app.chipsOf(&chips);
    if (all.len == 0) return false;
    view.plan_chip = @min(view.plan_chip, all.len - 1);
    if (anyKey(key, &.{ "l", "\x1b[C", "\x1bOC" })) {
        if (view.plan_chip + 1 == all.len) return false;
        view.plan_chip += 1;
        app.dirty = true;
        return true;
    }
    if (anyKey(key, &.{ "h", "\x1b[D", "\x1bOD" })) {
        if (view.plan_chip == 0) return false;
        view.plan_chip -= 1;
        app.dirty = true;
        return true;
    }
    if (!anyKey(key, &.{"Z"})) return false;
    if (all[view.plan_chip].repo) |repo| try app.focusFold(repo) else try toggleChip(app, view.plan_chip);
    return true;
}

/// Chip `at` of not planned's row folded or opened: a repo's through #849's fold, the backlog's
/// its cards in the rows' place.
pub fn toggleChip(app: *App, at: usize) !void {
    const view = &app.home.?;
    var chips: [sheets.max_chips]sheets.Chip = undefined;
    const all = app.chipsOf(&chips);
    if (at >= all.len) return;
    view.plan_chip = at;
    if (all[at].repo) |repo| return app.toggleRepoFold(repo);
    view.plan_backlog = !view.plan_backlog;
    app.dirty = true;
}

/// A click on the chip row: the chip under it folded or opened.
pub fn chipClick(app: *App, m: keys.Mouse) !void {
    var chips: [sheets.max_chips]sheets.Chip = undefined;
    for (app.chipsOf(&chips), 0..) |c, i| if (m.x >= c.x and m.x < c.x + c.w) return toggleChip(app, i);
}

/// A press on a todo row: it is held, to be dragged to next or opened where it was pressed.
pub fn todoPress(app: *App, row: sheets.Row) void {
    app.drag = .{ .todo_row = .{ .id = row.ticket orelse return } };
}
