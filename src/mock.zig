//! The redesign's mockups: one still frame of Home, the board, a card's popup or the
//! orchestrator's column, in one of three directions, drawn from a board file. A separate
//! program, so arena's own drawing is untouched; it waits on stdin while it is screenshotted.
const std = @import("std");
const tickets = @import("board.zig");
const color = @import("color.zig");
const text_mod = @import("text.zig");
const RGB = color.RGB;
const Card = tickets.Card;
const posix = std.posix;

const usage = "usage: arena-mock phosphor|workbench|neon home|popup|orch|alone|doing|planning|into BOARD.json PALETTE.sh [COLSxROWS OUT.html]\n";

/// The moment the fixture is seen at: every age is counted from here.
const now_at = "2026-11-24T05:00:00Z";

pub const Direction = enum { phosphor, workbench, neon };
pub const Screen = enum { home, popup, orch, alone, doing, planning, into };

const Ink = struct {
    fg: RGB,
    bg: ?RGB = null,
    bold: bool = false,
    italic: bool = false,
    under: bool = false,
};

const Cell = struct {
    cp: u21 = ' ',
    fg: RGB,
    bg: RGB,
    bold: bool = false,
    italic: bool = false,
    under: bool = false,
};

pub const Canvas = struct {
    w: usize,
    h: usize,
    cells: []Cell,

    pub fn init(gpa: std.mem.Allocator, w: usize, h: usize, ground: RGB, fg: RGB) !Canvas {
        const cells = try gpa.alloc(Cell, w * h);
        @memset(cells, .{ .fg = fg, .bg = ground });
        return .{ .w = w, .h = h, .cells = cells };
    }

    fn at(c: *Canvas, x: usize, y: usize) ?*Cell {
        if (x >= c.w or y >= c.h) return null;
        return &c.cells[y * c.w + x];
    }

    pub fn fill(c: *Canvas, x: usize, y: usize, w: usize, h: usize, bg: RGB) void {
        for (y..y + h) |yy| for (x..x + w) |xx| if (c.at(xx, yy)) |cell| {
            cell.* = .{ .fg = cell.fg, .bg = bg };
        };
    }

    pub fn put(c: *Canvas, x: usize, y: usize, cp: u21, ink: Ink) void {
        const cell = c.at(x, y) orelse return;
        cell.* = .{ .cp = cp, .fg = ink.fg, .bg = ink.bg orelse cell.bg, .bold = ink.bold, .italic = ink.italic, .under = ink.under };
    }

    /// `s` from (`x`, `y`), at most `max` cells; the cells written.
    pub fn print(c: *Canvas, x: usize, y: usize, s: []const u8, ink: Ink, max: usize) usize {
        var it = std.unicode.Utf8View.initUnchecked(s).iterator();
        var n: usize = 0;
        while (it.nextCodepoint()) |cp| {
            if (n >= max) break;
            if (n + 1 == max and it.i < s.len) {
                c.put(x + n, y, '…', ink);
                return max;
            }
            c.put(x + n, y, cp, ink);
            n += 1;
        }
        return n;
    }

    /// The background under (`x`, `y`).
    pub fn bgAt(c: *Canvas, x: usize, y: usize) RGB {
        return if (c.at(x, y)) |cell| cell.bg else c.cells[0].bg;
    }

    /// Everything in the rectangle moved toward `ground`, its text kept readable.
    pub fn shade(c: *Canvas, ground: RGB, by: f32) void {
        for (c.cells) |*cell| {
            cell.bg = cell.bg.mix(ground, by);
            if (cell.cp >= 0x2580 and cell.cp <= 0x259f) cell.fg = cell.fg.mix(ground, by) else cell.fg = color.dimFg(cell.fg, cell.bg);
        }
    }

    /// The frame as a page of cells as Ghostty draws them: block elements as shapes that fill
    /// the cell, and text under 4.5:1 against its cell repainted white or black, as the human's
    /// `minimum-contrast` does.
    pub fn writeHtml(c: *const Canvas, w: *std.Io.Writer, ground: RGB) !void {
        try w.print(
            \\<!doctype html><meta charset="utf-8"><style>
            \\body{{margin:0;padding:22px;background:{s};}}
            \\.r{{display:flex;height:18.333px;}}
            \\.r span{{flex:0 0 8.073px;min-width:0;height:18.333px;line-height:18.333px;font:14.667px "ComicShannsMono Nerd Font",monospace;
            \\white-space:pre;text-align:left;overflow:visible;font-variant-ligatures:none;}}
            \\</style><body>
        , .{&hex(ground)});
        for (0..c.h) |y| {
            try w.writeAll("<div class=r>");
            for (c.cells[y * c.w ..][0..c.w]) |cell| try cellHtml(w, cell);
            try w.writeAll("</div>");
        }
    }

    fn cellHtml(w: *std.Io.Writer, cell: Cell) !void {
        const fg = hex(cell.fg);
        const bg = hex(cell.bg);
        const layer: ?[]const u8 = switch (cell.cp) {
            '█' => "linear-gradient(F,F)",
            '▀' => "linear-gradient(to bottom,F 50%,transparent 50%)",
            '▄' => "linear-gradient(to top,F 50%,transparent 50%)",
            '▌' => "linear-gradient(to right,F 50%,transparent 50%)",
            '▐' => "linear-gradient(to left,F 50%,transparent 50%)",
            '▔' => "linear-gradient(to bottom,F 12.5%,transparent 12.5%)",
            '▁' => "linear-gradient(to top,F 12.5%,transparent 12.5%)",
            '▕' => "linear-gradient(to left,F 12.5%,transparent 12.5%)",
            '▏' => "linear-gradient(to right,F 12.5%,transparent 12.5%)",
            '▎' => "linear-gradient(to right,F 25%,transparent 25%)",
            '▍' => "linear-gradient(to right,F 37.5%,transparent 37.5%)",
            '▋' => "linear-gradient(to right,F 62.5%,transparent 62.5%)",
            '▊' => "linear-gradient(to right,F 75%,transparent 75%)",
            '▉' => "linear-gradient(to right,F 87.5%,transparent 87.5%)",
            '▖' => "linear-gradient(F,F) left bottom/50% 50% no-repeat",
            '▗' => "linear-gradient(F,F) right bottom/50% 50% no-repeat",
            '▘' => "linear-gradient(F,F) left top/50% 50% no-repeat",
            '▝' => "linear-gradient(F,F) right top/50% 50% no-repeat",
            '▚' => "linear-gradient(F,F) left top/50% 50% no-repeat,linear-gradient(F,F) right bottom/50% 50% no-repeat",
            '▞' => "linear-gradient(F,F) right top/50% 50% no-repeat,linear-gradient(F,F) left bottom/50% 50% no-repeat",
            0xe0b6 => "radial-gradient(ellipse 100% 50% at 100% 50%,F 98%,transparent 100%)",
            0xe0b4 => "radial-gradient(ellipse 100% 50% at 0% 50%,F 98%,transparent 100%)",
            else => null,
        };
        if (layer) |l| {
            try w.writeAll("<span style=\"background:");
            var it = std.mem.splitScalar(u8, l, 'F');
            try w.writeAll(it.first());
            while (it.next()) |part| try w.print("{s}{s}", .{ &fg, part });
            try w.print(",{s}\"></span>", .{&bg});
            return;
        }
        if (cell.cp == '░' or cell.cp == '▒') {
            try w.print("<span style=\"background:{s}\"></span>", .{&hex(cell.bg.mix(cell.fg, if (cell.cp == '░') 0.25 else 0.5))});
            return;
        }
        const white: RGB = .{ .r = 255, .g = 255, .b = 255 };
        const black: RGB = .{ .r = 0, .g = 0, .b = 0 };
        const shown = if (cell.cp == ' ' or color.contrast(cell.fg, cell.bg) >= color.floor) cell.fg else if (color.contrast(white, cell.bg) > color.contrast(black, cell.bg)) white else black;
        try w.print("<span style=\"background:{s};color:{s}", .{ &bg, &hex(shown) });
        if (cell.bold) try w.writeAll(";font-weight:bold");
        if (cell.italic) try w.writeAll(";font-style:italic");
        if (cell.under) try w.writeAll(";text-decoration:underline");
        // a glyph the font draws wider than its cell overflows over the next, not under it
        if (cell.cp > 0x7f) try w.writeAll(";position:relative;z-index:1");
        try w.writeAll("\">");
        switch (cell.cp) {
            '<' => try w.writeAll("&lt;"),
            '&' => try w.writeAll("&amp;"),
            '>' => try w.writeAll("&gt;"),
            else => {
                var buf: [4]u8 = undefined;
                const len = std.unicode.utf8Encode(cell.cp, &buf) catch 1;
                try w.writeAll(buf[0..len]);
            },
        }
        try w.writeAll("</span>");
    }

    fn hex(c: RGB) [7]u8 {
        var out: [7]u8 = undefined;
        _ = std.fmt.bufPrint(&out, "#{x:0>2}{x:0>2}{x:0>2}", .{ c.r, c.g, c.b }) catch unreachable;
        return out;
    }

    pub fn write(c: *const Canvas, w: *std.Io.Writer) !void {
        try w.writeAll("\x1b[?25l\x1b[H");
        var last: ?Cell = null;
        for (0..c.h) |y| {
            try w.print("\x1b[{d};1H", .{y + 1});
            for (c.cells[y * c.w ..][0..c.w]) |cell| {
                const same = if (last) |l| l.fg.r == cell.fg.r and l.fg.g == cell.fg.g and l.fg.b == cell.fg.b and
                    l.bg.r == cell.bg.r and l.bg.g == cell.bg.g and l.bg.b == cell.bg.b and
                    l.bold == cell.bold and l.italic == cell.italic and l.under == cell.under else false;
                if (!same) {
                    try w.print("\x1b[0;38;2;{d};{d};{d};48;2;{d};{d};{d}", .{ cell.fg.r, cell.fg.g, cell.fg.b, cell.bg.r, cell.bg.g, cell.bg.b });
                    if (cell.bold) try w.writeAll(";1");
                    if (cell.italic) try w.writeAll(";3");
                    if (cell.under) try w.writeAll(";4");
                    try w.writeAll("m");
                    last = cell;
                }
                var buf: [4]u8 = undefined;
                const len = std.unicode.utf8Encode(cell.cp, &buf) catch 1;
                try w.writeAll(buf[0..len]);
            }
        }
    }
};

/// The palette's colours by their names in palette.sh.
const Palette = struct {
    bg: RGB,
    ink: RGB,
    amber: RGB,
    amberdim: RGB,
    ambersoft: RGB,
    tint0: RGB,
    tint1: RGB,
    tint2: RGB,
    ember: RGB,
    dim: RGB,
    cyan: RGB,
    green: RGB,
    moss: RGB,
    grey: RGB,
    lilac: RGB,
    pink: RGB,
    red: RGB,
    sel: RGB,
    selsoft: RGB,
    sep: RGB,
    violet: RGB,
    white: RGB,
    s0: RGB,
    s2: RGB,
    s3: RGB,
    s4: RGB,

    fn parse(file: []const u8) !Palette {
        var p: Palette = undefined;
        inline for (@typeInfo(Palette).@"struct".field_names) |field| {
            const name = comptime blk: {
                const map = .{ .{ "tint0", "AMBERTINT0" }, .{ "tint1", "AMBERTINT1" }, .{ "tint2", "AMBERTINT2" }, .{ "s0", "SURFACE0" }, .{ "s2", "SURFACE2" }, .{ "s3", "SURFACE3" }, .{ "s4", "SURFACE4" } };
                for (map) |m| if (std.mem.eql(u8, m[0], field)) break :blk m[1];
                var up: [field.len]u8 = undefined;
                _ = std.ascii.upperString(&up, field);
                const final = up;
                break :blk &final;
            };
            @field(p, field) = find(file, name) orelse return error.PaletteIncomplete;
        }
        return p;
    }

    fn find(file: []const u8, name: []const u8) ?RGB {
        var lines = std.mem.tokenizeScalar(u8, file, '\n');
        while (lines.next()) |line| {
            if (!std.mem.startsWith(u8, line, "PALETTE_")) continue;
            const rest = line["PALETTE_".len..];
            if (!std.mem.startsWith(u8, rest, name) or rest.len < name.len + 8 or rest[name.len] != '=') continue;
            const hex = rest[name.len + 2 ..][0..6];
            return .{
                .r = std.fmt.parseInt(u8, hex[0..2], 16) catch return null,
                .g = std.fmt.parseInt(u8, hex[2..4], 16) catch return null,
                .b = std.fmt.parseInt(u8, hex[4..6], 16) catch return null,
            };
        }
        return null;
    }
};

