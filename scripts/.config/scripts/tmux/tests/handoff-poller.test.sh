#!/usr/bin/env bash
# Tests for handoff.sh's spawn-path building blocks (U2): the anchor poller
# (handoff_wait_for_pane_pattern), the bootstrap-gap check
# (handoff_bootstrap_gap), the Follow-ups insertion (handoff_append_followup),
# and the permission co-occurrence gate (handoff_permission_prompt_matches).
#
# Deliberately does NOT call the real `wb new --agent` spawn path — that
# creates a real git worktree, a real tmux session, and boots a real `claude`
# process (slow/heavy/side-effecting). Per the plan
# (docs/plans/2026-07-11-001-feat-handoff-v1-plan.md, U2 Verification), that
# full spawn-to-permission-clear sequence is a manual smoke test, not this
# automated suite. Instead: a bare-shell tmux pane stands in for "the
# spawned agent's pane" (send-keys makes it print anchor-like text), and a
# fixture directory stands in for a target repo.
#
# handoff.sh is sourced directly to reach its functions without running its
# routing logic — safe because the actual run is guarded by
# `[ "${BASH_SOURCE[0]}" = "${0}" ]` (handoff.sh, added in U2, mirroring the
# same guard wb.sh already carries at its own end) — false when sourced.
# Run: bash scripts/.config/scripts/tmux/tests/handoff-poller.test.sh
set -uo pipefail

HANDOFF="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/handoff.sh"
SESSION="handoff-poller-test-$$"
FIXTURE="$(mktemp -d -t handoff-poller-fixture.XXXXXX)"

# Extra throwaway tmux sessions/dirs created by the U2 tri-state
# characterization section further down (each fixture session there is
# named after its own repo/slug pair, unlike the single shared $SESSION
# above) — tracked here so cleanup() tears every one of them down, however
# far the script got before failing.
E2E_SESSIONS=()
E2E_STUBDIR=""
CLAUDE_STUB_DIR=""

cleanup() {
  tmux kill-session -t "=$SESSION" 2>/dev/null || true
  local s
  for s in "${E2E_SESSIONS[@]}"; do
    tmux kill-session -t "=$s" 2>/dev/null || true
  done
  rm -rf "$FIXTURE" "$E2E_STUBDIR" "$CLAUDE_STUB_DIR"
}
trap cleanup EXIT

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

assert_eq() { # <desc> <expected-exact> <actual>
  if [ "$3" = "$2" ]; then
    echo "ok   - $1"
  else
    echo "FAIL - $1"
    echo "       expected: $2"
    echo "       got:      $3"
    fail=1
  fi
}

# shellcheck disable=SC1090
source "$HANDOFF"
set +e   # handoff.sh sets -e; this test intentionally captures non-zero exits

BOOT_PATTERN='\? for shortcuts|Try "|[0-9]+% ctx'
PERM_PATTERN='Do you want to proceed\?'

tmux new-session -d -s "$SESSION" 2>/dev/null

# new_test_window <name> — create a fixture window and let its shell settle.
# This machine's default shell is zsh with a startup sequence (prompt theme,
# rc files) that takes a beat to finish rendering in a freshly created
# window; send-keys issued before that settles can be silently swallowed
# rather than merely delayed (observed live while writing this suite — see
# the final report for the full note). Every fixture window waits here
# before any send-keys call targets it.
new_test_window() {
  tmux new-window -t "=$SESSION" -n "$1"
  sleep 2
}

# FILLER — a real `claude` boot screen fills its pane with a welcome banner
# etc. well before an anchor shows, so `tail -n 20` (both production and
# this poller) lands on genuinely recent lines. A bare fixture shell's pane
# starts almost empty, so without padding, `capture-pane`'s FULL pane height
# (this session's windows are ~39 lines tall) piped through `tail -n 20`
# grabs mostly-BLANK trailing rows below the actual content instead of the
# anchor line — a real gap found live while writing this suite (see the
# final report). Every fixture below runs this filler immediately before
# its real payload so the anchor always lands within the tail window,
# matching a filled real pane rather than an artifact of an empty one.
FILLER='for i in $(seq 1 200); do echo pad-line-$i; done; '

