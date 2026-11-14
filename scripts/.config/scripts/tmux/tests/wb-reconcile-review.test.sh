#!/usr/bin/env bash
# Tests for `wb reconcile --review`/`--apply` (U7) — plain-bash assertions,
# same convention as wb-reconcile.test.sh. Sources wb.sh (safe: see the
# BASH_SOURCE guard at the bottom of wb.sh), stubs wb_reconcile_repos to
# point at real fixture git repos, stubs wb_reconcile_report_path to a
# fixture path (never touches the real logs/reconcile.md), and injects a
# fake `gh` via PATH so no live network call ever happens. Each section
# gets a FRESH TASKS_DIR/CODE_DIR — cmd_reconcile --apply mutates task
# files and worktrees, so sharing state across sections (an earlier
# section's task file suddenly gaining a worktree: field, say) produces
# findings that have nothing to do with the section actually being tested.
# Run: bash scripts/.config/scripts/tmux/tests/wb-reconcile-review.test.sh
set -uo pipefail

WB="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/wb.sh"
REPORT="$(mktemp -u -t wb-rr-report.XXXXXX.md)"
FIXTURE_BIN="$(mktemp -d -t wb-rr-bin.XXXXXX)"
ALL_TMP=("$FIXTURE_BIN")
trap 'rm -rf "${ALL_TMP[@]}" "$REPORT"' EXIT

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

cat > "$FIXTURE_BIN/gh" <<'EOF'
#!/usr/bin/env bash
echo '[]'
EOF
chmod +x "$FIXTURE_BIN/gh"
PATH="$FIXTURE_BIN:$PATH"

mk_repo() { git init -q "$1"; git -C "$1" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init; }
add_worktree() { git -C "$1" worktree add -q -b "$2" ".worktrees/$2" >/dev/null 2>&1; }

# check_line_for <report> <marker_pattern> <line_pattern> <replacement> —
# replaces the first line matching <line_pattern> within the block whose
# `<!-- wb-reconcile: ... -->` marker matches <marker_pattern>. A blank line
# separates the marker from its own checkboxes in the generated report, so
# `awk -v RS=''`'s paragraph mode can't span both in one match — this scans
# line-by-line with an explicit "am I in the target block" flag instead,
# which isn't fooled by blank lines within the block.
check_line_for() {
  local report="$1" marker="$2" find="$3" repl="$4"
  # ENVIRON, not -v: awk -v runs escape processing on the value, which
  # mangles the `\[` in these regexes (and differs between mawk and gawk).
  CL_MARKER="$marker" CL_FIND="$find" CL_REPL="$repl" awk '
    /<!-- wb-reconcile:/ { in_target = ($0 ~ ENVIRON["CL_MARKER"]) }
    in_target && $0 ~ ENVIRON["CL_FIND"] { $0 = ENVIRON["CL_REPL"] }
    { print }
  ' "$report" > "$report.tmp" && mv "$report.tmp" "$report"
}

# mk_task <tasks_dir> <file> <status> <repo> <branch> <worktree> <title>
mk_task() {
  local dir="$1" f="$1/$2"
  printf -- '---\nstatus: %s\nrepo: %s\nbranch: %s\nworktree: %s\ntags: []\ncreated: 2026-07-08\nclosed:\n---\n# %s\n\n## Plan\n\nOriginal plan.\n\n## Done\n\n## Follow-ups\n\n' \
    "$3" "$4" "$5" "$6" "$7" > "$f"
}

mk_template() { # <tasks_dir> — wb_seed_task reads TEMPLATE.md, so any
  # fixture exercising "create a task" needs one present.
  printf -- '---\nstatus: planned\nrepo:\nbranch:\nworktree:\nparent:\ntags: []\ncreated:\nclosed:\n---\n# Title\n\n## Plan\n\n## Done\n\n## Follow-ups\n\n## Decisions\n' \
    > "$1/TEMPLATE.md"
}

