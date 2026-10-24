#!/usr/bin/env bash
# wb-capture.sh — shared core of the wb decision auto-capture feature. Claude
# Code hooks (registered by the wb-capture plugin's hooks.json) and the
# /wb-decide skill both go through this one script, so state paths, guards,
# config and the event log live in exactly one place.
#
# Model: the agent is never told about drafts. The background sweep
# (wb-capture-sweep.sh) drafts decisions it finds unrecorded; drafts wait on the
# SHELF (<root>/shelved/<task-stem>/, one file per drafted decision) until Jet
# reviews them at a checkpoint (/wb-save, /close-out, /wb-decide shelved, the
# weekly review). No hook injects anything into the agent's context.
#
# Verbs:
#   hook-prompt | hook-posttool | hook-stop | hook-end
#                  Claude Code hook entry points (stdin JSON read once, session_id
#                  from `.session_id`; all exit 0, silent on failure).
#     hook-prompt    (UserPromptSubmit) stamps @wb_capture_sid, sheds the `ended`
#                  tombstone (a resumed session is alive), flags synthetic prompts
#                  (`synthetic`: `<task-notification>` from finished background
#                  sub-agents and sub-agent hand-backs, which arrive as `Another
#                  Claude session sent a message:` / `<agent-message ...>`, leading
#                  whitespace tolerated), then runs the hourly reaper. Prints nothing.
#     hook-stop      (Stop) updates taskhash/unchanged — the quiet-turn counter the
#                  sweep reads (skipped after a synthetic prompt) — and `taskpath`.
#                  No phrase matching: nothing is detected here.
#     hook-posttool  a silent no-op (exits 0 before any guard). The hook entry was
#                  removed; the verb stays so a session started before the change,
#                  which still calls it on every Bash tool call, doesn't print an
#                  error each time.
#     hook-end       (SessionEnd, 1.5s budget: one jq parse, no network, no task
#                  file) writes the `ended` tombstone and nothing else. A draft still
#                  in the session dir stays there: the reaper shelves it
#                  (reason reaped). Nothing here ever deletes a draft: resolved
#                  drafts are MOVED to <root>/resolved/ (see `retire_draft`, "Paths").
#   accept <path>  after /wb-decide recorded a shelved draft (`wb append … Decisions`
#                  && accept): move it (and its .stale sidecar) to resolved/ (outcome
#                  `shelved_accepted`), log `shelved_accepted` {"draft":"<basename>"}
#                  (+ "stale":true when marked; no source). Single-phase: nothing is
#                  armed beforehand and no flag file is written. A failed move exits 1
#                  and logs nothing. <path> must be a shelved draft of this task, or of
#                  the task named by `--task <stem>`; a path outside the shelf exits 1
#                  with a message on stderr.
#   dismiss <path> same, outcome `shelved_dismissed`, logs `shelved_dismissed`
#                  {"draft":"<basename>"}. A bare `dismiss` (no <path>, no --task) is a
#                  usage error: exit 1, nothing removed, nothing logged.
#   keep <path>    "leave it for later": validates <path> exactly like accept/dismiss,
#                  logs `shelved_kept` {"draft":"<basename>"} and leaves the file where it
#                  is. One event per review that showed the draft and left it.
#   accept|dismiss|keep ... --task <stem> ...
#                  resolve a shelved draft of ANOTHER task (typically one already
#                  closed): `dismiss --task <stem> <path>`. Path validation uses
#                  shelved/<stem>/ instead of this task's dir, and the logged event's
#                  `task` is <stem>. Any other `--option` is refused (exit 1, nothing
#                  changed), so a caller still using a removed flag (`accept --begin`,
#                  `dismiss --expect`) can never have it read as a path.
#   Every accept/dismiss/keep works WITHOUT a wb session: it ignores the kill switch and
#                  the tmux / @task / capture-session requirements (only WB_CAPTURE_SWEEP
#                  still silences it). The stem comes from --task, else the session's
#                  @task, else it exits 1 with a message (never a silent exit 0).
#                  Sessionless, the event is logged with an empty session_id (no jq: the
#                  file is still moved, the log line skipped).
#   mute | unmute  write / remove the per-session `muted` flag; logs each.
#   status         print mute state, session id, the log path, then this task's shelved
#                  drafts (one `shelved: <path>` line each, `(stale)` when marked;
#                  `shelved: none`) — human-readable lines. Read-only.
#   shelved [--all [--min-age-days <N>] | --task <stem> | --count --task <stem>]
#                  store verb, read-only, needs no tmux session or @task (honours only
#                  WB_CAPTURE_SWEEP): list shelved drafts, one path per line with a
#                  `(stale)` suffix when marked. `--task` lists one task's; `--all` groups
#                  every task as `<stem>:` then indented paths; bare `shelved` lists the
#                  current session's task (error when it has none).
#                  `--count --task <stem>` prints that task's number of shelved drafts (0
#                  when none) and nothing else; it makes no tmux call, so the status bar
#                  can run it every few seconds. `--min-age-days <N>` (with --all) keeps
#                  only drafts whose filename timestamp is more than N days old; a name
#                  with no timestamp counts as old, so it is never hidden.
#   pending-for-task <task-file>
#                  store verb, read-only: every shelved draft for that task's stem, one
#                  path per line, nothing when none. This is what `wb done`'s guard
#                  asks, so wb.sh never learns the capture layout. A per-session draft
#                  slot left from before the shelf-only change is not listed (moved to
#                  the shelf by hand at rollout).
#   log-shelved-left <stem> <count>
#                  store verb: append the `shelved_left` event (session_id empty) that `wb
#                  done --leave-shelved` records. Needs jq, else a silent no-op.
#   _config        TEST-ONLY: print the resolved config as key=value lines.
#
# Agent verbs find their session via the tmux PANE option @wb_capture_sid
# (stamped by hook-prompt); they run inside the agent's Bash, which inherits
# $TMUX_PANE. With it unset they print one error line and exit 0.
#
# Paths:
#   state root   ${XDG_STATE_HOME:-$HOME/.local/state}/wb/capture/
#   per session  <root>/<session_id>/   (taskhash unchanged draft muted ended
#                                        synthetic taskpath sweep_offset
#                                        sweep_failures sweep_invalid draft_stale
#                                        .lock draft.tmp.* draft_stale.tmp.*)
#   shelved drafts <root>/shelved/<task-stem>/<YYYYmmddTHHMMSS>-<sid>.md  (per TASK,
#                                        outlives the session dir; a sidecar
#                                        <name>.md.stale marks a stale draft;
#                                        <root>/shelved/_unknown/ when the task
#                                        is not known)
#   resolved drafts <root>/resolved/<task-stem>/<YYYYmmddTHHMMSS>-<outcome>-<name>.md
#                                        (outcome shelved_accepted|shelved_dismissed;
#                                        <name> = the shelved file's basename; a
#                                        `.md.stale` sidecar travels with it; kept
#                                        RESOLVED_KEEP_DAYS = 30 days, then pruned by
#                                        the reaper)
#   event log    <root>/log.jsonl       (one compact JSON line per event:
#                                        ts, session_id, task, event[, source][, draft])
#   reaper stamp <root>/.reaped          (mtime = last reap; at most one per hour)
#   log rotation <root>/log.jsonl.1      (previous log; see reaper)
#   kill switch  ${XDG_STATE_HOME:-$HOME/.local/state}/wb/disable-capture
#                (touch it and every verb becomes a silent no-op)
#
# A draft is never archived without Jet's explicit accept or dismiss, and never
# deleted at all: accept/dismiss move it to <root>/resolved/ (kept 30 days, then
# reaped). The session dir's `draft` slot is the sweep's output until the sweep
# writes the shelf directly; SessionEnd leaves a remaining one in place and the
# reaper shelves one it finds in a dir it is about to remove (reason reaped).
# Stale drafts: the sweep snapshots `## Decisions` (the text the model sees), then
# waits up to a minute for the model. If that section changed meanwhile (typically
# /wb-decide recording the very decision being drafted) the answer is discarded
# and the child reruns once on a fresh snapshot. Only if the section changes a
# second time during the rerun is the draft written — Jet decides — plus
# `draft_stale`, holding how many `### ` entries `## Decisions` had at the
# re-snapshot. A shelved stale draft carries a `.stale` sidecar, and its events are
# tagged `"stale":true`.
# `sweep_failures` (written by wb-capture-sweep.sh) counts consecutive failed
# sweeps; at sweep_max_failures the sweep skips with reason `backoff`.
# `sweep_invalid` marks that the last answer broke the output contract (neither
# NONE nor a `### ` entry): its excerpt is retried once, then skipped.
#
# Reaper (reap_stale, run by hook-prompt; at most once per hour, throttled by the
# mtime of <root>/.reaped, which is touched before the work starts). For each real,
# non-symlink subdir of the root whose name passes session_dir validation and
# that isn't the current session (and isn't `shelved` or `resolved`): remove it if it holds `ended`
# and that file is older than a grace period of 2 x sweep_timeout + 60 seconds (the
# timeout is the sweep's effective one: sweep_timeout=0 means the default 60, so 180s; an
# async sweep may still be running its child and shelve a late draft; if the age
# can't be computed the dir waits for the next reap), or if nothing in
# it was modified in the last 7 days (find -newermt on the dir + its files).
# A draft in a dir about to be removed is shelved first (reason reaped); a dir whose
# draft can't be shelved is kept and retried on the next reap.
# Removal is by explicit file names (+ draft.tmp.* glob) inside the validated dir,
# then rmdir — unknown leftovers keep the dir (never forced). The names include
# state files that earlier versions wrote, so session dirs from before the nudge
# removal still get reaped. `draft` is not among the names: a dir still holding one
# is kept (the reaper shelves drafts first).
# The same reap prunes resolved/<stem>/: regular non-symlink *.md / *.md.stale files
# older than RESOLVED_KEEP_DAYS (30) go by explicit per-file rm, then empty stem dirs
# are rmdir'd. A dir whose .lock
# is held (flock -n fails) is skipped until the next reap; no lock is held across
# the whole run. log.jsonl over WB_CAPTURE_LOG_MAX bytes (default 5242880) is
# mv'd to log.jsonl.1 (replacing an older one). The root must be non-empty, not /,
# and end in /wb/capture, else the reaper does nothing (fail open).
#
# Config (KTD8): defaults below, overridden by the optional untracked file
# ${XDG_CONFIG_HOME:-$HOME/.config}/wb/capture.conf — `KEY=value` lines, parsed
# line by line, NEVER sourced or eval'd (a `$(...)` in a value stays literal).
# `#` lines, blank lines, unknown keys and malformed lines are ignored — which is
# how an existing file's retired phrase-matching keys are skipped without a word.
# Values are taken verbatim to end of line.
#   sweep_every    integer, unchanged turns before a sweep (default 4)
#   sweep          on|off, background model sweep          (default on)
#   sweep_timeout  integer seconds for the sweep child     (default 60)
#   sweep_max_failures  integer, consecutive failed sweeps before the sweep
#                  backs off for the session; 0 = never back off (default 3)
#   sweep_model    model alias/id for the sweep child, no leading - (default sonnet)
#   sweep_effort   low|medium|high|xhigh|max, the child's --effort (default medium)
# A non-integer / non-on|off / otherwise invalid value falls back to the default.
#
# Guards (R5), checked in order before any state is touched: WB_CAPTURE_SWEEP
# set (recursion flag for the headless sweep child), kill switch, not in tmux,
# no @task on the tmux session, jq missing. Every one exits 0 silently. Exception:
# accept/dismiss/keep (see above) apply only the recursion flag.
#
# Never sources wb.sh and never writes under ~/code/tasks (KTD5): @task is read
# straight from the tmux session option. No `-e`; every path exits 0 so a hook
# can never block or fail Claude.
set -uo pipefail

