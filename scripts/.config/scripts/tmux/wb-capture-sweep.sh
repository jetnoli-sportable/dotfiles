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
# Staleness is judged on the `## Decisions` section only (the exact text the
# prompt is built from), hashed at snapshot time; edits elsewhere in the task
# file (Handoffs, frontmatter) never count. If a draft comes back and that section
# changed meanwhile (e.g. /wb-decide recorded it), the answer is discarded and the
# child is re-run ONCE against a fresh snapshot (log `rerun:true`). The rerun's
# NONE/error/timeout are handled as usual; a rerun draft is written fresh unless
# the section changed AGAIN, in which case it is written plus `draft_stale` = the
# re-snapshot's `### ` entry count (see "Stale drafts" in wb-capture.sh).
# A draft that arrives after SessionEnd (`ended` exists) is written, logged
# `pending_at_end` {draft:true} and then shelved (reason session_end) like any draft
# a session leaves behind; the rerun is skipped for an ended session.
#
# Overlapping sweeps: if a draft already exists when this sweep's answer arrives
# (another sweep wrote it meanwhile), that older draft is shelved (reason `superseded`)
# before the new one is written, so a draft is never overwritten unseen. But a draft
# the user is looking at (`reviewing`, or its sweep nudge `outstanding`) is left
# untouched, with its review state: the NEW answer goes straight to shelved/ (reason
# `superseded`, a `.stale` sidecar when this run is stale) and the draft is not replaced.
#
# The draft-writing tail (overlap check through draft write / late shelve) holds the
# session lock, the same one `wb-capture.sh dismiss --expect` takes (never held
# across the Haiku child).
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

# the one extraction of `## Decisions`: the prompt is built from it AND the
# staleness hash is taken over it, so the two can never diverge
decisions_section() {
  [ -n "$TASK_PATH" ] && [ -f "$TASK_PATH" ] || return 0
  awk '
    /^## Decisions[[:space:]]*$/ { f = 1; print; next }
    /^## / { f = 0 }
    f' "$TASK_PATH" 2>/dev/null || true
}
# hash_text <text> — the hash compared across the run; section_hash re-reads the file
hash_text() { printf '%s' "$1" | sha1sum 2>/dev/null | cut -d' ' -f1; }
section_hash() { [ -f "$TASK_PATH" ] && hash_text "$(decisions_section)"; }

# snapshot: decisions text + its hash + `### ` entry count
decisions="" snap_hash="" snap_count=0
take_snapshot() {
  snap_hash="" snap_count=0
  decisions="$(decisions_section)"
  # hash the very text the prompt carries (one read), not a second read of the file
  [ -f "$TASK_PATH" ] && snap_hash="$(hash_text "$decisions")"
  [ -n "$TASK_PATH" ] && [ -f "$TASK_PATH" ] && snap_count="$(printf '%s\n' "$decisions" | grep -c '^### ' || true)"
  [ -n "$decisions" ] || decisions="(no ## Decisions section / no entries recorded)"
}

# --- child ------------------------------------------------------------------
timeout_s="$CFG_SWEEP_TIMEOUT"; [ "$timeout_s" -gt 0 ] || timeout_s="$DEFAULT_SWEEP_TIMEOUT"
mkdir -p "$CAPTURE_ROOT" 2>/dev/null || exit 0
# run_child — asks Haiku about $excerpt vs $decisions; sets out, rc, result
run_child() {
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
  result=draft
  if [ "$rc" -eq 124 ]; then result=timeout
  elif [ "$rc" -ne 0 ] || [ -z "$out" ]; then result=error
  else parse_answer
  fi
}

