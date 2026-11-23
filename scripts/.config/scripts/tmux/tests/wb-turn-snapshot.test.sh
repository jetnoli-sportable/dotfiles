#!/usr/bin/env bash
# shellcheck disable=SC2016,SC2329,SC2015 # literal fixtures; trap, ok/bad helpers
# Tests for wb-turn-snapshot.sh, the
# prompt and stop hooks that write refs/worktree/wb/turn-start and /turn in a
# linked worktree. Real git in a temp repo with a linked worktree; a logging
# PATH shim for git injects slow or failing steps. No tmux is used: TMUX_PANE is
# just set so the guard passes.
# Run: bash scripts/.config/scripts/tmux/tests/wb-turn-snapshot.test.sh
# HOOK overrides the script under test.
set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HOOK="${HOOK:-$SELF_DIR/wb-turn-snapshot.sh}"
FIX="$(mktemp -d -t wb-turn-snapshot.XXXXXX)"
REAL_GIT="$(command -v git)"

export HOME="$FIX/home" XDG_STATE_HOME="$FIX/state" LANG=C.UTF-8 LC_ALL=C.UTF-8
export GIT_CONFIG_GLOBAL="$FIX/gitconfig" GIT_CONFIG_NOSYSTEM=1
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
mkdir -p "$HOME" "$XDG_STATE_HOME/wb" "$FIX/bin"
: >"$GIT_CONFIG_GLOBAL"
unset CLAUDE_CODE_ENTRYPOINT CLAUDE_CODE_SESSION_ATTENDED
export TMUX_PANE=%1

cleanup() { rm -rf "${FIX:?}"; }
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
#   hangadd      `add` hangs
#   slowtree     `write-tree` prints its tree, touches $FIX/treedone, then sleeps
cat >"$FIX/bin/git" <<EOF2
#!/usr/bin/env bash
case " \$* " in
  *" add "*)
    [ -e "$FIX/failadd" ] && exit 1
    [ -e "$FIX/hangadd" ] && exec sleep 30 ;;
  *" write-tree "*)
    if [ -e "$FIX/slowtree" ]; then
      out="\$("$REAL_GIT" "\$@")"; echo "\$out"
      touch "$FIX/treedone"; sleep 1.5; exit 0
    fi ;;
esac
exec "$REAL_GIT" "\$@"
EOF2
chmod +x "$FIX/bin/git"
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
