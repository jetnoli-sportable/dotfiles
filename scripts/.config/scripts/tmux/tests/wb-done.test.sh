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
FIXTURE_STATE="$(mktemp -d -t wb-done-state.XXXXXX)"   # XDG_STATE_HOME: wb-capture's shelved drafts + log
SLUGS=(alpha beta gamma dirty delta epsilon zeta eta theta kappa lambda mu nu)
session_for() { printf 'wb-done-test-%s-%s\n' "$1" "$$"; }   # <slug> -> its fixture session name
trap '
  rm -rf "$FIXTURE_CODE" "$FIXTURE_TASKS" "$FIXTURE_STATE"
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

# "epsilon" needs its OWN fixture repo named "dotfiles" (a roadmap-tracked
# repo, per KTD5) — cmd_done resolves repo_dir from the task file's repo:
# frontmatter (wb.sh's hoisted `repo` read), never from the @wb_repo tmux
# option, so a task file merely claiming repo: dotfiles while its real
# worktree sits under the generic "proj" fixture would make cmd_done's own
# repo_dir="$CODE_DIR/$repo" point at a directory that doesn't exist —
# every teardown step would then silently no-op via its own existence guard,
# and this fixture would only ever prove the nudge prints, never that it
# coexists correctly with a real worktree removal.
git init -q "$FIXTURE_CODE/dotfiles"
git -C "$FIXTURE_CODE/dotfiles" -c user.email=test@test -c user.name=test commit -q --allow-empty -m init
git -C "$FIXTURE_CODE/dotfiles" worktree add -q -b epsilon ".worktrees/epsilon" >/dev/null 2>&1
rm -f "$FIXTURE_TASKS/proj--epsilon.md"   # unused: mk_task's generic proj-rooted fixture for this slug
printf -- '---\nstatus: doing\nrepo: dotfiles\nbranch: epsilon\nworktree: .worktrees/epsilon\ntags: []\ncreated: 2026-07-07\nclosed:\n---\n# Title\n' \
  > "$FIXTURE_TASKS/dotfiles--epsilon.md"

# "zeta" mirrors epsilon for the OTHER roadmap-tracked repo value — the
# `dotfiles|docgen)` case pattern in wb.sh's nudge has two branches, and a
# fixture only exercising the first would let a typo/drop of the second
# alternative pass the whole suite unnoticed.
git init -q "$FIXTURE_CODE/docgen"
git -C "$FIXTURE_CODE/docgen" -c user.email=test@test -c user.name=test commit -q --allow-empty -m init
git -C "$FIXTURE_CODE/docgen" worktree add -q -b zeta ".worktrees/zeta" >/dev/null 2>&1
rm -f "$FIXTURE_TASKS/proj--zeta.md"   # unused: mk_task's generic proj-rooted fixture for this slug
printf -- '---\nstatus: doing\nrepo: docgen\nbranch: zeta\nworktree: .worktrees/zeta\ntags: []\ncreated: 2026-07-07\nclosed:\n---\n# Title\n' \
  > "$FIXTURE_TASKS/docgen--zeta.md"

for slug in "${SLUGS[@]}"; do
  s="$(session_for "$slug")"
  tmux new-session -d -s "$s" 2>/dev/null
  # epsilon/zeta each point at their own real fixture repo above (dotfiles/
  # docgen respectively), not the generic "proj" one every other slug uses.
  case "$slug" in
    epsilon) tmux set-option -t "=$s:" @wb_repo dotfiles >/dev/null ;;
    zeta)    tmux set-option -t "=$s:" @wb_repo docgen >/dev/null ;;
    *)       tmux set-option -t "=$s:" @wb_repo proj >/dev/null ;;
  esac
  tmux set-option -t "=$s:" @wb_slug "$slug" >/dev/null
done

