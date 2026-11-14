const std = @import("std");
const Allocator = std.mem.Allocator;

const intro = "\x1bPtmux;";
/// The kitty protocol sends a picture in pieces of at most 4096 bytes.
const max_len = 1 << 16;

/// Parts a pane's output into what the pane's terminal takes and the kitty graphics commands
/// its program wraps for tmux to pass through, which a control client is sent as output like
/// any other. Only pictures pass: nothing else a program wraps reaches arena's terminal.
pub const Pass = struct {
    state: enum { ground, body, esc } = .ground,
    matched: u8 = 0,
    buf: std.ArrayList(u8) = .empty,

    pub fn deinit(pass: *Pass, gpa: Allocator) void {
        pass.buf.deinit(gpa);
    }

    /// Takes the output as it comes, in pieces cut anywhere. Each whole command is appended to
    /// `out`, unwrapped, and everything outside a wrapping to `plain`.
    pub fn feed(pass: *Pass, gpa: Allocator, bytes: []const u8, out: *std.ArrayList(u8), plain: *std.ArrayList(u8)) !void {
        for (bytes) |byte| switch (pass.state) {
            .ground => {
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
                pass.state = .ground;
            },
            // Inside the wrapping every escape is doubled; one alone ends it.
            .esc => if (byte == 0x1b) {
                try pass.buf.append(gpa, byte);
                pass.state = .body;
            } else {
                if (byte == '\\' and passes(pass.buf.items)) try out.appendSlice(gpa, pass.buf.items);
                pass.state = .ground;
            },
        };
    }

    /// A query is answered on arena's own input, where nothing takes the answer to the pane, so
    /// it is not passed: a program that hears nothing sends its pictures the plain way.
    fn passes(command: []const u8) bool {
        if (!std.mem.startsWith(u8, command, "\x1b_G") or !std.mem.endsWith(u8, command, "\x1b\\")) return false;
        const keys = command[3 .. std.mem.indexOfScalar(u8, command, ';') orelse command.len - 2];
        var it = std.mem.tokenizeScalar(u8, keys, ',');
        while (it.next()) |key| if (std.mem.eql(u8, key, "a=q")) return false;
        return true;
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

test "a query, and anything wrapped that is not a picture, does not pass" {
    try expectParted(&.{"\x1bPtmux;\x1b\x1b_Gi=31,a=q,t=d,f=24,s=1,v=1;AAAA\x1b\x1b\\\x1b\\"}, "", "");
    try expectParted(&.{"\x1bPtmux;\x1b\x1b]52;c;aGk=\x07\x1b\\"}, "", "");
    try expectParted(&.{"\x1bPtmux;\x1b\x1b_Ga=T;QUJD\x07\x1b\\"}, "", "");
}
