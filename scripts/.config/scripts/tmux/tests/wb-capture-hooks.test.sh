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

echo "# draft strikes: first ignore re-nudges the same draft, second shelves it"
new_scenario; PK="$CAP/shelved/dotfiles--feat-x"
mkdir -p "$D"; printf '### Chose B\n- decided: B\n' >"$D/draft"
prompt "go"; assert_eq "draft nudge fired" sweep "$(cat "$D/outstanding")"
stop "carrying on"
assert_eq "ignored once" 1 "$(count_ev ignored)"
assert_eq "strike recorded" 1 "$(cat "$D/draft_strikes")"
assert_nofile "nudged_draft dropped" "$D/nudged_draft"
assert_file "draft kept after first ignore" "$D/draft"
prompt "next"
assert_match "same draft nudged again" 'background review drafted' "$OUT"
assert_eq "second nudge outstanding" sweep "$(cat "$D/outstanding")"
stop "still carrying on"
assert_eq "ignored twice" 2 "$(count_ev ignored)"
assert_nofile "draft left the session dir (sweep unblocked)" "$D/draft"
assert_nofile "nudged_draft gone" "$D/nudged_draft"
assert_nofile "strikes gone" "$D/draft_strikes"
assert_eq "draft_shelved logged once" 1 "$(count_ev draft_shelved)"
assert_eq "shelve reason" ignored_twice "$(jq -r 'select(.event=="draft_shelved")|.reason' "$LOG")"
assert_eq "never discarded" 0 "$(count_ev draft_discarded)"
assert_eq "one shelved file" 1 "$(ls "$PK" | wc -l | tr -d ' ')"
assert_match "shelved name sorts by time, carries sid" '^[0-9]{8}T[0-9]{6}-sid-aaa\.md$' "$(ls "$PK")"
assert_eq "shelved content verbatim" $'### Chose B\n- decided: B' "$(cat "$PK"/*.md)"
prompt "after"; assert_eq "nothing left to nudge" "" "$OUT"
assert_eq "no further shelve" 1 "$(count_ev draft_shelved)"

echo "# draft strikes: stale outstanding at the next prompt strikes too"
new_scenario
mkdir -p "$D"; printf 'draft\n' >"$D/draft"
prompt "go"; prompt "again, never reached Stop"
assert_eq "strike via prompt" 1 "$(cat "$D/draft_strikes")"
assert_match "re-nudged in the same prompt" 'background review drafted' "$OUT"

echo "# draft strikes: phrase-nudge ignores don't strike"
new_scenario
stop "we decided to use B"; prompt "go"; stop "ok"
assert_nofile "no strikes for a phrase ignore" "$D/draft_strikes"

echo "# draft strikes: SessionEnd resolves ignored without striking"
new_scenario
mkdir -p "$D"; printf 'draft\n' >"$D/draft"; prompt "go"
hook hook-end '{"session_id":"sid-aaa"}'
assert_eq "end -> ignored" 1 "$(count_ev ignored)"
assert_nofile "no strike at end" "$D/draft_strikes"
assert_eq "end shelves the draft" 1 "$(count_ev draft_shelved)"
assert_eq "end shelve reason" session_end "$(jq -r 'select(.event=="draft_shelved")|.reason' "$LOG")"
assert_nofile "draft left the session dir at end" "$D/draft"
assert_eq "shelved file exists" 1 "$(ls "$CAP/shelved/dotfiles--feat-x" | wc -l | tr -d ' ')"
assert_eq "pending_at_end still logged" 1 "$(count_ev pending_at_end)"
assert_file "ended tombstone" "$D/ended"
# SessionEnd with a draft never nudged: shelved, no ignored
new_scenario
mkdir -p "$D"; printf 'quiet draft\n' >"$D/draft"
hook hook-end '{"session_id":"sid-aaa"}'
assert_eq "un-nudged end: no ignored" 0 "$(count_ev ignored)"
assert_eq "un-nudged end: shelved" 1 "$(count_ev draft_shelved)"
# a marker alone shelves nothing
new_scenario
stop "we decided to use B"
hook hook-end '{"session_id":"sid-aaa"}'
assert_eq "marker is not shelved" 0 "$(count_ev draft_shelved)"
assert_nofile "no shelved dir for a marker" "$CAP/shelved"

