const std = @import("std");
const vt = @import("ghostty-vt");
const layout = @import("layout.zig");
const menu = @import("menu.zig");
const color = @import("color.zig");
const theme = @import("theme.zig");
const app_mod = @import("app.zig");
const App = app_mod.App;
const Session = app_mod.Session;
const Window = app_mod.Window;
const Writer = std.Io.Writer;

pub const What = enum { all, focused_border };

const Pen = struct {
    style: vt.Style = .{},
    dimmed: bool = false,
    fresh: bool = true,

    /// `dim` is the palette to dim against, for an unfocused window's cells. The terminal's own
    /// faint is not used for that: one keeping a minimum contrast repaints faint colours white.
    fn set(pen: *Pen, w: *Writer, given: vt.Style, dim: ?*const color.Palette) !void {
        if (!pen.fresh and pen.dimmed == (dim != null) and @as(u128, @bitCast(pen.style)) == @as(u128, @bitCast(given))) return;
        pen.* = .{ .style = given, .dimmed = dim != null, .fresh = false };
        var style = given;
        if (dim) |palette| {
            var fg = resolve(palette, style.fg_color) orelse palette.fg;
            var bg = resolve(palette, style.bg_color);
            if (style.flags.inverse) {
                const was = fg;
                fg = bg orelse palette.bg;
                bg = was;
                style.flags.inverse = false;
            }
            if (bg) |c| bg = color.dimBg(c, palette.bg);
            fg = color.dimFg(fg, bg orelse palette.bg);
            style.fg_color = .rgb(.{ .r = fg.r, .g = fg.g, .b = fg.b });
            style.bg_color = if (bg) |c| .rgb(.{ .r = c.r, .g = c.g, .b = c.b }) else .none;
        }
        try w.writeAll("\x1b[0");
        if (style.flags.bold) try w.writeAll(";1");
        if (style.flags.faint) try w.writeAll(";2");
        if (style.flags.italic) try w.writeAll(";3");
        if (style.flags.underline != .none) try w.writeAll(";4");
        if (style.flags.inverse) try w.writeAll(";7");
        if (style.flags.strikethrough) try w.writeAll(";9");
        try sgrColor(w, 38, style.fg_color);
        try sgrColor(w, 48, style.bg_color);
        try w.writeAll("m");
    }

    fn resolve(palette: *const color.Palette, c: vt.Style.Color) ?color.RGB {
        return switch (c.value()) {
            .none => null,
            .palette => |idx| palette.colors[idx],
            .rgb => |rgb| .{ .r = rgb.r, .g = rgb.g, .b = rgb.b },
        };
    }

    /// Palette colours stay palette indices, so the outer terminal's theme shows through.
    fn sgrColor(w: *Writer, base: u8, c: vt.Style.Color) !void {
        switch (c.value()) {
            .none => {},
            .palette => |idx| try w.print(";{d};5;{d}", .{ base, idx }),
            .rgb => |rgb| try w.print(";{d};2;{d};{d};{d}", .{ base, rgb.r, rgb.g, rgb.b }),
        }
    }
};

fn put(w: *Writer, cp: u21) !void {
    var buf: [4]u8 = undefined;
    const n = std.unicode.utf8Encode(cp, &buf) catch return w.writeAll(" ");
    try w.writeAll(buf[0..n]);
}

fn rgbStyle(c: color.RGB) vt.Style {
    return .{ .fg_color = .rgb(.{ .r = c.r, .g = c.g, .b = c.b }) };
}

/// A foreground from the machine palette, or an ANSI colour when there is none to read.
fn ink(app: *const App, comptime name: []const u8, fallback: u8) vt.Style {
    return if (app.theme) |t| rgbStyle(@field(t, name)) else .{ .fg_color = .palette(fallback) };
}

