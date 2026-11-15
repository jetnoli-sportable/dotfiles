#!/usr/bin/env bash
# Tests for U2 of the wb continue plan: the request store and the
# `wb continue` verbs (wb-continue.sh), and the lifecycle drops in wb.sh.
# Plain bash against a fixture store, a throwaway git repo as the task's
# worktree, JSONL fixture transcripts, and (for the lifecycle verbs) real tmux
# on ONE private -L socket behind a PATH shim, never the default socket.
# Run: bash scripts/.config/scripts/tmux/tests/wb-continue.test.sh
set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WB="$SELF_DIR/wb.sh"
FIX="$(mktemp -d -t wb-continue-fixture.XXXXXX)"
SOCK="wb-continue-sock-$$"
REAL_TMUX="$(command -v tmux)"

# Isolation FIRST (a past incident wiped ~/code when this was skipped).
export HOME="$FIX/home" XDG_STATE_HOME="$FIX/state" CODE_DIR="$FIX/code" TASKS_DIR="$FIX/tasks"
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
mkdir -p "$HOME" "$XDG_STATE_HOME" "$CODE_DIR" "$TASKS_DIR" "$FIX/bin"
unset TMUX TMUX_PANE CLAUDE_CODE_SESSION_ID WBC_TRANSCRIPT

cat > "$FIX/bin/tmux" <<EOF2
#!/usr/bin/env bash
exec "$REAL_TMUX" -L "$SOCK" -f /dev/null "\$@"
EOF2
chmod +x "$FIX/bin/tmux"
PATH="$FIX/bin:$PATH"

cleanup() { "$REAL_TMUX" -L "$SOCK" kill-server 2>/dev/null || true; rm -rf "${FIX:?}"; }
trap cleanup EXIT

fail=0
assert() { # <desc> <regex> <actual>
  if printf '%s' "$3" | grep -qE -- "$2"; then echo "ok   - $1"
  else echo "FAIL - $1"; echo "       expected match: $2"; echo "       got: $(printf '%s' "$3" | head -8)"; fail=1; fi
}
refute() { # <desc> <regex that must NOT match> <actual>
  if printf '%s' "$3" | grep -qE -- "$2"; then echo "FAIL - $1"; echo "       unexpected match: $2"; echo "       got: $(printf '%s' "$3" | head -8)"; fail=1
  else echo "ok   - $1"; fi
}
assert_eq() { # <desc> <expected> <actual>
  if [ "$2" = "$3" ]; then echo "ok   - $1"; else echo "FAIL - $1"; echo "       expected: $2"; echo "       got:      $3"; fail=1; fi
}

# shellcheck disable=SC1090
source "$WB"
# shellcheck disable=SC1091
source "$SELF_DIR/wb-continue.sh"
set +e
CLAUDE_PROJECTS_DIR="$FIX/projects"

# --- fixtures -----------------------------------------------------------------
WT="$CODE_DIR/proj/.worktrees/x"
mkdir -p "$WT"
git -C "$WT" init -q 2>/dev/null
printf 'one\n' > "$WT/a.txt"
git -C "$WT" add a.txt && git -C "$WT" commit -q -m init

ENTRY_BODY=$'\n**Done:** built the thing\nsecond done line\n\n**In flight:** nothing\n\n**Next:** run the review\n\n```run\n/ce-code-review\n```'
entry_text() { printf '### %s — wb-save\n%s' "${1:-2026-11-15 10:00}" "$ENTRY_BODY"; }

# mk_task <stem> [<entry text, default a rich save>] — frontmatter + one Handoffs entry
mk_task() {
  local stem="$1" entry="${2-$(entry_text)}"
  printf -- '---\nstatus: doing\nrepo: proj\nbranch: x\nworktree: .worktrees/x\ntags: []\ncreated: 2026-11-01\nclosed:\n---\n# Title\n\n## Plan\n\nplan\n\n## Handoffs\n\n%s\n' "$entry" > "$TASKS_DIR/$stem.md"
}
tf() { printf '%s/%s.md\n' "$TASKS_DIR" "$1"; }
handoff_count() { _wb_section_text "$(tf "$1")" Handoffs | grep -c '^### '; }
state_of() { wbc_get "$1" state; }
log_text() { cat "$XDG_STATE_HOME/wb/continue.log" 2>/dev/null; }

