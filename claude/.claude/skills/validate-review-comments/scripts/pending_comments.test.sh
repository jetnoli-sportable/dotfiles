#!/usr/bin/env bash
# pending_comments.test.sh — tests for pending_comments.py against throwaway git fixtures.
# Hunks are hand-written in the shape GitHub returns for pending comments (no line,
# side or subject_type; diff_hunk ends on the commented line).
# Run: ./pending_comments.test.sh
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PC="$SCRIPT_DIR/pending_comments.py"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
FAIL=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; FAIL=1; }

R="$WORK/repo"; mkdir -p "$R"
g() { git -C "$R" -c user.name=t -c user.email=t@t "$@"; }
g init -q -b main
for i in 1 2 3 4 5 6 7 8 9 10; do echo "line $i"; done > "$R/chg.py"
printf 'fn a() {\n  x();\n}\nfn b() {\n  y();\n}\n' > "$R/brace.c"
printf 'fn a() {\n  z();\n}\nfn b() {\n  z();\n}\n' > "$R/dup.c"
printf 'keep 1\nold value\nkeep 3\n' > "$R/del.txt"
cp "$R/brace.c" "$R/shift.c"; cp "$R/brace.c" "$R/rw.c"
g add -A; g commit -qm base; B=$(g rev-parse HEAD)
# PR 1: new file, a line added to chg.py at 6, a line deleted from del.txt
printf 'def f():\n    return 1\n' > "$R/new.py"
printf 'keep\nremove me\n' > "$R/gone.py"
printf 'here\n' > "$R/missing.py"
{ sed -n 1,5p "$R/chg.py"; echo 'added = True'; sed -n '6,$p' "$R/chg.py"; } > "$R/x"; mv "$R/x" "$R/chg.py"
printf 'keep 1\nkeep 3\n' > "$R/del.txt"
g add -A; g commit -qm pr1; H1=$(g rev-parse HEAD)
# PR 2: two lines above everything in chg.py, brace.c and dup.c, three above shift.c;
# fn b's body rewritten in rw.c; f renamed; gone.py loses its line; missing.py
# deleted; del.txt untouched
for f in chg.py brace.c dup.c; do { printf '// one\n// two\n'; cat "$R/$f"; } > "$R/x"; mv "$R/x" "$R/$f"; done
{ printf '// 1\n// 2\n// 3\n'; cat "$R/shift.c"; } > "$R/x"; mv "$R/x" "$R/shift.c"
sed -i 's/  y();/  w();/' "$R/rw.c"
sed -i 's/def f/def g/' "$R/new.py"
printf 'keep\n' > "$R/gone.py"
g rm -q missing.py; g add -A; g commit -qm pr2; H2=$(g rev-parse HEAD)
# PR 3: twenty more lines above chg.py's
{ for i in $(seq 20); do echo "// pad $i"; done; cat "$R/chg.py"; } > "$R/x"; mv "$R/x" "$R/chg.py"
g add -A; g commit -qm pr3; H3=$(g rev-parse HEAD)

# target <dir> <head> : single-PR target (PR 1) checked at <head>
target() { mkdir -p "$1"; cat > "$1/target.json" <<T
{"kind":"pr","repo":"fx/repo","repo_path":"$R","cli":"gh","base":"$B","head":"$2",
 "prs":[{"number":1,"base":"$B","head":"$2"}]}
T
}
U=https://api.github.com/repos/fx/repo/pulls
# c <id> <path> <hunk> [updated_at] [pr] : one raw pending comment as JSON
c() { python3 -c 'import json,sys; i,p,h,u,pr=sys.argv[1:6]; print(json.dumps({"id":int(i),"path":p,"diff_hunk":h,"updated_at":u,"body":"b","pull_request_url":f"'"$U"'/{pr}","html_url":"h"}))' "$1" "$2" "$3" "${4:-2026-01-01T00:00:00Z}" "${5:-1}"; }
# comments <dir> <json>... : write comments.json
comments() { local d="$1"; shift; local IFS=,; echo "[$*]" > "$d/comments.json"; }
run() { python3 "$PC" "$1/target.json" "$1/comments.json" >"$1/out.txt" 2>&1 || { fail "script error: $(cat "$1/out.txt")"; return 1; }; }
# field <dir> <id> <expr over r> : print a field of one mapped record
field() { python3 -c "import json;r=[x for x in json.load(open('$1/comments.mapped.json'))['comments'] if x['id']==$2][0];v=($3);print(v)"; }
expect() { [ "$2" = "$3" ] && pass "$1" || fail "$1 (got '$2', want '$3')"; }

