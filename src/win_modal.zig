const std = @import("std");
const vt = @import("ghostty-vt");
const theme = @import("theme.zig");
const bench = @import("parts.zig");
const app_mod = @import("app.zig");
const tickets = @import("board.zig");
const sheets = @import("plan.zig");
const draw = @import("draw.zig");
const modelName = draw.modelName;
const ago = draw.ago;
const feed = @import("feed.zig");
const color = @import("color.zig");
const boxLine = draw.boxLine;
const benchState = draw.benchState;
const fitted = draw.fitted;
const App = app_mod.App;
const Writer = std.Io.Writer;
const Pen = draw.Pen;
const clip = draw.clip;
const cellCount = draw.cellCount;
const repoHue = draw.repoHue;
const ink = draw.ink;
const chip = draw.chip;
const heading = draw.heading;
const onPanel = draw.onPanel;
const paintStyle = draw.paintStyle;

const DraftTone = enum { plain, dim, pick };

/// A draft's modal: the epic's outcome, its steps one a row with repo, model and what each waits
/// on, the pick marked, and the foot's keys.
pub fn draftBox(app: *const App, w: *Writer) !void {
    const rect = app.draftRect() orelse return;
    const view = app.home.?;
    const epic = view.draft.?;
    var list: [App.draft_max]*const tickets.Card = undefined;
    const steps = app.draftSteps(epic, &list);
    var head: [32]u8 = undefined;
    const title = std.fmt.bufPrint(&head, "☐ draft #{d}", .{epic}) catch "draft";
    if (app.roles) |r| {
        try bench.window(w, r, rect.x, rect.y, rect.w - 1, rect.h, title, null, true);
        try bench.say(w, rect.x + rect.w - 4, rect.y, "✕", r.text, r.raised, true);
    } else {
        const edge = ink(app, "amber", 4);
        var pen: Pen = .{};
        try pen.set(w, edge, null);
        try w.print("\x1b[{d};{d}H╭─ ", .{ rect.y + 1, rect.x + 1 });
        try pen.set(w, heading(app), null);
        try w.writeAll(title);
        try pen.set(w, edge, null);
        try w.writeAll(" ");
        for (cellCount(title) + 4..rect.w -| 1) |_| try w.writeAll("─");
        try w.writeAll("╮");
        try w.print("\x1b[{d};{d}H╰", .{ rect.y + rect.h, rect.x + 1 });
        for (2..rect.w) |_| try w.writeAll("─");
        try w.writeAll("╯");
    }
    try draftLine(app, w, rect, 1, app.draftTitle(epic), .plain);
    var count: [200]u8 = undefined;
    const body = if (app.draftIdea(epic)) |idea| idea.body else "";
    const quote = if (body.len == 0)
        std.fmt.bufPrint(&count, "{d} steps", .{steps.len}) catch ""
    else
        std.fmt.bufPrint(&count, "from your idea: \"{s}\"", .{clip(body, 150)}) catch "";
    try draftLine(app, w, rect, 2, quote, .dim);
    const asks = app.draftAsks(epic);
    const shown = @min(steps.len, rect.h -| 6 -| asks.len);
    for (asks, 0..) |ask, i| {
        var line: [300]u8 = undefined;
        const text = if (ask.answer) |answer|
            std.fmt.bufPrint(&line, "asked you: \"{s}\" you: \"{s}\"", .{ clip(ask.question, 100), clip(answer, 60) }) catch ""
        else
            std.fmt.bufPrint(&line, "asked you: \"{s}\" (open)", .{clip(ask.question, 100)}) catch "";
        try draftLine(app, w, rect, @intCast(4 + shown + i), text, .dim);
    }
    for (steps[0..shown], 0..) |step, i| {
        var row: [200]u8 = undefined;
        var waits: [48]u8 = undefined;
        const wait: []const u8 = if (step.blocked_by.len == 0) "free" else std.fmt.bufPrint(&waits, "← #{d}{s}", .{ step.blocked_by[0], if (step.blocked_by.len > 1) " …" else "" }) catch "";
        const model = step.model orelse "";
        const short = if (std.mem.startsWith(u8, model, "claude-")) model["claude-".len..] else model;
        const word = short[0 .. std.mem.indexOfScalar(u8, short, '-') orelse short.len];
        var lead: [64]u8 = undefined;
        const front = std.fmt.bufPrint(&lead, "{d} #{d} {s: <10} {s: <7} ", .{ i + 1, step.id, clip(step.repo orelse "", 10), word }) catch "";
        const room = (rect.w -| 5) -| cellCount(front) -| cellCount(wait) -| 2;
        const named = clip(step.title, room);
        const text = std.fmt.bufPrint(&row, "{s}{s}  {s}", .{ front, named, wait }) catch "";
        try draftLine(app, w, rect, @intCast(3 + i), text, if (i == view.draft_pick) .pick else .plain);
    }
    try draftLine(app, w, rect, rect.h - 2, "y go   r reply with changes   e edit a step   space its ticket   q close", .dim);
}

