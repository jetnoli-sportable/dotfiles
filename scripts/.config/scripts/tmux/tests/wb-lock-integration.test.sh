#!/usr/bin/env bash
# Integration tests for U3 (lock integration across all write chains) — the
# plan's highest-risk unit: wiring U1's wb_task_lock_acquire/release into
# every real wb.sh/handoff.sh write burst, plus the L2-L5 caller-side
# orphan-check-and-retry wrapper (wb_task_lock_acquire_guarded) built on top
# of U2's tmux_session_agent_state. Unlike wb-locks.test.sh (U1, unit tests
# against wb-locks.sh alone), this sources the REAL wb.sh so every scenario
# below exercises the actual wrapper + the real cmd_*/wb_reconcile_action_*
# lock bursts, not a hand-rolled stand-in.
#
# Real concurrent background processes, SIGKILL-adjacent liveness edge
# cases (a still-running-but-lock-free "orphan"), and flock contention
# timing — run ONLY inside this repo's Docker test sandbox, never bare on
# the host:
#   docker build -t wb-tests -f scripts/.config/scripts/tmux/tests/Dockerfile . -q
#   docker run --rm -v "$(pwd)":/repo:ro -w /repo wb-tests \
#     bash scripts/.config/scripts/tmux/tests/wb-lock-integration.test.sh
set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WB="$SELF_DIR/wb.sh"
WB_LOCKS="$SELF_DIR/wb-locks.sh"
export WB_LOCKS

FIXTURE="$(mktemp -d -t wb-lock-integ-fixture.XXXXXX)"
SOCK="wb-lock-integ-sock-$$"
REAL_TMUX="$(command -v tmux)"
ALL_TMP=()
HOLDER_PIDS=()
FIXTURE_SESSIONS=()

STUB_BIN="$FIXTURE/bin"
mkdir -p "$STUB_BIN"
cat > "$STUB_BIN/tmux" <<EOF
#!/usr/bin/env bash
exec "$REAL_TMUX" -L "$SOCK" "\$@"
EOF
chmod +x "$STUB_BIN/tmux"
PATH="$STUB_BIN:$PATH"

CLAUDE_STUB_DIR="$FIXTURE/claude-bin"
mkdir -p "$CLAUDE_STUB_DIR"
cp "$(command -v sleep)" "$CLAUDE_STUB_DIR/claude"
chmod +x "$CLAUDE_STUB_DIR/claude"

cleanup() {
  for pid in "${HOLDER_PIDS[@]:-}"; do
    [ -n "$pid" ] && kill "$pid" 2>/dev/null
  done
  for pid in "${HOLDER_PIDS[@]:-}"; do
    [ -n "$pid" ] && wait "$pid" 2>/dev/null
  done
  for s in "${FIXTURE_SESSIONS[@]:-}"; do
    [ -n "$s" ] && "$REAL_TMUX" -L "$SOCK" kill-session -t "=$s" 2>/dev/null
  done
  "$REAL_TMUX" -L "$SOCK" kill-server 2>/dev/null || true
  rm -rf "$FIXTURE" "${ALL_TMP[@]:-}"
}
trap cleanup EXIT

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
assert_not() { # <desc> <regex> <actual> — passes when <regex> does NOT match
  if printf '%s' "$3" | grep -qE "$2"; then
    echo "FAIL - $1"
    echo "       unexpected match: $2"
    echo "       got: $(printf '%s' "$3" | head -8)"
    fail=1
  else
    echo "ok   - $1"
  fi
}

# Isolate all lock state under this fixture's own fake XDG/home dirs — never
# touch the real $XDG_STATE_HOME/wb/locks on whatever host or container is
# running this test (same convention as wb-locks.test.sh).
export XDG_STATE_HOME="$FIXTURE/state"
export HOME="$FIXTURE/home"
mkdir -p "$XDG_STATE_HOME" "$HOME"

export CODE_DIR="$FIXTURE/code"
export TASKS_DIR="$FIXTURE/tasks"
mkdir -p "$CODE_DIR" "$TASKS_DIR"
printf -- '---\nstatus: planned\nrepo:\nbranch:\nworktree:\nparent:\ntags: []\ncreated:\nclosed:\n---\n# Title\n' \
  > "$TASKS_DIR/TEMPLATE.md"

# shellcheck disable=SC1090
source "$WB"
set +e   # wb.sh sets -e; this suite intentionally captures non-zero exits

# =============================================================================
# Shared helpers for the L2-L5 (orphan-check) scenarios below.
# =============================================================================

