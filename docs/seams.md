# The seams

This design is for #587, held to [the principles](principles.md), and read with
[the orchestrator](orchestrator.md), whose words (needs you, ask, look at, proposal, your move,
notice, tell) it keeps. The human approved it as drawn on 2026-11-23, notices with go/no and an
ask's options included (ask #27). Nothing in it is built yet. The build is the tickets at the end.

The human, 2026-11-23, after asking whether their inbox belongs in ficciones: "we need to take a
look at all the layers/seams here and make sure everything is where it belongs. there are parts
that go in each place".

## The layers

- **babylon:** tickets, asks, proposals, the pipeline, auto and hold, `board.json`, the CLI, the
  MCP server and its messages to sessions.
- **arena:** the TUI. Home, the board, the orchestrator's column and its feed, the rail, normal
  mode and modals. `arena show`, `board`, `inbox` and `gate` are its commands.
- **arena's Claude Code plugin** (`hooks/`, `.claude-plugin/`): what each Claude session runs.
  Its hooks mark the panes, hand babylon's messages in, and guard tmux. It points every session
  at babylon's MCP server.
- **ficciones:** the desktop shell (the bar, notices, the deck, `Super+U` and `Super+Shift+U`,
  `keys.json`, the launcher) and what is installed: Claude's `settings.json` and allow rules, the
  session-state hook, `session` with `/goal` and `/brief`, babylon's service and mods.
- **menard:** Elixir tools. It touches these only through ficciones' `menard-scope` hook, which
  keeps its writes inside ticket worktrees. It owns none of the concerns below.
