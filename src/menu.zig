const std = @import("std");

pub const Action = enum {
    new_window,
    rename_window,
    move_left,
    move_right,
    full_width,
    close_window,
    split_right,
    split_below,
    browser,
    close_pane,
    search,
    new_session,
    rename_session,
    jump,
    overview,
    board,
    rail_width,
    detach,
    confirm_close,
    confirm_close_session,
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
    .{ .icon = "↔", .label = "Full width", .key = 'z', .action = .full_width },
    .{ .icon = "×", .label = "Close window", .key = 'x', .action = .close_window },
    .{ .icon = "◫", .label = "Split pane right", .key = 'v', .action = .split_right, .group = true },
    .{ .icon = "⊟", .label = "Split pane below", .key = 's', .action = .split_below },
    .{ .icon = "◎", .label = "Browser window", .key = 'b', .action = .browser },
    .{ .icon = "×", .label = "Close pane", .key = 'c', .action = .close_pane },
    .{ .icon = "/", .label = "Search history", .key = '/', .action = .search },
    .{ .icon = "◇", .label = "New session", .key = 'S', .action = .new_session, .group = true },
    .{ .icon = "✎", .label = "Rename session", .key = 'R', .action = .rename_session },
    .{ .icon = "→", .label = "Jump to window", .key = 'p', .action = .jump },
    .{ .icon = "▦", .label = "Overview", .key = 'o', .action = .overview },
    .{ .icon = "▤", .label = "Board", .key = 't', .action = .board },
    .{ .icon = "◧", .label = "Wide or narrow rail", .key = 'w', .action = .rail_width },
    .{ .icon = "⎋", .label = "Detach", .key = 'q', .action = .detach },
};

pub const confirm = [_]Item{
    .{ .icon = "×", .label = "Close it", .key = 'y', .action = .confirm_close },
    .{ .icon = "↩", .label = "Keep it", .key = 'n', .action = .cancel },
};

pub const confirm_session = [_]Item{
    .{ .icon = "×", .label = "Close it", .key = 'y', .action = .confirm_close_session },
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

/// The windows a jump prompt lists under its text.
pub const jump_rows = 8;

/// A line of text being typed: a new name, or part of the name of a window to jump to.
pub const Prompt = struct {
    what: What,
    buf: [48]u8 = undefined,
    len: usize = 0,
    /// Which of the windows listed under a jump prompt Enter goes to.
    selected: usize = 0,
    /// The last search found nothing.
    missed: bool = false,

    pub const What = enum { window, session, jump, search };
    pub const Result = enum { none, cancel, commit, up, down };

    /// Rows the box takes; the first of a jump prompt's windows is on row `list_row`.
    pub fn height(p: *const Prompt) u16 {
        return if (p.what == .jump) 9 + jump_rows else 8;
    }

    pub const list_row = 6;

    pub fn text(p: *const Prompt) []const u8 {
        return p.buf[0..p.len];
    }

    /// One key press: Enter commits, Escape cancels, Backspace takes a character back, and the
    /// arrows, Tab, Ctrl+N and Ctrl+P are `up` and `down`, for a list under the text.
    pub fn press(p: *Prompt, key: []const u8) Result {
        if (std.mem.eql(u8, key, "\r")) return .commit;
        if (std.mem.eql(u8, key, "\x1b")) return .cancel;
        for ([_][]const u8{ "\x1b[A", "\x1bOA", "\x10" }) |up| if (std.mem.eql(u8, key, up)) return .up;
        for ([_][]const u8{ "\x1b[B", "\x1bOB", "\x0e", "\t" }) |down| if (std.mem.eql(u8, key, down)) return .down;
        if (key.len != 1) return .none;
        const byte = key[0];
        if (byte == 0x7f or byte == 0x08) {
            p.selected = 0;
            while (p.len > 0) {
                p.len -= 1;
                if (p.buf[p.len] & 0xC0 != 0x80) break;
            }
        } else if (byte >= 0x20) {
            p.selected = 0;
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

/// How well `text` answers `query`, letter case aside: 0 when it holds it whole, 1 when it holds
/// its letters in order, null when it does neither.
pub fn fuzzy(query: []const u8, text: []const u8) ?u1 {
    if (std.ascii.findIgnoreCase(text, query) != null) return 0;
    var matched: usize = 0;
    for (text) |c| {
        if (matched < query.len and std.ascii.toLower(c) == std.ascii.toLower(query[matched])) matched += 1;
    }
    return if (matched == query.len) 1 else null;
}

test "a query matches whole, then as letters in order, whatever the case" {
    try std.testing.expectEqual(@as(?u1, 0), fuzzy("", "work claude"));
    try std.testing.expectEqual(@as(?u1, 0), fuzzy("CLAU", "work claude"));
    try std.testing.expectEqual(@as(?u1, 1), fuzzy("wkcl", "work claude"));
    try std.testing.expectEqual(@as(?u1, null), fuzzy("clw", "work claude"));
}

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
    try std.testing.expectEqual(Menu.Result.none, m.press("?"));
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
    try std.testing.expectEqual(Action.close_window, m.click(5, 9).act);
    try std.testing.expectEqual(Menu.Result.none, m.click(5, 10));
    try std.testing.expectEqual(Action.split_right, m.click(5, 11).act);
}

test "a prompt takes text, whole characters back, and no more than fits" {
    var p: Prompt = .{ .what = .window };
    for ("né") |byte| _ = p.press(&.{byte});
    try std.testing.expectEqualStrings("né", p.text());
    _ = p.press("\x7f");
    try std.testing.expectEqualStrings("n", p.text());
    try std.testing.expectEqual(Prompt.Result.up, p.press("\x1b[A"));
    try std.testing.expectEqual(Prompt.Result.down, p.press("\t"));
    try std.testing.expectEqual(Prompt.Result.none, p.press("\x1b[C"));
    for (0..100) |_| _ = p.press("a");
    try std.testing.expectEqual(@as(usize, 44), p.len);
    try std.testing.expectEqual(Prompt.Result.commit, p.press("\r"));
    try std.testing.expectEqual(Prompt.Result.cancel, p.press("\x1b"));
}
