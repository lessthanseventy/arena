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
