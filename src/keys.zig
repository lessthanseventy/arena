const std = @import("std");

pub const Mouse = struct {
    /// The protocol's button code: bits 0-1 the button, 4/8/16 the modifiers, 32 motion, 64 wheel.
    code: u16,
    x: u16,
    y: u16,
    release: bool,

    pub fn wheel(m: Mouse) bool {
        return m.code & 64 != 0;
    }

    pub fn motion(m: Mouse) bool {
        return m.code & 32 != 0;
    }

    pub fn leftPress(m: Mouse) bool {
        return !m.release and m.code & (3 | 32 | 64) == 0;
    }

    pub fn rightPress(m: Mouse) bool {
        return !m.release and m.code & (3 | 32 | 64) == 2;
    }

    pub fn middlePress(m: Mouse) bool {
        return !m.release and m.code & (3 | 32 | 64) == 1;
    }

    /// The wheel turned left or right, as a touchpad's sideways swipe is reported.
    pub fn sideways(m: Mouse) bool {
        return m.wheel() and m.code & 2 != 0;
    }
};

pub const Event = union(enum) {
    /// The letter of an Alt chord arena acts on.
    chord: u8,
    mouse: Mouse,
    /// A terminal's reply to a query, the text between `ESC ]` and its terminator.
    osc: []const u8,
};

pub const Part = struct {
    /// Bytes for the focused window, up to the first event.
    text: []const u8,
    event: ?Event,
    rest: []const u8,
    /// The start of a mouse report or reply whose end has not been read yet: the caller keeps it
    /// and passes it again in front of what it reads next.
    held: []const u8 = &.{},
};

/// The keys arena takes with Alt; `\r` is Enter.
pub const chords = "hjklHLxmq123456789\r";

/// Splits input at the first thing arena reads itself: an Alt chord (ESC then one of `chords`),
/// an SGR mouse report, or the terminal's reply to a query.
pub fn next(bytes: []const u8) Part {
    var i: usize = 0;
    while (std.mem.indexOfScalarPos(u8, bytes, i, 0x1b)) |esc| : (i = esc + 1) {
        const after = bytes[esc + 1 ..];
        if (after.len == 0) break;
        if (std.mem.indexOfScalar(u8, chords, after[0]) != null) {
            return .{ .text = bytes[0..esc], .event = .{ .chord = after[0] }, .rest = after[1..] };
        }
        if (mouse(after)) |found| {
            return .{ .text = bytes[0..esc], .event = .{ .mouse = found.mouse }, .rest = after[found.len..] };
        }
        if (std.mem.startsWith(u8, after, "]") and after.len > 1) {
            if (std.mem.indexOfAny(u8, after, "\x07\x1b")) |end| {
                const st = after[end] == 0x1b;
                if (!st or (end + 1 < after.len and after[end + 1] == '\\')) {
                    const len = end + if (st) @as(usize, 2) else 1;
                    return .{ .text = bytes[0..esc], .event = .{ .osc = after[1..end] }, .rest = after[len..] };
                }
            }
        }
        const unfinished = (std.mem.startsWith(u8, after, "]") and after.len > 1) or
            (std.mem.startsWith(u8, after, "[<") and std.mem.indexOfAny(u8, after, "Mm") == null);
        if (unfinished and after.len < 64 and std.mem.indexOfScalar(u8, after, 0x1b) == null) {
            return .{ .text = bytes[0..esc], .event = null, .rest = &.{}, .held = bytes[esc..] };
        }
    }
    return .{ .text = bytes, .event = null, .rest = &.{} };
}

/// `[<code;x;y` then `M` for a press or motion, `m` for a release; x and y from 1.
fn mouse(after: []const u8) ?struct { mouse: Mouse, len: usize } {
    if (!std.mem.startsWith(u8, after, "[<")) return null;
    const end = std.mem.indexOfAnyPos(u8, after, 2, "Mm") orelse return null;
    var fields = std.mem.splitScalar(u8, after[2..end], ';');
    const code = std.fmt.parseInt(u16, fields.next() orelse return null, 10) catch return null;
    const x = std.fmt.parseInt(u16, fields.next() orelse return null, 10) catch return null;
    const y = std.fmt.parseInt(u16, fields.next() orelse return null, 10) catch return null;
    if (x == 0 or y == 0 or fields.next() != null) return null;
    return .{ .mouse = .{ .code = code, .x = x - 1, .y = y - 1, .release = after[end] == 'm' }, .len = end + 1 };
}

test "a chord is found among other typing" {
    const part = next("echo hi\r\x1bjmore");
    try std.testing.expectEqualStrings("echo hi\r", part.text);
    try std.testing.expectEqual(@as(u8, 'j'), part.event.?.chord);
    try std.testing.expectEqualStrings("more", part.rest);
}

test "Alt+Enter is a chord" {
    try std.testing.expectEqual(@as(u8, '\r'), next("\x1b\r").event.?.chord);
}

test "other escape sequences and a trailing escape are the window's" {
    for ([_][]const u8{ "\x1b[A", "\x1bOP", "\x1bz", "abc\x1b", "\x1b[<0;0;1M", "" }) |bytes| {
        const part = next(bytes);
        try std.testing.expectEqualStrings(bytes, part.text);
        try std.testing.expectEqual(@as(?Event, null), part.event);
    }
}

test "a terminal's reply is an event, ended by ST or BEL" {
    const st = next("a\x1b]4;5;rgb:ff/00/00\x1b\\b");
    try std.testing.expectEqualStrings("a", st.text);
    try std.testing.expectEqualStrings("4;5;rgb:ff/00/00", st.event.?.osc);
    try std.testing.expectEqualStrings("b", st.rest);
    try std.testing.expectEqualStrings("11;rgb:00/00/00", next("\x1b]11;rgb:00/00/00\x07").event.?.osc);
}

test "a report or reply cut off by the read is held, not typed" {
    for ([_][]const u8{ "\x1b[<0;1", "\x1b]4;5;rgb:ff" }) |cut| {
        const part = next(cut);
        try std.testing.expectEqualStrings("", part.text);
        try std.testing.expectEqual(@as(?Event, null), part.event);
        try std.testing.expectEqualStrings(cut, part.held);
    }
    try std.testing.expectEqualStrings("x", next("x\x1b[<0;1").text);
    try std.testing.expectEqualStrings("\x1b]", next("\x1b]").text);
}

test "a mouse report gives its cell from zero and what happened" {
    const press = next("a\x1b[<0;12;3Mb");
    try std.testing.expectEqualStrings("a", press.text);
    try std.testing.expectEqualStrings("b", press.rest);
    const m = press.event.?.mouse;
    try std.testing.expectEqual(@as(u16, 11), m.x);
    try std.testing.expectEqual(@as(u16, 2), m.y);
    try std.testing.expect(m.leftPress());

    try std.testing.expect(!next("\x1b[<0;1;1m").event.?.mouse.leftPress());
    try std.testing.expect(!next("\x1b[<2;1;1M").event.?.mouse.leftPress());
    try std.testing.expect(next("\x1b[<65;1;1M").event.?.mouse.wheel());
    try std.testing.expect(next("\x1b[<32;1;1M").event.?.mouse.motion());
    try std.testing.expect(next("\x1b[<1;1;1M").event.?.mouse.middlePress());
    try std.testing.expect(next("\x1b[<66;1;1M").event.?.mouse.sideways());
    try std.testing.expect(!next("\x1b[<65;1;1M").event.?.mouse.sideways());
}
