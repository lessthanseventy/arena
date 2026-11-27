//! Text on the screen that the mouse can select and copy. A frame records the rows of a window as
//! it draws them; a drag picks cells of those rows, and the text is read back from the rows, not
//! from the terminal, so a line arena wrapped is one line again.

const std = @import("std");

pub const Point = struct { x: u16, y: u16 };

/// The text area of a window: a drag is clipped to it.
pub const Area = struct {
    x: u16,
    y: u16,
    w: u16,
    h: u16,

    pub fn contains(a: Area, p: Point) bool {
        return p.x >= a.x and p.x < a.x + a.w and p.y >= a.y and p.y < a.y + a.h;
    }

    pub fn clamp(a: Area, p: Point) Point {
        return .{
            .x = std.math.clamp(p.x, a.x, a.x + a.w -| 1),
            .y = std.math.clamp(p.y, a.y, a.y + a.h -| 1),
        };
    }
};

const max_panes = 8;

const Row = struct {
    pane: u8,
    x: u16,
    y: u16,
    at: u32,
    len: u32,
    /// Set when the row runs on from the one before it, which arena wrapped: the cells the wrap
    /// dropped between them.
    dropped: ?u8,
};

pub const Selection = struct { from: Point, to: Point };

pub const Grab = struct {
    rows: std.ArrayList(Row) = .empty,
    bytes: std.ArrayList(u8) = .empty,
    /// The windows this frame recorded, later ones over earlier; a row belongs to the one drawn
    /// last when it was recorded, `cur`.
    areas: [max_panes]Area = undefined,
    n_areas: u8 = 0,
    cur: u8 = 0,
    /// Set when the last window is a modal, drawn over everything else.
    modal: bool = false,
    /// The window `sel` is in: a drag stays in the one it began in.
    active: u8 = 0,
    sel: ?Selection = null,
    /// What `sel` read when it was picked, to tell a redraw that put other text under it.
    held: std.ArrayList(u8) = .empty,
    held_valid: bool = false,
    /// Where the button went down, until it is let go or becomes a drag.
    pressed: ?Point = null,
    dragging: bool = false,
    /// The last press: when, where, and how many in a row.
    click_at: i64 = 0,
    click_x: u16 = 0,
    click_y: u16 = 0,
    clicks: u8 = 0,

    pub fn deinit(g: *Grab, gpa: std.mem.Allocator) void {
        g.rows.deinit(gpa);
        g.bytes.deinit(gpa);
        g.held.deinit(gpa);
    }

    /// A frame starts: what the last one recorded is dropped.
    pub fn begin(g: *Grab) void {
        g.cover();
    }

    /// Something drawn over the windows that records no text: nothing under it is selectable.
    pub fn cover(g: *Grab) void {
        g.rows.clearRetainingCapacity();
        g.bytes.clearRetainingCapacity();
        g.n_areas = 0;
        g.modal = false;
    }

    /// The frame drew a window over all the others, whose text lies in `area`.
    pub fn window(g: *Grab, area: Area) void {
        g.cover();
        g.areas[0] = area;
        g.n_areas = 1;
        g.cur = 0;
        g.modal = true;
    }

    /// The frame drew one more window beside the others, whose text lies in `area`.
    pub fn pane(g: *Grab, area: Area) void {
        if (g.n_areas == max_panes) return;
        g.areas[g.n_areas] = area;
        g.cur = g.n_areas;
        g.n_areas += 1;
    }

    /// The window whose text lies under `p`, the one drawn over the rest.
    pub fn paneAt(g: *const Grab, p: Point) ?u8 {
        var at: u8 = g.n_areas;
        while (at > 0) {
            at -= 1;
            if (g.areas[at].contains(p)) return at;
        }
        return null;
    }

    /// Text a window drew at (`x`, `y`), kept when it is readable and lies in the window being
    /// recorded; a later draw on the same cell takes the place of an earlier one.
    pub fn note(g: *Grab, gpa: std.mem.Allocator, x: usize, y: usize, text: []const u8) !void {
        if (g.n_areas == 0 or !readable(text)) return;
        const area = g.areas[g.cur];
        if (x < area.x or y < area.y or y >= area.y + area.h or x >= area.x + area.w) return;
        const room = area.x + area.w - x;
        const shown = cellSlice(text, 0, room);
        const at: u16 = @intCast(x);
        const line: u16 = @intCast(y);
        var i = g.rows.items.len;
        while (i > 0 and (g.rows.items[i - 1].y > line or (g.rows.items[i - 1].y == line and g.rows.items[i - 1].x > at))) i -= 1;
        const entry: Row = .{ .pane = g.cur, .x = at, .y = line, .at = @intCast(g.bytes.items.len), .len = @intCast(shown.len), .dropped = null };
        if (i > 0 and g.rows.items[i - 1].y == line and g.rows.items[i - 1].x == at and g.rows.items[i - 1].pane == g.cur) {
            g.rows.items[i - 1] = entry;
        } else try g.rows.insert(gpa, i, entry);
        try g.bytes.appendSlice(gpa, shown);
    }

    /// The frame drew `text` from cell (`x`, `y`). `dropped` is set for a row that runs on from
    /// the one above, with the number of spaces the wrap took out between them.
    pub fn row(g: *Grab, gpa: std.mem.Allocator, x: u16, y: u16, line: []const u8, dropped: ?usize) !void {
        // a run-on row's indent is layout, not text: the copy joins it by the break's own spaces
        const text = if (dropped != null) std.mem.trimStart(u8, line, " ") else line;
        if (text.len == 0) return;
        try g.rows.append(gpa, .{
            .pane = g.cur,
            .x = x + @as(u16, @intCast(line.len - text.len)),
            .y = y,
            .at = @intCast(g.bytes.items.len),
            .len = @intCast(text.len),
            .dropped = if (dropped) |n| @intCast(@min(n, 255)) else null,
        });
        try g.bytes.appendSlice(gpa, text);
    }

    fn slice(g: *const Grab, r: Row) []const u8 {
        return g.bytes.items[r.at..][0..r.len];
    }

    fn rowAt(g: *const Grab, y: u16) ?usize {
        for (g.rows.items, 0..) |r, i| if (r.pane == g.active and r.y == y) return i;
        return null;
    }

    fn pieceAt(g: *const Grab, p: Point) ?usize {
        for (g.rows.items, 0..) |r, i| {
            if (r.pane == g.active and r.y == p.y and p.x >= r.x and p.x - r.x < cells(g.slice(r))) return i;
        }
        return null;
    }

    /// Where a press at `p` meant to select: its word, or its whole line. A word is what lies
    /// between spaces, so a path or a command's flag is one.
    pub fn word(g: *const Grab, p: Point) ?Selection {
        const r = g.rows.items[g.pieceAt(p) orelse return null];
        const row_text = g.slice(r);
        const n = cells(row_text);
        const at = p.x - r.x;
        if (cellAt(row_text, at) == ' ') return null;
        var from = at;
        while (from > 0 and cellAt(row_text, from - 1) != ' ') from -= 1;
        var to = at;
        while (to + 1 < n and cellAt(row_text, to + 1) != ' ') to += 1;
        return .{ .from = .{ .x = r.x + @as(u16, @intCast(from)), .y = r.y }, .to = .{ .x = r.x + @as(u16, @intCast(to)), .y = r.y } };
    }

    /// The line of the text `p` is on, with the rows arena wrapped it over.
    pub fn wholeLine(g: *const Grab, p: Point) ?Selection {
        var first = g.rowAt(p.y) orelse return null;
        var last = first;
        const mine = g.rows.items[first].pane;
        while (first > 0 and g.rows.items[first - 1].pane == mine and (g.rows.items[first - 1].y == g.rows.items[first].y or
            (g.rows.items[first].dropped != null and g.rows.items[first - 1].y + 1 == g.rows.items[first].y))) first -= 1;
        while (last + 1 < g.rows.items.len and g.rows.items[last + 1].pane == mine and (g.rows.items[last + 1].y == g.rows.items[last].y or
            (g.rows.items[last + 1].dropped != null and g.rows.items[last + 1].y == g.rows.items[last].y + 1))) last += 1;
        const a = g.rows.items[first];
        const b = g.rows.items[last];
        return .{
            .from = .{ .x = a.x, .y = a.y },
            .to = .{ .x = b.x + @as(u16, @intCast(cells(g.slice(b)) - 1)), .y = b.y },
        };
    }

    /// The text of `s`, in reading order: a row arena wrapped joins the one before it as it was
    /// written, and any other row starts a line. Owned by the caller.
    pub fn read(g: *const Grab, gpa: std.mem.Allocator, s: Selection) ![]u8 {
        const reading = order(s);
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(gpa);
        var seen = false;
        var line: u16 = 0;
        for (g.rows.items) |r| {
            if (r.pane != g.active or r.y < reading.from.y or r.y > reading.to.y) continue;
            const line_cells = cells(g.slice(r));
            const first: usize = if (r.y == reading.from.y and reading.from.x > r.x) reading.from.x - r.x else 0;
            const last: usize = if (r.y == reading.to.y) (if (reading.to.x < r.x) continue else @min(reading.to.x - r.x, line_cells - 1)) else line_cells - 1;
            if (first > last) continue;
            if (seen) {
                if (r.y == line) try out.append(gpa, ' ') else if (r.dropped) |n| try out.appendNTimes(gpa, ' ', n) else try out.append(gpa, '\n');
            }
            seen = true;
            line = r.y;
            try out.appendSlice(gpa, cellSlice(g.slice(r), first, last + 1));
        }
        return out.toOwnedSlice(gpa);
    }

    /// The cells of `s` that show, a row's span of each: the text to draw inverted.
    pub fn spans(g: *const Grab, s: Selection, at: usize) ?struct { x: u16, y: u16, text: []const u8 } {
        const reading = order(s);
        var n: usize = 0;
        for (g.rows.items) |r| {
            if (r.pane != g.active or r.y < reading.from.y or r.y > reading.to.y) continue;
            const line_cells = cells(g.slice(r));
            const first: usize = if (r.y == reading.from.y and reading.from.x > r.x) reading.from.x - r.x else 0;
            const last: usize = if (r.y == reading.to.y) (if (reading.to.x < r.x) continue else @min(reading.to.x - r.x, line_cells - 1)) else line_cells - 1;
            if (first > last) continue;
            if (n == at) return .{ .x = r.x + @as(u16, @intCast(first)), .y = r.y, .text = cellSlice(g.slice(r), first, last + 1) };
            n += 1;
        }
        return null;
    }

    /// A frame is drawn with `sel` picked: a drag keeps what it reads current, and a selection
    /// whose text is no longer what was picked (a scroll, a move of the pick, a board update)
    /// is dropped. Whether `sel` is still set.
    pub fn settle(g: *Grab, gpa: std.mem.Allocator) !bool {
        const s = g.sel orelse return false;
        if (g.n_areas == 0 or g.active >= g.n_areas) {
            g.sel = null;
            return false;
        }
        const now = try g.read(gpa, s);
        defer gpa.free(now);
        if (g.held_valid and !g.dragging and !std.mem.eql(u8, g.held.items, now)) {
            g.sel = null;
            g.held_valid = false;
            return false;
        }
        g.held.clearRetainingCapacity();
        try g.held.appendSlice(gpa, now);
        g.held_valid = true;
        return true;
    }

    /// Whether this press goes on the last one: the same cell, soon after. The count of presses
    /// in a row, from one.
    pub fn press(g: *Grab, now: i64, p: Point) u8 {
        const again = g.clicks > 0 and now - g.click_at < 500 and p.x == g.click_x and p.y == g.click_y;
        g.clicks = if (again) @min(g.clicks + 1, 3) else 1;
        g.click_at = now;
        g.click_x = p.x;
        g.click_y = p.y;
        return g.clicks;
    }
};

