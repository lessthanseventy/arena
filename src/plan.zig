//! Home's plan: babylon's `plan` laid out as rows to draw, and the pick over the rows that can be
//! picked. Everything shown is what babylon gave; the only thing worked out here is how it folds.
const std = @import("std");
const tickets = @import("board.zig");
const text_mod = @import("text.zig");

pub const max_rows = 160;

/// The pipeline's stages in the order in flight lists them; queued goes by place.
const stages = [_][]const u8{ "landing", "reviewing", "verifying", "queued" };
/// The tickets of next that are drawn; the rest are `+N`.
const next_shown = 7;
/// The tickets of next a folded window names.
const next_summary = 5;

/// Rows kept past the goals for the foot: a gap, not planned's head and row, a gap, landed.
const foot_rows = 5;
/// Rows kept past the goals for the ideas: a gap, their rule, and three rows or the fold.
const idea_rows = 5;
/// Ideas shown a row each; past it they fold to one row.
const ideas_shown = 3;
/// The bit of `unfolded` that holds the ideas open.
pub const ideas_fold: u3 = 0;

pub const Kind = enum { head, blank, other, need, need_card, now, next, why, more, goals_more, goal, landed, unplanned, chips, todo, backlog, focal, drove, card_top, goal_bar, goal_next, goal_block, idea, ideas_more, summary, note, buttons, held };
pub const Style = enum { normal, dim, heading, attention };

/// Workbench's plan is six windows, each a fixed slot of the screen.
pub const Window = enum {
    move,
    driving,
    now,
    next,
    goals,
    unplanned,
    landed,

    pub fn title(win: Window) []const u8 {
        return switch (win) {
            .move => "your move",
            .driving => "driving towards",
            .now => "in flight",
            .unplanned => "not planned",
            else => @tagName(win),
        };
    }
};

pub const Shut = std.EnumSet(Window);

/// The ticket open in each window, 0 for none: one at a time.
pub const Open = std.EnumArray(Window, u32);

pub const Rect = struct { x: u16, y: u16, w: u16, h: u16 };

/// Rows of a window's slot that are not its body: the title bar, and the shadow's row.
pub const window_chrome = 2;
const driving_h = 5;

/// Under this many rows the windows above the lists keep one body row each, so not planned and
/// the rest keep rows of theirs.
const short_area = 26;

/// Rows Your move's slot shows at full width and at half: whatever it holds, its slot is this tall.
pub const move_rows_full = 5;
pub const move_rows_half = 3;

/// Where `win` sits on a plan area `w` by `h` cells, Your move showing `move_rows`: its title
/// bar, body and shadow. Worked out from the area alone, so nothing in a window or its fold
/// moves another.
pub fn slot(win: Window, w: u16, h: u16, move_rows: u16) Rect {
    // on a short screen Your move gives rows to the windows under it, down to one
    const shown: u16 = if (h < short_area) @as(u16, 1) else move_rows;
    const move_h = @min(shown + window_chrome, h);
    const drive_h = @min(@as(u16, if (h < short_area) driving_h - 2 else driving_h), h - move_h);
    const top = move_h + drive_h;
    const rest = h - top;
    const half = w * 3 / 5;
    return switch (win) {
        .move => .{ .x = 0, .y = 0, .w = w, .h = move_h },
        .driving => .{ .x = 0, .y = move_h, .w = w, .h = drive_h },
        .now => .{ .x = 0, .y = top, .w = half, .h = rest * 6 / 10 },
        .next => .{ .x = 0, .y = top + rest * 6 / 10, .w = half, .h = rest - rest * 6 / 10 },
        .goals => .{ .x = half, .y = top, .w = w - half, .h = rest * 4 / 10 },
        .unplanned => .{ .x = half, .y = top + rest * 4 / 10, .w = w - half, .h = rest * 3 / 10 },
        .landed => .{ .x = half, .y = top + rest * 7 / 10, .w = w - half, .h = rest - rest * 7 / 10 },
    };
}

/// The first of `len` rows a window of `body` rows shows, the row at `at` kept in view with the
/// rest of its card (two rows) below it.
pub fn windowTop(at: usize, len: usize, body: usize) usize {
    return @min((at + 3) -| body, len -| body);
}

pub const Row = struct {
    kind: Kind,
    /// Its place among the rows that can be picked; none for a heading, a why line or a gap.
    pick: ?usize = null,
    ticket: ?u32 = null,
    /// Of a row that unfolds more: which bit of `unfolded` it is.
    fold: ?u3 = null,
    style: Style = .normal,
    text: []const u8 = "",
    /// Where `text`'s tail begins, drawn in `tail_style`: the state of a now row, what a next
    /// item waits on.
    tail_at: usize = std.math.maxInt(usize),
    tail_style: Style = .dim,
    /// Workbench's rows are drawn from the plan itself: the index of the item among its list
    /// (now, next or goals), which of a focal window's rows this is, and a head's count.
    item: usize = 0,
    part: u8 = 0,
    count: usize = 0,
    /// Workbench's window the row is in.
    win: Window = .now,
    /// A row `narrow` left in place but that does not hold what is found: drawn dim, never picked.
    dim: bool = false,
};

/// The goal Home puts in the focal window: the one the human picked to drive towards; with no
/// pick, the first with a step being built, else the first not yet landed whole.
pub fn focalGoal(given: *const tickets.Plan) ?usize {
    const goals = given.goals;
    if (given.driving) |epic| for (goals, 0..) |goal, i| {
        if (goal.epic == epic) return i;
    };
    for (goals, 0..) |goal, i| for (goal.steps) |step| {
        if (std.mem.eql(u8, step.state, "building")) return i;
    };
    for (goals, 0..) |goal, i| if (goal.landed < goal.total) return i;
    return null;
}

/// The Your move item asking for the next goal, when the goal driven towards has landed: it is
/// driving, no longer among the open goals, and babylon asks.
pub fn driveLanded(given: *const tickets.Plan, b: *const tickets.Board) ?*const tickets.Need {
    const epic = given.driving orelse return null;
    for (given.goals) |goal| if (goal.epic == epic) return null;
    return b.driveNeed();
}

/// The focal window's title: whether the goal is the human's pick, or has landed.
pub fn drivingTitle(given: *const tickets.Plan, b: *const tickets.Board) []const u8 {
    if (driveLanded(given, b) != null) return "driving towards · landed";
    return if (given.driving != null) "driving towards · your pick" else "driving towards · d to pick";
}

fn drivenTitle(b: *const tickets.Board, need: *const tickets.Need, epic: u32) []const u8 {
    for (b.cards()) |card| if (card.id == epic) return card.title;
    return need.text;
}

/// A button under a landed goal: the drive item's action `at`, numbered; one past them
/// is `+ a new goal`.
pub fn driveButton(buf: []u8, need: *const tickets.Need, at: usize) []const u8 {
    if (at < need.actions.len) return std.fmt.bufPrint(buf, "{d} {s}", .{ at + 1, need.actions[at].label }) catch "";
    return "+ a new goal";
}

/// Which button of the landed window's row (`x0` its left edge) is under `x`: an action's place
/// in the drive item, or `need.actions.len` for `+ a new goal`.
pub fn driveButtonAt(need: *const tickets.Need, x0: usize, x: usize) ?usize {
    var at = x0 + 2;
    for (0..need.actions.len + 1) |i| {
        var buf: [96]u8 = undefined;
        const w = text_mod.cells(driveButton(&buf, need, i)) + 2;
        if (x >= at and x < at + w) return i;
        at += w + 1;
    }
    return null;
}

/// Whether a step is moving, next, or sent back, as opposed to landed or still waiting.
pub fn inFlight(step: tickets.Step) bool {
    const mark = Sheet.stepMark(step.state);
    return !std.mem.eql(u8, mark, "✓") and !std.mem.eql(u8, mark, "○");
}

/// How many of a goal's steps have landed and wait on the human to try.
pub fn goalTrying(goal: tickets.Goal) usize {
    var n: usize = 0;
    for (goal.steps) |step| n += @intFromBool(std.mem.eql(u8, step.state, "to_try"));
    return n;
}

/// A goal's next step: the first being built, else landing, else next, else the first waiting.
pub fn goalNext(goal: tickets.Goal) ?tickets.Step {
    for ([_][]const u8{ "◐", "◒", "●", "○" }) |want| for (goal.steps) |step| {
        if (std.mem.eql(u8, Sheet.stepMark(step.state), want)) return step;
    };
    return null;
}

/// The first step of a goal that waits on a ticket, and that ticket.
pub fn goalBlock(goal: tickets.Goal) ?struct { step: u32, on: u32 } {
    for (goal.steps) |step| for (step.waits_on) |wait| if (wait.ticket) |on| return .{ .step = step.ticket, .on = on };
    return null;
}

/// What not planned shows: the repos folded to their chips, and the backlog in the rows' place.
pub const See = struct {
    repos_shut: []const []const u8 = &.{},
    backlog: bool = false,
};

