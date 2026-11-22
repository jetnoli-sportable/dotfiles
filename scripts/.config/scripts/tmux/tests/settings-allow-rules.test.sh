#!/usr/bin/env bash
# Tests for the permissions.allow list in claude/.claude/settings.recommended.json.
# The list exists to skip prompts and auto mode's classifier on everyday
# commands, so it must stay narrow: the commands it is for match it, the ones
# a guard protects don't, and nothing broad (Bash(*), an interpreter, a
# wrapper) sneaks in. A matching allow rule doesn't stop a PreToolUse hook's
# "ask" (checked live with headless claude on 22 Nov 2026), so the last block
# pins that risky-command-guard still asks on every lease push the rule lets
# through to a default branch. Needs jq.
#
# Run: bash scripts/.config/scripts/tmux/tests/settings-allow-rules.test.sh
set -uo pipefail

TMUX_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPO="$(cd "$TMUX_DIR/../../../.." && pwd)"
SETTINGS="$REPO/claude/.claude/settings.recommended.json"
GUARD="$TMUX_DIR/risky-command-guard.sh"

fail=0
ok() { echo "ok   - $1"; }
bad() {
  echo "FAIL - $1"
  fail=1
}

mapfile -t ALLOW < <(jq -r '.permissions.allow[]? | select(startswith("Bash("))
  | ltrimstr("Bash(") | rtrimstr(")")' "$SETTINGS")
if [ "${#ALLOW[@]}" -gt 0 ]; then ok "allow has ${#ALLOW[@]} Bash rules"; else bad "allow has no Bash rules"; fi

# Same glob semantics as the Claude Code docs: `*` matches any text, and a
# trailing " *" also matches the bare command.
rule_matches() { # <pattern> <command>
  local pat="$1" cmd="$2"
  # shellcheck disable=SC2053
  [[ $cmd == $pat ]] && return 0
  # shellcheck disable=SC2053
  [[ $pat == *' *' && $cmd == ${pat% \*} ]]
}
allowed() { # <command> -- sets HIT to the first matching rule
  local r
  HIT=""
  for r in "${ALLOW[@]}"; do
    if rule_matches "$r" "$1"; then
      HIT="$r"
      return 0
    fi
  done
  return 1
}

# shellcheck disable=SC2088 # the rule matches a typed ~, unexpanded
for cmd in "git status" "git status --short" "git diff --stat development..HEAD" \
  "git log --oneline -5" "git show HEAD:README.md" "git add -A" \
  "git push --force-with-lease=feat/x:abc123 origin feat/x" "mkdir -p /tmp/claude-1000/x" \
  "wb append dotfiles--x Decisions" "wb now dotfiles--x" "wb set dotfiles--x size S" \
  "wb status dotfiles--x doing" "wb followup-done dotfiles--x 2" \
  "~/.config/scripts/tmux/wb.sh append dotfiles--x Handoffs"; do
  if allowed "$cmd"; then ok "allowed: $cmd"; else bad "not allowed: $cmd"; fi
done

# Each of these is guarded or simply not part of the list; none may match.
for cmd in "git push origin development" "git push --force origin main" \
  "git push -f origin feat/x" "git push --force-with-lease origin feat/x" \
  "git -C /x push --force-with-lease=a:b origin a" "git commit -m x" "git reset --hard" \
  "rm -rf /tmp/claude-1000/x" "kill 123" "tmux kill-server" "gcloud projects list" \
  "wb done dotfiles--x" "wb new dotfiles--x" "python3 -c 1" "bash -c 'git status'" \
  "timeout 5 git status" "env git status"; do
  if allowed "$cmd"; then bad "allowed by '$HIT': $cmd"; else ok "not allowed: $cmd"; fi
done

# Nothing broad: auto mode drops these anyway, and in default mode they would
# allow anything. A mid-rule `*` matches any text, so only a trailing one is used.
for r in "${ALLOW[@]}"; do
  case "$r" in
    '*'* | *'*'?*) bad "rule has a leading or mid-rule wildcard: $r" ;;
    bash* | sh* | zsh* | python* | node* | perl* | ruby* | env* | timeout* | xargs* | sudo* | eval* | exec*)
      bad "rule allows an interpreter or wrapper: $r"
      ;;
    *) ok "narrow: $r" ;;
  esac
done

# The lease rule lets these through the permission rules; the guard must still ask:
# default branches however the lease or the destination spells them, refspec
# globs, and --receive-pack/--exec, which run a command.
for cmd in "git push --force-with-lease=development:abc origin development" \
  "git push --force-with-lease=main:abc origin HEAD:main" \
  "git push --force-with-lease=x:abc origin HEAD" \
  "git push --force-with-lease=x:abc" \
  "git push --force-with-lease=main origin feat:heads/main" \
  "git push --force-with-lease=refs/heads/main:abc origin feat" \
  "git push --force-with-lease=x:abc origin '+refs/heads/*:refs/heads/*'" \
  "git push --force-with-lease=a --receive-pack='touch /tmp/p; git-receive-pack' . HEAD:refs/heads/t" \
  "git push --force-with-lease=a --exec=x origin feat"; do
  allowed "$cmd" || bad "test premise: the lease rule should match: $cmd"
  out="$(jq -n --arg c "$cmd" '{tool_name: "Bash", tool_input: {command: $c}, cwd: "/tmp"}' | bash "$GUARD")"
  if [ "$(jq -r '.hookSpecificOutput.permissionDecision // empty' <<<"$out")" = ask ]; then
    ok "guard still asks: $cmd"
  else bad "guard does not ask on an allowed lease push: $cmd"; fi
done

exit "$fail"
