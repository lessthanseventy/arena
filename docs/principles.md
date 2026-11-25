# Principles

The human, 2026-11-22: "I'm basically trying to marry lazygit, neovim, claude, ghostty, linux, and
me into some weird polycule lol. like take the ethos of all this stuff and combine it into a big
soup."

These are the rules for every design and build in arena, babylon, the desktop shell and asterion.
A review of a design or a UI change checks it against them.

## What each one brings

- **lazygit:** everything that matters fits on one screen. One key acts on what is under the
  cursor, and the keys are always written on screen.
- **neovim:** modes. Moving and acting are kept apart from typing, and verbs compose.
- **Claude:** you say what you want, and the work happens somewhere else while you watch.
- **ghostty:** fast, native, plain text, with nothing in the way.
- **Linux:** small tools that each do one thing, joined by text and commands. Anything can call
  anything.
- **the human:** attention is what's scarce. Only decisions interrupt, everything else waits until
  they look, and a glance tells where things stand.

## The rules

1. **Every screen says its keys.** A foot bar shows the keys for what is picked, and `?` shows all
   of them.
2. **Every list moves with `j`/`k` and acts with `⏎`.** `h`/`l` move between columns, `space`
   opens the picked thing, and `q`/`Esc` backs out one level.
3. **Typing and driving are separate modes.** In insert mode every key goes to the pane. In normal
   mode, keys drive arena. The mode is always on screen. No key is taken from a pane except the
   one that changes mode (and the Alt chords, until they retire).
4. **Look, open, go: one ladder.** Hovering or resting on a thing shows a *peek*: small, live,
   read-only. Opening it (`space`, or a click on what is picked) shows a *modal*, where the thing
   is shown whole with its actions. *Going* (`⏎`) goes there for real.
5. **Looking never moves anything.** Peeks, modals and hover draw over the screen. No cell outside
   them changes, and the view behind them is as it was when they close.
6. **One way to mark a selection.** Hover is not marked, focus is the turning gradient, and the
   pick is the accent box. They look the same everywhere
   ([board design](board-design.md#hover-focus-and-pick-one-system)).
7. **Anything clickable is also a command.** `arena show`, `arena board`, `arena gate`,
   `babylon …`: anything a click can do, a script, a hotkey or a Claude can do too.
8. **Only decisions interrupt.** A notice is for something only the human can decide. Progress,
   landings and Claudes that have finished wait in their places until the human looks.
9. **Plain text, fast.** What is drawn is text a terminal can draw, with no frame later than the
   key that asked for it.
10. **Nothing moves by itself.** A click, a hover or a count changing never resizes or moves
    anything outside the element itself. Panels have a fixed size and scroll; a tab's label has a
    fixed width and shortens rather than wraps. Only what the human must act on (Your move) may
    grow, and if it ever needs a cap, it gets the same fixed size and scroll. Content that moves
    on its own works against WCAG 3.2 (Predictable).
