//! The drawer's foot: the orchestrator's suggestions, between its chat and its prompt. A line it
//! suggests saying is typed into the prompt unsent when picked, as many as the human likes, each
//! on its own line; an item it points at opens in Your move.
const std = @import("std");
const keys = @import("keys.zig");
const tickets = @import("board.zig");
const app_mod = @import("app.zig");
const draw = @import("draw.zig");
const App = app_mod.App;
const Writer = std.Io.Writer;
const cellCount = draw.cellCount;
const clip = draw.clip;

/// The rows the foot never takes from the chat above it.
const keep_chat = 6;

/// One row of the foot: a need, and when it is one of Your move's, its place there.
pub const Row = struct { need: tickets.Need, at: ?usize = null };

/// The foot's `i`th row: the items the orchestrator points at, then the lines it suggests saying.
pub fn row(app: *const App, i: usize) ?Row {
    const b = if (app.board) |*b| b else return null;
    var n: usize = 0;
    for (b.needsYou(), 0..) |need, at| if (need.orch) {
        if (n == i) return .{ .need = need, .at = at };
        n += 1;
    };
    const said = b.said();
    return if (i - n < said.len) .{ .need = said[i - n] } else null;
}

/// How many rows the foot has, at most `board.said_max`.
pub fn count(app: *const App) usize {
    var n: usize = 0;
    while (n < tickets.said_max and row(app, n) != null) n += 1;
    return n;
}

/// The rows the foot takes in the column of `height` rows whose chat starts at `top`: none while
/// the orchestrator is off, and never so many that the chat has less than `keep_chat`.
pub fn height(app: *const App, top: u16) u16 {
    if (app.orchestratorWindow() == null) return 0;
    const room = app.view_h -| 1 -| top -| keep_chat;
    return @intCast(@min(count(app), room));
}

/// The rows drawn now: none unless the orchestrator's column is beside the board with its window.
pub fn shown(app: *const App) usize {
    const s = app.cur() orelse return 0;
    if (!s.orchestrator() or !app.sided()) return 0;
    return height(app, app.winTop(s, 0));
}

fn mark(id: []const u8) u64 {
    return std.hash.Wyhash.hash(0, id);
}

/// Whether the line `id` is already in the prompt.
pub fn taken(app: *const App, id: []const u8) bool {
    const h = mark(id);
    for (app.foot_taken) |t| if (t == h) return true;
    return false;
}

/// Whether any line of the foot now is in the prompt.
fn anyTaken(app: *const App) bool {
    var i: usize = 0;
    while (row(app, i)) |r| : (i += 1) if (r.at == null and taken(app, r.need.id)) return true;
    return false;
}

/// Row `i` picked: a line is typed into the orchestrator's prompt unsent, after the lines already
/// picked, on a line of its own; an item opens in Your move. A line picked twice is typed twice:
/// arena cannot see the prompt, so it cannot know the first was deleted.
pub fn pick(app: *App, i: usize) !void {
    const r = row(app, i) orelse return;
    if (r.at) |at| {
        if (r.need.ticket) |id| _ = try app.openDetail(id) else try app.openItem(at);
        return;
    }
    const win = app.orchestratorWindow() orelse return;
    if (win.panes.items.len == 0) return;
    // a working orchestrator has been sent what was typed, so the prompt is empty again
    if (app.orchestratorState() == .working) app.foot_taken = @splat(0);
    const pane = win.panes.items[0].id;
    if (anyTaken(app)) try app.send(.ignore, "send-keys -t %{d} M-Enter", .{pane});
    var buf: [1024]u8 = undefined;
    var w: Writer = .fixed(&buf);
    for (r.need.text) |c| {
        if (c == '\'') try w.writeAll("'\\''") else try w.writeByte(c);
    }
    try app.send(.ignore, "send-keys -t %{d} -l -- '{s}'", .{ pane, w.buffered() });
    app.foot_taken[app.foot_next] = mark(r.need.id);
    app.foot_next = (app.foot_next + 1) % app.foot_taken.len;
    try app.openDrawer();
}

/// A key while the drawer is in normal mode: `1` to `6` pick that row, `⏎` the first line not yet
/// picked. Whether the key was the foot's.
pub fn press(app: *App, key: []const u8) !bool {
    if (key.len != 1) return false;
    const visible = shown(app);
    if (key[0] >= '1' and key[0] <= '9') {
        const i = key[0] - '1';
        if (i >= visible) return false;
        try pick(app, i);
        return true;
    }
    if (key[0] != '\r') return false;
    var i: usize = 0;
    while (i < visible) : (i += 1) if (row(app, i)) |r| if (r.at == null and !taken(app, r.need.id)) {
        try pick(app, i);
        return true;
    };
    return false;
}

/// A click on a row of the foot. Whether it was one.
pub fn click(app: *App, m: keys.Mouse) !bool {
    const n: u16 = @intCast(shown(app));
    if (n == 0) return false;
    const left = app.term_w - app.view_w;
    if (m.x < left + 1 or m.x + 1 >= app.term_w) return false;
    const first = app.view_h - 1 - n;
    if (m.y < first or m.y >= app.view_h - 1) return false;
    try pick(app, m.y - first);
    return true;
}

/// Row `i` of the foot, `inner` cells wide.
pub fn paint(app: *const App, w: *Writer, pen: *draw.Pen, i: usize, inner: u16) !void {
    const r = row(app, i) orelse return;
    if (inner < 8) return;
    const used = r.at == null and taken(app, r.need.id);
    const dim = draw.ink(app, "dim", 8);
    try pen.set(w, draw.onPanel(app, .{}), null);
    try w.writeAll(" ");
    try pen.set(w, draw.onPanel(app, if (used) dim else draw.ink(app, "amber", 4)), null);
    try w.writeAll(if (used) "✓" else "◆");
    var cells: usize = 2;
    var buf: [32]u8 = undefined;
    const lead = if (r.at != null) "orch " else std.fmt.bufPrint(&buf, "{d} ", .{i + 1}) catch "";
    try pen.set(w, draw.onPanel(app, dim), null);
    try w.writeAll(" ");
    try w.writeAll(lead);
    cells += 1 + cellCount(lead);
    try pen.set(w, draw.onPanel(app, if (used) dim else .{}), null);
    const text = clip(r.need.text, @as(usize, inner) -| cells);
    try w.writeAll(text);
    cells += cellCount(text);
    try pen.set(w, draw.onPanel(app, .{}), null);
    for (@min(cells, inner)..inner) |_| try w.writeAll(" ");
}
