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
    /// When it was claimed, as `2026-11-21T23:20:05Z`.
    claimed_at: ?[]const u8 = null,
    branch: ?[]const u8 = null,
    /// The open tickets it waits on.
    blocked_by: []const u32 = &.{},
    epic_id: ?u32 = null,
    /// Where it is on its way to main: queued, verifying, reviewing, landing, landed or failed.
    stage: ?[]const u8 = null,
    /// The question about it waiting on an answer, if there is one.
    ask: ?Ask = null,
    /// Why babylon left its Claude running once it landed, empty when there is nothing to say:
    /// one line, safe to draw.
    session_note: []const u8 = "",

    /// The id of the pane holding it, if one does.
    pub fn holder(card: *const Card) ?u32 {
        const pane = card.claimed_by orelse return null;
        if (pane.len < 2 or pane[0] != '%') return null;
        return std.fmt.parseInt(u32, pane[1..], 10) catch null;
    }

    /// When it was claimed, in seconds since the epoch, if babylon says when.
    pub fn claimedAt(card: *const Card) ?i64 {
        const at = card.claimed_at orelse return null;
        if (at.len < 19) return null;
        const int = std.fmt.parseInt;
        const year = int(i64, at[0..4], 10) catch return null;
        const month = int(i64, at[5..7], 10) catch return null;
        const day = int(i64, at[8..10], 10) catch return null;
        const hour = int(i64, at[11..13], 10) catch return null;
        const minute = int(i64, at[14..16], 10) catch return null;
        const second = int(i64, at[17..19], 10) catch return null;
        // days from the civil date, the year counted from March so a leap day ends it
        const y = if (month <= 2) year - 1 else year;
        const era = @divFloor(y, 400);
        const of_era = y - era * 400;
        const of_year = @divFloor(153 * (if (month > 2) month - 3 else month + 9) + 2, 5) + day - 1;
        const days = era * 146097 + of_era * 365 + @divFloor(of_era, 4) - @divFloor(of_era, 100) + of_year - 719468;
        return days * 86400 + hour * 3600 + minute * 60 + second;
    }
};

/// babylon's auto mode: while on, it starts a Claude on each free todo card until `cap` are working.
pub const Auto = struct { on: bool = false, cap: u32 = 0, working: u32 = 0 };

/// babylon's orchestrator: `running` while its session is there, `on` while babylon keeps it so.
pub const Orchestrator = struct { on: bool = true, running: bool = true };

const File = struct { tickets: []Card, backlog: []const Card = &.{}, auto: ?Auto = null, orchestrator: ?Orchestrator = null };

pub const Board = struct {
    parsed: std.json.Parsed(File),

    pub fn parse(gpa: std.mem.Allocator, text: []const u8) !Board {
        var parsed = try std.json.parseFromSlice(File, gpa, text, .{ .ignore_unknown_fields = true, .allocate = .alloc_always });
        errdefer parsed.deinit();
        for (parsed.value.tickets) |*card| {
            if (card.session_note.len == 0) continue;
            var clean: std.ArrayList(u8) = .empty;
            try @import("app.zig").appendClean(&clean, parsed.arena.allocator(), card.session_note);
            std.mem.replaceScalar(u8, clean.items, '\n', ' ');
            card.session_note = clean.items;
        }
        return .{ .parsed = parsed };
    }

    pub fn deinit(b: *Board) void {
        b.parsed.deinit();
    }

    pub fn cards(b: *const Board) []const Card {
        return b.parsed.value.tickets;
    }

    /// Auto mode's cap and the Claudes working, while it is on.
    pub fn auto(b: *const Board) ?Auto {
        const state = b.parsed.value.auto orelse return null;
        return if (state.on) state else null;
    }

    /// What babylon says of its orchestrator, when its file does.
    pub fn orchestrator(b: *const Board) ?Orchestrator {
        return b.parsed.value.orchestrator;
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
    \\{"id":5,"repo":null,"title":"Loose","kind":"ticket","status":"todo","priority":"med","labels":[],"claimed_by":null,"branch":null,"blocked_by":[],"epic_id":null,"session_note":"its session is left running: it holds #6"}
    \\]}
;

test "the board parses babylon's file, fields it does not draw left out" {
    var b = try Board.parse(std.testing.allocator, sample);
    defer b.deinit();
    try std.testing.expectEqual(@as(usize, 4), b.cards().len);
    try std.testing.expectEqual(@as(?u32, 12), b.cards()[1].holder());
    try std.testing.expectEqual(@as(?u32, null), b.cards()[0].holder());
    try std.testing.expectEqualSlices(u32, &.{1}, b.cards()[2].blocked_by);
    try std.testing.expectEqualStrings("its session is left running: it holds #6", b.cards()[3].session_note);
    try std.testing.expectEqualStrings("", b.cards()[0].session_note);
}

test "a note's escapes and control characters are gone once the board is parsed, and it is one line" {
    var b = try Board.parse(std.testing.allocator,
        \\{"tickets":[{"id":1,"title":"Board","status":"done","session_note":"\u001b[31mit holds\u0007\n#6\u001b]0;t\u0007"}]}
    );
    defer b.deinit();
    try std.testing.expectEqualStrings("it holds #6", b.cards()[0].session_note);
}

test "a claim's time is read as seconds since the epoch, and one unsaid or unread is none" {
    var card: Card = .{ .id = 1, .title = "Board", .status = .doing };
    try std.testing.expectEqual(@as(?i64, null), card.claimedAt());
    card.claimed_at = "2026-11-21T23:20:05Z";
    try std.testing.expectEqual(@as(?i64, 1795303205), card.claimedAt());
    card.claimed_at = "2024-02-29T00:00:00Z";
    try std.testing.expectEqual(@as(?i64, 1709164800), card.claimedAt());
    card.claimed_at = "soon";
    try std.testing.expectEqual(@as(?i64, null), card.claimedAt());
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

test "auto mode is read while on, and a file without it or with it off has none" {
    const gpa = std.testing.allocator;
    var on = try Board.parse(gpa,
        \\{"tickets":[],"auto":{"on":true,"cap":2,"working":1}}
    );
    defer on.deinit();
    try std.testing.expectEqual(@as(u32, 2), on.auto().?.cap);
    try std.testing.expectEqual(@as(u32, 1), on.auto().?.working);
    var off = try Board.parse(gpa,
        \\{"tickets":[],"auto":{"on":false,"cap":2,"working":0}}
    );
    defer off.deinit();
    try std.testing.expectEqual(@as(?Auto, null), off.auto());
    var old = try Board.parse(gpa, sample);
    defer old.deinit();
    try std.testing.expectEqual(@as(?Auto, null), old.auto());
}

test "the orchestrator's state is read as babylon gives it, and a file without it has none" {
    const gpa = std.testing.allocator;
    var kept_off = try Board.parse(gpa,
        \\{"tickets":[],"orchestrator":{"on":false,"running":false}}
    );
    defer kept_off.deinit();
    try std.testing.expectEqual(@as(?Orchestrator, .{ .on = false, .running = false }), kept_off.orchestrator());
    var old = try Board.parse(gpa, sample);
    defer old.deinit();
    try std.testing.expectEqual(@as(?Orchestrator, null), old.orchestrator());
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
