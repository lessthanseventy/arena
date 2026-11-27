# What arena is

This page is for #1144. It is held to [the principles](principles.md). Where it and an older doc
disagree, this page wins. It supersedes parts of [No rail](no-rail.md) and
[Doing and Planning](doing-planning.md), and each says which at its top.

> Partly superseded by [The meta first](meta-first.md). Doing is Needs you, Heading for (or
> Projects) and one board, so in flight, other Claudes, next and landed leave it: the Claudes are
> one key away (`c`). Your move is titled Needs you. A Claude's pane in the middle column gains a
> path, its ticket's line and a side panel, and takes the room left of the drawer. Auto's modal
> becomes the settings card (`,`). The four surfaces, the one way anything opens, and how checks
> are answered all stand.

The human, 2026-11-26: "I started out wanting one thing and we drove somewhere else and got lost I
think. What should this all look like? What even is this?"

**What it is.** A personal software shop. The human sets direction, Claudes build, and babylon
gates, reviews and lands their work. Then the human checks it. arena is how the human sees and
steers all of that. It is not a multiplexer with a board on top. The tmux sessions are where the
Claudes run, and arena shows them only when the human asks.

**How it knotted.** arena began as a strip of tmux windows. A board, Plan, a drawer, a middle
column and Doing/Planning were laid over it, and nothing was taken out. So the multiplexer still
catches the human: a doc opens as a window on the strip, a new session takes the screen, and the
way home is a key nobody sees. Meanwhile "what needs you" was drawn in five places. This page
names four surfaces and one way to open things. Everything else is deleted.

## The four surfaces

There are four surfaces and nothing else. Each one answers one question.

| surface | answers | where |
| --- | --- | --- |
| **Your move** | what needs me? | the top window of Doing. Its count `▲ N` is in every head and foot |
| **Doing** | what is moving? | home: `b`, `◆ home`, `arena plan` |
| **Planning** | what comes after? | `tab` from Doing |
| **The orchestrator** | talk it over | the drawer, `o` from anywhere |

**Your move** is the only list of what needs the human. Each item is acted on where it stands,
with keys written on its row:

- a check: `y`, `n`, and `o open` when it has something to look at;
- an ask's options, and a proposal's go;
- a push, the digest, a restart;
- a Claude that waits in its pane.