const repo_names = [_][]const u8{ "arena", "babylon", "ficciones", "menard", "tlon" };
/// Nerd Font glyphs, one a repo, in `repo_names`' order.
const repo_glyphs = [_][]const u8{ "\u{f120}", "\u{f1b3}", "\u{f013}", "\u{f0ad}", "\u{f015}" };

fn repoIndex(repo: []const u8) usize {
    for (repo_names, 0..) |name, i| if (std.mem.eql(u8, name, repo)) return i;
    return 0;
}

/// A direction: its roles as colours, and the few shapes it draws differently.
const Skin = struct {
    dir: Direction,
    ground: RGB,
    panel: RGB,
    tile: RGB,
    raised: RGB,
    well: RGB,
    rule: RGB,
    shadow: RGB,
    text: RGB,
    dim: RGB,
    accent: RGB,
    on_accent: RGB,
    you: RGB,
    repo: [5]RGB,
    building: RGB,
    checking: RGB,
    queued: RGB,
    failed: RGB,
    landed: RGB,

    fn of(dir: Direction, p: Palette) Skin {
        return switch (dir) {
            .phosphor => .{
                .dir = dir,
                .ground = p.bg,
                .panel = p.tint0,
                .tile = p.tint1,
                .raised = p.tint2,
                .well = p.bg,
                .rule = p.amberdim,
                .shadow = p.bg,
                .text = p.amber,
                .dim = p.dim,
                .accent = p.amber,
                .on_accent = p.ink,
                .you = p.violet,
                .repo = .{ p.amber, p.ambersoft, p.ember, p.dim, p.sep },
                .building = p.amber,
                .checking = p.ambersoft,
                .queued = p.dim,
                .failed = p.ember,
                .landed = p.amber,
            },
            .workbench => .{
                .dir = dir,
                .ground = p.s0,
                .panel = p.s2,
                .tile = p.s3,
                .raised = p.s4,
                .well = p.bg,
                .rule = p.s4,
                .shadow = p.bg,
                .text = p.grey,
                .dim = p.grey.mix(p.s3, 0.4),
                .accent = p.amber,
                .on_accent = p.ink,
                .you = p.violet,
                .repo = .{ p.amber, p.violet, p.cyan, p.moss, p.pink },
                .building = p.amber,
                .checking = p.cyan,
                .queued = p.grey.mix(p.s3, 0.4),
                .failed = p.red,
                .landed = p.moss,
            },
            .neon => .{
                .dir = dir,
                .ground = p.bg,
                .panel = p.bg,
                .tile = p.s2,
                .raised = p.s4,
                .well = p.s2,
                .rule = p.s4,
                .shadow = p.bg,
                .text = p.white,
                .dim = p.grey.mix(p.bg, 0.3),
                .accent = p.pink,
                .on_accent = p.ink,
                .you = p.pink,
                .repo = .{ p.amber, p.violet, p.cyan, p.moss, p.lilac },
                .building = p.cyan,
                .checking = p.violet,
                .queued = p.grey.mix(p.bg, 0.3),
                .failed = p.red,
                .landed = p.green,
            },
        };
    }

    fn repoInk(s: Skin, repo: []const u8) RGB {
        return s.repo[repoIndex(repo)];
    }

    /// A card's tile in its repo's colour, for the directions that tint them.
    fn tileOf(s: Skin, repo: []const u8, picked: bool) RGB {
        return switch (s.dir) {
            .neon => s.repoInk(repo).mix(s.ground, if (picked) 0.8 else 0.9),
            else => if (picked) s.raised else s.tile,
        };
    }

    fn stateInk(s: Skin, state: []const u8) RGB {
        const eql = std.mem.eql;
        if (eql(u8, state, "building")) return s.building;
        if (eql(u8, state, "verifying") or eql(u8, state, "reviewing") or eql(u8, state, "landing")) return s.checking;
        if (eql(u8, state, "failed") or eql(u8, state, "sent_back")) return s.failed;
        if (eql(u8, state, "landed")) return s.landed;
        return s.queued;
    }
};

fn stateGlyph(state: []const u8) []const u8 {
    const eql = std.mem.eql;
    if (eql(u8, state, "building")) return "\u{f013}";
    if (eql(u8, state, "verifying")) return "\u{f00c}";
    if (eql(u8, state, "reviewing")) return "\u{f06e}";
    if (eql(u8, state, "queued") or eql(u8, state, "waiting")) return "\u{f017}";
    if (eql(u8, state, "failed") or eql(u8, state, "sent_back")) return "\u{f0e2}";
    if (eql(u8, state, "landed")) return "\u{f135}";
    return "\u{f10c}";
}

