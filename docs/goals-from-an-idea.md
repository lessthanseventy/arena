# Goals from an idea

This design is for #812, held to [the principles](~/projects/ficciones/docs/principles.md) and read with
[Home is the plan](plan-view.md), whose goals section it grows. The human approved it as drawn on
2026-11-24 ("go, file the build tickets"). Nothing in it is built yet. The
build is epic #813, the tickets at the end.

The human, 2026-11-24: "a 'goal' is kinda sorta an epic right? so like if i have a pie in the sky
idea, i could type it somewhere and have something break it out into tickets and plan the work".
To the orchestrator's shape (a front door on Plan, keep it or plan it now, an Opus planning
session, one approval, a goal you pick): "go, file it".

## The words

- **idea:** an epic in the backlog with no steps. It is kept, not planned, and nothing starts it.
- **planning:** an idea an Opus Claude is breaking out. It asks the human what it cannot decide.
- **draft:** an idea whose steps are filed, in the backlog, and wait on the human's go.
- **goal:** an epic whose steps are todo or further: what Plan's goals section shows today.
- **driving towards:** the one goal the human picked. next fills from it first.

An idea, a planning idea and a draft are the same epic at three moments. Each is told from the
others by what babylon already holds: its steps, a `plan` ticket on it, and an open look on it.

## The front door: `+ goal`

Plan's goals window gets `+ goal` on its title bar, on the right, as a button. `+` does the same
from anywhere on Plan in normal mode, as `+` files a ticket on the board.

It opens a modal over Plan's middle, in insert mode, with the cursor in the field:

```
            ┌─ ◆ a new goal ──────────────────────────────────────────────── ✕ ┐
            │                                                                  │
            │  what should be true when it's done? as rough as you like        │
            │ ▗▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▖  │
            │ ▐ the house's money shows on the desktop bar: what's safe to  ▌  │
            │ ▐ spend today, and a nudge when a bill is due█                ▌  │
            │ ▐                                                             ▌  │
            │ ▝▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▘  │
            │                                                                  │
            │   ▐ ⏎ plan it now ▌    ▐ k just keep it ▌    ▐ q cancel ▌         │
            │                        an Opus Claude breaks it out into steps   │
            └──────────────────────────────────────────────────────────────────┘▌
              ▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀
 INSERT  esc done typing   │   ⏎ plan it now  k keep it  q cancel
```

- **Typing:** every key goes to the field ([principle 3](~/projects/ficciones/docs/principles.md)); it wraps, and `⏎` ends
  typing. `esc` ends typing too. The mode word turns to NORMAL, and the buttons light.
- **Driving it:** `⏎` plan it now (the primary, filled), `k` just keep it, `i` back to typing, `q`
  cancel. Each button is a click too. Under the picked button, one dim line says what it does.
- **The title** is the idea's first line, cut at a sentence end or 70 cells; the whole text is the
  epic's body. The planning Claude writes the outcome line later, and it becomes the title then.
- **What runs** ([principle 7](~/projects/ficciones/docs/principles.md)): `babylon idea "…"` to keep it, and
  `babylon idea "…" --plan` to plan it now. The modal closes on the command's answer, and the new
  idea's row on Plan is picked.

## Ideas on Plan

Goals stay the epics that have work under way. Ideas, planning ideas and drafts sit at the foot of
the goals window, one row each, under a thin rule. Past three of them, they fold to `+N ideas`.

```
 ◆ goals │ 4                                                              + goal ▫
 ┌──────────────────────────────────────────────────────────────────────────────┐
 │ #326 The board, redesigned: an app, not a terminal dump                      │
 │ ████████████████████████████████████████▒▒▒▒▒▒▒▒▒▒▒▒▒   13/18  72%            │
 │ next  ◐ #760 building                                                        │
 │ ...                                                                          │
 │ ── ideas 3 ────────────────────────────────────────────────────────────────  │
 │ ▌✎ #830 money on the desktop bar        ◐ planning · Opus · 4m   ▲ asks you  │
 │  ☐ #831 a weekly retro I can read on my phone       draft · 7 steps · look   │
 │  ○ #829 asterion learns the garden                  idea · kept 2d           │
 └──────────────────────────────────────────────────────────────────────────────┘
```

- **idea** `○`: kept, with its age. `⏎` plans it now (`babylon idea 829 --plan`), `space` opens its
  modal with the whole text, `e` edits it, `x` withdraws it.
