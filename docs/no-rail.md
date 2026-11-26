# No rail

> Partly superseded by [What arena is](what-arena-is.md). These parts are replaced: `⏎` on an in
> flight row, an other Claudes row or a `waits in its pane` item now opens that Claude's pane in
> the middle column, not its window on the strip. The pane view is the human's own terminal,
> reached only from the switcher. The drawer has no next buttons: the orchestrator's suggestions
> are Your move rows. The 1920 px home is Doing's. The rest stands.

This design is for #1029, a step of #896. It follows [the principles](principles.md) and
[Plan replaces the board](plan-replaces-board.md) with #905's amended rules (one place per ticket,
in flight as one window, width goes to rows with titles). Nothing in it is built yet.

The human, 2026-11-25, looking at the rail beside Plan and at Plan's hover card: "kinda a
revelation maybe but do we even need the side rail? If I can hover and then space to do this
probably don't need to have the whole siderail thing? are we doing too much and not enough at the
same time?" And then: "yes, cut the rail and design it".

Today the same Claudes are drawn three times: in the rail's agents, in Plan's in flight, and in
the orchestrator column's building strip (which #940 removes). The hover card already shows what
an agent row in the rail shows: the state, what it is doing, its context, its shells. With the rail
gone, each Claude is drawn in one place.

Also folded in: **Your move goes on Plan, and the orchestrator column becomes a drawer.** Plan
answers "does anything need me?" first, but today Your move sits in the column. With no rail and
no column, Plan has the whole screen.

## Every rail job, and where it goes

The rail is `rail`, `railRow` and `agentRow` in `src/draw.zig`, and `railList`, `railPicks`,
`railKey`, `railDwell`, `railW` and their mouse handling in `src/app.zig`.