/// What the frame is drawn from: the board, the moment, and scratch space for words.
const Scene = struct {
    board: *const tickets.Board,
    skin: Skin,
    c: *Canvas,
    now: i64,
    buf: [64 * 1024]u8 = undefined,
    used: usize = 0,

    fn fmt(sc: *Scene, comptime f: []const u8, args: anytype) []const u8 {
        const out = std.fmt.bufPrint(sc.buf[sc.used..], f, args) catch return "";
        sc.used += out.len;
        return out;
    }

    fn ago(sc: *Scene, at: ?[]const u8) []const u8 {
        const then = tickets.epochOf(at) orelse return "";
        const s = sc.now - then;
        if (s < 3600) return sc.fmt("{d}m", .{@divFloor(s, 60)});
        if (s < 86400) return sc.fmt("{d}h", .{@divFloor(s, 3600)});
        return sc.fmt("{d}d", .{@divFloor(s, 86400)});
    }

    fn card(sc: *const Scene, id: u32) ?*const Card {
        for (sc.board.cards()) |*c| if (c.id == id) return c;
        return null;
    }

    fn model(name: ?[]const u8) ?[]const u8 {
        const m = name orelse return null;
        for ([_][]const u8{ "opus", "sonnet", "haiku", "fable" }) |short| if (std.mem.indexOf(u8, m, short) != null) return short;
        return m;
    }

    // ---- the pieces every direction has, each drawn its own way ----

    /// A label as a chip in `fg` (or on `fill`); the cells it took.
    fn chip(sc: *Scene, x: usize, y: usize, label: []const u8, fg: RGB, fill: bool) usize {
        const s = sc.skin;
        const under = sc.c.bgAt(x, y);
        const w = text_mod.cells(label);
        switch (s.dir) {
            .phosphor => {
                // half-block caps: a square-shouldered tag, the retro way
                const bg = if (fill) fg else s.raised;
                const tx = if (fill) s.on_accent else fg;
                sc.c.put(x, y, '▐', .{ .fg = bg, .bg = under });
                _ = sc.c.print(x + 1, y, label, .{ .fg = tx, .bg = bg, .bold = fill }, w);
                sc.c.put(x + 1 + w, y, '▌', .{ .fg = bg, .bg = under });
                return w + 2;
            },
            .workbench => {
                // a bevelled tag: a lead bar in its colour on a raised face
                const bg = if (fill) fg else s.raised;
                const tx = if (fill) s.on_accent else s.text;
                sc.c.put(x, y, '▎', .{ .fg = fg, .bg = bg });
                _ = sc.c.print(x + 1, y, label, .{ .fg = tx, .bg = bg, .bold = fill }, w);
                sc.c.put(x + 1 + w, y, ' ', .{ .fg = tx, .bg = bg });
                return w + 2;
            },
            .neon => {
                // a rounded pill
                const bg = if (fill) fg else fg.mix(under, 0.78);
                const tx = if (fill) s.on_accent else fg;
                sc.c.put(x, y, 0xe0b6, .{ .fg = bg, .bg = under });
                _ = sc.c.print(x + 1, y, label, .{ .fg = tx, .bg = bg, .bold = fill }, w);
                sc.c.put(x + 1 + w, y, 0xe0b4, .{ .fg = bg, .bg = under });
                return w + 2;
            },
        }
    }

    /// A button: its key and label; `primary` is filled. The cells it took.
    fn button(sc: *Scene, x: usize, y: usize, key: []const u8, label: []const u8, primary: bool) usize {
        const s = sc.skin;
        const under = sc.c.bgAt(x, y);
        const words = sc.fmt("{s} {s}", .{ key, label });
        const w = text_mod.cells(words);
        switch (s.dir) {
            .phosphor => {
                const bg = if (primary) s.accent else s.raised;
                const fg = if (primary) s.on_accent else s.text;
                sc.c.put(x, y, if (primary) '▐' else '[', .{ .fg = if (primary) bg else s.dim, .bg = under });
                _ = sc.c.print(x + 1, y, key, .{ .fg = fg, .bg = bg, .bold = true, .under = !primary }, 10);
                _ = sc.c.print(x + 1 + text_mod.cells(key), y, sc.fmt(" {s}", .{label}), .{ .fg = fg, .bg = bg, .bold = primary }, 40);
                sc.c.put(x + 1 + w, y, if (primary) '▌' else ']', .{ .fg = if (primary) bg else s.dim, .bg = under });
                return w + 2;
            },
            .workbench => {
                const bg = if (primary) s.accent else s.raised;
                const fg = if (primary) s.on_accent else s.text;
                _ = sc.c.print(x, y, sc.fmt(" {s} ", .{words}), .{ .fg = fg, .bg = bg, .bold = primary }, w + 2);
                sc.c.put(x, y, ' ', .{ .fg = fg, .bg = bg });
                _ = sc.c.print(x + 1, y, key, .{ .fg = if (primary) fg else s.accent, .bg = bg, .bold = true }, 10);
                // the bevel's shadow: a dark edge under and to the right
                sc.c.put(x + w + 2, y, '▌', .{ .fg = s.shadow, .bg = under });
                for (x + 1..x + w + 3) |xx| sc.c.put(xx, y + 1, '▀', .{ .fg = s.shadow, .bg = sc.c.bgAt(xx, y + 1) });
                return w + 3;
            },
            .neon => {
                const bg = if (primary) s.accent else s.raised;
                const fg = if (primary) s.on_accent else s.text;
                sc.c.put(x, y, 0xe0b6, .{ .fg = bg, .bg = under });
                _ = sc.c.print(x + 1, y, key, .{ .fg = if (primary) fg else s.accent, .bg = bg, .bold = true }, 10);
                _ = sc.c.print(x + 1 + text_mod.cells(key), y, sc.fmt(" {s}", .{label}), .{ .fg = fg, .bg = bg, .bold = primary }, 40);
                sc.c.put(x + 1 + w, y, 0xe0b4, .{ .fg = bg, .bg = under });
                return w + 2;
            },
        }
    }

    /// A progress bar `w` cells wide, `done` of `total`.
    fn bar(sc: *Scene, x: usize, y: usize, w: usize, done: u32, total: u32, ink: RGB) void {
        const s = sc.skin;
        const under = sc.c.bgAt(x, y);
        const eighths: usize = if (total == 0) 0 else @intCast(@as(u64, done) * w * 8 / total);
        switch (s.dir) {
            .phosphor => for (0..w) |i| {
                const full = i * 8 + 8 <= eighths;
                sc.c.put(x + i, y, if (full) '█' else '░', .{ .fg = if (full) ink else s.rule, .bg = under });
            },
            .workbench => {
                const track = s.well;
                for (0..w) |i| {
                    const filled = @min(8, eighths -| i * 8);
                    const parts = [_]u21{ ' ', '▏', '▎', '▍', '▌', '▋', '▊', '▉', '█' };
                    sc.c.put(x + i, y, parts[filled], .{ .fg = ink, .bg = track });
                }
            },
            .neon => {
                const track = ink.mix(under, 0.8);
                sc.c.put(x, y, 0xe0b6, .{ .fg = if (eighths > 0) ink else track, .bg = under });
                for (1..w - 1) |i| {
                    const filled = eighths >= (i + 1) * 8;
                    sc.c.put(x + i, y, ' ', .{ .fg = ink, .bg = if (filled) ink else track });
                }
                sc.c.put(x + w - 1, y, 0xe0b4, .{ .fg = if (eighths >= w * 8) ink else track, .bg = under });
            },
        }
    }

    /// A count as a badge beside a heading.
    fn badge(sc: *Scene, x: usize, y: usize, n: usize, ink: RGB) usize {
        return sc.chip(x, y, sc.fmt("{d}", .{n}), ink, sc.skin.dir != .workbench);
    }

    /// A surface with a heading, as each direction frames one; the first row inside it.
    fn panel(sc: *Scene, x: usize, y: usize, w: usize, h: usize, title: []const u8, count: ?usize, focused: bool) usize {
        const s = sc.skin;
        switch (s.dir) {
            .phosphor => {
                sc.c.fill(x, y, w, h, s.panel);
                sc.c.fill(x, y, w, 1, if (focused) s.accent else s.raised);
                const fg = if (focused) s.on_accent else s.text;
                sc.c.put(x, y, '▚', .{ .fg = fg });
                const n = sc.c.print(x + 2, y, title, .{ .fg = fg, .bold = true }, w - 4);
                if (count) |k| _ = sc.c.print(x + 3 + n, y, sc.fmt("{d}", .{k}), .{ .fg = fg }, 6);
                for (x + w - 6..x + w - 1) |xx| sc.c.put(xx, y, '▒', .{ .fg = if (focused) s.on_accent.mix(s.accent, 0.5) else s.rule });
                return y + 2;
            },
            .workbench => {
                // a window: a title bar, a face, and a shadow to the right and under it
                sc.c.fill(x, y, w, h, s.panel);
                sc.c.fill(x, y, w, 1, if (focused) s.raised else s.tile);
                sc.c.put(x + 1, y, '◆', .{ .fg = if (focused) s.accent else s.dim });
                const n = sc.c.print(x + 3, y, title, .{ .fg = if (focused) s.text else s.dim, .bold = true }, w - 6);
                if (count) |k| _ = sc.badge(x + 4 + n, y, k, s.dim);
                if (focused) for (x + 6 + n + 4..x + w - 4) |xx| sc.c.put(xx, y, '═', .{ .fg = s.accent.mix(s.raised, 0.5) });
                _ = sc.c.print(x + w - 3, y, "▫", .{ .fg = s.dim }, 1);
                for (y + 1..y + h + 1) |yy| sc.c.put(x + w, yy, '▌', .{ .fg = s.shadow, .bg = sc.c.bgAt(x + w, yy) });
                for (x + 1..x + w + 1) |xx| sc.c.put(xx, y + h, '▀', .{ .fg = s.shadow, .bg = sc.c.bgAt(xx, y + h) });
                return y + 2;
            },
            .neon => {
                const n = sc.c.print(x, y, title, .{ .fg = if (focused) s.accent else s.text, .bold = true }, w);
                if (count) |k| _ = sc.chip(x + n + 1, y, sc.fmt("{d}", .{k}), if (focused) s.accent else s.dim, false);
                for (x..x + w) |xx| sc.c.put(xx, y + 1, '▔', .{ .fg = if (focused) s.accent else s.rule });
                return y + 2;
            },
        }
    }

    /// The raised look of a picked thing: an accent bar down its left and, where the
    /// direction has depth, a half-block shadow.
    fn raise(sc: *Scene, x: usize, y: usize, w: usize, h: usize, focused: bool) void {
        const s = sc.skin;
        const lead = if (focused) s.accent else s.dim;
        for (y..y + h) |yy| sc.c.put(x, yy, '▌', .{ .fg = lead });
        switch (s.dir) {
            .neon => {
                // a ring of half blocks in the accent, the tile floating inside it
                const out = sc.c.bgAt(x + w, y);
                for (x..x + w) |xx| {
                    sc.c.put(xx, y -| 1, '▄', .{ .fg = lead, .bg = sc.c.bgAt(xx, y -| 1) });
                    sc.c.put(xx, y + h, '▀', .{ .fg = lead, .bg = sc.c.bgAt(xx, y + h) });
                }
                for (y..y + h) |yy| sc.c.put(x + w, yy, '▐', .{ .fg = lead.mix(out, 0.5), .bg = out });
                for (y..y + h) |yy| sc.c.put(x, yy, '█', .{ .fg = lead });
            },
            else => {
                const out = sc.c.bgAt(x + w, y + h);
                sc.c.put(x + w, y, '▖', .{ .fg = s.shadow, .bg = sc.c.bgAt(x + w, y) });
                for (y + 1..y + h) |yy| sc.c.put(x + w, yy, '▌', .{ .fg = s.shadow, .bg = sc.c.bgAt(x + w, yy) });
                sc.c.put(x, y + h, '▝', .{ .fg = s.shadow, .bg = out });
                for (x + 1..x + w + 1) |xx| sc.c.put(xx, y + h, '▀', .{ .fg = s.shadow, .bg = sc.c.bgAt(xx, y + h) });
            },
        }
    }

    /// `s` wrapped to `w` cells on at most `rows` rows from (`x`, `y`), the last cut with `…`;
    /// the rows taken.
    fn wrap(sc: *Scene, x: usize, y: usize, w: usize, rows: usize, s: []const u8, ink: Ink) usize {
        var rest = s;
        var row: usize = 0;
        while (rest.len > 0 and row < rows) : (row += 1) {
            if (text_mod.cells(rest) <= w) {
                _ = sc.c.print(x, y + row, rest, ink, w);
                return row + 1;
            }
            if (row + 1 == rows) {
                var buf: [256]u8 = undefined;
                _ = sc.c.print(x, y + row, text_mod.cut(&buf, rest, w), ink, w);
                return row + 1;
            }
            const broken = text_mod.breakLine(rest, w);
            _ = sc.c.print(x, y + row, broken.line, ink, w);
            rest = broken.rest;
        }
        return row;
    }

    /// The meta pills of a card: repo, model, and its state or what it waits on.
    fn metaRow(sc: *Scene, x: usize, y: usize, w: usize, cd: *const Card) void {
        const s = sc.skin;
        const repo = cd.repo orelse "";
        var at = x;
        const limit = x + w;
        at += sc.chip(at, y, sc.fmt("{s} {s}", .{ repo_glyphs[repoIndex(repo)], repo }), s.repoInk(repo), false) + 1;
        if (cd.ask != null) {
            at += sc.chip(at, y, "▲ asks you", s.you, true) + 1;
        } else if (cd.stage != null and std.mem.eql(u8, cd.stage.?, "failed")) {
            at += sc.chip(at, y, sc.fmt("{s} sent back", .{stateGlyph("failed")}), s.failed, true) + 1;
        } else if (cd.status == .review) {
            const st = cd.stage orelse "queued";
            at += sc.chip(at, y, sc.fmt("{s} {s} {s}", .{ stateGlyph(st), st, sc.ago(cd.stage_at) }), s.stateInk(st), false) + 1;
        } else if (cd.blocked_by.len > 0) {
            at += sc.chip(at, y, sc.fmt("\u{f0c1} waits #{d}", .{cd.blocked_by[0]}), s.dim, false) + 1;
        }
        if (model(cd.model)) |m| if (at + text_mod.cells(m) + 3 < limit) {
            at += sc.chip(at, y, m, s.dim, false) + 1;
        };
        if (cd.status == .doing and cd.claimed_at != null and at + 6 < limit) {
            _ = sc.c.print(at, y, sc.fmt("\u{f017} {s}", .{sc.ago(cd.claimed_at)}), .{ .fg = s.dim }, limit - at);
        } else if (cd.status == .todo and cd.inserted_at != null and at + 8 < limit) {
            _ = sc.c.print(at, y, sc.fmt("filed {s}", .{sc.ago(cd.inserted_at)}), .{ .fg = s.dim }, limit - at);
        }
    }

    fn priorityDot(sc: *Scene, x: usize, y: usize, cd: *const Card) void {
        const s = sc.skin;
        const high = std.mem.eql(u8, cd.priority, "high");
        const low = std.mem.eql(u8, cd.priority, "low");
        sc.c.put(x, y, if (high) '●' else if (low) '○' else '◉', .{ .fg = if (high) s.failed else s.dim });
    }

    /// One card as a tile: number and title (two rows at most), then its pills. Its height.
    fn cardTile(sc: *Scene, x: usize, y: usize, w: usize, cd: *const Card, picked: bool, focused: bool) usize {
        const s = sc.skin;
        const repo = cd.repo orelse "";
        const bg = s.tileOf(repo, picked);
        const blocked = cd.blocked_by.len > 0;
        const title_fg = if (blocked) s.dim else s.text;
        const inner = w - 4;
        const title = sc.fmt("#{d} {s}", .{ cd.id, cd.title });
        const rows: usize = if (text_mod.cells(title) > inner) 2 else 1;
        const h = rows + 3;
        sc.c.fill(x, y, w, h, bg);
        if (s.dir == .neon and !picked) for (y..y + h) |yy| sc.c.put(x, yy, '▎', .{ .fg = s.repoInk(repo) });
        if (s.dir == .workbench) for (x..x + w) |xx| sc.c.put(xx, y, '▔', .{ .fg = if (picked) s.text.mix(bg, 0.5) else s.raised });
        sc.priorityDot(x + w - 2, y + 1, cd);
        const n = sc.wrap(x + 2, y + 1, inner - 1, rows, title, .{ .fg = title_fg, .bold = true });
        // the number in the accent, over the title's start
        _ = sc.c.print(x + 2, y + 1, sc.fmt("#{d}", .{cd.id}), .{ .fg = if (blocked) s.dim else s.repoInk(repo), .bold = true }, 6);
        sc.metaRow(x + 2, y + 1 + n, inner, cd);
        if (picked) sc.raise(x, y, w, h, focused);
        return h;
    }
};

// ---- the frame around every screen ----

const Layout = struct {
    column: usize = 62,
    top: usize = 2,
    foot: usize = 1,

    fn mainX(_: Layout) usize {
        return 0;
    }
    fn mainW(l: Layout, w: usize) usize {
        return w - l.column - 2;
    }
    fn colX(l: Layout, w: usize) usize {
        return w - l.column - 1;
    }
};

