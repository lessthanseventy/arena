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

inner() { tmux -L $in -f /dev/null "$@" }
outer() { tmux -L $out -f /dev/null "$@" }
cleanup() {
  inner kill-server 2>/dev/null
  outer kill-server 2>/dev/null
  rm -rf $tmp
}
trap cleanup EXIT

screen() { outer capture-pane -p -t o }
key() { outer send-keys -t o "$@" }
# button, column and row from 1, then M to press or move and m to let go
mouse() { outer send-keys -t o -l $'\e'"[<$1;$2;$3$4" }

# Up to three seconds for a command to succeed.
await() {
  local i
  for i in {1..60}; do
    "$@" && return 0
    zselect -t 5
  done
  return 1
}
shows() { screen | grep -qE -- "$1" }
hides() { ! shows "$1" }
see() { await shows "$1" }
gone() { await hides "$1" }

check() {
  local name=$1
  shift
  if "$@"; then
    print "ok    $name"
  else
    print "FAIL  $name"
    screen | sed 's/^/      | /'
    fails=$((fails + 1))
  fi
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
outer new-session -d -s o -x 100 -y 24 \
  "env -u TMUX HOME=$tmp ARENA_REDUCED_MOTION=1 $bin -L $in alpha 2>$tmp/err; echo EXIT \$?; cat"
outer set -s set-clipboard on
# what arena writes, for what a picture of the screen does not show
outer pipe-pane -t o "cat >$tmp/raw"

check "the strip shows, the first column flush against the rail" see '^╭─ sessions ─+╮ ╭─ 1 one '

wide() { [[ $(inner display -p -t alpha:one '#{window_width} #{@arena_width}') == $1 ]] }
# a ; that ends an argument ends the command for tmux, unless escaped
key -l $'\e\\;'
check "Alt+; makes the window narrower" see '╭─ 1 one ─{50}╮'
check "and tmux has it that wide, and keeps the width" await wide '58 70'
key "M-'"
check "Alt+' makes it wider" see '╭─ 1 one ─{58}╮'

wrote() { grep -q -- "$1" $tmp/raw }
mouse 35 83 5 M
check "over a column's side the pointer is the one for resizing" await wrote $'\e]22;ew-resize'
mouse 0 83 5 M
mouse 32 66 5 M
mouse 0 66 5 m
check "dragging a column's side resizes its window" see '╭─ 1 one ─{41}╮'
mouse 0 66 5 M
mouse 32 83 5 M
mouse 0 83 5 m
check "and back" await wide '66 80'

windows() { [[ $(inner list-windows -t $1 -F '#{window_name}' | tr '\n' ' ') == "$2 " ]] }
mouse 0 20 1 M
mouse 32 90 1 M
mouse 32 92 1 M
mouse 32 95 1 M
mouse 0 95 1 m
check "a title dropped on another column takes its place, and goes no further" await windows alpha 'two one three'
see '─╮ ╭─ 2 one '
mouse 0 28 1 M
mouse 32 18 1 M
mouse 0 18 1 m
check "and back" await windows alpha 'one two three'
see '^╭─ sessions ─+╮ ╭─ 1 one '
mouse 0 20 1 M
mouse 32 5 3 M
mouse 0 5 3 m
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

rail() { [[ $(screen | grep -oE '^│ (alpha|beta) ' | tr -d '│ \n') == $1 ]] }
order() { [[ $(inner list-sessions -F '#{@arena_order}#{session_name}' | sort | tr -d '\n') == $1 ]] }
key M-J
check "Alt+J moves the session down the rail" await rail betaalpha
check "and its place is kept in tmux" await order 1beta2alpha
key M-K
check "Alt+K moves it up" await rail alphabeta

sessions() { [[ $(inner list-sessions | wc -l) -eq $1 ]] }
mouse 0 5 4 M
mouse 0 5 4 m
check "a click under the last session makes a new one" await sessions 3
see '│ [0-9]+ +1 │'
mouse 1 5 4 M
mouse 1 5 4 m
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

key M-m
key r
key 'renamed' Enter
check "the menu renames the window" see '╭─ 2 renamed '

key M-p
key 'solo' Enter
check "Alt+p jumps to a window of another session" see '╭─ 1 solo '

key M-o
check "Alt+o shows every session's windows" see '╭─ 1 one ─+╮ ╭─ 2 renamed '
mouse 0 80 4 M
mouse 32 20 4 M
mouse 0 20 4 m
check "a picture dropped on another takes its place" await windows alpha 'three one renamed'
see '╭─ 1 three ─+╮ ╭─ 2 one '
mouse 0 20 4 M
mouse 32 80 4 M
mouse 0 80 4 m
check "and back" await windows alpha 'one renamed three'
see '╭─ 1 one ─+╮ ╭─ 2 renamed '
mouse 0 80 4 M
mouse 32 20 12 M
mouse 0 20 12 m
check "on one of another session, it goes there in front of it" await windows beta 'three solo'
see '╭─ 1 three ─+╮ ╭─ 2 solo '
mouse 0 20 12 M
mouse 32 90 4 M
mouse 0 90 4 m
check "and on the rest of a session's row, to that session's end" await windows alpha 'one renamed three'
see '╭─ 3 three '
key Escape
check "Escape leaves the overview" see '╭─ 1 solo ─{40}'

# Output in the three seconds after arena resizes windows is taken for theirs redrawing, and marks
# nothing; tmux stamps activity to the second. The news has to come clear of both.
zselect -t 400
key 'printf "\033[%dGX\bY\n" $(tput cols)' Enter
check "a step back from the last column lands where tmux puts it" see ' Y│$'

inner send-keys -t alpha:one 'echo news' Enter
check "a window with news marks its session in the rail" see '│ alpha +[◌◉] +3 │'

mouse 0 3 3 M
mouse 32 3 2 M
mouse 0 3 2 m
check "dragging a session moves it up the rail" await rail betaalpha
check "and its place is kept in tmux" await order 1beta2alpha

key 'echo hello brave world' Enter
see '│hello brave world'
row=$(screen | grep -n '│hello brave world' | cut -d: -f1)
mouse 0 23 $row M
mouse 32 33 $row M
mouse 0 33 $row m
copied() { [[ $(outer show-buffer 2>/dev/null) == $1 ]] }
check "dragging selects text and copies it" await copied 'brave world'

highlit() { outer capture-pane -p -e -t o | grep -q $'\e\\[7mbrave' }
key M-/
key 'brave' Enter
check "Alt+/ finds text in the history" await highlit
key Escape

key 'exit' Enter
# three was the last window dropped on alpha, which makes it the one alpha shows
check "a session ending moves arena to one that is left" see '╭─ 3 three '
check "and takes it off the rail" gone '│ beta '

key M-q
check "Alt+q leaves cleanly" see 'EXIT 0'
check "and leaves the sessions running" inner has-session -t alpha
check "with nothing on stderr" test ! -s $tmp/err

exit $((fails > 0))
