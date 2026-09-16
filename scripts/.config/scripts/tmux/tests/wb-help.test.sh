#!/usr/bin/env bash
# Tests for `wb help` (cmd_help) and the dispatch's unknown-verb refusal.
#
# Unlike the other wb suites this one does NOT source wb.sh — both behaviours
# under test live in the CLI dispatch at the bottom of the file, which the
# `BASH_SOURCE[0]` guard deliberately skips when sourced. So every assertion
# here runs `bash wb.sh <args>` as a real subprocess, with a fixture HOME/
# TASKS_DIR (same isolation convention as wb-status.test.sh) and a stub tmux
# on PATH that records any call — `wb help` and an unknown verb must both be
# answerable without a tmux server.
# Run: bash scripts/.config/scripts/tmux/tests/wb-help.test.sh
set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WB="$SELF_DIR/wb.sh"

FIXTURE="$(mktemp -d -t wb-help-fixture.XXXXXX)"
trap 'rm -rf "$FIXTURE"' EXIT

fail=0
assert() { # <desc> <expected-regex> <actual>
  if printf '%s' "$3" | grep -qE "$2"; then
    echo "ok   - $1"
  else
    echo "FAIL - $1"
    echo "       expected match: $2"
    echo "       got: $(printf '%s' "$3" | head -8)"
    fail=1
  fi
}
assert_eq() { # <desc> <expected> <actual>
  if [ "$2" = "$3" ]; then
    echo "ok   - $1"
  else
    echo "FAIL - $1 (expected '$2', got '$3')"
    fail=1
  fi
}

export XDG_STATE_HOME="$FIXTURE/state"
export HOME="$FIXTURE/home"
export CODE_DIR="$FIXTURE/code"
export TASKS_DIR="$FIXTURE/tasks"
mkdir -p "$XDG_STATE_HOME" "$HOME" "$CODE_DIR" "$TASKS_DIR"

# Stub tmux: records every invocation and fails, so "did this path touch
# tmux at all" is a file-existence check rather than a guess.
STUB_BIN="$FIXTURE/bin"; mkdir -p "$STUB_BIN"
TMUX_CALLS="$FIXTURE/tmux-calls"
cat > "$STUB_BIN/tmux" <<STUB
#!/usr/bin/env bash
echo "\$@" >> "$TMUX_CALLS"
exit 1
STUB
chmod +x "$STUB_BIN/tmux"
export PATH="$STUB_BIN:$PATH"
unset TMUX

# =============================================================================
# Scenario: `wb help` prints the verb list.
# =============================================================================

out="$(bash "$WB" help 2>&1)"; rc=$?
assert_eq "wb help: exit 0" 0 "$rc"
assert "wb help: lists the status verb with its enum" \
  'wb status <task-ref> <prospective\|planned\|paused\|doing\|review>' "$out"
assert "wb help: lists the set verb" 'wb set <task-ref> <field> <value\|--unset>' "$out"
assert "wb help: names the live \$WB_SET_FIELDS allowlist, not a stale copy" \
  'fields: priority value size parent depends_on jira tags path' "$out"
assert "wb help: points at the guide" 'Guide: dotfiles/docs/wb-guide.md' "$out"

# The whole point of deriving the text from wb.sh's own header block: a verb
# added to the dispatch but not the header is caught here instead of being
# discovered the next time someone types `wb help` looking for it.
mapfile -t verbs < <(awk '
  /^if / && index($0, "BASH_SOURCE[0]") { at_guard = 1; next }
  at_guard && /^  case / { in_dispatch = 1; next }
  in_dispatch && /^  esac$/ { exit }
  in_dispatch && /^    [a-z]/ {
    split($0, p, ")"); v = p[1]; gsub(/^ +/, "", v)
    split(v, alts, "|")
    if (alts[1] ~ /^_/) next          # picker-internal callbacks
    if (alts[1] == "render") next     # fzf reload hook, not a user verb
    if (alts[1] == "help") next       # documented as `wb help`, printed as its own line
    print alts[1]
  }
' "$WB")
assert_eq "dispatch verb scrape found a plausible number of verbs" 1 \
  "$([ "${#verbs[@]}" -ge 15 ] && echo 1 || echo 0)"
missing=""
for v in "${verbs[@]}"; do
  printf '%s' "$out" | grep -qE "^  wb $v( |\$)" || missing="$missing $v"
done
assert_eq "every public dispatch verb appears in wb help" "" "$missing"

assert_eq "wb help: answered without touching tmux" 0 \
  "$([ -f "$TMUX_CALLS" ] && echo 1 || echo 0)"

# --help / -h are the same screen.
out_long="$(bash "$WB" --help 2>&1)"; rc_long=$?
out_short="$(bash "$WB" -h 2>&1)"; rc_short=$?
assert_eq "--help: exit 0" 0 "$rc_long"
assert_eq "-h: exit 0" 0 "$rc_short"
assert_eq "--help prints the same screen as help" "$out" "$out_long"
assert_eq "-h prints the same screen as help" "$out" "$out_short"

# =============================================================================
# Scenario: an unknown token is a typo, not a picker query.
# =============================================================================

rm -f "$TMUX_CALLS"
out="$(bash "$WB" stauts 2>&1)"; rc=$?
assert_eq "unknown verb: exit 2" 2 "$rc"
assert "unknown verb: names the token and points at wb help" \
  "wb: unknown verb 'stauts' — try wb help" "$out"
assert_eq "unknown verb: never reached tmux (no picker)" 0 \
  "$([ -f "$TMUX_CALLS" ] && echo 1 || echo 0)"

# A flag-shaped typo takes the same path (it is not a verb either).
out="$(bash "$WB" --boards 2>&1)"; rc=$?
assert_eq "unknown flag: exit 2" 2 "$rc"
assert "unknown flag: names the token" "unknown verb '--boards'" "$out"

# Bare `wb` still means the picker — it reaches tmux/fzf rather than erroring
# out with exit 2. (The stub tmux fails, so this only asserts the ROUTING:
# bare wb is not the unknown-verb path.)
rm -f "$TMUX_CALLS"
out="$(bash "$WB" 2>&1)"; rc=$?
assert_eq "bare wb: not the unknown-verb refusal" 0 \
  "$([ "$rc" = 2 ] && echo 1 || echo 0)"
assert_eq "bare wb: still routes to the picker" 0 \
  "$(printf '%s' "$out" | grep -qc "unknown verb" 2>/dev/null || echo 0)"

if [ "$fail" -eq 0 ]; then echo "ALL PASS"; else echo "FAILURES"; fi
exit "$fail"
