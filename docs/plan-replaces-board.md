# Plan replaces the board

This design is for #883. It follows [the principles](principles.md), including #887's rule that
nothing jumps or changes size. It builds on [Home is the plan](plan-view.md),
[to try](to-try.md) and [goals from an idea](goals-from-an-idea.md). The human approved it as drawn
on 2026-11-24 (ask #40, "looks good"). Nothing in it is built yet. The build is epic #896, the
tickets at the end.

The human, 2026-11-24, looking at Plan: "I don't think we need the board view any more the plan
view covers it all really. might just need to add a couple missing things to the plan view like
collapsible sections and hover and stuff". And later: "might be nice to highlight a little better
which ticket/plan is attached to which repo/workspace too". And for #887: "not a huge fan of things
like jumping around/changing size".

## Every board feature, and where it goes

The board today is `boardKey`, `boardMouse`, `cardActions` and `modalKey` in `src/app.zig`, and its
drawing in `src/draw.zig`.

| the board's | on Plan | |
| --- | --- | --- |
| **columns** todo · doing · review · recent (done) | todo → **not planned**; doing → **now**; review → **landing**; done → **landed** | every status has a window |
| backlog (`r` past the last repo, the `backlog` tab) | **not planned**'s `backlog` chip | same rows, `t` to todo |
| repo groups in a column, folded with `z` / `Z` and a heading click (#849) | **not planned**'s repo chips: each one opens or folds its repo's rows, saved as #849's folds are | the other windows are short enough that they don't need repo groups |
| `r` cycle repo, the `every · arena · …` tabs | `r` on Plan narrows **every** window to one repo, and the head says which. `r` again goes to the next repo | |
| `/` find, `esc` clears | `/` on Plan: the find line at the foot. Rows that don't match go dim and the pick skips them. Rows are dimmed, never removed, so nothing moves | |
| `h` `l` between columns, `j` `k` along one | `h` `l` go to the window beside, `j` `k` go along a window, and `J`/`K` from #619 stay for next | as today on Plan, plus `h` `l` |
| `⏎` go (to the holder's pane, or start a free todo card) | `⏎` on any ticket row | |
| `space` the card's modal (body, ask, proposal, checks, gate) | `space` on any ticket row, **the same modal** | the modal is not changed |
| `e` edit, `p` priority, `>` close, `<` reopen, `t` to todo | the same keys on any ticket row they apply to | `cardActions` is the one source |
| `G` give, and its list of Claudes | the same on a todo or stalled row | |
| `H` hand off (#832) | the same on a now row | |
| `w` / `W` add to next | the same on a not planned row | |
| `J` `K` move along the column (`babylon move`) | on a not planned row: move it in its repo's order. On next: move it in next (#619, as today) | the same verb, the row's own list |
| `a` answer, `x` no (on a card with an ask or proposal) | in the card's modal, as today. Your move already lists every ask and proposal | dropped as row keys on Plan, because `x` on next means "take out of next" |
| `P` the oldest proposal | `]` gets there: Your move puts it first | **dropped** |
| `A` auto, `g` gate, `o` orchestrator, `` ` `` fold the side, `?` keys | the same keys on Plan (all but `g` already work there) | |
| `+` new ticket | `+` adds to the window the pick is in: in **not planned** a ticket (its `+ new` button), anywhere else a goal (#818) | `n` (the inbox) is dropped: `]` does it, and `n` is ✗ on a to-try row |
| **hover peek** on a card (the Claude holding it, live) | the same peek on any ticket row: the pointer rests on it, or the pick rests after a key | |
| the picked card's box of action buttons | Workbench buttons on the picked row, on its second line | clicks for every key, per [principle 7](principles.md) |
| **drag** between columns (todo↔backlog, todo→done, done→todo) | dropped | the keys do the same thing (`t`, `>`, `<`). A drag across windows would have to aim at another window, and nothing on Plan lines up for that |
| drag a card onto the `b plan` tab (to next) | dragging a not planned row onto **next** | |
| epics along the top as slim bars | **goals**, as today | |
| to-try cards top the done column (#842, #877) | **Your move** only: its card has the checks and `y` / `n`; landed does not pin them | |
| the ▲ proposed chip on a card, clicked to Your move | the row's `▲` chip, clicked to Your move | |
| `arena board N` (opens the board on a ticket) | `arena plan N`: Plan with the pick on N, opening its window if it is folded. `arena board N` stays as an alias for one release, then is removed | |
| `B`, the `b plan · B board` tabs (#811), `▤ board` at the top of the rail | **removed**. The rail's top row reads `◆ home`. The head's tabs become one title, `◆ plan` | |

Nothing the board does is lost except: `P` (`]` does it), `a`/`x` as row keys (the modal has them),
and dragging between columns (keys do it).

## Plan, at the whole screen (210 cells, Plan 150, the column 60)

Seven windows, each a fixed slot. The layout is worked out from the screen's size, not from what
the windows hold, so a window never grows, shrinks or moves when its content changes or when it
is folded. A window holding more rows than fit scrolls inside itself. That is #887's rule.

```
 ◆ plan   every · arena · babylon · tlon · …   / find                     auto ▐●▌ 3/4   ◒ landing 4   ✓ 23 today   ▲ 3
┌─ ◆ DRIVING TOWARDS · your pick ─────────────────────────────────────────────────────────────────────────── ▾ ─┐
│ #326 The board, redesigned: an app, not a terminal dump      ▌>_ arena 11/14  ▌⌂ tlon 2/4        ██████████▒▒▒ 13/18 │
│ now ▌◐ #760 building ▐ ▲ asks you ▌ ──▶ ▌✗ #338 sent back ──▶ ▌○ #346 waits #760                       + 2 to file │
└──────────────────────────────────────────────────────────────────────────────────────────────────────────────────┘
┌─ ◆ now │ 3 ────────────────────────────────── ▾ ┐ ┌─ ◆ goals │ 4 ─────────────────────────────── + goal ▾ ┐
│▌>_ #760 Visual redesign: a GUI in the TUI    ◐ 21m │ │▌#326 The board, redesigned        13/18  72% │
│▌   ▐ arena:2 · %1626 ▌ space open  ⏎ go  H hand off│ │ ██████████████████▒▒▒▒▒▒   ▌>_ 11/14 ▌⌂ 2/4 │
│▌>_ #757 A click on the board turned auto…    ◐ 33m │ │ next ◐ #760 building   blocked #346 ← #760   │
│▌☗  #588 babylon start N            ◇ stalled idle 9m│ │▌#500 The orchestrator is the front door 9/12│
│                                                    │ │ ████████████████▒▒▒▒▒   ▌>_ 6/8  ▌☗ 3/4    │
├─ ◆ landing │ 4 ─────────────────────────────── ▾ ┤ │ ── ideas 2 ─────────────────────────────────  │
│▌>_ #587 The seams: one session-state hook  gate 18m│ │ ◐ #830 money on the desktop bar   planning 4m │
│▌>_ #591 zig test runs through menard   reviewing 9m│ │ ○ #829 asterion learns the garden   idea 2d   │
│▌⌂  #501 _got bumps done_week…          » queued 1st│ ├─ ◆ not planned │ 21 ────────── + new ▾ ┤
│▌☗  #590 Restarts become a Your move…   » queued 2nd│ │ ▐>_ arena 11 ▌ ☗ babylon 3  ⌂ tlon 4  ✎ 2  ⌸ 1 │
├─ ◆ next │ 5 ────────────────────────────────── ▾ ┤ │                 backlog 4 · 9 follow-ups      │
│ 1 ▌>_ #761 arena crashes with integer overflow  lane│ │▌>_ #346 Board 13: / finds cards  ○ ← #760    │
│        the crash leaves your shell full of mouse… │ │▌>_ #295 A Claude whose turn ended on an…  med │
│ 2 ▌⌂  #612 Money: a safe-to-spend-per-day   ready │ │▌>_ #321 README still describes the old c… low │
│        high, two days old, nothing blocks it      │ │▌>_ #322 A held card that asks or is sen…  med │
│ 3 ▌>_ #346 Board 13: / finds cards        ← #760  │ │                                   ↓ 7 more   │
│ 4 ▌☗  #590 Restarts become a Your move    ← #588  │ ├─ ◆ landed │ 23 today ──────────────── ▾ ┤
│ 5 ▌✎  #433 The bar says ▲ N and opens arena's…  ready│ │▌⌂ ✓ #825 house soak day                    2h │
│                                                    │ │▌>_ ✓ #632 Plan's head reads auto once    29m │
│                                                    │ │▌>_ ✓ #754 Folds survive a restart         50m │
│                                                    │ │▌⌂  ✓ #457 Money notices show the amount   1h │
└────────────────────────────────────────────────────┘ └───────────────────────────────── ↓ 19 more ─┘
 NORMAL  ⏎ go  space open  e edit  p priority  H hand off   │   j k pick  h l window  z fold  / find  r repo   │   ? keys
```

`▌` at a row's start is drawn in its repo's colour (see [Repo identity](#repo-identity)), and the
glyph after it is the repo's icon. The mockup shows the picked row on `#760` with its buttons.

### Piece by piece

1. **The head.** `◆ plan` (it is the only view now, so there are no tabs), then the repo filter
   (`every` lit, or the one repo `r` narrowed to; a click picks one), then `/ find`. Then auto, the
   pipeline, today's landings and `▲ N`, as today.
2. **Driving towards**: as #821 has it, plus each repo's chip with its share of the steps.
3. **Now**: only the tickets a Claude is building (the board's doing column). A held row shows its
   workspace chip on its second line when picked (`▐ arena:2 · %1626 ▌`, see
   [Workspace link](#workspace-link)). Stalled rows stay here, marked `◇`.
4. **Landing**: the review column. One row per ticket in the pipeline, with babylon's stage
   (`queued` with its place, `verifying` for the gate, `reviewing`, `landing`) and how long it has
   been in it. Rows of one stage no longer fold together, because the window scrolls instead.
   `⏎` and `space` open the gate's modal for its run (`t` in it goes to the ticket's modal), as a
   pipeline row on now does today. Stages come from babylon's `stage` and `stage_at` (#614), so
   this needs nothing new from babylon.
5. **Next**: as today (#618, #619).
6. **Goals**: as today, with ideas (#819) under their rule. A goal spanning repos shows one chip
   per repo with landed/total of its steps there.
7. **Not planned**: the todo column. Its top row is the repo chips, each with its count, then
   `backlog N` and the follow-up count. A chip is lit when its repo's rows are open (#849's fold,
   the same `folded` file). A click or `⏎` on a chip folds or opens it, and `Z` on a chip opens
   only that repo. Under the chips, the open repos' todo rows in babylon's order, each with its
   priority on the right and `← #N` when blocked. The `backlog` chip shows backlog rows in its
   place, as the board's backlog tab did.
8. **Landed**: today's landings newest first, `✓` with how long ago. `<` reopens a row. A to-try
   ticket shows in Your move only (#843), where its card has the checks and `y` / `n`.

## Folding

`z` folds the window the pick is in, and a click anywhere on its title bar does the same. A folded
window keeps its slot. Its body shows a one-line summary in place of its rows:

| window | its summary |
| --- | --- |
| driving towards | the title and the bar |
| in flight | `◐ 3 building · ◒ verifying 1 · reviewing 1 · queued 2` |
| next | the numbers and the tickets, one line: `1 #761 · 2 #612 · 3 #346 …` |
| goals | each goal's number and percentage |
| not planned | its chip row |
| landed | `✓ 23 today` |

**Why a fold doesn't hand its rows to the next window:** #887's rule. If a fold gave its space away,
every window under it would move. Folding is for quieting a window, not for making room. When a
list needs the whole height, `f` opens it as a modal over Plan
with the list whole, with the same keys on its rows. It is a look, so nothing behind it
moves ([principle 5](principles.md)).

`Z` folds every window but the picked one, and `Z` again opens them all. Folds are saved in
`$XDG_STATE_HOME/arena/folded` beside #849's repo folds, one `plan:<window>` line each. Arena
already reads that file at start, so folds survive a restart and #855's in-place restart.

## Any ticket row is a card

Every row that is one ticket (now, landing, next, not planned, landed, and a goal's steps in the
epic's modal) acts as the board's card did:

- **The keys** are `cardActions(card)`, unchanged: the row has the actions its card has.
  `⏎` go/start, `space` the modal, `e` edit, `p` priority, `G` give, `H` hand off, `>` close,
  `<` reopen, `t` to todo, `w`/`W` to next. `J` `K` move it in its own list. Next keeps `x`
  (out of next) and `e` (its why), as #619 has it. On a next row, `e` edits the why, and the
  ticket's own edit is in its modal.
- **The buttons.** The picked row grows no taller. Its second line, which every Workbench row
  already has for its chips, shows the buttons on raised, the primary in amber. A row with no
  second line (landed, not planned) gets one only while picked, inside its window's scroll. That is
  movement inside the window, which #887 allows, and the window's frame stays put.
- **The foot bar** names the picked row's keys, with the first group from `cardActions`
  ([principle 1](principles.md)).
- **The hover peek** is the board's peek. `peekOf` already takes a card, and a Plan row gives it its
  card, so the pointer resting on a row (or the pick after a key) shows the holder's live pane.
  Like any peek, it draws over everything and moves nothing.

## Repo identity

Today a repo shows as a small icon at the row's start, in a colour, and it is easy to miss. It
becomes the row's left edge:

- **Every ticket row starts `▌` in the repo's colour, then the repo's icon** (`>_` arena,
  `☗` babylon, `⌂` tlon, `✎` ficciones, `⌸` menard: the icons the rail already draws). The bar runs
  the row's full height, its second line included, so a window reads as stripes of colour at a
  glance. The picked row's accent box sits just inside the bar.
- **Chips** for a repo (filters, a goal's shares, not planned's groups) are `▐icon name N▌` on raised,
  with a lead bar in the repo's colour, as Workbench's chips already are.
- **The rail**: each session group's heading gets the same `▌` in its repo's colour, and each
  Claude's mark under it does too.
- **The pane frame**: arena sets a Claude's pane's border to its repo's colour
  (`set -p pane-border-style fg=…`) when the pane is claimed, so the Claude you are typing to wears
  the colour of its row.
- **babylon and "you" are both violet today** (theme.zig: `repo = {amber, violet, …}` and
  `you = violet`). The ask chip and babylon's rows look alike. **Proposed:** babylon takes `BLUE`
  from the palette (or a new `INDIGO` if `BLUE` reads too close to cyan), and violet means "you"
  only, as board-design.md already says it should.

## Workspace link

The rail groups sessions into workspaces (`arena`, `babylon-work`, `tlon`, …). A held row says which
workspace and window hold its Claude:

- **The chip** `▐ arena:2 · %1626 ▌` shows on a held row's second line: the session (workspace)
  name, the window, and the pane. Its lead bar is in the workspace's repo colour. A click goes there
  (`showPane`), the same as `⏎`.
- **How a workspace is tied to a repo when the names differ:** arena already knows each pane's
  working directory. A session's repo is the repo of its first Claude's worktree
  (`~/projects/babylon/.worktrees/...` → babylon). It is not taken from the session's name, so
  `babylon-work` is babylon's and wears babylon's colour on the rail and on the chip. A session whose
  Claudes are in different repos (rare) takes the colour of the repo most of them are in, and each
  Claude's mark keeps its own.
- The peek on a held row also names the workspace in its title (`%1626 · arena:2`).

## At half the screen (105 cells)

Home shows Plan or the column, swapped with `o` / `p` (#527). Plan at 105 cells is one column of
windows: driving towards, in flight, next, not planned, landed, goals. Each slot gets a fixed
share of the height: in flight and landed get 4 rows each, and next and not planned split the
rest. Fold, scroll and the modal work as above. This is the same set of windows stacked
differently, with no second design to keep.

## Removing the board

Last, once everything above has landed:

- `B`, the `b plan · B board` tabs (#811), `toBoard`, `boardKey`, `boardMouse`'s card handling, the
  column layout (`boardColumn`, `boardWidths`, lanes, strips), the epic bars, the board's
  drawing in draw.zig and mock.zig, and `BoardView`'s board-only fields are **deleted**, not
  hidden. `board_view` stays, renamed to `home` in its own small commit, since Plan and its modals
  live in it.
- The rail's top row: `▤ board` becomes `◆ home`, keeping its counts and its click.
- `b` (home) and Plan stay.
- e2e: every step that drives the board is rewritten to drive Plan's matching window (the list
  below). Board-only steps (column widths, lanes, drag between columns, `r` to backlog) are
  removed along with the code.
- README and screenshots: `docs/screenshots/board.png` is removed and `plan.png` is taken again.
  board-design.md gets a line at its top: superseded by this doc for the board itself, with its
  Workbench look still in force.

### The e2e steps that move

`test/e2e.zsh` drives the board in about 120 checks. They move as follows:

| board checks about | become checks on |
| --- | --- |
| `⏎` on a card (start, refused start, go to holder) | `⏎` on a not planned / now row |
| `space` modal, asks, proposals, gate modal, `g` | the same modal, opened from a row |
| `G` give, `H` hand off, `e`, `p`, `>`, `<` | the same keys on a row |
| `/` find, `w` why at the foot | `/` and `w` on Plan |
| `A` auto, `o` orchestrator, `]` `[`, Alt+h/l focus | the same, from Plan |
| the header's buttons (`● orch`, gate, auto switch) | Plan's head |
| `▤ board` at the top of the rail | `◆ home` |
| `arena board N` | `arena plan N` |
| `z` / `Z` repo folds | not planned's chips |
| column widths, lanes, strips, drag between columns | removed with the code |

## The build

All arena. Each is a specified Sonnet ticket and lands on its own. Each is blocked by the one before it,
except where noted.

1. **Repo identity (#897).** The row's `▌` edge and icon on every Plan row, chips with lead bars, the
   rail's group headings, and babylon off violet. Free.
2. **Folding windows in fixed slots (#898).** Layout from screen size alone, scrolling inside each window, `z`, `Z`,
   a click on the title bar, the summaries, `f` for a window whole as a modal, and `plan:` lines in
   `folded`. Free.
3. **Rows are cards (#899).** `cardActions` on every ticket row, the buttons on the picked row's second line,
   the foot bar, and the hover peek. After 2.
4. **In flight (#900).** Now and landing as one window, a row to each pipeline stage, and the gate's modal
   from them. After 2.
5. **Not planned is the todo list (#901).** Chips, #849's folds, the rows, backlog, `J` `K`, `w` `W`, `+ new`
   (and `+` in that window), and dragging a row onto next. After 3.
6. **Landed: today's landings (#902).** A row to each, newest first, with how long ago; to try stays in Your move. After 3.
7. **The board's tools on Plan (#903).** `/` find, `r` repo filter in the head, `h` `l` between windows,
   `g`, and `arena plan N`. After 3.
8. **Workspace link and pane frames (#904).** The workspace chip, tying a session to a repo by its Claudes'
   worktrees, the rail's colours, and the pane border. After 1 and 3.
9. **Plan at half the screen (#905)** as one column of slots. After 4, 5 and 6.
10. **The e2e moves to Plan (#906).** Every board step that has a Plan equivalent is rewritten to drive Plan,
    with the board still there. After 5, 6 and 7.
11. **Remove the board (#907).** Delete it, `◆ home` on the rail, `arena board N` as an alias, the README and
    screenshots. After 8, 9 and 10.
