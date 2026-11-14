#!/usr/bin/env bash
# Tests for review-stamp-hook.sh, the Claude Code Stop/SubagentStop hook that
# stamps a wb task as reviewed after a finished /ce-code-review.
#
# Fake tmux and wb.sh on PATH/WB_SH, fixture run folders under a fixture dir,
# transcripts built in the shapes of tests/fixtures/hook-payloads/. Nothing
# touches a real tmux server or task file. Needs jq and git.
#
# Run: bash scripts/.config/scripts/tmux/tests/review-stamp-hook.test.sh
# ok and bad only echo and set a flag, so A && ok || bad cannot misfire.
# shellcheck disable=SC2015
set -uo pipefail

TESTS="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK="${HOOK:-$TESTS/../review-stamp-hook.sh}"
FIX="$TESTS/fixtures/hook-payloads"
ROOT="$(mktemp -d -t review-stamp.XXXXXX)"
trap 'rm -rf "$ROOT"' EXIT

UIDN="$(id -u)"
RUNS="$ROOT/tmp/compound-engineering-$UIDN/ce-code-review"
SHIM="$ROOT/shim"
WB_LOG="$ROOT/wb.log"
REPO="$ROOT/repo"
mkdir -p "$RUNS" "$SHIM"

fail=0
[ -x "$HOOK" ] || {
  echo "FAIL - hook is not executable (Claude Code runs it directly): $HOOK"
  fail=1
}

# Fake tmux: answers from env, never contacts a server.
cat >"$SHIM/tmux" <<'SH'
#!/usr/bin/env bash
case "$1" in
display) printf '%s\n' "${FAKE_SESSION:-}" ;;
show)
  [ "$3" = "=${FAKE_SESSION:-}:" ] || exit 1
  case "${*: -1}" in
  @wb_repo) printf '%s\n' "${FAKE_REPO:-}" ;;
  @wb_slug) printf '%s\n' "${FAKE_SLUG:-}" ;;
  esac ;;
esac
exit 0
SH
cat >"$SHIM/wb.sh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$WB_LOG"
if [ -n "${WB_FAIL:-}" ]; then echo "$WB_FAIL" >&2; echo "second line" >&2; exit 1; fi
echo "wb reviewed: $2 marked reviewed"
SH
chmod +x "$SHIM/tmux" "$SHIM/wb.sh"

git init -q -b feat-x "$REPO"
git -C "$REPO" -c user.name=t -c user.email=t@t commit -q --allow-empty -m init
git -C "$REPO" branch other-br

ok() { echo "ok   - $1"; }
bad() {
  echo "FAIL - $1"
  fail=1
}

n=0
newid() {
  n=$((n + 1))
  NID="$(printf '20261114-2343%02d-%08x' "$n" "$((0x263fdd00 + n))")"
}
# mkrun <id> <branch> [finish-input-args]; metadata.json marks a finished run.
mkrun() {
  mkdir -p "$RUNS/$1"
  [ -n "$2" ] && jq -n --arg b "$2" --arg r "$1" '{branch:$b, head_sha:"abc", run_id:$r, verdict:"ok"}' >"$RUNS/$1/metadata.json"
  [ -z "${3:-}" ] || jq -n --arg a "$3" '{invocation:{arguments:$a}}' >"$RUNS/$1/finish-input.json"
}
# transcript <file> <run-id> <style> [args]: an invocation line, then a line naming the run folder.
transcript() {
  local f="$1" id="$2" style="$3" args="${4:-}"
  : >"$f"
  echo '{"type":"queue-operation","operation":"enqueue","content":"unrelated"}' >>"$f"
  case "$style" in
    skill) jq -nc --arg a "$args" '{type:"assistant",message:{content:[{type:"tool_use",name:"Skill",input:{skill:"compound-engineering:ce-code-review",args:$a}}]}}' >>"$f" ;;
    skill-noargs) jq -nc '{type:"assistant",message:{content:[{type:"tool_use",name:"Skill",input:{skill:"ce-code-review"}}]}}' >>"$f" ;;
    typed) jq -nc --arg a "$args" '{type:"user",message:{role:"user",content:("<command-message>ce-code-review</command-message>\n<command-name>/ce-code-review</command-name>\n<command-args>"+$a+"</command-args>")}}' >>"$f" ;;
    none) ;;
  esac
  jq -nc --arg p "$RUNS/$id" '{type:"user",message:{content:[{type:"tool_result",content:("Run artifacts: "+$p+"/ now\nmore")}]}}' >>"$f"
}
stop_payload() { jq --arg t "$1" --arg c "${2:-$REPO}" '.transcript_path=$t | .cwd=$c' "$FIX/Stop.json"; }
sub_payload() { jq --arg t "$1" --arg a "$2" --arg c "$REPO" '.transcript_path=$t | .agent_transcript_path=$a | .cwd=$c' "$FIX/SubagentStop.json"; }

