#!/usr/bin/env bash
# wb-continue-hook.sh — the Stop and SessionStart hooks of `wb continue`, and
# the helper the Stop hook starts. A saved session that asked to carry on in a
# fresh context (a request under ${XDG_STATE_HOME:-~/.local/state}/wb/continue/,
# see wb-continue.sh) is restarted here: the same pane, a fresh Claude, handed a
# script-verified copy of the save through `wb continue pickup`.
#
# Wired by the hooks-only wb-continue-hook plugin
# (claude/.claude/skills/wb-continue-hook/hooks/hooks.json, stowed into
# ~/.claude/skills/). Never also wire these in ~/.claude/settings.json: plugin
# and settings hooks both run, so every event would fire twice. WB_CONTINUE_BIN
# overrides where the plugin finds this script (default ~/.config/scripts/tmux).
#   Stop          -> wb-continue-hook.sh hook-stop
#   SessionStart  -> wb-continue-hook.sh hook-session-start
#
#   hook-stop            record the turn's snapshot on this session's request;
#                        for an armed request apply the guards (age, background
#                        work, scheduled jobs, a /decide surface, Jet looking)
#                        and, when all clear, claim it and start the helper
#   hook-session-start   a /clear by hand drops the pane's request
#   helper <stem> <id> [release]
#                        run by the tmux server (so it outlives the pane it
#                        respawns): settle, re-check, confirm the pane's Claude,
#                        then restart the pane's shell and type the launch
#                        command, and wait for the fresh Claude's pick-up. The
#                        `release` flag (Jet's own release, KTD11) skips shadow
#                        mode and returns a pane that is busy to `ready`
#   release <task> | --all | --pane <pane-id>
#                        what `wb continue release` runs: the same checks and
#                        restart as the Stop hook path, started by Jet
#
# The hooks run on every turn end of every Claude, so everything before a
# request matches is plain bash: the kill switch, three environment guards, a
# glob and a read loop. No tmux call, no jq, no wb.sh source until a request
# names this session. Always exits 0 and prints nothing.
#
# Files in ${XDG_STATE_HOME:-~/.local/state}/wb:
#   disable-continue   kill switch: the hooks exit at once while it exists
#   continue-live      shadow mode is ON unless this exists: the helper runs
#                      every check, logs "would-restart" and stops short of the
#                      respawn (the key and the picker release are not shadowed)
#
# Tunables (env; the helper reads the tmux server's environment, so set them
# with `tmux set-environment -g`): WB_CONTINUE_MAX_AGE (1800 s an armed request
# may wait), WB_CONTINUE_SETTLE_MS (1500) and WB_CONTINUE_SETTLE_MAX_MS (5000)
# for the idle wait, WB_CONTINUE_PROMPT_TIMEOUT (20 s for the shell to appear),
# WB_CONTINUE_PICKUP_TIMEOUT (120 s for the pick-up), WB_CONTINUE_SESSIONS_DIR
# (Claude's session registry, default ~/.claude/sessions).
set -uo pipefail

WBCH_SRC="${BASH_SOURCE[0]}"
case "$WBCH_SRC" in */*) WBCH_DIR="${WBCH_SRC%/*}" ;; *) WBCH_DIR=. ;; esac
WBCH_STATE="${XDG_STATE_HOME:-$HOME/.local/state}/wb"
WBCH_VERB="${1:-}"

# --- the cheap prefilter (plain bash, no forks) -----------------------------------

# wbch_any_request — true when at least one request file exists.
wbch_any_request() {
  local f
  for f in "$WBCH_STATE"/continue/*/request; do [ -f "$f" ] && return 0; done
  return 1
}

# wbch_find <field> <value> — sets WBCH_STEM to the first request whose
# `<field>=<value>` line matches exactly (fixed string); false when none does.
wbch_find() {
  local f line
  WBCH_STEM=""
  [ -n "$2" ] || return 1
  for f in "$WBCH_STATE"/continue/*/request; do
    [ -f "$f" ] || continue
    while IFS= read -r line || [ -n "$line" ]; do
      if [[ "$line" == "$1=$2" ]]; then
        f="${f%/request}"
        WBCH_STEM="${f##*/}"
        return 0
      fi
    done <"$f"
  done
  return 1
}

