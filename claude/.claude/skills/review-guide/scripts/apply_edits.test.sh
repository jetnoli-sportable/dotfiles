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

Run `check_KTD7` now. It has 3 callers. Second para about risk.

The R1 gate holds.
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
  {"id": "K-09", "old": "# Review T4", "new": "# Review the entrypoint"},
  {"id": "K-10", "old": "check_KTD7", "new": "check_KTD7 (decision seven)"},
  {"id": "K-11", "old": "now. It", "new": "now, so `it`"},
  {"id": "K-12", "old": "3 callers", "new": "13 callers"},
  {"id": "K-13", "old": "Second para about risk.", "new": "Second para about risk:\n```\nnote"},
  {"id": "K-14", "old": "R1 gate", "new": "R1 gate (requirement 1, the cite check)"}
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
expect "K-10: refused: protected" "part of an inline code span protected"
expect "K-11: refused: changes code spans" "new code span refused"
expect "K-12: refused: drops 3" "number grown into another (3 to 13) refused"
expect "K-13: refused: breaks structure" "new text opening a fence refused"
expect "K-14: applied" "expanding edit applied"
expect "3 applied, 11 not" "summary line"
/usr/bin/grep -q "the exit rules of T4, the Job entrypoint" "$WORK/page.md" && /usr/bin/grep -q "error table (KTD7)" "$WORK/page.md" \
  && pass "page written" || fail "page not written"
/usr/bin/grep -q "pairs with T4's exit rules" "$WORK/run/page.pre-clarity.md" \
  && pass "backup beside the report" || fail "no backup"

# a re-run against the same report changes nothing and keeps the first backup
out=$(python3 "$AE" "$WORK/page.md" "$WORK/run/clarity.json" --skip K-07 2>&1)
expect "K-14: refused: already applied" "re-run refuses an applied expanding edit"
expect "0 applied, 14 not" "re-run applies nothing"
[ "$(/usr/bin/grep -c 'requirement 1, the cite check' "$WORK/page.md")" = 1 ] \
  && /usr/bin/grep -q "pairs with T4's exit rules" "$WORK/run/page.pre-clarity.md" \
  && pass "re-run: one expansion, backup still the original" || fail "re-run doubled an edit or replaced the backup"

# dry run leaves the page alone
cp "$WORK/run/page.pre-clarity.md" "$WORK/page2.md"
python3 "$AE" "$WORK/page2.md" "$WORK/run/clarity.json" --dry-run >/dev/null
/usr/bin/grep -q "pairs with T4's exit rules" "$WORK/page2.md" && pass "dry run writes nothing" || fail "dry run wrote"

exit $FAIL
