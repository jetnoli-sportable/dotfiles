#!/usr/bin/env bash
# Tests for `wb down` and `wb pr-open` (U3) — plain-bash assertions against
# a fixture store, a fixture Claude transcript root, and real (throwaway)
# tmux sessions, same convention as wb-pause.test.sh. Sources wb.sh (safe:
# see the BASH_SOURCE guard at the bottom of wb.sh) to call cmd_down /
# cmd_pr_open directly against fixture state.
# Run: bash scripts/.config/scripts/tmux/tests/wb-down.test.sh
set -uo pipefail

WB="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/wb.sh"
FIXTURE="$(mktemp -d -t wb-down-fixture.XXXXXX)"
SESSION="wb-down-test-$$"
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
CODE_DIR="$FIXTURE/code"
CLAUDE_PROJECTS_DIR="$FIXTURE/projects"

mk_task() { # <file> <status> <repo> <branch>
  local f="$FIXTURE/$1"
  printf -- '---\nstatus: %s\nrepo: %s\nbranch: %s\nworktree: .worktrees/%s\ntags: []\ncreated: 2026-07-07\nclosed:\n---\n# Title\n' \
    "$2" "$3" "$4" "$4" > "$f"
}

mk_transcript() { # <worktree_abs> <id> <touch-date>
  local dir; dir="$(CLAUDE_PROJECTS_DIR="$CLAUDE_PROJECTS_DIR" wb_transcript_dir "$1")"
  mkdir -p "$dir"
  printf '{}' > "$dir/$2.jsonl"
  touch -d "$3" "$dir/$2.jsonl"
}

# --- happy path: two transcripts, agent pane carries the newer one ----------
mk_task 'proj--feat-alpha.md' doing proj feat/alpha
WT1="$CODE_DIR/proj/.worktrees/feat/alpha"
mkdir -p "$WT1"
mk_transcript "$WT1" older-id 2026-09-01T00:00:00
mk_transcript "$WT1" newer-id 2026-09-05T00:00:00

tmux new-session -d -s "$SESSION" 2>/dev/null
tmux set-option -t "=$SESSION:" @wb_repo proj >/dev/null
tmux set-option -t "=$SESSION:" @wb_slug feat/alpha >/dev/null
tmux rename-window -t "=$SESSION:1" agent >/dev/null
tmux set-option -p -t "=$SESSION:agent" @claude_session_id newer-id >/dev/null

wb_branch_has_open_pr() { return 1; }   # stub: no open PR for this scenario

out="$(cmd_down "$SESSION" 2>&1)"; rc=$?
assert "cmd_down exits 0" '^' "$rc-ok"; [ "$rc" -eq 0 ] || { echo "FAIL - exit $rc: $out"; fail=1; }
assert "confirmation message" 'set aside' "$out"

sessions_field="$(wb_get_frontmatter "$FIXTURE/proj--feat-alpha.md" claude_sessions)"
assert "claude_sessions: holds both ids" 'older-id' "$sessions_field"
assert "claude_sessions: holds both ids (2)" 'newer-id' "$sessions_field"
assert "claude_sessions: the live agent pane's id is marked primary" 'newer-id@[^,]*@primary' "$sessions_field"
if printf '%s' "$sessions_field" | grep -q 'older-id@[^,]*@primary'; then
  echo "FAIL - claude_sessions: the OLDER id must not be marked primary"; fail=1
else
  echo "ok   - claude_sessions: only the agent pane's id is marked primary"
fi

status_val="$(wb_get_frontmatter "$FIXTURE/proj--feat-alpha.md" status)"
assert "status unchanged (no open PR)" '^doing$' "$status_val"

if tmux has-session -t "=$SESSION" 2>/dev/null; then
  echo "FAIL - cmd_down left the session alive"; fail=1
else
  echo "ok   - cmd_down killed the session"
fi

if [ -d "$WT1" ]; then
  echo "ok   - worktree directory untouched by wb down"
else
  echo "FAIL - worktree directory was removed by wb down (it must never be)"; fail=1
fi

# --- probe stubbed to open PR -> status: review -----------------------------
mk_task 'proj--feat-review.md' doing proj feat/review
WT2="$CODE_DIR/proj/.worktrees/feat/review"
mkdir -p "$WT2"
mk_transcript "$WT2" review-id 2026-09-06T00:00:00
tmux new-session -d -s "${SESSION}-review" 2>/dev/null
tmux set-option -t "=${SESSION}-review:" @wb_repo proj >/dev/null
tmux set-option -t "=${SESSION}-review:" @wb_slug feat/review >/dev/null

wb_branch_has_open_pr() { return 0; }   # stub: open PR
out="$(cmd_down "${SESSION}-review" 2>&1)"; rc=$?
assert "cmd_down (open PR) exits 0" '^' "$rc-ok"; [ "$rc" -eq 0 ] || { echo "FAIL - exit $rc: $out"; fail=1; }
status_val="$(wb_get_frontmatter "$FIXTURE/proj--feat-review.md" status)"
assert "status flips to review when the branch has an open PR" '^review$' "$status_val"

# --- probe stubbed to fail -> status unchanged, exit 0, one stderr line -----
mk_task 'proj--feat-unknown.md' doing proj feat/unknown
WT3="$CODE_DIR/proj/.worktrees/feat/unknown"
mkdir -p "$WT3"
tmux new-session -d -s "${SESSION}-unknown" 2>/dev/null
tmux set-option -t "=${SESSION}-unknown:" @wb_repo proj >/dev/null
tmux set-option -t "=${SESSION}-unknown:" @wb_slug feat/unknown >/dev/null

