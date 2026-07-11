#!/usr/bin/env bash
# handoff.sh — route one piece of in-conversation discussion to its worker:
# switch to an already-live session (clipboard handoff) or spawn a fresh one.
#   handoff.sh <repo> <slug>
#
# Entirely mechanical — the /handoff skill (claude/.claude/skills/handoff/
# SKILL.md) owns the conversational judgment (repo/slug inference, rich
# context, first_action); this script only checks for a live session and
# either switches + clipboards, or spawns + injects. `first_action` is never
# a flag here — it lives in the target task file's body (R6).
#
# Design + rationale: docs/plans/2026-07-11-001-feat-handoff-v1-plan.md.
# wb.sh is never modified — see that file's own header and the BASH_SOURCE
# guard at its end, which is exactly what makes sourcing it here safe.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WB="$SCRIPT_DIR/wb.sh"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"
# Safe to source: wb.sh's CLI dispatch is guarded by
# `[ "${BASH_SOURCE[0]}" = "${0}" ]` (wb.sh, end of file), which is false
# when wb.sh is sourced from another script — the same property
# tests/wb-resume.test.sh already relies on. This reuses wb_sanitize/
# wb_task_file (read-only helpers) without hand-copying the sanitize
# transform where it could drift. NOTE: sourcing wb.sh reassigns
# SCRIPT_DIR/SELF to its own values (wb.sh:25-26) — harmless today only
# because handoff.sh never reads $SELF and both scripts live in the same
# directory (so the reassigned $SCRIPT_DIR happens to still be correct);
# $WB is captured above, before sourcing, so it's unaffected either way.
# shellcheck source=wb.sh
source "$WB"

# Poll timeouts — env-var overridable, matching wb.sh's own
# WB_SWEEP_THRESHOLD="${WB_SWEEP_THRESHOLD:-5}" convention (wb.sh:32).
HANDOFF_BOOT_TIMEOUT="${HANDOFF_BOOT_TIMEOUT:-30}"
HANDOFF_PERMISSION_TIMEOUT="${HANDOFF_PERMISSION_TIMEOUT:-20}"

# handoff_wait_for_pane_pattern <target> <timeout_secs> <extended-regex> —
# polls <target>'s recent pane text for <pattern>, 1s between attempts, up
# to <timeout_secs>. Mirrors lib.sh's own tmux_pane_awaiting_input tail-20
# scoping convention — a bounded recent-lines window keeps stale scrollback
# (or handoff.sh's own just-injected pointer sitting in the echoed input
# line before Enter is processed) from ever entering the match.
handoff_wait_for_pane_pattern() {
  local target="$1" timeout="$2" pattern="$3" waited=0
  while [ "$waited" -lt "$timeout" ]; do
    tmux capture-pane -ep -t "$target" 2>/dev/null | tail -n 20 \
      | grep -qE "$pattern" && return 0
    sleep 1; waited=$((waited + 1))
  done
  return 1
}

# handoff_bootstrap_gap <repo_dir> — true (exit 0) when <repo_dir> has
# NEITHER a .worktree-bootstrap manifest NOR any root .env* file (R11).
# Mirrors wb_bootstrap's own detection (wb.sh:142-157) read-only — it never
# performs the actual copy, just answers "would wb_bootstrap have found
# anything to copy?" so the spawn path can decide whether to warn without
# re-implementing the bootstrap step itself.
handoff_bootstrap_gap() {
  local repo_dir="$1"
  if [ -f "$repo_dir/.worktree-bootstrap" ]; then
    return 1
  fi
  local f
  while IFS= read -r -d '' f; do
    return 1
  done < <(find "$repo_dir" -maxdepth 1 -name '.env*' -print0 2>/dev/null)
  return 0
}

# handoff_append_followup <task_file> <line> — insert "- <line>" immediately
# after the line that is exactly "## Follow-ups" — the durable channel R3
# establishes for exactly this kind of note (R11), so a spawn nobody is
# watching the terminal for doesn't leave the gap's only record in a
# scrollback buffer. Mirrors wb_reconcile_merge_content's own awk-based
# body-insertion style (wb.sh). A no-op when the file has no such heading.
handoff_append_followup() {
  local file="$1" line="$2"
  awk -v line="$line" '
    { print }
    $0 == "## Follow-ups" { print "- " line }
  ' "$file" > "$file.tmp.$$" && mv "$file.tmp.$$" "$file"
}

