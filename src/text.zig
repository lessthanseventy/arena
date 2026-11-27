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

/// A line broken off a text: what is left of it, and the spaces the break took out.
pub const Line = struct { line: []const u8, rest: []const u8, gap: usize };

/// The first line of `text` in `width` cells, broken at the last space that fits so a word is
/// never cut; a word longer than the width is the only thing split.
pub fn breakLine(text: []const u8, width: usize) Line {
    const fit = clip(text, @max(width, 1));
    if (fit.len == text.len) return .{ .line = text, .rest = "", .gap = 0 };
    var end = fit.len;
    if (text[end] != ' ') {
        if (std.mem.lastIndexOfScalar(u8, fit, ' ')) |space| {
            if (std.mem.trimStart(u8, fit[0..space], " ").len > 0) end = space;
        }
    }
    const line = std.mem.trimEnd(u8, text[0..end], " ");
    if (line.len == 0) return .{ .line = fit, .rest = text[fit.len..], .gap = 0 };
    const rest = std.mem.trimStart(u8, text[end..], " ");
    return .{ .line = line, .rest = rest, .gap = text.len - line.len - rest.len };
}

/// How far a continuation of `text` is indented: past its leading spaces and a list marker
/// (`1.`, `2)`, `-`, `*`), so a second line sits under the text and not under the marker.
pub fn hang(text: []const u8) usize {
    var at: usize = 0;
    while (at < text.len and text[at] == ' ') at += 1;
    var end = at;
    while (end < text.len and std.ascii.isDigit(text[end])) end += 1;
    if (end > at and end + 1 < text.len and (text[end] == '.' or text[end] == ')') and text[end + 1] == ' ') {
        end += 1;
    } else if (at + 1 < text.len and (text[at] == '-' or text[at] == '*') and text[at + 1] == ' ') {
        end = at + 1;
    } else end = at;
    while (end > at and end < text.len and text[end] == ' ') end += 1;
    return end;
}

/// `text` in `max` cells: whole when it fits, else broken at a word and ended with `…`; a single
/// word longer than `max` is cut. `buf` holds the result.
pub fn cut(buf: []u8, text: []const u8, max: usize) []const u8 {
    if (cells(text) <= max) return text;
    if (max <= 1) return if (max == 0) "" else "…";
    const head = breakLine(text, max - 1).line;
    return std.fmt.bufPrint(buf, "{s}…", .{head}) catch head;
}

test "a line breaks at a space, so a word that does not fit goes whole to the next line" {
    const text = "right and wrong, then y/n";
    const first = breakLine(text, 19);
    try std.testing.expectEqualStrings("right and wrong,", first.line);
    try std.testing.expectEqualStrings("then y/n", first.rest);
    try std.testing.expectEqual(@as(usize, 1), first.gap);
    try std.testing.expectEqualStrings("right and wrong, then", breakLine(text, 21).line);
}

test "a word longer than the width is the only thing split" {
    const first = breakLine("abcdefghij kl", 4);
    try std.testing.expectEqualStrings("abcd", first.line);
    try std.testing.expectEqualStrings("efghij kl", first.rest);
    try std.testing.expectEqual(@as(usize, 0), first.gap);
}

test "a step's continuation is indented past its number" {
    try std.testing.expectEqual(@as(usize, 3), hang("1. run the thing"));
    try std.testing.expectEqual(@as(usize, 4), hang("  - a bullet"));
    try std.testing.expectEqual(@as(usize, 0), hang("plain words"));
    try std.testing.expectEqual(@as(usize, 0), hang("1.5 is a number"));
}

test "a cut ends at a word with an ellipsis, and a lone long word is cut in it" {
    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("only your…", cut(&buf, "only your move is shown", 13));
    try std.testing.expectEqualStrings("whole", cut(&buf, "whole", 5));
    try std.testing.expectEqualStrings("Portabl…", cut(&buf, "Portable-transportation", 8));
    try std.testing.expectEqualStrings("é…", cut(&buf, "éééé", 2));
}