echo "# draft strikes: followed / dismiss / clear reset the count"
new_scenario
mkdir -p "$D"; printf 'draft\n' >"$D/draft"; prompt "go"; stop "x"; prompt "go"
assert_file "struck once" "$D/draft_strikes"
posttool 'wb append x Decisions -'
assert_nofile "followed resets strikes" "$D/draft_strikes"
new_scenario
mkdir -p "$D"; printf 'draft\n' >"$D/draft"; prompt "go"; stop "x"
hook dismiss ''
assert_nofile "dismiss removes strikes" "$D/draft_strikes"; assert_nofile "dismiss removes draft" "$D/draft"
new_scenario
mkdir -p "$D"; printf 'draft\n' >"$D/draft"; prompt "go"; stop "x"
hook clear ''
assert_nofile "clear removes strikes" "$D/draft_strikes"

echo "# stale drafts: nudge wording, resolution events tagged, cleanup"
stale_draft() { # creates a stale draft for the scenario
  mkdir -p "$D"; printf '### Chose B\n- decided: B\n' >"$D/draft"; printf '1\n' >"$D/draft_stale"
}
stale_flag() { jq -r --arg e "$1" 'select(.event==$e)|.stale // "none"' "$LOG" | tail -1; }
new_scenario; stale_draft
prompt "go"
CTX="$(printf '%s' "$OUT" | jq -r .hookSpecificOutput.additionalContext)"
assert_match "stale nudge prefix" '^\[wb-capture\] A background review drafted' "$CTX"
assert_match "stale nudge: task file changed" 'task file changed while it was being written' "$CTX"
assert_match "stale nudge: may already be recorded" 'may already be recorded' "$CTX"
assert_match "stale nudge: compare with newest entries" 'compare the draft with the newest Decisions entries' "$CTX"
assert_match "stale nudge: still names draft path" "$D/draft" "$CTX"
assert_eq "stale nudge: one line" 1 "$(printf '%s\n' "$CTX" | wc -l | tr -d ' ')"
assert_eq "stale nudge: source sweep" sweep "$(cat "$D/outstanding")"
assert_eq "nudge_fired not tagged" none "$(stale_flag nudge_fired)"
new_scenario; mkdir -p "$D"; printf 'draft\n' >"$D/draft"; prompt "go"
assert_eq "non-stale nudge wording unchanged" '[wb-capture] A background review drafted an unrecorded decision ('"$D"'/draft). Run /wb-decide to review/accept, or /wb-decide dismiss.' "$(printf '%s' "$OUT" | jq -r .hookSpecificOutput.additionalContext)"
# ignored x2 -> ignored + draft_discarded tagged, draft_stale gone
new_scenario; stale_draft
prompt "go"; stop "carry on"
assert_eq "stale ignored tagged" true "$(stale_flag ignored)"
assert_file "draft_stale kept after first ignore" "$D/draft_stale"
prompt "go"; stop "carry on"
assert_eq "stale second ignored tagged" 2 "$(jq -r 'select(.event=="ignored" and .stale==true)|.event' "$LOG" | wc -l | tr -d ' ')"
assert_eq "stale draft_shelved tagged" true "$(stale_flag draft_shelved)"
assert_eq "draft_shelved keeps reason" ignored_twice "$(jq -r 'select(.event=="draft_shelved")|.reason' "$LOG")"
assert_nofile "two strikes removes draft_stale" "$D/draft_stale"
assert_eq "stale shelved file has a stale marker" 1 "$(ls "$CAP"/shelved/dotfiles--feat-x/*.stale | wc -l | tr -d ' ')"
# followed (posttool)
new_scenario; stale_draft; prompt "go"
posttool 'wb append x Decisions -'
assert_eq "stale followed tagged" true "$(stale_flag followed)"
# followed via clear verb
new_scenario; stale_draft; prompt "go"
hook clear ''
assert_eq "stale clear-followed tagged" true "$(stale_flag followed)"
assert_nofile "clear removes draft_stale" "$D/draft_stale"
# dismissed
new_scenario; stale_draft; prompt "go"
hook dismiss ''
assert_eq "stale dismissed tagged" true "$(stale_flag dismissed)"
assert_nofile "dismiss removes draft_stale" "$D/draft_stale"
assert_nofile "dismiss removes draft" "$D/draft"
# dismissed before it was ever nudged
new_scenario; stale_draft
hook dismiss ''
assert_eq "stale dismissed (un-nudged) tagged" true "$(stale_flag dismissed)"
# session end resolves ignored, tagged
new_scenario; stale_draft; prompt "go"
hook hook-end '{"session_id":"sid-aaa"}'
assert_eq "stale end-ignored tagged" true "$(stale_flag ignored)"
# non-stale draft: nothing tagged
new_scenario; mkdir -p "$D"; printf 'draft\n' >"$D/draft"
prompt "go"; stop "x"; prompt "go"; stop "x"
assert_eq "plain ignored untagged" none "$(stale_flag ignored)"
assert_eq "plain draft_shelved untagged" none "$(stale_flag draft_shelved)"
assert_eq "plain shelved file has no stale marker" 0 "$(ls "$CAP"/shelved/dotfiles--feat-x/*.stale 2>/dev/null | wc -l | tr -d ' ')"
new_scenario; mkdir -p "$D"; printf 'draft\n' >"$D/draft"; prompt "go"; posttool 'wb append x Decisions -'
assert_eq "plain followed untagged" none "$(stale_flag followed)"
new_scenario; mkdir -p "$D"; printf 'draft\n' >"$D/draft"; hook dismiss ''
assert_eq "plain dismissed untagged" none "$(stale_flag dismissed)"
# a phrase nudge alongside a stale draft is not tagged
new_scenario; stale_draft; prompt "go"; hook dismiss ''; stale_draft
sha1sum <"$D/draft" | cut -d' ' -f1 >"$D/nudged_draft"
stop "we decided to use B"; prompt "go"
assert_eq "phrase nudge beside stale draft" phrase "$(cat "$D/outstanding")"
stop "ok"
assert_eq "phrase ignore untagged" none "$(stale_flag ignored)"