DEFAULT_SWEEP_EVERY=4
DEFAULT_SWEEP=on
DEFAULT_SWEEP_TIMEOUT=60
DEFAULT_SWEEP_MAX_FAILURES=3
DEFAULT_SWEEP_MODEL=sonnet
DEFAULT_SWEEP_EFFORT=medium
# Days an archived (resolved) draft is kept before the reaper prunes it
RESOLVED_KEEP_DAYS=30

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

# tmux_task — the one place the current tmux session's @task is read. Sets
# TASK_PATH and TASK_STEM and returns 0; returns 1 (setting nothing) when not in
# tmux, tmux is missing, or the session has no @task. Never exits, so callers
# choose: the guard chain exits quietly, the path-carrying and listing verbs go on.
tmux_task() {
  [ -n "${TMUX:-}" ] || return 1
  command -v tmux >/dev/null 2>&1 || return 1
  local session task
  session="$(tmux display-message -p '#S' 2>/dev/null || true)"
  [ -n "$session" ] || return 1
  task="$(tmux show -t "=$session:" -v @task 2>/dev/null || true)"
  [ -n "$task" ] || return 1
  TASK_PATH="$task"
  task="${task##*/}"
  TASK_STEM="${task%.md}"
}

# guard_chain — recursion flag, kill switch, tmux, @task, jq. Sets TASK_STEM.
guard_chain() {
  [ -n "${WB_CAPTURE_SWEEP:-}" ] && quiet_exit
  [ -e "$KILL_SWITCH" ] && quiet_exit
  tmux_task || quiet_exit
  command -v jq >/dev/null 2>&1 || quiet_exit
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
# Always -t "$TMUX_PANE": untargeted, tmux reads the client's focused pane.
pane_sid() { [ -n "${TMUX_PANE:-}" ] && tmux show -pv -t "$TMUX_PANE" @wb_capture_sid 2>/dev/null || true; }

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

# hook_stop — maintain the quiet-turn counters the sweep reads. Nothing is detected here.
hook_stop() {
  hook_session_dir
  mkdir -p "$SDIR" 2>/dev/null || return 0
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

# hook_prompt — stamp the pane, shed the tombstone, flag synthetic turns, then
# (cheaply, once an hour) reap stale state. Prints nothing.
hook_prompt() {
  hook_prompt_stamp
  reap_stale
}

hook_prompt_stamp() {
  hook_session_dir
  [ -n "${TMUX_PANE:-}" ] && { tmux set -p -t "$TMUX_PANE" @wb_capture_sid "$SID" >/dev/null 2>&1 || true; }
  mkdir -p "$SDIR" 2>/dev/null || return 0
  # a prompt means the session is alive: a resumed session (`claude --resume`
  # keeps its session_id) must shed the tombstone its SessionEnd left, or the
  # sweep would skip it forever
  remove_named "$SDIR" ended
  local prompt
  prompt="$(jq_in '.prompt // empty')"
  # synthetic turns: background-agent notifications and sub-agent hand-backs
  # (leading whitespace/newlines are not part of the prefix test)
  local p_trim="${prompt#"${prompt%%[![:space:]]*}"}"
  case "$p_trim" in
    '<task-notification>'*|'Another Claude session sent a message:'*|'<agent-message'*)
      : >"$SDIR/synthetic"; return 0 ;;
  esac
  # a real prompt starts a new turn: a `synthetic` left by a turn that never
  # reached Stop (interrupted) must not suppress this turn's count
  remove_named "$SDIR" synthetic
}

# hook_end — SessionEnd: drop the tombstone. A draft still in the session dir stays
# there; the reaper shelves it.
hook_end() {
  hook_session_dir
  mkdir -p "$SDIR" 2>/dev/null || return 0
  : >"$SDIR/ended" 2>/dev/null || true
}

# shelved_dest <sid> — print a fresh, unused <root>/shelved/<task-stem>/<YYYYmmddTHHMMSS>-<sid>.md
# (creating the dir); TASK_STEM empty or unsafe -> shelved/_unknown. Fails 1 if the dir can't be made.
shelved_dest() {
  local sid="$1" stem="${TASK_STEM:-_unknown}" dir dest ts n=0
  case "$stem" in .|..|*/*) stem=_unknown ;; esac
  dir="$CAPTURE_ROOT/shelved/$stem"
  mkdir -p "$dir" 2>/dev/null || return 1
  ts="$(date +%Y%m%dT%H%M%S)"
  dest="$dir/$ts-$sid.md"
  while [ -e "$dest" ]; do n=$((n + 1)); dest="$dir/$ts-$sid-$n.md"; done
  printf '%s\n' "$dest"
}

# retire_draft <src> <outcome> <name> — move one draft (and its `.stale` sidecar, kept as
# <dest>.stale) to <root>/resolved/<task-stem>/<YYYYmmddTHHMMSS>-<outcome>-<name>.md instead of
# deleting it: a draft is the only copy of its text. <outcome> is shelved_accepted|
# shelved_dismissed; <name> is the shelved file's basename without .md. TASK_STEM empty or unsafe -> resolved/_unknown. The reaper prunes the archive
# after RESOLVED_KEEP_DAYS. Fails 1 with the source left in place if the move can't be made.
retire_draft() {
  local src="$1" outcome="$2" name="$3" stem="${TASK_STEM:-_unknown}" dir dest ts n=0
  case "$stem" in .|..|*/*) stem=_unknown ;; esac
  dir="$CAPTURE_ROOT/resolved/$stem"
  mkdir -p "$dir" 2>/dev/null || return 1
  ts="$(date +%Y%m%dT%H%M%S)"
  dest="$dir/$ts-$outcome-$name.md"
  while [ -e "$dest" ] || [ -L "$dest" ]; do n=$((n + 1)); dest="$dir/$ts-$outcome-$name-$n.md"; done
  mv -- "$src" "$dest" 2>/dev/null || return 1
  # the draft is safe now; a sidecar that won't move is only a stale flag
  [ -e "$src.stale" ] && { mv -- "$src.stale" "$dest.stale" 2>/dev/null || true; }
  # mv keeps the draft's old mtime: restart the keep-days clock at archive time
  touch -- "$dest" 2>/dev/null || true
  [ -e "$dest.stale" ] && { touch -- "$dest.stale" 2>/dev/null || true; }
  return 0
}