pub const max_chips = 16;

/// A chip of not planned's top row: a repo's with its count of todo tickets, or the backlog's.
pub const Chip = struct { x: usize, w: usize, repo: ?[]const u8, n: usize };

/// The chips of not planned's top row, from `x0`, as many as fit in `width` cells: a repo's each,
/// then the backlog's.
pub fn chipsAt(given: *const tickets.Plan, backlog_n: usize, x0: usize, width: usize, out: []Chip) []Chip {
    var n: usize = 0;
    var x = x0;
    const not = given.not_planned;
    for (not.by_repo.map.keys(), not.by_repo.map.values()) |name, count| {
        const w = chipWidth(name, count);
        if (n == out.len or x + w > x0 + width) return out[0..n];
        out[n] = .{ .x = x, .w = w, .repo = name, .n = count };
        n += 1;
        x += w + 1;
    }
    const w = chipWidth("backlog", backlog_n) - 2;
    if (n < out.len and x + w <= x0 + width) {
        out[n] = .{ .x = x, .w = w, .repo = null, .n = backlog_n };
        n += 1;
    }
    return out[0..n];
}

/// A chip's cells: its icon and name and count, and the chip's own two.
fn chipWidth(name: []const u8, count: usize) usize {
    var digits: [12]u8 = undefined;
    const n = std.fmt.bufPrint(&digits, "{d}", .{count}) catch "";
    return 2 + text_mod.cells(name) + 1 + n.len + 2;
}