# fresh_env — a new isolated TASKS_DIR + CODE_DIR pair, tracked for cleanup.
fresh_env() {
  TASKS_DIR="$(mktemp -d -t wb-rr-tasks.XXXXXX)"
  CODE_DIR="$(mktemp -d -t wb-rr-code.XXXXXX)"
  ALL_TMP+=("$TASKS_DIR" "$CODE_DIR")
  mk_template "$TASKS_DIR"
  rm -f "$REPORT"
}

# shellcheck disable=SC1090
source "$WB"
set +e   # wb.sh sets -e; this test captures non-zero exits by design
wb_open_buffer() { :; }   # no interactive nvim in a test run
wb_reconcile_report_path() { printf '%s' "$REPORT"; }

# =============================================================================
# --review: report generation
# =============================================================================
fresh_env
mk_repo "$CODE_DIR/proj"
add_worktree "$CODE_DIR/proj" orphan-a
wb_reconcile_repos() { printf '%s\n' "$CODE_DIR/proj"; }

out="$(cmd_reconcile --review 2>&1)"; rc=$?
assert "review: exits 0" '^' "$rc-ok"; [ "$rc" -eq 0 ] || { echo "FAIL - exit $rc: $out"; fail=1; }
assert "review: report written" "wrote $REPORT" "$out"
[ -f "$REPORT" ] && echo "ok   - report file exists" || { echo "FAIL - report file missing"; fail=1; }
assert "review: marker for orphan finding" 'kind=orphan repo=proj branch=orphan-a' "$(cat "$REPORT")"
assert "review: six actions present" 'do nothing' "$(cat "$REPORT")"
assert "review: merge action present" 'merge with task' "$(cat "$REPORT")"

out="$(cmd_reconcile --review 2>&1)"; rc=$?
assert "review: refuses to clobber unresolved report" 'unresolved findings' "$out"
[ "$rc" -ne 0 ] && echo "ok   - review: non-zero exit on refusal" || { echo "FAIL - review: exit $rc, expected refusal"; fail=1; }

# =============================================================================
# --apply: remove (orphan)
# =============================================================================
sed -i 's/^- \[ \] remove$/- [x] remove/' "$REPORT"
out="$(cmd_reconcile --apply 2>&1)"; rc=$?
assert "apply remove: exits 0" '^' "$rc-ok"; [ "$rc" -eq 0 ] || { echo "FAIL - exit $rc: $out"; fail=1; }
if [ -d "$CODE_DIR/proj/.worktrees/orphan-a" ]; then
  echo "FAIL - apply remove: worktree still exists"; fail=1
else
  echo "ok   - apply remove: worktree gone"
fi
if git -C "$CODE_DIR/proj" show-ref --verify --quiet refs/heads/orphan-a; then
  echo "FAIL - apply remove: branch still exists"; fail=1
else
  echo "ok   - apply remove: branch gone"
fi

# =============================================================================
# --apply: create a task (orphan)
# =============================================================================
fresh_env
mk_repo "$CODE_DIR/proj"
add_worktree "$CODE_DIR/proj" orphan-b
wb_reconcile_repos() { printf '%s\n' "$CODE_DIR/proj"; }
cmd_reconcile --review >/dev/null 2>&1
sed -i 's/^- \[ \] create a task (optional parent: `___`)$/- [x] create a task (optional parent: `___`)/' "$REPORT"
cmd_reconcile --apply >/dev/null 2>&1
new_task="$TASKS_DIR/proj--orphan-b.md"
if [ -f "$new_task" ]; then
  assert "apply create-task: status doing" 'status: doing' "$(cat "$new_task")"
  assert "apply create-task: dossier layout marker" 'layout: dossier' "$(cat "$new_task")"
  assert "apply create-task: ## Now points at the brief" 'read dossiers/proj--orphan-b/brief.md' "$(cat "$new_task")"
  [ -f "$TASKS_DIR/dossiers/proj--orphan-b/brief.md" ] \
    && echo "ok   - apply create-task: brief.md drafted" \
    || { echo "FAIL - apply create-task: no brief.md"; fail=1; }
