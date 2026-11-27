# The meta first

This design is for #1195, step 1 of epic #1193. It is held to [the principles](~/projects/ficciones/docs/principles.md),
and every rule there still holds. Where it and an older doc disagree, this page wins. It
supersedes parts of [What arena is](what-arena-is.md) and [Doing and Planning](doing-planning.md),
and each says which at its top. Nothing in #1193 is built until the human has read this page and
said go. Their go covers the screens and babylon's project and settings model (#1206–#1208), and
[What babylon gives the screens](#what-babylon-gives-the-screens) says what those give.

The human, 2026-11-27, looking at Planning: "we've gone too far lol. things are now like tooooo
condensed and densely packed and flat. they kinda expand but don't. less focus on the actual
claude sessions, more focus and emphasis on the meta. In planning and doing".

- On landed: "landed is taking up a lot of space for little value. is there some other sort of
  'queue' even if it's liek a nested tree sort of structure". Shown four ways to replace it
  (#1192: per-repo lanes, a chain tree, a goal tree, or just shrinking it), they asked for one view
  that does all four without getting dense, and said yes to the departures board drawn below.
- On other projects, a missing layer, "Global vs. Project settings for auto mode" and "a meta view
  of everything": "keep it all in one … I just want the visual/informational split to work right".
- Drilled into a session from the board: "whatever layer of the stack I'm in right now is missing
  something" (#1211).

## The ladder

There is one ladder, five rungs deep: **all → a project → a goal → a ticket → its session**.
Every rung leads with the meta, and each says the same three things:

- **where you are:** the head's picker for the first two rungs, and a path in the title bar for
  the three opened in the middle column (`doing › Ficciones › ◆ #1193 the meta first › #1196`);
- **the way back:** `esc` goes back one step, the way you came, and a click on any part of the
  path goes to that rung;
- **what needs you:** `▲ N` in the head on every rung, across every project. Each rung also shows,
  at its top, the Needs you items that are about it.

Each rung opens into the next with the same look, open and go (principle 4). Picking a row opens
it in place. `space` opens it whole in the middle column, and `⏎` goes.

| rung | where it is drawn | where you are | what needs you, on it | opens into |
| --- | --- | --- | --- | --- |
| **all** | Doing or Planning, head on `all` | `[all]` in the head | Needs you, every item | a project: `⏎` on its row in Projects, or its name in the head |
| **a project** | the same screens, narrowed | `[Ficciones]` in the head | Needs you, every item still, each tagged with its project | its goal: `space` on Heading for, or on a goal on Planning |
| **a goal** | its card, in the middle column | `doing › Ficciones › ◆ #1193 …` | the items about its steps, at the card's top | a step: `⏎` on it opens the ticket's card |
| **a ticket** | its card (#1174), in the middle column | `… › #1196 sections breathe` | its own items: its checks, its ask, a send-back | its session: `⏎` on a ticket with a Claude |
| **its session** | the Claude's pane, in the middle column | the same path, and the ticket's line | its open ask, with `⏎ answer` | nothing further; `i` types into it |

## The look

- **Room.** One blank row between windows, each in its own box. Windows no longer touch or share
  an edge (today in flight joins next, and goals join no goal).
- **Frames stay.** The sketch drew bare headings, but focus (principle 6, the turning gradient)
  is drawn on a window's frame, so each section keeps its box. A window's title is its heading.
- **Colour.** Window titles and goal headings are in the accent role, bold. Counts, labels and
  tags are dim. Bodies are in the text role. There are no new colours, and dim keeps 4.5:1
  (principle 12).
- **One row per thing, one state word.** A row is its state word, `#id`, short name, repo, `◆` on
  a step of a driven goal, one wait word, and its age right-aligned. Everything else moves into the
  opened row (principle 13). These second chips go from the rows:
  - next's pin glyph, which becomes `pinned` in the opened row's stage line;
  - no goal's and backlog's priority word (`med`, `high`), which moves to the stage line;
  - a goal step's `next K`, which moves to the stage line;
  - in flight's held chip (session·window·pane), which moves to the Claudes list (`c`).
- **The short name.** A row shows the ticket's `short` (babylon's few-word name, such as
  `sections breathe`), cut at a word with `…`. The sketch drew no name at all. A bare `#1196`
  tells nothing at a glance, and `short` is the short form principle 13 means. The full title is
  in the opened row.

## Doing

Doing answers "does anything need me, and what is moving, in what order?". It is three windows
and nothing else: **Needs you**, **Heading for** (or **Projects** on `all`), and **the board**.
Claudes are not drawn on Doing. A stuck one, or one that waits in its pane, is a Needs you item,
and `c` lists them all.

### On all, at 1920 px (220 × 51)

The pick is on #1198, an up-next row, so it is open.

```
 ◆ [doing]  planning     [all] · Ficciones · aleph · asterion      / find                                                                                      ◐ auto 4/8   ⌸ 5 Claudes   ◆ orch 12s   ✓ 23 today   ▲ 3   ≡
┌─ ◆ NEEDS YOU │ 3 ────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────┐
│  >_ ▲ #1195  read docs/meta-first.md and say go                                                                                                                                               Ficciones   asks you    2m │
│  >_ ✗ #1172  sent back: the review asks to drop otherName                                                                                                                                    Ficciones   sent back   14m │
│  ✉  ◇ #1233  stuck: its Claude has stopped                                                                                                                                                  asterion    ⏎ open pane   9m │
│                                                                                                                                                                                                                          │
│                                                                                                                                                                                                                          │
└──────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────┘

┌─ ◆ projects │ 3 ─────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────┐
│   Ficciones   ◆ #1193 the meta first            ███▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒   3/19  16%      ◐ auto      3 building · 1 landing                                                                                                 │
│   aleph       ◆ #1240 aleph reads a whole book  ▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒   0/4    0%      ○ manual    idle                                                                                                                   │
│   asterion    nothing driven · pick a goal on planning                         ◐ auto      1 building · 1 stuck                                                                                                          │
│                                                                                                                                                                                                                          │
└──────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────┘

┌─ ◆ board │ 3 landed today · 7 moving · 4 next ───────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────┐
│  ✓ landed     #1185  run e2e through menard             menard                                                                                                                                                       41m │
│  ✓ landed     #1189  the foot keeps its window          arena                                                                                                                                                         3m │
│ ───────────────────────────────────────────────────────────────────────────────────────────────────────── now ────────────────────────────────────────────────────────────────────────────────────────────────────────── │
│  ◒ landing    #1187  release menard with run e2e        menard                                                                                                                                                        1m │
│  ◒ reviewing  #1206  next says why it waits             babylon   ◆                                                                                                                                                   6m │
│  ◒ verifying  #1230  a mail filter per sender           asterion                                                                                                                                                      2m │
│  » queued 1st #1204  what-it-is.md comes first          babylon   ◆                                                                                                                                                   8m │
│  ◐ building   #1196  sections breathe                   arena     ◆                                                                                                                                                  12m │
│  ◐ building   #1207  projects in babylon                babylon   ◆                                                                                                                                                   4m │
│  ◇ stuck      #1233  a digest a day                     asterion                                                                                                                                                     31m │
│ ▌· up next    #1198  a picked row opens                 arena     ◆  after #1196                                                                                                                                         │
│                 Expand opens: the picked row opens in place into its detail, with its keys as the block's last row                                                                                                       │
│                                                                                                                                                                                                                          │
│                 goal     ◆ #1193 the meta first · step 3 of 19                                                                                                                                                           │
│                 why      the human: "they kinda expand but don't"                                                                                                                                                        │
│                 waits    after #1196: arena's cap is 1                                                                                                                                                                   │
│                 stage    todo · next 1 · filed 2h ago                                                                                                                                                                    │
│                 checks   none                                                                                                                                                                                            │
│                 ⏎ start now   space card   G give                                                                                                                                                                        │
│  · up next    #1191  next says why                      arena     ◆  waits #1206                                                                                                                                         │
│  · up next    #761   0-width pane overflow              arena        after #1196                                                                                                                                         │
│  · up next    #1241  aleph: the page reader             aleph        manual                                                                                                                                              │
│                                                                                                                                                                                                                          │
│                                                                                                                                                                                                                          │
│                                                                                                                                                                                                                          │
│                                                                                                                                                                                                                          │
│                                                                                                                                                                                                                          │
│                                                                                                                                                                                                                          │
│                                                                                                                                                                                                                          │
│                                                                                                                                                                                                                          │
│                                                                                                                                                                                                                          │
│                                                                                                                                                                                                                          │
└──────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────┘
 NORMAL  ⏎ start now  space card  G give   │   j k pick  h l window  tab planning  r project  c Claudes  , settings  / find  o orch   │                                                                              ? keys
```

The 49 rows between the head and the foot bar are fixed slots, worked out from the screen size
alone (principle 10):

- **Needs you**: full width, its title and five rows, as Your move has today. Only its title is
  new.
- a blank row;
- **Projects** (on `all`): full width, four rows, scrolling past four projects. Its height does
  not follow the count.
- a blank row;
- **The board**: the rest, 34 rows.

### On all, at half width (110 × 51)

The same three windows, one under another: Needs you with three rows, Projects with four, and the
board with the rest. Repo and short name are narrower, and the opened row's title wraps.

```
 ◆ [doing]  planning   [all] · Ficciones · aleph · asterion                                ◐ 4/8  ⌸ 5  ▲ 3  ≡
┌─ ◆ NEEDS YOU │ 3 ──────────────────────────────────────────────────────────────────────────────────────────┐
│  >_ ▲ #1195  read docs/meta-first.md and say go                                             Ficciones   2m │
│  >_ ✗ #1172  sent back: drop otherName                                                      Ficciones  14m │
│  ✉  ◇ #1233  stuck: its Claude has stopped                                                  asterion    9m │
└────────────────────────────────────────────────────────────────────────────────────────────────────────────┘

┌─ ◆ projects │ 3 ───────────────────────────────────────────────────────────────────────────────────────────┐
│   Ficciones  #1193 the meta first      ███▒▒▒▒▒▒▒▒▒  3/19 16%   ◐ auto    3 building                       │
│   aleph      #1240 aleph reads a book  ▒▒▒▒▒▒▒▒▒▒▒▒  0/4   0%   ○ manual  idle                             │
│   asterion   nothing driven                                     ◐ auto    1 building                       │
│                                                                                                            │
└────────────────────────────────────────────────────────────────────────────────────────────────────────────┘

┌─ ◆ board │ 3 landed today · 7 moving · 4 next ─────────────────────────────────────────────────────────────┐
│  ✓ landed     #1185  run e2e through menard  menard                                                    41m │
│  ✓ landed     #1189  the foot keeps its win… arena                                                      3m │
│ ────────────────────────────────────────────────── now ─────────────────────────────────────────────────── │
│  ◒ landing    #1187  release menard with ru… menard                                                     1m │
│  ◒ reviewing  #1206  next says why it waits  babylon  ◆                                                 6m │
│  ◒ verifying  #1230  a mail filter per send… asterion                                                   2m │
│  » queued 1st #1204  what-it-is.md comes fi… babylon  ◆                                                 8m │
│  ◐ building   #1196  sections breathe        arena    ◆                                                12m │
│  ◐ building   #1207  projects in babylon     babylon  ◆                                                 4m │
│  ◇ stuck      #1233  a digest a day          asterion                                                  31m │
│ ▌· up next    #1198  a picked row opens      arena    ◆  after #1196                                       │
│                 Expand opens: the picked row opens in place into its                                       │
│                 detail, with its keys as the block's last row                                              │
│                                                                                                            │
│                 goal     ◆ #1193 the meta first · step 3 of 19                                             │
│                 why      the human: "they kinda expand but don't"                                          │
│                 waits    after #1196: arena's cap is 1                                                     │
│                 stage    todo · next 1 · filed 2h ago                                                      │
│                 checks   none                                                                              │
│                 ⏎ start now   space card   G give                                                          │
│  · up next    #1191  next says why           arena    ◆  waits #1206                                       │
│  · up next    #761   0-width pane overflow   arena       after #1196                                       │
│  · up next    #1241  aleph: the page reader  aleph       manual                                            │
│                                                                                                            │
│                                                                                                            │
│                                                                                                            │
│                                                                                                            │
│                                                                                                            │
│                                                                                                            │
│                                                                                                            │
│                                                                                                            │
│                                                                                                            │
│                                                                                                            │
│                                                                                                            │
└────────────────────────────────────────────────────────────────────────────────────────────────────────────┘
 NORMAL  ⏎ start  space card  G give  │  j k  tab planning  r project  c Claudes │                     ? keys
```

### On one project, at 220 × 51

The head is on `Ficciones`. Needs you still holds every item, asterion's too. Projects gives way to
**Heading for**, one row, and the board shows only Ficciones' repos. The pick is on #1196, a
building row, so it is open.

```
 ◆ [doing]  planning     all · [Ficciones] · aleph · asterion      / find                                                                                      ◐ auto 4/8   ⌸ 5 Claudes   ◆ orch 12s   ✓ 23 today   ▲ 3   ≡
┌─ ◆ NEEDS YOU │ 3 ────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────┐
│  >_ ▲ #1195  read docs/meta-first.md and say go                                                                                                                                               Ficciones   asks you    2m │
│  >_ ✗ #1172  sent back: the review asks to drop otherName                                                                                                                                    Ficciones   sent back   14m │
│  ✉  ◇ #1233  stuck: its Claude has stopped                                                                                                                                                  asterion    ⏎ open pane   9m │
│                                                                                                                                                                                                                          │
│                                                                                                                                                                                                                          │
└──────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────┘

┌─ ◆ heading for  #1193 the meta first: Doing and Planning lead with goals, what lands next and what needs you   ◐ auto · 3 building ─────────────────────────────────────────────────── ███▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒   3/19  16% ─┐

┌─ ◆ board │ 3 landed today · 5 moving · 3 next ───────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────┐
│  ✓ landed     #1185  run e2e through menard             menard                                                                                                                                                       41m │
│  ✓ landed     #1189  the foot keeps its window          arena                                                                                                                                                         3m │
│ ───────────────────────────────────────────────────────────────────────────────────────────────────────── now ────────────────────────────────────────────────────────────────────────────────────────────────────────── │
│  ◒ landing    #1187  release menard with run e2e        menard                                                                                                                                                        1m │
│  ◒ reviewing  #1206  next says why it waits             babylon   ◆                                                                                                                                                   6m │
│  » queued 1st #1204  what-it-is.md comes first          babylon   ◆                                                                                                                                                   8m │
│ ▌◐ building   #1196  sections breathe                   arena     ◆                                                                                                                                                  12m │
│                 Sections breathe: one blank row between sections, headings in the accent colour, one state word per row                                                                                                  │
│                                                                                                                                                                                                                          │
│                 goal     ◆ #1193 the meta first · step 2 of 19                                                                                                                                                           │
│                 stage    building 12m · t1196-sections-breathe                                                                                                                                                           │
│                 Claude   ◐ working · arena:2 · ⏎ opens its pane                                                                                                                                                          │
│                 checks   ○ no two windows touch, at 220×51 and 110×51                                                                                                                                                    │
│                 ⏎ pane   space card   H hand off                                                                                                                                                                         │
│  ◐ building   #1207  projects in babylon                babylon   ◆                                                                                                                                                   4m │
│  · up next    #1198  a picked row opens                 arena     ◆  after #1196                                                                                                                                         │
│  · up next    #1191  next says why                      arena     ◆  waits #1206                                                                                                                                         │
│  · up next    #761   0-width pane overflow              arena        after #1196                                                                                                                                         │
│                                                                                                                                                                                                                          │
│                                                                                                                                                                                                                          │
│                                                                                                                                                                                                                          │
│                                                                                                                                                                                                                          │
│                                                                                                                                                                                                                          │
│                                                                                                                                                                                                                          │
│                                                                                                                                                                                                                          │
│                                                                                                                                                                                                                          │
│                                                                                                                                                                                                                          │
│                                                                                                                                                                                                                          │
│                                                                                                                                                                                                                          │
│                                                                                                                                                                                                                          │
│                                                                                                                                                                                                                          │
│                                                                                                                                                                                                                          │
│                                                                                                                                                                                                                          │
│                                                                                                                                                                                                                          │
│                                                                                                                                                                                                                          │
│                                                                                                                                                                                                                          │
│                                                                                                                                                                                                                          │
└──────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────┘
 NORMAL  ⏎ pane  space card  H hand off   │   j k pick  h l window  tab planning  r project  c Claudes  , settings  / find  o orch   │                                                                               ? keys
```

### On one project, at 110 × 51

```
 ◆ [doing]  planning   all · [Ficciones] · aleph · asterion                                ◐ 4/8  ⌸ 5  ▲ 3  ≡
┌─ ◆ NEEDS YOU │ 3 ──────────────────────────────────────────────────────────────────────────────────────────┐
│  >_ ▲ #1195  read docs/meta-first.md and say go                                             Ficciones   2m │
│  >_ ✗ #1172  sent back: drop otherName                                                      Ficciones  14m │
│  ✉  ◇ #1233  stuck: its Claude has stopped                                                  asterion    9m │
└────────────────────────────────────────────────────────────────────────────────────────────────────────────┘

┌─ ◆ heading for  #1193 the meta first  ◐ auto ───────────────────────────────────── ███▒▒▒▒▒▒▒▒▒  3/19 16% ─┐

┌─ ◆ board │ 3 landed today · 5 moving · 3 next ─────────────────────────────────────────────────────────────┐
│  ✓ landed     #1185  run e2e through menard  menard                                                    41m │
│  ✓ landed     #1189  the foot keeps its win… arena                                                      3m │
│ ────────────────────────────────────────────────── now ─────────────────────────────────────────────────── │
│  ◒ landing    #1187  release menard with ru… menard                                                     1m │
│  ◒ reviewing  #1206  next says why it waits  babylon  ◆                                                 6m │
│  » queued 1st #1204  what-it-is.md comes fi… babylon  ◆                                                 8m │
│ ▌◐ building   #1196  sections breathe        arena    ◆                                                12m │
│                 Sections breathe: one blank row between sections,                                          │
│                 headings in the accent colour, one state word per row                                      │
│                                                                                                            │
│                 goal     ◆ #1193 the meta first · step 2 of 19                                             │
│                 stage    building 12m · t1196-sections-breathe                                             │
│                 Claude   ◐ working · arena:2 · ⏎ opens its pane                                            │
│                 checks   ○ no two windows touch, at 220×51 and 110×51                                      │
│                 ⏎ pane   space card   H hand off                                                           │
│  ◐ building   #1207  projects in babylon     babylon  ◆                                                 4m │
│  · up next    #1198  a picked row opens      arena    ◆  after #1196                                       │
│  · up next    #1191  next says why           arena    ◆  waits #1206                                       │
│  · up next    #761   0-width pane overflow   arena       after #1196                                       │
│                                                                                                            │
│                                                                                                            │
│                                                                                                            │
│                                                                                                            │
│                                                                                                            │
│                                                                                                            │
│                                                                                                            │
│                                                                                                            │
│                                                                                                            │
│                                                                                                            │
│                                                                                                            │
│                                                                                                            │
│                                                                                                            │
│                                                                                                            │
│                                                                                                            │
│                                                                                                            │
│                                                                                                            │
│                                                                                                            │
│                                                                                                            │
│                                                                                                            │
└────────────────────────────────────────────────────────────────────────────────────────────────────────────┘
 NORMAL  ⏎ pane  space card  H hand off  │  j k  tab planning  r project  c Claudes │                  ? keys
```

### Needs you

Needs you is today's Your move, retitled. It holds the same items with the same keys (checks,
asks, proposals, a push, the digest, a restart, a Claude that waits in its pane), and adds one:

- **a stuck Claude:** `◇ #1233 stuck: its Claude has stopped`, with `⏎ open pane`. It is there
  while babylon calls the ticket stalled, and leaves when it no longer does.

It **never narrows**. Picking a project in the head leaves every item in place, and each one
carries its project, right-aligned and dim. It is the only window that may grow, as principle 10
allows, and today it doesn't need to.

### Heading for and Projects

- **On one project, Heading for** is one row, a title bar with no body:
  `◆ heading for  #1193 title`, then the project's auto word, then the bar and `N/M P%`
  right-aligned (principle 12). With no goal driven it reads `heading for  nothing · pick a goal
  on planning`, dim.
  - `space` or a click opens the goal's card in the middle column, the goal rung.
  - `⏎` opens Planning with the pick on that goal.
  - Today's chain-of-steps peek goes. The board's `◆` marks show where the goal's steps are.
- **On all, Projects** has one row per project: its name, its driven goal's `◆ #id short`, its bar
  and `N/M P%`, its auto word (`◐ auto`, `○ manual` or `‖ held`), and what is moving in it
  (`3 building · 1 landing`, `idle`, or `1 stuck`).
  - `⏎` narrows both screens to that project, as picking it in the head does.
  - `space` opens its driven goal's card.
  - `a` turns its auto on or off, and `p` holds it or lets it go
    ([Projects and settings](#projects-and-settings)).
  - A project row does not open in place. What it would open to is its own board rows, and `⏎`
    shows exactly that.

### The board

One list across every repo of the head's scope, ordered by time. It replaces in flight, next and
landed, and so it holds the four options the human was shown:

- **landed** is the top of the board, above the `now` line;
- **lanes** are the repo tag on each row;
- **chains** are the wait word (`after #1196`);
- **the goal tree** is `◆`.

**Order, top to bottom:**

1. landed today, oldest first, so the latest sits just above the line;
2. the `now` line, dim, the whole width;
3. in the pipeline, in landing order: landing, reviewing, verifying, then queued in queue order;
4. building (and doing), oldest first, with stuck ones among them as `◇ stuck`;
5. next, in next's order, each with its wait word.

**State words**, each with its glyph so none is said by colour alone (principle 12): `✓ landed`,
`◒ landing`, `◒ reviewing`, `◒ verifying`, `» queued 1st`, `◐ building`, `◇ stuck`, `· up next`.

**Wait words** come from babylon's `held` on each next row (#1206, #1191): `ready`, `after #N`
(N holds the repo's cap, or a path the ticket names), `waits #N` (blocked by N), `cap full`,
`auto off`, `starting`, and for a project's layer `held`, `manual` or `cap full`. `ready` shows
only when nothing holds the row.

**Scroll.** The board opens scrolled so the `now` line sits two rows from its top. One or two
landed rows show, and older ones are above, out of sight. `j`/`k` move the pick, and the window
scrolls inside its fixed rect. The board's title counts what it holds: `3 landed today ·
5 moving · 3 next`.

**Picking opens** the row in place: the row's own line, then under it, indented to the `#id`:

- the title in full, wrapped at words (#1172);
- a blank row;
- labelled lines, labels dim in one column (principle 12), only those that have something to say:
  - `goal`: `◆ #1193 the meta first · step 3 of 19`;
  - `why`: next's why;
  - `waits`: the wait word in full, `after #1196: arena's cap is 1`, `after #1172: both touch
    src/app.zig`;
  - `stage`: state and age, and what goes with it (`building 12m · t1196-…`, `queued 2nd`, `landed
    f06e86a · installed`, `todo · next 1 · pinned · med`);
  - `Claude`: on a building or stuck row, its Claude's state and where it runs;
  - `checks`: one `✓`/`✗`/`○` row each;
- the keys, as the block's last row.

The window keeps its rect. Rows under the block move down inside it, and the window scrolls so the
whole block is in view. Moving the pick closes the block and opens the next. Only the human's pick
moves rows (principle 10).

**Keys on a board row**, by its state:

| row | `⏎` | also |
| --- | --- | --- |
| building, doing, stuck | opens its pane in the middle column (the session rung) | `H` hand off |
| landing, reviewing, verifying, queued | opens its card | `g` its gate |
| up next | starts it now, as next's `⏎` does today | `G` give it to a running Claude |
| landed | opens its card | |

`space` opens the card on every row. Reordering next (`J` `K` `x` and dragging) stays on Planning.

### Claudes, one key away

`c`, or a click on `⌸ 5 Claudes` in the head, opens every session in the middle column: the
Claudes working on tickets, then those with no ticket. This is today's in flight and other Claudes,
moved off Doing. `arena claudes` opens it too (principle 7).

```
┌─ ◆ doing › Claudes │ 5 ────────────────────────────────────────────────────────────────────── × ─┐
│ ▌>_ #1196 sections breathe        ◐ building · working 20s                      arena:2      12m │
│  ☗  #1207 projects in babylon     ◐ building · working 4s                       babylon:1     4m │
│  ✉  #1233 a digest a day          ◇ stuck · stopped 9m                          asterion:1   31m │
│                                                                                                  │
│ ── no ticket 2 ────────────────────────────────────────────────────────────────────────────────  │
│  ⌸  ◐ menard · indexing the repo                                                menard:1      4m │
│  ✎  ○ ficciones · your shell                                                    ficciones:2   1h │
│                                                                                                  │
│ ⏎ pane   space card   H hand off   esc back                                                      │
└──────────────────────────────────────────────────────────────────────────────────────────────────┘
```

`⏎` opens the picked one's pane, `space` its ticket's card, `H` hands it off, and `esc` goes back
to Doing with the pick where it was.

## Planning

Planning answers "what comes after, and in what shape?". Each goal is a big heading: accent and
bold, with a blank row after it. The picked goal opens to its steps, and the others stay closed to
their heading. Next, no goal and the backlog sit beside them.

### On all, at 220 × 51

The pick is on #1193's heading, so it is open to its steps, with its keys as the last row.

```
 ◆ doing  [planning]    [all] · Ficciones · aleph · asterion      / find                                                                                       ◐ auto 4/8   ⌸ 5 Claudes   ◆ orch 12s   ✓ 23 today   ▲ 3   ≡
┌─ ◆ goals │ 6 ─────────────────────────────────────────────────────────────────────────────────────────────────────────── + goal ─┐ ┌─ ◆ next │ 4 ────────────────────────────────────────────────────────────────────────┐
│   Ficciones                                                                                                                      │ │  1 #1198  a picked row opens       arena                                after #1196 │
│                                                                                                                                  │ │  2 #1191  next says why            arena                                waits #1206 │
│ ▌◆ #1193 the meta first: Doing and Planning lead with goals   ◆ driving                             ███▒▒▒▒▒▒▒▒▒▒▒▒▒    3/19 16% │ │  3 #761   0-width pane overflow    arena                                after #1196 │
│     ◐ building    #1196  sections breathe               arena                                                                12m │ │  4 #1241  aleph: the page reader   aleph                                     manual │
│     ◐ building    #1207  projects in babylon            babylon                                                               4m │ │                                                                                     │
│     ◒ reviewing   #1206  next says why it waits         babylon                                                               6m │ │                                                                                     │
│     » queued 1st  #1204  what-it-is.md comes first      babylon                                                               8m │ │                                                                                     │
│     · up next     #1198  a picked row opens             arena        after #1196                                                 │ │                                                                                     │
│     · up next     #1191  next says why                  arena        waits #1206                                                 │ │                                                                                     │
│     ○ todo        #1192  the departures board           arena        waits #1198                                                 │ │                                                                                     │
│     ○ todo        #1199  Doing's three sections         arena        waits #1192                                                 │ │                                                                                     │
│     ○ todo        #1209  all or one project             arena        waits #1199                                                 │ │                                                                                     │
│     ○ todo        #1200  Planning per project           arena        waits #1209                                                 │ │                                                                                     │
│     … 6 more open · 3 landed, on the card                                                                                        │ │                                                                                     │
│     d drive   + ticket   a goal…   space card                                                                                    │ │                                                                                     │
│                                                                                                                                  │ │                                                                                     │
│    #896  Plan replaces the board                                                                    ██████████▒▒▒▒▒▒    8/13 62% │ │                                                                                     │
│                                                                                                                                  │ └─────────────────────────────────────────────────────────────────────────────────────┘
│    #1110 Doing and Planning                                                                         █████████▒▒▒▒▒▒▒    4/7  57% │
│                                                                                                                                  │ ┌─ ◆ no goal │ 21 ──────────────────────────────────────────────────────────── + new ─┐
│   aleph                                                                                                                          │ │   arena 11 · babylon 3 · ficciones 2 · menard 1 · asterion 4                        │
│                                                                                                                                  │ │                                                                                     │
│  ◆ #1240 aleph reads a whole book   ◆ driving                                                       ▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒    0/4   0% │ │                                                                                     │
│                                                                                                                                  │ │                                                                                     │
│   asterion                                                                                                                       │ │                                                                                     │
│                                                                                                                                  │ │                                                                                     │
│    #1229 a mail filter per sender                                                                   ██████▒▒▒▒▒▒▒▒▒▒    2/5  40% │ │                                                                                     │
│                                                                                                                                  │ │                                                                                     │
│                                                                                                                                  │ │                                                                                     │
│                                                                                                                                  │ │                                                                                     │
│                                                                                                                                  │ │                                                                                     │
│                                                                                                                                  │ │                                                                                     │
│                                                                                                                                  │ └─────────────────────────────────────────────────────────────────────────────────────┘
│                                                                                                                                  │
│                                                                                                                                  │ ┌─ ◆ backlog │ 6 ─────────────────────────────────────────────────────────────────────┐
│                                                                                                                                  │ │   2 ideas · 1 planning · 1 draft · 2 later                                          │
│                                                                                                                                  │ │                                                                                     │
│                                                                                                                                  │ │                                                                                     │
│                                                                                                                                  │ │                                                                                     │
│                                                                                                                                  │ │                                                                                     │
│                                                                                                                                  │ │                                                                                     │
│                                                                                                                                  │ │                                                                                     │
│                                                                                                                                  │ │                                                                                     │
│                                                                                                                                  │ │                                                                                     │
│                                                                                                                                  │ │                                                                                     │
│                                                                                                                                  │ │                                                                                     │
│                                                                                                                                  │ │                                                                                     │
└──────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────┘ └─────────────────────────────────────────────────────────────────────────────────────┘
 NORMAL  d drive  + ticket  a goal…  space card   │   j k pick  h l window  tab doing  r project  , settings  / find  o orch   │                                                                                     ? keys
```

- **Goals**: the left three fifths (132 cells), the whole height. On `all`, each project's goals
  are under its name (dim), its driven goal first. On one project the names go.
- **Next**: the right 87 cells, 19 rows. The same rows as the board's up-next rows, numbered.
- **No goal**: 14 rows. Until the pick enters it, it shows one count line: its repos and how many
  each has. Once the pick is in it, it shows its repo chips and its rows, in the same rect,
  scrolling.
- **Backlog**: 14 rows, the same way: a count line (`2 ideas · 1 planning · 1 draft · 2 later`)
  until picked, and its rows once it is.
- a blank row between each.

**Which goal is open.** The picked goal, or the goal of the picked step. When the pick leaves
goals for the right column, the goal it was on stays open. On first opening Planning, that is the
driven goal. This replaces `z`'s folds, and `z` goes.

### On all, at 110 × 51

One column: goals 22 rows, next 10, no goal 7 and backlog 7, a blank row between each. The goal
headings drop their bar and keep `N/M P%`.

```
 ◆ doing  [planning]  [all] · Ficciones · aleph · asterion                                 ◐ 4/8  ⌸ 5  ▲ 3  ≡
┌─ ◆ goals │ 6 ───────────────────────────────────────────────────────────────────────────────────── + goal ─┐
│   Ficciones                                                                                                │
│                                                                                                            │
│ ▌◆ #1193 the meta first: Doing and Planning lead with goals  ◆ driving                            3/19 16% │
│     ◐ building    #1196  sections breathe       arena                                                  12m │
│     ◐ building    #1207  projects in babylon    babylon                                                 4m │
│     ◒ reviewing   #1206  next says why it waits babylon                                                 6m │
│     » queued 1st  #1204  what-it-is.md comes f… babylon                                                 8m │
│     · up next     #1198  a picked row opens     arena       after #1196                                    │
│     · up next     #1191  next says why          arena       waits #1206                                    │
│     ○ todo        #1192  the departures board   arena       waits #1198                                    │
│     ○ todo        #1199  Doing's three sections arena       waits #1192                                    │
│     ○ todo        #1209  all or one project     arena       waits #1199                                    │
│     ○ todo        #1200  Planning per project   arena       waits #1209                                    │
│     … 6 more open · 3 landed, on the card                                                                  │
│     d drive   + ticket   a goal…   space card                                                              │
│                                                                                                            │
│    #896  Plan replaces the board                                                                  8/13 62% │
│                                                                                                            │
│    #1110 Doing and Planning                                                                       4/7  57% │
│                                                                                                            │
└────────────────────────────────────────────────────────────────────────────────────────────────────────────┘

┌─ ◆ next │ 4 ───────────────────────────────────────────────────────────────────────────────────────────────┐
│  1 #1198  a picked row opens       arena                                                       after #1196 │
│  2 #1191  next says why            arena                                                       waits #1206 │
│  3 #761   0-width pane overflow    arena                                                       after #1196 │
│  4 #1241  aleph: the page reader   aleph                                                            manual │
│                                                                                                            │
│                                                                                                            │
│                                                                                                            │
│                                                                                                            │
└────────────────────────────────────────────────────────────────────────────────────────────────────────────┘

┌─ ◆ no goal │ 21 ─────────────────────────────────────────────────────────────────────────────────── + new ─┐
│   arena 11 · babylon 3 · ficciones 2 · menard 1 · asterion 4                                               │
│                                                                                                            │
│                                                                                                            │
│                                                                                                            │
│                                                                                                            │
└────────────────────────────────────────────────────────────────────────────────────────────────────────────┘

┌─ ◆ backlog │ 6 ────────────────────────────────────────────────────────────────────────────────────────────┐
│   2 ideas · 1 planning · 1 draft · 2 later                                                                 │
│                                                                                                            │
│                                                                                                            │
│                                                                                                            │
│                                                                                                            │
└────────────────────────────────────────────────────────────────────────────────────────────────────────────┘
 NORMAL  d drive  + ticket  a goal…  space card  │  j k  tab doing  r project │                        ? keys
```

### On one project, at 220 × 51

The head is on `Ficciones`, so the goals are Ficciones' and the project names go. Next and no goal
hold only Ficciones' repos. The pick is in no goal, on #1058, so no goal shows its rows with #1058
open, and #1193 stays open on the left because the pick was last there.

```
 ◆ doing  [planning]    all · [Ficciones] · aleph · asterion      / find                                                                                       ◐ auto 4/8   ⌸ 5 Claudes   ◆ orch 12s   ✓ 23 today   ▲ 3   ≡
┌─ ◆ goals │ 3 ─────────────────────────────────────────────────────────────────────────────────────────────────────────── + goal ─┐ ┌─ ◆ next │ 3 ────────────────────────────────────────────────────────────────────────┐
│  ◆ #1193 the meta first: Doing and Planning lead with goals   ◆ driving                             ███▒▒▒▒▒▒▒▒▒▒▒▒▒    3/19 16% │ │  1 #1198  a picked row opens       arena                                after #1196 │
│     ◐ building    #1196  sections breathe               arena                                                                12m │ │  2 #1191  next says why            arena                                waits #1206 │
│     ◐ building    #1207  projects in babylon            babylon                                                               4m │ │  3 #761   0-width pane overflow    arena                                after #1196 │
│     ◒ reviewing   #1206  next says why it waits         babylon                                                               6m │ │                                                                                     │
│     » queued 1st  #1204  what-it-is.md comes first      babylon                                                               8m │ │                                                                                     │
│     · up next     #1198  a picked row opens             arena        after #1196                                                 │ │                                                                                     │
│     · up next     #1191  next says why                  arena        waits #1206                                                 │ │                                                                                     │
│     ○ todo        #1192  the departures board           arena        waits #1198                                                 │ │                                                                                     │
│     ○ todo        #1199  Doing's three sections         arena        waits #1192                                                 │ │                                                                                     │
│     ○ todo        #1209  all or one project             arena        waits #1199                                                 │ │                                                                                     │
│     ○ todo        #1200  Planning per project           arena        waits #1209                                                 │ │                                                                                     │
│     … 6 more open · 3 landed, on the card                                                                                        │ │                                                                                     │
│                                                                                                                                  │ │                                                                                     │
│    #896  Plan replaces the board                                                                    ██████████▒▒▒▒▒▒    8/13 62% │ │                                                                                     │
│                                                                                                                                  │ │                                                                                     │
│    #1110 Doing and Planning                                                                         █████████▒▒▒▒▒▒▒    4/7  57% │ │                                                                                     │
│                                                                                                                                  │ │                                                                                     │
│                                                                                                                                  │ └─────────────────────────────────────────────────────────────────────────────────────┘
│                                                                                                                                  │
│                                                                                                                                  │ ┌─ ◆ no goal │ 17 ──────────────────────────────────────────────────────────── + new ─┐
│                                                                                                                                  │ │  [arena 11]  babylon 3  ficciones 2  menard 1                                       │
│                                                                                                                                  │ │ ▌#1058  copy a branch from a card  arena                                       todo │
│                                                                                                                                  │ │          Copy a ticket's branch name from its card                                  │
│                                                                                                                                  │ │                                                                                     │
│                                                                                                                                  │ │          goal     none                                                              │
│                                                                                                                                  │ │          stage    todo · med · filed 3d ago                                         │
│                                                                                                                                  │ │          a goal…   w next   > close   e edit   p priority                           │
│                                                                                                                                  │ │  #1052  help lists keys by window  arena                                       todo │
│                                                                                                                                  │ │  #1060  a goal's bar shows review  arena                                       todo │
│                                                                                                                                  │ │  #761   0-width pane overflow      arena                                     next 3 │
│                                                                                                                                  │ │                                                                                     │
│                                                                                                                                  │ │                                                                                     │
│                                                                                                                                  │ └─────────────────────────────────────────────────────────────────────────────────────┘
│                                                                                                                                  │
│                                                                                                                                  │ ┌─ ◆ backlog │ 4 ─────────────────────────────────────────────────────────────────────┐
│                                                                                                                                  │ │   2 ideas · 1 planning · 1 draft · 2 later                                          │
│                                                                                                                                  │ │                                                                                     │
│                                                                                                                                  │ │                                                                                     │
│                                                                                                                                  │ │                                                                                     │
│                                                                                                                                  │ │                                                                                     │
│                                                                                                                                  │ │                                                                                     │
│                                                                                                                                  │ │                                                                                     │
│                                                                                                                                  │ │                                                                                     │
│                                                                                                                                  │ │                                                                                     │
│                                                                                                                                  │ │                                                                                     │
│                                                                                                                                  │ │                                                                                     │
│                                                                                                                                  │ │                                                                                     │
└──────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────┘ └─────────────────────────────────────────────────────────────────────────────────────┘
 NORMAL  a goal…  w next  > close  e edit  p priority  space card   │   j k pick  h l window  tab doing  r project  / find  o orch   │                                                                               ? keys
```

### On one project, at 110 × 51

```
 ◆ doing  [planning]  all · [Ficciones] · aleph · asterion                                 ◐ 4/8  ⌸ 5  ▲ 3  ≡
┌─ ◆ goals │ 3 ───────────────────────────────────────────────────────────────────────────────────── + goal ─┐
│  ◆ #1193 the meta first: Doing and Planning lead with goals  ◆ driving                            3/19 16% │
│     ◐ building    #1196  sections breathe       arena                                                  12m │
│     ◐ building    #1207  projects in babylon    babylon                                                 4m │
│     ◒ reviewing   #1206  next says why it waits babylon                                                 6m │
│     » queued 1st  #1204  what-it-is.md comes f… babylon                                                 8m │
│     · up next     #1198  a picked row opens     arena       after #1196                                    │
│     · up next     #1191  next says why          arena       waits #1206                                    │
│     ○ todo        #1192  the departures board   arena       waits #1198                                    │
│     ○ todo        #1199  Doing's three sections arena       waits #1192                                    │
│     ○ todo        #1209  all or one project     arena       waits #1199                                    │
│     ○ todo        #1200  Planning per project   arena       waits #1209                                    │
│     … 6 more open · 3 landed, on the card                                                                  │
│                                                                                                            │
│    #896  Plan replaces the board                                                                  8/13 62% │
│                                                                                                            │
│    #1110 Doing and Planning                                                                       4/7  57% │
└────────────────────────────────────────────────────────────────────────────────────────────────────────────┘

┌─ ◆ next │ 3 ───────────────────────────────────────────────────────────────────────────────────────────────┐
│  1 #1198  a picked row opens       arena                                                       after #1196 │
│  2 #1191  next says why            arena                                                       waits #1206 │
│  3 #761   0-width pane overflow    arena                                                       after #1196 │
│                                                                                                            │
│                                                                                                            │
│                                                                                                            │
└────────────────────────────────────────────────────────────────────────────────────────────────────────────┘

┌─ ◆ no goal │ 17 ─────────────────────────────────────────────────────────────────────────────────── + new ─┐
│  [arena 11]  babylon 3  ficciones 2  menard 1                                                              │
│ ▌#1058  copy a branch from a card      arena                                                          todo │
│          Copy a ticket's branch name from its card                                                         │
│                                                                                                            │
│          goal     none                                                                                     │
│          stage    todo · med · filed 3d ago                                                                │
│          a goal…   w next   > close   e edit   p priority                                                  │
│  #1052  help lists keys by window      arena                                                          todo │
│  #1060  a goal's bar shows review      arena                                                          todo │
│  #761   0-width pane overflow          arena                                                        next 3 │
│                                                                                                            │
└────────────────────────────────────────────────────────────────────────────────────────────────────────────┘

┌─ ◆ backlog │ 4 ────────────────────────────────────────────────────────────────────────────────────────────┐
│   2 ideas · 1 planning · 1 draft · 2 later                                                                 │
│                                                                                                            │
│                                                                                                            │
│                                                                                                            │
│                                                                                                            │
└────────────────────────────────────────────────────────────────────────────────────────────────────────────┘
 NORMAL  a goal…  w next  > close  e edit  │  j k  tab doing  r project │                              ? keys
```

### Planning's moves

Every move in [Doing and Planning](doing-planning.md#every-move-on-planning) stays, with the same
key, click and babylon command, on goal and step rows as on no goal's rows. Three change:

- `d` drives the goal in its own project (`babylon drive N`, which sets N's project's goal, #1207).
- `+` on goals with the head on `all` asks which project the goal is for, defaulting to the
  project of the goal under the pick. On one project it is that project's.
- `z` is removed, since the open goal follows the pick.

## A session

A session is the last rung: a Claude's pane in the middle column, opened by `⏎` on a building row,
a stuck item, or a row in the Claudes list. It leads with the meta, as the other rungs do.

- **The title bar** is the path: `◆ doing › Ficciones › ◆ #1193 the meta first › #1196 sections
  breathe`. Each part is a click to that rung, and `esc` goes back to where you came from with
  the pick where it was.
- **The ticket's line**: `#1196 sections breathe · ◐ building 12m · arena · t1196-… · step 2 of
  ◆ #1193`.
- **What it needs from you**: its open ask or check as one row, with `⏎ answer`. This is the same
  item as in Needs you, not a copy, and answering it here answers it there. With nothing open it
  reads `needs you: nothing`, dim.
- **The pane and a side panel** that fits the ticket's kind:
  - a **build** ticket shows its branch's changes against main (#1149's diff);
  - a **plan** ticket (label `plan`) shows its epic's steps as they are filed and changed, one row
    each with its state word, read from the board;
  - a session with **no ticket** has no panel, and the pane takes the width.

  The panel never shows another repo's git log, and the strip's `changes` column is never drawn
  here.

**A session takes the room left of the drawer,** not the 100-cell column. A Claude's pane needs
about 120 cells and its panel about 90, and Doing is one `esc` away. The head stays, with its `▲ N`.
At half width the panel doesn't fit beside the pane, so `d` turns the column between the pane and
the panel.

### A plan, at 220 × 51

#1194 planned epic #1193 and waits on ask #59.

```
 ◆ [doing]  planning     all · [Ficciones] · aleph · asterion      / find                                                                                      ◐ auto 4/8   ⌸ 5 Claudes   ◆ orch 12s   ✓ 23 today   ▲ 3   ≡
┌─ ◆ doing › Ficciones › ◆ #1193 the meta first › #1194 plan ────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────── × ─┐
│ #1194 plan · ◐ doing 27m · no repo · plans ◆ #1193                                                                                                                                                                       │
│ ▲ ask #59: does epic #1193 look right?                                                                                                                                                                          ⏎ answer │
├─────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────┬────────────────────────────────────────────────────────────────────────────────────────────────┤
│ ● file_ticket  #1209 all and per-project views                                                                          │ steps of #1193 · 19 · 3 landed                                                                 │
│   ⎿ filed #1209 in epic #1193, backlog                                                                                  │                                                                                                │
│ ● link_tickets  #1209 blocked_by #1199                                                                                  │ ◐ building    #1196  sections breathe                                                          │
│   ⎿ linked                                                                                                              │ ◐ building    #1207  projects in babylon                                                       │
│ ● update_ticket  #1200                                                                                                  │ ◒ reviewing   #1206  next says why it waits                                                    │
│   ⎿ body rewritten: built per project from the start                                                                    │ · up next     #1198  a picked row opens                                                        │
│ ● ask_human  #1193  "Does the epic look right?"                                                                         │ ○ todo        #1192  the departures board                                                      │
│   ⎿ ask #59 open, on the board                                                                                          │ ○ todo        #1199  Doing's three sections                                                    │
│                                                                                                                         │ ○ todo        #1209  all or one project                                                        │
│   Waiting on your answer to ask #59.                                                                                    │ ○ todo        #1200  Planning per project                                                      │
│                                                                                                                         │ ✎ new         #1222  principles to ficciones                                                   │
│ > █                                                                                                                     │ …                                                                                              │
│                                                                                                                         │                                                                                                │
│                                                                                                                         │                                                                                                │
│                                                                                                                         │                                                                                                │
│                                                                                                                         │                                                                                                │
│                                                                                                                         │                                                                                                │
│                                                                                                                         │                                                                                                │
│                                                                                                                         │                                                                                                │
│                                                                                                                         │                                                                                                │
│                                                                                                                         │                                                                                                │
│                                                                                                                         │                                                                                                │
│                                                                                                                         │                                                                                                │
│                                                                                                                         │                                                                                                │
│                                                                                                                         │                                                                                                │
│                                                                                                                         │                                                                                                │
│                                                                                                                         │                                                                                                │
│                                                                                                                         │                                                                                                │
│                                                                                                                         │                                                                                                │
│                                                                                                                         │                                                                                                │
│                                                                                                                         │                                                                                                │
│                                                                                                                         │                                                                                                │
│                                                                                                                         │                                                                                                │
│                                                                                                                         │                                                                                                │
│                                                                                                                         │                                                                                                │
│                                                                                                                         │                                                                                                │
│                                                                                                                         │                                                                                                │
│                                                                                                                         │                                                                                                │
│                                                                                                                         │                                                                                                │
│                                                                                                                         │                                                                                                │
│                                                                                                                         │                                                                                                │
│                                                                                                                         │                                                                                                │
│                                                                                                                         │                                                                                                │
│                                                                                                                         │                                                                                                │
└─────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────┴────────────────────────────────────────────────────────────────────────────────────────────────┘
 NORMAL  ⏎ answer  i type  space card   │   esc back  click the path to go up  tab planning   │                                                                                                                      ? keys
```

### A plan, at 110 × 51

```
 ◆ [doing]  planning   all · [Ficciones] · aleph · asterion                                ◐ 4/8  ⌸ 5  ▲ 3  ≡
┌─ ◆ doing › Ficciones › ◆ #1193 the meta first › #1194 plan ──────────────────────────────────────────── × ─┐
│ #1194 plan · ◐ doing 27m · no repo · plans ◆ #1193                                                         │
│ ▲ ask #59: does epic #1193 look right?                                                            ⏎ answer │
├────────────────────────────────────────────────────────────────────────────────────────────────────────────┤
│ ● file_ticket  #1209 all and per-project views                                                             │
│   ⎿ filed #1209 in epic #1193, backlog                                                                     │
│ ● link_tickets  #1209 blocked_by #1199                                                                     │
│   ⎿ linked                                                                                                 │
│ ● update_ticket  #1200                                                                                     │
│   ⎿ body rewritten: built per project from the start                                                       │
│ ● ask_human  #1193  "Does the epic look right?"                                                            │
│   ⎿ ask #59 open, on the board                                                                             │
│                                                                                                            │
│   Waiting on your answer to ask #59.                                                                       │
│                                                                                                            │
│ > █                                                                                                        │
│                                                                                                            │
│                                                                                                            │
│                                                                                                            │
│                                                                                                            │
│                                                                                                            │
│                                                                                                            │
│                                                                                                            │
│                                                                                                            │
│                                                                                                            │
│                                                                                                            │
│                                                                                                            │
│                                                                                                            │
│                                                                                                            │
│                                                                                                            │
│                                                                                                            │
│                                                                                                            │
│                                                                                                            │
│                                                                                                            │
│                                                                                                            │
│                                                                                                            │
│                                                                                                            │
│                                                                                                            │
│                                                                                                            │
│                                                                                                            │
│                                                                                                            │
│                                                                                                            │
│                                                                                                            │
│                                                                                                            │
│                                                                                                            │
│                                                                                                            │
│                                                                                                            │
│                                                                                                            │
└────────────────────────────────────────────────────────────────────────────────────────────────────────────┘
 NORMAL  ⏎ answer  i type  d steps  │  esc back │                                                      ? keys
```

### A build, at 220 × 51

```
 ◆ [doing]  planning     all · [Ficciones] · aleph · asterion      / find                                                                                      ◐ auto 4/8   ⌸ 5 Claudes   ◆ orch 12s   ✓ 23 today   ▲ 3   ≡
┌─ ◆ doing › Ficciones › ◆ #1193 the meta first › #1196 sections breathe ────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────── × ─┐
│ #1196 sections breathe · ◐ building 12m · arena · t1196-sections-breathe · step 2 of ◆ #1193                                                                                                                             │
│ needs you: nothing                                                                                                                                                                                                       │
├─────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────┬────────────────────────────────────────────────────────────────────────────────────────────────┤
│ ● Update(src/plan.zig)                                                                                                  │ changes · against main · 2 files +31 −9                                                        │
│   ⎿ Updated src/plan.zig with 9 additions and 3 removals                                                                │                                                                                                │
│ ● Bash(menard run test src/plan.zig)                                                                                    │ src/plan.zig                       +27 −8                                                      │
│   ⎿ {"ok":true,"tests":412,"failures":[]}                                                                               │ @@ -94,7 +94,10 @@ pub fn slot(                                                                │
│                                                                                                                         │ -    const top = move_h + drive_h;                                                             │
│   Now the frames: one blank row between windows.                                                                        │ +    const top = move_h + gap + drive_h + gap;                                                 │
│                                                                                                                         │ src/draw.zig                        +4 −1                                                      │
│ > █                                                                                                                     │ …                                                                                              │
│                                                                                                                         │                                                                                                │
│                                                                                                                         │                                                                                                │
│                                                                                                                         │                                                                                                │
│                                                                                                                         │                                                                                                │
│                                                                                                                         │                                                                                                │
│                                                                                                                         │                                                                                                │
│                                                                                                                         │                                                                                                │
│                                                                                                                         │                                                                                                │
│                                                                                                                         │                                                                                                │
│                                                                                                                         │                                                                                                │
│                                                                                                                         │                                                                                                │
│                                                                                                                         │                                                                                                │
│                                                                                                                         │                                                                                                │
│                                                                                                                         │                                                                                                │
│                                                                                                                         │                                                                                                │
│                                                                                                                         │                                                                                                │
│                                                                                                                         │                                                                                                │
│                                                                                                                         │                                                                                                │
│                                                                                                                         │                                                                                                │
│                                                                                                                         │                                                                                                │
│                                                                                                                         │                                                                                                │
│                                                                                                                         │                                                                                                │
│                                                                                                                         │                                                                                                │
│                                                                                                                         │                                                                                                │
│                                                                                                                         │                                                                                                │
│                                                                                                                         │                                                                                                │
│                                                                                                                         │                                                                                                │
│                                                                                                                         │                                                                                                │
│                                                                                                                         │                                                                                                │
│                                                                                                                         │                                                                                                │
│                                                                                                                         │                                                                                                │
│                                                                                                                         │                                                                                                │
│                                                                                                                         │                                                                                                │
│                                                                                                                         │                                                                                                │
│                                                                                                                         │                                                                                                │
│                                                                                                                         │                                                                                                │
└─────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────┴────────────────────────────────────────────────────────────────────────────────────────────────┘
 NORMAL  i type  d changes whole  space card   │   esc back  click the path to go up  tab planning   │                                                                                                               ? keys
```

### A build, at 110 × 51

```
 ◆ [doing]  planning   all · [Ficciones] · aleph · asterion                                ◐ 4/8  ⌸ 5  ▲ 3  ≡
┌─ ◆ doing › Ficciones › ◆ #1193 the meta first › #1196 sections breathe ──────────────────────────────── × ─┐
│ #1196 sections breathe · ◐ building 12m · arena · t1196-sections-breathe · step 2 of ◆ #1193               │
│ needs you: nothing                                                                                         │
├────────────────────────────────────────────────────────────────────────────────────────────────────────────┤
│ ● Update(src/plan.zig)                                                                                     │
│   ⎿ Updated src/plan.zig with 9 additions and 3 removals                                                   │
│ ● Bash(menard run test src/plan.zig)                                                                       │
│   ⎿ {"ok":true,"tests":412,"failures":[]}                                                                  │
│                                                                                                            │
│   Now the frames: one blank row between windows.                                                           │
│                                                                                                            │
│ > █                                                                                                        │
│                                                                                                            │
│                                                                                                            │
│                                                                                                            │
│                                                                                                            │
│                                                                                                            │
│                                                                                                            │
│                                                                                                            │
│                                                                                                            │
│                                                                                                            │
│                                                                                                            │
│                                                                                                            │
│                                                                                                            │
│                                                                                                            │
│                                                                                                            │
│                                                                                                            │
│                                                                                                            │
│                                                                                                            │
│                                                                                                            │
│                                                                                                            │
│                                                                                                            │
│                                                                                                            │
│                                                                                                            │
│                                                                                                            │
│                                                                                                            │
│                                                                                                            │
│                                                                                                            │
│                                                                                                            │
│                                                                                                            │
│                                                                                                            │
│                                                                                                            │
│                                                                                                            │
│                                                                                                            │
│                                                                                                            │
│                                                                                                            │
│                                                                                                            │
│                                                                                                            │
└────────────────────────────────────────────────────────────────────────────────────────────────────────────┘
 NORMAL  i type  d changes  space card  │  esc back │                                                  ? keys
```

**Keys.** It opens in normal mode, for watching, as #1149 built it. `i` types into the pane, and
while typing `esc` is the pane's. `Ctrl+Space` gives normal mode back, and then `esc` goes back.
`⏎` answers the open ask. `d` turns the panel to the whole width and back (at half width, it turns
between pane and panel). `space` opens the ticket's card.

## Projects and settings

### Projects

A project is a name, a set of repos and a home repo (#1207). Each repo is in at most one project.
A repo in none is a project of its own, named after it, so nothing changes before a project is
made. The shop is the project **Ficciones** (ficciones, arena, babylon, menard), homed in
ficciones. aleph and asterion are projects of their own. Each project drives its own goal.

- **The head's picker** reads `all · Ficciones · aleph · asterion`, in place of the repo chips.
  The pick wears the accent box (drawn `[ ]`). Each label has a fixed width and is cut with `…`, so
  the head doesn't move when the pick does (principle 10).
- `r` moves the pick to the next project, and after the last back to `all`. A click picks one.
- The pick holds across Doing and Planning, as the repo filter does today.
- `arena show --project P` opens with it picked (principle 7).
- No goal's repo chips stay inside no goal, narrowed to the project's repos.

### Settings, in three layers

Settings live where they are seen. There is no preferences screen (#1208).

| layer | keys | where it is seen |
| --- | --- | --- |
| **global** (this machine) | `auto` (the master switch), `cap`, `hold`, the digest's time, the orchestrator on or off | the head's `◐ auto 4/8`, and the settings card on `all` |
| **project** | `auto`, `cap` (its share), `hold`, `model` | its row in Projects, Heading for's auto word, and its settings card |
| **repo** | `cap`, `model` | its project's settings card |

A lower layer only narrows. A project's auto runs only while global auto is on, its cap is within
the global cap, and a global hold holds everything. Every value says where it came from: `set
here`, `from project`, `from global` or `default`.

**The settings card.** `,` opens it in the middle column for the head's scope: on `all` the global
layer, and on a project that project's. It replaces auto's modal (`A`), which goes.

```
┌─ ◆ settings · Ficciones ───────────────────────────────────────────────────────────────────── × ─┐
│ Ficciones · ficciones, arena, babylon, menard · home ficciones                                   │
│                                                                                                  │
│ project                                                                                          │
│ ▌auto         on          set here                                                               │
│  cap          4           set here · global 8                                                    │
│  hold         off         from global                                                            │
│  model        sonnet      set here · default opus                                                │
│                                                                                                  │
│ repos         cap                      model                                                     │
│  arena        1     set here           sonnet   from project                                     │
│  babylon      4     from project       opus     set here                                         │
│  ficciones    4     from project       sonnet   from project                                     │
│  menard       1     set here           sonnet   from project                                     │
│                                                                                                  │
│ ⏎ turn it   x inherit   j k pick   esc back                                                      │
│                                                                                                  │
│                                                                                                  │
│                                                                                                  │
└──────────────────────────────────────────────────────────────────────────────────────────────────┘
```

On `all`:

```
┌─ ◆ settings · all ─────────────────────────────────────────────────────────────────────────── × ─┐
│ global · this machine                                                                            │
│                                                                                                  │
│ ▌auto         on          set here                                                               │
│  cap          8           set here                                                               │
│  hold         off         default                                                                │
│  digest       09:00       default                                                                │
│  orchestrator on          set here                                                               │
│                                                                                                  │
│ projects           auto        cap   hold                                                        │
│  Ficciones         on          4     off                                                         │
│  aleph             off         —     off                                                         │
│  asterion          inherit     —     off                                                         │
│                                                                                                  │
│ ⏎ turn it   x default   ⏎ on a project opens its card   esc back                                 │
│                                                                                                  │
│                                                                                                  │
└──────────────────────────────────────────────────────────────────────────────────────────────────┘
```

`j`/`k` pick a row. `⏎` turns a yes-or-no value, or opens a one-line field for a number or a model
(principle 11's short field). `x` sets it back to inherit (or to the default, on the global layer).
Each change runs `babylon set [--project P | --repo R] KEY VALUE` (principle 7). The card redraws
from the next board read, not before.

**On a project's row in Projects**, `a` turns its auto on or off and `p` holds it or lets it go.
They run the same `babylon set`, and the row's word changes on the next board read. `p` is for
pause. `h` would read as "hold", but `h` and `l` move between windows (principle 2).

The head's `◐ auto` cell stays the global switch, as today.

## Every key and click

Each screen's foot bar shows the keys for what is picked, and `?` lists all of them (principle 1).
Keys not named here are unchanged.

**On Doing and Planning both:**

| key | click | does |
| --- | --- | --- |
| `j` `k` | a row | pick. A picked row opens in place |
| `h` `l` | | window to window |
| `tab` `shift+tab` | `doing` / `planning` in the head | switch screens |
| `r` | a project's name in the head | the next project, or `all` after the last |
| `space` | a click on the picked row | open the picked thing whole in the middle column |
| `c` | `⌸ N Claudes` in the head | the Claudes list in the middle column |
| `,` | | the settings card for the head's scope |
| `/` | | find |
| `o` | `◆ orch` in the head | the orchestrator's drawer |
| `?` | | every key |
| `esc` `q` | `×` | back one step: close what is open, then clear find, then close arena's home |

**On Doing:**

| where | key | does |
| --- | --- | --- |
| Needs you | as today: `y` `n` `o` on a check, an ask's options, `⏎` | act on the item where it stands |
| Needs you, a stuck item | `⏎` | its pane in the middle column |
| Heading for | `space` | the goal's card |
| Heading for | `⏎` | Planning, with the pick on the goal |
| Projects | `⏎` | narrow to that project |
| Projects | `space` | its goal's card |
| Projects | `a` / `p` | its auto / its hold |
| the board | `⏎`, `H`, `g`, `G` | by the row's state, as [the board](#the-board) gives them |

**On Planning:** as [Doing and Planning](doing-planning.md#every-move-on-planning) gives them,
except `z`, which goes, and `d` and `+`, as [Planning's moves](#plannings-moves) say.

**In the middle column:** a goal's card, a ticket's card and the Claudes list take `j` `k`, `⏎`
and `esc`, and each card's buttons show their key. A session takes `i`, `d`, `⏎ answer`,
`space`, `Ctrl+Space` and `esc`. The settings card takes `j` `k`, `⏎`, `x` and `esc`.

## What leaves, and where it went

| what | today | goes to |
| --- | --- | --- |
| **in flight** | a window on Doing | its tickets are the board's moving rows, and its Claudes are in the Claudes list (`c`) |
| **other Claudes** | the foot of in flight | the Claudes list, under `no ticket` |
| **next** on Doing | a window on Doing | the board's up-next rows. Next stays a window on Planning |
| **landed** | a window on Doing | the board's top, above `now`. `✓ N today` stays in the head |
| **driving towards** | one row | Heading for (one project) or Projects (on `all`). Its chain peek goes, replaced by `◆` |
| **Your move**'s title | `your move` | `needs you`, everywhere it is said, `?` included |
| **`z`**, a goal's fold | Planning | the open goal follows the pick |
| **the repo filter's chips** | the head | the project picker. No goal keeps its chips |
| **auto's modal** (`A`) | over Doing | the settings card (`,`) |
| **the strip's `changes` column** beside a session | #1149 removed it for the column | the session's side panel, its own ticket's only |
| the second chips on rows | pin, priority, `next K`, the held chip | the opened row, or the Claudes list |

## What babylon gives the screens

The screens draw only what board.json says. These are what #1206–#1208 add to it:

- **`plan.next[].held`** (#1206): `{why, by}` per next row, from the same rules auto starts by:
  `null`, `blocked`, `overlap`, `repo cap`, `cap`, `off`, `starting`, and with #1208 `project held`,
  `project off` and `project cap`. It gives the board its wait words. arena never works them out
  again.
- **`projects[]`** (#1207): `{name, repos, home, driving, goal: {id, title, landed, total}}`, the
  one-repo projects with open work included, and **`project`** on each ticket. It gives the head's
  picker, Projects, Heading for per project, and Planning's grouping.
- **settings with sources** (#1208): each `projects[]` entry carries its effective settings as
  `{key: {value, source}}`, and the global ones come the same way. It gives the settings card, and
  the auto word on Projects and Heading for. `babylon set [--project P | --repo R] KEY
  VALUE|inherit` writes them, and `babylon settings` prints them.

The rest is on the board already: stalled tickets for the stuck item, an epic's steps for a plan
session's panel, and a ticket's open ask for a session's needs-you row.

## Where this differs from the tickets

The human's go on this page settles these. Each ticket's body is rewritten to match.

1. **Rows carry the short name** (#1192). The sketch had none.
2. **Frames stay**, one blank row apart (#1196). The sketch had bare headings.
3. **A project row doesn't open in place** (#1209). `⏎` narrows to the project.
4. **Hold on a project row is `p`, not `h`** (#1210), since `h` moves between windows.
5. **`⏎` on an up-next row starts it**, as today (#1192 had it open the card).
6. **The settings card replaces auto's modal**, and `A` goes (#1210).
7. **A session takes the room left of the drawer**, not the 100-cell column (#1211).
8. **When the pick leaves goals, the goal it was on stays open** (#1200).
9. **The Claudes list is `arena claudes`** (#1192 had `arena sessions`), to match its title and
   `⌸ N Claudes`.

## The build

Each step lands on its own and leaves both screens working. The `blocks` links hold this order.

1. **This doc** (#1195).
2. **babylon, alongside the screens:**
   - #1206 next rows say why they wait (`lib/babylon/auto.ex`, `plan_next.ex`, `board.ex`), then
     arena's #1191 draws the word (`src/board.zig`, `src/win_next.zig`);
   - #1207 projects (`lib/babylon/projects.ex`, a migration, `driving.ex`, `orchestrator*.ex`,
     `board.ex`, `bin/babylon`, `mcp/`), then #1208 the settings layers (`settings.ex`, a
     migration, `auto.ex`, `pipeline.ex`, `board.ex`, `bin/babylon`, `mcp/`).
3. **#1196 sections breathe**: the blank rows, the title colours, the second chips dropped.
   `src/plan.zig` (`slot`, `stacked`), `src/draw.zig`, `src/win_next.zig`, `src/win_unplanned.zig`,
   `src/win_backlog.zig`, `src/win_goals.zig`, `src/mock.zig`.
4. **#1198 a picked row opens**, after #1172: one `detail()` per window in place of `wrapRest`.
   `src/app.zig`, `src/win_now.zig`, `src/win_next.zig`, `src/win_landed.zig`, `src/win_goals.zig`.
5. **#1192 the board**, after #1191 and #1149: `Window.board` and `src/win_board.zig`, the Claudes
   list and `arena claudes`. `src/plan.zig`, `src/win_board.zig`, `src/win_now.zig`, `src/draw.zig`,
   `src/app.zig`, `src/main.zig`, `src/mock.zig`.
6. **#1199 Doing's three sections**: `needs you`, `heading for`, the stuck item. `src/plan.zig`,
   `src/win_driving.zig`, `src/win_move.zig`, `src/board.zig`, `src/app.zig`, `src/mock.zig`.
7. **#1209 all or one project**, after #1207: the picker, Projects, `arena show --project`.
   `src/board.zig`, `src/draw.zig`, `src/win_driving.zig`, `src/win_board.zig`, `src/win_move.zig`,
   `src/app.zig`, `src/main.zig`, `src/mock.zig`.
8. **#1200 Planning per project**: goals as headings, the open goal follows the pick, `z` goes.
   `src/plan.zig`, `src/win_goals.zig`, `src/win_unplanned.zig`, `src/win_backlog.zig`,
   `src/app.zig`, `src/mock.zig`.
9. **#1210 the settings card**, after #1208: `,`, `a` and `p` on Projects, `A` goes. `src/app.zig`,
   a new `src/win_settings.zig`, `src/win_driving.zig`, `src/board.zig`, `src/mock.zig`.
10. **#1211 a session says what it is for**, after #1199: the path, the ticket's line, its ask,
    and the side panel. `src/app.zig`, `src/draw.zig`, the column's file from #1149,
    `src/board.zig`, `src/mock.zig`.
11. **#1174 cards that read well**, alongside, after #1172: `src/win_modal.zig`, `src/app.zig`.
12. **Low, later:** #1202 the Zig game starter, then #1203 `babylon project new`, then #1205
    `+ a new project`. #1204 (a new project's plan starts with docs/what-it-is.md) stands alone.
    #1222 moves the principles to ficciones once this page has landed, and #1223 has every Claude
    read its project's rules.

`src/app.zig` is touched by most arena steps, and `src/plan.zig` by #1196, #1192, #1199 and #1200.
The chain runs them one at a time.