# run_hook <payload>: sets OUT and CALLS (wb.sh invocations); a wb session unless FAKE_SLUG is emptied.
run_hook() {
  : >"$WB_LOG"
  OUT="$(printf '%s' "$1" | env ${NO_PANE:+-u TMUX_PANE} PATH="$SHIM:$PATH" WB_LOG="$WB_LOG" WB_SH="$SHIM/wb.sh" \
    TMUX_PANE="${PANE:-}" \
    FAKE_SESSION=sess FAKE_REPO=dotfiles FAKE_SLUG="${FAKE_SLUG-feat-x}" ${WB_FAIL:+WB_FAIL="$WB_FAIL"} "$HOOK")"
  RC=$?
  CALLS="$(wc -l <"$WB_LOG" | tr -d ' ')"
}
PANE=%1

check() { # <name> <expected-calls> [expected-output-substring|-]
  local name="$1" calls="$2" sub="${3:-}"
  [ "$RC" = 0 ] || {
    bad "$name (exit $RC)"
    return
  }
  [ "$CALLS" = "$calls" ] || {
    bad "$name (wb.sh calls: $CALLS, wanted $calls)"
    return
  }
  case "$sub" in
    "") [ -z "$OUT" ] || {
      bad "$name (unexpected output: $OUT)"
      return
    } ;;
    *) [[ "$OUT" == *"$sub"* ]] || {
      bad "$name (output lacks '$sub': $OUT)"
      return
    } ;;
  esac
  ok "$name"
}

# --- stamping on the session's own branch ---------------------------------
newid
id="$NID"
mkrun "$id" feat-x
transcript "$ROOT/t1.jsonl" "$id" skill "base:origin/development"
run_hook "$(stop_payload "$ROOT/t1.jsonl")"
check "finished run on the session's branch is stamped" 1 "stamped"
[ "$(cat "$WB_LOG")" = "reviewed sess" ] && ok "wb.sh reviewed gets the session name" || bad "wb.sh argv: $(cat "$WB_LOG")"
[ -e "$RUNS/$id/.wb-stamped" ] && ok "marker written in the run folder" || bad "no .wb-stamped marker"
jq -e '.systemMessage | test("sess") and test("'"${id##*-}"'|'"$id"'")' <<<"$OUT" >/dev/null && ok "systemMessage names the session and run" || bad "systemMessage: $OUT"

run_hook "$(stop_payload "$ROOT/t1.jsonl")"
check "same payload again: no call, no output" 0

# --- runs that must not stamp ---------------------------------------------
newid
id="$NID"
mkrun "$id" ""
transcript "$ROOT/t2.jsonl" "$id" skill ""
run_hook "$(stop_payload "$ROOT/t2.jsonl")"
check "run without metadata.json (review died): no call" 0

newid
id="$NID"
mkrun "$id" feat-x 123
transcript "$ROOT/t3.jsonl" "$id" skill ""
run_hook "$(stop_payload "$ROOT/t3.jsonl")"
check "finish-input.json arguments 123 (PR review): no call" 0

newid
id="$NID"
mkrun "$id" feat-x
transcript "$ROOT/t4.jsonl" "$id" skill "other-br"
run_hook "$(stop_payload "$ROOT/t4.jsonl")"
check "Skill args naming another existing branch: no call" 0

newid
id="$NID"
mkrun "$id" feat-x 123
transcript "$ROOT/t4b.jsonl" "$id" skill "base:origin/development"
run_hook "$(stop_payload "$ROOT/t4b.jsonl")"
check "finish-input.json wins over the transcript's args" 0

newid
id="$NID"
mkrun "$id" feat-x
transcript "$ROOT/t5.jsonl" "$id" skill "base:origin/development review branch feat-x"
run_hook "$(stop_payload "$ROOT/t5.jsonl")"
check "base: args with prose naming the current branch: stamped" 1 "stamped"

