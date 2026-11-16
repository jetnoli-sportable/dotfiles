#!/usr/bin/env bash
# shellcheck disable=SC2329,SC2030,SC2031,SC2016 # test scaffolding: traps, subshell env, literal fixtures
# Tests for U3 of the wb continue plan: wb-continue-hook.sh, the Stop and
# SessionStart hooks, the helper the Stop hook starts, and shadow mode.
# Real tmux on ONE fixed private -L socket with -f /dev/null behind a PATH shim
# (never the default socket); a stub `claude` records its argv and, when told,
# runs the real `wb continue pickup`, so the whole path runs without a real
# Claude. Payloads are the committed fixtures with their placeholders filled in.
# Run: bash scripts/.config/scripts/tmux/tests/wb-continue-hook.test.sh
# HOOK overrides the script under test.
set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WB="$SELF_DIR/wb.sh"
HOOK="${HOOK:-$SELF_DIR/wb-continue-hook.sh}"
PAYLOADS="$SELF_DIR/tests/fixtures/hook-payloads"
FIX="$(mktemp -d -t wb-continue-hook.XXXXXX)"
SOCK="wb-continue-hook-test-sock"
REAL_TMUX="$(command -v tmux)"
REAL_BASH="$(command -v bash)"

# Isolation FIRST (a past incident wiped ~/code when this was skipped).
export HOME="$FIX/home" XDG_STATE_HOME="$FIX/state" CODE_DIR="$FIX/code" TASKS_DIR="$FIX/tasks"
export WB_CONTINUE_SESSIONS_DIR="$FIX/sessions" LANG=C.UTF-8 LC_ALL=C.UTF-8
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
mkdir -p "$HOME" "$XDG_STATE_HOME/wb" "$CODE_DIR" "$TASKS_DIR" "$FIX/bin" "$WB_CONTINUE_SESSIONS_DIR"
unset TMUX TMUX_PANE CLAUDE_CODE_SESSION_ID CLAUDE_CODE_ENTRYPOINT CLAUDE_CODE_SESSION_ATTENDED WBC_TRANSCRIPT WB_CONTINUE_TEST

TMUX_LOG="$FIX/tmux.log"
: >"$TMUX_LOG"
# The shim logs every call. FAKE_CLIENTS (a file) makes list-clients report a
# client active just now (or "old"); CAPTURE_PENDING_AFTER (a file holding N)
# makes capture-pane from its Nth call on show text on the input line.
cat >"$FIX/bin/tmux" <<EOF2
#!/usr/bin/env bash
echo "\$*" >> "$TMUX_LOG"
if [ "\$1" = list-clients ] && [ -f "$FIX/fake-clients" ]; then
  if [ "\$(cat "$FIX/fake-clients")" = old ]; then echo \$(( \$(date +%s) - 120 )); else date +%s; fi
  exit 0
fi
if [ "\$1" = capture-pane ] && [ -f "$FIX/capture-pending-after" ]; then
  n=\$(( \$(cat "$FIX/capture-count" 2>/dev/null || echo 0) + 1 )); echo \$n > "$FIX/capture-count"
  if [ \$n -ge "\$(cat "$FIX/capture-pending-after")" ]; then printf '\xe2\x9d\xaf\xc2\xa0typed text\n'; exit 0; fi
fi
exec "$REAL_TMUX" -u -L "$SOCK" -f /dev/null "\$@"
EOF2
chmod +x "$FIX/bin/tmux"

# The old Claude: registers itself the way Claude does, shows an input-line
# screen, and sits there (exec keeps the pid the registry file names).
cat >"$FIX/bin/oldclaude" <<'EOF2'
#!/usr/bin/env bash
printf '{"sessionId":"%s","pid":%s}\n' "$1" "$$" > "$WB_CONTINUE_SESSIONS_DIR/$$.json"
[ -z "${2:-}" ] || printf "$2"
exec sleep 600
EOF2
# The fresh Claude: records argv; mode `exit` quits at once, mode `pickup`
# runs the real pick-up with the session id it was given, then sits.
cat >"$FIX/bin/claude" <<EOF2
#!/usr/bin/env bash
n=\$(( \$(cat "$FIX/claude-count" 2>/dev/null || echo 0) + 1 )); echo \$n > "$FIX/claude-count"
printf '%s\n' "\$@" > "$FIX/claude-argv-\$n"
sid=""; prev=""; last=""
for a in "\$@"; do [ "\$prev" = --session-id ] && sid="\$a"; prev="\$a"; last="\$a"; done
case "\$(cat "$FIX/claude-mode" 2>/dev/null)" in
  exit) exit 0 ;;
  pickup)
    CLAUDE_CODE_SESSION_ID="\$sid" bash "$WB" continue pickup "\${last#/wb-resume --continue }" > "$FIX/claude-pickup-\$n.out" 2>&1
    printf '{"sessionId":"%s","pid":%s}\n' "\$sid" "\$\$" > "\$WB_CONTINUE_SESSIONS_DIR/\$\$.json"
    exec sleep 600 ;;
esac
EOF2
chmod +x "$FIX/bin/oldclaude" "$FIX/bin/claude"
PATH="$FIX/bin:$PATH"
export PATH
echo exit >"$FIX/claude-mode"

cleanup() {
  "$REAL_TMUX" -L "$SOCK" kill-server 2>/dev/null || true
  rm -rf "${FIX:?}"
}
trap cleanup EXIT

fail=0
assert() { # <desc> <regex> <actual>
  if printf '%s' "$3" | /usr/bin/grep -qE -- "$2"; then
    echo "ok   - $1"
  else
    echo "FAIL - $1"
    echo "       expected match: $2"
    echo "       got: $(printf '%s' "$3" | head -8)"
    fail=1
  fi
}
refute() { # <desc> <regex that must NOT match> <actual>
  if printf '%s' "$3" | /usr/bin/grep -qE -- "$2"; then
    echo "FAIL - $1"
    echo "       unexpected match: $2"
    echo "       got: $(printf '%s' "$3" | head -8)"
    fail=1
  else echo "ok   - $1"; fi
}
assert_eq() { # <desc> <expected> <actual>
  if [ "$2" = "$3" ]; then echo "ok   - $1"; else
    echo "FAIL - $1"
    echo "       expected: $2"
    echo "       got:      $3"
    fail=1
  fi
}

# shellcheck disable=SC1090
source "$WB"
# shellcheck disable=SC1091
source "$SELF_DIR/wb-continue.sh"
set +e +u

tm() { "$FIX/bin/tmux" "$@"; }
# Tunables for the helper live in the tmux server's environment.
tm new-session -d -s keepalive 'sleep 3600'
tm set-environment -g WB_CONTINUE_SETTLE_MS 200
tm set-environment -g WB_CONTINUE_SETTLE_MAX_MS 1500
tm set-environment -g WB_CONTINUE_PROMPT_TIMEOUT 8
tm set-environment -g WB_CONTINUE_PICKUP_TIMEOUT 3
tm set-environment -g WB_CONTINUE_MAX_AGE 1800

# --- fixtures -----------------------------------------------------------------
WT="$CODE_DIR/proj/.worktrees/x"
mkdir -p "$WT"
git -C "$WT" init -q 2>/dev/null
printf 'one\n' >"$WT/a.txt"
git -C "$WT" add a.txt && git -C "$WT" commit -q -m init

ENTRY_BODY=$'\n**Done:** built the thing\n\n**In flight:** nothing\n\n**Next:** run the review\n\n```run\n/ce-code-review\n```'
mk_task() { # <stem>
  printf -- '---\nstatus: doing\nrepo: proj\nbranch: x\nworktree: .worktrees/x\ntags: []\ncreated: 2026-11-01\nclosed:\n---\n# Title\n\n## Plan\n\nplan\n\n## Handoffs\n\n### 2026-11-15 10:00 — wb-save\n%s\n' "$ENTRY_BODY" >"$TASKS_DIR/$1.md"
}
tf() { printf '%s/%s.md\n' "$TASKS_DIR" "$1"; }
state_of() { wbc_get "$1" state; }
reason_of() { wbc_get "$1" reason; }
log_text() { /usr/bin/grep "stem=${STEM:-}[ @]" "$XDG_STATE_HOME/wb/continue.log" 2>/dev/null; }
wait_log() { local _; for _ in $(seq 40); do log_text | /usr/bin/grep -q -- "$1" && return 0; sleep 0.1; done; return 1; }
wait_opt() { local _; for _ in $(seq 40); do [ -n "$(tm show -pv -t "$PANE" "$1" 2>/dev/null)" ] && return 0; sleep 0.1; done; return 1; }
live_on() { touch "$XDG_STATE_HOME/wb/continue-live"; }
tlog() { cat "$TMUX_LOG"; }
SCREEN_CLEAR='\xe2\x9d\xaf\xc2\xa0\n'
SCREEN_TEXT='\xe2\x9d\xaf\xc2\xa0some text\n'
SCREEN_DIM='\xe2\x9d\xaf\xc2\xa0\e[2mTry something\e[0m\n'
SCREEN_DIALOG='Do you want to proceed?\n  1. Yes\n  2. No\n'

T="$FIX/t.jsonl"
tr_user() { jq -nc --arg c "$2" --arg k "$1" '{type:"user",turnOrigin:($k|gsub("-";"_")),origin:{kind:$k},message:{content:$c}}'; }
tr_assistant() { jq -nc --arg m "$1" '{type:"assistant",message:{model:$m,content:[]}}'; }
typed_prompt() { printf '<command-message>wb-continue</command-message>\n<command-name>/wb-continue</command-name>\n<command-args>%s</command-args>' "$1"; }

