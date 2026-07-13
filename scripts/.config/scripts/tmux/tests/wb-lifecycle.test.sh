#!/usr/bin/env bash
# Tests for wb-lifecycle.sh's detection functions (dotfiles--feat-wb-board-
# lifecycle, U1-U3 only — U4's board render wiring is out of scope; the
# display layer is under active redesign, see the plan's "Implementation
# status") — plain-bash assertions against fixture git repos/worktrees and
# a real (but throwaway) tmux session, following wb-reconcile.test.sh's and
# wb-pause.test.sh's established conventions.
#
# Isolated to a private tmux server for the live-agent signal:
# wb_board_live_session_for enumerates every session on the server (like
# collect_combined_rows in wb-parent-child.test.sh), so running against the
# real default server would leak the developer's actual sessions into every
# assertion. A fake `tmux` shim earlier in PATH pins every invocation to a
# throwaway `-L` socket, same as wb-parent-child.test.sh. tmux_claude_panes
# itself is stubbed (save_fn/restore_fn, same convention) rather than faking
# a real running `claude` process in a pane.
#
# Run: bash scripts/.config/scripts/tmux/tests/wb-lifecycle.test.sh
set -uo pipefail

WB="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/wb.sh"
FIXTURE_CODE="$(mktemp -d -t wb-lifecycle-code.XXXXXX)"
FIXTURE_TASKS="$(mktemp -d -t wb-lifecycle-tasks.XXXXXX)"
FIXTURE_BIN="$(mktemp -d -t wb-lifecycle-bin.XXXXXX)"
PREFIX="wb-lc-test-$$"
SOCK="wb-lc-sock-$$"
REAL_TMUX="$(command -v tmux)"

cat > "$FIXTURE_BIN/tmux" <<EOF
#!/usr/bin/env bash
exec "$REAL_TMUX" -L "$SOCK" "\$@"
EOF
chmod +x "$FIXTURE_BIN/tmux"
PATH="$FIXTURE_BIN:$PATH"

