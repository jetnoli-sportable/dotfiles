#!/usr/bin/env bash
# status-right segment: how many decision drafts are waiting for review on this
# session's task. Prints nothing when none are shelved or the session has no task,
# so the bar stays quiet in the common case.
#
#   ✎N  (peach) — N shelved drafts for the task; review them with /wb-decide shelved
#
# Argument: the session's task path, i.e. tmux's expanded #{@task} (empty when the
# session has no task). The task stem is the basename without .md, exactly as
# wb-capture.sh's tmux_task derives it. The count itself comes from the store verb
# `wb-capture.sh shelved --count --task <stem>` (no tmux call, cheap enough for the
# status bar's 5 s refresh), so this script never learns where drafts live.
#
# Wired in tmux.conf (after the tpm run, prepended to the theme's status-right):
#   #(~/.config/scripts/tmux/capture-status.sh '#{@task}')
set -uo pipefail

task="${1:-}"
[ -n "$task" ] || exit 0
stem="${task##*/}"; stem="${stem%.md}"
[ -n "$stem" ] || exit 0

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
n="$(bash "$here/wb-capture.sh" shelved --count --task "$stem" 2>/dev/null)" || exit 0
[[ "$n" =~ ^[0-9]+$ ]] && [ "$n" -gt 0 ] && printf '#[fg=colour216,bold]✎%s#[default] ' "$n"
exit 0
