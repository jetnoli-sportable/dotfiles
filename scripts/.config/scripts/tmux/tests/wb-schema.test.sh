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

# --- cmd_done stamps closed:, and only kills the session behind --close -----
# cmd_done needs a live tmux session + worktree to exercise end-to-end, which
# is disproportionate to unit-test here (see wb-done.test.sh for the real
# fixture-backed coverage of the --close behavior itself). Assert the wiring
# directly, scoped to cmd_done's own function body (not an open-ended range)
# so a later, unrelated `tmux kill-session` elsewhere in the file (e.g.
# _ctrl_x's repo-kill path) can't leak in.
#
# The 2026-07-08 invariant ("sessions must survive wind-down") is opt-in now,
# not absolute: `--close` (dotfiles--feat-wb-done-close) makes the kill
# explicit rather than reverting that decision. So the guard below checks the
# real invariant — a kill-session call exists, but only ever reached behind
# the close-flag check on the same line — instead of the old blanket
# no-kill-session-anywhere assertion, which the gated call would now
# (correctly) fail.
done_block="$(awk '/^cmd_done\(\) \{/{p=1} p{print} p&&/^}/{exit}' "$WB")"
assert "cmd_done stamps status done" 'status done' "$done_block"
assert "cmd_done stamps closed: date" 'wb_set_frontmatter "\$task_file" closed "\$\(date \+%F\)"' "$done_block"
assert "cmd_done's kill-session is gated behind the close flag" \
  '\[ "\$close" -eq 1 \] && tmux kill-session' "$done_block"

kill_lines="$(printf '%s' "$done_block" | grep -c 'tmux kill-session' || true)"
if [ "$kill_lines" -eq 1 ]; then
  echo "ok   - cmd_done has exactly one kill-session call, and it's gated"
else
  echo "FAIL - cmd_done has $kill_lines kill-session call(s); expected exactly 1 (gated behind --close)"; fail=1
fi

# --- parent: schema (U1: wb_seed_task threading + wb_resolve_parent_ref) ----
# shellcheck disable=SC1090
source "$WB"
set +e   # wb.sh sets -e; this test intentionally captures non-zero exits
TASKS_DIR="$FIXTURE"

# wb_seed_task's new-file branch reads $TASKS_DIR/TEMPLATE.md — fixture one
# with the parent: line, same position TEMPLATE.md now carries it.
printf -- '---\nstatus: planned\nrepo:\nbranch:\nworktree:\nparent:\ntags: []\ncreated:\nclosed:\n---\n# Title\n\n## Plan\n\n## Done\n\n## Follow-ups\n\n## Decisions\n' \
  > "$FIXTURE/TEMPLATE.md"

mk_task 'proj--existing.md' doing proj 'Existing Task'

# wb_resolve_parent_ref — exists / doesn't exist
out="$(wb_resolve_parent_ref 'proj--existing' 2>&1)"; rc=$?
assert "wb_resolve_parent_ref: existing ref exits 0" '^' "$rc-ok"; [ "$rc" -eq 0 ] || { echo "FAIL - exit $rc: $out"; fail=1; }
assert "wb_resolve_parent_ref: prints the task file path" 'proj--existing\.md$' "$out"

out="$(wb_resolve_parent_ref 'proj--nonexistent' 2>&1)"; rc=$?
assert "wb_resolve_parent_ref: missing ref exits non-zero" '^' "$rc-fail"; [ "$rc" -ne 0 ] || { echo "FAIL - exit $rc"; fail=1; }
assert "wb_resolve_parent_ref: missing ref gives a clear error" "no matching task file" "$out"

# wb_seed_task (new file) — --parent value lands in the created file
new_file="$(wb_seed_task proj feat/child .worktrees/feat/child 'proj--existing')"
assert "wb_seed_task (new file): parent: set" '^proj--existing$' "$(wb_get_frontmatter "$new_file" parent)"

# wb_seed_task (existing file) — a blank parent: line gets filled in without
# disturbing other fields. Must already carry a parent: line (post-migration
# shape) — wb_set_frontmatter only overwrites an existing line, it can't
# insert one; mk_task's fixture template predates this field, so build this
# fixture by hand instead of via mk_task.
printf -- '---\nstatus: doing\nrepo: proj\nbranch: b\nworktree: .worktrees/x\nparent:\ntags: []\ncreated: 2026-07-07\nclosed:\n---\n# Fill Me\n' \
  > "$FIXTURE/proj--fillme.md"
wb_seed_task proj fillme .worktrees/fillme 'proj--existing' >/dev/null
assert "wb_seed_task (existing file): parent: filled in" '^proj--existing$' "$(wb_get_frontmatter "$FIXTURE/proj--fillme.md" parent)"
assert "wb_seed_task (existing file): other fields untouched" '^doing$' "$(wb_get_frontmatter "$FIXTURE/proj--fillme.md" status)"

# wb_seed_task — no parent given: field stays blank, no regression
printf -- '---\nstatus: doing\nrepo: proj\nbranch: b\nworktree: .worktrees/x\nparent:\ntags: []\ncreated: 2026-07-07\nclosed:\n---\n# No Parent\n' \
  > "$FIXTURE/proj--noparent.md"
wb_seed_task proj noparent .worktrees/noparent >/dev/null
# not via assert()'s regex match: its printf '%s' (no trailing newline) means
# an empty string is zero lines, and '^$' never matches zero lines.
if [ -z "$(wb_get_frontmatter "$FIXTURE/proj--noparent.md" parent)" ]; then
  echo "ok   - wb_seed_task: no --parent leaves parent: blank"
else
  echo "FAIL - wb_seed_task: no --parent leaves parent: blank"; fail=1
fi

# --- cmd_new --parent wiring (source-text assertions) -----------------------
# cmd_new needs a live tmux session + real git worktree to exercise
# end-to-end — disproportionate to unit-test the --parent slice specifically
# (same reasoning as cmd_done's wiring assertions above).
new_block="$(awk '/^cmd_new\(\) \{/{p=1} p{print} p&&/^}/{exit}' "$WB")"
assert "cmd_new: --parent consumes its value as a separate token" 'parent_ref="\$2"; shift 2' "$new_block"
assert "cmd_new: validates the parent ref" 'wb_resolve_parent_ref "\$parent_ref"' "$new_block"
assert "cmd_new: threads parent_ref into wb_seed_task" 'wb_seed_task "\$repo" "\$slug" "\$worktree_rel" "\$parent_ref"' "$new_block"
if printf '%s' "$new_block" | grep -qPzo 'wb_resolve_parent_ref[\s\S]*is not a git repo'; then
  echo "ok   - cmd_new: --parent validated before the worktree/git-repo check"
else
  echo "FAIL - cmd_new: --parent validation must run before touching the repo"; fail=1
fi

[ "$fail" -eq 0 ] && echo "ALL PASS" || echo "FAILURES"
exit "$fail"
