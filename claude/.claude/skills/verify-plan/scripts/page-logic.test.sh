#!/usr/bin/env bash
# page-logic.test.sh — runs the verify-plan pages' DOM-free render functions (the blocks
# between the CORE markers in templates/shared.js, shaping.html and map.html) under node,
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
const [shared, shaping, map, built, work] = process.argv.slice(1);
const core = (f) => { const m = fs.readFileSync(f, "utf8").match(/\/\/ CORE:BEGIN[\s\S]*?\/\/ CORE:END/); return m ? m[0] : ""; };
fs.writeFileSync(work + "/core.js", core(shared) + "\n" + core(shaping) + "\n" + core(map) + "\nmodule.exports = { VP: VP, VS: VS, VM: typeof VM === \"undefined\" ? null : VM };\n");
let n = 0;
for (const f of built.split(",")) {
  if (!fs.existsSync(f)) continue;
  for (const m of fs.readFileSync(f, "utf8").matchAll(/<script(?![^>]*application\/json)[^>]*>([\s\S]*?)<\/script>/g)) fs.writeFileSync(work + "/inline-" + (n++) + ".js", m[1]);
}
' "$SKILL_DIR/templates/shared.js" "$SKILL_DIR/templates/shaping.html" "$SKILL_DIR/templates/map.html" "$WORK/built/shaping.html,$WORK/built/map.html" "$WORK"

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
    const { VP, VS, VM } = require(process.env.CORE);
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

# ---------------------------------------------------------------- map page
check "the map core loads" "assert(VM, 'VM missing'); assert.strictEqual(typeof VM.page, 'function')"

check "a cell with a built and a planned test reports planned" "
  const c = VM.cell(d, 'R1', 'unit');
  assert.strictEqual(c.tests.length, 2);
  assert.deepStrictEqual(c.tests.map((i) => d.tests[i].status).sort(), ['built', 'planned']);
  assert.strictEqual(c.status, 'planned');
  assert.strictEqual(VM.worst(['built', 'planned']), 'planned');
  assert.strictEqual(VM.worst(['built', 'proposed', 'planned']), 'proposed');
  assert.strictEqual(VM.worst(['built']), 'built');
  assert.strictEqual(VM.worst([]), 'gap');"

check "a cell with no tests is a gap and the lane total leaves it out" "
  const c = VM.cell(d, 'R4', 'unit');
  assert.strictEqual(c.status, 'gap');
  const unit = VM.laneTotals(d).find((l) => l.id === 'unit');
  assert.strictEqual(unit.covered, 2);
  assert.strictEqual(unit.of, 4);
  d.tests = d.tests.filter((t) => !(t.lane === 'unit' && t.requirements.includes('R2')));
  assert.strictEqual(VM.laneTotals(d).find((l) => l.id === 'unit').covered, 1);"

check "a walkthrough cell is neutral before a run and the worst outcome after one" "
  const before = VM.cell(d, 'R1', 'walkthrough');
  assert.strictEqual(before.status, 'you');
  assert.strictEqual(before.steps.length, 2);
  d.run = { revision: 1, steps: { S1: { outcome: 'passed' }, S2: { outcome: 'failed' } } };
  assert.strictEqual(VM.cell(d, 'R1', 'walkthrough').status, 'failed');
  d.run.steps.S2.outcome = 'skipped';
  assert.strictEqual(VM.cell(d, 'R1', 'walkthrough').status, 'skipped');
  d.run.steps.S2.outcome = 'passed';
  assert.strictEqual(VM.cell(d, 'R1', 'walkthrough').status, 'passed');
  delete d.run.steps.S2;
  assert.strictEqual(VM.cell(d, 'R1', 'walkthrough').status, 'not-run', 'no recorded outcome counts as not run');
  assert.strictEqual(VM.cell(d, 'R4', 'walkthrough').status, 'gap');
  assert.strictEqual(VM.worstRun(['passed', 'skipped', 'not-run']), 'not-run');"

