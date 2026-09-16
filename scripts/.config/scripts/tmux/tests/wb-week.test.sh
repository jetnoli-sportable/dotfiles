#!/usr/bin/env bash
# Tests for `wb week` (cmd_week) — the standing weekly-capture doc and the
# per-week output record (U1, KTD1-KTD3). Same fixture/harness convention as
# wb-set.test.sh (fixture TASKS_DIR, source wb.sh, set +e to capture non-zero
# exits).
# Run: bash scripts/.config/scripts/tmux/tests/wb-week.test.sh
set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WB="$SELF_DIR/wb.sh"

FIXTURE="$(mktemp -d -t wb-week-fixture.XXXXXX)"
trap 'rm -rf "$FIXTURE"' EXIT

fail=0
assert() { # <desc> <expected-regex> <actual>
  if printf '%s' "$3" | grep -qE "$2"; then
    echo "ok   - $1"
  else
    echo "FAIL - $1"
    echo "       expected match: $2"
    echo "       got: $(printf '%s' "$3" | head -8)"
    fail=1
  fi
}
assert_eq() { # <desc> <expected> <actual>
  if [ "$2" = "$3" ]; then
    echo "ok   - $1"
  else
    echo "FAIL - $1 (expected '$2', got '$3')"
    fail=1
  fi
}

export XDG_STATE_HOME="$FIXTURE/state"
export HOME="$FIXTURE/home"
export CODE_DIR="$FIXTURE/code"
export TASKS_DIR="$FIXTURE/tasks"
mkdir -p "$XDG_STATE_HOME" "$HOME" "$CODE_DIR" "$TASKS_DIR"

# shellcheck disable=SC1090
source "$WB"
set +e   # wb.sh sets -e; this suite intentionally captures non-zero exits

CAPTURE="$TASKS_DIR/weeks/capture.md"

# =============================================================================
# Scenario: `wb week path` on an empty store creates the doc with exactly
# the four sections and prints its path.
# =============================================================================

out="$(cmd_week path 2>&1)"; rc=$?
assert_eq "path (create): exit 0" 0 "$rc"
assert_eq "path (create): prints the capture path" "$CAPTURE" "$out"
[ -f "$CAPTURE" ] || { echo "FAIL - path (create): file was not created"; fail=1; }
n_sections="$(grep -c '^## ' "$CAPTURE")"
assert_eq "path (create): exactly four sections" 4 "$n_sections"
for h in "What's working" "What's not working" "New ideas" "Notes"; do
  grep -qF "## $h" "$CAPTURE" || { echo "FAIL - path (create): missing section '$h'"; fail=1; }
done

# =============================================================================
# Scenario: `wb week path` a second time is idempotent.
# =============================================================================

before_content="$(cat "$CAPTURE")"
out2="$(cmd_week path 2>&1)"; rc2=$?
assert_eq "path (idempotent): exit 0" 0 "$rc2"
assert_eq "path (idempotent): same path" "$CAPTURE" "$out2"
after_content="$(cat "$CAPTURE")"
assert_eq "path (idempotent): content unchanged" "$before_content" "$after_content"
n_sections2="$(grep -c '^## ' "$CAPTURE")"
assert_eq "path (idempotent): still exactly four sections" 4 "$n_sections2"

# =============================================================================
# Scenario: `wb week append` inserts under the right heading, leaves the
# other three untouched, and round-trips a body with quotes/# intact.
# =============================================================================

rm -f "$CAPTURE"
out="$(cmd_week append "What's not working" 'reviews stall — quoting "the" spec, then a # comment-looking bit' 2>&1)"
rc=$?
assert_eq "append: exit 0" 0 "$rc"
content="$(cat "$CAPTURE")"

# Section boundaries: the entry must land strictly between "## What's not
# working" and the next "## " heading.
between="$(awk '/^## What.s not working$/{f=1;next} /^## /{f=0} f' "$CAPTURE")"
assert "append: entry lands under the right heading" \
  'reviews stall .* "the" spec, then a # comment-looking bit' "$between"

for h in "What's working" "New ideas" "Notes"; do
  section_body="$(awk -v h="## $h" '$0==h{f=1;next} /^## /{f=0} f' "$CAPTURE")"
  if printf '%s' "$section_body" | grep -q '\[ \]'; then
    echo "FAIL - append: '$h' section unexpectedly gained an entry"; fail=1
  fi
done
echo "ok   - append: other three sections left untouched"

# =============================================================================
# Scenario: an unknown section name exits non-zero, names the four valid
# sections, and writes nothing.
# =============================================================================

before_content="$(cat "$CAPTURE")"
out="$(cmd_week append "Grievances" "should be refused" 2>&1)"; rc=$?
assert_eq "append unknown section: exit 1" 1 "$rc"
assert "append unknown section: names all four sections" \
  "What's working.*What's not working.*New ideas.*Notes" "$out"
