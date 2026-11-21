#!/bin/sh
# babylon's messages for this pane, handed to its Claude without typing a key: after a tool call as
# context it reads mid-turn (tool), or as the reason to go on when it would stop (stop). babylon
# types only into a pane not working. A hook must never fail a turn: every miss is silent.
[ -n "$TMUX_PANE" ] || exit 0
# a subagent's tool call shares the pane: what it is handed never reaches the session
printf '%s' "$(cat)" | jq -e '.agent_id // empty' >/dev/null 2>&1 && exit 0
cli="${CLAUDE_PLUGIN_ROOT:-$(dirname "$0")/..}/babylon/bin/babylon"
msgs=$("$cli" call inbox '{}' 2>/dev/null | jq -r '.[] | "babylon: " + .text' 2>/dev/null)
[ -n "$msgs" ] || exit 0
case "$1" in
tool) jq -nc --arg m "$msgs" '{hookSpecificOutput: {hookEventName: "PostToolUse", additionalContext: $m}}' ;;
stop) jq -nc --arg m "$msgs" '{decision: "block", reason: $m}' ;;
esac
exit 0
