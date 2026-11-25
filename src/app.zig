const std = @import("std");
const vt = @import("ghostty-vt");
const control = @import("control.zig");
const layout = @import("layout.zig");
const keys = @import("keys.zig");
const menu = @import("menu.zig");
const color = @import("color.zig");
const Theme = @import("theme.zig").Theme;
const Roles = @import("theme.zig").Roles;
const Pass = @import("pass.zig").Pass;
const tickets = @import("board.zig");
const feed = @import("feed.zig");
const autos = @import("auto.zig");
const goal_modal = @import("goal.zig");
const sheets = @import("plan.zig");
const capture = @import("report.zig");
const draw = @import("draw.zig");
const build_options = @import("build_options");
const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;

pub const rail_button = "≡ menu";
pub const rail_new = "+ new";
const history_lines = 5000;
const rail_wide = 36;
const rail_narrow = 10;
/// How long the pointer rests on the narrow rail before it is drawn wide over the strip.
const dwell_ms = 300;
/// How long the pointer or the pick rests on a ticket or a Claude before a peek opens, and how often an open one is drawn again.
const look_ms = 400;
const look_live_ms = 500;
const quiet_s = 600;
const stir_s = 60;
/// A tmux `run-shell -b` of `cmd` whose output tmux never shows: it would open view mode on a pane,
/// which swallows every key typed to it. What it prints, a refusal, goes to a notification.
fn captured(comptime cmd: []const u8) []const u8 {
    return "run-shell -b \"out=\\$(" ++ cmd ++ " 2>&1) || " ++
        "{{ command -v notify-send >/dev/null && notify-send -a arena -- \\\"\\$out\\\"; }}\"";
}

/// How long arena keeps trying to have a Claude show a subagent, how long it leaves a key to be
/// drawn before it reads the screen again, and how many Downs it sends to reach the list.
const pick_ms = 3000;
/// How long the auto switch, asked "turn off?", waits for the second click.
const auto_confirm_ms = 3000;
const pick_key_ms = 150;
const pick_downs = 3;
pub const max_tabs = 32;
pub const tab_name = 16;
/// Wheel and swipe steps that move between windows or sessions are taken this far apart.
const nav_gap_ms = 150;
/// A turn of the wheel over the rail's agents scrolls them this many Claudes.
const wheel_agents = 3;

/// A sideways swipe steps once it has gone this many wheel events one way.
const swipe_events = 3;

/// Two clicks on a name this close together ask to rename it.
const double_click_ms = 400;

/// tmux has no order of sessions to change, so arena keeps each one's place in an option on it.
const session_format = "#{{session_id}} #{{?@arena_order,#{{@arena_order}},-}} #{{session_name}}";
/// A pane's @arena_claude, set by Claude Code's hooks, comes as its `Mark`'s number.
const claude_state = "#{{?#{{==:#{{@arena_claude}},background}},1,#{{?#{{==:#{{@arena_claude}},working}},2," ++
    "#{{?#{{==:#{{@arena_claude}},done}},3,#{{?#{{==:#{{@arena_claude}},waiting}},4," ++
    "#{{?#{{==:#{{@arena_claude}},stalled}},5,0}}}}}}}}}}";
/// A pane's @arena_review, set from its branch's code review, comes as its `Review`'s number.
const review_state = "#{{?#{{==:#{{@arena_review}},landed}},1,#{{?#{{==:#{{@arena_review}},reviewed}},2," ++
    "#{{?#{{==:#{{@arena_review}},queued}},3,#{{?#{{==:#{{@arena_review}},changes}},4,0}}}}}}}}";
const pane_format = "#{{session_id}} #{{window_id}} #{{pane_id}} #{{window_width}} #{{window_height}} " ++
    "#{{pane_left}} #{{pane_top}} #{{pane_width}} #{{pane_height}} #{{pane_active}} #{{window_active}} " ++
    claude_state ++ " #{{window_cell_width}} #{{window_cell_height}} #{{?@arena_width,#{{@arena_width}},0}} " ++
    review_state ++ " #{{?@arena_claude_since,#{{@arena_claude_since}},0}} " ++
    "#{{?@arena_claude_tokens,#{{@arena_claude_tokens}},0}} #{{?@arena_claude_at,#{{@arena_claude_at}},0}} " ++
    "#{{?@arena_claude_took,#{{@arena_claude_took}},0}} #{{?@arena_claude_ctx,#{{@arena_claude_ctx}},0}} " ++
    "#{{?@arena_claude_stirred,#{{@arena_claude_stirred}},0}} #{{?window_bell_flag,2,#{{?window_activity_flag,1,0}}}} " ++
    "#{{@arena_claude_doing}}\t#{{@arena_claude_prompt}}\t#{{@arena_claude_title}}\t#{{@arena_claude_said}}\t" ++
    "#{{@arena_claude_branch}}\t#{{@arena_claude_background}}\t#{{@arena_claude_agents}}\t#{{window_name}}";

/// The least and the most of the view a window's column is given, in hundredths, and how much
/// one press of narrower or wider changes it.
const min_share = 20;
const max_share = 100;
const share_step = 10;

/// What the Claude in a window not being looked at is doing: between turns with work of its own
/// running in the background, working, done and not yet looked at, waiting on an answer, or
/// stalled: its turn ended on an API error. In rising order of how much it wants looking at.
pub const Mark = enum { none, background, working, done, waiting, stalled };
/// What tmux saw in a window out of view: output, where `monitor-activity` is on, or a bell.
pub const Alert = enum { none, activity, bell };
/// Where the branch a window's panes are on stands in code review: landed, approved, in the
/// merge queue, or with changes requested. In rising order of how much it wants looking at.
pub const Review = enum {
    none,
    landed,
    reviewed,
    queued,
    changes,

    /// The state tmux's `review_state` gave as a number; anything else is `none`.
    pub fn of(n: u32) Review {
        return if (n <= @backingInt(Review.changes)) @fromBackingInt(@intCast(n)) else .none;
    }
};
const mode_flags = "#{{alternate_on}} #{{?cursor_flag,0,1}} #{{mouse_standard_flag}} #{{mouse_button_flag}} #{{mouse_all_flag}} #{{mouse_sgr_flag}}";
/// What to feed a pane's terminal for each of `mode_flags` that is 1, in the same order.
const mode_sets = [_][]const u8{ "\x1b[?1049h", "\x1b[?25l", "\x1b[?1000h", "\x1b[?1002h", "\x1b[?1003h", "\x1b[?1006h" };

pub const Pane = struct {
    id: u32,
    /// Where the pane sits in its window, in cells.
    x: u16 = 0,
    y: u16 = 0,
    term: vt.Terminal,
    stream: vt.TerminalStream,
    render: vt.RenderState = .empty,
    pass: Pass = .{},
    /// A pane's output is dropped until its captured screen has been fed in: the capture holds
    /// it. `wanted` again when arena comes back to a session, whose output it was not sent.
    seed: enum { wanted, asked, done } = .wanted,
    /// The `App.colors_known` this pane's colours were last told to tmux at, 0 for never.
    colors_told: u32 = 0,
    /// What the pane's program had set when last asked, by `mode_sets`.
    modes: [mode_sets.len]bool = @splat(false),

    fn create(app: *App, id: u32, cols: u16, rows: u16) !*Pane {
        const pane = try app.gpa.create(Pane);
        errdefer app.gpa.destroy(pane);
        pane.* = .{
            .id = id,
            .term = try .init(app.io, app.gpa, .{ .cols = @max(1, cols), .rows = @max(1, rows), .max_scrollback_bytes = 8 << 20 }),
            .stream = undefined,
        };
        pane.stream = pane.term.vtStream();
        return pane;
    }

    fn destroy(pane: *Pane, gpa: Allocator) void {
        pane.pass.deinit(gpa);
        pane.render.deinit(gpa);
        pane.stream.deinit();
        pane.term.deinit(gpa);
        gpa.destroy(pane);
    }

    /// Feeds the pane's program's output to its terminal, as tmux would take it. Where a
    /// character has just filled the last column, tmux holds the cursor one past it, so a step
    /// back lands on the last column; this terminal, like xterm, steps to the one before.
    /// Programs under tmux draw by tmux's rule.
    fn feed(pane: *Pane, bytes: []const u8) void {
        var rest = bytes;
        while (std.mem.indexOfAny(u8, rest, "\x08\x1b")) |at| {
            pane.stream.nextSlice(rest[0..at]);
            rest = rest[at..];
            const cursor = &pane.term.screens.active.cursor;
            const back = backBy(rest);
            if (!cursor.pending_wrap or back.len == 0) {
                pane.stream.nextSlice(rest[0..1]);
                rest = rest[1..];
                continue;
            }
            cursor.pending_wrap = false;
            if (back.cells > 1) {
                var buf: [16]u8 = undefined;
                pane.stream.nextSlice(std.fmt.bufPrint(&buf, "\x1b[{d}D", .{back.cells - 1}) catch unreachable);
            }
            rest = rest[back.len..];
        }
        pane.stream.nextSlice(rest);
    }

    /// The step back `bytes` starts with, a backspace or `CSI n D`: its length, 0 when it is
    /// neither, and how many cells it goes.
    fn backBy(bytes: []const u8) struct { len: usize, cells: u16 } {
        if (bytes[0] == 0x08) return .{ .len = 1, .cells = 1 };
        if (!std.mem.startsWith(u8, bytes, "\x1b[")) return .{ .len = 0, .cells = 0 };
        var end: usize = 2;
        while (end < bytes.len and std.ascii.isDigit(bytes[end])) end += 1;
        if (end == bytes.len or bytes[end] != 'D') return .{ .len = 0, .cells = 0 };
        const cells = if (end == 2) 1 else std.fmt.parseInt(u16, bytes[2..end], 10) catch return .{ .len = 0, .cells = 0 };
        return .{ .len = end + 1, .cells = @max(1, cells) };
    }

    fn contains(pane: *const Pane, x: usize, y: usize) bool {
        return x >= pane.x and x < pane.x + pane.term.cols and y >= pane.y and y < pane.y + pane.term.rows;
    }
};

pub const Window = struct {
    id: u32,
    name: []u8 = &.{},
    panes: std.ArrayList(*Pane) = .empty,
    active: usize = 0,
    /// The size tmux has the window at, which is arena's column unless another client holds it.
    w: u16 = 0,
    h: u16 = 0,
    /// The size of a cell in pixels, as tmux tells the window's programs.
    cell_w: u16 = 16,
    cell_h: u16 = 32,
    /// The size arena last asked tmux for, so one tmux will not give is asked for once.
    asked_w: u16 = 0,
    asked_h: u16 = 0,
    /// The hundredths of the view its column is given, kept in tmux as @arena_width; 0 until
    /// it is made narrower or wider, when the column has the width every such one has.
    share: u8 = 0,
    /// The most pressing state of the Claudes in its panes, the one it had at the list before,
    /// null for a window new to arena, and the pane of the Claude it is marked by.
    claude: Mark = .none,
    /// A subagent of its did something in the last `stir_s`.
    stirring: bool = false,
    was: ?Mark = null,
    agent_pane: u32 = 0,
    review: Review = .none,
    alert: Alert = .none,
    listed: bool = false,
    /// About the Claude it is marked by, as its hook set it, 0 and empty where no hook has: when
    /// its state began and when it or a subagent of its last did anything, in seconds since the
    /// epoch, the tokens of its context and the share of its budget they are, as its status line
    /// set it, how long its last turn took, and its `Info` between tabs.
    since: u32 = 0,
    at: u32 = 0,
    tokens: u32 = 0,
    ctx: u32 = 0,
    took: u32 = 0,
    info: []u8 = &.{},

    pub const Info = enum { doing, prompt, title, said, branch, background, agents };

    pub fn text(win: *const Window, field: Info) []const u8 {
        var it = std.mem.splitScalar(u8, win.info, '\t');
        for (0..@backingInt(field)) |_| _ = it.next();
        return it.next() orelse "";
    }

    /// How many subagents its Claude has in the background.
    pub fn subs(win: *const Window) usize {
        const all = win.text(.agents);
        return if (all.len == 0) 0 else std.mem.countScalar(u8, all, '\x1f') + 1;
    }

    /// The description of the `index`th of them.
    pub fn sub(win: *const Window, index: usize) []const u8 {
        var it = std.mem.splitScalar(u8, win.text(.agents), '\x1f');
        for (0..index) |_| _ = it.next();
        return it.next() orelse "";
    }

    /// What a list of Claudes calls it: its conversation's title, or the window's name before
    /// it has one.
    pub fn label(win: *const Window) []const u8 {
        const title = win.text(.title);
        return if (title.len > 0) title else win.name;
    }

    /// What a list of Claudes says its session itself is doing, under it: the tool it is on or
    /// what it waits for, or the first line of its last answer; else what it was last asked.
    pub fn detail(win: *const Window) []const u8 {
        const now = switch (win.claude) {
            .working, .waiting => win.text(.doing),
            .background, .done, .stalled, .none => win.text(.said),
        };
        return if (now.len > 0) now else win.text(.prompt);
    }

    /// Whether a Claude runs in it, one done and looked at included.
    pub fn agent(win: *const Window) bool {
        return win.since != 0 or win.claude != .none;
    }

    fn know(win: *Window, gpa: Allocator, since: u32, tokens: u32, at: u32, took: u32, ctx: u32, info: []const u8) !void {
        gpa.free(win.info);
        win.info = &.{};
        win.since = since;
        win.tokens = tokens;
        win.at = at;
        win.took = took;
        win.ctx = ctx;
        win.info = try gpa.dupe(u8, info);
    }

    /// Whether it has been working with nothing heard from it, nor any subagent of its, for
    /// `quiet_s`: a tool hung, or a call that will not come back.
    pub fn quiet(win: *const Window, epoch: i64) bool {
        return win.claude == .working and win.at != 0 and epoch - win.at >= quiet_s;
    }

    pub fn activePane(win: *const Window) ?*Pane {
        return if (win.active < win.panes.items.len) win.panes.items[win.active] else null;
    }

    pub fn paneAt(win: *const Window, x: usize, y: usize) ?*Pane {
        for (win.panes.items) |pane| if (pane.contains(x, y)) return pane;
        return null;
    }

    fn destroy(win: *Window, gpa: Allocator) void {
        gpa.free(win.name);
        gpa.free(win.info);
        win.panes.deinit(gpa);
        gpa.destroy(win);
    }
};

pub const Session = struct {
    id: u32,
    name: []u8 = &.{},
    /// Its place on the rail, as arena last left it in tmux; none for a session not yet moved.
    order: u32 = std.math.maxInt(u32),
    wins: std.ArrayList(*Window) = .empty,
    focus: usize = 0,
    scroll: i32 = 0,
    /// False until its strip has been put in place once, and again after a resize.
    placed: bool = false,
    /// Columns take the whole view, with no neighbour peeking.
    full: bool = false,

    /// babylon's own session, where its pipeline runs gates: kept last, off the rail and the
    /// agents, and reached from the board.
    pub fn gate(s: *const Session) bool {
        return std.mem.eql(u8, s.name, "babylon");
    }

    /// The orchestrator's session (`babylon orchestrator` starts it): kept off the rail with the gate.
    pub fn orchestrator(s: *const Session) bool {
        return std.mem.eql(u8, s.name, "orchestrator");
    }

    pub fn offRail(s: *const Session) bool {
        return s.gate() or s.orchestrator();
    }

    pub fn focused(s: *const Session) ?*Window {
        return if (s.focus < s.wins.items.len) s.wins.items[s.focus] else null;
    }
};

const Pending = union(enum) {
    ignore,
    switched,
    sessions,
    panes,
    modes: u32,
    capture: u32,
    cursor: u32,
};

pub const BoardView = struct {
    /// Which has the keys and is lit: the board, or the orchestrator's column beside it.
    focus: enum { board, orchestrator } = .board,
    /// The session the human was in when arena went to the orchestrator's to have its window
    /// live beside the board: gone back to when the board closes or the side is folded.
    back: ?u32 = null,
    /// The column and the card in it picked, and in the every view the repo whose group it is
    /// in, by its place among `laneRepos`.
    col: usize = 0,
    row: usize = 0,
    lane: usize = 0,
    /// The repo it is narrowed to: 0 for every one, else its place in the board's repos from 1.
    repo: usize = 0,
    /// The backlog shown as the one column, in place of the four.
    backlog: bool = false,
    /// The picked card's question shown over the board, waiting on its answer's number.
    answering: bool = false,
    /// The Claudes the picked card can be given to shown over the board, and the one picked.
    giving: ?usize = null,
    /// The ticket whose whole detail is shown over the board, and how far down it is scrolled.
    detail: ?u32 = null,
    detail_scroll: usize = 0,
    /// The tab of the orchestrator's strip that is lit, and how far its list is scrolled.
    tab: feed.Section = .next,
    tab_scroll: usize = 0,
    /// The option of the modal's open ask that ⏎ answers, from 1.
    ask_pick: u8 = 1,
    /// The check of the modal's to-try ticket that `y` and `n` act on, from 1.
    check_pick: u8 = 1,
    /// The open modal is that ticket's gate run, not its detail; and `W` has asked whether to
    /// withdraw it.
    gate: bool = false,
    withdrawing: bool = false,
    /// Auto's settings shown over the board, and the row picked: auto, hold, then each repo.
    auto_pick: ?usize = null,
    /// The `+ goal` modal is over the plan; what it holds is `App.goal`.
    goal_open: bool = false,
    /// The keys were in the orchestrator's column when it opened, and go back there.
    auto_from_column: bool = false,
    auto_normal: bool = false,
    /// The board's keys shown over it, until the next key.
    help: bool = false,
    /// Opened as home: the orchestrator's column beside it while the orchestrator is not running.
    home: bool = false,
    /// The feed's pick, by its place: Your move's items, then next's and auto's line, then
    /// landing's tickets, then building's.
    pick: usize = 0,
    /// Home drawn as the plan, when babylon's file has one, in the board's place.
    plan: bool = false,
    /// The plan's pick among its rows that can be picked, and the stages unfolded, a bit each.
    plan_pick: usize = 0,
    unfolded: u8 = 0,
    /// At home with the room of half a screen: the orchestrator's column alone, else the plan
    /// or the board alone.
    alone: bool = true,

    /// Whether a box lies over the board, the keys its own.
    pub fn boxed(view: BoardView) bool {
        return view.help or view.detail != null or view.answering or view.giving != null or view.auto_pick != null or view.goal_open;
    }
};

/// The cards a column of the board can hold, and the repos it can be narrowed to.
pub const max_cards = 256;
const max_ask_options = 9;
/// The Claudes a card can be given to, each picked by its number.
pub const give_rows = 9;
const max_repos = 32;
/// The orchestrator's column's width beside the board, kept to 2/5 of what the rail leaves.
pub const side_w = 60;

fn anyKey(pressed: []const u8, names: []const []const u8) bool {
    for (names) |name| if (std.mem.eql(u8, pressed, name)) return true;
    return false;
}

pub const App = struct {
    gpa: Allocator,
    io: std.Io,
    tmux_in: std.Io.File,
    sessions: std.ArrayList(*Session) = .empty,
    current: ?u32 = null,
    /// The session being left while its strip slides out.
    prev: ?u32 = null,
    /// The way the next session change goes, when arena asked for it: 1 down, -1 up.
    slide: i32 = 0,
    /// Rows the current strip still has to travel to its place.
    yoff: i32 = 0,
    menu: ?menu.Menu = null,
    /// A name being typed, over everything else.
    prompt: ?menu.Prompt = null,
    goal: goal_modal.Modal = .{},
    /// What the board is narrowed to by `/`, kept after Enter.
    find: [200]u8 = undefined,
    find_len: usize = 0,
    /// The window picked in the overview, while it is open in place of the strip.
    overview: ?Spot = null,
    /// babylon's board, as its file was last read; null while there is none.
    board: ?tickets.Board = null,
    /// The board while it is open in place of the strip.
    board_view: ?BoardView = null,
    /// The orchestrator was asked to start: gone to as soon as its session shows, unless the human
    /// has gone somewhere else first.
    orchestrating: bool = false,
    /// The session arena last asked tmux to switch to, until tmux says it is there, and how many
    /// switches tmux has yet to answer.
    heading: ?u32 = null,
    switches: u32 = 0,
    /// The orchestrator's column was folded away: the board opens without it until it is unfolded.
    side_folded: bool = false,
    rail: enum { wide, narrow } = .wide,
    /// The narrow rail drawn wide over the strip, while the pointer is on it.
    peek: bool = false,
    /// The pointer is on the row under the strip, which then has the windows' names for dots.
    over_dots: bool = false,
    /// Normal mode: keys drive arena and none is typed into a pane. Only held while nothing lies
    /// over the strip, or the orchestrator's column beside the board is focused; otherwise the
    /// overlay is the mode.
    normal: bool = false,
    /// Where the rail's pick was moved to in normal mode; none puts it on what is in view.
    rail_pick: ?RailPick = null,
    /// The popup over the strip in normal mode, which holds the keys while it is open.
    popup: ?Popup = null,
    /// The digits typed after `#` in normal mode, a ticket's number to open, while one is being typed.
    hash: [8]u8 = undefined,
    hash_len: ?u8 = null,
    agent_sort: AgentSort = .urgency,
    /// The rail's list of Claudes was scrolled to start at the `n`th, beside the window `at` that
    /// was in view then; going to another puts it back to following the Claude in view.
    agent_skip: ?struct { n: usize, at: ?*const Window } = null,
    /// The repos whose pipeline folds are open, as hashes; 0 for a free place.
    pipeline_open: [8]u64 = @splat(0),
    /// When the pointer came to rest on the narrow rail; 0 while it is elsewhere.
    hover_at: i64 = 0,
    /// The peek open, what the pointer rests on and since when, what Esc put away, where the
    /// pointer was as it opened (none: it follows the pick), when it was last drawn and when a
    /// key was last typed.
    look: ?Look = null,
    look_rest: ?Look = null,
    look_at: i64 = 0,
    /// How long a rest takes to open a peek; the e2e lengthens it past what its captures take.
    look_after: i64 = look_ms,
    look_off: ?Look = null,
    look_here: ?struct { x: u16, y: u16 } = null,
    look_drawn: i64 = 0,
    key_at: i64 = 0,
    /// The last input was a key that moves the pick: only then does a peek follow the pick.
    key_typed: bool = false,
    /// Set when the session's current window changed in tmux, so focus goes to it when listed.
    follow_active: bool = false,
    palette: color.Palette = .{},
    theme: ?Theme = null,
    /// The ticket the plan and the feed light dim for each other, set by `settleLit` each frame.
    lit_ticket: ?u32 = null,
    /// Workbench's roles from the same palette; none draws the board's header in the terminal's own colours.
    roles: ?Roles = null,
    /// Off under ARENA_REDUCED_MOTION: the border stands still and strips jump.
    motion: bool = true,
    phase: f32 = 0,
    term_w: u16 = 80,
    /// The strip's width: the terminal's, less the session rail and its gap.
    view_w: u16 = 80,
    /// The strip's height: the terminal's, less the row of dots under it.
    view_h: u16 = 23,
    pending: std.ArrayList(Pending) = .empty,
    /// The open reply's guard, its time and number, which its end repeats.
    guard: std.ArrayList(u8) = .empty,
    in_block: bool = false,
    /// Whether the open reply answers a command arena sent: tmux also writes replies to
    /// commands it ran itself for the client, as the attach, which answer nothing pending.
    block_mine: bool = false,
    block: std.ArrayList(u8) = .empty,
    /// The text of the ticket the board shows the detail of, as babylon gave it.
    detail: std.ArrayList(u8) = .empty,
    /// Where babylon keeps its board file, and where a card's detail is written to be read.
    board_dir: ?[]const u8 = null,
    /// The tickets whose detail babylon was asked to write and arena has yet to take in.
    detail_asked: std.ArrayList(u32) = .empty,
    /// The subagent a click on its row asked its Claude to show.
    pick: ?Pick = null,
    want_list: bool = true,
    listing: bool = false,
    listed: bool = false,
    dirty: bool = true,
    quit: bool = false,
    /// The strip's normal-mode keys shown over it, until the next key.
    strip_help: bool = false,
    /// tmux ended the client, as it does when the session it was on ends.
    ended: bool = false,
    /// Milliseconds on a clock that only goes forward, set each turn of the loop.
    now: i64 = 0,
    /// Until when a click on the auto switch, which has asked "turn off?", is answered by a second.
    auto_armed_until: i64 = 0,
    /// What the human asked of auto in its modal that babylon's file does not yet say.
    auto_wants: autos.Wants = .{},
    /// Seconds since the epoch, set each turn of the loop.
    epoch: i64 = 0,
    /// Seconds the local clock is ahead of UTC, for where today began.
    utc_offset: i64 = 0,
    /// babylon's refusals of what the feed ran for its items, said in their place.
    refusals: std.ArrayList(feed.Refusal) = .empty,
    /// babylon's refusal of the board's start, drawn on the card's action row until the next key.
    start_refused: ?[]u8 = null,
    /// What babylon said of the last report filed, drawn on the bottom row until the next key.
    report_said: ?[]u8 = null,
    report_failed: bool = false,
    /// When `report_said` goes by itself, in `now`'s milliseconds; 0 for one that stays until a key.
    report_until: i64 = 0,
    /// What the held left button is moving: the line after a pane, to resize it, a window by
    /// its title, along the strip, or a session by its name, along the rail.
    drag: union(enum) {
        none,
        divider: struct { pane: u32, upright: bool, asked: i32 = -1 },
        title: u32,
        /// A window by its picture in the overview.
        thumb: u32,
        session: u32,
        /// Text being selected in a pane, from the cell of it the button went down on.
        select: struct { pane: u32, x: u16, y: u16 },
        /// A click that focused a window: its program gets none of it, not even the let go.
        focus,
        /// A board card by its ticket, to move to the column it is let go over.
        card: struct {
            id: u32,
            /// The press was on the picked card, which a let go without a move opens.
            opens: bool,
            moved: bool = false,
        },
        /// A row of the plan's next by its place (from 0), to move to the row it is let go on.
        next_row: struct {
            from: usize,
            /// The press was on the picked row, which a let go without a move goes to.
            opens: bool,
            moved: bool = false,
        },
    } = .none,
    /// The session the open menu asks about closing.
    doomed: u32 = 0,
    /// The pointer's shape, and whether the next frame is to tell the terminal of it.
    shape: []const u8 = "default",
    shape_due: bool = false,
    /// Where the mouse last was.
    pointer: struct { x: u16 = 0, y: u16 = 0 } = .{},
    /// The last input, for a report.
    trail: capture.Trail = .{},
    /// What a report in the making holds, taken when its key was pressed: the summary is the
    /// first `report_summary_len` bytes.
    report_text: []u8 = &.{},
    report_summary_len: usize = 0,
    /// Where reports are saved; none when there is no home to keep them in.
    reports_dir: ?[]const u8 = null,
    /// The repos folded to their headings on the board, in every column; the file they are kept in.
    folds: [max_repos][48]u8 = undefined,
    fold_lens: [max_repos]u8 = @splat(0),
    fold_n: usize = 0,
    folds_path: ?[]const u8 = null,
    /// Bytes for the terminal arena runs in, written inside the next frame.
    out: std.ArrayList(u8) = .empty,
    /// A piece of a pane's output without what it passes to the terminal, between `Pass` and the pane.
    plain: std.ArrayList(u8) = .empty,
    /// The pane that last sent a graphics command, which the terminal's replies go back to: the
    /// terminal does not say which pane asked.
    asker: u32 = std.math.maxInt(u32),
    /// Counts the terminal's answers for its foreground and background; 0 until the first.
    colors_known: u32 = 0,
    /// The name last clicked, a window's or a session's, and when.
    clicked: ?Name = null,
    clicked_at: i64 = 0,
    nav_at: i64 = 0,
    /// When the wheel last went up or down.
    vertical_at: i64 = 0,
    /// The swipe going sideways now: when its last event came, how far it has gone, signed, and
    /// whether it has stepped.
    sideways_at: i64 = 0,
    sideways_run: i32 = 0,
    swiped: bool = false,

    pub fn deinit(app: *App) void {
        for (app.sessions.items) |s| app.destroySession(s);
        app.sessions.deinit(app.gpa);
        app.pending.deinit(app.gpa);
        app.block.deinit(app.gpa);
        app.detail.deinit(app.gpa);
        app.detail_asked.deinit(app.gpa);
        app.guard.deinit(app.gpa);
        app.out.deinit(app.gpa);
        app.plain.deinit(app.gpa);
        for (app.refusals.items) |r| {
            app.gpa.free(r.id);
            app.gpa.free(r.text);
        }
        app.refusals.deinit(app.gpa);
        app.auto_wants.deinit(app.gpa);
        if (app.start_refused) |text| app.gpa.free(text);
        if (app.report_said) |text| app.gpa.free(text);
        if (app.report_text.len > 0) app.gpa.free(app.report_text);
        if (app.board) |*b| b.deinit();
    }

    fn destroySession(app: *App, s: *Session) void {
        for (s.wins.items) |win| {
            for (win.panes.items) |pane| pane.destroy(app.gpa);
            win.destroy(app.gpa);
        }
        s.wins.deinit(app.gpa);
        app.gpa.free(s.name);
        app.gpa.destroy(s);
    }

    pub fn send(app: *App, kind: Pending, comptime fmt: []const u8, args: anytype) !void {
        var buf: [256]u8 = undefined;
        var w = app.tmux_in.writerStreaming(app.io, &buf);
        try w.interface.print(fmt ++ "\n", args);
        try w.interface.flush();
        try app.pending.append(app.gpa, kind);
    }

    pub fn sessionById(app: *const App, id: ?u32) ?*Session {
        for (app.sessions.items) |s| if (s.id == id) return s;
        return null;
    }

    pub fn cur(app: *const App) ?*Session {
        return app.sessionById(app.current);
    }

    fn sessionIndex(app: *const App, id: ?u32) ?usize {
        for (app.sessions.items, 0..) |s, i| if (s.id == id) return i;
        return null;
    }

    pub fn paneById(app: *const App, id: u32) ?*Pane {
        for (app.sessions.items) |s| for (s.wins.items) |win| for (win.panes.items) |pane| {
            if (pane.id == id) return pane;
        };
        return null;
    }

    pub fn colW(app: *const App, s: *const Session, win: *const Window) u16 {
        if (s.full) return app.view_w;
        if (win.share == 0) return layout.colWidth(app.view_w, s.wins.items.len);
        return layout.shareWidth(app.view_w, win.share);
    }

    /// The left edge of column `index` on the strip; of one past the last, where another would go.
    pub fn colX(app: *const App, s: *const Session, index: usize) i32 {
        var x: i32 = 0;
        for (s.wins.items[0..index]) |win| x += @as(i32, app.colW(s, win)) + layout.gap;
        return x;
    }

    pub const ColHit = struct { index: usize, cx: usize };

    /// The column at cell `at` of the strip, and which cell of it; none between two or past the end.
    pub fn colAt(app: *const App, s: *const Session, at: i32) ?ColHit {
        var x: i32 = 0;
        for (s.wins.items, 0..) |win, index| {
            const w = app.colW(s, win);
            if (at >= x and at < x + w) return .{ .index = index, .cx = @intCast(at - x) };
            x += @as(i32, w) + layout.gap;
        }
        return null;
    }

    pub fn target(app: *const App, s: *const Session) i32 {
        const win = s.focused() orelse return 0;
        const strip = app.colX(s, s.wins.items.len) - layout.gap;
        return layout.scrollTarget(app.view_w, app.colX(s, s.focus), app.colW(s, win), strip);
    }

    /// Gives a window's column `share` hundredths of the view, within what is worth having,
    /// and has tmux keep it.
    fn setShare(app: *App, s: *Session, win: *Window, share: i32) !void {
        const to: u8 = @intCast(std.math.clamp(share, min_share, max_share));
        if (to == win.share and !s.full) return;
        s.full = false;
        win.share = to;
        try app.send(.ignore, "set-option -w -t @{d} @arena_width {d}", .{ win.id, to });
        app.want_list = true;
        app.dirty = true;
    }

    /// The hundredths of the view a column `w` cells wide takes, to the nearest.
    fn shareOf(app: *const App, w: i32) i32 {
        return @divTrunc(w * 100 + app.view_w / 2, @max(1, app.view_w));
    }

    /// Makes the focused window's column narrower or wider by `delta` hundredths of the view.
    fn widenBy(app: *App, delta: i32) !void {
        const s = app.cur() orelse return;
        const win = s.focused() orelse return;
        const from = if (win.share != 0 and !s.full) win.share else app.shareOf(app.colW(s, win));
        try app.setShare(s, win, from + delta);
    }

    /// What `win` of `s` has to say; nothing when it is the window in view.
    pub fn mark(app: *const App, s: *const Session, win: *const Window) Mark {
        if (s.id == app.current and s.focused() == win) return .none;
        return win.claude;
    }

    /// The most pressing mark among a session's windows, the one in view included.
    pub fn sessionMark(s: *const Session) Mark {
        var most: Mark = .none;
        for (s.wins.items) |win| {
            if (@backingInt(win.claude) > @backingInt(most)) most = win.claude;
        }
        return most;
    }

    /// How many of a session's windows have its most pressing mark.
    pub fn sessionCount(s: *const Session) usize {
        const most = sessionMark(s);
        var count: usize = 0;
        for (s.wins.items) |win| count += @intFromBool(win.claude == most);
        return count;
    }

    /// The most pressing alert among a session's windows.
    pub fn sessionAlert(s: *const Session) Alert {
        var most: Alert = .none;
        for (s.wins.items) |win| {
            if (@backingInt(win.alert) > @backingInt(most)) most = win.alert;
        }
        return most;
    }

    /// The most pressing review state among a session's windows.
    pub fn sessionReview(s: *const Session) Review {
        var most: Review = .none;
        for (s.wins.items) |win| {
            if (@backingInt(win.review) > @backingInt(most)) most = win.review;
        }
        return most;
    }

    pub const Agent = struct { session: usize, win: *Window };
    /// How lists of agents are ordered: the one that most wants looking at first, the one heard
    /// from last, or by repo and ticket number, which no change of state moves.
    pub const AgentSort = enum { urgency, recent, ticket };

    /// The windows with a Claude, as many as `out` holds, grouped by session, as `agent_sort`
    /// has them: the session with the first of its Claudes first, then in the rail's order.
    pub fn agents(app: *const App, out: []Agent) usize {
        var n: usize = 0;
        for (app.sessions.items, 0..) |s, si| for (s.wins.items) |win| {
            if (s.offRail()) break;
            if (!win.agent() or n == out.len) continue;
            out[n] = .{ .session = si, .win = win };
            n += 1;
        };
        std.sort.insertion(Agent, out[0..n], app, agentBefore);
        return n;
    }

    fn agentBefore(app: *const App, a: Agent, b: Agent) bool {
        if (app.agent_sort == .ticket) return app.ticketBefore(a, b);
        if (a.session != b.session) {
            const ra = app.sessionRank(a.session);
            const rb = app.sessionRank(b.session);
            return ra > rb or (ra == rb and a.session < b.session);
        }
        return app.agentRank(a.win) > app.agentRank(b.win);
    }

    /// Where a Claude goes in a list, as `agent_sort` has it: the higher, the sooner.
    fn agentRank(app: *const App, win: *const Window) u64 {
        // a Claude never heard from counts as the newest
        const last = @max(win.at, win.since);
        return switch (app.agent_sort) {
            .urgency => urgency(win),
            .recent => if (last == 0) std.math.maxInt(u32) else last,
            .ticket => 0,
        };
    }

    /// The ticket a window's Claude works, by its branch, and its repo as the board has it.
    const TicketKey = struct { repo: []const u8, id: u32 };

    fn ticketKey(app: *const App, win: *const Window) ?TicketKey {
        const id = std.fmt.parseInt(u32, branchTicket(win.text(.branch)) orelse return null, 10) catch return null;
        const card = app.ticketCard(id) orelse return null;
        return .{ .repo = card.repo orelse "", .id = id };
    }

    pub fn ticketCard(app: *const App, id: u32) ?*const tickets.Card {
        const board = if (app.board) |*b| b else return null;
        for (board.cards()) |*card| if (card.id == id) return card;
        return null;
    }

    fn keyBefore(a: TicketKey, b: TicketKey) bool {
        return switch (std.mem.order(u8, a.repo, b.repo)) {
            .lt => true,
            .gt => false,
            .eq => a.id < b.id,
        };
    }

    /// The repo of a session's lowest ticket, empty for a session holding none.
    pub fn sessionRepo(app: *const App, si: usize) []const u8 {
        return if (app.sessionTicket(si)) |key| key.repo else "";
    }

    /// The lowest ticket among a session's Claudes, null for a session holding none.
    fn sessionTicket(app: *const App, si: usize) ?TicketKey {
        var best: ?TicketKey = null;
        for (app.sessions.items[si].wins.items) |win| if (win.agent()) {
            const key = app.ticketKey(win) orelse continue;
            if (best == null or keyBefore(key, best.?)) best = key;
        };
        return best;
    }

    /// The stable order: by repo, then ticket number, sessions with no ticket last by name. It
    /// reads only what a session's life does not change.
    fn ticketBefore(app: *const App, a: Agent, b: Agent) bool {
        if (a.session != b.session) {
            const ka = app.sessionTicket(a.session);
            const kb = app.sessionTicket(b.session);
            if (ka != null and kb != null) {
                if (keyBefore(ka.?, kb.?)) return true;
                if (keyBefore(kb.?, ka.?)) return false;
            } else if (ka != null or kb != null) return ka != null;
            const order = std.mem.order(u8, app.sessions.items[a.session].name, app.sessions.items[b.session].name);
            return order == .lt or (order == .eq and a.session < b.session);
        }
        const ka = app.ticketKey(a.win);
        const kb = app.ticketKey(b.win);
        if (ka != null and kb != null) return keyBefore(ka.?, kb.?);
        if (ka != null or kb != null) return ka != null;
        return a.win.id < b.win.id;
    }

    /// The more pressing its state, the higher; of those alike, the longer in it.
    fn urgency(win: *const Window) u64 {
        const since: u64 = if (win.since == 0) std.math.maxInt(u32) else win.since;
        return @as(u64, @backingInt(win.claude)) << 32 | (std.math.maxInt(u32) - since);
    }

    fn sessionRank(app: *const App, si: usize) u64 {
        var best: u64 = 0;
        for (app.sessions.items[si].wins.items) |win| if (win.agent()) {
            best = @max(best, app.agentRank(win));
        };
        return best;
    }

    /// A subagent of a window's Claude, by its place among those in the background.
    pub const Sub = struct { agent: Agent, index: usize };

    /// A repo's Claudes whose tickets are only waiting in babylon's pipeline, folded into one row
    /// until it is opened.
    pub const Fold = struct { repo: []const u8, count: usize, open: bool, session: ?usize = null };
    pub const max_folds = 8;

    /// A row of a list of agents: a session's name over its own, a window with a Claude, its
    /// `Window.detail`, its branch, review and context, a subagent of its, what else it has
    /// running in the background, how many Claudes are scrolled off above, a fold of the
    /// pipeline's, or how many more there are than rows.
    pub const AgentLine = union(enum) { session: usize, agent: Agent, detail: Agent, meta: Agent, sub: Sub, background: Agent, above: usize, pipeline: Fold, more: usize };

    /// The pane of the Claude asked for a subagent and the subagent's description, when arena
    /// stops trying, when it last sent a key, and how many Downs it has sent to reach the list.
    const Pick = struct { pane: u32, name: [320]u8 = undefined, len: usize, until: i64, sent_at: i64 = 0, downs: u8 = 0 };

    /// Whether a ticket's Claude has nothing to do until babylon is done with it.
    fn inPipeline(card: *const tickets.Card) bool {
        if (card.status != .review) return false;
        const stage = card.stage orelse return false;
        for ([_][]const u8{ "queued", "verifying", "reviewing" }) |waiting| {
            if (std.mem.eql(u8, stage, waiting)) return true;
        }
        return false;
    }

    pub fn repoHash(repo: []const u8) u64 {
        return std.hash.Wyhash.hash(0, repo) | 1;
    }

    /// What a fold is picked and kept open by: its repo's hash, or for a session's, its id's.
    pub fn foldKey(app: *const App, fold: Fold) u64 {
        const si = fold.session orelse return repoHash(fold.repo);
        return std.hash.Wyhash.hash(1, std.mem.asBytes(&app.sessions.items[si].id)) | 1;
    }

    fn foldOpen(app: *const App, key: u64) bool {
        return std.mem.indexOfScalar(u64, &app.pipeline_open, key) != null;
    }

    /// Whether the rail folds each session's Claudes that are not moving: narrow, at home.
    fn restFolded(app: *const App) bool {
        const view = app.board_view orelse return false;
        return view.home and app.rail == .narrow;
    }

    fn toggleFold(app: *App, hash: u64) void {
        if (std.mem.indexOfScalar(u64, &app.pipeline_open, hash)) |at| {
            app.pipeline_open[at] = 0;
        } else if (std.mem.indexOfScalar(u64, &app.pipeline_open, 0)) |free| {
            app.pipeline_open[free] = hash;
        }
        app.dirty = true;
    }

    /// The rail's Claudes: those whose tickets have landed or closed are left out, and those only
    /// waiting in the pipeline are folded a row to a repo, in order of name, unless the repo is
    /// open. The Claude in view stays, whatever its ticket, and so does one whose repo finds no
    /// fold left. Returns how many Claudes and folds.
    fn railList(app: *const App, out: []Agent, folds: []Fold) struct { usize, usize } {
        var all: [64]Agent = undefined;
        const total = app.agents(&all);
        const rest = app.restFolded();
        var n: usize = 0;
        var nf: usize = 0;
        for (all[0..total]) |a| {
            const card = if (app.agentSelected(a)) null else if (std.fmt.parseInt(u32, branchTicket(a.win.text(.branch)) orelse "", 10)) |id| app.ticketCard(id) else |_| null;
            if (card) |c| if (c.status == .done) continue;
            if (rest) {
                if (a.win.claude != .working and a.win.claude != .waiting) {
                    const at = for (folds[0..nf], 0..) |f, i| {
                        if (f.session == a.session) break i;
                    } else if (nf < folds.len) blk: {
                        const fold: Fold = .{ .repo = "", .count = 0, .open = false, .session = a.session };
                        folds[nf] = .{ .repo = "", .count = 0, .open = app.foldOpen(app.foldKey(fold)), .session = a.session };
                        nf += 1;
                        break :blk nf - 1;
                    } else null;
                    if (at) |i| {
                        folds[i].count += 1;
                        if (!folds[i].open) continue;
                    }
                }
            } else if (card) |c| if (inPipeline(c)) {
                const repo = c.repo orelse "";
                const at = for (folds[0..nf], 0..) |f, i| {
                    if (std.mem.eql(u8, f.repo, repo)) break i;
                } else if (nf < folds.len) blk: {
                    const fold: Fold = .{ .repo = repo, .count = 0, .open = false };
                    folds[nf] = .{ .repo = repo, .count = 0, .open = app.foldOpen(app.foldKey(fold)) };
                    nf += 1;
                    break :blk nf - 1;
                } else null;
                if (at) |i| {
                    folds[i].count += 1;
                    if (!folds[i].open) continue;
                }
            };
            out[n] = a;
            n += 1;
        }
        std.mem.sort(Fold, folds[0..nf], {}, struct {
            fn before(_: void, a: Fold, b: Fold) bool {
                if (a.session != null and b.session != null) return a.session.? < b.session.?;
                return std.mem.order(u8, a.repo, b.repo) == .lt;
            }
        }.before);
        return .{ n, nf };
    }

    /// The agents in at most `room` rows of `out`, as `agents` orders them, with each one's
    /// detail, its branch, review and context, and its background under it when `details`, where
    /// it has them.
    pub fn agentLines(app: *const App, out: []AgentLine, room: usize, details: bool) usize {
        var found: [64]Agent = undefined;
        var folds: [max_folds]Fold = undefined;
        const count, const nf = app.railList(&found, &folds);
        const from = app.listFrom(found[0..count], folds[0..nf], room, details);
        return linesFrom(out, room, details, found[0..count], folds[0..nf], from);
    }

    /// The first Claude listed: where the human scrolled to while the Claude they scrolled
    /// beside is still in view, else the first from which the selected one shows.
    fn listFrom(app: *const App, found: []const Agent, folds: []const Fold, room: usize, details: bool) usize {
        if (app.agent_skip) |skip| {
            if (skip.at == if (app.cur()) |s| s.focused() else null) return @min(skip.n, found.len -| 1);
        }
        const selected = for (found) |a| {
            if (app.agentSelected(a)) break true;
        } else false;
        var scratch: [64]AgentLine = undefined;
        var from: usize = 0;
        while (true) : (from += 1) {
            const n = linesFrom(&scratch, room, details, found, folds, from);
            if (!selected or from + 1 >= found.len) return from;
            for (scratch[0..n]) |line| {
                if (line == .agent and app.agentSelected(line.agent)) return from;
            }
        }
    }

    fn linesFrom(out: []AgentLine, room: usize, details: bool, found: []const Agent, folds: []const Fold, from: usize) usize {
        if (from == 0 or room == 0 or out.len == 0) return agentLinesFrom(out, room, details, found, folds);
        out[0] = .{ .above = from };
        return 1 + agentLinesFrom(out[1..], room - 1, details, found[from..], folds);
    }

    /// Whether `a` is the Claude in view: its window is its session's focus, and that session
    /// is the current one, with no board over it.
    pub fn agentSelected(app: *const App, a: Agent) bool {
        const s = app.sessions.items[a.session];
        return s.id == app.current and app.board_view == null and s.focused() == a.win;
    }

    /// The line of `session`'s fold of what is not moving, when it has one not yet listed and a row for it.
    fn restLine(out: []AgentLine, n: *usize, rows: usize, folds: []const Fold, session: usize, emitted: *u16) void {
        for (folds, 0..) |fold, i| {
            if (fold.session != session or n.* == rows or emitted.* >> @intCast(i) & 1 == 1) continue;
            out[n.*] = .{ .pipeline = fold };
            n.* += 1;
            emitted.* |= @as(u16, 1) << @intCast(i);
        }
    }

    fn agentLinesFrom(out: []AgentLine, room: usize, details: bool, found: []const Agent, folds: []const Fold) usize {
        const count = found.len;
        const rows = @min(out.len, room);
        if (rows == 0) return 0;
        var n: usize = 0;
        var last: ?usize = null;
        var emitted: u16 = 0;
        for (found[0..count]) |a| {
            if (n == rows) break;
            if (last) |l| if (l != a.session) restLine(out, &n, rows, folds, l, &emitted);
            if (n == rows) break;
            // a Claude's rows go together: past the first, one they do not all fit is left to the count
            const rest = @as(usize, @intFromBool(details and a.win.detail().len > 0)) +
                @intFromBool(details and (a.win.text(.branch).len > 0 or a.win.review != .none or a.win.tokens > 0)) +
                (if (details) a.win.subs() else 0) +
                @intFromBool(details and a.win.text(.background).len > 0);
            if (n > 0 and n + @intFromBool(last != a.session) + 1 + rest > rows) break;
            if (last != a.session) {
                out[n] = .{ .session = a.session };
                n += 1;
                last = a.session;
            }
            if (n == rows) break;
            out[n] = .{ .agent = a };
            n += 1;
            if (details and n < rows and a.win.detail().len > 0) {
                out[n] = .{ .detail = a };
                n += 1;
            }
            if (details and n < rows and (a.win.text(.branch).len > 0 or a.win.review != .none or a.win.tokens > 0)) {
                out[n] = .{ .meta = a };
                n += 1;
            }
            if (details) for (0..a.win.subs()) |i| {
                if (n == rows) break;
                out[n] = .{ .sub = .{ .agent = a, .index = i } };
                n += 1;
            };
            if (details and n < rows and a.win.text(.background).len > 0) {
                out[n] = .{ .background = a };
                n += 1;
            }
        }
        if (last) |l| restLine(out, &n, rows, folds, l, &emitted);
        var shown: usize = 0;
        for (out[0..n]) |line| shown += @intFromBool(line == .agent or line == .pipeline);
        // a session's fold comes after its Claudes, one with none moving under its own header; the
        // pipeline's folds after all of them, once all have been listed
        if (shown - @popCount(emitted) == count) {
            for (folds, 0..) |fold, i| if (fold.session) |si| {
                if (emitted >> @intCast(i) & 1 == 1) continue;
                if (n + 2 > rows) break;
                out[n] = .{ .session = si };
                out[n + 1] = .{ .pipeline = fold };
                n += 2;
                shown += 1;
            };
            for (folds) |fold| if (fold.session == null) {
                if (n == rows) break;
                out[n] = .{ .pipeline = fold };
                n += 1;
                shown += 1;
            };
        }
        if (shown < count + folds.len) {
            if (n == rows) {
                if (out[n - 1] == .agent or out[n - 1] == .pipeline) shown -= 1;
                n -= 1;
            }
            out[n] = .{ .more = count + folds.len - shown };
            n += 1;
        }
        return n;
    }

    /// Scrolls the rail's list of Claudes by `by`, up while the wheel turns up, as far as there
    /// is more to show. Going to another Claude puts the list back to following it.
    fn scrollAgents(app: *App, by: i32) void {
        var found: [64]Agent = undefined;
        var folds: [max_folds]Fold = undefined;
        const count, const nf = app.railList(&found, &folds);
        const rows = app.railAgentRows();
        const details = app.railDrawnW() == app.railWideW();
        const from = app.listFrom(found[0..count], folds[0..nf], rows, details);
        const to: usize = @intCast(std.math.clamp(@as(i64, @intCast(from)) + by, 0, @as(i64, @intCast(count -| 1))));
        app.agent_skip = .{ .n = to, .at = if (app.cur()) |s| s.focused() else null };
        app.dirty = true;
    }

    /// Whether the rail's list has Claudes scrolled off above it, and whether below.
    fn agentsOverflow(app: *const App) struct { above: bool, below: bool } {
        var lines: [64]AgentLine = undefined;
        const n = app.railAgents(&lines);
        return .{ .above = n > 0 and lines[0] == .above, .below = n > 0 and lines[n - 1] == .more };
    }

    /// The rail's agents, as many as have rows, with their details while the rail is drawn wide.
    pub fn railAgents(app: *const App, out: []AgentLine) usize {
        return app.agentLines(out, app.railAgentRows(), app.railDrawnW() == app.railWideW());
    }

    /// Whether row `y` of the rail is one of its agents' rows.
    fn inRailAgents(app: *const App, y: u16) bool {
        const top = app.railAgentsRow() + 1;
        return y >= top and y - top < app.railAgentRows();
    }

    /// The row of the rail's agents at row `y`, null for any other row.
    fn railAgentAt(app: *const App, y: u16) ?AgentLine {
        var lines: [64]AgentLine = undefined;
        const n = app.railAgents(&lines);
        const top = app.railAgentsRow() + 1;
        return if (y >= top and y - top < n) lines[y - top] else null;
    }

    /// A click on the row `line` of the rail's agents that goes nowhere but along the list.
    fn clickList(app: *App, line: AgentLine) void {
        var lines: [64]AgentLine = undefined;
        const n = app.railAgents(&lines);
        var shown: i32 = 0;
        for (lines[0..n]) |l| shown += @intFromBool(l == .agent);
        const page: i32 = @max(1, shown);
        switch (line) {
            .above => app.scrollAgents(-page),
            .more => app.scrollAgents(page),
            .pipeline => |fold| app.toggleFold(app.foldKey(fold)),
            else => {},
        }
    }

    fn goAgent(app: *App, a: Agent) !void {
        app.dirty = true;
        const s = app.sessions.items[a.session];
        const index = std.mem.indexOfScalar(*Window, s.wins.items, a.win) orelse return;
        try app.jumpTo(s, index);
    }

    /// Goes to a subagent's Claude and asks it to show the subagent.
    fn goSub(app: *App, sub: Sub) !void {
        try app.goAgent(sub.agent);
        const name = sub.agent.win.sub(sub.index);
        var pick: Pick = .{ .pane = sub.agent.win.agent_pane, .len = @min(name.len, 320), .until = app.now + pick_ms };
        @memcpy(pick.name[0..pick.len], name[0..pick.len]);
        app.pick = pick;
    }

    /// Whether `pane` is in the session in view with its screen taken in: tmux sends arena the
    /// output of no other session's panes.
    fn watched(app: *const App, pane: *const Pane) bool {
        const s = app.cur() orelse return false;
        for (s.wins.items) |win| if (std.mem.indexOfScalar(*Pane, win.panes.items, @constCast(pane)) != null) return pane.seed == .done;
        return false;
    }

    /// Whether a subagent's Claude shows it now, as far as arena has its screen.
    pub fn subShown(app: *const App, sub: Sub) bool {
        const pane = @constCast(app).paneById(sub.agent.win.agent_pane) orelse return false;
        if (!app.watched(pane)) return false;
        const at = listedSub(pane, sub.agent.win.sub(sub.index)) orelse return false;
        return at.shown;
    }

    /// Steps the Claude asked for a subagent toward showing it, by what its screen has: a Down
    /// while its list of agents has no pointer, which the row of shells over the list may take
    /// first, then from the pointer to the subagent's row, and Enter. Returns how long until the
    /// next step.
    pub fn pickStep(app: *App) !i64 {
        const never = std.math.maxInt(i64);
        const pick = if (app.pick) |*p| p else return never;
        const pane = app.paneById(pick.pane);
        if (pane == null or app.now >= pick.until) {
            app.pick = null;
            return never;
        }
        const wait = pick.sent_at + pick_key_ms - app.now;
        if (wait > 0) return wait;
        if (!app.watched(pane.?)) return pick_key_ms;
        const at = listedSub(pane.?, pick.name[0..pick.len]) orelse return pick_key_ms;
        if (at.below) |rows| if (!at.shown) {
            var keys_buf: [3 * 32 + 1]u8 = undefined;
            var typed: Writer = .fixed(&keys_buf);
            for (0..@min(@abs(rows), 32)) |_| try typed.writeAll(if (rows > 0) "\x1b[B" else "\x1b[A");
            try typed.writeAll("\r");
            try app.sendKeys(pane.?, typed.buffered());
        };
        if (at.shown or at.below != null or pick.downs == pick_downs) {
            app.pick = null;
            return never;
        }
        try app.sendKeys(pane.?, "\x1b[B");
        pick.downs += 1;
        pick.sent_at = app.now;
        return pick_key_ms;
    }

    /// Steps `by` through the Claudes waiting or done, the one that most wants looking at first:
    /// from the one in view to the next or the one before, round; from any other window, to the
    /// first or the last.
    fn stepAgent(app: *App, by: i32) !void {
        var found: [64]Agent = undefined;
        const n = app.needy(&found);
        if (n == 0) return;
        const s = app.cur();
        const here = for (found[0..n], 0..) |a, i| {
            if (s != null and app.sessions.items[a.session] == s.? and s.?.focused() == a.win) break i;
        } else null;
        const len: i32 = @intCast(n);
        const to: i32 = if (here) |i| @mod(@as(i32, @intCast(i)) + by, len) else if (by > 0) 0 else len - 1;
        try app.goAgent(found[@intCast(to)]);
    }

    /// The Claudes waiting or done, as many as `out` holds, the one that most wants looking at first.
    fn needy(app: *const App, out: []Agent) usize {
        var n: usize = 0;
        for (app.sessions.items, 0..) |s, si| for (s.wins.items) |win| {
            if ((win.claude != .waiting and win.claude != .done and win.claude != .stalled) or n == out.len) continue;
            out[n] = .{ .session = si, .win = win };
            n += 1;
        };
        std.sort.insertion(Agent, out[0..n], {}, struct {
            fn before(_: void, a: Agent, b: Agent) bool {
                return urgency(a.win) > urgency(b.win);
            }
        }.before);
        return n;
    }

    /// What the rail's pick is on, by id: a session in its list, a Claude's window in its own, or
    /// a fold by its key (`foldKey`): its repo's hash, or its session's id's.
    pub const RailPick = union(enum) { session: u32, agent: u32, fold: u64 };

    /// The rail as one list, as it is drawn: each session, then its Claudes, then the pipeline's folds.
    fn railPicks(app: *const App, out: []RailPick) usize {
        var n: usize = 0;
        for (app.sessions.items[0..app.railShown()]) |s| {
            if (n == out.len) return n;
            out[n] = .{ .session = s.id };
            n += 1;
        }
        var found: [64]Agent = undefined;
        var folds: [max_folds]Fold = undefined;
        const count, const nf = app.railList(&found, &folds);
        for (found[0..count]) |a| {
            if (n == out.len) break;
            out[n] = .{ .agent = a.win.id };
            n += 1;
        }
        for (folds[0..nf]) |fold| {
            if (n == out.len) break;
            out[n] = .{ .fold = app.foldKey(fold) };
            n += 1;
        }
        return n;
    }

    /// The rail's pick in normal mode over the strip: where the human put it, else on what is in
    /// view, the Claude in the list or its session. Null otherwise.
    pub fn railPicked(app: *const App) ?RailPick {
        if (!app.normal or app.board_view != null) return null;
        if (app.rail_pick) |pick| return pick;
        const s = app.cur() orelse return null;
        if (s.focused()) |win| if (win.agent()) return .{ .agent = win.id };
        return .{ .session = s.id };
    }

    /// The popup over the strip: what it shows, the pick the rail had when it opened, and the
    /// viewport of the pane it shows, which it scrolls and puts back.
    pub const Popup = struct {
        entry: RailPick,
        from: ?RailPick,
        /// How many rows of the pane's viewport are cut off its top: those under its last line of
        /// text are not shown, and this stays while it is scrolled.
        anchor: usize = 0,
        saved: ?struct { pane: u32, offset: usize, bottom: bool } = null,
        /// What the foot has: the keys, the open question's options, or a reply being typed.
        mode: enum { view, answer, reply } = .view,
        reply: [240]u8 = undefined,
        reply_len: usize = 0,
    };

    /// The question a Claude waits on: babylon's, answered through it, or Claude Code's own on the
    /// pane's screen, answered by typing the option's number into the pane.
    pub const Asked = struct {
        babylon: ?u32 = null,
        question: []const u8 = "",
        options: [9][]const u8 = undefined,
        n: usize = 0,
        text: [6144]u8 = undefined,
    };

    fn entryWindow(app: *const App, entry: RailPick) ?*Window {
        return switch (entry) {
            .agent => |id| (app.agentById(id) orelse return null).win,
            .session => |id| (app.sessionById(id) orelse return null).focused(),
            .fold => null,
        };
    }

    /// The question the popup's Claude waits on, if it waits on one.
    pub fn popupAsk(app: *const App, pane: *const Pane, out: *Asked) bool {
        const win = app.entryWindow((app.popup orelse return false).entry) orelse return false;
        if (std.fmt.parseInt(u32, branchTicket(win.text(.branch)) orelse "", 10)) |id| {
            if (app.ticketCard(id)) |card| if (card.ask) |ask| {
                out.babylon = ask.id;
                out.question = ask.question;
                out.n = @min(ask.options.len, out.options.len);
                for (ask.options[0..out.n], 0..) |option, i| out.options[i] = option;
                return out.n > 0;
            };
        } else |_| {}
        return win.claude == .waiting and screenAsk(pane, out);
    }

    /// Answers babylon's ask `id` with option `choice`; its refusal is said.
    fn answerAsk(app: *App, id: u32, choice: u8) !void {
        try app.send(.ignore, "run-shell -b \"out=\\$(babylon answer {d} {d} 2>&1) || " ++
            "{{ command -v notify-send >/dev/null && notify-send -a arena -- \\\"\\$out\\\"; }}\"", .{ id, choice });
    }

    /// A key while the popup's foot has the question's options: a digit answers, `r` replies
    /// instead and Esc goes back.
    fn answerPopupKey(app: *App, pane: *Pane, key: []const u8) !void {
        const pop = &app.popup.?;
        if (anyKey(key, &.{"\x1b"})) {
            pop.mode = .view;
        } else if (anyKey(key, &.{"r"})) {
            pop.mode = .reply;
            pop.reply_len = 0;
        } else if (key.len == 1 and key[0] >= '1' and key[0] <= '9') {
            var asked: Asked = .{};
            if (!app.popupAsk(pane, &asked) or key[0] - '0' > asked.n) return;
            if (asked.babylon) |id| try app.answerAsk(id, key[0] - '0') else try app.sendKeys(pane, key);
            pop.mode = .view;
        }
    }

    /// A key while the popup's foot has a reply being typed: Enter types it into the pane with an
    /// Enter, Esc goes back.
    fn replyPopupKey(app: *App, pane: *Pane, key: []const u8) !void {
        const pop = &app.popup.?;
        if (anyKey(key, &.{"\x1b"})) {
            pop.mode = .view;
        } else if (anyKey(key, &.{"\r"})) {
            if (pop.reply_len > 0) try app.sendKeys(pane, pop.reply[0..pop.reply_len]);
            try app.sendKeys(pane, "\r");
            pop.mode = .view;
        } else if (anyKey(key, &.{ "\x7f", "\x08" })) {
            while (pop.reply_len > 0) {
                pop.reply_len -= 1;
                if (pop.reply[pop.reply_len] & 0xc0 != 0x80) break;
            }
        } else if (key.len == 1 and key[0] >= ' ' and pop.reply_len < pop.reply.len) {
            pop.reply[pop.reply_len] = key[0];
            pop.reply_len += 1;
        }
    }

    /// The pane an entry of the rail stands for: a Claude's, or a session's focused window's active one.
    fn entryPane(app: *App, entry: RailPick) ?*Pane {
        switch (entry) {
            .agent => |id| {
                const a = app.agentById(id) orelse return null;
                return app.paneById(a.win.agent_pane) orelse a.win.activePane();
            },
            .session => |id| {
                const s = app.sessionById(id) orelse return null;
                return (s.focused() orelse return null).activePane();
            },
            .fold => return null,
        }
    }

    /// The pane the popup shows.
    pub fn popupPane(app: *App) ?*Pane {
        return app.entryPane((app.popup orelse return null).entry);
    }

    /// Whether the pane's viewport follows it, rather than being scrolled up into its history.
    pub fn following(pane: *const Pane) bool {
        const bar = @constCast(pane).term.screens.active.pages.scrollbar();
        return bar.offset + bar.len >= bar.total;
    }

    fn openPopup(app: *App, entry: RailPick) void {
        if (app.entryPane(entry) == null) return;
        app.popup = .{ .entry = entry, .from = app.rail_pick };
        app.popupShow(entry);
    }

    /// Shows `entry` in the popup: the pane before it has its viewport back, and this one's is kept
    /// and put at its newest. A pane of a session tmux does not stream is captured again.
    fn popupShow(app: *App, entry: RailPick) void {
        const pop = &app.popup.?;
        app.popupRestore();
        pop.entry = entry;
        const pane = app.entryPane(entry) orelse return;
        const bar = pane.term.screens.active.pages.scrollbar();
        pop.saved = .{ .pane = pane.id, .offset = bar.offset, .bottom = following(pane) };
        pane.term.scrollViewport(.bottom);
        if (!app.watched(pane) and pane.seed == .done) {
            pane.seed = .wanted;
            app.want_list = true;
        }
        app.dirty = true;
    }

    fn popupRestore(app: *App) void {
        const pop = &app.popup.?;
        const saved = pop.saved orelse return;
        pop.saved = null;
        const pane = app.paneById(saved.pane) orelse return;
        pane.term.scrollViewport(if (saved.bottom) .bottom else .{ .row = saved.offset });
    }

    /// Puts away the popup: the pane has its viewport back and the pick is where it was.
    fn closePopup(app: *App) void {
        if (app.popup == null) return;
        app.popupRestore();
        app.rail_pick = app.popup.?.from;
        app.popup = null;
        app.dirty = true;
    }

    /// A key in the popup: `j` `k` `C-d` `C-u` `g` `G` scroll the pane's history, `/` searches it,
    /// `h` `l` leaf through the rail, Enter goes there into insert, and `q` or Esc close it.
    fn popupKey(app: *App, key: []const u8) !void {
        const pop = &app.popup.?;
        const pane = app.entryPane(pop.entry) orelse return app.closePopup();
        app.dirty = true;
        const page: isize = @max(1, pane.term.rows / 2);
        if (pop.mode == .answer) return app.answerPopupKey(pane, key);
        if (pop.mode == .reply) return app.replyPopupKey(pane, key);
        if (anyKey(key, &.{ "q", "\x1b" })) {
            app.closePopup();
        } else if (anyKey(key, &.{"\r"})) {
            const entry = pop.entry;
            app.closePopup();
            app.rail_pick = entry;
            _ = try app.railKey("\r");
        } else if (anyKey(key, &.{ "j", "\x1b[B", "\x1bOB" })) {
            pane.term.scrollViewport(.{ .delta = 1 });
        } else if (anyKey(key, &.{ "k", "\x1b[A", "\x1bOA" })) {
            pane.term.scrollViewport(.{ .delta = -1 });
        } else if (anyKey(key, &.{"\x04"})) {
            pane.term.scrollViewport(.{ .delta = page });
        } else if (anyKey(key, &.{"\x15"})) {
            pane.term.scrollViewport(.{ .delta = -page });
        } else if (anyKey(key, &.{"g"})) {
            pane.term.scrollViewport(.top);
        } else if (anyKey(key, &.{"G"})) {
            pane.term.scrollViewport(.bottom);
        } else if (anyKey(key, &.{"/"})) {
            app.openSearch();
        } else if (anyKey(key, &.{"a"})) {
            var asked: Asked = .{};
            if (app.popupAsk(pane, &asked)) pop.mode = .answer;
        } else if (anyKey(key, &.{"r"})) {
            pop.mode = .reply;
            pop.reply_len = 0;
        } else if (anyKey(key, &.{ "h", "l" })) {
            var list: [96]RailPick = undefined;
            const n = app.railPicks(&list);
            const at = for (list[0..n], 0..) |entry, i| {
                if (std.meta.eql(entry, pop.entry)) break i;
            } else return;
            const to = if (key[0] == 'l') @min(at + 1, n - 1) else at -| 1;
            if (to != at and list[to] != .fold) {
                pop.mode = .view;
                app.popupShow(list[to]);
            }
        }
    }

    /// The Claude whose window has id `id`, in any session.
    pub fn agentById(app: *const App, id: u32) ?Agent {
        for (app.sessions.items, 0..) |s, si| for (s.wins.items) |win| {
            if (win.id == id) return .{ .session = si, .win = win };
        };
        return null;
    }

    /// A key while a ticket's number is typed after `#`: a digit adds to it, backspace takes one
    /// off, Esc drops it and Enter opens that ticket's modal on the board.
    fn hashKey(app: *App, key: []const u8) !void {
        const len = app.hash_len.?;
        app.dirty = true;
        if (anyKey(key, &.{"\x1b"})) {
            app.hash_len = null;
        } else if (anyKey(key, &.{ "\x7f", "\x08" })) {
            app.hash_len = if (len == 0) null else len - 1;
        } else if (key.len == 1 and std.ascii.isDigit(key[0])) {
            if (len < app.hash.len) {
                app.hash[len] = key[0];
                app.hash_len = len + 1;
            }
        } else if (anyKey(key, &.{"\r"})) {
            app.hash_len = null;
            const id = std.fmt.parseInt(u32, app.hash[0..len], 10) catch return;
            app.normal = false;
            try app.showCard(id);
            if (app.board_view) |*view| view.answering = false;
            if (app.board_view != null) _ = try app.openDetail(id);
        }
    }

    /// A key on the rail's pick, in normal mode over the strip: `j` `k` step it through the rail,
    /// `]` `[` to the next or previous Claude waiting or done, and Enter goes to it, into insert.
    /// Moving it changes nothing in the strip. Whether the key was the pick's.
    fn railKey(app: *App, key: []const u8) !bool {
        if (app.board_view != null) return false;
        var list: [96]RailPick = undefined;
        const n = app.railPicks(&list);
        if (n == 0) return false;
        const here = app.railPicked();
        const at = for (list[0..n], 0..) |entry, i| {
            if (here != null and std.meta.eql(entry, here.?)) break i;
        } else null;
        if (anyKey(key, &.{ "j", "\x1b[B", "\x1bOB" })) {
            app.rail_pick = list[if (at) |i| @min(i + 1, n - 1) else 0];
        } else if (anyKey(key, &.{ "k", "\x1b[A", "\x1bOA" })) {
            app.rail_pick = list[if (at) |i| i -| 1 else n - 1];
        } else if (anyKey(key, &.{ "]", "[" })) {
            var found: [64]Agent = undefined;
            const m = app.needy(&found);
            if (m == 0) return true;
            const from = if (here) |pick| switch (pick) {
                .agent => |id| for (found[0..m], 0..) |a, i| {
                    if (a.win.id == id) break i;
                } else null,
                .session, .fold => null,
            } else null;
            const len: i32 = @intCast(m);
            const by: i32 = if (key[0] == ']') 1 else -1;
            const to: i32 = if (from) |i| @mod(@as(i32, @intCast(i)) + by, len) else if (by > 0) 0 else len - 1;
            app.rail_pick = .{ .agent = found[@intCast(to)].win.id };
        } else if (anyKey(key, &.{" "})) {
            app.openPopup(here orelse return true);
            return true;
        } else if (anyKey(key, &.{"\r"})) {
            const pick = here orelse return true;
            if (pick == .fold) {
                var found: [64]Agent = undefined;
                var folds: [max_folds]Fold = undefined;
                _, const nf = app.railList(&found, &folds);
                for (folds[0..nf]) |fold| if (app.foldKey(fold) == pick.fold) app.toggleFold(pick.fold);
                return true;
            }
            app.normal = false;
            app.rail_pick = null;
            app.dirty = true;
            switch (pick) {
                .agent => |id| if (app.agentById(id)) |a| try app.goAgent(a),
                .session => |id| if (app.sessionIndex(id)) |i| try app.sessionTo(i),
                .fold => unreachable,
            }
            return true;
        } else return false;
        app.dirty = true;
        app.showPick();
        return true;
    }

    /// Scrolls the rail's list of Claudes to start at the pick when it is one the list has scrolled off.
    fn showPick(app: *App) void {
        const pick = app.rail_pick orelse return;
        if (pick == .session) return;
        var lines: [64]AgentLine = undefined;
        const shown = app.railAgents(&lines);
        for (lines[0..shown]) |line| switch (line) {
            .agent => |a| if (pick == .agent and a.win.id == pick.agent) return,
            .pipeline => |fold| if (pick == .fold and app.foldKey(fold) == pick.fold) return,
            else => {},
        };
        var found: [64]Agent = undefined;
        var folds: [max_folds]Fold = undefined;
        const count, _ = app.railList(&found, &folds);
        const to = switch (pick) {
            .agent => |id| for (found[0..count], 0..) |a, i| {
                if (a.win.id == id) break i;
            } else return,
            .fold => count -| 1,
            .session => return,
        };
        app.agent_skip = .{ .n = to, .at = if (app.cur()) |s| s.focused() else null };
    }

    fn toggleRail(app: *App) void {
        app.rail = if (app.rail == .wide) .narrow else .wide;
        app.peek = false;
        app.fit();
        app.want_list = true;
        app.dirty = true;
    }

    fn toggleSort(app: *App) void {
        app.agent_sort = switch (app.agent_sort) {
            .urgency => .recent,
            .recent => .ticket,
            .ticket => .urgency,
        };
        app.dirty = true;
    }

    /// The peek's target is the ticket's card or the Claude's window.
    pub const Look = union(enum) { ticket: u32, window: u32, fold: u64 };

    /// What a peek holds: the ticket and the Claude, either of which may be missing.
    pub const Peek = struct { card: ?*const tickets.Card, win: ?*const Window };

    /// What the pointer rests on, as of `look_at`.
    fn lookUnder(app: *const App, x: u16, y: u16) ?Look {
        if (app.menu != null or app.prompt != null or app.overview != null) return null;
        if (app.board_view) |view| if (view.boxed()) return null;
        if (x < app.railDrawnW()) {
            const line = app.railAgentAt(y) orelse return null;
            return switch (line) {
                .agent, .detail, .meta, .background => |a| .{ .window = a.win.id },
                .pipeline => |fold| .{ .fold = app.foldKey(fold) },
                else => null,
            };
        }
        if (app.feedUnder(x, y)) |look| return look;
        if (app.board_view == null or app.planShown()) return null;
        var buttons: [48]Button = undefined;
        for (app.boardButtons(&buttons)) |button| if (button.hit(x, y)) return null;
        const at = app.boardCardAt(x, y) orelse return null;
        const card = if (app.boardLanes()) app.laneCard(at.lane, at.col, at.row) else app.boardCard(at.col, at.row);
        return if (card) |c| .{ .ticket = c.id } else null;
    }

    /// The ticket of the feed item at (`x`, `y`), where the orchestrator's column is beside the
    /// board; its buttons are not part of it.
    fn feedUnder(app: *const App, x: u16, y: u16) ?Look {
        if (!app.sided() or y < 1) return null;
        const left = app.term_w - app.view_w;
        if (x < left + 2 or x + 2 > app.term_w) return null;
        var f: feed.Feed = undefined;
        if (!app.feedOf(&f)) return null;
        const line = y - 1;
        if (line >= f.count() or f.line(line).kind == .buttons) return null;
        if (line < f.shown and isTryRow(f.line(line).kind)) {
            const need = (app.board orelse return null).needsYou()[f.line(line).need orelse return null];
            return if (need.ticket) |id| .{ .ticket = id } else null;
        }
        const col = x - (left + 2);
        var held: ?feed.Item = null;
        for (0..f.itemCount()) |i| {
            const item = f.item(i).?;
            if (item.need != null) {
                if (item.line <= line) held = item;
            } else if (item.line == line and col >= item.at and col < item.at + item.w) {
                return if (item.ticket) |id| .{ .ticket = id } else null;
            }
        }
        const item = held orelse return null;
        return if (line < f.shown) (if (item.ticket) |id| .{ .ticket = id } else null) else null;
    }

    /// The fold of the rail that holds Claude `a`, if one does.
    fn agentFold(app: *const App, a: Agent) ?u64 {
        const card = if (app.agentSelected(a)) null else if (std.fmt.parseInt(u32, branchTicket(a.win.text(.branch)) orelse "", 10)) |id| app.ticketCard(id) else |_| null;
        if (card) |c| if (c.status == .done) return null;
        if (app.restFolded()) {
            if (a.win.claude == .working or a.win.claude == .waiting) return null;
            return app.foldKey(.{ .repo = "", .count = 0, .open = false, .session = a.session });
        }
        const c = card orelse return null;
        return if (inPipeline(c)) repoHash(c.repo orelse "") else null;
    }

    /// The Claudes the rail's fold `key` holds, as many as `out` has room for.
    pub fn foldMembers(app: *const App, key: u64, out: []Agent) usize {
        var all: [64]Agent = undefined;
        const total = app.agents(&all);
        var n: usize = 0;
        for (all[0..total]) |a| {
            if (n == out.len) break;
            if ((app.agentFold(a) orelse continue) != key) continue;
            out[n] = a;
            n += 1;
        }
        return n;
    }

    /// The pointer moved with no button held: what it rests on starts its pause, and leaving
    /// what a peek is of closes it.
    fn hoverLook(app: *App, m: keys.Mouse) void {
        app.key_typed = false;
        const over = app.lookUnder(m.x, m.y);
        if (std.meta.eql(over, app.look_rest)) return;
        app.look_rest = over;
        app.look_at = app.now;
        if (app.look != null and !std.meta.eql(over, app.look)) {
            app.look = null;
            app.dirty = true;
        }
    }

    /// Puts the peek away, and keeps what it was of from coming back until the pointer or the
    /// pick has been elsewhere.
    fn lookAway(app: *App) void {
        if (app.look) |was| {
            app.look_off = was;
            app.look = null;
            app.dirty = true;
        } else if (app.look_rest) |rest| app.look_off = rest;
    }

    /// What the pick is on, the board's card or the rail's entry, which a peek follows after a
    /// pause with no key.
    fn focusLook(app: *const App) ?Look {
        const view = app.board_view orelse {
            if (!app.key_typed or app.menu != null or app.prompt != null) return null;
            return switch (app.railPicked() orelse return null) {
                .agent => |id| .{ .window = id },
                .fold => |key| .{ .fold = key },
                .session => null,
            };
        };
        if (!app.key_typed or view.boxed() or view.focus != .board or app.planShown() or app.menu != null or app.prompt != null) return null;
        const card = app.boardCard(view.col, view.row) orelse return null;
        return .{ .ticket = card.id };
    }

    /// Opens the peek once the pointer or the pick has rested on something for `look_ms`, and
    /// redraws it while it is open, for its pane's lines. Returns how long until the next.
    pub fn lookStep(app: *App) i64 {
        const never = std.math.maxInt(i64);
        if (app.menu != null or app.prompt != null or app.overview != null) {
            app.look = null;
            return never;
        }
        if (app.look != null) {
            const left = look_live_ms - (app.now - app.look_drawn);
            if (left > 0) return left;
            app.look_drawn = app.now;
            app.dirty = true;
            return look_live_ms;
        }
        const want: Look, const since: i64 = if (app.look_rest) |rest| .{ rest, app.look_at } else if (app.focusLook()) |pick| .{ pick, app.key_at } else return never;
        if (app.look_off) |off| {
            if (std.meta.eql(off, want)) return never;
            app.look_off = null;
        }
        const left = since + app.look_after - app.now;
        if (left > 0) return left;
        app.look = want;
        app.look_drawn = app.now;
        app.look_here = if (app.look_rest != null) .{ .x = app.pointer.x, .y = app.pointer.y } else null;
        app.dirty = true;
        return look_live_ms;
    }

    /// What `look` is of now.
    pub fn peekOf(app: *const App, look: Look) ?Peek {
        switch (look) {
            .ticket => |id| {
                const card = app.ticketCard(id) orelse return null;
                return .{ .card = card, .win = app.claudeOf(card) };
            },
            .fold => return null,
            .window => |id| {
                const a = app.agentById(id) orelse return null;
                const card = if (std.fmt.parseInt(u32, branchTicket(a.win.text(.branch)) orelse "", 10)) |n| app.ticketCard(n) else |_| null;
                return .{ .card = card, .win = a.win };
            },
        }
    }

    /// The last non-blank rows of `pane`'s screen, top to bottom, as many as `out` holds, each
    /// copied into `buf`'s next `row_len` bytes. Returns how many.
    pub fn paneTail(pane: *Pane, buf: []u8, row_len: usize, out: [][]const u8) usize {
        const screen = pane.term.screens.active;
        var n: usize = 0;
        var y: i32 = pane.term.rows;
        while (y > 0 and n < out.len and (n + 1) * row_len <= buf.len) {
            y -= 1;
            const start = screen.pages.pin(.{ .active = .{ .x = 0, .y = @intCast(y) } }) orelse break;
            var end = start;
            end.x = pane.term.cols - 1;
            var row: Writer = .fixed(buf[n * row_len ..][0..row_len]);
            screen.dumpString(&row, .{ .tl = start, .br = end, .unwrap = false }) catch {};
            const text = std.mem.trim(u8, row.buffered(), " \n");
            if (text.len == 0) continue;
            out[n] = text;
            n += 1;
        }
        std.mem.reverse([]const u8, out[0..n]);
        return n;
    }

    /// A key while a peek is open: Esc puts it away, as does any other, which then goes on to do
    /// what it does. ⏎ goes to a Claude's pane, and on a card's peek picks the card and leaves
    /// the key to the board; space opens its card. Returns whether the key was the peek's.
    fn lookKey(app: *App, text: []const u8) !bool {
        app.key_at = app.now;
        app.key_typed = for ([_][]const u8{ "j", "k", "h", "l", "\x1b[A", "\x1b[B", "\x1b[C", "\x1b[D", "\x1bOA", "\x1bOB", "\x1bOC", "\x1bOD" }) |move| {
            if (std.mem.eql(u8, text, move)) break true;
        } else false;
        const look = app.look orelse {
            app.look_rest = null;
            return false;
        };
        const was = app.peekOf(look);
        app.lookAway();
        app.look_rest = null;
        if (std.mem.eql(u8, text, "\x1b") and !app.typing()) return true;
        if (app.typing() or was == null) return false;
        if (std.mem.eql(u8, text, "\r")) {
            if (look == .ticket and app.board_view != null) {
                _ = app.pickCard(look.ticket);
                app.board_view.?.focus = .board;
                if (was.?.card) |card| if (card.ask != null) {
                    _ = try app.openDetail(card.id);
                    return true;
                };
                return false;
            }
            if (was.?.win) |win| if (win.agent_pane != 0) {
                try app.showPane(win.agent_pane);
                return true;
            };
        } else if (std.mem.eql(u8, text, " ")) if (was.?.card) |card| if (app.board_view != null) {
            _ = try app.openDetail(card.id);
            return true;
        };
        return false;
    }

    /// The pointer moved with no button held: resting on the narrow rail draws it wide over the
    /// strip, after `dwell`, and leaving it draws it narrow again.
    fn hoverRail(app: *App, x: u16) void {
        if (app.rail == .wide or app.railW() == 0) return;
        if (x < app.railDrawnW()) {
            if (app.hover_at == 0 and !app.peek) app.hover_at = app.now;
            return;
        }
        app.hover_at = 0;
        if (app.peek) {
            app.peek = false;
            app.dirty = true;
        }
    }

    /// Draws the narrow rail wide once the pointer has rested on it long enough. Returns how
    /// long until it would.
    pub fn dwell(app: *App) i64 {
        return @min(app.railDwell(), app.lookStep());
    }

    fn railDwell(app: *App) i64 {
        if (app.hover_at == 0 or app.overlay()) return std.math.maxInt(i64);
        const left = app.hover_at + dwell_ms - app.now;
        if (left > 0) return left;
        app.hover_at = 0;
        app.peek = true;
        app.dirty = true;
        return std.math.maxInt(i64);
    }

    /// Whether a Claude is working in any window, its mark spinning.
    pub fn working(app: *const App) bool {
        for (app.sessions.items) |s| for (s.wins.items) |win| if (win.claude == .working or win.stirring) return true;
        return false;
    }

    /// A Claude done in the session's focused window has been looked at: its pane's state is
    /// cleared in tmux, unless a hook has moved it on since.
    fn see(app: *App, s: *Session) !void {
        const win = s.focused() orelse return;
        if (win.claude != .done) return;
        win.claude = .none;
        // Not `if`: a command it runs has a reply of its own, which arena would take for the
        // reply to the next command it sent.
        for (win.panes.items) |pane| try app.send(
            .ignore,
            "set -pF -t %{d} @arena_claude '#{{?#{{==:#{{@arena_claude}},done}},,#{{@arena_claude}}}}'",
            .{pane.id},
        );
    }

    fn toggleFull(app: *App) void {
        const s = app.cur() orelse return;
        s.full = !s.full;
        app.want_list = true;
        app.dirty = true;
    }

    /// The session rail's width, the same whatever its names, so the strip does not move when a
    /// Claude comes or goes. A terminal too narrow for it has none.
    /// Narrow, the rail shows a session by a short name, and a Claude by its mark and ticket.
    pub fn railW(app: *const App) u16 {
        if (app.term_w < 48 or app.sessions.items.len == 0) return 0;
        return if (app.rail == .wide) app.railWideW() else rail_narrow;
    }

    pub fn railWideW(app: *const App) u16 {
        return @min(rail_wide, @max(rail_narrow, app.term_w / 3));
    }

    /// Where the rail's top row says how many need the human, right of `▤ board`.
    pub const rail_needs_x = 9;

    /// How many items are the human's move.
    pub fn needsCount(app: *const App) usize {
        return if (app.board) |*b| b.needsYou().len else 0;
    }

    /// The rail's top row's count of what needs the human, as ` ▲ N`; nothing with none, so the
    /// row keeps its room for the rest.
    pub fn railNeeds(app: *const App, buf: []u8) []const u8 {
        if (app.needsCount() == 0) return "";
        return std.fmt.bufPrint(buf, " ▲ {d}", .{app.needsCount()}) catch "";
    }

    /// The rail's width as drawn, which a narrow one peeking is not.
    pub fn railDrawnW(app: *const App) u16 {
        return if (app.peek and app.railW() > 0) app.railWideW() else app.railW();
    }

    /// The strip's width, or with the orchestrator beside the board, its window's.
    pub fn fit(app: *App) void {
        const full = app.fullW();
        app.view_w = if (app.columnAlone()) full else if (app.sided()) @min(side_w, full * 2 / 5) else full;
    }

    /// The terminal width under which home cannot hold the column and the plan side by
    /// side, and shows one at a time.
    pub const half_below = 110;
    pub const half_hint = " p plan  B board ";

    /// Whether home has the room of half a screen.
    pub fn halfHome(app: *const App) bool {
        const view = app.board_view orelse return false;
        return view.home and app.term_w < half_below and app.hasPlan();
    }

    /// Whether home shows the orchestrator's column alone, the plan or the board being one key away.
    pub fn columnAlone(app: *const App) bool {
        return app.halfHome() and app.board_view.?.alone and !app.side_folded;
    }

    /// Whether the orchestrator's column is beside the open board, unless folded: while the
    /// orchestrator runs, with its window, and at home always, with what babylon says of it. At
    /// half a screen it is beside nothing: the plan or the board has the screen, or it has.
    pub fn sided(app: *const App) bool {
        const view = app.board_view orelse return false;
        if (app.halfHome() and !view.alone) return false;
        return !app.side_folded and (view.home or app.orchestratorSession() != null);
    }

    /// At half a screen, home swaps to the column (`o`) or the plan (`p`), each having the whole
    /// width, its keys its own.
    fn swapHome(app: *App, column: bool) !void {
        const view = &app.board_view.?;
        view.alone = column;
        view.plan = true;
        view.focus = if (column) .orchestrator else .board;
        view.help = false;
        view.detail = null;
        app.normal = false;
        app.dirty = true;
        app.reflow();
        if (column) try app.toSide();
    }

    /// `p` on the column alone swaps to the plan, which keeps next's own `p` (pin) off a ticket
    /// of next here; `J` `K` and `x` on the plan's next do the rest.
    fn halfKey(app: *App, key: []const u8) !bool {
        if (!app.columnAlone() or !anyKey(key, &.{"p"})) return false;
        try app.swapHome(false);
        return true;
    }

    /// Whether the column has the keys: its window's once arena is in its session, else its own.
    pub fn columnFocused(app: *const App) bool {
        const view = app.board_view orelse return false;
        return view.focus == .orchestrator and !view.boxed() and app.sided();
    }

    pub const OrchestratorState = enum { working, waiting, stalled, idle, restarting, off };

    /// The orchestrator as its column's head says it: its window's Claude while its session is
    /// there, else restarting while babylon keeps it on, else off.
    pub fn orchestratorState(app: *const App) OrchestratorState {
        if (app.orchestratorWindow()) |win| return switch (win.claude) {
            .working => .working,
            .waiting => .waiting,
            .stalled => .stalled,
            else => .idle,
        };
        const state = app.orchestrator() orelse return .off;
        return if (state.on) .restarting else .off;
    }

    /// The feed atop the orchestrator's column, from babylon's board: none without one.
    pub fn feedOf(app: *const App, f: *feed.Feed) bool {
        const b = if (app.board) |*b| b else return false;
        const today = app.epoch - @mod(app.epoch + app.utc_offset, 86400);
        const lit: feed.View = if (app.board_view) |view| .{ .lit = view.tab, .scroll = view.tab_scroll } else .{};
        const pick = if (app.board_view) |view| view.pick else std.math.maxInt(usize);
        feed.buildPicked(f, b, app.refusals.items, app.view_w -| 4, app.view_h -| 2, app.epoch, today, lit, pick);
        return true;
    }

    /// Whether the feed has the keys: the column has them, in normal mode while its window is in it.
    pub fn feedFocused(app: *const App) bool {
        return app.columnFocused() and (app.normal or !app.sideShown());
    }

    pub const FeedLit = enum { none, focused, dim };

    /// How the feed's pick is lit: bright while the feed has the keys, dim while the plan has them.
    pub fn feedLit(app: *const App) FeedLit {
        if (app.feedFocused()) return .focused;
        return if (app.planShown() and !app.columnFocused()) .dim else .none;
    }

    /// The ticket the side that does not have the keys lights dim: the plan's picked row's while
    /// the plan has them, the feed's picked item's while the feed has them. Worked out each frame
    /// from the picks, so it cannot go stale.
    pub fn settleLit(app: *App) void {
        app.lit_ticket = null;
        if (!app.planShown()) return;
        if (app.columnFocused()) {
            var f: feed.Feed = undefined;
            if (app.feedOf(&f)) if (app.feedPick(&f)) |on| {
                app.lit_ticket = on.ticket;
            };
            return;
        }
        var sheet: sheets.Sheet = undefined;
        if (!app.planSheet(&sheet)) return;
        if (sheet.picked(app.board_view.?.plan_pick)) |row| app.lit_ticket = row.ticket;
    }

    /// The feed's item that is lit: its pick while the feed has the keys, else the one of the
    /// plan's picked ticket.
    pub fn feedLitItem(app: *const App, f: *const feed.Feed) ?feed.Item {
        switch (app.feedLit()) {
            .none => return null,
            .focused => return app.feedPick(f),
            .dim => {
                const id = app.lit_ticket orelse return null;
                for (0..f.itemCount()) |i| if (f.item(i).?.ticket == id) return f.item(i);
                return null;
            },
        }
    }

    /// Whether the plan's `row` is lit: the pick's while the plan has the keys, else the row of
    /// the feed's picked ticket, dim.
    pub fn planRowLit(app: *const App, row: sheets.Row) bool {
        const view = app.board_view orelse return false;
        if (!app.columnFocused()) return if (row.pick) |p| p == view.plan_pick else false;
        const id = app.lit_ticket orelse return false;
        return row.ticket == id and (row.kind == .now or row.kind == .next);
    }

    /// The plan's pick put on the row of ticket `id` in now or next, when the plan is shown.
    fn pickPlan(app: *App, id: u32) void {
        var sheet: sheets.Sheet = undefined;
        if (!app.planSheet(&sheet)) return;
        for (sheet.rows[0..sheet.n]) |row| {
            const pick = row.pick orelse continue;
            if (row.ticket != id or (row.kind != .now and row.kind != .next)) continue;
            app.board_view.?.plan_pick = pick;
            return;
        }
    }

    /// The feed's pick, kept to what the feed has now: none while it has nothing to pick.
    pub fn feedPick(app: *const App, f: *const feed.Feed) ?feed.Item {
        const view = app.board_view orelse return null;
        const n = f.itemCount();
        return if (n == 0) null else f.item(@min(view.pick, n - 1));
    }

    /// A key on the feed, while the orchestrator's column has the keys in normal mode: `j` `k`
    /// move the pick through it and `]` `[` through Your move, the picked card lit on the board;
    /// on a Your move item, an action's key runs it as babylon gives it, and on a ticket landing
    /// or building, Enter goes to its Claude. Whether the key was the feed's.
    fn feedKey(app: *App, key: []const u8) !bool {
        var f: feed.Feed = undefined;
        if (!app.feedOf(&f)) return false;
        const view = &app.board_view.?;
        const n = f.itemCount();
        if (n == 0) return false;
        view.pick = @min(view.pick, n - 1);
        const moves = f.items_shown;
        const was = view.pick;
        if (f.item(view.pick).?.chip and anyKey(key, &.{ " ", "\r" })) return app.openChip(f.item(view.pick).?);
        const first = f.firstSpot();
        if (anyKey(key, &.{ "j", "\x1b[B", "\x1bOB" })) {
            if (view.pick + 1 == first + f.popCount() and view.pick >= first and f.scroll < f.max_scroll) {
                view.tab_scroll = f.scroll + 1;
                app.dirty = true;
                return app.pickPanelEnd(true);
            }
            view.pick = @min(view.pick + 1, n - 1);
        } else if (anyKey(key, &.{ "k", "\x1b[A", "\x1bOA" })) {
            if (view.pick == first and f.scroll > 0) {
                view.tab_scroll = f.scroll - 1;
                app.dirty = true;
                return app.pickPanelEnd(false);
            }
            view.pick -|= 1;
        } else if (anyKey(key, &.{"]"})) {
            if (moves > 0) view.pick = nextTile(&f, view.pick, moves);
        } else if (anyKey(key, &.{"["})) {
            if (moves > 0) view.pick = prevTile(&f, view.pick, moves);
        } else if (anyKey(key, &.{" "})) {
            const id = f.item(view.pick).?.ticket orelse return true;
            _ = app.pickCard(id);
            app.pickPlan(id);
            _ = try app.openDetail(id);
        } else return app.feedAct(f.item(view.pick).?, key);
        app.dirty = true;
        if (view.pick != was) if (f.item(view.pick).?.ticket) |id| {
            _ = app.pickCard(id);
            app.pickPlan(id);
        };
        return true;
    }

    /// The first of the `moves` items of Your move that is of the need after `at`'s, or the first.
    fn nextTile(f: *const feed.Feed, at: usize, moves: usize) usize {
        if (at >= moves) return 0;
        var to = at + 1;
        while (to < moves and f.item(to).?.need == f.item(at).?.need) to += 1;
        return if (to < moves) to else 0;
    }

    /// The first item of the need before `at`'s, or of the last when `at` is of the first or is
    /// not of Your move.
    fn prevTile(f: *const feed.Feed, at: usize, moves: usize) usize {
        var to = moves - 1;
        if (at < moves) {
            var from = at;
            while (from > 0 and f.item(from - 1).?.need == f.item(from).?.need) from -= 1;
            if (from > 0) to = from - 1;
        }
        while (to > 0 and f.item(to - 1).?.need == f.item(to).?.need) to -= 1;
        return to;
    }

    /// A tab of the strip clicked or opened: its list lit in the panel, from the top.
    fn openChip(app: *App, item: feed.Item) !bool {
        const view = &app.board_view.?;
        app.dirty = true;
        const section = item.section.?;
        if (view.tab != section) view.tab_scroll = 0;
        view.tab = section;
        return true;
    }

    /// The pick put on the panel's last ticket, or its first, once it has scrolled a line.
    fn pickPanelEnd(app: *App, last: bool) bool {
        var f: feed.Feed = undefined;
        if (!app.feedOf(&f)) return true;
        const view = &app.board_view.?;
        const first = f.firstSpot();
        if (f.popCount() > 0) view.pick = if (last) first + f.popCount() - 1 else first;
        if (f.item(view.pick).?.ticket) |id| {
            _ = app.pickCard(id);
            app.pickPlan(id);
        }
        return true;
    }

    /// The wheel over the panel scrolls its list a line a notch. Whether it was over the panel.
    fn panelWheel(app: *App, m: keys.Mouse) bool {
        if (!app.sided() or m.y < 1) return false;
        const left = app.term_w - app.view_w;
        if (m.x < left + 2 or m.x + 2 > app.term_w) return false;
        var f: feed.Feed = undefined;
        if (!app.feedOf(&f)) return false;
        const top = f.height() - f.panel;
        const row = m.y - 1;
        if (row < top or row >= f.height()) return false;
        const view = &app.board_view.?;
        view.tab_scroll = if (m.code & 1 == 0) f.scroll -| 1 else @min(f.scroll + 1, f.max_scroll);
        app.dirty = true;
        return true;
    }

    fn feedAct(app: *App, item: feed.Item, key: []const u8) !bool {
        const b = if (app.board) |*b| b else return false;
        const named: []const u8 = if (std.mem.eql(u8, key, "\r")) "⏎" else key;
        if (item.next) |at| return app.nextKey(at, &app.board_view.?.pick, key);
        const at = item.need orelse {
            if (!std.mem.eql(u8, named, "⏎")) return false;
            const id = item.ticket orelse return true;
            for (b.cards()) |card| if (card.id == id) if (card.holder()) |pane| try app.showPane(pane);
            return true;
        };
        const need = b.needsYou()[at];
        if (item.step) |s| if (s < need.steps.len) {
            if (anyKey(key, &.{"o"}) and feed.isLook(need.steps[s])) return app.lookAtDiff(need, need.steps[s]);
        };
        if (item.step) |s| if (s < need.steps.len) for (need.steps[s].actions) |action| {
            if (!std.mem.eql(u8, action.key, named)) continue;
            if (action.needs) |needs| if (std.mem.eql(u8, needs, "words")) {
                var id: [32]u8 = undefined;
                return app.openWords(std.fmt.bufPrint(&id, "{s}#{d}", .{ need.id, need.steps[s].n }) catch return true);
            };
            if (action.argv) |argv| return app.runNeed(need.id, argv);
            return true;
        };
        const found = for (need.actions) |action| {
            if (std.mem.eql(u8, action.key, named)) break action;
        } else null;
        // an action on a key is babylon's: opening the doc only has the keys it leaves
        if (need.doc != null and found == null and anyKey(key, &.{ "o", "\r" })) return app.openDoc(need);
        const action = found orelse return false;
        if (action.needs) |needs| if (std.mem.eql(u8, needs, "words")) return app.openWords(need.id);
        if (action.argv) |argv| return app.runNeed(need.id, argv);
        const ticket = need.ticket orelse return true;
        const needs = action.needs orelse return true;
        if (std.mem.eql(u8, needs, "surface")) {
            var id_buf: [12]u8 = undefined;
            return app.runNeed(need.id, &.{ "babylon", "start", std.fmt.bufPrint(&id_buf, "{d}", .{ticket}) catch return true });
        }
        if (std.mem.eql(u8, needs, "pick") and app.pickCard(ticket)) {
            app.board_view.?.giving = 0;
            app.dirty = true;
        }
        return true;
    }

    /// A click under Your move's items: on a chip of the strip, which opens its list, or on a
    /// ticket of the open list, which is the pick. Whether it was on the strip or the list.
    fn stripClick(app: *App, f: *const feed.Feed, row: usize, col: usize) !bool {
        if (row >= f.count()) return false;
        const view = &app.board_view.?;
        for (f.items_shown..f.itemCount()) |i| {
            const item = f.item(i).?;
            const here = item.line == row and (item.w == 0 or (col >= item.at and col < item.at + item.w));
            if (!here) continue;
            view.focus = .orchestrator;
            if (app.sideDue()) app.normal = true;
            view.pick = i;
            if (item.chip) return app.openChip(item);
            if (item.ticket) |id| {
                _ = app.pickCard(id);
                app.pickPlan(id);
            }
            app.dirty = true;
            return true;
        }
        return true;
    }

    /// A click on the feed's Your move: its item is the pick, and on a button, what the button's
    /// key does. Whether the click was on one of its items.
    fn feedClick(app: *App, m: keys.Mouse) !bool {
        if (!app.sided() or m.y < 1) return false;
        const left = app.term_w - app.view_w;
        if (m.x < left + 2 or m.x + 2 > app.term_w) return false;
        var f: feed.Feed = undefined;
        if (!app.feedOf(&f)) return false;
        const row = m.y - 1;
        if (row >= f.shown) return app.stripClick(&f, row, m.x - (left + 2));
        if (isTryRow(f.line(row).kind) or f.line(row).kind == .try_head) return app.tryClick(&f, row, m.x - (left + 2));
        var at: ?usize = null;
        for (0..f.items_shown) |i| {
            if (f.item(i).?.line <= row) at = i;
        }
        const i = at orelse return false;
        const view = &app.board_view.?;
        view.focus = .orchestrator;
        if (app.sideDue()) app.normal = true;
        view.pick = i;
        app.dirty = true;
        const item = f.item(i).?;
        if (item.ticket) |id| {
            _ = app.pickCard(id);
            app.pickPlan(id);
        }
        const line = f.line(row);
        if (line.kind != .buttons) return true;
        const chip = feed.chipKeyAt(line.text, m.x - (left + 2), app.roles != null) orelse return true;
        const key: []const u8 = if (std.mem.eql(u8, chip, "⏎")) "\r" else if (std.mem.eql(u8, chip, "space")) " " else chip;
        _ = try app.feedAct(item, key);
        return true;
    }

    /// What the line of the words of a to-try check says after them: the question, and the keys.
    pub const back_hint = "  what went wrong?  ⏎ send it back  esc not ✗";
    const send_back = "⏎ send it back";

    /// Whether `prompt` is the words of a to-try check that failed.
    pub fn stepWords(prompt: menu.Prompt) bool {
        return prompt.what == .words and std.mem.indexOfScalar(u8, prompt.item(), '#') != null;
    }

    /// Whether the click `m` is on `send it back`, at the right end of the line of the words of a
    /// failed check at the column's foot.
    fn onSendBack(app: *const App, m: keys.Mouse) bool {
        const inner = app.view_w -| 4;
        if (m.y != app.view_h -| 2 or inner < cellCount(back_hint)) return false;
        const hint = (app.term_w - app.view_w) + 1 + (inner - cellCount(back_hint));
        const from = hint + cellCount(back_hint[0..std.mem.indexOf(u8, back_hint, send_back).?]);
        return m.x >= from and m.x < from + cellCount(send_back);
    }

    fn isTryRow(kind: feed.Kind) bool {
        return switch (kind) {
            .try_title, .try_machine, .try_step, .try_buttons => true,
            else => false,
        };
    }

    /// A click on a to-try tile, `col` cells from the feed's text: a check's row picks that check,
    /// a button does what its key does, and the tile's number and title open its modal.
    fn tryClick(app: *App, f: *const feed.Feed, row: usize, col: usize) !bool {
        const line = f.line(row);
        if (line.kind == .try_head) return true;
        const view = &app.board_view.?;
        const need_at = line.need orelse return true;
        // the item it picks: the check's own, else the tile's, the one picked already when it is in it
        var first: ?usize = null;
        var mine: ?usize = null;
        for (0..f.items_shown) |i| {
            const item = f.item(i).?;
            if (item.need != need_at) continue;
            if (first == null) first = i;
            if (line.step != null and item.step == line.step) mine = i;
            if (line.step == null and i == view.pick) mine = i;
        }
        const i = mine orelse (if (first) |k| (if (view.pick >= k and f.item(view.pick) != null and f.item(view.pick).?.need == need_at) view.pick else k) else return true);
        view.focus = .orchestrator;
        if (app.sideDue()) app.normal = true;
        view.pick = i;
        app.dirty = true;
        const item = f.item(i).?;
        if (item.ticket) |id| {
            _ = app.pickCard(id);
            app.pickPlan(id);
        }
        const inner = app.view_w -| 2;
        switch (line.kind) {
            .try_title => {
                const id = item.ticket orelse return true;
                // the chip takes the cells before the title, the age those after it
                if (col + 1 >= 8 and col + 1 + line.alt.len + 2 < inner) _ = try app.openDetail(id);
            },
            .try_machine => {
                if (line.alt.len > 0 and col + 1 + cellCount(line.alt) + 5 >= inner) return app.feedAct(item, "x");
            },
            .try_buttons => {
                if (line.failed) return true;
                const chip = feed.chipKeyAt(line.text, col, true) orelse return true;
                _ = try app.feedAct(item, chip);
            },
            else => {},
        }
        return true;
    }

    /// A line opened at the column's foot for the human's words on Your move item `id`: Enter
    /// runs its words action with them, Escape drops it.
    fn openWords(app: *App, id: []const u8) bool {
        if (id.len > @typeInfo(@FieldType(menu.Prompt, "target")).array.len) return true;
        var prompt: menu.Prompt = .{ .what = .words };
        @memcpy(prompt.target[0..id.len], id);
        prompt.target_len = id.len;
        app.prompt = prompt;
        app.normal = false;
        app.dirty = true;
        return true;
    }

    /// Enter on a words line: the item's words action run with what was typed as its last
    /// argument, as babylon's `argv` says. Nothing typed runs nothing.
    fn sendWords(app: *App, prompt: menu.Prompt) !void {
        app.endWords();
        const b = if (app.board) |*b| b else return;
        if (prompt.len == 0) return;
        if (std.mem.indexOfScalar(u8, prompt.item(), '#')) |hash| {
            const n = std.fmt.parseInt(u32, prompt.item()[hash + 1 ..], 10) catch return;
            for (b.needsYou()) |need| {
                if (!std.mem.eql(u8, need.id, prompt.item()[0..hash])) continue;
                for (need.steps) |step| {
                    if (step.n != n) continue;
                    for (step.actions) |action| {
                        const needs = action.needs orelse continue;
                        if (!std.mem.eql(u8, needs, "words")) continue;
                        const argv = action.argv orelse return;
                        const full = try app.gpa.alloc([]const u8, argv.len + 1);
                        defer app.gpa.free(full);
                        @memcpy(full[0..argv.len], argv);
                        full[argv.len] = prompt.text();
                        _ = try app.runNeed(need.id, full);
                        return;
                    }
                }
            }
            return;
        }
        for (b.needsYou()) |need| {
            if (!std.mem.eql(u8, need.id, prompt.item())) continue;
            for (need.actions) |action| {
                const needs = action.needs orelse continue;
                if (!std.mem.eql(u8, needs, "words")) continue;
                const argv = action.argv orelse return;
                const full = try app.gpa.alloc([]const u8, argv.len + 1);
                defer app.gpa.free(full);
                @memcpy(full[0..argv.len], argv);
                full[argv.len] = prompt.text();
                _ = try app.runNeed(need.id, full);
                return;
            }
        }
    }

    /// A line opened at the board's foot for ticket `id`'s why in next, `was` in it to be edited:
    /// Enter puts the ticket in next, or keeps it there, with what is typed; Escape drops it.
    fn openWhy(app: *App, id: u32, was: []const u8) bool {
        var prompt: menu.Prompt = .{ .what = .why };
        const number = std.fmt.bufPrint(&prompt.target, "{d}", .{id}) catch return true;
        prompt.target_len = number.len;
        var keep = @min(was.len, prompt.buf.len - 4);
        while (keep < was.len and keep > 0 and was[keep] & 0xC0 == 0x80) keep -= 1;
        @memcpy(prompt.buf[0..keep], was[0..keep]);
        prompt.len = keep;
        app.prompt = prompt;
        app.normal = false;
        app.dirty = true;
        return true;
    }

    /// Enter on a why line: `babylon next N --why TEXT`, which adds the ticket at the bottom of
    /// next or, with it there, changes its why. Nothing typed runs nothing.
    fn sendWhy(app: *App, prompt: menu.Prompt) !void {
        app.endWords();
        if (prompt.len == 0) return;
        var said: [40]u8 = undefined;
        const refusal = std.fmt.bufPrint(&said, "next:{s}", .{prompt.item()}) catch return;
        _ = try app.runNeed(refusal, &.{ "babylon", "next", prompt.item(), "--why", prompt.text() });
    }

    /// `/` on the board: a line in its header to type what the cards are narrowed to, what Enter
    /// kept already in it.
    fn openFind(app: *App) void {
        var prompt: menu.Prompt = .{ .what = .find };
        @memcpy(prompt.buf[0..app.find_len], app.find[0..app.find_len]);
        prompt.len = app.find_len;
        app.prompt = prompt;
        app.normal = false;
        app.dirty = true;
    }

    /// Enter on the find line: what is typed is kept, and the keys are the board's again.
    fn keepFind(app: *App, prompt: menu.Prompt) void {
        @memcpy(app.find[0..prompt.len], prompt.text());
        app.find_len = prompt.len;
        app.prompt = null;
        app.normal = app.sideDue();
        app.refind();
    }

    /// Escape: nothing is narrowed any more.
    fn clearFind(app: *App) void {
        app.find_len = 0;
        app.prompt = null;
        app.normal = app.sideDue();
        app.refind();
    }

    /// The pick back on the first card the narrowing leaves, in the first lane that has one.
    fn refind(app: *App) void {
        app.dirty = true;
        const view = if (app.board_view) |*open| open else return;
        view.row = 0;
        view.lane = app.firstLane();
    }

    /// The words line gone, the feed having its keys back.
    fn endWords(app: *App) void {
        app.prompt = null;
        app.normal = app.sideDue();
        app.dirty = true;
    }

    /// The doc the needs-you item of ticket `id` names, opened as the inbox's `o` opens it.
    fn openAskDoc(app: *App, id: u32) !void {
        const b = if (app.board) |*b| b else return;
        for (b.needsYou()) |need| if (need.ticket == id and need.doc != null) {
            _ = try app.openDoc(need);
            return;
        };
    }

    /// The doc of a row, opened: a link by `xdg-open`, a file of the ticket's repo in a
    /// window of its own, in `glow` else `less`.
    fn openDoc(app: *App, need: tickets.Need) !bool {
        const doc = need.doc orelse return true;
        if (std.mem.startsWith(u8, doc, "http://") or std.mem.startsWith(u8, doc, "https://")) {
            return app.runNeed(need.id, &.{ "xdg-open", doc });
        }
        if (!plainName(need.repo)) return true;
        const script =
            "f=\"$HOME/projects/$1/$2\"; if [ ! -f \"$f\" ]; then echo \"no such file: $f\"; read _; exit; fi; " ++
            "if command -v glow >/dev/null 2>&1; then glow -p \"$f\"; else less \"$f\"; fi";
        var cmd: Writer.Allocating = .init(app.gpa);
        defer cmd.deinit();
        try cmd.writer.writeAll("new-window -a -n doc sh -c ");
        for ([_][]const u8{ script, "_", need.repo, doc }, 0..) |arg, i| {
            if (i > 0) try cmd.writer.writeAll(" ");
            try tmuxQuote(&cmd.writer, arg);
        }
        try app.closeBoard();
        try app.send(.ignore, "{s}", .{cmd.written()});
        return true;
    }

    /// `o` on a check to look at the diff: meatcheck on the landed change, in a window of its own
    /// so no Claude waits on it, its comments back as the ✗'s words, none as ✓.
    fn lookAtDiff(app: *App, need: tickets.Need, step: tickets.TryStep) !bool {
        const ticket = need.ticket orelse return true;
        if (!plainName(need.repo)) return true;
        const script =
            "cd \"$HOME/projects/$1\" || exit; " ++
            "out=$(meatcheck --diff \"$2\" --prompt \"$3\") || { echo \"meatcheck failed\"; read _; exit; }; " ++
            "if [ -z \"$out\" ]; then babylon tried \"$4\" \"$5\" ok; else " ++
            "words=$(printf '%s\\n' \"$out\" | awk -F, '{t=$4; for (i=5;i<=NF;i++) t=t \",\" $i; l=($2==$3)?$2:$2 \"-\" $3; printf \"%s:%s: %s\\n\",$1,l,t}'); " ++
            "babylon tried \"$4\" \"$5\" no \"$words\"; fi";
        var id: [12]u8 = undefined;
        var n: [12]u8 = undefined;
        var cmd: Writer.Allocating = .init(app.gpa);
        defer cmd.deinit();
        try cmd.writer.writeAll("new-window -a -n look sh -c ");
        const args = [_][]const u8{
            script,                                                   "_",
            need.repo,                                                step.range,
            step.text,                                                std.fmt.bufPrint(&id, "{d}", .{ticket}) catch return true,
            std.fmt.bufPrint(&n, "{d}", .{step.n}) catch return true,
        };
        for (args, 0..) |arg, i| {
            if (i > 0) try cmd.writer.writeAll(" ");
            try tmuxQuote(&cmd.writer, arg);
        }
        try app.send(.ignore, "{s}", .{cmd.written()});
        return true;
    }

    /// A key on a ticket of next, the `at`th: `J` and `K` move it down and up, `x` drops it from
    /// next and `p` pins it where it is. Each goes through babylon as the human, which marks the
    /// ticket as the human's, so the orchestrator moves it only with a proposal.
    fn nextKey(app: *App, at: usize, pick: *usize, key: []const u8) !bool {
        const b = if (app.board) |*b| b else return false;
        const plan = b.next();
        if (at >= plan.len) return false;
        var id: [12]u8 = undefined;
        var place: [12]u8 = undefined;
        const ticket = std.fmt.bufPrint(&id, "{d}", .{plan[at].ticket}) catch return true;
        var said: [24]u8 = undefined;
        const refusal = std.fmt.bufPrint(&said, "next:{d}", .{plan[at].ticket}) catch return true;
        if (anyKey(key, &.{"x"})) return app.runNeed(refusal, &.{ "babylon", "next", ticket, "--drop" });
        if (anyKey(key, &.{"p"})) {
            const here = std.fmt.bufPrint(&place, "{d}", .{at + 1}) catch return true;
            return app.runNeed(refusal, &.{ "babylon", "next", ticket, "--at", here });
        }
        const down = anyKey(key, &.{"J"});
        if (!down and !anyKey(key, &.{"K"})) return false;
        if (if (down) at + 1 >= plan.len else at == 0) return true;
        const to = std.fmt.bufPrint(&place, "{d}", .{if (down) at + 2 else at}) catch return true;
        pick.* = if (down) pick.* + 1 else pick.* - 1;
        return app.runNeed(refusal, &.{ "babylon", "next", ticket, "--at", to });
    }

    /// `argv`, run for Your move item `id` through tmux: babylon's refusal is written beside its
    /// board, for the feed to say in place of the item's buttons.
    fn runNeed(app: *App, id: []const u8, argv: []const []const u8) !bool {
        return app.runWith(id, argv, false);
    }

    /// `runNeed`, and with `report` also a word on success, `ok`, for arena to read: the board's
    /// start closes it only then.
    fn runWith(app: *App, id: []const u8, argv: []const []const u8, report: bool) !bool {
        // a refusal under a next row stays only until the next key of either
        if (std.mem.startsWith(u8, id, "next:")) {
            var i: usize = app.refusals.items.len;
            while (i > 0) {
                i -= 1;
                const r = app.refusals.items[i];
                if (!std.mem.startsWith(u8, r.id, "next:")) continue;
                app.gpa.free(r.id);
                app.gpa.free(r.text);
                _ = app.refusals.orderedRemove(i);
            }
        }
        app.dropRefusal(id);
        if (report) app.clearStartRefusal();
        var buf: [std.fs.max_path_bytes]u8 = undefined;
        const path = app.refusalPath(id, &buf) orelse "/dev/null";
        var cmd: Writer.Allocating = .init(app.gpa);
        defer cmd.deinit();
        try cmd.writer.writeAll("out=$(");
        for (argv, 0..) |arg, i| {
            if (i > 0) try cmd.writer.writeAll(" ");
            try shellQuote(&cmd.writer, arg);
        }
        try cmd.writer.writeAll(" 2>&1)");
        if (std.mem.eql(u8, id, "report")) {
            try cmd.writer.writeAll(" && printf 'ok %s\\n' \"$out\" >");
            try shellQuote(&cmd.writer, path);
        } else if (report) {
            try cmd.writer.writeAll(" && printf ok >");
            try shellQuote(&cmd.writer, path);
        }
        try cmd.writer.writeAll(if (std.mem.eql(u8, id, "report")) " || printf 'no %s\\n' \"$out\" >" else " || printf '%s\\n' \"$out\" >");
        try shellQuote(&cmd.writer, path);
        // tmux reads the line as a format, in double quotes: # is ##, and \, " and $ escaped
        var line: Writer.Allocating = .init(app.gpa);
        defer line.deinit();
        for (cmd.written()) |c| switch (c) {
            '#' => try line.writer.writeAll("##"),
            '\n' => try line.writer.writeAll("\\n"),
            '\\', '"', '$' => try line.writer.print("\\{c}", .{c}),
            else => try line.writer.writeByte(c),
        };
        try app.send(.ignore, captured("{s}"), .{line.written()});
        app.dirty = true;
        return true;
    }

    /// Where babylon's refusal of Your move item `id` is written for arena to read.
    pub fn refusalPath(app: *const App, id: []const u8, buf: []u8) ?[]const u8 {
        const dir = app.board_dir orelse return null;
        return std.fmt.bufPrint(buf, "{s}/refused-{s}", .{ dir, id }) catch null;
    }

    /// A refusal read for Your move item `id`, said in its place until it is acted on again or
    /// leaves the feed.
    pub fn refuse(app: *App, id: []const u8, text: []const u8) !void {
        app.dropRefusal(id);
        const line = std.mem.trim(u8, text, " \n");
        const first = line[0 .. std.mem.indexOfScalar(u8, line, '\n') orelse line.len];
        var clean: std.ArrayList(u8) = .empty;
        errdefer clean.deinit(app.gpa);
        try @import("text.zig").appendClean(&clean, app.gpa, first);
        const owned_id = try app.gpa.dupe(u8, id);
        errdefer app.gpa.free(owned_id);
        try app.refusals.append(app.gpa, .{ .id = owned_id, .text = try clean.toOwnedSlice(app.gpa) });
        app.dirty = true;
    }

    /// babylon's answer to the board's start: `ok` closes the board, anything else is drawn on
    /// the card where its start button was.
    pub fn startAnswered(app: *App, text: []const u8) !void {
        const line = std.mem.trim(u8, text, " \n");
        if (std.mem.eql(u8, line, "ok")) return app.closeBoard();
        if (app.board_view == null) return;
        const first = line[0 .. std.mem.indexOfScalar(u8, line, '\n') orelse line.len];
        var clean: std.ArrayList(u8) = .empty;
        errdefer clean.deinit(app.gpa);
        try @import("text.zig").appendClean(&clean, app.gpa, first);
        if (clean.items.len == 0) try clean.appendSlice(app.gpa, "babylon refused to start it");
        app.clearStartRefusal();
        app.start_refused = try clean.toOwnedSlice(app.gpa);
        app.dirty = true;
    }

    /// babylon's answer to the report key's filing: `ok` and its words, or `no` and why.
    pub fn reportAnswered(app: *App, text: []const u8) !void {
        const line = std.mem.trim(u8, text, " \n");
        const failed = !(std.mem.eql(u8, line, "ok") or std.mem.startsWith(u8, line, "ok "));
        const body = if (failed) std.mem.trim(u8, line[@min(3, line.len)..], " \n") else std.mem.trim(u8, line[2..], " \n");
        const first = body[0 .. std.mem.indexOfScalar(u8, body, '\n') orelse body.len];
        var clean: std.ArrayList(u8) = .empty;
        errdefer clean.deinit(app.gpa);
        if (failed) {
            try @import("text.zig").appendClean(&clean, app.gpa, first);
            if (clean.items.len == 0) try clean.appendSlice(app.gpa, "babylon refused the report");
        } else if (std.mem.indexOfScalar(u8, first, '#')) |at| {
            var end = at + 1;
            while (end < first.len and std.ascii.isDigit(first[end])) end += 1;
            try clean.print(app.gpa, "filed {s}", .{first[at..end]});
        } else try clean.appendSlice(app.gpa, "filed");
        app.clearReportSaid();
        app.report_said = try clean.toOwnedSlice(app.gpa);
        app.report_failed = failed;
        app.dirty = true;
    }

    /// Says in the foot that arena was replaced by a new build, and which ticket's it was.
    pub fn updated(app: *App, ticket: ?u32, until: i64) !void {
        var said: [32]u8 = undefined;
        const line = if (ticket) |id|
            try std.fmt.bufPrint(&said, "arena updated · #{d}", .{id})
        else
            "arena updated";
        app.clearReportSaid();
        app.report_said = try app.gpa.dupe(u8, line);
        app.report_failed = false;
        app.report_until = until;
        app.dirty = true;
    }

    /// Whether nothing is half done that a restart would drop: no drag, no box or prompt over
    /// the screen.
    pub fn quiet(app: *const App) bool {
        if (app.drag != .none or app.menu != null or app.prompt != null) return false;
        if (app.board_view) |view| if (view.goal_open) return false;
        if (app.overview != null or app.popup != null) return false;
        return if (app.board_view) |view| !view.boxed() else true;
    }

    pub fn clearReportSaid(app: *App) void {
        const text = app.report_said orelse return;
        app.gpa.free(text);
        app.report_said = null;
        app.report_until = 0;
        app.dirty = true;
    }

    fn clearStartRefusal(app: *App) void {
        const text = app.start_refused orelse return;
        app.gpa.free(text);
        app.start_refused = null;
        app.dirty = true;
    }

    fn dropRefusal(app: *App, id: []const u8) void {
        var i: usize = 0;
        while (i < app.refusals.items.len) {
            const r = app.refusals.items[i];
            if (!std.mem.eql(u8, r.id, id)) {
                i += 1;
                continue;
            }
            app.gpa.free(r.id);
            app.gpa.free(r.text);
            _ = app.refusals.orderedRemove(i);
        }
    }

    /// The row of window `index` of `s` its panes start on: under its top edge, and in the
    /// orchestrator's own window beside the board, under the feed and its rule too.
    pub fn winTop(app: *const App, s: *const Session, index: usize) u16 {
        if (index != 0 or !s.orchestrator() or !app.sided()) return 1;
        var f: feed.Feed = undefined;
        return if (app.feedOf(&f)) @intCast(1 + f.height() + 1) else 1;
    }

    /// The orchestrator's own window: its session's first.
    pub fn orchestratorWindow(app: *const App) ?*Window {
        const at = app.orchestratorSession() orelse return null;
        const wins = app.sessions.items[at].wins.items;
        return if (wins.len > 0) wins[0] else null;
    }

    /// Whether it is drawn there, arena in its session.
    pub fn sideShown(app: *const App) bool {
        const s = app.cur() orelse return false;
        return app.sided() and s.orchestrator();
    }

    /// Whether arena is in its session once tmux has made the switches asked of it: what is typed
    /// goes by this, so none of it by where arena was while a switch is unanswered.
    fn sideDue(app: *const App) bool {
        const s = app.sessionById(app.bound()) orelse return false;
        return app.sided() and s.orchestrator();
    }

    /// Whether its column is the one focused: the keys and the mouse are then its own, as any
    /// window's.
    pub fn sideFocused(app: *const App) bool {
        const view = app.board_view orelse return false;
        return view.focus == .orchestrator and !view.boxed() and app.sideDue();
    }

    /// The width right of the rail, the strip's or the board's and its side's.
    pub fn fullW(app: *const App) u16 {
        const rail = app.railW();
        return app.term_w - if (rail > 0) rail + 1 else 0;
    }

    /// The board's left edge and width: right of the rail, and left of the side when it shows.
    pub fn boardX(app: *const App) u16 {
        return app.term_w - app.fullW();
    }

    pub fn boardW(app: *const App) u16 {
        return if (app.sided()) app.fullW() -| app.view_w -| 1 else app.view_w;
    }

    /// A new terminal size, with its cells' in pixels when the terminal says (0 when not):
    /// every strip is put in place again once tmux has been told.
    pub fn resized(app: *App, cols: u16, rows: u16, cell_w: u16, cell_h: u16) !void {
        app.term_w = cols;
        app.view_h = @max(1, rows -| 1);
        app.fit();
        // A tmux without the pixels patch refuses the second, and keeps the first.
        try app.send(.ignore, "refresh-client -C {d}x{d}", .{ cols, rows });
        if (cell_w > 0 and cell_h > 0)
            try app.send(.ignore, "refresh-client -C {d}x{d},{d}x{d}", .{ cols, rows, cell_w, cell_h });
        for (app.sessions.items) |s| s.placed = false;
        app.want_list = true;
    }

    pub fn requestList(app: *App) !void {
        app.want_list = false;
        app.listing = true;
        try app.send(.sessions, "list-sessions -F '" ++ session_format ++ "'", .{});
        try app.send(.panes, "list-panes -a -F '" ++ pane_format ++ "'", .{});
    }

    pub fn onLine(app: *App, line: []u8) !void {
        const event = control.parse(line, if (app.in_block) app.guard.items else null);
        switch (event) {
            .begin => |open| {
                app.in_block = true;
                app.block_mine = open.mine;
                app.guard.clearRetainingCapacity();
                try app.guard.appendSlice(app.gpa, open.guard);
                app.block.clearRetainingCapacity();
            },
            .body => |body| {
                try app.block.appendSlice(app.gpa, body);
                try app.block.append(app.gpa, '\n');
            },
            .end, .failed => {
                app.in_block = false;
                if (!app.block_mine) return;
                const kind: Pending = if (app.pending.items.len > 0) app.pending.orderedRemove(0) else .ignore;
                // tmux runs no more of a list once a command of it fails, as one on a pane
                // just gone does: what was asked of that pane after it gets no reply
                if (event == .failed) switch (kind) {
                    .modes, .capture => |id| while (app.pending.items.len > 0) {
                        const rest = switch (app.pending.items[0]) {
                            .capture, .cursor => |next| next == id,
                            else => false,
                        };
                        if (!rest) break;
                        _ = app.pending.orderedRemove(0);
                    },
                    else => {},
                };
                if (kind == .switched) return app.onSwitched(event == .failed);
                try app.onReply(kind, app.block.items);
            },
            .output => |out| {
                const pane = app.paneById(out.pane) orelse return;
                app.plain.clearRetainingCapacity();
                const before = app.out.items.len;
                try pane.pass.feed(app.gpa, control.unescape(@constCast(out.data)), &app.out, &app.plain);
                if (app.out.items.len > before) app.asker = pane.id;
                if (pane.seed != .done) return;
                pane.feed(app.plain.items);
                app.dirty = true;
            },
            .changed => app.want_list = true,
            .window_selected => |session| {
                if (session == app.current) app.follow_active = true;
                app.want_list = true;
            },
            .session_changed => |id| app.onSessionChanged(id),
            .card => |id| try app.showCard(id),
            .pane => |id| try app.showPane(id),
            .holder => |id| try app.showHolder(id),
            .inbox => try app.showInbox(),
            .exit => {
                app.ended = true;
                app.quit = true;
            },
            .other => {},
        }
    }

    /// The strip of the session left slides out as the new one slides in. The new session's
    /// panes are captured afresh: tmux sent arena none of their output while it was elsewhere.
    fn onSessionChanged(app: *App, id: u32) void {
        const from = app.current;
        app.current = id;
        // a report with switches still unanswered may be one on the way to the last asked for
        if (app.heading == id or app.switches == 0) app.heading = null;
        if (from != null and from != id and app.motion) {
            const way: i32 = if (app.slide != 0) app.slide else blk: {
                const a = app.sessionIndex(from) orelse 0;
                const b = app.sessionIndex(id) orelse 0;
                break :blk if (b >= a) 1 else -1;
            };
            app.prev = from;
            app.yoff = way * @as(i32, app.view_h);
        }
        app.slide = 0;
        if (app.sessionById(id)) |s| for (s.wins.items) |win| for (win.panes.items) |pane| {
            pane.seed = .wanted;
        };
        app.want_list = true;
        app.dirty = true;
    }

    fn onReply(app: *App, kind: Pending, body: []const u8) !void {
        switch (kind) {
            .ignore, .switched => {},
            .sessions => try app.onSessions(body),
            .panes => try app.onPanes(body),
            // What the program set before arena was watching, which no capture shows: without
            // these a running editor would get no mouse and draw outside the alternate screen.
            .modes => |id| {
                const pane = app.paneById(id) orelse return;
                var flags = std.mem.tokenizeAny(u8, body, " \n");
                for (&pane.modes) |*set| set.* = std.mem.eql(u8, flags.next() orelse "0", "1");
            },
            .capture => |id| {
                const pane = app.paneById(id) orelse return;
                pane.stream.nextSlice("\x1bc");
                for (pane.modes, mode_sets) |set, sequence| if (set) pane.stream.nextSlice(sequence);
                // Every row is kept, blank ones too: the last screenful has to land as the screen.
                var lines = std.mem.splitScalar(u8, body[0..body.len -| 1], '\n');
                var first = true;
                while (lines.next()) |line| {
                    if (!first) pane.stream.nextSlice("\r\n");
                    first = false;
                    pane.stream.nextSlice(line);
                }
                pane.stream.nextSlice("\x1b[0m");
                pane.seed = .done;
                app.dirty = true;
            },
            .cursor => |id| {
                const pane = app.paneById(id) orelse return;
                var it = std.mem.tokenizeAny(u8, body, " \n");
                const x = std.fmt.parseInt(u16, it.next() orelse return, 10) catch return;
                const y = std.fmt.parseInt(u16, it.next() orelse return, 10) catch return;
                var buf: [32]u8 = undefined;
                pane.stream.nextSlice(try std.fmt.bufPrint(&buf, "\x1b[{d};{d}H", .{ y + 1, x + 1 }));
                app.dirty = true;
            },
        }
    }

    fn onSessions(app: *App, body: []const u8) !void {
        var old = app.sessions;
        defer old.deinit(app.gpa);
        app.sessions = .empty;
        var lines = std.mem.tokenizeScalar(u8, body, '\n');
        while (lines.next()) |line| {
            const space = std.mem.indexOfScalar(u8, line, ' ') orelse continue;
            const id = std.fmt.parseInt(u32, line[1..space], 10) catch continue;
            const rest = line[space + 1 ..];
            const name = std.mem.indexOfScalar(u8, rest, ' ') orelse continue;
            // A place is read once: after that arena's own is the newer, and a list asked for
            // before a move would put the old one back.
            const s = for (old.items, 0..) |known, i| {
                if (known.id == id) break old.swapRemove(i);
            } else blk: {
                const made = try app.gpa.create(Session);
                made.* = .{ .id = id, .order = std.fmt.parseInt(u32, rest[0..name], 10) catch std.math.maxInt(u32) };
                break :blk made;
            };
            app.gpa.free(s.name);
            s.name = try app.gpa.dupe(u8, rest[name + 1 ..]);
            try app.sessions.append(app.gpa, s);
        }
        for (old.items) |s| app.destroySession(s);
        std.sort.insertion(*Session, app.sessions.items, {}, struct {
            fn before(_: void, a: *Session, b: *Session) bool {
                if (a.offRail() != b.offRail()) return b.offRail();
                // tmux lists sessions by name: with no place of their own, the oldest first
                return a.order < b.order or (a.order == b.order and a.id < b.id);
            }
        }.before);
        if (app.board_view) |*view| {
            const alone = app.orchestratorSession() == null;
            if (alone or app.sessionIndex(view.back) == null) view.back = null;
        }
        try app.toSide();
        if (app.orchestrating) if (app.orchestratorSession()) |at| {
            app.orchestrating = false;
            try app.sessionTo(at);
        };
    }

    /// Rebuilds every session's windows and panes from tmux's list, keeping the terminals of the
    /// panes that are still there.
    fn onPanes(app: *App, body: []const u8) !void {
        app.listing = false;
        var old_wins: std.ArrayList(*Window) = .empty;
        defer old_wins.deinit(app.gpa);
        var old_panes: std.ArrayList(*Pane) = .empty;
        defer old_panes.deinit(app.gpa);
        var focus_ids: std.ArrayList(?u32) = .empty;
        defer focus_ids.deinit(app.gpa);
        for (app.sessions.items) |s| {
            try focus_ids.append(app.gpa, if (s.focused()) |win| win.id else null);
            for (s.wins.items) |win| {
                try old_wins.append(app.gpa, win);
                try old_panes.appendSlice(app.gpa, win.panes.items);
                win.panes.clearRetainingCapacity();
            }
            s.wins.clearRetainingCapacity();
            s.focus = 0;
        }

        var lines = std.mem.tokenizeScalar(u8, body, '\n');
        while (lines.next()) |line| {
            var it = std.mem.tokenizeScalar(u8, line, ' ');
            var n: [23]u32 = undefined;
            for (&n, 0..) |*field, i| {
                const token = it.next() orelse break;
                field.* = std.fmt.parseInt(u32, token[@intFromBool(i < 3)..], 10) catch break;
            } else {
                const rest = it.rest();
                var tabs: usize = 0;
                const cut = for (rest, 0..) |c, i| {
                    tabs += @intFromBool(c == '\t');
                    if (tabs == std.enums.values(Window.Info).len) break i;
                } else rest.len;
                const info = rest[0..cut];
                const name = if (cut < rest.len) rest[cut + 1 ..] else "";
                const s = app.sessionById(n[0]) orelse continue;
                const last = s.wins.getLastOrNull();
                const win = if (last != null and last.?.id == n[1]) last.? else blk: {
                    const win = for (old_wins.items, 0..) |known, i| {
                        if (known.id == n[1]) {
                            known.was = known.claude;
                            break old_wins.swapRemove(i);
                        }
                    } else made: {
                        const made = try app.gpa.create(Window);
                        made.* = .{ .id = n[1] };
                        break :made made;
                    };
                    app.gpa.free(win.name);
                    win.name = try app.gpa.dupe(u8, name);
                    win.w = @intCast(n[3]);
                    win.h = @intCast(n[4]);
                    win.cell_w = @intCast(n[12]);
                    win.cell_h = @intCast(n[13]);
                    win.claude = .none;
                    win.review = .none;
                    win.stirring = false;
                    win.alert = @fromBackingInt(@intCast(@min(n[22], @backingInt(Alert.bell))));
                    try win.know(app.gpa, 0, 0, 0, 0, 0, "");
                    // Read once: after that arena's own is the newer, and a list asked for
                    // before a change would put the old one back.
                    if (!win.listed) win.share = @intCast(@min(n[14], max_share));
                    win.listed = true;
                    if (n[10] == 1) s.focus = s.wins.items.len;
                    try s.wins.append(app.gpa, win);
                    break :blk win;
                };
                const pane = for (old_panes.items, 0..) |known, i| {
                    if (known.id == n[2]) break old_panes.swapRemove(i);
                } else try Pane.create(app, n[2], @intCast(n[7]), @intCast(n[8]));
                pane.x = @intCast(n[5]);
                pane.y = @intCast(n[6]);
                const said: Mark = @fromBackingInt(@intCast(@min(n[11], @backingInt(Mark.stalled))));
                // between turns with a subagent of its at work is working: only a shell left running is not
                const stirring = n[21] != 0 and app.epoch - n[21] < stir_s;
                if (stirring) win.stirring = true;
                const claude: Mark = if (said == .background and stirring) .working else said;
                const agent = n[16] != 0 or claude != .none;
                if (agent and (!win.agent() or @backingInt(claude) > @backingInt(win.claude))) {
                    try win.know(app.gpa, n[16], n[17], n[18], n[19], n[20], info);
                    win.agent_pane = n[2];
                }
                if (@backingInt(claude) > @backingInt(win.claude)) win.claude = claude;
                const review = Review.of(n[15]);
                if (@backingInt(review) > @backingInt(win.review)) win.review = review;
                // tmux wraps a pane's history again at its new width; the copy here, fed in as
                // rows, cannot, so it is taken afresh.
                if (pane.term.cols != n[7] or pane.term.rows != n[8]) {
                    try pane.term.resize(app.gpa, .{ .cols = @intCast(@max(1, n[7])), .rows = @intCast(@max(1, n[8])) });
                    pane.seed = .wanted;
                }
                if (n[9] == 1) win.active = win.panes.items.len;
                try win.panes.append(app.gpa, pane);
            }
        }
        for (old_panes.items) |pane| pane.destroy(app.gpa);
        try app.tellColors();
        for (old_wins.items) |win| win.destroy(app.gpa);

        for (app.sessions.items, 0..) |s, i| {
            const follow = app.follow_active and s.id == app.current;
            if (!follow and i < focus_ids.items.len) if (focus_ids.items[i]) |id| for (s.wins.items, 0..) |win, at| {
                if (win.id == id) s.focus = at;
            };
            if (!s.placed) s.scroll = app.target(s);
            s.placed = true;
        }
        try app.notify();
        app.follow_active = false;
        if (app.cur()) |s| try app.see(s);
        try app.settle();
        if (app.cur()) |s| app.listed = app.listed or s.wins.items.len > 0;
        app.dirty = true;
    }

    /// A desktop notification for each Claude come to wait on an answer or done since the list
    /// before, other than the one in view: notify-send, where there is one, run by tmux, which
    /// quotes the hook's text for the shell itself.
    fn notify(app: *App) !void {
        for (app.sessions.items) |s| for (s.wins.items) |win| {
            const was = win.was orelse continue;
            if (win.claude == was or (win.claude != .waiting and win.claude != .done and win.claude != .stalled)) continue;
            if (s.id == app.current and s.focused() == win) continue;
            try app.send(.ignore, "run-shell -b -t %{d} \"command -v notify-send >/dev/null && notify-send -a arena -- " ++
                "#{{?@arena_claude_title,#{{q:@arena_claude_title}},#{{q:window_name}}}} {s}\"", .{
                win.agent_pane,
                if (win.claude == .waiting) "#{q:@arena_claude_doing}" else "#{q:@arena_claude_said}",
            });
        };
    }

    /// The cells of each window's tab on the row under the strip: its number, a space, its name
    /// cut to `tab_name`, a space and a cell for its mark. Empty past `max_tabs` windows.
    pub fn tabWidths(s: *const Session, out: *[max_tabs]usize) []const usize {
        if (s.wins.items.len > max_tabs) return &.{};
        for (s.wins.items, 0..) |win, i| {
            const name = std.unicode.utf8CountCodepoints(win.name) catch win.name.len;
            out[i] = std.fmt.count("{d}", .{i + 1}) + 1 + @min(name, tab_name) + 2;
        }
        return out[0..s.wins.items.len];
    }

    /// Asks tmux to size the current session's windows to their columns, and for the screen of
    /// every pane not yet captured. A window just asked to change size is captured after tmux
    /// reports the new layout, at the size it will be drawn.
    fn settle(app: *App) !void {
        for (app.sessions.items) |s| {
            for (s.wins.items, 0..) |win, i| {
                const rows = @max(1, app.view_h -| 1 -| app.winTop(s, i));
                const cols = @max(1, app.colW(s, win) -| 2);
                const fits = win.w == cols and win.h == rows;
                const asked = win.asked_w == cols and win.asked_h == rows;
                if (s.id == app.current and !fits and !asked) {
                    win.asked_w = cols;
                    win.asked_h = rows;
                    try app.send(.ignore, "refresh-client -C @{d}:{d}x{d}", .{ win.id, cols, rows });
                    continue;
                }
                for (win.panes.items) |pane| {
                    if (pane.seed != .wanted) continue;
                    pane.seed = .asked;
                    // One list, which tmux runs without reading the pane between: output it read
                    // between the capture and the cursor would be drawn here at the wrong place.
                    try app.send(.{ .modes = pane.id }, "display-message -p -t %{d} '" ++ mode_flags ++ "' ; " ++
                        "capture-pane -p -e -S -{d} -t %{d} ; " ++
                        "display-message -p -t %{d} '#{{cursor_x}} #{{cursor_y}}'", .{ pane.id, history_lines, pane.id, pane.id });
                    try app.pending.append(app.gpa, .{ .capture = pane.id });
                    try app.pending.append(app.gpa, .{ .cursor = pane.id });
                }
            }
        }
    }

    fn sessionBy(app: *App, delta: i32) !void {
        const at = app.sessionIndex(app.current) orelse return;
        const next = @as(i32, @intCast(at)) + delta;
        if (next < 0 or next >= app.railSessions()) return;
        try app.sessionTo(@intCast(next));
    }

    fn sessionTo(app: *App, index: usize) !void {
        app.orchestrating = false;
        const to = app.sessions.items[index];
        if (to.id == app.bound()) return;
        if (app.sessionById(app.bound())) |from| try app.see(from);
        app.slide = if (index > app.sessionIndex(app.bound()) orelse index) 1 else -1;
        try app.switchTo(to.id);
    }

    fn switchTo(app: *App, id: u32) !void {
        app.heading = id;
        app.switches += 1;
        try app.send(.switched, "switch-client -t '${d}'", .{id});
    }

    /// tmux answered a switch. Answered in order, the last answers the session last asked for:
    /// refused, arena is going nowhere.
    fn onSwitched(app: *App, refused: bool) void {
        app.switches -|= 1;
        if (refused and app.switches == 0) app.heading = null;
    }

    /// The session arena is in once tmux has done what it was asked: the one it last asked for
    /// while that is still there, else the one tmux last said.
    fn bound(app: *const App) ?u32 {
        if (app.heading) |id| if (app.sessionIndex(id) != null) return id;
        return app.current;
    }

    /// A step along the strip of the session arena is bound for: typed while a switch is
    /// unanswered, it is not lost, nor made in the session being left.
    fn focusBy(app: *App, delta: i32) !void {
        const s = app.sessionById(app.bound()) orelse return;
        const next = @as(i32, @intCast(s.focus)) + delta;
        if (next < 0 or next >= s.wins.items.len) return;
        try app.focusIn(s, @intCast(next));
    }

    /// To a window of the session shown, which is where a click's index is from.
    fn focusTo(app: *App, index: usize) !void {
        const s = app.cur() orelse return;
        try app.focusIn(s, index);
    }

    fn focusIn(app: *App, s: *Session, index: usize) !void {
        app.orchestrating = false;
        try app.see(s);
        s.focus = index;
        try app.send(.ignore, "select-window -t @{d}", .{s.wins.items[index].id});
        app.dirty = true;
    }

    const Name = union(enum) { window: u32, session: u32, pane: u32 };

    /// What ends a word picked by two clicks.
    const word_ends = [_]u21{ ' ', '\t', '\'', '"', '`', '|', '│', ':', ';', ',', '(', ')', '[', ']', '{', '}', '<', '>', '$' };

    /// Puts the pane's selected text on the system clipboard and the primary selection, through
    /// the terminal.
    fn copy(app: *App, pane: *Pane) !void {
        const screen = pane.term.screens.active;
        const sel = screen.selection orelse return;
        const text = try screen.selectionString(app.gpa, .{ .sel = sel, .trim = true });
        defer app.gpa.free(text);
        if (text.len == 0) return;
        const encoder = std.base64.standard.Encoder;
        for ([_][]const u8{ "\x1b]52;c;", "\x1b]52;p;" }) |intro| {
            try app.out.appendSlice(app.gpa, intro);
            _ = encoder.encode(try app.out.addManyAsSlice(app.gpa, encoder.calcSize(text.len)), text);
            try app.out.append(app.gpa, 0x07);
        }
    }

    /// Opens the search prompt. Anything selected is let go, so the search starts from the newest.
    fn openSearch(app: *App) void {
        if (app.searchPane()) |pane| pane.term.screens.active.clearSelection();
        app.prompt = .{ .what = .search };
        app.dirty = true;
    }

    /// The pane a search looks in: the popup's, else the focused window's active one.
    fn searchPane(app: *App) ?*Pane {
        if (app.popup != null) return app.popupPane();
        const s = app.cur() orelse return null;
        return (s.focused() orelse return null).activePane();
    }

    /// Finds the prompt's text in the active pane's history, the match before the one last
    /// found, selects it and brings it into view. Past the oldest it starts again from the newest.
    fn searchNext(app: *App) !void {
        const prompt = &app.prompt.?;
        const pane = app.searchPane() orelse return;
        const query = prompt.text();
        if (query.len == 0) return;
        const screen = pane.term.screens.active;
        const bottom = screen.pages.pin(.{ .active = .{ .x = 0, .y = pane.term.rows - 1 } }) orelse return;
        var passes: u2 = if (screen.selection == null) 1 else 2;
        var at: ?vt.Pin = if (screen.selection) |sel| sel.start().up(1) else bottom;
        var buf: [1024]u8 = undefined;
        while (passes > 0) : ({
            passes -= 1;
            at = bottom;
        }) {
            while (at) |pin| : (at = pin.up(1)) {
                var row: Writer = .fixed(&buf);
                var whole = pin;
                whole.x = 0;
                const last = pane.term.cols - 1;
                var row_end = whole;
                row_end.x = last;
                screen.dumpString(&row, .{ .tl = whole, .br = row_end, .unwrap = false }) catch {};
                const text = row.buffered();
                const found = std.ascii.findIgnoreCase(text, query) orelse continue;
                var start = whole;
                start.x = @intCast(@min(last, std.unicode.utf8CountCodepoints(text[0..found]) catch found));
                var end = whole;
                end.x = @intCast(@min(last, start.x + (std.unicode.utf8CountCodepoints(query) catch query.len) - 1));
                try screen.select(vt.Selection.init(start, end, false));
                if (screen.pages.pointFromPin(.screen, whole)) |point| {
                    // near the top, clear of the prompt in the middle
                    pane.term.scrollViewport(.{ .row = point.coord().y -| 2 });
                }
                prompt.missed = false;
                return;
            }
        }
        prompt.missed = true;
    }

    /// A window by where it is: which session of the list, which window of the session.
    pub const Spot = struct { session: usize, win: usize };

    /// The outer size of a window's picture in the overview.
    pub const thumb_w = 26;
    pub const thumb_h = 7;

    /// The row a session's name is on in the overview, its windows' pictures in the rows under
    /// it; null when it is off the screen. As many sessions show as fit, the picked one among them.
    pub fn overviewRow(app: *const App, session: usize) ?u16 {
        const spot = app.overview orelse return null;
        const block = thumb_h + 1;
        const shown: usize = @max(1, app.view_h / block);
        const first = if (spot.session >= shown) spot.session - shown + 1 else 0;
        if (session < first or session >= first + shown or session >= app.railSessions()) return null;
        return @intCast((session - first) * block);
    }

    /// The top left corner of a window's picture in the overview; null when it is off the screen.
    pub fn thumbAt(app: *const App, at: Spot) ?struct { x: u16, y: u16 } {
        const spot = app.overview orelse return null;
        const row = app.overviewRow(at.session) orelse return null;
        const stride = thumb_w + 1;
        const across: usize = @max(1, (app.view_w + 1) / stride);
        const first = if (at.session == spot.session and spot.win >= across) spot.win - across + 1 else 0;
        if (at.win < first or at.win >= first + across) return null;
        return .{ .x = @intCast(app.term_w - app.view_w + (at.win - first) * stride), .y = row + 1 };
    }

    /// Opens the overview on the window in view. The other sessions' panes are captured again,
    /// so their pictures are of now and not of when arena was last there.
    fn openOverview(app: *App) void {
        const at = app.sessionIndex(app.current) orelse return;
        app.overview = .{ .session = at, .win = app.sessions.items[at].focus };
        for (app.sessions.items) |s| {
            if (s.id == app.current) continue;
            for (s.wins.items) |win| for (win.panes.items) |pane| {
                if (pane.seed == .done) pane.seed = .wanted;
            };
        }
        app.want_list = true;
        app.dirty = true;
    }

    /// A key in the overview: h, j, k, l and the arrows move, Enter goes to the window picked,
    /// Escape and q close.
    fn overviewKey(app: *App, key: []const u8) !void {
        app.dirty = true;
        const count = app.railSessions();
        if (count == 0) {
            app.overview = null;
            return;
        }
        const spot = &app.overview.?;
        spot.session = @min(spot.session, count - 1);
        const is = anyKey;
        if (is(key, &.{ "h", "\x1b[D", "\x1bOD" })) spot.win -|= 1;
        if (is(key, &.{ "l", "\x1b[C", "\x1bOC" })) spot.win += 1;
        if (is(key, &.{ "k", "\x1b[A", "\x1bOA" })) spot.session -|= 1;
        if (is(key, &.{ "j", "\x1b[B", "\x1bOB" }) and spot.session + 1 < count) spot.session += 1;
        const s = app.sessions.items[spot.session];
        spot.win = @min(spot.win, s.wins.items.len -| 1);
        if (is(key, &.{ "\x1b", "q" })) app.overview = null;
        if (is(key, &.{"\r"}) and s.wins.items.len > 0) {
            const win = spot.win;
            app.overview = null;
            try app.jumpTo(s, win);
        }
    }

    /// The board file's text as read now: the board it holds takes the place of the one before;
    /// there is none when there is no file or it does not parse.
    pub fn setBoard(app: *App, text: ?[]const u8) !void {
        if (app.board) |*b| b.deinit();
        app.board = if (text) |t| tickets.Board.parse(app.gpa, t) catch null else null;
        if (app.board == null) try app.closeBoard();
        app.settleAuto();
        // the feed's height may change, and the orchestrator's window with it
        app.want_list = true;
        // a refusal goes with its item
        var i: usize = 0;
        while (i < app.refusals.items.len) {
            const r = app.refusals.items[i];
            const needs = if (app.board) |*b| b.needsYou() else &.{};
            const present = for (needs) |need| {
                if (std.mem.eql(u8, need.id, r.id)) break true;
            } else false;
            if (present) {
                i += 1;
                continue;
            }
            app.gpa.free(r.id);
            app.gpa.free(r.text);
            _ = app.refusals.orderedRemove(i);
        }
        if (app.board_view) |*view| {
            var repos: [max_repos + 1][]const u8 = undefined;
            view.lane = @min(view.lane, app.laneRepos(&repos) -| 1);
        }
        app.dirty = true;
    }

    fn toggleBoard(app: *App) !void {
        app.orchestrating = false;
        app.dirty = true;
        if (app.board_view != null) return app.closeBoard();
        if (app.board == null) return;
        app.board_view = .{ .lane = app.firstLane() };
        try app.toSide();
    }

    /// The board opened on ticket `id`, over whatever had the keys, with its question shown
    /// when it asks one: what `arena board <id>` asks for. A ticket the board shows nowhere, a
    /// done one older than its repo's last few or one babylon has none of, opens the board as
    /// Alt+b does with what babylon says of it over it; with no board there is nothing to open.
    pub fn showCard(app: *App, id: u32) !void {
        if (app.board == null) return;
        app.menu = null;
        app.prompt = null;
        app.overview = null;
        app.orchestrating = false;
        app.dirty = true;
        if (app.board_view == null) app.board_view = .{};
        const view = &app.board_view.?;
        view.focus = .board;
        view.help = false;
        view.detail = null;
        view.giving = null;
        const picked = app.pickCard(id);
        view.answering = picked and app.boardCard(view.col, view.row).?.ask != null;
        if (!picked) _ = try app.openDetail(id);
        try app.toSide();
    }

    /// Ticket `id`'s whole detail asked of babylon and shown over the open board. False with
    /// nowhere for babylon to write it.
    fn openDetail(app: *App, id: u32) !bool {
        return app.openText(id, "detail", false);
    }

    /// Ticket `id`'s gate run, the run in progress's when it has one, in the modal frame.
    fn openGate(app: *App, id: u32) !void {
        _ = try app.openText(id, "gate", true);
    }

    /// The gate's modal on the run in progress, or the gate's session while none shows one.
    fn gateModal(app: *App) !void {
        var runs: [1]*const tickets.Card = undefined;
        const b = if (app.board) |*b| b else return;
        if (b.running(&runs) > 0) return app.openGate(runs[0].id);
        try app.toGate();
    }

    fn openText(app: *App, id: u32, comptime cmd: []const u8, gate: bool) !bool {
        var buf: [std.fs.max_path_bytes]u8 = undefined;
        const path = app.detailPath(id, &buf) orelse return false;
        const view = &app.board_view.?;
        // tmux gives a control client run-shell's output outside its reply, so it comes by a file
        std.Io.Dir.cwd().deleteFile(app.io, path) catch {};
        if (app.detail_asked.items.len == 16) _ = app.detail_asked.orderedRemove(0);
        try app.detail_asked.append(app.gpa, id);
        view.detail = id;
        view.detail_scroll = 0;
        view.ask_pick = 1;
        view.check_pick = 1;
        view.gate = gate;
        view.withdrawing = false;
        app.detail.clearRetainingCapacity();
        try app.send(.ignore, "run-shell -b \"babylon " ++ cmd ++ " {d} >'{s}.part' 2>&1; mv '{s}.part' '{s}'\"", .{ id, path, path, path });
        return true;
    }

    /// The open board's pick put on ticket `id`: in the every view where it shows there, else
    /// in its repo's own columns, else in the backlog. False when the board shows it nowhere,
    /// the board then as it opens.
    fn pickCard(app: *App, id: u32) bool {
        const view = &app.board_view.?;
        var repos: [max_repos][]const u8 = undefined;
        const n = if (app.board) |*b| b.repos(&repos) else 0;
        for (0..n + 2) |narrowed| {
            view.backlog = narrowed == n + 1;
            view.repo = if (view.backlog) 0 else narrowed;
            var lanes: [max_repos + 1][]const u8 = undefined;
            for (0..if (app.boardLanes()) app.laneRepos(&lanes) else 1) |lane| {
                view.lane = lane;
                for (0..app.boardCols()) |col| {
                    var out: [max_cards]*const tickets.Card = undefined;
                    const shown = @min(app.boardColumn(col, &out), max_cards);
                    for (out[0..shown], 0..) |card, row| if (card.id == id) {
                        view.col = col;
                        view.row = row;
                        return true;
                    };
                }
            }
        }
        view.backlog = false;
        view.repo = 0;
        view.col = 0;
        view.row = 0;
        view.lane = app.firstLane();
        return false;
    }

    /// The board put away, and the side with it, back in the session the human was in.
    fn closeBoard(app: *App) !void {
        const view = app.board_view orelse return;
        app.board_view = null;
        app.find_len = 0;
        app.clearStartRefusal();
        app.dirty = true;
        app.reflow();
        if (view.back) |id| try app.switchTo(id);
    }

    /// With the board open, the orchestrator running and the side not folded, arena goes to the
    /// orchestrator's session, to have its window live beside the board.
    fn toSide(app: *App) !void {
        app.reflow();
        if (!app.sided()) return;
        const view = &app.board_view.?;
        const to = app.sessions.items[app.orchestratorSession() orelse return].id;
        const from = app.bound();
        if (from == to) return;
        if (view.back == null) view.back = from;
        try app.switchTo(to);
    }

    /// The strip's width as it is now, and where it changed the windows sized again to it, once
    /// tmux has listed them.
    fn reflow(app: *App) void {
        const was = app.view_w;
        app.fit();
        if (app.view_w == was) return;
        for (app.sessions.items) |s| s.placed = false;
        app.want_list = true;
        app.dirty = true;
    }

    /// The repo the open board is narrowed to; null for every one.
    pub fn boardRepo(app: *const App) ?[]const u8 {
        const view = app.board_view orelse return null;
        if (view.repo == 0 or view.backlog) return null;
        const b = if (app.board) |*b| b else return null;
        var repos: [max_repos][]const u8 = undefined;
        const n = b.repos(&repos);
        return if (view.repo <= n) repos[view.repo - 1] else null;
    }

    /// The rows the card's detail takes in its box.
    pub fn detailRows(app: *const App) usize {
        const inner = detailWidth(app.boardW()).inner;
        if (app.board_view) |view| if (view.gate) return gateOutputRows(gateOutput(gateLastRun(app.detail.items)), inner);
        var n: usize = 0;
        var lines = DetailLines.init(if (app.detail.items.len > 0) app.detail.items else "…", inner);
        while (lines.next()) |_| n += 1;
        if (app.modalCard()) |card| if (card.stage_note.len > 0) {
            var note = DetailLines.init(card.stage_note, inner);
            while (note.next()) |_| n += 1;
        };
        return n;
    }

    /// Where babylon writes ticket `id`'s detail for the board to read.
    pub fn detailPath(app: *const App, id: u32, buf: []u8) ?[]const u8 {
        const dir = app.board_dir orelse return null;
        return std.fmt.bufPrint(buf, "{s}/detail-{d}.txt", .{ dir, id }) catch null;
    }

    /// The cards of the board's column `col` as it is narrowed, as many as fit in `out`; the
    /// count of those it shows.
    pub fn boardColumn(app: *const App, col: usize, out: []*const tickets.Card) usize {
        const b = if (app.board) |*b| b else return 0;
        if (app.footStrip(col)) return app.stripPicks(out);
        if (app.boardBacklog()) {
            var n: usize = 0;
            for (b.backlog()) |*card| if (card.finds(app.findText())) {
                if (n < out.len) out[n] = card;
                n += 1;
            };
            return n;
        }
        if (app.boardLanes()) if (app.pickRepo()) |repo| if (app.folded(repo)) return 0;
        return app.shownIn(tickets.statuses[col], app.pickRepo(), app.columnOf(tickets.statuses[col], app.pickRepo(), app.findText(), out));
    }

    /// What the board's cards are narrowed to: what is being typed after `/`, else what Enter kept.
    pub fn findText(app: *const App) []const u8 {
        if (app.prompt) |*prompt| if (prompt.what == .find) return prompt.text();
        return app.find[0..app.find_len];
    }

    /// The count of every card in the board's column `col` as it is narrowed, shown or not.
    pub fn boardColumnAll(app: *const App, col: usize) usize {
        if (app.boardBacklog()) return app.boardColumn(col, &.{});
        return app.columnOf(tickets.statuses[col], app.pickRepo(), app.findText(), &.{});
    }

    /// Done shows its last few closed, the first in its column, and then how many more it has.
    pub const done_shown = 3;

    /// Of `total` cards in `status`'s column of `repo`, how many are shown: in done, every `try`
    /// card, pinned above the capped recent ones.
    pub fn shownIn(app: *const App, status: tickets.Status, repo: ?[]const u8, total: usize) usize {
        if (status != .done) return total;
        const tries = app.columnOf(.@"try", repo, app.findText(), &.{});
        return @min(total, tries + @as(usize, if (app.workbench()) strip_n else done_shown));
    }

    /// The cards in column `col` of lane `lane`: those shown, and all of them.
    pub fn laneCounts(app: *const App, lane: usize, col: usize) struct { shown: usize, total: usize } {
        if (app.footStrip(col)) {
            const n = if (lane == app.pickLane()) app.stripPicks(&.{}) else 0;
            return .{ .shown = n, .total = n };
        }
        const repo = app.laneRepo(lane) orelse return .{ .shown = 0, .total = 0 };
        const total = app.columnOf(tickets.statuses[col], repo, app.findText(), &.{});
        const shown = if (app.folded(repo)) 0 else app.shownIn(tickets.statuses[col], repo, total);
        return .{ .shown = shown, .total = total };
    }

    /// Whether the open board is the every view, a lane a repo, not one repo's columns.
    pub fn boardLanes(app: *const App) bool {
        const view = app.board_view orelse return false;
        return view.repo == 0 and !view.backlog;
    }

    /// The repos the every view has a lane for, those with a card to do, doing or in review, in
    /// order of name, then "" for such cards of none.
    pub fn laneRepos(app: *const App, out: *[max_repos + 1][]const u8) usize {
        const b = if (app.board) |*b| b else return 0;
        const n = @min(out.len, b.lanes().len);
        @memcpy(out[0..n], b.lanes()[0..n]);
        return n;
    }

    /// The cards to do, doing or in review on tab `i`: every repo's, or one's. The backlog's
    /// own count is its cards'.
    pub fn tabCount(app: *const App, i: usize) usize {
        const b = if (app.board) |*b| b else return 0;
        var repos: [max_repos][]const u8 = undefined;
        const n = b.repos(&repos);
        if (i > n) return 0;
        const repo: ?[]const u8 = if (i == 0) null else repos[i - 1];
        return app.columnOf(.todo, repo, "", &.{}) + app.columnOf(.doing, repo, "", &.{}) + app.columnOf(.review, repo, "", &.{});
    }

    /// Whether `repo`'s group is folded to its heading.
    pub fn folded(app: *const App, repo: []const u8) bool {
        for (0..app.fold_n) |i| if (std.mem.eql(u8, app.folds[i][0..app.fold_lens[i]], repo)) return true;
        return false;
    }

    fn setFold(app: *App, repo: []const u8, on: bool) void {
        if (repo.len > app.folds[0].len) return;
        for (0..app.fold_n) |i| if (std.mem.eql(u8, app.folds[i][0..app.fold_lens[i]], repo)) {
            if (!on) {
                app.folds[i] = app.folds[app.fold_n - 1];
                app.fold_lens[i] = app.fold_lens[app.fold_n - 1];
                app.fold_n -= 1;
            }
            return;
        };
        if (!on or app.fold_n == max_repos) return;
        @memcpy(app.folds[app.fold_n][0..repo.len], repo);
        app.fold_lens[app.fold_n] = @intCast(repo.len);
        app.fold_n += 1;
    }

    /// The folds read from the file's lines, one repo each.
    pub fn loadFolds(app: *App, text: []const u8) void {
        var lines = std.mem.splitScalar(u8, text, '\n');
        while (lines.next()) |line| if (line.len > 0) app.setFold(line, true);
    }

    fn saveFolds(app: *App) !void {
        const path = app.folds_path orelse return;
        var data: Writer.Allocating = .init(app.gpa);
        defer data.deinit();
        for (0..app.fold_n) |i| try data.writer.print("{s}\n", .{app.folds[i][0..app.fold_lens[i]]});
        if (std.fs.path.dirname(path)) |dir| std.Io.Dir.cwd().createDirPath(app.io, dir) catch return;
        std.Io.Dir.cwd().writeFile(app.io, .{ .sub_path = path, .data = data.written() }) catch {};
    }

    /// A repo's group folded, or unfolded, in every column; the pick moves off a folded group.
    pub fn toggleRepoFold(app: *App, repo: []const u8) !void {
        app.setFold(repo, !app.folded(repo));
        app.dirty = true;
        app.settleLane();
        try app.saveFolds();
    }

    /// Every group but `keep`'s folded; with any folded, all unfolded instead.
    fn focusFold(app: *App, keep: []const u8) !void {
        if (app.fold_n > 0) {
            app.fold_n = 0;
        } else {
            var repos: [max_repos + 1][]const u8 = undefined;
            for (repos[0..app.laneRepos(&repos)]) |repo| if (!std.mem.eql(u8, repo, keep)) app.setFold(repo, true);
        }
        app.dirty = true;
        app.settleLane();
        try app.saveFolds();
    }

    /// Whether lane `lane`'s group holds a card the human must decide: an ask or a proposal.
    pub fn laneNeeds(app: *const App, lane: usize) bool {
        const repo = app.laneRepo(lane) orelse return false;
        var out: [max_cards]*const tickets.Card = undefined;
        for ([_]tickets.Status{ .todo, .doing, .review }) |status| {
            const n = @min(app.columnOf(status, repo, "", &out), max_cards);
            for (out[0..n]) |card| if (card.ask != null or card.proposal != null) return true;
        }
        return false;
    }

    /// The pick moved, when its group has no card shown in its column, to the first that has.
    fn settleLane(app: *App) void {
        const view = &(app.board_view orelse return);
        if (!app.boardLanes()) return;
        var repos: [max_repos + 1][]const u8 = undefined;
        const lanes = app.laneRepos(&repos);
        if (app.laneCounts(view.lane, view.col).shown > 0) return;
        for (0..lanes) |k| {
            if (app.laneCounts(k, view.col).shown == 0) continue;
            view.lane = k;
            view.row = 0;
            break;
        }
    }

    pub fn laneRepo(app: *const App, lane: usize) ?[]const u8 {
        var repos: [max_repos + 1][]const u8 = undefined;
        const n = app.laneRepos(&repos);
        return if (lane < n) repos[lane] else null;
    }

    /// The groups a column's cards are in: a repo's each in the every view, by its place among
    /// `laneRepos`, else the one of what the board is narrowed to.
    fn groupCount(app: *const App) usize {
        if (!app.boardLanes()) return 1;
        var repos: [max_repos + 1][]const u8 = undefined;
        return app.laneRepos(&repos);
    }

    /// The cards of group `lane` in column `col`: those shown, and all of them.
    pub fn groupCounts(app: *const App, lane: usize, col: usize) struct { shown: usize, total: usize } {
        if (app.boardLanes()) {
            const n = app.laneCounts(lane, col);
            return .{ .shown = n.shown, .total = n.total };
        }
        return .{ .shown = @min(app.boardColumn(col, &.{}), max_cards), .total = app.boardColumnAll(col) };
    }

    /// Card `row` of group `lane` in column `col`.
    pub fn groupCard(app: *const App, lane: usize, col: usize, row: usize) ?*const tickets.Card {
        return if (app.boardLanes()) app.laneCard(lane, col, row) else app.boardCard(col, row);
    }

    /// A line of a column, counted from its first: a repo's heading in the every view, row `part`
    /// of card `row`, or the line under a group's last saying how many more it has.
    pub const ColumnLine = struct {
        lane: usize,
        what: union(enum) { heading, card: struct { row: usize, part: usize }, more },
    };

    /// A column's lines from its first, each card as many as it is tall.
    pub const ColumnLines = struct {
        app: *const App,
        col: usize,
        groups: usize,
        lane: usize = 0,
        headed: bool = false,
        row: usize = 0,
        part: usize = 0,

        pub fn init(app: *const App, col: usize) ColumnLines {
            return .{ .app = app, .col = col, .groups = app.groupCount() };
        }

        pub fn next(it: *ColumnLines) ?ColumnLine {
            while (it.lane < it.groups) {
                const n = it.app.groupCounts(it.lane, it.col);
                if (n.total > 0 and !it.headed) {
                    it.headed = true;
                    if (it.app.boardLanes()) return .{ .lane = it.lane, .what = .heading };
                }
                if (it.row < n.shown) {
                    const line: ColumnLine = .{ .lane = it.lane, .what = .{ .card = .{ .row = it.row, .part = it.part } } };
                    it.part += 1;
                    if (it.part >= it.app.cardHeight(it.lane, it.col, it.row)) {
                        it.part = 0;
                        it.row += 1;
                    }
                    return line;
                }
                const hidden = it.app.boardLanes() and it.app.folded(it.app.laneRepo(it.lane) orelse "");
                const more = it.row == n.shown and n.total > n.shown and !hidden;
                it.row += 1;
                if (more) return .{ .lane = it.lane, .what = .more };
                it.lane += 1;
                it.headed = false;
                it.row = 0;
            }
            return null;
        }
    };

    pub fn columnLineAt(app: *const App, col: usize, line: usize) ?ColumnLine {
        var lines = ColumnLines.init(app, col);
        for (0..line) |_| _ = lines.next() orelse return null;
        return lines.next();
    }

    /// The line of column `col` card `row` of group `lane` starts on.
    pub fn cardStart(app: *const App, col: usize, lane: usize, row: usize) ?usize {
        var lines = ColumnLines.init(app, col);
        var at: usize = 0;
        while (lines.next()) |line| : (at += 1) switch (line.what) {
            .card => |card| if (line.lane == lane and card.row == row and card.part == 0) return at,
            else => {},
        };
        return null;
    }

    /// The line of column `col` on its first row inside its border: the picked card's column is
    /// scrolled to keep it in view down to its bottom edge, or its top when it is taller than
    /// the column.
    pub fn columnScroll(app: *const App, col: usize) usize {
        const view = app.board_view orelse return 0;
        if (col != view.col) return 0;
        const lane = app.pickLane();
        const top = app.cardStart(col, lane, view.row) orelse return 0;
        const bottom = top + app.cardHeight(lane, col, view.row) -| 1;
        const rows = @max(1, app.listH() -| (app.colTop() + 1));
        return if (bottom >= rows) @min(top, bottom - rows + 1) else 0;
    }

    /// The group the pick is in: its repo's in the every view, else the one.
    fn pickLane(app: *const App) usize {
        return if (app.boardLanes()) app.board_view.?.lane else 0;
    }

    /// Card `row` of column `col` in lane `lane`.
    pub fn laneCard(app: *const App, lane: usize, col: usize, row: usize) ?*const tickets.Card {
        if (app.footStrip(col)) return app.boardCard(col, row);
        const repo = app.laneRepo(lane) orelse return null;
        var out: [max_cards]*const tickets.Card = undefined;
        const n = app.shownIn(tickets.statuses[col], repo, app.columnOf(tickets.statuses[col], repo, app.findText(), &out));
        return if (row < @min(n, max_cards)) out[row] else null;
    }

    /// The lane the every view opens on: the first with a card in its first column.
    fn firstLane(app: *const App) usize {
        var repos: [max_repos + 1][]const u8 = undefined;
        for (0..app.laneRepos(&repos)) |k| if (app.laneCard(k, 0, 0) != null) return k;
        return 0;
    }

    /// The repo the pick moves within: the one the board is narrowed to, or in the every view
    /// the picked lane's.
    pub fn pickRepo(app: *const App) ?[]const u8 {
        if (!app.boardLanes()) return app.boardRepo();
        return app.laneRepo(app.board_view.?.lane);
    }

    pub fn boardBacklog(app: *const App) bool {
        const view = app.board_view orelse return false;
        return view.backlog;
    }

    /// The columns the open board shows: the four statuses, or the backlog alone.
    pub fn boardCols(app: *const App) usize {
        return if (app.boardBacklog()) 1 else tickets.statuses.len;
    }

    /// What the board's epic bars come to: none outside Workbench, in the backlog, with no goals or
    /// with too little room, else a title row, a bar row and a blank one.
    pub fn epicRows(app: *const App) u16 {
        const b = if (app.board) |*b| b else return 0;
        const plan = b.plan() orelse return 0;
        if (plan.goals.len == 0 or !app.workbench() or app.boardBacklog() or app.view_h < first_line + epic_rows + foot_rows + 6) return 0;
        return epic_rows;
    }

    pub const epic_rows: u16 = 3;

    /// The epics the board draws as bars, as many as the width holds side by side.
    pub fn epicBars(app: *const App) []const tickets.Goal {
        if (app.epicRows() == 0) return &.{};
        const goals = app.board.?.plan().?.goals;
        return goals[0..@max(1, @min(goals.len, (app.boardW() -| 2 + epic_gap) / (epic_min_w + epic_gap)))];
    }

    pub const epic_gap = 2;
    pub const epic_min_w = 24;

    /// `Board.column` on this board: an epic is left out only while its bar is drawn.
    pub fn columnOf(app: *const App, status: tickets.Status, repo: ?[]const u8, find: []const u8, out: []*const tickets.Card) usize {
        const b = if (app.board) |*b| b else return 0;
        return b.columnBars(status, repo, find, app.epicBars(), out);
    }

    /// The row the board's columns start at: under the epic bars, when it has them.
    pub fn colTop(app: *const App) u16 {
        return first_line + app.epicRows();
    }

    /// The cards in `status` on the whole board, whatever repo it is narrowed to, that the find
    /// holds; an epic is no work for a Claude, so it is not counted.
    pub fn boardCount(app: *const App, status: tickets.Status) usize {
        const b = if (app.board) |*b| b else return 0;
        return b.work(status, app.findText());
    }

    /// The cards in `status` on the whole board, epics not counted: the rail's chip, which no find narrows.
    pub fn railCount(app: *const App, status: tickets.Status) usize {
        const b = if (app.board) |*b| b else return 0;
        return b.work(status, "");
    }

    pub fn boardCard(app: *const App, col: usize, row: usize) ?*const tickets.Card {
        var out: [max_cards]*const tickets.Card = undefined;
        const n = app.boardColumn(col, &out);
        return if (row < @min(n, max_cards)) out[row] else null;
    }

    /// The board's columns side by side under a row of its own; in each, cards stacked from the
    /// second row inside its border.
    pub fn boardColW(app: *const App, col: usize) u16 {
        var widths: [tickets.statuses.len]u16 = undefined;
        app.boardWidths(&widths);
        return widths[col];
    }

    /// Width goes to what has cards: an empty column is as narrow as its heading, done takes
    /// `recent_w`, doing and review a share each by their cards, and todo the rest, the most.
    fn boardWidths(app: *const App, out: *[tickets.statuses.len]u16) void {
        const room = app.boardW();
        if (app.boardBacklog()) {
            out[0] = room;
            return;
        }
        var counts: [tickets.statuses.len]usize = undefined;
        var left = room;
        for (tickets.statuses, 0..) |status, c| {
            counts[c] = if (app.boardLanes()) app.boardCount(status) else app.boardColumnAll(c);
            out[c] = if (status == .done and app.footRows() > 0) 0 else if (counts[c] == 0) app.emptyColWidth(c) else if (status == .done) @min(recent_w, room / 4) else 0;
            left -|= out[c];
        }
        const sum = counts[0] + counts[1] + counts[2];
        if (sum == 0) {
            out[0] += left;
            return;
        }
        var rest = left;
        for (1..3) |c| if (counts[c] > 0) {
            const share: u16 = @intCast(left * counts[c] / sum);
            out[c] = if (counts[0] > 0) std.math.clamp(share, left / 4, left / 3) else share;
            rest -= out[c];
        };
        out[if (counts[0] > 0) 0 else if (counts[2] > 0) 2 else 1] += rest;
    }

    pub const recent_w = 40;

    /// An empty column's width: its heading, ` name 0 `, in its border, and todo's + beside it; a
    /// Workbench window's bar has its stripes, count badge and box.
    fn emptyColWidth(app: *const App, col: usize) u16 {
        const name = app.columnName(col);
        if (app.workbench()) return @intCast(cellCount(name) + 12 + @as(usize, if (col == 0) 8 else 0));
        return @intCast(cellCount(name) + 4 + 3 + @as(usize, if (col == 0) 4 else 0));
    }

    /// What column `col` is headed: its status, recent for the every view's strip, or backlog.
    pub fn columnName(app: *const App, col: usize) []const u8 {
        if (app.boardBacklog()) return "backlog";
        return if (app.boardStrip(col)) "recent" else @tagName(tickets.statuses[col]);
    }

    pub fn boardColX(app: *const App, col: usize) u16 {
        var x = app.boardX();
        for (0..col) |c| x += app.boardColW(c);
        return x;
    }

    /// Whether column `col` is the every view's strip of what each repo closed last: done, a
    /// card a row with no box.
    pub fn boardStrip(app: *const App, col: usize) bool {
        return (app.boardLanes() or app.footRows() > 0) and tickets.statuses[col] == .done;
    }

    /// Whether the board is drawn in Workbench's look, which has geometry of its own.
    pub fn workbench(app: *const App) bool {
        return app.roles != null;
    }

    /// Rows of Workbench's recent strip along the board's foot: its title bar, the timeline, the
    /// labels and the picked one's button.
    pub const foot_rows: u16 = 4;

    /// How many of the last closed the strip shows.
    pub const strip_n = tickets.Board.recent_n;

    /// The rows the recent strip takes: none outside Workbench, in the backlog, or with no room.
    pub fn footRows(app: *const App) u16 {
        if (!app.workbench() or app.boardBacklog() or app.view_h < app.colTop() + foot_rows + 6) return 0;
        return foot_rows;
    }

    /// The row after the last the columns' windows take: their shadow is on the one before.
    pub fn listH(app: *const App) u16 {
        return app.view_h - app.footRows() - app.barRows();
    }

    /// The board's last row is its key bar in Workbench's look, when there is room for the columns above it.
    pub fn barRows(app: *const App) u16 {
        return if (app.workbench() and app.view_h >= first_line + 8) 1 else 0;
    }

    /// A key of the board's foot bar, where it is drawn and clicked: 0-based, as the mouse has it.
    pub const BarKey = struct {
        what: union(enum) { card: CardAction, key: []const u8 },
        key: []const u8,
        word: []const u8,
        x: u16,
        /// A rule is drawn before it: it starts a group.
        group: bool,

        pub fn width(k: BarKey) u16 {
            return @intCast(cellCount(k.key) + cellCount(k.word) + 3);
        }

        pub fn hit(k: BarKey, app: *const App, x: u16, y: u16) bool {
            return y == app.view_h - 1 and x >= k.x and x < k.x + k.width();
        }
    };

    /// Below this many cells the bar keeps fewer keys.
    const bar_full_w = 110;

    /// The foot bar's keys, in three groups: the picked card's, the board's, and `?` with `esc`.
    /// Half width keeps `⏎ start  space open  G give  e edit │ + new  / find │ ? keys`. None
    /// while a word of babylon's is said in the bar's place.
    pub fn keyBar(app: *const App, out: []BarKey) []BarKey {
        if (app.barRows() == 0 or (app.report_said != null and !app.feedFocused())) return out[0..0];
        const view = app.board_view orelse return out[0..0];
        const full = app.boardW() >= bar_full_w;
        const Item = struct { what: @FieldType(BarKey, "what"), key: []const u8, word: []const u8, group: u8 };
        var items: [24]Item = undefined;
        var m: usize = 0;
        if (app.boardCard(view.col, view.row)) |card| {
            var have: [12]CardAction = undefined;
            const actions = cardActions(card, &have);
            const order = [_]CardAction{ .go, .open, .no, .answer, .give, .handoff, .edit, .priority, .close, .reopen, .to_todo, .up, .down, .to_next };
            for (order) |action| {
                const there = action == .open or std.mem.indexOfScalar(CardAction, actions, action) != null;
                const wanted = full or action == .go or action == .open or action == .give or action == .edit;
                if (there and wanted) {
                    items[m] = .{ .what = .{ .card = action }, .key = action.key(), .word = cardWord(card, action), .group = 0 };
                    m += 1;
                }
            }
        }
        const board = [_]struct { []const u8, []const u8, bool }{
            .{ "+", "new", true },   .{ "r", "repo", false }, .{ "/", "find", true },
            .{ "A", "auto", false }, .{ "o", "orch", false }, .{ "g", "gate", false },
        };
        for (board) |pair| if (full or pair[2]) {
            items[m] = .{ .what = .{ .key = pair[0] }, .key = pair[0], .word = pair[1], .group = 1 };
            m += 1;
        };
        items[m] = .{ .what = .{ .key = "?" }, .key = "?", .word = if (full) "all keys" else "keys", .group = 2 };
        m += 1;
        if (full) {
            items[m] = .{ .what = .{ .key = "\x1b" }, .key = "esc", .word = "close", .group = 2 };
            m += 1;
        }
        const right = app.boardX() + app.boardW();
        var x = app.boardX() + 1;
        var n: usize = 0;
        for (items[0..m], 0..) |item, i| {
            const group = i > 0 and items[i - 1].group != item.group;
            const k: BarKey = .{ .what = item.what, .key = item.key, .word = item.word, .x = x + @as(u16, if (group) 3 else 1), .group = group };
            if (k.x + k.width() > right or n == out.len) break;
            out[n] = k;
            n += 1;
            x = k.x + k.width();
        }
        return out[0..n];
    }

    /// The word a card's key says on the board: a free card's `⏎` starts it, a review card's
    /// `space` is its log.
    fn cardWord(card: *const tickets.Card, action: CardAction) []const u8 {
        return switch (action) {
            .go => if (card.proposal == null and card.holder() == null) "start" else action.label(),
            .open => if (card.status == .review) "log" else action.label(),
            else => action.label(),
        };
    }

    /// The cards the recent strip shows, the last closed first.
    pub fn stripCards(app: *const App, out: *[strip_n]*const tickets.Card) usize {
        var all: [max_cards]*const tickets.Card = undefined;
        const n = @min(app.columnOf(.done, app.boardRepo(), app.findText(), &all), strip_n);
        @memcpy(out[0..n], all[0..n]);
        return n;
    }

    /// Whether column `col` is the recent strip drawn along the board's foot, from `stripCards`,
    /// not as lanes of its own.
    fn footStrip(app: *const App, col: usize) bool {
        return app.footRows() > 0 and app.boardStrip(col);
    }

    /// The strip's entries as the pick has them: by their place among those drawn, whatever lane
    /// they are in; the count of those drawn, as many as fit in `out` copied.
    fn stripPicks(app: *const App, out: []*const tickets.Card) usize {
        var cards: [strip_n]*const tickets.Card = undefined;
        const n = app.stripCards(&cards);
        const m = @min(n, out.len);
        @memcpy(out[0..m], cards[0..m]);
        return n;
    }

    /// The width of one of the strip's entries.
    pub fn stripCell(app: *const App) u16 {
        return app.boardW() / strip_n;
    }

    /// Where the pick of card `card` is in column `col`, that column's own rows or, in the every
    /// view, its repo's lane.
    fn spotOf(app: *const App, col: usize, id: u32) ?CardAt {
        if (app.footStrip(col)) {
            var out: [strip_n]*const tickets.Card = undefined;
            const n = app.stripPicks(&out);
            for (out[0..n], 0..) |card, row| if (card.id == id) return .{ .lane = app.pickLane(), .col = col, .row = row };
            return null;
        }
        if (!app.boardLanes()) {
            var out: [max_cards]*const tickets.Card = undefined;
            const n = @min(app.boardColumn(col, &out), max_cards);
            for (out[0..n], 0..) |card, row| if (card.id == id) return .{ .lane = 0, .col = col, .row = row };
            return null;
        }
        var repos: [max_repos + 1][]const u8 = undefined;
        for (0..app.laneRepos(&repos)) |lane| {
            var row: usize = 0;
            while (app.laneCard(lane, col, row)) |card| : (row += 1) {
                if (card.id == id) return .{ .lane = lane, .col = col, .row = row };
            }
        }
        return null;
    }

    /// The card of the strip under (`x`, `y`), where the strip is drawn.
    fn stripCardAt(app: *const App, x: u16, y: u16) ?CardAt {
        const foot = app.footRows();
        if (foot == 0 or y <= app.listH() or y + 1 >= app.view_h -| app.barRows() or x < app.boardX()) return null;
        const k = (x - app.boardX()) / @max(1, app.stripCell());
        var cards: [strip_n]*const tickets.Card = undefined;
        if (k >= app.stripCards(&cards)) return null;
        const done = for (tickets.statuses, 0..) |status, c| {
            if (status == .done) break c;
        } else return null;
        return app.spotOf(done, cards[k].id);
    }

    /// Whether card `row` of group `lane` in column `col` is the one picked.
    pub fn cardPicked(app: *const App, lane: usize, col: usize, row: usize) bool {
        const view = app.board_view orelse return false;
        return col == view.col and row == view.row and lane == app.pickLane();
    }

    /// The rows card `row` of group `lane` takes in column `col`: one in the strip; else its
    /// title's, `title_rows` at most unless picked, a last row when it has something to say, and
    /// the picked one's top and bottom edges.
    pub fn cardHeight(app: *const App, lane: usize, col: usize, row: usize) usize {
        if (app.boardStrip(col)) return 1;
        const card = app.groupCard(lane, col, row) orelse return 1;
        var buf: [160]u8 = undefined;
        if (app.workbench()) {
            var tile = TitleLines.init(card.title, tileTextW(app.boardColW(col)));
            var rows: usize = 0;
            while (tile.next()) |_| rows += 1;
            return @max(1, @min(rows, tile_title_rows)) + @as(usize, if (app.cardPicked(lane, col, row)) 4 else 3);
        }
        var lines = TitleLines.init(cardTitle(card, &buf), cardTextW(app.boardColW(col)));
        var n: usize = 0;
        while (lines.next()) |_| n += 1;
        const last = @intFromBool(cardHasLast(card, app.cardRepoShown()));
        return if (app.cardPicked(lane, col, row)) n + last + 4 else @max(1, @min(n, title_rows) + last);
    }

    pub const title_rows = 4;

    /// A Workbench tile's title takes two rows at most, the picked one's too.
    pub const tile_title_rows = 2;

    /// The cells a Workbench tile's title has in a column `w` wide: its window's and its own
    /// gutters, a cell of the tile's, and the priority dot's.
    pub fn tileTextW(w: u16) usize {
        return w -| 7;
    }

    /// The cells a card's text has in a column `w` wide: the column's edges, the card's left mark
    /// and a space, and a cell after.
    pub fn cardTextW(w: u16) usize {
        return w -| 5;
    }

    pub fn cardTitle(card: *const tickets.Card, buf: []u8) []const u8 {
        return std.fmt.bufPrint(buf, "#{d} {s}", .{ card.id, card.title }) catch card.title;
    }

    /// Whether a card says its repo: in the backlog, where no heading or tab does.
    pub fn cardRepoShown(app: *const App) bool {
        return !app.boardLanes() and app.boardRepo() == null;
    }

    /// Whether a card has a last row, something to say past its title: a proposal, a question,
    /// where the pipeline has it, who holds it, what it waits on, and the rest of what is so of it.
    pub fn cardHasLast(card: *const tickets.Card, with_repo: bool) bool {
        return card.proposal != null or card.ask != null or card.stage != null or
            (card.status != .review and (card.holder() != null or card.status == .doing)) or
            with_repo or card.blocked_by.len > 0 or std.mem.eql(u8, card.kind, "epic") or
            (card.status == .todo and card.model != null) or
            (card.status == .done and card.session_note.len > 0) or card.handed_off_from != null or
            card.waiting_on != null;
    }

    pub const CardAt = struct { lane: usize, col: usize, row: usize };

    /// The group whose heading is at cell (`x`, `y`), in the every view.
    fn headingAt(app: *const App, x: u16, y: u16) ?usize {
        if (!app.boardLanes() or x < app.boardColX(0) or y < app.colTop() or y + 1 >= app.listH()) return null;
        const col = for (0..app.boardCols()) |c| {
            if (x < app.boardColX(c) + app.boardColW(c)) break c;
        } else return null;
        if (app.boardColW(col) == 0 or app.footStrip(col)) return null;
        const at = app.columnLineAt(col, y - app.colTop() + app.columnScroll(col)) orelse return null;
        return if (at.what == .heading) at.lane else null;
    }

    fn boardCardAt(app: *const App, x: u16, y: u16) ?CardAt {
        if (app.stripCardAt(x, y)) |at| return at;
        const left = app.boardColX(0);
        if (x < left or y < app.colTop() or y + 1 >= app.listH()) return null;
        const col = for (0..app.boardCols()) |c| {
            if (x < app.boardColX(c) + app.boardColW(c)) break c;
        } else return null;
        if (app.boardColW(col) == 0) return null;
        const at = app.columnLineAt(col, y - app.colTop() + app.columnScroll(col)) orelse return null;
        return switch (at.what) {
            .card => |card| .{ .lane = at.lane, .col = col, .row = card.row },
            else => null,
        };
    }

    /// The window with pane `id` in it, and that window's place in its session.
    pub fn paneWindow(app: *const App, id: u32) ?struct { session: *Session, index: usize } {
        for (app.sessions.items) |s| for (s.wins.items, 0..) |win, wi| for (win.panes.items) |pane| {
            if (pane.id == id) return .{ .session = s, .index = wi };
        };
        return null;
    }

    /// Goes to the Claude holding the card picked, closing the board; nothing when none does.
    fn goCard(app: *App) !void {
        const view = app.board_view orelse return;
        const card = app.boardCard(view.col, view.row) orelse return;
        const pane = card.holder() orelse {
            if (!givable(card)) return;
            // babylon refuses what it will not start and says why; the board closes when it does
            var id_buf: [12]u8 = undefined;
            _ = try app.runWith("start", &.{ "babylon", "start", std.fmt.bufPrint(&id_buf, "{d}", .{card.id}) catch return }, true);
            return;
        };
        try app.showPane(pane);
    }

    /// Pane `id` put in front, its session and window as needed, closing the board; nothing
    /// when tmux has no such pane.
    pub fn showPane(app: *App, id: u32) !void {
        const at = app.paneWindow(id) orelse return;
        try app.closeBoard();
        try app.send(.ignore, "select-pane -t %{d}", .{id});
        try app.jumpTo(at.session, at.index);
    }

    /// The pane of the Claude holding ticket `id` put in front; nothing when none does.
    pub fn showHolder(app: *App, id: u32) !void {
        const b = if (app.board) |*b| b else return;
        for (b.cards()) |*card| if (card.id == id) {
            if (card.holder()) |pane| try app.showPane(pane);
            return;
        };
    }

    /// Home: the board with the orchestrator's column beside it, which has the keys, in insert.
    /// With no board there is none.
    pub fn goHome(app: *App) !void {
        if (app.board == null) return;
        app.menu = null;
        app.prompt = null;
        app.overview = null;
        app.orchestrating = false;
        app.normal = false;
        app.dirty = true;
        if (app.board_view == null) app.board_view = .{ .lane = app.firstLane() };
        const view = &app.board_view.?;
        view.help = false;
        view.detail = null;
        view.giving = null;
        view.answering = false;
        app.side_folded = false;
        view.home = true;
        view.plan = app.hasPlan();
        view.alone = true;
        view.focus = .orchestrator;
        app.reflow();
        try app.toSide();
    }

    /// The board, from anywhere in normal mode: where home's plan goes to find, read or move a
    /// ticket. With no board there is none.
    pub fn toBoard(app: *App) !void {
        if (app.board == null) return;
        app.menu = null;
        app.prompt = null;
        app.overview = null;
        app.orchestrating = false;
        app.normal = false;
        app.dirty = true;
        if (app.board_view == null) app.board_view = .{ .lane = app.firstLane() };
        const view = &app.board_view.?;
        view.help = false;
        view.detail = null;
        view.giving = null;
        view.answering = false;
        view.plan = false;
        view.alone = false;
        view.focus = .board;
        app.reflow();
        try app.toSide();
    }

    /// Whether babylon's file carries a plan.
    pub fn hasPlan(app: *const App) bool {
        return if (app.board) |*b| b.plan() != null else false;
    }

    /// Whether home draws the plan, in the board's place.
    pub fn planShown(app: *const App) bool {
        const view = app.board_view orelse return false;
        return view.plan and app.hasPlan();
    }

    /// The plan laid out in rows for the board's width, less the cell the pick bar takes; false
    /// when it is not shown.
    pub fn planSheet(app: *const App, sheet: *sheets.Sheet) bool {
        if (!app.planShown()) return false;
        const b = &app.board.?;
        sheet.build(b.plan().?, b, app.boardW() -| 1, app.epoch, app.board_view.?.unfolded, app.halfHome(), app.workbench());
        return true;
    }

    /// The first of the plan's rows that is drawn: the row picked kept in view, two rows more
    /// below it.
    pub fn planTop(app: *const App, sheet: *const sheets.Sheet) usize {
        const view = app.board_view orelse return 0;
        const at = sheet.rowOf(view.plan_pick) orelse return 0;
        return (at + 3) -| (app.view_h -| 2 -| @intFromBool(app.halfHome()));
    }

    pub const plan_tab = "b plan";
    pub const board_tab = "B board";
    pub const tab_sep = " · ";
    /// The first row's left end on the plan and on the board alike: the same pair of tabs.
    pub const tabs_title = " " ++ plan_tab ++ tab_sep ++ board_tab;
    pub const plan_title = tabs_title;
    pub const orch_link = "o orchestrator";

    /// Where the plan tab is drawn and clicked, on the plan and on the board.
    pub fn planTab(app: *const App) struct { x: u16, w: u16 } {
        return .{ .x = app.boardX() + 1, .w = @intCast(cellCount(plan_tab)) };
    }

    /// Where the board tab is drawn and clicked, on the plan and on the board.
    pub fn planLink(app: *const App) struct { x: u16, w: u16 } {
        return .{ .x = app.boardX() + 1 + @as(u16, @intCast(cellCount(plan_tab) + cellCount(tab_sep))), .w = @intCast(cellCount(board_tab)) };
    }

    /// Where the head's `o orchestrator` is drawn and clicked, at half a screen.
    pub fn orchLink(app: *const App) struct { x: u16, w: u16 } {
        return .{ .x = app.boardX() + @as(u16, @intCast(cellCount(plan_title))) + 2, .w = @intCast(cellCount(orch_link)) };
    }

    /// A key on the plan, while it has the keys: `j` `k` pick through every row; Enter goes, and
    /// space or `t` opens the ticket; `B` is the board. What the board's keys do to a card is not
    /// the plan's, the card under them being out of sight.
    fn planKey(app: *App, key: []const u8) !void {
        const view = &app.board_view.?;
        const is = anyKey;
        var sheet: sheets.Sheet = undefined;
        if (!app.planSheet(&sheet)) return;
        view.plan_pick = @min(view.plan_pick, sheet.picks -| 1);
        if (is(key, &.{ "j", "\x1b[B", "\x1bOB" })) view.plan_pick = @min(view.plan_pick + 1, sheet.picks -| 1);
        if (is(key, &.{ "k", "\x1b[A", "\x1bOA" })) view.plan_pick -|= 1;
        if (is(key, &.{"?"})) view.help = true;
        if (is(key, &.{"+"})) return app.openGoal();
        if (is(key, &.{"B"})) return app.toBoard();
        if (is(key, &.{ "J", "K", "x", "e" })) {
            const row = sheet.picked(view.plan_pick) orelse return;
            if (row.kind != .next) return;
            const b = &app.board.?;
            for (b.next(), 0..) |item, at| {
                if (item.ticket != row.ticket.?) continue;
                if (is(key, &.{"e"})) _ = app.openWhy(item.ticket, item.why) else _ = try app.nextKey(at, &view.plan_pick, key);
                break;
            }
            return;
        }
        if (is(key, &.{ "\r", " ", "t" })) {
            const row = sheet.picked(view.plan_pick) orelse return;
            return app.planAct(row, key);
        }
        if (is(key, &.{ "\x1b", "q" })) return app.closeBoard();
        if (is(key, &.{"`"})) return app.foldSide();
        if (is(key, &.{"g"})) return app.toGate();
        if (is(key, &.{"o"})) return if (app.halfHome()) app.swapHome(true) else app.toOrchestrator();
        if (is(key, &.{"A"})) return app.openAuto();
        if (is(key, &.{"P"})) return app.jumpProposed();
        if (is(key, &.{ "]", "[" })) return app.toFeed(key, null);
        if (is(key, &.{ "l", "\x1b[C", "\x1bOC" }) and app.sided()) {
            view.focus = .orchestrator;
            if (app.sideDue()) app.normal = true;
        }
    }

    /// What a key does on a row of the plan. Space and `t` open its ticket's whole detail. Enter
    /// goes: to the Claude building it, or with none and nothing moving it, starts one; to the
    /// gate for a ticket in the pipeline; unfolds a folded row; starts a ticket of next now;
    /// and from a goal, landed or not planned, to the board on it.
    fn planAct(app: *App, row: *const sheets.Row, key: []const u8) !void {
        const view = &app.board_view.?;
        const given = app.board.?.plan().?;
        app.dirty = true;
        if (!std.mem.eql(u8, key, "\r")) {
            if (row.ticket) |id| _ = try app.openDetail(id);
            return;
        }
        switch (row.kind) {
            .folded => if (row.fold) |bit| {
                view.unfolded ^= @as(u8, 1) << bit;
            },
            .now => {
                const id = row.ticket orelse return;
                const item = for (given.now) |item| {
                    if (item.ticket == id) break item;
                } else return;
                const pane = if (item.holder()) |held| (if (app.paneWindow(held) != null) held else null) else null;
                if (pane) |held| return app.showPane(held);
                if (item.stalled != null) return app.send(.ignore, captured("babylon start {d}"), .{id});
                if (!std.mem.eql(u8, item.state, "building")) try app.toGate();
            },
            .next => if (row.ticket) |id| try app.send(.ignore, captured("babylon start {d}"), .{id}),
            .goals_more => try app.toBoard(),
            .goal, .focal => {
                try app.toBoard();
                for (given.goals) |goal| {
                    if (goal.epic != row.ticket) continue;
                    for (goal.steps) |step| {
                        if (std.mem.eql(u8, step.state, "landed")) continue;
                        _ = app.pickCard(step.ticket);
                        return;
                    }
                }
            },
            .landed, .unplanned => {
                try app.toBoard();
                const bv = &app.board_view.?;
                bv.repo = 0;
                bv.backlog = false;
                bv.row = 0;
                bv.lane = app.firstLane();
                bv.col = if (row.kind == .landed) @min(3, app.boardCols() -| 1) else 0;
            },
            else => {},
        }
    }

    /// A left click on the plan: on the head's `B board` the board, on a row its pick, and on
    /// the row picked already what Enter does.
    fn planClick(app: *App, m: keys.Mouse) !void {
        const view = &app.board_view.?;
        if (m.y == 0) {
            const link = app.planLink();
            if (m.x >= link.x and m.x < link.x + link.w) try app.toBoard();
            const orch = app.orchLink();
            if (app.halfHome() and m.x >= orch.x and m.x < orch.x + orch.w) try app.swapHome(true);
            return;
        }
        var sheet: sheets.Sheet = undefined;
        if (m.y < 2 or !app.planSheet(&sheet)) return;
        const at = app.planTop(&sheet) + (m.y - 2);
        if (at >= sheet.n) return;
        const row = sheet.rows[at];
        const head = app.goalHead();
        if (row.kind == .head and app.workbench() and std.mem.eql(u8, row.text, "goals") and m.x >= head.x and m.x < head.x + head.w) return app.openGoal();
        const pick = row.pick orelse return;
        const picked = view.plan_pick == pick;
        view.plan_pick = pick;
        if (row.kind == .next) app.drag = .{ .next_row = .{ .from = nextPlace(&sheet, at), .opens = picked } } else if (picked) try app.planAct(&row, "\r");
    }

    /// The place (from 0) in next of the next row at `at` of the sheet.
    fn nextPlace(sheet: *const sheets.Sheet, at: usize) usize {
        var place: usize = 0;
        for (sheet.rows[0..at]) |row| place += @intFromBool(row.kind == .next);
        return place;
    }

    /// The held button moved to `m`, or let go, with a row of next in it: let go on another row
    /// of next it takes that place, through babylon as the human; let go where it was pressed it
    /// goes, as a click on the picked row does.
    fn dragNextRow(app: *App, m: keys.Mouse) !void {
        const held = &app.drag.next_row;
        app.dirty = true;
        if (!m.release and m.motion() and !m.hover()) {
            held.moved = true;
            return;
        }
        const row = held.*;
        app.drag = .none;
        if (!m.release) return;
        var sheet: sheets.Sheet = undefined;
        if (m.y < 2 or !app.planSheet(&sheet)) return;
        const at = app.planTop(&sheet) + (m.y - 2);
        if (at >= sheet.n or sheet.rows[at].kind != .next) return;
        const to = nextPlace(&sheet, at);
        if (to == row.from) {
            if (row.opens and !row.moved) try app.planAct(&sheet.rows[at], "\r");
            return;
        }
        if (row.from >= app.board.?.next().len) return;
        const view = &app.board_view.?;
        view.plan_pick = sheet.rows[at].pick orelse return;
        var id: [12]u8 = undefined;
        var place: [12]u8 = undefined;
        var said: [24]u8 = undefined;
        const moved = app.board.?.next()[row.from].ticket;
        const number = std.fmt.bufPrint(&id, "{d}", .{moved}) catch return;
        const here = std.fmt.bufPrint(&place, "{d}", .{to + 1}) catch return;
        const refusal = std.fmt.bufPrint(&said, "next:{d}", .{moved}) catch return;
        _ = try app.runNeed(refusal, &.{ "babylon", "next", number, "--at", here });
    }

    /// The needs-you inbox: home, the feed atop its column.
    pub fn showInbox(app: *App) !void {
        try app.goHome();
    }

    /// What home keeps across tmux ending arena's client, as when the orchestrator's session the
    /// client was in ends: the board as it was, and the column's fold.
    pub const Kept = struct { view: BoardView, folded: bool };

    pub fn kept(app: *const App) ?Kept {
        var view = app.board_view orelse return null;
        view.help = false;
        view.detail = null;
        view.giving = null;
        view.answering = false;
        return .{ .view = view, .folded = app.side_folded };
    }

    /// Home as it was kept, in the new client's sessions.
    pub fn restore(app: *App, was: Kept) !void {
        if (app.board == null) return;
        app.board_view = was.view;
        app.side_folded = was.folded;
        app.dirty = true;
        try app.toSide();
    }

    /// A key while the column has the keys with no window of the orchestrator's in it: Enter
    /// starts it when it is off, h gives the board the keys, and Escape and q close the board.
    fn columnKey(app: *App, key: []const u8) !void {
        const view = &app.board_view.?;
        if (anyKey(key, &.{ "\x1b", "q" })) return app.closeBoard();
        if (anyKey(key, &.{ "h", "\x1b[D", "\x1bOD" })) view.focus = .board;
        if (anyKey(key, &.{"B"})) return app.toBoard();
        if (anyKey(key, &.{"A"})) return app.openAuto();
        if (anyKey(key, &.{"\r"}) and app.orchestratorState() == .off) {
            return app.send(.ignore, captured("babylon orchestrator"), .{});
        }
        if (try app.halfKey(key)) return;
        _ = try app.feedKey(key);
    }

    /// `]` or `[` from the board: the column's feed takes the keys, in normal mode, with the pick
    /// on Your move's first item or its last, or on the one of `ticket` when it has one.
    fn toFeed(app: *App, key: []const u8, ticket: ?u32) !void {
        const view = &app.board_view.?;
        if (!app.sided()) return;
        view.focus = .orchestrator;
        if (app.sideDue()) app.normal = true;
        app.dirty = true;
        var f: feed.Feed = undefined;
        if (!app.feedOf(&f) or f.items_shown == 0) return;
        view.pick = if (anyKey(key, &.{"["})) f.items_shown - 1 else 0;
        if (ticket) |id| for (0..f.items_shown) |i| if (f.item(i).?.ticket == id) {
            view.pick = i;
            break;
        };
        if (f.item(view.pick).?.ticket) |id| {
            _ = app.pickCard(id);
            app.pickPlan(id);
        }
    }

    /// A key on the board: h, l and the arrows go between columns, j and k along one, r narrows
    /// it to the next repo and from the last back to every one, Enter goes to the Claude holding
    /// the card picked or starts one on a free todo card, Escape and q close.
    fn boardKey(app: *App, key: []const u8) !void {
        app.clearStartRefusal();
        app.dirty = true;
        const view = &app.board_view.?;
        const is = anyKey;
        if (view.goal_open) return app.goalKey(key);
        if (view.auto_pick != null) return app.autoKey(key);
        if (view.answering) return app.answerKey(key);
        if (view.giving != null) return app.giveKey(key);
        if (view.help) {
            view.help = false;
            return;
        }
        if (view.detail != null) return app.modalKey(key);
        if (app.columnFocused()) return app.columnKey(key);
        if (app.planShown()) return app.planKey(key);
        if (is(key, &.{"b"}) and app.hasPlan()) return app.goHome();
        if (is(key, &.{" "})) if (app.boardCard(view.col, view.row)) |card| {
            if (try app.openDetail(card.id)) return;
        };
        if (is(key, &.{"?"})) {
            view.help = true;
            return;
        }
        if (is(key, &.{"a"})) return app.act(.answer);
        if (is(key, &.{ "h", "\x1b[D", "\x1bOD" })) view.col -|= 1;
        if (is(key, &.{ "l", "\x1b[C", "\x1bOC" }) and view.col + 1 < app.boardCols()) view.col += 1;
        const up = is(key, &.{ "k", "\x1b[A", "\x1bOA" });
        const down = is(key, &.{ "j", "\x1b[B", "\x1bOB" });
        if (app.boardLanes()) {
            // off a repo's group the pick goes on to the next with a card in the same column
            var repos: [max_repos + 1][]const u8 = undefined;
            const lanes = app.laneRepos(&repos);
            if (app.laneCounts(view.lane, view.col).shown == 0) for (0..lanes) |k| {
                if (app.laneCounts(k, view.col).shown == 0) continue;
                view.lane = k;
                break;
            };
            if (is(key, &.{"z"})) if (app.pickRepo()) |repo| return app.toggleRepoFold(repo);
            if (is(key, &.{"Z"})) return app.focusFold(app.pickRepo() orelse "");
            if (up and view.row > 0) {
                view.row -= 1;
            } else if (up) {
                var k = view.lane;
                while (k > 0) {
                    k -= 1;
                    if (app.laneCounts(k, view.col).shown == 0) continue;
                    view.lane = k;
                    view.row = std.math.maxInt(usize);
                    break;
                }
            }
            if (down and view.row + 1 < app.boardColumn(view.col, &.{})) {
                view.row += 1;
            } else if (down) {
                for (view.lane + 1..lanes) |k| if (app.laneCounts(k, view.col).shown > 0) {
                    view.lane = k;
                    view.row = 0;
                    break;
                };
            }
        } else {
            if (up) view.row -|= 1;
            if (down) view.row += 1;
        }
        if (is(key, &.{"r"})) {
            var repos: [max_repos][]const u8 = undefined;
            const n = if (app.board) |*b| b.repos(&repos) else 0;
            if (view.backlog) {
                view.backlog = false;
                view.repo = 0;
            } else if (view.repo == n) {
                view.backlog = true;
                view.col = 0;
            } else view.repo += 1;
            view.row = 0;
            view.lane = app.firstLane();
        }
        view.row = @min(view.row, app.boardColumn(view.col, &.{}) -| 1);
        if (is(key, &.{"/"})) return app.openFind();
        if (is(key, &.{"\x1b"}) and app.find_len > 0) return app.clearFind();
        if (is(key, &.{ "\x1b", "q" })) return app.closeBoard();
        if (is(key, &.{"`"})) return app.foldSide();
        if (is(key, &.{"g"})) return app.gateModal();
        if (is(key, &.{"o"})) return app.toOrchestrator();
        if (is(key, &.{"A"})) return app.openAuto();
        if (is(key, &.{"P"})) return app.jumpProposed();
        if (is(key, &.{ "]", "[" })) return app.toFeed(key, null);
        if (is(key, &.{"x"})) return app.act(.no);
        if (is(key, &.{"W"})) if (app.boardCard(view.col, view.row)) |card| {
            if (card.status == .todo) return app.toNext(card.id, true);
        };
        if (is(key, &.{"+"})) return app.newTicket();
        if (is(key, &.{"n"})) return app.showInbox();
        const keyed = [_]struct { []const u8, CardAction }{
            .{ "\r", .go },    .{ "e", .edit },    .{ "p", .priority }, .{ ">", .close },
            .{ "<", .reopen }, .{ "J", .down },    .{ "K", .up },       .{ "t", .to_todo },
            .{ "G", .give },   .{ "w", .to_next }, .{ "H", .handoff },
        };
        for (keyed) |pair| if (std.mem.eql(u8, key, pair[0])) return app.act(pair[1]);
    }

    /// The side folded away, or back beside the board; the board opens so from then on.
    fn foldSide(app: *App) !void {
        const view = &app.board_view.?;
        app.dirty = true;
        if (!app.sided()) {
            app.side_folded = false;
            return app.toSide();
        }
        app.side_folded = true;
        view.focus = .board;
        app.reflow();
        if (view.back) |id| try app.switchTo(id);
        view.back = null;
    }

    fn toGate(app: *App) !void {
        const at = app.gateSession() orelse return;
        try app.closeBoard();
        try app.sessionTo(at);
    }

    /// To the orchestrator, started first when it is not running and gone to once its session shows.
    fn toOrchestrator(app: *App) !void {
        if (app.orchestratorSession()) |at| {
            app.board_view = null;
            app.dirty = true;
            app.reflow();
            return app.sessionTo(at);
        }
        try app.closeBoard();
        app.orchestrating = true;
        try app.send(.ignore, captured("babylon orchestrator"), .{});
    }

    /// What babylon's file says of its orchestrator, when it does.
    pub fn orchestrator(app: *const App) ?tickets.Orchestrator {
        return if (app.board) |*b| b.orchestrator() else null;
    }

    /// babylon's auto mode, while it is on, or as the human just asked it to be.
    pub fn auto(app: *const App) ?tickets.Auto {
        const b = if (app.board) |*b| b else return null;
        var state = b.autoState() orelse return null;
        if (app.auto_wants.get(.on, "")) |on| state.on = on != 0;
        return if (state.on) state else null;
    }

    /// Whether babylon holds its pipeline, or as the human just asked it to.
    pub fn holding(app: *const App) bool {
        const b = if (app.board) |*b| b else return false;
        return if (app.auto_wants.get(.hold, "")) |on| on != 0 else b.hold();
    }

    /// How many repos have a cap of their own in auto's modal.
    pub fn autoRepos(app: *const App) usize {
        const b = if (app.board) |*b| b else return 0;
        return (b.autoState() orelse return 0).repo_caps.map.count();
    }

    /// Repo `i` of auto's caps and its cap, as the human just asked it to be.
    pub fn autoRepo(app: *const App, i: usize) ?struct { name: []const u8, cap: u32 } {
        const b = if (app.board) |*b| b else return null;
        const caps = (b.autoState() orelse return null).repo_caps.map;
        if (i >= caps.count()) return null;
        const name = caps.keys()[i];
        return .{ .name = name, .cap = app.auto_wants.get(.cap, name) orelse caps.values()[i] };
    }

    /// Auto's modal: a window over the board with a row for auto, its count, hold, a blank row, a
    /// row for each repo, a blank one and the foot. Its rows are `autoRows`.
    pub fn autoRect(app: *const App) ?ModalRect {
        const view = app.board_view orelse return null;
        if (view.auto_pick == null) return null;
        const width: u16 = @min(app.boardW() -| 4, 48);
        const bottom = app.view_h -| 2;
        if (width < 30 or bottom < first_line + 7) return null;
        const h: u16 = @intCast(@min(7 + app.autoRepos(), bottom - first_line + 1));
        return .{ .x = app.boardX() + (app.boardW() -| width) / 2, .y = first_line, .w = width, .h = h };
    }

    /// How many repo rows auto's modal has room for.
    pub fn autoRoom(rect: ModalRect) usize {
        return rect.h - 7;
    }

    /// Where auto's modal puts a repo row's `[-]` and its `[+]`: the name's cells, then the stepper.
    pub fn autoStepper(app: *const App, rect: ModalRect) struct { minus: u16, plus: u16 } {
        var name_w: usize = 4;
        for (0..app.autoRepos()) |i| name_w = @max(name_w, cellCount((app.autoRepo(i) orelse continue).name));
        const minus = rect.x + 2 + @as(u16, @intCast(name_w)) + 2;
        return .{ .minus = minus, .plus = minus + 6 };
    }

    /// Opens auto's modal, with the keys on the board.
    fn openAuto(app: *App) !void {
        const view = &app.board_view.?;
        view.auto_pick = 0;
        // too small a screen for the window: no box that takes the keys unseen
        if (app.autoRect() == null) {
            view.auto_pick = null;
            return;
        }
        view.auto_from_column = view.focus == .orchestrator;
        view.auto_normal = app.normal;
        view.focus = .board;
        app.dirty = true;
    }

    fn closeAuto(app: *App) void {
        const view = &app.board_view.?;
        view.auto_pick = null;
        if (view.auto_from_column) {
            view.focus = .orchestrator;
            app.normal = view.auto_normal;
        }
        app.dirty = true;
    }

    /// A key in auto's modal: `j` `k` pick a row, `+` `-` step the cap of a repo, `a` and `H` turn
    /// auto and hold on or off, and Escape closes it.
    fn autoKey(app: *App, key: []const u8) !void {
        const view = &app.board_view.?;
        const is = anyKey;
        const pick = &view.auto_pick.?;
        app.dirty = true;
        if (is(key, &.{ "\x1b", "q" })) return app.closeAuto();
        const last = app.autoRepos() + 1;
        if (is(key, &.{ "j", "\x1b[B", "\x1bOB" })) pick.* = @min(pick.* + 1, last);
        if (is(key, &.{ "k", "\x1b[A", "\x1bOA" })) pick.* -|= 1;
        if (is(key, &.{"a"})) try app.autoToggle(.on);
        if (is(key, &.{"H"})) try app.autoToggle(.hold);
        if (is(key, &.{ "\r", " " }) and pick.* < 2) try app.autoToggle(if (pick.* == 0) .on else .hold);
        if (pick.* < 2) return;
        if (is(key, &.{ "+", "=" })) try app.autoStep(pick.* - 2, true);
        if (is(key, &.{"-"})) try app.autoStep(pick.* - 2, false);
    }

    /// The `+ goal` modal over Plan's middle: a title bar, a prompt, a field of four lines, the
    /// buttons with a line under them, and the foot. None where the screen is too small for it.
    pub fn goalRect(app: *const App) ?ModalRect {
        const width: u16 = @min(app.boardW() -| 4, 64);
        const h: u16 = 12;
        if (width < 30 or app.view_h < first_line + h + 2) return null;
        return .{ .x = app.boardX() + (app.boardW() -| width) / 2, .y = first_line + (app.view_h - first_line - h) / 2, .w = width, .h = h };
    }

    pub const GoalButton = struct { key: []const u8, label: []const u8, x: u16, w: u16 };

    /// The modal's three buttons on its row 8, left to right: plan it now, just keep it, cancel.
    pub fn goalButtons(rect: ModalRect) [3]GoalButton {
        var out = [3]GoalButton{
            .{ .key = "\r", .label = "⏎ plan it now", .x = 0, .w = 0 },
            .{ .key = "k", .label = "k just keep it", .x = 0, .w = 0 },
            .{ .key = "q", .label = "q cancel", .x = 0, .w = 0 },
        };
        var x = rect.x + 3;
        for (&out) |*button| {
            button.x = x;
            button.w = @intCast(cellCount(button.label) + 2);
            x += button.w + 2;
        }
        return out;
    }

    /// Where the `+ goal` button sits on a goals title bar, `x` and width.
    pub fn goalHead(app: *const App) struct { x: u16, w: u16 } {
        return .{ .x = app.boardX() + 1 + app.boardW() -| 3 -| 10, .w = 8 };
    }

    fn openGoal(app: *App) !void {
        const view = &app.board_view.?;
        if (app.goalRect() == null) return;
        app.goal = .{};
        view.goal_open = true;
        app.dirty = true;
    }

    /// A key in the `+ goal` modal; `⏎` and `k` send what is typed to babylon, and the modal waits
    /// for its answer.
    fn goalKey(app: *App, key: []const u8) !void {
        const view = &app.board_view.?;
        app.dirty = true;
        switch (app.goal.press(key)) {
            .none => {},
            .cancel => view.goal_open = false,
            .plan => try app.goalSend(true),
            .keep => try app.goalSend(false),
        }
    }

    /// `babylon idea TEXT`, with `--plan` to plan it now. The modal stays until babylon answers.
    fn goalSend(app: *App, plan_now: bool) !void {
        app.goal.busy = true;
        app.goal.said_len = 0;
        const idea = std.mem.trim(u8, app.goal.text(), " ");
        _ = try app.runWith("goal", if (plan_now) &.{ "babylon", "idea", idea, "--plan" } else &.{ "babylon", "idea", idea }, true);
    }

    /// babylon's answer to the modal: `ok` closes it, anything else is said in it, the text kept.
    pub fn goalAnswered(app: *App, text: []const u8) !void {
        const view = if (app.board_view) |*open| open else return;
        if (!view.goal_open) return;
        app.dirty = true;
        const line = std.mem.trim(u8, text, " \n");
        if (std.mem.eql(u8, line, "ok")) {
            view.goal_open = false;
            return;
        }
        var clean: std.ArrayList(u8) = .empty;
        defer clean.deinit(app.gpa);
        try @import("text.zig").appendClean(&clean, app.gpa, line[0 .. std.mem.indexOfScalar(u8, line, '\n') orelse line.len]);
        app.goal.refuse(if (clean.items.len > 0) clean.items else "babylon refused the idea");
    }

    /// A click in the `+ goal` modal: a button is its key, and outside it, or its ✕, cancels.
    fn goalClick(app: *App, m: keys.Mouse) !void {
        const view = &app.board_view.?;
        const rect = app.goalRect() orelse {
            view.goal_open = false;
            return;
        };
        const close = m.y == rect.y and m.x + 4 >= rect.x + rect.w and m.x + 2 <= rect.x + rect.w;
        if (close or !rect.contains(m.x, m.y)) {
            view.goal_open = false;
            return;
        }
        if (app.goal.typing) return;
        if (m.y >= rect.y + 3 and m.y <= rect.y + 6) {
            app.goal.typing = true;
            return;
        }
        if (m.y != rect.y + 8) return;
        for (goalButtons(rect)) |button| if (m.x >= button.x and m.x < button.x + button.w) return app.goalKey(button.key);
    }

    /// Turns auto or hold the other way, shown at once and sent once the presses stop.
    fn autoToggle(app: *App, kind: autos.Kind) !void {
        const now_on = if (kind == .on) app.auto() != null else app.holding();
        try app.auto_wants.set(app.gpa, kind, "", @intFromBool(!now_on), app.now);
    }

    /// Raises or lowers repo `i`'s cap by one, never under 0, which pauses it.
    fn autoStep(app: *App, i: usize, up: bool) !void {
        const repo = app.autoRepo(i) orelse return;
        if (!up and repo.cap == 0) return;
        try app.auto_wants.set(app.gpa, .cap, repo.name, if (up) repo.cap + 1 else repo.cap - 1, app.now);
    }

    /// A click in auto's modal: a switch, a stepper button, a row to pick, or outside it to close.
    fn autoClick(app: *App, m: keys.Mouse) !void {
        const view = &app.board_view.?;
        const rect = app.autoRect() orelse return app.closeAuto();
        const close = app.workbench() and m.y == rect.y and m.x + 4 >= rect.x + rect.w and m.x + 2 <= rect.x + rect.w;
        if (close or !rect.contains(m.x, m.y)) return app.closeAuto();
        if (m.y == rect.y + 1) {
            view.auto_pick = 0;
            try app.autoToggle(.on);
        } else if (m.y == rect.y + 3) {
            view.auto_pick = 1;
            try app.autoToggle(.hold);
        } else if (m.y >= rect.y + 5 and m.y - rect.y - 5 < @min(app.autoRepos(), autoRoom(rect))) {
            const i = m.y - rect.y - 5;
            view.auto_pick = 2 + i;
            const stepper = app.autoStepper(rect);
            if (m.x >= stepper.minus and m.x < stepper.minus + 3) try app.autoStep(i, false);
            if (m.x >= stepper.plus and m.x < stepper.plus + 3) try app.autoStep(i, true);
        }
    }

    /// Sends each value asked of auto whose presses have stopped, the last one only: babylon runs
    /// in the background. Returns how long until the next is due.
    pub fn sendAuto(app: *App) !i64 {
        const never = std.math.maxInt(i64);
        app.settleAuto();
        var i: usize = 0;
        while (i < app.auto_wants.list.items.len) : (i += 1) {
            const want = app.auto_wants.list.items[i];
            if (want.due == 0 or app.now < want.due) continue;
            var id: [96]u8 = undefined;
            var arg: [96]u8 = undefined;
            const word: []const u8 = if (want.value != 0) "on" else "off";
            const argv: []const []const u8 = switch (want.kind) {
                .on => &.{ "babylon", "auto", word },
                .hold => &.{ "babylon", "hold", word },
                .cap => &.{ "babylon", "auto", "--repo-cap", std.fmt.bufPrint(&arg, "{s}={d}", .{ want.repo, want.value }) catch continue },
            };
            _ = try app.runNeed(want.id(&id), argv);
            app.auto_wants.list.items[i].due = 0;
            app.auto_wants.list.items[i].sent_at = app.now;
        }
        return app.auto_wants.nextDue(app.now) orelse never;
    }

    /// Drops what the human asked of auto that babylon's file now says, or has said nothing of
    /// since it was sent, and what is back at the value the file has before it was sent.
    pub fn settleAuto(app: *App) void {
        const b = if (app.board) |*b| b else return;
        const state = b.autoState() orelse tickets.Auto{};
        var i = app.auto_wants.list.items.len;
        while (i > 0) {
            i -= 1;
            const want = app.auto_wants.list.items[i];
            const has: ?u32 = switch (want.kind) {
                .on => @intFromBool(state.on),
                .hold => @intFromBool(b.hold()),
                .cap => state.repo_caps.map.get(want.repo),
            };
            const said = (want.due == 0 or want.sent_at == 0) and (if (has) |value| value == want.value else false);
            const stale = want.due == 0 and app.now - want.sent_at >= autos.trust_ms;
            if (said or stale) app.auto_wants.drop(app.gpa, i);
        }
    }

    /// babylon refused what was sent for `id`: the board's value shows again, and why is said.
    pub fn autoRefused(app: *App, id: []const u8, text: []const u8) !void {
        const line = std.mem.trim(u8, text, " \n");
        const first = line[0 .. std.mem.indexOfScalar(u8, line, '\n') orelse line.len];
        var clean: std.ArrayList(u8) = .empty;
        defer clean.deinit(app.gpa);
        try @import("text.zig").appendClean(&clean, app.gpa, first);
        try app.auto_wants.refuse(app.gpa, id, clean.items);
        app.dirty = true;
    }

    fn toggleAuto(app: *App) !void {
        try app.send(.ignore, captured("babylon auto {s}"), .{if (app.auto() == null) "on" else "off"});
    }

    /// The todo card picked put in next at its top, or at its bottom once its why is typed.
    fn toNext(app: *App, id: u32, top: bool) !void {
        if (!top) {
            _ = app.openWhy(id, "");
            return;
        }
        try app.send(.ignore, captured("babylon next {d} --at 1"), .{id});
    }

    fn newTicket(app: *App) !void {
        var buf: [80]u8 = undefined;
        const narrowed = if (app.boardRepo()) |r| (if (plainName(r)) std.fmt.bufPrint(&buf, " --repo {s}", .{r}) catch "" else "") else "";
        try app.ticketWindow("babylon new{s}", .{narrowed});
    }

    /// What can be done to a card from the board, by its key or its chip.
    pub const CardAction = enum {
        go,
        no,
        answer,
        give,
        edit,
        priority,
        close,
        reopen,
        to_todo,
        up,
        down,
        to_next,
        handoff,
        open,

        /// The key that does it, as the box on the board writes it.
        pub fn key(action: CardAction) []const u8 {
            return switch (action) {
                .go => "⏎",
                .no => "x",
                .answer => "a",
                .give => "G",
                .edit => "e",
                .priority => "p",
                .close => ">",
                .reopen => "<",
                .to_todo => "t",
                .up => "K",
                .down => "J",
                .to_next => "w",
                .handoff => "H",
                .open => "space",
            };
        }

        pub fn label(action: CardAction) []const u8 {
            return switch (action) {
                .open => "open",
                .go => "go",
                .no => "no",
                .answer => "answer",
                .give => "give",
                .edit => "edit",
                .priority => "priority",
                .close => "close",
                .reopen => "reopen",
                .to_todo => "to todo",
                .up => "↑",
                .down => "↓",
                .to_next => "next",
                .handoff => "hand off",
            };
        }
    };

    /// The actions `card` has: go while a proposal is open on it, a Claude holds it or it can be
    /// started, no beside a proposal, answer while it asks, give while it is
    /// free to claim, close while still to
    /// do and reopen once done, to todo while in the backlog, and edit and priority always, and
    /// moving it along its column but in the backlog or without a repo the move can be narrowed
    /// to, babylon having no move among the cards of none alone.
    pub fn cardActions(card: *const tickets.Card, out: *[12]CardAction) []CardAction {
        var n: usize = 0;
        const movable = card.status != .backlog and card.status != .@"try" and plainName(card.repo orelse "");
        const all = [_]struct { CardAction, bool }{
            .{ .go, card.proposal != null or card.holder() != null or givable(card) }, .{ .no, card.proposal != null },    .{ .answer, card.ask != null },
            .{ .give, givable(card) },                                                 .{ .edit, true },                   .{ .priority, true },
            .{ .close, card.status == .todo },                                         .{ .reopen, card.status == .done }, .{ .to_todo, card.status == .backlog },
            .{ .up, movable },                                                         .{ .down, movable },                .{ .to_next, card.status == .todo },
            .{ .handoff, card.status == .doing and card.holder() != null },
        };
        for (all) |pair| if (pair[1]) {
            out[n] = pair[0];
            n += 1;
        };
        return out[0..n];
    }

    /// Edit opens $EDITOR in a window of its own; priority goes from low up to high and round;
    /// close and reopen move a ticket between to do and done, the columns between being a claim's
    /// and the pipeline's; up and down move it along its column, the pick going with it. Each
    /// through babylon's command line. An action the picked card has not does nothing.
    fn act(app: *App, action: CardAction) !void {
        const view = if (app.board_view) |*open| open else return;
        const card = app.boardCard(view.col, view.row) orelse return;
        if (action == .open) {
            _ = try app.openDetail(card.id);
            return;
        }
        var have: [12]CardAction = undefined;
        if (std.mem.indexOfScalar(CardAction, cardActions(card, &have), action) == null) return;
        var buf: [80]u8 = undefined;
        const narrowed = if (app.pickRepo()) |r| (if (plainName(r)) std.fmt.bufPrint(&buf, " --repo {s}", .{r}) catch "" else "") else "";
        switch (action) {
            .go => if (card.proposal) |proposal| try app.settleProposal("go", proposal.id) else try app.goCard(),
            .no => if (card.proposal) |proposal| try app.settleProposal("no", proposal.id),
            .answer => view.answering = true,
            .give => view.giving = 0,
            .edit => try app.ticketWindow("babylon edit {d}", .{card.id}),
            .priority => {
                const eql = std.mem.eql;
                const next = if (eql(u8, card.priority, "low")) "med" else if (eql(u8, card.priority, "med")) "high" else "low";
                try app.send(.ignore, captured("babylon update {d} --priority {s}"), .{ card.id, next });
            },
            .close => try app.send(.ignore, captured("babylon update {d} --status done"), .{card.id}),
            .to_next => try app.toNext(card.id, false),
            .handoff => try app.askHandoff(card),
            .reopen, .to_todo => try app.send(.ignore, captured("babylon update {d} --status todo"), .{card.id}),
            .open => unreachable,
            .up, .down => {
                // a move babylon could not be narrowed to the repo shown would order every repo's cards
                if (app.pickRepo() != null and narrowed.len == 0) return;
                const down = action == .down;
                try app.send(.ignore, captured("babylon move {d} {s}{s}"), .{ card.id, if (down) "down" else "up", narrowed });
                view.row = if (down) @min(view.row + 1, app.boardColumn(view.col, &.{}) -| 1) else view.row -| 1;
            },
        }
    }

    /// The session holding `card` asked to hand it off, in the words babylon's own handoff
    /// proposal types: it commits what is uncommitted, then calls handoff.
    fn askHandoff(app: *App, card: *const tickets.Card) !void {
        const pane = card.holder() orelse return;
        try app.send(.ignore, "send-keys -t %{d} -l 'Your human asks you to hand #{d} off: commit what is uncommitted as a WIP commit, then call handoff.'", .{ pane, card.id });
        try app.send(.ignore, "send-keys -t %{d} Enter", .{pane});
    }

    /// A button on the board, where it is drawn and clicked: 0-based, as the mouse has it.
    pub const Button = struct {
        what: union(enum) { repo: usize, backlog, gate, orch, auto, needs, new, card: CardAction },
        x: u16,
        y: u16,
        w: u16,
        /// Drawn without its words, as a header with no room for them has it.
        short: bool = false,

        pub fn hit(button: Button, x: u16, y: u16) bool {
            return y == button.y and x >= button.x and x < button.x + button.w;
        }
    };

    /// What a modal button does when pressed.
    pub const ModalAction = union(enum) { close, card: CardAction, option: u8, words, claude, whole_log, ticket, bump, withdraw, tried_ok, tried_no };

    /// A button of the modal frame, where it is drawn and clicked: 0-based. It reads ` key label `.
    pub const ModalButton = struct {
        action: ModalAction,
        key: []const u8,
        label: []const u8,
        x: u16,
        y: u16,

        pub fn width(button: ModalButton) u16 {
            return @intCast(cellCount(button.key) + cellCount(button.label) + 3);
        }

        pub fn hit(button: ModalButton, x: u16, y: u16) bool {
            return y == button.y and x >= button.x and x < button.x + button.width();
        }
    };

    /// Where the modal frame is: its corner and size, 0-based.
    pub const ModalRect = struct {
        x: u16,
        y: u16,
        w: u16,
        h: u16,

        pub fn contains(rect: ModalRect, x: u16, y: u16) bool {
            return x >= rect.x and x < rect.x + rect.w and y >= rect.y and y < rect.y + rect.h;
        }
    };

    /// The frame of the modal open over the board, centred over it, when there is room for one.
    pub fn modalRect(app: *const App) ?ModalRect {
        const view = app.board_view orelse return null;
        if (view.detail == null) return null;
        const width = detailWidth(app.boardW());
        const top: u16 = first_line;
        const bottom = app.view_h -| 2;
        if (bottom < top + 3 or width.inner == 0) return null;
        return .{ .x = app.boardX() + (app.boardW() -| width.box) / 2, .y = top, .w = width.box, .h = bottom - top + 1 };
    }

    /// What a card's modal says of it above its body, a line each.
    pub const CardHead = struct {
        pub const Kind = enum { plain, dim, warn, options, check };
        buf: [1024]u8 = undefined,
        used: usize = 0,
        lines: [64][]const u8 = undefined,
        kinds: [64]Kind = undefined,
        n: usize = 0,
        /// The first of the lines of the open ask's options, a button each, and its words after.
        options: ?usize = null,
        /// The first of a to-try ticket's check lines, one each.
        checks: ?usize = null,

        fn add(head: *CardHead, kind: Kind, comptime fmt: []const u8, args: anytype) void {
            if (head.n == head.lines.len) return;
            const text = std.fmt.bufPrint(head.buf[head.used..], fmt, args) catch return;
            head.used += text.len;
            head.lines[head.n] = text;
            head.kinds[head.n] = kind;
            head.n += 1;
        }

        /// `text` run on over lines of `inner` cells, up to `rows` of them.
        fn wrap(head: *CardHead, kind: Kind, text: []const u8, inner: usize, rows: usize) void {
            var it = DetailLines.init(text, inner);
            var n: usize = 0;
            while (it.next()) |line| : (n += 1) {
                if (n == rows or head.n == head.lines.len) return;
                head.lines[head.n] = line;
                head.kinds[head.n] = kind;
                head.n += 1;
            }
        }
    };

    /// The card the open modal shows, when the board's pick is on it: the one its buttons act on.
    pub fn modalCard(app: *const App) ?*const tickets.Card {
        const view = app.board_view orelse return null;
        const id = view.detail orelse return null;
        const card = app.boardCard(view.col, view.row) orelse return null;
        return if (card.id == id) card else null;
    }

    /// Fills `head` with the card's title whole, its stage, holder, model and branch, what blocks
    /// it, the question it asks with its options, and what it was sent back for.
    pub fn cardHead(card: *const tickets.Card, inner: usize, epoch: i64, words: bool, head: *CardHead) void {
        head.* = .{};
        head.wrap(.plain, card.title, inner, head.lines.len);
        var meta: [256]u8 = undefined;
        var wr: Writer = .fixed(&meta);
        wr.print("{s}", .{@tagName(card.status)}) catch {};
        if (card.stage) |stage| wr.print(" · {s}", .{stage}) catch {};
        if (card.heldBy()) |pane| wr.print(" · held by {s}", .{pane}) catch {};
        if (card.handed_off_from) |pane| wr.print(" · handed off from {s}", .{pane}) catch {};
        if (card.model) |model| wr.print(" · {s}", .{model}) catch {};
        if (card.branch) |branch| wr.print(" · {s}", .{branch}) catch {};
        head.add(.dim, "{s}", .{wr.buffered()});
        if (card.blocked_by.len > 0) {
            wr = .fixed(&meta);
            wr.writeAll("blocked by") catch {};
            for (card.blocked_by) |id| wr.print(" #{d}", .{id}) catch {};
            head.add(.dim, "{s}", .{wr.buffered()});
        }
        if (card.proposal) |proposal| head.add(.warn, "▲ proposed: {s}", .{proposal.why});
        if (card.ask) |ask| {
            head.add(.warn, "▲ asks: {s}", .{ask.question});
            if (tickets.epochOf(ask.asked_at)) |at| {
                var age: [8]u8 = undefined;
                head.add(.dim, "waiting {s}", .{waited(&age, epoch - at)});
            }
            head.options = head.n;
            for (0..@min(ask.options.len, max_ask_options) + @intFromBool(words)) |_| head.add(.options, "", .{});
        }
        if (card.status == .@"try" and card.checks.len > 0) {
            var tried: usize = 0;
            for (card.checks) |check| tried += @intFromBool(check.result != null);
            head.add(.warn, "▲ try it: {d} of {d} tried", .{ tried, card.checks.len });
            head.checks = head.n;
            for (card.checks) |check| {
                const sign: []const u8 = if (check.result) |result| (if (std.mem.eql(u8, result, "ok")) "✓" else "✗") else "·";
                head.add(.check, "{s} {d} {s}", .{ sign, check.n, check.text });
            }
        }
    }

    /// The buttons of the open modal, in the order they are drawn: the open ask's options, then
    /// in its foot the card's actions that apply, its Claude's popup and close. Only close for
    /// a ticket the board's pick is not on.
    pub fn modalButtons(app: *const App, out: []ModalButton) []ModalButton {
        const rect = app.modalRect() orelse return out[0..0];
        const foot = rect.y + rect.h - 1;
        const right = rect.x + rect.w -| 2;
        var n: usize = 0;
        var x = rect.x + 2;
        if (app.board_view.?.gate) {
            const all = [_]ModalButton{
                .{ .action = .whole_log, .key = "L", .label = "whole log", .x = 0, .y = foot },
                .{ .action = .ticket, .key = "t", .label = "ticket", .x = 0, .y = foot },
                .{ .action = .bump, .key = "u", .label = "bump", .x = 0, .y = foot },
                .{ .action = .withdraw, .key = "W", .label = "withdraw", .x = 0, .y = foot },
                .{ .action = .close, .key = "q", .label = "close", .x = 0, .y = foot },
            };
            for (all) |item| {
                var button = item;
                button.x = x;
                if (x + button.width() > right or n == out.len) break;
                out[n] = button;
                n += 1;
                x += button.width() + 1;
            }
            return out[0..n];
        }
        if (app.modalCard()) |card| {
            var head: CardHead = undefined;
            const words = app.askWords(card);
            cardHead(card, detailWidth(app.boardW()).inner, app.epoch, words != null, &head);
            var shown: usize = 0;
            if (head.options) |line| if (card.ask) |ask| {
                shown = @min(ask.options.len, max_ask_options);
                for (ask.options[0..shown], 1..) |option, number| {
                    const y = rect.y + 1 + @as(u16, @intCast(line + number - 1));
                    if (y >= foot or n == out.len) break;
                    out[n] = .{ .action = .{ .option = @intCast(number) }, .key = "123456789"[number - 1 ..][0..1], .label = option, .x = x, .y = y };
                    n += 1;
                }
                if (words) |w| {
                    const y = rect.y + 1 + @as(u16, @intCast(line + shown));
                    if (y < foot and n < out.len) {
                        out[n] = .{ .action = .words, .key = w.action.key, .label = w.action.label, .x = x, .y = y };
                        n += 1;
                    }
                }
            };
            x = rect.x + 2;
            if (shown > 0 and n < out.len) {
                const pick = @min(@max(app.board_view.?.ask_pick, 1), shown);
                const button: ModalButton = .{ .action = .{ .option = pick }, .key = "⏎", .label = answers[pick - 1], .x = x, .y = foot };
                out[n] = button;
                n += 1;
                x += button.width() + 1;
            }
            if (card.status == .@"try" and card.checks.len > 0) {
                const tries = [_]ModalButton{
                    .{ .action = .tried_ok, .key = "y", .label = "✓ it works", .x = x, .y = foot },
                    .{ .action = .tried_no, .key = "n", .label = "✗ it failed", .x = x, .y = foot },
                };
                for (tries) |item| {
                    var button = item;
                    button.x = x;
                    if (x + button.width() > right or n == out.len) break;
                    out[n] = button;
                    n += 1;
                    x += button.width() + 1;
                }
            }
            var have: [12]CardAction = undefined;
            for (cardActions(card, &have)) |action| {
                if (action == .go and shown > 0) continue;
                const key: []const u8 = switch (action) {
                    .go => "⏎",
                    .no => "x",
                    .give => "G",
                    .handoff => "H",
                    .edit => "e",
                    .priority => "p",
                    .close => ">",
                    .reopen => "<",
                    else => continue,
                };
                const button: ModalButton = .{ .action = .{ .card = action }, .key = key, .label = action.label(), .x = x, .y = foot };
                if (x + button.width() > right or n == out.len) break;
                out[n] = button;
                n += 1;
                x += button.width() + 1;
            }
            if (app.claudeOf(card) != null and n < out.len) {
                const button: ModalButton = .{ .action = .claude, .key = app.claudeKey(card), .label = "its Claude", .x = x, .y = foot };
                if (x + button.width() <= right) {
                    out[n] = button;
                    n += 1;
                    x += button.width() + 1;
                }
            }
        }
        const close: ModalButton = .{ .action = .close, .key = "q", .label = "close", .x = x, .y = foot };
        if (n < out.len and x + close.width() <= right) {
            out[n] = close;
            n += 1;
        }
        return out[0..n];
    }

    /// Check number `pick` (from 1) of a to-try card, held to the ones it has.
    pub fn pickedCheck(card: *const tickets.Card, pick: u8) ?*const tickets.Check {
        if (card.checks.len == 0) return null;
        return &card.checks[@min(@max(pick, 1), card.checks.len) - 1];
    }

    /// Enter on a tried prompt: `babylon tried N n no WORDS`, the check failed and the ticket sent
    /// back. Nothing typed runs nothing.
    fn sendTried(app: *App, prompt: menu.Prompt) !void {
        app.endWords();
        if (prompt.len == 0) return;
        const item = prompt.item();
        const colon = std.mem.indexOfScalar(u8, item, ':') orelse return;
        _ = try app.runNeed("tried", &.{ "babylon", "tried", item[0..colon], item[colon + 1 ..], "no", prompt.text() });
    }

    /// The words action of `card`'s open ask, as babylon's Your move item gives it.
    pub fn askWords(app: *const App, card: *const tickets.Card) ?struct { need: []const u8, action: tickets.Action } {
        if (card.ask == null) return null;
        const b = if (app.board) |*b| b else return null;
        const need = b.askNeed(card.id) orelse return null;
        for (need.actions) |action| {
            const needs = action.needs orelse continue;
            if (std.mem.eql(u8, needs, "words")) return .{ .need = need.id, .action = action };
        }
        return null;
    }

    const answers = [max_ask_options][]const u8{ "answer 1", "answer 2", "answer 3", "answer 4", "answer 5", "answer 6", "answer 7", "answer 8", "answer 9" };

    /// The window of the Claude holding `card`, when there is one.
    pub fn claudeOf(app: *const App, card: *const tickets.Card) ?*const Window {
        const at = app.paneWindow(card.holder() orelse return null) orelse return null;
        return at.session.wins.items[at.index];
    }

    /// The key of the modal's its Claude: `c`, unless the open ask's words action has it.
    fn claudeKey(app: *const App, card: *const tickets.Card) []const u8 {
        const w = app.askWords(card) orelse return "c";
        return if (std.mem.eql(u8, w.action.key, "c")) "C" else "c";
    }

    /// What a press on a modal button does.
    fn pressModal(app: *App, action: ModalAction) !void {
        const view = &app.board_view.?;
        switch (action) {
            .close => view.detail = null,
            .card => |card| try app.act(card),
            .option => |choice| {
                const ask = (app.modalCard() orelse return).ask orelse return;
                if (choice > ask.options.len) return;
                try app.answerAsk(ask.id, choice);
                view.detail = null;
            },
            .words => {
                const w = app.askWords(app.modalCard() orelse return) orelse return;
                view.detail = null;
                _ = app.openWords(w.need);
            },
            .tried_ok => {
                const card = app.modalCard() orelse return;
                const check = pickedCheck(card, view.check_pick) orelse return;
                var ticket: [12]u8 = undefined;
                var step: [12]u8 = undefined;
                const id = std.fmt.bufPrint(&ticket, "{d}", .{card.id}) catch return;
                const n = std.fmt.bufPrint(&step, "{d}", .{check.n}) catch return;
                _ = try app.runNeed("tried", &.{ "babylon", "tried", id, n, "ok" });
            },
            .tried_no => {
                const card = app.modalCard() orelse return;
                const check = pickedCheck(card, view.check_pick) orelse return;
                var prompt: menu.Prompt = .{ .what = .tried };
                const item = std.fmt.bufPrint(&prompt.target, "{d}:{d}", .{ card.id, check.n }) catch return;
                prompt.target_len = item.len;
                app.prompt = prompt;
                app.normal = false;
                app.dirty = true;
            },
            .whole_log => try app.ticketWindow("babylon gate {d} | less", .{view.detail orelse return}),
            .ticket => _ = try app.openDetail(view.detail orelse return),
            .bump => try app.send(.ignore, captured("babylon bump {d}"), .{view.detail orelse return}),
            .withdraw => if (view.withdrawing) {
                try app.send(.ignore, captured("babylon withdraw {d}"), .{view.detail orelse return});
                view.detail = null;
            } else {
                view.withdrawing = true;
            },
            .claude => {
                const win = app.claudeOf(app.modalCard() orelse return) orelse return;
                try app.closeBoard();
                app.normal = true;
                app.openPopup(.{ .agent = win.id });
            },
        }
    }

    /// A key in the open modal: the keys of its buttons, `j` `k` to scroll and `q` to close.
    fn modalKey(app: *App, key: []const u8) !void {
        const view = &app.board_view.?;
        const is = anyKey;
        const was_withdrawing = view.withdrawing;
        view.withdrawing = false;
        if (is(key, &.{ "\x1b", "q", " " })) return app.pressModal(.close);
        if (!view.gate) if (app.modalCard()) |card| if (card.status == .@"try" and card.checks.len > 0) {
            if (is(key, &.{ "j", "\x1b[B", "\x1bOB" })) {
                view.check_pick = @intCast(@min(view.check_pick + 1, card.checks.len));
                return;
            }
            if (is(key, &.{ "k", "\x1b[A", "\x1bOA" })) {
                view.check_pick = @max(view.check_pick -| 1, 1);
                return;
            }
            if (is(key, &.{"y"})) return app.pressModal(.tried_ok);
            if (is(key, &.{"n"})) return app.pressModal(.tried_no);
        };
        if (is(key, &.{ "j", "\x1b[B", "\x1bOB" }) and view.detail_scroll + 1 < app.detailRows()) view.detail_scroll += 1;
        if (is(key, &.{ "k", "\x1b[A", "\x1bOA" })) view.detail_scroll -|= 1;
        if (view.gate) {
            if (is(key, &.{"L"})) return app.pressModal(.whole_log);
            if (is(key, &.{"t"})) return app.pressModal(.ticket);
            if (is(key, &.{"u"})) return app.pressModal(.bump);
            if (is(key, &.{"W"})) {
                view.withdrawing = was_withdrawing;
                return app.pressModal(.withdraw);
            }
            return;
        }
        if (is(key, &.{"g"})) return app.openGate(view.detail orelse return);
        if (is(key, &.{"d"})) return app.openAskDoc(view.detail orelse return);
        if (is(key, &.{"x"}) and (app.modalCard() orelse return).proposal != null) return app.pressModal(.{ .card = .no });
        const card = app.modalCard() orelse return;
        if (key.len == 1 and key[0] >= '1' and key[0] <= '9') return app.pressModal(.{ .option = key[0] - '0' });
        if (card.ask) |ask| if (ask.options.len > 0) {
            if (is(key, &.{"\t"})) view.ask_pick = if (view.ask_pick < @min(ask.options.len, max_ask_options)) view.ask_pick + 1 else 1;
            if (is(key, &.{"\r"})) return app.pressModal(.{ .option = @min(view.ask_pick, @as(u8, @intCast(@min(ask.options.len, max_ask_options)))) });
        };
        if (app.askWords(card)) |w| if (is(key, &.{w.action.key})) return app.pressModal(.words);
        const claude_key = app.claudeKey(card);
        const action: ModalAction = if (is(key, &.{"\r"})) .{ .card = .go } else if (is(key, &.{"G"})) .{ .card = .give } else if (is(key, &.{"H"})) .{ .card = .handoff } else if (is(key, &.{"e"})) .{ .card = .edit } else if (is(key, &.{"p"})) .{ .card = .priority } else if (is(key, &.{">"})) .{ .card = .close } else if (is(key, &.{"<"})) .{ .card = .reopen } else if (is(key, &.{claude_key}) and app.claudeOf(card) != null) .claude else return;
        try app.pressModal(action);
    }

    pub fn buttonLabel(app: *const App, button: Button, buf: []u8) []const u8 {
        const short = button.short;
        const b = if (app.board) |*b| b else null;
        return switch (button.what) {
            .repo => |i| blk: {
                var repos: [max_repos][]const u8 = undefined;
                const n = if (b) |board| board.repos(&repos) else 0;
                const name = if (i == 0) "every" else if (i <= n) repos[i - 1] else "?";
                break :blk std.fmt.bufPrint(buf, " {s} {d} ", .{ name, app.tabCount(i) }) catch " ? ";
            },
            .backlog => std.fmt.bufPrint(buf, " backlog {d} ", .{if (b) |board| board.backlog().len else 0}) catch " ? ",
            .gate => blk: {
                var runs: [1]*const tickets.Card = undefined;
                const card: ?*const tickets.Card = if (b) |board| (if (board.running(&runs) > 0) runs[0] else null) else null;
                const word = if (short) "" else "gate ";
                break :blk if (card) |c| std.fmt.bufPrint(buf, " ◒ {s}#{d} ", .{ word, c.id }) catch " ◒ " else if (short) " ◒ " else " ◒ gate ";
            },
            .orch => if (short) " ● " else " ● orch ",
            .auto => blk: {
                if (app.roles != null and !(app.auto() != null and app.now < app.auto_armed_until)) {
                    const state = app.auto() orelse break :blk if (short) " ▐● ▌" else "auto ▐● ▌";
                    const lead = if (short) " " else "auto ";
                    break :blk (if (state.tools) |t| (if (short) std.fmt.bufPrint(buf, " ▐ ●▌ {d}/{d}", .{ state.working, state.cap }) else std.fmt.bufPrint(buf, "auto ▐ ●▌ {d}/{d} · tools {d}/{d}", .{ state.working, state.cap, t.working, t.cap })) else std.fmt.bufPrint(buf, "{s}▐ ●▌ {d}/{d}", .{ lead, state.working, state.cap })) catch "▐ ●▌";
                }
                const word = if (short) "" else "auto ";
                if (app.auto() != null and app.now < app.auto_armed_until) break :blk " ◐ turn off? ";
                break :blk if (app.auto()) |state|
                    (if (state.tools) |t| (if (short) std.fmt.bufPrint(buf, " ◐ {d}/{d} ", .{ state.working, state.cap }) else std.fmt.bufPrint(buf, " ◐ auto {d}/{d} · tools {d}/{d} ", .{ state.working, state.cap, t.working, t.cap })) else std.fmt.bufPrint(buf, " ◐ {s}{d}/{d} ", .{ word, state.working, state.cap })) catch " ◐ "
                else if (short) " ◐ " else " ◐ auto ";
            },
            .needs => blk: {
                const n = if (b) |board| board.needsYou().len else 0;
                break :blk if (short) std.fmt.bufPrint(buf, " ▲ {d} ", .{n}) catch " ▲ " else std.fmt.bufPrint(buf, " ▲ {d} need you ", .{n}) catch " ▲ ";
            },
            .new => if (app.workbench()) " + new " else " + ",
            .card => |action| app.cardButtonText(action, buf),
        };
    }

    /// A picked card's button in the box: its key, then what it does, `⏎ start`; the strip's
    /// one row has no room for the key. A review card's `space` is its log, a free card's `⏎` starts it.
    fn cardButtonText(app: *const App, action: CardAction, buf: []u8) []const u8 {
        const view = app.board_view orelse return " ? ";
        const card = app.boardCard(view.col, view.row);
        const word = if (card) |c| switch (action) {
            .go => if (c.proposal == null and c.holder() == null) "start" else action.label(),
            .open => if (c.status == .review) "log" else action.label(),
            else => action.label(),
        } else action.label();
        if (app.boardStrip(view.col) and app.footRows() == 0) return std.fmt.bufPrint(buf, " {s} ", .{word}) catch " ? ";
        return std.fmt.bufPrint(buf, " {s} {s} ", .{ action.key(), word }) catch " ? ";
    }

    /// Rows the board's head takes: its title bar, then its tabs. The columns' top edge is the next, and their lines start under it.
    pub const head_rows: u16 = 2;
    pub const first_line: u16 = head_rows + 1;

    /// The title the board's first row begins with.
    pub const board_title = tabs_title;

    /// Where the board's first row ends its tabs: how many of its buttons there are, and where
    /// the `…` stands when tabs are left out.
    pub const Header = struct { n: usize, more: ?u16 };

    /// The board's first row in three groups: the title, the tabs (`every`, the repos, the
    /// backlog, each with its count), and, against the right edge, what babylon is doing
    /// (those needing the human, the gate, the orchestrator, auto). The right group drops its
    /// words when the tabs would not all fit beside it, and tabs that still do not fit are
    /// left out with a `…` after the last.
    pub fn header(app: *const App, out: []Button) Header {
        const finding = app.findText().len > 0 or (app.prompt != null and app.prompt.?.what == .find);
        if (finding and !app.workbench()) return .{ .n = 0, .more = null };
        var buf: [64]u8 = undefined;
        var repos: [max_repos][]const u8 = undefined;
        const count = if (app.board) |*b| b.repos(&repos) else 0;
        const ox = app.boardX();
        const right = ox + app.boardW();
        const title_end = ox + @as(u16, @intCast(cellCount(board_title))) + 1;
        const start = ox + 1;

        var tabs: [max_repos + 2]Button = undefined;
        var tab_n: usize = 0;
        for (0..count + 1) |i| {
            tabs[tab_n] = .{ .what = .{ .repo = i }, .x = 0, .y = 0, .w = 0 };
            tab_n += 1;
        }
        tabs[tab_n] = .{ .what = .backlog, .x = 0, .y = 0, .w = 0 };
        tab_n += 1;

        var group: [4]Button = undefined;
        var group_n: usize = 0;
        group[group_n] = .{ .what = .needs, .x = 0, .y = 0, .w = 0 };
        group_n += 1;
        if (app.gateSession() != null) {
            group[group_n] = .{ .what = .gate, .x = 0, .y = 0, .w = 0 };
            group_n += 1;
        }
        if (app.orchestrator() != null) {
            group[group_n] = .{ .what = .orch, .x = 0, .y = 0, .w = 0 };
            group_n += 1;
        }
        group[group_n] = .{ .what = .auto, .x = 0, .y = 0, .w = 0 };
        group_n += 1;

        const full_w = groupWidth(app, group[0..group_n], false);
        const short = title_end + full_w > right;
        for (group[0..group_n]) |*item| item.short = short;
        var group_w: u16 = @intCast(groupWidth(app, group[0..group_n], short));

        // what does not fit beside the title
        var first_w: u16 = 0;
        while (group_n > 0 and title_end + group_w > right) {
            group_n -= 1;
            group_w = @intCast(groupWidth(app, group[0..group_n], short));
        }

        var n: usize = 0;
        var x = right - group_w;
        for (group[0..group_n]) |item| {
            const w: u16 = @intCast(cellCount(app.buttonLabel(item, &buf)));
            out[n] = .{ .what = item.what, .x = x, .y = 0, .w = w, .short = short };
            n += 1;
            x += w + 1;
        }
        const limit = right;

        // the tabs, in room before the right group's, and one cell of it for a `…` when some are left
        var left: [max_repos + 2]Button = undefined;
        var left_n: usize = 0;
        x = start;
        for (tabs[0..if (finding) 0 else tab_n]) |tab| {
            first_w = @intCast(cellCount(app.buttonLabel(tab, &buf)));
            if (x + first_w > limit) break;
            left[left_n] = .{ .what = tab.what, .x = x, .y = 1, .w = first_w };
            left_n += 1;
            x += first_w + 1;
        }
        var more: ?u16 = null;
        if (left_n < tab_n and !finding) {
            while (left_n > 1 and left[left_n - 1].x + left[left_n - 1].w + 1 > limit) left_n -= 1;
            more = if (left_n > 0) left[left_n - 1].x + left[left_n - 1].w else start;
        }
        // the tabs go first in the order, so a click finds them before the right group's
        std.mem.copyBackwards(Button, out[left_n .. left_n + n], out[0..n]);
        @memcpy(out[0..left_n], left[0..left_n]);
        return .{ .n = left_n + n, .more = more };
    }

    fn groupWidth(app: *const App, group: []const Button, short: bool) usize {
        var buf: [64]u8 = undefined;
        var w: usize = 0;
        for (group) |item| {
            var button = item;
            button.short = short;
            w += cellCount(app.buttonLabel(button, &buf)) + 1;
        }
        return w -| 1;
    }

    /// The board's buttons: the tabs and what babylon is doing on its first row, a + on
    /// the to-do column's top edge, and the picked card's actions on the row above its bottom
    /// edge, each kept to the room it has. A row of the strip has no edge: the strip's own foot has its reopen.
    pub fn boardButtons(app: *const App, out: []Button) []Button {
        const view = app.board_view orelse return out[0..0];
        const cw = app.boardColW(0);
        var buf: [64]u8 = undefined;
        var n = app.header(out).n;
        const bench = app.workbench();
        if (cw >= @as(u16, if (bench) 26 else 12) and n < out.len) {
            out[n] = if (bench)
                .{ .what = .new, .x = app.boardColX(0) + cw - 12, .y = app.colTop() - 1, .w = 7 }
            else
                .{ .what = .new, .x = app.boardColX(0) + cw - 4, .y = app.colTop() - 1, .w = 3 };
            n += 1;
        }
        const card = app.boardCard(view.col, view.row) orelse return out[0..n];
        const strip = app.boardStrip(view.col);
        const foot = app.footRows() > 0;
        const y: u16 = if (strip) app.view_h -| 1 -| app.barRows() else blk: {
            const lane = app.pickLane();
            const top = app.cardStart(view.col, lane, view.row) orelse return out[0..n];
            const line = top + app.cardHeight(lane, view.col, view.row) - 2;
            const scroll = app.columnScroll(view.col);
            if (line < scroll) return out[0..n];
            break :blk @intCast(@min(app.colTop() + line - scroll, app.listH()));
        };
        if (!strip and y + 1 >= app.listH()) return out[0..n];
        var have: [12]CardAction = undefined;
        var x: u16 = app.boardColX(view.col) + 2;
        var edge = app.boardColX(view.col) + app.boardColW(view.col) -| 2;
        if (strip and foot) {
            var cards: [strip_n]*const tickets.Card = undefined;
            const shown_n = app.stripCards(&cards);
            const k = for (cards[0..shown_n], 0..) |c, i| {
                if (c.id == card.id) break i;
            } else return out[0..n];
            x = app.boardX() + @as(u16, @intCast(k)) * app.stripCell() + 1;
            edge = x + app.stripCell();
        } else if (bench) edge -= 1;
        for (cardActions(card, &have)) |action| {
            if (strip and action != .reopen) continue;
            const w: u16 = @intCast(cellCount(app.buttonLabel(.{ .what = .{ .card = action }, .x = 0, .y = 0, .w = 0 }, &buf)));
            if (x + w > edge or n == out.len) break;
            out[n] = .{ .what = .{ .card = action }, .x = x, .y = y, .w = w };
            n += 1;
            x += w + 1;
        }
        if (!strip and n < out.len) {
            const open: CardAction = .open;
            const w: u16 = @intCast(cellCount(app.buttonLabel(.{ .what = .{ .card = open }, .x = 0, .y = 0, .w = 0 }, &buf)));
            if (x + w <= edge) out[n] = .{ .what = .{ .card = open }, .x = x, .y = y, .w = w };
            if (x + w <= edge) n += 1;
        }
        return out[0..n];
    }

    /// Whether `m` is on a button of the board's first row, not a card's. The plan draws none.
    fn onHeaderButton(app: *App, m: keys.Mouse) bool {
        if (app.planShown()) return false;
        var buttons: [48]Button = undefined;
        for (app.boardButtons(&buttons)) |button| if (button.what != .card and button.hit(m.x, m.y)) return true;
        return false;
    }

    /// Whether column `x` of the auto button is on its switch, not its words.
    fn onAutoSwitch(app: *const App, button: Button, x: u16) bool {
        var buf: [96]u8 = undefined;
        const label = app.buttonLabel(button, &buf);
        const at = x - button.x;
        const knob = std.mem.indexOf(u8, label, "▐") orelse return at < 3;
        const from = cellCount(label[0..knob]);
        return at >= from and at < from + 4;
    }

    fn pressButton(app: *App, button: Button, x: u16) !void {
        const view = &app.board_view.?;
        switch (button.what) {
            .repo => |i| {
                view.repo = i;
                view.backlog = false;
                view.row = 0;
                view.lane = app.firstLane();
            },
            .backlog => {
                view.backlog = true;
                view.col = 0;
                view.row = 0;
            },
            .gate => try app.gateModal(),
            .orch => try app.toOrchestrator(),
            .auto => if (app.now >= app.auto_armed_until and !app.onAutoSwitch(button, x)) {
                try app.openAuto();
            } else if (app.auto() != null and app.now >= app.auto_armed_until) {
                app.auto_armed_until = app.now + auto_confirm_ms;
                app.dirty = true;
            } else {
                app.auto_armed_until = 0;
                try app.toggleAuto();
            },
            .needs => try app.toFeed("]", null),
            .new => try app.newTicket(),
            .card => |action| try app.act(action),
        }
    }

    /// A command over a ticket that wants the terminal, as $EDITOR does: in a window by the
    /// focused one, kept open on a refusal to be read.
    fn ticketWindow(app: *App, comptime cmd: []const u8, args: anytype) !void {
        try app.closeBoard();
        try app.send(.ignore, "new-window -a -n ticket \"" ++ cmd ++ " || read _\"", args);
    }

    /// Proposal `id` settled as `word`, go or no, through babylon, which only a human's own
    /// command line may do; its refusal is said.
    fn settleProposal(app: *App, comptime word: []const u8, id: u32) !void {
        try app.send(.ignore, "run-shell -b \"out=\\$(babylon " ++ word ++ " {d} 2>&1) || " ++
            "{{ command -v notify-send >/dev/null && notify-send -a arena -- \\\"\\$out\\\"; }}\"", .{id});
    }

    /// The pick on the card with the oldest open proposal, when the board has one.
    fn jumpProposed(app: *App) void {
        const id = (if (app.board) |*b| b.oldestProposed() else null) orelse return;
        _ = app.pickCard(id);
        app.dirty = true;
    }

    /// A key while a question is shown: its option's number answers it through babylon, which
    /// types the answer into the asking session; Esc puts it away unanswered.
    fn answerKey(app: *App, key: []const u8) !void {
        const view = &app.board_view.?;
        if (anyKey(key, &.{ "\x1b", "q" })) view.answering = false;
        if (key.len != 1 or key[0] < '1' or key[0] > '9') return;
        const card = app.boardCard(view.col, view.row) orelse return;
        const ask = card.ask orelse return;
        const choice = key[0] - '0';
        if (choice > ask.options.len) return;
        // babylon's refusal (the session that asked is gone) is said, or the ask stays with no word why
        try app.answerAsk(ask.id, choice);
        view.answering = false;
    }

    /// A key while the Claudes the picked card can be given to are shown: j and k pick one, and
    /// Enter or its number gives it the card through babylon, which types the claim into its pane
    /// as its human's word; Esc puts them away.
    fn giveKey(app: *App, key: []const u8) !void {
        const view = &app.board_view.?;
        var found: [give_rows]Agent = undefined;
        const n = app.agents(&found);
        const picked = view.giving.?;
        // opened from the feed, it gives the feed back its keys
        defer if (view.giving == null and view.focus == .orchestrator and app.sideDue()) {
            app.normal = true;
        };
        if (anyKey(key, &.{ "\x1b", "q" })) view.giving = null;
        if (anyKey(key, &.{ "j", "\x1b[B", "\x1bOB" }) and picked + 1 < n) view.giving = picked + 1;
        if (anyKey(key, &.{ "k", "\x1b[A", "\x1bOA" })) view.giving = picked -| 1;
        const to = if (anyKey(key, &.{"\r"})) picked else if (key.len == 1 and key[0] >= '1' and key[0] <= '9') key[0] - '1' else return;
        if (to >= n) return;
        const card = app.boardCard(view.col, view.row) orelse return;
        // babylon's refusal (that Claude is mid-turn, the card was claimed meanwhile) is said
        try app.send(.ignore, "run-shell -b \"out=\\$(babylon give {d} %{d} 2>&1) || " ++
            "{{ command -v notify-send >/dev/null && notify-send -a arena -- \\\"\\$out\\\"; }}\"", .{ card.id, found[to].win.agent_pane });
        view.giving = null;
    }

    /// The mouse on the board: a click on a card picks it, and on the card picked goes to the
    /// Claude holding it; the wheel moves along the column. Whether it was the board's: on the
    /// rail it is the rail's, and closes the board but for its own row there; on the
    /// orchestrator's column beside it a click focuses the column, as one on any window out of
    /// focus, and the wheel, or anything once it is focused, is the column's.
    fn boardMouse(app: *App, m: keys.Mouse) !bool {
        // a card's let go that never came: a new press ends that drag unseen
        if ((app.drag == .card or app.drag == .next_row) and m.leftPress()) app.drag = .none;
        if (app.drag != .none) return false;
        if (m.x < app.boardX()) {
            if (m.leftPress() and m.y != 1) try app.closeBoard();
            app.dirty = true;
            return false;
        }
        const view = &app.board_view.?;
        if (m.x >= app.boardX() + app.boardW() and app.sided() and !view.boxed()) {
            if (m.y >= app.view_h) return true;
            if (app.columnAlone() and m.y == 0 and m.leftPress()) {
                const hint = App.half_hint.len;
                const at = app.term_w -| 2 -| hint;
                if (m.x >= at and m.x < at + 8) {
                    try app.swapHome(false);
                    return true;
                }
                if (m.x >= at + 8 and m.x < at + hint) {
                    try app.toBoard();
                    return true;
                }
            }
            if (m.leftPress() and try app.feedClick(m)) return true;
            if (m.wheel() and app.panelWheel(m)) return true;
            if (app.sideShown() and (app.sideFocused() or m.wheel())) return false;
            if (m.leftPress()) {
                view.focus = .orchestrator;
                app.drag = .focus;
                app.dirty = true;
            }
            return true;
        }
        // a click on the header's buttons leaves the keys where they were: what is typed next
        // still reaches the orchestrator's column
        if (m.leftPress() and !app.onHeaderButton(m)) view.focus = .board;
        if (m.wheel()) {
            if (app.navStep()) try app.boardKey(if (m.code & 1 == 0) "k" else "j");
            return true;
        }
        if (!m.leftPress()) return true;
        app.dirty = true;
        const open = &app.board_view.?;
        // a box over the board takes the click, as a key would, so nothing hidden under it is pressed
        if (open.boxed()) {
            if (open.goal_open) {
                try app.goalClick(m);
                return true;
            }
            if (open.auto_pick != null) {
                try app.autoClick(m);
                return true;
            }
            if (app.modalRect()) |rect| {
                var modal: [16]ModalButton = undefined;
                for (app.modalButtons(&modal)) |button| if (button.hit(m.x, m.y)) {
                    try app.pressModal(button.action);
                    return true;
                };
                if (app.workbench() and !open.gate and m.y == rect.y and m.x + 4 >= rect.x + rect.w and m.x + 2 <= rect.x + rect.w) {
                    open.detail = null;
                    return true;
                }
                if (rect.contains(m.x, m.y)) return true;
            }
            open.help = false;
            open.detail = null;
            open.answering = false;
            open.giving = null;
            return true;
        }
        if (app.planShown()) {
            try app.planClick(m);
            return true;
        }
        if (m.y == 0 and app.onPlanTab(m.x) and app.hasPlan()) {
            try app.goHome();
            return true;
        }
        if (m.y == 0 and m.x < app.boardX() + cellCount(board_title)) return true;
        var bar: [24]BarKey = undefined;
        for (app.keyBar(&bar)) |k| if (k.hit(app, m.x, m.y)) {
            switch (k.what) {
                .card => |action| try app.act(action),
                .key => |key| try app.boardKey(key),
            }
            return true;
        };
        var buttons: [48]Button = undefined;
        for (app.boardButtons(&buttons)) |button| if (button.hit(m.x, m.y)) {
            try app.pressButton(button, m.x);
            return true;
        };
        if (app.headingAt(m.x, m.y)) |lane| {
            try app.toggleRepoFold(app.laneRepo(lane) orelse "");
            return true;
        }
        const at = app.boardCardAt(m.x, m.y) orelse return true;
        if (try app.cardNeedsClick(at, m)) return true;
        view.answering = false;
        const clicked = if (app.boardLanes()) app.laneCard(at.lane, at.col, at.row) else app.boardCard(at.col, at.row);
        const picked = app.boardCard(view.col, view.row);
        const again = clicked != null and picked != null and clicked.?.id == picked.?.id;
        if (!again) view.* = .{ .back = view.back, .col = at.col, .row = at.row, .lane = at.lane, .repo = view.repo, .backlog = view.backlog, .home = view.home };
        if (clicked) |card| app.drag = .{ .card = .{ .id = card.id, .opens = again } };
        return true;
    }

    /// The card with ticket `id`, on the board or in the backlog.
    pub fn cardById(app: *const App, id: u32) ?*const tickets.Card {
        const b = if (app.board) |*b| b else return null;
        for (b.cards()) |*card| if (card.id == id) return card;
        for (b.backlog()) |*card| if (card.id == id) return card;
        return null;
    }

    /// What a card let go in a column of `to` does: stays, takes that status through babylon, or is
    /// refused for a reason. todo↔backlog, todo→done (closed) and done→todo (reopened) are the
    /// moves; doing and review are a claim's and the pipeline's.
    pub const CardDrop = union(enum) { stay, status: []const u8, refuse: []const u8 };

    pub fn cardDrop(from: tickets.Status, to: tickets.Status) CardDrop {
        if (from == to) return .stay;
        return switch (to) {
            .doing, .review => .{ .refuse = "doing and review are a claim's and the pipeline's, not a drop's" },
            .@"try" => .{ .refuse = "a card to try is tried, not dropped" },
            .todo => if (from == .backlog or from == .done) .{ .status = "todo" } else .{ .refuse = "a claimed card goes on through the pipeline, not back to todo" },
            .done => if (from == .todo) .{ .status = "done" } else .{ .refuse = "only a todo card is closed by hand" },
            .backlog => if (from == .todo) .{ .status = "backlog" } else .{ .refuse = "only a todo card goes to the backlog" },
        };
    }

    /// The status a card let go at the pointer would take: the column under it, a repo's tab in
    /// the backlog (back to todo), or the backlog's button (to the backlog). None over anything else.
    pub fn cardTarget(app: *const App) ?tickets.Status {
        const x = app.pointer.x;
        const y = app.pointer.y;
        var buttons: [48]Button = undefined;
        for (app.boardButtons(&buttons)) |button| if (button.what != .card and button.hit(x, y)) return switch (button.what) {
            .backlog => .backlog,
            .repo => if (app.boardBacklog()) .todo else null,
            else => null,
        };
        if (x < app.boardX() or x >= app.boardX() + app.boardW()) return null;
        if (app.footRows() > 0 and y >= app.listH() and y < app.listH() + app.footRows()) return .done;
        if (y < app.colTop() or y + 1 >= app.listH()) return null;
        for (0..app.boardCols()) |c| if (app.boardColW(c) > 0 and x < app.boardColX(c) + app.boardColW(c)) {
            return if (app.boardBacklog()) .backlog else tickets.statuses[c];
        };
        return null;
    }

    /// Card `id` let go over `target`: moved where babylon allows, else the reason is said on the
    /// bottom row and it stays.
    fn dropCard(app: *App, id: u32, over: ?tickets.Status) !void {
        const to = over orelse return;
        const card = app.cardById(id) orelse return;
        switch (cardDrop(card.status, to)) {
            .stay => {},
            .status => |word| {
                var id_buf: [12]u8 = undefined;
                _ = try app.runWith("move", &.{ "babylon", "update", std.fmt.bufPrint(&id_buf, "{d}", .{id}) catch return, "--status", word }, false);
            },
            .refuse => |why| {
                var buf: [160]u8 = undefined;
                try app.reportAnswered(std.fmt.bufPrint(&buf, "no {s}", .{why}) catch "no");
            },
        }
    }

    /// A click on the `▲ proposed` that starts a card's last row, whose ticket has an item of Your
    /// move: the feed's pick goes to that item. Whether it was that click.
    fn cardNeedsClick(app: *App, at: CardAt, m: keys.Mouse) !bool {
        const card = app.groupCard(at.lane, at.col, at.row) orelse return false;
        if (card.proposal == null or app.boardStrip(at.col) or app.workbench()) return false;
        const line = app.columnLineAt(at.col, m.y - app.colTop() + app.columnScroll(at.col)) orelse return false;
        const part = switch (line.what) {
            .card => |spot| spot.part,
            else => return false,
        };
        const picked = app.cardPicked(at.lane, at.col, at.row);
        if (part + 1 + 3 * @as(usize, @intFromBool(picked)) != app.cardHeight(at.lane, at.col, at.row)) return false;
        const x = app.boardColX(at.col) + 2;
        if (m.x < x or m.x >= x + cellCount("▲ proposed")) return false;
        const b = if (app.board) |*b| b else return false;
        for (b.needsYou()) |need| if (need.ticket == card.id) {
            try app.toFeed("]", card.id);
            return true;
        };
        return false;
    }

    /// The mouse in the overview: a click on a picture goes to its window; a picture dragged
    /// onto another takes its place, in whichever session, and onto the rest of a session's
    /// row goes to that session's end; a click anywhere else closes the overview; and the
    /// wheel moves between sessions.
    fn overviewMouse(app: *App, m: keys.Mouse) !void {
        if (m.wheel()) {
            if (app.navStep()) try app.overviewKey(if (m.code & 1 == 0) "k" else "j");
            return;
        }
        if (app.drag == .thumb) {
            app.dirty = true;
            if (m.motion() and !m.hover()) return;
            const id = app.drag.thumb;
            const drop = app.overviewDrop();
            app.drag = .none;
            if (m.release) try app.dropThumb(id, drop orelse return);
            return;
        }
        if (!m.leftPress() and !m.rightPress()) return;
        app.dirty = true;
        if (m.leftPress()) if (app.thumbUnder(m.x, m.y)) |spot| {
            app.drag = .{ .thumb = app.sessions.items[spot.session].wins.items[spot.win].id };
            return;
        };
        app.overview = null;
    }

    /// The window whose picture in the overview is at (`x`, `y`) of the terminal.
    fn thumbUnder(app: *const App, x: u16, y: u16) ?Spot {
        for (app.sessions.items, 0..) |s, si| for (s.wins.items, 0..) |_, wi| {
            const at = app.thumbAt(.{ .session = si, .win = wi }) orelse continue;
            if (x >= at.x and x < at.x + thumb_w and y >= at.y and y < at.y + thumb_h) return .{ .session = si, .win = wi };
        };
        return null;
    }

    /// Where a window held by its picture would go, let go now: the place of the window whose
    /// picture is under the pointer, or with no `win` the end of the session whose row it is.
    pub const ThumbDrop = struct { session: usize, win: ?usize };

    pub fn overviewDrop(app: *const App) ?ThumbDrop {
        if (app.drag != .thumb) return null;
        const at = app.pointer;
        if (app.thumbUnder(at.x, at.y)) |spot| return .{ .session = spot.session, .win = spot.win };
        if (at.x < app.term_w - app.view_w) return null;
        for (app.sessions.items, 0..) |_, si| {
            const row = app.overviewRow(si) orelse continue;
            if (at.y >= row and at.y <= row + thumb_h) return .{ .session = si, .win = null };
        }
        return null;
    }

    /// The window `id`, held by its picture, was let go on `drop`: on its own picture that
    /// was a click, and goes to it.
    fn dropThumb(app: *App, id: u32, drop: ThumbDrop) !void {
        const to = app.sessions.items[drop.session];
        for (app.sessions.items) |s| for (s.wins.items, 0..) |win, from| {
            if (win.id != id) continue;
            const onto = drop.win orelse {
                if (s != to) try app.sendWin(s, from, to, null);
                return;
            };
            if (s != to) return app.sendWin(s, from, to, to.wins.items[onto].id);
            if (onto != from) return app.moveWin(s, from, onto);
            app.overview = null;
            return app.jumpTo(s, from);
        };
    }

    pub const Hit = union(enum) { window: struct { session: *Session, index: usize }, ticket: *const tickets.Card };

    /// What the jump prompt finds for `query`, the closest first, into `out`: the windows of
    /// every session by "session window" and a Claude's branch, then the board's tickets by
    /// `#number title repo`. Returns how many.
    pub fn jumpHits(app: *const App, query: []const u8, out: []Hit) usize {
        var n: usize = 0;
        for ([_]u1{ 0, 1 }) |rank| {
            for (app.sessions.items) |s| for (s.wins.items, 0..) |win, i| {
                if (n == out.len) return n;
                var buf: [160]u8 = undefined;
                const text = std.fmt.bufPrint(&buf, "{s} {s} {s}", .{ s.name, win.name, win.text(.branch) }) catch continue;
                if (menu.fuzzy(query, text) == rank) {
                    out[n] = .{ .window = .{ .session = s, .index = i } };
                    n += 1;
                }
            };
            const b = if (app.board) |*b| b else continue;
            for (b.cards()) |*card| {
                if (n == out.len) return n;
                var buf: [256]u8 = undefined;
                const text = std.fmt.bufPrint(&buf, "#{d} {s} {s}", .{ card.id, card.title, card.repo orelse "" }) catch continue;
                if (menu.fuzzy(query, text) == rank) {
                    out[n] = .{ .ticket = card };
                    n += 1;
                }
            }
        }
        return n;
    }

    /// Goes where a jump hit is: a window of any session, or a ticket's card, its modal open.
    fn jumpHit(app: *App, hit: Hit) !void {
        switch (hit) {
            .window => |at| try app.jumpTo(at.session, at.index),
            .ticket => |card| {
                app.normal = false;
                try app.showCard(card.id);
                if (app.board_view) |*view| view.answering = false;
                if (app.board_view != null) _ = try app.openDetail(card.id);
            },
        }
    }

    /// Goes to a window of any session.
    fn jumpTo(app: *App, s: *Session, index: usize) !void {
        if (s.id == app.current) return app.focusTo(index);
        s.focus = index;
        try app.send(.ignore, "select-window -t @{d}", .{s.wins.items[index].id});
        try app.sessionTo(app.sessionIndex(s.id) orelse return);
    }

    /// Whether this click on a name is the second of a pair.
    fn doubleClick(app: *App, name: Name) bool {
        const again = std.meta.eql(app.clicked, @as(?Name, name)) and app.now - app.clicked_at < double_click_ms;
        app.clicked = if (again) null else name;
        app.clicked_at = app.now;
        return again;
    }

    /// The held button moved to `m`, or let go, wherever the pointer is by then.
    fn dragTo(app: *App, m: keys.Mouse) !void {
        if (app.drag == .card) return app.dragCard(m);
        if (app.drag == .next_row) return app.dragNextRow(m);
        const s = app.cur() orelse {
            app.drag = .none;
            return;
        };
        if (m.release or !m.motion() or m.hover()) {
            const held = app.drag;
            const drop = app.dropAt();
            app.drag = .none;
            app.dirty = true;
            switch (held) {
                .select => |from| if (app.paneById(from.pane)) |pane| try app.copy(pane),
                .title => |id| if (m.release) try app.dropWindow(s, id, drop),
                else => {},
            }
            return;
        }
        const ox: i32 = app.term_w - app.view_w;
        switch (app.drag) {
            .none, .thumb, .focus => {},
            .card, .next_row => {},
            // Past the pane's top or bottom the history scrolls under the pointer.
            .select => |from| {
                const pane = app.paneById(from.pane) orelse return;
                const screen = pane.term.screens.active;
                const left = ox + app.colX(s, s.focus) - s.scroll + 1 + pane.x;
                const x = std.math.clamp(m.x - left, 0, pane.term.cols - 1);
                var y = @as(i32, m.y) - app.winTop(s, s.focus) - pane.y;
                if (y < 0 or y >= pane.term.rows) pane.term.scrollViewport(.{ .delta = if (y < 0) -1 else 1 });
                y = std.math.clamp(y, 0, pane.term.rows - 1);
                const end = screen.pages.pin(.{ .viewport = .{ .x = @intCast(x), .y = @intCast(y) } }) orelse return;
                const start = if (screen.selection) |sel|
                    sel.start()
                else
                    screen.pages.pin(.{ .viewport = .{ .x = from.x, .y = from.y } }) orelse return;
                try screen.select(vt.Selection.init(start, end, false));
                app.dirty = true;
            },
            .divider => |*line| {
                const win = s.focused() orelse return;
                const pane = for (win.panes.items) |pane| {
                    if (pane.id == line.pane) break pane;
                } else {
                    app.drag = .none;
                    return;
                };
                const inside = ox + app.colX(s, s.focus) - s.scroll + 1;
                const want: i32 = if (line.upright) m.x - inside - pane.x else @as(i32, m.y) - app.winTop(s, s.focus) - pane.y;
                if (want < 1 or want == line.asked) return;
                line.asked = want;
                const axis: u8 = if (line.upright) 'x' else 'y';
                try app.send(.ignore, "resize-pane -t %{d} -{c} {d}", .{ pane.id, axis, want });
            },
            // Nothing moves until it is let go: where it would go is drawn.
            .title => app.dirty = true,
            .session => |id| try app.dragSession(id, m),
        }
    }

    /// The held button moved to `m`, or let go, with a board card in it: no session is needed.
    fn dragCard(app: *App, m: keys.Mouse) !void {
        const held = &app.drag.card;
        app.dirty = true;
        if (!m.release and m.motion() and !m.hover()) {
            held.moved = true;
            return;
        }
        const card = held.*;
        const over = app.cardTarget();
        const on_plan = app.onPlanLink();
        app.drag = .none;
        if (!m.release) return;
        if (card.opens and !card.moved) _ = try app.openDetail(card.id) else if (on_plan) try app.dropOnNext(card.id) else try app.dropCard(card.id, over);
    }

    fn onPlanTab(app: *const App, x: u16) bool {
        const tab = app.planTab();
        return x >= tab.x and x < tab.x + tab.w;
    }

    /// Whether the pointer is on the board's `b plan` tab, the way back to the plan.
    fn onPlanLink(app: *const App) bool {
        return app.hasPlan() and app.pointer.y == 0 and app.onPlanTab(app.pointer.x);
    }

    /// Card `id` let go on the way back to the plan: a todo card joins next at its bottom, and
    /// its why is asked at the foot, as `n` does; one already there is moved to the bottom.
    fn dropOnNext(app: *App, id: u32) !void {
        const card = app.cardById(id) orelse return;
        if (card.status != .todo) return app.reportAnswered("no only a todo card goes in next");
        const queue = app.board.?.next();
        var at = queue.len + 1;
        for (queue) |item| if (item.ticket == id) {
            at = queue.len;
            break;
        };
        var number: [12]u8 = undefined;
        var place: [12]u8 = undefined;
        var said: [24]u8 = undefined;
        const ticket = std.fmt.bufPrint(&number, "{d}", .{id}) catch return;
        const here = std.fmt.bufPrint(&place, "{d}", .{at}) catch return;
        const refusal = std.fmt.bufPrint(&said, "next:{d}", .{id}) catch return;
        _ = try app.runNeed(refusal, &.{ "babylon", "next", ticket, "--at", here });
        if (at > queue.len) _ = app.openWhy(id, "");
    }

    /// Where a window held by its title would go, let go now: the place of the column under
    /// the pointer, or a session on the rail.
    pub const Drop = union(enum) { none, column: usize, session: usize };

    pub fn dropAt(app: *const App) Drop {
        if (app.drag != .title) return .none;
        const s = app.cur() orelse return .none;
        const ox = app.term_w - app.view_w;
        if (app.pointer.x < ox) {
            const row = app.railSession(app.pointer.y) orelse return .none;
            return if (app.sessions.items[row].id == s.id) .none else .{ .session = row };
        }
        const hit = app.colAt(s, @as(i32, app.pointer.x) - ox + s.scroll) orelse return .none;
        return if (s.wins.items[hit.index].id == app.drag.title) .none else .{ .column = hit.index };
    }

    /// The rail's rows: its sessions one under another from the second, then a rule over the button
    /// for a new session and the menu button, above its bottom border.
    pub fn railRuleRow(app: *const App) u16 {
        return app.view_h -| 4;
    }

    pub fn railNewRow(app: *const App) u16 {
        return app.view_h -| 3;
    }

    pub fn railMenuRow(app: *const App) u16 {
        return app.view_h -| 2;
    }

    /// How many sessions fit above the rule, with a row free under the last.
    pub fn railShown(app: *const App) usize {
        const room = app.railRuleRow() -| 1;
        return @min(app.railSessions(), room -| 2);
    }

    /// The sessions the rail and the overview list: all but babylon's, which sorts last.
    pub fn railSessions(app: *const App) usize {
        var n: usize = 0;
        while (n < app.sessions.items.len and !app.sessions.items[n].offRail()) n += 1;
        return n;
    }

    /// Where babylon's session is, when it is there.
    pub fn gateSession(app: *const App) ?usize {
        for (app.railSessions()..app.sessions.items.len) |i| if (app.sessions.items[i].gate()) return i;
        return null;
    }

    /// Where the orchestrator's session is, when it is running.
    pub fn orchestratorSession(app: *const App) ?usize {
        for (app.railSessions()..app.sessions.items.len) |i| if (app.sessions.items[i].orchestrator()) return i;
        return null;
    }

    /// The rule over the rail's agents, a row free under the last session, and the rows they can
    /// have under it, with one free over the rule at its foot.
    pub fn railAgentsRow(app: *const App) u16 {
        return @intCast(2 + app.railShown() + 1);
    }

    pub fn railAgentRows(app: *const App) u16 {
        return app.railRuleRow() -| 1 -| (app.railAgentsRow() + 1);
    }

    /// Which session is on row `y` of the rail.
    fn railSession(app: *const App, y: u16) ?usize {
        if (y < 2) return null;
        const index = y - 2;
        return if (index < app.railShown()) index else null;
    }

    fn dropWindow(app: *App, s: *Session, id: u32, drop: Drop) !void {
        const from = for (s.wins.items, 0..) |win, index| {
            if (win.id == id) break index;
        } else return;
        // a press that moved a window was not the first of two on its name
        if (drop != .none) app.clicked = null;
        switch (drop) {
            .none => {},
            .column => |to| try app.moveWin(s, from, to),
            .session => |to| try app.sendWin(s, from, app.sessions.items[to], null),
        }
    }

    /// Moves a window of `s` to another's place, the ones between shifting along: tmux swaps
    /// two at a time.
    fn moveWin(app: *App, s: *const Session, from: usize, to: usize) !void {
        const id = s.wins.items[from].id;
        var at = from;
        while (at != to) {
            at = if (to > at) at + 1 else at - 1;
            try app.send(.ignore, "swap-window -d -s @{d} -t @{d}", .{ id, s.wins.items[at].id });
        }
        app.want_list = true;
    }

    /// Moves a window of `s` to another session: in front of its window `before`, or to its
    /// end. A session's last window takes the session with it, and tmux would detach arena
    /// from a session that ends, so arena goes with the window.
    fn sendWin(app: *App, s: *const Session, from: usize, to: *const Session, before: ?u32) !void {
        if (s.id == app.current and s.wins.items.len == 1) {
            try app.sessionTo(app.sessionIndex(to.id) orelse return);
        }
        const id = s.wins.items[from].id;
        if (before) |next| {
            try app.send(.ignore, "move-window -b -s @{d} -t @{d}", .{ id, next });
        } else try app.send(.ignore, "move-window -s @{d} -t '${d}:'", .{ id, to.id });
        app.want_list = true;
    }

    /// The held button moved to `m` with a session, which goes to the row under the pointer.
    fn dragSession(app: *App, id: u32, m: keys.Mouse) !void {
        const at = app.sessionIndex(id) orelse return;
        const over = @min(app.railShown() -| 1, m.y -| 2);
        if (over != at) try app.moveSession(at, over);
    }

    /// Puts the session at `at` of the rail at `to`, and has tmux keep every session's place.
    fn moveSession(app: *App, at: usize, to: usize) !void {
        app.sessions.insertAssumeCapacity(to, app.sessions.orderedRemove(at));
        for (app.sessions.items, 1..) |s, place| {
            s.order = @intCast(place);
            try app.send(.ignore, "set-option -t '${d}' @arena_order {d}", .{ s.id, place });
        }
        app.dirty = true;
    }

    /// Moves the current session up or down the rail.
    fn sessionSwapBy(app: *App, delta: i32) !void {
        const at = app.sessionIndex(app.current) orelse return;
        const next = @as(i32, @intCast(at)) + delta;
        if (at >= app.railSessions() or next < 0 or next >= app.railSessions()) return;
        try app.moveSession(at, @intCast(next));
    }

    /// Ends a session and every window in it. tmux would detach arena from the session it is
    /// on when that ends, so arena moves to a neighbour first.
    fn closeSession(app: *App, id: u32) !void {
        const at = app.sessionIndex(id) orelse return;
        const count = app.sessions.items.len;
        if (id == app.current and count > 1) try app.sessionTo(if (at + 1 < count) at + 1 else at - 1);
        try app.send(.ignore, "kill-session -t '${d}'", .{id});
    }

    /// The line after a pane of the focused window, which is taken hold of to resize the pane.
    pub const Line = struct { pane: u32, upright: bool };

    pub fn lineAt(app: *const App, x: u16, y: u16) ?Line {
        const s = app.cur() orelse return null;
        const ox = app.term_w - app.view_w;
        if (x < ox or y == 0 or y + 1 >= app.view_h or app.yoff != 0) return null;
        const hit = app.colAt(s, @as(i32, x) - ox + s.scroll) orelse return null;
        const win = s.wins.items[hit.index];
        if (hit.index != s.focus or hit.cx == 0 or hit.cx == app.colW(s, win) - 1) return null;
        const tx = hit.cx - 1;
        const top = app.winTop(s, hit.index);
        if (y < top) return null;
        const ty = y - top;
        if (win.paneAt(tx, ty) != null) return null;
        if (tx > 0) if (win.paneAt(tx - 1, ty)) |before| return .{ .pane = before.id, .upright = true };
        if (ty > 0) if (win.paneAt(tx, ty - 1)) |above| return .{ .pane = above.id, .upright = false };
        return null;
    }

    /// Has the terminal show the pointer as what it is over, or holds, can be dragged: by
    /// name, as OSC 22 takes them.
    fn pointAs(app: *App, m: keys.Mouse) !void {
        const upright: ?bool = switch (app.drag) {
            .divider => |line| line.upright,
            .none => if (app.overlay()) null else if (app.lineAt(m.x, m.y)) |line| line.upright else null,
            else => null,
        };
        const shape: []const u8 = if (upright) |is| (if (is) "ew-resize" else "ns-resize") else "default";
        if (shape.ptr == app.shape.ptr) return;
        app.shape = shape;
        app.shape_due = true;
        app.dirty = true;
    }

    /// True when a wheel or swipe step may move between windows or sessions: they come in
    /// bursts, and each burst is one step.
    fn navStep(app: *App) bool {
        if (app.now - app.nav_at < nav_gap_ms) return false;
        app.nav_at = app.now;
        return true;
    }

    /// A sideways swipe steps one window, once it has gone `swipe_events` one way with no up or
    /// down among them, and no more however long its momentum runs.
    fn swipe(app: *App, by: i32) !void {
        if (app.now - app.sideways_at >= nav_gap_ms) {
            app.sideways_run = 0;
            app.swiped = false;
        }
        app.sideways_at = app.now;
        // A trackpad's swipe up or down drifts, and the sideways events among its own are not steps.
        if (app.now - app.vertical_at < nav_gap_ms) {
            app.sideways_run = 0;
            return;
        }
        if (app.sideways_run * by < 0) app.sideways_run = 0;
        app.sideways_run += by;
        if (app.swiped or @abs(app.sideways_run) < swipe_events) return;
        app.swiped = true;
        try app.focusBy(by);
    }

    /// A right click nothing else took opens the menu; with the menu open, a click picks from it
    /// or, outside it, closes it.
    fn onMouse(app: *App, m: keys.Mouse) !void {
        app.pointer = .{ .x = m.x, .y = m.y };
        if (m.leftPress() and app.menu == null and app.prompt == null and app.overview == null) {
            // with the board open, where a click puts the keys is the board's to say: a click on
            // its chrome must not leave the focused column in normal mode, drawn as insert
            if (app.paneClick(m)) {
                app.normal = false;
            } else if (app.board_view == null or m.x < app.railDrawnW()) app.normal = true;
            app.dirty = true;
        }
        try app.pointAs(m);
        if (m.hover()) {
            app.hoverRail(m.x);
            app.hoverLook(m);
        } else if (m.leftPress() or m.rightPress()) {
            app.lookAway();
            app.key_typed = false;
        }
        const over_dots = m.y == app.view_h and m.x >= app.term_w - app.view_w;
        if (over_dots != app.over_dots) {
            app.over_dots = over_dots;
            app.dirty = true;
        }
        if (app.overview != null) return app.overviewMouse(m);
        if (app.prompt) |prompt| if (stepWords(prompt)) {
            if (m.leftPress() and app.onSendBack(m)) try app.sendWords(prompt);
            return;
        };
        if (app.board_view != null) if (try app.boardMouse(m)) return;
        if (app.prompt) |*prompt| {
            if (!m.leftPress() and !m.rightPress()) return;
            app.dirty = true;
            const at = app.box(prompt.height());
            const first = at.y + menu.Prompt.list_row;
            const listed = prompt.what == .jump and m.leftPress() and m.x > at.x and m.x + 1 < at.x + menu.width and
                m.y >= first and m.y < first + menu.jump_rows;
            if (!listed) {
                if (prompt.what == .words or prompt.what == .why or prompt.what == .tried) app.endWords() else {
                    app.prompt = null;
                }
                return;
            }
            prompt.selected = m.y - first;
            return app.commit();
        }
        if (app.menu) |open| {
            if (!m.leftPress() and !m.rightPress()) return;
            const at = app.box(open.height());
            const inside = m.x >= at.x and m.x < at.x + menu.width and m.y >= at.y and m.y < at.y + open.height();
            try app.menuResult(if (inside and m.leftPress()) open.click(m.x - at.x, m.y - at.y) else .close);
            return;
        }
        if (!try app.mouseHit(m) and m.rightPress()) app.openMenu(&menu.main);
    }

    /// Whether the mouse event was for something. On the rail: a click picks a session or the
    /// menu, a second one on the current session renames it, one under the last makes a new
    /// one, a session is dragged to move it and middle clicked to close it, the wheel steps
    /// through sessions.
    /// On the strip: a click goes to that window, dot or pane; a title is dragged onto another
    /// column, to take its place, or onto a session of the rail, to go there, clicked twice to
    /// rename its window, middle clicked to close it; the line between panes is dragged to
    /// resize them; a sideways wheel steps through windows; and anything inside a pane is its
    /// program's or scrolls it, but for a shift drag, which selects, a middle click, which
    /// pastes the primary selection, and a hover.
    fn mouseHit(app: *App, m: keys.Mouse) !bool {
        const ox = app.term_w - app.view_w;
        if (m.wheel() and !m.sideways()) app.vertical_at = app.now;
        if (app.drag != .none and !m.wheel()) {
            try app.dragTo(m);
            return true;
        }
        if (m.x < @max(ox, app.railDrawnW())) {
            if (m.wheel()) {
                const up = m.code & 1 == 0;
                if (app.inRailAgents(m.y)) {
                    const more = app.agentsOverflow();
                    // a list that scrolls keeps the wheel, even at its ends: it steps no session
                    if (more.above or more.below) {
                        if (if (up) more.above else more.below) app.scrollAgents(if (up) -wheel_agents else wheel_agents);
                        return true;
                    }
                }
                if (app.navStep()) try app.sessionBy(if (up) -1 else 1);
                return true;
            }
            if (m.middlePress()) if (app.railSession(m.y)) |row| {
                app.doomed = app.sessions.items[row].id;
                app.openMenu(&menu.confirm_session);
                return true;
            };
            if (!m.leftPress()) return false;
            if (app.railAgentAt(m.y)) |line| {
                switch (line) {
                    .agent, .detail, .meta, .background => |a| try app.goAgent(a),
                    .sub => |sub| try app.goSub(sub),
                    .session => |si| try app.sessionTo(si),
                    .above, .pipeline, .more => app.clickList(line),
                }
                return true;
            }
            if (m.y == app.railAgentsRow() and app.railAgentAt(m.y + 1) != null) {
                app.toggleSort();
                return true;
            }
            if (m.y == 0) {
                app.toggleRail();
                return true;
            }
            if (m.y == 1 and app.board != null) {
                var text: [16]u8 = undefined;
                const needs = app.railNeeds(&text);
                if (app.railDrawnW() == app.railWideW() and app.needsCount() > 0 and m.x >= rail_needs_x and m.x < rail_needs_x + cellCount(needs)) {
                    if (app.board_view == null) try app.goHome();
                    try app.toFeed("]", null);
                    return true;
                }
                try app.goHome();
                return true;
            }
            if (m.y == app.railMenuRow()) app.openMenu(&menu.main);
            if (m.y == app.railNewRow()) try app.send(.ignore, "new-session", .{});
            if (app.railSession(m.y)) |row| {
                const id = app.sessions.items[row].id;
                if (app.doubleClick(.{ .session = id }) and id == app.current) {
                    app.prompt = .{ .what = .session };
                    app.dirty = true;
                } else {
                    try app.sessionTo(row);
                    app.drag = .{ .session = id };
                }
            }
            return true;
        }
        const s = app.cur() orelse return false;
        if (app.yoff != 0) return false;
        if (m.y == app.view_h) {
            if (m.wheel() and !m.sideways()) {
                if (app.navStep()) try app.focusBy(if (m.code & 1 == 0) -1 else 1);
                return true;
            }
            var widths: [max_tabs]usize = undefined;
            const tabs = tabWidths(s, &widths);
            const at = (if (tabs.len > 0) layout.tabAt(app.view_w, tabs, m.x - ox) else null) orelse
                layout.dotAt(app.view_w, s.wins.items.len, m.x - ox) orelse return false;
            if (m.leftPress()) try app.focusTo(at);
            return m.leftPress();
        }
        if (m.sideways()) {
            try app.swipe(if (m.code & 1 == 0) -1 else 1);
            return true;
        }
        if (m.leftPress()) if (app.lineAt(m.x, m.y)) |line| {
            app.drag = .{ .divider = .{ .pane = line.pane, .upright = line.upright } };
            return true;
        };
        const hit = app.colAt(s, @as(i32, m.x) - ox + s.scroll) orelse return false;
        const index = hit.index;
        const cx = hit.cx;
        const win = s.wins.items[index];
        const col_w = app.colW(s, win);
        const focused = index == s.focus;
        if (m.y == 0 and m.middlePress()) {
            try app.focusTo(index);
            app.openMenu(&menu.confirm);
            return true;
        }
        if (m.y == 0 and m.leftPress()) {
            if (!focused) try app.focusTo(index);
            if (app.doubleClick(.{ .window = win.id })) {
                app.prompt = .{ .what = .window };
                app.dirty = true;
            } else app.drag = .{ .title = win.id };
            return true;
        }
        if (!focused and !m.wheel()) {
            if (!m.leftPress()) return false;
            try app.focusTo(index);
            app.drag = .focus;
            return true;
        }
        const top = app.winTop(s, index);
        if (cx == 0 or cx == col_w - 1 or m.y < top) return false;
        const pane = win.paneAt(cx - 1, m.y - top) orelse return false;
        if (focused) {
            if (m.leftPress() and pane != win.activePane()) {
                win.active = std.mem.indexOfScalar(*Pane, win.panes.items, pane).?;
                try app.send(.ignore, "select-pane -t %{d}", .{pane.id});
                app.dirty = true;
            }
            const px: u16 = @intCast(cx - 1 - pane.x);
            const py: u16 = @intCast(m.y - top - pane.y);
            if (m.code & (3 | 32 | 64) == 1) {
                if (!m.release) try app.send(.ignore, "run-shell -b \"(wl-paste -p -n | tmux load-buffer -b arena-primary - && tmux paste-buffer -p -d -b arena-primary -t %{d}) >/dev/null 2>&1\"", .{pane.id});
                return true;
            }
            const shift = m.code & 4 != 0 and !m.wheel();
            if (!shift and try app.mouseToPane(win, pane, m, px, py)) return true;
            // The program takes no mouse, or shift is held: the button selects text, which is
            // copied when it is let go, and two clicks pick a word.
            if (m.leftPress()) {
                const screen = pane.term.screens.active;
                screen.clearSelection();
                app.dirty = true;
                if (!app.doubleClick(.{ .pane = pane.id })) {
                    app.drag = .{ .select = .{ .pane = pane.id, .x = px, .y = py } };
                    return true;
                }
                const pin = screen.pages.pin(.{ .viewport = .{ .x = px, .y = py } }) orelse return true;
                try screen.select(screen.selectWord(pin, &word_ends) orelse return true);
                try app.copy(pane);
                return true;
            }
        }
        if (!m.wheel()) return false;
        const up = m.code & 1 == 0;
        // A full-screen program with no mouse of its own has no history to scroll: the wheel is
        // its arrow keys, as terminals do.
        if (focused and pane.term.screens.active_key == .alternate) {
            const app_keys = pane.term.modes.get(.cursor_keys);
            const arrow: []const u8 = if (app_keys) (if (up) "\x1bOA" else "\x1bOB") else if (up) "\x1b[A" else "\x1b[B";
            for (0..3) |_| try app.sendKeys(pane, arrow);
            return true;
        }
        pane.term.scrollViewport(.{ .delta = if (up) -3 else 3 });
        app.dirty = true;
        return true;
    }

    /// Reports the mouse to the pane's program in the mode and format it asked tmux for; false
    /// when it asked for none.
    fn mouseToPane(app: *App, win: *const Window, pane: *Pane, m: keys.Mouse, x: usize, y: usize) !bool {
        const mode = pane.term.flags.mouse_event;
        if (mode == .none) return false;
        if (m.motion() and mode != .button and mode != .any) return true;
        if (m.hover()) return true;
        if (m.release and mode == .x10) return true;
        var buf: [32]u8 = undefined;
        switch (pane.term.flags.mouse_format) {
            .sgr => {
                const end: u8 = if (m.release) 'm' else 'M';
                try app.sendKeys(pane, try std.fmt.bufPrint(&buf, "\x1b[<{d};{d};{d}{c}", .{ m.code, x + 1, y + 1, end }));
            },
            .sgr_pixels => {
                // the middle of the cell, in the pixels tmux tells the program its cells are
                const end: u8 = if (m.release) 'm' else 'M';
                const px = x * win.cell_w + win.cell_w / 2;
                const py = y * win.cell_h + win.cell_h / 2;
                try app.sendKeys(pane, try std.fmt.bufPrint(&buf, "\x1b[<{d};{d};{d}{c}", .{ m.code, px, py, end }));
            },
            else => {
                // one byte a coordinate, offset by 32: cells past 222 cannot be said
                if (x > 222 or y > 222) return true;
                const code = if (m.release) m.code | 3 else m.code;
                buf[0..3].* = "\x1b[M".*;
                buf[3] = @intCast(code + 32);
                buf[4] = @intCast(x + 33);
                buf[5] = @intCast(y + 33);
                try app.sendKeys(pane, buf[0..6]);
            },
        }
        return true;
    }

    fn openMenu(app: *App, items: []const menu.Item) void {
        app.menu = .{ .items = items };
        app.dirty = true;
    }

    /// Whether the menu, a prompt or the overview has the keys and lies over the strip.
    pub fn overlay(app: *const App) bool {
        return app.menu != null or app.prompt != null or app.overview != null or app.board_view != null;
    }

    /// Where the top left corner of a menu or prompt `height` rows tall is: centred over the strip.
    pub fn box(app: *const App, height: u16) struct { x: u16, y: u16 } {
        return .{
            .x = app.term_w - app.view_w + (app.view_w -| menu.width) / 2,
            .y = (app.view_h -| height) / 2,
        };
    }

    /// Whether what is typed is the focused pane's: nothing lies over the strip, or the board
    /// does with the orchestrator's column beside it focused.
    fn typing(app: *const App) bool {
        return !app.normal and app.menu == null and app.prompt == null and app.overview == null and (app.board_view == null or app.sideFocused());
    }

    /// Whether a left click at `m` is on the strip or the board's side column, which it makes
    /// insert; the rail and the board are chrome.
    fn paneClick(app: *const App, m: keys.Mouse) bool {
        if (app.board_view) |view| return app.sideShown() and !view.boxed() and m.y < app.view_h and m.x > app.boardX() + app.boardW();
        return m.y < app.view_h and m.x >= @max(app.term_w - app.view_w, app.railDrawnW());
    }

    /// Normal mode ends where an overlay has the keys: it is the mode there, and closing it is
    /// back to insert.
    fn settleMode(app: *App) void {
        if (app.normal and app.overlay() and !app.sideFocused() and app.popup == null) app.normal = false;
        if (!app.normal) {
            app.hash_len = null;
            app.closePopup();
            app.rail_pick = null;
        }
    }

    /// Ctrl+Space: normal mode to insert, an overlay closed or the board's orchestrator column
    /// focused, or insert to normal.
    fn toggleMode(app: *App) !void {
        app.dirty = true;
        if (app.normal) {
            app.normal = false;
        } else if (app.menu != null or app.prompt != null or app.overview != null) {
            app.menu = null;
            app.prompt = null;
            app.overview = null;
        } else if (app.board_view) |*view| {
            if (app.sideFocused()) {
                app.normal = true;
            } else if (app.sideDue() and !view.boxed()) {
                view.focus = .orchestrator;
            } else try app.closeBoard();
        } else app.normal = true;
    }

    /// The strip's keys in normal mode that are an Alt chord's too: `h` `l`, `1`…`9`, `H` `L` `J`
    /// `K`, `;` `'`, `c` a new window, `x` `z` `o` `w` `m`, `/` to jump, `n` the inbox, `g` the
    /// gate and `Q` to leave. `q` does nothing here.
    fn stripKey(app: *App, key: []const u8) !void {
        if (key.len != 1) return;
        switch (key[0]) {
            'h', 'l', 'H', 'L', 'J', 'K', ';', '\'', 'x', 'z', '1'...'9' => try app.onChord(key[0]),
            'c' => try app.onChord('\r'),
            'o' => app.openOverview(),
            'w' => app.toggleRail(),
            'm' => app.openMenu(&menu.main),
            '/' => {
                app.prompt = .{ .what = .jump };
                app.dirty = true;
            },
            'n' => try app.showInbox(),
            '?' => {
                app.strip_help = true;
                app.dirty = true;
            },
            'g' => {
                if (app.board_view == null) try app.toggleBoard();
                if (app.board_view != null) try app.gateModal();
            },
            'Q' => app.quit = true,
            else => {},
        }
    }

    /// An arrow is ESC, `[` or `O`, and one more byte; anything else, a bare Esc included, is a byte.
    fn keyLen(text: []const u8) usize {
        return if (text.len >= 3 and text[0] == 0x1b and (text[1] == '[' or text[1] == 'O')) 3 else 1;
    }

    fn menuKeys(app: *App, text: []const u8) !void {
        var i: usize = 0;
        while (i < text.len) {
            // a key that closed what had the keys leaves the rest of the read to the pane
            if (app.typing()) return app.forward(text[i..]);
            const len = keyLen(text[i..]);
            const key = text[i..][0..len];
            i += len;
            // a prompt opened over any of them, as the report's is, has the keys first
            const asking = app.prompt != null;
            if (app.normal and !asking) {
                if (app.strip_help) {
                    app.strip_help = false;
                    app.dirty = true;
                    continue;
                }
                if (app.popup != null) {
                    try app.popupKey(key);
                    continue;
                }
                if (app.hash_len != null) {
                    try app.hashKey(key);
                    continue;
                }
                if (app.board_view == null and anyKey(key, &.{"#"})) {
                    app.hash_len = 0;
                    app.dirty = true;
                    continue;
                }
                if (app.sideFocused() and try app.halfKey(key)) continue;
                if (app.sideFocused() and try app.feedKey(key)) continue;
                if (try app.railKey(key)) continue;
                if (std.mem.eql(u8, key, "i") or std.mem.eql(u8, key, "\x1b")) {
                    app.normal = false;
                    app.dirty = true;
                }
                if (std.mem.eql(u8, key, "b")) try app.goHome();
                if (std.mem.eql(u8, key, "B")) try app.toBoard();
                if (app.board_view == null) {
                    try app.stripKey(key);
                    // a key that opened a menu, prompt or overview leaves the rest of the read to it
                    if (app.overlay()) app.normal = false;
                }
            } else if (app.overview != null and !asking) {
                try app.overviewKey(key);
            } else if (app.board_view != null and !app.sideFocused() and !asking) {
                try app.boardKey(key);
            } else if (app.prompt) |*prompt| {
                app.dirty = true;
                switch (prompt.press(key)) {
                    .none => if (prompt.what == .find) app.refind(),
                    .cancel => if (prompt.what == .find) app.clearFind() else if (prompt.what == .words or prompt.what == .why or prompt.what == .tried) app.endWords() else {
                        app.prompt = null;
                    },
                    .commit => try app.commit(),
                    .up => prompt.selected -|= 1,
                    .down => {
                        var hits: [menu.jump_rows]Hit = undefined;
                        if (prompt.selected + 1 < app.jumpHits(prompt.text(), &hits)) prompt.selected += 1;
                    },
                }
            } else if (app.menu) |*open| try app.menuResult(open.press(key)) else unreachable;
        }
    }

    /// Enter in the prompt: goes to the window picked, or gives the focused window or the
    /// session the name typed, an empty one changing nothing.
    fn commit(app: *App) !void {
        const prompt = app.prompt orelse return;
        if (prompt.what == .search) return app.searchNext();
        if (prompt.what == .words) return app.sendWords(prompt);
        if (prompt.what == .why) return app.sendWhy(prompt);
        if (prompt.what == .tried) return app.sendTried(prompt);
        if (prompt.what == .find) return app.keepFind(prompt);
        app.prompt = null;
        if (prompt.what == .report) return app.fileReport(prompt.text());
        const s = app.cur() orelse return;
        var cmd: Writer.Allocating = .init(app.gpa);
        defer cmd.deinit();
        switch (prompt.what) {
            .jump => {
                var hits: [menu.jump_rows]Hit = undefined;
                const n = app.jumpHits(prompt.text(), &hits);
                if (prompt.selected < n) try app.jumpHit(hits[prompt.selected]);
                return;
            },
            .search, .report, .words, .why, .find, .tried => return,
            .window => try cmd.writer.print("rename-window -t @{d} -- '", .{(s.focused() orelse return).id}),
            .session => try cmd.writer.print("rename-session -t '${d}' -- '", .{s.id}),
        }
        if (prompt.len == 0) return;
        for (prompt.text()) |byte| {
            if (byte == '\'') try cmd.writer.writeAll("'\\''") else try cmd.writer.writeByte(byte);
        }
        try cmd.writer.writeAll("'");
        try app.send(.ignore, "{s}", .{cmd.written()});
    }

    /// Closes the active pane, asking first when it is the window's only one.
    fn closePane(app: *App) !void {
        const s = app.cur() orelse return;
        const win = s.focused() orelse return;
        const pane = win.activePane() orelse return;
        if (win.panes.items.len == 1) return app.openMenu(&menu.confirm);
        try app.send(.ignore, "kill-pane -t %{d}", .{pane.id});
    }

    fn menuResult(app: *App, result: menu.Menu.Result) !void {
        app.dirty = true;
        switch (result) {
            .none => {},
            .close => app.menu = null,
            .act => |action| {
                app.menu = null;
                switch (action) {
                    .new_window => try app.newWindow(),
                    .rename_window => app.prompt = .{ .what = .window },
                    .rename_session => app.prompt = .{ .what = .session },
                    .move_left => try app.swapBy(-1),
                    .move_right => try app.swapBy(1),
                    .full_width => app.toggleFull(),
                    .jump => app.prompt = .{ .what = .jump },
                    .overview => app.openOverview(),
                    .board => try app.toggleBoard(),
                    .rail_width => app.toggleRail(),
                    .report => try app.startReport(),
                    .split_right => try app.send(.ignore, "split-window -h -c '#{{pane_current_path}}'", .{}),
                    .split_below => try app.send(.ignore, "split-window -v -c '#{{pane_current_path}}'", .{}),
                    .browser => {
                        app.follow_active = true;
                        // without the variable a new tab opens terminal-browser.com
                        try app.send(.ignore, "new-window -a -n browser -e TERMINAL_BROWSER_START_PAGE=1 -c '#{{pane_current_path}}' terminal-browser terminal-browser://start", .{});
                    },
                    .close_pane => try app.closePane(),
                    .search => app.openSearch(),
                    .close_window => app.openMenu(&menu.confirm),
                    .confirm_close => try app.closeWindow(),
                    .confirm_close_session => try app.closeSession(app.doomed),
                    .new_session => try app.send(.ignore, "new-session", .{}),
                    .detach => app.quit = true,
                    .cancel => {},
                }
            },
        }
    }

    /// A window after the focused one, in its directory, and focus on it.
    fn newWindow(app: *App) !void {
        app.follow_active = true;
        try app.send(.ignore, "new-window -a -c '#{{pane_current_path}}'", .{});
    }

    /// Closes the focused window. A session's last window takes the session with it, and tmux
    /// would detach arena from a session that ends, so arena moves to a neighbour first.
    fn closeWindow(app: *App) !void {
        const s = app.cur() orelse return;
        const win = s.focused() orelse return;
        const id = win.id;
        if (s.wins.items.len == 1 and app.sessions.items.len > 1) {
            const at = app.sessionIndex(s.id) orelse 0;
            try app.sessionTo(if (at + 1 < app.sessions.items.len) at + 1 else at - 1);
        }
        try app.send(.ignore, "kill-window -t @{d}", .{id});
    }

    fn swapBy(app: *App, delta: i32) !void {
        const s = app.cur() orelse return;
        const next = @as(i32, @intCast(s.focus)) + delta;
        if (next < 0 or next >= s.wins.items.len) return;
        try app.moveWin(s, s.focus, @intCast(next));
    }

    /// What the pointer is over, in words.
    fn writeElement(app: *const App, w: *Writer) !void {
        const p = app.pointer;
        if (app.prompt != null) return w.writeAll("a prompt");
        if (app.menu != null) return w.writeAll("a menu");
        if (app.overview != null) {
            const spot = app.thumbUnder(p.x, p.y) orelse return w.writeAll("the overview");
            const s = app.sessions.items[spot.session];
            return w.print("the overview's picture of window {s} of session {s}", .{ s.wins.items[spot.win].name, s.name });
        }
        if (p.x < app.railDrawnW()) {
            if (app.railSession(p.y)) |i| return w.print("rail: session {s}", .{app.sessions.items[i].name});
            if (app.railAgentAt(p.y)) |line| switch (line) {
                .agent, .detail, .meta, .background => |a| return w.print("rail: the Claude in window {s}", .{a.win.name}),
                .session => |i| return w.print("rail: session {s}", .{app.sessions.items[i].name}),
                else => return w.writeAll("rail: the list of Claudes"),
            };
            if (p.y == app.railNewRow()) return w.writeAll("rail: + new");
            if (p.y == app.railMenuRow()) return w.writeAll("rail: ≡ menu");
            if (p.y == 1 and app.board != null) return w.writeAll("rail: the board row");
            return w.writeAll("the rail");
        }
        if (app.board_view) |view| {
            if (view.boxed()) return w.writeAll("a box over the board");
            if (p.x >= app.boardX() + app.boardW()) return w.writeAll(if (app.sided()) "the orchestrator column" else "the board's edge");
            var buttons: [48]Button = undefined;
            for (app.boardButtons(&buttons)) |button| if (button.hit(p.x, p.y)) {
                var label: [48]u8 = undefined;
                return w.print("board {s} {s}", .{ if (button.what == .card) "card action" else "header button", std.mem.trim(u8, app.buttonLabel(button, &label), " ") });
            };
            if (app.boardCardAt(p.x, p.y)) |at| {
                const card = if (app.boardLanes()) app.laneCard(at.lane, at.col, at.row) else app.boardCard(at.col, at.row);
                if (card) |c| return w.print("card #{d} {s}", .{ c.id, c.title });
            }
            return w.writeAll("the board's background");
        }
        const s = app.cur() orelse return w.writeAll("nothing");
        if (p.y == app.view_h) return w.writeAll("the dots under the strip");
        const ox: i32 = app.term_w - app.view_w;
        const hit = app.colAt(s, @as(i32, p.x) - ox + s.scroll) orelse return w.writeAll("the strip between windows");
        const win = s.wins.items[hit.index];
        if (p.y == 0) return w.print("the title of window {s}", .{win.name});
        const top = app.winTop(s, hit.index);
        if (hit.cx > 0 and p.y >= top) if (win.paneAt(hit.cx - 1, p.y - top)) |pane| return w.print("pane %{d} of window {s}", .{ pane.id, win.name });
        return w.print("window {s}", .{win.name});
    }

    /// Which view is showing.
    fn writeView(app: *const App, w: *Writer) !void {
        if (app.overview != null) return w.writeAll("overview");
        if (app.board_view) |view| {
            try w.writeAll(if (view.home) "home" else "board");
            if (view.backlog) try w.writeAll(", backlog") else if (app.boardRepo()) |repo| try w.print(", {s} only", .{repo});
            if (view.boxed()) try w.writeAll(", a box open");
            if (app.sided()) try w.print(", orchestrator column {s}", .{if (view.focus == .orchestrator) "focused" else "beside"});
            return;
        }
        const s = app.cur() orelse return w.writeAll("no session");
        try w.print("session {s}", .{s.name});
        if (s.focused()) |win| try w.print(", window {s}", .{win.name});
    }

    /// What is picked: the board's card, the column's feed item or the focused window.
    fn writePicked(app: *const App, w: *Writer) !void {
        if (app.board_view) |view| {
            if (view.focus == .orchestrator and app.sided()) return w.print("the orchestrator column's feed item {d}", .{view.pick});
            const card = if (app.boardLanes()) app.laneCard(view.lane, view.col, view.row) else app.boardCard(view.col, view.row);
            if (card) |c| return w.print("card #{d} {s}", .{ c.id, c.title });
            return w.writeAll("no card");
        }
        const s = app.cur() orelse return w.writeAll("nothing");
        if (s.focused()) |win| return w.print("window {s}", .{win.name});
        return w.writeAll("nothing");
    }

    /// Takes what arena shows and the last input for a report, and asks the human what is wrong.
    /// The screen is drawn again with nothing over it, to be read as text.
    fn startReport(app: *App) !void {
        app.menu = null;
        app.dirty = true;
        var shot: Writer.Allocating = .init(app.gpa);
        defer shot.deinit();
        // a frame hands the terminal what is queued for it and the pointer's shape: both stay due
        const queued = app.out;
        const due = app.shape_due;
        app.out = .empty;
        defer {
            app.out.deinit(app.gpa);
            app.out = queued;
            app.shape_due = due;
        }
        try draw.frame(app, &shot.writer, .all);

        var element: [200]u8 = undefined;
        var view: [120]u8 = undefined;
        var picked: [200]u8 = undefined;
        const strings = struct {
            fn of(buf: []u8, app_: *const App, comptime write: fn (*const App, *Writer) anyerror!void) []const u8 {
                var w: Writer = .fixed(buf);
                write(app_, &w) catch {};
                return w.buffered();
            }
        };
        var text: Writer.Allocating = .init(app.gpa);
        defer text.deinit();
        const w = &text.writer;
        try capture.writeSummary(w, .{
            .commit = build_options.commit,
            .cols = app.term_w,
            .rows = app.view_h + 1,
            .rail = if (app.rail == .wide) "wide" else "narrow",
            .mode = if (app.normal) "normal" else "insert",
            .view = strings.of(&view, app, writeView),
            .picked = strings.of(&picked, app, writePicked),
            .pointer = .{ .x = app.pointer.x, .y = app.pointer.y },
            .element = strings.of(&element, app, writeElement),
        });
        const summary_len = w.end;
        try w.writeAll("\ninput, oldest first:\n");
        try app.trail.write(w, app.now);
        try w.writeAll("\n");
        try capture.writeScreen(app.gpa, app.io, w, shot.written(), app.term_w, app.view_h + 1, app.pointer.x, app.pointer.y);
        if (app.report_text.len > 0) app.gpa.free(app.report_text);
        app.report_text = try text.toOwnedSlice();
        app.report_summary_len = summary_len;
        app.prompt = .{ .what = .report };
    }

    /// Writes the capture under a name no earlier report has: `{epoch}-{n}.txt`, n the next free
    /// number in that second.
    fn saveCapture(app: *App, line: []const u8, path_buf: []u8) !?[]const u8 {
        const dir = app.reports_dir orelse return null;
        var data: Writer.Allocating = .init(app.gpa);
        defer data.deinit();
        try data.writer.print("what's wrong: {s}\n", .{line});
        try data.writer.writeAll(app.report_text);
        std.Io.Dir.cwd().createDirPath(app.io, dir) catch return null;
        for (0..1000) |n| {
            const path = std.fmt.bufPrint(path_buf, "{s}/{d}-{d}.txt", .{ dir, app.epoch, n }) catch return null;
            std.Io.Dir.cwd().writeFile(app.io, .{ .sub_path = path, .data = data.written(), .flags = .{ .exclusive = true } }) catch |err| switch (err) {
                error.PathAlreadyExists => continue,
                else => return null,
            };
            return path;
        }
        return null;
    }

    /// Saves the capture beside the reports before it and files a ticket in arena with the
    /// human's line and what the capture says first; an empty line files nothing.
    fn fileReport(app: *App, line: []const u8) !void {
        if (line.len == 0) return;
        var path_buf: [std.fs.max_path_bytes]u8 = undefined;
        const saved = try app.saveCapture(line, &path_buf);
        var body: Writer.Allocating = .init(app.gpa);
        defer body.deinit();
        try body.writer.print("{s}\n\nFiled by arena's report key.\n\n{s}", .{ line, app.report_text[0..app.report_summary_len] });
        if (saved) |path| try body.writer.print("capture, with the screen as text and the last input: {s}\n", .{path});
        _ = try app.runNeed("report", &.{ "babylon", "file", line, "--repo", "arena", "--body", body.written() });
    }

    /// Records what was typed, as it came: arena's own keys are kept, a pane's only counted.
    fn trailText(app: *App, text: []const u8) void {
        if (text.len == 0) return;
        if (app.typing()) app.trail.push(app.now, .{ .to_pane = text.len }) else app.trail.pushKeys(app.now, text);
    }

    fn onChord(app: *App, letter: u8) !void {
        if (letter == '!') return if (app.prompt == null) app.startReport();
        if (app.menu == null and app.prompt == null and app.sideDue()) {
            const view = &app.board_view.?;
            const s = app.sessionById(app.bound()).?;
            const at_board = view.focus == .board;
            // the board is the column before the orchestrator's first
            if (!view.boxed() and ((at_board and letter == 'l') or (!at_board and letter == 'h' and s.focus == 0))) {
                view.focus = if (at_board) .orchestrator else .board;
                app.dirty = true;
                return;
            }
            if (app.sideFocused() and (letter == 'h' or letter == 'l')) return app.focusBy(if (letter == 'h') -1 else 1);
        }
        if (app.overlay()) {
            app.menu = null;
            app.prompt = null;
            app.overview = null;
            if (app.board_view != null) try app.closeBoard();
            app.dirty = true;
            return;
        }
        switch (letter) {
            'h' => try app.focusBy(-1),
            'l' => try app.focusBy(1),
            'k' => try app.sessionBy(-1),
            'J' => try app.sessionSwapBy(1),
            'K' => try app.sessionSwapBy(-1),
            'H' => try app.swapBy(-1),
            'L' => try app.swapBy(1),
            'x' => app.openMenu(&menu.confirm),
            'q' => app.quit = true,
            'z' => app.toggleFull(),
            ';' => try app.widenBy(-share_step),
            '\'' => try app.widenBy(share_step),
            'b' => try app.toggleBoard(),
            'n' => try app.stepAgent(1),
            'N' => try app.stepAgent(-1),
            '/' => app.openSearch(),
            '\r' => try app.newWindow(),
            else => if (app.sessionById(app.bound())) |s| {
                if (letter - '1' < s.wins.items.len) try app.focusIn(s, letter - '1');
            },
        }
    }

    /// With Alt: h and l move along the strip, k to the session before, 1 to 9 go to a window,
    /// J and K move the session down and up the rail,
    /// H and L move the window, ; and ' make it narrower and wider, Enter opens one, x closes
    /// it, z gives it the whole width, b babylon's board, n and N step the Claudes, /
    /// searches the pane's history and q leaves. The rest is normal mode's.
    /// Everything else is the focused pane's, or the menu's while it is open. Alt is ESC and the
    /// letter together, which a typed Escape then a letter rarely is.
    ///
    /// Returns how many bytes at the end of `bytes` to pass again in front of the next read.
    pub fn onInput(app: *App, bytes: []const u8) !usize {
        var rest = bytes;
        while (rest.len > 0 and !app.quit) {
            const part = keys.next(rest);
            rest = part.rest;
            app.trailText(part.text);
            // the terminal's answers to arena's own questions are no key of the human's
            if (part.event == null or part.event.? != .osc) app.clearReportSaid();
            const taken = part.text.len > 0 and try app.lookKey(part.text);
            if (!taken) {
                if (app.typing()) try app.forward(part.text) else try app.menuKeys(part.text);
            }
            defer app.settleMode();
            if (part.event) |event| switch (event) {
                .chord, .mode => _ = try app.lookKey(""),
                else => {},
            };
            switch (part.event orelse return part.held.len) {
                .mouse => |m| {
                    app.trail.push(app.now, .{ .mouse = m });
                    try app.onMouse(m);
                },
                .chord => |letter| {
                    app.trail.push(app.now, .{ .chord = letter });
                    try app.onChord(letter);
                },
                .mode => {
                    app.trail.push(app.now, .mode);
                    try app.toggleMode();
                },
                .osc => |body| {
                    app.palette.answer(body);
                    app.dirty = true;
                    if (std.mem.startsWith(u8, body, "10;") or std.mem.startsWith(u8, body, "11;")) {
                        app.colors_known += 1;
                        try app.tellColors();
                    }
                },
                .graphics => |reply| if (app.paneById(app.asker)) |pane| try app.sendKeys(pane, reply),
            }
        }
        return 0;
    }

    /// Held input that turned out to be all there was, typed as it is.
    pub fn typedAlone(app: *App, bytes: []const u8) !void {
        app.trailText(bytes);
        if (try app.lookKey(bytes)) return;
        if (app.typing()) try app.forward(bytes) else try app.menuKeys(bytes);
        app.settleMode();
    }

    fn forward(app: *App, bytes: []const u8) !void {
        const s = app.sessionById(app.bound()) orelse return;
        const win = s.focused() orelse return;
        const pane = win.activePane() orelse return;
        if (bytes.len == 0) return;
        pane.term.screens.active.clearSelection();
        pane.term.scrollViewport(.bottom);
        app.dirty = true;
        try app.sendKeys(pane, bytes);
    }

    /// tmux answers a program's question for its foreground and background with what the client
    /// reported for the pane, and a control client that reported nothing gets black for both.
    fn tellColors(app: *App) !void {
        if (app.colors_known == 0) return;
        const fg = app.palette.fg;
        const bg = app.palette.bg;
        for (app.sessions.items) |s| for (s.wins.items) |win| for (win.panes.items) |pane| {
            if (pane.colors_told == app.colors_known) continue;
            pane.colors_told = app.colors_known;
            try app.send(.ignore, "refresh-client -r \"%{d}:\\033]10;rgb:{x:0>2}/{x:0>2}/{x:0>2}\\033\\\\\"", .{ pane.id, fg.r, fg.g, fg.b });
            try app.send(.ignore, "refresh-client -r \"%{d}:\\033]11;rgb:{x:0>2}/{x:0>2}/{x:0>2}\\033\\\\\"", .{ pane.id, bg.r, bg.g, bg.b });
        };
    }

    fn sendKeys(app: *App, pane: *const Pane, bytes: []const u8) !void {
        var cmd: Writer.Allocating = .init(app.gpa);
        defer cmd.deinit();
        // a pane left in a mode, by tmux's own output or the human's, takes the keys itself
        try app.send(.ignore, "if-shell -F -t %{d} \"#{{pane_in_mode}}\" \"send-keys -t %{d} -X cancel\"", .{ pane.id, pane.id });
        try cmd.writer.print("send-keys -H -t %{d}", .{pane.id});
        for (bytes) |b| try cmd.writer.print(" {x:0>2}", .{b});
        try app.send(.ignore, "{s}", .{cmd.written()});
    }
};

/// The numbered options of Claude Code's own question on `pane`'s screen, `1. Yes` and the like
/// under a marker or not, the last such list, with the line over them as the question.
fn screenAsk(pane: *const Pane, out: *App.Asked) bool {
    const rows = pane.render.row_data.items(.cells)[pane.render.viewportStart()..];
    const Span = struct { at: usize, len: usize };
    var spans: [64]Span = undefined;
    var n: usize = 0;
    var used: usize = 0;
    for (rows[rows.len -| spans.len..]) |row| {
        const start = used;
        for (row.items(.raw)) |raw| {
            if (raw.wide == .spacer_tail) continue;
            const cp: u21 = if (raw.hasText() and raw.content.codepoint.data != 0) raw.content.codepoint.data else ' ';
            const room = out.text.len - used;
            const len = std.unicode.utf8CodepointSequenceLength(cp) catch 1;
            if (len > room or used - start >= 160) break;
            used += std.unicode.utf8Encode(cp, out.text[used..]) catch 0;
        }
        const line = std.mem.trim(u8, out.text[start..used], " ");
        spans[n] = .{ .at = @intFromPtr(line.ptr) - @intFromPtr(&out.text), .len = line.len };
        n += 1;
    }
    var found = false;
    var i: usize = 0;
    while (i < n) : (i += 1) {
        const first = optionText(out.text[spans[i].at..][0..spans[i].len], 1) orelse continue;
        var count: usize = 1;
        var options: [9][]const u8 = undefined;
        options[0] = first;
        while (i + count < n and count < 9) : (count += 1) {
            options[count] = optionText(out.text[spans[i + count].at..][0..spans[i + count].len], count + 1) orelse break;
        }
        if (count < 2) continue;
        found = true;
        out.n = count;
        out.options = options;
        var q = i;
        out.question = "";
        while (q > 0) {
            q -= 1;
            if (spans[q].len > 0) {
                out.question = out.text[spans[q].at..][0..spans[q].len];
                break;
            }
        }
        i += count - 1;
    }
    return found;
}

/// The text of option `number` of a list on a line: `2. No`, or `❯ 2. No` with the pointer.
fn optionText(line: []const u8, number: usize) ?[]const u8 {
    var rest = line;
    for ([_][]const u8{ "❯ ", "› ", "> " }) |pointer| {
        if (std.mem.startsWith(u8, rest, pointer)) rest = rest[pointer.len..];
    }
    if (rest.len < 3 or rest[0] != '0' + @as(u8, @intCast(number)) or rest[1] != '.' or rest[2] != ' ') return null;
    return std.mem.trim(u8, rest[3..], " ");
}

/// Where the list of agents Claude Code draws at the foot of its screen has a subagent: whether
/// it is the one shown, and how many rows under the list's pointer it is, null while the list has
/// no pointer.
const Listed = struct { shown: bool, below: ?i32 };

/// The row of `pane`'s list of agents for the subagent described `name`, null when it has none.
/// A row has the pointer or two spaces, `●` for the one shown or `◯`, and the agent.
fn listedSub(pane: *const Pane, name: []const u8) ?Listed {
    const screen = pane.term.screens.active;
    var buf: [1024]u8 = undefined;
    var found: ?struct { y: i32, shown: bool } = null;
    var pointer: ?i32 = null;
    var in_list = false;
    var y: i32 = pane.term.rows;
    while (y > 0) {
        y -= 1;
        const start = screen.pages.pin(.{ .active = .{ .x = 0, .y = @intCast(y) } }) orelse break;
        var end = start;
        end.x = pane.term.cols - 1;
        var row: Writer = .fixed(&buf);
        screen.dumpString(&row, .{ .tl = start, .br = end, .unwrap = false }) catch {};
        const text = std.mem.trimEnd(u8, row.buffered(), " \n");
        if (text.len == 0 and !in_list) continue;
        const pointed = std.mem.startsWith(u8, text, "❯ ");
        const marked = if (pointed) text["❯ ".len..] else if (std.mem.startsWith(u8, text, "  ")) text[2..] else break;
        const shown = std.mem.startsWith(u8, marked, "● ");
        if (!shown and !std.mem.startsWith(u8, marked, "◯ ")) break;
        in_list = true;
        if (pointed) pointer = y;
        if (rowNames(marked["● ".len..], name)) found = .{ .y = y, .shown = shown };
    }
    const at = found orelse return null;
    return .{ .shown = at.shown, .below = if (pointer) |p| at.y - p else null };
}

/// Whether a row of Claude Code's list of agents, from its agent's type on, is of the subagent
/// described `name`: the type, two spaces, the description, cut with an ellipsis where the pane
/// is narrow, and how long it has run.
fn rowNames(row: []const u8, name: []const u8) bool {
    const gap = std.mem.indexOf(u8, row, "  ") orelse return false;
    const rest = row[gap + 2 ..];
    if (std.mem.startsWith(u8, rest, name)) return rest.len == name.len or std.mem.startsWith(u8, rest[name.len..], "  ");
    const cut = std.mem.indexOf(u8, rest, "…") orelse return false;
    return cut > 0 and std.mem.startsWith(u8, name, rest[0..cut]);
}

test "a row of Claude Code's list of agents is a subagent's by its description" {
    try std.testing.expect(rowNames("general-purpose  Sleep ninety        8s · ↓ 54.0k tokens", "Sleep ninety"));
    try std.testing.expect(rowNames("Explore  Sleep ninety", "Sleep ninety"));
    try std.testing.expect(rowNames("general-purpose  Sleep… 43s · ↓ 58.1k tokens", "Sleep ninety"));
    try std.testing.expect(!rowNames("general-purpose  Sleep ninety one  8s", "Sleep ninety"));
    try std.testing.expect(!rowNames("general-purpose  Sleep eighty  8s · ↓ 5…", "Sleep ninety"));
    try std.testing.expect(!rowNames("main", "main"));
}

/// The stages of a gate run, in the order babylon takes them.
pub const gate_stages = [_][]const u8{ "rebase", "gate", "review", "land", "install" };

/// One stage of a gate run as `babylon gate` writes it: its result word, when it started and
/// ended, and the lines indented under it with their indent.
pub const GateStage = struct { result: []const u8, start: ?[]const u8, end: ?[]const u8, body: []const u8 };

/// The last run of `babylon gate`'s text: from its final `run` line to the end.
pub fn gateLastRun(text: []const u8) []const u8 {
    const at = std.mem.lastIndexOf(u8, text, "\nrun ") orelse return text;
    return text[at + 1 ..];
}

/// Stage `name` in `run`, `  name: result (start to end)` and the lines under it.
pub fn gateStage(run: []const u8, name: []const u8) ?GateStage {
    var at: usize = 0;
    while (at < run.len) {
        const end = std.mem.indexOfScalarPos(u8, run, at, '\n') orelse run.len;
        const line = run[at..end];
        const next = @min(end + 1, run.len);
        defer at = next;
        if (line.len <= 3 + name.len or !std.mem.startsWith(u8, line, "  ") or line[2] == ' ') continue;
        if (!std.mem.startsWith(u8, line[2..], name) or line[2 + name.len] != ':') continue;
        const rest = std.mem.trim(u8, line[3 + name.len ..], " ");
        const paren = std.mem.indexOfScalar(u8, rest, '(');
        const result = std.mem.trim(u8, rest[0 .. paren orelse rest.len], " ");
        var start: ?[]const u8 = null;
        var stop: ?[]const u8 = null;
        if (paren) |open| {
            const inside = std.mem.trimEnd(u8, rest[open + 1 ..], ") ");
            if (std.mem.indexOf(u8, inside, " to ")) |sep| {
                start = inside[0..sep];
                stop = std.mem.trim(u8, inside[sep + 4 ..], " ");
            } else start = inside;
        }
        var body_end = next;
        while (body_end < run.len and std.mem.startsWith(u8, run[body_end..], "    ")) {
            body_end = @min((std.mem.indexOfScalarPos(u8, run, body_end, '\n') orelse run.len) + 1, run.len);
        }
        return .{ .result = result, .start = start, .end = if (stop != null and stop.?.len > 0) stop else null, .body = run[next..body_end] };
    }
    return null;
}

/// What a gate run's modal scrolls: the output of the first stage that failed, else the review's
/// once it has ended.
pub fn gateOutput(run: []const u8) []const u8 {
    var review: []const u8 = "";
    for (gate_stages) |name| {
        const stage = gateStage(run, name) orelse continue;
        if (std.mem.eql(u8, stage.result, "failed") or std.mem.eql(u8, stage.result, "error")) return std.mem.trimEnd(u8, stage.body, "\n");
        if (std.mem.eql(u8, name, "review") and stage.end != null) review = std.mem.trimEnd(u8, stage.body, "\n");
    }
    return review;
}

/// The rows `output` takes in `inner` cells, each line's indent under its stage taken off.
pub fn gateOutputRows(output: []const u8, inner: usize) usize {
    var n: usize = 0;
    var lines = std.mem.splitScalar(u8, output, '\n');
    while (lines.next()) |raw| {
        var wrapped = DetailLines.init(if (std.mem.startsWith(u8, raw, "    ")) raw[4..] else raw, inner);
        var any = false;
        while (wrapped.next()) |_| {
            any = true;
            n += 1;
        }
        if (!any) n += 1;
    }
    return n;
}

/// How long ago `secs` seconds is, as a wait reads: `45s`, `12m`, `3h`, `2d`.
pub fn waited(buf: []u8, secs: i64) []const u8 {
    const s = @max(0, secs);
    return (if (s < 60) std.fmt.bufPrint(buf, "{d}s", .{s}) else if (s < 3600) std.fmt.bufPrint(buf, "{d}m", .{@divFloor(s, 60)}) else if (s < 86400) std.fmt.bufPrint(buf, "{d}h", .{@divFloor(s, 3600)}) else std.fmt.bufPrint(buf, "{d}d", .{@divFloor(s, 86400)})) catch "";
}

/// The detail box's width, and the text's within its border.
pub fn detailWidth(view_w: u16) struct { box: u16, inner: u16 } {
    const box = @min(view_w -| 4, 100);
    return .{ .box = box, .inner = box -| 4 };
}

/// A card's title on two rows of `width`: the first cut at its last space that fits, the second
/// the rest, for the drawing to cut.
pub fn titleLines(title: []const u8, width: usize) [2][]const u8 {
    var it = std.unicode.Utf8View.initUnchecked(title).iterator();
    var n: usize = 0;
    while (n < width) : (n += 1) _ = it.nextCodepointSlice() orelse return .{ title, "" };
    if (it.i == title.len) return .{ title, "" };
    const cut = if (title[it.i] == ' ') it.i else std.mem.lastIndexOfScalar(u8, title[0..it.i], ' ') orelse it.i;
    return .{ std.mem.trimEnd(u8, title[0..cut], " "), std.mem.trimStart(u8, title[cut..], " ") };
}

/// A title wrapped to `width` characters a line at a time, cut at spaces where it can.
pub const TitleLines = struct {
    rest: []const u8,
    width: usize,

    pub fn init(title: []const u8, width: usize) TitleLines {
        return .{ .rest = title, .width = @max(1, width) };
    }

    pub fn next(it: *TitleLines) ?[]const u8 {
        if (it.rest.len == 0) return null;
        const lines = titleLines(it.rest, it.width);
        if (lines[0].len == 0) return null;
        it.rest = lines[1];
        return lines[0];
    }
};

/// A card's detail as the box shows it: each of its lines cut to `inner` characters and run on
/// under one another, the space at a cut dropped.
pub const DetailLines = struct {
    lines: std.mem.SplitIterator(u8, .scalar),
    rest: ?[]const u8 = null,
    inner: usize,

    pub fn init(text: []const u8, inner: usize) DetailLines {
        return .{ .lines = std.mem.splitScalar(u8, std.mem.trimEnd(u8, text, "\n"), '\n'), .inner = inner };
    }

    pub fn next(it: *DetailLines) ?[]const u8 {
        const rest = it.rest orelse it.lines.next() orelse return null;
        var cut = std.unicode.Utf8View.initUnchecked(rest).iterator();
        var n: usize = 0;
        while (n < it.inner) : (n += 1) _ = cut.nextCodepointSlice() orelse break;
        const line = rest[0..cut.i];
        const after = std.mem.trimStart(u8, rest[cut.i..], " ");
        it.rest = if (after.len > 0 and line.len > 0) after else null;
        return line;
    }
};

/// The cells `text` takes, a character a cell.
pub fn cellCount(text: []const u8) usize {
    return std.unicode.utf8CountCodepoints(text) catch text.len;
}

/// The number of the ticket a branch named `t<number>-...` works, null for any other branch.
pub fn branchTicket(branch: []const u8) ?[]const u8 {
    if (branch.len < 2 or branch[0] != 't') return null;
    var n: usize = 1;
    while (n < branch.len and std.ascii.isDigit(branch[n])) n += 1;
    if (n == 1 or (n < branch.len and branch[n] != '-')) return null;
    return branch[1..n];
}

/// `arg` as one argument of a tmux command: in double quotes, with `\`, `"` and `$` escaped and
/// `#` doubled, which tmux would read as a format.
fn tmuxQuote(w: *Writer, arg: []const u8) !void {
    try w.writeByte('"');
    for (arg) |c| switch (c) {
        '#' => try w.writeAll("##"),
        '\\', '"', '$' => try w.print("\\{c}", .{c}),
        else => try w.writeByte(c),
    };
    try w.writeByte('"');
}

test tmuxQuote {
    var out: Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try tmuxQuote(&out.writer, "a \"b\" $c #d\\");
    try std.testing.expectEqualStrings("\"a \\\"b\\\" \\$c ##d\\\\\"", out.written());
}

/// `arg` as one word to the shell, whatever is in it.
fn shellQuote(w: *Writer, arg: []const u8) !void {
    try w.writeByte('\'');
    for (arg) |c| if (c == '\'') try w.writeAll("'\\''") else try w.writeByte(c);
    try w.writeByte('\'');
}

test shellQuote {
    var out: Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try shellQuote(&out.writer, "{\"id\":27} it's");
    try std.testing.expectEqualStrings("'{\"id\":27} it'\\''s'", out.written());
}

/// A card babylon would let a Claude claim, or start one on: to do, held by no one, waiting on
/// nothing, and no epic. babylon says why when it refuses what this lets through.
fn givable(card: *const tickets.Card) bool {
    return card.holder() == null and card.status == .todo and card.blocked_by.len == 0 and !std.mem.eql(u8, card.kind, "epic");
}

test "hand off is a doing card's action while a Claude holds it, and no other card's" {
    var have: [12]App.CardAction = undefined;
    var c: tickets.Card = .{ .id = 1, .title = "a", .status = .doing, .claimed_by = "%3" };
    try std.testing.expect(std.mem.indexOfScalar(App.CardAction, App.cardActions(&c, &have), .handoff) != null);
    c.claimed_by = null;
    try std.testing.expect(std.mem.indexOfScalar(App.CardAction, App.cardActions(&c, &have), .handoff) == null);
    c.claimed_by = "%3";
    c.status = .todo;
    try std.testing.expect(std.mem.indexOfScalar(App.CardAction, App.cardActions(&c, &have), .handoff) == null);
}

test "a card is given only while it is free to claim, whatever its repo" {
    const free: tickets.Card = .{ .id = 1, .title = "a", .status = .todo };
    try std.testing.expect(givable(&free));
    var c = free;
    c.blocked_by = &.{2};
    try std.testing.expect(!givable(&c));
    c = free;
    c.claimed_by = "%3";
    try std.testing.expect(!givable(&c));
    c = free;
    c.handed_to = "%3";
    try std.testing.expect(!givable(&c));
    c = free;
    c.status = .backlog;
    try std.testing.expect(!givable(&c));
    c = free;
    c.kind = "epic";
    try std.testing.expect(!givable(&c));
}

/// A repo's name safe in a tmux command unquoted, as directory names are.
fn plainName(name: []const u8) bool {
    for (name) |c| if (!std.ascii.isAlphanumeric(c) and c != '-' and c != '_' and c != '.') return false;
    return name.len > 0;
}

test "the session to go back to is forgotten once it, or the orchestrator's, is gone, the column keeping the keys" {
    var app: App = .{ .gpa = std.testing.allocator, .io = undefined, .tmux_in = undefined };
    defer app.deinit();
    app.current = 2;
    const eq = std.testing.expectEqual;

    app.board_view = .{ .back = 1, .focus = .orchestrator };
    try app.onSessions("$1 0 work\n$2 1 orchestrator\n");
    try eq(@as(?u32, 1), app.board_view.?.back);
    try eq(.orchestrator, app.board_view.?.focus);

    try app.onSessions("$2 1 orchestrator\n");
    try eq(@as(?u32, null), app.board_view.?.back);

    app.board_view.?.back = 1;
    try app.onSessions("$1 0 work\n");
    try eq(@as(?u32, null), app.board_view.?.back);
    try eq(.orchestrator, app.board_view.?.focus);
}

test "home: the board with the orchestrator's column focused, its own keys while no window is in it" {
    var app: App = .{ .gpa = std.testing.allocator, .io = undefined, .tmux_in = undefined };
    defer app.deinit();
    const expect = std.testing.expect;
    try app.goHome();
    try expect(app.board_view == null);

    app.board = try tickets.Board.parse(std.testing.allocator,
        \\{"tickets":[{"id":1,"repo":"arena","title":"a","status":"todo"}]}
    );
    app.normal = true;
    try app.goHome();
    try expect(app.board_view.?.home and app.board_view.?.focus == .orchestrator);
    try expect(app.sided() and app.columnFocused() and !app.normal);
    try expect(!app.typing());
    try expect(app.orchestratorState() == .off);
    _ = try app.onInput("h");
    try expect(app.board_view.?.focus == .board and !app.columnFocused());

    app.board_view.?.focus = .orchestrator;
    app.board_view.?.help = true;
    const was = app.kept().?;
    try expect(!was.view.help and was.view.home and was.view.focus == .orchestrator);
    app.board_view.?.help = false;
    _ = try app.onInput("q");
    try expect(app.board_view == null);
    try app.restore(was);
    try expect(app.board_view.?.home and app.columnFocused());
}

test "a stalled Claude outranks one waiting, says its error, and draws its own glyph" {
    var stalled: Window = .{ .id = 1, .name = @constCast("a"), .claude = .stalled, .info = @constCast("\t\t\tYou are out of usage credits.") };
    var waiting: Window = .{ .id = 2, .name = @constCast("b"), .claude = .waiting };
    var wins = [_]*Window{ &waiting, &stalled };
    var s: Session = .{ .id = 1, .name = @constCast("s") };
    s.wins = .fromOwnedSlice(&wins);
    try std.testing.expectEqual(Mark.stalled, App.sessionMark(&s));
    try std.testing.expectEqual(@as(usize, 1), App.sessionCount(&s));
    try std.testing.expectEqualStrings("You are out of usage credits.", stalled.detail());
}

test "the column's head says the orchestrator's state: its Claude's, else restarting while babylon keeps it on, else off" {
    var orch: Session = .{ .id = 2, .name = @constCast("orchestrator") };
    var win: Window = .{ .id = 1, .name = @constCast("orch") };
    var wins = [_]*Window{&win};
    orch.wins = .fromOwnedSlice(&wins);
    var sessions = [_]*Session{&orch};
    var app: App = .{ .gpa = std.testing.allocator, .io = undefined, .tmux_in = undefined };
    const eq = std.testing.expectEqual;
    try eq(.off, app.orchestratorState());
    app.board = try tickets.Board.parse(std.testing.allocator,
        \\{"tickets":[],"orchestrator":{"on":true,"running":false}}
    );
    defer app.board.?.deinit();
    try eq(.restarting, app.orchestratorState());
    app.sessions = .fromOwnedSlice(&sessions);
    try eq(.idle, app.orchestratorState());
    win.claude = .working;
    try eq(.working, app.orchestratorState());
    win.claude = .waiting;
    try eq(.waiting, app.orchestratorState());
    win.claude = .stalled;
    try eq(.stalled, app.orchestratorState());
    app.sessions = .empty;
    app.board.?.deinit();
    app.board = try tickets.Board.parse(std.testing.allocator,
        \\{"tickets":[],"orchestrator":{"on":false,"running":false}}
    );
    try eq(.off, app.orchestratorState());
}

test "a dragged card moves todo↔backlog and todo↔done, and a drop babylon would refuse says why and stays" {
    const eq = std.testing.expectEqual;
    try eq(App.CardDrop.stay, App.cardDrop(.todo, .todo));
    try std.testing.expectEqualStrings("backlog", App.cardDrop(.todo, .backlog).status);
    try std.testing.expectEqualStrings("todo", App.cardDrop(.backlog, .todo).status);
    try std.testing.expectEqualStrings("done", App.cardDrop(.todo, .done).status);
    try std.testing.expectEqualStrings("todo", App.cardDrop(.done, .todo).status);
    for ([_][2]tickets.Status{ .{ .doing, .done }, .{ .review, .todo }, .{ .todo, .doing }, .{ .done, .review }, .{ .backlog, .done }, .{ .done, .backlog } }) |pair| {
        try std.testing.expect(App.cardDrop(pair[0], pair[1]) == .refuse);
    }

    var app: App = .{ .gpa = std.testing.allocator, .io = undefined, .tmux_in = undefined };
    defer app.deinit();
    app.term_w = 100;
    app.view_w = 100;
    app.view_h = 30;
    app.board = try tickets.Board.parse(std.testing.allocator,
        \\{"tickets":[{"id":1,"repo":"arena","title":"a","status":"doing"},{"id":2,"repo":"arena","title":"b","status":"todo"}]}
    );
    app.board_view = .{};
    try app.dropCard(1, .done);
    try std.testing.expect(app.report_failed);
    try std.testing.expect(std.mem.startsWith(u8, app.report_said.?, "only a todo card"));
    app.pointer = .{ .x = app.boardColX(1) + 2, .y = app.colTop() + 1 };
    try eq(@as(?tickets.Status, .doing), app.cardTarget());
    app.pointer = .{ .x = app.boardX(), .y = 0 };
    try eq(@as(?tickets.Status, null), app.cardTarget());
}

test "a press on a card arms its drag, the picked one's included, with or without a session, and a drop babylon refuses says why" {
    var app: App = .{ .gpa = std.testing.allocator, .io = undefined, .tmux_in = undefined };
    defer app.deinit();
    app.term_w = 100;
    app.view_w = 100;
    app.view_h = 30;
    app.board = try tickets.Board.parse(std.testing.allocator,
        \\{"tickets":[{"id":1,"repo":"arena","title":"a","status":"todo"},{"id":2,"repo":"arena","title":"b","status":"todo"}]}
    );
    app.board_view = .{};
    const eq = std.testing.expectEqual;
    const x = app.boardColX(0) + 2;
    var first: u16 = 0;
    var second: u16 = 0;
    for (app.colTop()..app.listH()) |y| if (app.boardCardAt(x, @intCast(y))) |at| {
        if (at.row == 0 and first == 0) first = @intCast(y);
        if (at.row == 1 and second == 0) second = @intCast(y);
    };
    try std.testing.expect(first > 0 and second > 0);

    // the picked card: armed to open on a let go without a move
    try std.testing.expect(try app.boardMouse(.{ .code = 0, .x = x, .y = first, .release = false }));
    try eq(@as(u32, 1), app.drag.card.id);
    try std.testing.expect(app.drag.card.opens);

    // dragged over doing, no session in the app: a drag all the same, and the drop is refused with its why
    app.pointer = .{ .x = app.boardColX(1) + 2, .y = app.colTop() + 1 };
    try app.dragTo(.{ .code = 32, .x = app.pointer.x, .y = app.pointer.y, .release = false });
    try std.testing.expect(app.drag.card.moved);
    try app.dragTo(.{ .code = 0, .x = app.pointer.x, .y = app.pointer.y, .release = true });
    try eq(@as(@TypeOf(app.drag), .none), app.drag);
    try std.testing.expect(app.report_failed);
    try std.testing.expect(std.mem.startsWith(u8, app.report_said.?, "doing and review"));

    // another card: picked by the press, which is not armed to open
    try std.testing.expect(try app.boardMouse(.{ .code = 0, .x = x, .y = second, .release = false }));
    try eq(@as(u32, 2), app.drag.card.id);
    try std.testing.expect(!app.drag.card.opens);
    try eq(@as(usize, 1), app.board_view.?.row);
}

test "a click on a key of the foot bar does what the key does, and half width keeps fewer keys" {
    var app: App = .{ .gpa = std.testing.allocator, .io = undefined, .tmux_in = undefined };
    defer app.deinit();
    app.term_w = 100;
    app.view_w = 100;
    app.view_h = 30;
    app.roles = @import("parts.zig").roles();
    app.board = try tickets.Board.parse(std.testing.allocator,
        \\{"tickets":[{"id":1,"repo":"arena","title":"a","status":"todo"}]}
    );
    app.board_view = .{};
    var bar_keys: [24]App.BarKey = undefined;
    const half = app.keyBar(&bar_keys).len;
    try std.testing.expect(half >= 5);
    app.term_w = 200;
    app.view_w = 200;
    try std.testing.expect(app.keyBar(&bar_keys).len > half);
    app.term_w = 100;
    app.view_w = 100;
    const bar = app.keyBar(&bar_keys);
    const help = bar[bar.len - 1];
    try std.testing.expectEqualStrings("?", help.key);
    try std.testing.expectEqual(true, try app.boardMouse(.{ .code = 0, .x = help.x + 1, .y = app.view_h - 1, .release = false }));
    try std.testing.expectEqual(true, app.board_view.?.help);
}

test "in the backlog a card let go on a repo's tab is bound for todo" {
    var app: App = .{ .gpa = std.testing.allocator, .io = undefined, .tmux_in = undefined };
    defer app.deinit();
    app.term_w = 100;
    app.view_w = 100;
    app.view_h = 30;
    app.roles = @import("parts.zig").roles();
    app.board = try tickets.Board.parse(std.testing.allocator,
        \\{"tickets":[{"id":2,"repo":"tlon","title":"b","status":"todo"}],"backlog":[{"id":1,"repo":"arena","title":"a","status":"backlog"}]}
    );
    app.board_view = .{ .backlog = true };
    var seen: ?u16 = null;
    for (app.colTop()..app.listH()) |y| if (app.boardCardAt(app.boardColX(0) + 3, @intCast(y))) |_| {
        seen = @intCast(y);
    };
    try std.testing.expectEqual(true, try app.boardMouse(.{ .code = 0, .x = app.boardColX(0) + 3, .y = seen.?, .release = false }));
    try std.testing.expectEqual(@as(u32, 1), app.drag.card.id);
    try app.dragTo(.{ .code = 32, .x = 5, .y = 2, .release = false });
    try std.testing.expectEqual(true, app.drag.card.moved);
    var buttons: [48]App.Button = undefined;
    for (app.boardButtons(&buttons)) |b| if (b.what == .repo) {
        app.pointer = .{ .x = b.x + 1, .y = b.y };
        try std.testing.expectEqual(@as(?tickets.Status, .todo), app.cardTarget());
        return;
    };
    return error.NoRepoTab;
}

test "a refused report says babylon's reason, a filed one its number, and both go with the next key" {
    var app: App = .{ .gpa = std.testing.allocator, .io = undefined, .tmux_in = undefined };
    defer app.deinit();
    try app.reportAnswered("no babylon: repo arena is held\nmore\n");
    try std.testing.expectEqualStrings("babylon: repo arena is held", app.report_said.?);
    try std.testing.expect(app.report_failed);
    try app.reportAnswered("ok #741 the thing\n");
    try std.testing.expectEqualStrings("filed #741", app.report_said.?);
    try std.testing.expect(!app.report_failed);
    try app.reportAnswered("ok \n");
    try std.testing.expectEqualStrings("filed", app.report_said.?);
    try std.testing.expect(!app.report_failed);
}

test "two reports in one second keep two captures" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir_len = try tmp.dir.realPath(std.testing.io, &dir_buf);
    var app: App = .{ .gpa = std.testing.allocator, .io = std.testing.io, .tmux_in = undefined, .epoch = 1000 };
    app.reports_dir = dir_buf[0..dir_len];
    var a: [std.fs.max_path_bytes]u8 = undefined;
    var b: [std.fs.max_path_bytes]u8 = undefined;
    const first = (try app.saveCapture("one", &a)).?;
    const second = (try app.saveCapture("two", &b)).?;
    try std.testing.expect(!std.mem.eql(u8, first, second));
    try std.testing.expect(std.mem.endsWith(u8, first, "/1000-0.txt"));
    try std.testing.expect(std.mem.endsWith(u8, second, "/1000-1.txt"));
}

test "the every view's columns grouped by repo: their lines, the pick stepping across groups, the scroll, the widths" {
    var app: App = .{ .gpa = std.testing.allocator, .io = undefined, .tmux_in = undefined };
    app.term_w = 100;
    app.view_w = 80;
    app.view_h = 8;
    app.board = try tickets.Board.parse(std.testing.allocator,
        \\{"tickets":[
        \\{"id":1,"repo":"arena","title":"a","status":"todo"},
        \\{"id":2,"repo":"arena","title":"b","status":"todo"},
        \\{"id":3,"repo":"arena","title":"c","status":"doing"},
        \\{"id":4,"repo":"tlon","title":"d","status":"doing"},
        \\{"id":5,"title":"e","status":"todo"}
        \\]}
    );
    defer app.board.?.deinit();
    app.board_view = .{};
    const eq = std.testing.expectEqual;

    // in todo, arena's heading and its two cards, the picked one boxed on five rows (its edges,
    // title, detail and actions) and the other a title's row, then the cards of no repo's; tlon
    // has none there, so no rows
    const Line = App.ColumnLine;
    try eq(Line{ .lane = 0, .what = .heading }, app.columnLineAt(0, 0).?);
    try eq(Line{ .lane = 0, .what = .{ .card = .{ .row = 0, .part = 0 } } }, app.columnLineAt(0, 1).?);
    try eq(Line{ .lane = 0, .what = .{ .card = .{ .row = 0, .part = 4 } } }, app.columnLineAt(0, 5).?);
    try eq(Line{ .lane = 0, .what = .{ .card = .{ .row = 1, .part = 0 } } }, app.columnLineAt(0, 6).?);
    try eq(Line{ .lane = 2, .what = .heading }, app.columnLineAt(0, 7).?);
    try eq(Line{ .lane = 2, .what = .{ .card = .{ .row = 0, .part = 0 } } }, app.columnLineAt(0, 8).?);
    try eq(@as(?Line, null), app.columnLineAt(0, 9));
    // in doing, arena's then tlon's, each card a title and a last row saying no Claude holds it
    try eq(Line{ .lane = 0, .what = .{ .card = .{ .row = 0, .part = 1 } } }, app.columnLineAt(1, 2).?);
    try eq(Line{ .lane = 1, .what = .heading }, app.columnLineAt(1, 3).?);

    // review and done have nothing, so are as narrow as their headings; todo the widest
    var sum: u16 = 0;
    for (0..4) |c| sum += app.boardColW(c);
    try eq(app.boardW(), sum);
    try eq(@as(u16, " review 0 ".len + 3), app.boardColW(2));
    try eq(@as(u16, " recent 0 ".len + 3), app.boardColW(3));
    try std.testing.expect(app.boardColW(0) > app.boardColW(1));

    const picked = struct {
        fn id(a: *const App) ?u32 {
            const view = a.board_view.?;
            return if (a.boardCard(view.col, view.row)) |card| card.id else null;
        }
    }.id;
    try eq(@as(?u32, 1), picked(&app));
    try app.boardKey("j");
    try eq(@as(?u32, 2), picked(&app));
    // five lines shown: the picked card's bottom edge kept on the last of them
    try eq(@as(usize, 2), app.columnScroll(0));
    try eq(@as(usize, 0), app.columnScroll(1));
    try app.boardKey("j");
    try eq(@as(?u32, 5), picked(&app));
    try eq(@as(usize, 4), app.columnScroll(0));
    try app.boardKey("j");
    try eq(@as(?u32, 5), picked(&app));
    // the cards of no repo have none doing: l goes to the first group that has
    try app.boardKey("l");
    try eq(@as(?u32, 3), picked(&app));
    try app.boardKey("h");
    try eq(@as(?u32, 1), picked(&app));
    try app.boardKey("l");
    try eq(@as(?u32, 3), picked(&app));
    try app.boardKey("j");
    try eq(@as(?u32, 4), picked(&app));
    try app.boardKey("j");
    try eq(@as(?u32, 4), picked(&app));
}

test "the board's first row: tabs with their counts, then babylon's state against the right edge, each said once" {
    var app: App = .{ .gpa = std.testing.allocator, .io = undefined, .tmux_in = undefined };
    app.term_w = 140;
    app.view_w = 140;
    app.view_h = 20;
    app.board = try tickets.Board.parse(std.testing.allocator,
        \\{"tickets":[
        \\{"id":1,"repo":"arena","title":"a","status":"todo"},
        \\{"id":2,"repo":"arena","title":"b","status":"doing"},
        \\{"id":3,"repo":"tlon","title":"c","status":"review","stage":"reviewing"},
        \\{"id":4,"repo":"menard","title":"d","status":"done"}
        \\],"backlog":[{"id":7,"repo":"arena","title":"later","status":"backlog"}],
        \\"auto":{"on":true,"cap":3,"working":2},"orchestrator":{"on":true,"running":true}}
    );
    defer app.board.?.deinit();
    app.board_view = .{};

    const labels = struct {
        fn of(a: *const App, out: *[2048]u8) ![]const u8 {
            var buttons: [48]App.Button = undefined;
            const head = a.header(&buttons);
            var len: usize = 0;
            for (buttons[0..head.n]) |button| {
                var buf: [64]u8 = undefined;
                const text = std.mem.trim(u8, a.buttonLabel(button, &buf), " ");
                len += (try std.fmt.bufPrint(out[len..], "{s}|", .{text})).len;
            }
            return out[0..len];
        }
    }.of;
    var out: [2048]u8 = undefined;
    // no gate session, so none; the orchestrator is said once, and auto once
    try std.testing.expectEqualStrings("every 3|arena 2|menard 0|tlon 1|backlog 1|▲ 0 need you|● orch|◐ auto 2/3|", try labels(&app, &out));

    var buttons: [48]App.Button = undefined;
    const head = app.header(&buttons);
    try std.testing.expectEqual(@as(?u16, null), head.more);
    const last = buttons[head.n - 1];
    try std.testing.expectEqual(app.boardX() + app.boardW(), last.x + last.w);

    // with less room the right group loses its words first, then tabs go, ending in …
    app.view_w = 40;
    try std.testing.expectEqualStrings("every 3|arena 2|menard 0|▲ 0|●|◐ 2/3|", try labels(&app, &out));
    const narrow = app.header(&buttons);
    try std.testing.expect(narrow.more != null);
}

test "the auto button says the tools slots when babylon gives them, and the short one drops them" {
    var app: App = .{ .gpa = std.testing.allocator, .io = undefined, .tmux_in = undefined };
    app.board = try tickets.Board.parse(std.testing.allocator,
        \\{"tickets":[],"auto":{"on":true,"cap":4,"working":4,"tools":{"working":1,"cap":1}}}
    );
    defer app.board.?.deinit();
    var buf: [64]u8 = undefined;
    var button: App.Button = .{ .what = .auto, .x = 0, .y = 0, .w = 0, .short = false };
    try std.testing.expectEqualStrings(" ◐ auto 4/4 · tools 1/1 ", app.buttonLabel(button, &buf));
    button.short = true;
    try std.testing.expectEqualStrings(" ◐ 4/4 ", app.buttonLabel(button, &buf));
}

test "auto's modal shows a step at once, and a cap babylon refused is back at its own" {
    var app: App = .{ .gpa = std.testing.allocator, .io = undefined, .tmux_in = undefined };
    app.term_w = 140;
    app.view_w = 120;
    app.view_h = 24;
    app.board = try tickets.Board.parse(std.testing.allocator,
        \\{"tickets":[],"auto":{"on":true,"cap":4,"working":1,"repo_caps":{"arena":2,"tlon":0}}}
    );
    defer app.board.?.deinit();
    defer app.auto_wants.deinit(std.testing.allocator);
    app.board_view = .{ .focus = .orchestrator };
    try app.boardKey("A");
    try std.testing.expectEqual(@as(?usize, 0), app.board_view.?.auto_pick);
    try std.testing.expect(app.board_view.?.focus == .board);
    try app.boardKey("j");
    try app.boardKey("j");
    try app.boardKey("+");
    try app.boardKey("+");
    try std.testing.expectEqual(@as(u32, 4), app.autoRepo(0).?.cap);
    try std.testing.expectEqual(@as(usize, 1), app.auto_wants.list.items.len);
    try app.boardKey("j");
    try app.boardKey("-");
    try std.testing.expectEqual(@as(u32, 0), app.autoRepo(1).?.cap);
    try app.boardKey("H");
    try std.testing.expect(app.holding());
    try app.boardKey("a");
    try std.testing.expect(app.auto() == null);

    app.auto_wants.list.items[0].due = 0;
    try app.autoRefused("auto:cap:arena", "babylon: no such repo\nmore");
    try std.testing.expectEqual(@as(u32, 2), app.autoRepo(0).?.cap);
    try std.testing.expectEqualStrings("babylon: no such repo", app.auto_wants.refused.?);

    try app.boardKey("\x1b");
    try std.testing.expectEqual(@as(?usize, null), app.board_view.?.auto_pick);
}

test "a click on the header's auto words opens its modal and one on its switch does not" {
    var app: App = .{ .gpa = std.testing.allocator, .io = undefined, .tmux_in = undefined };
    app.term_w = 140;
    app.view_w = 120;
    app.view_h = 24;
    app.board = try tickets.Board.parse(std.testing.allocator,
        \\{"tickets":[],"auto":{"on":false,"cap":4,"working":0}}
    );
    defer app.board.?.deinit();
    app.board_view = .{};
    const button: App.Button = .{ .what = .auto, .x = 10, .y = 0, .w = 8, .short = false };
    try std.testing.expect(app.onAutoSwitch(button, 10));
    try std.testing.expect(app.onAutoSwitch(button, 12));
    try std.testing.expect(!app.onAutoSwitch(button, 16));
    try app.pressButton(button, 16);
    try std.testing.expectEqual(@as(?usize, 0), app.board_view.?.auto_pick);
}

test "the every view's done column is a strip: narrow, a card a row, its reopen on its foot" {
    var app: App = .{ .gpa = std.testing.allocator, .io = undefined, .tmux_in = undefined };
    app.term_w = 140;
    app.view_w = 120;
    app.view_h = 20;
    app.board = try tickets.Board.parse(std.testing.allocator,
        \\{"tickets":[
        \\{"id":1,"repo":"arena","title":"a","status":"todo"},
        \\{"id":2,"repo":"arena","title":"b","status":"done"},
        \\{"id":3,"repo":"arena","title":"c","status":"done"},
        \\{"id":4,"repo":"arena","title":"d","status":"done"},
        \\{"id":5,"repo":"arena","title":"e","status":"done"},
        \\{"id":6,"repo":"arena","title":"f","status":"done"},
        \\{"id":7,"repo":"arena","title":"g","status":"done"},
        \\{"id":8,"repo":"arena","title":"h","status":"done"}
        \\]}
    );
    defer app.board.?.deinit();
    app.board_view = .{};
    const eq = std.testing.expectEqual;

    try eq(@min(App.recent_w, app.boardW() / 4), app.boardColW(3));
    try std.testing.expect(app.boardColW(0) > app.boardColW(3));
    try eq(app.boardColX(2) + app.boardColW(2), app.boardColX(3));
    try std.testing.expect(app.boardColX(3) + app.boardColW(3) <= app.boardX() + app.boardW());

    try app.boardKey("l");
    try app.boardKey("l");
    try app.boardKey("l");
    try app.boardKey("j");
    const view = app.board_view.?;
    try eq(@as(usize, 1), view.row);
    // under arena's heading
    try eq(view.row, app.boardCardAt(app.boardColX(3) + 1, app.colTop() + 2).?.row);
    var buttons: [48]App.Button = undefined;
    const shown = app.boardButtons(&buttons);
    const last = shown[shown.len - 1];
    try eq(App.CardAction.reopen, last.what.card);
    try eq(app.view_h - 1, last.y);

    // one repo's view keeps done's width, its cards boxed as the others'
    app.board_view.?.repo = 1;
    try eq(@min(App.recent_w, app.boardW() / 4), app.boardColW(3));
    try std.testing.expect(!app.boardStrip(3));
}

test "in the every view a click on a recent entry whose repo has no open card picks it" {
    var app: App = .{ .gpa = std.testing.allocator, .io = undefined, .tmux_in = undefined };
    app.term_w = 100;
    app.view_w = 100;
    app.view_h = 30;
    app.roles = @import("parts.zig").roles();
    app.board = try tickets.Board.parse(std.testing.allocator,
        \\{"tickets":[
        \\{"id":4,"repo":"tlon","title":"d","status":"doing"},
        \\{"id":6,"repo":"arena","title":"f","status":"done"}
        \\]}
    );
    defer app.board.?.deinit();
    app.board_view = .{ .col = 1 };
    const eq = std.testing.expectEqual;

    var recent: [App.strip_n]*const tickets.Card = undefined;
    try eq(@as(usize, 1), app.stripCards(&recent));
    const x = app.boardX() + 1;
    try std.testing.expect(try app.boardMouse(.{ .code = 0, .x = x, .y = app.listH() + 1, .release = false }));
    try eq(@as(usize, 3), app.board_view.?.col);
    try eq(@as(u32, 6), app.boardCard(3, app.board_view.?.row).?.id);
}

test "in the every view a find leaves a recent entry outside the last five closed, and it is picked by click" {
    var app: App = .{ .gpa = std.testing.allocator, .io = undefined, .tmux_in = undefined };
    app.term_w = 100;
    app.view_w = 100;
    app.view_h = 30;
    app.roles = @import("parts.zig").roles();
    app.board = try tickets.Board.parse(std.testing.allocator,
        \\{"tickets":[
        \\{"id":4,"repo":"a","title":"d","status":"doing"},
        \\{"id":10,"repo":"a","title":"x","status":"done"},
        \\{"id":11,"repo":"a","title":"x","status":"done"},
        \\{"id":12,"repo":"a","title":"x","status":"done"},
        \\{"id":13,"repo":"a","title":"x","status":"done"},
        \\{"id":14,"repo":"a","title":"x","status":"done"},
        \\{"id":15,"repo":"b","title":"zeta","status":"done"}
        \\]}
    );
    defer app.board.?.deinit();
    app.board_view = .{ .col = 1 };
    @memcpy(app.find[0..4], "zeta");
    app.find_len = 4;
    const eq = std.testing.expectEqual;

    var recent: [App.strip_n]*const tickets.Card = undefined;
    try eq(@as(usize, 1), app.stripCards(&recent));
    const x = app.boardX() + 1;
    try std.testing.expect(try app.boardMouse(.{ .code = 0, .x = x, .y = app.listH() + 1, .release = false }));
    try eq(@as(usize, 3), app.board_view.?.col);
    try eq(@as(u32, 15), app.boardCard(3, app.board_view.?.row).?.id);
}

test "in the every view a find leaves a recent entry no lane has, and the keys pick it and stay on it" {
    var app: App = .{ .gpa = std.testing.allocator, .io = undefined, .tmux_in = undefined };
    app.term_w = 100;
    app.view_w = 100;
    app.view_h = 30;
    app.roles = @import("parts.zig").roles();
    app.board = try tickets.Board.parse(std.testing.allocator,
        \\{"tickets":[
        \\{"id":4,"repo":"a","title":"d","status":"doing"},
        \\{"id":10,"repo":"a","title":"x","status":"done"},
        \\{"id":11,"repo":"a","title":"x","status":"done"},
        \\{"id":12,"repo":"a","title":"x","status":"done"},
        \\{"id":13,"repo":"a","title":"x","status":"done"},
        \\{"id":14,"repo":"a","title":"x","status":"done"},
        \\{"id":15,"repo":"b","title":"zeta","status":"done"}
        \\]}
    );
    defer app.board.?.deinit();
    app.board_view = .{ .col = 3 };
    @memcpy(app.find[0..4], "zeta");
    app.find_len = 4;
    const eq = std.testing.expectEqual;

    for (0..3) |_| try app.boardKey("j");
    try eq(@as(u32, 15), app.boardCard(3, app.board_view.?.row).?.id);
    try app.boardKey("k");
    try eq(@as(u32, 15), app.boardCard(3, app.board_view.?.row).?.id);
}

test "in the every view with epic bars shown, each drawn recent entry is picked by key and by click, the barred epic not among them" {
    var app: App = .{ .gpa = std.testing.allocator, .io = undefined, .tmux_in = undefined };
    app.term_w = 100;
    app.view_w = 100;
    app.view_h = 30;
    app.roles = @import("parts.zig").roles();
    app.board = try tickets.Board.parse(std.testing.allocator,
        \\{"tickets":[
        \\{"id":4,"repo":"a","title":"d","status":"doing"},
        \\{"id":326,"repo":"e","title":"Epic","kind":"epic","status":"done"},
        \\{"id":10,"repo":"a","title":"x","status":"done"},
        \\{"id":11,"repo":"b","title":"x","status":"done"}
        \\],
        \\"plan":{"goals":[{"epic":326,"title":"E","landed":0,"total":1,"steps":[]}]}}
    );
    defer app.board.?.deinit();
    app.board_view = .{ .col = 3 };
    const eq = std.testing.expectEqual;

    try std.testing.expect(app.epicBars().len > 0);
    var recent: [App.strip_n]*const tickets.Card = undefined;
    const n = app.stripCards(&recent);
    try eq(@as(usize, 2), n);
    for (0..n) |k| {
        const x = app.boardX() + 1 + @as(u16, @intCast(k)) * app.stripCell();
        try std.testing.expect(try app.boardMouse(.{ .code = 0, .x = x, .y = app.listH() + 1, .release = false }));
        try eq(recent[k].id, app.boardCard(3, app.board_view.?.row).?.id);
    }
    app.board_view.?.row = 0;
    for (0..n) |k| {
        try eq(recent[k].id, app.boardCard(3, app.board_view.?.row).?.id);
        try app.boardKey("j");
    }
    try eq(recent[n - 1].id, app.boardCard(3, app.board_view.?.row).?.id);
}

test "in the every view the keys step through the foot strip and stop at its ends, whatever its lanes" {
    var app: App = .{ .gpa = std.testing.allocator, .io = undefined, .tmux_in = undefined };
    app.term_w = 100;
    app.view_w = 100;
    app.view_h = 30;
    app.roles = @import("parts.zig").roles();
    app.board = try tickets.Board.parse(std.testing.allocator,
        \\{"tickets":[
        \\{"id":4,"repo":"a","title":"d","status":"doing"},
        \\{"id":5,"repo":"b","title":"d","status":"doing"},
        \\{"id":10,"repo":"a","title":"x","status":"done"},
        \\{"id":11,"repo":"b","title":"x","status":"done"},
        \\{"id":12,"repo":"a","title":"x","status":"done"}
        \\]}
    );
    defer app.board.?.deinit();
    app.board_view = .{ .col = 3 };
    const eq = std.testing.expectEqual;

    for (0..6) |_| try app.boardKey("j");
    try eq(@as(usize, 2), app.board_view.?.row);
    try eq(@as(u32, 12), app.boardCard(3, app.board_view.?.row).?.id);
    for (0..6) |_| try app.boardKey("k");
    try eq(@as(usize, 0), app.board_view.?.row);
    try eq(@as(u32, 10), app.boardCard(3, app.board_view.?.row).?.id);
}

test "in Workbench's look a click on the picked tile's button does its action, and one on a recent entry picks it" {
    var app: App = .{ .gpa = std.testing.allocator, .io = undefined, .tmux_in = undefined };
    app.term_w = 100;
    app.view_w = 100;
    app.view_h = 30;
    app.roles = @import("parts.zig").roles();
    app.board = try tickets.Board.parse(std.testing.allocator,
        \\{"tickets":[
        \\{"id":4,"repo":"tlon","title":"d","status":"doing","ask":{"id":9,"question":"Which?","options":["x"]}},
        \\{"id":6,"repo":"tlon","title":"f","status":"done"},
        \\{"id":7,"repo":"tlon","title":"g","status":"done"}
        \\]}
    );
    defer app.board.?.deinit();
    app.board_view = .{ .col = 1 };
    const eq = std.testing.expectEqual;

    try eq(@as(u16, 0), app.boardColW(3));
    var buttons: [48]App.Button = undefined;
    var answer: ?App.Button = null;
    for (app.boardButtons(&buttons)) |b| switch (b.what) {
        .card => |action| if (action == .answer) {
            answer = b;
        },
        else => {},
    };
    const on = answer.?;
    try std.testing.expect(!app.board_view.?.answering);
    try std.testing.expect(try app.boardMouse(.{ .code = 0, .x = on.x + 1, .y = on.y, .release = false }));
    try std.testing.expect(app.board_view.?.answering);
    app.board_view.?.answering = false;

    var recent: [App.strip_n]*const tickets.Card = undefined;
    try eq(@as(usize, 2), app.stripCards(&recent));
    const second = recent[1].id;
    const x = app.boardX() + app.stripCell() + 1;
    try std.testing.expect(try app.boardMouse(.{ .code = 0, .x = x, .y = app.listH() + 1, .release = false }));
    try eq(@as(usize, 3), app.board_view.?.col);
    try eq(second, app.boardCard(3, app.board_view.?.row).?.id);
    var picked: [48]App.Button = undefined;
    const reopen = for (app.boardButtons(&picked)) |b| {
        if (b.what == .card and b.what.card == .reopen) break b;
    } else return error.NoReopen;
    try eq(app.listH() + 3, reopen.y);
    try eq(app.boardX() + app.stripCell() + 1, reopen.x);
}

test "⏎ on a card's peek picks that card and is left to the board, not sent to a Claude's pane" {
    var app: App = .{ .gpa = std.testing.allocator, .io = undefined, .tmux_in = undefined };
    app.term_w = 100;
    app.view_w = 100;
    app.view_h = 30;
    app.board = try tickets.Board.parse(std.testing.allocator,
        \\{"tickets":[
        \\{"id":4,"repo":"tlon","title":"d","status":"todo"},
        \\{"id":6,"repo":"tlon","title":"f","status":"todo"}
        \\]}
    );
    defer app.board.?.deinit();
    app.board_view = .{ .col = 0, .row = 0, .focus = .orchestrator };
    app.look = .{ .ticket = 6 };
    try std.testing.expect(!try app.lookKey("\r"));
    try std.testing.expect(app.look == null);
    try std.testing.expect(app.board_view.?.focus == .board);
    try std.testing.expectEqual(@as(u32, 6), app.boardCard(app.board_view.?.col, app.board_view.?.row).?.id);
}

test "the pick on a rail entry opens its peek after the pause, once a key has moved it" {
    var app: App = .{ .gpa = std.testing.allocator, .io = undefined, .tmux_in = undefined };
    app.normal = true;
    app.rail_pick = .{ .agent = 5 };
    try std.testing.expect(app.focusLook() == null);
    app.key_typed = true;
    app.key_at = 1000;
    app.now = 1000;
    try std.testing.expect(app.lookStep() > 0);
    try std.testing.expect(app.look == null);
    app.now = 1000 + look_ms;
    _ = app.lookStep();
    try std.testing.expectEqual(@as(u32, 5), app.look.?.window);
}

test "the board opens on a ticket by its id: its lane, its repo's columns or the backlog, its question shown" {
    var app: App = .{ .gpa = std.testing.allocator, .io = undefined, .tmux_in = undefined };
    app.term_w = 100;
    app.view_w = 80;
    app.view_h = 24;
    try app.showCard(4);
    try std.testing.expect(app.board_view == null);
    app.board = try tickets.Board.parse(std.testing.allocator,
        \\{"tickets":[
        \\{"id":1,"repo":"arena","title":"a","status":"todo"},
        \\{"id":4,"repo":"tlon","title":"d","status":"doing","ask":{"id":9,"question":"Which?","options":["x"]}},
        \\{"id":6,"repo":"menard","title":"f","status":"done"},
        \\{"id":5,"title":"e","status":"todo"}
        \\],"backlog":[{"id":7,"repo":"arena","title":"g","status":"backlog"},{"id":8,"repo":"arena","title":"h","status":"backlog"}]}
    );
    defer app.board.?.deinit();
    const eq = std.testing.expectEqual;
    const picked = struct {
        fn id(a: *const App) ?u32 {
            const view = a.board_view.?;
            return if (a.boardCard(view.col, view.row)) |card| card.id else null;
        }
    }.id;

    app.overview = .{ .session = 0, .win = 0 };
    try app.showCard(4);
    try eq(@as(?u32, 4), picked(&app));
    try std.testing.expect(app.overview == null);
    try std.testing.expect(app.boardLanes());
    try std.testing.expect(app.board_view.?.answering);

    try app.showCard(5);
    try eq(@as(?u32, 5), picked(&app));
    try std.testing.expect(!app.board_view.?.answering);

    // menard has only a closed card, among the recent ones: its lane is in the every view
    try app.showCard(6);
    try eq(@as(?u32, 6), picked(&app));
    try std.testing.expect(app.boardLanes());

    try app.showCard(8);
    try eq(@as(?u32, 8), picked(&app));
    try std.testing.expect(app.board_view.?.backlog);

    try app.showCard(99);
    try eq(@as(?u32, 1), picked(&app));
    try std.testing.expect(app.boardLanes());
}

test "the picked card's box ends its buttons with space open, a review card's with space log" {
    var app: App = .{ .gpa = std.testing.allocator, .io = undefined, .tmux_in = undefined };
    app.term_w = 200;
    app.view_w = 160;
    app.view_h = 20;
    app.board = try tickets.Board.parse(std.testing.allocator,
        \\{"tickets":[
        \\{"id":1,"repo":"arena","title":"a","status":"todo"},
        \\{"id":2,"repo":"arena","title":"b","status":"review"}
        \\]}
    );
    defer app.board.?.deinit();
    app.board_view = .{};
    var buttons: [48]App.Button = undefined;
    var buf: [64]u8 = undefined;
    const last = struct {
        fn text(a: *const App, out: []App.Button, b: []u8) []const u8 {
            const shown = a.boardButtons(out);
            return std.mem.trim(u8, a.buttonLabel(shown[shown.len - 1], b), " ");
        }
    }.text;
    try std.testing.expectEqualStrings("space open", last(&app, &buttons, &buf));
    app.board_view.?.col = 2;
    const open: App.Button = .{ .what = .{ .card = .open }, .x = 0, .y = 0, .w = 0 };
    try std.testing.expectEqualStrings("space log", std.mem.trim(u8, app.buttonLabel(open, &buf), " "));
}

test "a click on ▲ proposed finds the last row of a picked card's box as of an unpicked one" {
    var app: App = .{ .gpa = std.testing.allocator, .io = undefined, .tmux_in = undefined };
    app.term_w = 200;
    app.view_w = 160;
    app.view_h = 20;
    app.board = try tickets.Board.parse(std.testing.allocator,
        \\{"tickets":[
        \\{"id":1,"repo":"arena","title":"a","status":"todo"},
        \\{"id":2,"repo":"arena","title":"b","status":"todo"}],
        \\"proposals":[{"id":4,"action":"start","ticket_id":1,"what":"Start #1","why":"Next"},{"id":5,"action":"start","ticket_id":2,"what":"Start #2","why":"Next"}],
        \\"needs_you":[{"id":"proposal:4","kind":"proposal","ticket":1,"repo":"arena","text":"P4","actions":[]},{"id":"proposal:5","kind":"proposal","ticket":2,"repo":"arena","text":"P5","actions":[]}]}
    );
    defer app.board.?.deinit();
    app.board_view = .{};
    const x = app.boardColX(0) + 2;
    // each card's last row is a hit, whichever of them is picked
    for (0..2) |_| {
        var hits: usize = 0;
        for (2..app.view_h - 1) |y| {
            const at = app.boardCardAt(x, @intCast(y)) orelse continue;
            if (try app.cardNeedsClick(at, .{ .code = 0, .x = x, .y = @intCast(y), .release = false })) hits += 1;
        }
        try std.testing.expectEqual(@as(usize, 2), hits);
        app.board_view.?.row = 1;
    }
}

test "a gate run's last run is read into its stages, their results, times and output" {
    const text =
        \\#5 T
        \\
        \\run submitted 2026-11-24T04:00:00Z
        \\  rebase: ok (2026-11-24T04:00:01Z to 2026-11-24T04:00:02Z)
        \\run submitted 2026-11-24T05:00:00Z
        \\  rebase: ok (2026-11-24T05:00:01Z to 2026-11-24T05:00:05Z)
        \\  gate: failed (2026-11-24T05:00:05Z to 2026-11-24T05:02:03Z)
        \\    test "a" failed
        \\    expected 1
        \\
        \\  review: running (2026-11-24T05:02:03Z)
        \\
    ;
    const run = gateLastRun(text);
    try std.testing.expect(std.mem.startsWith(u8, run, "run submitted 2026-11-24T05:00:00Z"));
    const rebase = gateStage(run, "rebase").?;
    try std.testing.expectEqualStrings("ok", rebase.result);
    try std.testing.expectEqualStrings("2026-11-24T05:00:05Z", rebase.end.?);
    const gate = gateStage(run, "gate").?;
    try std.testing.expectEqualStrings("failed", gate.result);
    try std.testing.expectEqualStrings("    test \"a\" failed\n    expected 1\n", gate.body);
    const review = gateStage(run, "review").?;
    try std.testing.expectEqualStrings("running", review.result);
    try std.testing.expect(review.end == null);
    try std.testing.expect(gateStage(run, "land") == null);
}

test "the strip's normal keys: q does nothing, Q leaves, ? shows the keys, / opens the jump prompt" {
    var app: App = .{ .gpa = std.testing.allocator, .io = undefined, .tmux_in = undefined };
    app.normal = true;
    try app.stripKey("q");
    try std.testing.expect(!app.quit and !app.strip_help and app.prompt == null and app.menu == null);
    try app.stripKey("?");
    try std.testing.expect(app.strip_help);
    try app.stripKey("/");
    try std.testing.expectEqual(menu.Prompt.What.jump, app.prompt.?.what);
    app.prompt = null;
    try app.stripKey("Q");
    try std.testing.expect(app.quit);
}

test "a key after the one that opened the menu, in the same read, is the menu's" {
    var app: App = .{ .gpa = std.testing.allocator, .io = undefined, .tmux_in = undefined };
    app.normal = true;
    try app.menuKeys("mj");
    try std.testing.expect(!app.normal);
    try std.testing.expectEqual(@as(usize, 1), app.menu.?.selected);
}

test "the jump prompt finds a ticket by its number or its title as well as a window" {
    var app: App = .{ .gpa = std.testing.allocator, .io = undefined, .tmux_in = undefined };
    app.board = try tickets.Board.parse(std.testing.allocator,
        \\{"tickets":[{"id":317,"repo":"arena","title":"Rail sorting","status":"todo"},{"id":8,"repo":"tlon","title":"Lights","status":"todo"}]}
    );
    defer app.board.?.deinit();
    var hits: [8]App.Hit = undefined;
    try std.testing.expectEqual(@as(usize, 1), app.jumpHits("#317", &hits));
    try std.testing.expectEqual(@as(u32, 317), hits[0].ticket.id);
    try std.testing.expectEqual(@as(usize, 1), app.jumpHits("lights", &hits));
    try std.testing.expectEqual(@as(u32, 8), hits[0].ticket.id);
}

test "a gate modal's scroll stops at the last line of the output it scrolls" {
    const run =
        \\run submitted 2026-11-24T05:00:00Z
        \\  rebase: ok (2026-11-24T05:00:01Z to 2026-11-24T05:00:05Z)
        \\  gate: failed (2026-11-24T05:00:05Z to 2026-11-24T05:02:03Z)
        \\    one
        \\    two
        \\
    ;
    try std.testing.expectEqual(@as(usize, 2), gateOutputRows(gateOutput(run), 40));
    try std.testing.expectEqualStrings("", gateOutput("run submitted x\n  rebase: ok (2026-11-24T05:00:01Z to 2026-11-24T05:00:05Z)\n"));
}

test "a card moves along its column only with a repo, out of the backlog" {
    var have: [12]App.CardAction = undefined;
    const has = struct {
        fn up(card: tickets.Card, out: *[12]App.CardAction) bool {
            return std.mem.indexOfScalar(App.CardAction, App.cardActions(&card, out), .up) != null;
        }
    }.up;
    try std.testing.expect(has(.{ .id = 1, .repo = "arena", .title = "a", .status = .todo }, &have));
    try std.testing.expect(!has(.{ .id = 2, .title = "b", .status = .todo }, &have));
    try std.testing.expect(!has(.{ .id = 4, .repo = "two words", .title = "d", .status = .todo }, &have));
    try std.testing.expect(!has(.{ .id = 3, .repo = "arena", .title = "c", .status = .backlog }, &have));
    try std.testing.expect(!has(.{ .id = 5, .repo = "arena", .title = "e", .status = .@"try" }, &have));
}

test "the done column's cap leaves the to-try cards out of its count, they are all shown" {
    var app: App = .{ .gpa = std.testing.allocator, .io = undefined, .tmux_in = undefined };
    defer app.pending.deinit(std.testing.allocator);
    app.board = try tickets.Board.parse(std.testing.allocator,
        \\{"tickets":[
        \\{"id":1,"repo":"arena","title":"a","status":"try"},
        \\{"id":2,"repo":"arena","title":"b","status":"try"},
        \\{"id":3,"repo":"arena","title":"c","status":"done"},
        \\{"id":4,"repo":"arena","title":"d","status":"done"},
        \\{"id":5,"repo":"arena","title":"e","status":"done"},
        \\{"id":6,"repo":"arena","title":"f","status":"done"}
        \\]}
    );
    defer app.board.?.deinit();
    try std.testing.expectEqual(@as(usize, 2 + App.done_shown), app.shownIn(.done, "arena", 6));
    try std.testing.expectEqual(@as(usize, 4), app.shownIn(.done, "arena", 4));
}

test "a capture tmux refuses, its pane gone, takes the cursor asked with it off what is awaited" {
    var app: App = .{ .gpa = std.testing.allocator, .io = undefined, .tmux_in = undefined };
    defer app.deinit();
    try app.pending.appendSlice(app.gpa, &.{ .{ .modes = 9 }, .{ .capture = 9 }, .{ .cursor = 9 }, .sessions });
    const lines = [_][]const u8{
        "%begin 1 1 1", "0 0 0 0 0 0",         "%end 1 1 1",
        "%begin 1 2 1", "can't find pane: %9", "%error 1 2 1",
    };
    var buf: [32]u8 = undefined;
    for (lines) |line| {
        @memcpy(buf[0..line.len], line);
        try app.onLine(buf[0..line.len]);
    }
    try std.testing.expectEqual(@as(usize, 1), app.pending.items.len);
    try std.testing.expect(app.pending.items[0] == .sessions);
}

test "the modes tmux refuses, its pane gone, take the capture and cursor asked with them off what is awaited" {
    var app: App = .{ .gpa = std.testing.allocator, .io = undefined, .tmux_in = undefined };
    defer app.deinit();
    try app.pending.appendSlice(app.gpa, &.{ .{ .modes = 9 }, .{ .capture = 9 }, .{ .cursor = 9 }, .{ .modes = 10 } });
    const lines = [_][]const u8{ "%begin 1 1 1", "can't find pane: %9", "%error 1 1 1" };
    var buf: [32]u8 = undefined;
    for (lines) |line| {
        @memcpy(buf[0..line.len], line);
        try app.onLine(buf[0..line.len]);
    }
    try std.testing.expectEqual(@as(usize, 1), app.pending.items.len);
    try std.testing.expectEqual(@as(u32, 10), app.pending.items[0].modes);
}

test "the session arena is headed for is kept only while tmux has a switch to it unanswered" {
    var app: App = .{ .gpa = std.testing.allocator, .io = undefined, .tmux_in = undefined };
    const eq = std.testing.expectEqual;

    // two switches asked: the report of the first is on the way to the second
    app.heading = 2;
    app.switches = 2;
    app.onSwitched(false);
    app.onSessionChanged(3);
    try eq(@as(?u32, 2), app.heading);
    app.onSwitched(false);
    app.onSessionChanged(2);
    try eq(@as(?u32, null), app.heading);

    // refused: no report will come
    app.heading = 4;
    app.switches = 1;
    app.onSwitched(true);
    try eq(@as(?u32, null), app.heading);

    // answered, then the client moved elsewhere before the report of it came
    app.heading = 5;
    app.switches = 1;
    app.onSwitched(false);
    app.onSessionChanged(6);
    try eq(@as(?u32, null), app.heading);
    try eq(@as(?u32, 6), app.current);
}

test "beside the board, the keys go by the session tmux was last asked for" {
    var work: Session = .{ .id = 1, .name = @constCast("work") };
    var orch: Session = .{ .id = 2, .name = @constCast("orchestrator") };
    var sessions = [_]*Session{ &work, &orch };
    var app: App = .{ .gpa = std.testing.allocator, .io = undefined, .tmux_in = undefined };
    app.sessions = .fromOwnedSlice(&sessions);
    const expect = std.testing.expect;

    // the board opened from the human's session: the switch to the orchestrator's is unanswered
    app.board_view = .{ .back = 1 };
    app.current = 1;
    app.heading = 2;
    app.switches = 1;
    try expect(!app.typing());
    try app.onChord('l');
    try expect(app.board_view.?.focus == .orchestrator);
    try expect(app.typing());
    try app.onChord('l');
    try expect(app.board_view != null);

    // on the way back out of it, they are the board's
    app.current = 2;
    app.heading = 1;
    try expect(!app.typing());
}

test "a left click on the dots row is chrome, not the pane's" {
    var app: App = .{ .gpa = std.testing.allocator, .io = undefined, .tmux_in = undefined };
    app.term_w = 80;
    app.view_w = 80;
    app.view_h = 24;
    const expect = std.testing.expect;
    try expect(app.paneClick(.{ .code = 0, .x = 10, .y = 23, .release = false }));
    try expect(!app.paneClick(.{ .code = 0, .x = 10, .y = 24, .release = false }));
}

test "a card's title wraps at a space onto its second row" {
    const eql = std.testing.expectEqualStrings;
    const short = titleLines("#3 Lights", 12);
    try eql("#3 Lights", short[0]);
    try eql("", short[1]);
    const long = titleLines("#3 Board cards look like cards", 12);
    try eql("#3 Board", long[0]);
    try eql("cards look like cards", long[1]);
    const at_space = titleLines("#3 Board cards", 8);
    try eql("#3 Board", at_space[0]);
    try eql("cards", at_space[1]);
    const one_word = titleLines("#3Boardcards", 8);
    try eql("#3Boardc", one_word[0]);
    try eql("ards", one_word[1]);
}

test "a card's modal runs a long title on over as many lines as it takes, none of it cut" {
    const card: tickets.Card = .{
        .id = 1,
        .title = "alpha beta gamma delta epsilon zeta eta theta iota kappa lambda mu nu xi omicron pi rho sigma tau upsilon phi chi psi omega alpha beta gamma delta epsilon zeta eta theta iota kappa lambda",
        .status = .doing,
    };
    var head: App.CardHead = undefined;
    App.cardHead(&card, 40, 0, false, &head);
    var rows: usize = 0;
    var last: []const u8 = "";
    for (head.lines[0..head.n], head.kinds[0..head.n]) |line, kind| if (kind == .plain) {
        try std.testing.expect(cellCount(line) <= 40);
        rows += 1;
        last = line;
    };
    try std.testing.expect(rows >= 5);
    try std.testing.expect(std.mem.endsWith(u8, last, "kappa lambda"));
}

test "a card's detail runs its long lines on, cut at the box's width" {
    var lines = DetailLines.init("#3 Title\n\none two three four\n", 8);
    const want = [_][]const u8{ "#3 Title", "", "one two ", "three fo", "ur" };
    for (want) |line| try std.testing.expectEqualStrings(line, lines.next().?);
    try std.testing.expectEqual(null, lines.next());
}

test "an Esc read with keys after it is a key of its own, and an arrow is three bytes" {
    try std.testing.expectEqual(@as(usize, 1), App.keyLen("\x1bi"));
    try std.testing.expectEqual(@as(usize, 1), App.keyLen("\x1bij"));
    try std.testing.expectEqual(@as(usize, 3), App.keyLen("\x1b[Aj"));
    try std.testing.expectEqual(@as(usize, 3), App.keyLen("\x1bOB"));
    try std.testing.expectEqual(@as(usize, 1), App.keyLen("\x1b["));
}

test "a review state is read from its number, and what is not one is none" {
    try std.testing.expectEqual(Review.none, Review.of(0));
    try std.testing.expectEqual(Review.landed, Review.of(1));
    try std.testing.expectEqual(Review.reviewed, Review.of(2));
    try std.testing.expectEqual(Review.queued, Review.of(3));
    try std.testing.expectEqual(Review.changes, Review.of(4));
    try std.testing.expectEqual(Review.none, Review.of(5));
}

test "babylon's own session, sorted last, is off the list and lists no agents" {
    var gate: Window = .{ .id = 1, .claude = .working };
    var mine: Window = .{ .id = 2, .claude = .working };
    var gates = [_]*Window{&gate};
    var mines = [_]*Window{&mine};
    var babylon: Session = .{ .id = 1, .name = @constCast("babylon") };
    babylon.wins = .fromOwnedSlice(&gates);
    var work: Session = .{ .id = 2, .name = @constCast("work") };
    work.wins = .fromOwnedSlice(&mines);
    var sessions = [_]*Session{ &work, &babylon };
    var app: App = .{ .gpa = std.testing.allocator, .io = undefined, .tmux_in = undefined };
    app.sessions = .fromOwnedSlice(&sessions);
    try std.testing.expectEqual(@as(usize, 1), app.railSessions());
    try std.testing.expectEqual(@as(?usize, 1), app.gateSession());
    var found: [4]App.Agent = undefined;
    try std.testing.expectEqual(@as(usize, 1), app.agents(&found));
    try std.testing.expectEqual(@as(u32, 2), found[0].win.id);
    try std.testing.expectEqual(@as(?usize, null), app.orchestratorSession());

    var orch: Session = .{ .id = 3, .name = @constCast("orchestrator") };
    var three = [_]*Session{ &work, &babylon, &orch };
    app.sessions = .fromOwnedSlice(&three);
    try std.testing.expectEqual(@as(usize, 1), app.railSessions());
    try std.testing.expectEqual(@as(?usize, 1), app.gateSession());
    try std.testing.expectEqual(@as(?usize, 2), app.orchestratorSession());
}

test "a session shows the review state that most wants looking at" {
    var a: Window = .{ .id = 1 };
    var b: Window = .{ .id = 2 };
    var c: Window = .{ .id = 3 };
    var wins = [_]*Window{ &a, &b, &c };
    var s: Session = .{ .id = 1 };
    s.wins = .fromOwnedSlice(&wins);
    try std.testing.expectEqual(Review.none, App.sessionReview(&s));
    a.review = .landed;
    try std.testing.expectEqual(Review.landed, App.sessionReview(&s));
    b.review = .reviewed;
    try std.testing.expectEqual(Review.reviewed, App.sessionReview(&s));
    c.review = .queued;
    try std.testing.expectEqual(Review.queued, App.sessionReview(&s));
    a.review = .changes;
    try std.testing.expectEqual(Review.changes, App.sessionReview(&s));
}

test "a Claude whose card is off the board sorts after the named repos, and a landing one stays listed" {
    const gpa = std.testing.allocator;
    var board = try tickets.Board.parse(gpa,
        \\{"tickets":[
        \\{"id":7,"repo":"tlon","title":"a","status":"doing"},
        \\{"id":8,"repo":"tlon","title":"b","status":"review","stage":"landing"}]}
    );
    defer board.deinit();
    const branches = [_][]const u8{ "\t\t\t\tt99-gone", "\t\t\t\tt7-a", "\t\t\t\tt8-b" };
    var wins: [3]Window = undefined;
    var sessions: [3]Session = undefined;
    var slots: [3]*Window = undefined;
    var pointers: [3]*Session = undefined;
    for (0..3) |i| {
        wins[i] = .{ .id = @intCast(i + 1), .claude = .working, .info = @constCast(branches[i]) };
        slots[i] = &wins[i];
        sessions[i] = .{ .id = @intCast(i + 1), .name = @constCast("s"), .wins = .fromOwnedSlice(slots[i .. i + 1]) };
        pointers[i] = &sessions[i];
    }
    var app: App = .{ .gpa = gpa, .io = undefined, .tmux_in = undefined, .board = board, .agent_sort = .ticket };
    app.sessions = .fromOwnedSlice(&pointers);
    app.board = board;

    var found: [3]App.Agent = undefined;
    var folds: [App.max_folds]App.Fold = undefined;
    const count, const nf = app.railList(&found, &folds);
    try std.testing.expectEqual(@as(usize, 3), count);
    try std.testing.expectEqual(@as(usize, 0), nf);
    try std.testing.expectEqual(@as(u32, 2), found[0].win.id);
    try std.testing.expectEqual(@as(u32, 3), found[1].win.id);
    try std.testing.expectEqual(@as(u32, 1), found[2].win.id);
}

test "a pipeline Claude whose repo finds no fold left is listed as itself" {
    const gpa = std.testing.allocator;
    const n = App.max_folds + 1;
    var json: std.ArrayList(u8) = .empty;
    defer json.deinit(gpa);
    try json.appendSlice(gpa, "{\"tickets\":[");
    for (0..n) |i| try json.print(gpa, "{s}{{\"id\":{d},\"repo\":\"r{d}\",\"title\":\"t\",\"status\":\"review\",\"stage\":\"queued\"}}", .{ if (i > 0) "," else "", i + 1, i });
    try json.appendSlice(gpa, "]}");
    var board = try tickets.Board.parse(gpa, json.items);
    defer board.deinit();
    var infos: [n][]u8 = undefined;
    var wins: [n]Window = undefined;
    var sessions: [n]Session = undefined;
    var slots: [n]*Window = undefined;
    var pointers: [n]*Session = undefined;
    for (0..n) |i| {
        infos[i] = try std.fmt.allocPrint(gpa, "\t\t\t\tt{d}-x", .{i + 1});
        wins[i] = .{ .id = @intCast(i + 1), .claude = .working, .info = infos[i] };
        slots[i] = &wins[i];
        sessions[i] = .{ .id = @intCast(i + 1), .name = @constCast("s"), .wins = .fromOwnedSlice(slots[i .. i + 1]) };
        pointers[i] = &sessions[i];
    }
    defer for (infos) |info| gpa.free(info);
    var app: App = .{ .gpa = gpa, .io = undefined, .tmux_in = undefined, .board = board, .agent_sort = .ticket };
    app.sessions = .fromOwnedSlice(&pointers);
    app.board = board;

    var found: [n]App.Agent = undefined;
    var folds: [App.max_folds]App.Fold = undefined;
    const count, const nf = app.railList(&found, &folds);
    try std.testing.expectEqual(@as(usize, 1), count);
    try std.testing.expectEqual(App.max_folds, nf);
}

test "the ticket order holds a Claude's place through its state, and the pipeline's and the landed's are folded away" {
    const gpa = std.testing.allocator;
    var board = try tickets.Board.parse(gpa,
        \\{"tickets":[
        \\{"id":9,"repo":"tlon","title":"a","status":"doing"},
        \\{"id":4,"repo":"tlon","title":"b","status":"doing"},
        \\{"id":7,"repo":"arena","title":"c","status":"doing"},
        \\{"id":5,"repo":"arena","title":"d","status":"review","stage":"verifying"},
        \\{"id":6,"repo":"arena","title":"e","status":"review","stage":"queued"},
        \\{"id":3,"repo":"arena","title":"f","status":"done"}]}
    );
    defer board.deinit();
    const branches = [_][]const u8{ "\t\t\t\tt9-a", "\t\t\t\tt4-b", "\t\t\t\tt7-c", "\t\t\t\tt5-d", "\t\t\t\tt6-e", "\t\t\t\tt3-f", "" };
    const names = [_][]const u8{ "s9", "s4", "s7", "s5", "s6", "s3", "loose" };
    var wins: [7]Window = undefined;
    var sessions: [7]Session = undefined;
    var slots: [7]*Window = undefined;
    var pointers: [7]*Session = undefined;
    for (0..7) |i| {
        wins[i] = .{ .id = @intCast(i + 1), .claude = .working, .info = @constCast(branches[i]) };
        slots[i] = &wins[i];
        sessions[i] = .{ .id = @intCast(i + 1), .name = @constCast(names[i]), .wins = .fromOwnedSlice(slots[i .. i + 1]) };
        pointers[i] = &sessions[i];
    }
    var app: App = .{ .gpa = gpa, .io = undefined, .tmux_in = undefined, .board = board, .agent_sort = .ticket };
    app.sessions = .fromOwnedSlice(&pointers);
    app.board = board;

    var found: [8]App.Agent = undefined;
    var folds: [App.max_folds]App.Fold = undefined;
    var count, var nf = app.railList(&found, &folds);
    try std.testing.expectEqual(@as(usize, 4), count);
    try std.testing.expectEqual(@as(usize, 1), nf);
    try std.testing.expectEqual(@as(usize, 2), folds[0].count);
    // arena's #7 first, then tlon's #4 and #9, the one with no ticket last
    try std.testing.expectEqual(@as(u32, 3), found[0].win.id);
    try std.testing.expectEqual(@as(u32, 2), found[1].win.id);
    try std.testing.expectEqual(@as(u32, 1), found[2].win.id);
    try std.testing.expectEqual(@as(u32, 7), found[3].win.id);

    wins[0].claude = .waiting;
    wins[0].since = 100;
    count, nf = app.railList(&found, &folds);
    try std.testing.expectEqual(@as(u32, 3), found[0].win.id);
    try std.testing.expectEqual(@as(u32, 1), found[2].win.id);

    // folded: one row for the pipeline's two; scrolled down a row, one above
    var lines: [16]App.AgentLine = undefined;
    const n = app.agentLines(&lines, 16, false);
    try std.testing.expectEqual(App.AgentLine{ .pipeline = folds[0] }, lines[n - 1]);
    app.agent_skip = .{ .n = 1, .at = null };
    const m = app.agentLines(&lines, 3, false);
    try std.testing.expectEqual(@as(usize, 3), m);
    try std.testing.expectEqual(@as(usize, 1), lines[0].above);
    try std.testing.expect(lines[2] == .more);
}

test "at home the narrow rail lists a session's working and waiting Claudes and folds the rest into one line" {
    const gpa = std.testing.allocator;
    const marks = [_]Mark{ .working, .waiting, .done, .done, .none };
    var wins: [5]Window = undefined;
    var slots: [5]*Window = undefined;
    for (0..5) |i| {
        wins[i] = .{ .id = @intCast(i + 1), .claude = marks[i], .since = 1 };
        slots[i] = &wins[i];
    }
    var s: Session = .{ .id = 1, .name = @constCast("arena"), .wins = .fromOwnedSlice(&slots) };
    var pointers = [_]*Session{&s};
    var app: App = .{ .gpa = gpa, .io = undefined, .tmux_in = undefined, .rail = .narrow, .board_view = .{ .home = true } };
    app.sessions = .fromOwnedSlice(&pointers);

    var lines: [16]App.AgentLine = undefined;
    const n = app.agentLines(&lines, 16, false);
    try std.testing.expectEqual(@as(usize, 4), n);
    try std.testing.expect(lines[0] == .session);
    try std.testing.expectEqual(@as(u32, 3), lines[1].agent.win.id + lines[2].agent.win.id);
    try std.testing.expectEqual(@as(usize, 3), lines[3].pipeline.count);

    app.toggleFold(app.foldKey(lines[3].pipeline));
    try std.testing.expectEqual(@as(usize, 7), app.agentLines(&lines, 16, false));
}

test "a find of a hundred bytes narrows the same before and after Enter, and the rail ignores it" {
    var typed_buf: [100]u8 = undefined;
    @memset(&typed_buf, 'x');
    @memcpy(typed_buf[0..6], "needle");
    const typed: []const u8 = &typed_buf;
    const json = try std.fmt.allocPrint(std.testing.allocator,
        \\{{"tickets":[
        \\{{"id":1,"repo":"arena","title":"{s}","status":"todo"}},
        \\{{"id":2,"repo":"arena","title":"needle","status":"todo"}}
        \\]}}
    , .{typed});
    defer std.testing.allocator.free(json);
    var app: App = .{ .gpa = std.testing.allocator, .io = undefined, .tmux_in = undefined };
    app.board = try tickets.Board.parse(std.testing.allocator, json);
    defer app.board.?.deinit();
    var prompt: menu.Prompt = .{ .what = .find };
    @memcpy(prompt.buf[0..typed.len], typed);
    prompt.len = typed.len;
    app.prompt = prompt;
    const typing = app.boardCount(.todo);
    app.keepFind(prompt);
    try std.testing.expectEqual(typed.len, app.find_len);
    try std.testing.expectEqual(typing, app.boardCount(.todo));
    try std.testing.expectEqual(@as(usize, 1), app.boardCount(.todo));
    try std.testing.expectEqual(@as(usize, 2), app.railCount(.todo));
}

test "a card's modal lists every option of its ask and its words, and ⏎ answers the lit one" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const sent = try tmp.dir.createFile(std.testing.io, "tmux", .{ .read = true });
    defer sent.close(std.testing.io);
    var app: App = .{ .gpa = std.testing.allocator, .io = std.testing.io, .tmux_in = sent };
    defer app.pending.deinit(std.testing.allocator);
    app.term_w = 80;
    app.view_w = 80;
    app.view_h = 24;
    app.roles = @import("parts.zig").roles();
    app.board = try tickets.Board.parse(std.testing.allocator,
        \\{"tickets":[
        \\{"id":4,"repo":"tlon","title":"d","status":"doing","ask":{"id":9,"question":"Which?","options":["a long first option that takes the whole row of the modal and more besides it","y","z"]}}
        \\],"needs_you":[{"id":"ask:9","kind":"ask","ticket":4,"repo":"tlon","text":"t",
        \\"actions":[{"key":"1","label":"a"},{"key":"c","label":"in words","argv":["babylon","answer","9","--words"],"needs":"words"}]}]}
    );
    defer app.board.?.deinit();
    app.board_view = .{ .col = 1, .detail = 4 };
    var buttons: [16]App.ModalButton = undefined;
    var rows: [4]u16 = undefined;
    var seen: usize = 0;
    var answer: []const u8 = "";
    for (app.modalButtons(&buttons)) |b| switch (b.action) {
        .option => {
            if (std.mem.eql(u8, b.key, "⏎")) {
                answer = b.label;
            } else {
                rows[seen] = b.y;
                seen += 1;
            }
        },
        .words => {
            rows[3] = b.y;
            try std.testing.expectEqualStrings("c", b.key);
        },
        else => {},
    };
    try std.testing.expectEqualStrings("answer 1", answer);
    try std.testing.expectEqual(@as(usize, 3), seen);
    try std.testing.expect(rows[0] < rows[1] and rows[1] < rows[2] and rows[2] < rows[3]);

    try app.modalKey("\t");
    try app.modalKey("\r");
    try std.testing.expectEqual(@as(?u32, null), app.board_view.?.detail);
    var got: [512]u8 = undefined;
    const len = try sent.readPositionalAll(std.testing.io, &got, 0);
    try std.testing.expect(std.mem.indexOf(u8, got[0..len], "babylon answer 9 2") != null);
}

test "in Workbench's look a click on a popup's option answers the ask and one on its ✕ closes it" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const sent = try tmp.dir.createFile(std.testing.io, "tmux", .{ .read = true });
    defer sent.close(std.testing.io);
    var app: App = .{ .gpa = std.testing.allocator, .io = std.testing.io, .tmux_in = sent };
    defer app.pending.deinit(std.testing.allocator);
    app.term_w = 80;
    app.view_w = 80;
    app.view_h = 24;
    app.roles = @import("parts.zig").roles();
    app.board = try tickets.Board.parse(std.testing.allocator,
        \\{"tickets":[
        \\{"id":4,"repo":"tlon","title":"d","status":"doing","ask":{"id":9,"question":"Which?","options":["x","y"]}}
        \\]}
    );
    defer app.board.?.deinit();
    app.board_view = .{ .col = 1, .detail = 4 };
    const eq = std.testing.expectEqual;
    const rect = app.modalRect().?;

    var buttons: [16]App.ModalButton = undefined;
    const second = for (app.modalButtons(&buttons)) |b| {
        if (b.action == .option and b.action.option == 2) break b;
    } else return error.NoOption;
    try std.testing.expect(try app.boardMouse(.{ .code = 0, .x = second.x + 1, .y = second.y, .release = false }));
    try eq(@as(?u32, null), app.board_view.?.detail);
    var got: [512]u8 = undefined;
    const len = try sent.readPositionalAll(std.testing.io, &got, 0);
    try std.testing.expect(std.mem.indexOf(u8, got[0..len], "babylon answer 9 2") != null);

    app.board_view.?.detail = 4;
    try std.testing.expect(try app.boardMouse(.{ .code = 0, .x = rect.x + rect.w - 4, .y = rect.y, .release = false }));
    try eq(@as(?u32, null), app.board_view.?.detail);
}

test "the plan's pick lights its ticket's Your move item dim in the feed, and the feed's pick moves the plan's" {
    var app: App = .{ .gpa = std.testing.allocator, .io = undefined, .tmux_in = undefined };
    app.term_w = 200;
    app.view_w = 60;
    app.view_h = 40;
    app.board = try tickets.Board.parse(std.testing.allocator,
        \\{"tickets":[],
        \\"needs_you":[
        \\{"id":"a","kind":"ask","ticket":760,"repo":"arena","text":"Which?","actions":[]},
        \\{"id":"b","kind":"sent_back","ticket":338,"repo":"arena","text":"sent back","actions":[]},
        \\{"id":"c","kind":"ask","ticket":55,"repo":"arena","text":"Not in the plan","actions":[]}],
        \\"plan":{"now":[
        \\{"ticket":760,"repo":"arena","title":"One","state":"building"},
        \\{"ticket":338,"repo":"arena","title":"Two","state":"building"},
        \\{"ticket":99,"repo":"arena","title":"Three","state":"building"}]}}
    );
    defer app.board.?.deinit();
    app.board_view = .{ .home = true, .plan = true, .focus = .board };
    const eq = std.testing.expectEqual;
    const view = &app.board_view.?;

    var f: feed.Feed = undefined;
    try std.testing.expect(app.feedOf(&f));
    const item_of = struct {
        fn at(ff: *const feed.Feed, ticket: u32) usize {
            for (0..ff.itemCount()) |i| if (ff.item(i).?.ticket == ticket) return ff.item(i).?.line;
            unreachable;
        }
    }.at;

    // the plan on a ticket the feed has an item for: that item is lit dim
    try app.planKey("j");
    app.settleLit();
    try eq(App.FeedLit.dim, app.feedLit());
    try eq(item_of(&f, 338), app.feedLitItem(&f).?.line);

    // the feed's own pick on a ticket the plan is not on does not move what the plan lights
    view.pick = 2;
    app.settleLit();
    try eq(item_of(&f, 338), app.feedLitItem(&f).?.line);

    // a plan row the feed has no item for lights none
    try app.planKey("j");
    app.settleLit();
    try std.testing.expect(app.feedLitItem(&f) == null);

    // the plan pick moved by anything but a plan key (J and K reorder next so) is followed
    view.plan_pick = 0;
    app.settleLit();
    try eq(item_of(&f, 760), app.feedLitItem(&f).?.line);

    // the feed has the keys: its pick lights its ticket's row dim, and a ticket not in the plan none
    view.focus = .orchestrator;
    app.normal = true;
    var sheet: sheets.Sheet = undefined;
    try std.testing.expect(app.planSheet(&sheet));
    view.pick = 1;
    app.settleLit();
    try eq(App.FeedLit.focused, app.feedLit());
    for (sheet.rows[0..sheet.n]) |row| {
        if (row.kind == .now) try eq(row.ticket.? == 338, app.planRowLit(row));
    }
    view.pick = 2;
    app.settleLit();
    for (sheet.rows[0..sheet.n]) |row| try std.testing.expect(!app.planRowLit(row));

    // moving in the feed moves the plan's pick to the ticket's row, when it has one
    view.pick = 0;
    try std.testing.expect(try app.feedKey("j"));
    try eq(@as(usize, 1), view.plan_pick);
}

test "an item of any kind runs its action's argv: ⏎ on a digest with no ticket and no repo" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const sent = try tmp.dir.createFile(std.testing.io, "tmux", .{ .read = true });
    defer sent.close(std.testing.io);
    var app: App = .{ .gpa = std.testing.allocator, .io = std.testing.io, .tmux_in = sent };
    defer app.pending.deinit(std.testing.allocator);
    app.term_w = 200;
    app.view_w = 60;
    app.view_h = 40;
    app.board = try tickets.Board.parse(std.testing.allocator,
        \\{"tickets":[],"needs_you":[
        \\{"id":"digest:1795536000","kind":"digest","ticket":null,"repo":"","text":"digest","doc":"/home/a/.cache/babylon/digests/2026-11-24.md","actions":[{"label":"seen","key":"⏎","argv":["babylon","digest","ok"]}]}]}
    );
    defer app.board.?.deinit();
    app.board_view = .{ .home = true, .plan = true, .focus = .orchestrator };
    try std.testing.expect(try app.feedKey("\r"));
    var got: [512]u8 = undefined;
    var len = try sent.readPositionalAll(std.testing.io, &got, 0);
    try std.testing.expect(std.mem.indexOf(u8, got[0..len], "'babylon' 'digest' 'ok'") != null);

    // a click on its seen button runs it too
    const before = len;
    var f: feed.Feed = undefined;
    try std.testing.expect(app.feedOf(&f));
    var row: u16 = 0;
    while (f.line(row).kind != .buttons) row += 1;
    // `o open   ⏎ seen`, after the lead of six: seen starts nine cells in
    const x: u16 = app.term_w - app.view_w + 2 + 6 + 10;
    try std.testing.expect(try app.boardMouse(.{ .code = 0, .x = x, .y = row + 1, .release = false }));
    len = try sent.readPositionalAll(std.testing.io, &got, 0);
    try std.testing.expect(len > before);
    try std.testing.expect(std.mem.indexOf(u8, got[before..len], "'babylon' 'digest' 'ok'") != null);
}

test "a row of next dragged onto another takes its place, and a todo card let go on the way back to the plan joins next at its bottom" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const sent = try tmp.dir.createFile(std.testing.io, "tmux", .{ .read = true });
    defer sent.close(std.testing.io);
    var app: App = .{ .gpa = std.testing.allocator, .io = std.testing.io, .tmux_in = sent };
    defer app.pending.deinit(std.testing.allocator);
    defer app.clearReportSaid();
    app.term_w = 200;
    app.view_w = 60;
    app.view_h = 30;
    app.board = try tickets.Board.parse(std.testing.allocator,
        \\{"tickets":[{"id":7,"repo":"arena","title":"c","status":"todo"},{"id":8,"repo":"arena","title":"d","status":"doing"}],
        \\"plan":{"next":[
        \\{"ticket":11,"repo":"arena","title":"a","why":"x"},
        \\{"ticket":12,"repo":"arena","title":"b","why":"y"}]}}
    );
    defer app.board.?.deinit();
    app.board_view = .{ .home = true, .plan = true, .focus = .board };
    const eq = std.testing.expectEqual;

    var sheet: sheets.Sheet = undefined;
    try std.testing.expect(app.planSheet(&sheet));
    var ys: [2]u16 = undefined;
    var n: usize = 0;
    for (sheet.rows[0..sheet.n], 0..) |row, at| if (row.kind == .next) {
        ys[n] = @intCast(2 + at - app.planTop(&sheet));
        n += 1;
    };
    try eq(@as(usize, 2), n);
    const x = app.boardX() + 3;
    try std.testing.expect(try app.boardMouse(.{ .code = 0, .x = x, .y = ys[1], .release = false }));
    try eq(@as(usize, 1), app.drag.next_row.from);
    try app.dragTo(.{ .code = 32, .x = x, .y = ys[0], .release = false });
    try app.dragTo(.{ .code = 0, .x = x, .y = ys[0], .release = true });
    try eq(@as(@TypeOf(app.drag), .none), app.drag);
    var got: [512]u8 = undefined;
    var len = try sent.readPositionalAll(std.testing.io, &got, 0);
    try std.testing.expect(std.mem.indexOf(u8, got[0..len], "'babylon' 'next' '12' '--at' '1'") != null);

    app.board_view = .{};
    app.drag = .{ .card = .{ .id = 8, .opens = false, .moved = true } };
    app.pointer = .{ .x = app.boardX() + 2, .y = 0 };
    try app.dragTo(.{ .code = 0, .x = app.pointer.x, .y = 0, .release = true });
    try std.testing.expect(app.report_failed);
    try std.testing.expect(app.prompt == null);

    app.drag = .{ .card = .{ .id = 7, .opens = false, .moved = true } };
    try app.dragTo(.{ .code = 0, .x = app.pointer.x, .y = 0, .release = true });
    len = try sent.readPositionalAll(std.testing.io, &got, 0);
    try std.testing.expect(std.mem.indexOf(u8, got[0..len], "'babylon' 'next' '7' '--at' '3'") != null);
    try eq(menu.Prompt.What.why, app.prompt.?.what);
}

test "j stays in its column, past the last todo card; a folded repo is its heading alone, skipped by the pick, its ask marked" {
    var app: App = .{ .gpa = std.testing.allocator, .io = undefined, .tmux_in = undefined };
    app.term_w = 140;
    app.view_w = 140;
    app.view_h = 30;
    app.board = try tickets.Board.parse(std.testing.allocator,
        \\{"tickets":[
        \\{"id":1,"repo":"arena","title":"a","status":"todo"},
        \\{"id":2,"repo":"tlon","title":"b","status":"todo"},
        \\{"id":3,"repo":"arena","title":"c","status":"doing"},
        \\{"id":4,"repo":"tlon","title":"d","status":"review","ask":{"id":1,"question":"q?"}}
        \\]}
    );
    defer app.board.?.deinit();
    app.board_view = .{};
    const eq = std.testing.expectEqual;
    const picked = struct {
        fn id(a: *const App) ?u32 {
            const v = a.board_view.?;
            return if (a.boardCard(v.col, v.row)) |c| c.id else null;
        }
    }.id;

    try app.boardKey("j");
    try app.boardKey("j");
    try app.boardKey("j");
    try eq(@as(?u32, 2), picked(&app));
    try eq(@as(usize, 0), app.board_view.?.col);

    try app.boardKey("z");
    try std.testing.expect(app.folded("tlon"));
    try eq(@as(?u32, 1), picked(&app));
    try app.boardKey("j");
    try eq(@as(?u32, 1), picked(&app));
    try eq(@as(usize, 0), app.groupCounts(1, 0).shown);
    try eq(@as(usize, 1), app.groupCounts(1, 0).total);
    try std.testing.expect(app.laneNeeds(1));
    try std.testing.expect(!app.laneNeeds(0));

    try app.boardKey("Z");
    try std.testing.expect(!app.folded("tlon"));
    try app.boardKey("Z");
    try std.testing.expect(app.folded("tlon") and !app.folded("arena"));

    var fresh: App = .{ .gpa = std.testing.allocator, .io = undefined, .tmux_in = undefined };
    fresh.loadFolds("tlon\n\narena\n");
    try std.testing.expect(fresh.folded("tlon") and fresh.folded("arena") and !fresh.folded("menard"));
}

test "a to-try card's modal lists its checks, j and k pick one, y says it works and n asks what went wrong" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const sent = try tmp.dir.createFile(std.testing.io, "tmux", .{ .read = true });
    defer sent.close(std.testing.io);
    var app: App = .{ .gpa = std.testing.allocator, .io = std.testing.io, .tmux_in = sent };
    defer app.pending.deinit(std.testing.allocator);
    app.term_w = 140;
    app.view_w = 140;
    app.view_h = 30;
    app.board = try tickets.Board.parse(std.testing.allocator,
        \\{"tickets":[{"id":7,"repo":"arena","title":"Lights","status":"try","stage":"landed",
        \\"checks":[{"n":1,"text":"it is told","result":"ok"},{"n":2,"text":"it has buttons","result":null},{"n":3,"text":"from the phone","result":null}]}]}
    );
    defer app.board.?.deinit();
    const eq = std.testing.expectEqual;
    const eql = std.testing.expectEqualStrings;

    app.board_view = .{ .col = 3, .detail = 7 };
    const card = app.modalCard().?;
    var head: App.CardHead = undefined;
    App.cardHead(card, 60, 0, false, &head);
    var first: ?usize = null;
    for (head.kinds[0..head.n], 0..) |kind, at| if (kind == .check and first == null) {
        first = at;
    };
    try eq(head.checks, first);
    try eql("✓ 1 it is told", head.lines[first.?]);
    try eql("· 2 it has buttons", head.lines[first.? + 1]);
    try eql("▲ try it: 1 of 3 tried", head.lines[first.? - 1]);

    var buttons: [16]App.ModalButton = undefined;
    var pressed: [3][]const u8 = undefined;
    var found: usize = 0;
    for (app.modalButtons(&buttons)) |button| if (button.action == .tried_ok or button.action == .tried_no) {
        pressed[found] = button.key;
        found += 1;
    };
    try eq(@as(usize, 2), found);
    try eql("y", pressed[0]);

    try app.modalKey("j");
    try eq(@as(u8, 2), app.board_view.?.check_pick);
    try app.modalKey("j");
    try app.modalKey("j");
    try eq(@as(u8, 3), app.board_view.?.check_pick);
    try app.modalKey("k");
    try app.modalKey("y");
    var got: [1024]u8 = undefined;
    var len = try sent.readPositionalAll(std.testing.io, &got, 0);
    try std.testing.expect(std.mem.indexOf(u8, got[0..len], "'babylon' 'tried' '7' '2' 'ok'") != null);

    try app.modalKey("n");
    try eq(menu.Prompt.What.tried, app.prompt.?.what);
    try eql("7:2", app.prompt.?.item());
    for ("late") |byte| _ = app.prompt.?.press(&.{byte});
    try app.commit();
    try std.testing.expect(app.prompt == null);
    len = try sent.readPositionalAll(std.testing.io, &got, 0);
    try std.testing.expect(std.mem.indexOf(u8, got[0..len], "'babylon' 'tried' '7' '2' 'no' 'late'") != null);
}

fn tryApp(sent: std.Io.File, tmp_board: []const u8) !App {
    var app: App = .{ .gpa = std.testing.allocator, .io = std.testing.io, .tmux_in = sent };
    app.term_w = 200;
    app.view_w = 60;
    app.view_h = 40;
    app.epoch = 1795262400;
    app.board_dir = "arena-test-board";
    app.board = try tickets.Board.parse(std.testing.allocator, tmp_board);
    app.board_view = .{ .home = true, .plan = true, .focus = .orchestrator };
    app.normal = true;
    return app;
}

fn sentText(sent: std.Io.File, buf: []u8) ![]const u8 {
    const len = try sent.readPositionalAll(std.testing.io, buf, 0);
    return buf[0..len];
}

/// The cell of the feed `col` cells in, at feed row `row`, as a click.
fn feedPoint(app: *const App, row: usize, col: u16) keys.Mouse {
    return .{ .code = 0, .x = app.term_w - app.view_w + 2 + col, .y = @intCast(row + 1), .release = false };
}

fn rowOf(f: *const feed.Feed, kind: feed.Kind, step: ?usize) usize {
    var row: usize = 0;
    while (!(f.line(row).kind == kind and f.line(row).step == step)) row += 1;
    return row;
}

test "in a to-try tile y settles the picked check, ] and [ go from tile to tile, and x closes it untried" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const sent = try tmp.dir.createFile(std.testing.io, "tmux", .{ .read = true });
    defer sent.close(std.testing.io);
    var app = try tryApp(sent, feed.try_sample);
    defer app.pending.deinit(std.testing.allocator);
    defer app.detail_asked.deinit(std.testing.allocator);
    defer app.board.?.deinit();
    const view = &app.board_view.?;
    const eq = std.testing.expectEqual;
    var got: [2048]u8 = undefined;
    var f: feed.Feed = undefined;

    // the pick goes check to check with j, tile to tile with ] and [, round at either end
    view.pick = 1;
    try std.testing.expect(try app.feedKey("j"));
    try eq(@as(usize, 2), view.pick);
    try std.testing.expect(try app.feedKey("]"));
    try eq(@as(usize, 3), view.pick);
    try std.testing.expect(try app.feedKey("]"));
    try eq(@as(usize, 4), view.pick);
    try std.testing.expect(try app.feedKey("]"));
    try eq(@as(usize, 0), view.pick);
    try std.testing.expect(try app.feedKey("]"));
    try eq(@as(usize, 1), view.pick);
    try std.testing.expect(try app.feedKey("["));
    try eq(@as(usize, 0), view.pick);
    try std.testing.expect(try app.feedKey("["));
    try eq(@as(usize, 4), view.pick);
    try std.testing.expect(try app.feedKey("["));
    try eq(@as(usize, 3), view.pick);
    try std.testing.expect(try app.feedKey("["));
    try eq(@as(usize, 1), view.pick);

    // y runs the check's ok argv; once babylon says it settled, the pick is on the next open one
    try std.testing.expect(try app.feedKey("y"));
    try std.testing.expect(std.mem.indexOf(u8, try sentText(sent, &got), "'babylon' 'tried' '825' '1' 'ok'") != null);
    app.board.?.deinit();
    const after = try std.mem.replaceOwned(u8, std.testing.allocator, feed.try_sample, "with buttons\",\"result\":null", "with buttons\",\"result\":\"ok\"");
    defer std.testing.allocator.free(after);
    app.board = try tickets.Board.parse(std.testing.allocator, after);
    try std.testing.expect(app.feedOf(&f));
    try eq(@as(?usize, 2), app.feedPick(&f).?.step);

    // x runs the tile's close untried
    try std.testing.expect(try app.feedKey("x"));
    try std.testing.expect(std.mem.indexOf(u8, try sentText(sent, &got), "'babylon' 'tried' '825' 'skip'") != null);

    // space opens the ticket's modal
    try std.testing.expect(try app.feedKey(" "));
    try eq(@as(?u32, 825), view.detail);
}

test "n on a check asks what went wrong, ⏎ sends the no argv with the words, esc takes the ✗ back" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const sent = try tmp.dir.createFile(std.testing.io, "tmux", .{ .read = true });
    defer sent.close(std.testing.io);
    var app = try tryApp(sent, feed.try_sample);
    defer app.pending.deinit(std.testing.allocator);
    defer app.board.?.deinit();
    app.board_view.?.pick = 2;
    var got: [2048]u8 = undefined;

    try std.testing.expect(try app.feedKey("n"));
    try std.testing.expectEqual(menu.Prompt.What.words, app.prompt.?.what);
    try std.testing.expect(App.stepWords(app.prompt.?));
    for ("two minutes late") |byte| _ = app.prompt.?.press(&.{byte});
    try app.commit();
    try std.testing.expect(app.prompt == null);
    try std.testing.expect(std.mem.indexOf(u8, try sentText(sent, &got), "'babylon' 'tried' '825' '3' 'no' 'two minutes late'") != null);

    // esc closes the line and runs nothing
    const before = (try sentText(sent, &got)).len;
    try std.testing.expect(try app.feedKey("n"));
    for ("x") |byte| _ = app.prompt.?.press(&.{byte});
    app.endWords();
    try std.testing.expect(app.prompt == null);
    try std.testing.expectEqual(before, (try sentText(sent, &got)).len);
}

test "a click on a to-try tile picks a check, settles it with ✓, fails it with ✗ and the words, opens its modal and closes it untried" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const sent = try tmp.dir.createFile(std.testing.io, "tmux", .{ .read = true });
    defer sent.close(std.testing.io);
    var app = try tryApp(sent, feed.try_sample);
    defer app.pending.deinit(std.testing.allocator);
    defer app.detail_asked.deinit(std.testing.allocator);
    defer app.board.?.deinit();
    const view = &app.board_view.?;
    const eq = std.testing.expectEqual;
    var got: [4096]u8 = undefined;
    var f: feed.Feed = undefined;

    // a click on a check's row picks it
    view.pick = 0;
    try std.testing.expect(app.feedOf(&f));
    try std.testing.expect(try app.boardMouse(feedPoint(&app, rowOf(&f, .try_step, 2), 8)));
    try std.testing.expect(app.feedOf(&f));
    try eq(@as(?usize, 2), app.feedPick(&f).?.step);

    // its buttons show under it; a click on ✓ is y
    const buttons = rowOf(&f, .try_buttons, 2);
    try std.testing.expect(try app.boardMouse(feedPoint(&app, buttons, 3)));
    try std.testing.expect(std.mem.indexOf(u8, try sentText(sent, &got), "'babylon' 'tried' '825' '3' 'ok'") != null);

    // a click on ✗ is n: the line for the words opens, a click outside it does nothing to it
    try std.testing.expect(try app.boardMouse(feedPoint(&app, buttons, 10)));
    try std.testing.expect(App.stepWords(app.prompt.?));
    for ("late") |byte| _ = app.prompt.?.press(&.{byte});
    try app.onMouse(feedPoint(&app, 3, 10));
    try std.testing.expect(app.prompt != null);

    // and one on `send it back` sends it with the words
    const inner: usize = app.view_w - 4;
    const hint = (app.term_w - app.view_w) + 1 + (inner - cellCount(App.back_hint));
    const at = std.mem.indexOf(u8, App.back_hint, "⏎ send it back").?;
    try app.onMouse(.{ .code = 0, .x = @intCast(hint + cellCount(App.back_hint[0..at]) + 3), .y = app.view_h - 2, .release = false });
    try std.testing.expect(app.prompt == null);
    try std.testing.expect(std.mem.indexOf(u8, try sentText(sent, &got), "'babylon' 'tried' '825' '3' 'no' 'late'") != null);

    // the number and the title open the ticket's modal
    try std.testing.expect(app.feedOf(&f));
    try std.testing.expect(try app.boardMouse(feedPoint(&app, rowOf(&f, .try_title, null), 12)));
    try eq(@as(?u32, 825), view.detail);
    view.detail = null;

    // the picked tile's close untried button closes it untried
    try std.testing.expect(app.feedOf(&f));
    const machine = rowOf(&f, .try_machine, null);
    try std.testing.expect(f.line(machine).alt.len > 0);
    try std.testing.expect(try app.boardMouse(feedPoint(&app, machine, 50)));
    try std.testing.expect(std.mem.indexOf(u8, try sentText(sent, &got), "'babylon' 'tried' '825' 'skip'") != null);
}

test "o on a check to look at the diff opens meatcheck on the landed range in a window of its own, with the check's words as its prompt" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const sent = try tmp.dir.createFile(std.testing.io, "tmux", .{ .read = true });
    defer sent.close(std.testing.io);
    var app = try tryApp(sent,
        \\{"tickets":[],"needs_you":[{"id":"try:932","kind":"try","ticket":932,"repo":"arena","text":"#932 arena  Lights","since":"2026-11-21T10:00:00Z","machine":"gate ✓",
        \\"steps":[{"n":2,"text":"look at the change: is the retry bounded?","kind":"look","range":"abc123^..abc123","result":null,"actions":[
        \\{"key":"y","label":"✓","argv":["babylon","tried","932","2","ok"]},{"key":"n","label":"✗","argv":["babylon","tried","932","2","no"],"needs":"words"}]}],"actions":[]}]}
    );
    defer app.pending.deinit(std.testing.allocator);
    defer app.board.?.deinit();
    app.board_view.?.pick = 0;
    var f: feed.Feed = undefined;
    try std.testing.expect(app.feedOf(&f));
    try std.testing.expectEqualStrings("o look   y ✓   n ✗", f.line(rowOf(&f, .try_buttons, 0)).text);

    try std.testing.expect(try app.feedKey("o"));
    var got: [4096]u8 = undefined;
    const said = try sentText(sent, &got);
    try std.testing.expect(std.mem.indexOf(u8, said, "new-window -a -n look") != null);
    try std.testing.expect(std.mem.indexOf(u8, said, "meatcheck --diff") != null);
    try std.testing.expect(std.mem.indexOf(u8, said, "abc123^..abc123") != null);
    try std.testing.expect(std.mem.indexOf(u8, said, "is the retry bounded?") != null);
}
test "a tab clicked lights its list in place, and j and the wheel scroll the panel without resizing the feed" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const sent = try tmp.dir.createFile(std.testing.io, "tmux", .{ .read = true });
    defer sent.close(std.testing.io);
    var app: App = .{ .gpa = std.testing.allocator, .io = std.testing.io, .tmux_in = sent };
    defer app.pending.deinit(std.testing.allocator);
    app.term_w = 200;
    app.view_w = 60;
    app.view_h = 40;
    var json: std.ArrayList(u8) = .empty;
    defer json.deinit(std.testing.allocator);
    try json.appendSlice(std.testing.allocator, "{\"tickets\":[],\"needs_you\":[],\"plan\":{\"next\":[");
    for (0..30) |i| {
        if (i > 0) try json.append(std.testing.allocator, ',');
        try json.print(std.testing.allocator, "{{\"ticket\":{d},\"repo\":\"arena\",\"title\":\"n\",\"why\":\"\",\"set_by\":\"orchestrator\"}}", .{i + 100});
    }
    try json.appendSlice(std.testing.allocator, "]}}");
    app.board = try tickets.Board.parse(std.testing.allocator, json.items);
    defer app.board.?.deinit();
    app.board_view = .{ .home = true, .plan = true, .focus = .orchestrator };
    const view = &app.board_view.?;
    const eq = std.testing.expectEqual;

    var f: feed.Feed = undefined;
    try std.testing.expect(app.feedOf(&f));
    const height = f.height();
    const tabs = f.chips;
    for (tabs) |tab| {
        _ = try app.openChip(.{ .line = 0, .chip = true, .section = tab.section });
        try std.testing.expect(app.feedOf(&f));
        try eq(height, f.height());
    }
    _ = try app.openChip(.{ .line = 0, .chip = true, .section = .next });
    try eq(feed.Section.next, view.tab);

    try std.testing.expect(app.feedOf(&f));
    view.pick = f.firstSpot() + f.popCount() - 1;
    try std.testing.expect(try app.feedKey("j"));
    try eq(@as(usize, 1), view.tab_scroll);
    try std.testing.expect(app.feedOf(&f));
    try eq(f.firstSpot() + f.popCount() - 1, view.pick);
    try std.testing.expect(try app.feedKey("k"));
    try eq(@as(usize, 1), view.tab_scroll);

    view.pick = f.firstSpot();
    try std.testing.expect(try app.feedKey("k"));
    try eq(@as(usize, 0), view.tab_scroll);

    const wheel_y: u16 = @intCast(f.height() + 1 - f.panel);
    const x = app.term_w - app.view_w + 3;
    try std.testing.expect(try app.boardMouse(.{ .code = 65, .x = x, .y = wheel_y, .release = false }));
    try eq(@as(usize, 1), view.tab_scroll);
    try std.testing.expect(try app.boardMouse(.{ .code = 64, .x = x, .y = wheel_y, .release = false }));
    try eq(@as(usize, 0), view.tab_scroll);
    try std.testing.expect(app.feedOf(&f));
    try eq(height, f.height());
}
