#!/usr/bin/env bash
# Claude Code hook (Stop and SubagentStop): after a finished /ce-code-review of
# the session's own branch, stamps the wb session's task as reviewed. Never
# blocks and never writes the task file itself: it calls wb.sh. Anything it
# can't evaluate passes with no output, exit 0.

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
. "$here/lib-review-target.sh" 2>/dev/null || exit 0
command -v jq >/dev/null 2>&1 && command -v git >/dev/null 2>&1 || exit 0

# This runs on every Stop, so the cheap wb-session check comes before any
# transcript is read.
[ -n "${TMUX_PANE:-}" ] || exit 0
session="$(timeout 2 tmux display -p -t "$TMUX_PANE" '#S' 2>/dev/null)" || exit 0
[ -n "$session" ] || exit 0
for opt in @wb_repo @wb_slug; do
  [ -n "$(timeout 2 tmux show -t "=$session:" -v "$opt" 2>/dev/null)" ] || exit 0
done

payload="$(cat)"
cwd="$(jq -r '.cwd // empty' <<<"$payload" 2>/dev/null)" || exit 0
transcript="$(jq -r '.agent_transcript_path // .transcript_path // empty' <<<"$payload")"
[ -n "$cwd" ] && [ -r "$transcript" ] || exit 0
cur="$(git -C "$cwd" symbolic-ref --short HEAD 2>/dev/null)" || exit 0

# Run folders named in the transcript, with the line each first appears on.
# The prefix class excludes backslash so a JSON "\n" before the path is not
# swallowed into it.
uid="$(id -u)"
pattern="/[^\"\\\\[:space:]]*/compound-engineering-$uid/ce-code-review/[0-9]{8}-[0-9]{6}-[0-9a-f]{8}"
found="$(grep -noE "$pattern" "$transcript" 2>/dev/null | awk -F: '!seen[$2]++ { print $1 "\t" $2 }')"
[ -n "$found" ] || exit 0

# Review invocations (Skill tool calls and typed slash commands) with their
# line numbers, in one jq pass over just the lines that mention ce-code-review.
invocations=""
loaded=0
load_invocations() {
  loaded=1
  invocations="$(grep -n 'ce-code-review' "$transcript" 2>/dev/null | jq -R -c '
    capture("^(?<n>[0-9]+):(?<j>.*)$") | (.n | tonumber) as $n | (.j | fromjson? // empty) as $o
    | if $o.type == "assistant" then
        $o.message.content[]? | select(.type == "tool_use" and .name == "Skill"
          and (.input.skill == "ce-code-review" or .input.skill == "compound-engineering:ce-code-review"))
        | {n: $n, args: (.input.args // "")}
      elif $o.type == "user" and ($o.message.content | type) == "string"
        and ($o.message.content | test("<command-name>/(compound-engineering:)?ce-code-review</command-name>")) then
        {n: $n, args: (($o.message.content | capture("<command-args>(?<a>(?s:.*?))</command-args>") | .a) // "")}
      else empty end' 2>/dev/null)"
}

eligible=()
while IFS=$'\t' read -r line folder; do
  [ -d "$folder" ] && [ ! -L "$folder" ] && [ -O "$folder" ] || continue
  # .wb-stamp-failed: a failed stamp is reported once, not on every Stop.
  [ -f "$folder/metadata.json" ] && [ ! -e "$folder/.wb-stamped" ] && [ ! -e "$folder/.wb-stamp-failed" ] || continue
  [ "$(jq -r '.branch // empty' "$folder/metadata.json" 2>/dev/null)" = "$cur" ] || continue
  args="$(jq -r '.invocation.arguments // empty' "$folder/finish-input.json" 2>/dev/null)"
  if [ -z "$args" ] && [ ! -f "$folder/finish-input.json" ]; then
    [ "$loaded" = 1 ] || load_invocations
    # "=" marks a found invocation, so an empty result means none was found:
    # the target is unknown, and the run is skipped rather than stamped.
    args="$(jq -rs --argjson f "$line" 'map(select(.n < $f)) | if length == 0 then "" else "=" + (last | .args // "") end' <<<"$invocations" 2>/dev/null)"
    [ -n "$args" ] || continue
    args="${args#=}"
  fi
  review_target_is_other "$cwd" "$args" && continue
  eligible+=("$folder")
done <<<"$found"
[ "${#eligible[@]}" -gt 0 ] || exit 0

wb="${WB_SH:-$HOME/.config/scripts/tmux/wb.sh}"
if err="$("$wb" reviewed "$session" 2>&1 >/dev/null)"; then
  for folder in "${eligible[@]}"; do : >"$folder/.wb-stamped"; done
  jq -n --arg m "wb: stamped $session's task as reviewed (review ${eligible[0]##*/})" '{systemMessage: $m}'
else
  for folder in "${eligible[@]}"; do : >"$folder/.wb-stamp-failed"; done
  jq -n --arg m "wb: stamping $session's task as reviewed failed (${err%%$'\n'*}). Run \`wb reviewed\` yourself." '{systemMessage: $m}'
fi
exit 0
