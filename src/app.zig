const std = @import("std");
const vt = @import("ghostty-vt");
const control = @import("control.zig");
const layout = @import("layout.zig");
const keys = @import("keys.zig");
const menu = @import("menu.zig");
const color = @import("color.zig");
const Theme = @import("theme.zig").Theme;
const Pass = @import("pass.zig").Pass;
const tickets = @import("board.zig");
const feed = @import("feed.zig");
const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;

pub const rail_button = "≡ menu";
pub const rail_new = "+ new";
const history_lines = 5000;
const rail_wide = 36;
const rail_narrow = 10;
/// How long the pointer rests on the narrow rail before it is drawn wide over the strip.
const dwell_ms = 300;
const quiet_s = 600;
const stir_s = 60;
/// How long arena keeps trying to have a Claude show a subagent, how long it leaves a key to be
/// drawn before it reads the screen again, and how many Downs it sends to reach the list.
const pick_ms = 3000;
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
    "#{{?#{{==:#{{@arena_claude}},done}},3,#{{?#{{==:#{{@arena_claude}},waiting}},4,0}}}}}}}}";
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
/// running in the background, working, done and not yet looked at, or waiting on an answer. In
/// rising order of how much it wants looking at.
pub const Mark = enum { none, background, working, done, waiting };
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
            .background, .done, .none => win.text(.said),
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
    /// The column and the card in it picked, and in the every view the lane it is in.
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
    /// The board's keys shown over it, until the next key.
    help: bool = false,
    /// Opened as home: the orchestrator's column beside it while the orchestrator is not running.
    home: bool = false,
    /// The feed's pick, by its place: Your move's items, then next's and auto's line, then
    /// landing's tickets, then building's.
    pick: usize = 0,
    /// The repo of auto's line that is lit, by its place among its caps.
    auto_repo: usize = 0,

    /// Whether a box lies over the board, the keys its own.
    pub fn boxed(view: BoardView) bool {
        return view.help or view.detail != null or view.answering or view.giving != null;
    }
};

