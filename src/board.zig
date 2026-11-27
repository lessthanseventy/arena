//! babylon's board, from the file it keeps: the tickets every Claude on the machine shares.
const std = @import("std");
const builtin = @import("builtin");

/// How many times the cards have been walked; in tests only, where a frame's budget of walks is held.
pub var passes: if (builtin.is_test) usize else void = if (builtin.is_test) 0 else {};

/// `try` is landed and waiting on the human's hands: drawn in the done column, above the done cards.
pub const Status = enum { todo, doing, review, @"try", done, backlog };
pub const statuses = [_]Status{ .todo, .doing, .review, .done };

/// A decision a session is waiting on its human for.
pub const Ask = struct {
    id: u32,
    question: []const u8,
    options: []const []const u8 = &.{},
    asked_at: ?[]const u8 = null,
};

/// An open ticket of the same repo that edits the same files: `kind` is `lines` where the hunks
/// meet (a conflict is likely) or `file` where only the file is shared.
pub const Overlap = struct {
    ticket: u32,
    kind: []const u8 = "file",
    files: []const []const u8 = &.{},

    /// Whether the hunks meet, which is worse than sharing a file.
    pub fn worse(o: Overlap) bool {
        return std.mem.eql(u8, o.kind, "lines");
    }
};

/// One step of a to-try ticket: `result` is null until tried, then `ok` or `no`.
pub const Check = struct {
    n: u32,
    text: []const u8,
    result: ?[]const u8 = null,
};

/// What the builder wrote for the human to try a landed ticket: what changed, the steps, and what
/// right and wrong look like.
pub const TrySheet = struct {
    changed: []const u8 = "",
    steps: []const []const u8 = &.{},
    right: []const u8 = "",
    wrong: []const u8 = "",
};

/// Whether a ticket's number, title or repo holds `query`, letter case aside; a leading `#` is
/// the number's. Everything holds an empty query.
pub fn holds(query: []const u8, id: u32, title: []const u8, repo: []const u8) bool {
    const q = if (query.len > 0 and query[0] == '#') query[1..] else query;
    if (q.len == 0) return true;
    var number: [12]u8 = undefined;
    const digits = std.fmt.bufPrint(&number, "{d}", .{id}) catch "";
    return std.mem.indexOf(u8, digits, q) != null or
        std.ascii.findIgnoreCase(title, q) != null or
        std.ascii.findIgnoreCase(repo, q) != null;
}

pub const Card = struct {
    id: u32,
    repo: ?[]const u8 = null,
    title: []const u8,
    /// The ticket's short name, which a row shows; an older babylon sends none.
    short: ?[]const u8 = null,
    kind: []const u8 = "ticket",
    status: Status,
    priority: []const u8 = "med",
    /// The tmux pane holding it, as `%12`.
    claimed_by: ?[]const u8 = null,
    /// When it was filed, and when it was claimed, as `2026-11-21T23:20:05Z`.
    inserted_at: ?[]const u8 = null,
    claimed_at: ?[]const u8 = null,
    /// When it came to its pipeline stage, in the same form.
    stage_at: ?[]const u8 = null,
    /// The Claude model babylon starts it with, when it names one.
    model: ?[]const u8 = null,
    /// When it was handed in to the pipeline, and when it was closed, in the same form.
    submitted_at: ?[]const u8 = null,
    closed_at: ?[]const u8 = null,
    /// The pane a chain handed it to, as `%7`, until that pane claims it.
    handed_to: ?[]const u8 = null,
    /// The landed ticket whose pane still holds it, while it is handed.
    handed_from: ?u32 = null,
    /// The pane whose session handed it off to this one, as `%407`, and when, in the same form.
    handed_off_from: ?[]const u8 = null,
    handed_off_at: ?[]const u8 = null,
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
    /// Why babylon sent it back, or what its pipeline last said of it.
    stage_note: []const u8 = "",
    /// The orchestrator's open proposal about it, the oldest when there are several; set as the
    /// board is parsed, never read from a card's own fields.
    proposal: ?Proposal = null,
    /// The steps a to-try ticket waits on the human for, and when it landed.
    checks: []Check = &.{},
    @"try": ?TrySheet = null,
    landed_at: ?[]const u8 = null,
    waiting_on: ?WaitingOn = null,
    overlaps: []Overlap = &.{},
    /// For a todo card whose body names a path an open ticket edits: `waiting for #N: src/a.zig`.
    clash: ?[]const u8 = null,

    /// Whether it is an epic: a goal over other tickets, which no session ever holds.
    pub fn isEpic(card: *const Card) bool {
        return std.mem.eql(u8, card.kind, "epic");
    }

    /// Whether it is an epic that has a bar in `bars`.
    pub fn barred(card: *const Card, bars: []const Goal) bool {
        if (!card.isEpic()) return false;
        for (bars) |bar| if (bar.epic == card.id) return true;
        return false;
    }

    /// The pane holding it, as `%12`: the one that claimed it, else the one it was handed to.
    pub fn heldBy(card: *const Card) ?[]const u8 {
        return card.claimed_by orelse card.handed_to;
    }

    /// What a row shows: its short name, else its title.
    pub fn name(card: Card) []const u8 {
        return card.short orelse card.title;
    }

    /// Whether its number, title or repo holds `query`, letter case aside; a leading `#` is the
    /// number's. Everything holds an empty query.
    pub fn finds(card: *const Card, query: []const u8) bool {
        return holds(query, card.id, card.title, card.repo orelse "");
    }

    /// What changed for the human, when the builder wrote a try sheet with one.
    pub fn changed(card: *const Card) ?[]const u8 {
        const sheet = card.@"try" orelse return null;
        return if (sheet.changed.len > 0) sheet.changed else null;
    }

    /// The id of the pane holding it, if one does.
    pub fn holder(card: *const Card) ?u32 {
        const pane = card.heldBy() orelse return null;
        if (pane.len < 2 or pane[0] != '%') return null;
        return std.fmt.parseInt(u32, pane[1..], 10) catch null;
    }

    /// When it was claimed, in seconds since the epoch, if babylon says when.
    pub fn claimedAt(card: *const Card) ?i64 {
        return epochOf(card.claimed_at);
    }
};