after_content="$(cat "$CAPTURE")"
assert_eq "append unknown section: file untouched" "$before_content" "$after_content"

# =============================================================================
# Scenario: an appended entry round-trips its date, repo and branch stamp
# intact. This fixture's $CODE_DIR is not a git repo, so the stamp falls
# back to "?" for both — still asserts the stamp SHAPE (date · repo/branch)
# round-trips rather than being dropped or mangled.
# =============================================================================

rm -f "$CAPTURE"
cmd_week append "New ideas" "stamped entry" >/dev/null 2>&1
today="$(date +%F)"
assert "stamp round-trip: date/repo/branch shape present" \
  "\\- \\[ \\] $today · .*/.* · stamped entry" "$(cat "$CAPTURE")"

# =============================================================================
# Scenario: `wb week record` on the very first-ever review — no prior
# weeks/*-review.md exists, so `_wb_week_previous_record`'s pipeline finds
# zero matches and exits 1. Under this suite's `set +e` that's invisible,
# so this scenario invokes wb.sh as a real subprocess (same convention as
# wb-board.test.sh) to exercise the actual `set -euo pipefail` the CLI runs
# under. Regression for: that non-zero return propagated through
# `prev="$(_wb_week_previous_record "$iso")"` and killed the whole `wb week
# record` call via set -e before it ever wrote the record — every
# first-ever weekly review would fail silently.
# =============================================================================

FIRSTRUN_TASKS="$(mktemp -d -t wb-week-firstrun.XXXXXX)"
out="$(HOME="$HOME" XDG_STATE_HOME="$XDG_STATE_HOME" CODE_DIR="$CODE_DIR" TASKS_DIR="$FIRSTRUN_TASKS" bash "$WB" week record 2026-W01 2>&1)"
rc=$?
assert_eq "first-ever record: exit 0" 0 "$rc"
FIRSTRUN_RECORD="$FIRSTRUN_TASKS/weeks/2026-W01-review.md"
assert_eq "first-ever record: prints the record path" "$FIRSTRUN_RECORD" "$out"
[ -f "$FIRSTRUN_RECORD" ] || { echo "FAIL - first-ever record: file was not created"; fail=1; }
assert "first-ever record: no previous record" "Previous record: none" "$(cat "$FIRSTRUN_RECORD" 2>/dev/null)"
rm -rf "$FIRSTRUN_TASKS"

# =============================================================================
# Scenario: `wb week record` mints weeks/<ISO>-review.md and is idempotent
# on a second call.
# =============================================================================

rm -f "$CAPTURE"
cmd_week append "What's working" "entry A" >/dev/null 2>&1
out="$(cmd_week record 2026-W10 2>&1)"; rc=$?
RECORD1="$TASKS_DIR/weeks/2026-W10-review.md"
assert_eq "record (mint): exit 0" 0 "$rc"
assert_eq "record (mint): prints the record path" "$RECORD1" "$out"
[ -f "$RECORD1" ] || { echo "FAIL - record (mint): file was not created"; fail=1; }
assert "record (mint): names the ISO week" "Week 2026-W10 review" "$(cat "$RECORD1")"
assert "record (mint): first review has no previous record" "Previous record: none" "$(cat "$RECORD1")"
assert "record (mint): rolled up entry A" "entry A" "$(cat "$RECORD1")"

before_record="$(cat "$RECORD1")"
out2="$(cmd_week record 2026-W10 2>&1)"; rc2=$?
assert_eq "record (idempotent): exit 0" 0 "$rc2"
assert_eq "record (idempotent): same path" "$RECORD1" "$out2"
after_record="$(cat "$RECORD1")"
assert_eq "record (idempotent): content unchanged" "$before_record" "$after_record"

# =============================================================================
# Scenario: a minted record links the previous week's record when one
# exists.
# =============================================================================

cmd_week append "What's working" "entry B" >/dev/null 2>&1
out="$(cmd_week record 2026-W13 2>&1)"; rc=$?
RECORD2="$TASKS_DIR/weeks/2026-W13-review.md"
assert_eq "record (link prev): exit 0" 0 "$rc"
assert "record (link prev): links the previous record" "Previous record: .*2026-W10-review\\.md" "$(cat "$RECORD2")"

# =============================================================================
# Scenario: an entry rolled into a record is not re-offered by the next
# record; an unrolled entry still is (the stranding case wb week record
# exists to fix — the old /park ledger left 12 of 58 entries untriaged
# across two reviews with no per-entry state). Rolled-up entries are
# REMOVED from the capture doc (not flipped to `- [x]` and kept forever —
# Jet, 2026-09-16: the per-week record is already the durable copy, so
# the capture doc stays bounded to only what's still unreviewed).
# =============================================================================

