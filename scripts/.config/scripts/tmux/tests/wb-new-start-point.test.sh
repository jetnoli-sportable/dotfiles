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

# a stacked blocker: local branch feat-a with one commit of its own, cut from
# the stale local default, so it is one commit behind origin/development
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
# feat-base sits under feat-a (feat-a is stacked on it); feat-merged's PR merged
# but its task was never marked done
git -C "$PROJ" branch -q feat-base feat-a~1
git -C "$PROJ" branch -q feat-merged feat-a
task proj--feat-base     doing   proj   feat-base
task proj--feat-merged   review  proj   feat-merged

export CODE_DIR="$FIXTURE_CODE"
export TASKS_DIR="$FIXTURE_TASKS"
export CLAUDE_PROJECTS_DIR="$FIXTURE_PROJECTS"

# shellcheck disable=SC1090
source "$WB"
set +e
# No menu unless a test asks for one — even when this file runs in a terminal.
_wb_new_interactive() { return 1; }
# No network: only feat-merged has a merged PR.
wb_pr_merge_status() { if [ "$2" = feat-merged ]; then echo merged; else echo not-merged; fi; }

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

# --- --depends-on: stacks on the blocker's local branch, nudges a rebase ----
out="$(new --depends-on proj--feat-a proj stacked-dep)"
assert_eq "--depends-on: stacked on the blocker's branch" "$FEAT_A_TIP" "$(tip stacked-dep)"
assert "--depends-on: stale blocker gets a rebase nudge" \
  'feat-a \(proj--feat-a\) is 1 commit\(s\) behind origin/development — consider rebasing' "$out"

# --- up-to-date blocker: stacks, no rebase nudge ----------------------------
# cut from the origin tip the first `wb new` above fetched
FRESH_TIP="$(gitc -C "$PROJ" commit-tree "$REMOTE_TIP^{tree}" -p "$REMOTE_TIP" -m "feat-fresh work")"
git -C "$PROJ" branch -q feat-fresh "$FRESH_TIP"
task proj--feat-fresh doing proj feat-fresh
out="$(new --depends-on proj--feat-fresh proj after-fresh)"
assert_eq "up-to-date blocker: stacked on the blocker's branch" "$FRESH_TIP" "$(tip after-fresh)"
if printf '%s' "$out" | grep -q 'consider rebasing'; then
  echo "FAIL - up-to-date blocker: no rebase nudge"; fail=1
else
  echo "ok   - up-to-date blocker: no rebase nudge"
fi

# --- --parent alone never stacks: a parent is an umbrella, not a blocker ----
new --parent proj--feat-a proj child-of-parent >/dev/null
assert_eq "--parent alone: branched from origin/<default>, not the parent" "$REMOTE_TIP" "$(tip child-of-parent)"

# --- planned first (real --planned path), started later ---------------------
new --planned --depends-on proj--feat-a proj later >/dev/null
assert_eq "planned: --depends-on persisted to the task file" "proj--feat-a" \
  "$(wb_get_frontmatter "$FIXTURE_TASKS/proj--later.md" depends_on)"
new proj later >/dev/null
assert_eq "planned-then-started: depends_on read from the task file" "$FEAT_A_TIP" "$(tip later)"

# --- first usable depends_on entry; parent ignored; skips done / branchless /
# cross-repo ------------------------------------------------------------------
task proj--order planned proj "" proj--feat-remote "proj--shipped,proj--no-branch,other--feat-a,proj--feat-a"
new proj order >/dev/null
assert_eq "order: first usable depends_on entry wins, parent ignored" "$FEAT_A_TIP" "$(tip order)"

# --- two usable blockers, no terminal: first one, and a note about the other -
out="$(new --depends-on proj--feat-a --depends-on proj--feat-remote proj two-blockers)"
assert_eq "two blockers: stacked on the first" "$FEAT_A_TIP" "$(tip two-blockers)"
assert "two blockers: notes the one left out" 'also depends on proj--feat-remote \(origin/feat-remote\)' "$out"

# --- second blocker already inside the first: no "merge it in" note -------
out="$(new --depends-on proj--feat-a --depends-on proj--feat-base proj contains-base)"
assert_eq "contained blocker: stacked on the first" "$FEAT_A_TIP" "$(tip contains-base)"
if printf '%s' "$out" | grep -q 'also depends on proj--feat-base'; then
  echo "FAIL - contained blocker: no note for a blocker the start point already has"; fail=1
else
  echo "ok   - contained blocker: no note for a blocker the start point already has"
fi

