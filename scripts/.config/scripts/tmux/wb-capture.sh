#!/usr/bin/env bash
# wb-capture.sh — shared core of the wb decision auto-capture feature. Claude
# Code hooks (registered by the wb-capture plugin's hooks.json, added in a
# later unit) and the /wb-decide skill both go through this one script, so
# state paths, guards, config and the event log live in exactly one place.
#
# Verbs:
#   hook-prompt | hook-posttool | hook-stop | hook-end
#                  Claude Code hook entry points (stdin JSON read once, session_id
#                  from `.session_id`; all exit 0, silent on failure).
#     hook-posttool  (PostToolUse/Bash) a `wb append … Decisions` command sets
#                  `recorded`; if `outstanding`, logs `followed` and clears it.
#     hook-stop      (Stop) recorded -> clear, no marker; else (not muted,
#                  cooldown 0) phrase-match last_assistant_message -> `marker`
#                  + cooldown. Decrements cooldown; updates taskhash/unchanged
#                  (skipped after a synthetic prompt).
#     hook-prompt    (UserPromptSubmit) stamps @wb_capture_sid; delivers one
#                  nudge line (draft beats marker) as additionalContext, writes
#                  `outstanding`, logs nudge_fired. `<task-notification>` prompts
#                  (synthetic, from finished background sub-agents) deliver
#                  nothing and set `synthetic`.
#     hook-end       (SessionEnd, 1.5s budget: one jq parse, no network, no task
#                  file) if `marker` or `draft` exists logs `pending_at_end`
#                  {marker,draft}; always writes the `ended` tombstone. Deletes
#                  nothing — the reaper does that.
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
#                                        unchanged draft muted outstanding ended
#                                        synthetic nudged_draft taskpath
#                                        sweep_offset .lock draft.tmp.*)
#   event log    <root>/log.jsonl       (one compact JSON line per event:
#                                        ts, session_id, task, event[, source])
#   reaper stamp <root>/.reaped          (mtime = last reap; at most one per hour)
#   log rotation <root>/log.jsonl.1      (previous log; see reaper)
#   kill switch  ${XDG_STATE_HOME:-$HOME/.local/state}/wb/disable-capture
#                (touch it and every verb becomes a silent no-op)
#
# Reaper (reap_stale, run by hook-prompt AFTER its nudge output is emitted, so it
# can't delay or alter it; at most once per hour, throttled by the mtime of
# <root>/.reaped, which is touched before the work starts). For each real,
# non-symlink subdir of the root whose name passes session_dir validation and
# that isn't the current session: remove it if it holds `ended`, or if nothing in
# it was modified in the last 7 days (find -newermt on the dir + its files).
# A stale, un-ended dir still holding marker/draft first logs `pending_orphaned`.
# Removal is by explicit file names (+ draft.tmp.* glob) inside the validated dir,
# then rmdir — unknown leftovers keep the dir (never forced). A dir whose .lock
# is held (flock -n fails) is skipped until the next reap; no lock is held across
# the whole run. log.jsonl over WB_CAPTURE_LOG_MAX bytes (default 5242880) is
# mv'd to log.jsonl.1 (replacing an older one). The root must be non-empty, not /,
# and end in /wb/capture, else the reaper does nothing (fail open).
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

# Kept deliberately strong: measured 2026-10-09 over 1382 recent assistant messages,
# "instead of"/"rather than"/"rejected" matched ~9% of all messages (ordinary prose);
# this list matches <1%. Recall gaps are the Haiku sweep's job.
DEFAULT_PHRASES="we decided|decided to|going with|let's go with|we'll go with|i'll go with|went with|settled on|the decision is|chose |opting for|ruled out"
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
TASK_PATH=""
INPUT=""

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
  TASK_PATH="$task"
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

# read_input — slurp hook stdin once into INPUT (guarded: a manual, tty
# invocation can't hang). jq_in <filter> parses fields out of INPUT.
read_input() { [ -t 0 ] || INPUT="$(cat 2>/dev/null || true)"; }
jq_in() { printf '%s' "$INPUT" | jq -r "$1" 2>/dev/null || true; }

