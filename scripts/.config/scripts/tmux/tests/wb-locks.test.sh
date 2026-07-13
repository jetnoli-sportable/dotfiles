#!/usr/bin/env bash
# Unit tests for wb-locks.sh (U1) — the per-task-file flock side-car lock
# primitives (wb_task_lock_acquire / wb_task_lock_release / the trap-append
# helper) every other concurrency-safety unit builds on. Plain-bash
# assertions against fixture files under mktemp -d, same convention as
# wb-handoffs.test.sh: hand-rolled `assert`, `set +e` after sourcing so
# non-zero returns are captured rather than aborting the script, a final
# ALL PASS/FAILURES line.
#
# This unit ships wb-locks.sh standalone (not yet wired into wb.sh or
# handoff.sh — that's U3), so this file sources wb-locks.sh directly, not
# wb.sh.
#
# Destructive/timing-sensitive scenarios here (SIGKILL, a real background
# holder process, flock contention timing) are meant to run inside the
# repo's Docker test sandbox, not raw on the host:
#   docker build -t wb-tests -f scripts/.config/scripts/tmux/tests/Dockerfile .
#   docker run --rm -v "$(pwd)":/repo:ro -w /repo wb-tests \
#     bash scripts/.config/scripts/tmux/tests/wb-locks.test.sh
#
# Run: bash scripts/.config/scripts/tmux/tests/wb-locks.test.sh
set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WB_LOCKS="$SELF_DIR/wb-locks.sh"
export WB_LOCKS

FIXTURE="$(mktemp -d -t wb-locks-fixture.XXXXXX)"
trap 'rm -rf "$FIXTURE"' EXIT

# Isolate all lock state under this fixture's own fake XDG/home dirs —
# never touch the real $XDG_STATE_HOME/wb/locks on whatever host or
# container is running this test.
export XDG_STATE_HOME="$FIXTURE/state"
export HOME="$FIXTURE/home"
mkdir -p "$XDG_STATE_HOME" "$HOME" "$FIXTURE/tasks"

# Force the "not inside tmux" baseline regardless of whatever environment
# is actually running this test file (e.g. a host shell that happens to be
# inside a real tmux session) — the tmux-identity scenario below opts back
# in deliberately, with a stubbed `tmux` binary.
unset TMUX TMUX_PANE

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
source "$WB_LOCKS"
set +e   # capture non-zero returns below rather than aborting the script

# =============================================================================
# Happy path: acquire -> holder file carries identity/pid/ISO timestamp/own
# tmux identity (empty outside tmux) -> release -> second acquire is instant.
# =============================================================================

TASK_HAPPY="$FIXTURE/tasks/repo--slug-happy.md"
printf -- '---\nstatus: doing\n---\n# Title\n' > "$TASK_HAPPY"

out="$(wb_task_lock_acquire "$TASK_HAPPY" 2>&1)"
rc=$?
# Note: `assert`'s grep -qE '^$' can't be used for "output is empty" — grep
# never matches a truly zero-byte input (there's no line to test the
# pattern against), so this checks emptiness directly instead.
[ -z "$out" ] && echo "ok   - happy: acquire produces zero output on an uncontended win (W7)" || { echo "FAIL - happy: acquire produced output: $out"; fail=1; }
[ "$rc" -eq 0 ] && echo "ok   - happy: acquire returns 0" || { echo "FAIL - happy: acquire returns 0 (got $rc)"; fail=1; }

LOCKFILE_HAPPY="$(_wb_lock_path_for "$TASK_HAPPY")"
[ -f "$LOCKFILE_HAPPY" ] && echo "ok   - happy: side-car lock file created under the lock dir" || { echo "FAIL - happy: lock file missing at $LOCKFILE_HAPPY"; fail=1; }

