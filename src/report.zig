//! "Report this": what arena was showing and the pointer doing, as text a ticket can carry.
const std = @import("std");
const vt = @import("ghostty-vt");
const keys = @import("keys.zig");
const Writer = std.Io.Writer;
const Allocator = std.mem.Allocator;

/// What a report says of arena's state, apart from the screen and the trail.
pub const Info = struct {
    commit: []const u8,
    cols: u16,
    rows: u16,
    rail: []const u8,
    mode: []const u8,
    view: []const u8,
    picked: []const u8,
    pointer: struct { x: u16, y: u16 },
    element: []const u8,
};

pub fn writeSummary(w: *Writer, info: Info) !void {
    try w.print("version: {s}\n", .{info.commit});
    try w.print("size: {d}x{d}\n", .{ info.cols, info.rows });
    try w.print("rail: {s}\n", .{info.rail});
    try w.print("mode: {s}\n", .{info.mode});
    try w.print("view: {s}\n", .{info.view});
    try w.print("picked: {s}\n", .{info.picked});
    try w.print("pointer: x={d} y={d} over {s}\n", .{ info.pointer.x, info.pointer.y, info.element });
}

/// The last input arena saw, oldest dropped first. What was typed into a pane is counted, not
/// kept: it may be a password.
pub const Trail = struct {
    const keep = 64;
    const Typed = struct { bytes: [12]u8 = undefined, len: u8 = 0 };

    pub const What = union(enum) {
        /// Keys arena itself took: normal mode, a menu, a prompt.
        keys: Typed,
        /// Bytes that went to a pane.
        to_pane: usize,
        chord: u8,
        mode,
        mouse: keys.Mouse,
    };
    const Entry = struct { at: i64, what: What };

    entries: [keep]Entry = undefined,
    total: usize = 0,

    pub fn push(t: *Trail, at: i64, what: What) void {
        if (t.total > 0) {
            const last = &t.entries[(t.total - 1) % keep];
            // a pointer on the move is one entry, where it is now; a run of typing, one count
            switch (what) {
                .mouse => |m| if (m.motion() and last.what == .mouse and last.what.mouse.motion() and last.what.mouse.code == m.code) {
                    last.* = .{ .at = at, .what = what };
                    return;
                },
                .to_pane => |n| if (last.what == .to_pane) {
                    last.what.to_pane += n;
                    last.at = at;
                    return;
                },
                else => {},
            }
        }
        t.entries[t.total % keep] = .{ .at = at, .what = what };
        t.total += 1;
    }

    pub fn pushKeys(t: *Trail, at: i64, text: []const u8) void {
        var typed: Typed = .{};
        typed.len = @intCast(@min(text.len, typed.bytes.len));
        @memcpy(typed.bytes[0..typed.len], text[0..typed.len]);
        t.push(at, .{ .keys = typed });
    }

    /// The entries oldest first, each with how long before `now` (milliseconds) it came.
    pub fn write(t: *const Trail, w: *Writer, now: i64) !void {
        const n = @min(t.total, keep);
        for (t.total - n..t.total) |i| {
            const entry = t.entries[i % keep];
            try w.print("-{d}ms  ", .{@max(0, now - entry.at)});
            switch (entry.what) {
                .keys => |typed| {
                    try w.writeAll("key ");
                    for (typed.bytes[0..typed.len]) |b| {
                        if (b >= 0x20 and b < 0x7f) try w.writeByte(b) else try w.print("\\x{x:0>2}", .{b});
                    }
                },
                .to_pane => |count| try w.print("{d} bytes typed into a pane", .{count}),
                .chord => |letter| if (letter == '\r') try w.writeAll("alt+enter") else try w.print("alt+{c}", .{letter}),
                .mode => try w.writeAll("ctrl+space"),
                .mouse => |m| try writeMouse(w, m),
            }
            try w.writeByte('\n');
        }
    }
};

