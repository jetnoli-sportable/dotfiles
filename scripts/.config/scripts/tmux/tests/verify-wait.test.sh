#!/usr/bin/env bash
# Tests for claude/.claude/skills/verify-behaviour/scripts/verify-wait.sh (U1 of
# docs/plans/2026-10-25-0240-feat-verify-behaviour-watcher-plan.md).
#
# Like decision-buffer-open.test.sh, the script under test is a standalone
# script: every scenario runs it as a subprocess against a fixture directory
# (invented transcripts, capture log, task files and checks.md; nothing under
# ~/code/tasks, ~/.local/state or ~/.claude is read or written). `tmux` and `wb`
# are stubs first on PATH that log their arguments; no real tmux server starts.
# `wait` is launched in the background with a fixture parent pid and a 0.2s poll,
# under `timeout`, so a broken scenario cannot hang the suite.
#
# Run: bash scripts/.config/scripts/tmux/tests/verify-wait.test.sh
#      (VERIFY_SCRIPT=<path> points it at another script, used to show red.)
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../../.." && pwd)" # no git: worktree .git pointers do not resolve in the Docker mount
SCRIPT="${VERIFY_SCRIPT:-$REPO_ROOT/claude/.claude/skills/verify-behaviour/scripts/verify-wait.sh}"
FIXTURE="$(mktemp -d -t verify-wait-fixture.XXXXXX)"
PARENT_PIDS=""
WAIT_PIDS=""
cleanup() {
  local p
  for p in $WAIT_PIDS $PARENT_PIDS; do kill "$p" 2>/dev/null; done
  rm -rf "${FIXTURE:?}"
}
trap cleanup EXIT

fail=0
assert() { # <desc> <expected-regex> <actual>
  if printf '%s' "$3" | grep -qE "$2"; then
    echo "ok   - $1"
  else
    echo "FAIL - $1"
    echo "       expected match: $2"
    echo "       got: $(printf '%s' "$3" | head -8)"
    fail=1
  fi
}
assert_not() { # <desc> <regex-that-must-not-match> <actual>
  if printf '%s' "$3" | grep -qE "$2"; then
    echo "FAIL - $1"
    echo "       unexpected match: $2"
    echo "       got: $(printf '%s' "$3" | head -8)"
    fail=1
  else
    echo "ok   - $1"
  fi
}
assert_eq() { # <desc> <expected> <actual>
  if [ "$2" = "$3" ]; then echo "ok   - $1"; else echo "FAIL - $1 (expected '$2', got '$3')"; fail=1; fi
}

# --- fixture helpers ------------------------------------------------------------

SCEN=0
setup() { # fresh fixture tree and environment for one scenario
  SCEN=$((SCEN + 1))
  FX="$FIXTURE/s$SCEN"
  mkdir -p "$FX/tasks/dossiers/feat" "$FX/projects/proj1" "$FX/projects/self" "$FX/state/wb/capture" "$FX/bin"
  export TASKS_DIR="$FX/tasks" XDG_STATE_HOME="$FX/state" CLAUDE_PROJECTS_DIR="$FX/projects"
  export VERIFY_POLL_SECS=0.2 VERIFY_SELF_DIR=self WB_VERIFY_WATCHER=1
  export TMUX_LOG="$FX/tmux.log" WB_LOG="$FX/wb.log"
  : >"$TMUX_LOG"; : >"$WB_LOG"
  printf '#!/bin/sh\necho "$@" >> "$TMUX_LOG"\n' >"$FX/bin/tmux"
  printf '#!/bin/sh\nprintf "%%s\\n" "$*" >> "$WB_LOG"\n' >"$FX/bin/wb"
  chmod +x "$FX/bin/tmux" "$FX/bin/wb"
  export PATH="$FX/bin:$ORIG_PATH"
  sleep 300 & PARENT=$!; PARENT_PIDS="$PARENT_PIDS $PARENT"
  export VERIFY_PARENT_PID="$PARENT"
  STATE="$FX/state/wb/verify"
  CHECKS="$TASKS_DIR/dossiers/feat/checks.md"
  TASKF="$TASKS_DIR/proj--task-a.md"
  TLOG="$FX/projects/proj1/sess1.jsonl"
  CLOG="$FX/state/wb/capture/log.jsonl"
}
ORIG_PATH="$PATH"

