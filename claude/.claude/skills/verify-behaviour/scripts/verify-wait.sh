#!/usr/bin/env bash
# verify-wait.sh — the mechanical half of the verify-behaviour watcher
# (docs/plans/2026-10-25-0240-feat-verify-behaviour-watcher-plan.md, U1).
#
# A standing Sonnet session sleeps inside `wait` (run with run_in_background);
# the script's exit is what wakes it. Everything that does not need judgement
# lives here so a wake turn only judges: it reads the hits, records verdicts,
# acks, re-arms. While nothing relevant happens no tokens are spent (R5).
#
# Subcommands
#   wait                 poll every watched file; exit when something relevant
#                        happened. First line of stdout is ONE keyword:
#                          HIT             new content matched an open check's
#                                          trigger; one hit line per hit follows
#                          CHECKS-CHANGED  a checks.md appeared or changed
#                          ALREADY-ARMED   another wait holds the lock (do nothing)
#                          BAD-LAUNCH      WB_VERIFY_WATCHER=1 missing (session
#                                          not started by the verify-behaviour
#                                          function; relaunch it)
#                          PARENT-GONE     the Claude process that armed us died
#                        Exit status is always 0; the keyword is the signal.
#                        Never exits on a timer.
#   status               armed or not, plus every hit not yet acked
#                        ([undelivered] / [delivered] prefix on each hit line).
#   list                 every check of every checks.md with its current state.
#   ack <hit-id>         drop a judged hit from the pending list.
#   record <checks-file> <id> <state> <quote> <source>
#                        append a verdict (states: open partial proposed met
#                        broken). broken/proposed raise the tmux status marker.
#   seen                 clear the tmux status marker.
#   scan --since <time> <checks-file>
#                        read-only history scan (<=20 hits per check, never
#                        moves positions or touches pending). Output: SCAN, then
#                        hit lines.
#   selftest             check that the newest transcripts still carry the keys
#                        the filters rely on; non-zero exit and SELFTEST-FAIL
#                        when they don't.
#
# Hit line (one line, fields in this order, `text=` last and runs to the end):
#   hit=<id> checks=<checks.md path> check=<check id> source=<source> \
#     file=<watched file> range=<start>-<end> text=<matched text, <=240 chars>
# <source> is transcript | capture-log | decisions:<task-stem>. <range> is the
# byte range of the line in <file> for transcript/capture-log, and the 1-based
# bullet number (start==end) under "## Decisions" for decisions sources.
# <id> is a hash of (checks file, check id, and either origin.msg_id for a peer
# message or file:start-offset), so the same content never yields two hits.
#
# List line:
#   state=<s> feature=<f> check=<id> [waiting_for=<3d2h>] checks=<path> title=<t>
#
# Verdicts (verdicts.md beside checks.md, and `## Verdicts` in the watcher's
# task file) are one markdown bullet per verdict, identical in both places:
#   - <iso time> | <feature>/<check id> | <state> | <source> | <quote>
# A check's current state is the last line carrying its <feature>/<id>.
# `waiting` is never recorded: it means live_since is empty.
#
# Design notes (plan KTDs): hits are at-least-once (written to pending before
# positions advance, KTD7); polling is one stat call over every watched file
# (KTD2); transcripts are filtered to message text and hook_additional_context
# before matching (KTD4); one wait at a time, guarded by a lock holding pid and
# start time (KTD8); `wait` refuses to arm without WB_VERIFY_WATCHER=1 (KTD9).
# Bash 3.2-compatible on purpose (no associative arrays), like wb.sh.
#
# Overridable for tests: TASKS_DIR, XDG_STATE_HOME, CLAUDE_PROJECTS_DIR,
# VERIFY_POLL_SECS, VERIFY_WATCHER_TASK, VERIFY_SELF_DIR, VERIFY_PARENT_PID,
# WB_BIN (the wb executable used by `record`).
set -uo pipefail

TASKS_DIR="${TASKS_DIR:-$HOME/code/tasks}"
STATE_BASE="${XDG_STATE_HOME:-$HOME/.local/state}/wb"
VSTATE="$STATE_BASE/verify"
CAPTURE_LOG="$STATE_BASE/capture/log.jsonl"
PROJ="${CLAUDE_PROJECTS_DIR:-$HOME/.claude/projects}"
POLL="${VERIFY_POLL_SECS:-5}"
WATCHER="${VERIFY_WATCHER_TASK:-dotfiles--verify-behaviour-watcher}"
# The watcher's own transcript folder is excluded or its own replies (which
# quote trigger text) would wake it. The encoding must match wb.sh's
# wb_transcript_dir (the folder Claude Code names after a working directory).
SELF_DIR="${VERIFY_SELF_DIR:-$(printf '%s' "$PWD" | tr './' '--')}"
SELF_DIR="${SELF_DIR##*/}"

SEP=$'\037' # internal field separator; JSON can't contain it raw, and unlike a tab it keeps empty fields
POS="$VSTATE/positions.tsv"
PENDING="$VSTATE/pending.tsv"
HITSEEN="$VSTATE/hits.seen"
LOCK="$VSTATE/lock"
W=""
TROWS=()          # numbered triggers (t.tsv rows), indexed by trigger number
TRIGJSON="[]"     # every trigger as JSON, built once per load_checks
DECSTEMS=""       # task stems named by any decisions: trigger (newline list)
DECSRCS=""        # decisions:<stem> sources with an open|partial trigger
NTRANS=0          # open|partial transcript triggers, and the earliest live epoch
MINLIVE_T=""
NCAP=0            # open|partial capture-log triggers
WFILES=()         # watched files, in stat order
BFILES=()         # file behind each batch index
NB=0
SRC=""
START=""
SP=()             # transcript start-time cache: paths, their start epochs (empty = none), count
SV=()
NS=0
FOUND=0
WRAW=""           # stat rows of the watched files
LASTRAW=$'\001'   # the previous stat call's whole output ('unset' until the first call)
STATCHG=1
CSIG=""
VSIG=""
HITMODE=pending
STATES=""
ONLYCF=""
SINCE=0
NEWHITS=0
NEWCOUNT=0
CONSUMED=0

