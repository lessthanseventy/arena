# Phosphor: style guide

An amber CRT application: one hue in four tints, a menu bar, and shade blocks. Screens:
[Home](phosphor-home.png) · [board](phosphor-board.png) · [popup](phosphor-popup.png) ·
[orchestrator](phosphor-orch.png). Colours are the palette's names (`palette.sh`).

## Palette roles

| role | colour | used for |
| --- | --- | --- |
| ground | `BG` | the tube |
| panel | `AMBERTINT0` | a column, the orchestrator's column, a popup |
| tile | `AMBERTINT1` | a card, a goal |
| raised | `AMBERTINT2` | the pick, a panel's head, a chip, a button |
| rule | `AMBERDIM` | rules, empty bar cells, the shade pattern |
| text | `AMBER` | words |
| dim | `DIM` | meta, ages, labels |
| accent | `AMBER` filled, `INK` on it | the menu bar, the focused head, the primary button, keys |
| you | `VIOLET` | asks and `▲ N need you`: the one hue that is not amber |
| per repo | arena `AMBER`, babylon `AMBERSOFT`, ficciones `EMBER`, menard `DIM`, tlon `SEP` | a shade each; the glyph tells them apart |
| per state | building `AMBER`, checking `AMBERSOFT`, queued `DIM`, sent back/stalled `EMBER`, landed `AMBER` | |

## Surfaces and depth

- A solid amber **menu bar** on row 0: `▚▞ ARENA`, the views as tabs (the current one inverted
  to tube-black), and the status on the right, with need-you in violet. A `▀` rule in `AMBERDIM`
  runs under it.
- A **panel** is `AMBERTINT0` under a one-row head in `AMBERTINT2`: `▚ name count` and `▒▒▒▒▒`.
  With focus, the head fills amber.
- The **pick** goes up to `AMBERTINT2`, with an accent `▌` down its left and a half-block shadow
  (`▖▌▝▀`) in `BG`.

## Chips and pills

`▐label▌`: square half-block shoulders around a `raised` face, with the text in the chip's shade.
A filled chip (asks, sent back, the step in flight) is the colour with `INK` text.

## Buttons and toggles

- A button is `[k label]`, with its key underlined. The primary one is filled `▐k label▌`.
- The foot bar is DOS style: each key inverted amber, then its word.
- A toggle is `[■□]` in amber and `AMBERDIM` (not drawn in the shots: auto is in the menu bar's status there).

## Spacing grid

The same grid as the others: a one-cell gutter, two-row cards plus a pill row, and columns at 40 /
33 / 27. The rail is 7 cells and the orchestrator's column is 62.

## Glyphs

The same Nerd Font set as [Workbench](workbench.md#glyphs). Bars are `█` filled and `░` empty,
with no partial cells: a CRT's coarse steps.
