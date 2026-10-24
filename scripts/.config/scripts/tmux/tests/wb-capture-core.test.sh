#!/usr/bin/env bash
# Tests for wb-capture.sh core (U2, store auto-capture; shelf-only since the nudge
# rework): guard chain, per-session state dirs, agent verbs (mute/unmute/status/
# accept/dismiss/keep), log lines, and the KEY=value config parser.
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
for b in bash cat date mkdir mv rm tr; do
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

echo "# status: shelf-only (no marker / draft / draft_sha lines, even with legacy state present)"
new_scenario; D="$(sdir sid-aaa)"; mkdir -p "$D"; echo phrase >"$D/marker"; echo d >"$D/draft"; echo 1 >"$D/draft_stale"
run_wb /dev/null status
assert_eq "status exit" 0 "$RC"
assert_eq "status: no marker line" 0 "$(printf '%s\n' "$OUT" | /usr/bin/grep -c '^marker:')"
assert_eq "status: no draft line" 0 "$(printf '%s\n' "$OUT" | /usr/bin/grep -c '^draft')"
assert_eq "status: no stale warning" 0 "$(printf '%s\n' "$OUT" | /usr/bin/grep -c 'may already')"
assert_match "status still shows mute state" '^muted: no$' "$OUT"
assert_match "status still shows the session" '^session: sid-aaa$' "$OUT"
assert_match "status still shows the shelved summary" '^shelved: none$' "$OUT"

echo "# removed verbs are silent no-ops: clear and review change nothing and print nothing"
new_scenario; D="$(sdir sid-aaa)"; mkdir -p "$D"; touch "$D/draft" "$D/muted"
for v in clear review; do
  run_wb /dev/null "$v"
  assert_eq "$v: exit 0, no output" "0:" "$RC:$OUT"
done
run_wb /dev/null clear --draft
assert_eq "clear --draft: exit 0, no output" "0:" "$RC:$OUT"
assert_file "removed verbs leave the session draft" "$D/draft"
assert_file "removed verbs leave muted" "$D/muted"
assert_eq "removed verbs log nothing" 0 "$(logn)"

echo "# shelved drafts: status lists, accept / dismiss <path> archive + log (with the draft's basename)"
new_scenario; D="$(sdir sid-aaa)"; PK="$CAP/shelved/dotfiles--feat-x"; mkdir -p "$D" "$PK"
run_wb /dev/null status
assert_match "no shelved drafts" 'shelved: none' "$OUT"
printf 'one\n' >"$PK/20261018T100000-sid-aaa.md"
printf 'two\n' >"$PK/20261018T110000-sid-bbb.md"; : >"$PK/20261018T110000-sid-bbb.md.stale"
mkdir -p "$CAP/shelved/other--task"; printf 'x\n' >"$CAP/shelved/other--task/20261018T090000-sid-ccc.md"
run_wb /dev/null status
assert_match "lists first path" "shelved: $PK/20261018T100000-sid-aaa.md\$" "$OUT"
assert_match "lists stale one marked" "shelved: $PK/20261018T110000-sid-bbb.md \\(stale\\)" "$OUT"
assert_eq "other task's drafts not listed" 0 "$(printf '%s\n' "$OUT" | /usr/bin/grep -c 'other--task')"
run_wb /dev/null accept "$PK/20261018T100000-sid-aaa.md"
assert_eq "accept exit" 0 "$RC"
assert_nofile "accept moves the draft off the shelf" "$PK/20261018T100000-sid-aaa.md"
assert_eq "accept logs shelved_accepted once" 1 "$(jq -r 'select(.event=="shelved_accepted")|.event' "$LOG" | wc -l | tr -d ' ')"
assert_eq "accept's draft field is the file's basename" 20261018T100000-sid-aaa.md "$(jq -r 'select(.event=="shelved_accepted")|.draft' "$LOG")"
assert_eq "accept carries no source" null "$(jq -r 'select(.event=="shelved_accepted")|.source // null' "$LOG")"
assert_eq "accept untagged when not stale" null "$(jq -r 'select(.event=="shelved_accepted")|.stale // null' "$LOG")"
assert_eq "accept leaves no flag file" 0 "$(ls "$D" | wc -l | tr -d ' ')"
run_wb /dev/null dismiss "$PK/20261018T110000-sid-bbb.md"
assert_eq "dismiss <path> exit" 0 "$RC"
assert_nofile "dismiss <path> moves the draft" "$PK/20261018T110000-sid-bbb.md"
assert_nofile "dismiss <path> moves the stale marker" "$PK/20261018T110000-sid-bbb.md.stale"
assert_eq "dismiss <path> logs shelved_dismissed" shelved_dismissed "$(jq -r 'select(.event=="shelved_dismissed")|.event' "$LOG")"
assert_eq "dismiss <path>'s draft field is the file's basename" 20261018T110000-sid-bbb.md "$(jq -r 'select(.event=="shelved_dismissed")|.draft' "$LOG")"
assert_eq "dismiss <path> carries no source" null "$(jq -r 'select(.event=="shelved_dismissed")|.source // null' "$LOG")"
assert_eq "dismiss <path> tagged stale" true "$(jq -r 'select(.event=="shelved_dismissed")|.stale' "$LOG")"
assert_eq "dismiss <path> logs no bare dismissed" 0 "$(jq -r 'select(.event=="dismissed")|.event' "$LOG" | wc -l | tr -d ' ')"
assert_file "other task's draft untouched" "$CAP/shelved/other--task/20261018T090000-sid-ccc.md"
run_wb /dev/null status
assert_match "all resolved" 'shelved: none' "$OUT"

