# arena

Every design and UI change here is held to [the principles](~/projects/ficciones/docs/principles.md): read it
before designing a screen, a key or a click.

Zig builds and tests go through `menard run test` (or `menard run check` when done), never
`zig build` or `zig build test` in the shell: menard kills the run's process group, reaps orphaned
compilers and ends a wait on a stuck cache lock with the holder named. The e2e is `menard run e2e`,
never `mise run e2e` in the shell: it runs the same task with the same process-group handling.

A change to what arena draws, or to its keys, updates the e2e steps that assert the old behaviour,
and says so in the commit. While working, run the e2e steps of what you changed if you need them
(`E2E_ONLY=<regex> mise run e2e`, the one way to run it by hand): only the
sections of `test/e2e.zsh` whose name matches run (`section NAME` opens one; `E2E_ONLY=click` is
the mouse one), each on a fresh world when the one before it was left out. A pattern matching no
section fails. A step that needs state another section leaves sets it up at its section's head.
Do not run the whole e2e before `submit_ticket`:
babylon's gate (`mise run check`) runs it once.