N=0
new_live_case() { new_case "$@"; live_on; }
# new_case [screen] — a task, a tmux session whose pane shell runs the old
# Claude stub (registered under SID), and the pane/stem/sid globals.
new_case() {
  N=$((N + 1))
  STEM="proj--c$N"
  SID="sess-old-$N"
  SESS="wbch-s$N"
  : >"$TMUX_LOG"
  rm -f "$FIX/capture-pending-after" "$FIX/capture-count" "$FIX/fake-clients" "$FIX/claude-count" "$XDG_STATE_HOME/wb/continue/born/"* "$XDG_STATE_HOME/wb/continue-live"
  echo exit >"$FIX/claude-mode"
  mk_task "$STEM"
  tm new-session -d -s "$SESS" -x 120 -y 30 'bash --norc --noprofile'
  tm set -t "$SESS" @task "$(tf "$STEM")"
  PANE="$(tm list-panes -t "$SESS" -F '#{pane_id}')"
  wait_shell "$PANE"
  tm send-keys -t "$PANE" -l "oldclaude $SID '${1-$SCREEN_CLEAR}'"
  tm send-keys -t "$PANE" Enter
  for _ in $(seq 50); do
    /usr/bin/grep -lq "\"sessionId\":\"$SID\"" "$WB_CONTINUE_SESSIONS_DIR"/*.json 2>/dev/null && break
    sleep 0.1
  done
  sleep 0.2
  OLDPID="$(/usr/bin/grep -l "\"sessionId\":\"$SID\"" "$WB_CONTINUE_SESSIONS_DIR"/*.json | head -1)"
  OLDPID="$(basename "$OLDPID" .json)"
}
wait_shell() { # <pane>
  local c
  for _ in $(seq 50); do
    c="$(tm display-message -p -t "$1" '#{pane_current_command}' 2>/dev/null)"
    case "$c" in bash | zsh | sh) return 0 ;; esac
    sleep 0.1
  done
  return 1
}
# arm_req <instruction> [transcript] — arm this case's request as its session
arm_req() {
  (
    export CLAUDE_CODE_SESSION_ID="$SID" TMUX_PANE="$PANE"
    [ -z "${2:-}" ] || export WBC_TRANSCRIPT="$2" WB_CONTINUE_TEST=1
    printf '%s' "${1-}" | wbc_arm "$(tf "$STEM")"
  ) >/dev/null 2>&1
}
stage_req_nosnap() { (
  export CLAUDE_CODE_SESSION_ID="$SID" TMUX_PANE="$PANE"
  wbc_stage "$(tf "$STEM")"
) >/dev/null 2>&1; }
# snap_req — the Stop hook's turn-end snapshot a release needs (clean, now)
snap_req() { (_wbc_lock "$STEM"; wbc_set snapshot "$STEM" "$(state_of "$STEM")" "$(reason_of "$STEM")" "last_stop=$(date +%s)" last_busy=0; _wbc_unlock "$STEM") >/dev/null 2>&1; }
stage_req() { stage_req_nosnap; snap_req; }
end_case() {
  tm kill-session -t "$SESS" 2>/dev/null
  rm -f "$XDG_STATE_HOME/wb/continue-live" "$XDG_STATE_HOME/wb/disable-continue"
  rm -rf "$XDG_STATE_HOME/wb/needs-you"
}
wait_state() { # <stem> <regex> [secs] — poll the request's state
  for _ in $(seq $((${3:-8} * 10))); do
    [[ "$(wbc_get "$1" state 2>/dev/null)" =~ $2 ]] && return 0
    sleep 0.1
  done
  return 1
}
wait_gone() {
  for _ in $(seq $((${2:-10} * 10))); do
    [ -f "$(wbc_dir "$1")/request" ] || return 0
    sleep 0.1
  done
  return 1
}

# payload <fixture> <session-id> [jq filter] — the fixture with placeholders filled
payload() {
  sed -e "s/__SESSION_ID__/$2/g" -e "s#__HOME__#$HOME#g" -e 's/__USER__/u/g' -e "s#__CWD__#$WT#g" \
    -e "s#__TMPDIR__#$FIX#g" -e 's/__PROMPT_ID__/p1/g' "$PAYLOADS/$1" | jq -c "${3:-.}"
}
# the transcript each Stop payload points at: the committed one, which holds the monitor's tool result
cp "$PAYLOADS/transcript-continue-sources.jsonl" "$FIX/monitor-transcript.jsonl"
CLEAN='.background_tasks = [] | .session_crons = [] | .transcript_path = "'"$FIX"'/monitor-transcript.jsonl"'
ONLY_MONITOR='.session_crons = [] | .background_tasks |= map(select(.id == "baj6ls1xl")) | .transcript_path = "'"$FIX"'/monitor-transcript.jsonl"'
run_hook() { # <verb> <pane> <json> [extra env assignments...]
  local verb="$1" pane="$2" json="$3"
  shift 3
  printf '%s' "$json" | env ${pane:+TMUX_PANE="$pane"} "$@" "$REAL_BASH" "$HOOK" "$verb"
}
stop_clean() { run_hook hook-stop "$PANE" "$(payload Stop-background-work.json "$SID" "$CLEAN")"; }
req_sum() { cksum <"$(wbc_dir "$1")/request"; }

# =============================================================================
echo "# cheap when nothing applies"
# =============================================================================
mkdir -p "$FIX/spy"
for c in tmux jq date cat grep readlink sed awk git; do
  printf '#!/bin/sh\necho "%s $*" >> "%s/spy.log"\nexit 0\n' "$c" "$FIX" >"$FIX/spy/$c"
  chmod +x "$FIX/spy/$c"
done
: >"$FIX/spy.log"
run_hook hook-stop %5 "$(payload Stop.json nobody-here)" PATH="$FIX/spy"
assert_eq "no request dir: nothing external runs, exit 0" "0 " "$? $(cat "$FIX/spy.log")"
new_case
arm_req ""
: >"$FIX/spy.log"
run_hook hook-stop "$PANE" "$(payload Stop.json some-other-session)" PATH="$FIX/spy"
assert_eq "a request for another session: no tmux, jq, date, cat... runs" "" "$(cat "$FIX/spy.log")"
run_hook hook-session-start "$PANE" "$(payload SessionStart-startup.json "$SID")" PATH="$FIX/spy"
assert_eq "SessionStart that is not a clear: no external command runs" "" "$(cat "$FIX/spy.log")"
end_case

# =============================================================================
echo "# AE1: a quiet Stop for an armed request restarts the pane, once (live mode)"
# =============================================================================
new_case
live_on
BAD="/ce-code-review \$(touch $FIX/pwned) 'x'; touch $FIX/pwned2"
{
  tr_assistant claude-opus-5-5
  tr_user human "$(typed_prompt "$BAD")"
} >"$T"
arm_req "" "$T"
ID="$(wbc_get "$STEM" id)"
assert_eq "request armed (typed, so any instruction qualifies)" armed "$(state_of "$STEM")"
echo pickup >"$FIX/claude-mode"
ENTRY_BEFORE="$(_wb_section_text "$(tf "$STEM")" Handoffs | head -12 | cksum)"
stop_clean
assert_eq "hook exit status" 0 "$?"
assert "state moves to claimed at once" '^(claimed|restarting)$' "$(state_of "$STEM")"
wait_gone "$STEM" 15
assert_eq "the pick-up removed the request" 0 "$?"
assert_eq "one respawn of that pane id" 1 "$(tlog | /usr/bin/grep -c "^respawn-pane -k -t $PANE ")"
assert_eq "one fresh claude started" 1 "$(cat "$FIX/claude-count" 2>/dev/null)"
NEW="$(sed -n 2p "$FIX/claude-argv-1")"
assert "argv: --session-id <uuid>" '^[0-9a-f-]{36}$' "$NEW"
assert_eq "argv names the model, effort, permission mode and the pick-up prompt" \
  "--session-id $NEW --model claude-opus-5-5 --effort medium --permission-mode acceptEdits /wb-resume --continue $ID" \
  "$(tr '\n' ' ' <"$FIX/claude-argv-1" | sed 's/ $//')"
assert "the typed line carries the request id" "claude --session-id $NEW --model claude-opus-5-5 --effort medium --permission-mode acceptEdits \"/wb-resume --continue $ID\"" \
  "$(tlog | /usr/bin/grep '^send-keys -t .* -l ')"
refute "the saving session's words never reach a command line" 'pwned|ce-code-review' "$(tlog | /usr/bin/grep -E 'run-shell|send-keys')"
assert_eq "injected instruction text ran nothing" "none" "$([ -e "$FIX/pwned" ] || [ -e "$FIX/pwned2" ] && echo ran || echo none)"
assert_eq "restart-born marker for the new id" yes "$([ -e "$XDG_STATE_HOME/wb/continue/born/$NEW" ] && echo yes || echo no)"
assert_eq "the pane's @claude_session_id is the new id" "$NEW" "$(tm show -pv -t "$PANE" @claude_session_id)"
assert_eq "the old Claude process is gone" gone "$([ -d "/proc/$OLDPID" ] && echo alive || echo gone)"
for _ in $(seq 100); do [ -s "$FIX/claude-pickup-1.out" ] && break; sleep 0.1; done
assert "the pick-up output carries the frozen entry" 'pickup ok' "$(cat "$FIX/claude-pickup-1.out" 2>/dev/null)"
assert "Handoffs names the save and the old session id" "old session $SID" "$(_wb_section_text "$(tf "$STEM")" Handoffs)"
wait_log "event=restarted"
assert "log: restart" "event=restarted stem=$STEM id=$ID" "$(log_text)"
assert_eq "the helper removed the pick-up marker" no "$([ -e "$XDG_STATE_HOME/wb/continue/picked-up/$ID" ] && echo yes || echo no)"
assert_eq "no reason left on the pane" "" "$(tm show -pv -t "$PANE" @wb_continue_reason 2>/dev/null)"
end_case

# =============================================================================
echo "# shadow mode (AE7): checks run, nothing restarts"
# =============================================================================
new_case
arm_req ""
ID="$(wbc_get "$STEM" id)"
stop_clean
wait_state "$STEM" '^ready$'
assert_eq "request becomes ready" ready "$(state_of "$STEM")"
assert_eq "reason says shadow" "shadow mode: would have restarted" "$(reason_of "$STEM")"
wait_log "event=would-restart"
assert "log: would-restart line" "event=would-restart stem=$STEM id=$ID state=ready" "$(log_text)"
refute "no respawn" 'respawn-pane' "$(tlog)"
assert_eq "no fresh claude" "" "$(cat "$FIX/claude-count" 2>/dev/null)"
assert_eq "old Claude still running" alive "$([ -d "/proc/$OLDPID" ] && echo alive || echo gone)"
end_case

# =============================================================================
echo "# AE3 and the payload guards"
# =============================================================================
new_case
arm_req ""
run_hook hook-stop "$PANE" "$(payload Stop-background-work.json "$SID" '.transcript_path = "'"$FIX"'/monitor-transcript.jsonl"')"
assert_eq "background shell, subagent and a cron: stays armed" armed "$(state_of "$STEM")"
assert_eq "reason names the background work" "waiting: background work still running" "$(reason_of "$STEM")"
refute "no helper started" 'run-shell' "$(tlog)"
assert "snapshot: busy, effort, permission mode" '^1$' "$(wbc_get "$STEM" last_busy)"
assert_eq "snapshot: effort" medium "$(wbc_get "$STEM" effort)"
assert_eq "snapshot: permission mode" acceptEdits "$(wbc_get "$STEM" permission_mode)"
assert "snapshot: last_stop is an epoch" '^[0-9]{10}$' "$(wbc_get "$STEM" last_stop)"
stop_clean
wait_state "$STEM" '^ready$'
assert "a later clean payload claims it (and the helper runs)" 'event=hook-claim stem='"$STEM" "$(log_text)"
assert_eq "the clean snapshot is not busy" 0 "$(wbc_get "$STEM" last_busy)"
end_case

new_case
arm_req ""
run_hook hook-stop "$PANE" "$(payload Stop-background-work.json "$SID" "$ONLY_MONITOR")"
wait_state "$STEM" '^ready$'
assert "a payload whose only task is a monitor claims" "event=hook-claim stem=$STEM" "$(log_text)"
end_case

new_case
arm_req ""
run_hook hook-stop "$PANE" "$(payload Stop-background-work.json "$SID" '.session_crons = [] | .background_tasks |= map(select(.id == "baj6ls1xl")) | .transcript_path = "/nonexistent/t.jsonl"')"
assert_eq "an unreadable transcript counts the running entry as blocking" armed "$(state_of "$STEM")"
run_hook hook-stop "$PANE" "$(payload Stop-background-work.json "$SID" '.session_crons = [] | .background_tasks = [{"id":"m1","type":"monitor","status":"running"}] | .transcript_path = "/nonexistent/t.jsonl"')"
wait_state "$STEM" '^ready$'
assert "a type: monitor entry counts as a monitor even unreadable" "event=hook-claim stem=$STEM" "$(log_text)"
end_case

new_case
arm_req ""
run_hook hook-stop "$PANE" "$(payload Stop-background-work.json "$SID" '.background_tasks = [{"id":"x","type":"shell"}] | .session_crons = [] | .transcript_path = "'"$FIX"'/monitor-transcript.jsonl"')"
assert_eq "a task with no status counts as running" armed "$(state_of "$STEM")"
run_hook hook-stop "$PANE" "$(payload Stop-background-work.json "$SID" '.background_tasks = [{"id":"x","type":"shell","status":"completed"}] | .session_crons = [] | .transcript_path = "'"$FIX"'/monitor-transcript.jsonl"')"
wait_state "$STEM" '^ready$'
assert "a finished task does not block" "event=hook-claim stem=$STEM" "$(log_text)"
end_case

new_case
arm_req ""
run_hook hook-stop "$PANE" "$(payload Stop-background-work.json "$SID" '.background_tasks = [] | .transcript_path = "'"$FIX"'/monitor-transcript.jsonl"')"
assert_eq "a scheduled wakeup does not claim" armed "$(state_of "$STEM")"
assert_eq "reason names the scheduled job" "waiting: a scheduled job is pending" "$(reason_of "$STEM")"
refute "no helper started" 'run-shell' "$(tlog)"
end_case

new_case
arm_req ""
BEFORE="$(req_sum "$STEM")"
run_hook hook-stop "$PANE" "$(payload Stop.json some-headless-child "$CLEAN")"
assert_eq "another session id: request untouched" "$BEFORE" "$(req_sum "$STEM")"
run_hook hook-stop "$PANE" "$(payload Stop.json some-headless-child "$CLEAN")" CLAUDE_CODE_ENTRYPOINT=sdk-cli
assert_eq "headless child, same pane, TMUX_PANE set, sdk entrypoint: untouched" "$BEFORE" "$(req_sum "$STEM")"
run_hook hook-stop "" "$(payload Stop.json some-headless-child "$CLEAN")"
assert_eq "headless child with TMUX_PANE stripped: untouched" "$BEFORE" "$(req_sum "$STEM")"
run_hook hook-stop "" "$(payload Stop.json "$SID" "$CLEAN")"
assert_eq "even the right session id without TMUX_PANE: untouched" "$BEFORE" "$(req_sum "$STEM")"
run_hook hook-stop "$PANE" "$(payload Stop.json "$SID" "$CLEAN")" CLAUDE_CODE_SESSION_ATTENDED=0
assert_eq "unattended session: untouched" "$BEFORE" "$(req_sum "$STEM")"
run_hook hook-stop "%999" "$(payload Stop.json "$SID" "$CLEAN")"
assert_eq "same session id from another pane: stays armed" armed "$(state_of "$STEM")"
refute "same session id from another pane: no helper" 'run-shell' "$(tlog)"
refute "same session id from another pane: no claim in the log" 'hook-claim' "$(log_text)"
end_case

# =============================================================================
echo "# kill switch, age, needs-you, Jet looking"
# =============================================================================
new_case
arm_req ""
BEFORE="$(req_sum "$STEM")"
: >"$TMUX_LOG"
touch "$XDG_STATE_HOME/wb/disable-continue"
stop_clean
assert_eq "kill switch: the request is not even read or written" "$BEFORE" "$(req_sum "$STEM")"
refute "kill switch: no tmux call" '.' "$(tlog)"
end_case

new_case
arm_req ""
sed -i 's/^created=.*/created=1000000000/' "$(wbc_dir "$STEM")/request"
stop_clean
assert_eq "an old armed request becomes ready" ready "$(state_of "$STEM")"
assert "reason has the real minutes and the picker hint" '^waited [0-9]+ minutes; release it from the picker$' "$(reason_of "$STEM")"
refute "no helper" 'run-shell' "$(tlog)"
end_case

new_case
arm_req ""
mkdir -p "$XDG_STATE_HOME/wb/needs-you"
printf 'page\n' >"$(wb_needs_you_file "$STEM")"
stop_clean
assert_eq "a non-empty needs-you marker blocks the claim" armed "$(state_of "$STEM")"
assert_eq "reason names the /decide surface" "waiting: a /decide surface is open" "$(reason_of "$STEM")"
refute "no helper" 'run-shell' "$(tlog)"
end_case

new_case
arm_req ""
tm copy-mode -t "$PANE"
stop_clean
assert_eq "session-initiated review, pane in copy mode: ready" ready "$(state_of "$STEM")"
assert_eq "reason says Jet was looking" "Jet was looking at the pane" "$(reason_of "$STEM")"
refute "no helper" 'run-shell' "$(tlog)"
end_case

new_case
arm_req ""
echo now >"$FIX/fake-clients"
stop_clean
assert_eq "active pane of a client active in the last 60 s: ready" ready "$(state_of "$STEM")"
end_case

new_case
arm_req ""
echo old >"$FIX/fake-clients"
stop_clean
wait_state "$STEM" '^ready$'
assert "a client idle for 120 s is not looking: claimed" "event=hook-claim stem=$STEM" "$(log_text)"
end_case

new_case
{ tr_user human "$(typed_prompt 'carry on')"; } >"$T"
arm_req "" "$T"
assert_eq "typed request is armed" "1 armed" "$(wbc_get "$STEM" typed) $(state_of "$STEM")"
tm copy-mode -t "$PANE"
stop_clean
wait_state "$STEM" '^ready$'
assert "typed by Jet: copy mode does not stop the claim" "event=hook-claim stem=$STEM" "$(log_text)"
end_case

# a staged (ready) request: only the snapshot is recorded
new_case
stage_req
stop_clean
assert_eq "ready request: state untouched" ready "$(state_of "$STEM")"
assert_eq "ready request: snapshot recorded" "medium 0" "$(wbc_get "$STEM" effort) $(wbc_get "$STEM" last_busy)"
refute "ready request: no helper" 'run-shell' "$(tlog)"
end_case

# =============================================================================
echo "# the helper: guards between claim and respawn"
# =============================================================================
new_live_case "$SCREEN_TEXT"
arm_req ""
stop_clean
wait_state "$STEM" '^armed$'
assert_eq "text on the input line: back to armed" armed "$(state_of "$STEM")"
assert_eq "reason" "text or a dialog on the input line" "$(reason_of "$STEM")"
refute "no respawn" 'respawn-pane' "$(tlog)"
end_case

new_live_case "$SCREEN_DIALOG"
arm_req ""
stop_clean
wait_state "$STEM" '^armed$'
assert_eq "no input line on screen (a dialog): fail closed, armed" "text or a dialog on the input line" "$(reason_of "$STEM")"
refute "no respawn" 'respawn-pane' "$(tlog)"
end_case

new_live_case "$SCREEN_DIM"
arm_req ""
echo pickup >"$FIX/claude-mode"
stop_clean
wait_gone "$STEM" 15
assert_eq "a dim placeholder on the input line is not text: restarts" 1 "$(tlog | /usr/bin/grep -c '^respawn-pane')"
end_case

new_live_case
arm_req ""
echo 2 >"$FIX/capture-pending-after"
stop_clean
wait_state "$STEM" '^armed$'
assert_eq "text appearing before the final check: armed again" "text or a dialog on the input line" "$(reason_of "$STEM")"
refute "no respawn" 'respawn-pane' "$(tlog)"
assert_eq "the restart-born marker was removed" "" "$(ls "$XDG_STATE_HOME/wb/continue/born" 2>/dev/null)"
assert_eq "new_session_id cleared" "" "$(wbc_get "$STEM" new_session_id)"
end_case

new_live_case
arm_req ""
tm set -p -t "$PANE" @claude_working 1
stop_clean
wait_state "$STEM" '^armed$' 8
sleep 0.3
assert_eq "a turn running during the settle wait: armed again" "a new turn started" "$(reason_of "$STEM")"
refute "no respawn" 'respawn-pane' "$(tlog)"
end_case

new_live_case
arm_req ""
stop_clean &
stop_clean &
wait
wait_state "$STEM" '^restarting$|^failed$|^ready$|^armed$' 10
sleep 1
assert_eq "two Stops in quick succession: one claim" 1 "$(log_text | /usr/bin/grep -c 'event=hook-claim')"
assert_eq "two Stops in quick succession: one helper started" 1 "$(tlog | /usr/bin/grep -c '^run-shell')"
end_case

# AE4: a commit between arm and Stop
new_live_case
arm_req ""
git -C "$WT" commit -q --allow-empty -m "after the save"
stop_clean
wait_state "$STEM" '^refused$'
assert_eq "a commit after the save: refused" refused "$(state_of "$STEM")"
assert_eq "reason" "branch moved since the save" "$(reason_of "$STEM")"
refute "no respawn" 'respawn-pane' "$(tlog)"
wait_opt @wb_continue_reason
assert_eq "the reason sits on the pane" "branch moved since the save" "$(tm show -pv -t "$PANE" @wb_continue_reason)"
wait_log "event=helper-refused"
assert "log has the refusal" "event=helper-refused stem=$STEM .*state=refused reason=\"branch moved since the save\"" "$(log_text)"
end_case

new_live_case
arm_req ""
printf 'edit\n' >>"$WT/a.txt"
stop_clean
wait_state "$STEM" '^refused$'
assert_eq "an edited working tree: refused" "working tree changed since the save" "$(reason_of "$STEM")"
git -C "$WT" checkout -q -- a.txt
end_case

new_live_case
arm_req ""
printf '\n### 2026-11-15 11:00 — wb pause (auto)\n\nnewer\n' >"$FIX/newer"
# the newer entry goes above the old one: Handoffs is newest first in this fixture
awk -v f="$FIX/newer" '/^### 2026-11-15 10:00/ && !d { while ((getline l < f) > 0) print l; d = 1 } { print }' "$(tf "$STEM")" >"$FIX/t.new" && mv "$FIX/t.new" "$(tf "$STEM")"
stop_clean
wait_state "$STEM" '^refused$'
assert "a newer Handoffs entry: refused" 'newer Handoffs entry|entry changed' "$(reason_of "$STEM")"
refute "no respawn" 'respawn-pane' "$(tlog)"
end_case

new_live_case
arm_req ""
mkdir -p "$XDG_STATE_HOME/wb/needs-you"
stop_clean
# the Stop passes (marker absent), then a /decide surface opens before the helper's own re-check
printf 'page\n' >"$(wb_needs_you_file "$STEM")"
wait_state "$STEM" '^armed$' 5
assert "a /decide surface opened during the settle: armed again" 'waiting: a /decide surface is open' "$(reason_of "$STEM")"
refute "no respawn" 'respawn-pane' "$(tlog)"
end_case

# the pane's Claude is not the saving session
new_live_case
(
  export CLAUDE_CODE_SESSION_ID="some-other-id" TMUX_PANE="$PANE"
  printf '' | wbc_arm "$(tf "$STEM")"
) >/dev/null 2>&1
run_hook hook-stop "$PANE" "$(payload Stop.json some-other-id "$CLEAN")"
wait_state "$STEM" '^ready$'
assert_eq "the pane's Claude is another session: ready, no restart" "could not confirm the pane's Claude is the one that saved" "$(reason_of "$STEM")"
refute "no respawn" 'respawn-pane' "$(tlog)"
end_case

# stub claude that exits at once: failed, save untouched, old id in the reason
new_live_case
arm_req ""
ID="$(wbc_get "$STEM" id)"
echo exit >"$FIX/claude-mode"
ENTRY_BEFORE="$(cksum <"$(tf "$STEM")")"
stop_clean
wait_state "$STEM" '^failed$' 15
assert_eq "the fresh Claude never picks up: failed" failed "$(state_of "$STEM")"
assert "reason has the old session id and the resume command" "the old session is $SID: claude --resume $SID" "$(reason_of "$STEM")"
wait_opt @wb_continue_reason
assert "pane option has the same reason" "claude --resume $SID" "$(tm show -pv -t "$PANE" @wb_continue_reason)"
wait_log "event=helper-failed"
assert "log has the failure with the old id" "event=helper-failed stem=$STEM id=$ID state=failed reason=\".*claude --resume $SID" "$(log_text)"
assert_eq "the save entry is unchanged" "$ENTRY_BEFORE" "$(cksum <"$(tf "$STEM")")"
assert_eq "the request is kept (releasable)" failed "$(state_of "$STEM")"
end_case

# unsafe values are dropped from the launch line
new_live_case
arm_req ""
sed -i 's/^model=.*/model=bad model;touch x/' "$(wbc_dir "$STEM")/request"
echo pickup >"$FIX/claude-mode"
stop_clean
wait_gone "$STEM" 15
refute "an unsafe model is dropped, not typed" 'touch|--model' "$(tlog | /usr/bin/grep '^send-keys -t .* -l ')"
end_case

# permission mode "default" (what transcripts record) is not a CLI choice: no flag
new_live_case
arm_req ""
echo pickup >"$FIX/claude-mode"
run_hook hook-stop "$PANE" "$(payload Stop-background-work.json "$SID" "$CLEAN | .permission_mode = \"default\"")"
wait_gone "$STEM" 15
refute "permission mode default: no --permission-mode on the launch line" '--permission-mode' "$(tlog | /usr/bin/grep '^send-keys -t .* -l ')"
end_case