pub const Sheet = struct {
    rows: [max_rows]Row = undefined,
    n: usize = 0,
    picks: usize = 0,
    /// Half a screen's plan: the pipeline folded to counts, next without its whys, goals without names.
    narrow: bool = false,
    /// Workbench's rows: a goal a card of rows, and the focal window first.
    bench: bool = false,
    buf: [32 * 1024]u8 = undefined,
    used: usize = 0,
    /// Workbench's windows folded to their summary, and the one rows are being added to.
    shut: Shut = undefined,
    cur: Window = .driving,
    from: usize = 0,

    /// The rows of `win`: where they start and how many.
    pub fn span(s: *const Sheet, win: Window) struct { start: usize, len: usize } {
        var start: usize = s.n;
        var len: usize = 0;
        for (s.rows[0..s.n], 0..) |row, i| if (row.win == win) {
            if (len == 0) start = i;
            len += 1;
        };
        return .{ .start = start, .len = len };
    }

    /// A row of the card's buttons under each ticket row that is open in its window, after the
    /// why a next row has; it is no pick, so the picks stay where they were.
    pub fn withButtons(s: *Sheet, open: Open) void {
        var after: [max_rows]u32 = @splat(0);
        var extra: usize = 0;
        for (s.rows[0..s.n], 0..) |row, i| {
            const owner = if (row.kind == .why and i > 0 and s.rows[i - 1].kind == .next) s.rows[i - 1] else row;
            if (owner.kind != .now and owner.kind != .next and owner.kind != .todo and owner.kind != .backlog) continue;
            const ticket = owner.ticket orelse continue;
            if (open.get(owner.win) != ticket) continue;
            const why_follows = owner.kind == .next and row.kind != .why and i + 1 < s.n and s.rows[i + 1].kind == .why;
            if (why_follows) continue;
            after[i] = ticket;
            extra += 1;
        }
        if (extra == 0 or s.n + extra > max_rows) return;
        var j = s.n + extra;
        var i = s.n;
        while (i > 0) {
            i -= 1;
            if (after[i] != 0) {
                j -= 1;
                s.rows[j] = .{ .kind = .buttons, .ticket = after[i], .win = s.rows[i].win };
            }
            j -= 1;
            s.rows[j] = s.rows[i];
        }
        s.n += extra;
    }

    /// Rows of the whole card under the Your move row that is open: its question, its buttons and,
    /// for a to-try item, a row for each check. They are no picks.
    pub fn withNeedCards(s: *Sheet, open: Open, b: *const tickets.Board) void {
        const ticket = open.get(.move);
        if (ticket == 0) return;
        var from: ?usize = null;
        for (s.rows[0..s.n], 0..) |row, i| if (row.kind == .need and row.ticket == ticket) {
            from = i;
            break;
        };
        const at = from orelse return;
        const need = b.needsYou()[s.rows[at].item];
        const extra = 2 + need.steps.len;
        if (s.n + extra > max_rows) return;
        std.mem.copyBackwards(Row, s.rows[at + 1 + extra .. s.n + extra], s.rows[at + 1 .. s.n]);
        for (0..extra) |part| {
            s.rows[at + 1 + part] = .{ .kind = .need_card, .ticket = ticket, .item = s.rows[at].item, .part = @intCast(part + 1), .win = .move };
        }
        s.n += extra;
    }

    /// A second line under each in-flight row whose Claude's pane `known` has, for its workspace
    /// chip; it is no pick, so the picks stay where they were.
    pub fn withHeld(s: *Sheet, given: *const tickets.Plan, known: anytype) void {
        var extra: usize = 0;
        var has: [max_rows]bool = @splat(false);
        for (s.rows[0..s.n], 0..) |row, i| {
            if (row.kind != .now) continue;
            const pane = given.now[row.item].holder() orelse continue;
            if (!known.has(pane)) continue;
            has[i] = true;
            extra += 1;
        }
        if (extra == 0 or s.n + extra > max_rows) return;
        var j = s.n + extra;
        var i = s.n;
        while (i > 0) {
            i -= 1;
            j -= 1;
            s.rows[j] = s.rows[i];
            if (has[i]) {
                const owner = s.rows[j];
                s.rows[j] = .{ .kind = .held, .ticket = owner.ticket, .item = owner.item, .win = owner.win };
                j -= 1;
                s.rows[j] = owner;
            }
        }
        s.n += extra;
    }

    /// A rule `other Claudes N` and a pick for each of the `n` Claudes with no ticket, at the foot
    /// of in flight's rows, where its `none` stood. `item` of a row is its place among them. A
    /// Claude holds no title, so a `find` leaves its row dim and out of the picks.
    pub fn withOthers(s: *Sheet, n: usize, find: []const u8) void {
        if (n == 0 or !s.bench or s.shut.contains(.now)) return;
        var foot: usize = 0;
        for (s.rows[0..s.n], 0..) |row, i| {
            if (row.win == .now) foot = i + 1;
        }
        const placeholder = foot > 0 and s.rows[foot - 1].kind == .note and s.rows[foot - 1].win == .now;
        if (placeholder) foot -= 1;
        const dropped = @intFromBool(placeholder);
        if (s.n + 1 + n - dropped > max_rows) return;
        var rows: [max_rows]Row = undefined;
        @memcpy(rows[0..foot], s.rows[0..foot]);
        rows[foot] = .{ .kind = .head, .text = "other Claudes", .count = n, .win = .now };
        const found = find.len > 0;
        for (0..n) |i| rows[foot + 1 + i] = .{ .kind = .other, .pick = if (found) null else 0, .dim = found, .item = i, .win = .now };
        const rest = s.rows[foot + dropped .. s.n];
        @memcpy(rows[foot + 1 + n ..][0..rest.len], rest);
        s.n = foot + 1 + n + rest.len;
        @memcpy(s.rows[0..s.n], rows[0..s.n]);
        s.picks = 0;
        for (s.rows[0..s.n]) |*row| if (row.pick != null) {
            row.pick = s.picks;
            s.picks += 1;
        };
    }

    /// Workbench's rows narrowed to the repo `repo` (none for every one) and to what `find` holds.
    /// Another repo's rows are left out of their windows; a row that does not hold `find` stays,
    /// dim and out of the picks, so nothing moves. A window left with no row says so.
    pub fn narrowTo(s: *Sheet, given: *const tickets.Plan, b: *const tickets.Board, repo: []const u8, find: []const u8) void {
        if (!s.bench or (repo.len == 0 and find.len == 0)) return;
        var rows: [max_rows]Row = undefined;
        var n: usize = 0;
        var in_win: ?Window = null;
        var had: bool = false;
        var kept_in_win: bool = false;
        var last: Verdict = .keep;
        for (s.rows[0..s.n]) |row| {
            if (in_win != row.win) {
                if (in_win) |win| if (had and !kept_in_win and n < rows.len) {
                    rows[n] = .{ .kind = .note, .style = .dim, .text = "no match", .win = win };
                    n += 1;
                };
                in_win = row.win;
                had = false;
                kept_in_win = false;
            }
            had = true;
            const verdict: Verdict = if (row.kind == .why) last else s.verdictOf(given, b, row, repo, find);
            last = verdict;
            if (verdict == .hide or n == rows.len) continue;
            rows[n] = row;
            if (verdict == .dim) {
                rows[n].dim = true;
                rows[n].pick = null;
            }
            kept_in_win = true;
            n += 1;
        }
        if (in_win) |win| if (had and !kept_in_win and n < rows.len) {
            rows[n] = .{ .kind = .note, .style = .dim, .text = "no match", .win = win };
            n += 1;
        };
        s.picks = 0;
        for (rows[0..n]) |*row| if (row.pick != null) {
            row.pick = s.picks;
            s.picks += 1;
        };
        @memcpy(s.rows[0..n], rows[0..n]);
        s.n = n;
    }

    const Verdict = enum { keep, dim, hide };

    fn verdictOf(s: *const Sheet, given: *const tickets.Plan, b: *const tickets.Board, row: Row, repo: []const u8, find: []const u8) Verdict {
        _ = s;
        const id, const title, const repo_of, const in_repo = switch (row.kind) {
            .now => .{ given.now[row.item].ticket, given.now[row.item].title, given.now[row.item].repo, std.mem.eql(u8, given.now[row.item].repo, repo) },
            .next => .{ given.next[row.item].ticket, given.next[row.item].title, given.next[row.item].repo, std.mem.eql(u8, given.next[row.item].repo, repo) },
            .goal, .card_top, .goal_bar, .goal_next, .goal_block => .{ given.goals[row.item].epic, given.goals[row.item].title, "", goalIn(b, given.goals[row.item], repo) },
            .idea => .{ given.ideas[row.item].epic, given.ideas[row.item].title, "", true },
            else => return .keep,
        };
        if (repo.len > 0 and !in_repo) return .hide;
        return if (tickets.holds(find, id, title, repo_of)) .keep else .dim;
    }

    /// Whether a step of `goal` is a ticket of `repo`.
    fn goalIn(b: *const tickets.Board, goal: tickets.Goal, repo: []const u8) bool {
        if (repo.len == 0) return true;
        for (goal.steps) |step| for (b.cards()) |card| {
            if (card.id == step.ticket and std.mem.eql(u8, card.repo orelse "", repo)) return true;
        };
        return false;
    }

    /// The picks of `win`: the first and how many.
    pub fn pickRange(s: *const Sheet, win: Window) ?struct { first: usize, n: usize } {
        var first: ?usize = null;
        var n: usize = 0;
        for (s.rows[0..s.n]) |row| if (row.win == win) if (row.pick) |p| {
            if (first == null) first = p;
            n += 1;
        };
        return if (first) |f| .{ .first = f, .n = n } else null;
    }

    /// The row picked as `pick`.
    pub fn picked(s: *const Sheet, pick: usize) ?*const Row {
        for (s.rows[0..s.n]) |*row| if (row.pick == pick) return row;
        return null;
    }

    /// The index of the row picked as `pick`.
    pub fn rowOf(s: *const Sheet, pick: usize) ?usize {
        for (s.rows[0..s.n], 0..) |row, i| if (row.pick == pick) return i;
        return null;
    }

    fn add(s: *Sheet, row: Row) void {
        if (s.n == s.rows.len) return;
        var r = row;
        r.win = s.cur;
        if (r.pick != null) {
            r.pick = s.picks;
            s.picks += 1;
        }
        s.rows[s.n] = r;
        s.n += 1;
    }

    fn print(s: *Sheet, comptime fmt: []const u8, args: anytype) []const u8 {
        const out = std.fmt.bufPrint(s.buf[s.used..], fmt, args) catch return "";
        const start = s.used;
        s.used += out.len;
        return s.buf[start..s.used];
    }

    /// `left` and `right` on a row `width` cells wide, `right` against the edge; `left`, cut to
    /// make room when it must be, ends in `…`.
    fn spread(s: *Sheet, width: usize, left: []const u8, right: []const u8) struct { text: []const u8, tail_at: usize } {
        const right_w = text_mod.cells(right);
        const room = width -| right_w -| 1;
        var shown = left;
        var cut = false;
        if (text_mod.cells(left) > room) {
            shown = text_mod.clip(left, room -| 1);
            cut = true;
        }
        const ellipsis: []const u8 = if (cut) "…" else "";
        const pad = width -| text_mod.cells(shown) -| @intFromBool(cut) -| right_w;
        const text = s.print("{s}{s}{s}{s}", .{ shown, ellipsis, spaces(pad), right });
        return .{ .text = text, .tail_at = shown.len + ellipsis.len + pad };
    }

    fn clipped(s: *Sheet, width: usize, line: []const u8) []const u8 {
        if (text_mod.cells(line) <= width) return line;
        return s.print("{s}…", .{text_mod.clip(line, width -| 1)});
    }

    /// The plan as rows `width` cells wide, `epoch` the time now, the stages in `unfolded` shown
    /// a row to a ticket.
    pub fn build(s: *Sheet, given: *const tickets.Plan, b: *const tickets.Board, width: usize, epoch: i64, unfolded: u8, narrow: bool, bench: bool, shut: Shut, see: See) void {
        s.narrow = narrow;
        s.bench = bench;
        s.shut = shut;
        s.n = 0;
        s.picks = 0;
        s.used = 0;
        if (bench) return s.windowRows(given, b, width, epoch, see);
        s.nowRows(given, width, epoch);
        s.nextRows(given, width);
        s.goalRows(given, width);
        s.ideaRows(given, width, epoch, unfolded);
        s.add(.{ .kind = .blank });
        s.landedRow(given, b, width);
        s.unplannedRow(given, width);
    }

    /// Starts `win`'s rows; true when it is folded, and its summary is all it holds.
    fn begin(s: *Sheet, win: Window) bool {
        s.cur = win;
        s.from = s.n;
        return s.shut.contains(win);
    }

    fn summaryRow(s: *Sheet, text: []const u8) void {
        s.add(.{ .kind = .summary, .pick = 0, .style = .dim, .text = text });
    }

    /// Ends a window's rows; a window with none says `empty`.
    fn end(s: *Sheet, empty: []const u8) void {
        if (s.n == s.from) s.add(.{ .kind = .note, .style = .dim, .text = empty });
    }

    /// Workbench's plan: each window's rows, in the order the pick walks them.
    fn windowRows(s: *Sheet, given: *const tickets.Plan, b: *const tickets.Board, width: usize, epoch: i64, see: See) void {
        if (s.begin(.move)) s.summaryRow(s.moveSummary(b)) else for (b.needsYou(), 0..) |need, at| {
            s.add(.{ .kind = .need, .pick = 0, .ticket = need.ticket, .item = at });
        }
        s.end("✓ nothing needs you");
        if (s.begin(.driving)) s.summaryRow(s.drivingSummary(given, b)) else if (driveLanded(given, b)) |need| {
            const title = drivenTitle(b, need, given.driving.?);
            s.add(.{ .kind = .drove, .part = 1, .pick = 0, .ticket = given.driving, .text = s.print("✓ #{d} {s}", .{ given.driving.?, title }) });
            s.add(.{ .kind = .drove, .part = 2, .text = "landed. what next?" });
            s.add(.{ .kind = .drove, .part = 3 });
        } else if (focalGoal(given)) |at| {
            s.add(.{ .kind = .focal, .item = at, .part = 1, .pick = 0, .ticket = given.goals[at].epic });
            s.add(.{ .kind = .focal, .item = at, .part = 2 });
            s.add(.{ .kind = .focal, .item = at, .part = 3 });
        }
        s.end("no goal yet");
        if (s.begin(.now)) s.summaryRow(s.nowSummary(given)) else {
            s.buildingRows(given, width, epoch);
            s.pipelineRows(given, width, epoch);
        }
        s.end("none");
        if (s.begin(.next)) s.summaryRow(s.nextSummary(given)) else s.nextRows(given, width);
        s.end("none");
        if (s.begin(.goals)) s.summaryRow(s.goalsSummary(given)) else {
            s.goalRows(given, width);
            s.ideaRows(given, width, epoch, 0);
        }
        s.end("none");
        if (s.begin(.unplanned)) s.summaryRow(s.unplannedSummary(given)) else s.unplannedRows(given, b, width, epoch, see);
        s.end("none");
        if (s.begin(.landed)) s.summaryRow(s.landedSummary(given)) else for (given.landed_today.newest, 0..) |id, at| {
            s.add(.{ .kind = .landed, .pick = 0, .ticket = id, .item = at });
        }
        s.end("none");
    }

    fn moveSummary(s: *Sheet, b: *const tickets.Board) []const u8 {
        const n = b.needsYou().len;
        return if (n == 0) "✓ nothing needs you" else s.print("▲ {d} need you", .{n});
    }

    fn drivingSummary(s: *Sheet, given: *const tickets.Plan, b: *const tickets.Board) []const u8 {
        if (driveLanded(given, b)) |need| {
            const epic = given.driving.?;
            const title = drivenTitle(b, need, epic);
            const progress = b.epicProgress(epic) orelse return s.print("✓ #{d} {s} · landed. what next?", .{ epic, title });
            return s.print("✓ #{d} {s}  {d}/{d} · landed. what next?", .{ epic, title, progress.total, progress.total });
        }
        const goal = given.goals[focalGoal(given) orelse return "no goal yet"];
        return s.print("#{d} {s}  {d}/{d}", .{ goal.epic, goal.title, goal.landed, goal.total });
    }

    fn nowSummary(s: *Sheet, given: *const tickets.Plan) []const u8 {
        var working: usize = 0;
        var stalled: usize = 0;
        for (given.now) |item| if (building(item)) {
            if (item.stalled != null) stalled += 1 else working += 1;
        };
        const start = s.used;
        if (stalled == 0) _ = s.print("◐ {d} building", .{working}) else _ = s.print("◐ {d} building · ◇ {d} stalled", .{ working, stalled });
        var first = true;
        for (stages) |name| {
            var count: usize = 0;
            for (given.now) |item| count += @intFromBool(!building(item) and std.mem.eql(u8, item.stage orelse "", name));
            if (count == 0) continue;
            _ = s.print("{s}{s} {d}", .{ if (first) " · ◒ " else " · ", name, count });
            first = false;
        }
        return s.buf[start..s.used];
    }

    fn nextSummary(s: *Sheet, given: *const tickets.Plan) []const u8 {
        if (given.next.len == 0) return "none";
        const start = s.used;
        for (given.next[0..@min(given.next.len, next_summary)], 1..) |item, place_n| {
            _ = s.print("{s}{d} #{d}", .{ if (place_n == 1) "" else " · ", place_n, item.ticket });
        }
        if (given.next.len > next_summary) _ = s.print(" …", .{});
        return s.buf[start..s.used];
    }

    fn goalsSummary(s: *Sheet, given: *const tickets.Plan) []const u8 {
        if (given.goals.len == 0) return "none";
        const start = s.used;
        for (given.goals, 0..) |goal, i| {
            const pct: u32 = if (goal.total == 0) 0 else goal.landed * 100 / goal.total;
            _ = s.print("{s}#{d} {d}%", .{ if (i == 0) "" else " · ", goal.epic, pct });
        }
        return s.buf[start..s.used];
    }

    fn unplannedSummary(s: *Sheet, given: *const tickets.Plan) []const u8 {
        const not = given.not_planned;
        const start = s.used;
        for (not.by_repo.map.keys(), not.by_repo.map.values()) |repo, n| _ = s.print("{s} {d} · ", .{ repo, n });
        _ = s.print("{d} follow-ups", .{not.follow_ups});
        return s.buf[start..s.used];
    }

    fn landedSummary(s: *Sheet, given: *const tickets.Plan) []const u8 {
        return s.print("✓ {d} today", .{given.landed_today.count});
    }

    fn headRow(s: *Sheet, name: []const u8, count: usize) void {
        const text = if (s.bench) name else s.print("{s} {d}", .{ name, count });
        s.add(.{ .kind = .head, .style = .heading, .text = text, .count = count });
    }

    fn building(item: tickets.NowItem) bool {
        return std.mem.eql(u8, item.state, "building");
    }

    fn nowRows(s: *Sheet, given: *const tickets.Plan, width: usize, epoch: i64) void {
        s.headRow("in flight", given.now.len);
        s.buildingRows(given, width, epoch);
        s.pipelineRows(given, width, epoch);
    }

    fn buildingRows(s: *Sheet, given: *const tickets.Plan, width: usize, epoch: i64) void {
        for (given.now, 0..) |item, i| if (building(item)) s.nowRow(item, i, width, epoch);
    }

    /// The pipeline's tickets, a row to each: landing first, then reviewing, verifying and
    /// queued by place.
    fn pipelineRows(s: *Sheet, given: *const tickets.Plan, width: usize, epoch: i64) void {
        var order: [max_rows]u16 = undefined;
        var n: usize = 0;
        for (given.now, 0..) |item, i| if (!building(item) and n < order.len) {
            order[n] = @intCast(i);
            n += 1;
        };
        std.mem.sort(u16, order[0..n], given, pipelineBefore);
        for (order[0..n]) |i| s.nowRow(given.now[i], i, width, epoch);
    }

    fn stageRank(item: tickets.NowItem) usize {
        for (stages, 0..) |name, rank| if (std.mem.eql(u8, item.stage orelse "", name)) return rank;
        return stages.len;
    }

    fn pipelineBefore(given: *const tickets.Plan, a: u16, b: u16) bool {
        const left = given.now[a];
        const right = given.now[b];
        if (stageRank(left) != stageRank(right)) return stageRank(left) < stageRank(right);
        if ((left.place orelse 0) != (right.place orelse 0)) return (left.place orelse 0) < (right.place orelse 0);
        return a < b;
    }

    fn nowRow(s: *Sheet, item: tickets.NowItem, at: usize, width: usize, epoch: i64) void {
        const queued = std.mem.eql(u8, item.stage orelse "", "queued");
        const mark: []const u8 = if (item.stalled != null) "◇" else if (item.waiting_on != null) "◷" else if (building(item)) "◐" else if (queued) "»" else "◒";
        var age: [16]u8 = undefined;
        const how = ago(&age, item.since, epoch);
        var th: [16]u8 = undefined;
        const state = if (queued and item.place != null) s.print("queued {s}", .{place(item.place.?, &th)}) else item.stage orelse item.state;
        var said: [96]u8 = undefined;
        const right = if (item.stalled) |why|
            s.print("stalled · {s}", .{why})
        else if (item.waiting_on) |wait|
            s.print("{s}", .{wait.say(&said)})
        else if (how.len > 0) s.print("{s} · {s}", .{ state, how }) else s.print("{s}", .{state});
        const left = s.print(" {s} #{d} {s: <8} {s}", .{ mark, item.ticket, text_mod.clip(item.repo, 8), item.title });
        const both = s.spread(width, left, right);
        s.add(.{
            .kind = .now,
            .pick = 0,
            .ticket = item.ticket,
            .item = at,
            .text = both.text,
            .tail_at = both.tail_at,
            .tail_style = if (item.stalled != null) .attention else .normal,
        });
    }

    fn nextRows(s: *Sheet, given: *const tickets.Plan, width: usize) void {
        if (!s.bench) {
            s.add(.{ .kind = .blank });
            s.headRow("next", given.next.len);
        }
        const shown = if (s.bench) given.next.len else @min(given.next.len, next_shown);
        for (given.next[0..shown], 1..) |item, place_n| {
            if (s.bench) {
                s.add(.{ .kind = .next, .pick = 0, .ticket = item.ticket, .item = place_n - 1 });
                if (item.why.len > 0 and !s.narrow) s.add(.{ .kind = .why, .style = .dim, .text = s.clipped(width, item.why) });
                continue;
            }
            const right = s.waits(item.waits_on);
            const left = s.print(" {d} #{d} {s: <8} {s}", .{ place_n, item.ticket, text_mod.clip(item.repo, 8), item.title });
            const both = s.spread(width, left, right);
            s.add(.{ .kind = .next, .pick = 0, .ticket = item.ticket, .text = both.text, .tail_at = both.tail_at });
            if (item.why.len > 0 and !s.narrow) s.add(.{ .kind = .why, .style = .dim, .text = s.clipped(width, s.print("      {s}", .{item.why})) });
        }
        if (shown < given.next.len) s.add(.{ .kind = .more, .style = .dim, .text = s.print("  +{d}", .{given.next.len - shown}) });
    }

    /// What an item waits on, as babylon says it: a ticket, or its repo's lane until one lands.
    fn waits(s: *Sheet, on: []const tickets.Wait) []const u8 {
        const start = s.used;
        for (on) |wait| {
            const sep: []const u8 = if (s.used == start) "← " else ", ";
            if (wait.ticket) |t| {
                _ = s.print("{s}needs #{d}", .{ sep, t });
            } else if (wait.until) |until| if (wait.lane) |lane| {
                _ = s.print("{s}after #{d} lands: one {s}", .{ sep, until, lane });
            };
        }
        if (s.used == start) return "free now";
        return s.buf[start..s.used];
    }

    fn goalRows(s: *Sheet, given: *const tickets.Plan, width: usize) void {
        if (!s.bench) {
            s.add(.{ .kind = .blank });
            s.headRow("goals", given.goals.len);
        }
        var name_w: usize = 0;
        if (!s.narrow) for (given.goals) |goal| {
            name_w = @max(name_w, @min(text_mod.cells(goal.title), 26));
        };
        const per: usize = if (s.bench) 5 else 1;
        const ideas_room: usize = if (given.ideas.len == 0) 0 else idea_rows;
        const room_rows = max_rows -| s.n -| foot_rows -| ideas_room;
        const shown = if (given.goals.len * per <= room_rows) given.goals.len else (room_rows -| 1) / per;
        for (given.goals[0..shown], 0..) |goal, i| {
            if (s.bench) {
                if (given.driving == goal.epic) continue;
                inline for (.{ .card_top, .goal, .goal_bar, .goal_next, .goal_block }) |kind| {
                    s.add(.{ .kind = kind, .item = i, .pick = if (kind == .goal) 0 else null, .ticket = if (kind == .goal) goal.epic else null });
                }
                continue;
            }
            var extra: [96]u8 = undefined;
            const trying = goalTrying(goal);
            const after = if (trying > 0)
                s.print("  {d} of {d}  {s}{s}▲ {d} to try", .{ goal.landed, goal.total, goalExtra(goal, &extra), if (goalExtra(goal, &extra).len > 0) "  " else "", trying })
            else
                s.print("  {d} of {d}  {s}", .{ goal.landed, goal.total, goalExtra(goal, &extra) });
            const name = text_mod.clip(goal.title, name_w);
            const head = s.print(" {s}{s}  #{d}  ", .{ name, spaces(name_w -| text_mod.cells(name)), goal.epic });
            const room = width -| text_mod.cells(head) -| text_mod.cells(after);
            const start = s.used;
            var marks: usize = 0;
            for (goal.steps) |step| {
                if (marks + 1 > room) break;
                _ = s.print("{s}", .{stepMark(step.state)});
                marks += 1;
            }
            if (marks < goal.steps.len and marks > 0) {
                const last = stepMark(goal.steps[marks - 1].state);
                s.used -= last.len;
                _ = s.print("…", .{});
            }
            const strip = s.buf[start..s.used];
            const line = s.print("{s}{s}{s}", .{ head, strip, after });
            s.add(.{ .kind = .goal, .pick = 0, .ticket = goal.epic, .text = s.clipped(width, line) });
        }
        if (shown < given.goals.len) s.add(.{ .kind = .goals_more, .pick = 0, .style = .dim, .text = s.print("  +{d} more goals", .{given.goals.len - shown}) });
    }

    /// Under a rule, a row to each idea in the order babylon gives them, oldest first; past
    /// three, one row that unfolds them.
    fn ideaRows(s: *Sheet, given: *const tickets.Plan, width: usize, epoch: i64, unfolded: u8) void {
        if (given.ideas.len == 0) return;
        if (!s.bench) s.add(.{ .kind = .blank });
        s.headRow("ideas", given.ideas.len);
        if (given.ideas.len > ideas_shown and unfolded & (@as(u8, 1) << ideas_fold) == 0) {
            s.add(.{ .kind = .ideas_more, .pick = 0, .fold = ideas_fold, .style = .dim, .text = s.print(" +{d} ideas", .{given.ideas.len}) });
            return;
        }
        for (given.ideas, 0..) |idea, i| {
            const state = ideaState(idea);
            var said: [64]u8 = undefined;
            const label = ideaLabel(&said, idea, epoch);
            const asks = state == .planning and idea.asks > 0;
            const right = if (asks) s.print("{s}  ▲ asks you", .{label}) else label;
            const left = s.print(" {s} #{d} {s}", .{ ideaMark(state), idea.epic, idea.title });
            const both = s.spread(width, left, right);
            s.add(.{
                .kind = .idea,
                .pick = 0,
                .ticket = idea.epic,
                .item = i,
                .text = both.text,
                .tail_at = both.tail_at,
                .tail_style = if (asks) .attention else .dim,
            });
        }
    }

    pub const IdeaState = enum { idea, planning, draft };

    /// An idea's state as one of the three drawn; one babylon names otherwise is a plain idea.
    pub fn ideaState(idea: tickets.Idea) IdeaState {
        return std.meta.stringToEnum(IdeaState, idea.state) orelse .idea;
    }

    pub fn ideaMark(state: IdeaState) []const u8 {
        return switch (state) {
            .idea => "○",
            .planning => "◐",
            .draft => "☐",
        };
    }

    /// What an idea says of itself on its row, in `buf`: kept for how long, planning for how
    /// long, or its steps drafted and waiting on a look.
    pub fn ideaLabel(buf: []u8, idea: tickets.Idea, epoch: i64) []const u8 {
        var age: [16]u8 = undefined;
        const out = switch (ideaState(idea)) {
            .idea => std.fmt.bufPrint(buf, "idea · kept {s}", .{kept(&age, idea.since, epoch)}),
            .planning => blk: {
                const how = ago(&age, idea.since, epoch);
                break :blk std.fmt.bufPrint(buf, "planning{s}{s}", .{ if (how.len > 0) " · " else "", how });
            },
            .draft => std.fmt.bufPrint(buf, "draft · {d} steps · look", .{idea.steps}),
        };
        return out catch "";
    }

    /// How long an idea has been kept, in whole days once past one.
    fn kept(buf: []u8, since: ?[]const u8, epoch: i64) []const u8 {
        const then = tickets.epochOf(since) orelse return "";
        const days = @divFloor(@max(epoch - then, 0), 86400);
        if (days >= 1) return std.fmt.bufPrint(buf, "{d}d", .{days}) catch "";
        return ago(buf, since, epoch);
    }

    pub fn stepMark(state: []const u8) []const u8 {
        const marks = [_][2][]const u8{
            .{ "landed", "✓" },
            .{ "building", "◐" },
            .{ "landing", "◒" },
            .{ "next", "●" },
            .{ "to_try", "▲" },
            .{ "failed", "✗" },
            .{ "sent_back", "✗" },
        };
        for (marks) |pair| if (std.mem.eql(u8, state, pair[0])) return pair[1];
        return "○";
    }

    /// The steps of a goal that are moving or next, by number, else what its first waiting step
    /// waits on.
    fn goalExtra(goal: tickets.Goal, buf: []u8) []const u8 {
        var used: usize = 0;
        var moving: usize = 0;
        for (goal.steps) |step| {
            const mark = stepMark(step.state);
            if (std.mem.eql(u8, mark, "✓") or std.mem.eql(u8, mark, "○") or std.mem.eql(u8, mark, "✗") or std.mem.eql(u8, mark, "▲")) continue;
            if (moving == 3) break;
            const out = std.fmt.bufPrint(buf[used..], "{s}{s} #{d}", .{ if (moving > 0) " " else "", mark, step.ticket }) catch break;
            used += out.len;
            moving += 1;
        }
        if (moving > 0) return buf[0..used];
        for (goal.steps) |step| {
            if (!std.mem.eql(u8, stepMark(step.state), "○")) continue;
            const out = if (step.waits_on.len > 0 and step.waits_on[0].ticket != null)
                std.fmt.bufPrint(buf, "○ #{d} waits on #{d}", .{ step.ticket, step.waits_on[0].ticket.? })
            else
                std.fmt.bufPrint(buf, "○ #{d}", .{step.ticket});
            return out catch "";
        }
        return "";
    }

    fn landedRow(s: *Sheet, given: *const tickets.Plan, b: *const tickets.Board, width: usize) void {
        const today = given.landed_today;
        const start = s.used;
        _ = s.print("landed today {d}", .{today.count});
        for (today.newest, 0..) |id, i| {
            _ = s.print("{s}", .{if (i == 0) "   " else " · "});
            const card = for (b.cards()) |*card| {
                if (card.id == id) break card;
            } else null;
            if (card) |c| {
                _ = s.print("#{d} {s} {s}", .{ id, c.repo orelse "", c.title });
            } else _ = s.print("#{d}", .{id});
        }
        s.add(.{ .kind = .landed, .pick = 0, .text = s.clipped(width, s.buf[start..s.used]) });
    }

    fn inNext(given: *const tickets.Plan, id: u32) bool {
        for (given.next) |item| if (item.ticket == id) return true;
        return false;
    }

    fn repoShut(see: See, repo: ?[]const u8) bool {
        for (see.repos_shut) |name| if (std.mem.eql(u8, name, repo orelse "")) return true;
        return false;
    }

    /// Not planned's rows: the chip row, then the open repos' todo tickets that are not in next in
    /// babylon's order (those that can start before those that wait), or the backlog's in their place.
    fn unplannedRows(s: *Sheet, given: *const tickets.Plan, b: *const tickets.Board, width: usize, epoch: i64, see: See) void {
        s.add(.{ .kind = .chips, .pick = 0, .count = given.not_planned.count });
        const rows_from = s.n;
        if (see.backlog) {
            for (b.backlog()) |*card| if (!card.isEpic()) s.ticketRow(.backlog, card, width, epoch);
            if (s.n == rows_from) s.add(.{ .kind = .note, .style = .dim, .text = "the backlog is empty" });
            return;
        }
        for ([_]bool{ false, true }) |waiting| for (b.cards()) |*card| {
            if (card.status != .todo or card.isEpic() or (card.blocked_by.len > 0) != waiting) continue;
            if (repoShut(see, card.repo) or inNext(given, card.id)) continue;
            s.ticketRow(.todo, card, width, epoch);
        };
        if (s.n != rows_from) return;
        const repos = given.not_planned.by_repo.map.count();
        const text = if (repos > 0 and see.repos_shut.len >= repos) "every repo is folded: ⏎ on a chip opens it" else "nothing to do in the open repos";
        s.add(.{ .kind = .note, .style = .dim, .text = text });
    }

    /// A todo or backlog ticket's row: its number and title, and on the right its priority and
    /// what it waits on, or in the backlog its age.
    fn ticketRow(s: *Sheet, kind: Kind, card: *const tickets.Card, width: usize, epoch: i64) void {
        var age: [16]u8 = undefined;
        const how = ago(&age, card.inserted_at, epoch);
        const right = if (card.blocked_by.len > 0)
            s.print("{s}  ← #{d}", .{ card.priority, card.blocked_by[0] })
        else if (kind == .backlog and how.len > 0) s.print("{s}  {s}", .{ card.priority, how }) else s.print("{s}", .{card.priority});
        const left = s.print(" #{d} {s}", .{ card.id, card.title });
        const both = s.spread(width, left, right);
        s.add(.{ .kind = kind, .pick = 0, .ticket = card.id, .text = both.text, .tail_at = both.tail_at, .tail_style = .dim });
    }

    fn unplannedRow(s: *Sheet, given: *const tickets.Plan, width: usize) void {
        const not = given.not_planned;
        const start = s.used;
        _ = s.print("not planned {d}, {d} follow-ups   ", .{ not.count, not.follow_ups });
        for (not.by_repo.map.keys(), not.by_repo.map.values(), 0..) |repo, n, i| {
            _ = s.print("{s}{s} {d}", .{ if (i == 0) "" else " · ", repo, n });
        }
        s.add(.{ .kind = .unplanned, .pick = 0, .text = s.clipped(width, s.buf[start..s.used]) });
    }
};