check "per-lane totals match the hand count" "
  const t = VM.laneTotals(d);
  const got = {};
  t.forEach((l) => (got[l.id] = [l.covered, l.of, l.notBuilt]));
  // Hand count: unit R1 R2; integration R1 R2 R3; end-to-end R3; walkthrough R1 R2 R3. Four requirements.
  assert.deepStrictEqual(got.unit, [2, 4, 2]);
  assert.deepStrictEqual(got.integration, [3, 4, 1]);
  assert.deepStrictEqual(got.e2e, [1, 4, 1]);
  assert.deepStrictEqual(got.walkthrough, [3, 4, 0]);"

check "the summary band counts match the hand count" "
  const b = VM.bandCounts(d);
  // R1 and R3 have a built test; R2 rests only on the walkthrough; R4 only waits on open decision D1.
  assert.strictEqual(b.total, 4);
  assert.strictEqual(b.builtReqs, 2);
  assert.strictEqual(b.youReqs, 1);
  assert.strictEqual(b.noneReqs, 0);
  assert.deepStrictEqual(b.waitIds, ['R4']);
  assert.strictEqual(b.pending, 4);
  assert.strictEqual(b.planned, 2);
  assert.strictEqual(b.proposed, 2);
  const html = VM.band(d);
  assert(html.includes('class=\"band\"'));"

check "the access summary says one step touches the cloud and none could affect prod" "
  const a = VM.accessSummary(d);
  assert.strictEqual(a.steps, 4);
  assert.strictEqual(a.cloud, 1);
  assert.strictEqual(a.prod, 0);
  assert.strictEqual(a.text, '1 of 4 steps touches the cloud; none could affect prod.');
  d.walkthrough.steps[0].access = ['cloud-write', 'prod', 'permission'];
  const b = VM.accessSummary(d);
  assert.strictEqual(b.cloud, 2);
  assert.strictEqual(b.prod, 1);
  assert(b.text.includes('1 could affect prod'), b.text);
  assert(b.text.includes('permission'), b.text);
  d.walkthrough.steps.forEach((s) => (s.access = ['local']));
  assert(VM.accessSummary(d).text.includes('local only'));"

check "each step shows risk and access, and beyond-local steps stand out" "
  const html = VM.walkthrough(d);
  const blocks = html.split('<div class=\"step').slice(1);
  assert.strictEqual(blocks.length, 4);
  const s3 = blocks.find((b) => b.includes('id=\"st-S3\"'));
  assert(s3.startsWith(' cloud'), 'cloud step is marked');
  assert(s3.includes('TOUCHES CLOUD'));
  assert(s3.includes(VP.esc(d.walkthrough.steps[2].risk)));
  const s1 = blocks.find((b) => b.includes('id=\"st-S1\"'));
  assert(!s1.startsWith(' cloud') && s1.includes('LOCAL ONLY'));
  assert(s1.includes('aria-expanded'));"

check "a step with no command shows its instruction as text with no copy control" "
  const blocks = VM.walkthrough(d).split('<div class=\"step').slice(1);
  const s2 = blocks.find((b) => b.includes('id=\"st-S2\"'));
  const step = d.walkthrough.steps[1];
  assert(!step.command);
  assert(s2.includes(VP.esc(step.instruction)));
  assert(!s2.includes('class=\"cp\"') && !s2.includes('data-copy'));
  const s1 = blocks.find((b) => b.includes('id=\"st-S1\"'));
  assert(s1.includes('data-copy=\"' + VP.esc(d.walkthrough.steps[0].command) + '\"'));
  assert(s1.includes('class=\"cp\"'));"

