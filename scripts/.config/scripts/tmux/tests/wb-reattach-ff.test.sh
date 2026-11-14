#!/usr/bin/env bash
# Behavioral tests for the reattach fast-forward (_wb_new_fast_forward, U3): when
# `wb new`/`wb resume` is about to create the tmux session for an EXISTING
# worktree or local branch that is clean, has no commits of its own and is
# behind its start point, the branch is fast-forwarded; otherwise wb prints one
# line saying how far behind it is and why it stayed. Same harness as
# wb-new-start-point.test.sh: real tmux on a private -L socket, real git under a
# fixture CODE_DIR with a real bare origin.
#
# Run: bash scripts/.config/scripts/tmux/tests/wb-reattach-ff.test.sh
set -uo pipefail

WB="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/wb.sh"
FIXTURE_CODE="$(mktemp -d -t wb-ff-code.XXXXXX)"
FIXTURE_TASKS="$(mktemp -d -t wb-ff-tasks.XXXXXX)"
FIXTURE_BIN="$(mktemp -d -t wb-ff-bin.XXXXXX)"
FIXTURE_PROJECTS="$(mktemp -d -t wb-ff-projects.XXXXXX)"
FIXTURE_GIT="$(mktemp -d -t wb-ff-git.XXXXXX)"
SOCK="wb-ff-sock-$$"
REAL_TMUX="$(command -v tmux)"

cat > "$FIXTURE_BIN/tmux" <<EOF
#!/usr/bin/env bash
exec "$REAL_TMUX" -L "$SOCK" "\$@"
EOF
chmod +x "$FIXTURE_BIN/tmux"
PATH="$FIXTURE_BIN:$PATH"

cleanup() {
  "$REAL_TMUX" -L "$SOCK" kill-server 2>/dev/null || true
  rm -rf "$FIXTURE_CODE" "$FIXTURE_TASKS" "$FIXTURE_BIN" "$FIXTURE_PROJECTS" "$FIXTURE_GIT"
}
trap cleanup EXIT