# an empty model: no --model, and the request records the fallback
new_live_case
arm_req ""
echo pickup >"$FIX/claude-mode"
(
  _wbc_lock "$STEM"
  wbc_set test "$STEM" "$(state_of "$STEM")" "$(reason_of "$STEM")" model=
  _wbc_unlock "$STEM"
)
stop_clean
wait_state "$STEM" '^restarting$' 10
assert_eq "model_fallback recorded" 1 "$(wbc_get "$STEM" model_fallback)"
wait_gone "$STEM" 15
refute "no --model on the launch line" '--model' "$(tlog | /usr/bin/grep '^send-keys -t .* -l ')"
end_case

# =============================================================================
echo "# SessionStart: /clear by hand drops the pane's request"
# =============================================================================
new_case
arm_req ""
run_hook hook-session-start "$PANE" "$(payload SessionStart-clear.json brand-new-id)"
assert_eq "clear with a different session id: the request is gone" "none" "$([ -f "$(wbc_dir "$STEM")/request" ] && echo there || echo none)"
assert "logged with the reason" "event=session-clear stem=$STEM .*reason=\"cleared by hand\"" "$(log_text)"
end_case

new_case
arm_req ""
run_hook hook-session-start "$PANE" "$(payload SessionStart-startup.json "$SID")"
assert_eq "source startup: the request stays" armed "$(state_of "$STEM")"
tm set -t "$SESS" @task "$(tf proj--someone-else)"
run_hook hook-session-start "$PANE" "$(payload SessionStart-clear.json brand-new-id)"
assert_eq "clear in a pane whose session is another task: the request stays" armed "$(state_of "$STEM")"
tm set -t "$SESS" @task "$(tf "$STEM")"
run_hook hook-session-start "%999" "$(payload SessionStart-clear.json brand-new-id)"
assert_eq "clear in another pane: the request stays" armed "$(state_of "$STEM")"
end_case

