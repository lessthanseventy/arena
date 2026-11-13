const std = @import("std");

pub const Action = enum {
    new_window,
    rename_window,
    move_left,
    move_right,
    close_window,
    split_right,
    split_below,
    close_pane,
    new_session,
    rename_session,
    detach,
    confirm_close,
    cancel,
};

pub const Item = struct {
    /// One cell wide.
    icon: []const u8,
    label: []const u8,
    /// The key that picks this item while the menu is open.
    key: u8,
    action: Action,
    /// The first of a group: a rule is drawn above it.
    group: bool = false,
};

pub const main = [_]Item{
    .{ .icon = "+", .label = "New window", .key = 'n', .action = .new_window },
    .{ .icon = "✎", .label = "Rename window", .key = 'r', .action = .rename_window },
    .{ .icon = "←", .label = "Move window left", .key = 'H', .action = .move_left },
    .{ .icon = "→", .label = "Move window right", .key = 'L', .action = .move_right },
    .{ .icon = "×", .label = "Close window", .key = 'x', .action = .close_window },
    .{ .icon = "◫", .label = "Split pane right", .key = 'v', .action = .split_right, .group = true },
    .{ .icon = "⊟", .label = "Split pane below", .key = 's', .action = .split_below },
    .{ .icon = "×", .label = "Close pane", .key = 'c', .action = .close_pane },
    .{ .icon = "◇", .label = "New session", .key = 'S', .action = .new_session, .group = true },
    .{ .icon = "✎", .label = "Rename session", .key = 'R', .action = .rename_session },
    .{ .icon = "⎋", .label = "Detach", .key = 'q', .action = .detach },
};

pub const confirm = [_]Item{
    .{ .icon = "×", .label = "Close it", .key = 'y', .action = .confirm_close },
    .{ .icon = "↩", .label = "Keep it", .key = 'n', .action = .cancel },
};

pub const width = 38;
/// Above the items: the border, a blank row, the heading and another blank row.
const first_row = 4;

pub const Menu = struct {
    items: []const Item,
    selected: usize = 0,

    pub const Result = union(enum) { none, close, act: Action };

    /// Rows the box takes: under the last item a blank row, the key hints and the border.
    pub fn height(m: Menu) u16 {
        return m.row(m.items.len - 1) + 4;
    }

    /// The row of the box an item is on.
    pub fn row(m: Menu, index: usize) u16 {
        var at: usize = first_row + index;
        for (m.items[0 .. index + 1]) |item| at += @intFromBool(item.group);
        return @intCast(at);
    }

    /// One key press, as the terminal sent it: j, k and the arrows move, Enter picks, an item's
    /// own key picks it, Escape closes.
    pub fn press(m: *Menu, key: []const u8) Result {
        const down = std.mem.eql(u8, key, "j") or std.mem.eql(u8, key, "\x1b[B") or std.mem.eql(u8, key, "\x1bOB");
        const up = std.mem.eql(u8, key, "k") or std.mem.eql(u8, key, "\x1b[A") or std.mem.eql(u8, key, "\x1bOA");
        if (down) m.selected = (m.selected + 1) % m.items.len;
        if (up) m.selected = (m.selected + m.items.len - 1) % m.items.len;
        if (down or up) return .none;
        if (std.mem.eql(u8, key, "\r")) return .{ .act = m.items[m.selected].action };
        if (std.mem.eql(u8, key, "\x1b")) return .close;
        if (key.len == 1) for (m.items) |item| {
            if (item.key == key[0]) return .{ .act = item.action };
        };
        return .none;
    }

    /// A click at (`x`, `y`) of the box, from its top left corner: an item's row picks it.
    pub fn click(m: Menu, x: usize, y: usize) Result {
        if (x == 0 or x >= width - 1) return .none;
        for (m.items, 0..) |item, i| if (m.row(i) == y) return .{ .act = item.action };
        return .none;
    }
};

/// A line of text being typed, for a new name.
pub const Prompt = struct {
    what: What,
    buf: [48]u8 = undefined,
    len: usize = 0,

    pub const What = enum { window, session };
    pub const Result = enum { none, cancel, commit };
    pub const height = 8;

    pub fn text(p: *const Prompt) []const u8 {
        return p.buf[0..p.len];
    }

    /// One key press: Enter commits, Escape cancels, Backspace takes a character back.
    pub fn press(p: *Prompt, key: []const u8) Result {
        if (std.mem.eql(u8, key, "\r")) return .commit;
        if (std.mem.eql(u8, key, "\x1b")) return .cancel;
        if (key.len != 1) return .none;
        const byte = key[0];
        if (byte == 0x7f or byte == 0x08) {
            while (p.len > 0) {
                p.len -= 1;
                if (p.buf[p.len] & 0xC0 != 0x80) break;
            }
        } else if (byte >= 0x20) {
            // room is kept for the rest of a character begun before the end
            const continues = byte & 0xC0 == 0x80;
            if (p.len < if (continues) p.buf.len else p.buf.len - 4) {
                p.buf[p.len] = byte;
                p.len += 1;
            }
        }
        return .none;
    }
};

test "keys move with wrapping, pick, and close" {
    var m: Menu = .{ .items = &main };
    try std.testing.expectEqual(Menu.Result.none, m.press("k"));
    try std.testing.expectEqual(main.len - 1, m.selected);
    _ = m.press("\x1b[B");
    try std.testing.expectEqual(@as(usize, 0), m.selected);
    _ = m.press("j");
    try std.testing.expectEqual(Action.rename_window, m.press("\r").act);
    try std.testing.expectEqual(Action.new_session, m.press("S").act);
    try std.testing.expectEqual(Menu.Result.close, m.press("\x1b"));
    try std.testing.expectEqual(Menu.Result.none, m.press("z"));
}

test "a click picks the item on its row; rules, padding and border pick nothing" {
    const c: Menu = .{ .items = &confirm };
    try std.testing.expectEqual(Action.confirm_close, c.click(5, 4).act);
    try std.testing.expectEqual(Action.cancel, c.click(5, 5).act);
    try std.testing.expectEqual(Menu.Result.none, c.click(5, 0));
    try std.testing.expectEqual(Menu.Result.none, c.click(5, 2));
    try std.testing.expectEqual(Menu.Result.none, c.click(5, 6));
    try std.testing.expectEqual(Menu.Result.none, c.click(0, 4));
    try std.testing.expectEqual(@as(u16, 9), c.height());

    const m: Menu = .{ .items = &main };
    try std.testing.expectEqual(Action.close_window, m.click(5, 8).act);
    try std.testing.expectEqual(Menu.Result.none, m.click(5, 9));
    try std.testing.expectEqual(Action.split_right, m.click(5, 10).act);
}

test "a prompt takes text, whole characters back, and no more than fits" {
    var p: Prompt = .{ .what = .window };
    for ("né") |byte| _ = p.press(&.{byte});
    try std.testing.expectEqualStrings("né", p.text());
    _ = p.press("\x7f");
    try std.testing.expectEqualStrings("n", p.text());
    try std.testing.expectEqual(Prompt.Result.none, p.press("\x1b[A"));
    for (0..100) |_| _ = p.press("a");
    try std.testing.expectEqual(@as(usize, 44), p.len);
    try std.testing.expectEqual(Prompt.Result.commit, p.press("\r"));
    try std.testing.expectEqual(Prompt.Result.cancel, p.press("\x1b"));
}
