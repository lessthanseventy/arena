#!/usr/bin/env zsh
# babylon-inbox.sh against a fake babylon CLI: what it hands Claude, and nothing when there is nothing
root=${0:A:h:h}
tmp=$(mktemp -d)
trap 'rm -rf $tmp' EXIT
mkdir -p $tmp/babylon/bin
fails=0

fake() {
  print -r -- "#!/bin/sh
[ \"\$1 \$2\" = 'call inbox' ] && [ \"\$TMUX_PANE\" = '%7' ] && printf '%s' '$1'" > $tmp/babylon/bin/babylon
  chmod +x $tmp/babylon/bin/babylon
}

hook() { print -r -- ${2:-'{}'} | CLAUDE_PLUGIN_ROOT=$tmp TMUX_PANE=${3:-%7} sh $root/hooks/babylon-inbox.sh $1 }

check() {
  local name=$1; shift
  if "$@"; then print "ok    $name"; else print "FAIL  $name"; fails=$((fails + 1)); fi
}

fake '[{"text":"#4 landed"},{"text":"#5 sent back"}]'
check "after a tool call, held messages are context for the turn" \
  test "$(hook tool | jq -r .hookSpecificOutput.additionalContext)" = $'babylon: #4 landed\nbabylon: #5 sent back'
check "at a stop, they keep it going" test "$(hook stop | jq -r '.decision + " " + .reason')" = $'block babylon: #4 landed\nbabylon: #5 sent back'
check "another pane's are not its" test -z "$(hook tool '{}' %8)"
check "a subagent's tool call takes none: they wait for the session" test -z "$(hook tool '{"agent_id":"a1"}')"

fake '[]'
check "with none held, it says nothing" test -z "$(hook tool)$(hook stop)"

rm $tmp/babylon/bin/babylon
check "with no babylon, nothing, and no failure" test -z "$(hook stop)"

exit $fails