const blank: [256]u8 = @splat(' ');

fn spaces(n: usize) []const u8 {
    return blank[0..@min(n, blank.len)];
}

/// `1st`, `2nd`, `3rd`, `4th`: a place in a queue, in `buf`.
pub fn place(n: u32, buf: []u8) []const u8 {
    const word: []const u8 = if (n % 100 >= 11 and n % 100 <= 13) "th" else switch (n % 10) {
        1 => "st",
        2 => "nd",
        3 => "rd",
        else => "th",
    };
    return std.fmt.bufPrint(buf, "{d}{s}", .{ n, word }) catch "";
}

/// How long ago `since` was, as `6m` or `1h05`; nothing when babylon does not say.
pub fn ago(buf: []u8, since: ?[]const u8, epoch: i64) []const u8 {
    const then = tickets.epochOf(since) orelse return "";
    const mins = @divFloor(@max(epoch - then, 0), 60);
    if (mins < 1) return "now";
    if (mins < 60) return std.fmt.bufPrint(buf, "{d}m", .{mins}) catch "";
    return std.fmt.bufPrint(buf, "{d}h{d:0>2}", .{ @divFloor(mins, 60), @mod(mins, 60) }) catch "";
}

const sample =
    \\{"tickets":[{"id":322,"repo":"arena","title":"held card e2e","status":"done"}],
    \\"plan":{
    \\"now":[
    \\{"ticket":600,"repo":"arena","title":"Design","state":"building","since":"2026-11-23T07:04:00Z","pane":"%757"},
    \\{"ticket":510,"repo":"tlon","title":"Money","state":"building","since":"2026-11-23T07:02:00Z","pane":"%575","stalled":"idle 9m"},
    \\{"ticket":587,"repo":"arena","title":"Seams","state":"landing","stage":"verifying","since":"2026-11-23T06:50:00Z"},
    \\{"ticket":591,"repo":"arena","title":"Hook","state":"landing","stage":"verifying","since":"2026-11-23T06:55:00Z"},
    \\{"ticket":560,"repo":"arena","title":"Third","state":"landing","stage":"verifying","since":"2026-11-23T06:56:00Z"},
    \\{"ticket":588,"repo":"babylon","title":"Queued","state":"landing","stage":"queued","place":1,"since":"2026-11-23T06:57:00Z"},
    \\{"ticket":429,"repo":"babylon","title":"Queued two","state":"landing","stage":"queued","place":2,"since":"2026-11-23T06:57:00Z"}],
    \\"next":[
    \\{"ticket":589,"repo":"babylon","title":"babylon start N","why":"the seams' verb","waits_on":[{"lane":"babylon","until":588}]},
    \\{"ticket":594,"repo":"arena","title":"the board's start","why":"stops typing","waits_on":[{"ticket":589}]},
    \\{"ticket":453,"repo":"arena","title":"Normal mode 2","why":"","waits_on":[]}],
    \\"goals":[{"epic":452,"title":"normal mode","total":3,"landed":1,"steps":[{"ticket":1,"state":"landed"},{"ticket":453,"state":"next"},{"ticket":454,"state":"waiting","waits_on":[{"ticket":453}]}]},
    \\{"epic":9,"title":"quiet","total":2,"landed":1,"steps":[{"ticket":1,"state":"landed"},{"ticket":3,"state":"waiting","waits_on":[{"ticket":2}]}]}],
    \\"landed_today":{"count":2,"newest":[322,999]},
    \\"not_planned":{"count":5,"follow_ups":3,"by_repo":{"arena":3,"tlon":2}}}}