# hook_session_dir — sid + validated dir from INPUT; sets SID, SDIR or exits 0.
hook_session_dir() {
  SID="$(jq_in '.session_id // empty')"
  SDIR="$(session_dir "$SID")" || quiet_exit
}

# read_num <file> — integer contents or 0.
read_num() {
  local v; v="$(cat "$1" 2>/dev/null || true)"
  [[ "$v" =~ ^[0-9]+$ ]] && echo "$v" || echo 0
}

# lock_session <dir> / unlock_session — flock on <dir>/.lock (fd 9) guarding the
# unchanged/taskhash counters, which the sync hook-stop and the async sweep both
# read-modify-write. Fails open: no flock (or no writable lock file) = no lock.
lock_session() {
  command -v flock >/dev/null 2>&1 || return 0
  { exec 9>"$1/.lock"; } 2>/dev/null || return 0
  flock 9 2>/dev/null || true
}
unlock_session() { exec 9>&-; }

# hook_posttool — a `wb append … Decisions` Bash command marks the turn recorded.
hook_posttool() {
  # cheap pre-filter on the raw JSON, before any jq
  case "$INPUT" in *wb*) ;; *) return 0 ;; esac
  case "$INPUT" in *append*) ;; *) return 0 ;; esac
  case "$INPUT" in *Decisions*) ;; *) return 0 ;; esac
  local cmd re
  cmd="$(jq_in '.tool_input.command // empty')"
  local q="'\""
  re='(^|[;&|(]|\$\()[[:space:]]*([A-Za-z_][A-Za-z0-9_]*=[^[:space:]]*[[:space:]]+)*([^[:space:];&|]*/)?wb[[:space:]]+append[[:space:]]([^;&|]*[[:space:]'"$q"'])?Decisions([[:space:]'"$q"']|$)'
  [[ "$cmd" =~ $re ]] || return 0
  hook_session_dir
  mkdir -p "$SDIR" 2>/dev/null || return 0
  : >"$SDIR/recorded"
  if [ -e "$SDIR/outstanding" ]; then
    log_event "$SID" followed "$(cat "$SDIR/outstanding" 2>/dev/null)"
    remove_named "$SDIR" outstanding
  fi
}

# hook_stop — detect (phrase match), suppress when recorded, maintain counters.
hook_stop() {
  hook_session_dir
  mkdir -p "$SDIR" 2>/dev/null || return 0
  load_config
  local msg cd matched="" p
  msg="$(jq_in '.last_assistant_message // empty')"
  cd="$(read_num "$SDIR/cooldown")"
  if [ -e "$SDIR/recorded" ]; then
    remove_named "$SDIR" recorded
  elif [ "$cd" -gt 0 ]; then
    : # cooldown turn: suppressed
  elif [ ! -e "$SDIR/muted" ] && [ -n "$msg" ]; then
    local IFS='|' lmsg="${msg,,}"
    for p in $CFG_PHRASES; do
      [ -n "$p" ] || continue
      if [[ "$lmsg" == *"${p,,}"* ]]; then matched="$p"; break; fi
    done
    unset IFS
  fi
  if [ -n "$matched" ]; then
    printf '%s' "$matched" >"$SDIR/marker"
    printf '%s\n' "$CFG_COOLDOWN" >"$SDIR/cooldown"
  elif [ "$cd" -gt 0 ]; then
    printf '%s\n' "$((cd - 1))" >"$SDIR/cooldown"
  fi
  # task-hash / unchanged counter (locked: races with the async sweep)
  lock_session "$SDIR"
  local h="" old un
  [ -n "$TASK_PATH" ] && [ -f "$TASK_PATH" ] && h="$(sha1sum <"$TASK_PATH" 2>/dev/null | cut -d' ' -f1)"
  old="$(cat "$SDIR/taskhash" 2>/dev/null || true)"
  un="$(read_num "$SDIR/unchanged")"
  if [ -n "$h" ] && [ "$h" = "$old" ]; then
    if [ -e "$SDIR/synthetic" ]; then :; else un=$((un + 1)); fi
  else
    [ -n "$h" ] && printf '%s\n' "$h" >"$SDIR/taskhash" || remove_named "$SDIR" taskhash
    un=0
  fi
  printf '%s\n' "$un" >"$SDIR/unchanged"
  unlock_session
  printf '%s\n' "$TASK_PATH" >"$SDIR/taskpath"
  remove_named "$SDIR" synthetic
}

