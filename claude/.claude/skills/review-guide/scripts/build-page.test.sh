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
run() { uv run -q --with markdown --with pygments python "$@"; }

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

# 4. review conventions: toggle, chips, risk badge, callouts, ranked cards, highlighting
cat > "$D/conv.md" <<'MD'
---
title: Conventions
---
## A. Overview

**Risk: medium.** Two spots matter.

**Recommendation:** fix spot 1 first.

## B. Review focus

### Where to look, ranked

**1. The lock handover, `wb-locks.sh:40`. Confirmed, high.**

```bash
if [ -e "$lock" ]; then echo held; fi
```

**2. The parser, `parse.sh:9`.**

- **L1-02** low, plausible · `parse.sh:9`: a stray fence survives.

**3. High-water mark off by one, `a.py:4`. Plausible, low.**

### Skim

**3. Not a spot:** numbered bold outside the ranked list stays a paragraph.

## C. Explainer

**Conclusion.** The handover is sound.

See [task decision D12](#task-d12).

<details markdown="1" id="task-d12">
<summary>Test counts in full</summary>

The four files pass: `plugin` 34 ok.

</details>
MD
if run "$BUILD" "$D" conv >"$WORK/out.txt" 2>&1; then
  H="$D/conv.html"
  /usr/bin/grep -q 'class="rail-toggle"' "$H" && /usr/bin/grep -q 'review-guide:rail' "$H" \
    && pass "sidebar toggle and its stored state" || fail "sidebar toggle missing"
  /usr/bin/grep -q '<span class="fid">L1-02</span> <span class="chip sev-low">low</span> <span class="chip v-plausible">plausible</span>' "$H" \
    && pass "finding id, severity and verdict chips" || fail "finding chips missing"
  /usr/bin/grep -q '<p class="callout risk sev-medium"><span class="badge">Risk: medium</span>' "$H" \
    && pass "risk badge" || fail "risk badge missing"
  /usr/bin/grep -q '<p class="callout rec"><strong' "$H" && /usr/bin/grep -q '<p class="callout concl">' "$H" \
    && pass "recommendation and conclusion callouts" || fail "callouts missing"
  cards=$(/usr/bin/grep -o 'class="spot sev-[a-z]*"' "$H" | tr '\n' ' ')
  [ "$cards" = 'class="spot sev-high" class="spot sev-low" class="spot sev-low" ' ] \
    && pass "three ranked cards; severity from the title's verdict, else from chips, never from a stray word" || fail "cards: $cards"
  /usr/bin/grep -q '<span class="chip sev-high">high</span> <span class="chip v-confirmed">confirmed</span>' "$H" \
    && pass "spot title verdict as chips" || fail "spot title chips missing"
  /usr/bin/grep -q '<div class="hl"><pre>.*<span class="k">if</span>' "$H" \
    && pass "fenced bash highlighted" || fail "no highlighted span in code block"
  /usr/bin/grep -q '<summary>Test counts in full</summary>' "$H" && /usr/bin/grep -q '<p>The four files pass: <code>plugin</code> 34 ok.</p>' "$H" \
    && pass "toggle block renders, with Markdown inside" || fail "toggle block not rendered"
  /usr/bin/grep -q '<details id="task-d12">' "$H" && /usr/bin/grep -q '<a href="#task-d12">task decision D12</a>' "$H" \
    && /usr/bin/grep -q 'el.tagName==="DETAILS") el.open=true' "$H" \
    && pass "a link to a toggle's id opens it" || fail "toggle id, link or opener missing"
else
  fail "conventions build failed: $(cat "$WORK/out.txt")"
fi

# 4b. comment verdict chips: only right after a **Comment N** label
cat > "$D/verd.md" <<'MD'
---
title: Verdicts
---
## Comments

**Comment 1** agree: the guard is missing.

**Comment 2** partly, the naming is fine.

**Comment 3** drop

**Comment 4** needs a look; we should drop the retry elsewhere.
MD
if run "$BUILD" "$D" verd >"$WORK/out.txt" 2>&1; then
  H="$D/verd.html"
  for v in agree partly drop; do
    /usr/bin/grep -q "<span class=\"chip v-$v\">$v</span>" "$H" \
      && pass "comment verdict chip: $v" || fail "no v-$v chip"
  done
  /usr/bin/grep -q '<strong>Comment 4</strong> needs a look; we should drop the retry' "$H" \
    && [ "$(/usr/bin/grep -o 'chip v-' "$H" | wc -l)" = 3 ] \
    && pass "no chip without a verdict word or for 'drop' in prose" || fail "stray verdict chip"
else
  fail "verdict build failed: $(cat "$WORK/out.txt")"
fi

# 5. pipeline page parity (skipped when the dossier is absent)
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
