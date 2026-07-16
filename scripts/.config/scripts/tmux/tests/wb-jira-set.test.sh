#!/usr/bin/env bash
# Tests for `wb jira-set` (U1 of the Jira-ticket-interop plan,
# docs/plans/2026-07-16-001-feat-jira-ticket-interop-plan.md) — the locked
# `jira:` write-back verb the /wb-jira-create skill's emit flow calls once
# per created ticket. Modeled on cmd_reviewed's single-field locked write
# (wb.sh), so these mirror wb-pause.test.sh's plain-bash-against-a-fixture
# convention and wb-lock-integration.test.sh's real-background-holder
# contention shape.
#
# jira-set takes an EXACT `<repo>--<slug>` stem plus a URL (never a tmux
# session, never the fuzzy matcher), so — unlike wb-pause — no tmux state
# is needed at all; every scenario is a pure task-file + lock-file exercise.
#
# Run: bash scripts/.config/scripts/tmux/tests/wb-jira-set.test.sh
set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WB="$SELF_DIR/wb.sh"
WB_LOCKS="$SELF_DIR/wb-locks.sh"
export WB_LOCKS

FIXTURE="$(mktemp -d -t wb-jira-set-fixture.XXXXXX)"
HOLDER_PIDS=()
cleanup() {
  for pid in "${HOLDER_PIDS[@]:-}"; do
    [ -n "$pid" ] && kill "$pid" 2>/dev/null
  done
  for pid in "${HOLDER_PIDS[@]:-}"; do
    [ -n "$pid" ] && wait "$pid" 2>/dev/null
  done
  rm -rf "$FIXTURE"
}
trap cleanup EXIT

# Isolate EVERYTHING this test can write under the fixture BEFORE sourcing
# wb.sh — task store, code dir, lock-file state, and $HOME — the
# 2026-07-10-incident convention (see wb-lock-integration.test.sh): a
# variable-name collision or a runaway write can then only reach a
# throwaway filesystem, never the real ~/code/tasks or ~/.local/state.
export TASKS_DIR="$FIXTURE/tasks"
export CODE_DIR="$FIXTURE/code"
export XDG_STATE_HOME="$FIXTURE/state"
export HOME="$FIXTURE/home"
mkdir -p "$TASKS_DIR" "$CODE_DIR" "$XDG_STATE_HOME" "$HOME"

# shellcheck disable=SC1090
source "$WB"
set +e   # wb.sh sets -e; this test intentionally captures non-zero exits

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
assert_eq() { # <desc> <expected> <actual>
  if [ "$2" = "$3" ]; then
    echo "ok   - $1"
  else
    echo "FAIL - $1 (expected '$2', got '$3')"
    fail=1
  fi
}

# mk_task <stem> [<jira-value>] — a minimal doing task file. When the second
# arg is given, a `jira:` line is written into the frontmatter; when omitted,
# NO `jira:` line exists at all (exercises wb_set_frontmatter's insert
# branch, mirroring a task file that predates the field being in the schema).
mk_task() {
  local stem="$1" jira="${2-__none__}" f="$TASKS_DIR/$1.md"
  {
    printf -- '---\nstatus: doing\nrepo: proj\nbranch: %s\nworktree: .worktrees/%s\n' "$stem" "$stem"
    [ "$jira" = "__none__" ] || printf 'jira: %s\n' "$jira"
    printf 'tags: []\ncreated: 2026-07-16\nclosed:\n---\n# Title for %s\n' "$stem"
  } > "$f"
}

URL='https://sportable.atlassian.net/browse/SFB-1234'
OTHER_URL='https://sportable.atlassian.net/browse/SFB-9999'

