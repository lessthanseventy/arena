//! Workbench's drawing parts: a window, a chip, a button, the switch and a bar, each
//! written as cursor moves and 24-bit colour to a frame. Positions are 0-based cells.
const std = @import("std");
const vt = @import("ghostty-vt");
const color = @import("color.zig");
const theme = @import("theme.zig");
const text_mod = @import("text.zig");
const report = @import("report.zig");
const grab_mod = @import("grab.zig");
const Writer = std.Io.Writer;
const RGB = theme.RGB;
const Roles = theme.Roles;

/// While a window's rows are drawn, where the text they say is recorded for the mouse to select.
pub var tap: ?struct { grab: *grab_mod.Grab, gpa: std.mem.Allocator } = null;

fn paint(w: *Writer, fg: RGB, bg: RGB, bold: bool) !void {
    try w.print("\x1b[0{s};38;2;{d};{d};{d};48;2;{d};{d};{d}m", .{ if (bold) ";1" else "", fg.r, fg.g, fg.b, bg.r, bg.g, bg.b });
}

fn moveTo(w: *Writer, x: usize, y: usize) !void {
    try w.print("\x1b[{d};{d}H", .{ y + 1, x + 1 });
}

fn spaces(w: *Writer, n: usize) !void {
    for (0..n) |_| try w.writeAll(" ");
}

/// `▎label ` on raised, its lead bar in `lead`; filled, `lead` is the face and the label is ink.
/// The cells it took.
pub fn chip(w: *Writer, r: Roles, x: usize, y: usize, label: []const u8, lead: RGB, filled: bool) !usize {
    return chipInk(w, r, x, y, label, lead, if (filled) r.on_accent else r.text, filled);
}

/// `chip`, unfilled, on a pill of `ground`.
pub fn chipAt(w: *Writer, r: Roles, x: usize, y: usize, label: []const u8, lead: RGB, ground: RGB) !usize {
    return chipOn(w, x, y, label, lead, r.text, false, ground);
}

/// A chip whose words are in `words`, as a repo's glyph and number are in its hue.
pub fn chipInk(w: *Writer, r: Roles, x: usize, y: usize, label: []const u8, lead: RGB, words: RGB, filled: bool) !usize {
    return chipOn(w, x, y, label, lead, words, filled, r.raised);
}

/// `chipInk` on a pill of `ground` where it is not filled, for a chip that sits on raised.
pub fn chipOn(w: *Writer, x: usize, y: usize, label: []const u8, lead: RGB, words: RGB, filled: bool, ground: RGB) !usize {
    const face = if (filled) lead else ground;
    try moveTo(w, x, y);
    try paint(w, lead, face, false);
    try w.writeAll("▎");
    try paint(w, words, face, filled);
    try w.print("{s} ", .{label});
    if (tap) |t| try t.grab.note(t.gpa, x + 1, y, label);
    return text_mod.cells(label) + 2;
}

/// `s` at (`x`, `y`) in `fg` on `bg`.
pub fn say(w: *Writer, x: usize, y: usize, s: []const u8, fg: RGB, bg: RGB, bold: bool) !void {
    try moveTo(w, x, y);
    try paint(w, fg, bg, bold);
    try w.writeAll(s);
    if (tap) |t| try t.grab.note(t.gpa, x, y, s);
}

/// `width` cells of `bg` from (`x`, `y`).
pub fn fill(w: *Writer, x: usize, y: usize, width: usize, bg: RGB) !void {
    try moveTo(w, x, y);
    try paint(w, bg, bg, false);
    try spaces(w, width);
}

/// A tile's top row, its bevel's light edge: `width` cells of `▔` in `edge` on `bg`.
pub fn bevel(w: *Writer, x: usize, y: usize, width: usize, edge: RGB, bg: RGB) !void {
    try moveTo(w, x, y);
    try paint(w, edge, bg, false);
    for (0..width) |_| try w.writeAll("▔");
}