# --- blocker whose PR merged (task not yet done): skipped, latest default ---
out="$(new --depends-on proj--feat-merged proj after-merged)"
assert_eq "merged-PR blocker: branched from origin/<default>" "$REMOTE_TIP" "$(tip after-merged)"
assert "merged-PR blocker: says to branch from the latest default" \
  "proj--feat-merged's PR \\(feat-merged\\) is already merged — its work is in origin/development, so branch from the latest origin/development instead" "$out"

# --- with a terminal: a menu of the blockers plus the latest default --------
_wb_new_interactive() { return 0; }
out="$(printf '\n' | new --depends-on proj--feat-a proj menu-default)"
assert_eq "menu: Enter picks the blocker" "$FEAT_A_TIP" "$(tip menu-default)"
assert "menu: shows ahead/behind for the blocker" '1\) feat-a  \(proj--feat-a, 1 ahead / 1 behind origin/development\)' "$out"
assert "menu: offers the latest default" '2\) origin/development  \(latest\)' "$out"
out="$(printf '2\n' | new --depends-on proj--feat-a proj menu-latest)"
assert_eq "menu: last option branches from origin/<default>" "$REMOTE_TIP" "$(tip menu-latest)"
if printf '%s' "$out" | grep -q 'consider rebasing'; then
  echo "FAIL - menu: no rebase nudge when the default was chosen"; fail=1
else
  echo "ok   - menu: no rebase nudge when the default was chosen"
fi
out="$(printf 'x\n9\n1\n' | new --depends-on proj--feat-a proj menu-retry)"
assert_eq "menu: re-asks on bad input, then honors the choice" "$FEAT_A_TIP" "$(tip menu-retry)"
assert "menu: says what input it wants" 'enter a number from 1 to 2' "$out"
_wb_new_interactive() { return 1; }

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

# --- a task's pre-set branch: is adopted as the git branch ------------------
# Seeding tools fill branch: (usually feat/…, fix/… — slash names) long before
# `wb new`; the git branch must BE that name, or every branch-keyed lookup
# (PR badge, wb down's open-PR check, a dependent's stacking) misses.
fm() { wb_get_frontmatter "$FIXTURE_TASKS/$1.md" "$2"; }
has_branch() { git -C "$PROJ" show-ref --verify --quiet "refs/heads/$1"; }
task proj--adopt planned proj feat/adopt
out="$(new proj adopt)"
assert_eq "adopt: git branch is the pre-set name, from fresh origin" "$REMOTE_TIP2" "$(tip feat/adopt)"
assert "adopt: says where it branched from" 'wb new: branching feat/adopt from origin/development' "$out"
has_branch adopt && { echo "FAIL - adopt: no second, slug-named branch"; fail=1; } || echo "ok   - adopt: no second, slug-named branch"
assert_eq "adopt: branch: left as the pre-set name" "feat/adopt" "$(fm proj--adopt branch)"
assert_eq "adopt: worktree dir stays slug-based" ".worktrees/adopt" "$(fm proj--adopt worktree)"
assert_eq "adopt: worktree is on the adopted branch" "feat/adopt" "$(git -C "$PROJ/.worktrees/adopt" rev-parse --abbrev-ref HEAD)"
assert_eq "adopt: planned flips to doing" "doing" "$(fm proj--adopt status)"
assert_eq "adopt: no upstream (--no-track)" "" "$(upstream feat/adopt)"

# --- a dependent stacks on the ADOPTED branch (what #73 reads from branch:) --
gitc -C "$PROJ/.worktrees/adopt" commit -q --allow-empty -m "adopt work"
ADOPT_TIP="$(tip feat/adopt)"
new --planned --depends-on proj--adopt proj after-adopt >/dev/null
new proj after-adopt >/dev/null
assert_eq "adopt: dependent stacks on the adopted branch's commits" "$ADOPT_TIP" "$(tip after-adopt)"

# --- the pre-set branch also gets #73's depends_on stacking itself ----------
task proj--adopt-stacked planned proj feat/adopt-stacked "" proj--feat-a
new proj adopt-stacked >/dev/null
assert_eq "adopt + depends_on: adopted branch cut from the blocker" "$FEAT_A_TIP" "$(tip feat/adopt-stacked)"

# --- pre-set branch already exists locally: attached as-is ------------------
git -C "$PROJ" branch -q feat/local-existing "$LOCAL_TIP"
task proj--adopt-local planned proj feat/local-existing
out="$(new proj adopt-local)"
assert_eq "existing local branch: attached unchanged" "$LOCAL_TIP" "$(tip feat/local-existing)"
assert_eq "existing local branch: worktree is on it" "feat/local-existing" "$(git -C "$PROJ/.worktrees/adopt-local" rev-parse --abbrev-ref HEAD)"
has_branch adopt-local && { echo "FAIL - existing local branch: no slug-named branch"; fail=1; } || echo "ok   - existing local branch: no slug-named branch"

