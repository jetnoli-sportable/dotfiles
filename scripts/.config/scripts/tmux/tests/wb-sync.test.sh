#!/usr/bin/env bash
# Tests for `wb sync` (U7) — fixture bare "origin" remote + fixture local
# clones exercising each guard/branch outcome. Real git plumbing throughout
# (fetch, rev-list --left-right, merge --ff-only) against throwaway repos
# under /tmp; never a real ~/code/tasks checkout.
#
# MUST run via the project's sandboxed Dockerfile, same reasoning as
# wb-done.test.sh's own header (2026-07-10 CODE_DIR incident):
#   docker build -t wb-tests -f scripts/.config/scripts/tmux/tests/Dockerfile .
#   docker run --rm -v "$(pwd)":/repo:ro -w /repo wb-tests \
#     bash scripts/.config/scripts/tmux/tests/wb-sync.test.sh
#
# The fixture origin's default branch is deliberately named "trunk" — NOT
# "development" (this dotfiles repo's own convention) or "main" — so a pass
# here actually proves cmd_sync's branch guard (H23) reads origin/HEAD
# dynamically rather than assuming either hardcoded name.
set -uo pipefail

WB="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/wb.sh"
FIXTURE="$(mktemp -d -t wb-sync-fixture.XXXXXX)"
trap 'rm -rf "$FIXTURE"' EXIT

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

DEFAULT_BRANCH=trunk

# mk_origin <name> — a fresh bare repo at $FIXTURE/origin-<name>.git, seeded
# with one commit on $DEFAULT_BRANCH via a throwaway working clone kept at
# $FIXTURE/seed-<name> (retained so later scenarios can push more commits
# through it, simulating "someone else pushed" without touching the fixture
# under test). Bare repos don't inherit a pushed branch as their own HEAD
# automatically, so its symref is set explicitly — confirmed by hand against
# a real bare+clone pair before writing this fixture. Prints the bare path.
mk_origin() {
  local name="$1"
  local bare="$FIXTURE/origin-$name.git"
  local seed="$FIXTURE/seed-$name"
  git init -q --bare "$bare"
  git init -q "$seed"
  git -C "$seed" symbolic-ref HEAD "refs/heads/$DEFAULT_BRANCH"
  echo init > "$seed/file.txt"
  git -C "$seed" add file.txt
  git -C "$seed" -c user.email=test@test -c user.name=test commit -q -m init
  git -C "$seed" remote add origin "$bare"
  git -C "$seed" push -q origin "$DEFAULT_BRANCH"
  git -C "$bare" symbolic-ref HEAD "refs/heads/$DEFAULT_BRANCH"
  printf '%s\n' "$bare"
}

# push_commit <seed-dir> <message> — commits <message> on top of whatever is
# checked out in <seed-dir> and pushes it straight to origin, simulating a
# concurrent push from someone else without ever touching the clone under
# test in the same scenario.
push_commit() {
  local seed="$1" msg="$2"
  echo "$msg" >> "$seed/file.txt"
  git -C "$seed" add file.txt
  git -C "$seed" -c user.email=test@test -c user.name=test commit -q -m "$msg"
  git -C "$seed" push -q origin "$DEFAULT_BRANCH"
}

# commit_local <clone-dir> <message> — commits directly inside a clone under
# test (i.e. a local, never-pushed commit), for ahead/diverged scenarios.
commit_local() {
  local clone="$1" msg="$2"
  echo "$msg" >> "$clone/file.txt"
  git -C "$clone" add file.txt
  git -C "$clone" -c user.email=test@test -c user.name=test commit -q -m "$msg"
}

# shellcheck disable=SC1090
source "$WB"
set +e   # wb.sh sets -e; this test intentionally captures non-zero exits

# =============================================================================
# Behind-only: local is a stale clone, fetch+ff-merge pulls the new commit(s)
# and reports how many.
# =============================================================================
origin_behind="$(mk_origin behind)"
git clone -q "$origin_behind" "$FIXTURE/behind" >/dev/null 2>&1
push_commit "$FIXTURE/seed-behind" "second commit"

