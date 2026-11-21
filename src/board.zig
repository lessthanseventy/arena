//! babylon's board, from the file it keeps: the tickets every Claude on the machine shares.
const std = @import("std");

pub const Status = enum { todo, doing, review, done, backlog };
pub const statuses = [_]Status{ .todo, .doing, .review, .done };

/// A decision a session is waiting on its human for.
pub const Ask = struct {
    id: u32,
    question: []const u8,
    options: []const []const u8 = &.{},
};

pub const Card = struct {
    id: u32,
    repo: ?[]const u8 = null,
    title: []const u8,
    kind: []const u8 = "ticket",
    status: Status,
    priority: []const u8 = "med",
    /// The tmux pane holding it, as `%12`.
    claimed_by: ?[]const u8 = null,
    branch: ?[]const u8 = null,
    /// The open tickets it waits on.
    blocked_by: []const u32 = &.{},
    epic_id: ?u32 = null,
    /// Where it is on its way to main: queued, verifying, reviewing, landing, landed or failed.
    stage: ?[]const u8 = null,
    /// The question about it waiting on an answer, if there is one.
    ask: ?Ask = null,

    /// The id of the pane holding it, if one does.
    pub fn holder(card: *const Card) ?u32 {
        const pane = card.claimed_by orelse return null;
        if (pane.len < 2 or pane[0] != '%') return null;
        return std.fmt.parseInt(u32, pane[1..], 10) catch null;
    }
};

const File = struct { tickets: []const Card, backlog: []const Card = &.{} };

pub const Board = struct {
    parsed: std.json.Parsed(File),

    pub fn parse(gpa: std.mem.Allocator, text: []const u8) !Board {
        return .{ .parsed = try std.json.parseFromSlice(File, gpa, text, .{ .ignore_unknown_fields = true, .allocate = .alloc_always }) };
    }

    pub fn deinit(b: *Board) void {
        b.parsed.deinit();
    }

    pub fn cards(b: *const Board) []const Card {
        return b.parsed.value.tickets;
    }

    /// The cards waiting to be put on the board, by repo then board order.
    pub fn backlog(b: *const Board) []const Card {
        return b.parsed.value.backlog;
    }

    /// The cards babylon's pipeline is working on now (verifying, reviewing or landing), as many as
    /// fit in `out`; the count of them all.
    pub fn running(b: *const Board, out: []*const Card) usize {
        var n: usize = 0;
        for (b.cards()) |*card| {
            const stage = card.stage orelse continue;
            for ([_][]const u8{ "verifying", "reviewing", "landing" }) |busy| if (std.mem.eql(u8, stage, busy)) {
                if (n < out.len) out[n] = card;
                n += 1;
            };
        }
        return n;
    }

    /// The repos on the board, each once and in order of name, as many as fit in `out`.
    pub fn repos(b: *const Board, out: [][]const u8) usize {
        var n: usize = 0;
        for (b.cards()) |card| {
            const repo = card.repo orelse continue;
            const seen = for (out[0..n]) |had| {
                if (std.mem.eql(u8, had, repo)) break true;
            } else false;
            if (seen or n == out.len) continue;
            out[n] = repo;
            n += 1;
        }
        std.mem.sort([]const u8, out[0..n], {}, struct {
            fn before(_: void, a: []const u8, z: []const u8) bool {
                return std.mem.order(u8, a, z) == .lt;
            }
        }.before);
        return n;
    }

    /// The cards in `status`'s column, of `repo` alone when given, in board order with those
    /// waiting on others last, as many as fit in `out`; the count of them all.
    pub fn column(b: *const Board, status: Status, repo: ?[]const u8, out: []*const Card) usize {
        var n: usize = 0;
        for ([_]bool{ false, true }) |waiting| for (b.cards()) |*card| {
            if (card.status != status or (card.blocked_by.len > 0) != waiting) continue;
            if (repo) |only| if (!std.mem.eql(u8, card.repo orelse "", only)) continue;
            if (n < out.len) out[n] = card;
            n += 1;
        };
        return n;
    }
};