fn draftLine(app: *const App, w: *Writer, rect: App.ModalRect, row: u16, text: []const u8, tone: DraftTone) !void {
    const inner: u16 = rect.w - 5;
    if (app.roles) |r| {
        const y = rect.y + row;
        const ink_of = switch (tone) {
            .plain, .pick => r.text,
            .dim => r.dim,
        };
        if (tone == .pick) try bench.say(w, rect.x + 1, y, "▌", r.accent, r.panel, true);
        try bench.say(w, rect.x + 2, y, clip(text, inner), ink_of, r.panel, tone == .pick);
        return;
    }
    var pen: Pen = .{};
    const style: vt.Style = switch (tone) {
        .plain => .{},
        .dim => ink(app, "dim", 8),
        .pick => heading(app),
    };
    try boxLine(w, &pen, ink(app, "amber", 4), style, rect.x, rect.y + 1 + row, text, inner);
}

/// A ticket's whole detail over the board, as babylon gave it, its lines cut to the box's width
/// and run on under one another, scrolled `scroll` rows down.
pub fn detailBox(app: *App, w: *Writer, id: u32, scroll: usize) !void {
    if (app.home.?.gate) return gateBox(app, w, id, scroll);
    const rect = app.modalRect() orelse return;
    if (app.roles) |r| return benchDetail(app, w, r, id, rect, scroll);
    const inner = app_mod.detailWidth(app.boardW()).inner;
    app.grab.window(.{ .x = rect.x + 2, .y = rect.y + 1, .w = inner, .h = rect.h -| 2 });
    const x = rect.x;
    const top = rect.y + 1;
    const bottom = rect.y + rect.h;
    var buf: [24]u8 = undefined;
    const title = std.fmt.bufPrint(&buf, " #{d} ", .{id}) catch " detail ";
    if (rect.w < cellCount(title) + 3) return;
    const edge = ink(app, "amber", 4);
    var pen: Pen = .{};

    const dim = ink(app, "dim", 8);
    const note = doneNote(app, id);
    var note_rows: u16 = 0;
    var counted = app_mod.DetailLines.init(note, inner);
    if (note.len > 0) while (counted.next()) |_| {
        if (note_rows < bottom - top - 2) note_rows += 1;
    };
    const card = app.modalCard();
    var head: App.CardHead = .{};
    if (card) |it| app.modalHead(it, inner, app.askWords(it) != null, &head);
    const win = if (card) |it| app.claudeOf(it) else null;
    if (win) |it| App.claudeHead(it, &head);
    const claude_rows: u16 = if (win != null and bottom - top - 2 > note_rows + head.n + 1) 1 else 0;
    const text_end = bottom - note_rows - claude_rows;

    var y = top + 1;
    for (head.lines[0..head.n], head.kinds[0..head.n], 0..) |line, kind, at| {
        if (y >= text_end) break;
        const style: vt.Style = switch (kind) {
            .plain, .options => .{},
            .dim, .check, .shell => dim,
            .warn => ink(app, "amber", 4),
            .sub => if (at - head.subs.? + 1 == app.home.?.sub_pick) ink(app, "amber", 4) else .{},
        };
        try boxLine(w, &pen, edge, style, x, y, line, inner);
        if (kind != .options) try app.grab.row(app.gpa, x + 2, y - 1, clip(line, inner), head.joins[at]);
        y += 1;
    }
    const text = if (app.detail.items.len > 0) app.detail.items else "…";
    var row: usize = 0;
    const parts = [2]struct { text: []const u8, style: vt.Style }{
        .{ .text = if (card) |it| it.stage_note else "", .style = dim },
        .{ .text = text, .style = .{} },
    };
    for (parts) |part| {
        if (part.text.len == 0) continue;
        var lines = app_mod.DetailLines.init(part.text, inner);
        while (lines.next()) |line| : (row += 1) {
            if (row < scroll or y >= text_end) continue;
            try boxLine(w, &pen, edge, part.style, x, y, line, inner);
            try app.grab.row(app.gpa, x + 2, y - 1, line, lines.dropped);
            y += 1;
        }
    }
    while (y < text_end) : (y += 1) try boxLine(w, &pen, edge, .{}, x, y, "", inner);
    if (claude_rows > 0) if (win) |it| {
        var ago_buf: [8]u8 = undefined;
        var said: [320]u8 = undefined;
        const state = if (it.claude == .none) "" else @tagName(it.claude);
        const line = std.fmt.bufPrint(&said, "its Claude: {s} {s} · {s}", .{ state, ago(&ago_buf, app.epoch, it.since), it.detail() }) catch "its Claude";
        try boxLine(w, &pen, edge, dim, x, y, line, inner);
        y += 1;
    };
    var noted = app_mod.DetailLines.init(note, inner);
    while (y < bottom) : (y += 1) {
        const line = noted.next() orelse "";
        try boxLine(w, &pen, edge, dim, x, y, line, inner);
        try app.grab.row(app.gpa, x + 2, y - 1, line, noted.dropped);
    }
    try modalFrame(app, w, rect, title, " j k scroll ");
}