TASKS_DIR="$FIXTURE/behind"
out="$(cmd_sync 2>&1)"; rc=$?
assert "behind: exits 0" '^' "$rc-ok"; [ "$rc" -eq 0 ] || { echo "FAIL - exit $rc: $out"; fail=1; }
assert "behind: reports pulled commit count" 'pulled 1 commit' "$out"
local_head="$(git -C "$FIXTURE/behind" rev-parse HEAD)"
origin_head="$(git -C "$origin_behind" rev-parse "$DEFAULT_BRANCH")"
if [ "$local_head" = "$origin_head" ]; then
  echo "ok   - behind: local now matches origin (fast-forwarded)"
else
  echo "FAIL - behind: local ($local_head) != origin ($origin_head)"; fail=1
fi

# =============================================================================
# Ahead-only: local has an unpushed commit, remote has nothing new ->
# no-op message, and — critically — NO push happens (this command never
# pushes, under any circumstance).
# =============================================================================
origin_ahead="$(mk_origin ahead)"
git clone -q "$origin_ahead" "$FIXTURE/ahead" >/dev/null 2>&1
commit_local "$FIXTURE/ahead" "local-only commit"
before_origin_head="$(git -C "$origin_ahead" rev-parse "$DEFAULT_BRANCH")"
before_local_head="$(git -C "$FIXTURE/ahead" rev-parse HEAD)"

TASKS_DIR="$FIXTURE/ahead"
out="$(cmd_sync 2>&1)"; rc=$?
assert "ahead: exits 0" '^' "$rc-ok"; [ "$rc" -eq 0 ] || { echo "FAIL - exit $rc: $out"; fail=1; }
assert "ahead: nothing-to-pull message" 'nothing to pull, consider pushing' "$out"
after_origin_head="$(git -C "$origin_ahead" rev-parse "$DEFAULT_BRANCH")"
after_local_head="$(git -C "$FIXTURE/ahead" rev-parse HEAD)"
if [ "$after_origin_head" = "$before_origin_head" ]; then
  echo "ok   - ahead: origin ref did NOT move (no push occurred)"
else
  echo "FAIL - ahead: origin ref moved ($before_origin_head -> $after_origin_head) — wb sync must never push"; fail=1
fi
if [ "$after_local_head" = "$before_local_head" ]; then
  echo "ok   - ahead: local HEAD unchanged"
else
  echo "FAIL - ahead: local HEAD changed ($before_local_head -> $after_local_head)"; fail=1
fi

# =============================================================================
# Diverged: both sides moved independently -> refuse, message shows both
# ahead/behind counts AND explicitly names `reset --hard origin/<branch>` as
# the anti-pattern to avoid.
# =============================================================================
origin_diverged="$(mk_origin diverged)"
git clone -q "$origin_diverged" "$FIXTURE/diverged" >/dev/null 2>&1
push_commit "$FIXTURE/seed-diverged" "remote-only commit"
commit_local "$FIXTURE/diverged" "local-only commit"
before_local_head="$(git -C "$FIXTURE/diverged" rev-parse HEAD)"

TASKS_DIR="$FIXTURE/diverged"
out="$(cmd_sync 2>&1)"; rc=$?
assert "diverged: non-zero exit" '^' "$rc-fail"; [ "$rc" -ne 0 ] || { echo "FAIL - exit $rc"; fail=1; }
assert "diverged: reports DIVERGED" 'DIVERGED' "$out"
assert "diverged: shows ahead/behind counts" '1 ahead, 1 behind' "$out"
assert "diverged: names reset --hard origin/<branch> as the anti-pattern" "reset --hard origin/$DEFAULT_BRANCH" "$out"
assert "diverged: gives manual resolution commands" 'git -C .* merge origin/'"$DEFAULT_BRANCH" "$out"
after_local_head="$(git -C "$FIXTURE/diverged" rev-parse HEAD)"
if [ "$after_local_head" = "$before_local_head" ]; then
  echo "ok   - diverged: local HEAD untouched (no auto-merge attempted)"