fn writeMouse(w: *Writer, m: keys.Mouse) !void {
    const button = [_][]const u8{ "left", "middle", "right", "none" };
    try w.writeAll("mouse ");
    if (m.wheel()) {
        try w.writeAll(switch (m.code & 3) {
            0 => "wheel up",
            1 => "wheel down",
            2 => "wheel left",
            else => "wheel right",
        });
    } else if (m.hover()) {
        try w.writeAll("hover");
    } else if (m.motion()) {
        try w.print("drag {s}", .{button[m.code & 3]});
    } else try w.print("{s} {s}", .{ if (m.release) "release" else "press", button[m.code & 3] });
    if (m.code & 4 != 0) try w.writeAll(" +shift");
    if (m.code & 8 != 0) try w.writeAll(" +alt");
    if (m.code & 16 != 0) try w.writeAll(" +ctrl");
    try w.print(" at x={d} y={d}", .{ m.x, m.y });
}

/// How far from the pointer, in cells, the styles are listed.
const reach_x = 6;
const reach_y = 1;

/// The screen `frame` draws on a terminal `cols` by `rows`: every row as text, then the styles of
/// the cells around (`px`, `py`), run by run.
pub fn writeScreen(gpa: Allocator, io: std.Io, w: *Writer, frame: []const u8, cols: u16, rows: u16, px: u16, py: u16) !void {
    var term: vt.Terminal = try .init(io, gpa, .{ .cols = @max(1, cols), .rows = @max(1, rows), .max_scrollback_bytes = 0 });
    defer term.deinit(gpa);
    var stream = term.vtStream();
    defer stream.deinit();
    stream.nextSlice(frame);
    var state: vt.RenderState = .empty;
    defer state.deinit(gpa);
    try state.update(gpa, &term);
    const lines = state.row_data.items(.cells)[state.viewportStart()..];

    try w.writeAll("screen:\n");
    for (lines[0..@min(lines.len, rows)], 0..) |line, y| {
        try w.print("{d:>3}|", .{y});
        var end: usize = 0;
        var text: std.ArrayList(u8) = .empty;
        defer text.deinit(gpa);
        for (0..line.len) |x| {
            const raw = line.items(.raw)[x];
            if (raw.wide == .spacer_tail) continue;
            if (!raw.hasText()) {
                try text.append(gpa, ' ');
                continue;
            }
            try appendCodepoint(&text, gpa, raw.content.codepoint.data);
            if (raw.content_tag == .codepoint_grapheme) for (line.items(.grapheme)[x]) |cp| try appendCodepoint(&text, gpa, cp);
            end = text.items.len;
        }
        try w.print("{s}\n", .{text.items[0..end]});
    }

    try w.print("styles around the pointer (x={d}..{d}, y={d}..{d}):\n", .{ px -| reach_x, px + reach_x, py -| reach_y, py + reach_y });
    for (@min(py -| reach_y, lines.len)..@min(lines.len, @as(usize, py) + reach_y + 1)) |y| {
        const line = lines[y];
        var x: usize = px -| reach_x;
        const last = @min(line.len, @as(usize, px) + reach_x + 1);
        while (x < last) {
            const style = cellStyle(line, x);
            var end = x + 1;
            while (end < last and styleBits(cellStyle(line, end)) == styleBits(style)) end += 1;
            try w.print("  y={d} x={d}-{d} \"", .{ y, x, end - 1 });
            for (x..end) |at| {
                const raw = line.items(.raw)[at];
                if (raw.wide == .spacer_tail) continue;
                if (raw.hasText()) try w.printUnicodeCodepoint(@intCast(raw.content.codepoint.data)) else try w.writeByte(' ');
            }
            try w.writeAll("\" ");
            try writeStyle(w, style);
            try w.writeByte('\n');
            x = end;
        }
    }
}

fn appendCodepoint(text: *std.ArrayList(u8), gpa: Allocator, cp: u21) !void {
    var buf: [4]u8 = undefined;
    try text.appendSlice(gpa, buf[0..try std.unicode.utf8Encode(cp, &buf)]);
}