# shellcheck disable=SC1090
source "$WB"
set +e   # wb.sh sets -e; this test intentionally captures non-zero exits
TASKS_DIR="$FIXTURE_TASKS"
CODE_DIR="$FIXTURE_CODE"
export XDG_STATE_HOME="$FIXTURE_STATE"
CAPROOT="$FIXTURE_STATE/wb/capture"
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
# U6/R6: seed a claude_sessions: snapshot before closing — cmd_done must
# blank it, since a done task's worktree is gone and the record would
# otherwise claim a resumable conversation that no longer exists.
wb_set_frontmatter "$FIXTURE_TASKS/proj--alpha.md" claude_sessions 'abc@2026-09-01T00:00:00Z@primary'
out="$(cmd_done "$alpha_session" 2>&1)"; rc=$?
assert "plain done: exits 0" '^' "$rc-ok"; [ "$rc" -eq 0 ] || { echo "FAIL - exit $rc: $out"; fail=1; }
assert "plain done: confirmation says the session stays open" 'worktree removed, session left open \(pass --close to end it\), task -> done' "$out"
assert "plain done: handoff line says the session stays open" 'Worktree removed, session left open \(`wb done` without `--close`\)\.$' "$(cat "$FIXTURE_TASKS/proj--alpha.md")"
if printf '%s' "$out" | grep -q 'roadmap-tracked'; then
  echo "FAIL - U10 nudge: fired for repo: proj, which isn't roadmap-tracked"; fail=1
else
  echo "ok   - U10 nudge: silent for an unrelated repo"
fi
[ -d "$FIXTURE_CODE/proj/.worktrees/alpha" ] \
  && { echo "FAIL - plain done: worktree not removed"; fail=1; } \
  || echo "ok   - plain done: worktree removed"
assert "plain done: task flipped to done" '^done$' "$(status_of alpha)"
sessions_val="$(wb_get_frontmatter "$FIXTURE_TASKS/proj--alpha.md" claude_sessions)"
if [ -z "$sessions_val" ]; then
  echo "ok   - plain done: claude_sessions: blanked"
else
  echo "FAIL - plain done: claude_sessions: should be blank, got '$sessions_val'"; fail=1
fi
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
assert "done --close: confirmation says the session closed" 'worktree removed, session closed, task -> done' "$out"
assert "done --close: handoff line says the session closed" 'Worktree removed, session closed \(`wb done --close`\)\.$' "$(cat "$FIXTURE_TASKS/proj--beta.md")"
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
assert "handoffs done: new entry appended" 'Worktree removed, session left open \(`wb done` without `--close`\)\.' "$(cat "$delta_file")"

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


# --- U10: roadmap-currency nudge fires only for a roadmap-tracked repo, ----
# --- alongside a REAL worktree teardown against its own "dotfiles" fixture --
epsilon_session="$(session_for epsilon)"
out="$(cmd_done "$epsilon_session" 2>&1)"; rc=$?
assert "U10 nudge: exits 0" '^' "$rc-ok"; [ "$rc" -eq 0 ] || { echo "FAIL - exit $rc: $out"; fail=1; }
assert "U10 nudge: fires for repo: dotfiles" 'dotfiles is roadmap-tracked.*docs/roadmap\.md' "$out"
[ -d "$FIXTURE_CODE/dotfiles/.worktrees/epsilon" ] \
  && { echo "FAIL - U10 nudge: epsilon's real worktree not removed"; fail=1; } \
  || echo "ok   - U10 nudge: epsilon's real worktree removed (repo_dir resolved correctly)"
status_of_dotfiles_epsilon() { wb_get_frontmatter "$FIXTURE_TASKS/dotfiles--epsilon.md" status; }
assert "U10 nudge: epsilon task flipped to done" '^done$' "$(status_of_dotfiles_epsilon)"

# --- U10: the OTHER roadmap-tracked repo value (docgen) fires too ----------
zeta_session="$(session_for zeta)"
out="$(cmd_done "$zeta_session" 2>&1)"; rc=$?
assert "U10 nudge: exits 0 (docgen)" '^' "$rc-ok"; [ "$rc" -eq 0 ] || { echo "FAIL - exit $rc: $out"; fail=1; }
assert "U10 nudge: fires for repo: docgen" 'docgen is roadmap-tracked.*docs/roadmap\.md' "$out"
[ -d "$FIXTURE_CODE/docgen/.worktrees/zeta" ] \
  && { echo "FAIL - U10 nudge: zeta's real worktree not removed"; fail=1; } \
  || echo "ok   - U10 nudge: zeta's real worktree removed (repo_dir resolved correctly)"