fn titleBar(sc: *Scene) void {
    const s = sc.skin;
    const c = sc.c;
    const b = sc.board;
    const plan = b.plan().?;
    const auto = b.auto().?;
    const needs = b.needsYou().len;
    var landing: usize = 0;
    for (plan.now) |item| landing += @intFromBool(!std.mem.eql(u8, item.state, "building"));
    switch (s.dir) {
        .phosphor => {
            // a menu bar, the old application way: a solid amber strip, the view inverted
            c.fill(0, 0, c.w, 1, s.accent);
            const ink: Ink = .{ .fg = s.on_accent, .bg = s.accent };
            _ = c.print(1, 0, "▚▞ ARENA", .{ .fg = s.on_accent, .bg = s.accent, .bold = true }, 10);
            var x: usize = 12;
            for ([_][]const u8{ "home", "backlog", "sessions" }, 0..) |tab, i| {
                const lit = i == 0;
                const word = sc.fmt(" {s} ", .{tab});
                x += c.print(x, 0, word, if (lit) .{ .fg = s.accent, .bg = s.ground, .bold = true } else ink, 20) + 1;
            }
            const right = sc.fmt("▲ {d} need you │ ◐ auto {d}/{d} │ ◒ landing {d} │ ✓ {d} today │ 05:00 ", .{ needs, auto.working, auto.cap, landing, plan.landed_today.count });
            const rw = text_mod.cells(right);
            _ = c.print(c.w - rw, 0, right, ink, rw);
            const need_at = c.w - rw;
            c.fill(need_at - 1, 0, 15, 1, s.you);
            _ = c.print(need_at, 0, sc.fmt("▲ {d} need you", .{needs}), .{ .fg = s.on_accent, .bg = s.you, .bold = true }, 14);
            for (0..c.w) |xx| c.put(xx, 1, '▀', .{ .fg = s.rule, .bg = s.ground });
        },
        .workbench => {
            // a screen title bar, then a row of tabs joined to the window under them
            c.fill(0, 0, c.w, 1, s.raised);
            _ = c.print(1, 0, "◆ arena", .{ .fg = s.accent, .bg = s.raised, .bold = true }, 10);
            _ = c.print(10, 0, "— home · the plan", .{ .fg = s.dim, .bg = s.raised }, 40);
            const clock = "05:00  ─ ▫ ✕ ";
            _ = c.print(c.w - text_mod.cells(clock), 0, clock, .{ .fg = s.dim, .bg = s.raised }, 20);
            var x: usize = 2;
            for ([_][]const u8{ "home", "backlog" }, 0..) |tab, i| {
                const lit = i == 0;
                const word = sc.fmt("  {s}  ", .{tab});
                const n = text_mod.cells(word);
                c.fill(x, 1, n, 1, if (lit) s.panel else s.tile);
                _ = c.print(x, 1, word, .{ .fg = if (lit) s.text else s.dim, .bold = lit }, n);
                if (lit) for (x..x + n) |xx| c.put(xx, 1, c.cells[1 * c.w + xx].cp, .{ .fg = s.text, .bold = true, .under = false });
                x += n + 1;
            }
            var rx: usize = c.w - 2;
            const items = [_]struct { []const u8, RGB, bool }{
                .{ sc.fmt("✓ {d} today", .{plan.landed_today.count}), s.landed, false },
                .{ sc.fmt("◒ landing {d}", .{landing}), s.checking, false },
                .{ sc.fmt("auto {d}/{d}", .{ auto.working, auto.cap }), s.accent, false },
                .{ sc.fmt("▲ {d} need you", .{needs}), s.you, true },
            };
            for (items) |item| {
                const n = text_mod.cells(item[0]) + 2;
                rx -= n + 1;
                _ = sc.chip(rx, 1, item[0], item[1], item[2]);
            }
            // the auto toggle, a real switch
            rx -= 10;
            _ = c.print(rx, 1, "auto", .{ .fg = s.dim }, 4);
            c.fill(rx + 5, 1, 3, 1, s.accent);
            c.put(rx + 7, 1, '●', .{ .fg = s.on_accent, .bg = s.accent });
        },
        .neon => {
            _ = c.print(1, 0, "arena", .{ .fg = s.accent, .bold = true }, 5);
            var x: usize = 8;
            for ([_][]const u8{ "home", "backlog" }, 0..) |tab, i| {
                const lit = i == 0;
                x += if (lit) sc.chip(x, 0, tab, s.text, true) + 1 else c.print(x + 1, 0, tab, .{ .fg = s.dim }, 10) + 3;
            }
            var rx: usize = c.w - 1;
            const items = [_]struct { []const u8, RGB, bool }{
                .{ sc.fmt("✓ {d}", .{plan.landed_today.count}), s.landed, false },
                .{ sc.fmt("◒ {d}", .{landing}), s.checking, false },
                .{ sc.fmt("auto {d}/{d}", .{ auto.working, auto.cap }), s.building, false },
                .{ sc.fmt("▲ {d} need you", .{needs}), s.you, true },
            };
            for (items) |item| {
                rx -= text_mod.cells(item[0]) + 3;
                _ = sc.chip(rx, 0, item[0], item[1], item[2]);
            }
        },
    }
}

fn footBar(sc: *Scene, screen: Screen) void {
    const s = sc.skin;
    const c = sc.c;
    const y = c.h - 1;
    const keys: []const [2][]const u8 = switch (screen) {
        .home => &.{ .{ "⏎", "go" }, .{ "space", "open" }, .{ "j k", "pick" }, .{ "J K", "reorder next" }, .{ "o", "orch" }, .{ "?", "keys" } },
        .popup => &.{ .{ "1-3", "answer" }, .{ "⏎", "go to its Claude" }, .{ "G", "give" }, .{ "e", "edit" }, .{ "j k", "scroll" }, .{ "q", "close" } },
        .orch => &.{ .{ "1-3", "answer" }, .{ "c", "in words" }, .{ "⏎", "go" }, .{ "x", "no" }, .{ "j k", "pick" }, .{ "i", "tell it" }, .{ "h", "back to the plan" } },
        .alone => &.{ .{ "⏎", "go" }, .{ "1-3", "answer" }, .{ "space", "open" }, .{ "j k", "pick" }, .{ "] [", "next needing you" }, .{ "z", "fold" }, .{ "o", "overview" }, .{ "?", "keys" } },
        .doing => &.{ .{ "⏎", "go" }, .{ "space", "open" }, .{ "H", "hand off" }, .{ "j k", "pick" }, .{ "h l", "window" }, .{ "tab", "planning" }, .{ "/", "find" }, .{ "o", "orchestrator" }, .{ "?", "keys" } },
        .planning => &.{ .{ "space", "open" }, .{ "a", "goal…" }, .{ "w", "next" }, .{ ">", "close" }, .{ "e", "edit" }, .{ "p", "priority" }, .{ "j k", "pick" }, .{ "h l", "window" }, .{ "+", "new" }, .{ "tab", "doing" }, .{ "/", "find" }, .{ "?", "keys" } },
        .into => &.{ .{ "⏎", "move it" }, .{ "j k", "pick" }, .{ "esc", "cancel" } },
    };
    const bg = switch (s.dir) {
        .phosphor => s.raised,
        .workbench => s.raised,
        .neon => s.ground,
    };
    c.fill(0, y, c.w, 1, bg);
    var x: usize = 1;
    x += sc.chip(x, y, "NORMAL", s.accent, true) + 2;
    for (keys) |k| {
        switch (s.dir) {
            .phosphor => {
                x += c.print(x, y, k[0], .{ .fg = s.on_accent, .bg = s.accent, .bold = true }, 8);
                x += c.print(x, y, sc.fmt(" {s}  ", .{k[1]}), .{ .fg = s.text }, 30);
            },
            .workbench => {
                x += c.print(x, y, k[0], .{ .fg = s.accent, .bold = true }, 8);
                x += c.print(x, y, sc.fmt(" {s}", .{k[1]}), .{ .fg = s.text }, 30);
                x += c.print(x, y, "  │  ", .{ .fg = s.dim }, 5);
            },
            .neon => {
                x += sc.chip(x, y, k[0], s.dim, false);
                x += c.print(x, y, sc.fmt(" {s}   ", .{k[1]}), .{ .fg = s.dim }, 30);
            },
        }
    }
}

// ---- the orchestrator's column ----

fn column(sc: *Scene, focused: bool, pick: usize) void {
    const s = sc.skin;
    const c = sc.c;
    const l: Layout = .{};
    const x = l.colX(c.w);
    const w = l.column;
    const y0 = l.top;
    const h = c.h - y0 - l.foot - 1;
    var y = sc.panel(x, y0, w, h, "orchestrator", null, focused);
    const head_y = y0;
    const status = "● working 12s · ctx 34%";
    _ = c.print(x + w - text_mod.cells(status) - 8, head_y, status, .{ .fg = if (s.dir == .phosphor and focused) s.on_accent else s.dim }, 30);
    const ix = x + 2;
    const iw = w - 4;

    // your move
    const needs = sc.board.needsYou();
    _ = c.print(ix, y, "▲ your move", .{ .fg = s.you, .bold = true }, 20);
    _ = sc.badge(ix + 12, y, needs.len, s.you);
    y += 2;
    for (needs, 0..) |need, i| {
        const picked = i == pick;
        const top = y;
        const tile = if (picked) s.raised else s.tile;
        if (std.mem.eql(u8, need.kind, "suggest")) {
            c.fill(ix, y, iw, 1, tile);
            _ = c.print(ix + 2, y, sc.fmt("◆ tell the orchestrator: {s}", .{need.text}), .{ .fg = s.accent, .bold = picked }, iw -| 12);
            _ = c.print(ix + iw -| 8, y, "⏎ type", .{ .fg = s.dim }, 6);
            y += if (s.dir == .workbench) 2 else 1;
            continue;
        }
        const tall: usize = if (std.mem.eql(u8, need.kind, "ask")) 4 else 3;
        c.fill(ix, y, iw, tall, tile);
        const kind_ink = if (std.mem.eql(u8, need.kind, "ask")) s.you else if (std.mem.eql(u8, need.kind, "sent_back")) s.failed else s.accent;
        const kind_word = if (std.mem.eql(u8, need.kind, "ask")) "asks" else if (std.mem.eql(u8, need.kind, "sent_back")) "sent back" else "proposal";
        var at = ix + 2;
        if (need.orch) at += sc.chip(at, y, "◆ orch", s.accent, true) + 1;
        at += sc.chip(at, y, kind_word, kind_ink, true) + 1;
        at += c.print(at, y, sc.fmt("#{d} ", .{need.ticket.?}), .{ .fg = s.repoInk(need.repo), .bold = true }, 6);
        _ = c.print(at, y, need.repo, .{ .fg = s.dim }, 12);
        y += 1;
        const said = if (std.mem.eql(u8, need.kind, "ask")) need.text else if (std.mem.indexOf(u8, need.text, ": ")) |cut| need.text[cut + 2 ..] else need.text;
        y += sc.wrap(ix + 2, y, iw - 4, if (tall == 4) 2 else 1, said, .{ .fg = s.text, .bold = picked });
        var bx = ix + 2;
        for (need.actions, 0..) |action, ai| {
            if (bx + text_mod.cells(action.label) + 6 > ix + iw) break;
            bx += sc.button(bx, y, action.key, action.label, ai == 0 and picked) + 1;
        }
        y += 1;
        if (picked) sc.raise(ix, top, iw, y - top, focused);
        y += if (s.dir == .workbench) 2 else 1;
    }

    // what is moving
    const plan = sc.board.plan().?;
    _ = c.print(ix, y, "◒ landing", .{ .fg = s.checking, .bold = true }, 12);
    var cx = ix + 12;
    for (plan.now) |item| {
        if (std.mem.eql(u8, item.state, "building")) continue;
        cx += sc.chip(cx, y, sc.fmt("#{d} {s}", .{ item.ticket, item.state }), s.stateInk(item.state), false) + 1;
    }
    y += 1;
    _ = c.print(ix, y, "◐ building", .{ .fg = s.building, .bold = true }, 12);
    cx = ix + 12;
    for (plan.now) |item| {
        if (!std.mem.eql(u8, item.state, "building")) continue;
        const stalled = item.stalled != null;
        cx += sc.chip(cx, y, sc.fmt("#{d} {s}", .{ item.ticket, if (stalled) item.stalled.? else sc.ago(item.since) }), if (stalled) s.failed else s.repoInk(item.repo orelse ""), false) + 1;
    }
    y += 1;
    _ = c.print(ix, y, sc.fmt("✓ landed today {d}", .{plan.landed_today.count}), .{ .fg = s.landed, .bold = true }, 30);
    y += 2;

    // its Claude, talking
    for (x + 1..x + w - 1) |xx| c.put(xx, y, '─', .{ .fg = s.rule });
    y += 1;
    const said = [_][]const u8{
        "● #587 is verifying and #591 is in review. #588 has",
        "  been idle 9m with its ticket still doing; I'll look.",
        "",
        "● #760's mockups are up: three directions, each with",
        "  Home, the board, a card and this column. I've put",
        "  the choice in your move, with a recommendation.",
        "",
        "● Next is #761 once #757 frees arena's lane.",
    };
    const talk_end = c.h - l.foot - 4;
    for (said) |line| {
        if (y >= talk_end) break;
        _ = c.print(ix, y, line, .{ .fg = if (line.len > 0 and line[0] == 0xe2) s.text else s.text.mix(s.panel, 0.15) }, iw);
        if (line.len > 2 and std.mem.startsWith(u8, line, "●")) c.put(ix, y, '●', .{ .fg = s.accent });
        y += 1;
    }
    // the prompt, a well to type into
    const py = c.h - l.foot - 3;
    c.fill(ix, py, iw, 1, s.well);
    _ = c.print(ix + 1, py, "❯ tell the orchestrator…", .{ .fg = s.dim, .bg = s.well, .italic = true }, iw - 2);
    _ = c.print(ix + iw - 9, py, "i insert", .{ .fg = s.dim, .bg = s.well }, 8);
}

