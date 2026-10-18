#!/usr/bin/env bash
# decision-page.test.sh — tests decision-page.py (validation, generation,
# escaping, determinism, browser-open refusal) and runs the page template's
# DOM-free core script block under node against the generated fixture page.
# Never launches a browser: every run uses --no-open, or a /tmp path that the
# generator refuses to open.
#
# Run: ./decision-page.test.sh
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(dirname "$SCRIPT_DIR")"
GEN="$SCRIPT_DIR/decision-page.py"
FIXTURE="$SKILL_DIR/fixtures/example-spec.json"
KIT_JS="$SKILL_DIR/kit/kit.js"
WORK="$(mktemp -d /tmp/decision-page-test.XXXXXX)"
trap 'rm -rf "$WORK"' EXIT

FAIL=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; FAIL=1; }

case "$WORK" in /tmp/*) ;; *) echo "refusing to run: test dir $WORK is not under /tmp"; exit 1 ;; esac

# gen <spec> [extra args...]: runs the generator without opening a browser; sets OUT and RC.
gen() { local spec="$1"; shift; OUT="$(python3 "$GEN" --spec "$spec" --no-open "$@" 2>&1)"; RC=$?; }

# mutate <name> <python statements on s>: writes a changed copy of the fixture to $WORK/<name>.json
mutate() {
  python3 - "$FIXTURE" "$WORK/$1.json" "$2" <<'PY'
import json, sys
s = json.load(open(sys.argv[1]))
exec(sys.argv[3])
json.dump(s, open(sys.argv[2], "w"))
PY
}

# reject <name> <python> <substring>: the mutated spec must exit 2 with a decision-page.py: message containing the substring
reject() {
  mutate "$1" "$2"; gen "$WORK/$1.json" --out "$WORK/$1.html"
  if [ "$RC" = 2 ] && [[ "$OUT" == *"decision-page.py:"* ]] && [[ "$OUT" == *"$3"* ]] && [ ! -e "$WORK/$1.html" ]; then
    pass "rejects: $1"
  else
    fail "rejects: $1 (rc=$RC, want substring '$3'): $OUT"
  fi
}

# --- validation ------------------------------------------------------
reject no-rec "s['items'][0]['options'][0].pop('rec')" 'item "sweep"'
reject two-rec "s['items'][0]['options'][1]['rec']=True" 'item "sweep"'
reject no-question "s['items'][1].pop('question')" 'item "lock-orphan"'
reject no-why "s['items'][1].pop('why_it_matters')" 'why_it_matters'
reject no-recommendation "s['items'][2].pop('recommendation')" 'item "sync"'
reject option-no-name "s['items'][2]['options'][1].pop('name')" 'option "keep"'
reject decided-no-decision "s['decided'][0].pop('decision')" 'done-review'
reject decided-no-date "s['decided'][0].pop('date')" 'done-review'
reject bad-stage-state "s['context']['stages'][0]['state']='soon'" 'soon'
reject bad-slug "s['slug']='Bad Slug'" 'slug'
reject two-current "s['context']['stages'][0]['state']='current'" 'current'
reject no-defer "s['items'][1]['options']=[o for o in s['items'][1]['options'] if o['v']!='defer']" 'defer'
reject rec-on-defer "[o.pop('rec',None) for o in s['items'][1]['options']]; s['items'][1]['options'][-1]['rec']=True" 'defer'
reject duplicate-item-ids "s['items'][1]['id']=s['items'][0]['id']" 'duplicate'
reject duplicate-option-ids "s['items'][0]['options'][1]['v']=s['items'][0]['options'][0]['v']" 'duplicate'
reject uppercase-id "s['items'][0]['id']='Sweep'" 'Sweep'
reject space-id "s['items'][0]['id']='my item'" 'my item'
reject round-zero "s['round']=0" 'round'
reject stats-string "s['stats']='a fact'" 'stats'
reject stats-non-string-item "s['stats']=['ok',3]" 'stats'
reject artifacts-string "s['items'][0]['artifacts']='x'" 'artifacts'
reject artifacts-non-object "s['items'][0]['artifacts']=['x']" 'artifacts'
reject lede-list "s['lede']=['x']" 'lede'
reject title-number "s['title']=5" 'title'
reject tag-string "s['items'][0]['tag']='keep'" 'tag'
reject tag-no-label "s['items'][0]['tag']={'tone':'keep'}" 'tag'
reject decided-with-options "s['decided'][0]['options']=[]" 'done-review'

# structural guards: each wrong shape is a problem, not a crash
reject spec-is-list "s=[]" 'JSON object'
reject items-not-list "s['items']='x'" 'items must be a list'
reject decided-not-list "s['decided']={}" 'decided must be a list'
reject stages-not-list "s['context']['stages']='x'" 'context.stages must be a list'
reject context-not-object "s['context']=[]" 'context.stages must be a list'
reject item-not-object "s['items'][0]='x'" 'items[0] must be an object'
reject decided-entry-not-object "s['decided'][0]=5" 'decided[0] must be an object'
reject option-not-object "s['items'][0]['options'][0]='x'" 'options[0] must be an object'

mutate three-problems "s['items'][0].pop('question'); s['items'][1]['options'][0].pop('name'); s['round']=0"
gen "$WORK/three-problems.json" --out "$WORK/three-problems.html"
n=$(printf '%s\n' "$OUT" | /usr/bin/grep -c '^decision-page.py:')
if [ "$RC" = 2 ] && [ "$n" -ge 3 ]; then pass "three separate problems are all reported in one run ($n lines)"; else fail "three problems in one run (rc=$RC, lines=$n): $OUT"; fi

python3 "$GEN" >/dev/null 2>&1; rc=$?
if [ "$rc" = 2 ]; then pass "missing --spec exits 2"; else fail "missing --spec exits 2 (rc=$rc)"; fi
gen "$WORK/does-not-exist.json"
if [ "$RC" = 2 ] && [[ "$OUT" == *"decision-page.py:"* ]]; then pass "unreadable spec exits 2"; else fail "unreadable spec exits 2 (rc=$RC): $OUT"; fi
echo '{not json' > "$WORK/bad.json"; gen "$WORK/bad.json"
if [ "$RC" = 2 ] && [[ "$OUT" == *"decision-page.py:"* ]]; then pass "invalid JSON exits 2"; else fail "invalid JSON exits 2 (rc=$RC): $OUT"; fi

# --- generation -------------------------------------------------------------
PAGE="$WORK/fixture.html"
gen "$FIXTURE" --out "$PAGE"
HASH="$(printf '%s\n' "$OUT" | sed -n 's/^spec_hash: //p')"
if [ "$RC" = 0 ] && [ -f "$PAGE" ] && [[ "$OUT" == *"$PAGE"* ]] && [[ "$HASH" =~ ^[0-9a-f]{8}$ ]]; then
  pass "fixture generates with --no-open, prints the path and an 8-char hash ($HASH)"
else
  fail "fixture generates (rc=$RC, hash='$HASH'): $OUT"
fi

missing=""
/usr/bin/grep -q '<title>wb deletion audit</title>' "$PAGE" || missing="$missing title"
for id in sweep lock-orphan sync auto-stamps done-review; do /usr/bin/grep -q "\"id\":\"$id\"" "$PAGE" || missing="$missing $id"; done
if [ -z "$missing" ]; then pass "page has the spec title, the embedded spec and every item id"; else fail "page is missing:$missing"; fi

if [ -f "$PAGE" ] && ! /usr/bin/grep -q '{{[A-Z_]*}}' "$PAGE"; then pass "page has no unfilled placeholders"; else fail "page is missing or still holds an unfilled placeholder"; fi

# --- determinism ------------------------------------------------------------
gen "$FIXTURE" --out "$WORK/again.html"; HASH2="$(printf '%s\n' "$OUT" | sed -n 's/^spec_hash: //p')"
if cmp -s "$PAGE" "$WORK/again.html" && [ "$HASH" = "$HASH2" ]; then pass "same spec twice gives an identical file and hash"; else fail "generation is not deterministic"; fi

# --- optional fields and the script-escape guard ---------------------------------
mutate sparse "
for i in s['items']:
    i.pop('artifacts', None)
    for o in i['options']:
        o.pop('cost', None); o.pop('risk', None)"
gen "$WORK/sparse.json" --out "$WORK/sparse.html"
if [ "$RC" = 0 ]; then pass "a spec with no artifacts and no cost/risk generates"; else fail "sparse spec generates (rc=$RC): $OUT"; fi

BASE_SCRIPTS=$(/usr/bin/grep -o '<script' "$PAGE" | wc -l)
mutate xss "s['items'][0]['why_it_matters']='</script><script>alert(1)</script> <!-- x   y'"
gen "$WORK/xss.json" --out "$WORK/xss.html"
XSS_SCRIPTS=$(/usr/bin/grep -o '<script' "$WORK/xss.html" | wc -l)
if [ "$RC" = 0 ] && [ "$XSS_SCRIPTS" = "$BASE_SCRIPTS" ] && ! /usr/bin/grep -q '<!-- x' "$WORK/xss.html"; then
  pass "spec text with </script> and <!-- adds no script element ($XSS_SCRIPTS <script tags)"
else
  fail "script-escape guard (rc=$RC, scripts $XSS_SCRIPTS vs $BASE_SCRIPTS): $OUT"
fi

# a suspicious field warns on stderr but the page is still written (exit 0), naming the JSON path
mutate suspect "
s['items'][0]['why_it_matters']='x <SCRIPT>y</SCRIPT>'
s['items'][1]['options'][0]['pros']='<img src=x onerror=alert(1)>'
s['lede']='a &lt;script&gt; shown, and once upon a time'"
gen "$WORK/suspect.json" --out "$WORK/suspect.html"
if [ "$RC" = 0 ] && [ -f "$WORK/suspect.html" ] \
   && [[ "$OUT" == *"warning: .items[0].why_it_matters"* || "$OUT" == *"warning: items[0].why_it_matters"* ]] \
   && [[ "$OUT" == *"items[1].options[0].pros"* ]] && [[ "$OUT" != *"lede"* ]]; then
  pass "<script and on...= fields warn with their JSON path and still exit 0; escaped text does not warn"
else
  fail "suspect-field warning (rc=$RC): $OUT"
fi
gen "$FIXTURE" --out "$WORK/clean.html"
if [[ "$OUT" != *"warning"* ]]; then pass "the fixture spec produces no warning"; else fail "fixture warns: $OUT"; fi

# pagekit.script_safe escapes the line separators as well as <
python3 -B - "$SKILL_DIR/kit" <<'PY'
import sys
sys.path.insert(0, sys.argv[1])
from pagekit import script_safe
out = script_safe("a\u2028b\u2029c</script><!--")
sys.exit(0 if out == "a\\u2028b\\u2029c\\u003c/script>\\u003c!--" else 1)
PY
if [ $? -eq 0 ]; then pass "script_safe escapes U+2028, U+2029 and <"; else fail "script_safe line-separator escaping"; fi

# --- opening ----------------------------------------------------------------
OUT="$(python3 "$GEN" --spec "$FIXTURE" --out "$WORK/tmp-open.html" 2>&1)"; RC=$?
if [ "$RC" = 0 ] && [ -f "$WORK/tmp-open.html" ] && [[ "$OUT" == *"not opened"* ]] && [[ "$OUT" == *"/tmp"* ]]; then
  pass "a /tmp output without --no-open is written, not opened, and says why"
else
  fail "/tmp output refuses to open (rc=$RC): $OUT"
fi

# --- core script block under node ----------------------------------------------
if ! command -v node >/dev/null 2>&1; then
  echo "SKIP: node not found; page script checks not run"
else
  # every inline script of the generated page must parse
  python3 - "$PAGE" "$WORK" <<'PY'
import re, sys
html = open(sys.argv[1], encoding="utf-8").read()
for n, m in enumerate(re.finditer(r'<script(?![^>]*application/json)[^>]*>(.*?)</script>', html, re.S)):
    open("%s/inline-%d.js" % (sys.argv[2], n), "w", encoding="utf-8").write(m.group(1))
core = re.search(r'// CORE:BEGIN.*?// CORE:END', html, re.S)
open("%s/core.js" % sys.argv[2], "w", encoding="utf-8").write(core.group(0) + "\nif (typeof module !== 'undefined') module.exports = DP;\n" if core else "")
PY
  bad=""
  for f in "$WORK"/inline-*.js; do node --check "$f" 2>"$WORK/syntax.err" || bad="$bad $(basename "$f"): $(head -3 "$WORK/syntax.err")"; done
  if [ -z "$bad" ] && ls "$WORK"/inline-*.js >/dev/null 2>&1; then pass "the page's inline scripts pass node --check"; else fail "inline script syntax:$bad"; fi

  # check <name> <js>: runs with DP (the page's core block), Kit, the fixture spec and assert in scope; must print OK
  check() {
    local out
    out="$(KIT="$KIT_JS" CORE="$WORK/core.js" FIXTURE="$FIXTURE" PAGE="$PAGE" node -e "
      const assert=require('assert'),fs=require('fs');
      globalThis.Kit=require(process.env.KIT);
      const DP=require(process.env.CORE);
      const raw=JSON.parse(fs.readFileSync(process.env.FIXTURE,'utf8'));
      const spec=DP.normalize(raw);
      const HASH='ab12cd34';
      $2
      console.log('OK')" 2>&1)"
    if [ "$out" = "OK" ]; then pass "$1"; else fail "$1: $out"; fi
  }

  check "page embeds the spec so it round-trips through JSON.parse" "
    const html=fs.readFileSync(process.env.PAGE,'utf8');
    const m=html.match(/<script id=\"spec\" type=\"application\/json\">([\s\S]*?)<\/script>/);
    assert.deepStrictEqual(JSON.parse(m[1]),raw)"

  check "all 4 open items answered counts 4; the decided item is in fixed, not in items" "
    const st={};for(const i of spec.items)st[i.id]={choice:i.options[0].v,note:''};
    assert.strictEqual(DP.answeredCount(spec,st),4);
    const j=DP.answersJson(spec,HASH,st);
    assert.deepStrictEqual(j.fixed,['done-review']);
    assert.strictEqual(j.items.length,4);
    assert.ok(!j.items.some(i=>i.id==='done-review'))"

  check "an option with no cost renders None stated in its Cost line" "
    const h=DP.cardHtml(spec.items[0],0);
    assert.ok(/<b>Cost<\/b>None stated/.test(h),'no None stated in Cost');
    assert.ok(/<b>Pros<\/b>Logs, scratch/.test(h),'a given Pros line must show')"

  check "item a-b with option c and item a with option b-c get distinct DOM ids" "
    const two=DP.normalize({slug:'x',round:1,items:[
      {id:'a-b',options:[{v:'c',name:'C',rec:true},{v:'defer',name:'Defer'}]},
      {id:'a',options:[{v:'b-c',name:'BC',rec:true},{v:'defer',name:'Defer'}]}]});
    const ids=[];two.items.forEach((it,k)=>{ids.push(DP.id.item(k),DP.id.note(k));it.options.forEach((o,m)=>ids.push(DP.id.opt(k,m)))});
    assert.strictEqual(new Set(ids).size,ids.length);
    assert.notStrictEqual(DP.id.opt(0,0),DP.id.opt(1,0))"

  check "a saved choice whose option id left the spec is not counted and copies as null" "
    const st={sweep:{choice:'gone-option',note:'kept note'},sync:{choice:'keep',note:''}};
    assert.strictEqual(DP.answeredCount(spec,st),1);
    const j=DP.answersJson(spec,HASH,st);
    assert.strictEqual(j.items.find(i=>i.id==='sweep').choice,null);
    assert.strictEqual(j.items.find(i=>i.id==='sweep').note,'kept note');
    assert.strictEqual(j.items.find(i=>i.id==='sync').choice,'keep')"

  check "copy answers with nothing answered still lists every open item with choice null" "
    const j=DP.answersJson(spec,HASH,{});
    assert.strictEqual(j.items.length,4);
    assert.ok(j.items.every(i=>i.choice===null&&i.note===''));
    assert.strictEqual(j.global_note,'');
    assert.strictEqual(j.spec_hash,HASH);assert.strictEqual(j.slug,'wb-deletion-audit');assert.strictEqual(j.round,1);
    assert.ok(/\(no answer\)/.test(DP.buildAnswers(spec,HASH,{})))"

  check "a note with a newline and '- fake: x' is indented in the markdown and verbatim in the JSON" "
    const note='first line\n- fake: x\n\`\`\`json\n{}\n\`\`\`';
    const st={sweep:{choice:'keep',note},_global:{note:'g1\n- fake: g'}};
    const text=DP.buildAnswers(spec,HASH,st);
    const k=text.lastIndexOf('\n\`\`\`json\n');
    const md=text.slice(0,k),js=text.slice(k+'\n\`\`\`json\n'.length).replace(/\n\`\`\`\$/,'');
    assert.ok(!md.split('\n').some(l=>/^\s{0,3}- fake/.test(l)),'unindented fake sibling in markdown');
    assert.ok(md.split('\n').some(l=>/^ {4}- fake: x/.test(l)),'note not indented');
    assert.ok(!md.split('\n').some(l=>/^\`\`\`/.test(l)),'fence at column 0 inside the markdown');
    const j=JSON.parse(js);
    assert.strictEqual(j.items.find(i=>i.id==='sweep').note,note);
    assert.strictEqual(j.global_note,'g1\n- fake: g');
    assert.strictEqual(DP.storageKey(spec,HASH),'decision-page:wb-deletion-audit:r1:ab12cd34');
    assert.strictEqual(DP.collection(spec,HASH),'decisions-r1-ab12cd34')"

  check "firstOpen: the first unanswered item; 0 when nothing is answered; 0 (not -1) when every item is answered" "
    const st={};
    assert.strictEqual(DP.firstOpen(spec,st),0);
    st[spec.items[0].id]={choice:spec.items[0].options[0].v};
    st[spec.items[1].id]={choice:'gone-option'};
    assert.strictEqual(DP.firstOpen(spec,st),1,'an invalid saved choice is still open');
    for(const i of spec.items)st[i.id]={choice:i.options[0].v};
    assert.strictEqual(DP.answeredCount(spec,st),spec.items.length);
    assert.strictEqual(DP.firstOpen(spec,st),0);
    assert.strictEqual(DP.firstOpen({items:[]},{}),0)"

  check "mergeSnapshot: remote answers merge, unknown ids and ids with a pending save are skipped, a remote clear gives null, _global merges, inputs untouched" "
    const ids=spec.items.map(i=>i.id), a=ids[0], b=ids[1], c=ids[2], ch=i=>spec.items.find(x=>x.id===i).options[0].v;
    const state={[b]:{choice:ch(b),note:'local'},[c]:{choice:ch(c),note:'keep me'}};
    const before=JSON.stringify(state);
    const m=DP.mergeSnapshot(state,[
      {id:a,data:{choice:ch(a),note:'n'}},
      {id:b,data:{choice:'',note:''}},
      {id:c,data:{choice:'x',note:'remote'}},
      {id:'nope',data:{choice:'x',note:'y'}},
      {id:'_global',data:{choice:'',note:'g'}}],new Set([c]),ids);
    assert.deepStrictEqual(m.changed,[a,b,'_global']);
    assert.deepStrictEqual(m.state[a],{choice:ch(a),note:'n'});
    assert.deepStrictEqual(m.state[b],{choice:null,note:''});
    assert.deepStrictEqual(m.state[c],state[c],'pending edit kept');
    assert.ok(!('nope' in m.state));
    assert.deepStrictEqual(m.state._global,{choice:null,note:'g'});
    assert.strictEqual(JSON.stringify(state),before,'state not mutated');
    const same=DP.mergeSnapshot(m.state,[{id:a,data:{choice:ch(a),note:'n'}}],new Set(),ids);
    assert.deepStrictEqual(same.changed,[],'an identical doc is not a change')"

  check "an escaped tag in a title stays inert in the sidebar, glance table and decided list" "
    const t='Issue: &lt;img src=x onerror=alert(1)&gt;';
    const x=DP.normalize({title:'T',slug:'t',round:1,decided:[{id:'d',title:t,decision:'ok',date:'2026-01-01'}],items:[
      {id:'x',title:t,question:'Q?',why_it_matters:'W',recommendation:'R',options:[{v:'go',name:'Go',rec:true},{v:'defer',name:'Defer'}]}]});
    const all=DP.bandHtml(x)+DP.sidebarHtml(x);
    assert.ok(!/<img/i.test(all),all);assert.ok(all.includes('&lt;img'))"

  check "a spec holding only the required fields renders with no undefined text" "
    const min=DP.normalize({title:'T',slug:'t',round:1,items:[
      {id:'x',question:'Q?',why_it_matters:'W',recommendation:'R',options:[{v:'go',name:'Go',rec:true},{v:'defer',name:'Defer'}]}]});
    const all=DP.bandHtml(min)+DP.sidebarHtml(min)+DP.cardHtml(min.items[0],0,min.round);
    assert.ok(!/undefined|null|NaN/.test(all),all.match(/.{20}(undefined|null|NaN).{20}/));
    assert.ok(/None stated/.test(all))"
fi

echo
if [ "$FAIL" = 0 ]; then echo "ALL TESTS PASSED"; else echo "SOME TESTS FAILED"; exit 1; fi
