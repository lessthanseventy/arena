const std = @import("std");

pub const RGB = struct {
    r: u8,
    g: u8,
    b: u8,

    pub fn mix(a: RGB, b: RGB, t: f32) RGB {
        return .{ .r = lerp(a.r, b.r, t), .g = lerp(a.g, b.g, t), .b = lerp(a.b, b.b, t) };
    }

    fn lerp(a: u8, b: u8, t: f32) u8 {
        const af: f32 = @floatFromInt(a);
        const bf: f32 = @floatFromInt(b);
        return @intFromFloat(@round(af + (bf - af) * t));
    }

    fn luminance(c: RGB) f32 {
        return 0.2126 * linear(c.r) + 0.7152 * linear(c.g) + 0.0722 * linear(c.b);
    }

    fn linear(v: u8) f32 {
        const s = @as(f32, @floatFromInt(v)) / 255.0;
        return if (s <= 0.04045) s / 12.92 else std.math.pow(f32, (s + 0.055) / 1.055, 2.4);
    }
};

/// The WCAG contrast ratio of two colours, from 1 to 21.
pub fn contrast(a: RGB, b: RGB) f32 {
    const la = a.luminance();
    const lb = b.luminance();
    return (@max(la, lb) + 0.05) / (@min(la, lb) + 0.05);
}

/// What an unfocused window's text may fall to against its background. A terminal told to keep a
/// minimum contrast repaints anything under its floor in white or black, so dimming stops here.
pub const floor = 4.5;
const dim_by = 0.45;

/// `fg` moved toward `bg` for an unfocused window, as far as `dim_by` or until the contrast
/// floor, whichever comes first. A colour already under the floor is left as it is.
pub fn dimFg(fg: RGB, bg: RGB) RGB {
    if (contrast(fg, bg) <= floor) return fg;
    var t: f32 = dim_by;
    while (t > 0.01) : (t -= 0.05) {
        const dimmed = fg.mix(bg, t);
        if (contrast(dimmed, bg) >= floor) return dimmed;
    }
    return fg;
}

/// A cell background moved toward the terminal's own for an unfocused window.
pub fn dimBg(bg: RGB, ground: RGB) RGB {
    return bg.mix(ground, dim_by);
}

/// The terminal's colours as arena knows them: xterm's defaults until the terminal answers.
pub const Palette = struct {
    colors: [256]RGB = defaults,
    fg: RGB = .{ .r = 0xe5, .g = 0xe5, .b = 0xe5 },
    bg: RGB = .{ .r = 0, .g = 0, .b = 0 },

    const defaults: [256]RGB = blk: {
        var all: [256]RGB = undefined;
        const base = [16][3]u8{
            .{ 0, 0, 0 },       .{ 205, 0, 0 },   .{ 0, 205, 0 },   .{ 205, 205, 0 },
            .{ 0, 0, 238 },     .{ 205, 0, 205 }, .{ 0, 205, 205 }, .{ 229, 229, 229 },
            .{ 127, 127, 127 }, .{ 255, 0, 0 },   .{ 0, 255, 0 },   .{ 255, 255, 0 },
            .{ 92, 92, 255 },   .{ 255, 0, 255 }, .{ 0, 255, 255 }, .{ 255, 255, 255 },
        };
        for (base, 0..) |c, i| all[i] = .{ .r = c[0], .g = c[1], .b = c[2] };
        const steps = [6]u8{ 0, 95, 135, 175, 215, 255 };
        for (0..216) |i| all[16 + i] = .{ .r = steps[i / 36], .g = steps[(i / 6) % 6], .b = steps[i % 6] };
        for (0..24) |i| {
            const v: u8 = @intCast(8 + i * 10);
            all[232 + i] = .{ .r = v, .g = v, .b = v };
        }
        break :blk all;
    };

    /// What to send a terminal to be told its foreground, background and first 16 colours.
    pub const query = blk: {
        var text: []const u8 = "\x1b]10;?\x1b\\\x1b]11;?\x1b\\";
        for (0..16) |i| text = text ++ std.fmt.comptimePrint("\x1b]4;{d};?\x1b\\", .{i});
        break :blk text;
    };

    /// Takes one answer to `query`, the text between `ESC ]` and its terminator:
    /// `4;N;rgb:RRRR/GGGG/BBBB`, or `10;rgb:…` and `11;rgb:…` for foreground and background.
    pub fn answer(p: *Palette, body: []const u8) void {
        var fields = std.mem.splitScalar(u8, body, ';');
        const kind = std.fmt.parseInt(u8, fields.next() orelse return, 10) catch return;
        const slot: *RGB = switch (kind) {
            10 => &p.fg,
            11 => &p.bg,
            4 => &p.colors[std.fmt.parseInt(u8, fields.next() orelse return, 10) catch return],
            else => return,
        };
        const spec = fields.next() orelse return;
        if (!std.mem.startsWith(u8, spec, "rgb:")) return;
        var parts = std.mem.splitScalar(u8, spec[4..], '/');
        slot.* = .{
            .r = channel(parts.next() orelse return) orelse return,
            .g = channel(parts.next() orelse return) orelse return,
            .b = channel(parts.next() orelse return) orelse return,
        };
    }

    /// One to four hex digits, scaled to a byte.
    fn channel(hex: []const u8) ?u8 {
        if (hex.len == 0 or hex.len > 4) return null;
        const v = std.fmt.parseInt(u32, hex, 16) catch return null;
        const max = (@as(u32, 1) << @intCast(hex.len * 4)) - 1;
        return @intCast((v * 255 + max / 2) / max);
    }
};

test "contrast runs from 1 to 21" {
    const black: RGB = .{ .r = 0, .g = 0, .b = 0 };
    const white: RGB = .{ .r = 255, .g = 255, .b = 255 };
    try std.testing.expectApproxEqAbs(@as(f32, 21), contrast(black, white), 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 1), contrast(white, white), 0.01);
}

test "dimming darkens but never under the floor" {
    const black: RGB = .{ .r = 0, .g = 0, .b = 0 };
    const amber: RGB = .{ .r = 0xFF, .g = 0xB0, .b = 0x00 };
    const pink: RGB = .{ .r = 0xF0, .g = 0x6F, .b = 0xB6 };
    for ([_]RGB{ amber, pink }) |c| {
        const dimmed = dimFg(c, black);
        try std.testing.expect(contrast(dimmed, black) >= floor);
        try std.testing.expect(contrast(dimmed, black) < contrast(c, black));
    }
    const murky: RGB = .{ .r = 0x60, .g = 0x30, .b = 0x30 };
    try std.testing.expectEqual(murky, dimFg(murky, black));
}

test "the palette takes a terminal's answers and ignores the rest" {
    var p: Palette = .{};
    p.answer("4;5;rgb:f0f0/6f6f/b6b6");
    p.answer("11;rgb:0a/0a/0a");
    p.answer("10;rgb:ffff/b0b0/0000");
    p.answer("4;300;rgb:00/00/00");
    p.answer("52;c;aGk=");
    try std.testing.expectEqual(RGB{ .r = 0xF0, .g = 0x6F, .b = 0xB6 }, p.colors[5]);
    try std.testing.expectEqual(RGB{ .r = 0x0A, .g = 0x0A, .b = 0x0A }, p.bg);
    try std.testing.expectEqual(RGB{ .r = 0xFF, .g = 0xB0, .b = 0x00 }, p.fg);
    try std.testing.expectEqual(RGB{ .r = 95, .g = 135, .b = 175 }, p.colors[67]);
    try std.testing.expectEqual(RGB{ .r = 8, .g = 8, .b = 8 }, p.colors[232]);
}
