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
# Tunables (env): WB_REVIEW_SETTLE_MS (1500) and WB_REVIEW_SETTLE_MAX_MS (5000)
# for the idle wait before typing.
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
  hook-stop | hook-session-start)
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

# wbrh_claim <stem> <route> — claim every pending item of the task by rename and
# mark each delivered under <route>. Sets WBRH_POINTER (one instruction naming
# every record) and WBRH_CLAIMED (the claimed ids); false when nothing was
# claimed, because nothing was pending or another route won every rename.
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

# wbrh_continue_armed — this pane has an armed wb continue request (a plain read
# of continue/*/request), so the restart's session-start must claim instead.
wbrh_continue_armed() {
  local f line pane=0 armed=0
  for f in "$WBRH_STATE"/continue/*/request; do
    [ -f "$f" ] || continue
    pane=0 armed=0
    while IFS= read -r line || [ -n "$line" ]; do
      [[ "$line" == "pane=$TMUX_PANE" ]] && pane=1
      [[ "$line" == "state=armed" ]] && armed=1
    done <"$f"
    [ "$pane" = 1 ] && [ "$armed" = 1 ] && return 0
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

# --- hook verbs --------------------------------------------------------------------

wbrh_hook() {
  local stem
  stem="$(wbrh_pane_stem)" || return 0
  # A hook of this task's session ends the hand-over the last block started.
  rm -f "$WBRH_Q/$stem/queue/inflight"
  wbrh_has_pending "$stem" || return 0
  if [ "$WBRH_VERB" = hook-stop ]; then
    wbrh_continue_armed && return 0
    wbrh_claim "$stem" turn-end || return 0
    : >"$WBRH_Q/$stem/queue/inflight"
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
    wbrh_status "$stem" "a review hand-over is still being worked on"
    return 0
  fi
  info="$(tmux display-message -p -t "$pane" '#{@claude_working}|#{pane_in_mode}' 2>/dev/null)" || info=""
  IFS='|' read -r working mode <<<"$info"
  if [ -n "$working" ] || ! wbrh_settle "$pane"; then
    wbrh_status "$stem" "waiting for the turn to end"
    return 0
  fi
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
  hook-stop | hook-session-start) wbrh_hook ;;
  deliver) wbrh_deliver "$2" ;;
esac
exit 0