/// ` key label ` on raised with the key in amber, and its shadow; the primary one is filled amber
/// with ink. `under` is what the shadow falls on, none for a button on a thing that casts its own.
/// The cells it took, the shadow's included.
pub fn button(w: *Writer, r: Roles, x: usize, y: usize, key: []const u8, label: []const u8, primary: bool, under: ?RGB) !usize {
    const face = if (primary) r.accent else r.raised;
    const words = if (primary) r.on_accent else r.text;
    try moveTo(w, x, y);
    try paint(w, words, face, primary);
    try w.writeAll(" ");
    try paint(w, if (primary) r.on_accent else r.accent, face, true);
    try w.writeAll(key);
    try paint(w, words, face, primary);
    try w.print(" {s} ", .{label});
    const width = text_mod.cells(key) + text_mod.cells(label) + 3;
    const under_ = under orelse return width + 1;
    try paint(w, r.well, under_, false);
    try w.writeAll("▌");
    try moveTo(w, x + 1, y + 1);
    for (0..width) |_| try w.writeAll("▀");
    return width + 1;
}

/// `label ▐ ●▌` on, `label ▐● ▌` off: amber with the knob right, or the well with the knob left.
/// `under` is what the switch's ends sit on. The cells it took.
pub fn toggle(w: *Writer, r: Roles, x: usize, y: usize, label: []const u8, on: bool, under: RGB) !usize {
    const track = if (on) r.accent else r.well;
    const knob = if (on) r.on_accent else r.text;
    try moveTo(w, x, y);
    try paint(w, r.text, under, false);
    try w.print("{s} ", .{label});
    try paint(w, track, under, false);
    try w.writeAll("▐");
    try paint(w, knob, track, false);
    try w.writeAll(if (on) " ●" else "● ");
    try paint(w, track, under, false);
    try w.writeAll("▌");
    return text_mod.cells(label) + 5;
}

/// A progress bar `width` cells wide, `done` of `total` filled in `lead`, on a track in the well.
pub fn bar(w: *Writer, r: Roles, x: usize, y: usize, width: usize, done: u32, total: u32, lead: RGB) !void {
    const eighths: usize = if (total == 0) 0 else @intCast(@as(u64, done) * width * 8 / total);
    const parts = [_][]const u8{ " ", "▏", "▎", "▍", "▌", "▋", "▊", "▉", "█" };
    try moveTo(w, x, y);
    try paint(w, lead, r.well, false);
    for (0..width) |i| try w.writeAll(parts[@min(8, eighths -| i * 8)]);
}

/// A window `width` by `h` at (`x`, `y`) on the ground: a panel boxed in line-drawing cells, its
/// title and count in the top border (`┌─ ◆ title │ N ──┐`). A focused window's border and
/// diamond are amber. The cell after its right edge is the gap to the next window.
pub fn window(w: *Writer, r: Roles, x: usize, y: usize, width: usize, h: usize, title: []const u8, count: ?usize, focused: bool) !void {
    if (width < 6 or h < 2) return;
    const edge = if (focused) r.accent else r.dim;
    try paint(w, r.text, r.panel, false);
    for (y..y + h) |yy| {
        try moveTo(w, x, yy);
        try spaces(w, width);
    }
    var nbuf: [20]u8 = undefined;
    const tally = if (count) |n| std.fmt.bufPrint(&nbuf, " │ {d}", .{n}) catch "" else "";
    var named_buf: [256]u8 = undefined;
    const named = text_mod.cut(&named_buf, title, width -| (7 + text_mod.cells(tally)));
    try moveTo(w, x, y);
    try paint(w, edge, r.panel, false);
    try w.writeAll("┌─ ");
    try paint(w, edge, r.panel, false);
    try w.writeAll("◆ ");
    try paint(w, if (focused) r.text else r.dim, r.panel, true);
    try w.writeAll(named);
    try paint(w, r.dim, r.panel, false);
    try w.writeAll(tally);
    try paint(w, edge, r.panel, false);
    try w.writeAll(" ");
    const used = 6 + text_mod.cells(named) + text_mod.cells(tally);
    for (used..width - 1) |_| try w.writeAll("─");
    try w.writeAll("┐");
    for (y + 1..y + h - 1) |yy| {
        try moveTo(w, x, yy);
        try w.writeAll("│");
        try moveTo(w, x + width - 1, yy);
        try w.writeAll("│");
    }
    try moveTo(w, x, y + h - 1);
    try w.writeAll("└");
    for (0..width - 2) |_| try w.writeAll("─");
    try w.writeAll("┘");
}