# send_payload <window> <payload> — literal-type FILLER + <payload> as one
# shell command line, then Enter as a separate send-keys call (mirrors the
# production injection shape this whole suite is ultimately testing).
send_payload() {
  tmux send-keys -t "=$SESSION:$1" -l "${FILLER}${2}"
  tmux send-keys -t "=$SESSION:$1" Enter
}

# --- happy path: boot-ready anchor -----------------------------------------
new_test_window boot
send_payload boot 'sleep 1 && echo "Try \"how does this work?\""'

handoff_wait_for_pane_pattern "=$SESSION:boot" 5 "$BOOT_PATTERN" >/dev/null
assert_eq "boot anchor: poller returns success before timeout" "0" "$?"

# --- happy path: permission-prompt anchor ----------------------------------
new_test_window perm
send_payload perm 'sleep 1 && echo "Do you want to proceed?"'

handoff_wait_for_pane_pattern "=$SESSION:perm" 5 "$PERM_PATTERN" >/dev/null
assert_eq "permission anchor: poller returns success before timeout" "0" "$?"

# --- regression (dry-run #2): bare "allow" text must not satisfy either ----
new_test_window falsepos-allow
send_payload falsepos-allow 'echo "auto-allows \`git push\` remains enabled"'

handoff_wait_for_pane_pattern "=$SESSION:falsepos-allow" 2 "$BOOT_PATTERN"
assert_eq "dry-run #2 regression: bare 'allow' text does not satisfy boot-ready" "1" "$?"

handoff_wait_for_pane_pattern "=$SESSION:falsepos-allow" 2 "$PERM_PATTERN"
assert_eq "dry-run #2 regression: bare 'allow' text does not satisfy permission-prompt" "1" "$?"

# --- regression (dry-run #3): handoff.sh's own pointer string must not ------
# satisfy the permission-prompt pattern (proves anchor disjointness).
new_test_window falsepos-pointer
send_payload falsepos-pointer 'echo "Read the task file at /some/path.md - it carries the full context and states the first action to take."'

handoff_wait_for_pane_pattern "=$SESSION:falsepos-pointer" 2 "$PERM_PATTERN"
assert_eq "dry-run #3 regression: injected pointer text does not satisfy permission-prompt" "1" "$?"

# --- auto-answer gating (R10): co-occurrence required ----------------------
# UNRELATED_POINTER stands in for handoff.sh's own injected pointer string in
# these two tests — it deliberately shares no text with either fixture pane,
# so filtering it out of the captured text (handoff_permission_prompt_matches'
# own first step) removes nothing and these two tests exercise plain
# co-occurrence, not the self-collision case (that's the dedicated test below).
UNRELATED_POINTER="Read the task file at /unrelated/path.md - it carries the full context and states the first action to take."

new_test_window gating-with
send_payload gating-with 'echo "Do you want to proceed?" && echo "Read ~/code/tasks/dotfiles--feat-foo.md"'
sleep 1
pane_with="$(tmux capture-pane -ep -t "=$SESSION:gating-with" | tail -n 20)"
if handoff_permission_prompt_matches "$pane_with" "$UNRELATED_POINTER"; then
  echo "ok   - R10 gating: prompt co-occurring with tasks/Read text triggers auto-answer condition"
else
  echo "FAIL - R10 gating: prompt co-occurring with tasks/Read text should trigger auto-answer condition"
  fail=1
fi

new_test_window gating-without
send_payload gating-without 'echo "Do you want to proceed?" && echo "1. Yes  2. No, and tell Claude what to do differently"'
sleep 1
pane_without="$(tmux capture-pane -ep -t "=$SESSION:gating-without" | tail -n 20)"
if handoff_permission_prompt_matches "$pane_without" "$UNRELATED_POINTER"; then
  echo "FAIL - R10 gating: prompt WITHOUT tasks/Read text should NOT trigger auto-answer condition"
  fail=1
else
  echo "ok   - R10 gating: prompt without tasks/Read text does not trigger auto-answer condition"
fi

