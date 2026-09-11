#!/usr/bin/env bash
# Tests for `wb pause` (U3 rework) — plain-bash assertions against a fixture
# store and a real (but throwaway) tmux session, same convention as
# wb-board.test.sh. Sources wb.sh (safe: see the BASH_SOURCE guard at the
# bottom of wb.sh) to call cmd_pause directly against fixture tmux state.
# `wb pause` now shelves a task ON PURPOSE (the progress axis) and composes
# `wb down` (the activity axis) so a paused task never keeps a live session
# — see wb-down.test.sh for cmd_down's own scenarios (snapshot building,
# the PR probe, the --keep-session self-target path).
# Run: bash scripts/.config/scripts/tmux/tests/wb-pause.test.sh
set -uo pipefail

WB="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/wb.sh"
FIXTURE="$(mktemp -d -t wb-pause-fixture.XXXXXX)"
SESSION="wb-pause-test-$$"
trap 'rm -rf "$FIXTURE"; tmux kill-session -t "=$SESSION" 2>/dev/null || true' EXIT

fail=0
assert() { # <desc> <expected-regex> <actual>
  if printf '%s' "$3" | grep -qE "$2"; then
    echo "ok   - $1"
  else
    echo "FAIL - $1"
    echo "       expected match: $2"
    echo "       got: $(printf '%s' "$3" | head -5)"
    fail=1
  fi
}

# shellcheck disable=SC1090
source "$WB"
set +e   # wb.sh sets -e; this test intentionally captures non-zero exits
TASKS_DIR="$FIXTURE"
CLAUDE_PROJECTS_DIR="$FIXTURE/projects"   # no real ~/.claude/projects reads/writes from this test

mk_task() { # <file> <status> <repo> <branch>
  local f="$FIXTURE/$1"
  printf -- '---\nstatus: %s\nrepo: %s\nbranch: %s\nworktree: .worktrees/x\ntags: []\ncreated: 2026-07-07\nclosed:\n---\n# Title\n' \
    "$2" "$3" "$4" > "$f"
}

# --- happy path: paused task keeps its worktree marker, loses its session --
mk_task 'proj--feat-alpha.md' doing proj feat/alpha
tmux new-session -d -s "$SESSION" 2>/dev/null
tmux set-option -t "=$SESSION:" @wb_repo proj >/dev/null
tmux set-option -t "=$SESSION:" @wb_slug feat/alpha >/dev/null

# Stub the PR probe so this test never shells out to a real `gh` — cmd_down's
# own PR-marking behavior is wb-down.test.sh's concern, not this file's.
wb_branch_has_open_pr() { return 1; }

# Lock-ordering trace (KTD5): wraps the two real primitives so this test can
# prove cmd_pause releases its own lock BEFORE cmd_down acquires its own,
# rather than nesting one critical section inside the other (the flock
# underneath wb_task_lock_acquire is not re-entrant — a nested acquire from
# the same process would time out and leave the task paused with the
# session still alive, exactly the crossed-axes state this model forbids).
LOCK_TRACE="$FIXTURE/.lock-trace"
eval "$(declare -f wb_task_lock_acquire_guarded | sed '1s/.*/_orig_acquire_guarded()/')"
eval "$(declare -f wb_task_lock_release | sed '1s/.*/_orig_release()/')"
wb_task_lock_acquire_guarded() { echo acquire >> "$LOCK_TRACE"; _orig_acquire_guarded "$@"; }
wb_task_lock_release()          { echo release >> "$LOCK_TRACE"; _orig_release "$@"; }

out="$(cmd_pause "$SESSION" 2>&1)"; rc=$?
assert "exits 0" '^' "$rc-ok"; [ "$rc" -eq 0 ] || { echo "FAIL - exit code $rc: $out"; fail=1; }
assert "confirmation message names paused" 'paused' "$out"
assert "confirmation message names the down step" 'set aside' "$out"

