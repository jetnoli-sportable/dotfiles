#!/usr/bin/env bash
# wb-migrate.sh — `wb migrate <task>|--all [--dry-run]` (U11, KTD22): the
# one-off conversion of a task file from the old single-file shape into the
# dossier layout (R31). Sourced by wb.sh the same way it sources wb-locks.sh;
# side-effect-free on source (functions only). Everything it needs from wb.sh
# (the U10 writers `_wb_dossier_dir`, `_wb_record_write_file`,
# `_wb_handoff_move_entry`, `_wb_write_atomic`, `wb_render_views`, the lock and
# frontmatter helpers) is looked up at call time, so source order does not
# matter.
#
# Safety model. A migrated file must be byte-shaped like one the live writers
# produce, and NOTHING may be lost. So per task the command:
#   1. takes the task's own lock (a held lock skips the task and lists it),
#   2. parses the three history sections fence-aware into a scratch directory
#      (never into the store),
#   3. writes every record file into a scratch copy of the dossier using the
#      very same U10 helpers the live writers use,
#   4. re-counts: "before" figures come from the raw text with plain grep (not
#      the parser), "after" figures from the files just written, and the
#      non-blank lines of every section are re-added up from the written
#      files. Any mismatch, any line the parser could not attribute, and any
#      other blocking condition leaves the task UNMIGRATED (nothing written)
#      and lists it as an exception,
#   5. only then moves the scratch dirs into dossiers/<stem>/, renames
#      CONCEPTS.md to concepts.md (KTD24), rewrites the task file, and
#      rebuilds the generated views once.
# A task that already has `layout: dossier` is skipped untouched, so a second
# run changes no byte. `--dry-run` does steps 2-4 and stops: no lock, no store
# write of any kind (not even a dossier directory).
#
# Awk is POSIX only (gawk and mawk both run in the test sandbox): no gensub,
# asort, PROCINFO or {n} intervals, and strings reach awk through ENVIRON
# (never -v, which would process backslash escapes).

# ---------------------------------------------------------------------------
# awk: shared library, fence-aware line classifiers
# ---------------------------------------------------------------------------

# _wb_mg_awk_lib — awk function definitions shared by the three section
# splitters, printed on stdout. Kept in a function (not a global string)
# because a sourced file with `set -e` active must not run a bare `read -d`.
_wb_mg_awk_lib() {
  cat <<'AWK'
function isdate(s) { return s ~ /^[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]/ }
function ltrim(s) { sub(/^[ \t]+/, "", s); return s }
function rtrim(s) { sub(/[ \t]+$/, "", s); return s }
function trim(s) { return rtrim(ltrim(s)) }

# skipsep(s): drop a leading "(who)" group and one separator (em dash, en
# dash, hyphen, colon or comma), then leading blanks.
function skipsep(s) {
  s = ltrim(s)
  if (s ~ /^\([^)]*\)/) { sub(/^\([^)]*\)/, "", s); s = ltrim(s) }
  if (s ~ /^(—|–)/) sub(/^(—|–)/, "", s)
  else if (s ~ /^[-:,]/) sub(/^[-:,]/, "", s)
  return ltrim(s)
}

# firstclause(s): s up to the first ". ", ": ", "; " or " — ", trailing
# punctuation trimmed. Used when an entry has no bold lead to name it.
function firstclause(s,   cut, p, i, d) {
  cut = length(s) + 1
  for (i = 1; i <= 4; i++) {
    d = (i == 1 ? ". " : (i == 2 ? ": " : (i == 3 ? "; " : " — ")))
    p = index(s, d)
    if (p > 0 && p < cut) cut = p
  }
  s = substr(s, 1, cut - 1)
  sub(/[ \t.:;,]+$/, "", s)
  return s
}

# stamp(s): s begins with a date. Sets sdate, shm (HHMM or "") and srest (the
# text after the date and optional " HH:MM").
function stamp(s) {
  sdate = substr(s, 1, 10); srest = substr(s, 11); shm = ""
  if (srest ~ /^ [0-9][0-9]:[0-9][0-9]/ && substr(srest, 7, 1) !~ /[0-9]/) {
    shm = substr(srest, 2, 2) substr(srest, 5, 2)
    srest = substr(srest, 7)
  }
}

# fence_event(line): a Markdown fence opens on ``` or ~~~ (up to 3 spaces of
# indent) and closes on the same character, at least as long, with nothing
# after it. Returns 1 for an opening line, 2 for a closing line, else 0;
# infence tracks the state between calls.
function fence_event(line,   rest, c, k) {
  match(line, /^ */)
  if (RLENGTH > 3) return 0
  rest = substr(line, RLENGTH + 1)
  c = substr(rest, 1, 1)
  if (c != "`" && c != "~") return 0
  k = 1
  while (substr(rest, k + 1, 1) == c) k++
  if (k < 3) return 0
  if (!infence) { infence = 1; fchar = c; flen = k; return 1 }
  if (c == fchar && k >= flen && substr(rest, k + 1) ~ /^[ \t]*$/) { infence = 0; return 2 }
  return 0
}
AWK
}

# ---------------------------------------------------------------------------
# section map
# ---------------------------------------------------------------------------

# _wb_mg_sections <task_file> — structure of a task file, tab-separated:
# `FM<TAB><n>` (line number of the frontmatter's closing ---; 0 when the file
# has no frontmatter at byte 0) then one `H<TAB><line><TAB><name>` per "## "
# heading. A "## " line inside a ``` or ~~~ fence is not a heading, and a
# heading needs a blank line before it (the same guard U10's section helpers
# use); the first body line after the frontmatter counts as preceded by one.
_wb_mg_sections() {
  awk "$(_wb_mg_sections_prog)" "$1"
}

# ---------------------------------------------------------------------------
# section splitters (awk): write entry files into a scratch dir, print facts
# ---------------------------------------------------------------------------

