#!/usr/bin/env bash
# Tests for replay-refusals.sh (U9, X7 of the tasks-dir concurrency-safety
# plan) -- the standalone, read-only tool that approximates what the
# reference-transaction hook (U6) would have refused, replayed against a
# repo's real reflog HISTORY via per-ref time-slicing. This is the gate
# that must be run, read by a human, and confirmed BEFORE the git-side hook
# is ever enabled for real.
#
# Every scenario below builds its OWN throwaway fixture repo (mktemp -d)
# and its OWN throwaway HOME/XDG_STATE_HOME (mktemp -d, via new_env below)
# -- this file NEVER touches the real ~/code/tasks checkout, the real
# ~/.local/state/wb/replay-passed marker, or the real
# ~/.local/state/wb/disable-git-hook switch file. Every invocation either
# passes --repo explicitly or points TASKS_DIR at a fixture, and HOME
# always resolves to a fixture too, so even a hypothetical fallback path
# could never reach anything real.
#
# Run: bash scripts/.config/scripts/tmux/tests/tasks-replay.test.sh
# Sandboxed:
#   docker build -t wb-tests -f scripts/.config/scripts/tmux/tests/Dockerfile .
#   docker run --rm -v "$(pwd)":/repo:ro -w /repo wb-tests \
#     bash scripts/.config/scripts/tmux/tests/tasks-replay.test.sh
set -uo pipefail

HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../tasks-git-hooks" && pwd)"
SCRIPT="$HOOK_DIR/replay-refusals.sh"