echo "# keep <path>: logs shelved_kept and leaves the draft exactly where it is"
new_scenario; D="$(sdir sid-aaa)"; PK="$CAP/shelved/dotfiles--feat-x"; mkdir -p "$D" "$PK"
printf 'one\n' >"$PK/20261018T100000-sid-aaa.md"; : >"$PK/20261018T100000-sid-aaa.md.stale"
run_wb /dev/null keep "$PK/20261018T100000-sid-aaa.md"
assert_eq "keep exit 0, no output" "0:" "$RC:$OUT"
assert_eq "keep leaves the draft in place, unchanged" one "$(cat "$PK/20261018T100000-sid-aaa.md")"
assert_file "keep leaves the stale sidecar" "$PK/20261018T100000-sid-aaa.md.stale"
assert_eq "keep archives nothing" 0 "$(ls "$CAP/resolved" 2>/dev/null | wc -l | tr -d ' ')"
assert_eq "keep logs exactly one line" 1 "$(logn)"
assert_eq "keep event" shelved_kept "$(jq -r .event "$LOG")"
assert_eq "keep's draft field is the file's basename" 20261018T100000-sid-aaa.md "$(jq -r .draft "$LOG")"
assert_eq "keep carries no source" null "$(jq -r '.source // null' "$LOG")"
assert_eq "keep logs the task stem" dotfiles--feat-x "$(jq -r .task "$LOG")"
run_wb /dev/null keep "$PK/20261018T100000-sid-aaa.md"
assert_eq "keep twice: logged twice (one per review)" 2 "$(logn)"
run_wb /dev/null keep "$H/nowhere.md"
assert_eq "keep outside the shelf: exit 1" 1 "$RC"
assert_match "keep outside the shelf explains on stderr" 'wb-capture:' "$OUT"
assert_eq "keep outside the shelf logs nothing" 2 "$(logn)"
run_wb /dev/null keep
assert_eq "keep without a path: exit 1" 1 "$RC"
assert_eq "keep without a path logs nothing" 2 "$(logn)"
PX="$CAP/shelved/closed--task"; mkdir -p "$PX"; printf 'z\n' >"$PX/20261018T120000-sid-z.md"
run_wb /dev/null keep "$PX/20261018T120000-sid-z.md"
assert_eq "keep another task's draft without --task: exit 1" 1 "$RC"
run_wb /dev/null keep --task closed--task "$PX/20261018T120000-sid-z.md"
assert_eq "keep --task: exit 0" 0 "$RC"
assert_eq "keep --task logs for that task's stem" closed--task "$(tail -n1 "$LOG" | jq -r .task)"
assert_file "keep --task leaves that draft" "$PX/20261018T120000-sid-z.md"
# keep works without a wb session, like accept/dismiss
EXTRA_ENV=(TMUX= TMUX_PANE=)
run_wb /dev/null keep --task closed--task "$PX/20261018T120000-sid-z.md"
assert_eq "keep --task without tmux: exit 0" 0 "$RC"
assert_eq "...logged with an empty session_id" "" "$(tail -n1 "$LOG" | jq -r .session_id)"
EXTRA_ENV=()

echo "# shelved drafts: paths outside the shelved dir are refused"
new_scenario; D="$(sdir sid-aaa)"; PK="$CAP/shelved/dotfiles--feat-x"; mkdir -p "$D" "$PK"
printf 'keep\n' >"$H/victim.md"; printf 'keep\n' >"$CAP/shelved/other--task.md"
mkdir -p "$CAP/shelved/other--task"; printf 'keep\n' >"$CAP/shelved/other--task/20261018T090000-sid-ccc.md"
ln -s "$H/victim.md" "$PK/20261018T120000-sid-link.md"
for bad in "$H/victim.md" "$PK/../../../../victim.md" "$PK/../other--task/20261018T090000-sid-ccc.md" \
           "$CAP/shelved/other--task/20261018T090000-sid-ccc.md" "$PK/20261018T120000-sid-link.md" \
           "$PK/missing.md" "$PK" "" "$PK/sub/x.md"; do
  for v in accept dismiss keep; do
    run_wb /dev/null "$v" "$bad"
    [ "$RC" -ne 0 ] && ok "$v refuses [$bad]" || bad "$v refuses [$bad]" "exit 0"
    assert_match "$v refusal explains on stderr" 'wb-capture' "$OUT"
  done
