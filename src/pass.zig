const std = @import("std");
const Allocator = std.mem.Allocator;

const intro = "\x1bPtmux;";
/// The kitty protocol asks for pieces of at most 4096 bytes, but Claude Code sends a picture whole.
const max_len = 16 << 20;

/// Parts a pane's output into what the pane's terminal takes and the kitty graphics commands
/// its program wraps for tmux to pass through, which a control client is sent as output like
/// any other. Only graphics commands pass: nothing else a program wraps reaches arena's terminal.
/// A window's name set as screen does, ESC k to ST or BEL, is tmux's, and arena's terminal
/// would show it as text.
pub const Pass = struct {
    state: enum { ground, body, esc, name, name_esc } = .ground,
    matched: u8 = 0,
    over: bool = false,
    buf: std.ArrayList(u8) = .empty,

    pub fn deinit(pass: *Pass, gpa: Allocator) void {
        pass.buf.deinit(gpa);
    }

    /// Takes the output as it comes, in pieces cut anywhere. Each whole command is appended to
    /// `out`, unwrapped, and everything outside a wrapping to `plain`.
    pub fn feed(pass: *Pass, gpa: Allocator, bytes: []const u8, out: *std.ArrayList(u8), plain: *std.ArrayList(u8)) !void {
        for (bytes) |byte| switch (pass.state) {
            .ground => {
                if (pass.matched == 1 and byte == 'k') {
                    pass.matched = 0;
                    pass.state = .name;
                    continue;
                }
                if (byte != intro[pass.matched]) {
                    try plain.appendSlice(gpa, intro[0..pass.matched]);
                    pass.matched = 0;
                }
                if (byte != intro[pass.matched]) {
                    try plain.append(gpa, byte);
                    continue;
                }
                pass.matched += 1;
                if (pass.matched == intro.len) {
                    pass.matched = 0;
                    pass.buf.clearRetainingCapacity();
                    pass.state = .body;
                }
            },
            .body => if (byte == 0x1b) {
                pass.state = .esc;
            } else if (pass.buf.items.len < max_len) {
                try pass.buf.append(gpa, byte);
            } else {
                pass.over = true;
            },
            // Inside the wrapping every escape is doubled; one alone ends it.
            .esc => if (byte == 0x1b) {
                if (pass.buf.items.len < max_len) try pass.buf.append(gpa, byte) else pass.over = true;
                pass.state = .body;
            } else {
                const command = pass.buf.items;
                if (!pass.over and byte == '\\' and std.mem.startsWith(u8, command, "\x1b_G") and std.mem.endsWith(u8, command, "\x1b\\")) try out.appendSlice(gpa, command);
                if (pass.buf.capacity > 1 << 16) pass.buf.clearAndFree(gpa);
                pass.over = false;
                pass.state = .ground;
            },
            .name => if (byte == 0x1b) {
                pass.state = .name_esc;
            } else if (byte == 0x07) {
                pass.state = .ground;
            },
            .name_esc => pass.state = if (byte == '\\') .ground else .name,
        };
    }
};

fn expectParted(pieces: []const []const u8, want_out: []const u8, want_plain: []const u8) !void {
    const gpa = std.testing.allocator;
    var pass: Pass = .{};
    defer pass.deinit(gpa);
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    var plain: std.ArrayList(u8) = .empty;
    defer plain.deinit(gpa);
    for (pieces) |piece| try pass.feed(gpa, piece, &out, &plain);
    try std.testing.expectEqualStrings(want_out, out.items);
    try std.testing.expectEqualStrings(want_plain, plain.items);
}

test "a window's name set as screen does, which tmux takes, is not text" {
    try expectParted(&.{ "\x1bkec", "ho\x1b", "\\hi\r\n" }, "", "hi\r\n");
    try expectParted(&.{"\x1bkvim\x07:q\x1b[m"}, "", ":q\x1b[m");
}

test "a wrapped picture is unwrapped, and the text around it is left" {
    try expectParted(
        &.{"ls\r\n\x1bPtmux;\x1b\x1b_Ga=T,i=7,m=1;QUJD\x1b\x1b\\\x1b\\$ \x1bPtmux;\x1b\x1b_Gm=0;RA==\x1b\x1b\\\x1b\\\x1b[m"},
        "\x1b_Ga=T,i=7,m=1;QUJD\x1b\\\x1b_Gm=0;RA==\x1b\\",
        "ls\r\n$ \x1b[m",
    );
}

test "a picture cut anywhere between pieces of output still passes" {
    const whole = "\x1b\x1bPtmux;\x1b\x1b_Ga=T,i=7;QUJD\x1b\x1b\\\x1b\\\x1bPq";
    for (1..whole.len) |cut| try expectParted(&.{ whole[0..cut], whole[cut..] }, "\x1b_Ga=T,i=7;QUJD\x1b\\", "\x1b\x1bPq");
}

fn wrapped(gpa: Allocator, intro_: []const u8, len: usize, end: []const u8) !std.ArrayList(u8) {
    var in: std.ArrayList(u8) = .empty;
    try in.appendSlice(gpa, intro_);
    try in.appendNTimes(gpa, 'A', len);
    try in.appendSlice(gpa, end);
    return in;
}

test "a picture sent whole, not in pieces, passes" {
    const gpa = std.testing.allocator;
    var in = try wrapped(gpa, "\x1bPtmux;\x1b\x1b_Ga=T;", 100_000, "\x1b\x1b\\\x1b\\$ ");
    defer in.deinit(gpa);
    var want = try wrapped(gpa, "\x1b_Ga=T;", 100_000, "\x1b\\");
    defer want.deinit(gpa);
    try expectParted(&.{in.items}, want.items, "$ ");
}

test "a command past what arena holds is left out whole, none of it text" {
    const gpa = std.testing.allocator;
    var in = try wrapped(gpa, "\x1bPtmux;\x1b\x1b_Ga=T;", max_len, "\x1b\x1b\\\x1b\\$ ");
    defer in.deinit(gpa);
    try expectParted(&.{in.items}, "", "$ ");
}

test "a query passes, and anything wrapped that is not a graphics command does not" {
    try expectParted(&.{"\x1bPtmux;\x1b\x1b_Gi=31,a=q;AAAA\x1b\x1b\\\x1b\\"}, "\x1b_Gi=31,a=q;AAAA\x1b\\", "");
    try expectParted(&.{"\x1bPtmux;\x1b\x1b]52;c;aGk=\x07\x1b\\"}, "", "");
    try expectParted(&.{"\x1bPtmux;\x1b\x1b_Ga=T;QUJD\x07\x1b\\"}, "", "");
}
