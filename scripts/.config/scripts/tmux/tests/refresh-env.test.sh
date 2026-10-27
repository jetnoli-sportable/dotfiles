#!/usr/bin/env bash
# Tests for refresh-env.sh — the login-time push of this login's display
# variables into a tmux server that outlived the last logout. Runs against a
# private tmux server (its own TMUX_TMPDIR, no config), never Jet's.
#
# Run: bash scripts/.config/scripts/tmux/tests/refresh-env.test.sh
set -uo pipefail

RE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/refresh-env.sh"
SANDBOX="$(mktemp -d -t refresh-env.XXXXXX)"
export TMUX_TMPDIR="$SANDBOX/tmux"
mkdir -p "$TMUX_TMPDIR"
unset TMUX TMUX_PANE
t() { tmux -f /dev/null "$@"; }
trap 't kill-server 2>/dev/null; rm -rf "$SANDBOX"' EXIT

fail=0
assert_eq() { # <desc> <expected> <actual>
  if [ "$2" = "$3" ]; then echo "ok   - $1"; else echo "FAIL - $1 (expected '$2', got '$3')"; fail=1; fi
}

[ -x "$RE" ] && echo "ok   - refresh-env.sh is executable (it runs under stow)" || { echo "FAIL - refresh-env.sh not executable"; fail=1; }

out="$(env -u DISPLAY XAUTHORITY=/new bash "$RE" 2>&1)"; rc=$?
assert_eq "no tmux server: exit 0" "0" "$rc"
assert_eq "no tmux server: silent" "" "$out"

# A server from the "previous login": global and per-session values are stale.
XAUTHORITY=/old DISPLAY=:9 t new-session -d -s alpha
XAUTHORITY=/old DISPLAY=:9 t new-session -d -s beta
t set-environment -g XAUTHORITY /old
t set-environment -t =alpha XAUTHORITY /old

env -u WAYLAND_DISPLAY -u SSH_AUTH_SOCK -u XDG_CURRENT_DESKTOP -u XDG_SESSION_DESKTOP -u XDG_SESSION_TYPE \
  XAUTHORITY=/new DISPLAY=:0 bash "$RE"; rc=$?
assert_eq "server running: exit 0" "0" "$rc"
assert_eq "global XAUTHORITY refreshed" "XAUTHORITY=/new" "$(t show-environment -g XAUTHORITY)"
assert_eq "global DISPLAY refreshed" "DISPLAY=:0" "$(t show-environment -g DISPLAY)"
assert_eq "session alpha XAUTHORITY refreshed" "XAUTHORITY=/new" "$(t show-environment -t =alpha XAUTHORITY)"
assert_eq "session beta XAUTHORITY refreshed" "XAUTHORITY=/new" "$(t show-environment -t =beta XAUTHORITY)"
assert_eq "a new pane in alpha inherits the refreshed key" "/new" \
  "$(t new-window -d -P -F '#{pane_id}' -t =alpha 'printf %s "$XAUTHORITY" >"'"$SANDBOX"'/pane-env"; sleep 5' >/dev/null; sleep 0.5; cat "$SANDBOX/pane-env")"

# An unset variable in the login environment is left alone rather than blanked.
t set-environment -g WAYLAND_DISPLAY wayland-old
env -u WAYLAND_DISPLAY XAUTHORITY=/new bash "$RE"
assert_eq "unset in the login env: tmux value untouched" "WAYLAND_DISPLAY=wayland-old" "$(t show-environment -g WAYLAND_DISPLAY)"

[ "$fail" -eq 0 ] && echo "ALL PASS" || { echo "SOME FAILED"; exit 1; }