;

fn rowText(s: *const Sheet, kind: Kind, nth: usize) ?[]const u8 {
    var seen: usize = 0;
    for (s.rows[0..s.n]) |row| if (row.kind == kind) {
        if (seen == nth) return row.text;
        seen += 1;
    };
    return null;
}

test "in flight: building first, then the pipeline a row to a ticket, landing before reviewing before verifying before queued by place, each said as babylon gives it" {
    var b = try tickets.Board.parse(std.testing.allocator, sample);
    defer b.deinit();
    var s: Sheet = undefined;
    const epoch = tickets.epochOf("2026-11-23T07:10:00Z").?;
    s.build(b.plan().?, &b, 100, epoch, 0, false, false, .empty, .{});
    const eq = std.testing.expectEqualStrings;
    const ok = std.testing.expect;
    try eq("in flight 7", rowText(&s, .head, 0).?);
    try ok(std.mem.startsWith(u8, rowText(&s, .now, 0).?, " ◐ #600 arena    Design"));
    try ok(std.mem.endsWith(u8, rowText(&s, .now, 0).?, "building · 6m"));
    try ok(std.mem.indexOf(u8, rowText(&s, .now, 1).?, "◇ #510") != null);
    try ok(std.mem.endsWith(u8, rowText(&s, .now, 1).?, "stalled · idle 9m"));
    try ok(std.mem.endsWith(u8, rowText(&s, .now, 2).?, "verifying · 20m"));
    try ok(std.mem.indexOf(u8, rowText(&s, .now, 3).?, "#591") != null);
    try ok(std.mem.indexOf(u8, rowText(&s, .now, 4).?, "#560") != null);
    try ok(std.mem.indexOf(u8, rowText(&s, .now, 5).?, "» #588") != null);
    try ok(std.mem.endsWith(u8, rowText(&s, .now, 5).?, "queued 1st · 13m"));
    try ok(std.mem.indexOf(u8, rowText(&s, .now, 6).?, "» #429") != null);
    try ok(std.mem.endsWith(u8, rowText(&s, .now, 6).?, "queued 2nd · 13m"));
    try std.testing.expectEqual(@as(?[]const u8, null), rowText(&s, .now, 7));
}

