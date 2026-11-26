# Doing and Planning

This design is for #1111, step 1 of #1110. It follows [the principles](principles.md) and
[No rail](no-rail.md), and it builds on #1109, which opens everything from Plan in one middle
column. Nothing in it is built yet.

The human, 2026-11-26: "for the landed goal one, i was thinking maybe we split out like doing and
planning if that makes sense. the backlog (not planned is a dumb name they are planned just not in
a goal or whatever right?) so we have a screen for like managing tickets, putting them in goals or
whatever and making new ones, and then the current Plan screen shows what's being worked on and
the stuff I need to do". On the orchestrator's sketch: "yes Doing and Planning, drive it next".

Plan becomes two screens:

- **Doing** answers "does anything need me, and what is moving?". It is today's Plan with the
  planning taken out: Your move, driving towards, in flight, next and landed.
- **Planning** is where tickets are arranged: goals with their tickets, no goal, the backlog, and
  next. Making a ticket or a goal, moving a ticket into or out of a goal, putting it in next and
  ordering next, and choosing the goal to drive all happen here.

Next is on both. Doing shows it because auto starts from it. Planning shows it because that's
where it is ordered.

## What goes where

| today on Plan | goes to | note |
| --- | --- | --- |
| Your move | **Doing** | as today |
| driving towards: the goal, its bar and its chain of steps | **Doing**, one line: `towards #N title  bar  N/M P%` | the chain is one step away: its peek on hover, the goal's card on `space` |
| driving towards' `1`–`9` buttons under a landed goal, and `+ a new goal` | **removed** | the landed-goal item in Your move opens Planning instead ([Switching](#switching)) |
| in flight and other Claudes | **Doing** | as today |
| next | **both** | on Doing it can be read, opened and started, but not reordered. It is reordered on Planning |
| landed | **Doing** | it gets the right column to itself, so its titles show whole |
| goals, with `+ goal` | **Planning** | each goal now lists its open tickets under it |
| `d` (drive a goal) | **Planning** | |
| not planned | **Planning**, renamed **no goal** | it keeps the todo tickets that are in no goal, with its repo chips |
| not planned's backlog tickets, and the ideas in goals | **Planning's backlog** | ideas, plans being made, drafts, and tickets kept for later |
| `+` on Doing | **removed** | `+` works on Planning only |

## Doing

### At 1920 px (220 × 51)

```
 ◆ [doing]  planning    every · arena · babylon · tlon · …   / find                                                                                                  ◐ auto 4/6   ◆ orch working 12s   ✓ 23 today   ▲ 3   ≡
┌─ ◆ YOUR MOVE │ 3 ───────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────── ▾ ┐
│ ▌>_ ▲ #1029 approve docs/no-rail.md: arena without the side rail                                                                                                                                           asks you   2m │
│ ▌>_ ◆ #896  landed: pick the goal to drive next                                                                                                                                                               ⏎ planning │
│ ▌⌂  ✗ #612  sent back: the gate's money test fails on the first of the month                                                                                                                                         14m │
│                                                                                                                                                                                                                          │
│                                                                                                                                                                                                                          │
└──────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────┘
┌─ ◆ towards #1110 Doing and Planning: Plan splits into a Doing and a Planning screen   ▌>_ 1/5   ████▒▒▒▒▒▒▒▒▒▒▒▒   1/5  20% ────────────────────────────────────────────────────────────────────────────────────────── ▸ ┐
┌─ ◆ in flight │ 6 ───────────────────────────────────────────────────────────────────────────────────────────────────────────── ▾ ┐ ┌─ ◆ landed │ 23 today ──────────────────────────────────────────────────────────── ▾ ┐
│ ▌>_ #1111 Doing and Planning 1: the design doc: each screen's windows, keys and moves                             ◐ building  4m │ │ ✓ #1105 Your move: a picked item says its first key                              2h │
│ ▌>_ #992  Copy text out of arena: drag to select in the ticket modal                                              ◐ building 33m │ │ ✓ #1083 the auto switch reads its cell from one picture                          3h │
│ ▌☗  #588  babylon start N: worktree and branch in one step                                                        ◇ stalled   9m │ │ ✓ #1029 Design: arena without the side rail                                      5h │
│ ▌>_ #904  Plan 8: workspace link: a held row's session·window·pane chip                                           ◒ reviewing 9m │ │ ✓ #612  Money: a safe-to-spend-per-day on the bar                                6h │
│ ▌>_ #940  The orchestrator column holds only your move and the chat                                               » queued 1st   │ │ ✓ #346  Board 13: / finds cards                                                  8h │
│ ▌>_ #901  Plan 5: not planned is the todo list: repo chips with folds                                             » queued 2nd   │ │ ✓ #590  Restarts become a Your move item                                         9h │
│ ── other Claudes 2 ────────────────────────────────────────────────────────────────────────────────────────────────────────────  │ │                                                                                     │
│ ▌⌸  ◐ menard · indexing the repo                                                                                menard:1      4m │ │                                                                                     │
│ ▌✎  ○ ficciones · your shell                                                                                    ficciones:2   1h │ │                                                                                     │
├─ ◆ next │ 5 ────────────────────────────────────────────────────────────────────────────────────────────────────────────────── ▾ ┤ │                                                                                     │
│ 1 ▌>_ #761  arena crashes with integer overflow on a 0-width pane                                                        ready   │ │                                                                                     │
│ 2 ▌⌂  #612  Money: a safe-to-spend-per-day on the bar                                                                    ← #588  │ │                                                                                     │
│ 3 ▌>_ #346  Board 13: / finds cards                                                                                      ready   │ │                                                                                     │
│ 4 ▌☗  #590  Restarts become a Your move item                                                                             ← #588  │ │                                                                                     │
│ 5 ▌✎  #433  The bar says ▲ N and opens arena's inbox                                                                     ready   │ │                                                                                     │
└──────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────┘ └─────────────────────────────────────────────────────────────────────────────────────┘
 NORMAL  ⏎ go  space open  H hand off   │   j k pick  h l window  z fold  tab planning  / find  o orchestrator   │   ? keys
```