# transcripts
T="$FIX/t.jsonl"
tr_user() { jq -nc --arg c "$2" --arg k "$1" '{type:"user",turnOrigin:($k|gsub("-";"_")),origin:{kind:$k},message:{content:$c}}'; }
tr_assistant() { jq -nc --arg m "$1" '{type:"assistant",message:{model:$m,content:[]}}'; }
typed_prompt() { printf '<command-message>wb-continue</command-message>\n<command-name>/wb-continue</command-name>\n<command-args>%s</command-args>' "$1"; }
use_transcript() { WBC_TRANSCRIPT="$T"; export WBC_TRANSCRIPT; }
no_transcript() { unset WBC_TRANSCRIPT; }
SID_OLD=sess-old-1111; SID_NEW=sess-new-2222
export CLAUDE_CODE_SESSION_ID="$SID_OLD"

# restarting <stem> <new-session-id> — what a later unit's helper will do
restarting() { _wbc_lock "$1"; wbc_set test "$1" restarting "test" "new_session_id=$2"; _wbc_unlock "$1"; }
pickup_as() { ( CLAUDE_CODE_SESSION_ID="$1"; wbc_pickup "$2" 2>&1 ); }
id_of() { wbc_get "$1" id; }

# =============================================================================
echo "# stage / arm: the frozen entry, replacement, lane"
# =============================================================================
no_transcript
mk_task proj--s1
out="$(wbc_stage "$(tf proj--s1)" </dev/null 2>&1)"; rc=$?
assert_eq "stage: exit 0" 0 "$rc"
assert "stage: reports a ready request with an id" '^wb continue: ready — .*\(proj--s1@[0-9a-f]{8}\)$' "$out"
D="$XDG_STATE_HOME/wb/continue/proj--s1"
assert_eq "stage: state ready" ready "$(state_of proj--s1)"
assert_eq "stage: typed 0" 0 "$(wbc_get proj--s1 typed)"
assert_eq "stage: command comes from the run block" "/ce-code-review" "$(wbc_get proj--s1 command)"
assert_eq "stage: no instruction file" 0 "$([ -e "$D/instruction" ] && echo 1 || echo 0)"
printf '%s\n' "$(entry_text)" > "$FIX/expected-entry"
if cmp -s "$FIX/expected-entry" "$D/entry.md"; then echo "ok   - frozen entry equals the Handoffs entry byte for byte"
else echo "FAIL - frozen entry differs from the Handoffs entry"; diff "$FIX/expected-entry" "$D/entry.md" | head -5; fail=1; fi
assert_eq "request keeps entry_heading" "### 2026-11-15 10:00 — wb-save" "$(wbc_get proj--s1 entry_heading)"
assert_eq "request keeps entry_sha" "$(sha256sum < "$FIX/expected-entry" | cut -d' ' -f1)" "$(wbc_get proj--s1 entry_sha)"
assert_eq "request keeps the session id" "$SID_OLD" "$(wbc_get proj--s1 session_id)"
assert_eq "request keeps the branch tip" "$(git -C "$WT" rev-parse HEAD)" "$(wbc_get proj--s1 tip)"
assert_eq "request keeps the worktree" "$WT" "$(wbc_get proj--s1 worktree)"
assert "row line: state, reason, done-line, command" \
  '^ready	saved; waits for a release	built the thing	/ce-code-review$' "$(cat "$D/row")"
assert "log line format" \
  '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:]+[+-][0-9]{4} wbc event=stage stem=proj--s1 id=proj--s1@[0-9a-f]{8} state=ready reason="saved; waits for a release"$' "$(log_text)"
assert_eq "no temp files left in the request dir" "" "$(ls "$D" | grep tmp || true)"

# arm twice -> one request holding the second instruction
mk_task proj--s2
echo "first thing" | wbc_arm "$(tf proj--s2)" >/dev/null 2>&1
id1="$(id_of proj--s2)"
echo "second thing" | wbc_arm "$(tf proj--s2)" >/dev/null 2>&1
assert_eq "arm twice: still one request dir" 1 "$(ls "$XDG_STATE_HOME/wb/continue" | grep -c '^proj--s2$')"
assert_eq "arm twice: holds the second instruction" "second thing" "$(cat "$XDG_STATE_HOME/wb/continue/proj--s2/instruction")"
assert_eq "arm twice: command is the second instruction" "second thing" "$(wbc_get proj--s2 command)"
[ "$id1" != "$(id_of proj--s2)" ] && echo "ok   - arm twice: a new id" || { echo "FAIL - arm twice kept the old id"; fail=1; }

# arm replacing a request that had an instruction, with none: the old one goes
printf '' | wbc_arm "$(tf proj--s2)" >/dev/null 2>&1
assert_eq "re-arm without an instruction removes the old instruction file" 0 "$([ -e "$XDG_STATE_HOME/wb/continue/proj--s2/instruction" ] && echo 1 || echo 0)"
assert_eq "re-arm without an instruction takes the run block" "/ce-code-review" "$(wbc_get proj--s2 command)"