# =============================================================================
# Happy path — task with an empty `jira:` -> the verb writes the URL, the
# frontmatter reads back the exact string, exit 0, message names the task.
# =============================================================================
mk_task 'proj--feat-happy' ''
out="$(cmd_jira_set 'proj--feat-happy' "$URL" 2>&1)"; rc=$?
assert_eq "happy: exit 0" 0 "$rc"
assert_eq "happy: jira: reads back the exact URL" "$URL" "$(wb_get_frontmatter "$TASKS_DIR/proj--feat-happy.md" jira)"
assert "happy: confirmation names the task" 'proj--feat-happy' "$out"
frontmatter_markers="$(grep -c '^---$' "$TASKS_DIR/proj--feat-happy.md")"
assert_eq "happy: exactly 2 frontmatter markers (no corruption)" 2 "$frontmatter_markers"

# =============================================================================
# Idempotent re-run — the SAME URL again is a no-op success (safe retry after
# a partial failure, KTD3): exit 0, field unchanged, no error, byte-identical.
# =============================================================================
before_idem="$(cat "$TASKS_DIR/proj--feat-happy.md")"
out_idem="$(cmd_jira_set 'proj--feat-happy' "$URL" 2>&1)"; rc_idem=$?
assert_eq "idempotent: exit 0" 0 "$rc_idem"
assert_eq "idempotent: file byte-identical (no rewrite)" "$before_idem" "$(cat "$TASKS_DIR/proj--feat-happy.md")"

# =============================================================================
# Refuse-clobber — a DIFFERENT existing `jira:` must fail loud, name the
# existing value, and write nothing (KTD3 — the R11-skip safety net). Covers
# the double-emit-bug-fails-safe guarantee.
# =============================================================================
mk_task 'proj--feat-clobber' "$URL"
before_clobber="$(cat "$TASKS_DIR/proj--feat-clobber.md")"
err_clobber="$(cmd_jira_set 'proj--feat-clobber' "$OTHER_URL" 2>&1 1>/dev/null)"; rc_clobber=$?
assert "refuse-clobber: non-zero exit" '^[1-9]' "$rc_clobber-x"
[ "$rc_clobber" -ne 0 ] || { echo "FAIL - refuse-clobber: expected non-zero exit, got $rc_clobber"; fail=1; }
assert "refuse-clobber: error names the existing value" 'SFB-1234' "$err_clobber"
assert_eq "refuse-clobber: file left byte-identical" "$before_clobber" "$(cat "$TASKS_DIR/proj--feat-clobber.md")"

# =============================================================================
# Missing stem — a `<repo>--<slug>` with no file fails loud and touches zero
# files.
# =============================================================================
err_missing="$(cmd_jira_set 'proj--does-not-exist' "$URL" 2>&1 1>/dev/null)"; rc_missing=$?
[ "$rc_missing" -ne 0 ] && echo "ok   - missing stem: non-zero exit" || { echo "FAIL - missing stem: expected non-zero exit"; fail=1; }
assert "missing stem: error says no matching task file" 'no matching task file' "$err_missing"
[ ! -e "$TASKS_DIR/proj--does-not-exist.md" ] && echo "ok   - missing stem: no file created" || { echo "FAIL - missing stem: a file was created"; fail=1; }

# =============================================================================
# Empty / absent URL argument — a usage error, non-zero, no write.
# =============================================================================
mk_task 'proj--feat-nourl' ''
err_empty_url="$(cmd_jira_set 'proj--feat-nourl' '' 2>&1 1>/dev/null)"; rc_empty_url=$?
[ "$rc_empty_url" -ne 0 ] && echo "ok   - empty URL: non-zero exit" || { echo "FAIL - empty URL: expected non-zero exit"; fail=1; }
assert "empty URL: usage error" 'usage' "$err_empty_url"
assert_eq "empty URL: jira: not written" "" "$(wb_get_frontmatter "$TASKS_DIR/proj--feat-nourl.md" jira)"

err_absent_url="$(cmd_jira_set 'proj--feat-nourl' 2>&1 1>/dev/null)"; rc_absent_url=$?
[ "$rc_absent_url" -ne 0 ] && echo "ok   - absent URL arg: non-zero exit" || { echo "FAIL - absent URL arg: expected non-zero exit"; fail=1; }
assert "absent URL arg: usage error" 'usage' "$err_absent_url"