(The drawing is shortened in height.) Below the head and above the foot bar, the 49 rows are
fixed slots, worked out from the screen size alone, as `slot()` works them out today:

- **Your move**: full width, its title and five rows, as no-rail set out.
- **Driving towards**: full width, **one row**. It is a window's title bar with no body:
  `◆ towards #1110 title`, the repos' `▌icon N/M`, the bar, then `N/M  P%` right-aligned
  (principle 12). A title too long for the row is cut at a word with `…`. With no goal being
  driven it reads `◆ towards no goal · pick one on planning` (dim).
  - Hover shows its peek: the chain of steps (`✓ #1111 ──▶ ◐ #1112 building ──▶ ○ #1113 …`).
  - `space` or a click opens the goal's card in the middle column.
  - `⏎` opens Planning with the pick on that goal.
- **In flight**, with other Claudes at its foot, and **next** under it: the left three fifths,
  132 cells. In flight takes 3/5 of the height and next 2/5.
- **Landed**: the right 87 cells, the whole height. A 40-cell title fits whole with room to spare.

Next on Doing is one line per ticket, the why on the picked row only, as today. `⏎` starts the
picked ticket now, `space` opens it, and `G` gives it. `J`, `K`, `x`, `p` and dragging, which
reorder next, are Planning's.

### At half width (110 × 51)

One column, top to bottom: Your move (three rows), driving towards (one row), in flight, next and
landed. The three lists split what is left: in flight 2/5, next 3/10, landed 3/10.

