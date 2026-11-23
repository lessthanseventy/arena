#!/bin/sh
# After the orchestrator's SendMessage to a session whose ticket has an open ask, the reminder to
# record the answer if the message was it. The recipient is the ListAgents name (`#316 …`) or a
# pane id; babylon's board file says which ticket holds an open ask. A hook must never fail a turn:
# every miss is silent.
[ -n "$TMUX_PANE" ] || exit 0
[ "${TMUX%%,*}" = "${TMUX_TMPDIR:-/tmp}/tmux-$(id -u)/default" ] || exit 0
json=$(cat)
printf '%s' "$json" | jq -e '.agent_id // empty' >/dev/null 2>&1 && exit 0
[ "$(tmux display-message -p -t "$TMUX_PANE" '#{session_name}' 2>/dev/null)" = orchestrator ] || exit 0
board=${BABYLON_BOARD:-${XDG_RUNTIME_DIR:-$HOME/.local/state}/babylon/board.json}
[ -r "$board" ] || exit 0
to=$(printf '%s' "$json" | jq -r 'select(.tool_name == "SendMessage") | .tool_input.to // empty' 2>/dev/null)
[ -n "$to" ] || exit 0
m=$(jq -r --arg to "$to" '
  .tickets[] | select(.ask != null) | . as $t
  | select(($to | test("^#" + ($t.id | tostring) + "( |$)")) or ($t.claimed_by != null and $t.claimed_by == $to))
  | "#\(.id)'"'"'s ask \(.ask.id) is still open: if this message answers it, record it with answer_ask (choice + said)."
' "$board" 2>/dev/null | head -1)
[ -n "$m" ] || exit 0
jq -nc --arg m "$m" '{systemMessage: $m, hookSpecificOutput: {hookEventName: "PostToolUse", additionalContext: $m}}'
exit 0