write_checks() { # <live_since> — checks C1 (transcript), C2 (capture-log), C3 (decisions)
  cat >"$CHECKS" <<EOF
# Demo checks
feature: demo
scope: proj--task-a
live_since: $1

## C1. Peer message arrives
kind: match
trigger: transcript /ZEBRA-PROPAGATE/
evidence: the receiving transcript
met when: the message is quoted
broken when: never delivered

## C2. Draft shelved
kind: match
trigger: capture-log /"event":"draft_shelved"/
evidence: the capture log
met when: logged
broken when: not logged

## C3. Decision recorded
kind: judge
trigger: decisions:proj--task-a /needle/
evidence: the task file
met when: bullet present
broken when: absent
EOF
}

tline() { # <json-text-content> — a user line with an old-enough timestamp
  jq -nc --arg t "$1" '{type:"user",timestamp:"2026-10-25T00:00:00.000Z",message:{content:$t}}'
}
peer_line() { # <msg_id> <body>
  jq -nc --arg id "$1" --arg b "$2" '{type:"user",timestamp:"2026-10-25T00:00:01.000Z",origin:{kind:"peer",msg_id:$id},message:{content:("<cross-session-message from=\"x\">" + $b + "</cross-session-message>")}}'
}
seed_transcript() { tline "hello there" >"$TLOG"; }
seed_task() { # bullets under Decisions, a Handoffs section
  cat >"$TASKF" <<'EOF'
---
status: doing
---
## Decisions

- first decision, nothing special

## Handoffs

### note
EOF
}

start_wait() { # background wait; sets WPID and OUT
  OUT="$FX/wait.out.$RANDOM"
  timeout 20 bash "$SCRIPT" wait >"$OUT" 2>&1 &
  WPID=$!; WAIT_PIDS="$WAIT_PIDS $WPID"
}
wait_ready() { local i; for i in $(seq 1 50); do [ -f "$STATE/ready" ] && return 0; sleep 0.1; done; return 1; }
await_exit() { local i; for i in $(seq 1 $(($1 * 10))); do kill -0 "$WPID" 2>/dev/null || return 0; sleep 0.1; done; return 1; }
running() { kill -0 "$WPID" 2>/dev/null; }
stop_wait() { kill "$WPID" 2>/dev/null; wait "$WPID" 2>/dev/null; }
vw() { bash "$SCRIPT" "$@"; }

# first_line / hit-line count of a wait's output
first_line() { head -n 1 "$OUT"; }
hit_count() { grep -c '^hit=' "$OUT"; }

# =============================================================================
echo "# Scenario: peer message wakes wait, hit names check and quoted line"
setup; write_checks 2020-01-01T00:00:00Z; seed_transcript
start_wait; wait_ready
peer_line m1 "ZEBRA-PROPAGATE ping from a sibling" >>"$TLOG"
await_exit 3; rc=$?
assert_eq "wait exited within a few polls" 0 "$rc"
assert "first line is HIT" '^HIT$' "$(first_line)"
out="$(cat "$OUT")"
assert "hit carries check id C1" 'check=C1 ' "$out"
assert "hit carries the checks file" "checks=$CHECKS " "$out"
assert "hit carries source and file" "source=transcript file=$TLOG " "$out"
assert "hit carries a byte range" 'range=[0-9]+-[0-9]+ ' "$out"
assert "hit quotes the matching text" 'text=.*ZEBRA-PROPAGATE ping from a sibling' "$out"
assert_eq "exactly one hit line" 1 "$(hit_count)"

