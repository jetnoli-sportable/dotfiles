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

# --- Handoffs: cmd_resume appends its own entry to the matched task file ---
# alpha's mk_task fixture already has "## Plan\n\n## Done\n\n## Follow-ups\n
# \n## Decisions\n" (no "## Handoffs" yet), so this exercises the
# missing-heading-insert-before-Decisions path. Checked right here, right
# after the single successful resume above and before any further
# run_resume call touches this same file again (the case-insensitive check
# just below re-resolves 'ALPHA' to this same task and would call
# wb_append_handoff a second time) — so the entry count asserted here is
# exactly 1, not a moving target.
alpha_file="$FIXTURE/dotfiles--alpha.md"
assert "resume: appends a ## Handoffs section" '^## Handoffs$' "$(cat "$alpha_file")"
assert "resume: entry names the command" 'Session resumed via `wb resume`\.' "$(cat "$alpha_file")"
h_line="$(grep -n '^## Handoffs$' "$alpha_file" | cut -d: -f1)"
d_line="$(grep -n '^## Decisions$' "$alpha_file" | cut -d: -f1)"
if [ -n "$h_line" ] && [ -n "$d_line" ] && [ "$h_line" -lt "$d_line" ]; then
  echo "ok   - resume: Handoffs section lands before Decisions"
else
  echo "FAIL - resume: Handoffs section should land before Decisions (h=$h_line, d=$d_line)"; fail=1
fi
entry_count="$(grep -cE '^### .* — wb resume \(auto\)$' "$alpha_file")"
if [ "$entry_count" -eq 1 ]; then
  echo "ok   - resume: exactly one Handoffs entry after one resume"
else
  echo "FAIL - resume: expected exactly 1 Handoffs entry, got $entry_count"; fail=1
fi

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

# --- Handoffs: a FRESH `wb new` must NOT gain a Handoffs entry -------------
# cmd_new is stubbed above (records args only), so this exercises the real
# task-creation path directly: wb_seed_task is what actually writes a brand
# new task file's body (from TASKS_DIR/TEMPLATE.md) — the same function
# cmd_new itself calls. The plan is explicit that the Handoffs-append call
# lives in cmd_resume's own body, never inside cmd_new/wb_seed_task, so a
# freshly-created task must come out with no "## Handoffs" section at all.
printf -- '---\nstatus: planned\nrepo:\nbranch:\nworktree:\ntags: []\ncreated:\nclosed:\n---\n# Title\n\n## Plan\n\n## Done\n\n## Follow-ups\n\n## Decisions\n' \
  > "$FIXTURE/TEMPLATE.md"
fresh_file="$(wb_seed_task dotfiles feat/brand-new .worktrees/feat/brand-new)"
if grep -q '^## Handoffs$' "$fresh_file"; then
  echo "FAIL - fresh wb new: unexpectedly gained a ## Handoffs section"; fail=1
else
  echo "ok   - fresh wb new: no ## Handoffs section (only resume adds one)"
fi

# Source-text guard: cmd_resume calls the helper, cmd_new's own body never
# does — the structural rule the runtime check above can't fully pin down
# on its own (a passing runtime check plus an absent call in cmd_new is
# what actually proves the "never from cmd_new" placement).
resume_block="$(awk '/^cmd_resume\(\) \{/{p=1} p{print} p&&/^}/{exit}' "$WB")"
new_block="$(awk '/^cmd_new\(\) \{/{p=1} p{print} p&&/^}/{exit}' "$WB")"
assert "cmd_resume: calls wb_append_handoff" 'wb_append_handoff' "$resume_block"
if printf '%s' "$new_block" | grep -q 'wb_append_handoff'; then
  echo "FAIL - cmd_new: must never call wb_append_handoff itself"; fail=1
else
  echo "ok   - cmd_new: never calls wb_append_handoff (fresh tasks stay Handoffs-free)"
fi

[ "$fail" -eq 0 ] && echo "ALL PASS" || echo "FAILURES"
exit "$fail"
