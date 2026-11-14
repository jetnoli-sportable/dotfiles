#!/usr/bin/env bash
# Tests for wb decide-path, decide-buffer, decide-open and decide-clear
# (wb-decide.sh): the needs-you marker and the nvim split, on a private tmux
# socket with a fake nvim.
#
# tmux safety: every tmux call goes through ONE shim on PATH that fixes the
# socket (-L t under this run's own TMUX_TMPDIR, -f /dev/null); the default
# socket is never touched.
# Run: bash scripts/.config/scripts/tmux/tests/wb-decide-buffer.test.sh
set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WB="$SELF_DIR/wb.sh"

FIX="$(mktemp -d -t wb-decide-buffer-fixture.XXXXXX)"
HOLDER=""
# shellcheck disable=SC2329  # runs from the EXIT trap
cleanup() {
  [ -z "$HOLDER" ] || kill "$HOLDER" 2>/dev/null
  tmux kill-server >/dev/null 2>&1
  rm -rf "$FIX"
}
trap cleanup EXIT

export HOME="$FIX/home" XDG_STATE_HOME="$FIX/state" CODE_DIR="$FIX/code" TASKS_DIR="$FIX/tasks"
export TMUX_TMPDIR="$FIX/tmuxdir"
mkdir -p "$HOME" "$XDG_STATE_HOME" "$CODE_DIR" "$TASKS_DIR" "$TMUX_TMPDIR" "$FIX/bin"
unset TMUX TMUX_PANE

# The one tmux shim: a fixed private socket, no config file.
REAL_TMUX="$(command -v tmux)"
cat > "$FIX/bin/tmux" <<'SHIM'
#!/bin/sh
exec "$REAL_TMUX" -L t -f /dev/null "$@"
SHIM
chmod +x "$FIX/bin/tmux"
export REAL_TMUX

# A fake nvim: records the env it got, then lives for the seconds in
# $FIX/nvim-secs. It never edits the file; the test does. It re-executes as a
# process whose argv[0] is nvim, since tmux names a pane's command from that.
cat > "$FIX/bin/nvim" <<'FAKE'
#!/usr/bin/env bash
printf '%s' "${WB_REVIEW_BUFFER:-}" > "$(dirname "$0")/../env-capture"
exec -a nvim sleep "$(cat "$(dirname "$0")/../nvim-secs")"
FAKE
chmod +x "$FIX/bin/nvim"
export PATH="$FIX/bin:$PATH"
nvim_secs() { echo "$1" > "$FIX/nvim-secs"; }

fail=0
assert() { # <desc> <expected-regex> <actual>
  if printf '%s' "$3" | grep -qE "$2"; then echo "ok   - $1"
  else echo "FAIL - $1"; echo "       expected match: $2"; echo "       got: $(printf '%s' "$3" | head -8)"; fail=1; fi
}
assert_eq() { # <desc> <expected> <actual>
  if [ "$2" = "$3" ]; then echo "ok   - $1"
  else echo "FAIL - $1 (expected '$2', got '$3')"; fail=1; fi
}
wait_until() { # <secs> <cmd…>
  local n=$(( $1 * 10 )); shift
  while [ "$n" -gt 0 ]; do "$@" && return 0; sleep 0.1; n=$((n - 1)); done
  return 1
}
wb() { "$BASH" "$WB" "$@"; }
panes() { tmux list-panes -t "=$1:" | wc -l | tr -d ' '; }
# shellcheck disable=SC2329  # run by wait_until
has_panes() { [ "$(panes "$1")" = "$2" ]; }
panes_in() { tmux list-panes -a -F '#{session_name}/#{window_name}' | grep -cxF "$1/$2"; }
sha() { sha256sum "$1" | awk '{print $1}'; }
mk_task() { # <stem> [layout line]
  printf -- '---\nstatus: doing\n%s\n---\n# %s\n\n## Handoffs\n\n## Decisions\n' "${2:-layout: dossier}" "$1" > "$TASKS_DIR/$1.md"
}

NYDIR="$XDG_STATE_HOME/wb/needs-you"
NY="$NYDIR/proj--dec"
mk_task proj--dec
tmux new-session -d -s proj--dec -x 160 -y 40 "sleep 600"
tmux set-option -t "=proj--dec:" @task "$TASKS_DIR/proj--dec.md" >/dev/null
P="$(tmux list-panes -t "=proj--dec:" -F '#{pane_id}')"

# --- decide-path -------------------------------------------------------------------------
DR="$TASKS_DIR/dossiers/proj--dec/decision-records"
ans="$(TMUX_PANE="$P" wb decide-path)"
assert "decide-path in a dossier task: a fresh stamped file in its decision-records" \
  "^$DR/[0-9]{4}-[0-9]{2}-[0-9]{2}-[0-9]{4}-decide\.md$" "$ans"
