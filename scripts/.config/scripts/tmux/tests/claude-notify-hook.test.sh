#!/usr/bin/env bash
# Tests for claude-notify-hook.sh: every tmux call names the agent's own pane
# ($TMUX_PANE) with -t, because an untargeted `tmux set -p` acts on the attached
# client's focused pane; with no $TMUX_PANE the hook writes nothing.
#
# The targeting checks fake tmux with a script on PATH that logs each call (no
# real server). The marker-lifecycle checks below run the hook against a real
# tmux server on its own socket (-L, -f /dev/null), never the default one.
#
# NOTIFY_HOOK overrides the script under test (e.g. an older revision, to show
# a lifecycle check failing before a fix).
# Run: bash scripts/.config/scripts/tmux/tests/claude-notify-hook.test.sh
set -uo pipefail

SCRIPT="${NOTIFY_HOOK:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/claude-notify-hook.sh}"
ROOT="$(mktemp -d -t claude-notify-hook.XXXXXX)"
REAL_TMUX="$(command -v tmux)"
SOCK="cnh-test-$$"
SOCK_FILE="${TMUX_TMPDIR:-/tmp}/tmux-$(id -u)/$SOCK"   # kill-server leaves it behind
trap '"$REAL_TMUX" -L "$SOCK" kill-server 2>/dev/null; rm -f "$SOCK_FILE"; rm -rf "$ROOT"' EXIT

FAKEBIN="$ROOT/fakebin"; mkdir -p "$FAKEBIN"
cat >"$FAKEBIN/tmux" <<'FAKE'
#!/usr/bin/env bash
echo "$*" >>"$FAKE_TMUX_CALLS"
case "$*" in *"show -pv"*) echo 1 ;; esac
exit 0
FAKE
chmod +x "$FAKEBIN/tmux"

fail=0
ok()   { echo "ok   - $1"; }
bad()  { echo "FAIL - $1${2:+ ($2)}"; fail=1; }
assert_eq()    { [ "$2" = "$3" ] && ok "$1" || bad "$1" "expected [$2], got [$3]"; }

# hook <verb> [TMUX_PANE] — run the hook with every field a verb reads on stdin; CALLS holds the log
hook() {
  CALLS="$ROOT/calls-$1-${2:-none}"; : >"$CALLS"
  printf '{"session_id":"sid-1","agent_id":"a1","source":"startup"}' | env -u TMUX_PANE PATH="$FAKEBIN:$PATH" TMUX=fake,1,0 \
    FAKE_TMUX_CALLS="$CALLS" ${2:+TMUX_PANE="$2"} bash "$SCRIPT" "$1"
}

for verb in start needs-input done agent-start agent-stop session-start; do
  hook "$verb" %7
  total=$(wc -l <"$CALLS")
  targeted=$(grep -cE -- '-t %7( |$)' "$CALLS")
  [ "$total" -gt 0 ] && assert_eq "$verb: all $total tmux calls target the agent's pane" "$total" "$targeted" \
    || bad "$verb: no tmux calls made"
done
hook start %7
assert_eq "start records the session id on the agent's pane" 1 "$(grep -c -- '-t %7 @claude_session_id sid-1' "$CALLS")"

hook start
assert_eq "no TMUX_PANE: nothing written" 0 "$(wc -l <"$CALLS")"

# --- Marker lifecycle against a real tmux server -----------------------------
# @claude_working must stay set while a turn runs OR a subagent it launched is
# alive. Subagents run in the background, so the turn's Stop fires while they
# still work; before 2026-11-05 Stop cleared the marker and the picker showed
# the pane green "done" until the agents reported back.
REALBIN="$ROOT/realbin"; mkdir -p "$REALBIN"
cat >"$REALBIN/tmux" <<SHIM
#!/usr/bin/env bash
exec "$REAL_TMUX" -L "$SOCK" -f /dev/null "\$@"
SHIM
chmod +x "$REALBIN/tmux"
"$REALBIN/tmux" new-session -d -s cnh 'sleep 600'
PANE="$("$REALBIN/tmux" list-panes -t cnh -F '#{pane_id}')"

