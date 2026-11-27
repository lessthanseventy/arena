# The orchestrator's choices are asks in Your move

This design is for #1046 and follows [the principles](~/projects/ficciones/docs/principles.md). It sits beside
[Plan replaces the board](plan-replaces-board.md). Nothing in it is built yet. The build is the
tickets at the end, and they wait on the human's Go.

The human, 2026-11-25: "how do you feel about another TUI for the next steps stuff instead of a
mod? I'm thinking we're driving towards something good here but like mixin that concern into this
conversation feels like it's muddying what we're trying to do". On the orchestrator's
recommendation they answered: "yes, file it as asks in your move".

## What changes

| today | after |
| --- | --- |
| The orchestrator ends each turn with `next: a \| b \| c`. The next-step mod turns it into buttons under the chat reply | The orchestrator raises the choice with `ask_human`: the options are the replies the human would give, with the recommended one first |
| The buttons are gone after a scroll, a new turn or an orchestrator restart, and nothing records the answer | The ask is a Your move item at the top of the orchestrator column. The human answers it there (or on Plan's card). The answer goes onto the ticket, and the ask survives scrolls and restarts |
| The chat holds both the conversation and the controls | The chat holds the conversation: what was found and why, and which ask it raised (`ask #N on #M`). It has no buttons |
| A separate TUI was floated | No new surface. Arena is the one place, which keeps with #896's rule: one thing, drawn in one place |

This keeps [principle 8](~/projects/ficciones/docs/principles.md) (only decisions interrupt, and an ask is a decision) and
principle 11 (words to answer an ask go in the ask's modal).

## The questions the ticket left open

### An ask with no ticket

**Settled: babylon keeps asks on tickets. When no ticket is about the choice yet, the orchestrator
files one first.** A new direction is filed as an idea (`file_idea`, an epic in the backlog).
Anything else is filed as a backlog ticket. Then it asks on that. When the answer is no, the
orchestrator closes it with the human's words. A choice about a repo's rules is filed in that repo,
as any other work is.

Why: every choice the orchestrator raises is about some piece of work, and the answer has to land
somewhere babylon's review can read it. A ticketless ask would need a nullable `ticket_id`. It
would also need a place for its answer, its own rule for holding the pipeline, and a Your move row
with no ticket. That is a new thing to keep in sync, there to save one `file_ticket` call. A refused
idea, once closed, costs nothing.

What babylon already does here:
- An ask on a backlog epic already shows in Your move (`NeedsYou.ask/2`). An option ask is drawn
  as `ask`, and a look as `draft`.
- A ticket can have only one open ask (`Asks.ask/2`). If a session already has one open on that
  ticket, the choice is already in Your move, so the orchestrator doesn't ask again.
- An open ask holds its ticket in the pipeline. That is right for the orchestrator's asks too: a
  ticket whose next step is the human's choice should not land before they make it.

What babylon gets wrong for the orchestrator today (build 1):
- **An answer goes to the pane that asked** (`Asks.hand_over/5` → `deliver/2`). If that pane is
  gone, the ask is closed unanswered. After an orchestrator restart, every ask it raised would be
  lost, and the ticket asked for the opposite. Fix: when the orchestrator asks, the ask records
  the orchestrator as its asker, not the pane. Its answer then goes to the orchestrator's pane at
  answer time (`Babylon.Orchestrator.pane/0`). If no orchestrator is running, the ask stays open,
  as it does today when tmux can't be reached. babylon restarts the orchestrator within a minute.
- **It notifies the orchestrator of its own ask** (`Asks.noticed/1` types `#N asks: …` into the
  orchestrator). Skip that when the orchestrator is the asker. Its chat reminders of an open ask
  are skipped the same way.

### The `next:` line

**Recommended: drop it.** Its only reader is the next-step mod's orchestrator branch, which this
design removes. A `try #N` or `answer #N` is already a Your move item. Kept as a summary with no
buttons, the line would repeat Your move in the chat, which is the duplication #896 cuts.

This changes the orchestrator's rules, and that change is the human's to make. The wording they
are asked to approve **replaces the whole `End every turn with a next: line` paragraph** in
babylon's `orchestrator.md`:

> **Every choice for the human is an ask.** When the human has to choose (between options, or yes
> or no), call ask_human on the ticket it is about. Each option is a reply the human would give,
> a few words long, and the one you recommend comes first. If no ticket is about it yet, file it
> first (an idea with file_idea for a new direction, else a backlog ticket in its repo) and ask on
> that. If the answer is no, close it with their words. In chat, say what you found and why, and
> name the ask (`ask #N on #M`). Put no options to pick from in chat, and end no turn with a
> `next:` line. The answer comes to your inbox; act on it then. If the human answers in chat
> instead, record it with answer_ask, as with any session's ask.

The `Put these to them (ask_human), with a recommendation` line under *What stays the human's*
already says this, so it stays as it is.

### The next-step mod and #993

**Recommended: keep the mod for every other session and remove its orchestrator branch.** For an
ordinary session the mod still does what #870 built it for: Claude Code's own ghost suggestion
shown as a button. The orchestrator code goes: the tmux session-name check, `orchestratorLine`,
the `next:` parsing, the ` | ` split, `board.ts` and its board.json filter, and the `argv` items.
Its tests go with it.

**#993** (the buttons do nothing on the orchestrator pane) is closed as superseded when that
ficciones change lands, because the buttons it is about no longer exist. #903 (`arena plan N`)
stays as it is: it is a Plan feature in its own right.

### #940 and #989

- **#940** (landed) left the orchestrator column holding Your move over the chat, and nothing
  else. This design needs that, and adds nothing to the column.
- **#989** (Your move one line per item, at most a third of the column) is what keeps the
  orchestrator's asks from crowding out the chat. With asks replacing the buttons, there will be
  more Your move items, so #989 should run before or alongside this build. Asks keep their place
  in Your move's order (proposals, then asks, then to-try, then send-backs). An ask the
  orchestrator raised is drawn like any other: `#M repo  asks: …`.
- **Arena needs no change of its own.** Your move already draws asks, their options as buttons,
  and the words modal (principle 11). The next-step buttons are drawn by the mod in Claude Code's
  pane, not by arena.

## The build

Each ticket is filed in the backlog and moves to todo on the human's Go.

1. **babylon #1047: the orchestrator's asks survive a restart and don't notify the orchestrator itself.**
   Sonnet. The asker is recorded as the orchestrator, and its answer goes to the orchestrator's
   current pane. No `#N asks` notice and no chat reminder goes to the orchestrator for its own
   asks.
2. **babylon #1048: the rules, `next:` replaced by asks.** The wording above, exactly as the human
   approves it. After 1.
3. **ficciones #1049: next-step keeps its ghost-suggestion button and loses its orchestrator branch.**
   Sonnet. Close #993 as superseded. After 2, so the orchestrator never has a choice with neither
   buttons nor an ask.

Arena: nothing new. #989 is the arena ticket this leans on.
