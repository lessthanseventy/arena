const std = @import("std");

/// The `+ goal` modal on Plan: a field for the rough idea, typed in insert mode, then driven in
/// normal mode by plan it now, just keep it, or cancel.
pub const Modal = struct {
    buf: [600]u8 = undefined,
    len: usize = 0,
    typing: bool = true,
    /// The command is running: its answer closes the modal or says why not.
    busy: bool = false,
    said: [160]u8 = undefined,
    said_len: usize = 0,

    pub const Result = enum { none, plan, keep, cancel };

    pub fn text(m: *const Modal) []const u8 {
        return m.buf[0..m.len];
    }

    pub fn refusal(m: *const Modal) []const u8 {
        return m.said[0..m.said_len];
    }

    /// One key. Typing: every key goes to the field, `⏎` and Esc end it. Driving: `⏎` plans it now,
    /// `k` keeps it, `i` types again, `q` and Esc cancel. Nothing typed plans or keeps nothing.
    pub fn press(m: *Modal, key: []const u8) Result {
        const esc = std.mem.eql(u8, key, "\x1b");
        if (m.busy) return if (esc or std.mem.eql(u8, key, "q")) .cancel else .none;
        if (m.typing) {
            if (esc or std.mem.eql(u8, key, "\r")) {
                m.typing = false;
            } else if (key.len == 1) m.type_(key[0]);
            return .none;
        }
        const filled = std.mem.trim(u8, m.text(), " ").len > 0;
        if (std.mem.eql(u8, key, "\r")) return if (filled) .plan else .none;
        if (std.mem.eql(u8, key, "k")) return if (filled) .keep else .none;
        if (std.mem.eql(u8, key, "i")) m.typing = true;
        if (esc or std.mem.eql(u8, key, "q")) return .cancel;
        return .none;
    }

    fn type_(m: *Modal, byte: u8) void {
        if (byte == 0x7f or byte == 0x08) {
            while (m.len > 0) {
                m.len -= 1;
                if (m.buf[m.len] & 0xC0 != 0x80) break;
            }
        } else if (byte >= 0x20) {
            const continues = byte & 0xC0 == 0x80;
            if (m.len < if (continues) m.buf.len else m.buf.len - 4) {
                m.buf[m.len] = byte;
                m.len += 1;
            }
        }
    }

    /// What babylon refused with, its first line.
    pub fn refuse(m: *Modal, line: []const u8) void {
        m.busy = false;
        const n = @min(line.len, m.said.len);
        @memcpy(m.said[0..n], line[0..n]);
        m.said_len = n;
    }
};

test "typing goes to the field, ⏎ and Esc end it, and the buttons act in normal" {
    var m: Modal = .{};
    for ("a é") |byte| try std.testing.expectEqual(Modal.Result.none, m.press(&.{byte}));
    try std.testing.expectEqualStrings("a é", m.text());
    // j, k and q are the field's while typing
    for ("kq") |byte| _ = m.press(&.{byte});
    try std.testing.expectEqualStrings("a ékq", m.text());
    _ = m.press("\x7f");
    _ = m.press("\x7f");
    try std.testing.expect(m.typing);
    _ = m.press("\x7f");
    try std.testing.expectEqualStrings("a ", m.text());
    _ = m.press("\x7f");
    _ = m.press("\x7f");
    _ = m.press("\x7f");
    try std.testing.expectEqual(@as(usize, 0), m.len);

    for ("rough") |byte| _ = m.press(&.{byte});
    try std.testing.expectEqual(Modal.Result.none, m.press("\x1b"));
    try std.testing.expect(!m.typing);
    try std.testing.expectEqual(Modal.Result.none, m.press("j"));
    try std.testing.expectEqualStrings("rough", m.text());
    try std.testing.expectEqual(Modal.Result.none, m.press("i"));
    try std.testing.expect(m.typing);
    try std.testing.expectEqual(Modal.Result.none, m.press("\r"));
    try std.testing.expectEqual(Modal.Result.plan, m.press("\r"));
    try std.testing.expectEqual(Modal.Result.keep, m.press("k"));
    try std.testing.expectEqual(Modal.Result.cancel, m.press("q"));
    try std.testing.expectEqual(Modal.Result.cancel, m.press("\x1b"));
}

test "an empty field plans and keeps nothing, and a running command takes only a cancel" {
    var m: Modal = .{};
    _ = m.press("\r");
    try std.testing.expectEqual(Modal.Result.none, m.press("\r"));
    try std.testing.expectEqual(Modal.Result.none, m.press("k"));
    m.typing = true;
    _ = m.press(" ");
    _ = m.press("\r");
    try std.testing.expectEqual(Modal.Result.none, m.press("k"));

    m.typing = true;
    _ = m.press("x");
    _ = m.press("\r");
    m.busy = true;
    try std.testing.expectEqual(Modal.Result.none, m.press("k"));
    m.refuse("babylon: no repo");
    try std.testing.expect(!m.busy);
    try std.testing.expectEqualStrings("babylon: no repo", m.refusal());
    try std.testing.expectEqual(Modal.Result.keep, m.press("k"));
}

/// `text` broken into lines of at most `width` characters, at a space where there is one, into
/// `out`; as many lines as fit. The count.
pub fn wrap(text: []const u8, width: usize, out: [][]const u8) usize {
    var n: usize = 0;
    var start: usize = 0;
    while (start < text.len and n < out.len) {
        var i = start;
        var count: usize = 0;
        var space: ?usize = null;
        while (i < text.len and count < width) : (count += 1) {
            if (text[i] == ' ') space = i;
            i += std.unicode.utf8ByteSequenceLength(text[i]) catch 1;
        }
        i = @min(i, text.len);
        if (i < text.len and text[i] != ' ') if (space) |at| if (at > start) {
            out[n] = text[start..at];
            n += 1;
            start = at + 1;
            continue;
        };
        out[n] = text[start..i];
        n += 1;
        start = if (i < text.len and text[i] == ' ') i + 1 else i;
    }
    return n;
}

test "a field wraps at a space, or at the width where a word is longer" {
    var out: [8][]const u8 = undefined;
    const n = wrap("the house's money shows on the desktop bar", 16, &out);
    try std.testing.expectEqual(@as(usize, 3), n);
    try std.testing.expectEqualStrings("the house's", out[0]);
    try std.testing.expectEqualStrings("money shows on", out[1]);
    try std.testing.expectEqualStrings("the desktop bar", out[2]);
    const m = wrap("abcdefghij", 4, &out);
    try std.testing.expectEqual(@as(usize, 3), m);
    try std.testing.expectEqualStrings("efgh", out[1]);
    try std.testing.expectEqual(@as(usize, 0), wrap("", 4, &out));
}
