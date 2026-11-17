#!/bin/sh
# Claude Code's hook for arena: sets the pane option @arena_claude, which arena marks the window
# by. $1 is the event (prompt | tool | stop | waiting | end), the hook's JSON is on stdin. A hook
# must never fail a turn: every miss is silent and the exit is 0.
pane=${TMUX_PANE:-}
[ -n "$pane" ] || exit 0
case ${1:-} in
prompt | tool) mark=working ;;
waiting) mark=waiting ;;
# Quotes inside the JSON's strings are escaped, so only a field of its own matches.
stop) if grep -Eq '"status" *: *"running"'; then mark=background; else mark='done'; fi ;;
end)
	tmux set -pu -t "$pane" @arena_claude 2>/dev/null
	exit 0
	;;
*) exit 0 ;;
esac
tmux set -p -t "$pane" @arena_claude "$mark" 2>/dev/null
exit 0
