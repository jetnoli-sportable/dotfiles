#!/usr/bin/env bash
# wb-review-hook.sh — delivers a code review Jet sent from the wb review page
# (wb-store review) to the Claude session of the task it was written for.
#
# The page's Send writes the review to a queue; this script hands queued reviews
# to Claude by exactly one of three routes, whichever comes first. Every route
# claims an item by an atomic rename (pending -> claimed), so a review is never
# handed over twice.
#   hook-stop            Stop hook: the turn just ended; block the stop with the
#                        pointer so Claude carries straight on with the review
#   hook-session-start   SessionStart hook: add the pointer to Claude's context
#   hook-stop-failure    StopFailure hook: the turn died on an API error; only
#                        drop the hand-over marker, print nothing
#   deliver <stem>       run by the review server after Send: type the pointer
#                        at an idle session's prompt, when every guard passes;
#                        otherwise leave the review queued and say why
#
# Wired by the hooks-only wb-review-hook plugin
# (claude/.claude/skills/wb-review-hook/hooks/hooks.json, stowed into
# ~/.claude/skills/). Never also wire these in ~/.claude/settings.json: plugin
# and settings hooks both run, so every event would fire twice. WB_REVIEW_BIN
# overrides where the plugin finds this script (default ~/.config/scripts/tmux).
#
# The hooks run on every turn end of every Claude, so everything before a queue
# item matches is plain bash: the kill switch, three environment guards and a
# glob. No tmux call, no jq until a pending item or an in-flight marker exists.
# Always exits 0. A hook verb prints only its JSON; `deliver` prints nothing.
#
# State, under ${XDG_STATE_HOME:-~/.local/state}/wb:
#   disable-review                     kill switch: every verb exits at once
#   review/<stem>/queue/pending|claimed|delivered/<id>.json, queue/inflight,
#   queue/status                       the queue contract written by wb-store
#
# A block starts a turn no UserPromptSubmit announces, and claude-notify-hook.sh's
# Stop handler marks the pane done. So the block also sets @claude_agent_wbreview
# (an epoch, the shape of a subagent marker: the notify hook counts it as a live
# agent) and queue/inflight records "<pane> <epoch>". The next hook-stop,
# session start or StopFailure of the task's pane clears both.
#
# Tunables (env): WB_REVIEW_SETTLE_MS (1500) and WB_REVIEW_SETTLE_MAX_MS (5000)
# for the idle wait before typing; WB_REVIEW_INFLIGHT_MAX_S (1800), how long an
# in-flight marker is trusted when no hook ever cleared it (an interrupt).
set -uo pipefail

WBRH_SRC="${BASH_SOURCE[0]}"
case "$WBRH_SRC" in */*) WBRH_DIR="${WBRH_SRC%/*}" ;; *) WBRH_DIR=. ;; esac
WBRH_STATE="${XDG_STATE_HOME:-$HOME/.local/state}/wb"
WBRH_Q="$WBRH_STATE/review"
WBRH_VERB="${1:-}"

# --- the cheap prefilter (plain bash, no forks) -----------------------------------

# wbrh_any_work — a pending item, or an in-flight marker the next hook must
# clear, exists for some task.
wbrh_any_work() {
  local f
  for f in "$WBRH_Q"/*/queue/pending/*.json "$WBRH_Q"/*/queue/inflight; do
    [ -e "$f" ] && return 0
  done
  return 1
}

# wbrh_has_pending <stem> — the task has at least one pending item.
wbrh_has_pending() {
  local f
  for f in "$WBRH_Q/$1"/queue/pending/*.json; do [ -e "$f" ] && return 0; done
  return 1
}

# wbrh_stem_ok <stem> — a safe task stem: no slash, plain characters only.
wbrh_stem_ok() { [[ "$1" =~ ^[A-Za-z0-9._-]+$ ]] && [ "$1" != . ] && [ "$1" != .. ]; }

# wbrh_stem_of <task-path> — the stem (basename without .md); false when unsafe.
wbrh_stem_of() {
  local b="${1##*/}"
  b="${b%.md}"
  wbrh_stem_ok "$b" || return 1
  printf '%s' "$b"
}

case "$WBRH_VERB" in
  hook-stop | hook-session-start | hook-stop-failure)
    exec 2>/dev/null
    [ -e "$WBRH_STATE/disable-review" ] && exit 0
    [ "${CLAUDE_CODE_SESSION_ATTENDED:-}" = 0 ] && exit 0
    case "${CLAUDE_CODE_ENTRYPOINT:-}" in sdk*) exit 0 ;; esac
    [ -n "${TMUX_PANE:-}" ] || exit 0
    wbrh_any_work || exit 0
    ;;
  deliver)
    exec >/dev/null 2>&1
    wbrh_stem_ok "${2:-}" || exit 0
    ;;
  *) exit 0 ;;
