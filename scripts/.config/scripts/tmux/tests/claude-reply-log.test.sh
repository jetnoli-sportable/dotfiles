#!/usr/bin/env bash
# Tests for claude-reply-log.sh: the Stop hook that writes each session's turns
# into ~/.claude/replies/<session-id>.md (hook-stop), and the `chain` verb that
# joins a task's reply files across /clear.
#
# Transcripts are the hand-written fixtures in fixtures/reply-log/ (shapes from
# the U1 probe, no real content). tmux is faked by a script on PATH.
# Run: bash scripts/.config/scripts/tmux/tests/claude-reply-log.test.sh
set -uo pipefail

SCRIPT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/claude-reply-log.sh"
FX="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/fixtures/reply-log"
REAL_BASH="$(command -v bash)"
ROOT="$(mktemp -d -t claude-reply-log.XXXXXX)"
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
chmod +x "$FAKEBIN/tmux"
EMPTYBIN="$ROOT/emptybin"; mkdir -p "$EMPTYBIN"

fail=0
ok()   { echo "ok   - $1"; }
bad()  { echo "FAIL - $1${2:+ ($2)}"; fail=1; }
assert_eq()    { [ "$2" = "$3" ] && ok "$1" || bad "$1" "expected [$2], got [$3]"; }
assert_has()   { grep -qF -- "$2" "$3" 2>/dev/null && ok "$1" || bad "$1" "missing [$2]"; }
assert_lacks() { ! grep -qF -- "$2" "$3" 2>/dev/null && ok "$1" || bad "$1" "unexpected [$2]"; }
# count <fixed-string> <file> — lines containing it
count() { grep -cF -- "$1" "$2" 2>/dev/null || true; }
anchors() { grep -c '^<!-- turn ' "$1" 2>/dev/null || true; }

SID=0b1e2c3d-0000-4000-8000-000000000001
n=0
# new_scenario — fresh HOME, reply dir and transcript path (<proj>/<sid>.jsonl)
new_scenario() {
  n=$((n + 1))
  H="$ROOT/s$n"; mkdir -p "$H/proj" "$H/tasks"
  RDIR="$H/replies"; TP="$H/proj/$SID.jsonl"
  OUTF="$RDIR/$SID.md"
  FAKE_TASK=""; IN_TMUX=0
  EXTRA_ENV=()
}
# use_fixture <name> [lines] — copy a fixture (optionally only its first N lines)
use_fixture() {
  if [ -n "${2:-}" ]; then head -n "$2" "$FX/$1.jsonl" >"$TP"; else cp "$FX/$1.jsonl" "$TP"; fi
  if [ -d "$FX/$1/subagents" ]; then mkdir -p "$H/proj/$SID"; cp -r "$FX/$1/subagents" "$H/proj/$SID/"; fi
}
# stop <prompt_id> <last_assistant_message> — run hook-stop; sets OUT, RC
stop() {
  local json
  json="$(jq -nc --arg s "$SID" --arg t "$TP" --arg p "$1" --arg m "$2" --arg c "$H" \
    '{session_id:$s,transcript_path:$t,cwd:$c,prompt_id:$p,hook_event_name:"Stop",stop_hook_active:false,last_assistant_message:$m}')"
  run_hook "$json"
}
run_hook() {
  printf '%s' "$1" >"$H/stdin.json"
  local -a envv=(HOME="$H" REPLY_LOG_DIR="$RDIR" TZ=UTC PATH="$FAKEBIN:$PATH" FAKE_TASK="$FAKE_TASK")
  local -a unset=(-u TMUX -u TMUX_PANE -u WB_CAPTURE_SWEEP -u CLAUDE_CODE_ENTRYPOINT -u CLAUDE_CODE_SESSION_ATTENDED)
  [ "$IN_TMUX" = 1 ] && envv+=(TMUX=fake,1,0 TMUX_PANE=%1)
  OUT="$(env "${unset[@]}" "${envv[@]}" "${EXTRA_ENV[@]}" "$REAL_BASH" "$SCRIPT" hook-stop <"$H/stdin.json" 2>"$H/stderr")"
  RC=$?
}
# section <heading-prefix> — the turn whose `## ` heading contains the text, up to the next turn
section() { awk -v h="$1" 'index($0,"## ")==1 && index($0,h){on=1; print; next} on && /^## /{exit} on' "$OUTF"; }

