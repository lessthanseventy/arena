#!/bin/sh
# Claude Code's hook for arena: sets the pane option @arena_claude, which arena marks the window
# by, @arena_claude_since, when that last changed, and what it is about: @arena_claude_prompt, the
# turn's prompt, and @arena_claude_doing, the tool it is on or what it waits for. $1 is the event
# (prompt | tool | stop | waiting | end), the hook's JSON is on stdin. A hook must never fail a
# turn: every miss is silent and the exit is 0. Without jq the text is left out.
pane=${TMUX_PANE:-}
[ -n "$pane" ] || exit 0
opt() { tmux set -p -t "$pane" "$1" "$2" 2>/dev/null; }
# A line of the hook's JSON, picked out by jq, at most 80 characters. arena reads it between tabs.
text() { command -v jq >/dev/null && jq -r "$1"' | tostring | gsub("\t"; " ") | .[0:80]' 2>/dev/null; }
case ${1:-} in
prompt)
	mark=working
	opt @arena_claude_prompt "$(text '[.prompt // "" | splits("\n") | select(test("\\S"))][0] // ""')"
	opt @arena_claude_doing ''
	;;
tool)
	mark=working
	opt @arena_claude_doing "$(text '.tool_name + " " + (.tool_input | .command // (.file_path // .path // "" | split("/") | last) // .pattern // .description // .url // "" | tostring | split("\n")[0])')"
	;;
waiting)
	mark=waiting
	opt @arena_claude_doing "$(text '.message // "" | sub("^Claude needs your permission to use "; "allow ") | sub("^Claude "; "")')"
	;;
# Quotes inside the JSON's strings are escaped, so only a field of its own matches.
stop)
	if grep -Eq '"status" *: *"running"'; then mark=background; else mark='done'; fi
	opt @arena_claude_doing ''
	;;
end)
	for o in @arena_claude @arena_claude_since @arena_claude_prompt @arena_claude_doing; do
		tmux set -pu -t "$pane" $o 2>/dev/null
	done
	exit 0
	;;
*) exit 0 ;;
esac
[ "$(tmux show -pqv -t "$pane" @arena_claude 2>/dev/null)" = "$mark" ] || opt @arena_claude_since "$(date +%s)"
opt @arena_claude "$mark"
exit 0
