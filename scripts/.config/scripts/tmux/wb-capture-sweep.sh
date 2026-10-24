#!/usr/bin/env bash
# wb-capture-sweep.sh — background model review (U4, store auto-capture).
# Two entry points, one script:
#
# Async (default): registered as an `async: true` Stop hook, so it launches at the
# same moment as the sync `hook-stop` and races it on the `unchanged` counter
# (hence the flock on <session dir>/.lock and the short sleep before taking it).
# When the task file has gone stale (`unchanged >= sweep_every`) it asks a headless
# child (`sweep_model` at `sweep_effort`, default sonnet/medium) whether the recent
# transcript holds an unrecorded decision. Session id and transcript come from the
# Stop payload on stdin.
#
# Forced (`--forced <session id> [<task path> [<transcript>]]`): the checkpoint
# sweep, run by `wb-capture.sh sweep` (from /wb-save and /close-out) with stdin from
# /dev/null. The task and transcript default to the session dir's `taskpath` and
# `transcript` files (persisted by hook-stop/hook-prompt, KTD5). It never reads stdin,
# skips the quiet-turn gate, the failure backoff and the startup sleep, and still
# honours the kill switch, WB_CAPTURE_SWEEP, `sweep=off` and `muted`. It prints exactly
# one result line on stdout (the async hook prints nothing): `drafted N`, `none`,
# `nothing new` (nothing written to the transcript since `sweep_offset`: no model
# call), `skipped: <off|muted|no session|no transcript|no jq>` or
# `failed: <timeout|error|invalid>`. Always exits 0.
#
# Drafts go straight to the SHELF, never to a per-session slot and never to the task
# file (KTD5/R14): the answer is split on its `### ` entries (up to MAX_ENTRIES) and
# each entry is shelved as its own file under <root>/shelved/<task-stem>/, logging
# `draft_shelved` {reason:sweep, draft:<file>} per file. The prompt names the task's
# shelved drafts ("already drafted, awaiting review") and the ones dismissed in the
# last 14 days ("already reviewed and rejected"), so a later turn that recaps a
# decision doesn't draft it twice (R6). Accepted drafts are not listed: the model
# already sees them in `## Decisions`.
# `sweep_max_failures` (default 3) consecutive error/timeout results stop the async
# sweep for the session (skip reason `backoff`); a draft or NONE resets the count.
# Staleness is judged on the `## Decisions` section only (the exact text the
# prompt is built from), hashed at snapshot time; edits elsewhere in the task
# file (Handoffs, frontmatter) never count. If a draft comes back and that section
# changed meanwhile (e.g. /wb-decide recorded it), the answer is discarded and the
# child is re-run ONCE against a fresh snapshot (log `rerun:true`). The rerun's
# NONE/error/timeout are handled as usual; a rerun draft is shelved fresh unless
# the section changed AGAIN, in which case each file also gets a `.stale` sidecar
# holding the re-snapshot's `### ` entry count (see "Stale drafts" in wb-capture.sh).
# A session that ended while the child ran still gets its draft shelved (the shelf
# outlives the session); the rerun is skipped for an ended session.
#
# Sources wb-capture.sh as a library (guards, config, state, log) — NOT wb.sh.
# Always exits 0. The async hook is silent on stdout and dies with the session; accepted.
set -uo pipefail

# shellcheck source=wb-capture.sh
source "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/wb-capture.sh"

EXCERPT_BUDGET=24000   # bytes of transcript excerpt sent to the child
MAX_ENTRIES=3          # `### ` entries one sweep may draft (the prompt asks for the same)

# finish <line> — forced mode prints its one result line, then exit 0; the async
# hook stays silent. Every early exit below goes through here.
FORCED=0
if [ "${1:-}" = --forced ]; then FORCED=1; F_SID="${2:-}"; F_TASK="${3:-}"; F_TRANSCRIPT="${4:-}"; fi
finish() { [ "$FORCED" = 1 ] && printf '%s\n' "$1"; exit 0; }