test "a landing ticket is listed before reviewing, verifying and queued, whatever order babylon gives" {
    var b = try tickets.Board.parse(std.testing.allocator,
        \\{"tickets":[],"plan":{"now":[
        \\{"ticket":1,"repo":"arena","title":"q2","state":"landing","stage":"queued","place":2},
        \\{"ticket":2,"repo":"arena","title":"v","state":"landing","stage":"verifying"},
        \\{"ticket":3,"repo":"arena","title":"l","state":"landing","stage":"landing"},
        \\{"ticket":4,"repo":"arena","title":"q1","state":"landing","stage":"queued","place":1},
        \\{"ticket":5,"repo":"arena","title":"r","state":"landing","stage":"reviewing"},
        \\{"ticket":6,"repo":"arena","title":"b","state":"building"}]}}
    );
    defer b.deinit();
    var s: Sheet = undefined;
    s.build(b.plan().?, &b, 100, 0, 0, false, true, .empty, .{});
    const want = [_]u32{ 6, 3, 5, 2, 4, 1 };
    var at: usize = 0;
    for (s.rows[0..s.n]) |row| if (row.kind == .now) {
        try std.testing.expectEqual(want[at], row.ticket.?);
        at += 1;
    };
    try std.testing.expectEqual(want.len, at);
}

test "a wait with no ticket and no landing to wait for is no wait" {
    const bare = [_]tickets.Wait{ .{ .lane = "arena" }, .{} };
    try std.testing.expect(tickets.Wait.first(&bare) == null);
    const mixed = [_]tickets.Wait{ .{ .lane = "arena" }, .{ .lane = "arena", .until = 818 } };
    try std.testing.expectEqual(@as(?u32, 818), tickets.Wait.first(&mixed).?.until);
    var s: Sheet = undefined;
    s.used = 0;
    try std.testing.expectEqualStrings("free now", s.waits(&bare));
}

