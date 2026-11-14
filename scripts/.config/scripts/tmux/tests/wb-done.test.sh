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

# --- picker's ctrl-x on a task row asks first; anything but y cancels ------
gamma_session="$(session_for gamma)"
for answer in n "" EOF; do
  case "$answer" in
    EOF) out="$(_ctrl_x task "$gamma_session" "" </dev/null 2>&1)"; rc=$? ;;
    *)   out="$(_ctrl_x task "$gamma_session" "" 2>&1 <<<"$answer")"; rc=$? ;;
  esac
  [ "$rc" -eq 0 ] && echo "ok   - ctrl-x cancel ($answer): exits 0" || { echo "FAIL - ctrl-x cancel ($answer): exit $rc: $out"; fail=1; }
  assert "ctrl-x cancel ($answer): says it left the task alone" 'wb: left proj--gamma as it was' "$out"
  assert "ctrl-x cancel ($answer): task still doing" '^doing$' "$(status_of gamma)"
  [ -d "$FIXTURE_CODE/proj/.worktrees/gamma" ] && echo "ok   - ctrl-x cancel ($answer): worktree kept" || { echo "FAIL - ctrl-x cancel ($answer): worktree removed"; fail=1; }
  tmux has-session -t "=$gamma_session" 2>/dev/null && echo "ok   - ctrl-x cancel ($answer): session alive" || { echo "FAIL - ctrl-x cancel ($answer): session killed"; fail=1; }
done
assert "ctrl-x prompt: names the task, its title and what closing does" \
  'Close proj--gamma \(Title\)\? Removes the worktree, marks the task done, and closes the session\. \[y/N\]' "$out"

# --- integration: picker's ctrl-x on a task row, confirmed, takes the close path
out="$(_ctrl_x task "$gamma_session" "" 2>&1 <<<y)"; rc=$?
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

# --- ctrl-x on a dormant row (no session) asks too, then closes in the store
omicron_file="$FIXTURE_TASKS/proj--omicron.md"
printf -- '---\nstatus: planned\nrepo: proj\ntags: []\ncreated: 2026-07-07\nclosed:\n---\n# Omicron title\n' >"$omicron_file"
out="$(_ctrl_x task "" "" "$omicron_file" 2>&1 <<<x)"; rc=$?
[ "$rc" -eq 0 ] && echo "ok   - ctrl-x dormant cancel: exits 0" || { echo "FAIL - ctrl-x dormant cancel: exit $rc: $out"; fail=1; }
assert "ctrl-x dormant prompt: names the task and says nothing is torn down" \
  'Close proj--omicron \(Omicron title\)\? Marks the task done in the store; nothing is torn down\. \[y/N\]' "$out"
assert "ctrl-x dormant cancel: task still planned" '^planned$' "$(wb_get_frontmatter "$omicron_file" status)"
out="$(_ctrl_x task "" "" "$omicron_file" 2>&1 <<<Y)"; rc=$?
[ "$rc" -eq 0 ] && echo "ok   - ctrl-x dormant confirm (Y): exits 0" || { echo "FAIL - ctrl-x dormant confirm (Y): exit $rc: $out"; fail=1; }
assert "ctrl-x dormant confirm (Y): task done" '^done$' "$(wb_get_frontmatter "$omicron_file" status)"

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

delta_hd="$FIXTURE_TASKS/dossiers/proj--delta/handoffs"
assert "handoffs done: prior entry moved to a handoffs/ file" 'Session paused via `wb pause`\.' "$(cat "$delta_hd"/*.md 2>&1)"
assert "handoffs done: new entry in the task file" 'Worktree removed, session left open \(`wb done` without `--close`\)\.' "$(cat "$delta_file")"

entry_count="$(grep -cE '^### .* — wb (pause|done) \(auto\)$' "$delta_file")"
if [ "$entry_count" -eq 1 ] && grep -qE '^### .* — wb done \(auto\)$' "$delta_file"; then
  echo "ok   - handoffs done: the task file holds exactly the newest (wb done) entry"
else
  echo "FAIL - handoffs done: expected only the wb done entry in the task file, got $entry_count entries"; fail=1
fi

done_line="$(grep -n '^### .* — wb done (auto)$' "$delta_file" | head -1 | cut -d: -f1)"
decisions_line="$(grep -n '^## Decisions$' "$delta_file" | head -1 | cut -d: -f1)"
if [ -n "$decisions_line" ] && [ "$done_line" -lt "$decisions_line" ]; then
  echo "ok   - handoffs done: new entry still lands inside the Handoffs section (before the next section)"
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

# --- end-to-end: a shelf file (written directly: hook-end no longer shelves a draft), ---
# --- the guard refuses, `wb-capture.sh dismiss <path>` resolves it, wb done proceeds ---
CAPTURE="$(dirname "$WB")/wb-capture.sh"
kappa_session="$(session_for kappa)"; kappa_file="$FIXTURE_TASKS/proj--kappa.md"
tmux set-option -t "=$kappa_session:" @task "$kappa_file" >/dev/null
kappa_pane="$(tmux display-message -p -t "=$kappa_session:" '#{pane_id}')"
kappa_tmux="$(tmux display-message -p -t "=$kappa_session:" '#{socket_path},#{pid},0')"
kcap() { TMUX="$kappa_tmux" TMUX_PANE="$kappa_pane" bash "$CAPTURE" "$@"; }
mkdir -p "$CAPROOT/shelved/proj--kappa"; printf '### Chose K\n- decided: K\n' >"$CAPROOT/shelved/proj--kappa/20261018T120000-sid-kappa.md"
kappa_draft="$CAPROOT/shelved/proj--kappa/20261018T120000-sid-kappa.md"
# hook-end must not shelve anything now: a stray per-session draft stays a stray
mkdir -p "$CAPROOT/sid-kappa"; printf 'stray\n' >"$CAPROOT/sid-kappa/draft"
printf '{"session_id":"sid-kappa"}' | kcap hook-end
[ "$(ls "$CAPROOT"/shelved/proj--kappa/ | wc -l | tr -d ' ')" = 1 ] && echo "ok   - e2e: hook-end shelved nothing extra" || { echo "FAIL - e2e: hook-end shelved a draft"; fail=1; }
rm -rf "$CAPROOT/sid-kappa"
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

# --- a stray per-session draft is not a shelved draft: wb done is not blocked by it ---
# --- (drafts left in that old slot are moved to the shelf by hand at rollout, KTD10) ---
lambda_session="$(session_for lambda)"; lambda_file="$FIXTURE_TASKS/proj--lambda.md"
mkdir -p "$CAPROOT/sid-live"
printf '### Chose L\n- decided: L\n' >"$CAPROOT/sid-live/draft"; printf '%s\n' "$lambda_file" >"$CAPROOT/sid-live/taskpath"
logn_before="$(wc -l <"$CAPROOT/log.jsonl" | tr -d ' ')"
out="$(cmd_done "$lambda_session" 2>&1)"; rc=$?
[ "$rc" -eq 0 ] && echo "ok   - stray session draft: wb done not blocked" || { echo "FAIL - stray session draft: blocked: $out"; fail=1; }
assert "stray session draft: task done" '^done$' "$(status_of lambda)"
case "$out" in *"pending in"*|*"decision draft"*) echo "FAIL - stray session draft: refusal wording appeared"; fail=1 ;; *) echo "ok   - stray session draft: no draft refusal" ;; esac
[ -f "$CAPROOT/sid-live/draft" ] && echo "ok   - stray session draft: left untouched" || { echo "FAIL - stray session draft: removed"; fail=1; }
[ "$(wc -l <"$CAPROOT/log.jsonl" | tr -d ' ')" = "$logn_before" ] && echo "ok   - stray session draft: nothing logged" || { echo "FAIL - stray session draft: log line written"; fail=1; }

# wb-capture.sh missing next to wb.sh: the guard is best-effort, so the close proceeds with a stderr note
nu_session="$(session_for nu)"; nu_file="$FIXTURE_TASKS/proj--nu.md"
mkdir -p "$CAPROOT/shelved/proj--nu"; printf 'd\n' >"$CAPROOT/shelved/proj--nu/20261018T100000-sid-n.md"
out="$(SCRIPT_DIR="$FIXTURE_STATE/no-such-dir" cmd_done "$nu_session" 2>&1)"; rc=$?
[ "$rc" -eq 0 ] && echo "ok   - missing wb-capture.sh: close proceeds" || { echo "FAIL - missing wb-capture.sh: exit $rc: $out"; fail=1; }
assert "missing wb-capture.sh: says the guard was skipped" 'wb-capture\.sh unavailable.*skipping' "$out"
assert "missing wb-capture.sh: task done" '^done$' "$(status_of nu)"