if [ "$FORCED" = 1 ]; then
  # the verb already ran its own guards; the kill switch and recursion flag are
  # re-checked here so the script is safe to run on its own. Stdin is never read.
  if [ -n "${WB_CAPTURE_SWEEP:-}" ] || [ -e "$KILL_SWITCH" ]; then finish "skipped: off"; fi
  command -v jq >/dev/null 2>&1 || finish "skipped: no jq"
  SID="$F_SID"
  SDIR="$(session_dir "$SID")" || finish "skipped: no session"
  [ -d "$SDIR" ] || finish "skipped: no session"
  TASK_PATH="${F_TASK:-$(head -n1 "$SDIR/taskpath" 2>/dev/null || true)}"
  [ -n "$TASK_PATH" ] || finish "skipped: no session"
  TASK_STEM="${TASK_PATH##*/}"; TASK_STEM="${TASK_STEM%.md}"
  TRANSCRIPT="${F_TRANSCRIPT:-$(head -n1 "$SDIR/transcript" 2>/dev/null || true)}"
  load_config
else
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

  # --- eligibility + counter reset, under the lock -------------------------
  lock_session "$SDIR"
  un="$(read_num "$SDIR/unchanged")"
  if [ "$un" -lt "$CFG_SWEEP_EVERY" ]; then
    unlock_session
    exit 0                      # nearly every turn: silent
  fi
  printf '0\n' >"$SDIR/unchanged"
  unlock_session
fi

reason=""
if [ "$CFG_SWEEP" = off ]; then reason=disabled
elif [ -e "$SDIR/muted" ]; then reason=muted
elif [ "$FORCED" = 0 ] && [ "$CFG_SWEEP_MAX_FAILURES" -gt 0 ] && \
     [ "$(read_num "$SDIR/sweep_failures")" -ge "$CFG_SWEEP_MAX_FAILURES" ]; then reason=backoff
fi
if [ -n "$reason" ]; then
  log_event "$SID" sweep_skipped "" "$(jq -nc --arg r "$reason" '{reason:$r}')"
  [ "$reason" = disabled ] && finish "skipped: off"
  finish "skipped: $reason"
fi
[ "$FORCED" = 0 ] && [ -e "$SDIR/ended" ] && exit 0

