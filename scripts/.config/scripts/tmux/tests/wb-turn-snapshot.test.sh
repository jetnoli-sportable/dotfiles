#!/usr/bin/env bash
# shellcheck disable=SC2016,SC2329,SC2015 # literal fixtures; trap, ok/bad helpers
# Tests for wb-turn-snapshot.sh, the
# prompt and stop hooks that write refs/worktree/wb/turn-start and /turn in a
# linked worktree. Real git in a temp repo with a linked worktree; a PATH shim
# for git injects slow or failing steps. The single-worktree tests set TMUX_PANE
# only so the guard passes; the multi-worktree ones use real tmux on ONE fixed
# private -L socket with -f /dev/null, so the pane carries the @task option.
# Run: bash scripts/.config/scripts/tmux/tests/wb-turn-snapshot.test.sh
# HOOK overrides the script under test.
set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HOOK="${HOOK:-$SELF_DIR/wb-turn-snapshot.sh}"
FIX="$(mktemp -d -t wb-turn-snapshot.XXXXXX)"
REAL_GIT="$(command -v git)"
REAL_TMUX="$(command -v tmux)"
export WBTS_SOCK="wb-turn-snapshot-test-sock" WBTS_REAL_TMUX="$REAL_TMUX"

export HOME="$FIX/home" XDG_STATE_HOME="$FIX/state" LANG=C.UTF-8 LC_ALL=C.UTF-8
export GIT_CONFIG_GLOBAL="$FIX/gitconfig" GIT_CONFIG_NOSYSTEM=1
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
mkdir -p "$HOME" "$XDG_STATE_HOME/wb" "$FIX/bin"
: >"$GIT_CONFIG_GLOBAL"
unset CLAUDE_CODE_ENTRYPOINT CLAUDE_CODE_SESSION_ATTENDED
export TMUX_PANE=%1

cleanup() {
  "$REAL_TMUX" -L "$WBTS_SOCK" kill-server 2>/dev/null || true
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

# git shim: fault injection through files in $FIX. It logs nothing; each file
# switches one behaviour for the git subcommand named in it.
#   failadd      `add` exits 1
#   hangadd      `add` hangs (when the file holds text, only for git calls whose
#                arguments contain it, e.g. one worktree's path)
#   slowtree     `write-tree` prints its tree, touches $FIX/treedone, then sleeps
cat >"$FIX/bin/git" <<EOF2
#!/usr/bin/env bash
case " \$* " in
  *" add "*)
    [ -e "$FIX/failadd" ] && exit 1
    if [ -e "$FIX/hangadd" ]; then
      pat="\$(cat "$FIX/hangadd")"
      [[ -z "\$pat" || "\$*" == *"\$pat"* ]] && exec sleep 30
    fi ;;
  *" write-tree "*)
    if [ -e "$FIX/slowtree" ]; then
      out="\$("$REAL_GIT" "\$@")"; echo "\$out"
      touch "$FIX/treedone"; sleep 1.5; exit 0
    fi ;;
esac
exec "$REAL_GIT" "\$@"
EOF2
chmod +x "$FIX/bin/git"
# tmux shim: the one private socket, no config. A quoted heredoc, so nothing
# expands here (a per-exec socket once forked ~1500 servers).
cat >"$FIX/bin/tmux" <<'EOF2'
#!/usr/bin/env bash
exec "$WBTS_REAL_TMUX" -u -L "$WBTS_SOCK" -f /dev/null "$@"
EOF2
chmod +x "$FIX/bin/tmux"
PATH="$FIX/bin:$PATH"
export PATH

MAIN="$FIX/main" WT="$FIX/wt"
git init -q -b main "$MAIN"
(cd "$MAIN" && echo base >a.txt && echo notes >notes.md && echo '*.log' >.gitignore && git add -A && git commit -qm init \
  && git worktree add -q -b feat "$WT")
GD="$(cd "$WT" && git rev-parse --absolute-git-dir)"

