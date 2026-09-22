#!/usr/bin/env bash
# Tests for claude/.claude/statusline.sh's plan-usage segment — the 5h and
# weekly rate-limit windows (rate_limits.{five_hour,seven_day}) with reset
# countdowns. Plain-bash assertions against synthetic statusLine payloads on
# stdin, same convention as tasks-agent-hook.test.sh (pure stdin-in, text-out
# filter; needs jq). Reset times are offsets from `now`, chosen mid-bucket so
# a second ticking over during the run can't change the rendered countdown.
#
# Run: bash scripts/.config/scripts/tmux/tests/statusline.test.sh
set -uo pipefail

SL="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../../.." && pwd)/claude/.claude/statusline.sh"

fail=0
assert() { # <desc> <expected-regex> <actual>
  if printf '%s' "$3" | grep -qE -- "$2"; then
    echo "ok   - $1"
  else
    echo "FAIL - $1"
    echo "       expected match: $2"
    echo "       got: $3"
    fail=1
  fi
}
refute() { # <desc> <unexpected-regex> <actual>
  if printf '%s' "$3" | grep -qE -- "$2"; then
    echo "FAIL - $1"
    echo "       unexpected match: $2"
    echo "       got: $3"
    fail=1
  else
    echo "ok   - $1"
  fi
}

# run <rate_limits-json-or-empty> — raw output (ANSI intact)
run() {
  local rl="${1:-}" payload='{"context_window":{"used_percentage":12},"session_name":"s","model":{"display_name":"Opus"}'
  [ -n "$rl" ] && payload="$payload,\"rate_limits\":$rl"
  printf '%s}' "$payload" | COLUMNS=200 bash "$SL"
}
plain() { sed 's/\x1b\[[0-9;]*m//g'; }

now=$(date +%s)

out="$(run "" | plain)"
assert "no rate_limits: base line renders" '12% ctx · s · Opus$' "$out"
refute "no rate_limits: no usage segment" '5h|wk' "$out"

out="$(run "{\"five_hour\":{\"used_percentage\":62.5,\"resets_at\":$((now + 4830))},\"seven_day\":{\"used_percentage\":18.2,\"resets_at\":$((now + 280000))}}" | plain)"
assert "both windows: 5h rounded pct + h/m countdown" '5h 63% ↻1h20m' "$out"
assert "both windows: weekly pct + d/h countdown, after 5h" '5h 63% ↻1h20m · wk 18% ↻3d5h$' "$out"

out="$(run "{\"five_hour\":{\"used_percentage\":3,\"resets_at\":$((now + 150))}}" | plain)"
assert "under an hour: minutes-only countdown" '5h 3% ↻2m$' "$out"
refute "only 5h present: no weekly part" 'wk' "$out"

out="$(run "{\"seven_day\":{\"used_percentage\":90,\"resets_at\":$((now - 5))}}" | plain)"
assert "past reset: pct still shown" 'wk 90%$' "$out"
refute "past reset: no countdown" '↻' "$out"

out="$(run "{\"five_hour\":{\"resets_at\":$((now + 100))}}" | plain)"
refute "window without used_percentage: part omitted" '5h' "$out"

out="$(run '{"five_hour":{"used_percentage":40,"resets_at":"2026-01-01T00:00:00Z"}}' | plain)"
assert "non-numeric resets_at: pct kept" '5h 40%$' "$out"

out="$(run "{\"five_hour\":{\"used_percentage\":90,\"resets_at\":$((now + 4830))}}")"
assert "traffic light: >=85% renders in the crit colour" $'\e\\[38;2;210;15;57m90%' "$out"

exit "$fail"
