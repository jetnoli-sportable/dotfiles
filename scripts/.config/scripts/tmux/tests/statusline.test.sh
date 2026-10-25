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

# --- per-session cache for claude-card.sh (CLAUDE_STATUS_CACHE_DIR) ---
tmp="$(mktemp -d)"
trap 'chmod -R u+w "$tmp"; rm -rf "$tmp"' EXIT
full='{"session_id":"abc-123","session_name":"s","model":{"id":"claude-x","display_name":"Opus"},"cost":{"total_cost_usd":1.25},"context_window":{"used_percentage":12}}'

cache="$tmp/cache"
out="$(printf '%s' "$full" | CLAUDE_STATUS_CACHE_DIR="$cache" COLUMNS=200 bash "$SL" | plain)"
assert "cache: printed line unchanged" '12% ctx · s · Opus$' "$out"
got="$(jq -c '[.session_id, .model, .cost_usd, .context_pct]' "$cache/abc-123.json" 2>&1)"
assert "cache: holds session, model, cost and context %" '^\["abc-123","Opus",1.25,12\]$' "$got"
ts="$(jq -r '.ts' "$cache/abc-123.json" 2>/dev/null)"
if [[ "$ts" =~ ^[0-9]+$ ]] && (( ts >= now && ts <= $(date +%s) )); then
  echo "ok   - cache: ts is the write time in epoch seconds"
else
  echo "FAIL - cache: ts is the write time in epoch seconds (got: $ts)"; fail=1
fi
assert "cache: no temp files left behind" '^abc-123\.json$' "$(ls -A "$cache")"

ro="$tmp/ro"; mkdir -p "$ro"; chmod 500 "$ro"
out="$(printf '%s' "$full" | CLAUDE_STATUS_CACHE_DIR="$ro" COLUMNS=200 bash "$SL" 2>&1; echo " rc=$?")"
assert "read-only cache dir: line still prints, exit 0" '12% ctx · s · Opus rc=0$' "$(printf '%s' "$out" | plain)"

nosid="$tmp/nosid"
out="$(printf '%s' '{"context_window":{"used_percentage":12},"session_name":"s","model":{"display_name":"Opus"}}' \
  | CLAUDE_STATUS_CACHE_DIR="$nosid" COLUMNS=200 bash "$SL" | plain)"
assert "no session_id: line prints" '12% ctx · s · Opus$' "$out"
if [ -e "$nosid" ] && [ -n "$(ls -A "$nosid")" ]; then
  echo "FAIL - no session_id: no cache written"; fail=1
else
  echo "ok   - no session_id: no cache written"
fi

bad="$tmp/bad"
printf '%s' '{"session_id":"../escape","model":{"display_name":"Opus"},"context_window":{"used_percentage":1}}' \
  | CLAUDE_STATUS_CACHE_DIR="$bad" COLUMNS=200 bash "$SL" >/dev/null
if [ -e "$tmp/escape.json" ] || { [ -e "$bad" ] && [ -n "$(ls -A "$bad")" ]; }; then
  echo "FAIL - unsafe session_id: no cache written"; fail=1
else
  echo "ok   - unsafe session_id: no cache written"
fi

exit "$fail"
