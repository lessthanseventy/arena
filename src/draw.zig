const std = @import("std");
const vt = @import("ghostty-vt");
const layout = @import("layout.zig");
const menu = @import("menu.zig");
const color = @import("color.zig");
const theme = @import("theme.zig");
const bench = @import("parts.zig");
const app_mod = @import("app.zig");
const tickets = @import("board.zig");
const feed = @import("feed.zig");
const sheets = @import("plan.zig");
const goal_mod = @import("goal.zig");
const App = app_mod.App;
const Session = app_mod.Session;
const Window = app_mod.Window;
const Pane = app_mod.Pane;
const Writer = std.Io.Writer;

pub const What = enum { all, focused_border };

const Pen = struct {
    style: vt.Style = .{},
    dimmed: bool = false,
    fresh: bool = true,
    /// A style every cell is drawn in while set: the selected agent's rows.
    over: ?vt.Style = null,

    /// `dim` is the palette to dim against, for an unfocused window's cells. The terminal's own
    /// faint is not used for that: one keeping a minimum contrast repaints faint colours white.
    fn set(pen: *Pen, w: *Writer, drawn: vt.Style, dim: ?*const color.Palette) !void {
        const given = pen.over orelse drawn;
        if (!pen.fresh and pen.dimmed == (dim != null) and @as(u128, @bitCast(pen.style)) == @as(u128, @bitCast(given))) return;
        pen.* = .{ .style = given, .dimmed = dim != null, .fresh = false, .over = pen.over };
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
    w: u16,
    focused: bool,
    /// A window held by its title would take this one's place.
    drop: bool = false,
    title: []const u21,
    /// The cell of the title that is the window's mark, drawn in amber.
    mark_at: ?usize = null,
    /// Dim at the right end of its top edge.
    right: []const u21 = &.{},
    /// The cells of the title, from and up to, that are a button: raised off the bar.
    button: ?[2]usize = null,
    /// Drawn as Workbench's window: a title bar, a panel for sides and a well along the foot.
    roles: ?theme.Roles = null,

    fn benchBorder(col: Column, r: theme.Roles, pen: *Pen, w: *Writer, cx: usize, y: u16) !void {
        const app = col.app;
        const quiet = !col.focused;
        if (y == 0) {
            const face = if (quiet) r.tile else r.raised;
            const right_at = col.w -| 2 -| col.right.len;
            var style = paintStyle(r.text, face, false);
            var cp: u21 = ' ';
            if (cx >= 2 and cx - 2 < col.title.len) {
                cp = col.title[cx - 2];
                style = paintStyle(if (col.mark_at == cx - 2) r.accent else if (quiet) r.dim else r.text, face, true);
                if (col.button) |cells| if (cx - 2 >= cells[0] and cx - 2 < cells[1]) {
                    style = paintStyle(r.text, if (quiet) r.raised else r.tile, true);
                };
            } else if (cx >= right_at and cx < col.w -| 2) {
                cp = col.right[cx - right_at];
                style = paintStyle(r.dim, face, false);
            } else if (!quiet and cx > 2 + col.title.len and cx + 1 < right_at) {
                cp = '═';
                style = paintStyle(r.accent.mix(r.raised, 0.5), face, false);
            }
            try pen.set(w, style, null);
            return put(w, cp);
        }
        if (y == app.view_h - 1) {
            const hint = if (app.normal) "i insert" else "esc normal";
            const said = "❯ tell the orchestrator…";
            const right_at = col.w -| 2 -| cellCount(hint);
            var style = paintStyle(r.dim, r.well, false);
            var cp: u21 = ' ';
            if (cx >= 2 and cx - 2 < cellCount(said) and cx + 1 < right_at) {
                var it = std.unicode.Utf8View.initUnchecked(said).iterator();
                for (0..cx - 2) |_| _ = it.nextCodepoint();
                cp = it.nextCodepoint() orelse ' ';
                if (cx == 2) style = paintStyle(r.accent, r.well, true);
            } else if (cx >= right_at and cx < col.w -| 2) {
                var it = std.unicode.Utf8View.initUnchecked(hint).iterator();
                for (0..cx - right_at) |_| _ = it.nextCodepoint();
                cp = it.nextCodepoint() orelse ' ';
            }
            try pen.set(w, style, null);
            return put(w, cp);
        }
        try pen.set(w, paintStyle(r.text, r.panel, false), null);
        try put(w, ' ');
    }

    /// The border cell at (`cx`, `y`) of the column: the frame and the title in its top edge.
    fn border(col: Column, pen: *Pen, w: *Writer, cx: usize, y: u16) !void {
        const app = col.app;
        if (col.roles) |r| return col.benchBorder(r, pen, w, cx, y);
        const h = app.view_h;
        const top = y == 0;
        const bottom = y == h - 1;

        if (top and cx >= 2 and cx - 2 < col.title.len) {
            const marked = col.mark_at == cx - 2;
            const pressed = if (col.button) |cells| cx - 2 >= cells[0] and cx - 2 < cells[1] else false;
            try pen.set(w, if (pressed or col.focused or col.drop) chip(app) else if (marked) ink(app, "amber", 4) else ink(app, "dim", 8), null);
            return put(w, col.title[cx - 2]);
        }
        const right_at = col.w -| 2 -| col.right.len;
        if (top and cx >= right_at and cx < col.w -| 2) {
            try pen.set(w, ink(app, "dim", 8), null);
            return put(w, col.right[cx - right_at]);
        }

        // normal mode stops the focused column's gradient and dims it
        const turning = col.focused and !app.normal;
        const style: vt.Style = if (app.theme) |t| rgbStyle(theme.gradient(
            if (turning) t.amber else t.amberdim,
            if (turning) t.violet else t.emberdim,
            theme.around(col.w, h, cx, y),
            if (turning) app.phase else 0,
        )) else .{ .fg_color = .palette(if (turning) 4 else 8) };
        try pen.set(w, style, null);
        const left = cx == 0;
        const right = cx == col.w - 1;
        try put(w, if (top) (if (left) '╭' else if (right) '╮' else '─') else if (bottom) (if (left) '╰' else if (right) '╯' else '─') else '│');
    }
};

/// Under the strip, centred on it, a dot per window of the session: the filled one is the window
/// in view, and any other with something to say shows its mark.
fn dots(app: *const App, w: *Writer, s: *const Session) !void {
    const ox = app.term_w - app.view_w;
    var pen: Pen = .{};
    try w.print("\x1b[{d};{d}H", .{ app.view_h + 1, ox + 1 });
    try pen.set(w, .{}, null);
    for (0..app.view_w) |_| try w.writeAll(" ");
    try modeCorner(app, w, &pen);
    if (app.normal) return normalKeys(app, w, &pen);
    if (app.over_dots) if (try tabs(app, w, &pen, s)) return;
    const start = layout.dotsStart(app.view_w, s.wins.items.len) orelse return;
    for (s.wins.items, 0..) |win, i| {
        const here = i == s.focus;
        const mark = app.mark(s, win);
        try w.print("\x1b[{d};{d}H", .{ app.view_h + 1, ox + start + 2 * i + 2 });
        try pen.set(w, if (here or mark != .none) ink(app, "amber", 4) else ink(app, "dim", 8), null);
        try put(w, if (here) '●' else if (mark != .none) glyph(app, mark) else if (win.alert != .none) alertGlyph(win.alert) else '○');
    }
}

const normal_label = "NORMAL";
const normal_keys = "j k pick  ] [ next waiting  ⏎ go  b home  B board  i insert";

/// The first cell of a rail row: the pick's bar in the accent, else a space.
fn pickBar(app: *const App, w: *Writer, pen: *Pen, picked: bool, base: vt.Style) !void {
    try pen.set(w, if (picked) ink(app, "amber", 4) else base, null);
    try w.writeAll(if (picked) "▌" else " ");
    if (picked) try pen.set(w, base, null);
}

/// `NORMAL` in the accent at the bottom-left corner of the screen while in normal mode, and the
/// cells it takes blank otherwise.
fn modeCorner(app: *const App, w: *Writer, pen: *Pen) !void {
    const ox = app.term_w - app.view_w;
    try w.print("\x1b[{d};1H", .{app.view_h + 1});
    if (app.normal) {
        try pen.set(w, ink(app, "amber", 4), null);
        try w.writeAll(normal_label);
    } else {
        try pen.set(w, .{}, null);
        for (0..@min(normal_label.len, ox)) |_| try w.writeAll(" ");
    }
}

/// In normal mode the row of dots is the keys that can be pressed, written out.
fn normalKeys(app: *const App, w: *Writer, pen: *Pen) !void {
    var buf: [48]u8 = undefined;
    const typed = if (app.hash_len) |len| std.fmt.bufPrint(&buf, "open #{s}▏  ⏎ open  esc cancel", .{app.hash[0..len]}) catch normal_keys else normal_keys;
    try keysLine(app, w, pen, typed);
}

fn keysLine(app: *const App, w: *Writer, pen: *Pen, text: []const u8) !void {
    const ox = app.term_w - app.view_w;
    const start = (app.view_w -| cellCount(text)) / 2;
    try w.print("\x1b[{d};{d}H", .{ app.view_h + 1, ox + start + 1 });
    try pen.set(w, ink(app, "dim", 8), null);
    try w.writeAll(clip(text, app.view_w));
}

const type_hint = "Ctrl+Space / i to type";

/// The row under the overview and the board: no dots there, but the mode is shown all the same.
fn modeRow(app: *const App, w: *Writer) !void {
    const ox = app.term_w - app.view_w;
    var pen: Pen = .{};
    try w.print("\x1b[{d};{d}H", .{ app.view_h + 1, ox + 1 });
    try pen.set(w, .{}, null);
    for (0..app.view_w) |_| try w.writeAll(" ");
    try modeCorner(app, w, &pen);
    if (app.normal) try keysLine(app, w, &pen, type_hint);
}

/// With the pointer on the row of dots, each window's number and name in their place, the one in
/// view a chip and any other with something to say its mark. False when they do not fit.
fn tabs(app: *const App, w: *Writer, pen: *Pen, s: *const Session) !bool {
    var widths: [app_mod.max_tabs]usize = undefined;
    const all = App.tabWidths(s, &widths);
    var x = layout.tabsStart(app.view_w, all) orelse return false;
    const ox = app.term_w - app.view_w;
    for (s.wins.items, all, 0..) |win, width, i| {
        const here = i == s.focus;
        const mark = app.mark(s, win);
        try w.print("\x1b[{d};{d}H", .{ app.view_h + 1, ox + x + 1 });
        try pen.set(w, if (here) chip(app) else ink(app, "dim", 8), null);
        try w.print("{d} ", .{i + 1});
        try pen.set(w, if (here) chip(app) else .{}, null);
        try w.writeAll(clip(win.name, app_mod.tab_name));
        try w.writeAll(" ");
        try pen.set(w, if (here) chip(app) else ink(app, "amber", 4), null);
        try put(w, if (mark != .none) glyph(app, mark) else alertGlyph(win.alert));
        x += width + 2;
    }
    return true;
}

const rail_title = " sessions ";

/// How long ago `since` was, in its largest whole unit: 45s, 4m, 2h, 3d.
fn ago(buf: []u8, epoch: i64, since: u32) []const u8 {
    if (since == 0) return "";
    const s = @max(0, epoch - since);
    return (if (s < 60)
        std.fmt.bufPrint(buf, "{d}s", .{s})
    else if (s < 3600)
        std.fmt.bufPrint(buf, "{d}m", .{@divFloor(s, 60)})
    else if (s < 86400)
        std.fmt.bufPrint(buf, "{d}h", .{@divFloor(s, 3600)})
    else
        std.fmt.bufPrint(buf, "{d}d", .{@min(99, @divFloor(s, 86400))})) catch "";
}

/// The share of its context budget past which a Claude's is drawn to be seen: compaction is near.
const ctx_warn = 80;

/// A length of time in its two largest units: 45s, 9m, 1h9m, 2d3h.
fn span(buf: []u8, s: u32) []const u8 {
    return (if (s < 60)
        std.fmt.bufPrint(buf, "{d}s", .{s})
    else if (s < 3600)
        std.fmt.bufPrint(buf, "{d}m", .{s / 60})
    else if (s < 86400)
        std.fmt.bufPrint(buf, "{d}h{d}m", .{ s / 3600, s / 60 % 60 })
    else
        std.fmt.bufPrint(buf, "{d}d{d}h", .{ s / 86400, s / 3600 % 24 })) catch "";
}

/// A count of tokens in four cells at most: 840, 84k, 1.2M.
fn tokenCount(buf: []u8, n: u32) []const u8 {
    if (n == 0) return "";
    return (if (n < 1000)
        std.fmt.bufPrint(buf, "{d}", .{n})
    else if (n < 1_000_000)
        std.fmt.bufPrint(buf, "{d}k", .{n / 1000})
    else
        std.fmt.bufPrint(buf, "{d}.{d}M", .{ n / 1_000_000, n / 100_000 % 10 })) catch "";
}

/// The session rail, a bordered panel down the left edge: a session a row with how many windows
/// it has, the current one a chip, its Claudes under a rule of their own, and the menu button on
/// its last row. Narrow, it has no titles, and its rows show less.
fn rail(app: *const App, w: *Writer) !void {
    const width = app.railDrawnW();
    if (width == 0) return;
    const wide = width == app.railWideW();
    const h = app.view_h;
    const inner = width - 2;
    const dim = ink(app, "dim", 8);
    var lines: [64]App.AgentLine = undefined;
    const agents = app.railAgents(&lines);
    const agents_row = app.railAgentsRow();
    const agents_title: []const u8 = if (!wide) "" else switch (app.agent_sort) {
        .urgency => " agents · urgency ",
        .recent => " agents · recent ",
        .ticket => " agents · ticket ",
    };
    var pen: Pen = .{};
    var y: u16 = 0;
    while (y < h) : (y += 1) {
        try w.print("\x1b[{d};1H", .{y + 1});
        const top = y == 0;
        const bottom = y == h - 1;
        const over_agents = y == agents_row and agents > 0;
        const ruled = (y == app.railRuleRow() or over_agents) and !top;
        const title: []const u8 = if (top and wide) rail_title else if (over_agents) agents_title else "";
        var x: u16 = 0;
        var at_title: usize = 0;
        while (x < width) : (x += 1) {
            if (!top and !bottom and !ruled and x == 1) {
                const at = y -| (agents_row + 1);

                if (y > agents_row and at < agents) {
                    try agentRow(app, w, &pen, lines[at], inner, wide);
                } else try railRow(app, w, &pen, y, inner, wide);
                x = width - 2;
                continue;
            }
            // a title is written a character at a time from the third cell, the multibyte · too
            if (x >= 2 and at_title < title.len) {
                try pen.set(w, dim, null);
                const len = std.unicode.utf8ByteSequenceLength(title[at_title]) catch 1;
                try w.writeAll(title[at_title..][0..len]);
                at_title += len;
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
fn railRow(app: *const App, w: *Writer, pen: *Pen, y: u16, inner: u16, wide: bool) !void {
    const dim = ink(app, "dim", 8);
    var filled: usize = 0;
    const index: usize = y -| 2;
    if (y == app.railMenuRow()) {
        try pen.set(w, dim, null);
        const button = if (wide) app_mod.rail_button else "≡";
        try w.writeAll(" ");
        try w.writeAll(button);
        filled = 1 + cellCount(button);
    } else if (y == app.railNewRow()) {
        try pen.set(w, dim, null);
        const button = if (wide) app_mod.rail_new else "+";
        try w.writeAll(" ");
        try w.writeAll(button);
        filled = 1 + cellCount(button);
    } else if (y == 1 and app.board != null) {
        const open = app.board_view != null;
        const todo = app.railCount(.todo);
        const doing = app.railCount(.doing);
        var buf: [48]u8 = undefined;
        try pen.set(w, if (open) chip(app) else ink(app, "amber", 4), null);
        var runs: [1]*const tickets.Card = undefined;
        const run_count = if (app.board) |*b| b.running(&runs) else 0;
        const running: ?*const tickets.Card = if (run_count > 0) runs[0] else null;
        if (wide) {
            // the pipeline's work in hand stands in for the counts while there is any
            var spun: [8]u8 = undefined;
            const mark = spun[0 .. std.unicode.utf8Encode(glyph(app, .working), &spun) catch 0];
            const counts = if (running) |card|
                (if (run_count > 1)
                    std.fmt.bufPrint(&buf, "{s} #{d} {s} +{d} ", .{ mark, card.id, card.stage.?, run_count - 1 })
                else
                    std.fmt.bufPrint(&buf, "{s} #{d} {s} ", .{ mark, card.id, card.stage.? })) catch ""
            else
                std.fmt.bufPrint(&buf, "{d} todo  {d} doing ", .{ todo, doing }) catch "";
            try w.writeAll(" ▤ board");
            var needs_buf: [16]u8 = undefined;
            const needs = app.railNeeds(&needs_buf);
            if (!open) try pen.set(w, if (app.needsCount() > 0) heading(app) else dim, null);
            try w.writeAll(needs);
            var auto_buf: [32]u8 = undefined;
            const auto = if (app.auto()) |state| (if (state.tools) |t|
                std.fmt.bufPrint(&auto_buf, " auto {d}/{d} · tools {d}/{d}", .{ state.working, state.cap, t.working, t.cap })
            else
                std.fmt.bufPrint(&auto_buf, " auto {d}/{d}", .{ state.working, state.cap })) catch "" else "";
            const orch_state = app.orchestrator();
            const runs_orch = if (orch_state) |state| state.running else false;
            const orch: []const u8 = if (orch_state) |state| (if (state.running or state.on) " orch" else " orch off") else "";
            // both give way to the counts on a rail too narrow: a running orchestrator first,
            // then auto's state, and one that is not running last
            const room = inner -| (8 + cellCount(needs) + 1 + cellCount(counts));
            const down_w = if (!runs_orch and cellCount(orch) <= room) cellCount(orch) else 0;
            const auto_w = if (cellCount(auto) + down_w <= room) cellCount(auto) else 0;
            const orch_w = if (runs_orch and auto_w + cellCount(orch) <= room) cellCount(orch) else down_w;
            const head = 8 + cellCount(needs) + auto_w + orch_w;
            if (auto_w > 0) {
                if (!open) try pen.set(w, autoOn(app), null);
                try w.writeAll(auto);
            }
            if (orch_w > 0) {
                if (!open) try pen.set(w, if (runs_orch) ink(app, "violet", 5) else ink(app, "dim", 8), null);
                try w.writeAll(orch);
            }
            try pen.set(w, if (open) chip(app) else ink(app, "dim", 8), null);
            const shown = clip(counts, inner -| head);
            try fitted(w, "", inner -| head -| cellCount(shown));
            try w.writeAll(shown);
            filled = @min(inner, head + (inner -| head -| cellCount(shown)) + cellCount(shown));
        } else {
            var spun: [8]u8 = undefined;
            const mark = spun[0 .. std.unicode.utf8Encode(glyph(app, .working), &spun) catch 0];
            const count = if (running != null) std.fmt.bufPrint(&buf, "{s} ", .{mark}) catch "" else std.fmt.bufPrint(&buf, "{d} ", .{doing}) catch "";
            try w.writeAll(" ▤");
            try fitted(w, "", inner -| 2 -| cellCount(count));
            try w.writeAll(count);
            filled = inner;
        }
    } else if (y >= 2 and index < app.railShown()) {
        const s = app.sessions.items[index];
        const drop = app.dropAt();
        // lit as the current one is: a window held by its title would go to it
        const here = (s.id == app.current and app.board_view == null) or (drop == .session and drop.session == index);
        const picked = if (app.railPicked()) |pick| pick == .session and pick.session == s.id else false;
        if (!wide) {
            const name = shortName(s.name);
            try repoBar(app, w, pen, app.sessionRepo(index), picked, if (here) chip(app) else .{});
            try w.writeAll(name);
            for (0..inner - 3 - cellCount(name)) |_| try w.writeAll(" ");
            try pen.set(w, if (here) chip(app) else ink(app, "amber", 4), null);
            try put(w, sessionGlyph(app, s));
            try pen.set(w, if (here) chip(app) else dim, null);
            try w.print("{d}", .{@min(s.wins.items.len, 9)});
            filled = inner;
        } else {
            const review = App.sessionReview(s);
            const many = App.sessionMark(s) != .none and App.sessionCount(s) > 1;
            const repo = app.sessionRepo(index);
            const icon = repoIcon(app, repo);
            const lead = if (icon != null) @as(usize, 2) else 0;
            const room = inner - 6 - lead - @intFromBool(review != .none) - @intFromBool(many);
            const cut = cellCount(s.name) > room;
            const name = clip(s.name, room - @intFromBool(cut));
            const base = if (here) chip(app) else vt.Style{};
            try repoBar(app, w, pen, repo, picked, base);
            if (icon) |mark| {
                var hue = repoEdge(app, repo).?;
                if (here) hue.bg_color = chip(app).bg_color;
                try pen.set(w, hue, null);
                try w.writeAll(mark);
                try pen.set(w, base, null);
                try w.writeAll(" ");
            }
            try w.writeAll(name);
            if (cut) try w.writeAll("…");
            for (0..inner - 5 - lead - @intFromBool(review != .none) - @intFromBool(many) - cellCount(name) - @intFromBool(cut)) |_| try w.writeAll(" ");
            if (review != .none) {
                try pen.set(w, if (here) chip(app) else reviewInk(app, review), null);
                try put(w, reviewGlyph(review));
            }
            try pen.set(w, if (here) chip(app) else ink(app, "amber", 4), null);
            try put(w, sessionGlyph(app, s));
            if (many) try w.print("{d}", .{@min(App.sessionCount(s), 9)});
            try pen.set(w, if (here) chip(app) else dim, null);
            try w.print("{d:>2} ", .{@min(s.wins.items.len, 99)});
            filled = inner;
        }
    } else try pen.set(w, .{}, null);
    for (@min(filled, inner)..inner) |_| try w.writeAll(" ");
}

/// The `inner` cells of a row of the rail's agents. Wide, a Claude's row has its mark, name,
/// review mark, context and time, and its detail under it with its branch; narrow, its mark and
/// time alone.
fn agentRow(app: *const App, w: *Writer, pen: *Pen, line: App.AgentLine, inner: u16, wide: bool) !void {
    const dim = ink(app, "dim", 8);
    var filled: usize = 0;
    // the selected Claude's rows are one solid bar, its shown subagent's in bold; its session's
    // header only says it holds it
    switch (line) {
        .agent, .detail, .meta, .background => |a| if (app.agentSelected(a)) {
            pen.over = chip(app);
        },
        .sub => |sub| if (app.agentSelected(sub.agent)) {
            var bar = chip(app);
            bar.flags.bold = app.subShown(sub);
            pen.over = bar;
        },
        else => {},
    }
    defer pen.over = null;
    switch (line) {
        .session => |si| {
            const s = app.sessions.items[si];
            // the current session's header is lit only while no Claude's row says so
            const holds = if (s.focused()) |win| win.agent() else false;
            const repo = app.sessionRepo(si);
            const lit = s.id == app.current and app.board_view == null and !holds;
            const base = if (lit) heading(app) else if (!wide and repo.len > 0) repoStyle(repo) else dim;
            try pen.set(w, base, null);
            if (wide) {
                const icon = repoIcon(app, repo);
                const lead: usize = if (icon != null) 2 else 0;
                const name = clip(s.name, inner - 2 - lead);
                if (repoEdge(app, repo)) |edge| {
                    try pen.set(w, edge, null);
                    try w.writeAll("▌");
                    if (icon) |mark| {
                        try w.writeAll(mark);
                        try pen.set(w, base, null);
                        try w.writeAll(" ");
                    } else try pen.set(w, base, null);
                } else try w.writeAll(" ");
                try w.writeAll(name);
                filled = 1 + lead + cellCount(name);
            } else {
                // a rule with the name in it, so it does not read as an entry
                const name = shortName(s.name);
                try w.writeAll("─");
                try w.writeAll(name);
                for (0..inner - 1 - cellCount(name)) |_| try w.writeAll("─");
                filled = inner;
            }
        },
        .agent => |a| {
            const win = a.win;
            var buf: [8]u8 = undefined;
            const time = ago(&buf, app.epoch, win.since);
            const picked = if (app.railPicked()) |pick| pick == .agent and pick.agent == win.id else false;
            try repoBar(app, w, pen, app.sessionRepo(a.session), picked, if (win.claude == .none) dim else ink(app, "amber", 4));
            try pen.set(w, if (win.claude == .none) dim else ink(app, "amber", 4), null);
            try put(w, agentGlyph(app, win));
            filled = 2;
            if (!wide) {
                // its ticket's number, else its window's place in its session
                var num: [8]u8 = undefined;
                const s = app.sessions.items[a.session];
                const at = std.mem.indexOfScalar(*Window, s.wins.items, win) orelse 0;
                const label = app_mod.branchTicket(win.text(.branch)) orelse
                    (std.fmt.bufPrint(&num, "w{d}", .{at + 1}) catch "");
                try pen.set(w, dim, null);
                try w.writeAll(" ");
                try w.writeAll(label);
                filled = 3 + cellCount(label);
            } else {
                // the time and a space at the right end
                const room = inner - 3 - 5;
                const s = app.sessions.items[a.session];
                try pen.set(w, if (s.id == app.current and s.focused() == win) ink(app, "amber", 4) else .{}, null);
                try w.writeAll(" ");
                try fitted(w, win.label(), room);
                filled = 3 + room;
            }
            if (wide) {
                try pen.set(w, dim, null);
                try w.writeAll(" ");
                for (time.len..3) |_| try w.writeAll(" ");
                try w.writeAll(time);
                filled += 4;
            }
        },
        .detail => |a| {
            const win = a.win;
            try repoBar(app, w, pen, app.sessionRepo(a.session), false, dim);
            // at the right: how long a quiet one has said nothing, or how long a done one worked
            var buf: [16]u8 = undefined;
            var since: [8]u8 = undefined;
            const quiet = win.quiet(app.epoch);
            const right: []const u8 = if (quiet)
                std.fmt.bufPrint(&buf, "quiet {s}", .{ago(&since, app.epoch, win.at)}) catch ""
            else if ((win.claude == .done or win.claude == .none) and win.took > 0)
                span(&buf, win.took)
            else
                "";
            try pen.set(w, dim, null);
            try w.writeAll("  ");
            try fitted(w, win.detail(), inner - 4 - if (right.len > 0) right.len + 1 else 0);
            if (right.len > 0) {
                try pen.set(w, if (quiet) ink(app, "emberdim", 1) else dim, null);
                try w.writeAll(" ");
                try w.writeAll(right);
            }
            filled = inner - 1;
        },
        .sub => |sub| {
            const win = sub.agent.win;
            try repoBar(app, w, pen, app.sessionRepo(sub.agent.session), false, dim);
            try pen.set(w, dim, null);
            try w.writeAll("  ");
            try pen.set(w, ink(app, "amber", 4), null);
            try put(w, if (win.stirring) glyph(app, .working) else '◔');
            // lit as its Claude's title is in view, while that Claude shows it
            try pen.set(w, if (app.subShown(sub)) ink(app, "amber", 4) else dim, null);
            try w.writeAll(" ");
            try fitted(w, win.sub(sub.index), inner - 6);
            filled = inner - 1;
        },
        .background => |a| {
            try repoBar(app, w, pen, app.sessionRepo(a.session), false, dim);
            try pen.set(w, dim, null);
            try w.writeAll("  ");
            try pen.set(w, ink(app, "amber", 4), null);
            // its subagents' rows spin for them; with none listed, this row is a subagent's
            try put(w, if (a.win.stirring and a.win.subs() == 0) glyph(app, .working) else '◔');
            try pen.set(w, dim, null);
            try w.writeAll(" ");
            try fitted(w, a.win.text(.background), inner - 6);
            filled = inner - 1;
        },
        .meta => |a| {
            const win = a.win;
            try repoBar(app, w, pen, app.sessionRepo(a.session), false, dim);
            try pen.set(w, dim, null);
            try w.writeAll("  ");
            var count: [8]u8 = undefined;
            // the share of its budget, when its status line says, else the tokens
            const tokens = if (win.ctx > 0)
                std.fmt.bufPrint(&count, "{d}%", .{@min(win.ctx, 999)}) catch ""
            else
                tokenCount(&count, win.tokens);
            // the context at the right end, kept clear of the rest by two cells at least
            const ctx: usize = if (tokens.len > 0) tokens.len + 4 else 0;
            var left: usize = inner - 4 - if (ctx > 0) ctx + 2 else 0;
            // the hook says "no repo" or "detached" and a commit for no branch; nothing, until it says
            const said = win.text(.branch);
            const named = said.len > 0 and !std.mem.eql(u8, said, "no repo") and !std.mem.startsWith(u8, said, "detached ");
            const branch = clip(if (said.len > 0) said else "branch unknown", left);
            try pen.set(w, if (named) ink(app, "violet", 5) else dim, null);
            try w.writeAll(branch);
            left -= cellCount(branch);
            var gap: usize = if (branch.len > 0) 2 else 0;
            if (win.review != .none and left >= gap + 3) {
                const word = clip(reviewWord(win.review), left - gap - 2);
                try pen.set(w, reviewInk(app, win.review), null);
                for (0..gap) |_| try w.writeAll(" ");
                try put(w, reviewGlyph(win.review));
                try w.writeAll(" ");
                try w.writeAll(word);
                left -= gap + 2 + cellCount(word);
                gap = 2;
            }
            if (ctx > 0) {
                try pen.set(w, if (win.ctx >= ctx_warn) ink(app, "emberdim", 1) else dim, null);
                for (0..left + 2) |_| try w.writeAll(" ");
                try w.writeAll(tokens);
                try w.writeAll(" ctx");
                left = 0;
            }
            filled = inner - 1 - left;
        },
        .above => |count| {
            try pen.set(w, dim, null);
            if (wide) try w.print(" ↑ {d} above", .{count}) else try w.print(" ↑{d}", .{count});
            filled = (if (wide) @as(usize, 9) else 2) + std.fmt.count("{d}", .{count});
        },
        .pipeline => |fold| {
            const picked = if (app.railPicked()) |pick| pick == .fold and pick.fold == app.foldKey(fold) else false;
            try repoBar(app, w, pen, if (fold.session) |si| app.sessionRepo(si) else fold.repo, picked, dim);
            try pen.set(w, dim, null);
            var buf: [96]u8 = undefined;
            const text = if (fold.session != null)
                std.fmt.bufPrint(&buf, " · {d}{s}", .{ fold.count, if (wide) " more" else "" }) catch ""
            else if (wide)
                std.fmt.bufPrint(&buf, " {s} {d} in the pipeline{s}{s}", .{ if (fold.open) "▾" else "◌", fold.count, if (fold.repo.len > 0) " · " else "", fold.repo }) catch ""
            else
                std.fmt.bufPrint(&buf, " ◌{d}", .{fold.count}) catch "";
            const shown = clip(text[@min(1, text.len)..], inner - 1);
            try w.writeAll(shown);
            filled = 1 + cellCount(shown);
        },
        .more => |count| {
            try pen.set(w, dim, null);
            if (wide) try w.print(" +{d} more", .{count}) else try w.print(" +{d}", .{count});
            filled = @min(inner, (if (wide) @as(usize, 7) else 2) + std.fmt.count("{d}", .{count}));
        },
    }
    for (filled..inner) |_| try w.writeAll(" ");
}

/// `repo`'s colour in Workbench's look, for the `▌` that starts its rows; none for a repo it has
/// no colour for, or without a palette.
fn repoEdge(app: *const App, repo: []const u8) ?vt.Style {
    const r = app.roles orelse return null;
    for (theme.Roles.repo_names, 0..) |name, i| if (std.mem.eql(u8, name, repo)) return rgbStyle(r.repo[i]);
    return null;
}

/// The rail's first cell of a row: the picked mark, else `repo`'s `▌`, else a space in `base`.
fn repoBar(app: *const App, w: *Writer, pen: *Pen, repo: []const u8, picked: bool, base: vt.Style) !void {
    if (!picked) if (repoEdge(app, repo)) |edge| {
        // a selected Claude's bar keeps its ground under the edge, not its ink
        const over = pen.over;
        pen.over = null;
        var drawn = edge;
        drawn.bg_color = (over orelse base).bg_color;
        try pen.set(w, drawn, null);
        try w.writeAll("▌");
        pen.over = over;
        try pen.set(w, base, null);
        return;
    };
    try pickBar(app, w, pen, picked, base);
}

/// `repo`'s icon, none where `repoEdge` has no colour for it.
fn repoIcon(app: *const App, repo: []const u8) ?[]const u8 {
    if (repoEdge(app, repo) == null) return null;
    for (theme.Roles.repo_names, 0..) |name, i| if (std.mem.eql(u8, name, repo)) return repo_glyphs[i];
    return null;
}

/// A repo's colour, one of the terminal's own, the same for the same name.
fn repoStyle(repo: []const u8) vt.Style {
    return .{ .fg_color = .palette(@intCast(2 + std.hash.Wyhash.hash(0, repo) % 5)) };
}

/// A Claude's mark in a list of them, where one done and looked at is still listed.
fn agentGlyph(app: *const App, win: *const Window) u21 {
    return if (win.claude == .none) '○' else glyph(app, win.claude);
}

/// `text` in exactly `width` cells: cut with an ellipsis, or padded.
fn fitted(w: *Writer, text: []const u8, width: usize) !void {
    if (width == 0) return;
    const cut = cellCount(text) > width;
    const shown = clip(text, if (cut) width - 1 else width);
    try w.writeAll(shown);
    if (cut) try w.writeAll("…");
    for (cellCount(shown) + @intFromBool(cut)..width) |_| try w.writeAll(" ");
}

const spinner = [_]u21{ '◐', '◓', '◑', '◒' };
const spinner_step_ms = 200;

fn glyph(app: *const App, mark: app_mod.Mark) u21 {
    return switch (mark) {
        .none => ' ',
        .background => '◔',
        .working => if (app.motion) spinner[@intCast(@mod(@divFloor(app.now, spinner_step_ms), spinner.len))] else spinner[0],
        .done => '◉',
        .waiting => '▲',
        .stalled => '✖',
    };
}

/// A session's mark: its Claudes' most pressing, else what tmux saw in its windows.
fn sessionGlyph(app: *const App, s: *const app_mod.Session) u21 {
    const mark = App.sessionMark(s);
    return if (mark != .none) glyph(app, mark) else alertGlyph(App.sessionAlert(s));
}

/// tmux's own marks for them in a window list.
fn alertGlyph(alert: app_mod.Alert) u21 {
    return switch (alert) {
        .none => ' ',
        .activity => '#',
        .bell => '!',
    };
}

fn reviewGlyph(review: app_mod.Review) u21 {
    return switch (review) {
        .none => ' ',
        .landed => '◆',
        .reviewed => '✓',
        .queued => '»',
        .changes => '✗',
    };
}

fn reviewWord(review: app_mod.Review) []const u8 {
    return switch (review) {
        .none => "",
        .landed => "landed",
        .reviewed => "approved",
        .queued => "queued",
        .changes => "changes",
    };
}

fn reviewInk(app: *const App, review: app_mod.Review) vt.Style {
    return switch (review) {
        .none, .landed => ink(app, "dim", 8),
        .reviewed => ink(app, "amber", 4),
        .queued => ink(app, "violet", 5),
        .changes => ink(app, "emberdim", 1),
    };
}

fn cellCount(text: []const u8) usize {
    return std.unicode.utf8CountCodepoints(text) catch text.len;
}

/// A session's name in five cells or fewer: a fixed short name for the repos that have one, else
/// the name cut.
fn shortName(name: []const u8) []const u8 {
    const short = [_][2][]const u8{
        .{ "ficciones", "ficc" },
        .{ "silliest_of_gooses", "goose" },
        .{ "menard", "menrd" },
    };
    for (short) |pair| if (std.mem.eql(u8, name, pair[0])) return pair[1];
    return clip(name, 5);
}

/// The first `max` characters of `text`.
fn clip(text: []const u8, max: usize) []const u8 {
    var it = std.unicode.Utf8View.initUnchecked(text).iterator();
    var n: usize = 0;
    while (n < max) : (n += 1) _ = it.nextCodepointSlice() orelse break;
    return text[0..it.i];
}

/// The last `max` characters of `text`.
fn lastCells(text: []const u8, max: usize) []const u8 {
    var n = cellCount(text);
    var it = std.unicode.Utf8View.initUnchecked(text).iterator();
    while (n > max) : (n -= 1) _ = it.nextCodepointSlice();
    return text[it.i..];
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

/// Bold violet: auto mode while it is on.
fn autoOn(app: *const App) vt.Style {
    var style = ink(app, "violet", 5);
    style.flags.bold = true;
    return style;
}

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
        .jump, .search, .report, .words, .why, .find, .tried => "",
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
            .report => "  ! What's wrong?",
            .words, .why, .find, .tried => "",
        },
        dim,
        std.fmt.bufPrint(&buf, "{s}  ", .{clip(was, 12)}) catch "",
    );
    try b.blank();
    const shown = lastCells(prompt.text(), menu.width - 10);
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
            const style: vt.Style = if (i == prompt.selected) chip(app) else .{};
            const s, const win = switch (hits[i]) {
                .window => |found| .{ found.session, found.session.wins.items[found.index] },
                .ticket => |card| {
                    const row = std.fmt.bufPrint(&buf, "  #{d} › {s}", .{ card.id, clip(card.title, 28) }) catch "";
                    try b.line(style, row, style, "");
                    continue;
                },
            };
            const left = std.fmt.bufPrint(&buf, "  {s} › {s}", .{ clip(s.name, 12), clip(win.name, 14) }) catch "";
            var mark: [8]u8 = undefined;
            const mark_len = std.unicode.utf8Encode(glyph(app, app.mark(s, win)), &mark) catch 0;
            @memcpy(mark[mark_len..][0..2], "  ");
            try b.line(style, left, if (i == prompt.selected) style else ink(app, "amber", 4), mark[0 .. mark_len + 2]);
        }
        try b.blank();
        try b.line(dim, "  ↑↓ move   ⏎ go   esc close", dim, "");
    } else if (prompt.what == .search) {
        try b.line(dim, if (prompt.missed) "  no match" else "  ⏎ older match   esc close", dim, "");
    } else if (prompt.what == .report) {
        try b.line(dim, "  ⏎ file it   esc cancel", dim, "");
    } else try b.line(dim, "  ⏎ rename   esc cancel", dim, "");
    try b.edge("╰", "╯");
    return .{ .x = at.x + 6 + @as(i32, @intCast(cellCount(shown))), .y = at.y + 4 };
}

/// The line a ticket's why is typed into, at the board's foot. Returns where its cursor goes.
fn wordsLine(app: *const App, w: *Writer, prompt: *const menu.Prompt) !Cursor {
    const x = app.boardX();
    const y = app.view_h -| 2;
    const inner = app.boardW() -| 4;
    var buf: [256]u8 = undefined;
    const hint = "  ⏎ save  esc drop";
    const room = inner -| 2 -| cellCount(hint);
    const text = prompt.text();
    var shown = text;
    while (cellCount(shown) > room and shown.len > 0) shown = shown[1..];
    while (shown.len > 0 and shown[0] & 0xC0 == 0x80) shown = shown[1..];
    var pen: Pen = .{};
    try pen.set(w, ink(app, "amber", 4), null);
    try w.print("\x1b[{d};{d}H", .{ y + 1, x + 2 });
    try pen.set(w, heading(app), null);
    try w.writeAll("❯ ");
    try pen.set(w, .{}, null);
    try w.writeAll(std.fmt.bufPrint(&buf, "{s}", .{shown}) catch "");
    const used = 2 + cellCount(shown);
    for (used..inner -| cellCount(hint)) |_| try w.writeAll(" ");
    try pen.set(w, ink(app, "dim", 8), null);
    if (inner >= used + cellCount(hint)) try w.writeAll(hint);
    return .{ .x = @as(i32, x) + 1 + @as(i32, @intCast(used)), .y = y };
}

const Cursor = struct { x: i32, y: i32 };

/// `text` run on over lines of `inner` cells: a newline ends a line, and one at the end leaves an
/// empty line to type on. The lines from `from` are put in `out`; the count of all is returned.
fn wrapLines(text: []const u8, inner: usize, from: usize, out: [][]const u8) usize {
    var n: usize = 0;
    var segments = std.mem.splitScalar(u8, text, '\n');
    while (segments.next()) |segment| {
        var rest = segment;
        while (true) {
            var cut = std.unicode.Utf8View.initUnchecked(rest).iterator();
            var cells: usize = 0;
            while (cells < inner) : (cells += 1) _ = cut.nextCodepointSlice() orelse break;
            if (n >= from and n - from < out.len) out[n - from] = rest[0..cut.i];
            n += 1;
            rest = rest[cut.i..];
            if (rest.len == 0) break;
        }
    }
    return n;
}

/// The modal the human's words are written in: over the orchestrator's column, with what it
/// answers quoted above a box that grows to a fixed height and then scrolls, and send and cancel
/// in its foot. Returns where its cursor goes.
fn wordsModal(app: *const App, w: *Writer, prompt: *const menu.Prompt) !Cursor {
    const rect = app.wordsRect();
    const inner: u16 = rect.w -| 4;
    const edge = ink(app, "amber", 4);
    const dim: vt.Style = ink(app, "dim", 8);
    var pen: Pen = .{};
    var scratch: [1024]u8 = undefined;
    const about = app.wordsAbout(prompt.*, &scratch);

    try pen.set(w, edge, null);
    try w.print("\x1b[{d};{d}H╭─", .{ rect.y + 1, rect.x + 1 });
    try pen.set(w, heading(app), null);
    const title = clip(about.title, inner -| 2);
    try w.print(" {s} ", .{title});
    try pen.set(w, edge, null);
    for (cellCount(title) + 4..rect.w -| 1) |_| try w.writeAll("─");
    try w.writeAll("╮");

    var row: u16 = 1;
    var quoted = app_mod.DetailLines.init(about.quote, inner);
    while (quoted.next()) |line| : (row += 1) {
        if (row > App.words_quote_rows) break;
        try boxLine(w, &pen, edge, dim, rect.x, rect.y + row + 1, line, inner);
    }
    if (row > 1) {
        try boxLine(w, &pen, edge, .{}, rect.x, rect.y + row + 1, "", inner);
        row += 1;
    }

    // the last row of the box says its keys: the foot's edge has no room for them in a narrow column
    const room = rect.h -| 2 -| row;
    const text_w = inner -| 2;
    const total = wrapLines(prompt.text(), text_w, 0, &.{});
    const start = total -| room;
    var lines: [32][]const u8 = undefined;
    const shown = lines[0..@min(room, lines.len)];
    _ = wrapLines(prompt.text(), text_w, start, shown);
    var last: []const u8 = "";
    for (0..room) |i| {
        var buf: [512]u8 = undefined;
        const at = start + i;
        const line: []const u8 = if (at < total and i < shown.len) shown[i] else "";
        if (at + 1 == total) last = line;
        const lead: []const u8 = if (at == 0) "❯ " else "  ";
        try boxLine(w, &pen, edge, .{}, rect.x, rect.y + row + 1 + @as(u16, @intCast(i)), std.fmt.bufPrint(&buf, "{s}{s}", .{ lead, line }) catch "", inner);
    }
    const cursor_row: u16 = @intCast(@min(total -| 1 -| start, room -| 1));
    try boxLine(w, &pen, edge, dim, rect.x, rect.y + row + 1 + room, "  shift+⏎ new line", inner);

    const foot = rect.y + rect.h;
    try pen.set(w, edge, null);
    try w.print("\x1b[{d};{d}H╰─", .{ foot, rect.x + 1 });
    for (3..rect.w) |_| try w.writeAll("─");
    try w.writeAll("╯");
    var buttons: [2]App.ModalButton = undefined;
    for (app.wordsButtons(prompt.*, &buttons)) |button| {
        var style = edge;
        style.flags.inverse = true;
        try pen.set(w, style, null);
        try w.print("\x1b[{d};{d}H {s} {s} ", .{ button.y + 1, button.x + 1, button.key, button.label });
    }
    try pen.set(w, .{}, null);
    return .{ .x = @as(i32, rect.x) + 2 + 2 + @as(i32, @intCast(@min(cellCount(last), text_w))), .y = @as(i32, rect.y) + row + @as(i32, cursor_row) };
}

/// What the board is narrowed to, after its title in the header: while it is typed, with its
/// cursor and what Enter and Escape do; once kept, with Escape's. Returns where the cursor goes.
fn findLine(app: *const App, w: *Writer) !?Cursor {
    const typing = if (app.prompt) |p| p.what == .find else false;
    const text = app.findText();
    if (!typing and text.len == 0) return null;
    var pen: Pen = .{};
    const x: usize = app.boardX() + cellCount(App.board_title) + 2;
    const hint = if (typing) "  ⏎ keep  esc clear" else "  esc clear";
    if (app.roles) |r| return benchFind(app, w, r, x, text, hint, typing);
    const room = @as(usize, app.boardW()) -| cellCount(App.board_title) -| 3;
    var shown = text;
    while (cellCount(shown) + 2 + cellCount(hint) > room and shown.len > 0) shown = shown[1..];
    while (shown.len > 0 and shown[0] & 0xC0 == 0x80) shown = shown[1..];
    try w.print("\x1b[1;{d}H", .{x + 1});
    try pen.set(w, ink(app, "amber", 4), null);
    try w.writeAll("/ ");
    try pen.set(w, .{}, null);
    try w.writeAll(shown);
    const used = 2 + cellCount(shown);
    try pen.set(w, ink(app, "dim", 8), null);
    try w.writeAll(hint);
    try pen.set(w, .{}, null);
    for (used + cellCount(hint)..room) |_| try w.writeAll(" ");
    return if (typing) .{ .x = @intCast(x + used), .y = 0 } else null;
}

/// The find line on the title bar's raised face, in the room the right group leaves: the hint goes
/// first when it does not fit, then the text, cut with `…`.
fn benchFind(app: *const App, w: *Writer, r: theme.Roles, x: usize, text: []const u8, hint: []const u8, typing: bool) !?Cursor {
    var heads: [48]App.Button = undefined;
    var right: usize = app.boardX() + app.boardW();
    for (heads[0..app.header(&heads).n]) |b| {
        if (b.y == 0) right = @min(right, b.x);
    }
    const room = right -| x -| 1;
    const lead = 2;
    const hinted = lead + cellCount(text) + cellCount(hint) <= room;
    const left = room -| lead -| (if (hinted) cellCount(hint) else 0);
    var cut: [204]u8 = undefined;
    const shown = if (cellCount(text) <= left) text else (std.fmt.bufPrint(&cut, "{s}…", .{clip(text, left -| 1)}) catch text);
    try bench.fill(w, x, 0, room, r.raised);
    if (room < lead) return null;
    try bench.say(w, x, 0, "/ ", r.accent, r.raised, true);
    try bench.say(w, x + lead, 0, shown, r.text, r.raised, false);
    if (hinted) try bench.say(w, x + lead + cellCount(shown), 0, hint, r.dim, r.raised, false);
    return if (typing) .{ .x = @intCast(x + lead + cellCount(shown)), .y = 0 } else null;
}

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
    return paneCell(app, pen, w, pane, tx - pane.x, ty - pane.y, dim, clip_lo, clip_hi);
}

