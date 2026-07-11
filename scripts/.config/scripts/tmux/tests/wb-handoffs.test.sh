#!/usr/bin/env bash
# Unit tests for wb_append_handoff (U1) — the shared "## Handoffs"-append
# helper wired into cmd_pause/cmd_done/cmd_resume. Plain-bash assertions
# against fixture files, same convention as handoff-poller.test.sh's own
# handoff_append_followup coverage (that helper's closest sibling in
# handoff.sh) — but unlike handoff_append_followup (which inserts its new
# bullet immediately after the heading, so repeated calls read
# newest-first), wb_append_handoff always appends at the END of an
# existing section, so these tests assert oldest-first ordering, not
# newest-first. Sources wb.sh directly (safe: the BASH_SOURCE guard at its
# end), same convention as wb-pause.test.sh / wb-resume.test.sh.
# Run: bash scripts/.config/scripts/tmux/tests/wb-handoffs.test.sh
set -uo pipefail

WB="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/wb.sh"
FIXTURE="$(mktemp -d -t wb-handoffs-fixture.XXXXXX)"
trap 'rm -rf "$FIXTURE"' EXIT

fail=0
assert() { # <desc> <expected-regex> <actual>
  if printf '%s' "$3" | grep -qE "$2"; then
    echo "ok   - $1"
  else
    echo "FAIL - $1"
    echo "       expected match: $2"
    echo "       got: $(printf '%s' "$3" | head -5)"
    fail=1
  fi
}

# assert_no_double_blank <desc> <file> — a stray double blank line (two
# consecutive empty lines) betrays sloppy insertion-point bookkeeping; this
# is the "no stray blank-line drift" check the plan's empty-section edge
# case calls for, generalized to every fixture below.
assert_no_double_blank() {
  if grep -Pzq '\n\n\n' "$2"; then
    echo "FAIL - $1: found a stray double blank line"
    fail=1
  else
    echo "ok   - $1: no stray double blank lines"
  fi
}

# shellcheck disable=SC1090
source "$WB"
set +e   # wb.sh sets -e; this test intentionally captures non-zero exits

# --- heading missing entirely, no "## Decisions" -> fresh section at EOF ---
NO_HEADING="$FIXTURE/no-heading.md"
printf -- '---\nstatus: doing\n---\n# Title\n\n## Plan\n\nsome plan text\n' > "$NO_HEADING"
wb_append_handoff "$NO_HEADING" "wb pause" 'Session paused via `wb pause`.'
assert "missing entirely: creates ## Handoffs" '^## Handoffs$' "$(cat "$NO_HEADING")"
assert "missing entirely: entry heading present" '^### [0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2} — wb pause \(auto\)$' "$(cat "$NO_HEADING")"
assert "missing entirely: message present" 'Session paused via `wb pause`\.' "$(cat "$NO_HEADING")"
assert "missing entirely: prior content untouched" 'some plan text' "$(cat "$NO_HEADING")"
assert_no_double_blank "missing entirely" "$NO_HEADING"

# --- heading missing, "## Decisions" exists -> inserted right before it ----
DECISIONS_ONLY="$FIXTURE/decisions-only.md"
printf -- '---\nstatus: doing\n---\n# Title\n\n## Plan\n\nsome plan text\n\n## Decisions\n' > "$DECISIONS_ONLY"
wb_append_handoff "$DECISIONS_ONLY" "wb pause" 'Session paused via `wb pause`.'
assert "missing + Decisions present: creates ## Handoffs" '^## Handoffs$' "$(cat "$DECISIONS_ONLY")"
assert "missing + Decisions present: prior content untouched" 'some plan text' "$(cat "$DECISIONS_ONLY")"
h_line="$(grep -n '^## Handoffs$' "$DECISIONS_ONLY" | cut -d: -f1)"
d_line="$(grep -n '^## Decisions$' "$DECISIONS_ONLY" | cut -d: -f1)"
if [ -n "$h_line" ] && [ -n "$d_line" ] && [ "$h_line" -lt "$d_line" ]; then
  echo "ok   - missing + Decisions present: Handoffs lands before Decisions"
else
  echo "FAIL - missing + Decisions present: Handoffs should land before Decisions (h=$h_line, d=$d_line)"; fail=1
fi
assert_no_double_blank "missing + Decisions present" "$DECISIONS_ONLY"