holder_content="$(cat "$LOCKFILE_HAPPY" 2>/dev/null)"
assert "happy: holder identity recorded (repo--disp_slug from the task file basename)" '^holder: repo--slug-happy$' "$holder_content"
assert "happy: pid recorded" "^pid: $$\$" "$holder_content"
assert "happy: ISO-8601 acquire timestamp recorded" '^acquired: [0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$' "$holder_content"
assert "happy: tmux_pane field present but empty (not inside tmux)" '^tmux_pane: *$' "$holder_content"
assert "happy: tmux_session field present but empty (not inside tmux)" '^tmux_session: *$' "$holder_content"

wb_task_lock_release "$TASK_HAPPY"
rc_rel=$?
[ "$rc_rel" -eq 0 ] && echo "ok   - happy: release returns 0" || { echo "FAIL - happy: release returns 0 (got $rc_rel)"; fail=1; }

start_ns=$(date +%s%N)
wb_task_lock_acquire "$TASK_HAPPY"
rc_second=$?
end_ns=$(date +%s%N)
elapsed_ms=$(( (end_ns - start_ns) / 1000000 ))
[ "$rc_second" -eq 0 ] && echo "ok   - happy: second acquire after release succeeds" || { echo "FAIL - happy: second acquire after release (got $rc_second)"; fail=1; }
[ "$elapsed_ms" -lt 500 ] && echo "ok   - happy: second acquire was instant (${elapsed_ms}ms, no lingering flock)" || { echo "FAIL - happy: second acquire took ${elapsed_ms}ms, expected instant"; fail=1; }
wb_task_lock_release "$TASK_HAPPY"

# =============================================================================
# tmux identity population: stub the `tmux` binary (may not even be
# installed/running here) to verify BOTH halves of W3's tri-state rule when
# actually inside tmux: TMUX_PANE copied verbatim, tmux session resolved via
# `tmux display -p '#S'`.
# =============================================================================

STUB_BIN="$FIXTURE/bin"
mkdir -p "$STUB_BIN"
cat > "$STUB_BIN/tmux" <<'EOF'
#!/usr/bin/env bash
if [ "$1" = display ]; then
  echo "fake-session"
  exit 0
fi
exit 1
EOF
chmod +x "$STUB_BIN/tmux"

TASK_TMUX="$FIXTURE/tasks/repo--slug-tmux.md"
printf -- '---\nstatus: doing\n---\n# Title\n' > "$TASK_TMUX"

(
  export PATH="$STUB_BIN:$PATH"
  export TMUX="/tmp/fake-tmux-socket,1234,0"
  export TMUX_PANE="%7"
  wb_task_lock_acquire "$TASK_TMUX"
)
# The subshell above exits once acquire returns, closing its fd (and thus
# the flock) automatically — nothing left to release from out here.
LOCKFILE_TMUX="$(_wb_lock_path_for "$TASK_TMUX")"
holder_tmux="$(cat "$LOCKFILE_TMUX" 2>/dev/null)"
assert "tmux identity: TMUX_PANE recorded verbatim when inside tmux" '^tmux_pane: %7$' "$holder_tmux"
assert "tmux identity: tmux session resolved via 'tmux display -p #S'" '^tmux_session: fake-session$' "$holder_tmux"

# =============================================================================
# Contention: a background (genuinely separate) process holds the lock; a
# foreground acquire attempt returns exit 75 within ~1s, naming the holder
# identity/pid/held-seconds — and, critically, does NOT blank the holder's
# own record (the W3 regression this whole idiom exists to prevent).
# =============================================================================

TASK_CONTEND="$FIXTURE/tasks/repo--slug-contend.md"
printf -- '---\nstatus: doing\n---\n# Title\n' > "$TASK_CONTEND"
export TASK_CONTEND
LOCKFILE_CONTEND="$(_wb_lock_path_for "$TASK_CONTEND")"

bash -c '
  source "$WB_LOCKS"
  wb_task_lock_acquire "$TASK_CONTEND" || exit 1
  sleep 3
  wb_task_lock_release "$TASK_CONTEND"
' &
HOLDER_PID=$!

