#!/usr/bin/env bash
# Tests for `handoff.sh` (U1) — plain-bash assertions against real throwaway
# tmux sessions, same convention as wb-resume.test.sh / wb-pause.test.sh:
# source wb.sh (safe: the BASH_SOURCE guard at its end) to compute expected
# values via wb_sanitize/wb_task_file, and exercise handoff.sh itself as a
# real subprocess (it has no such guard — it's meant to run directly).
#
# One deliberate deviation from "never mock tmux": handoff.sh's switch path
# calls tmux_focus (lib.sh), which — whenever $TMUX is set, as it is in any
# shell already running inside tmux, including the one running this test —
# issues a REAL `tmux switch-client`. That repoints whatever real client is
# attached to THIS machine's tmux server (its actual visible terminal) to
# the throwaway fixture session, with no code path in this test to point it
# back. That's a real disruptive side effect on the live terminal, not a
# test artifact, so it's the one tmux operation these tests must not let
# through for real. A minimal PATH-shadowed `tmux` wrapper intercepts only
# `switch-client`/`attach` (records the call, exits 0) and forwards every
# other subcommand straight to the real binary — has-session, new-session,
# kill-session all still hit the real tmux server exactly like the rest of
# this suite.
# Run: bash scripts/.config/scripts/tmux/tests/handoff.test.sh
set -uo pipefail

HANDOFF="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/handoff.sh"
WB="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/wb.sh"
REAL_TMUX="$(command -v tmux)"
FIXTURE="$(mktemp -d -t handoff-fixture.XXXXXX)"
STUBDIR="$(mktemp -d -t handoff-stub.XXXXXX)"
FOCUS_LOG="$FIXTURE/.focus-calls"
: > "$FOCUS_LOG"

SESSIONS_TO_KILL=()
cleanup() {
  local s
  for s in "${SESSIONS_TO_KILL[@]}"; do
    tmux kill-session -t "=$s" 2>/dev/null || true
  done
  rm -rf "$FIXTURE" "$STUBDIR"
}
trap cleanup EXIT

# Shadow `tmux switch-client`/`tmux attach` only — see header comment.
cat > "$STUBDIR/tmux" <<EOF
#!/usr/bin/env bash
case "\$1" in
  switch-client|attach)
    echo "\$@" >> "$FOCUS_LOG"
    exit 0
    ;;
esac
exec "$REAL_TMUX" "\$@"
EOF
chmod +x "$STUBDIR/tmux"

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

assert_eq() { # <desc> <expected-exact> <actual>
  if [ "$3" = "$2" ]; then
    echo "ok   - $1"
  else
    echo "FAIL - $1"
    echo "       expected: $2"
    echo "       got:      $3"
    fail=1
  fi
}

# shellcheck disable=SC1090
source "$WB"
set +e   # wb.sh sets -e; this test intentionally captures non-zero exits
export TASKS_DIR="$FIXTURE"   # both this test's own wb_* calls and the
                               # handoff.sh subprocess (inherits via export)
                               # resolve task files against the same fixture

# run_handoff <repo> <slug> — invokes handoff.sh as a real subprocess with
# the tmux-shadow PATH prepended. Combines stdout+stderr (same convention as
# wb-resume.test.sh's run_resume).
run_handoff() {
  out="$(PATH="$STUBDIR:$PATH" bash "$HANDOFF" "$@" 2>&1)"
  rc=$?
}

# --- pure sanitize check: slash-containing slug -> same dashed form --------
assert_eq "wb_sanitize: feat/foo-bar -> feat-foo-bar" "feat-foo-bar" "$(wb_sanitize "feat/foo-bar")"

# --- happy path + slash edge case: live session -> switch + clipboard -----
REPO="testrepo"
SLUG="feat/foo-bar"
DISP_SLUG="$(wb_sanitize "$SLUG")"
SESSION="${REPO}--${DISP_SLUG}"
TASK_FILE="$(wb_task_file "$REPO" "$DISP_SLUG")"

