#!/usr/bin/env bash
# Tests for wb-capture.sh hook verbs (U3, store auto-capture; shelf-only since the
# nudge rework): hook-prompt (stamps the pane, emits nothing), hook-stop (task-hash
# counter, no phrase matching), hook-posttool (silent no-op), hook-end (tombstone
# only), synthetic prompts, and the reaper.
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

# hook <verb> <json> [args...] — sets OUT, RC.
hook() {
  local verb="$1" json="$2"; shift 2
  printf '%s' "$json" >"$H/stdin.json"
  local -a envv=(HOME="$H" XDG_STATE_HOME="$STATE" XDG_CONFIG_HOME="$CFG"
    PATH="$FAKEBIN:$PATH" FAKE_TASK="$FAKE_TASK" FAKE_SID="$FAKE_SID"
    FAKE_TMUX_CALLS="$H/tmux-calls" TMUX=fake,1,0 TMUX_PANE=%1)
  OUT="$(env "${envv[@]}" "${EXTRA_ENV[@]}" "$REAL_BASH" "$SCRIPT" "$verb" "$@" <"$H/stdin.json" 2>"$H/stderr")"
  RC=$?
}
stop()    { hook hook-stop "$(jq -nc --arg m "$1" '{session_id:"sid-aaa",last_assistant_message:$m}')"; }
prompt()  { hook hook-prompt "$(jq -nc --arg p "$1" '{session_id:"sid-aaa",prompt:$p}')"; }
# posttool <cmd> [stdout] — PostToolUse payload; stdout defaults to wb's success line
posttool_out(){ hook hook-posttool "$(jq -nc --arg c "$1" --arg o "$2" '{session_id:"sid-aaa",tool_name:"Bash",tool_input:{command:$c},tool_response:{stdout:$o,stderr:"",interrupted:false,isImage:false,noOutputExpected:false}}')"; }
WB_OK='wb append: appended under "## Decisions" in /tmp/x.md'
posttool(){ posttool_out "$1" "${2-$WB_OK}"; }
events() { [ -f "$LOG" ] && jq -r .event "$LOG" | tr '\n' ' ' | sed 's/ $//' || echo ""; }
count_ev() { [ -f "$LOG" ] && jq -r --arg e "$1" 'select(.event==$e)|.event' "$LOG" | wc -l | tr -d ' ' || echo 0; }

echo "# hook-prompt stamps @wb_capture_sid and emits nothing, whatever is waiting"
new_scenario
mkdir -p "$D" "$CAP/shelved/dotfiles--feat-x"
printf '### Chose B\n- decided: B\n' >"$D/draft"
printf 'shelved one\n' >"$CAP/shelved/dotfiles--feat-x/20261018T100000-sid-old.md"
stop "ok so we're going with option B here, we decided to use it"
prompt "next"
assert_eq "prompt exit" 0 "$RC"
assert_eq "no additionalContext, no stdout at all" "" "$OUT"
assert_match "tmux set -p called" 'set -p -t %1 @wb_capture_sid sid-aaa' "$(cat "$H/tmux-calls")"
assert_eq "no nudge state written" "" "$(ls "$D" | /usr/bin/grep -E '^(outstanding|nudged_draft|marker|cooldown|reviewing|recorded|shelved_accept)$')"
assert_eq "nothing logged" "" "$(events)"
assert_file "the session draft is left for the sweep and the shelf" "$D/draft"
prompt "again, nothing changes"
assert_eq "second prompt: still silent" "" "$OUT"
assert_eq "second prompt: still nothing logged" "" "$(events)"

echo "# nothing pending"
new_scenario
prompt "hello"
assert_eq "empty stdout" "" "$OUT"
assert_eq "exit 0" 0 "$RC"

echo "# hook-stop: no phrase matching (no marker, no cooldown, nothing logged)"
new_scenario
for m in "ok so we're going with option B here" "we decided to use B" "the decision is C" "settled on D" "chose  E"; do
  stop "$m"
  assert_eq "stop on [$m]: exit 0, silent" "0:" "$RC:$OUT"