/// The cards a column of the board can hold, and the repos it can be narrowed to.
pub const max_cards = 256;
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
    agent_sort: AgentSort = .urgency,
    /// The rail's list of Claudes was scrolled to start at the `n`th, beside the window `at` that
    /// was in view then; going to another puts it back to following the Claude in view.
    agent_skip: ?struct { n: usize, at: ?*const Window } = null,
    /// The repos whose pipeline folds are open, as hashes; 0 for a free place.
    pipeline_open: [8]u64 = @splat(0),
    /// When the pointer came to rest on the narrow rail; 0 while it is elsewhere.
    hover_at: i64 = 0,
    /// Set when the session's current window changed in tmux, so focus goes to it when listed.
    follow_active: bool = false,
    palette: color.Palette = .{},
    theme: ?Theme = null,
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
    /// tmux ended the client, as it does when the session it was on ends.
    ended: bool = false,
    /// Milliseconds on a clock that only goes forward, set each turn of the loop.
    now: i64 = 0,
    /// Seconds since the epoch, set each turn of the loop.
    epoch: i64 = 0,
    /// Seconds the local clock is ahead of UTC, for where today began.
    utc_offset: i64 = 0,
    /// babylon's refusals of what the feed ran for its items, said in their place.
    refusals: std.ArrayList(feed.Refusal) = .empty,
    /// babylon's refusal of the board's start, drawn on the card's action row until the next key.
    start_refused: ?[]u8 = null,
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
    } = .none,
    /// The session the open menu asks about closing.
    doomed: u32 = 0,
    /// The pointer's shape, and whether the next frame is to tell the terminal of it.
    shape: []const u8 = "default",
    shape_due: bool = false,
    /// Where the mouse last was.
    pointer: struct { x: u16 = 0, y: u16 = 0 } = .{},
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
        if (app.start_refused) |text| app.gpa.free(text);
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

    fn paneById(app: *App, id: u32) ?*Pane {
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
        const card = app.ticketCard(id);
        return .{ .repo = if (card) |c| c.repo orelse "" else "", .id = id };
    }

    fn ticketCard(app: *const App, id: u32) ?*const tickets.Card {
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
    pub const Fold = struct { repo: []const u8, count: usize, open: bool };
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
        for ([_][]const u8{ "queued", "verifying", "reviewing", "landing" }) |waiting| {
            if (std.mem.eql(u8, stage, waiting)) return true;
        }
        return false;
    }

    fn repoHash(repo: []const u8) u64 {
        return std.hash.Wyhash.hash(0, repo) | 1;
    }

    fn foldOpen(app: *const App, repo: []const u8) bool {
        return std.mem.indexOfScalar(u64, &app.pipeline_open, repoHash(repo)) != null;
    }

    fn toggleFold(app: *App, repo: []const u8) void {
        const hash = repoHash(repo);
        if (std.mem.indexOfScalar(u64, &app.pipeline_open, hash)) |at| {
            app.pipeline_open[at] = 0;
        } else if (std.mem.indexOfScalar(u64, &app.pipeline_open, 0)) |free| {
            app.pipeline_open[free] = hash;
        }
        app.dirty = true;
    }

    /// The rail's Claudes: those whose tickets have landed or closed are left out, and those only
    /// waiting in the pipeline are folded a row to a repo, in order of name, unless the repo is
    /// open. The Claude in view stays, whatever its ticket. Returns how many Claudes and folds.
    fn railList(app: *const App, out: []Agent, folds: []Fold) struct { usize, usize } {
        var all: [64]Agent = undefined;
        const total = app.agents(&all);
        var n: usize = 0;
        var nf: usize = 0;
        for (all[0..total]) |a| {
            const card = if (app.agentSelected(a)) null else if (std.fmt.parseInt(u32, branchTicket(a.win.text(.branch)) orelse "", 10)) |id| app.ticketCard(id) else |_| null;
            if (card) |c| {
                if (c.status == .done) continue;
                if (inPipeline(c)) {
                    const repo = c.repo orelse "";
                    const at = for (folds[0..nf], 0..) |f, i| {
                        if (std.mem.eql(u8, f.repo, repo)) break i;
                    } else if (nf < folds.len) blk: {
                        folds[nf] = .{ .repo = repo, .count = 0, .open = app.foldOpen(repo) };
                        nf += 1;
                        break :blk nf - 1;
                    } else null;
                    if (at) |i| folds[i].count += 1;
                    if (!(at != null and folds[at.?].open)) continue;
                }
            }
            out[n] = a;
            n += 1;
        }
        std.mem.sort(Fold, folds[0..nf], {}, struct {
            fn before(_: void, a: Fold, b: Fold) bool {
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

    fn agentLinesFrom(out: []AgentLine, room: usize, details: bool, found: []const Agent, folds: []const Fold) usize {
        const count = found.len;
        const rows = @min(out.len, room);
        if (rows == 0) return 0;
        var n: usize = 0;
        var last: ?usize = null;
        for (found[0..count]) |a| {
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
        var shown: usize = 0;
        for (out[0..n]) |line| shown += @intFromBool(line == .agent);
        // the folds come after the Claudes, once all of them have been listed
        if (shown == count) for (folds) |fold| {
            if (n == rows) break;
            out[n] = .{ .pipeline = fold };
            n += 1;
            shown += 1;
        };
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
            .pipeline => |fold| app.toggleFold(fold.repo),
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
        var n: usize = 0;
        for (app.sessions.items, 0..) |s, si| for (s.wins.items) |win| {
            if ((win.claude != .waiting and win.claude != .done) or n == found.len) continue;
            found[n] = .{ .session = si, .win = win };
            n += 1;
        };
        if (n == 0) return;
        std.sort.insertion(Agent, found[0..n], {}, struct {
            fn before(_: void, a: Agent, b: Agent) bool {
                return urgency(a.win) > urgency(b.win);
            }
        }.before);
        const s = app.cur();
        const here = for (found[0..n], 0..) |a, i| {
            if (s != null and app.sessions.items[a.session] == s.? and s.?.focused() == a.win) break i;
        } else null;
        const len: i32 = @intCast(n);
        const to: i32 = if (here) |i| @mod(@as(i32, @intCast(i)) + by, len) else if (by > 0) 0 else len - 1;
        try app.goAgent(found[@intCast(to)]);
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

    /// A Claude done in the window in view has been looked at: its pane's state is cleared in
    /// tmux, unless a hook has moved it on since.
    fn see(app: *App) !void {
        const s = app.cur() orelse return;
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

    /// The rail's width as drawn, which a narrow one peeking is not.
    pub fn railDrawnW(app: *const App) u16 {
        return if (app.peek and app.railW() > 0) app.railWideW() else app.railW();
    }

    /// The strip's width, or with the orchestrator beside the board, its window's.
    pub fn fit(app: *App) void {
        const full = app.fullW();
        app.view_w = if (app.sided()) @min(side_w, full * 2 / 5) else full;
    }

    /// Whether the orchestrator's column is beside the open board, unless folded: while the
    /// orchestrator runs, with its window, and at home always, with what babylon says of it.
    pub fn sided(app: *const App) bool {
        const view = app.board_view orelse return false;
        return !app.side_folded and (view.home or app.orchestratorSession() != null);
    }

    /// Whether the column has the keys: its window's once arena is in its session, else its own.
    pub fn columnFocused(app: *const App) bool {
        const view = app.board_view orelse return false;
        return view.focus == .orchestrator and !view.boxed() and app.sided();
    }

    pub const OrchestratorState = enum { working, waiting, idle, restarting, off };

    /// The orchestrator as its column's head says it: its window's Claude while its session is
    /// there, else restarting while babylon keeps it on, else off.
    pub fn orchestratorState(app: *const App) OrchestratorState {
        if (app.orchestratorWindow()) |win| return switch (win.claude) {
            .working => .working,
            .waiting => .waiting,
            else => .idle,
        };
        const state = app.orchestrator() orelse return .off;
        return if (state.on) .restarting else .off;
    }

    /// The feed atop the orchestrator's column, from babylon's board: none without one.
    pub fn feedOf(app: *const App, f: *feed.Feed) bool {
        const b = if (app.board) |*b| b else return false;
        const today = app.epoch - @mod(app.epoch + app.utc_offset, 86400);
        feed.build(f, b, app.refusals.items, app.view_w -| 4, (app.view_h -| 2) / 2, app.epoch, today, if (app.board_view) |view| view.auto_repo else 0);
        return true;
    }

    /// Whether the feed has the keys: the column has them, in normal mode while its window is in it.
    pub fn feedFocused(app: *const App) bool {
        return app.columnFocused() and (app.normal or !app.sideShown());
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
        if (anyKey(key, &.{ "j", "\x1b[B", "\x1bOB" })) {
            view.pick = @min(view.pick + 1, n - 1);
        } else if (anyKey(key, &.{ "k", "\x1b[A", "\x1bOA" })) {
            view.pick -|= 1;
        } else if (anyKey(key, &.{"]"})) {
            if (moves > 0) view.pick = if (view.pick + 1 < moves) view.pick + 1 else 0;
        } else if (anyKey(key, &.{"["})) {
            if (moves > 0) view.pick = if (view.pick > 0 and view.pick <= moves) view.pick - 1 else moves - 1;
        } else return app.feedAct(f.item(view.pick).?, key);
        app.dirty = true;
        if (view.pick != was) if (f.item(view.pick).?.ticket) |id| {
            _ = app.pickCard(id);
        };
        return true;
    }

    fn feedAct(app: *App, item: feed.Item, key: []const u8) !bool {
        const b = if (app.board) |*b| b else return false;
        const named: []const u8 = if (std.mem.eql(u8, key, "\r")) "⏎" else key;
        if (item.auto) return app.autoKey(item, key);
        if (item.next) |at| return app.nextKey(at, key);
        const at = item.need orelse {
            if (!std.mem.eql(u8, named, "⏎")) return false;
            const id = item.ticket orelse return true;
            for (b.cards()) |card| if (card.id == id) if (card.holder()) |pane| try app.showPane(pane);
            return true;
        };
        const need = b.needsYou()[at];
        if (tickets.lookDoc(need) != null and anyKey(key, &.{ "o", "\r" })) return app.openDoc(need);
        const action = for (need.actions) |action| {
            if (std.mem.eql(u8, action.key, named)) break action;
        } else return false;
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

    /// The doc of a look at, opened: a link by `xdg-open`, a file of the ticket's repo in a
    /// window of its own, in `glow` else `less`.
    fn openDoc(app: *App, need: tickets.Need) !bool {
        const doc = tickets.lookDoc(need) orelse return true;
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

    /// A key on auto's line: `a` turns auto on or off, `H` hold, the arrows pick a repo of its
    /// caps and `+` `-` raise or lower the one picked, 0 pausing it. Each runs babylon as the
    /// human, and the line is drawn again from the board once babylon has written it.
    fn autoKey(app: *App, item: feed.Item, key: []const u8) !bool {
        const b = if (app.board) |*b| b else return false;
        const view = &app.board_view.?;
        const state = b.autoState() orelse return false;
        if (anyKey(key, &.{ "\x1b[C", "\x1bOC" })) {
            view.auto_repo = item.repo + 1;
        } else if (anyKey(key, &.{ "\x1b[D", "\x1bOD" })) {
            view.auto_repo = item.repo -| 1;
        } else if (anyKey(key, &.{"a"})) {
            return app.runNeed("auto", &.{ "babylon", "auto", if (state.on) "off" else "on" });
        } else if (anyKey(key, &.{"H"})) {
            return app.runNeed("auto", &.{ "babylon", "hold", if (b.hold()) "off" else "on" });
        } else if (anyKey(key, &.{ "+", "=", "-" })) {
            const caps = state.repo_caps.map;
            if (item.repo >= caps.count()) return true;
            const cap = caps.values()[item.repo];
            if (anyKey(key, &.{"-"}) and cap == 0) return true;
            var arg: [96]u8 = undefined;
            const set = std.fmt.bufPrint(&arg, "{s}={d}", .{ caps.keys()[item.repo], if (anyKey(key, &.{"-"})) cap - 1 else cap + 1 }) catch return true;
            return app.runNeed("auto", &.{ "babylon", "auto", "--repo-cap", set });
        } else return false;
        app.dirty = true;
        return true;
    }

    /// A key on a ticket of next, the `at`th: `J` and `K` move it down and up, `x` drops it from
    /// next and `p` pins it where it is. Each goes through babylon as the human, which marks the
    /// ticket as the human's, so the orchestrator moves it only with a proposal.
    fn nextKey(app: *App, at: usize, key: []const u8) !bool {
        const b = if (app.board) |*b| b else return false;
        const plan = b.next();
        if (at >= plan.len) return false;
        var id: [12]u8 = undefined;
        var place: [12]u8 = undefined;
        const ticket = std.fmt.bufPrint(&id, "{d}", .{plan[at].ticket}) catch return true;
        const view = &app.board_view.?;
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
        view.pick = if (down) view.pick + 1 else view.pick - 1;
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
        // a refusal under auto's line or a next row stays only until the next key of either
        if (std.mem.eql(u8, id, "auto") or std.mem.startsWith(u8, id, "next:")) {
            var i: usize = app.refusals.items.len;
            while (i > 0) {
                i -= 1;
                const r = app.refusals.items[i];
                if (!std.mem.eql(u8, r.id, "auto") and !std.mem.startsWith(u8, r.id, "next:")) continue;
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
        if (report) {
            try cmd.writer.writeAll(" && printf ok >");
            try shellQuote(&cmd.writer, path);
        }
        try cmd.writer.writeAll(" || printf '%s\\n' \"$out\" >");
        try shellQuote(&cmd.writer, path);
        // tmux reads the line as a format, in double quotes: # is ##, and \, " and $ escaped
        var line: Writer.Allocating = .init(app.gpa);
        defer line.deinit();
        for (cmd.written()) |c| switch (c) {
            '#' => try line.writer.writeAll("##"),
            '\\', '"', '$' => try line.writer.print("\\{c}", .{c}),
            else => try line.writer.writeByte(c),
        };
        try app.send(.ignore, "run-shell -b \"{s}\"", .{line.written()});
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
        app.clearStartRefusal();
        app.start_refused = try clean.toOwnedSlice(app.gpa);
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
        return if (app.feedOf(&f)) @intCast(1 + f.count() + 1) else 1;
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
                const said: Mark = @fromBackingInt(@intCast(@min(n[11], @backingInt(Mark.waiting))));
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
        try app.see();
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
            if (win.claude == was or (win.claude != .waiting and win.claude != .done)) continue;
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
        try app.see();
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
        try app.see();
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
        if (app.cur()) |s| if (s.focused()) |win| if (win.activePane()) |pane| {
            pane.term.screens.active.clearSelection();
        };
        app.prompt = .{ .what = .search };
        app.dirty = true;
    }

    /// Finds the prompt's text in the active pane's history, the match before the one last
    /// found, selects it and brings it into view. Past the oldest it starts again from the newest.
    fn searchNext(app: *App) !void {
        const prompt = &app.prompt.?;
        const s = app.cur() orelse return;
        const win = s.focused() orelse return;
        const pane = win.activePane() orelse return;
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
        var buf: [std.fs.max_path_bytes]u8 = undefined;
        const path = app.detailPath(id, &buf) orelse return false;
        const view = &app.board_view.?;
        // tmux gives a control client run-shell's output outside its reply, so it comes by a file
        std.Io.Dir.cwd().deleteFile(app.io, path) catch {};
        if (app.detail_asked.items.len == 16) _ = app.detail_asked.orderedRemove(0);
        try app.detail_asked.append(app.gpa, id);
        view.detail = id;
        view.detail_scroll = 0;
        app.detail.clearRetainingCapacity();
        try app.send(.ignore, "run-shell -b \"babylon detail {d} >'{s}.part' 2>&1; mv '{s}.part' '{s}'\"", .{ id, path, path, path });
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
        var lines = DetailLines.init(if (app.detail.items.len > 0) app.detail.items else "…", detailWidth(app.boardW()).inner);
        var n: usize = 0;
        while (lines.next()) |_| n += 1;
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
        if (app.boardBacklog()) {
            for (b.backlog(), 0..) |*card, i| if (i < out.len) {
                out[i] = card;
            };
            return b.backlog().len;
        }
        return shownOf(tickets.statuses[col], b.column(tickets.statuses[col], app.pickRepo(), out));
    }

    /// The count of every card in the board's column `col` as it is narrowed, shown or not.
    pub fn boardColumnAll(app: *const App, col: usize) usize {
        const b = if (app.board) |*b| b else return 0;
        if (app.boardBacklog()) return b.backlog().len;
        return b.column(tickets.statuses[col], app.pickRepo(), &.{});
    }

    /// Done shows its last few closed, the first in its column, and then how many more it has.
    pub const done_shown = 3;

    /// Of `total` cards in `status`'s column, how many are shown.
    pub fn shownOf(status: tickets.Status, total: usize) usize {
        return if (status == .done) @min(total, done_shown) else total;
    }

    /// The cards in column `col` of lane `lane`: those shown, and all of them.
    pub fn laneCounts(app: *const App, lane: usize, col: usize) struct { shown: usize, total: usize } {
        const b = if (app.board) |*b| b else return .{ .shown = 0, .total = 0 };
        const repo = app.laneRepo(lane) orelse return .{ .shown = 0, .total = 0 };
        const total = b.column(tickets.statuses[col], repo, &.{});
        return .{ .shown = shownOf(tickets.statuses[col], total), .total = total };
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
        var all: [max_repos][]const u8 = undefined;
        var n: usize = 0;
        for (all[0..b.repos(&all)]) |repo| if (app.live(repo)) {
            out[n] = repo;
            n += 1;
        };
        for (b.cards()) |card| if (card.repo == null and card.status != .done) {
            out[n] = "";
            n += 1;
            break;
        };
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
        return b.column(.todo, repo, &.{}) + b.column(.doing, repo, &.{}) + b.column(.review, repo, &.{});
    }

    /// Whether `repo` has a card to do, doing or in review.
    pub fn live(app: *const App, repo: []const u8) bool {
        const b = if (app.board) |*b| b else return false;
        return b.column(.todo, repo, &.{}) + b.column(.doing, repo, &.{}) + b.column(.review, repo, &.{}) > 0;
    }

    pub fn laneRepo(app: *const App, lane: usize) ?[]const u8 {
        var repos: [max_repos + 1][]const u8 = undefined;
        const n = app.laneRepos(&repos);
        return if (lane < n) repos[lane] else null;
    }

    /// The rows lane `repo` takes: a card's for each card its longest column shows, with a row for
    /// how many more it has, one at least.
    pub fn laneRows(app: *const App, repo: []const u8) usize {
        const b = if (app.board) |*b| b else return 1;
        var most: usize = 1;
        for (tickets.statuses) |status| {
            const total = b.column(status, repo, &.{});
            const shown = shownOf(status, total);
            const each: usize = if (status == .done) 1 else card_rows;
            most = @max(most, shown * each + @intFromBool(total > shown));
        }
        return most;
    }

    /// The line of the lanes lane `lane` starts on.
    pub fn laneStart(app: *const App, lane: usize) usize {
        var heights: [max_repos + 1]usize = undefined;
        const n = app.laneHeights(&heights);
        var start: usize = 0;
        for (heights[0..@min(lane, n)]) |rows| start += rows + 1;
        return start;
    }

    /// The rows each lane is given: those it needs, and the lines under the last shared among
    /// them as they need, so the lanes reach the board's foot.
    pub fn laneHeights(app: *const App, out: *[max_repos + 1]usize) usize {
        var repos: [max_repos + 1][]const u8 = undefined;
        const n = app.laneRepos(&repos);
        if (n == 0) return 0;
        var rows: usize = 0;
        for (repos[0..n], 0..) |repo, k| {
            out[k] = app.laneRows(repo);
            rows += out[k];
        }
        const need = rows + n - 1;
        const room = app.view_h -| 3;
        if (need >= room) return n;
        const extra = room - need;
        var given: usize = 0;
        for (out[0..n]) |*h| {
            const more = extra * h.* / rows;
            h.* += more;
            given += more;
        }
        out[n - 1] += extra - given;
        return n;
    }

    /// A line of the every view's lanes, counted from the first: lane `lane`'s row `row`, or the
    /// rule under it, which the last has none of.
    pub const LaneLine = struct { lane: usize, row: usize, rule: bool };

    pub fn laneLineAt(app: *const App, line: usize) ?LaneLine {
        var heights: [max_repos + 1]usize = undefined;
        const n = app.laneHeights(&heights);
        var start: usize = 0;
        for (heights[0..n], 0..) |rows, k| {
            if (line < start + rows) return .{ .lane = k, .row = line - start, .rule = false };
            if (line == start + rows and k + 1 < n) return .{ .lane = k, .row = rows, .rule = true };
            start += rows + 1;
        }
        return null;
    }

    /// The line of the lanes on the board's first row inside its border: scrolled to keep the
    /// picked card in view, down to its bottom edge.
    pub fn laneScroll(app: *const App) usize {
        const view = app.board_view orelse return 0;
        const each = app.cardRows(view.col);
        const pick = app.laneStart(view.lane) + view.row * each + each - 1;
        const shown = app.view_h -| 3;
        return if (pick >= shown) pick - shown + 1 else 0;
    }

    /// Card `row` of column `col` in lane `lane`.
    pub fn laneCard(app: *const App, lane: usize, col: usize, row: usize) ?*const tickets.Card {
        const b = if (app.board) |*b| b else return null;
        const repo = app.laneRepo(lane) orelse return null;
        var out: [max_cards]*const tickets.Card = undefined;
        const n = shownOf(tickets.statuses[col], b.column(tickets.statuses[col], repo, &out));
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

    fn boardBacklog(app: *const App) bool {
        const view = app.board_view orelse return false;
        return view.backlog;
    }

    /// The columns the open board shows: the four statuses, or the backlog alone.
    pub fn boardCols(app: *const App) usize {
        return if (app.boardBacklog()) 1 else tickets.statuses.len;
    }

    /// The cards in `status` on the whole board, whatever it is narrowed to.
    pub fn boardCount(app: *const App, status: tickets.Status) usize {
        const b = if (app.board) |*b| b else return 0;
        return b.column(status, null, &.{});
    }

    pub fn boardCard(app: *const App, col: usize, row: usize) ?*const tickets.Card {
        var out: [max_cards]*const tickets.Card = undefined;
        const n = app.boardColumn(col, &out);
        return if (row < @min(n, max_cards)) out[row] else null;
    }

    /// The board's four columns side by side under a row of its own, right of the lanes' names
    /// in the every view; in each, cards stacked from the second row inside its border. The
    /// every view's strip is narrow, and the columns before it share what it leaves.
    pub fn boardColW(app: *const App, col: usize) u16 {
        const room = app.boardW() - app.laneLabelW();
        const cols: u16 = @intCast(app.boardCols());
        if (!app.boardLanes()) return room / cols;
        const strip = @min(strip_max, app.boardW() / 6);
        return if (app.boardStrip(col)) strip else (room - strip) / (cols - 1);
    }

    pub fn boardColX(app: *const App, col: usize) u16 {
        var x = app.boardX() + app.laneLabelW();
        for (0..col) |c| x += app.boardColW(c);
        return x;
    }

    pub const strip_max = 24;

    /// Whether column `col` is the every view's strip of what each lane closed last: done, a
    /// card a row with no box.
    pub fn boardStrip(app: *const App, col: usize) bool {
        return app.boardLanes() and tickets.statuses[col] == .done;
    }

    /// The rows a card takes in column `col`.
    pub fn cardRows(app: *const App, col: usize) usize {
        return if (app.boardStrip(col)) 1 else card_rows;
    }

    pub fn laneLabelW(app: *const App) u16 {
        return if (app.boardLanes()) @min(14, app.boardW() / 6) else 0;
    }

    /// A card is a box: its top edge, its title on two rows, a footer of what else is so of it,
    /// and its bottom edge, where the picked card's actions go.
    pub const CardRow = enum(u3) { top, title, title_more, footer, bottom };
    pub const card_rows = std.enums.values(CardRow).len;

    /// The screen row card `k` of those shown starts on.
    pub fn cardTop(k: usize) u16 {
        return @intCast(2 + card_rows * k);
    }

    /// Which card of those shown screen row `y` is in, and which of its rows.
    pub fn cardRowAt(y: u16) ?struct { k: usize, part: CardRow } {
        if (y < 2) return null;
        return .{ .k = (y - 2) / card_rows, .part = @fromBackingInt(@intCast((y - 2) % card_rows)) };
    }

    pub fn boardShown(app: *const App) usize {
        return @max(1, (app.view_h -| 3) / card_rows);
    }

    /// The first card column `col` shows: the picked card's column scrolls to keep it in view.
    pub fn boardFirst(app: *const App, col: usize) usize {
        const view = app.board_view orelse return 0;
        const shown = app.boardShown();
        return if (col == view.col and view.row >= shown) view.row - shown + 1 else 0;
    }

    pub const CardAt = struct { lane: usize, col: usize, row: usize };

    fn boardCardAt(app: *const App, x: u16, y: u16) ?CardAt {
        const left = app.boardColX(0);
        if (x < left or y < 2 or y + 1 >= app.view_h) return null;
        const col = for (0..app.boardCols()) |c| {
            if (x < app.boardColX(c) + app.boardColW(c)) break c;
        } else return null;
        if (app.boardLanes()) {
            const at = app.laneLineAt(y - 2 + app.laneScroll()) orelse return null;
            const k = at.row / app.cardRows(col);
            if (at.rule or app.laneCard(at.lane, col, k) == null) return null;
            return .{ .lane = at.lane, .col = col, .row = k };
        }
        const at = cardRowAt(y) orelse return null;
        if (at.k >= app.boardShown()) return null;
        const row = app.boardFirst(col) + at.k;
        return if (row < app.boardColumn(col, &.{})) .{ .lane = 0, .col = col, .row = row } else null;
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
            if (!startable(card)) return;
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
        view.focus = .orchestrator;
        try app.toSide();
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
        // the arrows pick a repo on auto's line, and only h goes back to the board from it
        var f: feed.Feed = undefined;
        const on_auto = app.feedOf(&f) and (if (app.feedPick(&f)) |picked| picked.auto else false);
        if (anyKey(key, &.{"h"}) or (!on_auto and anyKey(key, &.{ "\x1b[D", "\x1bOD" }))) view.focus = .board;
        if (anyKey(key, &.{"\r"}) and app.orchestratorState() == .off) {
            return app.send(.ignore, "run-shell -b \"babylon orchestrator\"", .{});
        }
        _ = try app.feedKey(key);
    }

    /// `]` or `[` from the board: the column's feed takes the keys, in normal mode, with the pick
    /// on Your move's first item or its last.
    fn toFeed(app: *App, key: []const u8) !void {
        const view = &app.board_view.?;
        if (!app.sided()) return;
        view.focus = .orchestrator;
        if (app.sideDue()) app.normal = true;
        app.dirty = true;
        var f: feed.Feed = undefined;
        if (!app.feedOf(&f) or f.items_shown == 0) return;
        view.pick = if (anyKey(key, &.{"["})) f.items_shown - 1 else 0;
        if (f.item(view.pick).?.ticket) |id| _ = app.pickCard(id);
    }

    /// A key on the board: h, l and the arrows go between columns, j and k along one, r narrows
    /// it to the next repo and from the last back to every one, Enter goes to the Claude holding
    /// the card picked or starts one on a free todo card, Escape and q close.
    fn boardKey(app: *App, key: []const u8) !void {
        app.clearStartRefusal();
        app.dirty = true;
        const view = &app.board_view.?;
        const is = anyKey;
        if (view.answering) return app.answerKey(key);
        if (view.giving != null) return app.giveKey(key);
        if (view.help) {
            view.help = false;
            return;
        }
        if (view.detail != null) {
            if (is(key, &.{ "\x1b", "q", " " })) view.detail = null;
            if (is(key, &.{ "j", "\x1b[B", "\x1bOB" }) and view.detail_scroll + 1 < app.detailRows()) view.detail_scroll += 1;
            if (is(key, &.{ "k", "\x1b[A", "\x1bOA" })) view.detail_scroll -|= 1;
            return;
        }
        if (app.columnFocused()) return app.columnKey(key);
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
            // off a lane's end the pick goes on to the next lane with a card in the same column
            var repos: [max_repos + 1][]const u8 = undefined;
            const lanes = app.laneRepos(&repos);
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
        if (is(key, &.{ "\x1b", "q" })) return app.closeBoard();
        if (is(key, &.{"`"})) return app.foldSide();
        if (is(key, &.{"g"})) return app.toGate();
        if (is(key, &.{"o"})) return app.toOrchestrator();
        if (is(key, &.{"A"})) return app.toggleAuto();
        if (is(key, &.{"P"})) return app.jumpProposed();
        if (is(key, &.{ "]", "[" })) return app.toFeed(key);
        if (is(key, &.{"x"})) return app.act(.no);
        if (is(key, &.{"W"})) if (app.boardCard(view.col, view.row)) |card| {
            if (card.status == .todo) return app.toNext(card.id, true);
        };
        if (is(key, &.{"n"})) return app.newTicket();
        const keyed = [_]struct { []const u8, CardAction }{
            .{ "\r", .go },    .{ "e", .edit },    .{ "p", .priority }, .{ ">", .close },
            .{ "<", .reopen }, .{ "J", .down },    .{ "K", .up },       .{ "t", .to_todo },
            .{ "G", .give },   .{ "w", .to_next },
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
        try app.send(.ignore, "run-shell -b \"babylon orchestrator\"", .{});
    }

    /// What babylon's file says of its orchestrator, when it does.
    pub fn orchestrator(app: *const App) ?tickets.Orchestrator {
        return if (app.board) |*b| b.orchestrator() else null;
    }

    /// babylon's auto mode, while it is on.
    pub fn auto(app: *const App) ?tickets.Auto {
        return if (app.board) |*b| b.auto() else null;
    }

    fn toggleAuto(app: *App) !void {
        try app.send(.ignore, "run-shell -b \"babylon auto {s}\"", .{if (app.auto() == null) "on" else "off"});
    }

    /// The todo card picked put in next, at its bottom or at its top.
    fn toNext(app: *App, id: u32, top: bool) !void {
        try app.send(.ignore, "run-shell -b \"babylon next {d}{s}\"", .{ id, if (top) " --at 1" else "" });
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

        pub fn label(action: CardAction) []const u8 {
            return switch (action) {
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
        const movable = card.status != .backlog and plainName(card.repo orelse "");
        const all = [_]struct { CardAction, bool }{
            .{ .go, card.proposal != null or card.holder() != null or startable(card) }, .{ .no, card.proposal != null },    .{ .answer, card.ask != null },
            .{ .give, givable(card) },                                                   .{ .edit, true },                   .{ .priority, true },
            .{ .close, card.status == .todo },                                           .{ .reopen, card.status == .done }, .{ .to_todo, card.status == .backlog },
            .{ .up, movable },                                                           .{ .down, movable },                .{ .to_next, card.status == .todo },
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
                try app.send(.ignore, "run-shell -b \"babylon update {d} --priority {s}\"", .{ card.id, next });
            },
            .close => try app.send(.ignore, "run-shell -b \"babylon update {d} --status done\"", .{card.id}),
            .to_next => try app.toNext(card.id, false),
            .reopen, .to_todo => try app.send(.ignore, "run-shell -b \"babylon update {d} --status todo\"", .{card.id}),
            .up, .down => {
                // a move babylon could not be narrowed to the repo shown would order every repo's cards
                if (app.pickRepo() != null and narrowed.len == 0) return;
                const down = action == .down;
                try app.send(.ignore, "run-shell -b \"babylon move {d} {s}{s}\"", .{ card.id, if (down) "down" else "up", narrowed });
                view.row = if (down) @min(view.row + 1, app.boardColumn(view.col, &.{}) -| 1) else view.row -| 1;
            },
        }
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

    /// What a click at the pointer would act on, underlined while the pointer is on it: a board
    /// button by its place in `boardButtons`, a card, or a row of the rail.
    pub const Hovered = union(enum) { none, button: usize, card: CardAt, rail: u16 };

    pub fn hovered(app: *const App) Hovered {
        const p = app.pointer;
        if (app.menu != null or app.prompt != null or app.overview != null or app.drag != .none) return .none;
        const rail_w = app.railDrawnW();
        if (p.x < rail_w) return if (p.x > 0 and p.x + 1 < rail_w and app.railActs(p.y)) .{ .rail = p.y } else .none;
        const view = app.board_view orelse return .none;
        if (view.boxed() or p.x >= app.boardX() + app.boardW()) return .none;
        var buttons: [48]Button = undefined;
        for (app.boardButtons(&buttons), 0..) |button, i| if (button.hit(p.x, p.y)) return .{ .button = i };
        return if (app.boardCardAt(p.x, p.y)) |at| .{ .card = at } else .none;
    }

    fn railActs(app: *const App, y: u16) bool {
        return (y == 1 and app.board != null) or app.railSession(y) != null or y == app.railNewRow() or
            y == app.railMenuRow() or app.railAgentAt(y) != null;
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
                const word = if (short) "" else "auto ";
                break :blk if (app.auto()) |state|
                    std.fmt.bufPrint(buf, " ◐ {s}{d}/{d} ", .{ word, state.working, state.cap }) catch " ◐ "
                else if (short) " ◐ " else " ◐ auto ";
            },
            .needs => blk: {
                const n = if (b) |board| board.needsYou().len else 0;
                break :blk if (short) std.fmt.bufPrint(buf, " ▲ {d} ", .{n}) catch " ▲ " else std.fmt.bufPrint(buf, " ▲ {d} need you ", .{n}) catch " ▲ ";
            },
            .new => " + ",
            .card => |action| std.fmt.bufPrint(buf, " {s} ", .{action.label()}) catch " ? ",
        };
    }

    /// The title the board's first row begins with.
    pub const board_title = " ▤ board";

    /// Where the board's first row ends its tabs: how many of its buttons there are, and where
    /// the `…` stands when tabs are left out.
    pub const Header = struct { n: usize, more: ?u16 };

    /// The board's first row in three groups: the title, the tabs (`every`, the repos, the
    /// backlog, each with its count), and, against the right edge, what babylon is doing
    /// (those needing the human, the gate, the orchestrator, auto). The right group drops its
    /// words when the tabs would not all fit beside it, and tabs that still do not fit are
    /// left out with a `…` after the last.
    pub fn header(app: *const App, out: []Button) Header {
        var buf: [64]u8 = undefined;
        var repos: [max_repos][]const u8 = undefined;
        const count = if (app.board) |*b| b.repos(&repos) else 0;
        const ox = app.boardX();
        const right = ox + app.boardW();
        const start = ox + @as(u16, @intCast(cellCount(board_title))) + 1;

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

        var tabs_w: usize = 0;
        for (tabs[0..tab_n]) |tab| tabs_w += cellCount(app.buttonLabel(tab, &buf)) + 1;
        const full_w = groupWidth(app, group[0..group_n], false);
        const short = start + tabs_w + 1 + full_w > right;
        for (group[0..group_n]) |*item| item.short = short;
        var group_w: u16 = @intCast(groupWidth(app, group[0..group_n], short));

        // what does not fit beside the tabs' first, which is the one that says where we are
        var first_w: u16 = @intCast(cellCount(app.buttonLabel(tabs[0], &buf)));
        while (group_n > 0 and start + first_w + 1 + group_w > right) {
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
        const limit = right - group_w -| 1;

        // the tabs, in room before the right group's, and one cell of it for a `…` when some are left
        var left: [max_repos + 2]Button = undefined;
        var left_n: usize = 0;
        x = start;
        for (tabs[0..tab_n]) |tab| {
            first_w = @intCast(cellCount(app.buttonLabel(tab, &buf)));
            if (x + first_w > limit) break;
            left[left_n] = .{ .what = tab.what, .x = x, .y = 0, .w = first_w };
            left_n += 1;
            x += first_w + 1;
        }
        var more: ?u16 = null;
        if (left_n < tab_n) {
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
    /// the to-do column's top edge, and the picked card's actions on its bottom edge, each kept
    /// to the room it has. A row of the strip has no edge: the strip's own foot has its reopen.
    pub fn boardButtons(app: *const App, out: []Button) []Button {
        const view = app.board_view orelse return out[0..0];
        const cw = app.boardColW(0);
        var buf: [64]u8 = undefined;
        var n = app.header(out).n;
        if (cw >= 12 and n < out.len) {
            out[n] = .{ .what = .new, .x = app.boardColX(0) + cw - 4, .y = 1, .w = 3 };
            n += 1;
        }
        const card = app.boardCard(view.col, view.row) orelse return out[0..n];
        const strip = app.boardStrip(view.col);
        const y: u16 = if (strip) app.view_h -| 1 else if (app.boardLanes()) blk: {
            const line = app.laneStart(view.lane) + view.row * card_rows + @backingInt(CardRow.bottom);
            const scroll = app.laneScroll();
            if (line < scroll) return out[0..n];
            break :blk @intCast(@min(2 + line - scroll, app.view_h));
        } else cardTop(view.row - app.boardFirst(view.col)) + @backingInt(CardRow.bottom);
        if (!strip and y + 1 >= app.view_h) return out[0..n];
        var have: [12]CardAction = undefined;
        var x: u16 = app.boardColX(view.col) + 2;
        const edge = app.boardColX(view.col) + app.boardColW(view.col) -| 2;
        for (cardActions(card, &have)) |action| {
            if (strip and action != .reopen) continue;
            const w: u16 = @intCast(cellCount(app.buttonLabel(.{ .what = .{ .card = action }, .x = 0, .y = 0, .w = 0 }, &buf)));
            if (x + w > edge or n == out.len) break;
            out[n] = .{ .what = .{ .card = action }, .x = x, .y = y, .w = w };
            n += 1;
            x += w + 1;
        }
        return out[0..n];
    }

    fn pressButton(app: *App, button: Button) !void {
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
            .gate => try app.toGate(),
            .orch => try app.toOrchestrator(),
            .auto => try app.toggleAuto(),
            .needs => try app.toFeed("]"),
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
        try app.send(.ignore, "run-shell -b \"out=\\$(babylon answer {d} {d} 2>&1) || " ++
            "{{ command -v notify-send >/dev/null && notify-send -a arena -- \\\"\\$out\\\"; }}\"", .{ ask.id, choice });
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
        if (app.drag != .none) return false;
        if (m.x < app.boardX()) {
            if (m.leftPress() and m.y != 1) try app.closeBoard();
            app.dirty = true;
            return false;
        }
        const view = &app.board_view.?;
        if (m.x >= app.boardX() + app.boardW() and app.sided() and !view.boxed()) {
            if (m.y >= app.view_h) return true;
            if (app.sideShown() and (app.sideFocused() or m.wheel())) return false;
            if (m.leftPress()) {
                view.focus = .orchestrator;
                app.drag = .focus;
                app.dirty = true;
            }
            return true;
        }
        if (m.leftPress()) view.focus = .board;
        if (m.wheel()) {
            if (app.navStep()) try app.boardKey(if (m.code & 1 == 0) "k" else "j");
            return true;
        }
        if (!m.leftPress()) return true;
        app.dirty = true;
        const open = &app.board_view.?;
        // a box over the board takes the click, as a key would, so nothing hidden under it is pressed
        if (open.boxed()) {
            open.help = false;
            open.detail = null;
            open.answering = false;
            open.giving = null;
            return true;
        }
        var buttons: [48]Button = undefined;
        for (app.boardButtons(&buttons)) |button| if (button.hit(m.x, m.y)) {
            try app.pressButton(button);
            return true;
        };
        const at = app.boardCardAt(m.x, m.y) orelse return true;
        view.answering = false;
        if (view.col == at.col and view.row == at.row and view.lane == at.lane) {
            try app.goCard();
        } else view.* = .{ .back = view.back, .col = at.col, .row = at.row, .lane = at.lane, .repo = view.repo, .backlog = view.backlog, .home = view.home };
        return true;
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

    pub const Hit = struct { session: *Session, index: usize };

    /// The windows of every session whose "session window" answers `query`, the closest first,
    /// into `out`. Returns how many.
    pub fn jumpHits(app: *const App, query: []const u8, out: []Hit) usize {
        var n: usize = 0;
        for ([_]u1{ 0, 1 }) |rank| for (app.sessions.items) |s| for (s.wins.items, 0..) |win, i| {
            if (n == out.len) return n;
            var buf: [160]u8 = undefined;
            const text = std.fmt.bufPrint(&buf, "{s} {s}", .{ s.name, win.name }) catch continue;
            if (menu.fuzzy(query, text) == rank) {
                out[n] = .{ .session = s, .index = i };
                n += 1;
            }
        };
        return n;
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
        const was = app.hovered();
        app.pointer = .{ .x = m.x, .y = m.y };
        if (!std.meta.eql(was, app.hovered())) app.dirty = true;
        if (m.leftPress() and app.menu == null and app.prompt == null and app.overview == null) {
            // with the board open, where a click puts the keys is the board's to say: a click on
            // its chrome must not leave the focused column in normal mode, drawn as insert
            if (app.paneClick(m)) {
                app.normal = false;
            } else if (app.board_view == null or m.x < app.railDrawnW()) app.normal = true;
            app.dirty = true;
        }
        try app.pointAs(m);
        if (m.hover()) app.hoverRail(m.x);
        const over_dots = m.y == app.view_h and m.x >= app.term_w - app.view_w;
        if (over_dots != app.over_dots) {
            app.over_dots = over_dots;
            app.dirty = true;
        }
        if (app.overview != null) return app.overviewMouse(m);
        if (app.board_view != null) if (try app.boardMouse(m)) return;
        if (app.prompt) |*prompt| {
            if (!m.leftPress() and !m.rightPress()) return;
            app.dirty = true;
            const at = app.box(prompt.height());
            const first = at.y + menu.Prompt.list_row;
            const listed = prompt.what == .jump and m.leftPress() and m.x > at.x and m.x + 1 < at.x + menu.width and
                m.y >= first and m.y < first + menu.jump_rows;
            if (!listed) {
                app.prompt = null;
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
                if (!m.release) try app.send(.ignore, "run-shell -b \"wl-paste -p -n | tmux load-buffer -b arena-primary - && tmux paste-buffer -p -d -b arena-primary -t %{d}\"", .{pane.id});
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
        if (app.board_view) |view| return app.sideShown() and !view.boxed() and m.y < app.view_h and m.x >= app.boardX() + app.boardW();
        return m.x >= @max(app.term_w - app.view_w, app.railDrawnW());
    }

    /// Normal mode ends where an overlay has the keys: it is the mode there, and closing it is
    /// back to insert.
    fn settleMode(app: *App) void {
        if (app.normal and app.overlay() and !app.sideFocused()) app.normal = false;
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

    fn menuKeys(app: *App, text: []const u8) !void {
        var i: usize = 0;
        while (i < text.len) {
            // a key that closed what had the keys leaves the rest of the read to the pane
            if (app.typing()) return app.forward(text[i..]);
            // an arrow is ESC and two more; anything else is a key a byte
            const len: usize = if (text[i] == 0x1b and text.len - i >= 3) 3 else 1;
            const key = text[i..][0..len];
            i += len;
            if (app.normal) {
                if (app.sideFocused() and try app.feedKey(key)) continue;
                if (std.mem.eql(u8, key, "i") or std.mem.eql(u8, key, "\x1b")) {
                    app.normal = false;
                    app.dirty = true;
                }
                if (std.mem.eql(u8, key, "b")) try app.goHome();
            } else if (app.overview != null) {
                try app.overviewKey(key);
            } else if (app.board_view != null and !app.sideFocused()) {
                try app.boardKey(key);
            } else if (app.prompt) |*prompt| {
                app.dirty = true;
                switch (prompt.press(key)) {
                    .none => {},
                    .cancel => app.prompt = null,
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
        app.prompt = null;
        const s = app.cur() orelse return;
        var cmd: Writer.Allocating = .init(app.gpa);
        defer cmd.deinit();
        switch (prompt.what) {
            .jump => {
                var hits: [menu.jump_rows]Hit = undefined;
                const n = app.jumpHits(prompt.text(), &hits);
                if (prompt.selected < n) try app.jumpTo(hits[prompt.selected].session, hits[prompt.selected].index);
                return;
            },
            .search => return,
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

    fn onChord(app: *App, letter: u8) !void {
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
            'j' => try app.sessionBy(1),
            'k' => try app.sessionBy(-1),
            'J' => try app.sessionSwapBy(1),
            'K' => try app.sessionSwapBy(-1),
            'H' => try app.swapBy(-1),
            'L' => try app.swapBy(1),
            'x' => app.openMenu(&menu.confirm),
            'm' => app.openMenu(&menu.main),
            'q' => app.quit = true,
            'z' => app.toggleFull(),
            ';' => try app.widenBy(-share_step),
            '\'' => try app.widenBy(share_step),
            'o' => app.openOverview(),
            'b' => try app.toggleBoard(),
            'w' => app.toggleRail(),
            'n' => try app.stepAgent(1),
            'N' => try app.stepAgent(-1),
            '/' => app.openSearch(),
            'p' => {
                app.prompt = .{ .what = .jump };
                app.dirty = true;
            },
            '\r' => try app.newWindow(),
            else => if (app.sessionById(app.bound())) |s| {
                if (letter - '1' < s.wins.items.len) try app.focusIn(s, letter - '1');
            },
        }
    }

    /// With Alt: h and l move along the strip, j and k between sessions, 1 to 9 go to a window,
    /// J and K move the session down and up the rail,
    /// H and L move the window, ; and ' make it narrower and wider, Enter opens one, x closes
    /// it, z gives it the whole width, p asks
    /// for a window to jump to, o shows every session's windows at once, b babylon's board, /
    /// searches the pane's history, m opens the menu and q leaves.
    /// Everything else is the focused pane's, or the menu's while it is open. Alt is ESC and the
    /// letter together, which a typed Escape then a letter rarely is.
    ///
    /// Returns how many bytes at the end of `bytes` to pass again in front of the next read.
    pub fn onInput(app: *App, bytes: []const u8) !usize {
        var rest = bytes;
        while (rest.len > 0 and !app.quit) {
            const part = keys.next(rest);
            rest = part.rest;
            if (app.typing()) try app.forward(part.text) else try app.menuKeys(part.text);
            defer app.settleMode();
            switch (part.event orelse return part.held.len) {
                .mouse => |m| try app.onMouse(m),
                .chord => |letter| try app.onChord(letter),
                .mode => try app.toggleMode(),
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
        try cmd.writer.print("send-keys -H -t %{d}", .{pane.id});
        for (bytes) |b| try cmd.writer.print(" {x:0>2}", .{b});
        try app.send(.ignore, "{s}", .{cmd.written()});
    }
};

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

/// The longest repo name a session is named for in full.
const session_name = 64;

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

/// A todo card no Claude holds, waiting on nothing, of a repo that can name a session and a folder.
fn startable(card: *const tickets.Card) bool {
    const repo = card.repo orelse return false;
    return card.holder() == null and card.status == .todo and card.blocked_by.len == 0 and plainName(repo) and
        repo.len <= session_name;
}

/// A card babylon would let a running Claude claim: to do, held by no one, waiting on nothing.
fn givable(card: *const tickets.Card) bool {
    return card.holder() == null and card.status == .todo and card.blocked_by.len == 0 and !std.mem.eql(u8, card.kind, "epic");
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
    c.status = .backlog;
    try std.testing.expect(!givable(&c));
    c = free;
    c.kind = "epic";
    try std.testing.expect(!givable(&c));
}

test "a Claude is started only on a free todo card of a plain repo" {
    const free: tickets.Card = .{ .id = 1, .repo = "tlon", .title = "a", .status = .todo };
    try std.testing.expect(startable(&free));
    var c = free;
    c.blocked_by = &.{2};
    try std.testing.expect(!startable(&c));
    c = free;
    c.claimed_by = "%3";
    try std.testing.expect(!startable(&c));
    c = free;
    c.status = .doing;
    try std.testing.expect(!startable(&c));
    c = free;
    const long: [session_name + 1]u8 = @splat('a');
    c.repo = &long;
    try std.testing.expect(!startable(&c));
    c = free;
    c.repo = "a b";
    try std.testing.expect(!startable(&c));
    c = free;
    c.repo = null;
    try std.testing.expect(!startable(&c));
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
    app.sessions = .empty;
    app.board.?.deinit();
    app.board = try tickets.Board.parse(std.testing.allocator,
        \\{"tickets":[],"orchestrator":{"on":false,"running":false}}
    );
    try eq(.off, app.orchestratorState());
}

test "the every view's lanes: their lines, the pick stepping across them, and the scroll" {
    var app: App = .{ .gpa = std.testing.allocator, .io = undefined, .tmux_in = undefined };
    app.term_w = 100;
    app.view_w = 80;
    app.view_h = 6;
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

    // a card's rows for each card: arena two cards, tlon one, the cards of no repo one, a rule
    // between lanes
    const cr = App.card_rows;
    try eq(App.LaneLine{ .lane = 0, .row = 1, .rule = false }, app.laneLineAt(1).?);
    try eq(App.LaneLine{ .lane = 0, .row = 2 * cr, .rule = true }, app.laneLineAt(2 * cr).?);
    try eq(App.LaneLine{ .lane = 1, .row = 0, .rule = false }, app.laneLineAt(2 * cr + 1).?);
    try eq(App.LaneLine{ .lane = 2, .row = 0, .rule = false }, app.laneLineAt(3 * cr + 2).?);
    try eq(@as(?App.LaneLine, null), app.laneLineAt(4 * cr + 2));

    const picked = struct {
        fn id(a: *const App) ?u32 {
            const view = a.board_view.?;
            return if (a.boardCard(view.col, view.row)) |card| card.id else null;
        }
    }.id;
    try eq(@as(?u32, 1), picked(&app));
    try app.boardKey("j");
    try eq(@as(?u32, 2), picked(&app));
    // three lines shown, and the second card's bottom edge on the tenth
    try eq(@as(usize, 2 * cr - 3), app.laneScroll());
    try app.boardKey("j");
    try eq(@as(?u32, 5), picked(&app));
    try eq(@as(usize, 4 * cr + 2 - 3), app.laneScroll());
    try app.boardKey("j");
    try eq(@as(?u32, 5), picked(&app));
    try app.boardKey("k");
    try eq(@as(?u32, 2), picked(&app));
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
    app.view_w = 60;
    try std.testing.expectEqualStrings("every 3|arena 2|menard 0|▲ 0|●|◐ 2/3|", try labels(&app, &out));
    const narrow = app.header(&buttons);
    try std.testing.expect(narrow.more != null);
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

    try eq(@min(App.strip_max, app.boardW() / 6), app.boardColW(3));
    try std.testing.expect(app.boardColW(0) > app.boardColW(3));
    try eq(app.boardColX(2) + app.boardColW(2), app.boardColX(3));
    try std.testing.expect(app.boardColX(3) + app.boardColW(3) <= app.boardX() + app.boardW());
    // one card's rows, where done's three rows and its count of the rest are four
    try eq(@as(usize, App.card_rows), app.laneRows("arena"));

    try app.boardKey("l");
    try app.boardKey("l");
    try app.boardKey("l");
    try app.boardKey("j");
    const view = app.board_view.?;
    try eq(@as(usize, 1), view.row);
    try eq(view.row, app.boardCardAt(app.boardColX(3) + 1, 2 + 1).?.row);
    var buttons: [48]App.Button = undefined;
    const shown = app.boardButtons(&buttons);
    const last = shown[shown.len - 1];
    try eq(App.CardAction.reopen, last.what.card);
    try eq(app.view_h - 1, last.y);

    // one repo's view keeps done a column like the others
    app.board_view.?.repo = 1;
    try eq(app.boardColW(0), app.boardColW(3));
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

    // menard has only a closed card, so no lane in the every view
    try app.showCard(6);
    try eq(@as(?u32, 6), picked(&app));
    try std.testing.expectEqualStrings("menard", app.boardRepo().?);

    try app.showCard(8);
    try eq(@as(?u32, 8), picked(&app));
    try std.testing.expect(app.board_view.?.backlog);

    try app.showCard(99);
    try eq(@as(?u32, 1), picked(&app));
    try std.testing.expect(app.boardLanes());
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

test "a card's detail runs its long lines on, cut at the box's width" {
    var lines = DetailLines.init("#3 Title\n\none two three four\n", 8);
    const want = [_][]const u8{ "#3 Title", "", "one two ", "three fo", "ur" };
    for (want) |line| try std.testing.expectEqualStrings(line, lines.next().?);
    try std.testing.expectEqual(null, lines.next());
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
