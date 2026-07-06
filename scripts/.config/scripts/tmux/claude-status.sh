#!/usr/bin/env bash
# status-left segment: a quiet count of Claude agents that need you.
# Reads the @claude_blocked pane option that claude-notify-hook.sh pushes, so
# it's a single cheap `list-panes` — no capture-pane scan. Prints nothing when
# nothing is waiting, so the corner stays empty in the common case.
#
#   ✳N  (magenta) — N agents need input / are blocked on you
#   ✔N  (cyan)    — N long-running agents just finished and you haven't looked
#
# Wired in tmux.conf:  set -g status-left '#(~/.config/scripts/tmux/claude-status.sh)'
set -uo pipefail

read -r ni dn < <(
  tmux list-panes -a -F '#{@claude_blocked}' 2>/dev/null | awk '
    $0 == "done"            { d++ }
    $0 != "" && $0 != "done" { n++ }
    END { print n+0, d+0 }'
) || { ni=0; dn=0; }

out=""
[ "${ni:-0}" -gt 0 ] && out="#[fg=magenta,bold]✳${ni}#[default]"
[ "${dn:-0}" -gt 0 ] && out="${out:+$out }#[fg=cyan]✔${dn}#[default]"
[ -n "$out" ] && printf '%s ' "$out"
exit 0