# ISO-8601 -> epoch seconds (Z, offset and fractional seconds accepted), empty on garbage.
JQ_LIB='def ep: (capture("^(?<d>[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2})(\\.[0-9]+)?(?<z>Z|[+-][0-9]{2}:[0-9]{2})$")) as $c
  | (($c.d + "Z") | fromdateiso8601)
    - (if $c.z == "Z" then 0 else ((if $c.z[0:1] == "+" then 1 else -1 end) * (($c.z[1:3] | tonumber) * 3600 + ($c.z[4:6] | tonumber) * 60)) end);'

iso_epoch() { jq -rn --arg t "$1" "$JQ_LIB"' try ($t | ep) catch empty' 2>/dev/null; }
now_iso() { date -u +%Y-%m-%dT%H:%M:%SZ; }
hash10() { if command -v sha1sum >/dev/null 2>&1; then sha1sum; else shasum; fi | cut -c1-10; }

# GNU stat vs BSD stat, decided once (a partial failure of `stat -c` must not
# fall through to BSD flags, which mean something else on GNU).
if stat -c %s / >/dev/null 2>&1; then
  STATCMD=(stat -c "%n${SEP}%i${SEP}%s${SEP}%Y")
  fsize() { stat -c %s "$1" 2>/dev/null; }
  fino() { stat -c %i "$1" 2>/dev/null; }
  fmtime() { stat -c %Y "$1" 2>/dev/null; }
else
  STATCMD=(stat -f "%N${SEP}%i${SEP}%z${SEP}%m")
  fsize() { stat -f %z "$1" 2>/dev/null; }
  fino() { stat -f %i "$1" 2>/dev/null; }
  fmtime() { stat -f %m "$1" 2>/dev/null; }
fi

# --- processes ------------------------------------------------------------------

proc_start() { # <pid> — something that changes if the pid is reused
  local s
  if [ -r "/proc/$1/stat" ]; then
    s="$(sed 's/^.*) //' "/proc/$1/stat" 2>/dev/null)"
    # shellcheck disable=SC2086
    set -- "$1" $s
    printf '%s' "${21:-}" # field 22 (starttime) of /proc/<pid>/stat
  else
    ps -o lstart= -p "$1" 2>/dev/null | tr -s ' '
  fi
}
ppid_of() {
  if [ -r "/proc/$1/stat" ]; then
    sed 's/^.*) //' "/proc/$1/stat" 2>/dev/null | cut -d' ' -f2
  else
    ps -o ppid= -p "$1" 2>/dev/null | tr -d ' '
  fi
}
comm_of() {
  if [ -r "/proc/$1/comm" ]; then cat "/proc/$1/comm" 2>/dev/null; else ps -o comm= -p "$1" 2>/dev/null; fi
}
find_parent() { # the Claude process whose death ends the wait
  if [ -n "${VERIFY_PARENT_PID:-}" ]; then printf '%s' "$VERIFY_PARENT_PID"; return; fi
  local p="$PPID" i=0 c
  while [ -n "$p" ] && [ "$p" -gt 1 ] 2>/dev/null && [ "$i" -lt 30 ]; do
    c="$(comm_of "$p")"
    if [ "${c##*/}" = "claude" ]; then printf '%s' "$p"; return; fi
    p="$(ppid_of "$p")"; i=$((i + 1))
  done
  printf '%s' "$PPID"
}
alive() { kill -0 "$1" 2>/dev/null; }

# --- pending hits (shared between wait, ack and status: guarded by a tiny lock) ---

plock() {
  local i=0
  while ! mkdir "$VSTATE/pending.lock" 2>/dev/null; do
    i=$((i + 1))
    if [ "$i" -gt 100 ]; then rmdir "$VSTATE/pending.lock" 2>/dev/null; fi # stale after ~5s
    sleep 0.05
  done
}
punlock() { rmdir "$VSTATE/pending.lock" 2>/dev/null || true; }

# queue_hit <id> <line> — append a hit to pending unless it was ever raised before.
queue_hit() {
  plock
  if ! grep -qxF "$1" "$HITSEEN" 2>/dev/null; then
    printf '%s\n' "$1" >>"$HITSEEN"
    printf '%s%s0%s%s\n' "$1" "$SEP" "$SEP" "$2" >>"$PENDING"
    NEWHITS=$((NEWHITS + 1))
  fi
  punlock
}

# add_hit <trigger-idx> <source> <file> <start> <end> <msgid> <text>
# In scan mode the hit goes to $W/scan.out; otherwise to pending (deduplicated
# against every hit ever created, so an acked hit is never raised again).
add_hit() {
  local idx="$1" src="$2" f="$3" a="$4" b="$5" msgid="$6" text="$7" cf cid id key line
  IFS="$SEP" read -r _ cf cid _ <<<"${TROWS[$idx]}"
  key="$cf|$cid|${msgid:-$f:$a}"
  id="$(printf '%s' "$key" | hash10)"
  line="hit=$id checks=$cf check=$cid source=$src file=$f range=$a-$b text=$text"
  if [ "$HITMODE" = scan ]; then
    printf '%s%s%s\n' "$cid" "$SEP" "$line" >>"$W/scan.out"
    return
  fi
  queue_hit "$id" "$line"
}

# deliver — print HIT and every undelivered hit, marking them delivered; 1 if none.
deliver() {
  local out
  plock
  out="$(awk -F"$SEP" '$2 == 0 { print $3 }' "$PENDING" 2>/dev/null)"
  if [ -z "$out" ]; then punlock; return 1; fi
  awk -F"$SEP" -v OFS="$SEP" '{ $2 = 1; print }' "$PENDING" >"$PENDING.tmp" && mv "$PENDING.tmp" "$PENDING"
  punlock
  printf 'HIT\n%s\n' "$out"
}

# --- checks.md parsing ------------------------------------------------------------

