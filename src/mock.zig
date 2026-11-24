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

const usage = "usage: arena-mock phosphor|workbench|neon home|board|popup|orch BOARD.json PALETTE.sh [COLSxROWS OUT.html]\n";

/// The moment the fixture is seen at: every age is counted from here.
const now_at = "2026-11-24T05:00:00Z";

pub const Direction = enum { phosphor, workbench, neon };
pub const Screen = enum { home, board, popup, orch };

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
            \\.r span{{flex:0 0 8.073px;height:18.333px;line-height:18.333px;font:14.667px "ComicShannsMono Nerd Font",monospace;
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
            const head = text_mod.clip(rest, w);
            const cut = std.mem.lastIndexOfScalar(u8, head, ' ') orelse head.len;
            if (row + 1 == rows) {
                _ = sc.c.print(x, y + row, rest, ink, w);
                return row + 1;
            }
            _ = sc.c.print(x, y + row, rest[0..cut], ink, w);
            rest = std.mem.trimStart(u8, rest[cut..], " ");
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
        // measure: number + title over two rows
        var probe = sc.*;
        _ = &probe;
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
    rail: usize = 7,
    column: usize = 62,
    top: usize = 2,
    foot: usize = 1,

    fn mainX(l: Layout) usize {
        return l.rail + 1;
    }
    fn mainW(l: Layout, w: usize) usize {
        return w - l.rail - l.column - 3;
    }
    fn colX(l: Layout, w: usize) usize {
        return w - l.column - 1;
    }
};

fn titleBar(sc: *Scene, screen: Screen) void {
    const s = sc.skin;
    const c = sc.c;
    const b = sc.board;
    const plan = b.plan().?;
    const auto = b.auto().?;
    const needs = b.needsYou().len;
    var landing: usize = 0;
    for (plan.now) |item| landing += @intFromBool(!std.mem.eql(u8, item.state, "building"));
    const on_board = screen == .board or screen == .popup;
    switch (s.dir) {
        .phosphor => {
            // a menu bar, the old application way: a solid amber strip, the view inverted
            c.fill(0, 0, c.w, 1, s.accent);
            const ink: Ink = .{ .fg = s.on_accent, .bg = s.accent };
            _ = c.print(1, 0, "▚▞ ARENA", .{ .fg = s.on_accent, .bg = s.accent, .bold = true }, 10);
            var x: usize = 12;
            for ([_][]const u8{ "home", "board", "backlog", "sessions" }, 0..) |tab, i| {
                const lit = (i == 0 and !on_board) or (i == 1 and on_board);
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
            _ = c.print(10, 0, if (on_board) "— the board · every repo" else "— home · the plan", .{ .fg = s.dim, .bg = s.raised }, 40);
            const clock = "05:00  ─ ▫ ✕ ";
            _ = c.print(c.w - text_mod.cells(clock), 0, clock, .{ .fg = s.dim, .bg = s.raised }, 20);
            var x: usize = 2;
            for ([_][]const u8{ "home", "board", "backlog" }, 0..) |tab, i| {
                const lit = (i == 0 and !on_board) or (i == 1 and on_board);
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
            for ([_][]const u8{ "home", "board", "backlog" }, 0..) |tab, i| {
                const lit = (i == 0 and !on_board) or (i == 1 and on_board);
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

fn rail(sc: *Scene, screen: Screen) void {
    const s = sc.skin;
    const c = sc.c;
    const l: Layout = .{};
    const y0 = l.top;
    const h = c.h - y0 - l.foot;
    const bg = switch (s.dir) {
        .phosphor => s.panel,
        .workbench => s.ground,
        .neon => s.ground,
    };
    c.fill(0, y0, l.rail, h, bg);
    if (s.dir == .neon) for (y0..y0 + h) |yy| c.put(l.rail - 1, yy, '▕', .{ .fg = s.rule });
    // home, lit
    const home_bg = if (s.dir == .workbench) s.raised else s.accent;
    c.fill(1, y0 + 1, l.rail - 2, 1, home_bg);
    _ = c.print(2, y0 + 1, if (screen == .board or screen == .popup) " \u{f0db} " else " \u{f015} ", .{ .fg = if (s.dir == .workbench) s.accent else s.on_accent, .bg = home_bg, .bold = true }, 3);
    var y = y0 + 3;
    const sessions = [_]struct { []const u8, []const u8, bool }{
        .{ "arena", "◐◐", true },
        .{ "babylon", "◐", false },
        .{ "menard", "", false },
        .{ "tlon", "◐", false },
    };
    for (sessions) |ses| {
        const ink = s.repoInk(ses[0]);
        _ = c.print(2, y, repo_glyphs[repoIndex(ses[0])], .{ .fg = ink }, 1);
        _ = c.print(4, y, ses[0][0..2], .{ .fg = s.dim }, 2);
        y += 1;
        if (ses[1].len > 0) {
            _ = c.print(2, y, ses[1], .{ .fg = if (ses[2]) s.building else s.dim }, l.rail - 3);
            if (ses[2]) c.put(5, y, '▲', .{ .fg = s.you, .bold = true });
            y += 1;
        }
        y += 1;
    }
    _ = c.print(2, c.h - 3, "+  ≡", .{ .fg = s.dim }, 5);
}

fn footBar(sc: *Scene, screen: Screen) void {
    const s = sc.skin;
    const c = sc.c;
    const y = c.h - 1;
    const keys: []const [2][]const u8 = switch (screen) {
        .home => &.{ .{ "⏎", "go" }, .{ "space", "open" }, .{ "j k", "pick" }, .{ "J K", "reorder next" }, .{ "B", "board" }, .{ "o", "orch" }, .{ "?", "keys" } },
        .board => &.{ .{ "⏎", "go" }, .{ "space", "open" }, .{ "G", "give" }, .{ "e", "edit" }, .{ "p", "priority" }, .{ "/", "find" }, .{ "b", "home" }, .{ "?", "keys" } },
        .popup => &.{ .{ "1-3", "answer" }, .{ "⏎", "go to its Claude" }, .{ "G", "give" }, .{ "e", "edit" }, .{ "j k", "scroll" }, .{ "q", "close" } },
        .orch => &.{ .{ "1-3", "answer" }, .{ "c", "in words" }, .{ "⏎", "go" }, .{ "x", "no" }, .{ "j k", "pick" }, .{ "i", "tell it" }, .{ "h", "back to the plan" } },
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
        const tall: usize = if (std.mem.eql(u8, need.kind, "ask")) 4 else 3;
        c.fill(ix, y, iw, tall, tile);
        const kind_ink = if (std.mem.eql(u8, need.kind, "ask")) s.you else if (std.mem.eql(u8, need.kind, "sent_back")) s.failed else s.accent;
        const kind_word = if (std.mem.eql(u8, need.kind, "ask")) "asks" else if (std.mem.eql(u8, need.kind, "sent_back")) "sent back" else "proposal";
        var at = ix + 2;
        at += sc.chip(at, y, kind_word, kind_ink, true) + 1;
        at += c.print(at, y, sc.fmt("#{d} ", .{need.ticket.?}), .{ .fg = s.repoInk(need.repo), .bold = true }, 6);
        _ = c.print(at, y, need.repo, .{ .fg = s.dim }, 12);
        y += 1;
        const said = if (std.mem.eql(u8, need.kind, "ask")) need.text else if (std.mem.indexOf(u8, need.text, ": ")) |cut| need.text[cut + 2 ..] else need.text;
        y += sc.wrap(ix + 2, y, iw - 4, if (tall == 4) 2 else 1, said, .{ .fg = s.text, .bold = picked });
        if (tall == 3 or picked or i == 0) {
            if (tall == 3) {} else {}
        }
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
    y += 0;
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
        cx += sc.chip(cx, y, sc.fmt("#{d} {s}", .{ item.ticket, if (stalled) item.stalled.? else sc.ago(item.since) }), if (stalled) s.failed else s.repoInk(item.repo), false) + 1;
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
        const state = item.stage orelse item.state;
        var at = x0 + 2;
        _ = c.print(at, ly, stateGlyph(state), .{ .fg = if (stalled) s.failed else s.stateInk(state) }, 1);
        at += 2;
        _ = c.print(at, ly, sc.fmt("#{d}", .{item.ticket}), .{ .fg = s.repoInk(item.repo), .bold = true }, 5);
        at += 5;
        _ = c.print(at, ly, repo_glyphs[repoIndex(item.repo)], .{ .fg = s.repoInk(item.repo) }, 1);
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
        at += sc.chip(at, ly, sc.fmt("{s} {s}", .{ repo_glyphs[repoIndex(item.repo)], item.repo }), s.repoInk(item.repo), false) + 1;
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

// ---- the board ----

const board_pick: u32 = 760;

fn boardView(sc: *Scene, focused: bool) void {
    const s = sc.skin;
    const c = sc.c;
    const l: Layout = .{};
    const x0 = l.mainX() + 1;
    const W = l.mainW(c.w) - 1;
    var y = l.top + 1;

    // epics, as slim bars along the top
    const plan = sc.board.plan().?;
    var ex = x0;
    const ew = (W - 3 * 2) / plan.goals.len;
    for (plan.goals) |g| {
        const repo = if (sc.card(g.epic)) |cd| cd.repo orelse "" else "";
        _ = c.print(ex, y, sc.fmt("#{d} {s}", .{ g.epic, g.title }), .{ .fg = s.dim }, ew - 2);
        _ = c.print(ex, y, sc.fmt("#{d}", .{g.epic}), .{ .fg = s.repoInk(repo), .bold = true }, 5);
        sc.bar(ex, y + 1, ew - 10, g.landed, g.total, s.repoInk(repo));
        _ = c.print(ex + ew - 9, y + 1, sc.fmt("{d}/{d}", .{ g.landed, g.total }), .{ .fg = s.text }, 7);
        ex += ew + 2;
    }
    y += 3;

    // the columns
    const cols = [_]struct { tickets.Status, []const u8, usize }{
        .{ .todo, "todo", 40 },
        .{ .doing, "doing", 33 },
        .{ .review, "review", 27 },
    };
    const strip_h: usize = 3;
    const ch = c.h - y - l.foot - strip_h - 1;
    var cx = x0;
    for (cols, 0..) |col, ci| {
        const cw = if (ci == cols.len - 1) x0 + W - cx else W * col[2] / 100;
        var list: [64]*const Card = undefined;
        const all = sc.board.column(col[0], null, "", &list);
        var n: usize = 0;
        for (list[0..@min(all, list.len)]) |cd| {
            if (!std.mem.eql(u8, cd.kind, "epic")) {
                list[n] = cd;
                n += 1;
            }
        }
        var cy = sc.panel(cx, y, cw - 2, ch, col[1], n, focused and ci == 1);
        const add = if (col[0] == .todo) "+ new" else "";
        if (add.len > 0) _ = c.print(cx + cw - 10, y, add, .{ .fg = if (s.dir == .phosphor) s.text else s.dim, .bg = c.bgAt(cx + cw - 10, y) }, 6);
        for (repo_names) |repo| {
            var k: usize = 0;
            for (list[0..n]) |cd| k += @intFromBool(std.mem.eql(u8, cd.repo orelse "", repo));
            if (k == 0) continue;
            if (cy + 2 >= y + ch) break;
            // a repo's group heading
            const ink = s.repoInk(repo);
            const hn = c.print(cx + 1, cy, sc.fmt("{s} {s}", .{ repo_glyphs[repoIndex(repo)], repo }), .{ .fg = ink, .bold = true }, 20);
            for (cx + 2 + hn..cx + cw - 7) |xx| c.put(xx, cy, '┄', .{ .fg = s.rule });
            _ = c.print(cx + cw - 6, cy, sc.fmt("{d}", .{k}), .{ .fg = s.dim }, 3);
            cy += 1;
            for (list[0..n]) |cd| {
                if (!std.mem.eql(u8, cd.repo orelse "", repo)) continue;
                if (cy + 5 >= y + ch) {
                    _ = c.print(cx + 2, cy, "↓ more", .{ .fg = s.dim }, 8);
                    cy = y + ch;
                    break;
                }
                const picked = cd.id == board_pick;
                cy += sc.cardTile(cx + 1, cy, cw - 5, cd, picked, focused) + 1;
            }
        }
        cx += cw;
    }

    // recent: a thin timeline strip of the last five
    const sy = c.h - l.foot - strip_h - 1;
    var list: [64]*const Card = undefined;
    const done = sc.board.column(.done, null, "", &list);
    for (x0..x0 + W) |xx| c.put(xx, sy + 1, '━', .{ .fg = s.rule });
    _ = c.print(x0, sy, "recent", .{ .fg = s.text, .bold = true }, 7);
    _ = sc.badge(x0 + 7, sy, done, s.dim);
    var tx = x0 + 12;
    const step = (W - 14) / 5;
    for (list[0..@min(5, done)]) |cd| {
        const repo = cd.repo orelse "";
        const landed = cd.stage != null;
        c.put(tx, sy + 1, if (landed) '◆' else '◇', .{ .fg = if (landed) s.landed else s.dim, .bg = c.bgAt(tx, sy + 1) });
        _ = c.print(tx + 2, sy + 1, sc.fmt(" {s} ", .{sc.ago(cd.closed_at)}), .{ .fg = s.dim, .bg = c.bgAt(tx + 2, sy + 1) }, 6);
        const lw = sc.c.print(tx, sy + 2, sc.fmt("#{d} ", .{cd.id}), .{ .fg = s.repoInk(repo), .bold = true }, 6);
        _ = c.print(tx + lw, sy + 2, cd.title, .{ .fg = s.text }, step - lw - 2);
        tx += step;
    }
}

// ---- a card, whole ----

fn popup(sc: *Scene) void {
    const s = sc.skin;
    const c = sc.c;
    const card = sc.card(board_pick).?;
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
    const acts = [_][2][]const u8{ .{ "⏎", "go to its Claude" }, .{ "G", "give" }, .{ "e", "edit" }, .{ "p", "priority" }, .{ ">", "close" } };
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

pub fn draw(c: *Canvas, board: *const tickets.Board, p: Palette, dir: Direction, screen: Screen) void {
    var sc: Scene = .{ .board = board, .skin = Skin.of(dir, p), .c = c, .now = tickets.epochOf(now_at).? };
    c.fill(0, 0, c.w, c.h, sc.skin.ground);
    titleBar(&sc, screen);
    rail(&sc, screen);
    switch (screen) {
        .home => {
            home(&sc, true);
            column(&sc, false, 0);
        },
        .orch => {
            home(&sc, false);
            column(&sc, true, 0);
        },
        .board => {
            boardView(&sc, true);
            column(&sc, false, 0);
        },
        .popup => {
            boardView(&sc, true);
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
