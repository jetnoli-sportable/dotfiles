#!/usr/bin/env bash
# risky-command-guard.sh — Claude Code PreToolUse hook (matcher "Bash") that
# stops agent commands able to take out the whole workbench, or that Jet has
# asked to confirm every time.
#
# Why it exists: on 2026-10-25 a subagent's throwaway fzf test wrote
#   S=-L pt$$                 # unquoted: runs "pt965618" with env S=-L
#   tmux $S kill-server       # $S empty -> kills the REAL tmux server
# and all 21 wb sessions died at once. Sibling of
# tasks-git-hooks/pretooluse-guard.sh, which covers destructive git inside
# ~/code/tasks; this one covers everything else.
#
# How it decides: the command text is split into simple commands (on ; & |
# newlines, $( and backticks), leading VAR=x assignments and env/command/
# exec/sudo/nohup/timeout prefixes are stripped, and the first word picks the
# rule. It only sees the text the agent typed, never the values variables
# expand to — that is the point: `tmux $S kill-server` is refused because no
# literal -L/-S socket flag is visible.
#
#   deny (blocked, reason fed back to the agent):
#     tmux kill-server, or kill-session -a, without a literal -L/-S socket
#     pkill/killall aimed at tmux, claude, a shell, ghostty, node, or a user
#     kill aimed at -1 (every process you own)
#     rm -r of /, ~, $HOME, ~/code, ~/code/{tasks,notes,dotfiles}, ~/.claude,
#       ~/.config
#     shutdown/reboot/poweroff/halt, systemctl poweroff|reboot|halt|suspend
#     mkfs, dd of=/dev/…
#   ask (Jet confirms):
#     other tmux kill-session/kill-window/kill-pane/kill-server on the
#       default server
#     any other kill/pkill/killall, any other rm -r
#     DROP TABLE|DATABASE|SCHEMA, TRUNCATE, bq rm
#     terraform apply|destroy, gcloud/gsutil/kubectl delete or rm
#     git push --force to development/dev/main/master
#     systemctl stop|kill|restart
#
# Fails OPEN on internal errors (missing jq, bad JSON): a broken guard must
# never block every Bash call. Kill-switch: touch the file in $KILL_SWITCH.
set -uo pipefail

KILL_SWITCH="${XDG_STATE_HOME:-$HOME/.local/state}/claude/disable-risky-command-guard"
[ -e "$KILL_SWITCH" ] && exit 0
[ -t 0 ] && exit 0

payload="$(cat)"
[ -z "$payload" ] && exit 0
command -v jq >/dev/null 2>&1 || { echo "risky-command-guard: jq not found -- failing open" >&2; exit 0; }
cmd="$(printf '%s' "$payload" | jq -r '.tool_input.command // empty' 2>/dev/null)" \
  || { echo "risky-command-guard: bad payload -- failing open" >&2; exit 0; }
[ -z "$cmd" ] && exit 0

decision=""   # "", ask, deny — deny wins
reasons=()

flag() {
  local level="$1" why="$2"
  reasons+=("$why")
  if [ "$level" = deny ] || [ -z "$decision" ]; then
    [ "$decision" = deny ] || decision="$level"
  fi
}

# Whole-text rules: SQL can sit inside a quoted -e/--query argument.
if grep -Eiq '\b(drop[[:space:]]+(table|database|schema)|truncate([[:space:]]+table)?[[:space:]]+[[:alnum:]_`"]+)' <<<"$cmd"; then
  flag ask "SQL DROP/TRUNCATE: drops are confirmed every time"
fi

# strip_prefixes WORDS... — echo the words with leading assignments and
# wrapper commands removed.
strip_prefixes() {
  local in_env=0
  while [ $# -gt 0 ]; do
    case "$1" in
      [A-Za-z_]*=*) shift ;;
      env) in_env=1; shift ;;
      command|exec|sudo|nohup|nice|time|builtin) in_env=0; shift ;;
      timeout) shift; [ $# -gt 0 ] && shift ;;
      -u|--unset) [ $in_env = 1 ] || break; shift; [ $# -gt 0 ] && shift ;;
      -*) [ $in_env = 1 ] || break; shift ;;
      *) break ;;
    esac
  done
  printf '%s\n' "$*"
}

rm_target_is_catastrophic() {
  local t="$1"
  t="${t%\"}"; t="${t#\"}"; t="${t%\'}"; t="${t#\'}"
  t="${t//\$\{HOME\}/\$HOME}"
  t="${t%/\*}"; t="${t%/}"
  case "$t" in
    ''|'~'|'$HOME'|"$HOME"|/home) return 0 ;;  # '' is what / and /* strip to
  esac
  local sub
  for sub in code code/tasks code/notes code/dotfiles .claude .config; do
    case "$t" in
      "~/$sub"|"\$HOME/$sub"|"$HOME/$sub") return 0 ;;
    esac
  done
  return 1
}