# --- pre-set branch exists only on origin: checked out tracking it ----------
# Pushed AFTER proj's last fetch, so this also covers the targeted fetch.
git -C "$SEED" checkout -q -b feat/only-remote development
gitc -C "$SEED" commit -q --allow-empty -m "only-remote work"
git -C "$SEED" push -q origin feat/only-remote
ONLY_REMOTE_TIP="$(git -C "$BARE" rev-parse feat/only-remote)"
git -C "$PROJ" show-ref --verify --quiet refs/remotes/origin/feat/only-remote \
  && { echo "FAIL - fixture: feat/only-remote should not be fetched yet"; fail=1; }
task proj--adopt-remote planned proj feat/only-remote
out="$(new proj adopt-remote)"
assert_eq "remote-only branch: checked out at origin's tip" "$ONLY_REMOTE_TIP" "$(tip feat/only-remote)"
assert_eq "remote-only branch: tracks origin/<branch>" "origin/feat/only-remote" "$(upstream feat/only-remote)"
assert "remote-only branch: says it attached" 'attaching adopt-remote to existing origin/feat/only-remote' "$out"

# --- invalid ref name: clear error, nothing created -------------------------
task proj--adopt-bad planned proj 'bad..name'
out="$(new proj adopt-bad)"
assert "invalid ref: names the problem" "'bad\.\.name'.*not a valid git branch name" "$out"
[ -d "$PROJ/.worktrees/adopt-bad" ] && { echo "FAIL - invalid ref: no worktree created"; fail=1; } || echo "ok   - invalid ref: no worktree created"
assert_eq "invalid ref: task not flipped to doing" "planned" "$(fm proj--adopt-bad status)"

# --- checked out in another worktree: refused, naming it --------------------
task proj--adopt-busy planned proj feat-a
out="$(new proj adopt-busy)"
assert "checked out elsewhere: refused" "branch 'feat-a' is already checked out at $FIXTURE_GIT/feat-a-wt" "$out"
[ -d "$PROJ/.worktrees/adopt-busy" ] && { echo "FAIL - checked out elsewhere: no worktree created"; fail=1; } || echo "ok   - checked out elsewhere: no worktree created"
assert_eq "checked out elsewhere: task not flipped to doing" "planned" "$(fm proj--adopt-busy status)"

# --- blank branch: unchanged — slug-named branch, field filled --------------
task proj--adopt-blank planned proj ""
new proj adopt-blank >/dev/null
assert_eq "blank branch: slug-named branch from origin" "$REMOTE_TIP2" "$(tip adopt-blank)"
assert_eq "blank branch: branch: filled with the slug" "adopt-blank" "$(fm proj--adopt-blank branch)"

# --- resume/picker re-entry of an adopted task ------------------------------
# cmd_resume and the picker pass the BRANCH as <slug> plus the task file; the
# worktree dir and session must still be the slug-based ones from the first
# `wb new`, not a nested .worktrees/feat/… and a differently named session.
git -C "$PROJ" worktree remove "$PROJ/.worktrees/adopt"
tmux kill-session -t "=proj--adopt" 2>/dev/null
_WB_TASK_FILE_OVERRIDE="$FIXTURE_TASKS/proj--adopt.md" cmd_new proj feat/adopt >/dev/null 2>&1
unset _WB_TASK_FILE_OVERRIDE
assert_eq "resume: worktree recreated at the slug-based dir, on the adopted branch" "feat/adopt" \
  "$(git -C "$PROJ/.worktrees/adopt" rev-parse --abbrev-ref HEAD 2>/dev/null)"
[ -d "$PROJ/.worktrees/feat" ] && { echo "FAIL - resume: no nested .worktrees/feat"; fail=1; } || echo "ok   - resume: no nested .worktrees/feat"
tmux has-session -t "=proj--adopt" 2>/dev/null && echo "ok   - resume: session is the slug-named one" || { echo "FAIL - resume: session is the slug-named one"; fail=1; }