done
assert_file "victim untouched" "$H/victim.md"
assert_file "sibling task's draft untouched" "$CAP/shelved/other--task/20261018T090000-sid-ccc.md"
assert_file "symlink untouched" "$PK/20261018T120000-sid-link.md"
assert_eq "nothing logged by refusals" 0 "$(logn)"

echo "# bare dismiss (no path, no --task) is a usage error: exit 1, nothing removed, nothing logged"
new_scenario; D="$(sdir sid-aaa)"; PK="$CAP/shelved/dotfiles--feat-x"; mkdir -p "$D" "$PK"
touch "$D/draft" "$D/muted"; printf 's\n' >"$PK/20261018T100000-sid-a.md"
run_wb /dev/null dismiss
assert_eq "bare dismiss: exit 1" 1 "$RC"
assert_match "bare dismiss: usage message" 'usage: wb-capture.sh dismiss' "$OUT"
assert_file "bare dismiss: session draft kept" "$D/draft"
assert_file "bare dismiss: muted kept" "$D/muted"
assert_file "bare dismiss: shelved draft kept" "$PK/20261018T100000-sid-a.md"
assert_eq "bare dismiss: nothing logged" 0 "$(logn)"
assert_eq "bare dismiss: nothing archived" 0 "$(ls "$CAP/resolved" 2>/dev/null | wc -l | tr -d ' ')"
EXTRA_ENV=(TMUX= TMUX_PANE=); run_wb /dev/null dismiss
assert_eq "bare dismiss outside a session: still exit 1" 1 "$RC"
EXTRA_ENV=()
run_wb /dev/null dismiss ""
assert_eq "dismiss with an empty path: exit 1" 1 "$RC"

echo "# removed flags are refused, never mistaken for a path (a stale skill must not retire a draft early)"
PKF="$PK/20261018T100000-sid-a.md"
run_wb /dev/null accept --begin "$PKF"
assert_eq "accept --begin: exit 1" 1 "$RC"
assert_match "accept --begin: says the option is unknown" 'unknown option --begin' "$OUT"
assert_file "accept --begin: the draft stays on the shelf" "$PKF"
run_wb /dev/null dismiss --expect none "$PKF"
assert_eq "dismiss --expect: exit 1" 1 "$RC"
assert_file "dismiss --expect: the draft stays on the shelf" "$PKF"
run_wb /dev/null dismiss --expect none
assert_eq "bare dismiss --expect: exit 1" 1 "$RC"
assert_file "...and the draft is still there" "$PKF"
assert_eq "refused flags log nothing" 0 "$(logn)"

echo "# retire_draft: resolved drafts are archived under resolved/<stem>/, never deleted"
RS="dotfiles--feat-x"
res_files() { ls "$CAP/resolved/$RS" 2>/dev/null; }  # sorted names, empty when none
# shelved accept / dismiss archive the file and its .stale sidecar
new_scenario; PK="$CAP/shelved/$RS"; mkdir -p "$PK"
printf 'one\n' >"$PK/20261018T100000-sid-aaa.md"; : >"$PK/20261018T100000-sid-aaa.md.stale"
printf 'two\n' >"$PK/20261018T110000-sid-bbb.md"
run_wb /dev/null accept "$PK/20261018T100000-sid-aaa.md"; assert_eq "retire: shelved accept exit" 0 "$RC"
assert_nofile "retire: shelved accept moves the file" "$PK/20261018T100000-sid-aaa.md"
assert_nofile "retire: shelved accept moves the sidecar" "$PK/20261018T100000-sid-aaa.md.stale"
assert_eq "retire: archived accept file name" 1 "$(res_files | /usr/bin/grep -cE '^[0-9]{8}T[0-9]{6}-shelved_accepted-20261018T100000-sid-aaa\.md$')"
assert_eq "retire: archived accept sidecar name" 1 "$(res_files | /usr/bin/grep -cE '^[0-9]{8}T[0-9]{6}-shelved_accepted-20261018T100000-sid-aaa\.md\.stale$')"
run_wb /dev/null dismiss "$PK/20261018T110000-sid-bbb.md"; assert_eq "retire: shelved dismiss exit" 0 "$RC"
assert_eq "retire: archived dismiss file name" 1 "$(res_files | /usr/bin/grep -cE '^[0-9]{8}T[0-9]{6}-shelved_dismissed-20261018T110000-sid-bbb\.md$')"
assert_eq "retire: archived text kept" "two" "$(cat "$CAP/resolved/$RS/"*-shelved_dismissed-*.md)"
# a failed retire changes nothing: file kept, exit 1, no event
new_scenario; PK="$CAP/shelved/$RS"; D="$(sdir sid-aaa)"; mkdir -p "$PK" "$D" "$CAP/resolved"
printf 'one\n' >"$PK/20261018T100000-sid-aaa.md"; : >"$PK/20261018T100000-sid-aaa.md.stale"
: >"$CAP/resolved/$RS"
run_wb /dev/null dismiss "$PK/20261018T100000-sid-aaa.md"
assert_eq "retire fail: shelved dismiss exit 1" 1 "$RC"
assert_match "retire fail: shelved dismiss message" 'could not archive .* \(nothing changed\)' "$OUT"
assert_file "retire fail: shelved draft kept" "$PK/20261018T100000-sid-aaa.md"
assert_file "retire fail: sidecar kept" "$PK/20261018T100000-sid-aaa.md.stale"
assert_eq "retire fail: nothing logged" 0 "$(logn)"
run_wb /dev/null accept "$PK/20261018T100000-sid-aaa.md"
assert_eq "retire fail: shelved accept exit 1" 1 "$RC"
assert_file "retire fail: accept keeps the draft" "$PK/20261018T100000-sid-aaa.md"
assert_eq "retire fail: accept logs nothing" 0 "$(logn)"

