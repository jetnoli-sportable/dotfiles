#!/usr/bin/env bash
# Tests for `wb done`'s opt-in `--close` flag (dotfiles--feat-wb-done-close)
# — real fixture coverage, combining wb-pause.test.sh's real-tmux-session
# convention with wb-reconcile.test.sh's real-git-worktree convention, since
# cmd_done (unlike cmd_pause) actually removes the worktree.
#
# MUST run via the project's test Dockerfile, never bare on the host:
#   docker build -t wb-tests -f scripts/.config/scripts/tmux/tests/Dockerfile .
#   docker run --rm -v "$(pwd)":/repo:ro -w /repo wb-tests \
#     bash scripts/.config/scripts/tmux/tests/wb-done.test.sh
# This test calls real `git worktree remove` and `tmux kill-session` — the
# sandboxed runner exists specifically to contain a repeat of the
# 2026-07-10 CODE_DIR incident (see the Dockerfile's own comment).
#
# The self-resolve case (`wb done --close`, no session arg, run from inside
# the session being closed) is intentionally NOT covered here: `tmux
# kill-session` on your own session SIGHUPs the calling process, so the
# `out="$(cmd_done ...)"; rc=$?` capture pattern used throughout this suite
# cannot survive being the thing that gets killed mid-capture. Verified by
# hand instead — see the plan's Key Technical Decisions.
#
# Same constraint applies to _ctrl_x's task-case self-target guard (skip
# --close when the row IS the currently-attached session) — genuinely
# exercising it needs a real attached tmux client in the target session, not
# a bare test-runner process. wb-schema.test.sh carries a source-text guard
# for the check's presence instead; the guard's *absence* (the common case,
# where the row isn't your current session) is covered below.
set -uo pipefail

WB="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/wb.sh"
FIXTURE_CODE="$(mktemp -d -t wb-done-code.XXXXXX)"
FIXTURE_TASKS="$(mktemp -d -t wb-done-tasks.XXXXXX)"
SLUGS=(alpha beta gamma dirty delta epsilon)
session_for() { printf 'wb-done-test-%s-%s\n' "$1" "$$"; }   # <slug> -> its fixture session name
trap '
  rm -rf "$FIXTURE_CODE" "$FIXTURE_TASKS"
  for slug in "${SLUGS[@]}"; do tmux kill-session -t "=$(session_for "$slug")" 2>/dev/null || true; done
' EXIT

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

# --- fixture repo with one worktree per scenario -----------------------------
git init -q "$FIXTURE_CODE/proj"
git -C "$FIXTURE_CODE/proj" -c user.email=test@test -c user.name=test commit -q --allow-empty -m init

add_worktree() { # <slug>
  git -C "$FIXTURE_CODE/proj" worktree add -q -b "$1" ".worktrees/$1" >/dev/null 2>&1
}
mk_task() { # <slug>
  local f="$FIXTURE_TASKS/proj--$1.md"
  printf -- '---\nstatus: doing\nrepo: proj\nbranch: %s\nworktree: .worktrees/%s\ntags: []\ncreated: 2026-07-07\nclosed:\n---\n# Title\n' \
    "$1" "$1" > "$f"
}

for slug in "${SLUGS[@]}"; do
  add_worktree "$slug"
  mk_task "$slug"
done
# make the "dirty" worktree's tree dirty — an untracked file is enough for
# `git status --porcelain` to report something.
echo scratch > "$FIXTURE_CODE/proj/.worktrees/dirty/scratch.txt"

# "delta"'s task file already carries a "## Handoffs" section with a prior
# entry (e.g. from an earlier `wb pause`) — overwrite mk_task's minimal
# fixture so cmd_done's own Handoffs-append exercises the "append at the
# END of an existing section" path, not the create-from-scratch one
# wb-pause.test.sh already covers.
printf -- '---\nstatus: doing\nrepo: proj\nbranch: delta\nworktree: .worktrees/delta\ntags: []\ncreated: 2026-07-07\nclosed:\n---\n# Title\n\n## Handoffs\n\n### 2026-07-01 09:00 — wb pause (auto)\n\nSession paused via `wb pause`.\n\n## Decisions\n' \
  > "$FIXTURE_TASKS/proj--delta.md"