else
  echo "FAIL - diverged: local HEAD changed despite refusal ($before_local_head -> $after_local_head)"; fail=1
fi

# =============================================================================
# Dirty tree: an uncommitted change present -> refused BEFORE any
# ref/fetch-comparison work touches anything.
# =============================================================================
origin_dirty="$(mk_origin dirty)"
git clone -q "$origin_dirty" "$FIXTURE/dirty" >/dev/null 2>&1
echo scratch > "$FIXTURE/dirty/scratch.txt"
before_local_head="$(git -C "$FIXTURE/dirty" rev-parse HEAD)"

TASKS_DIR="$FIXTURE/dirty"
out="$(cmd_sync 2>&1)"; rc=$?
assert "dirty: non-zero exit" '^' "$rc-fail"; [ "$rc" -ne 0 ] || { echo "FAIL - exit $rc"; fail=1; }
assert "dirty: clear error" 'is dirty' "$out"
after_local_head="$(git -C "$FIXTURE/dirty" rev-parse HEAD)"
if [ "$after_local_head" = "$before_local_head" ]; then
  echo "ok   - dirty: local HEAD untouched"
else
  echo "FAIL - dirty: local HEAD changed despite the dirty guard"; fail=1
fi
[ -f "$FIXTURE/dirty/scratch.txt" ] \
  && echo "ok   - dirty: untracked scratch file still present (untouched)" \
  || { echo "FAIL - dirty: scratch file vanished"; fail=1; }

# =============================================================================
# Fetch failure: origin points at an unreachable path -> loud abort (not a
# silent no-op comparing against stale refs).
# =============================================================================
origin_fetchfail="$(mk_origin fetchfail)"
git clone -q "$origin_fetchfail" "$FIXTURE/fetchfail" >/dev/null 2>&1
git -C "$FIXTURE/fetchfail" remote set-url origin "$FIXTURE/does-not-exist.git"

TASKS_DIR="$FIXTURE/fetchfail"
out="$(cmd_sync 2>&1)"; rc=$?
assert "fetch failure: non-zero exit" '^' "$rc-fail"; [ "$rc" -ne 0 ] || { echo "FAIL - exit $rc"; fail=1; }
assert "fetch failure: clear abort message" 'fetch.*failed' "$out"

# =============================================================================
# Detached HEAD -> refused (H23), never fast-forward-merges into a detached
# state.
# =============================================================================
origin_detached="$(mk_origin detached)"
git clone -q "$origin_detached" "$FIXTURE/detached" >/dev/null 2>&1
git -C "$FIXTURE/detached" checkout -q --detach

TASKS_DIR="$FIXTURE/detached"
out="$(cmd_sync 2>&1)"; rc=$?
assert "detached HEAD: non-zero exit" '^' "$rc-fail"; [ "$rc" -ne 0 ] || { echo "FAIL - exit $rc"; fail=1; }
assert "detached HEAD: clear error" 'detached HEAD' "$out"

# =============================================================================
# Checked out on some OTHER branch than the tracked default -> refused
# (H23), naming both the actual and expected branch.
# =============================================================================
origin_wrongbranch="$(mk_origin wrongbranch)"
git clone -q "$origin_wrongbranch" "$FIXTURE/wrongbranch" >/dev/null 2>&1
git -C "$FIXTURE/wrongbranch" checkout -q -b other-branch

TASKS_DIR="$FIXTURE/wrongbranch"
out="$(cmd_sync 2>&1)"; rc=$?
assert "wrong branch: non-zero exit" '^' "$rc-fail"; [ "$rc" -ne 0 ] || { echo "FAIL - exit $rc"; fail=1; }
assert "wrong branch: names the actual branch" "on 'other-branch'" "$out"
assert "wrong branch: names the tracked default branch" "not '$DEFAULT_BRANCH'" "$out"

[ "$fail" -eq 0 ] && echo "ALL PASS" || echo "FAILURES"
exit "$fail"
