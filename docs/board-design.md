# The board, redesigned

> Superseded by [plan-replaces-board.md](plan-replaces-board.md) for the board itself, which is
> gone. Its Workbench look is still in force.

A design for arena's board, decided as a TUI in arena (#320). The mockups use the real board of
2026-11-22. Nothing here is built yet: the build is a stack of tickets, listed at the end.

What it is for, in one line: **a glance tells you what needs you, what is moving, and what is next.**

## The look: Workbench

Chosen by the human on 2026-11-24 ("Workbench, go ahead") from the three directions of #760, in
[docs/redesign/](redesign/README.md). The style guide is [workbench.md](redesign/workbench.md), and
the screenshots are `docs/redesign/workbench-{home,board,popup,orch}.png`, drawn by `arena-mock`
from [board.json](redesign/board.json). The layout below (what goes where, the keys, the clicks)
stands. Where its plain-text mockups show boxes and tags, the look is Workbench's:

- **A desktop GUI from 1990 on the palette.** The ground is `SURFACE0`. Every area is a window on
  `SURFACE2` with a one-row title bar, `◆ name`, a count badge and `▫`. A focused window's bar is
  `SURFACE4` with `═══` stripes in half-strength amber. Windows, the pick, the focal goal and
  buttons cast a hard one-cell shadow (`▌` right, `▀` under, in `BG`). Nothing else draws an outline.
- **Three steps of depth:** panel, then tile (`SURFACE3`, a card), then raised (`SURFACE4`, the
  pick, a button, a chip). A thing goes up one step when it is picked. Wells (the prompt, a bar's
  track) sink to `BG`.
- **A card** is its title, bold, on at most two rows, then a row of chips: the repo's glyph and
  number in its hue, the state or what it waits on, the model and the age. Priority is a dot in
  its corner. A chip is `▎label` on raised, its lead bar in its colour.
- **Buttons show on the picked thing only**: ` key label ` on raised with the key in amber, and
  one primary per area, filled amber. auto is a switch, `auto ▐ ●▌`. Tabs sit under the title bar,
  and the current one joins the window below it.
- **Colour has jobs.** Each repo has a hue (arena amber, babylon violet, ficciones cyan, menard
  moss, tlon pink) and so does each state. Violet means "you": asks and `▲ N need you` use it, and
  nothing else does.
- **Home** has one focal point: the goal we are driving towards, a window with a real bar and its
  steps in flight as a chain. Goals are cards with a bar, their next step and what blocks them.
  Next is a numbered queue with chips. Landed today is a strip.
- **The board**: epics are slim bars along its top, columns have count badges and repo groups,
  and recent is a timeline strip of the last five.
- **The orchestrator's column**: Your move on top, each item a tile with its buttons, then landing
  and building as chips, then its Claude and the prompt's well.
