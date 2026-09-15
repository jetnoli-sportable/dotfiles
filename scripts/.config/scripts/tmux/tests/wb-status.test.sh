#!/usr/bin/env bash
# Tests for `wb status` (cmd_status) — a store-only task's status: field,
# set directly under the per-task lock, for tasks with NO live session.
# Same convention as wb-append.test.sh (fixture TASKS_DIR, source wb.sh,
# set +e to capture non-zero exits) plus wb-pause.test.sh's real (throwaway)
# tmux session for the live-session-refusal scenario.
# Run: bash scripts/.config/scripts/tmux/tests/wb-status.test.sh
set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WB="$SELF_DIR/wb.sh"

FIXTURE="$(mktemp -d -t wb-status-fixture.XXXXXX)"
SESSION="wb-status-test-$$"
trap 'rm -rf "$FIXTURE"; tmux kill-session -t "=$SESSION" 2>/dev/null || true' EXIT

fail=0
assert() { # <desc> <expected-regex> <actual>
  if printf '%s' "$3" | grep -qE "$2"; then
    echo "ok   - $1"
  else
    echo "FAIL - $1"
    echo "       expected match: $2"
    echo "       got: $(printf '%s' "$3" | head -8)"
    fail=1
  fi
}
assert_eq() { # <desc> <expected> <actual>
  if [ "$2" = "$3" ]; then
    echo "ok   - $1"
  else
    echo "FAIL - $1 (expected '$2', got '$3')"
    fail=1
  fi
}

export XDG_STATE_HOME="$FIXTURE/state"
export HOME="$FIXTURE/home"
export CODE_DIR="$FIXTURE/code"
export TASKS_DIR="$FIXTURE/tasks"
mkdir -p "$XDG_STATE_HOME" "$HOME" "$CODE_DIR" "$TASKS_DIR"

# shellcheck disable=SC1090
source "$WB"
set +e   # wb.sh sets -e; this suite intentionally captures non-zero exits

mk_task() { # <file> <status> <branch> [<status-comment>]
  local f="$TASKS_DIR/$1"
  local status_line="status: $2"
  [ -z "${4:-}" ] || status_line="status: $2  # $4"
  printf -- '---\n%s\nrepo: proj\nbranch: %s\nworktree: .worktrees/%s\ntags: []\ncreated: 2026-07-01\nclosed:\n---\n# Title\n' \
    "$status_line" "$3" "$3" > "$f"
}

# =============================================================================
# Scenario: happy path, planned -> paused, store-only (no live session).
# =============================================================================

mk_task "proj--status-a.md" planned status-a
out="$(cmd_status "status-a" paused 2>&1)"; rc=$?
assert_eq "planned->paused: exit 0" 0 "$rc"
assert "planned->paused: confirmation names old -> new" 'proj--status-a\.md planned -> paused' "$out"
content="$(cat "$TASKS_DIR/proj--status-a.md")"
assert "planned->paused: frontmatter status updated" '^status: paused$' "$content"

# Handoffs entry appended
assert "planned->paused: Handoffs entry appended" 'wb status \(auto\)' "$content"
assert "planned->paused: Handoffs entry message" 'Status set to `paused` via `wb status`' "$content"

# =============================================================================
# Scenario: `prospective` (R25) is accepted by the enum.
# =============================================================================

mk_task "proj--status-prospective.md" planned status-prospective
out="$(cmd_status "status-prospective" prospective 2>&1)"; rc=$?
assert_eq "planned->prospective: exit 0" 0 "$rc"
content="$(cat "$TASKS_DIR/proj--status-prospective.md")"
assert "planned->prospective: frontmatter status updated" '^status: prospective$' "$content"

# An invalid value's usage message names the full enum, prospective included.
out="$(cmd_status "status-prospective" bogus 2>&1)"; rc=$?
assert_eq "invalid value names full enum: exit 1" 1 "$rc"
assert "invalid value names full enum incl. prospective" \
  'usage: wb status <task-ref> <prospective\|planned\|paused\|doing\|review>' "$out"

