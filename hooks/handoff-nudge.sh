#!/bin/sh
# At a stop, once per session, past 60% of its context: the reason to go on is to write a handoff.
# The meter is the statusline's, in the session's record directory; the marker beside it is what
# makes the nudge one. A hook must never fail a turn: every miss is silent.
json=$(cat)
printf '%s' "$json" | jq -e '.agent_id // empty' >/dev/null 2>&1 && exit 0
sid=$(printf '%s' "$json" | jq -r '.session_id // empty' 2>/dev/null)
case $sid in "" | */* | .*) exit 0 ;; esac
sessions="${XDG_RUNTIME_DIR:-/tmp}/sessions"
[ ! -e "$sessions/$sid.nudged" ] || exit 0
ctx=$(jq -r '.ctx // empty' "$sessions/$sid.meter" 2>/dev/null)
case $ctx in "" | *[!0-9.]*) exit 0 ;; esac
[ "${ctx%.*}" -ge 60 ] || exit 0
: >"$sessions/$sid.nudged" || exit 0
m="babylon: your context is past 60%: write a handoff now. Commit uncommitted work as a WIP commit, then call handoff with where it stands and the next step."
jq -nc --arg m "$m" '{systemMessage: $m, decision: "block", reason: $m}'
exit 0