```
 ◆ [doing]  planning   every · arena · …   / find                           ◐ auto 4/6   ◆ orch 12s   ▲ 3   ≡
┌─ ◆ YOUR MOVE │ 3 ─────────────────────────────────────────────────────────────────────────────────────── ▾ ┐
│ ▌>_ ▲ #1029 approve docs/no-rail.md                                                          asks you   2m │
│ ▌>_ ◆ #896  landed: pick the goal to drive next                                                 ⏎ planning │
│ ▌⌂  ✗ #612  sent back: the money test fails on the 1st                                                 14m │
└────────────────────────────────────────────────────────────────────────────────────────────────────────────┘
┌─ ◆ towards #1110 Doing and Planning   ████▒▒▒▒▒▒▒▒   1/5  20% ────────────────────────────────────────── ▸ ┐
┌─ ◆ in flight │ 6 ─────────────────────────────────────────────────────────────────────────────────────── ▾ ┐
│ ▌>_ #1111 Doing and Planning 1: the design doc                                              ◐ building  4m │
│ ▌>_ #992  Copy text out of arena: drag to select                                            ◐ building 33m │
│ ▌☗  #588  babylon start N: worktree and branch                                              ◇ stalled   9m │
│ ▌>_ #904  Plan 8: workspace link: a held row's chip                                         ◒ reviewing 9m │
│ ── other Claudes 2 ──────────────────────────────────────────────────────────────────────────────────────  │
│ ▌⌸  ◐ menard · indexing the repo                                                          menard:1      4m │
├─ ◆ next │ 5 ──────────────────────────────────────────────────────────────────────────────────────────── ▾ ┤
│ 1 ▌>_ #761  arena crashes with integer overflow on a 0-width pane                                   ready  │
│ 2 ▌⌂  #612  Money: a safe-to-spend-per-day on the bar                                               ← #588 │
│ 3 ▌>_ #346  Board 13: / finds cards                                                                 ready  │
├─ ◆ landed │ 23 today ─────────────────────────────────────────────────────────────────────────────────── ▾ ┤
│ ✓ #1105 Your move: a picked item says its first key                                                     2h │
│ ✓ #1083 the auto switch reads its cell from one picture                                                 3h │
└────────────────────────────────────────────────────────────────────────────────────────────────────────────┘
 NORMAL  ⏎ go  space open  …   │   j k pick  z fold  tab planning  o orch   │   ? keys
```

## Planning

### At 1920 px (220 × 51)

```
 ◆ doing  [planning]    every · arena · babylon · tlon · …   / find                                                                                                  ◐ auto 4/6   ◆ orch working 12s   ✓ 23 today   ▲ 3   ≡
┌─ ◆ goals │ 3 ────────────────────────────────────────────────────────────────────────────────────────────────────────── + goal ▾ ┐ ┌─ ◆ next │ 5 ───────────────────────────────────────────────────────────────────── ▾ ┐
│ ▾ ◆ #1110 Doing and Planning: Plan splits into a Doing and a Planning screen   ◆ driving             ████▒▒▒▒▒▒▒▒▒▒▒▒   1/5  20% │ │ 1 ▌>_ #761  arena crashes with integer overflow on a…                        ready  │
│     ▌>_ #1111 Doing and Planning 1: the design doc                                                                ◐ building  4m │ │ 2 ▌⌂  #612  Money: a safe-to-spend-per-day on the bar                        ← #588 │
│     ▌>_ #1112 Doing and Planning 2: the Planning screen, read only, and tab                                        ○ ← #1111     │ │ 3 ▌>_ #346  Board 13: / finds cards                                          ready  │
│     ▌>_ #1113 Doing and Planning 3: Planning's moves                                                               ○ ← #1112     │ │ 4 ▌☗  #590  Restarts become a Your move item                                 ← #588 │
│     ▌>_ #1114 Doing and Planning 4: Doing trimmed                                                                  ○ ← #1113     │ │ 5 ▌✎  #433  The bar says ▲ N and opens arena's inbox                         ready  │
│ ▸ #896  Plan replaces the board: every board feature on Plan, then the board removed                 ████████▒▒▒▒▒▒▒▒   8/13 62% │ │                                                                                     │
│ ▾ #500  The orchestrator is the front door                                                           ███████████▒▒▒▒▒   9/12 75% │ ├─ ◆ backlog │ 6 ────────────────────────────────────────────────────────────────── ▾ ┤
│     ▌>_ #1046 The orchestrator's choices become asks in Your move                                                 ◒ reviewing 2m │ │ ◇ #830  Money on the bar: a safe-to-spend-per-day                              idea │
│     ▌☗  #1036 A desktop notice for a Claude that waits                                                            ○ todo         │ │ ◐ #842  tlon: the house on a phone                                     planning  3m │
│     ▌>_ #1048 The drawer remembers where it was scrolled                                                          ○ todo         │ │ ✎ #850  Asterion: a mail filter per sender                                    draft │
├─ ◆ no goal │ 21 ──────────────────────────────────────────────────────────────────────────────────────────────────────── + new ▾ ┤ │ · #712  tlon: a second bathroom on the plan                                   later │
│ ▐>_ arena 11▌  ☗ babylon 3   ⌂ tlon 4   ✎ ficciones 2   ⌸ menard 1                                                               │ │ · #733  babylon: a week view of what landed                                   later │
│ ▌>_ #761  arena crashes with integer overflow on a 0-width pane                                                          next 1  │ │ · #740  arena: a light theme                                                  later │
│ ▌>_ #346  Board 13: / finds cards                                                                                        next 3  │ │                                                                                     │
│ ▌>_ #1058 Copy a ticket's branch name from its card                                                                      todo    │ │                                                                                     │
│ ▌>_ #1052 The help screen lists keys by window                                                                           todo    │ │                                                                                     │
│ ▌>_ #1060 A goal's bar shows what is in review                                                                           todo    │ │                                                                                     │
└──────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────┘ └─────────────────────────────────────────────────────────────────────────────────────┘
 NORMAL  space open  a goal…  w next  > close  e edit  p priority   │   j k pick  h l window  z fold  + new  tab doing  / find  o orchestrator   │   ? keys
```