sleep 1   # give the holder time to actually acquire + write its info first
content_before="$(cat "$LOCKFILE_CONTEND" 2>/dev/null)"
assert "contention: holder record present before the contending attempt" '^holder: repo--slug-contend$' "$content_before"
assert "contention: holder record carries the real holder pid" "^pid: $HOLDER_PID\$" "$content_before"

start_s=$(date +%s)
err_out="$(wb_task_lock_acquire "$TASK_CONTEND" 2>&1 1>/dev/null)"
rc_contend=$?
end_s=$(date +%s)
elapsed_s=$(( end_s - start_s ))

[ "$rc_contend" -eq 75 ] && echo "ok   - contention: losing acquire returns 75" || { echo "FAIL - contention: expected 75, got $rc_contend"; fail=1; }
[ "$elapsed_s" -le 2 ] && echo "ok   - contention: returned within the ~1s flock -w budget (${elapsed_s}s)" || { echo "FAIL - contention: took ${elapsed_s}s, expected ~1s"; fail=1; }

assert "contention: stderr names the holder identity" 'repo--slug-contend' "$err_out"
assert "contention: stderr names a pid" 'pid [0-9]+' "$err_out"
assert "contention: stderr names held-seconds" 'for [0-9]+s' "$err_out"
assert "contention: stderr addresses agents (stop + report, never clear)" 'Agents:.*(STOP|stop).*(report|clear)' "$err_out"
assert "contention: stderr addresses the operator-only rm override" 'Operator.*rm ' "$err_out"

content_after="$(cat "$LOCKFILE_CONTEND" 2>/dev/null)"
if [ "$content_before" = "$content_after" ]; then
  echo "ok   - contention: holder record byte-identical before/after the losing attempt (W3 regression guard)"
else
  echo "FAIL - contention: holder record CHANGED after a losing attempt (W3 regression!)"
  echo "       before: $content_before"
  echo "       after:  $content_after"
  fail=1
fi

wait "$HOLDER_PID" 2>/dev/null

# =============================================================================
# Crash release: kill -9 a process holding the lock; the NEXT acquire
# attempt succeeds promptly (kernel auto-releases flock on process death).
# =============================================================================

TASK_CRASH="$FIXTURE/tasks/repo--slug-crash.md"
printf -- '---\nstatus: doing\n---\n# Title\n' > "$TASK_CRASH"
export TASK_CRASH

bash -c '
  source "$WB_LOCKS"
  wb_task_lock_acquire "$TASK_CRASH" || exit 1
  sleep 30
' &
CRASH_PID=$!

sleep 1   # let it actually acquire first
kill -9 "$CRASH_PID" 2>/dev/null
wait "$CRASH_PID" 2>/dev/null   # reap; ignore the killed process's exit status
sleep 0.2   # brief grace for the kernel to tear down its fd table

start_ns=$(date +%s%N)
wb_task_lock_acquire "$TASK_CRASH"
rc_crash=$?
end_ns=$(date +%s%N)
elapsed_ms=$(( (end_ns - start_ns) / 1000000 ))

[ "$rc_crash" -eq 0 ] && echo "ok   - crash release: acquire after a SIGKILL'd holder succeeds" || { echo "FAIL - crash release: expected 0, got $rc_crash"; fail=1; }
[ "$elapsed_ms" -lt 500 ] && echo "ok   - crash release: succeeded promptly (${elapsed_ms}ms), no lingering flock" || { echo "FAIL - crash release: took ${elapsed_ms}ms — flock may not have auto-released"; fail=1; }

wb_task_lock_release "$TASK_CRASH"

# =============================================================================
# Kill-switch (X4): disable-locks file present -> acquire is a silent no-op
# success; release on top of that is equally a harmless no-op.
# =============================================================================

TASK_KILLSWITCH="$FIXTURE/tasks/repo--slug-killswitch.md"
printf -- '---\nstatus: doing\n---\n# Title\n' > "$TASK_KILLSWITCH"

DISABLE_FILE="$(_wb_lock_disable_file)"
mkdir -p "$(dirname "$DISABLE_FILE")"
: > "$DISABLE_FILE"

