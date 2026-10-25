#!/usr/bin/env bash
# claude-reply-log.sh — Claude reply log: a Stop hook writes each session's turns (Jet's prompt, Claude's reply text, the turn's artifacts) to ~/.claude/replies/<session-id>.md.
#
# Verbs:
#   hook-stop   (Stop hook, registered by the reply-log plugin's hooks.json) reads
#               the hook payload on stdin and reconciles the session's reply file
#               with its transcript. Always exits 0 and prints nothing.
#   hook-session-end
#               (SessionEnd hook: /clear or exit) the same reconcile, run once more
#               on the cursor's turn once the transcript is complete, so a session's
#               final turn gets its middle text and artifacts. Never creates a file.
#   chain <reply-file|session-id> | chain --pane <pane-id>
#               print the reply files to show for that session, oldest first, one
#               path per line: every reply file whose frontmatter `task:` matches
#               (the sessions of one wb task across /clear) plus the ids in that
#               task file's `claude_sessions:`. An empty `task:` chains to itself
#               alone. --pane resolves the pane's live session first (see
#               pane_session); when that session has no reply file yet (just
#               after /clear) it chains the pane's tmux session `@task` instead.
#               Prints nothing when neither gives a reply file.
#   view [pane-id]
#               the prefix+v binding: focus the pane's open reply viewer, or split
#               the pane and open one (nvim, claude-tmux.replies follows `chain
#               --pane`), or show a tmux message when no Claude session runs there.
#
# Reply file layout (one per Claude session id; never in a repo or the task store):
#   ---
#   session_id / task / cwd / branch / created     (frontmatter, written once)
#   ---
#   # <task stem or cwd basename> · <start time>
#   ## <YYYY-MM-DD HH:MM> · <first ~60 chars of the prompt>[ (interrupted)]
#   <!-- turn {"prompt_id":…,"session_id":…,"ts":…} -->
#   ### Prompt    (Jet's full prompt as a blockquote; prompts typed mid-turn too)
#   ### Reply     (every assistant text block, headings pushed down two levels)
#   ### Artifacts (published claude.ai URLs, written/edited files; omitted when none)
#
# Why reconcile instead of append: when Stop fires, the transcript usually lacks
# the turn's last entries (U1 probe: often all of them), so the final text comes
# from the payload's last_assistant_message and the rest is filled in at the next
# Stop. A cursor beside the reply file (.<sid>.cursor: turn id, byte offset of
# that turn's heading in the reply file, byte offset of its first entry in the
# transcript) marks the last turn written; each Stop cuts the reply file there
# and re-renders from that turn on. A turn that never got a Stop (Esc) has no
# `stop_hook_summary` entry and is marked (interrupted) once a later turn lands.
# The first Stop for a session renders only its current turn: no backfill.
#
# Guards (each a silent exit 0): kill switch <dir>/.disabled, WB_CAPTURE_SWEEP
# (the wb-capture sweep's headless child), a headless `claude -p` run, no jq, no
# readable transcript, a session id outside [A-Za-z0-9-]. Files are 0600 under a
# 0700 dir. REPLY_LOG_DIR overrides ~/.claude/replies (tests, sandbox);
# REPLY_LOG_LOCK_WAIT overrides the 4 s per-session lock wait (tests).
set -uo pipefail

REPLY_DIR="${REPLY_LOG_DIR:-$HOME/.claude/replies}"
SESSIONS_DIR="${CLAUDE_SESSIONS_DIR:-$HOME/.claude/sessions}"
# How far before the current prompt the first Stop starts reading, so a batch of
# prompts answered together (back-to-back peer messages) is seen whole.
FIRST_STOP_WINDOW=65536

quiet_exit() { exit 0; }

INPUT=""
WORK=""
read_input() { [ -t 0 ] || INPUT="$(cat 2>/dev/null || true)"; }
jq_in() { printf '%s' "$INPUT" | jq -r "$1" 2>/dev/null || true; }