NEWH=$'@@ -0,0 +1,2 @@\n+def f():\n+    return 1'
CHGH=$'@@ -1,3 +1,3 @@\n line 1\n line 2\n line 3\n@@ -4,3 +4,4 @@\n line 4\n line 5\n+added = True'
DELH=$'@@ -1,3 +1,2 @@\n keep 1\n-old value'
BRACEH=$'@@ -4,3 +4,3 @@\n fn b() {\n   y();\n }'
DUPH=$'@@ -4,3 +4,3 @@\n fn b() {\n   z();\n }'
GONEH=$'@@ -0,0 +1,2 @@\n+keep\n+remove me'
MISSH=$'@@ -0,0 +1 @@\n+here'

# 1. first run at the PR head: new file, changed file, deleted line, file-level
D="$WORK/first"; target "$D" "$H1"
comments "$D" "$(c 11 new.py "$NEWH")" "$(c 12 chg.py "$CHGH")" "$(c 13 del.txt "$DELH")" \
  "$(python3 -c 'import json;print(json.dumps({"id":14,"path":"del.txt","subject_type":"file","diff_hunk":"","updated_at":"t","body":"b","pull_request_url":"'"$U"'/1"}))')"
if run "$D"; then
  expect "new file -> head line, ok" "$(field "$D" 11 "r['side'],r['line'],r['cite']")" "('head', 2, 'ok')"
  expect "changed file -> mapped from the last header" "$(field "$D" 12 "r['side'],r['line'],r['cite']")" "('head', 6, 'ok')"
  expect "deleted line -> base side, base line, ok" "$(field "$D" 13 "r['side'],r['line'],r['cite']")" "('base', 2, 'ok')"
  expect "deleted line quotes base text" "$(field "$D" 13 "'old value' in r['excerpt']")" "True"
  expect "file-level -> no line, no excerpt" "$(field "$D" 14 "r['cite'],r['line'],r['excerpt']")" "('file', None, [])"
  expect "excerpt starts 3 lines above" "$(field "$D" 12 "r['excerpt_start'],r['excerpt'][3]")" "(3, 'added = True')"
  expect "first run: everything to check" "$(python3 -c "import json;print(all(r['changed'] for r in json.load(open('$D/comments.mapped.json'))['comments']))")" "True"
  expect "numbered in file then line order" "$(python3 -c "import json;print([(r['path'],r['n']) for r in json.load(open('$D/comments.mapped.json'))['comments']])")" \
    "[('chg.py', 1), ('del.txt', 2), ('del.txt', 3), ('new.py', 4)]"
  [ -f "$D/state.next.json" ] && [ ! -f "$D/state.json" ] && pass "state written as state.next.json" || fail "state file"
fi

# 2. drafted at PR 1's head, checked at later heads: moved, ambiguous, gone
D="$WORK/moved"; target "$D" "$H2"
comments "$D" "$(c 21 chg.py "$CHGH")" "$(c 22 brace.c "$BRACEH")" "$(c 23 dup.c "$DUPH")" \
  "$(c 24 gone.py "$GONEH")" "$(c 25 missing.py "$MISSH")" "$(c 26 shift.c "$BRACEH")"
if run "$D"; then
  expect "two lines inserted above -> moved, drafted line kept" "$(field "$D" 21 "r['cite'],r['line'],r['drafted_line']")" "('moved', 8, 6)"
  expect "repeated } matched by its preceding hunk line" "$(field "$D" 22 "r['cite'],r['line'],r['ambiguous']")" "('moved', 8, False)"
  expect "still more than one candidate -> ambiguous, nearest" "$(field "$D" 23 "r['cite'],r['line'],r['ambiguous']")" "('moved', 5, True)"
  expect "drafted text deleted -> gone" "$(field "$D" 24 "r['cite']")" "gone"
  expect "gone quotes the hunk as drafted" "$(field "$D" 24 "r['excerpt_start'],r['excerpt']")" "(1, ['keep', 'remove me'])"
  expect "file deleted -> gone" "$(field "$D" 25 "r['cite'],r['excerpt']")" "('gone', ['here'])"
  expect "another } landed on the drafted line -> moved to the paired one" "$(field "$D" 26 "r['cite'],r['line'],r['ambiguous']")" "('moved', 9, False)"
fi
D="$WORK/lone"; target "$D" "$H1"; comments "$D" "$(c 27 dup.c $'@@ -6,1 +6,1 @@\n }')"
run "$D" && expect "lone match on a recurring line -> ok but ambiguous" "$(field "$D" 27 "r['cite'],r['line'],r['ambiguous']")" "('ok', 6, True)"
D="$WORK/far"; target "$D" "$H3"; comments "$D" "$(c 21 chg.py "$CHGH")"
run "$D" && expect "twenty lines inserted above -> still moved" "$(field "$D" 21 "r['cite'],r['line']")" "('moved', 28)"

