const std = @import("std");

pub const Event = union(enum) {
    begin,
    end,
    /// A line of a command's reply, between `begin` and `end`.
    body: []const u8,
    /// Pane output, still in tmux's octal escaping; see `unescape`.
    output: struct { pane: u32, data: []const u8 },
    /// Sessions, windows or panes were added, closed, renamed or laid out anew: list them again.
    changed,
    /// The session with this id has a new current window.
    window_selected: u32,
    /// This client is now on the session with this id.
    session_changed: u32,
    exit,
    other,
};

const changes = [_][]const u8{
    "%sessions-changed",    "%session-renamed ",    "%window-add ",
    "%window-close ",       "%window-renamed ",     "%unlinked-window-",
    "%layout-change ",      "%window-pane-changed ",
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
    if (sessionId(line, "%session-changed $")) |id| return .{ .session_changed = id };
    if (sessionId(line, "%session-window-changed $")) |id| return .{ .window_selected = id };
    for (changes) |prefix| {
        if (std.mem.startsWith(u8, line, prefix)) return .changed;
    }
    return .other;
}

fn sessionId(line: []const u8, prefix: []const u8) ?u32 {
    if (!std.mem.startsWith(u8, line, prefix)) return null;
    var it = std.mem.tokenizeScalar(u8, line[prefix.len..], ' ');
    return std.fmt.parseInt(u32, it.next() orelse return null, 10) catch null;
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

test "anything that changes the tree asks for a relist" {
    for ([_][]const u8{
        "%window-add @3",          "%window-renamed @3 vim",      "%unlinked-window-close @9",
        "%sessions-changed",       "%session-renamed $7 notes",   "%layout-change @0 cf3a,80x24,0,0,0 cf3a,80x24,0,0,0 *",
        "%window-pane-changed @2 %4",
    }) |line| try std.testing.expectEqual(Event.changed, parse(line, false));
    try std.testing.expectEqual(Event.other, parse("%client-session-changed /dev/pts/3 $1 a", false));
    try std.testing.expectEqual(Event.exit, parse("%exit", false));
}

test "session notifications say which session" {
    try std.testing.expectEqual(@as(u32, 7), parse("%session-changed $7 notes", false).session_changed);
    try std.testing.expectEqual(@as(u32, 0), parse("%session-window-changed $0 @1", false).window_selected);
}
