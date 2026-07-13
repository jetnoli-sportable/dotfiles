#!/usr/bin/env bash
# pretooluse-guard.sh — Claude Code PreToolUse hook, layer 1 ("ask") of the
# TASKS_DIR concurrency-safety scheme.
#
# ~/code/tasks is a shared git checkout many concurrent Claude Code agent
# sessions write into. Two real incidents happened when an agent typed a raw
# `git reset --hard` (or similar) straight into a Bash tool call scoped at
# that directory, silently orphaning another session's unpushed commits.
# This script is a cheap "dumb pattern + directory matcher": it does NOT try
# to judge whether a command would actually orphan a commit — it only asks
# the operator to confirm before a dangerous-shaped git command, or a raw
# Edit/Write/MultiEdit, runs anywhere under ~/code/tasks. The real
# correctness judgment lives in a separate git-side hook (a different unit,
# not this script) — that hook still gets its own say even after this one
# says "ask" and the operator approves.
#
# This script NEVER returns permissionDecision "deny" — only "ask" or
# "allow" (the latter only via the wb-unsafe-rewind sentinel escape hatch,
# see below). A broken/misconfigured guard must never block every Bash call
# an agent makes, so any internal error (missing jq, bad JSON, ...) fails
# OPEN: exit 0 with a single stderr note. The git-side hook is the real
# backstop; this is just an early, cheap warning to a human.
#
# Registered twice in claude/.claude/settings.recommended.json's PreToolUse
# block: once matched on tool_name "Bash" (dangerous-git-command + directory
# scoping, below), once matched on "Edit|Write|MultiEdit" (raw task-file
# writes, since a parallel effort is teaching agents to use a locked `wb
# append` CLI verb instead of editing task files directly — this hook is the
# backstop for every OTHER session that doesn't know that convention yet).
#
# Style note: this is a sibling of claude-notify-hook.sh (same stdin-guard
# `[ ! -t 0 ]` pattern, same $HOME-based paths) but deliberately departs from
# its "always exit 0" property at the decision path — this script sometimes
# prints an "ask" (or sentinel-gated "allow") JSON payload to stdout instead.
#
# PreToolUse hook contract (code.claude.com/docs/en/hooks):
#   stdin:  JSON with top-level cwd / tool_name / tool_input.{command,file_path}
#   stdout (exit 0): {"hookSpecificOutput":{"hookEventName":"PreToolUse",
#                      "permissionDecision":"ask"|"allow"|"deny",
#                      "permissionDecisionReason":"..."}}
#   exit 0 with no stdout = proceed normally (no explicit decision).
#   Any non-zero-non-2 exit is a non-blocking error (tool call proceeds
#   anyway) — this is what H8's fail-open relies on.
set -uo pipefail

TASKS_DIR="${TASKS_DIR:-$HOME/code/tasks}"
KILL_SWITCH="${XDG_STATE_HOME:-$HOME/.local/state}/wb/disable-agent-hook"
SENTINEL_FILE="$TASKS_DIR/.git/WB_ALLOW_REWIND"
SENTINEL_TTL_SECS=120

# --- X4: agent-layer kill-switch — the very first thing this script does,
# before stdin is even read. No file -> no-op, no exceptions. ----------------
[ -e "$KILL_SWITCH" ] && exit 0

# Nothing on stdin (manual/interactive invocation, e.g. a human running this
# by hand) -> nothing to evaluate.
[ -t 0 ] && exit 0

payload="$(cat)"
[ -z "$payload" ] && exit 0

# H8: fail OPEN on any internal error, with exactly one stderr line.
fail_open() {
  echo "pretooluse-guard: $1 -- failing open (tool call proceeds)" >&2
  exit 0
}