# hook_prompt — nudge, then (cheaply, once an hour) reap stale state.
hook_prompt() {
  hook_prompt_nudge
  reap_stale
}

# hook_prompt_nudge — stamp the pane, deliver at most one nudge line.
hook_prompt_nudge() {
  hook_session_dir
  tmux set -p @wb_capture_sid "$SID" >/dev/null 2>&1 || true
  mkdir -p "$SDIR" 2>/dev/null || return 0
  # a prompt means the session is alive: a resumed session (`claude --resume`
  # keeps its session_id) must shed the tombstone its SessionEnd left, or the
  # sweep would skip it forever
  remove_named "$SDIR" ended
  local prompt
  prompt="$(jq_in '.prompt // empty')"
  case "$prompt" in
    '<task-notification>'*) : >"$SDIR/synthetic"; return 0 ;;
  esac
  # a real prompt starts a new turn: a `recorded` left by a turn that never
  # reached Stop (interrupted) must not suppress this turn's marker
  remove_named "$SDIR" synthetic recorded
  local line="" source="" dh="" phrase
  if [ -f "$SDIR/draft" ]; then
    dh="$(sha1sum <"$SDIR/draft" 2>/dev/null | cut -d' ' -f1)"
    if [ -n "$dh" ] && [ "$dh" != "$(cat "$SDIR/nudged_draft" 2>/dev/null || true)" ]; then
      line="[wb-capture] A background review drafted an unrecorded decision ($SDIR/draft). Run /wb-decide to review/accept, or /wb-decide dismiss."
      source=sweep
      printf '%s\n' "$dh" >"$SDIR/nudged_draft"
    fi
  fi
  if [ -z "$line" ] && [ -f "$SDIR/marker" ]; then
    phrase="$(tr -d '\000-\037\177' <"$SDIR/marker" 2>/dev/null || true)"
    if [ -n "$phrase" ]; then
      line="[wb-capture] Last turn read like a decision (\"$phrase\"). If it settled something, run /wb-decide; otherwise ignore or /wb-decide dismiss."
      source=phrase
    fi
  fi
  # a draft nudge (or a draft already nudged) supersedes any stale marker
  [ -f "$SDIR/draft" ] && remove_named "$SDIR" marker
  [ -n "$line" ] || { remove_named "$SDIR" marker; return 0; }
  remove_named "$SDIR" marker
  jq -nc --arg c "$line" \
    '{hookSpecificOutput:{hookEventName:"UserPromptSubmit",additionalContext:$c}}' 2>/dev/null || return 0
  printf '%s' "$source" >"$SDIR/outstanding"
  log_event "$SID" nudge_fired "$source"
}

# hook_end — SessionEnd: record anything left pending, drop the tombstone.
hook_end() {
  hook_session_dir
  mkdir -p "$SDIR" 2>/dev/null || return 0
  local m=false d=false
  [ -e "$SDIR/marker" ] && m=true
  [ -e "$SDIR/draft" ] && d=true
  if [ "$m" = true ] || [ "$d" = true ]; then
    log_event "$SID" pending_at_end "" "{\"marker\":$m,\"draft\":$d}"
  fi
  : >"$SDIR/ended" 2>/dev/null || true
}

# reap_dir <dir> — remove a validated session dir by explicit names, then rmdir.
reap_dir() {
  local d="$1" f
  remove_named "$d" marker recorded cooldown taskhash unchanged draft muted \
    outstanding ended synthetic nudged_draft taskpath sweep_offset .lock
  for f in "$d"/draft.tmp.*; do [ -f "$f" ] && rm -f -- "$f" 2>/dev/null; done
  rmdir -- "$d" 2>/dev/null || true
}

