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

# item <stem> <id> <record-path> — a pending queue item as the server writes it.
item() {
  mkdir -p "$RQ/$1/queue/pending"
  printf '{"id":"%s","stem":"%s","record":"%s","created":"2026-11-22T20:15:00Z","comments":3}\n' "$2" "$1" "$3" \
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

# --- inflight: deliver is busy until the next hook-stop clears it ---------------------------
t set -pu -t "$P1" @claude_working
item tk-a r-2 "$REC_B"
: >"$CALLS"
deliver tk-a
assert_eq "inflight: deliver types nothing" 0 "$(sends)"
assert_eq "inflight: status says a hand-over is being worked on" "a review hand-over is still being worked on" "$(status_of tk-a)"
mv "$RQ/tk-a/queue/pending/r-2.json" "$FIX/r-2.json"
hook hook-stop "$P1" >/dev/null
[ ! -e "$RQ/tk-a/queue/inflight" ] && ok "inflight: the next hook-stop removes it" || bad "inflight: the next hook-stop removes it"
assert_eq "AE1: second hook-stop after delivery prints nothing" "" "$(hook hook-stop "$P1")"
mv "$FIX/r-2.json" "$RQ/tk-a/queue/pending/r-2.json"
: >"$CALLS"
deliver tk-a
assert_eq "inflight cleared: deliver types the pointer" 2 "$(sends)"
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

# --- the plugin ---------------------------------------------------------------------------------------
PLUGIN="$REPO/claude/.claude/skills/wb-review-hook"
HOOKS="$PLUGIN/hooks/hooks.json"
MANIFEST="$PLUGIN/.claude-plugin/plugin.json"
assert_eq "plugin name" wb-review-hook "$(jq -r .name "$MANIFEST" 2>/dev/null)"
assert_eq "manifest keys are name/description/author only" '["author","description","name"]' "$(jq -c keys "$MANIFEST" 2>/dev/null)"
[ ! -e "$PLUGIN/SKILL.md" ] && ok "plugin dir carries no SKILL.md (hooks only)" || bad "plugin dir carries no SKILL.md (hooks only)"
assert_eq "plugin: exactly Stop and SessionStart" '["SessionStart","Stop"]' "$(jq -c '.hooks | keys' "$HOOKS" 2>/dev/null)"
assert_eq "plugin: one hook per event" 2 "$(jq '[.hooks[][].hooks[]] | length' "$HOOKS" 2>/dev/null)"
for pair in Stop:hook-stop SessionStart:hook-session-start; do
  ev="${pair%%:*}" want="${pair#*:}"
  assert_eq "$ev: timeout 5, synchronous" "5 false" "$(jq -r ".hooks.${ev}[0].hooks[0] | \"\(.timeout) \(.async == true)\"" "$HOOKS" 2>/dev/null)"
  cmd="$(jq -r ".hooks.${ev}[0].hooks[0].command" "$HOOKS" 2>/dev/null)"
  path="$(WB_REVIEW_BIN="$SELF_DIR" HOME=/nonexistent bash -c 'eval "set -- $1"; printf %s "$1"' _ "$cmd")"
  verb="$(WB_REVIEW_BIN="$SELF_DIR" HOME=/nonexistent bash -c 'eval "set -- $1"; printf %s "${2:-}"' _ "$cmd")"
  [ -x "$path" ] && ok "$ev: script exists and is executable" || bad "$ev: script exists and is executable" "$path"
  assert_eq "$ev: verb" "$want" "$verb"
done
assert_eq "no wb-review-hook hook in settings.recommended.json" 0 \
  "$(jq '[.. | strings | select(test("wb-review-hook"))] | length' "$REPO/claude/.claude/settings.recommended.json")"

if [ "$fail" -eq 0 ]; then echo "ALL PASSED"; else echo "FAILED"; fi
exit "$fail"