done
assert_nofile "no marker" "$D/marker"
assert_nofile "no cooldown" "$D/cooldown"
assert_nofile "no outstanding" "$D/outstanding"
assert_eq "nothing logged" "" "$(events)"
new_scenario
mkdir -p "$D"; touch "$D/muted"
stop "we decided to use B"
assert_nofile "muted: still no marker" "$D/marker"
new_scenario
stop ""; assert_eq "empty message: exit 0" 0 "$RC"
hook hook-stop '{"session_id":"sid-aaa"}'; assert_eq "missing message: exit 0" 0 "$RC"; assert_eq "no stdout" "" "$OUT"
new_scenario
mkdir -p "$CFG/wb"; printf 'phrases=we decided|bar\ncooldown=0\n' >"$CFG/wb/capture.conf"
stop "bar"; prompt "x"
assert_nofile "a configured phrase matches nothing (phrases= is ignored)" "$D/marker"
assert_eq "...and the prompt stays silent" "" "$OUT"

echo "# hook-posttool: a silent no-op verb (exits 0, writes nothing, logs nothing)"
new_scenario
mkdir -p "$D"; : >"$D/draft"
WB_OK_MULTI=$'session=$(tmux display-message -p \'#S\')\nwb append "$task_file" Decisions - <<\'WB_DECISION_END\'\n### t\n- x\nWB_DECISION_END'
for c in 'wb append ~/code/tasks/x.md Decisions -' 'wb append x Handoffs -' "$WB_OK_MULTI" 'ls -la'; do
  posttool "$c"
  assert_eq "posttool [${c:0:30}]: exit 0, silent" "0:" "$RC:$OUT"
done
hook hook-posttool '{"session_id":"sid-aaa","agent_id":"sub1","tool_name":"Bash","tool_input":{"command":"wb append t.md Decisions -"},"tool_response":{"stdout":"wb append: appended under \"## Decisions\" in t.md"}}'
assert_eq "sub-agent payload: exit 0, silent" "0:" "$RC:$OUT"
hook hook-posttool 'not json'; assert_eq "bad json: exit 0" 0 "$RC"
assert_nofile "no recorded flag" "$D/recorded"
assert_eq "session dir untouched (only the draft)" "draft" "$(ls "$D")"
assert_eq "nothing logged" "" "$(events)"
new_scenario
posttool 'wb append x Decisions -'
assert_nofile "posttool never even creates the session dir" "$D"
new_scenario; EXTRA_ENV=(WB_CAPTURE_SWEEP=1)
posttool 'wb append x Decisions -'; assert_eq "guards still short-circuit posttool" "0:" "$RC:$OUT"

echo "# task-hash"
new_scenario
stop "nothing"; assert_eq "first stop: unchanged 0" 0 "$(cat "$D/unchanged")"
stop "nothing"; assert_eq "unchanged 1" 1 "$(cat "$D/unchanged")"
stop "nothing"; assert_eq "unchanged 2" 2 "$(cat "$D/unchanged")"
echo "- external append" >>"$FAKE_TASK"
stop "nothing"; assert_eq "reset on change" 0 "$(cat "$D/unchanged")"
assert_eq "taskhash stored" "$(sha1sum <"$FAKE_TASK" | cut -d' ' -f1)" "$(cat "$D/taskhash")"
assert_eq "taskpath recorded" "$FAKE_TASK" "$(cat "$D/taskpath")"
new_scenario; rm -f "$FAKE_TASK"
stop "x"; stop "x"; assert_eq "missing task = changed" 0 "$(cat "$D/unchanged")"

echo "# synthetic task-notification prompt: no output, flagged, not counted"
new_scenario
prompt "<task-notification>agent done</task-notification>"
assert_eq "no output" "" "$OUT"
assert_file "synthetic flag" "$D/synthetic"
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
prompt "<task-notification>x</task-notification>"
prompt "real prompt"
assert_nofile "real prompt removes stale synthetic" "$D/synthetic"
assert_eq "real prompt: no output" "" "$OUT"

