#!/usr/bin/env bash
# Overview of every Claude Code agent running across all tmux sessions/windows,
# with live status, and a jump-to-it picker.
#
#   claude-sessions.sh [query]   fzf picker — enter jumps to that agent's pane
#   claude-sessions.sh dash      live dashboard window (auto-refresh)
#
# Status, most-urgent first:
#   needs-input -> BLOCKED on you: a permission/question modal in the pane, or a
#                  decision-buffer nvim split it set @claude_blocked for
#   done        -> a long-running turn just finished (Stop hook), awaiting you
#   waiting     -> turn finished, idle at the ✳ prompt, no @claude_working marker
#   working     -> @claude_working=1 (a turn is actually running), or a
#                  non-✳ spinner glyph in the title on a pane with no hook data
#   idle        -> plain-text title, no spinner
# The title glyph alone can't tell "working" from "waiting" on current Claude
# Code (its title glyph is a static ✳ whether generating or idle) or tell
# "needs-input" from "waiting" (a modal also keeps the ✳ glyph) — collect_rows
# relies on lib.sh's tmux_claude_panes to refine all three, via @claude_working
# / @claude_blocked and tmux_pane_awaiting_input respectively.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SELF="$SCRIPT_DIR/$(basename "${BASH_SOURCE[0]}")"   # for fzf reload to re-invoke us
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

# Emit one tab-separated row per running Claude pane:
#   <rank>\t<target>\t<status>\t<task>
# rank orders needs-input(0) before waiting(1) before working(2) before idle(3),
# so the picker/dashboard surface the agent that's actually blocking you first.
# The detection itself (including the modal-scan calibration note) lives in
# lib.sh's tmux_claude_panes — shared with wb.sh so there's one place to
# recalibrate if a future Claude Code changes its modal UI.
collect_rows() {
  tmux_claude_panes
}

# Emit the colored picker lines: <icon> <target> <status> <task>.
# target is the leading whitespace field, so fzf's {1} / "${sel%% *}" parse it.
# Also used by the fzf `reload` binding (via `claude-sessions.sh render`).
render_rows() {
  local rows
  rows="$(collect_rows | sort -n)"
  [ -n "$rows" ] || return 0
  printf '%s\n' "$rows" | awk -F'\t' '
    BEGIN { m="\033[1;35m"; g="\033[32m"; y="\033[33m"; d="\033[90m"; cy="\033[36m"; r="\033[0m" }
    {
      if ($3 == "needs-input")  { c=m;  icon="◆"; lbl="needs you" }
      else if ($3 == "done")    { c=cy; icon="✔"; lbl="finished" }
      else if ($3 == "waiting") { c=g;  icon="○"; lbl="done" }
      else if ($3 == "working") { c=y; icon="●"; lbl="working" }
      else                      { c=d; icon="·"; lbl="idle" }
      printf "%s%-24s%s %s%-12s%s %s\n", c, $2, r, c, icon" "lbl, r, $4
    }'
}

picker() {
  local rendered selection target

  # Keys that mean "navigate" in NORMAL mode but must type normally in SEARCH
  # mode. We toggle them with unbind/rebind as the mode flips. (h/l aren't here:
  # in NORMAL mode disable-search makes every unbound printable key inert, so
  # binding h:abort / l:accept is enough — they need no toggle. x = interrupt,
  # so it's toggled too.)
  local navkeys='j,k,g,G,q,i,x,/'

  rendered="$(render_rows)"
  if [ -z "$rendered" ]; then
    echo "No Claude Code sessions running across tmux." >&2
    exit 0
  fi

  # Modal navigation (vim-style):
  #   NORMAL (default) — search disabled, so unbound keys are inert:
  #     j/k move · g/G top/bottom · ctrl-d/ctrl-u half-page · l or enter jump
  #     · h cancel · x interrupt agent · ctrl-x kill pane · ctrl-r refresh
  #     · q quit · i or / start searching
  #   SEARCH — type to filter; esc returns to NORMAL.
  #
  # Preview is a read-only snapshot of the selected agent's pane (capture-pane).
  # The list auto-refreshes every 3s via the load→reload loop, and that same
  # tick re-runs the preview (refresh-preview), so the snapshot stays live even
  # while you sit on one agent. --track keeps the cursor on the same agent
  # across refreshes instead of jumping to the top.
  selection="$(printf '%s\n' "$rendered" | fzf --ansi --query="${1:-}" --select-1 --track \
        --prompt='NORMAL ' \
        --header=$'claude sessions\nNORMAL: j/k move · g/G top/bottom · l/enter jump · x interrupt · ctrl-x kill · ctrl-r refresh · i,/ search · q quit\nSEARCH: type to filter · esc back to normal' \
        --no-sort \
        --preview "tmux capture-pane -ep -t {1}" \
        --preview-window 'right,55%,wrap,border-left' \
        --preview-label ' agent screen ' \
        --bind 'start:disable-search' \
        --bind "load:reload-sync(sleep 3; \"$SELF\" render)+refresh-preview" \
        --bind 'j:down' \
        --bind 'k:up' \
        --bind 'g:first' \
        --bind 'G:last' \
        --bind 'ctrl-d:half-page-down' \
        --bind 'ctrl-u:half-page-up' \
        --bind 'l:accept' \
        --bind 'h:abort' \
        --bind 'q:abort' \
        --bind "ctrl-r:reload-sync(\"$SELF\" render)+refresh-preview" \
        --bind 'x:execute-silent(tmux send-keys -t {1} Escape)' \
        --bind "ctrl-x:execute-silent(tmux kill-pane -t {1})+reload-sync(\"$SELF\" render)" \
        --bind "i:unbind($navkeys)+enable-search+change-prompt(SEARCH )" \
        --bind "/:clear-query+unbind($navkeys)+enable-search+change-prompt(SEARCH )" \
        --bind "esc:enable-search+clear-query+disable-search+rebind($navkeys)+change-prompt(NORMAL )")" || exit 0

  [ -n "$selection" ] || exit 0
  target="${selection%% *}"
  tmux_goto_pane "$target"
}

