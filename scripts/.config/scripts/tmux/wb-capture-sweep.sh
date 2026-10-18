#!/usr/bin/env bash
# wb-capture-sweep.sh — Haiku background review (U4, store auto-capture).
# Registered as an `async: true` Stop hook, so it launches at the same moment
# as the sync `hook-stop` and races it on the `unchanged` counter (hence the
# flock on <session dir>/.lock and the short sleep before taking it). When the
# task file has gone stale (`unchanged >= sweep_every`) it asks a headless
# Haiku child whether the recent transcript holds an unrecorded decision and,
# if so, writes a per-session `draft` (never the task file — KTD5/R14).
# `sweep_max_failures` (default 3) consecutive error/timeout results stop the
# sweep for the session (skip reason `backoff`); a draft or NONE resets the count.
# The task file is hashed when `## Decisions` is snapshotted; a draft that comes
# back after the file changed (e.g. /wb-decide recorded it meanwhile) is still
# written, plus `draft_stale` = the snapshot's `### ` entry count (see "Stale
# drafts" in wb-capture.sh).
#
# Sources wb-capture.sh as a library (guards, config, state, log) — NOT wb.sh.
# Always exits 0, silent on stdout. Async hooks die with the session; accepted.
set -uo pipefail

# shellcheck source=wb-capture.sh
source "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/wb-capture.sh"

EXCERPT_BUDGET=24000   # bytes of transcript excerpt sent to the child

guard_chain
read_input
SID="$(jq_in '.session_id // empty')"
SDIR="$(session_dir "$SID")" || exit 0
[ -d "$SDIR" ] || exit 0
[ -e "$SDIR/ended" ] && exit 0
TRANSCRIPT="$(jq_in '.transcript_path // empty')"
load_config

# let the sync hook-stop land first; the lock is what guarantees correctness
sleep "${WB_CAPTURE_SWEEP_DELAY:-1}" 2>/dev/null || true

# --- eligibility + counter reset, under the lock ---------------------------
lock_session "$SDIR"
un="$(read_num "$SDIR/unchanged")"
if [ "$un" -lt "$CFG_SWEEP_EVERY" ]; then
  unlock_session
  exit 0                      # nearly every turn: silent
fi
printf '0\n' >"$SDIR/unchanged"
reason=""
if [ "$CFG_SWEEP" = off ]; then reason=disabled
elif [ -e "$SDIR/muted" ]; then reason=muted
elif [ -e "$SDIR/draft" ]; then reason=draft_pending
elif [ "$CFG_SWEEP_MAX_FAILURES" -gt 0 ] && \
     [ "$(read_num "$SDIR/sweep_failures")" -ge "$CFG_SWEEP_MAX_FAILURES" ]; then reason=backoff
fi
unlock_session
if [ -n "$reason" ]; then
  log_event "$SID" sweep_skipped "" "$(jq -nc --arg r "$reason" '{reason:$r}')"
  exit 0
fi
[ -e "$SDIR/ended" ] && exit 0

