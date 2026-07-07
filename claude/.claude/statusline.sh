#!/usr/bin/env bash
# Claude Code statusLine: context %, session name, model, effort level, and
# vim mode at a glance, on one line. Reads the hook JSON payload on stdin —
# schema verified empirically, not from public docs, since fields like
# `effort` and the `context_window.used_percentage` breakdown aren't
# documented anywhere as of 2.1.202.
#
# vim.mode folds the built-in vim-mode indicator in here so it can be
# turned off (hideVimModeIndicator: true) without losing the info — one
# line instead of two. The permission-mode ("auto mode on") indicator has
# no equivalent field in this payload, so it can't be replicated; it stays
# on its own, separate from this script's control entirely.
#
# No literal "current subagent" field exists in this payload either —
# subagents run inside the same top-level session, so there's one
# statusline per session, not per-agent. `session_name` (the wb/tmux
# session title) is the closest useful "which of my many concurrent
# sessions is this" signal.
set -euo pipefail

payload="$(cat)"

pct=$(jq -r '.context_window.used_percentage // 0' <<<"$payload")
session=$(jq -r '.session_name // "session"' <<<"$payload")
model=$(jq -r '.model.display_name // .model.id // "?"' <<<"$payload")
effort=$(jq -r '.effort.level // empty' <<<"$payload")
vim_mode=$(jq -r '.vim.mode // empty' <<<"$payload")

# traffic-light thresholds on context — the one field worth an at-a-glance warning
if   [ "$pct" -ge 85 ]; then ctx_color=$'\e[38;2;210;15;57m'   # crit (Catppuccin red)
elif [ "$pct" -ge 60 ]; then ctx_color=$'\e[38;2;223;142;29m'  # warn (Catppuccin yellow)
else                         ctx_color=$'\e[38;2;64;160;43m'   # ok   (Catppuccin green)
fi
reset=$'\e[0m'
dim=$'\e[2m'
accent=$'\e[38;2;136;57;239m'  # Catppuccin mauve

sep="${dim} · ${reset}"

line="${ctx_color}${pct}%${reset} ctx${sep}${accent}${session}${reset}${sep}${model}"
[ -n "$effort" ] && line="${line}${sep}${dim}${effort}${reset}"
[ -n "$vim_mode" ] && line="${line}${sep}${dim}${vim_mode}${reset}"

printf '%s' "$line"