/// One cell of `pane`'s screen at (`px`, `py`), as it was last rendered.
fn paneCell(app: *const App, pen: *Pen, w: *Writer, pane: *const Pane, px: usize, py: usize, dim: ?*const color.Palette, clip_lo: bool, clip_hi: bool) !void {
    _ = app;
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
        const focused = i == s.focus and (app.board_view == null or app.sideFocused()) and app.popup == null;
        if (what == .focused_border and !focused and app.mark(s, win) != .working) continue;
        const col_w = app.colW(s, win);
        const x0 = app.colX(s, i) - s.scroll;
        const x1 = x0 + col_w - 1;
        const lo: i32 = @max(x0, 0);
        const hi: i32 = @min(x1 + 1, app.view_w);
        if (lo >= hi) continue;
        for (win.panes.items) |pane| try pane.render.update(app.gpa, &pane.term);

        var title_buf: [96]u8 = undefined;
        var title_cps: [64]u21 = undefined;
        var right_cps: [24]u21 = undefined;
        const headed = i == 0 and s.orchestrator() and app.sided();
        var button: ?[2]usize = null;
        const title = if (headed) sideHead(app, &title_buf, &button, col_w) else std.fmt.bufPrint(&title_buf, " {d} {s} ", .{ i + 1, win.name }) catch title_buf[0..0];
        var title_len = codepoints(title, &title_cps);
        const mark = if (headed) .none else app.mark(s, win);
        if (mark != .none and title_len + 2 <= title_cps.len) {
            title_cps[title_len] = glyph(app, mark);
            title_cps[title_len + 1] = ' ';
            title_len += 2;
        }
        if (title_len + 4 > col_w) title_len = 0;
        const right = if (headed) right_cps[0..codepoints(sideHint(app), &right_cps)] else right_cps[0..0];
        const col: Column = .{
            .app = app,
            .w = col_w,
            .focused = focused,
            .drop = drop == .column and drop.column == i,
            .title = title_cps[0..title_len],
            .mark_at = if (headed and title_len > 0) 1 else if (mark != .none and title_len > 0) title_len - 2 else null,
            .right = if (title_len + right.len + 6 <= col_w) right else right[0..0],
            .button = if (title_len > 0) button else null,
            .roles = if (headed) app.roles else null,
        };

        var pen: Pen = .{};
        const top = app.winTop(s, i);
        var the_feed: feed.Feed = undefined;
        const drawn: usize = if (top > 1 and app.feedOf(&the_feed)) the_feed.count() + 2 else top;
        var y: u16 = 0;
        while (y < app.view_h) : (y += 1) {
            const sy = y + yoff;
            if (sy < 0 or sy >= app.view_h) continue;
            if (y > 0 and y < drawn and y + 1 < app.view_h) {
                if (x0 < 0 or x1 >= app.view_w) continue;
                try w.print("\x1b[{d};{d}H", .{ sy + 1, ox + x0 + 1 });
                try col.border(&pen, w, 0, y);
                if (what == .focused_border) {
                    try w.print("\x1b[{d};{d}H", .{ sy + 1, ox + x1 + 1 });
                } else try feedRow(app, w, &pen, &the_feed, y - 1, col_w - 2);
                try col.border(&pen, w, col_w - 1, y);
                continue;
            }
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
                try cell(app, &pen, w, win, @intCast(sx - x0 - 1), y - top, focused, sx == in_lo, sx + 1 == in_hi);
            }
        }

        if (!focused or yoff != 0) continue;
        const pane = win.activePane() orelse continue;
        if (!pane.render.cursor.visible) continue;
        const at = pane.render.cursor.viewport orelse continue;
        const sx = x0 + 1 + pane.x + at.x;
        if (sx >= lo and sx < hi) cursor = .{ .x = ox + sx, .y = top + pane.y + at.y };
    }
    return cursor;
}

const fold_hint = " ` fold ";

/// What the column's top edge says at its right: how to fold it, or at half a screen, where else
/// home goes.
fn sideHint(app: *const App) []const u8 {
    return if (app.columnAlone()) App.half_hint else fold_hint;
}

/// The feed's pick while the plan has the keys: dim ink, inverted.
fn dimLit(app: *const App) vt.Style {
    var style = ink(app, "dim", 8);
    style.flags.inverse = true;
    return style;
}

/// A style on Workbench's panel when it sets no background of its own.
fn onPanel(app: *const App, style: vt.Style) vt.Style {
    const r = app.roles orelse return style;
    var s = style;
    switch (s.bg_color.value()) {
        .none => s.bg_color = .rgb(.{ .r = r.panel.r, .g = r.panel.g, .b = r.panel.b }),
        else => {},
    }
    return s;
}

fn paintStyle(fg: color.RGB, bg: color.RGB, bold: bool) vt.Style {
    var s: vt.Style = .{ .fg_color = .rgb(.{ .r = fg.r, .g = fg.g, .b = fg.b }), .bg_color = .rgb(.{ .r = bg.r, .g = bg.g, .b = bg.b }) };
    s.flags.bold = bold;
    return s;
}

/// Cells written one after another on a feed row, `room` of them left.
const RowOut = struct {
    w: *Writer,
    pen: *Pen,
    room: usize,
    bg: color.RGB,

    fn say(o: *RowOut, fg: color.RGB, bold: bool, text: []const u8) !void {
        const t = clip(text, o.room);
        if (t.len == 0) return;
        try o.pen.set(o.w, paintStyle(fg, o.bg, bold), null);
        try o.w.writeAll(t);
        o.room -= cellCount(t);
    }

    /// `▎label `: a lead bar and the words on raised, or, `filled`, `lead` the face and ink the words.
    fn chip(o: *RowOut, r: theme.Roles, lead: color.RGB, label: []const u8, filled: bool) !void {
        if (o.room < cellCount(label) + 2) return;
        try o.pen.set(o.w, paintStyle(lead, if (filled) lead else r.raised, false), null);
        try o.w.writeAll("▎");
        try o.pen.set(o.w, paintStyle(if (filled) r.on_accent else r.text, if (filled) lead else r.raised, filled), null);
        try o.w.writeAll(label);
        try o.w.writeAll(" ");
        o.room -= cellCount(label) + 2;
    }

    /// ` key label ` raised with its shadow's `▌` after it, or filled amber when `primary`.
    fn button(o: *RowOut, r: theme.Roles, key: []const u8, label: []const u8, primary: bool) !void {
        if (o.room < cellCount(key) + cellCount(label) + 5) return;
        const face = if (primary) r.accent else r.raised;
        try o.pen.set(o.w, paintStyle(if (primary) r.on_accent else r.accent, face, primary), null);
        try o.w.writeAll(" ");
        try o.w.writeAll(key);
        try o.pen.set(o.w, paintStyle(if (primary) r.on_accent else r.text, face, primary), null);
        try o.w.writeAll(" ");
        try o.w.writeAll(label);
        try o.w.writeAll(" ");
        try o.pen.set(o.w, paintStyle(r.well, o.bg, false), null);
        try o.w.writeAll("▌ ");
        o.room -= cellCount(key) + cellCount(label) + 5;
    }

    fn finish(o: *RowOut) !void {
        try o.say(o.bg, false, spaceRun(o.room));
    }
};

const space_run: [512]u8 = @splat(' ');

fn spaceRun(n: usize) []const u8 {
    return space_run[0..@min(n, space_run.len)];
}

/// Workbench's row of the feed for the lines that are tiles, buttons or chips: a Your move item a
/// tile led by its kind's chip, its buttons raised, landing and building chips as chips, the
/// pick lit raised. Chips keep their cells, so the pick's place is the text's.
fn benchFeedRow(app: *const App, w: *Writer, pen: *Pen, r: theme.Roles, f: *const feed.Feed, row: usize, inner: u16) !void {
    const line = f.line(row);
    const on = app.feedLitItem(f);
    const strong = app.feedLit() == .focused;
    var head = row;
    if (line.kind == .buttons or line.kind == .refused) {
        while (head > 0 and f.line(head).kind != .item) head -= 1;
    }
    const tiled = line.kind == .item or line.kind == .buttons or line.kind == .refused;
    const lit = if (on) |o| tiled and o.line == head else false;
    var o: RowOut = .{ .w = w, .pen = pen, .room = inner, .bg = if (!tiled) r.panel else if (lit) r.raised else r.tile };
    try o.say(r.text, false, " ");
    switch (line.kind) {
        .item => {
            try o.say(if (strong) r.accent else r.dim, true, if (lit) "▌ " else "  ");
            const need = if (line.need) |at| app.board.?.needsYou()[at] else null;
            const kind = if (need) |n| n.kind else "";
            const eql = std.mem.eql;
            if (eql(u8, kind, "ask")) try o.chip(r, r.you, "asks", true) else if (eql(u8, kind, "sent_back") or eql(u8, kind, "sendback")) try o.chip(r, r.failed, "sent back", true) else if (eql(u8, kind, "proposal")) try o.chip(r, r.accent, "proposal", true) else if (kind.len > 0) try o.chip(r, r.dim, kind, false);
            if (need) |n| if (n.ticket) |id| if (std.mem.indexOfScalar(u8, line.text, '#') == null) {
                var buf: [64]u8 = undefined;
                try o.say(repoHue(r, n.repo).hue, true, std.fmt.bufPrint(&buf, "#{d} {s} ", .{ id, n.repo }) catch "");
            };
            try o.say(r.text, false, line.text);
        },
        .buttons => {
            try o.say(if (strong) r.accent else r.dim, true, if (lit) "▌ " else "  ");
            var primary = true;
            var pieces = std.mem.splitSequence(u8, line.text, "   ");
            while (pieces.next()) |piece| {
                const space = std.mem.indexOfScalar(u8, piece, ' ') orelse piece.len;
                const key = piece[0..space];
                const mine = primary and std.mem.eql(u8, key, "⏎");
                if (mine) primary = false;
                try o.button(r, key, std.mem.trimStart(u8, piece[space..], " "), mine);
            }
        },
        .refused => {
            try o.say(if (strong) r.accent else r.dim, true, if (lit) "▌ " else "  ");
            try o.say(r.failed, false, line.text);
        },
        .strip => {
            try o.say(r.text, false, " ");
            // each tab's chip takes the two cells of the gap before it
            for (f.chips[0..f.n_chips]) |tab| {
                const here = on != null and on.?.line == row and on.?.at == tab.at;
                const piece = line.text[tab.at..@min(line.text.len, tab.at + tab.w)];
                try o.chip(r, if (here) (if (strong) r.accent else r.dim) else r.dim, piece, here or tab.section == f.lit);
            }
        },
        .move_head => {
            const cut = std.mem.lastIndexOfScalar(u8, line.text, ' ') orelse 0;
            try o.say(r.you, true, line.text[0..cut]);
            try o.say(r.text, false, " ");
            try o.chip(r, r.dim, line.text[@min(cut + 1, line.text.len)..], false);
        },
        else => {
            // landing's and building's chips, three cells apart in the text and one here, the chip
            // taking the gap's two
            try o.say(r.text, false, " ");
            const building = line.kind == .building_chips;
            var at: usize = 0;
            var pieces = std.mem.splitSequence(u8, line.text, "   ");
            while (pieces.next()) |piece| {
                const failed = std.mem.startsWith(u8, piece, "✗ ");
                const label = if (failed) piece["✗ ".len..] else piece;
                const here = on != null and on.?.line == row and on.?.at == at;
                at += cellCount(piece) + 3;
                if (piece.len == 0) continue;
                if (piece[0] == '+') {
                    try o.say(r.dim, false, piece);
                    continue;
                }
                var words = std.mem.tokenizeScalar(u8, label, ' ');
                _ = words.next();
                _ = words.next();
                const stage = words.next() orelse "";
                const lead = if (here) (if (strong) r.accent else r.dim) else if (failed) r.failed else if (building) r.building else stepHue(r, stage).lead;
                try o.chip(r, lead, label, here);
            }
        },
    }
    try o.finish();
}

/// Workbench's rows of a to-try tile: the rule over the section, the title with its chip and age,
/// the machine's line, a row for each wrapped line of a check, and the buttons under the picked
/// one. The picked check lit raised.
fn benchTryRow(app: *const App, w: *Writer, pen: *Pen, r: theme.Roles, f: *const feed.Feed, row: usize, inner: u16) !void {
    const line = f.line(row);
    const on = app.feedLitItem(f);
    const strong = app.feedLit() == .focused;
    const lit = if (on) |o| line.need != null and o.need == line.need and line.step != null and o.step == line.step else false;
    var o: RowOut = .{ .w = w, .pen = pen, .room = inner, .bg = if (line.kind == .try_head) r.panel else if (lit) r.raised else r.tile };
    try o.say(r.text, false, " ");
    switch (line.kind) {
        .try_head => {
            try o.say(r.dim, false, line.text);
            while (o.room > 0) try o.say(r.dim, false, "─");
        },
        .try_title => {
            try o.say(r.text, false, "  ");
            try o.chip(r, r.you, "try", true);
            const age = line.alt;
            const room = o.room -| (cellCount(age) + 2);
            const text = clip(line.text, room);
            try o.say(r.text, false, text);
            try o.say(r.text, false, spaceRun(o.room -| (cellCount(age) + 1)));
            try o.say(if (line.old) r.you else r.dim, line.old, age);
        },
        .try_machine => {
            try o.say(r.text, false, "  ");
            const button = line.alt;
            const space = std.mem.indexOfScalar(u8, button, ' ') orelse button.len;
            const room = o.room -| (if (button.len > 0) cellCount(button) + 5 else @as(usize, 0));
            const text = clip(line.text, room);
            try o.say(r.dim, false, text);
            if (button.len > 0) {
                try o.say(r.text, false, spaceRun(o.room -| (cellCount(button) + 5)));
                try o.button(r, button[0..space], std.mem.trimStart(u8, button[space..], " "), false);
            }
        },
        .try_step => {
            try o.say(if (strong) r.accent else r.dim, true, if (lit) "▌ " else "  ");
            const room = o.room -| (if (line.settled) @as(usize, 2) else 0);
            const text = clip(line.text, room);
            try o.say(if (line.settled) r.dim else r.text, false, text);
            if (line.settled) {
                try o.say(r.text, false, spaceRun(o.room -| 1));
                try o.say(r.dim, false, "✓");
            }
        },
        .try_buttons => {
            if (line.failed) {
                try o.say(r.failed, false, "    ");
                try o.say(r.failed, false, line.text);
            } else {
                try o.say(r.text, false, "  ");
                var primary = true;
                var pieces = std.mem.splitSequence(u8, line.text, "   ");
                while (pieces.next()) |piece| {
                    const space = std.mem.indexOfScalar(u8, piece, ' ') orelse piece.len;
                    try o.button(r, piece[0..space], std.mem.trimStart(u8, piece[space..], " "), primary and strong);
                    primary = false;
                }
            }
        },
        else => {},
    }
    try o.finish();
}

/// Row `row` of the feed atop the orchestrator's column, `inner` cells wide: its line, or past
/// them, the rule under it.
fn feedRow(app: *const App, w: *Writer, pen: *Pen, f: *const feed.Feed, row: usize, inner: u16) !void {
    const dim = ink(app, "dim", 8);
    if (row < f.count()) if (app.roles) |r| switch (f.line(row).kind) {
        .item, .buttons, .refused, .move_head, .strip, .landing_chips, .building_chips => return benchFeedRow(app, w, pen, r, f, row, inner),
        .try_head, .try_title, .try_machine, .try_step, .try_buttons => return benchTryRow(app, w, pen, r, f, row, inner),
        else => {},
    };
    if (row >= f.count()) {
        try pen.set(w, onPanel(app, dim), null);
        for (0..inner) |_| try w.writeAll("─");
        return;
    }
    const line = f.line(row);
    try pen.set(w, onPanel(app, .{}), null);
    try w.writeAll(" ");
    var room: usize = inner -| 1;
    const bar = if (line.failed) ink(app, "emberdim", 1) else ink(app, "amber", 4);
    const lead: []const u8 = switch (line.kind) {
        .item => "▌ ",
        .buttons, .refused => "▌     ",
        .next_refused => "    ",
        .landing_chips, .building_chips, .next_item, .try_step => "  ",
        .try_buttons => "      ",
        else => "",
    };
    if (lead.len > 0 and room > cellCount(lead)) {
        try pen.set(w, onPanel(app, bar), null);
        try w.writeAll(lead);
        room -= cellCount(lead);
    }
    var bold = heading(app);
    bold.flags.bold = true;
    const style: vt.Style = switch (line.kind) {
        .move_head => bold,
        .next_head => ink(app, "amberdim", 8),
        .next_item => .{},
        .quiet, .more, .buttons, .strip, .blank, .try_head, .try_machine => dim,
        .refused, .next_refused => ink(app, "emberdim", 1),
        .try_buttons => if (line.failed) ink(app, "emberdim", 1) else dim,
        .item, .landing_chips, .building_chips, .try_title, .try_step => .{},
    };
    if (room == 0) return;
    // the pick's cells lit: the whole line of a Your move item, a ticket's chip of its own
    var lit_from: usize = 0;
    var lit_to: usize = 0;
    var shown = line.text;
    var marked: [256]u8 = undefined;
    // without Workbench's raised cells, a settled check ends on its mark and a picked tile's machine line on its button
    if (line.kind == .try_step and line.settled) shown = std.fmt.bufPrint(&marked, "{s}  ✓", .{line.text}) catch shown;
    if (line.kind == .try_machine and line.alt.len > 0) shown = std.fmt.bufPrint(&marked, "{s}   {s}", .{ line.text, line.alt }) catch shown;
    if (app.feedLitItem(f)) |on| if (on.line == row) {
        if (line.alt.len > 0) shown = line.alt;
        lit_from = clip(shown, on.at).len;
        lit_to = lit_from + (if (on.w == 0) shown.len - lit_from else clip(shown[lit_from..], on.w).len);
    };
    const cut = cellCount(shown) > room;
    const avail = if (cut) room - 1 else room;
    var used: usize = 0;
    var at: usize = 0;
    while (at < shown.len and used < avail) {
        const run = feedRun(app, line, shown, at, style);
        var end = run.end;
        var run_style = run.style;
        if (lit_from > at) end = @min(end, lit_from);
        if (at >= lit_from and at < lit_to) {
            end = @min(end, lit_to);
            run_style = if (app.feedLit() == .focused) chip(app) else dimLit(app);
        }
        const text = clip(shown[at..end], avail - used);
        if (text.len == 0) break;
        try pen.set(w, onPanel(app, run_style), null);
        try w.writeAll(text);
        used += cellCount(text);
        at += text.len;
    }
    try pen.set(w, onPanel(app, style), null);
    if (cut) try w.writeAll("…");
    for (used + @intFromBool(cut)..room) |_| try w.writeAll(" ");
}

const Run = struct { end: usize, style: vt.Style };

/// The run of one style that starts at byte `at` of a feed line: all of it, but for the chips of
/// landing and building, whose ticket number, repo, age and stage word each have a style of
/// their own. The stage word is coloured as the board's cards colour it.
fn feedRun(app: *const App, line: feed.Line, text: []const u8, at: usize, base: vt.Style) Run {
    const kind = line.kind;
    if (kind == .next_item) return nextRun(app, text, at);
    if (kind != .landing_chips and kind != .building_chips) return .{ .end = text.len, .style = base };
    if (text[at] == ' ') return .{ .end = std.mem.indexOfNonePos(u8, text, at, " ") orelse text.len, .style = .{} };
    // a chip's words, counted from where the run of three spaces before it ends
    var idx: usize = 0;
    var failed = false;
    var pos: usize = 0;
    while (true) {
        const end = std.mem.indexOfScalarPos(u8, text, pos, ' ') orelse text.len;
        if (idx == 0) failed = std.mem.eql(u8, text[pos..end], "✗");
        if (at < end) {
            const word = text[pos..end];
            return .{ .end = end, .style = feedWord(app, kind, word, idx, failed) };
        }
        const next = std.mem.indexOfNonePos(u8, text, end, " ") orelse text.len;
        idx = if (next - end >= 3) 0 else idx + 1;
        pos = next;
    }
}

/// The run of a line of next that starts at `at`: the human's pin and the ticket's number in the
/// card-number accent, its repo dim, then its title or why plain.
fn nextRun(app: *const App, text: []const u8, at: usize) Run {
    const first: usize = @intFromBool(std.mem.startsWith(u8, text, "▪"));
    var idx: usize = 0;
    var pos: usize = 0;
    while (pos < text.len) {
        const end = std.mem.indexOfScalarPos(u8, text, pos, ' ') orelse text.len;
        if (idx > first + 1) break;
        if (at < end) return .{ .end = end, .style = if (idx == first + 1) ink(app, "dim", 8) else ink(app, "amber", 4) };
        const gap = std.mem.indexOfNonePos(u8, text, end, " ") orelse text.len;
        if (at < gap) return .{ .end = gap, .style = .{} };
        idx += 1;
        pos = gap;
    }
    return .{ .end = text.len, .style = .{} };
}

fn feedWord(app: *const App, kind: feed.Kind, word: []const u8, idx: usize, failed: bool) vt.Style {
    const dim = ink(app, "dim", 8);
    const error_ink = ink(app, "emberdim", 1);
    const first: usize = @intFromBool(failed);
    if (word[0] == '+') return dim;
    if (idx < first) return error_ink;
    if (idx == first) return if (failed) error_ink else ink(app, "amber", 4);
    if (idx == first + 1 or word[0] == '+' or isAge(word)) return dim;
    if (failed) return error_ink;
    if (kind == .landing_chips) {
        const stage = stageStyle(app, word);
        return if (stage) |s| s else dim;
    }
    return if (std.mem.eql(u8, word, "▲")) ink(app, "amber", 4) else dim;
}

/// A ticket's age (`3h`) or its place in the queue (`2nd`).
fn isAge(word: []const u8) bool {
    const digits = std.mem.indexOfNone(u8, word, "0123456789") orelse return false;
    return digits > 0 and (std.mem.eql(u8, word[digits..], "m") or std.mem.eql(u8, word[digits..], "h") or
        std.mem.eql(u8, word[digits..], "d") or std.mem.eql(u8, word[digits..], "st") or
        std.mem.eql(u8, word[digits..], "nd") or std.mem.eql(u8, word[digits..], "rd") or std.mem.eql(u8, word[digits..], "th"));
}

