const std = @import("std");

pub const Event = union(enum) {
    /// A reply opens: `guard` is its time and number, which its end repeats; it answers a
    /// command of this client's only when `mine`.
    begin: struct { guard: []const u8, mine: bool },
    end,
    /// A reply ends, its command refused.
    failed,
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
    /// `arena board <id>` run elsewhere asks this arena for the board on that ticket.
    card: u32,
    exit,
    other,
};

/// What `arena board <id>` has tmux say to a running arena, the id after it: display-message
/// to a control client comes to it as a `%message` line.
pub const card_message = "arena board ";

const changes = [_][]const u8{
    "%sessions-changed", "%session-renamed ",     "%window-add ",
    "%window-close ",    "%window-renamed ",      "%unlinked-window-",
    "%layout-change ",   "%window-pane-changed ",
};

/// Classifies one line of `tmux -C` output. `open` is the guard of the open `%begin`, if any:
/// only an end with the same one closes it, as a reply's own lines may look like guards.
pub fn parse(line: []const u8, open: ?[]const u8) Event {
    if (open) |guard| {
        for ([_][]const u8{ "%end ", "%error " }) |prefix| {
            if (!std.mem.startsWith(u8, line, prefix)) continue;
            const rest = line[prefix.len..];
            if (std.mem.startsWith(u8, rest, guard) and rest.len > guard.len and rest[guard.len] == ' ')
                return if (std.mem.eql(u8, prefix, "%error ")) .failed else .end;
        }
        return .{ .body = line };
    }
    if (std.mem.startsWith(u8, line, "%begin ")) {
        const rest = line["%begin ".len..];
        const flags = std.mem.lastIndexOfScalar(u8, rest, ' ') orelse return .other;
        return .{ .begin = .{ .guard = rest[0..flags], .mine = std.mem.eql(u8, rest[flags + 1 ..], "1") } };
    }
    if (std.mem.startsWith(u8, line, "%output %")) {
        const rest = line["%output %".len..];
        const space = std.mem.indexOfScalar(u8, rest, ' ') orelse return .other;
        const pane = std.fmt.parseInt(u32, rest[0..space], 10) catch return .other;
        return .{ .output = .{ .pane = pane, .data = rest[space + 1 ..] } };
    }
    if (std.mem.startsWith(u8, line, "%exit")) return .exit;
    if (std.mem.startsWith(u8, line, "%message " ++ card_message)) {
        const id = std.fmt.parseInt(u32, line["%message ".len + card_message.len ..], 10) catch return .other;
        return .{ .card = id };
    }
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
    const ev = parse(&line, null);
    try std.testing.expectEqual(@as(u32, 12), ev.output.pane);
    try std.testing.expectEqualStrings("hi\x1b[1m\r\n\\", unescape(@constCast(ev.output.data)));
}

test "a block's lines are body until its own end or error" {
    const mine = parse("%begin 1 2 1", null).begin;
    try std.testing.expectEqualStrings("1 2", mine.guard);
    try std.testing.expect(mine.mine);
    try std.testing.expect(!parse("%begin 1 2 0", null).begin.mine);
    try std.testing.expectEqualStrings("%1 zsh", parse("%1 zsh", "1 2").body);
    try std.testing.expectEqual(Event.end, parse("%end 1 2 1", "1 2"));
    try std.testing.expectEqual(Event.failed, parse("%error 1 2 1", "1 2"));
}

test "a line of a reply that looks like a guard is still the reply's" {
    try std.testing.expectEqualStrings("%end 1 3 1", parse("%end 1 3 1", "1 2").body);
    try std.testing.expectEqualStrings("%end 1 23 1", parse("%end 1 23 1", "1 2").body);
    try std.testing.expectEqualStrings("%begin 1 3 1", parse("%begin 1 3 1", "1 2").body);
}

test "anything that changes the tree asks for a relist" {
    for ([_][]const u8{
        "%window-add @3",             "%window-renamed @3 vim",    "%unlinked-window-close @9",
        "%sessions-changed",          "%session-renamed $7 notes", "%layout-change @0 cf3a,80x24,0,0,0 cf3a,80x24,0,0,0 *",
        "%window-pane-changed @2 %4",
    }) |line| try std.testing.expectEqual(Event.changed, parse(line, null));
    try std.testing.expectEqual(Event.other, parse("%client-session-changed /dev/pts/3 $1 a", null));
    try std.testing.expectEqual(Event.exit, parse("%exit", null));
}

test "a message for the board says which ticket, and any other message is not arena's" {
    try std.testing.expectEqual(@as(u32, 240), parse("%message arena board 240", null).card);
    try std.testing.expectEqual(Event.other, parse("%message arena board lights", null));
    try std.testing.expectEqual(Event.other, parse("%message hello", null));
}

test "session notifications say which session" {
    try std.testing.expectEqual(@as(u32, 7), parse("%session-changed $7 notes", null).session_changed);
    try std.testing.expectEqual(@as(u32, 0), parse("%session-window-changed $0 @1", null).window_selected);
}
