#!/usr/bin/env bash
# Tests for claude/.claude/skills/decision-buffer/scripts/open-buffer.sh (U1,
# extended coverage added at U7 — docs/plans/2026-09-08-001-feat-decision-
# buffer-v2-plan.md). Unlike wb-handoffs.test.sh / wb-breakdown.test.sh,
# open-buffer.sh is a standalone script, not a function sourced out of
# wb.sh — every scenario below invokes it as a subprocess
# (`bash "$SCRIPT" <flags> <path>`) against a fixture directory, same
# fixture-dir + assert-helper convention as the sibling suites otherwise.
#
# The --reattach decision tree (R18 / mechanism.md's "Reattach decision
# tree") is driven by a fake `tmux` executable placed first on PATH for the
# duration of just those invocations. The stub covers ONLY the
# `tmux list-panes -a -F '#{pane_id} #{pane_current_command}'` parsing (plus
# no-op `wait-for`/`set` calls, logged so tests can assert whether wait-for
# was actually invoked) — it does not fake `split-window`, so --tmux/
# --terminal happy-path opens are NOT covered here; those are the documented
# manual smoke checks from U1/U4's own Verification sections.
#
# Run: bash scripts/.config/scripts/tmux/tests/decision-buffer-open.test.sh
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && git rev-parse --show-toplevel)"
SCRIPT="$REPO_ROOT/claude/.claude/skills/decision-buffer/scripts/open-buffer.sh"
FIXTURE="$(mktemp -d -t decision-buffer-open-fixture.XXXXXX)"
trap 'rm -rf "$FIXTURE"' EXIT

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
assert_not_eq() { # <desc> <not-expected> <actual>
  if [ "$2" != "$3" ]; then
    echo "ok   - $1"
  else
    echo "FAIL - $1 (expected something other than '$2', got '$3')"
    fail=1
  fi
}

# state_path_for <doc-path> — mirrors the script's own state_path_for().
state_path_for() { printf '%s.buffer-state' "$1"; }

# state_field <state-file> <key> — plain key=value line reader for
# assertions (independent of the script's own read_state, deliberately, so
# a bug in read_state can't hide itself from these tests).
state_field() {
  local sf="$1" key="$2"
  [ -f "$sf" ] || return 1
  grep "^${key}=" "$sf" | head -1 | cut -d= -f2-
}

mkdir -p "$FIXTURE/bin" "$FIXTURE/docs"

# ---------------------------------------------------------------------------
# fake `tmux` for --reattach's decision-tree tests
# ---------------------------------------------------------------------------
# Logs every invocation (space-joined args) to $TMUX_STUB_LOG so tests can
# assert whether wait-for was actually reached; for `list-panes`, cats
# $TMUX_STUB_PANES (the canned `#{pane_id} #{pane_current_command}` table
# for that scenario). Every other subcommand (`wait-for`, `set`, ...) is a
# no-op that exits 0 immediately — this is a DECISION-tree stub, not a
# working tmux, so a real `wait-for` block never happens here.
cat > "$FIXTURE/bin/tmux" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${TMUX_STUB_LOG:?TMUX_STUB_LOG not set}"
case "${1:-}" in
  list-panes) cat "${TMUX_STUB_PANES:?TMUX_STUB_PANES not set}" ;;
  *) exit 0 ;;
esac
STUB
chmod +x "$FIXTURE/bin/tmux"

# fake editor — records whether WB_REVIEW_BUFFER reached it, exits
# immediately (no real interactive editor involved).
cat > "$FIXTURE/bin/fake-editor" <<'STUB'
#!/usr/bin/env bash
printf '%s' "${WB_REVIEW_BUFFER:-}" > "${FAKE_EDITOR_OUT:?FAKE_EDITOR_OUT not set}"
exit 0
STUB
chmod +x "$FIXTURE/bin/fake-editor"

# dead_pid — a pid guaranteed to have already exited, for "no live waiter"
# scenarios (kill -0 on it reliably fails; the tiny window for OS pid reuse
# is the same accepted limitation the script's own comments call out).
dead_pid() {
  ( exit 0 ) &
  local p=$!
  wait "$p" 2>/dev/null
  printf '%s' "$p"
}

