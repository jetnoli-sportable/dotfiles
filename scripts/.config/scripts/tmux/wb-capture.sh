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
#                  `recorded`; if `outstanding`, logs `followed` and clears it (and, for
#                  a sweep nudge, draft_strikes; nudged_draft too, so a draft the append
#                  did not record is nudged again at the next prompt) —
#                  unless the one-shot `shelved_accept` flag is set (that append
#                  records a shelved draft; see "Two-phase accept").
#     hook-stop      (Stop) recorded -> clear, no marker; else (not muted,
#                  cooldown 0) phrase-match last_assistant_message -> `marker`
#                  + cooldown. Decrements cooldown; updates taskhash/unchanged
#                  (skipped after a synthetic prompt). A nudge still
#                  `outstanding` at the end of its (real) turn logs `ignored`,
#                  so every nudge resolves exactly once: followed | dismissed |
#                  ignored.
#     hook-prompt    (UserPromptSubmit) stamps @wb_capture_sid; delivers one
#                  nudge line (draft beats marker) as additionalContext, writes
#                  `outstanding`, logs nudge_fired. Synthetic prompts deliver
#                  nothing and set `synthetic`: `<task-notification>` (finished
#                  background sub-agents) and sub-agent hand-backs, which arrive
#                  as `Another Claude session sent a message:` /
#                  `<agent-message ...>` (leading whitespace tolerated).
#     hook-end       (SessionEnd, 1.5s budget: one jq parse, no network, no task
#                  file) if `marker` or `draft` exists logs `pending_at_end`
#                  {marker,draft}; resolves an outstanding nudge as ignored;
#                  shelves a remaining draft (reason session_end); always writes
#                  the `ended` tombstone. Deletes nothing else — the reaper does.
#   clear          agent verb: drop marker, reviewing and the outstanding flag; logs
#                  `followed` if a nudge was still outstanding. It KEEPS an unreviewed
#                  sweep draft (draft, draft_stale, draft_strikes), so the phrase path of
#                  /wb-decide can't delete a draft the user never saw; it drops
#                  nudged_draft, so a kept draft is nudged again at the next real prompt
#                  (and the two-strike shelve restarts) instead of going silent.
#   clear --draft  the draft-accept path: same, and also removes the draft and its
#                  draft_stale / draft_strikes (the draft is what just got recorded).
#   dismiss        same removal, logs `dismissed`. Quiet no-op (nothing logged)
#                  when nothing was pending. When the outstanding nudge is a PHRASE
#                  nudge it removes only marker + outstanding and keeps any sweep
#                  draft (never shown to the user), draft_stale, draft_strikes,
#                  reviewing and nudged_draft; the event is not tagged stale.
#   dismiss --expect none|<sha>
#                  compare-before-delete, bare session dismiss only: refuses (stderr
#                  `draft changed since status; review it first`, exit 1, nothing removed,
#                  nothing logged) if a draft exists and `none` was expected, or its sha1
#                  (`status`'s `draft_sha:` line) differs. No draft, or a matching sha:
#                  dismisses as usual. Check + removal run under the session lock, which
#                  the sweep's draft write also takes. With a <path> or --task: exit 1.
#   dismiss <path> dismiss one SHELVED draft: delete it, log `shelved_dismissed`
#                  (no source). <path> must be a shelved draft of this task, or of
#                  the task named by `--task <stem>` (below).
#   accept --begin <path>
#                  first half of accepting a shelved draft, run BEFORE the `wb
#                  append … Decisions`: same path rule, writes the one-shot
#                  `shelved_accept` flag and nothing else (see "Two-phase accept").
#   accept <path>  second half, after /wb-decide recorded a shelved draft: delete
#                  it, log `shelved_accepted` (no source). It leaves the
#                  `shelved_accept` flag alone: hook-posttool consumes it when the
#                  Bash call holding the append finishes. A path outside the shelved dir exits 1
#                  with a message on stderr. (`followed` and `dismissed` mean only
#                  "a nudge resolved".)
#   accept|dismiss ... --task <stem> ...
#                  resolve a shelved draft of ANOTHER task (typically one already
#                  closed): `dismiss --task <stem> <path>`, `accept --begin --task
#                  <stem> <path>`, `accept --task <stem> <path>`. Path validation uses
#                  shelved/<stem>/ instead of this task's dir, and the logged event's
#                  `task` is <stem>.
#   Every path-carrying accept/dismiss (a <path> or --task; `accept` always) works
#                  WITHOUT a wb session: it ignores the kill switch and the tmux / @task /
#                  capture-session requirements (only WB_CAPTURE_SWEEP still silences it).
#                  The stem comes from --task, else the session's @task, else it exits 1 with
#                  a message (never a silent exit 0). Sessionless, the event is logged with an
#                  empty session_id (no jq: the file is still removed, the log line skipped)
#                  and `accept --begin` writes no flag (the hooks are inert, nothing to
#                  protect). With a session and capture enabled the flag is written and the
#                  session id logged, as always. A bare `dismiss` (no path, no --task) is a
#                  session verb and keeps the guards.
#   mute | unmute  write / remove the per-session `muted` flag; logs each.
#   status         print pending marker/draft (with paths; `draft_sha: <sha1>` after a
#                  present draft), mute state, the
#                  log path, then this task's shelved drafts (one `shelved: <path>`
#                  line each, `(stale)` when marked; `shelved: none`) —
#                  human-readable lines. A stale draft adds a warning line plus
#                  the `### ` headings recorded since its snapshot. Read-only.
#   shelved [--all | --task <stem>]
#                  store verb, read-only, needs no tmux session or @task (honours only
#                  WB_CAPTURE_SWEEP): list shelved drafts, one path per line with a
#                  `(stale)` suffix when marked. `--task` lists one task's; `--all` groups
#                  every task as `<stem>:` then indented paths; bare `shelved` lists the
#                  current session's task (error when it has none).
#   pending-for-task <task-file>
#                  store verb, read-only: every shelved draft for that task's stem AND
#                  every live session draft (<root>/<sid>/draft) whose `taskpath` first
#                  line is that file; one path per line, nothing when none. This is what
#                  `wb done`'s guard asks, so wb.sh never learns the capture layout.
#   log-shelved-left <stem> <count>
#                  store verb: append the `shelved_left` event (session_id empty) that `wb
#                  done --leave-shelved` records. Needs jq, else a silent no-op.
#   review         mark the session's draft as under review (see "Engagement
#                  marker"): creates `reviewing` only if absent, and only when a
#                  draft exists and its sweep nudge is `outstanding`; otherwise a
#                  quiet no-op. Called by /wb-decide's draft-review path only.
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
#                                        sweep_offset draft_strikes
#                                        sweep_failures draft_stale reviewing
#                                        shelved_accept .lock
#                                        draft.tmp.* draft_stale.tmp.*)
#   shelved drafts <root>/shelved/<task-stem>/<YYYYmmddTHHMMSS>-<sid>.md  (per TASK,
#                                        outlives the session dir; a sidecar
#                                        <name>.md.stale marks a stale draft;
#                                        <root>/shelved/_unknown/ when the task
#                                        is not known)
#   event log    <root>/log.jsonl       (one compact JSON line per event:
#                                        ts, session_id, task, event[, source])
#   reaper stamp <root>/.reaped          (mtime = last reap; at most one per hour)
#   log rotation <root>/log.jsonl.1      (previous log; see reaper)
#   kill switch  ${XDG_STATE_HOME:-$HOME/.local/state}/wb/disable-capture
#                (touch it and every verb becomes a silent no-op)
#
# Draft strikes: a draft nudge (source sweep) that resolves `ignored` gets one more
# chance — `nudged_draft` is dropped so the same draft is nudged again on the next
# real prompt, and `draft_strikes` records 1. A second ignore SHELVES the draft: it
# moves to <root>/shelved/<task-stem>/ and logs `draft_shelved` {"reason":
# "ignored_twice"}; draft, nudged_draft, draft_strikes, draft_stale and reviewing
# are removed from the session dir, which lets the sweep run again. A draft is
# never deleted without the user's explicit accept or dismiss. SessionEnd
# shelves a remaining draft (reason session_end) and the reaper shelves one it finds
# in a dir it is about to remove (reason reaped). The strike count is dropped
# whenever the draft goes away another way (followed, dismiss, clear --draft) or the sweep
# writes a new draft. Phrase-nudge ignores don't strike and shelve nothing (no data);
# SessionEnd resolves an outstanding nudge as ignored without striking.
# Engagement marker: `review` creates `reviewing` while a sweep draft nudge is
# outstanding, meaning the user is mid-review over several messages. It never
# truncates an existing file: `reviewing` holds the carried-Stop counter, and a
# repeated `review` must not reset it. Only /wb-decide's draft-review path calls
# it (`status` is read-only, so a bare status check or a close-out sweep can't
# put an unrelated session under review). While it exists the Stop hook and the next prompt keep `outstanding` (carry it to the next
# turn) instead of resolving it ignored, and no new nudge fires, so the review
# resolves exactly once: followed (posttool) or dismissed (dismiss/clear). After
# REVIEW_MAX_TURNS carried Stops the review counts as abandoned: the next Stop
# resolves it ignored and strikes as usual. SessionEnd and the reaper still
# resolve it ignored, then shelve the draft (a draft the reaper can't shelve keeps
# its dir until a later reap succeeds).
# Two-phase accept: accepting a shelved draft runs a `wb append … Decisions`, which
# hook-posttool would count as the answer to whatever nudge is live in the session
# (a different, unrelated one). So /wb-decide runs `accept --begin <path>` immediately
# before the append (after any user confirmation), which writes `shelved_accept`;
# hook-posttool, once the Bash call holding the matching append finishes, consumes
# that flag, sets `recorded`, and otherwise leaves `outstanding`, `draft_strikes` and
# `reviewing` alone. `accept <path>` then deletes the draft and logs `shelved_accepted`.
# It deliberately does NOT drop the flag: PostToolUse runs after the WHOLE Bash call, so
# `accept --begin p; wb append …; accept p` in one command would otherwise lose the flag
# before the hook saw the append and log a spurious `followed`. The flag is one-shot and
# turn-scoped: only the hook, a real prompt, `dismiss <path>` and the reaper drop it, so
# an abandoned accept can't swallow a later append.
# Stale drafts: the sweep snapshots `## Decisions` (the text Haiku sees), then
# waits up to a minute for Haiku. If that section changed meanwhile (typically
# /wb-decide recording the very decision being drafted) the answer is discarded
# and the child reruns once on a fresh snapshot. Only if the section changes a
# second time during the rerun is the draft written — the user decides — plus
# `draft_stale`, holding how many `### ` entries `## Decisions` had at the
# re-snapshot. The draft nudge and `status` then warn it may already be recorded
# (status lists the entries added since). Staleness is not carried in
# `outstanding`: a nudge, once resolved, is tagged `"stale":true` in its
# followed | dismissed | ignored | draft_shelved event whenever its source is
# `sweep` and `draft_stale` exists (it lives exactly as long as `draft`, so it is
# still there at every resolution). Phrase nudges are never tagged.
# `sweep_failures` (written by wb-capture-sweep.sh) counts consecutive failed
# sweeps; at sweep_max_failures the sweep skips with reason `backoff`.
#
# Reaper (reap_stale, run by hook-prompt AFTER its nudge output is emitted, so it
# can't delay or alter it; at most once per hour, throttled by the mtime of
# <root>/.reaped, which is touched before the work starts). For each real,
# non-symlink subdir of the root whose name passes session_dir validation and
# that isn't the current session (and isn't `shelved`): remove it if it holds `ended`
# and that file is older than a grace period of 2 x sweep_timeout + 60 seconds (the
# timeout is the sweep's effective one: sweep_timeout=0 means the default 60, so 180s; an
# async sweep may still be running its Haiku child and shelve a late draft; if the age
# can't be computed the dir waits for the next reap), or if nothing in
# it was modified in the last 7 days (find -newermt on the dir + its files).
# A stale, un-ended dir still holding marker/draft logs `pending_orphaned`, once the
# dir is really going: an outstanding nudge is logged `ignored` and removed first, a
# draft is shelved (reason reaped), and only then is `pending_orphaned` logged. A dir
# kept because shelving failed logs neither again on the retry.
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
#   sweep_max_failures  integer, consecutive failed sweeps before the sweep
#                  backs off for the session; 0 = never back off (default 3)
# A non-integer / non-on|off value falls back to the default.
#
# Guards (R5), checked in order before any state is touched: WB_CAPTURE_SWEEP
# set (recursion flag for the headless sweep child), kill switch, not in tmux,
# no @task on the tmux session, jq missing. Every one exits 0 silently. Exception:
# a path-carrying accept/dismiss (see above) applies only the recursion flag.
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
DEFAULT_SWEEP_MAX_FAILURES=3
# Stops a draft review may carry its nudge before it counts as abandoned
REVIEW_MAX_TURNS=4

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

