#!/usr/bin/env bash
# Tests for the `paused` status + `closed:` field (U1) — plain-bash
# assertions against a fixture store, same convention as wb-board.test.sh.
# Run: bash scripts/.config/scripts/tmux/tests/wb-schema.test.sh
set -uo pipefail

WB="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/wb.sh"
FIXTURE="$(mktemp -d -t wb-schema-fixture.XXXXXX)"
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

mk_task() { # <file> <status> <repo> <title>
  local f="$FIXTURE/$1"
  {
    printf -- '---\nstatus: %s\nrepo: %s\nbranch: b\nworktree: .worktrees/x\ntags: []\ncreated: 2026-07-07\nclosed:\n---\n' "$2" "$3"
    [ -n "$4" ] && printf '# %s\n\n' "$4"
    printf '## Plan\n\n## Done\n\n## Follow-ups\n\n## Decisions\n'
  } > "$f"
}

# --- cmd_board ranks paused between review and planned ----------------------
mk_task 'dotfiles--a.md' doing   dotfiles 'Doing Task'
mk_task 'dotfiles--b.md' review  dotfiles 'Review Task'
mk_task 'dotfiles--c.md' paused  dotfiles 'Paused Task'
mk_task 'dotfiles--d.md' planned dotfiles 'Planned Task'
mk_task 'dotfiles--e.md' done    dotfiles 'Done Task'

out="$(TASKS_DIR="$FIXTURE" bash "$WB" board 2>&1)"
assert "paused row renders" 'paused +dotfiles +Paused Task' "$out"

l_review=$(printf '%s\n' "$out"  | grep -n '^review '  | cut -d: -f1 | head -1)
l_paused=$(printf '%s\n' "$out"  | grep -n '^paused '  | cut -d: -f1 | head -1)
l_planned=$(printf '%s\n' "$out" | grep -n '^planned ' | cut -d: -f1 | head -1)
if [ "$l_review" -lt "$l_paused" ] && [ "$l_paused" -lt "$l_planned" ]; then
  echo "ok   - status ordering review<paused<planned"
else
  echo "FAIL - status ordering ($l_review,$l_paused,$l_planned)"; fail=1
fi

# --- cmd_done stamps closed: -------------------------------------------------
# cmd_done needs a live tmux session + worktree to exercise end-to-end, which
# is disproportionate to unit-test here (see wb-resume.test.sh / wb-reconcile
# .test.sh for the tmux/gh-fixture pattern this project uses when that's
# warranted). Assert the wiring directly: the status-done and closed-date
# stamps must be adjacent so a done task is never left with a blank closed:.
done_block="$(awk '/wb_set_frontmatter "\$task_file" status done/,/tmux kill-session/' "$WB")"
assert "cmd_done stamps status done" 'status done' "$done_block"
assert "cmd_done stamps closed: date" 'wb_set_frontmatter "\$task_file" closed "\$\(date \+%F\)"' "$done_block"

[ "$fail" -eq 0 ] && echo "ALL PASS" || echo "FAILURES"
exit "$fail"
