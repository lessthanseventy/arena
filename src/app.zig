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
const grab_mod = @import("grab.zig");
const capture = @import("report.zig");
const draw = @import("draw.zig");
const win_feed = @import("win_feed.zig");
const win_driving = @import("win_driving.zig");
const win_goals = @import("win_goals.zig");
const win_landed = @import("win_landed.zig");
const win_move = @import("win_move.zig");
const runcheck = @import("runcheck.zig");
const win_next = @import("win_next.zig");
const win_now = @import("win_now.zig");
const win_unplanned = @import("win_unplanned.zig");
const build_options = @import("build_options");
const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;

const history_lines = 5000;
/// How long the pointer or the pick rests on a ticket or a Claude before a peek opens, and how often an open one is drawn again.
const look_ms = 400;
const look_live_ms = 500;
const quiet_s = 600;
const stir_s = 60;
/// A tmux `run-shell -b` of `cmd` whose output tmux never shows: it would open view mode on a pane,
/// which swallows every key typed to it. What it prints, a refusal, goes to a notification.
pub fn captured(comptime cmd: []const u8) []const u8 {
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
    "#{{window_index}} " ++
    "#{{@arena_claude_doing}}\t#{{@arena_claude_prompt}}\t#{{@arena_claude_title}}\t#{{@arena_claude_said}}\t" ++
    "#{{@arena_claude_branch}}\t#{{@arena_claude_background}}\t#{{@arena_claude_agents}}\t#{{pane_current_path}}\t#{{window_name}}";

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
    /// The colour of the border arena last set on it, none while tmux's own shows.
    frame: ?color.RGB = null,
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
    /// Its place in its session as tmux numbers it, the `2` of `arena:2`.
    index: u32 = 0,
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

    pub const Info = enum { doing, prompt, title, said, branch, background, agents, path };

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
    /// Its place in the order, as arena last left it in tmux; none for a session not yet moved.
    order: u32 = std.math.maxInt(u32),
    wins: std.ArrayList(*Window) = .empty,
    focus: usize = 0,
    scroll: i32 = 0,
    /// False until its strip has been put in place once, and again after a resize.
    placed: bool = false,
    /// Columns take the whole view, with no neighbour peeking.
    full: bool = false,

    /// babylon's own session, where its pipeline runs gates: kept last, off the lists and the
    /// agents, and reached from the board.
    pub fn gate(s: *const Session) bool {
        return std.mem.eql(u8, s.name, "babylon-gate");
    }

    /// The orchestrator's session (`babylon orchestrator` starts it): kept off the lists with the gate.
    pub fn orchestrator(s: *const Session) bool {
        return std.mem.eql(u8, s.name, "orchestrator");
    }

    pub fn unlisted(s: *const Session) bool {
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

pub const HomeView = struct {
    /// Which has the keys and is lit: the board, or the orchestrator's column beside it.
    focus: enum { plan, orchestrator } = .plan,
    /// The session the human was in when arena went to the orchestrator's to have its window
    /// live beside the board: gone back to when the board closes or the side is folded.
    back: ?u32 = null,
    /// The Claudes the picked card can be given to shown over the board, and the one picked.
    giving: ?usize = null,
    /// The ticket whose whole detail is shown over the board, and how far down it is scrolled.
    detail: ?u32 = null,
    detail_scroll: usize = 0,

    /// The option of the modal's open ask that ⏎ answers, from 1.
    ask_pick: u8 = 1,
    /// The check of the modal's to-try ticket that `y` and `n` act on, from 1.
    check_pick: u8 = 1,
    /// The subagent of the modal's Claude that ⏎ shows, from 1; 0 while none is picked and ⏎ goes there.
    sub_pick: u8 = 0,
    /// The open modal is that ticket's gate run, not its detail; and `W` has asked whether to
    /// withdraw it.
    gate: bool = false,
    withdrawing: bool = false,
    /// Auto's settings shown over the board, and the row picked: auto, hold, then each repo.
    auto_pick: ?usize = null,
    /// The `+ goal` modal is over the plan; what it holds is `App.goal`.
    goal_open: bool = false,
    /// A draft's modal is over the board: its epic, the step picked, and whether the keys were in
    /// the orchestrator's column when it opened.
    draft: ?u32 = null,
    draft_pick: usize = 0,
    draft_from_column: bool = false,
    /// The keys were in the orchestrator's column when it opened, and go back there.
    auto_from_column: bool = false,
    auto_normal: bool = false,
    /// The board's keys shown over it, until the next key.
    help: bool = false,
    /// The feed's pick, by its place: Your move's items, then next's and auto's line, then
    /// landing's tickets, then building's.
    pick: usize = 0,
    /// The plan's pick among its rows that can be picked, and the stages unfolded, a bit each.
    plan_pick: usize = 0,
    /// Not planned's chip the pick is on, by its place on the chip row, and whether the backlog's
    /// chip is open, its cards in the rows' place.
    plan_chip: usize = 0,
    plan_backlog: bool = false,
    /// The repo every window of the plan is narrowed to: 0 for every one, else its place in the
    /// board's repos from 1.
    plan_repo: usize = 0,
    unfolded: u8 = 0,
    /// Workbench's plan window shown whole, as a modal over the plan.
    whole: ?sheets.Window = null,
    /// At home with the room of half a screen: the orchestrator's column alone, else the plan
    /// or the board alone.
    alone: bool = true,

    /// Whether a box lies over the board, the keys its own.
    pub fn boxed(view: HomeView) bool {
        return view.help or view.detail != null or view.giving != null or view.auto_pick != null or view.goal_open or view.draft != null or view.whole != null;
    }
};

/// The cards a column of the board can hold, and the repos it can be narrowed to.
pub const max_cards = 256;
const max_ask_options = 9;
/// The Claudes a card can be given to, each picked by its number.
pub const give_rows = 9;
pub const max_repos = 32;
/// The orchestrator's column's width beside the board, kept to 2/5 of the width.
pub const side_w = 60;

pub fn anyKey(pressed: []const u8, names: []const []const u8) bool {
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
    home: ?HomeView = null,
    /// The orchestrator was asked to start: gone to as soon as its session shows, unless the human
    /// has gone somewhere else first.
    orchestrating: bool = false,
    /// The session arena last asked tmux to switch to, until tmux says it is there, and how many
    /// switches tmux has yet to answer.
    heading: ?u32 = null,
    switches: u32 = 0,
    /// The orchestrator's column was folded away: the board opens without it until it is unfolded.
    side_folded: bool = false,

    /// The pointer is on the row under the strip, which then has the windows' names for dots.
    over_dots: bool = false,
    /// Normal mode: keys drive arena and none is typed into a pane. Only held while nothing lies
    /// over the strip, or the orchestrator's column beside the board is focused; otherwise the
    /// overlay is the mode.
    normal: bool = false,

    /// The popup over the strip in normal mode, which holds the keys while it is open.
    popup: ?Popup = null,
    /// The digits typed after `#` in normal mode, a ticket's number to open, while one is being typed.
    hash: [8]u8 = undefined,
    hash_len: ?u8 = null,

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
    /// The strip's width: the terminal's, or with the orchestrator beside the board, its window's.
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

    /// babylon's refusals of what the feed ran for its items, said in their place.
    refusals: std.ArrayList(feed.Refusal) = .empty,
    /// The check whose commands `r` showed, for ⏎ to run.
    check_ask: ?CheckAsk = null,
    /// The checks run in a window of their own, the newest of a check last.
    check_runs: std.ArrayList(CheckRun) = .empty,
    /// babylon's refusal of the board's start, drawn on the card's action row until the next key.
    start_refused: ?[]u8 = null,
    /// What babylon said of the last report filed, drawn on the bottom row until the next key.
    report_said: ?[]u8 = null,
    report_failed: bool = false,
    /// When `report_said` goes by itself, in `now`'s milliseconds; 0 for one that stays until a key.
    report_until: i64 = 0,
    /// What the held left button is moving: the line after a pane, to resize it, a window by
    /// its title, along the strip.
    drag: union(enum) {
        none,
        divider: struct { pane: u32, upright: bool, asked: i32 = -1 },
        title: u32,
        /// A window by its picture in the overview.
        thumb: u32,
        /// Text being selected in a pane, from the cell of it the button went down on.
        select: struct { pane: u32, x: u16, y: u16 },
        /// A click that focused a window: its program gets none of it, not even the let go.
        focus,
        /// A row of the plan's next by its place (from 0), to move to the row it is let go on.
        next_row: struct {
            from: usize,
            /// The press was on the picked row, which a let go without a move goes to.
            opens: bool,
            moved: bool = false,
        },
        /// A todo row of not planned by its ticket, to join next where it is let go.
        todo_row: struct {
            id: u32,
            moved: bool = false,
        },
    } = .none,
    /// The session the open menu asks about closing.
    doomed: u32 = 0,
    /// The pointer's shape, and whether the next frame is to tell the terminal of it.
    shape: []const u8 = "default",
    shape_due: bool = false,
    /// Whether the terminal has been asked to send Shift+Enter as its own key, which an open
    /// words modal reads as a new line.
    words_keys: bool = false,
    /// The text of the window drawn over the rest, and what the mouse has picked of it.
    grab: grab_mod.Grab = .{},
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
    /// Workbench's plan windows folded to their summary, kept in the folds file as `plan:<window>`.
    plan_shut: sheets.Shut = .empty,
    /// The ticket open in each plan window, kept in the folds file as `open:<window>:<ticket>`.
    plan_open: sheets.Open = .initFill(0),
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
        app.grab.deinit(app.gpa);
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

    pub fn sessionIndex(app: *const App, id: ?u32) ?usize {
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

    /// The windows with a Claude, as many as `out` holds, grouped by session, the one with the
    /// first of its Claudes that most wants looking at first.
    pub fn agents(app: *const App, out: []Agent) usize {
        var n: usize = 0;
        for (app.sessions.items, 0..) |s, si| for (s.wins.items) |win| {
            if (s.unlisted()) break;
            if (!win.agent() or n == out.len) continue;
            out[n] = .{ .session = si, .win = win };
            n += 1;
        };
        std.sort.insertion(Agent, out[0..n], app, agentBefore);
        return n;
    }

    pub const max_others = 16;

    /// The Claudes whose branch names no ticket, as many as `out` holds, the most pressing first.
    pub fn otherClaudes(app: *const App, out: []Agent) []Agent {
        var all: [64]Agent = undefined;
        const total = app.agents(&all);
        var n: usize = 0;
        for (all[0..total]) |a| {
            if (n == out.len) break;
            if (branchTicket(a.win.text(.branch)) != null) continue;
            out[n] = a;
            n += 1;
        }
        std.sort.insertion(Agent, out[0..n], {}, otherBefore);
        return out[0..n];
    }

    fn otherBefore(_: void, a: Agent, b: Agent) bool {
        const ua = urgency(a.win);
        const ub = urgency(b.win);
        return ua > ub or (ua == ub and a.win.id < b.win.id);
    }

    /// The `at`th of the Claudes with no ticket, as in-flight's group lists them.
    pub fn otherAt(app: *const App, at: usize) ?Agent {
        var others: [max_others]Agent = undefined;
        const found = app.otherClaudes(&others);
        return if (at < found.len) found[at] else null;
    }

    fn agentBefore(app: *const App, a: Agent, b: Agent) bool {
        if (a.session != b.session) {
            const ra = app.sessionRank(a.session);
            const rb = app.sessionRank(b.session);
            return ra > rb or (ra == rb and a.session < b.session);
        }
        return urgency(a.win) > urgency(b.win);
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

    /// The repo a path is in, `~/projects/<repo>/…` worktrees included; empty for any other.
    pub fn pathRepo(path: []const u8) []const u8 {
        const marker = "/projects/";
        const at = std.mem.indexOf(u8, path, marker) orelse return "";
        const rest = path[at + marker.len ..];
        return rest[0 .. std.mem.indexOfScalar(u8, rest, '/') orelse rest.len];
    }

    /// The repo of a session's lowest ticket, empty for a session holding none.
    pub fn sessionRepo(app: *const App, si: usize) []const u8 {
        return if (app.sessionTicket(si)) |key| key.repo else "";
    }

    /// The repo most of a session's Claudes work in, by where their panes are, never by the
    /// session's name; the first of those tied. Empty for a session with no Claude in a repo.
    pub fn workspaceRepo(app: *const App, si: usize) []const u8 {
        const wins = app.sessions.items[si].wins.items;
        var best: []const u8 = "";
        var most: usize = 0;
        for (wins) |win| {
            if (!win.agent()) continue;
            const repo = pathRepo(win.text(.path));
            if (repo.len == 0) continue;
            var count: usize = 0;
            for (wins) |other| count += @intFromBool(other.agent() and std.mem.eql(u8, pathRepo(other.text(.path)), repo));
            if (count > most) {
                best = repo;
                most = count;
            }
        }
        return best;
    }

    /// Where a Claude's pane is: its session's name, its window's number and its session's repo.
    pub const Workspace = struct { session: []const u8, window: u32, repo: []const u8 };

    pub fn workspace(app: *const App, pane: u32) ?Workspace {
        for (app.sessions.items, 0..) |s, si| for (s.wins.items) |win| for (win.panes.items) |p| {
            if (p.id == pane) return .{ .session = s.name, .window = win.index, .repo = app.workspaceRepo(si) };
        };
        return null;
    }

    /// Whether a pane of this session's tmux is known, for the plan's workspace chips.
    const KnownPanes = struct {
        app: *const App,
        pub fn has(k: KnownPanes, pane: u32) bool {
            return k.app.workspace(pane) != null;
        }
    };

    /// The lowest ticket among a session's Claudes, null for a session holding none.
    fn sessionTicket(app: *const App, si: usize) ?TicketKey {
        var best: ?TicketKey = null;
        for (app.sessions.items[si].wins.items) |win| if (win.agent()) {
            const key = app.ticketKey(win) orelse continue;
            if (best == null or keyBefore(key, best.?)) best = key;
        };
        return best;
    }

    /// The more pressing its state, the higher; of those alike, the longer in it.
    fn urgency(win: *const Window) u64 {
        const since: u64 = if (win.since == 0) std.math.maxInt(u32) else win.since;
        return @as(u64, @backingInt(win.claude)) << 32 | (std.math.maxInt(u32) - since);
    }

    fn sessionRank(app: *const App, si: usize) u64 {
        var best: u64 = 0;
        for (app.sessions.items[si].wins.items) |win| if (win.agent()) {
            best = @max(best, urgency(win));
        };
        return best;
    }

    /// A subagent of a window's Claude, by its place among those in the background.
    pub const Sub = struct { agent: Agent, index: usize };

    /// The pane of the Claude asked for a subagent and the subagent's description, when arena
    /// stops trying, when it last sent a key, and how many Downs it has sent to reach the list.
    const Pick = struct { pane: u32, name: [320]u8 = undefined, len: usize, until: i64, sent_at: i64 = 0, downs: u8 = 0 };

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

    /// The popup over the strip: the window of the Claude it shows, and the
    /// viewport of the pane it shows, which it scrolls and puts back.
    pub const Popup = struct {
        entry: u32,
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
        /// Claude Code's `Enter to select · ↑/↓ to navigate` foot is on the screen: its own question box.
        boxed: bool = false,
    };

    fn entryWindow(app: *const App, entry: u32) ?*Window {
        return (app.agentById(entry) orelse return null).win;
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

    /// The pane of the Claude in window `entry`.
    fn entryPane(app: *App, entry: u32) ?*Pane {
        const a = app.agentById(entry) orelse return null;
        return app.paneById(a.win.agent_pane) orelse a.win.activePane();
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

    fn openPopup(app: *App, entry: u32) void {
        if (app.entryPane(entry) == null) return;
        app.popup = .{ .entry = entry };
        app.popupShow(entry);
    }

    /// Shows `entry` in the popup: its pane's viewport is kept and put at its newest. A pane of a
    /// session tmux does not stream is captured again.
    fn popupShow(app: *App, entry: u32) void {
        const pop = &app.popup.?;
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

    /// Puts away the popup: the pane has its viewport back.
    fn closePopup(app: *App) void {
        if (app.popup == null) return;
        app.popupRestore();
        app.popup = null;
        app.dirty = true;
    }

    /// A key in the popup: `j` `k` `C-d` `C-u` `g` `G` scroll the pane's history, `/` searches it,
    /// Enter goes there into insert, and `q` or Esc close it.
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
            app.normal = false;
            if (app.agentById(entry)) |a| try app.goAgent(a);
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
            try app.showPlan(id);
            if (app.home) |view| if (view.detail == null) {
                _ = try app.openDetail(id);
            };
        }
    }

    /// A key in normal mode over the strip: `j` `k` step to the session below or above, `]` `[` go
    /// to the next or previous Claude waiting or done, space opens the Claude in view and Enter
    /// goes into insert. Whether the key was one of them.
    fn sessionKey(app: *App, key: []const u8) !bool {
        if (app.home != null) return false;
        if (anyKey(key, &.{ "j", "\x1b[B", "\x1bOB" })) {
            try app.sessionBy(1);
        } else if (anyKey(key, &.{ "k", "\x1b[A", "\x1bOA" })) {
            try app.sessionBy(-1);
        } else if (anyKey(key, &.{ "]", "[" })) {
            try app.stepAgent(if (key[0] == ']') 1 else -1);
        } else if (anyKey(key, &.{" "})) {
            const win = (app.cur() orelse return true).focused() orelse return true;
            if (win.agent()) app.openPopup(win.id);
        } else if (anyKey(key, &.{"\r"})) {
            app.normal = false;
        } else return false;
        app.dirty = true;
        return true;
    }

    /// The peek's target is the ticket's card or the Claude's window.
    pub const Look = union(enum) { ticket: u32, window: u32 };

    /// What a peek holds: the ticket and the Claude, either of which may be missing.
    pub const Peek = struct { card: ?*const tickets.Card, win: ?*const Window };

    /// What the pointer rests on, as of `look_at`.
    fn lookUnder(app: *const App, x: u16, y: u16) ?Look {
        if (app.menu != null or app.prompt != null or app.overview != null) return null;
        if (app.home) |view| if (view.boxed()) return null;
        if (app.feedUnder(x, y)) |look| return look;
        if (app.planShown()) {
            var sheet: sheets.Sheet = undefined;
            if (!app.planSheet(&sheet)) return null;
            const row = sheet.rows[app.planRowAt(&sheet, x, y) orelse return null];
            if (row.kind == .other) return .{ .window = (app.otherAt(row.item) orelse return null).win.id };
            return if (opensInPlace(&row)) .{ .ticket = row.ticket.? } else null;
        }
        return null;
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
        if (line >= f.shown or f.line(line).kind == .buttons) return null;
        if (isTryRow(f.line(line).kind)) {
            const need = (app.board orelse return null).needsYou()[f.line(line).need orelse return null];
            return if (need.ticket) |id| .{ .ticket = id } else null;
        }
        var held: ?feed.Item = null;
        for (0..f.itemCount()) |i| {
            const item = f.item(i).?;
            if (item.line <= line) held = item;
        }
        const item = held orelse return null;
        return if (item.ticket) |id| .{ .ticket = id } else null;
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

    /// What the pick is on, the board's card, which a peek follows after a pause with no key.
    fn focusLook(app: *const App) ?Look {
        const view = app.home orelse return null;
        if (!app.key_typed or view.boxed() or view.focus != .plan or app.menu != null or app.prompt != null) return null;
        const card = app.pickedCard() orelse return null;
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
            if (look == .ticket and app.home != null) {
                app.pickPlan(look.ticket);
                app.home.?.focus = .plan;
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
        } else if (std.mem.eql(u8, text, " ")) if (was.?.card) |card| if (app.home != null) {
            _ = try app.openDetail(card.id);
            return true;
        };
        return false;
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

    /// How many items are the human's move.
    pub fn needsCount(app: *const App) usize {
        return if (app.board) |*b| b.needsYou().len else 0;
    }

    /// The strip's width, or with the orchestrator beside the board, its window's.
    pub fn fit(app: *App) void {
        const full = app.term_w;
        app.view_w = if (app.columnAlone()) full else if (app.sided()) @min(side_w, full * 2 / 5) else full;
    }

    /// The terminal width under which home cannot hold the column and the plan side by
    /// side, and shows one at a time.
    pub const half_below = 110;

    /// Whether home has the room of half a screen.
    pub fn halfHome(app: *const App) bool {
        return app.home != null and app.term_w < half_below and app.hasPlan();
    }

    /// Whether home shows the orchestrator's column alone, the plan or the board being one key away.
    pub fn columnAlone(app: *const App) bool {
        return app.halfHome() and app.home.?.alone and !app.side_folded;
    }

    /// Whether the orchestrator's column is beside the open board, unless folded: while the
    /// orchestrator runs, with its window, and at home always, with what babylon says of it. At
    /// half a screen it is beside nothing: the plan or the board has the screen, or it has.
    pub fn sided(app: *const App) bool {
        const view = app.home orelse return false;
        if (app.halfHome() and !view.alone) return false;
        return !app.side_folded;
    }

    /// The orchestrator's drawer opened over home, from the right edge: the whole width at half a
    /// screen. It has the keys, in insert, so typing goes straight to the chat.
    pub fn openDrawer(app: *App) !void {
        if (app.home == null) try app.goHome();
        const view = &app.home.?;
        view.alone = true;
        view.focus = .orchestrator;
        view.help = false;
        view.detail = null;
        app.side_folded = false;
        app.normal = false;
        app.dirty = true;
        app.reflow();
        try app.toSide();
    }

    /// The drawer closed: Plan has the keys, in the session arena was in before it opened.
    pub fn closeDrawer(app: *App) !void {
        const view = &app.home.?;
        view.alone = false;
        view.focus = .plan;
        app.normal = false;
        app.side_folded = true;
        app.dirty = true;
        app.reflow();
        if (view.back) |id| try app.switchTo(id);
        view.back = null;
    }

    /// Whether the drawer is open over home.
    pub fn drawerOpen(app: *const App) bool {
        return app.home != null and !app.side_folded;
    }

    /// Whether the column has the keys: its window's once arena is in its session, else its own.
    pub fn columnFocused(app: *const App) bool {
        const view = app.home orelse return false;
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
        if (app.planShown() and app.workbench()) return false;
        const pick = if (app.home) |view| view.pick else std.math.maxInt(usize);
        var asks: [box_max]Asked = undefined;
        var boxes: [box_max]feed.Box = undefined;
        const n = app.questionBoxes(&asks, &boxes);
        feed.buildPicked(f, b, app.refusals.items, boxes[0..n], app.view_w -| 4, app.view_h -| 2, app.epoch, pick);
        return true;
    }

    pub const box_max = 4;

    /// babylon's refusal of what was asked of Your move item `id`, when it has one.
    pub fn refusalOf(app: *const App, id: []const u8) ?[]const u8 {
        for (app.refusals.items) |r| if (std.mem.eql(u8, r.id, id)) return r.text;
        return null;
    }

    /// The tickets of Your move whose holder's pane shows Claude Code's own question box, with the
    /// options read off it.
    pub fn questionBoxes(app: *const App, asks: *[box_max]Asked, boxes: *[box_max]feed.Box) usize {
        const b = if (app.board) |*b| b else return 0;
        var n: usize = 0;
        for (b.needsYou()) |need| {
            if (n == box_max) break;
            const id = need.ticket orelse continue;
            const pane = app.paneById((app.ticketCard(id) orelse continue).holder() orelse continue) orelse continue;
            asks[n] = .{};
            if (!screenAsk(pane, &asks[n]) or !asks[n].boxed) continue;
            boxes[n] = .{ .ticket = id, .options = asks[n].options[0..asks[n].n] };
            n += 1;
        }
        return n;
    }

    /// Sends option `key` of the question box on the pane of Your move item `need`'s ticket to it:
    /// the human's own keypress, as if typed there. Whether it was one.
    pub fn answerBox(app: *App, need: tickets.Need, key: []const u8) !bool {
        if (key.len != 1 or key[0] < '1' or key[0] > '9') return false;
        const id = need.ticket orelse return false;
        const pane = app.paneById((app.ticketCard(id) orelse return false).holder() orelse return false) orelse return false;
        var asked: Asked = .{};
        if (!screenAsk(pane, &asked) or !asked.boxed or key[0] - '0' > asked.n) return false;
        try app.sendKeys(pane, key);
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
        if (sheet.picked(app.home.?.plan_pick)) |row| app.lit_ticket = row.ticket;
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
        const view = app.home orelse return false;
        if (!app.columnFocused()) return if (row.pick) |p| p == view.plan_pick else false;
        const id = app.lit_ticket orelse return false;
        return row.ticket == id and (row.kind == .now or row.kind == .next);
    }

    /// The plan's pick put on the row of ticket `id` in now or next, when the plan is shown.
    pub fn pickPlan(app: *App, id: u32) void {
        var sheet: sheets.Sheet = undefined;
        if (!app.planSheet(&sheet)) return;
        for (sheet.rows[0..sheet.n]) |row| {
            const pick = row.pick orelse continue;
            if (row.ticket != id or (row.kind != .now and row.kind != .next)) continue;
            app.home.?.plan_pick = pick;
            return;
        }
    }

    /// The feed's pick, kept to what the feed has now: none while it has nothing to pick.
    pub fn feedPick(app: *const App, f: *const feed.Feed) ?feed.Item {
        const view = app.home orelse return null;
        const n = f.itemCount();
        return if (n == 0) null else f.item(@min(view.pick, n - 1));
    }

    /// Whether `prompt` is the words of a to-try check that failed.
    pub fn stepWords(prompt: menu.Prompt) bool {
        return prompt.what == .words and std.mem.indexOfScalar(u8, prompt.item(), '#') != null;
    }

    /// The frame of the modal the human's words are written in: over the orchestrator's column, a
    /// fixed size, whatever is typed.
    pub fn wordsRect(app: *const App) ModalRect {
        const wide: u16 = if (app.view_w >= 30) app.view_w - 2 else app.view_w;
        const h = @min(app.view_h, words_rows);
        return .{ .x = app.term_w - app.view_w + (app.view_w - wide) / 2, .y = (app.view_h - h) / 2, .w = wide, .h = h };
    }

    pub const words_rows: u16 = 16;
    /// Rows of what is being answered, quoted above the box, at most.
    pub const words_quote_rows = 5;

    /// The buttons in the foot of the words modal: send, then cancel.
    pub fn wordsButtons(app: *const App, prompt: menu.Prompt, out: *[2]ModalButton) []ModalButton {
        const rect = app.wordsRect();
        var scratch: [1024]u8 = undefined;
        const about = app.wordsAbout(prompt, &scratch);
        const foot = rect.y + rect.h - 1;
        out[0] = .{ .action = .words, .key = "⏎", .label = about.send, .x = rect.x + 2, .y = foot };
        out[1] = .{ .action = .close, .key = "esc", .label = "cancel", .x = out[0].x + out[0].width() + 1, .y = foot };
        return out[0..2];
    }

    /// A click with the words modal open: send and cancel are its buttons; nothing else in it or
    /// behind it answers, so a stray click does not lose what was written.
    fn wordsClick(app: *App, prompt: menu.Prompt, m: keys.Mouse) !void {
        var buttons: [2]ModalButton = undefined;
        for (app.wordsButtons(prompt, &buttons)) |button| {
            if (!button.hit(m.x, m.y)) continue;
            app.dirty = true;
            switch (button.action) {
                .words => try app.commit(),
                else => app.endWords(),
            }
            return;
        }
    }

    /// What a words modal says of what it answers: its title, the thing quoted above the box and
    /// what its send button says, all in `buf`.
    pub const WordsAbout = struct { title: []const u8, quote: []const u8, send: []const u8 };

    pub fn wordsAbout(app: *const App, prompt: menu.Prompt, buf: []u8) WordsAbout {
        var w: Writer = .fixed(buf);
        const failed: WordsAbout = .{ .title = "✗ What went wrong?", .quote = "", .send = "send it back" };
        const item = prompt.item();
        const b = if (app.board) |*b| b else return .{ .title = "✎ Your words", .quote = "", .send = "send" };
        if (prompt.what == .tried) {
            const colon = std.mem.indexOfScalar(u8, item, ':') orelse return failed;
            const id = std.fmt.parseInt(u32, item[0..colon], 10) catch return failed;
            const n = std.fmt.parseInt(u32, item[colon + 1 ..], 10) catch return failed;
            for (b.cards()) |card| {
                if (card.id != id) continue;
                w.print("#{d} {s}", .{ card.id, card.title }) catch {};
                for (card.checks) |check| if (check.n == n) w.print("\ncheck {d}: {s}", .{ n, check.text }) catch {};
            }
            return .{ .title = failed.title, .quote = w.buffered(), .send = failed.send };
        }
        const hash = std.mem.indexOfScalar(u8, item, '#');
        const need = for (b.needsYou()) |need| {
            if (std.mem.eql(u8, need.id, if (hash) |at| item[0..at] else item)) break need;
        } else return .{ .title = "✎ Your words", .quote = "", .send = "send" };
        w.print("{s}", .{need.text}) catch {};
        if (hash) |at| {
            const n = std.fmt.parseInt(u32, item[at + 1 ..], 10) catch return failed;
            for (need.steps) |step| if (step.n == n) w.print("\ncheck {d}: {s}", .{ n, step.text }) catch {};
            return .{ .title = failed.title, .quote = w.buffered(), .send = failed.send };
        }
        var lead: []const u8 = "\n";
        for (need.actions) |action| {
            if (action.needs != null) continue;
            w.print("{s}{s} {s}", .{ lead, action.key, action.label }) catch {};
            lead = "   ";
        }
        const quote = w.buffered();
        var title: []const u8 = "✎ Your words";
        for (need.actions) |action| {
            const needs = action.needs orelse continue;
            if (!std.mem.eql(u8, needs, "words")) continue;
            title = std.fmt.bufPrint(w.buffer[quote.len..], "✎ {s}", .{action.label}) catch title;
            break;
        }
        return .{ .title = title, .quote = quote, .send = "send" };
    }

    pub fn isTryRow(kind: feed.Kind) bool {
        return switch (kind) {
            .try_title, .try_machine, .try_step, .try_buttons => true,
            else => false,
        };
    }

    /// A line opened at the column's foot for the human's words on Your move item `id`: Enter
    /// runs its words action with them, Escape drops it.
    pub fn openWords(app: *App, id: []const u8) bool {
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
        if (std.mem.startsWith(u8, prompt.item(), "close:")) {
            const id = prompt.item()["close:".len..];
            var said: [40]u8 = undefined;
            const refusal = std.fmt.bufPrint(&said, "close:{s}", .{id}) catch return;
            _ = try app.runNeed(refusal, &.{ "babylon", "update", id, "--status", "done", "--why", prompt.text() });
            return;
        }
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
        const view = if (app.home) |*open| open else return;
        view.plan_pick = 0;
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

    /// Reads `$f` with each empty cell of a table row padded to 30 no-break spaces: glow sizes a
    /// column by its cells' median width, so a column that is mostly empty is drawn a cell wide.
    const pad_empty_cells =
        "{ pad=$(printf '\\302\\240%.0s' $(seq 30)); " ++
        "sed -E ':a; /^\\|/ s/\\| +\\|/|'\"$pad\"'|/; ta' \"$f\"; }";

    /// The doc of a row, opened: a link by `xdg-open`, a file of the ticket's worktree (its repo's
    /// checkout when it has none) in a window of its own, in `glow` else `less`.
    pub fn openDoc(app: *App, need: tickets.Need) !bool {
        const doc = need.doc orelse return true;
        if (std.mem.startsWith(u8, doc, "http://") or std.mem.startsWith(u8, doc, "https://")) {
            return app.runNeed(need.id, &.{ "xdg-open", doc });
        }
        if (!plainName(need.repo)) return true;
        const script =
            "f=\"$HOME/projects/$1/$2\"; " ++
            "if [ -n \"$3\" ]; then for d in \"$HOME/projects/$1/.worktrees/t$3-\"*/; do [ -f \"$d$2\" ] && f=\"$d$2\" && break; done; fi; " ++
            "if [ ! -f \"$f\" ]; then echo \"no such file: $f\"; read _; exit; fi; " ++
            "if command -v glow >/dev/null 2>&1; then " ++ pad_empty_cells ++ " | glow -p -; else less \"$f\"; fi";
        var cmd: Writer.Allocating = .init(app.gpa);
        defer cmd.deinit();
        var ticket_buf: [16]u8 = undefined;
        const ticket = if (need.ticket) |t| std.fmt.bufPrint(&ticket_buf, "{d}", .{t}) catch "" else "";
        try cmd.writer.writeAll("new-window -a -n ");
        try writeDocWindow(&cmd.writer, need.id);
        try cmd.writer.writeAll(" sh -c ");
        for ([_][]const u8{ script, "_", need.repo, doc, ticket }, 0..) |arg, i| {
            if (i > 0) try cmd.writer.writeAll(" ");
            try tmuxQuote(&cmd.writer, arg);
        }
        try app.closeBoard();
        try app.send(.ignore, "{s}", .{cmd.written()});
        return true;
    }

    /// meatcheck prints TOON: `comments[N]{cols}:` then a row per comment, a text with a comma,
    /// colon or quote JSON-quoted, its newlines as `\n`. The columns are read from the header.
    const toon_words =
        "function parse(s, f,  n, i, L, c, v, d) { n = 0; i = 1; L = length(s); " ++
        "while (i <= L + 1) { v = \"\"; " ++
        "if (substr(s, i, 1) == q) { i++; while (i <= L) { c = substr(s, i, 1); " ++
        "if (c == bs) { d = substr(s, i + 1, 1); v = v (d ~ /^[nrt]$/ ? \" \" : d); i += 2 } " ++
        "else if (c == q) { i++; break } else { v = v c; i++ } } } " ++
        "else { while (i <= L && substr(s, i, 1) != \",\") { v = v substr(s, i, 1); i++ } } " ++
        "f[++n] = v; i++ } return n } " ++
        "BEGIN { q = sprintf(\"%c\", 34); bs = sprintf(\"%c\", 92) } " ++
        "NR == 1 { s = $0; sub(/^[^{]*\\{/, \"\", s); sub(/\\}:.*$/, \"\", s); n = parse(s, h); for (k = 1; k <= n; k++) col[h[k]] = k } " ++
        "NR > 1 && /^ / { s = $0; sub(/^ +/, \"\", s); parse(s, r); " ++
        "a = r[col[\"start_line\"]]; b = r[col[\"end_line\"]]; " ++
        "printf \"%s:%s: %s\\n\", r[col[\"path\"]], (a == b ? a : a \"-\" b), r[col[\"text\"]] }";

    /// `o` on a check to look at the diff: meatcheck on the landed change, in a window of its own
    /// so no Claude waits on it, its comments back as the ✗'s words, none as ✓.
    pub fn lookAtDiff(app: *App, need: tickets.Need, step: tickets.TryStep) !bool {
        const ticket = need.ticket orelse return true;
        if (!plainName(need.repo)) return true;
        const script =
            "cd \"$HOME/projects/$1\" || exit; " ++
            "d=$(mktemp) && git diff \"$2\" >\"$d\" && out=$(meatcheck --diff \"$d\" --prompt \"$3\"); rc=$?; rm -f \"$d\"; " ++
            "[ $rc -eq 0 ] || { echo \"meatcheck failed\"; read _; exit; }; " ++
            "words=$(printf '%s\\n' \"$out\" | awk '" ++ toon_words ++ "'); " ++
            "if [ -z \"$words\" ]; then babylon tried \"$4\" \"$5\" ok; else babylon tried \"$4\" \"$5\" no \"$words\"; fi";
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
    pub fn runNeed(app: *App, id: []const u8, argv: []const []const u8) !bool {
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

    pub const CheckAsk = struct { ticket: u32, n: u32, cmds: [512]u8 = undefined, len: usize = 0 };
    pub const CheckRun = struct { ticket: u32, n: u32, pane: ?u32 = null, done: bool = false };

    /// What arena says of check `n` of ticket `ticket`, under its tile and in its modal, as the
    /// lines of `text`.
    fn checkNote(app: *App, ticket: u32, comptime fmt: []const u8, args: anytype) !void {
        var id: [24]u8 = undefined;
        var clean: std.ArrayList(u8) = .empty;
        defer clean.deinit(app.gpa);
        var raw: [4096]u8 = undefined;
        const text = std.fmt.bufPrint(&raw, fmt, args) catch return;
        try @import("text.zig").appendClean(&clean, app.gpa, text);
        const owned_id = try app.gpa.dupe(u8, std.fmt.bufPrint(&id, "try:{d}", .{ticket}) catch return);
        errdefer app.gpa.free(owned_id);
        app.dropRefusal(owned_id);
        try app.refusals.append(app.gpa, .{ .id = owned_id, .text = try clean.toOwnedSlice(app.gpa) });
        app.dirty = true;
    }

    /// `r` on check `n` of ticket `ticket`, whose words are `text`: shows the commands in them,
    /// which run only on ⏎. Whether the text held any.
    pub fn checkOffer(app: *App, ticket: u32, n: u32, text: []const u8) !bool {
        var ask: CheckAsk = .{ .ticket = ticket, .n = n };
        const found = runcheck.find(text, &ask.cmds);
        if (found.len == 0) return false;
        ask.len = found.len;
        app.check_ask = ask;
        try app.checkNote(ticket, "run check {d}?\n{s}\n⏎ run · esc cancel", .{ n, found });
        return true;
    }

    /// The ask dropped, with what it said.
    pub fn checkCancel(app: *App) void {
        const ask = app.check_ask orelse return;
        app.check_ask = null;
        var id: [24]u8 = undefined;
        app.dropRefusal(std.fmt.bufPrint(&id, "try:{d}", .{ask.ticket}) catch return);
        app.dirty = true;
    }

    /// Where check `n` of ticket `ticket` writes its exit code and output while it runs.
    fn checkDir(app: *const App, ticket: u32, n: u32, buf: []u8) ?[]const u8 {
        const dir = app.board_dir orelse return null;
        return std.fmt.bufPrint(buf, "{s}/check-{d}-{d}", .{ dir, ticket, n }) catch null;
    }

    /// ⏎ on the ask: its commands run in a window of their own named `check #N`, which stays
    /// open for the output; arena reads the exit code and the last lines off its files.
    pub fn checkStart(app: *App) !void {
        const ask = app.check_ask orelse return;
        app.check_ask = null;
        var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
        const dir = app.checkDir(ask.ticket, ask.n, &dir_buf) orelse return app.checkCancel();
        const script =
            "d=$1; mkdir -p \"$d\" && rm -f \"$d/rc\" \"$d/out\" && printf '%s' \"${TMUX_PANE#%}\" >\"$d/pane\"; " ++
            "{ sh -c \"$2\"; echo $? >\"$d/rc.t\"; } 2>&1 | tee \"$d/out\"; mv \"$d/rc.t\" \"$d/rc\"; " ++
            "printf '\\nexit %s · ⏎ closes\\n' \"$(cat \"$d/rc\")\"; read _";
        var cmd: Writer.Allocating = .init(app.gpa);
        defer cmd.deinit();
        try cmd.writer.print("new-window -d -a -n \"check ##{d}\" sh -c ", .{ask.ticket});
        for ([_][]const u8{ script, "_", dir, ask.cmds[0..ask.len] }, 0..) |arg, i| {
            if (i > 0) try cmd.writer.writeAll(" ");
            try tmuxQuote(&cmd.writer, arg);
        }
        for ([_][]const u8{ "rc", "pane", "out" }) |name| {
            var path: [std.fs.max_path_bytes]u8 = undefined;
            const at = std.fmt.bufPrint(&path, "{s}/{s}", .{ dir, name }) catch continue;
            std.Io.Dir.cwd().deleteFile(app.io, at) catch {};
        }
        try app.send(.ignore, "{s}", .{cmd.written()});
        for (app.check_runs.items, 0..) |run, i| if (run.ticket == ask.ticket and run.n == ask.n) {
            _ = app.check_runs.orderedRemove(i);
            break;
        };
        try app.check_runs.append(app.gpa, .{ .ticket = ask.ticket, .n = ask.n });
        try app.checkNote(ask.ticket, "check {d} running · ⏎ to its window", .{ask.n});
    }

    /// The window a check was run in: its last run's.
    pub fn checkRunOf(app: *const App, ticket: u32, n: u32) ?CheckRun {
        var found: ?CheckRun = null;
        for (app.check_runs.items) |run| if (run.ticket == ticket and run.n == n) {
            found = run;
        };
        return found;
    }

    /// Reads what the running checks wrote: the pane of the window, then the exit code and the
    /// last five lines of output, which are said under the check.
    pub fn checkPoll(app: *App) !void {
        for (app.check_runs.items) |*run| {
            if (run.done) continue;
            var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
            const dir = app.checkDir(run.ticket, run.n, &dir_buf) orelse continue;
            if (run.pane == null) if (app.readCheckFile(dir, "pane")) |text| {
                defer app.gpa.free(text);
                run.pane = std.fmt.parseInt(u32, std.mem.trim(u8, text, " \n"), 10) catch null;
            };
            const rc = app.readCheckFile(dir, "rc") orelse continue;
            defer app.gpa.free(rc);
            run.done = true;
            const out = app.readCheckFile(dir, "out") orelse try app.gpa.dupe(u8, "");
            defer app.gpa.free(out);
            var tail: [2048]u8 = undefined;
            try app.checkNote(run.ticket, "check {d}: exit {s}\n{s}\n⏎ to its window", .{ run.n, std.mem.trim(u8, rc, " \n"), lastLines(out, 5, &tail) });
        }
    }

    fn readCheckFile(app: *const App, dir: []const u8, name: []const u8) ?[]u8 {
        var path: [std.fs.max_path_bytes]u8 = undefined;
        const at = std.fmt.bufPrint(&path, "{s}/{s}", .{ dir, name }) catch return null;
        return std.Io.Dir.cwd().readFileAlloc(app.io, at, app.gpa, .limited(1 << 16)) catch null;
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
        if (app.home == null) return;
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
        if (app.home) |view| if (view.goal_open) return false;
        if (app.overview != null or app.popup != null) return false;
        return if (app.home) |view| !view.boxed() else true;
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
    pub fn sideDue(app: *const App) bool {
        const s = app.sessionById(app.bound()) orelse return false;
        return app.sided() and s.orchestrator();
    }

    /// Whether its column is the one focused: the keys and the mouse are then its own, as any
    /// window's.
    pub fn sideFocused(app: *const App) bool {
        const view = app.home orelse return false;
        return view.focus == .orchestrator and !view.boxed() and app.sideDue();
    }

    pub fn boardW(app: *const App) u16 {
        return app.term_w;
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
            .card => |id| try app.showPlan(id),
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
                if (a.unlisted() != b.unlisted()) return b.unlisted();
                // tmux lists sessions by name: with no place of their own, the oldest first
                return a.order < b.order or (a.order == b.order and a.id < b.id);
            }
        }.before);
        if (app.home) |*view| {
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
            var n: [24]u32 = undefined;
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
                    win.index = n[23];
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
        try app.frameSync();
        for (old_wins.items) |win| win.destroy(app.gpa);

        for (app.sessions.items, 0..) |s, i| {
            const follow = app.follow_active and s.id == app.current;
            if (!follow and i < focus_ids.items.len) if (focus_ids.items[i]) |id| for (s.wins.items, 0..) |win, at| {
                if (win.id == id) s.focus = at;
            };
            if (!s.placed) s.scroll = app.target(s);
            s.placed = true;
        }
        try app.syncWaiting();
        try app.notify();
        app.follow_active = false;
        if (app.cur()) |s| try app.see(s);
        try app.settle();
        if (app.cur()) |s| app.listed = app.listed or s.wins.items.len > 0;
        app.dirty = true;
    }

    /// Whether a Claude's change of state is a notice: it came to wait on the human's answer or
    /// to stall. A finished turn is not, nor is a worker on its own background shell.
    pub fn notifies(was: Mark, now: Mark) bool {
        return now != was and (now == .waiting or now == .stalled);
    }

    /// A desktop notification for each Claude come to wait on an answer or stall since the list
    /// before, other than the one in view: notify-send, where there is one, run by tmux, which
    /// quotes the hook's text for the shell itself. One notice a pane: a later one replaces it.
    fn notify(app: *App) !void {
        for (app.sessions.items) |s| for (s.wins.items) |win| {
            const was = win.was orelse continue;
            if (!notifies(was, win.claude)) continue;
            if (s.id == app.current and s.focused() == win) continue;
            try app.send(.ignore, "run-shell -b -t %{d} \"command -v notify-send >/dev/null && notify-send -a arena " ++
                "--hint=string:x-canonical-private-synchronous:arena-%{d} -- " ++
                "#{{?@arena_claude_title,#{{q:@arena_claude_title}},#{{q:window_name}}}} {s}\"", .{
                win.agent_pane,
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
        if (next < 0 or next >= app.listedSessions()) return;
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

    const Name = union(enum) { window: u32, pane: u32 };

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
        try app.osc52(text);
    }

    /// Puts `text` on the clipboard and says how much, in the foot, for a moment.
    pub fn copyText(app: *App, text: []const u8) !void {
        if (text.len == 0) return;
        try app.osc52(text);
        var said: [32]u8 = undefined;
        const line = std.fmt.bufPrint(&said, "copied {d} chars", .{cellCount(text)}) catch return;
        app.clearReportSaid();
        app.report_said = try app.gpa.dupe(u8, line);
        app.report_failed = false;
        app.report_until = app.now + copied_ms;
        app.dirty = true;
    }

    /// How long the foot says what was copied.
    const copied_ms = 1500;

    fn osc52(app: *App, text: []const u8) !void {
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
        if (session < first or session >= first + shown or session >= app.listedSessions()) return null;
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
        const count = app.listedSessions();
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
        var old = app.board;
        app.board = if (text) |t| tickets.Board.parse(app.gpa, t) catch null else null;
        if (old) |*b| {
            try app.closeGoneDocs(b);
            b.deinit();
        }
        if (!app.hasPlan()) try app.closeBoard();
        try app.syncWaiting();
        try app.frameSync();
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
        app.dirty = true;
    }

    /// Your move's items for the Claudes waiting in their panes, put after babylon's: babylon does
    /// not know of them. Each leaves with the window's state.
    fn syncWaiting(app: *App) !void {
        const b = if (app.board) |*b| b else return;
        var items: std.ArrayList(tickets.Need) = .empty;
        defer items.deinit(app.gpa);
        var texts: Writer.Allocating = .init(app.gpa);
        defer texts.deinit();
        var ends: std.ArrayList(usize) = .empty;
        defer ends.deinit(app.gpa);
        for (app.sessions.items) |s| for (s.wins.items) |win| {
            if (win.claude != .waiting) continue;
            const ticket = if (branchTicket(win.text(.branch))) |digits| std.fmt.parseInt(u32, digits, 10) catch null else null;
            const on = win.text(.doing);
            if (ticket == null) try texts.writer.print("{s}:{d} ", .{ s.name, win.index });
            try texts.writer.writeAll("waits in its pane");
            if (on.len > 0) try texts.writer.print(": {s}", .{on});
            try ends.append(app.gpa, texts.written().len);
            try items.append(app.gpa, .{
                .id = try std.fmt.allocPrint(app.gpa, "pane:{d}", .{win.id}),
                .kind = "pane",
                .ticket = ticket,
                .repo = if (ticket) |t| if (app.ticketCard(t)) |card| card.repo orelse "" else "" else "",
                .text = "",
            });
        };
        defer for (items.items) |item| app.gpa.free(item.id);
        var from: usize = 0;
        for (items.items, ends.items) |*item, end| {
            item.text = texts.written()[from..end];
            from = end;
        }
        try b.setOwn(app.gpa, items.items);
    }

    /// The doc window of each ask in `old` that the board now shown no longer holds, answered or
    /// withdrawn, closed.
    fn closeGoneDocs(app: *App, old: *const tickets.Board) !void {
        const now = if (app.board) |*b| b.needsYou() else &.{};
        for (old.needsYou()) |need| {
            if (need.doc == null) continue;
            const still = for (now) |n| {
                if (std.mem.eql(u8, n.id, need.id)) break true;
            } else false;
            if (still) continue;
            var cmd: Writer.Allocating = .init(app.gpa);
            defer cmd.deinit();
            try cmd.writer.writeAll("kill-window -t =");
            try writeDocWindow(&cmd.writer, need.id);
            try app.send(.ignore, "{s}", .{cmd.written()});
        }
    }

    /// The name of the window that shows the doc of the ask `id`; tmux reads a `:` in a target as
    /// a session's end, so it is a `-`.
    fn writeDocWindow(w: *Writer, id: []const u8) !void {
        try w.writeAll("doc-");
        for (id) |c| try w.writeByte(if (c == ':') '-' else c);
    }

    fn toggleHome(app: *App) !void {
        app.orchestrating = false;
        app.dirty = true;
        if (app.home != null) return app.closeBoard();
        try app.goHome();
    }

    /// Home's plan opened with the pick on ticket `id`: what `arena plan <id>` asks for. The find
    /// line and the repo filter are cleared, and a window folded over the ticket is opened. A
    /// ticket the plan shows in no window opens its detail instead; with no plan, nothing opens.
    pub fn showPlan(app: *App, id: u32) !void {
        if (!app.hasPlan()) return;
        app.menu = null;
        app.prompt = null;
        app.overview = null;
        app.orchestrating = false;
        app.normal = false;
        app.dirty = true;
        app.find_len = 0;
        if (app.home == null) app.home = .{};
        const view = &app.home.?;
        view.help = false;
        view.detail = null;
        view.giving = null;
        view.whole = null;
        view.plan_repo = 0;
        view.alone = false;
        view.focus = .plan;
        if (!try app.pickPlanTicket(id)) _ = try app.openDetail(id);
        app.reflow();
        try app.toSide();
    }

    /// The plan's pick put on ticket `id`, the window it is in opened first when it is folded, and
    /// its repo's chip in not planned as a click on it leaves it.
    /// False when no window of the plan holds it.
    fn pickPlanTicket(app: *App, id: u32) !bool {
        const view = &app.home.?;
        var sheet: sheets.Sheet = undefined;
        if (!app.planSheet(&sheet)) return false;
        if (planPickOf(&sheet, id)) |pick| {
            view.plan_pick = pick;
            return true;
        }
        for (std.enums.values(sheets.Window)) |win| {
            if (!app.plan_shut.contains(win)) continue;
            app.plan_shut.remove(win);
            if (app.planSheet(&sheet)) if (planPickOf(&sheet, id)) |pick| {
                view.plan_pick = pick;
                try app.saveFolds();
                return true;
            };
            app.plan_shut.insert(win);
        }
        const repo = (app.cardById(id) orelse return false).repo orelse return false;
        if (!app.folded(repo)) return false;
        const unplanned_shut = app.plan_shut.contains(.unplanned);
        app.plan_shut.remove(.unplanned);
        try app.toggleRepoFold(repo);
        if (app.planSheet(&sheet)) if (planPickOf(&sheet, id)) |pick| {
            view.plan_pick = pick;
            try app.saveFolds();
            return true;
        };
        if (unplanned_shut) app.plan_shut.insert(.unplanned);
        try app.toggleRepoFold(repo);
        return false;
    }

    fn planPickOf(sheet: *const sheets.Sheet, id: u32) ?usize {
        for (sheet.rows[0..sheet.n]) |row| if (row.ticket == id) if (row.pick) |pick| return pick;
        return null;
    }

    /// Ticket `id`'s whole detail asked of babylon and shown over the open board. False with
    /// nowhere for babylon to write it.
    pub fn openDetail(app: *App, id: u32) !bool {
        return app.openText(id, "detail", false);
    }

    /// Ticket `id`'s gate run, the run in progress's when it has one, in the modal frame.
    pub fn openGate(app: *App, id: u32) !void {
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
        const view = &app.home.?;
        // tmux gives a control client run-shell's output outside its reply, so it comes by a file
        std.Io.Dir.cwd().deleteFile(app.io, path) catch {};
        if (app.detail_asked.items.len == 16) _ = app.detail_asked.orderedRemove(0);
        try app.detail_asked.append(app.gpa, id);
        view.detail = id;
        view.detail_scroll = 0;
        view.ask_pick = 1;
        view.check_pick = 1;
        view.sub_pick = 0;
        view.gate = gate;
        view.withdrawing = false;
        app.detail.clearRetainingCapacity();
        try app.send(.ignore, "run-shell -b \"babylon " ++ cmd ++ " {d} >'{s}.part' 2>&1; mv '{s}.part' '{s}'\"", .{ id, path, path, path });
        return true;
    }

    /// The board put away, and the side with it, back in the session the human was in.
    fn closeBoard(app: *App) !void {
        const view = app.home orelse return;
        app.home = null;
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
        const view = &app.home.?;
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

    /// The rows the card's detail takes in its box.
    pub fn detailRows(app: *const App) usize {
        const inner = detailWidth(app.boardW()).inner;
        if (app.home) |view| if (view.gate) return gateOutputRows(gateOutput(gateLastRun(app.detail.items)), inner);
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

    /// What the board's cards are narrowed to: what is being typed after `/`, else what Enter kept.
    pub fn findText(app: *const App) []const u8 {
        if (app.prompt) |*prompt| if (prompt.what == .find) return prompt.text();
        return app.find[0..app.find_len];
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
        while (lines.next()) |line| {
            if (line.len == 0) continue;
            if (std.mem.startsWith(u8, line, plan_fold)) {
                if (std.meta.stringToEnum(sheets.Window, line[plan_fold.len..])) |win| app.plan_shut.insert(win);
            } else if (std.mem.startsWith(u8, line, plan_opened)) {
                const rest = line[plan_opened.len..];
                const colon = std.mem.indexOfScalar(u8, rest, ':') orelse continue;
                const win = std.meta.stringToEnum(sheets.Window, rest[0..colon]) orelse continue;
                app.plan_open.set(win, std.fmt.parseInt(u32, rest[colon + 1 ..], 10) catch continue);
            } else app.setFold(line, true);
        }
    }

    const plan_fold = "plan:";
    const plan_opened = "open:";

    fn saveFolds(app: *App) !void {
        const path = app.folds_path orelse return;
        var data: Writer.Allocating = .init(app.gpa);
        defer data.deinit();
        for (0..app.fold_n) |i| try data.writer.print("{s}\n", .{app.folds[i][0..app.fold_lens[i]]});
        var shut = app.plan_shut.iterator();
        while (shut.next()) |win| try data.writer.print(plan_fold ++ "{s}\n", .{@tagName(win)});
        var opened = app.plan_open.iterator();
        while (opened.next()) |entry| if (entry.value.* != 0) try data.writer.print(plan_opened ++ "{s}:{d}\n", .{ @tagName(entry.key), entry.value.* });
        if (std.fs.path.dirname(path)) |dir| std.Io.Dir.cwd().createDirPath(app.io, dir) catch return;
        std.Io.Dir.cwd().writeFile(app.io, .{ .sub_path = path, .data = data.written() }) catch {};
    }

    /// A repo's group folded, or unfolded, in every column; the pick moves off a folded group.
    pub fn toggleRepoFold(app: *App, repo: []const u8) !void {
        app.setFold(repo, !app.folded(repo));
        app.dirty = true;
        try app.saveFolds();
    }

    /// Every group but `keep`'s folded; with any folded, all unfolded instead.
    fn focusFold(app: *App, keep: []const u8) !void {
        if (app.fold_n > 0) {
            app.fold_n = 0;
        } else {
            var repos: [max_repos][]const u8 = undefined;
            const b = if (app.board) |*b| b else return;
            for (repos[0..b.repos(&repos)]) |repo| if (!std.mem.eql(u8, repo, keep)) app.setFold(repo, true);
        }
        app.dirty = true;
        try app.saveFolds();
    }

    /// Whether the board is drawn in Workbench's look, which has geometry of its own.
    pub fn workbench(app: *const App) bool {
        return app.roles != null;
    }

    pub fn cardTitle(card: *const tickets.Card, buf: []u8) []const u8 {
        return std.fmt.bufPrint(buf, "#{d} {s}", .{ card.id, card.title }) catch card.title;
    }

    /// The window with pane `id` in it, and that window's place in its session.
    pub fn paneWindow(app: *const App, id: u32) ?struct { session: *Session, index: usize } {
        for (app.sessions.items) |s| for (s.wins.items, 0..) |win, wi| for (win.panes.items) |pane| {
            if (pane.id == id) return .{ .session = s, .index = wi };
        };
        return null;
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
        if (!app.hasPlan()) return;
        app.menu = null;
        app.prompt = null;
        app.overview = null;
        app.orchestrating = false;
        app.normal = false;
        app.dirty = true;
        if (app.home == null) app.home = .{};
        const view = &app.home.?;
        view.help = false;
        view.detail = null;
        view.giving = null;
        app.side_folded = true;
        view.alone = false;
        view.focus = .plan;
        app.reflow();
    }

    /// Whether babylon's file carries a plan.
    pub fn hasPlan(app: *const App) bool {
        return if (app.board) |*b| b.plan() != null else false;
    }

    /// Whether home draws the plan, in the board's place.
    pub fn planShown(app: *const App) bool {
        return app.home != null and app.hasPlan();
    }

    /// The plan laid out in rows for the board's width, less the cell the pick bar takes; false
    /// when it is not shown.
    pub fn planSheet(app: *const App, sheet: *sheets.Sheet) bool {
        if (!app.planShown()) return false;
        const b = &app.board.?;
        const view = app.home.?;
        var shut = app.plan_shut;
        if (view.whole) |win| shut.remove(win);
        var repos: [max_repos][]const u8 = undefined;
        sheet.build(b.plan().?, b, app.boardW() -| 1, app.epoch, view.unfolded, app.halfHome(), app.workbench(), shut, app.planSee(&repos));
        app.narrowPlan(sheet);
        if (app.workbench()) {
            sheet.withNeedCards(app.plan_open, b, app.planRect(.move).w -| 1);
            sheet.withWhyOnPick(app);
            sheet.withButtons(app.plan_open);
            sheet.withHeld(b.plan().?, KnownPanes{ .app = app });
            var others: [max_others]Agent = undefined;
            sheet.withOthers(app.otherClaudes(&others).len, app.findText());
        }
        return true;
    }

    /// What not planned shows: the repos folded, held in `out`, and the backlog's chip open or not.
    pub fn planSee(app: *const App, out: *[max_repos][]const u8) sheets.See {
        for (0..app.fold_n) |i| out[i] = app.folds[i][0..app.fold_lens[i]];
        return .{ .repos_shut = out[0..app.fold_n], .backlog = if (app.home) |view| view.plan_backlog else false };
    }

    /// Not planned's chips where they are drawn and clicked, on the screen.
    pub fn chipsOf(app: *const App, out: []sheets.Chip) []sheets.Chip {
        const b = if (app.board) |*b| b else return out[0..0];
        const given = b.plan() orelse return out[0..0];
        var backlog: usize = 0;
        for (b.backlog()) |*card| backlog += @intFromBool(!card.isEpic());
        const rect = app.planRect(.unplanned);
        return sheets.chipsAt(given, backlog, rect.x + 2, rect.w -| 4, out);
    }

    /// `sheet` narrowed to the plan's repo and to what the find line holds.
    pub fn narrowPlan(app: *const App, sheet: *sheets.Sheet) void {
        const b = &app.board.?;
        sheet.narrowTo(b.plan().?, b, app.planRepo() orelse "", app.findText());
    }

    /// The repo the plan is narrowed to; null for every one.
    pub fn planRepo(app: *const App) ?[]const u8 {
        const view = app.home orelse return null;
        const b = if (app.board) |*b| b else return null;
        var repos: [max_repos][]const u8 = undefined;
        const n = b.repos(&repos);
        return if (view.plan_repo >= 1 and view.plan_repo <= n) repos[view.plan_repo - 1] else null;
    }

    pub const RepoTab = struct { repo: usize, x: u16, w: u16 };

    /// Where the head draws and clicks the repo filter, `every` and then each repo, that fit
    /// before the right group; and the first cell after them.
    pub fn planRepoTabs(app: *const App, out: []RepoTab) struct { n: usize, end: u16 } {
        const b = if (app.board) |*b| b else return .{ .n = 0, .end = 0 };
        var repos: [max_repos][]const u8 = undefined;
        const count = b.repos(&repos);
        const orch: usize = if (app.halfHome()) cellCount(orch_link) + 2 else 0;
        var x: u16 = @as(u16, @intCast(cellCount(plan_title) + orch)) + 3;
        const limit: u16 = @as(u16, @intCast(draw.planHeadStart(app) -| 1));
        var n: usize = 0;
        for (0..count + 1) |i| {
            if (n == out.len) break;
            const w: u16 = @intCast(cellCount(if (i == 0) "every" else repos[i - 1]));
            if (x + w >= limit) break;
            out[n] = .{ .repo = i, .x = x, .w = w };
            n += 1;
            x += w + 3;
        }
        return .{ .n = n, .end = if (n == 0) x else x - 3 };
    }

    /// The card the keys and buttons act on: the plan's picked row's ticket.
    pub fn pickedCard(app: *const App) ?*const tickets.Card {
        const view = app.home orelse return null;
        var sheet: sheets.Sheet = undefined;
        if (!app.planSheet(&sheet)) return null;
        const row = sheet.picked(view.plan_pick) orelse return null;
        if (row.kind != .now and row.kind != .next and row.kind != .landed and row.kind != .todo and row.kind != .backlog) return null;
        return app.cardById(row.ticket orelse return null);
    }

    /// The word a card's key says: a free card's `⏎` starts it, a review card's `space` is its log.
    fn cardWord(card: *const tickets.Card, action: CardAction) []const u8 {
        return switch (action) {
            .go => if (card.proposal == null and card.holder() == null) "start" else action.label(),
            .open => if (card.status == .review) "log" else action.label(),
            else => action.label(),
        };
    }

    /// A button of an open ticket's row on the plan, where it is drawn and clicked.
    pub const PlanButton = struct { action: CardAction, key: []const u8, word: []const u8, x: u16, y: u16, w: u16 };

    /// The buttons of the `.buttons` row at `at` of `sheet`: the card's actions that are no
    /// modal's (answer and no stay there) and no list's (up and down are J and K), `open` last.
    pub fn planButtons(app: *const App, sheet: *const sheets.Sheet, at: usize, out: []PlanButton) []PlanButton {
        const row = sheet.rows[at];
        const card = app.cardById(row.ticket orelse return out[0..0]) orelse return out[0..0];
        const rect = app.planRect(row.win);
        const body = rect.h -| sheets.window_chrome;
        const top = app.planWindowTop(sheet, row.win, body);
        const line = at - sheet.span(row.win).start;
        const pin = planPinned(row.win);
        if (line < top or line >= top + body -| pin) return out[0..0];
        const y = rect.y + 1 + @as(u16, @intCast(pin + line - top));
        var have: [12]CardAction = undefined;
        const actions = cardActions(card, &have);
        const order = [_]CardAction{ .go, .open, .give, .handoff, .edit, .priority, .close, .reopen, .to_todo, .to_next };
        var x = rect.x + 2;
        const right = rect.x + rect.w -| 2;
        var n: usize = 0;
        for (order) |action| {
            if (action != .open and std.mem.indexOfScalar(CardAction, actions, action) == null) continue;
            const key = action.key();
            const word = cardWord(card, action);
            const w: u16 = @intCast(cellCount(key) + cellCount(word) + 3);
            if (x + w > right or n == out.len) break;
            out[n] = .{ .action = action, .key = key, .word = word, .x = x, .y = y, .w = w };
            n += 1;
            x += w + 1;
        }
        return out[0..n];
    }

    /// Ticket row `row` opened, or closed when it is the open one of its window; opening one
    /// closes the last.
    fn togglePlanOpen(app: *App, row: *const sheets.Row) !void {
        const id = row.ticket orelse return;
        app.plan_open.set(row.win, if (app.plan_open.get(row.win) == id) 0 else id);
        app.dirty = true;
        try app.saveFolds();
    }

    /// Whether a click or space on `row` opens it in place: the rows that are one ticket.
    fn opensInPlace(row: *const sheets.Row) bool {
        return row.ticket != null and (row.kind == .need or row.kind == .now or row.kind == .next or row.kind == .todo or row.kind == .backlog);
    }

    /// The plan's windows are laid out on this: the cells under the head's rule to the last row.
    fn planArea(app: *const App) sheets.Rect {
        return .{ .x = 1, .y = 2, .w = app.boardW() -| 2, .h = (app.view_h -| @intFromBool(app.halfHome())) -| 2 };
    }

    /// Where `win` is on the screen: its title bar, body and shadow.
    pub fn planSlot(app: *const App, win: sheets.Window) sheets.Rect {
        const area = app.planArea();
        const at = sheets.slot(win, area.w, area.h, app.halfHome());
        return .{ .x = area.x + at.x, .y = area.y + at.y, .w = at.w, .h = at.h };
    }

    /// The window shown whole, over the plan: inset from its area.
    pub fn planWhole(app: *const App) sheets.Rect {
        const area = app.planArea();
        return .{ .x = area.x + 2, .y = area.y + 1, .w = area.w -| 4, .h = area.h -| 2 };
    }

    /// The rect `win` is drawn in: its slot, or the modal when it is shown whole.
    pub fn planRect(app: *const App, win: sheets.Window) sheets.Rect {
        const view = app.home orelse return app.planSlot(win);
        return if (view.whole == win) app.planWhole() else app.planSlot(win);
    }

    /// Where the `+ new` button is on not planned's title bar, none where the window is too
    /// narrow to hold it beside its title.
    pub fn newHead(app: *const App) ?struct { x: u16, y: u16, w: u16 } {
        const rect = app.planSlot(.unplanned);
        if (rect.w < 36) return null;
        return .{ .x = rect.x + rect.w -| 13, .y = rect.y, .w = 7 };
    }

    /// Where the `+ goal` button is on the goals window's title bar.
    pub fn goalHead(app: *const App) struct { x: u16, y: u16, w: u16 } {
        const rect = app.planSlot(.goals);
        return .{ .x = rect.x + rect.w -| 13, .y = rect.y, .w = 8 };
    }

    /// The first row of `win` drawn in a body of `body` rows: the picked row kept in view when
    /// it is the window's, else the window's first.
    pub fn planWindowTop(app: *const App, sheet: *const sheets.Sheet, win: sheets.Window, body: usize) usize {
        const pin = planPinned(win);
        const view = app.home orelse return pin;
        const at = sheet.rowOf(view.plan_pick) orelse return pin;
        if (sheet.rows[at].win != win) return pin;
        const span = sheet.span(win);
        if (at - span.start < pin) return pin;
        var below = at + 1;
        while (below < sheet.n and sheet.rows[below].kind == .need_card) below += 1;
        const card = below - at - 1;
        const room = body -| pin;
        const place = at - span.start - pin;
        // a card longer than the body shows its foot, the buttons, over its head
        if (card > 2 and card + 1 > room) return pin + sheets.windowTop(place + card, span.len -| pin, room, 0);
        return pin + sheets.windowTop(place, span.len -| pin, room, @max(2, card));
    }

    /// The rows a window keeps on its first lines whatever it scrolls to: not planned's chips.
    pub fn planPinned(win: sheets.Window) usize {
        return if (win == .unplanned) 1 else 0;
    }

    /// The row of `win` (from 0) drawn on body line `line`.
    pub fn planRowOnLine(app: *const App, sheet: *const sheets.Sheet, win: sheets.Window, body: usize, line: usize) usize {
        const pin = planPinned(win);
        return if (line < pin) line else app.planWindowTop(sheet, win, body) + line - pin;
    }

    pub const PlanHit = struct { win: sheets.Window, row: ?usize = null, title: bool = false };

    /// What is under (`x`, `y`) of the plan: a window's title bar or a row.
    pub fn planHit(app: *const App, sheet: *const sheets.Sheet, x: u16, y: u16) ?PlanHit {
        const view = app.home orelse return null;
        if (view.whole) |win| return app.hitIn(sheet, win, app.planWhole(), x, y);
        for (std.enums.values(sheets.Window)) |win| if (app.hitIn(sheet, win, app.planSlot(win), x, y)) |hit| return hit;
        return null;
    }

    fn hitIn(app: *const App, sheet: *const sheets.Sheet, win: sheets.Window, rect: sheets.Rect, x: u16, y: u16) ?PlanHit {
        if (rect.h <= sheets.window_chrome or x < rect.x or x + 1 >= rect.x + rect.w or y < rect.y or y + 1 >= rect.y + rect.h) return null;
        if (y == rect.y) return .{ .win = win, .title = true };
        const body = rect.h - sheets.window_chrome;
        const span = sheet.span(win);
        const line = app.planRowOnLine(sheet, win, body, y - rect.y - 1);
        return .{ .win = win, .row = if (line < span.len) span.start + line else null };
    }

    /// The sheet's row under (`x`, `y`).
    fn planRowAt(app: *const App, sheet: *const sheets.Sheet, x: u16, y: u16) ?usize {
        if (!app.workbench()) {
            const at = app.planTop(sheet) + (y -| 2);
            return if (at < sheet.n) at else null;
        }
        const hit = app.planHit(sheet, x, y) orelse return null;
        return hit.row;
    }

    /// The pick as its window and its place among that window's picks.
    fn planPlace(app: *App) ?struct { win: sheets.Window, at: usize } {
        var sheet: sheets.Sheet = undefined;
        if (!app.planSheet(&sheet)) return null;
        const row = sheet.picked(app.home.?.plan_pick) orelse return null;
        return .{ .win = row.win, .at = app.home.?.plan_pick - sheet.pickRange(row.win).?.first };
    }

    /// The pick put back in the place it had in its window, now that a fold has renumbered the picks.
    fn planRestore(app: *App, place: anytype) void {
        var sheet: sheets.Sheet = undefined;
        if (!app.planSheet(&sheet)) return;
        const range = sheet.pickRange(place.win) orelse return;
        app.home.?.plan_pick = range.first + @min(place.at, range.n - 1);
    }

    /// `win` folded to its summary, or opened again; the pick stays where it was.
    pub fn togglePlanFold(app: *App, win: sheets.Window) !void {
        const place = app.planPlace();
        app.plan_shut.toggle(win);
        app.dirty = true;
        try app.saveFolds();
        if (place) |p| app.planRestore(p);
    }

    /// Every window but `keep` folded; with those folded already, all opened.
    fn foldPlanAll(app: *App, keep: sheets.Window) !void {
        const place = app.planPlace();
        var others = sheets.Shut.full;
        others.remove(keep);
        app.plan_shut = if (app.plan_shut.eql(others)) .empty else others;
        app.dirty = true;
        try app.saveFolds();
        if (place) |p| app.planRestore(p);
    }

    fn openWhole(app: *App, win: sheets.Window) void {
        const view = &app.home.?;
        view.whole = win;
        app.dirty = true;
        var sheet: sheets.Sheet = undefined;
        if (!app.planSheet(&sheet)) return;
        const range = sheet.pickRange(win) orelse return;
        view.plan_pick = std.math.clamp(view.plan_pick, range.first, range.first + range.n - 1);
    }

    fn closeWhole(app: *App) void {
        const view = &app.home.?;
        const win = view.whole orelse return;
        view.whole = null;
        app.dirty = true;
        if (!app.plan_shut.contains(win)) return;
        var sheet: sheets.Sheet = undefined;
        if (!app.planSheet(&sheet)) return;
        if (sheet.pickRange(win)) |range| view.plan_pick = range.first;
    }

    /// The first of the plan's rows that is drawn: the row picked kept in view, two rows more
    /// below it.
    pub fn planTop(app: *const App, sheet: *const sheets.Sheet) usize {
        const view = app.home orelse return 0;
        const at = sheet.rowOf(view.plan_pick) orelse return 0;
        return (at + 3) -| (app.view_h -| 2 -| @intFromBool(app.halfHome()));
    }

    pub const plan_title = " ◆ plan";
    pub const orch_link = "o orchestrator";

    /// Where the head's `o orchestrator` is drawn and clicked, at half a screen.
    pub fn orchLink(_: *const App) struct { x: u16, w: u16 } {
        return .{ .x = @as(u16, @intCast(cellCount(plan_title))) + 2, .w = @intCast(cellCount(orch_link)) };
    }

    /// A key on the plan, while it has the keys: `j` `k` pick through every row; Enter goes, and
    /// space or `t` opens the ticket; `B` is the board. What the board's keys do to a card is not
    /// the plan's, the card under them being out of sight.
    fn planKey(app: *App, key: []const u8) !void {
        const view = &app.home.?;
        const is = anyKey;
        var sheet: sheets.Sheet = undefined;
        if (!app.planSheet(&sheet)) return;
        // shown whole, the pick stays among its window's rows
        const range = if (view.whole) |win| sheet.pickRange(win) else null;
        const first = if (range) |r| r.first else 0;
        const last = if (range) |r| r.first + r.n - 1 else sheet.picks -| 1;
        view.plan_pick = std.math.clamp(view.plan_pick, first, last);
        if (is(key, &.{ "j", "\x1b[B", "\x1bOB" })) view.plan_pick = @min(view.plan_pick + 1, last);
        if (is(key, &.{ "k", "\x1b[A", "\x1bOA" })) view.plan_pick = @max(view.plan_pick -| 1, first);
        if (is(key, &.{"?"})) view.help = true;
        if (view.whole != null and is(key, &.{ "\x1b", "q" })) return app.closeWhole();
        if (view.whole != null and !is(key, &.{ "J", "K", "x", "e", "\r", " ", "t", "o", "p", ">", "<", "G", "w", "W", "H" })) return;
        if (app.workbench()) if (sheet.picked(view.plan_pick)) |row| {
            if (row.kind == .need and !is(key, &.{ "j", "k", "h", "l", "z", "Z", "f", "/", "r", "?", "q", "\x1b", "`", "g", "A", "]", "[", " ", "o", "O", "\x1b[A", "\x1b[B", "\x1b[C", "\x1b[D" }) and try win_move.answer(app, row, key)) return;
            if (row.kind == .chips and try app.chipKey(key)) return;
            if (is(key, &.{"z"})) return app.togglePlanFold(row.win);
            if (is(key, &.{"Z"})) return app.foldPlanAll(row.win);
            if (is(key, &.{"f"})) return app.openWhole(row.win);
        };
        if (is(key, &.{"+"})) {
            const in_unplanned = if (sheet.picked(view.plan_pick)) |row| row.win == .unplanned else false;
            return if (in_unplanned and app.workbench()) app.newTicket() else app.openGoal();
        }
        if (app.workbench() and view.whole == null) {
            if (is(key, &.{"/"})) return app.openFind();
            if (is(key, &.{"\x1b"}) and app.find_len > 0) return app.clearFind();
            if (is(key, &.{"r"})) return app.cyclePlanRepo();
            if (is(key, &.{ "l", "\x1b[C", "\x1bOC" })) if (app.planBeside(&sheet, true)) |to| {
                view.plan_pick = to;
                return;
            };
            if (is(key, &.{ "h", "\x1b[D", "\x1bOD" })) {
                if (app.planBeside(&sheet, false)) |to| view.plan_pick = to;
                return;
            }
        }
        if (is(key, &.{"d"})) if (sheet.picked(view.plan_pick)) |row| {
            if (row.kind == .goal or row.kind == .focal) return win_driving.drive(app, row.ticket.?);
        };
        if (key.len == 1 and key[0] >= '1' and key[0] <= '9') return win_driving.answer(app, key[0] - '1');

        if (is(key, &.{ "J", "K", "x", "e" })) {
            const row = sheet.picked(view.plan_pick) orelse return;
            if (row.kind == .idea) return app.ideaKey(row, key);
            if (row.kind == .todo and is(key, &.{ "J", "K" })) return win_unplanned.moveTodo(app, &sheet, row, is(key, &.{"J"}));
            if (row.kind == .backlog and is(key, &.{"x"})) return win_unplanned.openClose(app, row.ticket orelse return);
            if (row.kind != .next) {
                if (is(key, &.{"e"})) try app.act(.edit);
                return;
            }
            const b = &app.board.?;
            for (b.next(), 0..) |item, at| {
                if (item.ticket != row.ticket.?) continue;
                if (is(key, &.{"e"})) _ = app.openWhy(item.ticket, item.why) else _ = try app.nextKey(at, &view.plan_pick, key);
                break;
            }
            return;
        }
        if (is(key, &.{"W"})) if (app.pickedCard()) |card| {
            if (card.status == .todo) return app.toNext(card.id, true);
        };
        const keyed = [_]struct { []const u8, CardAction }{
            .{ "p", .priority }, .{ ">", .close },   .{ "<", .reopen },  .{ "t", .to_todo },
            .{ "G", .give },     .{ "w", .to_next }, .{ "H", .handoff },
        };
        for (keyed) |pair| if (std.mem.eql(u8, key, pair[0])) return app.act(pair[1]);
        if (is(key, &.{ "\r", " " })) {
            const row = sheet.picked(view.plan_pick) orelse return;
            if (is(key, &.{" "}) and opensInPlace(row)) {
                const open = app.plan_open.get(row.win) == row.ticket;
                try app.togglePlanOpen(row);
                if (!open) return;
            }
            return app.planAct(row, key);
        }
        if (is(key, &.{ "\x1b", "q" })) return app.closeBoard();
        if (is(key, &.{"`"})) return app.foldSide();
        if (is(key, &.{"g"})) return app.gateModal();
        if (is(key, &.{"o"})) return app.openDrawer();
        if (is(key, &.{"O"})) return app.openOverview();
        if (is(key, &.{"A"})) return app.openAuto();
        if (is(key, &.{ "]", "[" })) return app.toFeed(key, null);
        if (is(key, &.{ "l", "\x1b[C", "\x1bOC" }) and app.sided()) {
            view.focus = .orchestrator;
            if (app.sideDue()) app.normal = true;
        }
    }

    /// The chip row's own keys: `h` `l` from chip to chip, `Z` opening only the chip's repo. False
    /// for the rest, and past the first or last chip, for the window beside to take.
    fn chipKey(app: *App, key: []const u8) !bool {
        const view = &app.home.?;
        var chips: [sheets.max_chips]sheets.Chip = undefined;
        const all = app.chipsOf(&chips);
        if (all.len == 0) return false;
        view.plan_chip = @min(view.plan_chip, all.len - 1);
        if (anyKey(key, &.{ "l", "\x1b[C", "\x1bOC" })) {
            if (view.plan_chip + 1 == all.len) return false;
            view.plan_chip += 1;
            app.dirty = true;
            return true;
        }
        if (anyKey(key, &.{ "h", "\x1b[D", "\x1bOD" })) {
            if (view.plan_chip == 0) return false;
            view.plan_chip -= 1;
            app.dirty = true;
            return true;
        }
        if (!anyKey(key, &.{"Z"})) return false;
        if (all[view.plan_chip].repo) |repo| try app.focusFold(repo) else try app.toggleChip(view.plan_chip);
        return true;
    }

    /// Chip `at` of not planned's row folded or opened: a repo's through #849's fold, the backlog's
    /// its cards in the rows' place.
    pub fn toggleChip(app: *App, at: usize) !void {
        const view = &app.home.?;
        var chips: [sheets.max_chips]sheets.Chip = undefined;
        const all = app.chipsOf(&chips);
        if (at >= all.len) return;
        view.plan_chip = at;
        if (all[at].repo) |repo| return app.toggleRepoFold(repo);
        view.plan_backlog = !view.plan_backlog;
        app.dirty = true;
    }

    /// `r` on the plan: every window narrowed to the next repo, and after the last to every one.
    fn cyclePlanRepo(app: *App) void {
        const view = &app.home.?;
        var repos: [max_repos][]const u8 = undefined;
        const n = if (app.board) |*b| b.repos(&repos) else 0;
        view.plan_repo = if (view.plan_repo >= n) 0 else view.plan_repo + 1;
        view.plan_pick = 0;
        app.dirty = true;
    }

    /// The first pick of the window beside the picked row's, to the right or the left, in the
    /// other column at the same height; null where there is none or it holds nothing to pick.
    fn planBeside(app: *const App, sheet: *const sheets.Sheet, right: bool) ?usize {
        const view = app.home.?;
        const here = (sheet.picked(view.plan_pick) orelse return null).win;
        const left_col = here == .now or here == .next;
        if (here == .driving or left_col != right) return null;
        const at = app.planSlot(here).y;
        const side: []const sheets.Window = if (right) &.{ .goals, .unplanned, .landed } else &.{ .now, .next };
        for (side) |win| {
            const rect = app.planSlot(win);
            if (at >= rect.y and at < rect.y + rect.h) return (sheet.pickRange(win) orelse return null).first;
        }
        return null;
    }

    /// `e` and `x` on an idea row: a kept idea's text edited in $EDITOR as a card's is, or the idea
    /// withdrawn. One with a Claude on it or a draft is left to its own keys.
    fn ideaKey(app: *App, row: *const sheets.Row, key: []const u8) !void {
        const idea = app.board.?.plan().?.ideas[row.item];
        if (sheets.Sheet.ideaState(idea) != .idea) return;
        if (anyKey(key, &.{"e"})) return app.ticketWindow("babylon edit {d}", .{idea.epic});
        if (anyKey(key, &.{"x"})) try app.send(.ignore, captured("babylon withdraw {d}"), .{idea.epic});
    }

    /// What a key does on a row of the plan. Space and `t` open its ticket's whole detail. Enter
    /// goes: to the Claude building it, or with none and nothing moving it, starts one; to the
    /// gate for a ticket in the pipeline; unfolds a folded row; starts a ticket of next now;
    /// and from a goal, landed or not planned, to the board on it.
    fn planAct(app: *App, row: *const sheets.Row, key: []const u8) !void {
        const view = &app.home.?;
        const given = app.board.?.plan().?;
        app.dirty = true;
        if (row.kind == .other) {
            const a = app.otherAt(row.item) orelse return;
            try app.closeBoard();
            if (std.mem.eql(u8, key, "\r")) return app.goAgent(a);
            app.normal = true;
            return app.openPopup(a.win.id);
        }
        if (row.kind == .idea and sheets.Sheet.ideaState(given.ideas[row.item]) == .draft) return app.openDraft(given.ideas[row.item].epic);
        if (!std.mem.eql(u8, key, "\r")) {
            if (row.ticket) |id| _ = try app.openDetail(id);
            return;
        }
        switch (row.kind) {
            .summary => try app.togglePlanFold(row.win),
            .ideas_more => if (row.fold) |bit| {
                view.unfolded ^= @as(u8, 1) << bit;
            },
            .idea, .goal, .focal => try win_goals.act(app, row),
            .now => try win_now.act(app, row),
            .next => try win_next.act(app, row),
            .chips, .todo, .unplanned => try win_unplanned.act(app, row),
            .goals_more => app.openWhole(.goals),
            .landed => try win_landed.act(app, row),
            .need => try win_move.act(app, row),
            else => {},
        }
    }

    /// A left click on the plan: on a row its pick, and on the row picked already what Enter does.
    fn planClick(app: *App, m: keys.Mouse) !void {
        const view = &app.home.?;
        if (m.y == 0) {
            if (draw.planAutoSwitch(app)) |at| if (m.x >= at.x and m.x < at.x + at.w) return app.planAutoClick();
            var tabs: [33]RepoTab = undefined;
            const found = app.planRepoTabs(&tabs);
            if (app.workbench()) for (tabs[0..found.n]) |tab| if (m.x >= tab.x and m.x < tab.x + tab.w) {
                view.plan_repo = tab.repo;
                view.plan_pick = 0;
                app.dirty = true;
                return;
            };
            const orch = app.orchLink();
            if (app.halfHome() and m.x >= orch.x and m.x < orch.x + orch.w) return app.openDrawer();
            if (draw.planHeadHit(app, m.x)) |hit| switch (hit) {
                .orch => try app.openDrawer(),
                .menu => app.openMenu(&menu.main),
            };
            return;
        }
        var sheet: sheets.Sheet = undefined;
        if (m.y < 2 or !app.planSheet(&sheet)) return;
        if (app.workbench()) {
            const hit = app.planHit(&sheet, m.x, m.y) orelse return app.closeWhole();
            if (hit.title) {
                if (view.whole != null) return;
                const pressed = switch (hit.win) {
                    .driving => try win_driving.titleClick(app),
                    .goals => try win_goals.titleClick(app, m.x),
                    .unplanned => try win_unplanned.titleClick(app, m.x),
                    else => false,
                };
                if (pressed) return;
                return app.togglePlanFold(hit.win);
            }
        }
        const at = app.planRowAt(&sheet, m.x, m.y) orelse return;
        const row = sheet.rows[at];
        if (row.kind == .drove and row.part == 3) return win_driving.click(app, m);
        if (row.kind == .need_card) return win_move.click(app, &sheet, at, m);
        if (row.kind == .buttons) return app.planButtonClick(&sheet, at, m);
        if (row.kind == .held) {
            const pane = app.board.?.plan().?.now[row.item].holder() orelse return;
            return app.showPane(pane);
        }
        const pick = row.pick orelse return;
        const picked = view.plan_pick == pick;
        view.plan_pick = pick;
        if (row.kind == .chips) {
            var chips: [sheets.max_chips]sheets.Chip = undefined;
            for (app.chipsOf(&chips), 0..) |c, i| if (m.x >= c.x and m.x < c.x + c.w) return app.toggleChip(i);
            return;
        }
        if (row.kind == .todo) {
            app.drag = .{ .todo_row = .{ .id = row.ticket orelse return } };
        } else if (row.kind == .next) {
            app.drag = .{ .next_row = .{ .from = nextPlace(&sheet, at), .opens = true } };
        } else if (opensInPlace(&row)) {
            try app.togglePlanOpen(&row);
        } else if (picked) try app.planAct(&row, "\r");
    }

    /// A click on Plan's auto switch: off turns it on; on asks to turn it off, and a second click
    /// within a few seconds does.
    fn planAutoClick(app: *App) !void {
        if (app.auto() != null and app.now >= app.auto_armed_until) {
            app.auto_armed_until = app.now + auto_confirm_ms;
            app.dirty = true;
            return;
        }
        app.auto_armed_until = 0;
        try app.toggleAuto();
    }

    /// A click on the buttons row at `at`: the button under it pressed on its ticket, which the
    /// pick moves to first, the keys acting on the pick.
    fn planButtonClick(app: *App, sheet: *const sheets.Sheet, at: usize, m: keys.Mouse) !void {
        var buttons: [12]PlanButton = undefined;
        for (app.planButtons(sheet, at, &buttons)) |button| {
            if (m.y != button.y or m.x < button.x or m.x >= button.x + button.w) continue;
            const owner = sheet.rows[at - 1 - @as(usize, @intFromBool(sheet.rows[at - 1].kind == .why or sheet.rows[at - 1].kind == .held))];
            app.home.?.plan_pick = owner.pick orelse return;
            return app.act(button.action);
        }
    }

    /// The place (from 0) in next of the next row at `at` of the sheet.
    fn nextPlace(sheet: *const sheets.Sheet, at: usize) usize {
        var place: usize = 0;
        for (sheet.rows[0..at]) |row| place += @intFromBool(row.kind == .next);
        return place;
    }

    /// The held todo row moved to `m`, or let go: over next it joins next at the place it is let
    /// go on, `babylon next N --at K`, or at the bottom over the window's empty rows; let go where
    /// it was pressed it opens in place, as a click does.
    fn dragTodoRow(app: *App, m: keys.Mouse) !void {
        const held = &app.drag.todo_row;
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
        const hit = app.planHit(&sheet, m.x, m.y) orelse return;
        if (hit.win == .unplanned) {
            if (row.moved) return;
            const at = hit.row orelse return;
            if (sheet.rows[at].ticket == row.id) try app.togglePlanOpen(&sheet.rows[at]);
            return;
        }
        if (hit.win != .next or hit.title) return;
        const place = if (hit.row) |at| nextPlace(&sheet, at) + 1 else app.board.?.next().len + 1;
        var id: [12]u8 = undefined;
        var here: [12]u8 = undefined;
        var said: [24]u8 = undefined;
        const number = std.fmt.bufPrint(&id, "{d}", .{row.id}) catch return;
        const at_place = std.fmt.bufPrint(&here, "{d}", .{place}) catch return;
        const refusal = std.fmt.bufPrint(&said, "next:{d}", .{row.id}) catch return;
        _ = try app.runNeed(refusal, &.{ "babylon", "next", number, "--at", at_place });
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
        const at = app.planRowAt(&sheet, m.x, m.y) orelse return;
        if (sheet.rows[at].kind != .next) return;
        const to = nextPlace(&sheet, at);
        if (to == row.from) {
            if (row.opens and !row.moved) try app.togglePlanOpen(&sheet.rows[at]);
            return;
        }
        if (row.from >= app.board.?.next().len) return;
        const view = &app.home.?;
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
    pub const Kept = struct { view: HomeView, folded: bool };

    pub fn kept(app: *const App) ?Kept {
        var view = app.home orelse return null;
        view.help = false;
        view.whole = null;
        view.detail = null;
        view.giving = null;
        return .{ .view = view, .folded = app.side_folded };
    }

    /// Home as it was kept, in the new client's sessions.
    pub fn restore(app: *App, was: Kept) !void {
        if (app.board == null) return;
        app.home = was.view;
        app.side_folded = was.folded;
        app.dirty = true;
        try app.toSide();
    }

    /// A key while the column has the keys with no window of the orchestrator's in it: Enter
    /// starts it when it is off, h gives the board the keys, and Escape and q close the board.
    fn columnKey(app: *App, key: []const u8) !void {
        const view = &app.home.?;
        if (anyKey(key, &.{ "h", "\x1b[D", "\x1bOD" })) view.focus = .plan;
        if (anyKey(key, &.{"q"})) return app.closeBoard();
        if (anyKey(key, &.{"A"})) return app.openAuto();
        if (anyKey(key, &.{"\r"}) and app.orchestratorState() == .off) {
            return app.send(.ignore, captured("babylon orchestrator"), .{});
        }
        if (anyKey(key, &.{"\x1b"})) return if (app.drawerOpen()) app.closeDrawer() else app.closeBoard();
        if (try win_feed.press(app, key)) return;
        if (anyKey(key, &.{"o"}) and app.drawerOpen()) return app.closeDrawer();
    }

    /// `]` or `[` from the board: the column's feed takes the keys, in normal mode, with the pick
    /// on Your move's first item or its last, or on the one of `ticket` when it has one.
    fn toFeed(app: *App, key: []const u8, ticket: ?u32) !void {
        const view = &app.home.?;
        if (app.planShown() and app.workbench()) return app.toMove(key, ticket);
        if (ticket == null and !app.sided()) try app.openDrawer();
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
            app.pickPlan(id);
        }
    }

    /// `]` or `[` on the plan: the pick on Your move's first item or its last, or on the one of
    /// `ticket` when it has one; the plan has the keys.
    fn toMove(app: *App, key: []const u8, ticket: ?u32) !void {
        const view = &app.home.?;
        view.focus = .plan;
        view.whole = null;
        app.dirty = true;
        var sheet: sheets.Sheet = undefined;
        if (!app.planSheet(&sheet)) return;
        const range = sheet.pickRange(.move) orelse return;
        view.plan_pick = if (anyKey(key, &.{"["})) range.first + range.n - 1 else range.first;
        if (ticket) |id| for (sheet.rows[0..sheet.n]) |row| {
            if (row.win == .move and row.kind == .need and row.ticket == id) view.plan_pick = row.pick orelse continue;
        };
    }

    /// A key at home: a box over the plan takes it, else the drawer's, else the plan's.
    fn homeKey(app: *App, key: []const u8) !void {
        app.clearStartRefusal();
        app.dirty = true;
        const view = &app.home.?;
        if (view.goal_open) return app.goalKey(key);
        if (view.draft != null) return app.draftKey(key);
        if (view.auto_pick != null) return app.autoKey(key);
        if (view.giving != null) return app.giveKey(key);
        if (view.help) {
            view.help = false;
            return;
        }
        if (view.detail != null) return app.modalKey(key);
        if (anyKey(key, &.{"s"})) return app.openSwitcher();
        if (app.columnFocused()) return app.columnKey(key);
        return app.planKey(key);
    }

    /// The side folded away, or back beside the board; the board opens so from then on.
    fn foldSide(app: *App) !void {
        const view = &app.home.?;
        app.dirty = true;
        if (!app.sided()) {
            app.side_folded = false;
            return app.toSide();
        }
        app.side_folded = true;
        view.focus = .plan;
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
            app.home = null;
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
        const view = app.home orelse return null;
        if (view.auto_pick == null) return null;
        const width: u16 = @min(app.boardW() -| 4, 48);
        const bottom = app.view_h -| 2;
        if (width < 30 or bottom < first_line + 7) return null;
        const h: u16 = @intCast(@min(7 + app.autoRepos(), bottom - first_line + 1));
        return .{ .x = (app.boardW() -| width) / 2, .y = first_line, .w = width, .h = h };
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

    /// The most steps a draft's modal lists.
    pub const draft_max = 24;

    /// The backlog tickets filed under epic `epic`: a draft's steps, in the order babylon gives them.
    pub fn draftSteps(app: *const App, epic: u32, out: *[draft_max]*const tickets.Card) []*const tickets.Card {
        const b = if (app.board) |*b| b else return out[0..0];
        var n: usize = 0;
        for (b.backlog()) |*card| {
            if (card.epic_id != epic or n == out.len) continue;
            out[n] = card;
            n += 1;
        }
        return out[0..n];
    }

    /// The epic's title: the outcome the draft promises.
    pub fn draftTitle(app: *const App, epic: u32) []const u8 {
        const b = if (app.board) |*b| b else return "";
        for ([_][]const tickets.Card{ b.cards(), b.backlog() }) |list| for (list) |card| {
            if (card.id == epic) return card.title;
        };
        return "";
    }

    /// The idea behind epic `epic`'s draft, when babylon lists it.
    pub fn draftIdea(app: *const App, epic: u32) ?tickets.Idea {
        const plan = if (app.board) |*b| b.plan() orelse return null else return null;
        for (plan.ideas) |idea| if (idea.epic == epic) return idea;
        return null;
    }

    /// The most asks a draft's modal lists.
    pub const draft_asks_max = 3;

    /// The asks the planning Claude made, the first few, for the modal's foot.
    pub fn draftAsks(app: *const App, epic: u32) []const tickets.IdeaAsk {
        const idea = app.draftIdea(epic) orelse return &.{};
        return idea.ask_list[0..@min(idea.ask_list.len, draft_asks_max)];
    }

    /// The Your move item of epic `epic`'s look, when babylon gives one.
    fn draftNeed(app: *const App, epic: u32) ?*const tickets.Need {
        const b = if (app.board) |*b| b else return null;
        for (b.needsYou()) |*need| {
            if (std.mem.eql(u8, need.kind, "draft") and need.ticket == epic) return need;
        }
        return null;
    }

    /// A draft's modal over the board: a title bar, the outcome, a line of its count, a row for
    /// each step, a blank one and the foot.
    pub fn draftRect(app: *const App) ?ModalRect {
        const view = app.home orelse return null;
        const epic = view.draft orelse return null;
        var steps: [draft_max]*const tickets.Card = undefined;
        const n = app.draftSteps(epic, &steps).len;
        const width: u16 = @min(app.boardW() -| 4, 84);
        const bottom = app.view_h -| 2;
        if (width < 40 or bottom < first_line + 7) return null;
        const h: u16 = @intCast(@min(6 + n + app.draftAsks(epic).len, bottom - first_line + 1));
        return .{ .x = (app.boardW() -| width) / 2, .y = first_line, .w = width, .h = h };
    }

    pub fn openDraft(app: *App, epic: u32) void {
        const view = &app.home.?;
        view.draft = epic;
        view.draft_pick = 0;
        if (app.draftRect() == null) {
            view.draft = null;
            return;
        }
        view.draft_from_column = view.focus == .orchestrator;
        view.focus = .plan;
        app.dirty = true;
    }

    fn closeDraft(app: *App) void {
        const view = &app.home.?;
        view.draft = null;
        if (view.draft_from_column) view.focus = .orchestrator;
        app.dirty = true;
    }

    /// A key in a draft's modal: `j` `k` pick a step, space opens its ticket, `e` edits it, `y`
    /// goes (`babylon adopt`), `r` replies with changes on the line at the foot, `q` closes.
    fn draftKey(app: *App, key: []const u8) !void {
        const view = &app.home.?;
        const is = anyKey;
        const epic = view.draft.?;
        app.dirty = true;
        var steps: [draft_max]*const tickets.Card = undefined;
        const list = app.draftSteps(epic, &steps);
        if (is(key, &.{ "\x1b", "q" })) return app.closeDraft();
        if (is(key, &.{ "j", "\x1b[B", "\x1bOB" })) view.draft_pick = @min(view.draft_pick + 1, list.len -| 1);
        if (is(key, &.{ "k", "\x1b[A", "\x1bOA" })) view.draft_pick -|= 1;
        if (is(key, &.{"y"})) {
            var number: [12]u8 = undefined;
            var named: [16]u8 = undefined;
            const id = std.fmt.bufPrint(&number, "{d}", .{epic}) catch return;
            const refusal = if (app.draftNeed(epic)) |need| need.id else std.fmt.bufPrint(&named, "draft:{d}", .{epic}) catch return;
            app.closeDraft();
            _ = try app.runNeed(refusal, &.{ "babylon", "adopt", id });
            return;
        }
        if (is(key, &.{"r"})) {
            const need = app.draftNeed(epic) orelse return;
            app.closeDraft();
            _ = app.openWords(need.id);
            return;
        }
        if (list.len == 0) return;
        const step = list[@min(view.draft_pick, list.len - 1)];
        if (is(key, &.{" "})) {
            app.closeDraft();
            _ = try app.openDetail(step.id);
        } else if (is(key, &.{"e"})) {
            app.closeDraft();
            try app.ticketWindow("babylon edit {d}", .{step.id});
        }
    }

    /// Opens auto's modal, with the keys on the board.
    fn openAuto(app: *App) !void {
        const view = &app.home.?;
        view.auto_pick = 0;
        // too small a screen for the window: no box that takes the keys unseen
        if (app.autoRect() == null) {
            view.auto_pick = null;
            return;
        }
        view.auto_from_column = view.focus == .orchestrator;
        view.auto_normal = app.normal;
        view.focus = .plan;
        app.dirty = true;
    }

    fn closeAuto(app: *App) void {
        const view = &app.home.?;
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
        const view = &app.home.?;
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
        return .{ .x = (app.boardW() -| width) / 2, .y = first_line + (app.view_h - first_line - h) / 2, .w = width, .h = h };
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

    pub fn openGoal(app: *App) !void {
        const view = &app.home.?;
        if (app.goalRect() == null) return;
        app.goal = .{};
        view.goal_open = true;
        app.dirty = true;
    }

    /// A key in the `+ goal` modal; `⏎` and `k` send what is typed to babylon, and the modal waits
    /// for its answer.
    fn goalKey(app: *App, key: []const u8) !void {
        const view = &app.home.?;
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
        const view = if (app.home) |*open| open else return;
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
        const view = &app.home.?;
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
        const view = &app.home.?;
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

    pub fn newTicket(app: *App) !void {
        var buf: [80]u8 = undefined;
        const narrowed = if (app.planRepo()) |r| (if (plainName(r)) std.fmt.bufPrint(&buf, " --repo {s}", .{r}) catch "" else "") else "";
        try app.ticketWindow("babylon new{s}", .{narrowed});
    }

    /// What can be done to a card from the board, by its key or its chip.
    pub const CardAction = enum {
        go,
        no,
        give,
        edit,
        priority,
        close,
        reopen,
        to_todo,
        to_next,
        handoff,
        open,

        /// The key that does it, as the box on the board writes it.
        pub fn key(action: CardAction) []const u8 {
            return switch (action) {
                .go => "⏎",
                .no => "x",
                .give => "G",
                .edit => "e",
                .priority => "p",
                .close => ">",
                .reopen => "<",
                .to_todo => "t",
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
                .give => "give",
                .edit => "edit",
                .priority => "priority",
                .close => "close",
                .reopen => "reopen",
                .to_todo => "to todo",
                .to_next => "next",
                .handoff => "hand off",
            };
        }
    };

    /// The actions `card` has: go while a proposal is open on it, a Claude holds it or it can be
    /// started, no beside a proposal, give while it is free to claim, close while still to
    /// do and reopen once done, to todo while in the backlog, and edit and priority always.
    pub fn cardActions(card: *const tickets.Card, out: *[12]CardAction) []CardAction {
        var n: usize = 0;
        const all = [_]struct { CardAction, bool }{
            .{ .go, card.proposal != null or card.holder() != null or givable(card) }, .{ .no, card.proposal != null },
            .{ .give, givable(card) },                                                 .{ .edit, true },
            .{ .priority, true },                                                      .{ .close, card.status == .todo },
            .{ .reopen, card.status == .done },                                        .{ .to_todo, card.status == .backlog },
            .{ .to_next, card.status == .todo },                                       .{ .handoff, card.status == .doing and card.holder() != null },
        };
        for (all) |pair| if (pair[1]) {
            out[n] = pair[0];
            n += 1;
        };
        return out[0..n];
    }

    /// Edit opens $EDITOR in a window of its own; priority goes from low up to high and round;
    /// close and reopen move a ticket between to do and done, the columns between being a claim's
    /// and the pipeline's. Each through babylon's command line. An action the picked card has not
    /// does nothing.
    pub fn act(app: *App, action: CardAction) !void {
        const view = if (app.home) |*open| open else return;
        const card = app.pickedCard() orelse return;
        if (action == .open) {
            _ = try app.openDetail(card.id);
            return;
        }
        var have: [12]CardAction = undefined;
        if (std.mem.indexOfScalar(CardAction, cardActions(card, &have), action) == null) return;
        switch (action) {
            .go => if (card.proposal) |proposal| try app.settleProposal("go", proposal.id) else try app.goCard(),
            .no => if (card.proposal) |proposal| try app.settleProposal("no", proposal.id),
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
        }
    }

    /// Goes to the Claude holding the card picked, closing home; with none, starts one on a free
    /// card, babylon refusing what it will not start and saying why.
    fn goCard(app: *App) !void {
        const card = app.pickedCard() orelse return;
        const pane = card.holder() orelse {
            if (!givable(card)) return;
            var id_buf: [12]u8 = undefined;
            _ = try app.runWith("start", &.{ "babylon", "start", std.fmt.bufPrint(&id_buf, "{d}", .{card.id}) catch return }, true);
            return;
        };
        try app.showPane(pane);
    }

    /// The session holding `card` asked to hand it off, in the words babylon's own handoff
    /// proposal types: it commits what is uncommitted, then calls handoff.
    fn askHandoff(app: *App, card: *const tickets.Card) !void {
        const pane = card.holder() orelse return;
        try app.send(.ignore, "send-keys -t %{d} -l 'Your human asks you to hand #{d} off: commit what is uncommitted as a WIP commit, then call handoff.'", .{ pane, card.id });
        try app.send(.ignore, "send-keys -t %{d} Enter", .{pane});
    }

    /// What a modal button does when pressed.
    pub const ModalAction = union(enum) { close, card: CardAction, option: u8, sub: u8, words, claude, whole_log, ticket, bump, withdraw, tried_ok, tried_no, copy_check, run_check };

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
        const view = app.home orelse return null;
        if (view.detail == null) return null;
        const width = detailWidth(app.boardW());
        const top: u16 = first_line;
        const bottom = app.view_h -| 2;
        if (bottom < top + 3 or width.inner == 0) return null;
        return .{ .x = (app.boardW() -| width.box) / 2, .y = top, .w = width.box, .h = bottom - top + 1 };
    }

    /// What a card's modal says of it above its body, a line each.
    pub const CardHead = struct {
        pub const Kind = enum { plain, dim, warn, options, check, sub, shell };
        buf: [1024]u8 = undefined,
        used: usize = 0,
        lines: [64][]const u8 = undefined,
        kinds: [64]Kind = undefined,
        /// Of a line arena wrapped from the one before it: the spaces the wrap took out.
        joins: [64]?usize = @splat(null),
        n: usize = 0,
        /// The first of the lines of the open ask's options, a button each, and its words after.
        options: ?usize = null,
        /// The first of a to-try ticket's check lines, one each.
        checks: ?usize = null,
        /// The first of its Claude's subagent lines, one each, and how many.
        subs: ?usize = null,
        subs_n: usize = 0,

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
                head.joins[head.n] = it.dropped;
                head.n += 1;
            }
        }
    };

    /// The card the open modal shows: the one its buttons act on.
    pub fn modalCard(app: *const App) ?*const tickets.Card {
        const view = app.home orelse return null;
        return app.cardById(view.detail orelse return null);
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

    /// `cardHead` for the open modal: a to-try card's rows end with what arena says of the check
    /// it ran, or asks to run.
    pub fn modalHead(app: *const App, card: *const tickets.Card, inner: usize, words: bool, head: *CardHead) void {
        cardHead(card, inner, app.epoch, words, head);
        if (card.status != .@"try") return;
        var id: [24]u8 = undefined;
        const note = app.refusalOf(std.fmt.bufPrint(&id, "try:{d}", .{card.id}) catch return) orelse return;
        var rows = std.mem.splitScalar(u8, note, '\n');
        while (rows.next()) |row| head.add(.dim, "{s}", .{row});
    }

    /// The most subagents a Claude's rows list, in its card and its modal.
    pub const max_sub_rows = 4;

    /// Adds to `head` a line for each of `win`'s subagents, then one for its shell.
    pub fn claudeHead(win: *const Window, head: *CardHead) void {
        head.subs = head.n;
        head.subs_n = @min(win.subs(), max_sub_rows);
        for (0..head.subs_n) |i| head.add(.sub, "◔ {s}", .{win.sub(i)});
        if (win.text(.background).len > 0) head.add(.shell, "◔ {s}", .{win.text(.background)});
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
        var subs: ?struct { win: *const Window, line: usize, n: usize } = null;
        if (app.home.?.gate) {
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
            app.modalHead(card, detailWidth(app.boardW()).inner, words != null, &head);
            if (app.claudeOf(card)) |win| {
                claudeHead(win, &head);
                if (head.subs_n > 0) subs = .{ .win = win, .line = head.subs.?, .n = head.subs_n };
            }
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
                const pick = @min(@max(app.home.?.ask_pick, 1), shown);
                const button: ModalButton = .{ .action = .{ .option = pick }, .key = "⏎", .label = answers[pick - 1], .x = x, .y = foot };
                out[n] = button;
                n += 1;
                x += button.width() + 1;
            }
            if (card.status == .@"try" and card.checks.len > 0) {
                const tries = [_]ModalButton{
                    .{ .action = .tried_ok, .key = "y", .label = "✓ it works", .x = x, .y = foot },
                    .{ .action = .tried_no, .key = "n", .label = "✗ it failed", .x = x, .y = foot },
                    .{ .action = .run_check, .key = "r", .label = "run", .x = x, .y = foot },
                    .{ .action = .copy_check, .key = "Y", .label = "copy", .x = x, .y = foot },
                };
                var found: [512]u8 = undefined;
                const runs = if (pickedCheck(card, app.home.?.check_pick)) |check| runcheck.find(check.text, &found).len > 0 else false;
                for (tries) |item| {
                    if (item.action == .run_check and !runs) continue;
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
        if (subs) |s| for (0..s.n) |i| {
            const y = rect.y + 1 + @as(u16, @intCast(s.line + i));
            if (y >= foot or n == out.len) break;
            out[n] = .{ .action = .{ .sub = @intCast(i) }, .key = "◔", .label = @import("text.zig").clip(s.win.sub(i), 60), .x = rect.x + 2, .y = y };
            n += 1;
        };
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
        const view = &app.home.?;
        switch (action) {
            .close => {
                view.detail = null;
                app.checkCancel();
            },
            .run_check => {
                const card = app.modalCard() orelse return;
                const check = pickedCheck(card, view.check_pick) orelse return;
                _ = try app.checkOffer(card.id, check.n, check.text);
            },
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
            .copy_check => {
                const card = app.modalCard() orelse return;
                try app.copyText((pickedCheck(card, view.check_pick) orelse return).text);
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
            .sub => |i| {
                const win = app.claudeOf(app.modalCard() orelse return) orelse return;
                const a = app.agentById(win.id) orelse return;
                try app.closeBoard();
                try app.goSub(.{ .agent = a, .index = i });
            },
            .claude => {
                const win = app.claudeOf(app.modalCard() orelse return) orelse return;
                try app.closeBoard();
                app.normal = true;
                app.openPopup(win.id);
            },
        }
    }

    /// A key in the open modal: the keys of its buttons, `j` `k` to scroll and `q` to close.
    fn modalKey(app: *App, key: []const u8) !void {
        const view = &app.home.?;
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
            if (is(key, &.{"Y"})) return app.pressModal(.copy_check);
            if (is(key, &.{"r"})) return app.pressModal(.run_check);
            if (is(key, &.{"\r"})) if (pickedCheck(card, view.check_pick)) |check| {
                if (app.check_ask) |ask| if (ask.ticket == card.id and ask.n == check.n) return app.checkStart();
                if (app.checkRunOf(card.id, check.n)) |run| if (run.pane) |pane| return app.showPane(pane);
            };
            app.checkCancel();
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
        if (card.ask == null or card.ask.?.options.len == 0) if (app.claudeOf(card)) |win| if (win.subs() > 0) {
            const n: u8 = @intCast(@min(win.subs(), max_sub_rows));
            if (is(key, &.{"\t"})) view.sub_pick = if (view.sub_pick < n) view.sub_pick + 1 else 0;
            if (is(key, &.{"\r"}) and view.sub_pick > 0) return app.pressModal(.{ .sub = view.sub_pick - 1 });
        };
        if (card.ask) |ask| if (ask.options.len > 0) {
            if (is(key, &.{"\t"})) view.ask_pick = if (view.ask_pick < @min(ask.options.len, max_ask_options)) view.ask_pick + 1 else 1;
            if (is(key, &.{"\r"})) return app.pressModal(.{ .option = @min(view.ask_pick, @as(u8, @intCast(@min(ask.options.len, max_ask_options)))) });
        };
        if (app.askWords(card)) |w| if (is(key, &.{w.action.key})) return app.pressModal(.words);
        const claude_key = app.claudeKey(card);
        const action: ModalAction = if (is(key, &.{"\r"})) .{ .card = .go } else if (is(key, &.{"G"})) .{ .card = .give } else if (is(key, &.{"H"})) .{ .card = .handoff } else if (is(key, &.{"e"})) .{ .card = .edit } else if (is(key, &.{"p"})) .{ .card = .priority } else if (is(key, &.{">"})) .{ .card = .close } else if (is(key, &.{"<"})) .{ .card = .reopen } else if (is(key, &.{claude_key}) and app.claudeOf(card) != null) .claude else return;
        try app.pressModal(action);
    }

    /// Rows the board's head takes: its title bar, then its tabs. The columns' top edge is the next, and their lines start under it.
    pub const head_rows: u16 = 2;
    pub const first_line: u16 = head_rows + 1;

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

    /// A key while the Claudes the picked card can be given to are shown: j and k pick one, and
    /// Enter or its number gives it the card through babylon, which types the claim into its pane
    /// as its human's word; Esc puts them away.
    fn giveKey(app: *App, key: []const u8) !void {
        const view = &app.home.?;
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
        const card = app.pickedCard() orelse return;
        // babylon's refusal (that Claude is mid-turn, the card was claimed meanwhile) is said
        try app.send(.ignore, "run-shell -b \"out=\\$(babylon give {d} %{d} 2>&1) || " ++
            "{{ command -v notify-send >/dev/null && notify-send -a arena -- \\\"\\$out\\\"; }}\"", .{ card.id, found[to].win.agent_pane });
        view.giving = null;
    }

    /// The mouse at home: a box over the plan takes the click, as a key would; on the drawer a click
    /// focuses it, as one on any window out of focus, and the wheel, or anything once it is
    /// focused, is the drawer's; else it is the plan's.
    fn homeMouse(app: *App, m: keys.Mouse) !bool {
        // a drag's let go that never came: a new press ends that drag unseen
        if ((app.drag == .next_row or app.drag == .todo_row) and m.leftPress()) app.drag = .none;
        if (app.drag != .none) return false;

        const view = &app.home.?;
        if (m.x >= app.term_w - app.view_w and app.sided() and !view.boxed()) {
            if (m.y >= app.view_h) return true;
            if (m.leftPress() and try win_feed.click(app, m)) return true;

            if (app.sideShown() and (app.sideFocused() or m.wheel())) return false;
            if (m.leftPress()) {
                view.focus = .orchestrator;
                app.drag = .focus;
                app.dirty = true;
            }
            return true;
        }
        if (m.leftPress()) view.focus = .plan;
        if (m.wheel()) {
            if (app.navStep()) try app.homeKey(if (m.code & 1 == 0) "k" else "j");
            return true;
        }
        if (!m.leftPress()) return true;
        app.dirty = true;
        const open = &app.home.?;
        // a box over the plan takes the click, so nothing hidden under it is pressed
        if (open.boxed()) {
            if (open.goal_open) {
                try app.goalClick(m);
                return true;
            }
            if (open.draft != null) {
                app.closeDraft();
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
            if (open.whole != null and open.detail == null and !open.help and open.giving == null) {
                try app.planClick(m);
                return true;
            }
            open.help = false;
            open.detail = null;
            open.giving = null;
            return true;
        }
        try app.planClick(m);
        return true;
    }

    /// The card with ticket `id`, on the board or in the backlog.
    pub fn cardById(app: *const App, id: u32) ?*const tickets.Card {
        const b = if (app.board) |*b| b else return null;
        for (b.cards()) |*card| if (card.id == id) return card;
        for (b.backlog()) |*card| if (card.id == id) return card;
        return null;
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
                try app.showPlan(card.id);
                if (app.home) |view| if (view.detail == null) {
                    _ = try app.openDetail(card.id);
                };
            },
        }
    }

    /// A row of the switcher: a Claude, a session by its place in tmux's order, the row that makes
    /// a session, or what a typed query finds as the jump prompt does.
    pub const Row = union(enum) { claude: Agent, session: usize, new, hit: Hit };
    pub const max_rows = 128;

    /// The sooner a Claude wants looking at, the lower: waiting, stalled, done, working, the rest.
    fn claudeRank(win: *const Window) u8 {
        return switch (win.claude) {
            .waiting => 0,
            .stalled => 1,
            .done => 2,
            .working => 3,
            .background, .none => 4,
        };
    }

    fn claudeBefore(_: void, a: Agent, b: Agent) bool {
        const ra = claudeRank(a.win);
        const rb = claudeRank(b.win);
        return ra < rb or (ra == rb and urgency(a.win) > urgency(b.win));
    }

    /// A Claude as the switcher words it: its ticket and title, else its window and what it is doing.
    pub fn claudeLabel(app: *const App, buf: []u8, a: Agent) []const u8 {
        const win = a.win;
        const card = if (app.ticketKey(win)) |key| app.ticketCard(key.id) else null;
        return (if (card) |c|
            std.fmt.bufPrint(buf, "#{d} {s}", .{ c.id, c.title })
        else if (win.detail().len > 0)
            std.fmt.bufPrint(buf, "{s} · {s}", .{ win.name, win.detail() })
        else
            std.fmt.bufPrint(buf, "{s}", .{win.name})) catch "";
    }

    /// What the switcher is for: every Claude, urgency first, then every session in tmux's order
    /// and `+ new session`; with a query typed, the Claudes and sessions it matches and then the
    /// windows and tickets the jump prompt finds. Into `out`; how many.
    pub fn switcherRows(app: *const App, query: []const u8, out: []Row) usize {
        var found: [max_rows]Agent = undefined;
        var count: usize = 0;
        const sessions = app.listedSessions();
        for (app.sessions.items[0..sessions], 0..) |s, si| for (s.wins.items) |win| {
            if (!win.agent() or count == found.len) continue;
            found[count] = .{ .session = si, .win = win };
            count += 1;
        };
        std.sort.insertion(Agent, found[0..count], {}, claudeBefore);
        var n: usize = 0;
        for ([_]u1{ 0, 1 }) |rank| for (found[0..count]) |a| {
            if (n == out.len) return n;
            var label: [200]u8 = undefined;
            var text: [400]u8 = undefined;
            const s = app.sessions.items[a.session];
            const joined = std.fmt.bufPrint(&text, "{s} {s} {s} {s}", .{ app.claudeLabel(&label, a), s.name, a.win.name, a.win.text(.branch) }) catch continue;
            if (menu.fuzzy(query, joined) == rank) {
                out[n] = .{ .claude = a };
                n += 1;
            }
        };
        for ([_]u1{ 0, 1 }) |rank| for (app.sessions.items[0..sessions], 0..) |s, si| {
            if (n == out.len) return n;
            if (menu.fuzzy(query, s.name) == rank) {
                out[n] = .{ .session = si };
                n += 1;
            }
        };
        if (query.len == 0) {
            if (n < out.len) {
                out[n] = .new;
                n += 1;
            }
            return n;
        }
        var hits: [64]Hit = undefined;
        for (hits[0..app.jumpHits(query, &hits)]) |hit| {
            if (n == out.len) return n;
            if (hit == .window and hit.window.session.wins.items[hit.window.index].agent()) continue;
            out[n] = .{ .hit = hit };
            n += 1;
        }
        return n;
    }

    /// Opens the switcher over any view.
    fn openSwitcher(app: *App) void {
        app.menu = null;
        app.prompt = .{ .what = .jump };
        app.dirty = true;
    }

    /// Goes where a row of the switcher is.
    fn goRow(app: *App, row: Row) !void {
        if (app.home != null) try app.closeBoard();
        switch (row) {
            .claude => |a| try app.goAgent(a),
            .session => |si| try app.sessionTo(si),
            .new => try app.send(.ignore, "new-session", .{}),
            .hit => |hit| try app.jumpHit(hit),
        }
    }

    /// A key in the switcher while nothing is typed: `j` `k` move, `space` opens a Claude's card,
    /// `J` `K` move a session in tmux's order, `x` closes one after asking and `/` begins a filter.
    /// Whether the key was one of them; any other is typed.
    fn switcherKey(app: *App, prompt: *menu.Prompt, key: []const u8) !bool {
        if (prompt.what != .jump or prompt.len > 0 or prompt.filtering or key.len != 1) return false;
        var rows: [max_rows]Row = undefined;
        const n = app.switcherRows("", &rows);
        const row: ?Row = if (prompt.selected < n) rows[prompt.selected] else null;
        switch (key[0]) {
            'j' => prompt.selected = @min(prompt.selected + 1, n -| 1),
            'k' => prompt.selected -|= 1,
            '/' => prompt.filtering = true,
            ' ' => if (row) |r| if (r == .claude) {
                app.prompt = null;
                app.normal = true;
                app.openPopup(r.claude.win.id);
            },
            'J', 'K' => if (row) |r| if (r == .session) {
                const to = if (key[0] == 'J') r.session + 1 else r.session -| 1;
                if (to < app.listedSessions() and to != r.session) {
                    try app.moveSession(r.session, to);
                    prompt.selected = if (key[0] == 'J') prompt.selected + 1 else prompt.selected - 1;
                }
            },
            'x' => if (row) |r| if (r == .session) {
                app.doomed = app.sessions.items[r.session].id;
                app.prompt = null;
                app.openMenu(&menu.confirm_session);
            },
            else => return false,
        }
        return true;
    }

    /// Whether the pointer at cell `cx` of the foot row is on its windows, which then show their
    /// names: on a tab once they are shown, else anywhere but a button.
    fn overDots(app: *const App, cx: usize) bool {
        const s = app.cur() orelse return false;
        var widths: [max_tabs]usize = undefined;
        const tabs = tabWidths(s, &widths);
        if (app.over_dots and tabs.len > 0 and layout.tabAt(app.view_w, tabs, cx) != null) return true;
        return switch (app.footPart(cx) orelse layout.FootHit{ .window = 0 }) {
            .home, .go, .menu => false,
            .window => true,
        };
    }

    /// What of the foot row is at its cell `cx`: a button, or a window's dot.
    fn footPart(app: *const App, cx: usize) ?layout.FootHit {
        const s = app.cur() orelse return null;
        return layout.footAt(app.view_w, s.wins.items.len, cx);
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
        if (app.drag == .next_row) return app.dragNextRow(m);
        if (app.drag == .todo_row) return app.dragTodoRow(m);
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
            .next_row, .todo_row => {},
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
        }
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
    /// the pointer.
    pub const Drop = union(enum) { none, column: usize };

    pub fn dropAt(app: *const App) Drop {
        if (app.drag != .title) return .none;
        const s = app.cur() orelse return .none;
        const ox = app.term_w - app.view_w;
        if (app.pointer.x < ox) return .none;
        const hit = app.colAt(s, @as(i32, app.pointer.x) - ox + s.scroll) orelse return .none;
        return if (s.wins.items[hit.index].id == app.drag.title) .none else .{ .column = hit.index };
    }

    /// The sessions the switcher and the overview list: all but babylon's, which sorts last.
    pub fn listedSessions(app: *const App) usize {
        var n: usize = 0;
        while (n < app.sessions.items.len and !app.sessions.items[n].unlisted()) n += 1;
        return n;
    }

    /// Where babylon's session is, when it is there.
    pub fn gateSession(app: *const App) ?usize {
        for (app.listedSessions()..app.sessions.items.len) |i| if (app.sessions.items[i].gate()) return i;
        return null;
    }

    /// Where the orchestrator's session is, when it is running.
    pub fn orchestratorSession(app: *const App) ?usize {
        for (app.listedSessions()..app.sessions.items.len) |i| if (app.sessions.items[i].orchestrator()) return i;
        return null;
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

    /// Puts the session at `at` at `to`, and has tmux keep every session's place.
    fn moveSession(app: *App, at: usize, to: usize) !void {
        app.sessions.insertAssumeCapacity(to, app.sessions.orderedRemove(at));
        for (app.sessions.items, 1..) |s, place| {
            s.order = @intCast(place);
            try app.send(.ignore, "set-option -t '${d}' @arena_order {d}", .{ s.id, place });
        }
        app.dirty = true;
    }

    /// Moves the current session up or down the order.
    fn sessionSwapBy(app: *App, delta: i32) !void {
        const at = app.sessionIndex(app.current) orelse return;
        const next = @as(i32, @intCast(at)) + delta;
        if (at >= app.listedSessions() or next < 0 or next >= app.listedSessions()) return;
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

    /// The mouse over the text of the window drawn over the rest: a drag selects, and copies on
    /// let go; in a modal a second press on the same cell picks its word, a third its line (in
    /// Plan's windows a repeated press is a repeated click). A first press is still the press of
    /// what is under it. Whether the event was the selection's.
    pub fn grabMouse(app: *App, m: keys.Mouse) !bool {
        const g = &app.grab;
        if (g.n_areas == 0 or (!g.modal and (app.menu != null or app.prompt != null or app.popup != null))) {
            g.pressed = null;
            g.dragging = false;
            return false;
        }
        const at: grab_mod.Point = .{ .x = m.x, .y = m.y };
        if (m.leftPress()) g.active = g.paneAt(at) orelse g.active;
        const area = g.areas[g.active];
        if (g.dragging) {
            if (m.release or m.hover()) {
                g.dragging = false;
                try app.copyPicked();
            } else if (m.motion()) {
                g.sel.?.to = area.clamp(at);
            }
            app.dirty = true;
            return true;
        }
        if (m.leftPress()) {
            g.pressed = null;
            if (g.sel != null) {
                g.sel = null;
                app.dirty = true;
            }
            if (g.paneAt(at) == null) return false;
            const clicks = g.press(app.now, at);
            if (clicks == 1 or !g.modal) {
                g.pressed = at;
                return false;
            }
            g.sel = (if (clicks == 2) g.word(at) else g.wholeLine(at)) orelse return false;
            g.held_valid = false;
            try app.copyPicked();
            app.dirty = true;
            return true;
        }
        if (g.pressed) |from| {
            if (m.release) g.pressed = null else if (m.motion() and !m.hover() and !m.wheel() and app.drag == .none and (at.x != from.x or at.y != from.y)) {
                g.dragging = true;
                g.pressed = null;
                g.sel = .{ .from = from, .to = area.clamp(at) };
                g.held_valid = false;
                app.dirty = true;
                return true;
            }
        }
        return false;
    }

    fn copyPicked(app: *App) !void {
        const text = try app.grab.read(app.gpa, app.grab.sel orelse return);
        defer app.gpa.free(text);
        try app.copyText(text);
    }

    /// A right click nothing else took opens the menu; with the menu open, a click picks from it
    /// or, outside it, closes it.
    fn onMouse(app: *App, m: keys.Mouse) !void {
        app.pointer = .{ .x = m.x, .y = m.y };
        if (try app.grabMouse(m)) return;
        if (m.leftPress() and app.menu == null and app.prompt == null and app.overview == null) {
            // with the board open, where a click puts the keys is the board's to say: a click on
            // its chrome must not leave the focused column in normal mode, drawn as insert
            if (app.paneClick(m)) {
                app.normal = false;
            } else if (app.home == null) app.normal = true;
            app.dirty = true;
        }
        try app.pointAs(m);
        if (m.hover()) {
            app.hoverLook(m);
        } else if (m.leftPress() or m.rightPress()) {
            app.lookAway();
            app.key_typed = false;
        }
        const over_dots = m.y == app.view_h and m.x >= app.term_w - app.view_w and app.overDots(m.x - (app.term_w - app.view_w));
        if (over_dots != app.over_dots) {
            app.over_dots = over_dots;
            app.dirty = true;
        }
        if (app.overview != null) return app.overviewMouse(m);
        if (app.prompt) |prompt| if (prompt.multiline()) {
            if (m.leftPress()) try app.wordsClick(prompt, m);
            return;
        };
        if (app.home != null) if (try app.homeMouse(m)) return;
        if (app.prompt) |*prompt| {
            if (!m.leftPress() and !m.rightPress()) return;
            app.dirty = true;
            const at = app.box(prompt.height());
            const first = at.y + menu.Prompt.list_row;
            const wide = app.switcherW();
            const listed = prompt.what == .jump and m.leftPress() and m.x > at.x and m.x + 1 < at.x + wide and
                m.y >= first and m.y < first + menu.jump_rows;
            if (!listed) {
                if (prompt.what == .words or prompt.what == .why or prompt.what == .tried) app.endWords() else {
                    app.prompt = null;
                }
                return;
            }
            prompt.selected = prompt.top() + m.y - first;
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

    /// Whether the mouse event was for something. On the strip: a click goes to that window, dot
    /// or pane; a title is dragged onto another column, clicked twice to
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
        if (m.x < ox) return m.wheel() or m.leftPress();
        const s = app.cur() orelse return false;
        if (app.yoff != 0) return false;
        if (m.y == app.view_h) {
            if (m.wheel() and !m.sideways()) {
                if (app.navStep()) try app.focusBy(if (m.code & 1 == 0) -1 else 1);
                return true;
            }
            var widths: [max_tabs]usize = undefined;
            const tabs = tabWidths(s, &widths);
            const tab = if (app.over_dots and tabs.len > 0) layout.tabAt(app.view_w, tabs, m.x - ox) else null;
            const part = if (tab) |at| layout.FootHit{ .window = at } else app.footPart(m.x - ox) orelse return false;
            if (!m.leftPress()) return false;
            switch (part) {
                .home => try app.goHome(),
                .go => app.openSwitcher(),
                .menu => app.openMenu(&menu.main),
                .window => |at| try app.focusTo(at),
            }
            return true;
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
        return app.menu != null or app.prompt != null or app.overview != null or app.home != null;
    }

    /// Where the top left corner of a menu or prompt `height` rows tall is: centred over the strip.
    pub fn box(app: *const App, height: u16) struct { x: u16, y: u16 } {
        const width = if (app.prompt) |p| (if (p.what == .jump) app.switcherW() else menu.width) else menu.width;
        return .{
            .x = app.term_w - app.view_w + (app.view_w -| width) / 2,
            .y = (app.view_h -| height) / 2,
        };
    }

    /// The switcher's box, wide enough for a Claude's ticket, session and age on a row.
    pub fn switcherW(app: *const App) u16 {
        return @min(menu.switcher_w, app.view_w);
    }

    /// Whether what is typed is the focused pane's: nothing lies over the strip, or the board
    /// does with the orchestrator's column beside it focused.
    fn typing(app: *const App) bool {
        return !app.normal and app.menu == null and app.prompt == null and app.overview == null and (app.home == null or app.sideFocused());
    }

    /// Whether a left click at `m` is on the strip or the board's side column, which it makes
    /// insert; the board is chrome.
    fn paneClick(app: *const App, m: keys.Mouse) bool {
        if (app.home) |view| return app.sideShown() and !view.boxed() and m.y < app.view_h and m.x >= app.term_w - app.view_w;
        return m.y < app.view_h and m.x >= app.term_w - app.view_w;
    }

    /// Normal mode ends where an overlay has the keys: it is the mode there, and closing it is
    /// back to insert.
    fn settleMode(app: *App) void {
        if (app.normal and app.overlay() and !app.sideFocused() and app.popup == null) app.normal = false;
        if (!app.normal) {
            app.hash_len = null;
            app.closePopup();
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
        } else if (app.home) |*view| {
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
            'o' => try app.openDrawer(),
            'O' => app.openOverview(),

            'm' => app.openMenu(&menu.main),
            '/', 's' => app.openSwitcher(),
            'n' => try app.showInbox(),
            '?' => {
                app.strip_help = true;
                app.dirty = true;
            },
            'g' => {
                if (app.home == null) try app.toggleHome();
                if (app.home != null) try app.gateModal();
            },
            'Q' => app.quit = true,
            else => {},
        }
    }

    /// An arrow is ESC, `[` or `O`, and one more byte; a key with a modifier is ESC, `[`, digits
    /// and semicolons, and `u` or `~`; anything else, a bare Esc included, is a byte.
    fn keyLen(text: []const u8) usize {
        if (text.len < 3 or text[0] != 0x1b or (text[1] != '[' and text[1] != 'O')) return 1;
        if (text[1] == '[' and std.ascii.isDigit(text[2])) {
            var n: usize = 2;
            while (n < text.len and (std.ascii.isDigit(text[n]) or text[n] == ';')) n += 1;
            if (n < text.len and (text[n] == 'u' or text[n] == '~')) return n + 1;
        }
        return 3;
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
                if (app.home == null and anyKey(key, &.{"#"})) {
                    app.hash_len = 0;
                    app.dirty = true;
                    continue;
                }
                if (app.sideFocused() and app.drawerOpen() and anyKey(key, &.{"\x1b"})) {
                    try app.closeDrawer();
                    continue;
                }
                if (app.sideFocused() and try win_feed.press(app, key)) continue;
                if (app.sideFocused() and app.drawerOpen() and anyKey(key, &.{"o"})) {
                    try app.closeDrawer();
                    continue;
                }
                if (try app.sessionKey(key)) continue;
                if (std.mem.eql(u8, key, "i") or std.mem.eql(u8, key, "\x1b")) {
                    app.normal = false;
                    app.dirty = true;
                }
                if (std.mem.eql(u8, key, "b")) try app.goHome();
                if (app.home == null) {
                    try app.stripKey(key);
                    // a key that opened a menu, prompt or overview leaves the rest of the read to it
                    if (app.overlay()) app.normal = false;
                }
            } else if (app.overview != null and !asking) {
                try app.overviewKey(key);
            } else if (app.home != null and !app.sideFocused() and !asking) {
                try app.homeKey(key);
            } else if (app.prompt) |*prompt| {
                app.dirty = true;
                if (try app.switcherKey(prompt, key)) continue;
                switch (prompt.press(key)) {
                    .none => if (prompt.what == .find) app.refind(),
                    .cancel => if (prompt.what == .find) app.clearFind() else if (prompt.what == .words or prompt.what == .why or prompt.what == .tried) app.endWords() else {
                        app.prompt = null;
                    },
                    .commit => try app.commit(),
                    .up => prompt.selected -|= 1,
                    .down => {
                        var rows: [max_rows]Row = undefined;
                        if (prompt.selected + 1 < app.switcherRows(prompt.text(), &rows)) prompt.selected += 1;
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
                var rows: [max_rows]Row = undefined;
                const n = app.switcherRows(prompt.text(), &rows);
                if (prompt.selected < n) try app.goRow(rows[prompt.selected]);
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
                    .jump => app.openSwitcher(),
                    .overview => app.openOverview(),
                    .home => try app.toggleHome(),

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
        if (app.home) |view| {
            if (view.boxed()) return w.writeAll("a box over the plan");
            if (p.x >= app.boardW()) return w.writeAll(if (app.sided()) "the orchestrator column" else "the plan's edge");
            var sheet: sheets.Sheet = undefined;
            if (app.planSheet(&sheet)) if (app.planRowAt(&sheet, p.x, p.y)) |at| if (sheet.rows[at].ticket) |id| if (app.cardById(id)) |c| {
                return w.print("card #{d} {s}", .{ c.id, c.title });
            };
            return w.writeAll("the plan's background");
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
        if (app.home) |view| {
            try w.writeAll("home");
            if (app.planRepo()) |repo| try w.print(", {s} only", .{repo});
            if (view.boxed()) try w.writeAll(", a box open");
            if (app.sided()) try w.print(", orchestrator column {s}", .{if (view.focus == .orchestrator) "focused" else "beside"});
            return;
        }
        const s = app.cur() orelse return w.writeAll("no session");
        try w.print("session {s}", .{s.name});
        if (s.focused()) |win| try w.print(", window {s}", .{win.name});
    }

    /// What is picked: the plan's card, the column's feed item or the focused window.
    fn writePicked(app: *const App, w: *Writer) !void {
        if (app.home) |view| {
            if (view.focus == .orchestrator and app.sided()) return w.print("the orchestrator column's feed item {d}", .{view.pick});
            if (app.pickedCard()) |c| return w.print("card #{d} {s}", .{ c.id, c.title });
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
            const view = &app.home.?;
            const s = app.sessionById(app.bound()).?;
            const at_board = view.focus == .plan;
            // the board is the column before the orchestrator's first
            if (letter == 'h' and !at_board and s.focus == 0 and app.drawerOpen()) return app.closeDrawer();
            if (!view.boxed() and ((at_board and letter == 'l') or (!at_board and letter == 'h' and s.focus == 0))) {
                view.focus = if (at_board) .orchestrator else .plan;
                app.dirty = true;
                return;
            }
            if (app.sideFocused() and (letter == 'h' or letter == 'l')) return app.focusBy(if (letter == 'h') -1 else 1);
        }
        if (app.overlay()) {
            app.menu = null;
            app.prompt = null;
            app.overview = null;
            if (app.home != null) try app.closeBoard();
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
            'b' => try app.toggleHome(),
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
    /// J and K move the session down and up,
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
            if (part.event == null or part.event.? != .osc) {
                // a notice that goes by itself outlasts the pointer moving
                const moved = part.event != null and part.event.? == .mouse and app.report_until != 0;
                if (!moved) app.clearReportSaid();
            }
            if (part.text.len > 0 and app.grab.sel != null) {
                app.grab.sel = null;
                app.dirty = true;
            }
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

    /// The repo colour of the ticket claimed by the Claude in `pane`, if one is.
    fn frameOf(app: *const App, pane: u32) ?color.RGB {
        const r = app.roles orelse return null;
        const b = if (app.board) |*board| board else return null;
        for (b.cards()) |card| {
            if (card.status != .doing or (card.holder() orelse continue) != pane) continue;
            for (Roles.repo_names, 0..) |name, i| if (std.mem.eql(u8, name, card.repo orelse "")) return r.repo[i];
        }
        return null;
    }

    /// The border of each pane holding a claimed ticket in the ticket's repo colour, and tmux's
    /// own again where the claim has ended.
    fn frameSync(app: *App) !void {
        for (app.sessions.items) |s| for (s.wins.items) |win| for (win.panes.items) |pane| {
            const want = app.frameOf(pane.id);
            if (std.meta.eql(want, pane.frame)) continue;
            pane.frame = want;
            if (want) |c| {
                try app.send(.ignore, "set -p -t %{d} pane-border-style \"fg=#{x:0>2}{x:0>2}{x:0>2}\"", .{ pane.id, c.r, c.g, c.b });
                try app.send(.ignore, "set -p -t %{d} pane-active-border-style \"fg=#{x:0>2}{x:0>2}{x:0>2}\"", .{ pane.id, c.r, c.g, c.b });
            } else {
                try app.send(.ignore, "set -pu -t %{d} pane-border-style", .{pane.id});
                try app.send(.ignore, "set -pu -t %{d} pane-active-border-style", .{pane.id});
            }
        };
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
        // A pane left in a mode, by tmux's own output or the human's, takes the keys itself. Not
        // `if-shell`: the command it runs answers too, and arena would take that for the next reply.
        try app.send(.ignore, "copy-mode -q -t %{d}", .{pane.id});
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
        if (std.mem.indexOf(u8, line, "Enter to select") != null) out.boxed = true;
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
    /// Of the line last returned: set when it runs on from the one before, to the spaces the wrap
    /// took out between them.
    dropped: ?usize = null,
    gap: usize = 0,

    pub fn init(text: []const u8, inner: usize) DetailLines {
        return .{ .lines = std.mem.splitScalar(u8, std.mem.trimEnd(u8, text, "\n"), '\n'), .inner = inner };
    }

    pub fn next(it: *DetailLines) ?[]const u8 {
        it.dropped = if (it.rest != null) it.gap else null;
        const rest = it.rest orelse it.lines.next() orelse return null;
        var cut = std.unicode.Utf8View.initUnchecked(rest).iterator();
        var n: usize = 0;
        while (n < it.inner) : (n += 1) _ = cut.nextCodepointSlice() orelse break;
        const line = rest[0..cut.i];
        const after = std.mem.trimStart(u8, rest[cut.i..], " ");
        it.gap = rest.len - cut.i - after.len;
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

/// The last `n` lines of `text`, each cut to 100 characters, in `buf`.
fn lastLines(text: []const u8, n: usize, buf: []u8) []const u8 {
    const body = std.mem.trimEnd(u8, text, " \r\n");
    var from: usize = 0;
    var seen: usize = 0;
    var i = body.len;
    while (i > 0) : (i -= 1) if (body[i - 1] == '\n') {
        seen += 1;
        if (seen == n) {
            from = i;
            break;
        }
    };
    var w: Writer = .fixed(buf);
    var lines = std.mem.splitScalar(u8, body[from..], '\n');
    var first = true;
    while (lines.next()) |line| {
        if (!first) w.writeByte('\n') catch break;
        first = false;
        w.writeAll(@import("text.zig").clip(std.mem.trimEnd(u8, line, "\r"), 100)) catch break;
    }
    return w.buffered();
}

test lastLines {
    var buf: [256]u8 = undefined;
    try std.testing.expectEqualStrings("b\nc", lastLines("a\nb\nc\n\n", 2, &buf));
    try std.testing.expectEqualStrings("hi", lastLines("hi\n", 5, &buf));
    try std.testing.expectEqualStrings("", lastLines("", 5, &buf));
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
pub fn plainName(name: []const u8) bool {
    for (name) |c| if (!std.ascii.isAlphanumeric(c) and c != '-' and c != '_' and c != '.') return false;
    return name.len > 0;
}

test "the session to go back to is forgotten once it, or the orchestrator's, is gone, the column keeping the keys" {
    var app: App = .{ .gpa = std.testing.allocator, .io = undefined, .tmux_in = undefined };
    defer app.deinit();
    app.current = 2;
    const eq = std.testing.expectEqual;

    app.home = .{ .back = 1, .focus = .orchestrator };
    try app.onSessions("$1 0 work\n$2 1 orchestrator\n");
    try eq(@as(?u32, 1), app.home.?.back);
    try eq(.orchestrator, app.home.?.focus);

    try app.onSessions("$2 1 orchestrator\n");
    try eq(@as(?u32, null), app.home.?.back);

    app.home.?.back = 1;
    try app.onSessions("$1 0 work\n");
    try eq(@as(?u32, null), app.home.?.back);
    try eq(.orchestrator, app.home.?.focus);
}

test "home: the board with the orchestrator's column focused, its own keys while no window is in it" {
    var app: App = .{ .gpa = std.testing.allocator, .io = undefined, .tmux_in = undefined };
    defer app.deinit();
    const expect = std.testing.expect;
    try app.goHome();
    try expect(app.home == null);

    app.board = try tickets.Board.parse(std.testing.allocator,
        \\{"tickets":[{"id":1,"repo":"arena","title":"a","status":"todo"}],"plan":{"next":[]}}
    );
    app.normal = true;
    try app.goHome();
    try expect(app.home.?.focus == .plan);
    try expect(!app.drawerOpen() and !app.sided() and !app.columnFocused());
    try expect(app.orchestratorState() == .off);

    try app.openDrawer();
    try expect(app.drawerOpen() and app.sided() and app.columnFocused() and !app.normal);
    try expect(!app.typing());
    try app.closeDrawer();
    try expect(!app.drawerOpen() and app.home.?.focus == .plan and !app.columnFocused());

    try app.openDrawer();
    app.home.?.focus = .orchestrator;
    app.home.?.help = true;
    const was = app.kept().?;
    try expect(!was.view.help and was.view.focus == .orchestrator);
    app.home.?.help = false;
    _ = try app.onInput("q");
    try expect(app.home == null);
    try app.restore(was);
    try expect(app.home != null and app.columnFocused());
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

test "a doc's table has its empty cells padded, so glow gives their column room" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "d.md", .data = "| a | b | |\n| --- | --- | --- |\n| x | y | |\n\nno | | cell\n" });
    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = dir_buf[0..try tmp.dir.realPath(std.testing.io, &dir_buf)];
    const script = try std.fmt.allocPrint(std.testing.allocator, "f={s}/d.md; {s}", .{ dir, App.pad_empty_cells });
    defer std.testing.allocator.free(script);
    const ran = try std.process.run(std.testing.allocator, std.testing.io, .{ .argv = &.{ "sh", "-c", script } });
    defer std.testing.allocator.free(ran.stdout);
    defer std.testing.allocator.free(ran.stderr);
    const pad = "\u{a0}\u{a0}\u{a0}\u{a0}\u{a0}\u{a0}\u{a0}\u{a0}\u{a0}\u{a0}" ++ "\u{a0}\u{a0}\u{a0}\u{a0}\u{a0}\u{a0}\u{a0}\u{a0}\u{a0}\u{a0}" ++ "\u{a0}\u{a0}\u{a0}\u{a0}\u{a0}\u{a0}\u{a0}\u{a0}\u{a0}\u{a0}";
    const want = "| a | b |" ++ pad ++ "|\n| --- | --- | --- |\n| x | y |" ++ pad ++ "|\n\nno | | cell\n";
    try std.testing.expectEqualStrings(want, ran.stdout);
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
    app.home = .{ .focus = .orchestrator };
    try app.homeKey("A");
    try std.testing.expectEqual(@as(?usize, 0), app.home.?.auto_pick);
    try std.testing.expect(app.home.?.focus == .plan);
    try app.homeKey("j");
    try app.homeKey("j");
    try app.homeKey("+");
    try app.homeKey("+");
    try std.testing.expectEqual(@as(u32, 4), app.autoRepo(0).?.cap);
    try std.testing.expectEqual(@as(usize, 1), app.auto_wants.list.items.len);
    try app.homeKey("j");
    try app.homeKey("-");
    try std.testing.expectEqual(@as(u32, 0), app.autoRepo(1).?.cap);
    try app.homeKey("H");
    try std.testing.expect(app.holding());
    try app.homeKey("a");
    try std.testing.expect(app.auto() == null);

    app.auto_wants.list.items[0].due = 0;
    try app.autoRefused("auto:cap:arena", "babylon: no such repo\nmore");
    try std.testing.expectEqual(@as(u32, 2), app.autoRepo(0).?.cap);
    try std.testing.expectEqualStrings("babylon: no such repo", app.auto_wants.refused.?);

    try app.homeKey("\x1b");
    try std.testing.expectEqual(@as(?usize, null), app.home.?.auto_pick);
}

test "⏎ on a card's peek is left to home, not sent to a Claude's pane" {
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
    app.home = .{ .focus = .orchestrator };
    app.look = .{ .ticket = 6 };
    try std.testing.expect(!try app.lookKey("\r"));
    try std.testing.expect(app.look == null);
    try std.testing.expect(app.home.?.focus == .plan);
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

test "the switcher: s opens it, j k move, J K move a session, x asks, a typed key filters" {
    var one: Session = .{ .id = 2, .name = @constCast("alpha") };
    var two: Session = .{ .id = 3, .name = @constCast("beta") };
    var sessions = [_]*Session{ &one, &two };
    var app: App = .{ .gpa = std.testing.allocator, .io = undefined, .tmux_in = undefined };
    app.sessions = .fromOwnedSlice(&sessions);
    app.normal = true;
    try app.menuKeys("s");
    try std.testing.expectEqual(menu.Prompt.What.jump, app.prompt.?.what);
    var rows: [App.max_rows]App.Row = undefined;
    try std.testing.expectEqual(@as(usize, 3), app.switcherRows("", &rows));
    try std.testing.expectEqual(@as(usize, 0), rows[0].session);
    try std.testing.expect(rows[2] == .new);
    try app.menuKeys("j");
    try std.testing.expectEqual(@as(usize, 1), app.prompt.?.selected);
    try app.menuKeys("k");
    try std.testing.expectEqual(@as(usize, 0), app.prompt.?.selected);
    try app.menuKeys("b");
    try std.testing.expectEqualStrings("b", app.prompt.?.text());
    try std.testing.expectEqual(@as(usize, 1), app.switcherRows("b", &rows));
    app.prompt = .{ .what = .jump };
    try app.menuKeys("jx");
    try std.testing.expect(app.prompt == null);
    try std.testing.expectEqual(@as(u32, 3), app.doomed);
    try std.testing.expect(app.menu != null);
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
    app.home = .{ .back = 1 };
    app.current = 1;
    app.heading = 2;
    app.switches = 1;
    try expect(!app.typing());
    try app.onChord('l');
    try expect(app.home.?.focus == .orchestrator);
    try expect(app.typing());
    try app.onChord('l');
    try expect(app.home != null);

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
    var babylon: Session = .{ .id = 1, .name = @constCast("babylon-gate") };
    babylon.wins = .fromOwnedSlice(&gates);
    try std.testing.expect(!(Session{ .id = 9, .name = @constCast("babylon") }).gate());
    var work: Session = .{ .id = 2, .name = @constCast("work") };
    work.wins = .fromOwnedSlice(&mines);
    var sessions = [_]*Session{ &work, &babylon };
    var app: App = .{ .gpa = std.testing.allocator, .io = undefined, .tmux_in = undefined };
    app.sessions = .fromOwnedSlice(&sessions);
    try std.testing.expectEqual(@as(usize, 1), app.listedSessions());
    try std.testing.expectEqual(@as(?usize, 1), app.gateSession());
    var found: [4]App.Agent = undefined;
    try std.testing.expectEqual(@as(usize, 1), app.agents(&found));
    try std.testing.expectEqual(@as(u32, 2), found[0].win.id);
    try std.testing.expectEqual(@as(?usize, null), app.orchestratorSession());

    var orch: Session = .{ .id = 3, .name = @constCast("orchestrator") };
    var three = [_]*Session{ &work, &babylon, &orch };
    app.sessions = .fromOwnedSlice(&three);
    try std.testing.expectEqual(@as(usize, 1), app.listedSessions());
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
    app.home = .{ .detail = 4 };
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
    try std.testing.expectEqual(@as(?u32, null), app.home.?.detail);
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
    app.home = .{ .detail = 4 };
    const eq = std.testing.expectEqual;
    const rect = app.modalRect().?;

    var buttons: [16]App.ModalButton = undefined;
    const second = for (app.modalButtons(&buttons)) |b| {
        if (b.action == .option and b.action.option == 2) break b;
    } else return error.NoOption;
    try std.testing.expect(try app.homeMouse(.{ .code = 0, .x = second.x + 1, .y = second.y, .release = false }));
    try eq(@as(?u32, null), app.home.?.detail);
    var got: [512]u8 = undefined;
    const len = try sent.readPositionalAll(std.testing.io, &got, 0);
    try std.testing.expect(std.mem.indexOf(u8, got[0..len], "babylon answer 9 2") != null);

    app.home.?.detail = 4;
    try std.testing.expect(try app.homeMouse(.{ .code = 0, .x = rect.x + rect.w - 4, .y = rect.y, .release = false }));
    try eq(@as(?u32, null), app.home.?.detail);
}

test "a look's doc window is closed when its ask is answered or withdrawn, and one still asked is left" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const sent = try tmp.dir.createFile(std.testing.io, "tmux", .{ .read = true });
    defer sent.close(std.testing.io);
    var app: App = .{ .gpa = std.testing.allocator, .io = std.testing.io, .tmux_in = sent };
    defer app.pending.deinit(std.testing.allocator);
    defer if (app.board) |*b| b.deinit();
    try app.setBoard(
        \\{"tickets":[],"needs_you":[
        \\{"id":"ask:6","kind":"look","ticket":307,"repo":"tlon","text":"look","doc":"a.md","actions":[]},
        \\{"id":"ask:7","kind":"look","ticket":308,"repo":"tlon","text":"look","doc":"b.md","actions":[]},
        \\{"id":"ask:8","kind":"ask","ticket":309,"repo":"tlon","text":"which?","doc":null,"actions":[]}]}
    );
    try app.setBoard(
        \\{"tickets":[],"needs_you":[
        \\{"id":"ask:7","kind":"look","ticket":308,"repo":"tlon","text":"look","doc":"b.md","actions":[]}]}
    );
    var got: [512]u8 = undefined;
    const len = try sent.readPositionalAll(std.testing.io, &got, 0);
    try std.testing.expectEqualStrings("kill-window -t =doc-ask-6\n", got[0..len]);
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
    app.home = .{ .focus = .plan };
    const eq = std.testing.expectEqual;
    const view = &app.home.?;

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
    try std.testing.expect(try win_feed.press(&app, "j"));
    try eq(@as(usize, 1), view.plan_pick);
}

test "⏎ on an idea plans it, e and x edit and withdraw it, and ⏎ on the fold opens them" {
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
        \\{"tickets":[],"plan":{"ideas":[
        \\{"epic":829,"title":"garden","state":"idea"},
        \\{"epic":831,"title":"retro","state":"draft","steps":7}]}}
    );
    defer app.board.?.deinit();
    app.home = .{ .focus = .plan };
    const eq = std.testing.expectEqual;
    const view = &app.home.?;
    var got: [1024]u8 = undefined;

    try app.planKey("\r");
    var len = try sent.readPositionalAll(std.testing.io, &got, 0);
    try std.testing.expect(std.mem.indexOf(u8, got[0..len], "babylon idea 829 --plan") != null);

    const before = len;
    try app.planKey("x");
    len = try sent.readPositionalAll(std.testing.io, &got, 0);
    try std.testing.expect(std.mem.indexOf(u8, got[before..len], "babylon withdraw 829") != null);

    // a draft has no e or x of its own yet
    try app.planKey("j");
    try app.planKey("x");
    try app.planKey("e");
    try eq(len, try sent.readPositionalAll(std.testing.io, &got, 0));

    // e on a kept idea opens its window, and closes the board
    const then = len;
    try app.planKey("k");
    try app.planKey("e");
    len = try sent.readPositionalAll(std.testing.io, &got, 0);
    try std.testing.expect(std.mem.indexOf(u8, got[then..len], "babylon edit 829") != null);
    app.home = .{ .focus = .plan };

    app.board.?.deinit();
    app.board = try tickets.Board.parse(std.testing.allocator,
        \\{"tickets":[],"plan":{"ideas":[
        \\{"epic":1,"title":"a"},{"epic":2,"title":"b"},{"epic":3,"title":"c"},{"epic":4,"title":"d"}]}}
    );
    view.plan_pick = 0;
    var sheet: sheets.Sheet = undefined;
    try std.testing.expect(app.planSheet(&sheet));
    try std.testing.expect(sheet.picked(view.plan_pick).?.kind == .ideas_more);
    try app.planKey("\r");
    try eq(@as(u8, 1) << sheets.ideas_fold, view.unfolded);
    try std.testing.expect(app.planSheet(&sheet));
    try std.testing.expect(sheet.picked(view.plan_pick).?.kind == .idea);
}

test "d on a goal runs babylon drive, and 3 under a landed goal opens the new goal modal" {
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
        \\{"tickets":[],"plan":{"goals":[{"epic":326,"title":"board","landed":1,"total":2,"steps":[{"ticket":760,"state":"todo"}]}]}}
    );
    defer app.board.?.deinit();
    app.home = .{ .focus = .plan };
    try app.planKey("d");
    var got: [1024]u8 = undefined;
    const len = try sent.readPositionalAll(std.testing.io, &got, 0);
    try std.testing.expect(std.mem.indexOf(u8, got[0..len], "babylon drive 326") != null);

    app.board.?.deinit();
    app.board = try tickets.Board.parse(std.testing.allocator,
        \\{"tickets":[],"needs_you":[{"id":"drive:14","kind":"drive","ticket":14,"repo":"","text":"landed",
        \\"actions":[{"key":"1","label":"a","argv":["babylon","drive","1"]},{"key":"2","label":"b","argv":["babylon","drive","2"]}]}],
        \\"plan":{"driving":14,"goals":[]}}
    );
    try app.planKey("3");
    try std.testing.expect(app.home.?.goal_open);
}

const draft_board =
    \\{"tickets":[],"backlog":[
    \\{"id":830,"repo":"tlon","kind":"epic","title":"The bar shows what is safe to spend","status":"backlog"},
    \\{"id":832,"repo":"tlon","model":"claude-sonnet-5-5","title":"safe-to-spend as a file","status":"backlog","epic_id":830},
    \\{"id":833,"repo":"ficciones","model":"claude-haiku-5-5","title":"the bar reads it","status":"backlog","epic_id":830,"blocked_by":[832]}],
    \\"needs_you":[
    \\{"id":"ask:61","kind":"draft","ticket":830,"repo":"","text":"#830 The bar\n2 steps in 2 repos: tlon 1, ficciones 1","doc":null,
    \\ "actions":[{"key":"y","label":"go","argv":["babylon","adopt","830"]},{"key":"r","label":"reply","argv":["babylon","answer","61","--words"],"needs":"words"}]}],
    \\"plan":{"ideas":[{"epic":830,"title":"The bar","state":"draft","steps":2}]}}
;

test "space on a draft's tile opens its modal, j picks a step, y runs adopt and closes it, r opens the reply line" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const sent = try tmp.dir.createFile(std.testing.io, "tmux", .{ .read = true });
    defer sent.close(std.testing.io);
    var app: App = .{ .gpa = std.testing.allocator, .io = std.testing.io, .tmux_in = sent };
    defer app.pending.deinit(std.testing.allocator);
    defer app.clearReportSaid();
    app.term_w = 200;
    app.view_w = 60;
    app.view_h = 40;
    app.board = try tickets.Board.parse(std.testing.allocator, draft_board);
    defer app.board.?.deinit();
    app.home = .{ .focus = .orchestrator };
    app.normal = true;
    const eq = std.testing.expectEqual;
    const view = &app.home.?;

    try std.testing.expect(try win_feed.press(&app, " "));
    try eq(@as(?u32, 830), view.draft);
    try eq(@as(@TypeOf(view.focus), .plan), view.focus);
    try app.homeKey("j");
    try eq(@as(usize, 1), view.draft_pick);
    try app.homeKey("j");
    try eq(@as(usize, 1), view.draft_pick);

    try app.homeKey("y");
    try eq(@as(?u32, null), view.draft);
    var got: [1024]u8 = undefined;
    const len = try sent.readPositionalAll(std.testing.io, &got, 0);
    try std.testing.expect(std.mem.indexOf(u8, got[0..len], "'babylon' 'adopt' '830'") != null);

    app.openDraft(830);
    try app.homeKey("r");
    try eq(@as(?u32, null), view.draft);
    try std.testing.expect(app.prompt.?.what == .words);
    try std.testing.expectEqualStrings("ask:61", app.prompt.?.item());
}

test "⏎ on a draft's row on Plan opens the draft modal, and e edits the step picked" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const sent = try tmp.dir.createFile(std.testing.io, "tmux", .{ .read = true });
    defer sent.close(std.testing.io);
    var app: App = .{ .gpa = std.testing.allocator, .io = std.testing.io, .tmux_in = sent };
    defer app.pending.deinit(std.testing.allocator);
    app.term_w = 200;
    app.view_w = 60;
    app.view_h = 40;
    app.board = try tickets.Board.parse(std.testing.allocator, draft_board);
    defer app.board.?.deinit();
    app.home = .{ .focus = .plan };
    const view = &app.home.?;
    try app.planKey("\r");
    try std.testing.expectEqual(@as(?u32, 830), view.draft);
    try app.homeKey("j");
    try app.homeKey("e");
    var got: [1024]u8 = undefined;
    const len = try sent.readPositionalAll(std.testing.io, &got, 0);
    try std.testing.expect(std.mem.indexOf(u8, got[0..len], "babylon edit 833") != null);
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
    app.home = .{ .focus = .orchestrator };
    try std.testing.expect(try win_feed.press(&app, "\r"));
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
    try std.testing.expect(try app.homeMouse(.{ .code = 0, .x = x, .y = row + 1, .release = false }));
    len = try sent.readPositionalAll(std.testing.io, &got, 0);
    try std.testing.expect(len > before);
    try std.testing.expect(std.mem.indexOf(u8, got[before..len], "'babylon' 'digest' 'ok'") != null);
}

test "a row of next dragged onto another takes its place" {
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
    app.home = .{ .focus = .plan };
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
    const x = 3;
    try std.testing.expect(try app.homeMouse(.{ .code = 0, .x = x, .y = ys[1], .release = false }));
    try eq(@as(usize, 1), app.drag.next_row.from);
    try app.dragTo(.{ .code = 32, .x = x, .y = ys[0], .release = false });
    try app.dragTo(.{ .code = 0, .x = x, .y = ys[0], .release = true });
    try eq(@as(@TypeOf(app.drag), .none), app.drag);
    var got: [512]u8 = undefined;
    const len = try sent.readPositionalAll(std.testing.io, &got, 0);
    try std.testing.expect(std.mem.indexOf(u8, got[0..len], "'babylon' 'next' '12' '--at' '1'") != null);
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

    app.home = .{ .detail = 7 };
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
    try eq(@as(u8, 2), app.home.?.check_pick);
    try app.modalKey("j");
    try app.modalKey("j");
    try eq(@as(u8, 3), app.home.?.check_pick);
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

test "a drag over a wrapped line of the modal copies it as one line, inside the window, and Y copies a whole check" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const sent = try tmp.dir.createFile(std.testing.io, "tmux", .{ .read = true });
    defer sent.close(std.testing.io);
    var app: App = .{ .gpa = std.testing.allocator, .io = std.testing.io, .tmux_in = sent };
    defer app.pending.deinit(std.testing.allocator);
    defer app.out.deinit(std.testing.allocator);
    defer app.grab.deinit(std.testing.allocator);
    defer app.detail.deinit(std.testing.allocator);
    app.term_w = 140;
    app.view_w = 140;
    app.view_h = 30;
    const long_check = "run systemctl --user show babylon -p Environment and read the path of the offer.conf it names, then say what is in it";
    const json = try std.fmt.allocPrint(std.testing.allocator,
        \\{{"tickets":[{{"id":7,"repo":"arena","title":"Lights","status":"try","stage":"landed",
        \\"checks":[{{"n":1,"text":"it is told","result":null}},{{"n":2,"text":"{s}","result":null}}]}}],
        \\"plan":{{"now":[],"next":[],"goals":[],"landed_today":{{"count":0,"newest":[]}},"not_planned":{{"count":0,"follow_ups":0,"by_repo":{{}}}}}}}}
    , .{long_check});
    defer std.testing.allocator.free(json);
    app.board = try tickets.Board.parse(std.testing.allocator, json);
    defer app.board.?.deinit();
    const eql = std.testing.expectEqualStrings;
    app.home = .{ .detail = 7 };
    const inner = detailWidth(app.boardW()).inner;
    var body: std.ArrayList(u8) = .empty;
    defer body.deinit(std.testing.allocator);
    for (0..60) |n| try body.print(std.testing.allocator, "word{d} ", .{n});
    try app.detail.appendSlice(std.testing.allocator, body.items);

    var shot: Writer.Allocating = .init(std.testing.allocator);
    defer shot.deinit();
    try draw.frame(&app, &shot.writer, .all);
    const area = app.grab.areas[0];
    var wrapped: ?usize = null;
    for (app.grab.rows.items, 0..) |r, at| if (r.dropped != null and wrapped == null) {
        wrapped = at;
    };
    const second = app.grab.rows.items[wrapped.?];
    const first = app.grab.rows.items[wrapped.? - 1];

    // from the first cell of the row before the wrap to a cell of the one after, and then far
    // past the window's edge
    try std.testing.expect(try app.grabMouse(.{ .code = 0, .x = first.x, .y = first.y, .release = false }) == false);
    try std.testing.expect(try app.grabMouse(.{ .code = 32, .x = second.x + 3, .y = second.y, .release = false }));
    try std.testing.expect(app.grab.dragging);
    try std.testing.expect(try app.grabMouse(.{ .code = 32, .x = 900, .y = second.y, .release = false }));
    try std.testing.expectEqual(area.x + area.w - 1, app.grab.sel.?.to.x);
    _ = try app.grabMouse(.{ .code = 0, .x = 900, .y = second.y, .release = true });
    try std.testing.expect(!app.grab.dragging);
    try std.testing.expect(std.mem.indexOf(u8, app.out.items, "\x1b]52;c;") != null);
    const text = try app.grab.read(std.testing.allocator, app.grab.sel.?);
    defer std.testing.allocator.free(text);
    try std.testing.expect(std.mem.indexOfScalar(u8, text, '\n') == null);
    try std.testing.expect(std.mem.startsWith(u8, text, "word"));
    try std.testing.expect(std.mem.indexOf(u8, body.items, text) != null);
    try std.testing.expect(text.len > inner);
    var said: [32]u8 = undefined;
    try eql(try std.fmt.bufPrint(&said, "copied {d} chars", .{text.len}), app.report_said.?);

    // Y: the picked check, whole, though the modal cut it
    app.out.clearRetainingCapacity();
    app.home.?.check_pick = 2;
    try app.modalKey("Y");
    var want: [256]u8 = undefined;
    const encoded = std.base64.standard.Encoder.encode(&want, long_check);
    try std.testing.expect(std.mem.indexOf(u8, app.out.items, encoded) != null);
    app.clearReportSaid();
}

/// Draws the open modal and drags a selection across two of its wrapped body rows.
fn pickModalText(app: *App) !void {
    var shot: Writer.Allocating = .init(std.testing.allocator);
    defer shot.deinit();
    try draw.frame(app, &shot.writer, .all);
    var wrapped: ?usize = null;
    for (app.grab.rows.items, 0..) |r, at| if (r.dropped != null and wrapped == null) {
        wrapped = at;
    };
    const second = app.grab.rows.items[wrapped.?];
    const first = app.grab.rows.items[wrapped.? - 1];
    _ = try app.grabMouse(.{ .code = 0, .x = first.x, .y = first.y, .release = false });
    _ = try app.grabMouse(.{ .code = 32, .x = second.x + 3, .y = second.y, .release = false });
    _ = try app.grabMouse(.{ .code = 0, .x = second.x + 3, .y = second.y, .release = true });
    try std.testing.expect(app.grab.sel != null);
}

test "a selection in the modal drops on the j key, and when j scrolls the text under it" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const sent = try tmp.dir.createFile(std.testing.io, "tmux", .{ .read = true });
    defer sent.close(std.testing.io);
    var app: App = .{ .gpa = std.testing.allocator, .io = std.testing.io, .tmux_in = sent };
    defer app.pending.deinit(std.testing.allocator);
    defer app.out.deinit(std.testing.allocator);
    defer app.grab.deinit(std.testing.allocator);
    defer app.detail.deinit(std.testing.allocator);
    defer app.clearReportSaid();
    app.term_w = 140;
    app.view_w = 140;
    app.view_h = 30;
    const json =
        \\{"tickets":[{"id":7,"repo":"arena","title":"Lights","status":"doing","stage":"landed","checks":[]}],
        \\"plan":{"now":[],"next":[],"goals":[],"landed_today":{"count":0,"newest":[]},"not_planned":{"count":0,"follow_ups":0,"by_repo":{}}}}
    ;
    app.board = try tickets.Board.parse(std.testing.allocator, json);
    defer app.board.?.deinit();
    app.home = .{ .detail = 7 };
    var body: std.ArrayList(u8) = .empty;
    defer body.deinit(std.testing.allocator);
    for (0..200) |n| try body.print(std.testing.allocator, "word{d} ", .{n});
    try app.detail.appendSlice(std.testing.allocator, body.items);

    // the key itself drops it, with no frame drawn in between
    try pickModalText(&app);
    _ = try app.onInput("j");
    try std.testing.expect(app.grab.sel == null);

    // the scroll alone: the next frame finds other text under the pick and drops it
    app.now += 1000;
    try pickModalText(&app);
    var shot: Writer.Allocating = .init(std.testing.allocator);
    defer shot.deinit();
    try draw.frame(&app, &shot.writer, .all);
    try std.testing.expect(app.grab.sel != null);
    const scrolled = app.home.?.detail_scroll;
    try app.modalKey("j");
    try std.testing.expectEqual(scrolled + 1, app.home.?.detail_scroll);
    try std.testing.expect(app.grab.sel != null);
    try draw.frame(&app, &shot.writer, .all);
    try std.testing.expect(app.grab.sel == null);
}

fn tryApp(sent: std.Io.File, tmp_board: []const u8) !App {
    var app: App = .{ .gpa = std.testing.allocator, .io = std.testing.io, .tmux_in = sent };
    app.term_w = 200;
    app.view_w = 60;
    app.view_h = 40;
    app.epoch = 1795262400;
    app.board_dir = "arena-test-board";
    app.board = try tickets.Board.parse(std.testing.allocator, tmp_board);
    app.home = .{ .focus = .orchestrator };
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
    const view = &app.home.?;
    const eq = std.testing.expectEqual;
    var got: [2048]u8 = undefined;
    var f: feed.Feed = undefined;

    // the pick goes check to check with j, tile to tile with ] and [, round at either end
    view.pick = 1;
    try std.testing.expect(try win_feed.press(&app, "j"));
    try eq(@as(usize, 2), view.pick);
    try std.testing.expect(try win_feed.press(&app, "]"));
    try eq(@as(usize, 3), view.pick);
    try std.testing.expect(try win_feed.press(&app, "]"));
    try eq(@as(usize, 4), view.pick);
    try std.testing.expect(try win_feed.press(&app, "]"));
    try eq(@as(usize, 0), view.pick);
    try std.testing.expect(try win_feed.press(&app, "]"));
    try eq(@as(usize, 1), view.pick);
    try std.testing.expect(try win_feed.press(&app, "["));
    try eq(@as(usize, 0), view.pick);
    try std.testing.expect(try win_feed.press(&app, "["));
    try eq(@as(usize, 4), view.pick);
    try std.testing.expect(try win_feed.press(&app, "["));
    try eq(@as(usize, 3), view.pick);
    try std.testing.expect(try win_feed.press(&app, "["));
    try eq(@as(usize, 1), view.pick);

    // y runs the check's ok argv; once babylon says it settled, the pick is on the next open one
    try std.testing.expect(try win_feed.press(&app, "y"));
    try std.testing.expect(std.mem.indexOf(u8, try sentText(sent, &got), "'babylon' 'tried' '825' '1' 'ok'") != null);
    app.board.?.deinit();
    const after = try std.mem.replaceOwned(u8, std.testing.allocator, feed.try_sample, "with buttons\",\"result\":null", "with buttons\",\"result\":\"ok\"");
    defer std.testing.allocator.free(after);
    app.board = try tickets.Board.parse(std.testing.allocator, after);
    try std.testing.expect(app.feedOf(&f));
    try eq(@as(?usize, 2), app.feedPick(&f).?.step);

    // x runs the tile's close untried
    try std.testing.expect(try win_feed.press(&app, "x"));
    try std.testing.expect(std.mem.indexOf(u8, try sentText(sent, &got), "'babylon' 'tried' '825' 'skip'") != null);

    // space opens the ticket's modal
    try std.testing.expect(try win_feed.press(&app, " "));
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
    app.home.?.pick = 2;
    var got: [2048]u8 = undefined;

    try std.testing.expect(try win_feed.press(&app, "n"));
    try std.testing.expectEqual(menu.Prompt.What.words, app.prompt.?.what);
    try std.testing.expect(App.stepWords(app.prompt.?));
    for ("two minutes late") |byte| _ = app.prompt.?.press(&.{byte});
    try app.commit();
    try std.testing.expect(app.prompt == null);
    try std.testing.expect(std.mem.indexOf(u8, try sentText(sent, &got), "'babylon' 'tried' '825' '3' 'no' 'two minutes late'") != null);

    // esc closes the line and runs nothing
    const before = (try sentText(sent, &got)).len;
    try std.testing.expect(try win_feed.press(&app, "n"));
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
    const view = &app.home.?;
    const eq = std.testing.expectEqual;
    var got: [4096]u8 = undefined;
    var f: feed.Feed = undefined;

    // a click on a check's row picks it
    view.pick = 0;
    try std.testing.expect(app.feedOf(&f));
    try std.testing.expect(try app.homeMouse(feedPoint(&app, rowOf(&f, .try_step, 2), 8)));
    try std.testing.expect(app.feedOf(&f));
    try eq(@as(?usize, 2), app.feedPick(&f).?.step);

    // its buttons show under it; a click on ✓ is y
    const buttons = rowOf(&f, .try_buttons, 2);
    try std.testing.expect(try app.homeMouse(feedPoint(&app, buttons, 3)));
    try std.testing.expect(std.mem.indexOf(u8, try sentText(sent, &got), "'babylon' 'tried' '825' '3' 'ok'") != null);

    // a click on ✗ is n: the modal for the words opens, a click outside its buttons does nothing to it
    try std.testing.expect(try app.homeMouse(feedPoint(&app, buttons, 10)));
    try std.testing.expect(App.stepWords(app.prompt.?));
    for ("late") |byte| _ = app.prompt.?.press(&.{byte});
    try app.onMouse(feedPoint(&app, 3, 10));
    try std.testing.expect(app.prompt != null);

    // and one on `send it back` sends it with the words
    var modal_buttons: [2]App.ModalButton = undefined;
    const send = app.wordsButtons(app.prompt.?, &modal_buttons)[0];
    try app.onMouse(.{ .code = 0, .x = send.x + 2, .y = send.y, .release = false });
    try std.testing.expect(app.prompt == null);
    try std.testing.expect(std.mem.indexOf(u8, try sentText(sent, &got), "'babylon' 'tried' '825' '3' 'no' 'late'") != null);

    // the number and the title open the ticket's modal
    try std.testing.expect(app.feedOf(&f));
    try std.testing.expect(try app.homeMouse(feedPoint(&app, rowOf(&f, .try_title, null), 12)));
    try eq(@as(?u32, 825), view.detail);
    view.detail = null;

    // the picked tile's close untried button closes it untried
    try std.testing.expect(app.feedOf(&f));
    const machine = rowOf(&f, .try_machine, null);
    try std.testing.expect(f.line(machine).alt.len > 0);
    try std.testing.expect(try app.homeMouse(feedPoint(&app, machine, 50)));
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
    app.home.?.pick = 0;
    var f: feed.Feed = undefined;
    try std.testing.expect(app.feedOf(&f));
    try std.testing.expectEqualStrings("o look   y ✓   n ✗", f.line(rowOf(&f, .try_buttons, 0)).text);

    try std.testing.expect(try win_feed.press(&app, "o"));
    var got: [4096]u8 = undefined;
    const said = try sentText(sent, &got);
    try std.testing.expect(std.mem.indexOf(u8, said, "new-window -a -n look") != null);
    try std.testing.expect(std.mem.indexOf(u8, said, "meatcheck --diff") != null);
    try std.testing.expect(std.mem.indexOf(u8, said, "abc123^..abc123") != null);
    try std.testing.expect(std.mem.indexOf(u8, said, "is the retry bounded?") != null);
}
test "on Plan's windows z folds the picked one and keeps the pick, Z folds the rest and opens them again, f shows one whole and q closes it, and the folds load from their file's plan: lines" {
    var app: App = .{ .gpa = std.testing.allocator, .io = undefined, .tmux_in = undefined };
    app.term_w = 200;
    app.view_w = 60;
    app.view_h = 30;
    app.roles = @import("parts.zig").roles();
    app.board = try tickets.Board.parse(std.testing.allocator,
        \\{"tickets":[],"plan":{"now":[
        \\{"ticket":1,"repo":"arena","title":"a","state":"building"},
        \\{"ticket":2,"repo":"arena","title":"b","state":"building"}],
        \\"next":[{"ticket":11,"repo":"arena","title":"n","why":"","waits_on":[]}],
        \\"goals":[],"landed_today":{"count":0,"newest":[]},"not_planned":{"count":0,"follow_ups":0,"by_repo":{}}}}
    );
    defer app.board.?.deinit();
    app.home = .{ .focus = .plan };
    const eq = std.testing.expectEqual;
    const view = &app.home.?;
    var sheet: sheets.Sheet = undefined;

    try app.planKey("j");
    try eq(@as(usize, 1), view.plan_pick);
    try app.planKey("z");
    try std.testing.expect(app.plan_shut.contains(.now));
    try std.testing.expect(app.planSheet(&sheet));
    try eq(sheets.Window.now, sheet.picked(view.plan_pick).?.win);
    try eq(sheets.Kind.summary, sheet.picked(view.plan_pick).?.kind);
    try app.planKey("z");
    try std.testing.expect(!app.plan_shut.contains(.now));

    try app.planKey("Z");
    try eq(@as(usize, 6), app.plan_shut.count());
    try std.testing.expect(!app.plan_shut.contains(.now));
    try app.planKey("Z");
    try eq(@as(usize, 0), app.plan_shut.count());

    try app.planKey("f");
    try eq(@as(?sheets.Window, .now), view.whole);
    try app.planKey("j");
    try app.planKey("j");
    try std.testing.expect(app.planSheet(&sheet));
    try eq(sheets.Window.now, sheet.picked(view.plan_pick).?.win);
    try app.planKey("q");
    try eq(@as(?sheets.Window, null), view.whole);

    var fresh: App = .{ .gpa = std.testing.allocator, .io = undefined, .tmux_in = undefined };
    fresh.loadFolds("tlon\nplan:now\nplan:nowhere\nplan:landed\n");
    try std.testing.expect(fresh.folded("tlon") and !fresh.folded("plan:now"));
    try std.testing.expect(fresh.plan_shut.contains(.now) and fresh.plan_shut.contains(.landed) and fresh.plan_shut.count() == 2);
}

test "space opens a Plan ticket row in place, one to a window, with the card's own actions as its buttons; the open row loads from its file's open: line" {
    var app: App = .{ .gpa = std.testing.allocator, .io = undefined, .tmux_in = undefined };
    app.term_w = 200;
    app.view_w = 60;
    app.view_h = 30;
    app.roles = @import("parts.zig").roles();
    app.board = try tickets.Board.parse(std.testing.allocator,
        \\{"tickets":[
        \\{"id":1,"repo":"arena","title":"a","status":"doing"},
        \\{"id":2,"repo":"arena","title":"b","status":"doing"},
        \\{"id":11,"repo":"arena","title":"n","status":"todo"}],"plan":{"now":[
        \\{"ticket":1,"repo":"arena","title":"a","state":"building"},
        \\{"ticket":2,"repo":"arena","title":"b","state":"building"}],
        \\"next":[{"ticket":11,"repo":"arena","title":"n","why":"","waits_on":[]}],
        \\"goals":[],"landed_today":{"count":0,"newest":[]},"not_planned":{"count":0,"follow_ups":0,"by_repo":{}}}}
    );
    defer app.board.?.deinit();
    app.home = .{ .focus = .plan };
    const eq = std.testing.expectEqual;
    var sheet: sheets.Sheet = undefined;

    try eq(@as(u32, 1), app.pickedCard().?.id);
    try app.planKey(" ");
    try eq(@as(u32, 1), app.plan_open.get(.now));
    try std.testing.expect(app.planSheet(&sheet));
    const at = for (sheet.rows[0..sheet.n], 0..) |row, i| {
        if (row.kind == .buttons) break i;
    } else return error.TestUnexpectedResult;
    try eq(@as(u32, 1), sheet.rows[at].ticket.?);
    var buttons: [12]App.PlanButton = undefined;
    var have: [12]App.CardAction = undefined;
    const actions = App.cardActions(app.pickedCard().?, &have);
    const shown = app.planButtons(&sheet, at, &buttons);
    try std.testing.expect(shown.len >= 2);
    for (shown) |button| {
        try std.testing.expect(button.action == .open or std.mem.indexOfScalar(App.CardAction, actions, button.action) != null);
        try eq(shown[0].y, button.y);
    }

    try app.planKey("j");
    try app.planKey(" ");
    try eq(@as(u32, 2), app.plan_open.get(.now));

    app.loadFolds("open:now:7\nopen:nowhere:3\n");
    try eq(@as(u32, 7), app.plan_open.get(.now));
}

test "a session's repo is where its Claudes' panes are, a worktree's included, never its name" {
    const eq = std.testing.expectEqualStrings;
    try eq("babylon", App.pathRepo("/home/a/projects/babylon/.worktrees/t1-x"));
    try eq("arena", App.pathRepo("/home/a/projects/arena"));
    try eq("", App.pathRepo("/home/a/elsewhere"));

    var one: Window = .{ .id = 1, .claude = .working, .info = @constCast("\t\t\t\t\t\t\t/h/projects/babylon/.worktrees/x") };
    var two: Window = .{ .id = 2, .claude = .working, .info = @constCast("\t\t\t\t\t\t\t/h/projects/arena") };
    var three: Window = .{ .id = 3, .claude = .working, .info = @constCast("\t\t\t\t\t\t\t/h/projects/arena/.worktrees/y") };
    var shell: Window = .{ .id = 4, .info = @constCast("\t\t\t\t\t\t\t/h/projects/tlon") };
    var mixed: Session = .{ .id = 2, .name = @constCast("babylon-work") };
    var wins = [_]*Window{ &one, &two, &three, &shell };
    mixed.wins = .fromOwnedSlice(&wins);
    var plain: Session = .{ .id = 3, .name = @constCast("arena") };
    var only = [_]*Window{&one};
    plain.wins = .fromOwnedSlice(&only);
    var sessions = [_]*Session{ &mixed, &plain };
    var app: App = .{ .gpa = std.testing.allocator, .io = undefined, .tmux_in = undefined };
    app.sessions = .fromOwnedSlice(&sessions);
    try eq("arena", app.workspaceRepo(0));
    try eq("babylon", app.workspaceRepo(1));
}

fn chipsPick(app: *App) !usize {
    var sheet: sheets.Sheet = undefined;
    try std.testing.expect(app.planSheet(&sheet));
    for (sheet.rows[0..sheet.n]) |row| if (row.kind == .chips) return row.pick.?;
    return error.NoChips;
}

fn unplannedKinds(app: *App, kind: sheets.Kind) !usize {
    var sheet: sheets.Sheet = undefined;
    try std.testing.expect(app.planSheet(&sheet));
    var n: usize = 0;
    for (sheet.rows[0..sheet.n]) |row| n += @intFromBool(row.kind == kind);
    return n;
}

const not_planned_plan =
    \\{"tickets":[
    \\{"id":1,"repo":"arena","title":"blocked","status":"todo","blocked_by":[9]},
    \\{"id":2,"repo":"arena","title":"free","status":"todo"},
    \\{"id":3,"repo":"tlon","title":"other","status":"todo"}],
    \\"backlog":[{"id":6,"repo":"arena","title":"later","status":"backlog"}],
    \\"plan":{"next":[],"goals":[],"landed_today":{"count":0,"newest":[]},
    \\"not_planned":{"count":3,"follow_ups":0,"by_repo":{"arena":2,"tlon":1}}}}
;

test "on not planned's chips ⏎ folds a repo's rows, h l walk the chips, Z opens only one repo, and the backlog chip shows its cards" {
    var app: App = .{ .gpa = std.testing.allocator, .io = undefined, .tmux_in = undefined };
    app.term_w = 200;
    app.view_w = 60;
    app.view_h = 40;
    app.roles = @import("parts.zig").roles();
    app.board = try tickets.Board.parse(std.testing.allocator, not_planned_plan);
    defer app.board.?.deinit();
    app.home = .{ .focus = .plan };
    const eq = std.testing.expectEqual;
    const view = &app.home.?;
    view.plan_pick = try chipsPick(&app);

    try eq(@as(usize, 3), try unplannedKinds(&app, .todo));
    try app.planKey("\r");
    try std.testing.expect(app.folded("arena"));
    try eq(@as(usize, 1), try unplannedKinds(&app, .todo));
    try app.planKey("l");
    try eq(@as(usize, 1), view.plan_chip);
    try app.planKey("\r");
    try eq(@as(usize, 0), try unplannedKinds(&app, .todo));
    try app.planKey("Z");
    try eq(@as(usize, 0), app.fold_n);
    try app.planKey("Z");
    try std.testing.expect(app.folded("arena") and !app.folded("tlon"));
    try app.planKey("l");
    try app.planKey("\r");
    try std.testing.expect(view.plan_backlog);
    try eq(@as(usize, 1), try unplannedKinds(&app, .backlog));
    try eq(@as(usize, 0), try unplannedKinds(&app, .todo));
}

test "J K on a todo row move it in its repo, W adds it to next, + opens the new ticket window, x on a backlog row asks why, and a todo row dragged onto next joins it there" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const sent = try tmp.dir.createFile(std.testing.io, "tmux", .{ .read = true });
    defer sent.close(std.testing.io);
    var app: App = .{ .gpa = std.testing.allocator, .io = std.testing.io, .tmux_in = sent };
    defer app.pending.deinit(std.testing.allocator);
    app.term_w = 200;
    app.view_w = 60;
    app.view_h = 40;
    app.roles = @import("parts.zig").roles();
    app.board = try tickets.Board.parse(std.testing.allocator, not_planned_plan);
    defer app.board.?.deinit();
    app.home = .{ .focus = .plan };
    const eq = std.testing.expectEqual;
    const view = &app.home.?;
    var got: [2048]u8 = undefined;
    view.plan_pick = (try chipsPick(&app)) + 1;

    try app.planKey("J");
    var len = try sent.readPositionalAll(std.testing.io, &got, 0);
    try std.testing.expect(std.mem.indexOf(u8, got[0..len], "babylon move 2 down --repo arena") != null);
    try eq((try chipsPick(&app)) + 2, view.plan_pick);

    view.plan_pick = (try chipsPick(&app)) + 1;
    try app.planKey("W");
    len = try sent.readPositionalAll(std.testing.io, &got, 0);
    try std.testing.expect(std.mem.indexOf(u8, got[0..len], "babylon next 2 --at 1") != null);

    app.drag = .{ .todo_row = .{ .id = 3, .moved = true } };
    const next = app.planRect(.next);
    try app.dragTo(.{ .code = 0, .x = next.x + 3, .y = next.y + 1, .release = true });
    len = try sent.readPositionalAll(std.testing.io, &got, 0);
    try std.testing.expect(std.mem.indexOf(u8, got[0..len], "'babylon' 'next' '3' '--at' '1'") != null);

    view.plan_pick = try chipsPick(&app);
    try app.planKey("+");
    len = try sent.readPositionalAll(std.testing.io, &got, 0);
    try std.testing.expect(std.mem.indexOf(u8, got[0..len], "babylon new") != null);

    app.home = .{ .focus = .plan, .plan_backlog = true };
    app.home.?.plan_pick = (try chipsPick(&app)) + 1;
    try app.planKey("x");
    try std.testing.expect(app.prompt.?.what == .why);
    try std.testing.expectEqualStrings("close:6", app.prompt.?.item());
    var typed = app.prompt.?;
    @memcpy(typed.buf[0..8], "not need");
    typed.len = 8;
    try app.sendWhy(typed);
    len = try sent.readPositionalAll(std.testing.io, &got, 0);
    try std.testing.expect(std.mem.indexOf(u8, got[0..len], "'babylon' 'update' '6' '--status' 'done' '--why' 'not need'") != null);
    try std.testing.expect(std.mem.indexOf(u8, got[0..len], "not need") != null);
}

test "a click on not planned's + new button opens the new ticket window, and a window too narrow for it has none" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const sent = try tmp.dir.createFile(std.testing.io, "tmux", .{ .read = true });
    defer sent.close(std.testing.io);
    var app: App = .{ .gpa = std.testing.allocator, .io = std.testing.io, .tmux_in = sent };
    defer app.pending.deinit(std.testing.allocator);
    app.term_w = 300;
    app.view_w = 200;
    app.view_h = 40;
    app.roles = @import("parts.zig").roles();
    app.board = try tickets.Board.parse(std.testing.allocator, not_planned_plan);
    defer app.board.?.deinit();
    app.home = .{ .focus = .plan };
    app.side_folded = true;
    const head = app.newHead().?;
    try std.testing.expect(try app.homeMouse(.{ .code = 0, .x = head.x + 1, .y = head.y, .release = false }));
    var got: [1024]u8 = undefined;
    const len = try sent.readPositionalAll(std.testing.io, &got, 0);
    try std.testing.expect(std.mem.indexOf(u8, got[0..len], "babylon new") != null);

    app.term_w = 60;
    app.view_w = 60;
    try std.testing.expect(app.newHead() == null);
}

test "on Plan r narrows every window to one repo and back, / dims what misses the find and the pick skips it, h and l go to the window beside, and arena plan N picks N, opening its window" {
    var app: App = .{ .gpa = std.testing.allocator, .io = undefined, .tmux_in = undefined };
    app.term_w = 200;
    app.view_w = 60;
    app.view_h = 30;
    app.roles = @import("parts.zig").roles();
    app.board = try tickets.Board.parse(std.testing.allocator,
        \\{"tickets":[
        \\{"id":1,"repo":"arena","title":"alpha","status":"doing"},
        \\{"id":2,"repo":"babylon","title":"beta","status":"doing"},
        \\{"id":11,"repo":"arena","title":"gamma","status":"todo"}],"plan":{"now":[
        \\{"ticket":1,"repo":"arena","title":"alpha","state":"building"},
        \\{"ticket":2,"repo":"babylon","title":"beta","state":"building"}],
        \\"next":[{"ticket":11,"repo":"arena","title":"gamma","why":"","waits_on":[]}],
        \\"goals":[{"epic":9,"title":"A goal","total":1,"landed":0,"steps":[{"ticket":1,"state":"building"}]}],
        \\"landed_today":{"count":0,"newest":[]},"not_planned":{"count":0,"follow_ups":0,"by_repo":{}}}}
    );
    defer app.board.?.deinit();
    app.home = .{ .focus = .plan };
    const eq = std.testing.expectEqual;
    const view = &app.home.?;
    var sheet: sheets.Sheet = undefined;

    try app.planKey("r");
    try eq(@as(usize, 1), view.plan_repo);
    try std.testing.expect(app.planSheet(&sheet));
    for (sheet.rows[0..sheet.n]) |row| try std.testing.expect(row.ticket != 2);
    try app.planKey("r");
    try app.planKey("r");
    try eq(@as(usize, 0), view.plan_repo);

    @memcpy(app.find[0..4], "beta");
    app.find_len = 4;
    app.refind();
    try app.planKey("j");
    try std.testing.expect(app.planSheet(&sheet));
    try eq(@as(u32, 2), sheet.picked(view.plan_pick).?.ticket.?);
    try app.planKey("\x1b");
    try eq(@as(usize, 0), app.find_len);

    view.plan_pick = (sheet.pickRange(.now) orelse return error.NoNow).first;
    try app.planKey("l");
    try std.testing.expect(app.planSheet(&sheet));
    try eq(sheets.Window.goals, sheet.picked(view.plan_pick).?.win);
    try app.planKey("h");
    try std.testing.expect(app.planSheet(&sheet));
    try eq(sheets.Window.now, sheet.picked(view.plan_pick).?.win);

    app.plan_shut.insert(.next);
    try std.testing.expect(try app.pickPlanTicket(11));
    try std.testing.expect(!app.plan_shut.contains(.next));
    try std.testing.expect(app.planSheet(&sheet));
    try eq(@as(u32, 11), sheet.picked(view.plan_pick).?.ticket.?);
}

test "only a Claude come to wait or stall is a notice" {
    try std.testing.expect(!App.notifies(.working, .done));
    try std.testing.expect(!App.notifies(.done, .working));
    try std.testing.expect(!App.notifies(.working, .background));
    try std.testing.expect(App.notifies(.working, .waiting));
    try std.testing.expect(App.notifies(.done, .stalled));
    try std.testing.expect(!App.notifies(.waiting, .waiting));
}

test "⏎ on a subagent row in a card's modal shows that subagent, as a click on its row did" {
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
        \\{"tickets":[{"id":4,"repo":"tlon","title":"d","status":"doing","claimed_by":"%12"}]}
    );
    defer app.board.?.deinit();
    const pane = try Pane.create(&app, 12, 80, 24);
    defer pane.destroy(std.testing.allocator);
    var win: Window = .{ .id = 7, .name = @constCast("w"), .claude = .working, .agent_pane = 12, .info = @constCast("\t\t\t\t\t\tlint run\x1fcheck deps") };
    defer win.panes.deinit(std.testing.allocator);
    try win.panes.append(std.testing.allocator, pane);
    var s: Session = .{ .id = 1, .name = @constCast("s") };
    var wins = [_]*Window{&win};
    s.wins = .fromOwnedSlice(&wins);
    var sessions = [_]*Session{&s};
    app.sessions = .fromOwnedSlice(&sessions);
    app.current = 1;
    app.home = .{ .detail = 4 };

    var buttons: [16]App.ModalButton = undefined;
    var rows: [2]u16 = undefined;
    var seen: usize = 0;
    for (app.modalButtons(&buttons)) |b| if (b.action == .sub) {
        rows[seen] = b.y;
        seen += 1;
    };
    try std.testing.expectEqual(@as(usize, 2), seen);
    try std.testing.expectEqual(rows[0] + 1, rows[1]);

    try app.modalKey("\t");
    try app.modalKey("\t");
    try app.modalKey("\r");
    try std.testing.expect(app.home == null);
    try std.testing.expectEqual(@as(u32, 12), app.pick.?.pane);
    try std.testing.expectEqualStrings("check deps", app.pick.?.name[0..app.pick.?.len]);
}

fn needsBoard(buf: []u8, n: usize) ![]const u8 {
    var w: Writer = .fixed(buf);
    try w.writeAll("{\"tickets\":[],\"needs_you\":[");
    for (0..n) |i| try w.print("{s}{{\"id\":\"ask:{d}\",\"kind\":\"ask\",\"ticket\":{d},\"repo\":\"arena\",\"text\":\"item {d}\",\"actions\":[{{\"key\":\"y\",\"label\":\"yes\",\"argv\":[\"true\"]}}]}}", .{ if (i > 0) "," else "", i, 100 + i, i });
    try w.writeAll("],\"plan\":{\"now\":[],\"next\":[],\"goals\":[],\"landed_today\":{\"count\":0,\"newest\":[]},\"not_planned\":{\"count\":0,\"follow_ups\":0,\"by_repo\":{}}}}");
    return w.buffered();
}

test "Your move is a fixed slot whatever it holds, the picked item opens to its card and closes the last, and ] goes to its first item" {
    const eq = std.testing.expectEqual;
    var height: ?u16 = null;
    for ([_]usize{ 0, 3, 8 }) |n| {
        var buf: [4096]u8 = undefined;
        var app: App = .{ .gpa = std.testing.allocator, .io = undefined, .tmux_in = undefined };
        app.term_w = 200;
        app.view_w = 60;
        app.view_h = 40;
        app.roles = @import("parts.zig").roles();
        app.board = try tickets.Board.parse(std.testing.allocator, try needsBoard(&buf, n));
        defer app.board.?.deinit();
        app.home = .{ .focus = .plan };
        const rect = app.planSlot(.move);
        if (height) |h| try eq(h, rect.h) else height = rect.h;
        try eq(@as(u16, sheets.move_rows_full + sheets.window_chrome), rect.h);
        if (n == 0) continue;

        app.home.?.plan_pick = 5 % n;
        try app.planKey("]");
        try eq(@as(usize, 0), app.home.?.plan_pick);
        try app.planKey(" ");
        try eq(@as(u32, 100), app.plan_open.get(.move));
        try app.planKey("j");
        try app.planKey(" ");
        try eq(@as(u32, 101), app.plan_open.get(.move));
        var sheet: sheets.Sheet = undefined;
        try std.testing.expect(app.planSheet(&sheet));
        var cards: usize = 0;
        for (sheet.rows[0..sheet.n]) |row| cards += @intFromBool(row.kind == .need_card);
        try eq(@as(usize, 2), cards);
        try eq(@as(usize, n), sheet.pickRange(.move).?.n);
    }
}

test "⏎ on a Claude with no ticket in in flight's foot shows its window, space opens its popup, and its peek is its window" {
    var board = try tickets.Board.parse(std.testing.allocator,
        \\{"tickets":[],"plan":{"now":[],"next":[],"goals":[],
        \\"landed_today":{"count":0,"newest":[]},"not_planned":{"count":0,"follow_ups":0,"by_repo":{}}}}
    );
    defer board.deinit();
    var calm: Window = .{ .id = 1, .index = 1, .name = @constCast("a"), .claude = .working, .since = 1, .info = @constCast("\t\tindexing\t\t\t\t\t/h/projects/arena") };
    var asks: Window = .{ .id = 2, .index = 2, .name = @constCast("b"), .claude = .waiting, .since = 1, .info = @constCast("\t\tasks\t\t\t\t\t/h/projects/babylon") };
    var wins = [_]*Window{ &calm, &asks };
    var session: Session = .{ .id = 3, .name = @constCast("menard") };
    session.wins = .fromOwnedSlice(&wins);
    var sessions = [_]*Session{&session};
    var devnull = try std.Io.Dir.openFileAbsolute(std.testing.io, "/dev/null", .{ .mode = .write_only });
    defer devnull.close(std.testing.io);
    var app: App = .{ .gpa = std.testing.allocator, .io = std.testing.io, .tmux_in = devnull, .board = board, .current = 3 };
    defer app.pending.deinit(app.gpa);
    const pane = try Pane.create(&app, 7, 20, 5);
    defer pane.destroy(app.gpa);
    var panes = [_]*Pane{pane};
    asks.panes = .fromOwnedSlice(&panes);
    asks.agent_pane = 7;
    app.sessions = .fromOwnedSlice(&sessions);
    app.term_w = 200;
    app.view_w = 60;
    app.view_h = 30;
    app.roles = @import("parts.zig").roles();
    app.home = .{ .focus = .plan };
    const eq = std.testing.expectEqual;

    var sheet: sheets.Sheet = undefined;
    try std.testing.expect(app.planSheet(&sheet));
    const first = for (sheet.rows[0..sheet.n]) |row| {
        if (row.kind == .other) break row;
    } else return error.TestExpectedEqual;
    try eq(@as(usize, 0), first.item);
    try eq(sheets.Window.now, first.win);
    try std.testing.expect(app.otherAt(0).?.win == &asks);
    app.home.?.plan_pick = first.pick.?;
    try std.testing.expect(app.peekOf(.{ .window = 2 }).?.win == &asks);

    try app.planKey(" ");
    try eq(@as(?HomeView, null), app.home);
    try std.testing.expect(app.popup != null and app.popup.?.entry == 2);
    app.closePopup();

    app.home = .{ .focus = .plan, .plan_pick = first.pick.? };
    try app.planKey("\r");
    try eq(@as(?HomeView, null), app.home);
    try std.testing.expect(app.popup == null);
    try eq(@as(usize, 1), session.focus);
}

test "a Claude waiting in its pane is a Your move item after babylon's, ⏎ shows its pane, and it goes when the pane stops waiting" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const sent = try tmp.dir.createFile(std.testing.io, "tmux", .{ .read = true });
    defer sent.close(std.testing.io);
    const gpa = std.testing.allocator;
    var app: App = .{ .gpa = gpa, .io = std.testing.io, .tmux_in = sent };
    defer app.pending.deinit(gpa);
    app.board = try tickets.Board.parse(gpa,
        \\{"tickets":[{"id":7,"repo":"arena","title":"a","status":"doing"}],"needs_you":[{"id":"ask:9","kind":"ask","ticket":4,"repo":"tlon","text":"t","actions":[]}]}
    );
    defer app.board.?.deinit();
    var info = "wants to run: ls\t\t\t\tt7-x".*;
    var win: Window = .{ .id = 3, .name = @constCast("w"), .claude = .waiting, .agent_pane = 5, .info = &info };
    var bare: Window = .{ .id = 4, .name = @constCast("v"), .index = 2, .claude = .waiting, .info = @constCast("") };
    const pane = try Pane.create(&app, 5, 10, 5);
    defer pane.destroy(gpa);
    try win.panes.append(gpa, pane);
    defer win.panes.deinit(gpa);
    var slots = [_]*Window{ &win, &bare };
    var s: Session = .{ .id = 1, .name = @constCast("arena"), .wins = .fromOwnedSlice(&slots) };
    var list = [_]*Session{&s};
    app.sessions = .fromOwnedSlice(&list);
    app.current = 1;

    try app.syncWaiting();
    const needs = app.board.?.needsYou();
    try std.testing.expectEqual(@as(usize, 3), needs.len);
    try std.testing.expectEqualStrings("ask:9", needs[0].id);
    try std.testing.expectEqualStrings("waits in its pane: wants to run: ls", needs[1].text);
    try std.testing.expectEqual(@as(?u32, 7), needs[1].ticket);
    try std.testing.expectEqualStrings("arena", needs[1].repo);
    try std.testing.expectEqualStrings("arena:2 waits in its pane", needs[2].text);

    try std.testing.expect(try win_feed.act(&app, .{ .line = 0, .ticket = 7, .need = 1 }, "\r"));
    var got: [128]u8 = undefined;
    const len = try sent.readPositionalAll(std.testing.io, &got, 0);
    try std.testing.expect(std.mem.indexOf(u8, got[0..len], "select-pane -t %5") != null);

    win.claude = .working;
    try app.syncWaiting();
    try std.testing.expectEqual(@as(usize, 2), app.board.?.needsYou().len);
    bare.claude = .done;
    try app.syncWaiting();
    try std.testing.expectEqual(@as(usize, 1), app.board.?.needsYou().len);
}

test "arena plan N opens the shut repo chip that holds N" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const sent = try tmp.dir.createFile(std.testing.io, "tmux", .{ .read = true });
    defer sent.close(std.testing.io);
    var app: App = .{ .gpa = std.testing.allocator, .io = std.testing.io, .tmux_in = sent };
    defer app.pending.deinit(std.testing.allocator);
    app.term_w = 300;
    app.view_w = 200;
    app.view_h = 40;
    app.roles = @import("parts.zig").roles();
    app.board = try tickets.Board.parse(std.testing.allocator,
        \\{"tickets":[{"id":5,"repo":"tlon","title":"Lights","status":"todo","priority":"med","blocked_by":[]},
        \\{"id":6,"repo":"arena","title":"Keys","status":"todo","priority":"med","blocked_by":[]}],
        \\"plan":{"now":[],"next":[],"goals":[],"landed_today":{"count":0,"newest":[]},
        \\"not_planned":{"count":2,"follow_ups":0,"by_repo":{"tlon":1,"arena":1}}}}
    );
    defer app.board.?.deinit();
    app.home = .{ .focus = .plan };
    var sheet: sheets.Sheet = undefined;
    app.setFold("tlon", true);
    app.plan_shut.insert(.unplanned);
    try app.showPlan(5);
    try std.testing.expect(!app.folded("tlon"));
    try std.testing.expect(!app.plan_shut.contains(.unplanned));
    try std.testing.expect(app.planSheet(&sheet));
    try std.testing.expectEqual(@as(u32, 5), sheet.picked(app.home.?.plan_pick).?.ticket.?);
}
