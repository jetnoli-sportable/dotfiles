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
stop "done"
assert_eq "followed turn: no ignored" 0 "$(count_ev ignored)"

echo "# ignored: nudge turn ends with no append or dismiss"
new_scenario
stop "we decided to use B"; prompt "go"
assert_file "outstanding after delivery" "$D/outstanding"
stop "ok, carrying on with the refactor"
assert_eq "ignored logged once" 1 "$(count_ev ignored)"
assert_eq "ignored source" phrase "$(jq -r 'select(.event=="ignored")|.source' "$LOG")"
assert_nofile "outstanding cleared" "$D/outstanding"
prompt "next"; posttool 'wb append x Decisions -'
assert_eq "later unrelated append is not 'followed'" 0 "$(count_ev followed)"
stop "fine"
assert_eq "still one ignored" 1 "$(count_ev ignored)"

echo "# dismissed in the nudge turn: no ignored"
new_scenario
stop "we decided to use B"; prompt "go"
hook dismiss ''
assert_eq "dismissed logged" 1 "$(count_ev dismissed)"
stop "dismissed it"
assert_eq "no ignored after dismiss" 0 "$(count_ev ignored)"

echo "# synthetic turn doesn't resolve; the next real turn does"
new_scenario
stop "we decided to use B"; prompt "go"
prompt "<task-notification><task-id>x</task-id></task-notification>"
stop "background agent finished"
assert_eq "synthetic Stop: not ignored yet" 0 "$(count_ev ignored)"
assert_file "still outstanding" "$D/outstanding"
stop "real turn ends"
assert_eq "real Stop: ignored" 1 "$(count_ev ignored)"

echo "# stale outstanding (nudge turn never reached Stop) resolved at the next real prompt"
new_scenario
stop "we decided to use B"; prompt "go"
prompt "interrupted, asking again"
assert_eq "stale nudge -> ignored" 1 "$(count_ev ignored)"
assert_nofile "stale outstanding cleared" "$D/outstanding"

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

echo "# hook-end: pending marker -> pending_at_end + tombstone, task untouched"
new_scenario
stop "we decided A"
SUM1="$(sha1sum <"$FAKE_TASK")"
hook hook-end '{"session_id":"sid-aaa","reason":"other"}'
assert_eq "end exit" 0 "$RC"
assert_eq "one pending_at_end" 1 "$(count_ev pending_at_end)"
assert_eq "marker true" true "$(jq -r 'select(.event=="pending_at_end")|.marker' "$LOG")"
assert_eq "draft false" false "$(jq -r 'select(.event=="pending_at_end")|.draft' "$LOG")"
assert_eq "session_id logged" sid-aaa "$(jq -r 'select(.event=="pending_at_end")|.session_id' "$LOG")"
assert_file "ended tombstone" "$D/ended"
assert_file "marker not deleted by hook-end" "$D/marker"
assert_eq "task byte-identical" "$SUM1" "$(sha1sum <"$FAKE_TASK")"

echo "# hook-end: draft only"
new_scenario
mkdir -p "$D"; echo body >"$D/draft"
hook hook-end '{"session_id":"sid-aaa"}'
assert_eq "draft true" true "$(jq -r 'select(.event=="pending_at_end")|.draft' "$LOG")"
assert_eq "marker false" false "$(jq -r 'select(.event=="pending_at_end")|.marker' "$LOG")"

echo "# hook-end: nothing pending -> tombstone only, no log"
new_scenario
hook hook-end '{"session_id":"sid-aaa"}'
assert_file "tombstone" "$D/ended"
assert_nofile "nothing logged" "$LOG"
hook hook-end 'not json'; assert_eq "bad json exit" 0 "$RC"

echo "# resumed session (same session_id) sheds its tombstone on the next prompt"
new_scenario
hook hook-end '{"session_id":"sid-aaa"}'
assert_file "tombstone written" "$D/ended"
prompt "back again"
assert_nofile "tombstone cleared on resume" "$D/ended"