# not a rich save: nothing created
mk_task proj--s3 $'### 2026-11-15 10:05 — wb pause (auto)\n\nSession paused.'
out="$(wbc_arm "$(tf proj--s3)" </dev/null 2>&1)"; rc=$?
assert_eq "arm on a non-/wb-save entry: non-zero" 1 "$rc"
assert "arm on a non-/wb-save entry: says why" 'not a /wb-save entry' "$out"
assert_eq "arm on a non-/wb-save entry: nothing created" 0 "$([ -e "$XDG_STATE_HOME/wb/continue/proj--s3" ] && echo 1 || echo 0)"
out="$(wbc_stage "$(tf proj--s3)" </dev/null 2>&1)"; rc=$?
assert_eq "stage on a non-/wb-save entry: non-zero, nothing created" "1 0" "$rc $([ -e "$XDG_STATE_HOME/wb/continue/proj--s3" ] && echo 1 || echo 0)"
# no task, no tmux
out="$(wbc_arm </dev/null 2>&1)"; rc=$?
assert_eq "no task and no tmux session: non-zero" 1 "$rc"
assert "no task and no tmux session: clear message" 'no task given' "$out"

# claimed / restarting requests are left alone
mk_task proj--s4
wbc_stage "$(tf proj--s4)" >/dev/null 2>&1
restarting proj--s4 "$SID_NEW"
id_before="$(id_of proj--s4)"
out="$(wbc_stage "$(tf proj--s4)" </dev/null 2>&1)"; rc=$?
assert_eq "stage over a restarting request: exit 0, request untouched" "0 restarting $id_before" "$rc $(state_of proj--s4) $(id_of proj--s4)"
assert "stage over a restarting request: says why" 'left alone — the request for proj--s4 is restarting' "$out"
out="$(echo x | wbc_arm "$(tf proj--s4)" 2>&1)"; rc=$?
assert_eq "arm over a restarting request: non-zero, request untouched" "1 restarting $id_before" "$rc $(state_of proj--s4) $(id_of proj--s4)"

# lanes, session-initiated
lane() { # <task-stem> <stdin text> [arm args...]
  local s="$1" in="$2"; shift 2
  printf '%s' "$in" | wbc_arm "$@" "$(tf "$s")" >/dev/null 2>&1
  state_of "$s"
}
mk_task proj--l1
assert_eq "session-initiated /ce-work -> ready" ready "$(lane proj--l1 '/ce-work')"
assert_eq "session-initiated /ce-code-review -> armed" armed "$(lane proj--l1 '/ce-code-review')"
assert_eq "session-initiated /compound-engineering:ce-code-review with args -> armed" armed "$(lane proj--l1 '/compound-engineering:ce-code-review the diff')"
assert_eq "session-initiated /code-review -> armed" armed "$(lane proj--l1 '/code-review')"
assert_eq "session-initiated /code-reviewer (not the allow-list) -> ready" ready "$(lane proj--l1 '/code-reviewer')"
assert_eq "no instruction, review run block -> armed" armed "$(lane proj--l1 '')"
assert_eq "decline -> ready even for a review" ready "$(lane proj--l1 '/ce-code-review' --decline)"
assert_eq "decline is recorded" 1 "$(wbc_get proj--l1 declined)"
mk_task proj--l2 "$(entry_text '2026-11-15 11:00' | sed 's#^/ce-code-review$#/ce-work#')"
assert_eq "run block that is not a review, no instruction -> ready" ready "$(lane proj--l2 '')"

# restart-born
mkdir -p "$XDG_STATE_HOME/wb/continue/born"; : > "$XDG_STATE_HOME/wb/continue/born/$SID_OLD"
assert_eq "restart-born, session-initiated review -> ready" ready "$(lane proj--l1 '/ce-code-review')"
assert_eq "restart-born is recorded" 1 "$(wbc_get proj--l1 restart_born)"
{ tr_assistant claude-opus-5-5; tr_user human "$(typed_prompt '/ce-code-review')"; } > "$T"; use_transcript
assert_eq "restart-born, typed /wb-continue -> armed" armed "$(lane proj--l1 'ignored')"
rm -f "$XDG_STATE_HOME/wb/continue/born/$SID_OLD"
assert_eq "not restart-born, session-initiated review -> armed" armed "$(no_transcript; lane proj--l1 '/ce-code-review')"