The orchestrator's suggestions (#1141) are not in this list but in the drawer's foot, between its
chat and its prompt (#1176). A suggestion that points at a `needs_you` item marks that item's row
`◆ orch` and moves it to the top of Your move, and shows in the foot as a row that opens it. A
suggestion that is a line of text is a foot row only, at most six, one line each: `1`–`6`, `⏎`
(the first not yet picked) or a click types the line into the drawer's prompt without sending it,
each further one on a line of its own. Other places that show the same things only point to
Your move:

- **a desktop notice** is for a Your move item only, and a click on it opens arena with that item
  picked;
- **a ticket's card** is the item opened, not a second copy of it;
- **the next-step buttons** and **the drawer's foot** go.

```
┌─ ◆ YOUR MOVE │ 4 ─────────────────────────────────────────────────────────────┐
│ ▌>_ ◆ orch ▲ #1109 check 2: Plan opens a card beside the drawer  o open  y  n │
│ ▌>_ ◆ tell the orchestrator: rebase #1120 onto main                   ⏎ type  │
│ ▌☗  ▲ #588  waits in its pane: Allow `git push`?                        ⏎ open │
│ ▌>_ ↑ arena 3 commits not pushed                                       ⏎ push │
│                                                                               │
└───────────────────────────────────────────────────────────────────────────────┘
```

**Doing** is laid out as in [Doing and Planning](doing-planning.md#doing): Your move, then one line
for the goal being driven, then in flight with other Claudes at its foot, next (read-only), and
landed.

```
 ◆ [doing]  planning   every · arena · …   / find      ◐ auto 4/6  ◆ orch 12s  ▲ 4  ≡
┌─ ◆ YOUR MOVE │ 4 ─────────────────── … (above) ──────────────────────────────────┐
┌─ ◆ towards #1110 Doing and Planning   ████▒▒▒▒▒▒▒▒   1/5  20% ──────────────────┐
┌─ ◆ in flight │ 4 ─────────────────────────────┐ ┌─ ◆ landed │ 23 today ─────────┐
│ ▌>_ #1137 Nothing moves you off Plan  ◐ 12m  │ │ ✓ #1141 the suggest tool  1h  │
│ ▌☗  #588  babylon start N             ◇ 9m   │ │ ✓ #1133 checks in chat    2h  │
│ ── other Claudes 1 ───────────────────────── │ │                               │
│ ▌⌸  ◐ menard · indexing the repo      4m     │ │                               │
├─ ◆ next │ 3 ─────────────────────────────────┤ │                               │
│ 1 ▌>_ #1129 y/n answer the open check  ready │ │                               │
└──────────────────────────────────────────────┘ └───────────────────────────────┘
 NORMAL  ⏎ open  space card   │  j k pick  h l window  tab planning  o orch  │  ? keys
```

**Planning** is laid out as in [Doing and Planning](doing-planning.md#planning): goals with their
tickets, no goal, next (which can be reordered here), and the backlog. Every move is a key, a
click and a babylon command.

```
 ◆ doing  [planning]   every · arena · …   / find      ◐ auto 4/6  ◆ orch 12s  ▲ 4  ≡
┌─ ◆ goals │ 2 ─────────────────── + goal ┐ ┌─ ◆ next │ 3 ─────────────────────────┐
│ ▾ ◆ #1110 Doing and Planning  1/5  20%  │ │ 1 ▌>_ #1129 y/n answer the open…   │
│     ▌>_ #1112 Planning, read only  ○    │ ├─ ◆ backlog │ 3 ──────────────────────┤
│ ▸ #1135 Suggestions          1/3  33%   │ │ ◇ #846 reach the sessions from… idea│
├─ ◆ no goal │ 4 ─────────────────── + new ┤ │ · #323 the board as a window   later│
│ ▌>_ #1064 a key in the same burst  todo │ │                                     │
└─────────────────────────────────────────┘ └─────────────────────────────────────┘
 NORMAL  space card  a goal…  w next  d drive  + new  │  j k pick  tab doing  │  ? keys
```

**The orchestrator** is the drawer on the right, 60 cells wide. Plan narrows beside it (#1125).
It holds the orchestrator's chat and nothing else: no buttons, and no foot.

```
┌─ ◆ Doing, narrowed ───────────────┐ ┌─ ◆ orchestrator · working 12s ─────── × ┐
│ …                                 │ │ > check 2 of #1109 works                 │
│                                   │ │ ● Recorded: #1109 check 2 ok, "works".   │
│                                   │ │ > █                                      │
└───────────────────────────────────┘ └──────────────────────────────────────────┘
```

## The one way anything opens

**Everything opens in the middle column, and one way leads back: `esc`, or a click on `×`.** The
column is the one built in #1109, between Doing or Planning and the drawer. It shows one of two
things:

- **Text:** a ticket's card, a doc (rendered markdown, `j` `k` to scroll), the digest, a diff, or
  a push's commits.
- **A live pane:** a Claude's pane, a check's commands as they run, meatcheck over a diff, or
  `$EDITOR` on a ticket. The pane is sized to the column, as the drawer already shows the
  orchestrator's. It opens in normal mode, for watching, so `esc` closes it. `i` types into it,
  and while it is typed into, `esc` is the pane's (it stops a Claude's turn). `Ctrl+Space` gives
  normal mode back, and then `esc` closes the pane.

`⏎` on a Claude's row in in flight, or on a `waits in its pane` item, opens that Claude's pane in
the column. arena never shows a pane the human didn't open. A session or window babylon starts
only appears in in flight (#1137). arena makes no tmux window of its own to show something in.

**Go on a ticket starts its Claude and leaves the human where they are.** On 2026-11-26 the human
pressed go on #1144 in Your move, and arena dropped them on the strip, on #1144's pane. What they
saw:

- on the left, the neighbouring window's column, a Claude's `/changes` pane showing #1138's diff;
- on the right, the main checkout's window, its changes empty;
- the strip's foot row, `home | arena ● 1 2 3 4 5 · s go to`.

**Decided** (the human, 2026-11-26, to the orchestrator's answer: "that sounds right"). Go leaves
the human on Doing. A Claude's pane opens only from its row, in the middle column, with one
changes view for that ticket. `esc` goes back. The strip is never a place the human lands.

So the ticket shows up in in flight and Doing stays on screen. Opening
the row shows the Claude alone in the column, with no neighbours peeking in and no strip foot:

```
┌─ ◆ #1144 · arena · ◐ building 12m · t1144-one-page… ──────────────── × ┐
│ (the Claude's pane, live, sized to the column)                           │
│                                                                          │
│ ● Writing docs/what-arena-is.md                                          │
│ > █                                                                      │
├──────────────────────────────────────────────────────────────────────────┤
│ NORMAL  i type   d changes   space card   esc back                       │
└──────────────────────────────────────────────────────────────────────────┘
```

`d` turns the column between the pane and **that ticket's changes**: its branch's diff against
main, as text. It is the only changes view. Other tickets' changes are never drawn beside it.

**The strip stays, as the human's own terminal.** It holds the human's shells and anything with no
ticket, reached only from the switcher (`s`, then `⏎` on a session). Its keys stay as they are
(`h` `l` `H` `L` `J` `K` `;` `'` `c` `x` `z` `1`–`9`, the overview `O`, title drags), and its foot
row always starts `◆ home b`. A Claude is never reached through the strip.

**The rail** has been gone since #1029's build. What is left of it is the mock's `rail()`, which
still draws it on every screenshot except `alone`. It is deleted (see below).

## How the human checks work

- **Where checks show:** a landed ticket in try is one Your move item, with one row for each
  unsettled check. Opening the item shows the same rows in its card, in the middle column. A
  check shows nowhere else.
- **How they're answered:** there are two ways, and no third.
  - **On screen:** `y` passes the picked check, which is the first unsettled one (#1129). `n` asks
    for the human's words in a modal (principle 11).
  - **In chat:** the human tells the orchestrator, and it records the answer with `tried` and
    `said` holding the human's words (#1133). The card then shows "answered in chat: …".

  `! babylon tried` typed in a pane runs as that pane's Claude and is refused. So are the
  next-step buttons. Neither is a way to answer.
- **What a check must carry** (#1116): one line that says what to look at and what right looks
  like. A check that asks the human to read or see something names it with `doc` (a repo path or
  a URL), and its row has `o open`, which shows it in the column. A check that is the landed diff
  is a `look` check with its `range`, and `o open` shows the diff. A check written as a command
  runs in the column and passes on exit 0. A check to read or see something that names nothing
  to open is a bad check: the session that wrote it fixes it.

## What gets deleted

| what | where | replaced by |
| --- | --- | --- |
| docs opened as tmux windows `doc-*` (glow) | `openDoc`, src/app.zig | text in the middle column (#1137) |
| the `look` window (meatcheck over a diff) | `lookAtDiff`, src/app.zig | a live pane in the column |
| the `check #N` window | `checkStart`, src/app.zig | a live pane in the column. arena still reads its exit code from its files |
| the `ticket` window (`$EDITOR`, `babylon new`) | `ticketWindow`, src/app.zig | a live pane in the column |
| arena switching to a window babylon started | the switch path #1137 finds | the Claude appears in in flight, and nothing moves |
| `⏎` on a Claude row going to its window on the strip | `go` on in flight and other Claudes | its pane in the column |
| go on a ticket switching to its new Claude | Your move's and next's go | the Claude appears in in flight, and Doing stays |
| neighbouring windows' columns (their `/changes` panes) beside an opened Claude, and the strip's foot row | the strip, around a Claude's window | the column shows the one Claude, with `d` for its own ticket's changes |
| `n` in normal mode (`showInbox`, the same as `b`) | src/app.zig, `n` in the key table | `b`. `arena inbox` stays as an alias of `arena plan`, because notices call it |
| the drawer's foot of suggestions, as filed (not built) | #1142, #1143 | suggestion rows in Your move |
| the next-step mod | ficciones `modules/agents/mods/next-step/`, and its entries in `modules/agents/default.nix` and `modules/mac/default.nix` | Your move's suggestion rows, and the chat |
| the rail in the mocks | `rail()` and `Layout.rail` in src/mock.zig | nothing: the mock draws what arena draws |
| window folds (`▾` on a window's title, `z` on Plan) | already gone (#1108). The doc mocks follow in #1112 | none |

## What stays as is

These stay as they are:

- babylon, as the shop's floor: tickets, the gate, review and landing, `needs_you`, asks,
  proposals and suggestions.
- arena as a tmux client. The sessions live in tmux and outlast arena.
- The principles, the Workbench look, Doing's and Planning's windows and moves as their doc gives
  them, the switcher, `/` find, the menu, report this (`Alt+!`), the auto settings, normal and
  insert mode, and drag-to-copy.
- The verbs `arena plan [N]`, `arena show`, `arena planning [N]` and `arena inbox`.

One seam rule is added. A board that doesn't parse never blanks arena. Home shows babylon's error
in place of its windows (#1138).

## Each held ticket

| ticket | under this page |
| --- | --- |
| #1112 Planning, read only, and `tab` | **keep**, after #1127 |
| #1113 Planning's moves | **keep** |
| #1114 Doing trimmed | **keep**. It takes #1127's items 6 and 7 (window heights on Doing) |
| #1126 ticketless items open in the column | **keep**, after #1137, using its text view: the digest is a doc, and a push shows its commits as text |
| #1127 borders, and buttons by state | **keep**, before #1112 |
| #1135 suggestions (epic) | **rescope**: the suggestions are Your move rows, not a drawer foot |
| #1139 babylon zsh completion | **keep**. It doesn't touch arena |
| #1141 the `suggest` tool (done) | **keep**. Your move reads it |
| #1142 the drawer's foot | **close**. A new ticket replaces it: suggestions in Your move (the `◆ orch` mark, the text rows, `⏎ type`) |
| #1143 tick and send in the foot | **close**. Its "type the text into the prompt, unsent" moves into that new ticket |
| #1117, #1129, #1134, #1137, #1138 | **run now**, as the freeze says. #1137's column text view is what #1117's `o open` and #1126 show docs in |
| #1064 a key in the same burst | **keep** in the backlog |
| #323, #846 | **keep** in the backlog |

Tickets to file once the human has read this page, each held to it:

1. **arena:** Your move shows the orchestrator's suggestions, replacing #1142 and #1143.
2. **arena:** the middle column hosts a live pane. `⏎` on a Claude opens its pane there, with
   `d` for its ticket's changes, and go never leaves Doing.
3. **arena:** the `look`, `check #N` and `ticket` windows open in the column.
4. **arena:** the mock's rail goes.
5. **ficciones:** the next-step mod is removed.

## Decided by the human

The human, 2026-11-26, to the orchestrator's picks on this page's two open questions: "that all
sounds great".

1. **The strip stays only as the human's own terminal.** It is reached from the switcher and is
   never a place arena lands them.
2. **The next-step mod goes from every session,** not only the orchestrator's.