| the rail's | goes to | note |
| --- | --- | --- |
| **the agents list**: each Claude with its mark, ticket, title, age | **in flight**, a row per ticket being built or in the pipeline, as today | the row and its hover card show it; nothing new |
| a Claude's second and third lines: what it is doing or said, `quiet 12m`, branch, review mark, context | the **hover card** (`lookBox`), as today | the card gains a row per subagent and shell; it shows only their count today |
| a subagent's row, a click on it shows that subagent | the Claude's **modal** (`space` on the row): `⏎` or a click on a subagent row there | an action can't go in a peek (principle 5) |
| **Claudes with no ticket** (a menard Claude, the human's own, silliest_of_gooses) | **other Claudes**, a group at the foot of in flight: one line each, its mark, its repo's `▌` and icon from #904's cwd→repo rule, its title, `session:window`, its age | `⏎` goes there, hover shows its card |
| the **urgency sort** (waiting, stalled, done first) | **Your move** for what needs the human; in flight rows carry their state; the switcher sorts the same way (below) | see [Urgency](#urgency) |
| the `recent` and `ticket` sorts, the click on the agents rule | **dropped** | in flight sorts by stage, other Claudes by urgency |
| the **narrow rail's folds** (`· 4`, #427, #528) and its wide peek on hover | **dropped** | nothing is narrow any more |
| **the sessions list**: each session, its window count, the current one lit | the pane view's **foot row** names the session and its windows; the **switcher** lists every session | |
| a click on a session goes there; `j` `k` `⏎` the rail pick | the **switcher**: `s`, `j` `k`, `⏎`. In a pane view, `j` `k` in normal mode step to the session below or above | |
| `J` `K` move the session along the rail; dragging a session | `J` `K` move it in the switcher's order, the tmux order kept as today; dragging is **dropped** | the overview (`O`, see [Keys](#keys)) still drags windows between sessions |
| dragging a column's title onto a session | the **overview**: dragging a window's picture onto another session | the overview already does this |
| middle-click a session to close it | `x` on a session row in the switcher, after asking | |
| the wheel over the rail steps through sessions | **dropped** | `j` `k` do it |
| `+ new` at its foot | the switcher's last row, `+ new session`, and the menu | |
| `≡ menu` at its foot | `m` (as today), and `≡` at the right end of Plan's head and of the pane view's foot row | |
| the **top row**: `▤ board`, a click going home | `b` (and `Alt+b`) as today, and `◆ home` at the left of the pane view's foot row | |
| the top row's `▲ N` | `▲ N` beside `◆ home` in the foot row, and in Plan's head as today | |
| the top row's `auto N/M · tools N/M` and `orch` | Plan's head only, per #940 | |
| the top row's todo/doing counts, the pipeline's running ticket | **dropped**: in flight and not planned already count them | |
| `w` and the menu's "Wide or narrow rail" | **removed** | |
| `NORMAL` "over the foot of the rail" | the left end of the foot bar, where every view already says it | |
| folding away under about 60 cells | nothing to fold. Under 60 cells Plan is #905's one column and a pane view is the strip alone | |

The clock, the weather and the status strip at the far left of the human's screenshot are the
desktop shell's bar, not arena's. arena draws none of them, and this design changes none of them.

### Urgency

What the rail's urgency sort put first, and where each lands:

| a Claude that | today in the rail | without it |
| --- | --- | --- |
| asks through babylon (`ask_human`, a proposal, a send-back) | `▲` first | **Your move**, as today |
| waits in its pane (`@arena_claude` `waiting`: a permission prompt, a question typed in chat) | `▲` first | **Your move**, as a row `▲ #N waits in its pane` (or the session for one with no ticket), `⏎` goes there. **New:** arena adds it from the pane option, since babylon doesn't know about it |
| stalled (its turn ended on an API error) | `◇` near the top | its in flight row reads `◇ stalled`, as today. A stalled Claude with no ticket shows `◇` in other Claudes |
| done, and not looked at (`◉`) | high | its row's mark, until you look. Progress waits in its place (principle 8) |
| working, idle | lower | its row, its mark |

`]` and `[` (the next and previous Claude that waits or is done) never needed the rail, and stay.
The desktop notice for a Claude that waits is #1036's to settle, and this design leaves it alone.

## The switcher

**A popup list, not a strip at the foot.** It is today's jump prompt (`/`, `jumpHits`) grown to list
everything before anything is typed:

- A strip would need a cell for each of about 15 sessions and Claudes. At half width it can't hold
  them, and it would change width as Claudes come and go, against principle 10.
- A popup is a look that draws over the view and moves nothing (principle 5). Its rows move with
  `j` `k` and act with `⏎` (principle 2), and typing filters them, as the jump prompt already does.
- The jump prompt already finds windows, branches and tickets. A second finder beside it would
  repeat it.

`s` in normal mode opens it from any view, Plan included. In a pane view `/` opens it too, as it
opens the jump prompt today. On Plan, `/` stays Plan's find (#903). With nothing typed it lists:

```
╭─ go to ──────────────────────────────────────────────────────────────╮
│ ❯ █                                                                  │
│ ▲ ▌>_ #1029 Design: arena without the side rail       arena:2    4m  │
│ ◇ ▌☗  #588 babylon start N                             babylon:1  9m │
│ ◐ ▌>_ #760 Visual redesign: a GUI in the TUI           arena:3   21m │
│ ◐ ▌⌸  menard · indexing the repo                       menard:1   4m │
│ ── sessions ─────────────────────────────────────────────────────── │
│   ▌>_ arena          4 windows                                       │
│   ▌☗  babylon-work   2 windows                                       │
│   ▌⌂  tlon           3 windows                                       │
│   + new session                                                      │
│ j k move  ⏎ go  space card  J K order  x close  esc                  │
╰──────────────────────────────────────────────────────────────────────╯
```

Claudes come first, in the rail's urgency order (waits, stalled, done, working, idle), then the
sessions in tmux's order. Typing filters both, then windows and tickets as the jump prompt does
today. The box is a fixed size and scrolls inside itself. `space` on a Claude opens its card.

## The orchestrator as a drawer

The orchestrator column stops being a fixed column. It becomes a **drawer**: `o` opens it from the
right edge, over Plan, 60 cells wide (the whole width at half width), and `o`, `esc` or `Alt+h`
closes it. It holds the orchestrator's chat pane and nothing else. While it is open, keys and
typing go to the chat (insert mode, as Alt+l into the column today). It is drawn over Plan, so
Plan doesn't resize or move when it opens or closes (principles 5 and 10). Plan's head keeps the
orchestrator's state (`◆ orch working 12s`), and a click on it opens the drawer.

- **#940** (in review) stands as written. Its auto-only-in-Plan's-head holds, and the feed's tabs
  and lists it removes stay removed. The column it trims to "your move over the chat" becomes the
  drawer, holding only the chat, because Your move moves to Plan.
- **#989** moves to Plan. Its rules (one line per item, the picked item opens, a cap that
  scrolls) become Your move's window on Plan, below. The "a third of the column" cap becomes the
  window's fixed slot.
- **The next buttons under the chat** (the next-step mod): #1046 already turns the orchestrator's
  choices into asks in Your move. Once it lands, the drawer has no buttons. Until it lands, they
  ride in the drawer under the chat as they do in the column.

## Your move on Plan

Plan's top window, full width, above driving towards. Each item is one line
(`▲ #1029 arena  approve docs/no-rail.md  2m`), short first per #990. The picked item opens to its
whole card (the question, its options as buttons, its checks with `y` `n`), one open at a time, as
#899's rows do. The window is a **fixed slot**: its title and five rows at full height, three at
half width. More items scroll inside it (`↓ 2 more`). With nothing in it, it reads
`✓ nothing needs you` in one dim line, and the slot keeps its height.

A slot that grew with its items would push every window under it down each time an ask lands.
That is the jumping #887 rules out, so Your move gets principle 10's "same fixed size and scroll"
from the start.

`]` goes to Your move's first item from anywhere, as it went to the feed's.

## Home at 1920 px (220 × 51)

No rail and no column: Plan has the whole width. The 96 freed cells (the rail's 36 and the
column's 60) go to in flight and next, the windows with titles, per #905. In flight and next take
three fifths (132 cells), and goals, not planned and landed share the rest.

```
 ◆ plan   every · arena · babylon · tlon · …   / find          ◐ auto 4/6   ◆ orch working 12s   ✓ 23 today   ▲ 3   ≡
┌─ ◆ YOUR MOVE │ 3 ───────────────────────────────────────────────────────────────────────────────────────────────────────────── ▾ ┐
│▌>_ ▲ #1029 approve docs/no-rail.md: arena without the side rail                                                        asks you  2m │
│▌☗  ▲ #588  waits in its pane: Allow `git push`?                                                                    babylon:1  ⏎ go │
│▌⌂  ✗ #612  sent back: the gate's money test fails on the first of the month                                                    14m │
│                                                                                                                                    │
│                                                                                                                                    │
└────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────┘
┌─ ◆ DRIVING TOWARDS · your pick ──────────────────────────────────────────────────────────────────────────────────────────────── ▾ ┐
│ #896 Plan replaces the board: every board feature on Plan, then the board removed      ▌>_ 7/12  ▌☗ 1/1     ████████▒▒▒▒▒  8/13 │
│ ✓ #899 ──▶ ✓ #901 ──▶ ◐ #903 building ──▶ ◒ #904 reviewing ──▶ ○ #905 ──▶ ○ #906 ──▶ ○ #907                                       │
└────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────┘
┌─ ◆ in flight │ 6 ─────────────────────────────────────────────────────────── ▾ ┐ ┌─ ◆ goals │ 3 ─────────────────────── + goal ▾ ┐
│▌>_ #903 Plan 7: the board's tools on Plan: / find, r repo filter, h l   ◐ building 21m │ │▌#500 The orchestrator is the front door   9/12 │
│▌>_ #992 Copy text out of arena: drag to select in the ticket modal      ◐ building 33m │ │ ████████████████▒▒▒▒▒       ▌>_ 6/8  ▌☗ 3/4 │
│▌☗  #588 babylon start N: worktree and branch in one step                ◇ stalled   9m │ │▌#326 The board, redesigned               13/18 │
│▌>_ #904 Plan 8: workspace link: a held row's session·window·pane chip   ◒ reviewing 9m │ │ ██████████████████▒▒▒▒▒▒    ▌>_ 11/14 ▌⌂ 2/4 │
│▌>_ #940 The orchestrator column holds only your move and the chat       » queued 1st   │ ├─ ◆ not planned │ 21 ───────────── + new ▾ ┤
│▌>_ #901 Plan 5: not planned is the todo list: repo chips with folds     » queued 2nd   │ │ ▐>_ arena 11▌ ☗ babylon 3  ⌂ tlon 4  ✎ 2  ⌸ 1 │
│ ── other Claudes 2 ───────────────────────────────────────────────────────────────── │ ├─ ◆ landed │ 23 today ───────────────── ▾ ┤
│▌⌸  ◐ menard · indexing the repo                                     menard:1     4m │ │ ✓ 23 today                                 │
│▌✎  ○ ficciones · your shell                                         ficciones:2  1h │ │                                             │
├─ ◆ next │ 5 ────────────────────────────────────────────────────────────────── ▾ ┤ │                                             │
│ 1 ▌>_ #761 arena crashes with integer overflow on a 0-width pane          ready     │ │                                             │
│ 2 ▌⌂  #612 Money: a safe-to-spend-per-day on the bar                     ← #588    │ │                                             │
│ 3 ▌>_ #346 Board 13: / finds cards                                        ready     │ │                                             │
│ 4 ▌☗  #590 Restarts become a Your move item                               ← #588    │ │                                             │
│ 5 ▌✎  #433 The bar says ▲ N and opens arena's inbox                       ready     │ │                                             │
└──────────────────────────────────────────────────────────────────────────────────────┘ └─────────────────────────────────────────────┘
 NORMAL  ⏎ go  space open  e edit  p priority  H hand off   │   j k pick  h l window  z fold  / find  o orchestrator   │   ? keys
```

(The drawing is shortened in height. At 51 rows, in flight gets about 18 rows and next about 12.)

`o` opens the drawer on the right 60 cells, and Plan narrows to the cells left of it. The human,
2026-11-26, choosing between Plan staying full width under the drawer and Plan narrowing when it
opens: "Plan narrows beside the drawer". Every window lays out in that width, so right-aligned
columns (ages, `N/M  P%`, landed) end at the drawer's left edge and none is hidden under it. With
the middle column open as well the order is Plan, the column, the drawer, and Plan takes what is
left; if that is under 40 cells the column lies over Plan as before. Plan under 110 cells takes
#905's one-column layout. Opening or closing the drawer lays Plan out again; the pick, the scroll
and the open item stay.

### Keys

`o` has one job: the drawer, from any view. Today it has three: the overview in a pane view
(`openOverview`), the orchestrator on Plan (`toOrchestrator`, or the `o`/`p` swap at half width),
and an alias of `space` on Plan's picked row (`act(.open)`). So:

- **`o`** opens and closes the orchestrator's drawer, in every view.
- **`O`** opens the overview, in every view. No view binds `O` today.
- Plan's `o` as an alias of `space` goes: `space` opens the picked row, as on every other list.

## Home at half width (110 × 51)

#905's one column of fixed slots, with Your move first: Your move (three rows), driving towards
(folded), in flight, next, then goals, not planned and landed folded to their one-line summaries
(#905's "rest folded"). The `o`/`p` swap (#527) goes: `o` opens the drawer over the whole width.

```
 ◆ plan   every · arena · …   / find      ◐ auto 4/6   ◆ orch 12s   ▲ 3   ≡
┌─ ◆ YOUR MOVE │ 3 ───────────────────────────────────────────────────── ▾ ┐
│▌>_ ▲ #1029 approve docs/no-rail.md                           asks you 2m │
│▌☗  ▲ #588  waits in its pane: Allow `git push`?               babylon:1  │
│▌⌂  ✗ #612  sent back: the money test fails on the 1st               14m │
└──────────────────────────────────────────────────────────────────────────┘
┌─ ◆ driving towards · #896 Plan replaces the board ████████▒▒▒ 8/13 ▸ ──┐
┌─ ◆ in flight │ 6 ───────────────────────────────────────────────────── ▾ ┐
│▌>_ #903 Plan 7: the board's tools on Plan: / find, r     ◐ building 21m │
│▌>_ #992 Copy text out of arena: drag to select           ◐ building 33m │
│▌☗  #588 babylon start N: worktree and branch             ◇ stalled   9m │
│▌>_ #904 Plan 8: workspace link: a held row's chip        ◒ reviewing 9m │
│▌>_ #940 The orchestrator column holds only your move     » queued 1st   │
│ ── other Claudes 2 ─────────────────────────────────────────────────── │
│▌⌸  ◐ menard · indexing the repo                          menard:1    4m │
├─ ◆ next │ 5 ────────────────────────────────────────────────────────── ▾ ┤
│ 1 ▌>_ #761 arena crashes with integer overflow on a 0-width…    ready  │
│ 2 ▌⌂  #612 Money: a safe-to-spend-per-day on the bar            ← #588 │
│ 3 ▌>_ #346 Board 13: / finds cards                              ready  │
└──────────────────────────────────────────────────────────────────────────┘
┌─ ◆ goals │ 3  #500 9/12 · #326 13/18 · #830 idea ─────────────────── ▸ ┐
┌─ ◆ not planned │ 21  >_ 11 · ☗ 3 · ⌂ 4 · ✎ 2 · ⌸ 1 ─────────────────── ▸ ┐
┌─ ◆ landed │ ✓ 23 today ────────────────────────────────────────────── ▸ ┐
 NORMAL  ⏎ go  space open  …   │   j k pick  z fold  o orchestrator   │   ? keys
```

## A pane view at 1920 px and at half width

The strip takes the whole width. Today's row of dots under the strip becomes the **foot row**: home
on the left, then the session and its windows, then the switcher and the menu. Each part has a
fixed width, and a long session name shortens with `…`, so nothing in it moves as counts change.

```
╭─ 2 layout ───────────────────────────────────────────────────────────────────────────────────────────────╮ ╭─ 3 history ──────
│ claude › working on #903                                                                                 │ │ 3e94d5a Mar…
│ …                                                                                                        │ │ …
╰──────────────────────────────────────────────────────────────────────────────────────────────────────────╯ ╰──────────────────
 ◆ home ▲ 3  │  ▌>_ arena  ● 1 ◉ 2 ○ 3 ○ 4  │  s go to  ≡                                                    INSERT ^space
```

At half width the same line, with the window list shortened to the dots alone:

```
╭─ 2 layout ──────────────────────────────────────────────────────────╮ ╭─ 3
│ …                                                                   │ │ …
╰─────────────────────────────────────────────────────────────────────╯ ╰───
 ◆ home ▲ 3 │ ▌>_ arena ●◉○○ │ s go to  ≡                     INSERT ^space
```

A click on `◆ home` goes home. A click on `s go to` opens the switcher, a click on a dot goes to
that window (as today), and a click on `≡` opens the menu.

## Open tickets this changes

| ticket | change |
| --- | --- |
| **#923** (done) | closed by this design, as the orchestrator noted |
| **#927** (done) | its rail marks are deleted with the rail. Its colours and icons live on in the switcher and other Claudes |
| **#904** (review) | keeps the held row's chip, the pane border and the cwd→repo rule. Drops "the rail's session group headings use the session's repo colour"; the rule colours other Claudes and the switcher instead |
| **#905** (todo) | the half-width slots gain Your move at the top (three rows). `o`/`p` swap goes (the drawer replaces it). Its "under about 60 cells the rail folds away" line goes |
| **#906** (todo) | drops the rail e2e (`▤ board` checks, the rail's pick, `w`). Rail checks are deleted in the remove-the-rail step below, not rewritten |
| **#907** (todo) | `◆ home atop the rail` becomes `◆ home` in the pane view's foot row. Its "change the `▤ board` rail checks to `◆ home`" becomes checks on the foot row's `◆ home` |
| **#940** (review) | stands. The column it trims becomes the drawer in a step below |
| **#989** (todo) | rescoped to Your move on Plan (build step 1) |
| **#990** (todo) | the rail drops out of its "find the rest across the rail" |
| **#1046** (todo) | its "how it sits with #940" is answered here: the drawer holds the chat alone, no buttons |

## The build

Each step lands on its own, with the rail still there until step 6, so nothing loses its home
before the new one is in.

1. **Your move on Plan** (rescopes #989): the top window, full width, a fixed slot of five rows
   (three at half width) that scrolls, one line per item, the picked item opening to its card.
   It is read from the same `needs_you` the feed reads. After #940.
2. **Claudes that wait in their pane join Your move:** arena adds an item per pane whose
   `@arena_claude` is `waiting`, `⏎` going there. With step 1.
3. **Other Claudes in in flight:** a group at its foot, one line per Claude with no ticket,
   urgency-sorted, wearing its repo by #904's cwd→repo rule. After #904.
4. **The hover card and modal take the agent row's details:** a row per subagent and shell in
   the card, and `⏎` or a click on a subagent row in the Claude's modal shows it, as the rail's click did.
5. **The switcher:** `s` anywhere (and `/` in a pane view) lists Claudes (urgency first) and sessions before typing,
   `+ new session`, `J` `K` to order, `x` to close a session. **The foot row** in a pane view:
   `◆ home ▲ N`, the session and its windows, `s go to`, `≡`. `j` `k` in a pane view's normal
   mode step between sessions.
6. **Remove the rail:** `rail`, `railRow`, `agentRow`, the rail's picks, folds, dwell and peek,
   `agent_sort`, `w` and the menu's rail entry, the rail's mouse handling, its e2e checks and the
   README's rail text. Plan and the strip take the whole width. After 1 to 5.
7. **The orchestrator as a drawer:** `o` opens and closes it in every view, Plan takes the whole
   width, `≡` and the orchestrator's state in Plan's head, the `o`/`p` half-width swap removed.
   The overview moves to `O`, and Plan's `o` alias of `space` goes ([Keys](#keys)).
   After 1 (Your move has left the column) and #940.
8. **Docs and screenshots:** the README's rail and column sections, `docs/screenshots/strip.png`
   and `plan.png` taken again, and a line atop docs/orchestrator.md's "The rail, narrow":
   superseded by this doc. After 6 and 7.

Then #905, #906 and #907 as amended above.