# mkold <sid> [file...] — session dir with files, all backdated 8 days.
mkold() {
  local sid="$1" f; shift; mkdir -p "$CAP/$sid"
  for f in "$@"; do echo x >"$CAP/$sid/$f"; done
  touch -d '8 days ago' "$CAP/$sid"/* "$CAP/$sid" 2>/dev/null
}

echo "# reaper: ended dir removed on next eligible hook-prompt"
new_scenario
mkdir -p "$CAP/sid-done"; touch "$CAP/sid-done/ended" "$CAP/sid-done/unchanged"
prompt "hi"
assert_eq "prompt exit" 0 "$RC"
assert_nofile "ended dir removed" "$CAP/sid-done"
assert_file "stamp written" "$CAP/.reaped"
assert_file "current session dir kept" "$D"

echo "# reaper: 8-day-old dir with marker logs pending_orphaned and is removed"
new_scenario
mkold sid-old marker taskpath cooldown
printf '%s\n' "$H/tasks/dotfiles--feat-old.md" >"$CAP/sid-old/taskpath"; touch -d '8 days ago' "$CAP/sid-old/taskpath" "$CAP/sid-old"
prompt "hi"
assert_nofile "stale dir removed" "$CAP/sid-old"
assert_eq "one pending_orphaned" 1 "$(count_ev pending_orphaned)"
assert_eq "orphan sid" sid-old "$(jq -r 'select(.event=="pending_orphaned")|.session_id' "$LOG")"
assert_eq "orphan task stem" dotfiles--feat-old "$(jq -r 'select(.event=="pending_orphaned")|.task' "$LOG")"
assert_eq "orphan marker true" true "$(jq -r 'select(.event=="pending_orphaned")|.marker' "$LOG")"

echo "# reaper: stale dir with nothing pending -> removed, no orphan log"
new_scenario
mkold sid-old2 unchanged
prompt "hi"
assert_nofile "removed" "$CAP/sid-old2"
assert_eq "no orphan log" 0 "$(count_ev pending_orphaned)"

echo "# reaper: fresh un-ended dir kept; current session never removed"
new_scenario
mkdir -p "$CAP/sid-fresh"; touch "$CAP/sid-fresh/marker"
mkold sid-aaa marker ended   # current session: old AND ended
prompt "hi"
assert_file "fresh dir kept" "$CAP/sid-fresh/marker"
assert_file "current dir kept" "$D"
assert_nofile "current dir's tombstone shed (session is alive)" "$D/ended"

echo "# reaper: hourly throttle"
new_scenario
prompt "one"
mkdir -p "$CAP/sid-d2"; touch "$CAP/sid-d2/ended"
prompt "two"
assert_file "second ended dir survives inside the window" "$CAP/sid-d2/ended"
touch -d '2 hours ago' "$CAP/.reaped"
prompt "three"
assert_nofile "removed once stamp aged" "$CAP/sid-d2"

echo "# reaper: known files + draft.tmp.* + .lock removed; unknown file blocks rmdir"
new_scenario
mkdir -p "$CAP/sid-tmp" "$CAP/sid-unk"
touch "$CAP/sid-tmp/ended" "$CAP/sid-tmp/draft.tmp.123" "$CAP/sid-tmp/.lock" "$CAP/sid-tmp/sweep_offset"
touch "$CAP/sid-unk/ended" "$CAP/sid-unk/mystery"
prompt "hi"
assert_nofile "tmp/lock dir gone" "$CAP/sid-tmp"
assert_file "unknown file left" "$CAP/sid-unk/mystery"
assert_nofile "known file still removed" "$CAP/sid-unk/ended"

echo "# reaper: invalid names and symlinks untouched"
new_scenario
mkdir -p "$CAP/not valid!" "$H/target"
touch "$CAP/not valid!/ended" "$H/target/ended" "$H/target/marker"
ln -s "$H/target" "$CAP/linkdir"
prompt "hi"
assert_file "invalid-name dir kept" "$CAP/not valid!/ended"
assert_file "symlink kept" "$CAP/linkdir"
assert_file "symlink target ended intact" "$H/target/ended"
assert_file "symlink target marker intact" "$H/target/marker"

echo "# log rotation"
new_scenario
mkdir -p "$CAP"; printf '%s\n' '{"event":"old"}' '{"event":"old2"}' >"$LOG"
EXTRA_ENV=(WB_CAPTURE_LOG_MAX=10)
prompt "hi"
assert_file "rotated to .1" "$LOG.1"
assert_eq "rotated content" 2 "$(wc -l <"$LOG.1" | tr -d ' ')"
assert_nofile "log reset" "$LOG"
stop "we decided A"; prompt "again"
assert_file "next event starts new log" "$LOG"
assert_eq "new log excludes old" 0 "$(grep -c old "$LOG")"
new_scenario
mkdir -p "$CAP"; echo '{"event":"keep"}' >"$LOG"
prompt "hi"
assert_nofile "under cap: not rotated" "$LOG.1"

echo "# reaper fail-open on odd capture root"
new_scenario
echo notadir >"$H/afile"; mkdir -p "$H/outside"; touch "$H/outside/ended"
EXTRA_ENV=(XDG_STATE_HOME="$H/afile")
prompt "hi"
assert_eq "exit 0 with file as state home" 0 "$RC"
assert_file "outside untouched" "$H/outside/ended"
EXTRA_ENV=(XDG_STATE_HOME="/nonexistent-wbtest/zz")
prompt "hi"
assert_eq "exit 0 with unwritable state home" 0 "$RC"

echo "# reaper does not change nudge output"
new_scenario
stop "we decided A"
mkdir -p "$CAP/sid-gone"; touch "$CAP/sid-gone/ended"
prompt "go"
assert_nofile "reaper ran" "$CAP/sid-gone"
assert_eq "stdout is one JSON line" 1 "$(printf '%s\n' "$OUT" | wc -l | tr -d ' ')"
assert_eq "valid nudge json" UserPromptSubmit "$(printf '%s' "$OUT" | jq -r .hookSpecificOutput.hookEventName)"

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
