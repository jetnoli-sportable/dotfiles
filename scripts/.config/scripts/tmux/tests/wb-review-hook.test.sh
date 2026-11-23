#!/usr/bin/env bash
# shellcheck disable=SC2329,SC2016,SC2015 # test scaffolding: trap, literal fixtures, ok/bad helpers
# Tests for U6 of the wb diff viewer plan: wb-review-hook.sh (the Stop and
# SessionStart hooks plus the `deliver` verb the review server runs) and its
# hooks-only plugin. Real tmux on ONE fixed private -L socket with -f /dev/null
# behind a logging PATH shim (never the default socket). A "Claude" pane is a
# pane whose foreground command is named claude (a symlink to sleep) and whose
# screen shows an input line, text on it, or a dialog. The queue items are
# written here by hand, the way the review server writes them (queue contract).
# Run: bash scripts/.config/scripts/tmux/tests/wb-review-hook.test.sh
# HOOK overrides the script under test.
set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPO="$(cd "$SELF_DIR/../../../.." && pwd)"
HOOK="${HOOK:-$SELF_DIR/wb-review-hook.sh}"
FIX="$(mktemp -d -t wb-review-hook.XXXXXX)"
SOCK="wb-review-hook-test-sock"
REAL_TMUX="$(command -v tmux)"
REAL_JQ="$(command -v jq)"

# Isolation FIRST.
export HOME="$FIX/home" XDG_STATE_HOME="$FIX/state" LANG=C.UTF-8 LC_ALL=C.UTF-8
export WB_REVIEW_SETTLE_MS=200 WB_REVIEW_SETTLE_MAX_MS=800
mkdir -p "$HOME" "$XDG_STATE_HOME/wb" "$FIX/bin"
unset TMUX TMUX_PANE CLAUDE_CODE_ENTRYPOINT CLAUDE_CODE_SESSION_ATTENDED
STATE="$XDG_STATE_HOME/wb"
RQ="$STATE/review"

CALLS="$FIX/calls.log"
: >"$CALLS"
cat >"$FIX/bin/tmux" <<EOF
#!/usr/bin/env bash
echo "\$*" >> "$CALLS"
# Fault injection: send-keys fails while failsend exists; once mode2 exists the
# second pane_in_mode read reports copy mode.
[ "\$1" = send-keys ] && [ -e "$FIX/failsend" ] && exit 1
# holdonsettle: line 1 a path, the rest its content, written at settle's first
# @claude_working read (a turn ending with a question while deliver settles).
if [ "\$1" = show ] && [[ "\$*" == *@claude_working* ]] && [ -e "$FIX/holdonsettle" ]; then
  tail -n +2 "$FIX/holdonsettle" >"\$(head -n 1 "$FIX/holdonsettle")"
  rm -f "$FIX/holdonsettle"
fi
if [[ "\$*" == *pane_in_mode* ]] && [ -e "$FIX/mode2" ]; then
  echo x >> "$FIX/mode2"
  [ "\$(wc -l < "$FIX/mode2")" -ge 2 ] && { echo 1; exit 0; }
fi
exec "$REAL_TMUX" -u -L "$SOCK" -f /dev/null "\$@"
EOF
cat >"$FIX/bin/jq" <<EOF
#!/usr/bin/env bash
echo "jq \$*" >> "$CALLS"
exec "$REAL_JQ" "\$@"
EOF
ln -s "$(command -v sleep)" "$FIX/bin/claude"
chmod +x "$FIX/bin/tmux" "$FIX/bin/jq"
PATH="$FIX/bin:$PATH"
export PATH

cleanup() {
  "$REAL_TMUX" -L "$SOCK" kill-server 2>/dev/null || true
  rm -rf "${FIX:?}"
}
trap cleanup EXIT

fail=0
ok() { echo "ok   - $1"; }
bad() {
  echo "FAIL - $1${2:+ ($2)}"
  fail=1
}
assert_eq() { [ "$2" = "$3" ] && ok "$1" || bad "$1" "expected [$2], got [$3]"; }
assert_has() { [[ "$3" == *"$2"* ]] && ok "$1" || bad "$1" "expected [$2] in [$3]"; }
t() { "$REAL_TMUX" -u -L "$SOCK" -f /dev/null "$@"; }
sends() { /usr/bin/grep -c '^send-keys' "$CALLS" || true; }

# newpane <session> <stem|-> <screen: prompt|text|dialog|shell> — a one-pane
# session; sets PANE. A stem sets the session's @task the way wb does.
newpane() {
  local cmd
  case "$3" in
    prompt) cmd="printf '\\xe2\\x9d\\xaf\\xc2\\xa0\\n'; exec claude 600" ;;
    text) cmd="printf '\\xe2\\x9d\\xaf\\xc2\\xa0half typed\\n'; exec claude 600" ;;
    dialog) cmd="printf 'Do you want to proceed?\\n 1. Yes\\n 2. No\\n'; exec claude 600" ;;
    shell) cmd="exec sleep 600" ;;
  esac
  t new-session -d -s "$1" "$cmd"
  [ "$2" = - ] || t set-option -t "=$1:" @task "$FIX/tasks/$2.md"
  PANE="$(t list-panes -t "=$1:" -F '#{pane_id}' | head -n 1)"
  for _ in $(seq 1 50); do
    [ -n "$(t capture-pane -p -t "$PANE" | tr -d '[:space:]')" ] && break
    sleep 0.1
  done
}
endsessions() {
  local s
  for s in $(t list-sessions -F '#{session_name}' 2>/dev/null); do t kill-session -t "=$s"; done
}