# --- regression: R10 gate must not be self-satisfied by handoff.sh's own ----
# injected pointer text (found independently by 3 reviewers this session).
# Before the fix, handoff_permission_prompt_matches checked the whole
# captured window for "Do you want to proceed?" AND "Read" as two
# independent substrings — since the pointer itself starts with "Read" and
# sits in the same pane the permission poll scans, ANY "Do you want to
# proceed?" dialog (not just the tasks/Read one) would satisfy the gate as
# long as the pointer hadn't scrolled out of the tail-20 window yet, which
# is virtually guaranteed immediately after injection. This constructs
# exactly that: the real pointer text plus a dialog that is NOT the
# tasks/Read one (a generic "allow all edits" style prompt).
new_test_window gating-self-collision
SELF_POINTER="Read the task file at /some/path.md - it carries the full context and states the first action to take."
send_payload gating-self-collision "echo '$SELF_POINTER' && echo 'Do you want to proceed?' && echo '1. Yes  2. Yes, allow all edits during this session  3. No'"
sleep 1
pane_collision="$(tmux capture-pane -ep -t "=$SESSION:gating-self-collision" | tail -n 20)"
if handoff_permission_prompt_matches "$pane_collision" "$SELF_POINTER"; then
  echo "FAIL - R10 self-collision: an unrelated dialog must not auto-answer just because handoff.sh's own pointer text (containing 'Read') is still in the pane"
  fail=1
else
  echo "ok   - R10 self-collision: unrelated dialog does not trigger auto-answer even with the pointer's own 'Read' text present"
fi

# --- R7 regression: no send-keys call embeds the literal string /model ----
# Scoped to send-keys lines only — handoff.sh's own doc comments legitimately
# name "/model" in prose (explaining why it's never sent), which would
# false-positive a whole-file grep.
if grep -F 'send-keys' "$HANDOFF" | grep -qF '/model'; then
  echo "FAIL - R7: a send-keys line in handoff.sh embeds the literal string /model"
  fail=1
else
  echo "ok   - R7: no send-keys call in handoff.sh embeds the literal string /model"
fi

# --- spawn path always passes --agent to wb new -----------------------------
# Dropping --agent would make wb_layout_session (wb.sh) leave the "agent"
# window as an idle shell — nothing would ever type `claude` into it, and
# the boot-ready poll would burn its full timeout waiting on a process
# that was never started.
if grep -qF '"$WB" new --agent "$repo" "$slug"' "$HANDOFF"; then
  echo "ok   - spawn path passes --agent to wb new"
else
  echo "FAIL - spawn path missing --agent flag on the wb new call"
  fail=1
fi

# --- timeout path: no matching text ever appears ----------------------------
new_test_window timeout
SECONDS=0
handoff_wait_for_pane_pattern "=$SESSION:timeout" 3 "$BOOT_PATTERN"
rc=$?
elapsed=$SECONDS
assert_eq "timeout path: poller returns failure" "1" "$rc"
if [ "$elapsed" -ge 3 ] && [ "$elapsed" -le 5 ]; then
  echo "ok   - timeout path: completes at roughly the configured timeout (${elapsed}s, expected ~3s)"
else
  echo "FAIL - timeout path: elapsed ${elapsed}s not within the expected 3-5s window"
  fail=1
fi

# --- bootstrap-gap surfacing (R11): fixture repo dirs -----------------------
mkdir -p "$FIXTURE/repo-neither"
mkdir -p "$FIXTURE/repo-manifest"
touch "$FIXTURE/repo-manifest/.worktree-bootstrap"
mkdir -p "$FIXTURE/repo-envfile"
touch "$FIXTURE/repo-envfile/.env"
mkdir -p "$FIXTURE/repo-envfile-variant"
touch "$FIXTURE/repo-envfile-variant/.env.local"

handoff_bootstrap_gap "$FIXTURE/repo-neither"
assert_eq "bootstrap gap: neither manifest nor .env* -> gap detected" "0" "$?"

handoff_bootstrap_gap "$FIXTURE/repo-manifest"
assert_eq "bootstrap gap: .worktree-bootstrap present -> no gap" "1" "$?"

handoff_bootstrap_gap "$FIXTURE/repo-envfile"
assert_eq "bootstrap gap: root .env present -> no gap" "1" "$?"

handoff_bootstrap_gap "$FIXTURE/repo-envfile-variant"
assert_eq "bootstrap gap: root .env.local (glob match) present -> no gap" "1" "$?"

# --- handoff_append_followup: inserts right under the heading --------------
TASK_FIXTURE="$FIXTURE/task.md"
printf -- '---\nstatus: doing\nrepo: fixture-repo\n---\n# Title\n\n## Plan\n\nsome plan text\n\n## Follow-ups\n\n- pre-existing item\n\n## Decisions\n' > "$TASK_FIXTURE"

