#!/usr/bin/env bash
# Tests for `wb reconcile` (U6, detection only) — plain-bash assertions,
# same convention as wb-board.test.sh. Sources wb.sh (safe: see the
# BASH_SOURCE guard at the bottom of wb.sh), stubs wb_reconcile_repos to
# point at real fixture git repos (worktree detection needs real git state),
# and injects a fake `gh` via PATH so no live network call ever happens.
# Run: bash scripts/.config/scripts/tmux/tests/wb-reconcile.test.sh
set -uo pipefail

WB="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/wb.sh"
FIXTURE_CODE="$(mktemp -d -t wb-reconcile-code.XXXXXX)"
FIXTURE_TASKS="$(mktemp -d -t wb-reconcile-tasks.XXXXXX)"
FIXTURE_BIN="$(mktemp -d -t wb-reconcile-bin.XXXXXX)"
trap 'rm -rf "$FIXTURE_CODE" "$FIXTURE_TASKS" "$FIXTURE_BIN"' EXIT

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

# --- fake `gh` — no live network call, ever -----------------------------
cat > "$FIXTURE_BIN/gh" <<'EOF'
#!/usr/bin/env bash
head=""
while [ $# -gt 0 ]; do
  case "$1" in
    --head) head="$2"; shift 2 ;;
    *) shift ;;
  esac
done
case "$head" in
  merged-orphan) echo '[{"number":42,"mergedAt":"2026-07-01T00:00:00Z"}]' ;;
  stale-orphan)  echo '[]' ;;
  broken-orphan) echo 'gh: some unrelated failure' >&2; exit 1 ;;
  *) echo '[]' ;;
esac
EOF
chmod +x "$FIXTURE_BIN/gh"
PATH="$FIXTURE_BIN:$PATH"

# --- fixture repo with 4 worktrees: 3 orphaned (one per merge status), ------
# --- 1 tracked by a task file (must NOT show up as drift) -------------------
mk_repo() {
  local dir="$1"
  git init -q "$dir"
  git -C "$dir" -c user.email=test@test -c user.name=test commit -q --allow-empty -m init
}
add_worktree() { # <repo_dir> <branch>
  git -C "$1" worktree add -q -b "$2" ".worktrees/$2" >/dev/null 2>&1
}

mk_repo "$FIXTURE_CODE/proj"
add_worktree "$FIXTURE_CODE/proj" merged-orphan
add_worktree "$FIXTURE_CODE/proj" stale-orphan
add_worktree "$FIXTURE_CODE/proj" broken-orphan
add_worktree "$FIXTURE_CODE/proj" tracked-branch

mk_task() { # <file> <repo> <branch> <worktree>
  local f="$FIXTURE_TASKS/$1"
  printf -- '---\nstatus: doing\nrepo: %s\nbranch: %s\nworktree: %s\ntags: []\ncreated: 2026-07-07\nclosed:\n---\n# Title\n' \
    "$2" "$3" "$4" > "$f"
}
mk_task 'proj--tracked.md' proj tracked-branch '.worktrees/tracked-branch'
mk_task 'proj--ghost.md'   proj ghost-branch   '.worktrees/ghost-branch'   # worktree never created -> missing

# shellcheck disable=SC1090
source "$WB"
set +e   # wb.sh sets -e; this test captures non-zero exits by design
TASKS_DIR="$FIXTURE_TASKS"
CODE_DIR="$FIXTURE_CODE"
wb_reconcile_repos() { printf '%s\n' "$FIXTURE_CODE/proj"; }

out="$(cmd_reconcile 2>&1)"; rc=$?

assert "exits 0" '^' "$rc-ok"; [ "$rc" -eq 0 ] || { echo "FAIL - exit code $rc: $out"; fail=1; }
assert "header for orphan section"  'Orphaned worktrees' "$out"
assert "header for missing section" 'Tasks referencing a missing worktree' "$out"

assert "merged orphan reported as merged"     'proj +merged-orphan +\.worktrees/merged-orphan +merged' "$out"
assert "stale orphan reported as not-merged"  'proj +stale-orphan +\.worktrees/stale-orphan +not-merged' "$out"
assert "gh failure reported as unknown, not dropped" 'proj +broken-orphan +\.worktrees/broken-orphan +unknown' "$out"
assert "missing-worktree task reported"       'proj +\.worktrees/ghost-branch +proj--ghost' "$out"

if printf '%s' "$out" | grep -q 'tracked-branch.*not-merged\|tracked-branch.*merged\|tracked-branch.*unknown'; then
  echo "FAIL - tracked-branch (has a matching task file) reported as orphaned drift"
  fail=1
else
  echo "ok   - tracked-branch excluded (matched by task file)"
fi

# --- clean tree: no orphans, no missing worktrees -> explicit no-drift ------
CLEAN_CODE="$(mktemp -d -t wb-reconcile-clean-code.XXXXXX)"
CLEAN_TASKS="$(mktemp -d -t wb-reconcile-clean-tasks.XXXXXX)"
mk_repo "$CLEAN_CODE/proj"
add_worktree "$CLEAN_CODE/proj" only-branch
TASKS_DIR="$CLEAN_TASKS"
CODE_DIR="$CLEAN_CODE"
printf -- '---\nstatus: doing\nrepo: proj\nbranch: only-branch\nworktree: .worktrees/only-branch\ntags: []\ncreated: 2026-07-07\nclosed:\n---\n# Title\n' \
  > "$CLEAN_TASKS/proj--only.md"
wb_reconcile_repos() { printf '%s\n' "$CLEAN_CODE/proj"; }
out_clean="$(cmd_reconcile 2>&1)"; rc_clean=$?
assert "clean tree exits 0" '^' "$rc_clean-ok"; [ "$rc_clean" -eq 0 ] || { echo "FAIL - exit code $rc_clean: $out_clean"; fail=1; }
assert "clean tree reports no drift" 'no drift found' "$out_clean"
rm -rf "$CLEAN_CODE" "$CLEAN_TASKS"

[ "$fail" -eq 0 ] && echo "ALL PASS" || echo "FAILURES"
exit "$fail"
