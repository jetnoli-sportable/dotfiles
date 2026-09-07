#!/usr/bin/env bash
# Regression coverage for lib.sh's tmux_claude_panes() status detection.
# The picker's "working" column comes from this function reading the pane's
# tmux title glyph; against current Claude
# Code (v2.1.241, confirmed live via repeated tmux list-panes/capture-pane
# sampling of a genuinely mid-turn pane) the title glyph is a static "✳" for
# BOTH an actively-generating turn and an idle-at-the-prompt one — the
# heuristic's own comments say it was "calibrated against Claude Code
# v2.1.179", where a busy turn instead showed a distinct braille-spinner
# glyph. On the current build the glyph case can never reach its "working"
# branch for a real agent, so every in-progress session gets misreported as
# "waiting" (displayed as "done") until claude-notify-hook.sh's Stop hook
# eventually fires. The fix adds a ground-truth @claude_working pane marker
# (set at UserPromptSubmit, cleared at Stop) that tmux_claude_panes prefers
# over the glyph whenever the glyph would otherwise report "waiting" — the
# glyph itself stays as the fallback for a pane with no hook data.
#
# Same isolated-tmux-socket + claude-stub convention as handoff-poller.test.sh
# (pane_current_command reports the kernel comm of the pane's foreground
# process, which for a `#!/usr/bin/env bash` script is "bash" — a copy of the
# real `sleep` binary renamed to `claude` genuinely execs as comm "claude").
#
# Run: bash scripts/.config/scripts/tmux/tests/lib-claude-panes.test.sh
set -uo pipefail

LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib.sh"
FIXTURE_BIN="$(mktemp -d -t lib-claude-panes-bin.XXXXXX)"
CLAUDE_STUB_DIR="$(mktemp -d -t lib-claude-panes-claude.XXXXXX)"
SOCK="lib-cp-sock-$$"
SESSION="lib-cp-test-$$"
REAL_TMUX="$(command -v tmux)"

cat > "$FIXTURE_BIN/tmux" <<EOF
#!/usr/bin/env bash
exec "$REAL_TMUX" -L "$SOCK" "\$@"
EOF
chmod +x "$FIXTURE_BIN/tmux"
PATH="$FIXTURE_BIN:$PATH"

cp "$(command -v sleep)" "$CLAUDE_STUB_DIR/claude"
chmod +x "$CLAUDE_STUB_DIR/claude"

cleanup() {
  tmux -L "$SOCK" kill-server 2>/dev/null || true
  rm -rf "$FIXTURE_BIN" "$CLAUDE_STUB_DIR"
}
trap cleanup EXIT

fail=0
assert_eq() { # <desc> <expected> <actual>
  if [ "$2" = "$3" ]; then
    echo "ok   - $1"
  else
    echo "FAIL - $1 (expected '$2', got '$3')"
    fail=1
  fi
}

# shellcheck disable=SC1090
source "$LIB"

tmux new-session -d -s "$SESSION" -c /tmp 2>/dev/null
PANE="$(tmux list-panes -t "=$SESSION" -F '#{session_name}:#{window_index}.#{pane_index}')"
sleep 2   # let the fresh window's shell settle before send-keys (see handoff-poller.test.sh)
tmux send-keys -t "$PANE" "PATH=\"$CLAUDE_STUB_DIR:\$PATH\" claude 300" Enter
sleep 2   # give tmux a beat to report the updated pane_current_command

set_title() { tmux select-pane -t "$PANE" -T "$1"; }
set_opt()   { tmux set-option -p -t "$PANE" "$1" "$2" >/dev/null; }
clear_opt() { tmux set-option -pu -t "$PANE" "$1" >/dev/null 2>&1 || true; }

row_for() { # <session> -> "rank status" (task 3, 4 unused here)
  local rank target status task
  IFS=$'\t' read -r rank target status task < <(tmux_claude_panes "$SESSION")
  printf '%s %s' "$rank" "$status"
}

# --- idle: turn already finished, no working marker -------------------------
set_title "✳ Claude Code"
clear_opt @claude_blocked
clear_opt @claude_working
assert_eq "idle-at-prompt: static ✳ glyph, no @claude_working -> waiting" \
  "1 waiting" "$(row_for "$SESSION")"

# --- in-progress turn, current Claude Code's stuck-✳ title -------------------
# This is the case that fails before the fix: the glyph alone can't tell this
# apart from "idle", because current Claude Code shows the same "✳ <task>"
# title while genuinely generating.
set_title "✳ Some Task"
clear_opt @claude_blocked
set_opt @claude_working 1
assert_eq "mid-turn: static ✳ glyph but @claude_working=1 -> working" \
  "2 working" "$(row_for "$SESSION")"

# --- needs-input still wins over the working marker --------------------------
set_title "✳ Some Task"
set_opt @claude_working 1
set_opt @claude_blocked needs-input
assert_eq "blocked marker outranks @claude_working -> needs-input" \
  "0 needs-input" "$(row_for "$SESSION")"

# --- done still wins over the working marker ---------------------------------
set_title "✳ Some Task"
set_opt @claude_working 1
set_opt @claude_blocked done
assert_eq "done marker outranks @claude_working -> done" \
  "1 done" "$(row_for "$SESSION")"

# --- modal-scan fallback still outranks @claude_working ----------------------
# tmux_pane_awaiting_input scans the pane's own screen content, not the title
# or a marker -- drive a real "Do you want to proceed?" line into the pane's
# screen buffer so this exercises the actual content-scan path, not just the
# @claude_blocked marker path the previous two cases cover. This pane's
# foreground process is the sleep-based claude stub, not a live shell, so
# sending shell source as keystrokes would never execute; a pty's canonical-
# mode echo reproduces literal bytes on screen regardless of whether the
# foreground process ever reads them, which is enough for capture-pane to
# see -- so the padding is expanded here, before send-keys, not inside the
# pane.
padding="$(printf 'pad-line-%d\r\n' $(seq 1 200))"
tmux send-keys -t "$PANE" -l -- "${padding}Do you want to proceed?"
tmux send-keys -t "$PANE" Enter
set_title "✳ Some Task"
clear_opt @claude_blocked
set_opt @claude_working 1
assert_eq "modal-scan fallback still outranks @claude_working" \
  "0 needs-input" "$(row_for "$SESSION")"

# --- glyph fallback intact for a pane with no hook data ----------------------
set_title "⠋ Some Task"
clear_opt @claude_blocked
clear_opt @claude_working
assert_eq "hookless pane: real spinner glyph still detected -> working" \
  "2 working" "$(row_for "$SESSION")"

exit $fail
