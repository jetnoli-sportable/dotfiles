#!/usr/bin/env bash
# Fuzzy-pick a git repo under ~/code and jump to (or create) its tmux session.
#   s            open the picker
#   s <query>    pre-filter; auto-selects on a single match
#
# TODO: if the selected repo contains a .tmux_session.sh, source it to lay out
# panes (editor + server + logs) instead of opening a bare shell.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

selected="$( tmux_code_repos \
               | fzf --query="${1:-}" --select-1 \
                     --preview 'git -C {} -c color.status=always status -s 2>/dev/null | head -40
                                echo
                                git -C {} log --oneline -5 2>/dev/null' )" || exit 0

selected="${selected%/}"                 # tolerate trailing slashes
[ -n "$selected" ] || exit 0             # fzf cancelled — quit cleanly

session_name="${selected##*/}"
tmux_attach_or_create "$session_name" "$selected"
