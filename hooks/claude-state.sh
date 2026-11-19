#!/bin/sh
# shellcheck disable=SC2016 # jq's own $variables sit in single quotes
# Claude Code's hook for arena: sets the pane option @arena_claude, which arena marks the window
# by, @arena_claude_since, when that last changed, and what it is about: @arena_claude_prompt, the
# turn's prompt, @arena_claude_doing, the tool it is on or what it waits for,
# @arena_claude_title, what the conversation is about, @arena_claude_said, the first line of its
# last answer, @arena_claude_tokens, its context in tokens, @arena_claude_background, what its
# subagents and shells in the background are doing, and @arena_claude_branch, the git branch it
# works on. $1 is the
# event (prompt | tool | stop | waiting |
# end), the hook's JSON is on stdin. A hook must never fail a turn: every miss is silent and the
# exit is 0. Without jq the text is left out.
pane=${TMUX_PANE:-}
[ -n "$pane" ] || exit 0
json=$(cat)
opt() { tmux set -p -t "$pane" "$1" "$2" 2>/dev/null; }
# A line of the hook's JSON, picked out by jq, at most 80 characters. arena reads it between tabs.
text() { command -v jq >/dev/null && printf '%s' "$json" | jq -r "$1"' | tostring | gsub("\t"; " ") | .[0:80]' 2>/dev/null; }
transcript=$(printf '%s' "$json" | jq -r '.transcript_path // ""' 2>/dev/null)
# What the conversation is about: the name it was renamed to, else the topic `retitle` last gave
# it, else the title Claude Code gave it at its start. grep first, as a transcript runs to
# hundreds of megabytes.
title() {
	[ -f "$transcript" ] || return 0
	line=$(grep '"type":"custom-title"' "$transcript" | tail -1)
	[ -n "$line" ] && {
		json=$line text '.customTitle // ""'
		return 0
	}
	topic=$(tmux show -pqv -t "$pane" @arena_claude_topic 2>/dev/null)
	[ -n "$topic" ] && {
		printf '%s\n' "$topic"
		return 0
	}
	line=$(grep '"type":"ai-title"' "$transcript" | tail -1)
	[ -n "$line" ] && json=$line text '.aiTitle // ""'
}
# Claude Code titles a conversation once, at its start; this asks Haiku for its topic now, from the
# last prompts typed, unless it has been renamed. Without TMUX_PANE that Claude's own hooks here
# mark nothing.
retitle() {
	[ -f "$transcript" ] && command -v claude >/dev/null || return 0
	grep -q '"type":"custom-title"' "$transcript" && return 0
	prompts=$(grep '"type":"user"' "$transcript" | tail -400 | jq -r '.message.content |
		if type == "string" then . else ([.[]? | select(.type == "text") | .text] | join(" ")) end |
		select(length > 0 and (test("^(<|\\[|Another Claude session)") | not)) | gsub("\\s+"; " ") | .[0:300]' 2>/dev/null | tail -10)
	[ -n "$prompts" ] || return 0
	began=$(grep '"type":"ai-title"' "$transcript" | head -1 | jq -r '.aiTitle // ""' 2>/dev/null)
	now=$(tmux show -pqv -t "$pane" @arena_claude_title 2>/dev/null)
	topic=$(printf 'Began as: %s\nCalled now: %s\nLatest requests, oldest first:\n%s\n' "$began" "$now" "$prompts" |
		env -u TMUX_PANE timeout 90 claude -p --model haiku --tools "" --no-session-persistence \
			"Above is how a user's conversation with a coding agent began, what it is called now, and what \
they asked since. Short replies like 'yes' or 'go ahead' continue the work before them. If what it is \
called now still fits the latest requests, reply with it unchanged. Otherwise reply with a title of 2 to 4 \
words for what they are building now, the thing and not a detail of it, title case, nothing else: \
no colon, no quotes, no explanation. Examples: Agents List In Rail; Godot House Scene; Erlang \
Install Fix." 2>/dev/null |
		head -1 | tr -d '"*`' | tr '\t' ' ' | sed 's/.*: *//' | awk '{ NF = NF > 5 ? 5 : NF; print }' | cut -c1-40)
	[ -n "$topic" ] || return 0
	opt @arena_claude_topic "$topic"
	opt @arena_claude_title "$topic"
}
# The branch, "detached" and its commit, or "no repo".
branch() {
	cwd=$(printf '%s' "$json" | jq -r '.cwd // ""' 2>/dev/null)
	[ -d "$cwd" ] || return 0
	if ! git -C "$cwd" rev-parse --git-dir >/dev/null 2>&1; then
		b='no repo'
	else
		b=$(git -C "$cwd" branch --show-current 2>/dev/null)
		[ -n "$b" ] || b="detached $(git -C "$cwd" rev-parse --short HEAD 2>/dev/null)"
	fi
	opt @arena_claude_branch "$(printf '%s' "$b" | cut -c1-40)"
}
# The context its last answer was given: what was read from cache, written to it, and sent new.
tokens() {
	[ -f "$transcript" ] || return 0
	grep '"type":"assistant"' "$transcript" | tail -1 | jq -r '.message.usage |
		(.input_tokens // 0) + (.cache_read_input_tokens // 0) + (.cache_creation_input_tokens // 0)' 2>/dev/null
}
# A tool and what it is used on: its command's first line, its file's name, its pattern.
tool_text='.tool_name + " " + (.tool_input | .command // (.file_path // .path // "" | split("/") | last) // .pattern // .description // .url // "" | tostring | split("\n")[0])'
# What runs in the background is kept in @arena_claude_running, as JSON: an entry of id, type
# and description for each shell and subagent started, until a notification says it finished or
# a stop lists what runs. @arena_claude_background is that list as arena shows it.
running() {
	r=$(tmux show -pqv -t "$pane" @arena_claude_running 2>/dev/null)
	printf '%s' "${r:-[]}"
}
keep() {
	opt @arena_claude_running "$1"
	opt @arena_claude_background "$(json=$1 text 'if length == 0 then "" else
		(map(select(.type == "subagent")) | length) as $a | (length - $a) as $s |
		([if $a > 0 then "\($a) agent\(if $a > 1 then "s" else "" end)" else empty end,
			if $s > 0 then "\($s) shell\(if $s > 1 then "s" else "" end)" else empty end] | join(", "))
		+ ": " + (map(.description) | join(" · "))
	end')"
}
# The JSON of `running` with $1, a jq filter on the hook's JSON, done to it as $list.
change() { printf '%s' "$json" | jq -c --argjson list "$(running)" "$1" 2>/dev/null; }
case ${1:-} in
# A shell or subagent finishing comes as a prompt, which nobody typed: it is taken off the list.
prompt)
	mark=working
	if [ -n "$(text '.prompt // "" | select(test("^(<(task-notification|agent-message)|Another Claude session)"))')" ]; then
		l=$(change '[.prompt | scan("<task-id>([^<]+)</task-id>|<agent-message from=\"([^\"]+)\"") | .[] | select(.)] as $done |
			$list | map(select(.id as $id | $done | index($id) | not))') && keep "$l"
		[ "$(tmux show -pqv -t "$pane" @arena_claude 2>/dev/null)" = "$mark" ] || opt @arena_claude_since "$(date +%s)"
		opt @arena_claude "$mark"
		exit 0
	fi
	opt @arena_claude_prompt "$(text '[.prompt // "" | splits("\n") | select(test("\\S"))][0] // ""')"
	opt @arena_claude_doing ''
	opt @arena_claude_said ''
	branch
	t=$(title) && [ -n "$t" ] && opt @arena_claude_title "$t"
	# every fifth prompt the topic is asked again, apart from the turn
	n=$(($(tmux show -pqv -t "$pane" @arena_claude_prompts 2>/dev/null || echo 0) + 1))
	opt @arena_claude_prompts "$n"
	[ $((n % 5)) -eq 0 ] && (retitle) </dev/null >/dev/null 2>&1 &
	;;
# A subagent's tool is its own: the session's state and what it is doing stay as they are, and
# with nothing listed running it is shown as what runs. A shell or subagent the session starts
# in the background is listed.
tool)
	if [ -n "$(text '.agent_id // ""')" ]; then
		[ "$(running)" = '[]' ] && opt @arena_claude_background "$(text '"agent " + (.agent_type // "") + ": " + ('"$tool_text"')')"
		exit 0
	fi
	mark=working
	opt @arena_claude_doing "$(text "$tool_text")"
	l=$(change 'if .tool_response.backgroundTaskId then
			$list + [{id: .tool_response.backgroundTaskId, type: "shell",
				description: (.tool_input.description // .tool_input.command // "" | split("\n")[0])}]
		elif .tool_response.status == "async_launched" then
			$list + [{id: .tool_response.agentId, type: "subagent", description: (.tool_response.description // "")}]
		else empty end') && [ -n "$l" ] && keep "$l"
	;;
waiting)
	mark=waiting
	opt @arena_claude_doing "$(text '.message // "" | sub("^Claude needs your permission to use "; "allow ") | sub("^Claude "; "")')"
	;;
# Quotes inside the JSON's strings are escaped, so only a field of its own matches.
stop)
	if printf '%s' "$json" | grep -Eq '"status" *: *"running"'; then mark=background; else mark='done'; fi
	opt @arena_claude_doing ''
	t=$(title) && [ -n "$t" ] && opt @arena_claude_title "$t"
	opt @arena_claude_said "$(text '[.last_assistant_message // "" | splits("\n") | gsub("^[#>*\\s-]+|[*`]"; "") | select(test("\\S"))][0] // ""')"
	l=$(change '[.background_tasks[]? | select(.status == "running") |
		{id, type, description: (.description // .command // "" | split("\n")[0])}]') && keep "$l"
	n=$(tokens) && [ -n "$n" ] && opt @arena_claude_tokens "$n"
	branch
	;;
end)
	for o in @arena_claude @arena_claude_since @arena_claude_prompt @arena_claude_doing @arena_claude_title \
		@arena_claude_topic @arena_claude_prompts @arena_claude_said @arena_claude_tokens @arena_claude_background @arena_claude_running \
		@arena_claude_branch; do
		tmux set -pu -t "$pane" $o 2>/dev/null
	done
	exit 0
	;;
*) exit 0 ;;
esac
[ "$(tmux show -pqv -t "$pane" @arena_claude 2>/dev/null)" = "$mark" ] || opt @arena_claude_since "$(date +%s)"
opt @arena_claude "$mark"
exit 0
