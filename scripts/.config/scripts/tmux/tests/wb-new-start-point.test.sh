#!/usr/bin/env bash
# Behavioral tests for cmd_new's start-point resolution (_wb_new_start_point):
# a freshly created branch stacks on its depends_on/parent task's branch, or
# otherwise starts from a freshly fetched origin/<default> — never silently
# from the main checkout's (stale) HEAD. Same harness as wb-new.test.sh:
# source wb.sh, real tmux on a throwaway socket, real git under a fixture
# CODE_DIR — here with a real bare origin that is AHEAD of the clone's local
# default branch, which is exactly the stale-base case being fixed.
#
# Run: bash scripts/.config/scripts/tmux/tests/wb-new-start-point.test.sh
set -uo pipefail

WB="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/wb.sh"
FIXTURE_CODE="$(mktemp -d -t wb-sp-code.XXXXXX)"
FIXTURE_TASKS="$(mktemp -d -t wb-sp-tasks.XXXXXX)"
FIXTURE_BIN="$(mktemp -d -t wb-sp-bin.XXXXXX)"
FIXTURE_PROJECTS="$(mktemp -d -t wb-sp-projects.XXXXXX)"
FIXTURE_GIT="$(mktemp -d -t wb-sp-git.XXXXXX)"   # bare origin + a "someone else" clone
SOCK="wb-sp-sock-$$"
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

gitc() { git -c user.email=t@t -c user.name=t "$@"; }

# origin (bare, default branch `development`) <- seed clone pushes; proj is a
# real `git clone` (so origin/HEAD is set), then the seed pushes one more
# commit, leaving proj's local development AND its cached origin/development
# one commit behind the real remote.
BARE="$FIXTURE_GIT/origin.git"
SEED="$FIXTURE_GIT/seed"
PROJ="$FIXTURE_CODE/proj"
git init -q --bare -b development "$BARE"
git clone -q "$BARE" "$SEED" 2>/dev/null
git -C "$SEED" checkout -q -b development
gitc -C "$SEED" commit -q --allow-empty -m init
git -C "$SEED" push -q origin development
git clone -q "$BARE" "$PROJ"
gitc -C "$SEED" commit -q --allow-empty -m "merged-since-last-pull"
git -C "$SEED" push -q origin development
REMOTE_TIP="$(git -C "$BARE" rev-parse development)"
LOCAL_TIP="$(git -C "$PROJ" rev-parse development)"
[ "$REMOTE_TIP" != "$LOCAL_TIP" ] || { echo "FAIL - fixture: local should be behind origin"; exit 1; }

# a stacked blocker: local branch feat-a with one commit of its own
git -C "$PROJ" branch -q feat-a
git -C "$PROJ" worktree add -q "$FIXTURE_GIT/feat-a-wt" feat-a
gitc -C "$FIXTURE_GIT/feat-a-wt" commit -q --allow-empty -m "feat-a work"
FEAT_A_TIP="$(git -C "$PROJ" rev-parse feat-a)"

# a blocker whose branch exists only on origin (pushed from elsewhere)
git -C "$SEED" checkout -q -b feat-remote
gitc -C "$SEED" commit -q --allow-empty -m "feat-remote work"
git -C "$SEED" push -q origin feat-remote
git -C "$PROJ" fetch -q origin feat-remote
FEAT_REMOTE_TIP="$(git -C "$BARE" rev-parse feat-remote)"
# re-stale proj's cached origin/development (the fetch above didn't touch it,
# but be explicit that only feat-remote was fetched)
[ "$(git -C "$PROJ" rev-parse origin/development)" = "$LOCAL_TIP" ] \
  || { echo "FAIL - fixture: origin/development should still be stale"; exit 1; }

task() { # <stem> <status> <repo> <branch> [<parent>] [<depends_on>]
  printf -- '---\nstatus: %s\nrepo: %s\nbranch: %s\nworktree:\nparent: %s\ndepends_on: %s\ntags: []\ncreated: 2026-10-01\nclosed:\n---\n# %s\n' \
    "$2" "$3" "$4" "${5:-}" "${6:-}" "$1" > "$FIXTURE_TASKS/$1.md"
}
printf -- '---\nstatus: planned\nrepo:\nbranch:\nworktree:\nparent:\ndepends_on:\ntags: []\ncreated:\nclosed:\n---\n# Title\n' \
  > "$FIXTURE_TASKS/TEMPLATE.md"
task proj--feat-a        review  proj   feat-a
task proj--feat-remote   doing   proj   feat-remote
task proj--shipped       done    proj   feat-a
task proj--no-branch     doing   proj   does-not-exist
task other--feat-a       doing   other  feat-a

export CODE_DIR="$FIXTURE_CODE"
export TASKS_DIR="$FIXTURE_TASKS"
export CLAUDE_PROJECTS_DIR="$FIXTURE_PROJECTS"