_dash_group() {
  local rows="$1" want="$2" heading="$3" color="${4:-\033[1m}" shown=0
  local rank target status task
  while IFS=$'\t' read -r rank target status task; do
    [ "$status" = "$want" ] || continue
    if [ "$shown" -eq 0 ]; then printf '  %b%s\033[0m\n' "$color" "$heading"; shown=1; fi
    printf '    %-24s %s\n' "$target" "$task"
  done <<< "$rows"
  [ "$shown" -eq 1 ] && printf '\n'
  return 0
}

dashboard() {
  trap 'exit 0' INT
  while true; do
    local rows
    rows="$(collect_rows | sort -n)"
    clear
    printf '  \033[1mCLAUDE SESSIONS\033[0m   %s   (refresh 2s · ctrl-c quits)\n\n' "$(date +%H:%M:%S)"
    if [ -z "$rows" ]; then
      printf '  no claude sessions running\n'
    else
      _dash_group "$rows" needs-input "⚑ NEEDS YOUR INPUT" '\033[1;35m'
      _dash_group "$rows" done        "✔ FINISHED (long turn)" '\033[1;36m'
      _dash_group "$rows" waiting     "DONE — AWAITING YOU" '\033[1;32m'
      _dash_group "$rows" working     "WORKING"
      _dash_group "$rows" idle        "IDLE"
    fi
    sleep 2
  done
}

# goto — jump straight to the most-urgent waiting agent (needs-input first, else
# a just-finished long turn). Bound to prefix+j; reuses collect_rows' ranking and
# tmux_goto_pane (lib.sh). rank<=1 means "needs-input or done", never working/idle.
goto() {
  local target
  target="$(collect_rows | sort -n | awk -F'\t' '$1 <= 1 { print $2; exit }')"
  if [ -n "$target" ]; then
    tmux_goto_pane "$target"
  else
    tmux display-message "No Claude agent waiting."
  fi
}

# preview_popup — runs INSIDE a tmux display-popup (bound to prefix+J). Shows the
# most-urgent agent's pane title + recent output so you can decide without leaving
# your work; j or Enter jumps to it, any other key just closes. Read-only — you
# answer in the pane after jumping (the chosen design: see, then decide).
preview_popup() {
  local target k
  target="$(collect_rows | sort -n | awk -F'\t' '$1 <= 1 { print $2; exit }')"
  if [ -z "$target" ]; then
    echo "No Claude agent waiting."; sleep 1; return 0
  fi
  printf '\033[1;35m%s\033[0m\n\n' "$(tmux display-message -p -t "$target" '#{pane_title}')"
  tmux capture-pane -ep -t "$target" | tail -n 30
  printf '\n\033[2m── j or ↵ = jump · any other key = close ──\033[0m'
  IFS= read -rsn1 k || true
  case "$k" in
    ''|j|J) tmux_goto_pane "$target" ;;
  esac
}

case "${1:-}" in
  dash|dashboard|-d) dashboard ;;
  render)            render_rows ;;   # internal: feeds fzf reload bindings
  goto)              goto ;;          # prefix+j: jump to the most-urgent agent
  preview-popup)     preview_popup ;; # prefix+J: preview popup (j/↵ jumps, else closes)
  *)                 picker "${1:-}" ;;
esac