# =============================================================================
echo "# U5: release (wb continue release): AE5, the checks, --all, --pane, double press"
# =============================================================================
# AE5: a staged plain save is released by Jet; shadow mode (no continue-live
# file) does not apply to a release; the helper restarts the pane and the
# fresh Claude's pick-up succeeds. The call returns before the restart is done.
new_case
stage_req
ID="$(wbc_get "$STEM" id)"
assert_eq "staged save is ready" ready "$(state_of "$STEM")"
echo pickup >"$FIX/claude-mode"
out="$(wbc_release "$(tf "$STEM")" 2>&1)"
assert_eq "release exit status" 0 "$?"
assert "release prints one line: released" "^$STEM: released$" "$out"
assert "the call returned with the request claimed or restarting (detached)" '^(claimed|restarting)$' "$(state_of "$STEM")"
wait_gone "$STEM" 15
assert_eq "AE5: the pick-up removed the request" 0 "$?"
assert_eq "AE5: one respawn of that pane id (live though shadow mode is on)" 1 "$(tlog | /usr/bin/grep -c "^respawn-pane -k -t $PANE ")"
for _ in $(seq 100); do [ -s "$FIX/claude-pickup-1.out" ] && break; sleep 0.1; done
assert "AE5: the pick-up succeeded" 'pickup ok' "$(cat "$FIX/claude-pickup-1.out" 2>/dev/null)"
assert "AE5: ... and carries the save's command" 'ce-code-review' "$(cat "$FIX/claude-pickup-1.out" 2>/dev/null)"
wait_log "event=restarted"
assert "log: release then restarted" "event=release stem=$STEM id=$ID state=claimed" "$(log_text)"
end_case