# _wb_mg_split_decisions <section_file> <first_line_no> <outdir> <created>
# — split the body of "## Decisions" into entries, in the four written styles
# of KTD22 (A: `DATE — text`; B: `### DATE HH:MM — title`; C: `DATE
# decision-page <slug> rN: …`; D: a dated top-level bullet, bold or plain).
# Writes outdir/d<NNNN>.txt (the entry's lines, verbatim, first line = its
# start line) and outdir/markers.txt (`_No decisions:` lines). Prints
#   E <n> <style> <line> <date> <hm> <flags> <title>   one per entry
#   S <line> <n>                                       a (supersedes: marker
#   M <line>                                           a no-decisions marker
#   U <line>                                           a line no entry owns
# flags: d = date inherited from the previous entry, t = time stamped
# 0000, 0001… (or "-" for none). Continuation rules: a bullet entry (D) owns
# only its indented lines; A, B and C entries own every line up to the next
# entry start. Fence lines always belong to the open entry.
_wb_mg_split_decisions() {
  WB_MG_BASE="$2" WB_MG_DIR="$3" WB_MG_CREATED="$4" awk "$(_wb_mg_awk_lib)"$'\n'"$(cat <<'AWK'
function kind_of(line,   s) {
  if (line ~ /^### /) return "B"
  s = line; kbullet = 0; kbold = 0
  if (s ~ /^- /) { kbullet = 1; s = substr(s, 3) }
  if (s ~ /^\*\*[0-9][0-9][0-9][0-9]-/) { kbold = 1; s = substr(s, 3) }
  if (!isdate(s)) return ""
  kstr = s
  return (kbullet ? "D" : "A")
}
function clean(t) {
  gsub(/\*\*/, "", t); gsub(/\t/, " ", t)
  sub(/[ \t.:;,]+$/, "", t)
  return trim(t)
}
function open_entry(k, line, lineno,   style, t, p, d, hm, flags) {
  if (cur) close(efile)
  n++; cur = n; curstyle = k
  efile = sprintf("%s/d%04d.txt", dir, n)
  flags = ""
  if (k == "B") {
    style = "B"
    t = trim(substr(line, 5))
    if (isdate(t)) {
      stamp(t); d = sdate; hm = shm
      t = ltrim(srest)
      if (t ~ /^(—|–|-)/) sub(/^(—|–|-)/, "", t)
      t = trim(t)
      if (t == "") t = trim(substr(line, 5))
    } else { d = ""; hm = "" }
    t = clean(t)
  } else {
    style = k
    stamp(kstr); d = sdate; hm = shm
    if (k == "A" && srest ~ /^ decision-page /) style = "C"
    if (style == "C") {
      t = substr(srest, 16); p = index(t, ":")
      if (p > 0) t = substr(t, 1, p - 1); else t = firstclause(t)
    } else {
      t = skipsep(srest)
      if (kbold) { p = index(t, "**"); if (p > 0) t = substr(t, 1, p - 1); else t = firstclause(t) }
      else if (t ~ /^\*\*/) { t = substr(t, 3); p = index(t, "**"); if (p > 0) t = substr(t, 1, p - 1); else t = firstclause(t) }
      else t = firstclause(t)
    }
    t = clean(t)
  }
  if (t == "") t = clean(substr(line, 1, 80))
  if (d == "") { d = prevdate; flags = flags "d" } else prevdate = d
  if (hm == "") { hm = sprintf("%04d", cnt[d]++); flags = flags "t" }
  if (flags == "") flags = "-"
  print "E\t" n "\t" style "\t" lineno "\t" d "\t" hm "\t" flags "\t" t
}
function put(line, lineno) {
  print line > efile
  if (index(tolower(line), "(supersedes:") > 0) print "S\t" lineno "\t" cur
}
BEGIN { base = ENVIRON["WB_MG_BASE"] + 0; dir = ENVIRON["WB_MG_DIR"]
        prevdate = ENVIRON["WB_MG_CREATED"]; n = 0; cur = 0; infence = 0
        mfile = dir "/markers.txt"; printf "" > mfile }
{
  lineno = base + FNR - 1; line = $0
  ev = fence_event(line)
  if (ev != 0 || infence) {
    if (cur) put(line, lineno); else print "U\t" lineno
    next
  }
  if (line ~ /^[ \t]*$/) { if (cur) put(line, lineno); next }
  m = line; sub(/^- /, "", m)
  if (line ~ /^[^ \t]/ && m ~ /^_No decisions:/) {
    if (cur) close(efile)
    cur = 0; print line >> mfile; print "M\t" lineno; next
  }
  k = ""
  if (line ~ /^[^ \t]/) k = kind_of(line)
  if (k != "") { open_entry(k, line, lineno); put(line, lineno); next }
  if (cur == 0) { print "U\t" lineno; next }
  if (curstyle == "D" && line ~ /^[^ \t]/) { print "U\t" lineno; next }
  put(line, lineno)
}
END { if (cur) close(efile); close(mfile) }
AWK
)" "$1"
}

# _wb_mg_split_handoffs <section_file> <first_line_no> <outdir> <created> —
# split the body of "## Handoffs" at every top-level "### " heading outside a
# fence. Writes outdir/h<NNNN>.txt (heading line first, verbatim) and
# outdir/h-pre.txt (anything before the first heading). Prints
#   E <n> <line> <date> <hm> <flags>
# with the same date-inheritance and 0000, 0001… stamping rules as decisions;
# the date and time are only used by the caller as a fallback when the
# heading is not the standard `### YYYY-MM-DD HH:MM — source` shape.
_wb_mg_split_handoffs() {
  WB_MG_BASE="$2" WB_MG_DIR="$3" WB_MG_CREATED="$4" awk "$(_wb_mg_awk_lib)"$'\n'"$(cat <<'AWK'
function open_entry(line, lineno,   t, d, hm, flags) {
  if (cur) close(efile)
  n++; cur = n
  efile = sprintf("%s/h%04d.txt", dir, n)
  t = trim(substr(line, 5)); flags = ""; d = ""; hm = ""
  if (isdate(t)) { stamp(t); d = sdate; hm = shm }
  if (d == "") { d = prevdate; flags = flags "d" } else prevdate = d
  if (hm == "") { hm = sprintf("%04d", cnt[d]++); flags = flags "t" }
  if (flags == "") flags = "-"
  print "E\t" n "\t" lineno "\t" d "\t" hm "\t" flags
}
function put(line) { if (cur) print line > efile; else print line >> pre }
BEGIN { base = ENVIRON["WB_MG_BASE"] + 0; dir = ENVIRON["WB_MG_DIR"]
        prevdate = ENVIRON["WB_MG_CREATED"]; n = 0; cur = 0; infence = 0
        pre = dir "/h-pre.txt"; printf "" > pre }
{
  lineno = base + FNR - 1; line = $0
  ev = fence_event(line)
  if (ev != 0 || infence) { put(line); next }
  if (line ~ /^### /) { open_entry(line, lineno); put(line); next }
  put(line)
}
END { if (cur) close(efile); close(pre) }
AWK
)" "$1"
}