echo "# plain turn: frontmatter, heading, anchor, full prompt, reply, no thinking"
new_scenario; use_fixture plain
stop p-plain-1 $'# Blue\n\nBlue reads as calm.\n\n## Where it shows up\n\nSkies and deep water.'
assert_eq "exit 0" 0 "$RC"
assert_eq "no stdout" "" "$OUT"
assert_eq "frontmatter opens line 1" "---" "$(head -1 "$OUTF")"
assert_has "frontmatter session_id" "session_id: $SID" "$OUTF"
assert_has "frontmatter task (empty outside tmux)" "task: " "$OUTF"
assert_has "frontmatter cwd" "cwd: $H" "$OUTF"
assert_eq "frontmatter created" 1 "$(grep -cE '^created: [0-9]{4}-[0-9]{2}-[0-9]{2}T' "$OUTF")"
assert_has "turn heading with time and prompt start" "## 2026-10-25 10:00 · Explain the colour blue" "$OUTF"
assert_eq "one anchor" 1 "$(anchors "$OUTF")"
assert_has "anchor carries prompt_id, session_id, ts" "<!-- turn {\"prompt_id\":\"p-plain-1\",\"session_id\":\"$SID\",\"ts\":\"2026-10-25T10:00:00.000Z\"} -->" "$OUTF"
assert_has "full prompt, line 1" "> Explain the colour blue" "$OUTF"
assert_has "full prompt, line 2" "> in two short paragraphs." "$OUTF"
assert_has "reply text" "Skies and deep water." "$OUTF"
assert_has "reply # demoted to ###" "### Blue" "$OUTF"
assert_has "reply ## demoted to ####" "#### Where it shows up" "$OUTF"
assert_lacks "no thinking" "SECRET-THINKING" "$OUTF"
assert_lacks "no artifacts section when empty" "### Artifacts" "$OUTF"
assert_eq "reply text once" 1 "$(count 'Skies and deep water.' "$OUTF")"
assert_eq "no temp dirs left behind" "" "$(ls -A "$RDIR" | grep '^\.work' || true)"

echo "# every text block between tool calls, in order, no tool input/output"
new_scenario; use_fixture multitext
stop p-multi-1 "All done."
assert_eq "three blocks in order" "Starting now.|Middle step.|All done." \
  "$(grep -E '^(Starting now\.|Middle step\.|All done\.)$' "$OUTF" | paste -sd'|')"
assert_lacks "no tool input" "TOOL-INPUT-SHOULD-NOT-APPEAR" "$OUTF"
assert_lacks "no tool output" "TOOL-OUTPUT-SHOULD-NOT-APPEAR" "$OUTF"
assert_has "Write listed as an artifact" "- wrote: /work/notes.txt" "$OUTF"

echo "# transcript lag: final text from last_assistant_message, once; caught up on rerun"
new_scenario; use_fixture multitext 2
stop p-multi-1 "All done."
assert_has "early block present" "Starting now." "$OUTF"
assert_eq "final text from the payload, once" 1 "$(count 'All done.' "$OUTF")"
use_fixture multitext
stop p-multi-1 "All done."
assert_eq "missing middle block recovered" 1 "$(count 'Middle step.' "$OUTF")"
assert_eq "final text still once" 1 "$(count 'All done.' "$OUTF")"
assert_eq "still one anchor" 1 "$(anchors "$OUTF")"

echo "# a turn written short is completed by the next turn's Stop"
new_scenario; use_fixture multitext 4
stop p-multi-1 "All done."
assert_lacks "turn 1 short at first" "Middle step." "$OUTF"
use_fixture multitext
cat >>"$TP" <<'EOF'
{"type":"user","isSidechain":false,"promptId":"p-multi-2","origin":{"kind":"human"},"promptSource":"typed","timestamp":"2026-10-25T11:05:00.000Z","message":{"role":"user","content":"And the second?"}}
{"type":"assistant","isSidechain":false,"timestamp":"2026-10-25T11:05:01.000Z","message":{"role":"assistant","content":[{"type":"text","text":"Second turn reply."}]}}
EOF
stop p-multi-2 "Second turn reply."
assert_eq "turn 1 now complete" 1 "$(count 'Middle step.' "$OUTF")"
assert_eq "turn 1 final text once" 1 "$(count 'All done.' "$OUTF")"
assert_eq "turn 2 present once" 1 "$(count 'Second turn reply.' "$OUTF")"
assert_eq "two anchors" 2 "$(anchors "$OUTF")"
assert_lacks "turn 1 not marked interrupted" "(interrupted)" "$OUTF"

echo "# first Stop with earlier history: only the current turn (no backfill)"
new_scenario; use_fixture history
stop p-hist-4 "Current answer."
assert_eq "one anchor" 1 "$(anchors "$OUTF")"
assert_has "current turn" "Current answer." "$OUTF"
assert_lacks "no earlier prompts" "OLD-PROMPT" "$OUTF"
assert_lacks "no earlier replies" "OLD-REPLY" "$OUTF"
assert_lacks "nothing marked interrupted" "(interrupted)" "$OUTF"

