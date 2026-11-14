#!/usr/bin/env bash
# page-core.test.sh — runs the /decide page's DOM-free core (the block between
# the CORE markers in page/page.html) under node: tallies, grouping, accept
# logic, spec normalising and the svg sanitiser, plus node --check on every
# inline script. The DOM wiring is checked by hand on the first live publish.
#
# Run: bash page-core.test.sh        (PAGE=<html> overrides the page under test)
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(dirname "$SCRIPT_DIR")"
PAGE="${PAGE:-$SKILL_DIR/page/page.html}"
FIX="$SKILL_DIR/fixtures"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

FAIL=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; FAIL=1; }

if ! command -v node >/dev/null 2>&1; then
  echo "SKIP: node not found; page core checks not run"
  exit 0
fi

# Split the page's inline scripts to files, and the core block to a module.
node -e '
const fs = require("fs");
const html = fs.readFileSync(process.argv[1], "utf8");
let n = 0;
for (const m of html.matchAll(/<script(?![^>]*application\/json)[^>]*>([\s\S]*?)<\/script>/g)) fs.writeFileSync(process.argv[2] + "/inline-" + (n++) + ".js", m[1]);
const core = html.match(/\/\/ CORE:BEGIN[\s\S]*?\/\/ CORE:END/);
fs.writeFileSync(process.argv[2] + "/core.js", core ? core[0] + "\nmodule.exports = DC;\n" : "");
' "$PAGE" "$WORK"

bad=""
for f in "$WORK"/inline-*.js; do
  [ -e "$f" ] || break
  node --check "$f" 2>"$WORK/syntax.err" || bad="$bad $(basename "$f"): $(head -3 "$WORK/syntax.err")"
done
if [ -z "$bad" ] && ls "$WORK"/inline-*.js >/dev/null 2>&1; then pass "the inline scripts pass node --check"; else fail "inline script syntax:$bad"; fi

# check <name> <js>: runs with DC (the core), the fixtures dir and assert in scope; must print OK
check() {
  local out
  out="$(CORE="$WORK/core.js" FIX="$FIX" node -e "
    const assert = require('assert'), fs = require('fs');
    const DC = require(process.env.CORE);
    const load = (n) => JSON.parse(fs.readFileSync(process.env.FIX + '/' + n + '.json', 'utf8'));
    // A verdicts spec of n rows, every row with a suggestion, three areas.
    const big = (n) => ({ title: 'Big', layout: 'verdicts', verdicts: [{id:'fix',label:'Fix',tone:'good'},{id:'later',label:'Later'},{id:'skip',label:'Skip'}],
      items: Array.from({length: n}, (_, i) => ({ id: 'r' + i, title: 'Row ' + i, area: 'Area ' + (i % 3), suggested: ['fix','later','skip'][i % 3], reason: 'why ' + i })) });
    $2
    console.log('OK')" 2>&1)"
  if [ "$out" = "OK" ]; then pass "$1"; else fail "$1: $out"; fi
}

check "core loads from the page" "assert.strictEqual(typeof DC.summarize, 'function')"

check "30 suggested rows, 4 chosen, box off: 4 answered, 26 carried over" "
  const spec = DC.normalize(big(30));
  const ans = {}; for (let i = 0; i < 4; i++) ans['r' + i] = { choice: 'skip' };
  const s = DC.summarize(spec, ans, false);
  assert.strictEqual(s.answered, 4); assert.strictEqual(s.counts.chosen, 4); assert.strictEqual(s.counts.carried, 26);
  assert.strictEqual(s.counts.suggestion, 0);
  assert.ok(/4 chosen, 26 carried over; tick to take their suggestions/.test(DC.tallyText(spec, s)), DC.tallyText(spec, s));
  assert.strictEqual(s.byId.r10.value, '')"

check "30 suggested rows, 4 chosen, box on: 30 answered, 26 by suggestion" "
  const spec = DC.normalize(big(30));
  const ans = {}; for (let i = 0; i < 4; i++) ans['r' + i] = { choice: 'skip' };
  const s = DC.summarize(spec, ans, true);
  assert.strictEqual(s.answered, 30); assert.strictEqual(s.counts.suggestion, 26); assert.strictEqual(s.counts.chosen, 4);
  assert.strictEqual(s.byId.r10.value, 'later'); assert.strictEqual(s.byId.r0.value, 'skip')"

check "zero chosen, box off: nothing answered" "
  const spec = DC.normalize(big(30));
  const s = DC.summarize(spec, {}, false);
  assert.strictEqual(s.answered, 0); assert.strictEqual(s.counts.carried, 30);
  assert.ok(Object.values(s.byId).every((x) => x.value === ''))"

