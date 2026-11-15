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

reject bad-stage 's["stage"] = "done"' "stage" "shaping"
reject missing-file-arg 's["task"] = ""' "task"

# Unreadable input fails cleanly.
echo "{not json" > "$WORK/broken.json"; check "$WORK/broken.json"
if [ "$RC" != 0 ] && [ -n "$OUT" ]; then pass "rejects: malformed json"; else fail "malformed json (rc=$RC)"; fi
check "$WORK/missing.json"
if [ "$RC" != 0 ] && [ -n "$OUT" ]; then pass "rejects: missing file"; else fail "missing file (rc=$RC)"; fi

exit "$FAIL"