/// The orchestrator's column with no window of its in it: its head, and while it is off, how to
/// start it.
fn sideEmpty(app: *const App, w: *Writer) !void {
    const ox = app.term_w - app.view_w;
    var title_buf: [96]u8 = undefined;
    var title_cps: [64]u21 = undefined;
    var right_cps: [24]u21 = undefined;
    var button: ?[2]usize = null;
    var title_len = codepoints(sideHead(app, &title_buf, &button, app.view_w), &title_cps);
    if (title_len + 4 > app.view_w) title_len = 0;
    const right = right_cps[0..codepoints(sideHint(app), &right_cps)];
    const col: Column = .{
        .app = app,
        .w = app.view_w,
        .focused = app.columnFocused(),
        .title = title_cps[0..title_len],
        .mark_at = if (title_len > 0) 1 else null,
        .right = if (title_len + right.len + 6 <= app.view_w) right else right[0..0],
        .button = if (title_len > 0) button else null,
        .roles = app.roles,
    };
    var pen: Pen = .{};
    var the_feed: feed.Feed = undefined;
    const top: usize = if (app.feedOf(&the_feed)) the_feed.height() + 2 else 1;
    const drawn: usize = if (top > 1) the_feed.count() + 2 else 1;
    for (0..app.view_h) |y| {
        try w.print("\x1b[{d};{d}H", .{ y + 1, ox + 1 });
        for (0..app.view_w) |x| {
            if (y == 0 or y + 1 == app.view_h or x == 0 or x + 1 == app.view_w) {
                try col.border(&pen, w, x, @intCast(y));
            } else if (y < drawn) {
                if (x == 1) try feedRow(app, w, &pen, &the_feed, y - 1, app.view_w - 2);
            } else {
                try pen.set(w, onPanel(app, .{}), null);
                try w.writeAll(" ");
            }
        }
    }
    if (app.orchestratorState() != .off) return;
    const off = "orchestrator off · ⏎ start it";
    if (cellCount(off) + 4 > app.view_w) return;
    try pen.set(w, ink(app, "dim", 8), null);
    if (top + 2 >= app.view_h) return;
    try w.print("\x1b[{d};{d}H{s}", .{ top + 2, ox + 3, off });
}

fn codepoints(text: []const u8, out: []u21) usize {
    var n: usize = 0;
    var it = std.unicode.Utf8View.initUnchecked(text).iterator();
    while (it.nextCodepoint()) |cp| : (n += 1) {
        if (n == out.len) break;
        out[n] = cp;
    }
    return n;
}

/// The orchestrator's column's head, on its top edge: its mark, its state in words and the
/// share of its context used, then auto's count as a button, whose cells are `button`.
fn sideHead(app: *const App, buf: []u8, button: *?[2]usize, col_w: usize) []const u8 {
    var out: Writer = .fixed(buf);
    const room = col_w -| 4;
    var full = true;
    while (true) {
        out.end = 0;
        sideHeadInto(app, &out, button, full);
        if (!full or cellCount(out.buffered()) <= room) return out.buffered();
        full = false;
    }
}

fn sideHeadInto(app: *const App, out: *Writer, button: *?[2]usize, full: bool) void {
    const win = app.orchestratorWindow();
    const state = app.orchestratorState();
    const mark: u21 = switch (state) {
        .working => glyph(app, .working),
        .waiting => '▲',
        .stalled => glyph(app, .stalled),
        .idle, .off => '○',
        .restarting => '◌',
    };
    var when: [16]u8 = undefined;
    out.writeAll(" ") catch {};
    put(out, mark) catch {};
    if (!full) {
        sideHeadAuto(app, out, button);
        return;
    }
    out.writeAll(" orchestrator · ") catch {};
    switch (state) {
        .working => out.print("working {s}", .{ago(&when, app.epoch, win.?.since)}) catch {},
        .waiting => out.writeAll("waits on you") catch {},
        .stalled => out.writeAll("stalled") catch {},
        .idle => out.writeAll("idle") catch {},
        .restarting => out.writeAll("restarting") catch {},
        .off => out.writeAll("off") catch {},
    }
    if (win) |it| if (it.ctx > 0) out.print(" · ctx {d}%", .{@min(it.ctx, 999)}) catch {};
    sideHeadAuto(app, out, button);
}

fn sideHeadAuto(app: *const App, out: *Writer, button: *?[2]usize) void {
    button.* = null;
    if (app.board) |*b| if (b.autoState()) |auto| {
        out.writeAll(" ") catch {};
        const from = cellCount(out.buffered());
        (if (auto.on) out.print(" auto {d}/{d} ", .{ auto.working, auto.cap }) else out.writeAll(" auto off ")) catch {};
        button.* = .{ from, cellCount(out.buffered()) };
    };
    out.writeAll(" ") catch {};
}

/// Where auto's button is on the top edge of the orchestrator's column: its first cell from the
/// column's left edge, and its width.
pub fn sideAutoButton(app: *const App) ?struct { x: u16, w: u16 } {
    var buf: [96]u8 = undefined;
    var cells: ?[2]usize = null;
    _ = sideHead(app, &buf, &cells, app.view_w);
    const at = cells orelse return null;
    return .{ .x = @intCast(at[0] + 2), .w = @intCast(at[1] - at[0]) };
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
                    try put(w, glyph(app, mark));
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

fn rowHasText(row: anytype) bool {
    for (row.items(.raw)) |raw| if (raw.hasText() and raw.content.codepoint.data != ' ') return true;
    return false;
}

const popup_keys = " j k scroll  / find  h l next  a ask  r reply  ⏎ go  q ";
const popup_reply_keys = " ⏎ send  esc back ";

/// The popup, about three quarters of the strip each way and centred on it: its head, what the
/// Claude is doing and its context, then the pane's own screen from its bottom, `live` while it
/// follows the pane, and its keys in the foot.
fn popupBox(app: *App, w: *Writer, pop: App.Popup) !void {
    const pane = app.popupPane() orelse return;
    try pane.render.update(app.gpa, &pane.term);
    const pw: u16 = @max(24, app.view_w / 4 * 3);
    const ph: u16 = @max(9, app.view_h / 4 * 3);
    if (pw > app.view_w or ph > app.view_h) return;
    const x0 = app.term_w - app.view_w + (app.view_w - pw) / 2;
    const y0 = (app.view_h - ph) / 2;
    const inner = pw - 2;
    const edge = ink(app, "amber", 4);
    const dim = ink(app, "dim", 8);
    var pen: Pen = .{};
    var buf: [192]u8 = undefined;

    const win: ?*const Window, const session: ?*const Session = switch (pop.entry) {
        .agent => |id| if (app.agentById(id)) |a| .{ a.win, app.sessions.items[a.session] } else .{ null, null },
        .session => |id| .{ if (app.sessionById(id)) |s| s.focused() else null, app.sessionById(id) },
        .fold => .{ null, null },
    };
    var title: Writer = .fixed(&buf);
    title.writeAll(" ") catch {};
    if (win) |it| if (it.agent()) {
        put(&title, agentGlyph(app, it)) catch {};
        title.writeAll(" ") catch {};
        if (app_mod.branchTicket(it.text(.branch))) |n| title.print("#{s} ", .{n}) catch {};
    };
    if (win) |it| title.print("{s}", .{clip(it.label(), 40)}) catch {};
    if (session) |s| title.print(" · {s}", .{clip(s.name, 24)}) catch {};
    if (win) |it| if (it.agent() and it.claude != .none) {
        var ago_buf: [8]u8 = undefined;
        title.print(" · {s} {s}", .{ @tagName(it.claude), ago(&ago_buf, app.epoch, it.since) }) catch {};
    };
    title.writeAll(" ") catch {};

    var info: [192]u8 = undefined;
    var meta: Writer = .fixed(&info);
    if (win) |it| {
        if (it.ctx > 0) meta.print("ctx {d}%", .{@min(it.ctx, 999)}) catch {};
        const branch = it.text(.branch);
        if (branch.len > 0) meta.print("{s}{s}", .{ if (meta.end > 0) " · " else "", clip(branch, 60) }) catch {};
        if (it.subs() > 0) meta.print("{s}{d} subagents", .{ if (meta.end > 0) " · " else "", it.subs() }) catch {};
    }

    const live = App.following(pane);
    // the open question or reply takes three rows off the pane's foot: a rule and two lines
    const lower: u16 = if (pop.mode == .view) 0 else 3;
    var asked: App.Asked = .{};
    const has_ask = pop.mode == .answer and app.popupAsk(pane, &asked);
    var keys_buf: [48]u8 = undefined;
    const foot: []const u8 = switch (pop.mode) {
        .view => popup_keys,
        .answer => std.fmt.bufPrint(&keys_buf, " 1…{d} answer  r reply instead  esc back ", .{asked.n}) catch "",
        .reply => popup_reply_keys,
    };
    const prows = ph - 5 - lower;
    const rows = pane.render.row_data.items(.cells)[pane.render.viewportStart()..];
    if (live) {
        var used = rows.len;
        while (used > 0 and !rowHasText(rows[used - 1])) used -= 1;
        app.popup.?.anchor = used -| prows;
    }
    const first = app.popup.?.anchor;
    for (0..ph) |r| {
        try w.print("\x1b[{d};{d}H", .{ y0 + r + 1, x0 + 1 });
        const top = r == 0;
        const bottom = r == ph - 1;
        const ruled = r == 3 or (lower > 0 and r == ph - 4);
        try pen.set(w, edge, null);
        if (top or bottom or ruled) {
            try w.writeAll(if (top) "╭─" else if (bottom) "╰─" else "├─");
            var used: usize = 2;
            if (top or bottom) {
                try pen.set(w, if (top) heading(app) else dim, null);
                const text = clip(if (top) title.buffered() else foot, inner - 3);
                try w.writeAll(text);
                used += cellCount(text);
                try pen.set(w, edge, null);
            }
            for (used..inner + 1) |_| try w.writeAll("─");
            try w.writeAll(if (top) "╮" else if (bottom) "╯" else "┤");
            continue;
        }
        try w.writeAll("│");
        if (r < 3) {
            try pen.set(w, if (r == 1) .{} else dim, null);
            const text = if (r == 1) (if (win) |it| it.detail() else "") else meta.buffered();
            try w.writeAll(" ");
            try fitted(w, text, inner - 1);
        } else if (lower > 0 and r > ph - 4) {
            try pen.set(w, .{}, null);
            if (r == ph - 3) {
                var line: [320]u8 = undefined;
                var out: Writer = .fixed(&line);
                if (pop.mode == .reply) {
                    out.print(" reply: {s}▏", .{pop.reply[0..pop.reply_len]}) catch {};
                } else out.print(" answer: {s}", .{if (has_ask) asked.question else "no question open"}) catch {};
                try fitted(w, out.buffered(), inner);
            } else if (has_ask) {
                var used: usize = 1;
                try w.writeAll(" ");
                for (asked.options[0..asked.n], 1..) |option, n| {
                    const room = inner -| used;
                    if (room < 6) break;
                    try pen.set(w, heading(app), null);
                    try w.print(" {d} ", .{n});
                    try pen.set(w, .{}, null);
                    const text = clip(option, @min(room - 4, 26));
                    try w.writeAll(text);
                    try w.writeAll("  ");
                    used += 3 + cellCount(text) + 2;
                }
                try fitted(w, "", inner -| used);
            } else try fitted(w, "", inner);
        } else {
            const py = first + (r - 4);
            const tail: usize = if (live and r == ph - 2 - lower) 5 else 0;
            for (0..inner - tail) |tx| try paneCell(app, &pen, w, pane, tx, py, null, false, tx + 1 == inner - tail);
            if (tail > 0) {
                try pen.set(w, dim, null);
                try w.writeAll(" live");
            }
        }
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
        try put(w, sessionGlyph(app, s));
        for (s.wins.items, 0..) |win, wi| {
            const at = app.thumbAt(.{ .session = si, .win = wi }) orelse continue;
            const picked = if (drop) |to| to.session == si and to.win == wi else si == spot.session and wi == spot.win;
            try thumb(app, w, s, win, wi, at.x, at.y, picked);
        }
    }
}

fn planStyle(app: *const App, style: sheets.Style) vt.Style {
    return switch (style) {
        .normal => .{},
        .dim => ink(app, "dim", 8),
        .heading => heading(app),
        .attention => ink(app, "emberdim", 1),
    };
}

/// At half a screen the plan cuts its titles and drops next's whys: the picked row's whole title
/// and why are on the plan's last row.
fn planFoot(app: *App, w: *Writer, sheet: *const sheets.Sheet, pick: usize) !void {
    const given = app.board.?.plan().?;
    const row = sheet.picked(pick);
    var buf: [320]u8 = undefined;
    var text: []const u8 = "";
    if (row) |r| if (r.ticket) |id| {
        for (given.now) |item| if (item.ticket == id) {
            text = std.fmt.bufPrint(&buf, " #{d} {s}  {s}", .{ id, item.repo, item.title }) catch "";
        };
        for (given.next) |item| if (item.ticket == id) {
            text = std.fmt.bufPrint(&buf, " #{d} {s}  {s}{s}{s}", .{ id, item.repo, item.title, if (item.why.len > 0) " — " else "", item.why }) catch "";
        };
        if (text.len == 0) for (given.goals) |goal| if (goal.epic == id) {
            text = std.fmt.bufPrint(&buf, " #{d}  {s}", .{ id, goal.title }) catch "";
        };
    };
    var pen: Pen = .{};
    try w.print("\x1b[{d};{d}H", .{ app.view_h, app.boardX() + 1 });
    try pen.set(w, ink(app, "dim", 8), null);
    try fitted(w, text, app.boardW());
}

/// Home's plan in the board's place: its head, a rule, then its rows from the one the pick keeps
/// in view, the pick a bar at the left edge. What lies over the board lies over it.
fn planView(app: *App, w: *Writer, view: app_mod.BoardView) !void {
    var sheet: sheets.Sheet = undefined;
    if (!app.planSheet(&sheet)) return;
    const ox = app.boardX();
    const width = app.boardW();
    const dim = ink(app, "dim", 8);
    const b = &app.board.?;
    var pen: Pen = .{};
    var buf: [96]u8 = undefined;

    // the head: the title and the way to the board, then babylon's state against the right edge
    try w.print("\x1b[1;{d}H", .{ox + 1});
    try pen.set(w, .{}, null);
    try w.writeAll(" ");
    try pen.set(w, heading(app), null);
    try w.writeAll(App.plan_tab);
    try pen.set(w, dim, null);
    try w.writeAll(App.tab_sep);
    try w.writeAll(App.board_tab);
    if (app.halfHome()) {
        try pen.set(w, .{}, null);
        try w.writeAll("  ");
        try pen.set(w, dim, null);
        try w.writeAll(App.orch_link);
    }
    const given = b.plan().?;
    const auto = if (app.auto()) |state|
        std.fmt.bufPrint(&buf, "◐ auto {d}/{d}", .{ state.working, state.cap }) catch "◐"
    else
        "◐ auto";
    var today_buf: [32]u8 = undefined;
    var needs_buf: [16]u8 = undefined;
    const needs_n = b.needsYou().len;
    const pieces = [_]struct { []const u8, vt.Style }{
        .{ auto, if (app.auto() != null) autoOn(app) else dim },

        .{ std.fmt.bufPrint(&today_buf, "✓ {d} today", .{given.landed_today.count}) catch "", dim },
        .{ std.fmt.bufPrint(&needs_buf, "▲ {d}", .{needs_n}) catch "", if (needs_n > 0) heading(app) else dim },
    };
    // at half a screen the head keeps the way to the column and the board, and what needs the human
    const kept = if (app.halfHome()) pieces[pieces.len - 1 ..] else pieces[0..];
    var right_w: usize = 0;
    for (kept) |piece| right_w += cellCount(piece[0]) + 3;
    const left_w = cellCount(App.plan_title) + if (app.halfHome()) cellCount(App.orch_link) + 2 else 0;
    const start = width -| right_w;
    try pen.set(w, .{}, null);
    if (start > left_w) {
        for (left_w..start) |_| try w.writeAll(" ");
        for (kept) |piece| {
            try pen.set(w, piece[1], null);
            try w.writeAll(piece[0]);
            try pen.set(w, .{}, null);
            try w.writeAll("   ");
        }
    } else for (left_w..width) |_| try w.writeAll(" ");

    try w.print("\x1b[2;{d}H", .{ox + 1});
    try pen.set(w, dim, null);
    for (0..width) |_| try w.writeAll("─");

    const top = app.planTop(&sheet);
    var y: u16 = 2;
    const rows_end = app.view_h - @intFromBool(app.halfHome());
    if (app.halfHome()) try planFoot(app, w, &sheet, view.plan_pick);
    if (app.roles) |r| try benchPlan(app, w, r, &sheet, view, rows_end) else while (y < rows_end) : (y += 1) {
        try w.print("\x1b[{d};{d}H", .{ y + 1, ox + 1 });
        const at = top + (y - 2);
        try pen.set(w, .{}, null);
        if (at >= sheet.n) {
            try fitted(w, "", width);
            continue;
        }
        const row = sheet.rows[at];
        if (app.planRowLit(row)) {
            var bar = if (app.columnFocused()) dim else ink(app, "amber", 4);
            bar.flags.bold = true;
            try pen.set(w, bar, null);
            try w.writeAll("▌");
        } else try w.writeAll(" ");
        const split = @min(row.tail_at, row.text.len);
        try pen.set(w, planStyle(app, row.style), null);
        try w.writeAll(row.text[0..split]);
        try pen.set(w, planStyle(app, if (split < row.text.len) row.tail_style else row.style), null);
        try w.writeAll(row.text[split..]);
        try pen.set(w, .{}, null);
        for (cellCount(row.text) + 1..width) |_| try w.writeAll(" ");
    }
    if (view.detail) |id| try detailBox(app, w, id, view.detail_scroll);
    try autoBox(app, w);
    if (view.goal_open) try goalBox(app, w);
    try draftBox(app, w);
    if (view.help) try helpBox(app, w);
}

const goal_prompt = "what should be true when it's done? as rough as you like";
const goal_field_rows = 4;

/// The `+ goal` modal: its prompt, the field with the idea wrapped in it, the buttons, a dim line
/// of what the first does, babylon's refusal, and the foot with the mode and its keys.
fn goalBox(app: *const App, w: *Writer) !void {
    const rect = app.goalRect() orelse return;
    const modal = &app.goal;
    const inner: u16 = rect.w - 5;
    const x0 = rect.x + 2;
    var lines: [64][]const u8 = undefined;
    const n = goal_mod.wrap(modal.text(), inner -| 1, &lines);
    const first = n -| goal_field_rows;
    var asked: [2][]const u8 = .{ "", "" };
    _ = goal_mod.wrap(goal_prompt, inner, &asked);
    const buttons = App.goalButtons(rect);
    const said = modal.refusal();
    const mode = if (modal.typing) "INSERT" else "NORMAL";
    const keys_text = if (modal.typing) "esc done typing" else "⏎ plan  k keep  i type  q cancel";
    const note = if (modal.busy) "asking babylon…" else "an Opus Claude breaks it out into steps";
    if (app.roles) |r| {
        try bench.window(w, r, rect.x, rect.y, rect.w - 1, rect.h, "a new goal", null, true);
        try bench.say(w, rect.x + rect.w - 4, rect.y, "✕", r.text, r.raised, true);
        for (asked, 0..) |line, i| try bench.say(w, x0, rect.y + 1 + @as(u16, @intCast(i)), line, r.dim, r.panel, false);
        for (0..goal_field_rows) |row| {
            const y = rect.y + 3 + @as(u16, @intCast(row));
            try bench.fill(w, x0, y, inner, r.well);
            if (first + row >= n) {
                if (row == 0 and n == 0 and modal.typing) try bench.say(w, x0, y, "█", r.accent, r.well, false);
                continue;
            }
            const line = lines[first + row];
            try bench.say(w, x0, y, line, r.text, r.well, false);
            if (modal.typing and first + row == n - 1 and cellCount(line) < inner) try bench.say(w, x0 + cellCount(line), y, "█", r.accent, r.well, false);
        }
        for (buttons, 0..) |button, i| {
            const primary = i == 0 and !modal.typing;
            try bench.headButton(w, r, button.x, rect.y + 8, std.fmt.bufPrint(&goal_buf, " {s} ", .{button.label}) catch "", if (modal.typing) r.dim else r.accent, primary);
        }
        try bench.say(w, buttons[0].x, rect.y + 9, clip(note, inner -| 1), r.dim, r.panel, false);
        if (said.len > 0) try bench.say(w, x0, rect.y + 10, clip(said, inner), r.failed, r.panel, true);
        try bench.say(w, x0, rect.y + 11, mode, if (modal.typing) r.you else r.accent, r.panel, true);
        try bench.say(w, x0 + 8, rect.y + 11, clip(keys_text, inner -| 8), r.dim, r.panel, false);
        return;
    }
    const edge = ink(app, "amber", 4);
    const dim = ink(app, "dim", 8);
    var pen: Pen = .{};
    try pen.set(w, edge, null);
    try w.print("\x1b[{d};{d}H╭─", .{ rect.y + 1, rect.x + 1 });
    try pen.set(w, heading(app), null);
    try w.writeAll(" a new goal ");
    try pen.set(w, edge, null);
    for (15..rect.w) |_| try w.writeAll("─");
    try w.writeAll("╮");
    for (1..rect.h - 1) |row| {
        var text: []const u8 = "";
        var style: vt.Style = .{};
        switch (row) {
            1, 2 => {
                text = asked[row - 1];
                style = dim;
            },
            3...6 => if (first + row - 3 < n) {
                text = lines[first + row - 3];
            },
            8 => text = std.fmt.bufPrint(&goal_buf, "{s}   {s}   {s}", .{ buttons[0].label, buttons[1].label, buttons[2].label }) catch "",
            9 => {
                text = note;
                style = dim;
            },
            10 => {
                text = if (said.len > 0) said else keys_text;
                style = if (said.len > 0) ink(app, "emberdim", 1) else dim;
            },
            else => {},
        }
        try boxLine(w, &pen, edge, style, rect.x, rect.y + @as(u16, @intCast(row)) + 1, text, inner);
    }
    try pen.set(w, edge, null);
    try w.print("\x1b[{d};{d}H╰", .{ rect.y + rect.h, rect.x + 1 });
    for (0..rect.w - 2) |_| try w.writeAll("─");
    try w.writeAll("╯");
    try pen.set(w, dim, null);
    try w.print("\x1b[{d};{d}H {s} ", .{ rect.y + rect.h, rect.x + 3, mode });
}

var goal_buf: [64]u8 = undefined;

fn repeat(w: *Writer, x: usize, y: usize, cell_glyph: []const u8, n: usize, fg: color.RGB, bg: color.RGB) !void {
    var buf: [1024]u8 = undefined;
    var out: Writer = .fixed(&buf);
    for (0..n) |_| out.writeAll(cell_glyph) catch break;
    try bench.say(w, x, y, out.buffered(), fg, bg, false);
}

/// The plan's rows in Workbench's look, from `rows_end` up: seven windows, each in the slot
/// the screen's size gives it, a goal a card with its bar. A window shown whole is a modal over
/// them, and what is behind it is drawn as it was.
fn benchPlan(app: *App, w: *Writer, r: theme.Roles, sheet: *const sheets.Sheet, view: app_mod.BoardView, rows_end: u16) !void {
    var y: u16 = 2;
    while (y < rows_end) : (y += 1) try bench.fill(w, app.boardX(), y, app.boardW(), r.ground);
    if (view.whole == null) {
        for (std.enums.values(sheets.Window)) |win| try benchWindow(app, w, r, sheet, view, win, true);
        return;
    }
    var behind: sheets.Sheet = undefined;
    const b = &app.board.?;
    behind.build(b.plan().?, b, app.boardW() -| 1, app.epoch, view.unfolded, app.halfHome(), true, app.plan_shut);
    for (std.enums.values(sheets.Window)) |win| try benchWindow(app, w, r, &behind, view, win, false);
    try benchWindow(app, w, r, sheet, view, view.whole.?, true);
}

fn windowCount(given: *const tickets.Plan, win: sheets.Window) ?usize {
    return switch (win) {
        .driving => null,
        .now => given.now.len,
        .next => given.next.len,
        .goals => given.goals.len - @intFromBool(for (given.goals) |goal| {
            if (given.driving == goal.epic) break true;
        } else false),
        .unplanned => given.not_planned.count,
        .landed => given.landed_today.count,
    };
}

/// `win` in its slot (or the modal, when it is the one shown whole): its frame, fold mark and
/// the rows from the one that keeps the pick in view. `lit` is whether the pick is drawn.
fn benchWindow(app: *App, w: *Writer, r: theme.Roles, sheet: *const sheets.Sheet, view: app_mod.BoardView, win: sheets.Window, lit: bool) !void {
    const rect = app.planRect(win);
    const whole = lit and view.whole == win;
    if (rect.h <= sheets.window_chrome or rect.w < 16) return;
    const given = app.board.?.plan().?;
    const ww: usize = rect.w - 1;
    const body: usize = rect.h - sheets.window_chrome;
    const mine = sheet.span(win);
    const picked_at = if (lit) sheet.rowOf(view.plan_pick) else null;
    const focused = !app.columnFocused() and (if (picked_at) |at| sheet.rows[at].win == win else false);
    try bench.window(w, r, rect.x, rect.y, ww, rect.h - 1, if (win == .driving) sheets.drivingTitle(given, &app.board.?) else win.title(), windowCount(given, win), focused);
    const bar = if (focused) r.raised else r.tile;
    if (whole) {
        try bench.say(w, rect.x + ww - 10, rect.y, "q close", r.dim, bar, false);
    } else try bench.say(w, rect.x + ww - 3, rect.y, if (app.plan_shut.contains(win)) "▸" else "▾", r.dim, bar, false);
    if (win == .goals and !whole) {
        const head = app.goalHead();
        try bench.headButton(w, r, head.x, head.y, " + goal ", r.accent, false);
    }
    if (win == .driving and !app.plan_shut.contains(win) and sheets.driveLanded(given, &app.board.?) == null) if (sheets.focalGoal(given)) |at| {
        const goal = given.goals[at];
        var buf: [160]u8 = undefined;
        const text = std.fmt.bufPrint(&buf, "epic #{d}{s}{s}", .{ goal.epic, if (goal.doc != null) " · " else "", goal.doc orelse "" }) catch "";
        try bench.say(w, rect.x + 34, rect.y, clip(text, ww -| 38), r.dim, bar, false);
    };
    const top = if (lit) app.planWindowTop(sheet, win, body) else 0;
    for (0..body) |line| {
        if (top + line >= mine.len) break;
        try benchPlanRow(app, w, r, sheet, mine.start + top + line, rect.y + 1 + @as(u16, @intCast(line)), rect.x, ww, lit);
    }
}

fn stepHue(r: theme.Roles, state: []const u8) struct { word: []const u8, lead: color.RGB, filled: bool } {
    const eql = std.mem.eql;
    if (eql(u8, state, "building")) return .{ .word = "building", .lead = r.building, .filled = false };
    if (eql(u8, state, "landing")) return .{ .word = "landing", .lead = r.checking, .filled = false };
    if (eql(u8, state, "reviewing") or eql(u8, state, "verifying")) return .{ .word = state, .lead = r.checking, .filled = false };
    if (eql(u8, state, "failed") or eql(u8, state, "sent_back")) return .{ .word = "sent back", .lead = r.failed, .filled = true };
    if (eql(u8, state, "next")) return .{ .word = "next", .lead = r.dim, .filled = false };
    if (eql(u8, state, "to_try")) return .{ .word = "▲ to try", .lead = r.you, .filled = true };
    return .{ .word = "todo", .lead = r.dim, .filled = false };
}

fn goalHue(b: *const tickets.Board, r: theme.Roles, goal: tickets.Goal) color.RGB {
    for (b.cards()) |card| if (card.id == goal.epic) return repoHue(r, card.repo).hue;
    for (goal.steps) |step| for (b.cards()) |card| if (card.id == step.ticket) return repoHue(r, card.repo).hue;
    return r.dim;
}

/// A step as a chip at (`x`, `y`): its number and where it is.
fn stepChip(w: *Writer, r: theme.Roles, x: usize, y: usize, step: tickets.Step) !usize {
    const look = stepHue(r, step.state);
    var buf: [48]u8 = undefined;
    const label = std.fmt.bufPrint(&buf, "#{d} {s}", .{ step.ticket, look.word }) catch "";
    return bench.chipInk(w, r, x, y, label, look.lead, if (look.filled) r.on_accent else r.text, look.filled);
}

/// The row at `at` of the plan, drawn on row `y`, in a window one cell in from the board's left
/// edge and short of its right by the shadow.
fn benchPlanRow(app: *App, w: *Writer, r: theme.Roles, sheet: *const sheets.Sheet, at: usize, y: u16, x0: usize, ww: usize, lit: bool) !void {
    const b = &app.board.?;
    const given = b.plan().?;
    const row = sheet.rows[at];
    const picked = lit and app.planRowLit(row);
    const mark = if (app.columnFocused()) r.dim else r.accent;
    const bg = if (picked) r.raised else r.panel;
    const room = ww - 4;
    switch (row.kind) {
        .blank => {},
        .buttons => {
            try bench.fill(w, x0, y, ww, r.panel);
            var buttons: [12]App.PlanButton = undefined;
            for (app.planButtons(sheet, at, &buttons), 0..) |button, i| {
                _ = try bench.button(w, r, button.x, button.y, button.key, button.word, i == 0, null);
            }
        },
        .head => {
            try bench.fill(w, x0, y, ww, r.panel);
            var buf: [48]u8 = undefined;
            const label = std.fmt.bufPrint(&buf, "── {s} {d} ", .{ row.text, row.count }) catch "";
            try bench.say(w, x0 + 1, y, label, r.dim, r.panel, false);
            try repeat(w, x0 + 1 + cellCount(label), y, "─", ww -| 2 -| cellCount(label), r.dim, r.panel);
        },
        .summary, .note => {
            try bench.fill(w, x0, y, ww, bg);
            if (picked) try bench.say(w, x0, y, "▌", mark, bg, true);
            try bench.say(w, x0 + 2, y, clip(row.text, room), r.dim, bg, false);
        },
        .focal => {
            const goal = given.goals[row.item];
            const hue = goalHue(b, r, goal);
            {
                try bench.fill(w, x0, y, ww, bg);
                if (picked) try bench.say(w, x0, y, "▌", mark, bg, true);
                try bench.say(w, x0 + 1, y, "▌", hue, bg, false);
                switch (row.part) {
                    1 => {
                        const shares = try goalChips(w, r, b, goal, x0 + ww, y);
                        try bench.say(w, x0 + 2, y, clip(goal.title, room -| shares), r.text, bg, true);
                    },
                    2 => {
                        var buf: [32]u8 = undefined;
                        const label = std.fmt.bufPrint(&buf, "{d}/{d} landed", .{ goal.landed, goal.total }) catch "";
                        const bar_w = ww -| 5 -| cellCount(label);
                        try bench.bar(w, r, x0 + 2, y, bar_w, goal.landed, goal.total, hue);
                        try bench.say(w, x0 + 3 + bar_w, y, label, r.text, bg, false);
                    },
                    else => {
                        try bench.say(w, x0 + 2, y, "now", r.dim, bg, false);
                        var x = x0 + 6;
                        var flying: usize = 0;
                        for (goal.steps) |step| flying += @intFromBool(sheets.inFlight(step));
                        var shown: usize = 0;
                        for (goal.steps) |step| {
                            if (!sheets.inFlight(step)) continue;
                            if (x + 20 > x0 + ww) break;
                            if (shown > 0) {
                                try bench.say(w, x, y, "─▶ ", r.dim, bg, false);
                                x += 3;
                            }
                            x += try stepChip(w, r, x, y, step);
                            shown += 1;
                        }
                        if (shown < flying) {
                            var buf: [16]u8 = undefined;
                            try bench.say(w, x + 1, y, std.fmt.bufPrint(&buf, "+{d} more", .{flying - shown}) catch "", r.dim, bg, false);
                        }
                    },
                }
            }
            try bench.say(w, x0 + ww, y, "▌", r.well, r.ground, false);
        },
        .drove => {
            try bench.fill(w, x0, y, ww, bg);
            try bench.say(w, x0 + 1, y, "▌", r.accent, bg, false);
            switch (row.part) {
                1 => {
                    if (picked) try bench.say(w, x0, y, "▌", mark, bg, true);
                    try bench.say(w, x0 + 2, y, clip(row.text, room), r.text, bg, true);
                },
                2 => try bench.say(w, x0 + 2, y, row.text, r.dim, bg, false),
                else => {
                    const need = sheets.driveLanded(given, b).?;
                    var x = x0 + 2;
                    for (0..need.actions.len + 1) |i| {
                        var lbl: [96]u8 = undefined;
                        const label = sheets.driveButton(&lbl, need, i);
                        if (x + cellCount(label) + 2 > x0 + ww) break;
                        x += try bench.chipInk(w, r, x, y, label, if (i == need.actions.len) r.accent else r.dim, r.text, false) + 1;
                    }
                },
            }
        },
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
                try bench.say(w, title_x, y, clip(item.title, chip_x - title_x - 1), r.text, bg, false);
            } else try bench.say(w, title_x, y, clip(item.title, x0 + ww -| title_x -| 1), r.text, bg, false);
        },
        .next => {
            const item = given.next[row.item];
            try bench.fill(w, x0, y, ww, bg);
            if (picked) try bench.say(w, x0, y, "▌", mark, bg, true);
            var nb: [16]u8 = undefined;
            try bench.say(w, x0 + 2, y, std.fmt.bufPrint(&nb, "{d}", .{row.item + 1}) catch "", r.dim, bg, false);
            const repo = repoHue(r, item.repo);
            var idb: [16]u8 = undefined;
            const id = std.fmt.bufPrint(&idb, "#{d}", .{item.ticket}) catch "";
            try bench.say(w, x0 + 1, y, "▌", repo.hue, bg, false);
            try bench.say(w, x0 + 4, y, repo.glyph, repo.hue, bg, false);
            try bench.say(w, x0 + 6, y, id, repo.hue, bg, true);
            var lbuf: [48]u8 = undefined;
            const first = tickets.Wait.first(item.waits_on);
            const label = if (first) |wt| if (wt.ticket) |t|
                std.fmt.bufPrint(&lbuf, "\u{f0c1} waits #{d}", .{t}) catch "waits"
            else
                std.fmt.bufPrint(&lbuf, "\u{f0c1} after #{d}", .{wt.until.?}) catch "waits" else "ready";
            const chip_x = x0 + ww -| (cellCount(label) + 3);
            const title_x = x0 + 7 + cellCount(id);
            const pin_w: usize = if (item.pinned()) 2 else 0;
            _ = try bench.chipInk(w, r, chip_x, y, label, if (first == null) r.landed else r.dim, if (first == null) r.text else r.dim, false);
            if (item.pinned()) try bench.say(w, chip_x -| 2, y, "\u{f08d}", r.accent, bg, false);
            try bench.say(w, title_x, y, clip(item.title, chip_x -| title_x -| 1 -| pin_w), r.text, bg, false);
            try bench.say(w, x0 + ww, y, "▌", r.well, r.ground, false);
        },
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
                try bench.say(w, title_x, y, clip(idea.title, chip_x - title_x - 1), r.text, bg, false);
            } else try bench.say(w, title_x, y, clip(idea.title, right -| title_x), r.text, bg, false);
        },
        .ideas_more => {
            try bench.fill(w, x0, y, ww, bg);
            if (picked) try bench.say(w, x0, y, "▌", mark, bg, true);
            try bench.say(w, x0 + 2, y, clip(std.mem.trim(u8, row.text, " "), room), r.dim, bg, false);
        },
        .why, .more, .goals_more => {
            try bench.fill(w, x0, y, ww, r.panel);
            try bench.say(w, x0 + 7, y, clip(std.mem.trim(u8, row.text, " "), room -| 5), r.dim, r.panel, false);
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
                    try bench.say(w, cx + 2 + cellCount(id), y, clip(goal.title, cw -| 4 -| cellCount(id) -| shares), r.text, face, true);
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
        .landed => {
            const today = given.landed_today;
            const face = bg;
            try bench.fill(w, x0, y, ww, face);
            if (picked) try bench.say(w, x0, y, "▌", mark, face, true);
            var buf: [48]u8 = undefined;
            const head = std.fmt.bufPrint(&buf, "✓ landed today {d}", .{today.count}) catch "";
            try bench.say(w, x0 + 2, y, head, r.landed, face, true);
            var x = x0 + 3 + cellCount(head);
            for (today.newest[0..@min(today.newest.len, 5)]) |id| {
                var idb: [16]u8 = undefined;
                const text = std.fmt.bufPrint(&idb, "#{d}", .{id}) catch "";
                if (x + cellCount(text) + 4 > x0 + ww) break;
                try bench.say(w, x, y, "──", r.dim, face, false);
                const hue = for (b.cards()) |card| {
                    if (card.id == id) break repoHue(r, card.repo).hue;
                } else r.dim;
                try bench.say(w, x + 3, y, text, hue, face, true);
                x += cellCount(text) + 4;
            }
        },
    }
}