/// Whether `text` says something: a letter or digit, not a bar, a rule or an icon.
fn readable(text: []const u8) bool {
    var it = std.unicode.Utf8View.initUnchecked(text).iterator();
    while (it.nextCodepoint()) |c| {
        if (c < 0x80) {
            if (std.ascii.isAlphanumeric(@intCast(c))) return true;
        } else if ((c >= 0xC0 and c < 0x2000) or (c >= 0x3000 and c < 0xE000)) return true;
    }
    return false;
}

fn order(s: Selection) Selection {
    const swap = s.to.y < s.from.y or (s.to.y == s.from.y and s.to.x < s.from.x);
    return if (swap) .{ .from = s.to, .to = s.from } else s;
}

/// The cells `text` takes, a character a cell.
fn cells(text: []const u8) usize {
    return std.unicode.utf8CountCodepoints(text) catch text.len;
}

fn cellAt(text: []const u8, n: usize) u21 {
    var it = std.unicode.Utf8View.initUnchecked(text).iterator();
    var i: usize = 0;
    while (it.nextCodepoint()) |c| : (i += 1) if (i == n) return c;
    return ' ';
}

/// Cells `from` up to `to` of `text`.
fn cellSlice(text: []const u8, from: usize, to: usize) []const u8 {
    var it = std.unicode.Utf8View.initUnchecked(text).iterator();
    var i: usize = 0;
    var start: usize = text.len;
    var end: usize = text.len;
    while (true) : (i += 1) {
        if (i == from) start = it.i;
        if (i == to) {
            end = it.i;
            break;
        }
        _ = it.nextCodepointSlice() orelse break;
    }
    return text[start..end];
}

