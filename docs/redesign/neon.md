# Neon tiles: style guide

A modern flat app in a terminal: no chrome, rounded pills, tiles tinted by repo. Screens:
[Home](neon-home.png) · [board](neon-board.png) · [popup](neon-popup.png) ·
[orchestrator](neon-orch.png). Colours are the palette's names (`palette.sh`).

## Palette roles

| role | colour | used for |
| --- | --- | --- |
| ground | `BG` | everything that is not a tile |
| tile | the repo's colour 90% toward `BG` (80% when picked) | a card |
| raised | `SURFACE4` | a button, a picked row |
| well | `SURFACE2` | the prompt, a goal card |
| rule | `SURFACE4` | the `▔` under a heading |
| text | `WHITE` | words |
| dim | `GREY` 30% toward `BG` | meta, ages, labels |
| accent | `PINK` | focus, the pick's ring, the primary button, `NORMAL` |
| you | `PINK` | asks and `▲ N need you` (the accent is "you") |
| per repo | arena `AMBER`, babylon `VIOLET`, ficciones `CYAN`, menard `MOSS`, tlon `LILAC` | a tile's tint and stripe, its chip, its goal bar |
| per state | building `CYAN`, checking `VIOLET`, queued dim, sent back/stalled `RED`, landed `GREEN` | |

## Surfaces and depth

- **No window chrome.** A heading is bold text, a count pill, and a `▔` rule under it, which turns
  pink with focus.
- A **card** is a tile tinted by its repo, with a `▎` stripe of the repo's colour down its left.
- The **pick** is ringed in half blocks of pink (`▄` above, `▀` under, `█` left, a soft `▐` right),
  so it floats in a glow, not a box. A row in a list, such as next, takes a `█` bar alone.
- The popup is a `SURFACE2` tile with a repo-coloured `▀` top edge and a pink ring.

## Chips and pills

Real pills, with the Nerd Font's round caps: `label`. The face is the colour 78% toward what
is under it, and the text is the colour. A filled pill has the colour as its face and `INK` text.

## Buttons and toggles

- A button is a pill on `raised`, its key in pink. The primary one is a filled pink pill.
- The foot's keys are dim pills, each followed by its word.
- A toggle is a pill with its knob, `● auto` filled when on and dim when off (not drawn in the shots: auto is a status pill there).

## Spacing grid

A one-cell gutter, two-row cards plus a pill row with a blank row between cards, and columns at
40 / 33 / 27. The rail is 7 cells with a `▕` edge, and the orchestrator's column is 62.

## Glyphs

The same Nerd Font set as [Workbench](workbench.md#glyphs). Bars are pills: round caps and solid
cells, with the track in the bar's colour 80% toward the ground.
