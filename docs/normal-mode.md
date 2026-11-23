# Normal mode, the peek and the modal

This is a design for #393, held to [the principles](principles.md), and the human agreed to it on
2026-11-23. Nothing in it is built yet. The build is a stack of tickets, listed at the end.

The human, 2026-11-22: "I know we're super tmux heavy but I'm thinking we need some like
vim/modality sprinkled in if that makes sense? like I want to be able to just peek at stuff in a
popup or something", and then "conceptually i think i want most things i click on to be like a
modal. a ticket/card. the gate that kinda stuff."

## Two modes

- **Insert** is arena as it is today. Every key goes to the shown pane, apart from the Alt chords
  (until they retire) and the one key that changes mode.
- **Normal**: keys drive arena. Nothing is typed into any pane.

**`Ctrl+Space` changes mode, both ways.** In normal mode, `i` also goes back to insert, and so does
`Esc` once nothing is open. Each `Esc` closes one thing: the modal, then the peek, then normal
mode itself.

Why `Ctrl+Space` and not the toggles the ticket suggested:

| candidate | taken by |
| --- | --- |
| `Esc Esc` | Claude Code's own double Esc (rewind, or clear the prompt). A lone `Esc` has to reach Claude to stop a turn, and arena already passes it on after 30 ms (`keys.lone`). |
| `Alt+Space` | the desktop's launcher (ficciones `shell/assets/keys.json`) |
| `Ctrl+Space` | nothing found: it is not among Claude Code 2.1.321's own bindings, tmux's prefix here is `C-b`, and the only loss is zsh's emacs `set-mark-command` on `^@` in a shell pane |

The terminal sends `Ctrl+Space` as one NUL byte, so `keys.next` reads it as an event the way it
reads an Alt chord. This assumes the terminal is not using the kitty keyboard protocol, and arena
does not ask for that protocol.

Other ways to enter or leave a mode:

- Opening the board, the overview, the menu or jump enters normal mode, and closing them goes back
  to insert. That is what happens today, given a name.
- A click on a pane is insert into that pane. A click on the rail, the board or a peek is normal.
- `⏎ go` from anywhere lands in insert, in the pane it went to.

This is also the focus rule #426 asks for. In insert, a single letter is never arena's. With the
board open and the orchestrator's column focused, the column is in insert.

### What shows the mode

In insert, the focused column has its turning gradient, as today, and the corner says nothing.
In normal:

- the focused column's gradient stops and goes dim, and the pick lights in the accent instead;
- the row of dots under the strip becomes the key bar for what is picked, so the keys are written on
  screen. It is the same row, so nothing moves;
- `NORMAL` shows in the accent at the bottom-left corner, over the foot of the rail.

```
╭─ sessions ────────╮ ╭─ 1 claude ───────────────────────────────────────────╮ ╭─ 2 zsh ──
│ arena          3 │ │ ● I'll write the keymap next, then the mockups.      │ │ ~/proj
│ babylon        2 │ │                                                      │ │ ❯
│ tlon           1 │ │ ❯                                                    │ │
│ ── claudes ──────│ │                                                      │ │
│ ◐ #393 normal… 4m│ │                                                      │ │
│▌▲ #305 worktr… 2m│ │                                                      │ │
│ ◉ #324 rail s… 9m│ │                                                      │ │
│                  │ │                                                      │ │
│ NORMAL           │ ╰──────────────────────────────────────────────────────╯ ╰─────────
╰──────────────────╯  j k pick  space open  ⏎ go  a answer  ] next waiting  b board  n inbox  ? keys  i insert
```

The pick is on #305, a Claude in another session that waits on an answer. Moving the pick to it
changed nothing in the strip: the shown pane is still #393's.

## Look, open, go

One ladder for everything that stands for a thing: a Claude, a session, a card, the gate, an ask.