handoff_append_followup "$TASK_FIXTURE" "bootstrap gap: fixture-repo has neither manifest nor .env*"

inserted="$(awk '/^## Follow-ups$/ { getline; print; exit }' "$TASK_FIXTURE")"
assert_eq "append_followup: new line lands immediately under the heading" \
  "- bootstrap gap: fixture-repo has neither manifest nor .env*" "$inserted"
assert "append_followup: pre-existing Follow-ups content survives" "pre-existing item" "$(cat "$TASK_FIXTURE")"
assert "append_followup: other sections untouched" "some plan text" "$(cat "$TASK_FIXTURE")"

# heading missing but ## Decisions exists -> insert Follow-ups right before it.
# This is the live TEMPLATE.md shape (Plan/Decisions/Done, no Follow-ups) —
# real pre-existing task files lack the heading too, not just template-fresh
# ones, so this must not be a no-op (an earlier version of this function was).
DECISIONS_ONLY_FIXTURE="$FIXTURE/decisions-only.md"
printf -- '---\nstatus: doing\n---\n# Title\n\n## Plan\n\nsome plan text\n\n## Decisions\n' > "$DECISIONS_ONLY_FIXTURE"
handoff_append_followup "$DECISIONS_ONLY_FIXTURE" "gap noted here"
assert "append_followup: inserts a Follow-ups heading before Decisions when missing" \
  "## Follow-ups" "$(cat "$DECISIONS_ONLY_FIXTURE")"
assert "append_followup: the new line lands under the inserted heading" \
  "gap noted here" "$(cat "$DECISIONS_ONLY_FIXTURE")"
followups_line_no="$(grep -n '^## Follow-ups$' "$DECISIONS_ONLY_FIXTURE" | cut -d: -f1)"
decisions_line_no="$(grep -n '^## Decisions$' "$DECISIONS_ONLY_FIXTURE" | cut -d: -f1)"
if [ -n "$followups_line_no" ] && [ -n "$decisions_line_no" ] && [ "$followups_line_no" -lt "$decisions_line_no" ]; then
  echo "ok   - append_followup: inserted heading lands before Decisions, not after"
else
  echo "FAIL - append_followup: inserted heading should land before Decisions"
  fail=1
fi

# neither heading exists -> append a new Follow-ups section at EOF.
NO_HEADING_FIXTURE="$FIXTURE/no-heading.md"
printf -- '---\nstatus: doing\n---\n# Title\n\n## Plan\n' > "$NO_HEADING_FIXTURE"
handoff_append_followup "$NO_HEADING_FIXTURE" "should still appear"
assert "append_followup: appends a Follow-ups section at EOF when neither heading exists" \
  "## Follow-ups" "$(cat "$NO_HEADING_FIXTURE")"
assert "append_followup: the line appears under the appended heading" \
  "should still appear" "$(cat "$NO_HEADING_FIXTURE")"

# --- injection shape: pointer via one send-keys -l, Enter via a SEPARATE ---
# call — never combined, never an embedded newline. Fixed-string (-F)
# matches against known-exact source lines, not regex, so $ and " need no
# escaping gymnastics.
pointer_line='tmux send-keys -t "$target" -l "$pointer"'
enter_line='tmux send-keys -t "$target" Enter'
if grep -qF -- "$pointer_line" "$HANDOFF" && grep -qF -- "$enter_line" "$HANDOFF"; then
  echo "ok   - injection shape: pointer sent via send-keys -l, Enter via a separate send-keys call"
else
  echo "FAIL - injection shape: expected a separate '$pointer_line' line and '$enter_line' line"
  fail=1
fi

if grep -F 'send-keys' "$HANDOFF" | grep -Eq -- '-l.*Enter|Enter.*-l'; then
  echo "FAIL - injection shape: some send-keys call combines -l and Enter on one line (embedded-newline risk)"
  fail=1
else
  echo "ok   - injection shape: no send-keys call combines -l and Enter on one line"
fi