/// A goal whose steps are in more than one repo: a chip for each, right-aligned to `right`, with
/// its landed and total steps there. The cells they take, with a gap; none for a goal of one
/// repo, whose edge says it.
fn goalChips(w: *Writer, r: theme.Roles, b: *const tickets.Board, goal: tickets.Goal, right: usize, y: u16) !usize {
    var landed: [theme.Roles.repo_names.len]usize = @splat(0);
    var total: [theme.Roles.repo_names.len]usize = @splat(0);
    var repos: usize = 0;
    for (goal.steps) |step| {
        const card = for (b.cards()) |card| {
            if (card.id == step.ticket) break card;
        } else continue;
        const at = for (theme.Roles.repo_names, 0..) |name, i| {
            if (std.mem.eql(u8, name, card.repo orelse "")) break i;
        } else continue;
        repos += @intFromBool(total[at] == 0);
        total[at] += 1;
        landed[at] += @intFromBool(std.mem.eql(u8, step.state, "landed"));
    }
    if (repos < 2) return 0;
    var x = right;
    var taken: usize = 0;
    for (theme.Roles.repo_names, 0..) |_, i| {
        if (total[i] == 0) continue;
        var buf: [24]u8 = undefined;
        const label = std.fmt.bufPrint(&buf, "{s} {d}/{d}", .{ repo_glyphs[i], landed[i], total[i] }) catch "";
        const width = cellCount(label) + 2;
        if (taken + width + 1 > right / 2) break;
        x -= width + 1;
        taken += width + 1;
        _ = try bench.chipInk(w, r, x, y, label, r.repo[i], r.text, false);
    }
    return taken;
}

/// Nerd Font glyphs, one a repo, in `Roles.repo_names`' order.
const repo_glyphs = [_][]const u8{ "\u{f120}", "\u{f1b3}", "\u{f013}", "\u{f0ad}", "\u{f015}" };

fn repoHue(r: theme.Roles, repo: ?[]const u8) struct { glyph: []const u8, hue: color.RGB } {
    for (theme.Roles.repo_names, 0..) |name, i| if (std.mem.eql(u8, name, repo orelse "")) return .{ .glyph = repo_glyphs[i], .hue = r.repo[i] };
    return .{ .glyph = "\u{f10c}", .hue = r.dim };
}

/// The board in Workbench's look: its columns windows, their cards tiles, and the last closed a
/// strip along its foot.
fn benchBoard(app: *App, w: *Writer, r: theme.Roles, view: app_mod.BoardView) !void {
    const ox = app.boardX();
    for (App.first_line - 1..app.view_h) |y| try bench.tabRow(w, r, ox, @intCast(y), app.boardW());
    try benchEpics(app, w, r);
    const lanes = app.boardLanes();
    for (0..app.boardCols()) |c| {
        const cw = app.boardColW(c);
        if (cw < 8) continue;
        const x = app.boardColX(c);
        const total = if (lanes) app.boardCount(tickets.statuses[c]) else app.boardColumnAll(c);
        const lit = if (app.drag == .card) app.cardTarget() == (if (app.boardBacklog()) tickets.Status.backlog else tickets.statuses[c]) else c == view.col and !app.columnFocused();
        try bench.window(w, r, x, app.colTop() - 1, cw - 1, app.listH() - app.colTop(), app.columnName(c), total, lit);
        if (total == 0) try bench.say(w, x + 2, app.colTop(), "none", r.dim, r.panel, false);
        try benchLines(app, w, r, view, c, x, cw);
    }
    if (app.footRows() > 0) try benchRecent(app, w, r, view);
    try benchBar(app, w, r);
    if (app.drag == .card) try benchHeld(app, w, r);
}

/// The epics along the board's top, side by side as slim bars: `◆ #N title` over a bar in its
/// repo's hue, `landed/total`, and a chip when a child is being built. An epic is never a card.
fn benchEpics(app: *const App, w: *Writer, r: theme.Roles) !void {
    const goals = app.epicBars();
    if (goals.len == 0) return;
    const b = &app.board.?;
    const n = goals.len;
    const gap = App.epic_gap;
    const slot = (app.boardW() -| 2 - gap * (n - 1)) / n;
    const y = App.first_line - 1;
    for (goals, 0..) |goal, i| {
        const x = app.boardX() + 1 + i * (slot + gap);
        const progress = b.epicProgress(goal.epic) orelse continue;
        const hue = goalHue(b, r, goal);
        var building: usize = 0;
        for (b.cards()) |card| building += @intFromBool(card.epic_id == goal.epic and card.status == .doing);
        var head: [24]u8 = undefined;
        const id = std.fmt.bufPrint(&head, "◆ #{d} ", .{goal.epic}) catch "";
        try bench.say(w, x, y, id, hue, r.ground, true);
        try bench.say(w, x + cellCount(id), y, clip(goal.title, slot -| cellCount(id)), r.text, r.ground, false);
        var count: [24]u8 = undefined;
        const label = std.fmt.bufPrint(&count, "{d}/{d}", .{ progress.landed, progress.total }) catch "";
        var chip_buf: [24]u8 = undefined;
        const chip_text = std.fmt.bufPrint(&chip_buf, "{d} building", .{building}) catch "";
        const chip_w = cellCount(chip_text) + 5;
        const with_chip = building > 0 and slot >= 24 + chip_w;
        const tail = cellCount(label) + 1 + if (with_chip) chip_w + 1 else 0;
        const bar_w = slot -| tail;
        try bench.bar(w, r, x, y + 1, bar_w, progress.landed, progress.total, hue);
        try bench.say(w, x + bar_w + 1, y + 1, label, r.text, r.ground, false);
        if (with_chip) _ = try bench.chipInk(w, r, x + bar_w + 2 + cellCount(label), y + 1, chip_text, r.accent, r.text, false);
    }
}

/// The board's last row: its keys, each a chip with the key in amber, in three groups with a rule
/// between; babylon's word of a drop or a report is said in its place.
fn benchBar(app: *const App, w: *Writer, r: theme.Roles) !void {
    if (app.barRows() == 0) return;
    const y = app.view_h - 1;
    try bench.fill(w, app.boardX(), y, app.boardW(), r.ground);
    if (app.report_said != null and !app.feedFocused()) {
        const room = app.boardW() -| 2;
        try bench.say(w, app.boardX() + 1, y, clip(app.report_said.?, room), if (app.report_failed) r.failed else r.accent, r.ground, false);
        return;
    }
    var keys: [24]App.BarKey = undefined;
    for (app.keyBar(&keys)) |k| {
        if (k.group) try bench.say(w, k.x - 2, y, "│", r.dim, r.ground, false);
        try bench.say(w, k.x, y, " ", r.text, r.raised, false);
        try bench.say(w, k.x + 1, y, k.key, r.accent, r.raised, true);
        try bench.say(w, k.x + 1 + cellCount(k.key), y, " ", r.text, r.raised, false);
        try bench.say(w, k.x + 2 + cellCount(k.key), y, k.word, r.text, r.raised, false);
        try bench.say(w, k.x + 2 + cellCount(k.key) + cellCount(k.word), y, " ", r.text, r.raised, false);
    }
}

/// The card being dragged, under the pointer.
fn benchHeld(app: *const App, w: *Writer, r: theme.Roles) !void {
    const card = app.cardById(app.drag.card.id) orelse return;
    var buf: [160]u8 = undefined;
    const text = std.fmt.bufPrint(&buf, " #{d} {s} ", .{ card.id, card.title }) catch return;
    const x = app.pointer.x + 1;
    const room = app.term_w -| x;
    try bench.say(w, x, app.pointer.y, clip(text, @min(room, 32)), r.text, r.card(true), true);
}

fn benchLines(app: *const App, w: *Writer, r: theme.Roles, view: app_mod.BoardView, c: usize, x: u16, cw: u16) !void {
    var lines = App.ColumnLines.init(app, c);
    for (0..app.columnScroll(c)) |_| _ = lines.next();
    var y: u16 = app.colTop();
    while (y + 1 < app.listH()) : (y += 1) {
        const at = lines.next() orelse break;
        switch (at.what) {
            .heading => try benchHeading(w, r, app.laneRepo(at.lane).?, app.laneCounts(at.lane, c).total, at.lane == view.lane and c == view.col, foldMark(app, at.lane), x + 1, y, cw -| 3),
            .more => {
                var buf: [24]u8 = undefined;
                const n = app.groupCounts(at.lane, c);
                try bench.say(w, x + 2, y, std.fmt.bufPrint(&buf, "↓ {d} more", .{n.total - n.shown}) catch "", r.dim, r.panel, false);
            },
            .card => |spot| {
                const card = app.groupCard(at.lane, c, spot.row).?;
                if (app.boardStrip(c)) {
                    var buf: [160]u8 = undefined;
                    const trying = card.status == .@"try";
                    const text = std.fmt.bufPrint(&buf, "{s} #{d} {s}", .{ if (trying) "▲" else "✓", card.id, card.title }) catch card.title;
                    const lit = app.cardPicked(at.lane, c, spot.row) and !app.columnFocused();
                    try bench.say(w, x + 2, y, clip(text, cw -| 5), if (lit) r.accent else if (trying) r.you else r.dim, r.panel, lit);
                } else try benchTile(app, w, r, card, spot.part, app.cardPicked(at.lane, c, spot.row), x + 1, y, cw - 3, cw);
            },
        }
    }
}

/// What a group's heading says after its name: whether it is folded, and whether a card in it
/// waits on the human, which a fold must not hide.
fn foldMark(app: *const App, lane: usize) []const u8 {
    const folded = app.folded(app.laneRepo(lane) orelse "");
    const needs = app.laneNeeds(lane);
    return if (folded and needs) " ▸ ▲" else if (folded) " ▸" else if (needs) " ▾ ▲" else " ▾";
}

/// A repo's heading row in a column of `width` cells at `x`: its glyph and name in its hue, a dim
/// dashes, and its count of cards there.
fn benchHeading(w: *Writer, r: theme.Roles, repo: []const u8, count: usize, lit: bool, fold: []const u8, x: usize, y: usize, width: usize) !void {
    var buf: [24]u8 = undefined;
    const num = std.fmt.bufPrint(&buf, "{d}", .{count}) catch "";
    const mark = repoHue(r, repo);
    const name = clip(if (repo.len == 0) "no repo" else repo, width -| (cellCount(num) + 6 + cellCount(fold)));
    try bench.say(w, x + 1, y, mark.glyph, mark.hue, r.panel, false);
    try bench.say(w, x + 3, y, name, mark.hue, r.panel, true);
    try bench.say(w, x + 3 + cellCount(name), y, fold, if (std.mem.endsWith(u8, fold, "▲")) r.you else r.dim, r.panel, false);
    const from = x + 4 + cellCount(name) + cellCount(fold);
    const to = x + width -| (cellCount(num) + 1);
    var dashes: [128]u8 = undefined;
    var out: Writer = .fixed(&dashes);
    if (to > from) for (from..to) |_| out.writeAll("─") catch break;
    try bench.say(w, from, y, out.buffered(), if (lit) r.accent else r.dim, r.panel, false);
    try bench.say(w, @max(from, to) + 1, y, num, r.dim, r.panel, false);
}

/// What a card says of where it is, as a chip: a question open, sent back, proposed, where the
/// pipeline has it, what it waits on, who holds it.
fn benchState(app: *const App, card: *const tickets.Card, r: theme.Roles, buf: []u8) ?struct { label: []const u8, lead: color.RGB, words: color.RGB, filled: bool } {
    const eql = std.mem.eql;
    const stage = card.stage orelse "";
    if (card.proposal != null) return .{ .label = "▲ proposed", .lead = r.you, .words = r.on_accent, .filled = true };
    if (card.status == .@"try") return .{ .label = "▲ try it", .lead = r.you, .words = r.on_accent, .filled = true };
    if (card.isEpic()) {
        const got = if (app.board) |*b| b.epicProgress(card.id) else null;
        const label = if (got) |g| std.fmt.bufPrint(buf, "◆ epic {d}/{d}", .{ g.landed, g.total }) catch "◆ epic" else "◆ epic";
        return .{ .label = label, .lead = r.dim, .words = r.text, .filled = false };
    }
    if (card.ask != null and !eql(u8, stage, "queued")) return .{ .label = "▲ asks you", .lead = r.you, .words = r.on_accent, .filled = true };
    if (eql(u8, stage, "failed")) return .{ .label = "\u{f0e2} sent back", .lead = r.failed, .words = r.on_accent, .filled = true };
    if (stage.len > 0 and !(eql(u8, stage, "queued") and card.ask != null)) {
        const mark: []const u8, const lead = if (eql(u8, stage, "queued")) .{ "\u{f017}", r.queued } else if (eql(u8, stage, "verifying")) .{ "\u{f00c}", r.checking } else if (eql(u8, stage, "reviewing")) .{ "\u{f06e}", r.checking } else if (eql(u8, stage, "landed")) .{ "\u{f135}", r.landed } else .{ "\u{f017}", r.dim };
        var inner: [64]u8 = undefined;
        const said = cardStage(app, card, 0, stage, &inner);
        return .{ .label = std.fmt.bufPrint(buf, "{s} {s}", .{ mark, said }) catch said, .lead = lead, .words = r.text, .filled = false };
    }
    if (card.blocked_by.len > 0) return .{ .label = std.fmt.bufPrint(buf, "\u{f0c1} waits #{d}", .{card.blocked_by[0]}) catch "waits", .lead = r.dim, .words = r.dim, .filled = false };
    if (card.status == .doing) return if (card.holder() != null)
        .{ .label = "\u{f013} building", .lead = r.building, .words = r.text, .filled = false }
    else
        .{ .label = "\u{f10c} no Claude", .lead = r.failed, .words = r.text, .filled = false };
    return null;
}

/// An epic's progress as words, `epic · 3/7 landed` after `lead`, `epic` alone when the board has no count for it.
fn epicWords(app: *const App, card: *const tickets.Card, lead: []const u8, buf: []u8) []const u8 {
    const progress = if (app.board) |*b| b.epicProgress(card.id) else null;
    const got = progress orelse return std.fmt.bufPrint(buf, "{s}epic", .{lead}) catch "epic";
    return std.fmt.bufPrint(buf, "{s}epic · {d}/{d} landed", .{ lead, got.landed, got.total }) catch "epic";
}

/// Row `part` of a card as a tile at `x` and `tw` cells wide, in a column `col_w` wide: the bevel,
/// its title on two rows at most, then its chips. The picked one is raised, with a row for its
/// buttons and its shadow.
fn benchTile(app: *const App, w: *Writer, r: theme.Roles, card: *const tickets.Card, part: usize, picked: bool, x: u16, y: u16, tw: usize, col_w: u16) !void {
    const bg = r.card(picked);
    const text_w = App.tileTextW(col_w);
    const edge = repoHue(r, card.repo).hue;
    var count: usize = 0;
    var counted = app_mod.TitleLines.init(card.title, text_w);
    while (counted.next()) |_| count += 1;
    const t: usize = @max(1, @min(count, App.tile_title_rows));
    if (picked and part >= 1 and part <= t + 2) try bench.say(w, x + tw, y, "▌", r.well, r.panel, false);
    if (part == 0) {
        try bench.bevel(w, x, y, tw, if (picked) r.text.mix(bg, 0.5) else r.card(true), bg);
    } else if (part <= t) {
        try bench.fill(w, x, y, tw, bg);
        try bench.say(w, x, y, "▎", edge, bg, false);
        var lines = app_mod.TitleLines.init(card.title, text_w);
        var line: []const u8 = "";
        for (0..part) |_| line = lines.next() orelse "";
        const cut = part == App.tile_title_rows and count > App.tile_title_rows;
        var buf: [200]u8 = undefined;
        const shown = if (cut) (std.fmt.bufPrint(&buf, "{s}…", .{clip(line, text_w -| 1)}) catch line) else line;
        try bench.say(w, x + 1, y, shown, if (card.blocked_by.len > 0) r.dim else r.text, bg, true);
        if (part == 1) {
            const high = std.mem.eql(u8, card.priority, "high");
            const low = std.mem.eql(u8, card.priority, "low");
            try bench.say(w, x + tw - 2, y, if (high) "●" else if (low) "○" else "◉", if (high) r.failed else r.dim, bg, false);
        }
    } else if (part == t + 1) {
        try bench.fill(w, x, y, tw, bg);
        try bench.say(w, x, y, "▎", edge, bg, false);
        try benchChips(app, w, r, card, x + 1, y, tw - 2);
    } else if (picked and part == t + 2) {
        try bench.fill(w, x, y, tw, bg);
    } else if (picked and part == t + 3) {
        var under: [256]u8 = undefined;
        var out: Writer = .fixed(&under);
        for (0..@min(tw, 80)) |_| out.writeAll("▀") catch break;
        try bench.say(w, x + 1, y, out.buffered(), r.well, r.panel, false);
    }
}

/// A tile's chip row in `room` cells from `x`: the repo's glyph and the number in its hue, where
/// the card is, its model, and how long it has been filed or held.
fn benchChips(app: *const App, w: *Writer, r: theme.Roles, card: *const tickets.Card, x: u16, y: u16, room: usize) !void {
    var at = x;
    const end = x + room;
    var buf: [96]u8 = undefined;
    var state_buf: [96]u8 = undefined;
    const mark = repoHue(r, card.repo);
    const id = std.fmt.bufPrint(&buf, "{s} {d}", .{ mark.glyph, card.id }) catch "";
    at += @as(u16, @intCast(try bench.chipOn(w, at, y, id, mark.hue, mark.hue, false, r.well)));
    if (benchState(app, card, r, &state_buf)) |state| if (at + cellCount(state.label) + 2 <= end) {
        at += 1;
        at += @as(u16, @intCast(try bench.chipOn(w, at, y, state.label, state.lead, state.words, state.filled, r.well)));
    };
    if (card.model) |model| if (at + cellCount(modelName(model)) + 3 <= end) {
        at += 1;
        at += @as(u16, @intCast(try bench.chipAt(w, r, at, y, modelName(model), r.dim, r.well)));
    };
    if (card.handed_off_from) |pane| {
        const text = std.fmt.bufPrint(&buf, "↩ {s}", .{pane}) catch "";
        if (at + cellCount(text) + 3 <= end) {
            at += 1;
            at += @as(u16, @intCast(try bench.chipAt(w, r, at, y, text, r.dim, r.well)));
        }
    }
    var age: [8]u8 = undefined;
    var said: [24]u8 = undefined;
    const since: []const u8 = switch (card.status) {
        .todo => if (tickets.epochOf(card.inserted_at)) |t| ago(&age, app.epoch, @intCast(@max(1, t))) else "",
        .doing => if (card.claimedAt()) |t| ago(&age, app.epoch, @intCast(@max(1, t))) else "",
        else => "",
    };
    if (since.len > 0) {
        const text = std.fmt.bufPrint(&said, "{s}{s}", .{ if (card.status == .todo) "filed " else "", since }) catch since;
        if (at + 1 + cellCount(text) + 2 <= end) _ = try bench.chipAt(w, r, at + 1, y, text, r.dim, r.well);
    }
}

/// The recent strip along the foot: a title bar, a timeline of the last closed with how long ago
/// each, and under it each one's number and title. The picked one is lit and has its button.
fn benchRecent(app: *App, w: *Writer, r: theme.Roles, view: app_mod.BoardView) !void {
    const y0 = app.listH();
    const x = app.boardX();
    const focused = view.col == 3 and !app.columnFocused();
    var total: usize = 0;
    if (app.board != null) total = app.columnOf(.done, app.boardRepo(), app.findText(), &.{});
    try bench.titleBar(w, r, x, y0, app.boardW(), "recent", focused);
    var nbuf: [16]u8 = undefined;
    _ = try bench.chip(w, r, x + 4 + "recent".len, y0, std.fmt.bufPrint(&nbuf, "{d}", .{total}) catch "", r.dim, false);
    var cards: [App.strip_n]*const tickets.Card = undefined;
    const n = app.stripCards(&cards);
    const picked_id: ?u32 = if (view.col == 3) (if (app.boardCard(view.col, view.row)) |c| c.id else null) else null;
    const span_w = app.stripCell();
    for (cards[0..n], 0..) |card, k| {
        const cx = x + @as(u16, @intCast(k)) * span_w;
        const lit = picked_id == card.id and !app.columnFocused();
        const landed = card.stage != null and std.mem.eql(u8, card.stage.?, "landed");
        var age: [8]u8 = undefined;
        const since = if (tickets.epochOf(card.closed_at)) |t| ago(&age, app.epoch, @intCast(@max(1, t))) else "";
        var buf: [200]u8 = undefined;
        const trying = card.status == .@"try";
        const head = if (trying) "▲ try it " else std.fmt.bufPrint(&buf, "{s} {s} ", .{ if (landed) "◆" else "✓", since }) catch "◆";
        try bench.say(w, cx + 1, y0 + 1, head, if (lit) r.accent else if (trying) r.you else if (landed) r.landed else r.dim, r.ground, lit);
        var dashes: [256]u8 = undefined;
        var out: Writer = .fixed(&dashes);
        for (@min(cx + 1 + cellCount(head), cx + span_w)..cx + span_w) |_| out.writeAll("─") catch break;
        try bench.say(w, cx + 1 + cellCount(head), y0 + 1, out.buffered(), r.dim, r.ground, false);
        const id = std.fmt.bufPrint(&buf, "#{d}", .{card.id}) catch "";
        const hue = repoHue(r, card.repo).hue;
        try bench.say(w, cx + 1, y0 + 2, id, hue, r.ground, true);
        try bench.say(w, cx + 2 + cellCount(id), y0 + 2, clip(card.title, span_w -| (cellCount(id) + 3)), if (lit) r.text else r.dim, r.ground, lit);
    }
}

/// babylon's board in place of the strip: a row naming the repo it is narrowed to and its keys,
/// then a column a status, each a box of its cards, a card a box of its own: the ticket's number
/// and title on two rows, a footer of what else is so of it, its left edge its priority, and
/// the picked one's border lit.
fn boardView(app: *App, w: *Writer, view: app_mod.BoardView) !void {
    if (app.planShown()) return planView(app, w, view);
    const ox = app.boardX();
    const dim = ink(app, "dim", 8);
    const edge: vt.Style = .{ .fg_color = .palette(8) };
    var pen: Pen = .{};
    var buf: [160]u8 = undefined;

    if (app.roles) |r| {
        try bench.titleBar(w, r, ox, 0, app.boardW(), "", true);
        const plan_at = ox + 1;
        const board_at = plan_at + cellCount(App.plan_tab) + cellCount(App.tab_sep);
        try bench.say(w, plan_at, 0, App.plan_tab ++ App.tab_sep, r.dim, r.raised, false);
        try bench.say(w, board_at, 0, App.board_tab, r.text, r.raised, true);
        try bench.tabRow(w, r, ox, 1, app.boardW());
    } else {
        try w.print("\x1b[1;{d}H", .{ox + 1});
        try pen.set(w, .{}, null);
        try w.writeAll(" ");
        try pen.set(w, dim, null);
        try w.writeAll(App.plan_tab ++ App.tab_sep);
        try pen.set(w, heading(app), null);
        try w.writeAll(App.board_tab);
        try pen.set(w, .{}, null);
        try fitted(w, "", app.boardW() -| cellCount(App.board_title));
    }

    if (app.roles) |r| {
        try benchBoard(app, w, r, view);
        return benchOver(app, w, view);
    }
    const lanes = app.boardLanes();
    for (0..app.boardCols()) |c| {
        const name = app.columnName(c);
        const x = app.boardColX(c);
        const inner = app.boardColW(c) -| 2;
        const total = if (lanes) app.boardCount(tickets.statuses[c]) else app.boardColumnAll(c);
        const label = std.fmt.bufPrint(&buf, " {s} {d} ", .{ name, total }) catch "";
        try pen.set(w, edge, null);
        try w.print("\x1b[{d};{d}H╭─", .{ app.colTop(), x + 1 });
        try pen.set(w, dim, null);
        const shown = clip(label, inner -| 1);
        try w.writeAll(shown);
        try pen.set(w, edge, null);
        for (@min(cellCount(shown) + 1, inner)..inner) |_| try w.writeAll("─");
        try w.writeAll("╮");
        try columnLines(app, w, &pen, view, c, x, inner);
        if (total == 0 and app.view_h > 3) {
            try pen.set(w, dim, null);
            try w.print("\x1b[{d};{d}H", .{ app.colTop() + 1, x + 2 });
            try fitted(w, " none", inner);
            try pen.set(w, edge, null);
        }
        try w.print("\x1b[{d};{d}H╰", .{ app.view_h, x + 1 });
        for (0..inner) |_| try w.writeAll("─");
        try w.writeAll("╯");
    }
    try benchOver(app, w, view);
}

/// What lies over the board's columns: its buttons, the find line and the boxes opened on it.
fn benchOver(app: *App, w: *Writer, view: app_mod.BoardView) !void {
    try boardButtons(app, w, view);
    _ = try findLine(app, w);
    if (view.answering) if (app.pickedCard()) |card| if (card.ask) |ask| try askBox(app, w, card.id, ask);
    if (view.giving) |picked| if (app.pickedCard()) |card| try giveBox(app, w, card.id, picked);
    if (view.detail) |id| try detailBox(app, w, id, view.detail_scroll);
    try autoBox(app, w);
    try draftBox(app, w);
    if (view.help) try helpBox(app, w);
}

const DraftTone = enum { plain, dim, pick };

/// A draft's modal: the epic's outcome, its steps one a row with repo, model and what each waits
/// on, the pick marked, and the foot's keys.
fn draftBox(app: *const App, w: *Writer) !void {
    const rect = app.draftRect() orelse return;
    const view = app.board_view.?;
    const epic = view.draft.?;
    var list: [App.draft_max]*const tickets.Card = undefined;
    const steps = app.draftSteps(epic, &list);
    var head: [32]u8 = undefined;
    const title = std.fmt.bufPrint(&head, "☐ draft #{d}", .{epic}) catch "draft";
    if (app.roles) |r| {
        try bench.window(w, r, rect.x, rect.y, rect.w - 1, rect.h, title, null, true);
        try bench.say(w, rect.x + rect.w - 4, rect.y, "✕", r.text, r.raised, true);
    } else {
        const edge = ink(app, "amber", 4);
        var pen: Pen = .{};
        try pen.set(w, edge, null);
        try w.print("\x1b[{d};{d}H╭─ ", .{ rect.y + 1, rect.x + 1 });
        try pen.set(w, heading(app), null);
        try w.writeAll(title);
        try pen.set(w, edge, null);
        try w.writeAll(" ");
        for (cellCount(title) + 4..rect.w -| 1) |_| try w.writeAll("─");
        try w.writeAll("╮");
        try w.print("\x1b[{d};{d}H╰", .{ rect.y + rect.h, rect.x + 1 });
        for (2..rect.w) |_| try w.writeAll("─");
        try w.writeAll("╯");
    }
    try draftLine(app, w, rect, 1, app.draftTitle(epic), .plain);
    var count: [200]u8 = undefined;
    const body = if (app.draftIdea(epic)) |idea| idea.body else "";
    const quote = if (body.len == 0)
        std.fmt.bufPrint(&count, "{d} steps", .{steps.len}) catch ""
    else
        std.fmt.bufPrint(&count, "from your idea: \"{s}\"", .{clip(body, 150)}) catch "";
    try draftLine(app, w, rect, 2, quote, .dim);
    const asks = app.draftAsks(epic);
    const shown = @min(steps.len, rect.h -| 6 -| asks.len);
    for (asks, 0..) |ask, i| {
        var line: [300]u8 = undefined;
        const text = if (ask.answer) |answer|
            std.fmt.bufPrint(&line, "asked you: \"{s}\" you: \"{s}\"", .{ clip(ask.question, 100), clip(answer, 60) }) catch ""
        else
            std.fmt.bufPrint(&line, "asked you: \"{s}\" (open)", .{clip(ask.question, 100)}) catch "";
        try draftLine(app, w, rect, @intCast(4 + shown + i), text, .dim);
    }
    for (steps[0..shown], 0..) |step, i| {
        var row: [200]u8 = undefined;
        var waits: [48]u8 = undefined;
        const wait: []const u8 = if (step.blocked_by.len == 0) "free" else std.fmt.bufPrint(&waits, "← #{d}{s}", .{ step.blocked_by[0], if (step.blocked_by.len > 1) " …" else "" }) catch "";
        const model = step.model orelse "";
        const short = if (std.mem.startsWith(u8, model, "claude-")) model["claude-".len..] else model;
        const word = short[0 .. std.mem.indexOfScalar(u8, short, '-') orelse short.len];
        var lead: [64]u8 = undefined;
        const front = std.fmt.bufPrint(&lead, "{d} #{d} {s: <10} {s: <7} ", .{ i + 1, step.id, clip(step.repo orelse "", 10), word }) catch "";
        const room = (rect.w -| 5) -| cellCount(front) -| cellCount(wait) -| 2;
        const named = clip(step.title, room);
        const text = std.fmt.bufPrint(&row, "{s}{s}  {s}", .{ front, named, wait }) catch "";
        try draftLine(app, w, rect, @intCast(3 + i), text, if (i == view.draft_pick) .pick else .plain);
    }
    try draftLine(app, w, rect, rect.h - 2, "y go   r reply with changes   e edit a step   space its ticket   q close", .dim);
}

fn draftLine(app: *const App, w: *Writer, rect: App.ModalRect, row: u16, text: []const u8, tone: DraftTone) !void {
    const inner: u16 = rect.w - 5;
    if (app.roles) |r| {
        const y = rect.y + row;
        const ink_of = switch (tone) {
            .plain, .pick => r.text,
            .dim => r.dim,
        };
        if (tone == .pick) try bench.say(w, rect.x + 1, y, "▌", r.accent, r.panel, true);
        try bench.say(w, rect.x + 2, y, clip(text, inner), ink_of, r.panel, tone == .pick);
        return;
    }
    var pen: Pen = .{};
    const style: vt.Style = switch (tone) {
        .plain => .{},
        .dim => ink(app, "dim", 8),
        .pick => heading(app),
    };
    try boxLine(w, &pen, ink(app, "amber", 4), style, rect.x, rect.y + 1 + row, text, inner);
}

/// A ticket's whole detail over the board, as babylon gave it, its lines cut to the box's width
/// and run on under one another, scrolled `scroll` rows down.
fn detailBox(app: *const App, w: *Writer, id: u32, scroll: usize) !void {
    if (app.board_view.?.gate) return gateBox(app, w, id, scroll);
    const rect = app.modalRect() orelse return;
    if (app.roles) |r| return benchDetail(app, w, r, id, rect, scroll);
    const inner = app_mod.detailWidth(app.boardW()).inner;
    const x = rect.x;
    const top = rect.y + 1;
    const bottom = rect.y + rect.h;
    var buf: [24]u8 = undefined;
    const title = std.fmt.bufPrint(&buf, " #{d} ", .{id}) catch " detail ";
    if (rect.w < cellCount(title) + 3) return;
    const edge = ink(app, "amber", 4);
    var pen: Pen = .{};

    const dim = ink(app, "dim", 8);
    const note = doneNote(app, id);
    var note_rows: u16 = 0;
    var counted = app_mod.DetailLines.init(note, inner);
    if (note.len > 0) while (counted.next()) |_| {
        if (note_rows < bottom - top - 2) note_rows += 1;
    };
    const card = app.modalCard();
    var head: App.CardHead = .{};
    if (card) |it| App.cardHead(it, inner, app.epoch, app.askWords(it) != null, &head);
    const win = if (card) |it| app.claudeOf(it) else null;
    const claude_rows: u16 = if (win != null and bottom - top - 2 > note_rows + head.n + 1) 1 else 0;
    const text_end = bottom - note_rows - claude_rows;

    var y = top + 1;
    for (head.lines[0..head.n], head.kinds[0..head.n]) |line, kind| {
        if (y >= text_end) break;
        const style: vt.Style = switch (kind) {
            .plain, .options => .{},
            .dim, .check => dim,
            .warn => ink(app, "amber", 4),
        };
        try boxLine(w, &pen, edge, style, x, y, line, inner);
        y += 1;
    }
    const text = if (app.detail.items.len > 0) app.detail.items else "…";
    var row: usize = 0;
    const parts = [2]struct { text: []const u8, style: vt.Style }{
        .{ .text = if (card) |it| it.stage_note else "", .style = dim },
        .{ .text = text, .style = .{} },
    };
    for (parts) |part| {
        if (part.text.len == 0) continue;
        var lines = app_mod.DetailLines.init(part.text, inner);
        while (lines.next()) |line| : (row += 1) {
            if (row < scroll or y >= text_end) continue;
            try boxLine(w, &pen, edge, part.style, x, y, line, inner);
            y += 1;
        }
    }
    while (y < text_end) : (y += 1) try boxLine(w, &pen, edge, .{}, x, y, "", inner);
    if (claude_rows > 0) if (win) |it| {
        var ago_buf: [8]u8 = undefined;
        var said: [320]u8 = undefined;
        const state = if (it.claude == .none) "" else @tagName(it.claude);
        const line = std.fmt.bufPrint(&said, "its Claude: {s} {s} · {s}", .{ state, ago(&ago_buf, app.epoch, it.since), it.detail() }) catch "its Claude";
        try boxLine(w, &pen, edge, dim, x, y, line, inner);
        y += 1;
    };
    var noted = app_mod.DetailLines.init(note, inner);
    while (y < bottom) : (y += 1) try boxLine(w, &pen, edge, dim, x, y, noted.next() orelse "", inner);
    try modalFrame(app, w, rect, title, " j k scroll ");
}