- **planning** `◐`: its Claude's state as a chip, and `▲ asks you` in the "you" colour when it has
  an ask open. `⏎` goes to that Claude, as on a now row.
- **draft** `☐`: its step count and `look`. `⏎` and `space` open the draft modal (below).

## The planning Claude

`--plan` files a **plan ticket** for the idea, starts it at once and does not wait for next. The
plan ticket:

- is titled `Plan #830: <the idea's title>`, labelled `plan`, model Opus, and `relates` to the
  epic. It is not a step of the epic, so it never counts in the epic's bar;
- has no repo: an idea may touch several. babylon starts it in `~/projects` with no worktree and
  no repo lane, as it writes no code;
- carries the planning brief in its body. The brief says to read the repos the idea touches, to
  ask_human what it cannot decide (a choice, not a guess), and then to draft.

**The draft** is real tickets, filed in the backlog under the epic, so it can be read and edited on
the board like any other card:

- the epic's title becomes the outcome in one line: what is true when it's done (as #14 is);
- each step has its title, repo, model and body, written as a specified ticket a Sonnet can build;
- the steps are in order, with `blocks` links where one waits on another.

Then the Claude asks the human to look at the epic: an ask with no options and no doc, on the
epic. A reply with changes comes back to it as the ask's answer. It changes the draft and asks
again. On go, its plan ticket is done. Nothing it did lands on main, so it closes its ticket
with update_ticket rather than submit_ticket.

## The draft, for the human's go

The look reaches Your move as one tile:

```
 ▲ your move │ 2
 ┌──────────────────────────────────────────────────────────┐
 │ ▐ draft ▌ #830 money on the desktop bar                  │
 │ 7 steps in 3 repos: tlon 3, ficciones 3, babylon 1        │
 │ ▐ y go ▌  ▐ r reply ▌  ▐ space read it ▌                  │
 └──────────────────────────────────────────────────────────┘
```

`space` on it, or `⏎`/`space` on its row on Plan, opens the draft modal: the epic whole, with its
steps one per row, as the epic's modal on Plan already lists them, plus each step's repo, model and
what it waits on.

```
   ┌─ ☐ draft #830 ─────────────────────────────────────────────────────────── ✕ ┐
   │ The desktop bar shows what's safe to spend today, and nudges a bill        │
   │ due in two days                                                            │
   │ from your idea: "the house's money shows on the desktop bar: what's s…"    │
   │                                                                            │
   │   1 #832  tlon       Sonnet  safe-to-spend as a JSON file   free           │
   │ ▌ 2 #833  tlon       Sonnet  bills due in the next 7 days   free           │
   │   3 #834  ficciones  Sonnet  the bar reads tlon's file      ← #832         │
   │   4 #835  ficciones  Sonnet  the money chip and its peek    ← #834         │
   │   5 #836  tlon       Sonnet  a nudge two days before a bill ← #833         │
   │   6 #837  ficciones  Haiku   the nudge as a desktop notice  ← #836         │
   │   7 #838  babylon    Sonnet  the digest counts money nudges ← #836         │
   │                                                                            │
   │ asked you: "tlon or ficciones for the nudge's timer?" you: "tlon"          │
   │                                                                            │
   │ ▐ y go ▌   ▐ r reply with changes ▌   ▐ e edit a step ▌   ▐ q close ▌      │
   └────────────────────────────────────────────────────────────────────────────┘▌
 NORMAL  j k pick a step  space its ticket  e edit it   │   y go  r reply  q close
```

- **`y` go** runs `babylon adopt 830`: the epic's backlog steps go to todo, the look is answered
  "looks good", and the plan ticket is closed. The epic is now a goal, and its row moves up among
  the goals. The orchestrator puts its free steps in next as their blocks clear, as it does any
  goal's.
- **`r` reply** opens a line at the modal's foot, in insert mode. It is sent as the look's answer,
  so it reaches the planning Claude, and the row turns back to `◐ planning`.
- **`e`** edits the picked step in place, as `e` does on the board. Small fixes need no round trip.
- The asks the Claude made while planning, with the human's answers, are listed under the steps,
  so the go is taken knowing what was decided.

Withdrawing a draft (`x` on its row) withdraws its steps and the plan ticket, and leaves the idea
kept, so nothing is lost.

## Driving towards, picked

Today the focal window shows the first goal with a step building. It becomes the goal the human
picked:

- **`d`** on a goal's card (or its focal window's title bar, clicked) makes it the goal Plan drives
  towards: `babylon drive 326`. The focal window's title says `driving towards · your pick`.
