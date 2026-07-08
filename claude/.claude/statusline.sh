#!/usr/bin/env bash
# Claude Code statusLine: context %, session name, model, and effort level
# at a glance, right-aligned so it sits on the same row as the built-in
# vim-mode/auto-mode/PR indicator (which renders bottom-left with no
# config hook to reposition or merge into — verified: hideVimModeIndicator
# didn't move or remove it). Reads the hook JSON payload on stdin — schema
# verified empirically, not from public docs, since fields like `effort`
# and `context_window.used_percentage` aren't documented as of 2.1.202.
#
# No literal "current subagent" field exists in this payload — subagents
# run inside the same top-level session, so there's one statusline per
# session, not per-agent. `session_name` (the wb/tmux session title) is the
# closest useful "which of my many concurrent sessions is this" signal.
#
# Right-alignment needs the terminal width. $COLUMNS is exported by Claude
# Code to this subprocess (confirmed empirically — stdin/stdout aren't a
# tty here, so `tput cols`/`stty size` can't query it directly, but
# $COLUMNS arrives pre-set regardless). Falls back to 80 if ever unset.
set -euo pipefail

payload="$(cat)"

pct=$(jq -r '.context_window.used_percentage // 0' <<<"$payload")
session=$(jq -r '.session_name // "session"' <<<"$payload")
model=$(jq -r '.model.display_name // .model.id // "?"' <<<"$payload")
effort=$(jq -r '.effort.level // empty' <<<"$payload")

# traffic-light thresholds on context — the one field worth an at-a-glance warning
if   [ "$pct" -ge 85 ]; then ctx_color=$'\e[38;2;210;15;57m'   # crit (Catppuccin red)
elif [ "$pct" -ge 60 ]; then ctx_color=$'\e[38;2;223;142;29m'  # warn (Catppuccin yellow)
else                         ctx_color=$'\e[38;2;64;160;43m'   # ok   (Catppuccin green)
fi
reset=$'\e[0m'
dim=$'\e[2m'
accent=$'\e[38;2;136;57;239m'  # Catppuccin mauve

sep="${dim} · ${reset}"
plain_sep=" · "

line="${ctx_color}${pct}%${reset} ctx${sep}${accent}${session}${reset}${sep}${model}"
plain="${pct}% ctx${plain_sep}${session}${plain_sep}${model}"
if [ -n "$effort" ]; then
  line="${line}${sep}${dim}${effort}${reset}"
  plain="${plain}${plain_sep}${effort}"
fi

cols="${COLUMNS:-80}"
pad=$(( cols - ${#plain} ))
[ "$pad" -lt 0 ] && pad=0

printf '%*s%s' "$pad" "" "$line"