wt() { (cd "$WT" && "$@"); }
hook() { # hook <verb> [stdin] — run in the worktree
  local in="${2:-}"
  (cd "$WT" && printf '%s' "$in" | "$HOOK" "$1")
}
idle() { flock -w 10 "$GD/wb-turn.lock" true; } # the detached prompt holds the lock
ref() { git -C "$WT" rev-parse -q --verify "refs/worktree/wb/$1" 2>/dev/null; }
turn_files() { git -C "$WT" diff --name-only "refs/worktree/wb/turn^" "refs/worktree/wb/turn" 2>/dev/null | tr '\n' ' '; }
stop_in() { printf '{"last_assistant_message":"%s\\nsecond line","stop_hook_active":false}' "$1"; }

# --- AE8: editor change before the prompt stays out of the turn ----------------
echo "editor edit" >"$WT/notes.md"
hook prompt; idle
[ -n "$(ref turn-start)" ] && ok "prompt writes turn-start" || bad "prompt writes turn-start"
assert_eq "turn-start is parentless" 1 "$(git -C "$WT" rev-list --parents -n1 "$(ref turn-start)" | wc -w | tr -d ' ')"
echo "agent edit" >"$WT/x.go"
out="$(hook stop "$(stop_in 'Done: x.go edited')")"
assert_eq "stop prints nothing" "" "$out"
assert_eq "AE8: turn diff holds only the agent's edit" "x.go " "$(turn_files)"
msg="$(git -C "$WT" log -1 --format=%B "$(ref turn)")"
assert_has "message names the reply's first line" "reply Done: x.go edited" "$msg"
assert_has "message names HEAD" "head $(git -C "$WT" rev-parse HEAD)" "$msg"
/usr/bin/grep -q interrupted <<<"$msg" && bad "normal turn is not marked interrupted" || ok "normal turn is not marked interrupted"
assert_eq "stop moved turn-start to the new tree" "$(git -C "$WT" rev-parse "$(ref turn)^{tree}")" "$(git -C "$WT" rev-parse "$(ref turn-start)^{tree}")"
[ ! -e "$GD/wb-turn-open" ] && ok "stop clears the open-turn marker" || bad "stop clears the open-turn marker"

# --- AE9: unchanged tree leaves turn, still moves turn-start --------------------
T1="$(ref turn)"
hook stop "$(stop_in nothing)"
assert_eq "AE9: unchanged stop leaves turn" "$T1" "$(ref turn)"
assert_eq "AE9: turn-start sits on the current tree" "$(git -C "$WT" rev-parse "$(ref turn-start)^{tree}")" "$(cd "$WT" && GIT_INDEX_FILE="$GD/wb-turn-index" git write-tree)"

# --- second stop (review-block continuation) ------------------------------------
echo "review fix" >"$WT/y.go"
hook stop "$(stop_in 'Fixed y.go')"
assert_eq "continuation stop records only the response to the review" "y.go " "$(turn_files)"

# --- Esc: prompt, edit, no stop, prompt again -----------------------------------
hook prompt; idle
echo "interrupted edit" >"$WT/z.go"
hook prompt; idle
assert_eq "interrupted turn holds the edit" "z.go " "$(turn_files)"
assert_has "interrupted turn is marked" "wb turn (interrupted)" "$(git -C "$WT" log -1 --format=%B "$(ref turn)")"
assert_eq "new turn-start is the current tree" "$(git -C "$WT" rev-parse "$(ref turn-start)^{tree}")" \
  "$(cd "$WT" && GIT_INDEX_FILE="$GD/wb-turn-index" git write-tree)"
[ -e "$GD/wb-turn-open" ] && ok "second prompt reopens the turn" || bad "second prompt reopens the turn"
hook stop ""

