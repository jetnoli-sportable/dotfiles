#!/usr/bin/env bash
# wb-capture.sh — shared core of the wb decision auto-capture feature. Claude
# Code hooks (registered by the wb-capture plugin's hooks.json, added in a
# later unit) and the /wb-decide skill both go through this one script, so
# state paths, guards, config and the event log live in exactly one place.
#
# Verbs:
#   hook-prompt | hook-posttool | hook-stop | hook-end
#                  Claude Code hook entry points (stdin JSON, session_id from
#                  `.session_id`). Stubbed as silent no-ops here; filled in by
#                  later units.
#   clear          agent verb: drop marker, draft and outstanding flag. Logs
#                  nothing (the PostToolUse hook already logs `followed`).
#   dismiss        same removal, logs `dismissed`. Quiet no-op (nothing logged)
#                  when nothing was pending.
#   mute | unmute  write / remove the per-session `muted` flag; logs each.
#   status         print pending marker/draft (with paths), mute state, and the
#                  log path — human-readable lines.
#   _config        TEST-ONLY: print the resolved config as key=value lines.
#
# Agent verbs find their session via the tmux PANE option @wb_capture_sid
# (stamped by hook-prompt); they run inside the agent's Bash, which inherits
# $TMUX_PANE. With it unset they print one error line and exit 0.
#
# Paths:
#   state root   ${XDG_STATE_HOME:-$HOME/.local/state}/wb/capture/
#   per session  <root>/<session_id>/   (marker recorded cooldown taskhash
#                                        unchanged draft muted outstanding ended)
#   event log    <root>/log.jsonl       (one compact JSON line per event:
#                                        ts, session_id, task, event[, source])
#   kill switch  ${XDG_STATE_HOME:-$HOME/.local/state}/wb/disable-capture
#                (touch it and every verb becomes a silent no-op)
#
# Config (KTD8): defaults below, overridden by the optional untracked file
# ${XDG_CONFIG_HOME:-$HOME/.config}/wb/capture.conf — `KEY=value` lines, parsed
# line by line, NEVER sourced or eval'd (a `$(...)` in a value stays literal).
# `#` lines, blank lines, unknown keys and malformed lines are ignored. Values
# are taken verbatim to end of line (so a phrase may end in a space).
#   phrases        `|`-separated decision phrases, matched case-insensitively
#                  as fixed strings (default list below)
#   cooldown       integer, turns between phrase nudges   (default 3)
#   sweep_every    integer, unchanged turns before a sweep (default 4)
#   sweep          on|off, Haiku background sweep          (default on)
#   sweep_timeout  integer seconds for the sweep child     (default 60)
# A non-integer / non-on|off value falls back to the default.
#
# Guards (R5), checked in order before any state is touched: WB_CAPTURE_SWEEP
# set (recursion flag for the headless sweep child), kill switch, not in tmux,
# no @task on the tmux session, jq missing. Every one exits 0 silently.
#
# Never sources wb.sh and never writes under ~/code/tasks (KTD5): @task is read
# straight from the tmux session option. No `-e`; every path exits 0 so a hook
# can never block or fail Claude.
set -uo pipefail

DEFAULT_PHRASES="we decided|decided to|going with|let's go with|we'll go with|settled on|the decision is|chose |opting for|instead of|rather than|ruled out|rejected"
DEFAULT_COOLDOWN=3
DEFAULT_SWEEP_EVERY=4
DEFAULT_SWEEP=on
DEFAULT_SWEEP_TIMEOUT=60

STATE_BASE="${XDG_STATE_HOME:-$HOME/.local/state}/wb"
CAPTURE_ROOT="$STATE_BASE/capture"
LOG_FILE="$CAPTURE_ROOT/log.jsonl"
KILL_SWITCH="$STATE_BASE/disable-capture"
CONF_FILE="${XDG_CONFIG_HOME:-$HOME/.config}/wb/capture.conf"

# Fail-open: note on stderr, exit 0 (modelled on pretooluse-guard.sh).
fail_open() { echo "wb-capture: $*" >&2; exit 0; }

# Silent no-op exit.
quiet_exit() { exit 0; }

TASK_STEM=""

# guard_chain — recursion flag, kill switch, tmux, @task, jq. Sets TASK_STEM.
guard_chain() {
  [ -n "${WB_CAPTURE_SWEEP:-}" ] && quiet_exit
  [ -e "$KILL_SWITCH" ] && quiet_exit
  [ -n "${TMUX:-}" ] || quiet_exit
  command -v tmux >/dev/null 2>&1 || quiet_exit
  local session task
  session="$(tmux display-message -p '#S' 2>/dev/null || true)"
  [ -n "$session" ] || quiet_exit
  task="$(tmux show -t "=$session:" -v @task 2>/dev/null || true)"
  [ -n "$task" ] || quiet_exit
  command -v jq >/dev/null 2>&1 || quiet_exit
  task="${task##*/}"
  TASK_STEM="${task%.md}"
}

# session_dir <sid> — print <root>/<sid> if sid is a safe name, else fail 1.
# Every removal goes through this so it can only touch files inside a
# verified per-session dir.
session_dir() {
  local sid="${1:-}"
  [ -n "$CAPTURE_ROOT" ] || return 1
  [[ "$sid" =~ ^[A-Za-z0-9-]+$ ]] || return 1
  printf '%s/%s\n' "$CAPTURE_ROOT" "$sid"
}