assert_eq "the folder is created and the name reserved" yes "$([ -f "$ans" ] && echo yes || echo no)"
ans_b="$(TMUX_PANE="$P" wb decide-path)"
assert_eq "a second call in the same minute gives another name" yes "$([ "$ans" != "$ans_b" ] && echo yes || echo no)"
spec="$(TMUX_PANE="$P" wb decide-path --page 'My page!')"
assert "decide-path --page: <stamp>-<slug>/spec.json" "^$DR/[0-9-]{15}-my-page/spec\.json$" "$spec"
assert_eq "and the page folder exists" yes "$([ -d "${spec%/*}" ] && echo yes || echo no)"
mk_task proj--old "status_note: legacy"
tmux new-session -d -s proj--old "sleep 600"
tmux set-option -t "=proj--old:" @task "$TASKS_DIR/proj--old.md" >/dev/null
O="$(tmux list-panes -t "=proj--old:" -F '#{pane_id}')"
assert "a task not on the dossier layout still gets its dossier folder" \
  "^$TASKS_DIR/dossiers/proj--old/decision-records/[0-9-]{15}-decide\.md$" "$(TMUX_PANE="$O" wb decide-path)"
assert "--task names the task without a pane" "^$DR/" "$(wb decide-path --task proj--dec)"

tmux new-session -d -s plain "sleep 600"
Q="$(tmux list-panes -t "=plain:" -F '#{pane_id}')"
assert "outside a task, in tmux: under the state dir, keyed by the session" \
  "^$XDG_STATE_HOME/wb/decide/plain/[0-9-]{15}-decide\.md$" "$(TMUX_PANE="$Q" wb decide-path)"
out="$(wb decide-path 2>&1)"; code=$?
assert_eq "outside a task and outside tmux it exits 1" 1 "$code"
assert "and says why" 'neither a wb task nor in tmux' "$out"
out="$(TMUX_PANE="$P" wb decide-path --task nope 2>&1)"; code=$?
assert_eq "a --task that names no task exits 1" 1 "$code"
assert "and says so" "no task 'nope'" "$out"

# --- decide-buffer: open, mark, wait ----------------------------------------------------
ans="$FIX/answers-1.md"; echo "Q1: yes or no?" > "$ans"
sha1="$(sha "$ans")"
nvim_secs 3
TMUX_PANE="$P" wb decide-buffer "$ans" > "$FIX/out1" 2>&1 &
w1=$!
wait_until 5 test -s "$NY"
assert_eq "it opens one split in the task's session" 2 "$(panes proj--dec)"
split="$(tmux list-panes -t "=proj--dec:" -F '#{pane_id}' | grep -vxF "$P")"
assert_eq "and marks the task: file, the split's pane, the checksum from before the edit" \
  "buffer $ans $split $sha1" "$(cat "$NY" 2>/dev/null)"
assert_eq "the editor got WB_REVIEW_BUFFER=1" 1 "$(cat "$FIX/env-capture" 2>/dev/null)"
assert_eq "it keeps waiting while the split is open" yes "$(kill -0 "$w1" 2>/dev/null && echo yes || echo no)"
echo "answered" >> "$ans"

# AE1: a re-run on a file whose split is still open waits on that split.
TMUX_PANE="$P" wb decide-buffer "$ans" > "$FIX/out2" 2>&1 &
w2=$!
sleep 1
assert_eq "a re-run opens no second split" 2 "$(panes proj--dec)"
assert_eq "and is still waiting" yes "$(kill -0 "$w2" 2>/dev/null && echo yes || echo no)"
wait "$w1"; c1=$?
wait "$w2"; c2=$?
assert_eq "the first exits 0 once the split closes" 0 "$c1"
assert_eq "and so does the re-run" 0 "$c2"
assert_eq "the first prints the file, its open-time checksum, and that it changed" \
  "file: $ans
sha: $sha1
changed: yes" "$(cat "$FIX/out1")"
assert_eq "the re-run prints the same" "$(cat "$FIX/out1")" "$(cat "$FIX/out2")"
assert_eq "the split is gone" 1 "$(panes proj--dec)"
assert_eq "the marker line stays, with one line for the file" "buffer $ans $split $sha1" "$(cat "$NY")"

# AE6: pane gone and file changed since the first open: nothing opens, the answers are read.
ans2="$FIX/answers-2.md"; echo "Q2: a or b?" > "$ans2"; sha2="$(sha "$ans2")"
nvim_secs 600
TMUX_PANE="$P" wb decide-buffer "$ans2" > "$FIX/out3" 2>&1 &
w3=$!
wait_until 5 grep -q "^buffer $ans2 " "$NY"
split2="$(sed -n "s|^buffer $ans2 \(%[0-9]*\) .*|\1|p" "$NY")"
echo "A" >> "$ans2"
tmux kill-pane -t "$split2"
wait "$w3"
out="$(TMUX_PANE="$P" wb decide-buffer "$ans2" 2>&1)"; code=$?
assert_eq "re-run after the pane is gone and the file changed: exit 0" 0 "$code"
assert_eq "it opens no split" 1 "$(panes proj--dec)"
assert_eq "and prints the file as changed" "file: $ans2
sha: $sha2
changed: yes" "$out"
assert_eq "the marker line keeps its original checksum" "buffer $ans2 $split2 $sha2" "$(grep "^buffer $ans2 " "$NY")"

# A recorded pane that is gone, file unchanged: a fresh split, the first checksum kept.
ans3="$FIX/answers-3.md"; echo "Q3: ok?" > "$ans3"; sha3="$(sha "$ans3")"
TMUX_PANE="$P" wb decide-buffer "$ans3" > /dev/null 2>&1 &
w4=$!
wait_until 5 grep -q "^buffer $ans3 " "$NY"
split3="$(sed -n "s|^buffer $ans3 \(%[0-9]*\) .*|\1|p" "$NY")"
tmux kill-pane -t "$split3"
wait "$w4"
nvim_secs 3
TMUX_PANE="$P" wb decide-buffer "$ans3" > "$FIX/out5" 2>&1 &
w5=$!
wait_until 5 has_panes proj--dec 2
assert_eq "pane gone, file unchanged: the re-run opens a split" 2 "$(panes proj--dec)"
new3="$(sed -n "s|^buffer $ans3 \(%[0-9]*\) .*|\1|p" "$NY")"
assert_eq "the marker has the new pane" yes "$([ -n "$new3" ] && [ "$new3" != "$split3" ] && echo yes || echo no)"
assert_eq "and still the first checksum, on a single line" "1 $sha3" \
  "$(grep -c "^buffer $ans3 " "$NY") $(sed -n "s|^buffer $ans3 %[0-9]* ||p" "$NY")"
wait "$w5"
assert "that run reports the file unchanged" 'changed: no' "$(cat "$FIX/out5")"

# A recorded pane that now runs something else (the base pane runs sleep): same, a fresh split.
printf 'buffer %s %s %s\n' "$ans3" "$P" "$sha3" > "$NY"
TMUX_PANE="$P" wb decide-buffer "$ans3" > /dev/null 2>&1 &
w6=$!
wait_until 5 has_panes proj--dec 2
assert_eq "a recorded pane not running nvim is not waited on: a fresh split opens" 2 "$(panes proj--dec)"
assert_eq "its line has the new pane and the first checksum" "yes $sha3" \
  "$([ "$(sed -n "s|^buffer $ans3 \(%[0-9]*\) .*|\1|p" "$NY")" != "$P" ] && echo yes || echo no) $(sed -n "s|^buffer $ans3 %[0-9]* ||p" "$NY")"
wait "$w6"
rm -f "$NY"

# --- decide-open and decide-clear --------------------------------------------------------
printf 'buffer %s %%99 %s\n' "$ans" "$sha1" > "$NY"
TMUX_PANE="$P" wb decide-open page https://example.test/artifact/x r1
assert_eq "decide-open adds a page line" "buffer $ans %99 $sha1
page https://example.test/artifact/x r1" "$(cat "$NY")"
TMUX_PANE="$P" wb decide-open page https://example.test/artifact/x r2
assert_eq "a later rev of the same url replaces its line" "buffer $ans %99 $sha1
page https://example.test/artifact/x r2" "$(cat "$NY")"
TMUX_PANE="$P" wb decide-clear "$ans"
assert_eq "decide-clear <file> drops only that line" "page https://example.test/artifact/x r2" "$(cat "$NY")"
TMUX_PANE="$P" wb decide-clear https://example.test/artifact/x
assert_eq "clearing the last line removes the marker" no "$([ -e "$NY" ] && echo yes || echo no)"
TMUX_PANE="$P" wb decide-open page https://example.test/artifact/y r1
wb decide-open page https://example.test/artifact/z r1 --task proj--dec
assert_eq "--task works without a pane" 2 "$(wc -l < "$NY" | tr -d ' ')"
TMUX_PANE="$P" wb decide-clear --all
assert_eq "decide-clear --all removes the marker" no "$([ -e "$NY" ] && echo yes || echo no)"
out="$(TMUX_PANE="$Q" wb decide-open page https://example.test/artifact/plain r1; cat "$NYDIR/plain")"
assert_eq "outside a task the marker is keyed by the session name" "page https://example.test/artifact/plain r1" "$out"
TMUX_PANE="$Q" wb decide-clear --all

# --- the marker's own lock ---------------------------------------------------------------
mkdir -p "$XDG_STATE_HOME/wb/locks"
LF="$XDG_STATE_HOME/wb/locks/needs-you-proj--dec.lock"
( exec 9>>"$LF"; flock 9; exec sleep 60 ) &
HOLDER=$!
sleep 0.5
TMUX_PANE="$P" wb decide-open page https://example.test/artifact/held r1 >/dev/null 2>&1; code=$?
assert_eq "a held marker lock makes decide-open exit 75" 75 "$code"
assert_eq "writing nothing" no "$([ -e "$NY" ] && echo yes || echo no)"
TMUX_PANE="$P" wb decide-buffer "$ans" >/dev/null 2>&1; code=$?
assert_eq "and decide-buffer exit 75" 75 "$code"
assert_eq "before opening a split" 1 "$(panes proj--dec)"
assert_eq "and writing nothing" no "$([ -e "$NY" ] && echo yes || echo no)"
kill "$HOLDER" 2>/dev/null; wait "$HOLDER" 2>/dev/null; HOLDER=""

# --- a split that can't open marks nothing -----------------------------------------------
mk_task proj--tiny
tmux new-session -d -s proj--tiny -x 2 -y 2 "sleep 600"
tmux set-option -t "=proj--tiny:" @task "$TASKS_DIR/proj--tiny.md" >/dev/null
R="$(tmux list-panes -t "=proj--tiny:" -F '#{pane_id}')"
out="$(TMUX_PANE="$R" wb decide-buffer "$ans" 2>&1)"; code=$?
assert_eq "a split that can't open: exit 1" 1 "$code"
assert "and says so" "couldn't open the split" "$out"
assert_eq "leaving the task not needing Jet" no "$([ -e "$NYDIR/proj--tiny" ] && echo yes || echo no)"

# --- no caller pane: the agent window, found by exact name --------------------------------
mk_task proj--win
tmux new-session -d -s proj--win -x 160 -y 40 -n nvim "sleep 600"
tmux new-window -d -t "=proj--win:" -n agent "sleep 600"
tmux set-option -w -t "=proj--win:agent" remain-on-exit on
tmux set-option -t "=proj--win:" @task "$TASKS_DIR/proj--win.md" >/dev/null
nvim_secs 2
wb decide-buffer "$ans" --task proj--win > "$FIX/out7" 2>&1 &
w7=$!
wait_until 5 test -s "$NYDIR/proj--win"
assert_eq "with an agent window, the split opens there" 2 "$(panes_in proj--win agent)"
assert_eq "and not in the session's other window" 1 "$(panes_in proj--win nvim)"
# The agent window has remain-on-exit on; a split that inherited it never
# closes, so this fails rather than hanging the run.
wait_until 8 sh -c "! kill -0 $w7 2>/dev/null" || { kill "$w7" 2>/dev/null; echo "FAIL - decide-buffer never returned"; fail=1; }
wait "$w7"; code=$?
assert_eq "it exits 0 once nvim closes" 0 "$code"
assert_eq "the split is gone, not left as a dead pane" 1 "$(panes_in proj--win agent)"
assert_eq "and the agent's own window still stays on exit" on "$(tmux show-options -w -v -t "=proj--win:agent" remain-on-exit)"

mk_task proj--noagent
tmux new-session -d -s proj--noagent -x 160 -y 40 -n main "sleep 600"
tmux new-window -d -t "=proj--noagent:" -n agent-logs "sleep 600"
tmux set-option -t "=proj--noagent:" @task "$TASKS_DIR/proj--noagent.md" >/dev/null
wb decide-buffer "$ans" --task proj--noagent > /dev/null 2>&1 &
w8=$!
wait_until 5 test -s "$NYDIR/proj--noagent"
assert_eq "with no agent window, the split opens in the current window" 2 "$(panes_in proj--noagent main)"
assert_eq "and a window whose name only starts with agent doesn't count" 1 "$(panes_in proj--noagent agent-logs)"
wait "$w8"

# --- wb help -----------------------------------------------------------------------------
help="$(wb help)"
for v in decide-path decide-buffer decide-open decide-clear; do
  assert "wb help lists $v" "^  wb $v( |\$)" "$help"
done

if [ "$fail" = 0 ]; then echo "ALL PASS"; else echo "FAILURES"; fi
exit "$fail"
