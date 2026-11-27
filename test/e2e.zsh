#!/usr/bin/env zsh
# arena end to end: it runs in one private tmux server, standing in for the terminal, against
# sessions in another. Nothing here touches the tmux server or the configuration of whoever runs it.
zmodload zsh/zselect zsh/datetime

root=${0:A:h:h}
bin=$root/zig-out/bin/arena
in=arena-e2e-in-$$
out=arena-e2e-out-$$
tmp=$(mktemp -d)
fails=0
# stands in for the browser the menu opens: it says it ran, and stays until a line is typed
mkdir $tmp/bin
print -r -- $'#!/bin/sh\necho browser-stub $TERMINAL_BROWSER_START_PAGE "$@"\nread _' >$tmp/bin/terminal-browser
chmod +x $tmp/bin/terminal-browser
# stands in for the primary selection
print -r -- $'#!/bin/sh\nprintf primary-paste-text' >$tmp/bin/wl-paste
chmod +x $tmp/bin/wl-paste
# stands in for the Claude the hook asks for a topic: it names the requests it was handed
print -r -- $'#!/bin/sh\necho "$TMUX_PANE" >'$tmp$'/asked-pane\ncat >'$tmp$'/asked\necho \'"Topic From* Haiku"\'' >$tmp/bin/claude
chmod +x $tmp/bin/claude
print -r -- $'#!/bin/sh\nprintf "%s|" "$@" >>'$tmp$'/notified\necho >>'$tmp$'/notified' >$tmp/bin/notify-send
chmod +x $tmp/bin/notify-send
# stands in for babylon's command line: it says what the board answered
print -r -- $'#!/bin/sh\necho "$@" >>'$tmp$'/babylon\n[ "$1" = answer ] && [ -e '$tmp$'/refuse ] && { echo "babylon: no session to answer" >&2; exit 1; }\n[ "$1" = give ] && [ -e '$tmp$'/refuse ] && { echo "babylon: the Claude in $3 is mid-turn" >&2; exit 1; }\n[ "$1" = start ] && [ -e '$tmp$'/refuse-start ] && { echo "babylon: ticket #$2 is claimed by pane %1010" >&2; exit 1; }\n[ "$1" = next ] && [ -e '$tmp$'/refuse-next ] && { echo "babylon: ticket #$2 is claimed by pane %1010" >&2; exit 1; }\n[ "$1" = detail ] && printf \'#%s Lights\\n\\nthe whole of it\\n\' "$2"\n[ "$1" = gate ] && printf \'run submitted 2026-11-24T05:00:00Z\\n  rebase: ok (2026-11-24T05:00:01Z to 2026-11-24T05:00:05Z)\\n  gate: failed (2026-11-24T05:00:05Z to 2026-11-24T05:02:03Z)\\n    expected 1, found 0\\n\'\n[ "$1" = auto ] && [ -e '$tmp$'/chatty ] && { echo "babylon: auto chatter"; echo "babylon: auto chatter on stderr" >&2; }\nexit 0' >$tmp/bin/babylon
chmod +x $tmp/bin/babylon
# stands in for meatcheck: it records what it was asked and prints the comments it was given
print -r -- $'#!/bin/sh\necho "$@" >>'$tmp$'/meatcheck\n[ -e '$tmp$'/comments ] && cat '$tmp$'/comments\nexit 0' >$tmp/bin/meatcheck
chmod +x $tmp/bin/meatcheck
print -r -- $'#!/bin/sh\n[ "$1" = diff ] || exec '${commands[git]}$' "$@"\necho "$@" >>'$tmp$'/git' >$tmp/bin/git
chmod +x $tmp/bin/git
mkdir -p $tmp/projects/arena
export PATH=$tmp/bin:$PATH

