#!/bin/sh
# Denies Claude Code's own question box (AskUserQuestion) in a session that holds a babylon ticket:
# a question there shows nowhere but its pane, so Your move and the orchestrator cannot answer it.
# The pane id is looked up in babylon's board file. A hook must never fail a turn: every miss is silent.
[ -n "$TMUX_PANE" ] || exit 0
[ "${TMUX%%,*}" = "${TMUX_TMPDIR:-/tmp}/tmux-$(id -u)/default" ] || exit 0
json=$(cat)
printf '%s' "$json" | jq -e '.agent_id // empty' >/dev/null 2>&1 && exit 0
board=${BABYLON_BOARD:-${XDG_RUNTIME_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}}/babylon/board.json}
[ -r "$board" ] || exit 0
jq -e --arg p "$TMUX_PANE" '.tickets | any(.claimed_by == $p)' "$board" >/dev/null 2>&1 || exit 0
jq -nc '{hookSpecificOutput: {hookEventName: "PreToolUse", permissionDecision: "deny", permissionDecisionReason:
	"This session holds a babylon ticket, so ask with ask_human (the same question, options and recommendation): it shows in Your move and the orchestrator can answer it. Then wait for the answer in inbox."}}'
exit 0