# --- H3: dangerous-pattern set. Each alternative is anchored to an actual
# `git` invocation shape (subcommand + the flag that makes it destructive),
# deliberately broader than the observed incidents -- the "ask" posture (never
# "deny") absorbs false positives cheaply. Recovery-net destroyers (reflog
# expire/delete, gc --prune, bare prune) are included because those void the
# reflog/GC recoverability guarantee this whole scheme depends on: no other
# layer can see object pruning once it happens. ------------------------------
DANGEROUS_RE='reset[[:space:]]+--hard'
DANGEROUS_RE="${DANGEROUS_RE}|push\b.*(--force-with-lease|--force\b|(^|[[:space:]])-f([[:space:]]|\$))"
DANGEROUS_RE="${DANGEROUS_RE}|branch\b.*-D\b"
DANGEROUS_RE="${DANGEROUS_RE}|update-ref\b.*-d\b"
DANGEROUS_RE="${DANGEROUS_RE}|filter-branch|filter-repo"
DANGEROUS_RE="${DANGEROUS_RE}|clean\b[^&;|]*-[a-zA-Z]*f[a-zA-Z]*\b"
DANGEROUS_RE="${DANGEROUS_RE}|reflog\b.*(expire|delete)\b"
DANGEROUS_RE="${DANGEROUS_RE}|gc\b.*--prune\b"
DANGEROUS_RE="${DANGEROUS_RE}|(^|[[:space:]])prune\b"

# --- H2: cheap pre-filter, on the RAW stdin text, before ANY jq call or
# directory-resolution work. Which pre-filter applies depends on which
# matcher this invocation is for, so tool_name is sniffed with a raw grep
# first (same style as claude-notify-hook.sh's no-jq session_id fallback) --
# NOT a full jq parse. Getting this branch wrong would defeat the whole
# point of H2: e.g. an agent sitting in ~/code/tasks running plain `git
# status` mentions "code/tasks" nowhere near a dangerous pattern, but its
# `cwd` field DOES contain the substring "code/tasks" -- a naive combined
# "dangerous-pattern OR code/tasks" filter would treat that as a match and
# do full resolution work on every single Bash call issued from inside the
# tasks dir, which is the common case this hook exists to be cheap around.
# So: Bash calls are pre-filtered on the dangerous-pattern regex ONLY
# (independent of any cwd/path text); Edit/Write/MultiEdit calls are
# pre-filtered on the code/tasks substring ONLY (they have no "command" to
# pattern-match against). Anything else exits immediately, no jq. ----------
raw_tool_name="$(grep -o '"tool_name"[[:space:]]*:[[:space:]]*"[^"]*"' <<<"$payload" \
  | head -n1 | sed -E 's/.*"([^"]*)"$/\1/')"

case "$raw_tool_name" in
  Bash)
    grep -Eq "$DANGEROUS_RE" <<<"$payload" || exit 0
    ;;
  Edit|Write|MultiEdit)
    grep -Fq "code/tasks" <<<"$payload" || exit 0
    ;;
  *)
    exit 0
    ;;
esac

command -v jq >/dev/null 2>&1 || fail_open "jq not found in PATH"

jq_get() {
  local filter="$1" out rc
  out="$(printf '%s' "$payload" | jq -r "$filter" 2>/dev/null)"
  rc=$?
  [ $rc -eq 0 ] || fail_open "jq failed to parse hook payload"
  printf '%s' "$out"
}

tool_name="$(jq_get '.tool_name // empty')"
top_cwd="$(jq_get '.cwd // empty')"

# --- path helpers (best-effort; not required to handle every shell-quoting
# edge case -- the git-side hook is the real backstop for anything missed
# here on LOCAL ref updates). ------------------------------------------------

