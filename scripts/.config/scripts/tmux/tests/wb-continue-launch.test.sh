#!/usr/bin/env bash
# shellcheck disable=SC2329,SC2016 # test scaffolding: traps, subshell env, literal fixtures
# Tests for the launch half of the wb continue restart (U1's launch scenarios,
# moved here because the helper's wait loop is the code under test): the
# fixed launch command typed into a pane's fresh zsh runs the `claude` zsh
# wrapper (extracted from zsh/.zshrc the way wb-claude-wrapper.test.sh does) and
# so the stub claude inside a systemd scope (systemd-run is stubbed), and the
# helper types it only once the respawned pane shows a shell, however late the
# shell starts. Real tmux on ONE fixed private -L socket (never the default).
# Run: bash scripts/.config/scripts/tmux/tests/wb-continue-launch.test.sh
set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WB="$SELF_DIR/wb.sh"
HOOK="$SELF_DIR/wb-continue-hook.sh"
PAYLOADS="$SELF_DIR/tests/fixtures/hook-payloads"
ZSHRC="$(cd "$SELF_DIR/../../../.." && pwd)/zsh/.zshrc"
FUNC_SRC="$(sed -n '/# wb-claude-wrapper:begin/,/# wb-claude-wrapper:end/p' "$ZSHRC" | sed '1d;$d')"
[ -n "$FUNC_SRC" ] || {
  echo "FAIL - could not extract claude() wrapper from $ZSHRC"
  exit 1
}
command -v zsh >/dev/null 2>&1 || {
  echo "FAIL - zsh not found on PATH; the wrapper under test is a zsh function"
  exit 1
}
FIX="$(mktemp -d -t wb-continue-launch.XXXXXX)"
SOCK="wb-continue-launch-test-sock"
REAL_TMUX="$(command -v tmux)"
REAL_BASH="$(command -v bash)"

# Isolation FIRST.
export HOME="$FIX/home" XDG_STATE_HOME="$FIX/state" CODE_DIR="$FIX/code" TASKS_DIR="$FIX/tasks"
export WB_CONTINUE_SESSIONS_DIR="$FIX/sessions" LANG=C.UTF-8 LC_ALL=C.UTF-8
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
mkdir -p "$HOME" "$XDG_STATE_HOME/wb" "$CODE_DIR" "$TASKS_DIR" "$FIX/bin" "$FIX/zdot" "$WB_CONTINUE_SESSIONS_DIR"
unset TMUX TMUX_PANE CLAUDE_CODE_SESSION_ID CLAUDE_CODE_ENTRYPOINT CLAUDE_CODE_SESSION_ATTENDED WBC_TRANSCRIPT