echo "# session isolation"
new_scenario; A="$(sdir sid-aaa)"; B="$(sdir sid-bbb)"; mkdir -p "$A" "$B"
FAKE_SID=sid-bbb; run_wb /dev/null mute
assert_file "B muted" "$B/muted"; assert_nofile "A not muted" "$A/muted"

echo "# sid unset / invalid"
new_scenario; FAKE_SID=""; run_wb /dev/null status
assert_eq "unset sid exit" 0 "$RC"
assert_match "unset sid error line" '^wb-capture: no capture session recorded on this pane yet \(@wb_capture_sid unset\)$' "$OUT"
assert_eq "unset sid: single line" 1 "$(printf '%s\n' "$OUT" | wc -l | tr -d ' ')"
assert_nofile "unset sid: no state" "$CAP"

new_scenario; mkdir -p "$STATE/wb/x"; touch "$STATE/wb/x/marker" "$STATE/wb/x/draft"
for bad_sid in '../x' 'a/b' '.' '..' 'a b'; do
  FAKE_SID="$bad_sid"
  for v in status mute unmute; do run_wb /dev/null "$v"; assert_eq "invalid sid [$bad_sid] $v exit" 0 "$RC"; done
done
assert_file "traversal target marker intact" "$STATE/wb/x/marker"
assert_file "traversal target draft intact" "$STATE/wb/x/draft"
assert_nofile "traversal: nothing created" "$STATE/wb/x/muted"
assert_eq "invalid sids log nothing" 0 "$(logn)"

echo "# config"
cfg_get() { printf '%s\n' "$OUT" | sed -n "s/^$1=//p"; }
new_scenario; run_wb /dev/null _config
assert_eq "default sweep_every" 4 "$(cfg_get sweep_every)"
assert_eq "default sweep" on "$(cfg_get sweep)"
assert_eq "default sweep_timeout" 60 "$(cfg_get sweep_timeout)"
assert_eq "default sweep_max_failures" 3 "$(cfg_get sweep_max_failures)"
assert_eq "no phrases key" 0 "$(printf '%s\n' "$OUT" | /usr/bin/grep -c '^phrases=')"
assert_eq "no cooldown key" 0 "$(printf '%s\n' "$OUT" | /usr/bin/grep -c '^cooldown=')"

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
assert_eq "config with phrases= and cooldown= still loads" 0 "$RC"
assert_eq "cooldown line ignored: not printed" 0 "$(printf '%s\n' "$OUT" | /usr/bin/grep -c 'cooldown')"
assert_eq "phrases line ignored: not printed" 0 "$(printf '%s\n' "$OUT" | /usr/bin/grep -c 'phrases\|we agreed')"
assert_eq "non-integer falls back" 4 "$(cfg_get sweep_every)"
assert_eq "sweep applied" off "$(cfg_get sweep)"
assert_eq "timeout applied" 90 "$(cfg_get sweep_timeout)"
assert_eq "sweep_max_failures applied" 5 "$(cfg_get sweep_max_failures)"
assert_nofile "payload never executed" "$H/pwned"
assert_eq "unknown key ignored" "" "$(cfg_get bogus_key)"
assert_nofile "_config writes no state" "$CAP"

