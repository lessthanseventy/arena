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
print -r -- $'#!/bin/sh\necho "$@" >>'$tmp$'/babylon\n[ "$1" = answer ] && [ -e '$tmp$'/refuse ] && { echo "babylon: no session to answer" >&2; exit 1; }\n[ "$1" = detail ] && printf \'#%s Lights\\n\\nthe whole of it\\n\' "$2"\nexit 0' >$tmp/bin/babylon
chmod +x $tmp/bin/babylon
export PATH=$tmp/bin:$PATH

inner() { tmux -L $in -f /dev/null "$@" }
outer() { tmux -L $out -f /dev/null "$@" }
# kill-server leaves the socket file behind
cleanup() {
  inner kill-server 2>/dev/null
  outer kill-server 2>/dev/null
  rm -f ${TMUX_TMPDIR:-/tmp}/tmux-$UID/{$in,$out}
  rm -rf $tmp
}
trap cleanup EXIT

screen() { outer capture-pane -p -t o }
# what the hook names this checkout's branch: babylon's gate runs on a detached one
worked_on() {
  local b=$(git -C $root branch --show-current)
  print -r -- ${b:-detached $(git -C $root rev-parse --short HEAD)}
}
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
mouse 35 60 10 M
await dots '● ○ ○'

# A tmux with the pixels patch gives arena's terminal cells of 9x19 pixels, as a real one has.
mkfifo $tmp/sizer
outer -C attach -t o <$tmp/sizer >/dev/null 2>&1 &
exec {sizer}>$tmp/sizer
# tmux tells a pane its size again only when its cells change, so a cell's pixels come with one
print -u $sizer 'refresh-client -C 120x24,9x19'
print -u $sizer 'refresh-client -C 121x24,9x19'
outer_cells() { [[ $(outer display -p -t o '#{window_cell_width}') == 9 ]] }
cells() { [[ $(inner display -p -t alpha:one '#{window_cell_width}x#{window_cell_height}') == $1 ]] }
if await outer_cells; then
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
two=$(screen | awk 'NR == 1 { print index($0, "╭─ 2 two") + 3 }')
mouse 0 $two 6 M
mouse 0 $two 6 m
current() { [[ $(inner display -p -t alpha '#{window_name}') == $1 ]] }
await current two
zselect -t 50
untouched() { ! inner capture-pane -pJ -t alpha:two | grep -qF '[<0;' }
check "a click on a window out of focus focuses it, and its program is not clicked" untouched
await shows '│sh-[0-9.]+\$ +│'
inner send-keys -t alpha:two clear Enter

print -rn -- $'\e[?1003h\e[?1006h' >$tmp/any
inner send-keys -t alpha:two "clear; stty -echo -icanon; echo shift-copy-target; cat $tmp/any; timeout 3 cat -v; printf '\\033[?1006l\\033[?1003l'; stty sane" Enter
await shows 'shift-copy-target'
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
see '│ [0-9]+ +1 │'
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
lit() { [[ $(inked 13) == *$'\e[1;7m\e[38;5;4m beta '* && $(inked 7) != *$'\e[1;7m'* ]] }
check "the session in view has its name there lit, as in the list above" lit
looked() { [[ $(inked 14) == *$'\e[38;5;4m ◐ solo '* && $(inked 11) == *$'\e[39m one '* ]] }
check "and the Claude in view its title" looked
claude alpha:renamed prompt '{"prompt": "more"}'
for w in alpha:one alpha:renamed beta:solo; inner set -p -t $w @arena_claude_background 'a shell'
check "more than it has rows for, a Claude whose rows do not all fit is left to a count of the rest" await eval '[[ $(line 16) =~ "^│   ◔ a shell +│" && $(line 17) =~ "^│ \+1 more +│" ]]'
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
check "what still runs in the background" is_opt background '1 agent, 1 shell: Explore the rail · sleep 9'
check "the context its last answer was given" is_opt tokens 253190
check "and the branch it works on" is_opt branch "$(worked_on | cut -c1-40)"
check "the rail has its last words under it" see '│   Done. It loads '
check "and what runs in the background at the foot" see '│   ◔ 1 agent, 1 shell: Explore t… │'
check "with a shell and nothing heard from its agent, its mark is still" see '│ ◔ Named By Hand '
claude alpha:one tool '{"agent_id": "a1", "agent_type": "Explore", "tool_name": "Grep", "tool_input": {"pattern": "rail"}}'
check "a subagent's tool leaves the session as it was" [ "$(opt doing)" = '' -a "$(inner show -pqv -t alpha:one @arena_claude)" = background ]
check "and what runs as it was" is_opt background '1 agent, 1 shell: Explore the rail · sleep 9'
check "but with its agent at work it is drawn working" see '│ ◐ Named By Hand '
claude alpha:one prompt '{"prompt": "<task-notification>\n<task-id>b1</task-id>\n<status>completed</status>\n</task-notification>"}'
check "a shell's notice that it finished takes it off" is_opt background '1 agent: Explore the rail'
check "and is not taken for a prompt" is_opt prompt 'p'
claude alpha:one prompt '{"prompt": "<agent-message from=\"a1\">\ndone\n</agent-message>"}'
check "nor is a subagent's, which takes it off too" is_opt background ''
claude alpha:one tool '{"agent_id": "a2", "agent_type": "Plan", "tool_name": "Grep", "tool_input": {"pattern": "rail"}}'
check "with nothing running, a subagent's tool is shown as what runs" is_opt background 'agent Plan: Grep rail'
claude alpha:one tool '{"hook_event_name": "PostToolUse", "tool_name": "Bash", "tool_input": {"command": "sleep 9", "description": "Soak it"},
  "tool_response": {"backgroundTaskId": "b2"}}'
