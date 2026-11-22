#!/usr/bin/env bash
# shellcheck disable=SC2016,SC2329 # literal tmux formats in single quotes; the EXIT trap
# Tests for the status-left count (claude-status.sh) and for the two tmux.conf
# lines `wb continue` relies on: prefix+y and the @wb_unseen segment of
# status-right. Real tmux on ONE fixed private -L socket with -f /dev/null
# behind a PATH shim (never the default socket); panes carry the options the
# hooks would set.
# Run: bash scripts/.config/scripts/tmux/tests/claude-status.test.sh
set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="${SCRIPT:-$SELF_DIR/claude-status.sh}"
CONF="$SELF_DIR/../../../../tmux/.config/tmux/tmux.conf"
FIX="$(mktemp -d -t claude-status.XXXXXX)"
SOCK="claude-status-test-sock"
REAL_TMUX="$(command -v tmux)"

export HOME="$FIX/home"
mkdir -p "$HOME" "$FIX/bin"
unset TMUX TMUX_PANE

cat >"$FIX/bin/tmux" <<EOF2
#!/usr/bin/env bash
exec "$REAL_TMUX" -u -L "$SOCK" -f /dev/null "\$@"
EOF2
chmod +x "$FIX/bin/tmux"
PATH="$FIX/bin:$PATH"
export PATH

cleanup() {
  "$REAL_TMUX" -L "$SOCK" kill-server 2>/dev/null || true
  rm -rf "${FIX:?}"
}
trap cleanup EXIT

fail=0
assert_eq() { # <desc> <expected> <actual>
  if [ "$2" = "$3" ]; then echo "ok   - $1"; else
    echo "FAIL - $1"
    echo "       expected: $2"
    echo "       got:      $3"
    fail=1
  fi
}
assert() { # <desc> <regex> <actual>
  if printf '%s' "$3" | /usr/bin/grep -qE -- "$2"; then echo "ok   - $1"; else
    echo "FAIL - $1"
    echo "       expected match: $2"
    echo "       got: $(printf '%s' "$3" | head -8)"
    fail=1
  fi
}

tm() { tmux "$@"; }
status() { bash "$SCRIPT"; }

# pane <name> <@claude_blocked> <@wb_continue_reason> — a window whose pane
# carries those options (empty means unset).
pane() {
  local p
  tm new-window -d -t keepalive -n "$1" 'sleep 600'
  p="$(tm list-panes -t "keepalive:$1" -F '#{pane_id}')"
  [ -z "$2" ] || tm set -p -t "$p" @claude_blocked "$2"
  [ -z "$3" ] || tm set -p -t "$p" @wb_continue_reason "$3"
}
clear_panes() {
  local w
  for w in $(tm list-windows -t keepalive -F '#{window_id} #{window_name}' | awk '$2 != "base" {print $1}'); do
    tm kill-window -t "$w"
  done
}

tm new-session -d -s keepalive -n base -x 120 -y 30 'sleep 600'

echo "# claude-status.sh: the counts"
assert_eq "nothing set: no output" "" "$(status)"

pane a "" ""
assert_eq "a pane with neither option stays out of every count" "" "$(status)"
clear_panes

pane a "" "the branch moved since the save"
assert_eq "a row '|1' (no blocked flag, a continue reason): only the yellow count" \
  '#[fg=yellow]↻1#[default] ' "$(status)"
clear_panes

pane a blocked ""
pane b blocked ""
pane c "done" ""
assert_eq "two blocked and one done: magenta 2 then cyan 1, no yellow" \
  '#[fg=magenta,bold]✳2#[default] #[fg=cyan]✔1#[default] ' "$(status)"
clear_panes

pane a "" "the pane's shell never appeared"
pane b "done" ""
pane c blocked "no turn end was recorded since the save"
assert_eq "rows '|1', 'done|0' and 'blocked|1': all three segments, the reason panes counted once each" \
  '#[fg=magenta,bold]✳1#[default] #[fg=cyan]✔1#[default] #[fg=yellow]↻2#[default] ' "$(status)"
clear_panes

pane a "done" "a refused save"
assert_eq "a done pane with a reason counts in both" \
  '#[fg=cyan]✔1#[default] #[fg=yellow]↻1#[default] ' "$(status)"
clear_panes

echo "# tmux.conf: prefix+y and the @wb_unseen segment"
tm source-file -q "$CONF" >/dev/null 2>&1
keys="$(tm list-keys -T prefix 2>/dev/null)"
assert "prefix+y is bound to the release of this pane's saved session" \
  'bind-key +-T prefix +y +run-shell .*wb\.sh continue release --pane [^#]*#\{pane_id\}' "$keys"
assert "the binding shows the first line of a failure as a tmux message" \
  '-T prefix +y .*tmux display-message -d 6000' "$keys"
sr=""
for _ in $(seq 50); do
  sr="$(tm show -gv status-right 2>/dev/null)"
  case "$sr" in *wb_unseen*) break ;; esac
  sleep 0.1
done
assert "status-right carries the @wb_unseen segment" '#\{\?@wb_unseen,.*●#\{@wb_unseen\} unseen' "$sr"
assert "status-left runs claude-status.sh" 'claude-status\.sh' "$(tm show -gv status-left 2>/dev/null)"
tm source-file -q "$CONF" >/dev/null 2>&1
sleep 0.5
assert_eq "sourcing the conf again leaves one @wb_unseen segment" 1 \
  "$(tm show -gv status-right | /usr/bin/grep -o '@wb_unseen,' | wc -l)"

echo
if [ "$fail" -eq 0 ]; then echo "ALL PASSED"; else echo "FAILED"; fi
exit "$fail"