case "$WBCH_VERB" in
  hook-stop | hook-session-start)
    exec >/dev/null 2>&1
    [ -e "$WBCH_STATE/disable-continue" ] && exit 0
    [ "${CLAUDE_CODE_SESSION_ATTENDED:-}" = 0 ] && exit 0
    case "${CLAUDE_CODE_ENTRYPOINT:-}" in sdk*) exit 0 ;; esac
    [ -n "${TMUX_PANE:-}" ] || exit 0
    wbch_any_request || exit 0
    WBCH_INPUT=""
    [ -t 0 ] || IFS= read -r -d '' WBCH_INPUT || true # builtin: no fork
    if [ "$WBCH_VERB" = hook-stop ]; then
      [[ "$WBCH_INPUT" =~ \"session_id\"[[:space:]]*:[[:space:]]*\"([A-Za-z0-9._-]+)\" ]] || exit 0
      WBCH_SID="${BASH_REMATCH[1]}"
      wbch_find session_id "$WBCH_SID" || exit 0
    else
      [[ "$WBCH_INPUT" =~ \"source\"[[:space:]]*:[[:space:]]*\"clear\" ]] || exit 0
      wbch_find pane "$TMUX_PANE" || exit 0
    fi
    ;;
  helper) exec >/dev/null 2>&1 ;;
  release) ;; # Jet's own action: no kill switch, no hook guards, prints its result
  *) exit 0 ;;
esac

# wb.sh needs bash 5 and tmux's run-shell can find an older one first. Say so in
# the log, which a request's reader checks, and stop.
if [ "${BASH_VERSINFO[0]:-0}" -lt 5 ]; then
  mkdir -p "$WBCH_STATE" 2>/dev/null
  printf '%s wbc event=no-bash5 stem=%s id= state= reason="wb continue needs bash 5, found %s"\n' \
    "$(date '+%Y-%m-%dT%H:%M:%S%z')" "${WBCH_STEM:-${2:-}}" "${BASH_VERSION:-?}" >>"$WBCH_STATE/continue.log" 2>/dev/null
  exit 0
fi

# Sourced at the top level, not inside a function: wb.sh declares associative
# arrays that would turn local.
# shellcheck source=wb.sh
source "$WBCH_DIR/wb.sh" || exit 0
# shellcheck source=wb-continue.sh
source "$WBCH_DIR/wb-continue.sh" || exit 0
set +e +u
_wb_lock_trap_append_if_top_level wb_task_lock_release_all

# --- shared bits -----------------------------------------------------------------------

# wbch_looking <pane> — Jet is looking: the pane is in copy mode, or it is the
# active pane of the active window of a session with a client active within the
# last 60 seconds. One display-message and one list-clients.
wbch_looking() {
  local info mode pactive wactive sess act now
  info="$(tmux display-message -p -t "$1" '#{pane_in_mode}|#{pane_active}|#{window_active}|#{session_name}' 2>/dev/null)" || return 1
  IFS='|' read -r mode pactive wactive sess <<<"$info"
  [ "$mode" = 1 ] && return 0
  [ "$pactive" = 1 ] && [ "$wactive" = 1 ] || return 1
  now="$(date +%s)"
  while IFS= read -r act; do
    [[ "$act" =~ ^[0-9]+$ ]] || continue
    [ $((now - act)) -le 60 ] && return 0
  done < <(tmux list-clients -t "=$sess" -F '#{client_activity}' 2>/dev/null)
  return 1
}

# wbch_blocking_count <input-json> <transcript-path> <running-ids...> — prints
# how many of the running ids are not monitors. Monitors show as type "shell"
# in the payload, so they are told apart through the transcript: a line whose
# toolUseResult is an object with a `persistent` key names a monitor in its
# taskId. An unreadable transcript counts every running id (fail closed).
wbch_blocking_count() {
  local tpath="$1" id n=0 m
  shift
  local -A mon=()
  if [ "$#" -gt 0 ] && [ -r "$tpath" ]; then
    while IFS= read -r m; do [ -z "$m" ] || mon["$m"]=1; done < <(
      grep -F '"persistent"' "$tpath" 2>/dev/null |
        jq -rR 'fromjson? | select(type == "object") | .toolUseResult | select(type == "object" and has("persistent")) | .taskId // empty' 2>/dev/null
    )
  fi
  for id in "$@"; do [ -n "${mon[$id]:-}" ] || n=$((n + 1)); done
  printf '%s\n' "$n"
}

# --- hook-stop ----------------------------------------------------------------------------

wbch_stop() {
  local stem="$WBCH_STEM" sid="$WBCH_SID" line effort perm ncron tpath
  line="$(jq -r '[(.effort.level // ""), (.permission_mode // ""), ((.session_crons // []) | length), (.transcript_path // "")] | join("|")' <<<"$WBCH_INPUT" 2>/dev/null)"
  IFS='|' read -r effort perm ncron tpath <<<"$line"
  [[ "${ncron:-}" =~ ^[0-9]+$ ]] || ncron=1 # unreadable: assume a job is pending
  local -a running=()
  local nblock=0 parse_ok=1
  jq -e . >/dev/null 2>&1 <<<"$WBCH_INPUT" || parse_ok=0
  if [ "$parse_ok" = 1 ]; then
    mapfile -t running < <(jq -r '(.background_tasks // [])[] | select((.status // "running") == "running" and (.type // "") != "monitor") | .id // ""' <<<"$WBCH_INPUT" 2>/dev/null)
    nblock="$(wbch_blocking_count "$tpath" "${running[@]}")"
  else
    nblock=1
  fi
  local busy=0
  { [ "$nblock" -gt 0 ] || [ "$ncron" -gt 0 ]; } && busy=1

  _wbc_lock "$stem" || return 0
  local state now created reason event new_state cur_reason
  state="$(wbc_get "$stem" state)"
  if [ -z "$state" ] || [ "$(wbc_get "$stem" session_id)" != "$sid" ]; then
    _wbc_unlock "$stem"
    return 0
  fi
  now="$(date +%s)"
  cur_reason="$(wbc_get "$stem" reason)"
  local -a snap=("last_stop=$now" "last_busy=$busy" "effort=$effort" "permission_mode=$perm")
  new_state="$state"
  reason="$cur_reason"
  event=snapshot

  local claim=0
  if [ "$state" = armed ] && [ "$(wbc_get "$stem" pane)" = "$TMUX_PANE" ]; then
    created="$(wbc_get "$stem" created)"
    local max="${WB_CONTINUE_MAX_AGE:-1800}"
    if [[ "${created:-}" =~ ^[0-9]+$ ]] && [ $((now - created)) -gt "$max" ]; then
      new_state=ready
      event=hook-ready
      reason="waited $(((now - created) / 60)) minutes; release it from the picker"
    elif [ "$nblock" -gt 0 ]; then
      reason="waiting: background work still running"
    elif [ "$ncron" -gt 0 ]; then
      reason="waiting: a scheduled job is pending"
    elif [ -s "$(wb_needs_you_file "$stem")" ]; then
      reason="waiting: a /decide surface is open"
    elif [ "$(wbc_get "$stem" typed)" != 1 ] && wbch_looking "$TMUX_PANE"; then
      new_state=ready
      event=hook-ready
      reason="Jet was looking at the pane"
    else
      new_state=claimed
      event=hook-claim
      reason="claimed by the Stop hook"
      claim=1
    fi
    # A repeated wait reason is a snapshot, not a new log line.
    [ "$new_state" != armed ] || [ "$reason" = "$cur_reason" ] || event=hook-wait
  fi
  wbc_set "$event" "$stem" "$new_state" "$reason" "${snap[@]}"
  _wbc_unlock "$stem"
  [ "$claim" = 1 ] || return 0

  # Only the Stop that moved armed -> claimed gets here. The helper is owned by
  # the tmux server so it outlives the pane it respawns; only the stem and the
  # request id go on its command line.
  local id self cmd
  id="$(wbc_get "$stem" id)"
  self="$(readlink -f "$WBCH_SRC" 2>/dev/null)" || self="$WBCH_SRC"
  cmd="$(printf '%q ' "$BASH" "$self" helper "$stem" "$id")"
  if ! tmux run-shell -b -t "$TMUX_PANE" "$cmd" 2>/dev/null; then
    _wbc_lock "$stem" || return 0
    if [ "$(wbc_get "$stem" id)" = "$id" ] && [ "$(wbc_get "$stem" state)" = claimed ]; then
      wbc_set hook-ready "$stem" ready "tmux could not start the helper; release it from the picker"
    fi
    _wbc_unlock "$stem"
  fi
  return 0
}

# --- hook-session-start ----------------------------------------------------------------------

# A /clear by hand gives the session a NEW id, so the request is found by its
# pane, and only dropped when the pane's tmux session is that request's task.
wbch_session_start() {
  local stem="$WBCH_STEM" sess file
  [ "$(jq -r '.source // empty' <<<"$WBCH_INPUT" 2>/dev/null)" = clear ] || return 0
  sess="$(tmux display-message -p -t "$TMUX_PANE" '#S' 2>/dev/null)" || return 0
  [ -n "$sess" ] || return 0
  file="$(wb_session_task_file "$sess" 2>/dev/null)" || return 0
  [ "$file" = "$(wbc_get "$stem" task_file)" ] || return 0
  _wbc_lock "$stem" || return 0
  if [ "$(wbc_get "$stem" pane)" = "$TMUX_PANE" ]; then
    wb_continue_drop_files "$stem" session-clear "cleared by hand"
  fi
  _wbc_unlock "$stem"
  return 0
}

# --- the helper ---------------------------------------------------------------------------------

WBCH_DONE=0 WBCH_ID="" WBCH_PANE="" WBCH_RELEASE="" WBCH_DRIFT=""

# wbch_on_exit — the helper never leaves a request claimed or restarting
# without a word: on any exit it did not plan, say so in the request and log.
# shellcheck disable=SC2329 # runs as the EXIT trap (wbch_on_exit_trap)
wbch_on_exit() {
  [ "$WBCH_VERB" = helper ] && [ "$WBCH_DONE" = 0 ] && [ -n "$WBCH_STEM" ] || return 0
  local state
  state="$(wbc_get "$WBCH_STEM" state 2>/dev/null)"
  [ "$(wbc_get "$WBCH_STEM" id 2>/dev/null)" = "$WBCH_ID" ] || return 0
  case "$state" in
    claimed) wbch_set helper-crash ready "the helper stopped unexpectedly; release it from the picker" ;;
    restarting) wbch_set helper-crash failed "the helper stopped unexpectedly after the restart began; the old session is $(wbc_get "$WBCH_STEM" session_id): claude --resume $(wbc_get "$WBCH_STEM" session_id)" ;;
  esac
}

