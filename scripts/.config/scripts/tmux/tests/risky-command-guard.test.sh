#!/usr/bin/env bash
# Tests for risky-command-guard.sh — the Claude Code PreToolUse hook that
# denies or asks before commands that can take out the workbench (the
# 2026-10-25 `tmux $S kill-server` incident) or that Jet confirms every time.
#
# Plain-bash assertions against synthetic PreToolUse payloads on stdin, same
# convention as tasks-agent-hook.test.sh. Needs jq.
#
# Run: bash scripts/.config/scripts/tmux/tests/risky-command-guard.test.sh
set -uo pipefail

GUARD="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/risky-command-guard.sh"
FIXTURE_HOME="$(mktemp -d -t risky-guard-home.XXXXXX)"
trap 'rm -rf "$FIXTURE_HOME"' EXIT

fail=0
decide() { # <command> -> deny|ask|allow
  local out
  out="$(jq -n --arg c "$1" '{tool_name:"Bash", tool_input:{command:$c}}' \
    | HOME="$FIXTURE_HOME" bash "$GUARD")"
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
expect ask   'tmux kill-session -t dotfiles--foo'
expect ask   'tmux kill-pane -t %12'
expect allow 'tmux -L "pt$$" -f /dev/null kill-server'
expect allow 'tmux -S /tmp/x.sock kill-server'
expect allow 'tmux -L wbtest kill-session -t a'
expect allow 'tmux ls'
expect allow 'grep -n "tmux kill-server" notes.md'
expect allow "git commit -q -F - <<'EOF'
A test ran \`tmux \$S kill-server\` with \$S empty; kill -9 -1; rm -rf ~
EOF
git log -1"
expect deny  "bash <<'EOF'
tmux kill-server
EOF"
expect deny  "cat > notes <<EOF
fine
EOF
tmux kill-server"

# --- process kills ------------------------------------------------------
expect deny  'pkill tmux'
expect deny  'pkill -f claude'
expect deny  'killall zsh'
expect deny  'pkill -u jetnoli'
expect deny  'kill -9 -1'
expect deny  'kill -- -1'
expect ask   'kill 12345'
expect ask   'pkill -f my-dev-server'

# --- rm -r --------------------------------------------------------------
expect deny  'rm -rf ~'
expect deny  'rm -rf "$HOME"'
expect deny  'rm -rf $HOME/code'
expect deny  'rm -rf ~/code/tasks/'
expect deny  'rm -rf /'
expect deny  'rm -rf /*'
expect deny  'cd /tmp && rm -fr ~/.claude'
expect ask   'rm -rf "$tmpdir"'
expect ask   'rm -r build'
expect allow 'rm notes.txt'
expect allow 'rm -f a.log b.log'

# --- machine / data / cloud ---------------------------------------------
expect deny  'sudo reboot'
expect deny  'systemctl poweroff'
expect deny  'dd if=img of=/dev/sda bs=4M'
expect ask   'systemctl --user stop wb-agent-x.scope'
expect ask   'psql -c "DROP TABLE sessions"'
expect ask   'bq rm -f proj:ds.table'
expect ask   'terraform apply -auto-approve'
expect ask   'terraform destroy'
expect ask   'gcloud run jobs delete pp-job --region europe-west2'
expect ask   'kubectl delete pod x'
expect ask   'git push --force origin development'
expect allow 'git push --force-with-lease origin feat/x'
expect allow 'terraform plan'
expect allow 'systemctl --user status foo'
expect allow 'git status'

# --- fail-open / kill switch ---------------------------------------------
out="$(printf 'not json' | HOME="$FIXTURE_HOME" bash "$GUARD" 2>/dev/null)"
[ -z "$out" ] && echo "ok   - bad payload fails open" || { echo "FAIL - bad payload produced: $out"; fail=1; }
mkdir -p "$FIXTURE_HOME/.local/state/claude"
touch "$FIXTURE_HOME/.local/state/claude/disable-risky-command-guard"
expect allow 'tmux kill-server'
rm -f "$FIXTURE_HOME/.local/state/claude/disable-risky-command-guard"

[ "$fail" -eq 0 ] && echo "ALL PASS" || echo "FAILURES"
exit "$fail"
