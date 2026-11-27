//! The Claudes list in the middle column: the Claudes working on tickets, today's in-flight rows,
//! then the Claudes with no ticket under a rule.
const std = @import("std");
const color = @import("color.zig");
const theme = @import("theme.zig");
const bench = @import("parts.zig");
const app_mod = @import("app.zig");
const tickets = @import("board.zig");
const sheets = @import("plan.zig");
const draw = @import("draw.zig");
const win_board = @import("win_board.zig");
const App = app_mod.App;
const Writer = std.Io.Writer;
const anyKey = app_mod.anyKey;
const cellCount = draw.cellCount;
const repoHue = draw.repoHue;

/// A row of the list: a ticket in flight, or a Claude with none.
const Entry = union(enum) { ticket: usize, other: app_mod.App.Agent };

fn tickets_n(app: *const App) usize {
    return (app.board orelse return 0).plan().?.now.len;
}

/// How many rows the list holds.
fn count(app: *const App) usize {
    var others: [App.max_others]App.Agent = undefined;
    return tickets_n(app) + app.otherClaudes(&others).len;
}

fn entryAt(app: *const App, at: usize) ?Entry {
    const n = tickets_n(app);
    if (at < n) return .{ .ticket = at };
    const other = app.otherAt(at - n) orelse return null;
    return .{ .other = other };
}

/// The Claudes list opened in the middle column, the plan's pick where it was.
pub fn open(app: *App) !void {
    if (app.home == null) try app.goHome();
    if (!app.hasPlan()) return;
    app.dropOwned();
    const view = &app.home.?;
    view.detail = null;
    view.item_open = false;
    view.giving = null;
    view.into = null;
    view.repos = false;
    view.claude = null;
    view.claudes = true;
    view.claudes_pick = 0;
    view.focus = .plan;
    app.normal = false;
    app.dirty = true;
}

/// A key with the list open: `j` `k` pick, `⏎` the pane, space the card, `H` hands the ticket
/// off, `esc` goes back to Doing.
pub fn key(app: *App, pressed: []const u8) !void {
    const view = &app.home.?;
    app.dirty = true;
    const total = count(app);
    view.claudes_pick = @min(view.claudes_pick, total -| 1);
    if (anyKey(pressed, &.{ "\x1b", "q" })) {
        view.claudes = false;
        return;
    }
    if (anyKey(pressed, &.{ "j", "\x1b[B", "\x1bOB" })) {
        view.claudes_pick = @min(view.claudes_pick + 1, total -| 1);
        return;
    }
    if (anyKey(pressed, &.{ "k", "\x1b[A", "\x1bOA" })) {
        view.claudes_pick -|= 1;
        return;
    }
    const entry = entryAt(app, view.claudes_pick) orelse return;
    const enter = anyKey(pressed, &.{"\r"});
    const space = anyKey(pressed, &.{" "});
    switch (entry) {
        .ticket => |at| {
            const item = app.board.?.plan().?.now[at];
            if (anyKey(pressed, &.{"H"})) {
                if (app.cardById(item.ticket)) |card| try app.askHandoff(card);
                return;
            }
            if (!enter and !space) return;
            view.claudes = false;
            if (space) {
                _ = try app.openDetail(item.ticket);
                return;
            }
            try win_board.act(app, &.{ .kind = .now, .ticket = item.ticket, .item = at });
        },
        .other => |claude| {
            if (enter) {
                view.claudes = false;
                return app.openClaude(claude.win.agent_pane);
            }
            if (!space) return;
            view.claudes = false;
            try app.closeBoard();
            app.normal = true;
            app.openPopup(claude.win.id);
        },
    }
}

/// A ticket's row in the list: its Claude's mark, `#id`, name, state and age, and where its
/// Claude runs.
fn paintTicket(app: *App, w: *Writer, r: theme.Roles, item: tickets.NowItem, x0: usize, y: u16, ww: usize, bg: color.RGB) !void {
    const hue = repoHue(r, item.repo);
    const held = if (item.holder()) |pane| app.paneWindow(pane) else null;
    var mark: [4]u8 = undefined;
    const lead = if (item.stalled != null) r.failed else r.building;
    if (held) |at| {
        const win = at.session.wins.items[at.index];
        const n = std.unicode.utf8Encode(draw.agentGlyph(app, win), &mark) catch 0;
        try bench.say(w, x0, y, mark[0..n], lead, bg, true);
    } else try bench.say(w, x0, y, "·", r.dim, bg, false);
    var idb: [16]u8 = undefined;
    const id = std.fmt.bufPrint(&idb, "#{d}", .{item.ticket}) catch "";
    try bench.say(w, x0 + 2, y, id, hue.hue, bg, true);
    var age: [16]u8 = undefined;
    const since = sheets.ago(&age, item.since, app.epoch);
    var place_buf: [64]u8 = undefined;
    const place = if (held) |at| std.fmt.bufPrint(&place_buf, "{s}:{d}", .{ at.session.name, at.session.wins.items[at.index].index }) catch "" else "";
    var right_buf: [160]u8 = undefined;
    const stage = item.stage orelse item.state;
    const right = std.fmt.bufPrint(&right_buf, "{s}{s}  {s}  {s}", .{ if (item.stalled != null) "◇ stuck · " else "", stage, place, since }) catch "";
    const right_x = x0 + ww -| cellCount(right);
    const title_x = x0 + 3 + cellCount(id);
    try bench.say(w, right_x, y, right, if (item.stalled != null) r.failed else r.dim, bg, false);
    try draw.sayCut(w, title_x, y, item.name(), right_x -| title_x -| 1, r.text, bg, false);
}