# =============================================================================
echo "# Scenario: capture-log event matches, others do not"
setup; write_checks 2020-01-01T00:00:00Z; seed_transcript
echo '{"ts":"2026-10-25T00:00:00+00:00","session_id":"s","task":"proj--task-a","event":"muted"}' >"$CLOG"
start_wait; wait_ready
echo '{"ts":"2026-10-25T00:01:00+00:00","session_id":"s","task":"proj--task-a","event":"unmuted"}' >>"$CLOG"
sleep 1
running; rc=$?; assert_eq "non-matching capture line does not wake" 0 "$rc"
echo '{"ts":"2026-10-25T00:02:00+00:00","session_id":"s","task":"proj--task-a","event":"draft_shelved"}' >>"$CLOG"
await_exit 3; rc=$?
assert_eq "matching capture line wakes" 0 "$rc"
assert "hit is C2 from capture-log" 'check=C2 source=capture-log' "$(cat "$OUT")"

# =============================================================================
echo "# Scenario: Decisions bullet via write-then-rename wakes; Handoffs edit does not"
setup; write_checks 2020-01-01T00:00:00Z; seed_transcript; seed_task
start_wait; wait_ready
{ cat "$TASKF"; echo "more handoff notes with needle in them"; } >"$TASKF.tmp" && mv "$TASKF.tmp" "$TASKF"
sleep 1
running; rc=$?; assert_eq "an edit under Handoffs alone does not wake" 0 "$rc"
awk '/^## Handoffs/ && !d { print "- second decision mentioning the needle"; print ""; d=1 } { print }' "$TASKF" >"$TASKF.tmp" && mv "$TASKF.tmp" "$TASKF"
await_exit 3; rc=$?
assert_eq "a new Decisions bullet wakes" 0 "$rc"
assert "hit is C3 from the decisions source, bullet 2" 'check=C3 source=decisions:proj--task-a .* range=2-2 text=second decision mentioning the needle' "$(cat "$OUT")"

# =============================================================================
echo "# Scenario: hand-backs, tool results and queue-operation lines are filtered"
setup; write_checks 2020-01-01T00:00:00Z; seed_transcript
start_wait; wait_ready
jq -nc '{type:"user",timestamp:"2026-10-25T00:00:02.000Z",origin:{handback:"agent-1"},message:{content:"ZEBRA-PROPAGATE in a subagent report"}}' >>"$TLOG"
jq -nc '{type:"user",timestamp:"2026-10-25T00:00:03.000Z",message:{content:[{type:"tool_result",tool_use_id:"t",content:"ZEBRA-PROPAGATE in a tool result"}]}}' >>"$TLOG"
jq -nc '{type:"queue-operation",timestamp:"2026-10-25T00:00:04.000Z",operation:"enqueue",content:"ZEBRA-PROPAGATE queued"}' >>"$TLOG"
sleep 1
running; rc=$?; assert_eq "hand-back, tool_result and queue-operation lines do not wake" 0 "$rc"
jq -nc '{type:"assistant",timestamp:"2026-10-25T00:00:05.000Z",message:{content:[{type:"text",text:"saw ZEBRA-PROPAGATE arrive"}]}}' >>"$TLOG"
await_exit 3; rc=$?
assert_eq "an assistant text block does wake (positive control)" 0 "$rc"
assert "the hit quotes the text block" 'text=saw ZEBRA-PROPAGATE arrive' "$(cat "$OUT")"

# =============================================================================
echo "# Scenario: hook_additional_context wakes, skill_listing does not"
setup; write_checks 2020-01-01T00:00:00Z; seed_transcript
start_wait; wait_ready
jq -nc '{type:"attachment",timestamp:"2026-10-25T00:00:02.000Z",attachment:{type:"skill_listing",content:"ZEBRA-PROPAGATE is quoted in a skill listing"}}' >>"$TLOG"
sleep 1
running; rc=$?; assert_eq "skill_listing attachment does not wake" 0 "$rc"
jq -nc '{type:"attachment",timestamp:"2026-10-25T00:00:03.000Z",attachment:{type:"hook_additional_context",content:"ZEBRA-PROPAGATE injected by a hook"}}' >>"$TLOG"
await_exit 3; rc=$?
assert_eq "hook_additional_context attachment wakes" 0 "$rc"
assert "the hit quotes attachment.content" 'text=ZEBRA-PROPAGATE injected by a hook' "$(cat "$OUT")"