| rung | how | what | moves |
| --- | --- | --- | --- |
| **peek** | the pointer rests on it, or the pick rests on it for 400 ms in normal mode (#392) | small, live, read-only, beside the thing | nothing |
| **modal** | `space`, or a click on what is already picked | centred over arena: the thing whole, with its actions as buttons | nothing behind it |
| **go** | `⏎`, from the list or from the modal | goes there for real, into insert | the view |

**For a Claude or a session, the modal is the popup.** Its body is the live pane, scrollable, so
the "popup peek" and the "session modal" of the ticket are one thing and not two. The small hover
peek is #392.

**On the board, `⏎` stays the card's first action** (start, go, give) and `space` opens the modal.
A click on the picked card opens the modal and no longer goes. That makes clicking match the
human's "most things i click on to be like a modal", and keeps `⏎` the fast way through.

## The keymap

### Normal mode, over the strip

The pick moves through the rail as one list: each session, and the Claudes under it.

| key | does |
| --- | --- |
| `j` `k` (`↓` `↑`) | the pick to the next or previous entry in the rail; the strip stays as it is |
| `]` `[` | the pick to the next or previous Claude that waits or is done, the one that most wants looking at first |
| `h` `l` | the window to the left or right (the strip itself moves, as `Alt+h` `Alt+l`) |
| `1`…`9` | that window |
| `H` `L` | move the window left or right |
| `J` `K` | move the session down or up the rail |
| `space` | the picked thing's modal: for a Claude or a session, the popup |
| `⏎` | go to the pick, into insert |
| `#` | a ticket by number: `#305⏎` opens its card's modal |
| `/` | find: windows, sessions, Claudes and tickets, by name or number (`Alt+p`'s jump, widened) |
| `b` | the board |
| `n` | the needs-you inbox (#341); the board until it lands |
| `g` | the gate's modal, for the run in progress |
| `o` | the overview |
| `c` | a new window (`Alt+Enter`) |
| `x` | close the window, after asking |
| `z` | the session's columns at the whole width, and back |
| `;` `'` | the window narrower, wider |
| `w` | the rail narrow, and wide again |
| `m` | the menu |
| `?` | every key |
| `i` `Esc` `Ctrl+Space` | insert |
| `Q` | leave arena; the sessions keep running |

`q` closes what is open, and on the bare strip it does nothing, so a stray `q` never quits.

### The popup: a Claude's or a session's modal

| key | does |
| --- | --- |
| `j` `k`, `C-d` `C-u`, `g` `G` | scroll its pane's history; `G` follows it live again |
| `/` | search its pane's history (`Alt+/`, for any pane) |
| `h` `l` | the previous or next entry in the rail, without closing: leafing through the Claudes |
| `a` | answer its open ask in place: the options numbered, a digit answers |
| `r` | reply: a line at the popup's foot; `⏎` types it into the pane with an Enter |
| `t` | its ticket's modal |
| `⏎` | go there, into insert |
| `q` `Esc` | close; the pick is where it was |

### A card's modal

The same letters as the board, so nothing is learnt twice: `⏎` start or go, `G` give, `e` edit,
`p` priority, `>` close, `<` reopen, `a` answer its ask. Then `j` `k` scroll it, `c` its Claude's
popup, `g` its gate run, and `q` `Esc` close.

### The gate's modal

`j` `k` scroll the output, `L` the whole log in a window of its own, `t` the ticket's modal,
`u` bump it up the queue and `W` withdraw it (after asking). These are `babylon bump` and
`babylon withdraw`. `q` `Esc` close.

### An ask's or a proposal's modal

`1`…`9` answers with that option, `d` opens its doc when it names one, `t` the ticket's modal,
and `q` `Esc` close it unanswered.

### The board and the inbox

The board is a normal-mode screen. Its keys are today's, with three changes:

- `n` is the inbox everywhere. Filing a ticket moves to `+`, which is what the `+ new` button on
  the to-do column already says.
- `space` opens the card's modal. Today's detail over the board grows into it.
- `]` `[` pick the next or previous card that needs the human.
- `w` puts the picked todo card at the bottom of next, `W` at its top.

The inbox's keys: `j` `k` through its items, `space` the item's modal, `1`…`9` answer the picked
ask, `⏎` go to its Claude.

### The Alt chords

Each chord keeps working in insert until it has its normal-mode key, then it can retire. The ones
that collide with Claude Code retire first: Claude Code 2.1.321 binds meta `j`, `m`, `o`, `p` and
`w` as well, and today arena takes them before Claude sees them. What each of those does in Claude
Code is not checked.

| chord | normal |
| --- | --- |
| `Alt+h` `Alt+l` | `h` `l` |
| `Alt+j` `Alt+k` | `j` `k` then `⏎` (the pick moves first, then goes) |
| `Alt+1`…`Alt+9` | `1`…`9` |
| `Alt+H` `Alt+L` `Alt+J` `Alt+K` | `H` `L` `J` `K` |
| `Alt+;` `Alt+'` | `;` `'` |
| `Alt+Enter` | `c` |
| `Alt+x` `Alt+z` `Alt+o` `Alt+b` `Alt+w` `Alt+m` | the same letter |
| `Alt+p` | `/` |
| `Alt+n` `Alt+N` | `]` `[` then `⏎` |
| `Alt+/` | `space` on the shown pane, then `/` |
| `Alt+!` | none yet: it works in every mode, and over the board (also in the menu as Report this) |
| `Alt+q` | `Q` |

## Mockups

### The popup over a session

Normal mode, the pick on #305 in babylon, then `space`. The strip behind still shows #393's pane,
and arena dims it.

```
╭─ sessions ────────╮ ╭─ 1 claude ───────────────────────────────────────────────────────────────────────────────╮
│ arena          3 │ │ ● I'll write ╭─ ▲ #305 worktree cleanup · babylon:2 · waits 2m ───────────────╮          │
│ babylon        2 │ │              │ asks: remove the branch too, or keep it?                       │          │
│ tlon           1 │ │ ❯            │ opus · ctx 41% · t305-landed-worktree · 1 shell                │          │
│ ── claudes ──────│ │              │────────────────────────────────────────────────────────────────│          │
│ ◐ #393 normal… 4m│ │              │ ● Bash(git worktree list)                                      │          │
│▌▲ #305 worktr… 2m│ │              │   ⎿ ~/projects/babylon  9a1c2e0 [main]                         │          │
│ ◉ #324 rail s… 9m│ │              │     .worktrees/t305-landed  41be7d3 [t305-landed-worktree]     │          │
│                  │ │              │                                                                │          │
│                  │ │              │ ● The worktree goes once the ticket lands. Should its branch   │          │
│                  │ │              │   go too, or stay for a later look?                            │          │
│                  │ │              │                                                                │          │
│                  │ │              │ ❯ 1. Remove the branch too                                     │          │
│                  │ │              │   2. Keep the branch                                           │          │
│                  │ │              │                                                           live │          │
│                  │ │              ╰─ a answer  r reply  ⏎ go  t ticket  / search  h l next  q ─────╯          │
│                  │ │                                                                                          │
│ NORMAL           │ │                                                                                          │
╰──────────────────╯ ╰──────────────────────────────────────────────────────────────────────────────────────────╯
```

The popup is about three quarters of the strip in each direction. Its head is the Claude's mark,
ticket, window and state. Under that come its `doing` or ask, its model, context, branch and
shells, and then its pane, drawn from arena's own copy of the pane's screen. `live` marks that the
popup follows the pane. Scrolling up takes it off, and `G` puts it back on.

### The popup, answering the ask in place

After `a`. The options come from babylon's ask when the Claude asked through `ask_human`, or
from Claude Code's own question on its screen. The digit goes to whichever one it is: babylon's
`answer`, or the keys typed into the pane.

```
               ╭─ ▲ #305 worktree cleanup · babylon:2 · waits 2m ───────────────╮
               │ …                                                              │
               │ ❯ 1. Remove the branch too                                     │
               │   2. Keep the branch                                           │
               │────────────────────────────────────────────────────────────────│
               │ answer: Should its branch go too, or stay for a later look?    │
               │  1  Remove the branch too     2  Keep the branch               │
               ╰─ 1…2 answer  r reply instead  esc back ────────────────────────╯
```

After the answer the popup stays open. Its head turns from `▲ waits` to `◐ working`, and the pane
under it goes on live. `⏎` goes there, and `q` leaves it to work.

### Normal mode on the board

The board of [the board design](board-design.md#the-board-at-the-whole-screen), with the mode in
the corner. The foot bar shows the picked card's keys, and `space open` is one of them.

```
 ▤ board    every · arena 13 · babylon 7 · tlon 9    backlog 4         ▲ 4 need you   ◒ gate #305 reviewing   ● orch
 ────────────────────────────────────────────────────────────────────────────────────────────────────────────────────
 todo 32                         + new      doing 3                              review 2
 arena ───────────────────────────── 13     arena ────────────────────────── 2   babylon ──────────────────────── 1
 ╭──────────────────────────────────────╮   ▌ #393 Design: a normal mode for     ▌ #305 A landed ticket's worktree
 │ #295 A Claude whose turn ended on an │   ▌ arena, vim-style                   ▌ and branch are removed
 │ API error stays "working"            │   ▌ ◐ t393-design · opus · 4m          ▌ ▲ asks · ◒ reviewing · 2m
 │ med · filed 1d                       │
 │ ⏎ start  space open  G give  e edit  │
 ╰──────────────────────────────────────╯
 ▌ #290 e2e flake: the click that
 ▌ focuses window two…
 ────────────────────────────────────────────────────────────────────────────────────────────────────────────────────
 NORMAL  ⏎ start  space open  G give  e edit  p priority  > close  │  n inbox  + new  / find  ] needs you  │  ? keys
```

### A card's modal

`space` on #305, or a click on it once it is picked.

```
        ╭─ #305 · babylon · high · review ─────────────────────────────────────────────────╮
        │ A landed ticket's worktree and branch are removed, so nothing mistakes them for  │
        │ stranded work                                                                    │
        │                                                                                  │
        │ ◒ reviewing · 2m        held by babylon:2 · opus · t305-landed-worktree          │
        │ blocks #312 · relates #284 · filed 1d by the orchestrator                        │
        │──────────────────────────────────────────────────────────────────────────────────│
        │ ▲ asks: Should its branch go too, or stay for a later look?                      │
        │    1  Remove the branch too     2  Keep the branch                               │
        │──────────────────────────────────────────────────────────────────────────────────│
        │ When a ticket lands, its worktree under .worktrees/ and its branch stay. The     │
        │ next session to look sees work that seems stranded, and `wt list` grows. Remove  │
        │ both once the landing is on origin/main.                                         │
        │                                                                            ↓ 12  │
        │──────────────────────────────────────────────────────────────────────────────────│
        │ its Claude: ▲ waits 2m · said: The worktree goes once the ticket lands…          │
        ╰─ ⏎ go  1 2 answer  c its Claude  g gate run  e edit  p priority  > close  q ─────╯
```

The whole ticket is here in one place: the title whole, stage, holder, links, the open ask with
its options as buttons, the body rendered and scrollable, a send-back's `stage_note` in full where
there is one, and its Claude's state on the last row. The buttons are only the ones that apply,
as on the picked card.

### The gate's modal

`g`, or a click on the header's gate button, or `g` inside a card's modal.

```
        ╭─ gate · #305 babylon · run 3 of today ───────────────────────────────────────────╮
        │ ✓ rebase     onto main 9a1c2e0                                              4s   │
        │ ✓ gate       mise run check · 205 passed                                1m 58s   │
        │ ◒ review     opus, against the ticket and docs/principles.md              2m …   │
        │ · land       fast-forward main                                                   │
        │ · install    babylon release                                                     │
        │──────────────────────────────────────────────────────────────────────────────────│
        │ Finished in 119.5 seconds (2.9s async, 116.5s sync)                              │
        │ Result: 205 passed                                                               │
        │                                                                                  │
        │ queued behind it: #391 menard, #402 arena                                        │
        ╰─ L whole log  t ticket  u bump  W withdraw  j k scroll  q close ─────────────────╯
```

When a stage fails, its row is `✗` and the body is that check's output: the failing test's file,
line and message, not the log's last lines. After review, the verdict and its findings are in full.

### A session's modal

This is the popup (above), for every pane and not only a Claude's. A plain shell's head is its
window, its command and its directory, and its foot has no `a` or `t`.

## Board 5 (#338)

**The box stays as the compact form, and the modal is the whole one.** The picked card is boxed in
place with its first actions as buttons, as #338 has it, and `space open` is one of them. It keeps
the lazygit rule that the keys for what is under the cursor are on screen, without covering the
board. The modal takes the card's detail, so the box no longer grows to show the body. #338 can
be built as it is specced, adding the `space open` button.

## What this needs from elsewhere

- **babylon:** a run's stages with their start and end times, the failing check's output and the
  review's verdict, readable by arena (in board.json, or `babylon gate N`). Today board.json has
  only `stage` and `stage_note`, and `babylon detail` has the log's last lines.
- **babylon:** its review prompt checks a design or UI change against `docs/principles.md`.
- **babylon, ficciones:** AGENTS.md points to arena's `docs/principles.md`.
- **arena #361:** `arena gate [N]` and `arena show #N` open these modals from outside, so every
  modal is a command too.

## The build, as a stack

Epic #452. Each step builds on the one before. All of them are arena's, apart from the babylon tickets above (#447, #449) and ficciones' #448.

1. **Modes, as #426:** `Ctrl+Space` read as an event, insert and normal, `i` and `Esc`, the dim
   gradient and `NORMAL`, and the click rule (pane is insert, chrome is normal). #426's focus rule
   is built here, once. e2e: in insert, a sentence with `j k h l q n b` reaches the pane whole; in normal, none of
   it does.
2. **The rail's pick (#453):** `j` `k` `]` `[` move it without moving the strip, `⏎` goes, and the key bar
   replaces the dots in normal mode.
3. **The popup (#454):** `space` on a Claude or a session, the live pane from arena's own copy, scrolling,
   `G` live, `/` search, `h` `l` leafing through, and `⏎` go. e2e: no cell outside the popup
   changes while it is open, and closing it leaves the screen as it was.
4. **Answer and reply in the popup (#455):** `a` with babylon's ask or Claude's own question, and `r`.
5. **One modal frame (#456):** a centred box with a head, a scrollable body and a foot of buttons, each a
   rectangle from Board 1's layout (#333). Today's detail over the board moves onto it.
6. **The card's modal (#457)**, with `space` and a click on the picked card opening it, and `#N` from
   normal mode.
7. **The gate's modal (#459)**, which waits on babylon's run stages (#449).
8. **The ask's and proposal's modal (#460)**, and the inbox's `space`.
9. **Normal keys for the rest (#461)**, with the Alt chords that collide with Claude Code retired:
   `Alt+j`, `Alt+m`, `Alt+o`, `Alt+p`, `Alt+w`. The README's key table follows.
10. **Later, not this stack (ficciones #462):** a desktop hotkey opens the popup over whatever is in front, through
    arena's commands (ficciones).
