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

/// The strip offset that centres column `focus` in the view.
pub fn scrollTarget(view_w: u16, col_w: u16, focus: usize) i32 {
    return colX(col_w, focus) - @divTrunc(@as(i32, view_w) - col_w, 2);
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
    try std.testing.expectEqual(@as(i32, 0), scrollTarget(100, 100, 0));
}

test "the focused column is centred with a peek either side" {
    const w = colWidth(100, 3);
    try std.testing.expectEqual(@as(u16, 80), w);
    try std.testing.expectEqual(@as(i32, -10), scrollTarget(100, w, 0));
    try std.testing.expectEqual(@as(i32, 71), scrollTarget(100, w, 1));
}

test "step always arrives" {
    var s: i32 = 0;
    var frames: usize = 0;
    while (s != 160) : (frames += 1) s = step(s, 160);
    try std.testing.expect(frames < 20);
    try std.testing.expectEqual(@as(i32, -1), step(0, -1));
}