# _wb_mg_split_followups <section_file> <first_line_no> <outdir> — split the
# body of "## Follow-ups" into checkbox items (`- [ ]` open, `- [x]` ticked, a
# top-level line outside a fence). Writes outdir/i<NNNN>.txt (the item's
# lines, verbatim) and outdir/f-pre.txt (non-blank lines before the first
# item). Prints
#   I <n> <open|done> <line> <date> <title>
# date is the first YYYY-MM-DD in the item's first line (or "-"); title is
# its first clause with the checkbox and bold marks removed;
#   S <line>   a top-level non-checkbox line attached to the preceding item
#   P <line>   a non-blank line before any item (goes to the history file)
_wb_mg_split_followups() {
  WB_MG_BASE="$2" WB_MG_DIR="$3" awk "$(_wb_mg_awk_lib)"$'\n'"$(cat <<'AWK'
function put(line, lineno) {
  if (cur) {
    print line > efile
    if (line ~ /^[^ \t]/ && !infence) print "S\t" lineno
  } else if (line !~ /^[ \t]*$/) {
    print line >> pre; print "P\t" lineno
  }
}
BEGIN { base = ENVIRON["WB_MG_BASE"] + 0; dir = ENVIRON["WB_MG_DIR"]
        n = 0; cur = 0; infence = 0
        pre = dir "/f-pre.txt"; printf "" > pre }
{
  lineno = base + FNR - 1; line = $0
  ev = fence_event(line)
  if (ev != 0 || infence) {
    if (cur) print line > efile; else { print line >> pre; print "P\t" lineno }
    next
  }
  if (line ~ /^[-*] \[[ xX]\]/) {
    if (cur) close(efile)
    n++; cur = n
    efile = sprintf("%s/i%04d.txt", dir, n)
    kind = (substr(line, 4, 1) == " " ? "open" : "done")
    t = substr(line, 7)
    gsub(/\*\*/, "", t); gsub(/\t/, " ", t)
    t = trim(t)
    if (isdate(t)) t = skipsep(substr(t, 11))
    t = firstclause(t); if (t == "") t = trim(substr(line, 7))
    d = "-"
    if (match(line, /[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]/)) d = substr(line, RSTART, 10)
    print "I\t" n "\t" kind "\t" lineno "\t" d "\t" t
    print line > efile
    next
  }
  put(line, lineno)
}
END { if (cur) close(efile); close(pre) }
AWK
)" "$1"
}

# ---------------------------------------------------------------------------
# small helpers
# ---------------------------------------------------------------------------

# _wb_mg_nb <file> — number of lines in <file> with a non-blank character.
_wb_mg_nb() {
  local n; n="$(grep -c '[^[:space:]]' "$1" 2>/dev/null || true)"
  printf '%s\n' "${n:-0}"
}

# _wb_mg_body_nb <record_file> — non-blank lines of a record file after its
# frontmatter block (the block at byte 0, closed by the next --- line).
_wb_mg_body_nb() {
  awk '
    NR == 1 && $0 == "---" { fm = 1; next }
    fm == 1 { if ($0 == "---") fm = 2; next }
    $0 ~ /[^ \t]/ { n++ }
    END { print n + 0 }
  ' "$1"
}

# _wb_mg_count_md <dir> — number of *.md files directly in <dir> (0 when the
# dir does not exist). Never fails, so a caller under `set -e` is safe.
_wb_mg_count_md() {
  local n; n="$(find "$1" -maxdepth 1 -type f -name '*.md' 2>/dev/null | wc -l | tr -d ' ' || true)"
  printf '%s\n' "${n:-0}"
}

# _wb_mg_clip <title> — at most 100 characters, cut back to a word boundary
# when it had to be cut; "untitled" when empty.
_wb_mg_clip() {
  local t="$1"
  if [ -z "$t" ]; then printf 'untitled\n'; return 0; fi
  if [ "${#t}" -gt 100 ]; then
    t="${t:0:100}"
    if [[ "$t" == *" "* ]]; then t="${t% *}"; fi
  fi
  printf '%s\n' "$t"
}

# _wb_mg_cleanup <dir> — remove a scratch dir this command made, and only
# when it is one (under the scratch root, wb-migrate.* name).
_wb_mg_cleanup() {
  case "$1" in
    "$_WB_MG_TMPROOT"/wb-migrate.*) rm -rf -- "$1" ;;
  esac
}

# _wb_mg_exc <message> — record an exception for the task being migrated.
# Messages are reported at the end of the run; each one also counts in the
# task's count line.
_wb_mg_exc() {
  WB_MG_EXC+=("$_WB_MG_STEM: $1")
  _WB_MG_TASK_EXC=$((_WB_MG_TASK_EXC + 1))
}

# _wb_mg_block <message> — an exception that also stops this task: nothing
# is written for it.
_wb_mg_block() {
  _wb_mg_exc "$1"
  _WB_MG_BLOCKED=1
}

# _wb_mg_hist_counts <history_file> — facts about a migrated-history file,
# one `key N` line each: ticked (checkbox items under "#### Ticked
# follow-ups"), markers (`_No decisions:` lines under "#### No decisions"),
# and the non-blank line count of each block (nb_ticked, nb_fnotes,
# nb_markers, nb_pre, nb_done). Blocks are found by their exact heading line.
_wb_mg_hist_counts() {
  awk '
    $0 == "#### Ticked follow-ups" { b = "ticked"; next }
    $0 == "#### Follow-ups notes" { b = "fnotes"; next }
    $0 == "#### No decisions" { b = "markers"; next }
    $0 == "#### Handoffs preamble" { b = "pre"; next }
    $0 == "#### Done" { b = "done"; next }
    b != "" && $0 ~ /[^ \t]/ {
      nb[b]++
      if (b == "ticked" && $0 ~ /^[-*] \[[xX]\]/) ticked++
      if (b == "markers" && ($0 ~ /^_No decisions:/ || $0 ~ /^- _No decisions:/)) markers++
    }
    END {
      print "ticked " ticked + 0; print "markers " markers + 0
      print "nb_ticked " nb["ticked"] + 0; print "nb_fnotes " nb["fnotes"] + 0
      print "nb_markers " nb["markers"] + 0; print "nb_pre " nb["pre"] + 0
      print "nb_done " nb["done"] + 0
    }
  ' "$1"
}

# ---------------------------------------------------------------------------
# one task
# ---------------------------------------------------------------------------

