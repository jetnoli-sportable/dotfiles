#!/usr/bin/env bash
# verify-plan.test.sh — tests verify-plan.py `check`: the example passes silently, and
# mutated copies of it fail with a message naming the item and field.
# Run: ./verify-plan.test.sh
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(dirname "$SCRIPT_DIR")"
TOOL="$SCRIPT_DIR/verify-plan.py"
FIXTURE="$SKILL_DIR/fixtures/example-verify.json"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/verify-plan-test.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

FAIL=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; FAIL=1; }

# check <file>: sets OUT and RC.
check() { OUT="$(python3 "$TOOL" check "$1" 2>&1)"; RC=$?; }

# mutate <name> <python statements on s>: writes a changed copy of the fixture to $WORK/<name>.json
mutate() {
  python3 - "$FIXTURE" "$WORK/$1.json" "$2" <<'PY'
import copy, json, sys
s = json.load(open(sys.argv[1]))
exec(sys.argv[3])
json.dump(s, open(sys.argv[2], "w"))
PY
}

# reject <name> <python> <substring>...: the mutated copy must fail and the output must hold every substring
reject() {
  local name="$1" py="$2"; shift 2
  mutate "$name" "$py"; check "$WORK/$name.json"
  local ok=1 sub
  [ "$RC" != 0 ] || ok=0
  for sub in "$@"; do [[ "$OUT" == *"$sub"* ]] || ok=0; done
  if [ "$ok" = 1 ]; then pass "rejects: $name"; else fail "rejects: $name (rc=$RC out=$OUT)"; fi
}

# accept <name> <python>: the mutated copy must pass with no output
accept() {
  mutate "$1" "$2"; check "$WORK/$1.json"
  if [ "$RC" = 0 ] && [ -z "$OUT" ]; then pass "accepts: $1"; else fail "accepts: $1 (rc=$RC out=$OUT)"; fi
}

# The fixture passes, silently.
check "$FIXTURE"
if [ "$RC" = 0 ] && [ -z "$OUT" ]; then pass "example fixture passes silently"; else fail "example fixture (rc=$RC out=$OUT)"; fi

# Dangling reference: the message names the test and the id.
reject unknown-req 's["tests"][0]["requirements"].append("R99")' "$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["tests"][0]["id"])' "$FIXTURE")" "R99"
reject dup-req-id 's["requirements"][1]["id"] = s["requirements"][0]["id"]' "$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["requirements"][0]["id"])' "$FIXTURE")" "duplicate"
reject bad-access 's["walkthrough"]["steps"][0]["access"] = ["root"]' "root" "local" "cloud-read" "cloud-write" "prod" "permission"
reject bad-lane 's["tests"][0]["lane"] = "smoke"' "smoke" "unit" "integration" "e2e" "walkthrough"
reject unknown-part 's["tests"][0]["real_parts"].append("nope")' "nope"
reject unknown-decision 's["tests"][0]["decision"] = "D99"' "D99"
reject unknown-step-req 's["walkthrough"]["steps"][0]["requirements"].append("R98")' "R98"
reject blank-name 's["tests"][0]["name"] = "   "' "name"

# Coverage: strip the uncovered requirement's cover, then add each way out.
UNCOVERED='r = s["requirements"][-1]["id"]
for t in s["tests"]:
    t["requirements"] = [x for x in t["requirements"] if x != r]
for st in s["walkthrough"]["steps"]:
    st["requirements"] = [x for x in st["requirements"] if x != r]
for d in s["decisions"]:
    d["requirements"] = [x for x in d.get("requirements", []) if x != r]
s["requirements"][-1].pop("accepted_gap", None)'
reject uncovered "$UNCOVERED" "uncovered"
accept covered-by-open-decision "$UNCOVERED
d = [d for d in s['decisions'] if d['status'] == 'open'][0]
d['requirements'] = [r]"
accept covered-by-accepted-gap "$UNCOVERED
s['requirements'][-1]['accepted_gap'] = 'Cannot be exercised without a second household.'"
reject answered-decision-does-not-cover "$UNCOVERED
d = [d for d in s['decisions'] if d['status'] == 'answered'][0]
d['requirements'] = [r]" "uncovered"

# Optional sections.
accept no-parts 'del s["parts"]
for t in s["tests"]:
    t.pop("real_parts", None); t.pop("faked_parts", None)'
reject no-parts-but-tests-name-parts 'del s["parts"]' "real_parts"
accept no-run 's.pop("run", None)'
reject run-unknown-step 's["run"] = {"revision": s["walkthrough"]["revision"], "steps": {"S99": {"outcome": "passed"}}}' "S99"
reject run-bad-outcome 's["run"] = {"revision": s["walkthrough"]["revision"], "steps": {s["walkthrough"]["steps"][0]["id"]: {"outcome": "meh"}}}' "meh" "passed" "failed" "skipped" "not-run"
accept run-valid 's["run"] = {"revision": s["walkthrough"]["revision"], "steps": {s["walkthrough"]["steps"][0]["id"]: {"outcome": "skipped", "skip_reason": "no cloud access today"}}}'

# Optional title and summary: strings, never required.
reject title-not-string 's["title"] = 5' "title"
reject summary-not-string 's["summary"] = ["x"]' "summary"
accept no-title-no-summary 's.pop("title", None); s.pop("summary", None)'
reject bad-stage 's["stage"] = "done"' "stage" "shaping"
reject missing-file-arg 's["task"] = ""' "task"

# Unreadable input fails cleanly.
echo "{not json" > "$WORK/broken.json"; check "$WORK/broken.json"
if [ "$RC" != 0 ] && [ -n "$OUT" ]; then pass "rejects: malformed json"; else fail "malformed json (rc=$RC)"; fi
check "$WORK/missing.json"
if [ "$RC" != 0 ] && [ -n "$OUT" ]; then pass "rejects: missing file"; else fail "missing file (rc=$RC)"; fi