# wbch_pane_reason <text> — the lasting reason on the pane (empty clears it).
wbch_pane_reason() {
  [ -n "$WBCH_PANE" ] || return 0
  if [ -n "$1" ]; then
    tmux set -p -t "$WBCH_PANE" @wb_continue_reason "$1" 2>/dev/null
  else tmux set -p -u -t "$WBCH_PANE" @wb_continue_reason 2>/dev/null; fi
  return 0
}

# wbch_stale_exit — the request was replaced or dropped while the helper ran
# (the caller has released the lock): log it and end the helper quietly.
wbch_stale_exit() {
  wb_continue_log helper-stale "$WBCH_STEM" "$WBCH_ID" gone "the request was replaced or dropped while the helper ran"
  WBCH_DONE=1
  exit 0
}

# wbch_set <event> <state> <reason> [field=value ...] — a state change under
# the lock. A request that was replaced or dropped meanwhile ends the helper.
wbch_set() {
  _wbc_lock "$WBCH_STEM" || return 1
  if [ "$(wbc_get "$WBCH_STEM" id)" != "$WBCH_ID" ]; then
    _wbc_unlock "$WBCH_STEM"
    wbch_stale_exit
  fi
  local ev="$1"
  shift
  wbc_set "$ev" "$WBCH_STEM" "$@"
  local rc=$?
  _wbc_unlock "$WBCH_STEM"
  return "$rc"
}

