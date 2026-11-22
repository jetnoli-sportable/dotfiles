#!/usr/bin/env bash
# Tests for haircut-gate-hook.sh (the review-start gate) and lib-review-target.sh
# (the review-target rule it shares with the review-stamp hook).
#
# Payloads are the captured real ones in tests/fixtures/hook-payloads/ with
# skill, args, prompt and cwd swapped in through jq. Repos are throwaway, built
# under a mktemp dir with a local bare repo as `origin`. Needs git and jq.
#
# Run: bash scripts/.config/scripts/tmux/tests/haircut-gate-hook.test.sh
set -uo pipefail

TMUX_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GATE="${GATE:-$TMUX_DIR/haircut-gate-hook.sh}"
LIB="$TMUX_DIR/lib-review-target.sh"
FIX="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/fixtures/hook-payloads"
ROOT="$(mktemp -d -t haircut-gate.XXXXXX)"
trap 'rm -rf "$ROOT"' EXIT

# Fixture repos must not depend on the host's git config or run its hooks.
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.com
export GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.com
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null
g() { git -c core.hooksPath=/dev/null -c commit.gpgsign=false "$@"; }

fail=0
[ -x "$GATE" ] || {
  echo "FAIL - gate is not executable (Claude Code runs it directly): $GATE"
  fail=1
}
[ -f "$FIX/PreToolUse-Skill.json" ] || {
  echo "FAIL - missing fixtures in $FIX"
  exit 1
}

# new_repo <name>: clone of a bare origin whose HEAD is `development`, on
# branch feat/x with one shared commit on development.
new_repo() {
  local d="$ROOT/$1"
  g init -q --bare -b development "$d.origin"
  g clone -q "$d.origin" "$d" 2>/dev/null
  g -C "$d" checkout -q -b development 2>/dev/null
  echo base >"$d/base.txt"
  g -C "$d" add -A
  g -C "$d" commit -q -m "base"
  g -C "$d" push -q origin development
  g -C "$d" remote set-head origin development >/dev/null
  g -C "$d" checkout -q -b feat/x
  echo "$d"
}
commit() { # <repo> <file> <subject>: commit a change to <file>
  mkdir -p "$(dirname "$1/$2")"
  echo "$3 $RANDOM" >>"$1/$2"
  g -C "$1" add -A
  g -C "$1" commit -q -m "$3"
}
HC='chore: trim comments (haircut)'

skill_payload() { # <skill> <args|NOARGS> <cwd>
  jq --arg s "$1" --arg a "$2" --arg c "$3" \
    '.cwd=$c | .tool_input.skill=$s | if $a=="NOARGS" then del(.tool_input.args) else .tool_input.args=$a end' \
    "$FIX/PreToolUse-Skill.json"
}
prompt_payload() { # <fixture> <cwd> [prompt override]
  jq --arg c "$2" --arg p "${3-}" '.cwd=$c | if $p!="" then .prompt=$p else . end' "$FIX/$1"
}
run() { "$GATE" 2>/dev/null; }

check() { # <label> <expected: allow|deny|block> <payload-json>
  local out got
  out="$(printf '%s' "$3" | run)"
  if [ -z "$out" ]; then
    got=allow
  elif [ "$(jq -r '.hookSpecificOutput.permissionDecision // empty' <<<"$out")" = deny ]; then
    got=deny
  elif [ "$(jq -r '.decision // empty' <<<"$out")" = block ]; then
    got=block
  else got="odd:$out"; fi
  if [ "$got" = "$2" ]; then echo "ok   - $1: $2"; else
    echo "FAIL - $1: expected $2, got $got"
    fail=1
  fi
  LAST="$out"
}
CR=compound-engineering:ce-code-review

# --- Skill events -----------------------------------------------------
r="$(new_repo a)"
commit "$r" src/app.sh "add app"
check "unswept code commit" deny "$(skill_payload $CR "" "$r")"
reason="$(jq -r '.hookSpecificOutput.permissionDecisionReason' <<<"$LAST")"
case "$reason" in *"/haircut"*"add app"*) echo "ok   - deny reason names /haircut and the code commit" ;;
*)
  echo "FAIL - deny reason: $reason"
  fail=1
  ;;
