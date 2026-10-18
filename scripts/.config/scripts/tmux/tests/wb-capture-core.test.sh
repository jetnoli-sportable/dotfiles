#!/usr/bin/env bash
# Tests for wb-capture.sh core (U2, store auto-capture): guard chain, per-session
# state dirs, agent verbs (clear/dismiss/mute/unmute/status), log lines, and
# the KEY=value config parser.
#
# tmux is faked by a script on PATH (no real tmux server, no sockets): it
# answers `display-message` (session name), `show ... @task` ($FAKE_TASK) and
# `show -pv @wb_capture_sid` ($FAKE_SID); every other call is appended to
# $FAKE_TMUX_CALLS. HOME / XDG_* are isolated per scenario under one temp dir.
#
# Run: bash scripts/.config/scripts/tmux/tests/wb-capture-core.test.sh
set -uo pipefail

SCRIPT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/wb-capture.sh"
REAL_BASH="$(command -v bash)"

ROOT="$(mktemp -d -t wb-capture-core.XXXXXX)"
trap 'rm -rf "$ROOT"' EXIT

FAKEBIN="$ROOT/fakebin"
NOJQ_BIN="$ROOT/nojq-bin"
mkdir -p "$FAKEBIN" "$NOJQ_BIN"

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

# PATH with everything the script needs EXCEPT jq.
for b in bash cat date mkdir rm tr; do
  ln -s "$(command -v "$b")" "$NOJQ_BIN/$b"
done

fail=0
ok()   { echo "ok   - $1"; }
bad()  { echo "FAIL - $1${2:+ ($2)}"; fail=1; }
assert_eq()    { [ "$2" = "$3" ] && ok "$1" || bad "$1" "expected [$2], got [$3]"; }
assert_match() { printf '%s' "$3" | grep -qE "$2" && ok "$1" || bad "$1" "expected /$2/, got [$3]"; }
assert_file()  { [ -e "$2" ] && ok "$1" || bad "$1" "missing $2"; }
assert_nofile(){ [ ! -e "$2" ] && ok "$1" || bad "$1" "unexpected $2"; }

n=0
new_scenario() { # sets H STATE CFG CAP LOG, resets fake env
  n=$((n + 1))
  H="$ROOT/s$n"
  mkdir -p "$H/state" "$H/config"
  STATE="$H/state"; CFG="$H/config"
  CAP="$STATE/wb/capture"; LOG="$CAP/log.jsonl"
  FAKE_TASK="$H/tasks/dotfiles--feat-x.md"; FAKE_SID="sid-aaa"
  EXTRA_ENV=()
}

# run_wb <stdin-or-/dev/null> args... — sets OUT, RC. PATH override via RUN_PATH.
RUN_PATH=""
run_wb() {
  local in="$1"; shift
  local -a envv=(HOME="$H" XDG_STATE_HOME="$STATE" XDG_CONFIG_HOME="$CFG"
    PATH="${RUN_PATH:-$FAKEBIN:$PATH}" FAKE_TASK="$FAKE_TASK" FAKE_SID="$FAKE_SID"
    FAKE_TMUX_CALLS="$H/tmux-calls" TMUX=fake,1,0 TMUX_PANE=%1)
  OUT="$(env "${envv[@]}" "${EXTRA_ENV[@]}" "$REAL_BASH" "$SCRIPT" "$@" <"$in" 2>&1)"
  RC=$?
}
logn() { [ -f "$LOG" ] && wc -l <"$LOG" | tr -d ' ' || echo 0; }
sdir() { echo "$CAP/$1"; }

echo "# script exists and is executable"
[ -x "$SCRIPT" ] && ok "wb-capture.sh executable" || { bad "wb-capture.sh executable" "$SCRIPT"; echo "FAILED"; exit 1; }

echo "# guards"
guard_check() { # <desc>
  assert_eq "$1: exit 0" 0 "$RC"
  assert_eq "$1: no output" "" "$OUT"
  assert_nofile "$1: no state written" "$STATE/wb/capture"
}
new_scenario; EXTRA_ENV=(WB_CAPTURE_SWEEP=1); run_wb /dev/null mute; guard_check "recursion flag"
new_scenario; EXTRA_ENV=(WB_CAPTURE_SWEEP=1); mkdir -p "$STATE/wb"; touch "$STATE/wb/disable-capture"
run_wb /dev/null mute; guard_check "recursion flag wins over kill switch"
new_scenario; mkdir -p "$STATE/wb"; touch "$STATE/wb/disable-capture"; run_wb /dev/null mute; guard_check "kill switch"
new_scenario; EXTRA_ENV=(TMUX= TMUX_PANE=); run_wb /dev/null mute; guard_check "no tmux"
new_scenario; FAKE_TASK=""; run_wb /dev/null mute; guard_check "@task unset"
new_scenario; RUN_PATH="$FAKEBIN:$NOJQ_BIN"; run_wb /dev/null mute; guard_check "jq missing"
RUN_PATH=""
new_scenario; EXTRA_ENV=(WB_CAPTURE_SWEEP=1); run_wb /dev/null hook-stop; guard_check "recursion flag on hook verb"

