#!/usr/bin/env bash
# Tests for wb-capture-sweep.sh (U4, store auto-capture): the async Stop-hook
# Haiku sweep. tmux AND claude are faked by scripts on PATH — the real claude
# binary is never invoked.
# Run: bash scripts/.config/scripts/tmux/tests/wb-capture-sweep.test.sh
set -uo pipefail

TMUXDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SWEEP="$TMUXDIR/wb-capture-sweep.sh"
CAPTURE="$TMUXDIR/wb-capture.sh"
REAL_BASH="$(command -v bash)"
ROOT="$(mktemp -d -t wb-capture-sweep.XXXXXX)"
trap 'rm -rf "$ROOT"' EXIT

FAKEBIN="$ROOT/fakebin"; mkdir -p "$FAKEBIN"
cat >"$FAKEBIN/tmux" <<'FAKE'
#!/usr/bin/env bash
case "$1" in
  display-message) echo "fakesess" ;;
  show) case "$*" in
    *@task*) printf '%s\n' "${FAKE_TASK:-}" ;;
    *@wb_capture_sid*) printf '%s\n' "${FAKE_SID:-}" ;;
  esac ;;
esac
exit 0
FAKE
cat >"$FAKEBIN/claude" <<'FAKE'
#!/usr/bin/env bash
# records argv / env / cwd / stdin into $FAKE_CLAUDE_OUT, then acts per mode
o="$FAKE_CLAUDE_OUT"; mkdir -p "$o"
echo x >>"$o/invocations"
printf '[%s]\n' "$@" >"$o/argv"
printf 'SWEEP=%s TMUX=%s PANE=%s\n' "${WB_CAPTURE_SWEEP-unset}" "${TMUX-unset}" "${TMUX_PANE-unset}" >"$o/env"
pwd >"$o/cwd"
cat >"$o/stdin"
mode="${FAKE_CLAUDE_MODE:-draft}"
if [ -n "${FAKE_CLAUDE_SEQ:-}" ]; then # comma list, one mode per invocation (last repeats)
  IFS=, read -ra seq <<<"$FAKE_CLAUDE_SEQ"
  i=$(( $(wc -l <"$o/invocations") - 1 )); [ "$i" -ge "${#seq[@]}" ] && i=$(( ${#seq[@]} - 1 ))
  mode="${seq[$i]}"
fi
case "$mode" in
  draft) printf '### Chose B over A\n- decided: B\n- rejected: A\n- why: simpler\n' ;;
  none)  printf 'NONE\n' ;;
  none-padded) printf '\n  NONE  \n\n' ;;
  none-prose)  printf 'None.\n' ;;
  none-refusal) printf "I'm not going to write a Decisions entry from this excerpt. Its only candidate is X.\nUnder the rule \"prefer NONE when unsure,\" the answer is:\n\nNONE\n" ;;
  prose-only)  printf 'I could not find a settled decision in this excerpt, so nothing to record.\n' ;;
  none-first)  printf 'NONE\n\nThe only candidate was already recorded as X.\n' ;;
  none-bold)   printf '**NONE**\n' ;;
  none-code)   printf '`NONE`.\n' ;;
  preamble-draft) printf 'Here is the entry:\n### Chose B over A\n- decided: B\n- rejected: A\n' ;;
  draft-mentions-none) printf '### Chose B over A\n- decided: B\n- rejected: none of the others\n- why: none needed\n- done\n' ;;
  fail)  echo "boom" >&2; exit 1 ;;
  empty) : ;;
  sleep) exec sleep 5 ;;
  edit-task) # a decision is recorded while "thinking" (task file changes mid-call)
    sed -i '/^## Decisions/a ### Recorded meanwhile' "$FAKE_TASK"
    printf '### Chose B over A\n- decided: B\n' ;;
  edit-handoffs) # a write OUTSIDE ## Decisions while "thinking"
    printf '## Handoffs\nsaved mid-call\n' >>"$FAKE_TASK"
    printf '### Chose B over A\n- decided: B\n' ;;
  write-draft) # an overlapping sweep wrote a draft while this child was "thinking"
    printf 'OVERLAP_FIRST_DRAFT\n' >"$FAKE_DRAFT_PATH"
    printf '### Chose B over A\n- decided: B\n' ;;
  write-draft-edit) # overlapping draft written AND the task's Decisions change while "thinking"
    printf 'OVERLAP_FIRST_DRAFT\n' >"$FAKE_DRAFT_PATH"; sed -i '/^## Decisions/a ### Recorded meanwhile' "$FAKE_TASK"
    printf '### Chose B over A\n- decided: B\n' ;;
  hold-lock) # the draft-write tail must wait on the session lock: a background holder
    # takes <dir>/.lock now, and at release records whether the draft had landed yet
    rm -f "$o/held"
    flock "$FAKE_SDIR/.lock" bash -c ': >"$1"; sleep 1.5; [ -e "$2" ] && echo landed >"$3" || echo absent >"$3"' _ "$o/held" "$FAKE_DRAFT_PATH" "$o/draft_at_release" >/dev/null 2>&1 &
    for _ in $(seq 1 100); do [ -e "$o/held" ] && break; sleep 0.05; done
    printf '### Chose B over A\n- decided: B\n' ;;
  touch-ended) : >"$FAKE_ENDED_PATH"; printf '### late\n- decided: x\n' ;;
  touch-ended-edit) # session ends AND the task's Decisions change while "thinking"
    : >"$FAKE_ENDED_PATH"; sed -i '/^## Decisions/a ### Recorded meanwhile' "$FAKE_TASK"
    printf '### late\n- decided: x\n' ;;
esac
exit 0
FAKE
chmod +x "$FAKEBIN/tmux" "$FAKEBIN/claude"

fail=0
ok()   { echo "ok   - $1"; }
bad()  { echo "FAIL - $1${2:+ ($2)}"; fail=1; }
assert_eq()    { [ "$2" = "$3" ] && ok "$1" || bad "$1" "expected [$2], got [$3]"; }
assert_match() { printf '%s' "$3" | grep -qE -- "$2" && ok "$1" || bad "$1" "expected /$2/, got [$3]"; }
assert_nomatch(){ printf '%s' "$3" | grep -qE -- "$2" && bad "$1" "unexpected /$2/" || ok "$1"; }
assert_file()  { [ -e "$2" ] && ok "$1" || bad "$1" "missing $2"; }
assert_nofile(){ [ ! -e "$2" ] && ok "$1" || bad "$1" "unexpected $2"; }

