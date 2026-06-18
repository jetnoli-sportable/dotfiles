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