# ===========================================================================
# --direct: happy path — no state file, blocks synchronously, exits 0
# ===========================================================================
DIRECT_DOC="$FIXTURE/docs/direct.md"
printf '# doc\n' > "$DIRECT_DOC"
FAKE_EDITOR_OUT="$FIXTURE/direct-review-buffer-seen"
rm -f "$FAKE_EDITOR_OUT"

EDITOR="$FIXTURE/bin/fake-editor" FAKE_EDITOR_OUT="$FAKE_EDITOR_OUT" \
  bash "$SCRIPT" --direct "$DIRECT_DOC" >/tmp/decision-buffer-open-direct.out 2>&1
rc=$?
assert_eq "--direct: exits 0" "0" "$rc"
assert_eq "--direct: writes no state file" "" "$([ -f "$(state_path_for "$DIRECT_DOC")" ] && echo present)"
assert_eq "--direct: WB_REVIEW_BUFFER=1 reached the child editor" "1" "$(cat "$FAKE_EDITOR_OUT" 2>/dev/null)"
# --manual spawns no child process at all (the human runs the printed
# command themselves), so there is nothing to assert WB_REVIEW_BUFFER
# reaching there — it's only meaningful for --tmux/--direct, and --tmux
# can't be exercised here without a real interactive pane.

# ===========================================================================
# usage errors
# ===========================================================================
out_missing="$(bash "$SCRIPT" --direct 2>&1)"; rc_missing=$?
assert_eq "missing <path>: exits 2" "2" "$rc_missing"
assert "missing <path>: usage message printed" "missing <path>" "$out_missing"

out_unknown="$(bash "$SCRIPT" --bogus-flag "$DIRECT_DOC" 2>&1)"; rc_unknown=$?
assert_eq "unknown flag: exits 2" "2" "$rc_unknown"
assert "unknown flag: usage message printed" "unknown flag: --bogus-flag" "$out_unknown"

# ===========================================================================
# --manual: overwrite + reopen_count carry-forward / reset
# ===========================================================================
MANUAL_DOC="$FIXTURE/docs/manual.md"
printf 'v1 content\n' > "$MANUAL_DOC"
MANUAL_SF="$(state_path_for "$MANUAL_DOC")"

out_m1="$(bash "$SCRIPT" --manual "$MANUAL_DOC" 2>&1)"; rc_m1=$?
assert_eq "manual run1: exits 0" "0" "$rc_m1"
assert_eq "manual run1: mode=manual" "manual" "$(state_field "$MANUAL_SF" mode)"
assert_eq "manual run1: chan stays empty" "" "$(state_field "$MANUAL_SF" chan)"
assert_eq "manual run1: pane_id stays empty" "" "$(state_field "$MANUAL_SF" pane_id)"
assert_eq "manual run1: reopen_count starts at 0" "0" "$(state_field "$MANUAL_SF" reopen_count)"
assert "manual run1: prints copyable nvim command" '! .*nvim.*'"$(basename "$MANUAL_DOC")" "$out_m1"
pid_m1="$(state_field "$MANUAL_SF" caller_pid)"

# run2: content unchanged -> unconditional overwrite (fresh caller_pid),
# reopen_count carries forward from 0 to 1.
out_m2="$(bash "$SCRIPT" --manual "$MANUAL_DOC" 2>&1)"; rc_m2=$?
assert_eq "manual run2 (unchanged content): exits 0" "0" "$rc_m2"
pid_m2="$(state_field "$MANUAL_SF" caller_pid)"
assert_not_eq "manual run2: state file unconditionally overwritten (fresh caller_pid)" "$pid_m1" "$pid_m2"
assert_eq "manual run2: reopen_count carries forward (0 -> 1)" "1" "$(state_field "$MANUAL_SF" reopen_count)"

