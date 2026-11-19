#!/bin/sh
# Claude Code's hook for arena: sets the pane option @arena_claude, which arena marks the window
# by, @arena_claude_since, when that last changed, and what it is about: @arena_claude_prompt, the
# turn's prompt, @arena_claude_doing, the tool it is on or what it waits for,
# @arena_claude_title, what the conversation is about, @arena_claude_said, the first line of its
# last answer, @arena_claude_tokens, its context in tokens, @arena_claude_tasks, how many of its
# tasks run in the background, and @arena_claude_branch, the git branch it works on. $1 is the
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
		select(length > 0 and (startswith("<") | not)) | gsub("\\s+"; " ") | .[0:300]' 2>/dev/null | tail -10)
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
branch() {
	cwd=$(printf '%s' "$json" | jq -r '.cwd // ""' 2>/dev/null)
	[ -d "$cwd" ] && opt @arena_claude_branch "$(git -C "$cwd" branch --show-current 2>/dev/null | cut -c1-40)"
}
# The context its last answer was given: what was read from cache, written to it, and sent new.
tokens() {
	[ -f "$transcript" ] || return 0
	grep '"type":"assistant"' "$transcript" | tail -1 | jq -r '.message.usage |
		(.input_tokens // 0) + (.cache_read_input_tokens // 0) + (.cache_creation_input_tokens // 0)' 2>/dev/null
}
case ${1:-} in
prompt)
	mark=working
	opt @arena_claude_prompt "$(text '[.prompt // "" | splits("\n") | select(test("\\S"))][0] // ""')"
	opt @arena_claude_doing ''
	opt @arena_claude_said ''
	opt @arena_claude_tasks 0
	branch
	t=$(title) && [ -n "$t" ] && opt @arena_claude_title "$t"
	# every fifth prompt the topic is asked again, apart from the turn
	n=$(($(tmux show -pqv -t "$pane" @arena_claude_prompts 2>/dev/null || echo 0) + 1))
	opt @arena_claude_prompts "$n"
	[ $((n % 5)) -eq 0 ] && (retitle) </dev/null >/dev/null 2>&1 &
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
	if printf '%s' "$json" | grep -Eq '"status" *: *"running"'; then mark=background; else mark='done'; fi
	opt @arena_claude_doing ''
	t=$(title) && [ -n "$t" ] && opt @arena_claude_title "$t"
	opt @arena_claude_said "$(text '[.last_assistant_message // "" | splits("\n") | gsub("^[#>*\\s-]+|[*`]"; "") | select(test("\\S"))][0] // ""')"
	opt @arena_claude_tasks "$(text '[.background_tasks[]? | select(.status == "running")] | length')"
	n=$(tokens) && [ -n "$n" ] && opt @arena_claude_tokens "$n"
	branch
	;;
end)
	for o in @arena_claude @arena_claude_since @arena_claude_prompt @arena_claude_doing @arena_claude_title \
		@arena_claude_topic @arena_claude_prompts @arena_claude_said @arena_claude_tokens @arena_claude_tasks \
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