mkdir -p "$(dirname "$TASK_FILE")"
printf -- '---\nstatus: doing\nrepo: %s\nbranch: %s\nworktree: .worktrees/x\ncreated: 2026-07-07\n---\n# Title\n' \
  "$REPO" "$SLUG" > "$TASK_FILE"

tmux new-session -d -s "$SESSION" 2>/dev/null
SESSIONS_TO_KILL+=("$SESSION")

run_handoff "$REPO" "$SLUG"
assert_eq "happy path: exits 0" "0" "$rc"
if [ "$rc" -ne 0 ]; then echo "       (out: $out)"; fi

expected_pointer="Read the task file at $TASK_FILE - it carries the full context and states the first action to take."
clip="$(wl-paste 2>/dev/null || true)"
assert_eq "happy path: clipboard holds exact pointer string" "$expected_pointer" "$clip"

if printf '%s' "$out" | grep -q 'spawn path'; then
  echo "FAIL - happy path: attempted the spawn path"
  fail=1
else
  echo "ok   - happy path: did not attempt the spawn path"
fi

assert "happy path: tmux_focus called real switch-client for the right session" \
  "switch-client -t =$SESSION" "$(cat "$FOCUS_LOG")"

# --- switch-path edge case: live session, task file missing ---------------
REPO2="testrepo2"
SLUG2="feat/no-task-file"
DISP_SLUG2="$(wb_sanitize "$SLUG2")"
SESSION2="${REPO2}--${DISP_SLUG2}"
TASK_FILE2="$(wb_task_file "$REPO2" "$DISP_SLUG2")"
# deliberately do NOT create $TASK_FILE2

tmux new-session -d -s "$SESSION2" 2>/dev/null
SESSIONS_TO_KILL+=("$SESSION2")

run_handoff "$REPO2" "$SLUG2"
assert_eq "missing task file: exits 0 (does not fail)" "0" "$rc"
assert "missing task file: warns to stderr" "warning.*$TASK_FILE2.*does not exist" "$out"

expected_pointer2="Read the task file at $TASK_FILE2 - it carries the full context and states the first action to take."
clip2="$(wl-paste 2>/dev/null || true)"
assert_eq "missing task file: still switches and clipboards" "$expected_pointer2" "$clip2"

# --- error path: no live session -> takes the spawn branch, not switch ----
# Branch-selection only — testrepo3 has no real ~/code checkout, so `wb new`
# itself fails loudly ("not a git repo") before any tmux/poller/injection
# logic runs. Full spawn-path coverage (poller, injection shape, bootstrap-
# gap, permission handshake) lives in handoff-poller.test.sh's isolated
# fixtures, not here — a real end-to-end spawn is the plan's manual smoke
# test, not this automated suite.
REPO3="testrepo3"
SLUG3="feat/never-spawned"
run_handoff "$REPO3" "$SLUG3"
assert_eq "no live session: exits non-zero (repo3 has no real git checkout)" "1" "$rc"
assert "no live session: takes the spawn branch, not the switch path" "wb new:.*not a git repo" "$out"

# --- error path: zero positional args --------------------------------------
printf 'sentinel-before-error-test' | wl-copy
run_handoff
assert_eq "zero args: exits non-zero" "1" "$rc"
assert "zero args: usage message on stderr" "usage: handoff\.sh <repo> <slug>" "$out"
clip_after_zero="$(wl-paste 2>/dev/null || true)"
assert_eq "zero args: clipboard untouched (no session/clipboard logic attempted)" \
  "sentinel-before-error-test" "$clip_after_zero"

# --- error path: one positional arg ----------------------------------------
run_handoff "onlyrepo"
assert_eq "one arg: exits non-zero" "1" "$rc"
assert "one arg: usage message on stderr" "usage: handoff\.sh <repo> <slug>" "$out"
clip_after_one="$(wl-paste 2>/dev/null || true)"
assert_eq "one arg: clipboard untouched (no session/clipboard logic attempted)" \
  "sentinel-before-error-test" "$clip_after_one"

[ "$fail" -eq 0 ] && echo "ALL PASS" || echo "FAILURES"
exit "$fail"
