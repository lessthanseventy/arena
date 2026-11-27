# To try

This design is for #833, held to [the principles](~/projects/ficciones/docs/principles.md) and read with
[the orchestrator](orchestrator.md), whose Your move it grows. The human approved it as drawn on
2026-11-24 ("go, file the build tickets"). Nothing in it is built yet. The build is epic #837,
the tickets at the end.

The human, 2026-11-24, looking at #825's `▲ asks you` card: "do we need to call out somewhere
stuff that I need to look at/review/verify? Like 825 I guess. There's going to be some stuff the
machine can verify and some stuff it needs me to do". To the orchestrator's shape (a "you check"
list, a to-try state after landing, a to-try section in Your move, `▲ try it`): "go, file it".

## The words

- **check:** one step only the human can do or judge: a phone round trip, how a screen looks,
  whether an answer is right. It is one line, written so it can be done without reading the
  ticket ("ask the bot 'how much have I spent this week?': it matches `house:soak -- day`").
- **you check:** a ticket's list of checks. Most tickets have none. Everything not on it is the
  machine's: tests, the gate, review, soak.
- **to try:** a ticket that has landed and has checks still open. Its code is on main. It is not
  done until the human has tried it.
- **tried:** a check the human has settled, `✓` or `✗` with their words.

## Writing the list

Checks are written by whoever knows them, at any time before the ticket is tried:

- the session filing a ticket, as `checks` on `file_ticket`;
- the session that claims it, when it reads the work, and again when it finds a step mid-work:
  `add_check` (MCP) or `babylon check 825 "…"`;
- the orchestrator, when it triages a ticket the human filed;
- babylon's reviewer, when it sees a change with a step only the human can judge and no check
  for it. It adds the check and does not send the ticket back for it.

A check is one row of its own, not a section of the body: babylon never parses a body. A session
can reword or drop a check it wrote with `update_check` until the ticket lands.

**The stop hook stays as it is.** A hook cannot tell a change that needs a human's eye from one
that doesn't, and a heuristic there would nag every session. The two moments that matter say it
instead:

- `claim_ticket`'s answer ends with one line: "steps only the human can do or judge go on its
  list with add_check; it has N".
- `submit_ticket`'s answer names the list: "you check: 3 (reminder, money question, to-do)", or
  "you check: none, so it is done when it lands". A session that sees "none" on a change with a
  screen in it adds the check before babylon's reviewer has to.

## Landing to try

A ticket with checks lands through the gate as today: rebase, gate, review, fast-forward. Then
its status is `try`, not `done`. With no checks it goes to `done` as today.

- **It does not block.** A ticket blocked by a to-try ticket is free: the code it waits on is on
  main. A `✗` later sends the to-try ticket back for a fix on top of main, and the ticket built on
  it carries on. A ticket that truly waits on the human's verdict says so with its own check.
- **Its session ends** as a landed session does today. A to-try ticket can wait days, and a
  session left open for it is a session doing nothing.
- **Its epic** counts it as landed in the bar (its code is on main) and is not done while it is
  to try, so a goal whose last step waits on the human reads `▲ 1 to try` beside its bar.
- **No notice.** Landing to try is progress, not a decision ([principle 8](~/projects/ficciones/docs/principles.md)): it
  goes into Your move and the digest, and `▲ N` counts it, but nothing pops up.

## In Your move

To try is its own section in the feed, under the decisions (proposals, asks, looks) and over
send-backs. Each to-try ticket is one tile: its title, what the machine already did in one dim line,
then its checks, one row each.

```
 ▲ your move │ 3
 ┌──────────────────────────────────────────────────────────┐
 │ ▐ ask ▌ #760 arena  asks: which visual direction?        │
 │ ▐ 1 Phosphor ▌ ▐ 2 Workbench ▌ ▐ c in words ▌            │
 └──────────────────────────────────────────────────────────┘
 ── to try 2 ──────────────────────────────────────────────────
 ┌──────────────────────────────────────────────────────────┐
 │ ▐ try ▌ #825 tlon  house soak day                     2h │
 │ machine: soak day ✓  gate ✓  review ✓   landed f962a56   │
 │ ▌1 remind me in two minutes: it is told, with buttons    │
 │    ▐ y ✓ ▌ ▐ n ✗ ▌                                        │
 │  2 how much have I spent this week? matches soak day   ✓ │
 │  3 add a to-do, then done it, from the phone             │
 └──────────────────────────────────────────────────────────┘
 ┌──────────────────────────────────────────────────────────┐
 │ ▐ try ▌ #811 arena  plan · board tabs                 5m │
 │ machine: gate ✓  review ✓   landed 3c1e9a0               │
 │  1 click plan · board both ways: each tab goes, the lit  │
 │    one does nothing                                      │
 └──────────────────────────────────────────────────────────┘
```

- **Each check is a row the pick lands on.** `j` `k` move through them as through any feed item,
  and `]` `[` go from tile to tile. Only the picked check shows its buttons, so a tile stays as
  short as its list.
- **`y` ✓** settles the picked check and moves the pick to the next open one. The row keeps a dim
  `✓` on its right.
- **`n` ✗** opens a modal over the column for what went wrong, the check quoted above its box.
  `⏎` sends it, `shift+⏎` starts a new line and `esc` takes the `✗` back:

```
 ╭─ ✗ What went wrong? ─────────────────╮
 │ #930 Lights                          │
 │ check 1: remind me in two minutes    │
 │                                      │
 │ ❯ it came at 09:02, two minutes late │
 │                                      │
 │   shift+⏎ new line                   │
 ╰─ ⏎ send it back ─ esc cancel ────────╯
```

- **`space`** opens the ticket's modal, with its body, so the human can read what the change was
  before trying it.
- **The last `✓`** closes the ticket: it goes to `done`, and its tile goes in the same frame, as any
  settled item does.
- **A `✗`** sends it back at once, without waiting for the other checks. Its tile goes.
- Each button is a click too ([principle 7](~/projects/ficciones/docs/principles.md)): `babylon tried 825 1 ok` and
  `babylon tried 825 1 no "it came at 09:02"`.

## Sent back from to try

A `✗` is a send-back like the gate's, with the human's words as its reason:

- the ticket goes to `doing` with stage `failed`, and its `stage_note` is
  `you tried it: 1 remind me in two minutes: "it came at 09:02, two minutes late"`, kept as a
  send-back row as the gate's are;
- to its session if that is still alive (it is told, as a gate send-back is told); otherwise it is
  a free send-back, and the orchestrator puts it at the top of next, as it does any free
  send-back. A Claude that takes it starts from main, where the code already is;
- when it lands again, all its checks open again. A fix can break a step that passed, and trying
  three steps again costs less than a missed break.

## On the board and Plan

- The card's mark is `▲ try it`, in the "you" colour as `▲ asks you` is, with its own words, so the
  two are told apart at a glance: asks you wants a decision, try it wants hands.
- A to-try card sits at the top of the board's done column: it has landed, and it waits on the
  human. `space` on it shows the checks in its modal, with the same `y` and `n`.
- Plan's next and landing show nothing for it: it is not the machine's work any more. A goal's
  step that is to try reads `▲ to try` in the epic's modal.

## Left untouched

A to-try ticket stays to try until it is tried. Nothing closes it unseen: a check nobody tried
is not a check that passed.

- The day's digest lists to try in its own section, oldest first, each with its age
  (`#825 house soak day, 3 checks, 2d`).
- After seven days, its tile's age turns the "you" colour, and the digest puts it at the head of
  that section. Still no notice.
- The human can close it without trying (`x` on the tile, `babylon tried 825 skip`), which marks it
  done with the checks left untried, and its `stage_note` says so.

## What babylon holds and publishes

| | held as |
| --- | --- |
| a check | a `check` row: `ticket_id`, `n`, `text`, `result` (nil, `ok`, `no`), `words`, `settled_at`, `by` |
| to try | ticket status `try`, between `review` and `done` |
| tried | every check `ok`: the status goes to `done` |
| skipped | status `done`, its checks left nil, `stage_note` `closed untried by you` |

A ticket's checks are in `board.json` on its card:

```json
{"id": 825, "status": "try", "stage": "landed", "landed_at": "2026-11-24T21:02:00Z",
 "checks": [
   {"n": 1, "text": "remind me in two minutes: it is told, with buttons", "result": null},
   {"n": 2, "text": "how much have I spent this week? matches soak day", "result": "ok"},
   {"n": 3, "text": "add a to-do, then done it, from the phone", "result": null}]}
```

`needs_you` gains the kind `try`, one item per to-try ticket, carrying the machine's line and its
steps, each with its own actions:

```json
{"id": "try:825", "kind": "try", "ticket": 825, "repo": "tlon", "text": "#825 tlon  house soak day",
 "machine": "soak day ✓  gate ✓  review ✓   landed f962a56",
 "steps": [
   {"n": 1, "text": "remind me in two minutes: it is told, with buttons", "result": null,
    "actions": [{"key": "y", "label": "✓", "argv": ["babylon", "tried", "825", "1", "ok"]},
                {"key": "n", "label": "✗", "argv": ["babylon", "tried", "825", "1", "no"], "needs": "words"}]}],
 "actions": [{"key": "x", "label": "close untried", "argv": ["babylon", "tried", "825", "skip"]}]}
```

## The build

babylon, in order:

1. **Checks (#838).** The `check` rows, `checks` on `file_ticket`, `add_check`, `update_check` and
   `babylon check`, and `checks` on every card in board.json.
2. **The `try` status (#839).** Landing to try, `try` freeing what it blocks, the epic's status,
   and `babylon tried` (ok, no with words as a send-back, skip), with every check reopened on
   landing again. After 1.
3. **The words sessions read (#840).** The claim and submit answers, the reviewer adding missing
   checks, and the orchestrator writing them when it triages. After 1.
4. **To try in Your move and the digest (#841).** needs_you's `try` kind with its steps and the
   machine's line, and the digest's to-try section with ages. After 2.

arena, one stack:

5. **On the board (#842).** `.try`, the `▲ try it` chip, the top of the done column, and the
   checks in the card's modal. After 2.
6. **Your move's to try (#843).** The tile, its step rows, `y`, `n` with its line, `x` and
   `space`. After 4 and 5.
7. **On Plan (#844).** `▲ N to try` beside a goal's bar and `▲ to try` in the epic's modal.
   After 5.
