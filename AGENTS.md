# arena

Every design and UI change here is held to [docs/principles.md](docs/principles.md): read it
before designing a screen, a key or a click.

Zig builds and tests go through `menard run test` (or `menard run check` when done), never
`zig build` or `zig build test` in the shell: menard kills the run's process group, reaps orphaned
compilers and ends a wait on a stuck cache lock with the holder named. `mise run e2e` runs
`zig build` through its `build` dependency, so run it under `menard run check`.
