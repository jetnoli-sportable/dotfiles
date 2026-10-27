#!/usr/bin/env bash
# refresh-env.sh — point a tmux server that outlived the last logout (linger,
# #123) at this login's display. GNOME writes a new XAUTHORITY key at every
# login, but the server keeps the old values in its global environment and in
# each session's, so panes opened later inherit a key file that no longer
# exists and X tools fail with "Authorization required". Runs once at login
# from ~/.config/autostart/tmux-refresh-env.desktop. Shells already open keep
# their old values; open a new pane to pick these up.
set -uo pipefail

tmux has-session 2>/dev/null || exit 0

vars=(DISPLAY XAUTHORITY WAYLAND_DISPLAY XDG_CURRENT_DESKTOP XDG_SESSION_DESKTOP XDG_SESSION_TYPE SSH_AUTH_SOCK)
mapfile -t sessions < <(tmux list-sessions -F '#{session_name}')

for v in "${vars[@]}"; do
  val="${!v-}"
  [ -n "$val" ] || continue
  tmux set-environment -g "$v" "$val"
  for s in "${sessions[@]}"; do
    tmux set-environment -t "=$s" "$v" "$val"
  done
done