/// A switch as text: the knob right when on.
fn knobText(on: bool) []const u8 {
    return if (on) "▐ ●▌" else "▐● ▌";
}

/// Auto's settings over the board: auto as a switch, how many of its cap work, hold as a switch,
/// and each repo's cap as a stepper, `paused` at 0, with the Claudes working it. The foot says
/// babylon's refusal, else the keys. Its rows are where `App.autoClick` looks.
pub fn autoBox(app: *const App, w: *Writer) !void {
    const rect = app.autoRect() orelse return;
    const view = app.home.?;
    const pick = view.auto_pick.?;
    const state = app.board.?.autoState() orelse tickets.Auto{};
    const on = app.auto() != null;
    const hold = app.holding();
    const rows = @min(app.autoRepos(), App.autoRoom(rect));
    const stepper = app.autoStepper(rect);
    const x0 = rect.x + 2;
    const foot = rect.y + rect.h - 1;
    var line: [96]u8 = undefined;
    const said = app.auto_wants.refused;
    const hint = " j k pick   + - step   a auto   H hold   esc close ";
    const working = std.fmt.bufPrint(&line, "working {d} of {d}", .{ state.working, state.cap }) catch "";
    if (app.roles) |r| {
        try bench.window(w, r, rect.x, rect.y, rect.w - 1, rect.h, "auto", null, true);
        try bench.say(w, rect.x + rect.w - 4, rect.y, "✕", r.text, r.raised, true);
        _ = try bench.toggle(w, r, x0, rect.y + 1, "auto", on, r.panel);
        try bench.say(w, x0 + 10, rect.y + 1, if (on) "on" else "off", if (on) r.accent else r.dim, r.panel, pick == 0);
        try bench.say(w, x0, rect.y + 2, working, r.dim, r.panel, false);
        _ = try bench.toggle(w, r, x0, rect.y + 3, "hold", hold, r.panel);
        try bench.say(w, x0 + 10, rect.y + 3, if (hold) "on" else "off", if (hold) r.accent else r.dim, r.panel, pick == 1);
        if (pick < 2) try bench.say(w, rect.x + 1, rect.y + 1 + 2 * @as(u16, @intCast(pick)), "▌", r.accent, r.panel, true);
        for (0..rows) |i| {
            const repo = app.autoRepo(i) orelse continue;
            const y = rect.y + 5 + @as(u16, @intCast(i));
            const picked = pick == 2 + i;
            if (picked) try bench.say(w, rect.x + 1, y, "▌", r.accent, r.panel, true);
            try bench.say(w, x0, y, repo.name, if (picked) r.text else r.dim, r.panel, picked);
            try bench.say(w, stepper.minus, y, "[-]", r.accent, r.tile, true);
            const value = std.fmt.bufPrint(&line, "{d:^3}", .{repo.cap}) catch "";
            try bench.say(w, stepper.minus + 3, y, value, r.text, r.panel, true);
            try bench.say(w, stepper.plus, y, "[+]", r.accent, r.tile, true);
            const n = feed.working(&app.board.?, repo.name);
            const note = if (repo.cap == 0) "paused" else std.fmt.bufPrint(&line, "{d} working", .{n}) catch "";
            try bench.say(w, stepper.plus + 4, y, note, if (repo.cap == 0) r.failed else r.dim, r.panel, false);
        }
        if (said) |text| {
            try bench.say(w, x0, foot, clip(text, rect.w -| 5), r.failed, r.panel, true);
        } else if (cellCount(hint) < rect.w -| 4) try bench.say(w, x0, foot, hint, r.dim, r.panel, false);
        return;
    }
    const edge = ink(app, "amber", 4);
    const dim = ink(app, "dim", 8);
    const name_w = stepper.minus - 2 - x0;
    const inner = rect.w -| 4;
    var pen: Pen = .{};
    try pen.set(w, edge, null);
    try w.print("\x1b[{d};{d}H╭─", .{ rect.y + 1, rect.x + 1 });
    try pen.set(w, heading(app), null);
    try w.writeAll(" auto ");
    try pen.set(w, edge, null);
    for (9..rect.w) |_| try w.writeAll("─");
    try w.writeAll("╮");
    var y: u16 = 1;
    while (y < rect.h - 1) : (y += 1) {
        var buf: [160]u8 = undefined;
        var style: vt.Style = .{};
        var text: []const u8 = "";
        if (y == 1 or y == 3) {
            const picked = pick == (y - 1) / 2;
            const set = if (y == 1) on else hold;
            style.flags.bold = picked;
            text = std.fmt.bufPrint(&buf, "{s}  {s} {s}", .{ if (y == 1) "auto" else "hold", knobText(set), if (set) "on" else "off" }) catch "";
        } else if (y == 2) {
            style = dim;
            text = working;
        } else if (y >= 5 and y - 5 < rows) {
            const i = y - 5;
            const repo = app.autoRepo(i) orelse continue;
            var tail: [32]u8 = undefined;
            const note = if (repo.cap == 0) "paused" else std.fmt.bufPrint(&tail, "{d} working", .{feed.working(&app.board.?, repo.name)}) catch "";
            style.flags.bold = pick == 2 + i;
            text = std.fmt.bufPrint(&buf, "{s}{s}  [-]{d:^3}[+]  {s}", .{ repo.name, spaces[0..name_w -| cellCount(repo.name)], repo.cap, note }) catch "";
        }
        try boxLine(w, &pen, edge, style, rect.x, rect.y + y + 1, text, inner);
    }
    try pen.set(w, edge, null);
    try w.print("\x1b[{d};{d}H╰─", .{ rect.y + rect.h, rect.x + 1 });
    for (3..rect.w) |_| try w.writeAll("─");
    try w.writeAll("╯");
    const foot_text = if (said) |text| clip(text, rect.w -| 5) else hint;
    if (cellCount(foot_text) + 3 < rect.w) {
        try pen.set(w, if (said != null) ink(app, "emberdim", 1) else dim, null);
        try w.print("\x1b[{d};{d}H{s}", .{ rect.y + rect.h, rect.x + 3, foot_text });
    }
    try pen.set(w, .{}, null);
}