# typed detection
echo "# typed detection"
RAW=$'say "hi" \'x\' <b> & more\n/ce-work now\nline3'
{ tr_user human "build X"; tr_assistant claude-opus-5-5; tr_user human "$(typed_prompt "$RAW")"; } > "$T"; use_transcript
mk_task proj--t1
printf 'stdin words that must be ignored' | wbc_arm "$(tf proj--t1)" >/dev/null 2>&1
assert_eq "typed: armed" armed "$(state_of proj--t1)"
assert_eq "typed: typed=1" 1 "$(wbc_get proj--t1 typed)"
assert_eq "typed: the instruction is exactly the prompt's arguments" "$RAW" "$(cat "$XDG_STATE_HOME/wb/continue/proj--t1/instruction")"
assert_eq "typed: model comes from the last assistant line" claude-opus-5-5 "$(wbc_get proj--t1 model)"
# args containing the closing tag text: up to the LAST one
{ tr_user human "$(typed_prompt 'a </command-args> b')"; } > "$T"
printf '' | wbc_arm "$(tf proj--t1)" >/dev/null 2>&1
assert_eq "typed: arguments may contain </command-args>" 'a </command-args> b' "$(cat "$XDG_STATE_HOME/wb/continue/proj--t1/instruction")"
# typed with no args
{ tr_user human $'<command-message>wb-continue</command-message>\n<command-name>/wb-continue</command-name>'; } > "$T"
printf 'stdin' | wbc_arm "$(tf proj--t1)" >/dev/null 2>&1
assert_eq "typed with no arguments: armed, no instruction, run block is the command" "armed 0 /ce-code-review" \
  "$(state_of proj--t1) $([ -e "$XDG_STATE_HOME/wb/continue/proj--t1/instruction" ] && echo 1 || echo 0) $(wbc_get proj--t1 command)"

# typed, but the saving session declines (Jet must switch the model first)
{ tr_user human "$(typed_prompt 'switch to Opus, then /ce-plan')"; } > "$T"
printf '' | wbc_arm --decline "$(tf proj--t1)" >/dev/null 2>&1
assert_eq "typed but declined -> ready, still typed=1" "ready 1" "$(state_of proj--t1) $(wbc_get proj--t1 typed)"

# a Skill-tool turn: the turn opener is Jet's "build X"
{ tr_user human "build X"; tr_assistant claude-opus-5-5; } > "$T"
assert_eq "Skill-tool turn opened by 'build X' with /ce-work -> ready" ready "$(lane proj--t1 '/ce-work')"
assert_eq "...and typed=0" 0 "$(wbc_get proj--t1 typed)"
# other prompt sources are not typed
for kind in task-notification peer auto-continuation; do
  { tr_user human "build X"; tr_user "$kind" "$(typed_prompt '/ce-code-review')"; } > "$T"
  assert_eq "opener from '$kind' is not typed" "ready 0" "$(lane proj--t1 '/ce-work') $(wbc_get proj--t1 typed)"
done
{ jq -nc --arg c "$(typed_prompt "/ce-code-review")" '{type:"user",message:{content:$c}}'; } > "$T"
assert_eq "headless prompt (no turnOrigin) is not typed" "ready 0" "$(lane proj--t1 '/ce-work') $(wbc_get proj--t1 typed)"
{ jq -nc --arg c "$(typed_prompt 'x')" '{type:"user",turnOrigin:"human",origin:{kind:"human"},message:{content:[{type:"text",text:$c}]}}'; } > "$T"
assert_eq "human prompt with non-string content is not typed" "ready 0" "$(lane proj--t1 '/ce-work') $(wbc_get proj--t1 typed)"
# a cron-fired prompt after an earlier typed one: scheduled, no origin, same content
{ tr_user human "$(typed_prompt 'earlier typed')"; jq -nc --arg c "$(typed_prompt '/ce-code-review')" '{type:"user",turnOrigin:"scheduled",wakeupSource:"schedule_wakeup",message:{content:$c}}'; } > "$T"
assert_eq "a cron-fired /wb-continue after an earlier typed one is not typed" "ready 0" "$(lane proj--t1 '/ce-work') $(wbc_get proj--t1 typed)"
# the committed real-capture fixture (scrubbed transcript lines)
FXT="$SELF_DIR/tests/fixtures/hook-payloads/transcript-continue-sources.jsonl"
sed -n 1,2p "$FXT" > "$T"
assert_eq "fixture: the typed /wb-continue line is typed, args kept raw" "armed 1 typed \"quoted\" <angle> & amp" \
  "$(lane proj--t1 '/ce-work') $(wbc_get proj--t1 typed) $(cat "$XDG_STATE_HOME/wb/continue/proj--t1/instruction")"
