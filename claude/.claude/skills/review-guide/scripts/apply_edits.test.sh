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

Still open on the fix branch.
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
  {"id": "K-11", "old": "now. It", "new": "now, so ` it"},
  {"id": "K-12", "old": "3 callers", "new": "13 callers"},
  {"id": "K-13", "old": "Second para about risk.", "new": "Second para about risk:\n```\nnote"},
  {"id": "K-14", "old": "R1 gate", "new": "R1 gate (requirement 1, the cite check)"},
  {"id": "K-15", "old": "on the fix branch", "new": "on the fix branch `fix/x`"}
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
expect "K-11: refused: changes code spans" "lone backtick refused"
expect "K-12: refused: drops 3" "number grown into another (3 to 13) refused"
expect "K-13: refused: breaks structure" "new text opening a fence refused"
expect "K-14: applied" "expanding edit applied"
expect "K-15: applied" "edit adding a whole code span applied"
expect "4 applied, 11 not" "summary line"
/usr/bin/grep -q "the exit rules of T4, the Job entrypoint" "$WORK/page.md" && /usr/bin/grep -q "error table (KTD7)" "$WORK/page.md" \
  && pass "page written" || fail "page not written"
/usr/bin/grep -q "pairs with T4's exit rules" "$WORK/run/page.pre-clarity.md" \
  && pass "backup beside the report" || fail "no backup"

# a re-run against the same report changes nothing and keeps the first backup
out=$(python3 "$AE" "$WORK/page.md" "$WORK/run/clarity.json" --skip K-07 2>&1)
expect "K-14: refused: already applied" "re-run refuses an applied expanding edit"
expect "0 applied, 15 not" "re-run applies nothing"
[ "$(/usr/bin/grep -c 'requirement 1, the cite check' "$WORK/page.md")" = 1 ] \
  && /usr/bin/grep -q "pairs with T4's exit rules" "$WORK/run/page.pre-clarity.md" \
  && pass "re-run: one expansion, backup still the original" || fail "re-run doubled an edit or replaced the backup"

# with target.json, the backup is named by the reviewed head; new commits get a new backup
mkdir -p "$WORK/run3"
printf 'Page at the first head.\n' > "$WORK/page3.md"
echo '{"edits": [{"id": "K-01", "old": "Page at", "new": "This page is at"}]}' > "$WORK/run3/clarity.json"
echo '{"head": "aaaaaaa1111"}' > "$WORK/run3/target.json"
python3 "$AE" "$WORK/page3.md" "$WORK/run3/clarity.json" >/dev/null
printf 'Page at the second head.\n' > "$WORK/page3.md"  # re-synthesised after new commits
echo '{"head": "bbbbbbb2222"}' > "$WORK/run3/target.json"
python3 "$AE" "$WORK/page3.md" "$WORK/run3/clarity.json" >/dev/null
/usr/bin/grep -q "first head" "$WORK/run3/page3.pre-clarity.aaaaaaa.md" \
  && /usr/bin/grep -q "^Page at the second head" "$WORK/run3/page3.pre-clarity.bbbbbbb.md" \
  && pass "backup per reviewed head; the first head's backup kept" || fail "head-keyed backups: $(ls "$WORK/run3")"

# trim and toggle edits
mkdir -p "$WORK/run4"
cat > "$WORK/page4.md" <<'MD'
Intro para with 5 tests and `x.sh`.

See L1-02 for the cause.

The background: it ran 3 times before.

**Recommendation:** fix it.

Mid line text here.

