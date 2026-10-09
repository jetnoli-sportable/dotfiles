#!/usr/bin/env bash
# Tests for wb-capture.sh hook verbs (U3, store auto-capture): hook-stop
# (phrase detection, cooldown, task-hash counter), hook-posttool (recorded /
# followed), hook-prompt (nudge delivery, precedence, synthetic prompts).
#
# tmux is faked by a script on PATH (no real server); see wb-capture-core.test.sh.
# Run: bash scripts/.config/scripts/tmux/tests/wb-capture-hooks.test.sh
set -uo pipefail

SCRIPT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/wb-capture.sh"
REAL_BASH="$(command -v bash)"
ROOT="$(mktemp -d -t wb-capture-hooks.XXXXXX)"
trap 'rm -rf "$ROOT"' EXIT

FAKEBIN="$ROOT/fakebin"; mkdir -p "$FAKEBIN"
cat >"$FAKEBIN/tmux" <<'FAKE'
#!/usr/bin/env bash
case "$1" in
  display-message) echo "fakesess" ;;
  show)
    case "$*" in
      *@task*) printf '%s\n' "${FAKE_TASK:-}" ;;
      *@wb_capture_sid*) printf '%s\n' "${FAKE_SID:-}" ;;
    esac ;;
  *) echo "$*" >>"${FAKE_TMUX_CALLS:-/dev/null}" ;;
esac
exit 0
FAKE
chmod +x "$FAKEBIN/tmux"

fail=0
ok()   { echo "ok   - $1"; }
bad()  { echo "FAIL - $1${2:+ ($2)}"; fail=1; }
assert_eq()    { [ "$2" = "$3" ] && ok "$1" || bad "$1" "expected [$2], got [$3]"; }
assert_match() { printf '%s' "$3" | grep -qE "$2" && ok "$1" || bad "$1" "expected /$2/, got [$3]"; }
assert_file()  { [ -e "$2" ] && ok "$1" || bad "$1" "missing $2"; }
assert_nofile(){ [ ! -e "$2" ] && ok "$1" || bad "$1" "unexpected $2"; }

n=0
new_scenario() {
  n=$((n + 1))
  H="$ROOT/s$n"; mkdir -p "$H/state" "$H/config" "$H/tasks"
  STATE="$H/state"; CFG="$H/config"
  CAP="$STATE/wb/capture"; LOG="$CAP/log.jsonl"
  FAKE_TASK="$H/tasks/dotfiles--feat-x.md"; FAKE_SID="sid-aaa"
  printf '# task\n## Decisions\n' >"$FAKE_TASK"
  D="$CAP/sid-aaa"
  EXTRA_ENV=()
}

# hook <verb> <json> — sets OUT, RC.
hook() {
  local verb="$1" json="$2"
  printf '%s' "$json" >"$H/stdin.json"
  local -a envv=(HOME="$H" XDG_STATE_HOME="$STATE" XDG_CONFIG_HOME="$CFG"
    PATH="$FAKEBIN:$PATH" FAKE_TASK="$FAKE_TASK" FAKE_SID="$FAKE_SID"
    FAKE_TMUX_CALLS="$H/tmux-calls" TMUX=fake,1,0 TMUX_PANE=%1)
  OUT="$(env "${envv[@]}" "${EXTRA_ENV[@]}" "$REAL_BASH" "$SCRIPT" "$verb" <"$H/stdin.json" 2>"$H/stderr")"
  RC=$?
}
stop()    { hook hook-stop "$(jq -nc --arg m "$1" '{session_id:"sid-aaa",last_assistant_message:$m}')"; }
prompt()  { hook hook-prompt "$(jq -nc --arg p "$1" '{session_id:"sid-aaa",prompt:$p}')"; }
posttool(){ hook hook-posttool "$(jq -nc --arg c "$1" '{session_id:"sid-aaa",tool_name:"Bash",tool_input:{command:$c}}')"; }
events() { [ -f "$LOG" ] && jq -r .event "$LOG" | tr '\n' ' ' | sed 's/ $//' || echo ""; }
count_ev() { [ -f "$LOG" ] && jq -r --arg e "$1" 'select(.event==$e)|.event' "$LOG" | wc -l | tr -d ' ' || echo 0; }

