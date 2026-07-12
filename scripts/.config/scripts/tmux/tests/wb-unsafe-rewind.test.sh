#!/usr/bin/env bash
# Tests for `wb unsafe-rewind` (U7) — the sole sanctioned producer of the
# WB_ALLOW_REWIND sentinel a sibling git hook (tasks-git-hooks/, not touched
# by this unit) consults before honoring a rewind-shaped git operation
# (reset --hard, a force-push, ...) against $TASKS_DIR. This test only
# proves the PRODUCER writes the right shape (X1/X2) — the TTL/one-time-use
# ENFORCEMENT itself is proven by that sibling unit's own stale-sentinel
# test, not here.
#
# MUST run via the project's sandboxed Dockerfile, same reasoning as
# wb-done.test.sh's own header:
#   docker build -t wb-tests -f scripts/.config/scripts/tmux/tests/Dockerfile .
#   docker run --rm -v "$(pwd)":/repo:ro -w /repo wb-tests \
#     bash scripts/.config/scripts/tmux/tests/wb-unsafe-rewind.test.sh
set -uo pipefail

WB="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/wb.sh"
FIXTURE="$(mktemp -d -t wb-unsafe-rewind-fixture.XXXXXX)"
trap 'rm -rf "$FIXTURE"' EXIT

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

# A minimal ".git" dir is enough — cmd_unsafe_rewind never touches git
# plumbing, it just writes a file at $TASKS_DIR/.git/WB_ALLOW_REWIND.
mkdir -p "$FIXTURE/tasks/.git"

# shellcheck disable=SC1090
source "$WB"
set +e   # wb.sh sets -e; this test intentionally captures non-zero exits
TASKS_DIR="$FIXTURE/tasks"
SENTINEL="$TASKS_DIR/.git/WB_ALLOW_REWIND"

# --- error path: no reason arg at all ---------------------------------------
out="$(cmd_unsafe_rewind 2>&1)"; rc=$?
assert "missing reason: non-zero exit" '^' "$rc-fail"; [ "$rc" -ne 0 ] || { echo "FAIL - exit $rc"; fail=1; }
assert "missing reason: usage error" 'usage' "$out"
[ -f "$SENTINEL" ] \
  && { echo "FAIL - missing reason: sentinel written despite no reason"; fail=1; } \
  || echo "ok   - missing reason: no sentinel written"

# --- error path: an explicit empty-string reason ----------------------------
out="$(cmd_unsafe_rewind "" 2>&1)"; rc=$?
assert "empty reason: non-zero exit" '^' "$rc-fail"; [ "$rc" -ne 0 ] || { echo "FAIL - exit $rc"; fail=1; }
assert "empty reason: usage error" 'usage' "$out"
[ -f "$SENTINEL" ] \
  && { echo "FAIL - empty reason: sentinel written despite empty reason"; fail=1; } \
  || echo "ok   - empty reason: no sentinel written"

# --- happy path: a real reason writes the sentinel in the right shape ------
before="$(date +%s)"
out="$(cmd_unsafe_rewind "rebasing to drop an accidental secret commit" 2>&1)"; rc=$?
after="$(date +%s)"
assert "real reason: exits 0" '^' "$rc-ok"; [ "$rc" -eq 0 ] || { echo "FAIL - exit $rc: $out"; fail=1; }
assert "real reason: confirms the sentinel path" 'sentinel written to .*WB_ALLOW_REWIND' "$out"
assert "real reason: echoes the reason back" 'rebasing to drop an accidental secret commit' "$out"
assert "real reason: prints the TTL contract (120s, one-time-use)" '120' "$out"
assert "real reason: names the hook as the enforcer" 'hook' "$out"

if [ -f "$SENTINEL" ]; then
  echo "ok   - real reason: sentinel file created"
else
  echo "FAIL - real reason: sentinel file NOT created at $SENTINEL"; fail=1
fi

content="$(cat "$SENTINEL" 2>/dev/null)"
assert "sentinel: one line, '<epoch> <reason>' shape" \
  '^[0-9]+ rebasing to drop an accidental secret commit$' "$content"

epoch="$(printf '%s' "$content" | awk '{print $1}')"
if [ -n "$epoch" ] && [ "$epoch" -ge "$before" ] 2>/dev/null && [ "$epoch" -le "$after" ] 2>/dev/null; then
  echo "ok   - sentinel: epoch is plausible (within this test's wall-clock window)"
else
  echo "FAIL - sentinel: epoch ($epoch) not within [$before, $after]"; fail=1
fi

reason_field="${content#* }"
assert "sentinel: reason field matches verbatim" \
  '^rebasing to drop an accidental secret commit$' "$reason_field"

line_count="$(wc -l < "$SENTINEL")"
if [ "$line_count" -eq 1 ]; then
  echo "ok   - sentinel: exactly one line"
else
  echo "FAIL - sentinel: expected exactly 1 line, got $line_count"; fail=1
fi

# --- a second real call overwrites the sentinel, still one line ------------
out2="$(cmd_unsafe_rewind "second, different reason" 2>&1)"; rc=$?
assert "second call: exits 0" '^' "$rc-ok"; [ "$rc" -eq 0 ] || { echo "FAIL - exit $rc: $out2"; fail=1; }
content2="$(cat "$SENTINEL" 2>/dev/null)"
assert "second call: reason updated" 'second, different reason' "$content2"
line_count2="$(wc -l < "$SENTINEL")"
if [ "$line_count2" -eq 1 ]; then
  echo "ok   - second call: sentinel still exactly one line (overwritten, not appended)"
else
  echo "FAIL - second call: sentinel has $line_count2 lines, expected 1"; fail=1
fi

# --- a multi-word reason with no quoting help (all args) is joined by $* ---
out3="$(cmd_unsafe_rewind reason with multiple words 2>&1)"; rc=$?
assert "multi-arg reason: exits 0" '^' "$rc-ok"; [ "$rc" -eq 0 ] || { echo "FAIL - exit $rc: $out3"; fail=1; }
content3="$(cat "$SENTINEL" 2>/dev/null)"
assert "multi-arg reason: joined into the sentinel's reason field" \
  '^[0-9]+ reason with multiple words$' "$content3"

[ "$fail" -eq 0 ] && echo "ALL PASS" || echo "FAILURES"
exit "$fail"