# =============================================================================
# W6: the rewired wb done — classify first, stop before any change on an
# unknown, copy keepers, record kept:/discarded:, buffer only under --review.
# Every scenario runs on a dossier-layout task.
# =============================================================================
W6_BUFLOG="$FIXTURE_STATE/w6-buffer-calls"; : > "$W6_BUFLOG"
wb_open_buffer() { echo "$1" >> "$W6_BUFLOG"; }   # counted via a file: cmd_done runs in $(...) subshells
w6_calls() { wc -l < "$W6_BUFLOG" | tr -d ' '; }

SWP="$FIXTURE_CODE/swp"
git init -q "$SWP"
printf 'node_modules/\n*.log\n.claude-queue.md\nscratch/\nconfig.hjson\nmemo.md\nnotes.md\ndecisions/\nlogs/\n' > "$SWP/.gitignore"
printf 'config.hjson\n' > "$SWP/.worktree-bootstrap"
git -C "$SWP" add -A
git -C "$SWP" -c user.email=test@test -c user.name=test commit -q -m init
printf 'main config\n' > "$SWP/config.hjson"

# w6_new <slug> <dossier> — a worktree, its task file and a live session.
w6_new() {
  local slug="$1" layout="$2" f="$FIXTURE_TASKS/swp--$1.md" s
  git -C "$SWP" worktree add -q -b "$slug" ".worktrees/$slug" >/dev/null 2>&1
  cp "$SWP/config.hjson" "$SWP/.worktrees/$slug/config.hjson"   # what wb new's bootstrap does
  { printf -- '---\nstatus: doing\nrepo: swp\nbranch: %s\nworktree: .worktrees/%s\n' "$slug" "$slug"
    [ "$layout" = dossier ] && printf 'layout: dossier\n'
    printf 'tags: []\ncreated: 2026-11-01\nclosed:\n---\n# Title\n'; } > "$f"
  s="$(session_for "$slug")"
  tmux new-session -d -s "$s" 2>/dev/null
  tmux set-option -t "=$s:" @wb_repo swp >/dev/null
  tmux set-option -t "=$s:" @wb_slug "$slug" >/dev/null
  SLUGS+=("$slug")
}
w6_wt() { printf '%s\n' "$SWP/.worktrees/$1"; }
w6_file() { printf '%s\n' "$FIXTURE_TASKS/swp--$1.md"; }
w6_dossier() { printf '%s\n' "$FIXTURE_TASKS/dossiers/swp--$1"; }
w6_status() { wb_get_frontmatter "$(w6_file "$1")" status; }

for layout in dossier; do
  L="w6$layout"

  # --- default close: no buffer; keepers copied; throwaways recorded -------
  slug="${L}-clean"; w6_new "$slug" "$layout"
  wb_set_frontmatter "$(w6_file "$slug")" claude_sessions 'abc@2026-09-01T00:00:00Z@primary'
  mkdir -p "$(w6_wt "$slug")/node_modules/pkg"; echo x > "$(w6_wt "$slug")/node_modules/pkg/i.js"
  echo noise > "$(w6_wt "$slug")/app.log"
  printf 'queued\n' > "$(w6_wt "$slug")/.claude-queue.md"
  calls_before="$(w6_calls)"
  out="$(cmd_done "$(session_for "$slug")" 2>&1)"; rc=$?
  [ "$rc" -eq 0 ] && echo "ok   - W6: default close exits 0" || { echo "FAIL - W6: default close exit $rc: $out"; fail=1; }
  [ "$(w6_calls)" = "$calls_before" ] && echo "ok   - W6: default close never opens the buffer" || { echo "FAIL - W6: buffer opened without --review"; fail=1; }
  [ ! -d "$(w6_wt "$slug")" ] && echo "ok   - W6: worktree removed" || { echo "FAIL - W6: worktree remains"; fail=1; }
  assert "W6: status done" '^done$' "$(w6_status "$slug")"
  assert "W6: closed stamped" "^$(date +%F)\$" "$(wb_get_frontmatter "$(w6_file "$slug")" closed)"
  [ -z "$(wb_get_frontmatter "$(w6_file "$slug")" claude_sessions)" ] && echo "ok   - W6: claude_sessions blank" || { echo "FAIL - W6: claude_sessions not blank"; fail=1; }
  rec="$(cat "$(w6_file "$slug")")"
  assert "W6: handoff keeps the done_note wording" 'Worktree removed, session left open \(`wb done` without `--close`\)\.$' "$rec"
  assert "W6: one kept: line naming the queue file" '^kept: \.claude-queue\.md$' "$rec"
  assert "W6: one discarded: line naming node_modules/ and app.log" '^discarded: .*node_modules/.*app\.log$|^discarded: .*app\.log.*node_modules/$' "$rec"
  [ "$(printf '%s\n' "$rec" | /usr/bin/grep -c '^discarded:')" = 1 ] && echo "ok   - W6: exactly one discarded: line" || { echo "FAIL - W6: discarded: line count"; fail=1; }
  [ "$(cat "$(w6_dossier "$slug")/.claude-queue.md" 2>/dev/null)" = queued ] && echo "ok   - W6: queue file landed in the dossier" || { echo "FAIL - W6: queue file missing from dossier"; fail=1; }
  case "$out" in *"left open"*) echo "ok   - W6: confirmation printed" ;; *) echo "FAIL - W6: no confirmation: $out"; fail=1 ;; esac

  # --- an unknown stops everything; --keep resolves it (AE6) ---------------
  slug="${L}-unk"; w6_new "$slug" "$layout"
  mkdir -p "$(w6_wt "$slug")/scratch"; echo "my notes" > "$(w6_wt "$slug")/scratch/notes.txt"
  echo noise > "$(w6_wt "$slug")/app.log"
  before="$(cat "$(w6_file "$slug")")"
  out="$(cmd_done "$(session_for "$slug")" 2>&1)"; rc=$?
  [ "$rc" -eq 1 ] && echo "ok   - W6: unknown entry exits 1" || { echo "FAIL - W6: unknown exit $rc"; fail=1; }
  assert "W6: stop names the entry" 'unknown: scratch/notes\.txt' "$out"
  assert "W6: stop names the flags and the list file" 'wb-done-sweep\.list.*\-\-keep.*\-\-throwaway' "$out"
  [ -d "$(w6_wt "$slug")" ] && [ -f "$(w6_wt "$slug")/app.log" ] && echo "ok   - W6: worktree untouched" || { echo "FAIL - W6: worktree changed"; fail=1; }
  assert "W6: status unchanged" '^doing$' "$(w6_status "$slug")"
  [ "$(cat "$(w6_file "$slug")")" = "$before" ] && echo "ok   - W6: task file byte-identical" || { echo "FAIL - W6: task file changed"; fail=1; }
  [ ! -e "$(w6_dossier "$slug")" ] && echo "ok   - W6: no dossier created" || { echo "FAIL - W6: dossier created"; fail=1; }
  out="$(cmd_done "$(session_for "$slug")" --keep scratch/notes.txt 2>&1)"; rc=$?
  [ "$rc" -eq 0 ] && echo "ok   - W6: re-run with --keep succeeds" || { echo "FAIL - W6: --keep re-run exit $rc: $out"; fail=1; }
  [ "$(cat "$(w6_dossier "$slug")/scratch/notes.txt" 2>/dev/null)" = "my notes" ] && echo "ok   - W6: kept file in the dossier" || { echo "FAIL - W6: kept file missing"; fail=1; }
  assert "W6: handoff has the kept: line" '^kept: scratch/notes\.txt$' "$(cat "$(w6_file "$slug")")"
  [ ! -d "$(w6_wt "$slug")" ] && echo "ok   - W6: worktree removed after the re-run" || { echo "FAIL - W6: worktree remains"; fail=1; }
done

# --- a keeper inside a throwaway directory is copied before the removal -----
slug=w6dossier-inlogs; w6_new "$slug" dossier
mkdir -p "$(w6_wt "$slug")/logs"; echo keepme > "$(w6_wt "$slug")/logs/notes.log"; echo drop > "$(w6_wt "$slug")/logs/other.log"
out="$(cmd_done "$(session_for "$slug")" --keep logs/notes.log 2>&1)"; rc=$?
[ "$rc" -eq 0 ] && echo "ok   - W6 keep inside throwaway dir: exits 0" || { echo "FAIL - W6 keep inside throwaway dir: exit $rc: $out"; fail=1; }
[ "$(cat "$(w6_dossier "$slug")/logs/notes.log" 2>/dev/null)" = keepme ] && echo "ok   - W6 keep inside throwaway dir: file copied before the removal" || { echo "FAIL - W6 keep inside throwaway dir: file lost"; fail=1; }
[ ! -e "$(w6_dossier "$slug")/logs/other.log" ] && echo "ok   - W6 keep inside throwaway dir: its sibling not copied" || { echo "FAIL - W6 keep inside throwaway dir: sibling copied"; fail=1; }
assert "W6 keep inside throwaway dir: record names both" '^kept: logs/notes\.log$' "$(cat "$(w6_file "$slug")")"
assert "W6 keep inside throwaway dir: discarded names logs/" '^discarded: .*logs/' "$(cat "$(w6_file "$slug")")"

