const std = @import("std");
const vt = @import("ghostty-vt");
const layout = @import("layout.zig");
const menu = @import("menu.zig");
const color = @import("color.zig");
const theme = @import("theme.zig");
const bench = @import("parts.zig");
const grab_mod = @import("grab.zig");
const app_mod = @import("app.zig");
const tickets = @import("board.zig");
const feed = @import("feed.zig");
const sheets = @import("plan.zig");
const goal_mod = @import("goal.zig");
const win_plan = @import("win_plan.zig");
const win_landed = @import("win_landed.zig");
const win_driving = @import("win_driving.zig");
const win_now = @import("win_now.zig");
const win_move = @import("win_move.zig");
const win_modal = @import("win_modal.zig");
const win_feed = @import("win_feed.zig");
const win_next = @import("win_next.zig");
const win_goals = @import("win_goals.zig");
const win_unplanned = @import("win_unplanned.zig");
const App = app_mod.App;
const Session = app_mod.Session;
const Window = app_mod.Window;
const Pane = app_mod.Pane;
const Writer = std.Io.Writer;

pub const What = enum { all, focused_border };

pub const Pen = struct {
    style: vt.Style = .{},
    dimmed: bool = false,
    fresh: bool = true,
    /// A style every cell is drawn in while set: the selected agent's rows.
    over: ?vt.Style = null,

    /// `dim` is the palette to dim against, for an unfocused window's cells. The terminal's own
    /// faint is not used for that: one keeping a minimum contrast repaints faint colours white.
    pub fn set(pen: *Pen, w: *Writer, drawn: vt.Style, dim: ?*const color.Palette) !void {
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
pub fn ink(app: *const App, comptime name: []const u8, fallback: u8) vt.Style {
    return if (app.theme) |t| rgbStyle(@field(t, name)) else .{ .fg_color = .palette(fallback) };
}

/// Bold ink on amber: the focused title, the current session, the selected menu item.
pub fn chip(app: *const App) vt.Style {
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

/// Under the strip, the foot row: `◆ home ▲ N`, the session with a dot per window (the filled one
/// is the window in view, any other with something to say shows its mark), `s go to` and `≡`,
/// the mode at its right end. Every part keeps its cells.
fn dots(app: *const App, w: *Writer, s: *const Session) !void {
    const ox = app.term_w - app.view_w;
    var pen: Pen = .{};
    try w.print("\x1b[{d};{d}H", .{ app.view_h + 1, ox + 1 });
    try pen.set(w, .{}, null);
    for (0..app.view_w) |_| try w.writeAll(" ");
    try modeCorner(app, w, &pen);
    if (app.normal) return normalKeys(app, w, &pen);
    if (app.over_dots) if (try tabs(app, w, &pen, s)) return;
    const f = layout.foot(app.view_w, s.wins.items.len) orelse return;
    const dim = ink(app, "dim", 8);
    if (app.board != null) {
        try footAt(app, w, layout.Foot.home);
        try pen.set(w, ink(app, "amber", 4), null);
        try w.writeAll("◆ home");
        if (app.needsCount() > 0) {
            try footAt(app, w, layout.Foot.needs);
            try pen.set(w, heading(app), null);
            try w.print("▲ {d}", .{@min(app.needsCount(), 99)});
        }
    }
    try pen.set(w, dim, null);
    try footAt(app, w, f.session - (if (f.wide) @as(usize, 3) else 2));
    try w.writeAll("│");
    try footAt(app, w, f.session);
    const repo = app.sessionRepo(app.sessionIndex(s.id) orelse 0);
    if (repoEdge(app, repo)) |edge| {
        try pen.set(w, edge, null);
        try w.writeAll("▌");
        try w.writeAll(repoIcon(app, repo) orelse "  ");
    }
    try footAt(app, w, f.session + 4);
    try pen.set(w, .{}, null);
    try fitted(w, s.name, f.name_w);
    for (s.wins.items, 0..) |win, i| {
        const here = i == s.focus;
        const mark = app.mark(s, win);
        try footAt(app, w, f.dots + f.step * i);
        try pen.set(w, if (here or mark != .none) ink(app, "amber", 4) else dim, null);
        try put(w, if (here) '●' else if (mark != .none) glyph(app, mark) else if (win.alert != .none) alertGlyph(win.alert) else '○');
        if (f.wide) {
            try pen.set(w, dim, null);
            try w.print(" {d}", .{i + 1});
        }
    }
    try pen.set(w, dim, null);
    try footAt(app, w, f.go - (if (f.wide) @as(usize, 3) else 2));
    try w.writeAll("│");
    try footAt(app, w, f.go);
    try w.writeAll("s go to");
    try footAt(app, w, f.menu);
    try w.writeAll("≡");
    if (f.wide and f.end + layout.Foot.mode_w + 1 <= app.view_w) {
        try footAt(app, w, app.view_w - layout.Foot.mode_w - 1);
        try w.writeAll("INSERT ^space");
    }
}

/// Moves the cursor to cell `x` of the foot row.
fn footAt(app: *const App, w: *Writer, x: usize) !void {
    try w.print("\x1b[{d};{d}H", .{ app.view_h + 1, app.term_w - app.view_w + x + 1 });
}

const normal_label = "NORMAL";
const normal_keys = "j k session  ] [ next waiting  ⏎ go  s go to  b home  i insert";

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
    if (app.overview == null and app.drawerOpen()) return keysLine(app, w, &pen, if (app.columnFocused() and !app.normal) "INSERT" else drawer_hint);
    if (app.normal) try keysLine(app, w, &pen, type_hint);
}

const drawer_hint = "NORMAL · o close · i type";

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

/// How long ago `since` was, in its largest whole unit: 45s, 4m, 2h, 3d.
pub fn ago(buf: []u8, epoch: i64, since: u32) []const u8 {
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

/// `repo`'s colour in Workbench's look, for the `▌` that starts its rows; none for a repo it has
/// no colour for, or without a palette.
fn repoEdge(app: *const App, repo: []const u8) ?vt.Style {
    const r = app.roles orelse return null;
    for (theme.Roles.repo_names, 0..) |name, i| if (std.mem.eql(u8, name, repo)) return rgbStyle(r.repo[i]);
    return null;
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
pub fn agentGlyph(app: *const App, win: *const Window) u21 {
    return if (win.claude == .none) '○' else glyph(app, win.claude);
}

/// `text` in exactly `width` cells: cut with an ellipsis, or padded.
pub fn fitted(w: *Writer, text: []const u8, width: usize) !void {
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

pub fn cellCount(text: []const u8) usize {
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
pub fn clip(text: []const u8, max: usize) []const u8 {
    var it = std.unicode.Utf8View.initUnchecked(text).iterator();
    var n: usize = 0;
    while (n < max) : (n += 1) _ = it.nextCodepointSlice() orelse break;
    return text[0..it.i];
}

/// `text` in `max` cells: whole when it fits, else cut at a word boundary within six cells of the
/// end when there is one, and ended with `…`. `buf` holds the result.
pub fn clipMark(buf: []u8, text: []const u8, max: usize) []const u8 {
    if (cellCount(text) <= max) return text;
    if (max == 0) return "";
    var head = clip(text, max - 1);
    const tail = lastCells(head, 6);
    if (std.mem.lastIndexOfScalar(u8, tail, ' ')) |sp| {
        const at = head.len - tail.len + sp;
        if (at > 0) head = head[0..at];
    }
    head = std.mem.trimEnd(u8, head, " ");
    return std.fmt.bufPrint(buf, "{s}…", .{head}) catch head;
}

/// `clipMark` of `text` said at (`x`, `y`) in `max` cells.
pub fn sayCut(w: *Writer, x: usize, y: usize, text: []const u8, max: usize, fg: color.RGB, bg: color.RGB, bold: bool) !void {
    var buf: [256]u8 = undefined;
    try bench.say(w, x, y, clipMark(&buf, text, max), fg, bg, bold);
}

/// A goal's bar from `x` across `room` cells: the bar, then `N/M  P%` ending at the room's right
/// edge, then `tail` (what to try) after it when there is one. One shape in every window.
pub fn goalBar(w: *Writer, r: theme.Roles, x: usize, y: usize, room: usize, goal: tickets.Goal, hue: color.RGB, face: color.RGB, count_ink: color.RGB, tail: []const u8, tail_ink: color.RGB) !void {
    var buf: [32]u8 = undefined;
    const pct: u32 = if (goal.total == 0) 0 else goal.landed * 100 / goal.total;
    const label = std.fmt.bufPrint(&buf, "{d}/{d}  {d}%", .{ goal.landed, goal.total, pct }) catch "";
    const bar_w = room -| 1 -| cellCount(label) -| (if (tail.len > 0) cellCount(tail) + 2 else 0);
    try bench.bar(w, r, x, y, bar_w, goal.landed, goal.total, hue);
    try bench.say(w, x + 1 + bar_w, y, label, count_ink, face, false);
    if (tail.len > 0) try bench.say(w, x + 1 + bar_w + cellCount(label) + 2, y, tail, tail_ink, face, false);
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
    width: u16 = menu.width,

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
        for (0..b.width - 2) |_| try b.w.writeAll("─");
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
        for (0..(b.width - 4) -| (cellCount(left) + cellCount(right))) |_| try b.w.writeAll(" ");
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

pub fn heading(app: *const App) vt.Style {
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
    var b: Box = .{ .app = app, .w = w, .x = at.x, .y = at.y, .width = if (prompt.what == .jump) app.switcherW() else menu.width };
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
            .jump => "  → Go to",
            .search => "  / Search history",
            .report => "  ! What's wrong?",
            .words, .why, .find, .tried => "",
        },
        dim,
        std.fmt.bufPrint(&buf, "{s}  ", .{clip(was, 12)}) catch "",
    );
    try b.blank();
    const shown = lastCells(prompt.text(), b.width - 10);
    try b.line(.{}, std.fmt.bufPrint(&buf, "  › {s}", .{shown}) catch "", .{}, "");
    try b.blank();
    if (prompt.what == .jump) {
        var rows: [App.max_rows]App.Row = undefined;
        const n = app.switcherRows(prompt.text(), &rows);
        for (0..menu.jump_rows) |i| {
            const at_row = prompt.top() + i;
            if (at_row >= n) {
                try b.blank();
                continue;
            }
            try switcherRow(&b, rows[at_row], at_row == prompt.selected);
        }
        try b.blank();
        const asking = prompt.len == 0 and !prompt.filtering;
        try b.line(dim, if (asking) "  j k move  ⏎ go  space card  J K order  x close  / find  esc" else "  ↑↓ move   ⏎ go   esc close", dim, "");
    } else if (prompt.what == .search) {
        try b.line(dim, if (prompt.missed) "  no match" else "  ⏎ older match   esc close", dim, "");
    } else if (prompt.what == .report) {
        try b.line(dim, "  ⏎ file it   esc cancel", dim, "");
    } else try b.line(dim, "  ⏎ rename   esc cancel", dim, "");
    try b.edge("╰", "╯");
    return .{ .x = at.x + 6 + @as(i32, @intCast(cellCount(shown))), .y = at.y + 4 };
}

/// One row of the switcher: a Claude's mark, repo and ticket with its place and age at the right,
/// a session with its windows, the row that makes one, or a window or ticket the query found.
fn switcherRow(b: *Box, row: App.Row, picked: bool) !void {
    const app = b.app;
    var label_buf: [200]u8 = undefined;
    var right_buf: [48]u8 = undefined;
    var age: [8]u8 = undefined;
    var mark: u21 = ' ';
    var repo: ?[]const u8 = null;
    var label: []const u8 = "";
    var right: []const u8 = "";
    switch (row) {
        .claude => |a| {
            mark = agentGlyph(app, a.win);
            repo = app.sessionRepo(a.session);
            label = app.claudeLabel(&label_buf, a);
            right = std.fmt.bufPrint(&right_buf, "{s}:{d} {s:>4}", .{ clip(app.sessions.items[a.session].name, 12), a.win.index, ago(&age, app.epoch, a.win.since) }) catch "";
        },
        .session => |si| {
            const s = app.sessions.items[si];
            repo = app.sessionRepo(si);
            label = s.name;
            right = std.fmt.bufPrint(&right_buf, "{d} window{s}", .{ s.wins.items.len, if (s.wins.items.len == 1) "" else "s" }) catch "";
        },
        .new => label = "+ new session",
        .hit => |hit| switch (hit) {
            .window => |found| {
                const win = found.session.wins.items[found.index];
                mark = glyph(app, app.mark(found.session, win));
                label = std.fmt.bufPrint(&label_buf, "{s} › {s}", .{ found.session.name, win.name }) catch "";
            },
            .ticket => |card| label = std.fmt.bufPrint(&label_buf, "#{d} › {s}", .{ card.id, card.title }) catch "",
        },
    }
    if (!try b.begin()) return;
    const base: vt.Style = if (picked) chip(app) else .{};
    const inner: usize = b.width - 4;
    try b.w.writeAll("│");
    try b.pen.set(b.w, .{}, null);
    try b.w.writeAll(" ");
    try b.pen.set(b.w, base, null);
    if (mark != ' ') try b.pen.set(b.w, if (picked) base else ink(app, "amber", 4), null);
    try put(b.w, mark);
    try b.pen.set(b.w, base, null);
    try b.w.writeAll(" ");
    var lead: usize = 2;
    if (repo) |name| {
        lead += 4;
        if (repoEdge(app, name)) |edge| {
            var e = edge;
            e.bg_color = base.bg_color;
            try b.pen.set(b.w, e, null);
            try b.w.writeAll("▌");
            try b.w.writeAll(repoIcon(app, name) orelse "  ");
            try b.pen.set(b.w, base, null);
            try b.w.writeAll(" ");
        } else try b.w.writeAll("    ");
    }
    const tail = clip(right, inner -| lead -| 2);
    const room = inner -| lead -| cellCount(tail) -| 1;
    try fitted(b.w, label, room);
    try b.w.writeAll(" ");
    try b.pen.set(b.w, if (picked) base else ink(app, "dim", 8), null);
    try b.w.writeAll(tail);
    for (lead + room + 1 + cellCount(tail)..inner) |_| try b.w.writeAll(" ");
    try b.pen.set(b.w, .{}, null);
    try b.w.writeAll(" ");
    try b.pen.set(b.w, ink(app, "amber", 4), null);
    try b.w.writeAll("│");
}

/// The line a ticket's why is typed into, at the board's foot. Returns where its cursor goes.
fn wordsLine(app: *const App, w: *Writer, prompt: *const menu.Prompt) !Cursor {
    const x: u16 = 0;
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
    var slots: [33]App.RepoTab = undefined;
    const x: usize = app.planRepoTabs(&slots).end + 2;
    const hint = if (typing) "  ⏎ keep  esc clear" else "  esc clear";
    if (app.roles) |r| return benchFind(app, w, r, x, text, hint, typing);
    const room = @as(usize, app.boardW()) -| cellCount(App.plan_title) -| 3;
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
    const right = planHeadStart(app);
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
        const focused = i == s.focus and (app.home == null or app.sideFocused()) and app.popup == null;
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
        const title = if (headed) sideHead(app, &title_buf, col_w) else std.fmt.bufPrint(&title_buf, " {d} {s} ", .{ i + 1, win.name }) catch title_buf[0..0];
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
                } else try win_feed.feedRow(app, w, &pen, &the_feed, y - 1, col_w - 2);
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
const close_hint = " o close ";

fn sideHint(app: *const App) []const u8 {
    return if (app.drawerOpen()) close_hint else fold_hint;
}

/// The feed's pick while the plan has the keys: dim ink, inverted.
pub fn dimLit(app: *const App) vt.Style {
    var style = ink(app, "dim", 8);
    style.flags.inverse = true;
    return style;
}

/// A style on Workbench's panel when it sets no background of its own.
pub fn onPanel(app: *const App, style: vt.Style) vt.Style {
    const r = app.roles orelse return style;
    var s = style;
    switch (s.bg_color.value()) {
        .none => s.bg_color = .rgb(.{ .r = r.panel.r, .g = r.panel.g, .b = r.panel.b }),
        else => {},
    }
    return s;
}

pub fn paintStyle(fg: color.RGB, bg: color.RGB, bold: bool) vt.Style {
    var s: vt.Style = .{ .fg_color = .rgb(.{ .r = fg.r, .g = fg.g, .b = fg.b }), .bg_color = .rgb(.{ .r = bg.r, .g = bg.g, .b = bg.b }) };
    s.flags.bold = bold;
    return s;
}

/// The orchestrator's column with no window of its in it: its head, and while it is off, how to
/// start it.
fn sideEmpty(app: *const App, w: *Writer) !void {
    const ox = app.term_w - app.view_w;
    var title_buf: [96]u8 = undefined;
    var title_cps: [64]u21 = undefined;
    var right_cps: [24]u21 = undefined;
    var title_len = codepoints(sideHead(app, &title_buf, app.view_w), &title_cps);
    if (title_len + 4 > app.view_w) title_len = 0;
    const right = right_cps[0..codepoints(sideHint(app), &right_cps)];
    const col: Column = .{
        .app = app,
        .w = app.view_w,
        .focused = app.columnFocused(),
        .title = title_cps[0..title_len],
        .mark_at = if (title_len > 0) 1 else null,
        .right = if (title_len + right.len + 6 <= app.view_w) right else right[0..0],
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
                if (x == 1) try win_feed.feedRow(app, w, &pen, &the_feed, y - 1, app.view_w - 2);
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
/// share of its context used.
fn sideHead(app: *const App, buf: []u8, col_w: usize) []const u8 {
    var out: Writer = .fixed(buf);
    const room = col_w -| 4;
    var full = true;
    while (true) {
        out.end = 0;
        sideHeadInto(app, &out, full);
        if (!full or cellCount(out.buffered()) <= room) return out.buffered();
        full = false;
    }
}

fn sideHeadInto(app: *const App, out: *Writer, full: bool) void {
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
        out.writeAll(" ") catch {};
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
    out.writeAll(" ") catch {};
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

const popup_keys = " j k scroll  / find  a ask  r reply  ⏎ go  q ";
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

    const win: ?*const Window, const session: ?*const Session = if (app.agentById(pop.entry)) |a|
        .{ a.win, app.sessions.items[a.session] }
    else
        .{ null, null };
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
            text = std.fmt.bufPrint(&buf, " #{d} {s}  {s}", .{ id, item.repo orelse "", item.title }) catch "";
        };
        for (given.next) |item| if (item.ticket == id) {
            text = std.fmt.bufPrint(&buf, " #{d} {s}  {s}{s}{s}", .{ id, item.repo orelse "", item.title, if (item.why.len > 0) " — " else "", item.why }) catch "";
        };
        if (text.len == 0) for (given.goals) |goal| if (goal.epic == id) {
            text = std.fmt.bufPrint(&buf, " #{d}  {s}", .{ id, goal.title }) catch "";
        };
    };
    var pen: Pen = .{};
    try w.print("\x1b[{d};{d}H", .{ app.view_h, 1 });
    try pen.set(w, ink(app, "dim", 8), null);
    try fitted(w, text, app.boardW());
}

const PlanHeadBufs = struct { auto: [48]u8, auto_pad: [64]u8, today: [32]u8, needs: [16]u8, orch: [40]u8 };

const auto_ask = "◐ turn off?";

/// Auto's switch as asking "turn off?" or as `plain`, both padded to the same width so the
/// pieces after it stay under the pointer between the two clicks.
fn autoPiece(buf: []u8, plain: []const u8, armed: bool) []const u8 {
    const text = if (armed) auto_ask else plain;
    const width = @max(cellCount(plain), cellCount(auto_ask));
    const pad = width - cellCount(text);
    if (text.len + pad > buf.len) return text;
    @memcpy(buf[0..text.len], text);
    @memset(buf[text.len..][0..pad], ' ');
    return buf[0 .. text.len + pad];
}

test "auto's piece keeps one width asking and not" {
    var a: [64]u8 = undefined;
    var b: [64]u8 = undefined;
    for ([_][]const u8{ "◐ auto", "◐ auto 2/4", "◐ auto 4/4 · tools 1/1" }) |plain| {
        try std.testing.expectEqual(cellCount(autoPiece(&a, plain, false)), cellCount(autoPiece(&b, plain, true)));
    }
    try std.testing.expect(std.mem.startsWith(u8, autoPiece(&a, "◐ auto", true), auto_ask));
}

/// Plan's head against its right edge: auto's switch, today's landings and what
/// needs the human, three cells apart, from cell `start` of the board's width, the head's own
/// words taking `left_w`; with less room it keeps auto and what needs the human, then auto alone.
/// Auto says its tools slots when babylon gives them and the room is there.
const PlanHead = struct {
    pieces: [5]struct { text: []const u8, style: vt.Style },
    keep: u5,
    start: usize,
    left_w: usize,

    fn shows(head: PlanHead, i: usize) bool {
        return head.keep >> @intCast(i) & 1 == 1;
    }
};

fn planHead(app: *const App, bufs: *PlanHeadBufs) PlanHead {
    const b = &app.board.?;
    const given = b.plan().?;
    const needs_n = b.needsYou().len;
    const dim = ink(app, "dim", 8);
    const left_w = cellCount(App.plan_title) + if (app.oneColumn()) cellCount(App.orch_link) + 2 else 0;
    var head: PlanHead = .{ .pieces = undefined, .keep = 0b11111, .start = 0, .left_w = left_w };
    const tries = [_]struct { tools: bool, keep: u5 }{
        .{ .tools = true, .keep = if (app.oneColumn()) 0b10101 else 0b11111 },
        .{ .tools = false, .keep = if (app.oneColumn()) 0b10101 else 0b11111 },
        .{ .tools = false, .keep = 0b10101 },
        .{ .tools = false, .keep = 0b10001 },
    };
    for (tries) |try_| {
        const tools = try_.tools;
        head.keep = try_.keep;
        const plain: []const u8 = if (app.auto()) |state| (if (tools and state.tools != null)
            std.fmt.bufPrint(&bufs.auto, "◐ auto {d}/{d} · tools {d}/{d}", .{ state.working, state.cap, state.tools.?.working, state.tools.?.cap })
        else
            std.fmt.bufPrint(&bufs.auto, "◐ auto {d}/{d}", .{ state.working, state.cap })) catch "◐" else "◐ auto";
        const armed = app.auto() != null and app.now < app.auto_armed_until;
        const auto = autoPiece(&bufs.auto_pad, plain, armed);
        head.pieces = .{
            .{ .text = auto, .style = if (app.auto() != null) autoOn(app) else dim },
            .{ .text = std.fmt.bufPrint(&bufs.today, "✓ {d} today", .{given.landed_today.count}) catch "", .style = dim },
            .{ .text = std.fmt.bufPrint(&bufs.needs, "▲ {d}", .{needs_n}) catch "", .style = if (needs_n > 0) heading(app) else dim },
            .{ .text = orchPiece(app, &bufs.orch), .style = dim },
            .{ .text = "≡", .style = dim },
        };
        var right_w: usize = 0;
        for (head.pieces, 0..) |piece, i| {
            if (head.shows(i)) right_w += cellCount(piece.text) + 3;
        }
        head.start = app.boardW() -| right_w;
        if (head.start > left_w) break;
    }
    return head;
}

/// The orchestrator's state in Plan's head, a click on it opening the drawer.
fn orchPiece(app: *const App, buf: []u8) []const u8 {
    const win = app.orchestratorWindow();
    var when: [16]u8 = undefined;
    return (switch (app.orchestratorState()) {
        .working => std.fmt.bufPrint(buf, "◆ orch working {s}", .{ago(&when, app.epoch, win.?.since)}),
        .waiting => std.fmt.bufPrint(buf, "◆ orch waits on you", .{}),
        .stalled => std.fmt.bufPrint(buf, "◆ orch stalled", .{}),
        .idle => std.fmt.bufPrint(buf, "◆ orch idle", .{}),
        .restarting => std.fmt.bufPrint(buf, "◆ orch restarting", .{}),
        .off => std.fmt.bufPrint(buf, "◆ orch off", .{}),
    }) catch "◆ orch";
}

/// What Plan's head holds at column `x`: its orchestrator state or its `≡`.
pub fn planHeadHit(app: *const App, x: u16) ?enum { orch, menu } {
    var bufs: PlanHeadBufs = undefined;
    const head = planHead(app, &bufs);
    if (head.start <= head.left_w) return null;
    var at: usize = head.start;
    for (head.pieces, 0..) |piece, i| {
        if (!head.shows(i)) continue;
        const end = at + cellCount(piece.text);
        if (x >= at and x < end) return switch (i) {
            3 => .orch,
            4 => .menu,
            else => null,
        };
        at = end + 3;
    }
    return null;
}

/// The first cell of Plan's right group in the head, from the board's left edge: what lies
/// left of it is the repo filter's and the find line's.
pub fn planHeadStart(app: *const App) usize {
    var bufs: PlanHeadBufs = undefined;
    return planHead(app, &bufs).start;
}

/// Where Plan's auto switch is on the top row: its first cell and its width; none where the head
/// has no room for it.
pub fn planAutoSwitch(app: *const App) ?struct { x: u16, w: u16 } {
    var bufs: PlanHeadBufs = undefined;
    const head = planHead(app, &bufs);
    if (head.start <= head.left_w) return null;
    return .{ .x = @as(u16, @intCast(head.start)), .w = @intCast(cellCount(head.pieces[0].text)) };
}

/// The repo filter in the plan's head: `every` and each repo, the one the plan is narrowed to lit.
fn repoTabs(app: *App, w: *Writer, view: app_mod.HomeView) !void {
    var slots: [33]App.RepoTab = undefined;
    const found = app.planRepoTabs(&slots);
    var repos: [32][]const u8 = undefined;
    _ = app.board.?.repos(&repos);
    var pen: Pen = .{};
    for (slots[0..found.n], 0..) |tab, i| {
        try w.print("\x1b[1;{d}H", .{tab.x + 1});
        try pen.set(w, if (view.plan_repo == tab.repo) heading(app) else ink(app, "dim", 8), null);
        try w.writeAll(if (tab.repo == 0) "every" else repos[tab.repo - 1]);
        if (i + 1 < found.n) {
            try pen.set(w, ink(app, "dim", 8), null);
            try w.writeAll(" · ");
        }
    }
    try pen.set(w, .{}, null);
}

/// Home's plan in the board's place: its head, a rule, then its rows from the one the pick keeps
/// in view, the pick a bar at the left edge. What lies over the board lies over it.
/// Home with no plan: why there is none, and the way back.
fn planWhy(app: *App, w: *Writer) !void {
    var pen: Pen = .{};
    var buf: [128]u8 = undefined;
    try w.print("\x1b[2;3H", .{});
    try pen.set(w, heading(app), null);
    try fitted(w, app.boardWhy(&buf), app.view_w -| 4);
    try w.print("\x1b[4;3H", .{});
    try pen.set(w, ink(app, "dim", 8), null);
    try fitted(w, "q to go back", app.view_w -| 4);
    try pen.set(w, .{}, null);
}

fn planView(app: *App, w: *Writer, view: app_mod.HomeView) !void {
    var sheet: sheets.Sheet = undefined;
    if (!app.planSheet(&sheet)) return planWhy(app, w);
    const ox: u16 = 0;
    const width = app.boardW();
    const dim = ink(app, "dim", 8);
    var pen: Pen = .{};

    if (app.columnTakesPlan() and columnOpen(app, view)) {
        const room = app.columnRoom();
        for (0..app.view_h) |y| {
            try w.print("\x1b[{d};1H", .{y + 1});
            try pen.set(w, .{}, null);
            try fitted(w, "", room);
        }
        return planBoxes(app, w, view);
    }

    // the head: the title and the way to the board, then babylon's state against the right edge
    try w.print("\x1b[1;{d}H", .{ox + 1});
    try pen.set(w, .{}, null);
    try w.writeAll(" ");
    try pen.set(w, heading(app), null);
    try w.writeAll(App.plan_title[1..]);
    if (app.oneColumn()) {
        try pen.set(w, .{}, null);
        try w.writeAll("  ");
        try pen.set(w, dim, null);
        try w.writeAll(App.orch_link);
    }
    var head_bufs: PlanHeadBufs = undefined;
    const head = planHead(app, &head_bufs);
    try pen.set(w, .{}, null);
    if (head.start > head.left_w) {
        for (head.left_w..head.start) |_| try w.writeAll(" ");
        for (head.pieces, 0..) |piece, i| {
            if (!head.shows(i)) continue;
            try pen.set(w, piece.style, null);
            try w.writeAll(piece.text);
            try pen.set(w, .{}, null);
            try w.writeAll("   ");
        }
    } else for (head.left_w..width) |_| try w.writeAll(" ");
    if (app.workbench()) {
        try repoTabs(app, w, view);
        _ = try findLine(app, w);
    }

    try w.print("\x1b[2;{d}H", .{ox + 1});
    try pen.set(w, dim, null);
    for (0..width) |_| try w.writeAll("─");

    const top = app.planTop(&sheet);
    var y: u16 = 2;
    const rows_end = app.view_h - @intFromBool(app.oneColumn());
    if (app.oneColumn()) try planFoot(app, w, &sheet, view.plan_pick);
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
    try planBoxes(app, w, view);
}

/// Whether a box is open that is drawn in the middle column.
fn columnOpen(app: *const App, view: app_mod.HomeView) bool {
    const words = if (app.prompt) |prompt| prompt.multiline() else false;
    return words or view.detail != null or view.giving != null or view.goal_open or
        app.autoRect() != null or app.draftRect() != null;
}

/// The boxes opened from Plan, over it or, where it has no room beside them, in its place.
fn planBoxes(app: *App, w: *Writer, view: app_mod.HomeView) !void {
    if (view.giving) |picked| if (app.pickedCard()) |card| {
        app.grab.cover();
        try win_modal.giveBox(app, w, card.id, picked);
    };
    if (view.detail) |id| try win_modal.detailBox(app, w, id, view.detail_scroll);
    if (app.autoRect() != null) app.grab.cover();
    try win_modal.autoBox(app, w);
    if (view.goal_open) {
        app.grab.cover();
        try goalBox(app, w);
    }
    if (app.draftRect() != null) app.grab.cover();
    try win_modal.draftBox(app, w);
    if (view.help) {
        app.grab.cover();
        try helpBox(app, w);
    }
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

pub fn repeat(w: *Writer, x: usize, y: usize, cell_glyph: []const u8, n: usize, fg: color.RGB, bg: color.RGB) !void {
    var buf: [1024]u8 = undefined;
    var out: Writer = .fixed(&buf);
    for (0..n) |_| out.writeAll(cell_glyph) catch break;
    try bench.say(w, x, y, out.buffered(), fg, bg, false);
}

/// The plan's rows in Workbench's look, from `rows_end` up: seven windows, each in the slot
/// the screen's size gives it, a goal a card with its bar. A window shown whole is a modal over
/// them, and what is behind it is drawn as it was.
fn benchPlan(app: *App, w: *Writer, r: theme.Roles, sheet: *const sheets.Sheet, view: app_mod.HomeView, rows_end: u16) !void {
    var y: u16 = 2;
    while (y < rows_end) : (y += 1) try bench.fill(w, 0, y, app.boardW(), r.ground);
    if (view.whole == null) {
        for (std.enums.values(sheets.Window)) |win| try win_plan.benchWindow(app, w, r, sheet, view, win, true);
        return;
    }
    var behind: sheets.Sheet = undefined;
    var repos: [app_mod.max_repos][]const u8 = undefined;
    const b = &app.board.?;
    behind.build(b.plan().?, b, app.boardW() -| 1, app.epoch, view.unfolded, app.oneColumn(), true, app.planSee(&repos));
    app.narrowPlan(&behind);
    for (std.enums.values(sheets.Window)) |win| try win_plan.benchWindow(app, w, r, &behind, view, win, false);
    try win_plan.benchWindow(app, w, r, sheet, view, view.whole.?, true);
}

pub fn stepHue(r: theme.Roles, state: []const u8) struct { word: []const u8, lead: color.RGB, filled: bool } {
    const eql = std.mem.eql;
    if (eql(u8, state, "building")) return .{ .word = "building", .lead = r.building, .filled = false };
    if (eql(u8, state, "landing")) return .{ .word = "landing", .lead = r.checking, .filled = false };
    if (eql(u8, state, "reviewing") or eql(u8, state, "verifying")) return .{ .word = state, .lead = r.checking, .filled = false };
    if (eql(u8, state, "failed") or eql(u8, state, "sent_back")) return .{ .word = "sent back", .lead = r.failed, .filled = true };
    if (eql(u8, state, "next")) return .{ .word = "next", .lead = r.dim, .filled = false };
    if (eql(u8, state, "to_try")) return .{ .word = "▲ to try", .lead = r.you, .filled = true };
    return .{ .word = "todo", .lead = r.dim, .filled = false };
}

pub fn goalHue(b: *const tickets.Board, r: theme.Roles, goal: tickets.Goal) color.RGB {
    for (b.cards()) |card| if (card.id == goal.epic) return repoHue(r, card.repo).hue;
    for (goal.steps) |step| for (b.cards()) |card| if (card.id == step.ticket) return repoHue(r, card.repo).hue;
    return r.dim;
}

/// A step as a chip at (`x`, `y`): its number and where it is.
pub fn stepChip(w: *Writer, r: theme.Roles, x: usize, y: usize, step: tickets.Step) !usize {
    const look = stepHue(r, step.state);
    var buf: [48]u8 = undefined;
    const label = std.fmt.bufPrint(&buf, "#{d} {s}", .{ step.ticket, look.word }) catch "";
    return bench.chipInk(w, r, x, y, label, look.lead, if (look.filled) r.on_accent else r.text, look.filled);
}

/// A goal whose steps are in more than one repo: a chip for each, right-aligned to `right`, with
/// its landed and total steps there. The cells they take, with a gap; none for a goal of one
/// repo, whose edge says it.
pub fn goalChips(w: *Writer, r: theme.Roles, b: *const tickets.Board, goal: tickets.Goal, right: usize, y: u16) !usize {
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

pub fn repoHue(r: theme.Roles, repo: ?[]const u8) struct { glyph: []const u8, hue: color.RGB } {
    for (theme.Roles.repo_names, 0..) |name, i| if (std.mem.eql(u8, name, repo orelse "")) return .{ .glyph = repo_glyphs[i], .hue = r.repo[i] };
    return .{ .glyph = "\u{f10c}", .hue = r.dim };
}

/// What a card says of where it is, as a chip: a question open, sent back, proposed, where the
/// pipeline has it, what it waits on, who holds it.
pub fn benchState(app: *const App, card: *const tickets.Card, r: theme.Roles, buf: []u8) ?struct { label: []const u8, lead: color.RGB, words: color.RGB, filled: bool } {
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
    if (card.clash) |words| return .{ .label = std.fmt.bufPrint(buf, "◷ {s}", .{words}) catch "◷ clash", .lead = r.dim, .words = r.dim, .filled = false };
    if (card.blocked_by.len > 0) return .{ .label = std.fmt.bufPrint(buf, "\u{f0c1} waits #{d}", .{card.blocked_by[0]}) catch "waits", .lead = r.dim, .words = r.dim, .filled = false };
    if (card.status == .doing) return if (card.holder() != null)
        .{ .label = "\u{f013} building", .lead = r.building, .words = r.text, .filled = false }
    else
        .{ .label = "\u{f10c} no Claude", .lead = r.failed, .words = r.text, .filled = false };
    return null;
}

const plan_keys = [_][2][]const u8{
    .{ "j k, arrows", "pick a row: now, next, goals, ideas, landed, not planned" },
    .{ "⏎, click it", "go: its Claude, the gate, start it, plan an idea, unfold a row, the board on it" },
    .{ "space", "open the row in place; on an open row, its whole ticket" },
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

/// The plan's keys, boxed over its middle until the next key.
fn helpBox(app: *App, w: *Writer) !void {
    return keysBox(app, w, &plan_keys, " the plan's keys ", 0, app.boardW());
}

const strip_keys = [_][2][]const u8{
    .{ "j k", "the session below or above; ⏎ is insert, space opens the Claude" },
    .{ "] [", "the next or previous Claude that waits or is done" },
    .{ "h l  1…9", "the window left or right; that window" },
    .{ "H L  J K", "move the window; move the session" },
    .{ "; '", "the window narrower, wider" },
    .{ "c  x  z", "a new window; close it; the whole width" },
    .{ "/", "jump: windows, Claudes and tickets" },
    .{ "b n g", "the board; the inbox; the gate's modal" },
    .{ "O m", "the overview; the menu" },
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

pub fn boxLine(w: *Writer, pen: *Pen, edge: vt.Style, style: vt.Style, x: u16, y: u16, text: []const u8, inner: u16) !void {
    try pen.set(w, edge, null);
    try w.print("\x1b[{d};{d}H│ ", .{ y, x + 1 });
    try pen.set(w, style, null);
    try fitted(w, text, inner);
    try pen.set(w, edge, null);
    try w.writeAll(" │");
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

/// A model id as a card says it: `claude-opus-5-5` is `opus`.
pub fn modelName(model: []const u8) []const u8 {
    const rest = if (std.mem.startsWith(u8, model, "claude-")) model["claude-".len..] else return model;
    return rest[0 .. std.mem.indexOfScalar(u8, rest, '-') orelse rest.len];
}

fn reportInk(app: *const App) vt.Style {
    return if (app.report_failed) ink(app, "emberdim", 1) else ink(app, "amber", 4);
}

/// babylon's answer to the report key, where the key was pressed: directly under the picked feed
/// line while the feed has the keys; else the last row of the view.
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
    try w.print("\x1b[{d};{d}H{s}", .{ app.view_h, ox + 1, clip(text, app.view_w) });
}

/// The cells the mouse has picked, drawn inverted over what the frame drew.
fn grabOverlay(app: *App, w: *Writer) !void {
    if (!try app.grab.settle(app.gpa)) return;
    const sel = app.grab.sel.?;
    var i: usize = 0;
    while (app.grab.spans(sel, i)) |picked| : (i += 1) {
        try w.print("\x1b[{d};{d}H\x1b[0;7m{s}\x1b[0m", .{ picked.y + 1, picked.x + 1, picked.text });
    }
}

/// One frame: the current session's strip (and, mid-slide, the one being left) or the
/// overview in its place, the menu or prompt when open, and the cursor.
pub fn frame(app: *App, w: *Writer, what: What) !void {
    app.settleLit();
    app.grab.begin();
    try w.writeAll("\x1b[?2026h\x1b[?25l\x1b[0m");
    if (what == .all) {
        // Not 2J: erasing the whole display takes the terminal's kitty pictures with it.
        try w.writeAll("\x1b[H\x1b[J");
    }
    var cursor: ?Cursor = null;
    if (app.overview) |spot| {
        try overview(app, w, spot);
        try modeRow(app, w);
    } else if (app.home) |view| {
        if (!app.columnAlone()) try planView(app, w, view);
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
    try grabOverlay(app, w);
    if (app.report_said) |text| try reportSaid(app, w, text);
    if (app.start_refused) |text| if (app.planShown()) try reportSaid(app, w, text);
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

fn homeApp(board: *tickets.Board) App {
    var app: App = .{ .gpa = std.testing.allocator, .io = undefined, .tmux_in = undefined };
    app.term_w = 120;
    app.view_w = 60;
    app.view_h = 24;
    app.board = board.*;
    app.home = .{ .focus = .orchestrator };
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
    defer app.grab.deinit(std.testing.allocator);
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
    defer app.grab.deinit(std.testing.allocator);
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

test "the report's answer is drawn under the picked feed line" {
    var board = try tickets.Board.parse(std.testing.allocator,
        \\{"tickets":[],"needs_you":[
        \\{"id":"ask:3","kind":"ask","ticket":16,"repo":"arena","text":"#16 arena  asks: Blue?",
        \\ "actions":[{"key":"1","label":"Blue","argv":["babylon","answer","3","1"]}]}]}
    );
    defer board.deinit();
    var app = homeApp(&board);
    defer app.grab.deinit(std.testing.allocator);
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
        feed.build(&f, &b, &.{}, width, 80, 1795262400);
        for (0..f.itemCount() + 1) |pick| {
            app.home = .{ .focus = .orchestrator, .pick = pick };
            for (0..f.count() + 1) |row| {
                for (2..140) |inner| {
                    var out: Writer = .fixed(&buf);
                    var pen: Pen = .{};
                    try win_feed.feedRow(&app, &out, &pen, &f, row, @intCast(inner));
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
    app.home = .{ .draft = 830, .draft_pick = 1 };
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
    app.home = .{ .focus = .orchestrator };
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

/// Row `y` of `frame_bytes` on a terminal `cols` wide, from cell `from` on.
fn rowFrom(frame_bytes: []const u8, cols: u16, y: usize, from: usize, buf: []u8) ![]const u8 {
    const row = try screenRow(frame_bytes, cols, y, buf);
    var it = std.unicode.Utf8View.initUnchecked(row).iterator();
    for (0..from) |_| _ = it.nextCodepointSlice() orelse return "";
    return row[it.i..];
}

/// Fails when any cell from `from` on differs between two frames of `rows` rows.
fn expectSameFrom(a: []const u8, b: []const u8, cols: u16, rows: usize, from: usize) !void {
    for (0..rows) |y| {
        var buf_a: [1024]u8 = undefined;
        var buf_b: [1024]u8 = undefined;
        try std.testing.expectEqualStrings(try rowFrom(a, cols, y, from, &buf_a), try rowFrom(b, cols, y, from, &buf_b));
    }
}

test "a check's words prompt leaves the orchestrator's cells as they were, and the gate box stays left of them" {
    const gpa = std.testing.allocator;
    var prompt: menu.Prompt = .{ .what = .words };
    const item = "try:825#3";
    @memcpy(prompt.target[0..item.len], item);
    prompt.target_len = item.len;
    for ("it never answers") |byte| _ = prompt.press(&.{byte});
    var shut: std.Io.Writer.Allocating = .init(gpa);
    defer shut.deinit();
    var app = try wordsFrame(gpa, feed.try_sample, prompt, &shut);
    defer app.board.?.deinit();
    app.view_h = 28;
    app.prompt = null;
    shut.clearRetainingCapacity();
    try frame(&app, &shut.writer, .all);
    var open: std.Io.Writer.Allocating = .init(gpa);
    defer open.deinit();
    app.prompt = prompt;
    try frame(&app, &open.writer, .all);
    try std.testing.expect(std.mem.indexOf(u8, open.written(), "✗ What went wrong?") != null);
    const left = app.term_w - app.view_w;
    try expectSameFrom(shut.written(), open.written(), app.term_w, app.view_h, left);
    try std.testing.expect(app.wordsRect().x + app.wordsRect().w <= left);

    app.prompt = null;
    app.home.?.detail = 825;
    app.home.?.gate = true;
    var gate: std.Io.Writer.Allocating = .init(gpa);
    defer gate.deinit();
    try frame(&app, &gate.writer, .all);
    try expectSameFrom(shut.written(), gate.written(), app.term_w, app.view_h, left);
    const rect = app.modalRect().?;
    try std.testing.expect(rect.x + rect.w <= left);
}

test "too narrow for Plan, the orchestrator and a column, the words prompt takes Plan's place and leaves the orchestrator's cells" {
    const gpa = std.testing.allocator;
    var board = try tickets.Board.parse(gpa, grid_board);
    defer board.deinit();
    var app = homeApp(&board);
    defer app.grab.deinit(gpa);
    app.term_w = 112;
    app.view_w = 60;
    app.view_h = 28;
    app.home = .{ .focus = .plan };
    app.side_folded = false;
    try std.testing.expect(app.sided() and app.columnTakesPlan());
    var shut: std.Io.Writer.Allocating = .init(gpa);
    defer shut.deinit();
    try frame(&app, &shut.writer, .all);
    var first: [1024]u8 = undefined;
    var plan_rows: usize = 0;
    for (0..app.view_h) |y| plan_rows += @intFromBool(std.mem.indexOf(u8, try screenRow(shut.written(), app.term_w, y, &first), "goals") != null);
    try std.testing.expect(plan_rows > 0);

    var prompt: menu.Prompt = .{ .what = .words };
    const item = "try:825#3";
    @memcpy(prompt.target[0..item.len], item);
    prompt.target_len = item.len;
    app.prompt = prompt;
    var open: std.Io.Writer.Allocating = .init(gpa);
    defer open.deinit();
    try frame(&app, &open.writer, .all);
    try std.testing.expect(std.mem.indexOf(u8, open.written(), " esc cancel ") != null);
    const left = app.term_w - app.view_w;
    try expectSameFrom(shut.written(), open.written(), app.term_w, app.view_h, left);
    for (0..app.view_h) |y| {
        var buf: [1024]u8 = undefined;
        const row = try screenRow(open.written(), app.term_w, y, &buf);
        try std.testing.expect(std.mem.indexOf(u8, row, "goals") == null);
    }
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
    app.home = .{};
    app.side_folded = true;
    return app;
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
    defer app.grab.deinit(std.testing.allocator);
    app.term_w = 120;
    app.view_w = 80;
    app.view_h = 31;
    app.roles = bench.roles();
    app.home = .{ .alone = false, .focus = .plan };
    app.side_folded = true;
    const r = bench.roles();

    var sheet: sheets.Sheet = undefined;
    try std.testing.expect(app.planSheet(&sheet));
    // the goal with a step building, not the first listed
    try std.testing.expectEqual(@as(usize, 1), sheet.rows[sheet.span(.driving).start].item);

    var buf: [65536]u8 = undefined;
    var out: Writer = .fixed(&buf);
    try planView(&app, &out, app.home.?);
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
    defer app.grab.deinit(std.testing.allocator);
    app.term_w = 120;
    app.view_w = 80;
    app.view_h = 31;
    app.roles = bench.roles();
    app.home = .{ .alone = false, .focus = .plan };
    app.side_folded = true;
    const r = bench.roles();

    var sheet: sheets.Sheet = undefined;
    try std.testing.expect(app.planSheet(&sheet));
    var buf: [65536]u8 = undefined;
    var out: Writer = .fixed(&buf);
    try planView(&app, &out, app.home.?);
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
    defer app.grab.deinit(std.testing.allocator);
    app.term_w = 80;
    app.view_w = 80;
    app.view_h = 23;
    app.roles = bench.roles();
    app.home = .{ .alone = false, .focus = .plan };
    app.side_folded = true;
    try std.testing.expect(app.planShown());
    app.report_said = try std.testing.allocator.dupe(u8, "babylon: repo arena is held");
    defer std.testing.allocator.free(app.report_said.?);
    var buf: [65536]u8 = undefined;
    var out: Writer = .fixed(&buf);
    try frame(&app, &out, .all);
    try std.testing.expect(std.mem.indexOf(u8, out.buffered(), "babylon: repo arena is held") != null);
}

test "a card's popup in Workbench's look: a window with its ✕, the title whole, the ask's options as buttons and the facts as chips" {
    var app: App = .{ .gpa = std.testing.allocator, .io = undefined, .tmux_in = undefined };
    defer app.grab.deinit(std.testing.allocator);
    app.term_w = 80;
    app.view_w = 80;
    app.view_h = 24;
    app.roles = bench.roles();
    const r = app.roles.?;
    app.board = try tickets.Board.parse(std.testing.allocator,
        \\{"tickets":[
        \\{"id":4,"repo":"tlon","title":"Which direction should the board take","status":"doing","priority":"high","model":"claude-opus-5-5","claimed_by":"%12","claimed_at":"2026-11-24T00:00:00Z",
        \\ "ask":{"id":9,"question":"Which one?","options":["Phosphor","Workbench"]}}
        \\],"plan":{"now":[],"next":[],"goals":[],"landed_today":{"count":0,"newest":[]},"not_planned":{"count":0,"follow_ups":0,"by_repo":{}}}}
    );
    defer app.board.?.deinit();
    app.home = .{ .detail = 4 };
    var buf: [65536]u8 = undefined;
    var out: Writer = .fixed(&buf);
    try planView(&app, &out, app.home.?);
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
    defer app.grab.deinit(std.testing.allocator);
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
    const peek = app.peekOf(look) orelse return;
    var age_buf: [8]u8 = undefined;
    if (peek.card) |card| {
        if (card.holder()) |pane| if (app.workspace(pane)) |at| p.add(.head, "%{d} · {s}:{d}", .{ pane, at.session, at.window });
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
        if (card.clash) |said| p.add(.dim, "◷ {s}", .{said});
        for (card.overlaps) |overlap| {
            const first: []const u8 = if (overlap.files.len > 0) overlap.files[0] else "";
            if (overlap.worse()) p.add(.plain, "⚠ overlaps #{d}: {s} · lines", .{ overlap.ticket, first }) else p.add(.dim, "overlaps #{d}: {s} · file", .{ overlap.ticket, first });
        }
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
        p.add(.plain, "{u} {s}{s}", .{ agentGlyph(app, win), @tagName(win.claude), ew.buffered() });
        const shown = @min(win.subs(), App.max_sub_rows);
        for (0..shown) |i| p.add(.dim, "◔ {s}", .{win.sub(i)});
        if (win.subs() > shown) p.add(.dim, "◔ {d} more agents", .{win.subs() - shown});
        if (win.text(.background).len > 0) p.add(.dim, "◔ {s}", .{win.text(.background)});
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

test "a title too long for its slot is cut at a word boundary and ends in …, and one that fits is whole" {
    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("only your move", clipMark(&buf, "only your move", 14));
    try std.testing.expectEqualStrings("only your…", clipMark(&buf, "only your move is shown", 13));
    try std.testing.expectEqualStrings("Portable: transpor…", clipMark(&buf, "Portable: transportation", 19));
    try std.testing.expectEqualStrings("é…", clipMark(&buf, "éééé", 2));
}

test "next is one line a row, and only the picked row shows its why" {
    var board = try tickets.Board.parse(std.testing.allocator,
        \\{"tickets":[],
        \\"plan":{"now":[],"next":[
        \\{"ticket":1,"repo":"arena","title":"one","why":"why one"},
        \\{"ticket":2,"repo":"arena","title":"two","why":"why two"},
        \\{"ticket":3,"repo":"arena","title":"three","why":"why three"},
        \\{"ticket":4,"repo":"arena","title":"four","why":"why four"},
        \\{"ticket":5,"repo":"arena","title":"five","why":"why five"}],
        \\"goals":[],"landed_today":{"count":0,"newest":[]},
        \\"not_planned":{"count":0,"follow_ups":0,"by_repo":{}}}}
    );
    defer board.deinit();
    var app = homeApp(&board);
    defer app.grab.deinit(std.testing.allocator);
    app.view_w = 80;
    app.view_h = 31;
    app.roles = bench.roles();
    app.home = .{ .alone = false, .focus = .plan };
    app.side_folded = true;
    var sheet: sheets.Sheet = undefined;
    try std.testing.expect(app.planSheet(&sheet));
    var nexts: usize = 0;
    var whys: usize = 0;
    for (sheet.rows[0..sheet.n]) |row| {
        nexts += @intFromBool(row.kind == .next);
        whys += @intFromBool(row.kind == .why);
    }
    try std.testing.expectEqual(@as(usize, 5), nexts);
    try std.testing.expect(whys <= 1);
    var third: usize = 0;
    for (sheet.rows[0..sheet.n]) |row| {
        if (row.kind == .next and row.ticket.? == 3) third = row.pick.?;
    }
    app.home.?.plan_pick = third;
    try std.testing.expect(app.planSheet(&sheet));
    whys = 0;
    for (sheet.rows[0..sheet.n], 0..) |row, i| {
        if (row.kind != .why) continue;
        whys += 1;
        try std.testing.expectEqual(@as(u32, 3), sheet.rows[i - 1].ticket.?);
    }
    try std.testing.expectEqual(@as(usize, 1), whys);
}

/// Drags the mouse over the recorded text that starts with `from`, to the end of the line it is on.
fn dragOver(app: *App, from: []const u8) !void {
    const g = &app.grab;
    var found: ?struct { x: u16, y: u16 } = null;
    for (g.rows.items) |r| {
        if (std.mem.startsWith(u8, g.bytes.items[r.at..][0..r.len], from)) found = .{ .x = r.x, .y = r.y };
    }
    const at = found.?;
    try std.testing.expect(!try app.grabMouse(.{ .code = 0, .x = at.x, .y = at.y, .release = false }));
    try std.testing.expect(try app.grabMouse(.{ .code = 32, .x = at.x + 1, .y = at.y, .release = false }));
    try std.testing.expect(try app.grabMouse(.{ .code = 32, .x = 900, .y = at.y, .release = false }));
    _ = try app.grabMouse(.{ .code = 0, .x = 900, .y = at.y, .release = true });
}

test "a drag over a next row and over a goal's title in the driving window each copy their text" {
    var app = try epicApp(true, 40, 100);
    defer app.board.?.deinit();
    defer app.out.deinit(std.testing.allocator);
    defer app.grab.deinit(std.testing.allocator);
    defer if (app.report_said) |said| std.testing.allocator.free(said);
    var shot: Writer.Allocating = .init(std.testing.allocator);
    defer shot.deinit();
    try planView(&app, &shot.writer, app.home.?);

    try dragOver(&app, "The board");
    var text = try app.grab.read(std.testing.allocator, app.grab.sel.?);
    try std.testing.expect(std.mem.indexOf(u8, text, "The board, redesigned") != null);
    try std.testing.expect(std.mem.indexOf(u8, app.out.items, "\x1b]52;c;") != null);
    std.testing.allocator.free(text);

    var board = try tickets.Board.parse(std.testing.allocator,
        \\{"tickets":[],
        \\"plan":{"now":[],"next":[
        \\{"ticket":1,"repo":"arena","title":"one thing","why":"why one"},
        \\{"ticket":2,"repo":"arena","title":"two things","why":"why two"}],
        \\"goals":[],"landed_today":{"count":0,"newest":[]},
        \\"not_planned":{"count":0,"follow_ups":0,"by_repo":{}}}}
    );
    defer board.deinit();
    var next_app = homeApp(&board);
    defer next_app.out.deinit(std.testing.allocator);
    defer if (next_app.report_said) |said| std.testing.allocator.free(said);
    defer next_app.grab.deinit(std.testing.allocator);
    next_app.view_w = 100;
    next_app.term_w = 100;
    next_app.view_h = 31;
    next_app.roles = bench.roles();
    next_app.home = .{ .alone = false, .focus = .plan };
    var again: Writer.Allocating = .init(std.testing.allocator);
    defer again.deinit();
    try frame(&next_app, &again.writer, .all);
    try dragOver(&next_app, "#2");
    text = try next_app.grab.read(std.testing.allocator, next_app.grab.sel.?);
    defer std.testing.allocator.free(text);
    try std.testing.expect(std.mem.startsWith(u8, text, "#2 two things"));
    try std.testing.expect(std.mem.indexOfScalar(u8, text, '\n') == null);
}

test "a selection is dropped when a redraw puts other text under it" {
    var board = try tickets.Board.parse(std.testing.allocator,
        \\{"tickets":[],
        \\"plan":{"now":[],"next":[
        \\{"ticket":1,"repo":"arena","title":"one thing","why":"why one"},
        \\{"ticket":2,"repo":"arena","title":"two things","why":"why two"}],
        \\"goals":[],"landed_today":{"count":0,"newest":[]},
        \\"not_planned":{"count":0,"follow_ups":0,"by_repo":{}}}}
    );
    defer board.deinit();
    var app = homeApp(&board);
    defer app.grab.deinit(std.testing.allocator);
    defer app.out.deinit(std.testing.allocator);
    defer if (app.report_said) |said| std.testing.allocator.free(said);
    app.view_w = 100;
    app.term_w = 100;
    app.view_h = 31;
    app.roles = bench.roles();
    app.home = .{ .alone = false, .focus = .plan };
    app.side_folded = true;
    var shot: Writer.Allocating = .init(std.testing.allocator);
    defer shot.deinit();
    try frame(&app, &shot.writer, .all);
    try dragOver(&app, "#2");
    try std.testing.expect(app.grab.sel != null);

    shot.clearRetainingCapacity();
    try frame(&app, &shot.writer, .all);
    try std.testing.expect(app.grab.sel != null);

    var swapped = try tickets.Board.parse(std.testing.allocator,
        \\{"tickets":[],
        \\"plan":{"now":[],"next":[
        \\{"ticket":2,"repo":"arena","title":"two things","why":"why two"},
        \\{"ticket":1,"repo":"arena","title":"one thing","why":"why one"}],
        \\"goals":[],"landed_today":{"count":0,"newest":[]},
        \\"not_planned":{"count":0,"follow_ups":0,"by_repo":{}}}}
    );
    defer swapped.deinit();
    app.board = swapped;
    shot.clearRetainingCapacity();
    try frame(&app, &shot.writer, .all);
    try std.testing.expect(app.grab.sel == null);
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

test "the plan's head is one title, ◆ plan, with no tabs after it" {
    var board = try tickets.Board.parse(std.testing.allocator, epic_board);
    defer board.deinit();
    var app = homeApp(&board);
    defer app.grab.deinit(std.testing.allocator);
    app.view_w = 80;
    app.term_w = 80;
    app.home = .{ .alone = false, .focus = .plan };
    app.side_folded = true;
    var buf: [1 << 17]u8 = undefined;
    var out: Writer = .fixed(&buf);
    try planView(&app, &out, app.home.?);
    const drawn = out.buffered();
    try std.testing.expectEqual(@as(u21, '◆'), (try bench.probe(drawn, 1, 0)).cp);
    try std.testing.expectEqual(@as(u21, 'p'), (try bench.probe(drawn, 3, 0)).cp);
    try std.testing.expect(std.mem.indexOf(u8, drawn, "B board") == null);
}

test "with the drawer open Plan ends at the drawer's left edge: in flight's right column ends before it and no Plan cell is under it" {
    var board = try tickets.Board.parse(std.testing.allocator,
        \\{"tickets":[{"id":760,"repo":"arena","status":"doing","epic_id":326,"title":"Visual"}],
        \\"plan":{"now":[{"ticket":760,"repo":"arena","title":"Visual","state":"building","since":"2026-11-24T04:38:21Z"}],"next":[],
        \\"goals":[{"epic":326,"title":"The board, redesigned","landed":13,"total":18,"steps":[{"ticket":760,"state":"building"}]}],
        \\"landed_today":{"count":0,"newest":[]},"not_planned":{"count":0,"follow_ups":0,"by_repo":{}}}}
    );
    defer board.deinit();
    var app = homeApp(&board);
    defer app.grab.deinit(std.testing.allocator);
    app.term_w = 220;
    app.view_w = 60;
    app.view_h = 24;
    app.home = .{ .focus = .plan };
    app.side_folded = false;
    const left = app.term_w - app.view_w;
    try std.testing.expectEqual(left, app.boardW());
    var buf: [1 << 17]u8 = undefined;
    var out: Writer = .fixed(&buf);
    try planView(&app, &out, app.home.?);
    var counted = false;
    for (0..app.view_h) |y| {
        var row_buf: [1024]u8 = undefined;
        const row = try screenRow(out.buffered(), app.term_w, y, &row_buf);
        try std.testing.expect(try std.unicode.utf8CountCodepoints(row) <= left);
        if (std.mem.indexOf(u8, row, "building · now") != null) counted = true;
    }
    try std.testing.expect(counted);
}

test "auto is in Plan's head alone, with its tools; the orchestrator's column, the rail and the feed lack it" {
    var board = try tickets.Board.parse(std.testing.allocator,
        \\{"tickets":[],"needs_you":[
        \\{"id":"ask:3","kind":"ask","ticket":16,"repo":"arena","text":"#16 arena  asks: Blue?",
        \\ "actions":[{"key":"1","label":"Blue","argv":["babylon","answer","3","1"]}]}],
        \\"auto":{"on":true,"cap":6,"working":4,"idle":{"slots":2,"why":"next empty"},"tools":{"working":1,"cap":2}},
        \\"plan":{"now":[],"next":[]}}
    );
    defer board.deinit();
    var app = homeApp(&board);
    defer app.grab.deinit(std.testing.allocator);
    app.term_w = 140;
    app.view_w = 60;
    app.home = .{ .focus = .plan };
    var buf: [1 << 17]u8 = undefined;
    var out: Writer = .fixed(&buf);
    try frame(&app, &out, .all);
    const drawn = out.buffered();
    const count = struct {
        fn of(hay: []const u8, needle: []const u8) usize {
            return std.mem.count(u8, hay, needle);
        }
    }.of;
    try std.testing.expectEqual(@as(usize, 1), count(drawn, "auto 4/6"));
    try std.testing.expectEqual(@as(usize, 1), count(drawn, "tools 1/2"));
    try std.testing.expectEqual(@as(usize, 0), count(drawn, "slots idle"));
    try std.testing.expectEqual(@as(usize, 0), count(drawn, "idle"));
    app.term_w = 80;
    app.view_w = 80;
    app.home = .{ .alone = false, .focus = .plan };
    app.side_folded = true;
    var head_out: Writer = .fixed(&buf);
    try planView(&app, &head_out, app.home.?);
    const at = planAutoSwitch(&app).?;
    const mark = try bench.probe(head_out.buffered(), at.x, 0);
    try std.testing.expectEqual(@as(u21, '◐'), mark.cp);
}

test "a card to try wears ▲ try it in the you colour, filled" {
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
}

test "a to-try tile is drawn: its chip, its age in the you colour at a week, the machine's line, a check's rows and the picked check's buttons, with no close untried" {
    var b = try tickets.Board.parse(std.testing.allocator, feed.try_sample);
    defer b.deinit();
    var app: App = .{ .gpa = std.testing.allocator, .io = undefined, .tmux_in = undefined };
    app.roles = @import("parts.zig").roles();
    const r = app.roles.?;
    var f: feed.Feed = undefined;
    feed.buildPicked(&f, &b, &.{}, &.{}, 56, 80, 1795262400, 2);
    var buf: [2048]u8 = undefined;
    var want: [64]u8 = undefined;
    const Rows = struct {
        fn at(app_: *const App, f_: *const feed.Feed, out_: []u8, row: usize) ![]const u8 {
            var out: Writer = .fixed(out_);
            var pen: Pen = .{};
            try win_feed.feedRow(app_, &out, &pen, f_, row, 56);
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
    try std.testing.expect(!Rows.has(machine, "close untried"));

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

test "Plan's windows keep their slots: another window's rows or a count move none of them" {
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
    var shapes: [2]struct { text: []const u8 } = .{
        .{ .text = few },
        .{ .text = many_text[0..used] },
    };
    for (&shapes) |shape| {
        var board = try tickets.Board.parse(std.testing.allocator, shape.text);
        defer board.deinit();
        var app = homeApp(&board);
        defer app.grab.deinit(std.testing.allocator);
        app.term_w = 80;
        app.view_w = 80;
        app.view_h = 23;
        app.roles = bench.roles();
        app.home = .{ .alone = false, .focus = .plan };
        app.side_folded = true;
        var buf: [262144]u8 = undefined;
        var out: Writer = .fixed(&buf);
        try planView(&app, &out, app.home.?);
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
    defer app.grab.deinit(std.testing.allocator);
    app.term_w = 120;
    app.view_w = 80;
    app.view_h = 31;
    app.roles = bench.roles();
    const r = bench.roles();
    app.home = .{ .alone = false, .focus = .plan };
    app.side_folded = true;
    var buf: [262144]u8 = undefined;
    var out: Writer = .fixed(&buf);
    try planView(&app, &out, app.home.?);
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

test "an in-flight row with a Claude says its session, window and pane on a second line, in the session's repo colour" {
    var board = try tickets.Board.parse(std.testing.allocator,
        \\{"tickets":[{"id":701,"repo":"arena","status":"doing","title":"A","claimed_by":"%5"}],
        \\"plan":{"now":[{"ticket":701,"repo":"arena","title":"A","state":"building","pane":"%5"}],"next":[],"goals":[],
        \\"landed_today":{"count":0,"newest":[]},"not_planned":{"count":0,"follow_ups":0,"by_repo":{}}}}
    );
    defer board.deinit();
    var pane: Pane = .{ .id = 5, .term = undefined, .stream = undefined };
    var panes = [_]*Pane{&pane};
    var win: Window = .{ .id = 1, .index = 2, .name = @constCast("w"), .claude = .working, .since = 1, .info = @constCast("\t\t\t\tt701-x\t\t\t/h/projects/babylon/.worktrees/t701-x") };
    win.panes = .fromOwnedSlice(&panes);
    var wins = [_]*Window{&win};
    var session: Session = .{ .id = 2, .name = @constCast("babylon-work") };
    session.wins = .fromOwnedSlice(&wins);
    var sessions = [_]*Session{&session};
    var app = homeApp(&board);
    defer app.grab.deinit(std.testing.allocator);
    app.sessions = .fromOwnedSlice(&sessions);
    app.term_w = 80;
    app.view_w = 80;
    app.view_h = 23;
    app.roles = bench.roles();
    app.home = .{ .alone = false, .focus = .plan };
    app.side_folded = true;
    var buf: [262144]u8 = undefined;
    var out: Writer = .fixed(&buf);
    try planView(&app, &out, app.home.?);
    const drawn = out.buffered();
    try std.testing.expect(std.mem.indexOf(u8, drawn, "babylon-work:2 · %5") != null);
}

/// The `y`th row of `frame` drawn on a terminal `cols` wide, without its trailing spaces.
fn screenRow(frame_bytes: []const u8, cols: u16, y: usize, buf: []u8) ![]const u8 {
    const gpa = std.testing.allocator;
    var term: vt.Terminal = try .init(std.testing.io, gpa, .{ .cols = cols, .rows = 30, .max_scrollback_bytes = 0 });
    defer term.deinit(gpa);
    var stream = term.vtStream();
    defer stream.deinit();
    stream.nextSlice(frame_bytes);
    const text = try term.plainString(gpa);
    defer gpa.free(text);
    var lines = std.mem.splitScalar(u8, text, '\n');
    var at: usize = 0;
    while (lines.next()) |line| : (at += 1) {
        if (at != y) continue;
        const trimmed = std.mem.trimEnd(u8, line, " ");
        @memcpy(buf[0..trimmed.len], trimmed);
        return buf[0..trimmed.len];
    }
    return buf[0..0];
}

fn footApp(board: *tickets.Board, term_w: u16, s: *Session) App {
    var app: App = .{ .gpa = std.testing.allocator, .io = undefined, .tmux_in = undefined };
    app.board = board.*;
    app.term_w = term_w;
    app.view_w = term_w;
    app.view_h = 24;
    app.current = s.id;
    return app;
}

test "the foot row has home, the session with a dot and number per window, go to and the menu at 220 cells, and the dots alone at 110" {
    var board = try tickets.Board.parse(std.testing.allocator, "{\"tickets\":[]}");
    defer board.deinit();
    var s: Session = .{ .id = 2, .name = @constCast("arena") };
    var a: Window = .{ .id = 1, .name = @constCast("a") };
    var b: Window = .{ .id = 2, .name = @constCast("b"), .claude = .done, .since = 1 };
    var c: Window = .{ .id = 3, .name = @constCast("c") };
    var wins = [_]*Window{ &a, &b, &c };
    s.wins = .fromOwnedSlice(&wins);
    var sessions = [_]*Session{&s};
    var buf: [65536]u8 = undefined;
    var row: [512]u8 = undefined;

    var wide = footApp(&board, 220, &s);
    wide.sessions = .fromOwnedSlice(&sessions);
    var out: Writer = .fixed(&buf);
    try dots(&wide, &out, &s);
    const long = try screenRow(out.buffered(), 220, 24, &row);
    try std.testing.expect(std.mem.indexOf(u8, long, " ◆ home") != null);
    try std.testing.expect(std.mem.indexOf(u8, long, "arena         ● 1 ◉ 2 ○ 3") != null);
    try std.testing.expect(std.mem.indexOf(u8, long, "│  s go to  ≡") != null);
    try std.testing.expect(std.mem.endsWith(u8, long, "INSERT ^space"));

    var half = footApp(&board, 110, &s);
    half.sessions = .fromOwnedSlice(&sessions);
    out = .fixed(&buf);
    try dots(&half, &out, &s);
    const short = try screenRow(out.buffered(), 110, 24, &row);
    try std.testing.expect(std.mem.indexOf(u8, short, " ◆ home") != null);
    try std.testing.expect(std.mem.indexOf(u8, short, "arena    ●◉○ │ s go to  ≡") != null);
    try std.testing.expect(std.mem.indexOf(u8, short, "INSERT") == null);
}

test "Plan and a pane view start at column 0 at 220 and 110 cells" {
    var board = try tickets.Board.parse(std.testing.allocator,
        \\{"tickets":[],"plan":{"now":[],"next":[],"goals":[],
        \\"landed_today":{"count":0,"newest":[]},"not_planned":{"count":0,"follow_ups":0,"by_repo":{}}}}
    );
    defer board.deinit();
    var s: Session = .{ .id = 2, .name = @constCast("arena") };
    var a: Window = .{ .id = 1, .name = @constCast("a") };
    var wins = [_]*Window{&a};
    s.wins = .fromOwnedSlice(&wins);
    var sessions = [_]*Session{&s};
    var buf: [262144]u8 = undefined;
    var row: [4096]u8 = undefined;
    for ([_]u16{ 220, 110 }) |cols| {
        var app = homeApp(&board);
        defer app.grab.deinit(std.testing.allocator);
        app.term_w = cols;
        app.view_w = cols;
        app.sessions = .fromOwnedSlice(&sessions);
        app.roles = bench.roles();
        app.current = s.id;
        app.home = .{ .alone = false, .focus = .plan };
        app.side_folded = true;
        var out: Writer = .fixed(&buf);
        try planView(&app, &out, app.home.?);
        const head = try screenRow(out.buffered(), cols, 0, &row);
        try std.testing.expect(std.mem.startsWith(u8, head, " ◆ plan"));
        const underline = try screenRow(out.buffered(), cols, 1, &row);
        try std.testing.expect(std.mem.startsWith(u8, underline, "──"));

        app.home = null;
        out = .fixed(&buf);
        _ = try strip(&app, &out, &s, 0, .all);
        const pane = try screenRow(out.buffered(), cols, 0, &row);
        try std.testing.expect(std.mem.startsWith(u8, pane, "╭─"));
    }
}

test "the empty switcher lists Claudes by urgency, then sessions in tmux's order, then + new session" {
    var board = try tickets.Board.parse(std.testing.allocator, "{\"tickets\":[]}");
    defer board.deinit();
    var first: Session = .{ .id = 2, .name = @constCast("alpha") };
    var second: Session = .{ .id = 3, .name = @constCast("beta") };
    var work: Window = .{ .id = 1, .name = @constCast("work-w"), .claude = .working, .since = 1 };
    var wait: Window = .{ .id = 2, .name = @constCast("wait-w"), .claude = .waiting, .since = 1 };
    var done: Window = .{ .id = 3, .name = @constCast("done-w"), .claude = .done, .since = 1 };
    var wa = [_]*Window{ &work, &wait };
    var wb = [_]*Window{&done};
    first.wins = .fromOwnedSlice(&wa);
    second.wins = .fromOwnedSlice(&wb);
    var sessions = [_]*Session{ &first, &second };
    var app = footApp(&board, 80, &first);
    app.sessions = .fromOwnedSlice(&sessions);
    app.prompt = .{ .what = .jump };
    var buf: [65536]u8 = undefined;
    var out: Writer = .fixed(&buf);
    _ = try promptBox(&app, &out, &app.prompt.?);
    const drawn = out.buffered();
    var row: [512]u8 = undefined;
    const expected = [_][]const u8{ "wait-w", "done-w", "work-w", "alpha", "beta", "+ new session" };
    var from: usize = 0;
    for (expected) |want| {
        var found = false;
        for (from..24) |y| {
            const text = try screenRow(drawn, 80, y, &row);
            if (std.mem.indexOf(u8, text, want) == null) continue;
            from = y + 1;
            found = true;
            break;
        }
        try std.testing.expect(found);
    }
}

test "a Claude's hover card lists each subagent and its shell under its state line" {
    var win: Window = .{ .id = 1, .name = @constCast("w"), .claude = .working, .info = @constCast("\t\t\t\t\tmix ecto.migrate\tlint run\x1fcheck deps") };
    var s: Session = .{ .id = 1, .name = @constCast("s") };
    var wins = [_]*Window{&win};
    s.wins = .fromOwnedSlice(&wins);
    var sessions = [_]*Session{&s};
    var app: App = .{ .gpa = std.testing.allocator, .io = undefined, .tmux_in = undefined };
    app.term_w = 100;
    app.view_w = 100;
    app.view_h = 30;
    app.sessions = .fromOwnedSlice(&sessions);
    var buf: [65536]u8 = undefined;
    var out: Writer = .fixed(&buf);
    try lookBox(&app, &out, .{ .window = 1 });
    const drawn = out.buffered();
    const state = std.mem.indexOf(u8, drawn, "working") orelse return error.NoState;
    const first = std.mem.indexOf(u8, drawn, "◔ lint run") orelse return error.NoSub;
    const second = std.mem.indexOf(u8, drawn, "◔ check deps") orelse return error.NoSub;
    const shell = std.mem.indexOf(u8, drawn, "◔ mix ecto.migrate") orelse return error.NoShell;
    try std.testing.expect(state < first and first < second and second < shell);
    try std.testing.expect(std.mem.indexOf(u8, drawn, "2 agents") == null);
}

test "Your move with 8 items scrolls inside its five rows to the picked one" {
    var buf: [4096]u8 = undefined;
    var json: Writer = .fixed(&buf);
    try json.writeAll("{\"tickets\":[],\"needs_you\":[");
    for (0..8) |i| try json.print("{s}{{\"id\":\"ask:{d}\",\"kind\":\"ask\",\"ticket\":{d},\"repo\":\"arena\",\"text\":\"item {d}\",\"actions\":[]}}", .{ if (i > 0) "," else "", i, 100 + i, i });
    try json.writeAll("],\"plan\":{\"now\":[],\"next\":[],\"goals\":[],\"landed_today\":{\"count\":0,\"newest\":[]},\"not_planned\":{\"count\":0,\"follow_ups\":0,\"by_repo\":{}}}}");
    var board = try tickets.Board.parse(std.testing.allocator, json.buffered());
    defer board.deinit();
    var app = homeApp(&board);
    defer app.grab.deinit(std.testing.allocator);
    app.term_w = 80;
    app.view_w = 80;
    app.view_h = 31;
    app.roles = bench.roles();
    app.home = .{ .alone = false, .focus = .plan, .plan_pick = 7 };
    var screen: [262144]u8 = undefined;
    var out: Writer = .fixed(&screen);
    try planView(&app, &out, app.home.?);
    const drawn = out.buffered();
    try std.testing.expect(std.mem.indexOf(u8, drawn, "item 7") != null);
    try std.testing.expect(std.mem.indexOf(u8, drawn, "item 0") == null);
}

test "on the e2e's 24-row screen every Plan window keeps its title and a body row" {
    var board = try tickets.Board.parse(std.testing.allocator,
        \\{"tickets":[],"needs_you":[],"plan":{"now":[],"next":[],"goals":[],"landed_today":{"count":0,"newest":[]},"not_planned":{"count":0,"follow_ups":0,"by_repo":{}}}}
    );
    defer board.deinit();
    var app = homeApp(&board);
    defer app.grab.deinit(std.testing.allocator);
    app.term_w = 121;
    app.view_w = 60;
    app.view_h = 24;
    app.roles = bench.roles();
    app.home = .{ .alone = false, .focus = .plan };
    app.side_folded = true;
    var screen: [262144]u8 = undefined;
    var out: Writer = .fixed(&screen);
    try planView(&app, &out, app.home.?);
    for (std.enums.values(sheets.Window)) |win| {
        try std.testing.expect(app.planSlot(win).h > sheets.window_chrome);
        // goals' `+ goal` button covers the end of its title at this width
        const shown = if (win == .goals) win.title()[0..4] else win.title();
        try std.testing.expect(std.mem.indexOf(u8, out.buffered(), shown) != null);
    }
}

test "a Your move item ends its row in its first action's key, ticket or none, picked or not, and an open one does not and wears ▸" {
    var board = try tickets.Board.parse(std.testing.allocator,
        \\{"tickets":[],"needs_you":[
        \\{"id":"push:arena:abc:0","kind":"push","ticket":null,"repo":"arena","text":"▲ arena: 3 unpushed",
        \\ "actions":[{"key":"⏎","label":"push","argv":["babylon","push","arena"]},{"key":"l","label":"look"}]},
        \\{"id":"push:1","kind":"push","ticket":7,"repo":"arena","text":"3 commits to push","since":"2026-11-21T10:00:00Z",
        \\ "actions":[{"key":"⏎","label":"push","argv":["babylon","push","arena"]},{"key":"l","label":"look"}]}],
        \\"plan":{"now":[],"next":[],"goals":[],"landed_today":{"count":0,"newest":[]},"not_planned":{"count":0,"follow_ups":0,"by_repo":{}}}}
    );
    defer board.deinit();
    var app = homeApp(&board);
    defer app.grab.deinit(std.testing.allocator);
    app.term_w = 80;
    app.view_w = 80;
    app.view_h = 40;
    app.roles = bench.roles();
    app.home = .{ .focus = .plan };
    const rect = app.planRect(.move);
    var sheet: sheets.Sheet = undefined;
    try std.testing.expect(app.planSheet(&sheet));
    var buf: [65536]u8 = undefined;
    var out: Writer = .fixed(&buf);
    try win_plan.benchPlanRow(&app, &out, bench.roles(), &sheet, 0, 0, rect.x, rect.w - 1, false);
    try std.testing.expect(std.mem.indexOf(u8, out.buffered(), "⏎ push") != null);
    var picked_out: Writer = .fixed(&buf);
    try win_plan.benchPlanRow(&app, &picked_out, bench.roles(), &sheet, 1, 0, rect.x, rect.w - 1, true);
    try std.testing.expect(std.mem.indexOf(u8, picked_out.buffered(), "⏎ push") != null);

    app.home.?.detail = 7;
    try std.testing.expect(app.planSheet(&sheet));
    var open_out: Writer = .fixed(&buf);
    try win_plan.benchPlanRow(&app, &open_out, bench.roles(), &sheet, 1, 0, rect.x, rect.w - 1, true);
    try std.testing.expect(std.mem.indexOf(u8, open_out.buffered(), "⏎") == null);
    try std.testing.expect(std.mem.indexOf(u8, open_out.buffered(), "▸") != null);
}

test "with a Your move item's card open, every Your move row is drawn above it, the open one marked ▸, and the card has its check's y and no close untried" {
    var board = try tickets.Board.parse(std.testing.allocator,
        \\{"tickets":[{"id":1105,"repo":"arena","title":"Your move says its key","status":"try","stage":"landed",
        \\"checks":[{"n":1,"text":"it folds back","result":null},{"n":2,"text":"the pick stays","result":null}]}],
        \\"needs_you":[
        \\{"id":"try:1105","kind":"try","ticket":1105,"repo":"arena","text":"#1105 arena  to try","machine":"gate ✓",
        \\ "steps":[{"n":1,"text":"it folds back","result":null,"actions":[{"key":"y","label":"✓"},{"key":"n","label":"✗"}]},
        \\  {"n":2,"text":"the pick stays","result":null,"actions":[{"key":"y","label":"✓"},{"key":"n","label":"✗"}]}],
        \\ "actions":[{"key":"x","label":"close untried","argv":["babylon","tried","1105","skip"]}]},
        \\{"id":"push:arena:abc:0","kind":"push","ticket":null,"repo":"arena","text":"▲ arena: 2 unpushed",
        \\ "actions":[{"key":"⏎","label":"push","argv":["babylon","push","arena"]}]}],
        \\"plan":{"now":[],"next":[],"goals":[],"landed_today":{"count":0,"newest":[]},"not_planned":{"count":0,"follow_ups":0,"by_repo":{}}}}
    );
    defer board.deinit();
    var app = homeApp(&board);
    defer app.grab.deinit(std.testing.allocator);
    app.view_w = 48;
    app.view_h = 30;
    app.roles = bench.roles();
    app.home = .{ .focus = .plan, .detail = 1105 };
    var buf: [1 << 18]u8 = undefined;
    var out: Writer = .fixed(&buf);
    try planView(&app, &out, app.home.?);
    const slot = app.planSlot(.move);
    var line: [1024]u8 = undefined;

    const first = try screenRow(out.buffered(), app.term_w, slot.y + 1, &line);
    try std.testing.expect(std.mem.indexOf(u8, first, "▸▲ #1105 arena") != null);
    const second = try screenRow(out.buffered(), app.term_w, slot.y + 2, &line);
    try std.testing.expect(std.mem.indexOf(u8, second, "arena: 2 unpushed") != null);
    try std.testing.expect(app.modalRect().?.y >= slot.y + slot.h);
    var y_seen = false;
    for (slot.y + slot.h..app.view_h) |y| {
        const row = try screenRow(out.buffered(), app.term_w, y, &line);
        try std.testing.expect(std.mem.indexOf(u8, row, "close untried") == null);
        y_seen = y_seen or std.mem.indexOf(u8, row, "y ✓ it works") != null;
    }
    try std.testing.expect(y_seen);
}

const grid_board =
    \\{"tickets":[
    \\{"id":701,"repo":"arena","status":"doing","title":"A step that is building right now and long, with more words to push it past the edge of any window"},
    \\{"id":702,"repo":"babylon","status":"doing","title":"B"},
    \\{"id":703,"repo":"menard","status":"todo","title":"C"},
    \\{"id":410,"repo":"arena","kind":"epic","status":"doing","title":"menard goal"}],
    \\"plan":{"driving":410,"now":[
    \\{"ticket":701,"repo":"arena","title":"A step that is building right now and long, with more words to push it past the edge of any window","state":"building","since":"2026-11-23T07:04:00Z"},
    \\{"ticket":702,"repo":"babylon","title":"B","state":"landing","stage":"verifying","since":"2026-11-22T04:04:00Z"}],
    \\"next":[{"ticket":703,"repo":"menard","title":"C","why":"","waits_on":[]}],
    \\"goals":[
    \\{"epic":410,"title":"menard goal","total":12,"landed":5,"steps":[{"ticket":701,"state":"building"},{"ticket":702,"state":"building"},{"ticket":703,"state":"building"}]},
    \\{"epic":9,"title":"A second goal with a very long title that must be cut","total":15,"landed":14,"steps":[{"ticket":703,"state":"next"},{"ticket":702,"state":"to_try"}]}],
    \\"landed_today":{"count":1,"newest":[701]},"not_planned":{"count":0,"follow_ups":0,"by_repo":{}}}}
;

/// Plan drawn on a `width` by 38 screen from `grid_board`, read back as a grid of cells.
fn planGrid(board: *tickets.Board, width: u16) !struct { app: App, grid: bench.Grid } {
    var app = homeApp(board);
    app.term_w = 120;
    app.view_w = width;
    app.view_h = 38;
    app.epoch = tickets.epochOf("2026-11-23T07:10:00Z").?;
    app.roles = bench.roles();
    app.home = .{ .alone = false, .focus = .plan };
    app.side_folded = true;
    var buf: [262144]u8 = undefined;
    var out: Writer = .fixed(&buf);
    try planView(&app, &out, app.home.?);
    return .{ .app = app, .grid = try bench.Grid.init(out.buffered()) };
}

/// The first row of `slot` whose cells within it hold `needle`.
fn rowWith(g: *const bench.Grid, slot: sheets.Rect, needle: []const u8) ?usize {
    for (slot.y..slot.y + slot.h) |y| {
        if (g.find(y, slot.x, slot.x + slot.w, needle) != null) return y;
    }
    return null;
}

test "in a goals window every value starts at one x, and a bar's ends sit on the text column and the count's left edge" {
    const eq = std.testing.expectEqual;
    var board = try tickets.Board.parse(std.testing.allocator, grid_board);
    defer board.deinit();
    var shot = try planGrid(&board, 100);
    defer shot.app.grab.deinit(std.testing.allocator);
    const g = &shot.grid;
    const r = bench.roles();
    const slot = shot.app.planSlot(.goals);
    const x0: usize = slot.x;
    const to = x0 + slot.w;

    const blocked = rowWith(g, slot, "blocked").?;
    const next = blocked - 1;
    const bar = blocked - 2;
    const title = blocked - 3;
    try eq(x0 + 2, g.find(title, x0, to, "#9").?);
    try eq(x0 + 2, g.find(next, x0, to, "next").?);
    try eq(x0 + 2, g.find(blocked, x0, to, "blocked").?);
    try eq(g.find(next, x0, to, "#703").?, g.find(blocked, x0, to, "nothing").?);

    const count = g.find(bar, x0, to, "14/15").?;
    try eq(r.well, g.bgs[bar][x0 + 2]);
    try std.testing.expect(!std.meta.eql(r.well, g.bgs[bar][x0 + 1]));
    try eq(r.well, g.bgs[bar][count - 2]);
    try std.testing.expect(!std.meta.eql(r.well, g.bgs[bar][count - 1]));

    const driving = shot.app.planSlot(.driving);
    const dbar = rowWith(g, driving, "5/12").?;
    const dtitle = rowWith(g, driving, "menard goal").?;
    try eq(driving.x + 2, g.find(dtitle, driving.x, driving.x + driving.w, "menard goal").?);
    try eq(r.well, g.bgs[dbar][driving.x + 2]);
    const dcount = g.find(dbar, driving.x, driving.x + driving.w, "5/12").?;
    try eq(r.well, g.bgs[dbar][dcount - 2]);
    try std.testing.expect(!std.meta.eql(r.well, g.bgs[dbar][dcount - 1]));
}

test "every Plan window has its ◆ title and its count in the same places, no ▾, and driving's epic sits two cells after its title" {
    const eq = std.testing.expectEqual;
    var board = try tickets.Board.parse(std.testing.allocator, grid_board);
    defer board.deinit();
    var shot = try planGrid(&board, 100);
    defer shot.app.grab.deinit(std.testing.allocator);
    const g = &shot.grid;
    for (std.enums.values(sheets.Window)) |win| {
        const slot = shot.app.planSlot(win);
        const ww = slot.w - 1;
        const named = if (win == .driving) sheets.drivingTitle(shot.app.board.?.plan().?, &shot.app.board.?) else win.title();
        try eq(@as(u21, '◆'), g.cps[slot.y][slot.x + 1]);
        try eq(slot.x + 3, g.find(slot.y, slot.x, slot.x + ww, named).?);
        try std.testing.expect(g.find(slot.y, slot.x, slot.x + ww, "▾") == null);
        if (win_plan.windowCount(&shot.app.board.?, shot.app.board.?.plan().?, win) != null) {
            try eq(slot.x + 4 + cellCount(named), g.find(slot.y, slot.x, slot.x + ww, "▎").?);
        }
    }
    const driving = shot.app.planSlot(.driving);
    const pick = g.find(driving.y, driving.x, driving.x + driving.w, "your pick").?;
    try eq(pick + 9 + 2, g.find(driving.y, driving.x, driving.x + driving.w, "epic #410").?);
}

test "the step chain's arrows each have one cell before and after them, and a chip right after" {
    const eq = std.testing.expectEqual;
    var board = try tickets.Board.parse(std.testing.allocator, grid_board);
    defer board.deinit();
    var shot = try planGrid(&board, 100);
    defer shot.app.grab.deinit(std.testing.allocator);
    const g = &shot.grid;
    const slot = shot.app.planSlot(.driving);
    const y = rowWith(g, slot, "#701").?;
    var arrows: usize = 0;
    for (slot.x..slot.x + slot.w) |x| {
        if (g.cps[y][x] != '▶') continue;
        arrows += 1;
        try eq(@as(u21, '─'), g.cps[y][x - 1]);
        try eq(@as(u21, ' '), g.cps[y][x - 2]);
        try eq(@as(u21, ' '), g.cps[y][x + 1]);
        try eq(@as(u21, '▎'), g.cps[y][x + 2]);
    }
    try eq(@as(usize, 2), arrows);
}

test "a repo mark, a text line and a bar start on one column inside a window" {
    const eq = std.testing.expectEqual;
    var board = try tickets.Board.parse(std.testing.allocator, grid_board);
    defer board.deinit();
    var shot = try planGrid(&board, 100);
    defer shot.app.grab.deinit(std.testing.allocator);
    const g = &shot.grid;
    const now = shot.app.planSlot(.now);
    const flying = rowWith(g, now, "#701").?;
    try std.testing.expect(g.cps[flying][now.x + 2] != ' ');
    try eq(@as(u21, '▌'), g.cps[flying][now.x + 1]);
    const landed = shot.app.planSlot(.landed);
    const row = rowWith(g, landed, "#701").?;
    try eq(@as(u21, '✓'), g.cps[row][landed.x + 2]);
    const unplanned = shot.app.planSlot(.unplanned);
    try eq(unplanned.x + 2, g.find(rowWith(g, unplanned, "nothing to do").?, unplanned.x, unplanned.x + unplanned.w, "nothing to do").?);
}

test "home with no plan draws why, and the way back" {
    var app: App = .{ .gpa = std.testing.allocator, .io = undefined, .tmux_in = undefined };
    app.view_w = 80;
    app.view_h = 24;
    app.roles = bench.roles();
    app.board_error = error.UnexpectedToken;
    app.home = .{};
    var buf: [8192]u8 = undefined;
    var out: Writer = .fixed(&buf);
    try planView(&app, &out, app.home.?);
    const drawn = out.buffered();
    try std.testing.expect(std.mem.indexOf(u8, drawn, "babylon's board didn't parse: UnexpectedToken") != null);
    try std.testing.expect(std.mem.indexOf(u8, drawn, "q to go back") != null);
}

test "every title cut to fit ends in …" {
    var board = try tickets.Board.parse(std.testing.allocator, grid_board);
    defer board.deinit();
    var shot = try planGrid(&board, 100);
    defer shot.app.grab.deinit(std.testing.allocator);
    const g = &shot.grid;

    const cut = [_]struct { win: sheets.Window, id: []const u8, whole: []const u8 }{
        .{ .win = .now, .id = "#701", .whole = "A step that is building right now and long, with more words to push it past the edge of any window" },
        .{ .win = .goals, .id = "#9", .whole = "A second goal with a very long title that must be cut" },
        .{ .win = .landed, .id = "#701", .whole = "A step that is building right now and long, with more words to push it past the edge of any window" },
    };
    for (cut) |c| {
        const slot = shot.app.planSlot(c.win);
        const y = rowWith(g, slot, c.id).?;
        var buf: [512]u8 = undefined;
        const text = g.line(&buf, y, slot.x, slot.x + slot.w - 1);
        try std.testing.expect(std.mem.indexOf(u8, text, c.whole) == null);
        try std.testing.expect(std.mem.indexOf(u8, text, "…") != null);
    }
}

test "driving and goals draw progress in one shape, N/M then a percent, ending the same distance from their window's edge" {
    const eq = std.testing.expectEqual;
    var board = try tickets.Board.parse(std.testing.allocator, grid_board);
    defer board.deinit();
    var shot = try planGrid(&board, 100);
    defer shot.app.grab.deinit(std.testing.allocator);
    const g = &shot.grid;
    const driving = shot.app.planSlot(.driving);
    const goals = shot.app.planSlot(.goals);
    const cases = [_]struct { slot: sheets.Rect, label: []const u8, tail: []const u8 }{
        .{ .slot = driving, .label = "5/12  41%", .tail = "" },
        .{ .slot = goals, .label = "14/15  93%", .tail = "  ▲ 1 to try" },
    };
    var from_edge: ?usize = null;
    for (cases) |c| {
        const y = rowWith(g, c.slot, c.label).?;
        const at = g.find(y, c.slot.x, c.slot.x + c.slot.w, c.label).?;
        const gap = c.slot.x + c.slot.w - (at + cellCount(c.label) + cellCount(c.tail));
        try eq(from_edge orelse gap, gap);
        from_edge = gap;
    }
}
