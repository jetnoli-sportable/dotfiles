#!/usr/bin/env bash
# build-page.test.sh — tests for build-page.py (pragmatic-review .md -> .html).
# Run: ./build-page.test.sh
# The fixture is synthetic (a made-up bakery's ordering plan): no business content here.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILD="$SCRIPT_DIR/build-page.py"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

FAIL=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; FAIL=1; }
run() { uv run -q --with markdown --with pygments python "$@"; }
has() { /usr/bin/grep -q -- "$1" "$H"; }
count() { /usr/bin/grep -o -- "$1" "$H" | wc -l | tr -d ' '; }

D="$WORK/dossier"; mkdir -p "$D"
cat > "$D/review.md" <<'MD'
---
title: Pragmatic review: online ordering plan
eyebrow: Pragmatic review · example
updated: 2026-10-22
---
# Pragmatic review: online ordering plan

> **Input, not decisions: nothing here has been applied.** Findings for the owner.

Target: `plans/ordering.md` · Business: `example` · 2026-10-22

## Headlines

1. **Take orders by phone-form first.** The order page is the first real use; the
   loyalty scheme waits for repeat customers.
2. **Caching before the first order.** Nobody loads the menu twice yet.
   *Changes a settled decision:* the launch checklist.
3. Plain headline with no bold lead.

## Revised order

```order-diagram
{
  "lanes": [
    {"name": "As planned", "nodes": [
      {"id": "p1", "col": 0, "label": "S1", "sub": ["menu data"]},
      {"id": "p2", "col": 1, "label": "S2", "sub": ["menu cache"]},
      {"id": "p3", "col": 2, "label": "S3", "sub": ["order page"], "use": true}
    ]},
    {"name": "Revised", "nodes": [
      {"id": "r1", "col": 0, "label": "S1", "sub": ["menu data"]},
      {"id": "r3", "col": 1, "label": "S3", "sub": ["order page"], "use": true, "tag": "real orders"},
      {"id": "r2", "col": 2, "row": 0, "label": "S2", "moved": true},
      {"id": "r4", "col": 2, "row": 1, "label": "S4", "tag": "test data"}
    ]}
  ],
  "moves": [{"from": "p2", "to": "r2", "label": "after first use"}],
  "tags": {"real orders": "ok"},
  "band": {"from": 0, "to": 2, "label": "Start now: card-payment account"}
}
```

1. S1 — menu data
2. S3 — order page — moved up: it is the first real use
    - a nested note that says nothing about order
3. Parallel group A: S2, S4 — both read the menu

## Verdicts

Status in brackets is the task's own status.

| Step | Verdict | Trigger or reason | Flags | Settled | Source |
|---|---|---|---|---|---|
| S1 Menu data [doing] | needed now | everything reads it | — | | `plans/ordering.md#u1` |
| S2 Menu cache | **move** → after S3 | no repeat load yet | hardening before first use; blocks S3 | changes: launch checklist | `plans/ordering.md#u2` |
| S3 Order page | needed now | first real use | — | — | `plans/ordering.md#u3` |
| S4 Loyalty scheme | needed later | when 50 repeat customers | abstraction before second user | | `plans/ordering.md#u4` |
| S5 Multi-region | not needed, or needed later if a second shop opens | one shop | — | | `plans/ordering.md#u5` |

## Context used

- Facts from the learnings file: none (first run)

## Per-step options

Recommended option first.

**R0 — revised order.** Approve · approve with edits in notes · reject · Defer · Skip.

**S2 — menu cache.** (a) build after the order page ships · (b) keep it first · Defer · Skip.
*Changes a settled decision:* the launch checklist.

## Steps as extracted

```
S1. Menu data — deps: none — src: plans/ordering.md#u1
S2. Menu cache — deps: S1 — src: plans/ordering.md#u2
S3. Order page — deps: S2 — src: plans/ordering.md#u3
```

## Changes to apply

- none; this review is the record
MD

