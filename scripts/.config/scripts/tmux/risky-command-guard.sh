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
# How it decides: it only sees the text the agent typed, never the values
# variables expand to — that is the point: `tmux $S kill-server` is refused
# because no literal -L/-S socket flag is visible. The text is
#   1. joined at backslash-newline continuations;
#   2. stripped of heredoc bodies that are data (a file, a commit message),
#      keeping bodies whose owner is a shell or SQL client, or that are piped
#      into a shell (`cat <<EOF | bash`);
#   3. quote-processed in one pass over the whole command: quoted text handed
#      to a shell (`bash -c`, `sh -lc`, `su -c`, `eval`, `ssh host`, `watch`,
#      a `trap` handler) is lifted out and checked as commands; other quoted
#      text stays one visible argument with its separators neutralised, so
#      `rm -rf 'build'` and `pkill -f 'tmux'` are judged by what they name
#      while a commit message can never form a command; `$( )` and backticks
#      inside double quotes are still code; `# comments` are dropped;
#   4. split into simple commands (on ; & | newlines, $( and backticks);
#   5. per simple command: leading VAR=x, shell keywords (if/then/do/{/!...)
#      and wrappers with their options (env, sudo, nice, timeout N, xargs,
#      watch, exec, eval...) are stripped and the first word picks the rule.
#
#   deny (blocked, reason fed back to the agent; only the kill switch passes it):
#     tmux kill-server, or kill-session -a, without a literal -L/-S socket
#     pkill/killall aimed at tmux, claude, a shell, ghostty, node, or a user
#     kill with -1 as a target (every process you own); `kill -1 PID` is a
#       hangup to one process and only asks
#     rm -r of /, ~, $HOME, ~/code, ~/code/{tasks,notes,dotfiles}, ~/.claude,
#       ~/.config, /tmp, /tmp/tmux-* (the socket dir: every session unreachable)
#     shutdown/reboot/poweroff/halt, systemctl poweroff|reboot|halt|suspend
#     mkfs, dd of=/dev/…
#   ask (Jet confirms):
#     tmux kill-session/kill-window/kill-pane on the default server
#     any other kill/pkill/killall, any other rm -r, find -delete
#   allowed without asking: rm -r whose every target is agent scratch below
#     ~/.cleanroom/, /tmp/claude-<uid>/ or /tmp/compound-engineering-<uid>/,
#     written literally or as a variable assigned a literal path earlier in
#     the same command (never a `mktemp -d` variable; nothing is trusted
#     once the command uses source/./eval)
#     SQL DROP TABLE|DATABASE|SCHEMA, TRUNCATE TABLE (not in git/gh/echo
#       text), bq rm
#     terraform/tofu apply|destroy, gcloud/gsutil/kubectl delete or rm
#     git push --force/-f/+ref to development/dev/main/master, or with no
#       branch named
#     systemctl stop|kill|restart
#     backstop: any simple command still mentioning kill-server with no
#       literal -L/-S socket (catches forms the rules above don't parse,
#       at the price of an ask on prose that quotes it)
#   tmux kill-server WITH a literal -L/-S socket is allowed (a private server).
#
# Out of reach by design: commands inside a file run later (`bash t.sh`),
# python/node subprocess calls, and a variable used as the command word
# (`$TMUX_BIN kill-server`). It is an accident guard, not a sandbox.
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
SEP=$'\001'   # stands in for whitespace/separators inside a quoted argument

flag() {
  local level="$1" why="$2"
  reasons+=("$why")
  if [ "$level" = deny ] || [ -z "$decision" ]; then
    [ "$decision" = deny ] || decision="$level"
  fi
}

