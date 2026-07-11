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

[ "$fail" -eq 0 ] && echo "ALL PASS" || echo "FAILURES"
exit "$fail"
