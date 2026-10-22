#!/usr/bin/env bash
# build-briefs.test.sh — tests for build-briefs.py (references/briefs.md -> <run>/briefs/).
# Run: ./build-briefs.test.sh
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILD="$SCRIPT_DIR/build-briefs.py"
REF="$SCRIPT_DIR/../references/briefs.md"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

FAIL=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; FAIL=1; }

inventory() {
  cat > "$1/inventory.json" <<'JSON'
{"files": [{"path": "src/a.sh", "bucket": "logic", "added": 10, "removed": 2, "hot": ["locking"]},
           {"path": "docs/x.html", "bucket": "generated", "added": 1, "removed": 1, "hot": []}],
 "hot": ["locking"], "proportion": {"ratio": 1.5}}
JSON
  echo "# Run context: fixture intent line" > "$1/context.md"
}
leftovers() { /usr/bin/grep -lE '<(run|worktree|base|head|pr|report|stack)>' "$1"/briefs/*.md; }

# 1. branch target: one L1, placeholders filled, shared rules verbatim
B="$WORK/branch"; mkdir -p "$B"; inventory "$B"
cat > "$B/target.json" <<'JSON'
{"kind": "branch", "branch": "fix/x", "base": "b0", "head": "h0", "worktree": "/wt/x", "prs": []}
JSON
if python3 "$BUILD" "$B" >"$WORK/out.txt" 2>&1; then
  [ -f "$B/briefs/L1.md" ] && [ -f "$B/briefs/L5.md" ] && [ -f "$B/briefs/coordinator-2.md" ] \
    && pass "branch: all briefs written" || fail "branch: missing briefs: $(ls "$B/briefs")"
  [ -z "$(leftovers "$B")" ] && pass "branch: no unfilled placeholders" || fail "branch: placeholders left in $(leftovers "$B")"
  /usr/bin/grep -q 'Report: `lens-L1.json`' "$B/briefs/L1.md" && /usr/bin/grep -q 'You review `fix/x`: diff `b0..h0`, worktree' "$B/briefs/L1.md" \
    && pass "branch: L1 names its report, pr and range" || fail "branch: L1 header"
  /usr/bin/grep -q 'fixture intent line' "$B/briefs/common.md" && /usr/bin/grep -q '`src/a.sh` | logic' "$B/briefs/common.md" \
    && /usr/bin/grep -q 'Skim list (don.t read):\*\* `docs/x.html`' "$B/briefs/common.md" \
    && pass "branch: common has context, inventory and skim list" || fail "branch: common content"
  # the shared rules land word for word (only <run> filled)
  want="$(sed -n '/^## Shared rules/,/^## L1 Risk/p' "$REF" | sed '$d' | sed "s#<run>#$B#g" | sed -e :a -e '/^\n*$/{$d;N;ba' -e '}' | sed '/^---$/d')"
  got="$(sed -n '/^## Shared rules/,$p' "$B/briefs/common.md")"
  [ "$(printf '%s' "$want" | sed '/^$/d')" = "$(printf '%s' "$got" | sed '/^$/d')" ] \
    && pass "branch: shared rules copied verbatim" || fail "branch: shared rules differ"
  ! /usr/bin/grep -q '^## Stack note' "$B/briefs/common.md" && pass "branch: no stack note" || fail "branch: stack note present"
else
  fail "branch run failed: $(cat "$WORK/out.txt")"
fi

# 2. stack target: one L1 per PR with its own range, stack note listing the PRs
S="$WORK/stack"; mkdir -p "$S"; inventory "$S"
cat > "$S/target.json" <<'JSON'
{"kind": "stack", "base": "b1", "head": "h2", "worktree": "/wt/tip",
 "prs": [{"number": 541, "head_ref": "feat/a", "base": "b1", "head": "h1", "worktree": "/wt/541"},
         {"number": 543, "head_ref": "feat/b", "base": "h1", "head": "h2", "worktree": "/wt/543"}]}
JSON
if python3 "$BUILD" "$S" >"$WORK/out.txt" 2>&1; then
  [ -f "$S/briefs/L1-541.md" ] && [ -f "$S/briefs/L1-543.md" ] && [ ! -f "$S/briefs/L1.md" ] \
    && pass "stack: one L1 brief per PR" || fail "stack: L1 briefs: $(ls "$S/briefs")"
  /usr/bin/grep -q 'Report: `lens-L1-543.json`' "$S/briefs/L1-543.md" && /usr/bin/grep -q 'diff `h1..h2`, worktree\s*$\|diff `h1..h2`, worktree' "$S/briefs/L1-543.md" \
    && /usr/bin/grep -q '/wt/543' "$S/briefs/L1-543.md" \
    && pass "stack: L1-543 uses its own report, range and worktree" || fail "stack: L1-543 header"
  /usr/bin/grep -q '^## Stack note' "$S/briefs/common.md" && /usr/bin/grep -q 'PR 541 (`feat/a`): `b1..h1`' "$S/briefs/common.md" \
    && pass "stack: common carries the stack note and PR list" || fail "stack: stack note"
  [ -z "$(leftovers "$S")" ] && pass "stack: no unfilled placeholders" || fail "stack: placeholders left in $(leftovers "$S")"
else
  fail "stack run failed: $(cat "$WORK/out.txt")"
fi

# 3. symlinked script still finds references/briefs.md
mkdir -p "$WORK/bin"; ln -s "$BUILD" "$WORK/bin/build-briefs.py"
python3 "$WORK/bin/build-briefs.py" "$B" >/dev/null 2>&1 && pass "symlinked script finds the references" || fail "symlinked script"

[ "$FAIL" = 0 ] && echo "ALL PASS" || { echo "SOME FAILED"; exit 1; }