The same head and foot bar, and the same grid. The left three fifths (132 cells) hold the two
windows whose rows are titles you will act on:

- **Goals**: 3/5 of the height.
  - Each open goal is a header row: a fold mark (`▾` or `▸`), `◆` and the word `driving` on the
    goal being driven, its title, then its bar and `N/M P%` right-aligned.
  - Under an unfolded goal, its open tickets (todo, doing, review, try) are listed one line each,
    indented, in babylon's order. The column on the right says each one's state: `◐ building
    4m`, `◒ reviewing`, `» queued 1st`, `○ todo`, or `○ ← #N` while blocked by #N. A ticket also
    in next says `next K`. Landed steps are counted in `N/M`, not listed.
  - `space` on a goal opens its card in the middle column with every step, landed ones included
    (principle 13).
  - The driven goal is first, then the others in babylon's order. `z` folds and unfolds the goal
    the pick is on, and the folds hold for the session. Folding changes rows inside the window
    only. The window's slot doesn't move (principle 10).
- **No goal**: 2/5 of the height. Today's not planned, renamed: its repo chips, then the todo
  tickets that are in no goal, each in its repo's order (`J` `K` move one up or down that order,
  `babylon move`, as today). Backlog tickets leave this window for the backlog.

The right 87 cells:

- **Next**: 2/5 of the height. The same rows as on Doing. Here it can also be reordered.
- **Backlog**: 3/5 of the height. Ideas first (`◇ idea`, `◐ planning` with its age, `✎ draft`),
  then tickets kept for later (`· later`).

### At half width (110 × 51)

One column, top to bottom: goals 2/5 of the rows, then next, no goal and backlog 1/5 each.

```
 ◆ doing  [planning]   every · arena · …   / find                           ◐ auto 4/6   ◆ orch 12s   ▲ 3   ≡
┌─ ◆ goals │ 3 ──────────────────────────────────────────────────────────────────────────────────── + goal ▾ ┐
│ ▾ ◆ #1110 Doing and Planning   ◆ driving                                           ████▒▒▒▒▒▒▒▒   1/5  20% │
│     ▌>_ #1111 Doing and Planning 1: the design doc                                          ◐ building  4m │
│     ▌>_ #1112 Doing and Planning 2: the Planning screen                                      ○ ← #1111     │
│     ▌>_ #1113 Doing and Planning 3: Planning's moves                                         ○ ← #1112     │
│     ▌>_ #1114 Doing and Planning 4: Doing trimmed                                            ○ ← #1113     │
│ ▸ #896  Plan replaces the board                                                    ████████▒▒▒▒   8/13 62% │
│ ▸ #500  The orchestrator is the front door                                         █████████▒▒▒   9/12 75% │
├─ ◆ next │ 5 ──────────────────────────────────────────────────────────────────────────────────────────── ▾ ┤
│ 1 ▌>_ #761  arena crashes with integer overflow on a 0-width pane                                   ready  │
│ 2 ▌⌂  #612  Money: a safe-to-spend-per-day on the bar                                               ← #588 │
│ 3 ▌>_ #346  Board 13: / finds cards                                                                 ready  │
├─ ◆ no goal │ 21 ────────────────────────────────────────────────────────────────────────────────── + new ▾ ┤
│ ▐>_ arena 11▌  ☗ babylon 3   ⌂ tlon 4   ✎ 2   ⌸ 1                                                          │
│ ▌>_ #761  arena crashes with integer overflow on a 0-width pane                                    next 1  │
│ ▌>_ #1058 Copy a ticket's branch name from its card                                                todo    │
├─ ◆ backlog │ 6 ───────────────────────────────────────────────────────────────────────────────────────── ▾ ┤
│ ◇ #830  Money on the bar: a safe-to-spend-per-day                                                     idea │
│ ◐ #842  tlon: the house on a phone                                                            planning  3m │
└────────────────────────────────────────────────────────────────────────────────────────────────────────────┘
 NORMAL  space open  a goal…  w next  > close  …   │   j k pick  tab doing   │   ? keys
```