esac

# --- queue helpers -------------------------------------------------------------------

# wbrh_status <stem> <text> — the one-line reason a pending item still waits,
# written through a temp file and a rename.
wbrh_status() {
  local d="$WBRH_Q/$1/queue"
  [ -d "$d" ] || return 0
  printf '%s\n' "$2" >"$d/status.tmp.$$" && mv -f "$d/status.tmp.$$" "$d/status"
}

# wbrh_claim <stem> <route> — claim every pending item of the task by rename.
# Sets WBRH_POINTER (one instruction naming every record), WBRH_CLAIMED (the
# claimed ids) and WBRH_ROUTE (<route>, for
# wbrh_mark_delivered); false when nothing was claimed, because nothing was
# pending or another route won every rename.
# An item whose record path is empty or holds a control character is left alone.
wbrh_claim() {
  local stem="$1" route="$2" q="$WBRH_Q/$1/queue" f id rec
  local -a recs=() ids=()
  WBRH_POINTER="" WBRH_CLAIMED=()
  mkdir -p "$q/claimed" "$q/delivered" || return 1
  for f in "$q"/pending/*.json; do
    [ -e "$f" ] || continue
    id="${f##*/}"
    id="${id%.json}"
    [[ "$id" =~ ^[A-Za-z0-9_-]{1,64}$ ]] || continue
    rec="$(jq -r '.record // empty' "$f" 2>/dev/null)" || continue
    [ -n "$rec" ] && [[ "$rec" != *[[:cntrl:]]* ]] || continue
    mv "$f" "$q/claimed/$id.json" 2>/dev/null || continue
    recs+=("$rec")
    ids+=("$id")
  done
  [ "${#ids[@]}" -gt 0 ] || return 1
  local n="${#recs[@]}" list="" i
  if [ "$n" = 1 ]; then
    WBRH_POINTER="Jet sent a code review: read ${recs[0]} and address each comment."
  else
    for ((i = 0; i < n; i++)); do
      if [ "$i" = 0 ]; then
        list="${recs[i]}"
      elif [ "$i" = $((n - 1)) ]; then
        list="$list and ${recs[i]}"
      else
        list="$list, ${recs[i]}"
      fi
    done
    WBRH_POINTER="Jet sent $n code reviews: read $list, and address each comment."
  fi
  WBRH_CLAIMED=("${ids[@]}")
  WBRH_ROUTE="$route"
  return 0
}

# wbrh_mark_delivered <stem> — move the claimed ids to delivered with the route
# and time added, and drop the stale status line.
wbrh_mark_delivered() {
  local q="$WBRH_Q/$1/queue" id ts
  ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  for id in "${WBRH_CLAIMED[@]}"; do
    if jq --arg r "$WBRH_ROUTE" --arg t "$ts" '. + {route: $r, delivered: $t}' "$q/claimed/$id.json" >"$q/delivered/.$id.tmp.$$" 2>/dev/null; then
      mv -f "$q/delivered/.$id.tmp.$$" "$q/delivered/$id.json"
      rm -f "$q/claimed/$id.json"
    else
      rm -f "$q/delivered/.$id.tmp.$$"
      mv -f "$q/claimed/$id.json" "$q/delivered/$id.json"
    fi
  done
  rm -f "$q/status"
}

# wbrh_unclaim <stem> — put the claimed ids back to pending (a hand-over failed).
wbrh_unclaim() {
  local q="$WBRH_Q/$1/queue" id
  for id in "${WBRH_CLAIMED[@]}"; do mv -f "$q/claimed/$id.json" "$q/pending/$id.json" 2>/dev/null; done
}

