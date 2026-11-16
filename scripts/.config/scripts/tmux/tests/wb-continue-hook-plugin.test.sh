#!/usr/bin/env bash
# shellcheck disable=SC2015,SC2016 # the ok/bad helpers are not if-then-else
# Tests for the wb-continue-hook plugin wiring: the hooks-only skills-dir plugin at
# claude/.claude/skills/wb-continue-hook/ parses, its Stop and SessionStart hooks resolve (with
# WB_CONTINUE_BIN pointed at this repo's scripts) to an executable script and a
# verb wb-continue-hook.sh dispatches, it is synchronous with timeout 5, there
# is no SubagentStop hook (a subagent's Stop is not the session's), and the hook is not
# duplicated into settings.recommended.json (plugin + settings hooks both run,
# so a copy there would double-fire).
#
# Static checks only: no tmux, no claude, no hook is executed.
#
# Run: bash scripts/.config/scripts/tmux/tests/wb-continue-hook-plugin.test.sh
set -uo pipefail

TMUX_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPO="$(cd "$TMUX_DIR/../../../.." && pwd)"
PLUGIN="$REPO/claude/.claude/skills/wb-continue-hook"
HOOKS="$PLUGIN/hooks/hooks.json"
MANIFEST="$PLUGIN/.claude-plugin/plugin.json"
SETTINGS="$REPO/claude/.claude/settings.recommended.json"

fail=0
ok()   { echo "ok   - $1"; }
bad()  { echo "FAIL - $1${2:+ ($2)}"; fail=1; }
assert_eq()    { [ "$2" = "$3" ] && ok "$1" || bad "$1" "expected [$2], got [$3]"; }

# --- manifest ---------------------------------------------------------------
jq -e . "$MANIFEST" >/dev/null 2>&1 && ok "plugin.json parses" || bad "plugin.json parses"
assert_eq "plugin name" wb-continue-hook "$(jq -r .name "$MANIFEST" 2>/dev/null)"
assert_eq "manifest keys are name/description/author only" '["author","description","name"]' \
  "$(jq -c 'keys' "$MANIFEST" 2>/dev/null)"
[ ! -e "$PLUGIN/SKILL.md" ] && ok "plugin dir carries no SKILL.md (hooks only)" \
  || bad "plugin dir carries no SKILL.md (hooks only)"

# --- hooks.json shape -------------------------------------------------------
jq -e . "$HOOKS" >/dev/null 2>&1 && ok "hooks.json parses" || bad "hooks.json parses"
assert_eq "exactly Stop and SessionStart" '["SessionStart","Stop"]' "$(jq -c '.hooks | keys' "$HOOKS" 2>/dev/null)"
assert_eq "no SubagentStop hook" false "$(jq '.hooks | has("SubagentStop")' "$HOOKS" 2>/dev/null)"
assert_eq "one hook entry per event, two in all" 2 "$(jq '[.hooks[][].hooks[]] | length' "$HOOKS" 2>/dev/null)"

for pair in Stop:hook-stop SessionStart:hook-session-start; do
  ev="${pair%%:*}" want="${pair#*:}"
  assert_eq "$ev: type command" command "$(jq -r ".hooks.${ev}[0].hooks[0].type" "$HOOKS" 2>/dev/null)"
  assert_eq "$ev: timeout 5" 5 "$(jq -r ".hooks.${ev}[0].hooks[0].timeout" "$HOOKS" 2>/dev/null)"
  assert_eq "$ev: synchronous" false "$(jq ".hooks.${ev}[0].hooks[0].async == true" "$HOOKS" 2>/dev/null)"

  # --- the command resolves -------------------------------------------------
  cmd="$(jq -r ".hooks.${ev}[0].hooks[0].command" "$HOOKS" 2>/dev/null)"
  case "$cmd" in
    '"${WB_CONTINUE_BIN:-$HOME/.config/scripts/tmux}/wb-continue-hook.sh" '*) ok "$ev: command uses the WB_CONTINUE_BIN form" ;;
    *) bad "$ev: command uses the WB_CONTINUE_BIN form" "$cmd" ;;
  esac
  # Word-split the command the way the hook runner's shell would, with
  # WB_CONTINUE_BIN pointed at the repo (HOME bogus so a fallback can't pass).
  # shellcheck disable=SC2016
  path="$(WB_CONTINUE_BIN="$TMUX_DIR" HOME=/nonexistent bash -c 'eval "set -- $1"; printf %s "$1"' _ "$cmd")"
  # shellcheck disable=SC2016
  verb="$(WB_CONTINUE_BIN="$TMUX_DIR" HOME=/nonexistent bash -c 'eval "set -- $1"; printf %s "${2:-}"' _ "$cmd")"
  [ -x "$path" ] && ok "$ev: wb-continue-hook.sh exists and is executable" || bad "$ev: script exists and is executable" "$path"
  assert_eq "$ev: verb" "$want" "$verb"
  /usr/bin/grep -qE "(^|\|)[[:space:]]*${verb}[[:space:]]*(\||\))" "$TMUX_DIR/wb-continue-hook.sh" \
    && ok "$ev: wb-continue-hook.sh dispatches $verb" || bad "$ev: wb-continue-hook.sh dispatches $verb"
done

# --- no duplicate wiring in settings ----------------------------------------
jq -e . "$SETTINGS" >/dev/null 2>&1 && ok "settings.recommended.json parses" || bad "settings.recommended.json parses"
assert_eq "no wb-continue-hook hook in settings.recommended.json" 0 \
  "$(jq '[.. | strings | select(test("claude-wb-continue-hook"))] | length' "$SETTINGS")"

if [ "$fail" -eq 0 ]; then echo "ALL PASSED"; else echo "FAILED"; fi
exit "$fail"