/// A title bar `width` cells wide at (`x`, `y`): `◆ name`, and, focused, the bar raised and
/// striped `═══` in half-strength amber to its end; what sits on it is drawn after.
pub fn titleBar(w: *Writer, r: Roles, x: usize, y: usize, width: usize, name: []const u8, focused: bool) !void {
    const face = if (focused) r.raised else r.tile;
    try moveTo(w, x, y);
    try paint(w, r.text, face, false);
    try spaces(w, width);
    try moveTo(w, x + 1, y);
    try paint(w, if (focused) r.accent else r.dim, face, false);
    try w.writeAll("◆ ");
    try paint(w, if (focused) r.text else r.dim, face, true);
    var named_buf: [256]u8 = undefined;
    const named = text_mod.cut(&named_buf, name, width -| 4);
    try w.writeAll(named);
    const from = x + 3 + text_mod.cells(named) + 1;
    if (focused and from < x + width) {
        try moveTo(w, from, y);
        try paint(w, r.accent.mix(r.raised, 0.5), face, false);
        for (from..x + width) |_| try w.writeAll("═");
    }
}

/// A row `width` cells wide on the ground, under a title bar, that tabs are drawn on.
pub fn tabRow(w: *Writer, r: Roles, x: usize, y: usize, width: usize) !void {
    try moveTo(w, x, y);
    try paint(w, r.text, r.ground, false);
    try spaces(w, width);
}

/// A tab with `label` as it reads (padded) at (`x`, `y`): the current one is the panel, so it joins
/// the window below it, and the others are tiles.
pub fn tab(w: *Writer, r: Roles, x: usize, y: usize, label: []const u8, current: bool, quiet: bool) !void {
    try moveTo(w, x, y);
    try paint(w, if (current) r.text else if (quiet) r.queued else r.dim, if (current) r.panel else r.tile, current);
    try w.writeAll(label);
}

/// A button of the title bar with `label` as it reads: raised, in `fg`, or, `filled`, `fg` is the
/// face and the words are ink.
pub fn headButton(w: *Writer, r: Roles, x: usize, y: usize, label: []const u8, fg: RGB, filled: bool) !void {
    try moveTo(w, x, y);
    try paint(w, if (filled) r.on_accent else fg, if (filled) fg else r.raised, filled);
    try w.writeAll(label);
}

pub const unset: RGB = .{ .r = 1, .g = 2, .b = 3 };

pub const Cell = struct { cp: u21, fg: RGB, bg: RGB, bold: bool };

/// The cell at (`x`, `y`) of `frame` drawn on a 120 by 40 terminal; a colour never set is `unset`.
pub fn probe(frame: []const u8, x: usize, y: usize) !Cell {
    const gpa = std.testing.allocator;
    var term: vt.Terminal = try .init(std.testing.io, gpa, .{ .cols = 120, .rows = 40, .max_scrollback_bytes = 0 });
    defer term.deinit(gpa);
    var stream = term.vtStream();
    defer stream.deinit();
    stream.nextSlice(frame);
    var state: vt.RenderState = .empty;
    defer state.deinit(gpa);
    try state.update(gpa, &term);
    const line = state.row_data.items(.cells)[state.viewportStart() + y];
    const style = report.cellStyle(line, x);
    const raw = line.items(.raw)[x];
    const rgb = struct {
        fn of(c: vt.Style.Color) RGB {
            return switch (c.value()) {
                .rgb => |v| .{ .r = v.r, .g = v.g, .b = v.b },
                else => unset,
            };
        }
    };
    return .{
        .cp = if (raw.hasText()) raw.content.codepoint.data else ' ',
        .fg = rgb.of(style.fg_color),
        .bg = rgb.of(style.bg_color),
        .bold = style.flags.bold,
    };
}