# Emits C rows (one per check) and T rows (one per trigger) for one checks file.
#   C SEP cf SEP feature SEP live-epoch SEP id SEP title SEP state
#   T SEP cf SEP id SEP live-epoch SEP source SEP regex SEP state
# state is waiting when live_since is empty, else the last verdict, else open.
parse_checks() { # <checks-file>
  local cf="$1" raw ep=""
  raw="$(awk '/^## /{exit} { if (match($0, /live_since:[ \t]*[^ \t]*/)) { v = substr($0, RSTART, RLENGTH); sub(/live_since:[ \t]*/, "", v); print v; exit } }' "$cf")"
  case "$raw" in [0-9]*) ep="$(iso_epoch "$raw")" ;; esac
  local dir="${cf%/*}"
  CF="$cf" VF="$dir/verdicts.md" EP="$ep" DNAME="${dir##*/}" awk '
    function trim(s) { sub(/^[ \t]+/, "", s); sub(/[ \t]+$/, "", s); return s }
    BEGIN {
      S = "\037"; cf = ENVIRON["CF"]; vf = ENVIRON["VF"]; ep = ENVIRON["EP"]; feature = ENVIRON["DNAME"]
      while ((getline l < vf) > 0) {
        if (substr(l, 1, 2) != "- ") continue
        n = split(substr(l, 3), a, "[ ][|][ ]")
        if (n >= 3) last[trim(a[2])] = trim(a[3])
      }
      inhdr = 1
    }
    inhdr && /^## / { inhdr = 0 }
    inhdr {
      if (match($0, /feature:[ \t]*[^ \t]*/)) { v = substr($0, RSTART, RLENGTH); sub(/feature:[ \t]*/, "", v); if (v != "") feature = v }
      next
    }
    /^## / {
      id = $0; sub(/^## +/, "", id); title = id; sub(/^[^ .]+\.? */, "", title); sub(/[ .].*$/, "", id)
      if (ep == "") st = "waiting"; else { k = feature "/" id; st = (k in last) ? last[k] : "open" }
      print "C" S cf S feature S ep S id S title S st
      next
    }
    /^trigger:/ && id != "" {
      s = $0; sub(/^trigger:[ \t]*/, "", s); p = index(s, " "); if (p == 0) next
      src = substr(s, 1, p - 1); r = substr(s, p + 1); a1 = index(r, "/"); if (!a1) next
      b1 = 0; for (i = length(r); i > a1; i--) if (substr(r, i, 1) == "/") { b1 = i; break }
      if (!b1) next
      print "T" S cf S id S ep S src S substr(r, a1 + 1, b1 - a1 - 1) S st
    }' "$cf"
}

# load_checks — rebuild $W/c.tsv (every check) and $W/t.tsv (numbered triggers),
# plus everything the poll derives from them once instead of every pass: the
# trigger rows, the trigger JSON handed to jq, the decisions stems to watch and
# the per-source counts that let an idle source skip reading altogether.
load_checks() {
  local cf tag a b n=0 line
  : >"$W/rows"
  for cf in "$TASKS_DIR"/dossiers/*/checks.md; do
    [ -f "$cf" ] && parse_checks "$cf" >>"$W/rows"
  done
  awk -F"$SEP" '$1 == "C" { print substr($0, 3) }' "$W/rows" >"$W/c.tsv"
  awk -F"$SEP" '$1 == "T" { n++; print n "\037" substr($0, 3) }' "$W/rows" >"$W/t.tsv"
  TROWS=()
  while IFS= read -r line; do n=$((n + 1)); TROWS[$n]="$line"; done <"$W/t.tsv"
  # t.tsv columns: idx cf id live source regex state. Transcript triggers only
  # apply to sessions that started at/after the check's live_since (skills and
  # hooks load at session start, KTD11); the filter runs inside jq per row.
  TRIGJSON="$(jq -R -n -c '
    [inputs | split("\u001f")
     | {i: (.[0] | tonumber), cf: .[1], id: .[2], live: (if .[3] == "" then null else (.[3] | tonumber) end), src: .[4], re: .[5], state: .[6]}]' "$W/t.tsv")"
  [ -n "$TRIGJSON" ] || TRIGJSON="[]"
  NTRANS=0; MINLIVE_T=""; NCAP=0; DECSTEMS=""; DECSRCS=""
  while read -r tag a b; do
    case "$tag" in
      T) NTRANS="$a"; MINLIVE_T="$b" ;;
      C) NCAP="$a" ;;
      D) DECSRCS="$DECSRCS$a"$'\n' ;;
      S) DECSTEMS="$DECSTEMS$a"$'\n' ;;
    esac
  done < <(awk -F"$SEP" '
    $5 ~ /^decisions:/ && !st[$5]++ { print "S", substr($5, 11) }
    $7 == "open" || $7 == "partial" {
      if ($5 == "transcript") { nt++; if (min == "" || $4 + 0 < min + 0) min = $4 }
      else if ($5 == "capture-log") nc++
      else if ($5 ~ /^decisions:/ && !dr[$5]++) print "D", $5
    }
    END { print "T", nt + 0, min; print "C", nc + 0 }' "$W/t.tsv")
}

# --- extraction ----------------------------------------------------------------------

# The jq filter. Input rows are "<file-idx> SEP <start epoch|""> SEP <offset> SEP <length> SEP <raw line>".
# $kind: transcript | capture | plain. $src/$states/$only pick the triggers that
# apply; a row's start epoch drops triggers whose live_since is later than the
# session start. Output rows:
#   file-idx SEP start SEP end SEP trigger-idx SEP msg-id SEP snippet
# Transcript lines keep only user/assistant message text and hook_additional_context
# attachments; queue-operation lines, subagent hand-backs, tool results and other
# attachment types are dropped (KTD4). Capture-log lines of the watcher's own task
# are dropped. (read_range has already dropped transcript lines that cannot pass
# this filter, before they reach jq's fromjson.)
JQ_MATCH='
def clean: gsub("[\\x01-\\x1f]"; " ");
def txt: if type == "string" then . elif type == "array" then ([.[] | objects | select(.type == "text") | .text | strings] | join(" ")) else "" end;
def snip($re): clean as $s | ((try ($s | match($re).offset) catch 0) // 0) as $m | $s[(if $m > 60 then $m - 60 else 0 end):][:240];
split("\u001f") as $p
| $p[0] as $fi | ($p[1] | if . == "" then null else tonumber end) as $start
| ($p[2] | tonumber) as $off | ($p[3] | tonumber) as $len | $p[4] as $raw
| (if $kind == "plain" then {t: $raw, m: ""}
   else ($raw | try fromjson catch null) as $o
     | if ($o | type) != "object" then empty
       elif $kind == "capture" then
         (if ($o.task // "") == $watcher then empty
          elif ($since > 0 and ((try ($o.ts | ep) catch 0) < $since)) then empty
          else {t: $raw, m: ""} end)
       elif $o.type == "queue-operation" then empty
       elif (($o.origin | objects | has("handback")) // false) then empty
       elif $o.type == "attachment" then
         (if (($o.attachment | objects | .type) // "") == "hook_additional_context"
          then {t: (($o.attachment.content // "") | if type == "string" then . elif type == "array" then map(tostring) | join(" ") else tostring end), m: ""}
          else empty end)
       elif $o.type == "user" or $o.type == "assistant" then
         {t: (($o.message | objects | .content) | txt), m: (($o.origin | objects | select(.kind == "peer") | .msg_id) // "")}
       else empty end
   end) as $x
| select(($x.t | length) > 0)
| $trig[] | . as $tr
| select($tr.src == $src and any($states | split("|")[]; . == $tr.state) and ($only == "" or $tr.cf == $only) and ($start == null or $tr.live == null or $tr.live <= $start))
| select(try ($x.t | test($tr.re)) catch false)
| [$fi, ($off | tostring), (($off + $len) | tostring), ($tr.i | tostring), $x.m, ($x.t | snip($tr.re))] | join("\u001f")'

run_match() { # <kind> <source> <state-regex> <only-checks-file> <since-epoch>   (stdin: batch rows)
  jq -R -r --arg kind "$1" --argjson trig "$TRIGJSON" --arg src "$2" --arg states "$3" --arg only "$4" \
    --argjson since "${5:-0}" --arg watcher "$WATCHER" "$JQ_LIB $JQ_MATCH" 2>/dev/null
}

set_src() { # <path> -> SRC = transcript | capture-log | decisions:<stem> (empty otherwise)
  case "$1" in
    "$CAPTURE_LOG" | "$CAPTURE_LOG".1) SRC=capture-log ;;
    "$PROJ"/*) SRC=transcript ;;
    *.md) local b="${1##*/}"; SRC="decisions:${b%.md}" ;;
    *) SRC="" ;;
  esac
}