/// Bold ink on amber: the focused title, the current session, the selected menu item.
fn chip(app: *const App) vt.Style {
    var style: vt.Style = .{};
    style.flags.bold = true;
    if (app.theme) |t| {
        style.fg_color = .rgb(.{ .r = t.ink.r, .g = t.ink.g, .b = t.ink.b });
        style.bg_color = .rgb(.{ .r = t.amber.r, .g = t.amber.g, .b = t.amber.b });
    } else {
        style.fg_color = .palette(4);
        style.flags.inverse = true;
    }
    return style;
}

const Column = struct {
    app: *const App,
    session: *const Session,
    w: u16,
    focused: bool,
    title: []const u21,

    /// The border cell at (`cx`, `y`) of the column: the frame, the title in its top edge, and
    /// in the focused column's bottom edge a dot per window, the filled one being this one.
    fn border(col: Column, pen: *Pen, w: *Writer, cx: usize, y: u16) !void {
        const app = col.app;
        const h = app.view_h;
        const top = y == 0;
        const bottom = y == h - 1;

        if (top and cx >= 2 and cx - 2 < col.title.len) {
            try pen.set(w, if (col.focused) chip(app) else ink(app, "dim", 8), null);
            return put(w, col.title[cx - 2]);
        }

        const count = col.session.wins.items.len;
        if (bottom and col.focused and layout.inDots(col.w, count, cx)) {
            const dot = layout.dotAt(col.w, count, cx);
            const here = dot == col.session.focus;
            try pen.set(w, if (here) ink(app, "amber", 4) else ink(app, "dim", 8), null);
            return put(w, if (dot == null) ' ' else if (here) '●' else '○');
        }

        const style: vt.Style = if (app.theme) |t| rgbStyle(theme.gradient(
            if (col.focused) t.amber else t.amberdim,
            if (col.focused) t.violet else t.emberdim,
            theme.around(col.w, h, cx, y),
            if (col.focused) app.phase else 0,
        )) else .{ .fg_color = .palette(if (col.focused) 4 else 8) };
        try pen.set(w, style, null);
        const left = cx == 0;
        const right = cx == col.w - 1;
        try put(w, if (top) (if (left) '╭' else if (right) '╮' else '─') else if (bottom) (if (left) '╰' else if (right) '╯' else '─') else '│');
    }
};

/// The sessions, one to a row down the left edge under the menu button, the current one a chip.
fn rail(app: *const App, w: *Writer) !void {
    const width = app.railW();
    if (width == 0) return;
    var pen: Pen = .{};
    try w.writeAll("\x1b[1;1H");
    try pen.set(w, ink(app, "dim", 8), null);
    try w.writeAll(" " ++ app_mod.rail_button);
    for (app.sessions.items, 0..) |s, i| {
        if (i + 2 >= app.view_h) break;
        try w.print("\x1b[{d};1H", .{i + 2});
        try pen.set(w, if (s.id == app.current) chip(app) else ink(app, "dim", 8), null);
        try w.writeAll(" ");
        var cells: usize = 1;
        var name = std.unicode.Utf8View.initUnchecked(s.name).iterator();
        while (name.nextCodepoint()) |cp| : (cells += 1) {
            if (cells + 1 >= width) break;
            try put(w, cp);
        }
        while (cells < width) : (cells += 1) try w.writeAll(" ");
    }
}