# _wb_mg_convert <task_file> <dry:0|1> — parse, write into a scratch store,
# verify, and (unless dry) commit one task. CALLER HOLDS THE TASK LOCK (or is
# a dry run). Sets WB_MG_RESULT to migrated | blocked | already, prints the
# count line, and records exceptions through _wb_mg_exc / _wb_mg_block.
_wb_mg_convert() {
  local file="$1" dry="$2"
  local stem="${file##*/}"; stem="${stem%.md}"
  _WB_MG_STEM="$stem"; _WB_MG_TASK_EXC=0; _WB_MG_BLOCKED=0
  WB_MG_RESULT="migrated"
  local tag=""; [ "$dry" -eq 0 ] || tag="[dry-run] "

  if _wb_is_dossier "$file"; then
    WB_MG_RESULT="already"
    echo "wb migrate: ${tag}$stem  already layout: dossier, skipped"
    return 0
  fi

  local work; work="$(mktemp -d "$_WB_MG_TMPROOT/wb-migrate.XXXXXX")" || { _wb_mg_block "could not make a scratch directory"; WB_MG_RESULT="blocked"; return 0; }
  # (The scratch dir is removed on every path out of this function by the
  # wrapper below, so the early `return`s here need no cleanup of their own.)
  _WB_MG_WORK="$work"
  mkdir -p "$work/dec" "$work/hnd" "$work/fol" "$work/store"

  local total; total="$(awk 'END { print NR }' "$file")"

  # ---- section map --------------------------------------------------------
  local fmend=-1 kind a b
  local -a hl=() hn=()
  while IFS=$'\t' read -r kind a b; do
    case "$kind" in
      FM) fmend="$a" ;;
      H)  hl+=("$a"); hn+=("$b") ;;
    esac
  done < <(_wb_mg_sections "$file")
  if [ "$fmend" -lt 1 ]; then
    _wb_mg_block "no closed frontmatter block at byte 0; cannot add layout:"
    WB_MG_RESULT="blocked"
    _wb_mg_count_line "$tag" 0 0 0 0 0 0 0 0
    return 0
  fi
  local nsec="${#hl[@]}"
  local i end_i
  # first occurrence of each known section; later duplicates stay in place
  local i_now=-1 i_plan=-1 i_hand=-1 i_dec=-1 i_fol=-1 i_done=-1
  local -a role=()
  for ((i = 0; i < nsec; i++)); do
    role[i]="keep"
    case "${hn[i]}" in
      Now)        if [ "$i_now"  -lt 0 ]; then i_now=$i;  role[i]="now";  fi ;;
      Plan)       if [ "$i_plan" -lt 0 ]; then i_plan=$i; role[i]="plan"; fi ;;
      Handoffs)   if [ "$i_hand" -lt 0 ]; then i_hand=$i; role[i]="hand"; fi ;;
      Decisions)  if [ "$i_dec"  -lt 0 ]; then i_dec=$i;  role[i]="dec";  fi ;;
      Follow-ups) if [ "$i_fol"  -lt 0 ]; then i_fol=$i;  role[i]="fol";  fi ;;
      Done)       if [ "$i_done" -lt 0 ]; then i_done=$i; role[i]="done"; fi ;;
    esac
    if [ "${role[i]}" = "keep" ]; then
      _wb_mg_exc "section '## ${hn[i]}' (line ${hl[i]}) is not part of the layout; kept in the task file where it is"
    fi
  done
  # content range of section i: first line after its heading .. last line before the next heading
  _wb_mg_range() { # <i> -> "first last" (first > last when empty)
    local j="$1" nxt
    if [ $((j + 1)) -lt "$nsec" ]; then nxt=$((hl[j + 1] - 1)); else nxt="$total"; fi
    printf '%s %s\n' "$((hl[j] + 1))" "$nxt"
  }

  # ---- created date -------------------------------------------------------
  local created; created="$(wb_get_frontmatter "$file" created)"
  created="${created%%[[:space:]]#*}"; created="${created//[[:space:]]/}"; created="${created:0:10}"
  if [[ ! "$created" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]]; then
    created="$(date '+%Y-%m-%d')"
    _wb_mg_exc "no valid created: date in the frontmatter; today's date ($created) used for the history file name and as the default date"
  fi

  # ---- section texts ------------------------------------------------------
  local r first last
  local dec_text="" hand_text="" fol_text="" done_text=""
  local dec_first=0 hand_first=0 fol_first=0
  if [ "$i_dec" -ge 0 ];  then r="$(_wb_mg_range "$i_dec")";  read -r first last <<< "$r"; dec_first="$first";  sed -n "${first},${last}p" "$file" > "$work/dec.sec"; fi
  if [ "$i_hand" -ge 0 ]; then r="$(_wb_mg_range "$i_hand")"; read -r first last <<< "$r"; hand_first="$first"; sed -n "${first},${last}p" "$file" > "$work/hnd.sec"; fi
  if [ "$i_fol" -ge 0 ];  then r="$(_wb_mg_range "$i_fol")";  read -r first last <<< "$r"; fol_first="$first";  sed -n "${first},${last}p" "$file" > "$work/fol.sec"; fi
  if [ "$i_done" -ge 0 ]; then r="$(_wb_mg_range "$i_done")"; read -r first last <<< "$r"; sed -n "${first},${last}p" "$file" > "$work/done.sec"; fi
  local sec
  for sec in dec hnd fol done; do [ -f "$work/$sec.sec" ] || : > "$work/$sec.sec"; done

  # ---- "before" counts: raw text, no parser -------------------------------
  local dec_before hand_before open_before ticked_before marker_before done_nb
  dec_before="$(grep -cE '^(- )?(\*\*)?[0-9]{4}-[0-9]{2}-[0-9]{2}|^### ' "$work/dec.sec" || true)"
  hand_before="$(grep -c '^### ' "$work/hnd.sec" || true)"
  open_before="$(grep -cE '^[-*] \[ \]' "$work/fol.sec" || true)"
  ticked_before="$(grep -cE '^[-*] \[[xX]\]' "$work/fol.sec" || true)"
  marker_before="$(grep -cE '^(- )?_No decisions:' "$work/dec.sec" || true)"
  done_nb="$(_wb_mg_nb "$work/done.sec")"
  local hist_before=$((ticked_before + marker_before))

  # ---- parse: decisions ---------------------------------------------------
  local -a d_style=() d_line=() d_date=() d_hm=() d_flags=() d_title=()
  local nd=0 meta_tag n style ln date hm flags title
  local -a unattr=()
  : > "$work/dec.meta"
  _wb_mg_split_decisions "$work/dec.sec" "$dec_first" "$work/dec" "$created" > "$work/dec.meta"
  while IFS=$'\t' read -r meta_tag n style ln date hm flags title; do
    case "$meta_tag" in
      E) nd=$((nd + 1)); d_style[n]="$style"; d_line[n]="$ln"; d_date[n]="$date"; d_hm[n]="$hm"; d_flags[n]="$flags"; d_title[n]="$title" ;;
      U) unattr+=("$n") ;;
      S) _wb_mg_exc "line $n: prose (supersedes: …) marker kept as raw text in the new decision's body; decision stays in-force, link it by hand with wb decide-supersede" ;;
    esac
  done < "$work/dec.meta"
  if [ "${#unattr[@]}" -gt 0 ]; then
    _wb_mg_block "## Decisions has ${#unattr[@]} line(s) that fit no entry style (task line numbers: ${unattr[*]})"
  fi
  local nmark; nmark="$(_wb_mg_nb "$work/dec/markers.txt")"
  local nodate_lines="" notime_lines=""
  for ((i = 1; i <= nd; i++)); do
    if [[ "${d_flags[i]}" == *d* ]]; then nodate_lines+=" ${d_line[i]}"; fi
    if [[ "${d_flags[i]}" == *t* ]]; then notime_lines+=" ${d_line[i]}"; fi
  done
  if [ -n "$nodate_lines" ]; then _wb_mg_exc "decisions with no date took the previous entry's date (task lines:$nodate_lines)"; fi
  if [ -n "$notime_lines" ]; then _wb_mg_exc "decisions with no time were stamped <date> 0000, 0001, … in file order (task lines:$notime_lines)"; fi

  # ---- parse: handoffs ----------------------------------------------------
  local -a h_line=() h_date=() h_hm=() h_flags=()
  local nh=0 hnodate="" hnotime=""
  : > "$work/hnd.meta"
  _wb_mg_split_handoffs "$work/hnd.sec" "$hand_first" "$work/hnd" "$created" > "$work/hnd.meta"
  while IFS=$'\t' read -r meta_tag n ln date hm flags; do
    [ "$meta_tag" = "E" ] || continue
    nh=$((nh + 1)); h_line[n]="$ln"; h_date[n]="$date"; h_hm[n]="$hm"; h_flags[n]="$flags"
    if [[ "$flags" == *d* ]]; then hnodate+=" $ln"; fi
    if [[ "$flags" == *t* ]]; then hnotime+=" $ln"; fi
  done < "$work/hnd.meta"
  if [ -n "$hnodate" ]; then _wb_mg_exc "handoffs with no date took the previous entry's date (task lines:$hnodate)"; fi
  if [ -n "$hnotime" ]; then _wb_mg_exc "handoffs whose heading has no HH:MM were stamped <date> 0000, 0001, … in file order (task lines:$hnotime)"; fi
  local hpre_nb; hpre_nb="$(_wb_mg_nb "$work/hnd/h-pre.txt")"
  if [ "$nh" -eq 0 ] && [ "$(_wb_mg_nb "$work/hnd.sec")" -gt 0 ]; then
    _wb_mg_exc "## Handoffs has text but no '### ' entry headings; left in the task file as it is"
  elif [ "$hpre_nb" -gt 0 ]; then
    _wb_mg_exc "## Handoffs has $hpre_nb non-blank line(s) before its first '### ' heading; moved to the migrated-history file"
  fi

  # ---- parse: follow-ups --------------------------------------------------
  local nf=0 nopen=0 ndone=0 ticked_nb=0
  local -a strays=() pres=()
  : > "$work/fol.meta"
  _wb_mg_split_followups "$work/fol.sec" "$fol_first" "$work/fol" > "$work/fol.meta"
  while IFS=$'\t' read -r meta_tag n style ln date title; do
    case "$meta_tag" in
      I) # fields: I n kind line date title (read into n style ln date title)
         nf=$((nf + 1))
         if [ "$style" = "open" ]; then nopen=$((nopen + 1)); else
           ndone=$((ndone + 1))
           ticked_nb=$((ticked_nb + $(_wb_mg_nb "$work/fol/$(printf 'i%04d.txt' "$n")")))
         fi ;;
      S) strays+=("$n") ;;
      P) pres+=("$n") ;;
    esac
  done < "$work/fol.meta"
  if [ "${#strays[@]}" -gt 0 ]; then
    _wb_mg_exc "## Follow-ups: ${#strays[@]} top-level line(s) that are not checkbox items were attached to the item above them (task lines: ${strays[*]:0:20})"
  fi
  if [ "${#pres[@]}" -gt 0 ]; then
    _wb_mg_exc "## Follow-ups: ${#pres[@]} line(s) before the first checkbox item moved to the migrated-history file (task lines: ${pres[*]:0:20})"
  fi

  # ---- attribution check: every non-blank line owned -----------------------
  local sec_nb own_nb
  sec_nb="$(_wb_mg_nb "$work/dec.sec")"
  own_nb=$nmark
  for ((i = 1; i <= nd; i++)); do own_nb=$((own_nb + $(_wb_mg_nb "$work/dec/$(printf 'd%04d.txt' "$i")"))); done
  own_nb=$((own_nb + ${#unattr[@]}))
  if [ "$sec_nb" -ne "$own_nb" ]; then
    _wb_mg_block "## Decisions: $sec_nb non-blank lines in the section but $own_nb attributed by the parser"
  fi

  # ---- write records into the scratch store ------------------------------
  local dec_after=0 hand_after=0 open_after=0 hist_after=0
  if [ "$_WB_MG_BLOCKED" -eq 0 ]; then
    _wb_mg_emit "$file" "$work" "$stem" "$created" "$nd" "$nh" "$nf" "$i_hand" "$i_done" "$hpre_nb"
    local sdir="$work/store/dossiers/$stem"
    dec_after="$(_wb_mg_count_md "$sdir/decisions")"
    open_after="$(_wb_mg_count_md "$sdir/open-items")"
    local hfiles; hfiles="$(_wb_mg_count_md "$sdir/handoffs")"
    local hist_present=0
    [ -f "$work/hist.id" ] && hist_present=1
    hand_after=$((hfiles - hist_present))
    if [ "$nh" -ge 1 ]; then hand_after=$((hand_after + 1)); fi
    local hk hv hnb_ticked=0 hnb_fnotes=0 hnb_markers=0 hnb_pre=0 hnb_done=0 h_ticked=0 h_markers=0
    if [ "$hist_present" -eq 1 ]; then
      while read -r hk hv; do
        case "$hk" in
          ticked) h_ticked="$hv" ;; markers) h_markers="$hv" ;;
          nb_ticked) hnb_ticked="$hv" ;; nb_fnotes) hnb_fnotes="$hv" ;;
          nb_markers) hnb_markers="$hv" ;; nb_pre) hnb_pre="$hv" ;; nb_done) hnb_done="$hv" ;;
        esac
      done < <(_wb_mg_hist_counts "$sdir/handoffs/$(cat "$work/hist.id").md")
    fi
    hist_after=$((h_ticked + h_markers))

    # lossless checks: re-add the non-blank lines from the files just written
    local f actual expected
    actual=0
    for f in "$sdir"/decisions/*.md; do
      [ -f "$f" ] || continue
      actual=$((actual + $(_wb_mg_body_nb "$f")))
    done
    local nonB=0
    for ((i = 1; i <= nd; i++)); do [ "${d_style[i]}" = "B" ] || nonB=$((nonB + 1)); done
    actual=$((actual - nonB))
    expected=$((sec_nb - nmark))
    if [ "$actual" -ne "$expected" ]; then
      _wb_mg_block "## Decisions lost or gained lines: $expected non-blank lines expected in decision files, $actual found"
    fi
    if [ "$h_markers" -ne "$marker_before" ] || [ "$hnb_markers" -ne "$nmark" ]; then
      _wb_mg_block "## Decisions: $marker_before '_No decisions:' marker line(s) in the source, $h_markers in the history file"
    fi
    if [ "$hnb_done" -ne "$done_nb" ]; then
      _wb_mg_block "## Done: $done_nb non-blank lines in the source, $hnb_done in the history file"
    fi
    if [ "$nh" -ge 1 ]; then
      actual=0
      for f in "$sdir"/handoffs/*.md; do
        [ -f "$f" ] || continue
        [ "$f" = "$sdir/handoffs/$(cat "$work/hist.id" 2>/dev/null).md" ] && continue
        actual=$((actual + $(_wb_mg_body_nb "$f")))
      done
      actual=$((actual + $(_wb_mg_nb "$work/kept.txt") + hnb_pre))
      expected="$(_wb_mg_nb "$work/hnd.sec")"
      if [ "$actual" -ne "$expected" ]; then
        _wb_mg_block "## Handoffs lost or gained lines: $expected non-blank lines in the source, $actual in the written files"
      fi
    fi
    # Follow-ups: parser attribution (items + pre-item lines == section)
    local fol_sec_nb fol_own=0
    fol_sec_nb="$(_wb_mg_nb "$work/fol.sec")"
    for ((i = 1; i <= nf; i++)); do fol_own=$((fol_own + $(_wb_mg_nb "$work/fol/$(printf 'i%04d.txt' "$i")"))); done
    fol_own=$((fol_own + $(_wb_mg_nb "$work/fol/f-pre.txt")))
    if [ "$fol_sec_nb" -ne "$fol_own" ]; then
      _wb_mg_block "## Follow-ups: $fol_sec_nb non-blank lines in the section but $fol_own attributed by the parser"
    fi
    if [ "$h_ticked" -ne "$ticked_before" ] || [ "$hnb_ticked" -ne "$ticked_nb" ] \
       || [ "$hnb_fnotes" -ne "$(_wb_mg_nb "$work/fol/f-pre.txt")" ]; then
      _wb_mg_block "## Follow-ups: $ticked_before ticked item(s) ($ticked_nb non-blank lines) in the source, $h_ticked ($hnb_ticked lines) in the history file"
    fi
  else
    dec_after=$nd; open_after=$nopen; hand_after=$nh; hist_after=$((ndone + nmark))
  fi

  # ---- count comparison ---------------------------------------------------
  if [ "$dec_before" -ne "$dec_after" ] || [ "$hand_before" -ne "$hand_after" ] \
     || [ "$open_before" -ne "$open_after" ] || [ "$hist_before" -ne "$hist_after" ]; then
    if [ "$_WB_MG_BLOCKED" -eq 0 ]; then
      _wb_mg_block "counts before and after do not match (see the count line); source text and parser disagree"
    fi
  fi
  _wb_mg_count_line "$tag" "$dec_before" "$dec_after" "$hand_before" "$hand_after" "$open_before" "$open_after" "$hist_before" "$hist_after"

  if [ "$_WB_MG_BLOCKED" -eq 1 ]; then WB_MG_RESULT="blocked"; return 0; fi
  [ "$dry" -eq 0 ] || return 0

  # ---- commit: dossier dirs, concepts.md, task file -----------------------
  _wb_mg_commit "$file" "$work" "$stem" "$nh" "$i_now" "$i_hand" "$nsec" "$total" "$fmend" || { WB_MG_RESULT="blocked"; return 0; }
}

# _wb_mg_count_line <tag> <dec b a> <hand b a> <open b a> <hist b a> — one
# line per task: each figure is "before/after"; a pair that differs is marked.
_wb_mg_count_line() {
  local tag="$1"; shift
  local out="wb migrate: $tag$_WB_MG_STEM " label pair b a
  local -a labels=(decisions handoffs open-items history)
  local k=0
  while [ $# -ge 2 ]; do
    b="$1"; a="$2"; shift 2
    pair="$b/$a"; [ "$b" = "$a" ] || pair="$pair(MISMATCH)"
    out+=" ${labels[k]} $pair"
    k=$((k + 1))
  done
  out+=" exceptions $_WB_MG_TASK_EXC"
  if [ "$_WB_MG_BLOCKED" -eq 1 ]; then out+=" NOT MIGRATED"; fi
  printf '%s\n' "$out"
}

# _wb_mg_sections_prog — the awk program text behind _wb_mg_sections (so the
# function above can be run with `awk -f`).
_wb_mg_sections_prog() {
  _wb_mg_awk_lib
  cat <<'AWK'
BEGIN { fm = 0; infence = 0; prev = "" }
{
  if (FNR == 1) {
    if ($0 == "---") { fm = 1; next }
    print "FM\t0"; fm = 2
  }
  if (fm == 1) {
    if ($0 == "---") { fm = 2; print "FM\t" FNR; prev = "" }
    next
  }
  ev = fence_event($0)
  if (ev == 0 && !infence && $0 ~ /^## / && prev == "") print "H\t" FNR "\t" trim(substr($0, 4))
  prev = $0
}
END { if (fm == 1) print "FM\t-1" }
AWK
}

# ---------------------------------------------------------------------------
# writing records into the scratch store
# ---------------------------------------------------------------------------

# _wb_mg_emit <task_file> <work> <stem> <created> <nd> <nh> <nf> <i_hand>
#   <i_done> <hpre_nb> — write every record file into $work/store/dossiers/
# <stem>/ using the U10 helpers (so the bytes match what the live writers
# make): decisions/, handoffs/ (every entry but the newest, plus the
# migrated-history file) and open-items/. Leaves the newest handoff's text in
# $work/kept.txt and the history file's id in $work/hist.id. TASKS_DIR is
# overridden (dynamically scoped) so the helpers write into the scratch store.
_wb_mg_emit() {
  local file="$1" work="$2" stem="$3" created="$4" nd="$5" nh="$6" nf="$7" i_hand="$8" i_done="$9" hpre_nb="${10}"
  local TASKS_DIR="$work/store"
  local scratch_task="$TASKS_DIR/$stem.md"
  local sdir="$TASKS_DIR/dossiers/$stem"
  mkdir -p "$sdir/handoffs"
  local i f body text

  # --- decisions: <date>-<hhmm>-<slug>.md; B entries lose their heading line
  # (it becomes the title), every other style keeps its first line in the body
  while IFS=$'\t' read -r meta_tag n style ln date hm flags title; do
    [ "$meta_tag" = "E" ] || continue
    f="$work/dec/$(printf 'd%04d.txt' "$n")"
    if [ "$style" = "B" ]; then body="$(sed '1d' "$f")"; else body="$(cat "$f")"; fi
    body="$(_wb_trim_blank_lines "$body")"
    title="$(_wb_mg_clip "$title")"
    text="### $date ${hm:0:2}:${hm:2:2} — $title"
    if [ -n "$body" ]; then text+=$'\n\n'"$body"; fi
    _wb_record_write_file "$scratch_task" decisions "" "$text" || return 1
  done < "$work/dec.meta"

  # --- open follow-ups: open-items/<date>-<slug>.md, who/kind empty
  local created_date
  while IFS=$'\t' read -r meta_tag n kind ln date title; do
    [ "$meta_tag" = "I" ] && [ "$kind" = "open" ] || continue
    f="$work/fol/$(printf 'i%04d.txt' "$n")"
    body="$(cat "$f")"
    # the checkbox is replaced by the file's status: open
    body="$(printf '%s\n' "$body" | sed '1s/^[-*] \[ \] *//')"
    body="$(_wb_trim_blank_lines "$body")"
    created_date="$date"; [ "$created_date" != "-" ] || created_date="$created"
    title="$(_wb_mg_clip "$title")"
    text="### $created_date 00:00 — $title"
    if [ -n "$body" ]; then text+=$'\n\n'"$body"; fi
    _wb_record_write_file "$scratch_task" open-items "" "$text" || return 1
  done < "$work/fol.meta"

  # --- migrated-history file: handoffs/<created>-0000.md (written before the
  # moved entries so it keeps the plain name if a handoff is stamped 00:00)
  local hist="" ticked="" fnotes="" markers="" hpre="" donetxt=""
  while IFS=$'\t' read -r meta_tag n kind ln date title; do
    [ "$meta_tag" = "I" ] && [ "$kind" = "done" ] || continue
    f="$work/fol/$(printf 'i%04d.txt' "$n")"
    body="$(_wb_trim_blank_lines "$(cat "$f")")"
    if [ -n "$ticked" ]; then ticked+=$'\n'; fi
    ticked+="$body"
  done < "$work/fol.meta"
  fnotes="$(_wb_trim_blank_lines "$(cat "$work/fol/f-pre.txt" 2>/dev/null)")"
  markers="$(_wb_trim_blank_lines "$(cat "$work/dec/markers.txt" 2>/dev/null)")"
  hpre="$(_wb_trim_blank_lines "$(cat "$work/hnd/h-pre.txt" 2>/dev/null)")"
  donetxt="$(_wb_trim_blank_lines "$(cat "$work/done.sec" 2>/dev/null)")"
  # a heading-less Handoffs section stays in the task file, so its text is not history
  if [ "$nh" -eq 0 ]; then hpre=""; fi
  if [ -n "$ticked$fnotes$markers$hpre$donetxt" ]; then
    hist="### $created 00:00 — migrate (auto)"$'\n\n'"Records carried over by wb migrate: ticked follow-ups, the Done section and no-decision markers from the old task file."
    if [ -n "$ticked" ];   then hist+=$'\n\n'"#### Ticked follow-ups"$'\n\n'"$ticked"; fi
    if [ -n "$fnotes" ];   then hist+=$'\n\n'"#### Follow-ups notes"$'\n\n'"$fnotes"; fi
    if [ -n "$markers" ];  then hist+=$'\n\n'"#### No decisions"$'\n\n'"$markers"; fi
    if [ -n "$hpre" ];     then hist+=$'\n\n'"#### Handoffs preamble"$'\n\n'"$hpre"; fi
    if [ -n "$donetxt" ];  then hist+=$'\n\n'"#### Done"$'\n\n'"$donetxt"; fi
    _wb_handoff_move_entry "$sdir/handoffs" "$hist" "$created" "0000" || return 1
    local hid
    hid="$(find "$sdir/handoffs" -maxdepth 1 -type f -name "$created-0000*.md" | LC_ALL=C sort | head -1 || true)"
    hid="${hid##*/}"; printf '%s' "${hid%.md}" > "$work/hist.id"
  fi

  # --- handoffs: every entry but the newest moves to handoffs/
  : > "$work/kept.txt"
  while IFS=$'\t' read -r meta_tag n ln date hm flags; do
    [ "$meta_tag" = "E" ] || continue
    f="$work/hnd/$(printf 'h%04d.txt' "$n")"
    text="$(_wb_trim_blank_lines "$(cat "$f")")"
    if [ "$n" -eq "$nh" ]; then
      printf '%s\n' "$text" > "$work/kept.txt"
    else
      _wb_handoff_move_entry "$sdir/handoffs" "$text" "$date" "$hm" || return 1
    fi
  done < "$work/hnd.meta"
  return 0
}