else
  echo "FAIL - apply create-task: $new_task not created"; fail=1
fi

# --apply: create a task with an optional parent: annotation
fresh_env
mk_repo "$CODE_DIR/proj"
add_worktree "$CODE_DIR/proj" orphan-c
wb_reconcile_repos() { printf '%s\n' "$CODE_DIR/proj"; }
mk_task "$TASKS_DIR" "proj--parent-x.md" doing proj parent-x .worktrees/parent-x "Parent X"
cmd_reconcile --review >/dev/null 2>&1
sed -i 's/^- \[ \] create a task (optional parent: `___`)$/- [x] create a task (optional parent: `proj--parent-x`)/' "$REPORT"
cmd_reconcile --apply >/dev/null 2>&1
new_task="$TASKS_DIR/proj--orphan-c.md"
if [ -f "$new_task" ]; then
  assert "apply create-task with parent: parent: set" 'parent: proj--parent-x' "$(cat "$new_task")"
else
  echo "FAIL - apply create-task with parent: $new_task not created"; fail=1
fi

# --apply: create a task with a bogus parent: annotation — skips, no crash
fresh_env
mk_repo "$CODE_DIR/proj"
add_worktree "$CODE_DIR/proj" orphan-d
wb_reconcile_repos() { printf '%s\n' "$CODE_DIR/proj"; }
cmd_reconcile --review >/dev/null 2>&1
sed -i 's/^- \[ \] create a task (optional parent: `___`)$/- [x] create a task (optional parent: `proj--nonexistent`)/' "$REPORT"
out="$(cmd_reconcile --apply 2>&1)"; rc=$?
assert "apply create-task with bogus parent: exits 0 (skips, doesn't crash)" '^' "$rc-ok"; [ "$rc" -eq 0 ] || { echo "FAIL - exit $rc: $out"; fail=1; }
if [ -f "$TASKS_DIR/proj--orphan-d.md" ]; then
  echo "FAIL - apply create-task with bogus parent: task was created despite invalid parent"; fail=1
else
  echo "ok   - apply create-task with bogus parent: skipped, no task file created"
fi

# =============================================================================
# --apply: attach to task (orphan)
# =============================================================================
fresh_env
mk_repo "$CODE_DIR/proj"
add_worktree "$CODE_DIR/proj" orphan-c
mk_task "$TASKS_DIR" 'proj--existing.md' planned proj some-branch '' 'Existing Task'
wb_reconcile_repos() { printf '%s\n' "$CODE_DIR/proj"; }
cmd_reconcile --review >/dev/null 2>&1
sed -i 's/^- \[ \] attach to task: `___`$/- [x] attach to task: `proj--existing.md`/' "$REPORT"
cmd_reconcile --apply >/dev/null 2>&1
assert "apply attach: worktree field updated" 'worktree: \.worktrees/orphan-c' "$(cat "$TASKS_DIR/proj--existing.md")"

# --apply: merge with task on an orphan is attaching (worktree, not branch)
fresh_env
mk_repo "$CODE_DIR/proj"
add_worktree "$CODE_DIR/proj" orphan-m
mk_task "$TASKS_DIR" 'proj--existing.md' planned proj some-branch '' 'Existing Task'
wb_reconcile_repos() { printf '%s\n' "$CODE_DIR/proj"; }
cmd_reconcile --review >/dev/null 2>&1
sed -i 's/^- \[ \] merge with task: `___`$/- [x] merge with task: `proj--existing.md`/' "$REPORT"
cmd_reconcile --apply >/dev/null 2>&1
assert "apply orphan merge: attaches the worktree" 'worktree: \.worktrees/orphan-m' "$(cat "$TASKS_DIR/proj--existing.md")"
if grep -q '^worktree: orphan-m$' "$TASKS_DIR/proj--existing.md"; then
  echo "FAIL - apply orphan merge: the branch was written as the worktree"; fail=1
