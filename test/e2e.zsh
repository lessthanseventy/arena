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
outer new-session -d -s o -x 109 -y 24 \
  "env -u TMUX HOME=$tmp ARENA_REDUCED_MOTION=1 $bin -L $in alpha 2>$tmp/err; echo EXIT \$?; cat"
outer set -s set-clipboard on
# what arena writes, for what a picture of the screen does not show
outer pipe-pane -t o "cat >$tmp/raw"

check "the strip shows, the first column flush against the rail" see '^╭─ sessions ─+╮ ╭─ 1 one '
foot() { local s=$(screen); [[ $(sed -n 3p <<<$s) == '│ alpha '* && $(sed -n 4p <<<$s) == '│ beta '* && $(sed -n 20p <<<$s) == ├─*┤* && $(sed -n 21p <<<$s) == '│ + new '* && $(sed -n 22p <<<$s) == '│ ≡ menu '* ]] }
check "the rail keeps + new and the menu at its foot" await foot
dots() { local s=$(screen); [[ $(sed -n 23p <<<$s) == ╰* && $(sed -n 24p <<<$s) =~ "^ {64}$1 *\$" ]] }
check "a row of its own under the strip has a dot per window, centred on it" await dots '● ○ ○'
mouse 0 67 24 M
mouse 0 67 24 m
check "a click on a dot goes to its window" await dots '○ ● ○'
mouse 0 65 24 M
mouse 0 65 24 m
await dots '● ○ ○'

# A tmux with the pixels patch gives arena's terminal cells of 9x19 pixels, as a real one has.
mkfifo $tmp/sizer
outer -C attach -t o <$tmp/sizer >/dev/null 2>&1 &
exec {sizer}>$tmp/sizer
# tmux tells a pane its size again only when its cells change, so a cell's pixels come with one
print -u $sizer 'refresh-client -C 108x24,9x19'
print -u $sizer 'refresh-client -C 109x24,9x19'
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
mouse 0 29 1 M
mouse 32 99 1 M
mouse 32 101 1 M
mouse 32 104 1 M
mouse 0 104 1 m
check "a title dropped on another column takes its place, and goes no further" await windows alpha 'two one three'
see '─╮ ╭─ 2 one '
mouse 0 37 1 M
mouse 32 27 1 M
mouse 0 27 1 m
check "and back" await windows alpha 'one two three'
see '^╭─ sessions ─+╮ ╭─ 1 one '
mouse 0 29 1 M
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
mouse 65 69 10 M
mouse 67 69 10 M
mouse 65 69 10 M
zselect -t 30
mouse 66 69 10 M
zselect -t 30
check "a sideways wheel among a swipe down is not a step, nor is one on its own" current two
repeat 3 mouse 66 69 10 M
check "three sideways the same way are a step" await current one
zselect -t 30
repeat 8 mouse 67 69 10 M
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
mouse 35 67 5 M
check "over the line between panes the pointer is the one for resizing" await wrote $'\e]22;ew-resize'
mouse 0 67 5 M
mouse 32 60 5 M
mouse 0 60 5 m
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
mouse 0 89 4 M
mouse 32 29 4 M
mouse 0 29 4 m
check "a picture dropped on another takes its place" await windows alpha 'three one renamed'
see '╭─ 1 three ─+╮ ╭─ 2 one '
mouse 0 29 4 M
mouse 32 89 4 M
mouse 0 89 4 m
check "and back" await windows alpha 'one renamed three'
see '╭─ 1 one ─+╮ ╭─ 2 renamed '
mouse 0 89 4 M
mouse 32 29 12 M
mouse 0 29 12 m
check "on one of another session, it goes there in front of it" await windows beta 'three solo'
see '╭─ 1 three ─+╮ ╭─ 2 solo '
mouse 0 29 12 M
mouse 32 99 4 M
mouse 0 99 4 m
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
listed() {
  [[ $(line 6) == ├─' agents '─*┤* && $(line 7) == '│ alpha '* && $(line 8) =~ '^│ ▲ three +[0-9]+s │' &&
    $(line 9) == '│   allow Bash '* && $(line 10) =~ '^│ ◐ one +[0-9]+s │' &&
    $(line 11) == '│ beta '* && $(line 12) =~ '^│ ◐ solo +[0-9]+s │' ]]
}
check "the rail lists each session's Claudes under a rule of their own, what one waits for under it" await listed
claude alpha:three end
claude beta:solo waiting '{"message": "Claude is waiting for your input"}'
beta_first() {
  [[ $(line 7) == '│ beta '* && $(line 8) =~ '^│ ▲ solo ' && $(line 9) == '│   is waiting for you…│'* &&
    $(line 10) == '│ alpha '* && $(line 11) =~ '^│ ◐ one ' ]]
}
check "the session whose Claude most wants looking at comes first, and text past the rail is cut" await beta_first
claude alpha:one end
claude beta:solo end
check "with no Claudes left the rule over them goes" gone '├─ agents'