# --- symlinks are copied as links, never dereferenced -----------------------
slug=w6dossier-link; w6_new "$slug" dossier
mkdir -p "$(w6_wt "$slug")/scratch"; echo target > "$(w6_wt "$slug")/scratch/notes.txt"; ln -s notes.txt "$(w6_wt "$slug")/scratch/ln"
# A kept DIRECTORY holding any symlink stops the run (the link would dangle in
# the dossier once the worktree is gone); the kept link itself still copies as a link.
out="$(cmd_done "$(session_for "$slug")" --keep scratch 2>&1)"; rc=$?
[ "$rc" -eq 1 ] && echo "ok   - W6 symlink in a kept dir: stops" || { echo "FAIL - W6 symlink in a kept dir: exit $rc: $out"; fail=1; }
assert "W6 symlink in a kept dir: note names the link" 'unknown: scratch/ — holds symlink scratch/ln; keep its target or remove the link' "$out"
[ -d "$(w6_wt "$slug")" ] && [ ! -e "$(w6_dossier "$slug")/scratch" ] && echo "ok   - W6 symlink in a kept dir: nothing changed" || { echo "FAIL - W6 symlink in a kept dir: state changed"; fail=1; }
out="$(cmd_done "$(session_for "$slug")" --keep scratch/ln --throwaway scratch/notes.txt 2>&1)"; rc=$?
[ "$rc" -eq 0 ] && echo "ok   - W6 symlink keep: exits 0" || { echo "FAIL - W6 symlink keep: exit $rc: $out"; fail=1; }
[ -L "$(w6_dossier "$slug")/scratch/ln" ] && [ "$(readlink "$(w6_dossier "$slug")/scratch/ln")" = notes.txt ] && echo "ok   - W6 symlink keep: copied as a symlink" || { echo "FAIL - W6 symlink keep: not a symlink copy"; fail=1; }

# --- a copy that fails stops before the removal (KTD6) ----------------------
if [ "$(id -u)" -ne 0 ]; then
  slug=w6dossier-rofail; w6_new "$slug" dossier
  printf 'queued\n' > "$(w6_wt "$slug")/.claude-queue.md"
  mkdir -p "$(w6_dossier "$slug")"; chmod 555 "$(w6_dossier "$slug")"
  before="$(cat "$(w6_file "$slug")")"
  out="$(cmd_done "$(session_for "$slug")" 2>&1)"; rc=$?
  chmod 755 "$(w6_dossier "$slug")"
  [ "$rc" -eq 1 ] && echo "ok   - W6 failed copy: exits 1" || { echo "FAIL - W6 failed copy: exit $rc: $out"; fail=1; }
  [ -d "$(w6_wt "$slug")" ] && [ -f "$(w6_wt "$slug")/.claude-queue.md" ] && echo "ok   - W6 failed copy: worktree still present" || { echo "FAIL - W6 failed copy: worktree gone"; fail=1; }
  assert "W6 failed copy: status unchanged" '^doing$' "$(w6_status "$slug")"
  [ "$(cat "$(w6_file "$slug")")" = "$before" ] && echo "ok   - W6 failed copy: task file byte-identical" || { echo "FAIL - W6 failed copy: task file changed"; fail=1; }
fi

# --- a LATER keeper's copy fails after an earlier one succeeded --------------
# The first keeper (.claude-queue.md) was created by this run, so it is rolled
# back (its dossier file was absent before); the failed keeper merged into a
# dossier directory that already existed, so nothing there is deleted and the
# message says partial files may remain. The run still stops before removing
# the worktree or touching the task file. (Review triage, finding 4: this used
# to pin "the first keeper stays in the dossier".)
if [ "$(id -u)" -ne 0 ]; then
  slug=w6dossier-rofail2; w6_new "$slug" dossier
  printf 'queued\n' > "$(w6_wt "$slug")/.claude-queue.md"
  mkdir -p "$(w6_wt "$slug")/scratch"; echo "mine" > "$(w6_wt "$slug")/scratch/a.txt"
  mkdir -p "$(w6_dossier "$slug")/scratch"; chmod 555 "$(w6_dossier "$slug")/scratch"
  echo "pre-existing" > "$(w6_dossier "$slug")/old.txt"
  before="$(cat "$(w6_file "$slug")")"
  out="$(cmd_done "$(session_for "$slug")" --keep scratch 2>&1)"; rc=$?
  chmod 755 "$(w6_dossier "$slug")/scratch"
  [ "$rc" -eq 1 ] && echo "ok   - W6 later copy fails: exits 1" || { echo "FAIL - W6 later copy fails: exit $rc: $out"; fail=1; }
  assert "W6 later copy fails: says the copy failed" 'copying scratch into .* failed' "$out"
  assert "W6 later copy fails: says partial files may remain" 'keeper scratch failed partway.*partial files from it may remain under .*/scratch' "$out"
  [ -d "$(w6_wt "$slug")" ] && [ -f "$(w6_wt "$slug")/scratch/a.txt" ] && echo "ok   - W6 later copy fails: worktree still present" || { echo "FAIL - W6 later copy fails: worktree gone"; fail=1; }
  assert "W6 later copy fails: status unchanged" '^doing$' "$(w6_status "$slug")"
  [ "$(cat "$(w6_file "$slug")")" = "$before" ] && echo "ok   - W6 later copy fails: task file byte-identical" || { echo "FAIL - W6 later copy fails: task file changed"; fail=1; }
  [ ! -e "$(w6_dossier "$slug")/.claude-queue.md" ] && echo "ok   - W6 later copy fails: the first keeper (created this run) is rolled back" || { echo "FAIL - W6 later copy fails: first keeper left in the dossier"; fail=1; }
  [ "$(cat "$(w6_dossier "$slug")/old.txt" 2>/dev/null)" = pre-existing ] && [ -d "$(w6_dossier "$slug")/scratch" ] && echo "ok   - W6 later copy fails: pre-existing dossier content untouched" || { echo "FAIL - W6 later copy fails: pre-existing content removed"; fail=1; }
  [ ! -e "$(w6_dossier "$slug")/scratch/a.txt" ] && echo "ok   - W6 later copy fails: the failed keeper was not copied" || { echo "FAIL - W6 later copy fails: a.txt copied"; fail=1; }

  # A directory keeper that did not exist in the dossier before the run and dies
  # partway (an unreadable file) is removed whole, along with the earlier keeper.
  slug=w6dossier-rofail3; w6_new "$slug" dossier
  printf 'queued\n' > "$(w6_wt "$slug")/.claude-queue.md"
  mkdir -p "$(w6_wt "$slug")/scratch"; echo a > "$(w6_wt "$slug")/scratch/a.txt"; echo b > "$(w6_wt "$slug")/scratch/b.txt"
  chmod 000 "$(w6_wt "$slug")/scratch/b.txt"
  out="$(cmd_done "$(session_for "$slug")" --keep scratch 2>&1)"; rc=$?
  chmod 644 "$(w6_wt "$slug")/scratch/b.txt"
  [ "$rc" -eq 1 ] && echo "ok   - W6 new-dir copy fails: exits 1" || { echo "FAIL - W6 new-dir copy fails: exit $rc: $out"; fail=1; }
  [ ! -e "$(w6_dossier "$slug")/scratch" ] && [ ! -e "$(w6_dossier "$slug")/.claude-queue.md" ] && echo "ok   - W6 new-dir copy fails: everything this run created is removed" || { echo "FAIL - W6 new-dir copy fails: leftovers in $(find "$(w6_dossier "$slug")" 2>&1 | tr '\n' ' ')"; fail=1; }
  assert "W6 new-dir copy fails: lists what it removed" 'removed: .*scratch' "$out"
  [ -d "$(w6_wt "$slug")" ] && assert "W6 new-dir copy fails: status unchanged" '^doing$' "$(w6_status "$slug")"
fi

