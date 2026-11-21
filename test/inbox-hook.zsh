#!/usr/bin/env zsh
# babylon-inbox.sh against a fake babylon CLI: what it hands Claude, and nothing when there is nothing
root=${0:A:h:h}
tmp=$(mktemp -d)
trap 'rm -rf $tmp' EXIT
fails=0

fake() {
  print -r -- "#!/bin/sh
[ \"\$1 \$2\" = 'call inbox' ] && [ \"\$TMUX_PANE\" = '%7' ] && printf '%s' '$1'" > $tmp/babylon
  chmod +x $tmp/babylon
}

server=${TMUX_TMPDIR:-/tmp}/tmux-$(id -u)/default
hook() { print -r -- ${2:-'{}'} | BABYLON_CLI=$tmp/babylon TMUX=${4:-$server},1,0 TMUX_PANE=${3:-%7} sh $root/hooks/babylon-inbox.sh $1 }

check() {
  local name=$1; shift
  if "$@"; then print "ok    $name"; else print "FAIL  $name"; fails=$((fails + 1)); fi
}

fake '[{"text":"#4 landed"},{"text":"#5 sent back"}]'
check "after a tool call, held messages are context for the turn" \
  test "$(hook tool | jq -r .hookSpecificOutput.additionalContext)" = $'babylon: #4 landed\nbabylon: #5 sent back'
check "and the human sees them in the conversation too" \
  test "$(hook tool | jq -r .systemMessage)" = $'babylon: #4 landed\nbabylon: #5 sent back'
check "at a stop, they keep it going" test "$(hook stop | jq -r '.decision + " " + .reason')" = $'block babylon: #4 landed\nbabylon: #5 sent back'
check "another pane's are not its" test -z "$(hook tool '{}' %8)"
check "nor the same pane id's on another tmux server" test -z "$(hook tool '{}' %7 ${server:h}/tlon-workspace-1)"
check "a subagent's tool call takes none: they wait for the session" test -z "$(hook tool '{"agent_id":"a1"}')"

fake '[]'
check "with none held, it says nothing" test -z "$(hook tool)$(hook stop)"

rm $tmp/babylon
check "with no babylon, nothing, and no failure" test -z "$(hook stop)"

exit $fails
