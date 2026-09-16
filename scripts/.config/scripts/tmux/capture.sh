#!/usr/bin/env bash
# capture.sh — open the standing weekly-capture doc directly (the file
# `/park` and `/weekly-review` both read/write: ~/code/tasks/weeks/capture.md,
# printed by `wb week path`). Surfaced as a real gap during the first-ever
# /weekly-review live run (2026-W38): the doc already existed and was
# already the intended place for a human to leave a note by hand, but
# nothing short of running `/park` or knowing the exact path pointed at it.
#
# `wb week path` also creates the doc (with its four standing sections) on
# first use, so this works even before anything has ever been captured.
#
# Invoked via `bind p new-window -c "$HOME" "capture.sh"` in tmux.conf, so
# this script runs inside the freshly created window already — same
# scratch-window pattern as ask.sh/help.sh (rename, then run the tool
# directly; the window closes when the tool exits).
set -euo pipefail

WB="${WB:-$HOME/.config/scripts/tmux/wb.sh}"
# -t "$TMUX_PANE": anchor to the pane THIS script is actually running in,
# not tmux display-message's default (the client's currently-active
# window) — those differ whenever this window isn't focused the instant
# the script runs (e.g. testing via `new-window -d`), and renaming the
# wrong window this way corrupted a live agent window's name during this
# feature's own development.
self_target="$(tmux display-message -p -t "$TMUX_PANE" '#{session_name}:#{window_index}')"
tmux rename-window -t "=$self_target" capture

capture_path="$("$WB" week path)"
exec nvim "$capture_path"
