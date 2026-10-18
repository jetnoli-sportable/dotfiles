#!/usr/bin/env bash
# review-page.test.sh — smoke test for review-page.py: starts the server
# with a 3-item fixture spec, curls the page, POSTs a submit payload, and
# asserts answers.json + buffer-state came out right.
#
# Run: ./review-page.test.sh
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORK="$(mktemp -d)"
SPEC="$WORK/spec.json"
OUT="$WORK/answers.json"
STATE="$OUT.buffer-state"
LOG="$WORK/server.log"
PORT=58732

FAIL=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; FAIL=1; }

cleanup() {
  [ -n "${SERVER_PID:-}" ] && kill "$SERVER_PID" 2>/dev/null
  [ -n "${SERVER2_PID:-}" ] && kill "$SERVER2_PID" 2>/dev/null
  [ -n "${SERVER3_PID:-}" ] && kill "$SERVER3_PID" 2>/dev/null
  [ -n "${REATTACH2_PID:-}" ] && kill "$REATTACH2_PID" 2>/dev/null
  rm -rf "$WORK"
}
trap cleanup EXIT

cat > "$SPEC" <<'EOF'
{
  "title": "Fixture Review",
  "intro_md": "Test fixture — **three** items.",
  "sections": [{"title": "Fixture section", "md": "## Directions\n- alpha\n- beta", "open": true}],
  "context": {"task": "fixture--task", "here": "this page", "stages": [
    {"name": "Round 1", "state": "done"}, {"name": "Round 2", "state": "current"}, {"name": "Apply", "state": "upcoming"}]},
  "verdicts": [
    {"id": "apply", "label": "Apply", "color": "#a6e3a1"},
    {"id": "defer", "label": "Defer", "color": "#f9e2af"},
    {"id": "skip", "label": "Skip", "color": "#f38ba8"}
  ],
  "areas": [
    {
      "id": "area-a",
      "title": "Area A",
      "note": "First area.",
      "items": [
        {
          "id": "item-1",
          "title": "First item",
          "where": "foo.py:10",
          "what": "Does a thing that's tricky",
          "evidence": ["evidence one", "evidence two"],
          "suggested": "apply",
          "suggested_reason": "clear win",
          "depends_on": [],
          "depended_on_by": ["item-2"],
          "links": [],
          "meta": [["size", "M"], ["owner", "jet"]],
          "description": "### Plan\n- step one\n- step two\n\n1. first\n2. second\n\n```\ncode here\n```\n\nTail para with ``` unclosed fence\n- after fence bullet",
          "fields": [{"key": "slug", "label": "slug", "value": "feat/one"}]
        },
        {
          "id": "item-2",
          "title": "Second item",
          "where": "bar.py:20",
          "what": "Depends on item-1",
          "evidence": "single evidence string",
          "suggested": "defer",
          "suggested_reason": "unclear priority",
          "depends_on": ["item-1"],
          "depended_on_by": [],
          "links": [{"label": "PR", "href": "https://example.com"}],
          "prior": {"note": "why defer?", "reply": "it touches call sites"}
        },
        {
          "id": "item-3",
          "title": "Third item",
          "where": "baz.py:30",
          "what": "Standalone",
          "evidence": "",
          "suggested": "",
          "suggested_reason": "",
          "depends_on": [],
          "depended_on_by": [],
          "links": []
        }
      ]
    }
  ],
  "close_rule": "accept_defaults=false means only touched rows apply."
}
EOF

python3 "$SCRIPT_DIR/review-page.py" --spec "$SPEC" --out "$OUT" --port "$PORT" \
  > "$LOG" 2>&1 &
SERVER_PID=$!

# Wait for the server to come up (no polling loop with a long sleep; short
# bounded retries against the HTTP port).
UP=0
for i in $(seq 1 50); do
  if curl -s -o /dev/null "http://127.0.0.1:$PORT/"; then
    UP=1
    break
  fi
  sleep 0.1
done

if [ "$UP" -ne 1 ]; then
  fail "server did not come up on port $PORT"
  cat "$LOG"
  exit 1
fi
pass "server came up"

BODY="$(curl -s "http://127.0.0.1:$PORT/")"
PAGE="$WORK/page.html"
printf '%s' "$BODY" > "$PAGE"
if [[ "$BODY" == *'<title>Fixture Review</title>'* ]]; then
  pass "GET / returns 200 with title present"
