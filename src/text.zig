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

/// A markdown doc made safe to draw and plain: a heading loses its `#`s and a list item's `-` or
/// `*` becomes a `•`.
pub fn appendDoc(out: *std.ArrayList(u8), gpa: Allocator, markdown: []const u8) !void {
    var clean: std.ArrayList(u8) = .empty;
    defer clean.deinit(gpa);
    try appendClean(&clean, gpa, markdown);
    var lines = std.mem.splitScalar(u8, clean.items, '\n');
    var first = true;
    while (lines.next()) |line| {
        if (!first) try out.append(gpa, '\n');
        first = false;
        const body = std.mem.trimStart(u8, line, " ");
        const indent = line[0 .. line.len - body.len];
        const hashes = std.mem.indexOfNone(u8, body, "#") orelse body.len;
        if (hashes > 0 and hashes <= 6 and hashes < body.len and body[hashes] == ' ') {
            try out.appendSlice(gpa, std.mem.trimStart(u8, body[hashes..], " "));
        } else if (body.len > 1 and (body[0] == '-' or body[0] == '*') and body[1] == ' ') {
            try out.appendSlice(gpa, indent);
            try out.appendSlice(gpa, "\u{2022}");
            try out.appendSlice(gpa, body[1..]);
        } else try out.appendSlice(gpa, line);
    }
}

test "a doc's headings lose their hashes and its list items get bullets" {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(std.testing.allocator);
    try appendDoc(&out, std.testing.allocator, "# Title\n\n## Part two\n- one\n  * two\n#tag\n");
    try std.testing.expectEqualStrings("Title\n\nPart two\n\u{2022} one\n  \u{2022} two\n#tag\n", out.items);
}

/// How many cells `text` takes, a cell to a character.
pub fn cells(text: []const u8) usize {
    return std.unicode.utf8CountCodepoints(text) catch text.len;
}

/// The first `max` characters of `text`.
pub fn clip(text: []const u8, max: usize) []const u8 {
    var it = std.unicode.Utf8View.initUnchecked(text).iterator();
    var n: usize = 0;
    while (n < max) : (n += 1) _ = it.nextCodepointSlice() orelse break;
    return text[0..it.i];
}

test "text to draw loses its escapes and controls, and a byte not UTF-8 is a ?" {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(std.testing.allocator);
    try appendClean(&out, std.testing.allocator, "\x1b[31mred\x1b[0m\tok\x07\n\xff é \x1b]0;title\x07end\xe2\x82");
    try std.testing.expectEqualStrings("red ok\n? é end??", out.items);
}