# Artifact extraction shared by the main transcript and subagent transcripts:
# given tool_use blocks [{id,name,input}] and results {id: {err,text}}, the
# turn's artifacts as [{k (dedupe key), s (list line)}], in order of first use.
JQ_ARTS='
def arts($tools; $res):
  [ $tools[] | . as $t | ($res[$t.id] // null) as $r
    | select($r != null and ($r.err | not))
    | if ($t.name == "Write" or $t.name == "Edit" or $t.name == "MultiEdit" or $t.name == "NotebookEdit") then
        ($t.input.file_path // $t.input.notebook_path // empty) as $p
        | {k: $p, s: ((if $t.name == "Write" then "wrote: " else "edited: " end) + $p)}
      elif $t.name == "Artifact" and (($t.input.action // "publish") == "publish") and ($r.text | startswith("Published")) then
        ($r.text | capture("(?<u>https://claude\\.ai/(code/)?artifact/[A-Za-z0-9_-]+)").u // empty) as $u
        | {k: $u, s: $u}
      else empty end ];
def restext: if type == "string" then . elif type == "array" then (map(.text? // empty) | join("\n")) else "" end;
# tools/results of a list of transcript entries
def toolsof: [ .[] | select(.type == "assistant") | .message.content[]? | select(.type == "tool_use") | {id, name, input} ];
def resof: reduce (.[] | select(.type == "user" and (.message.content | type) == "array") | .message.content[] | select(.type == "tool_result"))
    as $b ({}; .[$b.tool_use_id] = {err: ($b.is_error // false), text: ($b.content | restext)});
'

# Groups transcript entries into turns and renders them. Input: raw transcript
# lines. Output (-j): a META record, then one record per rendered turn, each
# NUL-terminated. META is "<cursor turn id>\t<its first entry's promptId>\t<found>".
JQ_RENDER='
def isstart: .type == "user" and (.message.content | type) == "string" and (.origin | type) == "object" and ((.isCompactSummary // false) | not);
def tag($n): (capture("<" + $n + ">(?<v>[^<]*)</" + $n + ">").v // "");
def firstline: split("\n") | map(select(test("\\S"))) | (.[0] // "");
def cut($n): if length > $n then .[0:$n] + "…" else . end;
def nonul: gsub("\u0000"; "");
def esc: nonul | gsub("<!-- turn"; "<\\!-- turn");
def prompt_of:
  .message.content as $c | .origin as $o
  | if $o.kind == "task-notification" then
      {kind: "agent", line: ($c | tag("summary") | if . == "" then "a background task finished" else . end), agent: ($c | tag("task-id"))}
    elif $o.kind == "peer" and (($o.handback // false) or ($o.senderTaskId != null)) then
      {kind: "agent", line: (($o.name // "an agent") + " reported back"), agent: null}
    elif $o.kind == "peer" then
      {kind: "peer", line: (($o.name // "another session") + ": " + ($c | gsub("<[^>]*>"; "\n") | split("\n") | map(select(test("\\S") and (startswith("Another Claude session sent a message") | not))) | (.[0] // "") | cut(120))), agent: null}
    elif ($c | startswith("<command-message>")) then
      {kind: "human", text: ((("/" + ($c | tag("command-message"))) + (($c | tag("command-args")) as $a | if ($a | test("\\S")) then " " + $a else "" end)) | gsub("^\\s+|\\s+$"; "")), agent: null}
    else {kind: "human", text: $c, agent: null} end;
def quote: split("\n") | map(if . == "" then ">" else "> " + . end) | join("\n");
def demote:
  split("\n")
  | reduce .[] as $l ({o: [], f: null};
      if .f == null then
        if ($l | test("^ {0,3}(`{3,}|~{3,})")) then .f = ($l | capture("^ {0,3}(?<m>`{3,}|~{3,})").m) | .o += [$l]
        elif ($l | test("^#{1,6}(\\s|$)")) then
          .o += [($l | capture("^(?<h>#{1,6})(?<r>.*)$") | ("#" * ([(.h | length) + 2, 6] | min)) + .r)]
        else .o += [$l] end
      else
        .f as $f
        | if ($l | test("^ {0,3}" + ($f[0:1]) + "{" + ($f | length | tostring) + ",}\\s*$")) then .f = null else . end
        | .o += [$l]
      end)
  | (if .f then .o + [.f] else .o end) | join("\n");
def hhmm: try (sub("\\.[0-9]+Z$"; "Z") | fromdateiso8601 | strflocaltime("%Y-%m-%d %H:%M")) catch "";

$subsf[0] as $subs
| reduce (inputs | fromjson? | select((.isSidechain // false) | not)) as $e
  ({g: [], ls: false};
   if ($e | isstart) then
     ($e | prompt_of) as $p
     | if .ls and (.g | length) > 0 then
         .g[-1].ids += [$e.promptId] | .g[-1].prompts += [$p]
       else
         .g += [{ids: [$e.promptId], pids: [], prompts: [$p], extra: [], ts: ($e.timestamp // ""),
                 ents: [], texts: [], stopped: false, irq: false}]
       end
     | .ls = true
   elif (.g | length) == 0 then .
   elif $e.type == "assistant" then
     .ls = false | .g[-1].ents += [$e]
     | .g[-1].texts += [$e.message.content[]? | select(.type == "text") | .text]
   elif $e.type == "user" and ($e.message.content | type) == "array" then
     .ls = false | .g[-1].ents += [$e] | .g[-1].pids += [$e.promptId // empty]
     | if ([$e.message.content[] | select(.type == "text") | .text | startswith("[Request interrupted by user")] | any)
       then .g[-1].irq = true else . end
   elif $e.type == "attachment" and $e.attachment.type? == "queued_command" and $e.attachment.origin.kind? == "human" then
     .g[-1].extra += [$e.attachment.prompt | restext]
   elif $e.type == "system" and $e.subtype? == "stop_hook_summary" then .g[-1].stopped = true
   else . end)
| .g as $g
| ([$g | to_entries[] | select(any(.value.ids[], .value.pids[]; . == $from)) | .key] | first) as $fi
| ([$g | to_entries[] | select(any(.value.ids[], .value.pids[]; . == $cur)) | .key] | last) as $ci
| ($fi // $ci // (($g | length) - 1)) as $start
| if ($g | length) == 0 or $start < 0 then "META\t\t\t0\u0000" else
  ($g | length - 1) as $lastidx
  | "META\t" + ($g[-1].ids[-1]) + "\t" + ($g[-1].ids[0]) + "\t" + (if $fi != null then "1" else "0" end) + "\u0000",
    ($g | to_entries[] | select(.key >= $start) | .key as $i | .value as $t
     | ($i == $ci) as $iscur
     | ($t.texts | if $iscur and ($lam | test("\\S")) and ((. | last // "" | nonul | gsub("^\\s+|\\s+$"; "")) != ($lam | gsub("^\\s+|\\s+$"; ""))) then . + [$lam] else . end) as $texts
     | (($iscur | not) and ($t.irq or (($t.stopped | not) and $i < $lastidx))) as $int
     | ([$t.prompts[] | select(.kind == "human")] | first) as $h
     | (if $h then ($h.text | firstline | cut(60))
        elif $t.prompts[0].kind == "agent" then "(background agent finished) " + ($t.prompts[0].line | cut(60))
        else "(message from another session)" end) as $label
     | arts($t.ents | toolsof; $t.ents | resof) as $own
     | ([$t.prompts[].agent // empty, ($t.ents[] | select(.toolUseResult.agentId? != null and .toolUseResult.status? != "async_launched") | .toolUseResult.agentId)]
        | map($subs[.] // []) | add // []) as $sub
     | ([$own[], $sub[]] | reduce .[] as $a ([]; if any(.[]; .k == $a.k) then . else . + [$a] end)) as $arts
     | "## " + ($t.ts | hhmm) + " · " + ($label | esc) + (if $int then " (interrupted)" else "" end) + "\n"
       + "<!-- turn " + ({prompt_id: $t.ids[-1], session_id: $sid, ts: $t.ts} | tojson) + " -->\n"
       + "### Prompt\n"
       + ([$t.prompts[] | if .kind == "human" then (.text | esc | quote)
           elif .kind == "agent" then "> (background agent finished) " + (.line | esc)
           else "> (message from another session) " + (.line | esc) end]
          + [$t.extra[] | "*Added while Claude was working:*\n\n" + (esc | quote)] | join("\n\n")) + "\n"
       + "### Reply\n"
       + (if ($texts | length) == 0 then "*(no reply text)*" else ($texts | map(demote) | join("\n\n") | esc) end) + "\n"
       + (if ($arts | length) > 0 then "### Artifacts\n" + ([$arts[] | "- " + (.s | esc)] | join("\n")) + "\n" else "" end)
       + "\n\u0000")
  end
'

# subagent_arts <transcript tail file> <session dir> — JSON {agentId: [artifacts]}
# for every subagent transcript the tail refers to.
subagent_arts() {
  local -a files=()
  local id
  while IFS= read -r id; do
    [ -f "$2/subagents/agent-$id.jsonl" ] && files+=("$2/subagents/agent-$id.jsonl")
  done < <(grep -oE '<task-id>[A-Za-z0-9]+</task-id>|"agentId":"[A-Za-z0-9]+"' "$1" 2>/dev/null \
             | sed -E 's/^<task-id>|<\/task-id>$|^"agentId":"|"$//g' | sort -u)
  [ "${#files[@]}" -gt 0 ] || { echo '{}'; return; }
  jq -n -R -c "$JQ_ARTS"'
    reduce (inputs | input_filename as $f | fromjson? | {f: $f, e: .}) as $x ({}; .[$x.f] += [$x.e])
    | with_entries(.key |= (capture("agent-(?<id>[A-Za-z0-9]+)\\.jsonl$").id) | .value |= arts(toolsof; resof))' \
    "${files[@]}" 2>/dev/null || echo '{}'
}

# start_offset <transcript> <from byte> <promptId> — byte offset of the turn-start
# entry carrying that promptId (the first line with it and an origin), or empty.
start_offset() {
  local o
  o="$(tail -c +"$(($2 + 1))" "$1" 2>/dev/null | grep -b -F "\"promptId\":\"$3\"" | grep -F '"origin":{' | head -1 | cut -d: -f1)"
  [[ "$o" =~ ^[0-9]+$ ]] && echo $(($2 + o))
}

# task_of_pane — the wb task file of the tmux session the hook's pane is in, or empty.
task_of_pane() {
  [ -n "${TMUX_PANE:-}" ] && command -v tmux >/dev/null 2>&1 || return 0
  local s
  s="$(tmux display-message -p -t "$TMUX_PANE" '#S' 2>/dev/null || true)"
  [ -n "$s" ] && tmux show -t "=$s:" -v @task 2>/dev/null || true
}

# hook_stop [end] — reconcile the session's reply file with its transcript. With
# `end` (SessionEnd: /clear or exit) it re-renders the cursor's turn, the last one
# logged, from the now-complete transcript and ignores the payload's prompt_id; it
# never creates a file.
hook_stop() {
  local mode="${1:-stop}" tp sid pid lam cwd
  tp="$(jq_in '.transcript_path // empty')"
  sid="$(jq_in '.session_id // empty')"
  pid="$(jq_in '.prompt_id // empty')"
  lam="$(jq_in '.last_assistant_message // empty')"
  cwd="$(jq_in '.cwd // empty')"
  [ -n "$tp" ] && [ -r "$tp" ] || quiet_exit
  [[ "$sid" =~ ^[A-Za-z0-9-]+$ ]] || quiet_exit
  [ "$mode" = end ] || [[ "$pid" =~ ^[A-Za-z0-9-]+$ ]] || quiet_exit
  if [ "$mode" = end ]; then
    lam=""
    [ -f "$REPLY_DIR/$sid.md" ] || quiet_exit
  fi

  umask 077
  mkdir -p "$REPLY_DIR" 2>/dev/null || quiet_exit
  chmod 700 "$REPLY_DIR" 2>/dev/null || true
  local file="$REPLY_DIR/$sid.md" cursor="$REPLY_DIR/.$sid.cursor"
  if command -v flock >/dev/null 2>&1; then
    { exec 9>"$REPLY_DIR/.$sid.lock"; } 2>/dev/null || quiet_exit
    flock -w "${REPLY_LOG_LOCK_WAIT:-4}" 9 2>/dev/null || quiet_exit
  fi

  local tsize fsize=0 from start cut c_turn="" c_md="" c_tx="" drop_first=0
  tsize="$(stat -c %s "$tp" 2>/dev/null)" || quiet_exit
  [ -f "$file" ] && fsize="$(stat -c %s "$file" 2>/dev/null || echo 0)"
  if [ -f "$cursor" ]; then
    { IFS= read -r c_turn; IFS= read -r c_md; IFS= read -r c_tx; } <"$cursor" 2>/dev/null || true
  fi
  if [ -f "$file" ] && [[ "$c_turn" =~ ^[A-Za-z0-9-]+$ ]] && [[ "$c_md" =~ ^[0-9]+$ ]] && [[ "$c_tx" =~ ^[0-9]+$ ]] \
     && [ "$c_md" -le "$fsize" ] && [ "$c_tx" -le "$tsize" ]; then
    from="$c_turn"; start="$c_tx"; cut="$c_md"
    [ "$mode" = end ] && pid="$c_turn"
  elif [ "$mode" = end ]; then
    quiet_exit
  else
    # first Stop for this file (or a lost cursor): only the current turn, appended
    local off
    off="$(start_offset "$tp" 0 "$pid")"
    [ -n "$off" ] || quiet_exit
    from="$pid"; cut="$fsize"
    start=$((off > FIRST_STOP_WINDOW ? off - FIRST_STOP_WINDOW : 0))
    [ "$start" -gt 0 ] && drop_first=1
  fi

  local tail subs
  WORK="$(mktemp -d "$REPLY_DIR/.work.XXXXXX" 2>/dev/null)" || quiet_exit
  trap '[ -n "$WORK" ] && rm -rf -- "$WORK"' EXIT
  tail="$WORK/tail.jsonl"
  # a first-Stop window that starts mid-line drops that partial line
  if [ "$drop_first" = 1 ]; then
    tail -c +"$((start + 1))" "$tp" | sed 1d >"$tail"
  else
    tail -c +"$((start + 1))" "$tp" >"$tail"
  fi
  subs="$(subagent_arts "$tail" "${tp%.jsonl}")"

  # both go to jq as files: one argv string is capped at 128 KiB
  printf '%s' "$lam" >"$WORK/lam"
  printf '%s' "$subs" >"$WORK/subs"
  jq -n -R -j --arg from "$from" --arg cur "$pid" --arg sid "$sid" \
     --rawfile lam "$WORK/lam" --slurpfile subsf "$WORK/subs" "$JQ_ARTS$JQ_RENDER" <"$tail" >"$WORK/rendered" 2>/dev/null || quiet_exit

  local -a recs=()
  local rec
  while IFS= read -r -d '' rec; do recs+=("$rec"); done <"$WORK/rendered"
  [ "${#recs[@]}" -ge 2 ] || quiet_exit
  local meta="${recs[0]}" new_turn first_id found
  IFS=$'\t' read -r _ new_turn first_id found <<<"$meta"
  [ -n "$new_turn" ] || quiet_exit
  # the cursor's turn wasn't in the transcript tail: append, never cut
  [ "$from" = "$c_turn" ] && [ "$found" != 1 ] && cut="$fsize"

  local out="$WORK/out" last_off=0 i
  if [ -f "$file" ]; then
    head -c "$cut" "$file" >"$out"
  else
    local task created name
    task="$(task_of_pane)"
    created="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    name="${task##*/}"; name="${name%.md}"
    [ -n "$name" ] || name="${cwd##*/}"
    {
      printf -- '---\nsession_id: %s\ntask: %s\ncwd: %s\nbranch: %s\ncreated: %s\n---\n\n' \
        "$sid" "$task" "$cwd" "$( [ -n "$cwd" ] && git -C "$cwd" branch --show-current 2>/dev/null)" "$created"
      printf '# %s · %s\n\n' "${name:-claude}" "$(date +'%Y-%m-%d %H:%M')"
    } >"$out"
  fi
  for ((i = 1; i < ${#recs[@]}; i++)); do
    last_off="$(stat -c %s "$out")"
    printf '%s' "${recs[$i]}" >>"$out"
  done

  local new_tx
  new_tx="$(start_offset "$tp" "$start" "$first_id")"
  [ -n "$new_tx" ] || new_tx="$start"
  printf '%s\n%s\n%s\n' "$new_turn" "$last_off" "$new_tx" >"$WORK/cursor"
  mv -f "$out" "$file" && mv -f "$WORK/cursor" "$cursor"
}

# fm_field <file> <key> — a frontmatter value (frontmatter only ever starts on line 1).
fm_field() {
  awk -v k="$2" 'NR == 1 { if ($0 != "---") exit; next }
    $0 == "---" { exit }
    index($0, k ":") == 1 { v = substr($0, length(k) + 2); sub(/^[ \t]+/, "", v); print v; exit }' "$1" 2>/dev/null
}

# pane_session <pane-id> — the Claude session id live in that pane: the newest
# entry in Claude Code's session registry (~/.claude/sessions/<pid>.json, updated
# in place on /clear) whose `tmux` field names the pane and whose pid is alive,
# else the pane's @claude_session_id (set by the notify hook, which only changes
# at the first prompt after /clear).
pane_session() {
  local pane="$1" pid sid
  local -a files=("$SESSIONS_DIR"/*.json)
  if [ -e "${files[0]}" ] && command -v jq >/dev/null 2>&1; then
    while IFS=$'\t' read -r pid sid; do
      [[ "$pid" =~ ^[0-9]+$ ]] && kill -0 "$pid" 2>/dev/null && { printf '%s\n' "$sid"; return 0; }
    done < <(jq -r --arg p "$pane" 'select((.tmux // "") | endswith("." + $p)) | [(.updatedAt // 0), .pid, .sessionId] | @tsv' \
               "${files[@]}" 2>/dev/null | sort -rn | cut -f2-)
  fi
  tmux show -p -t "$pane" -v @claude_session_id 2>/dev/null || true
}

# chain_for_task <task file> — every reply file whose frontmatter `task:` matches,
# plus the ids in the task file's `claude_sessions:`, as paths oldest first.
chain_for_task() {
  local task="$1"
  {
    awk -v t="$task" 'FNR == 1 { fm = ($0 == "---"); c = ""; tk = ""; next }
      !fm { nextfile }
      $0 == "---" { if (tk == t) print c "\t" FILENAME; nextfile }
      index($0, "task: ") == 1 { tk = substr($0, 7) }
      index($0, "created: ") == 1 { c = substr($0, 10) }' "$REPLY_DIR"/*.md
    local -a ids=()
    local id f
    IFS=',' read -r -a ids <<<"$(fm_field "$task" claude_sessions)"
    for id in "${ids[@]}"; do
      id="${id%%@*}"; id="${id//[[:space:]]/}"
      [[ "$id" =~ ^[A-Za-z0-9-]+$ ]] || continue
      f="$REPLY_DIR/$id.md"
      [ -f "$f" ] && printf '%s\t%s\n' "$(fm_field "$f" created)" "$f"
    done
  } | sort -u | cut -f2
}

cmd_chain() {
  local file="" sid="" pane=""
  if [ "${1:-}" = --pane ]; then
    pane="${2:-}"
    sid="$(pane_session "$pane")"
  else
    case "${1:-}" in */*) file="$1" ;; *) sid="${1:-}" ;; esac
  fi
  if [ -z "$file" ]; then
    [[ "$sid" =~ ^[A-Za-z0-9-]+$ ]] || return 0
    file="$REPLY_DIR/$sid.md"
  fi
  local task=""
  if [ -f "$file" ]; then
    task="$(fm_field "$file" task)"
    if [ -z "$task" ]; then printf '%s\n' "$file"; return 0; fi
  elif [ -n "$pane" ]; then
    # /clear gave the pane a session with no reply file yet: the pane's wb task
    # still chains the earlier sessions
    local s
    s="$(tmux display-message -p -t "$pane" '#S' 2>/dev/null || true)"
    [ -n "$s" ] && task="$(tmux show -t "=$s:" -v @task 2>/dev/null || true)"
  fi
  [ -n "$task" ] || return 0
  chain_for_task "$task"
}

cmd_view() {
  local pane="${1:-${TMUX_PANE:-}}" existing sid nvim self new
  [ -n "$pane" ] || return 0
  existing="$(tmux list-panes -a -F '#{pane_id} #{@reply_log_for}' 2>/dev/null | awk -v p="$pane" '$2 == p { print $1; exit }')"
  if [ -n "$existing" ]; then
    tmux select-window -t "$existing" 2>/dev/null; tmux select-pane -t "$existing" 2>/dev/null
    return 0
  fi
  sid="$(pane_session "$pane")"
  if ! [[ "$sid" =~ ^[A-Za-z0-9-]+$ ]]; then
    tmux display-message -t "$pane" "reply log: no Claude session in this pane" 2>/dev/null
    return 0
  fi
  nvim="$(command -v nvim)" || { tmux display-message -t "$pane" "reply log: nvim not found" 2>/dev/null; return 0; }
  self="$(readlink -f "${BASH_SOURCE[0]}")"
  new="$(tmux split-window -h -l 45% -t "$pane" -P -F '#{pane_id}' \
           -e "REPLY_LOG_DIR=$REPLY_DIR" -e "CLAUDE_SESSIONS_DIR=$SESSIONS_DIR" \
           "$nvim -R -c \"lua require('claude-tmux.replies').follow({ pane = '$pane', script = '$self' })\"" 2>/dev/null)"
  [ -n "$new" ] && tmux set -p -t "$new" @reply_log_for "$pane" 2>/dev/null
  return 0
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  case "${1:-}" in
    chain) shift; cmd_chain "$@" ;;
    view) cmd_view "${2:-}" ;;
    hook-stop|hook-session-end)
      exec 2>/dev/null
      [ -e "$REPLY_DIR/.disabled" ] && quiet_exit
      [ -n "${WB_CAPTURE_SWEEP:-}" ] && quiet_exit
      [ "${CLAUDE_CODE_SESSION_ATTENDED:-}" = 0 ] && quiet_exit
      case "${CLAUDE_CODE_ENTRYPOINT:-}" in sdk*) quiet_exit ;; esac
      command -v jq >/dev/null 2>&1 || quiet_exit
      read_input
      if [ "$1" = hook-session-end ]; then hook_stop end; else hook_stop; fi
      ;;
  esac
  exit 0
fi