else
  fail "title not found in page body"
fi
if ! /usr/bin/grep -q '{{[A-Z_]*}}' "$PAGE"; then pass "page has no unfilled placeholders"; else fail "page still holds an unfilled placeholder"; fi

# --- page script under node (the page renders in the browser from the embedded spec) -------------
if ! command -v node >/dev/null 2>&1; then
  echo "SKIP: node not found; page script checks not run"
else
  KIT_JS="$(dirname "$SCRIPT_DIR")/../decision-page/kit/kit.js"
  python3 - "$PAGE" "$WORK" <<'PY'
import re, sys
html = open(sys.argv[1], encoding="utf-8").read()
for n, m in enumerate(re.finditer(r'<script(?![^>]*application/json)[^>]*>(.*?)</script>', html, re.S)):
    open("%s/inline-%d.js" % (sys.argv[2], n), "w", encoding="utf-8").write(m.group(1))
core = re.search(r'// CORE:BEGIN.*?// CORE:END', html, re.S)
open("%s/core.js" % sys.argv[2], "w", encoding="utf-8").write(core.group(0) + "\nif (typeof module !== 'undefined') module.exports = RP;\n" if core else "")
PY
  bad=""
  for f in "$WORK"/inline-*.js; do node --check "$f" 2>"$WORK/syntax.err" || bad="$bad $(basename "$f"): $(head -3 "$WORK/syntax.err")"; done
  if [ -z "$bad" ] && ls "$WORK"/inline-*.js >/dev/null 2>&1; then pass "the page's inline scripts pass node --check"; else fail "inline script syntax:$bad"; fi

  # check <name> <js>: runs with RP (the page's core block), Kit, the fixture spec (raw, and normalized as spec) and assert in scope; must print OK
  check() {
    local out
    out="$(KIT="$KIT_JS" CORE="$WORK/core.js" SPECFILE="$SPEC" PAGE="$PAGE" node -e "
      const assert=require('assert'),fs=require('fs');
      globalThis.Kit=require(process.env.KIT);
      const RP=require(process.env.CORE);
      const raw=JSON.parse(fs.readFileSync(process.env.SPECFILE,'utf8'));
      const spec=RP.normalize(raw), H='ab12';
      const byId=id=>spec.items.find(i=>i.id===id);
      $2
      console.log('OK')" 2>&1)"
    if [ "$out" = "OK" ]; then pass "$1"; else fail "$1: $out"; fi
  }

  check "page embeds the spec so it round-trips through JSON.parse" "
    const html=fs.readFileSync(process.env.PAGE,'utf8');
    const m=html.match(/<script id=\"spec\" type=\"application\/json\">([\s\S]*?)<\/script>/);
    assert.deepStrictEqual(JSON.parse(m[1]),raw)"

  check "markdown renders headings, ordered and bullet lists, fences; ' and < are escaped; an unclosed fence keeps the tail" "
    const h=RP.mdBlock(byId('item-1').description);
    assert.ok(h.includes('<h5 class=\"md-h\">Plan</h5>'),h);
    assert.ok(h.includes('<ul class=\"md-ul\"><li>step one</li><li>step two</li></ul>'));
    assert.ok(h.includes('<ol class=\"md-ol\"><li>first</li><li>second</li></ol>'));
    assert.ok(h.includes('<pre class=\"md-pre\">code here</pre>'));
    assert.ok(RP.mdBlock('it\'s <b>x</b>').includes('it&#39;s &lt;b&gt;x&lt;/b&gt;'));
    const u=RP.mdBlock('intro\n\`\`\`\nnever closed\n- after bullet');
    assert.ok(u.includes('<li>after bullet</li>')&&!u.includes('<pre'),u)"

  check "editable fields render in the details panel; editing one sets touched and fields_changed" "
    const i=byId('item-1'), html=RP.rowHtml(spec,i);
    assert.ok(html.includes('data-field-key=\"slug\"')&&html.includes('value=\"feat/one\"'),html);
    const st=RP.loadState({});
    let a=RP.buildAnswers(spec,H,st).items.find(x=>x.id==='item-1');
    assert.strictEqual(a.touched,false);assert.strictEqual(a.fields_changed,false);assert.deepStrictEqual(a.fields,{slug:'feat/one'});
    st.items['item-1']={fields:{slug:'feat/two'}};
    a=RP.buildAnswers(spec,H,st).items.find(x=>x.id==='item-1');
    assert.strictEqual(a.touched,true);assert.strictEqual(a.fields_changed,true);assert.deepStrictEqual(a.fields,{slug:'feat/two'})"

  check "sections render as collapsible panels with block markdown, open only when asked" "
    const h=RP.sectionsHtml(spec);
    assert.ok(h.includes('<details class=\"ev page-section\" open><summary>Fixture section</summary>'),h);
    assert.ok(h.includes('<ul class=\"md-ul\"><li>alpha</li><li>beta</li></ul>'));
    assert.ok(!RP.sectionsHtml({sections:[{title:'t',md:'x'}]}).includes(' open'))"

  check "links render as real anchors" "
    const h=RP.rowHtml(spec,byId('item-2'));
    assert.ok(h.includes('<a href=\"https://example.com\" target=\"_blank\" rel=\"noopener\">PR</a>'),h)"

  check "meta pairs render as chips, where as a chip, and depends_on / depended_on_by as chips that point at the named row" "
    const h1=RP.rowHtml(spec,byId('item-1')), h2=RP.rowHtml(spec,byId('item-2'));
    assert.ok(h1.includes('<span class=\"meta-chip\"><span class=\"meta-k\">size</span> M</span>')&&h1.includes('owner'),h1);
    assert.ok(h1.includes('foo.py:10'));
    assert.ok(h1.includes('data-dep=\"item-2\"')&&h1.includes('href=\"#r1\"'),'depended_on_by chip');
    assert.ok(h2.includes('data-dep=\"item-1\"')&&h2.includes('href=\"#r0\"'),'depends_on chip')"

  check "intro and close_rule sit in the band, each area's note under its heading" "
    const b=RP.bandHtml(spec);
    assert.ok(b.includes('Test fixture')&&b.includes('accept_defaults=false means only touched rows apply.'),b);
    assert.ok(RP.mainHtml(spec).includes('<p class=\"note\">First area.</p>'))"

  check "a spec with accept_defaults_default false renders the box unticked and posts accept_defaults false; a saved choice wins" "
    const off=RP.normalize({...raw,accept_defaults_default:false});
    assert.ok(!RP.closingHtml(RP.acceptOf(off,RP.loadState({}))).includes(' checked'));
    assert.ok(RP.closingHtml(RP.acceptOf(spec,RP.loadState({}))).includes(' checked'));
    assert.strictEqual(RP.buildAnswers(off,H,RP.loadState({})).accept_defaults,false);
    assert.strictEqual(RP.buildAnswers(spec,H,RP.loadState({})).accept_defaults,true);
    assert.strictEqual(RP.acceptOf(off,RP.loadState({accept:true})),true);
    assert.strictEqual(RP.buildAnswers(spec,H,RP.loadState({accept:false})).accept_defaults,false)"

  check "payload with every row untouched: verdict = suggested, touched false, untouched_count = rows, a no-suggestion row keeps an empty verdict" "
    const p=RP.buildAnswers(spec,H,RP.loadState({}));
    assert.deepStrictEqual(Object.keys(p),['spec_hash','accept_defaults','global_note','untouched_count','items']);
    assert.strictEqual(p.spec_hash,H);assert.strictEqual(p.untouched_count,3);assert.strictEqual(p.items.length,3);
    for(const i of p.items){assert.strictEqual(i.touched,false);assert.strictEqual(i.verdict,i.suggested);
      assert.deepStrictEqual(Object.keys(i),['id','verdict','suggested','touched','group','note','fields','fields_changed'])}
    assert.strictEqual(p.items[2].verdict,'');assert.strictEqual(p.items[2].suggested,'')"

  check "touched rows: a pick, an agree, a group and a note each mark the row touched; a note keeps the suggested verdict; a stale verdict is ignored" "
    const st=RP.loadState({items:{'item-1':{verdict:'skip'},'item-2':{note:'why?'},'item-3':{agreed:true,verdict:'gone'}}});
    const p=RP.buildAnswers(spec,H,st), by=id=>p.items.find(i=>i.id===id);
    assert.strictEqual(by('item-1').verdict,'skip');assert.strictEqual(by('item-1').touched,true);
    assert.strictEqual(by('item-2').verdict,'defer');assert.strictEqual(by('item-2').touched,true);assert.strictEqual(by('item-2').note,'why?');
    assert.strictEqual(by('item-3').touched,true);assert.strictEqual(by('item-3').verdict,'');
    assert.strictEqual(p.untouched_count,0);
    assert.strictEqual(RP.touched(spec,byId('item-1'),{group:'g1'}),true)"

  check "a row with no suggestion or an 'unclear' reason is flagged needs you; resolving it clears the flag" "
    assert.ok(RP.needsYou(byId('item-2'))&&RP.needsYou(byId('item-3'))&&!RP.needsYou(byId('item-1')));
    assert.strictEqual(RP.stats(spec,RP.loadState({})).need,2);
    assert.strictEqual(RP.stats(spec,RP.loadState({items:{'item-3':{verdict:'skip'},'item-2':{agreed:true}}})).need,0)"

  check "Agree-all in an area skips rows that need you" "
    const left=RP.areaStats(spec,0,RP.loadState({})).left.map(i=>i.id);
    assert.deepStrictEqual(left,['item-1'])"

  check "a spec with context and a prior renders the stage strip and the earlier-note marker; one without renders neither" "
    assert.ok(RP.bandHtml(spec).includes('class=\"stages\"')&&RP.bandHtml(spec).includes('You are here: this page'));
    assert.ok(RP.rowHtml(spec,byId('item-2')).includes('Earlier note')&&RP.rowHtml(spec,byId('item-2')).includes('it touches call sites'));
    assert.ok(!RP.rowHtml(spec,byId('item-1')).includes('Earlier note'));
    const bare=RP.normalize({...raw,context:undefined,areas:raw.areas.map(a=>({...a,items:a.items.map(({prior,...r})=>r)}))});
    assert.ok(!RP.bandHtml(bare).includes('stages'));
    assert.ok(!RP.mainHtml(bare).includes('Earlier note'))"

  check "two specs never share saved answers: the storage key carries the spec hash" "
    assert.notStrictEqual(RP.stateKey('aaa'),RP.stateKey('bbb'));
    assert.strictEqual(RP.stateKey('aaa'),'review-page:aaa');
    assert.deepStrictEqual(RP.loadState('junk'),{items:{},gq:'',accept:undefined})"

  check "a spec holding only ids renders with no undefined text" "
    const min=RP.normalize({areas:[{items:[{id:'x'},{}]}]});
    const all=RP.bandHtml(min)+RP.sidebarHtml(min)+RP.mainHtml(min)+RP.glanceHtml(min,RP.loadState({}))+RP.closingHtml(true);
    assert.ok(!/undefined|null|NaN/.test(all),all.match(/.{20}(undefined|null|NaN).{20}/));
    assert.strictEqual(min.items[1].id,'item-2')"
fi

# the spec text can never end the <script> it is embedded in
python3 - "$SCRIPT_DIR" "$WORK/xss.html" <<'PY'
import importlib.util, sys
sp = importlib.util.spec_from_file_location("rp", sys.argv[1] + "/review-page.py")
m = importlib.util.module_from_spec(sp); sp.loader.exec_module(m)
base = m.render_page({"areas": []}, "t", "h")
page = m.render_page({"areas": [{"id": "a", "items": [{"id": "x", "what": "</script><script>alert(1)</script> <!-- {{TITLE}}"}]}]}, "t", "h")
open(sys.argv[2], "w").write(page)
ok = (page.count("<script") == base.count("<script") and "<!-- {{" not in page
      and "<title>t</title>" in page and "\\u003c!-- {{TITLE}}" in page)  # the placeholder text stays literal inside the JSON
sys.exit(0 if ok else 1)
PY
if [ $? -eq 0 ]; then pass "spec text with </script>, <!-- and a placeholder adds no script element and is not substituted"; else fail "script-escape guard"; fi

SPEC_HASH="$(sha256sum "$SPEC" | awk '{print $1}')"

SUBMIT_PAYLOAD=$(cat <<EOF
{
  "spec_hash": "$SPEC_HASH",
  "accept_defaults": true,
  "global_note": "test global note",
  "items": [
    {"id": "item-1", "verdict": "apply", "suggested": "apply", "touched": true, "group": "g1", "note": ""},
    {"id": "item-2", "verdict": "skip", "suggested": "defer", "touched": true, "group": "g1", "note": "why override?"},
    {"id": "item-3", "verdict": "", "suggested": "", "touched": false, "group": "", "note": ""},
    {"id": "item-4", "verdict": "defer", "suggested": "defer", "touched": true, "group": "", "note": ""}
  ],
  "untouched_count": 1
}
EOF
)

BAD_HASH_STATUS="$(curl -s -o /dev/null -w '%{http_code}' -X POST -H 'Content-Type: application/json' \
  -d '{"spec_hash":"deadbeef","items":[]}' "http://127.0.0.1:$PORT/submit")"
if [ "$BAD_HASH_STATUS" = "409" ]; then pass "POST /submit with a foreign spec_hash is rejected (409)"; else fail "foreign spec_hash returned $BAD_HASH_STATUS, expected 409"; fi
XORIGIN_STATUS="$(curl -s -o /dev/null -w '%{http_code}' -X POST -H 'Content-Type: application/json' \
  -H 'Origin: http://evil.example' -d "$SUBMIT_PAYLOAD" "http://127.0.0.1:$PORT/submit")"
if [ "$XORIGIN_STATUS" = "403" ]; then pass "cross-origin POST /submit is rejected (403)"; else fail "cross-origin submit returned $XORIGIN_STATUS, expected 403"; fi
CTYPE_STATUS="$(curl -s -o /dev/null -w '%{http_code}' -X POST -H 'Content-Type: text/plain' \
  -d "$SUBMIT_PAYLOAD" "http://127.0.0.1:$PORT/submit")"
if [ "$CTYPE_STATUS" = "415" ]; then pass "non-JSON content type is rejected (415)"; else fail "text/plain submit returned $CTYPE_STATUS, expected 415"; fi
if [ -s "$OUT" ]; then fail "rejected submits must not write answers.json"; else pass "rejected submits wrote nothing"; fi

SUBMIT_STATUS="$(curl -s -o /tmp/review-page-test-submit-resp.$$ -w '%{http_code}' \
  -X POST -H 'Content-Type: application/json' -H "Origin: http://127.0.0.1:$PORT" -d "$SUBMIT_PAYLOAD" \
  "http://127.0.0.1:$PORT/submit")"