check "a shell put in the background is listed" is_opt background '1 shell: Soak it'
claude alpha:one tool '{"hook_event_name": "PostToolUse", "tool_name": "Agent", "tool_input": {},
  "tool_response": {"status": "async_launched", "agentId": "a3", "description": "Review it"}}'
check "and an agent sent off" is_opt background '1 agent, 1 shell: Soak it · Review it'
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
claude beta:solo prompt
mouse 0 5 4 M
mouse 0 5 4 m
await at beta:solo
see '│ ◐ solo '
claude alpha:three waiting '{"message": "Claude needs your permission to use Bash"}'
see '│ ▲ three '
notified() { [[ $(tail -1 $tmp/notified 2>/dev/null) == $1 ]] }
check "a Claude out of view come to wait is a desktop notification" await notified '-a|arena|--|three|allow Bash|'
told=$(wc -l <$tmp/notified)
claude beta:solo stop '{"last_assistant_message": "All done"}'
see '│ ◉ solo '
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
see '├─ agents · urgency '
key M-w
check "Alt+w narrows the rail to a session's first letters and its mark" see '^│ al ▲ │ '
check "and a Claude's mark and time" see '^│ ▲ +[0-9]+[sm]│ '
mouse 35 3 9 M
check "the pointer resting on it draws it wide over the strip" see '├─ agents · urgency '
mouse 35 72 3 M
check "and leaving it, narrow again" gone '├─ agents · urgency '
key M-w
check "Alt+w again widens it" see '^╭─ sessions ─+╮ '
claude alpha:three end
claude beta:solo end
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
see '│ alpha +◉ +3 │'
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
'{"id":8,"repo":"arena","title":"Board","kind":"ticket","status":"doing","priority":"high","claimed_by":"'$one'","blocked_by":[7]}],'\
'"backlog":[{"id":12,"repo":"arena","title":"Someday","kind":"ticket","status":"backlog","priority":"med","blocked_by":[]}]}' \
  >$tmp/run/babylon/board.json