# shelve_draft <sid> <reason> — move SDIR's draft to the per-task shelved dir
# (verbatim, <YYYYmmddTHHMMSS>-<sid>.md; a `.stale` sidecar when draft_stale
# exists), log `draft_shelved` (+ stale:true), then drop draft_stale. TASK_STEM
# empty -> shelved/_unknown. If the move fails nothing is removed (never lose it).
shelve_draft() {
  local sid="$1" reason="$2" dest extra
  [ -f "$SDIR/draft" ] || return 0
  dest="$(shelved_dest "$sid")" || return 1
  mv -- "$SDIR/draft" "$dest" 2>/dev/null || return 1
  extra="{\"reason\":\"$reason\"}"
  if [ -e "$SDIR/draft_stale" ]; then
    : >"$dest.stale" 2>/dev/null
    extra="{\"reason\":\"$reason\",\"stale\":true}"
  fi
  log_event "$sid" draft_shelved "" "$extra"
  remove_named "$SDIR" draft_stale
}

# shelve_answer <sid> <reason> <text> <stale: true|false> — shelve a NEW sweep answer
# (text) that never became SDIR's draft: write it to the shelved dir (atomically, so a
# half-written file is never listed), a `.stale` sidecar when <stale> is true, log
# `draft_shelved` (+ stale:true). Touches no session state: the draft already in SDIR
# stays exactly as it was. Fails 1 with nothing left behind.
shelve_answer() {
  local sid="$1" reason="$2" text="$3" stale="$4" dest extra
  dest="$(shelved_dest "$sid")" || return 1
  if ! { printf '%s\n' "$text" >"$dest.tmp.$$" && mv -f -- "$dest.tmp.$$" "$dest"; } 2>/dev/null; then
    rm -f -- "$dest.tmp.$$" 2>/dev/null; return 1
  fi
  extra="{\"reason\":\"$reason\"}"
  if [ "$stale" = true ]; then
    : >"$dest.stale" 2>/dev/null
    extra="{\"reason\":\"$reason\",\"stale\":true}"
  fi
  log_event "$sid" draft_shelved "" "$extra"
}