n=0
new_scenario() {
  n=$((n + 1))
  H="$ROOT/s$n"; mkdir -p "$H/state" "$H/config" "$H/tasks"
  STATE="$H/state"; CFG="$H/config"
  CAP="$STATE/wb/capture"; LOG="$CAP/log.jsonl"
  FAKE_TASK="$H/tasks/dotfiles--feat-x.md"
  printf '# task\n## Goal\nGOAL_SECTION_TEXT\n## Decisions\n### Existing decision\n- decided: EXISTING_DECISION_TEXT\n## Done\nDONE_SECTION_TEXT\n' >"$FAKE_TASK"
  D="$CAP/sid-aaa"; mkdir -p "$D"
  OUTDIR="$H/claude-out"
  TRANSCRIPT="$H/t.jsonl"
  mk_transcript 'first question' 'first answer'
  printf '4\n' >"$D/unchanged"
  EXTRA_ENV=(WB_CAPTURE_SWEEP_DELAY=0 FAKE_CLAUDE_MODE=draft)
}
# mk_transcript <user text> <assistant text> — overwrite fixture
mk_transcript() {
  {
    jq -nc --arg t "$1" '{type:"user",message:{role:"user",content:$t}}'
    jq -nc --arg t "$2" '{type:"assistant",message:{role:"assistant",content:[{type:"thinking",thinking:"THINKING_TEXT"},{type:"text",text:$t},{type:"tool_use",id:"1",name:"Bash",input:{command:"TOOLUSE_TEXT"}}]}}'
    jq -nc '{type:"user",message:{role:"user",content:[{type:"tool_result",tool_use_id:"1",content:"TOOLRESULT_TEXT"}]}}'
  } >"$TRANSCRIPT"
}
add_turn() { # <user> <assistant> — append
  jq -nc --arg t "$1" '{type:"user",message:{role:"user",content:[{type:"text",text:$t}]}}' >>"$TRANSCRIPT"
  jq -nc --arg t "$2" '{type:"assistant",message:{role:"assistant",content:[{type:"text",text:$t}]}}' >>"$TRANSCRIPT"
}

# run <script> [verb] — stdin is a Stop payload. Sets OUT, RC.
run() {
  local script="$1"; shift
  local -a envv=(HOME="$H" XDG_STATE_HOME="$STATE" XDG_CONFIG_HOME="$CFG"
    PATH="$FAKEBIN:$PATH" FAKE_TASK="$FAKE_TASK" FAKE_SID=sid-aaa FAKE_CLAUDE_OUT="$OUTDIR"
    FAKE_ENDED_PATH="$D/ended" FAKE_DRAFT_PATH="$D/draft" FAKE_SDIR="$D" TMUX=fake,1,0 TMUX_PANE=%1)
  jq -nc --arg tp "$TRANSCRIPT" '{session_id:"sid-aaa",transcript_path:$tp,last_assistant_message:"hi"}' >"$H/stdin.json"
  OUT="$(env "${envv[@]}" "${EXTRA_ENV[@]}" "$REAL_BASH" "$script" "$@" <"$H/stdin.json" 2>"$H/stderr")"
  RC=$?
}
sweep() { run "$SWEEP"; }
events() { [ -f "$LOG" ] && jq -r .event "$LOG" | tr '\n' ' ' | sed 's/ $//' || echo ""; }
last_field() { jq -r --arg e "$1" "select(.event==\$e)|.$2" "$LOG" 2>/dev/null | tail -1; }
invocations() { [ -f "$OUTDIR/invocations" ] && wc -l <"$OUTDIR/invocations" | tr -d ' ' || echo 0; }
set_conf() { mkdir -p "$CFG/wb"; printf '%s\n' "$@" >"$CFG/wb/capture.conf"; }

echo "# fires: draft written atomically"
new_scenario
sweep
assert_eq "exit 0" 0 "$RC"; assert_eq "silent stdout" "" "$OUT"
assert_file "draft written" "$D/draft"
assert_match "draft body" '^### Chose B over A' "$(cat "$D/draft")"
assert_eq "no tmp left" "" "$(ls "$D" | grep 'tmp' || true)"
assert_eq "sweep_ran logged" "sweep_ran" "$(events)"
assert_eq "result draft" draft "$(last_field sweep_ran result)"
assert_eq "counter reset" 0 "$(cat "$D/unchanged")"
assert_eq "offset stored" 3 "$(cat "$D/sweep_offset")"

echo "# nothing found"
new_scenario; EXTRA_ENV+=(FAKE_CLAUDE_MODE=none)
sweep
assert_nofile "no draft" "$D/draft"
assert_eq "result none" none "$(last_field sweep_ran result)"
assert_eq "counter reset" 0 "$(cat "$D/unchanged")"
new_scenario; EXTRA_ENV+=(FAKE_CLAUDE_MODE=none-padded)
sweep
assert_nofile "padded NONE: no draft" "$D/draft"
assert_eq "padded NONE: result none" none "$(last_field sweep_ran result)"
new_scenario; EXTRA_ENV+=(FAKE_CLAUDE_MODE=none-prose)
sweep
assert_nofile "'None.': no draft" "$D/draft"
assert_eq "'None.': result none" none "$(last_field sweep_ran result)"

echo "# refusal prose ending in a bare NONE line is none, not a draft"
new_scenario; EXTRA_ENV+=(FAKE_CLAUDE_MODE=none-refusal)
sweep
assert_nofile "refusal+NONE: no draft" "$D/draft"
assert_eq "refusal+NONE: result none" none "$(last_field sweep_ran result)"

echo "# NONE first then commentary, and decorated NONE, are none"
for m in none-first none-bold none-code; do
  new_scenario; EXTRA_ENV+=(FAKE_CLAUDE_MODE=$m)
  sweep
  assert_nofile "$m: no draft" "$D/draft"
  assert_eq "$m: result none" none "$(last_field sweep_ran result)"
done

