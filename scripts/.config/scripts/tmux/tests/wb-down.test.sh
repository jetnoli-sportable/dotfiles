#!/usr/bin/env bash
# Tests for `wb down` and `wb pr-open` (U3) — plain-bash assertions against
# a fixture store, a fixture Claude transcript root, and real (throwaway)
# tmux sessions, same convention as wb-pause.test.sh. Sources wb.sh (safe:
# see the BASH_SOURCE guard at the bottom of wb.sh) to call cmd_down /
# cmd_pr_open directly against fixture state.
# Run: bash scripts/.config/scripts/tmux/tests/wb-down.test.sh
set -uo pipefail

WB="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/wb.sh"
FIXTURE="$(mktemp -d -t wb-down-fixture.XXXXXX)"
SESSION="wb-down-test-$$"
trap 'rm -rf "$FIXTURE"; tmux kill-session -t "=$SESSION" 2>/dev/null || true' EXIT

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

# shellcheck disable=SC1090
source "$WB"
set +e   # wb.sh sets -e; this test intentionally captures non-zero exits
TASKS_DIR="$FIXTURE"
CODE_DIR="$FIXTURE/code"
CLAUDE_PROJECTS_DIR="$FIXTURE/projects"

mk_task() { # <file> <status> <repo> <branch>
  local f="$FIXTURE/$1"
  printf -- '---\nstatus: %s\nrepo: %s\nbranch: %s\nworktree: .worktrees/%s\ntags: []\ncreated: 2026-07-07\nclosed:\n---\n# Title\n' \
    "$2" "$3" "$4" "$4" > "$f"
}

mk_transcript() { # <worktree_abs> <id> <touch-date>
  local dir; dir="$(CLAUDE_PROJECTS_DIR="$CLAUDE_PROJECTS_DIR" wb_transcript_dir "$1")"
  mkdir -p "$dir"
  printf '{}' > "$dir/$2.jsonl"
  touch -d "$3" "$dir/$2.jsonl"
}

# --- happy path: two transcripts, agent pane carries the newer one ----------
mk_task 'proj--feat-alpha.md' doing proj feat/alpha
WT1="$CODE_DIR/proj/.worktrees/feat/alpha"
mkdir -p "$WT1"
mk_transcript "$WT1" older-id 2026-09-01T00:00:00
mk_transcript "$WT1" newer-id 2026-09-05T00:00:00

tmux new-session -d -s "$SESSION" 2>/dev/null
tmux set-option -t "=$SESSION:" @wb_repo proj >/dev/null
tmux set-option -t "=$SESSION:" @wb_slug feat/alpha >/dev/null
tmux rename-window -t "=$SESSION:1" agent >/dev/null
tmux set-option -p -t "=$SESSION:agent" @claude_session_id newer-id >/dev/null

wb_branch_has_open_pr() { return 1; }   # stub: no open PR for this scenario

out="$(cmd_down "$SESSION" 2>&1)"; rc=$?
assert "cmd_down exits 0" '^' "$rc-ok"; [ "$rc" -eq 0 ] || { echo "FAIL - exit $rc: $out"; fail=1; }
assert "confirmation message" 'set aside' "$out"

sessions_field="$(wb_get_frontmatter "$FIXTURE/proj--feat-alpha.md" claude_sessions)"
assert "claude_sessions: holds both ids" 'older-id' "$sessions_field"
assert "claude_sessions: holds both ids (2)" 'newer-id' "$sessions_field"
assert "claude_sessions: the live agent pane's id is marked primary" 'newer-id@[^,]*@primary' "$sessions_field"
if printf '%s' "$sessions_field" | grep -q 'older-id@[^,]*@primary'; then
  echo "FAIL - claude_sessions: the OLDER id must not be marked primary"; fail=1
else
  echo "ok   - claude_sessions: only the agent pane's id is marked primary"
fi

status_val="$(wb_get_frontmatter "$FIXTURE/proj--feat-alpha.md" status)"
assert "status unchanged (no open PR)" '^doing$' "$status_val"

if tmux has-session -t "=$SESSION" 2>/dev/null; then
  echo "FAIL - cmd_down left the session alive"; fail=1
else
  echo "ok   - cmd_down killed the session"
fi

if [ -d "$WT1" ]; then
  echo "ok   - worktree directory untouched by wb down"
else
  echo "FAIL - worktree directory was removed by wb down (it must never be)"; fail=1
fi

