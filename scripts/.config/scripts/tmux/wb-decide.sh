# shellcheck shell=bash
# wb-decide.sh — the surface verbs of /decide: decide-path, decide-buffer,
# decide-open and decide-clear. Sourced lazily by wb.sh's dispatch (like
# wb-continue.sh), so this file only defines functions; no top-level command
# runs just by sourcing it. It calls wb.sh's own helpers at run time.
#
# A task (or, outside one, a tmux session) with questions waiting on Jet has
# a needs-you marker, wb_needs_you_file <key> in wb.sh:
# ${XDG_STATE_HOME:-$HOME/.local/state}/wb/needs-you/<key>, one line per open
# surface:
#   buffer <answer file> <nvim pane> <sha256 of the file at first open>
#   page <url> <rev>
# <key> is the task's stem, or the tmux session's name outside a task. The
# picker shows the key as needing Jet while the file exists; /decide clears a
# surface once its items are recorded, and the file goes with the last line.
# Writers hold the lock `needs-you-<key>` (its own, never the task's, so a
# marker write can't time out against a task-file writer on the 1-second
# flock), so two surfaces opening or closing at once can't drop each other's
# lines.

# _wb_decide_target <verb> [--task <ref>] [args…] — whose surface this is.
# Sets WB_DECIDE_KEY, WB_DECIDE_TASK (the task file, empty outside a task),
# WB_DECIDE_SESSION (its tmux session when one is known) and WB_DECIDE_ARGS
# (the arguments left once --task is taken out). A --task that names no task
# fails; otherwise the task is the one the caller's pane (TMUX_PANE) belongs
# to, and a pane in no task keys the session's name.
_wb_decide_target() {
  local verb="$1" query="" err s sess
  shift
  WB_DECIDE_KEY=""; WB_DECIDE_TASK=""; WB_DECIDE_SESSION=""; WB_DECIDE_ARGS=()
  while [ $# -gt 0 ]; do
    case "$1" in
      --task)
        [ $# -ge 2 ] || { echo "wb $verb: --task needs a task" >&2; return 1; }
        query="$2"; shift 2 ;;
      *) WB_DECIDE_ARGS+=("$1"); shift ;;
    esac
  done
  if [ -n "$query" ]; then
    if ! err="$(_wb_append_resolve_task "$query" "wb $verb" 2>&1)"; then
      case "$err" in
        *"be more specific"*) printf '%s\n' "$err" >&2 ;;
        *) echo "wb $verb: no task '$query'" >&2 ;;
      esac
      return 1
    fi
    WB_DECIDE_TASK="$err"
    WB_DECIDE_KEY="$(basename -- "$WB_DECIDE_TASK" .md)"
    WB_DECIDE_SESSION="$(_wb_decide_task_session "$WB_DECIDE_TASK")"
    return 0
  fi
  if [ -n "${TMUX_PANE:-}" ] && s="$(tmux display -p -t "$TMUX_PANE" '#S' 2>/dev/null)" && [ -n "$s" ]; then
    WB_DECIDE_SESSION="$s"
    if sess="$(wb_session_task_file "$s" 2>/dev/null)" && [ -n "$sess" ]; then
      WB_DECIDE_TASK="$sess"
      WB_DECIDE_KEY="$(basename -- "$sess" .md)"
    else
      WB_DECIDE_KEY="$s"
    fi
    return 0
  fi
  echo "wb $verb: this session is neither a wb task nor in tmux, so nothing can mark it as needing Jet" >&2
  return 1
}

# _wb_decide_task_session <task_file> — the live tmux session whose @task
# points at the file, if any (the scan _wb_refuse_if_live_session does).
_wb_decide_task_session() {
  local session cur
  while IFS= read -r session; do
    [ -n "$session" ] || continue
    cur="$(tmux show -t "=$session:" -v @task 2>/dev/null || true)"
    if [ "$cur" = "$1" ]; then printf '%s\n' "$session"; return 0; fi
  done < <(tmux list-sessions -F '#{session_name}' 2>/dev/null || true)
  return 0
}

