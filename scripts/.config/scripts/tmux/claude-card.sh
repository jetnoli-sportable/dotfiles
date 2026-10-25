#!/usr/bin/env bash
# claude-card.sh — the session context card: where a Claude session stands, so
# Jet can answer it after switching in without scrolling or prompting. Shown in
# the wb picker preview and the prefix+i popup.
#
# Usage: claude-card.sh <pane-id | tmux target | session-id | task file>
#   A pane or tmux target (the picker's {7}) or a session id gives the live card;
#   a task file (the picker's {9}) gives the dormant card, built from the task's
#   newest reply file. Prints nothing when the input names no Claude session and
#   no reply history, so a caller can fall back to its own preview.
#
# Sections, in order, each left out when it has nothing:
#   state     busy | waiting | idle | quiet <age> | no Claude running | state
#             unknown, from Claude Code's session registry (~/.claude/sessions/
#             <pid>.json, counted only while its pid runs with the same start
#             time); then model, context % and cost from statusline.sh's cache
#   recap     Claude Code's latest recap (an away_summary, or /recap's output)
#             from the transcript, unless a turn started after it
#   prompt    the last prompt (first lines) and the one-line heading of the one before
#   reply     the start of the last reply
#   questions a "Needs you" section; "no open questions" for a reply in the
#             heading-per-point layout; else up to five "?" lines, "possibly open"
#   artifacts the last five across the task's reply files
#   decisions the last three titles under the task file's ## Decisions
# Every figure that can go stale carries its age. Reads local files only.
#
# Overrides (tests): REPLY_LOG_DIR, CLAUDE_SESSIONS_DIR, CLAUDE_PROJECTS_DIR,
# CLAUDE_STATUS_CACHE_DIR; width from FZF_PREVIEW_COLUMNS, then COLUMNS.
set -uo pipefail

# shellcheck source=claude-reply-log.sh
source "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/claude-reply-log.sh"   # REPLY_DIR, SESSIONS_DIR, fm_field, chain_for_task

PROJECTS_DIR="${CLAUDE_PROJECTS_DIR:-$HOME/.claude/projects}"
CACHE_DIR="${CLAUDE_STATUS_CACHE_DIR:-${XDG_CACHE_HOME:-$HOME/.cache}/claude-status}"
# widths count characters, not bytes, whatever locale the caller has
export LC_ALL=C.UTF-8
WIDTH="${FZF_PREVIEW_COLUMNS:-${COLUMNS:-80}}"
[[ "$WIDTH" =~ ^[0-9]+$ ]] && [ "$WIDTH" -ge 20 ] || WIDTH=80
QUIET_AFTER=600   # a busy session with no activity this long reads "quiet"
NOW="$(date +%s)"

B=$'\e[1m' D=$'\e[2m' R=$'\e[0m' ACC=$'\e[38;2;136;57;239m'

# age <epoch seconds> — "<1m", "12m", "3h", "2d"
age() {
  local s=$((NOW - $1))
  if   [ "$s" -lt 60 ];    then printf '<1m'
  elif [ "$s" -lt 3600 ];  then printf '%dm' $((s / 60))
  elif [ "$s" -lt 86400 ]; then printf '%dh' $((s / 3600))
  else                          printf '%dd' $((s / 86400))
  fi
}