# --- probe stubbed to open PR -> status: review -----------------------------
mk_task 'proj--feat-review.md' doing proj feat/review
WT2="$CODE_DIR/proj/.worktrees/feat/review"
mkdir -p "$WT2"
mk_transcript "$WT2" review-id 2026-09-06T00:00:00
tmux new-session -d -s "${SESSION}-review" 2>/dev/null
tmux set-option -t "=${SESSION}-review:" @wb_repo proj >/dev/null
tmux set-option -t "=${SESSION}-review:" @wb_slug feat/review >/dev/null

wb_branch_has_open_pr() { return 0; }   # stub: open PR
# R19: a page outlives its session, so wb down leaves the /decide marker.
export XDG_STATE_HOME="$FIXTURE/state"
mkdir -p "$XDG_STATE_HOME/wb/needs-you"
printf 'page https://example.test/artifact/x r1\n' > "$XDG_STATE_HOME/wb/needs-you/proj--feat-review"
out="$(cmd_down "${SESSION}-review" 2>&1)"; rc=$?
assert "cmd_down leaves the /decide needs-you marker in place" '^page https://example.test/artifact/x r1$' "$(cat "$XDG_STATE_HOME/wb/needs-you/proj--feat-review" 2>&1)"
assert "cmd_down (open PR) exits 0" '^' "$rc-ok"; [ "$rc" -eq 0 ] || { echo "FAIL - exit $rc: $out"; fail=1; }
status_val="$(wb_get_frontmatter "$FIXTURE/proj--feat-review.md" status)"
assert "status flips to review when the branch has an open PR" '^review$' "$status_val"

# --- probe stubbed to fail -> status unchanged, exit 0, one stderr line -----
mk_task 'proj--feat-unknown.md' doing proj feat/unknown
WT3="$CODE_DIR/proj/.worktrees/feat/unknown"
mkdir -p "$WT3"
tmux new-session -d -s "${SESSION}-unknown" 2>/dev/null
tmux set-option -t "=${SESSION}-unknown:" @wb_repo proj >/dev/null
tmux set-option -t "=${SESSION}-unknown:" @wb_slug feat/unknown >/dev/null

wb_branch_has_open_pr() { echo "stub: could not check PR status" >&2; return 1; }
out="$(cmd_down "${SESSION}-unknown" 2>&1)"; rc=$?
assert "cmd_down (probe failure) exits 0" '^' "$rc-ok"; [ "$rc" -eq 0 ] || { echo "FAIL - exit $rc: $out"; fail=1; }
status_val="$(wb_get_frontmatter "$FIXTURE/proj--feat-unknown.md" status)"
assert "status unchanged when the PR probe fails" '^doing$' "$status_val"
assert "probe failure line reaches the user" 'could not check PR status' "$out"
handoffs_count="$(grep -c '^### .* — wb down (auto)$' "$FIXTURE/proj--feat-unknown.md")"
if [ "$handoffs_count" -eq 1 ]; then
  echo "ok   - exactly one wb down Handoffs entry even when the probe fails"
else
  echo "FAIL - expected exactly 1 wb down Handoffs entry, got $handoffs_count"; fail=1
fi

# --- --keep-session: everything written, session survives (picker's _down --
# self-target wrapper uses this; see wb-picker-rows.test.sh for the source-
# text proof that _down actually passes it on a self-target) ----------------
wb_branch_has_open_pr() { return 1; }
tmux new-session -d -s "${SESSION}-keep" 2>/dev/null
tmux set-option -t "=${SESSION}-keep:" @wb_repo proj >/dev/null
tmux set-option -t "=${SESSION}-keep:" @wb_slug feat/unknown >/dev/null
out="$(cmd_down --keep-session "${SESSION}-keep" 2>&1)"; rc=$?
assert "--keep-session exits 0" '^' "$rc-ok"; [ "$rc" -eq 0 ] || { echo "FAIL - exit $rc: $out"; fail=1; }
if tmux has-session -t "=${SESSION}-keep" 2>/dev/null; then
  echo "ok   - --keep-session leaves the session alive"
else
  echo "FAIL - --keep-session must not kill the session"; fail=1
fi
assert "--keep-session: handoff line says the session stays open" 'Worktree kept, session left open \(`wb down --keep-session`\)\.$' "$(cat "$FIXTURE/proj--feat-unknown.md")"
tmux kill-session -t "=${SESSION}-keep" 2>/dev/null || true

# --- error path: not a wb task session, nothing written ---------------------
tmux new-session -d -s "${SESSION}-bare" 2>/dev/null
before_hash="$(md5sum "$FIXTURE/proj--feat-alpha.md" | cut -d' ' -f1)"
out="$(cmd_down "${SESSION}-bare" 2>&1)"; rc=$?
assert "bare session: non-zero exit" '^' "$rc-fail"; [ "$rc" -ne 0 ] || { echo "FAIL - exit $rc"; fail=1; }
assert "bare session: clear error" 'not a wb task session' "$out"
after_hash="$(md5sum "$FIXTURE/proj--feat-alpha.md" | cut -d' ' -f1)"
if [ "$before_hash" = "$after_hash" ]; then
  echo "ok   - bare session: nothing written to an unrelated task file"
