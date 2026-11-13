const std = @import("std");

pub const Action = enum { new_window, close_window, new_session, detach, confirm_close, cancel };

pub const Item = struct {
    label: []const u8,
    /// The key that picks this item while the menu is open.
    key: u8,
    action: Action,
};

pub const main = [_]Item{
    .{ .label = "New window", .key = 'n', .action = .new_window },
    .{ .label = "Close window", .key = 'x', .action = .close_window },
    .{ .label = "New session", .key = 's', .action = .new_session },
    .{ .label = "Detach", .key = 'q', .action = .detach },
};

pub const confirm = [_]Item{
    .{ .label = "Close it", .key = 'y', .action = .confirm_close },
    .{ .label = "Keep it", .key = 'n', .action = .cancel },
};

pub const width = 30;

pub const Menu = struct {
    items: []const Item,
    selected: usize = 0,

    pub const Result = union(enum) { none, close, act: Action };

    /// Rows the box takes: its items and a border above and below.
    pub fn height(m: Menu) u16 {
        return @intCast(m.items.len + 2);
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
        if (x == 0 or x >= width - 1 or y == 0 or y > m.items.len) return .none;
        return .{ .act = m.items[y - 1].action };
    }
};

test "keys move with wrapping, pick, and close" {
    var m: Menu = .{ .items = &main };
    try std.testing.expectEqual(Menu.Result.none, m.press("k"));
    try std.testing.expectEqual(main.len - 1, m.selected);
    _ = m.press("\x1b[B");
    try std.testing.expectEqual(@as(usize, 0), m.selected);
    _ = m.press("j");
    try std.testing.expectEqual(Action.close_window, m.press("\r").act);
    try std.testing.expectEqual(Action.new_session, m.press("s").act);
    try std.testing.expectEqual(Menu.Result.close, m.press("\x1b"));
    try std.testing.expectEqual(Menu.Result.none, m.press("z"));
}

test "a click picks the item on its row, and the border nothing" {
    const m: Menu = .{ .items = &confirm };
    try std.testing.expectEqual(Action.confirm_close, m.click(5, 1).act);
    try std.testing.expectEqual(Action.cancel, m.click(5, 2).act);
    try std.testing.expectEqual(Menu.Result.none, m.click(5, 0));
    try std.testing.expectEqual(Menu.Result.none, m.click(5, 3));
    try std.testing.expectEqual(Menu.Result.none, m.click(0, 1));
}