# load_starts <transcript...> — add each file's session start epoch (its first
# timestamped line) to the SP/SV cache, for all the files in one head|awk|jq pipeline.
# A file with no usable timestamp gets an empty start.
load_starts() {
  [ "$#" -gt 0 ] || return 0
  local out p v
  out="$(head -n 30 "$@" /dev/null 2>/dev/null \
    | LC_ALL=C awk -v S="$SEP" '/^==> .* <==$/ { f = substr($0, 5, length($0) - 8); next } index($0, "\"timestamp\"") { print f S $0 }' \
    | jq -R -r "$JQ_LIB"' split("\u001f") as $p | (try ($p[1:] | join("\u001f") | fromjson) catch null) as $o
        | select(($o | type) == "object") | ($o.timestamp // empty) as $t
        | [$p[0], ((try ($t | ep) catch empty) // "")] | join("\u001f")' 2>/dev/null \
    | awk -F"$SEP" '!seen[$1]++')"
  [ -n "$out" ] || return 0
  while IFS="$SEP" read -r p v; do SP[$NS]="$p"; SV[$NS]="$v"; NS=$((NS + 1)); done <<<"$out"
  return 0
}
# lookup_start <path> -> START (empty when unknown), FOUND (1 when the cache has the path)
lookup_start() {
  local i=0
  START=""; FOUND=0
  while [ "$i" -lt "$NS" ]; do
    if [ "${SP[$i]}" = "$1" ]; then START="${SV[$i]}"; FOUND=1; return 0; fi
    i=$((i + 1))
  done
}

decision_rows() { # <task file> -> "<n> SEP 0 SEP <text>" per bullet under ## Decisions
  awk '
    function flush() { if (have) { print n "\037" "0" "\037" cur; have = 0 } }
    /^## / { flush(); insec = ($0 ~ /^## Decisions[ \t]*$/); next }
    insec && /^[-*] / { flush(); n++; cur = substr($0, 3); have = 1; next }
    insec && have && /^[ \t]+[^ \t]/ { t = $0; sub(/^[ \t]+/, "", t); cur = cur " " t; next }
    insec && /^[ \t]*$/ { next }
    insec { flush() }
    END { flush() }' "$1"
}

# read_range <file> <from> <to> <out> <file-idx> <start> <kind> — one tail|awk
# pass. Appends the complete lines of [from,to) to <out> as batch rows and sets
# CONSUMED to the byte offset after the last complete line, so a half-written
# line waits for its newline. Transcript lines that cannot match anything
# (neither a user/assistant message nor hook_additional_context) are skipped
# here, before any JSON is parsed, but still counted as consumed.
read_range() {
  local f="$1" from="$2" to="$3" len filt=0
  CONSUMED="$from"
  len=$((to - from)); [ "$len" -gt 0 ] || return 0
  [ "$7" = transcript ] && filt=1
  printf '%s\n' "$from" >"$W/consumed"
  tail -c +$((from + 1)) "$f" 2>/dev/null | LC_ALL=C awk -v base="$from" -v len="$len" -v bi="$5" -v st="$6" -v filt="$filt" -v cf="$W/consumed" '
    BEGIN { o = 0; S = "\037" }
    { n = length($0) + 1; if (o + n > len) exit
      if (!filt || index($0, "\"type\":\"user\"") || index($0, "\"type\":\"assistant\"") || index($0, "hook_additional_context"))
        printf "%d%s%s%s%.0f%s%d%s%s\n", bi, S, st, S, base + o, S, n - 1, S, $0
      o += n }
    END { printf "%.0f\n", base + o > cf }' >>"$4"
  read -r CONSUMED <"$W/consumed"
}

# emit_batch <kind> <source> <rows-file> — run the matcher over a batch of rows
# and raise a hit per match (the file comes from BFILES by each row's index).
emit_batch() {
  local kind="$1" src="$2" rf="$3" bi st en idx msgid text
  [ -s "$rf" ] || return 0
  while IFS="$SEP" read -r bi st en idx msgid text; do
    add_hit "$idx" "$src" "${BFILES[$bi]}" "$st" "$en" "$msgid" "$text"
  done < <(run_match "$kind" "$src" "${STATES:-open|partial}" "$ONLYCF" "$SINCE" <"$rf")
}

# applies <source> <start> — could any trigger match this file at all? Poll mode
# only; scan mode (which names its own states and checks file) always reads.
applies() {
  [ "$HITMODE" = scan ] && return 0
  case "$1" in
    transcript) [ "$NTRANS" -gt 0 ] && { [ -z "$2" ] || [ "$MINLIVE_T" -le "$2" ]; } ;;
    capture-log) [ "$NCAP" -gt 0 ] ;;
    decisions:*) case $'\n'"$DECSRCS" in *$'\n'"$1"$'\n'*) return 0 ;; *) return 1 ;; esac ;;
  esac
}