inner() { tmux -L $in -f /dev/null "$@" }
outer() { tmux -L $out -f /dev/null "$@" }
# kill-server leaves the socket file behind
cleanup() {
  # a group kill that repeats its TERM would end this, or its kill-server client, half done
  trap '' HUP INT TERM
  [[ -n $server ]] && kill -CONT $server 2>/dev/null
  # the outer server first: an arena still starting in its pane would otherwise run its
  # `new-session -A` against the killed inner server and start a fresh one that outlives the run
  [[ -n $outer_pid ]] && kill $outer_pid 2>/dev/null
  outer kill-server 2>/dev/null
  [[ -n $inner_pid ]] && kill $inner_pid 2>/dev/null
  inner kill-server 2>/dev/null
  rm -f ${TMUX_TMPDIR:-/tmp}/tmux-$UID/{$in,$out}
  rm -rf $tmp
}
trap cleanup EXIT
# zsh runs the EXIT trap on an exit, not on a signal that kills it
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM
# a run killed outright cleaned nothing up: its servers go once its pid has
for stale in ${TMUX_TMPDIR:-/tmp}/tmux-$UID/arena-e2e-(in|out)-<->(N); do
  kill -0 ${stale##*-} 2>/dev/null && continue
  tmux -L ${stale:t} kill-server 2>/dev/null
  rm -f $stale
done

screen() { outer capture-pane -p -t o }
# what the hook names this checkout's branch: babylon's gate runs on a detached one
worked_on() {
  local b=$(git -C $root branch --show-current)
  print -r -- ${b:-detached $(git -C $root rev-parse --short HEAD)}
}
key() { outer send-keys -t o "$@" }
# button, column and row from 1, then M to press or move and m to let go. A spot not found on the
# screen is no cell: arena would take the broken report for typing and pass it to the pane.
mouse() {
  [[ $2 == <1-> && $3 == <1-> ]] || { fail "a mouse report at no cell: $*"; return 1 }
  outer send-keys -t o -l $'\e'"[<$1;$2;$3$4"
}
# a press and its let go on one cell, read once: read again after the press, it can land on the
# press's redraw
click() { mouse 0 $1 $2 M && mouse 0 $1 $2 m }

# Up to ten seconds for a command to succeed: babylon runs the gate on a busy machine.
poll() {
  local i
  for i in {1..200}; do
    "$@" && return 0
    zselect -t 5
  done
  return 1
}
# A wait outside a check that times out fails the run too: what came after it ran on a screen it
# did not expect, so its own failures would name the wrong cause.
await() {
  poll "$@" && return 0
  ((checking)) || fail "waited for: $*"
  return 1
}
shows() { screen | grep -qE -- "$1" }
# A capture can land mid-frame, with a row not yet drawn: what is gone is judged once two captures
# a tenth of a second apart agree.
settled() {
  local was now=$(screen) i
  for i in {1..30}; do
    was=$now
    zselect -t 10
    now=$(screen)
    [[ $now == "$was" ]] && break
  done
  print -r -- "$now"
}
hides() { ! settled | grep -qE -- "$1" }
see() { await shows "$1" }
normal() { shows "^NORMAL" || key C-Space; see "^NORMAL" }
gone() { await hides "$1" }

fail() {
  print "FAIL  $1"
  screen | sed 's/^/      | /'
  fails=$((fails + 1))
}
checking=0
check() {
  local name=$1 passed=0
  shift
  checking=1
  "$@" && passed=1
  checking=0
  if ((passed)); then print "ok    $name"; else fail "$name"; fi
}

# the checks read sh's own prompt, not one handed down
unset PS1
inner new-session -d -s alpha -n one -x 100 -y 30 sh
inner_pid=$(inner display -p '#{pid}')
inner set -g default-command sh
inner new-window -t alpha -n two sh
inner new-window -t alpha -n three sh
inner new-session -d -s beta -n solo sh
inner select-window -t alpha:one

# An empty HOME: no machine palette, so colours are the fallback ones. No motion: no slides to wait out.
outer new-session -d -s o -x 121 -y 24 \
  "env -u TMUX HOME=$tmp XDG_RUNTIME_DIR=$tmp/run ARENA_REDUCED_MOTION=1 ARENA_LOOK_MS=2000 $bin -L $in alpha 2>$tmp/err; echo EXIT \$?; cat"
outer set -s set-clipboard on
# o is restarted below: with o its only session, the server would exit, and a new-session close
# behind can land on it as it goes and be lost with it
outer set -s exit-empty off
outer_pid=$(outer display -p '#{pid}')
# what arena writes, for what a picture of the screen does not show
outer pipe-pane -t o "cat >$tmp/raw"

check "the strip shows, its first column at the screen's left edge" see '^╭─ 1 one '
dots() { local s=$(screen); [[ $(sed -n 23p <<<$s) == *[╰╯]* && $(sed -n 24p <<<$s) =~ "[^ ]+ +$1 │ s go to  ≡" ]] }
check "a row of its own under the strip has a dot per window, centred on it" await dots '●○○'
# the column, from 1, where $1 starts on the screen's last row
col() { local l=$(settled | sed -n 24p); local pre=${l%%$1*}; print $(( ${#pre} + 1 )) }
mouse 35 100 24 M
check "the pointer on it has each window's number and name in place of its dot" see '^ +1 one +2 two +3 three *$'
x=$(col '2 two')
mouse 0 $x 24 M
mouse 0 $x 24 m
key -l i
mouse 35 60 10 M
check "a click on a name goes to its window, and away from the row it is dots again" await dots '○●○'
mouse 35 100 24 M
see '1 one'
mouse 65 100 24 M
mouse 35 60 10 M
check "the wheel down on it goes to the next window" await dots '○○●'
zselect -t 50
mouse 35 100 24 M
mouse 65 100 24 M
mouse 35 60 10 M
check "and stops at the last" await dots '○○●'
mouse 35 100 24 M
see '1 one'
zselect -t 30
mouse 64 100 24 M
mouse 35 60 10 M
check "the wheel up, the one before" await dots '○●○'
mouse 35 100 24 M
see '1 one'
x=$(col '1 one')
mouse 0 $x 24 M
mouse 0 $x 24 m
key -l i
mouse 35 60 10 M
await dots '●○○'

# insert and normal: every key of a sentence is the pane's, or none is
typed() { [[ $(screen | grep -c -- "$1") -ge $2 ]] }
key -l 'echo jhklqnb'
key Enter
check "in insert a sentence with j h k l q n b reaches the pane whole" await typed 'jhklqnb' 2
key C-Space
check "Ctrl+Space is normal mode, NORMAL in the corner and its key in the dots' row" await shows '^NORMAL .*i insert'
key -l 'ytdfuvr'
zselect -t 50
check "in normal none of it reaches the pane, and q does not quit" hides 'ytdfuvr'
key -l i
check "i is insert again" gone '^NORMAL'
key -l 'echo back-in'
key Enter
check "and what is typed is the pane's" await typed 'back-in' 2
key C-Space
see '^NORMAL'
key Escape
check "Esc in normal is insert too" gone '^NORMAL'
key C-Space
see '^NORMAL'
mouse 0 60 10 M
mouse 0 60 10 m
check "a click on a pane is insert" gone '^NORMAL'

# j and k in normal mode step to the session below and above, and stay in normal
key C-Space
see '^NORMAL'
key -l j
check "in normal mode j goes to the next session" await shows '^╭─ 1 solo '
check "and the keys are written under the strip" await shows '^NORMAL .*j k session'
key -l k
check "k goes back" await shows '^╭─ 1 one '

# the switcher: s lists the Claudes, the sessions and + new session; Enter on a session goes there
key -l s
check "s opens the switcher" see '→ Go to'
check "it lists the sessions in tmux's order, then + new session" see "alpha +[0-9]+ windows?"
key -l j
key Enter
check "Enter on a session goes there, in insert" await shows '^╭─ 1 solo '
check "and the switcher is closed" gone '→ Go to'
key C-Space
see '^NORMAL'
key -l s
see '→ Go to'
key Escape
check "esc closes it" gone '→ Go to'
key C-Space
see '^NORMAL'
key -l /
check "/ in a pane view opens it too" see '→ Go to'
key Escape
key C-Space
see '^NORMAL'
key -l k
await shows '^╭─ 1 one '
key -l i

# A tmux with the pixels patch gives arena's terminal cells of 9x19 pixels, as a real one has.
mkfifo $tmp/sizer
outer -C attach -t o <$tmp/sizer >/dev/null 2>&1 &
exec {sizer}>$tmp/sizer
# tmux tells a pane its size again only when its cells change, so a cell's pixels come with one
print -u $sizer 'refresh-client -C 120x24,9x19'
print -u $sizer 'refresh-client -C 121x24,9x19'
outer_cells() { [[ $(outer display -p -t o '#{window_cell_width}') == 9 ]] }
cells() { [[ $(inner display -p -t alpha:one '#{window_cell_width}x#{window_cell_height}') == $1 ]] }
if poll outer_cells; then
  check "the terminal's cell size in pixels reaches the panes" await cells 9x19
else
  print "skip  the terminal's cell size in pixels reaches the panes: this tmux has no pixels patch"
fi

wrote_bytes() { grep -qaF -- "$1" $tmp/raw }
print -rn -- $'\ePtmux;\e\e_Ga=T,f=24,s=1,v=1,i=66051,U=1,q=2;AAAA\e\e\\\e\\\e[38;2;1;2;3m\U0010EEEE̅̅\e[m\n' >$tmp/picture
inner send-keys -t alpha:two "cat $tmp/picture" Enter
check "a picture a program wraps for tmux is passed on to the terminal" await wrote_bytes $'\e_Ga=T,f=24,s=1,v=1,i=66051,U=1,q=2;AAAA\e\\'
check "and its cells keep their colour in a window out of focus" await wrote_bytes $'\e[0;38;2;1;2;3m\U0010EEEE̅̅'
inner send-keys -t alpha:two clear Enter
gone $'\U0010EEEE'
big=${(l:100000::B:)}
print -rn -- $'\ePtmux;\e\e_Ga=T,f=100,i=66052,q=2;'$big$'\e\e\\\e\\' >$tmp/big
inner send-keys -t alpha:two "cat $tmp/big" Enter
check "one sent whole, past 64 KiB, too" await wrote_bytes $'\e_Ga=T,f=100,i=66052,q=2;'$big$'\e\\'
unleaked() { ! screen | grep -qF BBBBBBBB }
check "and none of it is text" unleaked
inner send-keys -t alpha:two clear Enter
kept() { ! grep -qaF -- $'\e[2J' $tmp/raw }
check "and no frame erases the whole display, which would take the pictures with it" kept
print -rn -- $'\ePtmux;\e\e_Gi=4207,a=q;AAAA\e\e\\\e\\' >$tmp/query
inner send-keys -t alpha:two "cat $tmp/query; head -c 14 | od -c" Enter
check "a graphics query is passed on too" await wrote_bytes $'\e_Gi=4207,a=q;AAAA\e\\'
key -l $'\e_Gi=4207;OK\e\\'
answered() { inner capture-pane -pJ -t alpha:two | grep -qF '_   G   i   =   4   2   0   7   ;   O   K' }
zselect -t 50
inner send-keys -t alpha:two C-d
check "and the terminal's answer goes to the pane that asked, not the one in focus" await answered
inner send-keys -t alpha:two clear Enter

key -l $'\e]10;rgb:ffff/b0b0/0000\e\\'
print -rn -- $'\e]10;?\e\\' >$tmp/fg
inner send-keys -t alpha:two "stty -echo -icanon; cat $tmp/fg; head -c 25 | od -c; stty sane" Enter
told() { inner capture-pane -pJ -t alpha:two | grep -qF 'b   0   /   0   0   0   0 033   \' }
check "a program asking for its foreground is told the terminal's, not tmux's black" await told
inner send-keys -t alpha:two clear Enter

print -rn -- $'\ekscreen-named\e\\after-name\n' >$tmp/named
inner send-keys -t alpha:two "cat $tmp/named" Enter
see '│after-name'
check "a window named as screen names one shows no name in the pane" hides 'screen-named'
inner send-keys -t alpha:two clear Enter

print -rn -- $'\e[?1000h\e[?1016h' >$tmp/pixels
inner send-keys -t alpha:one "stty -echo -icanon; cat $tmp/pixels; head -c 11 | od -c; printf '\\033[?1016l\\033[?1000l'; stty sane" Enter
await shows '^╭─ 1 one '
mousing() { [[ $(inner display -p -t $1 '#{mouse_standard_flag}') == 1 ]] }
await mousing alpha:one
# the pane's third column, second row: its frame starts at the title's corner
at=$(( $(settled | awk 'NR == 1 { print index($0, "╭─ 1 one") }') + 3 ))
mouse 0 $at 3 M
# the middle of the cell, in the window's cells, spelled as od spells it
cw=$(inner display -p -t alpha:one '#{window_cell_width}')
ch=$(inner display -p -t alpha:one '#{window_cell_height}')
report="<0;$((2 * cw + cw / 2));$((ch + ch / 2))M"
clicked() { inner capture-pane -pJ -t alpha:one | grep -qF -- "${(j:   :)${(s::)report}}" }
check "a click reaches a program that asked for pixels in pixels" await clicked
mouse 0 $at 3 m
inner send-keys -t alpha:one clear Enter

print -rn -- $'\e[?1000h\e[?1006h' >$tmp/clicks
inner send-keys -t alpha:two "stty -echo -icanon; cat $tmp/clicks; timeout 2 cat -v; printf '\\033[?1006l\\033[?1000l'; stty sane" Enter
await mousing alpha:two
# a capture taken mid-frame can lack the title, and index's 0 would click nothing
titled() { two=$(screen | awk 'NR == 1 { print index($0, "╭─ 2 two") }'); (( two > 0 )) }
check "window two's title is on the top line, to click under" await titled
two=$((two + 3))
mouse 0 $two 6 M
mouse 0 $two 6 m
current() { [[ $(inner display -p -t alpha '#{window_name}') == $1 ]] }
check "the click on window two makes it the current window" await current two
check "and the strip comes to rest on it" await dots '○●○'
zselect -t 50
untouched() { ! inner capture-pane -pJ -t alpha:two | grep -qF '[<0;' }
check "a click on a window out of focus focuses it, and its program is not clicked" untouched
check "window two shows its prompt" await shows '│sh-[0-9.]+\$ +│'
inner send-keys -t alpha:two clear Enter

print -rn -- $'\e[?1003h\e[?1006h' >$tmp/any
inner send-keys -t alpha:two "clear; stty -echo -icanon; echo shift-copy-target; cat $tmp/any; timeout 3 cat -v; printf '\\033[?1006l\\033[?1003l'; stty sane" Enter
check "window two shows the text to copy, whole" await shows 'shift-copy-target'
zselect -t 30
row=$(settled | grep -n 'shift-copy-target' | head -1 | cut -d: -f1)
col=$(settled | awk -v r=$row 'NR == r { print index($0, "shift-copy-target") }')
mouse 35 $((col + 2)) $((row + 1)) M
mouse 4 $col $row M
mouse 36 $((col + 16)) $row M
mouse 4 $((col + 16)) $row m
copied() { [[ $(outer show-buffer 2>/dev/null) == shift-copy-target ]] }
check "a shift drag over a program that took the mouse copies its text" await copied
zselect -t 350
unhovered() { ! inner capture-pane -pJ -t alpha:two | grep -qE '\[<(35|4|36);' }
check "and neither it nor the pointer moving over it reaches the program" unhovered
inner send-keys -t alpha:two clear Enter

inner send-keys -t alpha:two "clear; stty -echo -icanon; cat $tmp/any; timeout 3 cat -v; printf '\\033[?1006l\\033[?1003l'; stty sane" Enter
allmouse() { [[ $(inner display -p -t alpha:two '#{mouse_all_flag}') == 1 ]] }
await allmouse
mouse 1 $((col + 2)) $((row + 1)) M
mouse 1 $((col + 2)) $((row + 1)) m
pasted() { inner capture-pane -pJ -t alpha:two | grep -qF primary-paste-text }
check "a middle click pastes the primary selection, even into a program that took the mouse" await pasted
unclicked() { ! inner capture-pane -pJ -t alpha:two | grep -qF '[<1;' }
check "and the program is not sent the click" unclicked
zselect -t 350
inner send-keys -t alpha:two clear Enter
key M-h
see '^╭─ 1 one '

wide() { [[ $(inner display -p -t alpha:one '#{window_width} #{@arena_width}') == $1 ]] }
# a ; that ends an argument ends the command for tmux, unless escaped
key -l $'\e\\;'
check "Alt+; makes the window narrower" see '╭─ 1 one ─{73}╮'
check "and tmux has it that wide, and keeps the width" await wide '81 69'
key "M-'"
check "Alt+' makes it wider" see '╭─ 1 one ─{86}╮'

windows() { [[ $(inner list-windows -t $1 -F '#{window_name}' | tr '\n' ' ') == "$2 " ]] }
mouse 0 4 1 M
mouse 32 111 1 M
mouse 32 113 1 M
mouse 32 116 1 M
mouse 0 116 1 m
check "a title dropped on another column takes its place, and goes no further" await windows alpha 'two one three'
see '─╮ ╭─ 2 one '
mouse 0 22 1 M
mouse 32 2 1 M
mouse 0 2 1 m
check "and back" await windows alpha 'one two three'
see '^╭─ 1 one '

key M-l
check "Alt+l focuses the next window, its neighbour peeking" see '─╮ ╭─ 2 two ─'
key 'echo e2e-$((6*7))' Enter
check "typing reaches the focused pane" see 'e2e-42'
normal; key j; key -l i
check "normal j goes to the next session" see '╭─ 1 solo '
key M-k
check "Alt+k comes back, to the window left" see '╭─ 2 two '
inner new-window -d -t beta: -n second sh
server=$(inner display -p '#{pid}')
kill -STOP $server
normal; key j M-2
zselect -t 50
kill -CONT $server
beta_at() { [[ $(inner display -p -t beta: '#{window_name}') == $1 ]] }
check "Alt+2 typed before tmux has switched sessions selects the window of the session asked for" await beta_at second
key M-k
inner kill-window -t beta:second
# wheel 64 and 65 are up and down, 66 and 67 left and right
mouse 65 81 10 M
mouse 67 81 10 M
mouse 65 81 10 M
zselect -t 30
mouse 66 81 10 M
zselect -t 30
check "a sideways wheel among a swipe down is not a step, nor is one on its own" current two
repeat 3 mouse 66 81 10 M
check "three sideways the same way are a step" await current one
zselect -t 30
repeat 8 mouse 67 81 10 M
zselect -t 30
check "a swipe steps once however far it goes" await current two
key M-h
await current one
key M-l
see '╭─ 2 two '

inner send-keys -t beta:solo "clear; printf '%%end 1 1 1\\n%%begin 1 1 1\\n'" Enter
normal; key j; key -l i
see '╭─ 1 solo '
check "a pane showing lines like tmux's own replies is drawn whole" see '│%begin 1 1 1 '
key M-k
see '╭─ 2 two '

order() { [[ $(inner list-sessions -F '#{@arena_order}#{session_name}' | sort | tr -d '\n') == $1 ]] }
key M-J
check "Alt+J moves the session down, and its place is kept in tmux" await order 1beta2alpha
key M-K
check "Alt+K moves it up" await order 1alpha2beta

sessions() { [[ $(inner list-sessions | wc -l) -eq $1 ]] }
normal; key -l s
see '→ Go to'
key -l jj
key Enter
check "Enter on the switcher's + new session makes a session" await sessions 3
normal; key -l s
see '→ Go to'
key -l jj
key -l x
check "x on a session of the switcher asks before closing it" see 'Close session [0-9]+\?'
key y
check "and closes it" await sessions 2
key M-k
see '╭─ 2 two '

normal; key m
check "normal m opens the menu" see 'New window +n'
key Escape
check "Escape closes it" gone 'New window +n'

panes() { [[ $(inner list-panes -t alpha:two | wc -l) -eq $1 ]] }
normal; key m
key v
check "the menu splits the pane" await panes 2
check "and the split is drawn" see 'echo e2e.* │sh-[0-9.]+\$ +│'
wrote() { grep -q -- "$1" $tmp/raw }
first() { [[ $(inner list-panes -t alpha:two -F '#{pane_width}' | head -1) -eq $1 ]] }
mouse 35 61 5 M
check "over the line between panes the pointer is the one for resizing" await wrote $'\e]22;ew-resize'
mouse 0 61 5 M
mouse 32 54 5 M
mouse 0 54 5 m
check "dragging the line resizes the panes" await first 40

normal; key m
key r
key 'renamed' Enter
check "the menu renames the window" see '╭─ 2 renamed '

key 'cat -v' Enter
key M-p
key Enter
check "in insert, Alt+p reaches the pane: Claude Code's model picker is its own" see '\^\[p'
key C-c
normal; key /
check "in normal mode, / opens the jump prompt" see '→ Go to'
key 'sol'
check "and finds a Claude's window by its name" see '› solo'
key 'o' Enter
check "normal / jumps to a window of another session" see '╭─ 1 solo '

normal; key O
check "normal O shows every session's windows" see '╭─ 1 one ─+╮ ╭─ 2 renamed '
mouse 0 64 4 M
mouse 32 4 4 M
mouse 0 4 4 m
check "a picture dropped on another takes its place" await windows alpha 'three one renamed'
see '╭─ 1 three ─+╮ ╭─ 2 one '
mouse 0 4 4 M
mouse 32 64 4 M
mouse 0 64 4 m
check "and back" await windows alpha 'one renamed three'
see '╭─ 1 one ─+╮ ╭─ 2 renamed '
mouse 0 64 4 M
mouse 32 4 12 M
mouse 0 4 12 m
check "on one of another session, it goes there in front of it" await windows beta 'three solo'
see '╭─ 1 three ─+╮ ╭─ 2 solo '
mouse 0 4 12 M
mouse 32 74 4 M
mouse 0 74 4 m
check "and on the rest of a session's row, to that session's end" await windows alpha 'one renamed three'
see '╭─ 3 three '
key Escape
check "Escape leaves the overview" see '╭─ 1 solo ─{40}'

zselect -t 400
key 'printf "\033[%dGX\bY\n" $(tput cols)' Enter
check "a step back from the last column lands where tmux puts it" see ' Y│$'
normal; key k
key -l i

# arena's Claude Code hook, as Claude Code runs it in a pane of the session: event, then its JSON
claude() { print -r -- ${3:-'{}'} | TMUX="$(inner display -p '#{socket_path}'),0,0" TMUX_PANE=$1 sh $root/hooks/claude-state.sh $2 }
inner send-keys -t alpha:one 'echo news' Enter
zselect -t 250
check "output alone marks no window" await dots '○●○'
claude alpha:one prompt
check "a Claude working marks its window's dot ◐" await dots '◐●○'
claude alpha:one stop '{"background_tasks": [{"id": "b1", "status": "running"}]}'
check "between turns, with work in the background, ◔" await dots '◔●○'
claude alpha:one stop '{"last_assistant_message": "\"status\": \"running\"", "background_tasks": []}'
check "done and not looked at, ◉, whatever its last words say" await dots '◉●○'
claude alpha:three waiting
check "waiting on an answer, ▲, in another window's dot" await dots '◉●▲'
opt() { inner show -pqv -t alpha:one @arena_claude_$1 }
is_opt() { [[ $(opt $1) == $2 ]] }
claude alpha:one prompt $'{"prompt": "\\n  \\nfix the \\"rail\\"\\nand the rest"}'
check "the prompt's first line with words in it is kept" is_opt prompt 'fix the "rail"'
claude alpha:one tool '{"tool_name": "Bash", "tool_input": {"command": "mise run check\nand more"}}'
check "a command is the tool's first line" is_opt doing 'Bash mise run check'
since=$(opt since)
claude alpha:one tool '{"tool_name": "Edit", "tool_input": {"file_path": "/src/app.zig", "old_string": "a"}}'
check "a file is the tool's name of it" is_opt doing 'Edit app.zig'
check "still working, the time it began working stays" is_opt since $since
claude alpha:one tool '{"tool_name": "TodoWrite", "tool_input": {"todos": []}}'
check "a tool with nothing to name is its name" is_opt doing 'TodoWrite '
claude alpha:one waiting '{"message": "Claude needs your permission to use Bash"}'
check "waiting, what it waits for, in short" is_opt doing 'allow Bash'
stamped() { [[ -n $(opt since) && $(opt since) -le $(date +%s) ]] }
check "and when it began waiting" stamped
claude alpha:one tool "{\"tool_name\": \"Bash\", \"tool_input\": {\"command\": \"$(printf 'x%.0s' {1..100})\"}}"
check "the text is at most 80 characters" is_opt doing "Bash $(printf 'x%.0s' {1..75})"
claude alpha:one stop
check "a stop leaves the prompt" is_opt prompt 'fix the "rail"'
check "and nothing doing" is_opt doing ''
claude alpha:one prompt
claude alpha:one stopfailure '{"error": "rate_limit", "error_details": "You are out of usage credits.\nRun /usage-credits"}'
marked() { [[ $(inner show -pqv -t alpha:one @arena_claude) == stalled ]] }
check "a turn that ends on an API error is stalled, not working" marked
check "and says the error's first line" is_opt said 'You are out of usage credits.'
claude alpha:one end
claude alpha:three end
check "a session's end takes its mark off" await dots '○●○'
unset_all() { [[ -z $(inner show -p -t alpha:one | grep arena_claude) ]] }
check "and every option the hook set" unset_all
claude alpha:three waiting '{"message": "Claude needs your permission to use Bash"}'
claude alpha:one prompt '{"prompt": "go"}'
claude beta:solo tool '{"tool_name": "Read", "tool_input": {"file_path": "/a/b.zig"}}'
claude alpha:three end
claude alpha:one end
claude beta:solo end

transcript=$tmp/transcript.jsonl
{
  print -r -- '{"type":"ai-title","aiTitle":"Started Here"}'
  for p in one two; print -r -- '{"type":"user","message":{"content":"ask '$p'"}}'
  print -r -- '{"type":"user","message":{"content":[{"type":"tool_result","content":"no"}]}}'
  print -r -- '{"type":"user","message":{"content":"<command-name>/clear</command-name>"}}'
  print -r -- '{"type":"user","message":{"content":"This session is being continued from a previous conversation"}}'
  print -r -- '{"type":"queue-operation","operation":"enqueue","content":"ask three"}'
} >$transcript
said() { claude alpha:one $1 '{"prompt": "p", "transcript_path": "'$transcript'"}' }
titled() { [[ $(inner show -pqv -t alpha:one @arena_claude_title) == $1 ]] }
said prompt
check "a Claude is called by the title its conversation began with" titled 'Started Here'
repeat 4 said prompt
check "every fifth prompt Haiku is asked what it is about now" await titled 'Topic From Haiku'
asked() { [[ $(<$tmp/asked) == $'Began as: Started Here\nCalled now: Started Here\nLatest requests, oldest first:\nask one\nask two\nask three' && -z $(<$tmp/asked-pane) ]] }
check "from what was typed, sent while it worked too, with no pane for its own hooks to mark" asked
said stop
check "a stop keeps that topic" titled 'Topic From Haiku'
print -r -- '{"type":"custom-title","customTitle":"Named By Hand"}' >>$transcript
said stop
check "a conversation renamed is called by its name" titled 'Named By Hand'
rm $tmp/asked
repeat 5 said prompt
zselect -t 50
check "and Haiku is not asked again" [ ! -e $tmp/asked ]
print -r -- '{"type":"assistant","message":{"usage":{"input_tokens":4,"cache_read_input_tokens":253118,"cache_creation_input_tokens":68}}}' >>$transcript
claude alpha:one stop '{"last_assistant_message": "## **Done.** It loads\nmore", "cwd": "'$root'", "transcript_path": "'$transcript'",
  "background_tasks": [{"id": "a1", "type": "subagent", "status": "running", "description": "Explore the rail"},
    {"id": "b1", "type": "shell", "status": "running", "command": "sleep 9\nmore"}, {"id": "b0", "type": "shell", "status": "done", "command": "x"}]}'
check "a stop keeps the first line of its answer, plain" is_opt said 'Done. It loads'
check "its subagents still in the background" is_opt agents 'Explore the rail'
check "and the shells there" is_opt background '1 shell: sleep 9'
check "the context its last answer was given" is_opt tokens 253190
check "and the branch it works on" is_opt branch "$(worked_on | cut -c1-40)"
claude alpha:one tool '{"agent_id": "a1", "agent_type": "Explore", "tool_name": "Grep", "tool_input": {"pattern": "rail"}}'
check "a subagent's tool leaves the session as it was" [ "$(opt doing)" = '' -a "$(inner show -pqv -t alpha:one @arena_claude)" = background ]
check "and what runs as it was" [ "$(opt agents)" = 'Explore the rail' -a "$(opt background)" = '1 shell: sleep 9' ]
claude alpha:one prompt '{"prompt": "<task-notification>\n<task-id>b1</task-id>\n<status>completed</status>\n</task-notification>"}'
check "a shell's notice that it finished takes it off" [ "$(opt agents)" = 'Explore the rail' -a "$(opt background)" = '' ]
check "and is not taken for a prompt" is_opt prompt 'p'
claude alpha:one prompt '{"prompt": "<agent-message from=\"a1\">\ndone\n</agent-message>"}'
check "nor is a subagent's, which takes it off too" is_opt agents ''
claude alpha:one stop '{"last_assistant_message": "Waiting", "background_tasks": [{"id": "a4", "type": "subagent", "status": "waiting", "description": "Hug it"},
  {"id": "b4", "type": "shell", "status": "completed", "command": "x"}]}'
check "a subagent waiting on its own work at a stop is still what runs" is_opt agents 'Hug it'
check "and the session has work in the background" [ "$(inner show -pqv -t alpha:one @arena_claude)" = background ]
claude alpha:one prompt '{"prompt": "<agent-message from=\"a4\">\ndone\n</agent-message>"}'
claude alpha:one stop '{"last_assistant_message": "Waiting", "background_tasks": [{"id": "a5", "type": "subagent", "description": "No word"}]}'
check "one with no status is listed" is_opt agents 'No word'
check "and the session has it in the background too" [ "$(inner show -pqv -t alpha:one @arena_claude)" = background ]
claude alpha:one prompt '{"prompt": "<agent-message from=\"a5\">\ndone\n</agent-message>"}'
claude alpha:one tool '{"agent_id": "a2", "agent_type": "Plan", "tool_name": "Grep", "tool_input": {"pattern": "rail"}}'
check "with nothing running, a subagent's tool is shown as what runs" is_opt background 'agent Plan: Grep rail'
claude alpha:one tool '{"hook_event_name": "PostToolUse", "tool_name": "Bash", "tool_input": {"command": "sleep 9", "description": "Soak it"},
  "tool_response": {"backgroundTaskId": "b2"}}'
check "a shell put in the background is listed" is_opt background '1 shell: Soak it'
claude alpha:one tool '{"hook_event_name": "PostToolUse", "tool_name": "Agent", "tool_input": {},
  "tool_response": {"status": "async_launched", "agentId": "a3", "description": "Review it"}}'
check "and an agent sent off" [ "$(opt agents)" = 'Review it' -a "$(opt background)" = '1 shell: Soak it' ]
claude alpha:one tool '{"hook_event_name": "PostToolUse", "tool_name": "Agent", "tool_input": {},
  "tool_response": {"status": "async_launched", "agentId": "a6", "description": "Test it"}}'