# shellcheck disable=SC1090
source "$WB"
set +e

# cmd_new ends in tmux_focus -> `tmux attach`, which fails without a client;
# side effects (the branch's commit / upstream) are the real assertions.
new() { cmd_new "$@" 2>&1; }
tip() { git -C "$PROJ" rev-parse "$1" 2>/dev/null; }
upstream() { git -C "$PROJ" rev-parse --abbrev-ref "$1@{upstream}" 2>/dev/null; }

# --- no parent/depends_on: fetched origin/<default>, not stale local HEAD ----
out="$(new proj plain)"
assert_eq "plain: branched from the freshly fetched origin tip" "$REMOTE_TIP" "$(tip plain)"
assert "plain: says where it branched from" 'wb new: branching plain from origin/development' "$out"
assert_eq "plain: no upstream set to origin/development (--no-track)" "" "$(upstream plain)"

# --- --depends-on: stacks on the blocker's local branch ---------------------
new --depends-on proj--feat-a proj stacked-dep >/dev/null
assert_eq "--depends-on: stacked on the blocker's branch" "$FEAT_A_TIP" "$(tip stacked-dep)"

# --- --parent: stacks on the parent's branch --------------------------------
new --parent proj--feat-a proj stacked-parent >/dev/null
assert_eq "--parent: stacked on the parent's branch" "$FEAT_A_TIP" "$(tip stacked-parent)"

# --- planned first, started later: reads parent/depends_on from the file ----
task proj--later planned proj "" "" proj--feat-a
new proj later >/dev/null
assert_eq "planned-then-started: depends_on read from the task file" "$FEAT_A_TIP" "$(tip later)"

# --- depends_on wins over parent; skips done / branchless / cross-repo ------
task proj--order planned proj "" proj--feat-remote "proj--shipped,proj--no-branch,other--feat-a,proj--feat-a"
new proj order >/dev/null
assert_eq "order: first usable depends_on entry wins over parent" "$FEAT_A_TIP" "$(tip order)"

# --- blocker branch only on origin: uses origin/<branch> --------------------
new --depends-on proj--feat-remote proj stacked-remote >/dev/null
assert_eq "remote-only blocker branch: stacked on origin/<branch>" "$FEAT_REMOTE_TIP" "$(tip stacked-remote)"
assert_eq "remote-only blocker branch: no upstream set (--no-track)" "" "$(upstream stacked-remote)"

# --- only a done blocker: its commits are merged, use the default ----------
new --depends-on proj--shipped proj after-done >/dev/null
assert_eq "done blocker: falls back to origin/<default>" "$REMOTE_TIP" "$(tip after-done)"

# --- an existing local branch is attached as-is, never re-based -------------
git -C "$PROJ" branch -q preexisting "$LOCAL_TIP"
new proj preexisting >/dev/null
assert_eq "existing branch: attached unchanged" "$LOCAL_TIP" "$(tip preexisting)"

# --- no origin/HEAD symref: resolved via ls-remote --------------------------
git -C "$SEED" checkout -q development
gitc -C "$SEED" commit -q --allow-empty -m "another merge"
git -C "$SEED" push -q origin development
REMOTE_TIP2="$(git -C "$BARE" rev-parse development)"
git -C "$PROJ" remote set-head origin -d
new proj no-symref >/dev/null
assert_eq "no origin/HEAD symref: default resolved via ls-remote" "$REMOTE_TIP2" "$(tip no-symref)"
git -C "$PROJ" remote set-head origin development

# --- unreachable origin: warns, uses the last-fetched origin/<default> ------
git -C "$PROJ" remote set-url origin "$FIXTURE_GIT/gone.git"
out="$(new proj offline)"
assert "unreachable origin: warns about the failed fetch" 'warning: git fetch origin development failed' "$out"
assert_eq "unreachable origin: still branches from cached origin/development" "$REMOTE_TIP2" "$(tip offline)"
git -C "$PROJ" remote set-url origin "$BARE"

# --- no origin at all: old behavior (local HEAD), silently ------------------
mkdir -p "$FIXTURE_CODE/solo"
git init -q -b development "$FIXTURE_CODE/solo"
gitc -C "$FIXTURE_CODE/solo" commit -q --allow-empty -m init
SOLO_TIP="$(git -C "$FIXTURE_CODE/solo" rev-parse HEAD)"
out="$(new solo lonely)"
assert_eq "no origin: branched from local HEAD" "$SOLO_TIP" "$(git -C "$FIXTURE_CODE/solo" rev-parse lonely)"
if printf '%s' "$out" | grep -q 'branching\|warning: could not determine'; then
  echo "FAIL - no origin: should be silent about the start-point"; fail=1
else
  echo "ok   - no origin: silent about the start-point"
fi

exit "$fail"
