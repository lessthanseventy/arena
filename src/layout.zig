const std = @import("std");

pub const gap = 1;

/// Outer width of every column, border included. A lone column takes the whole view; otherwise
/// 0.8 of it, so a neighbour peeks on each side.
pub fn colWidth(view_w: u16, count: usize) u16 {
    if (count <= 1) return view_w;
    return @max(4, view_w * 4 / 5);
}

/// Outer width of a column given `share` hundredths of the view, to the nearest cell.
pub fn shareWidth(view_w: u16, share: u8) u16 {
    return @intCast(@max(4, (@as(u32, view_w) * share + 50) / 100));
}

/// The strip offset that centres the column `col_w` wide at `x` of a strip `strip` wide, short
/// of showing empty space past either end of it: the first column sits flush left and the last
/// flush right.
pub fn scrollTarget(view_w: u16, x: i32, col_w: u16, strip: i32) i32 {
    const centred = x - @divTrunc(@as(i32, view_w) - col_w, 2);
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
    try std.testing.expectEqual(@as(i32, 0), scrollTarget(100, 0, 100, 100));
}

test "a middle column is centred with a peek either side; the end ones sit flush" {
    const w = colWidth(100, 3);
    try std.testing.expectEqual(@as(u16, 80), w);
    try std.testing.expectEqual(@as(i32, 0), scrollTarget(100, 0, w, 242));
    try std.testing.expectEqual(@as(i32, 71), scrollTarget(100, 81, w, 242));
    try std.testing.expectEqual(@as(i32, 142), scrollTarget(100, 162, w, 242));
}

test "a share is hundredths of the view, and never too thin to draw" {
    try std.testing.expectEqual(@as(u16, 60), shareWidth(85, 70));
    try std.testing.expectEqual(@as(u16, 4), shareWidth(10, 20));
}

test "step always arrives" {
    var s: i32 = 0;
    var frames: usize = 0;
    while (s != 160) : (frames += 1) s = step(s, 160);
    try std.testing.expect(frames < 20);
    try std.testing.expectEqual(@as(i32, -1), step(0, -1));
}

/// Which window's dot sits at cell `cx` of the row under a strip `view_w` wide, if one does: the
/// dots are centred, one cell each with a space between. Null too when the row cannot fit them.
pub fn dotAt(view_w: u16, count: usize, cx: usize) ?usize {
    const start = dotsStart(view_w, count) orelse return null;
    if (cx <= start or cx >= start + count * 2 + 1 or (cx - start) % 2 == 0) return null;
    return (cx - start) / 2;
}

/// The cell before the first dot, whose window's dot is at this plus 1, the next at plus 3.
pub fn dotsStart(view_w: u16, count: usize) ?usize {
    const span = count * 2 + 1;
    if (count < 2 or span + 4 > view_w) return null;
    return (view_w - span) / 2;
}

test "dots are centred, one per window, with spaces between" {
    // 3 windows in 21 cells: span 7 from cell 7, dots at 8, 10 and 12
    try std.testing.expectEqual(@as(?usize, null), dotAt(21, 3, 7));
    try std.testing.expectEqual(@as(?usize, 0), dotAt(21, 3, 8));
    try std.testing.expectEqual(@as(?usize, null), dotAt(21, 3, 9));
    try std.testing.expectEqual(@as(?usize, 2), dotAt(21, 3, 12));

    try std.testing.expectEqual(@as(?usize, null), dotAt(21, 1, 10));
    try std.testing.expectEqual(@as(?usize, null), dotAt(8, 3, 4));
}
