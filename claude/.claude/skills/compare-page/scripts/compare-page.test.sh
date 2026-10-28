#!/usr/bin/env bash
# compare-page.test.sh — tests compare-page.py: validation, generation, escaping,
# determinism, diagram routing on awkward layouts, and the browser-open refusal.
# Never launches a browser: every run uses --no-open, or a /tmp path that the
# generator refuses to open.
#
# Run: ./compare-page.test.sh
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(dirname "$SCRIPT_DIR")"
GEN="$SCRIPT_DIR/compare-page.py"
FIXTURE="$SKILL_DIR/fixtures/example-spec.json"
WORK="$(mktemp -d /tmp/compare-page-test.XXXXXX)"
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
import copy, json, sys
s = json.load(open(sys.argv[1]))
exec(sys.argv[3])
json.dump(s, open(sys.argv[2], "w"))
PY
}

# reject <name> <python> <substring>: the mutated spec must exit 2 naming the substring, writing nothing
reject() {
  mutate "$1" "$2"; gen "$WORK/$1.json" --out "$WORK/$1.html"
  if [ "$RC" = 2 ] && [[ "$OUT" == *"compare-page.py:"* ]] && [[ "$OUT" == *"$3"* ]] && [ ! -e "$WORK/$1.html" ]; then
    pass "rejects: $1"
  else
    fail "rejects: $1 (rc=$RC, want substring '$3'): $OUT"
  fi
}

# accept <name> <python>: the mutated spec must render (exit 0) and contain one svg per option
accept() {
  mutate "$1" "$2"; gen "$WORK/$1.json" --out "$WORK/$1.html"
  local want; want="$(python3 -c 'import json,sys; print(len(json.load(open(sys.argv[1]))["options"]))' "$WORK/$1.json")"
  local got; got="$(grep -c '<svg class="dg"' "$WORK/$1.html" 2>/dev/null || echo 0)"
  if [ "$RC" = 0 ] && [ "$got" = "$want" ]; then pass "accepts: $1"; else fail "accepts: $1 (rc=$RC, svgs=$got/$want): $OUT"; fi
}

# --- validation ------------------------------------------------------
reject one-option "s['options']=s['options'][:1]" '2-5 options'
reject six-options "s['options']=[dict(copy.deepcopy(s['options'][1]), id='o%d'%i) for i in range(5)]+s['options'][:1]" '2-5 options'
reject no-rec "s['options'][0].pop('rec')" 'exactly one option needs rec'
reject two-rec "s['options'][1]['rec']=True; s['options'][1].pop('wins_if')" 'found 2'
reject wins-on-rec "s['options'][0]['wins_if']='never'" 'wins_if is for the alternatives'
reject no-summary "s['options'][1].pop('summary')" 'option "endpoint": needs summary'
reject empty-pros "s['options'][1]['pros']=[]" 'pros must be'
reject bad-slug "s['slug']='Bad Slug'" 'slug'
reject dup-option "s['options'][2]['id']='job'" 'option ids repeat'
reject unknown-zone "s['options'][0]['diagram']['nodes'][0]['zone']='mars'" 'unknown zone "mars"'
reject unknown-node "s['options'][0]['diagram']['edges'][0]['to']='ghost'" 'unknown node "ghost"'
reject shared-cell "s['options'][0]['diagram']['nodes'][1]['row']=0" 'share zone "laptop" row 0'
reject self-edge "s['options'][0]['diagram']['edges'][0]['to']='cmd'" 'to itself'
reject number-gap "s['options'][0]['diagram']['edges'][1]['n']=9" 'no gaps'
reject steps-mismatch "s['options'][0]['steps']=s['options'][0]['steps'][:-1]" 'one non-blank entry per numbered edge (6)'
reject five-zones "s['options'][0]['diagram']['zones']+= [{'id':'z%d'%i,'label':'Z'} for i in range(2)]" '1-4 zones'
reject bad-tone "s['options'][0]['diagram']['zones'][2]['tone']='red'" 'tone must be'
reject cell-missing "s['compare'][0]['cells'].pop('export')" 'no cell for export'
reject cell-extra "s['compare'][0]['cells']['zzz']='x'" 'unknown options zzz'
reject no-recommendation "s.pop('recommendation')" 'recommendation needs a summary'