fail=0
assert() { # <desc> <expected-regex> <actual>
  if printf '%s' "$3" | grep -qE "$2"; then
    echo "ok   - $1"
  else
    echo "FAIL - $1"
    echo "       expected match: $2"
    echo "       got: $(printf '%s' "$3" | head -12)"
    fail=1
  fi
}
assert_not() { # <desc> <not-expected-regex> <actual>
  if printf '%s' "$3" | grep -qE "$2"; then
    echo "FAIL - $1"
    echo "       should NOT match: $2"
    echo "       got: $(printf '%s' "$3" | head -12)"
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

if [ ! -x "$SCRIPT" ]; then
  echo "FAIL - sanity: replay-refusals.sh not found/executable at $SCRIPT -- cannot run this suite"
  exit 1
fi
bash -n "$SCRIPT" || { echo "FAIL - sanity: replay-refusals.sh fails bash -n"; exit 1; }

# --- fixture helpers ---------------------------------------------------------

FIXTURES=()
cleanup() {
  local d
  for d in "${FIXTURES[@]:-}"; do
    [ -n "$d" ] && rm -rf "$d"
  done
}
trap cleanup EXIT

# new_env -- fresh throwaway HOME + XDG_STATE_HOME for the NEXT script
# invocation(s). Exported so the script (which honors the same
# override-safe ${XDG_STATE_HOME:-$HOME/.local/state} convention as
# reference-transaction/wb.sh) can never resolve the marker path to
# anything real.
new_env() {
  FIXTURE_HOME="$(mktemp -d -t tasks-replay-home.XXXXXX)"; FIXTURES+=("$FIXTURE_HOME")
  FIXTURE_STATE="$(mktemp -d -t tasks-replay-state.XXXXXX)"; FIXTURES+=("$FIXTURE_STATE")
  export HOME="$FIXTURE_HOME" XDG_STATE_HOME="$FIXTURE_STATE"
}

mk_fixture_repo() { # -> prints path to a fresh repo, HEAD on development, reflogs on (default)
  local repo
  repo="$(mktemp -d -t tasks-replay-repo.XXXXXX)"
  FIXTURES+=("$repo")
  git init -q -b development "$repo"
  git -C "$repo" config user.email t@t
  git -C "$repo" config user.name t
  printf '%s' "$repo"
}

mk_fixture_repo_no_reflog() { # -> like mk_fixture_repo, but reflogs disabled from the start
  local repo
  repo="$(mktemp -d -t tasks-replay-repo.XXXXXX)"
  FIXTURES+=("$repo")
  git init -q -b development "$repo"
  git -C "$repo" config user.email t@t
  git -C "$repo" config user.name t
  git -C "$repo" config core.logAllRefUpdates false
  printf '%s' "$repo"
}

commit_file() { # <repo> <name> <content> <message>
  local repo="$1" name="$2" content="$3" msg="$4"
  printf '%s\n' "$content" > "$repo/$name"
  git -C "$repo" add "$name"
  git -C "$repo" commit -q -m "$msg"
}

# =============================================================================
echo "=== a rewind past an unpushed commit, no other ref anywhere -> REFUSE ==="
# =============================================================================
# Mirrors incidents 2/3's shape: a lone branch, `reset --hard` past a commit
# that, at that historical moment, no other ref's time-sliced position
# could reach.

new_env
REPO1="$(mk_fixture_repo)"
commit_file "$REPO1" f.txt one "c1"
sleep 1
commit_file "$REPO1" f.txt two "c2"
sleep 1
git -C "$REPO1" reset -q --hard HEAD~1

out1="$(bash "$SCRIPT" --repo "$REPO1" 2>&1)"; rc1=$?
assert_eq "solo rewind: script exits 0 (a reporting tool, not a gate -- REFUSE is a legible finding, not a script error)" 0 "$rc1"
assert "solo rewind: REFUSE line printed naming refs/heads/development" "^REFUSE - refs/heads/development" "$out1"
assert "solo rewind: reason names the orphaned commit with no other-ref coverage" "orphaned, none reachable from any other ref" "$out1"
assert "solo rewind: orphaned commit's own subject line included for legibility" "\bc2\b" "$out1"
assert "solo rewind: summary tallies exactly 1 refusal" "REFUSE: 1" "$out1"
assert "solo rewind: summary tallies 0 allows" "ALLOW: 0" "$out1"
assert "solo rewind: summary lists which ref/transition was refused" "^ +- refs/heads/development" "$out1"

# =============================================================================
echo
echo "=== a rewind to a commit reachable via ANOTHER ref at that historical moment -> ALLOW ==="
# =============================================================================
# A second branch already points at/through the target commit BEFORE the
# rewind happens -- even though this is still a non-fast-forward transition
# on the ref being examined, the time-sliced reachability check must find
# it covered.

new_env
REPO2="$(mk_fixture_repo)"
commit_file "$REPO2" f.txt one "c1"
sleep 1
commit_file "$REPO2" f.txt two "c2"
sleep 1
git -C "$REPO2" branch safety   # created BEFORE the rewind, still pointing at c2
sleep 1
git -C "$REPO2" reset -q --hard HEAD~1

out2="$(bash "$SCRIPT" --repo "$REPO2" 2>&1)"; rc2=$?
assert_eq "reachable-elsewhere rewind: exits 0" 0 "$rc2"
assert "reachable-elsewhere rewind: ALLOW line printed for the non-fast-forward transition" "^ALLOW +- refs/heads/development" "$out2"
assert "reachable-elsewhere rewind: reason names the covering ref and its time-slice" "reachable via refs/heads/safety at time-slice" "$out2"
assert "reachable-elsewhere rewind: summary tallies 0 refusals" "REFUSE: 0" "$out2"
assert "reachable-elsewhere rewind: summary tallies 1 allow" "ALLOW: 1" "$out2"

# =============================================================================
echo
echo "=== fast-forward-only history -> zero refusals, FF short-circuit proven to have actually run ==="
# =============================================================================

new_env
REPO3="$(mk_fixture_repo)"
commit_file "$REPO3" f.txt one "c1"
commit_file "$REPO3" f.txt two "c2"
commit_file "$REPO3" f.txt three "c3"
git -C "$REPO3" checkout -q -b feature
commit_file "$REPO3" f2.txt x "feature commit"
git -C "$REPO3" checkout -q development
git -C "$REPO3" merge -q --ff-only feature

out3="$(bash "$SCRIPT" --repo "$REPO3" 2>&1)"; rc3=$?
assert_eq "ff-only history: exits 0" 0 "$rc3"
assert_not "ff-only history: no REFUSE lines anywhere" "^REFUSE" "$out3"
assert_not "ff-only history: no ALLOW verdict lines either (nothing non-fast-forward to allow)" "^ALLOW  -" "$out3"
assert "ff-only history: summary explicitly states 0 non-fast-forward transitions examined" "non-fast-forward transitions examined: 0" "$out3"
# Prove the FF short-circuit itself actually ran (not just "nothing
# happened to be flagged") -- a non-zero fast-forward count in the summary,
# from a history with several real commits and a fast-forward merge.
ff_count="$(printf '%s\n' "$out3" | grep -oE 'fast-forwards skipped \(not printed individually\): [0-9]+' | grep -oE '[0-9]+$')"
if [ -n "$ff_count" ] && [ "$ff_count" -gt 0 ]; then
  echo "ok   - ff-only history: fast-forwards skipped count is $ff_count (> 0 -- the FF short-circuit demonstrably ran)"
else
  echo "FAIL - ff-only history: fast-forwards skipped count missing or zero (got '$ff_count') -- can't tell the FF path ran vs. nothing happened"
  fail=1
fi

# =============================================================================
echo
echo "=== empty reflog (reflogs disabled from repo creation) -> clean no-op, explicit bias-allow notice ==="
# =============================================================================

new_env
REPO4="$(mk_fixture_repo_no_reflog)"
commit_file "$REPO4" f.txt one "c1"

out4="$(bash "$SCRIPT" --repo "$REPO4" 2>&1)"; rc4=$?
assert_eq "empty reflog: exits 0" 0 "$rc4"
assert "empty reflog: explicit NOTICE naming the affected ref" "NOTICE - refs/heads/development has no reflog entries" "$out4"
assert "empty reflog: NOTICE states the approximation's bias-toward-allow rationale, not a silent no-op" "biases toward ALLOWING" "$out4"
assert "empty reflog: summary tallies 1 ref with empty/no reflog" "refs with empty/no reflog \(bias-allow no-op\): 1" "$out4"
assert "empty reflog: summary tallies 0 refusals (no transitions to examine)" "REFUSE: 0" "$out4"
assert "empty reflog: summary tallies 0 non-fast-forward transitions" "non-fast-forward transitions examined: 0" "$out4"

# =============================================================================
echo
echo "=== --record-pass: writes the marker only when explicitly passed ==="
# =============================================================================

new_env
REPO5="$(mk_fixture_repo)"
commit_file "$REPO5" f.txt one "c1"
MARKER5="$XDG_STATE_HOME/wb/replay-passed"

out5_plain="$(bash "$SCRIPT" --repo "$REPO5" 2>&1)"; rc5a=$?
assert_eq "plain run: exits 0" 0 "$rc5a"
if [ ! -e "$MARKER5" ]; then
  echo "ok   - plain run (no --record-pass): marker NOT written, regardless of how clean the output looks"
else
  echo "FAIL - plain run: marker was written without --record-pass ever being passed"
  fail=1
fi
assert_not "plain run: output does not claim to have recorded a pass" "record-pass: wrote" "$out5_plain"

out5_record="$(bash "$SCRIPT" --repo "$REPO5" --record-pass 2>&1)"; rc5b=$?
assert_eq "--record-pass run: exits 0" 0 "$rc5b"
if [ -f "$MARKER5" ]; then
  echo "ok   - --record-pass: marker written"
else
  echo "FAIL - --record-pass: marker missing at $MARKER5"
  fail=1
fi
assert "--record-pass: output names the exact marker path it wrote" "record-pass: wrote $MARKER5" "$out5_record"
assert "--record-pass: output clarifies this does NOT enable the hook" "does NOT enable the hook" "$out5_record"
marker_content="$(cat "$MARKER5" 2>/dev/null)"
assert "marker file: records a repo field" "^repo: $REPO5\$" "$marker_content"
assert "marker file: records a refuse_count field" "^refuse_count: [0-9]+\$" "$marker_content"

# --record-pass must write the marker regardless of refusal count (it is
# not the script's job to decide whether refusals were "the known
# incidents" -- that's why REPO1, which DID produce a refusal above, must
# still get the marker written once a human passes the flag).
new_env
out_record_with_refusal="$(bash "$SCRIPT" --repo "$REPO1" --record-pass 2>&1)"
MARKER_R1="$XDG_STATE_HOME/wb/replay-passed"
if [ -f "$MARKER_R1" ]; then
  echo "ok   - --record-pass writes the marker even on a run that found a refusal (script never gates on the count itself)"
else
  echo "FAIL - --record-pass did not write the marker on a run with a real refusal present"
  fail=1
fi
grep -q "refuse_count: 1" "$MARKER_R1" 2>/dev/null \
  && echo "ok   - marker records the actual refuse_count (1) for later audit" \
  || { echo "FAIL - marker's refuse_count does not reflect the real finding"; fail=1; }

# =============================================================================
echo
echo "=== no --repo given: falls back to TASKS_DIR (override-safe convention, matches reference-transaction/wb.sh) ==="
# =============================================================================

new_env
REPO6="$(mk_fixture_repo)"
commit_file "$REPO6" f.txt one "c1"

out6="$(TASKS_DIR="$REPO6" bash "$SCRIPT" 2>&1)"; rc6=$?
assert_eq "TASKS_DIR fallback (no --repo): exits 0" 0 "$rc6"
assert "TASKS_DIR fallback: replayed the TASKS_DIR-pointed repo, not the fixture HOME's default" "replay-refusals: $REPO6" "$out6"

# =============================================================================
echo
if [ "$fail" -eq 0 ]; then
  echo "ALL PASS"
else
  echo "FAILURES"
fi
exit "$fail"