else
  echo "FAIL - bare session: an unrelated task file was modified"; fail=1
fi
tmux kill-session -t "=${SESSION}-bare" 2>/dev/null || true

# --- idempotence: down twice -> second run reports no session --------------
snapshot_after_first="$(wb_get_frontmatter "$FIXTURE/proj--feat-alpha.md" claude_sessions)"
out="$(cmd_down "$SESSION" 2>&1)"; rc=$?
assert "second down: non-zero exit (session already gone)" '^' "$rc-fail"; [ "$rc" -ne 0 ] || { echo "FAIL - exit $rc"; fail=1; }
snapshot_after_second="$(wb_get_frontmatter "$FIXTURE/proj--feat-alpha.md" claude_sessions)"
if [ "$snapshot_after_first" = "$snapshot_after_second" ]; then
  echo "ok   - idempotence: claude_sessions: unchanged by a second (failing) down"
else
  echo "FAIL - idempotence: claude_sessions: changed by a second down"; fail=1
fi

# --- wb pr-open: exit codes for stubbed open / none / failure --------------
mk_task 'proj--feat-pr.md' doing proj feat/pr
tmux new-session -d -s "${SESSION}-pr" 2>/dev/null
tmux set-option -t "=${SESSION}-pr:" @wb_repo proj >/dev/null
tmux set-option -t "=${SESSION}-pr:" @wb_slug feat/pr >/dev/null

wb_branch_has_open_pr() { return 0; }
cmd_pr_open "${SESSION}-pr" >/dev/null 2>&1; rc=$?
assert "wb pr-open: open PR -> exit 0" '^0$' "$rc"

wb_branch_has_open_pr() { return 1; }
cmd_pr_open "${SESSION}-pr" >/dev/null 2>&1; rc=$?
assert "wb pr-open: no PR -> exit 1" '^1$' "$rc"

wb_branch_has_open_pr() { echo "stub: gh unavailable" >&2; return 1; }
out="$(cmd_pr_open "${SESSION}-pr" 2>&1)"; rc=$?
assert "wb pr-open: probe failure -> exit 1" '^1$' "$rc"
assert "wb pr-open: probe failure surfaces the diagnostic" 'gh unavailable' "$out"
tmux kill-session -t "=${SESSION}-pr" 2>/dev/null || true

# --- pinned error text (byte-exact): every verb that resolves a session via
# the shared helper must keep its own "wb <verb>:" prefix on all three errors.
assert_eq() { # <desc> <expected> <actual>
  if [ "$2" = "$3" ]; then
    echo "ok   - $1"
  else
    echo "FAIL - $1"
    echo "       expected: $2"
    echo "       got:      $3"
    fail=1
  fi
}
# down
out="$(unset TMUX; cmd_down 2>&1)"
assert_eq "down: no session arg + no TMUX -> exact error" \
  "wb down: run inside the target session, or pass a session name" "$out"
tmux new-session -d -s "${SESSION}-pinbare" 2>/dev/null
out="$(cmd_down "${SESSION}-pinbare" 2>&1)"
assert_eq "down: bare session -> exact error" \
  "wb down: ${SESSION}-pinbare has no @wb_repo/@wb_slug — not a wb task session" "$out"
tmux kill-session -t "=${SESSION}-pinbare" 2>/dev/null || true
tmux new-session -d -s "${SESSION}-pinghost" 2>/dev/null
tmux set-option -t "=${SESSION}-pinghost:" @wb_repo proj >/dev/null
tmux set-option -t "=${SESSION}-pinghost:" @wb_slug feat/pin-nonexistent >/dev/null
out="$(cmd_down "${SESSION}-pinghost" 2>&1)"
assert_eq "down: missing task file -> exact error" \
  "wb down: no task file for ${SESSION}-pinghost ($FIXTURE/proj--feat-pin-nonexistent.md)" "$out"
tmux kill-session -t "=${SESSION}-pinghost" 2>/dev/null || true

# pr-open
out="$(unset TMUX; cmd_pr_open 2>&1)"
assert_eq "pr-open: no session arg + no TMUX -> exact error" \
  "wb pr-open: run inside the target session, or pass a session name" "$out"
