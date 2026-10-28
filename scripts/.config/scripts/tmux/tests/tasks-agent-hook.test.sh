#!/usr/bin/env bash
# Tests for pretooluse-guard.sh (U5, tasks-dir concurrency-safety) — the
# Claude Code PreToolUse hook that asks the operator before a dangerous git
# command runs scoped at ~/code/tasks, or before an Edit/Write/MultiEdit
# lands on a task another live session is working on.
#
# Plain-bash assertions against synthetic PreToolUse JSON payloads fed on
# stdin, same convention as wb-schema.test.sh. No git fixtures; live tmux
# sessions come from a PATH-shimmed fake tmux that never contacts a real
# server. Runs fine on the host (needs jq, flock) or inside the
# Dockerfile'd sandbox.
#
# Run: bash scripts/.config/scripts/tmux/tests/tasks-agent-hook.test.sh
set -uo pipefail

GUARD="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/tasks-git-hooks/pretooluse-guard.sh"

FIXTURE_HOME="$(mktemp -d -t wb-guard-home.XXXXXX)"
FIXTURE_TASKS="$FIXTURE_HOME/code/tasks"
SENTINEL="$FIXTURE_TASKS/.git/WB_ALLOW_REWIND"
KILL_SWITCH="$FIXTURE_HOME/.local/state/wb/disable-agent-hook"
NOJQ_BIN="$(mktemp -d -t wb-guard-nojq-bin.XXXXXX)"
MARKER="$FIXTURE_HOME/marker"

mkdir -p "$FIXTURE_TASKS/.git" "$FIXTURE_HOME/.local/state/wb"

# A PATH containing every external command the script needs EXCEPT jq, to
# exercise H8's "jq missing from PATH" fail-open branch.
for b in cat grep sed head date; do
  real="$(command -v "$b")"
  ln -s "$real" "$NOJQ_BIN/$b"
done
REAL_BASH="$(command -v bash)"

# Fake tmux, first on PATH for every run_guard call, so no test ever reaches
# a real tmux server (2026-10-25 kill-server incident). It only prints canned
# answers from $TMUX_STUB_DIR: `sessions` (one "<name>\t<@task>" line per
# live session) for list-sessions, `own_session` for display -p '#S'. A
# `fail` file makes every call exit 1; every call touches `called`.
STUB_BIN="$(mktemp -d -t wb-guard-stub-bin.XXXXXX)"
TMUX_STUB_DIR="$FIXTURE_HOME/tmux-stub"
mkdir -p "$TMUX_STUB_DIR"
cat > "$STUB_BIN/tmux" <<'STUB'
#!/usr/bin/env bash
d="${TMUX_STUB_DIR:?}"
: > "$d/called"
[ -e "$d/fail" ] && { echo "tmux stub: forced failure" >&2; exit 1; }
case "${1:-}" in
  list-sessions) [ -f "$d/sessions" ] && cat "$d/sessions"; exit 0 ;;
  display) [ -f "$d/own_session" ] && cat "$d/own_session"; exit 0 ;;
esac
exit 0
STUB
chmod +x "$STUB_BIN/tmux"

# set_sessions ["<name> <task-basename>"...] — the stub's live sessions.
set_sessions() {
  local s
  : > "$TMUX_STUB_DIR/sessions"
  for s in "$@"; do
    printf '%s\t%s\n' "${s%% *}" "$FIXTURE_TASKS/${s#* }" >> "$TMUX_STUB_DIR/sessions"
  done
}
reset_stub() {
  rm -f "$TMUX_STUB_DIR"/{sessions,fail,called}
  printf 'me\n' > "$TMUX_STUB_DIR/own_session"
}
reset_stub

LOCK_DIR="$FIXTURE_HOME/.local/state/wb/locks"
mkdir -p "$LOCK_DIR"