# HOLDER_SCRIPT — a real, separate background process used to simulate a
# lock holder with a controllable recorded identity. Filename deliberately
# contains "wb.sh" so /proc/<pid>/cmdline satisfies wb.sh's
# _wb_lock_cmdline_wb_shaped process-identity check exactly like a real
# wb.sh subprocess would.
#
# `exec >>"$HOLDER_LOG" 2>&1` as its very FIRST line is load-bearing, not
# cosmetic logging: every holder here is launched from INSIDE a command
# substitution (spawn_holder is always called as `pid="$(spawn_holder ...)"`
# to capture the pid it echoes), so the backgrounded holder process inherits
# that command substitution's own internal pipe as its stdout/stderr — and
# a background job left holding that pipe's write end open past its
# capturing subshell's own exit gets torn down early (confirmed live: with
# no redirect here, the holder's own lock-file write proves it acquired
# correctly, then the process vanishes from `ps` almost immediately,
# well before its requested hold_secs elapses — every contention scenario
# below silently degenerated into an uncontended instant-success). Giving
# the holder its own independent output sink up front avoids that
# pipe entirely.
HOLDER_LOG="$FIXTURE/holder-output.log"
HOLDER_SCRIPT="$FIXTURE/lock-holder-wb.sh"
cat > "$HOLDER_SCRIPT" <<'EOF'
#!/usr/bin/env bash
exec >>"$HOLDER_LOG" 2>&1
source "$WB_LOCKS"
task_file="$1"; hold_secs="${2:-30}"; release_after_hold="${3:-0}"
wb_task_lock_acquire "$task_file" || exit 1
sleep "$hold_secs"
if [ "$release_after_hold" = 1 ]; then
  wb_task_lock_release "$task_file"
  sleep 60   # stay alive (kill -0 still succeeds) with the flock now free
fi
EOF
chmod +x "$HOLDER_SCRIPT"
export HOLDER_LOG

# spawn_holder <task_file> <hold_secs> <tmux_session_name> [<release_after_hold>]
# — launches HOLDER_SCRIPT as a genuinely separate process (via `exec`, so
# the forked subshell's own pid IS the holder's pid) with a per-call `tmux`
# stub prepended to PATH that answers `tmux display -p '#S'` with
# <tmux_session_name> — this is what wb-locks.sh's own
# _wb_lock_own_tmux_session records as the holder's own identity at acquire
# time, independent of whether <tmux_session_name> corresponds to a real
# tmux session on the fixture socket (the L2/L5 scenarios below control
# both independently: what name gets recorded, and whether a same-named
# session genuinely exists). Echoes the holder's pid.
spawn_holder() {
  local task_file="$1" hold_secs="$2" session_name="$3" release_after="${4:-0}"
  local stubdir; stubdir="$(mktemp -d -t wb-lock-integ-holderstub.XXXXXX)"
  ALL_TMP+=("$stubdir")
  cat > "$stubdir/tmux" <<STUBEOF
#!/usr/bin/env bash
if [ "\$1" = display ]; then
  echo "$session_name"
  exit 0
fi
exit 1
STUBEOF
  chmod +x "$stubdir/tmux"
  (
    export PATH="$stubdir:$PATH" TMUX="fake,1,0" TMUX_PANE="%9"
    exec bash "$HOLDER_SCRIPT" "$task_file" "$hold_secs" "$release_after"
  ) &
  local pid=$!
  HOLDER_PIDS+=("$pid")
  echo "$pid"
}

# _wait_for_holder <task_file> <holder_pid> [<timeout_secs>] — polls the
# side-car lock file (up to <timeout_secs>, default 3) until it records
# <holder_pid> as the current holder, instead of a blind `sleep N` guess.
# spawn_holder's own process spends a variable (Docker-load-dependent)
# amount of time on setup (mktemp, chmod, forking bash, sourcing
# wb-locks.sh) before it actually calls wb_task_lock_acquire — a fixed
# short sleep here was observed to flake under load (a scenario's own
# acquire attempt racing ahead of the holder's, seeing an uncontended lock
# and silently succeeding instead of exercising the contention path this
# whole suite exists to prove).
_wait_for_holder() {
  local task_file="$1" holder_pid="$2" timeout="${3:-3}" lockfile waited=0
  lockfile="$(_wb_lock_path_for "$task_file")"
  while [ "$waited" -lt "$((timeout * 10))" ]; do
    [ "$(_wb_lock_field "$lockfile" pid)" = "$holder_pid" ] && return 0
    sleep 0.1
    waited=$((waited + 1))
  done
  return 1
}