# --- an unlisted directory of many unknowns: at most 10 lines per entry ------
slug=w6dossier-many; w6_new "$slug" dossier
mkdir -p "$(w6_wt "$slug")/scratch"; for i in 01 02 03 04 05 06 07 08 09 10 11 12 13; do echo x > "$(w6_wt "$slug")/scratch/f$i.txt"; done
out="$(cmd_done "$(session_for "$slug")" 2>&1)"; rc=$?
[ "$rc" -eq 1 ] && echo "ok   - W6 many unknowns: stops" || { echo "FAIL - W6 many unknowns: exit $rc"; fail=1; }
[ "$(printf '%s\n' "$out" | grep -c '^  unknown: scratch/')" = 10 ] && echo "ok   - W6 many unknowns: exactly 10 unknown lines for scratch/" || { echo "FAIL - W6 many unknowns: $(printf '%s\n' "$out" | grep -c '^  unknown: scratch/') lines"; fail=1; }
assert "W6 many unknowns: the summary line" '^  … and 3 more under scratch/ \(add `throwaway:scratch/` to wb-done-sweep\.list or re-run with --throwaway scratch\)$' "$out"
assert "W6 many unknowns: header still counts all 13" '13 gitignored entries' "$out"
# a name holding an ESC byte is shown as \x1b, never sent raw
slug=w6dossier-esc; w6_new "$slug" dossier
mkdir -p "$(w6_wt "$slug")/scratch"; echo x > "$(w6_wt "$slug")/scratch/"$'\e'"[31mred.txt"
out="$(cmd_done "$(session_for "$slug")" 2>&1)"
assert "W6 ESC in a name: shown as \\x1b" 'unknown: scratch/\\x1b\[31mred\.txt' "$out"
case "$out" in *$'\e'*) echo "FAIL - W6 ESC in a name: raw ESC reached the output"; fail=1 ;; *) echo "ok   - W6 ESC in a name: no raw ESC in the output" ;; esac

# --- --review: an edit to a tracked file made while the buffer is open stops -
slug=w6dossier-reviewdirty; w6_new "$slug" dossier
wb_open_buffer() { echo "$1" >> "$W6_BUFLOG"; echo "edited meanwhile" >> "$(w6_wt w6dossier-reviewdirty)/.worktree-bootstrap"; }
: > "$W6_BUFLOG"
before="$(cat "$(w6_file "$slug")")"
out="$(cmd_done "$(session_for "$slug")" --review 2>&1)"; rc=$?
wb_open_buffer() { echo "$1" >> "$W6_BUFLOG"; }
[ "$rc" -eq 1 ] && echo "ok   - W6 --review dirty after buffer: exits 1" || { echo "FAIL - W6 --review dirty after buffer: exit $rc: $out"; fail=1; }
assert "W6 --review dirty after buffer: names the dirty tree" 'is dirty' "$out"
[ -d "$(w6_wt "$slug")" ] && [ "$(tail -1 "$(w6_wt "$slug")/.worktree-bootstrap")" = "edited meanwhile" ] && echo "ok   - W6 --review dirty after buffer: worktree and the edit kept" || { echo "FAIL - W6 --review dirty after buffer: worktree gone"; fail=1; }
[ "$(cat "$(w6_file "$slug")")" = "$before" ] && echo "ok   - W6 --review dirty after buffer: task file untouched" || { echo "FAIL - W6 --review dirty after buffer: task file changed"; fail=1; }

# --- a folder git no longer lists as a worktree stops with a clear message ----
slug=w6dossier-notwt; w6_new "$slug" dossier
rm -rf "$SWP/.git/worktrees/$slug"   # what a half-failed `git worktree remove` can leave behind
before="$(cat "$(w6_file "$slug")")"
out="$(cmd_done "$(session_for "$slug")" 2>&1)"; rc=$?
[ "$rc" -eq 1 ] && echo "ok   - W6 not a worktree: exits 1" || { echo "FAIL - W6 not a worktree: exit $rc: $out"; fail=1; }
assert "W6 not a worktree: the message" 'is no longer a git worktree \(a removal half-failed\?\); check what.s left in it, delete it by hand, then run git worktree prune and re-run' "$out"
[ -d "$(w6_wt "$slug")" ] && [ "$(cat "$(w6_file "$slug")")" = "$before" ] && echo "ok   - W6 not a worktree: nothing changed" || { echo "FAIL - W6 not a worktree: state changed"; fail=1; }

# --- collisions with what the dossier already holds stop the run ------------
slug=w6dossier-collide; w6_new "$slug" dossier
echo "worktree notes" > "$(w6_wt "$slug")/memo.md"
mkdir -p "$(w6_wt "$slug")/scratch"; echo "mine" > "$(w6_wt "$slug")/scratch/a.txt"
mkdir -p "$(w6_dossier "$slug")/scratch"
echo "dossier memo" > "$(w6_dossier "$slug")/memo.md"; echo "other" > "$(w6_dossier "$slug")/scratch/a.txt"
before="$(cat "$(w6_file "$slug")")"; dbefore="$(cat "$(w6_dossier "$slug")/memo.md" "$(w6_dossier "$slug")/scratch/a.txt")"
out="$(cmd_done "$(session_for "$slug")" --keep memo.md --keep scratch/a.txt 2>&1)"; rc=$?
[ "$rc" -eq 1 ] && echo "ok   - W6 collision: exits 1" || { echo "FAIL - W6 collision: exit $rc: $out"; fail=1; }
assert "W6 collision: names the dossier memo.md" "collides: .*dossiers/swp--${slug}/memo\\.md" "$out"
assert "W6 collision: names the nested colliding file" "collides: .*dossiers/swp--${slug}/scratch/a\\.txt" "$out"
[ -d "$(w6_wt "$slug")" ] && echo "ok   - W6 collision: worktree present" || { echo "FAIL - W6 collision: worktree gone"; fail=1; }
assert "W6 collision: status unchanged" '^doing$' "$(w6_status "$slug")"
[ "$(cat "$(w6_file "$slug")")" = "$before" ] && echo "ok   - W6 collision: task file byte-identical" || { echo "FAIL - W6 collision: task file changed"; fail=1; }
[ "$(cat "$(w6_dossier "$slug")/memo.md" "$(w6_dossier "$slug")/scratch/a.txt")" = "$dbefore" ] && echo "ok   - W6 collision: dossier files untouched" || { echo "FAIL - W6 collision: dossier changed"; fail=1; }
# identical copies are skipped but still listed as kept
echo "dossier memo" > "$(w6_wt "$slug")/memo.md"; echo "other" > "$(w6_wt "$slug")/scratch/a.txt"
out="$(cmd_done "$(session_for "$slug")" --keep memo.md --keep scratch/a.txt 2>&1)"; rc=$?
[ "$rc" -eq 0 ] && echo "ok   - W6 identical copies: exits 0" || { echo "FAIL - W6 identical copies: exit $rc: $out"; fail=1; }
assert "W6 identical copies: still listed as kept" '^kept: memo\.md, scratch/a\.txt$' "$(cat "$(w6_file "$slug")")"
[ "$(cat "$(w6_dossier "$slug")/memo.md")" = "dossier memo" ] && echo "ok   - W6 identical copies: dossier memo.md intact" || { echo "FAIL - W6 identical copies: memo.md changed"; fail=1; }

