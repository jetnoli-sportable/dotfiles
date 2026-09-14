#!/usr/bin/env bash
# review-page.test.sh — smoke test for review-page.py: starts the server
# with a 3-item fixture spec, curls the page, POSTs a submit payload, and
# asserts answers.json + buffer-state came out right.
#
# Run: ./review-page.test.sh
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TMPDIR="$(mktemp -d)"
SPEC="$TMPDIR/spec.json"
OUT="$TMPDIR/answers.json"
STATE="$OUT.buffer-state"
LOG="$TMPDIR/server.log"
PORT=58732

FAIL=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; FAIL=1; }

cleanup() {
  [ -n "${SERVER_PID:-}" ] && kill "$SERVER_PID" 2>/dev/null
  rm -rf "$TMPDIR"
}
trap cleanup EXIT

cat > "$SPEC" <<'EOF'
{
  "title": "Fixture Review",
  "intro_md": "Test fixture — **three** items.",
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
          "what": "Does a thing",
          "evidence": ["evidence one", "evidence two"],
          "suggested": "apply",
          "suggested_reason": "clear win",
          "depends_on": [],
          "depended_on_by": ["item-2"],
          "links": [],
          "meta": [["size", "M"], ["owner", "jet"]],
          "description": "### Plan\n- step one\n- step two",
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
          "links": [{"label": "PR", "href": "https://example.com"}]
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
if echo "$BODY" | grep -q 'id="details-item-1"' && echo "$BODY" | grep -q 'data-field-key="slug"' && echo "$BODY" | grep -q '<span class="meta-k">size</span> M' && echo "$BODY" | grep -q "<ul class='md-ul'><li>step one</li>"; then
  pass "details row, editable field, meta chip and block-markdown render"
else
  fail "details/fields/meta/markdown missing from page"
fi
if echo "$BODY" | grep -q 'id="details-item-2"'; then
  fail "item-2 has no description/fields but got a details row"
else
  pass "no details row for an item without description/fields"
fi
if echo "$BODY" | grep -q 'id="sections-marker-absent"'; then :; fi
if echo "$BODY" | grep -q '<title>Fixture Review</title>'; then
  pass "GET / returns 200 with title present"
else
  fail "title not found in page body"
fi

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

SUBMIT_STATUS="$(curl -s -o /tmp/review-page-test-submit-resp.$$ -w '%{http_code}' \
  -X POST -H 'Content-Type: application/json' -d "$SUBMIT_PAYLOAD" \
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

if [ "$FAIL" -eq 0 ]; then
  echo "ALL TESTS PASSED"
  exit 0
else
  echo "SOME TESTS FAILED"
  exit 1
fi