rm -f "/tmp/review-page-test-submit-resp.$$"

if [ "$SUBMIT_STATUS" = "200" ]; then
  pass "POST /submit returns 200"
else
  fail "POST /submit returned $SUBMIT_STATUS"
fi

# Give the server thread a moment to write answers.json and rewrite state
# after unblocking (bounded retries, not a long sleep).
FOUND=0
for i in $(seq 1 50); do
  if [ -s "$OUT" ]; then FOUND=1; break; fi
  sleep 0.1
done

if [ "$FOUND" -ne 1 ]; then
  fail "answers.json was not written"
else
  if python3 -c "
import json, sys
d = json.load(open('$OUT'))
assert d.get('accept_defaults') is True, 'accept_defaults not true'
assert d.get('global_note') == 'test global note', 'global_note mismatch'
items = {i['id']: i for i in d.get('items', [])}
assert items['item-1']['verdict'] == 'apply', 'item-1 verdict wrong'
assert items['item-2']['verdict'] == 'skip', 'item-2 verdict wrong'
assert items['item-2']['note'] == 'why override?', 'item-2 note wrong'
assert items['item-3']['touched'] is False, 'item-3 touched wrong'
assert d.get('untouched_count') == 1, 'untouched_count wrong: %r' % d.get('untouched_count')
assert items['item-4']['touched'] is True, 'item-4 (agreed) touched wrong'
assert items['item-4']['verdict'] == items['item-4']['suggested'] == 'defer', 'item-4 (agreed) verdict/suggested mismatch'
print('ok')
" > /tmp/review-page-test-check.$$ 2>&1; then
    pass "answers.json content matches submitted payload"
  else
    fail "answers.json content check failed: $(cat /tmp/review-page-test-check.$$)"
  fi
  rm -f "/tmp/review-page-test-check.$$"
