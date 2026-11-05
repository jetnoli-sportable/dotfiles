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

reset_pane; run start; agent agent-start a1
run session-start '{"source":"compact"}'
assert_eq "SessionStart(compact) mid-turn keeps the markers" 1 "$(opt @claude_working)"
run session-start '{"source":"startup"}'
assert_eq "SessionStart(startup) clears a dead process's turn and agents" "" "$(opt @claude_working)"
assert_eq "SessionStart(startup) removes stale agent markers" "" "$(opt @claude_agent_a1)"

[ "$fail" = 0 ] && echo "ALL PASSED" || { echo "FAILED"; exit 1; }