esac
[ "$(jq -r '.hookSpecificOutput.hookEventName' <<<"$LAST")" = PreToolUse ] || {
  echo "FAIL - hookEventName"
  fail=1
}
check "bare skill name, no args key" deny "$(skill_payload ce-code-review NOARGS "$r")"

commit "$r" src/app.sh "$HC"
check "after haircut commit" allow "$(skill_payload $CR "" "$r")"
commit "$r" src/app.sh "more code"
check "code commit after haircut" deny "$(skill_payload $CR "" "$r")"
commit "$r" src/app.sh "$HC"
commit "$r" docs/plan.txt "docs only"
commit "$r" notes.md "md only"
check "haircut then docs/md-only commits" allow "$(skill_payload $CR "" "$r")"

r="$(new_repo b)"
commit "$r" src/a.sh "code"
g -C "$r" commit -q --allow-empty -m 'chore: trim comments (haircut, nothing to trim)'
check "empty nothing-to-trim haircut counts as a sweep" allow "$(skill_payload $CR "" "$r")"

clean_mark() { # <repo> [rev]: record a nothing-to-trim sweep of rev (default HEAD)
  g -C "$1" rev-parse "${2:-HEAD}" >"$(g -C "$1" rev-parse --path-format=absolute --git-path haircut-clean)"
}
r="$(new_repo b2)"
commit "$r" src/a.sh "code"
clean_mark "$r"
check "nothing-to-trim marker at HEAD counts as a sweep" allow "$(skill_payload $CR "" "$r")"
commit "$r" notes.md "md after marker"
check "marker, then md-only commit" allow "$(skill_payload $CR "" "$r")"
commit "$r" src/a.sh "code after marker"
check "code commit after marker" deny "$(skill_payload $CR "" "$r")"
clean_mark "$r"
g -C "$r" commit -q --amend -m "code after marker, amended"
check "marker of a commit no longer on the branch" deny "$(skill_payload $CR "" "$r")"
echo "not-a-sha" >"$(g -C "$r" rev-parse --path-format=absolute --git-path haircut-clean)"
check "garbage marker" deny "$(skill_payload $CR "" "$r")"
g -C "$r" worktree add -q -b feat/y "$ROOT/b2-wt" HEAD 2>/dev/null
clean_mark "$r"
check "marker is per worktree" deny "$(skill_payload $CR "" "$ROOT/b2-wt")"

r="$(new_repo c)"
commit "$r" docs/a.txt "docs"
commit "$r" b.md "md"
check "only docs/md commits" allow "$(skill_payload $CR "" "$r")"
r="$(new_repo d)"
check "no commits ahead of default" allow "$(skill_payload $CR "" "$r")"

# --- args: other targets pass, own branch does not ------------------------
r="$(new_repo e)"
commit "$r" src/a.sh "code"
g -C "$r" branch other-branch development
check "args: PR number" allow "$(skill_payload $CR 123 "$r")"
check "args: PR URL" allow "$(skill_payload $CR https://github.com/o/r/pull/45 "$r")"
check "args: other existing branch" allow "$(skill_payload $CR other-branch "$r")"
check "args: prose naming current branch" deny "$(skill_payload $CR "Review branch feat/x against origin/development" "$r")"
check "args: range ending at current branch" deny "$(skill_payload $CR "origin/development...feat/x" "$r")"
check "args: base: key alone" deny "$(skill_payload $CR "base:origin/development" "$r")"

# --- other skills and prompts -----------------------------------------
check "other skill: haircut" allow "$(skill_payload haircut "" "$r")"
check "other skill: ce-plan" allow "$(skill_payload ce-plan "" "$r")"

# --- UserPromptSubmit -------------------------------------------------
check "typed /ce-code-review" block "$(prompt_payload UserPromptSubmit-ce-code-review.json "$r")"
reason="$(jq -r '.reason' <<<"$LAST")"
case "$reason" in *"/haircut"*"code"*) echo "ok   - block reason names /haircut" ;; *)
  echo "FAIL - block reason: $reason"
  fail=1
  ;;
