#!/usr/bin/env bash
# Claude Code hook → push the agent's state onto its own tmux pane as the
# @claude_blocked and @claude_working options, so claude-sessions.sh, the
# status-left segment, and the jump/preview bindings can read it instantly
# (no content-scan, no poll lag). @claude_working is ground truth for "a turn
# is actually running" — current Claude Code's pane-title glyph is a static
# "✳" whether a turn is generating or idle at the prompt, so
# tmux_claude_panes (lib.sh) can no longer tell those apart from the glyph
# alone.
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
    tmux set -p @claude_working 1 2>/dev/null || true
    # Record the Claude session id on the pane (hooks receive JSON on stdin
    # with a session_id field). A future `wb up --resume` needs it to
    # `claude --resume <id>` instead of cold-starting the agent — the one
    # piece of a wb session that is NOT reconstructable from the task file
    # (roadmap 9b amendment, 2026-07-06 review). Guarded so a manual,
    # stdin-less invocation can't hang on the read.
    if [ ! -t 0 ]; then
      sid=""
      if command -v jq >/dev/null 2>&1; then
        sid="$(jq -r '.session_id // empty' 2>/dev/null || true)"
      else
        sid="$(grep -o '"session_id"[[:space:]]*:[[:space:]]*"[^"]*"' 2>/dev/null \
          | head -n1 | sed 's/.*"\([^"]*\)"$/\1/')"
      fi
      [ -n "$sid" ] && { tmux set -p @claude_session_id "$sid" 2>/dev/null || true; }
    fi
    ;;
  needs-input)  # Notification: blocked on you (permission / question / idle prompt)
    tmux set -p @claude_blocked needs-input 2>/dev/null || true
    ;;
  done)         # Stop: turn finished — always clear the working marker, but
                # only light the "done" notification if it was long-running,
                # so trivial sub-30s turns don't light the indicator
    tmux set -pu @claude_working 2>/dev/null || true
    s="$(tmux show -pv @claude_started 2>/dev/null || true)"
    if [ -n "$s" ] && [ "$(( $(date +%s) - s ))" -ge "$DONE_MIN_SECS" ]; then
      tmux set -p @claude_blocked done 2>/dev/null || true
    fi
    ;;
esac

exit 0