# wbch_end <event> <state> <reason> [field=value ...] — change state and end.
# A refusal or failure also becomes the pane's lasting reason.
wbch_end() {
  local st="$2" why="$3"
  wbch_set "$@"
  case "$st" in refused | failed) wbch_pane_reason "$why" ;; esac
  WBCH_DONE=1
  exit 0
}

# wbch_back_armed <reason> — the request waits for the next quiet turn end.
# A release by Jet goes back to `ready` instead: an `armed` request would let a
# later Stop restart a pane Jet only meant to release by hand.
wbch_back_armed() {
  if [ "$WBCH_RELEASE" = release ]; then
    wbch_pane_reason "$1"
    wbch_end helper-ready ready "$1" new_session_id= model_fallback=
  fi
  wbch_end helper-armed armed "$1" new_session_id= model_fallback=
}

# wbch_input_pending <pane> — text on Claude's input line, or no input line on
# screen (a dialog, a menu, an unreadable screen: fail closed); WBCH_PENDING
# says which. The input line is the last line that starts with the prompt glyph
# followed by a no-break space (transcript lines use a plain space). An empty
# line is blank or shows a dim placeholder; typed text is not dim.
wbch_input_pending() {
  local screen line plain rest prompt=$'\xe2\x9d\xaf\xc2\xa0' found=""
  screen="$(wb_capture_pane "$1")" || screen=""
  while IFS= read -r line; do
    plain="${line//$'\e'\[[0-9;]*m/}"
    [[ "$plain" == "$prompt"* ]] && found="$line"
  done <<<"$screen"
  WBCH_PENDING="text or a dialog on the input line"
  [ -n "$found" ] || return 0
  rest="${found#*"$prompt"}"
  rest="${rest//$'\e'\[[039]m/}"
  rest="${rest//$'\e'\[49m/}"
  rest="${rest//$'\e'\[m/}"
  while [[ "$rest" == *[[:space:]] ]]; do rest="${rest%?}"; done
  [ -n "$rest" ] && [[ "$rest" != $'\e[2m'* ]]
}

# wbch_settle <pane> — wait until @claude_working has been empty for the whole
# settle time (the notify hook clears it on Stop, alongside this hook); false
# when it stays set, or is set again, past the overall limit.
wbch_settle() {
  local need="${WB_CONTINUE_SETTLE_MS:-1500}" max="${WB_CONTINUE_SETTLE_MAX_MS:-5000}"
  local t0 now clear_since="" working
  t0="${EPOCHREALTIME/./}"
  while :; do
    now="${EPOCHREALTIME/./}"
    working="$(tmux show -pv -t "$1" @claude_working 2>/dev/null)"
    if [ -n "$working" ]; then
      clear_since=""
    else
      [ -n "$clear_since" ] || clear_since="$now"
      [ $(((now - clear_since) / 1000)) -ge "$need" ] && return 0
    fi
    [ $(((now - t0) / 1000)) -ge "$max" ] && return 1
    sleep 0.1
  done
}

# wbch_descends <pid> <ancestor> — true when <pid> is <ancestor> or below it.
wbch_descends() {
  local p="$1" top="$2" n=0 stat rest
  while [ "$n" -lt 30 ] && [[ "$p" =~ ^[0-9]+$ ]] && [ "$p" -gt 1 ]; do
    [ "$p" = "$top" ] && return 0
    stat="$(<"/proc/$p/stat")" 2>/dev/null || return 1
    rest="${stat##*) }"
    # shellcheck disable=SC2086 # split on purpose: the stat fields
    set -- $rest
    p="${2:-}"
    n=$((n + 1))
  done
  return 1
}

