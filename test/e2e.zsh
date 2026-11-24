#!/usr/bin/env zsh
# arena end to end: it runs in one private tmux server, standing in for the terminal, against
# sessions in another. Nothing here touches the tmux server or the configuration of whoever runs it.
zmodload zsh/zselect

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
print -r -- $'#!/bin/sh\necho "$@" >>'$tmp$'/babylon\n[ "$1" = answer ] && [ -e '$tmp$'/refuse ] && { echo "babylon: no session to answer" >&2; exit 1; }\n[ "$1" = give ] && [ -e '$tmp$'/refuse ] && { echo "babylon: the Claude in $3 is mid-turn" >&2; exit 1; }\n[ "$1" = start ] && [ -e '$tmp$'/refuse-start ] && { echo "babylon: ticket #$2 is claimed by pane %1010" >&2; exit 1; }\n[ "$1" = next ] && [ -e '$tmp$'/refuse-next ] && { echo "babylon: ticket #$2 is claimed by pane %1010" >&2; exit 1; }\n[ "$1" = detail ] && printf \'#%s Lights\\n\\nthe whole of it\\n\' "$2"\nexit 0' >$tmp/bin/babylon
chmod +x $tmp/bin/babylon
export PATH=$tmp/bin:$PATH

inner() { tmux -L $in -f /dev/null "$@" }
outer() { tmux -L $out -f /dev/null "$@" }
# kill-server leaves the socket file behind
cleanup() {
  [[ -n $server ]] && kill -CONT $server 2>/dev/null
  inner kill-server 2>/dev/null
  outer kill-server 2>/dev/null
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
# button, column and row from 1, then M to press or move and m to let go
mouse() { outer send-keys -t o -l $'\e'"[<$1;$2;$3$4" }

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
inner set -g default-command sh
inner new-window -t alpha -n two sh
inner new-window -t alpha -n three sh
inner new-session -d -s beta -n solo sh
inner select-window -t alpha:one

# An empty HOME: no machine palette, so colours are the fallback ones. No motion: no slides to wait out.
outer new-session -d -s o -x 121 -y 24 \
  "env -u TMUX HOME=$tmp XDG_RUNTIME_DIR=$tmp/run ARENA_REDUCED_MOTION=1 $bin -L $in alpha 2>$tmp/err; echo EXIT \$?; cat"
outer set -s set-clipboard on
# what arena writes, for what a picture of the screen does not show
outer pipe-pane -t o "cat >$tmp/raw"

check "the strip shows, the first column flush against the rail" see '^╭─ sessions ─+╮ ╭─ 1 one '
foot() { local s=$(screen); [[ $(sed -n 3p <<<$s) == '│ alpha '* && $(sed -n 4p <<<$s) == '│ beta '* && $(sed -n 20p <<<$s) == ├─*┤* && $(sed -n 21p <<<$s) == '│ + new '* && $(sed -n 22p <<<$s) == '│ ≡ menu '* ]] }
check "the rail keeps + new and the menu at its foot" await foot
dots() { local s=$(screen); [[ $(sed -n 23p <<<$s) == ╰* && $(sed -n 24p <<<$s) =~ "^ {76}$1 *\$" ]] }
check "a row of its own under the strip has a dot per window, centred on it" await dots '● ○ ○'
# the column, from 1, where $1 starts on the screen's last row
col() { local l=$(screen | sed -n 24p); local pre=${l%%$1*}; print $(( ${#pre} + 1 )) }
mouse 35 60 24 M
check "the pointer on it has each window's number and name in place of its dot" see '^ +1 one +2 two +3 three *$'
x=$(col '2 two')
mouse 0 $x 24 M
mouse 0 $x 24 m
key -l i
mouse 35 60 10 M
check "a click on a name goes to its window, and away from the row it is dots again" await dots '○ ● ○'
mouse 35 60 24 M
see '1 one'
mouse 65 60 24 M
mouse 35 60 10 M
check "the wheel down on it goes to the next window" await dots '○ ○ ●'
zselect -t 50
mouse 35 60 24 M
mouse 65 60 24 M
mouse 35 60 10 M
check "and stops at the last" await dots '○ ○ ●'
mouse 35 60 24 M
see '1 one'
zselect -t 30
mouse 64 60 24 M
mouse 35 60 10 M
check "the wheel up, the one before" await dots '○ ● ○'
mouse 35 60 24 M
see '1 one'
x=$(col '1 one')
mouse 0 $x 24 M
mouse 0 $x 24 m
key -l i
mouse 35 60 10 M
await dots '● ○ ○'

# insert and normal: every key of a sentence is the pane's, or none is
typed() { [[ $(screen | grep -c -- "$1") -ge $2 ]] }
key -l 'echo jhklqnb'
key Enter
check "in insert a sentence with j h k l q n b reaches the pane whole" await typed 'jhklqnb' 2
key C-Space
check "Ctrl+Space is normal mode, NORMAL in the corner and its key in the dots' row" await shows '^NORMAL .*i insert'
key -l 'echo xjhklqnb'
zselect -t 50
check "in normal none of it reaches the pane, and q does not quit" hides 'xjhklqnb'
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
mouse 0 5 3 M
mouse 0 5 3 m
check "a click on the rail is normal" see '^NORMAL'
key -l i

# the rail's pick in normal mode: it moves, the strip does not, and Enter goes
strip() { screen | sed -n '1,22s/^.\{22\}//p' }
key C-Space
see '^NORMAL'
before=$(strip)
key -l j
check "in normal mode j puts the pick on the next session, and the keys are written under the strip" await shows '^│▌beta '
check "and the key bar replaces the dots" await shows '^NORMAL .*j k pick'
key -l k
check "k moves it back" await shows '^│▌alpha '
key -l j
see '^│▌beta '
check "the strip's text is unchanged" eval '[[ $(strip) == "$before" ]]'
key Enter
check "Enter goes to the pick, in insert" await shows '^│ beta'
check "and into insert" gone '^NORMAL'
key C-Space
see '^NORMAL'
key -l k
key Enter
see '^│ alpha'

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

inner new-session -d sh
last() { screen | sed -n 5p | grep -qE '^│ [0-9]+ +1 │' }
check "a new session goes under the others in the rail" await last
inner kill-session -t "$(inner list-sessions -F '#{session_name}' | grep -E '^[0-9]+$')"
gone '^│ [0-9]+ +1 │'

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
await shows '╭─ sessions ─+╮ ╭─ 1 one '
mousing() { [[ $(inner display -p -t $1 '#{mouse_standard_flag}') == 1 ]] }
await mousing alpha:one
# the pane's third column, second row: its frame starts at the title's corner
at=$(( $(screen | awk 'NR == 1 { print index($0, "╭─ 1 one") }') + 3 ))
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
# a capture taken mid-frame can lack the title, and index's 0 would click the rail
titled() { two=$(screen | awk 'NR == 1 { print index($0, "╭─ 2 two") }'); (( two > 0 )) }
check "window two's title is on the top line, to click under" await titled
two=$((two + 3))
mouse 0 $two 6 M
mouse 0 $two 6 m
current() { [[ $(inner display -p -t alpha '#{window_name}') == $1 ]] }
check "the click on window two makes it the current window" await current two
check "and the strip comes to rest on it" await dots '○ ● ○'
zselect -t 50
untouched() { ! inner capture-pane -pJ -t alpha:two | grep -qF '[<0;' }
check "a click on a window out of focus focuses it, and its program is not clicked" untouched
check "window two shows its prompt" await shows '│sh-[0-9.]+\$ +│'
inner send-keys -t alpha:two clear Enter

print -rn -- $'\e[?1003h\e[?1006h' >$tmp/any
inner send-keys -t alpha:two "clear; stty -echo -icanon; echo shift-copy-target; cat $tmp/any; timeout 3 cat -v; printf '\\033[?1006l\\033[?1003l'; stty sane" Enter
check "window two shows the text to copy, whole" await shows 'shift-copy-target'
zselect -t 30
row=$(screen | grep -n 'shift-copy-target' | head -1 | cut -d: -f1)
col=$(screen | awk -v r=$row 'NR == r { print index($0, "shift-copy-target") }')
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
see '^╭─ sessions ─+╮ ╭─ 1 one '

wide() { [[ $(inner display -p -t alpha:one '#{window_width} #{@arena_width}') == $1 ]] }
# a ; that ends an argument ends the command for tmux, unless escaped
key -l $'\e\\;'
check "Alt+; makes the window narrower" see '╭─ 1 one ─{49}╮'
check "and tmux has it that wide, and keeps the width" await wide '57 70'
key "M-'"
check "Alt+' makes it wider" see '╭─ 1 one ─{57}╮'

windows() { [[ $(inner list-windows -t $1 -F '#{window_name}' | tr '\n' ' ') == "$2 " ]] }
mouse 0 41 1 M
mouse 32 111 1 M
mouse 32 113 1 M
mouse 32 116 1 M
mouse 0 116 1 m
check "a title dropped on another column takes its place, and goes no further" await windows alpha 'two one three'
see '─╮ ╭─ 2 one '
mouse 0 49 1 M
mouse 32 39 1 M
mouse 0 39 1 m
check "and back" await windows alpha 'one two three'
see '^╭─ sessions ─+╮ ╭─ 1 one '
mouse 0 41 1 M
mouse 32 5 4 M
mouse 0 5 4 m
check "a title dropped on a session of the rail sends its window there" await windows beta 'solo one'
inner move-window -s beta:one -t alpha:0
inner select-window -t alpha:one
see '^╭─ sessions ─+╮ ╭─ 1 one '

key M-l
check "Alt+l focuses the next window, its neighbour peeking" see '─╮ ╭─ 2 two ─'
key 'echo e2e-$((6*7))' Enter
check "typing reaches the focused pane" see 'e2e-42'
key M-j
check "Alt+j goes to the next session" see '╭─ 1 solo '
key M-k
check "Alt+k comes back, to the window left" see '╭─ 2 two '
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
key M-j
see '╭─ 1 solo '
check "a pane showing lines like tmux's own replies is drawn whole" see '│%begin 1 1 1 '
key M-k
see '╭─ 2 two '

rail() { [[ $(screen | sed '/├─ agents/q' | grep -oE '^│ (alpha|beta) ' | tr -d '│ \n') == $1 ]] }
order() { [[ $(inner list-sessions -F '#{@arena_order}#{session_name}' | sort | tr -d '\n') == $1 ]] }
key M-J
check "Alt+J moves the session down the rail" await rail betaalpha
check "and its place is kept in tmux" await order 1beta2alpha
key M-K
check "Alt+K moves it up" await rail alphabeta

sessions() { [[ $(inner list-sessions | wc -l) -eq $1 ]] }
mouse 0 5 21 M
mouse 0 5 21 m
check "a click on + new makes a session" await sessions 3
see '│.[0-9]+ +1 │'
mouse 1 5 5 M
mouse 1 5 5 m
check "a middle click on a session asks before closing it" see 'Close session [0-9]+\?'
key y
check "and closes it" await sessions 2
key M-k
see '╭─ 2 two '

key M-m
check "Alt+m opens the menu" see 'New window +n'
key Escape
check "Escape closes it" gone 'New window +n'

panes() { [[ $(inner list-panes -t alpha:two | wc -l) -eq $1 ]] }
key M-m
key v
check "the menu splits the pane" await panes 2
check "and the split is drawn" see 'echo e2e.* │sh-[0-9.]+\$ +│'
wrote() { grep -q -- "$1" $tmp/raw }
first() { [[ $(inner list-panes -t alpha:two -F '#{pane_width}' | head -1) -eq $1 ]] }
mouse 35 79 5 M
check "over the line between panes the pointer is the one for resizing" await wrote $'\e]22;ew-resize'
mouse 0 79 5 M
mouse 32 72 5 M
mouse 0 72 5 m
check "dragging the line resizes the panes" await first 25

key M-m
key r
key 'renamed' Enter
check "the menu renames the window" see '╭─ 2 renamed '

key M-p
key 'solo' Enter
check "Alt+p jumps to a window of another session" see '╭─ 1 solo '

key M-o
check "Alt+o shows every session's windows" see '╭─ 1 one ─+╮ ╭─ 2 renamed '
mouse 0 101 4 M
mouse 32 41 4 M
mouse 0 41 4 m
check "a picture dropped on another takes its place" await windows alpha 'three one renamed'
see '╭─ 1 three ─+╮ ╭─ 2 one '
mouse 0 41 4 M
mouse 32 101 4 M
mouse 0 101 4 m
check "and back" await windows alpha 'one renamed three'
see '╭─ 1 one ─+╮ ╭─ 2 renamed '
mouse 0 101 4 M
mouse 32 41 12 M
mouse 0 41 12 m
check "on one of another session, it goes there in front of it" await windows beta 'three solo'
see '╭─ 1 three ─+╮ ╭─ 2 solo '
mouse 0 41 12 M
mouse 32 111 4 M
mouse 0 111 4 m
check "and on the rest of a session's row, to that session's end" await windows alpha 'one renamed three'
see '╭─ 3 three '
key Escape
check "Escape leaves the overview" see '╭─ 1 solo ─{40}'

zselect -t 400
key 'printf "\033[%dGX\bY\n" $(tput cols)' Enter
check "a step back from the last column lands where tmux puts it" see ' Y│$'

# arena's Claude Code hook, as Claude Code runs it in a pane of the session: event, then its JSON
claude() { print -r -- ${3:-'{}'} | TMUX="$(inner display -p '#{socket_path}'),0,0" TMUX_PANE=$1 sh $root/hooks/claude-state.sh $2 }
inner send-keys -t alpha:one 'echo news' Enter
zselect -t 250
check "output alone marks nothing in the rail" shows '│ alpha +3 │'
claude alpha:one prompt
check "a Claude working marks its session ◐" see '│ alpha +◐ +3 │'
claude alpha:one stop '{"background_tasks": [{"id": "b1", "status": "running"}]}'
check "between turns, with work in the background, ◔" see '│ alpha +◔ +3 │'
claude alpha:one stop '{"last_assistant_message": "\"status\": \"running\"", "background_tasks": []}'
check "done and not looked at, ◉, whatever its last words say" see '│ alpha +◉ +3 │'
claude alpha:three waiting
check "waiting on an answer, ▲, over a done one" see '│ alpha +▲ +3 │'
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
check "a session's end takes its mark off" see '│ alpha +3 │'
unset_all() { [[ -z $(inner show -p -t alpha:one | grep arena_claude) ]] }
check "and every option the hook set" unset_all
line() { sed -n $1p <<<$(screen) }
claude alpha:three waiting '{"message": "Claude needs your permission to use Bash"}'
claude alpha:one prompt '{"prompt": "go"}'
claude beta:solo tool '{"tool_name": "Read", "tool_input": {"file_path": "/a/b.zig"}}'
inner set -p -t alpha:three @arena_review changes
listed() {
  [[ $(line 6) == ├─' agents · urgency '─*┤* && $(line 7) == '│ alpha '* && $(line 8) =~ '^│ ▲ three +[0-9]+s │' &&
    $(line 9) == '│   allow Bash '* && $(line 10) == '│   branch unknown  ✗ changes '* && $(line 11) =~ '^│ ◐ one +[0-9]+s │' &&
    $(line 12) == '│   go '* && $(line 13) == '│ beta '* && $(line 14) =~ '^│ ◐ solo +[0-9]+s │' &&
    $(line 15) == '│   Read b.zig '* ]]
}
check "the rail lists each session's Claudes under a rule of their own, each over what it is doing and its review" await listed
inked() { sed -n $1p <<<$(outer capture-pane -ep -t o) }
lit() { [[ $(inked 14) == *$'\e[1;7m'*' ◐ solo '* && $(inked 15) == *$'\e[1;7m'*' Read b.zig '* && $(inked 13) != *$'\e[1;7m'* && $(inked 11) != *$'\e[1;7m'* ]] }
check "the Claude in view has all its rows lit, and its session's header is not" lit
bar_whole() { [[ $(inked 18) =~ $'\e\\[1;7m(\e\\[[0-9;]*m)*   ◔ a shell' ]] }
claude alpha:renamed prompt '{"prompt": "more"}'
for w in alpha:one alpha:renamed beta:solo; inner set -p -t $w @arena_claude_background 'a shell'
check "more than it has rows for, the list scrolls to the Claude in view" await eval '[[ $(line 16) =~ "^│ ◐ solo " && $(line 18) =~ "^│   ◔ a shell +│" ]] && ! screen | grep -q "▲ three"'
check "and the bar runs unbroken from the left through its background row" bar_whole
for w in alpha:one beta:solo; inner set -pu -t $w @arena_claude_background
claude alpha:renamed end
inner set -pu -t alpha:three @arena_review
claude alpha:three end
claude beta:solo waiting '{"message": "Claude is waiting for your input"}'
beta_first() {
  [[ $(line 7) == '│ beta '* && $(line 8) =~ '^│ ▲ solo ' && $(line 9) == '│   is waiting for your input '* &&
    $(line 10) == '│ alpha '* && $(line 11) =~ '^│ ◐ one ' ]]
}
check "the session whose Claude most wants looking at comes first" await beta_first
claude alpha:one end
claude beta:solo end
check "with no Claudes left the rule over them goes" gone '├─ agents'
claude alpha:one waiting
claude alpha:three waiting
check "a session with several Claudes at its mark counts them" see '│ alpha +▲2 +3 │'
claude alpha:one end
claude alpha:three end
inner new-window -d -t beta -n loud sh
inner set -w -t beta:loud monitor-activity on
inner send-keys -t beta:loud 'echo out' Enter
check "a window out of view that tmux saw output in, where it watches for it, marks its session #" see '│ beta +# +2 │'
inner send-keys -t beta:loud "printf '\\a'" Enter
check "and one that rang its bell, !" see '│ beta +! +2 │'
inner kill-window -t beta:loud

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
check "which the rail shows in place of its window's name" see '│ ◐ Started Here +[0-9]+s │'
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
check "the rail has its last words under it" see '│   Done. It loads '
check "and a row for each subagent in the background" see '│   ◔ Explore the rail +│'
check "with its shells at the foot" see '│   ◔ 1 shell: sleep 9 +│'
check "with a shell and nothing heard from its agent, its mark is still" see '│ ◔ Named By Hand '
claude alpha:one tool '{"agent_id": "a1", "agent_type": "Explore", "tool_name": "Grep", "tool_input": {"pattern": "rail"}}'
check "a subagent's tool leaves the session as it was" [ "$(opt doing)" = '' -a "$(inner show -pqv -t alpha:one @arena_claude)" = background ]
check "and what runs as it was" [ "$(opt agents)" = 'Explore the rail' -a "$(opt background)" = '1 shell: sleep 9' ]
check "but with its agent at work it is drawn working" see '│ ◐ Named By Hand '
check "and its subagent's row with it, its shells' still" await eval 'shows "│   ◐ Explore the rail +│" && shows "│   ◔ 1 shell: sleep 9 +│"'
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
check "which the rail has beside its last words" see '│   Done. It loads +1h2m │'
claude alpha:one prompt '{"prompt": "go on"}'
inner set -p -t alpha:one @arena_claude_at $(($(date +%s) - 700))
check "working with nothing heard for ten minutes, it is quiet" see '│   go on +quiet 11m │'
check "and its branch under that, its context at the right" see "│   $(worked_on | cut -c1-12).* +253k ctx │"
inner set -p -t alpha:one @arena_claude_ctx 88
check "the share of its budget, where its status line says it" see "│   $(worked_on | cut -c1-12).* +88% ctx │"
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
# stands in for Claude Code's list of agents at the foot of its screen: Down from its box goes
# to the row of shells, then into the list, and Enter shows the agent the pointer is on
cat >$tmp/bin/fake-agents <<'EOF'
#!/usr/bin/env zsh
rows=(main 'general-purpose  Explore the rail' 'general-purpose  Review it')
at=0 shown=1
while true; do
  out=$'\e[H\e[2J❯ box\n  auto mode on · 1 shell'
  for i in 1 2 3; do
    [[ $at == $((i + 1)) ]] && p='❯' || p=' '
    [[ $shown == $i ]] && m='●' || m='◯'
    out+=$'\n'"$p $m $rows[i]"
  done
  print -rn -- "$out"
  read -sk1 c || exit
  case $c in
    $'\e')
      read -sk2 c
      [[ $c == '[B' && $at -lt 4 ]] && at=$((at + 1))
      [[ $c == '[A' && $at -gt 0 ]] && at=$((at - 1))
      ;;
    $'\n' | $'\r') [[ $at -gt 1 ]] && shown=$((at - 1)) ;;
  esac
done
EOF
inner new-window -d -t alpha -n subs "zsh $tmp/bin/fake-agents"
claude alpha:subs stop '{"last_assistant_message": "Waiting", "background_tasks": [
  {"id": "s1", "type": "subagent", "status": "running", "description": "Explore the rail"},
  {"id": "s2", "type": "subagent", "status": "running", "description": "Review it"}]}'
row() { screen | grep -n -- "$1" | head -1 | cut -d: -f1 }
see '│   ◔ Review it '
y=$(row '│   ◔ Review it ')
mouse 0 8 $y M
mouse 0 8 $y m
check "a click on a subagent's row in the rail goes to its Claude's window" await at alpha:subs
fake() { inner capture-pane -p -t alpha:subs | grep -qx -- "$1" }
check "and steps that Claude's list of agents to it: past the shells, down to its row, Enter" await fake '❯ ● general-purpose  Review it'
# a lit row has its text in its mark's ink, a dim one a change of ink between the two; the
# pointer left on a row underlines it
sub_lit() { [[ $(inked $(row "│   ◔ $1 ")) == *$'\e[1;'(|4\;)'7m'* ]] }
sub_dim() { [[ $(inked $(row "│   ◔ $1 ")) != *$'\e[1;7m'* && $(inked $(row "│   ◔ $1 ")) == *$'\e[7m'* ]] }
check "the subagent its Claude shows has its row in bold on the Claude's bar" await sub_lit 'Review it'
check "and no other, though the bar runs through it" sub_dim 'Explore the rail'
y=$(row '│   ◔ Explore the rail ')
mouse 0 8 $y M
mouse 0 8 $y m
check "a click on another, with the pointer in the list, goes up from it" await fake '❯ ● general-purpose  Explore the rail'
check "and the light goes with it" await eval 'sub_lit "Explore the rail" && sub_dim "Review it"'
claude alpha:subs end
inner kill-window -t alpha:subs
claude beta:solo prompt
mouse 0 5 4 M
mouse 0 5 4 m
await at beta:solo
see '│.◐ solo '
claude alpha:three waiting '{"message": "Claude needs your permission to use Bash"}'
see '│ ▲ three '
notified() { [[ $(tail -1 $tmp/notified 2>/dev/null) == $1 ]] }
check "a Claude out of view come to wait is a desktop notification" await notified '-a|arena|--|three|allow Bash|'
told=$(wc -l <$tmp/notified)
claude beta:solo stop '{"last_assistant_message": "All done"}'
see '│.○ solo '
check "and the one in view is not" [ $(wc -l <$tmp/notified) -eq $told ]
claude alpha:three stop '{"last_assistant_message": "$(touch '$tmp'/ran) \"q\" `x` #{pane_id}"}'
check "one done too, its words as they are, run by no shell" await notified '-a|arena|--|three|$(touch '$tmp'/ran) "q" x #{pane_id}|'
check "nor by tmux" [ ! -e $tmp/ran ]
claude alpha:three waiting '{"message": "Claude needs your permission to use Bash"}'
see '│ ▲ three '
key M-n
check "Alt+n goes to the Claude that most wants looking at" await at alpha:three
key M-n
check "and stays where it is with no other waiting or done" at alpha:three
claude alpha:one waiting '{"message": "Claude is waiting for your input"}'
inner set -p -t alpha:one @arena_claude_since $(($(date +%s) - 100))
see '│ ▲ one '
key M-n
check "with another, Alt+n goes on to it, the longer waiting first" await at alpha:one
key M-n
check "and round to the first" await at alpha:three
key M-N
check "Alt+N goes back" await at alpha:one
claude alpha:one end
gone '│ ▲ one '
key M-n
check "from a window not listed, Alt+n goes to the first" await at alpha:three
mouse 0 5 11 M
mouse 0 5 11 m
check "a click on a Claude in the rail goes to its window" await at beta:solo
mouse 0 5 6 M
mouse 0 5 6 m
check "a click on the rule over them orders them by when they were last heard from" see '├─ agents · recent '
inner set -p -t alpha:three @arena_claude_at 0
inner set -p -t alpha:three @arena_claude_since $(($(date +%s) - 900))
inner set -p -t beta:solo @arena_claude_at $(date +%s)
first() { screen | grep -A1 -- '├─ agents' | tail -1 | grep -q -- "$1" }
check "the one heard from last first" await first '│ beta '
mouse 0 5 6 M
mouse 0 5 6 m
check "another click orders them by ticket" see '├─ agents · ticket '
mouse 0 5 6 M
mouse 0 5 6 m
see '├─ agents · urgency '
key M-w
inner set -p -t beta:solo @arena_claude_branch t324-lights
check "Alt+w narrows the rail to a session's short name, its mark and its windows" see '^│ alpha.3│ '
check "a Claude by its mark and its ticket's number" see '^│[ ▌]. 324 +│ '
check "or its window's place when it has no ticket" see '^│ . w3 +│ '
check "a session over its Claudes is a rule with its name" see '^│─alpha──│ '
sel() { [[ $(inked $(row "$1")) == *$'\e[1;7m'* ]] }
check "the Claude in view has its whole row in the selected style" await sel ' 324 '
check "and its session's rule and another Claude's row do not" test "$(sel '─beta─' && print y)$(sel ' w3 ' && print y)" = ""
mouse 35 3 9 M
check "the pointer resting on it draws it wide over the strip" see '├─ agents · urgency '
mouse 35 72 3 M
check "and leaving it, narrow again" gone '├─ agents · urgency '
key M-w
check "Alt+w again widens it" see '^╭─ sessions ─+╮ '

# the popup: a Claude's pane in another session, read-only, over the strip
inner send-keys -t alpha:three 'echo three-pane-line' Enter
shows '^NORMAL' || key C-Space
see '^NORMAL'
key -l ']'
see '^│▌.* three'
# the rail's ages tick on their own, popup or not
unaged() { screen | sed -E 's/ [0-9]+[smhd] │/ │/g' }
before=$(unaged)
beside() { screen | sed -n '1,2p;24p'; screen | cut -c1-30 }
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
check "and the screen is as it was" await eval '[[ $(unaged) == "$before" ]]'
key -l ' '
see '╰─ j k scroll'
key Escape
check "Esc closes it too" gone '╰─ j k scroll'

# answering and replying from the popup, without going there
mkdir -p $tmp/run/babylon
print -r -- '{"tickets":[{"id":324,"repo":"arena","title":"Lights","kind":"ticket","status":"doing","priority":"med","claimed_by":"%99",'\
'"claimed_at":"'$(date -u +%Y-%m-%dT%H:%M:%SZ)'","blocked_by":[],"ask":{"id":7,"question":"Keep it?","options":["yes","no"]}}]}' >$tmp/run/babylon/board.json
see '^│ ▤ board'
key -l j
see '^│▌.* solo'
key -l ' '
see '╭─ .*solo'
key -l a
check "a puts babylon's question at the foot with its options numbered" await shows 'answer: Keep it\?'
check "and the options" shows ' 1 yes +2 no'
key -l 2
check "a digit answers it through babylon" await grep -q '^answer 7 2' $tmp/babylon
check "and the popup stays open" shows '╭─ .* solo'
key -l r
key -l 'hello there'
check "r opens a reply line at the foot" shows 'reply: hello there'
key Enter
check "and Enter types it into the pane" await eval 'inner capture-pane -p -t beta:solo | grep -q "hello there"'
check "the popup stays open" shows '╭─ .* solo'
key -l q
rm -f $tmp/run/babylon/board.json
gone '^│ ▤ board'
# Claude Code's own question, on the screen
inner send-keys -t alpha:three "printf 'Do you want to proceed?\n❯ 1. Yes\n  2. No\n'" Enter
key -l k
see '^│▌.* three'
key -l ' '
see '╭─ ▲ three'
key -l a
check "its own question is read from the screen, with its options" await shows 'answer: Do you want to proceed\?'
check "and the options" shows ' 1 Yes +2 No'
key -l 2
check "a digit is typed into the pane" await eval 'inner capture-pane -p -t alpha:three | grep -q "sh-5.3\$ 2"'
key -l q
claude alpha:three end
claude beta:solo end

# 24 Claudes across three repos, ticket 10 landed, the last two of each repo waiting in the pipeline
board='{"tickets":['
repos=(amber birch cedar)
for s in 1 2 3; do
  repo=${repos[s]}
  inner new-session -d -s c$s -n n${s}0 sh
  for w in 0 1 2 3 4 5 6 7 8; do
    id=$s$w
    [[ $w != 0 ]] && inner new-window -d -t c$s -n n$id sh
    state=doing stage=null
    [[ $w == 0 ]] && state=done
    [[ $w -ge 7 ]] && state=review stage='"queued"'
    board+="{\"id\":$id,\"repo\":\"$repo\",\"title\":\"t\",\"status\":\"$state\",\"stage\":$stage},"
  done
done
mkdir -p $tmp/run/babylon
print -r -- "${board%,}]}" >$tmp/run/babylon/board.json
tick() { claude $1 prompt; inner set -p -t $1 @arena_claude_branch t${1##*n}-x }
for s in 1 2 3; do for w in 0 1 2 3 4 5 6 7 8; do tick c$s:n$s$w; done; done
agents_y() { row '├─ agents' }
click_title() { local y=$(agents_y); mouse 0 5 $y M; mouse 0 5 $y m }
check "the rail lists the Claudes, with how many more there are" see "[0-9]+ more"
check "and a landed ticket's Claude is not listed" gone ' n10 '
# a wheel step a time over the agents until the screen shows or hides what it is for
wheel_until() {
  local i y=$(($(agents_y) + 3))
  for i in {1..60}; do
    "$@" && return 0
    mouse $dir 5 $y M
    zselect -t 15
  done
  return 1
}
dir=65
check "the wheel over the agents scrolls them to the last one" wheel_until shows '◌ 2 in the pipeline · cedar'
check "which leaves a row for those above" see '↑ [0-9]+ above'
dir=64
check "and back up to the first" wheel_until hides '↑ [0-9]+ above'
click_title
click_title
check "the title's click cycles on to the stable order" see '├─ agents · ticket '
order() { local y=$(agents_y); screen | sed -n "$((y + 1)),$((y + 9))p" | grep -oE '(c[0-9]|n[0-9]+)' | tr -d '\n' }
before=$(order)
check "which lists by repo, then ticket" [ "${before#c1n11n12n13}" != "$before" ]
claude c1:n12 stop
inner set -p -t c1:n12 @arena_claude_branch t12-x
check "a Claude changing state" see '◉ n12'
check "does not move a row in it" [ "$(order)" = "$before" ]
dir=65
wheel_until shows '◌ 2 in the pipeline · cedar'
y=$(row '◌ 2 in the pipeline · cedar')
mouse 0 5 $y M
mouse 0 5 $y m
check "a click on a fold opens it onto its Claudes, which are listed, and it is left open to close" wheel_until shows '▾ 2 in the pipeline · cedar'
click_title
check "and the title's click goes round to urgency again" see '├─ agents · urgency '
for s in 1 2 3; do inner kill-session -t c$s; done
rm -f $tmp/run/babylon/board.json
gone '├─ agents'
mouse 0 5 4 M
mouse 0 5 4 m
await at beta:solo
review() { inner set -p -t $1 @arena_review $2 }
review alpha:one landed
check "a landed branch marks its session ◆" see '│ alpha +◆ +3 │'
review alpha:one reviewed
check "an approved one ✓" see '│ alpha +✓ +3 │'
review alpha:three queued
check "a queued one » over an approved one" see '│ alpha +» +3 │'
review alpha:one changes
check "changes asked for ✗ over the rest" see '│ alpha +✗ +3 │'
claude alpha:one prompt
claude alpha:one stop '{"background_tasks": []}'
check "the review mark sits beside the Claude mark" see '│ alpha +✗◉ +3 │'
claude alpha:one end
review alpha:one nonsense
check "a value it does not know marks nothing but what else is there" see '│ alpha +» +3 │'
inner set -pu -t alpha:one @arena_review
inner set -pu -t alpha:three @arena_review
see '│ alpha +3 │'
claude beta:solo tool
check "the session in view shows its own mark too" see '│ beta +◐ +1 │'
claude beta:solo stop
in_view_cleared() { [[ -z $(inner show -pqv -t beta:solo @arena_claude) ]] }
check "a done Claude in view is taken as looked at" await in_view_cleared
for w in $(inner list-windows -t alpha -F "#{window_index}"); claude alpha:$w stop
see '│ alpha +◉3 +3 │'
key M-k
looked() { [[ -z $(inner show -pqv -t "alpha:$(inner display -p -t alpha '#{window_index}')" @arena_claude) ]] }
await looked
zselect -t 100
own_replies() { ! screen | grep -qE '│[01] [01] [01] [01] [01] [01] ' }
check "and going to one leaves every pane its own reply" own_replies
for w in $(inner list-windows -t alpha -F "#{window_index}"); claude alpha:$w end
key M-j
see '╭─ 1 solo '

mouse 0 3 4 M
mouse 32 3 3 M
mouse 0 3 3 m
check "dragging a session moves it up the rail" await rail betaalpha
check "and its place is kept in tmux" await order 1beta2alpha
# a click on the rail is normal mode
key -l i

key 'echo hello brave world' Enter
see '│hello brave world'
row=$(screen | grep -n '│hello brave world' | cut -d: -f1)
mouse 0 45 $row M
mouse 32 55 $row M
mouse 0 55 $row m
copied() { [[ $(outer show-buffer 2>/dev/null) == $1 ]] }
check "dragging selects text and copies it" await copied 'brave world'

highlit() { outer capture-pane -p -e -t o | grep -q $'\e\\[7mbrave' }
key M-/
key 'brave' Enter
check "Alt+/ finds text in the history" await highlit
key Escape

key M-m
key b
check "the menu opens the browser in a window of its own, in view" see '╭─ [0-9] browser ─'
check "running terminal-browser on its start page, for new tabs too" see '│browser-stub 1 terminal-browser://start'
key Enter
gone 'browser-stub'

key 'exit' Enter
# three was the last window dropped on alpha, which makes it the one alpha shows
check "a session ending moves arena to one that is left" see '╭─ 3 three '
check "and takes it off the rail" gone '│ beta '

one=$(inner display -p -t alpha:one '#{pane_id}')
mkdir -p $tmp/run/babylon
print -r -- '{"tickets":[{"id":7,"repo":"tlon","title":"Lights","kind":"ticket","status":"todo","priority":"med","blocked_by":[],"stage":"failed",'\
'"ask":{"id":5,"question":"Which colour?","options":["red","blue"]}},'\
'{"id":8,"repo":"arena","title":"Board of the lanes","kind":"ticket","status":"doing","priority":"high","claimed_by":"'$one'",'\
'"claimed_at":"'$(date -u +%Y-%m-%dT%H:%M:%SZ)'","blocked_by":[7]},'\
'{"id":11,"repo":"arena","title":"Handed in","kind":"ticket","status":"review","priority":"med","claimed_by":"'$one'",'\
'"claimed_at":"'$(date -u +%Y-%m-%dT%H:%M:%SZ)'","blocked_by":[],"stage":"queued"}],'\
'"backlog":[{"id":12,"repo":"arena","title":"Someday","kind":"ticket","status":"backlog","priority":"med","blocked_by":[]}]}' \
  >$tmp/run/babylon/board.json
check "babylon's board has a row atop the rail, with its counts" see '^│ ▤ board +1 todo  1 doing │'
key M-b
check "Alt+b opens it in place of the strip, its repos as tabs" see ' ▤ board +every [0-9]+ +arena [0-9]+ +tlon [0-9]+ '
check "and where its keys are" see '\? keys'
check "the picked card's actions as chips on its own bottom edge" see '╰ go ─ answer ─ '
rowof() { screen | grep -n -m1 -- "$1" | cut -d: -f1 }
check "the row under its footer" test $(( $(rowof '#7 Lights') + 2 )) -eq "$(rowof '╰ go ─ answer ─ ')"
key l k
check "l to a column its repo has no card in picks the first repo's that has" see '╰ go ─ edit '
key h j
check "and h back to its own, j off its group's end staying when none is below" see '╰ go ─ answer ─ '
spot() { local l=$(screen | grep -m1 -- "$1"); local p=${l%%"$1"*}; print $(( ${#p} + 2 )) $(screen | grep -n -m1 -- "$1" | cut -d: -f1) }
mouse 0 ${(z)$(spot '#8 Board')} M
check "a click on a card in a repo's group picks it" see '╰ go ─ edit '
mouse 0 ${(z)$(spot '#7 Lights')} M
check "and on another, that one" see '╰ go ─ answer ─ '
key M-!
check "Alt+! over a card asks what is wrong" see "What's wrong\?"
key -l 'hover sticks on a card'
key Enter
filed() { [[ -f $tmp/babylon ]] && grep -q '^file hover sticks on a card --repo arena --body hover sticks on a card$' $tmp/babylon }
check "and Enter files a ticket in arena with the line" await filed
told_of() { grep -q -- "$1" $tmp/babylon }
check "which says what the pointer is over" told_of '^pointer: x=[0-9]* y=[0-9]* over card #7 Lights$'
check "and the window's size, the rail and the view" told_of '^size: 121x24$'
capture=$(sed -n 's/^capture, with the screen as text and the last input: //p' $tmp/babylon)
check "and names the capture file" test -f "$capture"
capture_has() { local p; for p in "$@"; do grep -q -- "$p" "$capture" || return 1; done }
check "which has the line, the last input and the screen as text" capture_has "^what's wrong: hover sticks on a card" 'mouse press left at' '^ *[0-9]*|.*#7 Lights'
check "with the styles around the pointer" grep -q '^styles around the pointer' "$capture"
rm $tmp/babylon
key '?'
check "? shows the board's keys" see "the board's keys"
key x
check "and any key puts them away" gone "the board's keys"
check "a column a status, with its count" see '╭─ doing 1 ─'
railed() { local l=$(inked $1); print -r -- "${${l#*│}%%│*}" }
alone() { [[ $(railed 2) == *$'\e[1;7m'* && $(railed 3)$(railed 4)$(railed 5) != *$'\e[1;7m'* ]] }
check "and the board's row is the one lit, not the session's" alone
check "in each column, a heading for each repo with cards there, with its count" see '│ tlon ─+ 1│ *│ arena ─+ 1│'
check "an empty column says none" see '│ none +│'
check "and is no wider than its heading" see '╭─ recent 0 ╮'
colw() { local l=$(screen | grep -m1 -- "╭─ $1 "); l=${l#*"╭─ $1 "}; print $(( ${#${l%%╮*}} )) }
check "a card not picked unboxed, a bar down its left, its number and title beside it" see '▌ #8 Board of the +│'
check "a long title running on to a second line" see '▌ lanes +│'
check "and a doing one its holder's window under them, and how long it has held it" see '▌ one · [0-9]+[sm] · '
check "one in review its stage in the holder's place, and its place in line" see '▌ » queued · 1st +│'
check "the picked card's priority on its top edge" see '╭ med ─'
claude alpha:one prompt
check "with its Claude's mark while it works" see '▌ [◐◓◑◒] one · [0-9]+[sm]'
claude alpha:one end
check "sent back and asking in its footer" see '│ \? asks · ✗ sent'
cardrow() { local l; for l in "${(@f)$(outer capture-pane -ep -t o)}"; [[ $l == *$1* ]] && print -r -- $l }
picked_lit() { [[ $(cardrow '#7 Lights') == *$'\e[1m\e[38;5;4m│\e[0m #7 Lights'* ]] }
high_edge() { [[ $(cardrow '#8 Board') == *$'\e[38;5;4m▌\e[38;5;8m #8 Board'* ]] }
key a
check "a shows the picked card's question" see '│ Which colour\? +│'
check "with its options by number" see '│ 2  blue +│'
key 2
checked() { [[ -f $tmp/babylon && $(tail -1 $tmp/babylon) == 'answer 5 2' ]] }
check "and a number answers it through babylon" await checked
check "and puts it away" gone 'Which colour'
touch $tmp/refuse
key a
check "asked again" see '│ Which colour\? +│'
key 1
refused() { [[ -f $tmp/notified && $(<$tmp/notified) == *'babylon: no session to answer'* ]] }
check "and refused by babylon, it says why" await refused
rm $tmp/refuse
settled() { screen | awk '{ s = $0; out = ""; while (match(s, / [0-9]+[smhd]/)) { tok = substr(s, RSTART, RLENGTH); gsub(/[0-9]/, "N", tok); out = out substr(s, 1, RSTART - 1) tok; s = substr(s, RSTART + RLENGTH) } print out s }' }
foot_at() { local l=$(screen | grep -m1 "╰─ q close"); print $(( ${l[(i)╰]} - 1 )) }
outside() { settled | sed -n '1,2p;$p'; screen | cut -c1-12 }
board_before=$(settled)
outside_before=$(outside)
key ' '
check "Space shows the picked card's whole ticket, as babylon tells it" see '│ the whole of it '
check "in a frame with its close button in the foot" see '╰─ q close '
check "no cell outside it has changed" eval '[[ $(outside) == "$outside_before" ]]'
key j j j j j
check "and j scrolls it no further than its last line" see '│ the whole of it '
key Escape
check "and Escape puts it away" gone 'the whole of it'
check "leaving the screen as it was" await eval '[[ $(settled) == "$board_before" ]]'
key ' '
see 'the whole of it'
mouse 0 $(( $(foot_at) + 3 )) $(screen | grep -n -m1 "╰─ q close" | cut -d: -f1) M
check "a click on its close button puts it away" gone 'the whole of it'
key ' '
see 'the whole of it'
mouse 0 $(( $(foot_at) + 4 )) 10 M
check "a click inside it leaves it open" shows 'the whole of it'
mouse 0 $(( $(foot_at) + 4 )) 2 M
check "and a click outside it closes it" gone 'the whole of it'
key ' '
see 'the whole of it'
key q
check "q closes it too" gone 'the whole of it'
nofile() { [[ ! -e $tmp/run/babylon/detail-7.txt ]] }
check "leaving no file of it behind" await nofile
key ' '
check "shown again" see '│ the whole of it '
mouse 0 3 12 M
check "and closed with the board by a click on the rail, no file either" await nofile
$bin -L $in board 7
check "arena board and a ticket's id, run elsewhere, opens the board on it with its question" see '│ Which colour\? +│'
key Escape
$bin -L $in board 8
check "and with the board open, moves the pick to it" see '╰ go ─ edit '
# past the wait that tells a lone Escape from Alt
zselect -t 10
check "the Escape typed before it put the question away, not the board after" shows ' board  every'
key Escape
gone ' board  every'
two=$(inner list-panes -s -t alpha -F '#{pane_id}' | sed -n 2p)
$bin -L $in show $two
check "arena show and a pane puts its window in front" await dots '○ ● ○'
$bin -L $in show "#8"
check "arena show and a held ticket's number does the same for its Claude's pane" await dots '● ○ ○'
$bin -L $in inbox
check "arena inbox opens home" see '╭─ ○ orchestrator · off '
$bin -L $in show $two
check "and a show with the board open puts it away for the pane" await dots '○ ● ○'
key M-b
last() { [[ -f $tmp/babylon && $(tail -1 $tmp/babylon) == $1 ]] }
key p
check "p raises the picked card's priority through babylon" await last 'update 7 --priority high'
key w
check "w puts the picked todo card at the bottom of next, through babylon" await last 'next 7'
key W
check "and W at its top" await last 'next 7 --at 1'
inner set -p -t alpha:one @arena_claude_since $(date +%s)
key G
check "G shows the running Claudes the picked card can be given to" see '│ [1-9]  alpha · one '
key Escape
check "and Escape puts them away" gone 'give #7 to'
key G
key "$(screen | sed -n 's/.*│ \([1-9]\)  alpha · one .*/\1/p')"
check "and a Claude's number gives it the card through babylon, by its pane" await last "give 7 $one"
check "and puts them away" gone 'give #7 to'
touch $tmp/refuse
key G
key "$(screen | sed -n 's/.*│ \([1-9]\)  alpha · one .*/\1/p')"
unfit() { [[ $(<$tmp/notified) == *"babylon: the Claude in $one is mid-turn"* ]] }
check "and refused by babylon, it says why, the pane whole" await unfit
rm $tmp/refuse
inner set -pu -t alpha:one @arena_claude_since
check "with no auto in babylon's file, the board says nothing of it" hides 'auto [0-9]'
key A
check "A turns babylon's auto mode on" await last 'auto on'
cp $tmp/run/babylon/board.json $tmp/board.noauto
print -r -- "${$(<$tmp/board.noauto)%\}}"',"auto":{"on":true,"cap":2,"working":1}}' >$tmp/run/babylon/board.json
check "on, the switch beside the tabs says how many work of the cap" see ' backlog [0-9]+ .* ◐ auto 1/2( |$)'
check "and so does the board's row atop the rail" see '^│ ▤ board auto 1/2 '
check "but the board's own header says it once, not after its name" gone ' board auto 1/2 +every '
key A
check "and A turns it off" await last 'auto off'
cp $tmp/board.noauto $tmp/run/babylon/board.json
check "off, the state is gone" gone 'auto [0-9]'
autocol() { local l=$(screen | grep -m1 ' board  every'); local p=${l%% ◐ *}; print $(( ${#p} + 2 )) }
mouse 0 $(autocol) $(screen | grep -n -m1 ' board  every' | cut -d: -f1) M
check "a click on the switch turns it on as A does" await last 'auto on'
check "the board has no orchestrator's button: its column is home's" hides ' orch '
print -r -- "${$(<$tmp/board.noauto)%\}}"',"orchestrator":{"on":true,"running":false}}' >$tmp/run/babylon/board.json
check "the board's row atop the rail says an orchestrator is not running" see '^│ ▤ board orch  '
print -r -- "${$(<$tmp/board.noauto)%\}}"',"orchestrator":{"on":false,"running":false}}' >$tmp/run/babylon/board.json
check "and that babylon keeps it off" see '^│ ▤ board orch off '
print -r -- "${$(<$tmp/board.noauto)%\}}"',"orchestrator":{"on":true,"running":true}}' >$tmp/run/babylon/board.json
check "and names it running" see '^│ ▤ board orch  '
cp $tmp/board.noauto $tmp/run/babylon/board.json
check "with nothing of it in babylon's file again, the row says nothing" gone '^│ ▤ board orch'
print -r -- "${$(<$tmp/board.noauto)%\}}"',"proposals":[{"id":4,"action":"start","ticket_id":7,"what":"Start #7","why":"Next in line"}],"needs_you":[{"id":"proposal:4","kind":"proposal","ticket":7,"repo":"tlon","text":"P4 Start #7: Next in line","actions":[]}]}' >$tmp/run/babylon/board.json
check "a card with an open proposal shows it" see '▲ proposed'
check "the header counts what needs you" see ' ▲ 1 need you'
check "and the card has a no beside its go" see '╰ go ─ no '
key Enter
check "go on it answers the proposal through babylon, not a Claude started" await last 'go 4'
key x
check "and x says no to it" await last 'no 4'
cp $tmp/board.noauto $tmp/run/babylon/board.json
check "with it settled, the card and the header say nothing of it" gone '▲ [1-9]'
print -r -- '{"tickets":['\
'{"id":13,"repo":"tlon","title":"Held for an answer","kind":"ticket","status":"review","priority":"med","claimed_by":"'$one'",'\
'"claimed_at":"'$(date -u +%Y-%m-%dT%H:%M:%SZ)'","blocked_by":[],"stage":"queued","ask":{"id":6,"question":"Which size?"}},'\
'{"id":14,"repo":"tlon","title":"Sent back asking","kind":"ticket","status":"review","priority":"med","claimed_by":"'$one'",'\
'"claimed_at":"'$(date -u +%Y-%m-%dT%H:%M:%SZ)'","blocked_by":[],"stage":"failed","ask":{"id":9,"question":"Which shape?"}}]}' >$tmp/run/babylon/board.json
check "a held card asking says so where the pipeline has it" see '[▌│] held: asks +│'
check "a sent back one asking has the question before it" see '[▌│] \? asks · ✗ sent back +│'
print -r -- '{"tickets":[{"id":15,"repo":"tlon","title":"Handed over","kind":"ticket","status":"todo","priority":"med","handed_to":"'$one'","handed_from":4,"blocked_by":[]}]}' >$tmp/run/babylon/board.json
check "a todo card handed to a pane is drawn held by it" see '[▌│] one +│'
cp $tmp/board.noauto $tmp/run/babylon/board.json
check "with the board back, #7 is there" see '#7 Lights'
mouse 0 ${(z)$(spot '#7 Lights')} M
key J
check "J moves it down its column, among its lane's" await last 'move 7 down --repo tlon'
key '>'
check "> closes a ticket still to do" await last 'update 7 --status done'
key e
check "e edits it in a window of its own" await last 'edit 7'
key M-b
key n
check "n files one, from every repo with the repo asked" await last 'new'
key M-b
key r
# how tmux spells the lit style varies with its terminal: any reverse-video SGR run just before the name
tablit() { [[ $(outer capture-pane -ep -t o) =~ $'((\e\\[[0-9;]*m)+) '$1' ' && $match[1] =~ '[[;]7[;m]' ]] }
check "r narrows it to one repo, its tab lit" await tablit arena
check "and to its cards" gone '#7 Lights'
check "which are whole there: number and title" see '▌ #8 Board of the lanes +│'
check "a high card's bar amber" high_edge
check "under them the window of the Claude holding it, then what it waits on" see '▌ one · [0-9]+[sm] · waits #7 +│'
check "its priority said by its bar, not in words" gone '· high'
tabrow() { screen | grep -n -m1 ' board  every' | cut -d: -f1 }
tabcol() { local l=$(screen | grep -m1 ' board  every'); local p=${l%%" $1 "*}; print $(( ${#p} + 2 )) }
key '?'
mouse 0 $(tabcol tlon) $(tabrow) M
check "a click while the keys are shown only puts them away" tablit arena
mouse 0 $(tabcol tlon) $(tabrow) M
check "a click on a tab narrows it to that repo" see '#7 Lights'
check "and only that" gone '#8 Board'
check "the picked card's border is lit" picked_lit
check "and, sent back from the pipeline, that first, after a question waiting on you" see '│ \? asks · ✗ sent back +│'
check "its actions as chips on its bottom edge" see '╰ go ─ answer ─'
check "the four columns do not show the backlog" gone '#12 Someday'
key r
check "r from the last repo goes to the backlog tab, lit" await tablit backlog
check "which shows its cards in place of the columns" see '#12 Someday'
check "and not the four columns" gone '╭─ doing '
told() { [[ -f $tmp/babylon && $(tail -1 $tmp/babylon) == 'update 12 --status todo' ]] }
key t
check "t moves a backlog card to todo through babylon" await told
key r
check "r from the backlog goes back to every repo" await tablit every
check "which does not show the backlog" gone '#12 Someday'
touch $tmp/refuse-start
key Enter
check "Enter on a card babylon refuses to start says why on the card, the board still open" see 'babylon: ticke'
rm $tmp/refuse-start
key Enter
check "Enter on a free todo card runs babylon start on it" await last 'start 7'
check "and closes the board once babylon has started it" gone ' board  every'
key M-b
check "and the board opens again on every repo" await tablit every
key r
check "and r again narrows it to the first repo" await tablit arena
key l
key Enter
check "Enter on a card goes to the Claude holding it" see '╭─ 1 one '
mouse 0 3 2 M
check "a click on its row in the rail goes home: the board, and the orchestrator's column beside it" see '╭─ ○ orchestrator · off '
check "which says how to start an orchestrator that is off" see 'orchestrator off · ⏎ start it'
check "with the board there" await shows ' board  every'
key Enter
check "and Enter there starts it" await last orchestrator
: >$tmp/babylon
mouse 0 3 2 M
check "another click stays home" shows ' board  every'
key q
check "and q there closes it" gone ' board  every'
# the colour the board's row atop the rail, unlit with the board closed, names the orchestrator in
rail_orch_ink() { [[ $(outer capture-pane -ep -t o) =~ $'▤ board((\e\\[[0-9;]*m)*) orch' && $match[1] == *"38;5;$1m" ]] }
cp $tmp/run/babylon/board.json $tmp/board.closed
print -r -- "${$(<$tmp/board.closed)%\}}"',"orchestrator":{"on":true,"running":true}}' >$tmp/run/babylon/board.json
check "the board's row has a running orchestrator lit" await rail_orch_ink 5
print -r -- "${$(<$tmp/board.closed)%\}}"',"orchestrator":{"on":true,"running":false}}' >$tmp/run/babylon/board.json
check "and one that is not running unlit" await rail_orch_ink 8
cp $tmp/board.closed $tmp/run/babylon/board.json
check "and says nothing of it once babylon's file does not" gone '^│ ▤ board orch'
key M-b
see ' board  every'
key -l 'qecho kept-after-q'
kept_after() { inner capture-pane -p -t alpha:one | grep -qF 'echo kept-after-q' }
check "what is typed in one read after the q closing the board is the pane's" await kept_after
key C-u
inner new-session -d -s babylon -n gate sh
key M-b
check "with babylon's gate session there, the board offers it" see '◒'
check "and the rail does not list it" gone '│ babylon '
key g
check "g on the board shows the gate" see '╭─ 1 gate '
cp $tmp/run/babylon/board.json $tmp/board.kept
print -r -- '{"tickets":[{"id":13,"repo":"babylon","title":"Gatekeeping","kind":"ticket","status":"todo","priority":"med","blocked_by":[]}]}' \
  >$tmp/run/babylon/board.json
key M-b
see 'Gatekeeping'
key Enter
check "Enter on a babylon card starts it through babylon too" await last 'start 13'
check "and closes the board" gone ' board  every'

cp $tmp/board.kept $tmp/run/babylon/board.json
key M-b
key o
starting() { [[ -f $tmp/babylon && $(tail -1 $tmp/babylon) == orchestrator ]] }
check "o on the board starts the orchestrator when it is not running" await starting
key M-b
check "the board opened in the meantime" see ' board  every'
key M-b
check "and closed" gone ' board  every'
inner new-session -d -s orchestrator -n orch sh
# nothing to wait on for what must not happen: a second for the session to be seen
zselect -t 100
check "an orchestrator that shows after the human moved on does not pull them to it" see '╭─ 1 gate '
key M-b
key o
check "and o goes to it now it is there" see '╭─ 1 orch '
check "which the rail does not list" gone '│ orchestrator '
inner kill-session -t '=orchestrator'
check "with the orchestrator gone, arena goes elsewhere" gone '╭─ 1 orch '
asked=$(grep -cx orchestrator $tmp/babylon)
key M-b
key o
asked_again() { (( $(grep -cx orchestrator $tmp/babylon) > asked )) }
check "o asks babylon to start it again" await asked_again
inner new-session -d -s orchestrator -n orch sh
check "and with no other move made, arena goes to it once its session is there" see '╭─ 1 orch '
print -r -- '{"tickets":[{"id":9,"repo":"arena","title":"Pipe","kind":"ticket","status":"review","priority":"med","blocked_by":[],"stage":"reviewing"}]}' \
  >$tmp/run/babylon/board.json
check "while babylon works a ticket toward main, the board's row says which and how far" see '^│ ▤ board +◐ #9 reviewing │'
print -r -- '{"tickets":[{"id":9,"repo":"arena","title":"Pipe","kind":"ticket","status":"review","priority":"med","blocked_by":[],"stage":"reviewing"},'\
'{"id":10,"repo":"tlon","title":"Pipe two","kind":"ticket","status":"review","priority":"med","blocked_by":[],"stage":"verifying"}]}' \
  >$tmp/run/babylon/board.json
check "and with two going, the first and how many more" see '^│ ▤ board +◐ #9 reviewing \+1 │'

in_session() { [[ $(inner list-clients -F '#{session_name}') == $1 ]] }
mouse 0 5 3 M
mouse 0 5 3 m
await in_session alpha
key M-b
check "with the orchestrator running, the board has its window beside it" see '╭─ ○ orchestrator · idle '
check "arena in its session to have it live" await in_session orchestrator
orch_lit() { [[ $(outer capture-pane -ep -t o) =~ $'((\e\\[[0-9;]*m)+) ○ orchestrator ' && $match[1] =~ '[[;]7[;m]' ]] }
shown_cursor() { [[ $(outer display -p -t o '#{cursor_flag}') == $1 ]] }
check "the board keeps the keys: its column is unlit, the cursor in no pane" eval '! orch_lit && shown_cursor 0'
: >$tmp/babylon
key M-l
check "Alt+l from the board focuses it, lit as the focused column" await orch_lit
key 'echo side' Enter
check "what is typed then reaches its pane" see '│side +│'
check "and none of it the board, which stays open" eval '[[ ! -s $tmp/babylon ]] && shows " board  every"'
inner send-keys -t orchestrator:orch "stty -echo -icanon; cat $tmp/clicks; timeout 2 cat -v; printf '\\033[?1006l\\033[?1000l'; stty sane" Enter
await mousing orchestrator:orch
mouse 64 100 10 M
wheeled() { inner capture-pane -pJ -t orchestrator:orch | grep -qF '[<64;' }
check "a wheel over it reaches its program" await wheeled
await eval '! mousing orchestrator:orch'
key M-h
check "Alt+h goes back to the board" await eval '! orch_lit && shown_cursor 0'
key '?'
check "whose keys are its own again" see "the board's keys"
key Escape
mouse 0 100 10 M
mouse 0 100 10 m
check "a click on it focuses it too" await orch_lit
key 'echo back' Enter
check "and what is typed reaches its pane" see '│back +│'
mouse 0 45 22 M
mouse 0 45 22 m
check "a click on the board gives the board the keys" await eval '! orch_lit'
key '`'
check "where \` folds it away" gone '╭─ ○ orchestrator · idle '
check "going back to the session the human was in" await in_session alpha
key '`'
check "and unfolds it" see '╭─ ○ orchestrator · idle '
key Escape
check "closing the board goes back to the session the human was in" await in_session alpha
check "the strip its whole width again" see '╭─ 1 one ─'
# The sessions' server stopped answers nothing: arena reads what is typed with its switch unanswered.
# Nothing shows that arena has read it, so it is given half a second to.
server=$(inner display -p '#{pid}')
kill -STOP $server
key M-b q
zselect -t 50
kill -CONT $server
check "opened and closed before tmux has switched, it comes back all the same" await in_session alpha
key M-b
await in_session orchestrator
kill -STOP $server
key '`' '`' q
zselect -t 50
kill -CONT $server
check "folded, unfolded and closed before tmux has switched back, it comes back all the same" await in_session alpha
said() { inner capture-pane -p -t $1 | grep -qx $2 }
kill -STOP $server
key M-b
see ' board  every'
key M-l 'echo ahead' Enter
zselect -t 50
check "the board stays open on an Alt+l typed before tmux has switched" shows ' board  every'
kill -CONT $server
check "Alt+l and what is typed before tmux has switched reach the orchestrator's pane" await said orchestrator:orch ahead
check "the board left open" await shows ' board  every'
key -l 'echo jkdufltb'
key Enter
check "with the board open, a sentence of the board's own letters reaches the orchestrator's pane whole" await said orchestrator:orch jkdufltb
check "and the board is still open" see ' board  every'
key C-Space
key -l 'echo nojkdu'
key Enter
zselect -t 50
check "Ctrl+Space makes that column normal: none of it reaches the pane" eval '! said orchestrator:orch nojkdu'
check "home in normal mode shows NORMAL and how to type" see '^NORMAL .*Ctrl\+Space / i to type'
key -l i
check "and i is insert again" gone '^NORMAL'
kill -STOP $server
key M-b
gone ' board  every'
key 'echo home' Enter
zselect -t 50
kill -CONT $server
check "what is typed after the board closes, before tmux has switched back, reaches the human's" await said alpha: home
check "and none of it the orchestrator's" eval '! said orchestrator:orch home'
inner new-window -d -t orchestrator: -n two sh
key M-b
see '` fold ─╮ ╭─ 2 t'
key M-b
await in_session alpha
orch_at() { [[ $(inner display -p -t orchestrator: '#{window_name}') == $1 ]] }
kill -STOP $server
key M-b M-l M-l
zselect -t 50
kill -CONT $server
check "Alt+l again before tmux has switched steps to the orchestrator's next window" await orch_at two
kill -STOP $server
key M-h
zselect -t 50
kill -CONT $server
check "and Alt+h back" await orch_at orch
inner kill-window -t orchestrator:two
key M-b
await in_session alpha
cp $tmp/run/babylon/board.json $tmp/board.pipe
print -r -- "${$(<$tmp/board.pipe)%\}}"',"orchestrator":{"on":true,"running":true}}' >$tmp/run/babylon/board.json
key C-Space
see '^NORMAL .*b home'
key b
check "b in normal mode goes home: the orchestrator's column beside the board, with the keys" await orch_lit
check "in insert" hides '^NORMAL'
await in_session orchestrator
inner kill-session -t '=orchestrator'
check "its session ending leaves home open, its head saying it restarts" see '╭─ ◌ orchestrator · restarting '
check "the board still there" await shows ' board  every'
check "and arena in the session the human was in" await in_session alpha
inner new-session -d -s orchestrator -n orch sh
check "the column comes back on the new orchestrator" see '╭─ ○ orchestrator · idle '
check "with the keys, as the human left them" await orch_lit
key 'echo again' Enter
check "and what is typed reaches the new one's pane" see '│again +│'
print -r -- "${$(<$tmp/board.pipe)%\}}"',"orchestrator":{"on":true,"running":true},"needs_you":['\
'{"id":"ask:5","kind":"ask","ticket":8,"repo":"arena","text":"#8 arena  asks: Blue or green?",'\
'"actions":[{"key":"1","label":"Blue","argv":["babylon","answer","5","1"]},{"key":"c","label":"in words","argv":["babylon","answer","5","--words"],"needs":"words"}]}]}' >$tmp/run/babylon/board.json
feed_above() {
  local head=$(rowof '○ orchestrator · idle') move=$(rowof '▲ your move 1') said=$(rowof '│again ')
  [[ -n $head && -n $move && -n $said ]] && (( head < move && move < said ))
}
check "the feed sits atop the orchestrator's column, Your move above its pane's first line" await feed_above
check "each item as babylon words it, its actions under it" see '▌     1 Blue   c in words'
check "the pane under the feed is as tall as what is left of the column" await eval '(( $(inner display -p -t orchestrator:orch "#{pane_height}") == 22 - $(rowof "✓ landed today") - 1 ))'
print -r -- "${$(jq -c '.tickets += [{"id":7,"repo":"tlon","title":"Lights","kind":"ticket","status":"todo","priority":"med","blocked_by":[],"stage":"failed"}]' $tmp/board.pipe)%\}}"',"orchestrator":{"on":true,"running":true},"needs_you":['\
'{"id":"ask:5","kind":"ask","ticket":8,"repo":"arena","text":"#8 arena  asks: Blue or green?",'\
'"actions":[{"key":"1","label":"Blue","argv":["babylon","answer","5","1"]},{"key":"c","label":"in words","argv":["babylon","answer","5","--words"],"needs":"words"}]},'\
'{"id":"sendback:7","kind":"sendback","ticket":7,"repo":"tlon","text":"✗ #7 tlon  sent back, free: red",'\
'"actions":[{"key":"G","label":"give","argv":null,"needs":"pick"},{"key":"⏎","label":"start","argv":null,"needs":"surface"},'\
'{"key":"x","label":"close","argv":["babylon","update","7","--status","done"]}]}]}' >$tmp/run/babylon/board.json
see '▲ your move 2'
check "the rail's top row says how many need the human" see '^│ ▤ board ▲ 2'
: >$tmp/babylon
key C-Space
feed_lit() { [[ $(outer capture-pane -ep -t o | grep -F -- "$1") =~ $'((\e\\[[0-9;]*m)+)'"$1" && $match[1] =~ '[[;]7[;m]' ]] }
check "normal mode in the column puts the pick on the feed's first item, lit" await feed_lit '#8 arena  asks'
key 1
check "an ask's option number runs its answer as babylon gives it" await last 'answer 5 1'
touch $tmp/refuse
key 1
check "and babylon's refusal is said in place of the item's buttons" see '▌     babylon: no session'
rm $tmp/refuse
key j
check "j moves the pick to the next item" await feed_lit '✗ #7 tlon'
key x
check "x on a free send-back closes it, as its action says" await last 'update 7 --status done'
key Enter
check "and Enter starts a Claude on it through babylon" await last 'start 7'
key G
check "G on it shows the running Claudes to give it to" see ' give #7 to '
key Escape
gone ' give #7 to '
key k
check "and closing them gives the feed back its keys" await feed_lit '#8 arena  asks'
key c
check "c on an ask opens a line at the column's foot" see '❯ .*⏎ send  esc drop'
key 'never mind'
key Escape
check "Escape drops it, and the feed has its keys again" await feed_lit '#8 arena  asks'
gone '⏎ send  esc drop'
: >$tmp/babylon
key c
key 'in words'
key Enter
check "Enter runs the action with the words as its last argument" await last 'answer 5 --words in words'
check "and the line is gone, the feed has its keys" await feed_lit '#8 arena  asks'
jq -c '. + {"hold":false,"auto":{"on":true,"cap":6,"working":2,"idle":{"slots":1,"why":"next empty"},"repo_caps":{"arena":3,"babylon":2,"tlon":1}},"plan":{"next":[{"ticket":655,"repo":"arena","title":"Typing reaches no pane","why":"third sighting","set_by":"orchestrator"},{"ticket":656,"repo":"babylon","title":"Held lines","why":"","set_by":"orchestrator"}]}}' $tmp/run/babylon/board.json >$tmp/board.tmp && mv $tmp/board.tmp $tmp/run/babylon/board.json
see '▷ next 2 · 1 slot idle'
check "next is under Your move, auto's line at its top" see 'auto on · 2 of 6 · hold off'
check "and its repos under it" see 'arena 3 · babylon 2 · tlon 1'
check "and a ticket of it a row" see '#656 babylon  Held lines'
key j
check "the pick goes on to auto's line, a repo of it lit" await feed_lit 'arena 3'
key Right Right
check "the arrows pick another repo" await feed_lit 'tlon 1'
: >$tmp/babylon
key -
check "- lowers its cap through babylon, 0 pausing it" await last 'auto --repo-cap tlon=0'
key +
check "and + raises it" await last 'auto --repo-cap tlon=2'
key a
check "a turns auto off through babylon" await last 'auto off'
key H
check "and H puts the pipeline on hold" await last 'hold on'
key j
check "the pick goes on to next's tickets" await feed_lit '#655 arena  third sighting'
touch $tmp/refuse-next
key p
check "a next key babylon refuses says why under the ticket's row" see 'babylon: ticket #655 is c'
rm $tmp/refuse-next
key p
check "p pins a ticket where it is, through babylon as the human" await last 'next 655 --at 1'
check "and the next key takes the refusal away" gone 'babylon: ticket #655 is c'
key J
check "J moves it down" await last 'next 655 --at 2'
key K
check "K moves the one under it up" await last 'next 656 --at 1'
key x
check "x drops it from next" await last 'next 655 --drop'
jq -c "del(.hold,.auto,.plan)" $tmp/run/babylon/board.json >$tmp/board.tmp && mv $tmp/board.tmp $tmp/run/babylon/board.json
key k k
key i
key M-h
await eval '! orch_lit'
key ']'
check "] from the board puts the feed's pick on Your move's first item, the column normal" await feed_lit '#8 arena  asks'
key j
check "where its keys are the feed's" await feed_lit '✗ #7 tlon'
key i
see '│again '
key M-h
check "Alt+h gives the board the keys" await eval '! orch_lit'
key o
check "o goes to it, the board put away" gone ' board  every'
key 'echo whole' Enter
check "and what is typed after o reaches its pane" see '│whole +│'
mouse 0 5 3 M
mouse 0 5 3 m
await in_session alpha

done_card() { print -r -- '{"id":'$1',"repo":"arena","title":"Done '$1'","kind":"ticket","status":"done","priority":"med","blocked_by":[]}' }
print -r -- '{"tickets":[{"id":20,"repo":"arena","title":"Next","kind":"ticket","status":"todo","priority":"med","blocked_by":[]},'\
"${$(done_card 25)%\}}"',"session_note":"left running: it holds #9"},'\
"$(done_card 24),$(done_card 23),$(done_card 22),$(done_card 21),"\
'{"id":30,"repo":"menard","title":"Old","kind":"ticket","status":"done","priority":"med","blocked_by":[]}]}' >$tmp/run/babylon/board.json
key M-b
key '`'

check "done shows its last few closed under its repo, a row each under a ✓" see '│ ✓ #23 Done 23 +│'
check "then how many more it has" see '│ 2 more +│'
check "headed recent, its count all of them" see '╭─ recent 6 ─'
check "a strip narrower than the columns before it" test "$(colw todo)" -gt "$(colw recent)"
key l l l j
check "a row of it is picked, its reopen on the strip's foot" see '╰─ reopen ─+╯'
key '<'
check "and < opens it again" await last 'update 24 --status todo'
key h h h
check "a repo with only done cards has no group" gone ' menard ─'
tabline() { local l; for l in "${(@f)$(outer capture-pane -ep -t o)}"; [[ $l == *'board'*' every '* ]] && print -r -- $l }
tab_dim() { [[ $(tabline) == *$'\e[38;5;8m '$1' '* ]] }
tab_lit() { ! tab_dim $1 }
mouse 35 60 24 M
check "and its tab is dim" tab_dim menard
check "where one with work is not" tab_lit arena
cp $tmp/run/babylon/board.json $tmp/board.lanes
print -r -- "${$(<$tmp/board.lanes)%\}}"',"auto":{"on":true,"cap":2,"working":1}}' >$tmp/run/babylon/board.json
check "with room, the header says auto beside every button" see ' ▤ board +every .* ▲ 0 +◒ +◐ 1/2( |$)'
outer resize-window -t o -x 105
check "and with less room still, it keeps the switch" see ' ▤ board +every .* ◐ 1/2( |$)'
outer resize-window -t o -x 121
cp $tmp/board.lanes $tmp/run/babylon/board.json
check "and off, it is gone again" gone 'auto [0-9]'
check "not the rest" gone 'Done 22'
key r
check "and so in one repo's view" see '│ 2 more +│'
check "where one whose Claude babylon left running says why, as far as its card has room" see '[▌│] left running: [^│]*… '
key l l l ' '
check "and its whole ticket says all of why" see '│ left running: it holds #9 '
key Escape
check "put away again" gone '│ left running: it holds #9 '
key j j j
check "where the pick goes no further than the last shown" see '╰ edit ─ priority ╯'
$bin -L $in board 21
check "arena board and the id of a done card older than those shown has its whole ticket over the board" see '│ #21 Lights '
key Escape
check "put away as any other" gone '│ #21 Lights '
key M-b

# each cell of a line of `capture-pane -e` as the attributes it is drawn in: fg/bg/flags
attrs() {
  setopt localoptions extendedglob
  local s=$1 fg= bg= k v i
  local -a ps
  local -aU fl
  while [[ -n $s ]]; do
    if [[ $s == $'\e['[0-9\;]#m* ]]; then
      ps=(${(s:;:)${${s%%m*}#$'\e['}})
      s=${s#*m}
      (( $#ps )) || ps=(0)
      for (( i = 1; i <= $#ps; i++ )); do
        case $ps[i] in
          (0) fg= bg= fl=() ;;
          (38|48)
            k=$ps[i]
            if [[ $ps[i+1] == 5 ]]; then v="5;$ps[i+2]"; (( i += 2 )); else v="2;$ps[i+2];$ps[i+3];$ps[i+4]"; (( i += 4 )); fi
            if [[ $k == 38 ]]; then fg=$v; else bg=$v; fi ;;
          (39) fg= ;;
          (49) bg= ;;
          (3[0-7]|9[0-7]) fg=$ps[i] ;;
          (4[0-7]|10[0-7]) bg=$ps[i] ;;
          (22) fl=(${fl:#[12]}) ;;
          (2[3-9]) fl=(${fl:#${ps[i]#2}}) ;;
          (*) fl+=($ps[i]) ;;
        esac
      done
    elif [[ $s == $'\e'* ]]; then
      s=${s#?}
    else
      print -r -- "$fg/$bg/${(oj:,:)fl}"
      s=${s#?}
    fi
  done
}
# the cells whose attributes differ between two pictures of `capture-pane -e`: row, column, and its attributes after
changed() {
  local -a la=("${(@f)1}") lb=("${(@f)2}") a b
  local r c
  for (( r = 1; r <= $#la || r <= $#lb; r++ )); do
    [[ $la[r] == "$lb[r]" ]] && continue
    a=("${(@f)$(attrs "$la[r]")}")
    b=("${(@f)$(attrs "$lb[r]")}")
    for (( c = 1; c <= $#a || c <= $#b; c++ )); do
      [[ $a[c] != $b[c] ]] && print -r -- "$r $c $b[c]"
    done
  done
}
# a capture can land mid-frame: the picture once two a tenth of a second apart agree
pic() {
  local was now=$(outer capture-pane -ep -t o) i
  for i in {1..30}; do
    was=$now
    zselect -t 10
    now=$(outer capture-pane -ep -t o)
    [[ $now == "$was" ]] && break
  done
  print -r -- "$now"
}
rowof() { screen | grep -n -m1 -F -- "$1" | cut -d: -f1 }
colof() { local l=$(screen | sed -n $1p); [[ $l == *"$2"* ]] || return 1; local p=${l%%"$2"*}; print $(( ${#p} + 1 )) }
# the column of the first │ at or after column $2 of row $1
barof() { local l=$(screen | sed -n $1p); local p=${${l[$2,-1]}%%│*}; print $(( $2 + ${#p} )) }
park() { mouse 35 $rest_x $rest_y M }
# The pointer from where nothing is under it to column $1, row $2: the screen's text is as it
# was, and only cells in rows $3 to $4 and columns $5 to $6 changed, each now underlined; with no
# rows given, nothing changed. Then away again, and it is all as it was.
hovered() {
  local text before after cell
  local -a cells f
  park
  zselect -t 30
  before=$(pic) text=$(screen)
  mouse 35 $1 $2 M
  if [[ -n $3 ]]; then await eval '[[ $(pic) != "$before" ]]' || { print "      nothing changed"; return 1 }; fi
  zselect -t 30
  after=$(pic)
  [[ $(screen) == "$text" ]] || { print "      text changed"; diff <(print -r -- "$text") <(screen) | sed 's/^/      /'; return 1 }
  cells=("${(@f)$(changed "$before" "$after")}")
  cells=("${(@)cells:#}")
  if [[ -z $3 ]]; then
    (( $#cells == 0 )) || { print -l -- "      changed:" "${cells[@]}"; return 1 }
  else
    for cell in "${cells[@]}"; do
      f=(${=cell})
      (( f[1] >= $3 && f[1] <= $4 && f[2] >= $5 && f[2] <= $6 )) || { print "      outside: $cell"; return 1 }
      [[ ,${f[3]##*/}, == *,4,* ]] || { print "      not underlined: $cell"; return 1 }
    done
  fi
  park
  await eval '[[ $(pic) == "$before" ]]' || { print "      not as it was after"; return 1 }
}
print -r -- '{"tickets":[{"id":40,"repo":"arena","title":"Hover me","kind":"ticket","status":"todo","priority":"med","blocked_by":[]},'\
'{"id":41,"repo":"menard","title":"Over there","kind":"ticket","status":"doing","priority":"med","blocked_by":[]}],'\
'"orchestrator":{"on":true,"running":true}}' >$tmp/run/babylon/board.json
claude alpha:one stop '{"last_assistant_message": "Hovered"}'
inner set -p -t alpha:one @arena_claude_since $(($(date +%s) - 7300))
inner split-window -h -t orchestrator:orch sh
outer resize-window -t o -x 160
key M-b
key '`'
see '╭─ ○ orchestrator · idle '
see '#40 Hover'
see '╭─ doing 1 '
check "the rail lists a Claude for the pointer to rest on" see '│ . one +2h'
rest_x=$(( $(colof 2 '╭─ doing') + 3 )) rest_y=18
r=1 c=$(colof 1 ' menard ')
check "the pointer on a tab underlines it and changes nothing else" hovered $((c + 2)) $r $r $r $c $((c + 9))
c=$(colof 2 ' + ')
check "and on the + that files a ticket" hovered $((c + 1)) 2 2 2 $c $((c + 2))
r=$(rowof '#40 Hover')
c=$(colof $r '#40')
check "on a card it underlines its title" hovered $((c + 3)) $r $r $((r + 1)) $((c - 1)) $(barof $r $c)
r=$(rowof '╰ go ')
c=$(colof $r ' give ')
check "and on one of the picked card's actions, that action" hovered $((c + 2)) $r $r $r $c $((c + 5))
rail_w=$(colof 1 '╮')
r=$(rowof '│ alpha ')
check "on the rail, a session's row" hovered 4 $r $r $r 2 $((rail_w - 1))
r=$(rowof ' one ')
check "and a Claude's" hovered 4 $r $r $r 2 $((rail_w - 1))
ox=$(colof 1 '╭─ ○ orchestrator')
divide=$(barof 3 $((ox + 1)))
for x y what in $ox 10 'its left edge' 160 10 'its right edge' $((ox + 12)) 1 'its top edge' \
  $((ox + 4)) 23 'its foot' $((ox + 4)) 24 'the row under it' $divide 10 'the line between its panes' \
  $((ox - 1)) 10 'the gap between it and the board' $rail_w 10 "the rail's edge"; do
  check "with the orchestrator's column beside the board, the pointer on $what changes nothing" hovered $x $y
done
pick_ink() {
  local r=$(( $(rowof '#40 Hover') - 1 ))
  local c=$(( $(colof $((r + 1)) '#40') - 2 ))
  [[ $(attrs "$(pic | sed -n ${r}p)" | sed -n ${c}p) == "5;$1/"* ]]
}
check "the picked card is in the accent while the board has the keys" await pick_ink 4
key M-l
check "and dim while the orchestrator's column has them" await pick_ink 8
key M-h
await pick_ink 4
key M-b
inner kill-pane -t orchestrator:orch.1
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
  "env -u TMUX HOME=$tmp XDG_RUNTIME_DIR=$tmp/run ARENA_REDUCED_MOTION=1 $bin -L $in board 7; echo EXIT \$?; cat"
check "with no arena running, arena board and an id starts one with the board on that ticket" see '│ Which colour\? +│'
untold() { ! grep -q 'arena board' $tmp/other-out }
check "and a control-mode client that is no arena is told nothing" untold
key Escape Escape M-q
check "which leaves as any other" see 'EXIT 0'
none() { $bin -L $in "$@" 2>/dev/null; [[ $? == 3 ]] }
check "with no arena running, arena show exits 3" none show %0
check "and arena inbox does too" none inbox
check "arena --help lists the doors" test -n "$($bin --help | grep -F 'arena [-L socket] show')"
outer new-window -t o \
  "env -u TMUX HOME=$tmp XDG_RUNTIME_DIR=$tmp/run ARENA_REDUCED_MOTION=1 $bin -L $in; echo EXIT \$?; cat"
check "arena with no session named opens home: the plan, the orchestrator's column pinned beside it" see '╭─ ○ orchestrator · idle '
check "the plan, with its head" see '◆ plan  B board'
check "next as babylon gives it" see '1 #7 +tlon +Lights +free now'
check "and its why under it" see 'the light switch'
check "the column with the keys" await orch_lit
key C-Space
key B
check "B shows the board" see ' board  every'
check "in the plan's place" gone '◆ plan'
key b
check "and b comes home to the plan" see '◆ plan  B board'
# the click that focuses a new terminal window lands anywhere in it
mouse 0 100 24 M
mouse 0 100 24 m
key -l 'echo restarted-jkdufltb'
key Enter
check "a click on the row under the column leaves it the keys, in insert: a sentence reaches its pane whole" await said orchestrator:orch restarted-jkdufltb
key M-b
gone ' board  every'
key -l 'echo worker-jkdufltb'
key Enter
check "and the board closed, a worker's pane gets it whole too" await said alpha: worker-jkdufltb
key M-b
see ' board  every'
cp $tmp/run/babylon/board.json $tmp/board.nolook
print -r -- '{"tickets":[],"needs_you":[{"id":"ask:6","kind":"ask","ticket":307,"repo":"tlon","text":"#307 tlon  asks: Which?","doc":null,"actions":[{"key":"1","label":"One","argv":["babylon","answer","6","1"]}]}]}' >$tmp/run/babylon/board.json
see '#307 tlon  asks: Which\?'
key ']'
key o
zselect -t 100
doc_window() { [[ $(inner list-windows -a -F '#{window_name}') == *doc* ]] }
check "o on a row that names no doc opens nothing" await eval '! doc_window'
print -r -- '{"tickets":[],"needs_you":[{"id":"ask:6","kind":"ask","ticket":307,"repo":"tlon","text":"#307 tlon  asks: Which?","doc":"docs/none-jkdufltb.md","actions":[{"key":"1","label":"One","argv":["babylon","answer","6","1"]}]}]}' >$tmp/run/babylon/board.json
check "a decision that names a doc keeps its place and wears a doc mark, with o to open it" see '#307 tlon  asks: Which\? ¶'
print -r -- '{"tickets":[],"needs_you":[{"id":"ask:6","kind":"look","ticket":307,"repo":"tlon","text":"#307 tlon  look at: docs/none-jkdufltb.md","doc":"docs/none-jkdufltb.md","actions":[{"key":"y","label":"looks good","argv":["babylon","call","answer_ask","{\"id\":6}"]},{"key":"c","label":"change","argv":null,"needs":"words"}]}]}' >$tmp/run/babylon/board.json
check "a look at is an item with its doc named and o to open it" see 'o open   y looks good'
key ']'
key o
check "o opens its doc in a window of its own" await doc_window
check "which says so when the file is not in the ticket's repo" await eval 'inner capture-pane -p -t "$(inner list-windows -a -F "#{window_id} #{window_name}" | awk "\$2==\"doc\"{print \$1}")" | grep -q "no such file: .*projects/tlon/docs/none-jkdufltb.md"'
cp $tmp/board.nolook $tmp/run/babylon/board.json
key M-b
key M-q
gone ' board  every'
key M-q
check "and leaves as any other" see 'EXIT 0'

exit $((fails > 0))
