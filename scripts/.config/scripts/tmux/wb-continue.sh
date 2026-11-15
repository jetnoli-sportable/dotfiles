# shellcheck shell=bash
# wb-continue.sh — the verbs of `wb continue`: stage, arm, status, drop,
# pickup, release. Sourced lazily by wb.sh's dispatch (like
# wb-decide.sh), so this file only defines functions; no top-level command
# runs just by sourcing it. It calls wb.sh's own helpers at run time.
#
# A saved session (a rich /wb-save entry under "## Handoffs") that should carry
# on in a fresh context has ONE request per task, kept under
# ${XDG_STATE_HOME:-$HOME/.local/state}/wb/continue/<stem>/:
#   request      key=value lines, one per field (WBC_FIELDS below)
#   entry.md     the Handoffs entry as it was when the request was made, frozen
#   instruction  the raw instruction text (absent when there is none)
#   row          one picker line: state<TAB>reason<TAB>done-line<TAB>command
# The files other than `row` are never rewritten after the request is made, so
# what pickup prints is exactly what was armed. Every state change happens under
# the lock `continue-<stem>` (taken before the task lock whenever both are
# needed), appends one line to .../wb/continue.log, and rewrites `row`.
# wb/continue/born/<session-id> marks a session a restart started; "born" can
# never be a task stem, which always contains "--".
#
# States: armed (the Stop hook may restart the pane), claimed, restarting,
# ready (waits for a release), refused, failed.

WBC_FIELDS=(id stem task_file state reason typed declined restart_born command
  session_id pane tmux_session model entry_sha entry_heading tip tree_sha
  worktree created updated new_session_id
  last_stop last_busy effort permission_mode model_fallback)

wbc_dir() { printf '%s/%s\n' "$(wb_continue_state_root)" "$1"; }

# wbc_get <stem> <field> — the field's value (blank when unset or no request).
wbc_get() {
  local f line; f="$(wbc_dir "$1")/request"
  [ -f "$f" ] || return 1
  while IFS= read -r line || [ -n "$line" ]; do
    if [[ "$line" == "$2="* ]]; then printf '%s\n' "${line#*=}"; return 0; fi
  done < "$f"
  return 0
}

_wbc_oneline() { local v="${1//[$'\t\r\n']/ }"; printf '%s' "$v"; }

_wbc_write_file() { # <path> <content> — atomic: temp + mv
  local tmp="$1.tmp.$$"
  printf '%s' "$2" > "$tmp" && mv -f "$tmp" "$1"
}

# wbc_set <event> <stem> <state> <reason> [field=value ...] — CALLER HOLDS
# continue-<stem>. Merges the fields into the request (creating it), sets state
# and reason, stamps `updated`, rewrites `row`, appends the log line (not for
# the event `snapshot`, the Stop hook's per-turn bookkeeping).
wbc_set() {
  local event="$1" stem="$2" state="$3" reason="$4"; shift 4
  local dir f line k kv_arg
  local -A kv=()
  dir="$(wbc_dir "$stem")"; mkdir -p "$dir" || return 1
  f="$dir/request"
  if [ -f "$f" ]; then
    while IFS= read -r line || [ -n "$line" ]; do
      kv["${line%%=*}"]="${line#*=}"
    done < "$f"
  fi
  for kv_arg in "$@"; do kv["${kv_arg%%=*}"]="${kv_arg#*=}"; done
  kv[stem]="$stem"; kv[state]="$state"; kv[reason]="$(_wbc_oneline "$reason")"
  kv[updated]="$(date +%s)"
  [ -n "${kv[created]:-}" ] || kv[created]="${kv[updated]}"
  local out=""
  for k in "${WBC_FIELDS[@]}"; do out+="$k=$(_wbc_oneline "${kv[$k]:-}")"$'\n'; done
  _wbc_write_file "$f" "$out" || return 1
  local done_line=""
  [ ! -f "$dir/entry.md" ] || done_line="$(_wbc_done_line "$dir/entry.md")"
  _wbc_write_file "$dir/row" "$state"$'\t'"${kv[reason]}"$'\t'"$(_wbc_oneline "$done_line")"$'\t'"${kv[command]:-}"$'\n'
  # The Stop hook's per-turn snapshot is not an event worth a log line.
  [ "$event" = snapshot ] || wb_continue_log "$event" "$stem" "${kv[id]:-}" "$state" "${kv[reason]}"
  return 0
}