# --- dropped-first-Enter regression (live smoke test, 2026-07-11): the ------
# Enter sent immediately after the boot-ready anchor first matches can be
# silently dropped while the TUI is still mid-transition off the welcome
# banner — observed live, not in any fixture (a bare-shell pane can't
# reproduce a real TUI's render timing). Fix is a bounded, safe-as-a-no-op
# resend: a second Enter after a short pause. Assert the pointer-injection
# block sends Enter twice with a sleep between, not just once.
enter_count_after_pointer="$(awk '/-l "\$pointer"/{found=1} found && /send-keys -t "\$target" Enter/{c++} END{print c+0}' "$HANDOFF")"
if [ "$enter_count_after_pointer" -ge 2 ]; then
  echo "ok   - dropped-Enter regression: pointer injection resends Enter after a pause, not just once"
else
  echo "FAIL - dropped-Enter regression: expected a second Enter resend after pointer injection (got $enter_count_after_pointer Enter sends)"
  fail=1
fi

# --- R10 auto-answer keystroke: single '2', no trailing Enter --------------
answer_line="tmux send-keys -t \"\$target\" -l '2'"
if grep -qF -- "$answer_line" "$HANDOFF"; then
  echo "ok   - permission answer: sends a single literal '2' keystroke"
else
  echo "FAIL - permission answer: expected a literal '$answer_line' call"
  fail=1
fi

# ============================================================================
# U2 (2026-07-11-001-feat-tasks-dir-concurrency-safety plan): tmux_session_
# agent_state characterization.
#
# handoff.sh's switch-path branch currently has an inline two-stage check
# (exact-match `tmux has-session`, then `pane_current_command == claude` on
# the `:agent` pane) that's being extracted into a shared, tri-state
# (alive/dead/unknown) lib.sh helper. This section pins handoff.sh's exact
# CURRENT stdout/stderr wording for all three underlying states BEFORE that
# extraction happens, so the same assertions re-run unchanged afterwards
# prove the refactor didn't alter any externally-visible behavior.
#
# Real subprocess execution of handoff.sh (not sourcing, unlike the rest of
# this file) — this is the only way to reach the switch-path branch, which
# lives inside the `[ "${BASH_SOURCE[0]}" = "${0}" ]`-guarded block at the
# bottom of handoff.sh and never runs when the file is merely sourced (per
# this file's own header, deliberately). That branch calls tmux_focus
# (lib.sh), which issues a REAL `tmux switch-client` whenever $TMUX is set
# — true in any shell already inside tmux, including the one running this
# suite — and that would hijack this machine's actual attached tmux client
# if allowed through for real (confirmed live: switch-client against a
# throwaway, never-attached fixture session still errors/affects real
# client resolution rather than being a harmless no-op). Same fix
# handoff.test.sh already uses for exactly this reason: a PATH-shadowed
# `tmux` wrapper that intercepts only switch-client/attach (a no-op) and
# forwards every other subcommand straight to the real binary.
# ----------------------------------------------------------------------------
REAL_TMUX_BIN="$(command -v tmux)"
E2E_STUBDIR="$(mktemp -d -t handoff-poller-e2e-stub.XXXXXX)"
cat > "$E2E_STUBDIR/tmux" <<EOF
#!/usr/bin/env bash
case "\$1" in
  switch-client|attach) exit 0 ;;
esac
exec "$REAL_TMUX_BIN" "\$@"
EOF
chmod +x "$E2E_STUBDIR/tmux"

# claude stub — tmux's pane_current_command reports the kernel's `comm` for
# the pane's foreground process, which for a `#!/usr/bin/env bash` script
# reflects the INTERPRETER's basename ("bash"), not the script's own
# filename — confirmed live while writing this suite. A plain copy of the
# real `sleep` binary renamed to `claude` is a genuine executable file
# whose comm really is "claude" once exec'd, satisfying the exact
# `[ "$(tmux list-panes ...)" = "claude" ]` check both the current inline
# code and the new tmux_session_agent_state helper make.
CLAUDE_STUB_DIR="$(mktemp -d -t handoff-poller-claude-stub.XXXXXX)"
cp "$(command -v sleep)" "$CLAUDE_STUB_DIR/claude"
chmod +x "$CLAUDE_STUB_DIR/claude"

E2E_TASKS_DIR="$FIXTURE/e2e-tasks"
mkdir -p "$E2E_TASKS_DIR"
export TASKS_DIR="$E2E_TASKS_DIR"   # keep handoff.sh's task-file I/O off the real store