# strip_heredocs — stdin -> stdout with heredoc bodies and terminators dropped
# (the line holding the `<<WORD` operator stays). Handles <<WORD, <<'WORD',
# <<"WORD", <<\WORD and the <<- forms (tab-stripped terminator); `<<<` here-strings
# aren't heredocs. An unterminated heredoc drops the rest, as the shell reads it.
strip_heredocs() {
  local line term="" dash=0 q="'\"" re
  re='(^|[^<])<<(-?)[[:space:]]*\\?['"$q"']?([A-Za-z_][A-Za-z0-9_]*)'
  while IFS= read -r line || [ -n "$line" ]; do
    if [ -n "$term" ]; then
      [ "$dash" = 1 ] && line="${line#"${line%%[!$'\t']*}"}"
      [ "$line" = "$term" ] && term=""
      continue
    fi
    printf '%s\n' "$line"
    if [[ "$line" =~ $re ]]; then
      term="${BASH_REMATCH[3]}"; dash=0
      [ -n "${BASH_REMATCH[2]}" ] && dash=1
    fi
  done
}

# hook_posttool — a `wb append … Decisions` Bash command marks the turn recorded.
hook_posttool() {
  # cheap pre-filter on the raw JSON, before any jq
  case "$INPUT" in *wb*) ;; *) return 0 ;; esac
  case "$INPUT" in *append*) ;; *) return 0 ;; esac
  case "$INPUT" in *Decisions*) ;; *) return 0 ;; esac
  local cmd re
  cmd="$(jq_in '.tool_input.command // empty')"
  # a newline separates commands too (multi-line Bash calls, as /wb-decide makes),
  # and must stop the match from running on into a heredoc body
  cmd="$(strip_heredocs <<<"$cmd")"
  cmd="${cmd//$'\n'/;}"
  local q="'\""
  re='(^|[;&|(]|\$\()[[:space:]]*([A-Za-z_][A-Za-z0-9_]*=[^[:space:]]*[[:space:]]+)*([^[:space:];&|]*/)?wb[[:space:]]+append[[:space:]]([^;&|]*[[:space:]'"$q"'])?Decisions([[:space:]'"$q"']|$)'
  [[ "$cmd" =~ $re ]] || return 0
  hook_session_dir
  mkdir -p "$SDIR" 2>/dev/null || return 0
  : >"$SDIR/recorded"
  # the append that records a shelved draft (accept --begin ran first) answers no
  # live nudge: consume the flag and leave the nudge/review state as it was
  if [ -e "$SDIR/shelved_accept" ]; then
    remove_named "$SDIR" shelved_accept
    return 0
  fi
  if [ -e "$SDIR/outstanding" ]; then
    local osrc; osrc="$(cat "$SDIR/outstanding" 2>/dev/null)"
    log_event "$SID" followed "$osrc" "$(stale_extra "$osrc")"
    remove_named "$SDIR" outstanding
    [ "$osrc" = sweep ] && remove_named "$SDIR" draft_strikes
    # a draft that outlives the append (it was not what got recorded) must be nudged
    # again at the next prompt, as plain `clear` does, not sit silent until SessionEnd
    remove_named "$SDIR" nudged_draft
  fi
  remove_named "$SDIR" reviewing
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
  # the agent had this turn to act on the nudge delivered at its prompt; a turn
  # that ends with neither a Decisions append (followed) nor a dismiss resolves
  # it as ignored, so a later unrelated append can't be counted as followed.
  # A synthetic turn isn't the agent's real turn yet.
  # A review in progress (`reviewing`, set by `review`) carries the nudge instead,
  # for at most REVIEW_MAX_TURNS Stops: an abandoned review would otherwise hold
  # the nudge (and block phrase nudges and the sweep) for the rest of the session.
  if [ -e "$SDIR/outstanding" ] && [ ! -e "$SDIR/synthetic" ]; then
    local rv
    rv="$(read_num "$SDIR/reviewing")"
    if [ -e "$SDIR/reviewing" ] && [ "$rv" -lt "$REVIEW_MAX_TURNS" ]; then
      printf '%s\n' "$((rv + 1))" >"$SDIR/reviewing"
    else
      remove_named "$SDIR" reviewing
      resolve_ignored
    fi
  fi
  remove_named "$SDIR" synthetic
}

