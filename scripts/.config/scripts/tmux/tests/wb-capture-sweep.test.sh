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
  show) case "$*" in *@task*) printf '%s\n' "${FAKE_TASK:-}" ;; esac ;;
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
case "${FAKE_CLAUDE_MODE:-draft}" in
  draft) printf '### Chose B over A\n- decided: B\n- rejected: A\n- why: simpler\n' ;;
  none)  printf 'NONE\n' ;;
  none-padded) printf '\n  NONE  \n\n' ;;
  none-prose)  printf 'None.\n' ;;
  fail)  echo "boom" >&2; exit 1 ;;
  empty) : ;;
  sleep) exec sleep 5 ;;
  touch-ended) : >"$FAKE_ENDED_PATH"; printf '### late\n- decided: x\n' ;;
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
    PATH="$FAKEBIN:$PATH" FAKE_TASK="$FAKE_TASK" FAKE_CLAUDE_OUT="$OUTDIR"
    FAKE_ENDED_PATH="$D/ended" TMUX=fake,1,0 TMUX_PANE=%1)
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
new_scenario; EXTRA_ENV+=(FAKE_CLAUDE_MODE=fail)
sweep
assert_nofile "error: no draft" "$D/draft"
assert_eq "error result" error "$(last_field sweep_ran result)"
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
assert_nofile "ended mid-run: no draft" "$D/draft"
assert_eq "ended mid-run: no tmp" "" "$(ls "$D" | grep 'tmp' || true)"
assert_eq "pending_at_end logged" pending_at_end "$(events)"
assert_eq "pending_at_end draft:true" true "$(last_field pending_at_end draft)"

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
# back-to-back: stop then sweep
new_scenario
sha1sum <"$FAKE_TASK" | cut -d' ' -f1 >"$D/taskhash"; printf '3\n' >"$D/unchanged"
run "$CAPTURE" hook-stop
assert_eq "stop bumped counter" 4 "$(cat "$D/unchanged")"
sweep
assert_eq "sweep then fires" draft "$(last_field sweep_ran result)"

[ "$fail" = 0 ] && echo "ALL PASSED" || { echo "FAILED"; exit 1; }