# --- the queue file merges into the dossier's copy (review round 3, finding 1) --
qhead() { printf '## 2026-11-0%sT10:00:0%s\n\n%s\n\n' "$1" "$2" "$3"; }
slug=w6dossier-queuemerge; w6_new "$slug" dossier
mkdir -p "$(w6_dossier "$slug")"
{ qhead 1 1 one; qhead 1 2 two; } > "$(w6_dossier "$slug")/.claude-queue.md"
{ qhead 1 2 two; qhead 1 3 three; qhead 1 4 four; } > "$(w6_wt "$slug")/.claude-queue.md"
out="$(cmd_done "$(session_for "$slug")" 2>&1)"; rc=$?
[ "$rc" -eq 0 ] && echo "ok   - W6 queue merge: exits 0 (a different dossier copy is no collision)" || { echo "FAIL - W6 queue merge: exit $rc: $out"; fail=1; }
exp="$({ qhead 1 1 one; qhead 1 2 two; qhead 1 3 three; qhead 1 4 four; })"
[ "$(cat "$(w6_dossier "$slug")/.claude-queue.md")" = "$exp" ] && echo "ok   - W6 queue merge: overlapping block not duplicated, new ones appended in order" || { echo "FAIL - W6 queue merge: got: $(cat "$(w6_dossier "$slug")/.claude-queue.md")"; fail=1; }
assert "W6 queue merge: handoff still lists the queue file as kept" '^kept: \.claude-queue\.md$' "$(cat "$(w6_file "$slug")")"
# a second merge of the same worktree file adds nothing (skipped as already there)
mkdir -p "$FIXTURE_STATE/qagain"; cp "$(w6_dossier "$slug")/.claude-queue.md" "$FIXTURE_STATE/qagain/before"
mkdir -p "$FIXTURE_STATE/qagain/wt"; { qhead 1 2 two; qhead 1 3 three; qhead 1 4 four; } > "$FIXTURE_STATE/qagain/wt/.claude-queue.md"
( _wb_done_keep_all "$FIXTURE_STATE/qagain/wt" "$(w6_dossier "$slug")" .claude-queue.md ) >/dev/null 2>&1; rc=$?
cmp -s "$FIXTURE_STATE/qagain/before" "$(w6_dossier "$slug")/.claude-queue.md" && [ "$rc" -eq 0 ] && echo "ok   - W6 queue merge: running it again changes nothing" || { echo "FAIL - W6 queue merge: second merge changed the file (rc $rc)"; fail=1; }
# a new block gets appended after a dossier copy with no final newline
printf '%s' "$(qhead 2 1 nonl)" > "$FIXTURE_STATE/qagain/nonl";
mkdir -p "$FIXTURE_STATE/qagain/d2"; cp "$FIXTURE_STATE/qagain/nonl" "$FIXTURE_STATE/qagain/d2/.claude-queue.md"
{ qhead 2 1 nonl; qhead 2 2 more; } > "$FIXTURE_STATE/qagain/wt/.claude-queue.md"
( _wb_done_keep_all "$FIXTURE_STATE/qagain/wt" "$FIXTURE_STATE/qagain/d2" .claude-queue.md ) >/dev/null 2>&1
[ "$(grep -c '^## 2026-11-02T' "$FIXTURE_STATE/qagain/d2/.claude-queue.md")" = 2 ] && [ "$(/usr/bin/grep -c 'more' "$FIXTURE_STATE/qagain/d2/.claude-queue.md")" = 1 ] && grep -q '^nonl$' "$FIXTURE_STATE/qagain/d2/.claude-queue.md" && echo "ok   - W6 queue merge: dossier copy without a final newline gets one before the append" || { echo "FAIL - W6 queue merge: no-final-newline case: $(cat "$FIXTURE_STATE/qagain/d2/.claude-queue.md")"; fail=1; }

# identical files: still skipped, still listed as kept
slug=w6dossier-queuesame; w6_new "$slug" dossier
mkdir -p "$(w6_dossier "$slug")"; { qhead 1 1 one; } > "$(w6_dossier "$slug")/.claude-queue.md"; cp "$(w6_dossier "$slug")/.claude-queue.md" "$(w6_wt "$slug")/.claude-queue.md"
cp "$(w6_dossier "$slug")/.claude-queue.md" "$FIXTURE_STATE/qsame.before"
out="$(cmd_done "$(session_for "$slug")" 2>&1)"; rc=$?
[ "$rc" -eq 0 ] && cmp -s "$FIXTURE_STATE/qsame.before" "$(w6_dossier "$slug")/.claude-queue.md" && echo "ok   - W6 queue identical: exits 0, dossier copy untouched" || { echo "FAIL - W6 queue identical: rc $rc: $out"; fail=1; }
assert "W6 queue identical: still listed as kept" '^kept: \.claude-queue\.md$' "$(cat "$(w6_file "$slug")")"

# same-second headings with different bodies are both kept
slug=w6dossier-queuesec; w6_new "$slug" dossier
mkdir -p "$(w6_dossier "$slug")"; { qhead 1 1 alpha; } > "$(w6_dossier "$slug")/.claude-queue.md"
{ qhead 1 1 alpha; qhead 1 1 beta; } > "$(w6_wt "$slug")/.claude-queue.md"
out="$(cmd_done "$(session_for "$slug")" 2>&1)"; rc=$?
[ "$rc" -eq 0 ] && [ "$(cat "$(w6_dossier "$slug")/.claude-queue.md")" = "$({ qhead 1 1 alpha; qhead 1 1 beta; })" ] && echo "ok   - W6 queue same-second: both bodies kept, no duplicate" || { echo "FAIL - W6 queue same-second: rc $rc: $(cat "$(w6_dossier "$slug")/.claude-queue.md")"; fail=1; }

# text before the first heading is a block of its own
slug=w6dossier-queuepre; w6_new "$slug" dossier
mkdir -p "$(w6_dossier "$slug")"; { qhead 1 1 alpha; } > "$(w6_dossier "$slug")/.claude-queue.md"
{ printf 'loose preamble\n'; qhead 1 1 alpha; } > "$(w6_wt "$slug")/.claude-queue.md"
cmd_done "$(session_for "$slug")" >/dev/null 2>&1
[ "$(grep -c 'loose preamble' "$(w6_dossier "$slug")/.claude-queue.md")" = 1 ] && [ "$(grep -c alpha "$(w6_dossier "$slug")/.claude-queue.md")" = 1 ] && echo "ok   - W6 queue preamble: kept as its own block" || { echo "FAIL - W6 queue preamble: $(cat "$(w6_dossier "$slug")/.claude-queue.md")"; fail=1; }

# the dossier copy is a directory: still a collision
slug=w6dossier-queuedir; w6_new "$slug" dossier
mkdir -p "$(w6_dossier "$slug")/.claude-queue.md"; { qhead 1 1 alpha; } > "$(w6_wt "$slug")/.claude-queue.md"
before="$(cat "$(w6_file "$slug")")"
out="$(cmd_done "$(session_for "$slug")" 2>&1)"; rc=$?
[ "$rc" -eq 1 ] && echo "ok   - W6 queue dir collision: exits 1" || { echo "FAIL - W6 queue dir collision: exit $rc: $out"; fail=1; }
assert "W6 queue dir collision: a collides: line" "collides: .*dossiers/swp--${slug}/\\.claude-queue\\.md\$" "$out"
[ -d "$(w6_wt "$slug")" ] && [ "$(cat "$(w6_file "$slug")")" = "$before" ] && echo "ok   - W6 queue dir collision: nothing changed" || { echo "FAIL - W6 queue dir collision: state changed"; fail=1; }
# a different OTHER kept file in the dossier is still a collision (unchanged rule)
slug=w6dossier-queueother; w6_new "$slug" dossier
mkdir -p "$(w6_dossier "$slug")/scratch" "$(w6_wt "$slug")/scratch"; echo a > "$(w6_wt "$slug")/scratch/q.md"; echo b > "$(w6_dossier "$slug")/scratch/q.md"
out="$(cmd_done "$(session_for "$slug")" --keep scratch/q.md 2>&1)"; rc=$?
[ "$rc" -eq 1 ] && echo "ok   - W6 queue merge is queue-only: other differing files still collide" || { echo "FAIL - W6 other collision: exit $rc: $out"; fail=1; }

# rollback: a later keeper fails after the queue file was appended to
if [ "$(id -u)" -ne 0 ]; then
  slug=w6dossier-queueroll; w6_new "$slug" dossier
  mkdir -p "$(w6_dossier "$slug")"; { qhead 1 1 one; } > "$(w6_dossier "$slug")/.claude-queue.md"
  cp "$(w6_dossier "$slug")/.claude-queue.md" "$FIXTURE_STATE/qroll.before"
  { qhead 1 1 one; qhead 1 2 two; } > "$(w6_wt "$slug")/.claude-queue.md"
  mkdir -p "$(w6_wt "$slug")/scratch"; echo a > "$(w6_wt "$slug")/scratch/a.txt"; echo b > "$(w6_wt "$slug")/scratch/b.txt"
  chmod 000 "$(w6_wt "$slug")/scratch/b.txt"
  out="$(cmd_done "$(session_for "$slug")" --keep scratch 2>&1)"; rc=$?
  chmod 644 "$(w6_wt "$slug")/scratch/b.txt"
  [ "$rc" -eq 1 ] && echo "ok   - W6 queue rollback: exits 1" || { echo "FAIL - W6 queue rollback: exit $rc: $out"; fail=1; }
  cmp -s "$FIXTURE_STATE/qroll.before" "$(w6_dossier "$slug")/.claude-queue.md" && echo "ok   - W6 queue rollback: the dossier queue file is back to its exact original bytes" || { echo "FAIL - W6 queue rollback: dossier queue file is: $(cat "$(w6_dossier "$slug")/.claude-queue.md")"; fail=1; }
  assert "W6 queue rollback: says it restored the file" 'restored .*\.claude-queue\.md' "$out"
  [ ! -e "$(w6_dossier "$slug")/scratch" ] && echo "ok   - W6 queue rollback: new dir removed too" || { echo "FAIL - W6 queue rollback: scratch left"; fail=1; }