# --- generation ------------------------------------------------------
gen "$FIXTURE" --out "$WORK/a.html"
[ "$RC" = 0 ] && [[ "$OUT" == *"wrote: $WORK/a.html"* ]] && [[ "$OUT" == *"not opened: --no-open"* ]] \
  && pass "fixture renders" || fail "fixture renders: $OUT"
gen "$FIXTURE" --out "$WORK/b.html"
cmp -s "$WORK/a.html" "$WORK/b.html" && pass "output is deterministic" || fail "output differs between runs"
grep -q 'run-&lt;gen&gt;/  new flow' "$WORK/a.html" && pass "diagram text is escaped" || fail "diagram text not escaped"
grep -q '<td class="rec">start, wait tens of seconds</td>' "$WORK/a.html" && pass "recommended column is marked" || fail "recommended column not marked"
! grep -q 'undefined\|None' "$WORK/a.html" && pass "no undefined/None leaks" || fail "undefined/None in page"

mutate xss "s['title']='<script>alert(1)</script>'"
gen "$WORK/xss.json" --out "$WORK/xss.html"
grep -q '<title>&lt;script&gt;' "$WORK/xss.html" && ! grep -q '<h1><script>' "$WORK/xss.html" \
  && pass "plain title is escaped" || fail "plain title not escaped"

# --- routing on awkward layouts -------------------------------------
accept five-options "s['options']+= [dict(copy.deepcopy(s['options'][1]), id='alt%d'%i) for i in range(2)]; [c['cells'].update({'alt0':'x','alt1':'y'}) for c in s['compare']]"
accept two-options "s['options']=s['options'][:2]; [c['cells'].pop('export') for c in s['compare']]"
accept four-zones-skips "
d = s['options'][0]['diagram']
d['zones'] = [{'id':'a','label':'A'},{'id':'b','label':'B'},{'id':'c','label':'C'},{'id':'d','label':'D','tone':'accent'}]
d['nodes'] = [
  {'id':'a0','zone':'a','row':0,'title':'a0'}, {'id':'a2','zone':'a','row':2,'title':'a2'},
  {'id':'b1','zone':'b','row':1,'title':'b1'}, {'id':'c0','zone':'c','row':0,'title':'c0'},
  {'id':'d0','zone':'d','row':0,'title':'d0'}, {'id':'d2','zone':'d','row':2,'title':'d2'},
  {'id':'d1','zone':'d','row':1,'title':'d1'}]
d['edges'] = [
  {'from':'a2','to':'d1','n':1}, {'from':'a0','to':'d0','n':2,'both':True}, {'from':'d2','to':'a0','n':3},
  {'from':'d0','to':'d2','n':4}, {'from':'b1','to':'c0','n':5,'dashed':True}, {'from':'a0','to':'a2','n':6}]
"
grep -q 'stroke-dasharray\|class="edge dash"' "$WORK/four-zones-skips.html" && pass "dashed edge rendered" || fail "dashed edge missing"
accept unnumbered-edges "
d = s['options'][1]['diagram']
for e in d['edges']: e.pop('n', None)
s['options'][1]['steps'] = []
"

# --- browser refusal -------------------------------------------------
OUT="$(python3 "$GEN" --spec "$FIXTURE" --out "$WORK/open.html" 2>&1)"
[[ "$OUT" == *"not opened: under /tmp"* ]] && pass "refuses to open under /tmp" || fail "open refusal: $OUT"

# --- bad input -------------------------------------------------------
echo '{not json' > "$WORK/broken.json"
gen "$WORK/broken.json"
[ "$RC" = 2 ] && [[ "$OUT" == *"invalid JSON"* ]] && pass "invalid JSON exits 2" || fail "invalid JSON: rc=$RC $OUT"
gen "$WORK/missing.json"
[ "$RC" = 2 ] && [[ "$OUT" == *"cannot read"* ]] && pass "missing spec exits 2" || fail "missing spec: rc=$RC $OUT"

exit "$FAIL"