echo "# sub-agent hand-back prompts are synthetic"
HB=$'Another Claude session sent a message:\n<agent-message from="a5bc0f267109c9055">\n[Subagent hand-back] done'
new_scenario
prompt "$HB"
assert_eq "hand-back: no output" "" "$OUT"
assert_file "hand-back: synthetic flag" "$D/synthetic"
new_scenario
prompt $'\n  \n<agent-message from="x">hi</agent-message>'
assert_file "leading whitespace agent-message: synthetic" "$D/synthetic"
new_scenario
prompt $'  \nAnother Claude session sent a message:\nhi'
assert_file "leading whitespace hand-back header: synthetic" "$D/synthetic"
new_scenario
prompt $'\n <task-notification>x</task-notification>'
assert_file "leading whitespace task-notification: synthetic" "$D/synthetic"
new_scenario
prompt "please look at the <agent-message tag in the log"
assert_nofile "mid-text <agent-message is a real prompt" "$D/synthetic"
new_scenario
stop "nothing"; stop "nothing"
prompt "$HB"; stop "hand-back handled"
assert_eq "hand-back turn does not count toward unchanged" 1 "$(cat "$D/unchanged")"

echo "# hook-end: keeps only the tombstone (no draft shelving, no pending_at_end), task untouched"
new_scenario
mkdir -p "$D"; echo body >"$D/draft"
SUM1="$(sha1sum <"$FAKE_TASK")"
hook hook-end '{"session_id":"sid-aaa","reason":"other"}'
assert_eq "end exit" 0 "$RC"
assert_eq "end silent" "" "$OUT"
assert_file "ended tombstone" "$D/ended"
assert_file "the draft stays in the session dir (the reaper shelves it)" "$D/draft"
assert_eq "nothing logged: no pending_at_end, no draft_shelved" "" "$(events)"
assert_nofile "nothing shelved" "$CAP/shelved"
assert_eq "task byte-identical" "$SUM1" "$(sha1sum <"$FAKE_TASK")"
new_scenario
stop "we decided A"
hook hook-end '{"session_id":"sid-aaa"}'
assert_file "tombstone after a phrase stop" "$D/ended"
assert_eq "nothing logged for a phrase stop" "" "$(events)"

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
touch -d '1 day ago' "$CAP/sid-done/ended"   # past the sweep grace period
prompt "hi"
assert_eq "prompt exit" 0 "$RC"
assert_nofile "ended dir removed" "$CAP/sid-done"
assert_file "stamp written" "$CAP/.reaped"
assert_file "current session dir kept" "$D"

echo "# reaper: a stale dir of pre-change nudge-era files is removed and logs nothing"
new_scenario
mkold sid-old marker taskpath cooldown outstanding nudged_draft reviewing shelved_accept draft_strikes recorded
assert_file "legacy files in place" "$CAP/sid-old/marker"
touch -d '8 days ago' "$CAP/sid-old/taskpath" "$CAP/sid-old"
prompt "hi"
assert_nofile "stale dir removed (legacy files and all)" "$CAP/sid-old"
assert_eq "no pending_orphaned, no ignored: the reaper logs nothing" "" "$(events)"

echo "# reaper: stale dir holding a draft shelves it (reason reaped); no pending_orphaned"
new_scenario
mkold sid-dr draft
prompt "hi"
assert_nofile "draft-only dir removed" "$CAP/sid-dr"
assert_eq "reaper shelved the draft" 1 "$(count_ev draft_shelved)"
assert_eq "reaper shelve reason" reaped "$(jq -r 'select(.event=="draft_shelved")|.reason' "$LOG")"
assert_eq "reaper shelve under _unknown (no taskpath)" 1 "$(ls "$CAP/shelved/_unknown" | wc -l | tr -d ' ')"
assert_eq "no pending_orphaned" 0 "$(count_ev pending_orphaned)"
assert_nofile "reaper never treats shelved/ as a session dir" "$CAP/shelved/.lock"
# a draft whose session recorded its task shelves under that task
new_scenario
mkold sid-dt draft taskpath
printf '%s\n' "$H/tasks/dotfiles--feat-old.md" >"$CAP/sid-dt/taskpath"; touch -d '8 days ago' "$CAP/sid-dt/taskpath" "$CAP/sid-dt"
echo "orphan draft" >"$CAP/sid-dt/draft"; touch -d '8 days ago' "$CAP/sid-dt/draft" "$CAP/sid-dt"
prompt "hi"
assert_eq "reaper shelves under the session's task" "orphan draft" "$(cat "$CAP"/shelved/dotfiles--feat-old/*-sid-dt.md)"
# a stale dir with a (legacy) phrase marker and no draft shelves nothing
new_scenario
mkold sid-mk marker
prompt "hi"
assert_eq "marker-only reap shelves nothing" 0 "$(count_ev draft_shelved)"