# stale_extra <source> [json] — print the extra-json for a nudge-resolution event:
# json (default {}) plus "stale":true when the nudge was a sweep draft nudge and
# draft_stale exists in SDIR. Otherwise json unchanged (empty = no extra).
stale_extra() {
  if [ "$1" = sweep ] && [ -e "$SDIR/draft_stale" ]; then
    local base="${2:-}"; [ -n "$base" ] || base='{}'
    printf '%s' "$base" | jq -c '. + {stale:true}' 2>/dev/null || printf '%s' "${2:-}"
  else
    printf '%s' "${2:-}"
  fi
}

# decision_headings <file> — the `### ` lines under `## Decisions`, in order.
decision_headings() {
  awk '/^## Decisions[[:space:]]*$/ { f = 1; next } /^## / { f = 0 } f && /^### /' "$1" 2>/dev/null
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

# shelve_draft <sid> <reason> — move SDIR's draft to the per-task shelved dir
# (verbatim, <YYYYmmddTHHMMSS>-<sid>.md; a `.stale` sidecar when draft_stale
# exists), log `draft_shelved`, then drop the draft's session state. TASK_STEM
# empty -> shelved/_unknown. If the move fails nothing is removed (never lose it).
shelve_draft() {
  local sid="$1" reason="$2" dest
  [ -f "$SDIR/draft" ] || return 0
  dest="$(shelved_dest "$sid")" || return 1
  mv -- "$SDIR/draft" "$dest" 2>/dev/null || return 1
  [ -e "$SDIR/draft_stale" ] && : >"$dest.stale" 2>/dev/null
  log_event "$sid" draft_shelved "" "$(stale_extra sweep "{\"reason\":\"$reason\"}")"
  remove_named "$SDIR" draft nudged_draft draft_strikes draft_stale reviewing
}

# shelve_answer <sid> <reason> <text> <stale: true|false> — shelve a NEW sweep answer
# (text) that never became SDIR's draft: write it to the shelved dir (atomically, so a
# half-written file is never listed), a `.stale` sidecar when <stale> is true, log
# `draft_shelved` (+ stale:true). Touches no session state: the draft already in SDIR,
# and its nudge/review state, stay exactly as they were. Fails 1 with nothing left behind.
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

# resolve_ignored [nostrike] — log the outstanding nudge as ignored and clear it.
# An ignored draft nudge strikes the draft (see "Draft strikes" in the header);
# `nostrike` (SessionEnd) leaves the draft's state alone.
resolve_ignored() {
  local src; src="$(cat "$SDIR/outstanding" 2>/dev/null)"
  log_event "$SID" ignored "$src" "$(stale_extra "$src")"
  remove_named "$SDIR" outstanding
  if [ "$src" = sweep ] && [ "${1:-}" != nostrike ] && [ -f "$SDIR/draft" ]; then
    if [ "$(read_num "$SDIR/draft_strikes")" -ge 1 ]; then
      shelve_draft "$SID" ignored_twice
    else
      # first ignore: drop the nudged-hash so the same draft is nudged once more
      remove_named "$SDIR" nudged_draft
      printf '1\n' >"$SDIR/draft_strikes"
    fi
  fi
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
  # synthetic turns: background-agent notifications and sub-agent hand-backs
  # (leading whitespace/newlines are not part of the prefix test)
  local p_trim="${prompt#"${prompt%%[![:space:]]*}"}"
  case "$p_trim" in
    '<task-notification>'*|'Another Claude session sent a message:'*|'<agent-message'*)
      : >"$SDIR/synthetic"; return 0 ;;
  esac
  # a real prompt starts a new turn: a `recorded` left by a turn that never
  # reached Stop (interrupted) must not suppress this turn's marker
  remove_named "$SDIR" synthetic recorded shelved_accept
  # likewise a nudge from a turn that never reached Stop
  # (unless the user is mid-review: that nudge carries on, and nothing new fires)
  if [ -e "$SDIR/reviewing" ] && [ -e "$SDIR/outstanding" ]; then
    remove_named "$SDIR" marker
    return 0
  fi
  [ -e "$SDIR/outstanding" ] && resolve_ignored
  local line="" source="" dh="" phrase
  if [ -f "$SDIR/draft" ]; then
    dh="$(sha1sum <"$SDIR/draft" 2>/dev/null | cut -d' ' -f1)"
    if [ -n "$dh" ] && [ "$dh" != "$(cat "$SDIR/nudged_draft" 2>/dev/null || true)" ]; then
      line="[wb-capture] A background review drafted an unrecorded decision ($SDIR/draft). Run /wb-decide to review/accept, or /wb-decide dismiss. If you carry on with something else first, tell the user in one line that a decision draft is waiting."
      [ -e "$SDIR/draft_stale" ] && line="[wb-capture] A background review drafted a decision ($SDIR/draft), but the task file changed while it was being written, so it may already be recorded. Run /wb-decide: compare the draft with the newest Decisions entries before accepting, or /wb-decide dismiss. If you carry on with something else first, tell the user in one line that a decision draft is waiting."
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
  remove_named "$SDIR" marker
  [ -n "$line" ] || return 0
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
  # a nudge whose turn never reached Stop gets no later prompt to resolve it
  [ -e "$SDIR/outstanding" ] && resolve_ignored nostrike
  # a draft never dies with the session: shelve it for the user's later accept/dismiss
  [ -e "$SDIR/draft" ] && shelve_draft "$SID" session_end
  : >"$SDIR/ended" 2>/dev/null || true
}