# _wbc_done_line <entry-file> — first line of the entry's **Done:** field,
# bold leader stripped (the next non-blank line when the leader line is bare).
_wbc_done_line() {
  awk '
    found && NF { print; exit }
    !found && /^\*\*Done:\*\*/ { s = $0; sub(/^\*\*Done:\*\*[ \t]*/, "", s); if (s != "") { print s; exit } found = 1 }
  ' "$1"
}

_wbc_lock() { wb_task_lock_acquire_guarded "continue-$1"; }
_wbc_unlock() { wb_task_lock_release "continue-$1"; }

# _wbc_resolve_task [<task>] — the task file: <task> like wb append, else the
# current tmux session's task.
_wbc_resolve_task() {
  local q="${1:-}" session f
  if [ -n "$q" ]; then _wb_append_resolve_task "$q" "wb continue"; return; fi
  if [ -n "${TMUX_PANE:-}" ]; then
    session="$(tmux display-message -p -t "$TMUX_PANE" '#S' 2>/dev/null)" || session=""
    if [ -n "$session" ] && f="$(wb_session_task_file "$session")" && [ -f "$f" ]; then
      printf '%s\n' "$f"; return 0
    fi
  fi
  echo "wb continue: no task given and the current tmux session has none (pass <task>)" >&2
  return 1
}

# _wbc_live_entry <task-file> — the Handoffs entry (from its first "### " line,
# trailing blank lines dropped); returns 1 when there is none.
_wbc_live_entry() {
  local text
  _wb_has_heading "$1" Handoffs || return 1
  text="$(_wb_section_text "$1" Handoffs | awk 'f || /^### / { f = 1; print }')"
  [ -n "$text" ] || return 1
  printf '%s\n' "$text"
}

_wbc_sha() { sha256sum | cut -d' ' -f1; }

# _wbc_worktree <task-file> — the task's worktree, from its frontmatter the way
# cmd_down derives it.
_wbc_worktree() {
  local repo branch rel
  repo="$(wb_get_frontmatter "$1" repo)"
  branch="$(wb_get_frontmatter "$1" branch)"
  rel="$(wb_get_frontmatter "$1" worktree)"
  [ -n "$rel" ] || rel=".worktrees/$branch"
  printf '%s/%s\n' "$(wb_repo_dir "$repo")" "$rel"
}

# _wbc_tip <worktree> / _wbc_tree_sha <worktree> — the drift snapshot: branch
# tip, and a hash of status, diff against HEAD and each untracked file's bytes,
# so an edit to an already-dirty file or to an untracked file changes it.
_wbc_tip() { GIT_OPTIONAL_LOCKS=0 git -C "$1" rev-parse HEAD 2>/dev/null || true; }
_wbc_tree_sha() {
  local wt="$1" f
  [ -d "$wt" ] || return 0
  {
    GIT_OPTIONAL_LOCKS=0 git -C "$wt" status --porcelain=v1 -uall 2>/dev/null
    GIT_OPTIONAL_LOCKS=0 git -C "$wt" diff HEAD --binary 2>/dev/null
    while IFS= read -r -d '' f; do
      printf '%s ' "$f"; sha256sum < "$wt/$f" 2>/dev/null
    done < <(GIT_OPTIONAL_LOCKS=0 git -C "$wt" ls-files --others --exclude-standard -z 2>/dev/null)
  } | _wbc_sha
}

