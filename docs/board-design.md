# The board, redesigned

A design for arena's board, decided as a TUI in arena (#320). The mockups use the real board of
2026-11-22. Nothing here is built yet: the build is a stack of tickets, listed at the end.

What it is for, in one line: **a glance tells you what needs you, what is moving, and what is next.**

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
 ▤ board    every · arena 13 · babylon 7 · ficciones · menard · tlon 9    backlog 4                     ▲ 1 needs you    ◒ gate #305 reviewing    ● orch    ◐ auto 3/3
 ─────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────
 ▲ ✗ #286 arena  Alt+h/Alt+l are dropped during an unanswered switch  —  sent back: the review asked for changes                                       ⏎ look   G give
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
each said once: `▲ 1 needs you`, the gate and its card, `orch`, `auto 3/3`. Each is a button. Under
it a rule, nothing else.

**A "needs you" row, only when something does.** Under the header, a row for each card whose
Claude asks you something (`? asks`) or that babylon sent back (`✗`, with the first line of its
`stage_note`). Its actions are on it: `⏎ answer` on an ask, `⏎ look` on a send-back, `G give`.
With nothing to do, the row is gone and the board moves up. Over three, they fold to
`▲ 5 need you  ⏎ go through them`, which picks the first and steps through them with `⏎`.

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

- A click on a card picks it; a click on the picked one does its `⏎`.
- A click on a header button, a "needs you" action, a picked card's action, or a key in the foot's
  bar does what it says.
- The wheel scrolls the column under the pointer.
- A card dragged onto another column moves there where babylon allows it (todo↔backlog,
  done→todo); elsewhere the drop says why not.

## The board, at half the screen

Four columns do not fit in about 90 cells, so the board shows two: **now** (doing and review) and
**next** (todo). `recent 41` becomes a button beside `+ new`, and `tab`, that swaps it in for next.

```
 ▤ board  every · arena 13 · babylon 7 · tlon 9 · …          ▲ 1   ◒ #305   ● orch   ◐ 3/3
 ─────────────────────────────────────────────────────────────────────────────────────────
 ▲ ✗ #286 Alt+h/Alt+l are dropped during an unanswered switch               ⏎ look  G give
     sent back: the review asked for changes
 ─────────────────────────────────────────────────────────────────────────────────────────

 now 5                                     next 32                       + new   recent 41
 doing                                     arena ───────────────────────────────────── 13
 ▌ #320 Design: the board looks and        ╭─────────────────────────────────────────────╮
 ▌ works like a real app · arena           │ #295 A Claude whose turn ended on an API    │
 ▌ ◐ t320-design · opus · 5m               │ error (out of usage credits) stays          │
 ▌ #324 The selected agent in the rail     │ "working" in its state, rail and board      │
 ▌ is not marked: highlight its whole      │ med · filed 1d                              │
 ▌ entry · arena                           │ ⏎ start  G give  e edit  p  > close         │
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
 ⏎ start  space open  G give  e edit   │   n new  / find  tab recent   │   ? keys
```

- In **now** the cards are grouped by stage, with their repo after the title in the every view.
- The header drops words before buttons (`▲ 1`, `◒ #305`, `◐ 3/3`); tabs that do not fit end in
  `…`, and `r` still steps through every repo.
- Under about 60 cells, now and next become tabs, one column at a time.

## The rail

While the board is open, the rail's sessions and Claudes repeat its cards (`#292`, `#260`, `#307`)
as cut lines. With the board open:

- **The rail goes narrow by itself**, as `Alt+w` makes it: two letters a session, a mark a Claude.
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

## What babylon needs to give

- **When each ticket was filed** (`inserted_at` in board.json), for a todo card's `filed 1d`.
- A queued card's place in line (`2nd`) arena can count itself from the queued cards.

The rest (`model`, `stage_note`, `closed_at`, `claimed_at`, `blocked_by`, asks) is in board.json.

## The build, as a stack

Each a ticket on the last, in this order:

1. **babylon:** board.json carries each ticket's `inserted_at`.
2. **Header:** one row in three groups, each thing said once, each a button.
3. **Needs you:** the row of asks and send-backs under the header, with their actions.
4. **Columns, no lanes:** the every view's columns grouped by repo, empty columns narrow, width by
   card count.
5. **Cards sized to their content:** the priority bar, the whole title, the last row by status;
   columns scroll by rows, not card slots.
6. **The picked card:** boxed, with its detail and action buttons.
7. **The key bar** along the foot, following the pick.
8. **Recent** filling its column, with ages.
9. **Half width:** now and next, then tabs under 60 cells.
10. **The rail:** narrow while the board is open, the picked card's Claude lit, a click on a Claude
    picks its card.
11. **Find** with `/`.
12. **Drag** a card between columns.
13. **README** and screenshots of the new board (takes in #321).