echo "# prose with no heading and no NONE is invalid: retried once, then skipped"
new_scenario; EXTRA_ENV+=(FAKE_CLAUDE_MODE=prose-only)
sweep
assert_nofile "prose-only: no draft" "$D/draft"
assert_eq "prose-only: result invalid" invalid "$(last_field sweep_ran result)"
assert_nofile "prose-only: offset not advanced" "$D/sweep_offset"
assert_file "prose-only: retry marked" "$D/sweep_invalid"
assert_nofile "prose-only: not a failure" "$D/sweep_failures"
printf '4\n' >"$D/unchanged"; sweep
assert_eq "prose-only retry: invalid again" invalid "$(last_field sweep_ran result)"
assert_eq "prose-only retry: offset advanced" 3 "$(cat "$D/sweep_offset" 2>/dev/null)"
assert_nofile "prose-only retry: marker cleared" "$D/sweep_invalid"

echo "# invalid answers never back the sweep off"
new_scenario; EXTRA_ENV+=(FAKE_CLAUDE_MODE=prose-only)
for i in 1 2 3 4; do printf '4\n' >"$D/unchanged"; add_turn "q$i" "a$i"; sweep; done
assert_eq "4 invalid: 4 invocations" 4 "$(invocations)"
assert_eq "4 invalid: no backoff skip" "" "$(last_field sweep_skipped reason)"
assert_nofile "4 invalid: no failures" "$D/sweep_failures"
new_scenario; EXTRA_ENV+=(FAKE_CLAUDE_MODE=fail)
for i in 1 2; do printf '4\n' >"$D/unchanged"; add_turn "q$i" "a$i"; sweep; done
EXTRA_ENV+=(FAKE_CLAUDE_MODE=prose-only); printf '4\n' >"$D/unchanged"; add_turn q3 a3; sweep
assert_nofile "invalid resets failures (claude answered)" "$D/sweep_failures"
new_scenario; printf '\n' >"$D/sweep_invalid"
sweep
assert_nofile "a draft clears the retry marker" "$D/sweep_invalid"

echo "# a preamble before the first ### line is stripped from the draft"
new_scenario; EXTRA_ENV+=(FAKE_CLAUDE_MODE=preamble-draft)
sweep
assert_file "preamble: draft written" "$D/draft"
assert_eq "preamble: draft starts at ###" "### Chose B over A" "$(head -1 "$D/draft")"
assert_nomatch "preamble: text gone" 'Here is the entry' "$(cat "$D/draft")"
assert_eq "preamble: result draft" draft "$(last_field sweep_ran result)"

echo "# a valid entry that mentions none on a non-final line is still a draft"
new_scenario; EXTRA_ENV+=(FAKE_CLAUDE_MODE=draft-mentions-none)
sweep
assert_file "mentions-none: draft written" "$D/draft"
assert_eq "mentions-none: result draft" draft "$(last_field sweep_ran result)"

echo "# rerun path parses the same way (preamble entry on both calls)"
new_scenario; EXTRA_ENV+=(FAKE_CLAUDE_SEQ=edit-task,preamble-draft)
sweep
assert_eq "rerun: two invocations" 2 "$(invocations)"
assert_eq "rerun: draft starts at ###" "### Chose B over A" "$(head -1 "$D/draft" 2>/dev/null)"

echo "# child invocation shape"
new_scenario
sweep
ARGV="$(cat "$OUTDIR/argv")"
assert_match "-p" '^\[-p\]$' "$ARGV"
assert_match "--model" '^\[--model\]$' "$ARGV"
assert_match "haiku" '^\[haiku\]$' "$ARGV"
assert_match "--no-session-persistence" '^\[--no-session-persistence\]$' "$ARGV"
assert_match "--max-turns" '^\[--max-turns\]$' "$ARGV"
assert_match "max-turns 1" '^\[1\]$' "$ARGV"
assert_match "--tools" '^\[--tools\]$' "$ARGV"
assert_match "tools empty-string arg" '^\[\]$' "$ARGV"
assert_match "--strict-mcp-config (no MCP servers loaded)" '^\[--strict-mcp-config\]$' "$ARGV"
assert_eq "env stripped/set" "SWEEP=1 TMUX=unset PANE=unset" "$(cat "$OUTDIR/env")"
assert_eq "cwd is capture root" "$(cd "$CAP" && pwd -P)" "$(cat "$OUTDIR/cwd")"

echo "# recursion guard"
new_scenario; EXTRA_ENV+=(WB_CAPTURE_SWEEP=1)
sweep
assert_eq "sweep exit" 0 "$RC"; assert_eq "sweep silent" "" "$OUT"
assert_eq "fake never invoked" 0 "$(invocations)"
assert_nofile "nothing logged" "$LOG"; assert_eq "unchanged untouched" 4 "$(cat "$D/unchanged")"
for v in hook-prompt hook-posttool hook-stop hook-end clear dismiss mute unmute; do
  run "$CAPTURE" "$v"
  assert_eq "$v silent" "" "$OUT"
done
assert_nofile "verbs log nothing" "$LOG"
assert_eq "verbs leave unchanged" 4 "$(cat "$D/unchanged")"

echo "# timeout and error"
new_scenario; EXTRA_ENV+=(FAKE_CLAUDE_MODE=sleep); set_conf sweep_timeout=1
sweep
assert_nofile "timeout: no draft" "$D/draft"
assert_eq "timeout result" timeout "$(last_field sweep_ran result)"
assert_eq "timeout: counter reset" 0 "$(cat "$D/unchanged")"
assert_nofile "timeout: sweep_offset unchanged (content retried)" "$D/sweep_offset"
new_scenario; EXTRA_ENV+=(FAKE_CLAUDE_MODE=fail)
sweep
assert_nofile "error: no draft" "$D/draft"
assert_eq "error result" error "$(last_field sweep_ran result)"
assert_nofile "error: sweep_offset unchanged (content retried)" "$D/sweep_offset"
new_scenario; EXTRA_ENV+=(FAKE_CLAUDE_MODE=empty)
sweep
assert_eq "empty output is error" error "$(last_field sweep_ran result)"
assert_eq "no tmp left (error)" "" "$(ls "$D" | grep 'tmp' || true)"