echo "# happy path"
new_scenario
stop "ok so we're going with option B here"
assert_eq "stop exit" 0 "$RC"
assert_file "marker written" "$D/marker"
assert_eq "marker holds phrase" "going with" "$(cat "$D/marker")"
prompt "next"
assert_eq "prompt exit" 0 "$RC"
assert_eq "one line" 1 "$(printf '%s\n' "$OUT" | wc -l | tr -d ' ')"
CTX="$(printf '%s' "$OUT" | jq -r .hookSpecificOutput.additionalContext)"
assert_eq "exact phrase nudge" '[wb-capture] Last turn read like a decision ("going with"). If it settled something, run /wb-decide; otherwise ignore or /wb-decide dismiss.' "$CTX"
assert_match "mentions /wb-decide" '/wb-decide' "$OUT"
assert_eq "hookEventName" UserPromptSubmit "$(printf '%s' "$OUT" | jq -r .hookSpecificOutput.hookEventName)"
assert_eq "no newline in context" 1 "$(printf '%s\n' "$CTX" | wc -l | tr -d ' ')"
assert_nofile "marker cleared" "$D/marker"
assert_eq "outstanding = phrase" phrase "$(cat "$D/outstanding")"
assert_eq "nudge_fired source" phrase "$(jq -r 'select(.event=="nudge_fired")|.source' "$LOG")"

echo "# @wb_capture_sid stamped"
assert_match "tmux set -p called" 'set -p @wb_capture_sid sid-aaa' "$(cat "$H/tmux-calls")"

echo "# nothing pending"
new_scenario
prompt "hello"
assert_eq "empty stdout" "" "$OUT"
assert_eq "exit 0" 0 "$RC"

echo "# suppression by recorded"
new_scenario
posttool 'wb append ~/code/tasks/x.md Decisions -'
assert_file "recorded set" "$D/recorded"
stop "we decided to use B"
assert_nofile "no marker" "$D/marker"
assert_nofile "recorded cleared" "$D/recorded"

echo "# stale recorded (turn never reached Stop) cleared by the next real prompt"
new_scenario
posttool 'wb append ~/code/tasks/x.md Decisions -'
prompt "carry on"
assert_nofile "stale recorded cleared" "$D/recorded"
stop "we decided to use B"
assert_file "marker set on the new turn" "$D/marker"

echo "# followed"
new_scenario
stop "we decided to use B"; prompt "go"
posttool 'wb append x Decisions -'
assert_eq "followed logged" 1 "$(count_ev followed)"
assert_eq "followed source" phrase "$(jq -r 'select(.event=="followed")|.source' "$LOG")"
assert_nofile "outstanding cleared" "$D/outstanding"
posttool 'wb append x Decisions -'
assert_eq "followed still once" 1 "$(count_ev followed)"

echo "# sub-agent posttool"
new_scenario
hook hook-posttool '{"session_id":"sid-aaa","agent_id":"sub1","tool_name":"Bash","tool_input":{"command":"wb append t.md Decisions -"}}'
assert_file "sub-agent counts as recorded" "$D/recorded"

echo "# non-matching commands"
new_scenario
posttool 'wb append x Handoffs -'; assert_nofile "Handoffs append" "$D/recorded"
posttool 'grep Decisions file';    assert_nofile "grep Decisions" "$D/recorded"
posttool 'echo wb append; cat Decisions.md'; assert_nofile "echo mention" "$D/recorded"
posttool 'ls -la';                 assert_nofile "unrelated" "$D/recorded"
assert_eq "exit 0" 0 "$RC"
posttool 'cd x && wb append t.md Decisions -'; assert_file "chained wb append" "$D/recorded"

echo "# cooldown"
new_scenario
stop "we decided A"; assert_file "marker 1" "$D/marker"
rm -f "$D/marker"
stop "we decided B"; assert_nofile "suppressed turn 2" "$D/marker"
stop "we decided C"; assert_nofile "suppressed turn 3" "$D/marker"
stop "we decided D"; assert_nofile "suppressed turn 4" "$D/marker"
stop "we decided E"; assert_file "new marker after cooldown" "$D/marker"