fi

# --- dossier record names are refused as keeps (review round 3, finding 2) ----
slug=w6dossier-recname; w6_new "$slug" dossier
mkdir -p "$(w6_wt "$slug")/decisions" "$(w6_wt "$slug")/scratch"
echo d > "$(w6_wt "$slug")/decisions/d.md"; echo n > "$(w6_wt "$slug")/notes.md"; echo s > "$(w6_wt "$slug")/scratch/notes.md"
before="$(cat "$(w6_file "$slug")")"
out="$(cmd_done "$(session_for "$slug")" --keep decisions --throwaway notes.md --throwaway scratch 2>&1)"; rc=$?
[ "$rc" -eq 1 ] && echo "ok   - W6 record name decisions: stops" || { echo "FAIL - W6 record name decisions: exit $rc: $out"; fail=1; }
assert "W6 record name decisions: unknown with the note" 'unknown: decisions/ — a dossier record name; rename it first' "$out"
out="$(cmd_done "$(session_for "$slug")" --keep notes.md --throwaway decisions --throwaway scratch 2>&1)"; rc=$?
[ "$rc" -eq 1 ] && echo "ok   - W6 record name notes.md: stops" || { echo "FAIL - W6 record name notes.md: exit $rc: $out"; fail=1; }
assert "W6 record name notes.md: unknown with the note" 'unknown: notes\.md — a dossier record name; rename it first' "$out"
[ -d "$(w6_wt "$slug")" ] && [ "$(cat "$(w6_file "$slug")")" = "$before" ] && [ ! -e "$(w6_dossier "$slug")/notes.md" ] && echo "ok   - W6 record names: nothing changed" || { echo "FAIL - W6 record names: state changed"; fail=1; }
out="$(cmd_done "$(session_for "$slug")" --keep scratch/notes.md --throwaway notes.md --throwaway decisions 2>&1)"; rc=$?
[ "$rc" -eq 0 ] && [ "$(cat "$(w6_dossier "$slug")/scratch/notes.md" 2>/dev/null)" = s ] && echo "ok   - W6 record names: scratch/notes.md (not top level) is still kept" || { echo "FAIL - W6 scratch/notes.md: exit $rc: $out"; fail=1; }

# --- more collision shapes (all stop before anything changes) ---------------
# (1) --keep scratch onto an existing dossier/scratch merges: no scratch/scratch
slug=w6dossier-merge; w6_new "$slug" dossier
mkdir -p "$(w6_wt "$slug")/scratch" "$(w6_dossier "$slug")/scratch"
echo "new" > "$(w6_wt "$slug")/scratch/new.txt"; echo "kept already" > "$(w6_dossier "$slug")/scratch/sibling.txt"
out="$(cmd_done "$(session_for "$slug")" --keep scratch 2>&1)"; rc=$?
[ "$rc" -eq 0 ] && echo "ok   - W6 merge into dossier dir: exits 0" || { echo "FAIL - W6 merge into dossier dir: exit $rc: $out"; fail=1; }
[ ! -e "$(w6_dossier "$slug")/scratch/scratch" ] && echo "ok   - W6 merge into dossier dir: no scratch/scratch" || { echo "FAIL - W6 merge: scratch/scratch created"; fail=1; }
[ "$(cat "$(w6_dossier "$slug")/scratch/sibling.txt")" = "kept already" ] && echo "ok   - W6 merge into dossier dir: existing sibling intact" || { echo "FAIL - W6 merge: sibling changed"; fail=1; }
[ "$(cat "$(w6_dossier "$slug")/scratch/new.txt" 2>/dev/null)" = new ] && echo "ok   - W6 merge into dossier dir: new file merged in" || { echo "FAIL - W6 merge: new.txt missing"; fail=1; }
# (2) dossier/scratch is a regular file, the worktree's scratch/ a directory
slug=w6dossier-filevsdir; w6_new "$slug" dossier
mkdir -p "$(w6_wt "$slug")/scratch"; echo x > "$(w6_wt "$slug")/scratch/a.txt"
mkdir -p "$(w6_dossier "$slug")"; echo "i am a file" > "$(w6_dossier "$slug")/scratch"
before="$(cat "$(w6_file "$slug")")"
out="$(cmd_done "$(session_for "$slug")" --keep scratch 2>&1)"; rc=$?
[ "$rc" -eq 1 ] && echo "ok   - W6 file-vs-dir collision: exits 1" || { echo "FAIL - W6 file-vs-dir: exit $rc: $out"; fail=1; }
assert "W6 file-vs-dir collision: a collides: line" "collides: .*dossiers/swp--${slug}/scratch\$" "$out"
[ -f "$(w6_wt "$slug")/scratch/a.txt" ] && [ "$(cat "$(w6_file "$slug")")" = "$before" ] && echo "ok   - W6 file-vs-dir collision: worktree and task file intact" || { echo "FAIL - W6 file-vs-dir: state changed"; fail=1; }
# (3) dossier/extra is a regular file and --keep extra/x.txt
printf 'extra/\n' >> "$SWP/.git/info/exclude"
slug=w6dossier-ancfile; w6_new "$slug" dossier
mkdir -p "$(w6_wt "$slug")/extra"; echo x > "$(w6_wt "$slug")/extra/x.txt"
mkdir -p "$(w6_dossier "$slug")"; echo "i am a file" > "$(w6_dossier "$slug")/extra"
before="$(cat "$(w6_file "$slug")")"
out="$(cmd_done "$(session_for "$slug")" --keep extra/x.txt 2>&1)"; rc=$?
[ "$rc" -eq 1 ] && echo "ok   - W6 file-ancestor collision: exits 1" || { echo "FAIL - W6 file-ancestor: exit $rc: $out"; fail=1; }
assert "W6 file-ancestor collision: a collides: line naming extra" "collides: .*dossiers/swp--${slug}/extra\$" "$out"
[ -f "$(w6_wt "$slug")/extra/x.txt" ] && [ "$(cat "$(w6_file "$slug")")" = "$before" ] && echo "ok   - W6 file-ancestor collision: worktree and task file intact" || { echo "FAIL - W6 file-ancestor: state changed"; fail=1; }
# (4) the dossier path itself is a regular file
slug=w6dossier-selffile; w6_new "$slug" dossier
printf 'queued\n' > "$(w6_wt "$slug")/.claude-queue.md"
mkdir -p "$FIXTURE_TASKS/dossiers"; echo "i am a file" > "$(w6_dossier "$slug")"
before="$(cat "$(w6_file "$slug")")"
out="$(cmd_done "$(session_for "$slug")" 2>&1)"; rc=$?
[ "$rc" -eq 1 ] && echo "ok   - W6 dossier-is-a-file: exits 1" || { echo "FAIL - W6 dossier-is-a-file: exit $rc: $out"; fail=1; }
assert "W6 dossier-is-a-file: the (the dossier itself) stop" 'collides: .*\(the dossier itself\)' "$out"
[ -f "$(w6_wt "$slug")/.claude-queue.md" ] && [ "$(cat "$(w6_file "$slug")")" = "$before" ] && echo "ok   - W6 dossier-is-a-file: worktree and task file intact" || { echo "FAIL - W6 dossier-is-a-file: state changed"; fail=1; }

# --- a bootstrap config.hjson: edited stops, identical is discarded (AE5) ---
slug=w6dossier-cfgedit; w6_new "$slug" dossier
echo "my edit" > "$(w6_wt "$slug")/config.hjson"
out="$(cmd_done "$(session_for "$slug")" 2>&1)"; rc=$?
[ "$rc" -eq 1 ] && echo "ok   - W6 AE5: edited config.hjson stops the run" || { echo "FAIL - W6 AE5: exit $rc: $out"; fail=1; }
assert "W6 AE5: names config.hjson" 'unknown: config\.hjson' "$out"
[ -d "$(w6_wt "$slug")" ] && echo "ok   - W6 AE5: worktree present" || { echo "FAIL - W6 AE5: worktree gone"; fail=1; }
out="$(cmd_done "$(session_for "$slug")" --keep config.hjson 2>&1)"; rc=$?
[ "$rc" -eq 1 ] && echo "ok   - W6 AE5: --keep cannot copy a credential-shaped file" || { echo "FAIL - W6 AE5: --keep exit $rc"; fail=1; }
[ ! -e "$(w6_dossier "$slug")/config.hjson" ] && echo "ok   - W6 AE5: never copied into the dossier" || { echo "FAIL - W6 AE5: config.hjson in the dossier"; fail=1; }
slug=w6dossier-cfgsame; w6_new "$slug" dossier
out="$(cmd_done "$(session_for "$slug")" 2>&1)"; rc=$?
[ "$rc" -eq 0 ] && echo "ok   - W6 AE5: identical config.hjson closes normally" || { echo "FAIL - W6 AE5 identical: exit $rc: $out"; fail=1; }
assert "W6 AE5: identical config.hjson is discarded" '^discarded: config\.hjson$' "$(cat "$(w6_file "$slug")")"