test "next says what each waits on and why, goals their steps, and the picks run through every row that can be" {
    var b = try tickets.Board.parse(std.testing.allocator, sample);
    defer b.deinit();
    var s: Sheet = undefined;
    s.build(b.plan().?, &b, 100, 0, 0, false, false, .empty, .{});
    const has = std.mem.indexOf;
    const ok = std.testing.expect;
    try ok(std.mem.endsWith(u8, rowText(&s, .next, 0).?, "← after #588 lands: one babylon"));
    try ok(std.mem.endsWith(u8, rowText(&s, .next, 1).?, "← needs #589"));
    try ok(std.mem.endsWith(u8, rowText(&s, .next, 2).?, "free now"));
    var whys: usize = 0;
    for (s.rows[0..s.n]) |row| whys += @intFromBool(row.kind == .why);
    try std.testing.expectEqual(@as(usize, 2), whys);
    try ok(has(u8, rowText(&s, .goal, 0).?, "#452  ✓●○  1 of 3  ● #453") != null);
    try ok(has(u8, rowText(&s, .goal, 1).?, "1 of 2  ○ #3 waits on #2") != null);
    try ok(has(u8, rowText(&s, .landed, 0).?, "landed today 2   #322 arena held card e2e · #999") != null);
    try ok(has(u8, rowText(&s, .unplanned, 0).?, "not planned 5, 3 follow-ups   arena 3 · tlon 2") != null);
    // 2 building and 5 pipeline rows, 3 next, 2 goals, landed, not planned
    try std.testing.expectEqual(@as(usize, 2 + 5 + 3 + 2 + 2), s.picks);
    try std.testing.expectEqual(s.picks - 1, s.rows[s.rowOf(s.picks - 1).?].pick.?);
}

test "ideas draw a row each under their rule, one in each state, and fold past three" {
    const ok = std.testing.expect;
    const given = try tickets.Board.parse(std.testing.allocator,
        \\{"tickets":[],"plan":{"ideas":[
        \\{"epic":830,"title":"money","state":"planning","plan_ticket":839,"pane":"%12","asks":1,"since":"2026-11-24T20:00:00Z"},
        \\{"epic":831,"title":"retro","state":"draft","steps":7,"since":"2026-11-24T10:00:00Z"},
        \\{"epic":829,"title":"garden","state":"idea","since":"2026-11-22T10:00:00Z"}]}}
    );
    var b = given;
    defer b.deinit();
    var s: Sheet = undefined;
    s.build(b.plan().?, &b, 80, tickets.epochOf("2026-11-24T20:04:00Z").?, 0, false, false, .empty, .{});
    try ok(std.mem.eql(u8, rowText(&s, .head, 3).?, "ideas 3"));
    const planning = rowText(&s, .idea, 0).?;
    try ok(std.mem.indexOf(u8, planning, "◐ #830 money") != null);
    try ok(std.mem.indexOf(u8, planning, "planning · 4m  ▲ asks you") != null);
    try ok(std.mem.indexOf(u8, rowText(&s, .idea, 1).?, "☐ #831 retro") != null);
    try ok(std.mem.indexOf(u8, rowText(&s, .idea, 1).?, "draft · 7 steps · look") != null);
    try ok(std.mem.indexOf(u8, rowText(&s, .idea, 2).?, "○ #829 garden") != null);
    try ok(std.mem.indexOf(u8, rowText(&s, .idea, 2).?, "idea · kept 2d") != null);
    try ok(rowText(&s, .ideas_more, 0) == null);

    var four = try tickets.Board.parse(std.testing.allocator,
        \\{"tickets":[],"plan":{"ideas":[
        \\{"epic":1,"title":"a"},{"epic":2,"title":"b"},{"epic":3,"title":"c"},{"epic":4,"title":"d"}]}}
    );
    defer four.deinit();
    s.build(four.plan().?, &four, 80, 0, 0, false, false, .empty, .{});
    try ok(rowText(&s, .idea, 0) == null);
    try ok(std.mem.eql(u8, rowText(&s, .ideas_more, 0).?, " +4 ideas"));
    s.build(four.plan().?, &four, 80, 0, @as(u8, 1) << ideas_fold, false, false, .empty, .{});
    try ok(rowText(&s, .ideas_more, 0) == null);
    try ok(rowText(&s, .idea, 3) != null);
}

test "a goal with a step to try reads ▲ N to try, and the step is neither next nor moving" {
    var b = try tickets.Board.parse(std.testing.allocator,
        \\{"tickets":[],"plan":{"now":[],"next":[],
        \\"goals":[{"epic":9,"title":"g","total":2,"landed":1,"steps":[{"ticket":1,"state":"to_try"},{"ticket":2,"state":"waiting"}]}],
        \\"landed_today":{"count":0,"newest":[]},"not_planned":{"count":0,"follow_ups":0,"by_repo":{}}}}
    );
    defer b.deinit();
    var s: Sheet = undefined;
    s.build(b.plan().?, &b, 100, 0, 0, false, false, .empty, .{});
    try std.testing.expect(std.mem.indexOf(u8, rowText(&s, .goal, 0).?, "1 of 2  ○ #2  ▲ 1 to try") != null);
    try std.testing.expectEqual(@as(u32, 2), goalNext(b.plan().?.goals[0]).?.ticket);
}

test "a row too wide is cut, its right side kept" {
    var b = try tickets.Board.parse(std.testing.allocator, sample);
    defer b.deinit();
    var s: Sheet = undefined;
    s.build(b.plan().?, &b, 40, 0, 0, false, false, .empty, .{});
    for (s.rows[0..s.n]) |row| try std.testing.expect(text_mod.cells(row.text) <= 40);
    try std.testing.expect(std.mem.endsWith(u8, rowText(&s, .now, 0).?, "building · now"));
}

test "the focal goal is the first with a step being built, a card is five rows, and its next and blocker are its steps" {
    var b = try tickets.Board.parse(std.testing.allocator, sample);
    defer b.deinit();
    const given = b.plan().?;
    try std.testing.expectEqual(@as(?usize, 0), focalGoal(given));
    try std.testing.expectEqual(@as(u32, 453), goalNext(given.goals[0]).?.ticket);
    try std.testing.expectEqual(@as(u32, 454), goalBlock(given.goals[0]).?.step);
    try std.testing.expectEqual(@as(u32, 453), goalBlock(given.goals[0]).?.on);
    var s: Sheet = undefined;
    s.build(given, &b, 100, 0, 0, false, true, .empty, .{});
    const at = s.span(.driving).start;
    try std.testing.expectEqual(Kind.focal, s.rows[at].kind);
    try std.testing.expectEqual(@as(usize, 0), s.rows[at].pick.?);
    var cards: usize = 0;
    for (s.rows[0..s.n]) |row| cards += @intFromBool(row.kind == .card_top);
    try std.testing.expectEqual(@as(usize, 2), cards);
}

test "the focal window follows plan.driving, says whose pick it is, and asks what next when that goal has landed" {
    const open =
        \\{"tickets":[{"id":14,"repo":"arena","kind":"epic","status":"done","title":"The house"},{"id":15,"repo":"arena","status":"done","title":"a step","epic_id":14}],
        \\"needs_you":[{"id":"drive:14","kind":"drive","ticket":14,"repo":"","text":"goal landed",
        \\"actions":[{"key":"1","label":"the board","argv":["babylon","drive","326"]},{"key":"2","label":"the orchestrator","argv":["babylon","drive","500"]}]}],
        \\"plan":{
    ;
    const goals =
        \\"goals":[
        \\{"epic":410,"title":"menard","landed":2,"total":7,"steps":[{"ticket":592,"state":"todo"}]},
        \\{"epic":326,"title":"board","landed":1,"total":2,"steps":[{"ticket":760,"state":"building"}]}]}}
    ;
    var s: Sheet = undefined;
    for ([_]struct { driving: []const u8, epic: ?u32, title: []const u8 }{
        .{ .driving = "", .epic = 326, .title = "driving towards · d to pick" },
        .{ .driving = "\"driving\":410,", .epic = 410, .title = "driving towards · your pick" },
    }) |case| {
        const text = try std.fmt.allocPrint(std.testing.allocator, "{s}{s}{s}", .{ open, case.driving, goals });
        defer std.testing.allocator.free(text);
        var b = try tickets.Board.parse(std.testing.allocator, text);
        defer b.deinit();
        const given = b.plan().?;
        try std.testing.expectEqual(@as(?u32, case.epic), given.goals[focalGoal(given).?].epic);
        try std.testing.expectEqualStrings(case.title, drivingTitle(given, &b));
        try std.testing.expect(driveLanded(given, &b) == null);
        s.build(given, &b, 100, 0, 0, false, true, .empty, .{});
        var cards: usize = 0;
        for (s.rows[0..s.n]) |row| cards += @intFromBool(row.kind == .card_top);
        try std.testing.expectEqual(@as(usize, if (case.driving.len == 0) 2 else 1), cards);
    }

    const text = try std.fmt.allocPrint(std.testing.allocator, "{s}\"driving\":14,{s}", .{ open, goals });
    defer std.testing.allocator.free(text);
    var b = try tickets.Board.parse(std.testing.allocator, text);
    defer b.deinit();
    const given = b.plan().?;
    const need = driveLanded(given, &b).?;
    s.build(given, &b, 100, 0, 0, false, true, .empty, .{});
    const at = s.span(.driving).start;
    try std.testing.expectEqualStrings("✓ #14 The house", s.rows[at].text);
    try std.testing.expectEqualStrings("landed. what next?", s.rows[at + 1].text);

    try std.testing.expectEqual(Kind.drove, s.rows[at + 2].kind);
    var buf: [96]u8 = undefined;
    try std.testing.expectEqualStrings("2 the orchestrator", driveButton(&buf, need, 1));
    try std.testing.expectEqualStrings("+ a new goal", driveButton(&buf, need, 2));
    try std.testing.expectEqual(@as(?usize, 0), driveButtonAt(need, 10, 12));
    try std.testing.expectEqual(@as(?usize, 1), driveButtonAt(need, 10, 12 + "1 the board".len + 3));
    try std.testing.expectEqual(@as(?usize, null), driveButtonAt(need, 10, 10));
    try std.testing.expectEqualStrings("driving towards · landed", drivingTitle(given, &b));
    s.build(given, &b, 100, 0, 0, false, true, Shut.initOne(.driving), .{});
    try std.testing.expectEqualStrings("✓ #14 The house  1/1 · landed. what next?", s.rows[s.span(.driving).start].text);
}