# _patch_acquired_timestamp <lockfile> <seconds_ago> — rewrites the
# `acquired:` line IN PLACE via a same-inode truncating `>` redirect — never
# `mv`/`sed -i`'s default rename-based edit, which would swap in a FRESH,
# lock-free inode at the same path out from under the real holder's still-
# open fd, silently breaking the very contention this test is simulating
# (the holder's flock lives on the OLD inode; a renamed-in replacement
# carries no lock at all).
_patch_acquired_timestamp() {
  local lockfile="$1" seconds_ago="$2" new_ts content
  new_ts="$(date -u -d "@$(( $(date +%s) - seconds_ago ))" +%Y-%m-%dT%H:%M:%SZ)"
  content="$(awk -v ts="$new_ts" '{ if ($0 ~ /^acquired: /) print "acquired: " ts; else print }' "$lockfile")"
  printf '%s\n' "$content" > "$lockfile"
}

# =============================================================================
# Scenario: incident-4 repro — two concurrent writers on the SAME fixture
# task file, each a real background process, each wrapped in the new
# acquire/release. One simulates cmd_pause's own frontmatter+Handoffs chain;
# the other simulates a `wb append`-style Follow-ups insert (the verb itself
# is U4, not built yet) via the same read-modify-write-via-mv shape. Zero
# lost writes expected.
# =============================================================================

INC4_TASK="$TASKS_DIR/proj--incident4.md"
printf -- '---\nstatus: doing\nrepo: proj\nbranch: incident4\nworktree: .worktrees/incident4\ntags: []\ncreated: 2026-07-07\nclosed:\n---\n# Title\n\n## Handoffs\n\n## Follow-ups\n\n' \
  > "$INC4_TASK"

# sim_append_followup <file> <line> — the `wb append`-shaped write: read the
# whole file, splice a line under "## Follow-ups" via awk, write back via
# tmp+mv (the exact shape handoff_append_followup/wb_append_handoff already
# use elsewhere in this codebase).
sim_append_followup() {
  local file="$1" line="$2"
  awk -v line="$line" '
    { print }
    $0 == "## Follow-ups" && !done { print "- " line; done = 1 }
  ' "$file" > "$file.tmp.$$" && mv "$file.tmp.$$" "$file"
}

(
  wb_task_lock_acquire_guarded "$INC4_TASK" || exit 1
  sleep 0.3   # widen the race window a real unlocked pair would lose to
  wb_set_frontmatter "$INC4_TASK" status paused
  wb_append_handoff "$INC4_TASK" "wb pause" 'Session paused via `wb pause`.'
  wb_task_lock_release "$INC4_TASK"
) &
INC4_A_PID=$!

(
  wb_task_lock_acquire_guarded "$INC4_TASK" || exit 1
  sleep 0.15
  sim_append_followup "$INC4_TASK" "concurrent append landed"
  wb_task_lock_release "$INC4_TASK"
) &
INC4_B_PID=$!

wait "$INC4_A_PID"; INC4_RC_A=$?
wait "$INC4_B_PID"; INC4_RC_B=$?

assert_eq "incident-4: writer A (frontmatter+Handoffs chain) succeeded" 0 "$INC4_RC_A"
assert_eq "incident-4: writer B (Follow-ups append) succeeded" 0 "$INC4_RC_B"
inc4_content="$(cat "$INC4_TASK")"
assert "incident-4: writer A's status flip landed" '^status: paused$' "$inc4_content"
assert "incident-4: writer A's Handoffs entry landed" 'Session paused via `wb pause`\.' "$inc4_content"
assert "incident-4: writer B's Follow-ups append landed" '^- concurrent append landed$' "$inc4_content"
frontmatter_markers="$(grep -c '^---$' "$INC4_TASK")"
assert_eq "incident-4: exactly 2 frontmatter markers (no interleaved corruption)" 2 "$frontmatter_markers"

# =============================================================================
# Scenario: incident-1's shape — two concurrent seed paths for the SAME new
# task (simulating two `cmd_new`-shaped concurrent calls for the identical
# repo+slug). Exactly one actually seeds; the other safely no-ops on the
# already-seeded file. Neither ever interleaves/corrupts the frontmatter.
# =============================================================================

INC1_REPO="proj"
INC1_SLUG="incident1-new"
INC1_TASK_FILE="$(wb_task_file "$INC1_REPO" "$(wb_sanitize "$INC1_SLUG")")"
rm -f "$INC1_TASK_FILE"