echo "# batched peer messages: one turn, both listed; hand-back and notification headings"
new_scenario; use_fixture batched 4
stop p-bat-2 "Noted both."
assert_eq "one turn for the batch" 1 "$(anchors "$OUTF")"
assert_has "peer heading" "· (message from another session)" "$OUTF"
assert_has "first peer summarised" "other-session-a: PEER-BODY-ONE first line" "$OUTF"
assert_has "second peer summarised" "other-session-b: PEER-BODY-TWO first line" "$OUTF"
assert_lacks "raw peer XML not shown" "<cross-session-message" "$OUTF"
use_fixture batched
stop p-bat-4 "Review is in."
assert_eq "three turns" 3 "$(anchors "$OUTF")"
assert_eq "batch still listed once" 1 "$(count 'PEER-BODY-ONE' "$OUTF")"
assert_has "hand-back is a background agent" "· (background agent finished) general-purpose reported back" "$OUTF"
assert_has "notification heading with its summary" '· (background agent finished) Agent "Review the parser" completed' "$OUTF"
assert_lacks "notification result body not shown" "NOTIFICATION-RESULT-BODY" "$OUTF"

echo "# a prompt typed mid-turn joins that turn's Prompt; mid-turn peer text doesn't"
new_scenario; use_fixture midturn
stop p-mid-1 "Built, and the docs are included."
assert_eq "one anchor" 1 "$(anchors "$OUTF")"
assert_has "mid-turn prompt listed" "> Also include the docs please" "$OUTF"
assert_lacks "mid-turn peer message not listed" "MIDTURN-PEER-TEXT" "$OUTF"

echo "# skill turns are headed /name args; local-command, bash and compaction entries are not turns"
new_scenario; use_fixture skill 8
stop p-sk-1 "Saved."
use_fixture skill
stop p-sk-2 "Resumed."
assert_eq "two turns" 2 "$(anchors "$OUTF")"
assert_has "skill heading" "· /wb-save before clear" "$OUTF"
assert_has "skill prompt" "> /wb-save before clear" "$OUTF"
assert_has "skill without args" "· /wb-resume" "$OUTF"
assert_lacks "no command markup" "<command-message>" "$OUTF"
for s in SKILL-BODY-TEXT LOCAL-CAVEAT-TEXT BASH-STDOUT-TEXT COMPACT-SUMMARY-TEXT; do
  assert_lacks "no $s" "$s" "$OUTF"
done

echo "# artifacts: published URL, written/edited paths de-duplicated, failures dropped, subagent files"
new_scenario; use_fixture artifacts 17
stop p-art-1 "Published; a background agent is writing the summary."
t1="$(section 'Publish the page')"
printf '%s\n' "$t1" >"$H/t1"
assert_has "published URL" "- https://claude.ai/artifact/PUBLISHEDPAGE1" "$H/t1"
assert_eq "written then edited path listed once" 1 "$(count '/work/page.html' "$H/t1")"
assert_has "listed as wrote (first use)" "- wrote: /work/page.html" "$H/t1"
assert_lacks "failed Edit dropped" "/work/other.md" "$H/t1"
assert_lacks "failed Write dropped" "/work/failed.txt" "$H/t1"
assert_lacks "quickstart URL not an artifact" "QUICKSTARTTYPEURL" "$H/t1"
assert_lacks "async launch lists no subagent files yet" "/work/summary.md" "$H/t1"
use_fixture artifacts
stop p-art-2 "The summary is written."
section 'background agent finished' >"$H/t2"
assert_has "subagent's write listed on the finish turn" "- wrote: /work/summary.md" "$H/t2"
assert_has "subagent's other write listed" "- wrote: /work/page.html" "$H/t2"
assert_lacks "no subagent reply text" "SUBAGENT-REPLY-TEXT" "$OUTF"
assert_lacks "no subagent prompt text" "SUBAGENT-PROMPT-TEXT" "$OUTF"

echo "# a blocked Stop's continuation re-renders the same turn"
new_scenario; use_fixture continuation 2
stop p-cont-1 "first answer"
use_fixture continuation
stop p-cont-1 "CONTINUED"
assert_eq "one anchor" 1 "$(anchors "$OUTF")"
assert_eq "first answer once" 1 "$(grep -cx 'first answer' "$OUTF")"
assert_eq "continuation text once" 1 "$(count 'CONTINUED' "$OUTF")"
assert_lacks "stop-hook feedback not shown" "STOP-FEEDBACK-TEXT" "$OUTF"

