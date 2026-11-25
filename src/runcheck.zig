//! The shell commands a to-try check's text holds, for `r` to run.

const std = @import("std");

/// The commands in `text`, one a line, in `buf`: each backticked span of more than one word, and
/// each line of a fenced block. Empty when there are none, or when they do not fit `buf`, since a
/// command cut short must never run.
pub fn find(text: []const u8, buf: []u8) []const u8 {
    var w: std.Io.Writer = .fixed(buf);
    var rest = text;
    while (std.mem.indexOfScalar(u8, rest, '`')) |open| {
        if (std.mem.startsWith(u8, rest[open..], "```")) {
            const from = open + 3;
            const close = std.mem.indexOfPos(u8, rest, from, "```") orelse break;
            var body = rest[from..close];
            // the first line of a block with several is its language tag
            if (std.mem.indexOfScalar(u8, body, '\n')) |nl| body = body[nl + 1 ..];
            var lines = std.mem.splitScalar(u8, body, '\n');
            while (lines.next()) |line| {
                const command = std.mem.trim(u8, line, " \t\r");
                if (command.len > 0) w.print("{s}\n", .{command}) catch return "";
            }
            rest = rest[close + 3 ..];
            continue;
        }
        const close = std.mem.indexOfScalarPos(u8, rest, open + 1, '`') orelse break;
        const span = std.mem.trim(u8, rest[open + 1 .. close], " \t");
        rest = rest[close + 1 ..];
        if (std.mem.indexOfAny(u8, span, " \t") == null or std.mem.indexOfScalar(u8, span, '\n') != null) continue;
        w.print("{s}\n", .{span}) catch return "";
    }
    return std.mem.trimEnd(u8, w.buffered(), "\n");
}

test "an inline command of several words is one, a lone word or plain prose is none" {
    var buf: [256]u8 = undefined;
    try std.testing.expectEqualStrings("echo hi", find("run `echo hi` and look", &buf));
    try std.testing.expectEqualStrings("", find("open `board.json` and look", &buf));
    try std.testing.expectEqualStrings("", find("it shows the card and says nothing is broken", &buf));
    try std.testing.expectEqualStrings("", find("an unclosed ` backtick and then more words", &buf));
}

test "several inline commands are one a line, in order" {
    var buf: [256]u8 = undefined;
    const text = "`systemctl --user show babylon -p Environment`, then `systemctl --user daemon-reload`";
    try std.testing.expectEqualStrings("systemctl --user show babylon -p Environment\nsystemctl --user daemon-reload", find(text, &buf));
}

test "a fenced block is a command a line, its language tag and blank lines left out" {
    var buf: [256]u8 = undefined;
    try std.testing.expectEqualStrings("echo a\nls -l /tmp", find("do:\n```sh\necho a\n\n  ls -l /tmp\n```\nthen look", &buf));
    try std.testing.expectEqualStrings("echo hi", find("```echo hi```", &buf));
}

test "commands that do not fit the buffer are none, not cut short" {
    var buf: [8]u8 = undefined;
    try std.testing.expectEqualStrings("", find("`rm -rf /tmp/some/long/path`", &buf));
}