if grep -qF 'entry A' "$RECORD2"; then
  echo "FAIL - stranding: entry A (already rolled up in 2026-W10) was re-offered in 2026-W13"; fail=1
else
  echo "ok   - stranding: entry A already rolled up was not re-offered"
fi
assert "stranding: unreviewed entry B was offered" "entry B" "$(cat "$RECORD2")"
assert_eq "stranding: entry A removed from the capture doc (not kept as [x])" "" "$(grep -F 'entry A' "$CAPTURE")"
assert_eq "stranding: entry B removed from the capture doc after its own record" "" "$(grep -F 'entry B' "$CAPTURE")"
if grep -qF '\[x\]' "$CAPTURE"; then
  echo "FAIL - stranding: capture doc still contains a [x] line — rolled-up entries must be removed, not flipped"; fail=1
else
  echo "ok   - stranding: capture doc never accumulates [x] lines"
fi

# "What's working" (both its entries just removed) must collapse back to
# the exact same "heading, blank, next heading" shape the fresh template
# produces — never a stray double-blank or dangling line.
what_working_body="$(awk '/^## What.s working$/{f=1;next} /^## /{f=0} f' "$CAPTURE")"
assert_eq "stranding: emptied 'What's working' section is well-formed (no leftover blanks)" "" "$what_working_body"

# A THIRD entry, never rolled into any record yet, must still show up as
# unreviewed — directly asserting the marker (not a date window) is what
# drives inclusion.
cmd_week append "What's working" "entry C" >/dev/null 2>&1
assert "stranding: entry C still unreviewed before any record covers it" '\- \[ \] .*entry C' "$(cat "$CAPTURE")"

# =============================================================================
# Scenario: a section emptied by a roll-up still accepts a fresh append
# afterward — the removal must never corrupt the heading it collapses
# back to (the same shape a brand-new section starts in).
# =============================================================================

rm -f "$CAPTURE"
cmd_week append "New ideas" "entry X" >/dev/null 2>&1
cmd_week record 2026-W15 >/dev/null 2>&1   # rolls up + removes entry X, empties "New ideas"
cmd_week append "New ideas" "entry Y" >/dev/null 2>&1
between2="$(awk '/^## New ideas$/{f=1;next} /^## /{f=0} f' "$CAPTURE")"
assert "re-append into emptied section: lands under the right heading" "entry Y" "$between2"
n_sections3="$(grep -c '^## ' "$CAPTURE")"
assert_eq "re-append into emptied section: still exactly four sections" 4 "$n_sections3"

# =============================================================================
# Scenario: `wb_week_unreviewed_count` prints a single-line "0" (not "0\n0")
# when the capture doc exists but has zero unreviewed entries — the normal
# post-review state. `grep -c` already prints "0" on no match and only
# EXITS 1 to signal that; a caller doing `grep -c ... || echo 0` gets a
# second "0" line on that nonzero exit, which breaks arithmetic composition
# (exactly what `cmd_done` does with this count) under `set -e`.
# =============================================================================

cmd_week record 2026-W20 >/dev/null 2>&1   # rolls up + removes the remaining unreviewed entry (C)
out="$(wb_week_unreviewed_count)"
assert_eq "unreviewed count at zero: single-line '0'" "0" "$out"
n_lines="$(printf '%s' "$out" | wc -l)"
# wc -l counts newlines, not lines-if-no-trailing-newline; a `$(...)`
# capture strips the trailing newline either way, so a genuinely single
# "0\n" line here reads 0, and the "0\n0\n" bug would read 1.
assert_eq "unreviewed count at zero: no embedded newline" "0" "$n_lines"

# The exact arithmetic `cmd_done` performs with this value — must not
# abort under `set -e` (it would if the count carried a second line).
(
  set -e
  total=$(( $(wb_followup_count) + $(wb_week_unreviewed_count) ))
  exit "$([ "$total" -ge 0 ] && echo 0 || echo 1)"
)
assert_eq "unreviewed count at zero: cmd_done-shaped arithmetic does not abort" 0 "$?"

# =============================================================================
# Scenario: `wb_pending_counts` reports unreviewed capture entries and days
# since the last record, and does not read ledger.jsonl.
# =============================================================================

out="$(wb_pending_counts)"
assert "pending counts: reports unreviewed capture entries" '[0-9]+ unreviewed capture entries' "$out"
assert "pending counts: reports days since last review" 'since last review' "$out"
if printf '%s' "$out" | grep -qi 'parked'; then
  echo "FAIL - pending counts: still mentions the retired 'parked' ledger wording"; fail=1
else
  echo "ok   - pending counts: no ledger wording"
fi

[ "$fail" -eq 0 ] && echo "ALL PASS" || echo "FAILURES"
exit "$fail"