tmux new-session -d -s "${SESSION}-pinbare" 2>/dev/null
out="$(cmd_pr_open "${SESSION}-pinbare" 2>&1)"
assert_eq "pr-open: bare session -> exact error" \
  "wb pr-open: ${SESSION}-pinbare has no @wb_repo/@wb_slug — not a wb task session" "$out"
tmux kill-session -t "=${SESSION}-pinbare" 2>/dev/null || true
tmux new-session -d -s "${SESSION}-pinghost" 2>/dev/null
tmux set-option -t "=${SESSION}-pinghost:" @wb_repo proj >/dev/null
tmux set-option -t "=${SESSION}-pinghost:" @wb_slug feat/pin-nonexistent >/dev/null
out="$(cmd_pr_open "${SESSION}-pinghost" 2>&1)"
assert_eq "pr-open: missing task file -> exact error" \
  "wb pr-open: no task file for ${SESSION}-pinghost ($FIXTURE/proj--feat-pin-nonexistent.md)" "$out"
tmux kill-session -t "=${SESSION}-pinghost" 2>/dev/null || true

# --- U9: unreviewed decision drafts on the shelf ----------------------------
# The count comes from wb-capture.sh, pointed at a fixture state dir. Terminal
# cases run a driver under `script` (a pty) so [ -t 0 ] is true.
export XDG_STATE_HOME="$FIXTURE/state"
SHELF="$XDG_STATE_HOME/wb/capture/shelved"
mk_shelf() { # <stem> <n>
  mkdir -p "$SHELF/$1"; local i
  for i in $(seq "$2"); do echo draft >"$SHELF/$1/2026110${i}T000000-sid.md"; done
}
mk_u9_session() { # <suffix> <slug>  (task file proj--<slug with / -> ->.md)
  mk_task "proj--${2//\//-}.md" doing proj "$2"
  mkdir -p "$CODE_DIR/proj/.worktrees/$2"
  tmux new-session -d -s "${SESSION}-$1" 2>/dev/null
  tmux set-option -t "=${SESSION}-$1:" @wb_repo proj >/dev/null
  tmux set-option -t "=${SESSION}-$1:" @wb_slug "$2" >/dev/null
}
alive() { tmux has-session -t "=${SESSION}-$1" 2>/dev/null && echo alive || echo gone; }
handoffs() { /usr/bin/grep -c '^### .* — wb ' "$FIXTURE/$1.md"; }
DRIVER="$FIXTURE/u9-driver.sh"
cat >"$DRIVER" <<EOF
#!/usr/bin/env bash
source "$WB"; set +e
TASKS_DIR="$FIXTURE"; CODE_DIR="$FIXTURE/code"; CLAUDE_PROJECTS_DIR="$FIXTURE/projects"
wb_branch_has_open_pr() { return 1; }
verb="\$1"; shift
case "\$verb" in
  down)  cmd_down "\$@" ;;
  pause) cmd_pause "\$@" ;;
esac
EOF
wb_branch_has_open_pr() { return 1; }

# no terminal: prints the line, does not wait, closes as usual
mk_u9_session d1 feat/u9-a; mk_shelf proj--feat-u9-a 2
out="$(cmd_down "${SESSION}-d1" </dev/null 2>&1)"; rc=$?
assert "u9 no terminal: line names 2 drafts" '2 shelved decision draft' "$out"
assert "u9 no terminal: line names the list command" 'wb-capture\.sh shelved --task proj--feat-u9-a' "$out"
assert_eq "u9 no terminal: no prompt text" "0" "$(printf '%s' "$out" | /usr/bin/grep -c 'press any key')"
assert_eq "u9 no terminal: session closed, exit 0" "gone 0" "$(alive d1) $rc"

# terminal + key: prompt shown, then the close completes
mk_u9_session d2 feat/u9-b; mk_shelf proj--feat-u9-b 2
out="$(printf 'x' | script -qec "bash $DRIVER down ${SESSION}-d2" /dev/null 2>&1)"
assert "u9 terminal+key: prompt shown" 'press any key to close, Ctrl-C to keep the session' "$out"
assert_eq "u9 terminal+key: session closed" "gone" "$(alive d2)"
assert_eq "u9 terminal+key: one Handoffs entry" "1" "$(handoffs proj--feat-u9-b)"
# the prompt precedes the Handoffs write: hold it open and look mid-wait
mk_u9_session d3 feat/u9-c; mk_shelf proj--feat-u9-c 2
( sleep 3 | script -qec "bash $DRIVER down ${SESSION}-d3" /dev/null >"$FIXTURE/u9-d3.out" 2>&1 ) &
sleep 1.5
assert_eq "u9 prompt waiting: no Handoffs entry yet, session alive" "0 alive" "$(handoffs proj--feat-u9-c) $(alive d3)"
wait