seed_writer() {
  local rel="$1"
  wb_task_lock_acquire_guarded "$INC1_TASK_FILE" || exit 1
  sleep 0.2   # widen the race window
  wb_seed_task "$INC1_REPO" "$INC1_SLUG" "$rel" >/dev/null
  wb_task_lock_release "$INC1_TASK_FILE"
}

( seed_writer ".worktrees/incident1-new" ) &
INC1_PID1=$!
( seed_writer ".worktrees/incident1-new" ) &
INC1_PID2=$!
wait "$INC1_PID1"; INC1_RC1=$?
wait "$INC1_PID2"; INC1_RC2=$?

assert_eq "incident-1: seed path 1 exits 0" 0 "$INC1_RC1"
assert_eq "incident-1: seed path 2 exits 0 (blocks, then sees already-seeded file — idempotent)" 0 "$INC1_RC2"
[ -f "$INC1_TASK_FILE" ] && echo "ok   - incident-1: task file exists" || { echo "FAIL - incident-1: task file missing"; fail=1; }
inc1_markers="$(grep -c '^---$' "$INC1_TASK_FILE" 2>/dev/null || echo 0)"
assert_eq "incident-1: exactly 2 frontmatter markers (not interleaved/corrupted)" 2 "$inc1_markers"
assert "incident-1: repo: field correctly set, not garbled" '^repo: proj$' "$(cat "$INC1_TASK_FILE")"
assert "incident-1: branch: field correctly set, not garbled" '^branch: incident1-new$' "$(cat "$INC1_TASK_FILE")"
assert "incident-1: worktree: field correctly set, not garbled" '^worktree: \.worktrees/incident1-new$' "$(cat "$INC1_TASK_FILE")"
assert "incident-1: status flipped planned->doing exactly once" '^status: doing$' "$(cat "$INC1_TASK_FILE")"

# =============================================================================
# Scenario: reconcile — `_merge` acquires survivor+loser in SORTED-PATH
# order (W11): pre-hold a lock on whichever of the pair sorts FIRST and
# confirm wb_reconcile_action_merge contends on THAT path (proving it's
# attempted first); pre-hold a lock on whichever sorts SECOND and confirm
# the function gets past the first lock cleanly and only contends on the
# second (and releases the first again afterward, rather than leaking it).
# =============================================================================

mk_merge_task() { # <file> <branch> <worktree>
  printf -- '---\nstatus: doing\nrepo: proj\nbranch: %s\nworktree: %s\ntags: []\ncreated: 2026-07-08\nclosed:\n---\n# Title\n\n## Plan\n\nSome plan.\n\n## Done\n\n## Follow-ups\n\n' \
    "$2" "$3" > "$1"
}
MERGE_FIRST="$TASKS_DIR/aaa--merge-first.md"    # sorts before merge-second
MERGE_SECOND="$TASKS_DIR/zzz--merge-second.md"
mk_merge_task "$MERGE_FIRST" branch-first worktree-first
mk_merge_task "$MERGE_SECOND" branch-second worktree-second
MERGE_BLOCK=$'- [x] survivor: this finding (new stub)\n'

# --- pre-hold the alphabetically-FIRST path -> merge must contend on it ----
merge_holder1="$(spawn_holder "$MERGE_FIRST" 2 "merge-order-irrelevant-session")"
_wait_for_holder "$MERGE_FIRST" "$merge_holder1"
merge_err1="$(wb_reconcile_action_merge missing proj branch-second worktree-second "$MERGE_SECOND" "$(basename "$MERGE_FIRST")" "$MERGE_BLOCK" 2>&1 1>/dev/null)"
merge_rc1=$?
assert_eq "reconcile _merge: sorted-first-locked -> action halts (75)" 75 "$merge_rc1"
assert "reconcile _merge: contends on the SORTED-FIRST path by name" "$(basename "$MERGE_FIRST")" "$merge_err1"
wait "$merge_holder1" 2>/dev/null