# =============================================================================
echo "# Scenario: a half-written line is not consumed until it completes"
setup; write_checks 2020-01-01T00:00:00Z; seed_transcript
start_wait; wait_ready
full="$(peer_line m9 'ZEBRA-PROPAGATE split write')"
printf '%s' "${full:0:60}" >>"$TLOG"
sleep 1
running; rc=$?; assert_eq "no wake while the line has no newline" 0 "$rc"
printf '%s\n' "${full:60}" >>"$TLOG"
await_exit 3; rc=$?
assert_eq "wakes once the line completes" 0 "$rc"
assert_eq "the completed line is one hit" 1 "$(hit_count)"

# =============================================================================
echo "# Scenario: capture log rotation loses and repeats nothing"
setup; write_checks 2020-01-01T00:00:00Z; seed_transcript
for i in 1 2 3 4 5 6; do echo "{\"ts\":\"2026-10-25T00:00:0$i+00:00\",\"session_id\":\"s\",\"task\":\"proj--task-a\",\"event\":\"filler_event_number_$i\"}" >>"$CLOG"; done
VERIFY_POLL_SECS=1.5 start_wait; wait_ready
# Line A lands in the old file, which is rotated away; line B opens the new, smaller file.
echo '{"ts":"2026-10-25T00:10:00+00:00","task":"proj--task-a","event":"draft_shelved","draft":"A"}' >>"$CLOG"
mv "$CLOG" "$CLOG.1"
echo '{"ts":"2026-10-25T00:11:00+00:00","task":"proj--task-a","event":"draft_shelved","draft":"B"}' >"$CLOG"
await_exit 5; rc=$?
assert_eq "wait exited after rotation" 0 "$rc"
out="$(cat "$OUT")"
assert_eq "both lines arrive in one delivery" 2 "$(hit_count)"
assert "line A from the rotated file is delivered" '"draft":"A"' "$out"
assert "line B from the new file is delivered" '"draft":"B"' "$out"
start_wait; wait_ready; sleep 2
running; rc=$?; assert_eq "re-arming does not read either line again" 0 "$rc"
stop_wait

# =============================================================================
echo "# Scenario: a new or changed checks.md wakes with CHECKS-CHANGED"
setup; write_checks 2020-01-01T00:00:00Z; seed_transcript
start_wait; wait_ready
mkdir -p "$TASKS_DIR/dossiers/other"
cp "$CHECKS" "$TASKS_DIR/dossiers/other/checks.md"
await_exit 3; rc=$?
assert_eq "wait exited for a new checks file" 0 "$rc"
assert "result is CHECKS-CHANGED" '^CHECKS-CHANGED$' "$(first_line)"
start_wait; wait_ready
sleep 1.1; echo "" >>"$CHECKS"; echo "## C4. Added later" >>"$CHECKS"
await_exit 3; rc=$?
assert_eq "wait exited for an edited checks file" 0 "$rc"
assert "result is CHECKS-CHANGED again" '^CHECKS-CHANGED$' "$(first_line)"

# =============================================================================
echo "# Scenario: empty live_since contributes no triggers, list shows waiting"
setup; write_checks ""; seed_transcript
start_wait; wait_ready
peer_line m1 "ZEBRA-PROPAGATE while waiting for rollout" >>"$TLOG"
sleep 1
running; rc=$?; assert_eq "a not-yet-live file never wakes wait" 0 "$rc"
stop_wait
out="$(vw list)"
assert "list shows C1 as waiting" 'state=waiting feature=demo check=C1 waiting_for=[0-9]+[mhd]' "$out"
assert_eq "all three checks are waiting" 3 "$(printf '%s\n' "$out" | grep -c 'state=waiting')"