test "a selection across a wrapped line reads back as the line, and a new line where the text had one" {
    const gpa = std.testing.allocator;
    var g: Grab = .{};
    defer g.deinit(gpa);
    g.begin();
    g.window(.{ .x = 2, .y = 1, .w = 10, .h = 4 });
    try g.row(gpa, 2, 1, "run systemct", null);
    try g.row(gpa, 2, 2, "l --user show", 0);
    try g.row(gpa, 2, 3, "then", 1);
    try g.row(gpa, 2, 4, "next line", null);
    const all = try g.read(gpa, .{ .from = .{ .x = 2, .y = 1 }, .to = .{ .x = 11, .y = 4 } });
    defer gpa.free(all);
    try std.testing.expectEqualStrings("run systemctl --user show then\nnext line", all);

    const part = try g.read(gpa, .{ .from = .{ .x = 6, .y = 1 }, .to = .{ .x = 4, .y = 2 } });
    defer gpa.free(part);
    try std.testing.expectEqualStrings("systemctl -", part);
}

test "a drag is clipped to the window, and double and triple clicks pick a word and a line" {
    const gpa = std.testing.allocator;
    var g: Grab = .{};
    defer g.deinit(gpa);
    g.begin();
    const area: Area = .{ .x = 2, .y = 1, .w = 10, .h = 3 };
    g.window(area);
    try g.row(gpa, 2, 1, "see /a/b-c now", null);
    try g.row(gpa, 2, 2, "x", 0);
    try std.testing.expectEqual(Point{ .x = 11, .y = 3 }, area.clamp(.{ .x = 50, .y = 40 }));
    try std.testing.expectEqual(Point{ .x = 2, .y = 1 }, area.clamp(.{ .x = 0, .y = 0 }));

    const w = g.word(.{ .x = 8, .y = 1 }).?;
    const text = try g.read(gpa, w);
    defer gpa.free(text);
    try std.testing.expectEqualStrings("/a/b-c", text);
    try std.testing.expect(g.word(.{ .x = 5, .y = 1 }) == null);

    const l = g.wholeLine(.{ .x = 3, .y = 2 }).?;
    const whole = try g.read(gpa, l);
    defer gpa.free(whole);
    try std.testing.expectEqualStrings("see /a/b-c nowx", whole);
}

test "presses on one cell soon after each other count up to three" {
    var g: Grab = .{};
    const p: Point = .{ .x = 4, .y = 4 };
    try std.testing.expectEqual(@as(u8, 1), g.press(1000, p));
    try std.testing.expectEqual(@as(u8, 2), g.press(1200, p));
    try std.testing.expectEqual(@as(u8, 3), g.press(1300, p));
    try std.testing.expectEqual(@as(u8, 3), g.press(1400, p));
    try std.testing.expectEqual(@as(u8, 1), g.press(2500, p));
    try std.testing.expectEqual(@as(u8, 1), g.press(2600, .{ .x = 5, .y = 4 }));
}