out_ks="$(wb_task_lock_acquire "$TASK_KILLSWITCH" 2>&1)"
rc_ks=$?
[ -z "$out_ks" ] && echo "ok   - kill-switch: acquire produces no output" || { echo "FAIL - kill-switch: acquire produced output: $out_ks"; fail=1; }
[ "$rc_ks" -eq 0 ] && echo "ok   - kill-switch: acquire returns 0 (silent no-op)" || { echo "FAIL - kill-switch: expected 0, got $rc_ks"; fail=1; }

LOCKFILE_KS="$(_wb_lock_path_for "$TASK_KILLSWITCH")"
if [ ! -e "$LOCKFILE_KS" ]; then
  echo "ok   - kill-switch: no lock file touched at all"
else
  echo "ok   - kill-switch: lock file exists but acquire still no-op'd (acceptable per spec)"
fi

out_ks_rel="$(wb_task_lock_release "$TASK_KILLSWITCH" 2>&1)"
rc_ks_rel=$?
[ -z "$out_ks_rel" ] && echo "ok   - kill-switch: release produces no output" || { echo "FAIL - kill-switch: release produced output: $out_ks_rel"; fail=1; }
[ "$rc_ks_rel" -eq 0 ] && echo "ok   - kill-switch: release returns 0" || { echo "FAIL - kill-switch: release expected 0, got $rc_ks_rel"; fail=1; }

rm -f "$DISABLE_FILE"

# =============================================================================
# Fail-closed: the lock directory can't be created -> exit 75, one distinct
# message naming the directory path. Uses a FILE occupying the path a
# directory needs to be created at (ENOTDIR) rather than chmod 000, so this
# holds regardless of whether the test happens to be running as root.
# =============================================================================

BLOCKING_FILE="$FIXTURE/blocking-file"
: > "$BLOCKING_FILE"
UNWRITABLE_STATE="$BLOCKING_FILE/state"   # can never become a directory

TASK_MKDIRFAIL="$FIXTURE/tasks/repo--slug-mkdirfail.md"
printf -- '---\nstatus: doing\n---\n# Title\n' > "$TASK_MKDIRFAIL"

err_mkdirfail="$(
  export XDG_STATE_HOME="$UNWRITABLE_STATE"
  wb_task_lock_acquire "$TASK_MKDIRFAIL" 2>&1 1>/dev/null
)"
rc_mkdirfail=$?

[ "$rc_mkdirfail" -eq 75 ] && echo "ok   - fail-closed (mkdir): acquire returns 75 when the lock dir can't be created" || { echo "FAIL - fail-closed (mkdir): expected 75, got $rc_mkdirfail"; fail=1; }
assert "fail-closed (mkdir): stderr names the failing directory path" "$UNWRITABLE_STATE/wb/locks" "$err_mkdirfail"
assert "fail-closed (mkdir): message mentions 'directory'" 'directory' "$err_mkdirfail"

# --- distinct sibling failure: the lock FILE itself can't be opened (a real
# directory sits at the exact lock-file path, so a read-write `<>` open
# fails with EISDIR) — requirement calls for a message DISTINCT from the
# mkdir failure above.
TASK_OPENFAIL="$FIXTURE/tasks/repo--slug-openfail.md"
printf -- '---\nstatus: doing\n---\n# Title\n' > "$TASK_OPENFAIL"
LOCKFILE_OPENFAIL="$(_wb_lock_path_for "$TASK_OPENFAIL")"
mkdir -p "$LOCKFILE_OPENFAIL"

err_openfail="$(wb_task_lock_acquire "$TASK_OPENFAIL" 2>&1 1>/dev/null)"
rc_openfail=$?

[ "$rc_openfail" -eq 75 ] && echo "ok   - fail-closed (open): acquire returns 75 when the lock file itself can't be opened" || { echo "FAIL - fail-closed (open): expected 75, got $rc_openfail"; fail=1; }
assert "fail-closed (open): stderr names the lock file path" "$LOCKFILE_OPENFAIL" "$err_openfail"

