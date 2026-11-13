const std = @import("std");

pub const Event = union(enum) {
    begin,
    end,
    /// A line of a command's reply, between `begin` and `end`.
    body: []const u8,
    /// Pane output, still in tmux's octal escaping; see `unescape`.
    output: struct { pane: u32, data: []const u8 },
    windows_changed,
    exit,
    other,
};

/// Classifies one line of `tmux -C` output. `in_block` is whether a `%begin` is open.
pub fn parse(line: []const u8, in_block: bool) Event {
    if (in_block) {
        if (std.mem.startsWith(u8, line, "%end ") or std.mem.startsWith(u8, line, "%error ")) return .end;
        return .{ .body = line };
    }
    if (std.mem.startsWith(u8, line, "%begin ")) return .begin;
    if (std.mem.startsWith(u8, line, "%output %")) {
        const rest = line["%output %".len..];
        const space = std.mem.indexOfScalar(u8, rest, ' ') orelse return .other;
        const pane = std.fmt.parseInt(u32, rest[0..space], 10) catch return .other;
        return .{ .output = .{ .pane = pane, .data = rest[space + 1 ..] } };
    }
    if (std.mem.startsWith(u8, line, "%exit")) return .exit;
    for ([_][]const u8{ "%window-add ", "%window-close ", "%window-renamed ", "%unlinked-window-" }) |prefix| {
        if (std.mem.startsWith(u8, line, prefix)) return .windows_changed;
    }
    return .other;
}

/// Decodes `%output` data in place: tmux writes bytes below space and backslash as `\ooo`.
pub fn unescape(data: []u8) []u8 {
    var r: usize = 0;
    var w: usize = 0;
    while (r < data.len) {
        if (data[r] == '\\' and r + 3 < data.len) {
            if (std.fmt.parseInt(u8, data[r + 1 .. r + 4], 8)) |byte| {
                data[w] = byte;
                w += 1;
                r += 4;
                continue;
            } else |_| {}
        }
        data[w] = data[r];
        w += 1;
        r += 1;
    }
    return data[0..w];
}

test "output carries its pane and unescapes" {
    var line = "%output %12 hi\\033[1m\\015\\012\\134".*;
    const ev = parse(&line, false);
    try std.testing.expectEqual(@as(u32, 12), ev.output.pane);
    try std.testing.expectEqualStrings("hi\x1b[1m\r\n\\", unescape(@constCast(ev.output.data)));
}

test "a block's lines are body until end or error" {
    try std.testing.expectEqual(Event.begin, parse("%begin 1 2 0", false));
    try std.testing.expectEqualStrings("%1 zsh", parse("%1 zsh", true).body);
    try std.testing.expectEqual(Event.end, parse("%end 1 2 0", true));
    try std.testing.expectEqual(Event.end, parse("%error 1 2 0", true));
}

test "window notifications ask for a relist" {
    try std.testing.expectEqual(Event.windows_changed, parse("%window-add @3", false));
    try std.testing.expectEqual(Event.windows_changed, parse("%window-renamed @3 vim", false));
    try std.testing.expectEqual(Event.other, parse("%session-changed $0 a", false));
    try std.testing.expectEqual(Event.exit, parse("%exit", false));
}