# item <stem> <id> <record-path> [created] — a pending queue item as the server writes it.
item() {
  mkdir -p "$RQ/$1/queue/pending"
  printf '{"id":"%s","stem":"%s","record":"%s","created":"%s","comments":3}\n' "$2" "$1" "$3" "${4:-2026-11-22T20:15:00Z}" \
    >"$RQ/$1/queue/pending/$2.json"
}
reset() {
  rm -rf "${RQ:?}" "$STATE/continue" "$STATE/disable-review"
  : >"$CALLS"
}
pending_n() { find "$RQ/$1/queue/pending" -name '*.json' 2>/dev/null | wc -l; }
delivered_route() { jq -r .route "$RQ/$1/queue/delivered/$2.json" 2>/dev/null; }
status_of() { cat "$RQ/$1/queue/status" 2>/dev/null; }
# hook <verb> <pane> — run a hook verb the way Claude does, stdout captured.
hook() { echo '{"hook_event_name":"x","stop_hook_active":false}' | TMUX_PANE="$2" bash "$HOOK" "$1"; }
deliver() { bash "$HOOK" deliver "$1"; }
# stopmsg <pane> <reply> — a Stop whose last assistant message is <reply>.
stopmsg() {
  "$REAL_JQ" -n --arg m "$2" '{hook_event_name:"Stop",stop_hook_active:false,last_assistant_message:$m}' | TMUX_PANE="$1" bash "$HOOK" hook-stop
}
# promptin <pane> <prompt> — a UserPromptSubmit with <prompt>.
promptin() {
  local json
  json="$("$REAL_JQ" -n --arg p "$2" '{hook_event_name:"UserPromptSubmit",prompt:$p}')"
  TMUX_PANE="$1" bash "$HOOK" hook-prompt <<<"$json"
}
held_f() { echo "$RQ/$1/queue/held"; }

REC_A="$FIX/tasks/dossiers/tk-a/reviews/2026-11-22-201500-review.md"
REC_B="$FIX/tasks/dossiers/tk-a/reviews/2026-11-22-203000-review.md"
PTR_A="Jet sent a code review: read $REC_A and address each comment."

newpane probe - prompt
assert_eq "test pane's foreground command is claude" claude "$(t display-message -p -t "$PANE" '#{pane_current_command}')"
endsessions

# --- AE1: busy -> nothing typed, waiting status; the Stop hook delivers --------------------
reset
newpane s1 tk-a prompt
P1="$PANE"
t set -p -t "$P1" @claude_working 1
item tk-a r-1 "$REC_A"
deliver tk-a
assert_eq "AE1: nothing typed while a turn runs" 0 "$(sends)"
assert_eq "AE1: item stays pending" 1 "$(pending_n tk-a)"
assert_eq "AE1: status says why" "waiting for the turn to end" "$(status_of tk-a)"
out="$(hook hook-stop "$P1")"
assert_eq "AE1: stop hook blocks" block "$(jq -r .decision <<<"$out")"
assert_eq "AE1: stop hook reason is the pointer" "$PTR_A" "$(jq -r .reason <<<"$out")"
assert_eq "AE1: stop hook prints only the block JSON" '["decision","reason"]' "$(jq -c 'keys' <<<"$out")"
assert_eq "AE1: delivered via turn end" turn-end "$(delivered_route tk-a r-1)"
assert_eq "AE1: delivered item keeps its record" "$REC_A" "$(jq -r .record "$RQ/tk-a/queue/delivered/r-1.json")"
[ -n "$(jq -r .delivered "$RQ/tk-a/queue/delivered/r-1.json")" ] && ok "AE1: delivered item has a time" || bad "AE1: delivered item has a time"
assert_eq "AE1: pending and claimed are empty" "0 0" "$(pending_n tk-a) $(find "$RQ/tk-a/queue/claimed" -name '*.json' | wc -l)"
[ ! -e "$RQ/tk-a/queue/status" ] && ok "AE1: status removed on delivery" || bad "AE1: status removed on delivery"
[ -e "$RQ/tk-a/queue/inflight" ] && ok "block writes queue/inflight" || bad "block writes queue/inflight"
assert_eq "block: inflight records pane and epoch" "$P1 yes" "$(read -r a b <"$RQ/tk-a/queue/inflight"; [[ "$b" =~ ^[0-9]+$ ]] && echo "$a yes")"
assert_eq "block: busy marker is an epoch" yes "$([[ "$(t show -pv -t "$P1" @claude_agent_wbreview 2>/dev/null)" =~ ^[0-9]+$ ]] && echo yes)"
assert_eq "block: @claude_working is set" 1 "$(t show -pv -t "$P1" @claude_working 2>/dev/null)"