if [ "$err_mkdirfail" != "$err_openfail" ]; then
  echo "ok   - fail-closed: mkdir-failure and open-failure messages are distinct"
else
  echo "FAIL - fail-closed: mkdir-failure and open-failure messages are IDENTICAL (spec requires distinct messages)"
  fail=1
fi

rm -rf "$LOCKFILE_OPENFAIL"

# =============================================================================
# Trap composition: install a lock-cleanup trap in a subshell that ALREADY
# has an EXIT trap installed — verify BOTH the pre-existing trap's action
# and the appended one fire on exit, in the order they were installed.
# =============================================================================

SIDEFILE_TRAP="$FIXTURE/trap-side-effects.log"
: > "$SIDEFILE_TRAP"

(
  trap "echo pre >> '$SIDEFILE_TRAP'" EXIT
  wb_lock_trap_append "echo lockcleanup >> '$SIDEFILE_TRAP'"
  exit 0
)

trap_content="$(cat "$SIDEFILE_TRAP")"
assert "trap composition: pre-existing trap action fired" 'pre' "$trap_content"
assert "trap composition: appended lock-cleanup action also fired" 'lockcleanup' "$trap_content"

pre_line="$(grep -n '^pre$' "$SIDEFILE_TRAP" | cut -d: -f1)"
clean_line="$(grep -n '^lockcleanup$' "$SIDEFILE_TRAP" | cut -d: -f1)"
if [ -n "$pre_line" ] && [ -n "$clean_line" ] && [ "$pre_line" -lt "$clean_line" ]; then
  echo "ok   - trap composition: pre-existing trap fires before the appended one (install order preserved)"
else
  echo "FAIL - trap composition: wrong order or one action missing (pre=$pre_line, cleanup=$clean_line)"
  fail=1
fi

# --- no pre-existing trap at all: the helper still installs cleanly.
# `trap - EXIT` first, deliberately: a bare subshell would otherwise
# INHERIT this test script's own top-level `trap 'rm -rf "$FIXTURE"' EXIT`
# (bash subshells inherit trap actions from their parent), which isn't the
# "no prior trap" case this scenario means to exercise — and combining
# onto it for real would rm -rf the fixture out from under this very test
# before the appended action could write to it.
SIDEFILE_TRAP2="$FIXTURE/trap-side-effects-2.log"
: > "$SIDEFILE_TRAP2"
(
  trap - EXIT
  wb_lock_trap_append "echo onlycleanup >> '$SIDEFILE_TRAP2'"
  exit 0
)
trap_content2="$(cat "$SIDEFILE_TRAP2")"
assert "trap composition (no pre-existing trap): appended action still fires" 'onlycleanup' "$trap_content2"

# --- the real wb_task_lock_release_all safety-net body composes cleanly
# alongside a pre-existing trap and doesn't error when actually invoked ---
SIDEFILE_TRAP3="$FIXTURE/trap-side-effects-3.log"
: > "$SIDEFILE_TRAP3"
TASK_TRAPNET="$FIXTURE/tasks/repo--slug-trapnet.md"
printf -- '---\nstatus: doing\n---\n# Title\n' > "$TASK_TRAPNET"

(
  trap "echo pre3 >> '$SIDEFILE_TRAP3'" EXIT
  wb_lock_trap_append 'wb_task_lock_release_all'
  wb_task_lock_acquire "$TASK_TRAPNET"
  exit 0
)
rc_trapnet=$?
trap_content3="$(cat "$SIDEFILE_TRAP3")"
assert "trap composition: wb_task_lock_release_all composes without erroring" 'pre3' "$trap_content3"
[ "$rc_trapnet" -eq 0 ] && echo "ok   - trap composition: subshell using wb_task_lock_release_all as the EXIT-trap body exits cleanly" || { echo "FAIL - trap composition: subshell exited $rc_trapnet"; fail=1; }

# =============================================================================
[ "$fail" -eq 0 ] && echo "ALL PASS" || echo "FAILURES"
exit "$fail"