# --- heading present but section EMPTY (blank line then next heading) -----
# Edge case: appends cleanly, no stray blank-line drift.
EMPTY_SECTION="$FIXTURE/empty-section.md"
printf -- '---\nstatus: doing\n---\n# Title\n\n## Handoffs\n\n## Decisions\n' > "$EMPTY_SECTION"
wb_append_handoff "$EMPTY_SECTION" "wb pause" 'Session paused via `wb pause`.'
assert "empty section: entry appears" 'Session paused via `wb pause`\.' "$(cat "$EMPTY_SECTION")"
entry_count_empty="$(grep -cE '^### .* — wb pause \(auto\)$' "$EMPTY_SECTION")"
if [ "$entry_count_empty" -eq 1 ]; then
  echo "ok   - empty section: exactly one entry heading"
else
  echo "FAIL - empty section: expected exactly 1 entry heading, got $entry_count_empty"; fail=1
fi
assert_no_double_blank "empty section" "$EMPTY_SECTION"
he_line="$(grep -n '^## Handoffs$' "$EMPTY_SECTION" | cut -d: -f1)"
de_line="$(grep -n '^## Decisions$' "$EMPTY_SECTION" | cut -d: -f1)"
if [ -n "$he_line" ] && [ -n "$de_line" ] && [ "$he_line" -lt "$de_line" ]; then
  echo "ok   - empty section: still bounded by ## Handoffs .. ## Decisions"
else
  echo "FAIL - empty section: section bounds wrong (h=$he_line, d=$de_line)"; fail=1
fi

# --- heading present, 2+ existing entries -> new entry lands at the END ----
# (end of section, not immediately after the heading); existing entries'
# order must stay undisturbed.
MULTI="$FIXTURE/multi-entry.md"
printf -- '---\nstatus: doing\n---\n# Title\n\n## Handoffs\n\n### 2026-07-01 09:00 — wb pause (auto)\n\nFirst entry.\n\n### 2026-07-02 10:00 — wb done (auto)\n\nSecond entry.\n\n## Decisions\n' > "$MULTI"
wb_append_handoff "$MULTI" "wb resume" 'Third entry.'
assert "2+ entries: first entry survives" 'First entry\.' "$(cat "$MULTI")"
assert "2+ entries: second entry survives" 'Second entry\.' "$(cat "$MULTI")"
assert "2+ entries: new (third) entry appended" 'Third entry\.' "$(cat "$MULTI")"

l1="$(grep -nF 'First entry.' "$MULTI" | cut -d: -f1)"
l2="$(grep -nF 'Second entry.' "$MULTI" | cut -d: -f1)"
l3="$(grep -nF 'Third entry.' "$MULTI" | cut -d: -f1)"
if [ -n "$l1" ] && [ -n "$l2" ] && [ -n "$l3" ] && [ "$l1" -lt "$l2" ] && [ "$l2" -lt "$l3" ]; then
  echo "ok   - 2+ entries: order preserved, new entry lands after all existing ones"
else
  echo "FAIL - 2+ entries: wrong order (first=$l1, second=$l2, third=$l3)"; fail=1
fi

entry_count_multi="$(grep -cE '^### .* — wb (pause|done|resume) \(auto\)$' "$MULTI")"
if [ "$entry_count_multi" -eq 3 ]; then
  echo "ok   - 2+ entries: exactly 3 entry headings total"
else
  echo "FAIL - 2+ entries: expected 3 entry headings, got $entry_count_multi"; fail=1
fi

d_line_multi="$(grep -n '^## Decisions$' "$MULTI" | cut -d: -f1)"
if [ -n "$d_line_multi" ] && [ -n "$l3" ] && [ "$l3" -lt "$d_line_multi" ]; then
  echo "ok   - 2+ entries: new entry still lands inside the Handoffs section"
else
  echo "FAIL - 2+ entries: new entry landed outside the Handoffs section (third=$l3, decisions=$d_line_multi)"; fail=1
fi
assert_no_double_blank "2+ entries" "$MULTI"

