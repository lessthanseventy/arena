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
    /// A window held by its title would take this one's place.
    drop: bool = false,
    title: []const u21,
    /// The cell of the title that is the window's mark, drawn in amber.
    mark_at: ?usize = null,

    /// The border cell at (`cx`, `y`) of the column: the frame, the title in its top edge, and
    /// in the focused column's bottom edge a dot per window, the filled one being this one and
    /// any other with something to say showing its mark.
    fn border(col: Column, pen: *Pen, w: *Writer, cx: usize, y: u16) !void {
        const app = col.app;
        const h = app.view_h;
        const top = y == 0;
        const bottom = y == h - 1;

        if (top and cx >= 2 and cx - 2 < col.title.len) {
            const marked = col.mark_at == cx - 2;
            try pen.set(w, if (col.focused or col.drop) chip(app) else if (marked) ink(app, "amber", 4) else ink(app, "dim", 8), null);
            return put(w, col.title[cx - 2]);
        }

        const count = col.session.wins.items.len;
        if (bottom and col.focused and layout.inDots(col.w, count, cx)) {
            const dot = layout.dotAt(col.w, count, cx) orelse {
                try pen.set(w, .{}, null);
                return put(w, ' ');
            };
            const here = dot == col.session.focus;
            const mark = app.mark(col.session, col.session.wins.items[dot]);
            try pen.set(w, if (here or mark != .none) ink(app, "amber", 4) else ink(app, "dim", 8), null);
            return put(w, if (here) '●' else if (mark != .none) glyph(mark) else '○');
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

const rail_title = " sessions ";

/// The session rail, a bordered panel down the left edge: a session a row with how many windows
/// it has, the current one a chip, and the menu button on its last row.
fn rail(app: *const App, w: *Writer) !void {
    const width = app.railW();
    if (width == 0) return;
    const h = app.view_h;
    const inner = width - 2;
    const dim = ink(app, "dim", 8);
    var pen: Pen = .{};
    var y: u16 = 0;
    while (y < h) : (y += 1) {
        try w.print("\x1b[{d};1H", .{y + 1});
        const top = y == 0;
        const bottom = y == h - 1;
        const ruled = y == app.railRuleRow() and !top;
        var x: u16 = 0;
        while (x < width) : (x += 1) {
            if (!top and !bottom and !ruled and x == 1) {
                try railRow(app, w, &pen, y, inner);
                x = width - 2;
                continue;
            }
            if (top and x >= 2 and x - 2 < rail_title.len) {
                try pen.set(w, dim, null);
                try w.writeByte(rail_title[x - 2]);
                continue;
            }
            const edge: vt.Style = if (app.theme) |t|
                rgbStyle(theme.gradient(t.amberdim, t.emberdim, theme.around(width, h, x, y), 0))
            else
                .{ .fg_color = .palette(8) };
            try pen.set(w, edge, null);
            const left = x == 0;
            const right = x == width - 1;
            try put(w, if (top)
                (if (left) '╭' else if (right) '╮' else '─')
            else if (bottom)
                (if (left) '╰' else if (right) '╯' else '─')
            else if (ruled)
                (if (left) '├' else if (right) '┤' else '─')
            else
                '│');
        }
    }
}

/// The `inner` cells of the rail's row `y` between its borders.
fn railRow(app: *const App, w: *Writer, pen: *Pen, y: u16, inner: u16) !void {
    const dim = ink(app, "dim", 8);
    var filled: usize = 0;
    const index: usize = y -| 2;
    if (y == app.railMenuRow()) {
        try pen.set(w, dim, null);
        try w.writeAll(" " ++ app_mod.rail_button);
        filled = 1 + cellCount(app_mod.rail_button);
    } else if (y == app.railNewRow()) {
        try pen.set(w, dim, null);
        try w.writeAll(" " ++ app_mod.rail_new);
        filled = 1 + cellCount(app_mod.rail_new);
    } else if (y >= 2 and index < app.railShown()) {
        const s = app.sessions.items[index];
        const drop = app.dropAt();
        // lit as the current one is: a window held by its title would go to it
        const here = s.id == app.current or (drop == .session and drop.session == index);
        const cut = cellCount(s.name) > inner - 6;
        const name = clip(s.name, inner - 6 - @intFromBool(cut));
        try pen.set(w, if (here) chip(app) else .{}, null);
        try w.writeAll(" ");
        try w.writeAll(name);
        if (cut) try w.writeAll("…");
        for (0..inner - 5 - cellCount(name) - @intFromBool(cut)) |_| try w.writeAll(" ");
        try pen.set(w, if (here) chip(app) else ink(app, "amber", 4), null);
        try put(w, glyph(App.sessionMark(s)));
        try pen.set(w, if (here) chip(app) else dim, null);
        try w.print("{d:>2} ", .{@min(s.wins.items.len, 99)});
        filled = inner;
    } else try pen.set(w, .{}, null);
    for (filled..inner) |_| try w.writeAll(" ");
}

fn glyph(mark: app_mod.Mark) u21 {
    return switch (mark) {
        .none => ' ',
        .working => '◌',
        .done => '◉',
        .waiting => '▲',
    };
}

fn cellCount(text: []const u8) usize {
    return std.unicode.utf8CountCodepoints(text) catch text.len;
}

/// The first `max` characters of `text`.
fn clip(text: []const u8, max: usize) []const u8 {
    var it = std.unicode.Utf8View.initUnchecked(text).iterator();
    var n: usize = 0;
    while (n < max) : (n += 1) _ = it.nextCodepointSlice() orelse break;
    return text[0..it.i];
}

/// A bordered box over the strip, drawn a row at a time from the top.
const Box = struct {
    app: *const App,
    w: *Writer,
    x: u16,
    y: u16,
    pen: Pen = .{},
    row: u16 = 0,

    /// False for a row the terminal is too short to show.
    fn begin(b: *Box) !bool {
        defer b.row += 1;
        if (b.y + b.row >= b.app.view_h) return false;
        try b.w.print("\x1b[{d};{d}H", .{ b.y + b.row + 1, b.x + 1 });
        try b.pen.set(b.w, ink(b.app, "amber", 4), null);
        return true;
    }

    fn edge(b: *Box, left: []const u8, right: []const u8) !void {
        if (!try b.begin()) return;
        try b.w.writeAll(left);
        for (0..menu.width - 2) |_| try b.w.writeAll("─");
        try b.w.writeAll(right);
    }

    /// A row of the inside, a cell clear of the border: `left` from its left end and `right`
    /// at its right end, each in its style, `left`'s filling the space between.
    fn line(b: *Box, left_style: vt.Style, left: []const u8, right_style: vt.Style, right: []const u8) !void {
        if (!try b.begin()) return;
        try b.w.writeAll("│");
        try b.pen.set(b.w, .{}, null);
        try b.w.writeAll(" ");
        try b.pen.set(b.w, left_style, null);
        try b.w.writeAll(left);
        for (0..(menu.width - 4) -| (cellCount(left) + cellCount(right))) |_| try b.w.writeAll(" ");
        try b.pen.set(b.w, right_style, null);
        try b.w.writeAll(right);
        try b.pen.set(b.w, .{}, null);
        try b.w.writeAll(" ");
        try b.pen.set(b.w, ink(b.app, "amber", 4), null);
        try b.w.writeAll("│");
    }

    fn blank(b: *Box) !void {
        try b.line(.{}, "", .{}, "");
    }
};

/// The line between a menu's groups.
const rule = blk: {
    var text: []const u8 = "  ";
    for (0..menu.width - 8) |_| text = text ++ "─";
    break :blk text;
};

fn heading(app: *const App) vt.Style {
    var style = ink(app, "amber", 4);
    style.flags.bold = true;
    return style;
}

/// The open menu: a heading, then an item a row with its icon and, at the right, its key, the
/// selected one a chip, and the keys that work the menu along the bottom.
fn menuBox(app: *const App, w: *Writer, open: menu.Menu) !void {
    const at = app.box(open.height());
    var b: Box = .{ .app = app, .w = w, .x = at.x, .y = at.y };
    const dim = ink(app, "dim", 8);
    const session = app.cur();
    const win = if (session) |s| s.focused() else null;
    var buf: [96]u8 = undefined;

    try b.edge("╭", "╮");
    try b.blank();
    if (open.items.ptr == &menu.confirm) {
        const name = clip(if (win) |found| found.name else "window", 20);
        try b.line(heading(app), std.fmt.bufPrint(&buf, "  Close {s}?", .{name}) catch "  Close?", dim, "");
    } else if (open.items.ptr == &menu.confirm_session) {
        const name = clip(if (app.sessionById(app.doomed)) |s| s.name else "", 12);
        try b.line(heading(app), std.fmt.bufPrint(&buf, "  Close session {s}?", .{name}) catch "  Close?", dim, "");
    } else {
        const name = clip(if (session) |s| s.name else "", 16);
        try b.line(heading(app), "  ◆ arena", dim, std.fmt.bufPrint(&buf, "{s}  ", .{name}) catch "");
    }
    try b.blank();
    for (open.items, 0..) |item, i| {
        if (item.group) try b.line(dim, rule, dim, "");
        const picked = i == open.selected;
        const left = std.fmt.bufPrint(&buf, "  {s}  {s}", .{ item.icon, item.label }) catch item.label;
        try b.line(if (picked) chip(app) else .{}, left, if (picked) chip(app) else dim, &.{ item.key, ' ', ' ' });
    }
    try b.blank();
    try b.line(dim, "  ↑↓ move   ⏎ pick   esc close", dim, "");
    try b.edge("╰", "╯");
}

/// The box a line is typed into: a new name, or part of a window's to jump to, with the windows
/// it matches listed under it. Returns where its cursor goes.
fn promptBox(app: *const App, w: *Writer, prompt: *const menu.Prompt) !Cursor {
    const at = app.box(prompt.height());
    var b: Box = .{ .app = app, .w = w, .x = at.x, .y = at.y };
    const dim = ink(app, "dim", 8);
    var buf: [96]u8 = undefined;
    const session = app.cur();
    const was: []const u8 = switch (prompt.what) {
        .window => if (session) |s| (if (s.focused()) |win| win.name else "") else "",
        .session => if (session) |s| s.name else "",
        .jump, .search => "",
    };

    try b.edge("╭", "╮");
    try b.blank();
    try b.line(
        heading(app),
        switch (prompt.what) {
            .window => "  ✎ Rename window",
            .session => "  ✎ Rename session",
            .jump => "  → Jump to window",
            .search => "  / Search history",
        },
        dim,
        std.fmt.bufPrint(&buf, "{s}  ", .{clip(was, 12)}) catch "",
    );
    try b.blank();
    const shown = clip(prompt.text(), menu.width - 10);
    try b.line(.{}, std.fmt.bufPrint(&buf, "  › {s}", .{shown}) catch "", .{}, "");
    try b.blank();
    if (prompt.what == .jump) {
        var hits: [menu.jump_rows]App.Hit = undefined;
        const n = app.jumpHits(prompt.text(), &hits);
        for (0..menu.jump_rows) |i| {
            if (i >= n) {
                try b.blank();
                continue;
            }
            const s = hits[i].session;
            const win = s.wins.items[hits[i].index];
            const style: vt.Style = if (i == prompt.selected) chip(app) else .{};
            const left = std.fmt.bufPrint(&buf, "  {s} › {s}", .{ clip(s.name, 12), clip(win.name, 14) }) catch "";
            var mark: [8]u8 = undefined;
            const mark_len = std.unicode.utf8Encode(glyph(app.mark(s, win)), &mark) catch 0;
            @memcpy(mark[mark_len..][0..2], "  ");
            try b.line(style, left, if (i == prompt.selected) style else ink(app, "amber", 4), mark[0 .. mark_len + 2]);
        }
        try b.blank();
        try b.line(dim, "  ↑↓ move   ⏎ go   esc close", dim, "");
    } else if (prompt.what == .search) {
        try b.line(dim, if (prompt.missed) "  no match" else "  ⏎ older match   esc close", dim, "");
    } else try b.line(dim, "  ⏎ rename   esc cancel", dim, "");
    try b.edge("╰", "╯");
    return .{ .x = at.x + 6 + @as(i32, @intCast(cellCount(shown))), .y = at.y + 4 };
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
    if (pane.render.row_data.items(.selection)[pane.render.viewportStart() + py]) |range| {
        if (px >= range[0] and px <= range[1]) style.flags.inverse = !style.flags.inverse;
    }
    // A kitty picture's cell names the picture by its colour, which dimming would change.
    const picture = raw.hasText() and raw.content.codepoint.data == 0x10EEEE;
    try pen.set(w, style, if (picture) null else dim);
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
    var cursor: ?Cursor = null;
    const drop = app.dropAt();

    for (s.wins.items, 0..) |win, i| {
        const focused = i == s.focus;
        if (what == .focused_border and !focused) continue;
        const col_w = app.colW(s, win);
        const x0 = app.colX(s, i) - s.scroll;
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
        const mark = app.mark(s, win);
        if (mark != .none and title_len + 2 <= title_cps.len) {
            title_cps[title_len] = glyph(mark);
            title_cps[title_len + 1] = ' ';
            title_len += 2;
        }
        if (title_len + 4 > col_w) title_len = 0;
        const col: Column = .{
            .app = app,
            .session = s,
            .w = col_w,
            .focused = focused,
            .drop = drop == .column and drop.column == i,
            .title = title_cps[0..title_len],
            .mark_at = if (mark != .none and title_len > 0) title_len - 2 else null,
        };

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

/// A window's picture in the overview, its top left corner at (`x`, `y`): a small frame with its
/// number and name, and inside it the top left of the window, from far enough down to show the
/// row its cursor is on.
fn thumb(app: *App, w: *Writer, s: *const Session, win: *const Window, number: usize, x: u16, y: u16, picked: bool) !void {
    for (win.panes.items) |pane| try pane.render.update(app.gpa, &pane.term);
    const tw = App.thumb_w;
    const th = App.thumb_h;
    const edge = if (picked) ink(app, "amber", 4) else ink(app, "amberdim", 8);
    const mark = app.mark(s, win);
    var buf: [64]u8 = undefined;
    const title = std.fmt.bufPrint(&buf, " {d} {s} ", .{ number + 1, clip(win.name, tw - 10) }) catch "";

    var off: usize = win.h -| (th - 2);
    if (win.activePane()) |pane| {
        if (pane.term.screens.active_key == .alternate) {
            off = 0;
        } else if (pane.render.cursor.viewport) |at| {
            off = @min(off, (pane.y + at.y + 1) -| (th - 2));
        }
    }

    var pen: Pen = .{};
    for (0..th) |row| {
        if (y + row >= app.view_h) break;
        try w.print("\x1b[{d};{d}H", .{ y + row + 1, x + 1 });
        try pen.set(w, edge, null);
        if (row == 0 or row == th - 1) {
            try w.writeAll(if (row == 0) "╭─" else "╰─");
            var used: usize = 2;
            if (row == 0) {
                try pen.set(w, if (picked) chip(app) else ink(app, "dim", 8), null);
                try w.writeAll(title);
                used += cellCount(title);
                if (mark != .none) {
                    try pen.set(w, ink(app, "amber", 4), null);
                    try put(w, glyph(mark));
                    used += 1;
                }
                try pen.set(w, edge, null);
            }
            for (used..tw - 1) |_| try w.writeAll("─");
            try w.writeAll(if (row == 0) "╮" else "╯");
            continue;
        }
        try w.writeAll("│");
        for (0..tw - 2) |tx| try cell(app, &pen, w, win, tx, row - 1 + off, picked, false, tx + 3 == tw);
        try pen.set(w, edge, null);
        try w.writeAll("│");
    }
}

/// Every session a row: its name, then a picture of each of its windows.
fn overview(app: *App, w: *Writer, spot: App.Spot) !void {
    const ox = app.term_w - app.view_w;
    // While a picture is held, what is lit is where it would go, not the one picked.
    const drop = app.overviewDrop();
    var pen: Pen = .{};
    for (app.sessions.items, 0..) |s, si| {
        const row = app.overviewRow(si) orelse continue;
        if (row >= app.view_h) continue;
        try w.print("\x1b[{d};{d}H", .{ row + 1, ox + 1 });
        const lit = if (drop) |to| to.session == si and to.win == null else si == spot.session;
        try pen.set(w, if (lit) chip(app) else if (s.id == app.current) heading(app) else .{}, null);
        try w.print(" {s} ", .{clip(s.name, 24)});
        try pen.set(w, ink(app, "amber", 4), null);
        try w.writeAll(" ");
        try put(w, glyph(App.sessionMark(s)));
        for (s.wins.items, 0..) |win, wi| {
            const at = app.thumbAt(.{ .session = si, .win = wi }) orelse continue;
            const picked = if (drop) |to| to.session == si and to.win == wi else si == spot.session and wi == spot.win;
            try thumb(app, w, s, win, wi, at.x, at.y, picked);
        }
    }
}

/// One frame: the rail, the current session's strip (and, mid-slide, the one being left) or the
/// overview in its place, the menu or prompt when open, and the cursor.
pub fn frame(app: *App, w: *Writer, what: What) !void {
    try w.writeAll("\x1b[?2026h\x1b[?25l\x1b[0m");
    if (what == .all) {
        // Not 2J: erasing the whole display takes the terminal's kitty pictures with it.
        try w.writeAll("\x1b[H\x1b[J");
        try rail(app, w);
    }
    var cursor: ?Cursor = null;
    if (app.overview) |spot| {
        try overview(app, w, spot);
    } else {
        if (app.yoff != 0) if (app.sessionById(app.prev)) |leaving| {
            const way: i32 = if (app.yoff > 0) 1 else -1;
            _ = try strip(app, w, leaving, app.yoff - way * @as(i32, app.view_h), .all);
        };
        if (app.cur()) |s| cursor = try strip(app, w, s, app.yoff, what);
    }
    if (app.prompt) |*prompt| {
        cursor = try promptBox(app, w, prompt);
    } else if (app.menu) |open| {
        try menuBox(app, w, open);
        cursor = null;
    }
    try w.writeAll("\x1b[0m");
    if (cursor) |at| try w.print("\x1b[{d};{d}H\x1b[?25h", .{ at.y + 1, at.x + 1 });
    try w.writeAll("\x1b[?2026l");
}
