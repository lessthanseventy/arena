const std = @import("std");

pub const gap = 1;

/// Outer width of every column, border included. A lone column takes the whole view; otherwise
/// 0.8 of it, so a neighbour peeks on each side.
pub fn colWidth(view_w: u16, count: usize) u16 {
    if (count <= 1) return view_w;
    return @max(4, view_w * 4 / 5);
}

/// Left edge of column `i` on the strip.
pub fn colX(col_w: u16, i: usize) i32 {
    return @as(i32, @intCast(i)) * (@as(i32, col_w) + gap);
}

/// The strip offset that centres column `focus` of `count` in the view, short of showing empty
/// space past either end of the strip: the first column sits flush left and the last flush right.
pub fn scrollTarget(view_w: u16, col_w: u16, focus: usize, count: usize) i32 {
    const centred = colX(col_w, focus) - @divTrunc(@as(i32, view_w) - col_w, 2);
    const strip = colX(col_w, count) - gap;
    return std.math.clamp(centred, 0, @max(0, strip - view_w));
}

/// One animation frame from `scroll` toward `target`: two fifths of the way, at least one cell.
pub fn step(scroll: i32, target: i32) i32 {
    const delta = target - scroll;
    if (delta == 0) return scroll;
    const move = @divTrunc(delta * 2, 5);
    return scroll + if (move == 0) std.math.sign(delta) else move;
}

test "a lone column fills the view and sits at its origin" {
    try std.testing.expectEqual(@as(u16, 100), colWidth(100, 1));
    try std.testing.expectEqual(@as(i32, 0), scrollTarget(100, 100, 0, 1));
}

test "a middle column is centred with a peek either side; the end ones sit flush" {
    const w = colWidth(100, 3);
    try std.testing.expectEqual(@as(u16, 80), w);
    try std.testing.expectEqual(@as(i32, 0), scrollTarget(100, w, 0, 3));
    try std.testing.expectEqual(@as(i32, 71), scrollTarget(100, w, 1, 3));
    try std.testing.expectEqual(@as(i32, 142), scrollTarget(100, w, 2, 3));
}

test "step always arrives" {
    var s: i32 = 0;
    var frames: usize = 0;
    while (s != 160) : (frames += 1) s = step(s, 160);
    try std.testing.expect(frames < 20);
    try std.testing.expectEqual(@as(i32, -1), step(0, -1));
}

/// Which window's dot sits at cell `cx` of a focused column's bottom edge, if one does: the dots
/// are centred, one cell each with a space between. Null too when the column cannot fit them.
pub fn dotAt(col_w: u16, count: usize, cx: usize) ?usize {
    const span = count * 2 + 1;
    if (count < 2 or span + 4 > col_w) return null;
    const start = (col_w - span) / 2;
    if (cx <= start or cx >= start + span or (cx - start) % 2 == 0) return null;
    return (cx - start) / 2;
}

/// Whether `cx` is in the run of cells the dots and their spacing take up.
pub fn inDots(col_w: u16, count: usize, cx: usize) bool {
    const span = count * 2 + 1;
    if (count < 2 or span + 4 > col_w) return false;
    const start = (col_w - span) / 2;
    return cx >= start and cx < start + span;
}

test "dots are centred, one per window, with spaces between" {
    // 3 windows in 21 cells: span 7 from cell 7, dots at 8, 10 and 12
    try std.testing.expectEqual(@as(?usize, null), dotAt(21, 3, 7));
    try std.testing.expectEqual(@as(?usize, 0), dotAt(21, 3, 8));
    try std.testing.expectEqual(@as(?usize, null), dotAt(21, 3, 9));
    try std.testing.expectEqual(@as(?usize, 2), dotAt(21, 3, 12));
    try std.testing.expect(inDots(21, 3, 7) and inDots(21, 3, 13) and !inDots(21, 3, 14));
    try std.testing.expectEqual(@as(?usize, null), dotAt(21, 1, 10));
    try std.testing.expectEqual(@as(?usize, null), dotAt(8, 3, 4));
}