# reap_dir <dir> — remove a validated session dir by explicit names, then rmdir.
reap_dir() {
  local d="$1" f
  # `draft` is deliberately not listed: a dir still holding one is kept (rmdir fails).
  # Line 2 is state that pre-nudge-removal versions wrote: listed so those dirs still reap.
  remove_named "$d" taskhash unchanged muted ended synthetic taskpath sweep_offset \
    sweep_failures sweep_invalid draft_stale .lock \
    marker recorded cooldown outstanding nudged_draft draft_strikes reviewing shelved_accept
  for f in "$d"/draft.tmp.* "$d"/draft_stale.tmp.*; do [ -f "$f" ] && rm -f -- "$f" 2>/dev/null; done
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
  load_config
  # the sweep runs its child for DEFAULT_SWEEP_TIMEOUT when sweep_timeout is 0, so the
  # grace is built from that same effective timeout (0 would otherwise shrink it to 60s)
  local eff_timeout="$CFG_SWEEP_TIMEOUT"
  [ "$eff_timeout" -gt 0 ] 2>/dev/null || eff_timeout="$DEFAULT_SWEEP_TIMEOUT"
  local grace=$(( 2 * eff_timeout + 60 )) cutoff
  cutoff=$(( $(date +%s) - grace )) 2>/dev/null || cutoff=""
  local d name sdir stale saved_stem="$TASK_STEM" tp SDIR  # SDIR: shelve_draft reads it
  for d in "$root"/*/; do
    d="${d%/}"; name="${d##*/}"
    [ -d "$d" ] && [ ! -L "$d" ] || continue
    sdir="$(session_dir "$name")" || continue
    [ "$name" != "${SID:-}" ] && [ "$name" != shelved ] && [ "$name" != resolved ] || continue
    stale=0
    if [ -e "$sdir/ended" ]; then
      # an in-flight sweep may still shelve a late draft here: reap only after a grace period
      [ -n "$cutoff" ] && [ "$cutoff" -gt 0 ] 2>/dev/null || continue
      [ -z "$(find "$sdir/ended" -maxdepth 0 -newermt "@$cutoff" -print 2>/dev/null)" ] || continue
    else
      [ -z "$(find "$sdir" -maxdepth 1 -newermt '7 days ago' -print -quit 2>/dev/null)" ] || continue
      stale=1
    fi
    if command -v flock >/dev/null 2>&1; then
      { exec 8>"$sdir/.lock"; } 2>/dev/null || continue
      flock -n 8 2>/dev/null || { exec 8>&-; continue; }
    fi
    tp="$(head -n1 "$sdir/taskpath" 2>/dev/null || true)"; tp="${tp##*/}"
    TASK_STEM="${tp%.md}"
    SDIR="$sdir"
    # a draft that can't be shelved keeps its dir: retried on the next reap
    if [ -e "$sdir/draft" ] && ! shelve_draft "$name" reaped; then
      TASK_STEM="$saved_stem"; exec 8>&-; continue
    fi
    TASK_STEM="$saved_stem"
    reap_dir "$sdir"
    exec 8>&-
  done
  prune_resolved "$root"
  return 0
}