# --- pre-hold the alphabetically-SECOND path -> merge gets past the first
# lock, then contends on the second, and releases the first again rather
# than leaking it (an immediate follow-up acquire on the first succeeds
# instantly) ----
merge_holder2="$(spawn_holder "$MERGE_SECOND" 2 "merge-order-irrelevant-session")"
_wait_for_holder "$MERGE_SECOND" "$merge_holder2"
merge_err2="$(wb_reconcile_action_merge missing proj branch-second worktree-second "$MERGE_SECOND" "$(basename "$MERGE_FIRST")" "$MERGE_BLOCK" 2>&1 1>/dev/null)"
merge_rc2=$?
assert_eq "reconcile _merge: sorted-second-locked -> action halts (75)" 75 "$merge_rc2"
assert "reconcile _merge: contends on the SORTED-SECOND path by name (proves the first was acquired cleanly)" "$(basename "$MERGE_SECOND")" "$merge_err2"
# Run the release-leak check (and its own release) inside a subshell:
# wb_task_lock_release's `exec {fd}<&- 2>/dev/null || true` closes the fd
# via a BARE `exec` with only redirections and no command — which applies
# ALL of those redirections to the CURRENT shell itself (the standard `exec
# > file` idiom for permanently redirecting a shell's own output), so it
# permanently redirects fd 2 (stderr) to /dev/null for whatever process
# calls it, not just for that one statement (confirmed live: this suite's
# own diagnostic `>&2` traces silently stopped working the moment ANY
# wb_task_lock_release call ran at this script's OWN top level — a latent
# wb-locks.sh (U1) behavior this unit doesn't touch or attempt to fix).
# A subshell's fd table is a private copy, so the corruption stays scoped
# to it and never reaches this script's own stderr.
release_check_out="$(
  start_release_check=$(date +%s%N)
  wb_task_lock_acquire_guarded "$MERGE_FIRST"
  rc_release_check=$?
  end_release_check=$(date +%s%N)
  elapsed_ms=$(( (end_release_check - start_release_check) / 1000000 ))
  wb_task_lock_release "$MERGE_FIRST"
  printf '%s %s\n' "$rc_release_check" "$elapsed_ms"
)"
read -r rc_release_check elapsed_ms <<< "$release_check_out"
[ "$rc_release_check" -eq 0 ] && [ "$elapsed_ms" -lt 500 ] \
  && echo "ok   - reconcile _merge: the sorted-first lock was released again after the second contended (no leak, ${elapsed_ms}ms)" \
  || { echo "FAIL - reconcile _merge: sorted-first lock appears leaked (rc=$rc_release_check, ${elapsed_ms}ms)"; fail=1; }
wait "$merge_holder2" 2>/dev/null

# =============================================================================
# Scenario: reconcile — `_remove` under contention halts rather than
# deleting mid-write (a bare `rm -f` racing another writer's tmp+mv could
# otherwise resurrect the file if unlocked, per W10).
# =============================================================================

REMOVE_TASK="$TASKS_DIR/proj--remove-contend.md"
mk_merge_task "$REMOVE_TASK" branch-remove worktree-remove
remove_holder="$(spawn_holder "$REMOVE_TASK" 2 "remove-order-irrelevant-session")"
_wait_for_holder "$REMOVE_TASK" "$remove_holder"
remove_err="$(wb_reconcile_action_remove missing proj branch-remove worktree-remove "$REMOVE_TASK" 2>&1 1>/dev/null)"
remove_rc=$?
assert_eq "reconcile _remove: under contention, halts (75) rather than deleting" 75 "$remove_rc"
assert "reconcile _remove: contention message names the target" "$(basename "$REMOVE_TASK")" "$remove_err"
[ -f "$REMOVE_TASK" ] && echo "ok   - reconcile _remove: task file NOT deleted while contended" || { echo "FAIL - reconcile _remove: task file was deleted despite contention"; fail=1; }
wait "$remove_holder" 2>/dev/null

# =============================================================================
# Scenario (code-review regression): wb_reconcile_apply's real loop over a
# batch of 2+ checked findings degrades a contended finding to a per-finding
# skip instead of aborting the WHOLE --apply run under set -e. Every
# wb_reconcile_action_* call is now lock-guarded (W10), which can return 75
# on contention — routine, not rare, at this feature's ~10-concurrent-agent
# scale — and a prior version called each action as a bare statement with no
# `||` guard, so the FIRST contended finding in a batch killed the entire
# process, silently skipping every finding after it.
# =============================================================================

BATCH_TASK_A="$TASKS_DIR/proj--batch-a.md"
BATCH_TASK_B="$TASKS_DIR/proj--batch-b.md"
mk_merge_task "$BATCH_TASK_A" branch-batch-a worktree-batch-a
mk_merge_task "$BATCH_TASK_B" branch-batch-b worktree-batch-b
BATCH_REPORT="$(mktemp -u -t wb-lock-integ-batch-report.XXXXXX.md)"
ALL_TMP+=("$BATCH_REPORT")
cat > "$BATCH_REPORT" <<EOF
# wb reconcile — review