# ---------------------------------------------------------------- build
# build_copy <name> [python]: copies the fixture (optionally mutated) into $WORK/<name>/verify.json
build_copy() {
  mkdir -p "$WORK/$1"
  if [ -n "${2:-}" ]; then mutate "$1" "$2"; mv "$WORK/$1.json" "$WORK/$1/verify.json"; else cp "$FIXTURE" "$WORK/$1/verify.json"; fi
}
build() { OUT="$(python3 "$TOOL" build "$1" 2>&1)"; RC=$?; }

build_copy b1; build "$WORK/b1/verify.json"
if [ "$RC" = 0 ] && [ -s "$WORK/b1/shaping.html" ]; then pass "build writes shaping.html beside the source"; else fail "build (rc=$RC out=$OUT)"; fi
cp "$WORK/b1/shaping.html" "$WORK/first.html"; build "$WORK/b1/verify.json"
if cmp -s "$WORK/first.html" "$WORK/b1/shaping.html"; then pass "building twice is byte-identical"; else fail "build is not deterministic"; fi

# Hostile text: a closing script tag in a requirement sentence.
build_copy b2 's["requirements"][0]["sentence"] = "Try </script><script>alert(1)</script> and <!-- x & y"'
build "$WORK/b2/verify.json"
if [ "$RC" = 0 ] && python3 - "$WORK/b1/shaping.html" "$WORK/b2/shaping.html" <<'PYEOF'
import re, sys
def counts(p):
    t = open(p, encoding="utf-8").read()
    return len(re.findall(r"<script", t, re.I)), len(re.findall(r"</script", t, re.I))
a, b = counts(sys.argv[1]), counts(sys.argv[2])
sys.exit(0 if a == b and a[0] == a[1] and a[0] >= 2 else 1)
PYEOF
then pass "a </script in a sentence builds with one closing tag per script block"; else fail "script-end safety (rc=$RC out=$OUT)"; fi

# Both pages: map.html is written beside shaping.html, identical on every build.
if [ -s "$WORK/b1/map.html" ]; then pass "build writes map.html beside the source"; else fail "map.html missing"; fi
cp "$WORK/b1/map.html" "$WORK/first-map.html"; build "$WORK/b1/verify.json"
if cmp -s "$WORK/first-map.html" "$WORK/b1/map.html"; then pass "building twice is byte-identical for map.html too"; else fail "map.html is not deterministic"; fi
if python3 - "$WORK/b2/map.html" <<'PYEOF'
import re, sys
t = open(sys.argv[1], encoding="utf-8").read()
a, b = len(re.findall(r"<script", t, re.I)), len(re.findall(r"</script", t, re.I))
sys.exit(0 if a == b and a >= 2 else 1)
PYEOF
then pass "a </script in a sentence builds map.html with one closing tag per script block"; else fail "map.html script-end safety"; fi

for PAGE in shaping.html map.html; do
  H="$WORK/b1/$PAGE"
  # Page metadata comment (the format wb.sh _wb_page_meta reads).
  if python3 - "$H" <<'PYEOF'
import sys
lines = open(sys.argv[1], encoding="utf-8").read().split("\n")
start = [i for i, l in enumerate(lines) if l.strip() == "---"]
ok = bool(start) and start[0] < 5 and len(start) >= 2
block = lines[start[0] + 1:start[1]] if ok else []
ok = ok and "tags: [verify-plan]" in block
ok = ok and any(l.startswith("retire_when: task:example--book-holds done") for l in block)
sys.exit(0 if ok else 1)
PYEOF
  then pass "$PAGE: metadata block opens within the first five lines with tags and retire_when"; else fail "$PAGE: page metadata block"; fi
  # Colour blocks and no vertical-scroll containers.
  if grep -q 'prefers-color-scheme: *dark' "$H" && grep -q ':root:not(\[data-theme="light"\])' "$H" && grep -q ':root\[data-theme="dark"\]' "$H"; then pass "$PAGE: light and dark colour blocks are present"; else fail "$PAGE: colour blocks"; fi
  if grep -Eiq 'overflow(-y)? *: *(auto|scroll)|max-height' "$H"; then fail "$PAGE: has a vertical-scroll container rule"; else pass "$PAGE: no vertical-scroll container rules"; fi
  if grep -q '<title>[^<]*Book holds' "$H"; then pass "$PAGE: browser title uses the document title"; else fail "$PAGE: browser title"; fi
done
build_copy b3 's["page"]["url"] = "https://example.test/p"'; build "$WORK/b3/verify.json"
if grep -q '^url: https://example.test/p$' "$WORK/b3/shaping.html" && grep -q '^url: https://example.test/p$' "$WORK/b3/map.html"; then pass "page url is emitted when present"; else fail "page url line"; fi
build_copy b5 's.pop("title")'; build "$WORK/b5/verify.json"
if grep -q '<title>[^<]*example--book-holds' "$WORK/b5/map.html"; then pass "browser title falls back to the task name"; else fail "title fallback"; fi

# An invalid document is refused and nothing is written.
build_copy b4 's["tests"][0]["requirements"].append("R99")'; build "$WORK/b4/verify.json"
if [ "$RC" != 0 ] && [[ "$OUT" == *R99* ]] && [ ! -e "$WORK/b4/shaping.html" ] && [ ! -e "$WORK/b4/map.html" ]; then pass "build refuses an invalid document"; else fail "build invalid (rc=$RC out=$OUT)"; fi

exit "$FAIL"