sed -n 1,10p "$FXT" > "$T"
assert_eq "fixture: cron-fired /wb-continue (latest turn opener) after typed ones is not typed" "ready 0" "$(lane proj--t1 '/ce-work') $(wbc_get proj--t1 typed)"
sed -n 1,12p "$FXT" > "$T"
assert_eq "fixture: task-notification openers are not typed" "ready 0" "$(lane proj--t1 '/ce-work') $(wbc_get proj--t1 typed)"
sed -n 1,9p "$FXT" > "$T"
assert_eq "fixture: a Skill-tool turn (opener is the human prompt, tool results follow) is not typed" "ready 0" "$(lane proj--t1 '/ce-work') $(wbc_get proj--t1 typed)"
{ tr_user human "$(typed_prompt 'x')"; printf 'not json {{{\n'; } > "$T"
assert_eq "a malformed line is skipped, the earlier typed prompt still counts" "armed 1" "$(lane proj--t1 'x') $(wbc_get proj--t1 typed)"
WBC_TRANSCRIPT="$FIX/missing.jsonl"
assert_eq "missing transcript is not typed" "ready 0" "$(lane proj--t1 '/ce-work') $(wbc_get proj--t1 typed)"
assert_eq "missing transcript: model blank" "" "$(wbc_get proj--t1 model)"
no_transcript
mkdir -p "$HOME/.claude/projects/-some-dir"
{ tr_user human "$(typed_prompt 'found by glob')"; } > "$HOME/.claude/projects/-some-dir/$SID_OLD.jsonl"
assert_eq "transcript found by globbing ~/.claude/projects/*/<session-id>.jsonl" "armed 1" "$(lane proj--t1 'x') $(wbc_get proj--t1 typed)"
rm -f "$HOME/.claude/projects/-some-dir/$SID_OLD.jsonl"

# an instruction and a different run block
echo "# command selection and pickup"
no_transcript
mk_task proj--c1
printf 'do the other thing' | wbc_arm "$(tf proj--c1)" >/dev/null 2>&1
restarting proj--c1 "$SID_NEW"
out="$(pickup_as "$SID_NEW" "$(id_of proj--c1)")"; rc=$?
assert_eq "pickup with instruction: exit 0" 0 "$rc"
cmd_after="$(printf '%s\n' "$out" | awk '/^Command to carry out:/{f=1;next} f')"
assert_eq "pickup prints only the instruction as the command" "do the other thing" "$cmd_after"
assert "pickup prints the frozen entry verbatim" '\*\*Done:\*\* built the thing' "$out"

# round trip of a hostile instruction
mk_task proj--c2
printf '%s' "$RAW" | wbc_arm "$(tf proj--c2)" >/dev/null 2>&1
restarting proj--c2 "$SID_NEW"
out="$(pickup_as "$SID_NEW" "$(id_of proj--c2)")"
cmd_after="$(printf '%s\n' "$out" | awk '/^Command to carry out:/{f=1;next} f')"
assert_eq "quotes, newlines, a leading slash command round-trip through pickup" "$RAW" "$cmd_after"

# no instruction: the run block is the command
mk_task proj--c3
wbc_stage "$(tf proj--c3)" >/dev/null 2>&1
restarting proj--c3 "$SID_NEW"
out="$(pickup_as "$SID_NEW" "$(id_of proj--c3)")"
assert_eq "no instruction: the run block is the command" "/ce-code-review" "$(printf '%s\n' "$out" | awk '/^Command to carry out:/{f=1;next} f')"
# no instruction, empty run block
mk_task proj--c4 "$(printf '### 2026-11-15 10:00 — wb-save\n\n**Done:** x\n\n**Next:** think')"
wbc_stage "$(tf proj--c4)" >/dev/null 2>&1
restarting proj--c4 "$SID_NEW"
out="$(pickup_as "$SID_NEW" "$(id_of proj--c4)")"
assert "no command at all: says so" 'Command to carry out: none recorded' "$out"

# the helper could not carry the model: the pick-up says so
mk_task proj--c5
wbc_stage "$(tf proj--c5)" >/dev/null 2>&1
_wbc_lock proj--c5; wbc_set test proj--c5 restarting "test" "new_session_id=$SID_NEW" model_fallback=1; _wbc_unlock proj--c5
out="$(pickup_as "$SID_NEW" "$(id_of proj--c5)")"
assert "model fallback: the pick-up names it" "Note: the old session's model could not be read" "$out"
mk_task proj--c6
wbc_stage "$(tf proj--c6)" >/dev/null 2>&1
restarting proj--c6 "$SID_NEW"
refute "no model fallback: no note" "model could not be read" "$(pickup_as "$SID_NEW" "$(id_of proj--c6)")"