trap 'rm -rf "$FIXTURE_HOME" "$NOJQ_BIN" "$STUB_BIN"' EXIT

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
assert_empty() { # <desc> <actual>
  if [ -z "$2" ]; then
    echo "ok   - $1"
  else
    echo "FAIL - $1 (expected no output, got: $2)"
    fail=1
  fi
}
assert_eq() { # <desc> <expected> <actual>
  if [ "$2" = "$3" ]; then
    echo "ok   - $1"
  else
    echo "FAIL - $1 (expected [$2], got [$3])"
    fail=1
  fi
}

# run_guard JSON [EXTRA_ENV_ASSIGNMENTS...] — sets OUT / ERR / RC.
# XDG_STATE_HOME is pinned to the fixture home on every call so the
# kill-switch check never accidentally sees a real ambient path. The caller
# is always "inside tmux" on the stub (pane %1, session `me`) unless an
# extra assignment overrides TMUX/TMUX_PANE.
run_guard() {
  local json="$1"; shift
  local errfile
  errfile="$(mktemp -t wb-guard-err.XXXXXX)"
  OUT="$(printf '%s' "$json" | env HOME="$FIXTURE_HOME" XDG_STATE_HOME="$FIXTURE_HOME/.local/state" \
    PATH="$STUB_BIN:$PATH" TMUX_STUB_DIR="$TMUX_STUB_DIR" TMUX="/stub,1,0" TMUX_PANE="%1" \
    "$@" "$REAL_BASH" "$GUARD" 2>"$errfile")"
  RC=$?
  ERR="$(cat "$errfile")"
  rm -f "$errfile"
}

decision_of() { printf '%s' "$1" | jq -r '.hookSpecificOutput.permissionDecision // empty' 2>/dev/null; }

# ============================================================================
# H3/H4/H5: git reset --hard, cwd inside ~/code/tasks -> ask, with all three
# required message elements (matched command, incident precedent, safe alts).
# ============================================================================
run_guard "{\"cwd\":\"$FIXTURE_TASKS\",\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"git reset --hard\"}}"
assert_eq "reset --hard scoped: exit 0" "0" "$RC"
assert "reset --hard scoped: permissionDecision ask" '"permissionDecision": *"ask"' "$OUT"
assert "reset --hard scoped: names the matched command" 'git reset --hard' "$OUT"
assert "reset --hard scoped: names past incidents" 'past incidents' "$OUT"
assert "reset --hard scoped: names the ff-only pull" 'pull --ff-only' "$OUT"
assert "reset --hard scoped: names wb unsafe-rewind" 'wb unsafe-rewind' "$OUT"
assert "reset --hard scoped: notes git-side hook still has a say" 'git-side' "$OUT"

# ============================================================================
# Same command, cwd elsewhere -> exit 0, no output.
# ============================================================================
run_guard "{\"cwd\":\"/tmp/some-other-repo\",\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"git reset --hard\"}}"
assert_eq "reset --hard elsewhere: exit 0" "0" "$RC"
assert_empty "reset --hard elsewhere: no stdout" "$OUT"

# ============================================================================
# `git -C ~/code/tasks reset --hard` from a DIFFERENT cwd -> ask (-C resolution)
# ============================================================================
run_guard "{\"cwd\":\"/tmp/elsewhere\",\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"git -C $FIXTURE_TASKS reset --hard\"}}"
assert_eq "git -C tasks reset --hard: exit 0" "0" "$RC"
assert_eq "git -C tasks reset --hard: ask" "ask" "$(decision_of "$OUT")"

# ============================================================================
# `cd ~/code/tasks && git reset --hard` -> ask (cd && prefix resolution)
# ============================================================================
run_guard "{\"cwd\":\"/tmp/elsewhere\",\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"cd $FIXTURE_TASKS && git reset --hard\"}}"
assert_eq "cd && reset --hard: exit 0" "0" "$RC"
assert_eq "cd && reset --hard: ask" "ask" "$(decision_of "$OUT")"