# --- inflight: deliver is busy until the next hook-stop clears it ---------------------------
item tk-a r-2 "$REC_B"
: >"$CALLS"
deliver tk-a
assert_eq "inflight: deliver types nothing" 0 "$(sends)"
assert_eq "inflight: status says a hand-over is being worked on" "a review hand-over is still being worked on" "$(status_of tk-a)"
mv "$RQ/tk-a/queue/pending/r-2.json" "$FIX/r-2.json"
hook hook-stop "$P1" >/dev/null
[ ! -e "$RQ/tk-a/queue/inflight" ] && ok "inflight: the next hook-stop removes it" || bad "inflight: the next hook-stop removes it"
assert_eq "next hook-stop clears the busy marker" "" "$(t show -pv -t "$P1" @claude_agent_wbreview 2>/dev/null)"
assert_eq "next hook-stop lets @claude_working go (no turn, no agent)" "" "$(t show -pv -t "$P1" @claude_working 2>/dev/null)"
assert_eq "AE1: second hook-stop after delivery prints nothing" "" "$(hook hook-stop "$P1")"
mv "$FIX/r-2.json" "$RQ/tk-a/queue/pending/r-2.json"
: >"$CALLS"
deliver tk-a
assert_eq "inflight cleared: deliver types the pointer" 2 "$(sends)"
endsessions

# --- the marker keeps the notify hook's derivation busy -------------------------------------------
reset
newpane s1 tk-a prompt
P1="$PANE"
item tk-a r-1 "$REC_A"
t set -p -t "$P1" @claude_turn 1
hook hook-stop "$P1" >/dev/null
t set -pu -t "$P1" @claude_turn 2>/dev/null
NOTIFY="$SELF_DIR/claude-notify-hook.sh"
TMUX_PANE="$P1" bash "$NOTIFY" "done" </dev/null
assert_eq "notify done after the block: still working" 1 "$(t show -pv -t "$P1" @claude_working 2>/dev/null)"
assert_eq "notify done after the block: not flagged done" "" "$(t show -pv -t "$P1" @claude_blocked 2>/dev/null)"
hook hook-stop "$P1" >/dev/null
assert_eq "clearing after notify ran first: working released" "" "$(t show -pv -t "$P1" @claude_working 2>/dev/null)"
endsessions

# --- interrupt: a block with no later Stop must not wedge deliver -------------------------------------
reset
newpane s1 tk-a prompt
P1="$PANE"
item tk-a r-1 "$REC_A"
hook hook-stop "$P1" >/dev/null
# Esc: no Stop. The pane is idle again, the marker and inflight remain.
t set -pu -t "$P1" @claude_working 2>/dev/null
item tk-a r-2 "$REC_B"
: >"$CALLS"
deliver tk-a
assert_eq "fresh inflight, pane still marked busy: deliver types nothing" 0 "$(sends)"
assert_eq "fresh inflight, pane still marked busy: existing status" "a review hand-over is still being worked on" "$(status_of tk-a)"
t set -pu -t "$P1" @claude_agent_wbreview 2>/dev/null
: >"$CALLS"
deliver tk-a
assert_eq "inflight whose pane lost the marker: pointer typed" 2 "$(sends)"
assert_eq "inflight whose pane lost the marker: delivered via prompt" prompt "$(delivered_route tk-a r-2)"
[ ! -e "$RQ/tk-a/queue/inflight" ] && ok "stale inflight removed by deliver" || bad "stale inflight removed by deliver"
endsessions

# aged out: marker still on the pane, but older than the limit
reset
newpane s1 tk-a prompt
P1="$PANE"
item tk-a r-1 "$REC_A"
hook hook-stop "$P1" >/dev/null
t set -pu -t "$P1" @claude_working 2>/dev/null
item tk-a r-2 "$REC_B"
: >"$CALLS"
WB_REVIEW_INFLIGHT_MAX_S=0 deliver tk-a
assert_eq "aged-out inflight: pointer typed" 2 "$(sends)"
assert_eq "aged-out inflight: stale busy marker cleared" "" "$(t show -pv -t "$P1" @claude_agent_wbreview 2>/dev/null)"
endsessions

# --- StopFailure: drop the marker, print nothing ---------------------------------------------------------
reset
newpane s1 tk-a prompt
P1="$PANE"
item tk-a r-1 "$REC_A"
hook hook-stop "$P1" >/dev/null
item tk-a r-2 "$REC_B"
out="$(hook hook-stop-failure "$P1")"
assert_eq "StopFailure: prints nothing" "" "$out"
[ ! -e "$RQ/tk-a/queue/inflight" ] && ok "StopFailure: inflight removed" || bad "StopFailure: inflight removed"
assert_eq "StopFailure: busy marker cleared" "" "$(t show -pv -t "$P1" @claude_agent_wbreview 2>/dev/null)"
assert_eq "StopFailure: does not claim a pending item" 1 "$(pending_n tk-a)"
endsessions

# --- AE2: idle -> pointer typed, Enter separate ----------------------------------------------
reset
newpane s1 tk-a prompt
P1="$PANE"
item tk-a r-1 "$REC_A"
deliver tk-a
assert_has "AE2: pointer typed with send-keys -l" "send-keys -t s1:0.0 -l -- $PTR_A" "$(/usr/bin/grep '^send-keys' "$CALLS" | sed -n 1p)"
assert_eq "AE2: Enter is its own send-keys call" "send-keys -t s1:0.0 Enter" "$(/usr/bin/grep '^send-keys' "$CALLS" | sed -n 2p)"
assert_eq "AE2: exactly two send-keys calls" 2 "$(sends)"
assert_eq "AE2: delivered via prompt" prompt "$(delivered_route tk-a r-1)"
assert_eq "AE2: nothing left pending" 0 "$(pending_n tk-a)"
assert_eq "AE2: a later hook-stop has nothing to block" "" "$(hook hook-stop "$P1")"
endsessions