echo "# mute / unmute / status"
new_scenario
run_wb /dev/null mute; assert_eq "mute exit" 0 "$RC"
assert_file "muted file" "$(sdir sid-aaa)/muted"
run_wb /dev/null status; assert_match "status shows muted" 'muted: yes' "$OUT"
assert_match "status shows log path" "$LOG" "$OUT"
run_wb /dev/null unmute
assert_nofile "muted removed" "$(sdir sid-aaa)/muted"
run_wb /dev/null status; assert_match "status shows unmuted" 'muted: no' "$OUT"
assert_eq "two log lines" 2 "$(logn)"
assert_eq "events" "muted unmuted" "$(jq -r .event "$LOG" | tr '\n' ' ' | sed 's/ $//')"
assert_eq "log task stem" "dotfiles--feat-x" "$(head -n1 "$LOG" | jq -r .task)"
assert_eq "log session_id" "sid-aaa" "$(head -n1 "$LOG" | jq -r .session_id)"
assert_match "log ts iso with colon offset" '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:]{8}[+-][0-9]{2}:[0-9]{2}$' "$(head -n1 "$LOG" | jq -r .ts)"

echo "# status pending"
new_scenario; D="$(sdir sid-aaa)"; mkdir -p "$D"; echo phrase >"$D/marker"; echo d >"$D/draft"
run_wb /dev/null status
assert_match "status marker" 'marker: present' "$OUT"
assert_match "status draft path" "draft: present.*$D/draft" "$OUT"

echo "# status: stale draft lists only the Decisions entries added since the snapshot"
new_scenario; D="$(sdir sid-aaa)"; mkdir -p "$D" "$H/tasks"; echo d >"$D/draft"; echo 1 >"$D/draft_stale"
printf '# t\n## Decisions\n### Old one\n- x\n### New one\n- y\n### Newer one\n## Done\n### Not a decision\n' >"$FAKE_TASK"
run_wb /dev/null status
assert_match "stale: warning" 'draft: .*may already be recorded' "$OUT"
assert_match "stale: lists new entry" '^### New one$' "$OUT"
assert_match "stale: lists newer entry" '^### Newer one$' "$OUT"
assert_eq "stale: old entry not listed" 0 "$(printf '%s\n' "$OUT" | /usr/bin/grep -c 'Old one')"
assert_eq "stale: other sections not listed" 0 "$(printf '%s\n' "$OUT" | /usr/bin/grep -c 'Not a decision')"
assert_match "stale: draft line still shown" "draft: present.*$D/draft" "$OUT"
rm -f "$FAKE_TASK"; run_wb /dev/null status
assert_match "stale, task unreadable: warning only" 'may already be recorded' "$OUT"
assert_eq "stale, task unreadable: no list" 0 "$(printf '%s\n' "$OUT" | /usr/bin/grep -c 'decisions added')"
new_scenario; D="$(sdir sid-aaa)"; mkdir -p "$D"; echo d >"$D/draft"
run_wb /dev/null status
assert_eq "not stale: no warning" 0 "$(printf '%s\n' "$OUT" | /usr/bin/grep -c 'may already')"
new_scenario; D="$(sdir sid-aaa)"; mkdir -p "$D"; echo 0 >"$D/draft_stale"
run_wb /dev/null status
assert_eq "draft_stale without draft: no warning" 0 "$(printf '%s\n' "$OUT" | /usr/bin/grep -c 'may already')"

echo "# dismiss / clear"
new_scenario; D="$(sdir sid-aaa)"; mkdir -p "$D"; touch "$D/marker" "$D/draft" "$D/outstanding" "$D/muted"
run_wb /dev/null dismiss; assert_eq "dismiss exit" 0 "$RC"
assert_nofile "dismiss removes marker" "$D/marker"
assert_nofile "dismiss removes draft" "$D/draft"
assert_nofile "dismiss removes outstanding" "$D/outstanding"
assert_file "dismiss leaves muted" "$D/muted"
assert_eq "dismiss logs once" 1 "$(logn)"
assert_eq "dismiss event" dismissed "$(jq -r .event "$LOG")"
run_wb /dev/null dismiss
assert_eq "dismiss nothing pending: quiet" "" "$OUT"
assert_eq "dismiss nothing pending: no new log" 1 "$(logn)"