status_of_docgen_zeta() { wb_get_frontmatter "$FIXTURE_TASKS/docgen--zeta.md" status; }
assert "U10 nudge: zeta task flipped to done" '^done$' "$(status_of_docgen_zeta)"

# --- shelved-draft guard (D13 #6): wb done refuses while wb-capture holds ----
# --- shelved decision drafts for the task, unless --leave-shelved ------------
eta_session="$(session_for eta)"; eta_file="$FIXTURE_TASKS/proj--eta.md"
mkdir -p "$CAPROOT/shelved/proj--eta" "$CAPROOT/shelved/proj--other"
printf '### Chose B\n- decided: B\n' >"$CAPROOT/shelved/proj--eta/20261018T100000-sid-a.md"
printf '### Chose C\n' >"$CAPROOT/shelved/proj--eta/20261018T110000-sid-b.md"
: >"$CAPROOT/shelved/proj--eta/20261018T110000-sid-b.md.stale"
printf 'x\n' >"$CAPROOT/shelved/proj--other/20261018T090000-sid-z.md"
eta_before="$(cat "$eta_file")"
out="$(cmd_done "$eta_session" --close 2>&1)"; rc=$?
[ "$rc" -ne 0 ] && echo "ok   - shelved guard: non-zero exit" || { echo "FAIL - shelved guard: exit $rc"; fail=1; }
assert "shelved guard: names the first draft" "$CAPROOT/shelved/proj--eta/20261018T100000-sid-a\\.md" "$out"
assert "shelved guard: names the second draft" "$CAPROOT/shelved/proj--eta/20261018T110000-sid-b\\.md" "$out"
assert "shelved guard: counts drafts, not sidecars" '2 decision draft' "$out"
assert "shelved guard: points at /close-out and /wb-decide shelved" '/close-out or /wb-decide shelved' "$out"
assert "shelved guard: points at --leave-shelved" '\-\-leave-shelved' "$out"
assert "shelved guard: labels the shelved drafts" 'shelved: .*20261018T100000-sid-a\.md' "$out"
case "$out" in *"pending in session"*|*"pending in a session"*) echo "FAIL - shelved guard: shelved-only refusal mentions a session draft"; fail=1 ;; *) echo "ok   - shelved guard: no session-draft remedy when none is pending" ;; esac
assert "shelved guard: says nothing changed" 'nothing changed' "$out"
[ -d "$FIXTURE_CODE/proj/.worktrees/eta" ] && echo "ok   - shelved guard: worktree untouched" || { echo "FAIL - shelved guard: worktree removed"; fail=1; }
assert "shelved guard: task not flipped" '^doing$' "$(status_of eta)"
[ "$(cat "$eta_file")" = "$eta_before" ] && echo "ok   - shelved guard: task file byte-identical" || { echo "FAIL - shelved guard: task file changed"; fail=1; }
tmux has-session -t "=$eta_session" 2>/dev/null && echo "ok   - shelved guard: session survives (--close did not run)" || { echo "FAIL - shelved guard: session killed"; fail=1; }
[ -f "$CAPROOT/shelved/proj--eta/20261018T100000-sid-a.md" ] && echo "ok   - shelved guard: drafts untouched" || { echo "FAIL - shelved guard: draft removed"; fail=1; }
[ ! -e "$CAPROOT/log.jsonl" ] && echo "ok   - shelved guard: refusal logs nothing" || { echo "FAIL - shelved guard: refusal wrote a log"; fail=1; }

