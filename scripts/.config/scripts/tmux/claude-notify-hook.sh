#!/usr/bin/env bash
# Claude Code hook → push the agent's state onto its own tmux pane as the
# @claude_blocked option, so claude-sessions.sh, the status-left segment, and
# the jump/preview bindings can read it instantly (no content-scan, no poll lag).
#
# Wired from ~/.claude/settings.json:
#   UserPromptSubmit -> claude-notify-hook.sh start        (a turn began)
#   Notification     -> claude-notify-hook.sh needs-input  (agent is asking you)
#   Stop             -> claude-notify-hook.sh done          (turn finished)
#
# Runs inside the agent's TTY, so $TMUX_PANE is inherited and `tmux set -p`
# targets the right pane. Outside tmux every tmux call no-ops. Always exits 0 so
# a hook can never block or fail Claude.
set -uo pipefail

DONE_MIN_SECS=30   # only flag a finished turn as "done" if it ran at least this long

case "${1:-}" in
  start)        # UserPromptSubmit: clear any stale marker, stamp the start time
    tmux set -p @claude_started "$(date +%s)" 2>/dev/null || true
    tmux set -pu @claude_blocked 2>/dev/null || true
    ;;
  needs-input)  # Notification: blocked on you (permission / question / idle prompt)
    tmux set -p @claude_blocked needs-input 2>/dev/null || true
    ;;
  done)         # Stop: turn finished — only notify if it was a long-running one,
                # so trivial sub-30s turns don't light the indicator
    s="$(tmux show -pv @claude_started 2>/dev/null || true)"
    if [ -n "$s" ] && [ "$(( $(date +%s) - s ))" -ge "$DONE_MIN_SECS" ]; then
      tmux set -p @claude_blocked done 2>/dev/null || true
    fi
    ;;
esac

exit 0