# ---------------------------------------------------------------------------
# commit
# ---------------------------------------------------------------------------

# _wb_mg_commit <task_file> <work> <stem> <nh> <i_now> <i_hand> <nsec>
#   <total> <fmend> — move the verified scratch dossier into the store,
# rename CONCEPTS.md, rewrite the task file (frontmatter + layout: dossier,
# title and intro, an empty ## Now above the first section, every kept
# section untouched, ## Handoffs reduced to its newest entry) and rebuild the
# views. The task file is rewritten LAST, through a temp file and mv, so a
# crash before it leaves no layout: field and the migration reruns (and then
# stops at the "dossier already holds records" check below, loudly).
_wb_mg_commit() {
  local file="$1" work="$2" stem="$3" nh="$4" i_now="$5" i_hand="$6" nsec="$7" total="$8" fmend="$9"
  local dest; dest="$(_wb_dossier_dir "$file")"
  local sdir="$work/store/dossiers/$stem" series
  # refuse before touching anything when a series dir already holds files
  for series in decisions handoffs open-items; do
    if [ -d "$sdir/$series" ] && [ -d "$dest/$series" ] && [ -n "$(find "$dest/$series" -mindepth 1 -print -quit 2>/dev/null)" ]; then
      _wb_mg_block "dossiers/$stem/$series/ already holds files; nothing written"
      return 1
    fi
  done
  mkdir -p "$dest" || { _wb_mg_block "could not create $dest"; return 1; }
  for series in decisions handoffs open-items; do
    [ -d "$sdir/$series" ] || continue
    rmdir "$dest/$series" 2>/dev/null || true
    mv "$sdir/$series" "$dest/$series" || { _wb_mg_block "could not move $series/ into $dest"; return 1; }
  done

  # CONCEPTS.md -> concepts.md (KTD24). Two-step rename so a case-insensitive
  # filesystem still renames; an exact-name listing detects a real clash.
  if [ -f "$dest/CONCEPTS.md" ]; then
    if ls -1 "$dest" | grep -qx 'concepts.md'; then
      _wb_mg_exc "dossiers/$stem/ holds both CONCEPTS.md and concepts.md; left both for you to merge"
    else
      mv "$dest/CONCEPTS.md" "$dest/.concepts.md.mv.$$" && mv "$dest/.concepts.md.mv.$$" "$dest/concepts.md"
      WB_MG_RENAMED+=("$stem")
    fi
  fi

  # task file
  local tmp="$file.tmp.$$"
  {
    sed -n "1,${fmend}p" "$file"
  } > "$tmp"
  _wb_mg_rewrite_body "$file" "$work" "$i_now" "$i_hand" "$nsec" "$total" "$fmend" "$nh" >> "$tmp"
  wb_set_frontmatter_field "$tmp" layout dossier
  mv "$tmp" "$file" || { _wb_mg_block "could not rewrite $file"; return 1; }
  wb_render_views "$file"
  return 0
}