new_scenario; mkdir -p "$CFG/wb"; printf 'sweep=maybe\ncooldown=3\nphrases=\n' >"$CFG/wb/capture.conf"
run_wb /dev/null _config
assert_eq "bad sweep value -> default" on "$(cfg_get sweep)"
assert_eq "cooldown=3 / empty phrases=: loads, nothing printed" "" "$(printf '%s\n' "$OUT" | /usr/bin/grep 'cooldown\|phrases')"
new_scenario; mkdir -p "$CFG/wb"; printf 'sweep_max_failures=many\n' >"$CFG/wb/capture.conf"
run_wb /dev/null _config
assert_eq "bad sweep_max_failures -> default" 3 "$(cfg_get sweep_max_failures)"

echo "# store verbs: shelved [--all | --task] (read-only, no @task needed)"
new_scenario; PK="$CAP/shelved/dotfiles--feat-x"; PO="$CAP/shelved/done--task"; mkdir -p "$PK" "$PO"
printf 'a\n' >"$PK/20261018T100000-sid-a.md"
printf 'b\n' >"$PO/20261018T110000-sid-b.md"; : >"$PO/20261018T110000-sid-b.md.stale"
printf 'c\n' >"$PO/20261018T120000-sid-c.md"
run_wb /dev/null shelved --task done--task
assert_eq "shelved --task exit" 0 "$RC"
assert_eq "shelved --task: paths, (stale) suffix, no sidecars" "$PO/20261018T110000-sid-b.md (stale)
$PO/20261018T120000-sid-c.md" "$OUT"
run_wb /dev/null shelved --all
assert_eq "shelved --all groups by task stem" "done--task:
  $PO/20261018T110000-sid-b.md (stale)
  $PO/20261018T120000-sid-c.md
dotfiles--feat-x:
  $PK/20261018T100000-sid-a.md" "$OUT"
run_wb /dev/null shelved
assert_eq "bare shelved lists the session task's drafts" "$PK/20261018T100000-sid-a.md" "$OUT"
run_wb /dev/null shelved --task nosuch--task
assert_eq "shelved --task with none: empty, exit 0" "0:" "$RC:$OUT"
run_wb /dev/null shelved --task ../x; assert_eq "shelved --task rejects a bad stem" 1 "$RC"
run_wb /dev/null shelved --bogus;     assert_eq "shelved rejects an unknown flag" 1 "$RC"
assert_eq "shelved logs nothing, changes nothing" 0 "$(logn)"
# no tmux, no @task, no jq: the store verbs still work
EXTRA_ENV=(TMUX= TMUX_PANE=); FAKE_TASK=""; RUN_PATH="$FAKEBIN:$NOJQ_BIN"
run_wb /dev/null shelved --task done--task
assert_eq "shelved --task needs no tmux, @task or jq" "$PO/20261018T110000-sid-b.md (stale)
$PO/20261018T120000-sid-c.md" "$OUT"
run_wb /dev/null shelved; assert_eq "bare shelved outside a session: error exit 1" 1 "$RC"
RUN_PATH=""; EXTRA_ENV=(WB_CAPTURE_SWEEP=1)
run_wb /dev/null shelved --all; assert_eq "recursion flag: silent no-op" "0:" "$RC:$OUT"
EXTRA_ENV=()

echo "# store verbs: shelved --count, shelved --all --min-age-days"
new_scenario; PK="$CAP/shelved/proj--eta"; mkdir -p "$PK" "$CAP/shelved/proj--old"
OLD_TS="$(date -d '8 days ago' +%Y%m%dT%H%M%S)"; NEW_TS="$(date +%Y%m%dT%H%M%S)"
printf 'a\n' >"$PK/$OLD_TS-sid-a.md"; printf 'b\n' >"$PK/$NEW_TS-sid-b.md"; printf 'c\n' >"$PK/$NEW_TS-sid-c.md"
printf 'o\n' >"$CAP/shelved/proj--old/$OLD_TS-sid-o.md"; : >"$CAP/shelved/proj--old/$OLD_TS-sid-o.md.stale"
EXTRA_ENV=(TMUX= TMUX_PANE=); FAKE_TASK=""
run_wb /dev/null shelved --count --task proj--eta
assert_eq "count of three shelved drafts" "0:3" "$RC:$OUT"
run_wb /dev/null shelved --count --task nosuch--task
assert_eq "count with no shelf dir: 0" "0:0" "$RC:$OUT"
mkdir -p "$CAP/shelved/empty--task"
run_wb /dev/null shelved --count --task empty--task
assert_eq "count of an empty shelf dir: 0" "0:0" "$RC:$OUT"
run_wb /dev/null shelved --count --task ../x; assert_eq "count rejects a bad stem" 1 "$RC"
run_wb /dev/null shelved --count; assert_eq "count needs --task" 1 "$RC"
: >"$H/tmux-calls"
run_wb /dev/null shelved --count --task proj--eta
assert_eq "count makes no tmux call" "" "$(cat "$H/tmux-calls" 2>/dev/null)"
run_wb /dev/null shelved --all --min-age-days 7
assert_eq "--min-age-days: only drafts older than N days, grouped by stem" "proj--eta:
  $PK/$OLD_TS-sid-a.md