# run <verb> [json] — the hook on PANE against the isolated server
run() {
  local json="${2:-}"; [ -n "$json" ] || json='{"session_id":"sid-1"}'
  printf '%s' "$json" | env -u TMUX_PANE PATH="$REALBIN:$PATH" \
    TMUX=fake,1,0 TMUX_PANE="$PANE" XDG_RUNTIME_DIR="$ROOT" bash "$SCRIPT" "$1"
}
agent() { run "$1" "{\"agent_id\":\"$2\",\"agent_type\":\"general-purpose\"}"; }
opt()   { "$REALBIN/tmux" show -pv -t "$PANE" "$1" 2>/dev/null; }
reset_pane() {
  local name _
  while read -r name _; do
    "$REALBIN/tmux" set -pu -t "$PANE" "$name"
  done < <("$REALBIN/tmux" show -p -t "$PANE" 2>/dev/null | grep '^@')
}
long_turn() { "$REALBIN/tmux" set -p -t "$PANE" @claude_started "$(( $(date +%s) - 120 ))"; }

reset_pane; run start
assert_eq "a running turn is working" 1 "$(opt @claude_working)"
run done
assert_eq "a finished turn with no subagents is not working" "" "$(opt @claude_working)"
assert_eq "a short turn (<30s) is not lit finished" "" "$(opt @claude_blocked)"

reset_pane; run start; agent agent-start a1; agent agent-stop a1; run done
assert_eq "a short turn that ran a subagent is not lit finished" "" "$(opt @claude_blocked)"

reset_pane; run needs-input
assert_eq "a Notification marks the pane needs-input" needs-input "$(opt @claude_blocked)"
run start
assert_eq "the next prompt clears needs-input" "" "$(opt @claude_blocked)"
long_turn; run done; run start
assert_eq "the next prompt clears finished" "" "$(opt @claude_blocked)"

reset_pane; run start; agent agent-start a1; long_turn; run done
assert_eq "turn ended while a background subagent runs: still working" 1 "$(opt @claude_working)"
assert_eq "turn ended while a background subagent runs: not lit finished" "" "$(opt @claude_blocked)"
agent agent-stop a1
assert_eq "last subagent stopped after the turn ended: not working" "" "$(opt @claude_working)"

reset_pane; run start; agent agent-start a1; agent agent-start a2; run done
agent agent-stop a1
assert_eq "one of two parallel subagents stopped: still working" 1 "$(opt @claude_working)"
agent agent-stop a2
assert_eq "both parallel subagents stopped: not working" "" "$(opt @claude_working)"
agent agent-stop a2
assert_eq "a repeated SubagentStop is harmless" "" "$(opt @claude_working)"

reset_pane; run start; agent agent-start a1; agent agent-stop a1
assert_eq "a subagent finishing mid-turn leaves the turn working" 1 "$(opt @claude_working)"
long_turn; run done
assert_eq "a long turn with no subagents left still lights finished" done "$(opt @claude_blocked)"

# A SubagentStop that never arrives (an interrupted or killed agent) must not
# pin the pane "working" for the rest of the process: a marker older than the
# hook's AGENT_TTL_SECS (2h) counts as gone. Age it by rewriting its start epoch.
reset_pane; run start; agent agent-start a1
assert_eq "an agent marker holds its start epoch" 1 \
  "$([[ "$(opt @claude_agent_a1)" =~ ^[0-9]{9,}$ ]] && echo 1)"
"$REALBIN/tmux" set -p -t "$PANE" @claude_agent_a1 "$(( $(date +%s) - 3 * 3600 ))"
long_turn; run done
assert_eq "a lost SubagentStop: stale marker no longer keeps the pane working" "" "$(opt @claude_working)"
assert_eq "a lost SubagentStop: a long turn still lights finished" done "$(opt @claude_blocked)"
assert_eq "a lost SubagentStop: the stale marker is removed" "" "$(opt @claude_agent_a1)"

