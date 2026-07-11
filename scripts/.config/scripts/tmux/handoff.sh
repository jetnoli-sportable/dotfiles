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

# Spawn path — built in U2. Stubbed here so this file is syntactically
# complete and the switch-path tests above can run against it.
echo "handoff: spawn path: not yet implemented" >&2
exit 1