/// A Claude with no ticket: its mark, label, and where it runs and for how long.
fn paintOther(app: *App, w: *Writer, r: theme.Roles, claude: App.Agent, x0: usize, y: u16, ww: usize, bg: color.RGB) !void {
    const win = claude.win;
    const lead = switch (win.claude) {
        .stalled => r.failed,
        .waiting => r.you,
        .done => r.landed,
        .working, .background => r.building,
        .none => r.dim,
    };
    var mark: [4]u8 = undefined;
    const n = std.unicode.utf8Encode(draw.agentGlyph(app, win), &mark) catch 0;
    try bench.say(w, x0, y, mark[0..n], lead, bg, true);
    var place_buf: [64]u8 = undefined;
    const place = std.fmt.bufPrint(&place_buf, "{s}:{d}", .{ app.sessions.items[claude.session].name, win.index }) catch "";
    var age_buf: [16]u8 = undefined;
    const age = draw.ago(&age_buf, app.epoch, win.since);
    const age_x = x0 + ww -| cellCount(age);
    const place_x = age_x -| (cellCount(place) + 2);
    try bench.say(w, age_x, y, age, r.dim, bg, false);
    try bench.say(w, place_x, y, place, r.dim, bg, false);
    try draw.sayCut(w, x0 + 2, y, win.label(), place_x -| (x0 + 3), r.text, bg, false);
}

pub fn paint(app: *App, w: *Writer) !void {
    const r = app.roles orelse bench.roles();
    const rect = app.columnRect() orelse return;
    const view = app.home.?;
    const given = app.board.?.plan().?;
    var others: [App.max_others]App.Agent = undefined;
    const rest = app.otherClaudes(&others);
    const total = given.now.len + rest.len;
    const inner = app_mod.detailWidth(app.columnRoom()).inner;
    const x0 = rect.x + 2;
    const foot = rect.y + rect.h - 1;
    app.grab.window(.{ .x = x0, .y = rect.y + 1, .w = inner, .h = rect.h -| 2 });
    try bench.window(w, r, rect.x, rect.y, rect.w - 1, rect.h + 1, "doing › Claudes", total, true);

    const body = @as(usize, foot -| rect.y -| 1);
    const lines = total + @as(usize, if (rest.len > 0) 1 else 0);
    const pick_line = view.claudes_pick + @as(usize, if (rest.len > 0 and view.claudes_pick >= given.now.len) 1 else 0);
    const top = @min((pick_line + 1) -| body, lines -| body);
    var y = rect.y + 1;
    var line: usize = 0;
    for (0..total) |i| {
        if (i == given.now.len and rest.len > 0) {
            if (line >= top and y < foot) {
                var rule: [48]u8 = undefined;
                const label = std.fmt.bufPrint(&rule, "── no ticket {d} ", .{rest.len}) catch "";
                try bench.say(w, x0, y, label, r.dim, r.panel, false);
                try draw.repeat(w, x0 + cellCount(label), y, "─", inner -| cellCount(label), r.dim, r.panel);
                y += 1;
            }
            line += 1;
        }
        defer line += 1;
        if (line < top or y >= foot) continue;
        const picked = i == view.claudes_pick;
        const bg = if (picked) r.raised else r.panel;
        try bench.fill(w, rect.x + 1, y, inner + 2, bg);
        if (picked) try bench.say(w, rect.x + 1, y, "▌", r.accent, bg, true);
        if (i < given.now.len) try paintTicket(app, w, r, given.now[i], x0, y, inner, bg) else try paintOther(app, w, r, rest[i - given.now.len], x0, y, inner, bg);
        y += 1;
    }
    if (total == 0) try bench.say(w, x0, rect.y + 1, "no Claudes", r.dim, r.panel, false);
    try bench.say(w, x0, foot, " ⏎ pane   space card   H hand off   esc back ", r.dim, r.panel, false);
}