# _wb_mg_rewrite_body <task_file> <work> <i_now> <i_hand> <nsec> <total>
#   <fmend> <nh> — the task file's body (everything after the frontmatter)
# on stdout. Reuses the section map computed by the caller (the hl/hn/role
# arrays are dynamically scoped from _wb_mg_convert).
_wb_mg_rewrite_body() {
  local file="$1" work="$2" i_now="$3" i_hand="$4" nsec="$5" total="$6" fmend="$7" nh="$8"
  local i first last pre_end
  if [ "$nsec" -gt 0 ]; then pre_end=$((hl[0] - 1)); else pre_end="$total"; fi
  if [ "$pre_end" -gt "$fmend" ]; then sed -n "$((fmend + 1)),${pre_end}p" "$file"; fi
  # the preamble must end in a blank line before the first heading
  local lastpre=""
  if [ "$pre_end" -gt "$fmend" ]; then lastpre="$(sed -n "${pre_end}p" "$file")"; fi
  if [ -n "$lastpre" ]; then printf '\n'; fi
  if [ "$i_now" -lt 0 ]; then printf '## Now\n\n'; fi
  for ((i = 0; i < nsec; i++)); do
    first="${hl[i]}"
    if [ $((i + 1)) -lt "$nsec" ]; then last=$((hl[i + 1] - 1)); else last="$total"; fi
    case "${role[i]}" in
      dec|fol|done) continue ;;
      hand)
        if [ "$nh" -ge 1 ]; then
          printf '## Handoffs\n\n'
          cat "$work/kept.txt"
          if [ $((i + 1)) -lt "$nsec" ]; then printf '\n'; fi
        else
          sed -n "${first},${last}p" "$file"
        fi ;;
      *) sed -n "${first},${last}p" "$file" ;;
    esac
  done
}