proj--old:
  $CAP/shelved/proj--old/$OLD_TS-sid-o.md (stale)" "$OUT"
run_wb /dev/null shelved --all --min-age-days 30
assert_eq "--min-age-days 30: nothing that old" "0:" "$RC:$OUT"
run_wb /dev/null shelved --all --min-age-days x; assert_eq "--min-age-days needs a number" 1 "$RC"
assert_eq "count and age filter log nothing" 0 "$(logn)"
EXTRA_ENV=()

echo "# store verb: pending-for-task (shelved drafts only)"
new_scenario; TF="$H/tasks/proj--eta.md"; mkdir -p "$H/tasks" "$CAP/shelved/proj--eta" "$CAP/shelved/proj--other"
printf 't\n' >"$TF"
printf 's\n' >"$CAP/shelved/proj--eta/20261018T100000-sid-a.md"; : >"$CAP/shelved/proj--eta/20261018T100000-sid-a.md.stale"
printf 'o\n' >"$CAP/shelved/proj--other/20261018T100000-sid-o.md"
mkdir -p "$CAP/sid-live" "$CAP/sid-elsewhere" "$CAP/sid-nodraft"
printf 'd\n' >"$CAP/sid-live/draft";      printf '%s\n' "$TF" >"$CAP/sid-live/taskpath"
printf 'd\n' >"$CAP/sid-elsewhere/draft"; printf '%s\n' "$H/tasks/proj--other.md" >"$CAP/sid-elsewhere/taskpath"
printf '%s\n' "$TF" >"$CAP/sid-nodraft/taskpath"
mkdir -p "$CAP/sid-notask"; printf 'd\n' >"$CAP/sid-notask/draft"
EXTRA_ENV=(TMUX= TMUX_PANE=); FAKE_TASK=""
run_wb /dev/null pending-for-task "$TF"
assert_eq "pending-for-task exit" 0 "$RC"
assert_eq "shelved drafts of the stem only; a live session draft is not listed" "$CAP/shelved/proj--eta/20261018T100000-sid-a.md" "$OUT"
run_wb /dev/null pending-for-task "$H/tasks/proj--none.md"
assert_eq "no drafts: no output, exit 0" "0:" "$RC:$OUT"
run_wb /dev/null pending-for-task; assert_eq "no task-file arg: exit 1" 1 "$RC"
EXTRA_ENV=()

echo "# store verb: log-shelved-left"
new_scenario; EXTRA_ENV=(TMUX= TMUX_PANE=); FAKE_TASK=""
run_wb /dev/null log-shelved-left proj--eta 2
assert_eq "log-shelved-left exit" 0 "$RC"
assert_eq "one line" 1 "$(logn)"
assert_eq "event" shelved_left "$(jq -r .event "$LOG")"
assert_eq "count is a number" 2 "$(jq -r '.count|if type=="number" then . else "x" end' "$LOG")"
assert_eq "task" proj--eta "$(jq -r .task "$LOG")"
assert_eq "session_id empty" "" "$(jq -r .session_id "$LOG")"
assert_eq "no source" null "$(jq -r '.source // null' "$LOG")"
assert_match "ts iso" '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:]{8}[+-][0-9]{2}:[0-9]{2}$' "$(jq -r .ts "$LOG")"
run_wb /dev/null log-shelved-left proj--eta two;   assert_eq "non-numeric count refused" 1 "$RC"
run_wb /dev/null log-shelved-left ../x 1;         assert_eq "bad stem refused" 1 "$RC"
run_wb /dev/null log-shelved-left proj--eta 007;  assert_eq "leading zeros normalised" 7 "$(tail -n1 "$LOG" | jq -r .count)"
assert_eq "refusals logged nothing" 2 "$(logn)"
RUN_PATH="$FAKEBIN:$NOJQ_BIN"; run_wb /dev/null log-shelved-left proj--eta 1
assert_eq "no jq: silent no-op" "0:" "$RC:$OUT"; assert_eq "no jq: nothing logged" 2 "$(logn)"
RUN_PATH=""; EXTRA_ENV=()