# reap_dir <dir> — remove a validated session dir by explicit names, then rmdir.
reap_dir() {
  local d="$1" f
  remove_named "$d" marker recorded cooldown taskhash unchanged draft muted \
    outstanding ended synthetic nudged_draft taskpath sweep_offset draft_strikes \
    sweep_failures draft_stale reviewing shelved_accept .lock
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
  local d name sdir stale pm pd osrc orphan saved_stem="$TASK_STEM" tp SDIR  # SDIR: stale_extra reads it
  for d in "$root"/*/; do
    d="${d%/}"; name="${d##*/}"
    [ -d "$d" ] && [ ! -L "$d" ] || continue
    sdir="$(session_dir "$name")" || continue
    [ "$name" != "${SID:-}" ] && [ "$name" != shelved ] || continue
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
    orphan=""
    if [ "$stale" = 1 ] && { [ -e "$sdir/marker" ] || [ -e "$sdir/draft" ]; }; then
      pm=false; pd=false
      [ -e "$sdir/marker" ] && pm=true
      [ -e "$sdir/draft" ] && pd=true
      orphan="{\"marker\":$pm,\"draft\":$pd}"
    fi
    # an unresolved nudge is ignored, not silently dropped with the dir; removing
    # `outstanding` here resolves it once even if the dir is kept and reaped again
    if [ -e "$sdir/outstanding" ]; then
      SDIR="$sdir"
      osrc="$(cat "$sdir/outstanding" 2>/dev/null)"
      log_event "$name" ignored "$osrc" "$(stale_extra "$osrc")"
      remove_named "$sdir" outstanding
    fi
    SDIR="$sdir"
    # a draft that can't be shelved keeps its dir: retried on the next reap
    if [ -e "$sdir/draft" ] && ! shelve_draft "$name" reaped; then
      TASK_STEM="$saved_stem"; exec 8>&-; continue
    fi
    # logged only once the dir is really going (a kept dir would log it every retry)
    [ -z "$orphan" ] || log_event "$name" pending_orphaned "" "$orphan"
    TASK_STEM="$saved_stem"
    reap_dir "$sdir"
    exec 8>&-
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
  CFG_SWEEP_MAX_FAILURES="$DEFAULT_SWEEP_MAX_FAILURES"
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
      sweep_max_failures) [[ "$val" =~ ^[0-9]+$ ]] && CFG_SWEEP_MAX_FAILURES="$val" ;;
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