esac
check "typed plugin-qualified with base:development" block "$(prompt_payload UserPromptSubmit-ce-code-review-base-development.json "$r")"
check "typed command naming a PR" allow "$(prompt_payload UserPromptSubmit-ce-code-review.json "$r" "/ce-code-review 123")"
check "typed command, PR on its second line" allow "$(prompt_payload UserPromptSubmit-ce-code-review.json "$r" $'/ce-code-review\nhttps://github.com/o/r/pull/45')"
g -C "$r" update-ref refs/remotes/origin/colleague-branch development
check "args: bare remote-only branch" allow "$(skill_payload $CR colleague-branch "$r")"
check "args: PR URL after a context line" allow "$(skill_payload $CR $'review the hooks\nhttps://github.com/o/r/pull/45' "$r")"
check "prose mentioning code review" allow "$(prompt_payload UserPromptSubmit-ce-code-review.json "$r" "please do a ce-code-review later")"
check "longer command name is not a match" allow "$(prompt_payload UserPromptSubmit-ce-code-review.json "$r" "/ce-code-review-extra")"

# --- cases the gate cannot evaluate pass -------------------------------
check "not a git repo" allow "$(skill_payload $CR "" "$ROOT")"
r="$(new_repo f)"
commit "$r" src/a.sh "code"
g -C "$r" checkout -q --detach
check "detached HEAD" allow "$(skill_payload $CR "" "$r")"
r="$(new_repo g)"
commit "$r" src/a.sh "code"
g -C "$r" remote remove origin
check "no resolvable default branch" allow "$(skill_payload $CR "" "$r")"
check "garbage stdin" allow "not json"

# --- lib-review-target.sh, direct -------------------------------------
# shellcheck source=/dev/null
. "$LIB"
r="$(new_repo h)"
commit "$r" src/a.sh "code"
g -C "$r" branch other-branch development
g -C "$r" update-ref refs/remotes/origin/remote-only development
tgt() { # <expected: other|own> <args>
  local got=own
  review_target_is_other "$r" "$2" && got=other
  if [ "$got" = "$1" ]; then echo "ok   - target $1: ${2//$'\n'/\\n}"; else
    echo "FAIL - target expected $1, got $got: ${2//$'\n'/\\n}"
    fail=1
  fi
}
tgt other "123"
tgt other "#123"
tgt other "review #123 please"
tgt other "https://github.com/o/r/pull/9"
tgt other "other-branch"
tgt other "origin/remote-only"
# shellcheck disable=SC2016
tgt other 'review `other-branch`.'
tgt other "origin/development...other-branch"
tgt own ""
tgt own "Review branch feat/x against origin/development"
tgt own "origin/development...feat/x"
tgt own "base:origin/development"
tgt own "base:other-branch plan:docs/p.md mode:report --fix"
# base: always means the current checkout (ce-code-review refuses base: with a
# PR or branch target), so numbers and branch names in its prose don't count.
tgt own "base:page-fixes — review branch feat/x (units 1–6: 10 commits from 6ef189d to f13b37c)"
tgt own "--full base:abc1234 (branch other-branch vs development; PR #12 follow-up)"
tgt own "development"
tgt own "no-such-branch"
# A bare name that exists only on the remote: ce-code-review resolves it as
# origin/<name>, so it is another branch.
tgt other "remote-only"
tgt other "review branch remote-only please"
# Arguments spanning lines: the target can sit after the first newline.
tgt other $'focus on hooks\nhttps://github.com/o/r/pull/9'
tgt other $'mode:agent\n#145'
tgt other $'context line\nother-branch'
tgt own $'Review branch feat/x\nagainst origin/development'
tgt own $'focus on hooks\nbase:origin/development'
# The helper is sourced into hooks, so it must leave the caller's variables alone.
before="$(set | /usr/bin/grep -c '^review_target_[a-z_]*=')"
if [ "$before" = 0 ]; then echo "ok   - helper leaves no review_target_ globals"; else
  echo "FAIL - helper leaked $before globals"
  fail=1
fi

exit "$fail"