# run3: content unchanged again -> reopen_count keeps carrying forward
out_m3="$(bash "$SCRIPT" --manual "$MANUAL_DOC" 2>&1)"; rc_m3=$?
assert_eq "manual run3 (still unchanged): exits 0" "0" "$rc_m3"
assert_eq "manual run3: reopen_count carries forward (1 -> 2)" "2" "$(state_field "$MANUAL_SF" reopen_count)"

# run4: content changed -> reopen_count resets to 0
printf 'v2 content, edited\n' >> "$MANUAL_DOC"
out_m4="$(bash "$SCRIPT" --manual "$MANUAL_DOC" 2>&1)"; rc_m4=$?
assert_eq "manual run4 (content changed): exits 0" "0" "$rc_m4"
assert_eq "manual run4: reopen_count resets to 0 on new content" "0" "$(state_field "$MANUAL_SF" reopen_count)"

# ===========================================================================
# --reattach
# ===========================================================================

# --- no state file at all -> "nothing to reattach", exit 1 -----------------
NOSTATE_DOC="$FIXTURE/docs/no-state.md"
printf 'never opened\n' > "$NOSTATE_DOC"
out_ns="$(bash "$SCRIPT" --reattach "$NOSTATE_DOC" 2>&1)"; rc_ns=$?
assert_eq "reattach, no state file: exits 1" "1" "$rc_ns"
assert "reattach, no state file: nothing-to-reattach message" "nothing to reattach" "$out_ns"

# --- caller_pid in state file still alive -> "already waiting", exit 1 -----
ALIVE_DOC="$FIXTURE/docs/alive-waiter.md"
printf 'being waited on\n' > "$ALIVE_DOC"
ALIVE_SF="$(state_path_for "$ALIVE_DOC")"
{
  printf 'chan=decision-buffer-done-test-1\n'
  printf 'pane_id=%%1\n'
  printf 'mode=tmux\n'
  printf 'opened_at=%s\n' "$(date +%s)"
  printf 'caller_pid=%s\n' "$$"   # the test's own pid — guaranteed alive
  printf 'content_hash=deadbeef\n'
  printf 'reopen_count=0\n'
} > "$ALIVE_SF"
before_mtime="$(stat -c %Y "$ALIVE_SF" 2>/dev/null || stat -f %m "$ALIVE_SF")"
out_aw="$(bash "$SCRIPT" --reattach "$ALIVE_DOC" 2>&1)"; rc_aw=$?
assert_eq "reattach, live caller_pid: exits 1" "1" "$rc_aw"
assert "reattach, live caller_pid: already-waiting message" "already waiting" "$out_aw"
assert_eq "reattach, live caller_pid: state file untouched" "present" "$([ -f "$ALIVE_SF" ] && echo present)"
after_mtime="$(stat -c %Y "$ALIVE_SF" 2>/dev/null || stat -f %m "$ALIVE_SF")"
assert_eq "reattach, live caller_pid: state file not rewritten" "$before_mtime" "$after_mtime"

# --- pane alive, running nvim -> waits on the recorded channel, exit 0 -----
NVIM_DOC="$FIXTURE/docs/pane-nvim.md"
printf 'still open in nvim\n' > "$NVIM_DOC"
NVIM_SF="$(state_path_for "$NVIM_DOC")"
DEAD1="$(dead_pid)"
{
  printf 'chan=decision-buffer-done-test-2\n'
  printf 'pane_id=%%5\n'
  printf 'mode=tmux\n'
  printf 'opened_at=%s\n' "$(date +%s)"
  printf 'caller_pid=%s\n' "$DEAD1"
  printf 'content_hash=deadbeef\n'
  printf 'reopen_count=0\n'
} > "$NVIM_SF"
printf '%%3 zsh\n%%5 nvim\n' > "$FIXTURE/panes-nvim.txt"
PATH="$FIXTURE/bin:$PATH" TMUX="fake-session" TMUX_PANE="%0" \
  TMUX_STUB_LOG="$FIXTURE/tmux-calls-nvim.log" TMUX_STUB_PANES="$FIXTURE/panes-nvim.txt" \
  bash "$SCRIPT" --reattach "$NVIM_DOC" >/tmp/decision-buffer-open-reattach-nvim.out 2>&1