// ---- Home: the plan ----

fn home(sc: *Scene, focused: bool) void {
    const s = sc.skin;
    const c = sc.c;
    const l: Layout = .{};
    const x0 = l.mainX() + 1;
    const W = l.mainW(c.w) - 1;
    const plan = sc.board.plan().?;
    const goal = plan.goals[0];
    var y = l.top + 1;

    // the focal point: what we are driving towards
    const fh: usize = 6;
    const fbg = switch (s.dir) {
        .phosphor => s.raised,
        .workbench => s.tile,
        .neon => s.accent.mix(s.ground, 0.85),
    };
    c.fill(x0, y, W, fh, fbg);
    if (s.dir == .workbench) {
        for (x0..x0 + W) |xx| c.put(xx, y, '▔', .{ .fg = s.raised });
        for (y + 1..y + fh + 1) |yy| c.put(x0 + W, yy, '▌', .{ .fg = s.shadow, .bg = c.bgAt(x0 + W, yy) });
        for (x0 + 1..x0 + W + 1) |xx| c.put(xx, y + fh, '▀', .{ .fg = s.shadow, .bg = c.bgAt(xx, y + fh) });
    }
    for (y..y + fh) |yy| c.put(x0, yy, '▌', .{ .fg = s.accent });
    _ = c.print(x0 + 3, y + 1, "DRIVING TOWARDS", .{ .fg = s.accent, .bold = true }, 20);
    _ = c.print(x0 + 20, y + 1, sc.fmt("epic #{d} · {s}", .{ goal.epic, goal.doc orelse "" }), .{ .fg = s.dim }, 60);
    _ = c.print(x0 + 3, y + 2, goal.title, .{ .fg = s.text, .bold = true }, W - 50);
    const bw: usize = 40;
    sc.bar(x0 + W - bw - 14, y + 2, bw, goal.landed, goal.total, s.accent);
    _ = c.print(x0 + W - 12, y + 2, sc.fmt("{d}/{d} landed", .{ goal.landed, goal.total }), .{ .fg = s.text, .bold = true }, 12);
    // its steps in flight, as a chain
    var sx = x0 + 3;
    _ = c.print(sx, y + 4, "now", .{ .fg = s.dim }, 4);
    sx += 4;
    for (goal.steps, 0..) |step, i| {
        const card = sc.card(step.ticket);
        const label = sc.fmt("{s} #{d} {s}", .{ stateGlyph(step.state), step.ticket, if (std.mem.eql(u8, step.state, "sent_back")) "sent back" else if (step.waits_on.len > 0) sc.fmt("waits #{d}", .{step.waits_on[0].ticket.?}) else step.state });
        sx += sc.chip(sx, y + 4, label, if (std.mem.eql(u8, step.state, "waiting")) s.dim else s.stateInk(step.state), i == 0) + 1;
        if (card) |cd| if (cd.ask != null) {
            sx += sc.chip(sx, y + 4, "▲ asks you", s.you, true) + 1;
        };
        if (i + 1 < goal.steps.len) sx += c.print(sx, y + 4, "──▶ ", .{ .fg = s.dim }, 4);
    }
    _ = c.print(x0 + W - 20, y + 4, "+ 2 more to file", .{ .fg = s.dim, .italic = true }, 18);
    y += fh + 2;

    // left: now and next; right: goals
    const lw = W * 57 / 100;
    const rx = x0 + lw + 3;
    const rw = W - lw - 3;
    const ly0 = y;

    // now
    var ly = sc.panel(x0, ly0, lw, plan.now.len + 3, "now", plan.now.len, false);
    for (plan.now) |item| {
        const stalled = item.stalled != null;
        const repo = item.repo orelse "";
        const state = item.stage orelse item.state;
        var at = x0 + 2;
        _ = c.print(at, ly, stateGlyph(state), .{ .fg = if (stalled) s.failed else s.stateInk(state) }, 1);
        at += 2;
        _ = c.print(at, ly, sc.fmt("#{d}", .{item.ticket}), .{ .fg = s.repoInk(repo), .bold = true }, 5);
        at += 5;
        _ = c.print(at, ly, repo_glyphs[repoIndex(repo)], .{ .fg = s.repoInk(repo) }, 1);
        at += 2;
        const tail_w: usize = 20;
        _ = c.print(at, ly, item.title, .{ .fg = s.text }, lw - (at - x0) - tail_w - 2);
        const tail = if (stalled) sc.fmt("stalled · {s}", .{item.stalled.?}) else sc.fmt("{s} · {s}", .{ state, sc.ago(item.since) });
        _ = sc.chip(x0 + lw - tail_w - 1, ly, tail, if (stalled) s.failed else s.stateInk(state), stalled);
        ly += 1;
    }

    // next
    ly += 2;
    const ny0 = ly;
    ly = sc.panel(x0, ny0, lw, plan.next.len * 2 + 3, "next", plan.next.len, focused);
    for (plan.next, 0..) |item, i| {
        const picked = i == 0;
        const row_bg = if (picked) s.raised else c.bgAt(x0 + 1, ly);
        if (picked) c.fill(x0 + 1, ly, lw - 2, 2, row_bg);
        var at = x0 + 2;
        _ = c.print(at, ly, sc.fmt("{d}", .{i + 1}), .{ .fg = s.accent, .bold = true }, 2);
        at += 3;
        const repo = item.repo orelse "";
        at += sc.chip(at, ly, sc.fmt("{s} {s}", .{ repo_glyphs[repoIndex(repo)], repo }), s.repoInk(repo), false) + 1;
        const tw = c.print(at, ly, sc.fmt("#{d} {s}", .{ item.ticket, item.title }), .{ .fg = s.text, .bold = true }, lw - (at - x0) - 18);
        _ = tw;
        if (item.waits_on.len > 0) {
            const wo = item.waits_on[0];
            const what = if (wo.ticket) |t| sc.fmt("\u{f0c1} waits #{d}", .{t}) else sc.fmt("\u{f0c1} lane · #{d}", .{wo.until.?});
            _ = sc.chip(x0 + lw - 16, ly, what, s.dim, false);
        } else _ = sc.chip(x0 + lw - 16, ly, "ready", s.landed, false);
        if (item.pinned()) _ = c.print(x0 + lw - 3, ly, "\u{f08d}", .{ .fg = s.accent }, 1);
        _ = c.print(at, ly + 1, item.why, .{ .fg = s.dim, .italic = true }, lw - (at - x0) - 4);
        if (picked and s.dir == .neon) {
            for (ly..ly + 2) |yy| c.put(x0 + 1, yy, '█', .{ .fg = s.accent });
        } else if (picked) sc.raise(x0 + 1, ly, lw - 2, 2, focused);
        ly += 2;
    }

    // goals, as cards
    // not planned, folded to counts by repo
    ly += 2;
    ly = sc.panel(x0, ly, lw, 4, "not planned", plan.not_planned.count, false);
    var npx = x0 + 2;
    var by_repo = plan.not_planned.by_repo.map.iterator();
    while (by_repo.next()) |entry| {
        npx += sc.chip(npx, ly, sc.fmt("{s} {s} {d}", .{ repo_glyphs[repoIndex(entry.key_ptr.*)], entry.key_ptr.*, entry.value_ptr.* }), s.repoInk(entry.key_ptr.*), false) + 1;
    }
    _ = c.print(npx, ly, sc.fmt("· {d} follow-ups", .{plan.not_planned.follow_ups}), .{ .fg = s.dim }, x0 + lw - npx - 1);

    var gy = sc.panel(rx, ly0, rw, (plan.goals.len) * 7 + 1, "goals", plan.goals.len, false);
    for (plan.goals) |g| {
        const gb = if (s.dir == .neon) s.tile else s.tile;
        c.fill(rx + 1, gy, rw - 2, 6, gb);
        const repo = if (sc.card(g.epic)) |cd| cd.repo orelse "" else "";
        if (s.dir == .neon) for (gy..gy + 6) |yy| c.put(rx + 1, yy, '▎', .{ .fg = s.repoInk(repo) });
        _ = c.print(rx + 3, gy, sc.fmt("#{d}", .{g.epic}), .{ .fg = s.repoInk(repo), .bold = true }, 5);
        _ = c.print(rx + 8, gy, g.title, .{ .fg = s.text, .bold = true }, rw - 11);
        const pw = rw - 18;
        sc.bar(rx + 3, gy + 1, pw, g.landed, g.total, s.repoInk(repo));
        _ = c.print(rx + 4 + pw, gy + 1, sc.fmt("{d}/{d}", .{ g.landed, g.total }), .{ .fg = s.text }, 8);
        const pct = g.landed * 100 / g.total;
        _ = c.print(rx + rw - 6, gy + 1, sc.fmt("{d}%", .{pct}), .{ .fg = s.dim }, 4);
        // its next step, and what blocks it
        _ = c.print(rx + 3, gy + 3, "next", .{ .fg = s.dim }, 7);
        _ = c.print(rx + 3, gy + 4, "blocked", .{ .fg = s.dim }, 7);
        if (g.steps.len > 0) {
            const st = g.steps[0];
            const word = if (std.mem.eql(u8, st.state, "sent_back")) "sent back" else st.state;
            _ = sc.chip(rx + 11, gy + 3, sc.fmt("{s} #{d} {s}", .{ stateGlyph(st.state), st.ticket, word }), s.stateInk(st.state), false);
        }
        var blocked = false;
        for (g.steps) |more| {
            if (more.waits_on.len == 0) continue;
            _ = sc.chip(rx + 11, gy + 4, sc.fmt("\u{f0c1} #{d} waits on #{d}", .{ more.ticket, more.waits_on[0].ticket.? }), s.failed, false);
            blocked = true;
            break;
        }
        if (!blocked) _ = c.print(rx + 11, gy + 4, "nothing", .{ .fg = s.dim }, 8);
        gy += 7;
    }

    // landed today, a strip
    const sy = c.h - l.foot - 4;
    c.fill(x0, sy, W, 2, if (s.dir == .neon) s.ground else s.panel);
    for (x0..x0 + W) |xx| c.put(xx, sy, if (s.dir == .phosphor) '▄' else '─', .{ .fg = s.rule, .bg = s.ground });
    var lx = x0 + 1;
    lx += c.print(lx, sy + 1, sc.fmt("✓ landed today {d}", .{plan.landed_today.count}), .{ .fg = s.landed, .bold = true }, 20) + 2;
    for (plan.landed_today.newest) |id| {
        const cd = sc.card(id) orelse continue;
        const repo = cd.repo orelse "";
        lx += c.print(lx, sy + 1, "┄ ", .{ .fg = s.dim }, 2);
        lx += sc.chip(lx, sy + 1, sc.fmt("{s} #{d}", .{ stateGlyph("landed"), id }), s.repoInk(repo), false) + 1;
        lx += c.print(lx, sy + 1, sc.fmt("{s} ", .{sc.ago(cd.closed_at)}), .{ .fg = s.dim }, 6);
    }
    _ = c.print(x0 + W - 12, sy + 1, "⏎ recent", .{ .fg = s.dim }, 12);
}