# 3. stack: does the commented code survive the later PRs?
D="$WORK/stack"; mkdir -p "$D"; cat > "$D/target.json" <<T
{"kind":"stack","repo":"fx/repo","repo_path":"$R","cli":"gh","base":"$B","head":"$H2",
 "prs":[{"number":1,"base":"$B","head":"$H1"},{"number":2,"base":"$H1","head":"$H2"}]}
T
comments "$D" "$(c 31 new.py $'@@ -0,0 +1,2 @@\n+def f():')" "$(c 32 chg.py "$CHGH")" "$(c 33 rw.c "$BRACEH")"
if run "$D"; then
  expect "renamed in a later PR -> survives false" "$(field "$D" 31 "r['cite'],r['later']")" "('ok', [{'pr': 2, 'survives': False, 'ambiguous': False}])"
  expect "unchanged in a later PR -> survives true" "$(field "$D" 32 "r['later']")" "[{'pr': 2, 'survives': True, 'ambiguous': False}]"
  expect "body rewritten, its } kept -> survives false" "$(field "$D" 33 "r['later']")" "[{'pr': 2, 'survives': False, 'ambiguous': False}]"
fi

# 4. re-run: edited, new and removed comments; numbers kept
D="$WORK/rerun"; target "$D" "$H1"
comments "$D" "$(c 41 chg.py "$CHGH")" "$(c 42 new.py "$NEWH")" "$(c 43 del.txt "$DELH")"
run "$D" && mv "$D/state.next.json" "$D/state.json"
comments "$D" "$(c 41 chg.py "$CHGH")" "$(c 42 new.py "$NEWH" 2026-02-02T00:00:00Z)" "$(c 44 brace.c $'@@ -1,1 +1,1 @@\n fn a() {')"
if run "$D"; then
  expect "unedited -> not changed, number kept" "$(field "$D" 41 "r['changed'],r['n']")" "(False, 1)"
  expect "edited -> changed, number kept" "$(field "$D" 42 "r['changed'],r['n']")" "(True, 3)"
  expect "new -> changed, next number" "$(field "$D" 44 "r['changed'],r['n']")" "(True, 4)"
  expect "missing id -> removed" "$(python3 -c "import json;print(json.load(open('$D/comments.mapped.json'))['removed'])")" "[43]"
fi

# 4b. numbers are never reused: remove the highest-numbered comment, then add one
D="$WORK/renumber"; target "$D" "$H1"
comments "$D" "$(c 45 chg.py "$CHGH")" "$(c 46 new.py "$NEWH")"
run "$D" && mv "$D/state.next.json" "$D/state.json"
comments "$D" "$(c 45 chg.py "$CHGH")"
run "$D" && mv "$D/state.next.json" "$D/state.json"
comments "$D" "$(c 45 chg.py "$CHGH")" "$(c 47 del.txt "$DELH")"
run "$D" && expect "new comment after a removal takes a fresh number" "$(field "$D" 47 "r['n']")" "3"

# 4c. stack re-run where only a later PR's head moved: survival re-checked
D="$WORK/stackmove"; mkdir -p "$D"
stack() { cat > "$D/target.json" <<T
{"kind":"stack","repo":"fx/repo","repo_path":"$R","cli":"gh","base":"$B","head":"$1",
 "prs":[{"number":1,"base":"$B","head":"$H1"},{"number":2,"base":"$H1","head":"$1"}]}
T
}
stack "$H1"; comments "$D" "$(c 48 rw.c "$BRACEH")"
run "$D" && mv "$D/state.next.json" "$D/state.json"
stack "$H2"
run "$D" && expect "later PR rewrote the line -> changed" "$(field "$D" 48 "r['changed'],r['later'][0]['survives']")" "(True, False)"

# 5. re-run after the head moved: only comments on files that changed between heads
D="$WORK/headmove"; target "$D" "$H1"
comments "$D" "$(c 51 chg.py "$CHGH")" "$(c 52 del.txt "$DELH")"
run "$D" && mv "$D/state.next.json" "$D/state.json"
target "$D" "$H2"
if run "$D"; then
  expect "file changed between heads -> changed" "$(field "$D" 51 "r['changed']")" "True"
  expect "file untouched between heads -> not changed" "$(field "$D" 52 "r['changed']")" "False"
fi

# 6. no comments
D="$WORK/empty"; target "$D" "$H1"; echo '[]' > "$D/comments.json"
run "$D" && expect "empty -> empty record list" "$(python3 -c "import json;print(json.load(open('$D/comments.mapped.json')))")" "{'comments': [], 'removed': []}"

[ "$FAIL" = 0 ] && echo "ALL PASS" || { echo "SOME FAILED"; exit 1; }
