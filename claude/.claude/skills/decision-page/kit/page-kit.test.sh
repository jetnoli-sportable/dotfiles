#!/usr/bin/env bash
# page-kit.test.sh — tests the DOM-free parts of kit.js under node: stop
# arithmetic, the key registry, the typing guard, storage fallback and the
# pure HTML renderers. The DOM wiring is covered by the browser checklist.
#
# Run: ./page-kit.test.sh
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KIT="$SCRIPT_DIR/kit.js"
TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TMPDIR"' EXIT

FAIL=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; FAIL=1; }

if ! command -v node >/dev/null 2>&1; then
  echo "SKIP: node not found; kit.js checks not run"
  exit 0
fi

# check <name> <js>: runs the js with Kit in scope; it must print OK.
check() {
  local name="$1" js="$2" out
  out="$(KIT="$KIT" node -e "const Kit=require(process.env.KIT);const assert=require('assert');$js;console.log('OK')" 2>&1)"
  if [ "$out" = "OK" ]; then pass "$name"; else fail "$name: $out"; fi
}

if [ -f "$KIT" ] && node --check "$KIT" 2>"$TMPDIR/syntax.err"; then
  pass "kit.js parses (node --check)"
else
  fail "kit.js parses (node --check): $(cat "$TMPDIR/syntax.err" 2>/dev/null || echo 'kit.js missing')"
fi

check "stops(): overview, items, closing in order" \
  "assert.deepStrictEqual(Kit.stops('band',['a','b'],'finish'),['band','a','b','finish'])"

check "step(): j walks overview -> item 0 -> last item -> closing and stays on closing" \
  "const s=Kit.stops('band',['a','b'],'finish');
   assert.strictEqual(Kit.step(s,'band',1),'a');
   assert.strictEqual(Kit.step(s,'b',1),'finish');
   assert.strictEqual(Kit.step(s,'finish',1),'finish')"

check "step(): k from item 0 goes to the overview, which stays put" \
  "const s=Kit.stops('band',['a','b'],'finish');
   assert.strictEqual(Kit.step(s,'a',-1),'band');
   assert.strictEqual(Kit.step(s,'band',-1),'band')"

check "step(): an empty item list goes overview -> closing" \
  "const s=Kit.stops('band',[],'finish');
   assert.strictEqual(Kit.step(s,'band',1),'finish')"

check "step(): a stop not in the list goes to the first item forward and the overview back" \
  "const s=Kit.stops('band',['a','b'],'finish');
   assert.strictEqual(Kit.step(s,'gone',1),'a');
   assert.strictEqual(Kit.step(s,'gone',-1),'band');
   assert.strictEqual(Kit.step(Kit.stops('band',[],'finish'),'gone',1),'finish')"