## Switching

- **`tab`** (and `shift+tab`) switches between Doing and Planning, from any window of either.
  Neither screen uses `tab` today.
- **The picker in the head**: `◆ doing  planning` at the head's left, in place of today's
  `◆ plan`. The screen you're on wears the accent box (the pick, principle 6), drawn `[ ]` in the
  mocks. A click on the other name switches. Both labels are fixed width, so the head doesn't
  move when you switch.
- **Each screen keeps its own pick, folds and scroll.** Switching back finds the screen as you
  left it. A middle column that is open closes on a switch, because it belongs to what was picked.
- **Home is Doing.** `b`, `Alt+b`, `◆ home` and `arena plan` open Doing, which answers "does
  anything need me?" first. `arena planning [N]` opens Planning, with the pick on #N when given
  (principle 7).
- **The repo filter (`r`) and find (`/`)** narrow both screens the same way. A filter set on one
  screen still holds on the other.
- **The landed goal's item in Your move** reads `◆ #896 landed: pick the goal to drive next`, with
  `⏎ planning` on the right. `⏎` or a click opens Planning with the pick on goals' first row.
  There `d` drives the picked goal, or `+` makes a new one. The item leaves Your move once babylon
  is driving a goal again. Its `1`–`9` buttons and `+ a new goal` are gone.

## Every move on Planning