# fit <text> — one line, cut to the card width
fit() {
  local s="${1//$'\t'/ }"
  if [ "${#s}" -gt "$WIDTH" ]; then
    s="${s:0:WIDTH-1}"
    printf '%s…\n' "${s%"${s##*[![:space:]]}"}"
  else
    printf '%s\n' "$s"
  fi
}

section() { # <label>
  local n=$((WIDTH - ${#1} - 4)) rule
  [ "$n" -gt 0 ] || n=0
  printf -v rule '%*s' "$n" ''
  printf '\n%s── %s %s%s\n' "$ACC$B" "$1" "${rule// /─}" "$R"
}

# proc_start <pid> — the process start time (field 22 of /proc/<pid>/stat)
proc_start() {
  local s
  s="$(cat "/proc/$1/stat" 2>/dev/null)" || return 1
  s="${s##*) }"
  # shellcheck disable=SC2086
  set -- $s
  printf '%s' "${20:-}"
}

# registry_entry <pane-id> <session-id> — "<sid>\t<status>\t<statusUpdatedAt ms>"
# of the newest live registry entry for that pane (or that session id).
registry_entry() {
  local -a files=("$SESSIONS_DIR"/*.json)
  [ -e "${files[0]}" ] || return 0
  local pid ps sid st at
  while IFS=$'\t' read -r pid ps sid st at; do
    [[ "$pid" =~ ^[0-9]+$ ]] && kill -0 "$pid" 2>/dev/null || continue
    [ "$(proc_start "$pid")" = "$ps" ] || continue
    printf '%s\t%s\t%s\n' "$sid" "$st" "$at"
    return 0
  done < <(jq -r --arg p "$1" --arg s "$2" '
      select(($p != "" and ((.tmux // "") | endswith("." + $p))) or ($s != "" and .sessionId == $s))
      | [(.updatedAt // 0), .pid, (.procStart // ""), .sessionId, (.status // ""), (.statusUpdatedAt // 0)] | @tsv' \
      "${files[@]}" 2>/dev/null | sort -rn | cut -f2-)
}

# recap <transcript> — "<epoch>\t<text>" of the latest recap, when no turn
# started after it. Candidate lines come from a reverse grep; jq checks them.
recap() {
  tac "$1" 2>/dev/null \
    | grep -m 24 -E '"subtype":"(away_summary|local_command)"|<command-name>/|"origin":\{' \
    | jq -rs '
        def strip: gsub("</?local-command-stdout>"; "") | sub("\\s*\\(disable recaps in /config\\)\\s*$"; "") | gsub("^\\s+|\\s+$"; "");
        def epoch: (.timestamp // "") | sub("\\.[0-9]+Z$"; "Z") | (try fromdateiso8601 catch null);
        def cmd: (.message.content | if type == "string" then (capture("<command-name>(?<c>/[^<]*)</command-name>").c // null) else null end);
        . as $e
        | first(range(0; length) as $i | $e[$i]
            | if .type == "system" and .subtype == "away_summary" then {r: .}
              elif .type == "system" and .subtype == "local_command" then
                (if (($e[$i + 1] // {}) | cmd) == "/recap" then {r: .} else empty end)
              elif .type == "user" and (.message.content | type) == "string" and (.origin | type) == "object" then {r: null}
              else empty end)
        | .r // empty | select(.content | type == "string")
        | "\(epoch // 0)\t\(.content | strip | gsub("\n+"; " "))"' 2>/dev/null
}

# last_turn <reply file> — the last turn, tagged: "T\t<heading>", "U\t<previous
# heading>", "P\t<prompt line>", "R\t<reply line>". Turns start at a "## " line
# followed by a turn anchor; the prompt is a blockquote, and the reply runs to
# a closing ### Artifacts list or the end.
last_turn() {
  awk '{ l[NR] = $0 }
    /^<!-- turn \{/ { if (NR > 1 && l[NR - 1] ~ /^## /) { p2 = p1; p1 = NR } }
    END {
      if (!p1) exit
      print "T\t" l[p1 - 1]
      if (p2) print "U\t" l[p2 - 1]
      end = NR
      for (i = NR; i > p1; i--) if (l[i] == "### Artifacts") { a = i; break }
      if (a) { for (j = a + 1; j <= NR; j++) if (l[j] != "" && l[j] !~ /^- /) a = 0 }
      if (a) end = a - 1
      mode = ""
      for (i = p1 + 1; i <= end; i++) {
        if (mode == "" && l[i] == "### Prompt") { mode = "P"; continue }
        if (mode == "P" && l[i] == "### Reply") { mode = "R"; continue }
        if (mode == "P") { s = l[i]; sub(/^> ?/, "", s); print "P\t" s }
        else if (mode == "R") print "R\t" l[i]
      }
    }' "$1" 2>/dev/null
}

# artifacts <reply file>... — "- <item>" lines from each turn's closing ### Artifacts list
artifacts() {
  # a turn's lines are buffered until the next anchor (its heading line, the
  # next turn's, is dropped first) or the end of the file
  awk 'function flush(   j, k, ok) {
         k = 0
         for (j = n; j >= 1; j--) if (l[j] == "### Artifacts") { k = j; break }
         if (k) {
           ok = 1
           for (j = k + 1; j <= n; j++) if (l[j] != "" && l[j] !~ /^- /) ok = 0
           if (ok) for (j = k + 1; j <= n; j++) if (l[j] ~ /^- /) out[++m] = l[j]
         }
         n = 0
       }
       FNR == 1 { flush() }
       /^<!-- turn \{/ { n--; flush(); next }
       { l[++n] = $0 }
       END { flush(); for (i = 1; i <= m; i++) print out[i] }' "$@" 2>/dev/null
}

# questions — from reply lines on stdin: "N\t<line>" (a Needs you section),
# "L" (heading-per-point layout, no Needs you), or "Q\t<line>" (lines ending in ?)
questions() {
  awk 'function italic(s) { return s ~ /^[*_][^*_].*[*_]$/ }
    /^ ? ? ?(```|~~~)/ { fence = !fence; prev = "x"; next }
    fence { next }
    /^#+ / {
      match($0, /^#+/); lvl = RLENGTH
      if (nl && lvl <= nl) { nl = 0; done = 1 }
      if (!done && tolower($0) ~ /needs you/) { nl = lvl; need = 1; prev = "h"; next }
      heads++; prev = "h"; next
    }
    nl { if ($0 ~ /[^[:space:]]/) print "N\t" $0; next }
    /^[[:space:]]*$/ { next }
    {
      if (prev == "h" && italic($0)) pointed++
      if (prev != "h" && !italic($0) && $0 ~ /\?[*_)`"]*[[:space:]]*$/ && q < 5) { q++; qs[q] = $0 }
      prev = "t"
    }
    END {
      if (need) exit
      if (heads >= 2 && pointed >= 2) { print "L"; exit }
      for (i = 1; i <= q; i++) print "Q\t" qs[i]
    }'
}

# decisions <task file> — the last three ### titles under ## Decisions
decisions() {
  awk '/^## / { d = ($0 == "## Decisions") ; next }
    d && /^### / { t[++n] = substr($0, 5) }
    END { for (i = (n > 3 ? n - 2 : 1); i <= n; i++) print "- " t[i] }' "$1" 2>/dev/null
}

main() {
  local arg="${1:-}" pane="" sid="" task="" mode=live
  command -v jq >/dev/null 2>&1 || return 0
  if [ -f "$arg" ]; then
    mode=dormant; task="$arg"
  else
    case "$arg" in
      %*) pane="$arg" ;;
      *:*|*.*) pane="$(tmux display-message -p -t "$arg" '#{pane_id}' 2>/dev/null)" || return 0 ;;
      *) [[ "$arg" =~ ^[A-Za-z0-9-]+$ ]] && sid="$arg" ;;
    esac
    [ -n "$pane$sid" ] || return 0
  fi

  local reg="" st="" st_at=0
  if [ "$mode" = live ]; then
    reg="$(registry_entry "$pane" "$sid")"
    if [ -n "$reg" ]; then
      IFS=$'\t' read -r sid st st_at <<<"$reg"
    elif [ -n "$pane" ]; then
      sid="$(tmux show -p -t "$pane" -v @claude_session_id 2>/dev/null || true)"
    fi
    [[ "$sid" =~ ^[A-Za-z0-9-]+$ ]] || return 0
  fi

  # the reply file: the session's own, else the newest in its task's chain
  local file="" s
  [ -n "$sid" ] && [ -f "$REPLY_DIR/$sid.md" ] && file="$REPLY_DIR/$sid.md"
  [ -n "$file" ] && [ -z "$task" ] && task="$(fm_field "$file" task)"
  if [ -z "$task" ] && [ -n "$pane" ]; then
    s="$(tmux display-message -p -t "$pane" '#S' 2>/dev/null || true)"
    [ -n "$s" ] && task="$(tmux show -t "=$s:" -v @task 2>/dev/null || true)"
  fi
  local -a chain=()
  if [ -n "$task" ] && [ -f "$task" ]; then
    mapfile -t chain < <(chain_for_task "$task")
  elif [ -n "$file" ]; then
    chain=("$file")
  fi
  [ -n "$file" ] || [ "${#chain[@]}" -eq 0 ] || file="${chain[-1]}"

  if [ "$mode" = dormant ] && [ -z "$file" ]; then
    echo "${D}no reply history for this task${R}"
    return 0
  fi

  # --- state
  local line="" transcript="" tm=0
  local -a tps=("$PROJECTS_DIR"/*/"$sid".jsonl)
  [ -n "$sid" ] && [ -f "${tps[0]}" ] && transcript="${tps[0]}" && tm="$(stat -c %Y "$transcript" 2>/dev/null || echo 0)"
  if [ "$mode" = dormant ]; then
    line="${B}dormant${R} ${D}· last turn $(age "$(stat -c %Y "$file")") ago${R}"
  else
    local at=$((st_at / 1000))
    [ "$tm" -gt "$at" ] && at="$tm"
    case "$st" in
      busy)    if [ $((NOW - at)) -ge "$QUIET_AFTER" ]; then line="${B}quiet $(age "$at")${R} ${D}(busy, no activity)${R}"
               else line="${B}busy${R} ${D}$(age "$at")${R}"; fi ;;
      waiting) line="${B}waiting on you${R} ${D}$(age "$at")${R}" ;;
      idle)    line="${B}idle${R} ${D}$(age "$at")${R}" ;;
      shell)   line="${B}no Claude running${R}" ;;
      *)       line="${B}state unknown${R}" ;;
    esac
    local c cm cp cc cts
    c="$CACHE_DIR/$sid.json"
    if [ -f "$c" ] && IFS=$'\t' read -r cm cp cc cts < <(jq -r '[(.model // ""), (.context_pct // ""), (.cost_usd // ""), (.ts // 0)] | @tsv' "$c" 2>/dev/null) \
       && [[ "$cts" =~ ^[0-9]+$ ]]; then
      line="$line ${D}·${R} ${cm:-?}"
      [ -n "$cp" ] && line="$line ${D}·${R} ${cp}% ctx"
      [ -n "$cc" ] && line="$line ${D}·${R} \$$(printf '%.2f' "$cc")"
      line="$line ${D}· as of $(age "$cts")${R}"
    fi
  fi
  printf '%s\n' "$line"
  [ -n "$task" ] && printf '%s%s%s\n' "$D" "$(fit "task: $(basename "$task" .md)")" "$R"

  # --- recap
  if [ "$mode" = live ] && [ -n "$transcript" ]; then
    local rts rtx
    if IFS=$'\t' read -r rts rtx < <(recap "$transcript") && [ -n "$rtx" ]; then
      section "Recap · $(age "$rts") ago"
      printf '%s\n' "$rtx"
    fi
  fi

  if [ -z "$file" ]; then
    printf '\n%s\n' "${D}no turns logged yet${R}"
    return 0
  fi

  # --- last exchange
  local -a P=() Rl=()
  local T="" U="" tag rest
  while IFS=$'\t' read -r tag rest; do
    case "$tag" in
      T) T="$rest" ;; U) U="$rest" ;;
      P) P+=("$rest") ;; R) Rl+=("$rest") ;;
    esac
  done < <(last_turn "$file")
  if [ -n "$T" ]; then
    local when="${T#\#\# }"; when="${when%% · *}"
    section "You asked · ${when##* }"
    local n=0 l
    for l in "${P[@]}"; do
      [[ "$l" == *[![:space:]]* ]] || continue
      [ "$n" -lt 6 ] || { echo "${D}…${R}"; break; }
      printf '%s\n' "$l"; n=$((n + 1))
    done
    [ -n "$U" ] && printf '%s%s%s\n' "$D" "$(fit "before that: ${U#* · }")" "$R"

    section "Claude replied"
    n=0
    for l in "${Rl[@]}"; do
      [[ "$l" == *[![:space:]]* ]] || continue
      [ "$n" -lt 12 ] || { echo "${D}…${R}"; break; }
      if [[ "$l" =~ ^#+\ (.*)$ ]]; then printf '%s\n' "$B${BASH_REMATCH[1]}$R"; else printf '%s\n' "$l"; fi
      n=$((n + 1))
    done

    local -a qn=() qq=()
    local layout=0
    while IFS=$'\t' read -r tag rest; do
      case "$tag" in N) qn+=("$rest") ;; Q) qq+=("$rest") ;; L) layout=1 ;; esac
    done < <(printf '%s\n' "${Rl[@]}" | questions)
    if [ "${#qn[@]}" -gt 0 ]; then
      section "Needs you"; printf '%s\n' "${qn[@]}"
    elif [ "$layout" = 1 ]; then
      section "Open questions"; echo "${D}no open questions${R}"
    elif [ "${#qq[@]}" -gt 0 ]; then
      section "Possibly open"; printf '%s\n' "${qq[@]}"
    fi
  fi

  # --- artifacts and decisions
  local -a arts=()
  mapfile -t arts < <(artifacts "${chain[@]}" | awk '{ k[NR] = $0 } END { for (i = NR; i >= 1 && c < 5; i--) if (!seen[k[i]]++) o[++c] = k[i]; for (i = c; i >= 1; i--) print o[i] }')
  if [ "${#arts[@]}" -gt 0 ]; then
    section "Artifacts"
    for l in "${arts[@]}"; do fit "$l"; done
  fi
  if [ -n "$task" ] && [ -f "$task" ]; then
    local -a dec=()
    mapfile -t dec < <(decisions "$task")
    if [ "${#dec[@]}" -gt 0 ]; then
      section "Decisions"
      for l in "${dec[@]}"; do fit "$l"; done
    fi
  fi
  return 0
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
  exit 0
fi