# "epsilon"'s task file claims repo: dotfiles (a roadmap-tracked repo, per
# KTD5) rather than "proj" — the U10 nudge fixture. Its own worktree/branch
# still live under the "proj" fixture repo since that's the only git repo
# this suite sets up; only the repo: frontmatter value (what the nudge
# actually reads) needs to say "dotfiles".
printf -- '---\nstatus: doing\nrepo: dotfiles\nbranch: epsilon\nworktree: .worktrees/epsilon\ntags: []\ncreated: 2026-07-07\nclosed:\n---\n# Title\n' \
  > "$FIXTURE_TASKS/proj--epsilon.md"

for slug in "${SLUGS[@]}"; do
  s="$(session_for "$slug")"
  tmux new-session -d -s "$s" 2>/dev/null
  tmux set-option -t "=$s:" @wb_repo proj >/dev/null
  tmux set-option -t "=$s:" @wb_slug "$slug" >/dev/null
done

# shellcheck disable=SC1090
source "$WB"
set +e   # wb.sh sets -e; this test intentionally captures non-zero exits
TASKS_DIR="$FIXTURE_TASKS"
CODE_DIR="$FIXTURE_CODE"
wb_open_buffer() { :; }   # no interactive nvim in a test run

status_of() { wb_get_frontmatter "$FIXTURE_TASKS/proj--$1.md" status; }   # <task-file-slug>; reuses wb.sh's own frontmatter reader

# --- U4 characterization: none of these fixture sessions set @task, so
# wb_session_task_file's @task-first resolution (KTD7) must fall through
# to the exact same @wb_repo/@wb_slug derivation cmd_done always used —
# byte-identical for every session that predates wb-breakdown. Asserted
# against "alpha" before the happy-path test below consumes it.
assert "U4 regression: @task-less session resolves identically to the pre-KTD7 derivation" \
  "^${FIXTURE_TASKS}/proj--alpha\\.md$" "$(wb_session_task_file "$(session_for alpha)")"

# --- happy path: plain `wb done` (no flag) leaves the session alive ---------
alpha_session="$(session_for alpha)"
out="$(cmd_done "$alpha_session" 2>&1)"; rc=$?
assert "plain done: exits 0" '^' "$rc-ok"; [ "$rc" -eq 0 ] || { echo "FAIL - exit $rc: $out"; fail=1; }
assert "plain done: confirmation message" 'closed' "$out"
if printf '%s' "$out" | grep -q 'roadmap-tracked'; then
  echo "FAIL - U10 nudge: fired for repo: proj, which isn't roadmap-tracked"; fail=1
else
  echo "ok   - U10 nudge: silent for an unrelated repo"
fi
[ -d "$FIXTURE_CODE/proj/.worktrees/alpha" ] \
  && { echo "FAIL - plain done: worktree not removed"; fail=1; } \
  || echo "ok   - plain done: worktree removed"
assert "plain done: task flipped to done" '^done$' "$(status_of alpha)"
if tmux has-session -t "=$alpha_session" 2>/dev/null; then
  echo "ok   - plain done: tmux session still alive"
else
  echo "FAIL - plain done: session was killed without --close"; fail=1
fi

# --- happy path: `wb done --close` kills the session ------------------------
beta_session="$(session_for beta)"
out="$(cmd_done "$beta_session" --close 2>&1)"; rc=$?
assert "done --close: exits 0" '^' "$rc-ok"; [ "$rc" -eq 0 ] || { echo "FAIL - exit $rc: $out"; fail=1; }
[ -d "$FIXTURE_CODE/proj/.worktrees/beta" ] \
  && { echo "FAIL - done --close: worktree not removed"; fail=1; } \
  || echo "ok   - done --close: worktree removed"
assert "done --close: task flipped to done" '^done$' "$(status_of beta)"
if tmux has-session -t "=$beta_session" 2>/dev/null; then
  echo "FAIL - done --close: session survived --close"; fail=1
else
  echo "ok   - done --close: session killed"
fi

# --- integration: picker's ctrl-x on a task row takes the close path --------
gamma_session="$(session_for gamma)"
out="$(_ctrl_x task "$gamma_session" "" 2>&1)"; rc=$?
assert "ctrl-x task: exits 0" '^' "$rc-ok"; [ "$rc" -eq 0 ] || { echo "FAIL - exit $rc: $out"; fail=1; }
[ -d "$FIXTURE_CODE/proj/.worktrees/gamma" ] \
  && { echo "FAIL - ctrl-x task: worktree not removed"; fail=1; } \
  || echo "ok   - ctrl-x task: worktree removed"