echo "# engagement marker: a review spanning several turns resolves once"
new_scenario
mkdir -p "$D"; printf '### Chose B\n- decided: B\n' >"$D/draft"
prompt "go"; assert_eq "sweep nudge outstanding" sweep "$(cat "$D/outstanding")"
hook review ''
assert_file "review marks the draft under review" "$D/reviewing"
stop "here is the draft, shall I record it?"
assert_eq "Stop while reviewing: not ignored" 0 "$(count_ev ignored)"
assert_file "nudge carried to the next turn" "$D/outstanding"
prompt "tweak the wording please"
assert_eq "prompt while reviewing: not ignored" 0 "$(count_ev ignored)"
assert_eq "no re-nudge while reviewing" "" "$OUT"
assert_eq "still one nudge_fired" 1 "$(count_ev nudge_fired)"
stop "reworded"
assert_eq "second Stop: still not ignored" 0 "$(count_ev ignored)"
posttool 'wb append x Decisions -'
assert_eq "exactly one followed" 1 "$(count_ev followed)"
assert_eq "zero ignored" 0 "$(count_ev ignored)"
assert_eq "zero draft_shelved" 0 "$(count_ev draft_shelved)"
assert_eq "zero draft_discarded" 0 "$(count_ev draft_discarded)"
assert_nofile "followed removes reviewing" "$D/reviewing"
assert_nofile "followed clears outstanding" "$D/outstanding"