rc_nvim=$?
assert_eq "reattach, pane alive+nvim: exits 0" "0" "$rc_nvim"
assert_eq "reattach, pane alive+nvim: state file deleted" "" "$([ -f "$NVIM_SF" ] && echo present)"
assert "reattach, pane alive+nvim: waits on the recorded channel" 'wait-for decision-buffer-done-test-2' "$(cat "$FIXTURE/tmux-calls-nvim.log")"

# --- pane no longer exists -> PaneGone: report, no wait, delete state, exit 0
GONE_DOC="$FIXTURE/docs/pane-gone.md"
printf 'closed out of band\n' > "$GONE_DOC"
GONE_SF="$(state_path_for "$GONE_DOC")"
DEAD2="$(dead_pid)"
{
  printf 'chan=decision-buffer-done-test-3\n'
  printf 'pane_id=%%9\n'
  printf 'mode=tmux\n'
  printf 'opened_at=%s\n' "$(date +%s)"
  printf 'caller_pid=%s\n' "$DEAD2"
  printf 'content_hash=deadbeef\n'
  printf 'reopen_count=0\n'
} > "$GONE_SF"
printf '%%3 zsh\n%%5 nvim\n' > "$FIXTURE/panes-gone.txt"   # %9 not present
out_gone="$(PATH="$FIXTURE/bin:$PATH" TMUX="fake-session" TMUX_PANE="%0" \
  TMUX_STUB_LOG="$FIXTURE/tmux-calls-gone.log" TMUX_STUB_PANES="$FIXTURE/panes-gone.txt" \
  bash "$SCRIPT" --reattach "$GONE_DOC" 2>&1)"
rc_gone=$?
assert_eq "reattach, pane gone: exits 0" "0" "$rc_gone"
assert "reattach, pane gone: reports pane-gone" 'gone' "$out_gone"
assert_eq "reattach, pane gone: state file deleted" "" "$([ -f "$GONE_SF" ] && echo present)"
assert_eq "reattach, pane gone: never calls wait-for" "0" "$(grep -c '^wait-for' "$FIXTURE/tmux-calls-gone.log" || true)"

# --- pane alive but not running nvim -> treated as already closed, exit 0 --
NOTNVIM_DOC="$FIXTURE/docs/pane-not-nvim.md"
printf 'nvim already exited\n' > "$NOTNVIM_DOC"
NOTNVIM_SF="$(state_path_for "$NOTNVIM_DOC")"
DEAD3="$(dead_pid)"
{
  printf 'chan=decision-buffer-done-test-4\n'
  printf 'pane_id=%%5\n'
  printf 'mode=tmux\n'
  printf 'opened_at=%s\n' "$(date +%s)"
  printf 'caller_pid=%s\n' "$DEAD3"
  printf 'content_hash=deadbeef\n'
  printf 'reopen_count=0\n'
} > "$NOTNVIM_SF"
printf '%%3 zsh\n%%5 zsh\n' > "$FIXTURE/panes-notnvim.txt"   # %5 alive, but zsh not nvim
out_notnvim="$(PATH="$FIXTURE/bin:$PATH" TMUX="fake-session" TMUX_PANE="%0" \
  TMUX_STUB_LOG="$FIXTURE/tmux-calls-notnvim.log" TMUX_STUB_PANES="$FIXTURE/panes-notnvim.txt" \
  bash "$SCRIPT" --reattach "$NOTNVIM_DOC" 2>&1)"
rc_notnvim=$?
assert_eq "reattach, pane alive but not nvim: exits 0" "0" "$rc_notnvim"
assert "reattach, pane alive but not nvim: treated as already closed" 'treating as already closed' "$out_notnvim"
assert_eq "reattach, pane alive but not nvim: state file deleted" "" "$([ -f "$NOTNVIM_SF" ] && echo present)"
assert_eq "reattach, pane alive but not nvim: never calls wait-for" "0" "$(grep -c '^wait-for' "$FIXTURE/tmux-calls-notnvim.log" || true)"

[ "$fail" -eq 0 ] && echo "ALL PASS" || echo "FAILURES"
exit "$fail"
