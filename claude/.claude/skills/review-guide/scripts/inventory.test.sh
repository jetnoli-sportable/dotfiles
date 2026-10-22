#!/usr/bin/env bash
# inventory.test.sh — tests for inventory.py against a mktemp fixture repo and
# the real PR #95 range in this repo (1c96d77^..1c96d77).
#
# Run: ./inventory.test.sh
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INV="$SCRIPT_DIR/inventory.py"
WORK="$(mktemp -d)"
FAIL=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; FAIL=1; }
trap 'rm -rf "$WORK"' EXIT

# jq-less JSON probe: py '<expr over d>' < json
py() { python3 -c "import json,sys; d=json.load(sys.stdin); print($1)"; }
check() { # name expected actual
  if [ "$2" = "$3" ]; then pass "$1"; else fail "$1 (expected '$2', got '$3')"; fi
}

R="$WORK/repo"
mkdir -p "$R" && cd "$R" || exit 1
g() { git -c user.name=t -c user.email=t@t -c commit.gpgsign=false "$@"; }
g init -q .
printf '* text=auto\n' > .gitattributes
printf 'one\ntwo\nthree\nfour\nfive\nsix\nseven\neight\n' > moveme.txt
printf 'old\n' > doc.md
g add -A && g commit -qm base
BASE=$(g rev-parse HEAD)

printf '*.gen.js linguist-generated\n' >> .gitattributes
mkdir -p src tests skills/x automated_testing/helpers
printf 'a\nb\nc\n' > src/app.py
printf 't1\nt2\n' > tests/app_test.py
printf 'f1\n' > automated_testing/helpers/fake_store.py
printf 's1\ns2\ns3\ns4\n' > skills/x/SKILL.md
printf 'd1\nd2\n' >> doc.md
printf 'g1\ng2\ng3\n' > out.gen.js
printf 'package-lock\n' > package-lock.json
printf '// DO NOT EDIT\nx\n' > built.js
git mv moveme.txt moved.txt
printf '\000\001\002' > blob.bin
g add -A && g commit -qm head
HEAD_SHA=$(g rev-parse HEAD)

OUT=$(python3 "$INV" "$R" "$BASE" "$HEAD_SHA" --words 40)
bucket() { echo "$OUT" | py "[f['bucket'] for f in d['files'] if f['path']=='$1'][0]"; }

check "logic file bucketed" logic "$(bucket src/app.py)"
check "test file bucketed" tests "$(bucket tests/app_test.py)"
check "helper under automated_testing/ is tests" tests "$(bucket automated_testing/helpers/fake_store.py)"
check "SKILL.md is agent-instructions" agent-instructions "$(bucket skills/x/SKILL.md)"
check "markdown doc bucketed" docs "$(bucket doc.md)"
check "linguist-generated bucketed" generated "$(bucket out.gen.js)"
check "lockfile is generated" generated "$(bucket package-lock.json)"
check "do-not-edit banner is generated" generated "$(bucket built.js)"

# totals equal numstat (added+removed, binary counted as 0)
EXPECT=$(g diff --numstat -M "$BASE" "$HEAD_SHA" | awk '$1!="-"{s+=$1+$2} END{print s}')
GOT=$(echo "$OUT" | py "sum(b['lines'] for b in d['totals'].values())")
check "bucket totals equal numstat sum" "$EXPECT" "$GOT"
check "logic total lines (app.py 3 + .gitattributes 1)" 4 "$(echo "$OUT" | py "d['totals']['logic']['lines']")"
check "docs total lines" 2 "$(echo "$OUT" | py "d['totals']['docs']['lines']")"

# pure rename
check "pure rename is rename-only" rename-only "$(bucket moved.txt)"
check "rename old path recorded" moveme.txt "$(echo "$OUT" | py "[f['old_path'] for f in d['files'] if f['path']=='moved.txt'][0]")"
check "rename-only counts zero lines" 0 "$(echo "$OUT" | py "d['totals']['rename-only']['lines']")"

# binary
check "binary listed" 1 "$(echo "$OUT" | py "len([f for f in d['files'] if f['path']=='blob.bin'])")"
check "binary has zero lines" 0 "$(echo "$OUT" | py "[f['added']+f['removed'] for f in d['files'] if f['path']=='blob.bin'][0]")"

# hot flags
printf 'rm -rf "$X"\nflock -n 9\n' > src/run.sh
printf 'rm -rf is dangerous; flock too\n' >> doc.md
mkdir -p infra .github/workflows db/migrations
printf 'x\n' > infra/main.tf
printf 'x\n' > .github/workflows/ci.yml
printf 'x\n' > db/migrations/001.sql
g add -A && g commit -qm hot
H2=$(g rev-parse HEAD)
OUT2=$(python3 "$INV" "$R" "$HEAD_SHA" "$H2")
hot() { echo "$OUT2" | py "sorted([f for f in d['files'] if f['path']=='$1'][0]['hot'])"; }
check "rm -rf in script flags destructive" "['destructive', 'locking']" "$(hot src/run.sh)"
check "same text in doc does not flag" "[]" "$(hot doc.md)"
check ".tf flagged" "['terraform']" "$(hot infra/main.tf)"
check "workflow flagged" "['ci']" "$(hot .github/workflows/ci.yml)"
check "migration flagged" "['migrations']" "$(hot db/migrations/001.sql)"
check "top-level hot union" "['ci', 'destructive', 'locking', 'migrations', 'terraform']" "$(echo "$OUT2" | py "sorted(d['hot'])")"

# proportion: plan doc adds explanation lines
mkdir -p docs/plans
printf 'p1\np2\np3\np4\n' > docs/plans/2026-01-01-plan.md
g add -A && g commit -qm plan
H3=$(g rev-parse HEAD)
OUT3=$(python3 "$INV" "$R" "$H2" "$H3" --words 10)
check "plan lines + words are explanation" 14 "$(echo "$OUT3" | py "d['proportion']['explanation']")"
OUT4=$(python3 "$INV" "$R" "$BASE" "$H3" --words 10)
check "ratio = explanation / logic" "$(python3 -c "print(round(14/ ($(echo "$OUT4" | py "d['totals']['logic']['lines']")),3))")" "$(echo "$OUT4" | py "d['proportion']['ratio']")"

# real PR #95
cd "$SCRIPT_DIR" || exit 1
REAL=$(python3 "$INV" "$(git rev-parse --show-toplevel)" 1c96d77^ 1c96d77 2>&1)
for kv in logic:1501 agent-instructions:402 tests:2463 docs:715 generated:639; do
  check "PR #95 ${kv%%:*}" "${kv##*:}" "$(echo "$REAL" | py "d['totals']['${kv%%:*}']['lines']" 2>&1)"
done

[ "$FAIL" = 0 ] && echo "ALL PASS" || { echo "SOME FAILED"; exit 1; }