# parse_answer — classifies the trimmed, non-empty $out; sets result and, for a
# draft, trims $out to start at its first `### ` line. Models vary: "None.",
# "NONE", or prose that ends in a bare NONE line. Order matters:
#   1. last non-empty line is NONE (optional . or !)  -> none
#   2. no line starting `### `                        -> error (contract violation;
#      the offset is kept so the excerpt is retried, and it feeds the failure backoff)
#   3. text before the first `### ` line              -> stripped from the draft
parse_answer() {
  local last="${out##*$'\n'}"   # $out is already trimmed: its last line is non-empty
  last="${last#"${last%%[![:space:]]*}"}"
  last="${last%"${last##*[![:space:]]}"}"
  if [[ "${last,,}" =~ ^none[.!]?$ ]]; then result=none; return 0; fi
  if [[ $'\n'"$out" != *$'\n### '* ]]; then result=error; return 0; fi
  [[ "$out" == '### '* ]] || out="### ${out#*$'\n### '}"
  result=draft
}

stale=false rerun=false
take_snapshot
run_child

# a draft whose `## Decisions` changed while the child ran (e.g. /wb-decide
# recorded it meanwhile) may duplicate that entry: discard it and ask once more
# against the current section. Only the draft path reruns, and only once.
if [ "$result" = draft ] && [ ! -e "$SDIR/ended" ] && [ -n "$snap_hash" ] && \
   [ "$snap_hash" != "$(section_hash)" ]; then
  rerun=true
  take_snapshot
  run_child
fi

# an overlapping sweep may have written a draft while this child ran (the
# draft_pending check above came before the call). Never overwrite it unseen.
# If that draft is being shown to the user (`reviewing`, or its sweep nudge is still
# `outstanding`), leave it and its review state completely alone and shelve this NEW
# answer straight away (reason `superseded`): shelving the shown draft would pull it
# out from under the review. Otherwise shelve the older draft first, then write this
# one. If shelving fails the answer is dropped and the content retried (result error).
# The rest (superseded check -> draft write -> late shelve) runs under the session
# lock, so a `dismiss --expect` can't check and remove between this sweep's checks
# and its write. Never held across the child run above; nothing in here re-locks.
lock_session "$SDIR"
moved=false
stale_new=false
[ -n "$snap_hash" ] && [ "$snap_hash" != "$(section_hash)" ] && stale_new=true
protect=false
if [ "$result" = draft ] && [ -e "$SDIR/draft" ]; then
  if [ -e "$SDIR/reviewing" ] || [ "$(cat "$SDIR/outstanding" 2>/dev/null)" = sweep ]; then
    protect=true
    [ -e "$SDIR/ended" ] && log_event "$SID" pending_at_end "" '{"draft":true}'
    if shelve_answer "$SID" superseded "$out" "$stale_new"; then
      moved=true; stale="$stale_new"
    else
      result=error
    fi
  elif ! shelve_draft "$SID" superseded; then
    result=error
  fi
fi

late=false
if [ "$result" = draft ] && [ "$moved" = false ]; then
  # the session ended while Haiku ran: SessionEnd already came and went, so nothing
  # else will nudge this draft. Write it as usual, then shelve it (below) so the
  # user can still accept or dismiss it later instead of losing it
  if [ -e "$SDIR/ended" ]; then
    late=true
    log_event "$SID" pending_at_end "" '{"draft":true}'
  fi
  # still moved during the (re)run: keep the draft, flag it possibly stale
  if [ "$stale_new" = true ]; then stale=true; fi
  remove_named "$SDIR" draft_stale
  tmp="$SDIR/draft.tmp.$$"; stmp="$SDIR/draft_stale.tmp.$$"
  if [ "$stale" = true ]; then
    printf '%s\n' "$snap_count" >"$stmp" 2>/dev/null && mv -f "$stmp" "$SDIR/draft_stale" 2>/dev/null || stale=false
  fi
  if printf '%s\n' "$out" >"$tmp" 2>/dev/null && mv -f "$tmp" "$SDIR/draft" 2>/dev/null; then :
  else rm -f -- "$tmp" "$stmp" 2>/dev/null; remove_named "$SDIR" draft_stale; stale=false; result=error; fi
  # a failed shelve leaves the draft in the session dir for the reaper to shelve
  [ "$late" = true ] && [ "$result" = draft ] && shelve_draft "$SID" session_end
fi
unlock_session

# the excerpt was consumed unless the sweep failed (retry that content next time).
# Written only now, after the superseded shelve and the draft write, so a failure
# in either (result flipped to error) leaves the offset where it was
case "$result" in none|draft) printf '%s\n' "$total" >"$SDIR/sweep_offset" ;; esac

# consecutive failures (claude missing / logged out / rate-limited) back the sweep
# off for the rest of the session; any clean run (draft or none) resets the count
case "$result" in
  error|timeout) printf '%s\n' "$(( $(read_num "$SDIR/sweep_failures") + 1 ))" >"$SDIR/sweep_failures" ;;
  *) remove_named "$SDIR" sweep_failures ;;
esac
# a protected draft keeps its strikes: this run wrote no new draft into the session
[ "$result" = draft ] && [ "$protect" = false ] && remove_named "$SDIR" draft_strikes
extra="$(jq -nc --arg r "$result" --argjson rr "$rerun" --argjson st "$stale" \
  '{result:$r} + (if $rr then {rerun:true} else {} end) + (if $st then {stale:true} else {} end)')"
log_event "$SID" sweep_ran "" "$extra"
exit 0