const spaces: [64]u8 = @splat(' ');

/// The card's modal in Workbench's look: a window over the board with its shadow and `✕`, the
/// title whole, the facts as chips, the open ask as a violet band with its options as buttons,
/// the body, and the card's actions as buttons along the foot. Its rows are `modalButtons`'.
fn benchDetail(app: *App, w: *Writer, r: theme.Roles, id: u32, rect: App.ModalRect, scroll: usize) !void {
    const inner = app_mod.detailWidth(app.boardW()).inner;
    const x0 = rect.x + 2;
    const foot = rect.y + rect.h - 1;
    app.grab.window(.{ .x = x0, .y = rect.y + 1, .w = inner, .h = rect.h -| 2 });
    var tbuf: [48]u8 = undefined;
    const card = app.modalCard();
    const title = std.fmt.bufPrint(&tbuf, "#{d} \u{b7} {s}", .{ id, if (card) |it| it.repo orelse "no repo" else "" }) catch "";
    try bench.window(w, r, rect.x, rect.y, rect.w - 1, rect.h, title, null, true);
    try bench.say(w, rect.x + rect.w - 4, rect.y, "✕", r.text, r.raised, true);

    var head: App.CardHead = .{};
    if (card) |it| app.modalHead(it, inner, app.askWords(it) != null, &head);
    if (card) |it| if (app.claudeOf(it)) |claude| App.claudeHead(claude, &head);
    const note = doneNote(app, id);
    var note_rows: u16 = 0;
    var counted = app_mod.DetailLines.init(note, inner);
    while (counted.next()) |_| {
        if (note_rows < foot - rect.y - 3) note_rows += 1;
    }
    const win = if (card) |it| app.claudeOf(it) else null;
    const claude_rows: u16 = if (win != null and foot - rect.y - 3 > note_rows + head.n + 1) 1 else 0;
    const text_end = foot - 1 - note_rows - claude_rows;

    var buttons: [16]App.ModalButton = undefined;
    const modal = app.modalButtons(&buttons);
    var y = rect.y + 1;
    var band = false;
    var facts = false;
    for (head.lines[0..head.n], head.kinds[0..head.n], 0..) |line, kind, at| {
        if (y >= text_end) break;
        if (kind == .warn) band = true;
        const bg = if (band) r.tile else r.panel;
        if (band) try bench.fill(w, rect.x + 1, y, rect.w - 3, bg);
        switch (kind) {
            .plain => {
                try bench.say(w, x0, y, clip(line, inner), r.text, bg, true);
                try app.grab.row(app.gpa, x0, y, clip(line, inner), head.joins[at]);
            },
            .dim => if (facts) {
                try bench.say(w, x0, y, clip(line, inner), r.dim, bg, false);
                try app.grab.row(app.gpa, x0, y, clip(line, inner), null);
            } else {
                facts = true;
                try benchFacts(app, w, r, card.?, x0, y, inner);
            },
            .warn => {
                try bench.say(w, x0, y, clip(line, inner), r.you, bg, true);
                try app.grab.row(app.gpa, x0, y, clip(line, inner), null);
            },
            .check => {
                try app.grab.row(app.gpa, x0, y, clip(line, inner), null);
                const settled = card.?.checks[at - head.checks.?].result != null;
                const lit = at - head.checks.? + 1 == @min(@max(app.home.?.check_pick, 1), card.?.checks.len);
                try bench.say(w, x0, y, clip(line, inner), if (lit) r.accent else if (settled) r.dim else r.text, bg, lit);
            },
            .sub => {
                const lit = at - head.subs.? + 1 == app.home.?.sub_pick;
                try app.grab.row(app.gpa, x0, y, clip(line, inner), null);
                try bench.say(w, x0, y, clip(line, inner), if (lit) r.accent else r.text, bg, lit);
            },
            .shell => {
                try app.grab.row(app.gpa, x0, y, clip(line, inner), null);
                try bench.say(w, x0, y, clip(line, inner), r.dim, bg, false);
            },
            .options => for (modal) |button| if ((button.action == .option or button.action == .words) and button.y == y) {
                const lit = button.action == .option and button.action.option == app.home.?.ask_pick;
                _ = try bench.button(w, r, button.x, y, button.key, button.label, lit, r.tile);
            },
        }
        y += 1;
    }
    if (band and y < text_end) {
        try bench.fill(w, rect.x + 1, y, rect.w - 3, r.tile);
        y += 1;
    }

    const text = if (app.detail.items.len > 0) app.detail.items else "…";
    var row: usize = 0;
    const parts = [2]struct { text: []const u8, fg: color.RGB }{
        .{ .text = if (card) |it| it.stage_note else "", .fg = r.dim },
        .{ .text = text, .fg = r.text },
    };
    for (parts) |part| {
        if (part.text.len == 0) continue;
        var lines = app_mod.DetailLines.init(part.text, inner);
        while (lines.next()) |line| : (row += 1) {
            if (row < scroll or y >= text_end) continue;
            try bench.say(w, x0, y, clip(line, inner), part.fg, r.panel, false);
            try app.grab.row(app.gpa, x0, y, clip(line, inner), lines.dropped);
            y += 1;
        }
    }
    y = text_end;
    if (claude_rows > 0) if (win) |it| {
        var ago_buf: [8]u8 = undefined;
        var said: [320]u8 = undefined;
        const state = if (it.claude == .none) "" else @tagName(it.claude);
        const line = std.fmt.bufPrint(&said, "its Claude: {s} {s} \u{b7} {s}", .{ state, ago(&ago_buf, app.epoch, it.since), it.detail() }) catch "its Claude";
        try bench.say(w, x0, y, clip(line, inner), r.dim, r.panel, false);
        y += 1;
    };
    var noted = app_mod.DetailLines.init(note, inner);
    while (noted.next()) |line| {
        if (y >= foot - 1) break;
        try bench.say(w, x0, y, clip(line, inner), r.dim, r.panel, false);
        try app.grab.row(app.gpa, x0, y, clip(line, inner), noted.dropped);
        y += 1;
    }

    var end = x0;
    var primary = true;
    for (modal) |button| {
        if ((button.action == .option or button.action == .words or button.action == .sub) and button.y != foot) continue;
        _ = try bench.button(w, r, button.x, button.y, button.key, button.label, primary and button.action != .close, r.ground);
        if (button.action != .close) primary = false;
        end = button.x + button.width() + 1;
    }
    const hint = " j k scroll ";
    if (end + cellCount(hint) < rect.x + rect.w - 2) try bench.say(w, end, foot, hint, r.dim, r.panel, false);
}

