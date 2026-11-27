//! What the human asked of babylon's auto in its modal, held until babylon's file says it: drawn
//! at once, sent once its last press is `settle_ms` old, and put back if babylon refuses.
const std = @import("std");

/// How long a press waits for the next before its value is sent.
pub const settle_ms = 120;
/// How long a sent value is shown while babylon's file does not yet say it.
pub const trust_ms = 5000;

pub const Kind = enum { on, hold, cap, pause };

pub const Want = struct {
    kind: Kind,
    /// Of a cap, its repo; owned.
    repo: []u8,
    /// A switch's is 0 or 1.
    value: u32,
    /// When it is to be sent, and when it was; 0 for not yet.
    due: i64,
    sent_at: i64 = 0,

    /// The id babylon's refusal of this is written under.
    pub fn id(want: Want, buf: []u8) []const u8 {
        return switch (want.kind) {
            .on => "auto:on",
            .hold => "auto:hold",
            .pause => "auto:pause",
            .cap => std.fmt.bufPrint(buf, "auto:cap:{s}", .{want.repo}) catch "auto:cap",
        };
    }
};

pub const Wants = struct {
    list: std.ArrayList(Want) = .empty,
    /// The first line of babylon's last refusal, owned.
    refused: ?[]u8 = null,

    pub fn deinit(wants: *Wants, gpa: std.mem.Allocator) void {
        for (wants.list.items) |want| gpa.free(want.repo);
        wants.list.deinit(gpa);
        wants.clearRefused(gpa);
    }

    pub fn clearRefused(wants: *Wants, gpa: std.mem.Allocator) void {
        if (wants.refused) |text| gpa.free(text);
        wants.refused = null;
    }

    fn find(wants: *const Wants, kind: Kind, repo: []const u8) ?usize {
        for (wants.list.items, 0..) |want, i| {
            if (want.kind == kind and std.mem.eql(u8, want.repo, repo)) return i;
        }
        return null;
    }

    /// The value asked for and not yet in babylon's file.
    pub fn get(wants: *const Wants, kind: Kind, repo: []const u8) ?u32 {
        return (wants.list.items[wants.find(kind, repo) orelse return null]).value;
    }

    /// Asks for `value`, to be sent `settle_ms` after `now` unless asked again.
    pub fn set(wants: *Wants, gpa: std.mem.Allocator, kind: Kind, repo: []const u8, value: u32, now: i64) !void {
        wants.clearRefused(gpa);
        if (wants.find(kind, repo)) |i| {
            wants.list.items[i].value = value;
            wants.list.items[i].due = now + settle_ms;
            return;
        }
        const owned = try gpa.dupe(u8, repo);
        errdefer gpa.free(owned);
        try wants.list.append(gpa, .{ .kind = kind, .repo = owned, .value = value, .due = now + settle_ms });
    }

    /// Takes back what was asked: the board's value shows again.
    pub fn drop(wants: *Wants, gpa: std.mem.Allocator, i: usize) void {
        gpa.free(wants.list.items[i].repo);
        _ = wants.list.orderedRemove(i);
    }

    /// Babylon refused the value with id `id`: it goes, and `text` is what the modal says.
    pub fn refuse(wants: *Wants, gpa: std.mem.Allocator, id: []const u8, text: []const u8) !void {
        var buf: [96]u8 = undefined;
        for (wants.list.items, 0..) |want, i| {
            if (!std.mem.eql(u8, want.id(&buf), id)) continue;
            wants.drop(gpa, i);
            break;
        }
        const said = try gpa.dupe(u8, text);
        wants.clearRefused(gpa);
        wants.refused = said;
    }

    /// How long until the next value is due to be sent, 0 for one due now; null for none.
    pub fn nextDue(wants: *const Wants, now: i64) ?i64 {
        var soonest: ?i64 = null;
        for (wants.list.items) |want| {
            if (want.due == 0) continue;
            const left = @max(0, want.due - now);
            if (soonest == null or left < soonest.?) soonest = left;
        }
        return soonest;
    }
};

test "a value asked again before it is sent is one value, due again" {
    var wants: Wants = .{};
    defer wants.deinit(std.testing.allocator);
    try wants.set(std.testing.allocator, .cap, "arena", 3, 1000);
    try wants.set(std.testing.allocator, .cap, "arena", 4, 1050);
    try wants.set(std.testing.allocator, .cap, "tlon", 1, 1060);
    try std.testing.expectEqual(@as(usize, 2), wants.list.items.len);
    try std.testing.expectEqual(@as(?u32, 4), wants.get(.cap, "arena"));
    try std.testing.expectEqual(@as(?u32, null), wants.get(.on, ""));
    try std.testing.expectEqual(@as(i64, 1050 + settle_ms), wants.list.items[0].due);
    try std.testing.expectEqual(@as(?i64, settle_ms - 20), wants.nextDue(1070));
}

test "a refused value goes back to the board's and the modal says why" {
    var wants: Wants = .{};
    defer wants.deinit(std.testing.allocator);
    try wants.set(std.testing.allocator, .cap, "arena", 3, 0);
    try wants.set(std.testing.allocator, .hold, "", 1, 0);
    try wants.refuse(std.testing.allocator, "auto:cap:arena", "babylon: no such repo");
    try std.testing.expectEqual(@as(?u32, null), wants.get(.cap, "arena"));
    try std.testing.expectEqual(@as(?u32, 1), wants.get(.hold, ""));
    try std.testing.expectEqualStrings("babylon: no such repo", wants.refused.?);
    try wants.set(std.testing.allocator, .on, "", 1, 0);
    try std.testing.expect(wants.refused == null);
}
