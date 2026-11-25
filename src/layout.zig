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

/// The foot row of a pane view, `view_w` cells wide with `count` windows: where each part starts.
/// Wide, a window is its dot and number; narrow, the dots alone. Null when even that cannot fit.
pub const Foot = struct {
    wide: bool,
    session: usize,
    name_w: usize,
    dots: usize,
    /// Cells from one window's dot to the next's.
    step: usize,
    go: usize,
    menu: usize,
    /// The first cell after the last part, where the mode may start.
    end: usize,

    pub const home = 1;
    pub const home_w = 6;
    pub const needs = 8;
    pub const needs_w = 4;
    pub const go_w = 7;
    pub const wide_from = 140;
    pub const mode_w = 13;
};

pub fn foot(view_w: u16, count: usize) ?Foot {
    const wide = view_w >= Foot.wide_from;
    const sep: usize = if (wide) 5 else 3;
    const name_w: usize = if (wide) 12 else 8;
    const digits: usize = if (count >= 100) 3 else if (count >= 10) 2 else 1;
    const stride: usize = if (wide) 3 + digits else 1;
    const dots_w = if (count == 0) 0 else (count - 1) * stride + (if (wide) 2 + digits else 1);
    const session = 12 + sep;
    const dots = session + 4 + name_w + (if (wide) @as(usize, 2) else 1);
    const go = dots + dots_w + sep;
    const menu = go + Foot.go_w + 2;
    if (menu + 2 > view_w) return null;
    return .{ .wide = wide, .session = session, .name_w = name_w, .dots = dots, .step = stride, .go = go, .menu = menu, .end = menu + 2 };
}

pub const FootHit = union(enum) { home, go, menu, window: usize };

/// What is at cell `cx` of the foot row: a window by the cells of its dot and number.
pub fn footAt(view_w: u16, count: usize, cx: usize) ?FootHit {
    const f = foot(view_w, count) orelse return null;
    if (cx >= Foot.home and cx < Foot.home + Foot.home_w) return .home;
    if (cx >= f.go and cx < f.go + Foot.go_w) return .go;
    if (cx == f.menu) return .menu;
    if (cx < f.dots) return null;
    const at = (cx - f.dots) / f.step;
    const within = (cx - f.dots) % f.step;
    if (at >= count or within >= (if (f.wide) f.step - 1 else 1)) return null;
    return .{ .window = at };
}

test "the foot row's parts keep their cells: wide, a window is its dot and number; narrow, the dot alone" {
    const wide = foot(220, 3).?;
    try std.testing.expect(wide.wide);
    try std.testing.expectEqual(@as(usize, 4), wide.step);
    try std.testing.expectEqual(FootHit.home, footAt(220, 3, 1).?);
    try std.testing.expectEqual(@as(?FootHit, null), footAt(220, 3, 7));
    try std.testing.expectEqual(FootHit{ .window = 1 }, footAt(220, 3, wide.dots + 4).?);
    try std.testing.expectEqual(@as(?FootHit, null), footAt(220, 3, wide.dots + 3));
    try std.testing.expectEqual(FootHit.go, footAt(220, 3, wide.go).?);
    try std.testing.expectEqual(FootHit.menu, footAt(220, 3, wide.menu).?);

    const half = foot(110, 4).?;
    try std.testing.expect(!half.wide);
    try std.testing.expectEqual(FootHit{ .window = 2 }, footAt(110, 4, half.dots + 2).?);
    try std.testing.expectEqual(@as(?FootHit, null), footAt(110, 4, half.dots + 4));
    try std.testing.expectEqual(@as(?Foot, null), foot(30, 4));
}

/// The first cell of tabs `widths` cells wide with two between, centred in `view_w`; null for
/// fewer than two, or when they do not fit with two cells to spare at each side.
pub fn tabsStart(view_w: u16, widths: []const usize) ?usize {
    if (widths.len < 2) return null;
    var span: usize = 2 * (widths.len - 1);
    for (widths) |w| span += w;
    if (span + 4 > view_w) return null;
    return (view_w - span) / 2;
}

/// The tab of `widths` at cell `cx`, laid out as `tabsStart` has them.
pub fn tabAt(view_w: u16, widths: []const usize, cx: usize) ?usize {
    var x = tabsStart(view_w, widths) orelse return null;
    for (widths, 0..) |w, i| {
        if (cx >= x and cx < x + w) return i;
        x += w + 2;
    }
    return null;
}

test "tabs are centred, two cells apart, and none when they do not fit" {
    // 3 + 2 + 4 = 9 cells of 20, from cell 5: the first at 5 to 7, the second at 10 to 13
    const widths = [_]usize{ 3, 4 };
    try std.testing.expectEqual(@as(?usize, 5), tabsStart(20, &widths));
    try std.testing.expectEqual(@as(?usize, null), tabAt(20, &widths, 4));
    try std.testing.expectEqual(@as(?usize, 0), tabAt(20, &widths, 5));
    try std.testing.expectEqual(@as(?usize, 0), tabAt(20, &widths, 7));
    try std.testing.expectEqual(@as(?usize, null), tabAt(20, &widths, 8));
    try std.testing.expectEqual(@as(?usize, 1), tabAt(20, &widths, 10));
    try std.testing.expectEqual(@as(?usize, null), tabAt(20, &widths, 14));
    try std.testing.expectEqual(@as(?usize, null), tabsStart(12, &widths));
    try std.testing.expectEqual(@as(?usize, null), tabsStart(80, &[_]usize{5}));
}