# strip_prefixes WORDS... — echo the words with leading assignments, shell
# keywords and wrapper commands (plus the wrappers' own options) removed.
strip_prefixes() {
  local w vals last
  while [ $# -gt 0 ]; do
    case "$1" in
      [A-Za-z_]*=*|if|then|else|elif|do|while|until|'!'|'{'|'}') shift; continue ;;
    esac
    w="${1##*/}"
    case "$w" in   # vals: the wrapper's short options that take a value
      env) vals=uCS ;;
      sudo|doas) vals=ugCDprtUTh ;;
      nice) vals=n ;;
      ionice) vals=cnp ;;
      timeout) vals=ks ;;
      xargs) vals=adEILnPs ;;
      watch) vals=nd ;;
      stdbuf) vals=ioe ;;
      time) vals=fo ;;
      exec) vals=a ;;
      command|nohup|builtin|setsid|eval) vals="" ;;
      *) break ;;
    esac
    shift
    while [ $# -gt 0 ]; do
      case "$1" in
        --) shift; break ;;
        --*) shift ;;
        -?*)
          last="${1: -1}"
          if [[ "$1" =~ ^-[A-Za-z]+$ ]] && [ -n "$vals" ] && [[ "$vals" == *"$last"* ]] && [ $# -ge 2 ]; then
            shift 2
          else
            shift
          fi ;;
        [A-Za-z_]*=*) if [ "$w" = env ]; then shift; else break; fi ;;
        *) break ;;
      esac
    done
    if [ "$w" = timeout ] && [ $# -gt 0 ]; then shift; fi   # the duration
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
    /tmp|/tmp/tmux-*) return 0 ;;  # the tmux socket dir: every session unreachable
  esac
  local sub
  for sub in code code/tasks code/notes code/dotfiles .claude .config; do
    case "$t" in
      "~/$sub"|"\$HOME/$sub"|"$HOME/$sub") return 0 ;;
    esac
  done
  return 1
}

# Agent scratch that is deleted all day and holds nothing of Jet's: clean-room
# copies, session scratchpads, code-review run folders. A target counts only
# when its text says so — a literal path, or a variable assigned a literal
# path earlier in the same command (see collect_assignments). A `mktemp -d`
# variable never counts: the 2026-07-10 wipe was a "scratch" variable that a
# sourced script had quietly re-pointed at ~/code.
rm_target_is_scratch() {
  local t="$1" name re
  while [[ "$t" =~ \$\{?([A-Za-z_][A-Za-z0-9_]*)\}? ]]; do
    name="${BASH_REMATCH[1]}"
    [ "$name" = HOME ] && { t="${t//"${BASH_REMATCH[0]}"/$HOME}"; continue; }
    [ -n "${scratch_vals[$name]+x}" ] && [ "${scratch_at[$name]}" -lt "$seg_idx" ] || return 1
    t="${t//"${BASH_REMATCH[0]}"/${scratch_vals[$name]}}"
  done
  t="${t//$SEP/ }"
  [[ "$t" == "~/"* ]] && t="$HOME/${t#\~/}"
  [[ "$t" == *..* || "$t" == *'$'* ]] && return 1
  case "$t" in "$HOME/.cleanroom/"*) t="/cleanroom/${t#"$HOME/.cleanroom/"}" ;; esac
  re='^(/tmp/claude-[0-9]+|/tmp/compound-engineering-[0-9]+|/cleanroom)/[^/*?[]+(/.*)?$'
  [[ "$t" =~ $re ]]
}