const palette =
    \\PALETTE_AMBER=#FFB000
    \\PALETTE_BG=#000000
    \\PALETTE_CYAN=#33C7FF
    \\PALETTE_GREY=#C7C7C7
    \\PALETTE_INK=#0A0A0A
    \\PALETTE_MOSS=#62A562
    \\PALETTE_PINK=#F06FB6
    \\PALETTE_RED=#FF7575
    \\PALETTE_SURFACE0=#0D0D0D
    \\PALETTE_SURFACE2=#141414
    \\PALETTE_SURFACE3=#1A1A1A
    \\PALETTE_SURFACE4=#2A2A2A
    \\PALETTE_VIOLET=#B98AFF
;

pub fn roles() Roles {
    return Roles.parse(palette).?;
}

fn expectCell(frame: []const u8, x: usize, y: usize, cp: u21, fg: RGB, bg: RGB) !void {
    const got = try probe(frame, x, y);
    try std.testing.expectEqual(cp, got.cp);
    try std.testing.expectEqual(fg, got.fg);
    try std.testing.expectEqual(bg, got.bg);
}

test "the roles come from the palette's names, dim stays readable on a tile, and a missing colour is no roles" {
    const r = roles();
    try std.testing.expectEqual(RGB{ .r = 0x0D, .g = 0x0D, .b = 0x0D }, r.ground);
    try std.testing.expectEqual(RGB{ .r = 0x2A, .g = 0x2A, .b = 0x2A }, r.raised);
    try std.testing.expect(!std.meta.eql(r.repo[1], r.you));
    try std.testing.expect(!std.meta.eql(r.repo[1], r.repo[2]));
    for ([_]RGB{ r.ground, r.panel, r.tile, r.raised }) |face| try std.testing.expect(color.contrast(r.repo[1], face) >= color.floor);
    try std.testing.expectEqual(r.repo[0], r.accent);
    try std.testing.expect(color.contrast(r.dim, r.tile) >= color.floor);
    try std.testing.expect(color.contrast(r.dim, r.tile) < color.contrast(r.text, r.tile));
    try std.testing.expectEqual(@as(?Roles, null), Roles.parse("PALETTE_AMBER=#FFB000\n"));
}

test "a window is a box of line-drawing cells with its title and count in the top border" {
    const r = roles();
    var buf: [4096]u8 = undefined;
    var w: Writer = .fixed(&buf);
    try window(&w, r, 10, 3, 30, 6, "todo", 12, false);
    const f = w.buffered();
    try expectCell(f, 10, 3, '┌', r.dim, r.panel);
    try expectCell(f, 13, 3, '◆', r.dim, r.panel);
    try expectCell(f, 15, 3, 't', r.dim, r.panel);
    try expectCell(f, 20, 3, '│', r.dim, r.panel);
    try expectCell(f, 22, 3, '1', r.dim, r.panel);
    try expectCell(f, 30, 3, '─', r.dim, r.panel);
    try expectCell(f, 39, 3, '┐', r.dim, r.panel);
    try expectCell(f, 10, 5, '│', r.dim, r.panel);
    try expectCell(f, 39, 5, '│', r.dim, r.panel);
    try expectCell(f, 12, 5, ' ', r.text, r.panel);
    try expectCell(f, 10, 8, '└', r.dim, r.panel);
    try expectCell(f, 25, 8, '─', r.dim, r.panel);
    try expectCell(f, 39, 8, '┘', r.dim, r.panel);
    try expectCell(f, 40, 4, ' ', unset, unset);
    try expectCell(f, 10, 9, ' ', unset, unset);
}