const popup_pick: u32 = 760;

// ---- a card, whole ----

fn popup(sc: *Scene) void {
    const s = sc.skin;
    const c = sc.c;
    const card = sc.card(popup_pick).?;
    const w: usize = 92;
    const h: usize = 31;
    const x = (c.w - w) / 2;
    const y = (c.h - h) / 2;
    const repo = card.repo orelse "";
    const face = switch (s.dir) {
        .phosphor => s.panel,
        .workbench => s.panel,
        .neon => s.tile,
    };
    c.fill(x, y, w, h, face);
    // its head
    switch (s.dir) {
        .phosphor => {
            c.fill(x, y, w, 1, s.accent);
            _ = c.print(x + 1, y, sc.fmt("▚ #{d} · {s}", .{ card.id, repo }), .{ .fg = s.on_accent, .bold = true }, 30);
            _ = c.print(x + w - 10, y, "[ q ✕ ]", .{ .fg = s.on_accent }, 8);
        },
        .workbench => {
            c.fill(x, y, w, 1, s.raised);
            _ = c.print(x + 1, y, "◆", .{ .fg = s.accent }, 1);
            _ = c.print(x + 3, y, sc.fmt("#{d} — {s}", .{ card.id, repo }), .{ .fg = s.text, .bold = true }, 30);
            for (x + 20..x + w - 6) |xx| c.put(xx, y, '═', .{ .fg = s.accent.mix(s.raised, 0.5) });
            _ = c.print(x + w - 4, y, "✕", .{ .fg = s.dim }, 1);
        },
        .neon => {
            for (x..x + w) |xx| c.put(xx, y, '▀', .{ .fg = s.repoInk(repo), .bg = s.tile });
        },
    }
    var cy = y + 2;
    const ix = x + 3;
    const iw = w - 6;
    _ = sc.chip(ix, cy, sc.fmt("{s} {s}", .{ repo_glyphs[repoIndex(repo)], repo }), s.repoInk(repo), false);
    _ = sc.chip(ix + 11, cy, "● high", s.failed, false);
    _ = sc.chip(ix + 20, cy, sc.fmt("{s} building {s}", .{ stateGlyph("building"), sc.ago(card.claimed_at) }), s.building, false);
    _ = sc.chip(ix + 37, cy, "opus", s.dim, false);
    _ = sc.chip(ix + 44, cy, "epic #326", s.dim, false);
    cy += 2;
    cy += sc.wrap(ix, cy, iw, 3, card.title, .{ .fg = s.text, .bold = true });
    cy += 1;

    // the ask, the part that needs you
    const ask = card.ask.?;
    const ah: usize = 5;
    c.fill(ix, cy, iw, ah, s.you.mix(face, 0.85));
    for (cy..cy + ah) |yy| c.put(ix, yy, '▌', .{ .fg = s.you });
    _ = c.print(ix + 2, cy + 1, "▲ asks you", .{ .fg = s.you, .bold = true }, 12);
    _ = c.print(ix + 14, cy + 1, ask.question, .{ .fg = s.text, .bold = true }, iw - 16);
    var bx = ix + 2;
    for (ask.options, 0..) |opt, i| {
        bx += sc.button(bx, cy + 3, sc.fmt("{d}", .{i + 1}), opt, i == 0) + 2;
    }
    _ = sc.button(bx + 2, cy + 3, "c", "in words", false);
    cy += ah + 1;

    // what is so of it, in two columns of label and value
    const facts = [_][2][]const u8{
        .{ "branch", card.branch orelse "" },
        .{ "held by", sc.fmt("%1280 · t760-visual-redesign · {s}", .{sc.ago(card.claimed_at)}) },
        .{ "filed", sc.fmt("{s} ago", .{sc.ago(card.inserted_at)}) },
        .{ "epic", "#326 The board, redesigned · 13/18" },
        .{ "blocks", "#346 find  ·  #759 hover" },
    };
    for (facts) |f| {
        _ = c.print(ix, cy, f[0], .{ .fg = s.dim }, 10);
        _ = c.print(ix + 11, cy, f[1], .{ .fg = s.text }, iw - 12);
        cy += 1;
    }
    sc.bar(ix + 11 + 37, cy - 2, 20, 13, 18, s.repoInk(repo));
    cy += 1;
    _ = c.print(ix, cy, "its body", .{ .fg = s.dim }, 10);
    cy += 1;
    const body = "Deliverable: a design, not the build. Two or three distinct visual directions, each rendered by arena itself from a fixture board.json at the human's real size, as real screenshots saved under docs/redesign/.";
    cy += sc.wrap(ix, cy, iw, 4, body, .{ .fg = s.text.mix(face, 0.15) });

    // its actions, the first filled
    const ay = y + h - 2;
    bx = ix;
    const acts = [_][2][]const u8{ .{ "⏎", "go to its Claude" }, .{ "G", "give" }, .{ "e", "edit" }, .{ "p", "priority" }, .{ "q", "close" } };
    for (acts, 0..) |a, i| bx += sc.button(bx, ay, a[0], a[1], i == 0) + 2;
    _ = c.print(x + w - 16, ay, "j k scroll", .{ .fg = s.dim }, 12);

    // its depth
    for (y + 1..y + h + 1) |yy| {
        c.put(x + w, yy, '█', .{ .fg = s.shadow });
        c.put(x + w + 1, yy, '▌', .{ .fg = s.shadow, .bg = c.bgAt(x + w + 1, yy) });
    }
    for (x + 2..x + w + 2) |xx| c.put(xx, y + h, '▀', .{ .fg = s.shadow, .bg = c.bgAt(xx, y + h) });
    if (s.dir == .neon) {
        for (y..y + h) |yy| {
            c.put(x - 1, yy, '▐', .{ .fg = s.accent, .bg = c.bgAt(x - 1, yy) });
            c.put(x + w, yy, '▌', .{ .fg = s.accent, .bg = c.bgAt(x + w, yy) });
        }
        for (x..x + w) |xx| c.put(xx, y + h, '▀', .{ .fg = s.accent, .bg = c.bgAt(xx, y + h) });
    }
}

// ---- arena alone: home with no board, from the Claudes' own state ----

const Mark = enum { waiting, stalled, done, working, background, seen };

/// One Claude as arena knows it without a board: its pane's options, set by the state hook.
const Claude = struct {
    mark: Mark,
    session: []const u8,
    window: u8,
    title: []const u8,
    line: []const u8,
    branch: []const u8,
    age: []const u8,
    ctx: ?u8 = null,
    options: []const []const u8 = &.{},
};

const your_move = [_]Claude{
    .{ .mark = .stalled, .session = "menard", .window = 3, .title = "zig test runs through menard's run test", .line = "its turn ended on an API error: 529 overloaded", .branch = "zig-test", .age = "4m", .ctx = 33 },
    .{ .mark = .waiting, .session = "arena", .window = 2, .title = "Visual redesign: a GUI in the TUI, retro", .line = "asks: Which visual direction should the board and Home take?", .branch = "visual-redesign", .age = "6m", .ctx = 61, .options = &.{ "Phosphor", "Workbench", "Neon tiles" } },
    .{ .mark = .waiting, .session = "tlon", .window = 1, .title = "Money: a safe-to-spend-per-day figure", .line = "wants to run: nix flake update", .branch = "safe-to-spend", .age = "2m", .ctx = 18, .options = &.{ "Yes", "Yes, don't ask again", "No" } },
    .{ .mark = .done, .session = "ficciones", .window = 1, .title = "The house soak day", .line = "The soak ran six hours clean; the diff is on the branch.", .branch = "soak-day", .age = "12m", .ctx = 52 },
    .{ .mark = .done, .session = "menard", .window = 2, .title = "outline lists a module's guards", .line = "Added guards to outline, with tests. Committed as 4fe1c2a.", .branch = "outline-guards", .age = "25m", .ctx = 40 },
};

const working = [_]Claude{
    .{ .mark = .working, .session = "arena", .window = 1, .title = "README leads with arena alone", .line = "Edit README.md", .branch = "readme-alone", .age = "3m", .ctx = 22 },
    .{ .mark = .working, .session = "menard", .window = 1, .title = "rename across umbrella apps", .line = "Bash mix test apps/core · 2 subagents", .branch = "umbrella-rename", .age = "18m", .ctx = 47 },
    .{ .mark = .background, .session = "tlon", .window = 2, .title = "garden sensor import", .line = "its shell: mix ecto.migrate", .branch = "sensor-import", .age = "9m", .ctx = 30 },
    .{ .mark = .working, .session = "ficciones", .window = 2, .title = "nixos module for the bar", .line = "Read bar.nix", .branch = "bar-module", .age = "1m", .ctx = 9 },
};

const quiet = [_]Claude{
    .{ .mark = .seen, .session = "arena", .window = 3, .title = "arena crashes with integer overflow in feedRows", .line = "Fixed and tested; committed as 9c1e2b0.", .branch = "feedrows-overflow", .age = "1h", .ctx = 38 },
    .{ .mark = .seen, .session = "tlon", .window = 3, .title = "plant watering schedule", .line = "Here are three ways to schedule it, cheapest first.", .branch = "main", .age = "3h", .ctx = 12 },
    .{ .mark = .seen, .session = "menard", .window = 4, .title = "why does credo flag this pipe", .line = "It's Credo.Check.Readability.SinglePipe; the fix is…", .branch = "main", .age = "1d" },
};

fn markGlyph(m: Mark) []const u8 {
    return switch (m) {
        .waiting => "▲",
        .stalled => "✗",
        .done => "◉",
        .working => "◐",
        .background => "◔",
        .seen => "○",
    };
}

fn markInk(s: Skin, m: Mark) RGB {
    return switch (m) {
        .waiting => s.you,
        .stalled => s.failed,
        .done => s.accent,
        .working => s.building,
        .background, .seen => s.dim,
    };
}