/// A card's facts as a row of chips from `x`, as many as `room` cells have: its repo, priority,
/// where it is, model, who holds it, and how long it has been filed and held.
fn benchFacts(app: *const App, w: *Writer, r: theme.Roles, card: *const tickets.Card, x: u16, y: u16, room: u16) !void {
    var at = x;
    const end = x + room;
    var sbuf: [96]u8 = undefined;
    var lbuf: [96]u8 = undefined;
    const mark = repoHue(r, card.repo);
    const high = std.mem.eql(u8, card.priority, "high");
    const low = std.mem.eql(u8, card.priority, "low");
    const state = benchState(app, card, r, &sbuf);
    const held = if (card.heldBy()) |pane| std.fmt.bufPrint(&lbuf, "held {s}", .{pane}) catch "" else "";
    var hbuf: [48]u8 = undefined;
    const handed = if (card.handed_off_from) |pane| std.fmt.bufPrint(&hbuf, "handed off from {s}", .{pane}) catch "" else "";
    var filed: [8]u8 = undefined;
    var claimed: [8]u8 = undefined;
    var fbuf: [24]u8 = undefined;
    var cbuf: [24]u8 = undefined;
    const filed_text = if (tickets.epochOf(card.inserted_at)) |t| std.fmt.bufPrint(&fbuf, "filed {s}", .{ago(&filed, app.epoch, @intCast(@max(1, t)))}) catch "" else "";
    const claimed_text = if (card.claimedAt()) |t| std.fmt.bufPrint(&cbuf, "held {s}", .{ago(&claimed, app.epoch, @intCast(@max(1, t)))}) catch "" else "";
    const items = [_]struct { label: []const u8, lead: color.RGB, words: color.RGB, filled: bool }{
        .{ .label = if (card.repo) |repo| repo else "no repo", .lead = mark.hue, .words = mark.hue, .filled = false },
        .{ .label = if (high) "● high" else if (low) "○ low" else "◉ med", .lead = if (high) r.failed else r.dim, .words = r.text, .filled = false },
        if (state) |s| .{ .label = s.label, .lead = s.lead, .words = s.words, .filled = s.filled } else .{ .label = @tagName(card.status), .lead = r.dim, .words = r.text, .filled = false },
        .{ .label = if (card.model) |m| modelName(m) else "", .lead = r.dim, .words = r.text, .filled = false },
        .{ .label = held, .lead = r.dim, .words = r.text, .filled = false },
        .{ .label = handed, .lead = r.dim, .words = r.text, .filled = false },
        .{ .label = filed_text, .lead = r.dim, .words = r.text, .filled = false },
        .{ .label = claimed_text, .lead = r.dim, .words = r.text, .filled = false },
    };
    for (items) |item| {
        if (item.label.len == 0 or at + cellCount(item.label) + 2 > end) continue;
        at += @as(u16, @intCast(try bench.chipInk(w, r, at, y, item.label, item.lead, item.words, item.filled))) + 1;
    }
}