check "a second one after it, a unit separator between" is_opt agents $'Review it\x1fTest it'
inner set -p -t alpha:one @arena_claude_began $(($(date +%s) - 3725))
claude alpha:one stop '{"last_assistant_message": "Done. It loads"}'
took() { [[ $(opt took) == 372[56] ]] }
check "a stop says how long its turn took" took
claude alpha:one prompt '{"prompt": "go on"}'
inner set -p -t alpha:one @arena_claude_at $(($(date +%s) - 700))
inner set -p -t alpha:one @arena_claude_ctx 88
mkdir $tmp/norepo
claude alpha:one stop '{"cwd": "'$tmp/norepo'"}'
check "outside a repo, no repo" is_opt branch 'no repo'
git -C $tmp/norepo init -q && git -C $tmp/norepo -c user.name=e2e -c user.email=e2e@localhost commit -q --allow-empty -m one &&
  git -C $tmp/norepo checkout -q --detach
claude alpha:one stop '{"cwd": "'$tmp/norepo'"}'
check "on no branch, detached and its commit" is_opt branch "detached $(git -C $tmp/norepo rev-parse --short HEAD)"
said end
check "the end takes the title and its count off too" await [ -z "$(inner show -p -t alpha:one | grep arena_claude)" ]

at() { [[ $(inner list-clients -F '#{session_name}:#{window_name}') == $1 ]] }
in_view_cleared() { [[ -z $(inner show -pqv -t alpha:renamed @arena_claude) ]] }
claude alpha:renamed prompt
claude alpha:three waiting '{"message": "Claude needs your permission to use Bash"}'
await dots '○●▲'
check "a Claude out of view come to wait is a desktop notification" await eval '[[ $(tail -1 $tmp/notified 2>/dev/null) == "-a|arena|--hint=string:x-canonical-private-synchronous:arena-%"*"|--|three|allow Bash|" ]]'
told=$(wc -l <$tmp/notified)
claude alpha:renamed stop '{"last_assistant_message": "All done"}'
await in_view_cleared
check "and the one in view is not" [ $(wc -l <$tmp/notified) -eq $told ]
told=$(wc -l <$tmp/notified)
for round in 1 2 3 4 5; do
  claude alpha:three stop '{"last_assistant_message": "$(touch '$tmp'/ran) \"q\" `x` #{pane_id}"}'
  await dots '○●◉'
  claude alpha:three prompt
  await dots '○●◐'
done
check "a Claude cycling between working and done is no notice" [ $(wc -l <$tmp/notified) -eq $told ]
claude alpha:three stopfailure '{"error": "rate_limit", "error_details": "$(touch '$tmp'/ran) \"q\" `x` #{pane_id}"}'
await dots '○●✖'
hostile='$(touch '$tmp'/ran) "q" x #{pane_id}'
stall_notice() { [[ $(tail -1 $tmp/notified) == "-a|arena|--hint=string:x-canonical-private-synchronous:arena-%"*"|--|three|$hostile|" ]] }
check "a Claude out of view come to stall is a notice, its words as they are" await stall_notice
check "run by no shell, nor by tmux" [ ! -e $tmp/ran ]
claude alpha:three prompt
await dots '○●◐'
claude alpha:three waiting '{"message": "Claude needs your permission to use Bash"}'
await dots '○●▲'
key M-n
check "Alt+n goes to the Claude that most wants looking at" await at alpha:three
key M-n
check "and stays where it is with no other waiting or done" at alpha:three
claude alpha:one waiting '{"message": "Claude is waiting for your input"}'
inner set -p -t alpha:one @arena_claude_since $(($(date +%s) - 100))
await dots '▲○●'
key M-n
check "with another, Alt+n goes on to it, the longer waiting first" await at alpha:one
key M-n
check "and round to the first" await at alpha:three
key M-N
check "Alt+N goes back" await at alpha:one
claude alpha:one end
await dots '●○▲'
key M-n
check "from a window not listed, Alt+n goes to the first" await at alpha:three

# the popup: a Claude's pane in another session, read-only, over the strip
inner send-keys -t alpha:three 'echo three-pane-line' Enter
shows '^NORMAL' || key C-Space
see '^NORMAL'

before=$(screen)
beside() { screen | sed -n '24p' }
beside_before=$(beside)
key -l ' '
check "space opens the popup, its head naming the Claude and its window" await shows '^.*╭─ ▲ three .*alpha'
check "and the pane's own line is in it, from the session arena is not in" await shows '│ ?three-pane-line'
check "with live while it follows the pane" await shows ' live'
check "and its keys in the foot" await shows '╰─ j k scroll .*a ask  r reply'
check "no cell outside it has changed its text" eval '[[ $(beside) == "$beside_before" ]]'
key -l 'x'
key -l 'jkgG'
check "a key of its own is not typed into the pane" eval '! screen | grep -q "three-pane-linex"'
key -l q
check "q closes it" await hides '╰─ j k scroll'
check "and the screen is as it was" await eval '[[ $(screen) == "$before" ]]'
key -l ' '
see '╰─ j k scroll'
key Escape
check "Esc closes it too" gone '╰─ j k scroll'