/// The head with no board: what home is, then how many Claudes are in each state.
fn aloneTitle(sc: *Scene) void {
    const s = sc.skin;
    const c = sc.c;
    c.fill(0, 0, c.w, 1, s.raised);
    _ = c.print(1, 0, "◆ arena", .{ .fg = s.accent, .bg = s.raised, .bold = true }, 10);
    _ = c.print(10, 0, "— home · your Claudes", .{ .fg = s.dim, .bg = s.raised }, 40);
    const clock = "05:00  ─ ▫ ✕ ";
    _ = c.print(c.w - text_mod.cells(clock), 0, clock, .{ .fg = s.dim, .bg = s.raised }, 20);
    var waits: usize = 0;
    var stalls: usize = 0;
    var dones: usize = 0;
    for (your_move) |cl| switch (cl.mark) {
        .waiting => waits += 1,
        .stalled => stalls += 1,
        .done => dones += 1,
        else => {},
    };
    var rx: usize = c.w - 2;
    const items = [_]struct { []const u8, RGB, bool }{
        .{ sc.fmt("○ {d} quiet", .{quiet.len}), s.dim, false },
        .{ sc.fmt("◐ {d} working", .{working.len}), s.building, false },
        .{ sc.fmt("◉ {d} done", .{dones}), s.accent, false },
        .{ sc.fmt("✗ {d} stalled", .{stalls}), s.failed, false },
        .{ sc.fmt("▲ {d} need you", .{waits}), s.you, true },
    };
    for (items) |item| {
        const n = text_mod.cells(item[0]) + 2;
        rx -= n + 1;
        _ = sc.chip(rx, 1, item[0], item[1], item[2]);
    }
}

/// One Claude's row: its mark, where it is, what it is about, then on a second row what it
/// does, waits for or last said. The picked one has its options and its buttons on a third.
fn claudeRow(sc: *Scene, x: usize, y: usize, w: usize, cl: Claude, picked: bool) usize {
    const s = sc.skin;
    const c = sc.c;
    const rows: usize = if (picked) 3 else 2;
    if (picked) c.fill(x, y, w, rows, s.raised);
    const dim_row = cl.mark == .seen;
    var at = x + 2;
    _ = c.print(at, y, markGlyph(cl.mark), .{ .fg = markInk(s, cl.mark), .bold = true }, 1);
    at += 2;
    at += sc.chip(at, y, sc.fmt("{s} {s}:{d}", .{ repo_glyphs[repoIndex(cl.session)], cl.session, cl.window }), s.repoInk(cl.session), false) + 1;
    const tail = sc.fmt("{s}", .{cl.branch});
    const tail_w: usize = 34;
    _ = c.print(at, y, cl.title, .{ .fg = if (dim_row) s.dim else s.text, .bold = !dim_row }, x + w - at - tail_w - 1);
    var tx = x + w - tail_w;
    tx += c.print(tx, y, "\u{e725} ", .{ .fg = s.dim }, 2);
    _ = c.print(tx, y, tail, .{ .fg = s.dim }, 18);
    if (cl.ctx) |pct| _ = c.print(x + w - 14, y, sc.fmt("ctx {d}%", .{pct}), .{ .fg = s.dim }, 8);
    _ = c.print(x + w - 5, y, cl.age, .{ .fg = if (cl.mark == .waiting) s.you else s.dim }, 4);
    const line_ink: RGB = switch (cl.mark) {
        .waiting => s.you,
        .stalled => s.failed,
        else => s.dim,
    };
    _ = c.print(x + 6, y + 1, cl.line, .{ .fg = line_ink, .italic = cl.mark == .done or cl.mark == .seen }, w - 10);
    if (picked) {
        var bx = x + 6;
        for (cl.options, 0..) |opt, i| bx += sc.button(bx, y + 2, sc.fmt("{d}", .{i + 1}), opt, false) + 1;
        bx += 1;
        bx += sc.button(bx, y + 2, "⏎", "go", true) + 1;
        _ = sc.button(bx, y + 2, "space", "open", false);
        sc.raise(x, y, w, rows, true);
    }
    return rows;
}

fn aloneHome(sc: *Scene) void {
    const c = sc.c;
    const l: Layout = .{};
    const x0 = l.mainX() + 1;
    const W = l.mainW(c.w) - 1;
    var y = l.top + 1;

    const move_h = 3 + your_move.len * 2 + 3;
    var ry = sc.panel(x0, y, W, move_h, "your move", your_move.len, true);
    for (your_move, 0..) |cl, i| ry += claudeRow(sc, x0 + 1, ry, W - 2, cl, i == 1) + @intFromBool(i == 1);
    y += move_h + 2;

    const work_h = 3 + working.len * 2;
    ry = sc.panel(x0, y, W, work_h, "working", working.len, false);
    for (working) |cl| ry += claudeRow(sc, x0 + 1, ry, W - 2, cl, false);
    y += work_h + 2;

    const quiet_h = c.h - l.foot - 2 - y;
    ry = sc.panel(x0, y, W, quiet_h, "quiet", quiet.len, false);
    for (quiet) |cl| ry += claudeRow(sc, x0 + 1, ry, W - 2, cl, false);
}

/// The picked Claude's pane, live and read-only, where the orchestrator's column is on Plan.
fn peekColumn(sc: *Scene) void {
    const s = sc.skin;
    const c = sc.c;
    const l: Layout = .{};
    const x = l.colX(c.w);
    const w = l.column;
    const y0 = l.top;
    const h = c.h - y0 - l.foot - 1;
    var y = sc.panel(x, y0, w, h, "arena:2 · Visual redesign", null, false);
    _ = c.print(x + w - 22, y0, "▲ waits 6m · ctx 61%", .{ .fg = s.you }, 20);
    const ix = x + 2;
    const iw = w - 4;
    c.fill(x + 1, y, w - 2, h - 3, s.well);
    const pane = [_][]const u8{
        "● Update(docs/redesign/README.md)",
        "  ⎿ Updated with 12 additions",
        "",
        "● The three directions are drawn: each has Home,",
        "  the board, a card's popup and the column, at",
        "  220×51, the size of your Ghostty.",
        "",
        "  Workbench does the most for \"a GUI in the TUI\":",
        "  windows, tabs, bevels, a real switch, and a hue",
        "  a repo. I'd pick it.",
        "",
        "╭──────────────────────────────────────────────────╮",
        "│ Which visual direction should the board and Home │",
        "│ take?                                            │",
        "│                                                  │",
        "│ ❯ 1. Phosphor                                    │",
        "│   2. Workbench                                   │",
        "│   3. Neon tiles                                  │",
        "│   4. Type something                              │",
        "╰──────────────────────────────────────────────────╯",
    };
    y += 1;
    for (pane) |line| {
        const box = std.mem.startsWith(u8, line, "│") or std.mem.startsWith(u8, line, "╭") or std.mem.startsWith(u8, line, "╰");
        _ = c.print(ix, y, line, .{ .fg = if (box) s.you else s.text, .bg = s.well }, iw);
        if (std.mem.startsWith(u8, line, "●")) c.put(ix, y, '●', .{ .fg = s.accent, .bg = s.well });
        y += 1;
    }
    const fy = c.h - l.foot - 3;
    _ = c.print(ix, fy, "live · read-only", .{ .fg = s.dim, .italic = true }, 20);
    var bx = ix + 18;
    bx += sc.button(bx, fy, "⏎", "go to it", true) + 1;
    _ = sc.button(bx, fy, "space", "whole", false);
}

// ---- Doing and Planning: the plan's two screens ----

/// The head of Doing or Planning: both screens' names, the one shown on the accent, then the repo
/// filter and, against the right edge, babylon's state.
fn planHead(sc: *Scene, screen: Screen) void {
    const s = sc.skin;
    const c = sc.c;
    c.fill(0, 0, c.w, 1, s.raised);
    _ = c.print(1, 0, "◆", .{ .fg = s.accent, .bg = s.raised, .bold = true }, 2);
    var x: usize = 3;
    for ([_]Screen{ .doing, .planning }) |name| {
        const word = sc.fmt(" {s} ", .{@tagName(name)});
        const on = name == screen;
        x += c.print(x, 0, word, .{ .fg = if (on) s.on_accent else s.dim, .bg = if (on) s.accent else s.raised, .bold = on }, 12) + 1;
    }
    x += 2;
    x += c.print(x, 0, "every · arena · babylon · tlon · …   / find", .{ .fg = s.dim, .bg = s.raised }, 60);
    const plan = sc.board.plan().?;
    const tail = sc.fmt("◐ auto 4/6   ◆ orch working 12s   ✓ {d} today   ▲ {d}   ≡", .{ plan.landed_today.count, sc.board.needsYou().len });
    _ = c.print(c.w - text_mod.cells(tail) - 1, 0, tail, .{ .fg = s.text, .bg = s.raised }, 80);
}

/// A ticket's row at `x`, `y`: its repo's mark and icon, its number, its title cut to the room the
/// `right` words leave, and the words against the edge.
fn ticketRow(sc: *Scene, x: usize, y: usize, w: usize, id: u32, right: []const u8, ink: RGB, picked: bool) void {
    const s = sc.skin;
    const c = sc.c;
    const cd = sc.card(id);
    const repo = if (cd) |card| card.repo orelse "" else "";
    if (picked) c.fill(x, y, w, 1, s.raised);
    c.put(x, y, '▌', .{ .fg = s.repoInk(repo), .bg = if (picked) s.raised else null });
    _ = c.print(x + 1, y, repo_glyphs[repoIndex(repo)], .{ .fg = s.repoInk(repo), .bg = if (picked) s.raised else null }, 1);
    var at = x + 3;
    at += c.print(at, y, sc.fmt("#{d}", .{id}), .{ .fg = s.repoInk(repo), .bold = true, .bg = if (picked) s.raised else null }, 6) + 1;
    const room = w -| (at - x) -| text_mod.cells(right) -| 3;
    _ = c.print(at, y, if (cd) |card| card.title else "", .{ .fg = s.text, .bg = if (picked) s.raised else null }, room);
    _ = c.print(x + w - text_mod.cells(right) - 1, y, right, .{ .fg = ink, .bg = if (picked) s.raised else null }, text_mod.cells(right));
}

/// Next on both screens: a place, then the same row as the rest.
fn nextWindow(sc: *Scene, x: usize, y: usize, w: usize, h: usize, focused: bool) void {
    const s = sc.skin;
    const plan = sc.board.plan().?;
    var ly = sc.panel(x, y, w, h, "next", plan.next.len, focused);
    for (plan.next, 1..) |item, place| {
        if (ly + 1 >= y + h) break;
        _ = sc.c.print(x + 1, ly, sc.fmt("{d}", .{place}), .{ .fg = s.accent, .bold = true }, 2);
        const waits = item.waits_on.len > 0 and item.waits_on[0].ticket != null;
        ticketRow(sc, x + 3, ly, w - 4, item.ticket, if (waits) sc.fmt("← #{d}", .{item.waits_on[0].ticket.?}) else "ready", if (waits) s.dim else s.landed, false);
        ly += 1;
    }
}

/// Doing: what needs the human and what is moving. Your move, the goal being driven, in flight and
/// next on the left, landed the whole height of the right.
fn doing(sc: *Scene) void {
    const s = sc.skin;
    const c = sc.c;
    const plan = sc.board.plan().?;
    const needs = sc.board.needsYou();
    const w = c.w - 2;
    const foot = c.h - 2;
    var y: usize = 2;

    const move_h = @max(needs.len, 1) + 3;
    var ny = sc.panel(1, y, w, move_h, "your move", needs.len, true);
    for (needs, 0..) |need, i| {
        if (i == 5) break;
        ticketRow(sc, 2, ny, w - 2, need.ticket orelse 0, "asks you", s.you, i == 0);
        ny += 1;
    }
    y += move_h + 2;

    const goal = plan.goals[0];
    c.fill(1, y, w, 1, s.tile);
    _ = c.print(3, y, sc.fmt("◆ towards #{d} {s}", .{ goal.epic, goal.title }), .{ .fg = s.text, .bg = s.tile, .bold = true }, w / 2);
    const pct = goal.landed * 100 / goal.total;
    sc.bar(w - 40, y, 20, goal.landed, goal.total, s.accent);
    _ = c.print(w - 18, y, sc.fmt("{d}/{d}  {d}%", .{ goal.landed, goal.total, pct }), .{ .fg = s.text, .bg = s.tile }, 14);
    y += 2;

    const left = w * 3 / 5;
    const rows = foot - y;
    const flight_h = rows * 6 / 10;
    var fy = sc.panel(1, y, left - 1, flight_h, "in flight", plan.now.len, false);
    for (plan.now) |item| {
        if (fy + 1 >= y + flight_h) break;
        const stalled = item.stalled != null;
        const state = item.stage orelse item.state;
        ticketRow(sc, 2, fy, left - 3, item.ticket, sc.fmt("{s} {s} {s}", .{ stateGlyph(state), if (stalled) "stalled" else state, sc.ago(item.since) }), if (stalled) s.failed else s.stateInk(state), false);
        fy += 1;
    }
    nextWindow(sc, 1, y + flight_h + 1, left - 1, rows - flight_h - 1, false);

    const lx = left + 1;
    var ly = sc.panel(lx, y, w - left, rows, "landed", plan.landed_today.count, false);
    for (plan.landed_today.newest) |id| {
        if (ly + 1 >= y + rows) break;
        const cd = sc.card(id) orelse continue;
        ticketRow(sc, lx + 1, ly, w - left - 2, id, sc.fmt("✓ {s}", .{sc.ago(cd.closed_at)}), s.landed, false);
        ly += 1;
    }
}

