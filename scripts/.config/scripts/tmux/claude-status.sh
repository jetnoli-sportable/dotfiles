#!/usr/bin/env bash
# status-left segment: a quiet count of Claude agents that need you.
# Reads the @claude_blocked pane option that claude-notify-hook.sh pushes, so
# it's a single cheap `list-panes` — no capture-pane scan. Prints nothing when
# nothing is waiting, so the corner stays empty in the common case.
#
#   ✳N  (magenta) — N agents need input / are blocked on you
#   ✔N  (cyan)    — N long-running agents just finished and you haven't looked
#   ↻N  (yellow)  — N panes whose saved session (wb continue) was refused or
#                   failed to restart; the pane option @wb_continue_reason holds
#                   why, and the next save in that pane clears it
#
# Wired in tmux.conf:  set -g status-left '#(~/.config/scripts/tmux/claude-status.sh)'
set -uo pipefail

read -r ni dn rn < <(
  tmux list-panes -a -F '#{@claude_blocked}|#{?@wb_continue_reason,1,0}' 2>/dev/null | awk -F'|' '
    $1 == "done"             { d++ }
    $1 != "" && $1 != "done" { n++ }
    $2 == 1                  { r++ }
    END { print n+0, d+0, r+0 }'
) || { ni=0; dn=0; rn=0; }

out=""
[ "${ni:-0}" -gt 0 ] && out="#[fg=magenta,bold]✳${ni}#[default]"
[ "${dn:-0}" -gt 0 ] && out="${out:+$out }#[fg=cyan]✔${dn}#[default]"
[ "${rn:-0}" -gt 0 ] && out="${out:+$out }#[fg=yellow]↻${rn}#[default]"
[ -n "$out" ] && printf '%s ' "$out"
exit 0
