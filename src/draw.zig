const std = @import("std");
const vt = @import("ghostty-vt");
const layout = @import("layout.zig");
const menu = @import("menu.zig");
const color = @import("color.zig");
const theme = @import("theme.zig");
const app_mod = @import("app.zig");
const tickets = @import("board.zig");
const feed = @import("feed.zig");
const App = app_mod.App;
const Session = app_mod.Session;
const Window = app_mod.Window;
const Writer = std.Io.Writer;

pub const What = enum { all, focused_border };

const Pen = struct {
    style: vt.Style = .{},
    dimmed: bool = false,
    fresh: bool = true,
    /// A style every cell is drawn in while set: the selected agent's rows.
    over: ?vt.Style = null,
    /// Every cell drawn while set is underlined: the rail's row under the pointer.
    under: bool = false,

    /// `dim` is the palette to dim against, for an unfocused window's cells. The terminal's own
    /// faint is not used for that: one keeping a minimum contrast repaints faint colours white.
    fn set(pen: *Pen, w: *Writer, drawn: vt.Style, dim: ?*const color.Palette) !void {
        var given = pen.over orelse drawn;
        if (pen.under) given.flags.underline = .single;
        if (!pen.fresh and pen.dimmed == (dim != null) and @as(u128, @bitCast(pen.style)) == @as(u128, @bitCast(given))) return;
        pen.* = .{ .style = given, .dimmed = dim != null, .fresh = false, .over = pen.over, .under = pen.under };
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

    /// The border cell at (`cx`, `y`) of the column: the frame and the title in its top edge.
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
const normal_keys = "i insert  b home  Esc insert  Ctrl+Space insert";

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
    const ox = app.term_w - app.view_w;
    const start = (app.view_w -| normal_keys.len) / 2;
    try w.print("\x1b[{d};{d}H", .{ app.view_h + 1, ox + start + 1 });
    try pen.set(w, ink(app, "dim", 8), null);
    try w.writeAll(normal_keys[0..@min(normal_keys.len, app.view_w)]);
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
    const hovered = app.hovered();
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
                pen.under = hovered == .rail and hovered.rail == y;
                defer pen.under = false;
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
        const todo = app.boardCount(.todo);
        const doing = app.boardCount(.doing);
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
            var auto_buf: [32]u8 = undefined;
            const auto = if (app.auto()) |state| std.fmt.bufPrint(&auto_buf, " auto {d}/{d}", .{ state.working, state.cap }) catch "" else "";
            const orch_state = app.orchestrator();
            const runs_orch = if (orch_state) |state| state.running else false;
            const orch: []const u8 = if (orch_state) |state| (if (state.running or state.on) " orch" else " orch off") else "";
            // both give way to the counts on a rail too narrow: a running orchestrator first,
            // then auto's state, and one that is not running last
            const room = inner -| (8 + 1 + cellCount(counts));
            const down_w = if (!runs_orch and cellCount(orch) <= room) cellCount(orch) else 0;
            const auto_w = if (cellCount(auto) + down_w <= room) cellCount(auto) else 0;
            const orch_w = if (runs_orch and auto_w + cellCount(orch) <= room) cellCount(orch) else down_w;
            const head = 8 + auto_w + orch_w;
            if (auto_w > 0) {
                if (!open) try pen.set(w, autoOn(app), null);
                try w.writeAll(auto);
            }
            if (orch_w > 0) {
                if (!open) try pen.set(w, if (runs_orch) ink(app, "violet", 5) else ink(app, "dim", 8), null);
                try w.writeAll(orch);
            }
            try pen.set(w, if (open) chip(app) else ink(app, "dim", 8), null);
            try fitted(w, "", inner -| head -| cellCount(counts));
            try w.writeAll(counts);
            filled = head + (inner -| head -| cellCount(counts)) + cellCount(counts);
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
        if (!wide) {
            const name = shortName(s.name);
            try pen.set(w, if (here) chip(app) else .{}, null);
            try w.writeAll(" ");
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
            const room = inner - 6 - @intFromBool(review != .none) - @intFromBool(many);
            const cut = cellCount(s.name) > room;
            const name = clip(s.name, room - @intFromBool(cut));
            try pen.set(w, if (here) chip(app) else .{}, null);
            try w.writeAll(" ");
            try w.writeAll(name);
            if (cut) try w.writeAll("…");
            for (0..inner - 5 - @intFromBool(review != .none) - @intFromBool(many) - cellCount(name) - @intFromBool(cut)) |_| try w.writeAll(" ");
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
    for (filled..inner) |_| try w.writeAll(" ");
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
            try pen.set(w, if (s.id == app.current and app.board_view == null) heading(app) else dim, null);
            if (wide) {
                const name = clip(s.name, inner - 2);
                try w.writeAll(" ");
                try w.writeAll(name);
                filled = 1 + cellCount(name);
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
            try pen.set(w, if (win.claude == .none) dim else ink(app, "amber", 4), null);
            try w.writeAll(" ");
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
            try w.writeAll("   ");
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
            try pen.set(w, dim, null);
            try w.writeAll("   ");
            try pen.set(w, ink(app, "amber", 4), null);
            try put(w, if (win.stirring) glyph(app, .working) else '◔');
            // lit as its Claude's title is in view, while that Claude shows it
            try pen.set(w, if (app.subShown(sub)) ink(app, "amber", 4) else dim, null);
            try w.writeAll(" ");
            try fitted(w, win.sub(sub.index), inner - 6);
            filled = inner - 1;
        },
        .background => |a| {
            try pen.set(w, dim, null);
            try w.writeAll("   ");
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
            try pen.set(w, dim, null);
            try w.writeAll("   ");
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
            try pen.set(w, dim, null);
            var buf: [96]u8 = undefined;
            const text = if (wide)
                std.fmt.bufPrint(&buf, " {s} {d} in the pipeline{s}{s}", .{ if (fold.open) "▾" else "◌", fold.count, if (fold.repo.len > 0) " · " else "", fold.repo }) catch ""
            else
                std.fmt.bufPrint(&buf, " ◌{d}", .{fold.count}) catch "";
            const shown = clip(text, inner);
            try w.writeAll(shown);
            filled = cellCount(shown);
        },
        .more => |count| {
            try pen.set(w, dim, null);
            if (wide) try w.print(" +{d} more", .{count}) else try w.print(" +{d}", .{count});
            filled = @min(inner, (if (wide) @as(usize, 7) else 2) + std.fmt.count("{d}", .{count}));
        },
    }
    for (filled..inner) |_| try w.writeAll(" ");
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
        .{ "babylon-work", "bab-w" },
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
            const mark_len = std.unicode.utf8Encode(glyph(app, app.mark(s, win)), &mark) catch 0;
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
        const focused = i == s.focus and (app.board_view == null or app.sideFocused());
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
        var right_cps: [8]u21 = undefined;
        const headed = i == 0 and s.orchestrator() and app.sided();
        const title = if (headed) sideHead(app, &title_buf) else std.fmt.bufPrint(&title_buf, " {d} {s} ", .{ i + 1, win.name }) catch title_buf[0..0];
        var title_len = codepoints(title, &title_cps);
        const mark = if (headed) .none else app.mark(s, win);
        if (mark != .none and title_len + 2 <= title_cps.len) {
            title_cps[title_len] = glyph(app, mark);
            title_cps[title_len + 1] = ' ';
            title_len += 2;
        }
        if (title_len + 4 > col_w) title_len = 0;
        const right = if (headed) right_cps[0..codepoints(fold_hint, &right_cps)] else right_cps[0..0];
        const col: Column = .{
            .app = app,
            .w = col_w,
            .focused = focused,
            .drop = drop == .column and drop.column == i,
            .title = title_cps[0..title_len],
            .mark_at = if (headed and title_len > 0) 1 else if (mark != .none and title_len > 0) title_len - 2 else null,
            .right = if (title_len + right.len + 6 <= col_w) right else right[0..0],
        };

        var pen: Pen = .{};
        const top = app.winTop(s, i);
        var the_feed: feed.Feed = undefined;
        if (top > 1) _ = app.feedOf(&the_feed);
        var y: u16 = 0;
        while (y < app.view_h) : (y += 1) {
            const sy = y + yoff;
            if (sy < 0 or sy >= app.view_h) continue;
            if (y > 0 and y < top and y + 1 < app.view_h) {
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

/// Row `row` of the feed atop the orchestrator's column, `inner` cells wide: its line, or past
/// them, the rule under it.
fn feedRow(app: *const App, w: *Writer, pen: *Pen, f: *const feed.Feed, row: usize, inner: u16) !void {
    const dim = ink(app, "dim", 8);
    if (row >= f.count()) {
        try pen.set(w, dim, null);
        for (0..inner) |_| try w.writeAll("─");
        return;
    }
    const line = f.line(row);
    try pen.set(w, .{}, null);
    try w.writeAll(" ");
    var room: usize = inner -| 1;
    const bar = if (line.failed) ink(app, "emberdim", 1) else ink(app, "amber", 4);
    const lead: []const u8 = switch (line.kind) {
        .item => "▌ ",
        .buttons => "▌     ",
        .chips => "  ",
        else => "",
    };
    if (lead.len > 0 and room > cellCount(lead)) {
        try pen.set(w, bar, null);
        try w.writeAll(lead);
        room -= cellCount(lead);
    }
    var bold = heading(app);
    bold.flags.bold = true;
    try pen.set(w, switch (line.kind) {
        .move_head => bold,
        .head => blk: {
            var style: vt.Style = .{};
            style.flags.bold = true;
            break :blk style;
        },
        .quiet, .more, .landed, .buttons => dim,
        .item, .chips => .{},
    }, null);
    try fitted(w, line.text, room);
}

/// The orchestrator's column with no window of its in it: its head, and while it is off, how to
/// start it.
fn sideEmpty(app: *const App, w: *Writer) !void {
    const ox = app.term_w - app.view_w;
    var title_buf: [96]u8 = undefined;
    var title_cps: [64]u21 = undefined;
    var right_cps: [8]u21 = undefined;
    var title_len = codepoints(sideHead(app, &title_buf), &title_cps);
    if (title_len + 4 > app.view_w) title_len = 0;
    const right = right_cps[0..codepoints(fold_hint, &right_cps)];
    const col: Column = .{
        .app = app,
        .w = app.view_w,
        .focused = app.columnFocused(),
        .title = title_cps[0..title_len],
        .mark_at = if (title_len > 0) 1 else null,
        .right = if (title_len + right.len + 6 <= app.view_w) right else right[0..0],
    };
    var pen: Pen = .{};
    var the_feed: feed.Feed = undefined;
    const top: usize = if (app.feedOf(&the_feed)) the_feed.count() + 2 else 1;
    for (0..app.view_h) |y| {
        try w.print("\x1b[{d};{d}H", .{ y + 1, ox + 1 });
        for (0..app.view_w) |x| {
            if (y == 0 or y + 1 == app.view_h or x == 0 or x + 1 == app.view_w) {
                try col.border(&pen, w, x, @intCast(y));
            } else if (y < top) {
                if (x == 1) try feedRow(app, w, &pen, &the_feed, y - 1, app.view_w - 2);
            } else {
                try pen.set(w, .{}, null);
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
/// share of its context used.
fn sideHead(app: *const App, buf: []u8) []const u8 {
    var out: Writer = .fixed(buf);
    const win = app.orchestratorWindow();
    const state = app.orchestratorState();
    const mark: u21 = switch (state) {
        .working => glyph(app, .working),
        .waiting => '▲',
        .idle, .off => '○',
        .restarting => '◌',
    };
    var when: [16]u8 = undefined;
    out.writeAll(" ") catch {};
    put(&out, mark) catch {};
    out.writeAll(" orchestrator · ") catch {};
    switch (state) {
        .working => out.print("working {s}", .{ago(&when, app.epoch, win.?.since)}) catch {},
        .waiting => out.writeAll("waits on you") catch {},
        .idle => out.writeAll("idle") catch {},
        .restarting => out.writeAll("restarting") catch {},
        .off => out.writeAll("off") catch {},
    }
    if (win) |it| if (it.ctx > 0) out.print(" · ctx {d}%", .{@min(it.ctx, 999)}) catch {};
    out.writeAll(" ") catch {};
    return out.buffered();
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

/// babylon's board in place of the strip: a row naming the repo it is narrowed to and its keys,
/// then a column a status, each a box of its cards, a card a box of its own: the ticket's number
/// and title on two rows, a footer of what else is so of it, its left edge its priority, and
/// the picked one's border lit.
fn boardView(app: *App, w: *Writer, view: app_mod.BoardView) !void {
    const ox = app.boardX();
    const dim = ink(app, "dim", 8);
    const edge: vt.Style = .{ .fg_color = .palette(8) };
    const repo = app.boardRepo();
    var pen: Pen = .{};
    var buf: [160]u8 = undefined;

    try w.print("\x1b[1;{d}H", .{ox + 1});
    try pen.set(w, heading(app), null);
    try w.writeAll(App.board_title);
    try pen.set(w, .{}, null);
    try fitted(w, "", app.boardW() -| cellCount(App.board_title));

    const lanes = app.boardLanes();
    if (lanes) try laneNames(app, w, &pen);
    for (0..app.boardCols()) |c| {
        const name = if (view.backlog) "backlog" else if (app.boardStrip(c)) "recent" else @tagName(tickets.statuses[c]);
        const x = app.boardColX(c);
        const inner = app.boardColW(c) -| 2;
        var cards: [app_mod.max_cards]*const tickets.Card = undefined;
        const n = app.boardColumn(c, &cards);
        const total = if (lanes) app.boardCount(tickets.statuses[c]) else app.boardColumnAll(c);
        const label = std.fmt.bufPrint(&buf, " {s} {d} ", .{ name, total }) catch "";
        try pen.set(w, edge, null);
        try w.print("\x1b[2;{d}H╭─", .{x + 1});
        try pen.set(w, dim, null);
        const shown = clip(label, inner -| 1);
        try w.writeAll(shown);
        try pen.set(w, edge, null);
        for (@min(cellCount(shown) + 1, inner)..inner) |_| try w.writeAll("─");
        try w.writeAll("╮");
        const first = app.boardFirst(c);
        var y: u16 = 2;
        if (lanes) {
            try laneColumn(app, w, &pen, view, c, x, inner);
            y = app.view_h;
        }
        while (y + 1 < app.view_h) : (y += 1) {
            try w.print("\x1b[{d};{d}H", .{ y + 1, x + 1 });
            try pen.set(w, edge, null);
            try w.writeAll("│");
            const slot = App.cardRowAt(y).?;
            const at = first + slot.k;
            if (at >= @min(n, cards.len) or slot.k >= app.boardShown() or inner < 4) {
                const more = at == n and slot.part == .top and slot.k < app.boardShown() and total > n;
                try pen.set(w, dim, null);
                try fitted(w, if (more) std.fmt.bufPrint(&buf, " {d} more", .{total - n}) catch "" else "", inner);
            } else try cardLine(app, w, &pen, cards[at], slot.part, c == view.col and at == view.row, hovers(app, 0, c, at), repo == null, inner);
            try pen.set(w, edge, null);
            try w.writeAll("│");
        }
        try w.print("\x1b[{d};{d}H╰", .{ app.view_h, x + 1 });
        for (0..inner) |_| try w.writeAll("─");
        try w.writeAll("╯");
    }
    try boardButtons(app, w, view);
    if (view.answering) if (app.boardCard(view.col, view.row)) |card| if (card.ask) |ask| try askBox(app, w, card.id, ask);
    if (view.giving) |picked| if (app.boardCard(view.col, view.row)) |card| try giveBox(app, w, card.id, picked);
    if (view.detail) |id| try detailBox(app, w, id, view.detail_scroll);
    if (view.help) try helpBox(app, w);
}

/// A ticket's whole detail over the board, as babylon gave it, its lines cut to the box's width
/// and run on under one another, scrolled `scroll` rows down.
fn detailBox(app: *const App, w: *Writer, id: u32, scroll: usize) !void {
    const width = app_mod.detailWidth(app.boardW());
    const bw = width.box;
    const inner = width.inner;
    const x = app.boardX() + (app.boardW() -| bw) / 2;
    const top: u16 = 3;
    const bottom: u16 = app.view_h -| 1;
    var buf: [24]u8 = undefined;
    const title = std.fmt.bufPrint(&buf, " #{d} ", .{id}) catch " detail ";
    if (bottom < top + 3 or inner == 0 or bw < cellCount(title) + 3) return;
    const edge = ink(app, "amber", 4);
    var pen: Pen = .{};

    try pen.set(w, edge, null);
    try w.print("\x1b[{d};{d}H╭─", .{ top, x + 1 });
    try pen.set(w, heading(app), null);
    try w.writeAll(title);
    try pen.set(w, edge, null);
    for (cellCount(title) + 1..bw - 2) |_| try w.writeAll("─");
    try w.writeAll("╮");

    const dim = ink(app, "dim", 8);
    const note = doneNote(app, id);
    var note_rows: u16 = 0;
    var counted = app_mod.DetailLines.init(note, inner);
    if (note.len > 0) while (counted.next()) |_| {
        if (note_rows < bottom - top - 3) note_rows += 1;
    };
    const text_end = bottom - 1 - note_rows;

    const text = if (app.detail.items.len > 0) app.detail.items else "…";
    var y = top + 1;
    var row: usize = 0;
    var lines = app_mod.DetailLines.init(text, inner);
    while (lines.next()) |line| : (row += 1) {
        if (row < scroll or y >= text_end) continue;
        try boxLine(w, &pen, edge, .{}, x, y, line, inner);
        y += 1;
    }
    while (y < text_end) : (y += 1) try boxLine(w, &pen, edge, .{}, x, y, "", inner);
    var noted = app_mod.DetailLines.init(note, inner);
    while (y < bottom - 1) : (y += 1) try boxLine(w, &pen, edge, dim, x, y, noted.next() orelse "", inner);
    try boxLine(w, &pen, edge, dim, x, y, "jk scroll · esc puts it away", inner);
    try pen.set(w, edge, null);
    try w.print("\x1b[{d};{d}H╰", .{ bottom, x + 1 });
    for (0..bw - 2) |_| try w.writeAll("─");
    try w.writeAll("╯");
}

/// Why babylon left done ticket `id`'s Claude running, empty when it says nothing of it.
fn doneNote(app: *const App, id: u32) []const u8 {
    const b = if (app.board) |*b| b else return "";
    for (b.cards()) |*card| if (card.id == id) return if (card.status == .done) card.session_note else "";
    return "";
}

/// The board's buttons over what is drawn under them: the repo tabs, the one shown lit, and the
/// gate; the + on the to-do column; the picked card's actions as chips; and, at the first row's
/// end, where its keys are.
fn boardButtons(app: *App, w: *Writer, view: app_mod.BoardView) !void {
    var pen: Pen = .{};
    var buf: [64]u8 = undefined;
    var buttons: [48]App.Button = undefined;
    const shown = app.boardButtons(&buttons);
    const hovered = app.hovered();
    var end: u16 = 0;
    var right = app.boardX() + app.boardW();
    for (shown, 0..) |button, index| {
        var style: vt.Style = switch (button.what) {
            .repo => |i| if (i == view.repo and !view.backlog) chip(app) else if (app.tabCount(i) > 0) .{} else ink(app, "dim", 8),
            .backlog => if (view.backlog) chip(app) else if (app.board.?.backlog().len > 0) .{} else ink(app, "dim", 8),
            .gate => ink(app, "violet", 5),
            .orch => if (app.orchestrator().?.running) ink(app, "violet", 5) else ink(app, "dim", 8),
            .auto => if (app.auto() != null) autoOn(app) else ink(app, "dim", 8),
            .proposed => if (app.board.?.proposedCount() > 0) heading(app) else ink(app, "dim", 8),
            .new => heading(app),
            .card => blk: {
                var lit = if (app.columnFocused()) ink(app, "dim", 8) else ink(app, "amber", 4);
                lit.flags.inverse = true;
                break :blk lit;
            },
        };
        if (hovered == .button and hovered.button == index) style.flags.underline = .single;
        try pen.set(w, style, null);
        try w.print("\x1b[{d};{d}H{s}", .{ button.y + 1, button.x + 1, app.buttonLabel(button, &buf) });
        if (button.y != 0) continue;
        switch (button.what) {
            .repo, .backlog => end = button.x + button.w,
            else => right = @min(right, button.x),
        }
    }
    var heads: [48]App.Button = undefined;
    if (app.header(&heads).more) |at| {
        try pen.set(w, ink(app, "dim", 8), null);
        try w.print("\x1b[1;{d}H…", .{at + 1});
        end = at + 1;
    }
    const hint = for ([_][]const u8{ "? keys · esc close", "? keys" }) |text| {
        if (end + 2 + cellCount(text) + 1 <= right) break text;
    } else "";
    if (hint.len > 0) {
        try pen.set(w, ink(app, "dim", 8), null);
        try w.print("\x1b[1;{d}H{s}", .{ right - 1 - cellCount(hint), hint });
    }
    try pen.set(w, .{}, null);
}

const board_keys = [_][2][]const u8{
    .{ "hjkl, arrows", "pick a card" },
    .{ "⏎, click it", "go to the Claude holding it, or start one on a free todo card" },
    .{ "space", "its whole ticket: body, links, gate log" },
    .{ "a G x P", "answer, give to a Claude, no to a proposal (⏎ is go), oldest proposed" },
    .{ "e", "edit its title, repo and body" },
    .{ "p", "raise its priority, high back to low" },
    .{ "> <", "close a ticket to do, reopen a done one" },
    .{ "J K", "move it down or up among its repo's cards" },
    .{ "n, +", "file a ticket" },
    .{ "r, a tab", "the next repo, the backlog, or the one clicked" },
    .{ "t", "move a backlog card to todo" },
    .{ "g", "babylon's gate, while it runs one" },
    .{ "o", "the orchestrator, started if it is not running" },
    .{ "A", "babylon's auto mode, on or off" },
    .{ "`", "fold the orchestrator's window beside it, or unfold" },
    .{ "alt+l", "to that window, and alt+h back to the board" },
    .{ "esc, q", "close the board" },
    .{ "left edge", "its priority: lit for high, dim for low" },
    .{ "◐ » ✗ ◆ ?", "working, queued, sent back, landed, asks" },
};

/// The board's keys, boxed over its middle until the next key.
fn helpBox(app: *App, w: *Writer) !void {
    const bw: u16 = @min(app.boardW() -| 4, 60);
    const inner = bw -| 4;
    const x = app.boardX() + (app.boardW() -| bw) / 2;
    const edge = ink(app, "amber", 4);
    var pen: Pen = .{};
    var y: u16 = @min(3, app.view_h -| (board_keys.len + 3));
    if (y == 0 or bw < 32) return;
    try pen.set(w, edge, null);
    try w.print("\x1b[{d};{d}H╭─", .{ y, x + 1 });
    try pen.set(w, heading(app), null);
    try w.writeAll(" the board's keys ");
    try pen.set(w, edge, null);
    for (cellCount(" the board's keys ") + 1..bw - 2) |_| try w.writeAll("─");
    try w.writeAll("╮");
    for (board_keys) |pair| {
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

/// The every view's lane names down the board's left, a rule between lanes as between their cards.
fn laneNames(app: *const App, w: *Writer, pen: *Pen) !void {
    const ox = app.boardX();
    const lw = app.laneLabelW();
    const view = app.board_view.?;
    const scroll = app.laneScroll();
    var y: u16 = 1;
    while (y < app.view_h) : (y += 1) {
        try w.print("\x1b[{d};{d}H", .{ y + 1, ox + 1 });
        const at = if (y >= 2 and y + 1 < app.view_h) app.laneLineAt(y - 2 + scroll) else null;
        const line = at orelse {
            try pen.set(w, .{}, null);
            try fitted(w, "", lw);
            continue;
        };
        if (line.rule) {
            try pen.set(w, .{ .fg_color = .palette(8) }, null);
            for (0..lw) |_| try w.writeAll("─");
            continue;
        }
        const repo = app.laneRepo(line.lane).?;
        try pen.set(w, if (line.lane == view.lane) heading(app) else .{}, null);
        try w.writeAll(" ");
        try fitted(w, if (line.row != 0) "" else if (repo.len == 0) "no repo" else repo, lw -| 1);
    }
}

/// Column `c` of the every view: each lane's cards in it boxed, a rule between lanes. The strip's
/// are a dim row each, ✓ and its number and title, the picked one lit.
fn laneColumn(app: *const App, w: *Writer, pen: *Pen, view: app_mod.BoardView, c: usize, x: u16, inner: u16) !void {
    const edge: vt.Style = .{ .fg_color = .palette(8) };
    const scroll = app.laneScroll();
    var y: u16 = 2;
    while (y + 1 < app.view_h) : (y += 1) {
        try w.print("\x1b[{d};{d}H", .{ y + 1, x + 1 });
        try pen.set(w, edge, null);
        const at = app.laneLineAt(y - 2 + scroll);
        if (at) |line| if (line.rule) {
            try w.writeAll("├");
            for (0..inner) |_| try w.writeAll("─");
            try w.writeAll("┤");
            continue;
        };
        try w.writeAll("│");
        const each = app.cardRows(c);
        const k = if (at) |line| line.row / each else 0;
        const card = if (at) |line| app.laneCard(line.lane, c, k) else null;
        if (card) |it| {
            const line = at.?;
            const picked = line.lane == view.lane and c == view.col and k == view.row;
            const hovered = hovers(app, line.lane, c, k);
            if (each == 1) {
                var buf: [160]u8 = undefined;
                var style = if (picked and !app.columnFocused()) heading(app) else if (picked) vt.Style{} else ink(app, "dim", 8);
                try pen.set(w, style, null);
                try w.writeAll(" ");
                if (hovered) style.flags.underline = .single;
                try pen.set(w, style, null);
                try fitted(w, std.fmt.bufPrint(&buf, "✓ #{d} {s}", .{ it.id, it.title }) catch it.title, inner -| 1);
            } else try cardLine(app, w, pen, it, @fromBackingInt(@intCast(line.row % each)), picked, hovered, false, inner);
        } else {
            var buf: [24]u8 = undefined;
            const counts = if (at) |line| app.laneCounts(line.lane, c) else null;
            const more = if (counts) |n| at.?.row == n.shown * each and n.total > n.shown else false;
            try pen.set(w, ink(app, "dim", 8), null);
            try fitted(w, if (more) std.fmt.bufPrint(&buf, " {d} more", .{counts.?.total - counts.?.shown}) catch "" else "", inner);
        }
        try pen.set(w, edge, null);
        try w.writeAll("│");
    }
}

/// Whether the pointer is on the card at `lane`, `col` and `row`.
fn hovers(app: *const App, lane: usize, col: usize, row: usize) bool {
    const at = app.hovered();
    return at == .card and std.meta.eql(at.card, .{ .lane = lane, .col = col, .row = row });
}

/// Row `part` of a card boxed in `inner` cells: its edges, the picked one's lit (dim while the
/// orchestrator's column has the keys) and its left one a high or low priority's colour, its
/// number and title on two rows, underlined under the pointer, and its footer and top edge.
fn cardLine(app: *const App, w: *Writer, pen: *Pen, card: *const tickets.Card, part: App.CardRow, picked: bool, hovered: bool, with_repo: bool, inner: u16) !void {
    if (inner < 4) return fitted(w, "", inner);
    var buf: [160]u8 = undefined;
    const dim = ink(app, "dim", 8);
    const border: vt.Style = if (picked and app.columnFocused()) dim else if (picked) heading(app) else .{};
    const left: vt.Style = if (picked) border else if (std.mem.eql(u8, card.priority, "high")) ink(app, "amber", 4) else if (std.mem.eql(u8, card.priority, "low")) dim else border;
    const ends: [2][]const u8 = switch (part) {
        .top => .{ "╭", "╮" },
        .bottom => .{ "╰", "╯" },
        else => .{ "│", "│" },
    };
    try pen.set(w, left, null);
    try w.writeAll(ends[0]);
    switch (part) {
        .top => try cardText(app, w, pen, card, with_repo, .{ .edge = border }, inner - 2),
        .bottom => {
            try pen.set(w, border, null);
            for (0..inner - 2) |_| try w.writeAll("─");
        },
        .title, .title_more => {
            const title = std.fmt.bufPrint(&buf, "#{d} {s}", .{ card.id, card.title }) catch card.title;
            const lines = app_mod.titleLines(title, inner - 3);
            var style: vt.Style = if (card.blocked_by.len > 0) dim else .{};
            try pen.set(w, style, null);
            try w.writeAll(" ");
            if (hovered) style.flags.underline = .single;
            try pen.set(w, style, null);
            try fitted(w, lines[@intFromBool(part == .title_more)], inner - 3);
        },
        .footer => try cardText(app, w, pen, card, with_repo, .footer, inner - 2),
    }
    try pen.set(w, border, null);
    try w.writeAll(ends[1]);
}

/// Where the pipeline has a card: its glyph, none when it has none, the word for it, and the
/// colour of both. A queued one with a question open is held: babylon moves it once it is answered.
fn stageOf(app: *const App, card: *const tickets.Card) ?struct { style: vt.Style, glyph: u21, word: []const u8 } {
    const s = card.stage orelse return null;
    const eql = std.mem.eql;
    if (eql(u8, s, "failed")) return .{ .style = ink(app, "emberdim", 1), .glyph = '✗', .word = "sent back" };
    if (eql(u8, s, "landed")) return .{ .style = ink(app, "amber", 4), .glyph = '◆', .word = "landed" };
    if (eql(u8, s, "queued")) return .{ .style = ink(app, "violet", 5), .glyph = if (card.ask == null) '»' else 0, .word = if (card.ask == null) "queued" else "held" };
    if (eql(u8, s, "verifying") or eql(u8, s, "reviewing")) return .{ .style = ink(app, "amber", 4), .glyph = glyph(app, .working), .word = s };
    return .{ .style = ink(app, "dim", 8), .glyph = 0, .word = s };
}

/// What has a card's footer to itself: the Claude holding it or, in review, where the pipeline
/// has it. Nothing has a card nobody holds.
fn cardWho(card: *const tickets.Card) enum { none, holder, stage } {
    if (card.status == .review) return if (card.stage != null) .stage else .none;
    return if (card.holder() != null) .holder else .none;
}

/// A card's footer or its top edge in `width` cells. The footer is who has the card, alone; the
/// rest of what is so of it is then on the top edge, the edge's line run on after it: a question
/// waiting on the human, where the pipeline has it as a glyph in its colour, and its detail. A
/// card nobody has keeps all of that in its footer, and its edge is bare.
fn cardText(app: *const App, w: *Writer, pen: *Pen, card: *const tickets.Card, with_repo: bool, on: union(enum) { edge: vt.Style, footer }, width: usize) !void {
    var buf: [160]u8 = undefined;
    var held: [96]u8 = undefined;
    var spun: [32]u8 = undefined;
    var proposed: [160]u8 = undefined;
    const dim = ink(app, "dim", 8);
    const who = cardWho(card);
    const rest = (who == .none) == (on == .footer);
    const stage: struct { vt.Style, []const u8 } = if (stageOf(app, card)) |s|
        .{ s.style, if (s.glyph == 0) s.word else std.fmt.bufPrint(&spun, "{u} {s}", .{ s.glyph, s.word }) catch s.word }
    else
        .{ dim, "" };
    const proposal = if (rest) (if (card.proposal) |p| std.fmt.bufPrint(&proposed, "▲ proposed: {s}", .{p.why}) catch "▲ proposed" else "") else "";
    const parts = [_]struct { vt.Style, []const u8 }{
        .{ heading(app), proposal },
        .{ ink(app, "amber", 4), if (rest and card.ask != null) "? asks" else "" },
        if (if (who == .stage) on == .footer else rest) stage else .{ dim, "" },
        .{ dim, if (who == .holder and on == .footer) cardHolder(app, card, &held) else "" },
        .{ dim, if (rest) cardDetail(card, with_repo, &buf) else "" },
    };
    const fill: struct { vt.Style, []const u8 } = switch (on) {
        .edge => |border| .{ border, "─" },
        .footer => .{ .{}, " " },
    };
    const bare = for (parts) |part| {
        if (part[1].len > 0) break false;
    } else true;
    if (bare and on == .edge) {
        try pen.set(w, fill[0], null);
        for (0..width) |_| try w.writeAll(fill[1]);
        return;
    }
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
    try pen.set(w, fill[0], null);
    for (0..left) |_| try w.writeAll(fill[1]);
}

/// The window of the Claude holding a card, with that Claude's mark and how long it has held it.
fn cardHolder(app: *const App, card: *const tickets.Card, buf: []u8) []const u8 {
    var out: Writer = .fixed(buf);
    const pane = card.holder() orelse return "";
    if (app.paneWindow(pane)) |at| {
        const win = at.session.wins.items[at.index];
        if (win.claude != .none) out.print("{u} ", .{glyph(app, win.claude)}) catch {};
        out.writeAll(win.name) catch {};
    } else out.writeAll(card.heldBy().?) catch {};
    var age: [8]u8 = undefined;
    if (card.claimedAt()) |at| out.print(" · {s}", .{ago(&age, app.epoch, @intCast(@max(1, at)))}) catch {};
    return out.buffered();
}

/// What else is so of a card, joined: its repo when the board shows every one, the tickets it
/// waits on, that it is an epic, a priority not the usual one, why a done one's Claude was left running.
fn cardDetail(card: *const tickets.Card, with_repo: bool, buf: []u8) []const u8 {
    var out: Writer = .fixed(buf);
    var sep: []const u8 = "";
    if (with_repo) {
        out.print("{s}{s}", .{ sep, card.repo orelse "no repo" }) catch {};
        sep = " · ";
    }
    if (card.blocked_by.len > 0) {
        out.print("{s}waits", .{sep}) catch {};
        for (card.blocked_by) |id| out.print(" #{d}", .{id}) catch {};
        sep = " · ";
    }
    if (std.mem.eql(u8, card.kind, "epic")) {
        out.print("{s}epic", .{sep}) catch {};
        sep = " · ";
    }
    if (!std.mem.eql(u8, card.priority, "med")) {
        out.print("{s}{s}", .{ sep, card.priority }) catch {};
        sep = " · ";
    }

    if (card.status == .done and card.session_note.len > 0) out.print("{s}{s}", .{ sep, card.session_note }) catch {};
    return out.buffered();
}

/// One frame: the rail, the current session's strip (and, mid-slide, the one being left) or the
/// overview in its place, the menu or prompt when open, and the cursor.
pub fn frame(app: *App, w: *Writer, what: What) !void {
    try w.writeAll("\x1b[?2026h\x1b[?25l\x1b[0m");
    if (what == .all) {
        // Not 2J: erasing the whole display takes the terminal's kitty pictures with it.
        try w.writeAll("\x1b[H\x1b[J");
        try rail(app, w);
    } else if (app.working()) try rail(app, w);
    var cursor: ?Cursor = null;
    if (app.overview) |spot| {
        try overview(app, w, spot);
    } else if (app.board_view) |view| {
        try boardView(app, w, view);
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
    if (app.prompt) |*prompt| {
        cursor = try promptBox(app, w, prompt);
    } else if (app.menu) |open| {
        try menuBox(app, w, open);
        cursor = null;
    }
    try w.writeAll("\x1b[0m");
    if (cursor) |at| try w.print("\x1b[{d};{d}H\x1b[?25h", .{ at.y + 1, at.x + 1 });
    if (app.shape_due) try w.print("\x1b]22;{s}\x1b\\", .{app.shape});
    app.shape_due = false;
    try w.writeAll(app.out.items);
    app.out.clearRetainingCapacity();
    try w.writeAll("\x1b[?2026l");
}

test "a queued card with a question open is held, and one without is queued" {
    var app: App = .{ .gpa = std.testing.allocator, .io = undefined, .tmux_in = undefined };
    var buf: [512]u8 = undefined;
    var card: tickets.Card = .{ .id = 1, .title = "Handed in", .status = .review, .stage = "queued" };

    var waiting: Writer = .fixed(&buf);
    var pen: Pen = .{};
    try cardText(&app, &waiting, &pen, &card, false, .footer, 15);
    try std.testing.expect(std.mem.indexOf(u8, waiting.buffered(), "» queued") != null);

    card.ask = .{ .id = 5, .question = "Which colour?" };
    var held: Writer = .fixed(&buf);
    pen = .{};
    try cardText(&app, &held, &pen, &card, false, .footer, 15);
    const drawn = held.buffered();
    try std.testing.expect(std.mem.indexOf(u8, drawn, "held") != null);
    try std.testing.expect(std.mem.indexOf(u8, drawn, "queued") == null);
    try std.testing.expect(std.mem.indexOf(u8, drawn, "…") == null);
    try std.testing.expect(std.mem.indexOf(u8, drawn, "? asks") == null);

    var edge: Writer = .fixed(&buf);
    pen = .{};
    try cardText(&app, &edge, &pen, &card, false, .{ .edge = .{} }, 15);
    try std.testing.expect(std.mem.indexOf(u8, edge.buffered(), "? asks") != null);
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
    for ([_][]const u8{ "left edge", "its priority: lit for high, dim for low", "◐ » ✗ ◆ ?", "working, queued, sent back, landed, asks" }) |text| {
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
