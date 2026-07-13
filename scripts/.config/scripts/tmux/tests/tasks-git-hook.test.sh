#!/usr/bin/env bash
# Tests for the reference-transaction hook (U6, H9-H17 of the tasks-dir
# concurrency-safety plan) -- the native git hook that vetoes any LOCAL
# branch-ref update which would orphan a commit reachable from nowhere
# else, regardless of what typed the git command (raw terminal, an agent's
# Bash tool, anything -- that's the whole point of it being a real git
# hook and not a Claude-Code-specific one).
#
# Every scenario below builds its OWN throwaway fixture repo (and its own
# throwaway $HOME, so the hook's hardcoded-by-default
# $HOME/code/tasks/.git/WB_ALLOW_REWIND and
# $XDG_STATE_HOME/wb/disable-git-hook paths never resolve to anything real)
# via mk_fixture_home/mk_fixture_repo below. NONE of this ever touches a
# real checkout.
#
# Run: bash scripts/.config/scripts/tmux/tests/tasks-git-hook.test.sh
# Sandboxed:
#   docker build -t wb-tests -f scripts/.config/scripts/tmux/tests/Dockerfile .
#   docker run --rm -v "$(pwd)":/repo:ro -w /repo wb-tests \
#     bash scripts/.config/scripts/tmux/tests/tasks-git-hook.test.sh
set -uo pipefail

HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../tasks-git-hooks" && pwd)"
HOOK="$HOOK_DIR/reference-transaction"

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
assert_not() { # <desc> <not-expected-regex> <actual>
  if printf '%s' "$3" | grep -qE "$2"; then
    echo "FAIL - $1"
    echo "       should NOT match: $2"
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

# --- fixture-repo helpers, built FIRST per the plan's execution note --------
# ("every scenario is a tiny scratch repo; none may touch a real checkout")

FIXTURES=()
cleanup() {
  local d
  for d in "${FIXTURES[@]:-}"; do
    [ -n "$d" ] && rm -rf "$d"
  done
}
trap cleanup EXIT

mk_fixture_home() { # -> prints path to a fresh throwaway HOME
  local h
  h="$(mktemp -d -t tasks-git-hook-home.XXXXXX)"
  FIXTURES+=("$h")
  printf '%s' "$h"
}

mk_fixture_repo() { # <home> -> prints path to a fresh repo: hook wired in
                     # via core.hooksPath, HEAD on `development`, one base
                     # commit. <home> is used for the base commit itself
                     # (it invokes the hook too -- old is zero, H14 allows
                     # it unconditionally -- but must still never resolve
                     # to a real $HOME along the way).
  local home="$1" repo
  repo="$(mktemp -d -t tasks-git-hook-repo.XXXXXX)"
  FIXTURES+=("$repo")
  git init -q -b development "$repo"
  git -C "$repo" config user.email t@t
  git -C "$repo" config user.name t
  git -C "$repo" config core.hooksPath "$HOOK_DIR"
  echo base > "$repo/base.txt"
  git -C "$repo" add base.txt
  HOME="$home" git -C "$repo" commit -q -m base </dev/null
  printf '%s' "$repo"
}

# run_git <home> <repo> <git-args...>
# Always runs with HOME pointed at the fixture (isolating the hook's
# sentinel/kill-switch lookups from anything real) and stdin closed (so no
# git subcommand can ever accidentally inherit a real pipe as fd 0 across
# the read loop this test drives). Captures combined stdout+stderr and
# returns the exit code via $?.
run_git() {
  local home="$1" repo="$2"; shift 2
  HOME="$home" timeout 10 git -C "$repo" "$@" </dev/null
}

commit_file() { # <home> <repo> <name> <content> <message>
  local home="$1" repo="$2" name="$3" content="$4" msg="$5"
  printf '%s\n' "$content" > "$repo/$name"
  HOME="$home" git -C "$repo" add "$name" </dev/null
  HOME="$home" git -C "$repo" commit -q -m "$msg" </dev/null
}

write_sentinel() { # <tasks-dir> <epoch> <reason>
  local tdir="$1" epoch="$2" reason="$3"
  mkdir -p "$tdir/.git"
  printf '%s %s\n' "$epoch" "$reason" > "$tdir/.git/WB_ALLOW_REWIND"
}

echo "=== H15 self-check: /dev/tty in this test environment ==="
# Re-verifying, from literally inside this test's own process tree, the
# same fact the plan already verified live from a Claude Code Bash call on
# 2026-07-11: no fd is a tty, and /dev/tty does not open. This is what lets
# H15 degrade to "just refuse" instead of ever risking a hang.
for fd in 0 1 2; do
  if [ -t "$fd" ]; then
    echo "note - fd $fd IS a tty in this test process"
  else
    echo "ok   - fd $fd is not a tty in this test process"
  fi
done
if { exec 9<"/dev/tty"; } 2>/dev/null; then
  exec 9<&-
  echo "note - /dev/tty DID open for reading in this test environment"
else
  echo "ok   - /dev/tty does not open for reading in this test environment (matches the 2026-07-11 live verification)"
fi

# =============================================================================
echo
echo "=== ordinary operations: zero refusal, zero output ==="
# =============================================================================

HOME1="$(mk_fixture_home)"
REPO1="$(mk_fixture_repo "$HOME1")"

out="$(commit_file "$HOME1" "$REPO1" f1.txt one "commit 1" 2>&1)"
assert_eq "ordinary commit: no hook output" "" "$out"

out="$(commit_file "$HOME1" "$REPO1" f1.txt two "commit 2" 2>&1)"
assert_eq "ordinary second commit: no hook output" "" "$out"

out="$(run_git "$HOME1" "$REPO1" checkout -q -b feature-a 2>&1)"; rc=$?
assert_eq "new branch creation: exit 0" 0 "$rc"
assert_eq "new branch creation: no hook output" "" "$out"

out="$(commit_file "$HOME1" "$REPO1" f2.txt on-feature "feature commit" 2>&1)"
assert_eq "commit on new branch: no hook output" "" "$out"

out="$(run_git "$HOME1" "$REPO1" checkout -q development 2>&1)"
out="$(run_git "$HOME1" "$REPO1" merge -q --no-ff -m "merge feature-a" feature-a 2>&1)"; rc=$?
assert_eq "merge: exit 0" 0 "$rc"
assert_eq "merge: no hook output" "" "$out"

out="$(run_git "$HOME1" "$REPO1" checkout -q -b feature-b 2>&1)"
out="$(commit_file "$HOME1" "$REPO1" f3.txt on-feature-b "feature-b commit" 2>&1)"
out="$(run_git "$HOME1" "$REPO1" checkout -q development 2>&1)"
out="$(run_git "$HOME1" "$REPO1" merge -q --ff-only feature-b 2>&1)"; rc=$?
assert_eq "fast-forward merge: exit 0" 0 "$rc"
assert_eq "fast-forward merge: no hook output" "" "$out"

out="$(run_git "$HOME1" "$REPO1" tag v1.0 2>&1)"; rc=$?
assert_eq "tag creation: exit 0" 0 "$rc"
assert_eq "tag creation: no hook output" "" "$out"

# fast-forward "pull": a bare remote, push development, then advance the
# remote independently and fetch + merge --ff-only locally.
REMOTE1="$(mktemp -d -t tasks-git-hook-remote.XXXXXX)"; FIXTURES+=("$REMOTE1")
git init -q --bare "$REMOTE1"
out="$(run_git "$HOME1" "$REPO1" remote add origin "$REMOTE1" 2>&1)"
out="$(run_git "$HOME1" "$REPO1" push -q origin development 2>&1)"
CLONE1="$(mktemp -d -t tasks-git-hook-clone.XXXXXX)"; FIXTURES+=("$CLONE1")
# `-b development`, not relying on the bare remote's default HEAD symref:
# a fresh `git init --bare` defaults its HEAD to refs/heads/master (or
# main) regardless of what branch got pushed into it, so an unqualified
# clone here would warn "remote HEAD refers to nonexistent ref" and leave
# CLONE1 with nothing checked out -- silently turning the "advance
# upstream" commit below into a no-op and this whole scenario into a
# false pass.
git clone -q -b development "$REMOTE1" "$CLONE1"
git -C "$CLONE1" config user.email t@t
git -C "$CLONE1" config user.name t
commit_file "$HOME1" "$CLONE1" upstream.txt from-upstream "upstream advance" >/dev/null 2>&1
HOME="$HOME1" git -C "$CLONE1" push -q origin development </dev/null

out="$(run_git "$HOME1" "$REPO1" fetch -q origin 2>&1)"; rc=$?
assert_eq "fetch (remote-tracking ref update): exit 0" 0 "$rc"
assert_eq "fetch: no hook output (refs/remotes/* is outside H10's scope)" "" "$out"

out="$(run_git "$HOME1" "$REPO1" merge -q --ff-only origin/development 2>&1)"; rc=$?
assert_eq "fast-forward pull (merge --ff-only): exit 0" 0 "$rc"
assert_eq "fast-forward pull: no hook output" "" "$out"
assert_eq "fast-forward pull: actually pulled in the upstream-only commit (not a no-op)" "yes" "$( [ -f "$REPO1/upstream.txt" ] && echo yes || echo no )"

# =============================================================================
echo
echo "=== reset --hard past an unpushed, otherwise-unreachable commit ==="
# =============================================================================

HOME2="$(mk_fixture_home)"
REPO2="$(mk_fixture_repo "$HOME2")"
commit_file "$HOME2" "$REPO2" f.txt one "c1" >/dev/null
commit_file "$HOME2" "$REPO2" f.txt two "c2" >/dev/null
c1="$(run_git "$HOME2" "$REPO2" rev-parse HEAD~1)"
c2="$(run_git "$HOME2" "$REPO2" rev-parse HEAD)"

out="$(run_git "$HOME2" "$REPO2" reset --hard "$c1" 2>&1)"; rc=$?
assert_eq "reset --hard past unreachable-elsewhere commit: refused (non-zero exit)" 1 "$( [ "$rc" -ne 0 ] && echo 1 || echo 0 )"
assert "refusal message names the ref" "REFUSING update to refs/heads/development" "$out"
assert "refusal message: index/worktree already moved warning" "ALREADY GONE by the time this hook runs" "$out"
assert "refusal message: names the safe resync command" "git reset --hard HEAD" "$out"
head_after="$(run_git "$HOME2" "$REPO2" rev-parse HEAD)"
assert_eq "post-refusal: HEAD unchanged (still c2)" "$c2" "$head_after"
worktree_content="$(cat "$REPO2/f.txt")"
assert_eq "post-refusal: working tree ALREADY moved to reset target (the surprising part)" "one" "$worktree_content"

out="$(run_git "$HOME2" "$REPO2" reset --hard HEAD 2>&1)"; rc=$?
assert_eq "post-refusal safe resync (reset --hard HEAD): exit 0" 0 "$rc"
# git's own "HEAD is now at ..." line is expected here; only the hook's
# own refusal text must be absent (old==new trivially passes the
# fast-forward check, so the hook itself stays silent).
assert_not "safe resync: no REFUSING output from the hook itself" "REFUSING" "$out"

# --- same target, but the commit IS reachable via another ref -> ALLOWED ----
HOME3="$(mk_fixture_home)"
REPO3="$(mk_fixture_repo "$HOME3")"
commit_file "$HOME3" "$REPO3" f.txt one "c1" >/dev/null
commit_file "$HOME3" "$REPO3" f.txt two "c2" >/dev/null
REMOTE3="$(mktemp -d -t tasks-git-hook-remote3.XXXXXX)"; FIXTURES+=("$REMOTE3")
git init -q --bare "$REMOTE3"
run_git "$HOME3" "$REPO3" remote add origin "$REMOTE3" >/dev/null
run_git "$HOME3" "$REPO3" push -q origin development >/dev/null 2>&1
run_git "$HOME3" "$REPO3" fetch -q origin >/dev/null 2>&1
# origin/development now points at c2 -- reachable elsewhere even after we
# reset the local branch back to c1.
out="$(run_git "$HOME3" "$REPO3" reset --hard HEAD~1 2>&1)"; rc=$?
assert_eq "reset --hard past a commit reachable via refs/remotes/origin/*: allowed (exit 0)" 0 "$rc"
assert_not "allowed reset: no REFUSING output from the hook itself" "REFUSING" "$out"

# =============================================================================
echo
echo "=== branch deletion ==="
# =============================================================================

HOME4="$(mk_fixture_home)"
REPO4="$(mk_fixture_repo "$HOME4")"

# unmerged-only branch -> its tip is reachable from nowhere else -> refused
run_git "$HOME4" "$REPO4" checkout -q -b unmerged-only >/dev/null
commit_file "$HOME4" "$REPO4" u.txt content "unmerged commit" >/dev/null
run_git "$HOME4" "$REPO4" checkout -q development >/dev/null
out="$(run_git "$HOME4" "$REPO4" branch -D unmerged-only 2>&1)"; rc=$?
assert_eq "deleting an unmerged-only branch: refused (non-zero exit)" 1 "$( [ "$rc" -ne 0 ] && echo 1 || echo 0 )"
assert "unmerged branch deletion: refusal names the ref" "refs/heads/unmerged-only" "$out"
branch_still_there="$(run_git "$HOME4" "$REPO4" branch --list unmerged-only)"
assert "unmerged branch deletion refused: branch still exists" "unmerged-only" "$branch_still_there"

# fully-merged branch -> tip reachable via development -> allowed
run_git "$HOME4" "$REPO4" checkout -q -b merged-away >/dev/null
commit_file "$HOME4" "$REPO4" m.txt content "will be merged" >/dev/null
run_git "$HOME4" "$REPO4" checkout -q development >/dev/null
run_git "$HOME4" "$REPO4" merge -q --no-ff -m "merge merged-away" merged-away >/dev/null
out="$(run_git "$HOME4" "$REPO4" branch -d merged-away 2>&1)"; rc=$?
assert_eq "deleting a fully-merged branch: allowed (exit 0)" 0 "$rc"

# deleting development itself, no sentinel -> refused (H13)
run_git "$HOME4" "$REPO4" checkout -q -b temp-holder >/dev/null
out="$(run_git "$HOME4" "$REPO4" branch -D development 2>&1)"; rc=$?
assert_eq "deleting development with no sentinel: refused (non-zero exit)" 1 "$( [ "$rc" -ne 0 ] && echo 1 || echo 0 )"
assert "development deletion refused: message present" "REFUSING update to refs/heads/development" "$out"
dev_still_there="$(run_git "$HOME4" "$REPO4" branch --list development)"
assert "development deletion refused: branch still exists" "development" "$dev_still_there"

# deleting development WITH a fresh sentinel -> allowed once, then consumed.
# Sentinel lives in the fixture REPO's own .git/ (never a separate,
# unrelated $TASKS_DIR-derived path) -- the hook resolves the sentinel via
# `git rev-parse --git-common-dir` against the repo it's actually invoked
# for, matching how a real `wb unsafe-rewind` writes it for the SAME repo
# `wb sync`/an agent's git command later operates on. A prior version of
# this test (and of the hook) used a TASKS_DIR env-var override pointed at
# an unrelated directory here -- exactly the sentinel-forgery shape a
# security review flagged: any Bash command could redirect TASKS_DIR to an
# attacker-controlled path and forge the bypass for a repo it was never
# written for.
write_sentinel "$REPO4" "$(date +%s)" "deliberate teardown"
out="$(run_git "$HOME4" "$REPO4" branch -D development 2>&1)"; rc=$?
assert_eq "deleting development WITH a fresh sentinel: allowed (exit 0)" 0 "$rc"
assert_eq "sentinel consumed: file gone afterward" "no" "$( [ -f "$REPO4/.git/WB_ALLOW_REWIND" ] && echo yes || echo no )"

# =============================================================================
echo
echo "=== sentinel mechanics ==="
# =============================================================================

HOME5="$(mk_fixture_home)"
REPO5="$(mk_fixture_repo "$HOME5")"

# two independent unmerged (refusable) branches
run_git "$HOME5" "$REPO5" checkout -q -b orphan-1 >/dev/null
commit_file "$HOME5" "$REPO5" o1.txt content "orphan-1 commit" >/dev/null
run_git "$HOME5" "$REPO5" checkout -q development >/dev/null
run_git "$HOME5" "$REPO5" checkout -q -b orphan-2 >/dev/null
commit_file "$HOME5" "$REPO5" o2.txt content "orphan-2 commit" >/dev/null
run_git "$HOME5" "$REPO5" checkout -q development >/dev/null

write_sentinel "$REPO5" "$(date +%s)" "one-time rewind"
out="$(run_git "$HOME5" "$REPO5" branch -D orphan-1 2>&1)"; rc=$?
assert_eq "fresh sentinel: first refusable op in this transaction passes (exit 0)" 0 "$rc"
assert_eq "fresh sentinel: consumed after first use" "no" "$( [ -f "$REPO5/.git/WB_ALLOW_REWIND" ] && echo yes || echo no )"

out="$(run_git "$HOME5" "$REPO5" branch -D orphan-2 2>&1)"; rc=$?
assert_eq "sentinel already consumed: second refusable op in a NEW transaction is refused" 1 "$( [ "$rc" -ne 0 ] && echo 1 || echo 0 )"

# stale sentinel (epoch far older than the 120s TTL) -> treated as absent
HOME6="$(mk_fixture_home)"
REPO6="$(mk_fixture_repo "$HOME6")"
run_git "$HOME6" "$REPO6" checkout -q -b orphan-stale >/dev/null
commit_file "$HOME6" "$REPO6" os.txt content "orphan-stale commit" >/dev/null
run_git "$HOME6" "$REPO6" checkout -q development >/dev/null
stale_epoch=$(( $(date +%s) - 200 ))
write_sentinel "$REPO6" "$stale_epoch" "too old"
out="$(run_git "$HOME6" "$REPO6" branch -D orphan-stale 2>&1)"; rc=$?
assert_eq "stale sentinel (>120s old): refused, treated as absent" 1 "$( [ "$rc" -ne 0 ] && echo 1 || echo 0 )"

# =============================================================================
echo
echo "=== sentinel forgery via TASKS_DIR redirection: must NOT bypass a DIFFERENT repo's refusal ==="
# =============================================================================
# Security regression test: a fresh, otherwise-valid sentinel written to an
# UNRELATED directory, with TASKS_DIR pointed at that directory on the same
# command line as the actual dangerous git invocation, must never authorize
# a rewind against the real repo the hook is invoked for. This is exactly
# the forgery a security review found: TASKS_DIR is a plain inheritable env
# var, so `TASKS_DIR=/tmp/forged git reset --hard` (or here, branch -D)
# against a repo unrelated to /tmp/forged used to succeed if the hook
# resolved the sentinel path from that env var instead of the real repo's
# own .git dir.
HOME7="$(mk_fixture_home)"
REPO7="$(mk_fixture_repo "$HOME7")"
FORGED_DIR="$(mktemp -d -t tasks-git-hook-forged.XXXXXX)"; FIXTURES+=("$FORGED_DIR")
run_git "$HOME7" "$REPO7" checkout -q -b unmerged-forged-target >/dev/null
commit_file "$HOME7" "$REPO7" f.txt content "would be orphaned" >/dev/null
run_git "$HOME7" "$REPO7" checkout -q development >/dev/null

write_sentinel "$FORGED_DIR" "$(date +%s)" "forged -- written to an unrelated directory"
out="$(HOME="$HOME7" TASKS_DIR="$FORGED_DIR" timeout 10 git -C "$REPO7" branch -D unmerged-forged-target </dev/null 2>&1)"; rc=$?
assert_eq "forged sentinel (wrong repo, via TASKS_DIR): still refused (non-zero exit)" 1 "$( [ "$rc" -ne 0 ] && echo 1 || echo 0 )"
assert "forged sentinel: refusal message present" "REFUSING update to refs/heads/unmerged-forged-target" "$out"
branch_still_there="$(run_git "$HOME7" "$REPO7" branch --list unmerged-forged-target)"
assert "forged sentinel: branch still exists" "unmerged-forged-target" "$branch_still_there"
assert_eq "forged sentinel: the unrelated directory's own sentinel is untouched (never consumed)" "yes" "$( [ -f "$FORGED_DIR/.git/WB_ALLOW_REWIND" ] && echo yes || echo no )"

# =============================================================================
echo
echo "=== no TTY available: refuses without hanging, no interactive prompt ==="
# =============================================================================

HOME7="$(mk_fixture_home)"
REPO7="$(mk_fixture_repo "$HOME7")"
commit_file "$HOME7" "$REPO7" f.txt one "c1" >/dev/null
commit_file "$HOME7" "$REPO7" f.txt two "c2" >/dev/null

start_ts=$(date +%s)
out="$(run_git "$HOME7" "$REPO7" reset --hard HEAD~1 2>&1)"; rc=$?
end_ts=$(date +%s)
elapsed=$(( end_ts - start_ts ))
assert_eq "no-tty refusal: exit non-zero" 1 "$( [ "$rc" -ne 0 ] && echo 1 || echo 0 )"
assert_not "no-tty refusal: interactive prompt text never printed" "Allow this one ref update anyway" "$out"
if [ "$elapsed" -le 8 ]; then
  echo "ok   - no-tty refusal: process terminated promptly (${elapsed}s), did not hang"
else
  echo "FAIL - no-tty refusal: took ${elapsed}s -- looks like a hang"
  fail=1
fi

# =============================================================================
echo
echo "=== commit --amend on shared history: refused absent a sentinel (known, accepted false positive) ==="
# =============================================================================

HOME8="$(mk_fixture_home)"
REPO8="$(mk_fixture_repo "$HOME8")"
commit_file "$HOME8" "$REPO8" f.txt one "original message" >/dev/null
orig_tip="$(run_git "$HOME8" "$REPO8" rev-parse HEAD)"

out="$(run_git "$HOME8" "$REPO8" commit -q --amend -m "amended message" 2>&1)"; rc=$?
assert_eq "commit --amend on development: refused absent a sentinel (documented trade-off)" 1 "$( [ "$rc" -ne 0 ] && echo 1 || echo 0 )"
head_after_amend="$(run_git "$HOME8" "$REPO8" rev-parse HEAD)"
assert_eq "amend refused: HEAD unchanged (still points at the pre-amend commit)" "$orig_tip" "$head_after_amend"

echo
if [ "$fail" -eq 0 ]; then
  echo "ALL PASS"
else
  echo "FAILURES"
fi
exit "$fail"