# prune_resolved <root> — delete archived drafts older than RESOLVED_KEEP_DAYS: only regular,
# non-symlink files named *.md / *.md.stale directly inside resolved/<stem>/, one explicit
# rm per validated path (no find -delete, no -r), then rmdir the stem dirs left empty
# (rmdir only, never forced). Never fails the hook.
prune_resolved() {
  local root="$1" rdir="$1/resolved" sd f
  [ -d "$rdir" ] && [ ! -L "$rdir" ] || return 0
  for sd in "$rdir"/*/; do
    sd="${sd%/}"
    [ -d "$sd" ] && [ ! -L "$sd" ] || continue
    for f in "$sd"/*.md "$sd"/*.md.stale; do
      [ -f "$f" ] && [ ! -L "$f" ] || continue
      [ -n "$(find "$f" -maxdepth 0 -type f -mtime +"$RESOLVED_KEEP_DAYS" -print 2>/dev/null)" ] || continue
      rm -f -- "$f" 2>/dev/null || true
    done
    rmdir -- "$sd" 2>/dev/null || true
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
  CFG_SWEEP_EVERY="$DEFAULT_SWEEP_EVERY"
  CFG_SWEEP="$DEFAULT_SWEEP"
  CFG_SWEEP_TIMEOUT="$DEFAULT_SWEEP_TIMEOUT"
  CFG_SWEEP_MAX_FAILURES="$DEFAULT_SWEEP_MAX_FAILURES"
  CFG_SWEEP_MODEL="$DEFAULT_SWEEP_MODEL"
  CFG_SWEEP_EFFORT="$DEFAULT_SWEEP_EFFORT"
  [ -r "$CONF_FILE" ] || return 0
  local line key val
  while IFS= read -r line || [ -n "$line" ]; do
    line="${line%$'\r'}"
    line="${line#"${line%%[![:space:]]*}"}"
    case "$line" in ''|'#'*) continue ;; esac
    [[ "$line" =~ ^[a-z_]+= ]] || continue
    key="${line%%=*}"; val="${line#*=}"
    case "$key" in
      sweep_every)   [[ "$val" =~ ^[0-9]+$ ]] && CFG_SWEEP_EVERY="$val" ;;
      sweep)         case "$val" in on|off) CFG_SWEEP="$val" ;; esac ;;
      sweep_timeout) [[ "$val" =~ ^[0-9]+$ ]] && CFG_SWEEP_TIMEOUT="$val" ;;
      sweep_max_failures) [[ "$val" =~ ^[0-9]+$ ]] && CFG_SWEEP_MAX_FAILURES="$val" ;;
      sweep_model)   [[ "$val" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] && CFG_SWEEP_MODEL="$val" ;;
      sweep_effort)  case "$val" in low|medium|high|xhigh|max) CFG_SWEEP_EFFORT="$val" ;; esac ;;
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

cmd_status() {
  agent_session_dir
  if [ -e "$SDIR/muted" ]; then echo "muted: yes"; else echo "muted: no"; fi
  echo "session: $SID"
  echo "log: $LOG_FILE"
  local pf n=0 stem="${TASK_STEM:-_unknown}"
  local -a dirs=("$CAPTURE_ROOT/shelved/$stem")
  [ "$stem" = _unknown ] || dirs+=("$CAPTURE_ROOT/shelved/_unknown")
  local pd
  for pd in "${dirs[@]}"; do
    for pf in "$pd"/*.md; do
      [ -f "$pf" ] || continue
      n=$((n + 1))
      if [ -e "$pf.stale" ]; then echo "shelved: $pf (stale)"; else echo "shelved: $pf"; fi
    done
  done
  [ "$n" -gt 0 ] || echo "shelved: none"
}

# shelved_draft_path <path> — succeed iff <path> is a regular, non-symlink draft
# directly inside this task's shelved dir (or shelved/_unknown); else stderr +
# exit 1 (nothing changed).
shelved_draft_path() {
  local p="${1:-}" d ok=0 rest
  for d in "$CAPTURE_ROOT/shelved/${TASK_STEM:-_unknown}" "$CAPTURE_ROOT/shelved/_unknown"; do
    case "$p" in "$d"/*) rest="${p#"$d"/}"; ok=1; break ;; esac
  done
  if [ "$ok" = 1 ] && [[ "$rest" =~ ^[A-Za-z0-9._-]+\.md$ ]] && [[ "$rest" != *..* ]] \
     && [ -f "$p" ] && [ ! -L "$p" ]; then
    return 0
  fi
  echo "wb-capture: not a shelved draft of this task: ${p:-<empty>} (nothing changed)" >&2
  exit 1
}

# resolve_shelved_context — context for accept/dismiss/keep, which work with or
# without a wb session (see "accept|dismiss|keep ... --task" in the header). Sets
# SID/SDIR only when a session is really available (tmux, a task on it, a recorded
# capture session id, no kill switch); otherwise both stay empty. TASK_STEM is the
# --task stem, else the session's @task stem; neither -> stderr + exit 1.
resolve_shelved_context() {
  SID="" SDIR=""
  local sid
  if tmux_task; then
    sid="$(pane_sid)"
    # hooks are inert under the kill switch: nothing to protect, nothing to log against
    if [ ! -e "$KILL_SWITCH" ] && [ -n "$sid" ]; then
      SDIR="$(session_dir "$sid")" && SID="$sid" || SDIR=""
    fi
  fi
  [ -n "$R_TASK" ] && TASK_STEM="$R_TASK"
  if ! stem_ok "$TASK_STEM"; then
    echo "wb-capture: no task to resolve against: pass --task <stem> or run from a wb task session (nothing changed)" >&2
    exit 1
  fi
}

# cmd_shelved <shelved_accepted|shelved_dismissed|shelved_kept> <path> — resolve one
# shelved draft: accepted/dismissed archive it (and its .stale sidecar) via
# retire_draft; kept leaves it in place. Logs the event with the draft's basename
# (+ stale:true when marked on accept/dismiss; session_id empty when sessionless).
# Path rule: shelved_draft_path.
cmd_shelved() {
  resolve_shelved_context
  local ev="$1" p="${2:-}" base x
  shelved_draft_path "$p"
  base="${p##*/}"
  x="{\"draft\":\"$base\"}"
  if [ "$ev" != shelved_kept ]; then
    [ -e "$p.stale" ] && x="{\"draft\":\"$base\",\"stale\":true}"
    # archive, don't delete; a failed move changes nothing (no event)
    if ! retire_draft "$p" "$ev" "${base%.md}"; then
      echo "wb-capture: could not archive $p (nothing changed)" >&2
      exit 1
    fi
  fi
  log_event "$SID" "$ev" "" "$x"
}

