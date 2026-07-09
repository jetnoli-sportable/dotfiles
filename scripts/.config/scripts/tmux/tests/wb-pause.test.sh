#!/usr/bin/env bash
# Tests for `wb pause` (U2) — plain-bash assertions against a fixture store
# and a real (but throwaway) tmux session, same convention as
# wb-board.test.sh. Sources wb.sh (safe: see the BASH_SOURCE guard at the
# bottom of wb.sh) to call cmd_pause directly against fixture tmux state.
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

mk_task() { # <file> <status> <repo> <branch>
  local f="$FIXTURE/$1"
  printf -- '---\nstatus: %s\nrepo: %s\nbranch: %s\nworktree: .worktrees/x\ntags: []\ncreated: 2026-07-07\nclosed:\n---\n# Title\n' \
    "$2" "$3" "$4" > "$f"
}

# --- happy path: paused task keeps its worktree marker and its session ------
mk_task 'proj--feat-alpha.md' doing proj feat/alpha
tmux new-session -d -s "$SESSION" 2>/dev/null
tmux set-option -t "=$SESSION:" @wb_repo proj >/dev/null
tmux set-option -t "=$SESSION:" @wb_slug feat/alpha >/dev/null

out="$(cmd_pause "$SESSION" 2>&1)"; rc=$?
assert "exits 0" '^' "$rc-ok"; [ "$rc" -eq 0 ] || { echo "FAIL - exit code $rc: $out"; fail=1; }
assert "confirmation message" 'paused' "$out"

status_val="$(awk '
  BEGIN { infm = 0 }
  /^---$/ { infm++; if (infm == 2) exit; next }
  infm == 1 && /^status:/ { sub(/^status:[ \t]*/, ""); print; exit }
' "$FIXTURE/proj--feat-alpha.md")"
assert "status flipped to paused" '^paused$' "$status_val"

if tmux has-session -t "=$SESSION" 2>/dev/null; then
  echo "ok   - tmux session still alive after pause"
else
  echo "FAIL - tmux session was killed by wb pause"
  fail=1
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