- **tlon/Asterion:** out of scope (#14). It is named only where it already has the pattern.

It is drawn for this machine only. The human, 2026-11-23: "we can assume we're just perfecting
this machine for now". The work Mac, which has no desktop shell, gets no notices once babylon's
notifier goes.

## The rules

These are the rules #587 started from, as tested against the code.

1. **babylon owns state and verbs, and draws nothing.** It holds every ticket, ask and proposal.
   It also decides what is the human's move, and which verbs settle each item. It shapes no row,
   colour or notice. *Test:* it fails twice today. babylon composes notice text and runs
   `notify-send` (`Notice`), and the rule for what is the human's move is written in four places
   (see below).
2. **Every surface is a thin reader of `board.json` and the session record, and acts only by
   running babylon's verbs.** *Test:* this holds for arena's board (every card action is a
   `babylon …` call) and the bar. It fails for starting a Claude, which arena does by typing its own
   `tmux new-window … claude 'Claim ticket…'`, a copy of babylon's `Auto.start`.
3. **Quick decisions go where the human already is, and depth goes in arena.** The desktop holds
   one item at a time: a notice or the bar cell. arena holds the list, the ticket, the doc, the
   words and the gate. *Test:* this is the open question below. A choice of a few options or a
   go/no is quick. Words, a doc, give and anything that needs the ticket are depth.
4. **Each concern has one owner, and the other places only point at it.** *Test:* it fails for
   *needs you* (four counters) and for *what's running* (two hooks writing two records).
5. **(added) The owner publishes each item with its actions, and surfaces render them
   generically.** The house already works this way. tlon's alerts each carry their actions as API
   calls, the shell draws them without knowing what they mean, and an alert drops off by itself
   once its cause is resolved (ficciones `lib/alerts.ts`). Work should take the same shape:
   babylon's `board.json` carries a `needs_you` list, and each item has its text and its actions as
   babylon argv. arena's feed, the bar and the notices draw that list. None of them derives it.
   This keeps the house and work on one vocabulary without sharing a channel.

## Who owns what

| concern | does it now | should own it | duplicates and gaps |
| --- | --- | --- | --- |
| **see what needs you** | babylon `Proposals.noticed` (asks + proposals); arena's mod `hooks/board-feed.tsx` (proposals + asks + free send-backs); ficciones `orchestrator-core.ts` (the same three); arena's header counts proposals only (`proposedCount`) | **babylon** computes `needs_you` in `board.json`. arena's feed draws it whole, and the bar draws its length | Four copies of one rule. The notice's N already leaves out free send-backs, so it can differ from the bar's |
| **settle a go/no** | `babylon go`/`no`; the board's card buttons (#494); the feed mod's buttons; #343 in the feed | **babylon** (`answer_proposal`). arena's feed and cards, and a notice's buttons, run its argv | None once the actions come with the item |
| **answer an ask** | `babylon answer`; the board; the orchestrator (`via`) | **babylon**. A choice can be answered from the feed or a notice. An answer in words only in arena's feed (`c`) | The ficciones office rail's ask row is gone (#533) |
| **look at a doc** | arena #342 (glow in a tmux window, unbuilt); ficciones `DocReader` (tlon's alerts only) | **arena** for work docs. A look's notice opens arena on it | Two readers, kept apart on purpose by #14 |
| **talk to the orchestrator** | its pane in arena's column; `babylon tell` (#529) from `Super+U` (#532) | **babylon** owns `tell` (the verb), **arena** the pane (the conversation), **ficciones** the one-line entry | None. This seam is already right |
| **be notified, and have a notice taken back** | babylon runs `notify-send` for asks (with the question) and proposals (`▲ N need you · …`); ficciones' sessions code runs `notify-send` for arena-go failures | **ficciones** raises a notice when a new id enters `needs_you`, closes it when the id leaves, and raises none while arena home is in front. **babylon** stops running a notifier | babylon cannot take a notice back or see what is in front. The ask notice still carries the question, against #349 |
| **see a ticket's detail and its gate** | `babylon detail` written to a file for arena; `arena gate` | **babylon** has the text. **arena** draws it | None |
| **see what's running and its state** | arena's `claude-state.sh` writes tmux pane options (`@arena_claude…`); ficciones' `session-state.sh` writes `$XDG_RUNTIME_DIR/sessions/<id>.json`. arena reads the first; the bar, `session`/`/brief` and babylon's meter reading read the second | **one hook, in arena's plugin**, writes both from one state machine. ficciones installs the plugin and does not keep its own | Two hooks on every event, with two vocabularies. ficciones' has no `StopFailure`, so a turn that ends on an API error stays *working* in the bar while arena shows it stopped (f4e01db fixed arena only) |
| **go to a Claude** | `arena show`; ficciones `arena-go.ts` calls it | **arena** | None |
| **restart after an install** | babylon's pipeline runs the repo's install; the orchestrator files a `done` ask (orchestrator.md); arena can restart itself | The **repo's install** says what must restart. **babylon** makes it a `needs_you` item whose action is that command (`⏎ restart now` where one exists) | Nothing says what needs a restart today. It is the orchestrator's guess |
| **start, stop and auto** | babylon `Auto.start` and a proposal's `:start`; arena types its own `tmux new-window … claude 'Claim ticket…'`; `babylon auto`, `hold` and `orchestrator` | **babylon**. A `babylon start N` that arena's `⏎` runs | arena's copy of the start command and its prompt |
| **settings and permissions** | ficciones `claude.nix` merges hooks into `settings.json` and `claude-allow.nix`; arena's plugin brings its hooks and babylon's MCP | **ficciones** installs and allows. **arena's plugin** is what a session runs | None, once the session-state hook moves to the plugin |

## The inbox question

The question was whether the human's inbox belongs in ficciones, as a popup or as notices with
go/no.

**Recommendation:** no inbox popup in ficciones. The list lives in one place, arena's feed. Its
door is `arena inbox`, which the bar and every notice already use. Each notice is one item and
carries that item's quick actions, drawn from its `needs_you` entry:

- a proposal: `go`, `no`;
- an ask with options: its options;
- a look, an ask in words, a free send-back (give needs a pick): only `open`, which runs
  `arena inbox` on the item.

A click on the notice's body opens arena on the item. A notice is taken back when its item is
settled anywhere.

This reverses one line of the human's from 2026-11-22 (#349): "notices … only say `▲ N need you`
and open the needs-you inbox. They don't carry the question themselves." The reason is rule 3:
a go/no is quick, and opening a terminal to press `⏎` costs more than the decision. The house's
decision banners already do this. The human approved the reversal on 2026-11-23.

## The ticket changes


| ticket | change |
| --- | --- |
| **#588** (babylon) | `board.json` carries `needs_you`: each item's id, kind, ticket, repo, first row and actions (`label`, `argv`), in the order the feed shows them, with #480's free send-back rule. `Proposals.noticed`'s count goes |
| **#592** (babylon) | Remove the notifier (`Notice.desktop`, `:notify`). Asks and proposals still tell the orchestrator. After #349 |
| **#589** (babylon) | `babylon start N`: what `Auto.start` does, as a CLI verb, never a Claude's |
| **#590** (babylon) | A repo's install names what must restart. babylon turns that into a `needs_you` item |
| **#591** (arena) | The plugin's hook writes the session record (`$XDG_RUNTIME_DIR/sessions`) as well as the pane options, from one state machine with `stopfailure` |
| **#593** (ficciones) | Drop `session-state.sh` and its hooks from `claude.nix` once arena's hook writes the record. `session`, `/goal` and `/brief` stay |
| **#594** (arena) | The board's `⏎ start` runs `babylon start N` |
| **#349** (ficciones) | Rescoped: ficciones raises the notices from `board.json`'s `needs_you`. It raises one per new id, closes it when the id leaves, and raises none while arena home is in front. Each notice carries the item's quick actions. Blocked by the `needs_you` ticket |
| **#595** (ficciones), after #531 | the bar's N reads `needs_you`'s length; `orchestrator-core.ts`'s count goes |
| **#479** (arena) | Unheld. It draws `needs_you` as babylon gives it, instead of deriving it. Its rows come from the item's first row and actions. Blocked by the `needs_you` ticket |
| **#341, #342, #343** (arena) | Unheld, as rescoped by #500. Each one's keys run the item's actions from `needs_you`, not their own calls |
| **#530** (babylon, landed) | Nothing. Its proposal notice goes with the notifier |
| **#532** (ficciones, landed) | Nothing |
| **#550** (babylon) | Unchanged. A *give* proposal becomes one more action kind on a `needs_you` item |
