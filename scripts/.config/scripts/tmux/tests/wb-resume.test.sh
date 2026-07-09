#!/usr/bin/env bash
# Tests for `wb resume <task>` (U3) — plain-bash assertions, same convention
# as wb-board.test.sh. Sources wb.sh (safe: see the BASH_SOURCE guard at the
# bottom of wb.sh) and stubs cmd_new so match resolution is tested without
# touching real git worktrees or tmux.
# Run: bash scripts/.config/scripts/tmux/tests/wb-resume.test.sh
set -uo pipefail

WB="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/wb.sh"
FIXTURE="$(mktemp -d -t wb-resume-fixture.XXXXXX)"
NEWCALL_FILE="$(mktemp -t wb-resume-newcall.XXXXXX)"
trap 'rm -rf "$FIXTURE" "$NEWCALL_FILE"' EXIT

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

mk_task() { # <file> <repo> <branch>
  local f="$FIXTURE/$1"
  printf -- '---\nstatus: doing\nrepo: %s\nbranch: %s\nworktree: .worktrees/x\ntags: []\ncreated: 2026-07-07\nclosed:\n---\n# Title\n\n## Plan\n\n## Done\n\n## Follow-ups\n\n## Decisions\n' "$2" "$3" > "$f"
}

# run_resume <query> — invokes cmd_resume via command substitution (so its
# `exit` calls only end that subshell, not this test script), storing output
# in $out and exit code in $rc. cmd_new's stub can't signal back through a
# variable (subshell assignments don't escape), so it writes to
# $NEWCALL_FILE instead — a file persists past the subshell exiting.
run_resume() {
  : > "$NEWCALL_FILE"
  out="$(cmd_resume "$1" 2>&1)"
  rc=$?
  cmd_new_calls="$(cat "$NEWCALL_FILE")"
}

# shellcheck disable=SC1090
source "$WB"
set +e   # wb.sh sets -e; this test intentionally captures non-zero exits
TASKS_DIR="$FIXTURE"

# Stub cmd_new to record its args instead of touching git/tmux.
cmd_new() { printf '%s' "$*" > "$NEWCALL_FILE"; }

# --- zero matches ------------------------------------------------------------
mk_task 'dotfiles--alpha.md' dotfiles feat/alpha
run_resume 'nonexistent'
assert "zero matches: non-zero exit" '^' "$rc-fail"; [ "$rc" -ne 0 ] || { echo "FAIL - exit code $rc"; fail=1; }
assert "zero matches: error message" "no task matches 'nonexistent'" "$out"

# --- exactly one match: delegates to cmd_new with repo + branch -------------
run_resume 'alpha'
assert "one match: exits 0" '^' "$rc-ok"; [ "$rc" -eq 0 ] || { echo "FAIL - exit code $rc: $out"; fail=1; }
assert "one match: cmd_new called with repo+branch" '^dotfiles feat/alpha$' "$cmd_new_calls"

# case-insensitive substring match
run_resume 'ALPHA'
assert "case-insensitive match" '^dotfiles feat/alpha$' "$cmd_new_calls"

# --- multiple matches: fails loudly, lists candidates ------------------------
mk_task 'dotfiles--alphabet.md' dotfiles feat/alphabet
run_resume 'alpha'
assert "multi match: non-zero exit" '^' "$rc-fail"; [ "$rc" -ne 0 ] || { echo "FAIL - exit code $rc"; fail=1; }
[ -z "$cmd_new_calls" ] && echo "ok   - multi match: does not call cmd_new" || { echo "FAIL - multi match: does not call cmd_new (got '$cmd_new_calls')"; fail=1; }
assert "multi match: lists both candidates" 'dotfiles--alpha$' "$out"
assert "multi match: lists both candidates (2)" 'dotfiles--alphabet' "$out"

# --- missing repo/branch frontmatter: fails loudly, no silent cmd_new call --
printf -- '---\nstatus: doing\nrepo:\nbranch:\nworktree:\ntags: []\ncreated: 2026-07-07\nclosed:\n---\n# Title\n' > "$FIXTURE/dotfiles--incomplete.md"
run_resume 'incomplete'
assert "incomplete frontmatter: non-zero exit" '^' "$rc-fail"; [ "$rc" -ne 0 ] || { echo "FAIL - exit code $rc"; fail=1; }
[ -z "$cmd_new_calls" ] && echo "ok   - incomplete frontmatter: does not call cmd_new" || { echo "FAIL - incomplete frontmatter: does not call cmd_new (got '$cmd_new_calls')"; fail=1; }

[ "$fail" -eq 0 ] && echo "ALL PASS" || echo "FAILURES"
exit "$fail"