/// Seconds as a stage's time reads: `4s`, `1m 58s`.
fn took(buf: []u8, secs: i64) []const u8 {
    const s = @max(0, secs);
    return (if (s < 60) std.fmt.bufPrint(buf, "{d}s", .{s}) else std.fmt.bufPrint(buf, "{d}m {d}s", .{ @divFloor(s, 60), @mod(s, 60) })) catch "";
}

/// The gate's modal: ticket `id`'s last run as a row a stage with its mark, its result and its
/// time, then under a rule the output of the first stage that failed, else the review's verdict,
/// and last what is queued behind it. `scroll` rows down the output.
fn gateBox(app: *App, w: *Writer, id: u32, scroll: usize) !void {
    const rect = app.modalRect() orelse return;
    const inner = app_mod.detailWidth(app.boardW()).inner;
    app.grab.window(.{ .x = rect.x + 2, .y = rect.y + 1, .w = inner, .h = rect.h -| 2 });
    const bottom = rect.y + rect.h;
    var title_buf: [32]u8 = undefined;
    const title = std.fmt.bufPrint(&title_buf, " gate · #{d} ", .{id}) catch " gate ";
    if (rect.w < cellCount(title) + 3) return;
    const edge = ink(app, "amber", 4);
    const dim = ink(app, "dim", 8);
    var pen: Pen = .{};
    const run = app_mod.gateLastRun(if (app.detail.items.len > 0) app.detail.items else "");
    var y = rect.y + 2;
    var output = app_mod.gateOutput(run);
    for (app_mod.gate_stages) |name| {
        var line_buf: [256]u8 = undefined;
        var dur_buf: [16]u8 = undefined;
        const stage = app_mod.gateStage(run, name);
        const mark: []const u8, const style: vt.Style = if (stage) |s| blk: {
            if (std.mem.eql(u8, s.result, "failed") or std.mem.eql(u8, s.result, "error")) break :blk .{ "✗", ink(app, "emberdim", 1) };
            if (s.end == null) break :blk .{ "◒", ink(app, "amber", 4) };
            break :blk .{ "✓", .{} };
        } else .{ "·", dim };
        const dur = if (stage) |s| (if (tickets.epochOf(s.start)) |from| took(&dur_buf, (tickets.epochOf(s.end) orelse app.epoch) - from) else "") else "";
        const result = if (stage) |s| s.result else "";
        const head = std.fmt.bufPrint(&line_buf, "{s} {s: <8} {s}", .{ mark, name, result }) catch name;
        const room = inner -| (cellCount(dur) + 1);
        var row: [320]u8 = undefined;
        var out: Writer = .fixed(&row);
        const shown = clip(head, room);
        out.writeAll(shown) catch {};
        for (cellCount(shown)..inner -| cellCount(dur)) |_| out.writeAll(" ") catch {};
        out.writeAll(dur) catch {};
        try boxLine(w, &pen, edge, style, rect.x, y, out.buffered(), inner);
        y += 1;
    }
    var bar: [1024]u8 = undefined;
    var ruler: Writer = .fixed(&bar);
    for (0..inner) |_| ruler.writeAll("─") catch {};
    try boxLine(w, &pen, edge, dim, rect.x, y, ruler.buffered(), inner);
    y += 1;

    var queued: [256]u8 = undefined;
    var q: Writer = .fixed(&queued);
    var waiting: usize = 0;
    if (app.board) |*b| for (b.cards()) |card| {
        const stage = card.stage orelse continue;
        if (card.id == id or !std.mem.eql(u8, stage, "queued")) continue;
        q.print("{s}#{d} {s}", .{ if (waiting == 0) "queued behind it: " else ", ", card.id, card.repo orelse "" }) catch {};
        waiting += 1;
    };
    const last = if (waiting > 0 and y + 1 < bottom) bottom - 1 else bottom;
    if (run.len == 0) output = "…";
    var row_at: usize = 0;
    var lines = std.mem.splitScalar(u8, output, '\n');
    while (lines.next()) |raw| {
        const text = if (std.mem.startsWith(u8, raw, "    ")) raw[4..] else raw;
        var wrapped = app_mod.DetailLines.init(text, inner);
        var any = false;
        while (wrapped.next()) |line| : (row_at += 1) {
            any = true;
            if (row_at < scroll or y >= last) continue;
            try boxLine(w, &pen, edge, .{}, rect.x, y, line, inner);
            try app.grab.row(app.gpa, rect.x + 2, y - 1, line, wrapped.dropped);
            y += 1;
        }
        if (!any) {
            if (row_at >= scroll and y < last) {
                try boxLine(w, &pen, edge, .{}, rect.x, y, "", inner);
                y += 1;
            }
            row_at += 1;
        }
    }
    while (y < last) : (y += 1) try boxLine(w, &pen, edge, .{}, rect.x, y, "", inner);
    if (last < bottom) try boxLine(w, &pen, edge, dim, rect.x, last, q.buffered(), inner);
    try modalFrame(app, w, rect, title, if (app.home.?.withdrawing) " W again to withdraw " else " j k scroll ");
}