# --- heading present, section runs to EOF (no other heading follows) ------
EOF_CASE="$FIXTURE/eof-case.md"
printf -- '---\nstatus: doing\n---\n# Title\n\n## Handoffs\n\n### 2026-07-01 09:00 — wb pause (auto)\n\nFirst entry.\n' > "$EOF_CASE"
wb_append_handoff "$EOF_CASE" "wb done" 'Second entry (eof).'
assert "eof case: prior entry survives" 'First entry\.' "$(cat "$EOF_CASE")"
assert "eof case: new entry appended" 'Second entry \(eof\)\.' "$(cat "$EOF_CASE")"
l1e="$(grep -nF 'First entry.' "$EOF_CASE" | cut -d: -f1)"
l2e="$(grep -nF 'Second entry (eof).' "$EOF_CASE" | cut -d: -f1)"
if [ -n "$l1e" ] && [ -n "$l2e" ] && [ "$l1e" -lt "$l2e" ]; then
  echo "ok   - eof case: new entry appended after the existing one"
else
  echo "FAIL - eof case: wrong order (first=$l1e, second=$l2e)"; fail=1
fi
assert_no_double_blank "eof case" "$EOF_CASE"

# --- neither heading present, file already ends in a blank line -----------
# The EOF-fallback branch used to unconditionally print a leading blank line
# with no prev-check, unlike its two sibling branches — a file already
# ending in a blank line got a double blank before the fresh section.
NO_HEADING_TRAILING_BLANK="$FIXTURE/no-heading-trailing-blank.md"
printf -- '---\nstatus: doing\n---\n# Title\n\n## Plan\n\nsome plan text\n\n' > "$NO_HEADING_TRAILING_BLANK"
wb_append_handoff "$NO_HEADING_TRAILING_BLANK" "wb pause" 'Session paused via `wb pause`.'
assert_no_double_blank "missing entirely, trailing blank in source" "$NO_HEADING_TRAILING_BLANK"
assert "missing entirely, trailing blank: creates ## Handoffs" '^## Handoffs$' "$(cat "$NO_HEADING_TRAILING_BLANK")"

# --- heading-shaped text inside ## Plan prose must not be mistaken for a --
# --- real heading (confirmed live: this spliced a Handoffs entry mid- -----
# --- paragraph before this guard existed) ----------------------------------
# The literal line "## Decisions" appears here NOT preceded by a blank line
# (mid-sentence, wrapped onto its own line) — only the real heading further
# down, which IS preceded by a blank line, may match.
HEADING_IN_PROSE="$FIXTURE/heading-in-prose.md"
printf -- '---\nstatus: doing\n---\n# Title\n\n## Plan\n\nThe insertion rule mirrors handoff_append_followup: insert right before\n## Decisions\nwhen that heading is missing, same convention.\n\n## Decisions\n\n- some decision\n' > "$HEADING_IN_PROSE"
wb_append_handoff "$HEADING_IN_PROSE" "wb pause" 'Session paused via `wb pause`.'
prose_line="$(grep -n '^## Decisions$' "$HEADING_IN_PROSE" | head -1 | cut -d: -f1)"
handoffs_line="$(grep -n '^## Handoffs$' "$HEADING_IN_PROSE" | cut -d: -f1)"
real_decisions_line="$(grep -n '^## Decisions$' "$HEADING_IN_PROSE" | tail -1 | cut -d: -f1)"
if [ -n "$handoffs_line" ] && [ -n "$real_decisions_line" ] && [ "$handoffs_line" -lt "$real_decisions_line" ] && [ "$handoffs_line" -gt "$prose_line" ]; then
  echo "ok   - heading-in-prose: entry lands at the REAL heading, not the prose quote"
else
  echo "FAIL - heading-in-prose: entry landed at the wrong location (handoffs=$handoffs_line, first ## Decisions text=$prose_line, real heading=$real_decisions_line)"; fail=1
fi
assert "heading-in-prose: quoted prose sentence still intact, not split" 'insert right before' "$(cat "$HEADING_IN_PROSE")"
plan_line="$(grep -n '^## Plan$' "$HEADING_IN_PROSE" | cut -d: -f1)"
if [ -n "$plan_line" ] && [ -n "$handoffs_line" ] && [ "$plan_line" -lt "$prose_line" ] && [ "$prose_line" -lt "$handoffs_line" ]; then
  echo "ok   - heading-in-prose: ## Plan's prose is untouched and precedes the new ## Handoffs section"
else
  echo "FAIL - heading-in-prose: ## Plan content was disturbed (plan=$plan_line, prose-quote=$prose_line, handoffs=$handoffs_line)"; fail=1
fi

[ "$fail" -eq 0 ] && echo "ALL PASS" || echo "FAILURES"
exit "$fail"