# pickup success: one Handoffs entry, request removed, second pickup fails
mk_task proj--p1
wbc_stage "$(tf proj--p1)" >/dev/null 2>&1
P1="$(id_of proj--p1)"
restarting proj--p1 "$SID_NEW"
before="$(handoff_count proj--p1)"
out="$(pickup_as "$SID_NEW" "$P1")"; rc=$?
assert_eq "pickup: exit 0" 0 "$rc"
assert_eq "pickup: exactly one Handoffs entry afterwards" 1 "$(handoff_count proj--p1)"
H="$(_wb_section_text "$(tf proj--p1)" Handoffs)"
assert "pickup: entry heading is a wb continue (auto) one" '^### [0-9-]+ [0-9:]+ — wb continue \(auto\)$' "$(printf '%s\n' "$H" | grep '^### ')"
assert "pickup: entry names the old session id" "old session $SID_OLD" "$H"
assert "pickup: entry says claude --resume reopens it" "claude --resume $SID_OLD" "$H"
assert "pickup: entry names the save's timestamp" 'save of 2026-11-15 10:00' "$H"
assert_eq "pickup: request removed" 0 "$([ -e "$XDG_STATE_HOME/wb/continue/proj--p1" ] && echo 1 || echo 0)"
assert "pickup: printed in order: entry, then the command" '=== Frozen save entry \(verbatim\) ===' "$out"
assert "pickup: log line" 'wbc event=pickup stem=proj--p1 .* state=dropped reason="picked up by the fresh session"' "$(log_text)"
cks="$(cksum < "$(tf proj--p1)")"
out="$(pickup_as "$SID_NEW" "$P1")"; rc=$?
assert_eq "second pickup: non-zero" 1 "$rc"
assert "second pickup: refused with the fallback" 'refused — no continue request for proj--p1' "$out"
assert "second pickup: names the manual fallback" '/clear, then /wb-resume' "$out"
assert_eq "second pickup: writes nothing" "$cks" "$(cksum < "$(tf proj--p1)")"
assert_eq "second pickup: no dir recreated" 0 "$([ -e "$XDG_STATE_HOME/wb/continue/proj--p1" ] && echo 1 || echo 0)"

# refusals
echo "# refusals"
arm_restarting() { # <stem> — a fresh restarting request; sets REQ
  mk_task "$1"; wbc_stage "$(tf "$1")" >/dev/null 2>&1; REQ="$(id_of "$1")"; restarting "$1" "$SID_NEW"
}
check_refusal() { # <desc> <stem> <regex>
  local out rc cks; cks="$(cksum < "$(tf "$2")")"
  out="$(pickup_as "$SID_NEW" "$REQ")"; rc=$?
  assert_eq "$1: non-zero" 1 "$rc"
  assert "$1: reason" "refused — $3" "$out"
  assert "$1: manual fallback shown" '/clear, then /wb-resume' "$out"
  assert_eq "$1: request set to refused with the reason" "refused" "$(state_of "$2")"
  assert "$1: the reason is on the request" "$3" "$(wbc_get "$2" reason)"
  assert_eq "$1: task file untouched" "$cks" "$(cksum < "$(tf "$2")")"
  assert "$1: logged" "wbc event=pickup stem=$2 .* state=refused reason=\".*$3" "$(log_text)"
}
arm_restarting proj--r1
sed -i 's/^\*\*Done:\*\* built the thing/**Done:** CHANGED/' "$(tf proj--r1)"
check_refusal "changed entry" proj--r1 'the save entry changed since it was armed'

arm_restarting proj--r2
mk_task proj--r2 "$(entry_text '2026-11-15 12:00')"
check_refusal "newer Handoffs entry" proj--r2 'a newer Handoffs entry landed since the save'

arm_restarting proj--r3
printf 'two\n' > "$WT/b.txt"; git -C "$WT" add b.txt && git -C "$WT" commit -q -m two
check_refusal "moved branch tip" proj--r3 'branch moved since the save'
# (the worktree now has a new tip; later requests snapshot it)

arm_restarting proj--r4
printf 'edited\n' >> "$WT/a.txt"
check_refusal "changed working tree (tracked edit)" proj--r4 'working tree changed since the save'
git -C "$WT" checkout -q -- a.txt