# queue_range <file> <source> <from> <to> <start> — add [from,to) to the poll's
# batch for its kind; sets CONSUMED (to <to> when no trigger can match: just advance).
queue_range() {
  local out="$W/batch.t" kind=transcript
  CONSUMED="$3"
  if [ "$2" = capture-log ]; then out="$W/batch.c"; kind=capture; fi
  if ! applies "$2" "$5"; then CONSUMED="$4"; return 0; fi
  NB=$((NB + 1)); BFILES[$NB]="$1"
  read_range "$1" "$3" "$4" "$out" "$NB" "$5" "$kind"
}

# match_jsonl <file> <source> <from> <to> <start-epoch> <kind> — hits from [from,to) of one jsonl, at once.
match_jsonl() {
  : >"$W/batch.s"; BFILES[1]="$1"
  read_range "$1" "$3" "$4" "$W/batch.s" 1 "$5" "$6"
  emit_batch "$6" "$2" "$W/batch.s"
}

# match_decisions <file> <source> <after-count> — hits from bullets numbered above
# <after-count>; sets NEWCOUNT to the bullet count. wb rewrites task files whole,
# so a changed stat means "recount", never "seek".
match_decisions() {
  local f="$1" src="$2" after="$3"
  decision_rows "$f" >"$W/dec.rows"
  NEWCOUNT="$(awk -F"$SEP" 'END { print NR ? $1 : 0 }' "$W/dec.rows")"
  applies "$src" "" || return 0
  [ "$NEWCOUNT" -gt "$after" ] || return 0
  awk -F"$SEP" -v OFS="$SEP" -v a="$after" '$1 > a { print 0, "", $1, $2, $3 }' "$W/dec.rows" >"$W/dec.new"
  BFILES[0]="$f"
  emit_batch plain "$src" "$W/dec.new"
}

# --- watched files and positions ---------------------------------------------------------

# watched_files — fills WFILES: every transcript but the watcher's own, the
# capture log, and the task files named by a decisions: trigger. The transcript
# glob is not stat-checked one by one: the stat call that follows drops a path
# that has vanished, and the watcher's folder is cut out by GLOBIGNORE.
watched_files() {
  local f s IFS=$'\n' GLOBIGNORE="$PROJ/$SELF_DIR/*"
  WFILES=("$PROJ"/*/*.jsonl)
  [ -e "${WFILES[0]}" ] || WFILES=()
  [ -f "$CAPTURE_LOG" ] && WFILES[${#WFILES[@]}]="$CAPTURE_LOG"
  for s in $DECSTEMS; do
    if [ -n "$s" ] && [ "$s" != "$WATCHER" ] && [ -f "$TASKS_DIR/$s.md" ]; then WFILES[${#WFILES[@]}]="$TASKS_DIR/$s.md"; fi
  done
  return 0
}

# stat_all — ONE stat call over every checks.md and verdicts.md (first) and
# every watched file. STATCHG says whether any row moved since the last call; only
# then are the rows split into the checks signature CSIG, the verdicts signature
# VSIG and the watched rows WRAW (all three are left as they were otherwise).
stat_all() {
  local f rest line i=0 raw
  local -a sf=()
  watched_files
  for f in "$TASKS_DIR"/dossiers/*/checks.md "$TASKS_DIR"/dossiers/*/verdicts.md; do [ -f "$f" ] && sf[${#sf[@]}]="$f"; done
  raw=""
  if [ "$(( ${#sf[@]} + ${#WFILES[@]} ))" -gt 0 ]; then
    raw="$("${STATCMD[@]}" ${sf[@]+"${sf[@]}"} ${WFILES[@]+"${WFILES[@]}"} 2>/dev/null)"
  fi
  if [ "$raw" = "$LASTRAW" ]; then STATCHG=0; return 0; fi
  STATCHG=1; LASTRAW="$raw"
  CSIG=""; VSIG=""; rest="$raw"
  while [ "$i" -lt "${#sf[@]}" ] && [ -n "$rest" ]; do
    case "$rest" in *$'\n'*) line="${rest%%$'\n'*}"; rest="${rest#*$'\n'}" ;; *) line="$rest"; rest="" ;; esac
    case "${line%%"$SEP"*}" in
      */checks.md) CSIG="$CSIG$line"$'\n' ;;
      */verdicts.md) VSIG="$VSIG$line"$'\n' ;;
    esac
    i=$((i + 1))
  done
  CSIG="${CSIG%$'\n'}"; VSIG="${VSIG%$'\n'}"; WRAW="$rest"
  return 0
}

# changed_rows — path ino size stored-offset stored-ino stored-start status(new|chg)
changed_rows() {
  [ -f "$POS" ] || : >"$POS"
  if [ -n "$WRAW" ]; then printf '%s\n' "$WRAW" >"$W/stat.watched"; else : >"$W/stat.watched"; fi
  awk -F"$SEP" -v OFS="$SEP" -v posf="$POS" '
    FILENAME == posf { have[$1] = 1; ino[$1] = $2; sz[$1] = $3; off[$1] = $4; st[$1] = $5; next }
    !($1 in have) { print $1, $2, $3, 0, "", "", "new"; next }
    ($2 != ino[$1] || $3 != sz[$1]) { print $1, $2, $3, off[$1], ino[$1], st[$1], "chg" }' "$POS" "$W/stat.watched"
}

