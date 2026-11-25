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
                        try bench.say(w, x0 + 2, y, clip(goal.title, room -| shares), r.text, bg, true);
                    },
                    2 => {
                        var buf: [32]u8 = undefined;
                        const label = std.fmt.bufPrint(&buf, "{d}/{d} landed", .{ goal.landed, goal.total }) catch "";
                        const bar_w = ww -| 5 -| cellCount(label);
                        try bench.bar(w, r, x0 + 2, y, bar_w, goal.landed, goal.total, hue);
                        try bench.say(w, x0 + 3 + bar_w, y, label, r.text, bg, false);
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
            try bench.say(w, x0 + ww, y, "▌", r.well, r.ground, false);
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
