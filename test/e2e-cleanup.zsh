#!/usr/bin/env zsh
# e2e.zsh's private tmux servers: a run that is killed takes its own down, and the next run takes
# down those of a run that could not. In a socket directory of its own, so no real run is touched.
zmodload zsh/zselect

root=${0:A:h:h}
export TMUX_TMPDIR=$(mktemp -d)
socks=$TMUX_TMPDIR/tmux-$UID
fails=0

cleanup() {
  local s
  for s in $socks/*(N); do tmux -L ${s:t} kill-server 2>/dev/null; done
  rm -rf $TMUX_TMPDIR
}
trap cleanup EXIT

answers() { tmux -L $1 list-sessions &>/dev/null }
silent() { ! answers $1 && [[ ! -e $socks/$1 ]] }
await() {
  local i
  for i in {1..100}; do
    "$@" && return 0
    zselect -t 5
  done
  return 1
}
check() {
  local name=$1; shift
  if "$@"; then print "ok    $name"; else print "FAIL  $name"; fails=$((fails + 1)); fi
}

dead=$(sh -c 'echo $$')
tmux -L arena-e2e-in-$dead -f /dev/null new-session -d sleep 600
tmux -L arena-e2e-out-$dead -f /dev/null new-session -d sleep 600

zsh $root/test/e2e.zsh &>/dev/null &
run=$!
check "a run starts both of its servers" await answers arena-e2e-out-$run
check "and takes down the inner server of a run whose pid is gone" silent arena-e2e-in-$dead
check "and its outer one" silent arena-e2e-out-$dead

kill -TERM $run
wait $run
check "killed mid-run, its inner server no longer answers" silent arena-e2e-in-$run
check "nor its outer one" silent arena-e2e-out-$run

exit $((fails > 0))