merge_positions() { # fold $W/newpos into positions.tsv (last write per path wins)
  [ -s "$W/newpos" ] || return 0
  awk -F"$SEP" -v nf="$W/newpos" 'FILENAME == nf { new[$1] = 1; next } !($1 in new)' "$W/newpos" "$POS" >"$POS.tmp"
  cat "$W/newpos" >>"$POS.tmp"
  mv "$POS.tmp" "$POS"; : >"$W/newpos"
}

# prep_new_starts — look up the start of every new transcript in $W/changed in one batch.
prep_new_starts() {
  local f ino size poff pino start status
  local -a nf=()
  while IFS="$SEP" read -r f ino size poff pino start status; do
    [ "$status" = new ] || continue
    set_src "$f"
    [ "$SRC" = transcript ] && nf[${#nf[@]}]="$f"
  done <"$W/changed"
  load_starts ${nf[@]+"${nf[@]}"}
}

# baseline_new — record every not-yet-tracked watched file at its current end, so
# history is never replayed by the poll (the first-live scan covers history).
baseline_new() {
  local f ino size poff pino start status
  changed_rows >"$W/changed"
  prep_new_starts
  while IFS="$SEP" read -r f ino size poff pino start status; do
    [ "$status" = new ] || continue
    set_src "$f"
    case "$SRC" in
      transcript) lookup_start "$f"; start="$START"; poff="$size" ;;
      capture-log) start=""; poff="$size" ;;
      *) start=""; poff="$(decision_rows "$f" | tail -n 1 | cut -d"$SEP" -f1)"; poff="${poff:-0}" ;;
    esac
    printf '%s\n' "$f$SEP$ino$SEP$size$SEP$poff$SEP$start" >>"$W/newpos"
  done <"$W/changed"
  merge_positions
}

# process_changed — one pass over the files whose stat moved. Transcript and
# capture-log ranges are read into one batch per kind and matched by a single jq
# run each; task files follow. Hits go to pending first; the caller merges
# positions afterwards (KTD7: pending before positions).
process_changed() {
  local f ino size poff pino start status n
  changed_rows >"$W/changed"
  [ -s "$W/changed" ] || return 0
  prep_new_starts
  : >"$W/batch.t"; : >"$W/batch.c"; : >"$W/changed.dec"; BFILES=(); NB=0
  while IFS="$SEP" read -r f ino size poff pino start status; do
    set_src "$f"
    case "$SRC" in
      transcript | capture-log)
        if [ "$status" = new ] && [ "$SRC" = transcript ]; then lookup_start "$f"; start="$START"; fi
        if [ -n "$pino" ] && { [ "$ino" != "$pino" ] || [ "$size" -lt "$poff" ]; }; then
          # Rotated (the capture log moves to <log>.1 at 5 MB): finish the old
          # file's unread tail before starting the new one from zero.
          if [ "$SRC" = capture-log ] && [ "$ino" != "$pino" ] && [ -f "$f.1" ] && [ "$(fino "$f.1")" = "$pino" ]; then
            n="$(fsize "$f.1")"
            queue_range "$f.1" capture-log "$poff" "$n" ""
          fi
          poff=0
        fi
        queue_range "$f" "$SRC" "$poff" "$size" "$start"
        poff="$CONSUMED"
        printf '%s\n' "$f$SEP$ino$SEP$size$SEP$poff$SEP$start" >>"$W/newpos" ;;
      decisions:*) printf '%s\n' "$f$SEP$ino$SEP$size$SEP$poff" >>"$W/changed.dec" ;;
    esac
  done <"$W/changed"
  emit_batch transcript transcript "$W/batch.t"
  emit_batch capture capture-log "$W/batch.c"
  while IFS="$SEP" read -r f ino size poff; do
    set_src "$f"
    match_decisions "$f" "$SRC" "$poff"
    printf '%s\n' "$f$SEP$ino$SEP$size$SEP$NEWCOUNT$SEP" >>"$W/newpos"
  done <"$W/changed.dec"
}

# --- history scans (KTD11) -----------------------------------------------------------------

# scan_collect <checks-file> <since-epoch> <state-regex> — prints up to 20 hit
# lines per check on stdout. Reads whole files; never touches positions or
# pending (its only writes are scratch files under $W). A subshell, so the scan
# mode globals revert on their own.
# Transcripts last written before <since-epoch> are skipped without a look (they
# started earlier still); start times come from positions.tsv when it has them.
scan_collect() (
  local cf="$1" f st sz mt rows line
  local -a cand=()
  HITMODE=scan; STATES="$3"; ONLYCF="$cf"; SINCE="$2"
  : >"$W/scan.out"
  SP=(); SV=(); NS=0
  if [ -f "$POS" ]; then
    while IFS="$SEP" read -r f _ _ _ st; do
      if [ -n "$st" ]; then SP[$NS]="$f"; SV[$NS]="$st"; NS=$((NS + 1)); fi
    done <"$POS"
  fi
  watched_files
  [ "${#WFILES[@]}" -gt 0 ] || return 0
  rows="$("${STATCMD[@]}" "${WFILES[@]}" 2>/dev/null)"
  while IFS="$SEP" read -r f _ sz mt; do
    set_src "$f"
    [ "$SRC" = transcript ] || continue
    if [ "$SINCE" -gt 0 ] && [ "$mt" -lt "$SINCE" ]; then continue; fi
    lookup_start "$f"
    [ "$FOUND" = 1 ] || cand[${#cand[@]}]="$f"
  done <<<"$rows"
  load_starts ${cand[@]+"${cand[@]}"}
  while IFS="$SEP" read -r f _ sz mt; do
    set_src "$f"
    case "$SRC" in
      transcript)
        if [ "$SINCE" -gt 0 ] && [ "$mt" -lt "$SINCE" ]; then continue; fi
        lookup_start "$f"
        if [ "$SINCE" -gt 0 ] && [ -n "$START" ] && [ "$START" -lt "$SINCE" ]; then continue; fi
        match_jsonl "$f" transcript 0 "$sz" "" transcript ;;
      capture-log) match_jsonl "$f" capture-log 0 "$sz" "" capture ;;
      decisions:*) match_decisions "$f" "$SRC" 0 ;;
    esac
  done <<<"$rows"
  # Keep the last 20 hits per check.
  awk -F"$SEP" '{ cid[NR] = $1; line[NR] = substr($0, length($1) + 2) }
    END { for (i = NR; i >= 1; i--) if (++seen[cid[i]] <= 20) keep[i] = 1; for (i = 1; i <= NR; i++) if (keep[i]) print line[i] }' "$W/scan.out"
)