# wbch_pane_claude_is <pane> <session-id> — a live Claude process under the pane
# registered that session id (KTD3). A headless child's own entry never matches.
wbch_pane_claude_is() {
  local panepid dir f b sid
  panepid="$(tmux display-message -p -t "$1" '#{pane_pid}' 2>/dev/null)"
  [[ "$panepid" =~ ^[0-9]+$ ]] || return 1
  dir="${WB_CONTINUE_SESSIONS_DIR:-$HOME/.claude/sessions}"
  for f in "$dir"/*.json; do
    [ -f "$f" ] || continue
    b="${f##*/}"
    b="${b%.json}"
    [[ "$b" =~ ^[0-9]+$ ]] && [ -d "/proc/$b" ] || continue
    wbch_descends "$b" "$panepid" || continue
    sid="$(jq -r '.sessionId // empty' "$f" 2>/dev/null)"
    [ "$sid" = "$2" ] && return 0
  done
  return 1
}

# wbch_drift_probe <stem> — the drift check under the task lock; the caller
# holds continue-<stem>. Sets WBCH_DRIFT to the reason ("" when none) and
# returns 1 on a drift. (A global, not a printed value: a command substitution
# would take the task lock in a subshell.)
wbch_drift_probe() {
  local task_file
  task_file="$(wbc_get "$1" task_file)"
  wb_task_lock_acquire_guarded "$task_file" >/dev/null 2>&1 || true
  WBCH_DRIFT=""
  WBCH_DRIFT="$(wbc_drift_check "$1")" || {
    wb_task_lock_release "$task_file" 2>/dev/null
    return 1
  }
  wb_task_lock_release "$task_file" 2>/dev/null
  return 0
}

# wbch_drift — the drift check under both locks; a drift refuses the request.
wbch_drift() {
  _wbc_lock "$WBCH_STEM" || return 1
  if [ "$(wbc_get "$WBCH_STEM" id)" != "$WBCH_ID" ]; then
    _wbc_unlock "$WBCH_STEM"
    wbch_stale_exit
  fi
  wbch_drift_probe "$WBCH_STEM" || {
    wbc_set helper-refused "$WBCH_STEM" refused "$WBCH_DRIFT"
    _wbc_unlock "$WBCH_STEM"
    wbch_pane_reason "$WBCH_DRIFT"
    WBCH_DONE=1
    exit 0
  }
  _wbc_unlock "$WBCH_STEM"
  return 0
}

# wbch_safe_word <value> — the value when it is safe to put on the launch line.
wbch_safe_word() { [[ "$1" =~ ^[A-Za-z0-9._:-]+$ ]] && printf '%s' "$1"; }