check "every grid test is labelled by its plain name, never a bare id" "
  const html = VM.grid(d);
  const names = new Set(d.tests.map((t) => t.name));
  const ids = new Set(d.tests.map((t) => t.id).concat(d.tests.map((t) => t.test_name)));
  const labels = [...html.matchAll(/<button type=\"button\" class=\"tl [^\"]*\" data-t=\"\d+\">([^<]*)</g)].map((m) => m[1]);
  assert.strictEqual(labels.length, 7, 'one tile per test and requirement pairing');
  labels.forEach((l) => { assert(names.has(l), 'label ' + l); assert(!ids.has(l)); });
  const ov = [...html.matchAll(/<span class=\"on\">([^<]*)</g)].map((m) => m[1]);
  ov.forEach((l) => assert(!ids.has(l), 'overview label ' + l));
  assert(d.tests.every((t) => html.includes(VP.esc(t.name))));
  assert(VM.testsList(d).includes(VP.esc(d.tests[0].name)));"

check "requirements elsewhere on the map are links to their card, not repeated sentences" "
  const page = VM.page(d);
  for (const r of d.requirements) assert.strictEqual(count(page, VP.esc(r.sentence)), 1, r.id);
  assert(VM.grid(d).includes('href=\"#r0\"'));"

check "a document without parts has no view toggle and no system view" "
  assert(VM.page(d).includes('id=\"vtog\"'));
  assert(VM.page(d).includes('class=\"sysv'));
  delete d.parts;
  d.tests.forEach((t) => { delete t.real_parts; delete t.faked_parts; });
  const page = VM.page(d);
  assert(!page.includes('id=\"vtog\"'));
  assert(!page.includes('sysv'));
  assert(page.includes('id=\"grid\"'));
  assert(!VM.testDetail(d, 0).includes('Real'), 'no part lines without parts');"

check "the system view marks parts no automated test runs for real" "
  assert.deepStrictEqual(VM.unreachedParts(d), ['notifier'].filter((p) => !d.tests.some((t) => t.real_parts.includes(p))));
  d.tests.forEach((t) => { t.real_parts = t.real_parts.filter((p) => p !== 'clock'); });
  assert(VM.unreachedParts(d).includes('clock'));
  const html = VM.system(d);
  assert(html.includes(VP.esc(d.parts[0].label)));
  assert(html.includes('unreached'));"

check "the title and summary show on both pages, and the task name stands in without a title" "
  assert(d.title && d.summary);
  for (const page of [VM.page(d), VS.page(d)]) {
    assert(page.includes('<h1>' + VP.esc(d.title) + '</h1>'));
    assert(page.includes(VP.esc(d.summary)));
  }
  delete d.title; delete d.summary;
  for (const page of [VM.page(d), VS.page(d)]) {
    assert(page.includes(VP.esc(d.task)));
    assert(!page.includes('class=\"sub\"'));
  }"

check "an accepted gap shows its reason on the card and marks its row on both pages" "
  const r = d.requirements[3];
  r.accepted_gap = 'Needs a second library branch to try.';
  assert(VP.reqCards(d).includes(VP.esc(r.accepted_gap)));
  const g = VM.grid(d);
  assert(g.includes('class=\"gap acc\"'), 'detail row');
  assert(g.includes('o-acc'), 'overview row');
  assert(VS.grid(d).includes('class=\"none acc\"'));
  const plain = VM.cell(d, 'R4', 'unit');
  assert.strictEqual(plain.status, 'gap');
  assert.strictEqual(VM.laneTotals(d).find((l) => l.id === 'unit').covered, 2);"

check "the map's stage bar marks the source's stage" "
  const page = VM.page(d);
  assert.strictEqual(count(page, 'aria-current=\"step\"'), 1);
  assert(page.includes('class=\"on\" aria-current=\"step\">2 &middot;'));"

check "the grid defaults to Overview only for longer lists" "
  assert.strictEqual(VM.defaultDensity(d), 'detail');
  for (let i = 0; i < 8; i++) d.requirements.push({ id: 'X' + i, label: 'Extra', sentence: 's', why: 'w', wrong_when: 'x', accepted_gap: 'later' });
  assert.strictEqual(VM.defaultDensity(d), 'over');"

check "map text with markup is escaped everywhere" "
  d.tests[0].name = '<img src=x onerror=alert(1)>';
  d.walkthrough.steps[0].title = '<b>t</b>';
  d.walkthrough.steps[1].instruction = 'Run <script>x</script>';
  const page = VM.page(d);
  assert(!page.includes('<img src=x'));
  assert(!page.includes('<b>t</b>'));
  assert(!page.includes('<script>x'));"

check "a requirement covered only by an open decision is marked as waiting, not as a gap" "
  assert.deepStrictEqual(VM.waitingOn(d, 'R4'), ['D1']);
  assert.deepStrictEqual(VM.waitingOn(d, 'R1'), []);
  const g = VM.grid(d);
  assert(g.includes('class=\"gap wait\"'), 'detail cell');
  assert(g.includes('Waits on D1'));
  assert(g.includes('o-wait'), 'overview cell');
  assert(g.includes('waits on D1'), 'row chip');
  const band = VM.band(d);
  assert(band.includes('Waiting on a decision'));
  assert(!band.includes('No proof at all'));
  d.decisions.find((x) => x.id === 'D1').status = 'answered';
  d.decisions.find((x) => x.id === 'D1').answer = 'fake-clock';
  d.requirements[3].accepted_gap = '';
  d.requirements[3].sentence = 'Four';
  assert.strictEqual(VM.bandCounts(d).noneReqs, 1);
  assert(VM.band(d).includes('No proof at all'));
  assert(!VM.grid(d).includes('Waits on D1'));"

check "the detail grid shows a status dot line per test, a compact walkthrough line, and a tentative marker" "
  const g = VM.grid(d);
  assert(g.includes('class=\"tl mt built\"'));
  assert(g.includes('class=\"tl mt planned\"'));
  assert(g.includes('class=\"tl mt proposed wait\"'), 'T5 rests on open D1');
  assert(g.includes('S1 &middot; ' + VP.esc(d.walkthrough.steps[0].title)));
  assert(!g.includes('<i>You run it'));"

check "the map has a section nav of anchors, and needs and unchecked boxes only when non-empty" "
  const page = VM.page(d);
  assert(page.includes('<nav class=\"secs\"'));
  ['sReq', 'sAuto', 'sWalk'].forEach((id) => { assert(page.includes('href=\"#' + id + '\"')); assert(page.includes('id=\"' + id + '\"')); });
  assert(page.includes('Not checked'));
  assert(page.includes(VP.esc(d.unchecked[0])));
  assert(page.includes('Planned work this needs'));
  assert(page.includes(VP.esc(d.needs[0])));
  d.unchecked = []; d.needs = [];
  const bare = VM.page(d);
  assert(!bare.includes('Not checked') && !bare.includes('Planned work this needs'));"

check "requirement links are joined with a comma that hugs the preceding link" "
  const html = VP.reqLinks(d, ['R1', 'R3']);
  assert(html.includes('</a>, <a'));
  assert(!html.includes(' ,'));
  assert.strictEqual(VP.reqLinks(d, []), '');
  assert(html.startsWith('<span class=\"rls\">'));"

# ---------------------------------------------------------------- run stage and results
# A seven-step copy of the fixture, with a run section recorded against it.
SEVEN="
  const base = d.walkthrough.steps;
  for (let n = 5; n <= 7; n++) base.push(Object.assign({}, base[0], { id: 'S' + n, title: 'Extra ' + n }));
  const mk = (o) => Object.assign({ skip_reason: '', output: '', note: '', time: '2026-11-16T10:00:00Z' }, o);
  d.run = { revision: 1, steps: {} };
  ['S1', 'S2', 'S3', 'S4', 'S5'].forEach((id) => (d.run.steps[id] = mk({ outcome: 'passed' })));
  d.run.steps.S6 = mk({ outcome: 'failed', note: 'Wrong order' });
"

check "pasted output from the source is returned escaped, never as markup" "
  $SEVEN
  d.stage = 'results';
  d.run.steps.S3 = mk({ outcome: 'passed', output: '<b>bold</b> </script><script>alert(1)</script> & x' });
  const html = VM.page(d);
  assert(html.includes('&lt;b&gt;bold&lt;/b&gt; &lt;/script&gt;&lt;script&gt;alert(1)&lt;/script&gt; &amp; x'));
  assert(!html.includes('<b>bold'));
  assert(!html.includes('</script>'));
  assert(!html.includes('<script>alert'));"

check "the Submit comment for 5 passed, 1 failed and 1 not run reads those three counts" "
  $SEVEN
  d.stage = 'run';
  const r = VM.resolve(d, {});
  const c = VM.counts(d, r.states);
  assert.deepStrictEqual([c.passed, c.failed, c.skipped, c.not_run, c.total], [5, 1, 0, 1, 7]);
  const text = VM.submitText(d, c, false);
  assert(text.includes('5 passed, 1 failed, 1 not run'), text);
  assert(text.includes('rev 1'));
  assert(!text.includes('skipped'), 'a zero count is left out');
  assert(text.includes('meta/submitted') && text.includes('steps'));
  assert.strictEqual(VM.progress(d, c), '6 of 7 done');
  c.skipped = 2;
  assert(VM.submitText(d, c, true).includes('2 skipped'));"

check "a source with a run section at stage run renders Submit; at stage results it does not" "
  $SEVEN
  d.stage = 'run';
  const run = VM.page(d);
  assert(run.includes('id=\"submit\"'));
  assert(run.includes('data-out=\"passed\"') && run.includes('data-out=\"failed\"') && run.includes('data-out=\"skipped\"'));
  d.stage = 'results';
  const res = VM.page(d);
  assert(!res.includes('id=\"submit\"'));
  assert(!res.includes('data-out='));
  assert(!res.includes('<textarea'));
  d.stage = 'map'; delete d.run;
  assert(!VM.page(d).includes('id=\"submit\"'), 'a plain map has no Submit');"

check "a stored step document from an older revision is shown as such and not counted" "
  $SEVEN
  d.stage = 'run'; delete d.run;
  const stored = { S1: { outcome: 'passed', rev: '0' }, S2: { outcome: 'failed', rev: '1' }, S3: { outcome: 'passed', rev: 1 } };
  const r = VM.resolve(d, stored);
  assert.deepStrictEqual(r.stale, ['S1']);
  assert.strictEqual(r.states.S1, undefined, 'not loaded as the current outcome');
  const c = VM.counts(d, r.states);
  assert.deepStrictEqual([c.passed, c.failed, c.not_run], [1, 1, 5]);
  assert(VM.page(d, { states: r.states, stale: r.stale }).includes('from an earlier version of the walkthrough'));
  assert(!VM.page(d, { states: r.states, stale: [] }).includes('from an earlier version'));"

check "a run recorded against an older walkthrough revision is never counted" "
  $SEVEN
  d.stage = 'run';
  d.walkthrough.revision = 2;
  assert.strictEqual(d.run.revision, 1);
  const r = VM.resolve(d, {});
  assert.deepStrictEqual(r.stale.slice().sort(), Object.keys(d.run.steps).sort());
  assert.deepStrictEqual(r.states, {});
  const c = VM.counts(d, r.states);
  assert.deepStrictEqual([c.passed, c.failed, c.skipped, c.not_run], [0, 0, 0, 7]);
  d.stage = 'results';
  const box = VM.resultsBox(d);
  assert(box.includes('7 steps)') && !box.includes('passed,') && box.includes('7 not run'), 'results count nothing');
  assert.strictEqual(VM.cell(d, 'R1', 'walkthrough').status, 'you');
  assert.strictEqual(VM.mode(d), 'results');
  d.stage = 'run';
  assert.strictEqual(VM.mode(d), 'run', 'the page still opens in run mode');
  assert(VM.page(d).includes('from an earlier version of the walkthrough'), 'the rendered page marks the run as stale');"

check "stored documents override the recorded run as the starting state" "
  $SEVEN
  const r = VM.resolve(d, { S1: { outcome: 'skipped', skip_reason: 'no time', rev: '1' } });
  assert.strictEqual(r.states.S1.outcome, 'skipped');
  assert.strictEqual(r.states.S2.outcome, 'passed', 'the recorded run is the base');
  assert.strictEqual(VM.counts(d, r.states).skipped, 1);"

check "the results page shows each outcome, a summary and every test's status, with a skip reason" "
  $SEVEN
  d.stage = 'results';
  d.run.steps.S7 = mk({ outcome: 'skipped', skip_reason: 'No cloud access today' });
  const page = VM.page(d);
  assert(page.includes('id=\"results\"'));
  assert(page.includes('5 passed, 1 failed, 1 skipped'), 'summary');
  assert(page.includes('No cloud access today'));
  assert(page.includes('Wrong order'));
  const box = VM.resultsBox(d);
  d.tests.forEach((t) => assert(box.includes(VP.esc(t.name)), t.name));
  assert(box.includes('Planned') && box.includes('Built'));
  assert(VM.cell(d, 'R1', 'walkthrough').status === 'failed', 'the grid lane agrees with the run');"

exit "$FAIL"