echo "# skips"
new_scenario; set_conf sweep=off
sweep
assert_eq "off: invoked" 0 "$(invocations)"
assert_eq "off: event" sweep_skipped "$(events)"
assert_eq "off: reason" disabled "$(last_field sweep_skipped reason)"
assert_eq "off: counter reset" 0 "$(cat "$D/unchanged")"
new_scenario; : >"$D/muted"
sweep
assert_eq "muted: invoked" 0 "$(invocations)"
assert_eq "muted: reason" muted "$(last_field sweep_skipped reason)"
new_scenario; printf 'existing draft\n' >"$D/draft"
sweep
assert_eq "pending: invoked" 0 "$(invocations)"
assert_eq "pending: reason" draft_pending "$(last_field sweep_skipped reason)"
assert_eq "pending: draft untouched" "existing draft" "$(cat "$D/draft")"
assert_eq "pending: counter reset" 0 "$(cat "$D/unchanged")"
new_scenario; printf '3\n' >"$D/unchanged"
sweep
assert_eq "below threshold: invoked" 0 "$(invocations)"
assert_nofile "below threshold: no log" "$LOG"
assert_eq "below threshold: counter kept" 3 "$(cat "$D/unchanged")"
new_scenario; set_conf sweep_every=2; printf '2\n' >"$D/unchanged"
sweep
assert_eq "sweep_every honoured" draft "$(last_field sweep_ran result)"

echo "# backoff: 3 consecutive failures stop the sweep for the session"
new_scenario; EXTRA_ENV+=(FAKE_CLAUDE_MODE=fail)
for i in 1 2 3; do printf '4\n' >"$D/unchanged"; add_turn "q$i" "a$i"; sweep; done
assert_eq "3 failures counted" 3 "$(cat "$D/sweep_failures")"
assert_eq "3 child invocations" 3 "$(invocations)"
printf '4\n' >"$D/unchanged"; add_turn q4 a4; sweep
assert_eq "4th: child not invoked" 3 "$(invocations)"
assert_eq "4th: skipped" sweep_skipped "$(events | awk '{print $NF}')"
assert_eq "4th: reason backoff" backoff "$(last_field sweep_skipped reason)"
assert_eq "4th: counter reset" 0 "$(cat "$D/unchanged")"
assert_eq "failures kept (session-scoped)" 3 "$(cat "$D/sweep_failures")"
new_scenario; EXTRA_ENV+=(FAKE_CLAUDE_MODE=sleep); set_conf sweep_timeout=1
for i in 1 2 3; do printf '4\n' >"$D/unchanged"; add_turn "q$i" "a$i"; sweep; done
assert_eq "timeouts count as failures" 3 "$(cat "$D/sweep_failures")"

echo "# backoff: a success resets the count"
new_scenario; EXTRA_ENV+=(FAKE_CLAUDE_MODE=fail)
for i in 1 2; do printf '4\n' >"$D/unchanged"; add_turn "q$i" "a$i"; sweep; done
assert_eq "2 failures" 2 "$(cat "$D/sweep_failures")"
EXTRA_ENV+=(FAKE_CLAUDE_MODE=none); printf '4\n' >"$D/unchanged"; add_turn q3 a3; sweep
assert_nofile "NONE resets failures" "$D/sweep_failures"
EXTRA_ENV+=(FAKE_CLAUDE_MODE=fail)
for i in 4 5 6; do printf '4\n' >"$D/unchanged"; add_turn "q$i" "a$i"; sweep; done
printf '4\n' >"$D/unchanged"; add_turn q7 a7; sweep
assert_eq "backoff only after 3 more in a row" backoff "$(last_field sweep_skipped reason)"
new_scenario
printf '2\n' >"$D/sweep_failures"; sweep
assert_nofile "draft resets failures" "$D/sweep_failures"

echo "# backoff: sweep_max_failures config"
new_scenario; EXTRA_ENV+=(FAKE_CLAUDE_MODE=fail); set_conf sweep_max_failures=1
sweep; printf '4\n' >"$D/unchanged"; add_turn q2 a2; sweep
assert_eq "max 1: second sweep backs off" backoff "$(last_field sweep_skipped reason)"
assert_eq "max 1: one invocation" 1 "$(invocations)"
new_scenario; EXTRA_ENV+=(FAKE_CLAUDE_MODE=fail); set_conf sweep_max_failures=0
printf '9\n' >"$D/sweep_failures"; sweep
assert_eq "max 0: never backs off" error "$(last_field sweep_ran result)"
new_scenario; set_conf sweep_max_failures=abc; printf '3\n' >"$D/sweep_failures"; sweep
assert_eq "invalid max falls back to 3" backoff "$(last_field sweep_skipped reason)"

echo "# draft strikes: after a discard the sweep runs again (no draft_pending skip)"
new_scenario
sweep; assert_file "draft written" "$D/draft"
run "$CAPTURE" hook-prompt; run "$CAPTURE" hook-stop        # nudge, ignored: strike 1
run "$CAPTURE" hook-prompt; run "$CAPTURE" hook-stop        # re-nudge, ignored: discarded
assert_nofile "draft discarded" "$D/draft"
printf '4\n' >"$D/unchanged"; add_turn q2 a2; sweep
assert_eq "sweep ran after shelve" 1 "$(jq -r 'select(.event=="draft_shelved")|.event' "$LOG" | wc -l | tr -d ' ')"
assert_eq "no draft_pending skip" "" "$(last_field sweep_skipped reason)"
assert_file "new draft written" "$D/draft"
assert_nofile "new draft starts with no strikes" "$D/draft_strikes"