# handoff_permission_prompt_matches <pane_text> — true when <pane_text>
# contains BOTH the literal permission-prompt phrase and a ~/code/tasks or
# Read substring (R10) — the co-occurrence requirement that keeps a
# differently-shaped dialog from ever being blind-approved.
handoff_permission_prompt_matches() {
  local text="$1"
  printf '%s' "$text" | grep -qE 'Do you want to proceed\?' \
    && printf '%s' "$text" | grep -qE '~/code/tasks|Read'
}

# Below this point: the actual routing run. Guarded exactly like wb.sh's own
# CLI dispatch (wb.sh, end of file) — false when this file is sourced rather
# than executed directly, so a caller (a test, or a future script) can reach
# the functions above without triggering a real run. Same BASH_SOURCE[0]-
# vs-$0 property already relied on above to source wb.sh safely.
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then

if [ "$#" -ne 2 ]; then
  echo "usage: handoff.sh <repo> <slug>" >&2
  exit 1
fi
repo="$1"
slug="$2"

disp_slug="$(wb_sanitize "$slug")"
session="${repo}--${disp_slug}"
task_file="$(wb_task_file "$repo" "$disp_slug")"

# Fully fixed — no variable substitution beyond $task_file. first_action
# never appears here (R6); the pointer's disjointness from the boot/
# permission anchor sets (U2) depends on this string never varying.
pointer="Read the task file at $task_file - it carries the full context and states the first action to take."

if tmux has-session -t "=$session" 2>/dev/null; then
  # Switch path: a live session already exists for this repo/slug.
  [ -f "$task_file" ] \
    || echo "handoff: warning: $session is live but $task_file does not exist" >&2
  # wl-copy daemonizes to keep serving the selection after this line
  # returns; without redirecting its own stdout/stderr away from whatever
  # they're inherited from (e.g. a caller capturing this script's output
  # via command substitution), that lingering background process holds
  # the caller's pipe open forever, hanging any reader waiting for EOF.
  printf '%s' "$pointer" | wl-copy >/dev/null 2>&1
  tmux_focus "$session"
  echo "handoff: switched to live session $session — pointer copied to clipboard"
  exit 0
fi

# Spawn path — no live session for this repo/slug. `wb new --agent` is
# idempotent, safe whether the worktree/task file already exist or not.
"$WB" new --agent "$repo" "$slug"

# R11: surface (never fix) a bootstrap gap — the fix is a per-repo
# .worktree-bootstrap manifest, tracked as its own roadmap line item.
repo_dir="$CODE_DIR/$repo"
if handoff_bootstrap_gap "$repo_dir"; then
  gap_msg="$repo_dir has neither a .worktree-bootstrap manifest nor a root .env* file — wb new's bootstrap step likely left this worktree incomplete (see wb_bootstrap, wb.sh:142-171)"
  echo "handoff: warning: $gap_msg" >&2
  [ -f "$task_file" ] && handoff_append_followup "$task_file" "$gap_msg"
fi

# wb_layout_session (wb.sh:225) names the agent window "agent".
target="=$session:agent"

if ! handoff_wait_for_pane_pattern "$target" "$HANDOFF_BOOT_TIMEOUT" '\? for shortcuts|Try "|[0-9]+% ctx'; then
  echo "handoff: spawned $session but it never showed a boot-ready anchor within ${HANDOFF_BOOT_TIMEOUT}s — check $target by hand" >&2
  exit 1
fi

# R7/R9: the pointer is fully fixed (no first_action substitution), sent as
# one literal-flag send-keys call, Enter as a SEPARATE call — never
# combined into one call, never a literal embedded newline (premature-
# submission risk). Never sends `/model` to the pane (R7).
tmux send-keys -t "$target" -l "$pointer"
tmux send-keys -t "$target" Enter

if ! handoff_wait_for_pane_pattern "$target" "$HANDOFF_PERMISSION_TIMEOUT" 'Do you want to proceed\?'; then
  echo "handoff: spawned and injected $session — no permission prompt seen within ${HANDOFF_PERMISSION_TIMEOUT}s (it may already be clear, or the agent hasn't reached its first action yet)" >&2
  exit 0
fi

pane_text="$(tmux capture-pane -ep -t "$target" 2>/dev/null | tail -n 20)"
if handoff_permission_prompt_matches "$pane_text"; then
  # R10: single keystroke, no trailing Enter — confirmed live, this menu
  # selects and submits on the keystroke itself, unlike the main input box.
  tmux send-keys -t "$target" -l '2'
  echo "handoff: spawned $session, injected pointer, cleared the tasks/ read permission prompt"
else
  echo "handoff: spawned and injected $session — a permission prompt appeared but didn't match the expected tasks/Read shape; leaving it for you to answer at $target" >&2
fi

exit 0

fi
