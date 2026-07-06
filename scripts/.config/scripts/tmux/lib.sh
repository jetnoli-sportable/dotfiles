#!/usr/bin/env bash
# Shared helpers for the tmux scripts in this directory.
# Sourced by session.sh, notes.sh and claude-sessions.sh — keeps the
# attach/switch logic (and the fd-binary quirk) in one place.

# fd ships as `fdfind` on Debian/Ubuntu. Shell aliases don't apply inside
# scripts, so resolve the real executable once.
FD_BIN="$(command -v fdfind || command -v fd || true)"

# tmux_ensure_session <name> <dir> — create a detached session if absent.
# Uses the `=` exact-name match so "03" never attaches to "03-foo".
tmux_ensure_session() {
  tmux has-session -t "=$1" 2>/dev/null || tmux new-session -d -s "$1" -c "$2"
}

# tmux_focus <name> — bring a session to the foreground.
tmux_focus() {
  if [ -n "${TMUX:-}" ]; then
    tmux switch-client -t "=$1"
  else
    tmux attach -t "=$1"
  fi
}

# tmux_attach_or_create <name> <dir> — ensure the session exists, then focus it.
tmux_attach_or_create() {
  tmux_ensure_session "$1" "$2"
  tmux_focus "$1"
}

# tmux_find_claude_pane <cwd> — print the session:window.pane target of the
# Claude Code pane running in <cwd> (first match wins), or exit 1 if none.
# Reuses the same `pane_current_command == claude` detection as the picker.
tmux_find_claude_pane() {
  local cwd="$1" cmd sess win pane path
  while IFS='|' read -r cmd sess win pane path; do
    [ "$cmd" = "claude" ] || continue
    [ "$path" = "$cwd" ] || continue
    printf '%s:%s.%s\n' "$sess" "$win" "$pane"
    return 0
  done < <(tmux list-panes -a -F \
    '#{pane_current_command}|#{session_name}|#{window_index}|#{pane_index}|#{pane_current_path}')
  return 1
}

# tmux_goto_pane <target> — focus a specific session:window.pane target.
tmux_goto_pane() {
  local target="$1" session winpane window
  session="${target%%:*}"
  winpane="${target#*:}"   # window.pane
  window="${winpane%%.*}"
  if [ -n "${TMUX:-}" ]; then
    tmux switch-client -t "$session"
    tmux select-window -t "$session:$window"
    tmux select-pane -t "$target"
  else
    tmux attach -t "$session" \; select-window -t "$session:$window" \; select-pane -t "$target"
  fi
}

# tmux_code_repos — every git repo dir under ~/code (by .git presence) plus a
# short allow-list of dirs that live outside ~/code's flat layout. Shared by
# session.sh and wb.sh so repo discovery stays in one place.
tmux_code_repos() {
  local extra=(
    "$HOME/code/notes"
    "$HOME/code/daemon"
  )
  { printf '%s\n' "${extra[@]}"
    "$FD_BIN" --type d --hidden --no-ignore-vcs \
      --exclude .terraform --exclude node_modules \
      '^\.git$' "$HOME/code" -X dirname
  } | sort -u
}

# tmux_pane_awaiting_input <target> — true if the pane is showing a modal that
# needs YOU (a permission prompt or AskUserQuestion menu) rather than sitting
# idle. Calibrated against Claude Code v2.1.179: every such modal drops the
# `-- INSERT --` input box and shows an "Esc to cancel" footer (permission
# prompts additionally say "Do you want to proceed?"). Idle and working panes
# always keep `-- INSERT --`. If a future Claude Code changes this modal UI,
# this pair of greps is the one thing to recalibrate (capture a live prompt
# with `tmux capture-pane -ep -t <target>` and compare).
tmux_pane_awaiting_input() {
  local screen
  screen="$(tmux capture-pane -ep -t "$1" 2>/dev/null | tail -n 20)"
  ! grep -q -- '-- INSERT --' <<<"$screen" \
    && grep -qE 'Esc to cancel|Do you want to (proceed|run)' <<<"$screen"
}

# tmux_claude_panes [session] — emit one row per running Claude pane, tab-separated:
#   <rank>\t<target>\t<status>\t<task>
# rank orders needs-input(0) before done/waiting(1) before working(2) before
# idle(3), so callers surface the agent that's actually blocking you first.
# Pass a session name to scope to just that session's panes (used by wb's
# per-session urgency check); omit to scan every session (claude-sessions.sh).
# See tmux_pane_awaiting_input for the "needs input" modal-detection note —
# this is the single shared home for that calibration.
tmux_claude_panes() {
  local scope="${1:-}"
  local cmd sess win pane blocked title target glyph task status rank
  while IFS='|' read -r cmd sess win pane blocked title; do
    [ "$cmd" = "claude" ] || continue
    [ -z "$scope" ] || [ "$sess" = "$scope" ] || continue
    target="$sess:$win.$pane"
    glyph="${title%% *}"          # leading token
    task="${title#* }"            # everything after it
    [ "$task" = "$title" ] && task=""   # no space => no task text
    case "$glyph" in
      ✳)               status="waiting"; rank=1 ;;   # turn finished, idle at the prompt
      ""|[A-Za-z0-9]*) status="idle";    rank=3 ;;   # plain text, no spinner
      *)               status="working"; rank=2 ;;   # a spinner glyph
    esac
    # "needs input" — BLOCKED on you, not merely idle. Two signals:
    #   (1) @claude_blocked: a marker the agent sets on its own pane before it
    #       blocks on an nvim buffer (decision-buffer skill). That block shows a
    #       spinner in the pane, so a content scan can't see it — hence the
    #       explicit marker. Its value (e.g. "nvim-buffer") is the reason why.
    #   (2) a live permission / AskUserQuestion menu (tmux_pane_awaiting_input).
    #       Such modals carry the ✳ glyph, so only ✳ ("waiting") panes are scanned.
    # A pushed marker (claude-notify-hook.sh) is ground truth and beats the glyph:
    #   "done"  -> a long turn just finished (Stop hook); awaiting you, rank 1
    #   any other non-empty value (needs-input / nvim-buffer / ...) -> blocked, rank 0
    # With hooks installed the content scan is a fallback for unmarked ✳ panes.
    if [ "$blocked" = done ]; then
      status="done"; rank=1
    elif [ -n "$blocked" ]; then
      status="needs-input"; rank=0
    elif [ "$status" = "waiting" ] && tmux_pane_awaiting_input "$target"; then
      status="needs-input"; rank=0
    fi
    [ -n "$task" ] || task="Claude Code"
    printf '%d\t%s\t%s\t%s\n' "$rank" "$target" "$status" "$task"
  done < <(tmux list-panes -a -F \
    '#{pane_current_command}|#{session_name}|#{window_index}|#{pane_index}|#{@claude_blocked}|#{pane_title}')
}
