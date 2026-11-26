# arena

Every design and UI change here is held to [docs/principles.md](docs/principles.md): read it
before designing a screen, a key or a click.

Zig builds and tests go through `menard run test` (or `menard run check` when done), never
`zig build` or `zig build test` in the shell: menard kills the run's process group, reaps orphaned
compilers and ends a wait on a stuck cache lock with the holder named. The e2e is `menard run e2e`,
never `mise run e2e` in the shell: it runs the same task with the same process-group handling.

A change to what arena draws, or to its keys, runs the e2e (`menard run e2e`)
before `submit_ticket`: `menard run test` is the unit tests only. Update the e2e steps that assert
the old behaviour, and say so in the commit.