cleanup() {
  "$REAL_TMUX" -L "$SOCK" kill-server 2>/dev/null || true
  rm -rf "$FIXTURE_CODE" "$FIXTURE_TASKS" "$FIXTURE_BIN"
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
# check <desc> <true|false> <fn...> — runs <fn...> and asserts its exit
# status matches the expected boolean, the calling convention every
# wb_lifecycle_* predicate uses (exit code, not printed "true"/"false").
check() {
  local desc="$1" expect="$2" got
  shift 2
  if "$@"; then got=true; else got=false; fi
  if [ "$got" = "$expect" ]; then
    echo "ok   - $desc"
  else
    echo "FAIL - $desc (expected $expect, got $got)"
    fail=1
  fi
}

# shellcheck disable=SC1090
source "$WB"
set +e   # wb.sh sets -e; this test intentionally captures non-zero exits
TASKS_DIR="$FIXTURE_TASKS"
CODE_DIR="$FIXTURE_CODE"

mk_repo() { git init -q "$1"; git -C "$1" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init; }
add_worktree() { # <repo_dir> <branch>
  git -C "$1" worktree add -q -b "$2" ".worktrees/$2" >/dev/null 2>&1
}
mk_task() { # <file> <status> <repo> <branch>
  local f="$FIXTURE_TASKS/$1"
  printf -- '---\nstatus: %s\nrepo: %s\nbranch: %s\nworktree: .worktrees/x\ntags: []\ncreated: 2026-07-07\nclosed:\n---\n# Title\n' \
    "$2" "$3" "$4" > "$f"
}

mk_repo "$FIXTURE_CODE/proj"

# =============================================================================
# signal 1: wb_lifecycle_has_worktree
# =============================================================================
add_worktree "$FIXTURE_CODE/proj" wt-present
check "has_worktree: existing worktree -> true" true \
  wb_lifecycle_has_worktree proj .worktrees/wt-present

add_worktree "$FIXTURE_CODE/proj" wt-removed
git -C "$FIXTURE_CODE/proj" worktree remove --force ".worktrees/wt-removed"
check "has_worktree: removed worktree -> false" false \
  wb_lifecycle_has_worktree proj .worktrees/wt-removed

# =============================================================================
# signal 2: wb_lifecycle_has_live_agent
# =============================================================================
mk_session() { # <suffix> <repo> <branch>
  tmux new-session -d -s "${PREFIX}-$1" 2>/dev/null
  tmux set-option -t "=${PREFIX}-$1:" @wb_repo "$2" >/dev/null
  tmux set-option -t "=${PREFIX}-$1:" @wb_slug "$3" >/dev/null
}
kill_session() { tmux kill-session -t "=${PREFIX}-$1" 2>/dev/null || true; }
save_fn() { declare -f "$1"; }

check "live-agent: no session at all -> false" false \
  wb_lifecycle_has_live_agent proj feat/no-such-session

mk_session plain proj feat/plain
check "live-agent: session exists, only nvim/shell panes (real tmux_claude_panes, unstubbed) -> false" false \
  wb_lifecycle_has_live_agent proj feat/plain
kill_session plain

mk_session withagent proj feat/withagent
ORIG_PANES="$(save_fn tmux_claude_panes)"
tmux_claude_panes() {
  [ "${1:-}" = "${PREFIX}-withagent" ] || return 0
  printf '2\t%s:1.0\tworking\ttask\n' "${PREFIX}-withagent"
}
check "live-agent: session with a real claude pane -> true" true \
  wb_lifecycle_has_live_agent proj feat/withagent
eval "$ORIG_PANES"
kill_session withagent

# =============================================================================
# signals 3/4: wb_lifecycle_has_plan / wb_lifecycle_has_brainstorm
# =============================================================================

# --- glob match: filename contains the sanitized branch fragment -----------
add_worktree "$FIXTURE_CODE/proj" feat/plan-glob
mkdir -p "$FIXTURE_CODE/proj/.worktrees/feat/plan-glob/docs/plans"
printf '# plan\n' > "$FIXTURE_CODE/proj/.worktrees/feat/plan-glob/docs/plans/2026-07-11-001-feat-plan-glob-plan.md"
mk_task 'proj--feat-plan-glob.md' doing proj feat/plan-glob
check "has_plan: glob match on branch-fragment filename -> true" true \
  wb_lifecycle_has_plan proj feat/plan-glob .worktrees/feat/plan-glob "$FIXTURE_TASKS/proj--feat-plan-glob.md"
# regression guard for the deferred cross-worktree bug: the doc is only
# inside the fixture worktree, never under $dotfiles_root (SCRIPT_DIR's own
# repo) — prove detection didn't need it to be there.
[ ! -f "$SCRIPT_DIR/../docs/plans/2026-07-11-001-feat-plan-glob-plan.md" ] \
  && echo "ok   - has_plan: glob-hit doc genuinely absent from \$dotfiles_root (re-rooting is load-bearing)" \
  || { echo "FAIL - fixture leaked into dotfiles_root, test is not proving what it claims"; fail=1; }

# --- prose match: task file names the path, no filename-substring match ----
add_worktree "$FIXTURE_CODE/proj" feat/plan-prose
mkdir -p "$FIXTURE_CODE/proj/.worktrees/feat/plan-prose/docs/plans"
printf '# plan\n' > "$FIXTURE_CODE/proj/.worktrees/feat/plan-prose/docs/plans/2026-07-11-999-something-else-plan.md"
{
  printf -- '---\nstatus: doing\nrepo: proj\nbranch: feat/plan-prose\nworktree: .worktrees/x\ntags: []\ncreated: 2026-07-07\nclosed:\n---\n'
  printf '# Feat Plan Prose\n\n## Decisions\n\nSee docs/plans/2026-07-11-999-something-else-plan.md for the plan.\n'
} > "$FIXTURE_TASKS/proj--feat-plan-prose.md"
check "has_plan: prose match with no filename-substring hit -> true" true \
  wb_lifecycle_has_plan proj feat/plan-prose .worktrees/feat/plan-prose "$FIXTURE_TASKS/proj--feat-plan-prose.md"

# --- edge case: neither glob nor prose match --------------------------------
add_worktree "$FIXTURE_CODE/proj" feat/plan-none
mkdir -p "$FIXTURE_CODE/proj/.worktrees/feat/plan-none/docs/plans"
printf '# unrelated\n' > "$FIXTURE_CODE/proj/.worktrees/feat/plan-none/docs/plans/2020-01-01-unrelated-plan.md"
mk_task 'proj--feat-plan-none.md' doing proj feat/plan-none
check "has_plan: neither glob nor prose match -> false" false \
  wb_lifecycle_has_plan proj feat/plan-none .worktrees/feat/plan-none "$FIXTURE_TASKS/proj--feat-plan-none.md"

# --- edge case: docs/plans/ doesn't exist at all in the worktree ------------
add_worktree "$FIXTURE_CODE/proj" feat/plan-nodir
mk_task 'proj--feat-plan-nodir.md' doing proj feat/plan-nodir
check "has_plan: no docs/plans/ dir at all -> false, no error" false \
  wb_lifecycle_has_plan proj feat/plan-nodir .worktrees/feat/plan-nodir "$FIXTURE_TASKS/proj--feat-plan-nodir.md"

# --- has_brainstorm: same construction, glob-hit case -----------------------
add_worktree "$FIXTURE_CODE/proj" feat/brainstorm-glob
mkdir -p "$FIXTURE_CODE/proj/.worktrees/feat/brainstorm-glob/docs/brainstorms"
printf '# brainstorm\n' > "$FIXTURE_CODE/proj/.worktrees/feat/brainstorm-glob/docs/brainstorms/2026-07-11-001-feat-brainstorm-glob-brainstorm.md"
mk_task 'proj--feat-brainstorm-glob.md' doing proj feat/brainstorm-glob
check "has_brainstorm: glob match on branch-fragment filename -> true" true \
  wb_lifecycle_has_brainstorm proj feat/brainstorm-glob .worktrees/feat/brainstorm-glob "$FIXTURE_TASKS/proj--feat-brainstorm-glob.md"

add_worktree "$FIXTURE_CODE/proj" feat/brainstorm-none
mk_task 'proj--feat-brainstorm-none.md' doing proj feat/brainstorm-none
check "has_brainstorm: no docs/brainstorms/ dir at all -> false, no error" false \
  wb_lifecycle_has_brainstorm proj feat/brainstorm-none .worktrees/feat/brainstorm-none "$FIXTURE_TASKS/proj--feat-brainstorm-none.md"

# --- R27/AE8: empty branch: -> not-found before any matching ---------------
mkdir -p "$FIXTURE_CODE/proj/docs/plans"
printf '# unrelated\n' > "$FIXTURE_CODE/proj/docs/plans/2020-01-01-anything-plan.md"
printf -- '---\nstatus: planned\nrepo: proj\nbranch:\nworktree: .worktrees/x\ntags: []\ncreated: 2026-07-07\nclosed:\n---\n# Title\n' \
  > "$FIXTURE_TASKS/proj--emptybranch.md"
check "has_plan: empty branch: with unrelated docs/plans/ present -> false (AE8)" false \
  wb_lifecycle_has_plan proj "" .worktrees/x "$FIXTURE_TASKS/proj--emptybranch.md"
check "has_brainstorm: empty branch: -> false" false \
  wb_lifecycle_has_brainstorm proj "" .worktrees/x "$FIXTURE_TASKS/proj--emptybranch.md"
check "has_ideate: empty branch: -> false" false \
  wb_lifecycle_has_ideate proj "" .worktrees/x "$FIXTURE_TASKS/proj--emptybranch.md"

# --- AE8: empty worktree: -> not-found, never scans the main checkout ------
printf '# plan\n' > "$FIXTURE_CODE/proj/docs/plans/2026-07-11-001-feat-emptywt-match-plan.md"
printf -- '---\nstatus: planned\nrepo: proj\nbranch: feat/emptywt-match\nworktree:\ntags: []\ncreated: 2026-07-07\nclosed:\n---\n# Title\n' \
  > "$FIXTURE_TASKS/proj--emptywt.md"
check "has_plan: empty worktree: with a matching-name doc in the main checkout -> false" false \
  wb_lifecycle_has_plan proj feat/emptywt-match "" "$FIXTURE_TASKS/proj--emptywt.md"

# --- R6/AE3: kept-branch fallback — worktree removed, branch has the doc ---
add_worktree "$FIXTURE_CODE/proj" feat/plan-kept
mkdir -p "$FIXTURE_CODE/proj/.worktrees/feat/plan-kept/docs/plans"
printf '# plan\n' > "$FIXTURE_CODE/proj/.worktrees/feat/plan-kept/docs/plans/2026-07-11-001-feat-plan-kept-plan.md"
git -C "$FIXTURE_CODE/proj/.worktrees/feat/plan-kept" add docs/plans
git -C "$FIXTURE_CODE/proj/.worktrees/feat/plan-kept" -c user.email=t@t -c user.name=t commit -q -m "plan doc"
git -C "$FIXTURE_CODE/proj" worktree remove --force ".worktrees/feat/plan-kept"
mk_task 'proj--feat-plan-kept.md' done proj feat/plan-kept
check "has_plan: worktree removed, branch carries the plan doc -> true via ls-tree fallback (AE3)" true \
  wb_lifecycle_has_plan proj feat/plan-kept .worktrees/feat/plan-kept "$FIXTURE_TASKS/proj--feat-plan-kept.md"

# --- worktree removed AND branch deleted -> false, no crash -----------------
git -C "$FIXTURE_CODE/proj" branch -D feat/plan-kept
check "has_plan: worktree removed and branch deleted -> false, no crash" false \
  wb_lifecycle_has_plan proj feat/plan-kept .worktrees/feat/plan-kept "$FIXTURE_TASKS/proj--feat-plan-kept.md"

# --- R6/AE3: kept-branch fallback, prose half -------------------------------
add_worktree "$FIXTURE_CODE/proj" feat/plan-kept-prose
mkdir -p "$FIXTURE_CODE/proj/.worktrees/feat/plan-kept-prose/docs/plans"
printf '# plan\n' > "$FIXTURE_CODE/proj/.worktrees/feat/plan-kept-prose/docs/plans/2026-07-11-999-unrelated-name-plan.md"
{
  printf -- '---\nstatus: done\nrepo: proj\nbranch: feat/plan-kept-prose\nworktree: .worktrees/x\ntags: []\ncreated: 2026-07-07\nclosed: 2026-07-12\n---\n'
  printf '# Feat Plan Kept Prose\n\n## Decisions\n\nSee docs/plans/2026-07-11-999-unrelated-name-plan.md for the plan.\n'
} > "$FIXTURE_TASKS/proj--feat-plan-kept-prose.md"
git -C "$FIXTURE_CODE/proj/.worktrees/feat/plan-kept-prose" add docs/plans
git -C "$FIXTURE_CODE/proj/.worktrees/feat/plan-kept-prose" -c user.email=t@t -c user.name=t commit -q -m "plan doc"
git -C "$FIXTURE_CODE/proj" worktree remove --force ".worktrees/feat/plan-kept-prose"
check "has_plan: kept-branch fallback, prose half finds committed-only doc -> true" true \
  wb_lifecycle_has_plan proj feat/plan-kept-prose .worktrees/feat/plan-kept-prose "$FIXTURE_TASKS/proj--feat-plan-kept-prose.md"

# =============================================================================
# signal 8: wb_lifecycle_has_ideate (R7)
# =============================================================================
add_worktree "$FIXTURE_CODE/proj" feat/ideate-glob
mkdir -p "$FIXTURE_CODE/proj/.worktrees/feat/ideate-glob/docs/ideation"
printf '# ideate\n' > "$FIXTURE_CODE/proj/.worktrees/feat/ideate-glob/docs/ideation/2026-07-11-001-feat-ideate-glob-ideation.md"
mk_task 'proj--feat-ideate-glob.md' doing proj feat/ideate-glob
check "has_ideate: glob match on branch-fragment filename -> true" true \
  wb_lifecycle_has_ideate proj feat/ideate-glob .worktrees/feat/ideate-glob "$FIXTURE_TASKS/proj--feat-ideate-glob.md"
check "has_ideate match does not also fire has_plan" false \
  wb_lifecycle_has_plan proj feat/ideate-glob .worktrees/feat/ideate-glob "$FIXTURE_TASKS/proj--feat-ideate-glob.md"

# =============================================================================
# R8: discriminator — docs/plans/ candidates counted by frontmatter, not location
# =============================================================================
add_worktree "$FIXTURE_CODE/proj" feat/disc-brainstorm
mkdir -p "$FIXTURE_CODE/proj/.worktrees/feat/disc-brainstorm/docs/plans"
{
  printf -- '---\ntitle: x\nartifact_contract: ce-unified-plan/v1\nartifact_readiness: requirements-only\nproduct_contract_source: ce-brainstorm\n---\n'
  printf '# Plan\n'
} > "$FIXTURE_CODE/proj/.worktrees/feat/disc-brainstorm/docs/plans/2026-07-11-001-feat-disc-brainstorm-plan.md"
mk_task 'proj--feat-disc-brainstorm.md' doing proj feat/disc-brainstorm
check "has_brainstorm: requirements-only ce-brainstorm plan file -> true" true \
  wb_lifecycle_has_brainstorm proj feat/disc-brainstorm .worktrees/feat/disc-brainstorm "$FIXTURE_TASKS/proj--feat-disc-brainstorm.md"
check "has_plan: same requirements-only file -> false (not plan-done yet)" false \
  wb_lifecycle_has_plan proj feat/disc-brainstorm .worktrees/feat/disc-brainstorm "$FIXTURE_TASKS/proj--feat-disc-brainstorm.md"

# --- after enrichment: brainstorm stays true (source persists), plan flips true
{
  printf -- '---\ntitle: x\nartifact_contract: ce-unified-plan/v1\nartifact_readiness: implementation-ready\nproduct_contract_source: ce-brainstorm\n---\n'
  printf '# Plan\n'
} > "$FIXTURE_CODE/proj/.worktrees/feat/disc-brainstorm/docs/plans/2026-07-11-001-feat-disc-brainstorm-plan.md"
check "has_brainstorm: after enrichment, source field persists -> still true" true \
  wb_lifecycle_has_brainstorm proj feat/disc-brainstorm .worktrees/feat/disc-brainstorm "$FIXTURE_TASKS/proj--feat-disc-brainstorm.md"
check "has_plan: after enrichment (readiness != requirements-only) -> now true" true \
  wb_lifecycle_has_plan proj feat/disc-brainstorm .worktrees/feat/disc-brainstorm "$FIXTURE_TASKS/proj--feat-disc-brainstorm.md"

# --- legacy plan file, no contract frontmatter at all -----------------------
add_worktree "$FIXTURE_CODE/proj" feat/disc-legacy
mkdir -p "$FIXTURE_CODE/proj/.worktrees/feat/disc-legacy/docs/plans"
printf '# Legacy Plan\n' > "$FIXTURE_CODE/proj/.worktrees/feat/disc-legacy/docs/plans/2026-07-11-001-feat-disc-legacy-plan.md"
mk_task 'proj--feat-disc-legacy.md' doing proj feat/disc-legacy
check "has_plan: legacy plan file, no contract frontmatter -> true" true \
  wb_lifecycle_has_plan proj feat/disc-legacy .worktrees/feat/disc-legacy "$FIXTURE_TASKS/proj--feat-disc-legacy.md"
check "has_brainstorm: legacy plan file, no contract frontmatter -> false" false \
  wb_lifecycle_has_brainstorm proj feat/disc-legacy .worktrees/feat/disc-legacy "$FIXTURE_TASKS/proj--feat-disc-legacy.md"

# --- discriminator under the kept-branch fallback ---------------------------
add_worktree "$FIXTURE_CODE/proj" feat/disc-kept
mkdir -p "$FIXTURE_CODE/proj/.worktrees/feat/disc-kept/docs/plans"
{
  printf -- '---\ntitle: x\nartifact_contract: ce-unified-plan/v1\nartifact_readiness: requirements-only\nproduct_contract_source: ce-brainstorm\n---\n'
  printf '# Plan\n'
} > "$FIXTURE_CODE/proj/.worktrees/feat/disc-kept/docs/plans/2026-07-11-001-feat-disc-kept-plan.md"
git -C "$FIXTURE_CODE/proj/.worktrees/feat/disc-kept" add docs/plans
git -C "$FIXTURE_CODE/proj/.worktrees/feat/disc-kept" -c user.email=t@t -c user.name=t commit -q -m "requirements-only plan"
git -C "$FIXTURE_CODE/proj" worktree remove --force ".worktrees/feat/disc-kept"
mk_task 'proj--feat-disc-kept.md' doing proj feat/disc-kept
check "has_brainstorm: kept-branch fallback, requirements-only via git show -> true" true \
  wb_lifecycle_has_brainstorm proj feat/disc-kept .worktrees/feat/disc-kept "$FIXTURE_TASKS/proj--feat-disc-kept.md"
check "has_plan: kept-branch fallback, requirements-only via git show -> false" false \
  wb_lifecycle_has_plan proj feat/disc-kept .worktrees/feat/disc-kept "$FIXTURE_TASKS/proj--feat-disc-kept.md"

# =============================================================================
# signal 7: wb_lifecycle_pr_is_live
# =============================================================================
check "pr_is_live: OPEN state -> true" true wb_lifecycle_pr_is_live "#18 (OPEN)"
check "pr_is_live: CLOSED state -> false" false wb_lifecycle_pr_is_live "#18 (CLOSED)"
check "pr_is_live: MERGED state -> false" false wb_lifecycle_pr_is_live "#18 (MERGED)"
check "pr_is_live: empty pr_info -> false" false wb_lifecycle_pr_is_live ""

# =============================================================================
# signal 5: wb_lifecycle_work_done
# =============================================================================
# proj's main checkout stays on "main" throughout (only worktrees ever check
# out other branches) and has no origin remote, so wb_lifecycle_default_branch
# falls back to `git branch --show-current` against $repo_dir and resolves to
# "main" for every scenario below except the dedicated no-resolvable-default
# case, which uses its own detached-HEAD fixture repo.
commit_file() { # <worktree_abs_dir> <relative_file> <content>
  printf '%s\n' "$3" > "$1/$2"
  git -C "$1" add "$2"
  git -C "$1" -c user.email=t@t -c user.name=t commit -q -m "wip: $2"
}

# --- happy path: one committed non-planning change beyond merge-base -------
add_worktree "$FIXTURE_CODE/proj" work-committed
commit_file "$FIXTURE_CODE/proj/.worktrees/work-committed" impl.txt code
check "work_done: committed non-planning change beyond merge-base -> true" true \
  wb_lifecycle_work_done proj .worktrees/work-committed work-committed

# --- happy path: uncommitted-only non-planning change (feat/handoff-v1 case) -
add_worktree "$FIXTURE_CODE/proj" work-uncommitted
printf 'wip\n' > "$FIXTURE_CODE/proj/.worktrees/work-uncommitted/wip.txt"
check "work_done: uncommitted-only non-planning change, zero commits beyond merge-base -> true" true \
  wb_lifecycle_work_done proj .worktrees/work-uncommitted work-uncommitted

# --- happy path: worktree removed, branch still carries a committed change -
add_worktree "$FIXTURE_CODE/proj" work-removed
commit_file "$FIXTURE_CODE/proj/.worktrees/work-removed" impl.txt code
git -C "$FIXTURE_CODE/proj" worktree remove --force ".worktrees/work-removed"
check "work_done: worktree removed but branch carries committed change -> true, no crash" true \
  wb_lifecycle_work_done proj .worktrees/work-removed work-removed

# --- edge case: only planning-artifact paths touched ------------------------
add_worktree "$FIXTURE_CODE/proj" work-planning-only
mkdir -p "$FIXTURE_CODE/proj/.worktrees/work-planning-only/docs/plans"
commit_file "$FIXTURE_CODE/proj/.worktrees/work-planning-only" docs/plans/x.md plan
check "work_done: only planning-artifact paths touched -> false (documented limitation)" false \
  wb_lifecycle_work_done proj .worktrees/work-planning-only work-planning-only

# --- edge case: zero commits beyond merge-base, clean working tree ---------
add_worktree "$FIXTURE_CODE/proj" work-clean
check "work_done: clean worktree, no commits beyond merge-base -> false" false \
  wb_lifecycle_work_done proj .worktrees/work-clean work-clean

# --- edge case: worktree gone AND zero commits beyond merge-base -----------
add_worktree "$FIXTURE_CODE/proj" work-gone-clean
git -C "$FIXTURE_CODE/proj" worktree remove --force ".worktrees/work-gone-clean"
check "work_done: worktree gone + no commits beyond merge-base -> false, no crash" false \
  wb_lifecycle_work_done proj .worktrees/work-gone-clean work-gone-clean

# --- edge case: no resolvable default branch (detached HEAD, no origin) ----
mk_repo "$FIXTURE_CODE/detached"
DETACHED_SHA="$(git -C "$FIXTURE_CODE/detached" rev-parse HEAD)"
git -C "$FIXTURE_CODE/detached" checkout -q "$DETACHED_SHA"
add_worktree "$FIXTURE_CODE/detached" some-branch
check "work_done: no resolvable default branch -> false, no crash" false \
  wb_lifecycle_work_done detached .worktrees/some-branch some-branch

# =============================================================================
# signal 6 + wb reviewed: wb_lifecycle_review_done / cmd_reviewed
# =============================================================================

# --- wb_lifecycle_review_done: no field -> false; field set -> true --------
mk_task 'proj--feat-review-a.md' doing proj feat/review-a
check "review_done: no reviewed: field at all -> false" false \
  wb_lifecycle_review_done "$FIXTURE_TASKS/proj--feat-review-a.md"
wb_set_frontmatter "$FIXTURE_TASKS/proj--feat-review-a.md" reviewed 2026-07-01
check "review_done: reviewed: field set -> true" true \
  wb_lifecycle_review_done "$FIXTURE_TASKS/proj--feat-review-a.md"

# --- cmd_reviewed: happy path, stamps today's date --------------------------
mk_task 'proj--feat-review-b.md' doing proj feat/review-b
mk_session reviewb proj feat/review-b
out="$(cmd_reviewed "${PREFIX}-reviewb" 2>&1)"; rc=$?
assert "cmd_reviewed: exits 0" '^' "$rc-ok"; [ "$rc" -eq 0 ] || { echo "FAIL - exit $rc: $out"; fail=1; }
assert "cmd_reviewed: confirmation message" 'reviewed' "$out"
today="$(date +%F)"
assert "cmd_reviewed: stamps today's date" "^$today\$" \
  "$(wb_get_frontmatter "$FIXTURE_TASKS/proj--feat-review-b.md" reviewed)"
kill_session reviewb

# --- edge case: no session arg, run outside any wb session ($TMUX unset) ---
out="$(unset TMUX; cmd_reviewed 2>&1)"; rc=$?
assert "cmd_reviewed: no session arg + no TMUX -> non-zero exit" '^' "$rc-fail"; [ "$rc" -ne 0 ] || { echo "FAIL - exit $rc"; fail=1; }
assert "cmd_reviewed: no session arg + no TMUX -> clear error" 'run inside the target session' "$out"

# --- edge case: session given but not a wb task session (no @wb_repo/@wb_slug)
tmux new-session -d -s "${PREFIX}-bare" 2>/dev/null
out="$(cmd_reviewed "${PREFIX}-bare" 2>&1)"; rc=$?
assert "cmd_reviewed: bare session -> non-zero exit" '^' "$rc-fail"; [ "$rc" -ne 0 ] || { echo "FAIL - exit $rc"; fail=1; }
assert "cmd_reviewed: bare session -> clear error" 'not a wb task session' "$out"
kill_session bare

# --- regression: wb_seed_task's reviewed: blank-fill ------------------------
printf -- '---\nstatus: doing\nrepo: proj\nbranch: b\nworktree: .worktrees/x\ntags: []\ncreated: 2026-07-07\nclosed:\n---\n# No Reviewed Field\n' \
  > "$FIXTURE_TASKS/proj--noreviewed.md"
wb_seed_task proj noreviewed .worktrees/noreviewed >/dev/null
if grep -q '^reviewed:' "$FIXTURE_TASKS/proj--noreviewed.md"; then
  echo "ok   - wb_seed_task: reviewed: key inserted into a pre-existing file that lacked it"
else
  echo "FAIL - wb_seed_task: reviewed: key missing after seed"; fail=1
fi
if [ -z "$(wb_get_frontmatter "$FIXTURE_TASKS/proj--noreviewed.md" reviewed)" ]; then
  echo "ok   - wb_seed_task: reviewed: backfilled blank, not a bogus value"
else
  echo "FAIL - wb_seed_task: reviewed: unexpectedly got a non-blank value"; fail=1
fi

printf -- '---\nstatus: doing\nrepo: proj\nbranch: b\nworktree: .worktrees/x\ntags: []\ncreated: 2026-07-07\nclosed:\nreviewed: 2026-01-01\n---\n# Already Reviewed\n' \
  > "$FIXTURE_TASKS/proj--already-reviewed.md"
wb_seed_task proj already-reviewed .worktrees/already-reviewed >/dev/null
assert "wb_seed_task: an already-set reviewed: value is never overwritten" '^2026-01-01$' \
  "$(wb_get_frontmatter "$FIXTURE_TASKS/proj--already-reviewed.md" reviewed)"

# --- regression: repo/branch/worktree/status blank-fill still work ---------
printf -- '---\nstatus: planned\nrepo:\nbranch:\nworktree:\ntags: []\ncreated:\nclosed:\n---\n# Untouched Fields\n' \
  > "$FIXTURE_TASKS/proj--blankfields.md"
wb_seed_task proj blankfields .worktrees/blankfields >/dev/null
assert "regression: wb_seed_task still fills repo:" '^proj$' "$(wb_get_frontmatter "$FIXTURE_TASKS/proj--blankfields.md" repo)"
assert "regression: wb_seed_task still fills branch:" '^blankfields$' "$(wb_get_frontmatter "$FIXTURE_TASKS/proj--blankfields.md" branch)"
assert "regression: wb_seed_task still fills worktree:" '^\.worktrees/blankfields$' "$(wb_get_frontmatter "$FIXTURE_TASKS/proj--blankfields.md" worktree)"
assert "regression: wb_seed_task still bumps planned->doing" '^doing$' "$(wb_get_frontmatter "$FIXTURE_TASKS/proj--blankfields.md" status)"

# =============================================================================
# U2: wb_lifecycle_parse_path (R4) — path: field parsing, render-tolerant
# =============================================================================
assert_lines() { # <desc> <expected> <actual>
  if [ "$3" = "$2" ]; then
    echo "ok   - $1"
  else
    echo "FAIL - $1"
    echo "       expected: $(printf '%s' "$2" | tr '\n' ',')"
    echo "       got:      $(printf '%s' "$3" | tr '\n' ',')"
    fail=1
  fi
}

assert_lines "parse_path: absent -> default plan,work,review" \
  "$(printf 'plan\nwork\nreview')" "$(wb_lifecycle_parse_path '')"
assert_lines "parse_path: blank -> default plan,work,review" \
  "$(printf 'plan\nwork\nreview')" "$(wb_lifecycle_parse_path '   ')"
assert_lines "parse_path: whitespace-tolerant" \
  "$(printf 'plan\nwork\nreview')" "$(wb_lifecycle_parse_path 'plan, work , review')"
assert_lines "parse_path: unknown token dropped, no failure" \
  "$(printf 'plan\nwork')" "$(wb_lifecycle_parse_path 'plan,bogus,work')"
assert_lines "parse_path: duplicates dropped, canonical order imposed" \
  "$(printf 'plan\nwork')" "$(wb_lifecycle_parse_path 'work,plan,plan')"
assert_lines "parse_path: bracketed form stripped" \
  "$(printf 'work\nreview')" "$(wb_lifecycle_parse_path '[work,review]')"

# =============================================================================
# U2: wb_lifecycle_stage_state — four-state model (R1-R4)
# =============================================================================
default_path="$(wb_lifecycle_parse_path '')"

# --- AE1: work progress under changes+merged PR; done once status:done ----
add_worktree "$FIXTURE_CODE/proj" feat/stage-work
commit_file "$FIXTURE_CODE/proj/.worktrees/feat/stage-work" impl.txt code
mk_task 'proj--feat-stage-work.md' doing proj feat/stage-work
assert "stage_state: open task, changes + merged PR -> work progress (AE1)" '^progress$' \
  "$(wb_lifecycle_stage_state work proj feat/stage-work .worktrees/feat/stage-work "$FIXTURE_TASKS/proj--feat-stage-work.md" doing '#5 (MERGED)' "$default_path")"
assert "stage_state: status:done + PR merged -> work done (AE1)" '^done$' \
  "$(wb_lifecycle_stage_state work proj feat/stage-work .worktrees/feat/stage-work "$FIXTURE_TASKS/proj--feat-stage-work.md" done '#5 (MERGED)' "$default_path")"

# --- open task, no changes, PR OPEN -> work progress (PR-any-state signal) -
add_worktree "$FIXTURE_CODE/proj" feat/stage-pr-open
mk_task 'proj--feat-stage-pr-open.md' doing proj feat/stage-pr-open
assert "stage_state: open task, no changes, PR OPEN -> work progress" '^progress$' \
  "$(wb_lifecycle_stage_state work proj feat/stage-pr-open .worktrees/feat/stage-pr-open "$FIXTURE_TASKS/proj--feat-stage-pr-open.md" doing '#7 (OPEN)' "$default_path")"

# --- status:done, PR still OPEN -> work progress, not done (R2) -----------
assert "stage_state: status:done, PR OPEN -> work progress, not done" '^progress$' \
  "$(wb_lifecycle_stage_state work proj feat/stage-pr-open .worktrees/feat/stage-pr-open "$FIXTURE_TASKS/proj--feat-stage-pr-open.md" done '#7 (OPEN)' "$default_path")"

# --- status:done, no PR ever -> work done ----------------------------------
assert "stage_state: status:done, no PR ever -> work done" '^done$' \
  "$(wb_lifecycle_stage_state work proj feat/stage-pr-open .worktrees/feat/stage-pr-open "$FIXTURE_TASKS/proj--feat-stage-pr-open.md" done '' "$default_path")"

# --- AE2: no path: field + brainstorm artifact exists -> brainstorm done ---
add_worktree "$FIXTURE_CODE/proj" feat/stage-ae2
mkdir -p "$FIXTURE_CODE/proj/.worktrees/feat/stage-ae2/docs/brainstorms"
printf '# brainstorm\n' > "$FIXTURE_CODE/proj/.worktrees/feat/stage-ae2/docs/brainstorms/2026-07-11-001-feat-stage-ae2-brainstorm.md"
mk_task 'proj--feat-stage-ae2.md' doing proj feat/stage-ae2
assert "stage_state: no path:, brainstorm artifact exists -> brainstorm done (AE2)" '^done$' \
  "$(wb_lifecycle_stage_state brainstorm proj feat/stage-ae2 .worktrees/feat/stage-ae2 "$FIXTURE_TASKS/proj--feat-stage-ae2.md" doing '' "$default_path")"

# --- AE7: path: work,review -> ideate/brainstorm/plan all n/a -------------
add_worktree "$FIXTURE_CODE/proj" feat/stage-ae7
mk_task 'proj--feat-stage-ae7.md' doing proj feat/stage-ae7
docs_only_path="$(wb_lifecycle_parse_path 'work,review')"
for s in ideate brainstorm plan; do
  assert "stage_state: path work,review -> $s is n/a (AE7)" '^na$' \
    "$(wb_lifecycle_stage_state "$s" proj feat/stage-ae7 .worktrees/feat/stage-ae7 "$FIXTURE_TASKS/proj--feat-stage-ae7.md" doing '' "$docs_only_path")"
done
assert "stage_state: path work,review -> work renders per signals (pending, no changes)" '^pending$' \
  "$(wb_lifecycle_stage_state work proj feat/stage-ae7 .worktrees/feat/stage-ae7 "$FIXTURE_TASKS/proj--feat-stage-ae7.md" doing '' "$docs_only_path")"
assert "stage_state: path work,review -> review pending (not yet reviewed)" '^pending$' \
  "$(wb_lifecycle_stage_state review proj feat/stage-ae7 .worktrees/feat/stage-ae7 "$FIXTURE_TASKS/proj--feat-stage-ae7.md" doing '' "$docs_only_path")"

# --- review: stamped -> done ------------------------------------------------
wb_set_frontmatter "$FIXTURE_TASKS/proj--feat-stage-ae7.md" reviewed 2026-07-12
assert "stage_state: reviewed: stamped -> review done" '^done$' \
  "$(wb_lifecycle_stage_state review proj feat/stage-ae7 .worktrees/feat/stage-ae7 "$FIXTURE_TASKS/proj--feat-stage-ae7.md" doing '' "$docs_only_path")"

# --- AE8: branchless, worktree-less planned task; dirty main checkout -----
echo dirty > "$FIXTURE_CODE/proj/dirty.txt"
printf -- '---\nstatus: planned\nrepo: proj\nbranch:\nworktree:\ntags: []\ncreated: 2026-07-07\nclosed:\n---\n# Title\n' \
  > "$FIXTURE_TASKS/proj--stage-branchless.md"
assert "stage_state: branchless+worktree-less planned task, dirty main checkout -> work pending, never progress (AE8)" '^pending$' \
  "$(wb_lifecycle_stage_state work proj '' '' "$FIXTURE_TASKS/proj--stage-branchless.md" planned '' "$default_path")"
rm -f "$FIXTURE_CODE/proj/dirty.txt"

# --- session-less parent task: placeholder repo -> fails closed, no error --
mk_task 'proj--stage-parent.md' doing NOSUCHREPO somebranch
assert "stage_state: session-less parent (placeholder repo) -> plan pending, no crash" '^pending$' \
  "$(wb_lifecycle_stage_state plan NOSUCHREPO somebranch .worktrees/x "$FIXTURE_TASKS/proj--stage-parent.md" doing '' "$default_path")"

[ "$fail" -eq 0 ] && echo "ALL PASS" || echo "FAILURES"
exit "$fail"