/// The open menu, a box over the middle of the strip: an item a row, its key at the right, the
/// selected one a chip.
fn menuBox(app: *const App, w: *Writer, open: menu.Menu) !void {
    const box = app.menuBox(open);
    const edge = ink(app, "amber", 4);
    var title_buf: [menu.width]u8 = undefined;
    const closing = if (app.cur()) |s| s.focused() else null;
    const title: []const u8 = if (open.items.ptr == &menu.confirm and closing != null)
        std.fmt.bufPrint(&title_buf, " Close {s}? ", .{closing.?.name}) catch " Close? "
    else
        " arena ";
    const title_cells = std.unicode.utf8CountCodepoints(title) catch title.len;
    var pen: Pen = .{};

    try w.print("\x1b[{d};{d}H", .{ box.y + 1, box.x + 1 });
    try pen.set(w, edge, null);
    try w.writeAll("╭─");
    try w.writeAll(title);
    for (0..menu.width -| (3 + title_cells)) |_| try w.writeAll("─");
    try w.writeAll("╮");
    for (open.items, 0..) |item, i| {
        try w.print("\x1b[{d};{d}H", .{ box.y + 2 + i, box.x + 1 });
        try pen.set(w, edge, null);
        try w.writeAll("│");
        try pen.set(w, if (i == open.selected) chip(app) else .{}, null);
        try w.print(" {s}", .{item.label});
        for (0..menu.width - 5 - item.label.len) |_| try w.writeAll(" ");
        try w.print("{c} ", .{item.key});
        try pen.set(w, edge, null);
        try w.writeAll("│");
    }
    try w.print("\x1b[{d};{d}H", .{ box.y + 2 + open.items.len, box.x + 1 });
    try w.writeAll("╰");
    for (0..menu.width - 2) |_| try w.writeAll("─");
    try w.writeAll("╯");
}

const Cursor = struct { x: i32, y: i32 };

/// One cell of a window's inside, at (`tx`, `ty`) from its top left: a pane's cell, the line
/// between panes, or nothing where tmux has the window smaller than its column. `clip_lo` and
/// `clip_hi` say whether a neighbouring cell on that side is drawn, for a wide character's halves.
fn cell(app: *const App, pen: *Pen, w: *Writer, win: *const Window, tx: usize, ty: usize, focused: bool, clip_lo: bool, clip_hi: bool) !void {
    const dim: ?*const color.Palette = if (focused) null else &app.palette;
    const pane = win.paneAt(tx, ty) orelse {
        if (tx >= win.w or ty >= win.h) {
            try pen.set(w, .{}, null);
            return w.writeAll(" ");
        }
        const active = if (win.activePane()) |a|
            tx + 1 >= a.x and tx <= a.x + a.term.cols and ty + 1 >= a.y and ty <= a.y + a.term.rows
        else
            false;
        try pen.set(w, if (active and focused) ink(app, "amber", 4) else ink(app, "amberdim", 8), dim);
        const upright = (ty > 0 and win.paneAt(tx, ty - 1) == null) or (ty + 1 < win.h and win.paneAt(tx, ty + 1) == null);
        return put(w, if (upright) '│' else '─');
    };
    const px = tx - pane.x;
    const py = ty - pane.y;
    const rows = pane.render.row_data.items(.cells)[pane.render.viewportStart()..];
    if (py >= rows.len or px >= rows[py].len) {
        try pen.set(w, .{}, null);
        return w.writeAll(" ");
    }
    const row = rows[py];
    const raw = row.items(.raw)[px];
    var style: vt.Style = if (raw.style_id != 0) row.items(.style)[px] else .{};
    switch (raw.content_tag) {
        .bg_color_palette => style.bg_color = .palette(raw.content.color_palette.data),
        .bg_color_rgb => style.bg_color = .rgb(.{ .r = raw.content.color_rgb.r, .g = raw.content.color_rgb.g, .b = raw.content.color_rgb.b }),
        else => {},
    }
    try pen.set(w, style, dim);
    // Half of a wide character at a clipped edge is drawn as a space.
    const whole = switch (raw.wide) {
        .wide => !clip_hi,
        .spacer_tail => !clip_lo,
        else => true,
    };
    if (raw.wide == .spacer_tail and whole) return;
    if (!whole or !raw.hasText()) return w.writeAll(" ");
    try put(w, raw.content.codepoint.data);
    if (raw.content_tag == .codepoint_grapheme) {
        for (row.items(.grapheme)[px]) |cp| try put(w, cp);
    }
}