/// A switch as text: the knob right when on.
fn knobText(on: bool) []const u8 {
    return if (on) "▐ ●▌" else "▐● ▌";
}

/// Auto's settings over the board: auto as a switch, how many of its cap work, hold as a switch,
/// and each repo's cap as a stepper, `paused` at 0, with the Claudes working it. The foot says
/// babylon's refusal, else the keys. Its rows are where `App.autoClick` looks.
fn autoBox(app: *const App, w: *Writer) !void {
    const rect = app.autoRect() orelse return;
    const view = app.board_view.?;
    const pick = view.auto_pick.?;
    const state = app.board.?.autoState() orelse tickets.Auto{};
    const on = app.auto() != null;
    const hold = app.holding();
    const rows = @min(app.autoRepos(), App.autoRoom(rect));
    const stepper = app.autoStepper(rect);
    const x0 = rect.x + 2;
    const foot = rect.y + rect.h - 1;
    var line: [96]u8 = undefined;
    const said = app.auto_wants.refused;
    const hint = " j k pick   + - step   a auto   H hold   esc close ";
    const working = std.fmt.bufPrint(&line, "working {d} of {d}", .{ state.working, state.cap }) catch "";
    if (app.roles) |r| {
        try bench.window(w, r, rect.x, rect.y, rect.w - 1, rect.h, "auto", null, true);
        try bench.say(w, rect.x + rect.w - 4, rect.y, "✕", r.text, r.raised, true);
        _ = try bench.toggle(w, r, x0, rect.y + 1, "auto", on, r.panel);
        try bench.say(w, x0 + 10, rect.y + 1, if (on) "on" else "off", if (on) r.accent else r.dim, r.panel, pick == 0);
        try bench.say(w, x0, rect.y + 2, working, r.dim, r.panel, false);
        _ = try bench.toggle(w, r, x0, rect.y + 3, "hold", hold, r.panel);
        try bench.say(w, x0 + 10, rect.y + 3, if (hold) "on" else "off", if (hold) r.accent else r.dim, r.panel, pick == 1);
        if (pick < 2) try bench.say(w, rect.x + 1, rect.y + 1 + 2 * @as(u16, @intCast(pick)), "▌", r.accent, r.panel, true);
        for (0..rows) |i| {
            const repo = app.autoRepo(i) orelse continue;
            const y = rect.y + 5 + @as(u16, @intCast(i));
            const picked = pick == 2 + i;
            if (picked) try bench.say(w, rect.x + 1, y, "▌", r.accent, r.panel, true);
            try bench.say(w, x0, y, repo.name, if (picked) r.text else r.dim, r.panel, picked);
            try bench.say(w, stepper.minus, y, "[-]", r.accent, r.tile, true);
            const value = std.fmt.bufPrint(&line, "{d:^3}", .{repo.cap}) catch "";
            try bench.say(w, stepper.minus + 3, y, value, r.text, r.panel, true);
            try bench.say(w, stepper.plus, y, "[+]", r.accent, r.tile, true);
            const n = feed.working(&app.board.?, repo.name);
            const note = if (repo.cap == 0) "paused" else std.fmt.bufPrint(&line, "{d} working", .{n}) catch "";
            try bench.say(w, stepper.plus + 4, y, note, if (repo.cap == 0) r.failed else r.dim, r.panel, false);
        }
        if (said) |text| {
            try bench.say(w, x0, foot, clip(text, rect.w -| 5), r.failed, r.panel, true);
        } else if (cellCount(hint) < rect.w -| 4) try bench.say(w, x0, foot, hint, r.dim, r.panel, false);
        return;
    }
    const edge = ink(app, "amber", 4);
    const dim = ink(app, "dim", 8);
    const name_w = stepper.minus - 2 - x0;
    const inner = rect.w -| 4;
    var pen: Pen = .{};
    try pen.set(w, edge, null);
    try w.print("\x1b[{d};{d}H╭─", .{ rect.y + 1, rect.x + 1 });
    try pen.set(w, heading(app), null);
    try w.writeAll(" auto ");
    try pen.set(w, edge, null);
    for (9..rect.w) |_| try w.writeAll("─");
    try w.writeAll("╮");
    var y: u16 = 1;
    while (y < rect.h - 1) : (y += 1) {
        var buf: [160]u8 = undefined;
        var style: vt.Style = .{};
        var text: []const u8 = "";
        if (y == 1 or y == 3) {
            const picked = pick == (y - 1) / 2;
            const set = if (y == 1) on else hold;
            style.flags.bold = picked;
            text = std.fmt.bufPrint(&buf, "{s}  {s} {s}", .{ if (y == 1) "auto" else "hold", knobText(set), if (set) "on" else "off" }) catch "";
        } else if (y == 2) {
            style = dim;
            text = working;
        } else if (y >= 5 and y - 5 < rows) {
            const i = y - 5;
            const repo = app.autoRepo(i) orelse continue;
            var tail: [32]u8 = undefined;
            const note = if (repo.cap == 0) "paused" else std.fmt.bufPrint(&tail, "{d} working", .{feed.working(&app.board.?, repo.name)}) catch "";
            style.flags.bold = pick == 2 + i;
            text = std.fmt.bufPrint(&buf, "{s}{s}  [-]{d:^3}[+]  {s}", .{ repo.name, spaces[0..name_w -| cellCount(repo.name)], repo.cap, note }) catch "";
        }
        try boxLine(w, &pen, edge, style, rect.x, rect.y + y + 1, text, inner);
    }
    try pen.set(w, edge, null);
    try w.print("\x1b[{d};{d}H╰─", .{ rect.y + rect.h, rect.x + 1 });
    for (3..rect.w) |_| try w.writeAll("─");
    try w.writeAll("╯");
    const foot_text = if (said) |text| clip(text, rect.w -| 5) else hint;
    if (cellCount(foot_text) + 3 < rect.w) {
        try pen.set(w, if (said != null) ink(app, "emberdim", 1) else dim, null);
        try w.print("\x1b[{d};{d}H{s}", .{ rect.y + rect.h, rect.x + 3, foot_text });
    }
    try pen.set(w, .{}, null);
}

const spaces: [64]u8 = @splat(' ');

/// The card's modal in Workbench's look: a window over the board with its shadow and `✕`, the
/// title whole, the facts as chips, the open ask as a violet band with its options as buttons,
/// the body, and the card's actions as buttons along the foot. Its rows are `modalButtons`'.
fn benchDetail(app: *const App, w: *Writer, r: theme.Roles, id: u32, rect: App.ModalRect, scroll: usize) !void {
    const inner = app_mod.detailWidth(app.boardW()).inner;
    const x0 = rect.x + 2;
    const foot = rect.y + rect.h - 1;
    var tbuf: [48]u8 = undefined;
    const card = app.modalCard();
    const title = std.fmt.bufPrint(&tbuf, "#{d} \u{b7} {s}", .{ id, if (card) |it| it.repo orelse "no repo" else "" }) catch "";
    try bench.window(w, r, rect.x, rect.y, rect.w - 1, rect.h, title, null, true);
    try bench.say(w, rect.x + rect.w - 4, rect.y, "✕", r.text, r.raised, true);

    var head: App.CardHead = .{};
    if (card) |it| App.cardHead(it, inner, app.epoch, app.askWords(it) != null, &head);
    const note = doneNote(app, id);
    var note_rows: u16 = 0;
    var counted = app_mod.DetailLines.init(note, inner);
    while (counted.next()) |_| {
        if (note_rows < foot - rect.y - 3) note_rows += 1;
    }
    const win = if (card) |it| app.claudeOf(it) else null;
    const claude_rows: u16 = if (win != null and foot - rect.y - 3 > note_rows + head.n + 1) 1 else 0;
    const text_end = foot - 1 - note_rows - claude_rows;

    var buttons: [16]App.ModalButton = undefined;
    const modal = app.modalButtons(&buttons);
    var y = rect.y + 1;
    var band = false;
    var facts = false;
    for (head.lines[0..head.n], head.kinds[0..head.n], 0..) |line, kind, at| {
        if (y >= text_end) break;
        if (kind == .warn) band = true;
        const bg = if (band) r.tile else r.panel;
        if (band) try bench.fill(w, rect.x + 1, y, rect.w - 3, bg);
        switch (kind) {
            .plain => try bench.say(w, x0, y, clip(line, inner), r.text, bg, true),
            .dim => if (facts) {
                try bench.say(w, x0, y, clip(line, inner), r.dim, bg, false);
            } else {
                facts = true;
                try benchFacts(app, w, r, card.?, x0, y, inner);
            },
            .warn => try bench.say(w, x0, y, clip(line, inner), r.you, bg, true),
            .check => {
                const settled = card.?.checks[at - head.checks.?].result != null;
                const lit = at - head.checks.? + 1 == @min(@max(app.board_view.?.check_pick, 1), card.?.checks.len);
                try bench.say(w, x0, y, clip(line, inner), if (lit) r.accent else if (settled) r.dim else r.text, bg, lit);
            },
            .options => for (modal) |button| if ((button.action == .option or button.action == .words) and button.y == y) {
                const lit = button.action == .option and button.action.option == app.board_view.?.ask_pick;
                _ = try bench.button(w, r, button.x, y, button.key, button.label, lit, r.tile);
            },
        }
        y += 1;
    }
    if (band and y < text_end) {
        try bench.fill(w, rect.x + 1, y, rect.w - 3, r.tile);
        y += 1;
    }

    const text = if (app.detail.items.len > 0) app.detail.items else "…";
    var row: usize = 0;
    const parts = [2]struct { text: []const u8, fg: color.RGB }{
        .{ .text = if (card) |it| it.stage_note else "", .fg = r.dim },
        .{ .text = text, .fg = r.text },
    };
    for (parts) |part| {
        if (part.text.len == 0) continue;
        var lines = app_mod.DetailLines.init(part.text, inner);
        while (lines.next()) |line| : (row += 1) {
            if (row < scroll or y >= text_end) continue;
            try bench.say(w, x0, y, clip(line, inner), part.fg, r.panel, false);
            y += 1;
        }
    }
    y = text_end;
    if (claude_rows > 0) if (win) |it| {
        var ago_buf: [8]u8 = undefined;
        var said: [320]u8 = undefined;
        const state = if (it.claude == .none) "" else @tagName(it.claude);
        const line = std.fmt.bufPrint(&said, "its Claude: {s} {s} \u{b7} {s}", .{ state, ago(&ago_buf, app.epoch, it.since), it.detail() }) catch "its Claude";
        try bench.say(w, x0, y, clip(line, inner), r.dim, r.panel, false);
        y += 1;
    };
    var noted = app_mod.DetailLines.init(note, inner);
    while (noted.next()) |line| {
        if (y >= foot - 1) break;
        try bench.say(w, x0, y, clip(line, inner), r.dim, r.panel, false);
        y += 1;
    }

    var end = x0;
    var primary = true;
    for (modal) |button| {
        if ((button.action == .option or button.action == .words) and button.y != foot) continue;
        _ = try bench.button(w, r, button.x, button.y, button.key, button.label, primary and button.action != .close, r.ground);
        if (button.action != .close) primary = false;
        end = button.x + button.width() + 1;
    }
    const hint = " j k scroll ";
    if (end + cellCount(hint) < rect.x + rect.w - 2) try bench.say(w, end, foot, hint, r.dim, r.panel, false);
}

/// A card's facts as a row of chips from `x`, as many as `room` cells have: its repo, priority,
/// where it is, model, who holds it, and how long it has been filed and held.
fn benchFacts(app: *const App, w: *Writer, r: theme.Roles, card: *const tickets.Card, x: u16, y: u16, room: u16) !void {
    var at = x;
    const end = x + room;
    var sbuf: [96]u8 = undefined;
    var lbuf: [96]u8 = undefined;
    const mark = repoHue(r, card.repo);
    const high = std.mem.eql(u8, card.priority, "high");
    const low = std.mem.eql(u8, card.priority, "low");
    const state = benchState(app, card, r, &sbuf);
    const held = if (card.heldBy()) |pane| std.fmt.bufPrint(&lbuf, "held {s}", .{pane}) catch "" else "";
    var hbuf: [48]u8 = undefined;
    const handed = if (card.handed_off_from) |pane| std.fmt.bufPrint(&hbuf, "handed off from {s}", .{pane}) catch "" else "";
    var filed: [8]u8 = undefined;
    var claimed: [8]u8 = undefined;
    var fbuf: [24]u8 = undefined;
    var cbuf: [24]u8 = undefined;
    const filed_text = if (tickets.epochOf(card.inserted_at)) |t| std.fmt.bufPrint(&fbuf, "filed {s}", .{ago(&filed, app.epoch, @intCast(@max(1, t)))}) catch "" else "";
    const claimed_text = if (card.claimedAt()) |t| std.fmt.bufPrint(&cbuf, "held {s}", .{ago(&claimed, app.epoch, @intCast(@max(1, t)))}) catch "" else "";
    const items = [_]struct { label: []const u8, lead: color.RGB, words: color.RGB, filled: bool }{
        .{ .label = if (card.repo) |repo| repo else "no repo", .lead = mark.hue, .words = mark.hue, .filled = false },
        .{ .label = if (high) "● high" else if (low) "○ low" else "◉ med", .lead = if (high) r.failed else r.dim, .words = r.text, .filled = false },
        if (state) |s| .{ .label = s.label, .lead = s.lead, .words = s.words, .filled = s.filled } else .{ .label = @tagName(card.status), .lead = r.dim, .words = r.text, .filled = false },
        .{ .label = if (card.model) |m| modelName(m) else "", .lead = r.dim, .words = r.text, .filled = false },
        .{ .label = held, .lead = r.dim, .words = r.text, .filled = false },
        .{ .label = handed, .lead = r.dim, .words = r.text, .filled = false },
        .{ .label = filed_text, .lead = r.dim, .words = r.text, .filled = false },
        .{ .label = claimed_text, .lead = r.dim, .words = r.text, .filled = false },
    };
    for (items) |item| {
        if (item.label.len == 0 or at + cellCount(item.label) + 2 > end) continue;
        at += @as(u16, @intCast(try bench.chipInk(w, r, at, y, item.label, item.lead, item.words, item.filled))) + 1;
    }
}

/// Seconds as a stage's time reads: `4s`, `1m 58s`.
fn took(buf: []u8, secs: i64) []const u8 {
    const s = @max(0, secs);
    return (if (s < 60) std.fmt.bufPrint(buf, "{d}s", .{s}) else std.fmt.bufPrint(buf, "{d}m {d}s", .{ @divFloor(s, 60), @mod(s, 60) })) catch "";
}

/// The gate's modal: ticket `id`'s last run as a row a stage with its mark, its result and its
/// time, then under a rule the output of the first stage that failed, else the review's verdict,
/// and last what is queued behind it. `scroll` rows down the output.
fn gateBox(app: *const App, w: *Writer, id: u32, scroll: usize) !void {
    const rect = app.modalRect() orelse return;
    const inner = app_mod.detailWidth(app.boardW()).inner;
    const bottom = rect.y + rect.h;
    var title_buf: [32]u8 = undefined;
    const title = std.fmt.bufPrint(&title_buf, " gate · #{d} ", .{id}) catch " gate ";
    if (rect.w < cellCount(title) + 3) return;
    const edge = ink(app, "amber", 4);
    const dim = ink(app, "dim", 8);
    var pen: Pen = .{};
    const run = app_mod.gateLastRun(if (app.detail.items.len > 0) app.detail.items else "");
    var y = rect.y + 2;
    var output = app_mod.gateOutput(run);
    for (app_mod.gate_stages) |name| {
        var line_buf: [256]u8 = undefined;
        var dur_buf: [16]u8 = undefined;
        const stage = app_mod.gateStage(run, name);
        const mark: []const u8, const style: vt.Style = if (stage) |s| blk: {
            if (std.mem.eql(u8, s.result, "failed") or std.mem.eql(u8, s.result, "error")) break :blk .{ "✗", ink(app, "emberdim", 1) };
            if (s.end == null) break :blk .{ "◒", ink(app, "amber", 4) };
            break :blk .{ "✓", .{} };
        } else .{ "·", dim };
        const dur = if (stage) |s| (if (tickets.epochOf(s.start)) |from| took(&dur_buf, (tickets.epochOf(s.end) orelse app.epoch) - from) else "") else "";
        const result = if (stage) |s| s.result else "";
        const head = std.fmt.bufPrint(&line_buf, "{s} {s: <8} {s}", .{ mark, name, result }) catch name;
        const room = inner -| (cellCount(dur) + 1);
        var row: [320]u8 = undefined;
        var out: Writer = .fixed(&row);
        const shown = clip(head, room);
        out.writeAll(shown) catch {};
        for (cellCount(shown)..inner -| cellCount(dur)) |_| out.writeAll(" ") catch {};
        out.writeAll(dur) catch {};
        try boxLine(w, &pen, edge, style, rect.x, y, out.buffered(), inner);
        y += 1;
    }
    var bar: [1024]u8 = undefined;
    var ruler: Writer = .fixed(&bar);
    for (0..inner) |_| ruler.writeAll("─") catch {};
    try boxLine(w, &pen, edge, dim, rect.x, y, ruler.buffered(), inner);
    y += 1;

    var queued: [256]u8 = undefined;
    var q: Writer = .fixed(&queued);
    var waiting: usize = 0;
    if (app.board) |*b| for (b.cards()) |card| {
        const stage = card.stage orelse continue;
        if (card.id == id or !std.mem.eql(u8, stage, "queued")) continue;
        q.print("{s}#{d} {s}", .{ if (waiting == 0) "queued behind it: " else ", ", card.id, card.repo orelse "" }) catch {};
        waiting += 1;
    };
    const last = if (waiting > 0 and y + 1 < bottom) bottom - 1 else bottom;
    if (run.len == 0) output = "…";
    var row_at: usize = 0;
    var lines = std.mem.splitScalar(u8, output, '\n');
    while (lines.next()) |raw| {
        const text = if (std.mem.startsWith(u8, raw, "    ")) raw[4..] else raw;
        var wrapped = app_mod.DetailLines.init(text, inner);
        var any = false;
        while (wrapped.next()) |line| : (row_at += 1) {
            any = true;
            if (row_at < scroll or y >= last) continue;
            try boxLine(w, &pen, edge, .{}, rect.x, y, line, inner);
            y += 1;
        }
        if (!any) {
            if (row_at >= scroll and y < last) {
                try boxLine(w, &pen, edge, .{}, rect.x, y, "", inner);
                y += 1;
            }
            row_at += 1;
        }
    }
    while (y < last) : (y += 1) try boxLine(w, &pen, edge, .{}, rect.x, y, "", inner);
    if (last < bottom) try boxLine(w, &pen, edge, dim, rect.x, last, q.buffered(), inner);
    try modalFrame(app, w, rect, title, if (app.board_view.?.withdrawing) " W again to withdraw " else " j k scroll ");
}

/// The modal frame every thing opens in: the rounded box at `rect` with its head in the top edge
/// and, in the bottom edge, the open modal's buttons, then `hint`.
fn modalFrame(app: *const App, w: *Writer, rect: App.ModalRect, head: []const u8, hint: []const u8) !void {
    const edge = ink(app, "amber", 4);
    var pen: Pen = .{};
    const right = rect.x + rect.w;
    try pen.set(w, edge, null);
    try w.print("\x1b[{d};{d}H╭─", .{ rect.y + 1, rect.x + 1 });
    try pen.set(w, heading(app), null);
    try w.writeAll(head);
    try pen.set(w, edge, null);
    for (cellCount(head) + 3..rect.w) |_| try w.writeAll("─");
    try w.writeAll("╮");

    const foot = rect.y + rect.h;
    try w.print("\x1b[{d};{d}H╰─", .{ foot, rect.x + 1 });
    for (3..rect.w) |_| try w.writeAll("─");
    try w.writeAll("╯");

    var buttons: [16]App.ModalButton = undefined;
    var end = rect.x + 2;
    for (app.modalButtons(&buttons)) |button| {
        var style = ink(app, "amber", 4);
        style.flags.inverse = true;

        try pen.set(w, style, null);
        try w.print("\x1b[{d};{d}H {s} {s} ", .{ button.y + 1, button.x + 1, button.key, button.label });
        if (button.y == foot - 1) end = button.x + button.width();
    }
    if (end + cellCount(hint) < right) {
        try pen.set(w, ink(app, "dim", 8), null);
        try w.print("\x1b[{d};{d}H{s}", .{ foot, end + 1, hint });
    }
    try pen.set(w, .{}, null);
}

/// Why babylon left done ticket `id`'s Claude running, empty when it says nothing of it.
fn doneNote(app: *const App, id: u32) []const u8 {
    const b = if (app.board) |*b| b else return "";
    for (b.cards()) |*card| if (card.id == id) return if (card.status == .done) card.session_note else "";
    return "";
}

/// A header button in Workbench's look, over the title bar or on its tab row; false for one that
/// is not part of the header.
fn workbenchButton(app: *const App, w: *Writer, r: theme.Roles, button: App.Button, view: app_mod.BoardView, buf: []u8) !bool {
    const label = app.buttonLabel(button, buf);
    const board = if (app.board) |*b| b else return false;
    switch (button.what) {
        .repo => |i| try bench.tab(w, r, button.x, button.y, label, i == view.repo and !view.backlog, app.tabCount(i) == 0),
        .backlog => try bench.tab(w, r, button.x, button.y, label, view.backlog, board.backlog().len == 0),
        .needs => {
            const n = board.needsYou().len;
            try bench.headButton(w, r, button.x, button.y, label, if (n > 0) r.you else r.dim, n > 0);
        },
        .new => {
            const focused = view.col == 0 and !app.columnFocused();
            try bench.say(w, button.x, button.y, label, r.accent, if (focused) r.raised else r.tile, true);
        },
        .card => |action| {
            const trimmed = std.mem.trim(u8, label, " ");
            const split = std.mem.indexOfScalar(u8, trimmed, ' ') orelse return false;
            var buttons: [48]App.Button = undefined;
            const first = for (app.boardButtons(&buttons)) |b| {
                if (b.what == .card) break b;
            } else return false;
            _ = action;
            _ = try bench.button(w, r, button.x, button.y, trimmed[0..split], trimmed[split + 1 ..], button.x == first.x and button.y == first.y, null);
        },
        .gate => try bench.headButton(w, r, button.x, button.y, label, r.checking, false),
        .orch => try bench.headButton(w, r, button.x, button.y, label, if (app.orchestrator().?.running) r.text else r.dim, false),
        .auto => {
            const armed = app.auto() != null and app.now < app.auto_armed_until;
            if (armed) {
                try bench.headButton(w, r, button.x, button.y, label, r.accent, true);
                return true;
            }
            const used = try bench.toggle(w, r, button.x, button.y, if (button.short) "" else "auto", app.auto() != null, r.raised);
            const at = std.mem.indexOf(u8, label, "▌") orelse return true;
            const rest = label[at + "▌".len ..];
            if (rest.len > 0 and used < button.w) try bench.headButton(w, r, button.x + used, button.y, rest, r.dim, false);
        },
    }
    return true;
}

/// The board's buttons over what is drawn under them: the repo tabs, the one shown lit, and the
/// gate; the + on the to-do column; the picked card's actions as chips; and, at the first row's
/// end, where its keys are.
fn boardButtons(app: *App, w: *Writer, view: app_mod.BoardView) !void {
    var pen: Pen = .{};
    var buf: [64]u8 = undefined;
    var buttons: [48]App.Button = undefined;
    const shown = app.boardButtons(&buttons);
    var end: u16 = app.boardX() + @as(u16, @intCast(cellCount(App.board_title)));
    var right = app.boardX() + app.boardW();
    var refusal_at: ?App.Button = null;
    const said: ?[]const u8 = if (app.start_refused) |text| text else if (app.report_said != null and !app.feedFocused() and app.barRows() == 0) app.report_said else null;
    const said_ink = if (app.start_refused != null) ink(app, "emberdim", 1) else reportInk(app);
    for (shown) |button| {
        if (said != null and button.what == .card) {
            if (refusal_at == null) refusal_at = button;
            continue;
        }
        const style: vt.Style = switch (button.what) {
            .repo => |i| if (i == view.repo and !view.backlog) chip(app) else if (app.tabCount(i) > 0) .{} else ink(app, "dim", 8),
            .backlog => if (view.backlog) chip(app) else if (app.board.?.backlog().len > 0) .{} else ink(app, "dim", 8),
            .gate => ink(app, "violet", 5),
            .orch => if (app.orchestrator().?.running) ink(app, "violet", 5) else ink(app, "dim", 8),
            .auto => if (app.auto() != null) autoOn(app) else ink(app, "dim", 8),
            .needs => if (app.board.?.needsYou().len > 0) heading(app) else ink(app, "dim", 8),
            .new => heading(app),
            .card => blk: {
                var lit = if (app.columnFocused()) ink(app, "dim", 8) else ink(app, "amber", 4);
                lit.flags.inverse = true;
                break :blk lit;
            },
        };

        const drawn = if (app.roles) |r| try workbenchButton(app, w, r, button, view, &buf) else false;
        if (!drawn) {
            try pen.set(w, style, null);
            try w.print("\x1b[{d};{d}H{s}", .{ button.y + 1, button.x + 1, app.buttonLabel(button, &buf) });
        }
        if (button.y != 0) continue;
        switch (button.what) {
            .repo, .backlog => end = button.x + button.w,
            else => right = @min(right, button.x),
        }
    }
    // babylon's refusal of the start, or its answer to the report key, takes the place of the
    // card's action row
    if (refusal_at) |at| if (said) |text| {
        const edge = app.boardColX(view.col) + app.boardColW(view.col) -| 2;
        if (app.roles) |r| {
            try bench.say(w, at.x, at.y, clip(text, edge -| at.x -| 1), if (app.start_refused != null) r.failed else r.accent, r.raised, false);
        } else {
            try pen.set(w, said_ink, null);
            try w.print("\x1b[{d};{d}H{s}", .{ at.y + 1, at.x + 1, clip(text, edge -| at.x) });
        }
    };
    var heads: [48]App.Button = undefined;
    if (app.header(&heads).more) |at| {
        try pen.set(w, ink(app, "dim", 8), null);
        try w.print("\x1b[2;{d}H…", .{at + 1});
    }
    const hint = for ([_][]const u8{ "? keys · esc close", "? keys" }) |text| {
        if (end + 2 + cellCount(text) + 1 <= right) break text;
    } else "";
    if (hint.len > 0) {
        if (app.roles) |r| {
            try bench.say(w, right - 1 - cellCount(hint) - 1, 0, hint, r.dim, r.raised, false);
        } else {
            try pen.set(w, ink(app, "dim", 8), null);
            try w.print("\x1b[1;{d}H{s}", .{ right - 1 - cellCount(hint), hint });
        }
    }
    try pen.set(w, .{}, null);
}

const board_keys = [_][2][]const u8{
    .{ "hjkl, arrows", "pick a card" },
    .{ "⏎, click it", "go to the Claude holding it, or start one on a free todo card" },
    .{ "space", "its whole ticket: body, links, gate log" },
    .{ "a G H x P", "answer, give, ask its Claude to hand off, no to a proposal, oldest proposed" },
    .{ "e", "edit its title, repo and body" },
    .{ "p", "raise its priority, high back to low" },
    .{ "> <", "close a ticket to do, reopen a done one" },
    .{ "J K", "move it down or up among its repo's cards" },
    .{ "+ n /", "file a ticket; the inbox; find cards by number, title or repo" },
    .{ "r z Z", "next repo, backlog, or a tab; fold a repo or a heading; Z all but it" },
    .{ "t w W", "backlog card to todo; todo card to next, asking its why; W at top" },
    .{ "g", "the gate's modal on the run in progress, else its session" },
    .{ "o", "the orchestrator, started if it is not running" },
    .{ "A", "babylon's auto mode, on or off" },
    .{ "`", "fold the orchestrator's window beside it, or unfold" },
    .{ "alt+l", "to that window, and alt+h back to the board" },
    .{ "esc, q", "close the board" },
    .{ "▌", "its priority: amber for high, dim for low" },
    .{ "◐ » ✗ ◆ ?", "working, queued, sent back, landed, asks" },
};

const plan_keys = [_][2][]const u8{
    .{ "j k, arrows", "pick a row: now, next, goals, ideas, landed, not planned" },
    .{ "⏎, click it", "go: its Claude, the gate, start it, plan an idea, unfold a row, the board on it" },
    .{ "space, t", "its whole ticket" },
    .{ "z, Z", "fold the picked window to its summary; fold all but it, and open all" },
    .{ "f", "the picked window whole, over the plan; q closes it" },
    .{ "+", "a new goal: plan it now, or just keep it" },
    .{ "d", "drive towards the picked goal; 1…9 answer a landed goal's what next" },
    .{ "J K x e", "on next: move it down or up, take it out, edit its why" },
    .{ "x e", "on a kept idea: withdraw it, edit it" },
    .{ "B, b", "the board, and back to the plan" },
    .{ "] [", "your move, first or last" },
    .{ "l, h", "the orchestrator's column, and back" },
    .{ "g o A", "the gate, the orchestrator, babylon's auto mode" },
    .{ "`", "fold the orchestrator's column, or unfold" },
    .{ "esc, q", "close home" },
    .{ "◐ ◒ » ◇", "building, in the pipeline, queued, stalled" },
};

/// The board's keys, or the plan's, boxed over its middle until the next key.
fn helpBox(app: *App, w: *Writer) !void {
    const list: []const [2][]const u8 = if (app.planShown()) &plan_keys else &board_keys;
    const title = if (app.planShown()) " the plan's keys " else " the board's keys ";
    return keysBox(app, w, list, title, app.boardX(), app.boardW());
}

const strip_keys = [_][2][]const u8{
    .{ "j k", "the pick down or up the rail; ⏎ goes, space opens" },
    .{ "] [", "the next or previous Claude that waits or is done" },
    .{ "h l  1…9", "the window left or right; that window" },
    .{ "H L  J K", "move the window; move the session" },
    .{ "; '", "the window narrower, wider" },
    .{ "c  x  z", "a new window; close it; the whole width" },
    .{ "/", "jump: windows, Claudes and tickets" },
    .{ "b n g", "the board; the inbox; the gate's modal" },
    .{ "o w m", "the overview; the rail narrow; the menu" },
    .{ "i Esc", "insert again" },
    .{ "Q", "leave; the sessions keep running" },
};

/// The strip's normal-mode keys, boxed over the strip.
fn stripHelp(app: *App, w: *Writer) !void {
    return keysBox(app, w, &strip_keys, " the keys ", app.term_w - app.view_w, app.view_w);
}

/// `list`'s keys boxed over the middle of the `width` columns from `left`, with `title`.
fn keysBox(app: *App, w: *Writer, list: []const [2][]const u8, title: []const u8, left: u16, width: u16) !void {
    const bw: u16 = @min(width -| 4, 60);
    const inner = bw -| 4;
    const x = left + (width -| bw) / 2;
    const edge = ink(app, "amber", 4);
    var pen: Pen = .{};
    var y: u16 = @min(3, app.view_h -| (list.len + 3));
    if (y == 0 or bw < 32) return;
    try pen.set(w, edge, null);
    try w.print("\x1b[{d};{d}H╭─", .{ y, x + 1 });
    try pen.set(w, heading(app), null);
    try w.writeAll(title);
    try pen.set(w, edge, null);
    for (cellCount(title) + 1..bw - 2) |_| try w.writeAll("─");
    try w.writeAll("╮");
    for (list) |pair| {
        y += 1;
        try pen.set(w, edge, null);
        try w.print("\x1b[{d};{d}H│ ", .{ y, x + 1 });
        try pen.set(w, heading(app), null);
        try fitted(w, pair[0], 14);
        try pen.set(w, .{}, null);
        try fitted(w, pair[1], inner -| 14);
        try pen.set(w, edge, null);
        try w.writeAll(" │");
    }
    y += 1;
    try boxLine(w, &pen, edge, ink(app, "dim", 8), x, y, "any key puts this away", inner);
    y += 1;
    try pen.set(w, edge, null);
    try w.print("\x1b[{d};{d}H╰", .{ y, x + 1 });
    for (0..bw - 2) |_| try w.writeAll("─");
    try w.writeAll("╯");
}

/// The question a card waits on, boxed over the middle of the board: the question wrapped to the
/// box, then each option by its number.
fn askBox(app: *App, w: *Writer, id: u32, ask: tickets.Ask) !void {
    const bw: u16 = @min(app.boardW() -| 4, 64);
    const inner = bw -| 4;
    const x = app.boardX() + (app.boardW() -| bw) / 2;
    const edge = ink(app, "amber", 4);
    var pen: Pen = .{};
    var buf: [48]u8 = undefined;
    var y: u16 = 4;

    const title = std.fmt.bufPrint(&buf, " #{d} asks ", .{id}) catch " asks ";
    try pen.set(w, edge, null);
    try w.print("\x1b[{d};{d}H╭─", .{ y, x + 1 });
    try pen.set(w, heading(app), null);
    try w.writeAll(title);
    try pen.set(w, edge, null);
    for (cellCount(title) + 1..bw - 2) |_| try w.writeAll("─");
    try w.writeAll("╮");

    var rest = ask.question;
    while (rest.len > 0 and y < 10) {
        const line = clip(rest, inner);
        y += 1;
        try boxLine(w, &pen, edge, .{}, x, y, line, inner);
        rest = std.mem.trimStart(u8, rest[line.len..], " ");
    }
    y += 1;
    try boxLine(w, &pen, edge, .{}, x, y, "", inner);
    for (ask.options, 1..) |option, n| {
        if (n > 9) break;
        y += 1;
        try pen.set(w, edge, null);
        try w.print("\x1b[{d};{d}H│ ", .{ y, x + 1 });
        try pen.set(w, heading(app), null);
        try w.print("{d}  ", .{n});
        try pen.set(w, .{}, null);
        try fitted(w, option, inner -| 3);
        try pen.set(w, edge, null);
        try w.writeAll(" │");
    }
    y += 1;
    try boxLine(w, &pen, edge, ink(app, "dim", 8), x, y, "its number answers · esc puts it away", inner);
    y += 1;
    try pen.set(w, edge, null);
    try w.print("\x1b[{d};{d}H╰", .{ y, x + 1 });
    for (0..bw - 2) |_| try w.writeAll("─");
    try w.writeAll("╯");
}