reset_pane; run start; agent agent-start a1; agent agent-start a2
"$REALBIN/tmux" set -p -t "$PANE" @claude_agent_a1 "$(( $(date +%s) - 3 * 3600 ))"
run done
assert_eq "a stale marker beside a live agent: still working" 1 "$(opt @claude_working)"
assert_eq "a stale marker beside a live agent: the live marker stays" 1 "$([ -n "$(opt @claude_agent_a2)" ] && echo 1)"

reset_pane; run start; agent agent-start a1
run session-start '{"source":"compact"}'
assert_eq "SessionStart(compact) mid-turn keeps the markers" 1 "$(opt @claude_working)"
run session-start '{"source":"startup"}'
assert_eq "SessionStart(startup) clears a dead process's turn and agents" "" "$(opt @claude_working)"
assert_eq "SessionStart(startup) removes stale agent markers" "" "$(opt @claude_agent_a1)"

# Stop and SubagentStop landing together: the per-pane flock serialises them.
# Hold the lock ourselves, start both hooks so each is parked on it, then release.
# Whatever order they take it in, the last subagent is gone and the turn over, so
# @claude_working must end unset (not stuck at 1 from one hook reading the
# other's marker before it was cleared).
reset_pane; run start; agent agent-start a1
LOCKFILE="$ROOT/claude-notify-hook-${PANE#%}.lock"
(
  exec 9>>"$LOCKFILE"; flock 9
  sleep 0.7
) &
holder=$!
sleep 0.2
run done & p1=$!
agent agent-stop a1 & p2=$!
sleep 0.2
assert_eq "both hooks wait while the pane lock is held" "1" "$(opt @claude_working)"
assert_eq "Stop waits while the pane lock is held" "1" "$(opt @claude_turn)"
assert_eq "SubagentStop waits while the pane lock is held" 1 "$([ -n "$(opt @claude_agent_a1)" ] && echo 1)"
wait "$holder"; wait "$p1"; wait "$p2"
assert_eq "simultaneous Stop and SubagentStop: not stuck working" "" "$(opt @claude_working)"
assert_eq "simultaneous Stop and SubagentStop: turn marker cleared" "" "$(opt @claude_turn)"
assert_eq "simultaneous Stop and SubagentStop: agent marker cleared" "" "$(opt @claude_agent_a1)"

# SessionStart's cleanup loop must clear only its own pane. Make a second pane
# (it becomes the window's active pane, so an untargeted tmux call would hit it)
# holding live markers, then run the hook for the first pane.
PANE2="$("$REALBIN/tmux" split-window -d -P -F '#{pane_id}' -t cnh 'sleep 600')"
"$REALBIN/tmux" select-pane -t "$PANE2"
reset_pane; run start; agent agent-start a1
"$REALBIN/tmux" set -p -t "$PANE2" @claude_turn 1
"$REALBIN/tmux" set -p -t "$PANE2" @claude_agent_b1 "$(date +%s)"
"$REALBIN/tmux" set -p -t "$PANE2" @claude_working 1
run session-start '{"source":"startup"}'
assert_eq "SessionStart cleanup clears its own pane's agents" "" "$(opt @claude_agent_a1)"
assert_eq "SessionStart cleanup clears its own pane's turn" "" "$(opt @claude_turn)"
assert_eq "SessionStart cleanup leaves another pane's turn" 1 "$("$REALBIN/tmux" show -pv -t "$PANE2" @claude_turn)"
assert_eq "SessionStart cleanup leaves another pane's agent marker" 1 "$([ -n "$("$REALBIN/tmux" show -pv -t "$PANE2" @claude_agent_b1)" ] && echo 1)"
assert_eq "SessionStart cleanup leaves another pane's working flag" 1 "$("$REALBIN/tmux" show -pv -t "$PANE2" @claude_working)"

[ "$fail" = 0 ] && echo "ALL PASSED" || { echo "FAILED"; exit 1; }