# answering and replying from the popup, without going there
mkdir -p $tmp/run/babylon
print -r -- '{"tickets":[{"id":324,"repo":"arena","title":"Lights","kind":"ticket","status":"doing","priority":"med","claimed_by":"%99",'\
'"claimed_at":"'$(date -u +%Y-%m-%dT%H:%M:%SZ)'","blocked_by":[],"ask":{"id":7,"question":"Keep it?","options":["yes","no"]}}]}' >$tmp/run/babylon/board.json
inner set -p -t beta:solo @arena_claude_branch t324-lights
claude beta:solo prompt
zselect -t 300
key -l j
await at beta:solo
key -l ' '
see '╭─ .*solo'
key -l a
check "a puts babylon's question at the foot with its options numbered" await shows 'answer: Keep it\?'
check "and the options" await shows ' 1 yes +2 no'
key -l 2
check "a digit answers it through babylon" await grep -q '^answer 7 2' $tmp/babylon
check "and the popup stays open" shows '╭─ .* solo'
key -l r
key -l 'hello there'
check "r opens a reply line at the foot" await shows 'reply: hello there'
key Enter
check "and Enter types it into the pane" await eval 'inner capture-pane -p -t beta:solo | grep -q "hello there"'
check "the popup stays open" shows '╭─ .* solo'
key -l q
rm -f $tmp/run/babylon/board.json
zselect -t 300
# Claude Code's own question, on the screen
inner send-keys -t alpha:three "printf 'Do you want to proceed?\n❯ 1. Yes\n  2. No\n'" Enter
key -l k
await at alpha:three
key -l ' '
see '╭─ ▲ three'
see 'Do you want to proceed'
key -l a
check "its own question is read from the screen, with its options" await shows 'answer: Do you want to proceed\?'
check "and the options" await shows ' 1 Yes +2 No'
key -l 2
check "a digit is typed into the pane" await eval 'inner capture-pane -p -t alpha:three | grep -q "sh-5.3\$ 2"'
key -l q
claude alpha:three end
claude beta:solo end

normal; key j
await at beta:solo
claude beta:solo tool
claude beta:solo stop
in_view_cleared() { [[ -z $(inner show -pqv -t beta:solo @arena_claude) ]] }
check "a done Claude in view is taken as looked at" await in_view_cleared
for w in $(inner list-windows -t alpha -F "#{window_index}"); claude alpha:$w stop
zselect -t 300
key M-k
looked() { [[ -z $(inner show -pqv -t "alpha:$(inner display -p -t alpha '#{window_index}')" @arena_claude) ]] }
await looked
zselect -t 100
own_replies() { ! screen | grep -qE '│[01] [01] [01] [01] [01] [01] ' }
check "and going to one leaves every pane its own reply" own_replies
for w in $(inner list-windows -t alpha -F "#{window_index}"); claude alpha:$w end
normal; key j Enter
see '╭─ 1 solo '


key 'echo hello brave world' Enter
see '│hello brave world'
row=$(settled | grep -n '│hello brave world' | cut -d: -f1)
mouse 0 8 $row M
mouse 32 18 $row M
mouse 0 18 $row m
copied() { [[ $(outer show-buffer 2>/dev/null) == $1 ]] }
check "dragging selects text and copies it" await copied 'brave world'

highlit() { outer capture-pane -p -e -t o | grep -q $'\e\\[7mbrave' }
key M-/
key 'brave' Enter
check "Alt+/ finds text in the history" await highlit
key Escape

normal; key m
key b
check "the menu opens the browser in a window of its own, in view" see '╭─ [0-9] browser ─'
check "running terminal-browser on its start page, for new tabs too" see '│browser-stub 1 terminal-browser://start'
key Enter
gone 'browser-stub'

key 'exit' Enter
# three was the last window dropped on alpha, which makes it the one alpha shows
check "a session ending moves arena to one that is left" see '╭─ 3 three '
check "and the session is gone" await sessions 1

# Plan drives what the board drove: the tickets, their modals, the keys on a row, the orchestrator's column beside it.
# Workbench's look (a palette) gives Plan its windows and rows for no goal; the plain look keeps what the typing
# races need, the column's lit state.
one=$(inner display -p -t alpha:one '#{pane_id}')
mkdir -p $tmp/run/babylon $tmp/.config/ficciones/theme
print -r -- '{"tickets":[{"id":7,"repo":"tlon","title":"Lights","kind":"ticket","status":"todo","priority":"med","blocked_by":[],"stage":"failed",'\
'"stage_note":"the review sent it back: the first reason runs long enough to need a second row in the box, and\nthe last words of it are never cut off",'\
'"ask":{"id":5,"question":"Which colour?","options":["red","blue"]}},'\
'{"id":8,"repo":"arena","title":"Board of the lanes","kind":"ticket","status":"doing","priority":"high","claimed_by":"'$one'",'\
'"claimed_at":"'$(date -u +%Y-%m-%dT%H:%M:%SZ)'","blocked_by":[7]},'\
'{"id":11,"repo":"arena","title":"Handed in","kind":"ticket","status":"review","priority":"med","claimed_by":"'$one'",'\
'"claimed_at":"'$(date -u +%Y-%m-%dT%H:%M:%SZ)'","blocked_by":[],"stage":"queued"}],'\
'"backlog":[{"id":12,"repo":"arena","title":"Someday","kind":"ticket","status":"backlog","priority":"med","blocked_by":[]}],'\
'"plan":{"now":[{"ticket":8,"repo":"arena","title":"Board of the lanes","state":"building","since":"2026-11-24T10:00:00Z","pane":"'$one'"},'\
'{"ticket":11,"repo":"arena","title":"Handed in","state":"landing","stage":"queued","place":1,"since":"2026-11-24T10:00:00Z"}],'\
'"next":[],"goals":[],"landed_today":{"count":0,"newest":[]},"not_planned":{"count":1,"follow_ups":0,"by_repo":{"tlon":1}}}}' \
  >$tmp/run/babylon/board.json