if run "$BUILD" "$D" review >"$WORK/out.txt" 2>&1 && [ -f "$D/review.html" ]; then
  H="$D/review.html"
  has '<title>Pragmatic review: online ordering plan</title>' && has 'pragmatic-review:rail' \
    && has "the pragmatic-review skill's <code>build-page.py</code>" \
    && pass "shared shell: title, own rail key, own generator credit" || fail "shell"
  [ "$(count 'href="#[a-z-]*"')" = 8 ] && pass "eight nav entries (overview + seven sections)" \
    || fail "nav entries: $(count 'href="#[a-z-]*"')"
  has '<blockquote class="input">' && has '<span class="badge">Input only</span>' \
    && pass "input banner" || fail "input banner"
  cards=$(/usr/bin/grep -o 'class="spot [a-z-]*"' "$H" | tr '\n' ' ')
  [ "$cards" = 'class="spot hl" class="spot sev-medium" class="spot hl" ' ] \
    && pass "three headline cards, the settled one amber" || fail "headline cards: $cards"
  has 'Settled decision it changes: the launch checklist' && pass "headline settled note" \
    || fail "headline settled note"
  has '<figure class="order"><svg viewBox="0 0 1040 ' && has 'class="k-moved"' && has 'class="k-use"' \
    && has 'class="mv"' && has '>after first use</text>' && has 'class="k-band"' \
    && pass "order diagram: moved and first-use boxes, move arrow with label, band" || fail "order diagram"
  has 'class="k-dot-ok"' && has 'class="t-tag"' && has '<i class="dotk ok"></i>real orders' \
    && has '<i class="dotk"></i>test data' && pass "diagram tags and their tones in the legend" \
    || fail "diagram tags"
  ! has 'order-diagram' && pass "diagram JSON not left in the page" || fail "diagram JSON leaked"
  has '<ol class="path">' && [ "$(count '<li class="moved">')" = 1 ] \
    && pass "revised order styled; only the item that says moved is marked" \
    || fail "path list (moved: $(count '<li class="moved">'))"
  vs=$(/usr/bin/grep -o 'data-v="[a-z]*" data-settled="[01]"' "$H" | tr '\n' ' ')
  [ "$vs" = 'data-v="now" data-settled="0" data-v="move" data-settled="1" data-v="now" data-settled="0" data-v="later" data-settled="0" data-v="notneeded" data-settled="0" ' ] \
    && pass "five verdict cards, keys and settled flag by column" || fail "verdict cards: $vs"
  has '<span class="status">doing</span>' && has '<span class="fid">S2</span>' \
    && pass "step id and status parsed" || fail "step id or status"
  [ "$(count 'split verdict')" = 1 ] && pass "split verdict marked once" || fail "split verdict"
  has 'class="seg seg-now"' && has 'Needed now · 2' && has '1 would change a settled decision' \
    && pass "verdict-count bar and legend" || fail "verdict bar"
  has 'data-f="all" aria-pressed="true">All 5' && has 'data-f="settled"' \
    && has 'c.dataset.settled==="1"' && pass "filter buttons and their script" || fail "filters"
  [ "$(count 'class="chip flag"')" = 3 ] && pass "flags as chips, dashes dropped" \
    || fail "flag chips: $(count 'class="chip flag"')"
  [ "$(count '<article class="opt')" = 2 ] && has '<article class="opt settled">' \
    && pass "two option cards, the settled one marked" || fail "option cards"
  [ "$(count '<li class="rec">')" = 2 ] && [ "$(count '<li class="dim">')" = 4 ] \
    && pass "first option recommended, Defer and Skip dimmed" || fail "option rows"
  has '<summary>Show all 3 steps' && pass "extracted steps collapsed" || fail "steps details"
  has '<p>Status in brackets' && has 'Facts from the learnings file' \
    && pass "non-convention text still renders" || fail "plain text lost"
else
  fail "build failed: $(cat "$WORK/out.txt")"
fi

# a page with none of the conventions still builds
cat > "$D/plain.md" <<'MD'
# Plain

## Verdicts

No table yet.
MD
run "$BUILD" "$D" plain >"$WORK/out.txt" 2>&1 && /usr/bin/grep -q 'No table yet.' "$D/plain.html" \
  && pass "plain page without conventions" || fail "plain page: $(cat "$WORK/out.txt")"

# bad diagram JSON fails loudly
printf '# Bad\n\n## Revised order\n\n```order-diagram\n{"lanes": [\n```\n' > "$D/bad.md"
out=$(run "$BUILD" "$D" bad 2>&1); rc=$?
[ $rc -ne 0 ] && [[ "$out" == *"order-diagram block is not valid JSON"* ]] \
  && pass "invalid diagram JSON exits non-zero with a reason" || fail "bad json (rc=$rc): $out"

# missing md
out=$(run "$BUILD" "$D" nope 2>&1); rc=$?
[ $rc -ne 0 ] && [[ "$out" == *"$D/nope.md"* ]] && pass "missing md exits non-zero naming path" \
  || fail "missing md (rc=$rc): $out"

# symlinked script still finds review-guide's shared core and template
mkdir -p "$WORK/link"; ln -s "$BUILD" "$WORK/link/build-page.py"; rm -f "$D/review.html"
run "$WORK/link/build-page.py" "$D" review >"$WORK/out.txt" 2>&1 && [ -f "$D/review.html" ] \
  && pass "symlinked script finds the shared core" || fail "symlinked script: $(cat "$WORK/out.txt")"

exit $FAIL