check_segment() {
  local seg="$1" w rest
  # shellcheck disable=SC2086 # word-splitting the segment is the intent
  set -f; set -- $seg; set +f
  [ $# -eq 0 ] && return
  seg="$(strip_prefixes "$@")"
  set -f; set -- $seg; set +f
  [ $# -eq 0 ] && return
  w="${1##*/}"; shift
  rest=" $* "

  case "$w" in
    tmux)
      local has_socket=0
      [[ "$rest" =~ [[:space:]]-[LS] ]] && has_socket=1
      if [[ "$rest" =~ [[:space:]]kill-server[[:space:]] ]]; then
        if [ $has_socket = 0 ]; then
          flag deny "tmux kill-server with no literal -L/-S socket would kill the real tmux server and every wb session (2026-10-25 incident). Use a fixed, quoted private socket: tmux -L \"test-\$\$\" -f /dev/null ..."
        fi
      elif [[ "$rest" =~ [[:space:]]kill-(session|window|pane)[[:space:]] ]] && [ $has_socket = 0 ]; then
        local what="${BASH_REMATCH[1]}"
        if [[ "$rest" =~ [[:space:]]kill-session[[:space:]].*-a[[:space:]] ]]; then
          flag deny "tmux kill-session -a on the default server kills every other wb session"
        else
          flag ask "tmux kill-$what on the default server targets a real session"
        fi
      fi
      ;;
    pkill|killall)
      if [[ "$rest" =~ [[:space:]](-u|--user)[[:space:]] ]] \
        || [[ "$rest" =~ (^|[[:space:]/\"\'])(tmux|claude|zsh|bash|sh|ghostty|node|systemd)([[:space:]\"\']|$) ]]; then
        flag deny "$w aimed at tmux/claude/a shell/ghostty/node/a user would take down live sessions"
      else
        flag ask "$w: process kills are confirmed every time"
      fi
      ;;
    kill)
      if [[ "$rest" =~ [[:space:]]-1[[:space:]] ]] && ! [[ "$rest" =~ [[:space:]]-1[[:space:]]+[0-9] ]]; then
        flag deny "kill -1 signals every process you own"
      else
        flag ask "kill: process kills are confirmed every time"
      fi
      ;;
    rm)
      local a recursive=0 targets=()
      for a in "$@"; do
        case "$a" in
          --recursive) recursive=1 ;;
          --*) ;;
          -*[rR]*) recursive=1 ;;
          -*) ;;
          *) targets+=("$a") ;;
        esac
      done
      if [ $recursive = 1 ]; then
        local hit=0
        for a in "${targets[@]}"; do rm_target_is_catastrophic "$a" && hit=1; done
        if [ $hit = 1 ]; then
          flag deny "rm -r of /, home, ~/code, the task/notes store, dotfiles, ~/.claude or ~/.config"
        else
          flag ask "rm -r: recursive deletes are confirmed every time"
        fi
      fi
      ;;
    shutdown|reboot|poweroff|halt) flag deny "$w would stop the machine" ;;
    systemctl)
      if [[ "$rest" =~ [[:space:]](poweroff|reboot|halt|suspend|hibernate|kexec)[[:space:]] ]]; then
        flag deny "systemctl ${BASH_REMATCH[1]} would stop the machine"
      elif [[ "$rest" =~ [[:space:]](stop|kill|restart)[[:space:]] ]]; then
        flag ask "systemctl ${BASH_REMATCH[1]} stops a running unit (wb agents run in systemd scopes)"
      fi
      ;;
    mkfs|mkfs.*) flag deny "$w formats a filesystem" ;;
    dd) [[ "$rest" =~ [[:space:]]of=/dev/ ]] && flag deny "dd of=/dev/... overwrites a device" ;;
    bq) [[ "$rest" =~ ^[[:space:]]*(-[^[:space:]]+[[:space:]]+)*rm[[:space:]] ]] && flag ask "bq rm deletes a BigQuery table or dataset" ;;
    terraform|tofu)
      [[ "$rest" =~ [[:space:]](apply|destroy)[[:space:]] ]] && flag ask "$w ${BASH_REMATCH[1]} changes real infrastructure"
      ;;
    gcloud|gsutil|kubectl)
      [[ "$rest" =~ [[:space:]](delete|rm)[[:space:]] ]] && flag ask "$w ${BASH_REMATCH[1]} deletes cloud resources"
      ;;
    git)
      if [[ "$rest" =~ [[:space:]]push[[:space:]] ]] \
        && [[ "$rest" =~ [[:space:]](-f|--force|--force-with-lease(=[^[:space:]]*)?)[[:space:]] ]] \
        && [[ "$rest" =~ [[:space:]:+](development|dev|main|master)[[:space:]] ]]; then
        flag ask "force-push to a default branch rewrites shared history"
      fi
      ;;
  esac
}

# Heredoc bodies are data (a commit message quoting `tmux $S kill-server`,
# a file being written) unless the heredoc feeds a shell, so drop the body
# lines unless a shell-like command precedes the `<<` on its opening line.
drop_data_heredocs() {
  awk '
    term != "" { if ($0 ~ "^[[:space:]]*" term "[[:space:]]*$") term = ""; else if (keep) print; next }
    {
      print
      if (match($0, /<<-?[[:space:]]*["\047]?[A-Za-z_][A-Za-z0-9_]*/)) {
        t = substr($0, RSTART, RLENGTH); sub(/^<<-?[[:space:]]*["\047]?/, "", t)
        head = substr($0, 1, RSTART - 1)
        keep = (head ~ /(^|[[:space:]|;&(])(bash|sh|zsh|dash|ssh|eval|source|tmux|xargs)([[:space:]]|$)/)
        term = t
      }
    }'
}

while IFS= read -r seg; do
  check_segment "$seg"
done < <(printf '%s\n' "$cmd" | drop_data_heredocs | sed -E 's/\$\(|`|&&|\|\||[;&|()]/\n/g')

[ -z "$decision" ] && exit 0

reason="risky-command-guard: $(printf '%s; ' "${reasons[@]}")"
reason="${reason%; }"
jq -n --arg d "$decision" --arg r "$reason" \
  '{hookSpecificOutput: {hookEventName: "PreToolUse", permissionDecision: $d, permissionDecisionReason: $r}}'
exit 0