cp $tmp/run/babylon/board.json $tmp/board.kept
for name in AMBER VIOLET AMBERDIM EMBERDIM INK DIM GREY SURFACE0 SURFACE2 SURFACE3 SURFACE4 BG CYAN MOSS PINK RED; do print -r -- "PALETTE_$name=#808080"; done >$tmp/.config/ficciones/theme/palette.sh
outer resize-window -t o -x 200 -y 40
zselect -t 300
normal
key b
see 'in flight[^0-9]*2'
key M-b
gone 'in flight[^0-9]*2'
last() { [[ -f $tmp/babylon && $(tail -1 $tmp/babylon) == $1 ]] }
outer resize-window -t o -x 200 -y 40
zselect -t 100
$bin -L $in plan 7
see "no goal"
: >$tmp/babylon
key ' '
check "a ticket's modal opened from a no goal row shows the question and its options by number" see '2 blue'
key 2
checked() { [[ -f $tmp/babylon && $(tail -1 $tmp/babylon) == 'answer 5 2' ]] }
check "and a number answers it through babylon" await checked
check "and closes it" gone '2 blue'
touch $tmp/refuse
key ' '
key 1
refused() { [[ -f $tmp/notified && $(<$tmp/notified) == *'babylon: no session to answer'* ]] }
check "and an answer babylon refuses says why" await refused
rm $tmp/refuse
rowof() { screen | grep -n -m1 -- "$1" | cut -d: -f1 }
key ' '
check "space on a row and o show the picked ticket's whole ticket, as babylon tells it" see 'the whole of it'
check "with its close button in the foot" see 'q close'
check "and a send-back's reason whole in it, on as many rows as it takes" see 'last words of it are never cut off'
key j j j j j
check "and j scrolls it no further than its last line" see 'the whole of it'
key Escape
check "Escape puts it away" gone 'the whole of it'
key ' '
see 'the whole of it'
key q
check "q closes it too" gone 'the whole of it'
nofile() { [[ ! -e $tmp/run/babylon/detail-7.txt ]] }
check "leaving no file of it behind" await nofile
close_at() { local l=$(settled | grep -m1 "q close"); print $(( ${#${l%%q close*}} + 1 )) $(settled | grep -n -m1 "q close" | cut -d: -f1) }
key ' '
see 'the whole of it'
mouse 0 ${(z)$(close_at)} M
check "a click on the modal's close button puts it away" gone 'the whole of it'
key ' '
key ' '
see 'the whole of it'
foot_at=(${(z)$(close_at)})
mouse 0 $(( foot_at[1] - 20 )) $(( foot_at[2] - 3 )) M
check "a click inside the modal leaves it open" eval 'settled | grep -qE "the whole of it"'
mouse 0 70 39 M
check "and a click outside it closes it" gone 'the whole of it'
$bin -L $in plan 7
check "arena plan and a ticket's id, run elsewhere, opens Plan with the pick on it" see 'no goal'
check "so that its row is open in place" see '⏎ start'
key ' '
see 'the whole of it'
arena_pid=$(pgrep -x -P $(outer display -p -t o '#{pane_pid}') arena)
kill -STOP $arena_pid
key Escape
$bin -L $in plan 8
zselect -t 10
kill -CONT $arena_pid
zselect -t 10
check "an Escape typed before arena plan moved the pick put the modal away, not Plan after" gone 'the whole of it'
key ' '
check "and the pick is on the new ticket" see '⏎ go'
key ' '
outer resize-window -t o -x 121 -y 24
two=$(inner list-panes -s -t alpha -F '#{pane_id}' | sed -n 2p)
$bin -L $in show $two
check "arena show and a pane puts its window in front, Plan put away" await dots '○●○'
$bin -L $in plan 7
see 'no goal'
$bin -L $in show $two
check "and a show with Plan open puts it away for the pane" await dots '○●○'
shows '^NORMAL' || key C-Space
see '^NORMAL'
key -l '#'
key -l 7
key Enter
check "# in normal mode and a ticket's number open that ticket's modal over Plan" see 'the whole of it'
key Escape
check "Esc puts the modal away" gone 'the whole of it'
zselect -t 10
key Escape
check "and Plan" gone 'no goal'
outer resize-window -t o -x 200 -y 40
zselect -t 200
last() { [[ -f $tmp/babylon && $(tail -1 $tmp/babylon) == $1 ]] }
$bin -L $in plan 7
see 'no goal'
key /
key -l zzz
check "/ opens a find line on Plan, the typing in it" see '/ zzz'
key BSpace BSpace BSpace
key -l TLON
key Enter
check "Enter keeps the find and gives Plan its keys" see '/ TLON'
key Escape
check "Escape clears it" gone '/ TLON'
key -l 'qecho dropped-after-q'
zselect -t 100
key -l 'echo kept-after-q'
kept_after_plan() { inner capture-pane -p -t alpha | grep -qF 'echo kept-after-q' }
check "what is typed in the read after the one closing Plan is the pane's" await kept_after_plan
dropped_after_plan() { ! inner capture-pane -p -t alpha | grep -qF 'dropped-after-q' }
check "and what is typed in the same read as the q closing Plan is dropped" dropped_after_plan
key C-u
$bin -L $in plan 7
zselect -t 100
key p
check "p raises the picked row's priority through babylon" await last 'update 7 --priority high'
key w
check "w on a no goal row asks its why at the foot" see '❯ +⏎ save  esc drop'
key Escape
check "and Escape drops it" gone '⏎ save  esc drop'
key w
key -l 'the lights'
key Enter
check "its why puts the ticket at the bottom of next, through babylon" await last 'next 7 --why the lights'
key W
check "and W at its top" await last 'next 7 --at 1'
folded_file=$tmp/.local/state/arena/folded
$bin -L $in plan 7
zselect -t 200
key k
key Enter
check "⏎ on a repo's chip folds its rows" gone '#7 Lights'
check "and the fold is kept with the repo folds" await eval 'grep -qx tlon $folded_file'
key Z
check "Z on the chip opens only that repo's rows" see '#7 Lights'
check "and the fold is gone from the repo folds" await eval '! grep -qx tlon $folded_file'
inner set -p -t alpha:one @arena_claude_since $(date +%s)
inner new-window -d -t alpha: -n spare sh
inner set -p -t alpha:spare @arena_claude_since $(date +%s)
key Tab
see 'other Claudes 1'
inner kill-window -t alpha:spare
$bin -L $in plan 7
zselect -t 200
key G
check "G on a no goal row shows the running Claudes it can be given to" see '│? *[1-9] +alpha · one'
key Escape
check "and Escape puts them away" gone 'give #7 to'
key G
see "give #7 to"
key "$(screen | sed -n 's/.*[│ ] *\([1-9]\)  *alpha · one .*/\1/p' | head -1)"
check "and a Claude's number gives it the ticket through babylon, by its pane" await last "give 7 $one"
touch $tmp/refuse
$bin -L $in plan 7
zselect -t 200
key G
see "give #7 to"
key "$(screen | sed -n 's/.*[│ ] *\([1-9]\)  *alpha · one .*/\1/p' | head -1)"
unfit() { [[ -f $tmp/notified && $(<$tmp/notified) == *"babylon: the Claude in $one is mid-turn"* ]] }
check "and refused by babylon, it says why, the pane whole" await unfit
rm $tmp/refuse
inner set -pu -t alpha:one @arena_claude_since
outer resize-window -t o -x 200 -y 40
$bin -L $in plan 7
see 'no goal'
: >$tmp/babylon
key J
check "J on a no goal row moves it down its repo's order through babylon" await last 'move 7 down --repo tlon'
check "the backlog is a window of its own on Planning, listing what is kept for later" see '#12 Someday'
key j
: >$tmp/babylon
key t
check "t on a backlog row moves it to todo through babylon" await last 'update 12 --status todo'
key Escape
cp $tmp/run/babylon/board.json $tmp/board.noauto
$bin -L $in plan 7
zselect -t 200
check "with no auto in babylon's file, Plan's head says nothing of it" hides 'auto [0-9]'
key A
check "A opens auto's settings over Plan" see 'working [0-9]+ of [0-9]+'
key a
check "a in them turns babylon's auto mode on" await last 'auto on'
key Escape
check "and esc closes them" gone 'working [0-9]+ of [0-9]+'
print -r -- "${$(<$tmp/board.noauto)%\}}"',"auto":{"on":true,"cap":2,"working":1}}' >$tmp/run/babylon/board.json
check "on, Plan's head says how many work of the cap" see ' ◐ auto 1/2( |$)'
key A
key a
check "and a turns it off" await last 'auto off'
key Escape
cp $tmp/board.noauto $tmp/run/babylon/board.json
check "off, the state is gone" gone 'auto [0-9]'
check "with nothing of the orchestrator in babylon's file, Plan's head has no button for it" hides ' ● orch '
print -r -- "${$(<$tmp/board.noauto)%\}}"',"auto":{"on":true,"cap":4,"working":4,"tools":{"working":1,"cap":1}}}' >$tmp/run/babylon/board.json
check "with room, Plan's head says the tools slots when babylon's file gives them" see ' ◐ auto 4/4 · tools 1/1( |$)'
outer resize-window -t o -x 56
check "and with less room, without the tools slots" see ' ◐ auto 4/4 +≡'
outer resize-window -t o -x 200
cp $tmp/board.noauto $tmp/run/babylon/board.json
outer resize-window -t o -x 200 -y 40
zselect -t 200
key Escape
plan_up='◆ (in flight|no goal)'
plan_home() { normal; key b; see "$plan_up" }
plan_at() { $bin -L $in plan $1; see "$plan_up" }
# column and row from one picture, taken again while it shows nothing (mid-frame): from two, a click goes out with no row
spot() { local at l p i; for i in {1..30}; do at=$(settled | grep -n -m1 -- "$1") && break; zselect -t 100; done; [[ -n $at ]] || return 1; l=${at#*:} p=${l%%"$1"*}; print $(( ${#p} + 2 )) ${at%%:*} }
plan_home
touch $tmp/refuse-start
plan_at 7
key Enter
check "⏎ on a no goal row babylon refuses to start says why on the foot, Plan still open" see 'babylon: ticke'
rm $tmp/refuse-start
: >$tmp/babylon
key Enter
check "⏎ on a free todo row runs babylon start on it" await last 'start 7'
await eval '[[ -e $tmp/run/babylon/refused-start ]]'
await eval '[[ ! -e $tmp/run/babylon/refused-start ]]'
check "and leaves Doing on screen once babylon has started it" see "$plan_up"
plan_at 8
key Enter
check "⏎ on an in flight row opens the Claude's pane in the middle column" await shows 'NORMAL  i type   d changes   esc back'
check "and the strip is not visited" gone '╭─ 1 one '
key d
check "d turns the column to its ticket's changes" await shows 'NORMAL  d pane   j k scroll   esc back'
key d
key i
check "i types into it" await shows 'INSERT  ctrl\+space normal'
key C-Space
await shows 'NORMAL  i type   d changes   esc back'
shut=(${=$(spot ' × ')})
click $(( shut[1] - 12 )) $(( shut[2] + 3 ))
check "a click inside the Claude's pane in the middle column types into it, as i does" await shows 'INSERT  ctrl\+space normal'
key -l zxqclick
check "and what is typed after it shows in the Claude's prompt" await shows 'zxqclick'
key C-u
await eval '! shows zxqclick'
key C-Space
await shows 'NORMAL  i type   d changes   esc back'
key Escape
check "esc in normal mode closes it, Doing on screen" await eval '! [[ $(screen) == *"esc back"* ]]'
see "$plan_up"
print -r -- "${$(<$tmp/board.kept)%\}}"',"proposals":[{"id":4,"action":"start","ticket_id":7,"what":"Start #7","why":"Next in line"}],"needs_you":[{"id":"proposal:4","kind":"proposal","ticket":7,"repo":"tlon","text":"P4 Start #7: Next in line","actions":[{"key":"⏎","label":"go","argv":["babylon","go","4"]},{"key":"x","label":"no","argv":["babylon","no","4"]}]}]}' >$tmp/run/babylon/board.json
check "Plan's head counts what needs you" see ' ▲ 1'
plan_at 7
: >$tmp/babylon
key Enter
check "⏎ on a row with an open proposal answers it through babylon, not a Claude started" await last 'go 4'
plan_at 7
key x
check "and x on it says no to it" await last 'no 4'
cp $tmp/board.kept $tmp/run/babylon/board.json
gone ' ▲ 1'
plan_at 7
: >$tmp/babylon
key '>'
check "> on a no goal row closes a ticket still to do" await last 'update 7 --status done'
key e
check "e on a no goal row edits it in the middle column" await last 'edit 7'
zselect -t 500
key Escape
plan_at 8
key ' '
key ' '
check "a modal opened from an in flight row shows its body" see 'the whole of it'
check "and its holder's state" see 'its Claude: '
key Enter
check "and ⏎ in it opens the Claude holding it in the middle column" await shows 'NORMAL  i type   d changes   esc back'
key Escape
plan_up='◆ (in flight|no goal)'
plan_home() { normal; key b; see "$plan_up" }
plan_at() { $bin -L $in plan $1; see "$plan_up" }
in_session() { [[ $(inner list-clients -F '#{session_name}') == $1 ]] }
orch_lit() { [[ $(outer capture-pane -ep -t o) =~ $'((\e\\[[0-9;]*m)+) ○ orchestrator ' && $match[1] =~ '[[;]7[;m]' ]] }
shown_cursor() { [[ $(outer display -p -t o '#{cursor_flag}') == $1 ]] }
said() { inner capture-pane -p -t $1 | grep -qx $2 }
inner new-session -d -s babylon-gate -n gate sh
plan_at 7
key g
check "g on Plan shows the gate" see '╭─ 1 gate '
plan_home
print -r -- '{"tickets":[{"id":21,"repo":"arena","title":"Running","kind":"ticket","status":"review","priority":"med","blocked_by":[],"stage":"reviewing"},{"id":22,"repo":"arena","title":"Waiting","kind":"ticket","status":"review","priority":"med","blocked_by":[],"stage":"queued"}],"plan":{"now":[{"ticket":21,"repo":"arena","title":"Running","state":"landing","stage":"reviewing","since":"2026-11-24T10:00:00Z"},{"ticket":22,"repo":"arena","title":"Waiting","state":"landing","stage":"queued","place":1,"since":"2026-11-24T10:00:00Z"}],"next":[],"goals":[],"landed_today":{"count":0,"newest":[]},"not_planned":{"count":0,"follow_ups":0,"by_repo":{}}}}' >$tmp/run/babylon/board.json
see '#21 Running'
plan_at 21
key g
check "g on Plan with a run in progress opens the gate's modal on it" see '╭─ gate · #21 '
check "its stages with their marks and times" see '✓ rebase +ok +4s'
check "the failed one's result" see '✗ gate +failed +1m 58s'
check "and its failing output under them" see '│ expected 1, found 0 +│'
check "and what is queued behind it" see 'queued behind it: #22 arena'
check "with its keys in the foot" see '╰─ L whole log ─ t ticket ─ u bump ─ W withdraw ─ q close'
key u
check "u bumps it through babylon" await last 'bump 21'
key q
key q
print -r -- '{"tickets":[{"id":13,"repo":"babylon","title":"Gatekeeping","kind":"ticket","status":"todo","priority":"med","blocked_by":[]}],"plan":{"now":[],"next":[],"goals":[],"landed_today":{"count":0,"newest":[]},"not_planned":{"count":1,"follow_ups":0,"by_repo":{"babylon":1}}}}' >$tmp/run/babylon/board.json
plan_home
key Tab
see 'Gatekeeping'
plan_at 13
key Enter
check "⏎ on a babylon row starts it through babylon" await last 'start 13'
check "and leaves Plan on screen" see "$plan_up"
cp $tmp/board.kept $tmp/run/babylon/board.json
see '#7 Lights'
plan_at 7
key o
key Enter
starting() { [[ -f $tmp/babylon && $(tail -1 $tmp/babylon) == orchestrator ]] }
check "o on Plan opens the drawer, and ⏎ in it starts the orchestrator when it is not running" await starting
key M-h
inner kill-session -t '=orchestrator'
inner kill-session -t '=babylon-gate'
await in_session alpha
plan_up='in flight [0-9]'
plan_home() { normal; key b; see "$plan_up" }
plan_at() { $bin -L $in plan $1; see "$plan_up" }
in_session() { [[ $(inner list-clients -F '#{session_name}') == $1 ]] }
orch_lit() { [[ $(outer capture-pane -ep -t o) =~ $'((\e\\[[0-9;]*m)+) ○ orchestrator ' && $match[1] =~ '[[;]7[;m]' ]] }
shown_cursor() { [[ $(outer display -p -t o '#{cursor_flag}') == $1 ]] }
said() { inner capture-pane -p -t $1 | grep -qx $2 }
print -r -- '' >$tmp/.config/ficciones/theme/palette.sh
outer resize-window -t o -x 121 -y 24
inner new-session -d -s orchestrator -n orch sh
cp $tmp/board.kept $tmp/board.two
print -r -- "${$(<$tmp/board.two)%\}}"',"orchestrator":{"on":true,"running":true}}' >$tmp/run/babylon/board.json
: >$tmp/babylon
$bin -L $in plan 8
see "$plan_up"
check "with the orchestrator running, Plan has its window beside it" see '╭─ ○ orchestrator · idle '
check "arena in its session to have it live" await in_session orchestrator
check "Plan keeps the keys: its column is unlit, the cursor in no pane" eval '! orch_lit && shown_cursor 0'
key M-l
check "Alt+l from Plan focuses it, lit as the focused column" await orch_lit
key 'echo side' Enter
check "what is typed then reaches its pane" see '│side +│'
in_mode() { [[ -n $(inner display -p -t orchestrator:orch '#{pane_mode}') ]] }
cp $tmp/run/babylon/board.json $tmp/board.chatty
print -r -- "${$(<$tmp/board.chatty)%\}}"',"auto":{"on":true,"cap":2,"working":1}}' >$tmp/run/babylon/board.json
touch $tmp/chatty
offs=$(grep -cx 'auto off' $tmp/babylon)
click 10 20
key '`'
see '◐ (auto )?1/2'
switch=$(spot '◐ auto')
mouse 0 ${(z)switch} M
mouse 0 ${(z)switch} M
await eval '(( $(grep -cx "auto off" $tmp/babylon) > offs ))'
key '`'
zselect -t 50
check "a babylon command that prints leaves the orchestrator's pane out of any mode" eval '! in_mode'
key M-l
key -l 'echo after-chatter-jkdufltb'
key Enter
check "and a sentence typed then reaches it whole" await eval 'inner capture-pane -p -t orchestrator:orch | grep -qx after-chatter-jkdufltb'
rm $tmp/chatty
cp $tmp/board.chatty $tmp/run/babylon/board.json
inner copy-mode -t orchestrator:orch
check "the pane put in a mode" eval 'in_mode'
key M-l
key -l 'echo after-mode-jkdufltb'
key Enter
check "a sentence typed to a pane in a mode takes it out and reaches the pane whole" await eval 'inner capture-pane -p -t orchestrator:orch | grep -qx after-mode-jkdufltb && ! in_mode'
: >$tmp/babylon
check "and none of it Plan, which stays open" eval '[[ ! -s $tmp/babylon ]] && shows "$plan_up"'
mousing() { [[ $(inner display -p -t $1 '#{mouse_standard_flag}') == 1 ]] }
print -rn -- $'\e[?1000h\e[?1006h' >$tmp/clicks
inner send-keys -t orchestrator:orch "stty -echo -icanon; cat $tmp/clicks; timeout 2 cat -v; printf '\\033[?1006l\\033[?1000l'; stty sane" Enter
await mousing orchestrator:orch
mouse 64 100 10 M
wheeled() { inner capture-pane -pJ -t orchestrator:orch | grep -qF '[<64;' }
check "a wheel over it reaches its program" await wheeled
await eval '! mousing orchestrator:orch'
key M-h
check "Alt+h goes back to Plan" await eval '! orch_lit && shown_cursor 0'
key '?'
check "whose keys are its own again" see "the plan.s keys"
key Escape
key o
check "o opens the drawer again, with the keys" await orch_lit
key M-h
key Escape
check "closing Plan goes back to the session the human was in" await in_session alpha
plan_at 8
key '`'
see '╭─ ○ orchestrator · idle '
key Escape
check "Escape closes a Plan with the column beside it, going back to the session the human was in" await in_session alpha
server=$(inner display -p '#{pid}')
inner kill-session -t '=orchestrator'
await in_session alpha
print -r -- '' >$tmp/.config/ficciones/theme/palette.sh
outer resize-window -t o -x 121 -y 24
rm -f $tmp/babylon $tmp/notified
one=$(inner display -p -t alpha:one '#{pane_id}')
mkdir -p $tmp/run/babylon
print -r -- '{"tickets":[{"id":7,"repo":"tlon","title":"Lights","kind":"ticket","status":"todo","priority":"med","blocked_by":[]}],'\
'"plan":{"now":[],"next":[{"ticket":7,"repo":"tlon","title":"Lights","why":"the light switch","set_by":"orchestrator","waits_on":[]}],'\
'"goals":[],"landed_today":{"count":0,"newest":[]},"not_planned":{"count":0,"follow_ups":0,"by_repo":{}}}}' >$tmp/run/babylon/board.json
shows '^NORMAL' && key -l i
see 'INSERT|◆ home'
x=$(col '◆ home')
mouse 0 $x 24 M
mouse 0 $x 24 m
check "a click on ◆ home in the foot row goes home" see 'in flight [0-9]'
key Escape
check "and Escape closes it again" gone 'in flight [0-9]'

rowof() { settled | grep -n -m1 -F -- "$1" | cut -d: -f1 }
colof() { local l=$(settled | sed -n $1p); [[ $l == *"$2"* ]] || return 1; local p=${l%%"$2"*}; print $(( ${#p} + 1 )) }
# the column of the first │ at or after column $2 of row $1
barof() { local l=$(settled | sed -n $1p); local p=${${l[$2,-1]}%%│*}; print $(( $2 + ${#p} )) }
park() { mouse 35 80 18 M }
inner new-session -d -s orchestrator -n orch sh
inner select-window -t alpha:one
inner split-window -h -t alpha:one sh
await eval '[[ $(inner list-panes -t alpha:one | wc -l) == 2 ]]'
zselect -t 50
divide=$(barof 5 $(( $(colof 1 '╭─ 1 one') + 1 )))
mouse 35 $divide 5 M
shaped() { [[ $(<$tmp/raw) == *$'\e]22;ew-resize'* ]] }
await shaped
in_frame() { local raw=$(<$tmp/raw); local pre=${raw%$'\e]22;ew-resize'*}; [[ ${pre##*$'\e[?2026'} == h* ]] }
check "the pointer's shape goes out inside a frame" in_frame
park
inner kill-pane -t alpha:one.1
outer resize-window -t o -x 121

key M-q
check "Alt+q leaves cleanly" see 'EXIT 0'
check "and leaves the sessions running" inner has-session -t alpha
check "with nothing on stderr" test ! -s $tmp/err

print -r -- '{"tickets":[{"id":7,"repo":"tlon","title":"Lights","kind":"ticket","status":"todo","priority":"med","blocked_by":[],'\
'"ask":{"id":5,"question":"Which colour?","options":["red","blue"]}}],'\
'"plan":{"now":[],"next":[{"ticket":7,"repo":"tlon","title":"Lights","why":"the light switch","set_by":"orchestrator","waits_on":[]}],'\
'"goals":[],"landed_today":{"count":0,"newest":[]},"not_planned":{"count":0,"follow_ups":0,"by_repo":{}}}}' >$tmp/run/babylon/board.json
# a control-mode client that is no arena, as iTerm is
mkfifo $tmp/other
inner -C attach <$tmp/other >$tmp/other-out 2>&1 &
exec {other}>$tmp/other
other_there() { [[ $(inner list-clients -F '#{client_control_mode}') == 1 ]] }
check "a control-mode client that is no arena is on the server" await other_there
outer new-window -t o \
  "env -u TMUX HOME=$tmp XDG_RUNTIME_DIR=$tmp/run ARENA_REDUCED_MOTION=1 $bin -L $in plan 7; echo EXIT \$?; cat"
check "with no arena running, arena plan and an id starts one with the plan's pick on that ticket" see '▌ 1 #7 tlon'
untold() { ! grep -q 'arena plan' $tmp/other-out }
check "and a control-mode client that is no arena is told nothing" untold
key Escape M-q
check "which leaves as any other" see 'EXIT 0'
none() { $bin -L $in "$@" 2>/dev/null; [[ $? == 3 ]] }
check "with no arena running, arena show exits 3" none show %0
check "and arena inbox does too" none inbox
check "arena --help lists the doors" test -n "$($bin --help | grep -F 'arena [-L socket] show')"
outer new-window -t o \
  "env -u TMUX HOME=$tmp XDG_RUNTIME_DIR=$tmp/run ARENA_REDUCED_MOTION=1 $bin -L $in; echo EXIT \$?; cat"
check "arena with no session named opens home: the plan alone, its head saying the orchestrator's state" see '◆ +doing'
check "and no column beside it" gone '╭─ ○ orchestrator'
check "the orchestrator in the plan's head" see '◆ orch idle'
check "next as babylon gives it" see '1 #7 +tlon +Lights +free now'
check "and its why under it" see 'the light switch'
key o
check "o opens the orchestrator's drawer over the plan" see '╭─ ○ orchestrator · idle '
check "with the keys, in insert" await orch_lit
check "and its foot says INSERT" see 'INSERT'
key -l 'echo '
key o
key -l -- '-typed'
key Enter
check "o typed in the drawer reaches its pane" await eval 'inner capture-pane -p -t orchestrator:orch | grep -qx o-typed'
# cat, not the shell: readline would hold the esc as a meta prefix and take the next key typed with it
inner send-keys -t orchestrator:orch 'stty -echo -icanon; cat -v; stty sane' Enter
await eval '[[ $(inner display -p -t orchestrator:orch "#{pane_current_command}") == cat ]]'
key Escape
check "esc typed in it reaches the chat" await eval 'inner capture-pane -p -t orchestrator:orch | grep -qxF "^["'
check "and the drawer stays open, in insert" see 'INSERT'
inner send-keys -t orchestrator:orch C-c
await eval '[[ $(inner display -p -t orchestrator:orch "#{pane_current_command}") == sh ]]'

key C-Space
check "Ctrl+Space leaves insert, the foot saying how to close it" see 'NORMAL · o close · i type'
key o
check "o closes it in normal mode" gone '╭─ ○ orchestrator'
key o
check "o opens it again" await orch_lit
key M-h
check "Alt+h closes it from insert" gone '╭─ ○ orchestrator'
key O
check "O opens the overview" see '╭─ 1 one '
key Escape
outer resize-window -t o -x 105
check "at half the screen the plan keeps the screen, with a link to the orchestrator in its head" see '◆ +doing.*o orchestrator'
check "its next without a row for its why, the picked row's whole title and why at the foot" see '#7 tlon +Lights — the light switch'
key o
check "o opens the drawer over the whole width" see '╭─ ○ orchestrator .* o close'
key M-h
check "and Alt+h closes it" gone '╭─ ○ orchestrator'
outer resize-window -t o -x 121
check "at more width the plan is as it was" see '◆ +doing'
key e
check "e on a next row opens its why, to edit" see '❯ the light switch'
key -l ' now'
key Enter
check "and Enter keeps it there with the new why, through babylon" await last 'next 7 --why the light switch now'
key x
zselect -t 300
check "x on Doing's next does nothing: next is reordered on Planning" eval '! last "next 7 --drop"'
key Tab
key l
key x
check "x takes it out of next on Planning, through babylon" await last 'next 7 --drop'
key Tab
: >$tmp/babylon
# Workbench's plan is seven windows, each in a slot the screen's size gives it, and none folds:
# each keeps its rows and its place
cp $tmp/run/babylon/board.json $tmp/board.slots
mkdir -p $tmp/.config/ficciones/theme
for name in AMBER VIOLET AMBERDIM EMBERDIM INK DIM GREY SURFACE0 SURFACE2 SURFACE3 SURFACE4 BG CYAN MOSS PINK RED; do print -r -- "PALETTE_$name=#808080"; done >$tmp/.config/ficciones/theme/palette.sh
print -r -- '{"tickets":[{"id":703,"repo":"arena","title":"Landed one","kind":"ticket","status":"done","closed_at":"2026-11-24T10:00:00Z","priority":"med","blocked_by":[]},{"id":701,"repo":"arena","title":"First building","kind":"ticket","status":"doing","priority":"med","blocked_by":[]}],"plan":{"now":[{"ticket":701,"repo":"arena","title":"First building","state":"building","since":"2026-11-24T10:00:00Z"},{"ticket":702,"repo":"arena","title":"Second landing","state":"landing","stage":"verifying","since":"2026-11-24T10:00:00Z"}],"next":[{"ticket":7,"repo":"tlon","title":"Lights","why":"","set_by":"orchestrator","waits_on":[]}],"goals":[],"landed_today":{"count":1,"newest":[703]},"not_planned":{"count":0,"follow_ups":0,"by_repo":{}}}}' >$tmp/run/babylon/board.json
check "in Workbench's look the plan's windows have their title bars" await shows '◆ in flight.*◆ landed'
check "in flight holds the ticket being built" see 'First buil'
check "and the pipeline's, with its stage" see 'Second lan'
check "landed holds today's landing, a row to a ticket" see '✓ #703'
title_row() { settled | grep -n "$1" | head -1 | cut -d: -f1 }
next_row=$(title_row '◆ next')
key z
check "z folds nothing: in flight keeps its rows" see 'First buil'
same_row() { [[ $(title_row '◆ next') == $next_row ]] }
check "and the window below stays on the same screen row" await same_row
check "no window's title has a fold mark" gone '▾'
key f
check "f opens the window whole, as a modal" see 'q close'
key q
check "and q closes it" gone 'q close'
check "with the window below still on its row" same_row
title_click() { local row=$(title_row "$1"); local line=$(settled | sed -n "${row}p"); mouse 0 $(( ${#${line%%$1*}} + 3 )) $row M; mouse 0 $(( ${#${line%%$1*}} + 3 )) $row m }
title_click '◆ in flight'
check "a click on a window's title bar leaves it open" see 'First buil'
check "with the window below still on its row" same_row
outer resize-window -t o -x 105 -y 40
check "at half the screen the windows stack in one column, in flight above next" await eval '[[ -n $(title_row "◆ in flight") && -n $(title_row "◆ next") ]] && (( $(title_row "◆ in flight") < $(title_row "◆ next") ))'
outer resize-window -t o -x 121 -y 24
key j
key Enter
check "⏎ on a pipeline row opens the gate's modal for its run" await shows '✗ gate +failed'
key q
key k
: >$tmp/babylon
see '◐ auto'
r=$(rowof '◐ auto'); c=$(colof $r '◐ auto')
mouse 0 $((c + 1)) $r M
mouse 0 $((c + 1)) $r m
check "a click on the switch in Plan's head turns auto on" await last 'auto on'
cp $tmp/run/babylon/board.json $tmp/board.plan
print -r -- "${$(<$tmp/board.plan)%\}}"',"auto":{"on":true,"cap":4,"working":2,"tools":{"working":1,"cap":1}}}' >$tmp/run/babylon/board.json
check "on, Plan's head says how many work of the cap" see '◐ auto 2/4'
check "and the orchestrator's column says nothing of auto" eval '[[ $(screen | grep -c "auto 2/4") == 1 ]]'
auto_offs() { grep -cx 'auto off' $tmp/babylon }
offs=$(auto_offs)
r=$(rowof '◐ auto'); c=$(colof $r '◐ auto'); today_c=$(colof $r '✓')
mouse 0 $((c + 1)) $r M
mouse 0 $((c + 1)) $r m
check "one click on it only asks to turn it off" see '◐ turn off\?'
check "and the pieces after it stay where they were" eval '[[ $(colof '$r' "◐ turn") == '$c' && $(colof '$r' "✓") == '$today_c' ]]'
mouse 0 $((c + 1)) $r M
mouse 0 $((c + 1)) $r m
check "a second click does" await eval '(( $(auto_offs) > offs ))'
cp $tmp/board.plan $tmp/run/babylon/board.json
: >$tmp/babylon
check "the picked row is open in place, with the card's buttons under it" await shows 'space open +e edit'
key -l ' '
check "and space on it opens its modal" see 'q close'
key Escape
check "which Escape puts away, the row staying open" gone 'q close'
check "the pick starts on the first window's row" see '▌▌. #701 First building'
key /
key -l Light
key Enter
check "/ with part of a title keeps the rows that hold it, and the pick skips the rest, a Claude with no ticket too" await shows '▌▌1 . #7 Lights'
check "the rows that miss it stay, dimmed" see '#701 First building'
key Escape
check "and Escape clears it" gone '/ Light'
key r
check "r narrows the plan to one repo" await gone 'Lights'
check "the repo's rows are the ones left" see 'First building'
for round in 1 2 3 4 5; do
  shows 'Lights' && break
  key r
  zselect -t 30
done
check "and r past the last repo shows every one again" await shows 'Lights'
repeat 12 key j
key '<'
check "< on a landed row opens its ticket again" await last 'update 703 --status todo'
repeat 12 key k
: >$tmp/babylon
key p
check "p on a now row raises its priority through babylon" await last 'update 701 --priority high'
key e
check "e on a now row edits its ticket" await last 'edit 701'
normal
key b
key Tab
print -r -- '{"tickets":[{"id":801,"repo":"q","title":"Alp","kind":"ticket","status":"todo","priority":"high","blocked_by":[]},{"id":802,"repo":"z","title":"Bet","kind":"ticket","status":"todo","priority":"med","blocked_by":[]}],"plan":{"now":[],"next":[],"goals":[],"landed_today":{"count":0,"newest":[]},"not_planned":{"count":2,"follow_ups":0,"by_repo":{"q":1,"z":1}}}}' >$tmp/run/babylon/board.json
check "no goal lists the open repos' todo tickets under its chips" await shows 'Alp'
check "with a chip for every repo" see 'q 1.*z 1'
chip_click() { local row=$(settled | grep -n "$1" | head -1 | cut -d: -f1); local line=$(settled | sed -n "${row}p"); mouse 0 $(( ${#${line%%$1*}} + 2 )) $row M; mouse 0 $(( ${#${line%%$1*}} + 2 )) $row m }
chip_click 'q 1'
check "a click on a repo's chip folds its rows" await gone 'Alp'
check "and the other repo's rows are the ones left" see 'Bet'
check "the fold is kept with the repo folds" await eval 'grep -qx q $folded_file'
chip_click 'q 1'
check "a click on the chip again opens them" await shows 'Alp'
chip_click 'q 1'
await gone 'Alp'
plan_said=$($bin -L $in plan 801 2>&1; print exit $?)
check "arena plan N tells the running arena" test "$plan_said" = 'exit 0'
check "arena plan N on a ticket in a shut repo chip opens the chip" await shows 'Alp'
check "and the fold file no longer holds the repo" await eval '! grep -qx q $folded_file'
check "and its row is in view in the small window" see 'Alp'
: >$tmp/babylon
click ${(z)$(spot Alp)}
key w
check "w on a no goal row asks why it goes to next" see '❯'
key -l 'it is next'
key Enter
check "and Enter adds it to next, through babylon" await last 'next 801 --why it is next'
: >$tmp/babylon
key +
check "+ in no goal opens the new ticket in the middle column" await last 'new'
zselect -t 500
key Escape
normal
key b
key b
cp $tmp/run/babylon/board.json $tmp/board.foot
foot_json=$(<$tmp/board.foot)
foot_json=${foot_json/'{"tickets":['/'{"tickets":[{"id":934,"repo":"arena","title":"Foot","kind":"ticket","status":"try","stage":"landed","priority":"med","blocked_by":[],"checks":[{"n":1,"text":"the row says which of the two is which","result":null}]},'}
print -r -- "${foot_json%\}}"',"needs_you":[{"id":"try:934","kind":"try","ticket":934,"repo":"arena","text":"#934 arena  Foot","since":"2026-11-24T10:00:00Z","machine":"gate ✓","steps":['\
'{"n":1,"text":"the row says which of the two is which","result":null,"actions":[{"key":"y","label":"✓","argv":["babylon","tried","934","1","ok"]},{"key":"n","label":"✗","argv":["babylon","tried","934","1","no"],"needs":"words"}]}],'\
'"actions":[{"key":"x","label":"close untried","argv":["babylon","tried","934","skip"]}]},'\
'{"id":"push:arena:abc:0","kind":"push","ticket":null,"repo":"arena","text":"▲ arena: 2 unpushed","actions":[{"key":"⏎","label":"push","argv":["babylon","push","arena"]}]}]}' >$tmp/run/babylon/board.json
outer resize-window -t o -x 121 -y 40
click ${(z)$(spot '#934 arena')}
check "a click on a Your move item opens its card in the middle column" await shows 'q close'
check "with its check and its y" shows 'y ✓ it works'
check "while every Your move row stays, the open one marked" shows '▸▲ #934 arena'
see '▲ arena: 2 unpushed'
check "and no close untried anywhere" gone 'close untried'
: >$tmp/babylon
key y
check "y in the card answers its check, through babylon" await last 'tried 934 1 ok'
check "and, it being the last, closes the card" gone 'q close'
key -l ' '
check "space opens it again" await shows 'q close'
key n
check "and n asks for the words" see 'What went wrong\?'
key Escape
check "and Escape puts the words away" gone 'What went wrong\?'
key -l ' '
check "space closes the card" gone 'q close'
check "the item's row still there" shows '#934 arena'
click ${(z)$(spot '#934 arena')}
check "and a click opens it again" await shows 'q close'
click ${(z)$(spot '#934 arena')}
check "and the same click closes it" gone 'q close'
cp $tmp/board.foot $tmp/run/babylon/board.json
gone '#934'
outer resize-window -t o -x 121 -y 24
print -r -- '' >$tmp/.config/ficciones/theme/palette.sh
cp $tmp/board.slots $tmp/run/babylon/board.json
check "without a palette the plan is the plain one again" see '1 #7 +tlon +Lights +free now'
key Tab
key +
check "+ on the plan opens the goal modal under its prompt" see "what should be true when it's done"
key -l 'money on the bar'
check "what is typed, k among it, shows in its field" see 'money on the bar'
key Escape
check "esc ends typing, and the keys written are its buttons" see '⏎ plan  k keep  i type  q cancel'
key k
check "k keeps it: babylon idea is run with the text" await last 'idea money on the bar'
check "and the modal closes on babylon's answer" gone "what should be true when it's done"
key o
await orch_lit
key -l 'echo drawer-jkdufltb'
key Enter
check "o on Plan then, and what is typed straight after reaches the chat whole" await said orchestrator:orch drawer-jkdufltb
key M-h
gone '╭─ ○ orchestrator'
key M-b
gone 'in flight [0-9]'
key -l 'echo worker-jkdufltb'
key Enter
check "and the board closed, a worker's pane gets it whole too" await said alpha: worker-jkdufltb
key M-b
see 'in flight [0-9]'
cp $tmp/run/babylon/board.json $tmp/board.nolook
planless='"plan":{"now":[],"next":[],"goals":[],"landed_today":{"count":0,"newest":[]},"not_planned":{"count":0,"follow_ups":0,"by_repo":{}}}'
addplan() { local j=$(cat); print -r -- "${j%\}},$planless}" >$tmp/run/babylon/board.json }
print -r -- '{"tickets":[],"needs_you":[{"id":"ask:6","kind":"ask","ticket":307,"repo":"tlon","text":"#307 tlon  asks: Which?","doc":null,"actions":[{"key":"1","label":"One","argv":["babylon","answer","6","1"]}]}]}' | addplan
key ']'
see '#307 tlon  asks: Which\?'
key o
zselect -t 100
doc_window() { [[ $(inner list-windows -a -F '#{window_name}') == *doc* ]] }
check "o on a row that names no doc opens nothing" await eval '! doc_window'
key ']'
print -r -- '{"tickets":[],"needs_you":[{"id":"ask:6","kind":"ask","ticket":307,"repo":"tlon","text":"#307 tlon  asks: Which?","doc":"docs/none-jkdufltb.md","actions":[{"key":"1","label":"One","argv":["babylon","answer","6","1"]}]}]}' | addplan
check "a decision that names a doc keeps its place and wears a doc mark, with o to open it" see '#307 tlon  asks: Which\? ¶'
print -r -- '{"tickets":[],"needs_you":[{"id":"ask:6","kind":"look","ticket":307,"repo":"tlon","text":"#307 tlon  look at: docs/none-jkdufltb.md","doc":"docs/none-jkdufltb.md","actions":[{"key":"y","label":"looks good","argv":["babylon","call","answer_ask","{\"id\":6}"]},{"key":"c","label":"change","argv":null,"needs":"words"}]}]}' | addplan
check "a look at is an item with its doc named and o to open it" see 'o open   y looks good'
key ']'
see '▌ #307 tlon  look at'
key o
check "o opens its doc in the middle column, with no window of its own" await eval '! doc_window'
check "which says so when the file is not in the ticket's repo" see 'no such file:'
check "and the path under it, whole" see 'docs/none-jkdufltb.md'
key Escape
gone 'no such file'
mkdir -p $tmp/projects/tlon/.worktrees/t307-design/docs
print -r -- 'only-on-the-branch' >$tmp/projects/tlon/.worktrees/t307-design/docs/none-jkdufltb.md
key C-Space
key ']'
see '▌ #307 tlon  look at'
key o
check "a doc only in the ticket's worktree opens from there" see 'only-on-the-branch'
key Escape
gone 'only-on-the-branch'
# an item of any kind runs its action: a digest has no ticket and no repo, and ⏎ is its seen
print -r -- '{"tickets":[],"needs_you":[{"id":"digest:1795536000","kind":"digest","ticket":null,"repo":"","text":"digest: 3 landed","doc":"/tmp/none-jkdufltb.md","actions":[{"key":"⏎","label":"seen","argv":["babylon","digest","ok"]}]}]}' | addplan
key C-Space
key ']'
see 'o open   ⏎ seen'
: >$tmp/babylon
key Enter
check "⏎ on a digest runs its seen through babylon, though it names a doc" await last 'digest ok'
: >$tmp/babylon
see 'o open   ⏎ seen'
digest_row=$(screen | grep -n '⏎ seen' | head -1 | cut -d: -f1)
digest_line=$(screen | grep '⏎ seen' | head -1)
digest_prefix=${digest_line%%⏎ seen*}
mouse 0 $((${#digest_prefix} + 2)) $digest_row M
mouse 0 $((${#digest_prefix} + 2)) $digest_row m
check "and a click on its seen does the same" await last 'digest ok'
# a ticket to try is a tile with a row for each check, and y on each check settles it: the tile leaves
trying() {
  local one=${1:-null} two=${2:-null}
  print -r -- '{"tickets":[],"needs_you":[{"id":"try:931","kind":"try","ticket":931,"repo":"arena","text":"#931 arena  Lights","since":"2026-11-24T10:00:00Z","machine":"gate ✓  landed abc1234","steps":['\
'{"n":1,"text":"it is told","result":'$one',"actions":[{"key":"y","label":"✓","argv":["babylon","tried","931","1","ok"]},{"key":"n","label":"✗","argv":["babylon","tried","931","1","no"],"needs":"words"}]},'\
'{"n":2,"text":"it has buttons","result":'$two',"actions":[{"key":"y","label":"✓","argv":["babylon","tried","931","2","ok"]},{"key":"n","label":"✗","argv":["babylon","tried","931","2","no"],"needs":"words"}]}],'\
'"actions":[{"key":"x","label":"close untried","argv":["babylon","tried","931","skip"]}]}]}' | addplan
}
trying
check "a ticket to try is a tile in Your move, its checks a row each" see '── to try 1'
see '2 it has buttons'
key ']'
: >$tmp/babylon
key y
check "y on its first check settles it, through babylon" await last 'tried 931 1 ok'
trying '"ok"'
see '1 it is told +✓'
: >$tmp/babylon
key y
check "and then the next, the pick having moved on" await last 'tried 931 2 ok'
print -r -- '{"tickets":[],"needs_you":[]}' | addplan
check "a ticket tried on every check leaves Your move" gone '── to try'
# one ticket with an open ask and a try: each row opens its own item
both() {
  local ask=${1:+',"ask":{"id":11,"question":"When to reboot?","options":["alpha","beta"]}'}
  local items='{"id":"try:935","kind":"try","ticket":935,"repo":"arena","text":"#935 arena  Both","since":"2026-11-24T10:00:00Z","machine":"gate ✓","steps":[{"n":1,"text":"the flood is gone","result":null,"actions":[{"key":"y","label":"✓","argv":["babylon","tried","935","1","ok"]},{"key":"n","label":"✗","argv":["babylon","tried","935","1","no"],"needs":"words"}]}],"actions":[{"key":"x","label":"close untried","argv":["babylon","tried","935","skip"]}]}'
  [[ -n $1 ]] && items='{"id":"ask:11","kind":"ask","ticket":935,"repo":"arena","text":"#935 arena  asks: When to reboot?","since":"2026-11-24T10:00:00Z","actions":[{"key":"1","label":"alpha","argv":["babylon","answer","11","1"]},{"key":"2","label":"beta","argv":["babylon","answer","11","2"]}]},'$items
  print -r -- '{"tickets":[{"id":935,"repo":"arena","title":"Both","kind":"ticket","status":"try","stage":"landed","priority":"med","blocked_by":[],"checks":[{"n":1,"text":"the flood is gone","result":null}],"try":{"changed":"The flood stops.","steps":["Look"],"right":"quiet","wrong":"loud"}'$ask'}],"needs_you":['$items']}' | addplan
}
outer resize-window -t o -x 121 -y 40
key o
gone 'o close'
both ask
key ']'
see 'asks: When to reboot'
key Enter
check "a ticket's ask row opens its question and options, not its try sheet" await shows '2 beta'
check "with no try sheet beside them" gone 'TRY IT'
: >$tmp/babylon
key 1
check "1 answers the ask, through babylon" await last 'answer 11 1'
both
gone 'asks: When to reboot'
check "and the try row stays in Your move" await shows '── to try'
print -r -- '{"tickets":[],"needs_you":[]}' | addplan
gone '── to try'
# a check to look at the diff: o opens meatcheck on the landed range; its comments come back as the ✗, none as ✓
looking() {
  print -r -- '{"tickets":[],"needs_you":[{"id":"try:932","kind":"try","ticket":932,"repo":"arena","text":"#932 arena  Doors","since":"2026-11-24T10:00:00Z","machine":"gate ✓","steps":['\
'{"n":1,"text":"look at the change: is the retry bounded","kind":"look","range":"abc123^..abc123","result":null,"actions":[{"key":"y","label":"✓","argv":["babylon","tried","932","1","ok"]},{"key":"n","label":"✗","argv":["babylon","tried","932","1","no"],"needs":"words"}]}],'\
'"actions":[]}]}' | addplan
}
looking
see 'o open'
key ']'
: >$tmp/babylon
key o
check "o on a look check runs meatcheck on the landed range, with the check's words" await eval '[[ -f $tmp/meatcheck ]] && grep -q -- "--prompt look at the change: is the retry bounded" $tmp/meatcheck && grep -q -- "diff abc123^..abc123" $tmp/git'
check "and no comments is a ✓, through babylon" await last 'tried 932 1 ok'

print -r -- $'comments[2]{end_line,id,path,"side,omitempty",start_line,text}:\n  12,1,src/a.zig,"",12,loop never ends\n  5,2,src/b.zig,"",3,"why, \\"here\\"\\nsecond"' >$tmp/comments
: >$tmp/babylon
key b
key b
see 'o open'
key ']'
key o
check "and its comments are the ✗'s words, an anchored line each" await eval '[[ $(<$tmp/babylon) == *"tried 932 1 no src/a.zig:12: loop never ends"* && $(<$tmp/babylon) == *"src/b.zig:3-5: why, \"here\" second"* ]]'
rm -f $tmp/comments
# a check that holds a command gets r: it shows the command and runs nothing until ⏎, the command
# runs in a window of its own, and the tile says its exit and last lines
running() {
  print -r -- '{"tickets":[],"needs_you":[{"id":"try:933","kind":"try","ticket":933,"repo":"arena","text":"#933 arena  Echo","since":"2026-11-24T10:00:00Z","machine":"gate ✓","steps":['\
'{"n":1,"text":"say `echo hi` and read it","result":null,"actions":[{"key":"y","label":"✓","argv":["babylon","tried","933","1","ok"]},{"key":"n","label":"✗","argv":["babylon","tried","933","1","no"],"needs":"words"}]}],'\
'"actions":[]}]}' | addplan
}
running
key b
key b
see 'r run'
key ']'
key r
check "r shows the command first, with ⏎ run · esc cancel" see 'run check 1\?'
check "and nothing has run before ⏎" eval '[[ ! -e $tmp/run/babylon/check-933-1 ]]'
key Escape
check "esc puts it away" gone 'run check 1\?'
key ']'
key r
see 'run check 1\?'
sessions_before=$(inner list-sessions -F '#{session_id}')
key Enter
check "⏎ runs it in the middle column: the strip gets no window of its own" await shows 'check 1: exit 0'
check "and none named check #933 is made" eval '[[ $(inner list-windows -a -F "#{window_name}") != *"check #933"* ]]'
check "and the tile says its exit and its last lines" await shows 'check 1: exit 0'
check "with what the command printed" shows '^.*▌? *hi *│? *$'
check "and y is still the human's to press" shows 'y ✓'
for s in $(inner list-sessions -F '#{session_id}'); [[ $sessions_before == *$s* ]] || inner kill-session -t $s
key M-b
cp $tmp/board.nolook $tmp/run/babylon/board.json
# home takes the plan as it opens, so arena must have read it back before b
zselect -t 300

inner new-session -d -s gamma -n g1 sh
for n in 2 3 4 5 6 7; inner new-window -t gamma -n g$n sh
claude gamma:g6 prompt
$bin -L $in show $(inner display -p -t gamma:g6 '#{pane_id}')
await shows ' 6 g6 '

g6=$(inner display -p -t gamma:g6 '#{pane_id}')
plan_up='in flight [0-9]'
plan_at() { $bin -L $in plan $1; see "$plan_up" }
last() { [[ -f $tmp/babylon && $(tail -1 $tmp/babylon) == $1 ]] }
print -r -- '' >$tmp/.config/ficciones/theme/palette.sh
outer resize-window -t o -x 121 -y 24
nowplan() { print -r -- '{"tickets":[{"id":920,"repo":"arena","title":"Peek me","kind":"ticket","status":"doing","priority":"med","claimed_by":"'$g6'","claimed_at":"'$1'","blocked_by":[]'"$2"'}],"plan":{"now":[{"ticket":920,"repo":"arena","title":"Peek me","state":"building","since":"'$1'","pane":"'$g6'"}],"next":[],"goals":[],"landed_today":{"count":0,"newest":[]},"not_planned":{"count":0,"follow_ups":0,"by_repo":{}}}}' >$tmp/run/babylon/board.json }
nowplan $(date -u -d '2 days ago' +%Y-%m-%dT%H:%M:%SZ)
zselect -t 200
$bin -L $in plan 920
now=$(date -u +%Y-%m-%dT%H:%M:%SZ)
nowplan $now ',"handed_off_from":"%407","handed_off_at":"'$now'"'
zselect -t 150
plan_at 920
key ' '
key ' '
check "a row handed off from a pane says so in its modal" await shows 'handed off from %407'
check "whose foot has H for asking its Claude to hand off" see 'H hand off'
key H
sent() { [[ $(inner capture-pane -J -p -t gamma:g6) == *'hand #920 off: commit what is uncommitted as a WIP commit, then call handoff.'* ]] }
check "H in it types the ask into the Claude holding it, as babylon's own does" await sent
key Escape
mkdir -p $tmp/.config/ficciones/theme
for name in AMBER VIOLET AMBERDIM EMBERDIM INK DIM GREY SURFACE0 SURFACE2 SURFACE3 SURFACE4 BG CYAN MOSS PINK RED; do print -r -- "PALETTE_$name=#808080"; done >$tmp/.config/ficciones/theme/palette.sh
outer resize-window -t o -x 200 -y 40
asking() { print -r -- '{"id":'$1',"repo":"arena","title":"'$2'","kind":"ticket","status":"todo","priority":"med","blocked_by":[],"ask":{"id":'$3',"question":"Which one?","options":["alpha","beta","gamma"]}}' }
print -r -- '{"tickets":['"$(asking 920 'Peek me' 6)"','"$(asking 921 'Second' 7)"','"$(asking 922 'Third' 8)"'],"plan":{"now":[],"next":[],"goals":[],"landed_today":{"count":0,"newest":[]},"not_planned":{"count":3,"follow_ups":0,"by_repo":{"arena":3}}}}' >$tmp/run/babylon/board.json
zselect -t 300
$bin -L $in plan 920
see '#922 Third'
key ' '
key ' '
check "a ticket with an open ask: its modal opened from a row lists every option, a row each" see '3 gamma'
check "and ⏎ in its foot is labelled for answering the lit option" see '⏎ answer 1'
: >$tmp/babylon
key 2
check "a number answers that option through babylon" await last 'answer 6 2'
check "and puts the modal away" gone '3 gamma'
$bin -L $in plan 921
see '#922 Third'
key ' '
key ' '
await shows '3 gamma'
: >$tmp/babylon
gamma_row=$(screen | grep -n -m1 -E '3 gamma' | cut -d: -f1)
mouse 0 $(( $(colof $gamma_row '3 gamma') + 1 )) $gamma_row M
check "a click on an option answers it" await last 'answer 7 3'
$bin -L $in plan 922
see '#922 Third'
key ' '
key ' '
await shows '3 gamma'
: >$tmp/babylon
key Enter
check "and ⏎ answers the lit one, which its label said" await last 'answer 8 1'
key Escape
print -r -- '{"tickets":[{"id":930,"repo":"arena","title":"Lights","kind":"ticket","status":"try","stage":"landed","priority":"med","blocked_by":[],'\
'"checks":[{"n":1,"text":"it is told","result":null},{"n":2,"text":"it has buttons","result":null}]}],"plan":{"now":[],"next":[],"goals":[],"landed_today":{"count":0,"newest":[]},"not_planned":{"count":0,"follow_ups":0,"by_repo":{}}}}' >$tmp/run/babylon/board.json
zselect -t 300
$bin -L $in plan 930
check "a ticket to try, opened from Plan, has a modal listing its checks, a row each" await shows '○ 2 it has buttons'
clipped() { [[ $(outer show-buffer 2>/dev/null) == $1 ]] }
key Y
check "Y copies the picked check through OSC 52" await clipped 'it is told'
check "and the foot says how much" await shows 'copied 10 chars'
check_row=$(rowof '○ 2 it has buttons')
check_col=$(colof $check_row '○ 2 it has buttons')
mouse 0 $check_col $check_row M
mouse 32 $(( check_col + 17 )) $check_row M
mouse 0 $(( check_col + 17 )) $check_row m
check "a drag over a check in the modal copies what it covers" await clipped '○ 2 it has buttons'
check "and the foot says how much" await shows 'copied 18 chars'
mouse 0 $(( check_col + 8 )) $check_row M
mouse 0 $(( check_col + 8 )) $check_row m
mouse 0 $(( check_col + 8 )) $check_row M
mouse 0 $(( check_col + 8 )) $check_row m
check "and a second press on a word copies the word" await clipped 'has'
: >$tmp/babylon
key j
key y
check "j picks a check and y says it works, through babylon" await last 'tried 930 2 ok'
key j
key n
check "n opens a modal asking what went wrong, the check quoted in it" see 'What went wrong\?'
check "with send and cancel in its foot" see '⏎ send it back .*esc cancel'
check "and its new line key in the box" see 'shift\+⏎ new line'
see 'check 2: it has buttons'
key -l 'too late'
key -l $'\e[27;2;13~'
key -l 'by a day'
check "shift+⏎ starts a new line, both lines in the box" see '  by a day'
key Enter
check "and ⏎ sends it back with the words as written, the new line in them, through babylon" await eval 'grep -qx "tried 930 2 no too late" $tmp/babylon && [[ $(tail -1 $tmp/babylon) == "by a day" ]]'
check "and the modal is gone" gone 'What went wrong\?'
print -r -- '' >$tmp/.config/ficciones/theme/palette.sh
outer resize-window -t o -x 121 -y 24
key Escape
key M-b
key M-q
gone 'in flight [0-9]'
key M-q
check "and leaves as any other" see 'EXIT 0'

# a new build installed under a running arena: it runs again in place, where it was
mkdir -p $tmp/run/babylon $tmp/run/arena
print -r -- '{"tickets":[{"id":7,"repo":"arena","title":"Lights","kind":"ticket","status":"todo","priority":"med","blocked_by":[]},'\
'{"id":9,"repo":"arena","title":"Doors","kind":"ticket","status":"todo","priority":"med","blocked_by":[]}],"backlog":[],"plan":{"now":[],"next":[{"ticket":9,"repo":"arena","title":"Doors","why":"","set_by":"orchestrator","waits_on":[]}],"goals":[],"landed_today":{"count":0,"newest":[]},"not_planned":{"count":0,"follow_ups":0,"by_repo":{}}}}' \
  >$tmp/run/babylon/board.json
cp $bin $tmp/arena-copy
install_build() { cp $bin $tmp/arena-next && mv $tmp/arena-next $tmp/arena-copy }
outer kill-session -t o
outer new-session -d -s o -x 121 -y 24 \
  "env -u TMUX HOME=$tmp XDG_RUNTIME_DIR=$tmp/run ARENA_REDUCED_MOTION=1 $tmp/arena-copy -L $in alpha 2>$tmp/update-err; echo EXIT \$?; cat"
check "the terminal's server outlives the session restarted in it" eval '[[ $(outer display -p "#{pid}") == $outer_pid ]]'
see ' alpha  '
key M-b
see 'in flight [0-9]'
print 822 >$tmp/run/arena/installed
install_build
check "a build installed under arena is run again, and the foot says which ticket's" await shows 'arena updated · #822'
check "with no exit between" hides '^EXIT'
check "and Plan is still open where it was" see 'in flight [0-9]'
key M-!
see "What's wrong\?"
install_build
zselect -t 350
check "a build installed while a prompt is open waits for it" shows "What's wrong\?"
key Escape
check "and is run once it closes" await shows 'arena updated'
key M-b
key M-q
gone 'in flight [0-9]'
key M-q
check "and it leaves as any other" see 'EXIT 0'
check "with nothing said on its error stream" test ! -s $tmp/update-err

# a crash gives the terminal back as a quit does: no mouse reports typed into the shell
outer new-session -d -s p -x 100 -y 24 \
  "env -u TMUX HOME=$tmp XDG_RUNTIME_DIR=$tmp/run ARENA_REDUCED_MOTION=1 ARENA_TEST_PANIC=1 $bin -L $in alpha 2>$tmp/panic-err; echo EXIT \$?; cat"
panicked() { [[ $(outer capture-pane -p -t p) == *'EXIT 134'* ]] }
check "a panic aborts arena" await panicked
modes() { [[ $(outer display -p -t p '#{mouse_any_flag}#{mouse_all_flag}#{mouse_sgr_flag}#{alternate_on}#{cursor_flag}') == 00001 ]] }
check "and leaves mouse reporting off, the alternate screen left and the cursor shown" await modes
check "and says why" grep -q ARENA_TEST_PANIC $tmp/panic-err

# an in-flight row on the plan has one state word and no workspace line, and Enter on it goes to its Claude
mkdir -p $tmp/.config/ficciones/theme
for name in AMBER VIOLET AMBERDIM EMBERDIM INK DIM GREY SURFACE0 SURFACE2 SURFACE3 SURFACE4 BG CYAN MOSS PINK RED; do print -r -- "PALETTE_$name=#808080"; done >$tmp/.config/ficciones/theme/palette.sh
held_pane=$(inner list-panes -s -t alpha -F '#{pane_id}' | sed -n 2p)
held_index=$(inner display -p -t $held_pane '#{window_index}')
print -r -- '{"tickets":[{"id":701,"repo":"arena","title":"Held building","kind":"ticket","status":"doing","priority":"med","blocked_by":[]}],"plan":{"now":[{"ticket":701,"repo":"arena","title":"Held building","state":"building","since":"2026-11-24T10:00:00Z","pane":"'$held_pane'"}],"next":[],"goals":[],"landed_today":{"count":0,"newest":[]},"not_planned":{"count":0,"follow_ups":0,"by_repo":{}}}}' >$tmp/run/babylon/board.json
outer kill-session -t o
outer new-session -d -s o -x 121 -y 24 \
  "env -u TMUX HOME=$tmp XDG_RUNTIME_DIR=$tmp/run ARENA_REDUCED_MOTION=1 $bin -L $in 2>$tmp/err; echo EXIT \$?; cat"
check "an in-flight row shows its ticket" see "Held building"
check "and no session, window and pane line under it" eval '! settled | grep -q "alpha:$held_index · $held_pane"'
inner select-window -t alpha:one
key Enter
check "and Enter on it opens that pane in the middle column" await shows 'NORMAL  i type   d changes   esc back'

exit $((fails > 0))