check "registry: registering g twice throws, naming the key" \
  "const k=Kit.newKeys();k.register('g',()=>{},'group');
   assert.throws(()=>k.register('g',()=>{},'again'),/\"g\"/)"

check "registry: the kit's shared keys are already taken" \
  "const k=Kit.newKeys();
   for(const key of ['j','k','Enter','e','E','n','[','?','Escape'])
     assert.throws(()=>k.register(key,()=>{},'x'),new RegExp('\"'+key.replace(/[\\\\[?]/g,'\\\\\$&')+'\"'))"

check "registry: an array registers several keys; a clash on any throws" \
  "const k=Kit.newKeys();k.register(['1','2','3'],()=>{},'pick');
   assert.ok(k.get('2'));
   assert.throws(()=>k.register(['4','3'],()=>{},'x'),/\"3\"/);
   assert.strictEqual(k.get('4'),undefined)"

check "registry: get() returns the handler registered for a key" \
  "const k=Kit.newKeys();const h=()=>{};k.register('a',h,'agree');
   assert.strictEqual(k.get('a').handler,h);assert.strictEqual(k.get('zz'),undefined)"

check "guard: a textarea target is ignored, except Escape which blurs" \
  "assert.strictEqual(Kit.guard({tagName:'TEXTAREA'},'j'),'skip');
   assert.strictEqual(Kit.guard({tagName:'TEXTAREA'},'Escape'),'blur')"

check "guard: text inputs and selects are ignored; buttons, radios and checkboxes pass" \
  "assert.strictEqual(Kit.guard({tagName:'INPUT',type:'text'},'a'),'skip');
   assert.strictEqual(Kit.guard({tagName:'INPUT',type:'search'},'a'),'skip');
   assert.strictEqual(Kit.guard({tagName:'SELECT'},'a'),'skip');
   assert.strictEqual(Kit.guard({tagName:'INPUT',type:'radio'},'a'),'pass');
   assert.strictEqual(Kit.guard({tagName:'INPUT',type:'checkbox'},'a'),'pass');
   assert.strictEqual(Kit.guard({tagName:'BUTTON'},'a'),'pass');
   assert.strictEqual(Kit.guard(null,'a'),'pass')"

check "storage: get() returns the fallback, without throwing, when localStorage throws" \
  "const boom={getItem(){throw new Error('blocked')},setItem(){throw new Error('blocked')}};
   const s=Kit.store(boom);
   assert.deepStrictEqual(s.get('k',{x:1}),{x:1});
   assert.strictEqual(s.set('k',{a:1}),false)"

check "storage: with no localStorage at all, helpers fall back safely" \
  "const s=Kit.store();assert.strictEqual(s.get('k','dflt'),'dflt');assert.strictEqual(s.set('k',1),false)"

check "storage: round-trips JSON, and corrupt JSON gives the fallback" \
  "const m={};const mem={getItem:k=>k in m?m[k]:null,setItem:(k,v)=>{m[k]=String(v)}};
   const s=Kit.store(mem);
   assert.strictEqual(s.set('k',{a:[1,2]}),true);
   assert.deepStrictEqual(s.get('k',null),{a:[1,2]});
   m.bad='{nope';assert.strictEqual(s.get('bad','fb'),'fb')"

check "storage: remove() deletes a key, and never throws when storage does" \
  "const m={};const mem={getItem:k=>k in m?m[k]:null,setItem:(k,v)=>{m[k]=String(v)},removeItem:k=>{delete m[k]}};
   const s=Kit.store(mem);s.set('k',1);assert.strictEqual(s.remove('k'),true);assert.strictEqual(s.get('k','gone'),'gone');
   assert.strictEqual(Kit.store({removeItem(){throw new Error('x')}}).remove('k'),false)"

check "renderers: esc and strip" \
  "assert.strictEqual(Kit.esc('<a href=\"x\">&'),'&lt;a href=&quot;x&quot;&gt;&amp;');
   assert.strictEqual(Kit.strip('<code>a</code> &lt;b&gt; &amp;'),'a <b> &')"

check "renderers: chip links absolute paths and escapes its label" \
  "const h=Kit.chip({kind:'file',label:'<x>',path:'/tmp/a b'});
   assert.ok(h.includes('<a class=\"chip\" href=\"file:///tmp/a b\"'));assert.ok(h.includes('&lt;x&gt;'));
   assert.ok(Kit.chip({kind:'skill',label:'wb-done',path:'wb-done'}).startsWith('<span class=\"chip\"'))"

check "renderers: stageStrip marks the current stage and says where you are" \
  "const h=Kit.stageStrip({task:'t--x',here:'audit',stages:[{name:'A',state:'done'},{name:'B',state:'current',note:'this page'},{name:'C',state:'upcoming'}]});
   assert.ok(h.includes('aria-current=\"step\"'));assert.ok(h.includes('You are here: audit'));
   assert.ok(h.includes('2 · Current'));assert.ok(h.includes('(t--x)'))"

check "renderers: stageStrip maps an unknown or hostile state to later" \
  "const h=Kit.stageStrip({task:'t',here:'h',stages:[{name:'A',state:'x\"><img src=x onerror=1>'}]});
   assert.ok(!h.includes('<img'));assert.ok(h.includes('class=\"later\"'));assert.ok(h.includes('1 · Later'));assert.ok(!h.includes('undefined'))"

echo
if [ "$FAIL" -eq 0 ]; then echo "ALL TESTS PASSED"; else echo "SOME TESTS FAILED"; exit 1; fi
