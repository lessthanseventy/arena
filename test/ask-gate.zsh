#!/usr/bin/env zsh
# ask-gate.sh against a fake board: AskUserQuestion is denied where a ticket is held, allowed elsewhere
root=${0:A:h:h}
tmp=$(mktemp -d)
trap 'rm -rf $tmp' EXIT
fails=0

print -r -- '{"tickets":[{"id":915,"claimed_by":"%9"},{"id":916,"claimed_by":null}]}' > $tmp/board.json
server=${TMUX_TMPDIR:-/tmp}/tmux-$(id -u)/default
hook() { # pane [json] [board]
  print -r -- "${2:-{\}}" | BABYLON_BOARD="${3:-$tmp/board.json}" TMUX=$server,1,0 TMUX_PANE=$1 sh $root/hooks/ask-gate.sh
}
check() {
  local name=$1; shift
  if "$@"; then print "ok    $name"; else print "FAIL  $name"; fails=$((fails + 1)); fi
}

check "a session holding a ticket is denied, told to use ask_human" \
  test "$(hook %9 | jq -r '.hookSpecificOutput | .permissionDecision + " " + (.permissionDecisionReason | test("ask_human") | tostring)')" = "deny true"
check "a session holding none asks as usual" test -z "$(hook %8)"
check "a subagent of the holder asks as usual" test -z "$(hook %9 '{"agent_id":"a1"}')"
check "with no board: nothing" test -z "$(hook %9 '{}' $tmp/none.json)"
check "on another tmux server: nothing" test -z "$(print '{}' | BABYLON_BOARD=$tmp/board.json TMUX=${server:h}/other,1,0 TMUX_PANE=%9 sh $root/hooks/ask-gate.sh)"

exit $fails