# ============================================================================
# Compound command, only the SECOND git invocation is scoped -> ask
# (H4's any-invocation-matches rule).
# ============================================================================
run_guard "{\"cwd\":\"/tmp/elsewhere\",\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"git -C /some/other/repo status && git -C $FIXTURE_TASKS reset --hard\"}}"
assert_eq "compound only-2nd-scoped: exit 0" "0" "$RC"
assert_eq "compound only-2nd-scoped: ask" "ask" "$(decision_of "$OUT")"

# ============================================================================
# Non-matching commands -> exit 0, NO directory-resolution work at all.
# Proven via GUARD_TEST_MARKER_FILE, which the script only touches once it
# is actually inside the per-invocation resolution codepath (H4). Uses a cwd
# INSIDE the tasks dir specifically, to prove the marker isn't touched just
# because "code/tasks" text happens to appear somewhere in the payload — the
# cheap check (H2) must be driven by the command string alone, not by cwd.
# ============================================================================
rm -f "$MARKER"
run_guard "{\"cwd\":\"$FIXTURE_TASKS\",\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"git commit -m foo\"}}" "GUARD_TEST_MARKER_FILE=$MARKER"
assert_eq "git commit -m foo: exit 0" "0" "$RC"
assert_empty "git commit -m foo: no stdout" "$OUT"
if [ -f "$MARKER" ]; then
  echo "FAIL - git commit -m foo: directory-resolution codepath was reached"; fail=1
else
  echo "ok   - git commit -m foo: directory-resolution codepath NOT reached"
fi

rm -f "$MARKER"
run_guard "{\"cwd\":\"$FIXTURE_TASKS\",\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"ls -la\"}}" "GUARD_TEST_MARKER_FILE=$MARKER"
assert_eq "ls -la: exit 0" "0" "$RC"
assert_empty "ls -la: no stdout" "$OUT"
if [ -f "$MARKER" ]; then
  echo "FAIL - ls -la: directory-resolution codepath was reached"; fail=1
else
  echo "ok   - ls -la: directory-resolution codepath NOT reached"
fi

# Sanity check on the marker instrumentation itself: a MATCHING command must
# still reach the resolution codepath, or the two assertions above would be
# vacuously true (marker never firing for anything).
rm -f "$MARKER"
run_guard "{\"cwd\":\"$FIXTURE_TASKS\",\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"git reset --hard\"}}" "GUARD_TEST_MARKER_FILE=$MARKER"
if [ -f "$MARKER" ]; then
  echo "ok   - marker sanity: matching command DOES reach the resolution codepath"
else
  echo "FAIL - marker sanity: matching command never touched the marker (instrumentation broken)"; fail=1
fi
rm -f "$MARKER"

# ============================================================================
# H6: fresh, unconsumed sentinel + a matched+scoped command -> allow.
# ============================================================================
printf '%s test-reason\n' "$(date +%s)" > "$SENTINEL"
run_guard "{\"cwd\":\"$FIXTURE_TASKS\",\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"git reset --hard\"}}"
assert_eq "fresh sentinel + matched: exit 0" "0" "$RC"
assert_eq "fresh sentinel + matched: allow" "allow" "$(decision_of "$OUT")"
[ -f "$SENTINEL" ] && echo "ok   - fresh sentinel: NOT consumed by this layer" \
  || { echo "FAIL - fresh sentinel: was deleted (only the git-side hook may consume it)"; fail=1; }

# --- H6 critical ordering regression: fresh sentinel + an UNMATCHED command
# -> exit 0 (NOT allow). If pattern/scope matching ran AFTER the sentinel
# check instead of before, this would wrongly return "allow" for an
# innocuous command — a 120s "allow literally everything" token.
run_guard "{\"cwd\":\"$FIXTURE_TASKS\",\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"git status\"}}"
assert_eq "fresh sentinel + unmatched: exit 0" "0" "$RC"
assert_empty "fresh sentinel + unmatched: NOT allow, no stdout" "$OUT"
rm -f "$SENTINEL"

