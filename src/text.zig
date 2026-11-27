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

/// What a heading line in `landed`'s text starts with, taken off when it is drawn.
pub const heading_mark = '\x01';

/// The whole commit hash of a landing note, null for a note not in `landed`'s shape.
pub fn fullHash(note: []const u8) ?[]const u8 {
    const lead = "landed on main as ";
    if (!std.mem.startsWith(u8, note, lead)) return null;
    const body = note[lead.len..];
    const hash = body[0 .. std.mem.indexOfAny(u8, body, ", ") orelse body.len];
    return if (hash.len > 0) hash else null;
}

/// A landing note as lines to draw, in `buf`: a blank row, the heading `Landed`, `on main`, the
/// short hash and what happened since, then the review's fixes and the follow-ups as bullets.
/// Babylon writes the note as one string, so it is split on its joins; a note not in that shape
/// comes back as it was.
pub fn landed(buf: []u8, note: []const u8) []const u8 {
    const lead = "landed on main as ";
    if (!std.mem.startsWith(u8, note, lead)) return note;
    var body = note[lead.len..];
    var state: []const u8 = "";
    if (std.mem.lastIndexOf(u8, body, " \u{b7} install")) |at| {
        state = body[at + 4 ..];
        body = body[0..at];
    }
    var follow: []const u8 = "";
    if (std.mem.indexOf(u8, body, "; follow-ups filed: ")) |at| {
        follow = body[at + 20 ..];
        body = body[0..at];
    }
    const hash_end = std.mem.indexOfAny(u8, body, ", ") orelse body.len;
    const hash = body[0..hash_end];
    var fixes = body[hash_end..];
    const fixes_lead = ", with the review's fixes: ";
    fixes = if (std.mem.startsWith(u8, fixes, fixes_lead)) fixes[fixes_lead.len..] else "";

    var w: std.Io.Writer = .fixed(buf);
    w.print("\n{c}Landed\non main \u{b7} {s}", .{ heading_mark, hash[0..@min(hash.len, 7)] }) catch return w.buffered();
    if (state.len > 0) w.print(" \u{b7} {s}", .{state}) catch return w.buffered();
    inline for (.{ .{ "Review fixes", fixes }, .{ "Follow-ups", follow } }) |part| if (part[1].len > 0) {
        w.print("\n{s}", .{part[0]}) catch return w.buffered();
        var items = std.mem.splitSequence(u8, part[1], "; ");
        while (items.next()) |item| w.print("\n  - {s}", .{item}) catch return w.buffered();
    };
    return w.buffered();
}

test "a landing note is split into its hash, fixes and follow-ups, each its own row" {
    var buf: [512]u8 = undefined;
    const note = "landed on main as 70119238def8b48a6c7ce684a4abfbe1e4a75a5e, with the review's fixes: one.; two. \u{b7} installing";
    try std.testing.expectEqualStrings("\n\x01Landed\non main \u{b7} 7011923 \u{b7} installing\nReview fixes\n  - one.\n  - two.", landed(&buf, note));
    try std.testing.expectEqualStrings(
        "\n\x01Landed\non main \u{b7} abcdef0\nFollow-ups\n  - #5 a\n  - #6 b",
        landed(&buf, "landed on main as abcdef0123, with the review's fixes: ; follow-ups filed: #5 a; #6 b"),
    );
    try std.testing.expectEqualStrings("gate ok", landed(&buf, "gate ok"));
    try std.testing.expectEqualStrings(
        "\n\x01Landed\non main \u{b7} abcdef0\nReview fixes\n  - a \u{b7} b",
        landed(&buf, "landed on main as abcdef0123, with the review's fixes: a \u{b7} b"),
    );
}
