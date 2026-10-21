#!/usr/bin/env bash
# build-page.test.sh — tests for build-page.py (dossier .md -> .html).
# Run: ./build-page.test.sh
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILD="$SCRIPT_DIR/build-page.py"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

FAIL=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; FAIL=1; }
run() { uv run -q --with markdown python "$@"; }

# 1. fixture: nav entries, sections, unescaped SVG
D="$WORK/dossier"; mkdir -p "$D"
cat > "$D/guide.md" <<'MD'
---
title: Fixture Guide
eyebrow: test
updated: 2026-10-22
---
Intro text.

## First part

<figure><svg viewBox="0 0 10 10"><rect class="k-script" width="5" height="5"/></svg></figure>

## Second part

Body two.
MD
if run "$BUILD" "$D" guide >"$WORK/out.txt" 2>&1 && [ -f "$D/guide.html" ]; then
  H="$D/guide.html"
  navs=$(/usr/bin/grep -c 'href="#first-part"\|href="#second-part"' "$H")
  secs=$(/usr/bin/grep -c '<section id="\(first\|second\)-part">' "$H")
  [ "$navs" = 2 ] && pass "two nav entries" || fail "nav entries ($navs): $(cat "$WORK/out.txt")"
  [ "$secs" = 2 ] && pass "two sections" || fail "sections ($secs)"
  /usr/bin/grep -q '<svg viewBox="0 0 10 10"><rect class="k-script"' "$H" \
    && pass "svg unescaped" || fail "svg escaped or missing"
else
  fail "build failed: $(cat "$WORK/out.txt")"
fi

# 2. missing md
out=$(run "$BUILD" "$D" nope 2>&1); rc=$?
if [ $rc -ne 0 ] && [[ "$out" == *"$D/nope.md"* ]]; then pass "missing md exits non-zero naming path"
else fail "missing md (rc=$rc): $out"; fi

# 3. symlinked script still finds template
mkdir -p "$WORK/link"; ln -s "$BUILD" "$WORK/link/build-page.py"
rm -f "$D/guide.html"
if run "$WORK/link/build-page.py" "$D" guide >"$WORK/out.txt" 2>&1 && [ -f "$D/guide.html" ]; then
  pass "symlinked script finds template"
else fail "symlinked script: $(cat "$WORK/out.txt")"; fi

# 4. pipeline page parity (skipped when the dossier is absent)
P=/home/jetnoli/code/tasks/dossiers/dotfiles--skill-review-guide
if [ -f "$P/pipeline.md" ] && [ -f "$P/pipeline.html" ]; then
  mkdir -p "$WORK/pipe"; cp "$P/pipeline.md" "$WORK/pipe/"
  if run "$BUILD" "$WORK/pipe" pipeline >/dev/null 2>&1 && diff -q "$WORK/pipe/pipeline.html" "$P/pipeline.html" >/dev/null; then
    pass "pipeline page identical to dossier copy"
  else fail "pipeline page differs from dossier copy"; fi
else
  echo "SKIP: pipeline parity (dossier absent)"
fi

exit $FAIL