wb_branch_has_open_pr() { echo "stub: could not check PR status" >&2; return 1; }
out="$(cmd_down "${SESSION}-unknown" 2>&1)"; rc=$?
assert "cmd_down (probe failure) exits 0" '^' "$rc-ok"; [ "$rc" -eq 0 ] || { echo "FAIL - exit $rc: $out"; fail=1; }
status_val="$(wb_get_frontmatter "$FIXTURE/proj--feat-unknown.md" status)"
assert "status unchanged when the PR probe fails" '^doing$' "$status_val"
assert "probe failure line reaches the user" 'could not check PR status' "$out"
handoffs_count="$(grep -c '^### .* — wb down (auto)$' "$FIXTURE/proj--feat-unknown.md")"
if [ "$handoffs_count" -eq 1 ]; then
  echo "ok   - exactly one wb down Handoffs entry even when the probe fails"
else
  echo "FAIL - expected exactly 1 wb down Handoffs entry, got $handoffs_count"; fail=1
fi

# --- --keep-session: everything written, session survives (picker's _down --
# self-target wrapper uses this; see wb-picker-rows.test.sh for the source-
# text proof that _down actually passes it on a self-target) ----------------
wb_branch_has_open_pr() { return 1; }
tmux new-session -d -s "${SESSION}-keep" 2>/dev/null
tmux set-option -t "=${SESSION}-keep:" @wb_repo proj >/dev/null
tmux set-option -t "=${SESSION}-keep:" @wb_slug feat/unknown >/dev/null
out="$(cmd_down --keep-session "${SESSION}-keep" 2>&1)"; rc=$?
assert "--keep-session exits 0" '^' "$rc-ok"; [ "$rc" -eq 0 ] || { echo "FAIL - exit $rc: $out"; fail=1; }
if tmux has-session -t "=${SESSION}-keep" 2>/dev/null; then
  echo "ok   - --keep-session leaves the session alive"
else
  echo "FAIL - --keep-session must not kill the session"; fail=1
fi
tmux kill-session -t "=${SESSION}-keep" 2>/dev/null || true

# --- error path: not a wb task session, nothing written ---------------------
tmux new-session -d -s "${SESSION}-bare" 2>/dev/null
before_hash="$(md5sum "$FIXTURE/proj--feat-alpha.md" | cut -d' ' -f1)"
out="$(cmd_down "${SESSION}-bare" 2>&1)"; rc=$?
assert "bare session: non-zero exit" '^' "$rc-fail"; [ "$rc" -ne 0 ] || { echo "FAIL - exit $rc"; fail=1; }
assert "bare session: clear error" 'not a wb task session' "$out"
after_hash="$(md5sum "$FIXTURE/proj--feat-alpha.md" | cut -d' ' -f1)"
if [ "$before_hash" = "$after_hash" ]; then
  echo "ok   - bare session: nothing written to an unrelated task file"
else
  echo "FAIL - bare session: an unrelated task file was modified"; fail=1
fi
tmux kill-session -t "=${SESSION}-bare" 2>/dev/null || true

# --- idempotence: down twice -> second run reports no session --------------
snapshot_after_first="$(wb_get_frontmatter "$FIXTURE/proj--feat-alpha.md" claude_sessions)"
out="$(cmd_down "$SESSION" 2>&1)"; rc=$?
assert "second down: non-zero exit (session already gone)" '^' "$rc-fail"; [ "$rc" -ne 0 ] || { echo "FAIL - exit $rc"; fail=1; }
snapshot_after_second="$(wb_get_frontmatter "$FIXTURE/proj--feat-alpha.md" claude_sessions)"
if [ "$snapshot_after_first" = "$snapshot_after_second" ]; then
  echo "ok   - idempotence: claude_sessions: unchanged by a second (failing) down"
else
  echo "FAIL - idempotence: claude_sessions: changed by a second down"; fail=1
fi

# --- wb pr-open: exit codes for stubbed open / none / failure --------------
mk_task 'proj--feat-pr.md' doing proj feat/pr
tmux new-session -d -s "${SESSION}-pr" 2>/dev/null
tmux set-option -t "=${SESSION}-pr:" @wb_repo proj >/dev/null
tmux set-option -t "=${SESSION}-pr:" @wb_slug feat/pr >/dev/null

wb_branch_has_open_pr() { return 0; }
cmd_pr_open "${SESSION}-pr" >/dev/null 2>&1; rc=$?
assert "wb pr-open: open PR -> exit 0" '^0$' "$rc"

wb_branch_has_open_pr() { return 1; }
cmd_pr_open "${SESSION}-pr" >/dev/null 2>&1; rc=$?
assert "wb pr-open: no PR -> exit 1" '^1$' "$rc"

wb_branch_has_open_pr() { echo "stub: gh unavailable" >&2; return 1; }
out="$(cmd_pr_open "${SESSION}-pr" 2>&1)"; rc=$?
assert "wb pr-open: probe failure -> exit 1" '^1$' "$rc"
assert "wb pr-open: probe failure surfaces the diagnostic" 'gh unavailable' "$out"
tmux kill-session -t "=${SESSION}-pr" 2>/dev/null || true

[ "$fail" -eq 0 ] && echo "ALL PASS" || echo "FAILURES"
exit "$fail"