# ============================================================================
# H8: jq absent from PATH -> exit 0 plus EXACTLY ONE stderr line.
# ============================================================================
run_guard "{\"cwd\":\"$FIXTURE_TASKS\",\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"git reset --hard\"}}" "PATH=$NOJQ_BIN"
assert_eq "jq absent: exit 0" "0" "$RC"
assert_empty "jq absent: no stdout (no decision, fails open)" "$OUT"
err_lines="$(printf '%s\n' "$ERR" | grep -c '.')"
assert_eq "jq absent: exactly one stderr line" "1" "$err_lines"

# ============================================================================
# X4: kill-switch file present -> exit 0 before anything else, even for an
# otherwise-matching command.
# ============================================================================
touch "$KILL_SWITCH"
run_guard "{\"cwd\":\"$FIXTURE_TASKS\",\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"git reset --hard\"}}"
assert_eq "kill-switch present: exit 0" "0" "$RC"
assert_empty "kill-switch present: no stdout" "$OUT"
rm -f "$KILL_SWITCH"

# ============================================================================
# H3 recovery-net shapes: reflog expire / gc --prune, scoped -> ask.
# ============================================================================
run_guard "{\"cwd\":\"$FIXTURE_TASKS\",\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"git reflog expire --expire=now --all\"}}"
assert_eq "reflog expire scoped: ask" "ask" "$(decision_of "$OUT")"

run_guard "{\"cwd\":\"$FIXTURE_TASKS\",\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"git gc --prune=now\"}}"
assert_eq "gc --prune scoped: ask" "ask" "$(decision_of "$OUT")"

# ============================================================================
# H24: Edit/Write/MultiEdit — ask only when another live session owns the
# target's task, or that task's wb lock is held right now. The owning task
# is the top-level task file itself, or dossiers/<task>/… for its dossier.
# ============================================================================
edit_json() { # <tool> <file_path>
  printf '{"cwd":"%s","tool_name":"%s","tool_input":{"file_path":"%s"}}' "$FIXTURE_HOME" "$1" "$2"
}

# hold_lock <task-basename> <holder-tmux-session> — hold that task's wb
# side-car lock from this test shell (no background process), with holder
# info written the way wb_task_lock_acquire writes it. The guard inherits
# the fd but probes through a fresh open, so it still sees the lock held.
hold_lock() {
  local lockfile="$LOCK_DIR/$1.lock"
  printf 'holder: %s\npid: %s\nacquired: %s\ntmux_pane: %%9\ntmux_session: %s\n' \
    "${1%.md}" "$$" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$2" > "$lockfile"
  exec {LOCK_FD}<>"$lockfile"
  flock -n "$LOCK_FD" || { echo "FAIL - hold_lock: could not take $lockfile"; fail=1; }
}
release_lock() { exec {LOCK_FD}<&-; }

reset_stub
run_guard "$(edit_json Edit "$FIXTURE_TASKS/foo.md")"
assert_eq "Edit own task, no live sessions: exit 0" "0" "$RC"
assert_empty "Edit own task, no live sessions: no stdout" "$OUT"

set_sessions "me foo.md"
run_guard "$(edit_json Edit "$FIXTURE_TASKS/foo.md")"
assert_empty "Edit task owned by the caller's own session: no stdout" "$OUT"

set_sessions "me bar.md" "other foo.md"
run_guard "$(edit_json Edit "$FIXTURE_TASKS/foo.md")"
assert_eq "Edit task owned by another session: exit 0" "0" "$RC"
assert_eq "Edit task owned by another session: ask" "ask" "$(decision_of "$OUT")"
assert "Edit task owned by another session: names it" "session 'other'" "$OUT"

set_sessions "other foo.md"
run_guard "$(edit_json Write "$FIXTURE_TASKS/dossiers/foo/page.html")"
assert_eq "Write to a dossier of another session's task: ask" "ask" "$(decision_of "$OUT")"
assert "Write to a dossier of another session's task: names it" "session 'other'" "$OUT"

set_sessions "other bar.md"
run_guard "$(edit_json MultiEdit "$FIXTURE_TASKS/dossiers/foo/page.html")"
assert_empty "MultiEdit to a dossier no other session owns: no stdout" "$OUT"

