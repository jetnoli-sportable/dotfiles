#!/usr/bin/env bash
# Claude Code hook → push the agent's state onto its own tmux pane as the
# @claude_blocked and @claude_working options, so claude-sessions.sh, the
# status-left segment, and the jump/preview bindings can read it instantly
# (no content-scan, no poll lag). @claude_working is ground truth for "this
# agent is working" — current Claude Code's pane-title glyph is a static "✳"
# whether a turn is generating or idle at the prompt, so tmux_claude_panes
# (lib.sh) can no longer tell those apart from the glyph alone.
#
# "Working" means a turn is running OR a subagent it launched is still alive.
# Subagents run in the background, so the main turn ends (Stop fires) right
# after spawning them and stays idle until they report back, often minutes
# later; keyed on the turn alone, the picker showed that pane green "done"
# while its agents worked (reproduced 2026-11-05, Claude Code 2.1.318). The two
# halves are kept as separate markers and @claude_working is derived from them:
#   @claude_turn            1 while a turn runs (start .. done)
#   @claude_agent_<id>      1 per live subagent (agent-start .. agent-stop); one
#                           option per agent so parallel starts can't race a count
# Background shell commands are NOT counted: Claude Code has no hook for when
# they start or finish.
#
# Wired from ~/.claude/settings.json:
#   UserPromptSubmit -> claude-notify-hook.sh start          (a turn began)
#   Notification     -> claude-notify-hook.sh needs-input    (agent is asking you)
#   Stop             -> claude-notify-hook.sh done           (turn finished)
#   SubagentStart    -> claude-notify-hook.sh agent-start    (a subagent began)
#   SubagentStop     -> claude-notify-hook.sh agent-stop     (a subagent finished)
#   SessionStart     -> claude-notify-hook.sh session-start  (claude (re)started)
#
# Runs inside the agent's TTY, so $TMUX_PANE names the agent's own pane. Every
# call passes it with -t: without -t, tmux acts on the attached client's
# FOCUSED pane, so an agent finishing while you look at another pane would mark
# that pane instead (reproduced on tmux 3.7c, 2026-10-22). No $TMUX_PANE means
# no pane of our own, so nothing is written. Always exits 0 so a hook can never
# block or fail Claude.
set -uo pipefail

DONE_MIN_SECS=30   # only flag a finished turn as "done" if it ran at least this long

[ -n "${TMUX_PANE:-}" ] || exit 0
P="$TMUX_PANE"

# Hooks receive JSON on stdin. Guarded so a manual, stdin-less invocation
# can't hang on the read.
input=""
[ -t 0 ] || input="$(cat 2>/dev/null || true)"

# json_field <name> — a top-level string field of the hook input, or empty.
json_field() {
  if command -v jq >/dev/null 2>&1; then
    printf '%s' "$input" | jq -r --arg k "$1" '.[$k] // empty' 2>/dev/null || true
  else
    printf '%s' "$input" | grep -o "\"$1\"[[:space:]]*:[[:space:]]*\"[^\"]*\"" 2>/dev/null \
      | head -n1 | sed 's/.*"\([^"]*\)"$/\1/'
  fi
}

# agent_opt — this hook's subagent marker name, or empty when the input carries
# no usable agent_id. Ids are hex today; anything else is stripped so the name
# stays a valid tmux option.
agent_opt() {
  local id
  id="$(json_field agent_id | tr -cd 'A-Za-z0-9_-')"
  [ -n "$id" ] && printf '@claude_agent_%s' "$id"
}

agents_live() {
  tmux show -p -t "$P" 2>/dev/null | grep -q '^@claude_agent_'
}

# sync_working — set @claude_working from @claude_turn and the agent markers.
sync_working() {
  if [ -n "$(tmux show -pv -t "$P" @claude_turn 2>/dev/null || true)" ] || agents_live; then
    tmux set -p -t "$P" @claude_working 1 2>/dev/null || true
  else
    tmux set -pu -t "$P" @claude_working 2>/dev/null || true
  fi
}

# Serialise per pane: a Stop and a SubagentStop landing together could each
# read the other's marker before it was cleared and leave @claude_working stuck
# at 1. Best effort: without flock, or if the lock can't be had in 2s, run anyway.
lock="${XDG_RUNTIME_DIR:-/tmp}/claude-notify-hook-${P#%}.lock"
if command -v flock >/dev/null 2>&1 && exec 9>>"$lock" 2>/dev/null; then
  flock -w 2 9 2>/dev/null || true
fi

case "${1:-}" in
  start)        # UserPromptSubmit: clear any stale marker, stamp the start time
    tmux set -p -t "$P" @claude_started "$(date +%s)" 2>/dev/null || true
    tmux set -pu -t "$P" @claude_blocked 2>/dev/null || true
    tmux set -p -t "$P" @claude_turn 1 2>/dev/null || true
    tmux set -p -t "$P" @claude_working 1 2>/dev/null || true
    # Record the Claude session id on the pane. A future `wb up --resume`
    # needs it to `claude --resume <id>` instead of cold-starting the agent —
    # the one piece of a wb session that is NOT reconstructable from the task
    # file (roadmap 9b amendment, 2026-07-06 review).
    sid="$(json_field session_id)"
    [ -n "$sid" ] && { tmux set -p -t "$P" @claude_session_id "$sid" 2>/dev/null || true; }
    ;;
  needs-input)  # Notification: blocked on you (permission / question / idle prompt)
    tmux set -p -t "$P" @claude_blocked needs-input 2>/dev/null || true
    ;;
  done)         # Stop: turn finished. Still working while subagents run; once
                # nothing runs, light "done" only for a long-running turn, so
                # trivial sub-30s turns don't light the indicator
    tmux set -pu -t "$P" @claude_turn 2>/dev/null || true
    sync_working
    if ! agents_live; then
      s="$(tmux show -pv -t "$P" @claude_started 2>/dev/null || true)"
      if [ -n "$s" ] && [ "$(( $(date +%s) - s ))" -ge "$DONE_MIN_SECS" ]; then
        tmux set -p -t "$P" @claude_blocked done 2>/dev/null || true
      fi
    fi
    ;;
  agent-start)  # SubagentStart
    opt="$(agent_opt)"
    [ -n "$opt" ] && { tmux set -p -t "$P" "$opt" 1 2>/dev/null || true; }
    sync_working
    ;;
  agent-stop)   # SubagentStop: fires again if a finished agent is resumed and
                # stops a second time, so unsetting must stay idempotent
    opt="$(agent_opt)"
    [ -n "$opt" ] && { tmux set -pu -t "$P" "$opt" 2>/dev/null || true; }
    sync_working
    ;;
  session-start) # SessionStart: a fresh claude process in this pane (wb resume,
                 # a restart after a crash) inherits the dead one's markers. Reset
                 # them, or a dead turn or agent would show "working" forever.
                 # Not on clear/compact: those happen inside a live process, and
                 # an auto-compact runs mid-turn.
    case "$(json_field source)" in
      startup|resume)
        tmux set -pu -t "$P" @claude_turn 2>/dev/null || true
        while read -r name _; do
          case "$name" in @claude_agent_*) tmux set -pu -t "$P" "$name" 2>/dev/null || true ;; esac
        done < <(tmux show -p -t "$P" 2>/dev/null)
        sync_working
        ;;
    esac
    ;;
esac

exit 0