out="$(cmd_done "$eta_session" --leave-shelved 2>&1)"; rc=$?
[ "$rc" -eq 0 ] && echo "ok   - --leave-shelved: exits 0" || { echo "FAIL - --leave-shelved: exit $rc: $out"; fail=1; }
assert "--leave-shelved: task flipped to done" '^done$' "$(status_of eta)"
[ -d "$FIXTURE_CODE/proj/.worktrees/eta" ] && { echo "FAIL - --leave-shelved: worktree not removed"; fail=1; } || echo "ok   - --leave-shelved: worktree removed"
[ -f "$CAPROOT/shelved/proj--eta/20261018T100000-sid-a.md" ] && echo "ok   - --leave-shelved: drafts left in place" || { echo "FAIL - --leave-shelved: a draft was removed"; fail=1; }
assert "--leave-shelved: logs shelved_left with the count" '"event":"shelved_left".*"count":2|"count":2.*"event":"shelved_left"' "$(cat "$CAPROOT/log.jsonl" 2>/dev/null)"
assert "--leave-shelved: log line names the task" '"task":"proj--eta"' "$(cat "$CAPROOT/log.jsonl" 2>/dev/null)"
[ "$(wc -l <"$CAPROOT/log.jsonl" | tr -d ' ')" = 1 ] && echo "ok   - --leave-shelved: exactly one log line" || { echo "FAIL - --leave-shelved: log line count"; fail=1; }
assert "--leave-shelved: handoff line records the left drafts" 'left in .*shelved/proj--eta' "$(cat "$eta_file")"
assert "--leave-shelved: handoff line still says the session stays open" 'Worktree removed, session left open \(`wb done` without `--close`\); --leave-shelved: 2 decision draft' "$(cat "$eta_file")"

# an empty (or non-draft-only) shelved dir, and a dir for another task, don't block
theta_session="$(session_for theta)"
mkdir -p "$CAPROOT/shelved/proj--theta"; printf 'n\n' >"$CAPROOT/shelved/proj--theta/notes.txt"
out="$(cmd_done "$theta_session" 2>&1)"; rc=$?
[ "$rc" -eq 0 ] && echo "ok   - shelved guard: empty shelved dir does not block" || { echo "FAIL - shelved guard: empty dir blocked: $out"; fail=1; }
assert "shelved guard: empty dir -> done" '^done$' "$(status_of theta)"
[ "$(wc -l <"$CAPROOT/log.jsonl" | tr -d ' ')" = 1 ] && echo "ok   - shelved guard: nothing left, nothing logged" || { echo "FAIL - shelved guard: spurious log line"; fail=1; }
assert "shelved guard: plain close keeps the plain handoff line" 'Worktree removed, session left open \(`wb done` without `--close`\)\.$' "$(cat "$FIXTURE_TASKS/proj--theta.md")"

# store-only close (no live session) is guarded too, before any mutation
iota_file="$FIXTURE_TASKS/proj--iota.md"
printf -- '---\nstatus: planned\nrepo: proj\ntags: []\ncreated: 2026-07-07\nclosed:\n---\n# Title\n' >"$iota_file"
mkdir -p "$CAPROOT/shelved/proj--iota"; printf 'd\n' >"$CAPROOT/shelved/proj--iota/20261018T100000-sid-i.md"
iota_before="$(cat "$iota_file")"
out="$(cmd_done proj--iota 2>&1)"; rc=$?
[ "$rc" -ne 0 ] && echo "ok   - shelved guard (store-only): non-zero exit" || { echo "FAIL - shelved guard (store-only): exit $rc"; fail=1; }
assert "shelved guard (store-only): names the draft" "shelved/proj--iota/20261018T100000-sid-i\\.md" "$out"
[ "$(cat "$iota_file")" = "$iota_before" ] && echo "ok   - shelved guard (store-only): task file byte-identical" || { echo "FAIL - shelved guard (store-only): task file changed"; fail=1; }
out="$(cmd_done proj--iota --leave-shelved 2>&1)"; rc=$?
[ "$rc" -eq 0 ] && echo "ok   - --leave-shelved (store-only): exits 0" || { echo "FAIL - --leave-shelved (store-only): exit $rc: $out"; fail=1; }
assert "--leave-shelved (store-only): task done" '^done$' "$(wb_get_frontmatter "$iota_file" status)"
assert "store-only: handoff line says nothing was torn down" 'Closed in the store only \(`wb done`\): no live session, nothing torn down; --leave-shelved: 1 decision draft' "$(cat "$iota_file")"
[ "$(wc -l <"$CAPROOT/log.jsonl" | tr -d ' ')" = 2 ] && echo "ok   - --leave-shelved (store-only): logged" || { echo "FAIL - --leave-shelved (store-only): log line count"; fail=1; }