Another aside.
MD
cat > "$WORK/run4/clarity.json" <<'JSON'
{ "edits": [
  {"id": "T-01", "kind": "trim", "old": "Intro para with 5 tests and `x.sh`.", "new": "Intro para."},
  {"id": "T-02", "kind": "trim", "old": "See L1-02 for the cause.", "new": "See below."},
  {"id": "T-03", "kind": "toggle", "old": "The background: it ran 3 times before.", "summary": "Background"},
  {"id": "T-04", "kind": "toggle", "old": "**Recommendation:** fix it.", "summary": "Advice"},
  {"id": "T-05", "kind": "toggle", "old": "line text", "summary": "Part"},
  {"id": "T-06", "kind": "toggle", "old": "Another aside.", "summary": " "},
  {"id": "T-07", "kind": "jargon", "old": "Another aside.", "new": "Another aside.\n<details>"},
  {"id": "T-08", "kind": "jargon", "old": "Intro para.", "new": "Intro."}
] }
JSON
out=$(python3 "$AE" "$WORK/page4.md" "$WORK/run4/clarity.json" 2>&1)
expect "T-01: applied (trim)" "trim may drop a number and a code span"
expect "T-02: refused: trims finding id" "trim never touches a paragraph with a finding id"
expect "T-03: applied (toggle)" "toggle wraps a whole block"
expect "T-04: refused: toggles recommendation callout" "toggle never hides a callout"
expect "T-05: refused: not a whole block" "toggle of part of a line refused"
expect "T-06: refused: no summary" "toggle needs a summary"
expect "T-07: refused: breaks structure" "plain edit adding a toggle tag refused"
expect "T-08: applied" "later edit sees the earlier trim"
/usr/bin/grep -qzF $'<details markdown="1">\n<summary>Background</summary>\n\nThe background: it ran 3 times before.\n\n</details>' "$WORK/page4.md" \
  && pass "toggle block written" || fail "toggle block not written: $(cat "$WORK/page4.md")"
out=$(python3 "$AE" "$WORK/page4.md" "$WORK/run4/clarity.json" 2>&1)
expect "T-03: refused: already applied" "re-run refuses an applied toggle"

# what a toggle or trim must not hide, and toggle placement
mkdir -p "$WORK/run5"
cat > "$WORK/page5.md" <<'MD'
The script writes `<details markdown="1">` around the text.

- Skim: covered by L1-06, L1-07 and L1-09.

**C-01** The cache is never cleared.

**Risk: medium.** Two reasons: the lock in `lock.py:42`, and 3 retries.

1. First step.
2. Second step.
3. Third step.

Background worth folding.

Plain prose here.
MD
cat > "$WORK/run5/clarity.json" <<'JSON'
{ "edits": [
  {"id": "U-01", "kind": "toggle", "old": "- Skim: covered by L1-06, L1-07 and L1-09.", "summary": "Skim list"},
  {"id": "U-02", "kind": "toggle", "old": "**C-01** The cache is never cleared.", "summary": "Cache"},
  {"id": "U-03", "kind": "trim", "old": " Two reasons: the lock in `lock.py:42`, and 3 retries.", "new": ""},
  {"id": "U-04", "kind": "toggle", "old": "2. Second step.", "summary": "Step"},
  {"id": "U-05", "kind": "toggle", "old": "Background worth folding.", "summary": "Why <b>this</b>"},
  {"id": "U-06", "kind": "jargon", "old": "Plain prose here.", "new": "Plain prose. <details><summary>x</summary>"}
] }
JSON
out=$(python3 "$AE" "$WORK/page5.md" "$WORK/run5/clarity.json" 2>&1)
expect "U-01: refused: toggles finding id" "toggle never hides bare finding ids"
expect "U-02: refused: toggles finding id" "toggle never hides a bold id with no severity"
expect "U-03: refused: trims risk badge" "trim never cuts a risk's reasons"
expect "U-04: refused: not a whole block" "toggle of one list item refused"
expect "U-05: applied (toggle)" "a <details> in a code span doesn't count as an open toggle"
expect "U-06: refused: breaks structure" "plain edit adding a mid-line toggle tag refused"
/usr/bin/grep -qF '<summary>Why &lt;b&gt;this&lt;/b&gt;</summary>' "$WORK/page5.md" \
  && pass "toggle summary escaped" || fail "summary not escaped: $(cat "$WORK/page5.md")"

# dry run leaves the page alone
cp "$WORK/run/page.pre-clarity.md" "$WORK/page2.md"
python3 "$AE" "$WORK/page2.md" "$WORK/run/clarity.json" --dry-run >/dev/null
/usr/bin/grep -q "pairs with T4's exit rules" "$WORK/page2.md" && pass "dry run writes nothing" || fail "dry run wrote"

exit $FAIL
