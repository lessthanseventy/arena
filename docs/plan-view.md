# Home is the plan

This design is for #600, held to [the principles](principles.md) and to the seams (#587,
`docs/seams.md`), and read with [the orchestrator](orchestrator.md), whose words and column it
keeps. The human approved it as drawn on 2026-11-23 (ask #28). Nothing in it is built yet. The
build is the tickets at the end.

The human, 2026-11-23, looking at arena home: "is a 'board' the best shape here? … I just want to
be able to see what's going on and what's planned". To the orchestrator's sketch of now, next,
goals and landed: "that sounds right".

## Why

A kanban answers *what status is each ticket*. The human asks two other things: *what is happening
now*, and *what is the plan*. On 2026-11-23 the board had 125 todo cards, 65 of them labelled
follow-up. They filled the screen, and nothing on it said what comes next or why. The plan lived
only in the orchestrator's head and in its proposals.

So Home becomes the **plan**: what is running, what comes next and why, how far each goal has got,
and what landed. The board stays, one key away, as the drill-down for finding, editing and moving
a ticket. The orchestrator's column stays pinned on the right, with Your move at its top, exactly
as [the orchestrator](orchestrator.md#the-orchestrators-column) has it.

## The words

- **now:** every ticket a Claude or the pipeline is working, with its stage and how long it has been
  in it.
- **stalled:** a ticket in now that nothing is moving: its Claude has been idle with the ticket
  still doing, or no Claude holds it any more. babylon says which.
- **next:** an ordered list of tickets, each with a one-line why. It is real data in babylon, not
  the orchestrator's memory. auto starts from its top.
- **goal:** an epic, drawn as a strip of its steps.
- **not planned:** every todo ticket that is not in next. Most of them are follow-ups. It is folded
  to counts.

## Home, at the whole screen (210 cells)

The plan takes the board's place. The rail is narrow on the left, and the column is pinned on the
right at 60 cells, as today. The data is the live board of 2026-11-23 07:05Z; next is drawn as the
orchestrator would set it.

```
╭─────╮ ◆ plan  B board                     ◐ auto 3/4   ◒ landing 13   ✓ 179 today      ▲ 0 │ ◐ orchestrator · working 12s · ctx 34%          ` fold
│▐▤▌  │ ─────────────────────────────────────────────────────────────────────────────────────│ ──────────────────────────────────────────────────────────
│ ar  │ now 16                                                                               │ ▲ your move 0   nothing needs you
│ ◐600│ ▌ ◐ #600 arena    Design: Home is a plan view, not a kanban board   building · 6m    │
│ ◐334│   ◐ #334 arena    Board 2: one calm header in three groups          building · 22m   │ ◒ landing 13
│ ba  │   ◇ #510 tlon     Money: a safe-to-spend-per-day figure             stalled · idle 9m│   #587 arena  verifying 18m   #591 arena  verifying 8m
│ tl  │   ◒ #587 arena    Design: the seams                                 verifying · 18m  │   +11
│ ◐510│   ◒ #591 arena    One session-state hook                            verifying · 8m   │ ◐ building 3
│ · 4 │   ◒ #501 tlon     _got bumps done_week when the id is not waiting   reviewing · 29m  │   #600 arena 6m   #334 arena 22m   #510 tlon ◇ 9m
│     │   ◒ verifying 4   #560 arena  #502 tlon  #514 tlon  #522 tlon                        │ ✓ landed today 179                                 ⏎ recent
│     │   » queued 6      #588 babylon 1st  #429 babylon 2nd  #554 tlon 3rd  +3              │ ──────────────────────────────────────────────────────────
│     │                                                                                      │ ● #587 and #591 are verifying. #510 has been idle 9m with
│     │ next 5                                                                               │   its ticket still doing; I'll look at it. Next is #589,
│     │   1 #589 babylon  babylon start N                    ← after #588 lands: one babylon │   once #588 frees babylon's lane.
│     │                   the seams' verb every start goes through                           │
│     │   2 #594 arena    the board's start runs babylon start N          ← needs #589       │
│     │                   arena stops typing its own tmux new-window                         │
│     │   3 #590 babylon  restarts become a Your move item                ← needs #588       │
│     │                   the last guess the orchestrator makes for the human                │
│     │   4 #453 arena    Normal mode 2: the rail's pick moves with j k   free now           │
│     │                   the start of the normal-mode stack; nothing blocks it              │
│     │   5 #519 tlon     Asterion orchestrator 4: money's sources        ← needs #510       │
│     │                   the last step of the house's orchestrator                          │
│     │                                                                                      │
│     │ goals 4                                                                              │
│     │   Asterion orchestrator   #14   ✓✓✓✓✓✓✓✓✓✓✓✓ ◒◒ ○     12 of 15   ◒ #522 #520  ○ #519 │
│     │   the orchestrator front  #525  ✓✓✓✓✓✓ ○○             6 of 8     ○ #527 waits on #343│
│     │   the board, redesigned   #326  ✓✓✓✓✓✓ ◐ ○○○○○○○○○○○○○○ 6 of 21   ◐ #334             │
├─────┤   normal mode             #452  ✓ ●○○○○○○○             1 of 9     ● #453 next        │
│ +   │                                                                                      │
│     │ landed today 179   #322 arena held card e2e · #526 arena Home · #529 babylon tell · …│ ❯
│     │ not planned 120, 65 follow-ups     arena 61 · babylon 35 · tlon 20 · ficciones 3 · +1│
╰─────╯ ─────────────────────────────────────────────────────────────────────────────────────┴──────────────────────────────────────────────────────────
 NORMAL  ⏎ go to its Claude  space popup  t ticket   │   j k pick  ] [ your move  l orchestrator   │   B board  / find  ? keys
```

### Piece by piece

1. **The head:** `◆ plan` is lit, `B board` is the way to the drill-down. Then auto, the pipeline,
   the day's landings, and `▲ N`, each said once and each a button (as Board 2 has it).
2. **Now:** one row per ticket a Claude is building, then the pipeline's tickets in flight, each with
   its stage and how long it has been in that stage. The marks are the house's: `◐` building, `▲`
   its Claude waits on the human, `◒` in the pipeline, `◇` stalled. A stalled row says why in place
   of its stage (`idle 9m`, `no Claude`), in the attention colour. Pipeline tickets in the same
   stage past the first two fold into one row (`◒ verifying 4 …`), and queued ones into `» queued N`
   with their places. Building rows never fold: there are at most auto's cap of them.
3. **Next:** the ordered list, numbered. Each item is two rows: the ticket and what it waits on
   (`← needs #589`, `← after #588 lands: one babylon` for a repo's lane, or `free now`), then its
   why, dim. Up to seven items show; past that, `+N`.
4. **Goals:** one row per open epic, in the order babylon gives. The strip is one mark per step in
   the epic's own order: `✓` landed, `◐` building, `◒` in the pipeline, `●` in next, `○` waiting,
   `✗` sent back. Then `N of M` landed, then the steps that are moving or next by number, or what
   the first waiting step waits on.
5. **Landed today:** one row, the count then the newest few by title. They are never a list here,
   because landings wait until the human looks ([principle 8](principles.md)).
6. **Not planned:** one row of counts by repo, with the follow-ups among them counted on the right.
   It is the rest of todo, and it is not the plan.

When the plan is taller than the screen, it scrolls as one list under the head, and the pick keeps
itself in view.

**The plan points at the column, and the column at the plan.** Picking a row whose ticket has a
Your move item lights that item dim in the feed. Picking a feed item lights its ticket's row dim
in the plan, as the feed does with the board today.

## Home, at half the screen (105 cells)

As [the orchestrator](orchestrator.md#home-at-half-the-screen-105-cells) has it, home shows one of
two things at a time and opens on the orchestrator. `p` swaps to the plan and `o` swaps back. `B`
is the board from either.

```
╭─────╮ ◆ plan · ◐ auto 3/4 · ◒ 13 · ✓ 179                                 ▲ 0   o orchestrator   B board
│▐▤▌  │ ───────────────────────────────────────────────────────────────────────────────────────────────
│ ar  │ now 16
│ ◐600│ ▌ ◐ #600 arena    Design: Home is a plan view          building 6m
│ ◐334│   ◐ #334 arena    Board 2: one calm header             building 22m
│ ba  │   ◇ #510 tlon     Money: safe-to-spend per day         stalled · idle 9m
│ tl  │   ◒ #587 arena  verifying 18m   #591 arena verifying 8m   #501 tlon reviewing 29m
│ ◐510│   ◒ verifying 4  » queued 6
│ · 4 │ next 5
│     │   1 #589 babylon  babylon start N                      ← after #588 lands
│     │   2 #594 arena    the board's start runs babylon start ← needs #589
│     │   3 #590 babylon  restarts become a Your move item     ← needs #588
│     │   4 #453 arena    Normal mode 2                        free now
│     │   5 #519 tlon     Asterion orchestrator 4              ← needs #510
│     │ goals 4
│     │   #14   ✓✓✓✓✓✓✓✓✓✓✓✓◒◒○        12 of 15
│     │   #525  ✓✓✓✓✓✓○○              6 of 8
│     │   #326  ✓✓✓✓✓✓◐○○○○○○○○○○○○○○  6 of 21
├─────┤   #452  ✓●○○○○○○○             1 of 9
│ +   │ ✓ 179 today   not planned 120 · follow-ups 65
╰─────╯ ───────────────────────────────────────────────────────────────────────────────────────────────
 NORMAL  ⏎ go  space popup  t ticket   │   j k pick   │   o orchestrator  B board  ? keys
```

At this width titles are cut, the pipeline folds to two rows, next drops its why rows, and goals
drop their names. The picked row's whole title and why show in the foot bar's first group instead.
Under about 60 cells the rail folds away, and the head keeps `▲ N`, `o` and `B`.

## Keys and the pick

At home, normal mode, the plan focused. `j` `k` move the pick through every row: now, next, goals,
landed, not planned. `]` `[` still go to Your move, `l` to the orchestrator's column and `h` back.
`space` opens, and `⏎` goes, as [principle 4](principles.md) has it.

| on a row in | `⏎` | `space` | other keys |
| --- | --- | --- | --- |
| **now**, building | go to its Claude, into insert | its Claude's popup | `t` its ticket's modal |
| **now**, stalled | go to its Claude; with none, `babylon start N` | the popup, or the card's modal with no Claude | `G` give it to a running Claude, as on the board |
| **now**, in the pipeline | the gate's modal for its run | the same | `t` its ticket |
| **now**, a folded row | unfold it into one row per ticket | | |
| **next** | `babylon start N` now, ahead of auto | the card's modal, its why whole | `J` `K` move it down or up, `x` take it out of next, `e` edit its why |
| **goals** | the board, showing only this epic's cards | the epic's modal: its steps one per row, `j` `k` and `⏎` on each as on next or now | |
| **landed today** | the board's recent column | | |
| **not planned** | the board, showing only todo cards not in next | | |

Unfolding a folded now row is the one place a row grows. It is a *go* (`⏎`), not a look, so
[principle 5](principles.md) holds: looking never moves anything.

The keys change from [orchestrator.md](orchestrator.md#what-arena-shows-on-open) in one way: `b`
still goes home from anywhere, and home now shows the plan. `B` is the board, from anywhere in
normal mode, and `b` from the board comes home to the plan. A click on the head's `◆ plan` and
`B board` does the same.

On the board, a picked todo card's key bar gains `n next`: it adds the card to the bottom of next
and asks for its why in a line at the foot. Dragging a card onto the board's `▤ board` title, the
way back to the plan, is the same. Dragging a next row onto another on the plan takes that place.

## Who sets next, and where its why lives

Next is a list in babylon, one row per ticket: the ticket, its place, its why, and who set it
(`orchestrator` or `human`). It is kept in its own table, not on the ticket, so taking a ticket out
of next forgets the why, and a ticket's own `sort` and `priority` keep meaning what they mean on the
board.

- **The orchestrator** keeps next. Its prompt says: keep next to what should start in the coming
  hours, at most about seven, each with a why the human can read in one line. It uses the
  `plan_next` MCP tool, or `babylon next 589 --why "…" [--at 1]` and `babylon next 589 --drop`.
- **The human** moves items with `J` `K` or by dragging, takes one out with `x`, edits a why with
  `e`, and adds one with `n` on the board. Each of these runs the same `babylon next …` line
  ([principle 7](principles.md)). An item the human placed is marked `human`, and the
  orchestrator's prompt says not to reorder past it without a proposal.
- **auto takes from the top of next.** While auto is on and has room, it starts the first item in
  next that is free (nothing blocks it and its repo's lane has room). Only when nothing in next is
  free does it fall back to today's order (priority, then the board's order). A started item leaves
  next, because it is now in now. So next is what will actually happen next, not a wish list, and
  the orchestrator needs no `start #N next` proposal while auto is on.
- **What an item waits on** is babylon's to say, not arena's: its open blockers, its repo's lane
  being full (`after #588 lands: one babylon`), or nothing (`free now`).

## What babylon publishes

Per the seams (rule 5), babylon computes the plan and arena only draws it. `board.json` gains one
key, `plan`, each list in the order arena shows it:

```json
"plan": {
  "now": [
    {"ticket": 600, "repo": "arena", "title": "…", "state": "building", "stage": null,
     "since": "2026-11-23T07:04:00Z", "pane": "%757", "stalled": null},
    {"ticket": 510, "repo": "tlon", "title": "…", "state": "building", "stage": null,
     "since": "2026-11-23T07:02:41Z", "pane": "%575", "stalled": "idle 9m"},
    {"ticket": 588, "repo": "babylon", "title": "…", "state": "landing", "stage": "queued",
     "since": "2026-11-23T06:57:41Z", "place": 1, "stalled": null}
  ],
  "next": [
    {"ticket": 589, "repo": "babylon", "title": "…", "why": "the seams' verb every start goes through",
     "set_by": "orchestrator", "waits_on": [{"lane": "babylon", "until": 588}],
     "actions": [{"label": "start", "argv": ["babylon", "start", "589"]},
                 {"label": "drop", "argv": ["babylon", "next", "589", "--drop"]}]}
  ],
  "goals": [
    {"epic": 326, "title": "…", "doc": "docs/board-design.md", "landed": 6, "total": 21,
     "steps": [{"ticket": 333, "state": "landed"}, {"ticket": 334, "state": "building"},
               {"ticket": 335, "state": "waiting", "waits_on": [{"ticket": 334}]}]}
  ],
  "landed_today": {"count": 179, "newest": [322, 526, 529]},
  "not_planned": {"count": 120, "follow_ups": 65,
                  "by_repo": {"arena": 61, "babylon": 35, "tlon": 20, "ficciones": 3, "menard": 1}}
}
```

- `since` is when the ticket entered its current status or stage. babylon does not keep that today
  (only `claimed_at` and `submitted_at`), so tickets gain a `stage_at`, stamped on every status and
  stage change.
- `stalled` reads the session record (`$XDG_RUNTIME_DIR/sessions`, written by arena's hook once
  #591 lands): a doing ticket whose Claude has been idle past five minutes with no open ask, or
  whose claiming pane is gone (`no Claude`). A Claude waiting on an ask is `▲`, not stalled.
- `goals` carries every step, not only today's, because `tickets` carries done tickets for one day
  only. Its steps are the epic's children in the board's order.
- `landed_today` counts the human's day, not the last 24 hours.
- The rest of `board.json` stays as it is. The board still reads `tickets` and `backlog`.

## The board epic, #326

The board is no longer Home. It is where the human goes to find a ticket, read it whole, edit it or
move it. Board 2–15 against that:

| ticket | keep or close | why |
| --- | --- | --- |
| #334 Board 2, the header | keep (running) | the board still needs a calm head, and the plan's head is drawn on the same pattern |
| #335 Board 3, columns by repo | keep | finding by repo is half of drilling down |
| #336 Board 4, cards as tall as their text | keep | the board is where a ticket is read |
| #338 Board 5, the picked card's box | keep | it is where edit, move and give live |
| #339 Board 6, the key bar | keep | [principle 1](principles.md) |
| #340 Board 7, recent with ages | **close** | landed today on the plan says it; `⏎` there opens the recent column as it is |
| #341, #342, #343, Board 8–10 | unchanged here | already the feed's, as rescoped by #500 and the seams. Move them under #525 |
| #344 Board 11, now and next at half width | **close** | the plan at half width is now and next |
| #345 Board 12, the rail narrow beside the board | **close** | home's narrow rail is #528's, and the board is no longer home |
| #346 Board 13, find with `/` | keep, and first | finding is what the board is now for |
| #347 Board 14, drag between columns | keep | moving is the other half; drag onto next comes with it |
| #348 Board 15, README and screenshots | keep, rescoped | it shows Home as the plan and the board as the drill-down, last in the stack |
| #349, the notices | unchanged here | ficciones', as rescoped by the seams |

The kept board tickets stay held until the plan's first arena step (#618) lands, so Home changes before
the board is polished.

## The build

Epic #612.

babylon, in order:

1. **Next as data (#613):** a `plan_next` table, `babylon next N [--why TEXT] [--at K] [--drop]`, the
   `plan_next` MCP tool, and `set_by`. A started ticket leaves next.
2. **auto takes from next first (#615)**, then falls back to today's order.
3. **`stage_at` (#614)** on tickets, stamped on every status and stage change.
4. **`plan` in board.json (#616):** now (with `since` and `stalled`), next (with `waits_on` and actions),
   goals with all their steps, landed today by the human's day, and not planned. After 1 and 3,
   and after #591 for `stalled`.
5. **The orchestrator's prompt (#617)** keeps next and its whys, and stops proposing `start` while auto is
   on. After 1.

arena, one stack:

6. **Home draws the plan (#618)** in the board's place at the whole width: now, next, goals, landed and
   not planned, with `j` `k`, `⏎` and `space` per row as above, `b` home and `B` the board. After 4.
   e2e: `arena` opens on `◆ plan` with the column pinned, and `B` shows the board.
7. **Next is edited from the plan (#619):** `J` `K`, `x`, `e`, and `n` on a board card, each running
   `babylon next`.
8. **The plan at half width (#527, rescoped)**, swapped with the orchestrator by `p` and `o`. It rescopes #527 from
   board-or-column to plan-or-column.
9. **The plan and the feed point at each other (#620)**, with the dim pick.
10. **Drag onto next (#621)**, with #347.

#526 (Home, landed) stays, and step 6 builds on it.
