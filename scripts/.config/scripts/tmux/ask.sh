#!/usr/bin/env bash
# ask.sh — quick-question scratch window (roadmap 9f-5): a fresh Claude Code
# session in the CURRENT tmux session, for a question that doesn't need to
# outlive the window it's asked in. Deliberately separate from `/help`
# (help.sh's INDEX picker, zero-LLM by design) and from `wb`'s agent windows
# (task-scoped, persistent) — this is a one-off scratch session you can
# close whenever, mirroring wb.sh's agent-window pattern (new-window, then
# send-keys "claude") but without any task/worktree bookkeeping.
#
# Invoked via `bind q new-window "ask.sh"` in tmux.conf, so this script runs
# inside the freshly created window already — it just renames that window
# and starts Claude Code in it.
set -euo pipefail

self_target="$(tmux display-message -p '#{session_name}:#{window_index}')"

tmux rename-window -t "=$self_target" ask
tmux send-keys -t "=$self_target" "claude" Enter