# wbc_drift_check <stem> — prints the reason and returns 1 on the first failing
# check; 0 when the request still matches what is live. Callers check the state
# themselves: the helper runs this while the request is claimed, pickup while
# it is restarting.
wbc_drift_check() {
  local stem="$1" dir f live heading
  dir="$(wbc_dir "$stem")"
  [ -f "$dir/request" ] || { echo "no continue request for $stem"; return 1; }
  f="$(wbc_get "$stem" task_file)"
  [ -f "$f" ] || { echo "the task file is gone"; return 1; }
  live="$(_wbc_live_entry "$f")" || live=""
  heading="${live%%$'\n'*}"
  [ "$heading" = "$(wbc_get "$stem" entry_heading)" ] \
    || { echo "a newer Handoffs entry landed since the save"; return 1; }
  [ "$(printf '%s\n' "$live" | _wbc_sha)" = "$(wbc_get "$stem" entry_sha)" ] \
    || { echo "the save entry changed since it was armed"; return 1; }
  local wt; wt="$(wbc_get "$stem" worktree)"
  [ "$(_wbc_tip "$wt")" = "$(wbc_get "$stem" tip)" ] \
    || { echo "branch moved since the save"; return 1; }
  [ "$(_wbc_tree_sha "$wt")" = "$(wbc_get "$stem" tree_sha)" ] \
    || { echo "working tree changed since the save"; return 1; }
  return 0
}

# --- the session's own facts -------------------------------------------------

