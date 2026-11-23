#!/usr/bin/env zsh
# claude-state.sh's session record, $XDG_RUNTIME_DIR/sessions/<id>.json, against a fake tmux
root=${0:A:h:h}
work=$(mktemp -d)
trap 'rm -rf $work' EXIT
mkdir -p $work/bin $work/run $work/repo/lib
git -C $work/repo init -q
print -r -- '#!/bin/sh' > $work/bin/tmux
chmod +x $work/bin/tmux
export PATH=$work/bin:$PATH XDG_RUNTIME_DIR=$work/run TMUX=/tmp/tmux-1000/default,1,0 TMUX_PANE=%7
rec=$work/run/sessions/s1.json
bad=0
send() { jq -nc --arg cwd $work/repo/lib "{session_id: \"s1\", cwd: \$cwd} + $2" | sh $root/hooks/claude-state.sh $1 }
is() {
  local got v=ok
  got=$(jq -r "$1" $rec 2>/dev/null)
  [[ $got == $2 ]] || { v=FAIL; bad=1 }
  printf '%-5s %-12s = %-28s %s\n' $v "$1" "$got" "$3"
}
claim() {
  local what=$1; shift
  if "$@"; then print "ok    $what"; else print "FAIL  $what"; bad=1; fi
}

send start '{source: "startup"}'
is .state idle "a new session sits idle"
is .said null "having been asked nothing"

send prompt '{prompt: "make   the bar\nknow about my sessions"}'
is .state working "a prompt starts work"
is .repo repo "the repo is the git top, not the cwd"
is .socket /tmp/tmux-1000/default "the tmux socket"
is .pane %7 "and the pane"
is .said "make the bar know about my sessions" "what was asked, on one line"
since=$(jq .since $rec)

send tool '{tool_name: "Edit", tool_input: {file_path: "/r/lib/deck.ex", old_string: "a"}}'
is .doing "Edit deck.ex" "a file call names the file"
is .since $since "staying at work keeps since"
send tool '{tool_name: "Bash", tool_input: {command: "ls", description: "List files"}}'
is .doing "List files" "a description wins"
send tool '{tool_name: "TodoWrite", tool_input: {todos: []}}'
is .doing TodoWrite "else the tool"

jq '.goal = "a bar that knows" | .next = "wire the inotify"' $rec > $rec.new && mv $rec.new $rec
send waiting '{notification_type: "permission_prompt", message: "Claude needs your permission to use Bash"}'
is .state waiting "a permission prompt waits on you"
is .doing TodoWrite "and keeps what it was doing"
send tool '{agent_id: "a1", tool_name: "Read", tool_input: {file_path: "/r/x"}}'
is .state waiting "a subagent's tool leaves the state alone"
send stop '{background_tasks: [{status: "running"}]}'
is .state working "a stop with work in the background is still at work"
send stop '{background_tasks: [{status: "completed"}]}'
is .state done "a stop with nothing running is done"
is .said "make the bar know about my sessions" "the ask outlives the turn"
is .goal "a bar that knows" "so does the goal"
is .next "wire the inotify" "and the next step"
send prompt '{prompt: "again"}'
send stopfailure '{error: "rate_limit"}'
is .state done "a turn that ends on an API error is done"
send start '{source: "resume"}'
is .state done "a resumed session keeps its record"

send prompt '{prompt: "<cross-session-message from=\"uds:/run/x.sock\" from-name=\"orchestrator\" from-mode=\"auto\">Orchestrator here,\nfor #427</cross-session-message>"}'
is .said "orchestrator: Orchestrator here, for #427" "a message from another session says who, not the tag"
send prompt '{prompt: "<cross-session-message from=\"uds:/run/x.sock\">hi</cross-session-message>"}'
is .said "another session: hi" "an unnamed sender"
send prompt '{prompt: "<cross-session-message from=\"u\" from-name=\"\">hi</cross-session-message>"}'
is .said "another session: hi" "an empty sender name"
send prompt '{prompt: "<cross-session-message from=\"u\" from-name=\"a\">one</cross-session-message>\n<cross-session-message from=\"u\" from-name=\"b\">two</cross-session-message>"}'
is .said "a: one" "back-to-back messages show the first"
send prompt '{prompt: "<cross-session-message from=\"u\" from-name=\"a\">one</cross-session-message>\nand then some"}'
is .said "a: one" "text after the closing tag"
send prompt '{prompt: "why <cross-session-message from-name=\"x\">y</cross-session-message> raw?"}'
is .said "why <cross-session-message from-name=\"x\">y</cross-session-message> raw?" "a tag quoted mid-sentence stays as typed"

print '{"session_id": "../x"}' | sh $root/hooks/claude-state.sh tool
claim "a session id cannot leave the dir" test ! -e $work/run/x.json
print 'not json' | sh $root/hooks/claude-state.sh tool
claim "bad input exits 0" test $? = 0

env -u TMUX_PANE sh -c 'jq -nc "{session_id: \"s2\", cwd: \"/\", prompt: \"hi\"}" | sh $0/hooks/claude-state.sh prompt' $root
claim "a session outside tmux still has its record" test "$(jq -r .state $work/run/sessions/s2.json)" = working

send start '{source: "resume"}'
jq '.state = "done"' $rec > $rec.new && mv $rec.new $rec
TMUX_PANE=%8 TMUX=/tmp/other,1,0 send start '{source: "resume"}'
is .pane %8 "a start in a new pane moves the record there"
is .socket /tmp/other "and to its socket"
is .state done "and keeps its state"

ARENA_RETITLE=1 sh -c 'jq -nc "{session_id: \"s3\", cwd: \"/\"}" | sh $0/hooks/claude-state.sh start' $root
claim "the retitle subprocess leaves no record" test ! -e $work/run/sessions/s3.json

print '{"ctx":41,"model":"Opus 5.5"}' > $work/run/sessions/s1.meter
send end '{}'
claim "the end removes the record" test ! -e $rec
claim "and the statusline's meter" test ! -e $work/run/sessions/s1.meter
exit $bad