# --- end-to-end: the shelved draft comes from the REAL wb-capture.sh hook-end path, ---
# --- the guard refuses, `wb-capture.sh dismiss <path>` resolves it, wb done proceeds ---
CAPTURE="$(dirname "$WB")/wb-capture.sh"
kappa_session="$(session_for kappa)"; kappa_file="$FIXTURE_TASKS/proj--kappa.md"
tmux set-option -t "=$kappa_session:" @task "$kappa_file" >/dev/null
kappa_pane="$(tmux display-message -p -t "=$kappa_session:" '#{pane_id}')"
kappa_tmux="$(tmux display-message -p -t "=$kappa_session:" '#{socket_path},#{pid},0')"
mkdir -p "$CAPROOT/sid-kappa"; printf '### Chose K\n- decided: K\n' >"$CAPROOT/sid-kappa/draft"
kcap() { TMUX="$kappa_tmux" TMUX_PANE="$kappa_pane" bash "$CAPTURE" "$@"; }
printf '{"session_id":"sid-kappa"}' | kcap hook-end
kappa_draft="$(ls "$CAPROOT"/shelved/proj--kappa/*-sid-kappa.md 2>/dev/null | head -1)"
[ -n "$kappa_draft" ] && echo "ok   - e2e: hook-end shelved the draft under the task stem" || { echo "FAIL - e2e: no shelved draft produced"; fail=1; }
kappa_before="$(cat "$kappa_file")"
out="$(cmd_done "$kappa_session" 2>&1)"; rc=$?
[ "$rc" -ne 0 ] && echo "ok   - e2e: wb done refuses the real shelved draft" || { echo "FAIL - e2e: wb done exit $rc"; fail=1; }
assert "e2e: refusal names the draft" "sid-kappa\\.md" "$out"
[ "$(cat "$kappa_file")" = "$kappa_before" ] && echo "ok   - e2e: task file untouched by the refusal" || { echo "FAIL - e2e: task file changed"; fail=1; }
tmux set-option -p -t "$kappa_pane" @wb_capture_sid sid-kappa >/dev/null
kcap dismiss "$kappa_draft"
[ ! -e "$kappa_draft" ] && echo "ok   - e2e: dismiss <path> removed the shelved draft" || { echo "FAIL - e2e: draft still present"; fail=1; }
assert "e2e: shelved_dismissed logged" '"event":"shelved_dismissed"' "$(cat "$CAPROOT/log.jsonl" 2>/dev/null)"
out="$(cmd_done "$kappa_session" 2>&1)"; rc=$?
[ "$rc" -eq 0 ] && echo "ok   - e2e: wb done proceeds once dismissed" || { echo "FAIL - e2e: wb done exit $rc: $out"; fail=1; }
assert "e2e: task flipped to done" '^done$' "$(status_of kappa)"