echo "# engagement marker: an abandoned review stops carrying after REVIEW_MAX_TURNS Stops"
new_scenario
mkdir -p "$D"; printf '### Chose B\n- decided: B\n' >"$D/draft"
prompt "go"; hook review ''
for t in 1 2 3 4; do stop "turn $t"; prompt "something else $t"; done
assert_eq "4 carried Stops: not ignored yet" 0 "$(count_ev ignored)"
stop "turn 5"
assert_eq "5th Stop resolves ignored once" 1 "$(count_ev ignored)"
assert_nofile "cap removes reviewing" "$D/reviewing"
assert_eq "cap strikes the draft (kept, not shelved)" 1 "$(cat "$D/draft_strikes" 2>/dev/null)"
assert_file "draft still there" "$D/draft"
prompt "next"
assert_eq "struck draft re-nudged after the cap" sweep "$(cat "$D/outstanding" 2>/dev/null)"

echo "# engagement marker: a plain status does not start a review (status is read-only)"
new_scenario
mkdir -p "$D"; printf '### Chose B\n- decided: B\n' >"$D/draft"
prompt "go"; hook status ''
assert_nofile "status leaves no reviewing" "$D/reviewing"
posttool 'wb append x Decisions -'
assert_eq "unrelated append after status: one followed" 1 "$(count_ev followed)"
assert_nofile "followed: outstanding cleared" "$D/outstanding"
new_scenario
mkdir -p "$D"; printf '### Chose B\n- decided: B\n' >"$D/draft"
prompt "go"; hook status ''; stop "an unrelated turn"
assert_eq "Stop after plain status resolves ignored (no carried review)" 1 "$(count_ev ignored)"
assert_nofile "no reviewing after the Stop" "$D/reviewing"
assert_eq "first ignore strikes the draft" 1 "$(cat "$D/draft_strikes" 2>/dev/null)"

echo "# engagement marker: a second review doesn't reset the carried-Stop counter"
new_scenario
mkdir -p "$D"; printf 'draft\n' >"$D/draft"
prompt "go"; hook review ''; stop "one"; stop "two"
assert_eq "two carried Stops" 2 "$(cat "$D/reviewing")"
hook review ''
assert_eq "review again: counter kept" 2 "$(cat "$D/reviewing")"
stop "three"
assert_eq "counter continues" 3 "$(cat "$D/reviewing")"