fi

# Wait for the background process to exit (it exits right after writing
# state + signaling tmux, if present).
wait "$SERVER_PID" 2>/dev/null
SERVER_PID=""

if [ -f "$STATE" ]; then
  CLOSED_VAL="$(grep '^closed=' "$STATE" | cut -d= -f2)"
  MODE_VAL="$(grep '^mode=' "$STATE" | cut -d= -f2)"
  if [ "$CLOSED_VAL" = "1" ] && [ "$MODE_VAL" = "review-page" ]; then
    pass "buffer-state closed=1, mode=review-page"
  else
    fail "buffer-state closed/mode wrong: closed=$CLOSED_VAL mode=$MODE_VAL"
  fi
else
  fail "buffer-state file missing"
fi

# =============================================================================
# --reattach
# =============================================================================

# Case 1: closed=1 already (the first scenario's server closed above) —
# --reattach against the same --out should be an immediate, no-wait hit.
REATTACH_OUT1="$(python3 "$SCRIPT_DIR/review-page.py" --reattach "$OUT" 2>&1)"; REATTACH_RC1=$?
if [ "$REATTACH_RC1" = 0 ] && [ "$REATTACH_OUT1" = "$OUT" ]; then
  pass "--reattach: closed=1 prints the answers path and exits 0 immediately"
