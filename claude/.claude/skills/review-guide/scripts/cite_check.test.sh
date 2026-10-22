#!/usr/bin/env bash
# cite_check.test.sh — tests for cite_check.py against throwaway git fixtures.
# Run: ./cite_check.test.sh
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CC="$SCRIPT_DIR/cite_check.py"
EXAMPLE="$SCRIPT_DIR/../fixtures/example-finding.json"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
FAIL=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; FAIL=1; }

R="$WORK/repo"; RUN="$WORK/run"; mkdir -p "$R" "$RUN"
g() { git -C "$R" -c user.name=t -c user.email=t@t "$@"; }
g init -q -b main
for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15; do echo "line $i"; done > "$R/a.txt"
printf 'gone one\nSECRET = base\n' > "$R/del.txt"
g add -A; g commit -qm base; BASE=$(g rev-parse HEAD)
# PR1: insert risky line at a.txt:5, delete del.txt
{ sed -n 1,4p "$R/a.txt"; echo 'risky = eval(x)'; sed -n '5,$p' "$R/a.txt"; } > "$R/a.new"; mv "$R/a.new" "$R/a.txt"
g rm -q del.txt; g add -A; g commit -qm pr1; H1=$(g rev-parse HEAD)
# PR2: insert 3 lines at top of a.txt
{ printf 'x1\nx2\nx3\n'; cat "$R/a.txt"; } > "$R/a.new"; mv "$R/a.new" "$R/a.txt"
g add -A; g commit -qm pr2; H2=$(g rev-parse HEAD)
printf 'Intent: also update the docs\n' > "$RUN/context.md"

cat > "$RUN/target.json" <<TARGET
{"kind":"stack","repo":"fx/repo","repo_path":"$R","cli":"gh","base":"$BASE","head":"$H2",
 "prs":[{"number":1,"head_ref":"pr1","base":"$BASE","head":"$H1","worktree":"$R"},
        {"number":2,"head_ref":"pr2","base":"$H1","head":"$H2","worktree":"$R"}]}
TARGET

# mk <out> <lens> <pr> <file> <line> <side> <excerpt> ; writes one-finding report
mk() { python3 - "$@" <<'PY'
import json,sys
out,lens,pr,f,line,side,ex=sys.argv[1:8]
json.dump({"findings":[{"id":"F1","lens":lens,"pr":int(pr),"file":f,"line":int(line),"side":side,"excerpt":ex,"claim":"c","scenario":"s","severity":"low","confidence":"low"}],"checked_clean":[],"rulings":[]},open(out,"w"))
PY
}
# expect <name> <input> <want-cite> <want-line>
expect() {
  local name="$1" in="$2" want="$3" wline="$4" out="${2%.json}.cited.json" got
  python3 "$CC" "$RUN/target.json" "$in" >/dev/null 2>"$WORK/err" || { fail "$name (script error: $(cat "$WORK/err"))"; return; }
  got=$(python3 -c "import json,sys;f=json.load(open('$out'))['findings'][0];print(f['cite'],f['line'])")
  [ "$got" = "$want $wline" ] && pass "$name" || fail "$name (got '$got', want '$want $wline')"
}

mk "$RUN/lens-L1.json" L1 1 a.txt 5 head 'risky = eval(x)'
expect "exact line -> ok" "$RUN/lens-L1.json" ok 5
python3 -c "import json;assert 'cite' not in json.load(open('$RUN/lens-L1.json'))['findings'][0]" && pass "original input left untouched" || fail "original input left untouched"

mk "$RUN/lens-L2.json" L1 1 a.txt 3 head 'risky = eval(x)'
expect "two lines below -> moved to corrected line" "$RUN/lens-L2.json" moved 5
mk "$RUN/lens-L3.json" L3 1 a.txt 15 head 'risky = eval(x)'
expect "ten lines away -> missing" "$RUN/lens-L3.json" missing 15
mk "$RUN/lens-L4.json" L4 1 a.txt 5 head 'no such text anywhere'
expect "absent excerpt -> missing" "$RUN/lens-L4.json" missing 5

