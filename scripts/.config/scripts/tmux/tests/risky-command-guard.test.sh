#!/usr/bin/env bash
# Tests for risky-command-guard.sh — the Claude Code PreToolUse hook that
# denies or asks before commands that can take out the workbench (the
# 2026-10-25 `tmux $S kill-server` incident) or that Jet confirms every time.
#
# Plain-bash assertions against synthetic PreToolUse payloads on stdin, same
# convention as tasks-agent-hook.test.sh. Needs jq.
#
# Run: bash scripts/.config/scripts/tmux/tests/risky-command-guard.test.sh
# GUARD=/path/to/copy.sh runs the same cases against another copy of the hook.
set -uo pipefail

GUARD="${GUARD:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/risky-command-guard.sh}"
FIXTURE_HOME="$(mktemp -d -t risky-guard-home.XXXXXX)"
trap 'rm -rf "$FIXTURE_HOME"' EXIT

fail=0
decide() { # <command> -> deny|ask|allow
  local out
  out="$(jq -n --arg c "$1" '{tool_name:"Bash", tool_input:{command:$c}}' \
    | HOME="$FIXTURE_HOME" XDG_STATE_HOME="$FIXTURE_HOME/.local/state" bash "$GUARD")"
  if [ -z "$out" ]; then echo allow; else jq -r '.hookSpecificOutput.permissionDecision' <<<"$out"; fi
}
expect() { # <expected> <command>
  local got; got="$(decide "$2")"
  if [ "$got" = "$1" ]; then
    echo "ok   - $1: $2"
  else
    echo "FAIL - expected $1, got $got: $2"; fail=1
  fi
}

# --- tmux ---------------------------------------------------------------
expect deny  'S=-L pt$$
tmux $S -f /dev/null new-session -d "bash run.sh"
tmux $S kill-server'
expect deny  'tmux kill-server'
expect deny  'sleep 1 && tmux kill-server'
expect deny  'env -u TMUX tmux kill-server'
expect deny  'tmux kill-session -a'
expect deny  'tmux kill-session -t x -a'
expect deny  'tmux kill-serv'
expect deny  'tmux "kill-server"'
expect ask   'tmux kill-session -t dotfiles--foo'
expect ask   'tmux kill-pane -t %12'
expect ask   'tmux kill-window -t x'
expect ask   'tmux killp -a'
expect allow 'tmux -L "pt$$" -f /dev/null kill-server'
expect allow 'tmux -S /tmp/x.sock kill-server'
expect allow 'tmux -L wbtest kill-session -t a'
expect allow 'tmux ls'