status_val="$(awk '
  BEGIN { infm = 0 }
  /^---$/ { infm++; if (infm == 2) exit; next }
  infm == 1 && /^status:/ { sub(/^status:[ \t]*/, ""); print; exit }
' "$FIXTURE/proj--feat-alpha.md")"
assert "status flipped to paused" '^paused$' "$status_val"

if tmux has-session -t "=$SESSION" 2>/dev/null; then
  echo "FAIL - tmux session survived wb pause (a paused task must never keep a live session)"
  fail=1
else
  echo "ok   - tmux session killed by wb pause (composed wb down)"
fi

trace="$(cat "$LOCK_TRACE" 2>/dev/null)"
assert "lock trace: acquire, release, acquire, release (never nested)" \
  '^acquire
release
acquire
release$' "$trace"

# --- Handoffs: pause then down, in that order, one entry each ---------------
handoffs_block="$(awk '/^## Handoffs$/{p=1} p' "$FIXTURE/proj--feat-alpha.md")"
assert "cmd_pause: creates a ## Handoffs section" '^## Handoffs$' "$handoffs_block"
pause_line=$(printf '%s\n' "$handoffs_block" | grep -n '— wb pause (auto)$' | cut -d: -f1 | head -1)
down_line=$(printf '%s\n' "$handoffs_block" | grep -n '— wb down (auto)$' | cut -d: -f1 | head -1)
if [ -n "$pause_line" ] && [ -n "$down_line" ] && [ "$pause_line" -lt "$down_line" ]; then
  echo "ok   - Handoffs: wb pause entry precedes wb down entry"
else
  echo "FAIL - Handoffs: expected wb pause entry before wb down entry (pause=$pause_line, down=$down_line)"; fail=1
fi
assert "cmd_pause: entry body names the command" 'Session paused via `wb pause`\.' "$handoffs_block"
assert "cmd_down: entry body names the command" 'Session closed via `wb down`' "$handoffs_block"

pause_count="$(grep -c '^### .* — wb pause (auto)$' "$FIXTURE/proj--feat-alpha.md")"
down_count="$(grep -c '^### .* — wb down (auto)$' "$FIXTURE/proj--feat-alpha.md")"
if [ "$pause_count" -eq 1 ] && [ "$down_count" -eq 1 ]; then
  echo "ok   - exactly one wb pause entry and one wb down entry after one pause"
else
  echo "FAIL - expected exactly 1 wb pause + 1 wb down entry, got pause=$pause_count down=$down_count"; fail=1
fi

# --- error path: not a wb task session ---------------------------------------
tmux new-session -d -s "${SESSION}-bare" 2>/dev/null
out="$(cmd_pause "${SESSION}-bare" 2>&1)"; rc=$?
assert "bare session: non-zero exit" '^' "$rc-fail"; [ "$rc" -ne 0 ] || { echo "FAIL - exit code $rc"; fail=1; }
assert "bare session: clear error" 'not a wb task session' "$out"
tmux kill-session -t "=${SESSION}-bare" 2>/dev/null || true

# --- error path: wb task session but no task file on disk --------------------
tmux new-session -d -s "${SESSION}-ghost" 2>/dev/null
tmux set-option -t "=${SESSION}-ghost:" @wb_repo proj >/dev/null
tmux set-option -t "=${SESSION}-ghost:" @wb_slug feat/nonexistent >/dev/null
out="$(cmd_pause "${SESSION}-ghost" 2>&1)"; rc=$?
assert "missing task file: non-zero exit" '^' "$rc-fail"; [ "$rc" -ne 0 ] || { echo "FAIL - exit code $rc"; fail=1; }
assert "missing task file: clear error" 'no task file' "$out"
tmux kill-session -t "=${SESSION}-ghost" 2>/dev/null || true

[ "$fail" -eq 0 ] && echo "ALL PASS" || echo "FAILURES"
exit "$fail"