# seed_e2e_task <repo> <slug> — matching handoff.test.sh's own fixture task
# file shape, just enough frontmatter for wb_task_file/wb_sanitize to agree.
seed_e2e_task() {
  local repo="$1" slug="$2" file
  file="$(wb_task_file "$repo" "$(wb_sanitize "$slug")")"
  mkdir -p "$(dirname "$file")"
  printf -- '---\nstatus: doing\nrepo: %s\nbranch: %s\nworktree: .worktrees/x\ncreated: 2026-07-07\n---\n# Title\n' \
    "$repo" "$slug" > "$file"
}

# run_handoff_e2e <repo> <slug> — real subprocess with the shadowed tmux
# wrapper on PATH; stdout/stderr captured SEPARATELY (unlike this file's
# other assert() calls, which read one combined stream) because which
# stream each switch-path message lands on is itself part of what's being
# characterized (the alive message is a plain echo on stdout; the not-alive
# message is explicitly `>&2`).
run_handoff_e2e() {
  local outfile errfile
  outfile="$(mktemp -t handoff-e2e-out.XXXXXX)"
  errfile="$(mktemp -t handoff-e2e-err.XXXXXX)"
  PATH="$E2E_STUBDIR:$PATH" bash "$HANDOFF" "$@" >"$outfile" 2>"$errfile"
  e2e_rc=$?
  e2e_out="$(cat "$outfile")"
  e2e_err="$(cat "$errfile")"
  rm -f "$outfile" "$errfile"
}

# --- dead: no session at all -> spawn path taken, not switch ---------------
# Mirrors handoff.test.sh's own "no live session" case: repo3 has no real
# ~/code checkout, so `wb new` fails loudly before any further spawn-path
# logic runs — enough to prove the switch branch (and its two messages)
# were never reached.
E2E_REPO_DEAD="e2e-dead-repo-$$"
E2E_SLUG_DEAD="feat-dead"
run_handoff_e2e "$E2E_REPO_DEAD" "$E2E_SLUG_DEAD"
assert_eq "tri-state dead: exits non-zero (falls through to spawn path, no real repo checkout)" "1" "$e2e_rc"
assert "tri-state dead: spawn path attempted (wb new's own error)" "wb new:.*not a git repo" "$e2e_err"
if printf '%s%s' "$e2e_out" "$e2e_err" | grep -q "switched to live session"; then
  echo "FAIL - tri-state dead: neither switch-path message should ever print"
  fail=1
else
  echo "ok   - tri-state dead: neither switch-path message prints"
fi

# --- unknown: session exists, :agent pane is a plain shell (not claude) ----
E2E_REPO_UNKNOWN="e2e-unknown-repo-$$"
E2E_SLUG_UNKNOWN="feat-unknown"
E2E_SESSION_UNKNOWN="${E2E_REPO_UNKNOWN}--$(wb_sanitize "$E2E_SLUG_UNKNOWN")"
seed_e2e_task "$E2E_REPO_UNKNOWN" "$E2E_SLUG_UNKNOWN"
tmux new-session -d -s "$E2E_SESSION_UNKNOWN" 2>/dev/null
E2E_SESSIONS+=("$E2E_SESSION_UNKNOWN")
tmux new-window -t "=$E2E_SESSION_UNKNOWN" -n agent 2>/dev/null   # plain shell, no claude

run_handoff_e2e "$E2E_REPO_UNKNOWN" "$E2E_SLUG_UNKNOWN"
assert_eq "tri-state unknown: exits 0 (still switches)" "0" "$e2e_rc"
assert "tri-state unknown: exact not-alive wording, on stderr" \
  "^handoff: switched to live session $E2E_SESSION_UNKNOWN, but its agent window has no running claude process — " \
  "$e2e_err"
if printf '%s' "$e2e_out" | grep -q "switched to live session"; then
  echo "FAIL - tri-state unknown: the alive-branch message must not appear on stdout"
  fail=1
else
  echo "ok   - tri-state unknown: alive-branch message absent from stdout"
fi