# stem_ok <stem> — a safe single path component (no slash, not . or ..).
stem_ok() {
  case "${1:-}" in ''|.|..|*/*) return 1 ;; esac
  [[ "$1" =~ ^[A-Za-z0-9._-]+$ ]]
}

# shelved_paths <stem> — the shelved drafts of one task, one path per line.
shelved_paths() {
  local pf
  for pf in "$CAPTURE_ROOT/shelved/$1"/*.md; do
    [ -f "$pf" ] && [ ! -L "$pf" ] && printf '%s\n' "$pf"
  done
  return 0
}

# list_shelved_for <stem> <indent> [<cutoff>] — shelved_paths with the `(stale)` suffix;
# with <cutoff> (YYYYmmddTHHMMSS), only drafts whose filename stamp is older than it.
list_shelved_for() {
  local pf ts
  while IFS= read -r pf; do
    [ -n "$pf" ] || continue
    if [ -n "${3:-}" ]; then
      ts="${pf##*/}"; ts="${ts:0:15}"
      [[ "$ts" =~ ^[0-9]{8}T[0-9]{6}$ ]] && [[ ! "$ts" < "$3" ]] && continue
    fi
    if [ -e "$pf.stale" ]; then printf '%s%s (stale)\n' "$2" "$pf"; else printf '%s%s\n' "$2" "$pf"; fi
  done < <(shelved_paths "$1")
}