const sample =
    \\{"tickets":[
    \\{"id":3,"repo":"tlon","title":"House","kind":"ticket","status":"todo","priority":"low","labels":[],"claimed_by":null,"branch":null,"blocked_by":[],"epic_id":null},
    \\{"id":1,"repo":"arena","title":"Board","kind":"ticket","status":"doing","priority":"high","labels":["x"],"claimed_by":"%12","branch":"t1-board","blocked_by":[],"epic_id":null},
    \\{"id":2,"repo":"arena","title":"Rail","kind":"ticket","status":"todo","priority":"med","labels":[],"claimed_by":null,"branch":null,"blocked_by":[1],"epic_id":4},
    \\{"id":5,"repo":null,"title":"Loose","kind":"ticket","status":"todo","priority":"med","labels":[],"claimed_by":null,"branch":null,"blocked_by":[],"epic_id":null}
    \\]}
;

test "the board parses babylon's file, fields it does not draw left out" {
    var b = try Board.parse(std.testing.allocator, sample);
    defer b.deinit();
    try std.testing.expectEqual(@as(usize, 4), b.cards().len);
    try std.testing.expectEqual(@as(?u32, 12), b.cards()[1].holder());
    try std.testing.expectEqual(@as(?u32, null), b.cards()[0].holder());
    try std.testing.expectEqualSlices(u32, &.{1}, b.cards()[2].blocked_by);
}

test "a column is narrowed to one repo, in board order, those waiting last" {
    var b = try Board.parse(std.testing.allocator, sample);
    defer b.deinit();
    var out: [8]*const Card = undefined;
    try std.testing.expectEqual(@as(usize, 3), b.column(.todo, null, &out));
    try std.testing.expectEqual(@as(u32, 3), out[0].id);
    try std.testing.expectEqual(@as(u32, 2), out[2].id);
    try std.testing.expectEqual(@as(usize, 1), b.column(.todo, "arena", &out));
    try std.testing.expectEqual(@as(u32, 2), out[0].id);
    try std.testing.expectEqual(@as(usize, 0), b.column(.done, null, &out));
}

test "the backlog is its own list: the columns leave it out, and a file without one parses" {
    const gpa = std.testing.allocator;
    var b = try Board.parse(gpa,
        \\{"tickets":[{"id":1,"title":"a","status":"todo"}],"backlog":[{"id":7,"repo":"arena","title":"later","status":"backlog"}]}
    );
    defer b.deinit();
    try std.testing.expectEqual(@as(usize, 1), b.backlog().len);
    try std.testing.expectEqual(Status.backlog, b.backlog()[0].status);
    var out: [4]*const Card = undefined;
    for (statuses) |status| try std.testing.expectEqual(@as(usize, if (status == .todo) 1 else 0), b.column(status, null, &out));
    var old = try Board.parse(gpa, sample);
    defer old.deinit();
    try std.testing.expectEqual(@as(usize, 0), old.backlog().len);
}

test "the cards the pipeline is working on are those verifying, reviewing or landing" {
    const gpa = std.testing.allocator;
    var idle = try Board.parse(gpa,
        \\{"tickets":[{"id":1,"title":"a","status":"review","stage":"queued"},{"id":2,"title":"b","status":"doing","stage":"failed"}]}
    );
    defer idle.deinit();
    var out: [2]*const Card = undefined;
    try std.testing.expectEqual(@as(usize, 0), idle.running(&out));
    var busy = try Board.parse(gpa,
        \\{"tickets":[{"id":1,"title":"a","status":"review","stage":"queued"},{"id":3,"title":"c","status":"review","stage":"reviewing"},{"id":4,"title":"d","status":"review","stage":"verifying"}]}
    );
    defer busy.deinit();
    try std.testing.expectEqual(@as(usize, 2), busy.running(&out));
    try std.testing.expectEqual(@as(u32, 3), out[0].id);
    try std.testing.expectEqual(@as(u32, 4), out[1].id);
}

test "the repos are each named once, in order" {
    var b = try Board.parse(std.testing.allocator, sample);
    defer b.deinit();
    var out: [8][]const u8 = undefined;
    const n = b.repos(&out);
    try std.testing.expectEqual(@as(usize, 2), n);
    try std.testing.expectEqualStrings("arena", out[0]);
    try std.testing.expectEqualStrings("tlon", out[1]);
}