/// The Claudes the picked card can be given to, boxed over the middle of the board, each by its
/// number: its session and what its window is called, dim with why where babylon would refuse it.
fn giveBox(app: *App, w: *Writer, id: u32, picked: usize) !void {
    const bw: u16 = @min(app.boardW() -| 4, 64);
    const inner = bw -| 4;
    const x = app.boardX() + (app.boardW() -| bw) / 2;
    const edge = ink(app, "amber", 4);
    var pen: Pen = .{};
    var buf: [48]u8 = undefined;
    var y: u16 = 4;

    const title = std.fmt.bufPrint(&buf, " give #{d} to ", .{id}) catch " give to ";
    try pen.set(w, edge, null);
    try w.print("\x1b[{d};{d}H╭─", .{ y, x + 1 });
    try pen.set(w, heading(app), null);
    try w.writeAll(title);
    try pen.set(w, edge, null);
    for (cellCount(title) + 1..bw - 2) |_| try w.writeAll("─");
    try w.writeAll("╮");

    var found: [app_mod.give_rows]App.Agent = undefined;
    const n = app.agents(&found);
    for (found[0..n], 0..) |agent, i| {
        y += 1;
        const why = switch (agent.win.claude) {
            .working => " · mid-turn",
            .waiting => " · waits on you",
            .stalled => " · stalled",
            .none, .background, .done => "",
        };
        var line: [256]u8 = undefined;
        const text = std.fmt.bufPrint(&line, "{s} · {s}{s}", .{ app.sessions.items[agent.session].name, agent.win.label(), why }) catch agent.win.label();
        try pen.set(w, edge, null);
        try w.print("\x1b[{d};{d}H│ ", .{ y, x + 1 });
        try pen.set(w, heading(app), null);
        try w.print("{d}  ", .{i + 1});
        try pen.set(w, if (i == picked) chip(app) else if (why.len > 0) ink(app, "dim", 8) else .{}, null);
        try fitted(w, text, inner -| 3);
        try pen.set(w, edge, null);
        try w.writeAll(" │");
    }
    if (n == 0) {
        y += 1;
        try boxLine(w, &pen, edge, .{}, x, y, "no Claude is running", inner);
    }
    y += 1;
    try boxLine(w, &pen, edge, ink(app, "dim", 8), x, y, "its number gives, or jk and ⏎ · esc puts it away", inner);
    y += 1;
    try pen.set(w, edge, null);
    try w.print("\x1b[{d};{d}H╰", .{ y, x + 1 });
    for (0..bw - 2) |_| try w.writeAll("─");
    try w.writeAll("╯");
}

fn boxLine(w: *Writer, pen: *Pen, edge: vt.Style, style: vt.Style, x: u16, y: u16, text: []const u8, inner: u16) !void {
    try pen.set(w, edge, null);
    try w.print("\x1b[{d};{d}H│ ", .{ y, x + 1 });
    try pen.set(w, style, null);
    try fitted(w, text, inner);
    try pen.set(w, edge, null);
    try w.writeAll(" │");
}

/// Column `c`'s lines inside its border, scrolled: in the every view each repo with cards in it a
/// heading row, `arena ──── 13`, its cards under it; a card as tall as what it says. The strip's
/// are a dim row each, ✓ and its number and title, the picked one lit.
fn columnLines(app: *const App, w: *Writer, pen: *Pen, view: app_mod.BoardView, c: usize, x: u16, inner: u16) !void {
    const edge: vt.Style = .{ .fg_color = .palette(8) };
    const with_repo = app.cardRepoShown();
    var lines = App.ColumnLines.init(app, c);
    for (0..app.columnScroll(c)) |_| _ = lines.next();
    var y: u16 = app.colTop();
    while (y + 1 < app.view_h) : (y += 1) {
        try w.print("\x1b[{d};{d}H", .{ y + 1, x + 1 });
        try pen.set(w, edge, null);
        try w.writeAll("│");
        const at = lines.next() orelse {
            try pen.set(w, .{}, null);
            try fitted(w, "", inner);
            try pen.set(w, edge, null);
            try w.writeAll("│");
            continue;
        };
        switch (at.what) {
            .heading => try groupHeading(app, w, pen, app.laneRepo(at.lane).?, app.laneCounts(at.lane, c).total, at.lane == view.lane and c == view.col, foldMark(app, at.lane), inner),
            .more => {
                var buf: [24]u8 = undefined;
                const n = app.groupCounts(at.lane, c);
                try pen.set(w, ink(app, "dim", 8), null);
                try fitted(w, std.fmt.bufPrint(&buf, " {d} more", .{n.total - n.shown}) catch "", inner);
            },
            .card => |spot| {
                const it = app.groupCard(at.lane, c, spot.row).?;
                const picked = app.cardPicked(at.lane, c, spot.row);
                if (app.boardStrip(c)) {
                    var buf: [160]u8 = undefined;
                    const style = if (picked and !app.columnFocused()) heading(app) else ink(app, "dim", 8);
                    try pen.set(w, style, null);
                    try w.writeAll(" ");
                    try fitted(w, std.fmt.bufPrint(&buf, "{s} #{d} {s}", .{ if (it.status == .@"try") "▲" else "✓", it.id, it.title }) catch it.title, inner -| 1);
                } else try cardLine(app, w, pen, it, spot.part, picked, with_repo, inner);
            },
        }
        try pen.set(w, edge, null);
        try w.writeAll("│");
    }
}

/// A repo's heading row in a column, `arena ──── 13`: its name, lit where the pick is, then a
/// dim rule to its count of cards there.
fn groupHeading(app: *const App, w: *Writer, pen: *Pen, repo: []const u8, count: usize, lit: bool, fold: []const u8, inner: u16) !void {
    var buf: [24]u8 = undefined;
    const num = std.fmt.bufPrint(&buf, " {d}", .{count}) catch "";
    const name = clip(if (repo.len == 0) "no repo" else repo, inner -| (cellCount(num) + 3 + cellCount(fold)));
    try pen.set(w, if (lit) heading(app) else .{}, null);
    try w.writeAll(" ");
    try w.writeAll(name);
    try pen.set(w, ink(app, "dim", 8), null);
    try w.writeAll(fold);
    const used = 2 + cellCount(name) + cellCount(fold) + cellCount(num);
    if (used > inner) return fitted(w, "", inner -| (1 + cellCount(name)));
    try w.writeAll(" ");
    for (used..inner) |_| try w.writeAll("─");
    try w.writeAll(num);
}

/// Row `part` of a card in `inner` cells. One not picked has a bar down its left, amber for high
/// and dim for low, its number and title wrapped to the column, the last of `title_rows` cut with
/// `…`, and a last row when it has something to say. The picked one is boxed in its place, lit
/// (dim while the orchestrator's column has the keys), its title whole, its priority and how long
/// since it was filed on its top edge. A card waiting on another is dim.
fn cardLine(app: *const App, w: *Writer, pen: *Pen, card: *const tickets.Card, part: usize, picked: bool, with_repo: bool, inner: u16) !void {
    if (inner < 4) return fitted(w, "", inner);
    var buf: [160]u8 = undefined;
    const dim = ink(app, "dim", 8);
    const border: vt.Style = if (picked and app.columnFocused()) dim else if (picked) heading(app) else .{};
    const bar: vt.Style = if (picked) border else if (std.mem.eql(u8, card.priority, "high")) ink(app, "amber", 4) else if (std.mem.eql(u8, card.priority, "low")) dim else .{};
    const title = App.cardTitle(card, &buf);
    const width = App.cardTextW(inner + 2);
    var count: usize = 0;
    var counted = app_mod.TitleLines.init(title, width);
    while (counted.next()) |_| count += 1;
    const rows = if (picked) count else @min(count, App.title_rows);
    const last = @intFromBool(App.cardHasLast(card, with_repo));
    if (picked and (part == 0 or part == rows + last + 3)) {
        try pen.set(w, border, null);
        if (part == 0) {
            try w.writeAll("╭");
            for (0..inner - 2) |_| try w.writeAll("─");
            try w.writeAll("╮");
        } else {
            try w.writeAll("╰");
            for (0..inner - 2) |_| try w.writeAll("─");
            try w.writeAll("╯");
        }
        return;
    }
    const row = if (picked) part - 1 else part;
    try pen.set(w, bar, null);
    try w.writeAll(if (picked) "│" else "▌");
    if (row < rows) {
        var lines = app_mod.TitleLines.init(title, width);
        var line: []const u8 = "";
        for (0..row + 1) |_| line = lines.next() orelse "";
        const style: vt.Style = if (card.blocked_by.len > 0) dim else .{};
        try pen.set(w, style, null);
        try w.writeAll(" ");
        if (!picked and row + 1 == App.title_rows and count > App.title_rows) {
            const shown = clip(line, width -| 1);
            try w.writeAll(shown);
            try w.writeAll("…");
            try pen.set(w, .{}, null);
            try fitted(w, "", width -| (cellCount(shown) + 1));
        } else try fitted(w, line, width);
    } else if (row < rows + last) {
        try cardLast(app, w, pen, card, with_repo, inner - 2);
    } else if (row == rows + last) {
        try cardAge(app, w, pen, card, inner - 2);
    } else try fitted(w, "", inner - 2);
    try pen.set(w, border, null);
    try w.writeAll(if (picked) "│" else " ");
}

/// The picked card's detail row in `width` cells: its priority and how long since it was filed.
fn cardAge(app: *const App, w: *Writer, pen: *Pen, card: *const tickets.Card, width: usize) !void {
    var buf: [48]u8 = undefined;
    var age: [8]u8 = undefined;
    const filed = if (tickets.epochOf(card.inserted_at)) |at| ago(&age, app.epoch, @intCast(@max(1, at))) else "";
    const text = if (filed.len > 0) std.fmt.bufPrint(&buf, "{s} · filed {s}", .{ card.priority, filed }) catch card.priority else card.priority;
    try pen.set(w, ink(app, "dim", 8), null);
    try w.writeAll(" ");
    try fitted(w, text, width -| 1);
}

/// Where the pipeline has a card: its glyph, none when it has none, the word for it, and the
/// colour of both. A queued one with a question open is held: babylon moves it once it is answered.
fn stageOf(app: *const App, card: *const tickets.Card) ?struct { style: vt.Style, glyph: u21, word: []const u8 } {
    const s = card.stage orelse return null;
    const eql = std.mem.eql;
    if (eql(u8, s, "failed")) return .{ .style = ink(app, "emberdim", 1), .glyph = '✗', .word = "sent back" };
    if (eql(u8, s, "landed")) return .{ .style = ink(app, "amber", 4), .glyph = '◆', .word = "landed" };
    if (eql(u8, s, "queued")) return .{ .style = ink(app, "violet", 5), .glyph = if (card.ask == null) '»' else 0, .word = if (card.ask == null) "queued" else "held: asks" };
    if (eql(u8, s, "verifying") or eql(u8, s, "reviewing")) return .{ .style = ink(app, "amber", 4), .glyph = glyph(app, .working), .word = s };
    return .{ .style = ink(app, "dim", 8), .glyph = 0, .word = s };
}

/// The colour the board gives a pipeline stage's word, none for one it leaves dim.
fn stageStyle(app: *const App, word: []const u8) ?vt.Style {
    if (std.mem.eql(u8, word, "queued")) return ink(app, "violet", 5);
    if (std.mem.eql(u8, word, "verifying") or std.mem.eql(u8, word, "reviewing")) return ink(app, "amber", 4);
    return null;
}

/// A card's last row in `width` cells, what is so of it past its title joined by ` · `: the
/// orchestrator's proposal, a question waiting on the human, where the pipeline has it as a glyph
/// in its colour, the Claude holding it, and its detail.
fn cardLast(app: *const App, w: *Writer, pen: *Pen, card: *const tickets.Card, with_repo: bool, width: usize) !void {
    var buf: [160]u8 = undefined;
    var held: [96]u8 = undefined;
    var spun: [48]u8 = undefined;
    var proposed: [160]u8 = undefined;
    const dim = ink(app, "dim", 8);
    const stage: struct { vt.Style, []const u8 } = if (stageOf(app, card)) |s|
        .{ s.style, cardStage(app, card, s.glyph, s.word, &spun) }
    else
        .{ dim, "" };
    const queued = card.stage != null and std.mem.eql(u8, card.stage.?, "queued");
    const parts = [_]struct { vt.Style, []const u8 }{
        .{ heading(app), if (card.proposal) |p| std.fmt.bufPrint(&proposed, "▲ proposed: {s}", .{p.why}) catch "▲ proposed" else "" },
        .{ ink(app, "amber", 4), if (card.ask != null and !queued) "? asks" else "" },
        stage,
        .{ dim, if (card.status != .review and !card.isEpic()) cardHolder(app, card, &held) else "" },
        .{ dim, cardDetail(app, card, with_repo, &buf) },
    };
    var left = width -| 2;
    try pen.set(w, .{}, null);
    try w.writeAll(" ");
    var first = true;
    for (parts) |part| {
        if (part[1].len == 0) continue;
        if (!first) {
            const sep = clip(" · ", left);
            try pen.set(w, dim, null);
            try w.writeAll(sep);
            left -= cellCount(sep);
        }
        first = false;
        const cut = cellCount(part[1]) > left;
        const shown = clip(part[1], if (cut) left -| 1 else left);
        try pen.set(w, part[0], null);
        try w.writeAll(shown);
        left -= cellCount(shown);
        if (cut and left > 0) {
            try w.writeAll("…");
            left -= 1;
        }
    }
    try pen.set(w, .{}, null);
    try w.writeAll(" ");
    for (0..left) |_| try w.writeAll(" ");
}

/// Where the pipeline has a card, said: its glyph and word, then for one queued its place in its
/// repo's line, and for one being gated how long it has been there.
fn cardStage(app: *const App, card: *const tickets.Card, mark: u21, word: []const u8, buf: []u8) []const u8 {
    var out: Writer = .fixed(buf);
    if (mark != 0) out.print("{u} ", .{mark}) catch {};
    out.writeAll(word) catch {};
    const s = card.stage.?;
    const eql = std.mem.eql;
    if (eql(u8, s, "queued") and card.ask == null) {
        const place = queuePlace(app, card);
        const suffix = if (place % 100 / 10 == 1) "th" else switch (place % 10) {
            1 => "st",
            2 => "nd",
            3 => "rd",
            else => "th",
        };
        out.print(" · {d}{s}", .{ place, suffix }) catch {};
    } else if (eql(u8, s, "verifying") or eql(u8, s, "reviewing") or eql(u8, s, "landing")) {
        var age: [8]u8 = undefined;
        if (tickets.epochOf(card.stage_at)) |at| out.print(" · {s}", .{ago(&age, app.epoch, @intCast(@max(1, at)))}) catch {};
    }
    return out.buffered();
}

/// A queued card's place in its repo's line, from 1: babylon runs a repo's queued tickets in the
/// order they were submitted, then by number.
fn queuePlace(app: *const App, card: *const tickets.Card) usize {
    const b = if (app.board) |*b| b else return 1;
    const eql = std.mem.eql;
    const mine = card.submitted_at orelse "";
    var place: usize = 1;
    for (b.cards()) |*other| {
        if (other.id == card.id or other.stage == null or !eql(u8, other.stage.?, "queued")) continue;
        if (!eql(u8, other.repo orelse "", card.repo orelse "")) continue;
        const at = other.submitted_at orelse "";
        if (std.mem.order(u8, at, mine) == .lt or (eql(u8, at, mine) and other.id < card.id)) place += 1;
    }
    return place;
}

/// The Claude holding a card: its window with that Claude's mark, the model it was started with,
/// and how long it has held it; a doing card no Claude holds says so, and since when.
fn cardHolder(app: *const App, card: *const tickets.Card, buf: []u8) []const u8 {
    var out: Writer = .fixed(buf);
    var age: [8]u8 = undefined;
    const since = if (card.claimedAt()) |at| ago(&age, app.epoch, @intCast(@max(1, at))) else "";
    const pane = card.holder() orelse {
        if (card.status != .doing) return "";
        out.writeAll("○ no Claude holds it") catch {};
        if (since.len > 0) out.print(" · {s}", .{since}) catch {};
        return out.buffered();
    };
    if (app.paneWindow(pane)) |at| {
        const win = at.session.wins.items[at.index];
        if (win.claude != .none) out.print("{u} ", .{glyph(app, win.claude)}) catch {};
        out.writeAll(win.name) catch {};
    } else out.writeAll(card.heldBy().?) catch {};
    if (card.model) |model| out.print(" · {s}", .{modelName(model)}) catch {};
    if (since.len > 0) out.print(" · {s}", .{since}) catch {};
    return out.buffered();
}

/// A model id as a card says it: `claude-opus-5-5` is `opus`.
fn modelName(model: []const u8) []const u8 {
    const rest = if (std.mem.startsWith(u8, model, "claude-")) model["claude-".len..] else return model;
    return rest[0 .. std.mem.indexOfScalar(u8, rest, '-') orelse rest.len];
}

/// What else is so of a card, joined: its repo where nothing else says it, the tickets it waits
/// on, that it is an epic, a todo card's model, why a done one's Claude was left running.
fn cardDetail(app: *const App, card: *const tickets.Card, with_repo: bool, buf: []u8) []const u8 {
    var out: Writer = .fixed(buf);
    var sep: []const u8 = "";
    if (with_repo) {
        out.print("{s}{s}", .{ sep, card.repo orelse "no repo" }) catch {};
        sep = " · ";
    }
    if (card.waiting_on) |wait| {
        var said: [96]u8 = undefined;
        out.print("{s}{s}", .{ sep, wait.say(&said) }) catch {};
        sep = " · ";
    }
    if (card.blocked_by.len > 0) {
        out.print("{s}waits", .{sep}) catch {};
        for (card.blocked_by) |id| out.print(" #{d}", .{id}) catch {};
        sep = " · ";
    }
    if (card.isEpic()) {
        var words: [48]u8 = undefined;
        out.print("{s}{s}", .{ sep, epicWords(app, card, "◆ ", &words) }) catch {};
        sep = " · ";
    }
    if (card.status == .todo) if (card.model) |model| {
        out.print("{s}{s}", .{ sep, modelName(model) }) catch {};
        sep = " · ";
    };
    if (card.handed_off_from) |pane| {
        out.print("{s}handed off from {s}", .{ sep, pane }) catch {};
        sep = " · ";
    }
    if (card.status == .done and card.session_note.len > 0) out.print("{s}{s}", .{ sep, card.session_note }) catch {};
    return out.buffered();
}

fn reportInk(app: *const App) vt.Style {
    return if (app.report_failed) ink(app, "emberdim", 1) else ink(app, "amber", 4);
}

/// babylon's answer to the report key, where the key was pressed: directly under the picked feed
/// line while the feed has the keys; on the board, on the picked card's action row, which
/// boardButtons draws; else, with nowhere of its own, the last row of the view.
fn reportSaid(app: *App, w: *Writer, text: []const u8) !void {
    const ox = app.term_w - app.view_w;
    var pen: Pen = .{};
    try pen.set(w, reportInk(app), null);
    var f: feed.Feed = undefined;
    if (app.feedOf(&f)) if (app.feedPick(&f)) |on| if (app.feedFocused() and on.line + 3 < app.view_h) {
        const room = app.view_w -| 4;
        try w.print("\x1b[{d};{d}H{s}", .{ on.line + 3, ox + 3, clip(text, room) });
        for (cellCount(clip(text, room))..room) |_| try w.writeAll(" ");
        return;
    };
    if (app.board_view != null and !app.planShown() and !app.feedFocused() and (cardActionsShown(app) or app.barRows() > 0)) return;
    try w.print("\x1b[{d};{d}H{s}", .{ app.view_h, ox + 1, clip(text, app.view_w) });
}

fn cardActionsShown(app: *const App) bool {
    var buttons: [48]App.Button = undefined;
    for (app.boardButtons(&buttons)) |button| if (button.what == .card) return true;
    return false;
}

/// One frame: the rail, the current session's strip (and, mid-slide, the one being left) or the
/// overview in its place, the menu or prompt when open, and the cursor.
pub fn frame(app: *App, w: *Writer, what: What) !void {
    app.settleLit();
    try w.writeAll("\x1b[?2026h\x1b[?25l\x1b[0m");
    if (what == .all) {
        // Not 2J: erasing the whole display takes the terminal's kitty pictures with it.
        try w.writeAll("\x1b[H\x1b[J");
        try rail(app, w);
    } else if (app.working()) try rail(app, w);
    var cursor: ?Cursor = null;
    if (app.overview) |spot| {
        try overview(app, w, spot);
        try modeRow(app, w);
    } else if (app.board_view) |view| {
        if (!app.columnAlone()) try boardView(app, w, view);
        try modeRow(app, w);
        // the orchestrator's window beside it, once arena is in its session
        if (app.sideShown()) {
            cursor = try strip(app, w, app.cur().?, 0, what);
        } else if (app.sided()) try sideEmpty(app, w);
    } else {
        if (app.yoff != 0) if (app.sessionById(app.prev)) |leaving| {
            const way: i32 = if (app.yoff > 0) 1 else -1;
            _ = try strip(app, w, leaving, app.yoff - way * @as(i32, app.view_h), .all);
        };
        if (app.cur()) |s| {
            cursor = try strip(app, w, s, app.yoff, what);
            try dots(app, w, s);
        }
    }
    // a narrow rail drawn wide lies over the strip
    if (app.peek) try rail(app, w);
    if (app.look) |look| try lookBox(app, w, look);
    if (app.strip_help and app.overlay() == false) try stripHelp(app, w);
    if (app.popup) |pop| {
        try popupBox(app, w, pop);
        cursor = null;
    }
    if (app.prompt) |*prompt| {
        cursor = if (prompt.multiline()) try wordsModal(app, w, prompt) else if (prompt.what == .why) try wordsLine(app, w, prompt) else if (prompt.what == .find) try findLine(app, w) else try promptBox(app, w, prompt);
    } else if (app.menu) |open| {
        try menuBox(app, w, open);
        cursor = null;
    }
    if (app.report_said) |text| try reportSaid(app, w, text);
    const asking = if (app.prompt) |prompt| prompt.multiline() else false;
    if (asking != app.words_keys) {
        // modifyOtherKeys 1: a terminal sends Shift+Enter as its own key, not as Enter
        try w.writeAll(if (asking) "\x1b[>4;1m" else "\x1b[>4;0m");
        app.words_keys = asking;
    }
    try w.writeAll("\x1b[0m");
    if (cursor) |at| try w.print("\x1b[{d};{d}H\x1b[?25h", .{ at.y + 1, at.x + 1 });
    if (app.shape_due) try w.print("\x1b]22;{s}\x1b\\", .{app.shape});
    app.shape_due = false;
    try w.writeAll(app.out.items);
    app.out.clearRetainingCapacity();
    try w.writeAll("\x1b[?2026l");
}

fn sgr(buf: []u8, style: vt.Style) ![]const u8 {
    var out: Writer = .fixed(buf);
    var pen: Pen = .{};
    try pen.set(&out, style, null);
    return out.buffered();
}

test "a landing row's stage word is drawn in its state's colour" {
    var b = try tickets.Board.parse(std.testing.allocator,
        \\{"tickets":[
        \\{"id":14,"repo":"arena","title":"a","status":"doing","claimed_by":"%3","claimed_at":"2026-11-21T10:00:00Z"},
        \\{"id":17,"repo":"arena","title":"b","status":"review","stage":"queued","submitted_at":"2026-11-21T11:30:00Z"},
        \\{"id":15,"repo":"babylon","title":"c","status":"review","stage":"reviewing","submitted_at":"2026-11-21T11:58:00Z"}],
        \\"needs_you":[]}
    );
    defer b.deinit();
    var app: App = .{ .gpa = std.testing.allocator, .io = undefined, .tmux_in = undefined };
    var f: feed.Feed = undefined;
    feed.build(&f, &b, &.{}, 56, 80, 1795262400, 0, .{ .lit = .landing });

    var buf: [2048]u8 = undefined;
    var pen: Pen = .{};
    var want: [64]u8 = undefined;
    const at = struct {
        fn row(app_: *const App, f_: *const feed.Feed, pen_: *Pen, out_: []u8, i: usize) ![]const u8 {
            var out: Writer = .fixed(out_);
            try feedRow(app_, &out, pen_, f_, i, 56);
            return out.buffered();
        }
    };
    // row 0 is the quiet line, 1 the strip; the lit list's chips follow
    const quiet = try at.row(&app, &f, &pen, &buf, 0);
    try std.testing.expect(std.mem.indexOf(u8, quiet, "nothing needs you") != null);

    pen = .{};
    const chips = try at.row(&app, &f, &pen, &buf, 2);
    const reviewing = try std.fmt.allocPrint(std.testing.allocator, "{s}reviewing", .{try sgr(&want, ink(&app, "amber", 4))});
    defer std.testing.allocator.free(reviewing);
    try std.testing.expect(std.mem.indexOf(u8, chips, reviewing) != null);
    const queued = try std.fmt.allocPrint(std.testing.allocator, "{s}queued", .{try sgr(&want, ink(&app, "violet", 5))});
    defer std.testing.allocator.free(queued);
    try std.testing.expect(std.mem.indexOf(u8, chips, queued) != null);
    const repo = try std.fmt.allocPrint(std.testing.allocator, "{s}babylon", .{try sgr(&want, ink(&app, "dim", 8))});
    defer std.testing.allocator.free(repo);
    try std.testing.expect(std.mem.indexOf(u8, chips, repo) != null);
}

test "the feed draws Your move's header bold, a send-back in the error colour, a sent back chip's ✗ and words in it, and the strip dim" {
    var b = try tickets.Board.parse(std.testing.allocator,
        \\{"tickets":[
        \\{"id":495,"repo":"arena","title":"a","status":"doing","claimed_by":"%610","claimed_at":"2026-11-21T11:00:00Z","stage":"failed"},
        \\{"id":9,"repo":"arena","title":"b","status":"done","stage":"landed","closed_at":"2026-11-21T11:30:00Z"}],
        \\"needs_you":[
        \\{"id":"ask:3","kind":"ask","ticket":16,"repo":"arena","text":"#16 arena  asks: Blue?",
        \\ "actions":[{"key":"1","label":"Blue","argv":["babylon","answer","3","1"]}]},
        \\{"id":"sendback:12","kind":"sendback","ticket":12,"repo":"arena","text":"✗ #12 arena  sent back, free: red",
        \\ "actions":[{"key":"G","label":"give","argv":null,"needs":"pick"}]}]}
    );
    defer b.deinit();
    var app: App = .{ .gpa = std.testing.allocator, .io = undefined, .tmux_in = undefined };
    var f: feed.Feed = undefined;
    feed.build(&f, &b, &.{}, 56, 80, 1795262400, 1795262400 - 12 * 3600, .{ .lit = .landed });
    var buf: [2048]u8 = undefined;
    const has = struct {
        fn in(drawn: []const u8, style: vt.Style, text: []const u8) !bool {
            var buf_: [64]u8 = undefined;
            var pat: [128]u8 = undefined;
            return std.mem.indexOf(u8, drawn, try std.fmt.bufPrint(&pat, "{s}{s}", .{ try sgr(&buf_, style), text })) != null;
        }
    }.in;
    const row = struct {
        fn of(app_: *const App, f_: *const feed.Feed, out_: []u8, i: usize) ![]const u8 {
            var out: Writer = .fixed(out_);
            var pen: Pen = .{};
            try feedRow(app_, &out, &pen, f_, i, 56);
            return out.buffered();
        }
    }.of;

    var bold = heading(&app);
    bold.flags.bold = true;
    const head = try row(&app, &f, &buf, 0);
    try std.testing.expect(try has(head, bold, "▲ your move 2"));

    var seen: usize = 0;
    for (0..f.count()) |i| {
        const line = f.line(i);
        const drawn = try row(&app, &f, &buf, i);
        switch (line.kind) {
            .item => {
                seen += 1;
                const bar = if (line.failed) ink(&app, "emberdim", 1) else ink(&app, "amber", 4);
                try std.testing.expect(try has(drawn, bar, "▌ "));
                if (line.failed) {
                    try std.testing.expect(std.mem.indexOf(u8, line.text, "sent back") != null);
                } else try std.testing.expect(!try has(drawn, ink(&app, "emberdim", 1), "▌ "));
            },
            .strip => seen += 1,
            else => {},
        }
    }
    try std.testing.expectEqual(@as(usize, 3), seen);

    feed.build(&f, &b, &.{}, 56, 80, 1795262400, 1795262400 - 12 * 3600, .{ .lit = .building });
    for (0..f.count()) |i| if (f.line(i).kind == .building_chips) {
        const drawn = try row(&app, &f, &buf, i);
        const error_ink = ink(&app, "emberdim", 1);
        try std.testing.expect(try has(drawn, error_ink, "✗"));
        try std.testing.expect(try has(drawn, error_ink, "#495"));
    };
}

test "the done strip's picked card is lit while the board has the keys and dims like its neighbours once the column has them" {
    var app: App = .{ .gpa = std.testing.allocator, .io = undefined, .tmux_in = undefined };
    app.board = try tickets.Board.parse(std.testing.allocator,
        \\{"tickets":[
        \\{"id":1,"repo":"arena","title":"todo","status":"todo"},
        \\{"id":2,"repo":"arena","title":"first","status":"done","stage":"landed"},
        \\{"id":3,"repo":"arena","title":"second","status":"done","stage":"landed"}]}
    );
    defer app.board.?.deinit();
    app.view_w = 100;
    app.term_w = 100;
    app.view_h = 12;
    app.board_view = .{ .col = 3, .row = 0 };
    var buf: [4096]u8 = undefined;
    var pen: Pen = .{};
    const lit = heading(&app);
    var want: [64]u8 = undefined;
    var pat: [128]u8 = undefined;

    var out: Writer = .fixed(&buf);
    try columnLines(&app, &out, &pen, app.board_view.?, 3, 0, 40);
    const board_keys_drawn = out.buffered();
    const picked_lit = try std.fmt.bufPrint(&pat, "{s} ✓ #2", .{try sgr(&want, lit)});
    try std.testing.expect(std.mem.indexOf(u8, board_keys_drawn, picked_lit) != null);
    const neighbour = "│ ✓ #3";
    try std.testing.expect(std.mem.indexOf(u8, board_keys_drawn, neighbour) != null);

    app.board_view.?.home = true;
    app.board_view.?.focus = .orchestrator;
    try std.testing.expect(app.columnFocused());
    pen = .{};
    out = .fixed(&buf);
    try columnLines(&app, &out, &pen, app.board_view.?, 3, 0, 40);
    const column_keys_drawn = out.buffered();
    const picked_dim = "│ ✓ #2";
    try std.testing.expect(std.mem.indexOf(u8, column_keys_drawn, picked_dim) != null);
    try std.testing.expect(std.mem.indexOf(u8, column_keys_drawn, picked_lit) == null);
}

test "a pinned ticket's mark in next is drawn in the accent" {
    var b = try tickets.Board.parse(std.testing.allocator,
        \\{"tickets":[],"needs_you":[],"hold":true,
        \\"auto":{"on":true,"cap":6,"working":4,"idle":{"slots":2,"why":"next empty"},"repo_caps":{"arena":2,"tlon":0}},
        \\"plan":{"next":[{"ticket":655,"repo":"arena","title":"Typing","why":"third","set_by":"human"}]}}
    );
    defer b.deinit();
    var app: App = .{ .gpa = std.testing.allocator, .io = undefined, .tmux_in = undefined };
    var f: feed.Feed = undefined;
    feed.build(&f, &b, &.{}, 70, 80, 1795262400, 0, .{ .lit = .next });
    var buf: [2048]u8 = undefined;
    var want: [64]u8 = undefined;
    var out: Writer = .fixed(&buf);
    var pen: Pen = .{};
    try feedRow(&app, &out, &pen, &f, 3, 70);
    const pin = try std.fmt.allocPrint(std.testing.allocator, "{s}  ▪", .{try sgr(&want, ink(&app, "amber", 4))});
    defer std.testing.allocator.free(pin);
    try std.testing.expect(std.mem.indexOf(u8, out.buffered(), pin) != null);
}

test "a queued card says its place in its repo's line, and with a question open it is held" {
    var app: App = .{ .gpa = std.testing.allocator, .io = undefined, .tmux_in = undefined };
    app.board = try tickets.Board.parse(std.testing.allocator,
        \\{"tickets":[
        \\{"id":1,"repo":"arena","title":"a","status":"review","stage":"queued","submitted_at":"2026-11-23T02:00:00Z"},
        \\{"id":2,"repo":"arena","title":"b","status":"review","stage":"queued","submitted_at":"2026-11-23T01:00:00Z"},
        \\{"id":3,"repo":"tlon","title":"c","status":"review","stage":"queued","submitted_at":"2026-11-23T00:00:00Z"}
        \\]}
    );
    defer app.board.?.deinit();
    var buf: [512]u8 = undefined;
    var card = app.board.?.cards()[0];

    var waiting: Writer = .fixed(&buf);
    var pen: Pen = .{};
    try cardLast(&app, &waiting, &pen, &card, false, 30);
    try std.testing.expect(std.mem.indexOf(u8, waiting.buffered(), "» queued · 2nd") != null);

    card.ask = .{ .id = 5, .question = "Which colour?" };
    var held: Writer = .fixed(&buf);
    pen = .{};
    try cardLast(&app, &held, &pen, &card, false, 30);
    const drawn = held.buffered();
    try std.testing.expect(std.mem.indexOf(u8, drawn, "held: asks") != null);
    try std.testing.expect(std.mem.indexOf(u8, drawn, "queued") == null);
    try std.testing.expect(std.mem.indexOf(u8, drawn, "? asks") == null);
}

test "a card handed off says from which pane, on a last row of its own" {
    var app: App = .{ .gpa = std.testing.allocator, .io = undefined, .tmux_in = undefined };
    var card: tickets.Card = .{ .id = 7, .title = "t", .status = .todo };
    try std.testing.expect(!App.cardHasLast(&card, false));
    card.handed_off_from = "%407";
    try std.testing.expect(App.cardHasLast(&card, false));
    var buf: [160]u8 = undefined;
    try std.testing.expectEqualStrings("handed off from %407", cardDetail(&app, &card, false, &buf));
}

