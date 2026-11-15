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
unset TMUX TMUX_PANE CLAUDE_CODE_SESSION_ID CLAUDE_CODE_ENTRYPOINT CLAUDE_CODE_SESSION_ATTENDED WBC_TRANSCRIPT

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
    [ -z "${2:-}" ] || export WBC_TRANSCRIPT="$2"
    printf '%s' "${1-}" | wbc_arm "$(tf "$STEM")"
  ) >/dev/null 2>&1
}
stage_req() { (
  export CLAUDE_CODE_SESSION_ID="$SID" TMUX_PANE="$PANE"
  wbc_stage "$(tf "$STEM")"
) >/dev/null 2>&1; }
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
{
  tr_assistant claude-opus-5-5
  tr_user human "go"
} >"$T"
BAD="/ce-code-review \$(touch $FIX/pwned) 'x'; touch $FIX/pwned2"
arm_req "$BAD" "$T"
ID="$(wbc_get "$STEM" id)"
assert_eq "request armed (session-initiated review)" armed "$(state_of "$STEM")"
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

echo
if [ "$fail" -eq 0 ]; then echo "ALL PASSED"; else echo "FAILED"; fi
exit "$fail"