new_scenario; D="$(sdir sid-aaa)"; mkdir -p "$D"; touch "$D/marker" "$D/draft"; printf sweep >"$D/outstanding"
run_wb /dev/null clear; assert_eq "clear exit" 0 "$RC"
assert_nofile "clear removes marker" "$D/marker"
assert_nofile "clear removes draft" "$D/draft"
assert_nofile "clear removes outstanding" "$D/outstanding"
assert_eq "clear resolves outstanding: one log line" 1 "$(logn)"
assert_eq "clear logs followed, not dismissed" followed "$(jq -r .event "$LOG")"
assert_eq "clear keeps the nudge source" sweep "$(jq -r .source "$LOG")"
new_scenario; D="$(sdir sid-aaa)"; mkdir -p "$D"; touch "$D/marker" "$D/draft"
run_wb /dev/null clear
assert_eq "clear with no outstanding logs nothing" 0 "$(logn)"

echo "# session isolation"
new_scenario; A="$(sdir sid-aaa)"; B="$(sdir sid-bbb)"; mkdir -p "$A" "$B"; touch "$A/marker" "$B/marker"
FAKE_SID=sid-bbb; run_wb /dev/null mute
assert_file "B muted" "$B/muted"; assert_nofile "A not muted" "$A/muted"
run_wb /dev/null dismiss
assert_nofile "B marker removed" "$B/marker"; assert_file "A marker untouched" "$A/marker"

echo "# sid unset / invalid"
new_scenario; FAKE_SID=""; run_wb /dev/null dismiss
assert_eq "unset sid exit" 0 "$RC"
assert_match "unset sid error line" '^wb-capture: no capture session recorded on this pane yet \(@wb_capture_sid unset\)$' "$OUT"
assert_eq "unset sid: single line" 1 "$(printf '%s\n' "$OUT" | wc -l | tr -d ' ')"
assert_nofile "unset sid: no state" "$CAP"

new_scenario; mkdir -p "$STATE/wb/x"; touch "$STATE/wb/x/marker" "$STATE/wb/x/draft"
for bad_sid in '../x' 'a/b' '.' '..' 'a b'; do
  FAKE_SID="$bad_sid"
  for v in dismiss clear mute unmute; do run_wb /dev/null "$v"; assert_eq "invalid sid [$bad_sid] $v exit" 0 "$RC"; done
done
assert_file "traversal target marker intact" "$STATE/wb/x/marker"
assert_file "traversal target draft intact" "$STATE/wb/x/draft"
assert_nofile "traversal: nothing created" "$STATE/wb/x/muted"
assert_eq "invalid sids log nothing" 0 "$(logn)"

echo "# config"
cfg_get() { printf '%s\n' "$OUT" | sed -n "s/^$1=//p"; }
DEFAULT_PHRASES='we decided|decided to|going with|let'"'"'s go with|we'"'"'ll go with|i'"'"'ll go with|went with|settled on|the decision is|chose |opting for|ruled out'
new_scenario; run_wb /dev/null _config
assert_eq "default cooldown" 3 "$(cfg_get cooldown)"
assert_eq "default sweep_every" 4 "$(cfg_get sweep_every)"
assert_eq "default sweep" on "$(cfg_get sweep)"
assert_eq "default sweep_timeout" 60 "$(cfg_get sweep_timeout)"
assert_eq "default sweep_max_failures" 3 "$(cfg_get sweep_max_failures)"
assert_eq "default phrases" "$DEFAULT_PHRASES" "$(cfg_get phrases)"

new_scenario; mkdir -p "$CFG/wb"
cat >"$CFG/wb/capture.conf" <<CONF
# comment
cooldown=7
bogus_key=1
this line is malformed
=novalue
sweep_every=abc
sweep=off
sweep_timeout=90
sweep_max_failures=5
phrases=we agreed|\$(touch $H/pwned)
CONF
run_wb /dev/null _config
assert_eq "cooldown applied" 7 "$(cfg_get cooldown)"
assert_eq "non-integer falls back" 4 "$(cfg_get sweep_every)"
assert_eq "sweep applied" off "$(cfg_get sweep)"
assert_eq "timeout applied" 90 "$(cfg_get sweep_timeout)"
assert_eq "sweep_max_failures applied" 5 "$(cfg_get sweep_max_failures)"
assert_eq "command substitution stays literal" "we agreed|\$(touch $H/pwned)" "$(cfg_get phrases)"
assert_nofile "payload never executed" "$H/pwned"
assert_eq "unknown key ignored" "" "$(cfg_get bogus_key)"
assert_nofile "_config writes no state" "$CAP"

new_scenario; mkdir -p "$CFG/wb"; printf 'sweep=maybe\ncooldown=-2\n' >"$CFG/wb/capture.conf"
run_wb /dev/null _config
assert_eq "bad sweep value -> default" on "$(cfg_get sweep)"
new_scenario; mkdir -p "$CFG/wb"; printf 'sweep_max_failures=many\n' >"$CFG/wb/capture.conf"
run_wb /dev/null _config
assert_eq "bad sweep_max_failures -> default" 3 "$(cfg_get sweep_max_failures)"
assert_eq "negative cooldown -> default" 3 "$(cfg_get cooldown)"

if [ "$fail" -eq 0 ]; then echo "ALL PASSED"; else echo "FAILED"; fi
exit "$fail"