# draft_sha — sha1 of $SDIR/draft, empty when there is no draft or no sha1sum.
draft_sha() { sha1sum <"$SDIR/draft" 2>/dev/null | cut -d' ' -f1; }

cmd_clear_or_dismiss() { # <log-event|""> [--draft|""] [expect: none|<sha>]
  local drop_draft=0 expect="${3:-}" locked=0
  [ "${2:-}" = --draft ] && drop_draft=1
  agent_session_dir
  # compare-before-delete: `dismiss --expect none|<sha>` refuses (nothing removed,
  # nothing logged) when the draft present is not the one the caller saw. The check and
  # the removal run under the session lock, which the sweep's draft write also takes,
  # so a draft can't land between the two.
  if [ -n "$expect" ]; then
    lock_session "$SDIR"; locked=1
    if [ -e "$SDIR/draft" ]; then
      local cur=""; [ "$expect" = none ] || cur="$(draft_sha)"
      if [ "$expect" = none ] || [ -z "$cur" ] || [ "$cur" != "$expect" ]; then
        unlock_session
        echo "wb-capture: draft changed since status; review it first (nothing changed)" >&2
        exit 1
      fi
    fi
  fi
  local pending=0 f
  for f in marker draft outstanding; do [ -e "$SDIR/$f" ] && pending=1; done
  # clear runs only after /wb-decide's write; if hook-posttool missed that
  # command, the nudge still resolves (as followed) instead of vanishing
  if [ -z "$1" ] && [ -e "$SDIR/outstanding" ]; then
    local osrc; osrc="$(cat "$SDIR/outstanding" 2>/dev/null)"
    log_event "$SID" followed "$osrc" "$(stale_extra "$osrc")"
  fi
  # a dismiss of a stale draft is tagged unless the pending nudge was a phrase one
  local dsrc=sweep dx
  [ -e "$SDIR/outstanding" ] && dsrc="$(cat "$SDIR/outstanding" 2>/dev/null)"
  dx="$(stale_extra "$dsrc")"
  if [ "$1" = dismissed ] && [ "$dsrc" = phrase ]; then
    # a phrase nudge never showed the sweep draft: dismissing it leaves the draft alone
    remove_named "$SDIR" marker outstanding
  elif [ -z "$1" ] && [ "$drop_draft" = 0 ]; then
    # plain clear (the phrase/hinted path): the draft was not what got recorded and
    # may be unseen, so it stays pending (never deleted without accept or dismiss).
    # nudged_draft goes too: a kept draft whose nudge just resolved must be nudged
    # again, or it would sit silent until SessionEnd shelves it
    remove_named "$SDIR" marker outstanding reviewing nudged_draft
  else
    remove_named "$SDIR" marker draft draft_strikes draft_stale outstanding reviewing
  fi
  if [ "$1" = dismissed ] && [ "$pending" = 1 ]; then log_event "$SID" dismissed "" "$dx"; fi
  [ "$locked" = 1 ] && unlock_session
}