Every move has a key, a mouse action, and a button on the picked ticket's card in the middle
column (#1109), which shows the key on the button. Every one runs through babylon's command line,
so a script or a Claude can do the same thing (principle 7).

| move | key | mouse | babylon | today |
| --- | --- | --- | --- | --- |
| **new ticket** in no goal | `+` on no goal | `+ new` on no goal's title bar | `babylon new [--repo R]` ($EDITOR in a window) | as today, from not planned |
| **new ticket** in a goal | `+` on a goal or its tickets | `+ ticket` on the goal's card | `babylon new --epic M [--repo R]` | **new: #1115** |
| **new goal** | `+` on goals | `+ goal` on goals' title bar | `babylon idea TEXT --plan` (`⏎ plan it now`) or `babylon idea TEXT` (`k just keep it`), from the `+ goal` modal | as today. It lands in the backlog as an idea, then joins goals when its draft is adopted |
| **ticket into a goal**, **out of one**, or **to another** | `a` opens *into which goal?* in the middle column | drag the row onto a goal's header or one of its tickets, or onto no goal; or `a goal…` on the card | `babylon update N --epic M`, or `--epic none` | **new: #1115** |
| **ticket into next** | `w` (asks why, then at the bottom), `W` (at the top) | drag the row into next where it should go; or `w next` on the card | `babylon next N [--why W]`, `babylon next N --at K` | as today |
| **reorder next** | `J` `K` on a next row | drag within next | `babylon next N --at K` | as today, moved off Doing |
| **out of next** | `x` on a next row | `x drop` on the card | `babylon next N --drop` | as today, moved off Doing |
| **drive a goal** | `d` on a goal | `d drive` on the goal's card | `babylon drive N` | as today, moved off Doing |
| **backlog to todo**: an idea | `⏎` plans it | `⏎ plan` on its card | `babylon idea N --plan` | as today |
| **backlog to todo**: a draft | `space` opens it, `y` adopts | `y adopt` in the draft | `babylon adopt N` (its steps go to todo, and the goal joins goals) | as today |
| **backlog to todo**: a ticket | `t` | `t to todo` on its card | `babylon update N --status todo` (into its goal, or no goal) | as today |
| **close a ticket** | `>` | `> close` on its card | `babylon update N --status done` | as today |
| **drop an idea** | `x` on an idea | `x drop` on its card | `babylon withdraw N` | as today |

The ticket asked for `update_ticket epic_id`. babylon has no such field. Today a ticket's goal is
its `parent` link (`babylon link M parent N`, `babylon unlink M parent N`), and a ticket has at
most one. Moving a ticket from one goal to another would take an unlink and then a link. If the
link failed, the ticket would be left in no goal and nobody would be told. **babylon #1115** adds
`babylon update N --epic M|none` (one transaction), `epic_id` on `update_ticket`, and
`babylon new --epic M`. It blocks step 3 (#1113).

### Into which goal?

`a` on any ticket row (in goals or no goal) opens the picker in the middle column: the open goals,
the driven one first, then `no goal`. The ticket's current place says `✓ here`. `j` `k` move, `⏎`
moves the ticket there, `esc` or `×` cancels.

```
┌─ ◆ #1058 into which goal? ──────────────────────── × ┐
│ ❯ ◆ #1110 Doing and Planning                     1/5 │
│   #896  Plan replaces the board                 8/13 │
│   #500  The orchestrator is the front door      9/12 │
│   no goal                                     ✓ here │
│                                                      │
│ [⏎ move it]  [esc cancel]                            │
└──────────────────────────────────────────────────────┘
```

### Dragging

A drag starts on a ticket row in goals, no goal or next. While it's held, a one-line ghost of the
row follows the pointer, and the window it would drop into has its title lit. Nothing else is
drawn differently, and no row moves (principles 5 and 10). Letting go on:

- a goal's header or one of its tickets: into that goal;
- no goal: out of its goal;
- next, between two rows or over its empty rows: into next at that place, or a reorder if the
  ticket was already in next (as dragging in next works today);
- anywhere else: nothing.

The rows change only when babylon answers and the board is read again, as every move works today.

## What leaves Doing

- the **goals** window, its `+ goal`, and `+` on Doing;
- the **not planned** window (now no goal, on Planning);
- **`d`**, the **`1`–`9` drive buttons** and **`+ a new goal`** under driving towards;
- reordering next: **`J` `K` `x` `p`** and dragging on Doing's next;
- the ideas and backlog tickets that showed in goals and not planned.

## The build

Each step lands on its own and leaves both screens working. They run in this order: the `blocks`
links already chain them, so no two touch the same file at once.

1. **This doc** (#1111).
2. **Planning, read only, and switching** (#1112), after #1109 and this doc.
   - A `doing | planning` screen on the home view, with its own pick, folds and scroll for each.
   - `tab`, the head's picker, and `arena planning [N]`.
   - `plan.zig`: `Window` gains `backlog`, `unplanned` becomes `no_goal` titled `no goal`, and
     `slot()` takes the screen. Doing's slots lose goals and not planned, and landed takes the
     right column.
   - `win_goals.zig` lists each goal's tickets under it. `win_unplanned.zig` becomes no goal
     without the backlog rows. A new `win_backlog.zig` takes the ideas and backlog tickets.
     `win_next.zig` draws on both screens.
   - Keys bound to a row's kind follow the row to Planning as they are (`d`, `+`, `t`, next's
     `J` `K`). This step adds no moves and removes none.
   - `src/mock.zig` gains the Planning screen, for the screenshots.
   - Touches `plan.zig`, `draw.zig` (the head), `app.zig` (the screen, `tab`, the picker's
     click), `main.zig` (the verb), `win_goals.zig`, `win_unplanned.zig`, `win_backlog.zig`,
     `mock.zig`.
3. **Planning's moves** (#1113), after #1112 and babylon #1115.
   - `a` and the *into which goal?* column, dragging between windows, `+` in a goal, and each
     card's buttons, as in [Every move on Planning](#every-move-on-planning).
   - `d` and `+` work on Planning only. Next's reorder keys and its drag leave Doing.
   - The landed goal's Your move item opens Planning. The `1`–`9` buttons and `+ a new goal`
     under driving towards are removed (`win_driving.answer`).
   - Touches `app.zig` (the keys and the mouse), `win_goals.zig`, `win_unplanned.zig`,
     `win_next.zig`, `win_move.zig`, `win_driving.zig`.
4. **Doing trimmed** (#1114), after #1113.
   - Driving towards becomes one row, with its chain in the peek and the goal's card.
   - In flight and next keep the left three fifths. Landed gets the right column.
   - Other Claudes' rows show their whole name, cut with `…` only at the edge (#1106's item 1).
   - Touches `plan.zig` (`slot()`'s driving height), `win_driving.zig`, `win_now.zig`,
     `win_landed.zig`.

`plan.zig` is touched in steps 2 and 4, and `win_driving.zig` in steps 3 and 4. Both pairs are
already in order through the chain.