echo "# precedence"
new_scenario
stop "we decided A"; mkdir -p "$D"; echo "body" >"$D/draft"
prompt "go"
assert_match "draft line" 'background review drafted an unrecorded decision \(.*/draft\)\. Run /wb-decide to review/' "$OUT"
assert_eq "draft source" sweep "$(cat "$D/outstanding")"
assert_eq "one line" 1 "$(printf '%s\n' "$OUT" | wc -l | tr -d ' ')"
assert_nofile "marker cleared" "$D/marker"
assert_file "draft stays" "$D/draft"
assert_eq "nudge source sweep" sweep "$(jq -r 'select(.event=="nudge_fired")|.source' "$LOG")"
prompt "again"
assert_eq "same draft not re-nudged" "" "$OUT"
echo "changed body" >"$D/draft"
prompt "again"
assert_match "changed draft re-nudged" 'drafted an unrecorded decision' "$OUT"

echo "# empty / missing message"
new_scenario
stop ""; assert_nofile "empty -> no marker" "$D/marker"; assert_eq "empty exit" 0 "$RC"
hook hook-stop '{"session_id":"sid-aaa"}'; assert_nofile "missing -> no marker" "$D/marker"
assert_eq "missing exit" 0 "$RC"; assert_eq "no stdout" "" "$OUT"

echo "# muted"
new_scenario
mkdir -p "$D"; touch "$D/muted"
stop "we decided A"; assert_nofile "muted: no marker" "$D/marker"

echo "# newline in phrase config stays one line"
new_scenario
printf 'phrases=we decided|bar\n' >"$CFG/wb/capture.conf"
stop "bar"; prompt "x"
assert_eq "single line" 1 "$(printf '%s\n' "$OUT" | wc -l | tr -d ' ')"

echo "# task-hash"
new_scenario
stop "nothing"; assert_eq "first stop: unchanged 0" 0 "$(cat "$D/unchanged")"
stop "nothing"; assert_eq "unchanged 1" 1 "$(cat "$D/unchanged")"
stop "nothing"; assert_eq "unchanged 2" 2 "$(cat "$D/unchanged")"
echo "- external append" >>"$FAKE_TASK"
stop "nothing"; assert_eq "reset on change" 0 "$(cat "$D/unchanged")"
assert_eq "taskhash stored" "$(sha1sum <"$FAKE_TASK" | cut -d' ' -f1)" "$(cat "$D/taskhash")"
new_scenario; rm -f "$FAKE_TASK"
stop "x"; stop "x"; assert_eq "missing task = changed" 0 "$(cat "$D/unchanged")"

echo "# synthetic task-notification prompt"
new_scenario
stop "we decided A"
prompt "<task-notification>agent done</task-notification>"
assert_eq "no nudge" "" "$OUT"
assert_file "marker kept" "$D/marker"
assert_file "synthetic flag" "$D/synthetic"
stop "nothing"; stop "nothing" # first establishes hash
new_scenario
stop "nothing"; stop "nothing"
assert_eq "baseline unchanged 1" 1 "$(cat "$D/unchanged")"
prompt "<task-notification>x</task-notification>"
stop "nothing"
assert_eq "synthetic stop: no increment" 1 "$(cat "$D/unchanged")"
assert_nofile "synthetic flag removed by stop" "$D/synthetic"
stop "nothing"
assert_eq "next stop increments" 2 "$(cat "$D/unchanged")"
new_scenario
stop "we decided A"
prompt "<task-notification>x</task-notification>"
prompt "real prompt"
assert_match "next real prompt nudges" 'going with|decided to|we decided' "$OUT"
assert_nofile "real prompt removes stale synthetic" "$D/synthetic"

echo "# guards short-circuit hook verbs"
new_scenario; EXTRA_ENV=(WB_CAPTURE_SWEEP=1)
stop "we decided A"; assert_eq "no output" "" "$OUT"; assert_nofile "no state" "$CAP"
new_scenario; EXTRA_ENV=(WB_CAPTURE_SWEEP=1); prompt "x"; assert_nofile "prompt: no state" "$CAP"

echo "# bad input fails open"
new_scenario
hook hook-stop 'not json'; assert_eq "bad json exit" 0 "$RC"; assert_eq "bad json quiet" "" "$OUT"
hook hook-prompt '{"session_id":"../evil"}'; assert_eq "bad sid exit" 0 "$RC"
assert_nofile "no traversal" "$CAP/../evil"

[ "$fail" = 0 ] && echo "ALL PASSED" || { echo "FAILED"; exit 1; }