# cmd_list_shelved [--all [--min-age-days <N>] | --task <stem> | --count --task <stem>] —
# see "shelved" in the header. Read-only.
cmd_list_shelved() {
  local d stem out cutoff=""
  case "${1:-}" in
    --count)
      [ "${2:-}" = --task ] && stem_ok "${3:-}" \
        || { echo "usage: wb-capture.sh shelved --count --task <stem>" >&2; exit 1; }
      shelved_paths "$3" | wc -l | tr -d ' ' ;;
    --all)
      if [ -n "${2:-}" ]; then
        [ "$2" = --min-age-days ] && [[ "${3:-}" =~ ^[0-9]+$ ]] \
          || { echo "usage: wb-capture.sh shelved --all [--min-age-days <N>]" >&2; exit 1; }
        cutoff="$(date -d "$((10#$3)) days ago" +%Y%m%dT%H%M%S)"
      fi
      for d in "$CAPTURE_ROOT"/shelved/*/; do
        d="${d%/}"; stem="${d##*/}"
        [ -d "$d" ] && [ ! -L "$d" ] && stem_ok "$stem" || continue
        out="$(list_shelved_for "$stem" '  ' "$cutoff")"
        [ -n "$out" ] || continue
        printf '%s:\n%s\n' "$stem" "$out"
      done ;;
    --task)
      stem_ok "${2:-}" || { echo "wb-capture: shelved --task needs a task stem" >&2; exit 1; }
      list_shelved_for "$2" '' ;;
    '')
      # the current session's task, resolved without the guard chain's silent exits
      tmux_task && stem="$TASK_STEM"
      stem_ok "${stem:-}" || { echo "wb-capture: shelved: not in a wb task session; pass --all or --task <stem>" >&2; exit 1; }
      list_shelved_for "$stem" '' ;;
    *) echo "usage: wb-capture.sh shelved [--all [--min-age-days <N>] | --task <stem> | --count --task <stem>]" >&2; exit 1 ;;
  esac
}