else
  fail "--reattach (closed=1) wrong: rc=$REATTACH_RC1 out=$REATTACH_OUT1"
fi

# Case 2: closed=0, caller_pid alive — a fresh server that hasn't been
# POSTed to yet. --reattach (from a second, independent process) must
# block until the POST lands, then exit 0 with the answers path.
SPEC2="$WORK/spec2.json"
OUT2="$WORK/answers2.json"
STATE2="$OUT2.buffer-state"
LOG2="$WORK/server2.log"
PORT2=58733
cat > "$SPEC2" <<'EOF'
{"title": "Reattach fixture", "areas": [{"id": "a", "title": "A", "items": [
  {"id": "only-item", "title": "Only item", "where": "x.py:1", "what": "thing", "suggested": "apply"}
]}]}
EOF

python3 "$SCRIPT_DIR/review-page.py" --spec "$SPEC2" --out "$OUT2" --port "$PORT2" \
  > "$LOG2" 2>&1 &
SERVER2_PID=$!

UP=0
for i in $(seq 1 50); do
  if curl -s -o /dev/null "http://127.0.0.1:$PORT2/"; then UP=1; break; fi
  sleep 0.1
done
if [ "$UP" -ne 1 ]; then
  fail "--reattach fixture: server2 did not come up on port $PORT2"
  cat "$LOG2"