echo "# two-phase accept: recording a shelved draft doesn't resolve the live nudge"
new_scenario; PK="$CAP/shelved/dotfiles--feat-x"; SF="$PK/20261018T100000-sid-old.md"
mkdir -p "$D" "$PK"; printf 'live draft\n' >"$D/draft"; printf 'shelved one\n' >"$SF"
prompt "go"; hook review ''; printf '1\n' >"$D/draft_strikes"
assert_eq "sweep nudge outstanding" sweep "$(cat "$D/outstanding")"
hook accept '' --begin "$SF"
assert_eq "begin exit" 0 "$RC"
assert_file "begin writes the one-shot flag" "$D/shelved_accept"
assert_file "begin leaves the draft" "$SF"
assert_eq "begin logs nothing" 0 "$(count_ev shelved_accepted)"
posttool 'wb append x Decisions -'
assert_file "append marks the turn recorded" "$D/recorded"
assert_nofile "append consumes the flag" "$D/shelved_accept"
assert_eq "live nudge still outstanding" sweep "$(cat "$D/outstanding" 2>/dev/null)"
assert_eq "no followed for the shelved record" 0 "$(count_ev followed)"
assert_file "review state kept" "$D/reviewing"
assert_eq "draft_strikes kept" 1 "$(cat "$D/draft_strikes" 2>/dev/null)"
hook accept '' "$SF"
assert_eq "accept exit" 0 "$RC"
assert_nofile "accept deletes the shelved draft" "$SF"
assert_eq "one shelved_accepted" 1 "$(count_ev shelved_accepted)"
assert_eq "still no followed" 0 "$(count_ev followed)"
assert_eq "live nudge untouched by accept" sweep "$(cat "$D/outstanding" 2>/dev/null)"
posttool 'wb append x Decisions -'
assert_eq "the next, unrelated append follows normally" 1 "$(count_ev followed)"
assert_nofile "...and resolves the nudge" "$D/outstanding"
# a leftover flag is dropped by accept <path>, dismiss <path> and a real prompt; a bad path writes none
new_scenario; PK="$CAP/shelved/dotfiles--feat-x"; SF="$PK/20261018T100000-sid-old.md"
mkdir -p "$D" "$PK"; printf 'x\n' >"$SF"; printf 'y\n' >"$PK/20261018T110000-sid-old.md"
hook accept '' --begin "$PK/nope.md"
assert_eq "begin on a bad path exits 1" 1 "$RC"
assert_nofile "begin on a bad path writes no flag" "$D/shelved_accept"
hook accept '' --begin ""
assert_eq "begin with no path exits 1" 1 "$RC"
hook accept '' --begin "$SF"; hook accept '' "$SF"
assert_nofile "accept <path> drops a leftover flag" "$D/shelved_accept"
hook accept '' --begin "$PK/20261018T110000-sid-old.md"; hook dismiss '' "$PK/20261018T110000-sid-old.md"
assert_nofile "dismiss <path> drops a leftover flag" "$D/shelved_accept"
assert_eq "dismiss <path> logs shelved_dismissed" 1 "$(count_ev shelved_dismissed)"
new_scenario; PK="$CAP/shelved/dotfiles--feat-x"; SF="$PK/20261018T100000-sid-old.md"
mkdir -p "$D" "$PK"; printf 'x\n' >"$SF"
hook accept '' --begin "$SF"; assert_file "flag set" "$D/shelved_accept"
prompt "a new turn"
assert_nofile "a real prompt drops an abandoned flag" "$D/shelved_accept"
assert_file "abandoned accept leaves the shelved draft" "$SF"
new_scenario
mkdir -p "$CAP/sid-sa"; printf 'x' >"$CAP/sid-sa/shelved_accept"; touch -d '8 days ago' "$CAP/sid-sa"/* "$CAP/sid-sa"
prompt "hi"
assert_nofile "reaper removes a dir holding only the flag" "$CAP/sid-sa"

echo "# engagement marker: dismiss ends the review, one dismissed"
new_scenario
mkdir -p "$D"; printf 'draft\n' >"$D/draft"
prompt "go"; hook review ''; stop "reviewing"
hook dismiss ''
assert_eq "exactly one dismissed" 1 "$(count_ev dismissed)"
assert_eq "no ignored" 0 "$(count_ev ignored)"
assert_nofile "dismiss removes reviewing" "$D/reviewing"
hook clear ''
new_scenario
mkdir -p "$D"; printf 'draft\n' >"$D/draft"; prompt "go"; hook review ''
hook clear ''
assert_nofile "clear removes reviewing" "$D/reviewing"

echo "# engagement marker: not set for a phrase nudge or an un-nudged draft"
new_scenario
stop "we decided to use B"; prompt "go"
hook review ''
assert_nofile "phrase nudge: no reviewing" "$D/reviewing"
stop "ok"
assert_eq "phrase nudge still ignored normally" 1 "$(count_ev ignored)"
new_scenario
mkdir -p "$D"; printf 'draft\n' >"$D/draft"
hook review ''
assert_nofile "draft not yet nudged: no reviewing" "$D/reviewing"
new_scenario
hook review ''
assert_nofile "nothing pending: no reviewing" "$D/reviewing"

echo "# engagement marker: a phrase nudge cannot displace an outstanding sweep nudge under review"
new_scenario
mkdir -p "$D"; printf 'draft\n' >"$D/draft"
prompt "go"; hook review ''
stop "we decided to use B"
prompt "next"
assert_eq "outstanding still sweep" sweep "$(cat "$D/outstanding")"
assert_eq "no second nudge_fired" 1 "$(count_ev nudge_fired)"

echo "# engagement marker: SessionEnd resolves ignored (once) then shelves, even while reviewing"
new_scenario
mkdir -p "$D"; printf 'draft\n' >"$D/draft"
prompt "go"; hook review ''; stop "reviewing"
hook hook-end '{"session_id":"sid-aaa"}'
assert_eq "end: one ignored" 1 "$(count_ev ignored)"
assert_eq "end: shelved" 1 "$(count_ev draft_shelved)"
assert_eq "end: shelve reason" session_end "$(jq -r 'select(.event=="draft_shelved")|.reason' "$LOG")"
assert_nofile "end: reviewing removed" "$D/reviewing"
assert_nofile "end: outstanding removed" "$D/outstanding"

echo "# engagement marker: the reaper resolves ignored (once) then shelves, even while reviewing"
new_scenario
mkdir -p "$CAP/sid-rv"; printf 'sweep' >"$CAP/sid-rv/outstanding"; printf 'rv draft\n' >"$CAP/sid-rv/draft"; : >"$CAP/sid-rv/reviewing"
printf '%s\n' "$H/tasks/dotfiles--feat-rv.md" >"$CAP/sid-rv/taskpath"
touch -d '8 days ago' "$CAP/sid-rv"/* "$CAP/sid-rv"
prompt "hi"
assert_nofile "reaped dir gone (reviewing removed too)" "$CAP/sid-rv"
assert_eq "reaper: one ignored" 1 "$(count_ev ignored)"
assert_eq "reaper: shelved" 1 "$(count_ev draft_shelved)"
assert_eq "reaper: shelved under the session's task" "rv draft" "$(cat "$CAP"/shelved/dotfiles--feat-rv/*-sid-rv.md)"

echo "# reaper: a draft it cannot shelve keeps its dir (retried next reap), never deleted"
new_scenario
mkdir -p "$CAP/sid-pf" "$CAP/shelved"; printf 'pf draft\n' >"$CAP/sid-pf/draft"
printf 'sweep' >"$CAP/sid-pf/outstanding"
printf '%s\n' "$H/tasks/dotfiles--feat-pf.md" >"$CAP/sid-pf/taskpath"
: >"$CAP/shelved/dotfiles--feat-pf"     # a FILE where the shelved dir must go: mkdir fails
touch -d '8 days ago' "$CAP/sid-pf"/* "$CAP/sid-pf"
prompt "hi"
assert_eq "unshelvable draft kept in place" "pf draft" "$(cat "$CAP/sid-pf/draft" 2>/dev/null)"
assert_eq "no draft_shelved logged" 0 "$(count_ev draft_shelved)"
assert_eq "kept dir: nudge ignored once" 1 "$(count_ev ignored)"
assert_nofile "kept dir: outstanding resolved" "$CAP/sid-pf/outstanding"
assert_eq "kept dir: no pending_orphaned yet" 0 "$(count_ev pending_orphaned)"
# second reap, still blocked: neither event repeats
touch -d '8 days ago' "$CAP/sid-pf"/* "$CAP/sid-pf/.lock" "$CAP/sid-pf" 2>/dev/null; touch -d '2 hours ago' "$CAP/.reaped"
prompt "again"
assert_file "still kept" "$CAP/sid-pf/draft"
assert_eq "still ignored once" 1 "$(count_ev ignored)"
assert_eq "still no pending_orphaned" 0 "$(count_ev pending_orphaned)"
# third reap, blocker gone: shelved, pending_orphaned logged once, no second ignored
rm -f "$CAP/shelved/dotfiles--feat-pf"
touch -d '8 days ago' "$CAP/sid-pf"/* "$CAP/sid-pf/.lock" "$CAP/sid-pf" 2>/dev/null; touch -d '2 hours ago' "$CAP/.reaped"
prompt "third"
assert_nofile "dir reaped once shelving works" "$CAP/sid-pf"
assert_eq "shelved on the retry" 1 "$(count_ev draft_shelved)"
assert_eq "exactly one ignored across all reaps" 1 "$(count_ev ignored)"
assert_eq "exactly one pending_orphaned across all reaps" 1 "$(count_ev pending_orphaned)"

echo "# shelving: nothing is shelved twice and the sweep is unblocked"
new_scenario; PK="$CAP/shelved/dotfiles--feat-x"
mkdir -p "$D"; printf 'one\n' >"$D/draft"
prompt "go"; stop "x"; prompt "go"; stop "x"
printf 'two\n' >"$D/draft"
prompt "go"; stop "x"; prompt "go"; stop "x"
assert_eq "two drafts shelved separately" 2 "$(ls "$PK"/*.md | wc -l | tr -d ' ')"

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
posttool $'session=$(tmux display-message -p \'#S\')\ntask_file=$(tmux show -t "=$session:" -v @task)\nwb append "$task_file" Decisions - <<\'WB_DECISION_END\'\n### t\n- x\nWB_DECISION_END'
assert_file "multi-line /wb-decide shape" "$D/recorded"

echo "# heredoc bodies are not commands"
new_scenario
stop "we decided to use B"; prompt "go"
posttool $'cat > notes.md <<\'EOF\'\nwb append "$t" Decisions -\nEOF'
assert_nofile "heredoc body line does not set recorded" "$D/recorded"
assert_eq "no followed from a heredoc body" 0 "$(count_ev followed)"
assert_file "nudge still outstanding" "$D/outstanding"
for op in '<<EOF' '<<"EOF"' "<<-EOF" "<<-'EOF'" "<< EOF" '<<\EOF'; do
  new_scenario
  posttool "cat > n.md $op"$'\nwb append x Decisions -\nEOF'
  assert_nofile "body of [$op] not matched" "$D/recorded"
done
new_scenario
posttool $'cat > n.md <<-EOF\n\twb append x Decisions -\n\tEOF\ntrue'
assert_nofile "<<- body with tab-indented terminator" "$D/recorded"
new_scenario
posttool $'cat > n.md <<EOF\nbody\nEOF\nwb append x Decisions -'
assert_file "command after the terminator still matches" "$D/recorded"
new_scenario
posttool $'wb append x Decisions - <<\'WB_DECISION_END\'\n### t\n- x\nWB_DECISION_END'
assert_file "operator line itself still matches" "$D/recorded"
new_scenario
posttool $'grep x <<< "wb append y Decisions -"'
assert_nofile "here-string is not a heredoc but is not a command either" "$D/recorded"
new_scenario
posttool $'cat <<<foo\nwb append x Decisions -'
assert_file "here-string does not swallow following lines" "$D/recorded"
new_scenario
posttool $'cat > n.md <<\'EOF\'\nwb append x Decisions -\nnever terminated'
assert_eq "unterminated heredoc: exit 0" 0 "$RC"
assert_nofile "unterminated heredoc body not matched" "$D/recorded"
posttool $'cat <<EOF'
assert_eq "bare heredoc: exit 0" 0 "$RC"
new_scenario
posttool $'cd /tmp\nwb append "$t" Decisions - <<EOF\nbody\nEOF'; assert_file "append on a later line" "$D/recorded"
new_scenario
posttool $'wb append x Handoffs - <<EOF\nsee ## Decisions above\nEOF'; assert_nofile "Handoffs heredoc mentioning Decisions" "$D/recorded"

echo "# clear resolves an outstanding nudge the posttool hook missed"
new_scenario
stop "we decided to use B"; prompt "go"
hook clear ''
assert_eq "clear -> followed" 1 "$(count_ev followed)"
assert_eq "clear followed source" phrase "$(jq -r 'select(.event=="followed")|.source' "$LOG")"
stop "recorded"
assert_eq "no ignored after clear" 0 "$(count_ev ignored)"
new_scenario
stop "we decided to use B"; prompt "go"
posttool 'wb append x Decisions -'; hook clear ''
assert_eq "posttool + clear: followed once" 1 "$(count_ev followed)"

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
posttool 'wb append x Decisions -'     # followed: no strike, hash still matches
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
mkdir -p "$CFG/wb"; printf 'phrases=we decided|bar\n' >"$CFG/wb/capture.conf"
stop "bar"; prompt "x"
assert_match "configured phrase nudged" '\("bar"\)' "$(printf '%s' "$OUT" | jq -r .hookSpecificOutput.additionalContext)"
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

echo "# hook-end: outstanding nudge (turn never reached Stop) -> ignored once"
new_scenario
stop "we decided A"; prompt "go"
hook hook-end '{"session_id":"sid-aaa"}'
assert_eq "end -> ignored" 1 "$(count_ev ignored)"
assert_eq "end ignored source" phrase "$(jq -r 'select(.event=="ignored")|.source' "$LOG")"
assert_nofile "outstanding cleared at end" "$D/outstanding"

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

echo "# reaper: stale dir holding only a draft logs pending_orphaned (draft:true) and is removed"
new_scenario
mkold sid-dr draft
prompt "hi"
assert_nofile "draft-only dir removed" "$CAP/sid-dr"
assert_eq "reaper shelved the draft" 1 "$(count_ev draft_shelved)"
assert_eq "reaper shelve reason" reaped "$(jq -r 'select(.event=="draft_shelved")|.reason' "$LOG")"
assert_eq "reaper shelve under _unknown (no taskpath)" 1 "$(ls "$CAP/shelved/_unknown" | wc -l | tr -d ' ')"
assert_eq "one pending_orphaned" 1 "$(count_ev pending_orphaned)"
assert_eq "orphan sid" sid-dr "$(jq -r 'select(.event=="pending_orphaned")|.session_id' "$LOG")"
assert_eq "orphan draft true" true "$(jq -r 'select(.event=="pending_orphaned")|.draft' "$LOG")"
assert_eq "orphan marker false" false "$(jq -r 'select(.event=="pending_orphaned")|.marker' "$LOG")"
assert_nofile "reaper never treats shelved/ as a session dir" "$CAP/shelved/.lock"
# a draft whose session recorded its task shelves under that task
new_scenario
mkold sid-dt draft taskpath
printf '%s\n' "$H/tasks/dotfiles--feat-old.md" >"$CAP/sid-dt/taskpath"; touch -d '8 days ago' "$CAP/sid-dt/taskpath" "$CAP/sid-dt"
echo "orphan draft" >"$CAP/sid-dt/draft"; touch -d '8 days ago' "$CAP/sid-dt/draft" "$CAP/sid-dt"
prompt "hi"
assert_eq "reaper shelves under the session's task" "orphan draft" "$(cat "$CAP"/shelved/dotfiles--feat-old/*-sid-dt.md)"
# a phrase marker is not shelved
new_scenario
mkold sid-mk marker
prompt "hi"
assert_eq "marker-only reap shelves nothing" 0 "$(count_ev draft_shelved)"

echo "# reaper: dir holding an outstanding nudge logs ignored before removal"
new_scenario
mkold sid-out outstanding
printf 'sweep' >"$CAP/sid-out/outstanding"; touch -d '8 days ago' "$CAP/sid-out/outstanding" "$CAP/sid-out"
prompt "hi"
assert_nofile "removed" "$CAP/sid-out"
assert_eq "one ignored" 1 "$(count_ev ignored)"
assert_eq "ignored sid" sid-out "$(jq -r 'select(.event=="ignored")|.session_id' "$LOG")"
assert_eq "ignored source" sweep "$(jq -r 'select(.event=="ignored")|.source' "$LOG")"

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
touch "$CAP/sid-tmp/ended" "$CAP/sid-tmp/draft.tmp.123" "$CAP/sid-tmp/.lock" "$CAP/sid-tmp/sweep_offset" \
  "$CAP/sid-tmp/draft_strikes" "$CAP/sid-tmp/sweep_failures" "$CAP/sid-tmp/draft_stale" \
  "$CAP/sid-tmp/draft_stale.tmp.77"
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