# =============================================================================
echo "# Scenario: transcripts that started before live_since are not scanned"
setup; write_checks 2026-10-25T12:00:00Z
jq -nc '{type:"user",timestamp:"2026-10-25T01:00:00.000Z",message:{content:"old session"}}' >"$TLOG"
NEWLOG="$FX/projects/proj1/sess2.jsonl"
jq -nc '{type:"user",timestamp:"2026-10-25T13:00:00.000Z",message:{content:"new session"}}' >"$NEWLOG"
start_wait; wait_ready
peer_line m1 "ZEBRA-PROPAGATE in the old session" >>"$TLOG"
sleep 1
running; rc=$?; assert_eq "old session (first line before live_since) does not wake" 0 "$rc"
peer_line m2 "ZEBRA-PROPAGATE in the new session" >>"$NEWLOG"
await_exit 3; rc=$?
assert_eq "new session wakes" 0 "$rc"
assert "hit names the new session file" "file=$NEWLOG " "$(cat "$OUT")"

# =============================================================================
echo "# Scenario: history hits are delivered once, on the first arm after a file goes live"
setup; write_checks 2020-01-01T00:00:00Z; seed_transcript
peer_line h1 "ZEBRA-PROPAGATE from before the watcher started" >>"$TLOG"
start_wait; await_exit 3; rc=$?
assert_eq "first arm exits at once with the historical hit" 0 "$rc"
assert "historical hit delivered" 'check=C1 .*ZEBRA-PROPAGATE from before' "$(cat "$OUT")"
start_wait; wait_ready; sleep 1
running; rc=$?; assert_eq "second arm does not replay history" 0 "$rc"
stop_wait

# =============================================================================
echo "# Scenario: undelivered pending hits exit at once; delivered ones do not; ack clears"
setup; write_checks 2020-01-01T00:00:00Z; seed_transcript
mkdir -p "$STATE"
printf 'abc1234567\037%s\037hit=abc1234567 checks=%s check=C1 source=transcript file=/x range=1-2 text=pending text\n' 0 "$CHECKS" >"$STATE/pending.tsv"
start_wait; await_exit 3; rc=$?
assert_eq "undelivered hit makes a new wait exit at once" 0 "$rc"
assert "the pending hit is printed" 'hit=abc1234567 .*text=pending text' "$(cat "$OUT")"
start_wait; wait_ready; sleep 1
running; rc=$?; assert_eq "the now-delivered hit does not exit the next wait" 0 "$rc"
stop_wait
out="$(vw status)"
assert "status still lists the delivered, unacked hit" '\[delivered\] hit=abc1234567' "$out"
out="$(vw ack abc1234567)"
assert "ack reports the hit" 'acked abc1234567' "$out"
assert "status is clean after ack" 'unacked: 0' "$(vw status)"
vw ack nope >/dev/null 2>&1; rc=$?
assert_eq "acking an unknown hit fails" 1 "$rc"

# =============================================================================
echo "# Scenario: a second wait prints ALREADY-ARMED; a dead pid's lock is taken over"
setup; write_checks 2020-01-01T00:00:00Z; seed_transcript
start_wait; wait_ready
before="$(cksum <"$STATE/positions.tsv")"
OUT2="$FX/second.out"
timeout 10 bash "$SCRIPT" wait >"$OUT2" 2>&1
assert "second wait prints ALREADY-ARMED" '^ALREADY-ARMED$' "$(head -n 1 "$OUT2")"
assert_eq "positions untouched by the refused arm" "$before" "$(cksum <"$STATE/positions.tsv")"
running; rc=$?; assert_eq "the first wait keeps running" 0 "$rc"
stop_wait
setup; write_checks 2020-01-01T00:00:00Z; seed_transcript
mkdir -p "$STATE"; echo "999999 stale" >"$STATE/lock"
start_wait
if wait_ready; then echo "ok   - a lock whose pid is dead is taken over"; else echo "FAIL - stale lock not taken over"; fail=1; fi
stop_wait