# --- excerpt: user/assistant text blocks since the last sweep ---------------
# Harness-injected user messages are skipped: `isMeta` ones (an invoked skill's whole
# SKILL.md, 14-15 KB, which would otherwise fill the budget below at every checkpoint
# sweep and push the real turns out unswept) and `<local-command-caveat>` lines. A
# slash-command wrapper collapses to the command as typed (`/wb-decide <args>`).
[ -n "$TRANSCRIPT" ] && [ -r "$TRANSCRIPT" ] || finish "skipped: no transcript"
total="$(wc -l <"$TRANSCRIPT" | tr -d ' ')"
off="$(read_num "$SDIR/sweep_offset")"
[ "$total" -lt "$off" ] && off=0
excerpt="$(tail -n +"$((off + 1))" "$TRANSCRIPT" | head -n "$((total - off))" | jq -rR '
  fromjson? | select(type == "object" and (.type == "user" or .type == "assistant"))
  | select(.isMeta != true)
  | (if .type == "user" then "USER: " else "ASSISTANT: " end) as $p
  | .message.content
  | (if type == "string" then [{type: "text", text: .}] elif type == "array" then . else [] end)
  | .[] | select(type == "object" and .type == "text" and ((.text // "") != ""))
  | .text
  | select(test("^\\s*<local-command-caveat>") | not)
  | if test("^\\s*<command-(name|message)>") then
      ((capture("<command-name>(?<n>[^<]*)</command-name>") | .n) // "") as $n
      | ((capture("<command-args>(?<a>[\\s\\S]*?)</command-args>") | .a) // "") as $a
      | ($n + (if $a == "" then "" else " " + $a end))
    else . end
  | select(. != "")
  | $p + . + "\n"' 2>/dev/null || true)"
if [ "${#excerpt}" -gt 0 ] && [ "$(printf '%s' "$excerpt" | wc -c)" -gt "$EXCERPT_BUDGET" ]; then
  excerpt="[...earlier turns truncated...]
$(printf '%s' "$excerpt" | tail -c "$EXCERPT_BUDGET")"
fi
if [ -z "$excerpt" ]; then
  printf '%s\n' "$total" >"$SDIR/sweep_offset"
  log_event "$SID" sweep_skipped "" '{"reason":"no_new_content"}'
  finish "nothing new"
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
mkdir -p "$CAPTURE_ROOT" 2>/dev/null || finish "failed: error"
# shelf_context — the prompt's two "do not draft these again" sections (R6), built fresh
# for each child run: this task's shelved drafts, and the drafts dismissed in the last
# 14 days (resolved/<stem>/<YYYYmmddTHHMMSS>-shelved_dismissed-<name>.md, aged by that
# filename stamp). Each is the `### ` title lines of the files, as bullets; an empty
# section is left out. Accepted drafts are not listed: `## Decisions` already holds them.
shelf_context() {
  local f cutoff ts waiting="" rejected="" t
  stem_ok "$TASK_STEM" || return 0
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    while IFS= read -r t; do waiting+="- ${t#\#\#\# }"$'\n'; done < <(grep '^### ' "$f" 2>/dev/null || true)
  done < <(shelved_paths "$TASK_STEM")
  cutoff="$(date -d '14 days ago' +%Y%m%dT%H%M%S)"
  for f in "$CAPTURE_ROOT/resolved/$TASK_STEM"/*-shelved_dismissed-*.md; do
    [ -f "$f" ] && [ ! -L "$f" ] || continue
    ts="${f##*/}"; ts="${ts:0:15}"
    [[ "$ts" =~ ^[0-9]{8}T[0-9]{6}$ ]] && [[ ! "$ts" < "$cutoff" ]] || continue
    while IFS= read -r t; do rejected+="- ${t#\#\#\# }"$'\n'; done < <(grep '^### ' "$f" 2>/dev/null || true)
  done
  [ -z "$waiting" ] || printf '\n=== ALREADY DRAFTED, AWAITING REVIEW (do not draft these again) ===\n%s' "$waiting"
  [ -z "$rejected" ] || printf '\n=== ALREADY REVIEWED AND REJECTED (do not draft these again) ===\n%s' "$rejected"
}

# run_child — asks the model about $excerpt vs $decisions; sets out, rc, result. Hooks
# are off in the child (`disableAllHooks`): every user/plugin hook would run in it,
# and e.g. a learnings injector adds KBs of unrelated text to each sweep prompt.
run_child() {
  out="$({
    cat <<'PROMPT'
You are reviewing an excerpt of a coding-session transcript against the
Decisions already recorded for the task being worked on.

If concrete decisions were made in the excerpt (an option chosen over an
alternative, or a design/approach settled) that are NOT already recorded in the
Decisions section, reply with one Decisions entry per unrecorded decision, at
most 3, and nothing else. Each entry is a `### <short title>` line, then 2-4
bullets covering what was decided, the alternative that was rejected, and why.

Otherwise reply with exactly: NONE

Rules: do not restate entries that are already recorded or that are listed
as already drafted or already rejected; do not invent decisions; routine implementation steps are not decisions; prefer NONE when
unsure. No preamble, no commentary.

=== RECORDED DECISIONS (do not repeat these) ===
PROMPT
    printf '%s\n%s\n=== TRANSCRIPT EXCERPT ===\n%s\n=== END EXCERPT ===\n' "$decisions" "$(shelf_context)" "$excerpt"
  } | (cd "$CAPTURE_ROOT" && env -u TMUX -u TMUX_PANE WB_CAPTURE_SWEEP=1 \
        timeout "$timeout_s" "${WB_CAPTURE_CLAUDE:-claude}" -p \
        --model "$CFG_SWEEP_MODEL" --effort "$CFG_SWEEP_EFFORT" \
        --no-session-persistence --max-turns 1 --tools "" --strict-mcp-config \
        --settings '{"disableAllHooks":true}' 2>/dev/null))"
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
# draft, trims $out to start at its first `### ` line and keeps at most MAX_ENTRIES
# `### ` entries. Models vary: "None.", "**NONE**", or prose that starts or ends
# with a bare NONE line. Order matters:
#   1. last line is NONE                               -> none
#   2. no line starting `### `: first line is NONE     -> none
#                               otherwise              -> invalid (contract
#      violation, not an outage: retried once, never feeds the failure backoff)
#   3. text before the first `### ` line               -> stripped from the draft
#   4. more than MAX_ENTRIES `### ` entries            -> the rest are dropped
parse_answer() {
  # $out is already trimmed: its first and last lines are non-empty
  if is_none_line "${out##*$'\n'}"; then result=none; return 0; fi
  if [[ $'\n'"$out" != *$'\n### '* ]]; then
    if is_none_line "${out%%$'\n'*}"; then result=none; else result=invalid; fi
    return 0
  fi
  [[ "$out" == '### '* ]] || out="### ${out#*$'\n### '}"
  # the prompt asks for at most MAX_ENTRIES entries; drop any the model adds past that
  out="$(printf '%s\n' "$out" | awk -v max="$MAX_ENTRIES" '/^### / && ++n > max { exit } 1')"
  result=draft
}

# is_none_line <line> — NONE in any case, optionally wrapped in * or ` and
# ending in . or !
is_none_line() {
  local l="${1,,}" re='^[*`]*none[.!]?[*`]*[.!]?$'
  l="${l#"${l%%[![:space:]]*}"}"
  l="${l%"${l##*[![:space:]]}"}"
  [[ "$l" =~ $re ]]
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

# a draft answer: shelve each `### ` entry as its own file (KTD3). The section changing
# during the (re)run marks every file stale, its sidecar holding the re-snapshot's
# entry count. A file that can't be shelved makes the run an error (the content is
# retried next time); entries already shelved stay.
drafted=0
if [ "$result" = draft ]; then
  [ -n "$snap_hash" ] && [ "$snap_hash" != "$(section_hash)" ] && stale=true
  entry="" entries_list=()
  while IFS= read -r line; do
    if [[ "$line" == '### '* ]]; then
      [ -z "$entry" ] || entries_list+=("$entry")
      entry="$line"
    else
      entry+=$'\n'"$line"
    fi
  done <<<"$out"
  [ -z "$entry" ] || entries_list+=("$entry")
  for entry in "${entries_list[@]}"; do
    entry="${entry%"${entry##*[![:space:]]}"}"
    if shelve_answer "$SID" sweep "$entry" "$stale" "$snap_count"; then drafted=$((drafted + 1))
    else result=error; break; fi
  done
fi

# the excerpt was consumed unless the sweep failed (retry that content next time).
# Written only now, after the shelving, so a failure there (result flipped to error)
# leaves the offset where it was. An invalid
# answer is retried once (`sweep_invalid` marks the retry), then its content is
# skipped, so a model that keeps answering in prose can't pin the excerpt
case "$result" in
  none|draft) printf '%s\n' "$total" >"$SDIR/sweep_offset"; remove_named "$SDIR" sweep_invalid ;;
  invalid)
    if [ -e "$SDIR/sweep_invalid" ]; then
      printf '%s\n' "$total" >"$SDIR/sweep_offset"; remove_named "$SDIR" sweep_invalid
    else
      : >"$SDIR/sweep_invalid"
    fi ;;
esac

# consecutive failures (claude missing / logged out / rate-limited) back the sweep
# off for the rest of the session; any run where claude answered (draft, none or
# invalid) resets the count
case "$result" in
  error|timeout) printf '%s\n' "$(( $(read_num "$SDIR/sweep_failures") + 1 ))" >"$SDIR/sweep_failures" ;;
  *) remove_named "$SDIR" sweep_failures ;;
esac
# entries: `### ` entries in a drafted answer (= shelf files, up to MAX_ENTRIES)
entries=0
[ "$result" = draft ] && entries="$(printf '%s\n' "$out" | awk '/^### /{n++} END{print n+0}')"
extra="$(jq -nc --arg r "$result" --argjson rr "$rerun" --argjson st "$stale" \
  --arg m "$CFG_SWEEP_MODEL" --arg e "$CFG_SWEEP_EFFORT" --argjson n "$entries" \
  '{result:$r, model:$m, effort:$e} + (if $r == "draft" then {entries:$n} else {} end)
   + (if $rr then {rerun:true} else {} end) + (if $st then {stale:true} else {} end)')"
log_event "$SID" sweep_ran "" "$extra"
case "$result" in
  draft) finish "drafted $drafted" ;;
  none)  finish "none" ;;
  *)     finish "failed: $result" ;;
esac
