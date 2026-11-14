# shellcheck shell=bash
# wb-decide.sh — the surface verbs of /decide: decide-path, decide-buffer,
# decide-open and decide-clear. Sourced lazily by wb.sh's dispatch (like
# wb-migrate.sh), so this file only defines functions; no top-level command
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
# an editor, and was started on <file>. A pane id that tmux handed out again
# after a restart, or a pane whose editor quit into a shell, fails.
_wb_decide_pane_runs_editor() {
  local out id rest cmd start
  out="$(tmux display -p -t "$1" '#{pane_id}|#{pane_current_command}|#{pane_start_command}' 2>/dev/null)" || return 1
  id="${out%%|*}"; [ "$id" = "$1" ] || return 1
  rest="${out#*|}"; cmd="${rest%%|*}"; start="${rest#*|}"
  case "$cmd" in nvim|vim|vi) ;; *) return 1 ;; esac
  [[ "$start" == *"$(printf '%q' "$2")"* ]]
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
cmd_decide_buffer() {
  local file editor target session pane sha now line rest mode="split" f psess
  _wb_decide_target decide-buffer "$@" || exit 1
  file="${WB_DECIDE_ARGS[0]:-}"
  if [ -z "$file" ] || [ ! -f "$file" ] || [ "${#WB_DECIDE_ARGS[@]}" -gt 1 ]; then
    echo "usage: wb decide-buffer <answer file> [--task <ref>] (the file must exist)" >&2; exit 1
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
           "WB_REVIEW_BUFFER=1 $(printf '%q ' "$editor" "$file")" \; set-option -p remain-on-exit off 2>/dev/null)" \
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