check "a row with no suggestion stays unanswered even with the box on" "
  const spec = DC.normalize(load('verdicts'));
  const s = DC.summarize(spec, {}, true);
  assert.strictEqual(s.byId.b2.status, 'unanswered'); assert.strictEqual(s.counts.unanswered, 1)"

check "items layout: one answered, blank item with a default takes it, no-default item is unanswered" "
  const spec = DC.normalize(load('items'));
  const s = DC.summarize(spec, { 'idle-after': { choice: '3m' } }, false);
  assert.strictEqual(s.byId['idle-after'].status, 'chosen');
  assert.deepStrictEqual(s.byId['busy-colour'], { status: 'default', value: 'amber' });
  assert.deepStrictEqual(s.byId.legend, { status: 'default', value: 'footer' });
  assert.strictEqual(s.byId['no-default'].status, 'unanswered');
  assert.deepStrictEqual(s.unansweredIds, ['no-default']);
  assert.strictEqual(s.counts.default, 2);
  assert.ok(/^Unanswered: Sort order of the picker\./.test(DC.tallyText(spec, s)), DC.tallyText(spec, s))"

check "items layout: with nothing answered, nothing is default taken" "
  const spec = DC.normalize(load('items'));
  const s = DC.summarize(spec, {}, false);
  assert.strictEqual(s.counts.default, 0); assert.strictEqual(s.answered, 0); assert.strictEqual(s.counts.unanswered, 4);
  // a note alone does not answer, so it does not unlock defaults either
  const n = DC.summarize(spec, { legend: { note: 'hm' } }, false);
  assert.strictEqual(n.counts.default, 0)"

check "a field edit with no pick is not a status: the core has no edited, the row counts as blank" "
  const spec = DC.normalize(load('verdicts'));
  const item = spec.items.find((i) => i.id === 'b3');
  assert.ok(!DC.STATUSES.includes('edited'));
  const a = DC.buildAnswer(item, null, { fields: { slug: 'x' } }, spec.rev, 'now');
  assert.strictEqual(a.fields_changed, true); assert.strictEqual(a.fields.slug, 'x'); assert.strictEqual(a.fields.size, 'S'); assert.strictEqual(a.rev, '2');
  const s = DC.summarize(spec, { b3: a }, false);
  assert.deepStrictEqual(s.byId.b3, { status: 'carried', value: '' }); assert.strictEqual(s.answered, 0);
  assert.strictEqual('edited' in s.counts, false);
  const same = DC.buildAnswer(item, null, { note: 'n' }, spec.rev, 'now');
  assert.strictEqual(same.fields_changed, false)"

check "answerAfterFieldEdit picks the suggestion on an empty choice, never overrides, picks nothing without one" "
  const spec = DC.normalize(load('verdicts'));
  const item = spec.items.find((i) => i.id === 'b3');
  assert.strictEqual(item.suggested, 'fix');
  const a = DC.answerAfterFieldEdit(spec, item, null, { slug: 'x' }, spec.rev, 'now');
  assert.strictEqual(a.choice, 'fix'); assert.strictEqual(a.fields.slug, 'x'); assert.strictEqual(a.fields_changed, true);
  assert.deepStrictEqual(DC.summarize(spec, { b3: a }, false).byId.b3, { status: 'chosen', value: 'fix' });
  const own = DC.answerAfterFieldEdit(spec, item, { choice: 'skip' }, { slug: 'x' }, spec.rev, 'now');
  assert.strictEqual(own.choice, 'skip');
  const cleared = DC.answerAfterFieldEdit(spec, item, { choice: '' }, { slug: 'x' }, spec.rev, 'now', true);
  assert.strictEqual(cleared.choice, '');
  const bare = spec.items.find((i) => !i.suggested);
  if (bare) { const n = DC.answerAfterFieldEdit(spec, bare, null, bare.fields[0] ? { [bare.fields[0].key]: 'y' } : {}, spec.rev, 'now'); assert.strictEqual(n.choice, ''); }
  const nos = { ...item, suggested: '' };
  assert.strictEqual(DC.answerAfterFieldEdit(spec, nos, null, { slug: 'x' }, spec.rev, 'now').choice, '')"

check "per-area counts sum to the header tally (both layouts, box on and off)" "
  for (const [name, accept, ans] of [['verdicts', false, { a1: { choice: 'fix' } }], ['verdicts', true, { a1: { choice: 'fix' } }], ['items', false, { legend: { choice: 'help' } }], ['triage', false, {}]]) {
    const spec = DC.normalize(load(name));
    const s = DC.summarize(spec, ans, accept);
    assert.strictEqual(s.areas.reduce((n, a) => n + a.total, 0), s.total, name);
    assert.strictEqual(s.areas.reduce((n, a) => n + a.answered, 0), s.answered, name);
    for (const st of DC.STATUSES) assert.strictEqual(s.areas.reduce((n, a) => n + a.counts[st], 0), s.counts[st], name + ' ' + st);
    assert.ok(s.areas.length >= 2 || name === 'triage');
  }
  const flat = DC.normalize({ title: 't', layout: 'items', items: [{ id: 'x', title: 'X', options: [] }] });
  assert.deepStrictEqual(DC.summarize(flat, {}, false).areas.map((a) => a.area), [''])"

