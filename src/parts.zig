//! Workbench's drawing parts: a window, its shadow, a chip, a button, the switch and a bar, each
//! written as cursor moves and 24-bit colour to a frame. Positions are 0-based cells.
const std = @import("std");
const vt = @import("ghostty-vt");
const color = @import("color.zig");
const theme = @import("theme.zig");
const text_mod = @import("text.zig");
const report = @import("report.zig");
const Writer = std.Io.Writer;
const RGB = theme.RGB;
const Roles = theme.Roles;

fn paint(w: *Writer, fg: RGB, bg: RGB, bold: bool) !void {
    try w.print("\x1b[0{s};38;2;{d};{d};{d};48;2;{d};{d};{d}m", .{ if (bold) ";1" else "", fg.r, fg.g, fg.b, bg.r, bg.g, bg.b });
}

fn moveTo(w: *Writer, x: usize, y: usize) !void {
    try w.print("\x1b[{d};{d}H", .{ y + 1, x + 1 });
}

fn spaces(w: *Writer, n: usize) !void {
    for (0..n) |_| try w.writeAll(" ");
}

/// The hard one-cell shadow of a `width` by `h` rectangle at (`x`, `y`): `▌` down its right and
/// `▀` under it, in the well's colour on `under`, what lies beside and below it.
pub fn shadow(w: *Writer, r: Roles, x: usize, y: usize, width: usize, h: usize, under: RGB) !void {
    try paint(w, r.well, under, false);
    for (y + 1..y + h + 1) |yy| {
        try moveTo(w, x + width, yy);
        try w.writeAll("▌");
    }
    try moveTo(w, x + 1, y + h);
    for (0..width) |_| try w.writeAll("▀");
}

/// `▎label ` on raised, its lead bar in `lead`; filled, `lead` is the face and the label is ink.
/// The cells it took.
pub fn chip(w: *Writer, r: Roles, x: usize, y: usize, label: []const u8, lead: RGB, filled: bool) !usize {
    const face = if (filled) lead else r.raised;
    try moveTo(w, x, y);
    try paint(w, lead, face, false);
    try w.writeAll("▎");
    try paint(w, if (filled) r.on_accent else r.text, face, filled);
    try w.print("{s} ", .{label});
    return text_mod.cells(label) + 2;
}

/// ` key label ` on raised with the key in amber, and its shadow; the primary one is filled amber
/// with ink. `under` is what the shadow falls on. The cells it took, the shadow's included.
pub fn button(w: *Writer, r: Roles, x: usize, y: usize, key: []const u8, label: []const u8, primary: bool, under: RGB) !usize {
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
    try paint(w, r.well, under, false);
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

/// A window `width` by `h` at (`x`, `y`) on the ground: its face, a title bar (`◆ name`, a count
/// badge, `▫`) and its shadow. A focused bar is raised and striped `═══` in half-strength amber.
pub fn window(w: *Writer, r: Roles, x: usize, y: usize, width: usize, h: usize, title: []const u8, count: ?usize, focused: bool) !void {
    const bar_bg = if (focused) r.raised else r.tile;
    try paint(w, r.text, r.panel, false);
    for (y + 1..y + h) |yy| {
        try moveTo(w, x, yy);
        try spaces(w, width);
    }
    try moveTo(w, x, y);
    try paint(w, r.text, bar_bg, false);
    try spaces(w, width);
    try moveTo(w, x + 1, y);
    try paint(w, if (focused) r.accent else r.dim, bar_bg, false);
    try w.writeAll("◆ ");
    const named = text_mod.clip(title, width -| 8);
    try paint(w, if (focused) r.text else r.dim, bar_bg, true);
    try w.writeAll(named);
    var end = x + 3 + text_mod.cells(named);
    if (count) |n| {
        var buf: [20]u8 = undefined;
        end += 1;
        end += try chip(w, r, end, y, std.fmt.bufPrint(&buf, "{d}", .{n}) catch "", r.dim, false);
    }
    if (focused and end + 1 < x + width -| 4) {
        try moveTo(w, end + 1, y);
        try paint(w, r.accent.mix(r.raised, 0.5), bar_bg, false);
        for (end + 1..x + width - 4) |_| try w.writeAll("═");
    }
    try moveTo(w, x + width - 3, y);
    try paint(w, r.dim, bar_bg, false);
    try w.writeAll("▫");
    try shadow(w, r, x, y, width, h, r.ground);
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
    const named = text_mod.clip(name, width -| 4);
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

/// The cell at (`x`, `y`) of `frame` drawn on an 80 by 24 terminal; a colour never set is `unset`.
pub fn probe(frame: []const u8, x: usize, y: usize) !Cell {
    const gpa = std.testing.allocator;
    var term: vt.Terminal = try .init(std.testing.io, gpa, .{ .cols = 80, .rows = 24, .max_scrollback_bytes = 0 });
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
    try std.testing.expectEqual(r.repo[1], r.you);
    try std.testing.expectEqual(r.repo[0], r.accent);
    try std.testing.expect(color.contrast(r.dim, r.tile) >= color.floor);
    try std.testing.expect(color.contrast(r.dim, r.tile) < color.contrast(r.text, r.tile));
    try std.testing.expectEqual(@as(?Roles, null), Roles.parse("PALETTE_AMBER=#FFB000\n"));
}

test "a window is a face, a title bar with its name and count, and a shadow in the well" {
    const r = roles();
    var buf: [4096]u8 = undefined;
    var w: Writer = .fixed(&buf);
    try window(&w, r, 10, 3, 30, 6, "todo", 12, false);
    const f = w.buffered();
    try expectCell(f, 10, 3, ' ', r.text, r.tile);
    try expectCell(f, 11, 3, '◆', r.dim, r.tile);
    try expectCell(f, 13, 3, 't', r.dim, r.tile);
    try expectCell(f, 18, 3, '▎', r.dim, r.raised);
    try expectCell(f, 19, 3, '1', r.text, r.raised);
    try expectCell(f, 37, 3, '▫', r.dim, r.tile);
    try expectCell(f, 12, 5, ' ', r.text, r.panel);
    try expectCell(f, 40, 4, '▌', r.well, r.ground);
    try expectCell(f, 40, 9, '▀', r.well, r.ground);
    try expectCell(f, 11, 9, '▀', r.well, r.ground);
    try expectCell(f, 10, 9, ' ', unset, unset);
}

test "a focused window has a raised bar striped in half amber" {
    const r = roles();
    var buf: [4096]u8 = undefined;
    var w: Writer = .fixed(&buf);
    try window(&w, r, 0, 0, 30, 5, "doing", null, true);
    const f = w.buffered();
    try expectCell(f, 1, 0, '◆', r.accent, r.raised);
    try expectCell(f, 3, 0, 'd', r.text, r.raised);
    try expectCell(f, 12, 0, '═', r.accent.mix(r.raised, 0.5), r.raised);
    try expectCell(f, 25, 0, '═', r.accent.mix(r.raised, 0.5), r.raised);
    try expectCell(f, 27, 0, '▫', r.dim, r.raised);
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