# --- --review: classify, buffer once, classify again, act on the second ------
slug=w6dossier-review; w6_new "$slug" dossier
echo noise > "$(w6_wt "$slug")/app.log"
: > "$W6_BUFLOG"
wb_open_buffer() { echo "$1" >> "$W6_BUFLOG"; printf '\nreview note\n' >> "$1"; }
out="$(cmd_done "$(session_for "$slug")" --review 2>&1)"; rc=$?
[ "$rc" -eq 0 ] && echo "ok   - W6 --review: exits 0" || { echo "FAIL - W6 --review: exit $rc: $out"; fail=1; }
[ "$(w6_calls)" = 1 ] && echo "ok   - W6 --review: buffer opened exactly once" || { echo "FAIL - W6 --review: buffer calls $(w6_calls)"; fail=1; }
assert "W6 --review: a buffer edit survives the final burst" '^review note$' "$(cat "$(w6_file "$slug")")"
assert "W6 --review: task done" '^done$' "$(w6_status "$slug")"
# an unknown present BEFORE the buffer stops without opening it
slug=w6dossier-reviewunk; w6_new "$slug" dossier
mkdir -p "$(w6_wt "$slug")/scratch"; echo x > "$(w6_wt "$slug")/scratch/n.txt"
: > "$W6_BUFLOG"
out="$(cmd_done "$(session_for "$slug")" --review 2>&1)"; rc=$?
[ "$rc" -eq 1 ] && [ "$(w6_calls)" = 0 ] && echo "ok   - W6 --review: an unknown stops before the buffer opens" || { echo "FAIL - W6 --review: rc $rc, calls $(w6_calls)"; fail=1; }
# a file that appears while the buffer is open is caught by the second pass
slug=w6dossier-reviewlate; w6_new "$slug" dossier
wb_open_buffer() { echo "$1" >> "$W6_BUFLOG"; mkdir -p "$(w6_wt w6dossier-reviewlate)/scratch"; echo late > "$(w6_wt w6dossier-reviewlate)/scratch/late.txt"; }
: > "$W6_BUFLOG"
before="$(cat "$(w6_file "$slug")")"
out="$(cmd_done "$(session_for "$slug")" --review 2>&1)"; rc=$?
[ "$rc" -eq 1 ] && echo "ok   - W6 --review: second classification stops on a late unknown" || { echo "FAIL - W6 --review late: exit $rc: $out"; fail=1; }
[ -d "$(w6_wt "$slug")" ] && [ "$(cat "$(w6_file "$slug")")" = "$before" ] && echo "ok   - W6 --review late: nothing changed" || { echo "FAIL - W6 --review late: state changed"; fail=1; }
wb_open_buffer() { echo "$1" >> "$W6_BUFLOG"; }
# store-only close under --review
so_file="$FIXTURE_TASKS/swp--w6-storeonly.md"
printf -- '---\nstatus: planned\nrepo: swp\nlayout: dossier\ntags: []\ncreated: 2026-11-01\nclosed:\n---\n# Store only\n' > "$so_file"
: > "$W6_BUFLOG"
out="$(cmd_done swp--w6-storeonly --review 2>&1)"; rc=$?
[ "$rc" -eq 0 ] && [ "$(w6_calls)" = 1 ] && echo "ok   - W6 --review store-only: buffer opened once, exits 0" || { echo "FAIL - W6 --review store-only: rc $rc calls $(w6_calls): $out"; fail=1; }
assert "W6 --review store-only: task done" '^done$' "$(wb_get_frontmatter "$so_file" status)"

# --- a retry after the worktree is already gone skips the sweep -------------
slug=w6dossier-gone; w6_new "$slug" dossier
git -C "$SWP" worktree remove --force ".worktrees/$slug"
out="$(cmd_done "$(session_for "$slug")" 2>&1)"; rc=$?
[ "$rc" -eq 0 ] && echo "ok   - W6 retry: worktree already gone, exits 0" || { echo "FAIL - W6 retry: exit $rc: $out"; fail=1; }
assert "W6 retry: status flipped" '^done$' "$(w6_status "$slug")"
case "$(cat "$(w6_file "$slug")")" in *$'\nkept:'*|*$'\ndiscarded:'*) echo "FAIL - W6 retry: record carries kept/discarded lines"; fail=1 ;; *) echo "ok   - W6 retry: no kept/discarded lines" ;; esac

# --- the undecided-drafts check still comes first, before any classification -
slug=w6dossier-drafts; w6_new "$slug" dossier
mkdir -p "$(w6_wt "$slug")/scratch"; echo x > "$(w6_wt "$slug")/scratch/n.txt"
mkdir -p "$CAPROOT/shelved/swp--$slug"; printf 'd\n' > "$CAPROOT/shelved/swp--$slug/20261018T100000-sid-w6.md"
out="$(cmd_done "$(session_for "$slug")" 2>&1)"; rc=$?
assert "W6 drafts first: the draft refusal, not the unknown stop" 'decision draft.*nothing changed' "$out"
case "$out" in *"unknown:"*) echo "FAIL - W6 drafts first: classifier ran first"; fail=1 ;; *) echo "ok   - W6 drafts first: classifier not reached" ;; esac

# --- ctrl-x on a worktree with an unknown entry shows the stop in a popup ----
slug=w6dossier-ctrlx; w6_new "$slug" dossier
mkdir -p "$(w6_wt "$slug")/scratch"; echo x > "$(w6_wt "$slug")/scratch/n.txt"
POPUP_OUT="$FIXTURE_STATE/w6-popup"; : > "$POPUP_OUT"
tmux() {   # stub only display-popup; everything else is the real tmux
  if [ "${1:-}" = display-popup ]; then
    local last="${*: -1}" pf
    pf="$(printf '%s' "$last" | sed -n 's/^cat \([^;]*\);.*/\1/p')"
    [ -f "$pf" ] && cat "$pf" >> "$POPUP_OUT"
    return 0
  fi
  command tmux "$@"
}
out="$(_ctrl_x task "$(session_for "$slug")" "" 2>&1 <<<y)"; rc=$?
unset -f tmux
assert "W6 ctrl-x: the popup shows the stop text" 'unknown: scratch/n\.txt' "$(cat "$POPUP_OUT")"
tmux has-session -t "=$(session_for "$slug")" 2>/dev/null && echo "ok   - W6 ctrl-x: session left alive" || { echo "FAIL - W6 ctrl-x: session killed"; fail=1; }
[ -d "$(w6_wt "$slug")" ] && echo "ok   - W6 ctrl-x: worktree untouched" || { echo "FAIL - W6 ctrl-x: worktree removed"; fail=1; }
assert "W6 ctrl-x: status still doing" '^doing$' "$(w6_status "$slug")"
# popup unavailable: falls back to display-message
tmux() {
  case "${1:-}" in
    display-popup) return 1 ;;
    display-message) if [ "${2:-}" = -d ]; then printf '%s' "$4" >> "$POPUP_OUT.msg"; return 0; fi; command tmux "$@" ;;
    *) command tmux "$@" ;;
  esac
}
: > "$POPUP_OUT.msg"
_ctrl_x task "$(session_for "$slug")" "" >/dev/null 2>&1 <<<y
unset -f tmux
assert "W6 ctrl-x: falls back to display-message" 'unknown: scratch/n\.txt' "$(cat "$POPUP_OUT.msg")"