test "goals past what fits fold into one row, and landed and not planned keep theirs" {
    var buf: [8192]u8 = undefined;
    var used = (try std.fmt.bufPrint(&buf, "{{\"tickets\":[],\"plan\":{{\"now\":[],\"next\":[],\"goals\":[", .{})).len;
    for (0..32) |i| {
        used += (try std.fmt.bufPrint(buf[used..], "{s}{{\"epic\":{d},\"title\":\"g{d}\",\"total\":2,\"landed\":1,\"steps\":[{{\"ticket\":1,\"state\":\"landed\"}},{{\"ticket\":2,\"state\":\"next\"}}]}}", .{ if (i > 0) "," else "", 100 + i, i })).len;
    }
    used += (try std.fmt.bufPrint(buf[used..], "],\"landed_today\":{{\"count\":1,\"newest\":[1]}},\"not_planned\":{{\"count\":0,\"follow_ups\":0,\"by_repo\":{{}}}}}}}}", .{})).len;
    var b = try tickets.Board.parse(std.testing.allocator, buf[0..used]);
    defer b.deinit();
    var s: Sheet = undefined;
    s.build(b.plan().?, &b, 100, 0, 0, false, true, .empty, .{});
    try std.testing.expect(rowText(&s, .landed, 0) != null);
    try std.testing.expect(rowText(&s, .chips, 0) != null);
    try std.testing.expect(std.mem.indexOf(u8, rowText(&s, .goals_more, 0).?, "more goals") != null);
}

test "a now row waiting on a ticket says so, with its own mark, and is not drawn as stalled" {
    var b = try tickets.Board.parse(std.testing.allocator,
        \\{"tickets":[],"plan":{"now":[
        \\{"ticket":505,"repo":"arena","title":"Parked","state":"building","since":"2026-11-23T07:00:00Z","pane":"%580","waiting_on":{"ticket":829,"for":null,"since":"2026-11-23T07:01:00Z"}}]}}
    );
    defer b.deinit();
    var s: Sheet = undefined;
    s.build(b.plan().?, &b, 100, tickets.epochOf("2026-11-23T07:10:00Z").?, 0, false, false, .empty, .{});
    const row = rowText(&s, .now, 0).?;
    try std.testing.expect(std.mem.indexOf(u8, row, "◷ #505") != null);
    try std.testing.expect(std.mem.endsWith(u8, row, "◷ waiting on #829"));
    try std.testing.expect(std.mem.indexOf(u8, row, "stalled") == null);
}

test "landed is a row to each of today's tickets, newest first, and folds to its count" {
    var b = try tickets.Board.parse(std.testing.allocator,
        \\{"tickets":[{"id":5,"title":"Five","status":"done"},{"id":6,"title":"Six","status":"done"}],"plan":{"now":[],"next":[],"goals":[],
        \\"landed_today":{"count":23,"newest":[6,5]},"not_planned":{"count":0,"follow_ups":0,"by_repo":{}}}}
    );
    defer b.deinit();
    var s: Sheet = undefined;
    s.build(b.plan().?, &b, 100, 0, 0, false, true, .empty, .{});
    var tickets_seen: [2]u32 = undefined;
    var n: usize = 0;
    for (s.rows[0..s.n]) |row| if (row.kind == .landed) {
        tickets_seen[n] = row.ticket.?;
        n += 1;
    };
    try std.testing.expectEqual(@as(usize, 2), n);
    try std.testing.expectEqualSlices(u32, &.{ 6, 5 }, &tickets_seen);
    s.build(b.plan().?, &b, 100, 0, 0, false, true, .initOne(.landed), .{});
    try std.testing.expectEqualStrings("✓ 23 today", rowText(&s, .summary, 0).?);
}

test "a second line under each in-flight row whose pane is known, and no pick of its own" {
    var b = try tickets.Board.parse(std.testing.allocator,
        \\{"tickets":[],"plan":{"now":[
        \\{"ticket":1,"repo":"arena","title":"Held","state":"building","pane":"%7"},
        \\{"ticket":2,"repo":"arena","title":"Elsewhere","state":"building","pane":"%8"},
        \\{"ticket":3,"repo":"arena","title":"Nobody","state":"building"}]}}
    );
    defer b.deinit();
    var s: Sheet = undefined;
    s.build(b.plan().?, &b, 100, 0, 0, false, true, .empty, .{});
    const before = s.n;
    const Known = struct {
        pub fn has(_: @This(), pane: u32) bool {
            return pane == 7;
        }
    };
    s.withHeld(b.plan().?, Known{});
    try std.testing.expectEqual(before + 1, s.n);
    for (s.rows[0..s.n], 0..) |row, i| if (row.kind == .held) {
        try std.testing.expectEqual(@as(?u32, 1), row.ticket);
        try std.testing.expectEqual(Kind.now, s.rows[i - 1].kind);
        try std.testing.expectEqual(@as(?u32, 1), s.rows[i - 1].ticket);
        try std.testing.expectEqual(@as(?usize, null), row.pick);
    };
}

test "not planned's rows are the open repos' todo tickets that are not in next, startable first; the backlog chip shows the backlog" {
    var b = try tickets.Board.parse(std.testing.allocator,
        \\{"tickets":[
        \\{"id":1,"repo":"arena","title":"blocked","status":"todo","blocked_by":[9]},
        \\{"id":2,"repo":"arena","title":"free","status":"todo","priority":"high"},
        \\{"id":3,"repo":"tlon","title":"folded repo","status":"todo"},
        \\{"id":4,"repo":"arena","title":"in next","status":"todo"},
        \\{"id":5,"repo":"arena","title":"doing","status":"doing"}],
        \\"backlog":[{"id":6,"repo":"arena","title":"later","status":"backlog","kind":"ticket"},{"id":7,"title":"an idea","status":"backlog","kind":"epic"}],
        \\"plan":{"next":[{"ticket":4,"repo":"arena","title":"in next","why":""}],
        \\"not_planned":{"count":3,"follow_ups":0,"by_repo":{"arena":2,"tlon":1}}}}
    );
    defer b.deinit();
    var s: Sheet = undefined;
    const shut = [_][]const u8{"tlon"};
    s.build(b.plan().?, &b, 100, 0, 0, false, true, .empty, .{ .repos_shut = &shut });
    const win = s.span(.unplanned);
    try std.testing.expectEqual(Kind.chips, s.rows[win.start].kind);
    try std.testing.expectEqual(@as(usize, 3), win.len);
    try std.testing.expectEqual(@as(?u32, 2), s.rows[win.start + 1].ticket);
    try std.testing.expectEqual(@as(?u32, 1), s.rows[win.start + 2].ticket);
    try std.testing.expect(std.mem.endsWith(u8, s.rows[win.start + 2].text, "med  ← #9"));
    s.build(b.plan().?, &b, 100, 0, 0, false, true, .empty, .{ .backlog = true });
    const back = s.span(.unplanned);
    try std.testing.expectEqual(@as(usize, 2), back.len);
    try std.testing.expectEqual(Kind.backlog, s.rows[back.start + 1].kind);
    try std.testing.expectEqual(@as(?u32, 6), s.rows[back.start + 1].ticket);
    var chips: [max_chips]Chip = undefined;
    const got = chipsAt(b.plan().?, 1, 10, 80, &chips);
    try std.testing.expectEqual(@as(usize, 3), got.len);
    try std.testing.expect(got[2].repo == null);
    try std.testing.expect(got[1].x == got[0].x + got[0].w + 1);
}