# a turn in progress: refused for that reason, the request stays ready
new_case
stage_req
tm set -p -t "$PANE" @claude_working 1
out="$(wbc_release "$(tf "$STEM")" 2>&1)"
assert_eq "turn in progress: exit status 1" 1 "$?"
assert "turn in progress: reason shown" "$STEM: not released: a turn is in progress" "$out"
assert_eq "turn in progress: the request stays ready" ready "$(state_of "$STEM")"
refute "turn in progress: nothing respawned" 'respawn-pane' "$(tlog)"
assert_eq "turn in progress: a wait is not a failure, so the pane's status mark is not set" "" "$(tm show -pv -t "$PANE" @wb_continue_reason 2>/dev/null)"
assert "log: release-wait line" "event=release-wait stem=$STEM .*a turn is in progress" "$(log_text)"
# a drift refusal does mark the pane, and the next save clears it
tm set -p -t "$PANE" @claude_working ""
printf '\n### 2026-11-15 11:00 — wb-save\n\n**Done:** more\n' >>"$(tf "$STEM")"
wbc_release "$(tf "$STEM")" >/dev/null 2>&1
assert "a drift refusal puts its reason on the pane" 'newer Handoffs entry|save entry changed' "$(tm show -pv -t "$PANE" @wb_continue_reason 2>/dev/null)"
mk_task "$STEM"
stage_req
assert_eq "a fresh stage clears the pane's reason" "" "$(tm show -pv -t "$PANE" @wb_continue_reason 2>/dev/null)"
end_case

# a dirty snapshot: background work at the last turn end
new_case
stage_req
(_wbc_lock "$STEM"; wbc_set snapshot "$STEM" ready "$(reason_of "$STEM")" "last_stop=$(date +%s)" last_busy=1; _wbc_unlock "$STEM")
out="$(wbc_release "$(tf "$STEM")" 2>&1)"
assert "busy snapshot: refused with its reason" "not released: background work was still running at the last turn end" "$out"
assert_eq "busy snapshot: the request stays ready" ready "$(state_of "$STEM")"
refute "busy snapshot: nothing respawned" 'respawn-pane' "$(tlog)"
(_wbc_lock "$STEM"; wbc_set snapshot "$STEM" ready "$(reason_of "$STEM")" last_busy=0; _wbc_unlock "$STEM")
echo pickup >"$FIX/claude-mode"
out="$(wbc_release "$(tf "$STEM")" 2>&1)"
assert "a clean snapshot releases" "$STEM: released" "$out"
wait_gone "$STEM" 15
end_case

# text on the input line, a /decide surface, a session that is not there
new_case "$SCREEN_TEXT"
stage_req
(_wbc_lock "$STEM"; wbc_set snapshot "$STEM" ready "$(reason_of "$STEM")" "last_stop=$(date +%s)" last_busy=0; _wbc_unlock "$STEM")
out="$(wbc_release "$(tf "$STEM")" 2>&1)"
assert "typed text on the input line: not released" "not released: text or a dialog on the input line" "$out"
assert_eq "... and the request stays ready" ready "$(state_of "$STEM")"
end_case
new_case
stage_req
mkdir -p "$XDG_STATE_HOME/wb/needs-you"
printf 'page https://example.test/a r1\n' >"$(wb_needs_you_file "$STEM")"
out="$(wbc_release "$(tf "$STEM")" 2>&1)"
assert "an open /decide surface: not released" "not released: a /decide surface is open" "$out"
refute "... nothing respawned" 'respawn-pane' "$(tlog)"
end_case
new_case
stage_req
tm set -t "$SESS" @task "$(tf proj--someone-else)"
out="$(wbc_release "$(tf "$STEM")" 2>&1)"
assert "the pane belongs to another task: the session is not running" "not released: the session is not running" "$out"
end_case

# drift refuses (the save changed): a newer Handoffs entry
new_case
stage_req
printf '\n### 2026-11-15 11:00 — wb-save\n\n**Done:** more\n' >>"$(tf "$STEM")"
out="$(wbc_release "$(tf "$STEM")" 2>&1)"
assert "drift: refused with U2's reason" "$STEM: refused: (a newer Handoffs entry landed since the save|the save entry changed since it was armed)" "$out"
assert_eq "drift: the request is refused" refused "$(state_of "$STEM")"
out="$(wbc_release "$(tf "$STEM")" 2>&1)"
assert "a refused request is not released by a second press" "refused: .*; not released" "$out"
refute "nothing respawned" 'respawn-pane' "$(tlog)"
end_case

# --all: one drifted row is refused, the ready one goes, one with no command waits
# (leftover requests of the cases above, whose sessions are gone, are skipped silently)
new_case
STEM1="$STEM"
stage_req
new_case
STEM2="$STEM"

stage_req
SAVED_BODY="$ENTRY_BODY"
ENTRY_BODY=$'\n**Done:** built the thing\n\n**Next:** just carry on'
new_case
STEM3="$STEM"
PANE3="$PANE"
stage_req
ENTRY_BODY="$SAVED_BODY"
assert_eq "the plain save has no command" "" "$(wbc_get "$STEM3" command)"
printf '\n### 2026-11-15 11:00 — wb-save\n\n**Done:** more\n' >>"$(tf "$STEM1")"
echo pickup >"$FIX/claude-mode"
out="$(wbc_release --all 2>&1)"
assert_eq "--all: exit status 0 (one released)" 0 "$?"
assert "--all: the drifted one is refused" "$STEM1: refused: (a newer Handoffs entry|the save entry changed)" "$out"
refute "--all: requests whose sessions are gone say nothing" "not running" "$out"
assert "--all: the ready one is released" "$STEM2: released" "$out"
refute "--all: the one with no command is not touched" "$STEM3" "$out"
wait_gone "$STEM2" 15
assert_eq "--all: the released request was picked up" 0 "$?"
assert_eq "--all: the drifted request is refused" refused "$(state_of "$STEM1")"
assert_eq "--all: the no-command request is still ready" ready "$(state_of "$STEM3")"
assert_eq "--all: exactly one respawn" 1 "$(tlog | /usr/bin/grep -c '^respawn-pane ')"
# --pane releases any save, even one with no command; the fresh Claude follows the Next prose
out="$(wbc_release --pane "$PANE3" 2>&1)"
assert "--pane: released although no command" "$STEM3: released" "$out"
wait_gone "$STEM3" 15
assert_eq "--pane: picked up" 0 "$?"
for _ in $(seq 100); do [ -s "$FIX/claude-pickup-2.out" ] && break; sleep 0.1; done
assert "--pane: the pick-up says to follow the Next prose" 'none recorded; follow the entry' "$(cat "$FIX/claude-pickup-2.out" 2>/dev/null)"
out="$(wbc_release --pane %9999 2>&1)"
assert "--pane: a pane with no request says so" "no saved session to continue in this pane" "$out"
tm kill-session -t "wbch-s$((N - 2))" 2>/dev/null
tm kill-session -t "wbch-s$((N - 1))" 2>/dev/null
end_case

# pressing release twice restarts once
new_case
stage_req
echo pickup >"$FIX/claude-mode"
out1="$(wbc_release "$(tf "$STEM")" 2>&1)"
out2="$(wbc_release "$(tf "$STEM")" 2>&1)"
assert "first press releases" "$STEM: released" "$out1"
assert "second press does not (already restarting, or already done)" "already restarting|no saved session" "$out2"
wait_gone "$STEM" 15
sleep 0.5
assert_eq "one respawn for two presses" 1 "$(tlog | /usr/bin/grep -c '^respawn-pane ')"
assert_eq "one fresh Claude" 1 "$(cat "$FIX/claude-count" 2>/dev/null)"
end_case

# an armed request: Jet's own press outranks waiting for a Stop
new_case
arm_req ""
assert_eq "armed before the press" armed "$(state_of "$STEM")"
snap_req
echo pickup >"$FIX/claude-mode"
out="$(wbc_release "$(tf "$STEM")" 2>&1)"
assert "armed: released by the press" "$STEM: released" "$out"
wait_gone "$STEM" 15
assert_eq "armed: restarted and picked up" 0 "$?"
end_case

# a failed restart can be released again
new_case
stage_req
(_wbc_lock "$STEM"; wbc_set test "$STEM" failed "the pane's shell never appeared"; _wbc_unlock "$STEM")
echo pickup >"$FIX/claude-mode"
out="$(wbc_release "$(tf "$STEM")" 2>&1)"
assert "failed: released again" "$STEM: released" "$out"
wait_gone "$STEM" 15
assert_eq "failed: second attempt picked up" 0 "$?"
end_case

# after a manual /clear the row is gone
new_case
stage_req
assert_eq "the row file exists while the request does" yes "$([ -f "$(wbc_dir "$STEM")/row" ] && echo yes || echo no)"
run_hook hook-session-start "$PANE" "$(payload SessionStart-clear.json brand-new-id)"
assert_eq "after /clear by hand: no request and no row" none "$([ -f "$(wbc_dir "$STEM")/row" ] || [ -f "$(wbc_dir "$STEM")/request" ] && echo there || echo none)"
end_case

# =============================================================================
echo "# U6: what Jet has not seen is counted before the restart, from the old transcript"
# =============================================================================
BASE=1800000000
iso() { date -u -d "@$1" +%Y-%m-%dT%H:%M:%S.000Z; }
UNSEEN_DIR="$XDG_STATE_HOME/wb/continue/unseen"
# mk_old <turn: "<prompt id> <start> <end>">... — the old session's transcript
# (turns cut at user lines with a turnOrigin; the end is its last line's time)
# and reply file (one anchor per turn), under the fixture HOME.
mk_old() {
  local spec pid st en tp="$HOME/.claude/projects/proj/$SID.jsonl" rf="$HOME/.claude/replies/$SID.md"
  mkdir -p "${tp%/*}" "${rf%/*}"
  : >"$tp"
  printf -- '---\nsession_id: %s\ntask: \n---\n\n' "$SID" >"$rf"
  for spec in "$@"; do
    read -r pid st en <<<"$spec"
    {
      jq -nc --arg p "$pid" --arg t "$(iso "$st")" '{type:"user",turnOrigin:"human",promptId:$p,timestamp:$t,origin:{kind:"human"},message:{content:"go"}}'
      jq -nc --arg t "$(iso $((st + 1)))" '{type:"assistant",timestamp:$t,message:{content:[]}}'
      jq -nc --arg t "$(iso "$en")" '{type:"assistant",timestamp:$t,message:{content:[]}}'
      printf '{"type":"last-prompt"}\n'
    } >>"$tp"
    printf '## 2026-11-15 10:00 · %s\n<!-- turn {"prompt_id":"%s","session_id":"%s","ts":"%s"} -->\n### Prompt\n> go\n### Reply\nok\n\n' "$pid" "$pid" "$SID" "$(iso "$st")" >>"$rf"
  done
}
# restart_and_wait — Jet releases the saved session; return once the helper
# has respawned the pane and typed the launch (the fresh claude stub ran)
restart_and_wait() {
  stage_req
  wbc_release "$(tf "$STEM")" >/dev/null 2>&1
  for _ in $(seq 150); do [ -f "$FIX/claude-count" ] && break; sleep 0.1; done
  sleep 0.2
}
unseen_file() { printf '%s/%s' "$UNSEEN_DIR" "$STEM"; }
unseen_text() { cat "$(unseen_file)" 2>/dev/null; }