## 1. missing worktree — proj / batch-a

<!-- wb-reconcile: kind=missing repo=proj branch=branch-batch-a worktree=worktree-batch-a taskfile=$BATCH_TASK_A -->

- [ ] do nothing
- [x] remove
- [ ] discuss

## 2. missing worktree — proj / batch-b

<!-- wb-reconcile: kind=missing repo=proj branch=branch-batch-b worktree=worktree-batch-b taskfile=$BATCH_TASK_B -->

- [ ] do nothing
- [x] remove
- [ ] discuss
EOF

wb_reconcile_report_path() { printf '%s' "$BATCH_REPORT"; }
batch_holder="$(spawn_holder "$BATCH_TASK_A" 2 "batch-order-irrelevant-session")"
_wait_for_holder "$BATCH_TASK_A" "$batch_holder"

batch_out="$(wb_reconcile_apply 2>&1)"
assert "reconcile --apply batch: reports partial completion (1 applied, 1 skipped)" '1 applied, 1 skipped' "$batch_out"
[ -f "$BATCH_TASK_A" ] && echo "ok   - reconcile --apply batch: contended finding (A) left untouched, not deleted" || { echo "FAIL - reconcile --apply batch: contended finding (A) was deleted"; fail=1; }
[ ! -f "$BATCH_TASK_B" ] && echo "ok   - reconcile --apply batch: uncontended finding (B) still applied despite A's contention" || { echo "FAIL - reconcile --apply batch: uncontended finding (B) was never reached (whole batch aborted)"; fail=1; }
wait "$batch_holder" 2>/dev/null
unset -f wb_reconcile_report_path

# =============================================================================
# Scenario: reconcile — existing checked-box gate behavior is unchanged (a
# quick smoke test only; wb-reconcile-review.test.sh already covers this
# logic in depth). Real fixture repo + worktree, faked `gh`, stubbed
# wb_open_buffer/wb_reconcile_report_path/wb_reconcile_repos.
# =============================================================================

SMOKE_REPORT="$(mktemp -u -t wb-lock-integ-smoke-report.XXXXXX.md)"
ALL_TMP+=("$SMOKE_REPORT")
cat > "$STUB_BIN/gh" <<'EOF'
#!/usr/bin/env bash
echo '[]'
EOF
chmod +x "$STUB_BIN/gh"

git init -q "$CODE_DIR/smokeproj"
git -C "$CODE_DIR/smokeproj" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
git -C "$CODE_DIR/smokeproj" worktree add -q -b smoke-orphan ".worktrees/smoke-orphan" >/dev/null 2>&1

wb_open_buffer() { :; }
wb_reconcile_report_path() { printf '%s' "$SMOKE_REPORT"; }
wb_reconcile_repos() { printf '%s\n' "$CODE_DIR/smokeproj"; }

cmd_reconcile --review >/dev/null 2>&1
sed -i '0,/^- \[ \] do nothing$/s//- [x] do nothing/' "$SMOKE_REPORT"
cmd_reconcile --apply >/dev/null 2>&1
[ -d "$CODE_DIR/smokeproj/.worktrees/smoke-orphan" ] \
  && echo "ok   - reconcile smoke test: checked-box gate unchanged (do-nothing left the worktree alone)" \
  || { echo "FAIL - reconcile smoke test: worktree was removed despite 'do nothing'"; fail=1; }

# =============================================================================
# Scenario: cmd_done — the lock must NOT be held while wb_open_buffer runs.
# Stub wb_open_buffer to itself attempt an acquire on the SAME task file
# from within the stub; that inner acquire must succeed instantly, proving
# the outer cmd_done isn't holding it at that point.
# =============================================================================

git init -q "$CODE_DIR/doneproj"
# .gitignore committed BEFORE the worktree's branch forks off HEAD — a
# worktree's own branch only sees files present in the commit it was
# created FROM; committing .gitignore afterward, on the main checkout's
# still-checked-out branch, would land on a DIFFERENT branch the worktree
# never sees, and `git status --porcelain` (no --ignored) would then report
# the later-added .env as a plain untracked (dirty) file instead of
# ignoring it — confirmed live while building this scenario.
cat > "$CODE_DIR/doneproj/.gitignore" <<'EOF'
.env
EOF
git -C "$CODE_DIR/doneproj" add .gitignore
git -C "$CODE_DIR/doneproj" -c user.email=t@t -c user.name=t commit -q -m gitignore
git -C "$CODE_DIR/doneproj" worktree add -q -b done-lock-check ".worktrees/done-lock-check" >/dev/null 2>&1
echo secretstuff > "$CODE_DIR/doneproj/.worktrees/done-lock-check/.env"   # an ignored file -> exercises burst 1