# --- @claude_blocked is not a guard -----------------------------------------------------------
for v in "done" "needs-input"; do
  reset
  newpane s1 tk-a prompt
  t set -p -t "$PANE" @claude_blocked "$v"
  item tk-a r-1 "$REC_A"
  deliver tk-a
  assert_eq "@claude_blocked=$v with an empty input line: typed" prompt "$(delivered_route tk-a r-1)"
  endsessions
done

# --- permission dialog on screen --------------------------------------------------------------
reset
newpane s1 tk-a dialog
item tk-a r-1 "$REC_A"
deliver tk-a
assert_eq "dialog: nothing typed" 0 "$(sends)"
assert_eq "dialog: item stays pending" 1 "$(pending_n tk-a)"
assert_eq "dialog: status says why" "a permission question is on screen" "$(status_of tk-a)"
endsessions

# --- text on the input line -------------------------------------------------------------------
reset
newpane s1 tk-a text
item tk-a r-1 "$REC_A"
deliver tk-a
assert_eq "text on input: nothing typed" 0 "$(sends)"
assert_eq "text on input: item stays pending" 1 "$(pending_n tk-a)"
assert_eq "text on input: status says why" "text on the input line" "$(status_of tk-a)"
endsessions

# --- copy mode ---------------------------------------------------------------------------------
reset
newpane s1 tk-a prompt
t copy-mode -t "$PANE"
item tk-a r-1 "$REC_A"
deliver tk-a
assert_eq "copy mode: nothing typed" 0 "$(sends)"
assert_eq "copy mode: status says why" "the pane is in copy mode" "$(status_of tk-a)"
endsessions

# copy mode entered during the settle wait: only the re-read sees it
reset
newpane s1 tk-a prompt
: >"$FIX/mode2"
item tk-a r-1 "$REC_A"
deliver tk-a
rm -f "$FIX/mode2"
assert_eq "copy mode after settle: nothing typed" 0 "$(sends)"
assert_eq "copy mode after settle: item stays pending" 1 "$(pending_n tk-a)"
assert_eq "copy mode after settle: status says why" "the pane is in copy mode" "$(status_of tk-a)"
endsessions

# --- send-keys failure: the claim is undone ---------------------------------------------------
reset
newpane s1 tk-a prompt
touch "$FIX/failsend"
item tk-a r-1 "$REC_A"
deliver tk-a
rm -f "$FIX/failsend"
assert_eq "send-keys fails: item back in pending" 1 "$(pending_n tk-a)"
assert_eq "send-keys fails: claimed and delivered hold nothing" 0 \
  "$(find "$RQ/tk-a/queue/claimed" "$RQ/tk-a/queue/delivered" -name '*.json' | wc -l)"
assert_eq "send-keys fails: status says so" "typing into the pane failed" "$(status_of tk-a)"
endsessions

# --- AE3: no Claude running -> pending; the SessionStart hook delivers -------------------------
reset
newpane s1 tk-a shell
P1="$PANE"
item tk-a r-1 "$REC_A"
deliver tk-a
assert_eq "AE3: nothing typed" 0 "$(sends)"
assert_eq "AE3: item stays pending" 1 "$(pending_n tk-a)"
assert_eq "AE3: status says no Claude" "no Claude running for this task" "$(status_of tk-a)"
out="$(hook hook-session-start "$P1")"
assert_eq "AE3: session start adds context" SessionStart "$(jq -r .hookSpecificOutput.hookEventName <<<"$out")"
assert_eq "AE3: context is the pointer" "$PTR_A" "$(jq -r .hookSpecificOutput.additionalContext <<<"$out")"
assert_eq "AE3: delivered via session start" session-start "$(delivered_route tk-a r-1)"
assert_eq "AE3: nothing left pending" 0 "$(pending_n tk-a)"
endsessions
reset
item tk-a r-1 "$REC_A"
deliver tk-a
assert_eq "no tmux session at all: status says no Claude" "no Claude running for this task" "$(status_of tk-a)"

# --- armed wb continue request: hook-stop holds back, the restart's session start claims -------
reset
newpane s1 tk-a prompt
P1="$PANE"
mkdir -p "$STATE/continue/tk-a"
printf 'state=armed\npane=%s\ntask_file=%s\n' "$P1" "$FIX/tasks/tk-a.md" >"$STATE/continue/tk-a/request"
item tk-a r-1 "$REC_A"
assert_eq "armed continue: hook-stop prints nothing" "" "$(hook hook-stop "$P1")"
assert_eq "armed continue: item stays pending" 1 "$(pending_n tk-a)"
out="$(hook hook-session-start "$P1")"
assert_eq "armed continue: the restart's session start claims it" "$PTR_A" "$(jq -r .hookSpecificOutput.additionalContext <<<"$out")"
endsessions