# ---------------------------------------------------------------------------
# the verb
# ---------------------------------------------------------------------------

# cmd_migrate <task>|--all [--dry-run] — see the file header. Prints one
# count line per task (decisions, handoffs, open-items, history, each
# "before/after", then the exception count) and ends with a report listing
# every task skipped because its lock was held and every exception. Exit 0
# when every task was migrated or already had the layout; 1 when any task was
# left unmigrated or skipped.
cmd_migrate() {
  local target="" dry=0 all=0 arg
  for arg in "$@"; do
    case "$arg" in
      --dry-run) dry=1 ;;
      --all)     all=1 ;;
      -*)        echo "usage: wb migrate <task>|--all [--dry-run]" >&2; return 1 ;;
      *)         if [ -n "$target" ]; then echo "usage: wb migrate <task>|--all [--dry-run]" >&2; return 1; fi; target="$arg" ;;
    esac
  done
  if { [ "$all" -eq 1 ] && [ -n "$target" ]; } || { [ "$all" -eq 0 ] && [ -z "$target" ]; }; then
    echo "usage: wb migrate <task>|--all [--dry-run]" >&2
    return 1
  fi

  local -a files=()
  if [ "$all" -eq 1 ]; then
    while IFS= read -r arg; do files+=("$arg"); done < <(wb_task_files)
  else
    local one; one="$(_wb_append_resolve_task "$target" "wb migrate")" || return 1
    files+=("$one")
  fi

  _WB_MG_TMPROOT="${TMPDIR:-/tmp}"; _WB_MG_TMPROOT="${_WB_MG_TMPROOT%/}"
  [ "$dry" -eq 1 ] || _wb_lock_trap_append_if_top_level wb_task_lock_release_all
  WB_MG_EXC=(); WB_MG_RENAMED=()
  local -a skipped=() blocked=()
  local n_migrated=0 n_already=0 f stem rc=0
  for f in "${files[@]}"; do
    stem="${f##*/}"; stem="${stem%.md}"
    if [ "$dry" -eq 0 ]; then
      if ! wb_task_lock_acquire_guarded "$f"; then
        echo "wb migrate: $stem  SKIPPED, lock held"
        skipped+=("$stem")
        continue
      fi
    fi
    _WB_MG_WORK=""
    _wb_mg_convert "$f" "$dry"
    [ -z "$_WB_MG_WORK" ] || _wb_mg_cleanup "$_WB_MG_WORK"
    [ "$dry" -eq 1 ] || wb_task_lock_release "$f"
    case "$WB_MG_RESULT" in
      migrated) n_migrated=$((n_migrated + 1)) ;;
      already)  n_already=$((n_already + 1)) ;;
      blocked)  blocked+=("$stem") ;;
    esac
  done

  # ---- report -------------------------------------------------------------
  local verb="migrated"; [ "$dry" -eq 0 ] || verb="would migrate"
  echo
  echo "wb migrate: $n_migrated $verb, $n_already already had the layout, ${#blocked[@]} left unmigrated, ${#skipped[@]} skipped (lock held)"
  if [ "${#skipped[@]}" -gt 0 ]; then
    echo "Skipped, lock held (rerun for these):"
    printf '  %s\n' "${skipped[@]}"
    rc=1
  fi
  if [ "${#blocked[@]}" -gt 0 ]; then
    echo "Left unmigrated, nothing written:"
    printf '  %s\n' "${blocked[@]}"
    rc=1
  fi
  if [ "${#WB_MG_EXC[@]}" -gt 0 ]; then
    echo "Exceptions for you:"
    printf '  %s\n' "${WB_MG_EXC[@]}"
  fi
  if [ "${#WB_MG_RENAMED[@]}" -gt 0 ]; then
    echo "CONCEPTS.md was renamed to concepts.md for: ${WB_MG_RENAMED[*]}"
    echo "Rewrite the CLAUDE.local.md import lines with: wb family <task> --reseed (running sessions need /clear or a restart)."
  fi
  return "$rc"
}