# --- alive: session exists, :agent pane IS running claude ------------------
E2E_REPO_ALIVE="e2e-alive-repo-$$"
E2E_SLUG_ALIVE="feat-alive"
E2E_SESSION_ALIVE="${E2E_REPO_ALIVE}--$(wb_sanitize "$E2E_SLUG_ALIVE")"
seed_e2e_task "$E2E_REPO_ALIVE" "$E2E_SLUG_ALIVE"
tmux new-session -d -s "$E2E_SESSION_ALIVE" 2>/dev/null
E2E_SESSIONS+=("$E2E_SESSION_ALIVE")
tmux new-window -t "=$E2E_SESSION_ALIVE" -n agent 2>/dev/null
sleep 2   # let the fresh window's shell settle before send-keys (see new_test_window above)
tmux send-keys -t "=$E2E_SESSION_ALIVE:agent" "PATH=\"$CLAUDE_STUB_DIR:\$PATH\" claude 300" Enter
sleep 2   # give tmux a beat to report the updated pane_current_command

run_handoff_e2e "$E2E_REPO_ALIVE" "$E2E_SLUG_ALIVE"
assert_eq "tri-state alive: exits 0" "0" "$e2e_rc"
assert "tri-state alive: exact alive wording, on stdout" \
  "^handoff: switched to live session $E2E_SESSION_ALIVE — " "$e2e_out"
if printf '%s' "$e2e_err" | grep -q "no running claude process"; then
  echo "FAIL - tri-state alive: the not-alive-branch message must not appear on stderr"
  fail=1
else
  echo "ok   - tri-state alive: not-alive-branch message absent from stderr"
fi

# ============================================================================
# tmux_session_agent_state (lib.sh) — direct tri-state coverage. This
# function is the target of the U2 extraction above, so (unlike that
# section) these assertions only make sense once it exists — the
# characterization section above is what proves handoff.sh's own visible
# behavior didn't change across the extraction that introduced it. Reuses
# CLAUDE_STUB_DIR from that section.
# ----------------------------------------------------------------------------
TSAS_DEAD_SESSION="handoff-poller-tsas-dead-$$"
tmux kill-session -t "=$TSAS_DEAD_SESSION" 2>/dev/null || true
assert_eq "tmux_session_agent_state: no session at all -> dead" \
  "dead" "$(tmux_session_agent_state "$TSAS_DEAD_SESSION")"

TSAS_UNKNOWN_SESSION="handoff-poller-tsas-unknown-$$"
tmux new-session -d -s "$TSAS_UNKNOWN_SESSION" 2>/dev/null
tmux new-window -t "=$TSAS_UNKNOWN_SESSION" -n agent 2>/dev/null   # plain shell, no claude
assert_eq "tmux_session_agent_state: session exists, :agent pane not claude -> unknown" \
  "unknown" "$(tmux_session_agent_state "$TSAS_UNKNOWN_SESSION")"
tmux kill-session -t "=$TSAS_UNKNOWN_SESSION" 2>/dev/null || true

TSAS_NOWINDOW_SESSION="handoff-poller-tsas-nowindow-$$"
tmux new-session -d -s "$TSAS_NOWINDOW_SESSION" 2>/dev/null   # no :agent window at all
assert_eq "tmux_session_agent_state: session exists, no :agent window at all -> unknown" \
  "unknown" "$(tmux_session_agent_state "$TSAS_NOWINDOW_SESSION")"
tmux kill-session -t "=$TSAS_NOWINDOW_SESSION" 2>/dev/null || true

TSAS_ALIVE_SESSION="handoff-poller-tsas-alive-$$"
tmux new-session -d -s "$TSAS_ALIVE_SESSION" 2>/dev/null
tmux new-window -t "=$TSAS_ALIVE_SESSION" -n agent 2>/dev/null
sleep 2   # let the fresh window's shell settle before send-keys (see new_test_window above)
tmux send-keys -t "=$TSAS_ALIVE_SESSION:agent" "PATH=\"$CLAUDE_STUB_DIR:\$PATH\" claude 300" Enter
sleep 2   # give tmux a beat to report the updated pane_current_command
assert_eq "tmux_session_agent_state: :agent pane running claude -> alive" \
  "alive" "$(tmux_session_agent_state "$TSAS_ALIVE_SESSION")"
tmux kill-session -t "=$TSAS_ALIVE_SESSION" 2>/dev/null || true

[ "$fail" -eq 0 ] && echo "ALL PASS" || echo "FAILURES"
exit "$fail"
