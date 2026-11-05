#!/usr/bin/env bash
# Tests for the pane-status plugin wiring: the hooks-only skills-dir plugin at
# claude/.claude/skills/pane-status/ parses, wires exactly the six events the
# picker's pane markers need, each to a verb claude-notify-hook.sh dispatches
# (resolved with PANE_STATUS_BIN pointed at this repo's scripts), synchronous
# with timeout 5, and is not duplicated into settings.recommended.json (plugin
# and settings hooks both run, so a copy there would fire every event twice).
#
# Why a plugin: stow carries it to a new machine; hook entries in the untracked
# ~/.claude/settings.json never travel.
#
# Static checks only: no tmux, no claude, no hook is executed.
#
# Run: bash scripts/.config/scripts/tmux/tests/pane-status-plugin.test.sh
set -uo pipefail

TMUX_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPO="$(cd "$TMUX_DIR/../../../.." && pwd)"
PLUGIN="$REPO/claude/.claude/skills/pane-status"
HOOKS="$PLUGIN/hooks/hooks.json"
MANIFEST="$PLUGIN/.claude-plugin/plugin.json"
SETTINGS="$REPO/claude/.claude/settings.recommended.json"

fail=0
ok()   { echo "ok   - $1"; }
bad()  { echo "FAIL - $1${2:+ ($2)}"; fail=1; }
assert_eq()    { [ "$2" = "$3" ] && ok "$1" || bad "$1" "expected [$2], got [$3]"; }

# --- manifest ---------------------------------------------------------------
jq -e . "$MANIFEST" >/dev/null 2>&1 && ok "plugin.json parses" || bad "plugin.json parses"
assert_eq "plugin name" pane-status "$(jq -r .name "$MANIFEST" 2>/dev/null)"
assert_eq "manifest keys are name/description/author only" '["author","description","name"]' \
  "$(jq -c 'keys' "$MANIFEST" 2>/dev/null)"
[ ! -e "$PLUGIN/SKILL.md" ] && ok "plugin dir carries no SKILL.md (hooks only)" \
  || bad "plugin dir carries no SKILL.md (hooks only)"

# --- hooks.json shape -------------------------------------------------------
jq -e . "$HOOKS" >/dev/null 2>&1 && ok "hooks.json parses" || bad "hooks.json parses"
assert_eq "exactly the six picker events" \
  '["Notification","SessionStart","Stop","SubagentStart","SubagentStop","UserPromptSubmit"]' \
  "$(jq -c '.hooks | keys' "$HOOKS" 2>/dev/null)"
assert_eq "one hook entry per event, six in all" 6 "$(jq '[.hooks[][].hooks[]] | length' "$HOOKS" 2>/dev/null)"
assert_eq "Notification matches every notification type" '*' "$(jq -r '.hooks.Notification[0].matcher' "$HOOKS" 2>/dev/null)"

for pair in UserPromptSubmit:start Notification:needs-input Stop:done \
            SubagentStart:agent-start SubagentStop:agent-stop SessionStart:session-start; do
  ev="${pair%%:*}" want="${pair#*:}"
  assert_eq "$ev: type command" command "$(jq -r ".hooks.$ev[0].hooks[0].type" "$HOOKS" 2>/dev/null)"
  assert_eq "$ev: timeout 5" 5 "$(jq -r ".hooks.$ev[0].hooks[0].timeout" "$HOOKS" 2>/dev/null)"
  assert_eq "$ev: synchronous" false "$(jq ".hooks.$ev[0].hooks[0].async == true" "$HOOKS" 2>/dev/null)"

  # --- the command resolves -------------------------------------------------
  cmd="$(jq -r ".hooks.$ev[0].hooks[0].command" "$HOOKS" 2>/dev/null)"
  case "$cmd" in
    '"${PANE_STATUS_BIN:-$HOME/.config/scripts/tmux}/claude-notify-hook.sh" '*) ok "$ev: command uses the PANE_STATUS_BIN form" ;;
    *) bad "$ev: command uses the PANE_STATUS_BIN form" "$cmd" ;;
  esac
  # Word-split the command the way the hook runner's shell would, with
  # PANE_STATUS_BIN pointed at the repo (HOME bogus so a fallback can't pass).
  # shellcheck disable=SC2016
  path="$(PANE_STATUS_BIN="$TMUX_DIR" HOME=/nonexistent bash -c 'eval "set -- $1"; printf %s "$1"' _ "$cmd")"
  # shellcheck disable=SC2016
  verb="$(PANE_STATUS_BIN="$TMUX_DIR" HOME=/nonexistent bash -c 'eval "set -- $1"; printf %s "${2:-}"' _ "$cmd")"
  [ -x "$path" ] && ok "$ev: claude-notify-hook.sh exists and is executable" || bad "$ev: script exists and is executable" "$path"
  assert_eq "$ev: verb" "$want" "$verb"
  /usr/bin/grep -qE "^[[:space:]]*${verb}\)" "$TMUX_DIR/claude-notify-hook.sh" \
    && ok "$ev: claude-notify-hook.sh dispatches $verb" || bad "$ev: claude-notify-hook.sh dispatches $verb"
done

# --- no duplicate wiring in settings ----------------------------------------
jq -e . "$SETTINGS" >/dev/null 2>&1 && ok "settings.recommended.json parses" || bad "settings.recommended.json parses"
assert_eq "no pane-status hook in settings.recommended.json" 0 \
  "$(jq '[.. | strings | select(test("claude-notify-hook"))] | length' "$SETTINGS")"

if [ "$fail" -eq 0 ]; then echo "ALL PASSED"; else echo "FAILED"; fi
exit "$fail"