transcript=$tmp/transcript.jsonl
{
  print -r -- '{"type":"ai-title","aiTitle":"Started Here"}'
  for p in one two; print -r -- '{"type":"user","message":{"content":"ask '$p'"}}'
  print -r -- '{"type":"user","message":{"content":[{"type":"tool_result","content":"no"}]}}'
  print -r -- '{"type":"user","message":{"content":"<command-name>/clear</command-name>"}}'
} >$transcript
said() { claude alpha:one $1 '{"prompt": "p", "transcript_path": "'$transcript'"}' }
titled() { [[ $(inner show -pqv -t alpha:one @arena_claude_title) == $1 ]] }
said prompt
check "a Claude is called by the title its conversation began with" titled 'Started Here'
check "which the rail shows in place of its window's name" see '│ ◐ Started Here +[0-9]+s │'
repeat 4 said prompt
check "every fifth prompt Haiku is asked what it is about now" await titled 'Topic From Haiku'
asked() { [[ $(<$tmp/asked) == $'Began as: Started Here\nCalled now: Started Here\nLatest requests, oldest first:\nask one\nask two' && -z $(<$tmp/asked-pane) ]] }
check "from what was typed, with no pane for its own hooks to mark" asked
said stop
check "a stop keeps that topic" titled 'Topic From Haiku'
print -r -- '{"type":"custom-title","customTitle":"Named By Hand"}' >>$transcript
said stop
check "a conversation renamed is called by its name" titled 'Named By Hand'
rm $tmp/asked
repeat 5 said prompt
zselect -t 50
check "and Haiku is not asked again" [ ! -e $tmp/asked ]
said end
check "the end takes the title and its count off too" await [ -z "$(inner show -p -t alpha:one | grep arena_claude)" ]

at() { [[ $(inner list-clients -F '#{session_name}:#{window_name}') == $1 ]] }
claude alpha:three waiting '{"message": "Claude needs your permission to use Bash"}'
claude beta:solo prompt
mouse 0 5 4 M
mouse 0 5 4 m
await at beta:solo
see '│ ▲ three '
key M-n
check "Alt+n goes to the Claude that most wants looking at" await at alpha:three
key M-n
check "and stays where it is with no other waiting or done" at alpha:three
mouse 0 5 11 M
mouse 0 5 11 m
check "a click on a Claude in the rail goes to its window" await at beta:solo
key M-a
check "Alt+a opens the box of every Claude, by urgency" see '│ +◐ agents +by urgency +│'
check "each with what it is doing" see '▲ three +allow Bash +[0-9]+s'
key s
check "s orders them by when they last changed" see '│ +◐ agents +by recent +│'
key s
key Enter
check "Enter goes to the one picked, the first" await at alpha:three
check "and closes the box" gone 'by urgency'
mouse 35 5 8 M
check "the pointer resting on the rail's Claudes opens the box" see 'by urgency'
mouse 35 60 3 M
check "and leaving them and the box closes it" gone 'by urgency'
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
mouse 0 33 $row M
mouse 32 43 $row M
mouse 0 43 $row m
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

key M-q
check "Alt+q leaves cleanly" see 'EXIT 0'
check "and leaves the sessions running" inner has-session -t alpha
check "with nothing on stderr" test ! -s $tmp/err

exit $((fails > 0))