# --- Esc during a review-block continuation --------------------------------------
# The review hook's Stop block writes queue/inflight naming the pane and starts a
# turn no prompt announces; an Esc then means no Stop clears it.
inflight() { # inflight <pane> <age-seconds>
  mkdir -p "$XDG_STATE_HOME/wb/review/tk/queue"
  printf '%s %s\n' "$1" "$((EPOCHSECONDS - $2))" >"$XDG_STATE_HOME/wb/review/tk/queue/inflight"
}
hook prompt; idle
echo "before the review" >"$WT/r1.go"
hook stop "$(stop_in 'Built r1')"
inflight "$TMUX_PANE" 5
echo "review edit" >"$WT/r2.go"
hook prompt; idle
assert_eq "Esc during a review turn: the turn holds the review's edit" "r2.go " "$(turn_files)"
assert_has "Esc during a review turn: marked interrupted" "wb turn (interrupted)" "$(git -C "$WT" log -1 --format=%B "$(ref turn)")"
hook stop ""
for case in "other pane:%9 5" "stale marker:$TMUX_PANE 7200"; do
  hook prompt; idle; hook stop ""
  T0="$(ref turn)"
  read -r p age <<<"${case#*:}"
  inflight "$p" "$age"
  echo "jet's edit, ${case%%:*}" >"$WT/jet.md"
  hook prompt; idle
  assert_eq "inflight on ${case%%:*}: Jet's edit before the prompt is no turn" "$T0" "$(ref turn)"
  hook stop ""
done
rm -rf "$XDG_STATE_HOME/wb/review"

# --- untracked vs ignored --------------------------------------------------------
hook prompt; idle
echo u >"$WT/untracked.txt"; echo l >"$WT/debug.log"
hook stop "$(stop_in x)"
files="$(turn_files)"
assert_has "untracked, non-ignored file is in the snapshot" "untracked.txt" "$files"
[[ "$files" == *debug.log* ]] && bad "ignored file stays out" || ok "ignored file stays out"

# --- real index and HEAD unchanged -----------------------------------------------
wt git add -A
before_idx="$(git -C "$WT" ls-files -s | sha1sum)" before_head="$(git -C "$WT" rev-parse HEAD)"
echo w >"$WT/w.txt"
hook prompt; idle; echo more >>"$WT/w.txt"; hook stop "$(stop_in x)"
assert_eq "real index unchanged" "$before_idx" "$(git -C "$WT" ls-files -s | sha1sum)"
assert_eq "HEAD unchanged" "$before_head" "$(git -C "$WT" rev-parse HEAD)"

# --- stop with no turn-start writes only turn-start -----------------------------
git -C "$WT" update-ref -d refs/worktree/wb/turn-start
git -C "$WT" update-ref -d refs/worktree/wb/turn
echo q >"$WT/q.txt"
hook stop "$(stop_in x)"
[ -n "$(ref turn-start)" ] && [ -z "$(ref turn)" ] && ok "stop without turn-start writes only turn-start" \
  || bad "stop without turn-start writes only turn-start"

# --- hook returns before the detached child finishes -----------------------------
touch "$FIX/slowtree"; rm -f "$FIX/treedone"
S0="$(ref turn-start)"
echo "editor save" >"$WT/e.txt"
start=$(date +%s%N)
hook prompt
ms=$((($(date +%s%N) - start) / 1000000))
[ "$ms" -lt 1000 ] && ok "prompt returns before the detached child finishes (${ms} ms)" || bad "prompt returns before the child finishes" "${ms} ms"
# --- a stop during a running prompt waits for it --------------------------------
for _ in $(seq 1 100); do [ -e "$FIX/treedone" ] && break; sleep 0.1; done
echo "agent edit during" >"$WT/during.go"
rm -f "$FIX/slowtree"
hook stop "$(stop_in 'waited')"
assert_eq "stop waited for prompt: editor save stays out, agent edit in" "during.go " "$(turn_files)"
[ "$(ref turn-start)" != "$S0" ] && ok "turn-start was written by the prompt child" || bad "turn-start was written by the prompt child"

