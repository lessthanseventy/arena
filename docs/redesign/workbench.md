# Workbench: style guide

A desktop GUI from 1990 on today's palette: every area a window, every control a raised face.
Screens: [Home](workbench-home.png) · [board](workbench-board.png) · [popup](workbench-popup.png) ·
[orchestrator](workbench-orch.png). Colours are the palette's names (`palette.sh`).

## Palette roles

| role | colour | used for |
| --- | --- | --- |
| ground | `SURFACE0` | the desktop behind every window |
| panel | `SURFACE2` | a window's face: a column, the orchestrator's column, a popup |
| tile | `SURFACE3` | a card, an unfocused window's title bar, an inactive tab |
| raised | `SURFACE4` | the pick, a focused title bar, a button, a chip |
| well | `BG` | sunken: the prompt, a progress bar's track |
| text | `GREY` | words |
| dim | `GREY` 40% toward `SURFACE3` | meta, ages, labels (kept ≥ 4.5:1) |
| accent | `AMBER` | focus, the primary button, keys in the foot bar, the auto switch |
| you | `VIOLET` | asks and `▲ N need you`, and nothing else |
| per repo | arena `AMBER`, babylon `VIOLET`, ficciones `CYAN`, menard `MOSS`, tlon `PINK` | a repo's glyph, number, chip lead and goal bar |
| per state | building `AMBER`, verifying/reviewing `CYAN`, queued dim, sent back/stalled `RED`, landed `MOSS` | state chips and glyphs |

## Surfaces and depth

- Three steps up from the ground: panel, tile, raised. A thing goes up a step when it is picked.
- **A window** has a one-row title bar: `◆`, its name, a count badge, and `▫` at the right. When it
  has focus, the bar is `raised` with `═══` stripes in half-strength amber. Otherwise it is `tile`.
- **The shadow** is hard and one cell deep: `▌` down the right and `▀` under it, in `BG`. A window,
  the focal goal, the pick and a button each cast one. Only those cast one.
- A card's top row is a `▔` highlight in `raised`, the bevel's light edge.

## Chips and pills

`▎label ` on `raised`: a lead bar in the chip's colour, then its text. A filled chip, for "asks"
or `▲ 3 need you`, has its colour as the face and `INK` text. Count badges are dim chips.

## Buttons and toggles

- A button is ` key label ` on `raised`, its key in amber, with its own shadow. The primary one,
  only one per area, is filled amber with `INK` text.
- A toggle is a word and a three-cell switch: `auto ▐ ●▌`, filled amber with the knob right when
  on, and `well` with the knob left when off.
- Tabs sit on the row under the title bar. The current tab is `panel`, so it joins the window
  below it, and the others are `tile`.

## Spacing grid

- A one-cell gutter inside every window and a one-cell gap between windows. The shadow takes the gap.
- A card is 2 cells in from its column, and its rows are title ×1–2, then pills. One blank row
  between cards.
- Columns split the main area 40 / 33 / 27 (todo, doing, review). The rail is 7 cells, and the
  orchestrator's column is 62.

## Glyphs

Repos: arena ``, babylon ``, ficciones ``, menard ``, tlon ``. States: building ``,
verifying ``, reviewing ``, queued or waiting ``, sent back ``, landed ``, waits-on link
``. Priority dots: `●` high (red), `◉` med, `○` low. Window: `◆` title, `▫` box, `✕` close.
A Nerd Font glyph is always followed by a space, because Ghostty lets it spill into the next cell.