# =============================================================================
echo "# Scenario: BAD-LAUNCH without the launch marker touches nothing"
setup; write_checks 2020-01-01T00:00:00Z; seed_transcript
out="$(env -u WB_VERIFY_WATCHER timeout 5 bash "$SCRIPT" wait 2>&1)"
assert "prints BAD-LAUNCH first" '^BAD-LAUNCH' "$out"
if [ -e "$STATE" ]; then echo "FAIL - state dir was created"; fail=1; else echo "ok   - no state dir, no lock, no positions"; fi

# =============================================================================
echo "# Scenario: the watcher's own transcript folder, task file, verdicts.md and capture lines never wake it"
setup; write_checks 2020-01-01T00:00:00Z; seed_transcript
cat >>"$CHECKS" <<'EOF'

## C4. Watcher's own decisions
kind: match
trigger: decisions:dotfiles--verify-behaviour-watcher /needle/
evidence: x
met when: x
broken when: x
EOF
WTASK="$TASKS_DIR/dotfiles--verify-behaviour-watcher.md"
printf '## Decisions\n\n- start\n' >"$WTASK"
start_wait; wait_ready
peer_line s1 "ZEBRA-PROPAGATE in the watcher's own transcript" >>"$FX/projects/self/own.jsonl"
printf '## Decisions\n\n- start\n- a needle in the watcher task\n' >"$WTASK.tmp" && mv "$WTASK.tmp" "$WTASK"
echo "- 2026-10-25T00:00:00Z | demo/C3 | met | s | needle" >>"$TASKS_DIR/dossiers/feat/verdicts.md"
echo '{"ts":"2026-10-25T00:02:00+00:00","task":"dotfiles--verify-behaviour-watcher","event":"draft_shelved"}' >>"$CLOG"
sleep 1.2
running; rc=$?; assert_eq "none of the watcher's own writes woke it" 0 "$rc"
peer_line s2 "ZEBRA-PROPAGATE in a sibling transcript" >>"$TLOG"
await_exit 3; rc=$?
assert_eq "a real event still wakes (positive control)" 0 "$rc"

# =============================================================================
echo "# Scenario: a peer message with a repeated msg_id is one hit"
setup; write_checks 2020-01-01T00:00:00Z; seed_transcript
start_wait; wait_ready
{ peer_line dup1 "ZEBRA-PROPAGATE twice"; peer_line dup1 "ZEBRA-PROPAGATE twice"; } >>"$TLOG"
await_exit 3
assert_eq "same origin.msg_id yields one hit" 1 "$(hit_count)"

# =============================================================================
echo "# Scenario: parent process gone"
setup; write_checks 2020-01-01T00:00:00Z; seed_transcript
start_wait; wait_ready
kill "$PARENT"; wait "$PARENT" 2>/dev/null
await_exit 3; rc=$?
assert_eq "wait exits when the parent is gone" 0 "$rc"
assert "result is PARENT-GONE" '^PARENT-GONE$' "$(first_line)"

# =============================================================================
echo "# Scenario: record appends to verdicts.md and calls wb append once"
setup; write_checks 2020-01-01T00:00:00Z
out="$(vw record "$CHECKS" C1 met 'the line said ZEBRA-PROPAGATE' 'session sess1 at 00:00' 2>&1)"; rc=$?
assert_eq "record exits 0" 0 "$rc"
V="$TASKS_DIR/dossiers/feat/verdicts.md"
assert_eq "one verdict line" 1 "$(wc -l <"$V" | tr -d ' ')"
assert "line format: time | feature/id | state | source | quote" '^- [0-9T:Z-]+ \| demo/C1 \| met \| session sess1 at 00:00 \| the line said ZEBRA-PROPAGATE$' "$(cat "$V")"
assert_eq "wb called exactly once" 1 "$(wc -l <"$WB_LOG" | tr -d ' ')"
assert "wb append <watcher task> Verdicts <line>" '^append dotfiles--verify-behaviour-watcher Verdicts - [0-9T:Z-]+ \| demo/C1 \| met' "$(cat "$WB_LOG")"
assert_eq "no temp file left beside checks.md" "" "$(ls -A "$TASKS_DIR/dossiers/feat" | grep '^\.verdicts\.')"
assert "list reflects the last verdict" 'state=met feature=demo check=C1 ' "$(vw list)"
vw record "$CHECKS" C1 open 'reopened by Jet' 'jet' >/dev/null
assert "a later line wins (reopened)" 'state=open feature=demo check=C1 ' "$(vw list)"
vw record "$CHECKS" C1 waiting q s >/dev/null 2>&1; rc=$?
assert_eq "waiting can't be recorded" 1 "$rc"
vw record "$CHECKS" NOPE met q s >/dev/null 2>&1; rc=$?
assert_eq "unknown check id is refused" 1 "$rc"