echo "# parallel hook runs leave one well-formed copy"
new_scenario; use_fixture multitext
for i in 1 2 3 4; do stop p-multi-1 "All done." & done; wait
assert_eq "one anchor after 4 parallel runs" 1 "$(anchors "$OUTF")"
assert_eq "one frontmatter" 2 "$(grep -c '^---$' "$OUTF")"
assert_eq "final text once" 1 "$(count 'All done.' "$OUTF")"

echo "# a turn with no Stop is marked (interrupted) when the next turn completes"
new_scenario; use_fixture interrupted 3
stop p-int-1 "First answer."
use_fixture interrupted
stop p-int-3 "Hi."
assert_eq "three turns" 3 "$(anchors "$OUTF")"
assert_eq "only the middle turn is interrupted" "## 2026-10-25 12:01 · Search everything (interrupted)" "$(grep '(interrupted)' "$OUTF")"
assert_has "its partial reply kept" "Searching now." "$OUTF"

echo "# rendering: headings nest, fences untouched and closed, anchors escaped"
new_scenario; use_fixture markup
stop p-mk-1 "unused"
assert_has "# -> ###" "### Top heading" "$OUTF"
assert_has "## -> ####" "#### Second level" "$OUTF"
assert_has "###### capped" "###### Six deep" "$OUTF"
assert_has "~~~ fence content untouched" "# a shell comment, not a heading" "$OUTF"
assert_has "four-backtick fence content untouched" "# still inside the four-backtick fence" "$OUTF"
assert_has "unclosed fence content untouched" "# unclosed fence comment" "$OUTF"
assert_eq "unclosed fence closed at the turn's end" '```' \
  "$(awk '/# unclosed fence comment/{getline; print; exit}' "$OUTF")"
assert_eq "one real anchor" 1 "$(anchors "$OUTF")"
assert_eq "anchors in heading, prompt and reply escaped" 3 "$(count '<\!-- turn' "$OUTF")"

echo "# guards: each exits 0, prints nothing, writes nothing"
guard_case() {
  local label="$1"; shift
  new_scenario; use_fixture plain
  "$@"
  assert_eq "$label: exit 0" 0 "$RC"
  assert_eq "$label: no stdout" "" "$OUT"
  assert_eq "$label: nothing written" "" "$(ls -A "$RDIR" 2>/dev/null)"
}
g_sweep()   { EXTRA_ENV=(WB_CAPTURE_SWEEP=1); stop p-plain-1 x; }
g_kill()    { mkdir -p "$RDIR"; : >"$RDIR/.disabled"; stop p-plain-1 x; rm -f "$RDIR/.disabled"; }
g_headless(){ EXTRA_ENV=(CLAUDE_CODE_ENTRYPOINT=sdk-cli CLAUDE_CODE_SESSION_ATTENDED=0); stop p-plain-1 x; }
g_notp()    { run_hook "$(jq -nc --arg s "$SID" '{session_id:$s,transcript_path:"",prompt_id:"p-plain-1",last_assistant_message:"x"}')"; }
g_badsid()  { run_hook "$(jq -nc --arg t "$TP" '{session_id:"../evil",transcript_path:$t,prompt_id:"p-plain-1",last_assistant_message:"x"}')"; }
g_nojq()    { EXTRA_ENV=(PATH="$EMPTYBIN"); stop p-plain-1 x; }
g_unread()  { rm -f "$TP"; stop p-plain-1 x; }
g_garbage() { run_hook "not json at all"; }
guard_case "WB_CAPTURE_SWEEP" g_sweep
guard_case "kill switch" g_kill
guard_case "headless claude -p" g_headless
guard_case "empty transcript_path" g_notp
guard_case "bad session id" g_badsid
guard_case "no jq" g_nojq
guard_case "unreadable transcript" g_unread
guard_case "garbage stdin" g_garbage
[ -e "$ROOT/evil.md" ] && bad "bad session id escaped the dir" || ok "bad session id wrote nothing outside"

echo "# task: comes from the tmux session's @task"
new_scenario; use_fixture plain
IN_TMUX=1; FAKE_TASK="$H/tasks/dotfiles--feat-x.md"
stop p-plain-1 x
assert_has "task from @task" "task: $H/tasks/dotfiles--feat-x.md" "$OUTF"
assert_has "session heading names the task" "# dotfiles--feat-x · " "$OUTF"

echo "# files are private"
new_scenario; use_fixture plain
stop p-plain-1 x
assert_eq "dir 700" 700 "$(stat -c %a "$RDIR")"
assert_eq "reply file 600" 600 "$(stat -c %a "$OUTF")"

echo
if [ "$fail" = 0 ]; then echo "ALL PASSED"; else echo "SOME FAILED"; exit 1; fi
