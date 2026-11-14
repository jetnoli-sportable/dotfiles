#!/usr/bin/env bash
# render-check.test.sh — checks render-check.sh's usage errors, its
# no-renderer message, and (when a renderer is installed) that it writes a
# non-empty PNG with the fixed colour applied to the copy.
#
# Run: ./render-check.test.sh
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RC="$SCRIPT_DIR/render-check.sh"
WORK="$(mktemp -d)"
FAIL=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; FAIL=1; }
trap 'rm -rf "$WORK"' EXIT

cat > "$WORK/fixture.svg" <<'EOF'
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 300 120"><rect x="10" y="10" width="120" height="50" fill="none" stroke="currentColor"/><text x="70" y="40" text-anchor="middle" fill="currentColor">box A</text></svg>
EOF

# No argument: usage error, nonzero.
if bash "$RC" >/dev/null 2>&1; then fail "no argument exits nonzero"; else pass "no argument exits nonzero"; fi

# Missing file: exit 2.
bash "$RC" "$WORK/nope.svg" "$WORK/out" >/dev/null 2>&1
[ $? -eq 2 ] && pass "missing file exits 2" || fail "missing file exits 2"

# No renderer (Linux only; macOS always has qlmanage): exit 3 with the
# install hint.
if ! command -v qlmanage >/dev/null 2>&1; then
  err=$(PLAYWRIGHT_BROWSERS_PATH="$WORK/none" bash "$RC" "$WORK/fixture.svg" "$WORK/out" 2>&1 >/dev/null)
  code=$?
  [ $code -eq 3 ] && pass "no renderer exits 3" || fail "no renderer exits 3 (got $code)"
  [[ $err == *"playwright"*"install chromium-headless-shell"* ]] \
    && pass "no renderer prints the install command" \
    || fail "no renderer prints the install command: $err"
fi

# Real render, when a renderer exists.
png=$(bash "$RC" "$WORK/fixture.svg" "$WORK/out" 2>/dev/null)
code=$?
if [ $code -eq 3 ]; then
  echo "SKIP: no renderer installed, real render not checked"
else
  [ $code -eq 0 ] && [ -s "$png" ] && pass "renders a non-empty PNG" || fail "renders a non-empty PNG (code $code, '$png')"
  grep -q 'style="color:#222;background:#fff"' "$WORK/out/fixture.check.svg" \
    && pass "copy gets the fixed colour" || fail "copy gets the fixed colour"
  grep -q 'style=' "$WORK/fixture.svg" && fail "original left untouched" || pass "original left untouched"
fi

[ $FAIL -eq 0 ] && echo "ALL PASS" || { echo "SOME FAILED"; exit 1; }