echo "# overlapping sweeps: a draft written while the child ran is shelved (superseded), not overwritten"
new_scenario; EXTRA_ENV+=(FAKE_CLAUDE_MODE=write-draft)
printf '1\n' >"$D/draft_strikes"
sweep
assert_match "the new draft is in place" '^### Chose B over A' "$(cat "$D/draft")"
SH="$CAP/shelved/dotfiles--feat-x"
assert_eq "exactly one shelved file" 1 "$(ls "$SH"/*.md 2>/dev/null | wc -l | tr -d ' ')"
assert_match "the shelved file holds the first draft verbatim" 'OVERLAP_FIRST_DRAFT' "$(cat "$SH"/*.md 2>/dev/null)"
assert_eq "draft_shelved logged once" 1 "$(jq -r 'select(.event=="draft_shelved")|.event' "$LOG" | wc -l | tr -d ' ')"
assert_eq "draft_shelved reason superseded" superseded "$(last_field draft_shelved reason)"
assert_eq "sweep_ran still logs draft" draft "$(last_field sweep_ran result)"
assert_nofile "strikes of the superseded draft are gone" "$D/draft_strikes"
new_scenario; EXTRA_ENV+=(FAKE_CLAUDE_MODE=write-draft)
printf '2\n' >"$D/draft_stale"
sweep
SH="$CAP/shelved/dotfiles--feat-x"
assert_eq "a stale superseded draft keeps its stale sidecar" 1 "$(ls "$SH"/*.md.stale 2>/dev/null | wc -l | tr -d ' ')"
assert_eq "...and draft_shelved is tagged stale" true "$(last_field draft_shelved stale)"
assert_nofile "the new draft is not stale" "$D/draft_stale"
new_scenario
sweep
assert_nofile "no overlap: nothing shelved" "$CAP/shelved"
assert_eq "no overlap: no draft_shelved" 0 "$(jq -r 'select(.event=="draft_shelved")|.event' "$LOG" | wc -l | tr -d ' ')"
# the older draft can't be shelved (shelved/ is a plain file, so mkdir fails): it
# stays, this answer is dropped as an error, and the excerpt is NOT consumed
new_scenario; EXTRA_ENV+=(FAKE_CLAUDE_MODE=write-draft)
mkdir -p "$CAP"; : >"$CAP/shelved"
sweep
assert_match "shelve failed: the older draft stays in place" 'OVERLAP_FIRST_DRAFT' "$(cat "$D/draft")"
assert_eq "shelve failed: sweep_ran logs error" error "$(last_field sweep_ran result)"
assert_nofile "shelve failed: sweep_offset unchanged (content retried)" "$D/sweep_offset"

echo "# overlapping sweeps: a draft under review is left alone; the NEW answer is shelved"
SH="$CAP/shelved/dotfiles--feat-x"
protect_check() { # <desc> — the shown draft and its review state are untouched, the new answer is shelved
  assert_eq "$1: the shown draft is still in place" 'OVERLAP_FIRST_DRAFT' "$(cat "$D/draft")"
  SH="$CAP/shelved/dotfiles--feat-x"
  assert_eq "$1: exactly one shelved file" 1 "$(ls "$SH"/*.md 2>/dev/null | wc -l | tr -d ' ')"
  assert_match "$1: the shelved file holds the NEW answer" '^### Chose B over A' "$(cat "$SH"/*.md 2>/dev/null)"
  assert_eq "$1: draft_shelved reason superseded" superseded "$(last_field draft_shelved reason)"
  assert_eq "$1: draft_shelved logged once" 1 "$(jq -r 'select(.event=="draft_shelved")|.event' "$LOG" | wc -l | tr -d ' ')"
  assert_eq "$1: sweep_ran logs draft" draft "$(last_field sweep_ran result)"
  assert_file "$1: sweep_offset advanced (answer consumed)" "$D/sweep_offset"
  assert_eq "$1: the draft's strikes are kept" 1 "$(cat "$D/draft_strikes")"
  assert_nofile "$1: no tmp left" "$(ls "$D"/draft.tmp.* 2>/dev/null | head -1)"
}
new_scenario; EXTRA_ENV+=(FAKE_CLAUDE_MODE=write-draft)
printf '2\n' >"$D/reviewing"; printf '1\n' >"$D/draft_strikes"
sweep
protect_check "reviewing"
assert_eq "reviewing: the review state (carried-Stop counter) is untouched" 2 "$(cat "$D/reviewing")"
new_scenario; EXTRA_ENV+=(FAKE_CLAUDE_MODE=write-draft)
printf 'sweep' >"$D/outstanding"; printf '1\n' >"$D/draft_strikes"; printf 'h\n' >"$D/nudged_draft"
sweep
protect_check "outstanding=sweep"
assert_eq "outstanding=sweep: the nudge is still outstanding" sweep "$(cat "$D/outstanding")"
assert_eq "outstanding=sweep: nudged_draft kept" h "$(cat "$D/nudged_draft")"
# a phrase nudge outstanding is not a review of the draft: the older draft is shelved first
new_scenario; EXTRA_ENV+=(FAKE_CLAUDE_MODE=write-draft)
printf 'phrase' >"$D/outstanding"
sweep
assert_match "outstanding=phrase: the new draft is in place" '^### Chose B over A' "$(cat "$D/draft")"
assert_match "outstanding=phrase: the older draft was shelved" 'OVERLAP_FIRST_DRAFT' "$(cat "$CAP/shelved/dotfiles--feat-x"/*.md 2>/dev/null)"
# the new answer is stale: sidecar + stale tag
new_scenario; EXTRA_ENV+=(FAKE_CLAUDE_MODE=write-draft-edit)
printf '1\n' >"$D/reviewing"; printf '1\n' >"$D/draft_strikes"
sweep
protect_check "stale answer"
assert_eq "stale answer: the sidecar marks the shelved answer stale" 1 "$(ls "$SH"/*.md.stale 2>/dev/null | wc -l | tr -d ' ')"
assert_eq "stale answer: draft_shelved tagged stale" true "$(last_field draft_shelved stale)"
assert_nofile "stale answer: the shown draft gains no draft_stale" "$D/draft_stale"
# the new answer can't be shelved (shelved/ is a plain file): error, nothing disturbed, offset not advanced
new_scenario; EXTRA_ENV+=(FAKE_CLAUDE_MODE=write-draft)
printf '2\n' >"$D/reviewing"; mkdir -p "$CAP"; : >"$CAP/shelved"
sweep
assert_eq "shelve failed: the shown draft stays" 'OVERLAP_FIRST_DRAFT' "$(cat "$D/draft")"
assert_eq "shelve failed: reviewing untouched" 2 "$(cat "$D/reviewing")"
assert_eq "shelve failed: sweep_ran logs error" error "$(last_field sweep_ran result)"
assert_nofile "shelve failed: sweep_offset unchanged (content retried)" "$D/sweep_offset"