check "areas keep spec order (first appearance)" "
  const s = DC.summarize(DC.normalize(load('verdicts')), {}, false);
  assert.deepStrictEqual(s.areas.map((a) => a.area), ['Parsing', 'Naming'])"

check "answers for ids not in the spec, and choices not in the options, are ignored" "
  const spec = DC.normalize(load('verdicts'));
  const s = DC.summarize(spec, { ghost: { choice: 'fix' }, a1: { choice: 'nonsense' } }, false);
  assert.strictEqual(s.answered, 0); assert.strictEqual(s.total, 6); assert.strictEqual(s.byId.ghost, undefined);
  assert.strictEqual(s.byId.a1.status, 'carried')"

check "90-row verdicts spec: counts, comment text and submitted doc carry the rev" "
  const spec = DC.normalize(big(90)); spec.rev = '7';
  const ans = {}; for (let i = 0; i < 12; i++) ans['r' + i] = { choice: 'fix' };
  const off = DC.summarize(spec, ans, false), on = DC.summarize(spec, ans, true);
  assert.strictEqual(off.answered, 12); assert.strictEqual(off.counts.carried, 78);
  assert.strictEqual(on.answered, 90); assert.strictEqual(on.counts.suggestion, 78);
  assert.ok(/rev 7: 90 of 90 answered/.test(DC.commentText(spec, on, false)));
  assert.ok(/^Resubmitted rev 7/.test(DC.commentText(spec, on, true)));
  const d = DC.submittedDoc(spec, on, { threadId: 't1', sent: true }, 'now');
  assert.strictEqual(d.rev, '7'); assert.strictEqual(d.accept_remaining, true); assert.strictEqual(d.threadId, 't1'); assert.strictEqual(d.counts.suggestion, 78);
  assert.strictEqual(DC.submittedDoc(spec, off, {}, 'now').accept_remaining, false)"

check "svg sanitiser strips script, foreignObject, on* attributes and javascript: links" "
  const dirty = '<svg viewBox=\"0 0 10 10\" onload=\"x()\"><script>alert(1)</script><foreignObject><div>hi</div></foreignObject><a href=\"javascript:alert(1)\"><circle r=\"2\" onclick=\"y()\" ONMOUSEOVER=\\'z()\\'/></a><scr<script>x</script>ipt>bad</script></svg>';
  const clean = DC.sanitizeSvg(dirty);
  assert.ok(!/script/i.test(clean), clean); assert.ok(!/foreignObject/i.test(clean), clean);
  assert.ok(!/\bon[a-z]+\s*=/i.test(clean), clean); assert.ok(!/javascript:/i.test(clean), clean);
  assert.ok(/<circle/.test(clean) && /viewBox/.test(clean), clean)"

check "link hrefs: https and relative pass, javascript: and data: do not" "
  assert.strictEqual(DC.safeHref('https://example.com/a'), 'https://example.com/a');
  assert.strictEqual(DC.safeHref('compare.html'), 'compare.html');
  assert.strictEqual(DC.safeHref('javascript:alert(1)'), ''); assert.strictEqual(DC.safeHref('data:text/html,x'), '');
  assert.strictEqual(DC.safeHref('//evil.example/x'), ''); assert.strictEqual(DC.safeHref('http://example.com'), '')"

for name in items verdicts triage; do
  check "fixture $name parses and normalises" "
    const spec = DC.normalize(load('$name'));
    assert.ok(spec.items.length > 0); assert.ok(spec.title);
    const s = DC.summarize(spec, {}, false); assert.strictEqual(s.total, spec.items.length)"
done

check "normalise rejects a spec with no layout or items" "
  assert.throws(() => DC.normalize({ title: 't', items: [] }), /layout/);
  assert.throws(() => DC.normalize({ title: 't', layout: 'items' }), /items/);
  assert.throws(() => DC.normalize(null), /object/)"

check "normalise defaults: rev 1, neutral tone, global note on unless false" "
  const s = DC.normalize({ title: 't', layout: 'verdicts', verdicts: [{id:'a',label:'A',tone:'purple'},{id:'b',label:'B'}], items: [{ id: 'x', title: 'X' }] });
  assert.strictEqual(s.rev, '1'); assert.strictEqual(s.verdicts[0].tone, 'neutral'); assert.ok(s.globalNote);
  assert.strictEqual(DC.normalize({ title: 't', layout: 'items', global_note: false, items: [] }).globalNote, null)"

exit $FAIL