# wbch_unseen_scan <pane> <old-session-id> — how many of the old session's turns
# Jet has not seen, before the restart takes the pane away. Sets WBCH_UNSEEN_N and
# WBCH_UNSEEN_FIRST (the first such turn's prompt id, the viewer's divider target).
# A turn counts by its END (the timestamp of its last transcript line), not its
# prompt: one that started while Jet watched and finished after he left is unseen.
# Turns are cut at user lines carrying a turnOrigin, and consecutive such lines
# merge (the reply log groups them the same way, under the last prompt id). The
# pane's @wb_seen_at stamp is the last focus-in or focus-out; none counts every
# turn. A pane Jet is looking at counts as seen up to now. Only turns with an
# anchor in the old session's reply file count, so the viewer can find them.
wbch_unseen_scan() {
  local pane="$1" old="$2" stamp tp="" f rf end pid id n=0 first=""
  WBCH_UNSEEN_N=0 WBCH_UNSEEN_FIRST=""
  [[ "$old" =~ ^[A-Za-z0-9-]+$ ]] || return 0
  wbch_looking "$pane" && return 0
  stamp="$(tmux show -pv -t "$pane" @wb_seen_at 2>/dev/null)"
  [[ "$stamp" =~ ^[0-9]+$ ]] || stamp=-1
  tp="$(_wbc_transcript_of "$old")"
  [ -n "$tp" ] || return 0
  rf="${REPLY_LOG_DIR:-$HOME/.claude/replies}/$old.md"
  [ -r "$rf" ] || return 0
  local -A anchors=()
  while IFS= read -r id; do [ -z "$id" ] || anchors["$id"]=1; done < <(
    grep -o '"prompt_id":"[A-Za-z0-9-]*"' "$rf" 2>/dev/null | sed 's/^"prompt_id":"//; s/"$//')
  while IFS=$'\t' read -r end pid; do
    [[ "$end" =~ ^[0-9]+$ ]] && [ "$end" -gt "$stamp" ] || continue
    [ -n "${anchors[$pid]:-}" ] || continue
    n=$((n + 1))
    [ -n "$first" ] || first="$pid"
  done < <(jq -rn -R '
    def ep: try (sub("\\.[0-9]+Z$"; "Z") | fromdateiso8601) catch null;
    reduce (inputs | fromjson? | select(type == "object")) as $e ({g: [], ls: false};
      if ($e.type == "user" and ($e.turnOrigin // null) != null and ($e.isSidechain // false | not)) then
        if .ls then .g[-1].pid = ($e.promptId // .g[-1].pid)
        else .g += [{pid: ($e.promptId // ""), end: ($e.timestamp | ep)}] end | .ls = true
      elif (.g | length) == 0 then .
      else .ls = false | (($e.timestamp // null) | ep) as $t | if $t != null then .g[-1].end = $t else . end end)
    | .g[] | select(.end != null and .pid != "") | "\(.end)\t\(.pid)"' <"$tp" 2>/dev/null)
  WBCH_UNSEEN_N="$n"
  WBCH_UNSEEN_FIRST="$first"
  return 0
}

# wbch_unseen_write <stem> <pane> <old-session-id> — after a restart that went
# ahead: append "<old id> <count> <first unseen prompt id>" to the task's unseen
# file (a second restart adds a line; the mark is the sum) and put the sum on the
# pane, which survives the respawn. Nothing when the count is 0. Lives outside
# the request dir because the request is removed at pick-up.
wbch_unseen_write() {
  local stem="$1" pane="$2" old="$3" dir f
  [ "${WBCH_UNSEEN_N:-0}" -gt 0 ] || return 0
  dir="$(wb_continue_state_root)/unseen"
  mkdir -p "$dir" 2>/dev/null || return 0
  f="$dir/$stem"
  printf '%s %s %s\n' "$old" "$WBCH_UNSEEN_N" "$WBCH_UNSEEN_FIRST" >>"$f" 2>/dev/null || return 0
  wb_continue_unseen_sum "$f"
  tmux set -p -t "$pane" @wb_unseen "$WB_UNSEEN_SUM" 2>/dev/null
  return 0
}

wbch_helper() {
  local stem="$WBCH_STEM" id="$WBCH_ID" state pane wt old
  state="$(wbc_get "$stem" state 2>/dev/null)"
  if [ "$(wbc_get "$stem" id 2>/dev/null)" != "$id" ] || [ "$state" != claimed ]; then
    wb_continue_log helper-stale "$stem" "$id" "${state:-gone}" "the helper found the request changed before it started"
    WBCH_DONE=1
    return 0
  fi
  pane="$(wbc_get "$stem" pane)"
  WBCH_PANE="$pane"
  wt="$(wbc_get "$stem" worktree)"
  old="$(wbc_get "$stem" session_id)"
  wbch_pane_reason ""

  # 1. Settle: the turn that just ended is really over.
  wbch_settle "$pane" || wbch_back_armed "a new turn started"
  # 2. Text or a dialog on the input line.
  if wbch_input_pending "$pane"; then wbch_back_armed "$WBCH_PENDING"; fi
  # 3. A /decide surface, then drift.
  [ -s "$(wb_needs_you_file "$stem")" ] && wbch_back_armed "waiting: a /decide surface is open"
  wbch_drift
  # 4. The pane's live Claude is the one that saved.
  wbch_pane_claude_is "$pane" "$old" ||
    wbch_end helper-ready ready "could not confirm the pane's Claude is the one that saved"
  # 5. Shadow mode: everything above ran; stop short of the respawn. A release
  # is Jet's own action and is live from the start.
  if [ ! -e "$WBCH_STATE/continue-live" ] && [ "$WBCH_RELEASE" != release ]; then
    wbch_end would-restart ready "shadow mode: would have restarted"
  fi

  # 6. Prepare: the fresh session's id, marked restart-born, and what it keeps.
  local new model effort pm fb=0 mw
  read -r new </proc/sys/kernel/random/uuid
  if ! { mkdir -p "$(wb_continue_state_root)/born" && : >"$(wb_continue_state_root)/born/$new"; }; then
    wbch_end helper-failed failed "could not mark the fresh session as restart-born"
  fi
  model="$(wbc_get "$stem" model)"
  mw="$(wbch_safe_word "$model")"
  [ -n "$mw" ] || fb=1
  effort="$(wbch_safe_word "$(wbc_get "$stem" effort)")"
  pm="$(wbch_safe_word "$(wbc_get "$stem" permission_mode)")"
  # Transcripts and payloads say "default", which is not a --permission-mode choice.
  [ "$pm" != default ] || pm=""
  wbch_set helper-restarting restarting "restarting the pane" "new_session_id=$new" "model_fallback=$fb"

  # 7. The final look, immediately before the respawn.
  local undo=""
  if wbch_input_pending "$pane"; then
    undo="$WBCH_PENDING"
  elif [ -n "$(tmux show -pv -t "$pane" @claude_working 2>/dev/null)" ]; then undo="a new turn started"; fi
  if [ -n "$undo" ]; then
    rm -f "$(wb_continue_state_root)/born/$new"
    wbch_back_armed "$undo"
  fi

  # 8. Restart: the pane's original shell, a prompt, then the fixed launch line.
  # Count what Jet has not seen first (the old Claude's transcript and the pane's
  # focus stamp are both still there), record it once the respawn took.
  wbch_unseen_scan "$pane" "$old"
  tmux respawn-pane -k -t "$pane" -c "$wt" 2>/dev/null || {
    rm -f "$(wb_continue_state_root)/born/$new"
    wbch_end helper-ready ready "tmux could not respawn the pane; release it from the picker" new_session_id= model_fallback=
  }
  wbch_unseen_write "$stem" "$pane" "$old"
  # A shell seen on two polls in a row: the command name passes through
  # `sh`/`bash` for a few milliseconds on its way to something else.
  local timeout="${WB_CONTINUE_PROMPT_TIMEOUT:-20}" i pcmd="" shells=0
  for ((i = 0; i < timeout * 5; i++)); do
    pcmd="$(tmux display-message -p -t "$pane" '#{pane_current_command}' 2>/dev/null || true)"
    case "$pcmd" in
      bash | zsh | sh | dash | fish) shells=$((shells + 1)) ;;
      *) shells=0 ;;
    esac
    [ "$shells" -ge 2 ] && break
    sleep 0.2
  done
  [ "$shells" -ge 2 ] || pcmd=""
  local resume="claude --resume $old"
  if [ -z "$pcmd" ]; then
    wbch_end helper-failed failed "the pane's shell never appeared; the old session is $old: $resume"
  fi
  local launch="claude --session-id $new"
  [ -z "$mw" ] || launch+=" --model $mw"
  [ -z "$effort" ] || launch+=" --effort $effort"
  [ -z "$pm" ] || launch+=" --permission-mode $pm"
  launch+=" \"/wb-resume --continue $id\""
  tmux send-keys -t "$pane" C-u
  tmux send-keys -t "$pane" -l "$launch"
  tmux send-keys -t "$pane" Enter
  tmux set -p -t "$pane" @claude_session_id "$new" 2>/dev/null

  # 9. Wait for the pick-up: it removes the request, or refuses it.
  local pt="${WB_CONTINUE_PICKUP_TIMEOUT:-120}" cur
  for ((i = 0; i < pt * 2; i++)); do
    if [ ! -f "$(wbc_dir "$stem")/request" ] || [ "$(wbc_get "$stem" id)" != "$id" ]; then
      wb_continue_log restarted "$stem" "$id" restarted "the fresh Claude picked up the save"
      wbch_pane_reason ""
      WBCH_DONE=1
      return 0
    fi
    cur="$(wbc_get "$stem" state)"
    if [ "$cur" != restarting ]; then
      wbch_pane_reason "$(wbc_get "$stem" reason)"
      WBCH_DONE=1
      return 0
    fi
    sleep 0.5
  done
  wbch_end helper-failed failed "the fresh Claude did not pick up the save within ${pt}s; the old session is $old: $resume"
}

# --- release (Jet's own: the picker keys, the tmux key, `wb continue release`) -----

# wbch_release_check <stem> — the KTD8 checks, in order, before anything is
# ended. Prints the reason and returns 1 when the request stays as it is (busy,
# a turn in progress, text on the input line, a /decide surface, the session is
# not there), 2 when the save itself no longer holds (drift: the request is
# refused). Reuses the helper's own input-line, drift and pane-Claude checks.
wbch_release_check() {
  local stem="$1" pane tsess tf busy stop
  pane="$(wbc_get "$stem" pane)"
  tf="$(wbc_get "$stem" task_file)"
  tsess=""
  [ -z "$pane" ] || tsess="$(tmux display-message -p -t "$pane" '#S' 2>/dev/null)" || tsess=""
  if [ -z "$tsess" ] || [ "$(wb_session_task_file "$tsess" 2>/dev/null)" != "$tf" ]; then
    echo "the session is not running"
    return 1
  fi
  busy="$(wbc_get "$stem" last_busy)"
  stop="$(wbc_get "$stem" last_stop)"
  if [ -n "$stop" ] && [ "$busy" != 0 ]; then
    echo "background work was still running at the last turn end"
    return 1
  fi
  if [ -n "$(tmux show -pv -t "$pane" @claude_working 2>/dev/null)" ]; then
    echo "a turn is in progress"
    return 1
  fi
  if [ -s "$(wb_needs_you_file "$stem")" ]; then
    echo "a /decide surface is open"
    return 1
  fi
  if wbch_input_pending "$pane"; then
    if [ -z "$stop" ]; then echo "no turn end was recorded and the pane is not at an idle prompt"
    else echo "$WBCH_PENDING"; fi
    return 1
  fi
  _wbc_lock "$stem" || { echo "the request is locked by another command"; return 1; }
  if ! wbch_drift_probe "$stem"; then
    _wbc_unlock "$stem"
    echo "$WBCH_DRIFT"
    return 2
  fi
  _wbc_unlock "$stem"
  if ! wbch_pane_claude_is "$pane" "$(wbc_get "$stem" session_id)"; then
    echo "could not confirm the pane's Claude is the one that saved"
    return 1
  fi
  return 0
}

# wbch_release_one <stem> <any|cmd> — release one request: check, claim, start
# the helper detached. Prints one line. `cmd` skips a request with no command
# (--all), silently, as it does a request whose session is gone; `any` releases it (the fresh Claude follows the save's
# Next prose). Returns 0 when released.
wbch_release_one() {
  local stem="$1" need="$2" state reason rc id self cmd
  state="$(wbc_get "$stem" state 2>/dev/null)"
  case "$state" in
    ready | failed | armed) ;;
    claimed | restarting) echo "$stem: already restarting"; return 1 ;;
    refused) echo "$stem: refused: $(wbc_get "$stem" reason); not released"; return 1 ;;
    *) echo "$stem: no saved session to continue"; return 1 ;;
  esac
  if [ "$need" = cmd ] && [ -z "$(wbc_get "$stem" command)" ]; then return 2; fi
  id="$(wbc_get "$stem" id)"
  WBCH_PANE="$(wbc_get "$stem" pane)"
  reason="$(wbch_release_check "$stem")" && rc=0 || rc=$?
  if [ "$rc" = 1 ]; then
    wb_continue_log release-wait "$stem" "$id" "$state" "not released: $reason"
    wbch_pane_reason "$reason"
    # --all skips a request whose session is gone (a leftover) without a word.
    [ "$need" = cmd ] && [ "$reason" = "the session is not running" ] && return 2
    echo "$stem: not released: $reason"
    return 1
  elif [ "$rc" = 2 ]; then
    _wbc_lock "$stem" || return 1
    if [ "$(wbc_get "$stem" id)" = "$id" ]; then wbc_set release-refused "$stem" refused "$reason"; fi
    _wbc_unlock "$stem"
    wbch_pane_reason "$reason"
    echo "$stem: refused: $reason"
    return 1
  fi
  # Claim under the lock: a second press, or the Stop hook, may have got here first.
  _wbc_lock "$stem" || return 1
  state="$(wbc_get "$stem" state)"
  if [ "$(wbc_get "$stem" id)" != "$id" ]; then
    _wbc_unlock "$stem"
    echo "$stem: the request changed meanwhile; not released"
    return 1
  fi
  case "$state" in
    ready | failed | armed) ;;
    *) _wbc_unlock "$stem"; echo "$stem: already restarting"; return 1 ;;
  esac
  wbc_set release "$stem" claimed "released by Jet"
  _wbc_unlock "$stem"
  wbch_pane_reason ""
  self="$(readlink -f "$WBCH_SRC" 2>/dev/null)" || self="$WBCH_SRC"
  cmd="$(printf '%q ' "$BASH" "$self" helper "$stem" "$id" release)"
  if ! tmux run-shell -b -t "$WBCH_PANE" "$cmd" 2>/dev/null; then
    _wbc_lock "$stem" || return 1
    if [ "$(wbc_get "$stem" id)" = "$id" ] && [ "$(wbc_get "$stem" state)" = claimed ]; then
      wbc_set release-ready "$stem" ready "tmux could not start the helper; release it again"
    fi
    _wbc_unlock "$stem"
    echo "$stem: tmux could not start the helper"
    return 1
  fi
  echo "$stem: released"
  return 0
}

# wbch_release_main <task> | --all | --pane <pane-id>
wbch_release_main() {
  local stem tf d n=0 rc
  case "${1:-}" in
    --all)
      for d in "$WBCH_STATE"/continue/*/request; do
        [ -f "$d" ] || continue
        d="${d%/request}"
        stem="${d##*/}"
        wbch_release_one "$stem" cmd && n=$((n + 1))
      done
      [ "$n" -gt 0 ] || echo "nothing ready to continue"
      ;;
    --pane)
      if [ -z "${2:-}" ] || ! wbch_find pane "$2"; then
        echo "no saved session to continue in this pane"
        return 1
      fi
      wbch_release_one "$WBCH_STEM" any && n=1
      ;;
    *)
      tf="$(_wbc_resolve_task "${1:-}")" || return 1
      stem="$(basename -- "$tf" .md)"
      wbch_release_one "$stem" any && n=1
      ;;
  esac
  rc=1
  [ "$n" -gt 0 ] && rc=0
  return "$rc"
}

# shellcheck disable=SC2329 # named in the trap below
wbch_on_exit_trap() { wbch_on_exit; }
wb_lock_trap_append wbch_on_exit_trap

case "$WBCH_VERB" in
  hook-stop) wbch_stop ;;
  hook-session-start) wbch_session_start ;;
  release)
    wbch_release_main "${@:2}"
    exit $?
    ;;
  helper)
    WBCH_STEM="${2:-}"
    WBCH_ID="${3:-}"
    WBCH_RELEASE="${4:-}"
    if [[ "$WBCH_STEM" =~ ^[A-Za-z0-9._-]+$ ]] && [[ "$WBCH_ID" == "$WBCH_STEM"@* ]]; then
      wbch_helper
    else WBCH_STEM=""; fi
    ;;
esac
exit 0