# an edit to an already-dirty file, and an untracked file's content
printf 'dirty\n' >> "$WT/a.txt"; printf 'u1\n' > "$WT/untracked.txt"
arm_restarting proj--r5
printf 'dirtier\n' >> "$WT/a.txt"
check_refusal "edit to an already-dirty file" proj--r5 'working tree changed since the save'
arm_restarting proj--r6
printf 'u2\n' > "$WT/untracked.txt"
check_refusal "edit to an untracked file" proj--r6 'working tree changed since the save'
git -C "$WT" checkout -q -- a.txt; rm -f "$WT/untracked.txt"

# unchanged dirty tree passes
printf 'dirty\n' >> "$WT/a.txt"; printf 'u1\n' > "$WT/untracked.txt"
arm_restarting proj--r7
out="$(pickup_as "$SID_NEW" "$REQ")"; rc=$?
assert_eq "an unchanged dirty working tree still picks up" 0 "$rc"
git -C "$WT" checkout -q -- a.txt; rm -f "$WT/untracked.txt"

# identity refusals leave the request alone
arm_restarting proj--r8
out="$(pickup_as "$SID_NEW" "proj--other@deadbeef")"; rc=$?
assert_eq "another task's request id (no request there): non-zero" 1 "$rc"
assert "another task's request id: reason" 'refused — no continue request for proj--other' "$out"
assert_eq "...and this task's request is untouched" "restarting $REQ" "$(state_of proj--r8) $(id_of proj--r8)"
out="$(pickup_as "$SID_NEW" "proj--r8@deadbeef")"; rc=$?
assert_eq "a stale id for a task that has a request: non-zero, request untouched" "1 restarting" "$rc $(state_of proj--r8)"
assert "a stale id: reason" 'request id does not match' "$out"
out="$(pickup_as "some-other-session" "$REQ")"; rc=$?
assert_eq "a session that is not the pre-chosen one: non-zero" 1 "$rc"
assert "wrong session: reason" 'refused — pick-up from a session other than the one the restart started' "$out"
assert "wrong session: fallback shown" '/clear, then /wb-resume' "$out"
assert_eq "wrong session: request stays restarting, the right session can still pick up" restarting "$(state_of proj--r8)"
out="$(pickup_as "" "$REQ")"; rc=$?
assert_eq "no session id at all: refused" 1 "$rc"
out="$(pickup_as "$SID_NEW" "$REQ")"; rc=$?
assert_eq "the right session then succeeds" 0 "$rc"
mk_task proj--r9; wbc_stage "$(tf proj--r9)" >/dev/null 2>&1
out="$(pickup_as "$SID_NEW" "$(id_of proj--r9)")"; rc=$?
assert_eq "a request not in the restarting state is refused" "1 ready" "$rc $(state_of proj--r9)"
assert "not restarting: reason" 'is ready, not restarting' "$out"
arm_restarting proj--r10
rm -f "$(tf proj--r10)"
out="$(pickup_as "$SID_NEW" "$REQ")"; rc=$?
assert_eq "task file gone: refused" "1 refused" "$rc $(state_of proj--r10)"
assert "task file gone: reason" 'the task file is gone' "$out"

# status / drop
echo "# status, drop, end to end"
mk_task proj--d1
wbc_stage "$(tf proj--d1)" >/dev/null 2>&1
out="$(wbc_status "$(tf proj--d1)")"
assert "status prints fields" '^state=ready$' "$out"
assert "status prints the id" "^id=proj--d1@[0-9a-f]{8}$" "$out"
out="$(wbc_drop "$(tf proj--d1)")"
assert "drop says it dropped" 'dropped the request for proj--d1' "$out"
assert_eq "drop removes the dir" 0 "$([ -e "$XDG_STATE_HOME/wb/continue/proj--d1" ] && echo 1 || echo 0)"
assert "drop is logged" 'wbc event=drop stem=proj--d1 .* state=dropped' "$(log_text)"
assert "status with no request" '^no continue request for proj--d1$' "$(wbc_status "$(tf proj--d1)")"
assert "release is a stub that exits 2" 'not built yet' "$(wbc_release 2>&1)"; wbc_release >/dev/null 2>&1; assert_eq "release exit code" 2 "$?"