cmd_status() {
  agent_session_dir
  local f
  for f in marker draft; do
    if [ -e "$SDIR/$f" ]; then echo "$f: present ($SDIR/$f)"; else echo "$f: none"; fi
  done
  # the draft's sha1, for `dismiss --expect <sha>` (compare-before-delete)
  if [ -e "$SDIR/draft" ]; then
    local dsha; dsha="$(draft_sha)"
    [ -n "$dsha" ] && echo "draft_sha: $dsha"
  fi
  if [ -e "$SDIR/draft_stale" ] && [ -e "$SDIR/draft" ]; then
    echo "draft: the task file changed while it was being written, so it may already be recorded"
    local tp="${TASK_PATH:-}" cnt; cnt="$(read_num "$SDIR/draft_stale")"
    [ -f "$tp" ] || tp="$(head -n1 "$SDIR/taskpath" 2>/dev/null || true)"
    if [ -f "$tp" ]; then
      echo "decisions added since the draft was started:"
      decision_headings "$tp" | tail -n +"$((cnt + 1))"
    fi
  fi
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

# cmd_review — mark the pending sweep draft as under review (see "Engagement
# marker"). Only when a draft exists and its sweep nudge is outstanding (phrase
# nudges don't count); never truncates an existing marker (it holds the counter).
cmd_review() {
  agent_session_dir
  [ -e "$SDIR/reviewing" ] && return 0
  if [ -e "$SDIR/draft" ] && [ "$(cat "$SDIR/outstanding" 2>/dev/null)" = sweep ]; then
    : >"$SDIR/reviewing" 2>/dev/null || true
  fi
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

# resolve_shelved_context — context for a path-carrying accept/dismiss, which works
# with or without a wb session (see "accept|dismiss ... --task" in the header). Sets
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

# cmd_shelved <shelved_accepted|shelved_dismissed> <path> — resolve one shelved
# draft: delete it (and its .stale sidecar), log the event (+ stale:true when
# marked; session_id empty when sessionless). A dismiss drops a leftover
# `shelved_accept` flag; an accept leaves it for hook-posttool to consume (see
# "Two-phase accept"). Path rule: shelved_draft_path.
cmd_shelved() {
  resolve_shelved_context
  local ev="$1" p="${2:-}" x=""
  shelved_draft_path "$p"
  [ -e "$p.stale" ] && x='{"stale":true}'
  rm -f -- "$p" "$p.stale" 2>/dev/null || true
  [ "$ev" = shelved_dismissed ] && [ -n "$SDIR" ] && remove_named "$SDIR" shelved_accept
  log_event "$SID" "$ev" "" "$x"
}

# cmd_accept_begin <path> — first phase of accepting a shelved draft (see "Two-phase
# accept"): validate the path, then write the one-shot `shelved_accept` flag (only
# when a session is available: with none, the hooks are inert and there is nothing
# for the flag to protect).
cmd_accept_begin() {
  resolve_shelved_context
  shelved_draft_path "${1:-}"
  [ -n "$SDIR" ] && mkdir -p "$SDIR" 2>/dev/null && : >"$SDIR/shelved_accept"
  return 0
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

# list_shelved_for <stem> <indent> — shelved_paths with the `(stale)` suffix.
list_shelved_for() {
  local pf
  while IFS= read -r pf; do
    [ -n "$pf" ] || continue
    if [ -e "$pf.stale" ]; then printf '%s%s (stale)\n' "$2" "$pf"; else printf '%s%s\n' "$2" "$pf"; fi
  done < <(shelved_paths "$1")
}

# cmd_list_shelved [--all | --task <stem>] — see "shelved" in the header. Read-only.
cmd_list_shelved() {
  local d stem out
  case "${1:-}" in
    --all)
      for d in "$CAPTURE_ROOT"/shelved/*/; do
        d="${d%/}"; stem="${d##*/}"
        [ -d "$d" ] && [ ! -L "$d" ] && stem_ok "$stem" || continue
        out="$(list_shelved_for "$stem" '  ')"
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
    *) echo "usage: wb-capture.sh shelved [--all | --task <stem>]" >&2; exit 1 ;;
  esac
}