newid
id="$NID"
mkrun "$id" feat-x
transcript "$ROOT/t6.jsonl" "$id" typed "base:origin/development"
run_hook "$(stop_payload "$ROOT/t6.jsonl")"
check "typed /ce-code-review command line: stamped" 1 "stamped"

newid
id="$NID"
mkrun "$id" feat-x
transcript "$ROOT/t6b.jsonl" "$id" typed "other-br"
run_hook "$(stop_payload "$ROOT/t6b.jsonl")"
check "typed command naming another branch: no call" 0

newid
id="$NID"
mkrun "$id" feat-x
transcript "$ROOT/t7.jsonl" "$id" skill-noargs
run_hook "$(stop_payload "$ROOT/t7.jsonl")"
check "Skill call without args: own branch, stamped" 1 "stamped"

newid
id="$NID"
mkrun "$id" feat-x
transcript "$ROOT/t7b.jsonl" "$id" none
run_hook "$(stop_payload "$ROOT/t7b.jsonl")"
check "no invocation found in the transcript: own branch, stamped" 1 "stamped"

newid
id="$NID"
mkrun "$id" other-br
transcript "$ROOT/t8.jsonl" "$id" skill ""
run_hook "$(stop_payload "$ROOT/t8.jsonl")"
check "metadata branch differs from the cwd branch: no call" 0

newid
id="$NID"
mkrun "$id" feat-x
newid
transcript "$ROOT/t9.jsonl" "$NID" skill ""
run_hook "$(stop_payload "$ROOT/t9.jsonl")"
check "finished run folder not named in the transcript: no call" 0

newid
real="$NID"
mkrun "$real" feat-x
newid
id="$NID"
ln -s "$RUNS/$real" "$RUNS/$id"
transcript "$ROOT/t10.jsonl" "$id" skill ""
run_hook "$(stop_payload "$ROOT/t10.jsonl")"
check "run folder that is a symlink: ignored" 0

# --- session checks ---------------------------------------------------------
newid
id="$NID"
mkrun "$id" feat-x
transcript "$ROOT/t11.jsonl" "$id" skill ""
FAKE_SLUG="" run_hook "$(stop_payload "$ROOT/t11.jsonl")"
check "non-wb tmux session (no @wb_slug): no call, no output" 0
NO_PANE=1 PANE="" run_hook "$(stop_payload "$ROOT/t11.jsonl")"
check "no TMUX_PANE: no call, no output" 0
[ ! -e "$RUNS/$id/.wb-stamped" ] && ok "skipped runs stay unmarked" || bad "marker written for a skipped run"

# --- SubagentStop ---------------------------------------------------------
newid
id="$NID"
mkrun "$id" feat-x
newid
transcript "$ROOT/parent.jsonl" "$NID" none
transcript "$ROOT/agent.jsonl" "$id" skill ""
run_hook "$(sub_payload "$ROOT/parent.jsonl" "$ROOT/agent.jsonl")"
check "SubagentStop with agent_transcript_path naming the run: stamped" 1 "stamped"

# --- failure ----------------------------------------------------------------
newid
id="$NID"
mkrun "$id" feat-x
transcript "$ROOT/t12.jsonl" "$id" skill ""
WB_FAIL="no task file for sess" run_hook "$(stop_payload "$ROOT/t12.jsonl")"
check "failing wb.sh: message says so, hook exits 0" 1 "failed"
[[ "$OUT" == *"no task file for sess"* && "$OUT" != *"second line"* ]] && ok "message carries only the first stderr line" || bad "stderr in message: $OUT"
[[ "$OUT" == *"wb reviewed"* ]] && ok "message tells Jet to run wb reviewed" || bad "no wb reviewed advice: $OUT"
[ ! -e "$RUNS/$id/.wb-stamped" ] && ok "no marker after a failed stamp" || bad "marker written after failure"

# --- bad payloads -----------------------------------------------------------
run_hook ""
check "empty payload: exit 0, no output" 0
run_hook "{not json"
check "malformed payload: exit 0, no output" 0
run_hook "$(jq -n '{hook_event_name:"Stop"}')"
check "payload without transcript_path or cwd: exit 0, no output" 0
run_hook "$(stop_payload "$ROOT/missing.jsonl")"
check "transcript file missing: exit 0, no output" 0

[ "$fail" = 0 ] && echo "ALL PASS" || {
  echo "FAILURES"
  exit 1
}