- The pointer draws nothing (#759), and the plan and the board stay split.

## Today, at the whole screen (210×52), as captured

```
╭─ sessions ───────────────────────╮  board auto 3/3   every   arena   babylon   ficciones   menard   tlon   backlog     gate   orch   auto 3/3                                                ? keys · esc close
│ ▤ board orch ◒ #308 verifying +1 │               ╭─ todo 32 ────────────────────────────── + ╮╭─ doing 4 ─────────────────────────────────╮╭─ review 2 ────────────────────────────────╮╭─ recent 41 ──────────╮
│ arena                          2 │  arena        │╭─────────────────────────────────────────╮││╭ high ───────────────────────────────────╮││                                           ││ ✓ #260 Show the hold…│
│                                  │               ││ #295 A Claude whose turn ended on an API││││ #320 Design: the board looks and works  │││                                           ││ ✓ #292 Clean card ti…│
│                                  │               ││ error (out of usage credits) stays "wor…││││ like a real app                         │││                                           ││ ✓ #293 Board imports…│
│                                  │               ││                                         ││││ %286 · 5m                               │││                                           ││ 19 more              │
│                                  │               │╰ go ─ give ─ edit ─ priority ─ close ─ ↑ ╯││╰─────────────────────────────────────────╯││                                           ││                      │
│                                  │               │╭─────────────────────────────────────────╮││╭ high ───────────────────────────────────╮││                                           ││                      │
│                                  │               ││ #286 Alt+h/Alt+l are dropped during an  ││││ #324 The selected agent in the rail is  │││                                           ││                      │
│                                  │               ││ unanswered switch                       ││││ not marked: highlight its whole entry   │││                                           ││                      │
│                                  │               ││ ✗ sent back                             ││││ %290 · 1m                               │││                                           ││                      │
│                                  │               │╰─────────────────────────────────────────╯││╰─────────────────────────────────────────╯││                                           ││                      │
   …  arena's lane fills the height; babylon, ficciones, menard and tlon are below it, unseen
```

- Every card is five rows whatever it holds, and its title is cut at two.
- arena's lane fills the screen, so the other repos' lanes are off it.
- doing and review are boxes as wide as todo, mostly empty.
- `auto 3/3` is said twice; tabs, views and status share one row with nothing grouping them.
- go, give and edit are tags on the picked card's border.
- At half the screen titles are cut to "#290 e2e flake: th…" and "#320 Design: t…".

## The board, at the whole screen

The board's own area, with the rail narrowed beside it (see [The rail](#the-rail)): 166 cells.

```
 ▤ board    every · arena 13 · babylon 7 · ficciones · menard · tlon 9    backlog 4                      ▲ 4 need you    ◒ gate #305 reviewing    ● orch    ◐ auto 3/3
 ─────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────

 todo 32                                  + new    doing 3                                 review 2                             recent 41
 arena ─────────────────────────────────── 13      arena ───────────────────────────── 2   babylon ───────────────────────── 1  ✓ #184 babylon  A gate that runs…   7m
 ╭─────────────────────────────────────────────╮   ▌ #320 Design: the board looks and      ▌ #305 A landed ticket's worktree    ✓ #307 tlon  Design: asterion, …   10m
 │ #295 A Claude whose turn ended on an API    │   ▌ works like a real app                 ▌ and branch are removed, so         ✓ #293 arena  Board imports app…   13m
 │ error (out of usage credits) stays          │   ▌ ◐ t320-design · opus · 5m             ▌ nothing mistakes them for          ✓ #292 arena  Clean card titles…   14m
 │ "working" in its state, rail and board      │   ▌ #324 The selected agent in the rail   ▌ stranded work                      ◆ #260 arena  Show the holder o…   15m
 │ med · filed 1d                              │   ▌ is not marked: highlight its whole    ▌ ◒ reviewing · 2m                   ◆ #297 babylon  A ticket carrie…   15m
 │ ⏎ start  G give  e edit  p priority  > close│   ▌ entry                                 tlon ──────────────────────────── 1  ◆ #294 babylon  Done tickets ke…   15m
 ╰─────────────────────────────────────────────╯   ▌ ◐ t324-rail-select · sonnet · 1m      ▌ #308 Asterion 1: write the         ✓ #298 tlon  Proposals: one Am…     1d
 ▌ #290 e2e flake: the click that focuses          tlon ────────────────────────────── 1   ▌ /api/home contract and audit       ✓ #299 tlon  Money notices sho…     1d
 ▌ window two leaves the strip on window one,      ▌ #14 The house is for personal life,   ▌ local_list.gd against the server   ✓ #301 tlon  The house's daily…     1d
 ▌ failing the shift-drag and middle-click         ▌ not a software factory                ▌ » queued · 2nd                     ◆ #289 arena  Comment overstate…    1d
 ▌ checks                                          ▌ ○ no Claude holds it · 2d                                                  ◆ #288 arena  Clean the note be…    1d
 ▌ #291 Force the #181 checks too                                                                                               ◆ #285 arena  Force the race in…    1d
 ▌ #321 README still describes the old card                                                                                     ◆ #284 babylon  A ticket whose …    1d
 ▌ layout                                                                                                                       ◆ #282 arena  Tell only arena's…    1d
 ▌ #322 A held card that asks or is sent back                                                                                   ◆ #283 arena  A done card older…    1d
 ▌ has no e2e                                                                                                                   ◆ #278 arena  A queued card hel…    1d
 ▌ #246 arena's tsconfig.json extends                                                                                           ◆ #281 babylon  Keep the socket…    1d
 ▌ .claude-plugin/types/tsconfig.json, which                                                                                    ◆ #276 arena  Two zig builds in…    1d
 ▌ is not in the repo                                                                                                           ◆ #259 arena  Test the new `?` …    1d
 ▌ #247 The board-feed mod's test has no case                                                                                   ◆ #258 arena  Test a card in re…    1d
 ▌ for a missing inotifywait or a missing                                                                                       ◆ #238 arena  The board draws a…    1d
 ▌ board file at start                                                                                                          ◆ #277 ficciones  The office ra…    1d
 babylon ─────────────────────────────────── 6                                                                                  ◆ #255 arena  Keys after a boar…    1d
 ▌ #303 babylon reads its own history: a                                                                                        ◆ #253 arena  Keys typed during…    1d
 ▌ nightly retro that turns repeated                                                                                            ◆ #254 arena  A stale `BoardVie…    1d
 ▌ send-backs into root-cause tickets                                                                                           ◆ #248 arena  The running secti…    1d
 ▌ #304 Test the one-off migration                                                                                              ◆ #243 arena  Show the orchestr…    1d
 ▌ #202 Remove the stopgap give rule                                                                                            ◆ #240 arena  A door from outsi…    1d
 ▌ #206 The pipeline's tmux windows and                                                                                         ◆ #256 tlon  Retag live seats s…    1d
 ▌ commands (gate, install, git) still run                                                                                      ◆ #279 tlon  Server.Home.Mornin…    1d
 ▌ with the release's bin and erts first in…                                                                                    ◆ #262 tlon  planner f2 fixture…    1d
 tlon ────────────────────────────────────── 9                                                                                  ◆ #257 babylon  board.json: a t…    1d
 ▌ #302 The house on Telegram: one Today card                                                                                   ◆ #249 babylon  The board file …    1d
 ▌ a day, edited in place, with todos,                                                                                          ◆ #273 menard  Test the vanishe…    1d
 ▌ notices and proposals kept apart                                                                                             ◆ #280 tlon  Morning test fails…    1d
 ▌ opus                                                                                                                         ◆ #275 babylon  A ticket with a…    1d
 ▌ #311 Asterion 4: background mode, so                                                                                         ◆ #274 arena  Two zig compiles …    1d
 ▌ reminders and Telegram run with the window                                                                                                ↓ 3 more
 ▌ shut
                 ↓ 9 more
 ─────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────
 ⏎ start  space open  G give  e edit  p priority  > close  J K move   │   n new  r repo  / find  A auto  o orch  g gate   │   ? all keys   esc close
```

### Piece by piece

**One calm header, in three groups.** Left: what you are looking at: `every`, or one repo, each
with its count of open cards (a repo with none dim), then `backlog`. Right: what babylon is doing,
each said once: `▲ 4 need you`, the gate and its card, `orch`, `auto 3/3`. Each is a button. Under
it a rule, nothing else. `▲ 4 need you` opens [the inbox](#needs-you-the-inbox); with nothing
there it is a dim `▲ 0`.

**Columns by status, grouped by repo inside, no lanes.** In the every view the board is four
columns. Inside each, every repo with cards in it gets a one-row heading with its count
(`arena ──── 13`) and its cards under it; a repo with none there takes no rows. This replaces the
lanes: babylon's cards no longer wait under a screen of arena's todo.

**Width goes to what has cards.** An empty column shrinks to its heading and says `none`. Todo gets
the most, doing and review a share each by how many cards they hold, recent a fixed 40 cells. With
one repo picked, the same columns hold its cards with no repo headings.

**Cards as tall as what they say.** No box around each card: a priority bar `▌` down its left
(amber high, plain med, dim low), its number and whole title wrapped to the column, and a last row
only when there is something to say:

| card in | its last row |
| --- | --- |
| todo | `waits #305`, the card dimmed, when blocked; its model when it has one; else nothing |
| doing | `◐ t320-design · opus · 5m`: its Claude's mark, window, model and how long held; `○ no Claude holds it · 2d` when none does |
| review | its stage in the holder's place: `◒ reviewing · 2m`, `» queued · 2nd`, `held: asks` |
| recent | one row: `✓` closed or `◆` landed, number, repo, title cut, how long ago |

A title over four rows is cut at the fourth with `…`; the picked card shows it whole.

**The picked card is a box with its actions in it.** The card under the cursor is boxed in the
accent colour, with its detail (`med · filed 1d`) and its actions as buttons:
`⏎ start  G give  e edit  p priority  > close`. Only those that apply: a doing card's `⏎` is `go`,
a review card has `space log`, a recent one `< reopen`. The selection is as plain as #324 makes the
rail's.

**A key bar along the foot.** The picked card's keys, then the board's (`n new`, `r repo`,
`/ find`, `A auto`), then `? all keys`. It follows the pick, so what you can do is always written.
`?` still opens the whole list.

**Recent fills its column**, newest first, with how long ago each closed, and `↓ 3 more` at its
foot.

**Find.** `/` narrows every column to cards whose number, title or repo match, live as you type;
`esc` clears it. It is the one new key.

### Mouse

- A click on a card picks it; a click on the picked one opens its modal, as `space` does, and `⏎` in it goes.
- A click on a header button, a picked card's action, an inbox item's option, or a key in the
  foot's bar does what it says.
- The wheel scrolls the column under the pointer.
- A card dragged onto another column moves there where babylon allows it (todo↔backlog,
  done→todo); elsewhere the drop says why not.

## Needs you: the inbox

The one place for what needs the human's eyes or decision. The header's `▲ 4 need you` opens it in
the board's place, and so do the rail's board row, the desktop's notices and the bar: none of them
say more than `▲ N need you`. A card with something in it carries `▲` in its last row, and its
`⏎` opens the inbox on that item. `esc` goes back to the board.

```
 ▤ board    every · arena 13 · babylon 7 · ficciones · menard · tlon 9    backlog 4                      ▲ 4 need you    ◒ gate #305 reviewing    ● orch    ◐ auto 3/3
 ─────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────
 ▲ needs you  4                                                                                                                                  esc back to the board

 decisions 1
 ╭───────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────╮
 │ #320 arena  Design: the board looks and works like a real app                                                                         asked 3m ago by t320-design │
 │ Build it as the doc's 13-ticket stack?            ▤ docs/board-design.md   o open it                                                                              │
 │                                                                                                                                                                   │
 │ 1 Yes, file the stack as drawn   2 Yes, but leave out find and drag   3 Change something first   4 A different direction                        c answer in words │
 ╰───────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────╯

 to look at 1
 ▌ #307 tlon  Design: asterion, the house as its own app and backend     ▤ docs/asterion.md                               ⏎ open   y looks good   c say what to change

 sent back 2
 ▌ ✗ #286 arena  Alt+h/Alt+l are dropped during an unanswered switch                                                                        its Claude has it   ⏎ look
 ▌   the review asked for changes: the e2e never holds tmux unanswered
 ▌ ✗ #290 arena  e2e flake: the click that focuses window two leaves the strip on window one                                         yours   ⏎ look   G give   x close
 ▌   no Claude holds it: the gate failed twice on the same check

 from the orchestrator 2
 ▌ Start #302 next: tlon's Today card is high, filed a day ago, and nothing blocks it                                                                      ⏎ go   x no
 ▌ Restart t305-landed-worktree: its Claude has been quiet 40m on a doing card                                                                             ⏎ go   x no

 ─────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────
 j k pick   1-9 an option   ⏎ go   x no   o open   c in words   │   esc the board
```

It has four kinds, each a heading with its count, oldest first inside:

- **Decisions:** every open ask: its ticket, who asked and when, the question, its options as
  buttons, answered in place with `1`-`9` or a click, or in words with `c`. An ask that comes with a
  doc to read names it, and `o` opens it.
- **To look at:** mockups and designs waiting on review. The item names the doc itself, never a
  branch, and `⏎` opens it: a file in the repo in a window beside the board (`glow`, else `less`),
  a link in the browser. `y` says it looks good, `c` says what to change; both go to its ticket's
  Claude as the answer.
- **Sent back:** the first line of the reason, and whose move it is: `its Claude has it` when the
  session holding it was told and is on it, `yours` when no Claude holds it or it needs a choice.
  Only `yours` counts toward `▲ N`; the rest are there to be seen.
- **From the orchestrator:** its proposals: what to start next, follow-ups to keep or close,
  sessions to restart. Each is one line saying what and why, with `⏎ go` and `x no`, never a chat
  paragraph. On `go` babylon does it; on `no` it is gone.

With nothing in it, it says `nothing needs you` in the middle of the board's area.

## The board, at half the screen

Four columns do not fit in about 90 cells, so the board shows two: **now** (doing and review) and
**next** (todo). `recent 41` becomes a button beside `+ new`, and `tab`, that swaps it in for next.

```
 ▤ board  every · arena 13 · babylon 7 · tlon 9 · …          ▲ 4   ◒ #305   ● orch   ◐ 3/3
 ─────────────────────────────────────────────────────────────────────────────────────────

 now 5                                     next 32                       + new   recent 41
 doing                                     arena ───────────────────────────────────── 13
 ▌ #320 Design: the board looks and        ╭─────────────────────────────────────────────╮
 ▌ works like a real app · arena           │ #295 A Claude whose turn ended on an API    │
 ▌ ◐ t320-design · opus · 5m               │ error (out of usage credits) stays          │
 ▌ #324 The selected agent in the rail     │ "working" in its state, rail and board      │
 ▌ is not marked: highlight its whole      │ med · filed 1d                              │
 ▌ entry · arena                           │ ⏎ start  G give  e edit  p priority  > close│
 ▌ ◐ t324-rail-select · sonnet · 1m        ╰─────────────────────────────────────────────╯
 ▌ #14 The house is for personal life,     ▌ #290 e2e flake: the click that focuses
 ▌ not a software factory · tlon           ▌ window two leaves the strip on window one,
 ▌ ○ no Claude holds it · 2d               ▌ failing the shift-drag and middle-click
 review                                    ▌ checks
 ▌ #305 A landed ticket's worktree and     ▌ #291 Force the #181 checks too
 ▌ branch are removed, so nothing          ▌ #321 README still describes the old card
 ▌ mistakes them for stranded work         ▌ layout
 ▌ babylon                                 ▌ #322 A held card that asks or is sent back
 ▌ ◒ reviewing · 2m                        ▌ has no e2e
 ▌ #308 Asterion 1: write the /api/home    babylon ───────────────────────────────────── 6
 ▌ contract and audit local_list.gd        ▌ #303 babylon reads its own history: a
 ▌ against the server · tlon               ▌ nightly retro that turns repeated
 ▌ » queued · 2nd                          ▌ send-backs into root-cause tickets
                                                             ↓ 23 more

 ─────────────────────────────────────────────────────────────────────────────────────────
 ⏎ start  space open  G give  e edit   │   n new  / find   │   ? keys
```

- In **now** the cards are grouped by stage, with their repo after the title in the every view.
- The header drops words before buttons (`▲ 1`, `◒ #305`, `◐ 3/3`); tabs that do not fit end in
  `…`, and `r` still steps through every repo.
- Under about 60 cells, now and next become tabs, one column at a time.

## The rail

While the board is open, the rail's sessions and Claudes repeat its cards (`#292`, `#260`, `#307`)
as cut lines. With the board open:

- **The rail goes narrow by itself**, as `Alt+w` makes it: a short name and its windows a session, a Claude its mark and its ticket's number.
  Its width goes to the board, and it comes back wide when the board closes. Resting the pointer on
  it draws it wide over the board, as today.
- **The rail and the board point at each other.** The Claude holding the picked card is lit in the
  rail with #324's whole-entry mark, and a click on a Claude in the rail picks its card.

```
╭────╮
│ ▤  │   the board: lit while it is open
│ ar │   arena
│▐◐▌ │   lit: holds #320, the picked card
│ ◐  │
│ ba │   babylon
│ ◐  │
│ tl │   tlon
│ ◐  │
├────┤
│ +  │
│ ≡  │
╰────╯
```

## Hover, focus and pick: one system

The human, hovering today's board: "these go all wonky when i hover them. make it all work together
nicely". Header tabs were drawn over (`menard` showed as `enard`), and something moved at the foot
of the orchestrator's column. So hover, focus and pick are three states, each with one look
everywhere, across the header, the cards, the inbox, the rail and the orchestrator's column:

| state | what it is | its look |
| --- | --- | --- |
| hover | the thing under the pointer | no look at all; a click still acts on it |
| focus | the area keys go to: board, inbox, rail or the orchestrator's column | its frame in the turning gradient, as a focused column's is today |
| pick | the one item in an area the keys act on | the accent box, or #324's whole-entry mark in the rail |

The rules that make them hold together:

- **Hover changes nothing.** No cell, text or attribute changes under the pointer, and nothing
  beside it moves. The one thing hover opens is the narrow rail's wide peek,
  drawn over the board and taken back cell for cell.
- **One layout, read by drawing and clicking alike.** Every button, tab, card and action has its
  rectangle from one pass; the frame draws from those rectangles and a click or hover is tested
  against the same ones. Nothing is drawn "over what is under it" at a guessed place.
- **Everything is in the frame.** The pointer's shape and any other escape go out inside the
  synchronized frame, never between frames where the cursor stands at some cell.
- **Each area has its own pick, and only the focused area's is in the accent.** The others show
  theirs dim, so a glance shows where the keys will go.

An e2e holds it: it hovers one of each kind of element (a tab, a status button, a card, a card's
action, a key in the foot's bar, an inbox option, a rail session and Claude, the orchestrator
column's edges and the dividers) and checks that no cell changed.

## What babylon needs to give

- **When each ticket was filed** (`inserted_at` in board.json), for a todo card's `filed 1d`.
- **A doc on an ask**: an ask can name a file or link to look at, and be a decision or a "look at
  this"; board.json gives both.
- **Whose move a send-back is**: board.json says whether the holding session was told and is on
  it, or the human must act.
- **Proposals from the orchestrator**: a way to post one (what, why, the action babylon runs on
  go), list the open ones in board.json, and take go or no.
- **auto's count no higher than its cap**: the header said `auto 4/3`; board.json had
  `"working":4,"cap":3`, so babylon counts more as working than it started.
- A queued card's place in line (`2nd`) arena can count itself from the queued cards.

The rest (`model`, `stage_note`, `closed_at`, `claimed_at`, `blocked_by`, asks) is in board.json.

## The build, as a stack

babylon's parts stand alone and can go in any order. arena's are one stack, each on the last; a part
that reads a babylon field waits on that ticket.

babylon:

- board.json carries each ticket's `inserted_at`.
- An ask can name a doc and be a decision or a look.
- A send-back says whose move it is.
- Orchestrator proposals, with go and no.
- auto's working count never passes its cap.

arena:

1. **Hover, focus and pick:** one layout of rectangles for drawing and clicks, hover drawing
   nothing, escapes inside the frame, and the hover e2e.
2. **Header:** one row in three groups, each thing said once, each a button.
3. **Columns, no lanes:** the every view's columns grouped by repo, empty columns narrow, width by
   card count.
4. **Cards sized to their content:** the priority bar, the whole title, the last row by status;
   columns scroll by rows, not card slots.
5. **The picked card:** boxed, with its detail and action buttons.
6. **The key bar** along the foot, following the pick.
7. **Recent** filling its column, with ages.
8. **The inbox:** decisions and sent back, from what board.json has today; `▲ N` in the header,
   the rail and on cards opens it.
9. **The inbox's to look at**, opening the doc (waits on babylon's doc on an ask).
10. **The inbox's proposals** (waits on babylon's proposals).
11. **Half width:** now and next, then tabs under 60 cells.
12. **The rail:** narrow while the board is open, the picked card's Claude lit, a click on a Claude
    picks its card.
13. **Find** with `/`.
14. **Drag** a card between columns.
15. **README** and screenshots of the new board (takes in #321).

arena, the Workbench look ([The look](#the-look-workbench)), #768–#773 on top of what has landed:
1 then 2; 3 (then 4, the key bar #339 and the epic bars #756) and 5 and 6 each after 2. It replaces
the visual parts of 5 (#338), 6 (#339), the epic ticket (#756) and the hover ticket (#759):

1. **Workbench's parts:** its palette roles, and windows, shadows, chips, buttons, the switch and
   bars as drawing calls, with tests on their cells.
2. **The title bar:** tabs, `▲ N need you`, the gate and the auto switch.
3. **The board:** columns as windows, cards as tiles with chips, the pick raised with its buttons,
   recent as a strip. The epic bars (#756) and the key bar (#339) follow it.
4. **The card's popup** as a window.
5. **Home:** the focal goal, goal cards, the next queue, the landed strip.
6. **The orchestrator's column:** Your move tiles, the chips, the prompt's well.

ficciones: the bar's and the desktop's notices of asks say only `▲ N need you` and open arena's inbox.