# cmd_pending_for_task <task-file> — see "pending-for-task" in the header.
cmd_pending_for_task() {
  local tf="${1:-}" stem d name tp
  [ -n "$tf" ] || { echo "usage: wb-capture.sh pending-for-task <task-file>" >&2; exit 1; }
  stem="${tf##*/}"; stem="${stem%.md}"
  stem_ok "$stem" || exit 0
  shelved_paths "$stem"
  for d in "$CAPTURE_ROOT"/*/; do
    d="${d%/}"; name="${d##*/}"
    [ "$name" != shelved ] && session_dir "$name" >/dev/null || continue
    [ -d "$d" ] && [ ! -L "$d" ] && [ -f "$d/draft" ] || continue
    tp="$(head -n1 "$d/taskpath" 2>/dev/null || true)"
    [ -n "$tp" ] || continue
    if [ "$tp" = "$tf" ] || { [ -e "$tp" ] && [ -e "$tf" ] && [ "$(readlink -f "$tp")" = "$(readlink -f "$tf")" ]; }; then
      printf '%s\n' "$d/draft"
    fi
  done
  return 0
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

# parse_resolve_args <args...> — accept/dismiss operands: [--begin] [--task <stem>] [--expect <none|sha>] [<path>].
# Sets R_BEGIN (0|1), R_TASK, R_PATH, R_EXPECT/R_HAS_EXPECT (the value is consumed, never a path). A bad --task exits 1.
parse_resolve_args() {
  R_BEGIN=0 R_TASK="" R_PATH="" R_EXPECT="" R_HAS_EXPECT=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --begin) R_BEGIN=1; shift ;;
      --expect)
        [ $# -ge 2 ] && [ -n "$2" ] || { echo "wb-capture: --expect needs 'none' or a draft sha1 (nothing changed)" >&2; exit 1; }
        R_EXPECT="$2"; R_HAS_EXPECT=1; shift 2 ;;
      --task)
        stem_ok "${2:-}" || { echo "wb-capture: --task needs a task stem (nothing changed)" >&2; exit 1; }
        R_TASK="$2"; shift 2 ;;
      *) R_PATH="$1"; shift ;;
    esac
  done
}

