#!/usr/bin/env bash
# Behavioral tests for `wb restart` (cmd_restart, U4): restore a set of wb
# sessions from a list file or from the store (--crashed), pre-typing
# `claude "/wb-resume"` in each agent window without Enter. Real tmux on a
# private -L socket (never the default socket); `wb resume` itself is replaced
# by a fake script (SELF) that makes a session the way resume would, so these
# tests cover restart's own loop, not worktree creation. The exact-stem
# resolver change is checked against the real cmd_resume with cmd_new stubbed.
#
# Run: bash scripts/.config/scripts/tmux/tests/wb-restart.test.sh
set -uo pipefail

WB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WB="$WB_DIR/wb.sh"
FIXTURE_CODE="$(mktemp -d -t wb-rs-code.XXXXXX)"
FIXTURE_TASKS="$(mktemp -d -t wb-rs-tasks.XXXXXX)"
FIXTURE_BIN="$(mktemp -d -t wb-rs-bin.XXXXXX)"
TMUX_LOG="$FIXTURE_BIN/tmux.log"
SOCK="wb-rs-sock-$$"
REAL_TMUX="$(command -v tmux)"

cat > "$FIXTURE_BIN/tmux" <<EOF2
#!/usr/bin/env bash
echo "\$*" >> "$TMUX_LOG"
exec "$REAL_TMUX" -L "$SOCK" "\$@"
EOF2
chmod +x "$FIXTURE_BIN/tmux"
PATH="$FIXTURE_BIN:$PATH"

# Fake `wb resume <stem>`: *--bad-* fails, *--slow-* leaves a non-shell in the
# agent window, anything else gets a shell window with a pre-typed warm resume.
# The session is named the way cmd_new names it: <repo>--<worktree: slug>.
cat > "$FIXTURE_BIN/fake-wb.sh" <<'EOF2'
#!/usr/bin/env bash
[ "$1" = resume ] || exit 2
s="$2"
wt="$(awk -F': *' '/^worktree:/ { print $2; exit }' "$TASKS_DIR/$2.md" 2>/dev/null)"
[ -z "$wt" ] || s="${2%%--*}--$(printf '%s' "${wt#.worktrees/}" | tr '/' '-')"
case "$2" in
  *--bad-*) exit 1 ;;
  *--slow-*) tmux new-session -d -s "$s" -n agent 'sleep 300' ;;
  *) tmux new-session -d -s "$s" -n agent
     sleep 0.5   # let the shell draw its prompt first, as wb's layout does by the time restart types
     tmux send-keys -t "=$s:agent" 'claude --resume old-id' ;;
esac
# wb resume focuses the session it made
tmux switch-client -t "=$s" 2>/dev/null || true
EOF2

cleanup() {
  "$REAL_TMUX" -L "$SOCK" kill-server 2>/dev/null || true
  rm -rf "${FIXTURE_CODE:?}" "${FIXTURE_TASKS:?}" "${FIXTURE_BIN:?}"
}
trap cleanup EXIT