echo "# stale draft: task file changed during the child call"
new_scenario; EXTRA_ENV+=(FAKE_CLAUDE_MODE=edit-task)
sweep
assert_file "stale: draft still written" "$D/draft"
assert_match "stale: draft body" '^### Chose B over A' "$(cat "$D/draft")"
assert_file "stale: draft_stale written" "$D/draft_stale"
assert_eq "stale: re-snapshot entry count (Existing + first edit)" 2 "$(cat "$D/draft_stale")"
assert_eq "stale: child ran twice (one rerun)" 2 "$(invocations)"
assert_eq "stale: rerun logged" true "$(last_field sweep_ran rerun)"
assert_eq "stale: no tmp left" "" "$(ls "$D" | grep 'tmp' || true)"
assert_eq "stale: one sweep_ran" sweep_ran "$(events)"
assert_eq "stale: result draft" draft "$(last_field sweep_ran result)"
assert_eq "stale: stale true" true "$(last_field sweep_ran stale)"
assert_nofile "stale: no draft_strikes" "$D/draft_strikes"
run "$CAPTURE" hook-prompt
assert_match "stale: nudge says may already be recorded" 'may already be recorded' "$OUT"
assert_eq "stale: nudge_fired not tagged" null "$(last_field nudge_fired stale)"
run "$CAPTURE" dismiss
assert_eq "stale: dismissed tagged" true "$(last_field dismissed stale)"
assert_nofile "stale: dismiss clears draft_stale" "$D/draft_stale"

echo "# stale draft: unchanged task file -> no draft_stale, log as before"
new_scenario
sweep
assert_file "fresh: draft written" "$D/draft"
assert_nofile "fresh: no draft_stale" "$D/draft_stale"
assert_eq "fresh: sweep_ran line has exactly ts/sid/task/event/result" '["event","result","session_id","task","ts"]' "$(jq -c 'select(.event=="sweep_ran")|keys' "$LOG")"
assert_eq "fresh: no stale field" null "$(last_field sweep_ran stale)"

echo "# stale draft: a non-stale draft removes an old draft_stale"
new_scenario; printf '7\n' >"$D/draft_stale"
sweep
assert_file "old-stale: draft written" "$D/draft"
assert_nofile "old-stale: draft_stale removed" "$D/draft_stale"
assert_eq "old-stale: not tagged" null "$(last_field sweep_ran stale)"

echo "# stale draft: a changed task file with no draft result writes nothing stale"
new_scenario; EXTRA_ENV+=(FAKE_CLAUDE_MODE=none)
sweep
assert_nofile "none: no draft_stale" "$D/draft_stale"

echo "# stale draft: count is of the snapshot, task without Decisions entries"
new_scenario; printf '# task\n## Decisions\n## Done\n' >"$FAKE_TASK"; EXTRA_ENV+=(FAKE_CLAUDE_MODE=edit-task)
sweep
assert_eq "empty section: count of the re-snapshot" 1 "$(cat "$D/draft_stale")"

echo "# stale draft: a new stale draft after a discard is flagged afresh"
new_scenario; EXTRA_ENV+=(FAKE_CLAUDE_MODE=edit-task)
sweep
run "$CAPTURE" hook-prompt; run "$CAPTURE" hook-stop; run "$CAPTURE" hook-prompt; run "$CAPTURE" hook-stop
assert_nofile "discarded: draft_stale gone" "$D/draft_stale"
printf '4\n' >"$D/unchanged"; add_turn q2 a2; sweep
assert_file "re-sweep: draft_stale again" "$D/draft_stale"
assert_eq "re-sweep: count of its own re-snapshot" 4 "$(cat "$D/draft_stale")"

echo "# rerun: write outside ## Decisions during the child run is NOT stale"
new_scenario; EXTRA_ENV+=(FAKE_CLAUDE_MODE=edit-handoffs)
sweep
assert_file "handoffs: draft written" "$D/draft"
assert_nofile "handoffs: not stale" "$D/draft_stale"
assert_eq "handoffs: child called once" 1 "$(invocations)"
assert_eq "handoffs: no stale field" null "$(last_field sweep_ran stale)"
assert_eq "handoffs: no rerun field" null "$(last_field sweep_ran rerun)"

echo "# rerun: Decisions edited in run 1 only -> rerun, draft fresh"
new_scenario; EXTRA_ENV+=(FAKE_CLAUDE_SEQ=edit-task,draft)
sweep
assert_eq "rerun: child called twice" 2 "$(invocations)"
assert_file "rerun: draft written" "$D/draft"
assert_nofile "rerun: not stale" "$D/draft_stale"
assert_eq "rerun: logged" true "$(last_field sweep_ran rerun)"
assert_eq "rerun: no stale field" null "$(last_field sweep_ran stale)"
assert_eq "rerun: result draft" draft "$(last_field sweep_ran result)"
assert_match "rerun: second prompt carries the recorded entry" 'Recorded meanwhile' "$(cat "$OUTDIR/stdin")"
assert_eq "rerun: one sweep_ran" sweep_ran "$(events)"

echo "# rerun: rerun answers NONE -> no draft"
new_scenario; EXTRA_ENV+=(FAKE_CLAUDE_SEQ=edit-task,none)
sweep
assert_eq "rerun-none: child called twice" 2 "$(invocations)"
assert_nofile "rerun-none: no draft" "$D/draft"
assert_nofile "rerun-none: no draft_stale" "$D/draft_stale"
assert_eq "rerun-none: result none" none "$(last_field sweep_ran result)"
assert_eq "rerun-none: rerun logged" true "$(last_field sweep_ran rerun)"
assert_eq "rerun-none: offset advanced" 3 "$(cat "$D/sweep_offset")"

echo "# rerun: section changes during both runs -> stale draft (re-snapshot count)"
new_scenario; EXTRA_ENV+=(FAKE_CLAUDE_SEQ=edit-task,edit-task)
sweep
assert_eq "both: child called twice, never thrice" 2 "$(invocations)"
assert_file "both: draft written" "$D/draft"
assert_eq "both: draft_stale is the re-snapshot count" 2 "$(cat "$D/draft_stale")"
assert_eq "both: rerun true" true "$(last_field sweep_ran rerun)"
assert_eq "both: stale true" true "$(last_field sweep_ran stale)"

echo "# rerun: rerun times out / errors -> no draft, counts as a failure"
new_scenario; EXTRA_ENV+=(FAKE_CLAUDE_SEQ=edit-task,sleep); set_conf sweep_timeout=1
sweep
assert_nofile "rerun-timeout: no draft" "$D/draft"
assert_eq "rerun-timeout: result" timeout "$(last_field sweep_ran result)"
assert_eq "rerun-timeout: rerun logged" true "$(last_field sweep_ran rerun)"
assert_eq "rerun-timeout: failure counted" 1 "$(cat "$D/sweep_failures")"
assert_nofile "rerun-timeout: offset not advanced" "$D/sweep_offset"
new_scenario; EXTRA_ENV+=(FAKE_CLAUDE_SEQ=edit-task,fail)
sweep
assert_nofile "rerun-error: no draft" "$D/draft"
assert_eq "rerun-error: result" error "$(last_field sweep_ran result)"
assert_eq "rerun-error: failure counted" 1 "$(cat "$D/sweep_failures")"