# _wb_decide_pane_exists <pane_id> — tmux prints nothing and exits 0 for a
# pane that is gone, so the printed id is compared.
_wb_decide_pane_exists() { [ "$(tmux display -p -t "$1" '#{pane_id}' 2>/dev/null)" = "$1" ]; }

# _wb_decide_pane_runs_editor <pane_id> <file> — the pane is alive, is running
# an editor, and was opened on <file>. The split is tagged with the pane option
# @wb_decide_file, compared exactly: tmux escapes #{pane_start_command} again,
# so matching the file inside it never worked for a path with a space. A pane
# id that tmux handed out again after a restart, or a pane whose editor quit
# into a shell, fails.
_wb_decide_pane_runs_editor() {
  local out id cmd tag
  out="$(tmux display -p -t "$1" '#{pane_id}|#{pane_current_command}' 2>/dev/null)" || return 1
  id="${out%%|*}"; [ "$id" = "$1" ] || return 1
  cmd="${out#*|}"
  case "$cmd" in nvim|vim|vi) ;; *) return 1 ;; esac
  tag="$(tmux show-options -p -v -t "$1" @wb_decide_file 2>/dev/null)" || return 1
  [ "$tag" = "$2" ]
}

# _wb_decide_sha <file> — sha256 of the file's content.
_wb_decide_sha() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum -- "$1" | awk '{print $1}'
  else
    shasum -a 256 -- "$1" | awk '{print $1}'
  fi
}

# _wb_decide_line_is <line> <ref> — the marker line is the surface <ref>
# (a file or a url). Its kind and trailing fields (a buffer's pane and sha, a
# page's rev) are space-free, so a file name with spaces still matches only
# itself.
_wb_decide_line_is() {
  local l="$1" ref="$2" rest
  case "$l" in buffer\ *|page\ *) ;; *) return 1 ;; esac
  rest="${l#* }"
  [[ "$rest" == "$ref "* ]] || return 1
  rest="${rest#"$ref "}"
  [[ "$rest" =~ ^[^\ ]+(\ [^\ ]+)?$ ]]
}

# _wb_decide_marker_line <marker> <ref> — the marker's line for <ref>, if any.
_wb_decide_marker_line() {
  local l
  [ -f "$1" ] || return 0
  while IFS= read -r l || [ -n "$l" ]; do
    if _wb_decide_line_is "$l" "$2"; then printf '%s\n' "$l"; return 0; fi
  done < "$1"
  return 0
}

# _wb_decide_marker_put <marker> <drop-ref> [<new line>] — rewrite the marker
# without <drop-ref>'s line, plus <new line> when given; no lines left removes
# the file. The caller holds the marker's lock.
_wb_decide_marker_put() {
  local f="$1" ref="$2" new="${3:-}" l tmp="$1.tmp.$$"
  mkdir -p "${f%/*}"
  {
    if [ -f "$f" ]; then
      while IFS= read -r l || [ -n "$l" ]; do
        if [ -n "$ref" ] && _wb_decide_line_is "$l" "$ref"; then continue; fi
        printf '%s\n' "$l"
      done < "$f"
    fi
    if [ -n "$new" ]; then printf '%s\n' "$new"; fi
  } > "$tmp"
  if [ -s "$tmp" ]; then mv -f "$tmp" "$f"; else rm -f "$tmp" "$f"; fi
}

# _wb_decide_lock <key> — take the marker's own lock, or exit 75.
_wb_decide_lock() {
  _wb_lock_trap_append_if_top_level wb_task_lock_release_all
  wb_task_lock_acquire_guarded "needs-you-$1" || exit $?
}