pub fn cellStyle(line: anytype, x: usize) vt.Style {
    const raw = line.items(.raw)[x];
    var style: vt.Style = if (raw.style_id != 0) line.items(.style)[x] else .{};
    switch (raw.content_tag) {
        .bg_color_palette => style.bg_color = .palette(raw.content.color_palette.data),
        .bg_color_rgb => style.bg_color = .rgb(.{ .r = raw.content.color_rgb.r, .g = raw.content.color_rgb.g, .b = raw.content.color_rgb.b }),
        else => {},
    }
    return style;
}

fn styleBits(style: vt.Style) u128 {
    return @bitCast(style);
}

fn writeColor(w: *Writer, c: vt.Style.Color) !void {
    switch (c.value()) {
        .none => try w.writeAll("-"),
        .palette => |idx| try w.print("p{d}", .{idx}),
        .rgb => |rgb| try w.print("#{x:0>2}{x:0>2}{x:0>2}", .{ rgb.r, rgb.g, rgb.b }),
    }
}

fn writeStyle(w: *Writer, style: vt.Style) !void {
    try w.writeAll("fg=");
    try writeColor(w, style.fg_color);
    try w.writeAll(" bg=");
    try writeColor(w, style.bg_color);
    inline for (.{ "bold", "italic", "faint", "inverse", "strikethrough" }) |flag| {
        if (@field(style.flags, flag)) try w.writeAll(" " ++ flag);
    }
    if (style.flags.underline != .none) try w.writeAll(" underline");
}

test "the trail keeps the last entries oldest first, one for a run of moves or typing" {
    var t: Trail = .{};
    t.push(100, .{ .mouse = .{ .code = 35, .x = 1, .y = 1, .release = false } });
    t.push(110, .{ .mouse = .{ .code = 35, .x = 2, .y = 1, .release = false } });
    t.push(120, .{ .mouse = .{ .code = 0, .x = 2, .y = 1, .release = false } });
    t.push(130, .{ .to_pane = 2 });
    t.push(140, .{ .to_pane = 3 });
    t.pushKeys(150, "\x1b[A");
    t.push(160, .{ .chord = '!' });

    var buf: [512]u8 = undefined;
    var w: Writer = .fixed(&buf);
    try t.write(&w, 200);
    try std.testing.expectEqualStrings(
        \\-90ms  mouse hover at x=2 y=1
        \\-80ms  mouse press left at x=2 y=1
        \\-60ms  5 bytes typed into a pane
        \\-50ms  key \x1b[A
        \\-40ms  alt+!
        \\
    , w.buffered());
}

test "the trail drops its oldest past what it keeps" {
    var t: Trail = .{};
    for (0..Trail.keep + 5) |i| t.push(@intCast(i), .{ .chord = 'j' });
    var buf: [4096]u8 = undefined;
    var w: Writer = .fixed(&buf);
    try t.write(&w, 1000);
    try std.testing.expect(std.mem.startsWith(u8, w.buffered(), "-995ms"));
    try std.testing.expectEqual(@as(usize, Trail.keep), std.mem.count(u8, w.buffered(), "\n"));
}

test "a screen is its rows as text, and the styles around the pointer run by run" {
    const gpa = std.testing.allocator;
    var out: Writer.Allocating = .init(gpa);
    defer out.deinit();
    try writeScreen(gpa, std.testing.io, &out.writer, "\x1b[Hab \x1b[4;38;5;4mcard\x1b[0m z\x1b[2;1Hnext", 20, 3, 5, 0);
    const text = out.written();

    try std.testing.expect(std.mem.indexOf(u8, text, "  0|ab card z\n  1|next\n  2|\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "y=0 x=0-2 \"ab \" fg=- bg=-\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "y=0 x=3-6 \"card\" fg=p4 bg=- underline\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "y=1 x=0-11 \"next        \" fg=- bg=-\n") != null);
}