# AE6: two turns end after the stamp
new_case
mk_old "p1 $BASE $((BASE + 10))" "p2 $((BASE + 100)) $((BASE + 110))" "p3 $((BASE + 200)) $((BASE + 210))"
tm set -p -t "$PANE" @wb_seen_at $((BASE + 50))
restart_and_wait
assert_eq "AE6: two turns ended after the stamp: one line, count 2, divider at the first" "$SID 2 p2" "$(unseen_text)"
assert_eq "AE6: the pane carries the count (it survives the respawn)" 2 "$(tm show -pv -t "$PANE" @wb_unseen)"
assert_eq "the pane was respawned (a real restart)" 1 "$(tlog | /usr/bin/grep -c "^respawn-pane -k -t $PANE ")"
end_case

# a stamp later than every turn: nothing to record
new_case
mk_old "p1 $BASE $((BASE + 10))" "p2 $((BASE + 100)) $((BASE + 110))"
tm set -p -t "$PANE" @wb_seen_at $((BASE + 1000))
restart_and_wait
assert_eq "stamp later than every turn: no unseen file" none "$([ -e "$(unseen_file)" ] && echo there || echo none)"
assert_eq "... and no pane mark" "" "$(tm show -pv -t "$PANE" @wb_unseen 2>/dev/null)"
assert_eq "... but the pane was restarted" 1 "$(tlog | /usr/bin/grep -c "^respawn-pane -k -t $PANE ")"
end_case

# a turn is unseen by its END: one that finished between a focus-in (+20) and the
# focus-out (+50) was watched; one that began while watching but ended after he left is not
new_case
mk_old "p1 $BASE $((BASE + 10))" "p2 $((BASE + 30)) $((BASE + 40))" "p3 $((BASE + 45)) $((BASE + 60))"
tm set -p -t "$PANE" @wb_seen_at $((BASE + 50))
restart_and_wait
assert_eq "turns that finish between a focus-in and the next focus-out are not counted; one ending after he left is" "$SID 1 p3" "$(unseen_text)"
end_case

# no stamp at all: every turn counts
new_case
mk_old "p1 $BASE $((BASE + 10))" "p2 $((BASE + 100)) $((BASE + 110))" "p3 $((BASE + 200)) $((BASE + 210))"
restart_and_wait
assert_eq "no stamp: every turn counts, the divider at the first" "$SID 3 p1" "$(unseen_text)"
end_case

# a turn with no anchor in the reply file cannot be found by the viewer: not counted
new_case
mk_old "p1 $BASE $((BASE + 10))" "p2 $((BASE + 100)) $((BASE + 110))"
sed -i '/"prompt_id":"p1"/d' "$HOME/.claude/replies/$SID.md"
restart_and_wait
assert_eq "a turn with no anchor is skipped; the first anchored one is the divider target" "$SID 1 p2" "$(unseen_text)"
end_case

# the pane Jet is looking at counts as seen up to now
new_case
mk_old "p1 $BASE $((BASE + 10))" "p2 $((BASE + 100)) $((BASE + 110))"
echo new >"$FIX/fake-clients"
restart_and_wait
assert_eq "restart of a pane Jet is looking at: no unseen file" none "$([ -e "$(unseen_file)" ] && echo there || echo none)"
assert_eq "... and no pane mark" "" "$(tm show -pv -t "$PANE" @wb_unseen 2>/dev/null)"
assert_eq "... the pane was restarted all the same" 1 "$(tlog | /usr/bin/grep -c "^respawn-pane -k -t $PANE ")"
end_case

# a second restart adds a line; an earlier line stays
new_case
mkdir -p "$UNSEEN_DIR"
printf 'sess-earlier 1 q9\n' >"$(unseen_file)"
mk_old "p1 $BASE $((BASE + 10))" "p2 $((BASE + 100)) $((BASE + 110))"
tm set -p -t "$PANE" @wb_seen_at $((BASE + 50))
restart_and_wait
assert_eq "two restarts leave two lines" "sess-earlier 1 q9|$SID 1 p2" "$(unseen_text | paste -sd'|')"
assert_eq "... and the pane mark is their sum" 2 "$(tm show -pv -t "$PANE" @wb_unseen)"
end_case

# shadow mode restarts nothing, so nothing is recorded
new_case
mk_old "p1 $BASE $((BASE + 10))"
arm_req ""
stop_clean
wait_state "$STEM" '^ready$'
assert_eq "shadow mode: no unseen file" none "$([ -e "$(unseen_file)" ] && echo there || echo none)"
assert_eq "shadow mode: no pane mark" "" "$(tm show -pv -t "$PANE" @wb_unseen 2>/dev/null)"
end_case
rm -rf "$UNSEEN_DIR"

# =============================================================================
echo "# review fixes: input-line bytes as the live screen prints them"
# =============================================================================
# Lines captured with `tmux capture-pane -ep` from live Claude panes: every
# input line starts with \e[39m, an idle one is blank or a dim suggestion.
# The line above the prompt is a full-width coloured rule, which is why tmux
# starts the prompt row with \e[39m (the colour carries over, no reset between).
RULE="\e[38;5;244m$(printf '\xe2\x94\x80%.0s' $(seq 120))\e[39m\n"
SCREEN_LIVE_BLANK="$RULE"'\e[39m\xe2\x9d\xaf\xc2\xa0\n'
SCREEN_LIVE_DIM="$RULE"'\e[39m\xe2\x9d\xaf\xc2\xa0\e[2mTry something else\e[0m\n'
SCREEN_LIVE_TEXT="$RULE"'\e[39m\xe2\x9d\xaf\xc2\xa0hello\n'
# The same three lines as bytes, straight into the parser (no tmux in between).
eval "$(sed -n '/^wbch_input_pending() {/,/^}/p' "$HOOK")"
input_pending_for() { ( SCR="$1"; wb_capture_pane() { printf '%b' "$SCR"; }; wbch_input_pending %0 && echo pending || echo clear ); }
assert_eq "bytes: \\e[39m, glyph, dim suggestion: clear" clear "$(input_pending_for '\e[39m\xe2\x9d\xaf\xc2\xa0\e[2mTry something else\e[0m\n')"
assert_eq "bytes: \\e[39m, glyph, typed text: pending" pending "$(input_pending_for '\e[39m\xe2\x9d\xaf\xc2\xa0hello\n')"
assert_eq "bytes: \\e[39m, glyph, blank: clear" clear "$(input_pending_for '\e[39m\xe2\x9d\xaf\xc2\xa0\n')"
assert_eq "bytes: typed text then a dim hint after it: pending" pending "$(input_pending_for '\e[39m\xe2\x9d\xaf\xc2\xa0hello \e[2mmore\e[0m\n')"
assert_eq "bytes: no prompt line (a dialog): pending (fail closed)" pending "$(input_pending_for 'Do you want to proceed?\n')"
for sc in "LIVE_BLANK:$SCREEN_LIVE_BLANK" "LIVE_DIM:$SCREEN_LIVE_DIM"; do
  new_case "${sc#*:}"
  sc="${sc%%:*}"
  stage_req
  echo pickup >"$FIX/claude-mode"
  out="$(wbc_release "$(tf "$STEM")" 2>&1)"
  assert "live idle prompt ($sc): counts as clear, released" "$STEM: released" "$out"
  wait_gone "$STEM" 15
  end_case
done
new_case "$SCREEN_LIVE_TEXT"
stage_req
out="$(wbc_release "$(tf "$STEM")" 2>&1)"
assert "live prompt with typed text: pending, not released" "not released: text or a dialog on the input line" "$out"
refute "... nothing respawned" 'respawn-pane' "$(tlog)"
end_case

# =============================================================================
echo "# review fixes: transcript greps read past an invalid byte"
# =============================================================================
printf '{"type":"user","toolUseResult":{"persistent":true,"taskId":"baj6ls1xl","note":"bad \xff byte"}}\n' >"$FIX/badbyte-transcript.jsonl"
new_case
arm_req ""
run_hook hook-stop "$PANE" "$(payload Stop-background-work.json "$SID" "$ONLY_MONITOR | .transcript_path = \"$FIX/badbyte-transcript.jsonl\"")"
wait_state "$STEM" '^ready$'
assert "a monitor line holding an invalid byte still counts as a monitor: claims" "event=hook-claim stem=$STEM" "$(log_text)"
end_case

# =============================================================================
echo "# review fixes: a drift check that cannot take its lock does not restart"
# =============================================================================
new_live_case
arm_req ""
ID="$(wbc_get "$STEM" id)"
(_wbc_lock "$STEM"; wbc_set test "$STEM" claimed "claimed by the Stop hook"; _wbc_unlock "$STEM")
rm -f "$FIX/hold-lock"
( wb_task_lock_acquire "continue-$STEM" && for _ in $(seq 100); do [ -e "$FIX/hold-lock-release" ] && break; sleep 0.1; done ) &
holder=$!
sleep 0.3
( sleep 2; touch "$FIX/hold-lock-release" ) &
env WB_CONTINUE_SETTLE_MS=200 WB_CONTINUE_SETTLE_MAX_MS=1500 "$REAL_BASH" "$HOOK" helper "$STEM" "$ID"
wait "$holder" 2>/dev/null
rm -f "$FIX/hold-lock-release"
assert_eq "lock unavailable at the drift step: back to armed" armed "$(state_of "$STEM")"
assert_eq "reason names the lock" "could not take the request lock for the drift check" "$(reason_of "$STEM")"
refute "no respawn" 'respawn-pane' "$(tlog)"
assert_eq "the old Claude is still running" alive "$([ -d "/proc/$OLDPID" ] && echo alive || echo gone)"
end_case

