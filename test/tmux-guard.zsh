#!/usr/bin/env zsh
# tmux-guard.sh on Bash calls as the hook is handed them: which it refuses, and which it lets by
root=${0:A:h:h}
fails=0

hook() { jq -nc --arg c "$1" '{tool_name: "Bash", tool_input: {command: $c}}' | sh $root/hooks/tmux-guard.sh }
refused() { [[ "$(hook "$1" | jq -r .hookSpecificOutput.permissionDecision)" == deny ]] }
let_by() { [[ -z "$(hook "$1")" ]] }

check() {
  local name=$1; shift
  if "$@"; then print "ok    $name"; else print "FAIL  $name"; fails=$((fails + 1)); fi
}

check "a kill-server that names no socket is refused" refused 'tmux kill-server'
check "TMUX_TMPDIR names none: in a pane \$TMUX is asked first" \
  refused 'T=$(mktemp -d) && TMUX_TMPDIR=$T tmux new-session -d -s keep sleep 60; TMUX_TMPDIR=$T tmux kill-server'
check "nor does env, a config file, or a line of its own" refused $'cd /tmp\nenv -u TMUX_PANE tmux -f /dev/null kill-server'
check "nor one handed to a shell" refused "sh -c 'tmux kill-server'"
check "the refusal says what to type" \
  test "$(hook 'tmux kill-server' | jq -r '.hookSpecificOutput.permissionDecisionReason | test("-L")')" = true
check "with -L it is the server named" let_by 'tmux -L probe new-session -d; tmux -L probe kill-server'
check "with -S too" let_by 'tmux -S /tmp/probe.sock kill-server'
check "one of two that names none is still refused" refused 'tmux -L probe kill-server; tmux kill-server'
check "after then" refused 'if true; then tmux kill-server; fi'
check "after else" refused 'if false; then :; else tmux kill-server; fi'
check "after do" refused 'for s in a b; do tmux kill-server; done'
check "after {" refused '{ tmux kill-server; }'
check "after !" refused '! tmux kill-server'
check "as the test of an if" refused 'if tmux kill-server; then :; fi'
check "of an elif" refused 'if false; then :; elif tmux kill-server; then :; fi'
check "of a while, after its !" refused 'while ! tmux kill-server; do :; done'
check "of an until" refused 'until tmux kill-server; do :; done'
check "a keyword with -L is let by" let_by 'if true; then tmux -L probe kill-server; fi'
check "a keyword mid-prose opens no command" let_by 'git commit -m "and then tmux kill-server names no socket"'
check "other tmux commands are let by" let_by 'tmux list-sessions; tmux kill-window -t t1'
check "so is the word in prose" let_by 'git commit -m "refuse a tmux kill-server that names no socket"'
check "but not where it opens a quote, as a shell's own command does" refused 'echo "tmux kill-server"'
check "and a call that is not tmux" let_by 'ls'

exit $fails