_wbc_transcript() {
  local t g
  if [ -n "${WBC_TRANSCRIPT:-}" ]; then printf '%s\n' "$WBC_TRANSCRIPT"; return 0; fi
  [ -n "${CLAUDE_CODE_SESSION_ID:-}" ] || return 1
  for g in "$HOME"/.claude/projects/*/"$CLAUDE_CODE_SESSION_ID.jsonl"; do
    if [ -f "$g" ]; then t="$g"; break; fi
  done
  [ -n "${t:-}" ] && printf '%s\n' "$t"
}

# _wbc_typed_info — sets WBC_TYPED (1 only when the prompt that opened the
# current turn is a person's typed /wb-continue) and WBC_TYPED_ARGS (the raw
# text between <command-args> and the last </command-args>). The opener is the
# LAST user line with a turnOrigin (tool results and skill bodies have none; a
# cron-fired prompt has one, "scheduled", and no origin). Any doubt: 0.
_wbc_typed_info() {
  WBC_TYPED=0; WBC_TYPED_ARGS=""
  local tr last kind turn content rest
  tr="$(_wbc_transcript)" || return 0
  [ -r "$tr" ] || return 0
  last="$(grep -F '"turnOrigin"' "$tr" 2>/dev/null \
    | jq -cR 'fromjson? | select(type == "object" and .type == "user" and (.turnOrigin != null))' 2>/dev/null \
    | tail -n 1)" || last=""
  [ -n "$last" ] || return 0
  turn="$(printf '%s' "$last" | jq -r '.turnOrigin // empty' 2>/dev/null)" || return 0
  kind="$(printf '%s' "$last" | jq -r '.origin.kind // empty' 2>/dev/null)" || return 0
  [ "$turn" = human ] && [ "$kind" = human ] || return 0
  content="$(printf '%s' "$last" | jq -j 'if (.message.content | type) == "string" then .message.content else empty end' 2>/dev/null; printf x)"
  content="${content%x}"
  case "$content" in *'<command-name>/wb-continue</command-name>'*) ;; *) return 0 ;; esac
  WBC_TYPED=1
  local open='<command-args>' close='</command-args>'
  if [[ "$content" == *"$open"* ]]; then
    rest="${content#*"$open"}"
    WBC_TYPED_ARGS="${rest%"$close"*}"
  fi
  return 0
}

_wbc_model() {
  local tr; tr="$(_wbc_transcript)" || return 0
  [ -r "$tr" ] || return 0
  grep -F '"assistant"' "$tr" 2>/dev/null \
    | jq -rR 'fromjson? | select(type == "object" and .type == "assistant") | .message.model // empty' 2>/dev/null \
    | tail -n 1
}

_wbc_born() { [ -n "${CLAUDE_CODE_SESSION_ID:-}" ] && [ -e "$(wb_continue_state_root)/born/$CLAUDE_CODE_SESSION_ID" ]; }

# _wbc_run_block <entry-file> — the lines of the entry's first ```run fence.
_wbc_run_block() {
  awk '/^```run[ \t]*$/ && !seen { inb = 1; seen = 1; next } inb && /^```/ { exit } inb { print }' "$1"
}

# wbc_command_full <stem> — the command to carry out: the instruction when the
# request has one, else the frozen entry's run block (may be empty).
wbc_command_full() {
  local dir; dir="$(wbc_dir "$1")"
  if [ -f "$dir/instruction" ]; then cat "$dir/instruction"; else _wbc_run_block "$dir/entry.md"; fi
}

_wbc_is_review() {
  local c="$1" first
  c="${c#"${c%%[![:space:]]*}"}"
  first="${c%%[[:space:]]*}"
  case "$first" in /ce-code-review|/compound-engineering:ce-code-review|/code-review) return 0 ;; esac
  return 1
}

# --- stage / arm ---------------------------------------------------------------

# _wbc_make <verb> <task> <decline> — shared body of stage and arm. Instruction
# comes from the typed prompt record, else stdin (session-initiated arm only).
_wbc_make() {
  local verb="$1" task="$2" decline="$3"
  local task_file stem existing_state
  task_file="$(_wbc_resolve_task "$task")" || return 1
  stem="$(basename -- "$task_file" .md)"

  local typed=0 instruction="" born=0
  if [ "$verb" = arm ]; then
    _wbc_typed_info
    if [ "$WBC_TYPED" = 1 ]; then typed=1; instruction="$WBC_TYPED_ARGS"
    elif [ ! -t 0 ]; then instruction="$(cat)"; fi
    [[ "$instruction" == *[![:space:]]* ]] || instruction=""
  fi
  _wbc_born && born=1

  _wbc_lock "$stem" || return $?
  existing_state="$(wbc_get "$stem" state 2>/dev/null)" || existing_state=""
  case "$existing_state" in
    claimed|restarting)
      _wbc_unlock "$stem"
      echo "wb continue: $verb left alone — the request for $stem is $existing_state" >&2
      [ "$verb" = stage ] && return 0
      return 1 ;;
  esac

  # The live entry, read under the task lock (continue-<stem> is already held).
  local entry heading
  wb_task_lock_acquire_guarded "$task_file" || { _wbc_unlock "$stem"; return 1; }
  entry="$(_wbc_live_entry "$task_file")" || entry=""
  wb_task_lock_release "$task_file"
  heading="${entry%%$'\n'*}"
  if [[ "$heading" != *' — wb-save' ]]; then
    _wbc_unlock "$stem"
    echo "wb continue: $verb refused — the live Handoffs entry in $stem is not a /wb-save entry (run /wb-save first)" >&2
    return 1
  fi

  local dir; dir="$(wbc_dir "$stem")"
  mkdir -p "$dir" || { _wbc_unlock "$stem"; return 1; }
  _wbc_write_file "$dir/entry.md" "$entry"$'\n'
  if [ -n "$instruction" ]; then _wbc_write_file "$dir/instruction" "$instruction"; else rm -f "$dir/instruction"; fi

  local command
  command="$(wbc_command_full "$stem")"
  command="$(_wbc_oneline "$command")"
  command="${command#"${command%%[![:space:]]*}"}"; command="${command%"${command##*[![:space:]]}"}"

  local state reason
  if [ "$verb" = stage ]; then state=ready; reason="saved; waits for a release"
  elif [ "$decline" = 1 ]; then state=ready; reason="the session declined an automatic restart"
  elif [ "$typed" = 1 ]; then state=armed; reason="typed by Jet"
  elif [ "$born" = 1 ]; then state=ready; reason="a restart-born session cannot restart itself"
  elif _wbc_is_review "$command"; then state=armed; reason="a code review, requested by the session"
  else state=ready; reason="the command is not a code review"; fi

  local wt model pane tsess
  wt="$(_wbc_worktree "$task_file")"
  model="$(_wbc_model)"; pane="${TMUX_PANE:-}"; tsess=""
  if [ -n "$pane" ]; then tsess="$(tmux display-message -p -t "$pane" '#S' 2>/dev/null)" || tsess=""; fi
  local id; id="$stem@$(od -An -N4 -tx1 /dev/urandom | tr -d ' \n')"

  # A fresh request: blank every field the old one may have set.
  rm -f "$dir/request"
  wbc_set "$verb" "$stem" "$state" "$reason" \
    "id=$id" "task_file=$task_file" "typed=$typed" "declined=$decline" "restart_born=$born" \
    "command=$command" "session_id=${CLAUDE_CODE_SESSION_ID:-}" "pane=$pane" "tmux_session=$tsess" \
    "model=$model" "entry_sha=$(printf '%s\n' "$entry" | _wbc_sha)" "entry_heading=$heading" \
    "tip=$(_wbc_tip "$wt")" "tree_sha=$(_wbc_tree_sha "$wt")" "worktree=$wt" "new_session_id="
  local rc=$?
  _wbc_unlock "$stem"
  [ "$rc" = 0 ] || return "$rc"
  # A fresh save clears a refusal or failure reason the pane's status shows.
  [ -z "$pane" ] || tmux set -p -u -t "$pane" @wb_continue_reason 2>/dev/null || true
  echo "wb continue: $state — $reason ($id)"
}

wbc_stage() { _wbc_make stage "${1:-}" 0; }
wbc_arm() {
  local decline=0 task=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --decline) decline=1 ;;
      *) task="$1" ;;
    esac
    shift
  done
  _wbc_make arm "$task" "$decline"
}

# --- status / drop ---------------------------------------------------------------

wbc_status() {
  local task_file stem k
  task_file="$(_wbc_resolve_task "${1:-}")" || return 1
  stem="$(basename -- "$task_file" .md)"
  if [ ! -f "$(wbc_dir "$stem")/request" ]; then echo "no continue request for $stem"; return 0; fi
  for k in "${WBC_FIELDS[@]}"; do printf '%s=%s\n' "$k" "$(wbc_get "$stem" "$k")"; done
}

wbc_drop() {
  local task_file stem
  task_file="$(_wbc_resolve_task "${1:-}")" || return 1
  stem="$(basename -- "$task_file" .md)"
  if [ ! -f "$(wbc_dir "$stem")/request" ]; then echo "no continue request for $stem"; return 0; fi
  _wbc_lock "$stem" || return $?
  wb_continue_drop_files "$stem" drop "dropped by wb continue drop"
  _wbc_unlock "$stem"
  echo "wb continue: dropped the request for $stem"
}

# --- pickup ------------------------------------------------------------------------

_wbc_refuse_msg() {
  echo "wb continue: refused — $1" >&2
  echo "Fall back by hand: /clear, then /wb-resume." >&2
}

# wbc_pickup <request-id> — single use; run by the fresh Claude. Prints the
# frozen entry and the command, or the refusal.
wbc_pickup() {
  local id="${1:-}"
  if [ -z "$id" ] || [[ "$id" != *@* ]]; then echo "usage: wb continue pickup <request-id>" >&2; return 2; fi
  local stem="${id%@*}"
  _wbc_lock "$stem" || return $?

  # Identity checks say nothing about the request's own save, so they refuse
  # without touching the request (the right session can still pick it up).
  local dir; dir="$(wbc_dir "$stem")"
  if [ ! -f "$dir/request" ]; then
    _wbc_unlock "$stem"; _wbc_refuse_msg "no continue request for $stem"; return 1
  fi
  local reason=""
  if [ "$(wbc_get "$stem" id)" != "$id" ]; then reason="the request id does not match the one on file for $stem"
  elif [ "$(wbc_get "$stem" state)" != restarting ]; then reason="the request for $stem is $(wbc_get "$stem" state), not restarting"
  elif [ -z "${CLAUDE_CODE_SESSION_ID:-}" ] || [ "${CLAUDE_CODE_SESSION_ID}" != "$(wbc_get "$stem" new_session_id)" ]; then
    reason="pick-up from a session other than the one the restart started"
  fi
  if [ -n "$reason" ]; then
    wb_continue_log pickup "$stem" "$id" "$(wbc_get "$stem" state)" "refused without change: $reason"
    _wbc_unlock "$stem"; _wbc_refuse_msg "$reason"; return 1
  fi

  local task_file; task_file="$(wbc_get "$stem" task_file)"
  if [ ! -f "$task_file" ]; then
    wbc_set pickup "$stem" refused "the task file is gone"
    _wbc_unlock "$stem"; _wbc_refuse_msg "the task file is gone"; return 1
  fi
  if ! wb_task_lock_acquire_guarded "$task_file"; then
    _wbc_unlock "$stem"; return 1
  fi
  if ! reason="$(wbc_drift_check "$stem")"; then
    wbc_set pickup "$stem" refused "$reason"
    wb_task_lock_release "$task_file"; _wbc_unlock "$stem"
    _wbc_refuse_msg "$reason"; return 1
  fi

  local entry command heading ts old
  entry="$(cat "$dir/entry.md")"
  command="$(wbc_command_full "$stem")"
  heading="$(wbc_get "$stem" entry_heading)"
  ts="${heading#\#\#\# }"; ts="${ts%% — *}"
  old="$(wbc_get "$stem" session_id)"
  local fallback; fallback="$(wbc_get "$stem" model_fallback)"
  local msg="Continued in a fresh context from the save of $ts"
  if [ -n "$old" ]; then msg+=" (old session $old; \`claude --resume $old\` reopens it)"; fi
  msg+="."
  if ! wb_append_handoff "$task_file" "wb continue" "$msg"; then
    wbc_set pickup "$stem" failed "could not write the Handoffs entry"
    wb_task_lock_release "$task_file"; _wbc_unlock "$stem"
    _wbc_refuse_msg "could not write the Handoffs entry"; return 1
  fi
  wb_task_lock_release "$task_file"
  wb_continue_drop_files "$stem" pickup "picked up by the fresh session"
  _wbc_unlock "$stem"

  echo "wb continue: pickup ok for $stem"
  [ "$fallback" != 1 ] || echo "Note: the old session's model could not be read; this session runs on the default model."
  echo "=== Frozen save entry (verbatim) ==="
  printf '%s\n' "$entry"
  echo "=== End of frozen save entry ==="
  if [ -n "$command" ]; then
    echo "Command to carry out:"
    printf '%s\n' "$command"
  else
    echo "Command to carry out: none recorded; follow the entry's Next prose."
  fi
}

# wbc_release <task> | --all | --pane <pane-id> — Jet's release of a ready, failed
# or armed request: the helper's checks, then the restart, started detached so
# the picker and the tmux key return at once. The logic lives with the helper in
# wb-continue-hook.sh (one set of checks); this runs it as a child.
wbc_release() {
  local helper_sh="${BASH_SOURCE[0]%/*}/wb-continue-hook.sh"
  case "${1:-}" in
    -h|--help) echo "usage: wb continue release <task> | --all | --pane <pane-id>"; return 0 ;;
  esac
  if [ ! -f "$helper_sh" ]; then echo "wb continue release: $helper_sh is missing" >&2; return 1; fi
  "$BASH" "$helper_sh" release "$@"
}

wbc_main() {
  local verb="${1:-}"
  [ $# -eq 0 ] || shift
  _wb_lock_trap_append_if_top_level wb_task_lock_release_all
  case "$verb" in
    stage)   wbc_stage "$@" ;;
    arm)     wbc_arm "$@" ;;
    status)  wbc_status "$@" ;;
    drop)    wbc_drop "$@" ;;
    pickup)  wbc_pickup "$@" ;;
    release) wbc_release "$@" ;;
    *) echo "usage: wb continue stage|arm|status|drop|pickup|release ... (see wb help)" >&2; return 2 ;;
  esac
}
