#!/usr/bin/env bash
# Tests for the reply-log plugin wiring: the hooks-only skills-dir plugin at
# claude/.claude/skills/reply-log/ parses, its single Stop hook resolves (with
# REPLY_LOG_BIN pointed at this repo's scripts) to an executable script and a
# verb claude-reply-log.sh dispatches, it is synchronous with timeout 5, there
# is no SubagentStop hook (subagent turns write nothing), and the hook is not
# duplicated into settings.recommended.json (plugin + settings hooks both run,
# so a copy there would double-fire).
#
# Static checks only: no tmux, no claude, no hook is executed.
#
# Run: bash scripts/.config/scripts/tmux/tests/reply-log-plugin.test.sh
set -uo pipefail

TMUX_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPO="$(cd "$TMUX_DIR/../../../.." && pwd)"
PLUGIN="$REPO/claude/.claude/skills/reply-log"
HOOKS="$PLUGIN/hooks/hooks.json"
MANIFEST="$PLUGIN/.claude-plugin/plugin.json"
SETTINGS="$REPO/claude/.claude/settings.recommended.json"

fail=0
ok()   { echo "ok   - $1"; }
bad()  { echo "FAIL - $1${2:+ ($2)}"; fail=1; }
assert_eq()    { [ "$2" = "$3" ] && ok "$1" || bad "$1" "expected [$2], got [$3]"; }

# --- manifest ---------------------------------------------------------------
jq -e . "$MANIFEST" >/dev/null 2>&1 && ok "plugin.json parses" || bad "plugin.json parses"
assert_eq "plugin name" reply-log "$(jq -r .name "$MANIFEST" 2>/dev/null)"
assert_eq "manifest keys are name/description/author only" '["author","description","name"]' \
  "$(jq -c 'keys' "$MANIFEST" 2>/dev/null)"
[ ! -e "$PLUGIN/SKILL.md" ] && ok "plugin dir carries no SKILL.md (hooks only)" \
  || bad "plugin dir carries no SKILL.md (hooks only)"

# --- hooks.json shape -------------------------------------------------------
jq -e . "$HOOKS" >/dev/null 2>&1 && ok "hooks.json parses" || bad "hooks.json parses"
assert_eq "only a Stop event" '["Stop"]' "$(jq -c '.hooks | keys' "$HOOKS" 2>/dev/null)"
assert_eq "no SubagentStop hook" false "$(jq '.hooks | has("SubagentStop")' "$HOOKS" 2>/dev/null)"
assert_eq "one hook entry in all" 1 "$(jq '[.hooks[][].hooks[]] | length' "$HOOKS" 2>/dev/null)"
assert_eq "type command" command "$(jq -r '.hooks.Stop[0].hooks[0].type' "$HOOKS" 2>/dev/null)"
assert_eq "timeout 5" 5 "$(jq -r '.hooks.Stop[0].hooks[0].timeout' "$HOOKS" 2>/dev/null)"
assert_eq "synchronous" false "$(jq '.hooks.Stop[0].hooks[0].async == true' "$HOOKS" 2>/dev/null)"

# --- the command resolves ---------------------------------------------------
cmd="$(jq -r '.hooks.Stop[0].hooks[0].command' "$HOOKS" 2>/dev/null)"
case "$cmd" in
  '"${REPLY_LOG_BIN:-$HOME/.config/scripts/tmux}/claude-reply-log.sh" '*) ok "command uses the REPLY_LOG_BIN form" ;;
  *) bad "command uses the REPLY_LOG_BIN form" "$cmd" ;;
esac
# Word-split the command the way the hook runner's shell would, with
# REPLY_LOG_BIN pointed at the repo (HOME bogus so a fallback can't pass).
# shellcheck disable=SC2016
path="$(REPLY_LOG_BIN="$TMUX_DIR" HOME=/nonexistent bash -c 'eval "set -- $1"; printf %s "$1"' _ "$cmd")"
# shellcheck disable=SC2016
verb="$(REPLY_LOG_BIN="$TMUX_DIR" HOME=/nonexistent bash -c 'eval "set -- $1"; printf %s "${2:-}"' _ "$cmd")"
[ -x "$path" ] && ok "claude-reply-log.sh exists and is executable" || bad "script exists and is executable" "$path"
assert_eq "verb" hook-stop "$verb"
grep -qE "^[[:space:]]+${verb}\)" "$TMUX_DIR/claude-reply-log.sh" \
  && ok "claude-reply-log.sh dispatches $verb" || bad "claude-reply-log.sh dispatches $verb"

# --- no duplicate wiring in settings ----------------------------------------
jq -e . "$SETTINGS" >/dev/null 2>&1 && ok "settings.recommended.json parses" || bad "settings.recommended.json parses"
assert_eq "no reply-log hook in settings.recommended.json" 0 \
  "$(jq '[.. | strings | select(test("claude-reply-log"))] | length' "$SETTINGS")"

if [ "$fail" -eq 0 ]; then echo "ALL PASSED"; else echo "FAILED"; fi
exit "$fail"
