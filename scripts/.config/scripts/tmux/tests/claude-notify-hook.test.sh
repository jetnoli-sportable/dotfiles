#!/usr/bin/env bash
# Tests for claude-notify-hook.sh: every tmux call names the agent's own pane
# ($TMUX_PANE) with -t, because an untargeted `tmux set -p` acts on the attached
# client's focused pane; with no $TMUX_PANE the hook writes nothing.
#
# tmux is faked by a script on PATH that logs each call (no real server).
# Run: bash scripts/.config/scripts/tmux/tests/claude-notify-hook.test.sh
set -uo pipefail

SCRIPT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/claude-notify-hook.sh"
ROOT="$(mktemp -d -t claude-notify-hook.XXXXXX)"
trap 'rm -rf "$ROOT"' EXIT

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

# hook <verb> [TMUX_PANE] — run the hook with a session_id on stdin; CALLS holds the log
hook() {
  CALLS="$ROOT/calls-$1-${2:-none}"; : >"$CALLS"
  printf '{"session_id":"sid-1"}' | env -u TMUX_PANE PATH="$FAKEBIN:$PATH" TMUX=fake,1,0 \
    FAKE_TMUX_CALLS="$CALLS" ${2:+TMUX_PANE="$2"} bash "$SCRIPT" "$1"
}

for verb in start needs-input done; do
  hook "$verb" %7
  total=$(wc -l <"$CALLS")
  targeted=$(grep -c -- '-t %7 ' "$CALLS")
  [ "$total" -gt 0 ] && assert_eq "$verb: all $total tmux calls target the agent's pane" "$total" "$targeted" \
    || bad "$verb: no tmux calls made"
done
hook start %7
assert_eq "start records the session id on the agent's pane" 1 "$(grep -c -- '-t %7 @claude_session_id sid-1' "$CALLS")"

hook start
assert_eq "no TMUX_PANE: nothing written" 0 "$(wc -l <"$CALLS")"

[ "$fail" = 0 ] && echo "ALL PASSED" || { echo "FAILED"; exit 1; }