# NAME=value words that stand alone as a command (not `NAME=x cmd`, which only
# sets the env of cmd) and are the only way NAME is set in this command. Any
# second assignment, `for NAME`, `read`/`printf -v`, `+=`, `${NAME:=…}`, or a
# `source`/`.`/`eval` anywhere makes the value untrustworthy.
collect_assignments() {
  local i seg w name v rest="$filtered"
  declare -gA scratch_vals=() scratch_at=() scratch_bad=()
  [[ "$filtered" =~ (^|[$'\n'\;\&\|\(])[[:space:]]*(source|\.|eval)[[:space:]] ]] && return
  for i in "${!segments[@]}"; do
    seg="${segments[$i]}"
    set -f; set -- $seg; set +f
    [ $# -eq 0 ] && continue
    case "$1" in export|local|declare|typeset|readonly) shift ;; esac
    if [ "${1:-}" = for ] || [ "${1:-}" = select ]; then scratch_bad[${2:-_}]=1; continue; fi
    if [ "${1:-}" = read ] || [ "${1:-}" = mapfile ] || [ "${1:-}" = printf ]; then
      for w in "$@"; do [[ "$w" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] && scratch_bad[$w]=1; done
      continue
    fi
    local all=1
    for w in "$@"; do [[ "$w" =~ ^[A-Za-z_][A-Za-z0-9_]*\+?= ]] || all=0; done
    for w in "$@"; do
      [[ "$w" =~ ^([A-Za-z_][A-Za-z0-9_]*)(\+?)=(.*)$ ]] || break
      name="${BASH_REMATCH[1]}"
      if [ $all = 0 ] || [ -n "${BASH_REMATCH[2]}" ] || [ -n "${scratch_vals[$name]+x}" ]; then
        scratch_bad[$name]=1
      else
        v="${BASH_REMATCH[3]}"; v="${v//\$\{HOME\}/}"; v="${v//\$HOME/}"
        if [[ "$v" == *'$'* ]]; then scratch_bad[$name]=1; else scratch_vals[$name]="${BASH_REMATCH[3]}"; scratch_at[$name]=$i; fi
      fi
    done
  done
  while [[ "$rest" =~ \$\{([A-Za-z_][A-Za-z0-9_]*):?= ]]; do
    scratch_bad[${BASH_REMATCH[1]}]=1; rest="${rest/"${BASH_REMATCH[0]}"/}"
  done
  for name in "${!scratch_bad[@]}"; do unset "scratch_vals[$name]"; done
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
  rest="${rest//$SEP/ }"

  case "$w" in
    git|gh|pgh|echo|printf) ;;
    *)
      local lower="${w,,}${rest,,}"
      if [[ "$lower" =~ (^|[^[:alnum:]_])(drop[[:space:]]+(table|database|schema)|truncate[[:space:]]+table)[[:space:]] ]] \
        || [[ "$w$rest" =~ (^|[^[:alnum:]_])TRUNCATE[[:space:]]+[[:alnum:]_\`\"] ]]; then
        flag ask "SQL DROP/TRUNCATE: drops are confirmed every time"
      fi ;;
  esac

  case "$w" in
    tmux)
      local has_socket=0
      [[ "$rest" =~ [[:space:]]-[LS] ]] && has_socket=1
      if [[ "$rest" =~ [[:space:]]kill-ser[a-z]*[[:space:]] ]]; then
        if [ $has_socket = 0 ]; then
          flag deny "tmux kill-server with no literal -L/-S socket would kill the real tmux server and every wb session (2026-10-25 incident). Use a fixed, quoted private socket: tmux -L \"test-\$\$\" -f /dev/null ..."
        fi
      elif [ $has_socket = 0 ] && [[ "$rest" =~ [[:space:]](kill-session|kill-window|kill-pane|killw|killp)[[:space:]] ]]; then
        local what="${BASH_REMATCH[1]}"
        if [[ "$rest" =~ [[:space:]]kill-session[[:space:]](.*[[:space:]])?-[A-Za-z]*a[A-Za-z]*[[:space:]] ]]; then
          flag deny "tmux kill-session -a on the default server kills every other wb session"
        else
          flag ask "tmux $what on the default server targets a real session"
        fi
      fi
      ;;
    pkill|killall)
      if [[ "$rest" =~ [[:space:]](-u|--user)[[:space:]] ]] \
        || [[ "$rest" =~ (^|[[:space:]/])(tmux|claude|zsh|bash|sh|ghostty|node|systemd)([[:space:]]|$) ]]; then
        flag deny "$w aimed at tmux/claude/a shell/ghostty/node/a user would take down live sessions"
      else
        flag ask "$w: process kills are confirmed every time"
      fi
      ;;
    kill)
      # skip the signal spec so only targets are judged: `kill -1 PID` is SIGHUP
      local args=("$@") i=0 t hit=0
      case "${args[0]:-}" in
        -l|-L|--list|--table) return ;;
        -s|-n|--signal) i=2 ;;
        --) i=0 ;;
        -*) i=1 ;;
      esac
      [ "${args[$i]:-}" = "--" ] && i=$((i + 1))
      for t in "${args[@]:$i}"; do [ "$t" = -1 ] && hit=1; done
      if [ $hit = 1 ]; then
        flag deny "kill with target -1 signals every process you own"
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
        local hit=0 scratch=1
        for a in "${targets[@]}"; do
          rm_target_is_catastrophic "$a" && hit=1
          rm_target_is_scratch "$a" || scratch=0
        done
        [ ${#targets[@]} -eq 0 ] && scratch=0
        if [ $hit = 1 ]; then
          flag deny "rm -r of /, home, ~/code, the task/notes store, dotfiles, ~/.claude, ~/.config, /tmp or the tmux socket dir"
        elif [ $scratch = 1 ]; then
          :
        else
          flag ask "rm -r: recursive deletes are confirmed every time"
        fi
      fi
      ;;
    find)
      [[ "$rest" =~ [[:space:]]-delete[[:space:]] ]] && flag ask "find -delete: recursive deletes are confirmed every time"
      local a on=0 sub=()
      for a in "$@"; do
        if [ $on = 1 ]; then
          case "$a" in
            ';'|'\;'|'\'|'+') on=0; [ ${#sub[@]} -gt 0 ] && check_segment "${sub[*]}"; sub=() ;;
            *) sub+=("$a") ;;
          esac
        else
          case "$a" in -exec|-execdir|-ok|-okdir) on=1 ;; esac
        fi
      done
      [ ${#sub[@]} -gt 0 ] && check_segment "${sub[*]}"
      ;;
    ssh)
      # an unquoted remote command: skip ssh's options and the host
      while [ $# -gt 0 ]; do
        case "$1" in
          -[bcDEeFIiJLlmOopQRSWw]) if [ $# -ge 2 ]; then shift 2; else shift; fi ;;
          -*) shift ;;
          *) shift; break ;;
        esac
      done
      [ $# -gt 0 ] && check_segment "$*"
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
      local a r push=0 force=0 hitdef=0 after=()
      for a in "$@"; do
        if [ $push = 0 ]; then [ "$a" = push ] && push=1; continue; fi
        case "$a" in
          --force|--force=*|--force-with-lease|--force-with-lease=*) force=1 ;;
          --*) ;;
          -*) [[ "$a" =~ ^-[A-Za-z]*f ]] && force=1 ;;
          *) after+=("$a") ;;
        esac
      done
      if [ $push = 1 ]; then
        for r in "${after[@]:1}"; do
          [[ "$r" == +* ]] && force=1
          r="${r#+}"; r="${r##*:}"; r="${r#refs/heads/}"
          case "$r" in development|dev|main|master) hitdef=1 ;; esac
        done
        if [ $force = 1 ] && [ $hitdef = 1 ]; then
          flag ask "force-push to a default branch rewrites shared history"
        elif [ $force = 1 ] && [ ${#after[@]} -lt 2 ]; then
          flag ask "force-push with no branch named pushes the current branch, which may be a default branch"
        fi
      fi
      ;;
  esac
}

# Heredoc bodies are data (a commit message quoting `tmux $S kill-server`,
# a file being written) unless they feed a shell or SQL client, so drop the
# body lines unless the command owning the `<<` is one, or the opening line
# pipes into a shell. `<<<` (a herestring) is not a heredoc.
drop_data_heredocs() {
  awk '
    term != "" { if ($0 ~ "^[[:space:]]*" term "[[:space:]]*$") term = ""; else if (keep) print; next }
    {
      print
      if (match($0, /(^|[^<])<<-?[[:space:]]*["\047]?[A-Za-z_][A-Za-z0-9_]*/)) {
        m = substr($0, RSTART, RLENGTH); p = index(m, "<<")
        t = substr(m, p); sub(/^<<-?[[:space:]]*["\047]?/, "", t)
        head = substr($0, 1, RSTART + p - 2); tail = substr($0, RSTART + RLENGTH)
        # judge only the simple command that owns the heredoc, by its first word
        seg = head; gsub(/.*[;&|(]/, "", seg); sub(/^[[:space:]]+/, "", seg)
        while (seg ~ /^[A-Za-z_][A-Za-z0-9_]*=[^[:space:]]*[[:space:]]+/) sub(/^[A-Za-z_][A-Za-z0-9_]*=[^[:space:]]*[[:space:]]+/, "", seg)
        nw = split(seg, wds, /[[:space:]]+/); k = 1
        while (k < nw && wds[k] ~ /^(sudo|env|command|exec|nohup|time)$/) k++
        w = wds[k]; sub(/.*\//, "", w)
        keep = (w ~ /^(bash|sh|zsh|dash|ksh|ssh|eval|source|psql|mysql|sqlite3|bq|duckdb)$/) \
          || (tail ~ /\|[[:space:]]*((sudo|env|command|exec)[[:space:]]+)*([^[:space:]|]*\/)?(bash|sh|zsh|dash|ksh|ssh)([[:space:]]|$)/)
        term = t
      }
    }'
}

# One pass over the whole command (quotes may span lines). Quoted text handed
# to a shell is lifted onto its own `;`-delimited segment with inner quotes
# dropped; other quoted text is kept as one argument, its whitespace and
# separators turned into $SEP. `$( )` and backticks in double quotes stay
# code. Unquoted `# comments` are dropped.
process_quotes() {
  awk -v RS='\001' -v ORS='' '
    function data(c) { return (c ~ /[[:space:];&|()`<>]/) ? "\001" : c }
    function lifts(cur) {
      return cur ~ /(^|[[:space:]\/])(bash|sh|zsh|dash|ksh|su)([[:space:]]+[^[:space:]]+)*[[:space:]]+-[A-Za-z]*c[A-Za-z]*[[:space:]]*$/ \
        || cur ~ /(^|[[:space:]])eval[[:space:]]/ || cur ~ /(^|[[:space:]\/])(ssh|watch)[[:space:]]/ \
        || cur ~ /(^|[[:space:]])trap[[:space:]]+(--[[:space:]]+)?$/
    }
    {
      s = $0; n = length(s); out = ""; st = 0   # 0 code, 1/2 single/double data, 3/4 single/double lifted
      for (i = 1; i <= n; i++) {
        c = substr(s, i, 1)
        if (st == 1) { if (c == "\047") st = 0; else out = out data(c); continue }
        if (st == 2) {
          if (c == "\\" && i < n) { i++; out = out data(substr(s, i, 1)); continue }
          if (c == "\"") { st = 0; continue }
          if (c == "$" && substr(s, i + 1, 1) == "(") {
            out = out ";"; depth = 1
            for (i += 2; i <= n; i++) { d = substr(s, i, 1); if (d == "(") depth++; else if (d == ")" && --depth == 0) break; out = out d }
            out = out ";"; continue
          }
          if (c == "`") { j = index(substr(s, i + 1), "`"); if (j == 0) j = n - i + 1; out = out ";" substr(s, i + 1, j - 1) ";"; i += j; continue }
          out = out data(c); continue
        }
        if (st == 3 && c == "\047") { out = out ";"; st = 0; continue }
        if (st == 4 && c == "\\" && substr(s, i + 1, 1) == "\"") { i++; continue }
        if (st == 4 && c == "\"") { out = out ";"; st = 0; continue }
        if (st != 0 && (c == "\047" || c == "\"")) continue
        if (c == "\\" && i < n) { out = out c substr(s, i + 1, 1); i++; continue }
        if (st == 0 && c == "#" && (i == 1 || substr(s, i - 1, 1) ~ /[[:space:];&|(]/)) {
          j = index(substr(s, i), "\n"); if (j == 0) break; i += j - 2; continue
        }
        if (st == 0 && (c == "\047" || c == "\"")) {
          cur = out; sub(/.*[;&|(\n]/, "", cur)
          if (lifts(cur)) { out = out ";"; st = (c == "\047") ? 3 : 4 } else st = (c == "\047") ? 1 : 2
          continue
        }
        out = out c
      }
      print out
    }'
}

cmd="${cmd//$'\\\n'/ }"
filtered="$(printf '%s\n' "$cmd" | drop_data_heredocs | process_quotes)"

mapfile -t segments < <(printf '%s\n' "$filtered" | sed -E 's/\$\(|`|&&|\|\||[;&|()]/\n/g')
collect_assignments

backstop=0
for seg_idx in "${!segments[@]}"; do
  seg="${segments[$seg_idx]}"
  check_segment "$seg"
  seg=" ${seg//$SEP/ } "
  if [[ "$seg" =~ [^[:alnum:]_-]kill-server[^[:alnum:]_-] ]] && ! [[ "$seg" =~ [[:space:]]-[LS] ]]; then
    backstop=1
  fi
done

if [ $backstop = 1 ] && [ "$decision" != deny ]; then
  flag ask "mentions tmux kill-server with no literal -L/-S socket in the same command; if it runs, it kills every wb session"
fi

[ -z "$decision" ] && exit 0

reason="risky-command-guard: $(printf '%s; ' "${reasons[@]}")"
reason="${reason%; }"
jq -n --arg d "$decision" --arg r "$reason" \
  '{hookSpecificOutput: {hookEventName: "PreToolUse", permissionDecision: $d, permissionDecisionReason: $r}}'
exit 0
