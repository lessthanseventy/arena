# babylon

Tickets for the Claude sessions on one machine, across repos: any session files one, any session
claims one and works it in its own worktree, and the work is verified, reviewed and landed before it
reaches main. arena draws the board.

> "Like all men in Babylon, I have been proconsul; like all, a slave." (Borges, *The Lottery in Babylon*)

## Run it

```sh
mise run test     # the suite, on a fresh babylon_test database
mise run check    # the gate: format, warnings as errors, Credo, the suite
```

SQLite: `babylon_dev.db` and `babylon_test.db` beside the project, and the release's in
`$XDG_STATE_HOME/babylon/babylon.db` (`~/.local/state` when unset), made and migrated at start.

## Serve it

```sh
mix ecto.create && mix ecto.migrate
BABYLON_SERVE=1 mix run --no-halt     # MCP on http://127.0.0.1:4050/ (BABYLON_PORT)
```

A Claude session reaches it as an HTTP MCP server through arena's plugin (`../.claude-plugin/plugin.json`), whose
header names the session's tmux pane, which is what holds a claim. The server's instructions tell a
session when to file a ticket and when to claim one.

Its tools are `file_ticket`, `list_tickets`, `get_ticket`, `update_ticket`, `move_ticket`,
`link_tickets`, `unlink_tickets`, `claim_ticket`, `release_ticket`, `submit_ticket`, `ask_human`,
`answer_ask` and `inbox`. `bin/babylon` is the same tools from a shell (`babylon` alone for its
usage), and `babylon new` and `babylon edit N` write a ticket's title, repo and body in `$EDITOR`;
it needs `curl` and `jq`.

A claimed ticket is `doing`, held by its pane while that pane runs Claude, with a branch
`t<id>-<slug>` to work it on (`wt switch --create <branch>`). Once a minute a claim whose pane is
gone goes back to `todo`, labelled `lapsed`, its branch kept for whoever picks it up.

A submitted ticket is `review` and goes through the pipeline, one ticket at a time in the order
submitted, in one worktree a repo (`~/projects/<repo>`) kept warm under `~/.cache/babylon/work`
(seeded once with what the repo's `.worktreeinclude` names, then reset to each branch): its branch
is rebased onto `origin/main` and the repo's `mise run check` run (30 minutes at most) in a window
of babylon's own tmux session `babylon`, there to watch and read after (arena leaves it out of the
agents list), its output also kept in `~/.cache/babylon/logs`; then a headless `claude -p`
reviews the diff and ends on a verdict: `approve`; `fix`, having made small mechanical fixes
itself in the gate's worktree (no edits outside it), which are committed on the branch and gated
again, at most 60 changed lines, each named on a `FIXED:` line; or `request_changes`, its edits
dropped. Then it is pushed as main's new head, which only a fast-forward passes; main having
moved meanwhile means another rebase and gate first. How it went goes to the holding session's
inbox: landed, the ticket is `done`;
sent back, it is `doing` again with why in `stage_note`, or `todo` labelled `sent back` when that
session is gone. There are no pull requests: the gate and the review are babylon's. Landed, the
repo's own checkout, when it is on main with nothing changed, is fast-forwarded and its `install`
task (if it has one) started in a window of babylon's session, so what runs is what landed.

babylon's word to a session (a ticket landed or sent back, an ask answered) is kept per pane until
the session reads it with the `inbox` tool. What is typed into the pane is only a nudge to read it,
held while the pane's Claude waits on its human (arena's hook marks the pane `waiting`, when a
typed line would land in an open dialog), and repeated once a minute, four times at most, while
it is unread.

Served, it keeps the board arena draws in `$XDG_RUNTIME_DIR/babylon/board.json` (beside the database where there is no runtime
dir, as on the Mac): every open
ticket and those done in the last day, each with its open blockers and its epic, rewritten within
a second of a change.

```sh
babylon file "Claim with a lease" --priority high
babylon list --repo babylon --status todo,doing
babylon link 2 blocks 3
babylon claim 3
```