test "a card not picked: its priority bar, its whole title wrapped to four rows, and a last row only with something to say" {
    var app: App = .{ .gpa = std.testing.allocator, .io = undefined, .tmux_in = undefined };
    var buf: [1024]u8 = undefined;
    const Drawn = struct {
        fn row(a: *App, out: []u8, card: *const tickets.Card, part: usize, inner: u16) ![]const u8 {
            var w: Writer = .fixed(out);
            var pen: Pen = .{};
            try cardLine(a, &w, &pen, card, part, false, false, inner);
            return w.buffered();
        }
    };
    const long: tickets.Card = .{ .id = 7, .title = "one two three four five six seven eight nine ten eleven twelve", .status = .todo, .priority = "high" };
    try std.testing.expect(!App.cardHasLast(&long, false));
    var first = try Drawn.row(&app, &buf, &long, 0, 16);
    try std.testing.expect(std.mem.indexOf(u8, first, "▌") != null);
    try std.testing.expect(std.mem.indexOf(u8, first, "#7 one two") != null);
    try std.testing.expect(std.mem.indexOf(u8, first, try sgr(buf[900..], ink(&app, "amber", 4))) != null);
    const fourth = try Drawn.row(&app, &buf, &long, 3, 16);
    try std.testing.expect(std.mem.indexOf(u8, fourth, "…") != null);

    const held: tickets.Card = .{ .id = 8, .title = "short", .status = .doing, .model = "claude-opus-5-5" };
    try std.testing.expect(App.cardHasLast(&held, false));
    first = try Drawn.row(&app, &buf, &held, 1, 40);
    try std.testing.expect(std.mem.indexOf(u8, first, "○ no Claude holds it") != null);
    const todo: tickets.Card = .{ .id = 9, .title = "short", .status = .todo, .model = "claude-opus-5-5", .blocked_by = &.{4} };
    first = try Drawn.row(&app, &buf, &todo, 1, 40);
    try std.testing.expect(std.mem.indexOf(u8, first, "waits #4 · opus") != null);
}

test "the board's first row ends on its keys' hint, the short one with less room, and a … stands after the last tab left in" {
    var app: App = .{ .gpa = std.testing.allocator, .io = undefined, .tmux_in = undefined };
    app.board = try tickets.Board.parse(std.testing.allocator,
        \\{"tickets":[
        \\{"id":1,"repo":"arena","title":"a","status":"todo"},
        \\{"id":2,"repo":"menard","title":"b","status":"todo"},
        \\{"id":3,"repo":"tlon","title":"c","status":"todo"}
        \\],"auto":{"on":true,"cap":3,"working":2},"orchestrator":{"on":true,"running":true}}
    );
    defer app.board.?.deinit();
    app.board_view = .{};
    app.view_h = 20;
    var buf: [8192]u8 = undefined;
    const has = struct {
        fn in(drawn: []const u8, text: []const u8) bool {
            return std.mem.indexOf(u8, drawn, text) != null;
        }
    }.in;

    app.view_w = 140;
    app.term_w = 140;
    var wide: Writer = .fixed(&buf);
    try boardButtons(&app, &wide, app.board_view.?);
    try std.testing.expect(has(wide.buffered(), "? keys · esc close"));
    try std.testing.expect(!has(wide.buffered(), "…"));

    app.view_w = 44;
    app.term_w = 44;
    var short: Writer = .fixed(&buf);
    try boardButtons(&app, &short, app.board_view.?);
    try std.testing.expect(has(short.buffered(), "? keys"));
    try std.testing.expect(!has(short.buffered(), "esc close"));

    app.view_w = 30;
    app.term_w = 30;
    var heads: [48]App.Button = undefined;
    const more = app.header(&heads).more.?;
    var narrow: Writer = .fixed(&buf);
    try boardButtons(&app, &narrow, app.board_view.?);
    var at: [24]u8 = undefined;
    try std.testing.expect(has(narrow.buffered(), try std.fmt.bufPrint(&at, "\x1b[2;{d}H…", .{more + 1})));
}

test "the board's head in Workbench's look: a striped title bar, tabs under it that join the window, need-you filled violet, the auto switch" {
    var app: App = .{ .gpa = std.testing.allocator, .io = undefined, .tmux_in = undefined };
    app.term_w = 80;
    app.view_w = 80;
    app.view_h = 20;
    app.roles = bench.roles();
    const r = app.roles.?;
    app.board = try tickets.Board.parse(std.testing.allocator,
        \\{"tickets":[
        \\{"id":1,"repo":"arena","title":"a","status":"todo"},
        \\{"id":2,"repo":"menard","title":"b","status":"todo"}
        \\],"auto":{"on":true,"cap":3,"working":2},
        \\"needs_you":[{"id":"ask:3","kind":"ask","ticket":1,"repo":"arena","text":"#1 arena  asks: Blue?",
        \\ "actions":[{"key":"1","label":"Blue","argv":["babylon","answer","3","1"]}]}]}
    );
    defer app.board.?.deinit();
    app.board_view = .{};
    var buf: [16384]u8 = undefined;
    var out: Writer = .fixed(&buf);
    try boardView(&app, &out, app.board_view.?);
    const drawn = out.buffered();

    var buttons: [48]App.Button = undefined;
    const head = app.header(&buttons);
    var needs: ?App.Button = null;
    var auto: ?App.Button = null;
    for (buttons[0..head.n]) |b| switch (b.what) {
        .needs => needs = b,
        .auto => auto = b,
        else => {},
    };
    const tab = buttons[0];
    const next = buttons[1];
    const eq = std.testing.expectEqual;

    const bar = try bench.probe(drawn, 1, 0);
    try eq(@as(u21, 'b'), bar.cp);
    try eq(r.dim, bar.fg);
    try eq(r.raised, bar.bg);
    const lit = try bench.probe(drawn, 10, 0);
    try eq(@as(u21, 'B'), lit.cp);
    try eq(r.text, lit.fg);
    const stripe = try bench.probe(drawn, 20, 0);
    try eq(@as(u21, '═'), stripe.cp);
    try eq(r.accent.mix(r.raised, 0.5), stripe.fg);

    try eq(@as(u16, 1), tab.y);
    const here = try bench.probe(drawn, tab.x + 1, 1);
    try eq(@as(u21, 'e'), here.cp);
    try eq(r.panel, here.bg);
    try eq(r.tile, (try bench.probe(drawn, next.x + 1, 1)).bg);
    try eq(r.ground, (try bench.probe(drawn, 79, 1)).bg);

    const ask = needs.?;
    const asks = try bench.probe(drawn, ask.x + 1, 0);
    try eq(@as(u21, '▲'), asks.cp);
    try eq(r.on_accent, asks.fg);
    try eq(r.you, asks.bg);

    const sw = auto.?;
    try eq(@as(u21, 'a'), (try bench.probe(drawn, sw.x, 0)).cp);
    const cap = try bench.probe(drawn, sw.x + 5, 0);
    try eq(@as(u21, '▐'), cap.cp);
    try eq(r.accent, cap.fg);
    const knob = try bench.probe(drawn, sw.x + 7, 0);
    try eq(@as(u21, '●'), knob.cp);
    try eq(r.accent, knob.bg);
    try eq(@as(u21, '2'), (try bench.probe(drawn, sw.x + 10, 0)).cp);
    try eq(app.boardX() + app.boardW(), sw.x + sw.w);
}

test "the board in Workbench's look: windows, the picked tile raised with its chips, buttons and shadow, and the recent strip" {
    var app: App = .{ .gpa = std.testing.allocator, .io = undefined, .tmux_in = undefined };
    app.term_w = 80;
    app.view_w = 80;
    app.view_h = 24;
    app.roles = bench.roles();
    const r = app.roles.?;
    app.board = try tickets.Board.parse(std.testing.allocator,
        \\{"tickets":[
        \\{"id":1,"repo":"arena","title":"first","status":"todo","priority":"high","model":"claude-opus-5-5"},
        \\{"id":3,"repo":"arena","title":"second","status":"todo"},
        \\{"id":2,"repo":"menard","title":"old","status":"done","closed_at":"2026-11-24T00:00:00Z"}
        \\]}
    );
    defer app.board.?.deinit();
    app.board_view = .{};
    var buf: [65536]u8 = undefined;
    var out: Writer = .fixed(&buf);
    try boardView(&app, &out, app.board_view.?);
    const drawn = out.buffered();
    const eq = std.testing.expectEqual;
    const arena = r.repo[0];

    // todo is a window on its own: a title bar with its count, the gap beside it the shadow's
    try eq(@as(u21, 't'), (try bench.probe(drawn, 3, 2)).cp);
    try eq(@as(u21, '▌'), (try bench.probe(drawn, app.boardColW(0) - 1, 4)).cp);

    // the picked tile: its bevel, its title with the priority dot in its corner, its chip row
    const tw = app.boardColW(0) - 3;
    const bevel = try bench.probe(drawn, 1, 4);
    try eq(@as(u21, '▔'), bevel.cp);
    try eq(r.card(true), bevel.bg);
    const title = try bench.probe(drawn, 2, 5);
    try eq(@as(u21, 'f'), title.cp);
    try std.testing.expect(title.bold);
    try eq(r.card(true), title.bg);
    const dot = try bench.probe(drawn, 1 + tw - 2, 5);
    try eq(@as(u21, '●'), dot.cp);
    try eq(r.failed, dot.fg);
    const lead = try bench.probe(drawn, 2, 6);
    try eq(@as(u21, '▎'), lead.cp);
    try eq(arena, lead.fg);
    const mark = try bench.probe(drawn, 3, 6);
    try eq(@as(u21, 0xf120), mark.cp);
    try eq(arena, mark.fg);
    const number = try bench.probe(drawn, 5, 6);
    try eq(@as(u21, '1'), number.cp);
    try eq(arena, number.fg);
    const model = try bench.probe(drawn, 9, 6);
    try eq(@as(u21, 'o'), model.cp);
    try eq(r.text, model.fg);
    try eq(r.dim, (try bench.probe(drawn, 8, 6)).fg);

    // its shadow, and the first button on the row it has for them filled amber, the next raised
    try eq(@as(u21, '▌'), (try bench.probe(drawn, 1 + tw, 5)).cp);
    try eq(@as(u21, '▀'), (try bench.probe(drawn, 2, 8)).cp);
    try eq(r.well, (try bench.probe(drawn, 2, 8)).fg);
    var buttons: [48]App.Button = undefined;
    const shown = app.boardButtons(&buttons);
    var cards: usize = 0;
    for (shown) |b| if (b.what == .card) {
        try eq(@as(u16, 7), b.y);
        const face = (try bench.probe(drawn, b.x, b.y)).bg;
        try eq(if (cards == 0) r.accent else r.raised, face);
        cards += 1;
    };
    try std.testing.expect(cards >= 2);

    // the card under it is a tile, not raised, and has no buttons
    const next = try bench.probe(drawn, 1, 9);
    try eq(r.card(false), next.bg);
    try eq(r.card(false), (try bench.probe(drawn, 2, 10)).bg);

    // recent is a strip along the foot, its entry a mark and its number in the repo's hue
    const foot = app.listH();
    try eq(@as(u16, 19), foot);
    try eq(@as(u21, 'r'), (try bench.probe(drawn, 3, foot)).cp);
    try eq(@as(u21, '✓'), (try bench.probe(drawn, 1, foot + 1)).cp);
    const entry = try bench.probe(drawn, 1, foot + 2);
    try eq(@as(u21, '#'), entry.cp);
    try eq(r.repo[3], entry.fg);

    // the foot bar on the last row: the picked card's keys, a rule, the board's, a rule, ?
    const bar_y = app.view_h - 1;
    var keys: [24]App.BarKey = undefined;
    const bar = app.keyBar(&keys);
    const first = try bench.probe(drawn, bar[0].x + 1, bar_y);
    try eq(@as(u21, '⏎'), first.cp);
    try eq(r.accent, first.fg);
    try eq(r.raised, first.bg);
    try std.testing.expect(bar.len >= 6);
    for (bar) |k| if (k.group) try eq(@as(u21, '│'), (try bench.probe(drawn, k.x - 2, bar_y)).cp);
    try std.testing.expectEqualStrings("?", bar[bar.len - 1].key);
    try std.testing.expectEqualStrings("keys", bar[bar.len - 1].word);
}

test "unpicked cards are filled tiles a blank row apart, their chips pills on their own fill" {
    var app: App = .{ .gpa = std.testing.allocator, .io = undefined, .tmux_in = undefined };
    app.term_w = 80;
    app.view_w = 80;
    app.view_h = 24;
    app.roles = bench.roles();
    const r = app.roles.?;
    app.board = try tickets.Board.parse(std.testing.allocator,
        \\{"tickets":[
        \\{"id":1,"repo":"arena","title":"first","status":"todo"},
        \\{"id":2,"repo":"arena","title":"second","status":"todo","model":"claude-opus-5-5"},
        \\{"id":3,"repo":"arena","title":"third","status":"todo"}
        \\]}
    );
    defer app.board.?.deinit();
    app.board_view = .{};
    var buf: [65536]u8 = undefined;
    var out: Writer = .fixed(&buf);
    try boardView(&app, &out, app.board_view.?);
    const drawn = out.buffered();
    const eq = std.testing.expectEqual;

    const last = app.boardColW(0) - 3;
    for ([_]u16{ 9, 10, 11 }) |y| try eq(r.card(false), (try bench.probe(drawn, last, y)).bg);
    try eq(r.panel, (try bench.probe(drawn, last, 12)).bg);
    for ([_]u16{ 13, 14, 15 }) |y| try eq(r.card(false), (try bench.probe(drawn, last, y)).bg);
    try std.testing.expect(color.contrast(r.card(false), r.panel) >= 1.15);
    try eq(r.repo[0], (try bench.probe(drawn, 1, 10)).fg);
    try eq(r.well, (try bench.probe(drawn, 4, 11)).bg);
}

test "with the roles set, the find line is on the bar's face, clipped before the right group, and the hint is dim on it" {
    var app: App = .{ .gpa = std.testing.allocator, .io = undefined, .tmux_in = undefined };
    app.term_w = 70;
    app.view_w = 70;
    app.view_h = 20;
    app.roles = bench.roles();
    const r = app.roles.?;
    app.board = try tickets.Board.parse(std.testing.allocator,
        \\{"tickets":[{"id":1,"repo":"arena","title":"a","status":"todo"}],"auto":{"on":true,"cap":3,"working":2}}
    );
    defer app.board.?.deinit();
    app.board_view = .{};
    app.find_len = 30;
    @memset(app.find[0..30], 'x');
    var buf: [16384]u8 = undefined;
    var out: Writer = .fixed(&buf);
    try boardView(&app, &out, app.board_view.?);
    const drawn = out.buffered();
    const eq = std.testing.expectEqual;

    var heads: [48]App.Button = undefined;
    var right: u16 = app.boardX() + app.boardW();
    for (heads[0..app.header(&heads).n]) |b| right = @min(right, b.x);
    try std.testing.expect(right < app.boardX() + app.boardW());
    const slash = try bench.probe(drawn, 19, 0);
    try eq(@as(u21, '/'), slash.cp);
    try eq(r.raised, slash.bg);
    try eq(@as(u21, '…'), (try bench.probe(drawn, right - 2, 0)).cp);
    try eq(r.raised, (try bench.probe(drawn, right - 2, 0)).bg);
    try eq(r.raised, (try bench.probe(drawn, right - 1, 0)).bg);
    try std.testing.expect(std.mem.indexOf(u8, drawn, "esc clear") == null);

    app.find_len = 2;
    var short: Writer = .fixed(&buf);
    try boardView(&app, &short, app.board_view.?);
    const hint = try bench.probe(short.buffered(), 25, 0);
    try eq(@as(u21, 'e'), hint.cp);
    try eq(r.dim, hint.fg);
    try eq(r.raised, hint.bg);
}

test "the board's keys end on a card's edge and its marks, and a 24-row terminal has them whole" {
    var app: App = .{ .gpa = std.testing.allocator, .io = undefined, .tmux_in = undefined };
    app.view_w = 80;
    const x = app.boardX() + 10;
    var buf: [8192]u8 = undefined;
    var at: [24]u8 = undefined;

    app.view_h = 23;
    var short: Writer = .fixed(&buf);
    try helpBox(&app, &short);
    var drawn = short.buffered();
    for ([_][]const u8{ "▌", "its priority: amber for high, dim for low", "◐ » ✗ ◆ ?", "working, queued, sent back, landed, asks" }) |text| {
        try std.testing.expect(std.mem.indexOf(u8, drawn, text) != null);
    }
    try std.testing.expect(std.mem.indexOf(u8, drawn, try std.fmt.bufPrint(&at, "\x1b[1;{d}H╭", .{x + 1})) != null);
    try std.testing.expect(std.mem.indexOf(u8, drawn, try std.fmt.bufPrint(&at, "\x1b[{d};{d}H╰", .{ board_keys.len + 3, x + 1 })) != null);
    try std.testing.expect(board_keys.len + 3 <= app.view_h);

    app.view_h = 40;
    var tall: Writer = .fixed(&buf);
    try helpBox(&app, &tall);
    drawn = tall.buffered();
    try std.testing.expect(std.mem.indexOf(u8, drawn, try std.fmt.bufPrint(&at, "\x1b[3;{d}H╭", .{x + 1})) != null);
}

fn homeApp(board: *tickets.Board) App {
    var app: App = .{ .gpa = std.testing.allocator, .io = undefined, .tmux_in = undefined };
    app.term_w = 120;
    app.view_w = 60;
    app.view_h = 24;
    app.board = board.*;
    app.board_view = .{ .home = true, .focus = .orchestrator };
    return app;
}

test "a stalled orchestrator's head says stalled in the frame" {
    var board = try tickets.Board.parse(std.testing.allocator,
        \\{"tickets":[],"orchestrator":{"on":true,"running":true}}
    );
    defer board.deinit();
    var orch: Session = .{ .id = 2, .name = @constCast("orchestrator") };
    var win: Window = .{ .id = 1, .name = @constCast("orch"), .claude = .stalled };
    var wins = [_]*Window{&win};
    orch.wins = .fromOwnedSlice(&wins);
    var sessions = [_]*Session{&orch};
    var app = homeApp(&board);
    app.sessions = .fromOwnedSlice(&sessions);
    var buf: [65536]u8 = undefined;
    var out: Writer = .fixed(&buf);
    try frame(&app, &out, .all);
    try std.testing.expect(std.mem.indexOf(u8, out.buffered(), "orchestrator · stalled") != null);
}

test "a frame of the board with an orchestrator column draws at every width from 40 to 120" {
    var board = try tickets.Board.parse(std.testing.allocator,
        \\{"tickets":[],"orchestrator":{"on":true,"running":true}}
    );
    defer board.deinit();
    var orch: Session = .{ .id = 2, .name = @constCast("orchestrator") };
    var win: Window = .{ .id = 1, .name = @constCast("orch"), .claude = .working };
    var wins = [_]*Window{&win};
    orch.wins = .fromOwnedSlice(&wins);
    var sessions = [_]*Session{&orch};
    var app = homeApp(&board);
    app.sessions = .fromOwnedSlice(&sessions);
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    for (40..121) |term_w| {
        app.term_w = @intCast(term_w);
        app.fit();
        out.clearRetainingCapacity();
        try frame(&app, &out.writer, .all);
    }
}

test "the report's answer is drawn under the picked feed line, the tab strip's row untouched" {
    var board = try tickets.Board.parse(std.testing.allocator,
        \\{"tickets":[{"id":17,"repo":"arena","title":"b","status":"review","stage":"queued","submitted_at":"2026-11-21T11:30:00Z"}],"needs_you":[]}
    );
    defer board.deinit();
    var app = homeApp(&board);
    app.report_said = try std.testing.allocator.dupe(u8, "filed #9");
    defer std.testing.allocator.free(app.report_said.?);
    var f: feed.Feed = undefined;
    try std.testing.expect(app.feedOf(&f));
    const pick = app.feedPick(&f).?;
    var buf: [65536]u8 = undefined;
    var out: Writer = .fixed(&buf);
    try frame(&app, &out, .all);
    var want: [48]u8 = undefined;
    const under = try std.fmt.bufPrint(&want, "\x1b[{d};{d}Hfiled #9", .{ pick.line + 3, app.term_w - app.view_w + 3 });
    try std.testing.expect(std.mem.indexOf(u8, out.buffered(), under) != null);
    var strip_row: [16]u8 = undefined;
    const tab_row = try std.fmt.bufPrint(&strip_row, "\x1b[{d};", .{app.view_h + 1});
    const at = std.mem.indexOf(u8, out.buffered(), "filed #9").?;
    try std.testing.expect(std.mem.indexOf(u8, out.buffered()[at - 12 .. at], tab_row) == null);
}

test "the feed draws at every width and with every item picked, with a long next and every line present" {
    var b = try tickets.Board.parse(std.testing.allocator,
        \\{"tickets":[
        \\{"id":338,"repo":"arena","title":"a","status":"doing","stage":"failed","claimed_by":"%3","claimed_at":"2026-11-21T11:23:00Z"},
        \\{"id":757,"repo":"arena","title":"a","status":"doing","claimed_by":"%3","claimed_at":"2026-11-21T11:48:00Z"},
        \\{"id":759,"repo":"arena","title":"b","status":"doing","claimed_by":"%4","claimed_at":"2026-11-21T11:54:00Z"},
        \\{"id":760,"repo":"arena","title":"c","status":"doing","claimed_by":"%5","claimed_at":"2026-11-21T11:59:00Z"},
        \\{"id":619,"repo":"arena","title":"e","status":"review","stage":"queued","submitted_at":"2026-11-21T11:30:00Z"}],
        \\"needs_you":[],"hold":false,
        \\"auto":{"on":true,"cap":6,"working":4,"repo_caps":{"arena":3,"babylon":2,"tlon":0}},
        \\"plan":{"next":[
        \\{"ticket":346,"repo":"arena","title":"Board 13: / finds cards by number, title or repo, live","why":"the board's / finds cards by number, title or repo"},
        \\{"ticket":758,"repo":"arena","title":"The board is laggy: measure where a frame's time goes and fix it","why":"the board is laggy; measure where each frame goes and fix it"},
        \\{"ticket":459,"repo":"arena","title":"Normal mode 7: the gate's modal, a run's stages with times, the failing check's output and the review's verdict","why":"normal mode step 7: the gate's modal, a run's stages with times and the failing check; after #338"}]}}
    );
    defer b.deinit();
    var app: App = .{ .gpa = std.testing.allocator, .io = undefined, .tmux_in = undefined };
    var buf: [4096]u8 = undefined;
    for (8..120) |width| {
        var f: feed.Feed = undefined;
        feed.build(&f, &b, &.{}, width, 80, 1795262400, 0, .{});
        for (0..f.itemCount() + 1) |pick| {
            app.board_view = .{ .home = true, .focus = .orchestrator, .pick = pick };
            for (0..f.count() + 1) |row| {
                for (2..140) |inner| {
                    var out: Writer = .fixed(&buf);
                    var pen: Pen = .{};
                    try feedRow(&app, &out, &pen, &f, row, @intCast(inner));
                }
            }
        }
    }
}

/// A board the size of the one the human called laggy: five repos, 23 to do, 7 doing, 2 in
/// review and 330 done, titles long enough to wrap.
fn bigBoard(gpa: std.mem.Allocator) !tickets.Board {
    var json: std.Io.Writer.Allocating = .init(gpa);
    defer json.deinit();
    const w = &json.writer;
    try w.writeAll("{\"tickets\":[");
    const repos = [_][]const u8{ "arena", "babylon", "ficciones", "menard", "tlon" };
    const counts = [_]struct { []const u8, usize }{ .{ "todo", 23 }, .{ "doing", 7 }, .{ "review", 2 }, .{ "done", 330 } };
    var id: usize = 1;
    for (counts) |count| for (0..count[1]) |k| {
        if (id > 1) try w.writeAll(",");
        try w.print(
            \\{{"id":{d},"repo":"{s}","title":"A ticket title long enough to wrap twice in a column, as the board's titles do, number {d}","status":"{s}","priority":"{s}","claimed_by":{s},"blocked_by":{s},"closed_at":"2026-11-20T10:00:00Z","inserted_at":"2026-11-20T09:00:00Z"}}
        , .{ id, repos[k % repos.len], id, count[0], if (k % 3 == 0) "high" else "med", if (std.mem.eql(u8, count[0], "doing")) "\"%3\"" else "null", if (k % 7 == 1 and std.mem.eql(u8, count[0], "todo")) "[1]" else "[]" });
        id += 1;
    };
    try w.writeAll("],\"needs_you\":[]}");
    return tickets.Board.parse(gpa, json.written());
}

test "a frame of a board of five repos and 362 cards walks the cards under 3000 times" {
    const gpa = std.testing.allocator;
    var board = try bigBoard(gpa);
    defer board.deinit();
    var app: App = .{ .gpa = gpa, .io = std.testing.io, .tmux_in = undefined };
    app.term_w = 240;
    app.view_w = 80;
    app.view_h = 60;
    app.board = board;
    app.listed = true;
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    const views = [_]app_mod.BoardView{
        .{ .home = true },
        .{ .home = true, .col = 0, .row = 3, .lane = 2 },
        .{ .home = true, .repo = 1 },
        .{ .home = true, .backlog = true },
    };
    // Walks, not time, which a loaded machine stretches: a frame is slow when per-line helpers each
    // walk the whole board. Today's views take 157 to 2420; a helper scanning per line takes far more.
    for (views) |view| {
        app.board_view = view;
        tickets.passes = 0;
        out.clearRetainingCapacity();
        try frame(&app, &out.writer, .all);
        try std.testing.expect(tickets.passes < 3000);
    }
}

test "a draft's modal draws the outcome, a row to each step with what it waits on, the pick, and the keys" {
    const gpa = std.testing.allocator;
    var board = try tickets.Board.parse(gpa,
        \\{"tickets":[],"backlog":[
        \\{"id":830,"repo":"tlon","kind":"epic","title":"The bar shows what is safe to spend","status":"backlog"},
        \\{"id":832,"repo":"tlon","model":"claude-sonnet-5-5","title":"safe-to-spend as a file","status":"backlog","epic_id":830},
        \\{"id":833,"repo":"ficciones","model":"claude-haiku-5-5","title":"the bar reads it","status":"backlog","epic_id":830,"blocked_by":[832]}],
        \\"plan":{"ideas":[{"epic":830,"title":"The bar","state":"draft","steps":2,"body":"the bar shows spend",
        \\"ask_list":[{"id":1,"question":"tlon or ficciones?","answer":"tlon"},{"id":2,"question":"which timer?","answer":null}]}]}}
    );
    defer board.deinit();
    var app: App = .{ .gpa = gpa, .io = std.testing.io, .tmux_in = undefined };
    app.term_w = 160;
    app.view_w = 100;
    app.view_h = 40;
    app.board = board;
    app.board_view = .{ .home = true, .plan = true, .draft = 830, .draft_pick = 1 };
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    try frame(&app, &out.writer, .all);
    const drawn = out.written();
    for ([_][]const u8{ "draft #830", "The bar shows what is safe to spend", "from your idea: \"the bar shows spend\"", "asked you: \"tlon or ficciones?\" you: \"tlon\"", "asked you: \"which timer?\" (open)", "1 #832 tlon", "sonnet", "free", "2 #833 ficciones", "haiku", "← #832", "y go   r reply with changes" }) |want| {
        std.testing.expect(std.mem.indexOf(u8, drawn, want) != null) catch |err| {
            std.debug.print("missing {s}\n", .{want});
            return err;
        };
    }
}

fn wordsFrame(gpa: std.mem.Allocator, json: []const u8, prompt: menu.Prompt, out: *std.Io.Writer.Allocating) !App {
    var app: App = .{ .gpa = gpa, .io = std.testing.io, .tmux_in = undefined };
    app.term_w = 160;
    app.view_w = 60;
    app.view_h = 40;
    app.board = try tickets.Board.parse(gpa, json);
    app.board_view = .{ .home = true, .plan = true, .focus = .orchestrator };
    app.prompt = prompt;
    try frame(&app, &out.writer, .all);
    return app;
}

test "a ✗'s words are a modal over the column: its title, the check quoted, the box, send and cancel, and no line at the column's foot" {
    const gpa = std.testing.allocator;
    var prompt: menu.Prompt = .{ .what = .words };
    const item = "try:825#3";
    @memcpy(prompt.target[0..item.len], item);
    prompt.target_len = item.len;
    for ("it never answers") |byte| _ = prompt.press(&.{byte});
    _ = prompt.press("\n");
    for ("not even once") |byte| _ = prompt.press(&.{byte});
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    var app = try wordsFrame(gpa, feed.try_sample, prompt, &out);
    defer app.board.?.deinit();
    const drawn = out.written();
    for ([_][]const u8{ "✗ What went wrong?", "check 3: add a to-do from the phone", "❯ it never answers", "  not even once", " ⏎ send it back ", " esc cancel ", "shift+⏎ new line" }) |want| {
        std.testing.expect(std.mem.indexOf(u8, drawn, want) != null) catch |err| {
            std.debug.print("missing {s}\n", .{want});
            return err;
        };
    }
    try std.testing.expect(std.mem.indexOf(u8, drawn, "esc not ✗") == null);
    try std.testing.expect(std.mem.indexOf(u8, drawn, "\x1b[>4;1m") != null);
}

test "an ask's own words are a modal with the question and its options quoted; the frame is the same size for one line and for a long text, which scrolls to its end" {
    const gpa = std.testing.allocator;
    const json =
        \\{"tickets":[],"needs_you":[{"id":"ask:6","kind":"ask","ticket":307,"repo":"tlon","text":"#307 tlon  asks: Blue or green?",
        \\ "actions":[{"key":"1","label":"Blue","argv":["babylon","answer","6","1"]},{"key":"c","label":"in my own words","argv":["babylon","answer","6","--words"],"needs":"words"}]}]}
    ;
    var short: menu.Prompt = .{ .what = .words };
    @memcpy(short.target[0..5], "ask:6");
    short.target_len = 5;
    _ = short.press("a");
    var long = short;
    for (0..30) |i| {
        var line: [16]u8 = undefined;
        for (std.fmt.bufPrint(&line, "line {d}", .{i}) catch "") |byte| _ = long.press(&.{byte});
        _ = long.press("\n");
    }
    var one: std.Io.Writer.Allocating = .init(gpa);
    defer one.deinit();
    var app_one = try wordsFrame(gpa, json, short, &one);
    defer app_one.board.?.deinit();
    var many: std.Io.Writer.Allocating = .init(gpa);
    defer many.deinit();
    var app_many = try wordsFrame(gpa, json, long, &many);
    defer app_many.board.?.deinit();

    const has = std.mem.indexOf;
    for ([_][]const u8{ "✎ in my own words", "#307 tlon  asks: Blue or green?", "1 Blue", " ⏎ send ", " esc cancel " }) |want| {
        std.testing.expect(has(u8, one.written(), want) != null) catch |err| {
            std.debug.print("missing {s}\n", .{want});
            return err;
        };
    }
    // the frame's top and foot edges are drawn at the same place whatever is typed
    const rect = app_one.wordsRect();
    var top: [32]u8 = undefined;
    const edge = try std.fmt.bufPrint(&top, "\x1b[{d};{d}H╭─", .{ rect.y + 1, rect.x + 1 });
    try std.testing.expect(has(u8, one.written(), edge) != null);
    try std.testing.expect(has(u8, many.written(), edge) != null);
    var foot: [32]u8 = undefined;
    const base = try std.fmt.bufPrint(&foot, "\x1b[{d};{d}H╰─", .{ rect.y + rect.h, rect.x + 1 });
    try std.testing.expect(has(u8, many.written(), base) != null);
    // a box of a fixed height scrolls: the last lines are shown, the first are not
    try std.testing.expect(has(u8, many.written(), "line 29") != null);
    try std.testing.expect(has(u8, many.written(), "line 0 ") == null);
}

/// An epic with seven children, three done, one doing and three todo, its goal's own count wrong
/// so that a count read from the children shows; the epic itself doing, and one more in the backlog.
const epic_board =
    \\{"tickets":[
    \\{"id":326,"repo":"arena","kind":"epic","status":"doing","title":"The board, redesigned"},
    \\{"id":11,"repo":"arena","title":"done a","status":"done","epic_id":326,"closed_at":"2026-11-24T00:00:00Z"},
    \\{"id":12,"repo":"arena","title":"done b","status":"done","epic_id":326,"closed_at":"2026-11-24T00:00:00Z"},
    \\{"id":13,"repo":"arena","title":"done c","status":"done","epic_id":326,"closed_at":"2026-11-24T00:00:00Z"},
    \\{"id":14,"repo":"arena","title":"building one","status":"doing","epic_id":326,"claimed_by":"%3"},
    \\{"id":15,"repo":"arena","title":"todo a","status":"todo","epic_id":326},
    \\{"id":16,"repo":"arena","title":"todo b","status":"todo","epic_id":326},
    \\{"id":17,"repo":"arena","title":"todo c","status":"todo","epic_id":326}],
    \\"backlog":[{"id":500,"repo":"arena","kind":"epic","status":"backlog","title":"Later goal"}],
    \\"plan":{"goals":[{"epic":326,"title":"The board, redesigned","landed":0,"total":99,"steps":[]}]}}
;

fn epicApp(roles: bool, view_h: u16, width: u16) !App {
    var app: App = .{ .gpa = std.testing.allocator, .io = undefined, .tmux_in = undefined };
    app.term_w = width;
    app.view_w = width;
    app.view_h = view_h;
    if (roles) app.roles = bench.roles();
    app.board = try tickets.Board.parse(std.testing.allocator, epic_board);
    app.board_view = .{};
    return app;
}

test "an epic with no bar is a row in its column, never a Claude: a short terminal, the classic look, the backlog" {
    const has = std.mem.indexOf;
    var buf: [1 << 18]u8 = undefined;
    var short = try epicApp(true, 14, 200);
    defer short.board.?.deinit();
    try std.testing.expectEqual(@as(u16, 0), short.epicRows());
    try std.testing.expectEqual(@as(usize, 2), short.boardColumnAll(1));
    var out: Writer = .fixed(&buf);
    try boardView(&short, &out, short.board_view.?);
    try std.testing.expect(has(u8, out.buffered(), "epic 3/7") != null);

    var classic = try epicApp(false, 24, 200);
    defer classic.board.?.deinit();
    try std.testing.expectEqual(@as(u16, 0), classic.epicRows());
    out = .fixed(&buf);
    try boardView(&classic, &out, classic.board_view.?);
    try std.testing.expect(has(u8, out.buffered(), "epic · 3/7 landed") != null);
    try std.testing.expect(has(u8, out.buffered(), "no Claude holds it") == null);

    var backlog = try epicApp(true, 24, 80);
    defer backlog.board.?.deinit();
    backlog.board_view = .{ .backlog = true };
    try std.testing.expectEqual(@as(u16, 0), backlog.epicRows());
    out = .fixed(&buf);
    try boardView(&backlog, &out, backlog.board_view.?);
    try std.testing.expect(has(u8, out.buffered(), "Later goal") != null);
    try std.testing.expect(has(u8, out.buffered(), "epic") != null);
}