# =============================================================================
# Field-insert — a task file predating the `jira:` key (NO `jira:` line at
# all) has the field inserted before the closing `---` (exercises
# wb_set_frontmatter's insert branch).
# =============================================================================
mk_task 'proj--feat-insert'   # no jira arg -> no jira: line
grep -q '^jira:' "$TASKS_DIR/proj--feat-insert.md" && { echo "FAIL - field-insert precondition: fixture already has a jira: line"; fail=1; } || echo "ok   - field-insert precondition: fixture has no jira: line"
out_insert="$(cmd_jira_set 'proj--feat-insert' "$URL" 2>&1)"; rc_insert=$?
assert_eq "field-insert: exit 0" 0 "$rc_insert"
assert_eq "field-insert: jira: now present with the URL" "$URL" "$(wb_get_frontmatter "$TASKS_DIR/proj--feat-insert.md" jira)"
insert_markers="$(grep -c '^---$' "$TASKS_DIR/proj--feat-insert.md")"
assert_eq "field-insert: still exactly 2 frontmatter markers" 2 "$insert_markers"
# the inserted line must be INSIDE the frontmatter (before the 2nd ---), not
# appended after the body
jira_line_no="$(grep -n '^jira:' "$TASKS_DIR/proj--feat-insert.md" | head -1 | cut -d: -f1)"
second_marker_no="$(grep -n '^---$' "$TASKS_DIR/proj--feat-insert.md" | sed -n '2p' | cut -d: -f1)"
[ -n "$jira_line_no" ] && [ -n "$second_marker_no" ] && [ "$jira_line_no" -lt "$second_marker_no" ] \
  && echo "ok   - field-insert: jira: line sits inside the frontmatter block" \
  || { echo "FAIL - field-insert: jira: line not inside the frontmatter block (jira@$jira_line_no, close@$second_marker_no)"; fail=1; }

# =============================================================================
# Lock contention — a live holder owns the per-task lock -> the verb refuses
# per wb_task_lock_acquire_guarded (exit 75) and writes nothing. Uses a real
# background holder process (wb-lock-integration.test.sh's shape), recording
# an EMPTY tmux_session so the guarded wrapper's orphan-check bails on the
# first (tmux_session-empty) condition and never retries — deterministic
# bare, no /proc cmdline shaping or tmux socket needed.
# =============================================================================
HOLDER_LOG="$FIXTURE/holder-output.log"
export HOLDER_LOG
HOLDER_SCRIPT="$FIXTURE/lock-holder-wb.sh"   # "wb.sh" in the name: harmless here, matches the sibling suite
cat > "$HOLDER_SCRIPT" <<'EOF'
#!/usr/bin/env bash
# Redirect first (see wb-lock-integration.test.sh): keeps the backgrounded
# holder from being torn down early through an inherited pipe.
exec >>"$HOLDER_LOG" 2>&1
source "$WB_LOCKS"
task_file="$1"; hold_secs="${2:-10}"
wb_task_lock_acquire "$task_file" || exit 1
sleep "$hold_secs"
EOF
chmod +x "$HOLDER_SCRIPT"

# _wait_for_holder <task_file> <pid> [<timeout_s>] — poll the side-car lock
# file until it records <pid> as holder (never a blind sleep — the holder
# spends variable time forking/sourcing before it actually acquires).
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

mk_task 'proj--feat-contend' ''
CONTEND_TASK="$TASKS_DIR/proj--feat-contend.md"
before_contend="$(cat "$CONTEND_TASK")"
# NB: launched WITHOUT TMUX in the environment, so the holder records an
# empty tmux_session — exactly the orphan-check-bails condition above.
( exec env -u TMUX -u TMUX_PANE bash "$HOLDER_SCRIPT" "$CONTEND_TASK" 10 ) &
contend_holder=$!
HOLDER_PIDS+=("$contend_holder")
if _wait_for_holder "$CONTEND_TASK" "$contend_holder"; then
  contend_out="$(cmd_jira_set 'proj--feat-contend' "$URL" 2>&1)"; rc_contend=$?
  assert_eq "lock contention: exit 75 (refused, per wb_task_lock_acquire_guarded)" 75 "$rc_contend"
  assert "lock contention: reports the contention" 'contended on' "$contend_out"
  assert_eq "lock contention: jira: NOT written (field unchanged)" "" "$(wb_get_frontmatter "$CONTEND_TASK" jira)"
  assert_eq "lock contention: file left byte-identical" "$before_contend" "$(cat "$CONTEND_TASK")"