# --- Fix 1: the ctrl-x path must stop at a failed step (errexit is off there) --
# A locked worktree makes a single `git worktree remove --force` fail.
slug=w6dossier-locked; w6_new "$slug" dossier
git -C "$SWP" worktree lock "$(w6_wt "$slug")" >/dev/null 2>&1
before="$(cat "$(w6_file "$slug")")"
: > "$POPUP_OUT"
tmux() {
  if [ "${1:-}" = display-popup ]; then
    local last="${*: -1}" pf
    pf="$(printf '%s' "$last" | sed -n 's/^cat \([^;]*\);.*/\1/p')"
    [ -f "$pf" ] && cat "$pf" >> "$POPUP_OUT"
    return 0
  fi
  command tmux "$@"
}
out="$(_ctrl_x task "$(session_for "$slug")" "" 2>&1 <<<y)"; rc=$?
unset -f tmux
[ "$rc" -ne 0 ] && echo "ok   - ctrl-x failed removal: non-zero exit" || { echo "FAIL - ctrl-x failed removal: exit 0: $out"; fail=1; }
[ -d "$(w6_wt "$slug")" ] && echo "ok   - ctrl-x failed removal: worktree still there" || { echo "FAIL - ctrl-x failed removal: worktree gone"; fail=1; }
assert "ctrl-x failed removal: status unchanged" '^doing$' "$(w6_status "$slug")"
[ "$(cat "$(w6_file "$slug")")" = "$before" ] && echo "ok   - ctrl-x failed removal: task file byte-identical" || { echo "FAIL - ctrl-x failed removal: task file changed"; fail=1; }
case "$(cat "$(w6_file "$slug")"; cat "$(w6_dossier "$slug")"/handoffs/* 2>/dev/null)" in *"wb done"*) echo "FAIL - ctrl-x failed removal: a wb done handoff was written"; fail=1 ;; *) echo "ok   - ctrl-x failed removal: no wb done handoff" ;; esac
assert "ctrl-x failed removal: the stop text reached the popup" 'could not remove .*task left as is' "$(cat "$POPUP_OUT")"
git -C "$SWP" worktree unlock "$(w6_wt "$slug")" >/dev/null 2>&1

# (b) the success path prints cmd_done's own output
slug=w6dossier-ctrlxok; w6_new "$slug" dossier
out="$(_ctrl_x_done "$(session_for "$slug")" 2>&1)"; rc=$?
[ "$rc" -eq 0 ] && echo "ok   - ctrl-x success: exit 0" || { echo "FAIL - ctrl-x success: exit $rc: $out"; fail=1; }
assert "ctrl-x success: prints cmd_done's output" 'wb done: .* worktree removed' "$out"
assert "ctrl-x success: task done" '^done$' "$(w6_status "$slug")"

# (c) the popup shows its temp file and removes it itself; ctrl-x leaves it alone
# when the popup ran. The shim runs the popup command string through sh -c.
slug=w6dossier-tmpclean; w6_new "$slug" dossier
mkdir -p "$(w6_wt "$slug")/scratch"; echo x > "$(w6_wt "$slug")/scratch/n.txt"
W6_TMP="$FIXTURE_STATE/w6-tmpdir"; mkdir -p "$W6_TMP"; : > "$W6_TMP/popup-shown"
tmux() {
  if [ "${1:-}" = display-popup ]; then
    local last="${*: -1}"
    ls "$W6_TMP"/wb-done-stop.* >/dev/null 2>&1 && : > "$W6_TMP/popup-saw-file"
    sh -c "$last" < /dev/null > "$W6_TMP/popup-shown" 2>&1
    return 0
  fi
  command tmux "$@"
}
TMPDIR="$W6_TMP" _ctrl_x_done "$(session_for "$slug")" >/dev/null 2>&1
unset -f tmux
[ -e "$W6_TMP/popup-saw-file" ] && echo "ok   - ctrl-x temp file: existed when the popup started" || { echo "FAIL - ctrl-x temp file: not there when the popup started"; fail=1; }
assert "ctrl-x temp file: the popup showed the stop text" 'unknown: scratch/n\.txt' "$(cat "$W6_TMP/popup-shown")"
ls "$W6_TMP"/wb-done-stop.* >/dev/null 2>&1 && { echo "FAIL - ctrl-x temp file: left behind"; fail=1; } || echo "ok   - ctrl-x temp file: removed by the popup command"
# a popup that never runs (the shim ignores it): the file stays, because the popup owns the removal
tmux() { if [ "${1:-}" = display-popup ]; then return 0; fi; command tmux "$@"; }
TMPDIR="$W6_TMP" _ctrl_x_done "$(session_for "$slug")" >/dev/null 2>&1
unset -f tmux
ls "$W6_TMP"/wb-done-stop.* >/dev/null 2>&1 && echo "ok   - ctrl-x temp file: not removed by ctrl-x when the popup ran" || { echo "FAIL - ctrl-x temp file: ctrl-x removed it though the popup ran"; fail=1; }
rm -f "$W6_TMP"/wb-done-stop.*
# display-popup fails: ctrl-x removes the file itself, and shows the message
tmux() { case "${1:-}" in display-popup) return 1 ;; display-message) [ "${2:-}" = -d ] && return 0; command tmux "$@" ;; *) command tmux "$@" ;; esac; }
TMPDIR="$W6_TMP" _ctrl_x_done "$(session_for "$slug")" >/dev/null 2>&1
unset -f tmux
ls "$W6_TMP"/wb-done-stop.* >/dev/null 2>&1 && { echo "FAIL - ctrl-x temp file: left behind after a failed popup"; fail=1; } || echo "ok   - ctrl-x temp file: removed by ctrl-x when the popup failed"
# a TMPDIR with a space and a $: the quoted path still shows and removes the file
W6_TMP2="$FIXTURE_STATE/w6 tmp \$dir"; mkdir -p "$W6_TMP2"
tmux() {
  if [ "${1:-}" = display-popup ]; then
    local last="${*: -1}"
    sh -c "$last" < /dev/null > "$W6_TMP2/popup-shown.txt" 2>&1
    return 0
  fi
  command tmux "$@"
}
TMPDIR="$W6_TMP2" _ctrl_x_done "$(session_for "$slug")" >/dev/null 2>&1
unset -f tmux
assert "ctrl-x odd TMPDIR (space and \$): the popup showed the stop text" 'unknown: scratch/n\.txt' "$(cat "$W6_TMP2/popup-shown.txt")"
ls "$W6_TMP2"/wb-done-stop.* >/dev/null 2>&1 && { echo "FAIL - ctrl-x odd TMPDIR: temp file left behind"; fail=1; } || echo "ok   - ctrl-x odd TMPDIR: temp file removed"

# (d) mktemp fails (TMPDIR missing): the text goes to display-message
tmux() { if [ "${1:-}" = display-message ] && [ "${2:-}" = -d ]; then printf '%s' "$4" >> "$POPUP_OUT.msg"; return 0; fi; command tmux "$@"; }
: > "$POPUP_OUT.msg"
TMPDIR="$FIXTURE_STATE/no-such-tmpdir" _ctrl_x_done "$(session_for "$slug")" >/dev/null 2>&1
unset -f tmux
assert "ctrl-x no temp file: display-message got the stop text" 'unknown: scratch/n\.txt' "$(cat "$POPUP_OUT.msg")"

# --- Fix 4: tmux expands #(cmd) in display-message text; the fallback doubles every # ---
slug=w6dossier-hashfmt; w6_new "$slug" dossier
printf '%s\n' '\#(touch marker)' >> "$SWP/.git/info/exclude"
: > "$(w6_wt "$slug")/#(touch marker)"
tmux() {
  case "${1:-}" in
    display-popup) return 1 ;;
    display-message) if [ "${2:-}" = -d ]; then printf '%s' "$4" >> "$POPUP_OUT.msg"; return 0; fi; command tmux "$@" ;;
    *) command tmux "$@" ;;
  esac
}
: > "$POPUP_OUT.msg"
( cd "$FIXTURE_STATE" && _ctrl_x_done "$(session_for "$slug")" >/dev/null 2>&1 )
unset -f tmux
assert "ctrl-x #( escaping: display-message text carries ##(" '##\(touch marker\)' "$(cat "$POPUP_OUT.msg")"
case "$(cat "$POPUP_OUT.msg")" in *[!#]"#(touch"*|"#(touch"*) echo "FAIL - ctrl-x #( escaping: a single # still precedes ("; fail=1 ;; *) echo "ok   - ctrl-x #( escaping: no unescaped #(" ;; esac
found="$(find "$FIXTURE_STATE" "$FIXTURE_CODE" "$FIXTURE_TASKS" "$PWD" -maxdepth 3 -name marker 2>/dev/null | head -1)"
[ -z "$found" ] && echo "ok   - ctrl-x #( escaping: no marker file created" || { echo "FAIL - ctrl-x #( escaping: marker at $found"; fail=1; }

# --- wb help lists all five flags -------------------------------------------
help_out="$(bash "$WB" help 2>&1)"
for flag in --close --leave-shelved --review --keep --throwaway; do
  assert "W6 help: wb done usage line lists $flag" "wb done \\[.*\\${flag}" "$help_out"
done

[ "$fail" -eq 0 ] && echo "ALL PASS" || echo "FAILURES"
exit "$fail"