else
  echo "ok   - apply orphan merge: the branch is not written as the worktree"
fi

# =============================================================================
# --apply: merge with task (missing-worktree finding) — no automatic merge.
# Each task's records are files in its own dossier, so the review no longer
# offers it there; a review doc written before that change still has the
# line, and checking it is reported and skipped: no reopen/confirm phase,
# nothing deleted or rewritten.
# =============================================================================
fresh_env
wb_reconcile_repos() { :; }
mk_task "$TASKS_DIR" 'proj--stale.md'    doing proj stale-branch  '.worktrees/gone-a' 'Stale Task'
mk_task "$TASKS_DIR" 'proj--survivor.md' doing proj keeper-branch '.worktrees/gone-b' 'Survivor Task'
for d in proj--stale proj--survivor; do
  mkdir -p "$TASKS_DIR/dossiers/$d/decisions"; printf 'rec %s\n' "$d" > "$TASKS_DIR/dossiers/$d/decisions/r.md"
done
cmd_reconcile --review >/dev/null 2>&1
assert "merge fixture: both missing findings present" 'proj--stale' "$(cat "$REPORT")"
if grep -q 'merge with task' "$REPORT"; then
  echo "FAIL - review: a missing-worktree finding offers merge with task"; fail=1
else
  echo "ok   - review: a missing-worktree finding doesn't offer merge with task"
fi
check_line_for "$REPORT" 'taskfile=.*proj--stale\.md' \
  '^- \[ \] attach to task: `___`$' '- [x] merge with task: `proj--survivor.md`'
merge_before="$(cat "$TASKS_DIR/proj--stale.md" "$TASKS_DIR/proj--survivor.md"; find "$TASKS_DIR/dossiers" -type f | LC_ALL=C sort | xargs cat)"

out="$(cmd_reconcile --apply 2>&1)"; rc=$?
assert "merge: exits 0" '^' "$rc-ok"; [ "$rc" -eq 0 ] || { echo "FAIL - exit $rc: $out"; fail=1; }
assert "merge: says to merge by hand and skips the finding" 'merge them by hand — skipping this finding' "$out"
if printf '%s' "$out" | grep -q 'reopening for confirmation'; then
  echo "FAIL - merge: reopened the review for a survivor choice (that phase is gone)"; fail=1
else
  echo "ok   - merge: no survivor-confirmation phase"
fi
if [ -f "$TASKS_DIR/proj--stale.md" ] && [ -f "$TASKS_DIR/proj--survivor.md" ] \
  && [ "$merge_before" = "$(cat "$TASKS_DIR/proj--stale.md" "$TASKS_DIR/proj--survivor.md"; find "$TASKS_DIR/dossiers" -type f | LC_ALL=C sort | xargs cat)" ]; then
  echo "ok   - merge: both task files and their dossiers left exactly as they were"
else
  echo "FAIL - merge: a task file was deleted or changed"; fail=1
fi

# =============================================================================
# --apply: do nothing is a true no-op
# =============================================================================
fresh_env
mk_repo "$CODE_DIR/proj"
add_worktree "$CODE_DIR/proj" orphan-d
wb_reconcile_repos() { printf '%s\n' "$CODE_DIR/proj"; }
cmd_reconcile --review >/dev/null 2>&1
sed -i '0,/^- \[ \] do nothing$/s//- [x] do nothing/' "$REPORT"
cmd_reconcile --apply >/dev/null 2>&1
[ -d "$CODE_DIR/proj/.worktrees/orphan-d" ] \
  && echo "ok   - do-nothing: worktree untouched" \
  || { echo "FAIL - do-nothing: worktree was removed"; fail=1; }

[ "$fail" -eq 0 ] && echo "ALL PASS" || echo "FAILURES"
exit "$fail"