# cmd_pending_for_task <task-file> — see "pending-for-task" in the header.
cmd_pending_for_task() {
  local tf="${1:-}" stem
  [ -n "$tf" ] || { echo "usage: wb-capture.sh pending-for-task <task-file>" >&2; exit 1; }
  stem="${tf##*/}"; stem="${stem%.md}"
  stem_ok "$stem" || exit 0
  shelved_paths "$stem"
}

# cmd_log_shelved_left <stem> <count> — see "log-shelved-left" in the header.
cmd_log_shelved_left() {
  local stem="${1:-}" count="${2:-}"
  if ! stem_ok "$stem" || [[ ! "$count" =~ ^[0-9]+$ ]]; then
    echo "usage: wb-capture.sh log-shelved-left <task-stem> <count>" >&2; exit 1
  fi
  command -v jq >/dev/null 2>&1 || exit 0
  TASK_STEM="$stem"
  log_event "" shelved_left "" "{\"count\":$((10#$count))}"
}

# parse_resolve_args <args...> — accept/dismiss/keep operands: [--task <stem>] [<path>].
# Sets R_TASK, R_PATH. A bad --task, or any other --option, exits 1 (so a removed flag is
# never read as a path).
parse_resolve_args() {
  R_TASK="" R_PATH=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --task)
        stem_ok "${2:-}" || { echo "wb-capture: --task needs a task stem (nothing changed)" >&2; exit 1; }
        R_TASK="$2"; shift 2 ;;
      --*) echo "wb-capture: unknown option $1 (nothing changed)" >&2; exit 1 ;;
      *) R_PATH="$1"; shift ;;
    esac
  done
}

cmd_config() {
  load_config
  printf 'sweep_every=%s\nsweep=%s\nsweep_timeout=%s\nsweep_max_failures=%s\n' \
    "$CFG_SWEEP_EVERY" "$CFG_SWEEP" "$CFG_SWEEP_TIMEOUT" "$CFG_SWEEP_MAX_FAILURES"
}

# Source-able as a library (wb-capture-sweep.sh): dispatch only when executed.
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  verb="${1:-}"
  case "$verb" in
    dismiss|accept|keep|mute|unmute|status|_config|hook-prompt|hook-stop|hook-end) ;;
    shelved|pending-for-task|log-shelved-left) ;;
    hook-posttool) exit 0 ;;   # no-op: the hook entry is gone, old sessions still call it
    *) exit 0 ;;
  esac

  # store verbs: take their task explicitly, so no tmux / @task guard (only the
  # recursion flag applies)
  case "$verb" in
    shelved|pending-for-task|log-shelved-left)
      [ -n "${WB_CAPTURE_SWEEP:-}" ] && quiet_exit
      case "$verb" in
        shelved)           cmd_list_shelved "${2:-}" "${3:-}" "${4:-}" ;;
        pending-for-task)  cmd_pending_for_task "${2:-}" ;;
        log-shelved-left)  cmd_log_shelved_left "${2:-}" "${3:-}" ;;
      esac
      exit 0 ;;
  esac

  # accept/dismiss/keep: resolve a shelved draft by path, with or without a wb
  # session, so they skip the kill switch / tmux / @task guards (only the recursion
  # flag applies; jq is needed only for the log line, which log_event skips without it).
  case "$verb" in
    dismiss|accept|keep)
      [ -n "${WB_CAPTURE_SWEEP:-}" ] && quiet_exit
      parse_resolve_args "${@:2}"
      if [ "$verb" = dismiss ] && [ -z "$R_PATH" ] && [ -z "$R_TASK" ]; then
        echo "usage: wb-capture.sh dismiss [--task <stem>] <path> (nothing changed)" >&2
        exit 1
      fi
      case "$verb" in
        dismiss) cmd_shelved shelved_dismissed "$R_PATH" ;;
        accept)  cmd_shelved shelved_accepted "$R_PATH" ;;
        keep)    cmd_shelved shelved_kept "$R_PATH" ;;
      esac
      exit 0 ;;
  esac

  guard_chain

  case "$verb" in
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
    hook-prompt|hook-stop)
      read_input
      case "$verb" in
        hook-prompt) hook_prompt ;;
        hook-stop)   hook_stop ;;
      esac
      ;;
    hook-end)
      read_input
      hook_end
      ;;
  esac


  exit 0
fi