- **next fills from it first.** The orchestrator's prompt says to put the driving goal's free
  steps at the top of next before anything else, and to say so in the why
  (`the goal you're driving towards`).
- With no pick yet, the focal window is as it is today, and its title says
  `driving towards · d to pick`.

When the driving goal lands its last step, the focal window asks for the next one, instead of going
quiet:

```
 ┌─ ◆ DRIVING TOWARDS ─────────────────────────────────────────────────────────┐
 │ ✓ #14 The house is for personal life, not a software factory     40/40      │
 │ landed. what next?                                                          │
 │ ▐ 1 #326 the board, redesigned 72% ▌ ▐ 2 #500 the orchestrator 75% ▌        │
 │ ▐ 3 #830 money on the desktop bar · draft ▌    ▐ + a new goal ▌             │
 └─────────────────────────────────────────────────────────────────────────────┘
```

The same question is a Your move item (`goal landed: what next?`), because it is a decision only
the human makes ([principle 8](~/projects/ficciones/docs/principles.md)). `1`…`9` or a click picks; `+` opens the `+ goal`
modal.

No sprint dates and no points. The bar is the pace.

## What babylon holds and publishes

Every state comes from what babylon has, plus one field:

| | held as |
| --- | --- |
| idea | an epic, `backlog`, with no steps and no open `plan` ticket |
| planning | an epic with an open ticket labelled `plan` that `relates` to it |
| draft | an epic whose steps are all `backlog`, with an open look on it |
| goal | an epic whose status is `todo` or `doing` |
| driving | `driving`, an epic id, in babylon's orchestrator settings row |

An epic filed `backlog` keeps that status: `refresh_epic` derives it only when a step changes, and
steps filed in the backlog derive `backlog`.

`board.json`'s `plan` changes in three ways:

```json
"plan": {
  "driving": 326,
  "goals": [ "...as today, without backlog epics..." ],
  "ideas": [
    {"epic": 830, "title": "money on the desktop bar", "state": "planning",
     "plan_ticket": 839, "pane": "%1502", "asks": 1, "since": "2026-11-24T20:01:00Z"},
    {"epic": 831, "title": "a weekly retro I can read on my phone", "state": "draft",
     "body": "a retro I can read on my phone, weekly", "steps": 7, "ask": 61,
     "asks": 0, "ask_list": [{"id": 58, "question": "weekly or daily?", "answer": "weekly"}],
     "since": "..."},
    {"epic": 829, "title": "asterion learns the garden", "state": "idea", "since": "..."}
  ]
}
```

Your move (`needs_you`) gains two kinds: `draft`, a look on an epic, with `y go` running
`babylon adopt N` and `r reply`; and `drive`, the landed driving goal, with one action per open
goal and draft.

## The build

babylon, in order:

1. **Ideas (#814).** `babylon idea TEXT [--plan]` and `babylon idea N --plan`, and an MCP tool
   `file_idea`: an epic filed `backlog`, its title cut from the text and the text as its body.
   `plan.ideas` in board.json with each idea's state, and `plan.goals` without backlog epics.
2. **The plan ticket (#815).** `--plan` files the plan ticket (label `plan`, Opus, no repo, `relates` the
   epic, the planning brief in its body) and starts it at once in `~/projects` with no worktree and
   outside the lanes. After 1.
3. **The draft's go (#816).** `babylon adopt N` (backlog steps to todo, the look answered, the plan
   ticket done), and the `draft` kind in needs_you. After 2.
4. **Driving (#817).** `driving` in the orchestrator's settings, `babylon drive N`, `plan.driving`, the
   `drive` needs-you item when it lands, and the orchestrator's prompt filling next from it first. After 1.

arena, one stack:

5. **`+ goal` (#818).** The button on the goals window's title bar, `+` on Plan, and the modal with its
   two choices, running `babylon idea`. After 1 and 2.
6. **Ideas on Plan (#819).** The ideas rows under the goals, with `⏎`, `space`, `e` and `x` per state.
   After 1.
7. **The draft (#820).** The draft tile in Your move and the draft modal, with `y`, `r` and `e`. After 3
   and 6.
8. **Driving, picked (#821).** The focal window from `plan.driving`, `d` on a goal, and the "what next?"
   window. After 4.