# --- resume/picker re-entry hardening --------------------------------------
reenter() { # <stem> <branch> — the resume/picker call shape
  local repo="${1%%--*}"
  _WB_TASK_FILE_OVERRIDE="$FIXTURE_TASKS/$1.md" cmd_new "$repo" "$2" 2>&1
  unset _WB_TASK_FILE_OVERRIDE
}
# a worktree: that climbs out of .worktrees/ is ignored with a warning
task proj--trav planned proj feat/trav
wb_set_frontmatter "$FIXTURE_TASKS/proj--trav.md" worktree ".worktrees/../../escape"
out="$(reenter proj--trav feat/trav)"
assert "traversal worktree: warns and falls back" "warning: ignoring worktree: '\.worktrees/\.\./\.\./escape'" "$out"
[ -e "$FIXTURE_CODE/escape" ] && { echo "FAIL - traversal worktree: nothing created outside .worktrees"; fail=1; } || echo "ok   - traversal worktree: nothing created outside .worktrees"
assert_eq "traversal worktree: slug-derived dir, on the adopted branch" "feat/trav" \
  "$(git -C "$PROJ/.worktrees/trav" rev-parse --abbrev-ref HEAD 2>/dev/null)"
assert_eq "traversal worktree: field rewritten to the safe path" ".worktrees/trav" "$(fm proj--trav worktree)"

# blank worktree: + preset branch: dir/session come from the task file stem
task proj--blankwt planned proj feat/blankwt
reenter proj--blankwt feat/blankwt >/dev/null
assert_eq "blank worktree: stem-slug dir, on the preset branch" "feat/blankwt" \
  "$(git -C "$PROJ/.worktrees/blankwt" rev-parse --abbrev-ref HEAD 2>/dev/null)"
[ -d "$PROJ/.worktrees/feat" ] && { echo "FAIL - blank worktree: no nested .worktrees/feat"; fail=1; } || echo "ok   - blank worktree: no nested .worktrees/feat"
tmux has-session -t "=proj--blankwt" 2>/dev/null && echo "ok   - blank worktree: session is stem-named" || { echo "FAIL - blank worktree: session is stem-named"; fail=1; }

# ...and the remote-only adopt (tracking) applies on that path too
git -C "$SEED" checkout -q -b feat/blankwt-remote development
gitc -C "$SEED" commit -q --allow-empty -m "blankwt-remote work"
git -C "$SEED" push -q origin feat/blankwt-remote
BLANK_REMOTE_TIP="$(git -C "$BARE" rev-parse feat/blankwt-remote)"
task proj--blankwt-remote planned proj feat/blankwt-remote
reenter proj--blankwt-remote feat/blankwt-remote >/dev/null
assert_eq "blank worktree + remote-only branch: checked out at origin's tip" "$BLANK_REMOTE_TIP" "$(tip feat/blankwt-remote)"
assert_eq "blank worktree + remote-only branch: tracks origin/<branch>" "origin/feat/blankwt-remote" "$(upstream feat/blankwt-remote)"

# --- could not check origin for the pre-set branch: abort, create nothing ---
git -C "$PROJ" remote set-url origin "$FIXTURE_GIT/gone.git"
task proj--adopt-offline planned proj feat/offline
out="$(new proj adopt-offline)"
assert "offline adopt: says it could not reach origin" "couldn't reach origin to check for branch 'feat/offline'" "$out"
[ -d "$PROJ/.worktrees/adopt-offline" ] && { echo "FAIL - offline adopt: no worktree created"; fail=1; } || echo "ok   - offline adopt: no worktree created"
has_branch feat/offline && { echo "FAIL - offline adopt: no local branch cut"; fail=1; } || echo "ok   - offline adopt: no local branch cut"
assert_eq "offline adopt: task not flipped to doing" "planned" "$(fm proj--adopt-offline status)"
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

# --- no origin, one blocker: a one-entry menu is skipped -------------------
SOLO_FEAT_TIP="$(gitc -C "$FIXTURE_CODE/solo" commit-tree "$SOLO_TIP^{tree}" -p "$SOLO_TIP" -m "solo-feat work")"
git -C "$FIXTURE_CODE/solo" branch -q solo-feat "$SOLO_FEAT_TIP"
task solo--feat doing solo solo-feat
_wb_new_interactive() { return 0; }
out="$(new --depends-on solo--feat solo solo-menu </dev/null)"
_wb_new_interactive() { return 1; }
assert_eq "no-origin, one blocker: stacked on the blocker" "$SOLO_FEAT_TIP" "$(git -C "$FIXTURE_CODE/solo" rev-parse solo-menu)"
if printf '%s' "$out" | grep -q 'Choice\|branch from:'; then
  echo "FAIL - no-origin, one blocker: no one-entry menu"; fail=1
else
  echo "ok   - no-origin, one blocker: no one-entry menu"
fi

exit "$fail"