# --- text that only mentions a command ------------------------------------
expect allow "git commit -q -F - <<'EOF'
A test ran \`tmux \$S kill-server\` with \$S empty; kill -9 -1; rm -rf ~
EOF
git log -1"
expect allow "git commit -m 'line one
rm -rf ~ and kill -1 are bad'"
expect allow 'git commit -m "guard (kill -1) and rm -rf ~
second line; pkill tmux"'
expect allow "git commit -m 'fix: truncate long titles'"
expect allow "gh pr create --body 'drops DROP TABLE handling'"
expect allow 'echo "$(date) done"'
# the backstop asks on prose that names kill-server (accepted trade-off)
expect ask   'grep -n "tmux kill-server" notes.md'
expect ask   "git commit -m 'stop \`tmux \$S kill-server\`; never pkill tmux'"
expect ask   "msg='run \`tmux kill-server\` and rm -rf ~'; echo \"\$msg\""
expect allow 'tmux kill-server -L x'
expect deny  'tmux kill-server # -L x'

# --- code handed to a shell (finding 1) -----------------------------------
expect deny  "bash -c 'tmux kill-server'"
expect deny  'bash -c "tmux kill-server"'
expect deny  'bash -c "cd /tmp && tmux $S kill-server"'
expect deny  "bash -lc 'tmux kill-server'"
expect deny  "sh -ec 'rm -rf ~/code'"
expect deny  "ssh box 'sudo reboot'"
expect deny  'ssh box "sudo reboot"'
expect deny  'ssh -p 22 box sudo reboot'
expect deny  'eval "tmux $S kill-server"'
expect deny  'eval tmux kill-server'
expect deny  'echo "x $(tmux kill-server)"'
expect allow "bash -c 'ls -la'"
expect allow "ssh host 'uptime'"
expect allow "eval 'echo hi'"
expect allow 'bash -c "git commit -m '"'"'fix'"'"'"'

# --- traps, loops, conditionals, groups (finding 2) -----------------------
expect deny  "trap 'tmux \$S kill-server' EXIT"
expect deny  'trap "tmux $S kill-server" EXIT'
expect deny  'for p in 1 2; do tmux $S kill-server; done'
expect deny  'if true; then tmux kill-server; fi'
expect deny  '{ rm -rf ~/code; }'
expect deny  '! tmux kill-server'
expect deny  'f() { tmux kill-server; }'
expect allow "trap 'rm -f \"\$tmp\"' EXIT"

# --- heredocs and herestrings (finding 3) ---------------------------------
expect deny  "bash <<'EOF'
tmux kill-server
EOF"
expect deny  "cat <<'EOF' | bash
tmux kill-server
EOF"
expect deny  "cat <<< word
tmux kill-server"
expect deny  "cat > notes <<EOF
fine
EOF
tmux kill-server"
expect allow "cat > notes <<'EOF'
tmux kill-server
EOF"
expect ask   "psql <<'SQL'
DROP TABLE sessions;
SQL"

# --- line continuations (finding 6) ---------------------------------------
expect deny  'tmux $S \
kill-server'
expect deny  'rm -rf \
~/code'

# --- wrappers, xargs, find (finding 7) ------------------------------------
expect deny  'sudo reboot'
expect deny  'sudo -u root reboot'
expect deny  'sudo -n rm -rf ~/code'
expect deny  'nice -n 19 rm -rf ~/code'
expect deny  'timeout 30 tmux kill-server'
expect deny  'timeout -k 5 30 tmux kill-server'
expect deny  'timeout --foreground 30 tmux kill-server'
expect ask   'pgrep -f fzf | xargs kill -9'
expect ask   'xargs -I {} rm -rf {}'
expect ask   'find . -name node_modules -type d -exec rm -rf {} +'
expect ask   'find /tmp/x -mindepth 1 -delete'
expect deny  'find . -exec tmux kill-server \;'
expect allow 'find . -name "*.sh" -exec shellcheck {} +'
expect allow 'xargs -n1 echo'

# --- process kills (finding 8) --------------------------------------------
expect deny  'pkill tmux'
expect deny  'pkill -f claude'
expect deny  "pkill -f 'tmux'"
expect deny  "killall 'claude'"
expect deny  'killall zsh'
expect deny  'pkill -u jetnoli'
expect deny  'kill -9 -1'
expect deny  'kill -- -1'
expect deny  'kill -s HUP -1'
expect ask   'kill -1 "$pid"'
expect ask   'kill -1 $(pgrep foo)'
expect ask   'kill 12345'
expect ask   'pkill -f my-dev-server'
expect allow 'kill -l'

# --- rm -r (finding 5) ----------------------------------------------------
expect deny  'rm -rf ~'
expect deny  'rm -rf "$HOME"'
expect deny  'rm -rf $HOME/code'
expect deny  'rm -rf ~/code/tasks/'
expect deny  'rm -rf /'
expect deny  "rm -rf '/'"
expect deny  'rm -rf /*'
expect deny  'rm --recursive ~'
expect deny  'cd /tmp && rm -fr ~/.claude'
expect ask   'rm -rf "$tmpdir"'
expect ask   "rm -rf 'build'"
expect ask   "rm -rf 'build dir'"
expect ask   'rm -r build'
expect allow 'rm notes.txt'
expect allow 'rm -f a.log b.log'
expect deny  'rm -rf /tmp/tmux-1000'
expect deny  'rm -rf /tmp/*'
expect deny  'rm -rf /tmp/'

# --- rm -r of agent scratch (asked too often: 13 of 16 asks in 2h, 2026-10-25)
expect allow 'rm -rf ~/.cleanroom/wb-resume-baseline ~/.cleanroom/wb-resume-mutation'
expect allow 'rm -rf "$HOME/.cleanroom/decision-propagation-oldsweep" && echo cleaned'
expect allow 'rm -rf -- /tmp/compound-engineering-1000/ce-code-review/20261025-172822-7ccdd92c /tmp/claude-1000/sessionend-probe'
expect allow 'S=/tmp/claude-1000/-home-x/abc/scratchpad; rm -rf $S/basedev; mkdir $S/basedev'
expect allow 'cd /x; S=/tmp/claude-1000/-home-x/abc/scratchpad/regress; rm -rf "$S"; mkdir -p "$S/share"'
expect allow 'd=/tmp/compound-engineering-1000/ce-code-review/r1; ls "$d" && rm -rf -- "$d" && echo deleted'
expect allow 'C=~/.cleanroom/x; rm -rf "${C}"'
expect ask   'rm -rf ~/.cleanroom'
expect ask   'rm -rf ~/.cleanroom/*'
expect ask   'rm -rf /tmp/claude-1000'
expect ask   'rm -rf /tmp/claude-1000/*'
expect ask   'rm -rf /tmp/claude-1000/../tmux-1000'
expect ask   'rm -rf /tmp/claude-1000/x ~/notes'
expect ask   'rm -rf /tmp/foo'
expect ask   'd=$(mktemp -d); echo x > $d/f; rm -r $d'
expect ask   'rm -rf "$S"; S=/tmp/claude-1000/x'
expect ask   'S=/tmp/claude-1000/x; S=$HOME; rm -rf "$S"'
expect ask   'S=/tmp/claude-1000/x; for i in 1 2; do rm -rf "$S"; S=~; done'
expect ask   'S=/tmp/claude-1000/x; source wb.sh; rm -rf "$S"'
expect ask   'S=/tmp/claude-1000/x; . ./env.sh; rm -rf "$S"'
expect ask   'S=/tmp/claude-1000/x; read S; rm -rf "$S"'
expect ask   'S=/tmp/claude-1000/x; S+=/../..; rm -rf "$S"'
expect ask   'S=/tmp/claude-1000/x; : "${S:=~}"; rm -rf "$S"'
expect ask   'S=/tmp/claude-1000/x rm -rf "$S"'
expect ask   'S=$D/x; rm -rf "$S"'
expect ask   'S=$S/x; rm -rf "$S"'
expect ask   'for S in /tmp/claude-1000/x ~; do rm -rf "$S"; done'
# second review: forms that reshape or add targets after the guard reads the text
expect ask   'S=/tmp/claude-1000/x; rm -rf "${S%/*}"'
expect ask   'S=/tmp/claude-1000/x; rm -rf "${S%%/claude*}"'
expect ask   'S=/tmp/claude-1000/x; rm -rf "${S:0:4}"'
expect ask   'S=/tmp/claude-1000/x; rm -rf "${S##*/}"'
expect ask   'S=/tmp/claude-1000/x; rm -rf "${#S}"'
expect ask   'D="/tmp/claude-1000/x $HOME"; rm -rf $D'
expect ask   "D='/tmp/claude-1000/x /'; rm -rf \${D}"
expect ask   'rm -rf "/tmp/claude-1000/a b"'
expect ask   'S=/tmp/claude-1000/x; if source wb.sh; then rm -rf "$S"; fi'
expect ask   'S=/tmp/claude-1000/x; { . ./env.sh; }; rm -rf "$S"'
expect ask   'S=/tmp/claude-1000/x; command source wb.sh; rm -rf "$S"'
expect ask   'rm -rf /tmp/claude-1000/x $(cat paths.txt)'
expect ask   'rm -rf /tmp/claude-1000/x `pwd`'
expect ask   'rm -rf "/tmp/claude-1000/x/$(echo ../../../home/jetnoli)"'
expect ask   'n=$(ls ~/.cleanroom); rm -rf ~/.cleanroom/x/$n'
expect ask   'echo ~/code | xargs rm -rf /tmp/claude-1000/x'
expect ask   'ls | xargs -0 rm -rf /tmp/claude-1000/x'
expect ask   'rm -rf /tmp/claude-1000/{x,}'
expect ask   'rm -rf /tmp/claude-1000/./*'
expect ask   'rm -rf ~/.cleanroom/./*'
expect ask   'rm -rf /tmp/compound-engineering-1000/*'
expect allow 'S=/tmp/claude-1000/x; rm -rf "${S}/build"'
expect allow 'rm -rf /tmp/claude-1000/x/{a,b}'

# --- machine / data / cloud ---------------------------------------------
expect deny  'reboot'
expect deny  'systemctl poweroff'
expect deny  'dd if=img of=/dev/sda bs=4M'
expect deny  'mkfs.ext4 /dev/sdb1'
expect allow 'dd if=/dev/zero of=img bs=1M count=1'
expect ask   'systemctl --user stop wb-agent-x.scope'
expect ask   'systemctl --user restart foo'
expect ask   'psql -c "DROP TABLE sessions"'
expect ask   'psql -c "TRUNCATE sessions"'
expect ask   'bq rm -f proj:ds.table'
expect ask   'terraform apply -auto-approve'
expect ask   'terraform destroy'
expect ask   'tofu apply'
expect ask   'gcloud run jobs delete pp-job --region europe-west2'
expect ask   'gsutil rm gs://b/x'
expect ask   'kubectl delete pod x'
expect allow 'truncate -s 0 app.log'
expect allow 'terraform plan'
expect allow 'systemctl --user status foo'

# --- force pushes (finding 9) ---------------------------------------------
expect ask   'git push --force origin development'
expect ask   'git push -f origin main'
expect ask   'git push -fu origin main'
expect ask   'git push origin +main'
expect ask   "git push --force origin 'main'"
expect ask   'git push --force origin HEAD:development'
expect ask   'git push -f'
expect ask   'git push --force origin'
expect allow 'git push --force-with-lease origin feat/x'
expect allow 'git push origin main'
expect allow 'git push -u origin feat/x'
expect allow 'git status'

# --- fail-open / kill switch ---------------------------------------------
out="$(printf 'not json' | HOME="$FIXTURE_HOME" XDG_STATE_HOME="$FIXTURE_HOME/.local/state" bash "$GUARD" 2>/dev/null)"
[ -z "$out" ] && echo "ok   - bad payload fails open" || { echo "FAIL - bad payload produced: $out"; fail=1; }
mkdir -p "$FIXTURE_HOME/.local/state/claude"
touch "$FIXTURE_HOME/.local/state/claude/disable-risky-command-guard"
expect allow 'tmux kill-server'
rm -f "$FIXTURE_HOME/.local/state/claude/disable-risky-command-guard"

[ "$fail" -eq 0 ] && echo "ALL PASS" || echo "FAILURES"
exit "$fail"