# the real dispatch arm (lazy source) as a subprocess
mk_task proj--e1
out="$(bash "$WB" continue stage "$(tf proj--e1)" </dev/null 2>&1)"; rc=$?
assert_eq "wb continue stage via the real dispatch: exit 0" 0 "$rc"
assert "wb continue stage via the real dispatch: ready" '^wb continue: ready' "$out"
out="$(bash "$WB" continue status proj--e1 2>&1)"
assert "wb continue status via the dispatch (fuzzy task ref)" '^state=ready$' "$out"
out="$(bash "$WB" continue bogus 2>&1)"; rc=$?
assert_eq "wb continue with an unknown verb: exit 2" 2 "$rc"
assert "wb help lists the new verbs" 'wb continue pickup <request-id>' "$(bash "$WB" help 2>&1)"
bash "$WB" continue drop proj--e1 >/dev/null 2>&1

# =============================================================================
echo "# lifecycle verbs drop the request"
# =============================================================================
declare -f wb_branch_has_open_pr >/dev/null && wb_branch_has_open_pr() { return 1; }
live_req() { # <stem> — a request for the stem, state ready
  mk_task "$1"; wbc_stage "$(tf "$1")" >/dev/null 2>&1
}
has_req() { [ -e "$XDG_STATE_HOME/wb/continue/$1/request" ] && echo yes || echo no; }

# pause (which composes down)
live_req proj--life-pause
tmux new-session -d -s lp-pause
tmux set-option -t =lp-pause: @task "$(tf proj--life-pause)" >/dev/null
assert_eq "before wb pause: the request exists" yes "$(has_req proj--life-pause)"
out="$(cmd_pause lp-pause 2>&1)"; rc=$?
assert_eq "wb pause: exit 0" 0 "$rc"
assert_eq "wb pause removed the request" no "$(has_req proj--life-pause)"
assert "wb pause: logged" 'wbc event=pause stem=proj--life-pause .* state=dropped' "$(log_text)"
tmux kill-session -t =lp-pause 2>/dev/null

# down
live_req proj--life-down
tmux new-session -d -s lp-down
tmux set-option -t =lp-down: @task "$(tf proj--life-down)" >/dev/null
out="$(cmd_down lp-down 2>&1)"; rc=$?
assert_eq "wb down: exit 0" 0 "$rc"
assert_eq "wb down removed the request" no "$(has_req proj--life-down)"
assert "wb down: logged" 'wbc event=down stem=proj--life-down .* state=dropped' "$(log_text)"
tmux kill-session -t =lp-down 2>/dev/null

# done (a store-only close: no live session by that name)
live_req proj--life-done
out="$(cmd_done proj--life-done </dev/null 2>&1)"; rc=$?
assert_eq "wb done (store-only): exit 0" 0 "$rc"
assert_eq "wb done removed the request" no "$(has_req proj--life-done)"
assert "wb done: logged" 'wbc event=done stem=proj--life-done .* state=dropped' "$(log_text)"

# restart: brings a task's session back (wb resume replaced by a fake)
live_req proj--life-restart
mkdir -p "$CODE_DIR/proj/.worktrees/x"
cat > "$FIX/fake-wb.sh" <<'EOF2'
#!/usr/bin/env bash
[ "$1" = resume ] || exit 2
tmux new-session -d -s "proj--x" -n agent
sleep 0.3
EOF2
chmod +x "$FIX/fake-wb.sh"
SELF_SAVED="${SELF:-}"; SELF="$FIX/fake-wb.sh"
tmux new-session -d -s start
export WB_RESTART_PROMPT_TIMEOUT=2
TMUX="$(tmux display-message -p '#{socket_path},#{pid},0')"; export TMUX
TMUX_PANE="$(tmux display-message -p -t =start: '#{pane_id}')"; export TMUX_PANE
LIST="$FIX/list"; printf 'proj--life-restart\n' > "$LIST"
cmd_restart --dry-run "$LIST" >/dev/null 2>&1
assert_eq "wb restart --dry-run keeps the request" yes "$(has_req proj--life-restart)"
out="$(cmd_restart "$LIST" 2>&1)"; rc=$?
assert_eq "wb restart: removed the request" no "$(has_req proj--life-restart)"
assert "wb restart: logged" 'wbc event=restart stem=proj--life-restart .* state=dropped' "$(log_text)"
unset TMUX TMUX_PANE
tmux kill-session -t =proj--x 2>/dev/null
tmux kill-session -t =start 2>/dev/null
SELF="$SELF_SAVED"

# the call sites are in the verbs themselves
for v in cmd_pause cmd_down cmd_done cmd_restart; do
  assert "$v calls wb_continue_drop" 'wb_continue_drop ' "$(declare -f "$v")"
done

echo
if [ "$fail" -eq 0 ]; then echo "ALL PASS"; else echo "FAILURES"; fi
exit "$fail"
