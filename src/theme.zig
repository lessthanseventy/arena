const std = @import("std");

pub const RGB = @import("color.zig").RGB;

pub const Theme = struct {
    amber: RGB,
    violet: RGB,
    amberdim: RGB,
    emberdim: RGB,
    ink: RGB,
    dim: RGB,

    /// Reads the machine palette's `PALETTE_<NAME>=#RRGGBB` lines; null unless every colour is there.
    pub fn parse(text: []const u8) ?Theme {
        return .{
            .amber = find(text, "AMBER") orelse return null,
            .violet = find(text, "VIOLET") orelse return null,
            .amberdim = find(text, "AMBERDIM") orelse return null,
            .emberdim = find(text, "EMBERDIM") orelse return null,
            .ink = find(text, "INK") orelse return null,
            .dim = find(text, "DIM") orelse return null,
        };
    }

    fn find(text: []const u8, comptime name: []const u8) ?RGB {
        const prefix = "PALETTE_" ++ name ++ "=#";
        var lines = std.mem.tokenizeScalar(u8, text, '\n');
        while (lines.next()) |line| {
            if (!std.mem.startsWith(u8, line, prefix) or line.len < prefix.len + 6) continue;
            const hex = line[prefix.len..][0..6];
            return .{
                .r = std.fmt.parseInt(u8, hex[0..2], 16) catch return null,
                .g = std.fmt.parseInt(u8, hex[2..4], 16) catch return null,
                .b = std.fmt.parseInt(u8, hex[4..6], 16) catch return null,
            };
        }
        return null;
    }
};


/// How far clockwise round a `w` by `h` border the cell at (`x`, `y`) sits, from 0 to 1. A row
/// counts double a column, as a cell is about twice as tall as it is wide.
pub fn around(w: u16, h: u16, x: usize, y: usize) f32 {
    const wf: f32 = @floatFromInt(w - 1);
    const hf: f32 = @floatFromInt((h - 1) * 2);
    const xf: f32 = @floatFromInt(x);
    const yf: f32 = @floatFromInt(y * 2);
    const at = if (y == 0) xf else if (x == w - 1) wf + yf else if (y == h - 1) wf + hf + (wf - xf) else wf + hf + wf + (hf - yf);
    return at / (2 * (wf + hf));
}

/// The border colour at `pos` round the border: `a` fading to `b` and back, turned by `phase`.
pub fn gradient(a: RGB, b: RGB, pos: f32, phase: f32) RGB {
    const t = @mod(pos - phase, 1.0);
    return a.mix(b, 1.0 - @abs(2.0 * t - 1.0));
}

test "parse needs every colour" {
    const text =
        \\# generated
        \\PALETTE_AMBER=#FFB000
        \\PALETTE_AMBERDIM=#7A5500
        \\PALETTE_DIM=#BB9D53
        \\PALETTE_EMBERDIM=#9E3B00
        \\PALETTE_INK=#0A0A0A
        \\PALETTE_VIOLET=#B98AFF
    ;
    const theme = Theme.parse(text).?;
    try std.testing.expectEqual(RGB{ .r = 0xFF, .g = 0xB0, .b = 0x00 }, theme.amber);
    try std.testing.expectEqual(RGB{ .r = 0x7A, .g = 0x55, .b = 0x00 }, theme.amberdim);
    try std.testing.expectEqual(@as(?Theme, null), Theme.parse("PALETTE_AMBER=#FFB000\n"));
}

test "the gradient is seamless and reaches both colours" {
    const a: RGB = .{ .r = 0, .g = 0, .b = 0 };
    const b: RGB = .{ .r = 200, .g = 100, .b = 50 };
    try std.testing.expectEqual(a, gradient(a, b, 0, 0));
    try std.testing.expectEqual(b, gradient(a, b, 0.5, 0));
    try std.testing.expectEqual(b, gradient(a, b, 0.75, 0.25));
    try std.testing.expectEqual(gradient(a, b, 0.001, 0).r, gradient(a, b, 0.999, 0).r);
}

test "around runs clockwise from the top left" {
    try std.testing.expectEqual(@as(f32, 0), around(11, 6, 0, 0));
    try std.testing.expect(around(11, 6, 10, 0) < around(11, 6, 10, 5));
    try std.testing.expect(around(11, 6, 10, 5) < around(11, 6, 0, 5));
    try std.testing.expect(around(11, 6, 0, 5) < around(11, 6, 0, 1));
    try std.testing.expect(around(11, 6, 0, 1) < 1);
}