# --- excerpt: user/assistant text blocks since the last sweep ---------------
[ -n "$TRANSCRIPT" ] && [ -r "$TRANSCRIPT" ] || exit 0
total="$(wc -l <"$TRANSCRIPT" | tr -d ' ')"
off="$(read_num "$SDIR/sweep_offset")"
[ "$total" -lt "$off" ] && off=0
excerpt="$(tail -n +"$((off + 1))" "$TRANSCRIPT" | head -n "$((total - off))" | jq -rR '
  fromjson? | select(type == "object" and (.type == "user" or .type == "assistant"))
  | (if .type == "user" then "USER: " else "ASSISTANT: " end) as $p
  | .message.content
  | (if type == "string" then [{type: "text", text: .}] elif type == "array" then . else [] end)
  | .[] | select(type == "object" and .type == "text" and ((.text // "") != ""))
  | $p + .text + "\n"' 2>/dev/null || true)"
if [ "${#excerpt}" -gt 0 ] && [ "$(printf '%s' "$excerpt" | wc -c)" -gt "$EXCERPT_BUDGET" ]; then
  excerpt="[...earlier turns truncated...]
$(printf '%s' "$excerpt" | tail -c "$EXCERPT_BUDGET")"
fi
if [ -z "$excerpt" ]; then
  printf '%s\n' "$total" >"$SDIR/sweep_offset"
  log_event "$SID" sweep_skipped "" '{"reason":"no_new_content"}'
  exit 0
fi

decisions="" snap_hash="" snap_count=0
[ -f "$TASK_PATH" ] && snap_hash="$(sha1sum <"$TASK_PATH" 2>/dev/null | cut -d' ' -f1)"
[ -n "$TASK_PATH" ] && [ -f "$TASK_PATH" ] && snap_count="$(decision_headings "$TASK_PATH" | wc -l | tr -d ' ')"
[ -n "$TASK_PATH" ] && [ -f "$TASK_PATH" ] && decisions="$(awk '
  /^## Decisions[[:space:]]*$/ { f = 1; print; next }
  /^## / { f = 0 }
  f' "$TASK_PATH" 2>/dev/null || true)"
[ -n "$decisions" ] || decisions="(no ## Decisions section / no entries recorded)"

# --- child ------------------------------------------------------------------
timeout_s="$CFG_SWEEP_TIMEOUT"; [ "$timeout_s" -gt 0 ] || timeout_s="$DEFAULT_SWEEP_TIMEOUT"
mkdir -p "$CAPTURE_ROOT" 2>/dev/null || exit 0
out="$({
  cat <<'PROMPT'
You are reviewing an excerpt of a coding-session transcript against the
Decisions already recorded for the task being worked on.

If a concrete decision was made in the excerpt (an option chosen over an
alternative, or a design/approach settled) that is NOT already recorded in the
Decisions section, reply with a single Decisions entry body and nothing else:
a `### <short title>` line, then 2-4 bullets covering what was decided, the
alternative that was rejected, and why.

Otherwise reply with exactly: NONE

Rules: do not restate entries that are already recorded; do not invent
decisions; routine implementation steps are not decisions; prefer NONE when
unsure. No preamble, no commentary.

=== RECORDED DECISIONS (do not repeat these) ===
PROMPT
  printf '%s\n\n=== TRANSCRIPT EXCERPT ===\n%s\n=== END EXCERPT ===\n' "$decisions" "$excerpt"
} | (cd "$CAPTURE_ROOT" && env -u TMUX -u TMUX_PANE WB_CAPTURE_SWEEP=1 \
      timeout "$timeout_s" "${WB_CAPTURE_CLAUDE:-claude}" -p --model haiku \
      --no-session-persistence --max-turns 1 --tools "" --strict-mcp-config 2>/dev/null))"
rc=$?
out="${out#"${out%%[![:space:]]*}"}"
out="${out%"${out##*[![:space:]]}"}"

result=draft stale=false
if [ "$rc" -eq 124 ]; then result=timeout
elif [ "$rc" -ne 0 ] || [ -z "$out" ]; then result=error
elif [[ "${out,,}" =~ ^none[.!]?$ ]]; then result=none   # models vary: "None.", "NONE"
fi

# the excerpt was consumed unless the child failed (retry that content next time)
case "$result" in none|draft) printf '%s\n' "$total" >"$SDIR/sweep_offset" ;; esac

if [ "$result" = draft ]; then
  if [ -e "$SDIR/ended" ]; then
    log_event "$SID" pending_at_end "" '{"draft":true}'
    exit 0
  fi
  # the task file moved while the child ran: keep the draft, flag it possibly stale
  stale=false
  if [ -n "$snap_hash" ] && \
     [ "$snap_hash" != "$(sha1sum <"$TASK_PATH" 2>/dev/null | cut -d' ' -f1)" ]; then stale=true; fi
  remove_named "$SDIR" draft_stale
  tmp="$SDIR/draft.tmp.$$"; stmp="$SDIR/draft_stale.tmp.$$"
  if [ "$stale" = true ]; then
    printf '%s\n' "$snap_count" >"$stmp" 2>/dev/null && mv -f "$stmp" "$SDIR/draft_stale" 2>/dev/null || stale=false
  fi
  if printf '%s\n' "$out" >"$tmp" 2>/dev/null && mv -f "$tmp" "$SDIR/draft" 2>/dev/null; then :
  else rm -f -- "$tmp" "$stmp" 2>/dev/null; remove_named "$SDIR" draft_stale; stale=false; result=error; fi
fi

# consecutive failures (claude missing / logged out / rate-limited) back the sweep
# off for the rest of the session; any clean run (draft or none) resets the count
case "$result" in
  error|timeout) printf '%s\n' "$(( $(read_num "$SDIR/sweep_failures") + 1 ))" >"$SDIR/sweep_failures" ;;
  *) remove_named "$SDIR" sweep_failures ;;
esac
[ "$result" = draft ] && remove_named "$SDIR" draft_strikes
extra="$(jq -nc --arg r "$result" '{result:$r}')"
[ "$stale" = true ] && extra="$(jq -nc --arg r "$result" '{result:$r,stale:true}')"
log_event "$SID" sweep_ran "" "$extra"
exit 0