test "an epic on the board in Workbench's look is a bar over the columns, counted from its children, and no card in doing" {
    var app = try epicApp(true, 24, 80);
    defer app.board.?.deinit();
    const r = app.roles.?;
    var buf: [1 << 18]u8 = undefined;
    var out: Writer = .fixed(&buf);
    try boardView(&app, &out, app.board_view.?);
    const drawn = out.buffered();
    const eq = std.testing.expectEqual;
    const hue = r.repo[0];

    try eq(@as(u16, 3), app.epicRows());
    const y = App.first_line - 1;
    try eq(@as(u21, '◆'), (try bench.probe(drawn, 1, y)).cp);
    try eq(hue, (try bench.probe(drawn, 1, y)).fg);
    try eq(@as(u21, '#'), (try bench.probe(drawn, 3, y)).cp);
    try eq(hue, (try bench.probe(drawn, 4, y + 1)).fg);

    try std.testing.expect(std.mem.indexOf(u8, drawn, "3/7") != null);
    try std.testing.expect(std.mem.indexOf(u8, drawn, "/99") == null);
    try std.testing.expect(std.mem.indexOf(u8, drawn, "1 building") != null);

    // the columns start under the bars, and doing holds the step alone
    try eq(@as(u16, 6), app.colTop());
    try eq(@as(usize, 1), app.boardColumnAll(1));
}

test "Home in Workbench's look: the focal goal is the one with a step building, and a goal's card has its bar in its repo's hue" {
    var board = try tickets.Board.parse(std.testing.allocator,
        \\{"tickets":[
        \\{"id":326,"repo":"arena","kind":"epic","status":"doing","title":"The board, redesigned"},
        \\{"id":410,"repo":"menard","kind":"epic","status":"doing","title":"menard runs zig too"},
        \\{"id":760,"repo":"arena","status":"doing","epic_id":326,"title":"Visual redesign"}],
        \\"plan":{"now":[{"ticket":760,"repo":"arena","title":"Visual redesign","state":"building","since":"2026-11-24T04:38:21Z"}],
        \\"next":[{"ticket":761,"repo":"arena","title":"arena crashes","why":"the crash","set_by":"human","waits_on":[{"lane":"arena","until":757}]}],
        \\"goals":[
        \\{"epic":410,"title":"menard runs zig too","landed":2,"total":7,"steps":[{"ticket":592,"state":"todo"}]},
        \\{"epic":326,"title":"The board, redesigned","landed":13,"total":18,"steps":[{"ticket":760,"state":"building"},{"ticket":338,"state":"sent_back"},{"ticket":346,"state":"waiting","waits_on":[{"ticket":760}]}]}],
        \\"landed_today":{"count":23,"newest":[632,754]},
        \\"not_planned":{"count":21,"follow_ups":9,"by_repo":{"arena":11,"tlon":4}}}}
    );
    defer board.deinit();
    var app = homeApp(&board);
    app.term_w = 80;
    app.view_w = 80;
    app.view_h = 23;
    app.roles = bench.roles();
    app.board_view = .{ .home = true, .plan = true, .alone = false, .focus = .board };
    const r = bench.roles();

    var sheet: sheets.Sheet = undefined;
    try std.testing.expect(app.planSheet(&sheet));
    // the goal with a step building, not the first listed
    try std.testing.expectEqual(@as(usize, 1), sheet.rows[0].item);

    var buf: [65536]u8 = undefined;
    var out: Writer = .fixed(&buf);
    try planView(&app, &out, app.board_view.?);
    const f = out.buffered();

    // the first goal's card in the goals window: its bar row, 2 of 7 in menard's hue on the well
    var at: usize = 0;
    for (sheet.rows[0..sheet.n], 0..) |row, i| {
        if (row.kind == .goal_bar and row.item == 0) at = i;
    }
    const slot = app.planSlot(.goals);
    const y = slot.y + 1 + (at - sheet.span(.goals).start);
    const x = slot.x + 1 + 2;
    const bar_w = (slot.w - 1 - 2) - 4 - "2/7  28%".len;
    const filled = try bench.probe(f, x, y);
    try std.testing.expectEqual(@as(u21, '█'), filled.cp);
    try std.testing.expectEqual(r.repo[3], filled.fg);
    try std.testing.expectEqual(r.well, filled.bg);
    const empty = try bench.probe(f, x + bar_w - 1, y);
    try std.testing.expectEqual(@as(u21, ' '), empty.cp);
    try std.testing.expectEqual(r.well, empty.bg);
}

test "a goal with a step to try reads ▲ 1 to try after its bar in the you colour, and the step's chip reads ▲ to try" {
    var board = try tickets.Board.parse(std.testing.allocator,
        \\{"tickets":[
        \\{"id":326,"repo":"arena","kind":"epic","status":"doing","title":"The board, redesigned"}],
        \\"plan":{"now":[],"next":[],
        \\"goals":[{"epic":326,"title":"The board, redesigned","landed":2,"total":3,"steps":[{"ticket":7,"state":"to_try"}]}],
        \\"landed_today":{"count":0,"newest":[]},
        \\"not_planned":{"count":0,"follow_ups":0,"by_repo":{}}}}
    );
    defer board.deinit();
    var app = homeApp(&board);
    app.term_w = 80;
    app.view_w = 80;
    app.view_h = 23;
    app.roles = bench.roles();
    app.board_view = .{ .home = true, .plan = true, .alone = false, .focus = .board };
    const r = bench.roles();

    var sheet: sheets.Sheet = undefined;
    try std.testing.expect(app.planSheet(&sheet));
    var buf: [65536]u8 = undefined;
    var out: Writer = .fixed(&buf);
    try planView(&app, &out, app.board_view.?);
    const f = out.buffered();

    var at: usize = 0;
    for (sheet.rows[0..sheet.n], 0..) |row, i| {
        if (row.kind == .goal_bar and row.item == 0) at = i;
    }
    const rect = app.planSlot(.goals);
    const y = rect.y + 1 + (at - sheet.span(.goals).start) - app.planWindowTop(&sheet, .goals, rect.h - sheets.window_chrome);
    const cw = rect.w - 1 - 2;
    const label_x = rect.x + 1 + 3 + cw -| 4 -| "2/3  66%".len -| 10 -| 2;
    const words_x = label_x + "2/3  66%".len + 2;
    const mark = try bench.probe(f, words_x, y);
    try std.testing.expectEqual(@as(u21, '▲'), mark.cp);
    try std.testing.expectEqual(r.you, mark.fg);
    const last = try bench.probe(f, words_x + 9, y);
    try std.testing.expectEqual(@as(u21, 'y'), last.cp);

    var chip_buf: [4096]u8 = undefined;
    var chip_out: Writer = .fixed(&chip_buf);
    _ = try stepChip(&chip_out, r, 4, 2, board.plan().?.goals[0].steps[0]);
    try std.testing.expect(std.mem.indexOf(u8, chip_out.buffered(), "#7 ▲ to try") != null);
}

test "babylon's refusal, said while the plan is shown, is on screen" {
    var board = try tickets.Board.parse(std.testing.allocator,
        \\{"tickets":[{"id":760,"repo":"arena","status":"doing","title":"Visual redesign"}],
        \\"plan":{"now":[{"ticket":760,"repo":"arena","title":"Visual redesign","state":"building","since":"2026-11-24T04:38:21Z"}],
        \\"next":[],"goals":[],"landed_today":{"count":0,"newest":[]},"not_planned":{"count":0,"follow_ups":0,"by_repo":{}}}}
    );
    defer board.deinit();
    var app = homeApp(&board);
    app.term_w = 80;
    app.view_w = 80;
    app.view_h = 23;
    app.roles = bench.roles();
    app.board_view = .{ .home = true, .plan = true, .alone = false, .focus = .board };
    try std.testing.expect(app.planShown());
    try std.testing.expect(app.barRows() > 0);
    app.report_said = try std.testing.allocator.dupe(u8, "babylon: repo arena is held");
    defer std.testing.allocator.free(app.report_said.?);
    var buf: [65536]u8 = undefined;
    var out: Writer = .fixed(&buf);
    try frame(&app, &out, .all);
    try std.testing.expect(std.mem.indexOf(u8, out.buffered(), "babylon: repo arena is held") != null);
}

test "a card's popup in Workbench's look: a window with its ✕, the title whole, the ask's options as buttons and the facts as chips" {
    var app: App = .{ .gpa = std.testing.allocator, .io = undefined, .tmux_in = undefined };
    app.term_w = 80;
    app.view_w = 80;
    app.view_h = 24;
    app.roles = bench.roles();
    const r = app.roles.?;
    app.board = try tickets.Board.parse(std.testing.allocator,
        \\{"tickets":[
        \\{"id":4,"repo":"tlon","title":"Which direction should the board take","status":"doing","priority":"high","model":"claude-opus-5-5","claimed_by":"%12","claimed_at":"2026-11-24T00:00:00Z",
        \\ "ask":{"id":9,"question":"Which one?","options":["Phosphor","Workbench"]}}
        \\]}
    );
    defer app.board.?.deinit();
    app.board_view = .{ .col = 1, .detail = 4 };
    var buf: [65536]u8 = undefined;
    var out: Writer = .fixed(&buf);
    try boardView(&app, &out, app.board_view.?);
    const drawn = out.buffered();
    const eq = std.testing.expectEqual;
    const rect = app.modalRect().?;

    // the title bar is raised with its ✕ at the right, the face below it the panel, a shadow beside
    try eq(@as(u21, '◆'), (try bench.probe(drawn, rect.x + 1, rect.y)).cp);
    const close = try bench.probe(drawn, rect.x + rect.w - 4, rect.y);
    try eq(@as(u21, '✕'), close.cp);
    try eq(r.raised, close.bg);
    try eq(r.panel, (try bench.probe(drawn, rect.x + 3, rect.y + 8)).bg);
    try eq(@as(u21, '▌'), (try bench.probe(drawn, rect.x + rect.w - 1, rect.y + 3)).cp);

    // the whole title in bold, then the facts: the repo's chip in its hue, the high dot in red
    const title = try bench.probe(drawn, rect.x + 2, rect.y + 1);
    try eq(@as(u21, 'W'), title.cp);
    try std.testing.expect(title.bold);
    const repo = try bench.probe(drawn, rect.x + 2 + 1, rect.y + 2);
    try eq(@as(u21, 't'), repo.cp);
    try eq(r.repo[4], repo.fg);

    // the ask in violet, its options buttons: the first filled amber, the next raised
    var buttons: [16]App.ModalButton = undefined;
    var options: [2]App.ModalButton = undefined;
    var n: usize = 0;
    for (app.modalButtons(&buttons)) |b| if (b.action == .option and b.y < rect.y + rect.h - 1) {
        options[n] = b;
        n += 1;
    };
    try eq(@as(usize, 2), n);
    try eq(r.you, (try bench.probe(drawn, rect.x + 2, options[0].y - 1)).fg);
    try eq(r.accent, (try bench.probe(drawn, options[0].x, options[0].y)).bg);
    try eq(r.raised, (try bench.probe(drawn, options[1].x, options[1].y)).bg);
}

test "the orchestrator's column in Workbench: Your move's three items are tiles led by their kind's chip, each with its buttons raised" {
    var board = try tickets.Board.parse(std.testing.allocator,
        \\{"tickets":[],"orchestrator":{"on":true,"running":true},
        \\"needs_you":[
        \\{"id":"ask-52","kind":"ask","ticket":760,"repo":"arena","text":"Which visual direction should the board and Home take?",
        \\ "actions":[{"key":"1","label":"Phosphor"},{"key":"2","label":"Workbench"},{"key":"c","label":"in words","needs":"words"}]},
        \\{"id":"back-338","kind":"sent_back","ticket":338,"repo":"arena","text":"sent back, free: the review asked for the action row",
        \\ "actions":[{"key":"G","label":"give"},{"key":"⏎","label":"start"},{"key":"x","label":"close"}]},
        \\{"id":"prop-41","kind":"proposal","ticket":612,"repo":"tlon","text":"start #612 next: high, two days old",
        \\ "actions":[{"key":"⏎","label":"go"},{"key":"x","label":"no"}]}]}
    );
    defer board.deinit();
    var app = homeApp(&board);
    app.term_w = 80;
    app.view_w = 80;
    app.view_h = 23;
    app.roles = bench.roles();
    const r = bench.roles();
    var f: feed.Feed = undefined;
    try std.testing.expect(app.feedOf(&f));
    var buf: [262144]u8 = undefined;
    var out: Writer = .fixed(&buf);
    try sideEmpty(&app, &out);
    const frame_out = out.buffered();

    const head = try bench.probe(frame_out, 2, 1);
    try std.testing.expectEqual(@as(u21, '▲'), head.cp);
    try std.testing.expectEqual(r.you, head.fg);
    try std.testing.expectEqual(r.panel, head.bg);

    // each item's row: the pick on the first, its chip filled in its kind's colour
    const kinds = [_]theme.RGB{ r.you, r.failed, r.accent };
    var seen: usize = 0;
    for (0..f.count()) |i| {
        if (f.line(i).kind != .item) continue;
        const y = i + 1;
        const lit = seen == 0;
        const bg = if (lit) r.raised else r.tile;
        const lead = try bench.probe(frame_out, 2, y);
        try std.testing.expectEqual(@as(u21, if (lit) '▌' else ' '), lead.cp);
        try std.testing.expectEqual(bg, lead.bg);
        const chip_cell = try bench.probe(frame_out, 4, y);
        try std.testing.expectEqual(@as(u21, '▎'), chip_cell.cp);
        try std.testing.expectEqual(kinds[seen], chip_cell.fg);
        try std.testing.expectEqual(kinds[seen], chip_cell.bg);
        // its buttons on the row under: raised with the key in amber, a proposal's ⏎ the filled primary
        const button = try bench.probe(frame_out, 5, y + 1);
        try std.testing.expectEqual(if (seen == 2) r.accent else r.raised, button.bg);
        try std.testing.expectEqual(if (seen == 2) r.on_accent else r.accent, button.fg);
        seen += 1;
    }
    try std.testing.expectEqual(@as(usize, 3), seen);

    // the foot is a well
    const foot = try bench.probe(frame_out, 5, app.view_h - 1);
    try std.testing.expectEqual(r.well, foot.bg);
}

const peek_w = 60;
const peek_rows = 7;
const PeekInk = enum { head, plain, dim };
const PeekRow = struct { text: []const u8, ink: PeekInk };
const PeekRows = struct {
    store: [20][200]u8 = undefined,
    rows: [20]PeekRow = undefined,
    n: usize = 0,

    fn add(p: *PeekRows, ink_: PeekInk, comptime fmt: []const u8, args: anytype) void {
        if (p.n >= p.rows.len) return;
        const slot = &p.store[p.n];
        var wr: Writer = .fixed(slot);
        const text = if (wr.print(fmt, args)) |_| wr.buffered() else |_| cut: {
            var end = @min(wr.end, slot.len - "…".len);
            while (end > 0 and slot[end] & 0xC0 == 0x80) end -= 1;
            @memcpy(slot[end..][0.."…".len], "…");
            break :cut slot[0 .. end + "…".len];
        };
        p.rows[p.n] = .{ .text = text, .ink = ink_ };
        p.n += 1;
    }
};

/// The peek of a ticket or a Claude, boxed over what is under it: the ticket, where it stands,
/// what its Claude is doing, and the last lines of its pane, with the keys at its foot.
fn lookBox(app: *App, w: *Writer, look: App.Look) !void {
    var p: PeekRows = .{};
    if (look == .fold) {
        var members: [16]App.Agent = undefined;
        const n = app.foldMembers(look.fold, &members);
        if (n == 0) return;
        p.add(.head, "{d} Claude{s} not moving", .{ n, if (n == 1) "" else "s" });
        for (members[0..n]) |a| {
            const id = std.fmt.parseInt(u32, app_mod.branchTicket(a.win.text(.branch)) orelse "", 10) catch null;
            const card = if (id) |i| app.ticketCard(i) else null;
            if (card) |c| {
                p.add(.plain, "{u} #{d} {s}{s}{s}", .{ agentGlyph(app, a.win), c.id, c.title, if (c.stage != null) " · " else "", c.stage orelse "" });
            } else p.add(.plain, "{u} {s}", .{ agentGlyph(app, a.win), a.win.label() });
        }
        p.add(.head, "esc away", .{});
        return peekBox(app, w, &p);
    }
    const peek = app.peekOf(look) orelse return;
    var age_buf: [8]u8 = undefined;
    if (peek.card) |card| {
        p.add(.head, "#{d} {s}", .{ card.id, card.title });
        p.add(.dim, "{s} · {s} · {s}", .{ card.repo orelse "no repo", card.priority, card.model orelse "default model" });
        var rel: [120]u8 = undefined;
        var rw: Writer = .fixed(&rel);
        if (card.blocked_by.len > 0) {
            rw.writeAll("blocked by") catch {};
            for (card.blocked_by) |id| rw.print(" #{d}", .{id}) catch {};
        }
        var blocks = false;
        if (app.board) |*b| for (b.cards()) |*other| {
            if (std.mem.indexOfScalar(u32, other.blocked_by, card.id) == null) continue;
            if (!blocks) rw.writeAll(if (rw.end > 0) " · blocks" else "blocks") catch {};
            rw.print(" #{d}", .{other.id}) catch {};
            blocks = true;
        };
        if (rw.end > 0) p.add(.dim, "{s}", .{rw.buffered()});
        const since: u32 = if (tickets.epochOf(card.stage_at orelse card.claimed_at)) |e| @intCast(@max(0, e)) else 0;
        const age = ago(&age_buf, app.epoch, since);
        const gap: []const u8 = if (age.len > 0) " · " else "";
        if (card.status == .doing and card.stage_note.len > 0) {
            p.add(.plain, "sent back · {s}{s}{s}", .{ std.mem.sliceTo(card.stage_note, '\n'), gap, age });
        } else {
            const stage = card.stage orelse "";
            p.add(.plain, "{s}{s}{s}{s}{s}", .{ @tagName(card.status), if (stage.len > 0) " · " else "", stage, gap, age });
        }
    } else if (peek.win) |win| p.add(.head, "{s}", .{win.label()});
    if (peek.win) |win| {
        var extra: [80]u8 = undefined;
        var ew: Writer = .fixed(&extra);
        if (win.ctx > 0) ew.print(" · {d}% context", .{@min(win.ctx, 999)}) catch {};
        if (win.text(.background).len > 0) ew.print(" · {s}", .{win.text(.background)}) catch {};
        if (win.subs() > 0) ew.print(" · {d} agent{s}", .{ win.subs(), if (win.subs() == 1) "" else "s" }) catch {};
        p.add(.plain, "{u} {s}{s}", .{ agentGlyph(app, win), @tagName(win.claude), ew.buffered() });
        const doing = win.text(.doing);
        const said = std.mem.sliceTo(win.text(.said), '\n');
        if (doing.len > 0) p.add(.plain, "doing: {s}", .{doing});
        if (said.len > 0) p.add(.dim, "said: {s}", .{said});
        if (app.paneById(win.agent_pane)) |pane| {
            var buf: [peek_rows * 200]u8 = undefined;
            var tail: [peek_rows][]const u8 = undefined;
            const got = App.paneTail(pane, &buf, 200, &tail);
            for (tail[0..got]) |line| p.add(.dim, "{s}", .{line});
        }
    } else p.add(.dim, "no Claude holds it", .{});
    if (peek.card) |card| if (card.ask != null) {
        p.add(.head, "⏎ answer   space open card   esc away", .{});
        return peekBox(app, w, &p);
    };
    p.add(.head, "⏎ go   space open card   esc away", .{});
    return peekBox(app, w, &p);
}

fn peekBox(app: *App, w: *Writer, p: *const PeekRows) !void {
    const n = p.n;
    const bw: u16 = @min(peek_w, app.term_w -| 2);
    if (bw < 20 or app.view_h < n + 2) return;
    const inner: u16 = bw - 4;
    const h: u16 = @intCast(n + 2);
    var x: u16 = (app.term_w - bw) / 2;
    var y: u16 = @min(3, app.view_h + 1 - h);
    if (app.look_here) |at| {
        x = @min(at.x + 2, app.term_w - bw);
        y = @min(at.y + 2, app.view_h + 1 - h);
    }
    const edge = ink(app, "amber", 4);
    var pen: Pen = .{};
    try pen.set(w, edge, null);
    try w.print("\x1b[{d};{d}H╭", .{ y + 1, x + 1 });
    for (0..bw - 2) |_| try w.writeAll("─");
    try w.writeAll("╮");
    for (p.rows[0..n], 0..) |row, i| {
        const style: vt.Style = switch (row.ink) {
            .head => heading(app),
            .plain => .{},
            .dim => ink(app, "dim", 8),
        };
        try boxLine(w, &pen, edge, style, x, y + 2 + @as(u16, @intCast(i)), row.text, inner);
    }
    try pen.set(w, edge, null);
    try w.print("\x1b[{d};{d}H╰", .{ y + 2 + n, x + 1 });
    for (0..bw - 2) |_| try w.writeAll("─");
    try w.writeAll("╯");
}

test "a peek row too long for its slot is cut at a whole character and ends in …" {
    var p: PeekRows = .{};
    var long: [250]u8 = undefined;
    @memset(&long, 'x');
    p.add(.head, "#1 {s}", .{long});
    var multi: [300]u8 = undefined;
    for (0..150) |i| @memcpy(multi[i * 2 ..][0..2], "é");
    p.add(.dim, "{s}", .{multi});
    p.add(.plain, "short", .{});
    for (p.rows[0..2]) |row| {
        try std.testing.expect(row.text.len <= 200);
        try std.testing.expect(std.mem.endsWith(u8, row.text, "…"));
        try std.testing.expect(std.unicode.utf8ValidateSlice(row.text));
    }
    try std.testing.expect(std.mem.startsWith(u8, p.rows[0].text, "#1 xxx"));
    try std.testing.expectEqualStrings("short", p.rows[2].text);
}

test "the plan's head and the board's head show the same pair of tabs, the current one lit" {
    var board = try tickets.Board.parse(std.testing.allocator, epic_board);
    defer board.deinit();
    var app = homeApp(&board);
    app.view_w = 80;
    app.term_w = 80;
    const eq = std.testing.expectEqual;
    var buf: [1 << 17]u8 = undefined;
    const views = [_]app_mod.BoardView{ .{ .home = true, .plan = true, .alone = false, .focus = .board }, .{} };
    for (views, 0..) |view, i| {
        app.board_view = view;
        var out: Writer = .fixed(&buf);
        try boardView(&app, &out, view);
        const drawn = out.buffered();
        const plan = try bench.probe(drawn, app.planTab().x, 0);
        const link = try bench.probe(drawn, app.planLink().x, 0);
        try eq(@as(u21, 'b'), plan.cp);
        try eq(@as(u21, 'B'), link.cp);
        try eq(i == 0, plan.bold);
        try eq(i == 1, link.bold);
    }
}

test "a card to try wears ▲ try it in the you colour, filled, and leads the recent strip with the same mark" {
    var app: App = .{ .gpa = std.testing.allocator, .io = undefined, .tmux_in = undefined };
    app.term_w = 80;
    app.view_w = 80;
    app.view_h = 24;
    app.roles = bench.roles();
    const r = app.roles.?;
    app.board = try tickets.Board.parse(std.testing.allocator,
        \\{"tickets":[
        \\{"id":2,"repo":"menard","title":"old","status":"done","closed_at":"2026-11-24T00:00:00Z"},
        \\{"id":7,"repo":"tlon","title":"Lights","status":"try","stage":"landed","checks":[{"n":1,"text":"it is told","result":null}]},
        \\{"id":8,"repo":"tlon","title":"Ask","status":"review","ask":{"id":1,"question":"q?"}}
        \\]}
    );
    defer app.board.?.deinit();
    const eq = std.testing.expectEqual;
    var buf: [64]u8 = undefined;
    const state = benchState(&app, &app.board.?.cards()[1], r, &buf).?;
    try std.testing.expectEqualStrings("▲ try it", state.label);
    try eq(r.you, state.lead);
    try eq(r.on_accent, state.words);
    try std.testing.expect(state.filled);
    const asks = benchState(&app, &app.board.?.cards()[2], r, &buf).?;
    try std.testing.expectEqualStrings("▲ asks you", asks.label);
    try std.testing.expect(!std.mem.eql(u8, state.label, asks.label));

    app.board_view = .{};
    var out_buf: [65536]u8 = undefined;
    var out: Writer = .fixed(&out_buf);
    try boardView(&app, &out, app.board_view.?);
    const first = try bench.probe(out.buffered(), 1, app.listH() + 1);
    try eq(@as(u21, '▲'), first.cp);
    try eq(r.you, first.fg);
}

test "a to-try tile is drawn: its chip, its age in the you colour at a week, the machine's line, a check's rows, the picked check's buttons and its tile's close untried" {
    var b = try tickets.Board.parse(std.testing.allocator, feed.try_sample);
    defer b.deinit();
    var app: App = .{ .gpa = std.testing.allocator, .io = undefined, .tmux_in = undefined };
    app.roles = @import("parts.zig").roles();
    const r = app.roles.?;
    var f: feed.Feed = undefined;
    feed.buildPicked(&f, &b, &.{}, &.{}, 56, 80, 1795262400, 0, .{}, 2);
    var buf: [2048]u8 = undefined;
    var want: [64]u8 = undefined;
    const Rows = struct {
        fn at(app_: *const App, f_: *const feed.Feed, out_: []u8, row: usize) ![]const u8 {
            var out: Writer = .fixed(out_);
            var pen: Pen = .{};
            try feedRow(app_, &out, &pen, f_, row, 56);
            return out.buffered();
        }
        fn has(drawn: []const u8, text: []const u8) bool {
            return std.mem.indexOf(u8, drawn, text) != null;
        }
    };

    const head = try Rows.at(&app, &f, &buf, 2);
    try std.testing.expect(Rows.has(head, "── to try 2 ─"));

    const title = try Rows.at(&app, &f, &buf, 3);
    try std.testing.expect(Rows.has(title, "try"));
    try std.testing.expect(Rows.has(title, "#825 tlon  house soak day"));
    try std.testing.expect(Rows.has(title, try sgr(&want, paintStyle(r.dim, r.tile, false))));
    try std.testing.expect(!Rows.has(title, try sgr(&want, paintStyle(r.you, r.tile, true))));

    const machine = try Rows.at(&app, &f, &buf, 4);
    try std.testing.expect(Rows.has(machine, "soak day ✓  gate ✓  review ✓"));
    try std.testing.expect(Rows.has(machine, "close untried"));

    const first = try Rows.at(&app, &f, &buf, 5);
    try std.testing.expect(Rows.has(first, "1 remind me in two minutes"));
    const settled = try Rows.at(&app, &f, &buf, 7);
    try std.testing.expect(Rows.has(settled, "2 how much have I spent this week"));
    try std.testing.expect(Rows.has(settled, "✓"));
    try std.testing.expect(!Rows.has(first, "✓"));

    var at: usize = 0;
    while (f.line(at).kind != .try_buttons) at += 1;
    const buttons = try Rows.at(&app, &f, &buf, at);
    try std.testing.expect(Rows.has(buttons, "y"));
    try std.testing.expect(Rows.has(buttons, "✓"));
    try std.testing.expect(Rows.has(buttons, "✗"));

    var week: usize = 0;
    while (!(f.line(week).kind == .try_title and f.line(week).old)) week += 1;
    const old = try Rows.at(&app, &f, &buf, week);
    try std.testing.expect(Rows.has(old, try sgr(&want, paintStyle(r.you, r.tile, true))));
    try std.testing.expect(Rows.has(old, "11d"));
    const other = try Rows.at(&app, &f, &buf, week + 1);
    try std.testing.expect(!Rows.has(other, "close untried"));
}

test "Plan's windows keep their slots: another window's rows, a count or a fold move none of them" {
    const eq = std.testing.expectEqual;
    const few =
        \\{"tickets":[],"plan":{"now":[],"next":[{"ticket":9,"repo":"arena","title":"n","why":"","waits_on":[]}],
        \\"goals":[],"landed_today":{"count":0,"newest":[]},"not_planned":{"count":0,"follow_ups":0,"by_repo":{}}}}
    ;
    var many_text: [4096]u8 = undefined;
    var used = (try std.fmt.bufPrint(&many_text, "{{\"tickets\":[],\"plan\":{{\"now\":[", .{})).len;
    for (0..30) |i| {
        used += (try std.fmt.bufPrint(many_text[used..], "{s}{{\"ticket\":{d},\"repo\":\"arena\",\"title\":\"t\",\"state\":\"building\"}}", .{ if (i > 0) "," else "", 100 + i })).len;
    }
    used += (try std.fmt.bufPrint(many_text[used..], "],\"next\":[],\"goals\":[],\"landed_today\":{{\"count\":40,\"newest\":[]}},\"not_planned\":{{\"count\":3,\"follow_ups\":0,\"by_repo\":{{}}}}}}}}", .{})).len;
    var shapes: [3]struct { text: []const u8, fold: bool } = .{
        .{ .text = few, .fold = false },
        .{ .text = many_text[0..used], .fold = false },
        .{ .text = many_text[0..used], .fold = true },
    };
    for (&shapes) |shape| {
        var board = try tickets.Board.parse(std.testing.allocator, shape.text);
        defer board.deinit();
        var app = homeApp(&board);
        app.term_w = 80;
        app.view_w = 80;
        app.view_h = 23;
        app.roles = bench.roles();
        app.board_view = .{ .home = true, .plan = true, .alone = false, .focus = .board };
        if (shape.fold) app.plan_shut.insert(.now);
        var buf: [262144]u8 = undefined;
        var out: Writer = .fixed(&buf);
        try planView(&app, &out, app.board_view.?);
        for (std.enums.values(sheets.Window)) |win| {
            const slot = app.planSlot(win);
            const diamond = try bench.probe(out.buffered(), slot.x + 1, slot.y);
            try eq(@as(u21, '◆'), diamond.cp);
        }
    }
}

test "Plan's rows start with a ▌ in their repo's colour, and a goal's card has it on every row" {
    const eq = std.testing.expectEqual;
    var board = try tickets.Board.parse(std.testing.allocator,
        \\{"tickets":[
        \\{"id":701,"repo":"arena","status":"doing","title":"A"},
        \\{"id":702,"repo":"babylon","status":"doing","title":"B"},
        \\{"id":703,"repo":"menard","status":"todo","title":"C"}],
        \\"plan":{"now":[
        \\{"ticket":701,"repo":"arena","title":"A","state":"building"},
        \\{"ticket":702,"repo":"babylon","title":"B","state":"building"}],
        \\"next":[{"ticket":703,"repo":"menard","title":"C","why":"","waits_on":[]}],
        \\"goals":[{"epic":9,"title":"g","total":2,"landed":0,"steps":[{"ticket":701,"state":"building"},{"ticket":703,"state":"todo"}]}],
        \\"landed_today":{"count":0,"newest":[]},"not_planned":{"count":0,"follow_ups":0,"by_repo":{}}}}
    );
    defer board.deinit();
    var app = homeApp(&board);
    app.term_w = 80;
    app.view_w = 80;
    app.view_h = 23;
    app.roles = bench.roles();
    const r = bench.roles();
    app.board_view = .{ .home = true, .plan = true, .alone = false, .focus = .board };
    var buf: [262144]u8 = undefined;
    var out: Writer = .fixed(&buf);
    try planView(&app, &out, app.board_view.?);
    const drawn = out.buffered();

    const now = app.planSlot(.now);
    for (0..2) |line| {
        const edge = try bench.probe(drawn, now.x + 1, now.y + 1 + @as(u16, @intCast(line)));
        try eq(@as(u21, '▌'), edge.cp);
        try eq(r.repo[line], edge.fg);
    }
    const next = app.planSlot(.next);
    const edge = try bench.probe(drawn, next.x + 1, next.y + 1);
    try eq(@as(u21, '▌'), edge.cp);
    try eq(r.repo[3], edge.fg);

    // the card's rows, its title, bar, next and blocker, wear the colour of the goal's repo
    const goals = app.planSlot(.goals);
    for (2..4) |line| {
        const mark = try bench.probe(drawn, goals.x + 1, goals.y + @as(u16, @intCast(line)));
        try eq(@as(u21, '▌'), mark.cp);
        try eq(r.repo[0], mark.fg);
    }
}

test "the rail's sessions and Claudes wear their repo's ▌ and icon, one repo's colour to a row" {
    const eq = std.testing.expectEqual;
    var board = try tickets.Board.parse(std.testing.allocator,
        \\{"tickets":[
        \\{"id":701,"repo":"arena","status":"doing","title":"A"},
        \\{"id":702,"repo":"babylon","status":"doing","title":"B"}]}
    );
    defer board.deinit();
    var first: Session = .{ .id = 2, .name = @constCast("alpha") };
    var second: Session = .{ .id = 3, .name = @constCast("beta") };
    var a: Window = .{ .id = 1, .name = @constCast("a"), .claude = .working, .since = 1, .info = @constCast("\t\t\t\tt701-x") };
    var b: Window = .{ .id = 2, .name = @constCast("b"), .claude = .working, .since = 1, .info = @constCast("\t\t\t\tt702-y") };
    var wa = [_]*Window{&a};
    var wb = [_]*Window{&b};
    first.wins = .fromOwnedSlice(&wa);
    second.wins = .fromOwnedSlice(&wb);
    var sessions = [_]*Session{ &first, &second };
    var app = homeApp(&board);
    app.board_view = null;
    app.term_w = 80;
    app.view_w = 80;
    app.view_h = 24;
    app.sessions = .fromOwnedSlice(&sessions);
    app.current = 2;
    app.roles = bench.roles();
    const r = bench.roles();
    var buf: [65536]u8 = undefined;
    var out: Writer = .fixed(&buf);
    try rail(&app, &out);
    const drawn = out.buffered();

    for (0..2) |i| {
        const edge = try bench.probe(drawn, 1, 2 + i);
        try eq(@as(u21, '▌'), edge.cp);
        try eq(r.repo[i], edge.fg);
        const icon = try bench.probe(drawn, 2, 2 + i);
        try eq(try std.unicode.utf8Decode(repo_glyphs[i]), icon.cp);
        try eq(r.repo[i], icon.fg);
    }

    var lines: [64]App.AgentLine = undefined;
    const n = app.railAgents(&lines);
    var seen: usize = 0;
    for (lines[0..n], 0..) |line, at| {
        const si = switch (line) {
            .session => |si| si,
            .agent, .detail, .meta, .background => |ag| ag.session,
            .sub => |sub| sub.agent.session,
            else => continue,
        };
        const y = app.railAgentsRow() + 1 + at;
        const edge = try bench.probe(drawn, 1, y);
        try eq(@as(u21, '▌'), edge.cp);
        try eq(r.repo[si], edge.fg);
        seen += 1;
    }
    try std.testing.expect(seen >= 4);
}