# --- wb continue already claimed or restarting the pane: still held back ------------------------
for st in claimed restarting; do
  reset
  newpane s1 tk-a prompt
  P1="$PANE"
  mkdir -p "$STATE/continue/tk-a"
  printf 'state=%s\npane=%s\ntask_file=%s\n' "$st" "$P1" "$FIX/tasks/tk-a.md" >"$STATE/continue/tk-a/request"
  item tk-a r-1 "$REC_A"
  assert_eq "$st continue: hook-stop prints nothing" "" "$(hook hook-stop "$P1")"
  assert_eq "$st continue: item stays pending" 1 "$(pending_n tk-a)"
  out="$(hook hook-session-start "$P1")"
  assert_eq "$st continue: the restart's session start claims it" "$PTR_A" "$(jq -r .hookSpecificOutput.additionalContext <<<"$out")"
  endsessions
done

# --- two pending reviews go together -------------------------------------------------------------
reset
newpane s1 tk-a prompt
P1="$PANE"
item tk-a r-1 "$REC_A"
item tk-a r-2 "$REC_B"
out="$(hook hook-stop "$P1")"
assert_eq "two reviews: one pointer naming both" \
  "Jet sent 2 code reviews: read $REC_A and $REC_B, and address each comment." "$(jq -r .reason <<<"$out")"
assert_eq "two reviews: both delivered via turn end" "turn-end turn-end" "$(delivered_route tk-a r-1) $(delivered_route tk-a r-2)"
endsessions

# --- R18: only the task's own session ---------------------------------------------------------------
reset
newpane other tk-b prompt
PB="$PANE"
item tk-a r-1 "$REC_A"
assert_eq "R18: hook-stop in another task's pane prints nothing" "" "$(hook hook-stop "$PB")"
assert_eq "R18: hook-session-start in another task's pane prints nothing" "" "$(hook hook-session-start "$PB")"
deliver tk-a
assert_eq "R18: deliver types into no other task's pane" 0 "$(sends)"
assert_eq "R18: the review is still pending" 1 "$(pending_n tk-a)"
newpane noname - prompt
assert_eq "R18: a pane in a session with no @task prints nothing" "" "$(hook hook-stop "$PANE")"
endsessions

# --- exits and the prefilter ------------------------------------------------------------------------
reset
newpane s1 tk-a prompt
P1="$PANE"
: >"$CALLS"
for v in hook-stop hook-session-start; do
  hook "$v" "$P1" >"$FIX/o" 2>&1
  rc=$?
  assert_eq "no queue directory: $v exits 0 and prints nothing" "0:" "$rc:$(cat "$FIX/o")"
done
deliver tk-a
rc=$?
assert_eq "no queue directory: deliver exits 0" 0 "$rc"
assert_eq "no queue directory: no tmux or jq call" "" "$(cat "$CALLS")"
bash "$HOOK" bogus
assert_eq "unknown verb exits 0" 0 "$?"
bash "$HOOK"
assert_eq "no verb exits 0" 0 "$?"

item tk-a r-1 "$REC_A"
: >"$CALLS"
touch "$STATE/disable-review"
assert_eq "kill switch: hook-stop prints nothing" "" "$(hook hook-stop "$P1")"
assert_eq "kill switch: no tmux call" "" "$(cat "$CALLS")"
deliver tk-a
assert_eq "kill switch: deliver types nothing" 0 "$(sends)"
rm -f "$STATE/disable-review"
assert_eq "SDK entrypoint: prints nothing" "" "$(CLAUDE_CODE_ENTRYPOINT=sdk-cli hook hook-stop "$P1")"
assert_eq "unattended: prints nothing" "" "$(CLAUDE_CODE_SESSION_ATTENDED=0 hook hook-stop "$P1")"
assert_eq "no TMUX_PANE: prints nothing" "" "$(echo '{}' | bash "$HOOK" hook-stop)"
assert_eq "all of those left the item pending" 1 "$(pending_n tk-a)"

# --- deliver validates the stem ----------------------------------------------------------------------
mkdir -p "$STATE/evil/queue/pending"
printf '{"id":"x","record":"/x/y.md"}\n' >"$STATE/evil/queue/pending/x.json"
: >"$CALLS"
deliver ../evil
deliver 'a/b'
deliver ''
deliver '..'
assert_eq "bad stems: nothing claimed, no tmux call" "1:" "$(find "$STATE/evil/queue/pending" -name '*.json' | wc -l):$(cat "$CALLS")"