else
  # Sanity: state file exists and is closed=0 before we've submitted anything.
  PRE_CLOSED="$(grep '^closed=' "$STATE2" 2>/dev/null | cut -d= -f2)"
  if [ "$PRE_CLOSED" = "0" ]; then
    pass "--reattach fixture: server2's state file starts closed=0"
  else
    fail "--reattach fixture: expected closed=0 before submit, got '$PRE_CLOSED'"
  fi

  # Start the reattach wait in the background — it must not return before
  # the POST below lands.
  REATTACH2_OUTFILE="$WORK/reattach2.out"
  python3 "$SCRIPT_DIR/review-page.py" --reattach "$OUT2" > "$REATTACH2_OUTFILE" 2>&1 &
  REATTACH2_PID=$!

  sleep 0.5
  if kill -0 "$REATTACH2_PID" 2>/dev/null; then
    pass "--reattach: closed=0/pid-alive case blocks rather than returning immediately"
  else
    fail "--reattach returned before the review was ever submitted"
  fi

  SPEC2_HASH="$(sha256sum "$SPEC2" | awk '{print $1}')"
  SUBMIT2_PAYLOAD="$WORK/submit2.json"
  cat > "$SUBMIT2_PAYLOAD" <<EOF
{"spec_hash": "$SPEC2_HASH", "items": [{"id": "only-item", "verdict": "apply", "touched": true}]}
EOF
  curl -s -o /dev/null -X POST -H 'Content-Type: application/json' \
    -H "Origin: http://127.0.0.1:$PORT2" --data "@$SUBMIT2_PAYLOAD" \
    "http://127.0.0.1:$PORT2/submit" > /dev/null

  wait "$SERVER2_PID" 2>/dev/null
  SERVER2_PID=""

  # --reattach should now unblock on its own (bounded wait, not a hang).
  REATTACH2_DONE=0
  for i in $(seq 1 50); do
    if ! kill -0 "$REATTACH2_PID" 2>/dev/null; then REATTACH2_DONE=1; break; fi
    sleep 0.1
  done
  if [ "$REATTACH2_DONE" -ne 1 ]; then
    fail "--reattach never returned after the review was submitted"
    kill "$REATTACH2_PID" 2>/dev/null
  else
    wait "$REATTACH2_PID" 2>/dev/null; REATTACH2_RC=$?
    REATTACH2_OUT="$(cat "$REATTACH2_OUTFILE")"
    if [ "$REATTACH2_RC" = 0 ] && [ "$REATTACH2_OUT" = "$OUT2" ]; then
      pass "--reattach: unblocks and prints the answers path once the review is submitted"
    else
      fail "--reattach (post-submit) wrong: rc=$REATTACH2_RC out=$REATTACH2_OUT"
    fi
  fi