# terminal + SIGINT at the prompt: nothing written, status unchanged, session alive
mk_u9_session d4 feat/u9-d; mk_shelf proj--feat-u9-d 2
before="$(md5sum "$FIXTURE/proj--feat-u9-d.md" | cut -d' ' -f1)"
( sleep 5 | script -qec "bash $DRIVER down ${SESSION}-d4" /dev/null >"$FIXTURE/u9-d4.out" 2>&1 ) &
sleep 1.5
pkill -INT -f "u9-driver.sh down ${SESSION}-d4" 2>/dev/null
wait
assert "u9 SIGINT: prompt had been shown" 'press any key' "$(cat "$FIXTURE/u9-d4.out")"
assert_eq "u9 SIGINT: session alive" "alive" "$(alive d4)"
assert_eq "u9 SIGINT: task file untouched (no Handoffs, no status change)" "$before" "$(md5sum "$FIXTURE/proj--feat-u9-d.md" | cut -d' ' -f1)"
tmux kill-session -t "=${SESSION}-d4" 2>/dev/null || true

# no drafts: no line
mk_u9_session d5 feat/u9-e
out="$(cmd_down "${SESSION}-d5" </dev/null 2>&1)"
assert_eq "u9 no drafts: no warning line" "0" "$(printf '%s' "$out" | /usr/bin/grep -c 'shelved decision draft')"

# capture script missing: no line, no error, session closes
mk_u9_session d6 feat/u9-f; mk_shelf proj--feat-u9-f 2
REAL_SD="$SCRIPT_DIR"; SCRIPT_DIR="$FIXTURE/no-such-dir"
out="$(cmd_down "${SESSION}-d6" </dev/null 2>&1)"; rc=$?
SCRIPT_DIR="$REAL_SD"
assert_eq "u9 capture script missing: no line, closed, exit 0" "0 gone 0" "$(printf '%s' "$out" | /usr/bin/grep -c 'shelved decision draft') $(alive d6) $rc"

# kill switch set with 2 drafts: line still printed
mk_u9_session d7 feat/u9-g; mk_shelf proj--feat-u9-g 2
mkdir -p "$XDG_STATE_HOME/wb"; : >"$XDG_STATE_HOME/wb/disable-capture"
out="$(cmd_down "${SESSION}-d7" </dev/null 2>&1)"
rm -f "$XDG_STATE_HOME/wb/disable-capture"
assert "u9 kill switch: line still printed" '2 shelved decision draft' "$out"

# --keep-session with drafts: same warning, session left open
mk_u9_session d8 feat/u9-h; mk_shelf proj--feat-u9-h 2
out="$(cmd_down --keep-session "${SESSION}-d8" </dev/null 2>&1)"; rc=$?
assert "u9 --keep-session: warning printed" '2 shelved decision draft' "$out"
assert_eq "u9 --keep-session: session alive, exit 0" "alive 0" "$(alive d8) $rc"
tmux kill-session -t "=${SESSION}-d8" 2>/dev/null || true

# wb pause with drafts: warned once (cmd_pause warns, cmd_down does not repeat), paused, closed
mk_u9_session d9 feat/u9-i; mk_shelf proj--feat-u9-i 2
out="$(cmd_pause "${SESSION}-d9" </dev/null 2>&1)"
assert_eq "u9 wb pause: warned once, paused, closed" "1 paused gone" "$(printf '%s' "$out" | /usr/bin/grep -c 'shelved decision draft') $(wb_get_frontmatter "$FIXTURE/proj--feat-u9-i.md" status) $(alive d9)"
# wb pause + SIGINT at the prompt: status not written, session alive
mk_u9_session d10 feat/u9-j; mk_shelf proj--feat-u9-j 1
before="$(md5sum "$FIXTURE/proj--feat-u9-j.md" | cut -d' ' -f1)"
( sleep 5 | script -qec "bash $DRIVER pause ${SESSION}-d10" /dev/null >"$FIXTURE/u9-d10.out" 2>&1 ) &
sleep 1.5
pkill -INT -f "u9-driver.sh pause ${SESSION}-d10" 2>/dev/null
wait
assert_eq "u9 wb pause SIGINT: task untouched, session alive" "same alive" "$([ "$before" = "$(md5sum "$FIXTURE/proj--feat-u9-j.md" | cut -d' ' -f1)" ] && echo same || echo changed) $(alive d10)"
tmux kill-session -t "=${SESSION}-d10" 2>/dev/null || true

[ "$fail" -eq 0 ] && echo "ALL PASS" || echo "FAILURES"
exit "$fail"