check "babylon's board has a row atop the rail, with its counts" see '^│ ▤ board +1 todo  1 doing │'
key M-b
check "Alt+b opens it in place of the strip, its repos as tabs" see ' board   every   arena   tlon '
check "and where its keys are" see '\? keys · esc close'
check "the picked card's actions as chips under it" see '│  go   answer  '
key '?'
check "? shows the board's keys" see "the board's keys"
key x
check "and any key puts them away" gone "the board's keys"
check "a column a status, with its count" see '╭─ doing 1 ─'
railed() { local l=$(inked $1); print -r -- "${${l#*│}%%│*}" }
alone() { [[ $(railed 2) == *$'\e[1;7m'* && $(railed 3)$(railed 4)$(railed 5) != *$'\e[1;7m'* ]] }
check "and the board's row is the one lit, not the session's" alone
check "a card has its number and title" see '│ #8 Board +│'
check "under them its repo and the Claude holding it" see '│ arena · alpha:one'
check "and, sent back from the pipeline, that first, after a question waiting on you" see '│ \? asks · ✗ sent'
key a
check "a shows the picked card's question" see '│ Which colour\? +│'
check "with its options by number" see '│ 2  blue +│'
key 2
checked() { [[ -f $tmp/babylon && $(<$tmp/babylon) == 'answer 5 2' ]] }
check "and a number answers it through babylon" await checked
check "and puts it away" gone 'Which colour'
touch $tmp/refuse
key a
check "asked again" see '│ Which colour\? +│'
key 1
refused() { [[ -f $tmp/notified && $(<$tmp/notified) == *'babylon: no session to answer'* ]] }
check "and refused by babylon, it says why" await refused
rm $tmp/refuse
key ' '
check "Space shows the picked card's whole ticket, as babylon tells it" see '│ the whole of it '
key j j j j j
check "and j scrolls it no further than its last line" see '│ the whole of it '
key Escape
check "and Escape puts it away" gone 'the whole of it'
nofile() { [[ ! -e $tmp/run/babylon/detail-7.txt ]] }
check "leaving no file of it behind" await nofile
key ' '
check "shown again" see '│ the whole of it '
mouse 0 3 12 M
check "and closed with the board by a click on the rail, no file either" await nofile
key M-b
last() { [[ -f $tmp/babylon && $(tail -1 $tmp/babylon) == $1 ]] }
key p
check "p raises the picked card's priority through babylon" await last 'update 7 --priority high'
key J
check "J moves it down its column" await last 'move 7 down'
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
tabrow() { screen | grep -n -m1 ' board   every' | cut -d: -f1 }
tabcol() { local l=$(screen | grep -m1 ' board   every'); local p=${l%%" $1 "*}; print $(( ${#p} + 2 )) }
key '?'
mouse 0 $(tabcol tlon) $(tabrow) M
check "a click while the keys are shown only puts them away" tablit arena
mouse 0 $(tabcol tlon) $(tabrow) M
check "a click on a tab narrows it to that repo" see '#7 Lights'
check "and only that" gone '#8 Board'
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
started() { [[ $(inner list-panes -t '=tlon:t7' -F '#{pane_start_command}' 2>/dev/null) == *'Claim ticket #7 with claim_ticket'* ]] }
key Enter
check "Enter on a free todo card starts a Claude on it, in its repo's session" await started
inner kill-session -t '=tlon'
key M-b
check "and the board opens again on every repo" await tablit every
key r
check "and r again narrows it to the first repo" await tablit arena
key l
key Enter
check "Enter on a card goes to the Claude holding it" see '╭─ 1 one '
mouse 0 3 2 M
check "a click on its row in the rail opens the board again" see ' board   every'
mouse 0 3 2 M
check "and another closes it" gone ' board   every'
inner new-session -d -s babylon -n gate sh
key M-b
check "with babylon's gate session there, the board offers it" see ' gate .*\? keys'
check "and the rail does not list it" gone '│ babylon '
key g
check "g on the board shows the gate" see '╭─ 1 gate '
key M-b
key o
starting() { [[ -f $tmp/babylon && $(tail -1 $tmp/babylon) == orchestrator ]] }
check "o on the board starts the orchestrator when it is not running" await starting
inner new-session -d -s orchestrator -n orch sh
check "and goes to it once its session is there" see '╭─ 1 orch '
check "which the rail does not list" gone '│ orchestrator '
print -r -- '{"tickets":[{"id":9,"repo":"arena","title":"Pipe","kind":"ticket","status":"review","priority":"med","blocked_by":[],"stage":"reviewing"}]}' \
  >$tmp/run/babylon/board.json
check "while babylon works a ticket toward main, the board's row says which and how far" see '^│ ▤ board +◐ #9 reviewing │'
print -r -- '{"tickets":[{"id":9,"repo":"arena","title":"Pipe","kind":"ticket","status":"review","priority":"med","blocked_by":[],"stage":"reviewing"},'\
'{"id":10,"repo":"tlon","title":"Pipe two","kind":"ticket","status":"review","priority":"med","blocked_by":[],"stage":"verifying"}]}' \
  >$tmp/run/babylon/board.json
check "and with two going, the first and how many more" see '^│ ▤ board +◐ #9 reviewing \+1 │'

key M-q
check "Alt+q leaves cleanly" see 'EXIT 0'
check "and leaves the sessions running" inner has-session -t alpha
check "with nothing on stderr" test ! -s $tmp/err

exit $((fails > 0))