test "a window's top row is one border from corner to corner with its title in it" {
    const r = roles();
    var buf: [4096]u8 = undefined;
    var w: Writer = .fixed(&buf);
    try window(&w, r, 0, 0, 40, 5, "your move", 2, false);
    const f = w.buffered();
    const row = "┌─ ◆ your move │ 2 ────────────────────┐";
    var it = std.unicode.Utf8View.initUnchecked(row).iterator();
    var x: usize = 0;
    while (it.nextCodepoint()) |cp| : (x += 1) {
        try std.testing.expectEqual(cp, (try probe(f, x, 0)).cp);
        try std.testing.expectEqual(r.panel, (try probe(f, x, 0)).bg);
    }
    try std.testing.expectEqual(@as(usize, 40), x);
}

test "a focused window's border and diamond are amber and its title bright" {
    const r = roles();
    var buf: [4096]u8 = undefined;
    var w: Writer = .fixed(&buf);
    try window(&w, r, 0, 0, 30, 5, "doing", null, true);
    const f = w.buffered();
    try expectCell(f, 0, 0, '┌', r.accent, r.panel);
    try expectCell(f, 3, 0, '◆', r.accent, r.panel);
    try expectCell(f, 5, 0, 'd', r.text, r.panel);
    try expectCell(f, 29, 0, '┐', r.accent, r.panel);
    try expectCell(f, 0, 2, '│', r.accent, r.panel);
    try expectCell(f, 29, 4, '┘', r.accent, r.panel);
}

test "a chip is a lead bar and its words on raised, and a filled one is its colour with ink" {
    const r = roles();
    var buf: [512]u8 = undefined;
    var w: Writer = .fixed(&buf);
    try std.testing.expectEqual(@as(usize, 6), try chip(&w, r, 5, 2, "opus", r.checking, false));
    try std.testing.expectEqual(@as(usize, 6), try chip(&w, r, 5, 4, "asks", r.you, true));
    const f = w.buffered();
    try expectCell(f, 5, 2, '▎', r.checking, r.raised);
    try expectCell(f, 6, 2, 'o', r.text, r.raised);
    try expectCell(f, 10, 2, ' ', r.text, r.raised);
    try expectCell(f, 5, 4, '▎', r.you, r.you);
    try expectCell(f, 6, 4, 'a', r.on_accent, r.you);
    try std.testing.expect((try probe(f, 6, 4)).bold);
}

test "a button has its key in amber, a primary is filled amber, and both cast a shadow" {
    const r = roles();
    var buf: [1024]u8 = undefined;
    var w: Writer = .fixed(&buf);
    try std.testing.expectEqual(@as(usize, 9), try button(&w, r, 2, 1, "g", "give", false, r.tile));
    try std.testing.expectEqual(@as(usize, 10), try button(&w, r, 2, 6, "⏎", "start", true, r.tile));
    const f = w.buffered();
    try expectCell(f, 2, 1, ' ', r.text, r.raised);
    try expectCell(f, 3, 1, 'g', r.accent, r.raised);
    try expectCell(f, 5, 1, 'g', r.text, r.raised);
    try expectCell(f, 9, 1, ' ', r.text, r.raised);
    try expectCell(f, 10, 1, '▌', r.well, r.tile);
    try expectCell(f, 3, 2, '▀', r.well, r.tile);
    try expectCell(f, 3, 6, '⏎', r.on_accent, r.accent);
    try expectCell(f, 5, 6, 's', r.on_accent, r.accent);
    try expectCell(f, 11, 7, '▀', r.well, r.tile);
}