# =============================================================================
echo "# Scenario: broken/proposed set @verify_alert, met does not, seen clears"
setup; write_checks 2020-01-01T00:00:00Z
vw record "$CHECKS" C1 met q s >/dev/null
assert_eq "met does not touch tmux" "" "$(cat "$TMUX_LOG")"
vw record "$CHECKS" C2 partial q s >/dev/null
assert_eq "partial does not touch tmux" "" "$(cat "$TMUX_LOG")"
vw record "$CHECKS" C2 broken q s >/dev/null
assert "broken sets the global option to the count, which tmux.conf draws as ⚑N" '^set -g @verify_alert 1$' "$(cat "$TMUX_LOG")"
: >"$TMUX_LOG"
vw record "$CHECKS" C3 proposed q s >/dev/null
assert "proposed raises the count" '^set -g @verify_alert 2$' "$(cat "$TMUX_LOG")"
: >"$TMUX_LOG"
vw seen
assert "seen unsets it" '^set -gu @verify_alert' "$(cat "$TMUX_LOG")"
setup; write_checks 2020-01-01T00:00:00Z
printf '#!/bin/sh\nexit 1\n' >"$FX/bin/tmux"
vw record "$CHECKS" C1 broken q s >/dev/null 2>&1; rc=$?
assert_eq "record succeeds when tmux isn't running" 0 "$rc"

# =============================================================================
echo "# Scenario: scan --since caps at 20 hits per check and moves nothing"
setup; write_checks 2020-01-01T00:00:00Z
tline "start" >"$TLOG"
for i in $(seq 1 25); do peer_line "p$i" "ZEBRA-PROPAGATE number $i" >>"$TLOG"; done
out="$(vw scan --since 2020-01-01T00:00:00Z "$CHECKS")"
assert "scan prints SCAN first" '^SCAN$' "$(printf '%s\n' "$out" | head -n 1)"
assert_eq "at most 20 hits for C1" 20 "$(printf '%s\n' "$out" | grep -c 'check=C1 ')"
assert "the cap keeps the latest hits" 'number 25' "$out"
assert_eq "no positions written" "no" "$([ -e "$STATE/positions.tsv" ] && echo yes || echo no)"
assert_eq "nothing pending" "no" "$([ -s "$STATE/pending.tsv" ] && echo yes || echo no)"

# =============================================================================
echo "# Scenario: selftest passes on today's keys and fails loudly without them"
setup
cat >"$TLOG" <<'EOF'
{"type":"user","timestamp":"2026-10-25T00:00:00.000Z","message":{"content":"hi"}}
{"type":"user","origin":{"kind":"peer","msg_id":"m"},"message":{"content":"x"}}
{"type":"attachment","attachment":{"type":"hook_additional_context","content":"y"}}
EOF
out="$(vw selftest)"; rc=$?
assert_eq "selftest passes" 0 "$rc"
assert "says OK" '^SELFTEST-OK' "$out"
setup
echo '{"kind":"renamed","payload":{"content":"hi"}}' >"$TLOG"
out="$(vw selftest)"; rc=$?
assert_eq "selftest fails without the keys" 1 "$rc"
assert "names the missing keys" 'SELFTEST-FAIL.*message.*origin|SELFTEST-FAIL.*origin.*message' "$out"

echo
if [ "$fail" -eq 0 ]; then echo "ALL PASS"; else echo "SOME FAILED"; fi
exit "$fail"