/// The modal frame every thing opens in: the rounded box at `rect` with its head in the top edge
/// and, in the bottom edge, the open modal's buttons, then `hint`.
fn modalFrame(app: *const App, w: *Writer, rect: App.ModalRect, head: []const u8, hint: []const u8) !void {
    const edge = ink(app, "amber", 4);
    var pen: Pen = .{};
    const right = rect.x + rect.w;
    try pen.set(w, edge, null);
    try w.print("\x1b[{d};{d}H╭─", .{ rect.y + 1, rect.x + 1 });
    try pen.set(w, heading(app), null);
    try w.writeAll(head);
    try pen.set(w, edge, null);
    for (cellCount(head) + 3..rect.w) |_| try w.writeAll("─");
    try w.writeAll("╮");

    const foot = rect.y + rect.h;
    try w.print("\x1b[{d};{d}H╰─", .{ foot, rect.x + 1 });
    for (3..rect.w) |_| try w.writeAll("─");
    try w.writeAll("╯");

    var buttons: [16]App.ModalButton = undefined;
    var end = rect.x + 2;
    for (app.modalButtons(&buttons)) |button| {
        var style = ink(app, "amber", 4);
        style.flags.inverse = true;

        try pen.set(w, style, null);
        try w.print("\x1b[{d};{d}H {s} {s} ", .{ button.y + 1, button.x + 1, button.key, button.label });
        if (button.y == foot - 1) end = button.x + button.width();
    }
    if (end + cellCount(hint) < right) {
        try pen.set(w, ink(app, "dim", 8), null);
        try w.print("\x1b[{d};{d}H{s}", .{ foot, end + 1, hint });
    }
    try pen.set(w, .{}, null);
}

