#!/usr/bin/env bash
# Tests for `wb board` — plain-bash assertions against a fixture store.
# Run: bash scripts/.config/scripts/tmux/tests/wb-board.test.sh
set -uo pipefail

WB="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/wb.sh"
FIXTURE="$(mktemp -d -t wb-board-fixture.XXXXXX)"
TMUX_STUB_BIN="$(mktemp -d -t wb-board-tmux-stub.XXXXXX)"
trap 'rm -rf "$FIXTURE" "$TMUX_STUB_BIN"' EXIT

# `wb board` is invoked as a fresh `bash "$WB"` subprocess below (not
# sourced), so stubbing wb_live_agent_count directly (the wb-lifecycle.test.sh
# `save_fn`/redefine convention) wouldn't survive the process boundary — a
# fake `tmux` on PATH answering the `list-panes -a` call it makes gets the
# same effect and works across subprocess boundaries. wb_live_agent_count
# queries `-F '#{pane_current_command}'` only (deliberately not routed
# through tmux_claude_panes' heavier per-pane classification — see lib.sh),
# so each FAKE_PANE_ROWS line is just the bare command name.
cat > "$TMUX_STUB_BIN/tmux" <<'STUB'
#!/usr/bin/env bash
if [ "${1:-}" = "list-panes" ]; then
  printf '%s\n' "${FAKE_PANE_ROWS:-}"
fi
STUB
chmod +x "$TMUX_STUB_BIN/tmux"

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

mk_task() { # <file> <status> <repo> <title> <n-followups>
  local f="$FIXTURE/$1"
  {
    printf -- '---\nstatus: %s\nrepo: %s\nbranch: b\nworktree: .worktrees/x\ntags: []\ncreated: 2026-07-07\n---\n' "$2" "$3"
    [ -n "$4" ] && printf '# %s\n\n' "$4"
    printf '## Plan\n\n## Done\n\n'
    if [ "$5" -gt 0 ]; then
      printf '## Follow-ups\n\n'
      for _ in $(seq 1 "$5"); do printf -- '- a follow-up\n'; done
      printf '\n'
    fi
    printf '## Decisions\n'
  } > "$f"
}

# --- fixtures ---------------------------------------------------------------
mk_task 'dotfiles--alpha.md'      doing    dotfiles      'Alpha Task'   2
mk_task 'dotfiles--commented.md'  'review    # flip to done once merged' dotfiles 'Commented Task' 0
mk_task 'dotfiles--beta.md'       planned  dotfiles      'Beta Task'    0
mk_task 'be--monorepo--gamma.md'  review   be--monorepo  'Gamma Task'   3
mk_task 'dotfiles--delta.md'      done     dotfiles      ''             1   # no title -> slug fallback
printf '# Not a task\n' > "$FIXTURE/README.md"                               # must be excluded
printf '# Template\n'   > "$FIXTURE/TEMPLATE.md"                             # must be excluded

out="$(TASKS_DIR="$FIXTURE" bash "$WB" board 2>&1)"
rc=$?

# --- assertions -------------------------------------------------------------
assert "exits 0" '^' "$rc-ok"; [ "$rc" -eq 0 ] || { echo "FAIL - exit code $rc"; fail=1; }
assert "header row present"            'STATUS +REPO +TASK +FOLLOW-UPS' "$out"
assert "doing row with count"          'doing +dotfiles +Alpha Task +2' "$out"
assert "review row"                    'review +be--monorepo +Gamma Task +3' "$out"
assert "planned row, zero follow-ups"  'planned +dotfiles +Beta Task +0' "$out"
assert "titleless row falls back to slug" 'done +dotfiles +dotfiles--delta +1' "$out"
assert "inline frontmatter comment stripped" 'review +dotfiles +Commented Task +0' "$out"

# status ordering: doing < review < planned < done (line-number comparison)
l_doing=$(printf '%s\n' "$out"   | grep -n '^doing '   | cut -d: -f1 | head -1)
l_review=$(printf '%s\n' "$out"  | grep -n '^review '  | cut -d: -f1 | head -1)
l_planned=$(printf '%s\n' "$out" | grep -n '^planned ' | cut -d: -f1 | head -1)
l_done=$(printf '%s\n' "$out"    | grep -n '^done '    | cut -d: -f1 | head -1)
if [ "$l_doing" -lt "$l_review" ] && [ "$l_review" -lt "$l_planned" ] && [ "$l_planned" -lt "$l_done" ]; then
  echo "ok   - status ordering doing<review<planned<done"
else
  echo "FAIL - status ordering ($l_doing,$l_review,$l_planned,$l_done)"; fail=1
fi

# README/TEMPLATE excluded
if printf '%s' "$out" | grep -q 'Not a task\|Template'; then
  echo "FAIL - README/TEMPLATE leaked into board"; fail=1
else
  echo "ok   - README/TEMPLATE excluded"
fi

# --- live-agent count (U3, R7) -----------------------------------------------
out_agents3="$(TASKS_DIR="$FIXTURE" PATH="$TMUX_STUB_BIN:$PATH" \
  FAKE_PANE_ROWS=$'claude\nclaude\nclaude' \
  bash "$WB" board 2>&1)"
assert "board shows live-agent count" 'live agents: 3' "$out_agents3"

out_agents0="$(TASKS_DIR="$FIXTURE" PATH="$TMUX_STUB_BIN:$PATH" FAKE_PANE_ROWS='' bash "$WB" board 2>&1)"
rc_agents0=$?
assert "board with zero live agents" 'live agents: 0' "$out_agents0"
[ "$rc_agents0" -eq 0 ] || { echo "FAIL - zero-agents board exited $rc_agents0"; fail=1; }

# empty store
empty="$(mktemp -d -t wb-board-empty.XXXXXX)"
out_empty="$(TASKS_DIR="$empty" bash "$WB" board 2>&1)"
assert "empty store message" 'no tasks' "$out_empty"
rmdir "$empty"

[ "$fail" -eq 0 ] && echo "ALL PASS" || echo "FAILURES"
exit "$fail"