echo "# reaper: a draft it cannot shelve keeps its dir (retried next reap), never deleted"
new_scenario
mkdir -p "$CAP/sid-pf" "$CAP/shelved"; printf 'pf draft\n' >"$CAP/sid-pf/draft"
printf '%s\n' "$H/tasks/dotfiles--feat-pf.md" >"$CAP/sid-pf/taskpath"
: >"$CAP/shelved/dotfiles--feat-pf"     # a FILE where the shelved dir must go: mkdir fails
touch -d '8 days ago' "$CAP/sid-pf"/* "$CAP/sid-pf"
prompt "hi"
assert_eq "unshelvable draft kept in place" "pf draft" "$(cat "$CAP/sid-pf/draft" 2>/dev/null)"
assert_eq "no draft_shelved logged" 0 "$(count_ev draft_shelved)"
# second reap, still blocked
touch -d '8 days ago' "$CAP/sid-pf"/* "$CAP/sid-pf/.lock" "$CAP/sid-pf" 2>/dev/null; touch -d '2 hours ago' "$CAP/.reaped"
prompt "again"
assert_file "still kept" "$CAP/sid-pf/draft"
assert_eq "still no draft_shelved" 0 "$(count_ev draft_shelved)"
# third reap, blocker gone: shelved once, dir reaped
rm -f "$CAP/shelved/dotfiles--feat-pf"
touch -d '8 days ago' "$CAP/sid-pf"/* "$CAP/sid-pf/.lock" "$CAP/sid-pf" 2>/dev/null; touch -d '2 hours ago' "$CAP/.reaped"
prompt "third"
assert_nofile "dir reaped once shelving works" "$CAP/sid-pf"
assert_eq "shelved on the retry, exactly once" 1 "$(count_ev draft_shelved)"
assert_eq "shelved text intact" "pf draft" "$(cat "$CAP"/shelved/dotfiles--feat-pf/*-sid-pf.md)"

echo "# reaper: stale dir with nothing pending -> removed, nothing logged"
new_scenario
mkold sid-old2 unchanged
prompt "hi"
assert_nofile "removed" "$CAP/sid-old2"
assert_eq "no log" "" "$(events)"

echo "# reaper: fresh un-ended dir kept; current session never removed"
new_scenario
mkdir -p "$CAP/sid-fresh"; touch "$CAP/sid-fresh/marker"
mkold sid-aaa marker ended   # current session: old AND ended
prompt "hi"
assert_file "fresh dir kept" "$CAP/sid-fresh/marker"
assert_file "current dir kept" "$D"
assert_nofile "current dir's tombstone shed (session is alive)" "$D/ended"

echo "# reaper: a just-ended dir survives (in-flight sweep grace); a backdated one is removed"
new_scenario
mkdir -p "$CAP/sid-fe" "$CAP/sid-oe"
touch "$CAP/sid-fe/ended" "$CAP/sid-oe/ended"
touch -d '1 day ago' "$CAP/sid-oe/ended"
prompt "hi"
assert_file "fresh ended dir survives the reap" "$CAP/sid-fe/ended"
assert_nofile "backdated ended dir removed" "$CAP/sid-oe"
mkdir -p "$CFG/wb"; printf 'sweep_timeout=600\n' >"$CFG/wb/capture.conf"
mkdir -p "$CAP/sid-ge"; touch -d '10 minutes ago' "$CAP/sid-ge/ended"
touch -d '2 hours ago' "$CAP/.reaped"
prompt "again"
assert_file "grace scales with sweep_timeout (10 min < 2x600+60s)" "$CAP/sid-ge/ended"

echo "# reaper: sweep_timeout=0 uses the sweep's default timeout for the grace (2x60+60 = 180s)"
new_scenario
mkdir -p "$CFG/wb"; printf 'sweep_timeout=0\n' >"$CFG/wb/capture.conf"
mkdir -p "$CAP/sid-z1" "$CAP/sid-z2"
touch -d '100 seconds ago' "$CAP/sid-z1/ended"; touch -d '400 seconds ago' "$CAP/sid-z2/ended"
touch -d '2 hours ago' "$CAP/.reaped" 2>/dev/null || { mkdir -p "$CAP"; touch -d '2 hours ago' "$CAP/.reaped"; }
prompt "hi"
assert_file "timeout 0: a dir ended 100s ago survives (grace 180s, not 60s)" "$CAP/sid-z1/ended"
assert_nofile "timeout 0: a dir ended 400s ago is reaped" "$CAP/sid-z2"

echo "# reaper: hourly throttle"
new_scenario
prompt "one"
mkdir -p "$CAP/sid-d2"; touch "$CAP/sid-d2/ended"; touch -d '1 day ago' "$CAP/sid-d2/ended"
prompt "two"
assert_file "second ended dir survives inside the window" "$CAP/sid-d2/ended"
touch -d '2 hours ago' "$CAP/.reaped"
prompt "three"
assert_nofile "removed once stamp aged" "$CAP/sid-d2"

echo "# reaper: known files + draft.tmp.* + .lock removed; unknown file blocks rmdir"
new_scenario
mkdir -p "$CAP/sid-tmp" "$CAP/sid-unk"
touch "$CAP/sid-tmp/ended" "$CAP/sid-tmp/draft.tmp.123" "$CAP/sid-tmp/.lock" "$CAP/sid-tmp/sweep_offset" \
  "$CAP/sid-tmp/draft_strikes" "$CAP/sid-tmp/sweep_failures" "$CAP/sid-tmp/sweep_invalid" \
  "$CAP/sid-tmp/draft_stale" "$CAP/sid-tmp/draft_stale.tmp.77"
touch "$CAP/sid-unk/ended" "$CAP/sid-unk/mystery"
touch -d '1 day ago' "$CAP/sid-tmp/ended" "$CAP/sid-unk/ended"
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
hook mute ''; prompt "again"
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

echo "# reaper does not make hook-prompt talk"
new_scenario
mkdir -p "$CAP/sid-gone"; touch -d '1 day ago' "$CAP/sid-gone/ended"
prompt "go"
assert_nofile "reaper ran" "$CAP/sid-gone"
assert_eq "stdout still empty" "" "$OUT"

echo "# guards short-circuit hook verbs"
new_scenario; EXTRA_ENV=(WB_CAPTURE_SWEEP=1)
stop "we decided A"; assert_eq "no output" "" "$OUT"; assert_nofile "no state" "$CAP"
new_scenario; EXTRA_ENV=(WB_CAPTURE_SWEEP=1); prompt "x"; assert_nofile "prompt: no state" "$CAP"

echo "# bad input fails open"
new_scenario
hook hook-stop 'not json'; assert_eq "bad json exit" 0 "$RC"; assert_eq "bad json quiet" "" "$OUT"
hook hook-prompt '{"session_id":"../evil"}'; assert_eq "bad sid exit" 0 "$RC"
assert_nofile "no traversal" "$CAP/../evil"

echo "# resolved/ archive: the reaper never treats it as a session dir, prunes only old archived drafts"
new_scenario
mkdir -p "$CAP/resolved/dotfiles--feat-x" "$CAP/resolved/dotfiles--feat-y" "$CAP/resolved/dotfiles--feat-z"
RX="$CAP/resolved/dotfiles--feat-x"; RY="$CAP/resolved/dotfiles--feat-y"; RZ="$CAP/resolved/dotfiles--feat-z"
# files named like session state, directly under resolved/: a session-dir reap would shelve or remove them
printf 'm' >"$CAP/resolved/marker"; printf 'rd\n' >"$CAP/resolved/draft"
printf 'old\n' >"$RX/20260101T000000-accepted-sid-a.md"; : >"$RX/20260101T000000-accepted-sid-a.md.stale"
printf 'new\n' >"$RX/20261020T000000-dismissed-sid-b.md"
printf 'keep\n' >"$RX/notes.txt"
printf 'old\n' >"$RY/20260101T000000-shelved_accepted-q.md"
printf 'old\n' >"$RZ/20260101T000000-dismissed-sid-c.md"; ln -s "$RX/notes.txt" "$RZ/20260101T000001-dismissed-link.md"
printf 'outside\n' >"$H/outside.md"; touch -d '40 days ago' "$H/outside.md"
touch -d '31 days ago' "$RX/20260101T000000-accepted-sid-a.md" "$RX/20260101T000000-accepted-sid-a.md.stale" "$RX/notes.txt" \
  "$RY/20260101T000000-shelved_accepted-q.md" "$RZ/20260101T000000-dismissed-sid-c.md"
touch -h -d '31 days ago' "$RZ/20260101T000001-dismissed-link.md"
touch -d '1 day ago' "$RX/20261020T000000-dismissed-sid-b.md"
touch -d '8 days ago' "$CAP/resolved/marker" "$CAP/resolved/draft" "$CAP/resolved"
prompt "hi"
assert_file "resolved is not reaped as a session dir (marker)" "$CAP/resolved/marker"
assert_file "resolved is not reaped as a session dir (draft)" "$CAP/resolved/draft"
assert_eq "resolved: nothing shelved or orphaned" 00 "$(count_ev draft_shelved)$(count_ev pending_orphaned)"
assert_nofile "prune: old .md removed" "$RX/20260101T000000-accepted-sid-a.md"
assert_nofile "prune: old .md.stale removed" "$RX/20260101T000000-accepted-sid-a.md.stale"
assert_file "prune: newer .md kept" "$RX/20261020T000000-dismissed-sid-b.md"
assert_file "prune: non-matching old name kept" "$RX/notes.txt"
assert_file "prune: stem dir with survivors kept" "$RX"
assert_nofile "prune: stem dir emptied by pruning is rmdir'd" "$RY"
assert_nofile "prune: old regular file removed beside a symlink" "$RZ/20260101T000000-dismissed-sid-c.md"
assert_file "prune: symlink never removed" "$RZ/20260101T000001-dismissed-link.md"
assert_file "prune: a stem dir holding a symlink is kept" "$RZ"
assert_file "prune: the symlink target is untouched" "$RX/notes.txt"
assert_file "prune: files outside resolved/ untouched" "$H/outside.md"
# throttled: a second prompt inside the hour prunes nothing new
printf 'old\n' >"$RX/20260101T000002-accepted-sid-d.md"; touch -d '40 days ago' "$RX/20260101T000002-accepted-sid-d.md"
prompt "again"
assert_file "prune is inside the throttled reap" "$RX/20260101T000002-accepted-sid-d.md"
touch -d '2 hours ago' "$CAP/.reaped"
prompt "third"
assert_nofile "next reap prunes it" "$RX/20260101T000002-accepted-sid-d.md"
# reap_dir backstop: a dir still holding a draft is kept, the rest of its state is removed
new_scenario; mkdir -p "$D"; printf 'precious\n' >"$D/draft"; touch "$D/marker" "$D/ended"
( source "$SCRIPT"; reap_dir "$D" ) >/dev/null 2>&1
assert_eq "reap_dir keeps the draft" precious "$(cat "$D/draft" 2>/dev/null)"
assert_file "reap_dir keeps a dir holding a draft" "$D"
assert_nofile "reap_dir still removes the other state" "$D/marker"
rm -f "$D/draft"; ( source "$SCRIPT"; reap_dir "$D" ) >/dev/null 2>&1
assert_nofile "reap_dir removes a dir with no draft" "$D"

[ "$fail" = 0 ] && echo "ALL PASSED" || { echo "FAILED"; exit 1; }