assert "ctrl-x task: task flipped to done" '^done$' "$(status_of gamma)"
if tmux has-session -t "=$gamma_session" 2>/dev/null; then
  echo "FAIL - ctrl-x task: session survived (dispatch didn't take the close path)"; fail=1
else
  echo "ok   - ctrl-x task: session killed via picker dispatch"
fi

# --- regression: a dirty worktree fails fast, --close or not ----------------
dirty_session="$(session_for dirty)"
out="$(cmd_done "$dirty_session" --close 2>&1)"; rc=$?
assert "dirty worktree: non-zero exit" '^' "$rc-fail"; [ "$rc" -ne 0 ] || { echo "FAIL - exit $rc"; fail=1; }
assert "dirty worktree: clear error" 'is dirty' "$out"
[ -d "$FIXTURE_CODE/proj/.worktrees/dirty" ] \
  && echo "ok   - dirty worktree: not removed" \
  || { echo "FAIL - dirty worktree: was removed despite dirty check"; fail=1; }
assert "dirty worktree: task NOT flipped to done" '^doing$' "$(status_of dirty)"
if tmux has-session -t "=$dirty_session" 2>/dev/null; then
  echo "ok   - dirty worktree: session untouched (dirty check runs before any kill)"
else
  echo "FAIL - dirty worktree: session was killed despite the dirty guard"; fail=1
fi


# --- Handoffs: cmd_done appends to an ALREADY-EXISTING section, in order ----
delta_session="$(session_for delta)"
delta_file="$FIXTURE_TASKS/proj--delta.md"
out="$(cmd_done "$delta_session" 2>&1)"; rc=$?
assert "handoffs done: exits 0" '^' "$rc-ok"; [ "$rc" -eq 0 ] || { echo "FAIL - exit $rc: $out"; fail=1; }
assert "handoffs done: task flipped to done" '^done$' "$(status_of delta)"

assert "handoffs done: prior entry survives" 'Session paused via `wb pause`\.' "$(cat "$delta_file")"
assert "handoffs done: new entry appended" 'Session closed via `wb done`\.' "$(cat "$delta_file")"

entry_count="$(grep -cE '^### .* — wb (pause|done) \(auto\)$' "$delta_file")"
if [ "$entry_count" -eq 2 ]; then
  echo "ok   - handoffs done: exactly 2 entries total (prior + new)"
else
  echo "FAIL - handoffs done: expected 2 Handoffs entries, got $entry_count"; fail=1
fi

pause_line="$(grep -n '^### .* — wb pause (auto)$' "$delta_file" | head -1 | cut -d: -f1)"
done_line="$(grep -n '^### .* — wb done (auto)$' "$delta_file" | head -1 | cut -d: -f1)"
if [ -n "$pause_line" ] && [ -n "$done_line" ] && [ "$pause_line" -lt "$done_line" ]; then
  echo "ok   - handoffs done: new entry lands AFTER the existing one (end of section, oldest-first)"
else
  echo "FAIL - handoffs done: entry ordering wrong (pause=$pause_line, done=$done_line)"; fail=1
fi

decisions_line="$(grep -n '^## Decisions$' "$delta_file" | head -1 | cut -d: -f1)"
if [ -n "$decisions_line" ] && [ "$done_line" -lt "$decisions_line" ]; then
  echo "ok   - handoffs done: new entry still lands inside the Handoffs section (before ## Decisions)"
else
  echo "FAIL - handoffs done: new entry landed outside the Handoffs section (done=$done_line, decisions=$decisions_line)"; fail=1
fi


# --- U10: roadmap-currency nudge fires only for a roadmap-tracked repo: ----
epsilon_session="$(session_for epsilon)"
out="$(cmd_done "$epsilon_session" 2>&1)"; rc=$?
assert "U10 nudge: exits 0" '^' "$rc-ok"; [ "$rc" -eq 0 ] || { echo "FAIL - exit $rc: $out"; fail=1; }
assert "U10 nudge: fires for repo: dotfiles" 'dotfiles is roadmap-tracked.*docs/roadmap\.md' "$out"

[ "$fail" -eq 0 ] && echo "ALL PASS" || echo "FAILURES"
exit "$fail"
