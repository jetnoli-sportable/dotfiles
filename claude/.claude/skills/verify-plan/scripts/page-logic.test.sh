#!/usr/bin/env bash
# page-logic.test.sh — runs the verify-plan pages' DOM-free render functions (the blocks
# between the CORE markers in templates/shared.js and templates/shaping.html) under node,
# plus node --check on every inline script of a built page. The DOM wiring is checked by
# hand in a browser.
#
# Run: bash page-logic.test.sh
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(dirname "$SCRIPT_DIR")"
TOOL="$SCRIPT_DIR/verify-plan.py"
FIX="$SKILL_DIR/fixtures/example-verify.json"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

FAIL=0
pass() { echo "PASS: $1"; }
fail() {
  echo "FAIL: $1"
  FAIL=1
}

if ! command -v node >/dev/null 2>&1; then
  echo "SKIP: node not found; page logic checks not run"
  exit 0
fi

# Build the fixture into a temp copy, then split out the cores and the inline scripts.
mkdir -p "$WORK/built"
cp "$FIX" "$WORK/built/verify.json"
python3 "$TOOL" build "$WORK/built/verify.json" >"$WORK/build.out" 2>&1 || fail "build of the fixture failed: $(cat "$WORK/build.out")"

node -e '
const fs = require("fs");
const [shared, shaping, built, work] = process.argv.slice(1);
const core = (f) => { const m = fs.readFileSync(f, "utf8").match(/\/\/ CORE:BEGIN[\s\S]*?\/\/ CORE:END/); return m ? m[0] : ""; };
fs.writeFileSync(work + "/core.js", core(shared) + "\n" + core(shaping) + "\nmodule.exports = { VP: VP, VS: VS };\n");
if (fs.existsSync(built)) {
  let n = 0;
  for (const m of fs.readFileSync(built, "utf8").matchAll(/<script(?![^>]*application\/json)[^>]*>([\s\S]*?)<\/script>/g)) fs.writeFileSync(work + "/inline-" + (n++) + ".js", m[1]);
}
' "$SKILL_DIR/templates/shared.js" "$SKILL_DIR/templates/shaping.html" "$WORK/built/shaping.html" "$WORK"

bad=""
for f in "$WORK"/inline-*.js; do
  [ -e "$f" ] || break
  node --check "$f" 2>"$WORK/syntax.err" || bad="$bad $(basename "$f"): $(head -3 "$WORK/syntax.err")"
done
if [ -z "$bad" ] && ls "$WORK"/inline-*.js >/dev/null 2>&1; then pass "the built page's inline scripts pass node --check"; else fail "inline script syntax:${bad:- none found}"; fi

# check <name> <js>: runs with VP, VS, the fixture (d, a fresh copy per check) and assert in scope; must print OK
check() {
  local out
  out="$(CORE="$WORK/core.js" FIX="$FIX" node -e "
    const assert = require('assert'), fs = require('fs');
    const { VP, VS } = require(process.env.CORE);
    const d = JSON.parse(fs.readFileSync(process.env.FIX, 'utf8'));
    const count = (hay, needle) => hay.split(needle).length - 1;
    $2
    console.log('OK')" 2>&1)"
  if [ "$out" = "OK" ]; then pass "$1"; else fail "$1: $out"; fi
}

check "the cores load" "assert.strictEqual(typeof VP.reqCards, 'function'); assert.strictEqual(typeof VS.page, 'function')"

check "requirement cards hold each sentence exactly once" "
  const html = VP.reqCards(d);
  for (const r of d.requirements) assert.strictEqual(count(html, VP.esc(r.sentence)), 1, r.id);
  assert.strictEqual(count(VS.page(d), VP.esc(d.requirements[0].sentence)), 1, 'page-wide: defined once');"

check "a sentence with <b> and & is escaped" "
  d.requirements[0].sentence = 'Use <b>bold</b> & more';
  const html = VP.reqCards(d);
  assert(html.includes('Use &lt;b&gt;bold&lt;/b&gt; &amp; more'));
  assert(!html.includes('<b>bold'));
  assert(!VS.page(d).includes('<b>bold'));"

check "an answered decision shows its chosen option and note" "
  const dec = d.decisions.find((x) => x.status === 'answered');
  const html = VS.decision(d, dec);
  const chosen = dec.options.find((o) => o.id === dec.answer);
  assert(html.includes(VP.esc(chosen.label)));
  assert(html.includes(VP.esc(dec.note)));
  assert(html.includes('Change in /decide'));
  assert(!html.includes('Answer in /decide'));
  assert(!html.includes('Waiting for your answer'));"

check "an open decision shows the waiting state and the answer control" "
  const dec = d.decisions.find((x) => x.status === 'open');
  const html = VS.decision(d, dec);
  assert(html.includes('Waiting for your answer'));
  assert(html.includes('Answer in /decide'));
  assert(html.includes('data-copy=\"/verify-plan\"'));
  assert(!html.includes('Change in /decide'));
  assert(html.includes('Recommended'));"

check "a test resting on an open decision is tentative, then firm once answered" "
  const t = d.tests.find((x) => x.decision === 'D1');
  assert.strictEqual(VS.testState(d, t), 'tentative');
  assert(VS.grid(d).includes('class=\"tl tent\"'));
  assert(VS.testsList(d).includes('Tentative'));
  const dec = d.decisions.find((x) => x.id === 'D1');
  dec.status = 'answered'; dec.answer = 'fake-clock';
  assert.strictEqual(VS.testState(d, t), 'firm');
  assert(!VS.grid(d).includes('class=\"tl tent\"'));
  assert.strictEqual(VS.testState(d, d.tests[0]), 'firm');"

check "the stage bar marks the named stage and no other" "
  const names = ['shaping', 'map', 'run', 'results'];
  names.forEach((s, i) => {
    const links = VP.stageBar(s).split('<a ').slice(1);
    assert.strictEqual(links.length, 4);
    links.forEach((l, j) => assert.strictEqual(l.includes('aria-current=\"step\"'), i === j, s + ' link ' + j));
    assert(links[0].includes('href=\"shaping.html\"'));
    links.slice(1).forEach((l) => assert(l.includes('href=\"map.html\"')));
  });"

check "requirements elsewhere are links to their card, not repeated sentences" "
  const g = VS.grid(d);
  assert(g.includes('href=\"#r0\"'));
  for (const r of d.requirements) assert(!g.includes(VP.esc(r.sentence)), r.id);"

exit "$FAIL"