# --- live-session draft guard (D14 #2): a draft still pending in a live session dir ---
# --- whose taskpath is this task would be shelved by SessionEnd after the close ---
lambda_session="$(session_for lambda)"; lambda_file="$FIXTURE_TASKS/proj--lambda.md"
mkdir -p "$CAPROOT/sid-live" "$CAPROOT/sid-otherlive"
printf '### Chose L\n- decided: L\n' >"$CAPROOT/sid-live/draft"; printf '%s\n' "$lambda_file" >"$CAPROOT/sid-live/taskpath"
printf '### Other\n' >"$CAPROOT/sid-otherlive/draft"; printf '%s\n' "$FIXTURE_TASKS/proj--elsewhere.md" >"$CAPROOT/sid-otherlive/taskpath"
lambda_before="$(cat "$lambda_file")"
out="$(cmd_done "$lambda_session" 2>&1)"; rc=$?
[ "$rc" -ne 0 ] && echo "ok   - live draft guard: non-zero exit" || { echo "FAIL - live draft guard: exit $rc"; fail=1; }
assert "live draft guard: names the live draft" "$CAPROOT/sid-live/draft" "$out"
assert "live draft guard: counts only this task's draft" '1 decision draft' "$out"
assert "live draft guard: names the owning session" 'pending in session sid-live: ' "$out"
assert "live draft guard: remedy is resolve in that session or --leave-shelved" 'resolve it with /wb-decide in that session, or re-run with --leave-shelved' "$out"
assert "live draft guard: remedy names SessionEnd/reaper and --task" 'SessionEnd or the reaper will shelve it; resolve it later with --task' "$out"
case "$out" in *"/close-out or /wb-decide shelved"*) echo "FAIL - live draft guard: offered the shelved remedy for a session draft"; fail=1 ;; *) echo "ok   - live draft guard: no shelved remedy for a session draft" ;; esac
case "$out" in *sid-otherlive*) echo "FAIL - live draft guard: named another task's live draft"; fail=1 ;; *) echo "ok   - live draft guard: another task's live draft ignored" ;; esac
assert "live draft guard: says nothing changed" 'nothing changed' "$out"
[ "$(cat "$lambda_file")" = "$lambda_before" ] && echo "ok   - live draft guard: task file byte-identical" || { echo "FAIL - live draft guard: task file changed"; fail=1; }
[ -d "$FIXTURE_CODE/proj/.worktrees/lambda" ] && echo "ok   - live draft guard: worktree untouched" || { echo "FAIL - live draft guard: worktree removed"; fail=1; }
[ -f "$CAPROOT/sid-live/draft" ] && echo "ok   - live draft guard: draft untouched" || { echo "FAIL - live draft guard: draft removed"; fail=1; }
logn_before="$(wc -l <"$CAPROOT/log.jsonl" | tr -d ' ')"
out="$(cmd_done "$lambda_session" --leave-shelved 2>&1)"; rc=$?
[ "$rc" -eq 0 ] && echo "ok   - live draft --leave-shelved: exits 0" || { echo "FAIL - live draft --leave-shelved: exit $rc: $out"; fail=1; }
assert "live draft --leave-shelved: task done" '^done$' "$(status_of lambda)"
[ -f "$CAPROOT/sid-live/draft" ] && echo "ok   - live draft --leave-shelved: draft left in place" || { echo "FAIL - live draft --leave-shelved: draft removed"; fail=1; }
assert "live draft --leave-shelved: logged with count 1" '"task":"proj--lambda".*"count":1|"count":1.*"task":"proj--lambda"' "$(tail -n1 "$CAPROOT/log.jsonl")"
[ "$(wc -l <"$CAPROOT/log.jsonl" | tr -d ' ')" = "$((logn_before + 1))" ] && echo "ok   - live draft --leave-shelved: exactly one log line" || { echo "FAIL - live draft --leave-shelved: log line count"; fail=1; }
assert "live draft --leave-shelved: handoff records the left draft" 'decision draft\(s\) left in place' "$(cat "$lambda_file")"

# a live draft of this task that was already shelved/cleared (no draft file) doesn't block
mu_session="$(session_for mu)"; mu_file="$FIXTURE_TASKS/proj--mu.md"
mkdir -p "$CAPROOT/sid-mu"; printf '%s\n' "$mu_file" >"$CAPROOT/sid-mu/taskpath"
out="$(cmd_done "$mu_session" 2>&1)"; rc=$?
[ "$rc" -eq 0 ] && echo "ok   - live draft guard: a session dir without a draft does not block" || { echo "FAIL - live draft guard: blocked without a draft: $out"; fail=1; }

# wb-capture.sh missing next to wb.sh: the guard is best-effort, so the close proceeds with a stderr note
nu_session="$(session_for nu)"; nu_file="$FIXTURE_TASKS/proj--nu.md"
mkdir -p "$CAPROOT/shelved/proj--nu"; printf 'd\n' >"$CAPROOT/shelved/proj--nu/20261018T100000-sid-n.md"
out="$(SCRIPT_DIR="$FIXTURE_STATE/no-such-dir" cmd_done "$nu_session" 2>&1)"; rc=$?
[ "$rc" -eq 0 ] && echo "ok   - missing wb-capture.sh: close proceeds" || { echo "FAIL - missing wb-capture.sh: exit $rc: $out"; fail=1; }
assert "missing wb-capture.sh: says the guard was skipped" 'wb-capture\.sh unavailable.*skipping' "$out"
assert "missing wb-capture.sh: task done" '^done$' "$(status_of nu)"

[ "$fail" -eq 0 ] && echo "ALL PASS" || echo "FAILURES"
exit "$fail"