# =============================================================================
# Scenario: `done` is refused with a pointer to `wb done`.
# =============================================================================

mk_task "proj--status-b.md" doing status-b
out="$(cmd_status "status-b" done 2>&1)"; rc=$?
assert_eq "refuses done: exit 1" 1 "$rc"
assert "refuses done: points at wb done" 'use .wb done <task>. instead' "$out"
content="$(cat "$TASKS_DIR/proj--status-b.md")"
assert "refuses done: status untouched" '^status: doing$' "$content"

# =============================================================================
# Scenario: an invalid value is a usage error.
# =============================================================================

out="$(cmd_status "status-b" bogus 2>&1)"; rc=$?
assert_eq "invalid value: exit 1" 1 "$rc"
assert "invalid value: usage message" 'usage: wb status' "$out"
content="$(cat "$TASKS_DIR/proj--status-b.md")"
assert "invalid value: status untouched" '^status: doing$' "$content"

# =============================================================================
# Scenario: no-op when already at the target value — prints "already <new>",
# exits 0, and does not rewrite the file (mtime unchanged, no Handoffs entry).
# =============================================================================

mk_task "proj--status-c.md" review status-c
before_mtime="$(stat -c %Y "$TASKS_DIR/proj--status-c.md" 2>/dev/null || stat -f %m "$TASKS_DIR/proj--status-c.md")"
sleep 1
out="$(cmd_status "status-c" review 2>&1)"; rc=$?
assert_eq "no-op: exit 0" 0 "$rc"
assert "no-op: message says already <new>" 'already review' "$out"
content="$(cat "$TASKS_DIR/proj--status-c.md")"
if printf '%s' "$content" | grep -q '## Handoffs'; then
  echo "FAIL - no-op: a Handoffs section was created despite the no-op"; fail=1
else
  echo "ok   - no-op: no Handoffs section was created"
fi
after_mtime="$(stat -c %Y "$TASKS_DIR/proj--status-c.md" 2>/dev/null || stat -f %m "$TASKS_DIR/proj--status-c.md")"
assert_eq "no-op: file not rewritten (mtime unchanged)" "$before_mtime" "$after_mtime"

# =============================================================================
# Scenario: a trailing inline comment on the status: line survives the
# rewrite (TEMPLATE.md/README.md's `status: planned|doing|...  # lifecycle
# state ...` shape).
# =============================================================================

mk_task "proj--status-d.md" planned status-d "lifecycle state note"
out="$(cmd_status "status-d" doing 2>&1)"; rc=$?
assert_eq "trailing comment preserved: exit 0" 0 "$rc"
content="$(cat "$TASKS_DIR/proj--status-d.md")"
assert "trailing comment preserved: status updated, comment intact" '^status: doing  # lifecycle state note$' "$content"

# =============================================================================
# Scenario: refuses when a LIVE tmux session's @task points at the resolved
# file — this verb is for store-only tasks. Skipped if this harness has no
# usable tmux server.
# =============================================================================

if tmux new-session -d -s "$SESSION" 2>/dev/null; then
  mk_task "proj--status-live.md" doing status-live
  LIVE_FILE="$TASKS_DIR/proj--status-live.md"
  tmux set-option -t "=$SESSION:" @task "$LIVE_FILE" >/dev/null

  out="$(cmd_status "status-live" paused 2>&1)"; rc=$?
  assert_eq "live session refusal: exit 1" 1 "$rc"
  assert "live session refusal: names the live session" "has a live session $SESSION" "$out"
  content="$(cat "$LIVE_FILE")"
  assert "live session refusal: status untouched" '^status: doing$' "$content"

  tmux kill-session -t "=$SESSION" 2>/dev/null
else
  echo "skip - live session refusal: no usable tmux server in this harness"
fi

[ "$fail" -eq 0 ] && echo "ALL PASS" || echo "FAILURES"
exit "$fail"
