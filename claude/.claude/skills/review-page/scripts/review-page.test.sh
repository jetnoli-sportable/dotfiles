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
  [ -n "${SERVER2_PID:-}" ] && kill "$SERVER2_PID" 2>/dev/null
  [ -n "${SERVER3_PID:-}" ] && kill "$SERVER3_PID" 2>/dev/null
  [ -n "${REATTACH2_PID:-}" ] && kill "$REATTACH2_PID" 2>/dev/null
  rm -rf "$TMPDIR"
}
trap cleanup EXIT

cat > "$SPEC" <<'EOF'
{
  "title": "Fixture Review",
  "intro_md": "Test fixture — **three** items.",
  "sections": [{"title": "Fixture section", "md": "## Directions\n- alpha\n- beta", "open": true}],
  "hide_columns": ["group"],
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
if echo "$BODY" | grep -q "that&#39;s tricky"; then
  pass "esc() escapes a single quote as &#39;"
else
  fail "esc() did not escape a single quote in item-1's 'what' field"
fi
if echo "$BODY" | grep -q "id=\"details-item-2\""; then
  fail "item-2 has no description/fields but got a details row"
else
  pass "no details row for an item without description/fields"
fi
if echo "$BODY" | grep -q '<details class="page-section" open><summary>Fixture section</summary>' \
   && echo "$BODY" | grep -q "<ul class='md-ul'><li>alpha</li><li>beta</li></ul>"; then
  pass "sections panel renders with block markdown"
else
  fail "sections panel missing or mis-rendered"
fi
if echo "$BODY" | grep -q '\.review-table \.col-group { display: none; }'; then
  pass "hide_columns emits the column CSS rule"
else
  fail "hide_columns CSS rule missing"
fi
if echo "$BODY" | grep -q "<h5 class='md-h'>Plan</h5>" \
   && echo "$BODY" | grep -q "<ol class='md-ol'><li>first</li><li>second</li></ol>" \
   && echo "$BODY" | grep -q "<pre class='md-pre'>code here</pre>" \
   && echo "$BODY" | grep -q "<li>after fence bullet</li>"; then
  pass "md_block renders heading, ordered list, fence; an unclosed fence does not swallow the tail"
else
  fail "md_block heading/ol/fence/unclosed-fence rendering wrong"
fi
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
SPEC2="$TMPDIR/spec2.json"
OUT2="$TMPDIR/answers2.json"
STATE2="$OUT2.buffer-state"
LOG2="$TMPDIR/server2.log"
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
  REATTACH2_OUTFILE="$TMPDIR/reattach2.out"
  python3 "$SCRIPT_DIR/review-page.py" --reattach "$OUT2" > "$REATTACH2_OUTFILE" 2>&1 &
  REATTACH2_PID=$!

  sleep 0.5
  if kill -0 "$REATTACH2_PID" 2>/dev/null; then
    pass "--reattach: closed=0/pid-alive case blocks rather than returning immediately"
  else
    fail "--reattach returned before the review was ever submitted"
  fi

  SPEC2_HASH="$(sha256sum "$SPEC2" | awk '{print $1}')"
  SUBMIT2_PAYLOAD="$TMPDIR/submit2.json"
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
SPEC3="$TMPDIR/spec3.json"
OUT3="$TMPDIR/answers3.json"
LOG3="$TMPDIR/server3.log"
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
SPEC4="$TMPDIR/spec4.json"
OUT4="$TMPDIR/answers4.json"
STATE4="$OUT4.buffer-state"
LOG4="$TMPDIR/server4.log"
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