/// Why babylon left done ticket `id`'s Claude running, empty when it says nothing of it.
fn doneNote(app: *const App, id: u32) []const u8 {
    const b = if (app.board) |*b| b else return "";
    for (b.cards()) |*card| if (card.id == id) return if (card.status == .done) card.session_note else "";
    return "";
}

/// The Claudes the picked card can be given to, boxed over the middle of the board, each by its
/// number: its session and what its window is called, dim with why where babylon would refuse it.
pub fn giveBox(app: *App, w: *Writer, id: u32, picked: usize) !void {
    const bw: u16 = @min(app.boardW() -| 4, 64);
    const inner = bw -| 4;
    const x = (app.boardW() -| bw) / 2;
    const edge = ink(app, "amber", 4);
    var pen: Pen = .{};
    var buf: [48]u8 = undefined;
    var y: u16 = 4;

    const title = std.fmt.bufPrint(&buf, " give #{d} to ", .{id}) catch " give to ";
    try pen.set(w, edge, null);
    try w.print("\x1b[{d};{d}H╭─", .{ y, x + 1 });
    try pen.set(w, heading(app), null);
    try w.writeAll(title);
    try pen.set(w, edge, null);
    for (cellCount(title) + 1..bw - 2) |_| try w.writeAll("─");
    try w.writeAll("╮");

    var found: [app_mod.give_rows]App.Agent = undefined;
    const n = app.agents(&found);
    for (found[0..n], 0..) |agent, i| {
        y += 1;
        const why = switch (agent.win.claude) {
            .working => " · mid-turn",
            .waiting => " · waits on you",
            .stalled => " · stalled",
            .none, .background, .done => "",
        };
        var line: [256]u8 = undefined;
        const text = std.fmt.bufPrint(&line, "{s} · {s}{s}", .{ app.sessions.items[agent.session].name, agent.win.label(), why }) catch agent.win.label();
        try pen.set(w, edge, null);
        try w.print("\x1b[{d};{d}H│ ", .{ y, x + 1 });
        try pen.set(w, heading(app), null);
        try w.print("{d}  ", .{i + 1});
        try pen.set(w, if (i == picked) chip(app) else if (why.len > 0) ink(app, "dim", 8) else .{}, null);
        try fitted(w, text, inner -| 3);
        try pen.set(w, edge, null);
        try w.writeAll(" │");
    }
    if (n == 0) {
        y += 1;
        try boxLine(w, &pen, edge, .{}, x, y, "no Claude is running", inner);
    }
    y += 1;
    try boxLine(w, &pen, edge, ink(app, "dim", 8), x, y, "its number gives, or jk and ⏎ · esc puts it away", inner);
    y += 1;
    try pen.set(w, edge, null);
    try w.print("\x1b[{d};{d}H╰", .{ y, x + 1 });
    for (0..bw - 2) |_| try w.writeAll("─");
    try w.writeAll("╯");
}