# --- git failure or timeout leaves the refs as they were --------------------------
T0="$(ref turn)" S0="$(ref turn-start)"
echo f >"$WT/f.txt"
touch "$FIX/failadd"
hook stop "$(stop_in x)"; rc=$?
assert_eq "failing git step: exit 0" 0 "$rc"
assert_eq "failing git step: turn unchanged" "$T0" "$(ref turn)"
assert_eq "failing git step: turn-start unchanged" "$S0" "$(ref turn-start)"
rm -f "$FIX/failadd"; touch "$FIX/hangadd"
start=$(date +%s)
WB_TURN_GIT_TIMEOUT=1 hook stop "$(stop_in x)"; rc=$?
secs=$(($(date +%s) - start))
assert_eq "timed-out git step: exit 0" 0 "$rc"
[ "$secs" -le 4 ] && ok "timed-out git step is cut off (${secs}s)" || bad "timed-out git step is cut off" "${secs}s"
assert_eq "timed-out git step: turn unchanged" "$T0" "$(ref turn)"
assert_eq "timed-out git step: turn-start unchanged" "$S0" "$(ref turn-start)"
rm -f "$FIX/hangadd"

# --- several worktrees: the task's primary and extras (R12, KTD9) ----------------
# Repos live under $CODE_DIR; the pane's @task names a task file listing them.
export CODE_DIR="$FIX/code"
mkrepo() { # mkrepo <name> — repo $CODE_DIR/<name> with a linked worktree .worktrees/feat
  git init -q -b main "$CODE_DIR/$1"
  (cd "$CODE_DIR/$1" && echo base >a.txt && git add -A && git commit -qm init \
    && git worktree add -q -b feat "$CODE_DIR/$1/.worktrees/feat")
}
mkrepo pa; mkrepo pb
WA="$CODE_DIR/pa/.worktrees/feat" WB="$CODE_DIR/pb/.worktrees/feat"
GDA="$(git -C "$WA" rev-parse --absolute-git-dir)" GDB="$(git -C "$WB" rev-parse --absolute-git-dir)"
mkdir -p "$FIX/tasks"
task() { # task <name> <worktrees value> — a task file with primary pa
  printf -- '---\nrepo: pa\nworktree: .worktrees/feat\nworktrees: %s\n---\n# t\n' "$2" >"$FIX/tasks/$1.md"
}
task two 'pb/.worktrees/feat'
task bad 'pc/.worktrees/gone, ../evil/.worktrees/x, pd/.worktrees/../../y, pb/.worktrees/feat'
tmux new-session -d -s two 'exec sleep 600'; tmux set-option -t '=two:' @task "$FIX/tasks/two.md"
tmux new-session -d -s bad 'exec sleep 600'; tmux set-option -t '=bad:' @task "$FIX/tasks/bad.md"
tmux new-session -d -s plain 'exec sleep 600'
pane() { tmux list-panes -t "=$1:" -F '#{pane_id}' | head -n 1; }
mhook() { # mhook <pane> <cwd> <verb> [stdin]
  (cd "$2" && printf '%s' "${4:-}" | TMUX_PANE="$1" "$HOOK" "$3")
}
midle() { flock -w 10 "$GDA/wb-turn.lock" true && flock -w 10 "$GDB/wb-turn.lock" true; }
mref() { git -C "$1" rev-parse -q --verify "refs/worktree/wb/$2" 2>/dev/null; }
mfiles() { git -C "$1" diff --name-only "refs/worktree/wb/turn^" "refs/worktree/wb/turn" 2>/dev/null | tr '\n' ' '; }
P2="$(pane two)" PB="$(pane bad)" PP="$(pane plain)"

# AE4: a turn that edited only the extra leaves the primary's turn ref alone.
mhook "$P2" "$WA" prompt; midle
echo a1 >"$WA/a1.txt"; echo b1 >"$WB/b1.txt"
mhook "$P2" "$WA" stop "$(stop_in first)"
mhook "$P2" "$WA" prompt; midle
assert_eq "both worktrees get turn-start from one prompt" 2 "$(for w in "$WA" "$WB"; do mref "$w" turn-start; done | wc -l | tr -d ' ')"
# The first stop saw edits in both; each turn ref is parented on its own turn-start.
assert_eq "edit in both: primary's turn holds its edit" "a1.txt " "$(git -C "$WA" diff --name-only "refs/worktree/wb/turn^" "refs/worktree/wb/turn" | tr '\n' ' ')"
assert_eq "edit in both: extra's turn holds its edit" "b1.txt " "$(mfiles "$WB")"
assert_eq "edit in both: each turn is parented on a parentless turn-start" "1 1" \
  "$(for w in "$WA" "$WB"; do git -C "$w" rev-list --parents -n1 "$(mref "$w" turn)^" | wc -w | tr -d ' '; done | tr '\n' ' ' | sed 's/ $//')"