# wbrh_continue_pending — this pane has a wb continue request that has not yet
# respawned it (a plain read of continue/*/request), so the restart's
# session-start must claim instead. wb continue's own Stop hook runs in parallel
# with this one and moves the request armed -> claimed -> restarting within the
# same turn end, so all three states hold the review back.
wbrh_continue_pending() {
  local f line pane=0 pending=0
  for f in "$WBRH_STATE"/continue/*/request; do
    [ -f "$f" ] || continue
    pane=0 pending=0
    while IFS= read -r line || [ -n "$line" ]; do
      [[ "$line" == "pane=$TMUX_PANE" ]] && pane=1
      case "$line" in state=armed | state=claimed | state=restarting) pending=1 ;; esac
    done <"$f"
    [ "$pane" = 1 ] && [ "$pending" = 1 ] && return 0
  done
  return 1
}

# wbrh_pane_stem — the stem of the task whose tmux session holds $TMUX_PANE,
# from the session's @task option (wb sets it to the task file's path).
wbrh_pane_stem() {
  local task
  task="$(tmux display-message -p -t "$TMUX_PANE" '#{@task}' 2>/dev/null)" || return 1
  [ -n "$task" ] || return 1
  wbrh_stem_of "$task"
}

# wbrh_resync_working <pane> — after dropping our busy marker, put @claude_working
# back to what claude-notify-hook.sh's sync_working would derive (a running turn
# or a fresh subagent marker keeps it set), since its own Stop handler may have
# run first and seen our marker.
wbrh_resync_working() {
  local name val live=0
  [ -n "$(tmux show -pv -t "$1" @claude_turn 2>/dev/null)" ] && live=1
  while read -r name val; do
    case "$name" in @claude_agent_*) ;; *) continue ;; esac
    [[ "$val" =~ ^[0-9]+$ ]] && ((EPOCHSECONDS - val < 7200)) && live=1
  done < <(tmux show -p -t "$1" 2>/dev/null)
  if [ "$live" = 1 ]; then tmux set -p -t "$1" @claude_working 1; else tmux set -pu -t "$1" @claude_working; fi
}

# wbrh_clear_busy <pane> — drop the busy marker the last block set.
wbrh_clear_busy() {
  tmux set -pu -t "$1" @claude_agent_wbreview 2>/dev/null
  wbrh_resync_working "$1"
}

# --- hook verbs --------------------------------------------------------------------

wbrh_hook() {
  local stem q
  stem="$(wbrh_pane_stem)" || return 0
  q="$WBRH_Q/$stem/queue"
  # A hook of this task's session ends the hand-over the last block started.
  if [ -e "$q/inflight" ]; then
    rm -f "$q/inflight"
    wbrh_clear_busy "$TMUX_PANE"
  fi
  [ "$WBRH_VERB" = hook-stop-failure ] && return 0
  wbrh_has_pending "$stem" || return 0
  if [ "$WBRH_VERB" = hook-stop ]; then
    wbrh_continue_pending && return 0
    wbrh_claim "$stem" turn-end || return 0
    printf '%s %s\n' "$TMUX_PANE" "$EPOCHSECONDS" >"$q/inflight"
    # Both Stop hooks run in parallel: the marker keeps the notify hook's own
    # derivation busy when it runs after us, the direct sets win when it ran first.
    tmux set -p -t "$TMUX_PANE" @claude_agent_wbreview "$EPOCHSECONDS"
    tmux set -p -t "$TMUX_PANE" @claude_working 1
    tmux set -pu -t "$TMUX_PANE" @claude_blocked
    jq -n --arg r "$WBRH_POINTER" '{decision: "block", reason: $r}'
  else
    wbrh_claim "$stem" session-start || return 0
    jq -n --arg r "$WBRH_POINTER" '{hookSpecificOutput: {hookEventName: "SessionStart", additionalContext: $r}}'
  fi
  wbrh_mark_delivered "$stem"
}

# --- deliver (the idle route) -------------------------------------------------------

# Copied from wb.sh's wb_capture_pane (wb.sh can't be sourced cheaply here): the
# pane's current screen, colours kept.
wbrh_capture_pane() { tmux capture-pane -ep -t "$1" 2>/dev/null; }

# Copied from wb-continue-hook.sh's wbch_input_pending (that file dispatches on
# $1 and exits, so it can't be sourced): sets WBRH_INPUT to "text" when text is
# on Claude's input line, "none" when no input line is on screen (a dialog or
# menu: fail closed); false only when the input line is empty. The input line is
# the last line starting with the prompt glyph and a no-break space.
wbrh_input_pending() {
  local screen line plain rest prompt=$'\xe2\x9d\xaf\xc2\xa0' found="" ext
  ext="$(shopt -p extglob)"
  shopt -s extglob
  screen="$(wbrh_capture_pane "$1")" || screen=""
  while IFS= read -r line; do
    plain="${line//$'\e'\[*([0-9;])m/}"
    [[ "$plain" == "$prompt"* ]] && found="$line"
  done <<<"$screen"
  eval "$ext"
  WBRH_INPUT=none
  [ -n "$found" ] || return 0
  rest="${found#*"$prompt"}"
  rest="${rest//$'\e'\[[039]m/}"
  rest="${rest//$'\e'\[49m/}"
  rest="${rest//$'\e'\[m/}"
  while [[ "$rest" == *[[:space:]] ]]; do rest="${rest%?}"; done
  WBRH_INPUT=text
  [ -n "$rest" ] && [[ "$rest" != $'\e[2m'* ]]
}

# Copied from wb-continue-hook.sh's wbch_settle: wait until @claude_working has
# been empty for the whole settle time; false when it stays set, or is set
# again, past the overall limit.
wbrh_settle() {
  local need="${WB_REVIEW_SETTLE_MS:-1500}" max="${WB_REVIEW_SETTLE_MAX_MS:-5000}"
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

# wbrh_find_pane <stem> — sets WBRH_PANE to the Claude pane of the tmux session
# whose @task names this stem (KTD7); false when there is none.
wbrh_find_pane() {
  local name task row
  WBRH_PANE=""
  while IFS='|' read -r name task; do
    [ -n "$task" ] || continue
    [ "$(wbrh_stem_of "$task")" = "$1" ] || continue
    row="$(tmux_claude_panes "$name" | head -n 1)"
    [ -n "$row" ] || continue
    IFS=$'\t' read -r _ WBRH_PANE _ <<<"$row"
    [ -n "$WBRH_PANE" ] && return 0
  done < <(tmux list-sessions -F '#{session_name}|#{@task}' 2>/dev/null)
  return 1
}

# wbrh_inflight_live <file> — the hand-over is still being worked on: the marker
# is younger than WB_REVIEW_INFLIGHT_MAX_S and its pane still carries the busy
# marker. An interrupt or a StopFailure leaves the marker behind with no hook to
# clear it. Sets WBRH_INFLIGHT_PANE.
wbrh_inflight_live() {
  local pane ts max="${WB_REVIEW_INFLIGHT_MAX_S:-1800}"
  WBRH_INFLIGHT_PANE=""
  read -r pane ts <"$1" || true
  [[ "$pane" =~ ^%[0-9]+$ ]] && WBRH_INFLIGHT_PANE="$pane"
  [[ "$ts" =~ ^[0-9]+$ ]] && ((EPOCHSECONDS - ts < max)) || return 1
  [ -n "$WBRH_INFLIGHT_PANE" ] || return 1
  [ -n "$(tmux show -pv -t "$WBRH_INFLIGHT_PANE" @claude_agent_wbreview 2>/dev/null)" ]
}

wbrh_deliver() {
  local stem="$1" pane info working mode
  wbrh_has_pending "$stem" || return 0
  if [ -e "$WBRH_STATE/disable-review" ]; then
    wbrh_status "$stem" "review delivery is switched off"
    return 0
  fi
  # shellcheck source=lib.sh
  source "$WBRH_DIR/lib.sh" || return 0
  if ! wbrh_find_pane "$stem"; then
    wbrh_status "$stem" "no Claude running for this task"
    return 0
  fi
  pane="$WBRH_PANE"
  if [ -e "$WBRH_Q/$stem/queue/inflight" ]; then
    if wbrh_inflight_live "$WBRH_Q/$stem/queue/inflight"; then
      wbrh_status "$stem" "a review hand-over is still being worked on"
      return 0
    fi
    rm -f "$WBRH_Q/$stem/queue/inflight"
    [ -n "$WBRH_INFLIGHT_PANE" ] && wbrh_clear_busy "$WBRH_INFLIGHT_PANE"
  fi
  info="$(tmux display-message -p -t "$pane" '#{@claude_working}|#{pane_in_mode}' 2>/dev/null)" || info=""
  IFS='|' read -r working mode <<<"$info"
  if [ -n "$working" ] || ! wbrh_settle "$pane"; then
    wbrh_status "$stem" "waiting for the turn to end"
    return 0
  fi
  # settle can wait seconds: the pane may have entered copy mode meanwhile.
  mode="$(tmux display-message -p -t "$pane" '#{pane_in_mode}' 2>/dev/null)"
  if [ "$mode" = 1 ]; then
    wbrh_status "$stem" "the pane is in copy mode"
    return 0
  fi
  if wbrh_input_pending "$pane"; then
    if [ "$WBRH_INPUT" = text ]; then
      wbrh_status "$stem" "text on the input line"
    else
      wbrh_status "$stem" "a permission question is on screen"
    fi
    return 0
  fi
  wbrh_claim "$stem" prompt || return 0
  if tmux send-keys -t "$pane" -l -- "$WBRH_POINTER" && tmux send-keys -t "$pane" Enter; then
    wbrh_mark_delivered "$stem"
  else
    wbrh_unclaim "$stem"
    wbrh_status "$stem" "typing into the pane failed"
  fi
}

case "$WBRH_VERB" in
  hook-stop | hook-session-start | hook-stop-failure) wbrh_hook ;;
  deliver) wbrh_deliver "$2" ;;
esac
exit 0
