#!/usr/bin/env zsh
# ask-reminder.sh against a fake board and a fake tmux: when the orchestrator is reminded, and when not
root=${0:A:h:h}
tmp=$(mktemp -d)
trap 'rm -rf $tmp' EXIT
fails=0

print -r -- '{"tickets":[
 {"id":316,"claimed_by":"%9","ask":{"id":3,"question":"Blue or green?"}},
 {"id":317,"claimed_by":"%10","ask":null},
 {"id":31,"claimed_by":"%11","ask":{"id":4,"question":"x"}}]}' > $tmp/board.json
print -r -- '#!/bin/sh
printf "%s\n" "$FAKE_SESSION"' > $tmp/tmux
chmod +x $tmp/tmux

server=${TMUX_TMPDIR:-/tmp}/tmux-$(id -u)/default
hook() { # to [session] [board]
  jq -nc --arg to "$1" '{tool_name: "SendMessage", tool_input: {to: $to, message: "go blue"}}' |
    PATH=$tmp:$PATH FAKE_SESSION="${2:-orchestrator}" BABYLON_BOARD="${3:-$tmp/board.json}" TMUX=$server,1,0 TMUX_PANE=%1 sh $root/hooks/ask-reminder.sh
}
check() {
  local name=$1; shift
  if "$@"; then print "ok    $name"; else print "FAIL  $name"; fails=$((fails + 1)); fi
}

want="#316's ask 3 is still open: if this message answers it, record it with answer_ask (choice + said)."
check "a send to the ListAgents name of a ticket with an open ask is reminded" \
  test "$(hook '#316 the colour' | jq -r .hookSpecificOutput.additionalContext)" = "$want"
check "so is a send to its pane" test "$(hook %9 | jq -r .hookSpecificOutput.additionalContext)" = "$want"
check "#31 is not #316's" test "$(hook '#31 x' | jq -r .hookSpecificOutput.additionalContext)" = "#31's ask 4 is still open: if this message answers it, record it with answer_ask (choice + said)."
check "a ticket with no open ask: nothing" test -z "$(hook '#317 hi')"
check "a session with no ticket: nothing" test -z "$(hook orchestrator-peer)"
check "from another session: nothing" test -z "$(hook '#316 x' work)"
check "with no board: nothing" test -z "$(hook '#316 x' orchestrator $tmp/none.json)"

print -r -- '{"tickets":[{"id":320,"claimed_by":null,"handed_to":"%12","ask":{"id":5,"question":"x"}}]}' > $tmp/handed.json
check "a send to the pane a card is handed to is reminded" \
  test "$(hook %12 orchestrator $tmp/handed.json | jq -r .hookSpecificOutput.additionalContext)" = "#320's ask 5 is still open: if this message answers it, record it with answer_ask (choice + said)."
mkdir -p $tmp/state/babylon
cp $tmp/board.json $tmp/state/babylon/board.json
xdg() { # the hook with no BABYLON_BOARD and no XDG_RUNTIME_DIR
  jq -nc '{tool_name: "SendMessage", tool_input: {to: "%9", message: "go"}}' |
    env -u BABYLON_BOARD -u XDG_RUNTIME_DIR PATH=$tmp:$PATH FAKE_SESSION=orchestrator XDG_STATE_HOME=$tmp/state TMUX=$server,1,0 TMUX_PANE=%1 sh $root/hooks/ask-reminder.sh
}
check "with no runtime dir the board is under XDG_STATE_HOME" test -n "$(xdg)"

exit $fails