echo "# rerun: a first NONE/error answer is never rerun"
new_scenario; EXTRA_ENV+=(FAKE_CLAUDE_SEQ=none)
sweep
assert_eq "no-rerun on none: called once" 1 "$(invocations)"
assert_eq "no-rerun on none: no rerun field" null "$(last_field sweep_ran rerun)"

echo "# no new content: only tool calls / nothing since the last sweep"
new_scenario
{
  jq -nc '{type:"assistant",message:{content:[{type:"tool_use",id:"1",name:"Bash",input:{command:"x"}}]}}'
  jq -nc '{type:"user",message:{content:[{type:"tool_result",tool_use_id:"1",content:"out"}]}}'
} >"$TRANSCRIPT"
sweep
assert_eq "tool-only: invoked" 0 "$(invocations)"
assert_eq "tool-only: event" sweep_skipped "$(events)"
assert_eq "tool-only: reason" no_new_content "$(last_field sweep_skipped reason)"
assert_eq "tool-only: offset advanced past it" 2 "$(cat "$D/sweep_offset")"
assert_nofile "tool-only: no draft" "$D/draft"
assert_eq "tool-only: counter reset" 0 "$(cat "$D/unchanged")"
new_scenario; EXTRA_ENV+=(FAKE_CLAUDE_MODE=none)
sweep                                   # consumes the fixture (offset 3)
printf '4\n' >"$D/unchanged"; : >"$OUTDIR/invocations"
sweep                                   # nothing new since the last sweep_offset
assert_eq "nothing new: no second child" 0 "$(invocations)"
assert_eq "nothing new: reason" no_new_content "$(last_field sweep_skipped reason)"
assert_eq "nothing new: offset kept" 3 "$(cat "$D/sweep_offset")"

echo "# excerpt content"
new_scenario
sweep
S="$(cat "$OUTDIR/stdin")"
assert_match "user prefix" '^USER: first question' "$S"
assert_match "assistant prefix" '^ASSISTANT: first answer' "$S"
assert_nomatch "no thinking" 'THINKING_TEXT' "$S"
assert_nomatch "no tool_use" 'TOOLUSE_TEXT' "$S"
assert_nomatch "no tool_result" 'TOOLRESULT_TEXT' "$S"

echo "# excerpt budget"
new_scenario
{
  for i in $(seq 1 200); do
    pad="$(head -c 1000 /dev/zero | tr '\0' 'x')"
    jq -nc --arg t "turn$i $pad" '{type:"user",message:{role:"user",content:$t}}'
  done
  jq -nc '{type:"assistant",message:{content:[{type:"text",text:"NEWEST_MARK"}]}}'
} >"$TRANSCRIPT"
sed -i '1s/turn1 /OLDEST_MARK /' "$TRANSCRIPT"
sweep
SZ="$(wc -c <"$OUTDIR/stdin" | tr -d ' ')"
[ "$SZ" -le 28000 ] && ok "stdin within budget+overhead ($SZ)" || bad "stdin too big" "$SZ"
assert_match "newest kept" 'NEWEST_MARK' "$(cat "$OUTDIR/stdin")"
assert_nomatch "oldest dropped" 'OLDEST_MARK' "$(cat "$OUTDIR/stdin")"

echo "# offset"
new_scenario; EXTRA_ENV+=(FAKE_CLAUDE_MODE=none)
sweep
assert_eq "offset after first" 3 "$(cat "$D/sweep_offset")"
add_turn 'second question' 'second answer'
printf '4\n' >"$D/unchanged"
sweep
S="$(cat "$OUTDIR/stdin")"
assert_match "new text included" 'second answer' "$S"
assert_nomatch "old text excluded" 'first answer' "$S"
assert_eq "offset advanced" 5 "$(cat "$D/sweep_offset")"
: >"$TRANSCRIPT"; mk_transcript 'fresh question' 'fresh answer'   # shorter than offset
printf '4\n' >"$D/unchanged"
sweep
assert_match "short transcript restarts at 0" 'fresh answer' "$(cat "$OUTDIR/stdin")"

echo "# ended"
new_scenario; : >"$D/ended"
sweep
assert_eq "ended: invoked" 0 "$(invocations)"; assert_nofile "ended: no log" "$LOG"
assert_nofile "ended: no draft" "$D/draft"
new_scenario; EXTRA_ENV+=(FAKE_CLAUDE_MODE=touch-ended)
sweep
PK="$CAP/shelved/dotfiles--feat-x"
assert_nofile "ended mid-run: draft not left in the session dir" "$D/draft"
assert_eq "ended mid-run: no tmp" "" "$(ls "$D" | grep 'tmp' || true)"
assert_eq "ended mid-run: logs" "pending_at_end draft_shelved sweep_ran" "$(events)"
assert_eq "pending_at_end draft:true" true "$(last_field pending_at_end draft)"
assert_eq "ended mid-run: shelved with reason session_end" session_end "$(last_field draft_shelved reason)"
assert_eq "ended mid-run: one shelved file" 1 "$(ls "$PK"/*.md 2>/dev/null | wc -l | tr -d ' ')"
assert_match "ended mid-run: shelved draft is the answer" '^### late' "$(cat "$PK"/*.md)"
assert_eq "ended mid-run: no .stale sidecar" 0 "$(ls "$PK"/*.stale 2>/dev/null | wc -l | tr -d ' ')"
assert_eq "ended mid-run: no rerun" 1 "$(invocations)"
assert_eq "ended mid-run: sweep_ran result draft" draft "$(last_field sweep_ran result)"
assert_nofile "ended mid-run: draft_stale cleaned" "$D/draft_stale"
# the same, with Decisions changing too: shelved with a .stale sidecar, still no rerun
new_scenario; EXTRA_ENV+=(FAKE_CLAUDE_MODE=touch-ended-edit); PK="$CAP/shelved/dotfiles--feat-x"
sweep
assert_eq "ended+edited: no rerun (ended skips it)" 1 "$(invocations)"
assert_eq "ended+edited: shelved" 1 "$(ls "$PK"/*.md 2>/dev/null | wc -l | tr -d ' ')"
assert_eq "ended+edited: .stale sidecar" 1 "$(ls "$PK"/*.stale 2>/dev/null | wc -l | tr -d ' ')"
assert_eq "ended+edited: draft_shelved tagged stale" true "$(last_field draft_shelved stale)"
assert_nofile "ended+edited: draft not left behind" "$D/draft"