# --- AE11: a turn that ends with "Needs you" holds the review ------------------------------------
reset
newpane s1 tk-a prompt
P1="$PANE"
item tk-a r-1 "$REC_A"
t set -p -t "$P1" @claude_working 1
out="$(stopmsg "$P1" $'Built the routes.\n\n**Needs you:** pick A or B')"
assert_eq "AE11: a closing Needs you: no block JSON" "" "$out"
assert_eq "AE11: the item stays pending" 1 "$(pending_n tk-a)"
assert_eq "AE11: held line 2 is the question" "pick A or B" "$(sed -n 2p "$(held_f tk-a)")"
assert_eq "AE11: held line 1 is an epoch" yes "$([[ "$(sed -n 1p "$(held_f tk-a)")" =~ ^[0-9]{10}$ ]] && echo yes)"
assert_eq "AE11: held status" "held: the session asked you something" "$(status_of tk-a)"
[ ! -e "$RQ/tk-a/queue/inflight" ] && ok "AE11: nothing in flight" || bad "AE11: nothing in flight"
assert_eq "AE11: nothing typed" 0 "$(sends)"
deliver tk-a
rc=$?
assert_eq "AE11: deliver with held and no newer item: exit 0, nothing typed, item pending" "0 0 1" "$rc $(sends) $(pending_n tk-a)"
assert_eq "AE11: deliver keeps the held status" "held: the session asked you something" "$(status_of tk-a)"
assert_eq "held: a Stop with no answer yet keeps holding" "" "$(stopmsg "$P1" 'Still going.')"
assert_eq "held: ... and the item stays pending" 1 "$(pending_n tk-a)"
endsessions

# a newer item is Jet's answer: deliver claims everything and drops the hold
reset
newpane s1 tk-a prompt
item tk-a r-1 "$REC_A" 2026-11-22T20:15:00Z
item tk-a r-2 "$REC_B" 2026-11-22T20:30:00Z
printf '%s\n%s\n' "$(date -u -d 2026-11-22T20:20:00Z +%s)" "pick A or B" >"$(held_f tk-a)"
: >"$RQ/tk-a/queue/held.answered"
deliver tk-a
assert_eq "AE11: deliver claims everything when an item is newer than the hold" 0 "$(pending_n tk-a)"
assert_eq "AE11: ... typed at the prompt" prompt "$(delivered_route tk-a r-2)"
assert_eq "AE11: ... the older item went with it" prompt "$(delivered_route tk-a r-1)"
[ ! -e "$(held_f tk-a)" ] && [ ! -e "$RQ/tk-a/queue/held.answered" ] && ok "AE11: ... held and held.answered removed" || bad "AE11: ... held and held.answered removed"
endsessions

# the turn-end route does the same for a newer item
reset
newpane s1 tk-a prompt
P1="$PANE"
item tk-a r-1 "$REC_B" 2026-11-22T20:30:00Z
printf '%s\n%s\n' "$(date -u -d 2026-11-22T20:20:00Z +%s)" "pick A or B" >"$(held_f tk-a)"
out="$(stopmsg "$P1" 'Done.')"
assert_eq "held: a newer item is claimed at the next turn end" block "$(jq -r .decision <<<"$out")"
[ ! -e "$(held_f tk-a)" ] && ok "held: ... and the hold is gone" || bad "held: ... and the hold is gone"
endsessions

# "needs you" mid-text is not a closing line
reset
newpane s1 tk-a prompt
P1="$PANE"
item tk-a r-1 "$REC_A"
out="$(stopmsg "$P1" $'The reply says it needs you to know X.\n\nAll done.')"
assert_eq "mid-text needs you: claims as usual" block "$(jq -r .decision <<<"$out")"
[ ! -e "$(held_f tk-a)" ] && ok "mid-text needs you: no hold" || bad "mid-text needs you: no hold"
endsessions

# the closing-line rule, as wb-store's needsYouRe and replyEnd pin it
holds() { # <reply> — held or claimed
  reset
  newpane s1 tk-a prompt
  item tk-a r-1 "$REC_A"
  stopmsg "$PANE" "$1" >/dev/null
  [ -e "$(held_f tk-a)" ] && echo held || echo claimed
  endsessions
}
assert_eq "rule: a bulleted Needs you line holds" held "$(holds $'Built.\n- **Needs you:** merge it')"
assert_eq "rule: a numbered list under a bare Needs you holds" held "$(holds $'Built.\n**Needs you:**\n1. merge\n2. test')"
assert_eq "rule: Needs you inside the last 12 non-blank lines holds" held "$(holds $'**Needs you:** x\n\n1\n2\n3\n4\n5\n6\n7\n8\n9\n10\n11')"
assert_eq "rule: Needs you above the last 12 non-blank lines claims" claimed "$(holds $'**Needs you:** x\n1\n2\n3\n4\n5\n6\n7\n8\n9\n10\n11\n12')"
assert_eq "rule: a lowercase 'needs you' marker claims" claimed "$(holds $'Built.\n**needs you:** x')"
assert_eq "rule: an indented marker claims" claimed "$(holds $'Built.\n  **Needs you:** x')"
assert_eq "rule: a Nothing-needed last line claims" claimed "$(holds $'**Needs you:** x\n**Nothing needed.**')"
assert_eq "rule: a missing last_assistant_message claims" claimed "$(holds '')"
reset
newpane s1 tk-a prompt
item tk-a r-1 "$REC_A"
stopmsg "$PANE" $'Built.\n**Needs you:**\n  merge PR 4 or tell me to hold' >/dev/null
assert_eq "rule: a bare marker takes the next line as the question" "merge PR 4 or tell me to hold" "$(sed -n 2p "$(held_f tk-a)")"
endsessions