DONE_TASK_FILE="$TASKS_DIR/doneproj--done-lock-check.md"
printf -- '---\nstatus: doing\nrepo: doneproj\nbranch: done-lock-check\nworktree: .worktrees/done-lock-check\ntags: []\ncreated: 2026-07-07\nclosed:\n---\n# Title\n' \
  > "$DONE_TASK_FILE"

DONE_SESSION="wb-lock-integ-done-$$"
tmux new-session -d -s "$DONE_SESSION" 2>/dev/null
FIXTURE_SESSIONS+=("$DONE_SESSION")
tmux set-option -t "=$DONE_SESSION:" @wb_repo doneproj >/dev/null
tmux set-option -t "=$DONE_SESSION:" @wb_slug done-lock-check >/dev/null

BUFFER_INNER_RESULT="$FIXTURE/buffer-inner-result"
: > "$BUFFER_INNER_RESULT"
wb_open_buffer() {
  local path="$1"
  local start_ns end_ns elapsed_ms
  start_ns=$(date +%s%N)
  if wb_task_lock_acquire_guarded "$path"; then
    end_ns=$(date +%s%N)
    elapsed_ms=$(( (end_ns - start_ns) / 1000000 ))
    printf 'ok %s\n' "$elapsed_ms" > "$BUFFER_INNER_RESULT"
    wb_task_lock_release "$path"
  else
    printf 'FAILED\n' > "$BUFFER_INNER_RESULT"
  fi
}

done_out="$(cmd_done "$DONE_SESSION" 2>&1)"
done_rc=$?
assert_eq "cmd_done: exits 0" 0 "$done_rc"
[ "$done_rc" -eq 0 ] || echo "       cmd_done output: $done_out"
buffer_result="$(cat "$BUFFER_INNER_RESULT")"
assert "cmd_done: wb_open_buffer's own inner acquire succeeded (lock was free)" '^ok ' "$buffer_result"
buffer_elapsed="$(awk '{print $2}' <<< "$buffer_result")"
if [ -n "$buffer_elapsed" ] && [ "$buffer_elapsed" -lt 500 ] 2>/dev/null; then
  echo "ok   - cmd_done: inner acquire was instant (${buffer_elapsed}ms, outer cmd_done wasn't holding it)"
else
  echo "FAIL - cmd_done: inner acquire took ${buffer_elapsed}ms — outer lock may still have been held"
  fail=1
fi
assert "cmd_done: task flipped to done" '^status: done$' "$(cat "$DONE_TASK_FILE")"

# =============================================================================
# Scenario L2 (kill path) — a recorded holder with a DEAD tmux session
# (never created for real) but a YOUNG (<60s) acquire timestamp must NOT be
# cleared: the wrapper must halt exactly like an ordinary contention, with
# no retry attempted (proven by exactly ONE "contended on" message).
# =============================================================================

L2_YOUNG_TASK="$TASKS_DIR/proj--l2-young.md"
printf -- '---\nstatus: doing\nrepo: proj\nbranch: l2-young\nworktree: .worktrees/l2-young\ntags: []\ncreated: 2026-07-07\nclosed:\n---\n# Title\n' \
  > "$L2_YOUNG_TASK"

l2young_holder="$(spawn_holder "$L2_YOUNG_TASK" 3 "l2-young-dead-session")"
_wait_for_holder "$L2_YOUNG_TASK" "$l2young_holder"   # let it actually acquire (and record a fresh, young timestamp) first
l2young_err="$(wb_task_lock_acquire_guarded "$L2_YOUNG_TASK" 2>&1 1>/dev/null)"
l2young_rc=$?
assert_eq "L2 young-timestamp dead-session: exit 75 (NOT cleared)" 75 "$l2young_rc"
l2young_contend_count="$(grep -oc 'contended on' <<< "$l2young_err")"
assert_eq "L2 young-timestamp dead-session: exactly ONE contention message (no retry attempted — mid-spawn protection)" 1 "$l2young_contend_count"
wait "$l2young_holder" 2>/dev/null

# =============================================================================
# Scenario L2 (kill path, positive) — a recorded holder with a DEAD tmux
# session, an OLD (>60s, synthetically patched) acquire timestamp, a
# confirmed wb/claude-shaped /proc/<pid>/cmdline, and its own recorded pane
# confirmed gone: cleared, and the lock is successfully retried.
# =============================================================================

