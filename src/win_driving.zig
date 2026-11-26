const std = @import("std");
const color = @import("color.zig");
const theme = @import("theme.zig");
const bench = @import("parts.zig");
const app_mod = @import("app.zig");
const tickets = @import("board.zig");
const sheets = @import("plan.zig");
const draw = @import("draw.zig");
const App = app_mod.App;
const Writer = std.Io.Writer;
const clip = draw.clip;
const cellCount = draw.cellCount;
const goalHue = draw.goalHue;
const goalChips = draw.goalChips;
const stepChip = draw.stepChip;

pub fn paint(app: *App, w: *Writer, r: theme.Roles, sheet: *const sheets.Sheet, at: usize, y: u16, x0: usize, ww: usize, lit: bool) !void {
    const b = &app.board.?;
    const given = b.plan().?;
    const row = sheet.rows[at];
    const picked = lit and app.planRowLit(row);
    const mark = if (app.columnFocused()) r.dim else r.accent;
    const bg = if (picked) r.raised else r.panel;
    const room = ww - 4;
    switch (row.kind) {
        .focal => {
            const goal = given.goals[row.item];
            const hue = goalHue(b, r, goal);
            {
                try bench.fill(w, x0, y, ww, bg);
                if (picked) try bench.say(w, x0, y, "▌", mark, bg, true);
                try bench.say(w, x0 + 1, y, "▌", hue, bg, false);
                switch (row.part) {
                    1 => {
                        const shares = try goalChips(w, r, b, goal, x0 + ww, y);
                        try draw.sayCut(w, x0 + 2, y, goal.name(), room -| shares, r.text, bg, true);
                    },
                    2 => {
                        try draw.goalBar(w, r, x0 + 2, y, ww -| 4, goal, hue, bg, r.dim, "", r.dim);
                    },
                    else => {
                        try bench.say(w, x0 + 2, y, "now", r.dim, bg, false);
                        var x = x0 + 6;
                        var flying: usize = 0;
                        for (goal.steps) |step| flying += @intFromBool(sheets.inFlight(step));
                        var shown: usize = 0;
                        for (goal.steps) |step| {
                            if (!sheets.inFlight(step)) continue;
                            if (x + 20 > x0 + ww) break;
                            if (shown > 0) {
                                try bench.say(w, x, y, "─▶ ", r.dim, bg, false);
                                x += 3;
                            }
                            x += try stepChip(w, r, x, y, step);
                            shown += 1;
                        }
                        if (shown < flying) {
                            var buf: [16]u8 = undefined;
                            try bench.say(w, x + 1, y, std.fmt.bufPrint(&buf, "+{d} more", .{flying - shown}) catch "", r.dim, bg, false);
                        }
                    },
                }
            }
        },
        .drove => {
            try bench.fill(w, x0, y, ww, bg);
            try bench.say(w, x0 + 1, y, "▌", r.accent, bg, false);
            switch (row.part) {
                1 => {
                    if (picked) try bench.say(w, x0, y, "▌", mark, bg, true);
                    try bench.say(w, x0 + 2, y, clip(row.text, room), r.text, bg, true);
                },
                2 => try bench.say(w, x0 + 2, y, row.text, r.dim, bg, false),
                else => {
                    const need = sheets.driveLanded(given, b).?;
                    var x = x0 + 2;
                    for (0..need.actions.len + 1) |i| {
                        var lbl: [96]u8 = undefined;
                        const label = sheets.driveButton(&lbl, need, i);
                        if (x + cellCount(label) + 2 > x0 + ww) break;
                        x += try bench.chipInk(w, r, x, y, label, if (i == need.actions.len) r.accent else r.dim, r.text, false) + 1;
                    }
                },
            }
        },
        else => {},
    }
}

/// `babylon drive N`: the goal Plan drives towards.
pub fn drive(app: *App, epic: u32) !void {
    app.dirty = true;
    try app.send(.ignore, app_mod.captured("babylon drive {d}"), .{epic});
}

/// Button `at` under a landed goal: the drive item's action run as babylon gave it, or
/// `+ a new goal` one past them. Nothing when no goal has landed.
pub fn answer(app: *App, at: usize) !void {
    const b = &app.board.?;
    const need = sheets.driveLanded(b.plan().?, b) orelse return;
    app.dirty = true;
    if (at == need.actions.len) return app.openGoal();
    if (at > need.actions.len) return;
    const argv = need.actions[at].argv orelse return;
    _ = try app.runNeed(need.id, argv);
}

/// The pick on the landed goal's row, above its `+ a new goal`.
pub fn pick(app: *App) void {
    var sheet: sheets.Sheet = undefined;
    if (!app.planSheet(&sheet)) return;
    for (sheet.rows[0..sheet.n]) |row| {
        if (row.kind != .drove or row.part != 1) continue;
        app.home.?.plan_pick = row.pick orelse continue;
        app.dirty = true;
        return;
    }
}

/// A click on the buttons row under a landed goal.
pub fn click(app: *App, m: anytype) !void {
    const b = &app.board.?;
    const need = sheets.driveLanded(b.plan().?, b) orelse return;
    const button = sheets.driveButtonAt(need, app.planRect(.driving).x, m.x) orelse return;
    return answer(app, button);
}

/// A click on the title bar: with a goal in focus and none landed, drives it.
pub fn titleClick(app: *App) !bool {
    const given = app.board.?.plan().?;
    if (sheets.driveLanded(given, &app.board.?) != null) return false;
    const at = sheets.focalGoal(given) orelse return false;
    try drive(app, given.goals[at].epic);
    return true;
}

/// The driving window's title-bar extra: the focal goal's epic and doc, after the title.
pub fn frame(app: *App, w: *Writer, r: theme.Roles, rect: sheets.Rect, ww: usize, bar: color.RGB) !void {
    const given = app.board.?.plan().?;
    if (sheets.driveLanded(given, &app.board.?) != null) return;
    const at = sheets.focalGoal(given) orelse return;
    const goal = given.goals[at];
    var buf: [160]u8 = undefined;
    const text = std.fmt.bufPrint(&buf, "epic #{d}{s}{s}", .{ goal.epic, if (goal.doc != null) " · " else "", goal.doc orelse "" }) catch "";
    const gap = rect.x + 6 + cellCount(sheets.drivingTitle(given, &app.board.?));
    const shown = clip(text, rect.x + ww -| gap -| 9);
    try bench.say(w, gap, rect.y, " ", r.dim, bar, false);
    try bench.say(w, gap + 1, rect.y, shown, r.dim, bar, false);
    try bench.say(w, gap + 1 + cellCount(shown), rect.y, " ", r.dim, bar, false);
}
