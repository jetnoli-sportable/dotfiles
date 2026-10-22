#!/usr/bin/env bash
# apply_edits.test.sh — tests for apply_edits.py (clarity sweep edits -> page source).
# Run: ./apply_edits.test.sh
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AE="$SCRIPT_DIR/apply_edits.py"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

FAIL=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; FAIL=1; }

mkdir -p "$WORK/run"
cat > "$WORK/page.md" <<'MD'
---
title: T4 page
---
# Review T4

This pairs with T4's exit rules.

**Risk: low.** Per KTD7 it is fine.

**1. The parser, `parse.sh:9`.** It is the commit point.

- **L1-02** low, plausible · `parse.sh:9`: a stray fence survives 2 times.

```bash
echo T4
```

T4 again here. T4 again here.
MD
cat > "$WORK/run/clarity.json" <<'JSON'
{ "edits": [
  {"id": "K-01", "old": "pairs with T4's exit rules", "new": "pairs with the exit rules of T4, the Job entrypoint"},
  {"id": "K-02", "old": "Per KTD7 it", "new": "Per the plan's error table (KTD7) it"},
  {"id": "K-03", "old": "T4 again here.", "new": "x"},
  {"id": "K-04", "old": "echo T4", "new": "echo Job"},
  {"id": "K-05", "old": "a stray fence survives 2 times", "new": "a stray fence survives"},
  {"id": "K-06", "old": "**Risk: low.** Per", "new": "Risk is low. Per"},
  {"id": "K-07", "old": "It is the commit point.", "new": "It decides which run wins."},
  {"id": "K-08", "old": "not in the page", "new": "y"},
  {"id": "K-09", "old": "# Review T4", "new": "# Review the entrypoint"}
] }
JSON
out=$(python3 "$AE" "$WORK/page.md" "$WORK/run/clarity.json" --skip K-07 2>&1)
expect() { [[ "$out" == *"$1"* ]] && pass "$2" || fail "$2 (wanted '$1'): $out"; }
expect "K-01: applied" "plain edit applied"
expect "K-02: applied" "second edit applied"
expect "K-03: refused: old not unique" "non-unique old refused"
expect "K-04: refused: protected" "fenced code protected"
expect "K-05: refused: drops 2" "dropped number refused"
expect "K-06: refused: breaks risk badge" "renderer form kept"
expect "K-07: skipped" "skip list honoured"
expect "K-08: refused: old not found" "missing old refused"
expect "K-09: refused: protected" "heading protected"
expect "2 applied, 7 not" "summary line"
/usr/bin/grep -q "the exit rules of T4, the Job entrypoint" "$WORK/page.md" && /usr/bin/grep -q "error table (KTD7)" "$WORK/page.md" \
  && pass "page written" || fail "page not written"
/usr/bin/grep -q "pairs with T4's exit rules" "$WORK/run/page.pre-clarity.md" \
  && pass "backup beside the report" || fail "no backup"

# dry run leaves the page alone
cp "$WORK/run/page.pre-clarity.md" "$WORK/page2.md"
python3 "$AE" "$WORK/page2.md" "$WORK/run/clarity.json" --dry-run >/dev/null
/usr/bin/grep -q "pairs with T4's exit rules" "$WORK/page2.md" && pass "dry run writes nothing" || fail "dry run wrote"

exit $FAIL