fail=0
assert() { # <desc> <expected-regex> <actual>
  if printf '%s' "$3" | /usr/bin/grep -qE "$2"; then
    echo "ok   - $1"
  else
    echo "FAIL - $1"
    echo "       expected match: $2"
    echo "       got: $(printf '%s' "$3" | head -8)"
    fail=1
  fi
}
refute() { # <desc> <regex that must NOT match> <actual>
  if printf '%s' "$3" | /usr/bin/grep -qE "$2"; then
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

export CODE_DIR="$FIXTURE_CODE"
export TASKS_DIR="$FIXTURE_TASKS"
export WB_RESTART_PROMPT_TIMEOUT=2

# shellcheck disable=SC1090
source "$WB"
set +e
SELF="$FIXTURE_BIN/fake-wb.sh"

task() { # <stem> <status> [<worktree-exists:1|0>]
  local stem="$1" status="$2" wt="${3:-1}" slug="${1#*--}"
  printf -- '---\nstatus: %s\nrepo: proj\nbranch: %s\nworktree: .worktrees/%s\ntags: []\ncreated: 2026-10-01\nclosed:\n---\n# %s\n\n## Plan\n' \
    "$status" "$slug" "$slug" "$stem" > "$FIXTURE_TASKS/$stem.md"
  [ "$wt" = 0 ] || mkdir -p "$FIXTURE_CODE/proj/.worktrees/$slug"
}
has() { tmux has-session -t "=$1" 2>/dev/null; }
pane() { tmux capture-pane -pJ -t "=$1:agent" 2>/dev/null; }   # -J: a long host prompt wraps the 80-column pane
sw_last() { /usr/bin/grep '^switch-client' "$TMUX_LOG" | tail -1; }

tmux new-session -d -s start
# readline shells (C-u clears the line, as in the real zsh/bash agent windows)
tmux set-option -g default-shell /bin/bash
TMUX="$(tmux display-message -p '#{socket_path},#{pid},0')"; export TMUX
# no client is attached here: pin "the current session" to `start` via its pane
TMUX_PANE="$(tmux display-message -p -t =start: '#{pane_id}')"; export TMUX_PANE

# --- list file: two valid stems, comments and blanks ignored ------------------
task proj--one doing; task proj--two doing
LIST="$FIXTURE_BIN/list1"
printf '# restart these\nproj--one\n\n  proj--two   # trailing\n' > "$LIST"
: > "$TMUX_LOG"
out="$(cmd_restart "$LIST" 2>&1)"; rc=$?
assert_eq "list: exit 0" 0 "$rc"
has proj--one && has proj--two && echo "ok   - list: both sessions exist" || { echo "FAIL - list: both sessions exist"; fail=1; }
assert "list: one pre-typed" 'claude "/wb-resume"' "$(pane proj--one)"
refute "list: warm resume command cleared" 'old-id' "$(pane proj--one)"
assert "list: two pre-typed" 'claude "/wb-resume"' "$(pane proj--two)"
refute "list: no Enter sent" 'send-keys .*Enter' "$(cat "$TMUX_LOG")"
assert "list: summary" '2 ok, 0 skipped, 0 failed' "$out"
assert_eq "list: client returned to the starting session" "switch-client -t =start" "$(sw_last)"

# --- skips and failures --------------------------------------------------------
task proj--live doing; task proj--bad-one doing; task proj--good doing
tmux new-session -d -s proj--live
LIST2="$FIXTURE_BIN/list2"
printf 'proj--ghost\nproj--on\nproj--live\nproj--bad-one\nproj--good\n' > "$LIST2"
out="$(cmd_restart "$LIST2" 2>&1)"; rc=$?
assert "missing: skipped with a reason" 'SKIP  proj--ghost: no task file' "$out"
assert "substring of a stem: skipped as missing, not resolved fuzzily" 'SKIP  proj--on: no task file' "$out"
assert "live: skipped" 'SKIP  proj--live: session proj--live still open' "$out"
assert "failed resume: reported" 'FAIL  proj--bad-one: wb resume failed' "$out"
assert "later entry still runs after a failure" 'OK    proj--good' "$out"
assert "summary counts" '1 ok, 3 skipped, 1 failed' "$out"
assert_eq "exit status reflects the failure only" 1 "$rc"
assert_eq "client returned to the starting session after failures" "switch-client -t =start" "$(sw_last)"

# --- dry run ---------------------------------------------------------------
task proj--dry doing
printf 'proj--dry\n' > "$FIXTURE_BIN/list3"
out="$(cmd_restart --dry-run "$FIXTURE_BIN/list3" 2>&1)"; rc=$?
assert "dry-run: prints the plan" 'WOULD proj--dry: wb resume, then pre-type: claude "/wb-resume"' "$out"
assert "dry-run: says nothing was done" 'dry run, nothing done' "$out"
has proj--dry && { echo "FAIL - dry-run: created a session"; fail=1; } || echo "ok   - dry-run: no session created"

# --- outside tmux ------------------------------------------------------------
out="$(TMUX= cmd_restart "$FIXTURE_BIN/list3" 2>&1)"; rc=$?
assert "outside tmux: refuses" 'run this from inside tmux' "$out"
assert_eq "outside tmux: exit 2" 2 "$rc"
has proj--dry && { echo "FAIL - outside tmux: created a session"; fail=1; } || echo "ok   - outside tmux: no session created"
out="$(TMUX= cmd_restart --dry-run "$FIXTURE_BIN/list3" 2>&1)"
assert "outside tmux: --dry-run still works" 'WOULD proj--dry' "$out"

# --- prompt never appears -------------------------------------------------------
task proj--slow-start doing
printf 'proj--slow-start\n' > "$FIXTURE_BIN/list4"
out="$(cmd_restart "$FIXTURE_BIN/list4" 2>&1)"
assert "no shell in time: command printed for Jet" 'WARN  proj--slow-start: .*nothing typed\. Type this there: claude "/wb-resume"' "$out"
refute "no shell in time: nothing typed into the window" 'wb-resume' "$(pane proj--slow-start)"

# --- --crashed: which tasks are listed -------------------------------------------
rm -f "${FIXTURE_TASKS:?}"/*.md
task proj--c-resumed doing;  wb_append_handoff "$FIXTURE_TASKS/proj--c-resumed.md" "wb resume" 'Session resumed via `wb resume`.'
task proj--c-closed doing;   wb_append_handoff "$FIXTURE_TASKS/proj--c-closed.md" "wb down" 'Session closed via `wb down` — worktree kept.'
task proj--c-keep doing;     wb_append_handoff "$FIXTURE_TASKS/proj--c-keep.md" "wb down" 'Worktree kept, session left open (`wb down --keep-session`).'
task proj--c-review review;  wb_append_handoff "$FIXTURE_TASKS/proj--c-review.md" "wb resume" 'Session resumed via `wb resume`.'
task proj--c-paused paused;  wb_append_handoff "$FIXTURE_TASKS/proj--c-paused.md" "wb resume" 'Session resumed via `wb resume`.'
task proj--c-nowt doing 0;   wb_append_handoff "$FIXTURE_TASKS/proj--c-nowt.md" "wb resume" 'Session resumed via `wb resume`.'
task proj--c-live doing;     wb_append_handoff "$FIXTURE_TASKS/proj--c-live.md" "wb resume" 'Session resumed via `wb resume`.'
tmux new-session -d -s proj--c-live
# closed by wb down, then resumed: the newest handoff is the resume, so it is listed
task proj--c-reclosed doing
wb_append_handoff "$FIXTURE_TASKS/proj--c-reclosed.md" "wb down" 'Session closed via `wb down` — worktree kept.'
wb_append_handoff "$FIXTURE_TASKS/proj--c-reclosed.md" "wb resume" 'Session resumed via `wb resume`.'
# no handoff at all: listed (nothing says it was closed on purpose)
task proj--c-nohand doing
out="$(cmd_restart --dry-run --crashed 2>&1)"
for s in c-resumed c-keep c-review c-reclosed c-nohand; do
  assert "crashed: lists $s" "WOULD proj--$s:" "$out"
done
for s in c-closed c-paused c-nowt c-live; do
  refute "crashed: does not list $s" "proj--$s" "$out"
done
# a closing wb down whose file in handoffs/ is newer than the task file's entry
task proj--c-moved doing
wb_append_handoff "$FIXTURE_TASKS/proj--c-moved.md" "wb resume" 'Session resumed via `wb resume`.'
D="$FIXTURE_TASKS/dossiers/proj--c-moved"
mkdir -p "$D/handoffs"
printf -- '---\nsource: wb down\nauto: true\n---\n### 2099-01-01 00:00 — wb down (auto)\n\nSession closed via `wb down` — worktree kept.\n' > "$D/handoffs/2099-01-01-0000.md"
out="$(cmd_restart --dry-run --crashed 2>&1)"
refute "crashed: newer closing wb down in handoffs/ excludes the task" 'proj--c-moved' "$out"
rm -rf "${D:?}/handoffs"

# --- --crashed with a terminal and answer n: nothing launched ------------------------
before="$(tmux list-sessions -F '#S' | sort | tr '\n' ' ')"
out="$( (sleep 1; echo n) | script -qec "bash '$WB' restart --crashed" /dev/null 2>&1 )"
assert "crashed + terminal: asks first" 'Restart these [0-9]+ session\(s\)\? \[y/N\]' "$out"
assert "crashed + terminal: n launches nothing" 'nothing launched' "$out"
assert_eq "crashed + terminal: no new sessions" "$before" "$(tmux list-sessions -F '#S' | sort | tr '\n' ' ')"

# --- a continuing child: its session is named after the worktree it inherited ------
# wb breakdown moves the parent's branch: and worktree: onto the child, so the
# child's session is proj--mom, not proj--kid, and the parent is left with no
# branch: (nothing to resume; its old worktree now belongs to the child).
rm -f "${FIXTURE_TASKS:?}"/*.md
mkdir -p "$FIXTURE_CODE/proj/.worktrees/mom"
printf -- '---\nstatus: doing\nrepo: proj\nbranch: mom\nworktree: .worktrees/mom\ntags: []\ncreated: 2026-10-01\nclosed:\n---\n# kid\n' > "$FIXTURE_TASKS/proj--kid.md"
printf -- '---\nstatus: doing\nrepo: proj\nbranch:\nworktree:\ntags: []\ncreated: 2026-10-01\nclosed:\n---\n# mom\n' > "$FIXTURE_TASKS/proj--mom.md"
assert_eq "child: session name comes from worktree:" "proj--mom" "$(_wb_task_session "$FIXTURE_TASKS/proj--kid.md")"
out="$(cmd_restart --dry-run --crashed 2>&1)"
assert "child: listed as crashed while proj--mom is gone" 'WOULD proj--kid:' "$out"
refute "child: parent with no branch: is not listed" 'proj--mom:' "$out"
tmux new-session -d -s proj--mom
out="$(cmd_restart --dry-run --crashed 2>&1)"
refute "child: not listed while its session proj--mom is live" 'proj--kid' "$out"
printf 'proj--kid\n' > "$FIXTURE_BIN/list5"
out="$(cmd_restart "$FIXTURE_BIN/list5" 2>&1)"
assert "child: list entry skipped while proj--mom is live" 'SKIP  proj--kid: session proj--mom still open' "$out"
tmux kill-session -t =proj--mom
out="$(cmd_restart "$FIXTURE_BIN/list5" 2>&1)"; rc=$?
assert "child: restored and pre-typed" 'OK    proj--kid' "$out"
assert_eq "child: exit 0" 0 "$rc"
assert "child: proj--mom's agent window holds the command" 'claude "/wb-resume"' "$(pane proj--mom)"

# --- exact stem resolution in the real cmd_resume -----------------------------------------
NEWCALL="$FIXTURE_BIN/newcall"
cmd_new() { printf '%s' "$*" > "$NEWCALL"; }
rm -f "${FIXTURE_TASKS:?}"/*.md
printf -- '---\nstatus: doing\nrepo: proj\nbranch: feat/parent\nworktree: .worktrees/x\ntags: []\ncreated: 2026-07-07\nclosed:\n---\n# P\n' > "$FIXTURE_TASKS/proj--feat-parent.md"
printf -- '---\nstatus: doing\nrepo: proj\nbranch: feat/parent-child\nworktree: .worktrees/y\ntags: []\ncreated: 2026-07-07\nclosed:\n---\n# C\n' > "$FIXTURE_TASKS/proj--feat-parent-child.md"
out="$(cmd_resume proj--feat-parent 2>&1)"; rc=$?
assert_eq "resume: exact stem that prefixes another stem exits 0" 0 "$rc"
assert_eq "resume: exact stem resumes the parent, not an ambiguity" "proj feat/parent" "$(cat "$NEWCALL")"
out="$(cmd_resume feat-par 2>&1)"; rc=$?
assert "resume: a partial query matching both is still ambiguous" "matches 2 tasks" "$out"

[ "$fail" -eq 0 ] && echo "ALL PASS" || echo "FAILURES"
