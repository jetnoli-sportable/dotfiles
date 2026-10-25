#!/usr/bin/env bash
# Tests for wb-capture-sweep.sh (U4, store auto-capture; U2 of the capture-nudge
# rework): the async Stop-hook sweep and its forced checkpoint mode (the
# `wb-capture.sh sweep` verb). Drafts land on the shelf, one file per decision.
# tmux AND claude are faked by scripts on PATH — the real claude binary is never
# invoked.
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
  two-entries)  printf '### Chose B over A\n- decided: B\n- why: simpler\n\n### Chose D over C\n- decided: D\n- why: faster\n' ;;
  four-entries) printf 'Entries:\n'; for i in 1 2 3 4; do printf '### Entry %s\n- decided: X%s\n- why: y%s\n\n' "$i" "$i" "$i"; done ;;
  fail)  echo "boom" >&2; exit 1 ;;
  empty) : ;;
  sleep) exec sleep 5 ;;
  edit-task) # a decision is recorded while "thinking" (task file changes mid-call)
    sed -i '/^## Decisions/a ### Recorded meanwhile' "$FAKE_TASK"
    printf '### Chose B over A\n- decided: B\n' ;;
  edit-task-two) # as edit-task, answering two entries
    sed -i '/^## Decisions/a ### Recorded meanwhile' "$FAKE_TASK"
    printf '### Chose B over A\n- decided: B\n\n### Chose D over C\n- decided: D\n' ;;
  edit-handoffs) # a write OUTSIDE ## Decisions while "thinking"
    printf '## Handoffs\nsaved mid-call\n' >>"$FAKE_TASK"
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
  SH="$CAP/shelved/dotfiles--feat-x"
  OUTDIR="$H/claude-out"
  TRANSCRIPT="$H/t.jsonl"
  mk_transcript 'first question' 'first answer'
  printf '4\n' >"$D/unchanged"
  printf '%s\n' "$TRANSCRIPT" >"$D/transcript"     # what hook-stop/hook-prompt persist (KTD5)
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
    FAKE_ENDED_PATH="$D/ended" TMUX=fake,1,0 TMUX_PANE=%1)
  jq -nc --arg tp "$TRANSCRIPT" '{session_id:"sid-aaa",transcript_path:$tp,last_assistant_message:"hi"}' >"$H/stdin.json"
  OUT="$(env "${envv[@]}" "${EXTRA_ENV[@]}" "$REAL_BASH" "$script" "$@" <"$H/stdin.json" 2>"$H/stderr")"
  RC=$?
}
sweep() { run "$SWEEP"; }
events() { [ -f "$LOG" ] && jq -r .event "$LOG" | tr '\n' ' ' | sed 's/ $//' || echo ""; }
last_field() { jq -r --arg e "$1" "select(.event==\$e)|.$2" "$LOG" 2>/dev/null | tail -1; }
invocations() { [ -f "$OUTDIR/invocations" ] && wc -l <"$OUTDIR/invocations" | tr -d ' ' || echo 0; }
# argv_after <flag> — the fake claude's argument right after <flag>
argv_after() { /usr/bin/grep -x -A1 -F -- "[$1]" "$OUTDIR/argv" | sed -n '2s/^\[\(.*\)\]$/\1/p'; }
# shelf helpers: drafts live in $SH, one file per decision, never in $D/draft
shelf_files() { ls "$SH"/*.md 2>/dev/null; }
shelf_count() { shelf_files | wc -l | tr -d ' '; }
shelf_cat() { local f; for f in $(shelf_files); do cat "$f"; done; }
shelf_nth() { shelf_files | sed -n "${1}p"; }
# shelf_with <pattern> — the shelved file whose text matches (files of one sweep share a
# timestamp, so their sort order is not the draft order)
shelf_with() { local f; for f in $(shelf_files); do grep -qE -- "$1" "$f" && { echo "$f"; return; }; done; }
# no_tmp — leftover *.tmp.* files in the session dir or on the shelf
no_tmp() { { ls "$D"; ls "$SH" 2>/dev/null; } | grep '\.tmp\.' || true; }
# assert_shelved <n> <desc> — n files on the shelf and no session draft slot
assert_shelved() {
  assert_eq "$2" "$1" "$(shelf_count)"
  assert_nofile "$2: no session draft slot" "$D/draft"
}
set_conf() { mkdir -p "$CFG/wb"; printf '%s\n' "$@" >"$CFG/wb/capture.conf"; }

echo "# fires: the draft is shelved atomically as its own file"
new_scenario
sweep
assert_eq "exit 0" 0 "$RC"; assert_eq "silent stdout" "" "$OUT"
assert_shelved 1 "draft shelved"
assert_match "draft body" '^### Chose B over A' "$(shelf_cat)"
assert_eq "no tmp left" "" "$(no_tmp)"
assert_eq "draft_shelved then sweep_ran logged" "draft_shelved sweep_ran" "$(events)"
assert_eq "draft_shelved reason sweep" sweep "$(last_field draft_shelved reason)"
assert_eq "draft_shelved names its file" "$(basename "$(shelf_nth 1)")" "$(last_field draft_shelved draft)"
assert_eq "result draft" draft "$(last_field sweep_ran result)"
assert_eq "counter reset" 0 "$(cat "$D/unchanged")"
assert_eq "offset stored" 3 "$(cat "$D/sweep_offset")"

echo "# nothing found"
new_scenario; EXTRA_ENV+=(FAKE_CLAUDE_MODE=none)
sweep
assert_shelved 0 "no draft"
assert_eq "result none" none "$(last_field sweep_ran result)"
assert_eq "none: no entries field" null "$(last_field sweep_ran entries)"
assert_eq "counter reset" 0 "$(cat "$D/unchanged")"
new_scenario; EXTRA_ENV+=(FAKE_CLAUDE_MODE=none-padded)
sweep
assert_shelved 0 "padded NONE: no draft"
assert_eq "padded NONE: result none" none "$(last_field sweep_ran result)"
new_scenario; EXTRA_ENV+=(FAKE_CLAUDE_MODE=none-prose)
sweep
assert_shelved 0 "'None.': no draft"
assert_eq "'None.': result none" none "$(last_field sweep_ran result)"

echo "# refusal prose ending in a bare NONE line is none, not a draft"
new_scenario; EXTRA_ENV+=(FAKE_CLAUDE_MODE=none-refusal)
sweep
assert_shelved 0 "refusal+NONE: no draft"
assert_eq "refusal+NONE: result none" none "$(last_field sweep_ran result)"

echo "# NONE first then commentary, and decorated NONE, are none"
for m in none-first none-bold none-code; do
  new_scenario; EXTRA_ENV+=(FAKE_CLAUDE_MODE=$m)
  sweep
  assert_shelved 0 "$m: no draft"
  assert_eq "$m: result none" none "$(last_field sweep_ran result)"
done

echo "# prose with no heading and no NONE is invalid: retried once, then skipped"
new_scenario; EXTRA_ENV+=(FAKE_CLAUDE_MODE=prose-only)
sweep
assert_shelved 0 "prose-only: no draft"
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
assert_shelved 1 "preamble: draft written"
assert_eq "preamble: draft starts at ###" "### Chose B over A" "$(head -1 "$(shelf_nth 1)")"
assert_nomatch "preamble: text gone" 'Here is the entry' "$(shelf_cat)"
assert_eq "preamble: result draft" draft "$(last_field sweep_ran result)"

echo "# a valid entry that mentions none on a non-final line is still a draft"
new_scenario; EXTRA_ENV+=(FAKE_CLAUDE_MODE=draft-mentions-none)
sweep
assert_shelved 1 "mentions-none: draft written"
assert_eq "mentions-none: result draft" draft "$(last_field sweep_ran result)"

echo "# several entries in one answer: up to 3, each shelved as its own file"
new_scenario; EXTRA_ENV+=(FAKE_CLAUDE_MODE=two-entries)
sweep
assert_eq "two entries: result draft" draft "$(last_field sweep_ran result)"
assert_shelved 2 "two entries: two files"
assert_eq "two entries: one entry per file" "1 1" "$(for f in $(shelf_files); do grep -c '^### ' "$f"; done | tr '\n' ' ' | sed 's/ $//')"
assert_eq "two entries: sweep_ran logs entries 2" 2 "$(last_field sweep_ran entries)"
assert_match "two entries: first entry has its own file" 'decided: B' "$(cat "$(shelf_with 'Chose B')")"
assert_match "two entries: second entry has its own file" 'decided: D' "$(cat "$(shelf_with 'Chose D')")"
assert_nomatch "two entries: no mixing" 'decided: D' "$(cat "$(shelf_with 'Chose B')")"
assert_eq "two entries: two draft_shelved lines" 2 "$(jq -r 'select(.event=="draft_shelved")|.event' "$LOG" | wc -l | tr -d ' ')"
assert_eq "two entries: each draft_shelved names its own file" "$(for f in $(shelf_files); do basename "$f"; done | sort | tr '\n' ' ')" "$(jq -r 'select(.event=="draft_shelved")|.draft' "$LOG" | sort | tr '\n' ' ')"
assert_eq "two entries: every draft_shelved is reason sweep" sweep "$(jq -r 'select(.event=="draft_shelved")|.reason' "$LOG" | sort -u)"
assert_eq "two entries: files are distinct" 2 "$(shelf_files | sort -u | wc -l | tr -d ' ')"
new_scenario; EXTRA_ENV+=(FAKE_CLAUDE_MODE=four-entries)
sweep
assert_eq "four entries: result draft" draft "$(last_field sweep_ran result)"
assert_shelved 3 "four entries: exactly 3 files"
assert_eq "four entries: sweep_ran logs the 3 kept" 3 "$(last_field sweep_ran entries)"
assert_eq "four entries: preamble stripped" "### Entry 1" "$(head -1 "$(shelf_with 'Entry 1')")"
assert_match "four entries: third kept whole" 'why: y3' "$(cat "$(shelf_with 'Entry 3')")"
assert_nomatch "four entries: fourth dropped" 'Entry 4|X4|y4' "$(shelf_cat)"
assert_eq "four entries: third file ends at its body" "- why: y3" "$(tail -1 "$(shelf_with 'Entry 3')")"
new_scenario
sweep
assert_shelved 1 "one entry: one file"
assert_eq "one entry: sweep_ran logs entries 1" 1 "$(last_field sweep_ran entries)"
assert_match "prompt asks for one entry per decision, at most 3" 'one Decisions entry per unrecorded decision, at most 3' "$(tr '\n' ' ' <"$OUTDIR/stdin")"
assert_nomatch "prompt no longer asks for a single entry" 'single Decisions entry' "$(cat "$OUTDIR/stdin")"

echo "# rerun path parses the same way (preamble entry on both calls)"
new_scenario; EXTRA_ENV+=(FAKE_CLAUDE_SEQ=edit-task,preamble-draft)
sweep
assert_eq "rerun: two invocations" 2 "$(invocations)"
assert_eq "rerun: draft starts at ###" "### Chose B over A" "$(head -1 "$(shelf_nth 1)" 2>/dev/null)"

echo "# child invocation shape"
new_scenario
sweep
ARGV="$(cat "$OUTDIR/argv")"
assert_match "-p" '^\[-p\]$' "$ARGV"
assert_match "--model" '^\[--model\]$' "$ARGV"
assert_eq "default model: sonnet" sonnet "$(argv_after --model)"
assert_eq "--effort" medium "$(argv_after --effort)"
assert_eq "sweep_ran carries the default model" sonnet "$(last_field sweep_ran model)"
assert_eq "sweep_ran carries the default effort" medium "$(last_field sweep_ran effort)"
assert_match "--no-session-persistence" '^\[--no-session-persistence\]$' "$ARGV"
assert_match "--max-turns" '^\[--max-turns\]$' "$ARGV"
assert_match "max-turns 1" '^\[1\]$' "$ARGV"
assert_match "--tools" '^\[--tools\]$' "$ARGV"
assert_match "tools empty-string arg" '^\[\]$' "$ARGV"
assert_match "--strict-mcp-config (no MCP servers loaded)" '^\[--strict-mcp-config\]$' "$ARGV"
assert_match "--settings" '^\[--settings\]$' "$ARGV"
assert_match "hooks disabled in the child" '^\[\{"disableAllHooks":true\}\]$' "$ARGV"
assert_eq "env stripped/set" "SWEEP=1 TMUX=unset PANE=unset" "$(cat "$OUTDIR/env")"
assert_eq "cwd is capture root" "$(cd "$CAP" && pwd -P)" "$(cat "$OUTDIR/cwd")"

echo "# sweep_model / sweep_effort: config overrides, invalid values fall back"
new_scenario; set_conf sweep_model=claude-haiku-4.5 sweep_effort=high
sweep
assert_eq "conf model reaches the child" claude-haiku-4.5 "$(argv_after --model)"
assert_eq "conf effort reaches the child" high "$(argv_after --effort)"
assert_eq "sweep_ran logs the conf model" claude-haiku-4.5 "$(last_field sweep_ran model)"
assert_eq "sweep_ran logs the conf effort" high "$(last_field sweep_ran effort)"
for e in low medium high xhigh max; do
  new_scenario; set_conf "sweep_effort=$e"; sweep
  assert_eq "effort $e accepted" "$e" "$(argv_after --effort)"
done
for bad in 'sweep_model=-p' 'sweep_model=--tools' 'sweep_model=haiku;rm' 'sweep_model=a b' 'sweep_model=' 'sweep_model=$(x)' 'sweep_model=opus/4' 'sweep_effort=ultra' 'sweep_effort=' 'sweep_effort=HIGH' 'sweep_effort=high extra'; do
  new_scenario; set_conf "$bad"; sweep
  assert_eq "invalid [$bad]: model falls back" sonnet "$(argv_after --model)"
  assert_eq "invalid [$bad]: effort falls back" medium "$(argv_after --effort)"
done
new_scenario; set_conf sweep_model=opus sweep_effort=bogus; sweep
assert_eq "one valid key survives an invalid sibling (model)" opus "$(argv_after --model)"
assert_eq "one valid key survives an invalid sibling (effort)" medium "$(argv_after --effort)"
new_scenario; EXTRA_ENV+=(FAKE_CLAUDE_MODE=fail); set_conf sweep_model=opus
sweep
assert_eq "a failed run still logs model" opus "$(last_field sweep_ran model)"
assert_eq "a failed run still logs effort" medium "$(last_field sweep_ran effort)"

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
assert_shelved 0 "timeout: no draft"
assert_eq "timeout result" timeout "$(last_field sweep_ran result)"
assert_eq "timeout: counter reset" 0 "$(cat "$D/unchanged")"
assert_nofile "timeout: sweep_offset unchanged (content retried)" "$D/sweep_offset"
new_scenario; EXTRA_ENV+=(FAKE_CLAUDE_MODE=fail)
sweep
assert_shelved 0 "error: no draft"
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
new_scenario; printf 'legacy draft\n' >"$D/draft"
sweep
assert_eq "legacy slot: sweep still runs" 1 "$(invocations)"
assert_eq "legacy slot: the new draft is shelved" 1 "$(shelf_count)"
assert_eq "legacy slot: left untouched" "legacy draft" "$(cat "$D/draft")"
assert_eq "legacy slot: no draft_pending skip" "" "$(last_field sweep_skipped reason)"
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

echo "# stale draft: task file changed during the child call"
new_scenario; EXTRA_ENV+=(FAKE_CLAUDE_MODE=edit-task)
sweep
assert_shelved 1 "stale: draft still shelved"
assert_match "stale: draft body" '^### Chose B over A' "$(shelf_cat)"
assert_file "stale: .stale sidecar written" "$(shelf_nth 1).stale"
assert_eq "stale: re-snapshot entry count (Existing + first edit)" 2 "$(cat "$(shelf_nth 1).stale")"
assert_eq "stale: child ran twice (one rerun)" 2 "$(invocations)"
assert_eq "stale: rerun logged" true "$(last_field sweep_ran rerun)"
assert_eq "stale: no tmp left" "" "$(no_tmp)"
assert_eq "stale: draft_shelved then one sweep_ran" "draft_shelved sweep_ran" "$(events)"
assert_eq "stale: draft_shelved tagged stale" true "$(last_field draft_shelved stale)"
assert_eq "stale: result draft" draft "$(last_field sweep_ran result)"
assert_eq "stale: stale true" true "$(last_field sweep_ran stale)"

echo "# stale draft: unchanged task file -> no sidecar, log as before"
new_scenario
sweep
assert_shelved 1 "fresh: draft shelved"
assert_nofile "fresh: no .stale sidecar" "$(shelf_nth 1).stale"
assert_eq "fresh: sweep_ran line has exactly ts/sid/task/event/result/model/effort/entries" '["effort","entries","event","model","result","session_id","task","ts"]' "$(jq -c 'select(.event=="sweep_ran")|keys' "$LOG")"
assert_eq "fresh: no stale field" null "$(last_field sweep_ran stale)"
assert_eq "fresh: draft_shelved has no stale tag" null "$(last_field draft_shelved stale)"

echo "# stale draft: a changed task file with no draft result writes nothing stale"
new_scenario; EXTRA_ENV+=(FAKE_CLAUDE_MODE=none)
sweep
assert_shelved 0 "none: nothing shelved"

echo "# stale draft: count is of the snapshot, task without Decisions entries"
new_scenario; printf '# task\n## Decisions\n## Done\n' >"$FAKE_TASK"; EXTRA_ENV+=(FAKE_CLAUDE_MODE=edit-task)
sweep
assert_eq "empty section: count of the re-snapshot" 1 "$(cat "$(shelf_nth 1).stale")"

echo "# stale draft: every file of a multi-entry stale answer carries the sidecar"
new_scenario; EXTRA_ENV+=(FAKE_CLAUDE_SEQ=edit-task,edit-task-two)
sweep
assert_shelved 2 "stale multi: two files"
assert_eq "stale multi: both sidecars hold the re-snapshot count" "2 2" "$(for f in $(shelf_files); do cat "$f.stale"; done | tr '\n' ' ' | sed 's/ $//')"
assert_eq "stale multi: both draft_shelved tagged stale" "true true" "$(jq -r 'select(.event=="draft_shelved")|.stale' "$LOG" | tr '\n' ' ' | sed 's/ $//')"

echo "# rerun: write outside ## Decisions during the child run is NOT stale"
new_scenario; EXTRA_ENV+=(FAKE_CLAUDE_MODE=edit-handoffs)
sweep
assert_shelved 1 "handoffs: draft written"
assert_nofile "handoffs: not stale" "$(shelf_nth 1).stale"
assert_eq "handoffs: child called once" 1 "$(invocations)"
assert_eq "handoffs: no stale field" null "$(last_field sweep_ran stale)"
assert_eq "handoffs: no rerun field" null "$(last_field sweep_ran rerun)"

echo "# rerun: Decisions edited in run 1 only -> rerun, draft fresh"
new_scenario; EXTRA_ENV+=(FAKE_CLAUDE_SEQ=edit-task,draft)
sweep
assert_eq "rerun: child called twice" 2 "$(invocations)"
assert_shelved 1 "rerun: draft written"
assert_nofile "rerun: not stale" "$(shelf_nth 1).stale"
assert_eq "rerun: logged" true "$(last_field sweep_ran rerun)"
assert_eq "rerun: no stale field" null "$(last_field sweep_ran stale)"
assert_eq "rerun: result draft" draft "$(last_field sweep_ran result)"
assert_match "rerun: second prompt carries the recorded entry" 'Recorded meanwhile' "$(cat "$OUTDIR/stdin")"
assert_eq "rerun: one draft_shelved, one sweep_ran" "draft_shelved sweep_ran" "$(events)"

echo "# rerun: rerun answers NONE -> no draft"
new_scenario; EXTRA_ENV+=(FAKE_CLAUDE_SEQ=edit-task,none)
sweep
assert_eq "rerun-none: child called twice" 2 "$(invocations)"
assert_shelved 0 "rerun-none: no draft"
assert_eq "rerun-none: result none" none "$(last_field sweep_ran result)"
assert_eq "rerun-none: rerun logged" true "$(last_field sweep_ran rerun)"
assert_eq "rerun-none: offset advanced" 3 "$(cat "$D/sweep_offset")"

echo "# rerun: section changes during both runs -> stale draft (re-snapshot count)"
new_scenario; EXTRA_ENV+=(FAKE_CLAUDE_SEQ=edit-task,edit-task)
sweep
assert_eq "both: child called twice, never thrice" 2 "$(invocations)"
assert_shelved 1 "both: draft written"
assert_eq "both: the .stale sidecar is the re-snapshot count" 2 "$(cat "$(shelf_nth 1).stale")"
assert_eq "both: rerun true" true "$(last_field sweep_ran rerun)"
assert_eq "both: stale true" true "$(last_field sweep_ran stale)"

echo "# rerun: rerun times out / errors -> no draft, counts as a failure"
new_scenario; EXTRA_ENV+=(FAKE_CLAUDE_SEQ=edit-task,sleep); set_conf sweep_timeout=1
sweep
assert_shelved 0 "rerun-timeout: no draft"
assert_eq "rerun-timeout: result" timeout "$(last_field sweep_ran result)"
assert_eq "rerun-timeout: rerun logged" true "$(last_field sweep_ran rerun)"
assert_eq "rerun-timeout: failure counted" 1 "$(cat "$D/sweep_failures")"
assert_nofile "rerun-timeout: offset not advanced" "$D/sweep_offset"
new_scenario; EXTRA_ENV+=(FAKE_CLAUDE_SEQ=edit-task,fail)
sweep
assert_shelved 0 "rerun-error: no draft"
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
assert_shelved 0 "tool-only: no draft"
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

echo "# excerpt: injected skill text and command wrappers don't crowd out real turns"
new_scenario
{
  # ~15 KB of real conversation since the last sweep, oldest turn marked
  for i in $(seq 1 15); do
    pad="$(head -c 1000 /dev/zero | tr '\0' 'y')"
    jq -nc --arg t "turn$i $pad" '{type:"user",message:{role:"user",content:$t}}'
  done
  jq -nc '{type:"user",isMeta:true,message:{role:"user",content:"<local-command-caveat>CAVEAT_TEXT</local-command-caveat>"}}'
  jq -nc '{type:"user",message:{role:"user",content:"<command-message>wb-save</command-message>\n<command-name>/wb-save</command-name>\n<command-args>CMD_ARGS_TEXT</command-args>"}}'
  # the invoked skill's SKILL.md, injected as an isMeta user message, larger than the budget
  skill="$(head -c 30000 /dev/zero | tr '\0' 's')"
  jq -nc --arg t "Base directory for this skill: SKILL_BODY_MARK $skill" '{type:"user",isMeta:true,message:{role:"user",content:[{type:"text",text:$t}]}}'
} >"$TRANSCRIPT"
sed -i '1s/turn1 /EARLY_TURN_MARK /' "$TRANSCRIPT"
sweep
S="$(cat "$OUTDIR/stdin")"
assert_match "earliest real turn still reaches the prompt" 'EARLY_TURN_MARK' "$S"
assert_nomatch "isMeta skill text dropped" 'SKILL_BODY_MARK' "$S"
assert_nomatch "local-command caveat dropped" 'CAVEAT_TEXT' "$S"
assert_nomatch "no truncation marker" 'earlier turns truncated' "$S"
assert_match "command wrapper collapses to the command as typed" 'USER: /wb-save CMD_ARGS_TEXT' "$S"
assert_nomatch "no command wrapper tags" '<command-(name|message|args)>' "$S"

echo "# excerpt: [wb-propagate] cross-session messages kept as RECEIVED lines (no origin: older Claude Code)"
new_scenario
{
  jq -nc '{type:"user",message:{role:"user",content:"a real question"}}'
  jq -nc '{type:"user",isMeta:true,message:{role:"user",content:"Another Claude session sent a message:\n<cross-session-message from=\"uds:/run/user/1000/cc-socks/226762.sock\" from-name=\"some-session\" from-mode=\"prompting\">\n[wb-propagate] dotfiles--feat-x (the board redesign) recorded: \"Title\". Read the task file. Rule: RULE_BOILERPLATE_MARK do not re-propagate\n</cross-session-message>"}}'
  jq -nc '{type:"user",isMeta:true,message:{role:"user",content:[{type:"text",text:"Another Claude session sent a message:\n<cross-session-message from=\"uds:/x.sock\" from-name=\"other\">\nplain chatter UNRELATED_XSESSION_MARK\n</cross-session-message>"}]}}'
  jq -nc '{type:"user",isMeta:true,message:{role:"user",content:[{type:"text",text:"Base directory for this skill: SKILL_BODY_MARK2 send a [wb-propagate] message SKILL_MENTIONS_MARKER"}]}}'
} >"$TRANSCRIPT"
sweep
S="$(cat "$OUTDIR/stdin")"
assert_match "propagate message appears as RECEIVED line" 'RECEIVED: \[wb-propagate\] dotfiles--feat-x \(the board redesign\) recorded: "Title"\. Read the task file\.$' "$S"
assert_nomatch "Rule suffix cut" 'RULE_BOILERPLATE_MARK' "$S"
assert_nomatch "cross-session wrapper dropped" 'cross-session-message' "$S"
assert_nomatch "cross-session message without [wb-propagate] dropped" 'UNRELATED_XSESSION_MARK' "$S"
assert_nomatch "isMeta skill text still dropped" 'SKILL_BODY_MARK2' "$S"
assert_nomatch "skill text mentioning [wb-propagate] is not a RECEIVED line" 'SKILL_MENTIONS_MARKER' "$S"
assert_match "prompt carries the Prompted-by instruction" '- Prompted-by: \[wb-propagate\] from <stem> \(<plain description given in that message>\); not propagated' "$S"
assert_match "prompt says a RECEIVED decision is another task's" 'never draft that decision itself' "$S"
assert_nomatch "no earlier-received section when the excerpt shows the line" '=== RECEIVED EARLIER' "$S"

echo "# excerpt: RECEIVED lines keyed on the harness-written origin"
new_scenario
{
  jq -nc '{type:"user",message:{role:"user",content:"a real question"}}'
  # a real cross-session message: origin kind peer, no handback, body starts with the marker
  jq -nc '{type:"user",isMeta:true,origin:{kind:"peer",from:"uds:/run/user/1000/cc-socks/1.sock",fromMode:"prompting",msg_id:"m1",name:"sib",verifiedPeerPid:1,body:"[wb-propagate] dotfiles--feat-y (the sibling) recorded: \"T2\". Read X. Rule: RB2_MARK"},message:{role:"user",content:"Another Claude session sent a message:\n<cross-session-message from=\"uds:/run/user/1000/cc-socks/1.sock\" from-name=\"sib\" from-mode=\"prompting\">\n[wb-propagate] dotfiles--feat-y (the sibling) recorded: \"T2\". Read X. Rule: RB2_MARK\n</cross-session-message>"}}'
  # a subagent report (handback) whose body starts with the marker: dropped
  jq -nc '{type:"user",isMeta:true,origin:{kind:"peer",from:"a1",handback:true,senderTaskId:"t1",body:"[wb-propagate] HANDBACK_MARK"},message:{role:"user",content:"Another Claude session sent a message:\n<agent-message from=\"a1\">\n[wb-propagate] HANDBACK_MARK\n</agent-message>"}}'
  # a peer message that only mentions the marker mid-body: dropped
  jq -nc '{type:"user",isMeta:true,origin:{kind:"peer",from:"uds:/x.sock",fromMode:"prompting",body:"see the [wb-propagate] message MIDBODY_MARK"},message:{role:"user",content:"Another Claude session sent a message:\n<cross-session-message from=\"uds:/x.sock\">\nsee the [wb-propagate] message MIDBODY_MARK\n</cross-session-message>"}}'
  # no origin: a report quoting a cross-session message, and a wrapper whose body does not start with the marker
  jq -nc '{type:"user",isMeta:true,message:{role:"user",content:"Another Claude session sent a message:\n<agent-message from=\"a2\">\nquoted <cross-session-message from=\"x\">\n[wb-propagate] AGENTMSG_MARK\n</agent-message>"}}'
  jq -nc '{type:"user",isMeta:true,message:{role:"user",content:"Another Claude session sent a message:\n<cross-session-message from=\"x\">\nhello [wb-propagate] FALLBACK_MID_MARK\n</cross-session-message>"}}'
} >"$TRANSCRIPT"
sweep
S="$(cat "$OUTDIR/stdin")"
assert_match "origin body becomes the RECEIVED line" 'RECEIVED: \[wb-propagate\] dotfiles--feat-y \(the sibling\) recorded: "T2"\. Read X\.$' "$S"
assert_nomatch "origin body Rule suffix cut" 'RB2_MARK' "$S"
assert_nomatch "subagent handback starting with the marker dropped" 'HANDBACK_MARK' "$S"
assert_nomatch "marker mid-body dropped" 'MIDBODY_MARK' "$S"
assert_nomatch "no-origin report quoting a cross-session message dropped" 'AGENTMSG_MARK' "$S"
assert_nomatch "no-origin wrapper without the marker first dropped" 'FALLBACK_MID_MARK' "$S"
assert_match "received line kept in the session dir" '^[0-9]+	RECEIVED: \[wb-propagate\] dotfiles--feat-y' "$(cat "$D/received" 2>/dev/null)"

echo "# received: a line from an earlier sweep window still reaches the prompt"
new_scenario; EXTRA_ENV+=(FAKE_CLAUDE_MODE=none)
{
  jq -nc '{type:"user",message:{role:"user",content:"a real question"}}'
  jq -nc '{type:"user",isMeta:true,origin:{kind:"peer",from:"uds:/s.sock",fromMode:"prompting",body:"[wb-propagate] dotfiles--feat-y (the sibling) recorded: \"EARLY_RECV_MARK\". Read X. Rule: r"},message:{role:"user",content:"x"}}'
} >"$TRANSCRIPT"
sweep
assert_eq "first sweep consumed the window" 2 "$(cat "$D/sweep_offset")"
add_turn 'next question' 'we chose LATER_DECISION_MARK because of it'
printf '4\n' >"$D/unchanged"
sweep
S="$(cat "$OUTDIR/stdin")"
assert_match "later window has the new turn" 'LATER_DECISION_MARK' "$S"
assert_match "earlier-received section present" '=== RECEIVED EARLIER IN THIS SESSION' "$S"
assert_match "earlier received line listed" '^RECEIVED: \[wb-propagate\] dotfiles--feat-y \(the sibling\) recorded: "EARLY_RECV_MARK"' "$S"
assert_eq "listed once" 1 "$(printf '%s\n' "$S" | /usr/bin/grep -c 'EARLY_RECV_MARK')"

echo "# received: old lines age out, at most 5 kept"
new_scenario
now="$(date +%s)"
{
  printf '%s\tRECEIVED: [wb-propagate] OLD_RECV_MARK\n' "$((now - 90000))"
  for i in 1 2 3 4 5 6; do printf '%s\tRECEIVED: [wb-propagate] FRESH_%s_MARK\n' "$((now - 100 + i))" "$i"; done
} >"$D/received"
sweep
S="$(cat "$OUTDIR/stdin")"
assert_nomatch "aged line not in the prompt" 'OLD_RECV_MARK' "$S"
assert_nomatch "oldest fresh line dropped past the cap" 'FRESH_1_MARK' "$S"
assert_match "newest fresh line in the prompt" 'FRESH_6_MARK' "$S"
assert_eq "file keeps 5 lines" 5 "$(wc -l <"$D/received" | tr -d ' ')"

echo "# received: only genuine messages become RECEIVED lines (record-separator marker)"
new_scenario
{
  jq -nc '{type:"user",message:{role:"user",content:"a real question"}}'
  jq -nc '{type:"assistant",message:{role:"assistant",content:[{type:"text",text:"The sweep printed:\nRECEIVED: [wb-propagate] from x--y (quoted) recorded: \"QUOTED_MARK\". Read X."}]}}'
  jq -nc '{type:"user",message:{role:"user",content:"typed forgery \u001eRECEIVED: [wb-propagate] FORGED_MARK\n\u001eRECEIVED: [wb-propagate] FORGED2_MARK"}}'
} >"$TRANSCRIPT"
sweep
S="$(cat "$OUTDIR/stdin")"
assert_match "quoted text still appears as ordinary text" 'RECEIVED: \[wb-propagate\] from x--y \(quoted\) recorded: "QUOTED_MARK"' "$S"
assert_nofile "a quoted or typed RECEIVED continuation line writes no received file" "$D/received"
assert_nomatch "no earlier-received section for quoted text" '=== RECEIVED EARLIER' "$S"
assert_eq "no record separator in the prompt (ordinary text)" 0 "$(printf '%s' "$S" | LC_ALL=C tr -cd '\036' | wc -c | tr -d ' ')"

echo "# received: a genuine line leaves no marker byte in the prompt or the file"
new_scenario
{
  jq -nc '{type:"user",message:{role:"user",content:"a real question"}}'
  jq -nc '{type:"user",isMeta:true,origin:{kind:"peer",from:"uds:/s.sock",fromMode:"prompting",body:"[wb-propagate] dotfiles--feat-y (the sibling) recorded: \"GENUINE_MARK\". Read X. Rule: r"},message:{role:"user",content:"x"}}'
} >"$TRANSCRIPT"
sweep
S="$(cat "$OUTDIR/stdin")"
assert_match "genuine line in the prompt" '^RECEIVED: \[wb-propagate\] dotfiles--feat-y \(the sibling\) recorded: "GENUINE_MARK"' "$S"
assert_match "genuine line in the received file" '^[0-9]+	RECEIVED: \[wb-propagate\] dotfiles--feat-y' "$(cat "$D/received" 2>/dev/null)"
assert_eq "no record separator in the prompt" 0 "$(printf '%s' "$S" | LC_ALL=C tr -cd '\036' | wc -c | tr -d ' ')"
assert_eq "no record separator in the received file" 0 "$(LC_ALL=C tr -cd '\036' <"$D/received" | wc -c | tr -d ' ')"

echo "# received: a sweep with nothing new leaves the received file intact"
before="$(cat "$D/received")"
printf '4\n' >"$D/unchanged"
sweep
assert_eq "received file unchanged by a nothing-new sweep" "$before" "$(cat "$D/received" 2>/dev/null)"

echo "# received: the same genuine line in two consecutive sweeps is stored once"
new_scenario; EXTRA_ENV+=(FAKE_CLAUDE_MODE=none)
RECV='{type:"user",isMeta:true,origin:{kind:"peer",from:"uds:/s.sock",fromMode:"prompting",body:"[wb-propagate] dotfiles--feat-y (the sibling) recorded: \"TWICE_MARK\". Read X. Rule: r"},message:{role:"user",content:"x"}}'
{
  jq -nc '{type:"user",message:{role:"user",content:"a real question"}}'
  jq -nc "$RECV"
} >"$TRANSCRIPT"
sweep
jq -nc "$RECV" >>"$TRANSCRIPT"
add_turn 'more' 'more answer'
printf '4\n' >"$D/unchanged"
sweep
assert_eq "same line stored once across two sweeps" 1 "$(/usr/bin/grep -c 'TWICE_MARK' "$D/received")"

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
assert_shelved 0 "ended: no draft"
new_scenario; EXTRA_ENV+=(FAKE_CLAUDE_MODE=touch-ended)
sweep
PK="$CAP/shelved/dotfiles--feat-x"
assert_nofile "ended mid-run: nothing left in the session dir" "$D/draft"
assert_eq "ended mid-run: no tmp" "" "$(ls "$D" | grep 'tmp' || true)"
assert_eq "ended mid-run: logs (no pending_at_end)" "draft_shelved sweep_ran" "$(events)"
assert_eq "ended mid-run: shelved with reason sweep" sweep "$(last_field draft_shelved reason)"
assert_eq "ended mid-run: one shelved file" 1 "$(ls "$PK"/*.md 2>/dev/null | wc -l | tr -d ' ')"
assert_match "ended mid-run: shelved draft is the answer" '^### late' "$(cat "$PK"/*.md)"
assert_eq "ended mid-run: no .stale sidecar" 0 "$(ls "$PK"/*.stale 2>/dev/null | wc -l | tr -d ' ')"
assert_eq "ended mid-run: no rerun" 1 "$(invocations)"
assert_eq "ended mid-run: sweep_ran result draft" draft "$(last_field sweep_ran result)"
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
assert_shelved 1 "concurrent: draft written"
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
assert_shelved 0 "locked: no draft yet"
wait $HOLDER $p1
assert_eq "released: sweep reset the counter" 0 "$(cat "$D/unchanged")"
assert_eq "released: sweep ran the child" 1 "$(invocations)"
assert_shelved 1 "released: draft written"
# back-to-back: stop then sweep
new_scenario
sha1sum <"$FAKE_TASK" | cut -d' ' -f1 >"$D/taskhash"; printf '3\n' >"$D/unchanged"
run "$CAPTURE" hook-stop
assert_eq "stop bumped counter" 4 "$(cat "$D/unchanged")"
sweep
assert_eq "sweep then fires" draft "$(last_field sweep_ran result)"

echo "# the prompt names what is already drafted or already rejected (R6)"
stamp() { date -d "$1" +%Y%m%dT%H%M%S; }   # stamp '3 days ago'
RES_DIR() { echo "$CAP/resolved/dotfiles--feat-x"; }
# section <title> — the body of one labelled prompt section the fake claude received
section() { awk -v t="=== $1" 'index($0, t) == 1 { f = 1; next } /^===/ { f = 0 } f' "$OUTDIR/stdin"; }
new_scenario; mkdir -p "$SH" "$CAP/shelved/other--task"
printf '### Waiting one\n- decided: W1\n' >"$SH/20261020T100000-sid-old1.md"
printf '### Waiting two\n- decided: W2\n' >"$SH/20261021T100000-sid-old2.md"
printf '### Another task waiting\n- decided: O\n' >"$CAP/shelved/other--task/20261020T100000-sid-old3.md"
sweep
assert_match "drafted section is labelled" 'ALREADY DRAFTED, AWAITING REVIEW \(do not draft these again\)' "$(cat "$OUTDIR/stdin")"
assert_match "drafted section lists the first waiting heading" 'Waiting one' "$(section 'ALREADY DRAFTED')"
assert_match "drafted section lists the second waiting heading" 'Waiting two' "$(section 'ALREADY DRAFTED')"
assert_nomatch "another task's shelf is not listed" 'Another task waiting' "$(cat "$OUTDIR/stdin")"
assert_nomatch "no rejected section when nothing was dismissed" 'ALREADY REVIEWED AND REJECTED' "$(cat "$OUTDIR/stdin")"
assert_match "the recorded decisions are still in the prompt" 'EXISTING_DECISION_TEXT' "$(cat "$OUTDIR/stdin")"
new_scenario; mkdir -p "$(RES_DIR)"
printf '### Recently rejected\n- decided: R1\n' >"$(RES_DIR)/$(stamp '3 days ago')-shelved_dismissed-20261001T100000-sid-a.md"
printf '### Long ago rejected\n- decided: R2\n' >"$(RES_DIR)/$(stamp '20 days ago')-shelved_dismissed-20261001T100001-sid-b.md"
printf '### Accepted heading\n- decided: A1\n' >"$(RES_DIR)/$(stamp '1 day ago')-shelved_accepted-20261001T100002-sid-c.md"
printf '### Stale sidecar text\n' >"$(RES_DIR)/$(stamp '2 days ago')-shelved_dismissed-20261001T100003-sid-d.md.stale"
sweep
assert_match "rejected section is labelled" 'ALREADY REVIEWED AND REJECTED \(do not draft these again\)' "$(cat "$OUTDIR/stdin")"
assert_eq "rejected section holds the 3-day-old dismissal only" "- Recently rejected" "$(section 'ALREADY REVIEWED' | /usr/bin/grep -v '^$')"
assert_nomatch "the 20-day-old dismissal is not listed" 'Long ago rejected' "$(cat "$OUTDIR/stdin")"
assert_nomatch "an accepted draft is not listed" 'Accepted heading' "$(cat "$OUTDIR/stdin")"
assert_nomatch "no drafted section when the shelf is empty" 'ALREADY DRAFTED' "$(cat "$OUTDIR/stdin")"
new_scenario
sweep
assert_nomatch "an empty shelf and archive add no section" 'ALREADY (DRAFTED|REVIEWED)' "$(cat "$OUTDIR/stdin")"

echo "# forced sweep (wb-capture.sh sweep): runs below the cadence, one result line, exit 0"
vsweep() { run "$CAPTURE" sweep; }
new_scenario; printf '3\n' >"$D/unchanged"
vsweep
assert_eq "three quiet turns: drafted 1" "drafted 1" "$OUT"
assert_eq "exit 0" 0 "$RC"
assert_eq "the model was asked once" 1 "$(invocations)"
assert_eq "one file on the shelf" 1 "$(shelf_count)"
assert_nofile "no session draft slot" "$D/draft"
assert_eq "the quiet-turn counter is left alone" 3 "$(cat "$D/unchanged")"
assert_eq "sweep_ran result draft" draft "$(last_field sweep_ran result)"
vsweep
assert_eq "run again with nothing new: nothing new" "nothing new" "$OUT"
assert_eq "nothing new: no second model call" 1 "$(invocations)"
new_scenario; printf '3\n' >"$D/sweep_offset"
vsweep
assert_eq "nothing written since sweep_offset: nothing new" "nothing new" "$OUT"
assert_eq "nothing new: exit 0" 0 "$RC"
assert_eq "nothing new: no model call" 0 "$(invocations)"
assert_eq "nothing new: nothing shelved" 0 "$(shelf_count)"
new_scenario; EXTRA_ENV+=(FAKE_CLAUDE_MODE=none)
vsweep
assert_eq "model says NONE: none" "none" "$OUT"
assert_eq "none: sweep_ran result none" none "$(last_field sweep_ran result)"
new_scenario; EXTRA_ENV+=(FAKE_CLAUDE_MODE=two-entries)
vsweep
assert_eq "two entries: drafted 2" "drafted 2" "$OUT"
assert_eq "two entries: exactly one stdout line" 1 "$(printf '%s\n' "$OUT" | wc -l | tr -d ' ')"
assert_eq "two entries: two files" 2 "$(shelf_count)"
new_scenario; EXTRA_ENV+=(FAKE_CLAUDE_MODE=fail)
vsweep
assert_eq "model error: failed: error" "failed: error" "$OUT"; assert_eq "model error: exit 0" 0 "$RC"
new_scenario; EXTRA_ENV+=(FAKE_CLAUDE_MODE=prose-only)
vsweep
assert_eq "contract violation: failed: invalid" "failed: invalid" "$OUT"
new_scenario; mkdir -p "$CAP"; : >"$CAP/shelved"   # shelved/ is a plain file: nothing can be shelved
vsweep
assert_eq "shelving fails: failed: error" "failed: error" "$OUT"; assert_eq "shelving fails: exit 0" 0 "$RC"
assert_nofile "shelving fails: offset not advanced (content retried)" "$D/sweep_offset"

echo "# forced sweep: guards print a skipped line, make no model call, exit 0"
new_scenario; : >"$D/muted"
vsweep
assert_eq "muted: skipped: muted" "skipped: muted" "$OUT"; assert_eq "muted: exit 0" 0 "$RC"
assert_eq "muted: no model call" 0 "$(invocations)"
new_scenario; set_conf sweep=off
vsweep
assert_eq "sweep=off: skipped: off" "skipped: off" "$OUT"; assert_eq "sweep=off: no model call" 0 "$(invocations)"
new_scenario; mkdir -p "$STATE/wb"; : >"$STATE/wb/disable-capture"
vsweep
assert_eq "kill switch: skipped: off" "skipped: off" "$OUT"; assert_eq "kill switch: no model call" 0 "$(invocations)"
new_scenario; EXTRA_ENV+=(WB_CAPTURE_SWEEP=1)
vsweep
assert_eq "WB_CAPTURE_SWEEP: skipped: off" "skipped: off" "$OUT"; assert_eq "WB_CAPTURE_SWEEP: no model call" 0 "$(invocations)"
new_scenario; EXTRA_ENV+=(FAKE_SID=)
vsweep
assert_eq "no capture session on the pane: skipped: no session" "skipped: no session" "$OUT"
assert_eq "no session: exit 0" 0 "$RC"; assert_eq "no session: no model call" 0 "$(invocations)"
new_scenario; EXTRA_ENV+=(FAKE_TASK=)
vsweep
assert_eq "no @task: skipped: no session" "skipped: no session" "$OUT"
new_scenario; rm -f "$D/transcript"
vsweep
assert_eq "no persisted transcript: skipped: no transcript" "skipped: no transcript" "$OUT"
assert_eq "no transcript: exit 0" 0 "$RC"
new_scenario; printf '%s\n' "$H/gone.jsonl" >"$D/transcript"
vsweep
assert_eq "unreadable transcript: skipped: no transcript" "skipped: no transcript" "$OUT"
new_scenario; EXTRA_ENV+=(TMUX=)
vsweep
assert_eq "outside tmux: skipped: no session" "skipped: no session" "$OUT"

echo "# forced sweep: the failure backoff is ignored, the sweep still runs"
new_scenario; printf '3\n' >"$D/sweep_failures"
vsweep
assert_eq "backoff active: drafted 1" "drafted 1" "$OUT"
assert_eq "backoff active: the model was asked" 1 "$(invocations)"
assert_nofile "a successful forced run resets the failure count" "$D/sweep_failures"
new_scenario; EXTRA_ENV+=(FAKE_CLAUDE_MODE=fail)
vsweep
assert_eq "a forced failure counts toward the async backoff" 1 "$(cat "$D/sweep_failures")"

echo "# forced sweep: transcript and task come from the session dir, never from stdin"
new_scenario
printf '{"type":"user","message":{"role":"user","content":"FROM_SESSION_DIR_TRANSCRIPT"}}\n' >"$H/persisted.jsonl"
printf '%s\n' "$H/persisted.jsonl" >"$D/transcript"
vsweep    # run's stdin payload names the fixture transcript; it must be ignored
assert_eq "drafted from the persisted transcript" "drafted 1" "$OUT"
assert_match "the excerpt is the persisted transcript" 'FROM_SESSION_DIR_TRANSCRIPT' "$(cat "$OUTDIR/stdin")"
assert_nomatch "stdin's transcript_path is ignored" 'first answer' "$(cat "$OUTDIR/stdin")"
new_scenario; printf '%s\n' "$FAKE_TASK" >"$D/taskpath"
run "$SWEEP" --forced sid-aaa
assert_eq "script direct: task and transcript from the session dir" "drafted 1" "$OUT"
assert_eq "script direct: shelved under the task's stem" 1 "$(shelf_count)"
new_scenario; rm -f "$D/transcript"; mk_transcript 'arg question' 'ARG_TRANSCRIPT_TEXT'
run "$SWEEP" --forced sid-aaa "$FAKE_TASK" "$TRANSCRIPT"
assert_eq "script direct: transcript from an argument" "drafted 1" "$OUT"
assert_match "script direct: the argument's transcript was used" 'ARG_TRANSCRIPT_TEXT' "$(cat "$OUTDIR/stdin")"
new_scenario
run "$SWEEP" --forced sid-aaa
assert_eq "script direct with no task anywhere: skipped: no session" "skipped: no session" "$OUT"
run "$SWEEP" --forced bad/sid "$FAKE_TASK"
assert_eq "script direct with an unsafe session id: skipped: no session" "skipped: no session" "$OUT"
run "$SWEEP" --forced sid-zzz "$FAKE_TASK"
assert_eq "script direct with an unknown session: skipped: no session" "skipped: no session" "$OUT"
new_scenario
mkfifo "$H/fifo"; exec 7<>"$H/fifo"      # a stdin that never delivers: reading it would block
envv=(HOME="$H" XDG_STATE_HOME="$STATE" XDG_CONFIG_HOME="$CFG" PATH="$FAKEBIN:$PATH" FAKE_TASK="$FAKE_TASK"
  FAKE_CLAUDE_OUT="$OUTDIR" TMUX=fake,1,0 TMUX_PANE=%1 FAKE_CLAUDE_MODE=draft)
OUT="$(timeout 20 env "${envv[@]}" "$REAL_BASH" "$SWEEP" --forced sid-aaa "$FAKE_TASK" <&7 2>/dev/null)"; RC=$?
exec 7>&-
assert_eq "forced never reads stdin: finished, not timed out" "0:drafted 1" "$RC:$OUT"

echo "# forced sweep: the child timeout holds, on the run and on its rerun (failed: timeout)"
new_scenario; EXTRA_ENV+=(FAKE_CLAUDE_MODE=sleep); set_conf sweep_timeout=1
t0=$SECONDS; vsweep; t1=$((SECONDS - t0))
assert_eq "run times out: failed: timeout" "failed: timeout" "$OUT"; assert_eq "run times out: exit 0" 0 "$RC"
[ "$t1" -lt 30 ] && ok "run timeout finished in ${t1}s" || bad "run timeout took ${t1}s"
echo "       (forced timeout test, run only: ${t1}s)"
new_scenario; EXTRA_ENV+=(FAKE_CLAUDE_SEQ=edit-task,sleep); set_conf sweep_timeout=1
t0=$SECONDS; vsweep; t2=$((SECONDS - t0))
assert_eq "rerun times out too: failed: timeout" "failed: timeout" "$OUT"; assert_eq "rerun times out: exit 0" 0 "$RC"
assert_eq "rerun times out: both calls were made" 2 "$(invocations)"
assert_eq "rerun times out: nothing shelved" 0 "$(shelf_count)"
[ "$t2" -lt 30 ] && ok "run+rerun timeout finished in ${t2}s" || bad "run+rerun timeout took ${t2}s"
echo "       (forced run + rerun timeout test: ${t2}s; worst case at the default 60s is 120s)"

echo "# forced sweep: the stale rerun path shelves with sidecars"
new_scenario; EXTRA_ENV+=(FAKE_CLAUDE_SEQ=edit-task,edit-task-two)
vsweep
assert_eq "stale rerun: drafted 2" "drafted 2" "$OUT"
assert_eq "stale rerun: both files carry the re-snapshot count" "2 2" "$(for f in $(shelf_files); do cat "$f.stale"; done | tr '\n' ' ' | sed 's/ $//')"

[ "$fail" = 0 ] && echo "ALL PASSED" || { echo "FAILED"; exit 1; }