TMUX_LOG="$FIX/tmux.log"
: >"$TMUX_LOG"
cat >"$FIX/bin/tmux" <<EOF2
#!/usr/bin/env bash
echo "\$(date +%s%N) \$*" >> "$TMUX_LOG"
exec "$REAL_TMUX" -u -L "$SOCK" -f /dev/null "\$@"
EOF2
cat >"$FIX/bin/oldclaude" <<'EOF2'
#!/usr/bin/env bash
printf '{"sessionId":"%s","pid":%s}\n' "$1" "$$" > "$WB_CONTINUE_SESSIONS_DIR/$$.json"
printf '\xe2\x9d\xaf\xc2\xa0\n'
exec sleep 600
EOF2
# systemd-run: record argv, then exec the trailing absolute command.
cat >"$FIX/bin/systemd-run" <<EOF2
#!/usr/bin/env bash
printf '%s\n' "\$@" >> "$FIX/systemd-run.argv"
args=("\$@")
for i in "\${!args[@]}"; do
  case "\${args[\$i]}" in /*) exec "\${args[@]:\$i}" ;; esac
done
exit 1
EOF2
# claude: records argv; mode `pickup` runs the real pick-up, anything else quits.
cat >"$FIX/bin/claude" <<EOF2
#!/usr/bin/env bash
n=\$(( \$(cat "$FIX/claude-count" 2>/dev/null || echo 0) + 1 )); echo \$n > "$FIX/claude-count"
printf '%s\n' "\$@" > "$FIX/claude-argv-\$n"
sid=""; prev=""; last=""
for a in "\$@"; do [ "\$prev" = --session-id ] && sid="\$a"; prev="\$a"; last="\$a"; done
case "\$(cat "$FIX/claude-mode" 2>/dev/null)" in
  pickup)
    CLAUDE_CODE_SESSION_ID="\$sid" bash "$WB" continue pickup "\${last#/wb-resume --continue }" > "$FIX/claude-pickup-\$n.out" 2>&1
    printf '{"sessionId":"%s","pid":%s}\n' "\$sid" "\$\$" > "\$WB_CONTINUE_SESSIONS_DIR/\$\$.json"
    exec sleep 600 ;;
esac
exit 0
EOF2
chmod +x "$FIX/bin/"*
printf '%s\n' "$FUNC_SRC" >"$FIX/zdot/.zshrc"
PATH="$FIX/bin:$PATH"
export PATH
ZSH_PANE_CMD="env ZDOTDIR=$FIX/zdot zsh -i"

cleanup() {
  "$REAL_TMUX" -L "$SOCK" kill-server 2>/dev/null || true
  rm -rf "${FIX:?}"
}
trap cleanup EXIT

fail=0
assert() { # <desc> <regex> <actual>
  if printf '%s' "$3" | /usr/bin/grep -qE -- "$2"; then
    echo "ok   - $1"
  else
    echo "FAIL - $1"
    echo "       expected match: $2"
    echo "       got: $(printf '%s' "$3" | head -8)"
    fail=1
  fi
}
assert_eq() { # <desc> <expected> <actual>
  if [ "$2" = "$3" ]; then echo "ok   - $1"; else
    echo "FAIL - $1"
    echo "       expected: $2"
    echo "       got:      $3"
    fail=1
  fi
}

# shellcheck disable=SC1090
source "$WB"
# shellcheck disable=SC1091
source "$SELF_DIR/wb-continue.sh"
set +e +u

tm() { "$FIX/bin/tmux" "$@"; }
tm new-session -d -s keepalive 'sleep 3600'
tm set-environment -g WB_CONTINUE_SETTLE_MS 200
tm set-environment -g WB_CONTINUE_SETTLE_MAX_MS 1500
tm set-environment -g WB_CONTINUE_PROMPT_TIMEOUT 10
tm set-environment -g WB_CONTINUE_PICKUP_TIMEOUT 15
touch "$XDG_STATE_HOME/wb/continue-live"

wait_cmd() { # <pane> <regex> [secs] — wait for pane_current_command to match
  local c
  for _ in $(seq $((${3:-10} * 10))); do
    c="$(tm display-message -p -t "$1" '#{pane_current_command}' 2>/dev/null)"
    [[ "$c" =~ $2 ]] && return 0
    sleep 0.1
  done
  return 1
}
wait_file() {
  for _ in $(seq $((${2:-10} * 10))); do
    [ -s "$1" ] && return 0
    sleep 0.1
  done
  return 1
}
reset_stubs() {
  : >"$FIX/systemd-run.argv"
  rm -f "$FIX/claude-count" "$FIX"/claude-argv-* "$FIX"/claude-pickup-*
}

# =============================================================================
echo "# the launch command, typed into a fresh zsh, runs the wrapper and the stub claude"
# =============================================================================
reset_stubs
echo exit >"$FIX/claude-mode"
tm new-session -d -s launch1 -x 120 -y 30 "$ZSH_PANE_CMD"
tm set -t launch1 @wb_repo proj
P1="$(tm list-panes -t launch1 -F '#{pane_id}')"
wait_cmd "$P1" '^zsh$' 10
assert_eq "the pane starts a zsh" 0 "$?"
sleep 1 # zsh finishes its startup (zle) before the line goes in, as after a respawn
LAUNCH='claude --session-id 11111111-2222-3333-4444-555555555555 --model claude-opus-5-5 --effort medium --permission-mode acceptEdits "/wb-resume --continue proj--s1@abcd1234"'
tm send-keys -t "$P1" C-u
tm send-keys -t "$P1" -l "$LAUNCH"
tm send-keys -t "$P1" Enter
wait_file "$FIX/claude-argv-1" 10
assert_eq "the stub claude ran" 0 "$?"
assert_eq "its argv: session id, model, effort, permission mode, one prompt argument" \
  "--session-id 11111111-2222-3333-4444-555555555555 --model claude-opus-5-5 --effort medium --permission-mode acceptEdits /wb-resume --continue proj--s1@abcd1234" \
  "$(tr '\n' ' ' <"$FIX/claude-argv-1" | sed 's/ $//')"
assert_eq "the prompt reached claude as ONE argument (quoting kept)" 1 "$(/usr/bin/grep -c '^/wb-resume --continue proj--s1@abcd1234$' "$FIX/claude-argv-1")"
assert "through the wrapper: systemd-run --scope with a wb-agent unit" '^--scope$' "$(cat "$FIX/systemd-run.argv")"
assert "scope arguments: --user, --collect, the unit name and the memory caps" 'wb-agent-launch1-' "$(cat "$FIX/systemd-run.argv")"
assert "scope arguments: MemoryHigh and MemoryMax" 'MemoryHigh=.*' "$(cat "$FIX/systemd-run.argv")"
wait_cmd "$P1" '^zsh$' 10
assert_eq "quitting claude returns to a zsh prompt, the pane stays" 0 "$?"
assert_eq "the pane still exists" "$P1" "$(tm list-panes -t launch1 -F '#{pane_id}')"
tm kill-session -t launch1

# =============================================================================
echo "# the helper types only once the respawned pane shows a shell, however late"
# =============================================================================
reset_stubs
echo pickup >"$FIX/claude-mode"
: >"$TMUX_LOG"
WT="$CODE_DIR/proj/.worktrees/x"
mkdir -p "$WT"
git -C "$WT" init -q 2>/dev/null
printf 'one\n' >"$WT/a.txt"
git -C "$WT" add a.txt && git -C "$WT" commit -q -m init
STEM=proj--late
SID=sess-old-late
printf -- '---\nstatus: doing\nrepo: proj\nbranch: x\nworktree: .worktrees/x\ntags: []\ncreated: 2026-11-01\nclosed:\n---\n# Title\n\n## Plan\n\nplan\n\n## Handoffs\n\n### 2026-11-15 10:00 — wb-save\n\n**Done:** built\n\n**In flight:** nothing\n\n**Next:** review\n\n```run\n/ce-code-review\n```\n' >"$TASKS_DIR/$STEM.md"
# The pane's original command takes 2 s to hand over to zsh, so right after the
# respawn pane_current_command is `awk`, not a shell.
# awk stays the terminal's foreground process (as pane_current_command sees it)
# for the whole sleep; a shell script would show as `bash` throughout.
printf '#!/usr/bin/awk -f\nBEGIN { system("sleep 2; exec env ZDOTDIR=%s zsh -i") }\n' "$FIX/zdot" > "$FIX/bin/slowshell"; chmod +x "$FIX/bin/slowshell"
tm new-session -d -s late -x 120 -y 30 "$FIX/bin/slowshell"
tm set -t late @wb_repo proj
tm set -t late @task "$TASKS_DIR/$STEM.md"
PL="$(tm list-panes -t late -F '#{pane_id}')"
wait_cmd "$PL" '^zsh$' 10
sleep 1
tm send-keys -t "$PL" -l "oldclaude $SID"
tm send-keys -t "$PL" Enter
for _ in $(seq 40); do
  /usr/bin/grep -lq "\"sessionId\":\"$SID\"" "$WB_CONTINUE_SESSIONS_DIR"/*.json 2>/dev/null && break
  sleep 0.1
done
sleep 0.3
(
  export CLAUDE_CODE_SESSION_ID="$SID" TMUX_PANE="$PL"
  printf '' | wbc_arm "$TASKS_DIR/$STEM.md"
) >/dev/null 2>&1
ID="$(wbc_get "$STEM" id)"
assert_eq "armed" armed "$(wbc_get "$STEM" state)"
payload="$(sed -e "s/__SESSION_ID__/$SID/g" -e "s#__HOME__#$HOME#g" -e 's/__USER__/u/g' -e "s#__CWD__#$WT#g" -e "s#__TMPDIR__#$FIX#g" -e 's/__PROMPT_ID__/p1/g' "$PAYLOADS/Stop.json" |
  jq -c '.background_tasks = [] | .session_crons = []')"
printf '%s' "$payload" | env TMUX_PANE="$PL" "$REAL_BASH" "$HOOK" hook-stop
wait_file "$FIX/claude-argv-1" 25
assert_eq "the stub claude ran after the late shell came up" 0 "$?"
for _ in $(seq 60); do
  [ -f "$XDG_STATE_HOME/wb/continue/$STEM/request" ] || break
  sleep 0.25
done
assert_eq "the pick-up went through (request removed)" none "$([ -f "$XDG_STATE_HOME/wb/continue/$STEM/request" ] && echo there || echo none)"
RESPAWN_T="$(/usr/bin/grep -m1 ' respawn-pane ' "$TMUX_LOG" | cut -d' ' -f1)"
FIRST_KEYS_T="$(awk -v r="$RESPAWN_T" '$2 == "send-keys" && $1 > r { print $1; exit }' "$TMUX_LOG")"
GAP_MS=$(((FIRST_KEYS_T - RESPAWN_T) / 1000000))
if [ "$GAP_MS" -ge 1500 ]; then
  echo "ok   - nothing was typed for ${GAP_MS} ms after the respawn (the shell took 2 s)"
else
  echo "FAIL - the first key was sent only ${GAP_MS} ms after the respawn; the wait loop did not hold"
  fail=1
fi
assert "the stub claude got the request id" "/wb-resume --continue $ID" "$(cat "$FIX/claude-argv-1")"
assert "through the wrapper: a systemd scope" '^--scope$' "$(cat "$FIX/systemd-run.argv")"
tm kill-session -t late

echo
if [ "$fail" -eq 0 ]; then echo "ALL PASSED"; else echo "FAILED"; fi
exit "$fail"
