#!/bin/sh
# Refuses a Bash call whose `tmux kill-server` names no socket (-L or -S). Inside a pane $TMUX
# names the server before TMUX_TMPDIR is looked at, so a server meant as private is the one every
# session runs in. The hook's JSON is on stdin. Every miss is silent: without jq nothing is refused.
command=$(jq -r '.tool_input.command // ""' 2>/dev/null | tr '\n' ';')
s='[[:space:]]'
# tmux where a command starts, after env and assignments, then its own flags, then kill-server
kills=$(printf '%s' "$command" | grep -oE \
	"(^|[;&|(\`'\"])$s*(env$s+)?(-u$s+[^[:space:]]+$s+)*([A-Za-z_][A-Za-z0-9_]*=[^[:space:]]*$s+)*tmux($s+-[A-Za-z0-9]+($s+[^-;&|[:space:]][^[:space:]]*)?)*$s+kill-server")
[ -n "$kills" ] || exit 0
printf '%s\n' "$kills" | grep -qvE "tmux.*$s-[LS]" || exit 0
jq -nc '{hookSpecificOutput: {hookEventName: "PreToolUse", permissionDecision: "deny", permissionDecisionReason:
	"tmux kill-server here names no socket, so it would end the server every session runs in: inside a pane $TMUX is asked before TMUX_TMPDIR. Start a private server with `tmux -L <name> -f /dev/null …` and end it with `tmux -L <name> kill-server`."}}'
exit 0
