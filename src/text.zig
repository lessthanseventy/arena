const std = @import("std");
const Allocator = std.mem.Allocator;

/// `text` made safe to draw: escape sequences and control characters but newlines dropped, a tab
/// a space, and a byte that is not UTF-8 a `?`.
pub fn appendClean(out: *std.ArrayList(u8), gpa: Allocator, text: []const u8) !void {
    var i: usize = 0;
    while (i < text.len) {
        const b = text[i];
        if (b == 0x1b) {
            i += 1;
            if (i < text.len and text[i] == '[') {
                i += 1;
                while (i < text.len and (text[i] < 0x40 or text[i] > 0x7e)) i += 1;
            } else if (i < text.len and text[i] == ']') {
                while (i < text.len and text[i] != 0x07 and !(text[i] == 0x1b and i + 1 < text.len and text[i + 1] == '\\')) i += 1;
                if (i < text.len and text[i] == 0x1b) i += 1;
            }
            i += 1;
        } else if (b == '\t') {
            try out.append(gpa, ' ');
            i += 1;
        } else if (b < 0x20 and b != '\n' or b == 0x7f) {
            i += 1;
        } else if (b < 0x80) {
            try out.append(gpa, b);
            i += 1;
        } else {
            const len = std.unicode.utf8ByteSequenceLength(b) catch 0;
            const whole = len > 0 and i + len <= text.len and (if (std.unicode.utf8Decode(text[i .. i + len])) |_| true else |_| false);
            if (whole) try out.appendSlice(gpa, text[i .. i + len]) else try out.append(gpa, '?');
            i += if (whole) len else 1;
        }
    }
}

test "text to draw loses its escapes and controls, and a byte not UTF-8 is a ?" {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(std.testing.allocator);
    try appendClean(&out, std.testing.allocator, "\x1b[31mred\x1b[0m\tok\x07\n\xff é \x1b]0;title\x07end\xe2\x82");
    try std.testing.expectEqualStrings("red ok\n? é end??", out.items);
}