# expand_path PATH BASE -- expand a leading ~ or $HOME, then resolve a
# relative PATH against BASE. Does not itself normalize ".." or resolve
# symlinks -- path_under_tasks_dir (below) does that canonicalization on
# the way in, so every caller gets it for free without expand_path needing
# to know about the containment check it feeds.
expand_path() {
  local p="$1" base="$2"
  # strip one layer of surrounding quotes, if any
  p="${p%\"}"; p="${p#\"}"
  p="${p%\'}"; p="${p#\'}"
  case "$p" in
    "~") p="$HOME" ;;
    "~/"*) p="$HOME/${p#\~/}" ;;
    "\$HOME") p="$HOME" ;;
    "\$HOME/"*) p="$HOME/${p#\$HOME/}" ;;
  esac
  case "$p" in
    /*) : ;;
    *) p="${base%/}/$p" ;;
  esac
  printf '%s' "$p"
}

# path_under_tasks_dir PATH -- true if PATH is TASKS_DIR itself or beneath
# it, judged on the CANONICAL form of both sides (`realpath -m` -- resolves
# `..`/symlinks without requiring the path to actually exist yet, since a
# git/Edit target may not). A prior version compared the raw string
# expand_path returned against a raw $TASKS_DIR: `-C ~/code/dotfiles/../tasks`
# expands to a string containing "dotfiles/../tasks", which a plain prefix
# match against "$TASKS_DIR" (= ".../code/tasks") never matches, even though
# the shell/OS resolves that exact path to the real $TASKS_DIR -- the same
# `..`-traversal containment bug wb_safe_rel (wb.sh) already guards against
# correctly, for a lower-stakes purpose, via this same realpath -m pattern.
path_under_tasks_dir() {
  local p="$1" real_p real_tasks_dir
  [ -z "$p" ] && return 1
  real_p="$(realpath -m -- "$p" 2>/dev/null)" || real_p="$p"
  real_tasks_dir="$(realpath -m -- "$TASKS_DIR" 2>/dev/null)" || real_tasks_dir="$TASKS_DIR"
  case "$real_p" in
    "$real_tasks_dir"|"$real_tasks_dir"/*) return 0 ;;
    *) return 1 ;;
  esac
}

# sentinel_is_fresh -- X1's escape hatch. ~/code/tasks/.git/WB_ALLOW_REWIND
# holds one line "<epoch> <reason>"; fresh within a 120s TTL of that epoch.
# This hook only ever READS/checks it -- it never creates it (that's `wb
# unsafe-rewind`, a different unit) and never consumes/deletes it (only the
# git-side hook consumes it). Callers MUST only call this after a dangerous+
# scoped match has already been established (H6) -- never before pattern/
# scope matching, or a 120s sentinel becomes "allow literally everything".
sentinel_is_fresh() {
  [ -f "$SENTINEL_FILE" ] || return 1
  local line epoch now delta
  line="$(head -n1 "$SENTINEL_FILE" 2>/dev/null)" || return 1
  epoch="${line%% *}"
  case "$epoch" in
    ''|*[!0-9]*) return 1 ;;
  esac
  now="$(date +%s)"
  delta=$(( now - epoch ))
  [ "$delta" -ge 0 ] && [ "$delta" -le "$SENTINEL_TTL_SECS" ]
}

emit_decision() {
  local decision="$1" reason="$2"
  jq -n --arg decision "$decision" --arg reason "$reason" \
    '{hookSpecificOutput: {hookEventName: "PreToolUse", permissionDecision: $decision, permissionDecisionReason: $reason}}'
}

# --- Bash matcher (H1-H6) ----------------------------------------------------
handle_bash() {
  local command matched=0 matched_inv="" current_dir="$top_cwd" normalized inv dir

  command="$(jq_get '.tool_input.command // empty')"
  [ -z "$command" ] && exit 0

  # Marker for the "no directory-resolution work at all" tests: only touched
  # once we are actually about to do per-invocation resolution (H4).
  if [ -n "${GUARD_TEST_MARKER_FILE:-}" ]; then
    : > "$GUARD_TEST_MARKER_FILE"
  fi

  # Split the command into individual invocations on &&, ||, ;, |. Order
  # matters: collapse the two-char operators first so a lone `|` split
  # doesn't fire in the middle of a `||`.
  normalized="$(printf '%s' "$command" | sed -E 's/(&&|\|\|)/\n/g' | sed -E 's/[;|]/\n/g')"

  while IFS= read -r inv; do
    inv="$(printf '%s' "$inv" | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//')"
    [ -z "$inv" ] && continue

    # `cd <path>` sets the working directory for subsequent invocations in
    # this same command that don't carry their own -C/--git-dir.
    if [[ "$inv" =~ ^cd[[:space:]]+(.+)$ ]]; then
      current_dir="$(expand_path "${BASH_REMATCH[1]}" "$current_dir")"
      continue
    fi

    # H3's DANGEROUS_RE patterns are already shaped like git subcommands
    # ("reset --hard", "branch...-D", ...) -- they don't need a literal
    # leading "git" token to be meaningful, and requiring one here let an
    # ordinary env-prefixed or wrapper-prefixed invocation
    # (`TASKS_DIR=/tmp/x git reset --hard`, `\git reset --hard` -- the
    # everyday alias-bypass idiom, `env git reset --hard`,
    # `sh -c "git reset --hard ..."`) skip this check ENTIRELY: none of
    # these are adversarial obfuscation, just ordinary shell idioms an
    # honest agent could type, and the outer H2 pre-filter (which gates
    # entry into this whole script) already matches DANGEROUS_RE against
    # the raw command text with no such prefix requirement -- this inner
    # anchor had drifted stricter than that outer gate. Do the
    # dangerous-pattern + directory-scope check directly against every
    # invocation; a former `^git` requirement used to `continue` past
    # non-git-prefixed lines entirely before ever reaching it.

    # H4: resolve THIS invocation's target dir -- explicit -C/--git-dir
    # first, else the tracked `cd` state, else the fallback top-level cwd.
    # Attempting -C/--git-dir extraction against a non-git invocation is
    # harmless (the regex simply won't match) now that this no longer
    # gates on a literal git prefix first.
    dir="$current_dir"
    if [[ "$inv" =~ -C[[:space:]]+([^[:space:]]+) ]]; then
      dir="$(expand_path "${BASH_REMATCH[1]}" "$current_dir")"
    elif [[ "$inv" =~ --git-dir=([^[:space:]]+) ]]; then
      dir="$(expand_path "${BASH_REMATCH[1]}" "$current_dir")"
      dir="${dir%/.git}"
    fi

    if grep -Eq "$DANGEROUS_RE" <<<"$inv" && path_under_tasks_dir "$dir"; then
      matched=1
      matched_inv="$inv"
      break
    fi
  done <<<"$normalized"

  [ "$matched" -eq 1 ] || exit 0

  # H6: sentinel check happens ONLY here, strictly after H3+H4 already
  # matched and scoped this specific command.
  if sentinel_is_fresh; then
    emit_decision "allow" \
      "A fresh 'wb unsafe-rewind' sentinel authorizes this specific dangerous command ($matched_inv) scoped to \$HOME/code/tasks. The separate git-side hook still has final say."
    exit 0
  fi

  emit_decision "ask" \
    "Matched dangerous git command: \`$matched_inv\` -- scoped to \$HOME/code/tasks, the shared multi-agent task store. This mirrors two real past incidents where a raw destructive git command in that directory silently orphaned another session's unpushed commits. Prefer \`wb sync\` or \`wb unsafe-rewind\` instead of running this directly. Approving here does NOT bypass the separate git-side reference-transaction hook -- it still gets its own say."
  exit 0
}

# --- Edit/Write/MultiEdit matcher (H24) --------------------------------------
handle_edit() {
  local file_path

  file_path="$(jq_get '.tool_input.file_path // empty')"
  [ -z "$file_path" ] && exit 0

  file_path="$(expand_path "$file_path" "$top_cwd")"
  path_under_tasks_dir "$file_path" || exit 0

  emit_decision "ask" \
    "$tool_name is targeting a file under \$HOME/code/tasks (the shared multi-agent task store): $file_path. A parallel effort is teaching agents to use the locked \`wb append\` CLI verb instead of writing task files directly with an editor tool, so concurrent sessions don't clobber each other's writes -- this is the backstop for sessions that don't know that convention yet. Prefer \`wb append\` instead of editing this file directly."
  exit 0
}

case "$tool_name" in
  Bash) handle_bash ;;
  Edit|Write|MultiEdit) handle_edit ;;
  *) exit 0 ;;
esac