L2_OLD_TASK="$TASKS_DIR/proj--l2-old.md"
printf -- '---\nstatus: doing\nrepo: proj\nbranch: l2-old\nworktree: .worktrees/l2-old\ntags: []\ncreated: 2026-07-07\nclosed:\n---\n# Title\n' \
  > "$L2_OLD_TASK"

# hold_secs=1.5 (> the wrapper's own first `flock -w 1` timeout, so that
# FIRST attempt genuinely contends and returns 75) then release-but-stay-
# alive (kill -0 keeps succeeding with the flock now actually free — the
# "zombie/orphaned wb subprocess" shape L2 describes, without needing an
# actual OS zombie).
l2old_holder="$(spawn_holder "$L2_OLD_TASK" 1.5 "l2-old-dead-session" 1)"
_wait_for_holder "$L2_OLD_TASK" "$l2old_holder"   # let it actually acquire + write its holder info first
l2old_lockfile="$(_wb_lock_path_for "$L2_OLD_TASK")"
_patch_acquired_timestamp "$l2old_lockfile" 65

start_ns=$(date +%s%N)
l2old_err="$(wb_task_lock_acquire_guarded "$L2_OLD_TASK" 2>&1 1>/dev/null)"
l2old_rc=$?
end_ns=$(date +%s%N)
l2old_elapsed_ms=$(( (end_ns - start_ns) / 1000000 ))

assert_eq "L2 old-timestamp dead-session: cleared and retried -> exit 0" 0 "$l2old_rc"
l2old_contend_count="$(grep -oc 'contended on' <<< "$l2old_err")"
assert_eq "L2 old-timestamp dead-session: exactly ONE contention message (the original failed attempt; no second halt message)" 1 "$l2old_contend_count"
echo "info - L2 old-timestamp dead-session: guarded acquire took ${l2old_elapsed_ms}ms (expected roughly 1000-2500ms: one failed 1s attempt, then a retry that unblocks once the holder actually releases)"
wb_task_lock_release "$L2_OLD_TASK"
kill "$l2old_holder" 2>/dev/null
wait "$l2old_holder" 2>/dev/null

# =============================================================================
# Scenario L5 — a recorded holder whose OWN recorded tmux session is
# confirmed ALIVE (a real session on the fixture socket, `:agent` window
# running the claude stub): exit 75, no clearing attempted at all — the
# wrapper must not even run the orphan-check's deeper conditions, only the
# top-level tmux-state check.
# =============================================================================

L5_ALIVE_SESSION="wb-lock-integ-l5-alive-$$"
tmux new-session -d -s "$L5_ALIVE_SESSION" 2>/dev/null
FIXTURE_SESSIONS+=("$L5_ALIVE_SESSION")
tmux new-window -t "=$L5_ALIVE_SESSION" -n agent 2>/dev/null
sleep 2   # let the fresh window's shell settle before send-keys
tmux send-keys -t "=$L5_ALIVE_SESSION:agent" "PATH=\"$CLAUDE_STUB_DIR:\$PATH\" claude 300" Enter
sleep 2   # give tmux a beat to report the updated pane_current_command

L5_TASK="$TASKS_DIR/proj--l5-alive.md"
printf -- '---\nstatus: doing\nrepo: proj\nbranch: l5-alive\nworktree: .worktrees/l5-alive\ntags: []\ncreated: 2026-07-07\nclosed:\n---\n# Title\n' \
  > "$L5_TASK"

l5_holder="$(spawn_holder "$L5_TASK" 3 "$L5_ALIVE_SESSION")"
_wait_for_holder "$L5_TASK" "$l5_holder"
l5_err="$(wb_task_lock_acquire_guarded "$L5_TASK" 2>&1 1>/dev/null)"
l5_rc=$?
assert_eq "L5 alive holder session: exit 75, never force-broken" 75 "$l5_rc"
l5_contend_count="$(grep -oc 'contended on' <<< "$l5_err")"
assert_eq "L5 alive holder session: exactly ONE contention message (no retry attempted at all)" 1 "$l5_contend_count"
[ -s "$L5_TASK" ] && ! grep -q '^status: done$' "$L5_TASK" \
  && echo "ok   - L5 alive holder session: task file untouched" \
  || { echo "FAIL - L5 alive holder session: task file unexpectedly modified"; fail=1; }
wait "$l5_holder" 2>/dev/null

# =============================================================================
[ "$fail" -eq 0 ] && echo "ALL PASS" || echo "FAILURES"
exit "$fail"