# multi-line excerpts: every line must match, in order
mk "$RUN/lens-L5.json" L1 1 a.txt 5 head $'risky = eval(x)\nline 5'
expect "two-line excerpt, both lines real -> ok" "$RUN/lens-L5.json" ok 5
mk "$RUN/lens-L5b.json" L1 1 a.txt 5 head $'risky = eval(x)\nos.system(x)'
expect "real first line, invented second line -> missing" "$RUN/lens-L5b.json" missing 5
mk "$RUN/lens-L5c.json" L2 1 a.txt 1 head 'x1'
expect "excerpt too short to prove anything -> missing" "$RUN/lens-L5c.json" missing 1
mk "$RUN/lens-L5d.json" L1 1 a.txt 6 head 'line'
expect "short line must equal the file line, not be part of it -> missing" "$RUN/lens-L5d.json" missing 6

mk "$RUN/lens-L1b.json" L1 1 del.txt 2 base 'SECRET = base'
expect "side base on deleted file -> ok" "$RUN/lens-L1b.json" ok 2

# stack: PR2 shifted a.txt by 3 lines; PR1's own L1 finding still ok at PR1 head
mk "$RUN/lens-L1c.json" L1 1 a.txt 5 head 'risky = eval(x)'
expect "stack L1 uses PR1's own head -> ok" "$RUN/lens-L1c.json" ok 5
# non-L1 lens uses range end (H2): line is 8 there, cited 5 -> moved
mk "$RUN/lens-L2c.json" L2 1 a.txt 5 head 'risky = eval(x)'
expect "stack L2 uses range head -> moved +3" "$RUN/lens-L2c.json" moved 8

mk "$RUN/lens-L3b.json" L3 1 context.md 1 head 'also update the docs'
expect "context.md excerpt -> ok" "$RUN/lens-L3b.json" ok 1

# verified.json with a coordinator-raised finding and a verdict
python3 - "$RUN/verified.json" <<'PY'
import json,sys
fs=[{"id":"C1","lens":"coordinator","pr":2,"file":"a.txt","line":9,"side":"head","excerpt":"risky = eval(x)","claim":"c","scenario":"s","severity":"high","confidence":"high","verdict":"CONFIRMED","reason":"seen"}]
json.dump({"findings":fs,"checked_clean":[],"rulings":[]},open(sys.argv[1],"w"))
PY
expect "verified.json coordinator finding checked (pr2 head, 9 -> 8 moved)" "$RUN/verified.json" moved 8
python3 -c "import json;f=json.load(open('$RUN/verified.cited.json'))['findings'][0];assert f['verdict']=='CONFIRMED'" && pass "verdict preserved" || fail "verdict preserved"

# real example in this repo
EX="$WORK/example"; mkdir -p "$EX"; cp "$EXAMPLE" "$EX/lens-L1.json"
REPO_ROOT="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel)"
if SHA=$(git -C "$REPO_ROOT" rev-parse --verify -q 'a9540a8^{commit}'); then
  cat > "$EX/target.json" <<TARGET
{"kind":"branch","repo":"dotfiles","repo_path":"$REPO_ROOT","cli":"gh","base":"$SHA","head":"$SHA",
 "prs":[{"number":0,"head_ref":"fix/capture-handback-none","base":"$SHA","head":"$SHA","worktree":"$REPO_ROOT"}]}
TARGET
  python3 "$CC" "$EX/target.json" "$EX/lens-L1.json" >/dev/null 2>&1
  c=$(python3 -c "import json;print(json.load(open('$EX/lens-L1.cited.json'))['findings'][0]['cite'])" 2>/dev/null)
  [ "$c" = ok ] && pass "real pipeline-page example at a9540a8 -> ok" || fail "real example (got '$c')"
else
  fail "a9540a8 not reachable in this repo"
fi
exit $FAIL