# reap_stale — see header. Never fails the hook.
reap_stale() {
  local root="$CAPTURE_ROOT" stamp
  case "$root" in ''|/) return 0 ;; */wb/capture) ;; *) return 0 ;; esac
  [ -d "$root" ] && [ ! -L "$root" ] || return 0
  stamp="$root/.reaped"
  if [ -e "$stamp" ] && [ -n "$(find "$stamp" -maxdepth 0 -mmin -60 2>/dev/null)" ]; then
    return 0
  fi
  : >"$stamp" 2>/dev/null || return 0
  # rotate the log
  local max="${WB_CAPTURE_LOG_MAX:-5242880}" size
  [[ "$max" =~ ^[0-9]+$ ]] || max=5242880
  if [ -f "$LOG_FILE" ]; then
    size="$(wc -c <"$LOG_FILE" 2>/dev/null | tr -d ' ')"
    [[ "$size" =~ ^[0-9]+$ ]] && [ "$size" -gt "$max" ] && mv -f -- "$LOG_FILE" "$LOG_FILE.1" 2>/dev/null
  fi
  local d name sdir stale pm pd saved_stem="$TASK_STEM" tp
  for d in "$root"/*/; do
    d="${d%/}"; name="${d##*/}"
    [ -d "$d" ] && [ ! -L "$d" ] || continue
    sdir="$(session_dir "$name")" || continue
    [ "$name" != "${SID:-}" ] || continue
    stale=0
    if [ ! -e "$sdir/ended" ]; then
      [ -z "$(find "$sdir" -maxdepth 1 -newermt '7 days ago' -print -quit 2>/dev/null)" ] || continue
      stale=1
    fi
    if command -v flock >/dev/null 2>&1; then
      { exec 8>"$sdir/.lock"; } 2>/dev/null || continue
      flock -n 8 2>/dev/null || { exec 8>&-; continue; }
    fi
    if [ "$stale" = 1 ] && { [ -e "$sdir/marker" ] || [ -e "$sdir/draft" ]; }; then
      pm=false; pd=false
      [ -e "$sdir/marker" ] && pm=true
      [ -e "$sdir/draft" ] && pd=true
      tp="$(head -n1 "$sdir/taskpath" 2>/dev/null || true)"; tp="${tp##*/}"
      TASK_STEM="${tp%.md}"
      log_event "$name" pending_orphaned "" "{\"marker\":$pm,\"draft\":$pd}"
      TASK_STEM="$saved_stem"
    fi
    reap_dir "$sdir"
    exec 8>&- 2>/dev/null
  done
  return 0
}

# log_event <sid> <event> [source] [extra-json] — append one compact JSON line.
# extra-json is an optional compact JSON object merged into the line (e.g.
# '{"result":"draft"}'); an invalid one drops the line rather than the hook.
log_event() {
  local sid="$1" event="$2" source="${3:-}" extra="${4:-}" ts line
  [ -n "$extra" ] || extra='{}'
  ts="$(date +%Y-%m-%dT%H:%M:%S%z)"
  ts="${ts%??}:${ts: -2}"
  line="$(jq -nc --arg ts "$ts" --arg sid "$sid" --arg task "$TASK_STEM" \
    --arg event "$event" --arg source "$source" --argjson extra "$extra" \
    '{ts:$ts,session_id:$sid,task:$task,event:$event}
     + (if $source == "" then {} else {source:$source} end) + $extra' 2>/dev/null)" || return 0
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

# Source-able as a library (wb-capture-sweep.sh): dispatch only when executed.
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
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
    hook-prompt|hook-posttool|hook-stop)
      read_input
      case "$verb" in
        hook-prompt)   hook_prompt ;;
        hook-posttool) hook_posttool ;;
        hook-stop)     hook_stop ;;
      esac
      ;;
    hook-end)
      read_input
      hook_end
      ;;
  esac


  exit 0
fi