echo "# accept / dismiss --task <stem>: resolve another (closed) task's shelved draft"
new_scenario; D="$(sdir sid-aaa)"; PX="$CAP/shelved/closed--task"; PK="$CAP/shelved/dotfiles--feat-x"; mkdir -p "$D" "$PX" "$PK"
printf 'x\n' >"$PX/20261018T100000-sid-x.md"; : >"$PX/20261018T100000-sid-x.md.stale"
printf 'y\n' >"$PX/20261018T110000-sid-y.md"
printf 'z\n' >"$PX/20261018T120000-sid-z.md"
printf 'k\n' >"$PK/20261018T130000-sid-k.md"
run_wb /dev/null dismiss "$PX/20261018T110000-sid-y.md"
assert_eq "without --task a closed task's draft is refused" 1 "$RC"
assert_file "...and left alone" "$PX/20261018T110000-sid-y.md"
run_wb /dev/null dismiss --task closed--task "$PX/20261018T110000-sid-y.md"
assert_eq "dismiss --task exit" 0 "$RC"
assert_nofile "dismiss --task deletes the draft" "$PX/20261018T110000-sid-y.md"
assert_eq "dismiss --task logs shelved_dismissed" 1 "$(jq -r 'select(.event=="shelved_dismissed")|.event' "$LOG" | wc -l | tr -d ' ')"
assert_eq "...for the closed task's stem" closed--task "$(jq -r 'select(.event=="shelved_dismissed")|.task' "$LOG")"
run_wb /dev/null dismiss --task closed--task "$PK/20261018T130000-sid-k.md"
assert_eq "--task <stem> validates against that stem's dir (current task's draft refused)" 1 "$RC"
assert_file "...left alone" "$PK/20261018T130000-sid-k.md"
run_wb /dev/null dismiss --task closed--task; assert_eq "dismiss --task without a path: refused" 1 "$RC"
run_wb /dev/null dismiss --task ../x "$PX/20261018T120000-sid-z.md"; assert_eq "bad --task stem refused" 1 "$RC"
assert_file "...nothing deleted" "$PX/20261018T120000-sid-z.md"
run_wb /dev/null accept --task closed--task "$PX/20261018T120000-sid-z.md"
assert_eq "accept --task exit" 0 "$RC"
assert_nofile "accept --task deletes the draft" "$PX/20261018T120000-sid-z.md"
run_wb /dev/null accept --task closed--task "$PX/20261018T100000-sid-x.md"
assert_nofile "accept --task deletes the stale sidecar too" "$PX/20261018T100000-sid-x.md.stale"
assert_eq "accept --task logs shelved_accepted, stale-tagged" "true" "$(jq -r 'select(.event=="shelved_accepted" and .task=="closed--task" and .stale==true)|.stale' "$LOG" | tail -n1)"
assert_eq "accept --task's draft field is the basename" 20261018T100000-sid-x.md "$(jq -r 'select(.event=="shelved_accepted" and .stale==true)|.draft' "$LOG" | tail -n1)"

echo "# path-carrying accept / dismiss work without a session (kill switch, no @task, no tmux, no jq)"
sl_setup() { # fresh scenario with three shelved drafts of closed--task
  new_scenario; D="$(sdir sid-aaa)"; PX="$CAP/shelved/closed--task"; mkdir -p "$D" "$PX"
  printf 'a\n' >"$PX/20261018T100000-sid-a.md"; printf 'b\n' >"$PX/20261018T110000-sid-b.md"
  : >"$PX/20261018T110000-sid-b.md.stale"; printf 'c\n' >"$PX/20261018T120000-sid-c.md"
}
sl_setup; mkdir -p "$STATE/wb"; touch "$STATE/wb/disable-capture"
run_wb /dev/null dismiss --task closed--task "$PX/20261018T100000-sid-a.md"
assert_eq "kill switch: dismiss --task exit" 0 "$RC"
assert_nofile "kill switch: dismiss --task still deletes the draft" "$PX/20261018T100000-sid-a.md"
assert_eq "kill switch: dismiss --task still logs shelved_dismissed" 1 "$(jq -r 'select(.event=="shelved_dismissed")|.event' "$LOG" 2>/dev/null | wc -l | tr -d ' ')"
assert_eq "kill switch: the event has an empty session_id" "" "$(jq -r 'select(.event=="shelved_dismissed")|.session_id' "$LOG")"
assert_eq "kill switch: the event task is the --task stem" closed--task "$(jq -r 'select(.event=="shelved_dismissed")|.task' "$LOG")"
run_wb /dev/null accept --task closed--task "$PX/20261018T120000-sid-c.md"
assert_nofile "kill switch: accept --task deletes the draft" "$PX/20261018T120000-sid-c.md"
assert_eq "kill switch: accept logs shelved_accepted" 1 "$(jq -r 'select(.event=="shelved_accepted")|.event' "$LOG" | wc -l | tr -d ' ')"
run_wb /dev/null mute; assert_eq "kill switch: a bare session verb is still a silent no-op" "0:" "$RC:$OUT"

sl_setup; FAKE_TASK=""
run_wb /dev/null accept --task closed--task "$PX/20261018T100000-sid-a.md"
assert_eq "no @task: accept --task exit" 0 "$RC"
assert_nofile "no @task: accept --task deletes the draft" "$PX/20261018T100000-sid-a.md"
assert_eq "no @task: logged with empty session_id" "" "$(jq -r 'select(.event=="shelved_accepted")|.session_id' "$LOG")"
EXTRA_ENV=(TMUX= TMUX_PANE=)
run_wb /dev/null dismiss --task closed--task "$PX/20261018T120000-sid-c.md"
assert_eq "no tmux at all: dismiss --task exit" 0 "$RC"
assert_nofile "no tmux at all: dismiss --task deletes the draft" "$PX/20261018T120000-sid-c.md"
EXTRA_ENV=()