cmd_config() {
  load_config
  printf 'phrases=%s\ncooldown=%s\nsweep_every=%s\nsweep=%s\nsweep_timeout=%s\nsweep_max_failures=%s\n' \
    "$CFG_PHRASES" "$CFG_COOLDOWN" "$CFG_SWEEP_EVERY" "$CFG_SWEEP" "$CFG_SWEEP_TIMEOUT" \
    "$CFG_SWEEP_MAX_FAILURES"
}

# Source-able as a library (wb-capture-sweep.sh): dispatch only when executed.
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  verb="${1:-}"
  case "$verb" in
    clear|dismiss|accept|review|mute|unmute|status|_config|hook-prompt|hook-posttool|hook-stop|hook-end) ;;
    shelved|pending-for-task|log-shelved-left) ;;
    *) exit 0 ;;
  esac

  # store verbs: take their task explicitly, so no tmux / @task guard (only the
  # recursion flag applies)
  case "$verb" in
    shelved|pending-for-task|log-shelved-left)
      [ -n "${WB_CAPTURE_SWEEP:-}" ] && quiet_exit
      case "$verb" in
        shelved)           cmd_list_shelved "${2:-}" "${3:-}" ;;
        pending-for-task)  cmd_pending_for_task "${2:-}" ;;
        log-shelved-left)  cmd_log_shelved_left "${2:-}" "${3:-}" ;;
      esac
      exit 0 ;;
  esac

  # path-carrying accept/dismiss: resolve a shelved draft by path, with or without a
  # wb session, so they skip the kill switch / tmux / @task guards (only the
  # recursion flag applies; jq is needed only for the log line, which log_event skips
  # without it). A bare `dismiss` still goes through the guard chain below.
  case "$verb" in
    dismiss|accept)
      parse_resolve_args "${@:2}"
      if [ "$verb" = accept ] || [ -n "$R_PATH" ] || [ -n "$R_TASK" ]; then
        [ "$R_HAS_EXPECT" = 1 ] && { echo "wb-capture: --expect only goes with a bare session dismiss, not accept, <path> or --task (nothing changed)" >&2; exit 1; }
        [ -n "${WB_CAPTURE_SWEEP:-}" ] && quiet_exit
        if [ "$verb" = dismiss ]; then cmd_shelved shelved_dismissed "$R_PATH"
        elif [ "$R_BEGIN" = 1 ]; then cmd_accept_begin "$R_PATH"
        else cmd_shelved shelved_accepted "$R_PATH"
        fi
        exit 0
      fi ;;
  esac

  guard_chain

  case "$verb" in
    clear)   cmd_clear_or_dismiss "" "${2:-}" ;;
    dismiss) cmd_clear_or_dismiss dismissed "" "$R_EXPECT" ;;
    mute)
      agent_session_dir
      mkdir -p "$SDIR" 2>/dev/null && : >"$SDIR/muted" && log_event "$SID" muted
      ;;
    unmute)
      agent_session_dir
      remove_named "$SDIR" muted
      log_event "$SID" unmuted
      ;;
    review)  cmd_review ;;
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