# pane_sid — session id recorded on this pane by hook-prompt (agent verbs).
pane_sid() { tmux show -pv @wb_capture_sid 2>/dev/null || true; }

# stdin_sid — session id from hook stdin JSON (hook verbs). Guarded so a
# manual, stdin-less invocation can't hang on the read.
stdin_sid() {
  [ -t 0 ] && return 0
  jq -r '.session_id // empty' 2>/dev/null || true
}

# log_event <sid> <event> [source] — append one compact JSON line.
log_event() {
  local sid="$1" event="$2" source="${3:-}" ts line
  ts="$(date +%Y-%m-%dT%H:%M:%S%z)"
  ts="${ts%??}:${ts: -2}"
  line="$(jq -nc --arg ts "$ts" --arg sid "$sid" --arg task "$TASK_STEM" \
    --arg event "$event" --arg source "$source" \
    '{ts:$ts,session_id:$sid,task:$task,event:$event}
     + (if $source == "" then {} else {source:$source} end)' 2>/dev/null)" || return 0
  [ -n "$line" ] || return 0
  mkdir -p "$CAPTURE_ROOT" 2>/dev/null || return 0
  printf '%s\n' "$line" >>"$LOG_FILE" 2>/dev/null || true
}

# remove_named <dir> <name>... — remove explicit files inside a validated dir.
remove_named() {
  local d="$1" f; shift
  for f in "$@"; do rm -f -- "$d/$f" 2>/dev/null || true; done
}

# load_config — set CFG_* from defaults, then capture.conf (never sourced).
load_config() {
  CFG_PHRASES="$DEFAULT_PHRASES"
  CFG_COOLDOWN="$DEFAULT_COOLDOWN"
  CFG_SWEEP_EVERY="$DEFAULT_SWEEP_EVERY"
  CFG_SWEEP="$DEFAULT_SWEEP"
  CFG_SWEEP_TIMEOUT="$DEFAULT_SWEEP_TIMEOUT"
  [ -r "$CONF_FILE" ] || return 0
  local line key val
  while IFS= read -r line || [ -n "$line" ]; do
    line="${line%$'\r'}"
    line="${line#"${line%%[![:space:]]*}"}"
    case "$line" in ''|'#'*) continue ;; esac
    [[ "$line" =~ ^[a-z_]+= ]] || continue
    key="${line%%=*}"; val="${line#*=}"
    case "$key" in
      phrases)       [ -n "$val" ] && CFG_PHRASES="$val" ;;
      cooldown)      [[ "$val" =~ ^[0-9]+$ ]] && CFG_COOLDOWN="$val" ;;
      sweep_every)   [[ "$val" =~ ^[0-9]+$ ]] && CFG_SWEEP_EVERY="$val" ;;
      sweep)         case "$val" in on|off) CFG_SWEEP="$val" ;; esac ;;
      sweep_timeout) [[ "$val" =~ ^[0-9]+$ ]] && CFG_SWEEP_TIMEOUT="$val" ;;
    esac
  done <"$CONF_FILE"
  return 0
}

# agent_session_dir — resolve + validate this pane's session dir for an agent
# verb; sets SID and SDIR. Unset sid: one error line, exit 0. Invalid: fail open.
agent_session_dir() {
  SID="$(pane_sid)"
  if [ -z "$SID" ]; then
    echo "wb-capture: no capture session recorded on this pane yet (@wb_capture_sid unset)"
    exit 0
  fi
  SDIR="$(session_dir "$SID")" || fail_open "invalid session id on pane; nothing changed"
}

cmd_clear_or_dismiss() { # <log-event|"">
  agent_session_dir
  local pending=0 f
  for f in marker draft outstanding; do [ -e "$SDIR/$f" ] && pending=1; done
  remove_named "$SDIR" marker draft outstanding
  if [ "$1" = dismissed ] && [ "$pending" = 1 ]; then log_event "$SID" dismissed; fi
}

cmd_status() {
  agent_session_dir
  local f
  for f in marker draft; do
    if [ -e "$SDIR/$f" ]; then echo "$f: present ($SDIR/$f)"; else echo "$f: none"; fi
  done
  if [ -e "$SDIR/muted" ]; then echo "muted: yes"; else echo "muted: no"; fi
  echo "session: $SID"
  echo "log: $LOG_FILE"
}

cmd_config() {
  load_config
  printf 'phrases=%s\ncooldown=%s\nsweep_every=%s\nsweep=%s\nsweep_timeout=%s\n' \
    "$CFG_PHRASES" "$CFG_COOLDOWN" "$CFG_SWEEP_EVERY" "$CFG_SWEEP" "$CFG_SWEEP_TIMEOUT"
}

verb="${1:-}"
case "$verb" in
  clear|dismiss|mute|unmute|status|_config|hook-prompt|hook-posttool|hook-stop|hook-end) ;;
  *) exit 0 ;;
esac

guard_chain

case "$verb" in
  clear)   cmd_clear_or_dismiss "" ;;
  dismiss) cmd_clear_or_dismiss dismissed ;;
  mute)
    agent_session_dir
    mkdir -p "$SDIR" 2>/dev/null && : >"$SDIR/muted" && log_event "$SID" muted
    ;;
  unmute)
    agent_session_dir
    remove_named "$SDIR" muted
    log_event "$SID" unmuted
    ;;
  status)  cmd_status ;;
  _config) cmd_config ;;
  hook-prompt|hook-posttool|hook-stop|hook-end)
    : # implemented in later units (U3-U5)
    ;;
esac

exit 0