# --- hook-prompt: Jet's answer releases the hold at the next quiet Stop -----------------------------
reset
newpane s1 tk-a prompt
P1="$PANE"
item tk-a r-1 "$REC_A"
stopmsg "$P1" $'Q.\n**Needs you:** pick' >/dev/null
out="$(promptin "$P1" 'pick A')"
assert_eq "hook-prompt prints nothing" "" "$out"
[ -e "$RQ/tk-a/queue/held.answered" ] && ok "hook-prompt: a typed prompt writes held.answered" || bad "hook-prompt: a typed prompt writes held.answered"
out="$(stopmsg "$P1" 'Went with A.')"
assert_eq "answered: the next Stop without a Needs you claims" block "$(jq -r .decision <<<"$out")"
[ ! -e "$(held_f tk-a)" ] && [ ! -e "$RQ/tk-a/queue/held.answered" ] && ok "answered: hold and note removed" || bad "answered: hold and note removed"
endsessions

reset
newpane s1 tk-a prompt
P1="$PANE"
item tk-a r-1 "$REC_A"
stopmsg "$P1" $'Q.\n**Needs you:** pick' >/dev/null
promptin "$P1" 'pick A' >/dev/null
out="$(stopmsg "$P1" $'Still unsure.\n**Needs you:** really pick')"
assert_eq "answered, but the turn ends with a new question: still held" "" "$out"
assert_eq "answered, new question: held.answered is reset" "gone" "$([ -e "$RQ/tk-a/queue/held.answered" ] && echo there || echo gone)"
assert_eq "answered, new question: the new text is held" "really pick" "$(sed -n 2p "$(held_f tk-a)")"
endsessions

reset
newpane s1 tk-a shell
P1="$PANE"
item tk-a r-1 "$REC_A"
mkdir -p "$RQ/tk-a/queue"
printf '%s\n%s\n' "$(date +%s)" "pick" >"$(held_f tk-a)"
out="$(hook hook-session-start "$P1")"
assert_eq "held: session start claims" "$PTR_A" "$(jq -r .hookSpecificOutput.additionalContext <<<"$out")"
[ ! -e "$(held_f tk-a)" ] && ok "held: session start removes the hold" || bad "held: session start removes the hold"
endsessions

# prompts nobody typed do not answer
for ap in $'Another Claude session sent a message:\n<cross-session-message>hi' '<task-notification>done</task-notification>' $'  \n<task-notification>x' '(background task finished)' '[SYSTEM] note' 'Your claude.ai usage limit has reset. Continue.'; do
  reset
  newpane s1 tk-a prompt
  P1="$PANE"
  item tk-a r-1 "$REC_A"
  stopmsg "$P1" $'Q.\n**Needs you:** pick' >/dev/null
  promptin "$P1" "$ap" >/dev/null
  [ ! -e "$RQ/tk-a/queue/held.answered" ] && ok "auto prompt writes no held.answered: ${ap//$'\n'/ }" || bad "auto prompt writes no held.answered: ${ap//$'\n'/ }"
  assert_eq "auto prompt: the following quiet Stop leaves the review held" "1:" "$(pending_n tk-a):$(stopmsg "$P1" 'Progress report.')"
  endsessions
done

# the pointer deliver types is not Jet's answer
reset
newpane s1 tk-a prompt
P1="$PANE"
item tk-a r-1 "$REC_A"
stopmsg "$P1" $'Q.\n**Needs you:** pick' >/dev/null
promptin "$P1" "$PTR_A" >/dev/null
promptin "$P1" "Jet sent 2 code reviews: read a, b, and address each comment." >/dev/null
[ ! -e "$RQ/tk-a/queue/held.answered" ] && ok "a typed review pointer writes no held.answered" || bad "a typed review pointer writes no held.answered"
endsessions

# a turn that ends with a question while deliver settles: nothing typed
reset
newpane s1 tk-a prompt
item tk-a r-1 "$REC_A"
printf '%s\n%s\n%s\n' "$(held_f tk-a)" "$(date +%s)" "pick A or B" >"$FIX/holdonsettle"
deliver tk-a
assert_eq "held during settle: nothing typed, item pending" "0 1" "$(sends) $(pending_n tk-a)"
assert_eq "held during settle: held status" "held: the session asked you something" "$(status_of tk-a)"
rm -f "$FIX/holdonsettle"
endsessions

# no held file anywhere: exits before any fork
reset
newpane s1 tk-a prompt
P1="$PANE"
item tk-a r-1 "$REC_A"
: >"$CALLS"
promptin "$P1" 'hello' >/dev/null
rc=$?
assert_eq "no held file: hook-prompt exits 0 with no tmux or jq call" "0:" "$rc:$(cat "$CALLS")"
endsessions

# --- deliver's exit code ----------------------------------------------------------------------------
reset
newpane s1 tk-a shell
item tk-a r-1 "$REC_A"
deliver tk-a
assert_eq "deliver with no Claude pane: exit 3" 3 "$?"
endsessions
reset
newpane s1 tk-a prompt
t set -p -t "$PANE" @claude_working 1
item tk-a r-1 "$REC_A"
deliver tk-a
assert_eq "deliver with a busy pane: exit 0" 0 "$?"
endsessions
reset
newpane s1 tk-a prompt
item tk-a r-1 "$REC_A"
deliver tk-a
assert_eq "deliver that types: exit 0" 0 "$?"
endsessions