# =============================================================================
echo "# review fixes: nothing slow between the final look and the respawn"
# =============================================================================
new_case
mk_old "p1 1800000000 1800000010"
stage_req
echo pickup >"$FIX/claude-mode"
wbc_release "$(tf "$STEM")" >/dev/null 2>&1
wait_gone "$STEM" 15
between="$(tlog | awk '/^capture-pane/ { buf = ""; next } /^respawn-pane/ { print buf; exit } { buf = buf $0 "\n" }')"
assert "the final look is the only call before the respawn" "^show -pv -t $PANE @claude_working$" "$between"
refute "the unseen scan (display-message, focus stamp) is not between them" 'display-message|@wb_seen_at' "$between"
assert "the unseen scan did run, before that look" '@wb_seen_at' "$(tlog)"
end_case

# =============================================================================
echo "# review fixes: a release needs a recorded turn end"
# =============================================================================
new_case
stage_req_nosnap
assert_eq "a staged request has no snapshot yet" "" "$(wbc_get "$STEM" last_stop)"
out="$(wbc_release "$(tf "$STEM")" 2>&1)"
assert_eq "no snapshot: exit status 1" 1 "$?"
assert "no snapshot: refused with the reason" "$STEM: not released: no turn end was recorded since the save \\(is the wb-continue hook loaded\\?\\)" "$out"
assert_eq "no snapshot: the request stays ready" ready "$(state_of "$STEM")"
refute "no snapshot: nothing respawned" 'respawn-pane' "$(tlog)"
snap_req
echo pickup >"$FIX/claude-mode"
assert "once a turn end is recorded the same release goes" "$STEM: released" "$(wbc_release "$(tf "$STEM")" 2>&1)"
wait_gone "$STEM" 15
end_case

# =============================================================================
echo "# review fixes: a request that failed after the respawn can be released"
# =============================================================================
new_live_case
arm_req ""
echo exit >"$FIX/claude-mode"
stop_clean
wait_state "$STEM" '^failed$' 15
assert_eq "the restart failed after a real respawn" failed "$(state_of "$STEM")"
assert "it knows the fresh session id" '^[0-9a-f-]{36}$' "$(wbc_get "$STEM" new_session_id)"
assert_eq "the old Claude is gone" gone "$([ -d "/proc/$OLDPID" ] && echo alive || echo gone)"
wait_shell "$PANE"
: >"$TMUX_LOG"
echo pickup >"$FIX/claude-mode"
sed -i 's/^stops_since_save=.*/stops_since_save=5/' "$(wbc_dir "$STEM")/request"
out="$(wbc_release "$(tf "$STEM")" 2>&1)"
assert "released although the old Claude is gone and the pane is at a shell" "$STEM: released" "$out"
wait_gone "$STEM" 15
assert_eq "the retry restarted the pane and was picked up" 0 "$?"
assert_eq "one respawn for the retry" 1 "$(tlog | /usr/bin/grep -c '^respawn-pane -k ')"
end_case

# a failed request with no new_session_id (no respawn happened) keeps the old-session check
new_case
stage_req
(_wbc_lock "$STEM"; wbc_set test "$STEM" failed "could not mark"; _wbc_unlock "$STEM")
(
  export CLAUDE_CODE_SESSION_ID="some-other-id" TMUX_PANE="$PANE"
  _wbc_lock "$STEM"; wbc_set test "$STEM" failed "x" session_id=some-other-id; _wbc_unlock "$STEM"
)
out="$(wbc_release "$(tf "$STEM")" 2>&1)"
assert "failed with no new session id and another Claude in the pane: not released" "not released: could not confirm the pane's Claude is the one that saved" "$out"
end_case

# =============================================================================
echo "# review fixes: claimed and restarting requests age out"
# =============================================================================
# a claimed request nobody updated for the stale limit: failed, naming the old session
new_case "$SCREEN_TEXT"
stage_req
ID="$(wbc_get "$STEM" id)"
(_wbc_lock "$STEM"; wbc_set test "$STEM" claimed "claimed by the Stop hook"; _wbc_unlock "$STEM")
sed -i 's/^updated=.*/updated=1000000000/' "$(wbc_dir "$STEM")/request"
out="$(wbc_release "$(tf "$STEM")" 2>&1)"
refute "an old claim is not answered 'already restarting'" 'already restarting' "$out"
assert_eq "an old claim becomes failed (the pane has text, so the release itself is refused)" failed "$(state_of "$STEM")"
assert "its reason names the old session and the resume command" "the old session is $SID: claude --resume $SID" "$(reason_of "$STEM")"
assert "log: stale-claim" "event=stale-claim stem=$STEM id=$ID state=failed reason=\".*no update for" "$(log_text)"
end_case

# a fresh claim is still 'already restarting'
new_case
stage_req
(_wbc_lock "$STEM"; wbc_set test "$STEM" claimed "claimed by the Stop hook"; _wbc_unlock "$STEM")
out="$(wbc_release "$(tf "$STEM")" 2>&1)"
assert "a fresh claim: already restarting" "$STEM: already restarting" "$out"
assert_eq "... and still claimed" claimed "$(state_of "$STEM")"
end_case

# a claimed request whose pane no longer exists
new_case
stage_req
(_wbc_lock "$STEM"; wbc_set test "$STEM" restarting "restarting the pane" pane=%9999 new_session_id=fresh-id; _wbc_unlock "$STEM")
out="$(wbc_release "$(tf "$STEM")" 2>&1)"
assert_eq "its pane is gone: failed" failed "$(state_of "$STEM")"
assert "log: stale-claim says the pane is gone" "event=stale-claim stem=$STEM .*its pane is gone" "$(log_text)"
refute "the answer is not 'already restarting'" 'already restarting' "$out"
end_case

# /wb-save's stage over a stale claim replaces it; over a live one leaves it
new_case
stage_req
ID="$(wbc_get "$STEM" id)"
(_wbc_lock "$STEM"; wbc_set test "$STEM" claimed "claimed by the Stop hook"; _wbc_unlock "$STEM")
stage_req_nosnap
assert_eq "a fresh claim: /wb-save's stage leaves it" "claimed $ID" "$(state_of "$STEM") $(wbc_get "$STEM" id)"
sed -i 's/^updated=.*/updated=1000000000/' "$(wbc_dir "$STEM")/request"
stage_req_nosnap
assert_eq "an old claim: the stage replaces it with a ready request" ready "$(state_of "$STEM")"
if [ "$ID" != "$(wbc_get "$STEM" id)" ]; then echo "ok   - ... under a new id"; else echo "FAIL - the stale request kept its id"; fail=1; fi
end_case

# =============================================================================
echo "# review fixes: stale pane ids"
# =============================================================================
# two requests name the same pane id for different tasks (a tmux restart reuses ids)
mk_other() { # <stem> <pane>: a leftover request of another task naming <pane>
  mk_task "$1"
  (_wbc_lock "$1"; wbc_set test "$1" ready "saved" "task_file=$(tf "$1")" "command=/ce-code-review" "pane=$2" "session_id=other-sess" last_stop=1 last_busy=0; _wbc_unlock "$1")
}
new_case
stage_req
mk_other proj--a-leftover "$PANE"
echo pickup >"$FIX/claude-mode"
out="$(wbc_release --pane "$PANE" 2>&1)"
assert "--pane releases the request of the pane's own task" "^$STEM: released$" "$out"
refute "--pane never touches the leftover" 'leftover' "$out"
assert_eq "the leftover stays as it was" ready "$(state_of proj--a-leftover)"
wait_gone "$STEM" 15
end_case

new_case
mk_other proj--a-leftover "$PANE"
out="$(wbc_release --all 2>&1)"
refute "--all: a leftover whose pane is another session's says nothing" 'leftover|not running' "$out"
assert_eq "--all: and puts no reason on that pane" "" "$(tm show -pv -t "$PANE" @wb_continue_reason 2>/dev/null)"
out="$(wbc_release --pane "$PANE" 2>&1)"
assert "--pane: no request of this pane's task" "no saved session to continue in this pane" "$out"
out="$(wbc_release proj--a-leftover 2>&1)"
assert "naming the leftover: says the session is not running" "not released: the session is not running" "$out"
assert_eq "... and still puts no reason on the pane" "" "$(tm show -pv -t "$PANE" @wb_continue_reason 2>/dev/null)"
end_case

new_case
arm_req ""
mk_other proj--a-leftover "$PANE"
run_hook hook-session-start "$PANE" "$(payload SessionStart-clear.json brand-new-id)"
assert_eq "/clear by hand: the pane's own task's request is dropped" none "$([ -f "$(wbc_dir "$STEM")/request" ] && echo there || echo none)"
assert_eq "... the leftover of another task stays" ready "$(state_of proj--a-leftover)"
end_case

# =============================================================================
echo "# follow-ups: a drop during the restart is not logged as a restart"
# =============================================================================
new_case
stage_req
ID="$(wbc_get "$STEM" id)"
echo exit >"$FIX/claude-mode"
wbc_release "$(tf "$STEM")" >/dev/null 2>&1
for _ in $(seq 100); do tlog | /usr/bin/grep -q '^send-keys -t .* -l claude --session-id' && break; sleep 0.1; done
assert_eq "the helper typed the launch line and now waits for the pick-up" restarting "$(state_of "$STEM")"
wbc_drop "$(tf "$STEM")" >/dev/null 2>&1
wait_log "event=dropped stem=$STEM"
assert "the log says the request was dropped during the restart" "event=dropped stem=$STEM id=$ID state=gone reason=\"the request was dropped during the restart\"" "$(log_text)"
refute "... and never says restarted" 'event=restarted' "$(log_text)"
assert_eq "no pick-up marker either" no "$([ -e "$XDG_STATE_HOME/wb/continue/picked-up/$ID" ] && echo yes || echo no)"
end_case