/// One of babylon's times, as `2026-11-21T23:20:05Z`, in seconds since the epoch.
pub fn epochOf(given: ?[]const u8) ?i64 {
    const at = given orelse return null;
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

/// The slots auto has free with nothing in next to start, and why.
pub const Idle = struct { slots: u32, why: []const u8 = "" };

/// babylon's auto mode: while on, it starts a Claude on each free todo card until `cap` are working.
/// `repo_caps` is each repo's own cap, 0 for one paused.
pub const Auto = struct {
    pub const Tools = struct { working: u32 = 0, cap: u32 = 0 };
    on: bool = false,
    cap: u32 = 0,
    working: u32 = 0,
    tools: ?Tools = null,
    idle: ?Idle = null,
    repo_caps: std.json.ArrayHashMap(u32) = .{},
};

/// What holds a ticket of next back, as babylon's auto says: `why` is the reason's name, `by` the
/// ticket, ask or cap it is by when it has one.
pub const Held = struct {
    why: []const u8 = "",
    by: ?u32 = null,

    /// The one word of the row: `after #1186`, `cap full`, `needs you`. An unknown reason is shown
    /// as babylon spells it.
    pub fn word(h: Held, buf: []u8) []const u8 {
        const eql = std.mem.eql;
        if (eql(u8, h.why, "blocked")) if (h.by) |n| return std.fmt.bufPrint(buf, "waits #{d}", .{n}) catch "waits";
        if (eql(u8, h.why, "repo cap") or eql(u8, h.why, "overlap")) if (h.by) |n| return std.fmt.bufPrint(buf, "after #{d}", .{n}) catch "after";
        const words = [_][2][]const u8{
            .{ "cap", "cap full" },
            .{ "project cap", "cap full" },
            .{ "off", "auto off" },
            .{ "project off", "manual" },
            .{ "project held", "held" },
            .{ "starting", "starting" },
            .{ "asked", "asked" },
            .{ "sent back", "needs you" },
            .{ "repo not ready", "no repo dir" },
            .{ "queued", "queued" },
            .{ "not todo", "not todo" },
        };
        for (words) |pair| if (eql(u8, h.why, pair[0])) return pair[1];
        return h.why;
    }
};

/// A ticket in next, the plan's ordered list of what should start soon. `set_by` is who placed it:
/// `human` is a pin, which the orchestrator moves only with a proposal.
pub const Next = struct {
    ticket: u32,
    /// None for a ticket of no repo, as a planning ticket is.
    repo: ?[]const u8 = null,
    title: []const u8 = "",
    short: ?[]const u8 = null,
    why: []const u8 = "",
    set_by: []const u8 = "",
    waits_on: []Wait = &.{},
    /// Null when nothing holds it, or when babylon is too old to say.
    held: ?Held = null,
    actions: []NextAction = &.{},

    /// What a row shows: its short name, else its title.
    pub fn name(n: Next) []const u8 {
        return n.short orelse n.title;
    }

    pub fn pinned(n: Next) bool {
        return std.mem.eql(u8, n.set_by, "human");
    }
};

/// babylon's orchestrator: `running` while its session is there, `on` while babylon keeps it so.
pub const Orchestrator = struct { on: bool = true, running: bool = true };

/// What one of the human's moves offers: `argv` runs it, or with none, `needs` says what the
/// human must give first (`words`, `pick`) or the surface must do itself (`surface`).
pub const Action = struct {
    key: []const u8,
    label: []const u8,
    argv: ?[]const []const u8 = null,
    needs: ?[]const u8 = null,
};

/// One check of a to-try item, with the actions babylon gives it.
pub const TryStep = struct {
    n: u32,
    text: []const u8,
    /// `look` for a check to be done by reading the landed change; then `range` is its git range.
    kind: []const u8 = "",
    range: []const u8 = "",
    /// A repo path or link the check asks to be read.
    doc: ?[]const u8 = null,
    result: ?[]const u8 = null,
    actions: []Action = &.{},
};

/// One thing that is the human's move, as babylon words it: its first row and its actions.
pub const Need = struct {
    id: []const u8,
    kind: []const u8,
    ticket: ?u32 = null,
    repo: []const u8 = "",
    text: []const u8,
    /// The file or link of the ask the row is of, a look's or a decision's.
    doc: ?[]const u8 = null,
    /// Of a `try` item: what the machine did, since when it waits, and its checks.
    machine: []const u8 = "",
    since: ?[]const u8 = null,
    steps: []TryStep = &.{},
    actions: []Action = &.{},
    /// The orchestrator points at it (an `item` suggestion).
    orch: bool = false,
    /// Babylon says it is only status: arena draws it on the head, not in Your move.
    status: bool = false,
};

/// A repo's main against its origin.
pub const RepoState = struct { repo: []const u8, ahead: u32 = 0, behind: u32 = 0 };

/// One line of the orchestrator's: `text` for a line to say to it, `item` for a `needs_you` item it
/// points at, which carries that item's own `ticket` and `text`.
pub const Suggestion = struct {
    id: []const u8 = "",
    kind: []const u8 = "",
    text: []const u8 = "",
    ticket: ?u32 = null,
};

/// A move the orchestrator proposes, waiting on the human's go or no.
pub const Proposal = struct {
    id: u32,
    ticket_id: ?u32 = null,
    why: []const u8 = "",
};

/// What a ticket in next, or a goal's step, waits on: another ticket, or its repo's lane until a
/// ticket lands.
pub const Wait = struct {
    ticket: ?u32 = null,
    lane: ?[]const u8 = null,
    until: ?u32 = null,

    /// The first wait that names a ticket or a landing to wait for; a lane with no `until` is nothing.
    pub fn first(on: []const Wait) ?Wait {
        for (on) |wait| if (wait.ticket != null or wait.until != null) return wait;
        return null;
    }
};

/// Whom a ticket is waiting on: another ticket, or words, since when. Babylon sets it on a ticket
/// card and a `plan.now` row that is parked on purpose, which is not stalled.
pub const WaitingOn = struct {
    ticket: ?u32 = null,
    @"for": ?[]const u8 = null,
    since: ?[]const u8 = null,

    /// `◷ waiting on #829`, or `◷ waiting for <words>`, in `buf`.
    pub fn say(wait: WaitingOn, buf: []u8) []const u8 {
        if (wait.ticket) |id| return std.fmt.bufPrint(buf, "◷ waiting on #{d}", .{id}) catch "◷ waiting";
        if (wait.@"for") |words| return std.fmt.bufPrint(buf, "◷ waiting for {s}", .{words}) catch "◷ waiting";
        return "◷ waiting";
    }
};

/// One ticket in `plan.now`: building under a Claude's pane, or in the pipeline at a stage.
pub const NowItem = struct {
    ticket: u32,
    /// None for a ticket of no repo, as a planning ticket is.
    repo: ?[]const u8 = null,
    title: []const u8 = "",
    short: ?[]const u8 = null,
    state: []const u8 = "",
    stage: ?[]const u8 = null,
    since: ?[]const u8 = null,
    pane: ?[]const u8 = null,
    place: ?u32 = null,
    /// Why nothing is moving it (`idle 9m`, `no Claude`), when nothing is.
    stalled: ?[]const u8 = null,
    waiting_on: ?WaitingOn = null,

    /// What a row shows: its short name, else its title.
    pub fn name(item: NowItem) []const u8 {
        return item.short orelse item.title;
    }

    /// The id of the pane working it, if babylon names one.
    pub fn holder(item: *const NowItem) ?u32 {
        const pane = item.pane orelse return null;
        if (pane.len < 2 or pane[0] != '%') return null;
        return std.fmt.parseInt(u32, pane[1..], 10) catch null;
    }
};

pub const NextAction = struct {
    label: []const u8,
    argv: []const []const u8 = &.{},
};

pub const Step = struct {
    ticket: u32,
    state: []const u8 = "",
    waits_on: []Wait = &.{},
};

pub const Goal = struct {
    epic: u32,
    title: []const u8 = "",
    short: ?[]const u8 = null,
    doc: ?[]const u8 = null,
    landed: u32 = 0,
    total: u32 = 0,
    steps: []Step = &.{},

    /// What a row shows: its short name, else its title.
    pub fn name(goal: Goal) []const u8 {
        return goal.short orelse goal.title;
    }
};

/// A question the planning Claude put to the human, and their answer once given.
pub const IdeaAsk = struct {
    id: u32 = 0,
    question: []const u8 = "",
    answer: ?[]const u8 = null,
};

/// An epic that is not yet a goal: kept as `idea`, with a Claude on it as `planning`, or its
/// steps drafted and awaiting the human's look as `draft`.
pub const Idea = struct {
    epic: u32,
    title: []const u8 = "",
    short: ?[]const u8 = null,
    body: []const u8 = "",
    state: []const u8 = "idea",
    plan_ticket: ?u32 = null,
    pane: ?[]const u8 = null,
    asks: u32 = 0,
    ask_list: []IdeaAsk = &.{},
    steps: u32 = 0,
    since: ?[]const u8 = null,

    /// What a row shows: its short name, else its title.
    pub fn name(idea: Idea) []const u8 {
        return idea.short orelse idea.title;
    }

    /// The id of the pane planning it, if babylon names one.
    pub fn holder(idea: *const Idea) ?u32 {
        const pane = idea.pane orelse return null;
        if (pane.len < 2 or pane[0] != '%') return null;
        return std.fmt.parseInt(u32, pane[1..], 10) catch null;
    }
};

pub const LandedToday = struct { count: u32 = 0, newest: []u32 = &.{} };

pub const NotPlanned = struct {
    count: u32 = 0,
    follow_ups: u32 = 0,
    by_repo: std.json.ArrayHashMap(u32) = .{},
};

/// What babylon says the plan is: what is running, what comes next and why, how far each goal
/// has got, what landed and what is not planned, each in the order to draw it.
pub const Plan = struct {
    /// The epic the human picked to drive towards.
    driving: ?u32 = null,
    now: []NowItem = &.{},
    next: []Next = &.{},
    goals: []Goal = &.{},
    ideas: []Idea = &.{},
    landed_today: LandedToday = .{},
    not_planned: NotPlanned = .{},
};

/// A made project: a named set of repos.
const Project = struct { name: []const u8, repos: []const []const u8 = &.{} };

const File = struct {
    tickets: []Card,
    projects: []Project = &.{},
    backlog: []Card = &.{},
    auto: ?Auto = null,
    hold: bool = false,
    orchestrator: ?Orchestrator = null,
    proposals: []Proposal = &.{},
    needs_you: []Need = &.{},
    suggestions: []Suggestion = &.{},
    said: []Need = &.{},
    plan: ?Plan = null,
};

/// The most text suggestions the drawer's foot holds.
pub const said_max = 6;

pub const Board = struct {
    parsed: std.json.Parsed(File),
    /// Babylon's own needs_you while `parsed` holds it with arena's own after it, and the arena
    /// those are copied into.
    given: ?[]Need = null,
    own: ?std.heap.ArenaAllocator = null,
    /// Found once at parse, since a frame asks for them on every line it draws.
    names: []const []const u8 = &.{},
    lane_names: []const []const u8 = &.{},
    /// The `needs_you` items babylon marks `status`: its restart waiting on the gates running, and
    /// a repo's unpushed commits. Taken out of `needs_you` at parse.
    restart: ?[]const u8 = null,
    repo_states: []const RepoState = &.{},

    pub fn parse(gpa: std.mem.Allocator, text: []const u8) !Board {
        var parsed = try std.json.parseFromSlice(File, gpa, text, .{ .ignore_unknown_fields = true, .allocate = .alloc_always });
        errdefer parsed.deinit();
        const arena = parsed.arena.allocator();
        for (parsed.value.tickets) |*card| {
            card.title = try cleanLine(arena, card.title);
            if (card.short) |short| card.short = try cleanLine(arena, short);
            card.session_note = try cleanLine(arena, card.session_note);
            card.stage_note = try cleanLine(arena, card.stage_note);
            if (card.waiting_on) |*wait| if (wait.@"for") |words| {
                wait.@"for" = try cleanLine(arena, words);
            };
            for (card.checks) |*check| check.text = try cleanLine(arena, check.text);
            if (card.@"try") |*sheet| {
                sheet.changed = try cleanLine(arena, sheet.changed);
                sheet.right = try cleanLine(arena, sheet.right);
                sheet.wrong = try cleanLine(arena, sheet.wrong);
                const steps = try arena.alloc([]const u8, sheet.steps.len);
                for (sheet.steps, steps) |step, *slot| slot.* = try cleanLine(arena, step);
                sheet.steps = steps;
            }
            if (card.clash) |words| card.clash = try cleanLine(arena, words);
            for (card.overlaps) |*overlap| {
                const files = try arena.alloc([]const u8, overlap.files.len);
                for (overlap.files, files) |file, *slot| slot.* = try cleanLine(arena, file);
                overlap.files = files;
            }
        }
        for (parsed.value.backlog) |*card| {
            card.title = try cleanLine(arena, card.title);
            if (card.short) |short| card.short = try cleanLine(arena, short);
        }
        for (parsed.value.needs_you) |*need| {
            // a to-try ticket is closed by answering its checks, or from its card
            if (std.mem.eql(u8, need.kind, "try")) need.actions = &.{};
            need.text = try cleanLine(arena, need.text);
            need.machine = try cleanLine(arena, need.machine);
            for (need.actions) |*action| action.label = try cleanLine(arena, action.label);
            for (need.steps) |*step| {
                step.text = try cleanLine(arena, step.text);
                for (step.actions) |*action| action.label = try cleanLine(arena, action.label);
            }
        }
        var restart: ?[]const u8 = null;
        var states: std.ArrayList(RepoState) = .empty;
        var kept: usize = 0;
        const all = parsed.value.needs_you;
        for (all) |need| {
            if (!need.status) {
                all[kept] = need;
                kept += 1;
            } else if (std.mem.eql(u8, need.kind, "push")) {
                try states.append(arena, .{ .repo = need.repo, .ahead = countBefore(need.text, " unpushed") });
            } else if (std.mem.eql(u8, need.id, "restart-pending")) {
                restart = need.text;
            } else {
                all[kept] = need;
                kept += 1;
            }
        }
        parsed.value.needs_you = all[0..kept];
        try suggest(arena, &parsed.value);
        if (parsed.value.plan) |*given| {
            for (given.now) |*item| {
                item.title = try cleanLine(arena, item.title);
                if (item.short) |short| item.short = try cleanLine(arena, short);
                if (item.repo) |repo| item.repo = try cleanLine(arena, repo);
                if (item.stalled) |why| item.stalled = try cleanLine(arena, why);
                if (item.waiting_on) |*wait| if (wait.@"for") |words| {
                    wait.@"for" = try cleanLine(arena, words);
                };
            }
            for (given.next) |*item| {
                if (item.repo) |repo| item.repo = try cleanLine(arena, repo);
                item.title = try cleanLine(arena, item.title);
                if (item.short) |short| item.short = try cleanLine(arena, short);
                item.why = try cleanLine(arena, item.why);
            }
            for (given.goals) |*goal| {
                goal.title = try cleanLine(arena, goal.title);
                if (goal.short) |short| goal.short = try cleanLine(arena, short);
            }
            for (given.ideas) |*idea| {
                idea.title = try cleanLine(arena, idea.title);
                if (idea.short) |short| idea.short = try cleanLine(arena, short);
                idea.body = try cleanLine(arena, idea.body);
                for (idea.ask_list) |*ask| {
                    ask.question = try cleanLine(arena, ask.question);
                    if (ask.answer) |answer| ask.answer = try cleanLine(arena, answer);
                }
            }
        }
        for (parsed.value.proposals) |*proposal| {
            proposal.why = try cleanLine(arena, proposal.why);
            const id = proposal.ticket_id orelse continue;
            for ([_][]Card{ parsed.value.tickets, parsed.value.backlog }) |list| for (list) |*card| {
                if (card.id == id and card.proposal == null) card.proposal = proposal.*;
            };
        }
        var b: Board = .{ .parsed = parsed, .restart = restart, .repo_states = states.items };
        b.names = try b.findRepos(arena);
        b.lane_names = try b.findLanes(arena);
        return b;
    }

    /// The number that ends the words before `word` in `text`, 0 when there is none.
    fn countBefore(text: []const u8, word: []const u8) u32 {
        const at = std.mem.indexOf(u8, text, word) orelse return 0;
        var start = at;
        while (start > 0 and std.ascii.isDigit(text[start - 1])) start -= 1;
        return std.fmt.parseInt(u32, text[start..at], 10) catch 0;
    }

    /// The commits main is ahead of origin's, summed over the repos.
    pub fn unpushed(b: *const Board) u32 {
        var sum: u32 = 0;
        for (b.repo_states) |s| sum += s.ahead;
        return sum;
    }

    /// What babylon says of `repo`'s main against its origin; level when it says nothing.
    pub fn repoState(b: *const Board, repo: []const u8) RepoState {
        for (b.repo_states) |s| if (std.mem.eql(u8, s.repo, repo)) return s;
        return .{ .repo = repo };
    }

    /// The tickets babylon's restart waits on, as `#12, #13`; empty when it says none.
    pub fn restartAfter(b: *const Board) []const u8 {
        const text = b.restart orelse return "";
        const from = (std.mem.indexOf(u8, text, "until ") orelse return "") + "until ".len;
        const to = std.mem.indexOfPos(u8, text, from, " finish") orelse return "";
        return text[from..to];
    }

    fn findRepos(b: *const Board, arena: std.mem.Allocator) ![]const []const u8 {
        var names: std.ArrayList([]const u8) = .empty;
        for (b.cards()) |card| {
            const repo = card.repo orelse continue;
            const seen = for (names.items) |had| {
                if (std.mem.eql(u8, had, repo)) break true;
            } else false;
            if (!seen) try names.append(arena, repo);
        }
        std.mem.sort([]const u8, names.items, {}, struct {
            fn before(_: void, a: []const u8, z: []const u8) bool {
                return std.mem.order(u8, a, z) == .lt;
            }
        }.before);
        return names.items;
    }

    /// How many of the last closed the recent strip shows.
    pub const recent_n = 5;

    fn findLanes(b: *const Board, arena: std.mem.Allocator) ![]const []const u8 {
        var found: std.ArrayList([]const u8) = .empty;
        var recent: [recent_n]*const Card = undefined;
        const shown = @min(b.column(.done, null, "", &recent), recent_n);
        for (b.names) |repo| {
            const live = for (b.cards()) |card| {
                const open = card.status == .todo or card.status == .doing or card.status == .review;
                if (open and std.mem.eql(u8, card.repo orelse "", repo)) break true;
            } else false;
            const closed = for (recent[0..shown]) |card| {
                if (std.mem.eql(u8, card.repo orelse "", repo)) break true;
            } else false;
            if (live or closed) try found.append(arena, repo);
        }
        for (b.cards()) |card| if (card.repo == null and card.status != .done) {
            try found.append(arena, "");
            break;
        };
        return found.items;
    }

    fn cleanLine(arena: std.mem.Allocator, text: []const u8) ![]const u8 {
        if (text.len == 0) return text;
        var clean: std.ArrayList(u8) = .empty;
        try @import("text.zig").appendClean(&clean, arena, text);
        std.mem.replaceScalar(u8, clean.items, '\n', ' ');
        return clean.items;
    }

    /// Lifts the `needs_you` items the suggestions point at to the top, in the suggestions' order,
    /// marked, and keeps the text suggestions apart in `said`, kind `suggest`, not in Your move. A
    /// suggestion of another kind, or pointing at an item that is gone, is dropped.
    fn suggest(arena: std.mem.Allocator, file: *File) !void {
        if (file.suggestions.len == 0) return;
        const lines = try arena.alloc(Need, @min(file.suggestions.len, said_max));
        var said_n: usize = 0;
        for (file.suggestions) |s| {
            if (!std.mem.eql(u8, s.kind, "text") or said_n == lines.len) continue;
            lines[said_n] = .{ .id = s.id, .kind = "suggest", .ticket = s.ticket, .text = try cleanLine(arena, s.text) };
            said_n += 1;
        }
        file.said = lines[0..said_n];
        const out = try arena.alloc(Need, file.needs_you.len);
        const taken = try arena.alloc(bool, file.needs_you.len);
        @memset(taken, false);
        var n: usize = 0;
        for (file.suggestions) |s| {
            if (!std.mem.eql(u8, s.kind, "item")) continue;
            const text = try cleanLine(arena, s.text);
            for (file.needs_you, taken, 0..) |need, *gone, at| {
                if (gone.* or need.ticket != s.ticket or !std.mem.eql(u8, need.text, text)) continue;
                gone.* = true;
                out[n] = file.needs_you[at];
                out[n].orch = true;
                n += 1;
                break;
            }
        }
        for (file.needs_you, taken) |need, gone| if (!gone) {
            out[n] = need;
            n += 1;
        };
        file.needs_you = out[0..n];
    }

    pub fn deinit(b: *Board) void {
        if (b.own) |*own| own.deinit();
        b.parsed.deinit();
    }

    /// Puts `items`, copied, after babylon's own in Your move, in place of the ones put there before.
    pub fn setOwn(b: *Board, gpa: std.mem.Allocator, items: []const Need) !void {
        const given = b.given orelse b.parsed.value.needs_you;
        var own = if (b.own) |*old| old.* else std.heap.ArenaAllocator.init(gpa);
        errdefer own.deinit();
        _ = own.reset(.free_all);
        const out = try own.allocator().alloc(Need, given.len + items.len);
        @memcpy(out[0..given.len], given);
        for (items, out[given.len..]) |item, *slot| {
            slot.* = item;
            slot.id = try own.allocator().dupe(u8, item.id);
            slot.text = try own.allocator().dupe(u8, item.text);
            slot.repo = try own.allocator().dupe(u8, item.repo);
        }
        b.given = given;
        b.own = own;
        b.parsed.value.needs_you = out;
    }

    pub fn cards(b: *const Board) []const Card {
        if (builtin.is_test) passes += 1;
        return b.parsed.value.tickets;
    }

    /// What is the human's move, in the order babylon gives it.
    pub fn needsYou(b: *const Board) []const Need {
        return b.parsed.value.needs_you;
    }

    /// The lines the orchestrator suggests saying to it, for the drawer's foot.
    pub fn said(b: *const Board) []const Need {
        return b.parsed.value.said;
    }

    /// The Your move item asking what goal to drive towards next, when babylon gives one.
    pub fn driveNeed(b: *const Board) ?*const Need {
        for (b.needsYou()) |*need| {
            if (std.mem.eql(u8, need.kind, "drive")) return need;
        }
        return null;
    }

    /// The Your move item of ticket `id`'s open ask, when babylon gives one.
    pub fn askNeed(b: *const Board, id: u32) ?*const Need {
        for (b.needsYou()) |*need| {
            if (std.mem.eql(u8, need.kind, "ask") and need.ticket == id) return need;
        }
        return null;
    }

    /// What babylon says the plan is, when its file says one.
    pub fn plan(b: *const Board) ?*const Plan {
        return if (b.parsed.value.plan) |*p| p else null;
    }

    /// Auto mode's cap and the Claudes working, while it is on.
    pub fn auto(b: *const Board) ?Auto {
        const state = b.parsed.value.auto orelse return null;
        return if (state.on) state else null;
    }

    /// Auto mode's state on or off, when babylon's file says it.
    pub fn autoState(b: *const Board) ?Auto {
        return b.parsed.value.auto;
    }

    /// Whether babylon holds its pipeline.
    pub fn hold(b: *const Board) bool {
        return b.parsed.value.hold;
    }

    /// The plan's next, in order.
    pub fn next(b: *const Board) []const Next {
        return if (b.parsed.value.plan) |given| given.next else &.{};
    }

    /// The name of the project `repo` is in, when it is in one.
    pub fn projectOf(b: *const Board, repo: []const u8) ?[]const u8 {
        for (b.parsed.value.projects) |project| for (project.repos) |r| {
            if (std.mem.eql(u8, r, repo)) return project.name;
        };
        return null;
    }

    /// What babylon says of its orchestrator, when its file does.
    pub fn orchestrator(b: *const Board) ?Orchestrator {
        return b.parsed.value.orchestrator;
    }

    /// The cards with a proposal on them.
    pub fn proposedCount(b: *const Board) usize {
        var n: usize = 0;
        for ([_][]const Card{ b.cards(), b.backlog() }) |list| for (list) |card| {
            if (card.proposal != null) n += 1;
        };
        return n;
    }

    /// The id of the card with the oldest open proposal on it.
    pub fn oldestProposed(b: *const Board) ?u32 {
        for (b.parsed.value.proposals) |proposal| {
            const id = proposal.ticket_id orelse continue;
            for ([_][]const Card{ b.cards(), b.backlog() }) |list| for (list) |card| {
                if (card.id == id) return id;
            };
        }
        return null;
    }

    /// The cards waiting to be put on the board, by repo then board order.
    pub fn backlog(b: *const Board) []const Card {
        if (builtin.is_test) passes += 1;
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
        const n = @min(out.len, b.names.len);
        @memcpy(out[0..n], b.names[0..n]);
        return n;
    }

    /// The repos with a card to do, doing or in review, in order of name, then "" when a card of
    /// none is not done.
    pub fn lanes(b: *const Board) []const []const u8 {
        return b.lane_names;
    }

    /// How many cards of `status` are work for a Claude, the epics left out, narrowed by `find`.
    pub fn work(b: *const Board, status: Status, find: []const u8) usize {
        var n: usize = 0;
        for (b.cards()) |*card| n += @intFromBool((card.status == status or (status == .done and card.status == .@"try")) and !card.isEpic() and card.finds(find));
        return n;
    }

    /// How far an epic has got, from the tickets that name it as theirs: those landed of all. An
    /// epic whose children the board does not list has its goal's own count, else none.
    pub fn epicProgress(b: *const Board, epic: u32) ?struct { landed: u32, total: u32 } {
        var landed: u32 = 0;
        var total: u32 = 0;
        for (b.cards()) |card| if (card.epic_id == epic) {
            total += 1;
            landed += @intFromBool(card.status == .done or card.status == .@"try");
        };
        if (total > 0) return .{ .landed = landed, .total = total };
        const given = b.plan() orelse return null;
        for (given.goals) |goal| if (goal.epic == epic) return .{ .landed = goal.landed, .total = goal.total };
        return null;
    }

    /// The cards in `status`'s column, of `repo` alone when given and matching `find`, in board
    /// order with those waiting on others last, as many as fit in `out`; the count of them all.
    pub fn column(b: *const Board, status: Status, repo: ?[]const u8, find: []const u8, out: []*const Card) usize {
        return b.columnBars(status, repo, find, &.{}, out);
    }

    /// `column` without the epics that have a bar in `bars`: an epic with none stays a card.
    pub fn columnBars(b: *const Board, status: Status, repo: ?[]const u8, find: []const u8, bars: []const Goal, out: []*const Card) usize {
        var n: usize = 0;
        const shown: []const Status = if (status == .done) &.{ .@"try", .done } else &.{status};
        for (shown) |of| for ([_]bool{ false, true }) |waiting| for (b.cards()) |*card| {
            if (card.status != of or (card.blocked_by.len > 0) != waiting or card.barred(bars)) continue;
            if (repo) |only| if (!std.mem.eql(u8, card.repo orelse "", only)) continue;
            if (!card.finds(find)) continue;
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
    try std.testing.expectEqual(@as(?u32, null), b.cards()[0].handed_from);
    try std.testing.expectEqual(@as(?u32, 12), b.cards()[1].holder());
    try std.testing.expectEqual(@as(?u32, null), b.cards()[0].holder());
    try std.testing.expectEqualSlices(u32, &.{1}, b.cards()[2].blocked_by);
    try std.testing.expectEqualStrings("its session is left running: it holds #6", b.cards()[3].session_note);
    try std.testing.expectEqualStrings("", b.cards()[0].session_note);
}

test "a todo card handed to a pane is held by it until the pane claims it" {
    var b = try Board.parse(std.testing.allocator,
        \\{"tickets":[{"id":6,"title":"Handed","status":"todo","handed_to":"%7","handed_from":4},
        \\{"id":7,"title":"Claimed","status":"doing","claimed_by":"%9","handed_to":null,"handed_from":null}]}
    );
    defer b.deinit();
    try std.testing.expectEqual(@as(?u32, 7), b.cards()[0].holder());
    try std.testing.expectEqual(@as(?u32, 4), b.cards()[0].handed_from);
    try std.testing.expectEqual(@as(?u32, 9), b.cards()[1].holder());
}

test "a card says which pane handed it off and when" {
    var b = try Board.parse(std.testing.allocator,
        \\{"tickets":[{"id":6,"title":"Fresh","status":"doing","claimed_by":"%9","handed_off_from":"%407","handed_off_at":"2026-11-24T21:00:00Z"},
        \\{"id":7,"title":"Plain","status":"doing","claimed_by":"%8","handed_off_from":null,"handed_off_at":null}]}
    );
    defer b.deinit();
    try std.testing.expectEqualStrings("%407", b.cards()[0].handed_off_from.?);
    try std.testing.expectEqualStrings("2026-11-24T21:00:00Z", b.cards()[0].handed_off_at.?);
    try std.testing.expectEqual(@as(?[]const u8, null), b.cards()[1].handed_off_from);
}

test "a note's escapes and control characters are gone once the board is parsed, and it is one line" {
    var b = try Board.parse(std.testing.allocator,
        \\{"tickets":[{"id":1,"title":"Board","status":"done","session_note":"\u001b[31mit holds\u0007\n#6\u001b]0;t\u0007"}]}
    );
    defer b.deinit();
    try std.testing.expectEqualStrings("it holds #6", b.cards()[0].session_note);
}

test "a stage note's escapes and control characters are gone once the board is parsed, and it is one line" {
    var b = try Board.parse(std.testing.allocator,
        \\{"tickets":[{"id":1,"title":"Board","status":"doing","stage_note":"\u001b[31msent back\u0007\nwhy\u001b]0;t\u0007"}]}
    );
    defer b.deinit();
    try std.testing.expectEqualStrings("sent back why", b.cards()[0].stage_note);
}

test "a title's escapes and control characters are gone once the board is parsed" {
    var b = try Board.parse(std.testing.allocator,
        \\{"tickets":[{"id":1,"title":"\u001b[31mBo\u0007ard\n2","status":"done"}],"backlog":[{"id":7,"title":"\u001b]0;t\u0007later","status":"backlog"}]}
    );
    defer b.deinit();
    try std.testing.expectEqualStrings("Board 2", b.cards()[0].title);
    try std.testing.expectEqualStrings("later", b.parsed.value.backlog[0].title);
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
    try std.testing.expectEqual(@as(usize, 3), b.column(.todo, null, "", &out));
    try std.testing.expectEqual(@as(u32, 3), out[0].id);
    try std.testing.expectEqual(@as(u32, 2), out[2].id);
    try std.testing.expectEqual(@as(usize, 1), b.column(.todo, "arena", "", &out));
    try std.testing.expectEqual(@as(u32, 2), out[0].id);
    try std.testing.expectEqual(@as(usize, 0), b.column(.done, null, "", &out));
}

test "an epic is left out of a column only while it has a bar, and counted from its children" {
    var b = try Board.parse(std.testing.allocator,
        \\{"tickets":[{"id":1,"kind":"epic","title":"goal","status":"doing"},{"id":2,"title":"step","status":"doing","epic_id":1},{"id":3,"title":"landed","status":"done","epic_id":1}]}
    );
    defer b.deinit();
    var out: [4]*const Card = undefined;
    try std.testing.expectEqual(@as(usize, 2), b.column(.doing, null, "", &out));
    const bars = [_]Goal{.{ .epic = 1 }};
    try std.testing.expectEqual(@as(usize, 1), b.columnBars(.doing, null, "", &bars, &out));
    try std.testing.expectEqual(@as(u32, 2), out[0].id);
    try std.testing.expectEqual(@as(usize, 1), b.work(.doing, ""));
    const progress = b.epicProgress(1).?;
    try std.testing.expectEqual(@as(u32, 1), progress.landed);
    try std.testing.expectEqual(@as(u32, 2), progress.total);
}

test "a try card parses its checks, counts as landed, and is first in the done column" {
    var b = try Board.parse(std.testing.allocator,
        \\{"tickets":[
        \\{"id":1,"title":"e","kind":"epic","status":"doing"},
        \\{"id":2,"epic_id":1,"title":"old","status":"done"},
        \\{"id":3,"epic_id":1,"title":"fresh","status":"try","landed_at":"2026-11-24T21:02:00Z",
        \\ "checks":[{"n":1,"text":"it is told","result":null},{"n":2,"text":"spend matches","result":"ok"}]}
        \\]}
    );
    defer b.deinit();
    var out: [4]*const Card = undefined;
    try std.testing.expectEqual(@as(usize, 2), b.column(.done, null, "", &out));
    try std.testing.expectEqual(@as(u32, 3), out[0].id);
    try std.testing.expectEqual(Status.@"try", out[0].status);
    try std.testing.expectEqual(@as(usize, 2), out[0].checks.len);
    try std.testing.expectEqualStrings("it is told", out[0].checks[0].text);
    try std.testing.expectEqual(@as(?[]const u8, null), out[0].checks[0].result);
    try std.testing.expectEqualStrings("ok", out[0].checks[1].result.?);
    try std.testing.expectEqualStrings("2026-11-24T21:02:00Z", out[0].landed_at.?);
    try std.testing.expectEqual(@as(usize, 0), b.column(.review, null, "", &out));
    try std.testing.expectEqual(@as(u32, 2), b.epicProgress(1).?.landed);
}

test "find keeps the cards whose number, title or repo hold it, letter case aside" {
    var b = try Board.parse(std.testing.allocator, sample);
    defer b.deinit();
    var out: [8]*const Card = undefined;
    try std.testing.expectEqual(@as(usize, 1), b.column(.todo, null, "hous", &out));
    try std.testing.expectEqual(@as(u32, 3), out[0].id);
    try std.testing.expectEqual(@as(usize, 1), b.column(.todo, null, "ARENA", &out));
    try std.testing.expectEqual(@as(u32, 2), out[0].id);
    try std.testing.expectEqual(@as(usize, 1), b.column(.todo, null, "#5", &out));
    try std.testing.expectEqual(@as(u32, 5), out[0].id);
    try std.testing.expectEqual(@as(usize, 0), b.column(.todo, null, "nothing", &out));
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
    for (statuses) |status| try std.testing.expectEqual(@as(usize, if (status == .todo) 1 else 0), b.column(status, null, "", &out));
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
    try std.testing.expectEqual(@as(?Auto.Tools, null), on.auto().?.tools);
}

test "auto's tools slots are read when babylon gives them" {
    var b = try Board.parse(std.testing.allocator,
        \\{"tickets":[],"auto":{"on":true,"cap":4,"working":4,"tools":{"working":1,"cap":2}}}
    );
    defer b.deinit();
    try std.testing.expectEqual(@as(u32, 1), b.auto().?.tools.?.working);
    try std.testing.expectEqual(@as(u32, 2), b.auto().?.tools.?.cap);
}

test "next, hold and auto's repo caps are read as babylon gives them" {
    var b = try Board.parse(std.testing.allocator,
        \\{"tickets":[],"hold":true,"auto":{"on":true,"cap":6,"working":5,"idle":{"slots":2,"why":"next empty"},"repo_caps":{"arena":3,"tlon":0}},
        \\"plan":{"next":[{"ticket":655,"repo":"arena","title":"Typing\nreaches","why":"third sighting","set_by":"human"},{"ticket":9}]}}
    );
    defer b.deinit();
    try std.testing.expect(b.hold());
    try std.testing.expectEqual(@as(u32, 2), b.autoState().?.idle.?.slots);
    try std.testing.expectEqual(@as(u32, 0), b.autoState().?.repo_caps.map.get("tlon").?);
    try std.testing.expectEqual(@as(usize, 2), b.next().len);
    try std.testing.expectEqualStrings("Typing reaches", b.next()[0].title);
    try std.testing.expect(b.next()[0].pinned() and !b.next()[1].pinned());
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

test "proposals are read, each found by its ticket, and counted only where the board has the ticket" {
    var b = try Board.parse(std.testing.allocator,
        \\{"tickets":[{"id":1,"title":"a","status":"todo"},{"id":2,"title":"b","status":"doing"}],
        \\"proposals":[{"id":9,"action":"close","ticket_id":3,"what":"x","why":"gone"},
        \\{"id":10,"action":"start","ticket_id":2,"what":"y","why":"Next\nin line"},
        \\{"id":11,"action":"start","ticket_id":1,"what":"z"},{"id":12,"action":"note","what":"w"}]}
    );
    defer b.deinit();
    try std.testing.expectEqual(@as(usize, 2), b.proposedCount());
    try std.testing.expectEqual(@as(?u32, 2), b.oldestProposed());
    try std.testing.expectEqual(@as(u32, 11), b.cards()[0].proposal.?.id);
    try std.testing.expectEqualStrings("Next in line", b.cards()[1].proposal.?.why);
    var old = try Board.parse(std.testing.allocator, sample);
    defer old.deinit();
    try std.testing.expectEqual(@as(usize, 0), old.proposedCount());
    try std.testing.expectEqual(@as(?u32, null), old.oldestProposed());
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

test "overlaps and clash come from the board json, and a clash is one clean line" {
    var b = try Board.parse(std.testing.allocator,
        \\{"tickets":[{"id":1,"title":"A","status":"doing","overlaps":[{"ticket":7,"kind":"lines","files":["src/draw.zig","src/app.zig"]}]},
        \\{"id":2,"title":"B","status":"todo","clash":"waiting for #7:\u001b[31m src/a.zig\n"},
        \\{"id":3,"title":"C","status":"todo"}]}
    );
    defer b.deinit();
    const cards = b.cards();
    try std.testing.expectEqual(@as(usize, 1), cards[0].overlaps.len);
    try std.testing.expect(cards[0].overlaps[0].worse());
    try std.testing.expectEqualStrings("src/app.zig", cards[0].overlaps[0].files[1]);
    try std.testing.expectEqualStrings("waiting for #7: src/a.zig ", cards[1].clash.?);
    try std.testing.expect(cards[2].clash == null and cards[2].overlaps.len == 0);
}

test "waiting_on says whom a card or a now row waits on, ticket or words" {
    var b = try Board.parse(std.testing.allocator,
        \\{"tickets":[{"id":1,"title":"A","status":"doing","waiting_on":{"ticket":829,"for":null,"since":"2026-11-24T21:00:00Z"}},
        \\{"id":2,"title":"B","status":"doing","waiting_on":{"ticket":null,"for":"the human","since":null}},
        \\{"id":3,"title":"C","status":"doing","waiting_on":null}],
        \\"plan":{"now":[{"ticket":1,"waiting_on":{"ticket":829}}]}}
    );
    defer b.deinit();
    var buf: [96]u8 = undefined;
    try std.testing.expectEqualStrings("◷ waiting on #829", b.cards()[0].waiting_on.?.say(&buf));
    try std.testing.expectEqualStrings("◷ waiting for the human", b.cards()[1].waiting_on.?.say(&buf));
    try std.testing.expectEqual(@as(?WaitingOn, null), b.cards()[2].waiting_on);
    try std.testing.expectEqualStrings("◷ waiting on #829", b.plan().?.now[0].waiting_on.?.say(&buf));
}

test "babylon's own board parses with its plan, a planning ticket of no repo in now too" {
    var b = try Board.parse(std.testing.allocator, @embedFile("fixtures/board.json"));
    defer b.deinit();
    const given = b.plan().?;
    try std.testing.expectEqual(@as(u32, 1136), given.now[0].ticket);
    try std.testing.expectEqual(@as(?[]const u8, null), given.now[0].repo);
    try std.testing.expect(given.next.len > 0 and given.goals.len > 0);
}

test "an item suggestion lifts and marks the needs_you item it copies, a text one is a row of its own, and others are dropped" {
    var b = try Board.parse(std.testing.allocator,
        \\{"tickets":[],"needs_you":[
        \\{"id":"a","kind":"push","ticket":1,"repo":"arena","text":"push one"},
        \\{"id":"b","kind":"proposal","ticket":2,"repo":"arena","text":"go two"}],
        \\"suggestions":[
        \\{"id":"suggestion:1","kind":"item","text":"go two","ticket":2,"actions":[]},
        \\{"id":"suggestion:2","kind":"text","text":"rebase #7","ticket":null,"actions":[]},
        \\{"id":"suggestion:3","kind":"item","text":"gone","ticket":9,"actions":[]},
        \\{"id":"suggestion:4","kind":"new-kind","text":"x"}]}
    );
    defer b.deinit();
    const needs = b.needsYou();
    try std.testing.expectEqual(@as(usize, 2), needs.len);
    try std.testing.expectEqualStrings("b", needs[0].id);
    try std.testing.expect(needs[0].orch and !needs[1].orch);
    try std.testing.expectEqualStrings("a", needs[1].id);
    try std.testing.expectEqual(@as(usize, 1), b.said().len);
    try std.testing.expectEqualStrings("suggest", b.said()[0].kind);
    try std.testing.expectEqualStrings("rebase #7", b.said()[0].text);
    var old = try Board.parse(std.testing.allocator, sample);
    defer old.deinit();
    try std.testing.expectEqual(@as(usize, 0), old.needsYou().len);
}