# no stem anywhere: exit 1 with a message, nothing deleted, nothing logged (never a silent 0)
sl_setup; FAKE_TASK=""
run_wb /dev/null dismiss "$PX/20261018T100000-sid-a.md"
assert_eq "no stem: dismiss <path> exits 1" 1 "$RC"
assert_match "no stem: dismiss says what to pass" 'pass --task <stem>' "$OUT"
assert_file "no stem: dismiss leaves the draft" "$PX/20261018T100000-sid-a.md"
run_wb /dev/null accept "$PX/20261018T100000-sid-a.md"
assert_eq "no stem: accept <path> exits 1" 1 "$RC"
assert_file "no stem: draft untouched" "$PX/20261018T100000-sid-a.md"
assert_eq "no stem: nothing logged" 0 "$(logn)"
sl_setup; mkdir -p "$STATE/wb"; touch "$STATE/wb/disable-capture"; FAKE_TASK=""
run_wb /dev/null dismiss "$PX/20261018T100000-sid-a.md"
assert_eq "kill switch + no stem: still exits 1 (not silent 0)" 1 "$RC"

# the recursion flag still silences it; no jq still does the file op but skips the log
sl_setup; EXTRA_ENV=(WB_CAPTURE_SWEEP=1)
run_wb /dev/null dismiss --task closed--task "$PX/20261018T100000-sid-a.md"
assert_eq "recursion flag: exit 0, no output" "0:" "$RC:$OUT"
assert_file "recursion flag: draft untouched" "$PX/20261018T100000-sid-a.md"
sl_setup; RUN_PATH="$FAKEBIN:$NOJQ_BIN"
run_wb /dev/null dismiss --task closed--task "$PX/20261018T100000-sid-a.md"
assert_eq "no jq: dismiss --task exit" 0 "$RC"
assert_nofile "no jq: the draft is still deleted" "$PX/20261018T100000-sid-a.md"
assert_eq "no jq: the log line is skipped" 0 "$(logn)"
RUN_PATH=""; EXTRA_ENV=()

# with a session and capture enabled the session id is logged
sl_setup
run_wb /dev/null dismiss --task closed--task "$PX/20261018T100000-sid-a.md"
assert_eq "session: the logged event carries the session id" sid-aaa "$(jq -r 'select(.event=="shelved_dismissed")|.session_id' "$LOG")"
# a session whose @task gives the stem needs no --task
sl_setup; FAKE_TASK="$H/tasks/closed--task.md"
run_wb /dev/null dismiss "$PX/20261018T100000-sid-a.md"
assert_eq "stem from @task: dismiss <path> exit" 0 "$RC"
assert_nofile "stem from @task: draft deleted" "$PX/20261018T100000-sid-a.md"

echo "# claim_shelved: a name taken after shelved_dest checked it is never overwritten"
new_scenario
PK="$CAP/shelved/dotfiles--feat-x"; mkdir -p "$PK"
OUT="$(env HOME="$H" XDG_STATE_HOME="$STATE" XDG_CONFIG_HOME="$CFG" PATH="$FAKEBIN:$PATH" \
  PK="$PK" "$REAL_BASH" -c '
  source "$1"; TASK_STEM=dotfiles--feat-x
  # the race: another sweep publishes the name shelved_dest just handed out, before our claim
  real_dest="$(declare -f shelved_dest)"; eval "orig_${real_dest}"
  raced=0
  shelved_dest() { local d; d="$(orig_shelved_dest "$@")" || return 1
    if [ "$raced" = 0 ] && [ ! -e "$PK/.raced" ]; then : >"$PK/.raced"; printf "FIRST\n" >"$d"; fi
    printf "%s\n" "$d"; }
  printf "SECOND\n" >"$PK/src.tmp"
  claim_shelved "$PK/src.tmp" sid-aaa' _ "$SCRIPT" 2>&1)"
RC=$?
assert_eq "claim_shelved: exit 0 after a lost race" 0 "$RC"
first="$(grep -l FIRST "$PK"/*.md 2>/dev/null)"
assert_match "claim_shelved: the other sweep's draft survives" 'sid-aaa\.md$' "$first"
assert_match "claim_shelved: ours took the next name" 'sid-aaa-1\.md$' "$OUT"
assert_eq "claim_shelved: ours holds our text" SECOND "$(cat "$OUT" 2>/dev/null)"
assert_nofile "claim_shelved: source removed" "$PK/src.tmp"

if [ "$fail" -eq 0 ]; then echo "ALL PASSED"; else echo "FAILED"; fi
exit "$fail"