# first_live_scans — scan each newly live checks file once so behaviour that
# happened before the watcher started is still judged. Hits go through pending.
first_live_scans() {
  local cf ep line id
  touch "$VSTATE/seen-live"
  while IFS="$SEP" read -r cf ep; do
    [ -n "$ep" ] || continue
    grep -qxF "$cf" "$VSTATE/seen-live" && continue
    scan_collect "$cf" "$ep" "open|partial" >"$W/first.hits"
    while IFS= read -r line; do
      [ -n "$line" ] || continue
      id="${line#hit=}"; id="${id%% *}"
      queue_hit "$id" "$line"
    done <"$W/first.hits"
    printf '%s\n' "$cf" >>"$VSTATE/seen-live"
  done < <(awk -F"$SEP" '{ print $1 "\037" $3 }' "$W/c.tsv" | sort -u)
}

# --- subcommands ------------------------------------------------------------------------------

cleanup() {
  if [ -f "$LOCK" ] && [ "$(cut -d' ' -f1 "$LOCK" 2>/dev/null)" = "$$" ]; then rm -f "$LOCK" "$VSTATE/ready"; fi
  if [ -n "$W" ] && [ -d "$W" ]; then rm -f "${W:?}"/* 2>/dev/null; rmdir "$W" 2>/dev/null; fi
  return 0
}

acquire_lock() {
  local pid st
  if (set -C; printf '%s %s\n' "$$" "$(proc_start $$)" >"$LOCK") 2>/dev/null; then return 0; fi
  read -r pid st <"$LOCK" 2>/dev/null
  if [ -n "${pid:-}" ] && alive "$pid" && [ "$(proc_start "$pid")" = "${st:-}" ]; then return 1; fi
  rm -f "$LOCK" # stale: its process is gone (or the pid was reused)
  (set -C; printf '%s %s\n' "$$" "$(proc_start $$)" >"$LOCK") 2>/dev/null
}

emit_checks_changed() {
  printf '%s\n' "$CSIG" >"$VSTATE/sig.tsv"
  printf 'CHECKS-CHANGED\nA checks.md appeared or changed; re-read the checks (run: list).\n'
}

cmd_wait() {
  if [ "${WB_VERIFY_WATCHER:-}" != 1 ]; then
    echo BAD-LAUNCH
    echo "This session was not started by the verify-behaviour function (WB_VERIFY_WATCHER is unset). Quit and relaunch with: verify-behaviour"
    return 0
  fi
  mkdir -p "$VSTATE"
  if ! acquire_lock; then
    echo ALREADY-ARMED
    echo "Another wait is running (lock: $LOCK). Do nothing."
    return 0
  fi
  W="$(mktemp -d "$VSTATE/tmp.XXXXXX")"
  trap cleanup EXIT
  trap 'exit 0' TERM INT
  : >>"$PENDING"; : >>"$HITSEEN"; : >"$W/newpos"
  local parent sigold="$VSTATE/sig.tsv" prevw
  parent="$(find_parent)"

  # Undelivered hits first (KTD7): events from an interrupted turn are not lost.
  if deliver; then return 0; fi

  load_checks
  stat_all
  if [ ! -f "$VSTATE/primed" ]; then baseline_new; date +%s >"$VSTATE/primed"; fi
  first_live_scans
  if [ "$NEWHITS" -gt 0 ] && deliver; then return 0; fi

  # Checks changed while no wait was running (a new feature, an edit).
  if [ -f "$sigold" ] && [ "$(<"$sigold")" != "$CSIG" ]; then
    emit_checks_changed
    return 0
  fi
  printf '%s\n' "$CSIG" >"$sigold"
  echo "$$" >"$VSTATE/ready"

  # An idle pass is a sleep, one stat call and a string compare. The first pass
  # always reads positions (nothing compared yet), so growth between waits is seen.
  local oldc="$CSIG" oldv="$VSIG"
  prevw=""; LASTRAW=$'\001'
  while :; do
    if ! alive "$parent"; then
      printf 'PARENT-GONE\nThe Claude process that armed this wait (pid %s) is gone.\n' "$parent"
      return 0
    fi
    sleep "$POLL"
    stat_all
    [ "$STATCHG" = 0 ] && continue
    if [ "$CSIG" != "$oldc" ]; then emit_checks_changed; return 0; fi
    # A verdict (or reopen) changes which checks are armed, without waking us.
    if [ "$VSIG" != "$oldv" ]; then oldv="$VSIG"; load_checks; stat_all; baseline_new; fi
    [ "$WRAW" = "$prevw" ] && continue
    prevw="$WRAW"
    NEWHITS=0
    process_changed
    if [ "$NEWHITS" -gt 0 ]; then
      merge_positions
      deliver && return 0
    fi
    merge_positions
  done
}

cmd_status() {
  local pid st
  echo STATUS
  if [ -f "$LOCK" ] && read -r pid st <"$LOCK" && alive "$pid"; then echo "armed: yes (pid $pid)"; else echo "armed: no"; fi
  if [ -s "$PENDING" ]; then
    echo "unacked: $(wc -l <"$PENDING" | tr -d ' ')"
    awk -F"$SEP" '{ print "[" ($2 == 0 ? "undelivered" : "delivered") "] " $3 }' "$PENDING"
  else
    echo "unacked: 0"
  fi
}

cmd_ack() {
  local id="${1:-}"
  [ -n "$id" ] || { echo "usage: verify-wait.sh ack <hit-id>" >&2; return 1; }
  mkdir -p "$VSTATE"; touch "$PENDING"
  plock
  if ! awk -F"$SEP" -v id="$id" '$1 == id { f = 1 } END { exit !f }' "$PENDING"; then
    punlock; echo "ack: no pending hit $id" >&2; return 1
  fi
  awk -F"$SEP" -v id="$id" '$1 != id' "$PENDING" >"$PENDING.tmp" && mv "$PENDING.tmp" "$PENDING"
  punlock
  echo "acked $id"
}

cmd_list() {
  W="$(mktemp -d "${TMPDIR:-/tmp}/verify-list.XXXXXX")"; trap cleanup EXIT
  load_checks
  local cf feature ep id title state age m s
  while IFS="$SEP" read -r cf feature ep id title state; do
    age=""
    if [ "$state" = waiting ]; then
      m="$(fmtime "$cf")"; s=$(($(date +%s) - m))
      if [ "$s" -ge 86400 ]; then age=" waiting_for=$((s / 86400))d$(((s % 86400) / 3600))h"
      elif [ "$s" -ge 3600 ]; then age=" waiting_for=$((s / 3600))h$(((s % 3600) / 60))m"
      else age=" waiting_for=$((s / 60))m"; fi
    fi
    printf 'state=%s feature=%s check=%s%s checks=%s title=%s\n' "$state" "$feature" "$id" "$age" "$cf" "$title"
  done <"$W/c.tsv"
}

cmd_record() {
  if [ "$#" -lt 5 ]; then echo "usage: verify-wait.sh record <checks-file> <id> <state> <quote> <source>" >&2; return 1; fi
  local cf="$1" id="$2" state="$3" quote="$4" source="$5" feature line vf tmp wb n
  case "$state" in
    open | partial | proposed | met | broken) ;;
    *) echo "record: state must be open|partial|proposed|met|broken (waiting is derived, never recorded)" >&2; return 1 ;;
  esac
  [ -f "$cf" ] || { echo "record: no such checks file $cf" >&2; return 1; }
  feature="$(parse_checks "$cf" | awk -F"$SEP" -v id="$id" '$1 == "C" && $5 == id { print $3; exit }')"
  [ -n "$feature" ] || { echo "record: check '$id' not found in $cf" >&2; return 1; }
  quote="$(printf '%s' "$quote" | tr '\n\t\r' '   ')"
  source="$(printf '%s' "$source" | tr '\n\t\r' '   ' | sed 's/ | / \/ /g')"
  line="- $(now_iso) | $feature/$id | $state | $source | $quote"
  vf="${cf%/*}/verdicts.md"
  tmp="$(mktemp "${cf%/*}/.verdicts.XXXXXX")"
  { [ -f "$vf" ] && cat "$vf"; printf '%s\n' "$line"; } >"$tmp" && mv "$tmp" "$vf"

  wb="${WB_BIN:-}"
  if [ -z "$wb" ]; then
    if command -v wb >/dev/null 2>&1; then wb=wb; else wb="$HOME/.config/scripts/tmux/wb.sh"; fi
  fi
  "$wb" append "$WATCHER" Verdicts "$line" >/dev/null || echo "record: wb append failed; the verdict is in $vf only" >&2

  case "$state" in
    broken | proposed)
      # The count is whatever the status bar option holds, so a tmux restart
      # (which clears the option) cannot leave a stale count behind.
      n="$(tmux show -gv @verify_alert 2>/dev/null)"
      case "$n" in '' | *[!0-9]*) n=0 ;; esac
      tmux set -g @verify_alert "$((n + 1))" >/dev/null 2>&1 || true ;;
  esac
  echo "recorded: $line"
}

cmd_seen() {
  tmux set -gu @verify_alert >/dev/null 2>&1 || true
}

cmd_scan() {
  if [ "${1:-}" != "--since" ] || [ -z "${2:-}" ] || [ -z "${3:-}" ]; then
    echo "usage: verify-wait.sh scan --since <time> <checks-file>" >&2; return 1
  fi
  local since cf="$3"
  since="$(iso_epoch "$2")"; [ -n "$since" ] || since="$2"
  case "$since" in *[!0-9]*) echo "scan: cannot parse time '$2'" >&2; return 1 ;; esac
  [ -f "$cf" ] || { echo "scan: no such checks file $cf" >&2; return 1; }
  W="$(mktemp -d "${TMPDIR:-/tmp}/verify-scan.XXXXXX")"; trap cleanup EXIT
  load_checks
  echo SCAN
  scan_collect "$cf" "$since" "open|partial|waiting"
}

cmd_selftest() {
  local f missing="" k n=0 allkeys=""
  while IFS= read -r f; do
    n=$((n + 1))
    allkeys="$allkeys $(tail -n 3000 "$f" | jq -r 'select(type == "object") | keys_unsorted[]' 2>/dev/null | sort -u | tr '\n' ' ')"
  done < <(ls -t "$PROJ"/*/*.jsonl 2>/dev/null | head -n 10)
  if [ "$n" -eq 0 ]; then echo "SELFTEST-FAIL no transcripts under $PROJ"; return 1; fi
  for k in type message origin attachment; do
    case " $allkeys " in *" $k "*) ;; *) missing="$missing $k" ;; esac
  done
  if [ -n "$missing" ]; then
    echo "SELFTEST-FAIL transcript keys missing:$missing (transcript triggers can't be trusted)"
    return 1
  fi
  echo "SELFTEST-OK keys type message origin attachment present in the newest $n transcripts"
}

case "${1:-}" in
  wait) shift; cmd_wait "$@" ;;
  status) shift; cmd_status "$@" ;;
  list) shift; cmd_list "$@" ;;
  ack) shift; cmd_ack "$@" ;;
  record) shift; cmd_record "$@" ;;
  seen) shift; cmd_seen "$@" ;;
  scan) shift; cmd_scan "$@" ;;
  selftest) shift; cmd_selftest "$@" ;;
  *) echo "usage: verify-wait.sh wait|status|list|ack <id>|record <checks> <id> <state> <quote> <source>|seen|scan --since <time> <checks>|selftest" >&2; exit 2 ;;
esac
