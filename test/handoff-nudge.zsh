#!/usr/bin/env zsh
# handoff-nudge.sh against a fake meter: nudges once, past 60% of the context, never twice
root=${0:A:h:h}
tmp=$(mktemp -d)
trap 'rm -rf $tmp' EXIT
mkdir -p $tmp/sessions
export XDG_RUNTIME_DIR=$tmp
fails=0
stop() { print -r -- ${2:-'{"session_id":"s1"}'} | sh $root/hooks/handoff-nudge.sh }
check() {
  local name=$1; shift
  if "$@"; then print "ok    $name"; else print "FAIL  $name"; fails=$((fails + 1)); fi
}

print '{"ctx":41}' > $tmp/sessions/s1.meter
check "under the threshold, nothing" test -z "$(stop)"
print '{"ctx":62}' > $tmp/sessions/s1.meter
check "a subagent's stop takes none" test -z "$(stop x '{"session_id":"s1","agent_id":"a1"}')"
check "past it, a stop is told to write a handoff" test "$(stop | jq -r .decision)" = block
check "a second stop is not" test -z "$(stop)"
print '{"ctx":80}' > $tmp/sessions/s2.meter
check "another session has its own" test "$(stop x '{"session_id":"s2"}' | jq -r .decision)" = block
check "with no meter, nothing" test -z "$(stop x '{"session_id":"s3"}')"
check "a session id cannot leave the dir" test -z "$(stop x '{"session_id":"../x"}')"

exit $fails
