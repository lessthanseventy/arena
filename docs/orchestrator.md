# The orchestrator is the front door

This design is for #500, held to [the principles](principles.md), and builds on
[the board design](board-design.md) and [normal mode](normal-mode.md). The human agreed to it
as drawn on 2026-11-23. Nothing in it is built yet. The build is a list of tickets, given at the
end.

The human, 2026-11-22: "the sessions popup is kinda dumb can we jsut like step back and think
about this? like the orchestrator is probably a first class citizen somehow. how should this
look/work". To the orchestrator's proposal: "that all sounds great".

## The words

These words mean the same thing wherever they show: in arena, babylon, the desktop, and Asterion's
own orchestrator (tlon #512), which copies them. The house and work stay separate systems (#14):
they share the words, not the channel.

- **needs you (`▲ N`):** the count of items that are the human's move, and nothing else. It is
  the same count everywhere it shows, and `▲ 0` is drawn dim, never hidden.
- **ask:** a question from a Claude to the human, with numbered options and an answer in words.
  It is open until it is answered.
- **look at:** an ask that names a doc. It is settled with *looks good* or *change*.
- **proposal:** an action the orchestrator suggests, given as what and then why. It is settled with
  **go** (the action runs) or **no** (it is dropped), never talked over in chat.
- **your move:** the list of open asks, looks, proposals and free send-backs. Each item is settled
  in place, where it is shown.
- **notice:** raised only when a new ask or proposal appears, once. It is taken back when the item
  is settled anywhere, and it is not raised while your move is already in front.
- **tell:** a line from the human, typed into the orchestrator's prompt as the human's word, held
  while the orchestrator is mid-turn. A Claude never sends one.

## Why

Sessions are listed in five places: the deck's sessions popup, the office rail, the deck's agents
cell, arena's rail and `/brief`. Each one is a list of tmux panes, and most of those panes are idle.
The human thinks in three things: what needs me, what is moving, and telling the orchestrator
something. The orchestrator is the one session that already holds that view, yet it is only another
pane.

So the orchestrator becomes the place the human starts from. Sessions are reached through their
tickets, and the desktop keeps one line about it.

## What arena shows on open

`arena`, with no session named, opens **home**: the board with the orchestrator's column pinned
on its right, and the rail narrow on the left. The orchestrator's column has focus in normal mode,
with the pick on the oldest item under **Your move**. With nothing there, the column is in insert
and its prompt is ready to type into.

- `arena work` still opens the session `work`, as today.
- `b` from anywhere in normal mode goes home, and so does a click on the rail's top row. `q` on a
  bare strip does nothing, as before.
- `arena inbox` opens home with the pick on the oldest Your move item. That is the door every
  notice and the bar use.
- With no babylon board file, there is no home, and `arena` opens the most recent session as today.

The column is pinned beside the board, not beside every strip. A session's own strip takes the
whole width, as it does now. The way back is the rail's top row or `b`, and the bar always says
the orchestrator's state.

## Home, at the whole screen (210 cells)

```
╭─────╮ ▤ board  every · arena 13 · babylon 7 · tlon 9   backlog 4     ▲ 3   ◒ gate #305   ◐ auto 3/4 │ ◐ orchestrator · working 12s · ctx 34%          ` fold
│▐▤▌  │ ──────────────────────────────────────────────────────────────────────────────────────────────│ ──────────────────────────────────────────────────────────
│ ar  │ todo 32                       + new   doing 3                        review 2                │ ▲ your move 3
│ ◐320│ arena ─────────────────────── 13      arena ──────────────────── 2  babylon ─────────────── 1 │ ╭────────────────────────────────────────────────────────╮
│ ▲393│ ▌ #295 A Claude whose turn ended      ▌ #320 Design: the board     ▌ #305 A landed ticket's   │ │ #393 arena  asks: Ctrl+Space or Esc Esc for the mode?  │
│ ba  │ ▌ on an API error stays "working"     ▌ looks and works like a…    ▌ worktree and branch are  │ │ 1 Ctrl+Space   2 Esc Esc   c in words   space whole    │
│ ▲305│ ▌ med · filed 1d                      ▌ ◐ t320-design · opus · 5m  ▌ removed                  │ ╰────────────────────────────────────────────────────────╯
│ tl  │ ▌ #290 e2e flake: the click that      ▌ #393 Design: a normal      ▌ ◒ reviewing · 2m         │ ▌ P14 start #302 next: high, a day old, nothing blocks it
│ ◐308│ ▌ focuses window two leaves the…      ▌ mode for arena             tlon ─────────────────── 1 │ ▌     ⏎ go   x no
│ · 4 │ ▌ #291 Force the #181 checks too      ▌ ▲ asks · opus · 4m         ▌ #308 Asterion 1: write   │ ▌ ✗ #290 arena  sent back, free: the gate failed twice
│     │ babylon ───────────────────────── 6   tlon ───────────────────── 1 ▌ the /api/home contract   │ ▌     G give   ⏎ start   x close
│     │ ▌ #303 babylon reads its own history  ▌ #14 The house is for       ▌ » queued · 2nd           │
│     │ ▌ #304 Test the one-off migration     ▌ personal life                                         │ ◒ landing 2
│     │ ▌ #202 Remove the stopgap give rule   ▌ ○ no Claude holds it · 2d                             │   #305 babylon  reviewing 2m    #308 tlon  queued 2nd
│     │ tlon ──────────────────────────── 9                                                           │ ◐ building 3
│     │ ▌ #302 The house on Telegram: one                                                             │   #320 arena 5m   #393 arena ▲ 4m   #14 tlon ○ 2d
│     │ ▌ Today card a day, edited in place                                                           │ ✓ landed today 6                                   ⏎ recent
│     │ ▌ ▲ proposed: start next                                                                      │ ──────────────────────────────────────────────────────────
│     │                 ↓ 9 more                                                                      │ ● #305 is reviewing. #393 waits on you for its mode key;
│     │                                                                                               │   that is the one decision in front of you. I proposed
│     │                                                                                               │   #302 next since tlon's lane is free.
├─────┤                                                                                               │
│ +   │                                                                                               │ ❯
╰─────╯ ──────────────────────────────────────────────────────────────────────────────────────────────┴──────────────────────────────────────────────────────────
 NORMAL  1 2 answer  c in words  space whole  t ticket   │   j k pick  h board  i type to it   │   b home  / find  ? keys
```

The board keeps the layout of [the board design](board-design.md#the-board-at-the-whole-screen),
narrower by the column's 60 cells. The board header's `▲ 3` is a button that moves focus to the
column with the pick on Your move. The board's `orch` button goes, because the column is always
there.

## The orchestrator's column

From the top down, its parts are:

1. **Its head:** the orchestrator's state mark, the state in words (`working 12s`,
   `▲ waits on you`, `idle`, `◌ restarting`, `off`), and its context share. `` ` fold `` sits on the
   right.
2. **The feed**, drawn by arena from board.json, the same source as the board. arena draws it, not
   a Claude Code mod, so it is always at the top. It has four parts:
   - **▲ your move N**: everything the human has to act on, each item settled in place (see
     [the feed](#the-feed-settled-in-place)). With nothing in it, the part is one dim line,
     `nothing needs you`.
   - **◒ landing N**: tickets in babylon's pipeline, in queue order, each with its stage and how
     long it has been there. One row for each two tickets, up to two rows, then `+N`.
   - **◐ building N**: doing tickets, each with its holder's mark and age. `▲` marks one whose
     Claude waits on the human, `○` one no Claude holds. Two rows at most.
   - **✓ landed today N**: one line, and `⏎ recent` opens the board's recent column. Landings
     are never listed one by one here, because they wait until the human looks
     ([principle 8](principles.md)).
3. **A rule**, then **the orchestrator's live pane**: its transcript and its prompt, as today's
   column has. Typing into it is talking to it.

The feed takes what it needs, up to half the column's height. Past that, Your move scrolls inside
its part, and landing and building keep their two rows each.

**The feed points at the board.** Picking a feed item lights its card on the board with the dim
pick, as the rail and the board point at each other. Picking a card whose ticket has a Your move
item lights that item dim in the feed.

When the orchestrator is off, the pane's place says `orchestrator off · ⏎ start it`, which runs
`babylon orchestrator`. The feed is drawn from board.json, so it stays while the orchestrator is
off or restarting.

### Keys

In insert, every key goes to the orchestrator's prompt, as with any pane. In normal mode, with the
column focused:

| key | does |
| --- | --- |
| `j` `k` | the pick through the feed's items: Your move first, then next (auto's line at its top), then landing, then building |
| `]` `[` | the pick to the next or previous Your move item, from anywhere at home |
| `1`…`9` | answer the picked ask with that option |
| `⏎` | the picked item's first action: `go` on a proposal, `start` on a free send-back, and go to its Claude on a landing or building item |
| `x` | `no` on a proposal, `close` on a free send-back |
| `J` `K` | on a ticket of next, move it down or up; `p` pins it where it is, `x` drops it. Each goes through `babylon next` as the human, so the orchestrator moves a pinned one only with a proposal |
| `a` `H` | on auto's line, at the top of next: turn auto on or off, and hold on or off |
| `←` `→` `+` `-` | on auto's line, pick a repo of its caps and raise or lower it, 0 pausing it (`babylon auto --repo-cap REPO=N`); `h` goes back to the board from there |
| `G` | give the picked free send-back to a running Claude, as on the board |
| `c` | answer the picked ask in words, in a line at the column's foot |
| `o` `⏎` `y` | on a look at: open its doc (a repo file in a window of its own, in `glow` else `less`; a link by `xdg-open`), then say it looks good |
| `space` | the picked item's modal: the ask's or proposal's ([normal mode](normal-mode.md#an-asks-or-a-proposals-modal)), or the card's |
| `t` | the ticket's card modal |
| `h` | focus to the board, where `l` comes back |
| `i` | insert, into the orchestrator's prompt |
| `` ` `` | fold the column away, and unfold it |

A click on the feed picks an item, and a click on one of its buttons does what the button says. A
click on the pane is insert into it.

## The feed, settled in place

Every Your move item is one or two rows: what it is, then its buttons, written as the keys that do
them. Settling an item takes it out of the feed in the same frame. It does not leave behind a
confirming line, because babylon's answer is the confirmation: an item that babylon refuses stays
in the feed, with the reason in place of its buttons.

| kind | first row | buttons |
| --- | --- | --- |
| an ask | `#393 arena  asks: <question>` | its options `1`…`9`, `c in words`, `space whole` |
| a look at | `#307 tlon  look at: docs/asterion.md` | `o open`, `y looks good`, `c change` |
| a proposal | `P14 <what>: <why>` | `⏎ go`, `x no` |
| a free send-back | `✗ #290 arena  sent back, free: <the reason's first line>` | `G give`, `⏎ start`, `x close` |
| something only the human can do | `↻ restart arena: #452's change is installed` | `⏎ done` |

- An ask is open until it is answered. Its box takes as many rows as its options need, so the
  options are never cut.
- A send-back counts as **free** when no Claude holds it and nothing open blocks it (#480). A
  send-back held by a Claude goes under building with `✗`. A blocked one goes under building as
  `✗ #360 waits on #361`. Neither is the human's move.
- A proposal on a ticket shows its `▲ proposed` line on that card on the board too, and go or no
  there settles it the same way (#494).
- A thing only the human can do, such as restarting arena or the desktop shell after an install,
  is an ask the orchestrator files, with `done` as its option. arena can do one of those itself
  (restarting arena). For that one, `⏎` does it and the button says `⏎ restart now`.

`▲ N`, wherever it shows (the board header, the rail's top row, the bar), counts the Your move items
and nothing else.

## Home, at half the screen (105 cells)

The plan and the column do not both fit (a terminal under 110 cells), so home shows one of them at
a time, opening on the orchestrator. `p` swaps to [the plan](plan-view.md), `o` swaps back, and `B`
is the board from either. The way to the other is in each head row, so each always says that the
other is there; a click on it does the same.

`o` is one key for two things, told apart by where it is pressed: in the column it opens the picked
look-at's doc (as above), and in the plan it swaps back to the column. `p` in the column is the swap
at this width, so next's own `p` (pin it where it is) is not there; `J` `K` and `x` on the plan's
next are.

```
╭─────╮ ◐ orchestrator · working 12s · ctx 34%                     ▲ 3   ◒ #305   ◐ 3/4   b board
│▐▤▌  │ ─────────────────────────────────────────────────────────────────────────────────────────────
│ ar  │ ▲ your move 3
│ ◐320│ ╭───────────────────────────────────────────────────────────────────────────────────────────╮
│ ▲393│ │ #393 arena  asks: Ctrl+Space or Esc Esc for the mode?                                     │
│ ba  │ │ 1 Ctrl+Space   2 Esc Esc   c in words   space whole                                       │
│ ▲305│ ╰───────────────────────────────────────────────────────────────────────────────────────────╯
│ tl  │ ▌ P14 start #302 next: high, a day old, nothing blocks it                        ⏎ go   x no
│ ◐308│ ▌ ✗ #290 arena  sent back, free: the gate failed twice          G give   ⏎ start   x close
│ · 4 │ ◒ landing 2   #305 babylon reviewing 2m   #308 tlon queued 2nd
│     │ ◐ building 3  #320 arena 5m   #393 arena ▲ 4m   #14 tlon ○ 2d
│     │ ✓ landed today 6                                                                  ⏎ recent
│     │ ─────────────────────────────────────────────────────────────────────────────────────────────
│     │ ● #305 is reviewing. #393 waits on you for its mode key; that is the one decision
│     │   in front of you. I proposed #302 next since tlon's lane is free.
├─────┤
│ +   │ ❯
╰─────╯ ─────────────────────────────────────────────────────────────────────────────────────────────
 NORMAL  1 2 answer  c in words  space whole   │   j k pick  b board  i type to it   │   ? keys
```

At this width a proposal's or send-back's buttons sit at the end of its row, and landing and
building are one row each. Under about 60 cells the rail folds away as well, and the head keeps
`▲ 3` and `b`.

## The rail, narrow

At home the rail is narrow, as the board design has it, and it holds less. It shows each tmux
session, and under it only the Claudes that are **working** (`◐`) or **wait on the human** (`▲`),
each one by its ticket number (#358). The rest of the session's Claudes fold into one `· 4`
line: idle ones, those done or only queued in the pipeline (#427's fold). A pick or a click on
that line opens it, and hover peeks it (#392).

```
╭─────╮
│▐▤▌  │   home: lit while it is in front; ▲ 3 after it when the rail is wide
│ ar  │   arena
│ ◐320│   working on #320
│ ▲393│   waits on the human
│ ba  │   babylon
│ ▲305│
│ tl  │   tlon
│ ◐308│
│ · 4 │   four more, folded: idle, done, or queued
├─────┤
│ +   │
╰─────╯
```

A Claude whose ticket has landed, or was closed done with nothing to land, is ended, so it leaves
the rail by itself (#222, #242). The orchestrator is never in the rail, because it has its column.

**Sessions are reached through tickets.** On the board, `space` on a card opens its modal, `c`
there opens its Claude's popup, and `⏎` goes there ([normal mode](normal-mode.md#look-open-go)).
The rail is for the few that are moving or waiting.

## The bar and the hotkey

The desktop keeps one cell for all of this, in the top bar, where the waiting cell is today:

```
 ▲ 3 · orchestrator: working
```

| the orchestrator is | the cell says |
| --- | --- |
| working | `▲ 3 · orchestrator: working` |
| waiting on the human | `▲ 3 · orchestrator: waits on you`, in the attention colour |
| idle | `▲ 3 · orchestrator: idle` |
| answering a line told to it | `orchestrator: on it`, then `orchestrator: answered` until arena shows it |
| restarting or off | `orchestrator: restarting`, `orchestrator: off` |

`▲ 0` is drawn dim, never hidden, so the cell never changes width as N changes from or to nothing.
A click on the cell runs `arena inbox`, starting arena when none is running (exit 3).

**The hotkey is `Super+U`, which today opens the office rail. It is freed once the office rail is
removed.** It works from anywhere, with arena open or not:

1. `Super+U` opens a one-line entry at the top of the screen, like the launcher:
   `tell the orchestrator ❯ `.
2. `⏎` runs `babylon tell "<line>"`, and the entry closes at once. `Esc` closes it with nothing
   sent.
3. babylon types the line into the orchestrator's prompt as the human's word, through the same
   `Panes.tell` that `give` uses. While the orchestrator is mid-turn, babylon holds the line and
   types it when the turn ends. When the box already has text in it, babylon refuses, as `give`
   does, and the entry stays open and says why.
4. **The reply is seen where the orchestrator always speaks:** its pane in the column. The bar
   cell says `orchestrator: on it` while it works on the line, and `orchestrator: answered` once its
   turn ends. That stays until arena next shows the column. A click opens arena home with the
   column scrolled to the reply.
5. A reply that needs a decision is an ask, so it goes to Your move and raises a notice under the
   rules below. A plain reply raises no notice, because the human chose when to look.

`babylon tell` is a command like `go` and `give`: yours to run, never a Claude's. A script, a
phone shortcut or another hotkey can call it too ([principle 7](principles.md)).

**A personal line goes to the house, not here.** The entry tells only the work orchestrator, and
it never forwards a line between the two (#14). The house's orchestrator (tlon #512) can take its
own key on the same pattern, such as `Super+Shift+U` with a `tell the house ❯` entry running
Asterion's own tell. Which key it takes, and whether the house's bar cell sits beside this one, is
open, for #512 to settle.

## Notices

A desktop notice is raised only for something only the human can decide or do:

- an open **ask**, including the orchestrator's own (`restart arena now`, `done`);
- a new **proposal** from the orchestrator.

Nothing else raises one: not landings, installs, a send-back held by a Claude, a Claude that has
finished, or a reply to a told line. Those go to the orchestrator, and it shows them in its feed.
A free send-back raises none of its own: the orchestrator proposes what to do with it (give it,
start it, close it), and that proposal raises the notice.

Each notice says `▲ N need you · <the item's first row>`, and a click runs `arena inbox` on that
item. It is raised once, when the item first appears, and it is taken back when the item is
settled anywhere. While arena is in front with home showing, no notice is raised, because the feed
already shows it.

## What is removed

| where | what | why |
| --- | --- | --- |
| ficciones, the deck | its sessions cell and popup (`deck-sessions`) and its agents cell (`deck-agents`) | sessions are reached through tickets; the bar cell says the orchestrator's state |
| ficciones, the office rail | the whole rail and its `Super+U` | its Claude rows are the rail's, its asks and board line are the feed's |
| ficciones, notices | ask notices carrying the question (#349) | one `▲ N need you` notice per item, opening arena |
| babylon, notices | the landed and sent-back notices (`Pipeline`) | landings wait until looked at; a free send-back reaches the human as a proposal |
| arena, the board | the `orch` button, and the needs-you inbox as a view in the board's place (#341's view) | the column is always there, and its feed is the inbox |
| arena, the orchestrator | the Claude Code mod's feed (`hooks/board-feed.tsx`) | arena draws the feed at the column's top |

The rest of the deck (the log, media and the timer) stays.

## The build

Epic #525. Each step is one ticket. The arena steps form one stack, each on the one before. babylon's and
ficciones' steps stand alone, apart from what each one says it waits on.

arena:

1. **Home (#526; absorbs #252):** `arena` opens the board with the orchestrator's column pinned at
   60 cells, the column focused, `b` and the rail's top row going home, and `arena inbox` the
   door. The column survives an orchestrator restart. While it restarts, the head says
   `◌ restarting`, the board stays open, and the human stays where they were (#252's bug). The
   board's `orch` button goes. e2e: `tmux kill-session -t =orchestrator` with home open leaves home
   open and the column back on the new orchestrator.
2. **The feed at the column's top (#479, rescoped):** arena draws Your move, landing, building and
   landed today from board.json above the orchestrator's pane, with #480's rule for which
   send-backs are free. The mod's Pane goes. e2e: the feed's `▲ your move` sits above the pane's
   first transcript line.
3. **#480 closes into step 2:** its `rows()` test moves to arena's feed.
4. **Asks and send-backs settled in place (#341, rescoped):** `1`…`9`, `c`, `G`, `⏎ start`,
   `x close`, and `▲ N` in the board header, the rail and on cards moving focus to the feed. No
   inbox view in the board's place.
5. **Looks (#342, rescoped):** `o` and `y` on an ask that names a doc, in the feed.
6. **Proposals (#343, rescoped):** `⏎ go` and `x no` in the feed, the same call as #494's card
   buttons.
7. **Home at half width (#527):** one of the column and the plan at a time, with `p` and `o`, and `B`
   the board from either.
8. **The narrow rail holds only what moves (#528, after #427 and #358):** working and waiting
   Claudes, the rest folded per session into one line, and the orchestrator left out.
9. **The peek (#392)** covers feed items too. It is unchanged apart from that, and is not held.

babylon:

10. **`babylon tell TEXT` (#529):** the line typed into the orchestrator as the human's word,
    held while it is mid-turn, refused over text in its box, and refused from a Claude's pane.
11. **Notices only for decisions (#530):** a notice for a new proposal, none for landed or sent
    back. The orchestrator's prompt says to propose an action for each free send-back.
12. **#242** as filed: a Claude whose ticket is closed done with nothing to land is ended.

ficciones:

13. **The bar's orchestrator cell (#531):** `▲ N · orchestrator: <state>`, from the session
    state files and board.json, with a click running `arena inbox`.
14. **`Super+U` tells the orchestrator (#532, after 10 and 15):** the one-line entry running
    `babylon tell`.
15. **Remove the deck's session cells and the office rail (#533, after 13):** `deck-sessions`,
    `deck-agents`, `Office.tsx`, and the keys.json row for `Super+U` rewritten.
16. **Notices are `▲ N need you` and open arena (#349, rescoped):** one per item, raised once,
    taken back when settled, and none while arena's home is in front.

#494 (go and no on cards) is unaffected and lands on its own. #427 and the normal-mode stack
(#452) are unaffected, and step 8 builds on #427.