test "the switch is amber with the knob right when on, and the well with it left when off" {
    const r = roles();
    var buf: [512]u8 = undefined;
    var w: Writer = .fixed(&buf);
    try std.testing.expectEqual(@as(usize, 9), try toggle(&w, r, 0, 0, "auto", true, r.tile));
    try std.testing.expectEqual(@as(usize, 9), try toggle(&w, r, 0, 2, "auto", false, r.tile));
    const f = w.buffered();
    try expectCell(f, 0, 0, 'a', r.text, r.tile);
    try expectCell(f, 5, 0, '▐', r.accent, r.tile);
    try expectCell(f, 6, 0, ' ', r.on_accent, r.accent);
    try expectCell(f, 7, 0, '●', r.on_accent, r.accent);
    try expectCell(f, 8, 0, '▌', r.accent, r.tile);
    try expectCell(f, 5, 2, '▐', r.well, r.tile);
    try expectCell(f, 6, 2, '●', r.text, r.well);
    try expectCell(f, 7, 2, ' ', r.text, r.well);
    try expectCell(f, 8, 2, '▌', r.well, r.tile);
}

test "a bar fills its cells left to right in eighths on a track in the well" {
    const r = roles();
    var buf: [512]u8 = undefined;
    var w: Writer = .fixed(&buf);
    try bar(&w, r, 4, 1, 10, 5, 8, r.repo[2]);
    const f = w.buffered();
    try expectCell(f, 4, 1, '█', r.repo[2], r.well);
    try expectCell(f, 9, 1, '█', r.repo[2], r.well);
    try expectCell(f, 10, 1, '▎', r.repo[2], r.well);
    try expectCell(f, 11, 1, ' ', r.repo[2], r.well);
    try expectCell(f, 13, 1, ' ', r.repo[2], r.well);
}

/// A frame drawn on a 120 by 40 terminal, one codepoint a cell, for tests that read where text sits.
pub const Grid = struct {
    cps: [40][120]u21,
    bgs: [40][120]RGB,

    pub fn init(frame: []const u8) !Grid {
        const gpa = std.testing.allocator;
        var term: vt.Terminal = try .init(std.testing.io, gpa, .{ .cols = 120, .rows = 40, .max_scrollback_bytes = 0 });
        defer term.deinit(gpa);
        var stream = term.vtStream();
        defer stream.deinit();
        stream.nextSlice(frame);
        var state: vt.RenderState = .empty;
        defer state.deinit(gpa);
        try state.update(gpa, &term);
        var g: Grid = .{ .cps = undefined, .bgs = undefined };
        for (0..40) |y| {
            const row = state.row_data.items(.cells)[state.viewportStart() + y];
            const cells = row.items(.raw);
            for (0..120) |x| {
                g.cps[y][x] = if (cells[x].hasText()) cells[x].content.codepoint.data else ' ';
                g.bgs[y][x] = switch (report.cellStyle(row, x).bg_color.value()) {
                    .rgb => |v| .{ .r = v.r, .g = v.g, .b = v.b },
                    else => unset,
                };
            }
        }
        return g;
    }

    /// The column of the first `needle` on row `y` in [`from`, `to`), or null.
    pub fn find(g: *const Grid, y: usize, from: usize, to: usize, needle: []const u8) ?usize {
        var at = from;
        while (at < to) : (at += 1) {
            var it = std.unicode.Utf8View.initUnchecked(needle).iterator();
            var x = at;
            const hit = while (it.nextCodepoint()) |cp| : (x += 1) {
                if (x >= to or g.cps[y][x] != cp) break false;
            } else true;
            if (hit) return at;
        }
        return null;
    }

    /// Row `y`, columns [`from`, `to`), as text.
    pub fn line(g: *const Grid, buf: []u8, y: usize, from: usize, to: usize) []const u8 {
        var n: usize = 0;
        for (from..@min(to, 120)) |x| n += std.unicode.utf8Encode(g.cps[y][x], buf[n..]) catch break;
        return buf[0..n];
    }
};