set_sessions "other foo.md"
for shared in README.md weeks/x.md context/y.md; do
  run_guard "$(edit_json Edit "$FIXTURE_TASKS/$shared")"
  assert_empty "Edit shared file $shared: no stdout" "$OUT"
done

set_sessions "other foo.md"
run_guard "$(edit_json Edit "$FIXTURE_TASKS/foo.md")" "TMUX=" "TMUX_PANE="
assert_eq "Edit outside tmux, another session owns the task: ask" "ask" "$(decision_of "$OUT")"
assert "Edit outside tmux, another session owns the task: names it" "session 'other'" "$OUT"

reset_stub
hold_lock foo.md other
run_guard "$(edit_json Edit "$FIXTURE_TASKS/foo.md")"
release_lock
assert_eq "Edit while another session's wb command holds the lock: ask" "ask" "$(decision_of "$OUT")"
assert "Edit while another session's wb command holds the lock: names it" "session 'other'" "$OUT"

hold_lock foo.md me
run_guard "$(edit_json Edit "$FIXTURE_TASKS/foo.md")"
release_lock
assert_empty "Edit while the caller's own session holds the lock: no stdout" "$OUT"

run_guard "$(edit_json Edit "$FIXTURE_TASKS/foo.md")"
assert_empty "Edit with the lock file present but not held: no stdout" "$OUT"
rm -f "$LOCK_DIR/foo.md.lock"

set_sessions "other foo.md"
touch "$TMUX_STUB_DIR/fail"
run_guard "$(edit_json Edit "$FIXTURE_TASKS/foo.md")"
assert_eq "tmux query fails: exit 0" "0" "$RC"
assert_empty "tmux query fails: no stdout" "$OUT"
assert_eq "tmux query fails: exactly one stderr line" "1" "$(printf '%s\n' "$ERR" | grep -c '.')"
reset_stub

set_sessions "other foo.md"
run_guard "$(edit_json Edit "$FIXTURE_TASKS/foo.md")"
if printf '%s' "$OUT" | grep -q 'wb append'; then
  echo "FAIL - ask reason still tells the agent to use wb append"; fail=1
else
  echo "ok   - ask reason no longer mentions wb append"
fi

run_guard "$(edit_json Edit "$FIXTURE_HOME/code/other-repo/foo.md")"
assert_eq "Edit outside tasks: exit 0" "0" "$RC"
assert_empty "Edit outside tasks: no stdout" "$OUT"

run_guard "$(edit_json Write "$FIXTURE_HOME/code/other-repo/bar.md")"
assert_empty "Write outside tasks: no stdout" "$OUT"

run_guard "$(edit_json MultiEdit "$FIXTURE_HOME/code/other-repo/baz.md")"
assert_empty "MultiEdit outside tasks: no stdout" "$OUT"

# ============================================================================
# H24 shares the kill-switch too, even under contention.
# ============================================================================
touch "$KILL_SWITCH"
run_guard "$(edit_json Edit "$FIXTURE_TASKS/foo.md")"
assert_eq "Edit + kill-switch: exit 0" "0" "$RC"
assert_empty "Edit + kill-switch: no stdout" "$OUT"
rm -f "$KILL_SWITCH"
reset_stub

# ============================================================================
# H5: NEVER "deny", anywhere. Checked at the call-site level (not a raw
# grep for the word "deny", which also appears legitimately in the script's
# own comments documenting the hook contract) — no `emit_decision` call, the
# only place a decision is ever produced, may pass "deny".
# ============================================================================
if grep -E '^[^#]*emit_decision[[:space:]]+"deny"' "$GUARD" | grep -qv '^\s*#'; then
  echo "FAIL - guard script has an emit_decision \"deny\" call site"; fail=1
else
  echo "ok   - guard script never calls emit_decision with \"deny\""
fi

[ "$fail" -eq 0 ] && echo "ALL PASS" || echo "FAILURES"
exit "$fail"
