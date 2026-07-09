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
  awk -v marker="$marker" -v find="$find" -v repl="$repl" '
    /<!-- wb-reconcile:/ { in_target = ($0 ~ marker) }
    in_target && $0 ~ find { $0 = repl }
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
  printf -- '---\nstatus: planned\nrepo:\nbranch:\nworktree:\ntags: []\ncreated:\nclosed:\n---\n# Title\n\n## Plan\n\n## Done\n\n## Follow-ups\n\n## Decisions\n' \
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
sed -i 's/^- \[ \] create a task$/- [x] create a task/' "$REPORT"
cmd_reconcile --apply >/dev/null 2>&1
new_task="$TASKS_DIR/proj--orphan-b.md"
if [ -f "$new_task" ]; then
  assert "apply create-task: status doing" 'status: doing' "$(cat "$new_task")"
else
  echo "FAIL - apply create-task: $new_task not created"; fail=1
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

# =============================================================================
# --apply: merge with task (missing-worktree finding) — two-phase confirm
# =============================================================================
fresh_env
wb_reconcile_repos() { :; }
mk_task "$TASKS_DIR" 'proj--stale.md'    doing proj stale-branch  '.worktrees/gone-a' 'Stale Task'
mk_task "$TASKS_DIR" 'proj--survivor.md' doing proj keeper-branch '.worktrees/gone-b' 'Survivor Task'
touch -d '5 days ago' "$TASKS_DIR/proj--stale.md"
# survivor.md is newer (created just now) -> should be pre-picked as survivor
cmd_reconcile --review >/dev/null 2>&1
assert "merge fixture: both missing findings present" 'proj--stale' "$(cat "$REPORT")"

# name proj--survivor.md as the merge target on the stale finding's block
check_line_for "$REPORT" 'taskfile=.*proj--stale\.md' \
  '^- \[ \] merge with task: `___`$' '- [x] merge with task: `proj--survivor.md`'

out="$(cmd_reconcile --apply 2>&1)"; rc=$?
assert "merge phase1: reopens for confirmation" 'reopening for confirmation' "$out"
assert "merge phase1: survivor sub-checkboxes appended" 'survivor: this finding' "$(cat "$REPORT")"
assert "merge phase1: newer file pre-picked as survivor" '\[x\] survivor: `proj--survivor.md`' "$(cat "$REPORT")"
[ -f "$TASKS_DIR/proj--stale.md" ] && [ -f "$TASKS_DIR/proj--survivor.md" ] \
  && echo "ok   - merge phase1: neither file touched yet" \
  || { echo "FAIL - merge phase1: a file was deleted before confirmation"; fail=1; }

# phase 2: leave the pre-checked default as-is, apply again
out="$(cmd_reconcile --apply 2>&1)"; rc=$?
assert "merge phase2: exits 0" '^' "$rc-ok"; [ "$rc" -eq 0 ] || { echo "FAIL - exit $rc: $out"; fail=1; }
if [ -f "$TASKS_DIR/proj--survivor.md" ] && [ ! -f "$TASKS_DIR/proj--stale.md" ]; then
  echo "ok   - merge phase2: survivor kept, loser deleted"
else
  echo "FAIL - merge phase2: survivor present=$( [ -f "$TASKS_DIR/proj--survivor.md" ] && echo yes || echo no), loser present=$( [ -f "$TASKS_DIR/proj--stale.md" ] && echo yes || echo no)"
  fail=1
fi
assert "merge phase2: loser's Plan content folded into survivor" 'Original plan' "$(cat "$TASKS_DIR/proj--survivor.md")"

# =============================================================================
# --apply: merge override — user re-checks the OTHER survivor box
# =============================================================================
fresh_env
wb_reconcile_repos() { :; }
mk_task "$TASKS_DIR" 'proj--stale2.md'    doing proj stale2-branch  '.worktrees/gone-c' 'Stale Task 2'
mk_task "$TASKS_DIR" 'proj--survivor2.md' doing proj keeper2-branch '.worktrees/gone-d' 'Survivor Task 2'
touch -d '5 days ago' "$TASKS_DIR/proj--stale2.md"
cmd_reconcile --review >/dev/null 2>&1
check_line_for "$REPORT" 'taskfile=.*proj--stale2\.md' \
  '^- \[ \] merge with task: `___`$' '- [x] merge with task: `proj--survivor2.md`'
cmd_reconcile --apply >/dev/null 2>&1   # phase 1: appends pre-checked defaults
# override: uncheck the pre-picked default, check the other one instead
check_line_for "$REPORT" 'taskfile=.*proj--stale2\.md' \
  '\[x\] survivor: `proj--survivor2.md`' '  - [ ] survivor: `proj--survivor2.md` (existing) <!-- pre-picked: most recently active -->'
check_line_for "$REPORT" 'taskfile=.*proj--stale2\.md' \
  '\[ \] survivor: this finding' '  - [x] survivor: this finding (new stub)'
cmd_reconcile --apply >/dev/null 2>&1
if [ -f "$TASKS_DIR/proj--stale2.md" ] && [ ! -f "$TASKS_DIR/proj--survivor2.md" ]; then
  echo "ok   - merge override: user's explicit choice honored over the pre-picked default"
else
  echo "FAIL - merge override not honored (stale2 present=$( [ -f "$TASKS_DIR/proj--stale2.md" ] && echo yes || echo no), survivor2 present=$( [ -f "$TASKS_DIR/proj--survivor2.md" ] && echo yes || echo no))"
  fail=1
fi

# =============================================================================
# --apply: malformed survivor choice (both checked) is skipped, not guessed
# =============================================================================
fresh_env
wb_reconcile_repos() { :; }
mk_task "$TASKS_DIR" 'proj--stale3.md'    doing proj stale3-branch  '.worktrees/gone-e' 'Stale Task 3'
mk_task "$TASKS_DIR" 'proj--survivor3.md' doing proj keeper3-branch '.worktrees/gone-f' 'Survivor Task 3'
cmd_reconcile --review >/dev/null 2>&1
check_line_for "$REPORT" 'taskfile=.*proj--stale3\.md' \
  '^- \[ \] merge with task: `___`$' '- [x] merge with task: `proj--survivor3.md`'
cmd_reconcile --apply >/dev/null 2>&1   # phase 1: appends defaults (exactly one pre-checked)
# force BOTH survivor boxes checked -> malformed, regardless of which one the
# pre-pick landed on (mtimes of two just-created fixture files aren't a
# reliable enough signal to assume which default this run will land on).
check_line_for "$REPORT" 'taskfile=.*proj--stale3\.md' \
  '\[.\] survivor: `proj--survivor3.md`' '  - [x] survivor: `proj--survivor3.md` (existing) <!-- pre-picked: most recently active -->'
check_line_for "$REPORT" 'taskfile=.*proj--stale3\.md' \
  '\[.\] survivor: this finding' '  - [x] survivor: this finding (new stub)'
out="$(cmd_reconcile --apply 2>&1)"
assert "malformed survivor: warns and skips" 'need exactly 1' "$out"
[ -f "$TASKS_DIR/proj--stale3.md" ] && [ -f "$TASKS_DIR/proj--survivor3.md" ] \
  && echo "ok   - malformed survivor: both files left untouched" \
  || { echo "FAIL - malformed survivor: a file was touched despite the malformed choice"; fail=1; }

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
