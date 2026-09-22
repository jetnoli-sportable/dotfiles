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
#
# Plan usage (`5h 42% ↻1h20m · wk 18% ↻3d4h`) comes from the documented
# `rate_limits.{five_hour,seven_day}.{used_percentage,resets_at}` fields
# (percent 0-100, reset as epoch seconds). They're only sent for Pro/Max
# subscribers and only after the session's first API response, and each
# window can be absent on its own — so each part renders only when present.
set -euo pipefail

payload="$(cat)"

pct=$(jq -r '.context_window.used_percentage // 0' <<<"$payload")
session=$(jq -r '.session_name // "session"' <<<"$payload")
model=$(jq -r '.model.display_name // .model.id // "?"' <<<"$payload")
effort=$(jq -r '.effort.level // empty' <<<"$payload")
# "<pct> <resets_at>" per window, pct rounded; nothing when the window's absent
read -r h5_pct h5_reset < <(jq -r '.rate_limits.five_hour // empty
  | "\((.used_percentage // empty) + 0.5 | floor) \(.resets_at // "")"' <<<"$payload") || true
read -r wk_pct wk_reset < <(jq -r '.rate_limits.seven_day // empty
  | "\((.used_percentage // empty) + 0.5 | floor) \(.resets_at // "")"' <<<"$payload") || true

# traffic-light thresholds — context, and the plan-usage windows the same way
traffic() { # <pct 0-100>
  if   [ "$1" -ge 85 ]; then printf '\e[38;2;210;15;57m'   # crit (Catppuccin red)
  elif [ "$1" -ge 60 ]; then printf '\e[38;2;223;142;29m'  # warn (Catppuccin yellow)
  else                       printf '\e[38;2;64;160;43m'   # ok   (Catppuccin green)
  fi
}
ctx_color=$(traffic "$pct")
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

# compact countdown to an epoch-seconds reset: 3d4h / 1h20m / 20m; blank if past
until_reset() { # <epoch>
  local left=$(( $1 - $(date +%s) ))
  [ "$left" -gt 0 ] || return 0
  if   [ "$left" -ge 86400 ]; then printf '%dd%dh' $(( left / 86400 )) $(( left % 86400 / 3600 ))
  elif [ "$left" -ge 3600 ];  then printf '%dh%02dm' $(( left / 3600 )) $(( left % 3600 / 60 ))
  else                             printf '%dm' $(( left / 60 ))
  fi
}
usage_part() { # <label> <pct> <resets_at> — appends to line/plain
  [[ "$2" =~ ^[0-9]+$ ]] || return 0
  local part="$1 $2%" when=""
  [[ "$3" =~ ^[0-9]+$ ]] && when=$(until_reset "$3")
  local colored="${dim}$1${reset} $(traffic "$2")$2%${reset}"
  if [ -n "$when" ]; then
    part="$part ↻$when"
    colored="$colored ${dim}↻$when${reset}"
  fi
  line="${line}${sep}${colored}"
  plain="${plain}${plain_sep}${part}"
}
usage_part 5h "${h5_pct:-}" "${h5_reset:-}"
usage_part wk "${wk_pct:-}" "${wk_reset:-}"

cols="${COLUMNS:-80}"
pad=$(( cols - ${#plain} ))
[ "$pad" -lt 0 ] && pad=0

printf '%*s%s' "$pad" "" "$line"