fi

# Case 3: closed=0, caller_pid dead — the server was killed before anyone
# submitted. --reattach must report the death (exit 3), not hang.
SPEC3="$WORK/spec3.json"
OUT3="$WORK/answers3.json"
LOG3="$WORK/server3.log"
PORT3=58734
cp "$SPEC2" "$SPEC3"

python3 "$SCRIPT_DIR/review-page.py" --spec "$SPEC3" --out "$OUT3" --port "$PORT3" \
  > "$LOG3" 2>&1 &
SERVER3_PID=$!

UP=0
for i in $(seq 1 50); do
  if curl -s -o /dev/null "http://127.0.0.1:$PORT3/"; then UP=1; break; fi
  sleep 0.1
done
if [ "$UP" -ne 1 ]; then
  fail "--reattach dead-pid fixture: server3 did not come up on port $PORT3"
  cat "$LOG3"
else
  kill -9 "$SERVER3_PID" 2>/dev/null
  wait "$SERVER3_PID" 2>/dev/null
  SERVER3_PID=""

  REATTACH3_OUT="$(python3 "$SCRIPT_DIR/review-page.py" --reattach "$OUT3" 2>&1)"; REATTACH3_RC=$?
  if [ "$REATTACH3_RC" = 3 ] && echo "$REATTACH3_OUT" | grep -q "died before submit"; then
    pass "--reattach: a dead caller_pid exits 3 with the death message, no answers.json written"
  else
    fail "--reattach (dead pid) wrong: rc=$REATTACH3_RC out=$REATTACH3_OUT"
  fi
  if [ -s "$OUT3" ]; then
    fail "--reattach must not fabricate answers.json for a dead, never-submitted process"
  else
    pass "--reattach (dead pid): no answers.json was written"
  fi
fi

# =============================================================================
# --timeout
# =============================================================================

# A server given --timeout 1 with no POST ever sent must give up rather than
# wait forever: exit 4, write no answers.json, leave the state file closed=0.
SPEC4="$WORK/spec4.json"
OUT4="$WORK/answers4.json"
STATE4="$OUT4.buffer-state"
LOG4="$WORK/server4.log"
PORT4=58735
cp "$SPEC2" "$SPEC4"

TIMEOUT4_START=$(date +%s)
python3 "$SCRIPT_DIR/review-page.py" --spec "$SPEC4" --out "$OUT4" --port "$PORT4" --timeout 1 \
  > "$LOG4" 2>&1
TIMEOUT4_RC=$?
TIMEOUT4_ELAPSED=$(( $(date +%s) - TIMEOUT4_START ))

if [ "$TIMEOUT4_RC" = 4 ]; then
  pass "--timeout: an unsubmitted review exits 4 rather than hanging"
else
  fail "--timeout: expected exit 4, got $TIMEOUT4_RC ($(cat "$LOG4"))"
fi
if [ "$TIMEOUT4_ELAPSED" -le 10 ]; then
  pass "--timeout 1: returned promptly (${TIMEOUT4_ELAPSED}s), not stuck"
else
  fail "--timeout 1: took ${TIMEOUT4_ELAPSED}s — looks like it ignored the timeout"
fi
if [ -s "$OUT4" ]; then
  fail "--timeout: must not write answers.json when nothing was ever submitted"
else
  pass "--timeout: no answers.json was written"
fi
if [ -f "$STATE4" ]; then
  TIMEOUT4_CLOSED="$(grep '^closed=' "$STATE4" | cut -d= -f2)"
  if [ "$TIMEOUT4_CLOSED" = "0" ]; then
    pass "--timeout: state file left at closed=0"
  else
    fail "--timeout: expected closed=0, state file has closed=$TIMEOUT4_CLOSED"
  fi
else
  fail "--timeout: state file missing entirely"
fi

if [ "$FAIL" -eq 0 ]; then
  echo "ALL TESTS PASSED"
  exit 0
else
  echo "SOME TESTS FAILED"
  exit 1
fi