/// A session's windows as columns, the whole strip moved down by `yoff` rows. Returns where the
/// focused pane's cursor is, when it shows.
fn strip(app: *App, w: *Writer, s: *const Session, yoff: i32, what: What) !?Cursor {
    const ox = app.term_w - app.view_w;
    const col_w = app.colW(s);
    var cursor: ?Cursor = null;

    for (s.wins.items, 0..) |win, i| {
        const focused = i == s.focus;
        if (what == .focused_border and !focused) continue;
        const x0 = layout.colX(col_w, i) - s.scroll;
        const x1 = x0 + col_w - 1;
        const lo: i32 = @max(x0, 0);
        const hi: i32 = @min(x1 + 1, app.view_w);
        if (lo >= hi) continue;
        for (win.panes.items) |pane| try pane.render.update(app.gpa, &pane.term);

        var title_buf: [64]u8 = undefined;
        const title = std.fmt.bufPrint(&title_buf, " {d} {s} ", .{ i + 1, win.name }) catch title_buf[0..0];
        var title_cps: [64]u21 = undefined;
        var title_len: usize = 0;
        var view = std.unicode.Utf8View.initUnchecked(title).iterator();
        while (view.nextCodepoint()) |cp| : (title_len += 1) title_cps[title_len] = cp;
        if (title_len + 4 > col_w) title_len = 0;
        const col: Column = .{ .app = app, .session = s, .w = col_w, .focused = focused, .title = title_cps[0..title_len] };

        var pen: Pen = .{};
        var y: u16 = 0;
        while (y < app.view_h) : (y += 1) {
            const sy = y + yoff;
            if (sy < 0 or sy >= app.view_h) continue;
            if (y == 0 or y == app.view_h - 1) {
                try w.print("\x1b[{d};{d}H", .{ sy + 1, ox + lo + 1 });
                var sx = lo;
                while (sx < hi) : (sx += 1) try col.border(&pen, w, @intCast(sx - x0), y);
                continue;
            }
            if (x0 >= 0) {
                try w.print("\x1b[{d};{d}H", .{ sy + 1, ox + x0 + 1 });
                try col.border(&pen, w, 0, y);
            }
            if (x1 < app.view_w) {
                try w.print("\x1b[{d};{d}H", .{ sy + 1, ox + x1 + 1 });
                try col.border(&pen, w, col_w - 1, y);
            }
            if (what == .focused_border) continue;

            const in_lo: i32 = @max(lo, x0 + 1);
            const in_hi: i32 = @min(hi, x1);
            if (in_lo >= in_hi) continue;
            try w.print("\x1b[{d};{d}H", .{ sy + 1, ox + in_lo + 1 });
            var sx = in_lo;
            while (sx < in_hi) : (sx += 1) {
                try cell(app, &pen, w, win, @intCast(sx - x0 - 1), y - 1, focused, sx == in_lo, sx + 1 == in_hi);
            }
        }

        if (!focused or yoff != 0) continue;
        const pane = win.activePane() orelse continue;
        if (!pane.render.cursor.visible) continue;
        const at = pane.render.cursor.viewport orelse continue;
        const sx = x0 + 1 + pane.x + at.x;
        if (sx >= lo and sx < hi) cursor = .{ .x = ox + sx, .y = 1 + pane.y + at.y };
    }
    return cursor;
}

/// One frame: the rail, the current session's strip (and, mid-slide, the one being left), the
/// menu when open, and the cursor.
pub fn frame(app: *App, w: *Writer, what: What) !void {
    try w.writeAll("\x1b[?2026h\x1b[?25l\x1b[0m");
    if (what == .all) {
        try w.writeAll("\x1b[2J");
        try rail(app, w);
    }
    if (app.yoff != 0) if (app.sessionById(app.prev)) |leaving| {
        const way: i32 = if (app.yoff > 0) 1 else -1;
        _ = try strip(app, w, leaving, app.yoff - way * @as(i32, app.view_h), .all);
    };
    var cursor: ?Cursor = if (app.cur()) |s| try strip(app, w, s, app.yoff, what) else null;
    if (app.menu) |open| {
        try menuBox(app, w, open);
        cursor = null;
    }
    try w.writeAll("\x1b[0m");
    if (cursor) |at| try w.print("\x1b[{d};{d}H\x1b[?25h", .{ at.y + 1, at.x + 1 });
    try w.writeAll("\x1b[?2026l");
}
