#!/usr/bin/env bash
# Open daily notes in nvim inside a single persistent `notes` tmux session.
#   N            fuzzy-pick any note
#   N .          jump straight to today's daily note
#   N <query>    fuzzy-pick, pre-filtered
#
# Each note opens in its own window (named after the file) and is reused if
# already open — so re-running never types into a focused editor, and we don't
# spawn a new tmux session per day.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

TARGET_PATH="$HOME/code/notes"
DAILY_NOTE_DIR="$TARGET_PATH/daily"
NOTE_PATH="$DAILY_NOTE_DIR/$(date +'%d-%m-%Y').md"

mkdir -p "$DAILY_NOTE_DIR"

note_file="$NOTE_PATH"
# Any argument other than "." opens the fuzzy picker over all notes.
if [[ -n "${1-}" && "$1" != "." ]]; then
  note_file="$("$FD_BIN" --type f . "$TARGET_PATH" | fzf --query="$1" --select-1)" || exit 0
  [ -n "$note_file" ] || exit 0
fi

[ -e "$note_file" ] || touch "$note_file"

note_dir="$(dirname "$note_file")"
note_name="$(basename "$note_file")"
note_name="${note_name%.*}"

SESSION="notes"
tmux_ensure_session "$SESSION" "$DAILY_NOTE_DIR"

# Reuse the note's window if it's already open; otherwise launch nvim in a fresh
# one. Never send-keys into whatever editor happens to be focused.
if tmux list-windows -t "=$SESSION" -F '#{window_name}' 2>/dev/null | grep -qxF "$note_name"; then
  tmux select-window -t "=$SESSION:$note_name"
else
  tmux new-window -t "=$SESSION" -n "$note_name" -c "$note_dir" "nvim '$note_file'"
fi

tmux_focus "$SESSION"