/// Planning: where tickets are arranged. Goals with their tickets and no goal on the left, next and
/// the backlog on the right.
fn planning(sc: *Scene) void {
    const s = sc.skin;
    const c = sc.c;
    const plan = sc.board.plan().?;
    const w = c.w - 2;
    const rows = c.h - 4;
    const left = w * 3 / 5;
    const goals_h = rows * 6 / 10;

    var gy = sc.panel(1, 2, left - 1, goals_h, "goals", plan.goals.len, true);
    const gx = 2;
    const gw = left - 3;
    for (plan.goals, 0..) |goal, i| {
        if (gy + 1 >= 2 + goals_h) break;
        const repo = if (sc.card(goal.epic)) |cd| cd.repo orelse "" else "";
        const open = i != 1;
        const row_bg: ?RGB = if (i == 0) s.raised else null;
        if (i == 0) c.fill(gx, gy, gw, 1, s.raised);
        _ = c.print(gx + 1, gy, if (open) "▾" else "▸", .{ .fg = s.dim, .bg = row_bg }, 1);
        var at: usize = gx + 3;
        if (i == 0) at += c.print(at, gy, "◆ ", .{ .fg = s.repoInk(repo), .bg = row_bg }, 2);
        at += c.print(at, gy, sc.fmt("#{d}", .{goal.epic}), .{ .fg = s.repoInk(repo), .bold = true, .bg = row_bg }, 6) + 1;
        const bw: usize = 16;
        const label = sc.fmt("{d}/{d}  {d}%", .{ goal.landed, goal.total, goal.landed * 100 / goal.total });
        const bx = gx + gw - bw - text_mod.cells(label) - 3;
        _ = c.print(at, gy, goal.title, .{ .fg = s.text, .bold = true, .bg = row_bg }, bx -| at -| 12);
        if (i == 0) _ = c.print(bx - 10, gy, "◆ driving", .{ .fg = s.repoInk(repo), .bg = row_bg }, 9);
        sc.bar(bx, gy, bw, goal.landed, goal.total, s.repoInk(repo));
        _ = c.print(bx + bw + 1, gy, label, .{ .fg = s.dim, .bg = row_bg }, 14);
        gy += 1;
        if (!open) continue;
        for (goal.steps) |step| {
            if (gy + 1 >= 2 + goals_h) break;
            const waits = step.waits_on.len > 0 and step.waits_on[0].ticket != null;
            const word = if (waits) sc.fmt("○ ← #{d}", .{step.waits_on[0].ticket.?}) else sc.fmt("{s} {s}", .{ stateGlyph(step.state), step.state });
            ticketRow(sc, gx + 4, gy, gw - 4, step.ticket, word, if (waits) s.dim else s.stateInk(step.state), false);
            gy += 1;
        }
    }

    const no_y = 2 + goals_h + 1;
    var ny = sc.panel(1, no_y, left - 1, rows - goals_h - 1, "no goal", plan.not_planned.count, false);
    var npx: usize = 3;
    var by_repo = plan.not_planned.by_repo.map.iterator();
    while (by_repo.next()) |entry| {
        npx += sc.chip(npx, ny, sc.fmt("{s} {s} {d}", .{ repo_glyphs[repoIndex(entry.key_ptr.*)], entry.key_ptr.*, entry.value_ptr.* }), s.repoInk(entry.key_ptr.*), false) + 1;
    }
    ny += 1;
    var shown: usize = 0;
    for (sc.board.cards()) |card| {
        if (ny + 1 >= no_y + rows - goals_h - 1) break;
        if (card.status != .todo or card.isEpic() or card.epic_id != null) continue;
        const place = for (plan.next, 1..) |item, k| {
            if (item.ticket == card.id) break k;
        } else 0;
        ticketRow(sc, 2, ny, left - 3, card.id, if (place > 0) sc.fmt("next {d}", .{place}) else card.priority, s.dim, false);
        ny += 1;
        shown += 1;
    }

    const rx = left + 1;
    const next_h = rows * 4 / 10;
    nextWindow(sc, rx, 2, w - left, next_h, false);
    var by = sc.panel(rx, 2 + next_h + 1, w - left, rows - next_h - 1, "backlog", sc.board.backlog().len, false);
    for (sc.board.backlog()) |card| {
        if (by + 1 >= 2 + rows) break;
        if (card.isEpic()) continue;
        ticketRow(sc, rx + 1, by, w - left - 2, card.id, "later", s.dim, false);
        by += 1;
    }
}

/// Planning after `a` on a ticket: the middle column asks into which goal, the pick on the
/// first and the ticket's own place marked.
fn into(sc: *Scene) void {
    const s = sc.skin;
    const c = sc.c;
    const plan = sc.board.plan().?;
    planning(sc);
    const w: usize = 58;
    const x = c.w - w - 4;
    var y = sc.panel(x, 3, w, plan.goals.len + 6, "#1058 into which goal?", null, true);
    for (plan.goals, 0..) |goal, i| {
        const bg: ?RGB = if (i == 0) s.raised else null;
        if (i == 0) c.fill(x + 1, y, w - 2, 1, s.raised);
        _ = c.print(x + 2, y, if (i == 0) "❯" else " ", .{ .fg = s.accent, .bg = bg, .bold = true }, 1);
        const repo = if (sc.card(goal.epic)) |cd| cd.repo orelse "" else "";
        var at: usize = x + 4;
        if (i == 0) at += c.print(at, y, "◆ ", .{ .fg = s.repoInk(repo), .bg = bg }, 2);
        at += c.print(at, y, sc.fmt("#{d} ", .{goal.epic}), .{ .fg = s.repoInk(repo), .bg = bg, .bold = true }, 7);
        _ = c.print(at, y, goal.title, .{ .fg = s.text, .bg = bg, .bold = i == 0 }, w - 20);
        const tally = sc.fmt("{d}/{d}", .{ goal.landed, goal.total });
        _ = c.print(x + w - 2 - text_mod.cells(tally), y, tally, .{ .fg = s.dim, .bg = bg }, 8);
        y += 1;
    }
    _ = c.print(x + 4, y, "no goal", .{ .fg = s.text }, 20);
    _ = c.print(x + w - 8, y, "✓ here", .{ .fg = s.dim }, 6);
    y += 2;
    const used = sc.button(x + 2, y, "⏎", "move it", true);
    _ = sc.button(x + 2 + used + 1, y, "esc", "cancel", false);
}

pub fn draw(c: *Canvas, board: *const tickets.Board, p: Palette, dir: Direction, screen: Screen) void {
    var sc: Scene = .{ .board = board, .skin = Skin.of(dir, p), .c = c, .now = tickets.epochOf(now_at).? };
    c.fill(0, 0, c.w, c.h, sc.skin.ground);
    if (screen == .doing or screen == .planning or screen == .into) {
        planHead(&sc, if (screen == .doing) .doing else .planning);
        switch (screen) {
            .doing => doing(&sc),
            .planning => planning(&sc),
            else => into(&sc),
        }
        footBar(&sc, screen);
        return;
    }
    if (screen != .alone) titleBar(&sc);
    switch (screen) {
        .doing, .planning, .into => unreachable,
        .home => {
            home(&sc, true);
            column(&sc, false, 0);
        },
        .orch => {
            home(&sc, false);
            column(&sc, true, 0);
        },
        .alone => {
            aloneHome(&sc);
            aloneTitle(&sc);
            peekColumn(&sc);
        },
        .popup => {
            home(&sc, true);
            column(&sc, false, 0);
            footBar(&sc, screen);
            c.shade(sc.skin.ground, 0.55);
            popup(&sc);
            return;
        },
    }
    footBar(&sc, screen);
}

fn winsize() ?posix.winsize {
    var ws: posix.winsize = undefined;
    if (posix.system.ioctl(posix.STDOUT_FILENO, posix.T.IOCGWINSZ, @intFromPtr(&ws)) != 0) return null;
    if (ws.col == 0 or ws.row == 0) return null;
    return ws;
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const gpa = init.arena.allocator();
    const args = try init.minimal.args.toSlice(gpa);
    if (args.len != 5 and args.len != 7) {
        try std.Io.File.stderr().writeStreamingAll(io, usage);
        std.process.exit(2);
    }
    const dir = std.meta.stringToEnum(Direction, args[1]) orelse return error.UnknownDirection;
    const screen = std.meta.stringToEnum(Screen, args[2]) orelse return error.UnknownScreen;
    const cwd = std.Io.Dir.cwd();
    const board_text = try cwd.readFileAlloc(io, args[3], gpa, .limited(1 << 22));
    var board = try tickets.Board.parse(gpa, board_text);
    defer board.deinit();
    const palette = try Palette.parse(try cwd.readFileAlloc(io, args[4], gpa, .limited(1 << 16)));
    if (args.len == 7) {
        var dims = std.mem.splitScalar(u8, args[5], 'x');
        const cols = try std.fmt.parseInt(usize, dims.first(), 10);
        const rows = try std.fmt.parseInt(usize, dims.next() orelse return error.BadSize, 10);
        var canvas = try Canvas.init(gpa, cols, rows, palette.bg, palette.amber);
        draw(&canvas, &board, palette, dir, screen);
        var page: std.Io.Writer.Allocating = .init(gpa);
        try canvas.writeHtml(&page.writer, palette.bg);
        return cwd.writeFile(io, .{ .sub_path = args[6], .data = page.written() });
    }
    const ws = winsize() orelse posix.winsize{ .col = 220, .row = 51, .xpixel = 0, .ypixel = 0 };
    var canvas = try Canvas.init(gpa, ws.col, ws.row, palette.bg, palette.amber);
    draw(&canvas, &board, palette, dir, screen);
    var out: std.Io.Writer.Allocating = .init(gpa);
    try canvas.write(&out.writer);
    try std.Io.File.stdout().writeStreamingAll(io, out.written());
    var buf: [16]u8 = undefined;
    _ = std.Io.File.stdin().readStreaming(io, &.{&buf}) catch {};
}

test "a canvas cuts what does not fit with an ellipsis" {
    const gpa = std.testing.allocator;
    const black: RGB = .{ .r = 0, .g = 0, .b = 0 };
    var c = try Canvas.init(gpa, 8, 1, black, black);
    defer gpa.free(c.cells);
    try std.testing.expectEqual(@as(usize, 5), c.print(0, 0, "board view", .{ .fg = black }, 5));
    try std.testing.expectEqual(@as(u21, '…'), c.cells[4].cp);
}