# _wb_decide_name_free <dir> <prefix> <suffix> — a stamp, in the dossier's own
# YYYY-MM-DD-HHMM form, that makes <dir>/<prefix><stamp><suffix> a free name;
# -2, -3… is added to the stamp when it is taken.
_wb_decide_name_free() {
  local stamp n=1 name
  stamp="$(date +%Y-%m-%d-%H%M)"
  name="$stamp"
  while [ -e "$1/$2$name$3" ]; do n=$((n + 1)); name="$stamp-$n"; done
  printf '%s\n' "$name"
}

# cmd_decide_path [--task <ref>] [--page <slug>] — a fresh path for this
# task's answers, its directory created: the buffer's answer file
# (decision-records/<stamp>-decide.md, reserved empty), or with --page the
# spec of a page (decision-records/<stamp>-<slug>/spec.json, its folder
# created). In a task they sit in its dossier, even on a task not yet on the
# dossier layout; outside one, under wb/decide/<session>/ in the state dir.
cmd_decide_path() {
  local dir slug="" name path
  _wb_decide_target decide-path "$@" || exit 1
  if [ "${WB_DECIDE_ARGS[0]:-}" = --page ]; then
    [ -n "${WB_DECIDE_ARGS[1]:-}" ] || { echo "usage: wb decide-path [--task <ref>] [--page <slug>]" >&2; exit 1; }
    slug="$(_wb_slug "${WB_DECIDE_ARGS[1]}")"
  elif [ "${#WB_DECIDE_ARGS[@]}" -gt 0 ]; then
    echo "usage: wb decide-path [--task <ref>] [--page <slug>]" >&2; exit 1
  fi
  if [ -n "$WB_DECIDE_TASK" ]; then
    dir="$(_wb_dossier_dir "$WB_DECIDE_TASK")/decision-records"
  else
    dir="${XDG_STATE_HOME:-$HOME/.local/state}/wb/decide/$WB_DECIDE_KEY"
  fi
  mkdir -p "$dir"
  if [ -n "$slug" ]; then
    name="$(_wb_decide_name_free "$dir" "" "-$slug")"
    path="$dir/$name-$slug"
    mkdir -p "$path"
    printf '%s/spec.json\n' "$path"
  else
    name="$(_wb_decide_name_free "$dir" "" "-decide.md")"
    path="$dir/$name-decide.md"
    : > "$path"
    printf '%s\n' "$path"
  fi
}

# cmd_decide_open page <url> <rev> [--task <ref>] — mark a page as open; a
# later rev of the same url replaces the earlier line. (decide-buffer marks
# its own surface.)
cmd_decide_open() {
  local f
  _wb_decide_target decide-open "$@" || exit 1
  if [ "${WB_DECIDE_ARGS[0]:-}" != page ] || [ -z "${WB_DECIDE_ARGS[1]:-}" ] || [ -z "${WB_DECIDE_ARGS[2]:-}" ] \
     || [ "${#WB_DECIDE_ARGS[@]}" -gt 3 ]; then
    echo "usage: wb decide-open page <url> <rev> [--task <ref>]" >&2; exit 1
  fi
  f="$(wb_needs_you_file "$WB_DECIDE_KEY")"
  _wb_decide_lock "$WB_DECIDE_KEY"
  _wb_decide_marker_put "$f" "${WB_DECIDE_ARGS[1]}" "page ${WB_DECIDE_ARGS[1]} ${WB_DECIDE_ARGS[2]}"
  wb_task_lock_release "needs-you-$WB_DECIDE_KEY"
}

# _wb_decide_agent_window <session> — the id of the session's window named
# exactly agent, if it has one. Found by name, since base-index differs between
# configs; the id also keeps a second window of that name from failing the split.
_wb_decide_agent_window() {
  tmux list-windows -t "=$1:" -F '#{window_id} #{window_name}' 2>/dev/null \
    | sed -n 's/^\(@[0-9]*\) agent$/\1/p' | head -n1
}