# --- the done light after a review-block turn ----------------------------------------------------------
for age in 60 5; do
  reset
  newpane s1 tk-a prompt
  P1="$PANE"
  item tk-a r-1 "$REC_A"
  t set -p -t "$P1" @claude_turn 1
  t set -p -t "$P1" @claude_started "$(($(date +%s) - age))"
  hook hook-stop "$P1" >/dev/null
  t set -pu -t "$P1" @claude_turn
  TMUX_PANE="$P1" bash "$NOTIFY" "done" </dev/null
  assert_eq "block turn ${age}s: the notify hook ran first and saw the busy marker" "" "$(t show -pv -t "$P1" @claude_blocked 2>/dev/null)"
  hook hook-stop "$P1" >/dev/null
  if [ "$age" = 60 ]; then
    assert_eq "block turn ${age}s: the review hook's Stop lights done" "done" "$(t show -pv -t "$P1" @claude_blocked 2>/dev/null)"
  else
    assert_eq "block turn ${age}s: under 30 s stays unset" "" "$(t show -pv -t "$P1" @claude_blocked 2>/dev/null)"
  fi
  endsessions
done
reset
newpane s1 tk-a prompt
P1="$PANE"
item tk-a r-1 "$REC_A"
t set -p -t "$P1" @claude_started "$(($(date +%s) - 90))"
hook hook-stop "$P1" >/dev/null
t set -p -t "$P1" @claude_turn 1
hook hook-stop "$P1" >/dev/null
assert_eq "a turn still running at the clearing Stop: not flagged done" "" "$(t show -pv -t "$P1" @claude_blocked 2>/dev/null)"
endsessions

# --- the plugin ---------------------------------------------------------------------------------------
PLUGIN="$REPO/claude/.claude/skills/wb-review-hook"
HOOKS="$PLUGIN/hooks/hooks.json"
MANIFEST="$PLUGIN/.claude-plugin/plugin.json"
assert_eq "plugin name" wb-review-hook "$(jq -r .name "$MANIFEST" 2>/dev/null)"
assert_eq "manifest keys are name/description/author only" '["author","description","name"]' "$(jq -c keys "$MANIFEST" 2>/dev/null)"
[ ! -e "$PLUGIN/SKILL.md" ] && ok "plugin dir carries no SKILL.md (hooks only)" || bad "plugin dir carries no SKILL.md (hooks only)"
assert_eq "plugin: Stop, StopFailure, SessionStart and UserPromptSubmit" '["SessionStart","Stop","StopFailure","UserPromptSubmit"]' "$(jq -c '.hooks | keys' "$HOOKS" 2>/dev/null)"
for pair in Stop:hook-stop StopFailure:hook-stop-failure SessionStart:hook-session-start UserPromptSubmit:hook-prompt; do
  ev="${pair%%:*}" want="${pair#*:}"
  RH='[.hooks.'"$ev"'[].hooks[] | select(.command | test("wb-review-hook.sh"))]'
  assert_eq "$ev: exactly one wb-review-hook.sh hook" 1 "$(jq "$RH | length" "$HOOKS" 2>/dev/null)"
  assert_eq "$ev: timeout 5, synchronous" "5 false" "$(jq -r "${RH}[0] | \"\(.timeout) \(.async == true)\"" "$HOOKS" 2>/dev/null)"
  cmd="$(jq -r "${RH}[0].command" "$HOOKS" 2>/dev/null)"
  path="$(WB_REVIEW_BIN="$SELF_DIR" HOME=/nonexistent bash -c 'eval "set -- $1"; printf %s "$1"' _ "$cmd")"
  verb="$(WB_REVIEW_BIN="$SELF_DIR" HOME=/nonexistent bash -c 'eval "set -- $1"; printf %s "${2:-}"' _ "$cmd")"
  [ -x "$path" ] && ok "$ev: script exists and is executable" || bad "$ev: script exists and is executable" "$path"
  assert_eq "$ev: verb" "$want" "$verb"
done
TS='[.hooks[][].hooks[] | select(.command | test("wb-turn-snapshot.sh"))]'
assert_eq "turn snapshot: wired on UserPromptSubmit, Stop and StopFailure" \
  "UserPromptSubmit prompt 5,Stop stop 10,StopFailure stop 10" \
  "$(jq -r '[.hooks | to_entries[] | .key as $ev | .value[].hooks[] | select(.command | test("wb-turn-snapshot.sh")) | "\($ev) \(.command | split(" ") | last) \(.timeout)"] | join(",")' "$HOOKS" 2>/dev/null)"
for cmd in $(jq -r "${TS}[].command | @base64" "$HOOKS" 2>/dev/null); do
  cmd="$(base64 -d <<<"$cmd")"
  path="$(WB_REVIEW_BIN="$SELF_DIR" HOME=/nonexistent bash -c 'eval "set -- $1"; printf %s "$1"' _ "$cmd")"
  [ -x "$path" ] && ok "turn snapshot: script exists and is executable" || bad "turn snapshot: script exists and is executable" "$path"
done
assert_eq "no wb-review-hook hook in settings.recommended.json" 0 \
  "$(jq '[.. | strings | select(test("wb-review-hook"))] | length' "$REPO/claude/.claude/settings.recommended.json")"

if [ "$fail" -eq 0 ]; then echo "ALL PASSED"; else echo "FAILED"; fi
exit "$fail"
