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

Postgres over the local socket (`/run/postgresql`, or `PGHOST`), with peer auth.

## Serve it

```sh
mix ecto.create && mix ecto.migrate
BABYLON_SERVE=1 mix run --no-halt     # MCP on http://127.0.0.1:4050/ (BABYLON_PORT)
```

A Claude session reaches it as an HTTP MCP server. The header names the session's tmux pane, which
is what holds a claim:

```sh
claude mcp add --scope user --transport http babylon http://127.0.0.1:4050/ \
  --header 'X-Babylon-Pane: ${TMUX_PANE}'
```

Its tools are `file_ticket`, `list_tickets`, `get_ticket`, `update_ticket`, `link_tickets`,
`unlink_tickets`, `claim_ticket` and `release_ticket`. `bin/babylon` is the same tools from a shell
(`babylon` alone for its usage); it needs `curl` and `jq`.

A claimed ticket is `doing`, held by its pane while that pane runs Claude, with a branch
`t<id>-<slug>` to work it on (`wt switch --create <branch>`). Once a minute a claim whose pane is
gone goes back to `todo`, labelled `lapsed`, its branch kept for whoever picks it up.

```sh
babylon file "Claim with a lease" --priority high
babylon list --repo babylon --status backlog,doing
babylon link 2 blocks 3
babylon claim 3
```