# =============================================================================
echo "# follow-ups: a release that only waits does not mark the pane as failed"
# =============================================================================
new_case
stage_req
tm set -p -t "$PANE" @wb_continue_reason "an earlier failure"
tm set -p -t "$PANE" @claude_working 1
out="$(wbc_release "$(tf "$STEM")" 2>&1)"
assert "turn in progress: the message still says why" "not released: a turn is in progress" "$out"
assert_eq "the pane's reason is left as it was" "an earlier failure" "$(tm show -pv -t "$PANE" @wb_continue_reason)"
tm set -p -t "$PANE" @claude_working ""
tm set -p -u -t "$PANE" @wb_continue_reason
mkdir -p "$XDG_STATE_HOME/wb/needs-you"
printf 'page https://example.test/a r1\n' >"$(wb_needs_you_file "$STEM")"
out="$(wbc_release "$(tf "$STEM")" 2>&1)"
assert "a /decide surface is open: reported" "not released: a /decide surface is open" "$out"
assert_eq "... and sets no pane reason" "" "$(tm show -pv -t "$PANE" @wb_continue_reason 2>/dev/null)"
rm -rf "$XDG_STATE_HOME/wb/needs-you"
end_case

new_case
stage_req
echo 2 >"$FIX/capture-pending-after"
wbc_release "$(tf "$STEM")" >/dev/null 2>&1
wait_state "$STEM" '^ready$'
wait_log "event=helper-ready"
assert "the helper found text on the input line and went back to ready" "text or a dialog" "$(reason_of "$STEM")"
assert_eq "... without marking the pane" "" "$(tm show -pv -t "$PANE" @wb_continue_reason 2>/dev/null)"
end_case

new_case
stage_req
printf '\n### 2026-11-15 11:00 — wb-save\n\n**Done:** more\n' >>"$(tf "$STEM")"
wbc_release "$(tf "$STEM")" >/dev/null 2>&1
assert "a drift refusal does mark the pane" 'newer Handoffs entry|save entry changed' "$(tm show -pv -t "$PANE" @wb_continue_reason 2>/dev/null)"
end_case

# =============================================================================
echo "# follow-ups: a release refuses when the session kept working after the save"
# =============================================================================
# the save's own turn end brings the counter to 0; a release goes
new_case
stage_req
assert_eq "staged: the save's own turn end is still to come" -1 "$(wbc_get "$STEM" stops_since_save)"
stop_clean
assert_eq "the save's own Stop: the counter is 0" 0 "$(wbc_get "$STEM" stops_since_save)"
echo pickup >"$FIX/claude-mode"
out="$(wbc_release "$(tf "$STEM")" 2>&1)"
assert "save then release with no further turns: released" "$STEM: released" "$out"
wait_gone "$STEM" 15
assert_eq "... and picked up" 0 "$?"
end_case

# one more turn: refused, and the pane says so
new_case
stage_req
stop_clean
stop_clean
assert_eq "a second Stop: the counter is 1" 1 "$(wbc_get "$STEM" stops_since_save)"
out="$(wbc_release "$(tf "$STEM")" 2>&1)"
assert_eq "release after one more turn: exit status 1" 1 "$?"
assert "release after one more turn: refused with the save-again reason" "$STEM: refused: the session kept working after the save; save again" "$out"
assert_eq "the request is refused" refused "$(state_of "$STEM")"
assert "the reason sits on the pane for the status mark" 'kept working after the save' "$(tm show -pv -t "$PANE" @wb_continue_reason 2>/dev/null)"
refute "nothing respawned" 'respawn-pane' "$(tlog)"
wait_log "event=release-refused"
assert "log: release-refused" "event=release-refused stem=$STEM .*state=refused reason=\"the session kept working after the save; save again\"" "$(log_text)"
# saving again replaces it and a release goes
stage_req
stop_clean
echo pickup >"$FIX/claude-mode"
assert "a fresh save after the extra turn releases" "$STEM: released" "$(wbc_release "$(tf "$STEM")" 2>&1)"
wait_gone "$STEM" 15
end_case

# a failed request is checked the same way
new_case
stage_req
stop_clean
stop_clean
(_wbc_lock "$STEM"; wbc_set test "$STEM" failed "x"; _wbc_unlock "$STEM")
assert "failed (no respawn) with more turns since the save: refused" "refused: the session kept working after the save" "$(wbc_release "$(tf "$STEM")" 2>&1)"
end_case

# an armed request that waited through turn ends for background work still restarts
new_live_case
arm_req ""
ID="$(wbc_get "$STEM" id)"
assert_eq "armed: the counter starts at 0" 0 "$(wbc_get "$STEM" stops_since_save)"
BG="$(payload Stop-background-work.json "$SID" '.transcript_path = "'"$FIX"'/monitor-transcript.jsonl"')"
run_hook hook-stop "$PANE" "$BG"
run_hook hook-stop "$PANE" "$BG"
assert_eq "two turn ends waiting for background work: still armed" armed "$(state_of "$STEM")"
assert_eq "... and they were not counted" 0 "$(wbc_get "$STEM" stops_since_save)"
echo pickup >"$FIX/claude-mode"
stop_clean
wait_gone "$STEM" 15
assert_eq "the quiet Stop then restarted it" 0 "$?"
wait_log "event=restarted"
end_case

# an armed request that went ready (shadow mode) is released after its own waits, and refused after a later turn
new_case
arm_req ""
stop_clean
wait_state "$STEM" '^ready$'
assert_eq "armed then ready at its own Stop: the counter is 0" 0 "$(wbc_get "$STEM" stops_since_save)"
echo pickup >"$FIX/claude-mode"
assert "released by Jet after the waits" "$STEM: released" "$(wbc_release "$(tf "$STEM")" 2>&1)"
wait_gone "$STEM" 15
end_case
new_case
arm_req ""
stop_clean
wait_state "$STEM" '^ready$'
stop_clean
assert_eq "a turn after it went ready is counted" 1 "$(wbc_get "$STEM" stops_since_save)"
assert "... and the release refuses" "refused: the session kept working after the save" "$(wbc_release "$(tf "$STEM")" 2>&1)"
end_case

# =============================================================================
echo "# U6: pane-focus-in and pane-focus-out both stamp @wb_seen_at, and the old focus-in hook stays"
# =============================================================================
CONF="$SELF_DIR/../../../../tmux/.config/tmux/tmux.conf"
/usr/bin/grep -E '^set-hook' "$CONF" >"$FIX/hooks.conf"
tm set -g focus-events on
tm source-file "$FIX/hooks.conf"
tm source-file "$FIX/hooks.conf"
hooks="$(tm show-hooks -gw 2>/dev/null)"
assert_eq "a reload leaves one focus-out hook" 1 "$(printf '%s\n' "$hooks" | /usr/bin/grep -c '^pane-focus-out\[')"
assert_eq "a reload leaves the two focus-in hooks (acknowledge + stamp)" 2 "$(printf '%s\n' "$hooks" | /usr/bin/grep -c '^pane-focus-in\[')"
assert "the acknowledge hook is still there" 'pane-focus-in\[0\].*@claude_blocked' "$hooks"
if command -v script >/dev/null 2>&1; then
  # panes whose program asks for focus reports, as vim and Claude do (a shell pane that exits would end the test)
  FOCUSCMD="printf '\\e[?1004h'; exec sleep 600"
  tm new-session -d -s seen -x 80 -y 24 "$FOCUSCMD"
  tm split-window -t seen "$FOCUSCMD"
  PA="$(tm list-panes -t seen -F '#{pane_id}' | sed -n 1p)"
  PB="$(tm list-panes -t seen -F '#{pane_id}' | sed -n 2p)"
  tm set -p -t "$PA" @claude_session_id some-claude
  tm set -p -t "$PA" @claude_blocked 1
  tm select-pane -t "$PB"
  sleep 0.5
  # a pty client gives the hooks focus events to fire on
  timeout 15 script -qc "env TERM=xterm-256color $REAL_TMUX -L $SOCK -f /dev/null attach -t seen" /dev/null </dev/null >/dev/null 2>&1 &
  scr=$!
  sleep 1.5
  tm select-pane -t "$PA" # pane A gains focus
  sleep 1.5
  in_a="$(tm show -pv -t "$PA" @wb_seen_at 2>/dev/null)"
  assert "focus-in stamps a pane that ran Claude with an epoch" '^[0-9]{10}$' "$in_a"
  assert_eq "... and the acknowledge hook still ran (marker cleared)" "" "$(tm show -pv -t "$PA" @claude_blocked 2>/dev/null)"
  assert_eq "a pane that never ran Claude is not stamped (no fork)" "" "$(tm show -pv -t "$PB" @wb_seen_at 2>/dev/null)"
  sleep 1.2
  tm select-pane -t "$PB" # pane A loses focus
  sleep 1.5
  out_a="$(tm show -pv -t "$PA" @wb_seen_at 2>/dev/null)"
  assert "focus-out stamps it again, later than the focus-in" '^[0-9]{10}$' "$out_a"
  if [ "${out_a:-0}" -gt "${in_a:-0}" ]; then
    echo "ok   - ... the stamp moved forward ($in_a -> $out_a)"
  else
    echo "FAIL - the focus-out stamp did not move past the focus-in ($in_a -> $out_a)"
    fail=1
  fi
  kill "$scr" 2>/dev/null
  wait "$scr" 2>/dev/null
  tm kill-session -t seen 2>/dev/null
else
  echo "skip - no script(1): the live focus stamp check did not run"
fi


echo
if [ "$fail" -eq 0 ]; then echo "ALL PASSED"; else echo "FAILED"; fi
exit "$fail"