TURN_A="$(mref "$WA" turn)" TURN_B="$(mref "$WB" turn)"
echo b2 >"$WB/b2.txt"
mhook "$P2" "$WA" stop "$(stop_in second)"
assert_eq "AE4: primary's turn ref is unchanged" "$TURN_A" "$(mref "$WA" turn)"
assert_eq "AE4: extra's turn shows the new edit" "b2.txt " "$(mfiles "$WB")"
[ "$(mref "$WB" turn)" != "$TURN_B" ] && ok "AE4: extra's turn moved" || bad "AE4: extra's turn moved"

# The working folder inside the extra: each worktree once (a repeated lock would
# stall the prompt for its whole 3 s budget).
start=$(date +%s%N)
mhook "$P2" "$WB" prompt
ms=$((($(date +%s%N) - start) / 1000000))
midle
[ "$ms" -lt 1500 ] && ok "working folder in the extra: each worktree recorded once (${ms} ms)" || bad "working folder in the extra: each worktree recorded once" "${ms} ms"
echo b3 >"$WB/b3.txt"; echo a3 >"$WA/a3.txt"
mhook "$P2" "$WB" stop "$(stop_in third)"
assert_eq "working folder in the extra: extra recorded" "b3.txt " "$(mfiles "$WB")"
assert_eq "working folder in the extra: primary recorded too" "a3.txt " "$(mfiles "$WA")"

# Missing and invalid entries are skipped; the primary is still recorded.
mhook "$PB" "$WA" prompt; midle
echo a4 >"$WA/a4.txt"; echo b4 >"$WB/b4.txt"
mhook "$PB" "$WA" stop "$(stop_in fourth)"
assert_eq "skipped entries: primary recorded" "a4.txt " "$(mfiles "$WA")"
assert_eq "skipped entries: the valid extra after them is recorded" "b4.txt " "$(mfiles "$WB")"
[ ! -e "$CODE_DIR/pc" ] && [ ! -e "$FIX/evil" ] && [ ! -e "$CODE_DIR/y" ] && ok "skipped entries: nothing created" || bad "skipped entries: nothing created"
task missing 'pc/.worktrees/gone'
tmux set-option -t '=two:' @task "$FIX/tasks/missing.md"
mhook "$P2" "$WA" prompt; midle
echo a5 >"$WA/a5.txt"
mhook "$P2" "$WA" stop "$(stop_in fifth)"
assert_eq "missing extra: primary recorded" "a5.txt " "$(mfiles "$WA")"
tmux set-option -t '=two:' @task "$FIX/tasks/two.md"

# A pane with no @task keeps today's behaviour: the working folder only.
mhook "$PP" "$WA" prompt; midle
T0B="$(mref "$WB" turn)" S0B="$(mref "$WB" turn-start)"
echo a6 >"$WA/a6.txt"; echo b6 >"$WB/b6.txt"
mhook "$PP" "$WA" stop "$(stop_in sixth)"
assert_eq "no @task: working folder recorded" "a6.txt " "$(mfiles "$WA")"
assert_eq "no @task: the task's other worktree is left alone" "$T0B|$S0B" "$(mref "$WB" turn)|$(mref "$WB" turn-start)"