# cmd_decide_buffer <answer file> [--task <ref>] — open the file in nvim in a
# split of the task's tmux session, wait for that pane to close, then print
# the file, its checksum from the first open and whether it differs now:
#   file: <path>
#   sha: <sha256 recorded at the first open>
#   changed: yes|no
# A caller whose pane is in the task's session gets the split beside it; a
# caller with no pane of its own gets the agent window, else the session's
# current window. /decide runs this as a background command, so Jet can take
# as long as he likes and the session is re-invoked when it exits.
#
# The marker line keeps the first open's checksum for good. A re-run waits on
# the recorded pane while it still runs nvim on the file; with that pane gone
# and the file changed it opens nothing and reports changed, so the answers
# are read; only a file that still matches its checksum gets a new split.
#
# --reopen starts a new round on a file the caller rewrote (a second round of
# questions, the next run-and-paste step): it still waits on a split that is
# open, but otherwise always opens a new one and records the file's current
# checksum, so the rewrite isn't mistaken for Jet's answers.
cmd_decide_buffer() {
  local file editor target session pane sha now line rest mode="split" f psess reopen=0 a args=()
  _wb_decide_target decide-buffer "$@" || exit 1
  for a in "${WB_DECIDE_ARGS[@]+"${WB_DECIDE_ARGS[@]}"}"; do
    if [ "$a" = --reopen ]; then reopen=1; else args+=("$a"); fi
  done
  file="${args[0]:-}"
  if [ -z "$file" ] || [ ! -f "$file" ] || [ "${#args[@]}" -gt 1 ]; then
    echo "usage: wb decide-buffer [--reopen] <answer file> [--task <ref>] (the file must exist)" >&2; exit 1
  fi
  case "$file" in /*) ;; *) file="$PWD/$file" ;; esac
  editor="$(command -v nvim)" || { echo "wb decide-buffer: nvim isn't on the PATH" >&2; exit 1; }
  f="$(wb_needs_you_file "$WB_DECIDE_KEY")"
  session="$WB_DECIDE_SESSION"
  psess=""
  if [ -n "${TMUX_PANE:-}" ] && _wb_decide_pane_exists "$TMUX_PANE"; then
    psess="$(tmux display -p -t "$TMUX_PANE" '#S' 2>/dev/null || true)"
  fi
  if [ -n "$psess" ] && { [ -z "$session" ] || [ "$session" = "$psess" ]; }; then
    target="$TMUX_PANE"
  elif [ -n "$session" ]; then
    target="$(_wb_decide_agent_window "$session")"
    target="${target:-=$session:}"
  else
    echo "wb decide-buffer: $WB_DECIDE_KEY has no tmux session to open the buffer in" >&2; exit 1
  fi

  # Locked while the marker is read and the split made, so the surface is
  # marked as soon as it exists; released before the wait, since a buffer may
  # stay open for hours.
  _wb_decide_lock "$WB_DECIDE_KEY"
  now="$(_wb_decide_sha "$file")"
  sha="$now"; pane=""
  line="$(_wb_decide_marker_line "$f" "$file")"
  if [ -n "$line" ]; then
    rest="${line#buffer "$file" }"
    pane="${rest%% *}"; sha="${rest##* }"
    if _wb_decide_pane_runs_editor "$pane" "$file"; then
      mode="wait"
    elif [ "$reopen" = 1 ]; then
      sha="$now"
    elif [ "$sha" != "$now" ]; then
      mode="none"
    fi
  fi
  if [ "$mode" = split ]; then
    # The agent window has remain-on-exit on, which the split would inherit:
    # its pane would outlive nvim and the wait below would never end. Turning
    # it off in the same tmux command acts on the new pane, so nvim can't
    # exit first. WB_REVIEW_BUFFER=1 skips format-on-save, as the other
    # review buffers do.
    if ! pane="$(tmux split-window -h -t "$target" -c "${file%/*}" -P -F '#{pane_id}' \
           "WB_REVIEW_BUFFER=1 $(printf '%q ' "$editor" "$file")" \; set-option -p remain-on-exit off \; set-option -p @wb_decide_file "$file" 2>/dev/null)" \
       || [ -z "$pane" ]; then
      wb_task_lock_release "needs-you-$WB_DECIDE_KEY"
      echo "wb decide-buffer: tmux couldn't open the split" >&2; exit 1
    fi
    _wb_decide_marker_put "$f" "$file" "buffer $file $pane $sha"
  fi
  wb_task_lock_release "needs-you-$WB_DECIDE_KEY"
  if [ "$mode" != none ]; then
    while _wb_decide_pane_exists "$pane"; do sleep 1; done
  fi
  now="$(_wb_decide_sha "$file")"
  printf 'file: %s\nsha: %s\nchanged: %s\n' "$file" "$sha" "$([ "$now" = "$sha" ] && echo no || echo yes)"
  exit 0
}

# cmd_decide_clear <file|url> | --all [--task <ref>] — the surface is answered
# and recorded; drop its line, and the marker once none is left.
cmd_decide_clear() {
  local f ref
  _wb_decide_target decide-clear "$@" || exit 1
  ref="${WB_DECIDE_ARGS[0]:-}"
  if [ -z "$ref" ] || [ "${#WB_DECIDE_ARGS[@]}" -gt 1 ]; then
    echo "usage: wb decide-clear <file|url> | --all [--task <ref>]" >&2; exit 1
  fi
  f="$(wb_needs_you_file "$WB_DECIDE_KEY")"
  [ -f "$f" ] || exit 0
  _wb_decide_lock "$WB_DECIDE_KEY"
  if [ "$ref" = --all ]; then rm -f "$f"; else _wb_decide_marker_put "$f" "$ref"; fi
  wb_task_lock_release "needs-you-$WB_DECIDE_KEY"
  exit 0
}

# _wb_decision_trim <text> — drop leading and trailing whitespace.
_wb_decision_trim() {
  local t="$1"
  t="${t#"${t%%[![:space:]]*}"}"
  t="${t%"${t##*[![:space:]]}"}"
  printf '%s' "$t"
}

# _wb_decision_read <record file> — sets WB_DEC_TITLE (the first `# ` line
# after the frontmatter, trailing space trimmed) and WB_DEC_BODY (what follows
# it, whitespace-trimmed at both ends).
_wb_decision_read() {
  local text first rest=""
  text="$(awk 'c >= 2 { print; next } /^---$/ { c++ }' "$1")"
  first="${text%%$'\n'*}"
  if [[ "$text" == *$'\n'* ]]; then rest="${text#*$'\n'}"; fi
  first="${first#"# "}"
  WB_DEC_TITLE="$(_wb_decision_trim "$first")"
  WB_DEC_BODY="$(_wb_decision_trim "$rest")"
}

# cmd_decision [--task <ref>] [--default] "<title>" — record one answer (body
# on stdin) in the task's Decisions, under the task lock. A record with the
# same title as an in-force one (exact match, trailing spaces
# ignored) supersedes it, the old file kept and marked superseded; an
# identical body writes nothing. --default marks the record "default taken" by
# a first body line `Default taken.` (the only way a later lookup can tell it
# from Jet's own answer): it never supersedes a live record without that
# line, and writes a new entry naming it instead. An answer from Jet
# supersedes every live record of its title, defaults included. Every task is
# on the dossier layout (W4), so the record is always a decisions/ file.
cmd_decision() {
  local usage='usage: wb decision [--task <task>] [--default] "<title>"   (body on stdin; title matched exactly, trailing spaces ignored; --default writes a "Default taken." first line and never supersedes Jet'"'"'s answer)'
  local isdef=0 args=() a title body file dir f stamp
  for a in "$@"; do
    if [ "$a" = --default ]; then isdef=1; else args+=("$a"); fi
  done
  if ! _wb_decide_has_task_source "${args[@]+"${args[@]}"}"; then
    echo "wb decision: no task given and this isn't a tmux pane in one; pass --task <task>" >&2; exit 1
  fi
  _wb_decide_target decision "${args[@]+"${args[@]}"}" || exit 1
  file="$WB_DECIDE_TASK"
  [ -n "$file" ] || { echo "wb decision: not in a task; pass --task <task>" >&2; exit 1; }
  if [ "${#WB_DECIDE_ARGS[@]}" -ne 1 ] || [ -z "$(_wb_decision_trim "${WB_DECIDE_ARGS[0]}")" ]; then
    echo "$usage" >&2; exit 1
  fi
  title="$(_wb_decision_trim "${WB_DECIDE_ARGS[0]}")"
  body="$(cat)"
  if _wb_blank_only "$body"; then echo "wb decision: empty body — nothing to write" >&2; exit 1; fi
  body="$(_wb_decision_trim "$body")"
  if [ "$isdef" = 1 ]; then body="Default taken."$'\n'"$body"; fi
  stamp="### $(date '+%Y-%m-%d %H:%M') — $title"

  _wb_lock_trap_append_if_top_level wb_task_lock_release_all
  wb_task_lock_acquire_guarded "$file" || exit $?

  dir="$(_wb_dossier_dir "$file")/decisions"
  local ids=() isdefs=() bodies=() id
  if [ -d "$dir" ]; then
    # Only files whose text contains the title can match, so grep narrows the
    # per-file reads below (they run inside the task lock); the exact title
    # test still decides. Byte-order file order, as the store lists them.
    while IFS= read -r f; do
      f="${f##*/}"
      [ "$(wb_get_frontmatter "$dir/$f" status)" = in-force ] || continue
      _wb_decision_read "$dir/$f"
      [ "$WB_DEC_TITLE" = "$title" ] || continue
      ids+=("${f%.md}"); bodies+=("$WB_DEC_BODY")
      if [ "${WB_DEC_BODY%%$'\n'*}" = "Default taken." ]; then isdefs+=(1); else isdefs+=(0); fi
    done < <(cd "$dir" && LC_ALL=C && grep -lF -- "$title" ./*.md 2>/dev/null)
  fi

  # Which live records this one supersedes (indexes into ids), and the answer
  # a default must leave alone.
  local sup=() i ans=""
  if [ "$isdef" = 1 ]; then
    for i in "${!ids[@]}"; do [ "${isdefs[$i]}" = 0 ] && ans="${ids[$i]}"; done
    [ -z "$ans" ] || body+=$'\n\n'"Not superseding $ans: that answer stays in force."
  fi
  [ -n "$ans" ] || for i in "${!ids[@]}"; do sup+=("$i"); done
  if [ "${#ids[@]}" -gt 0 ]; then
    i=$((${#ids[@]} - 1))
    if [ "$body" = "${bodies[$i]}" ]; then
      wb_task_lock_release "$file"
      echo "wb decision: unchanged — ${ids[$i]} already says this"
      return 0
    fi
  fi

  local newest=""
  [ "${#sup[@]}" -eq 0 ] || newest="${ids[${sup[$((${#sup[@]} - 1))]}]}"
  if ! _wb_record_write_file "$file" decisions "$newest" "$stamp"$'\n\n'"$body"; then
    wb_task_lock_release "$file"; exit 1
  fi
  local new="$WB_RECORD_ID" list="" said="" bad=0
  for i in "${sup[@]+"${sup[@]}"}"; do
    id="${ids[$i]}"
    list+="${list:+, }$id"
    said+="${said:+, }$id \"$title\""
    if ! wb_set_frontmatter_field "$dir/$id.md" status superseded \
       || ! wb_set_frontmatter_field "$dir/$id.md" superseded_by "[$new]"; then
      bad=1; echo "wb decision: wrote $new but could not mark '$id' superseded; fix $dir/$id.md by hand (status: superseded, superseded_by: [$new])" >&2
    fi
  done
  if [ "${#sup[@]}" -gt 1 ]; then wb_set_frontmatter_field "$dir/$new.md" supersedes "[$list]" || bad=1; fi
  wb_render_views "$file"
  wb_task_lock_release "$file"
  [ "$bad" = 0 ] || exit 1
  if [ -n "$said" ]; then
    echo "wb decision: wrote $new in $(basename -- "$file") (supersedes $said)"
  elif [ -n "$ans" ]; then
    echo "wb decision: wrote $new in $(basename -- "$file") (default taken; $ans stays in force)"
  else
    echo "wb decision: wrote $new in $(basename -- "$file")"
  fi
}

# _wb_decide_has_task_source [args…] — a --task is among the args, or the
# caller is in a tmux pane; the check _wb_decide_target's own message about
# markers would answer misleadingly for a verb that writes to a task.
_wb_decide_has_task_source() {
  local a
  for a in "$@"; do [ "$a" = --task ] && return 0; done
  [ -n "${TMUX_PANE:-}" ]
}

# cmd_decide_spec_check [--previous <spec>] <spec.json> — check a /decide page
# spec against the rules in claude/.claude/skills/decide/references/page-spec.md
# ("Checker rules"): printed one problem per line, naming the item, exit 1;
# `ok: <n> items` and exit 0 when clean. Top-level keys it doesn't know
# (/wb-breakdown's `breakdown`) are the page's to ignore, so they pass.
# With --previous, an item id present in both specs must keep its title and
# its option ids, so an old answer never attaches to a changed question.
cmd_decide_spec_check() {
  local usage="usage: wb decide-spec-check [--previous <spec>] <spec.json>"
  local spec="" prev="" out
  while [ $# -gt 0 ]; do
    case "$1" in
      --previous) [ $# -ge 2 ] || { echo "$usage" >&2; exit 1; }; prev="$2"; shift 2 ;;
      *) [ -z "$spec" ] || { echo "$usage" >&2; exit 1; }; spec="$1"; shift ;;
    esac
  done
  [ -n "$spec" ] || { echo "$usage" >&2; exit 1; }
  command -v jq >/dev/null 2>&1 || { echo "wb decide-spec-check: jq isn't on the PATH" >&2; exit 1; }
  [ -f "$spec" ] || { echo "wb decide-spec-check: no such file: $spec" >&2; exit 1; }
  jq -e . "$spec" >/dev/null 2>&1 || { echo "wb decide-spec-check: $spec is not valid JSON" >&2; exit 1; }
  if [ -n "$prev" ]; then
    { [ -f "$prev" ] && jq -e . "$prev" >/dev/null 2>&1; } || { echo "wb decide-spec-check: $prev is not a readable JSON spec" >&2; exit 1; }
  else
    prev=/dev/null
  fi
  out="$(jq -r --slurpfile prev "$prev" '
    def nm($i): "item " + (if (.id | type) == "string" and .id != "" then .id else "#\($i + 1)" end);
    def sid: (.id | type) == "string" and .id != "";
    def oids: [(.options // [])[]? | objects | .id];
    . as $s
    | ($s.layout) as $lay
    | ([($s.verdicts // [])[]? | objects | .id]) as $vids
    | ($s.items | type == "array") as $haveitems
    | [
        (if ($s.title | type) != "string" or $s.title == "" then "spec: title is required" else empty end),
        (if ($lay == "items" or $lay == "verdicts") | not then "spec: layout must be \"items\" or \"verdicts\"" else empty end),
        (if $haveitems | not then "spec: items must be a list" else empty end),
        (if $lay == "verdicts" then
           (if ($s.verdicts | type) != "array" or ($s.verdicts | length) < 2 then "spec: verdicts layout needs at least two verdicts" else empty end),
           (($s.verdicts // []) | if type == "array" then . else [] end | to_entries[]
             | .value as $v
             | (if ($v | type) != "object" or ($v.id | type) != "string" or ($v.label | type) != "string" then "spec: verdict #\(.key + 1) needs an id and a label" else empty end),
               (if ($v | type) == "object" and ($v | has("tone")) and (["neutral","good","bad","info","warn"] | index($v.tone) | not) then "spec: verdict \($v.id // "#\(.key + 1)") has an unknown tone" else empty end)),
           ([$vids[] | select(. != null)] | group_by(.)[] | select(length > 1) | "spec: verdict id \(.[0]) is not unique")
         else empty end),
        (if $haveitems then
           ($s.items | to_entries[] | .key as $i | .value as $it
             | if ($it | type) != "object" then "item #\($i + 1): must be an object"
               else $it | nm($i) as $n
                 | (if sid | not then "\($n): needs an id" else empty end),
                   (if (.title | type) != "string" or .title == "" then "\($n): needs a title" else empty end),
                   (if $lay == "items" then
                      (if (.options | type) != "array" or (.options | length) < 2 then "\($n): items layout needs at least two options"
                       else
                         (.options | to_entries[] | select((.value | type) != "object" or (.value.id | type) != "string" or (.value.label | type) != "string") | "\($n): option #\(.key + 1) needs an id and a label"),
                         ([oids[] | select(. != null)] | group_by(.)[] | select(length > 1) | "\($n): option id \(.[0]) is not unique")
                       end),
                      (if has("default") and ((oids | index($it.default)) | not) then "\($n): default \(.default) is not one of its option ids" else empty end)
                    else empty end),
                   (if has("suggested") and (($vids | index($it.suggested)) | not) then "\($n): suggested \(.suggested) is not a verdict id" else empty end),
                   (if $lay == "verdicts" and has("suggested") and ((.reason | type) != "string" or .reason == "") then "\($n): has a suggested but no reason" else empty end),
                   (if (.blocks | type) == "array" then
                      (.blocks[] | . as $b | if type != "object" then "\($n): block must be an object"
                       elif (["text","code","table","svg","mermaid","links"] | index($b.type)) | not then "\($n): unknown block type \"\($b.type)\""
                       elif .type == "svg" and ((.svg // "") | tostring | test("<script|(^|[\\s\"/<>\\x27])on[a-z]+\\s*=|foreignobject|javascript:"; "i")) then "\($n): svg block has a script, an on* attribute, foreignObject or a javascript: link"
                       else empty end)
                    else empty end),
                   (if .kind == "triage" then
                      (if $lay != "items" then "\($n): triage items need the items layout"
                       else
                         (.options // []) as $o
                         | ([$o[]? | select(.recommended == true)] | length) as $rec
                         | ([$o[]? | select(.id != "defer" and .id != "skip")] | length) as $real
                         | (if $rec != 1 then "\($n): triage needs exactly one recommended option" else empty end),
                           (if [$o[]? | select(.recommended == true and (.id == "defer" or .id == "skip"))] | length > 0 then "\($n): defer and skip are never recommended" else empty end),
                           (if $real < 2 then "\($n): triage needs the recommended fix and at least one real alternative besides defer and skip" else empty end),
                           (if ([$o[]?.id] | .[-2:]) != ["defer","skip"] then "\($n): triage needs defer then skip as its last two options" else empty end)
                       end)
                    else empty end)
               end),
           ([$s.items[]? | objects | select(sid) | .id] | group_by(.)[] | select(length > 1) | "item \(.[0]): id is not unique"),
           (if ($prev | length) > 0 and ($prev[0].items | type) == "array" then
              ($prev[0].items | map(select(type == "object" and sid) | {key: .id, value: .}) | from_entries) as $old
              | ($s.items[]? | objects | select(sid) | . as $it | $old[$it.id] as $o | select($o != null)
                 | (if $it.title != $o.title then "item \($it.id): its question changed since the previous spec; give it a new id" else empty end),
                   (if ([$it | oids[]?] | sort) != ([$o | oids[]?] | sort) then "item \($it.id): its options changed since the previous spec; give it a new id" else empty end))
            else empty end)
         else empty end)
      ] | .[]' "$spec")" || { echo "wb decide-spec-check: could not check $spec" >&2; exit 1; }
  if [ -n "$out" ]; then
    printf '%s\n' "$out"
    exit 1
  fi
  echo "ok: $(jq '.items | length' "$spec") items"
}
