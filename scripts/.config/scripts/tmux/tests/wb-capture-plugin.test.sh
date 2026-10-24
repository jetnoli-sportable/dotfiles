#!/usr/bin/env bash
# Tests for the wb-capture plugin wiring (U7, store auto-capture): the
# hooks-only skills-dir plugin at claude/.claude/skills/wb-capture/ parses,
# every hook command resolves (with WB_CAPTURE_BIN pointed at this repo's
# scripts) to an executable script and a verb wb-capture.sh dispatches, the
# Stop event carries exactly one sync and one async entry, there is no
# PostToolUse hook (the nudge machinery that used it is gone), and no capture hook
# is duplicated into settings.recommended.json (plugin + settings hooks both
# run, so a copy there would double-fire).
#
# Static checks only: no tmux, no claude, no hook is executed.
#
# Run: bash scripts/.config/scripts/tmux/tests/wb-capture-plugin.test.sh
set -uo pipefail

TMUX_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPO="$(cd "$TMUX_DIR/../../../.." && pwd)"
PLUGIN="$REPO/claude/.claude/skills/wb-capture"
HOOKS="$PLUGIN/hooks/hooks.json"
MANIFEST="$PLUGIN/.claude-plugin/plugin.json"
SETTINGS="$REPO/claude/.claude/settings.recommended.json"

fail=0
ok()   { echo "ok   - $1"; }
bad()  { echo "FAIL - $1${2:+ ($2)}"; fail=1; }
assert_eq()    { [ "$2" = "$3" ] && ok "$1" || bad "$1" "expected [$2], got [$3]"; }

# --- manifest ---------------------------------------------------------------
jq -e . "$MANIFEST" >/dev/null 2>&1 && ok "plugin.json parses" || bad "plugin.json parses"
assert_eq "plugin name" wb-capture "$(jq -r .name "$MANIFEST" 2>/dev/null)"
assert_eq "manifest keys are name/description/author only" '["author","description","name"]' \
  "$(jq -c 'keys' "$MANIFEST" 2>/dev/null)"
[ ! -e "$PLUGIN/SKILL.md" ] && ok "plugin dir carries no SKILL.md (hooks only)" \
  || bad "plugin dir carries no SKILL.md (hooks only)"

# --- hooks.json shape -------------------------------------------------------
jq -e . "$HOOKS" >/dev/null 2>&1 && ok "hooks.json parses" || bad "hooks.json parses"
assert_eq "events: UserPromptSubmit, Stop, SessionEnd" '["SessionEnd","Stop","UserPromptSubmit"]' \
  "$(jq -c '.hooks | keys' "$HOOKS")"
assert_eq "no PostToolUse hook registered" false "$(jq '.hooks | has("PostToolUse")' "$HOOKS")"
assert_eq "no hook command names hook-posttool" 0 "$(jq '[.. | strings | select(test("hook-posttool"))] | length' "$HOOKS")"
assert_eq "four hook entries in all" 4 "$(jq '[.hooks[][].hooks[]] | length' "$HOOKS")"
assert_eq "one sync Stop entry" 1 "$(jq '[.hooks.Stop[].hooks[] | select(.async != true)] | length' "$HOOKS")"
assert_eq "one async Stop entry" 1 "$(jq '[.hooks.Stop[].hooks[] | select(.async == true)] | length' "$HOOKS")"
assert_eq "the async Stop entry is the sweep" wb-capture-sweep.sh \
  "$(jq -r '.hooks.Stop[].hooks[] | select(.async == true) | .command' "$HOOKS" | grep -oE 'wb-capture-sweep\.sh')"
assert_eq "every sync entry has timeout 5" 3 \
  "$(jq '[.hooks[][].hooks[] | select(.async != true and .timeout == 5)] | length' "$HOOKS")"
assert_eq "every entry is type command" 4 "$(jq '[.hooks[][].hooks[] | select(.type == "command")] | length' "$HOOKS")"

# --- every command resolves -------------------------------------------------
expect_verb() { # event -> verb its command must pass ("" = the sweep, no verb)
  case "$1" in
    UserPromptSubmit) echo hook-prompt ;; SessionEnd) echo hook-end ;; Stop) echo "$2" ;;
  esac
}
while IFS=$'\t' read -r event mode cmd; do
  async=""; [ "$mode" = async ] && async=1
  case "$cmd" in
    '"${WB_CAPTURE_BIN:-$HOME/.config/scripts/tmux}/'*) ok "$event${async:+ async}: command uses the WB_CAPTURE_BIN form" ;;
    *) bad "$event${async:+ async}: command uses the WB_CAPTURE_BIN form" "$cmd" ;;
  esac
  # Word-split the command the way the hook runner's shell would, with
  # WB_CAPTURE_BIN pointed at the repo (HOME bogus so a fallback can't pass).
  # shellcheck disable=SC2016
  path="$(WB_CAPTURE_BIN="$TMUX_DIR" HOME=/nonexistent bash -c 'eval "set -- $1"; printf %s "$1"' _ "$cmd")"
  verb="$(WB_CAPTURE_BIN="$TMUX_DIR" HOME=/nonexistent bash -c 'eval "set -- $1"; printf %s "${2:-}"' _ "$cmd")"
  [ -x "$path" ] && ok "$event${async:+ async}: $(basename "$path") exists and is executable" \
    || bad "$event${async:+ async}: script exists and is executable" "$path"
  if [ -n "$async" ]; then
    assert_eq "$event async: sweep takes no verb" "" "$verb"
  else
    want="$(expect_verb "$event" hook-stop)"
    assert_eq "$event: verb" "$want" "$verb"
    grep -qE "^[[:space:]]+${verb}[|)]|[|]${verb}[|)]" "$TMUX_DIR/wb-capture.sh" \
      && ok "$event: wb-capture.sh dispatches $verb" || bad "$event: wb-capture.sh dispatches $verb"
  fi
done < <(jq -r '.hooks | to_entries[] | .key as $e | .value[].hooks[]
  | [$e, (if .async == true then "async" else "sync" end), .command] | @tsv' "$HOOKS")

# --- no duplicate wiring in settings ----------------------------------------
jq -e . "$SETTINGS" >/dev/null 2>&1 && ok "settings.recommended.json parses" || bad "settings.recommended.json parses"
assert_eq "no capture hook in settings.recommended.json" 0 \
  "$(jq '[.. | strings | select(test("wb-capture"))] | length' "$SETTINGS")"

if [ "$fail" -eq 0 ]; then echo "ALL PASSED"; else echo "FAILED"; fi
exit "$fail"