echo "# decisions extraction"
new_scenario
sweep
S="$(cat "$OUTDIR/stdin")"
assert_match "existing decisions present" 'EXISTING_DECISION_TEXT' "$S"
assert_nomatch "goal excluded" 'GOAL_SECTION_TEXT' "$S"
assert_nomatch "done excluded" 'DONE_SECTION_TEXT' "$S"
assert_match "NONE contract in prompt" 'NONE' "$S"

echo "# lock / race with hook-stop"
new_scenario; EXTRA_ENV=(FAKE_CLAUDE_MODE=draft)   # real 1s delay
sha1sum <"$FAKE_TASK" | cut -d' ' -f1 >"$D/taskhash"; printf '3\n' >"$D/unchanged"
STOPJSON='{"session_id":"sid-aaa","last_assistant_message":"nothing"}'
envv=(HOME="$H" XDG_STATE_HOME="$STATE" XDG_CONFIG_HOME="$CFG" PATH="$FAKEBIN:$PATH"
  FAKE_TASK="$FAKE_TASK" FAKE_CLAUDE_OUT="$OUTDIR" FAKE_ENDED_PATH="$D/ended" TMUX=fake,1,0 TMUX_PANE=%1)
jq -nc --arg tp "$TRANSCRIPT" '{session_id:"sid-aaa",transcript_path:$tp}' >"$H/sw.json"
printf '%s' "$STOPJSON" >"$H/st.json"
env "${envv[@]}" WB_CAPTURE_SWEEP_DELAY=1 FAKE_CLAUDE_MODE=draft "$REAL_BASH" "$SWEEP" <"$H/sw.json" >/dev/null 2>&1 &
p1=$!
env "${envv[@]}" "$REAL_BASH" "$CAPTURE" hook-stop <"$H/st.json" >/dev/null 2>&1 &
p2=$!
wait $p1 $p2
assert_file "concurrent: draft written" "$D/draft"
assert_eq "concurrent: counter reset after sweep" 0 "$(cat "$D/unchanged")"
assert_eq "concurrent: one sweep" 1 "$(invocations)"
assert_file "lock file" "$D/.lock"
# deterministic: the TEST holds the session lock, hooks start with zero delay,
# and must not touch the counter until it is released (a no-op flock fails this)
mk_hook_env() { # rebuild envv + payloads for the CURRENT scenario
  envv=(HOME="$H" XDG_STATE_HOME="$STATE" XDG_CONFIG_HOME="$CFG" PATH="$FAKEBIN:$PATH"
    FAKE_TASK="$FAKE_TASK" FAKE_CLAUDE_OUT="$OUTDIR" FAKE_ENDED_PATH="$D/ended" TMUX=fake,1,0 TMUX_PANE=%1)
  jq -nc --arg tp "$TRANSCRIPT" '{session_id:"sid-aaa",transcript_path:$tp}' >"$H/sw.json"
  printf '%s' "$STOPJSON" >"$H/st.json"
}
hold_lock() { # <secs> — hold <dir>/.lock in the background; returns once held
  rm -f "$H/held"
  flock "$D/.lock" "$REAL_BASH" -c ': >"$1"; sleep "$2"' _ "$H/held" "$1" &
  HOLDER=$!
  for _ in $(seq 1 100); do [ -e "$H/held" ] && break; sleep 0.05; done
  assert_file "test holds the lock" "$H/held"
}
new_scenario
sha1sum <"$FAKE_TASK" | cut -d' ' -f1 >"$D/taskhash"; printf '3\n' >"$D/unchanged"
mk_hook_env
hold_lock 2
env "${envv[@]}" "$REAL_BASH" "$CAPTURE" hook-stop <"$H/st.json" >/dev/null 2>&1 &
p2=$!
sleep 0.7
assert_eq "locked: hook-stop has not bumped the counter" 3 "$(cat "$D/unchanged")"
wait $HOLDER $p2
assert_eq "released: hook-stop bumped the counter" 4 "$(cat "$D/unchanged")"
new_scenario; mk_hook_env                 # unchanged=4 (>= sweep_every) from new_scenario
hold_lock 2
env "${envv[@]}" WB_CAPTURE_SWEEP_DELAY=0 FAKE_CLAUDE_MODE=draft "$REAL_BASH" "$SWEEP" <"$H/sw.json" >/dev/null 2>&1 &
p1=$!
sleep 0.7
assert_eq "locked: sweep has not reset the counter" 4 "$(cat "$D/unchanged")"
assert_eq "locked: sweep has not run the child" 0 "$(invocations)"
assert_nofile "locked: no draft yet" "$D/draft"
wait $HOLDER $p1
assert_eq "released: sweep reset the counter" 0 "$(cat "$D/unchanged")"
assert_eq "released: sweep ran the child" 1 "$(invocations)"
assert_file "released: draft written" "$D/draft"
# back-to-back: stop then sweep
new_scenario
sha1sum <"$FAKE_TASK" | cut -d' ' -f1 >"$D/taskhash"; printf '3\n' >"$D/unchanged"
run "$CAPTURE" hook-stop
assert_eq "stop bumped counter" 4 "$(cat "$D/unchanged")"
sweep
assert_eq "sweep then fires" draft "$(last_field sweep_ran result)"

echo "# the draft write runs under the session lock (so dismiss --expect cannot interleave)"
new_scenario; EXTRA_ENV+=(FAKE_CLAUDE_MODE=hold-lock)
sweep
sleep 2   # the backgrounded lock holder outlives the child; let it finish before asserting
assert_eq "draft had NOT landed while another process held the lock" absent "$(cat "$OUTDIR/draft_at_release" 2>/dev/null)"
assert_file "draft landed once the lock was released" "$D/draft"
assert_eq "result draft" draft "$(last_field sweep_ran result)"

[ "$fail" = 0 ] && echo "ALL PASSED" || { echo "FAILED"; exit 1; }