else
  echo "FAIL - lock contention: background holder never acquired the lock (setup failure)"
  fail=1
fi
kill "$contend_holder" 2>/dev/null
wait "$contend_holder" 2>/dev/null

# =============================================================================
# U4 — /wb-jira-create skill: write-boundary + create-only grep check
# =============================================================================
# The one mechanically enforceable invariant for the agent-driven skill
# halves (U2/U3), same precedent wb-breakdown.test.sh's U6 established: a
# grep-based smoke check (not exhaustive NLP) that this skill (a) never
# instructs an Edit/Write-tool write against ~/code/tasks, (b) routes its
# ONE store write through `wb jira-set`, (c) states the never-Edit/Write-tool
# rule, (d) states its create-only posture, and (e) names no ticket-mutation
# MCP tool (transition/edit/worklog/delete) — so Jira access stays
# create-only (R12).

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../../.." && pwd)"
SKILL_FILE="$REPO_ROOT/claude/.claude/skills/wb-jira-create/SKILL.md"

if [ ! -f "$SKILL_FILE" ]; then
  echo "FAIL - U4 skill grep check: $SKILL_FILE not found"
  fail=1
else
  if grep -niE 'use read then edit|(edit|write) tool.*(task file|~/code/tasks)|write .?~/code/tasks/[^ ]*\.md' "$SKILL_FILE" >/dev/null; then
    echo "FAIL - U4 skill grep check: wb-jira-create/SKILL.md contains an Edit/Write-tool task-file write instruction:"
    grep -niE 'use read then edit|(edit|write) tool.*(task file|~/code/tasks)|write .?~/code/tasks/[^ ]*\.md' "$SKILL_FILE" | sed 's/^/       /'
    fail=1
  else
    echo "ok   - U4 skill grep check: no Edit/Write-tool task-file write instruction"
  fi

  if grep -qE 'wb jira-set' "$SKILL_FILE"; then
    echo "ok   - U4 skill grep check: routes its store write through wb jira-set"
  else
    echo "FAIL - U4 skill grep check: does not reference wb jira-set"
    fail=1
  fi

  if grep -Pzoqi '(?s)never[^.]{0,200}?(edit|write)[\s/-]*tool' "$SKILL_FILE"; then
    echo "ok   - U4 skill grep check: states the never-Edit/Write-tool rule"
  else
    echo "FAIL - U4 skill grep check: missing the never-Edit/Write-tool rule"
    fail=1
  fi

  if grep -qiE 'create-only' "$SKILL_FILE"; then
    echo "ok   - U4 skill grep check: states the create-only posture (R12)"
  else
    echo "FAIL - U4 skill grep check: missing the create-only posture statement"
    fail=1
  fi

  # No ticket-mutation MCP tool named as an action — create-only means the
  # skill's Jira writes are createJiraIssue/createIssueLink only.
  if grep -niE 'transitionJiraIssue|editJiraIssue|addWorklogToJiraIssue|deleteJiraIssue' "$SKILL_FILE" >/dev/null; then
    echo "FAIL - U4 skill grep check: names a ticket-mutation MCP tool (not create-only):"
    grep -niE 'transitionJiraIssue|editJiraIssue|addWorklogToJiraIssue|deleteJiraIssue' "$SKILL_FILE" | sed 's/^/       /'
    fail=1
  else
    echo "ok   - U4 skill grep check: names no ticket-mutation MCP tool (create-only)"
  fi
fi

[ "$fail" -eq 0 ] && echo "ALL PASS" || echo "FAILURES"
exit "$fail"