fail=0
assert() { # <desc> <expected-regex> <actual>
  if printf '%s' "$3" | /usr/bin/grep -qE "$2"; then
    echo "ok   - $1"
  else
    echo "FAIL - $1"
    echo "       expected match: $2"
    echo "       got: $(printf '%s' "$3" | head -8)"
    fail=1
  fi
}
refute() { # <desc> <regex that must NOT match> <actual>
  if printf '%s' "$3" | /usr/bin/grep -qE "$2"; then
    echo "FAIL - $1"
    echo "       unexpected match: $2"
    echo "       got: $(printf '%s' "$3" | head -8)"
    fail=1
  else
    echo "ok   - $1"
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

gitc() { git -c user.email=t@t -c user.name=t "$@"; }

BARE="$FIXTURE_GIT/origin.git"
SEED="$FIXTURE_GIT/seed"
PROJ="$FIXTURE_CODE/proj"
git init -q --bare -b development "$BARE"
git clone -q "$BARE" "$SEED" 2>/dev/null
git -C "$SEED" checkout -q -b development
echo base > "$SEED/f"
git -C "$SEED" add f
gitc -C "$SEED" commit -q -m init
git -C "$SEED" push -q origin development
git clone -q "$BARE" "$PROJ"

advance() { # <n> — the remote default gains n commits
  local i
  for ((i = 0; i < ${1:-1}; i++)); do gitc -C "$SEED" commit -q --allow-empty -m "dev-$RANDOM"; done
  git -C "$SEED" push -q origin development
}
# mk <slug> — a worktree on branch <slug> cut from the freshest origin/development
mk() {
  git -C "$PROJ" fetch -q origin development
  git -C "$PROJ" worktree add -q --no-track -b "$1" "$PROJ/.worktrees/$1" origin/development
}
task() { # <stem> <status> <branch> [<depends_on>]
  printf -- '---\nstatus: %s\nrepo: proj\nbranch: %s\nworktree:\nparent:\ndepends_on: %s\ntags: []\ncreated: 2026-10-01\nclosed:\n---\n# %s\n' \
    "$2" "$3" "${4:-}" "$1" > "$FIXTURE_TASKS/$1.md"
}
printf -- '---\nstatus: planned\nrepo:\nbranch:\nworktree:\nparent:\ndepends_on:\ntags: []\ncreated:\nclosed:\n---\n# Title\n' \
  > "$FIXTURE_TASKS/TEMPLATE.md"

export CODE_DIR="$FIXTURE_CODE"
export TASKS_DIR="$FIXTURE_TASKS"
export CLAUDE_PROJECTS_DIR="$FIXTURE_PROJECTS"

# shellcheck disable=SC1090
source "$WB"
set +e
_wb_new_interactive() { return 1; }
wb_pr_merge_status() { echo not-merged; }
wb_branch_has_open_pr() { return 1; }

new() { cmd_new "$@" 2>&1; }
tip() { git -C "$PROJ" rev-parse "$1" 2>/dev/null; }
session_exists() { tmux has-session -t "=proj--$1" 2>/dev/null; }

# --- clean, 3 behind, no commits of its own, no live session: fast-forwarded --
mk ff-basic
OLD="$(tip ff-basic)"
advance 3
out="$(new proj ff-basic)"
assert_eq "ff: branch moved to origin/development" "$(git -C "$BARE" rev-parse development)" "$(tip ff-basic)"
assert "ff: message names the move, 3 commits and the start point" \
  "wb new: fast-forwarded ff-basic ${OLD:0:7}\.\.[0-9a-f]{7} \(3 commits\) to origin/development" "$out"
session_exists ff-basic && echo "ok   - ff: session created" || { echo "FAIL - ff: session created"; fail=1; }

# --- already at the start point: silent -------------------------------------
out="$(new proj ff-basic)"
refute "at start point (session exists now): nothing printed" 'fast-forward|behind' "$out"
mk ff-uptodate
out="$(new proj ff-uptodate)"
refute "at start point: nothing printed" 'fast-forward|behind' "$out"

# --- live session: not touched ----------------------------------------------
mk ff-live
LIVE_OLD="$(tip ff-live)"
tmux new-session -d -s proj--ff-live -c "$PROJ/.worktrees/ff-live"
advance 2
out="$(new proj ff-live)"
assert_eq "live session: branch untouched" "$LIVE_OLD" "$(tip ff-live)"
refute "live session: nothing printed" 'fast-forward|behind' "$out"

# --- one commit of its own: not moved, behind line --------------------------
mk ff-own
gitc -C "$PROJ/.worktrees/ff-own" commit -q --allow-empty -m "own work"
OWN_OLD="$(tip ff-own)"
advance 2
out="$(new proj ff-own)"
assert_eq "own commit: branch untouched" "$OWN_OLD" "$(tip ff-own)"
assert "own commit: behind line with the reason" \
  'wb new: ff-own is 2 commit\(s\) behind origin/development — not fast-forwarded: it has 1 commit\(s\) of its own' "$out"
session_exists ff-own && echo "ok   - own commit: session still created" || { echo "FAIL - own commit: session still created"; fail=1; }

# --- tracked file modified -------------------------------------------------
mk ff-dirty
DIRTY_OLD="$(tip ff-dirty)"
echo changed > "$PROJ/.worktrees/ff-dirty/f"
advance 1
out="$(new proj ff-dirty)"
assert_eq "dirty: branch untouched" "$DIRTY_OLD" "$(tip ff-dirty)"
assert "dirty: warning names the tracked-file changes" 'behind origin/development — not fast-forwarded: .*tracked files' "$out"

# --- untracked file the fast-forward would overwrite: git refuses ----------
mk ff-untracked
UT_OLD="$(tip ff-untracked)"
echo "from remote" > "$SEED/u.txt"
git -C "$SEED" add u.txt
gitc -C "$SEED" commit -q -m "add u.txt"
git -C "$SEED" push -q origin development
echo "mine" > "$PROJ/.worktrees/ff-untracked/u.txt"
out="$(new proj ff-untracked)"
assert_eq "untracked overwrite: branch untouched" "$UT_OLD" "$(tip ff-untracked)"
assert_eq "untracked overwrite: my file intact" "mine" "$(cat "$PROJ/.worktrees/ff-untracked/u.txt")"
assert "untracked overwrite: warns git refused" 'wb new: warning: .*ff-untracked.*(refused|could not)' "$out"
session_exists ff-untracked && echo "ok   - untracked overwrite: session still created" || { echo "FAIL - untracked overwrite: session still created"; fail=1; }

# --- HEAD detached ---------------------------------------------------------
mk ff-detached
git -C "$PROJ/.worktrees/ff-detached" checkout -q --detach
DET_OLD="$(tip ff-detached)"
advance 1
out="$(new proj ff-detached)"
assert_eq "detached: branch untouched" "$DET_OLD" "$(tip ff-detached)"
assert "detached: warning" 'not fast-forwarded: .*detached' "$out"

# --- worktree checked out on a different branch ----------------------------
mk ff-other
git -C "$PROJ/.worktrees/ff-other" checkout -q -b somewhere-else
OTHER_OLD="$(tip ff-other)"
advance 1
out="$(new proj ff-other)"
assert_eq "other branch: ff-other untouched" "$OTHER_OLD" "$(tip ff-other)"
assert "other branch: warning names the branch" 'not fast-forwarded: .*somewhere-else' "$out"

# --- rebase in progress ----------------------------------------------------
mk ff-rebase
mkdir "$(git -C "$PROJ/.worktrees/ff-rebase" rev-parse --absolute-git-dir)/rebase-merge"
RB_OLD="$(tip ff-rebase)"
advance 1
out="$(new proj ff-rebase)"
assert_eq "rebase in progress: branch untouched" "$RB_OLD" "$(tip ff-rebase)"
assert "rebase in progress: warning" 'not fast-forwarded: .*rebase' "$out"

# --- origin/<branch> has commits the local branch lacks --------------------
mk ff-pull
PULL_OLD="$(tip ff-pull)"
git -C "$SEED" checkout -q -b ff-pull "$PULL_OLD"
gitc -C "$SEED" commit -q --allow-empty -m "pushed from another machine"
git -C "$SEED" push -q origin ff-pull
git -C "$SEED" checkout -q development
git -C "$PROJ" fetch -q origin ff-pull
advance 1
out="$(new proj ff-pull)"
assert_eq "origin has more: branch untouched" "$PULL_OLD" "$(tip ff-pull)"
assert "origin has more: pull-first warning" 'not fast-forwarded: .*pull first' "$out"

# --- stacked on a blocker that exists on origin: moves to origin/<blocker> --
mk ff-stack
STACK_OLD="$(tip ff-stack)"
advance 1
git -C "$PROJ" fetch -q origin development
git -C "$SEED" checkout -q -b blk-a origin/development
gitc -C "$SEED" commit -q --allow-empty -m "blk-a on origin"
git -C "$SEED" push -q origin blk-a
git -C "$SEED" checkout -q -b blk-b origin/development
gitc -C "$SEED" commit -q --allow-empty -m "blk-b on origin"
git -C "$SEED" push -q origin blk-b
git -C "$SEED" checkout -q development
git -C "$PROJ" fetch -q origin blk-a blk-b
# a local blk-a with an unpushed commit: must never be the target
git -C "$PROJ" branch -q blk-a "$STACK_OLD"
git -C "$PROJ/.worktrees/ff-stack" log -1 >/dev/null
BLKA_LOCAL="$(gitc -C "$PROJ" commit-tree "$STACK_OLD^{tree}" -p "$STACK_OLD" -m "local-only blk-a")"
git -C "$PROJ" branch -q -f blk-a "$BLKA_LOCAL"
task proj--blk-a doing blk-a
task proj--blk-b doing blk-b
task proj--ff-stack doing ff-stack "proj--blk-a,proj--blk-b"
_wb_new_interactive() { return 0; }
out="$(new proj ff-stack </dev/null)"
_wb_new_interactive() { return 1; }
assert_eq "stacked: moved to origin/blk-a" "$(tip origin/blk-a)" "$(tip ff-stack)"
refute "stacked: never onto the blocker's local branch" "$BLKA_LOCAL" "$(git -C "$PROJ" log --format=%H ff-stack)"
assert "stacked: message names origin/blk-a" 'to origin/blk-a' "$out"
refute "terminal + two blockers: no menu during reattach" 'branch from:|Choice' "$out"

# --- local branch exists, no worktree: worktree added, then fast-forwarded --
git -C "$PROJ" fetch -q origin development
git -C "$PROJ" branch -q --no-track ff-nowt origin/development
advance 2
out="$(new proj ff-nowt)"
[ -d "$PROJ/.worktrees/ff-nowt" ] && echo "ok   - no worktree: worktree added" || { echo "FAIL - no worktree: worktree added"; fail=1; }
assert_eq "no worktree: branch fast-forwarded" "$(git -C "$BARE" rev-parse development)" "$(tip ff-nowt)"
assert "no worktree: message" 'fast-forwarded ff-nowt .* \(2 commits\)' "$out"

# --- branch cut by this very call: no fast-forward attempt -----------------
out="$(new proj ff-cut)"
assert_eq "just cut: at the start point" "$(git -C "$BARE" rev-parse development)" "$(tip ff-cut)"
refute "just cut: no fast-forward or behind line" 'fast-forward|behind' "$out"

# --- branch attached from origin by this call: also "just created" ---------
git -C "$PROJ" fetch -q origin development
git -C "$SEED" checkout -q -b ff-att origin/development
gitc -C "$SEED" commit -q --allow-empty -m "att work"
git -C "$SEED" push -q origin ff-att
git -C "$SEED" checkout -q development
ATT_TIP="$(git -C "$BARE" rev-parse ff-att)"
advance 2
task proj--ff-att doing ff-att
out="$(new proj ff-att)"
assert "attached: attach line printed" 'attaching ff-att to existing origin/ff-att' "$out"
assert_eq "attached: left at the origin tip, not fast-forwarded" "$ATT_TIP" "$(tip ff-att)"
refute "attached: no fast-forward line" 'fast-forwarded' "$out"

exit "$fail"