# prompt: a worktree whose lock is held elsewhere is skipped, the other recorded.
mhook "$P2" "$WA" prompt; midle
S0A="$(mref "$WA" turn-start)" S0B="$(mref "$WB" turn-start)"
echo a7 >"$WA/a7.txt"; echo b7 >"$WB/b7.txt"
flock "$GDB/wb-turn.lock" sleep 5 & holder=$!
sleep 0.3
mhook "$P2" "$WA" prompt
flock -w 10 "$GDA/wb-turn.lock" true
[ "$(mref "$WA" turn-start)" != "$S0A" ] && ok "lock busy on one worktree: the other is recorded" || bad "lock busy on one worktree: the other is recorded"
assert_eq "lock busy on one worktree: the busy one keeps its turn-start" "$S0B" "$(mref "$WB" turn-start)"
wait "$holder"

# prompt with both locks busy returns inside the hook's 5 s timeout.
flock "$GDA/wb-turn.lock" sleep 6 & h1=$!
flock "$GDB/wb-turn.lock" sleep 6 & h2=$!
sleep 0.3
start=$(date +%s%N)
mhook "$P2" "$WA" prompt; rc=$?
ms=$((($(date +%s%N) - start) / 1000000))
assert_eq "both locks busy: exit 0" 0 "$rc"
[ "$ms" -lt 4500 ] && ok "both locks busy: prompt returns inside its 5 s timeout (${ms} ms)" || bad "both locks busy: prompt returns inside 5 s" "${ms} ms"
wait "$h1" "$h2"

# stop with a hanging git call in the extra: within the 10 s hook timeout, exit 0,
# the primary recorded.
mhook "$P2" "$WA" prompt; midle
echo a8 >"$WA/a8.txt"; echo b8 >"$WB/b8.txt"
TB="$(mref "$WB" turn)"
printf '%s' "$WB" >"$FIX/hangadd"
start=$(date +%s)
mhook "$P2" "$WA" stop "$(stop_in eighth)"; rc=$?
secs=$(($(date +%s) - start))
rm -f "$FIX/hangadd"
assert_eq "hung git in the extra: exit 0" 0 "$rc"
[ "$secs" -lt 10 ] && ok "hung git in the extra: stop returns inside its 10 s timeout (${secs}s)" || bad "hung git in the extra: stop returns inside 10 s" "${secs}s"
assert_eq "hung git in the extra: primary recorded" "a8.txt " "$(mfiles "$WA")"
assert_eq "hung git in the extra: extra's turn unchanged" "$TB" "$(mref "$WB" turn)"

# --- guards: nothing written, nothing printed -------------------------------------
git -C "$WT" update-ref -d refs/worktree/wb/turn-start
git -C "$WT" update-ref -d refs/worktree/wb/turn
guard() { # guard <label> <env...> -- <dir>
  local label="$1" dir out; shift
  local envs=()
  while [ "$1" != -- ]; do envs+=("$1"); shift; done
  shift; dir="$1"
  out="$(cd "$dir" && env "${envs[@]}" "$HOOK" prompt </dev/null 2>&1; env "${envs[@]}" "$HOOK" stop <<<'{}' 2>&1)"
  sleep 0.3
  assert_eq "$label: nothing printed" "" "$out"
}
guard "sdk entrypoint" CLAUDE_CODE_ENTRYPOINT=sdk-cli -- "$WT"
guard "unattended" CLAUDE_CODE_SESSION_ATTENDED=0 -- "$WT"
guard "no TMUX_PANE" -u TMUX_PANE -- "$WT"
mkdir -p "$XDG_STATE_HOME/wb" && : >"$XDG_STATE_HOME/wb/disable-turn-snapshot"
guard "kill switch" FOO=1 -- "$WT"
rm -f "$XDG_STATE_HOME/wb/disable-turn-snapshot"
guard "main checkout" FOO=1 -- "$MAIN"
assert_eq "guards: no refs in the worktree" "" "$(ref turn-start)$(ref turn)"
assert_eq "main checkout: no refs" "" "$(git -C "$MAIN" for-each-ref refs/worktree | tr -d ' ')"
[ ! -e "$MAIN/.git/wb-turn.lock" ] && ok "main checkout: no lock file" || bad "main checkout: no lock file"

if [ "$fail" -eq 0 ]; then echo "ALL PASSED"; else echo "FAILED"; fi
exit "$fail"
