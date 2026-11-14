#!/usr/bin/env bash
# Claude Code hook: stops a review of the current branch (/ce-code-review via
# the Skill tool, or typed as a slash command) until /haircut has swept the
# branch's latest code commit. One script for PreToolUse (matcher Skill) and
# UserPromptSubmit, told apart by hook_event_name. Anything it can't evaluate
# passes: no output, exit 0.

payload="$(cat)"
# Runs on every prompt and Skill call; nearly none are reviews.
[[ $payload == *ce-code-review* ]] || exit 0

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
. "$here/lib-review-target.sh" 2>/dev/null || exit 0
command -v jq >/dev/null 2>&1 && command -v git >/dev/null 2>&1 || exit 0

event="$(jq -r '.hook_event_name // empty' <<<"$payload" 2>/dev/null)" || exit 0
cwd="$(jq -r '.cwd // empty' <<<"$payload")"
[ -n "$cwd" ] || exit 0

args=""
case "$event" in
  PreToolUse)
    [ "$(jq -r '.tool_name // empty' <<<"$payload")" = Skill ] || exit 0
    case "$(jq -r '.tool_input.skill // empty' <<<"$payload")" in
      ce-code-review | compound-engineering:ce-code-review) ;;
      *) exit 0 ;;
    esac
    args="$(jq -r '.tool_input.args // empty' <<<"$payload")"
    ;;
  UserPromptSubmit)
    prompt="$(jq -r '.prompt // empty' <<<"$payload")"
    rest="${prompt#/compound-engineering:ce-code-review}"
    [ "$rest" = "$prompt" ] && rest="${prompt#/ce-code-review}"
    [ "$rest" = "$prompt" ] && exit 0
    # The command name must end there: not /ce-code-review-extra.
    case "$rest" in "" | [[:space:]]*) ;; *) exit 0 ;; esac
    args="$rest"
    ;;
  *) exit 0 ;;
esac

git -C "$cwd" rev-parse --is-inside-work-tree >/dev/null 2>&1 || exit 0
git -C "$cwd" symbolic-ref -q HEAD >/dev/null 2>&1 || exit 0
review_target_is_other "$cwd" "$args" && exit 0

base="$(review_target_default_branch "$cwd")"
[ -n "$base" ] || exit 0
mb="$(git -C "$cwd" merge-base "$base" HEAD 2>/dev/null)" || exit 0

# Newest first in topological order, not by timestamp: commit dates can run
# backwards after a rebase or amend. Whichever of "code commit" and "haircut
# commit" comes first decides.
unswept=""
while IFS=$'\t' read -r sha subject; do
  # The subject /haircut commits with (claude/.claude/skills/haircut/SKILL.md).
  case "$subject" in "chore: trim comments (haircut"*) break ;; esac
  # Merge commits list no files here, so they never count as code.
  if git -C "$cwd" diff-tree --root --no-commit-id --name-only -r "$sha" 2>/dev/null |
    grep -qv -e '\.md$' -e '^docs/'; then
    unswept="$(git -C "$cwd" log -1 --format='%h %s' "$sha")"
    break
  fi
done < <(git -C "$cwd" log --topo-order --format='%H%x09%s' "$mb..HEAD" 2>/dev/null)
[ -n "$unswept" ] || exit 0

reason="haircut gate: the newest code commit has no /haircut sweep after it ($unswept). Run /haircut, commit its result, then retry the review."
if [ "$event" = PreToolUse ]; then
  jq -n --arg r "$reason" \
    '{hookSpecificOutput: {hookEventName: "PreToolUse", permissionDecision: "deny", permissionDecisionReason: $r}}'
else
  jq -n --arg r "$reason" '{decision: "block", reason: $r}'
fi
exit 0
