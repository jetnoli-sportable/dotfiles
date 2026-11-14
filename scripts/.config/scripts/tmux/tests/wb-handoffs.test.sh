#!/usr/bin/env bash
# Unit tests for wb_append_handoff (U1) — the shared "## Handoffs"-append
# helper wired into cmd_pause/cmd_done/cmd_resume. Plain-bash assertions
# against fixture files, same convention as handoff-poller.test.sh's own
# handoff_append_followup coverage (that helper's sibling in handoff.sh,
# which now delegates to the same _wb_append_under_heading core).
# wb_append_handoff keeps ONE entry under "## Handoffs" (the newest); the
# previous entries move to dossiers/<stem>/handoffs/<date>-<hhmm>.md. Sources
# wb.sh directly (safe: the BASH_SOURCE guard at its end), same convention as
# wb-pause.test.sh / wb-resume.test.sh.
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

export TASKS_DIR="$FIXTURE/tasks"
mkdir -p "$TASKS_DIR"
# shellcheck disable=SC1090
source "$WB"
set +e   # wb.sh sets -e; this test intentionally captures non-zero exits

# --- heading missing entirely, no other section -> fresh section at EOF ---
NO_HEADING="$FIXTURE/no-heading.md"
printf -- '---\nstatus: doing\n---\n# Title\n\n## Plan\n\nsome plan text\n' > "$NO_HEADING"
wb_append_handoff "$NO_HEADING" "wb pause" 'Session paused via `wb pause`.'
assert "missing entirely: creates ## Handoffs" '^## Handoffs$' "$(cat "$NO_HEADING")"
assert "missing entirely: entry heading present" '^### [0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2} — wb pause \(auto\)$' "$(cat "$NO_HEADING")"
assert "missing entirely: message present" 'Session paused via `wb pause`\.' "$(cat "$NO_HEADING")"
assert "missing entirely: prior content untouched" 'some plan text' "$(cat "$NO_HEADING")"
assert_no_double_blank "missing entirely" "$NO_HEADING"

# --- heading missing, other headings exist -> fresh section at EOF ---------
DECISIONS_ONLY="$FIXTURE/decisions-only.md"
printf -- '---\nstatus: doing\n---\n# Title\n\n## Plan\n\nsome plan text\n\n## Decisions\n' > "$DECISIONS_ONLY"
wb_append_handoff "$DECISIONS_ONLY" "wb pause" 'Session paused via `wb pause`.'
assert "missing + other headings: creates ## Handoffs" '^## Handoffs$' "$(cat "$DECISIONS_ONLY")"
assert "missing + other headings: prior content untouched" 'some plan text' "$(cat "$DECISIONS_ONLY")"
h_line="$(grep -n '^## Handoffs$' "$DECISIONS_ONLY" | cut -d: -f1)"
d_line="$(grep -n '^## Decisions$' "$DECISIONS_ONLY" | cut -d: -f1)"
if [ -n "$h_line" ] && [ -n "$d_line" ] && [ "$h_line" -gt "$d_line" ]; then
  echo "ok   - missing + other headings: Handoffs lands at EOF, after Decisions"
else
  echo "FAIL - missing + other headings: Handoffs should land at EOF (h=$h_line, d=$d_line)"; fail=1
fi
assert_no_double_blank "missing + other headings" "$DECISIONS_ONLY"

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

# --- heading present, 2+ existing entries -> newest stays, the rest move ---
# The task file keeps ONE entry; every older one becomes a file under
# dossiers/<stem>/handoffs/, named by its own timestamp (time order).
MULTI="$TASKS_DIR/multi-entry.md"
printf -- '---\nstatus: doing\n---\n# Title\n\n## Handoffs\n\n### 2026-07-01 09:00 — wb pause (auto)\n\nFirst entry.\n\n### 2026-07-02 10:00 — wb done (auto)\n\nSecond entry.\n\n## Decisions\n' > "$MULTI"
wb_append_handoff "$MULTI" "wb resume" 'Third entry.'
HD="$TASKS_DIR/dossiers/multi-entry/handoffs"
assert "2+ entries: the task file holds the newest entry" 'Third entry\.' "$(cat "$MULTI")"
if grep -qF 'First entry.' "$MULTI" || grep -qF 'Second entry.' "$MULTI"; then
  echo "FAIL - 2+ entries: older entries should have left the task file"; fail=1
else
  echo "ok   - 2+ entries: older entries left the task file"
fi
assert "2+ entries: first entry moved to its own handoffs/ file" 'First entry\.' "$(cat "$HD/2026-07-01-0900.md" 2>&1)"
assert "2+ entries: second entry moved to its own handoffs/ file" 'Second entry\.' "$(cat "$HD/2026-07-02-1000.md" 2>&1)"
assert "2+ entries: moved entries are flagged auto: true" '^auto: true$' "$(cat "$HD/2026-07-01-0900.md" 2>&1)"
assert "2+ entries: moved entry records its source" '^source: wb pause$' "$(cat "$HD/2026-07-01-0900.md" 2>&1)"
entry_count_multi="$(grep -cE '^### ' "$MULTI")"
if [ "$entry_count_multi" -eq 1 ]; then
  echo "ok   - 2+ entries: exactly 1 entry heading left in the task file"
else
  echo "FAIL - 2+ entries: expected 1 entry heading, got $entry_count_multi"; fail=1
fi
hl="$(grep -n '^## Handoffs$' "$MULTI" | cut -d: -f1)"
d_line_multi="$(grep -n '^## Decisions$' "$MULTI" | cut -d: -f1)"
l3="$(grep -nF 'Third entry.' "$MULTI" | cut -d: -f1)"
if [ -n "$hl" ] && [ -n "$l3" ] && [ -n "$d_line_multi" ] && [ "$hl" -lt "$l3" ] && [ "$l3" -lt "$d_line_multi" ]; then
  echo "ok   - 2+ entries: the new entry sits inside the Handoffs section"
else
  echo "FAIL - 2+ entries: new entry outside the Handoffs section (handoffs=$hl third=$l3 decisions=$d_line_multi)"; fail=1
fi
assert_no_double_blank "2+ entries" "$MULTI"

# --- heading present, section runs to EOF (no other heading follows) ------
EOF_CASE="$TASKS_DIR/eof-case.md"
printf -- '---\nstatus: doing\n---\n# Title\n\n## Handoffs\n\n### 2026-07-01 09:00 — wb pause (auto)\n\nFirst entry.\n' > "$EOF_CASE"
wb_append_handoff "$EOF_CASE" "wb done" 'Second entry (eof).'
assert "eof case: prior entry moved to handoffs/" 'First entry\.' "$(cat "$TASKS_DIR/dossiers/eof-case/handoffs/2026-07-01-0900.md" 2>&1)"
assert "eof case: new entry in the task file" 'Second entry \(eof\)\.' "$(cat "$EOF_CASE")"
if grep -qF 'First entry.' "$EOF_CASE"; then
  echo "FAIL - eof case: prior entry still in the task file"; fail=1
else
  echo "ok   - eof case: prior entry left the task file"
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
# --- paragraph before this guard existed); a missing Handoffs goes at EOF --
# The literal line "## Decisions" appears here NOT preceded by a blank line
# (mid-sentence, wrapped onto its own line) — only the real heading further
# down, which IS preceded by a blank line, may match.
HEADING_IN_PROSE="$FIXTURE/heading-in-prose.md"
printf -- '---\nstatus: doing\n---\n# Title\n\n## Plan\n\nThe insertion rule mirrors handoff_append_followup: insert right before\n## Decisions\nwhen that heading is missing, same convention.\n\n## Decisions\n\n- some decision\n' > "$HEADING_IN_PROSE"
wb_append_handoff "$HEADING_IN_PROSE" "wb pause" 'Session paused via `wb pause`.'
prose_line="$(grep -n '^## Decisions$' "$HEADING_IN_PROSE" | head -1 | cut -d: -f1)"
handoffs_line="$(grep -n '^## Handoffs$' "$HEADING_IN_PROSE" | cut -d: -f1)"
real_decisions_line="$(grep -n '^## Decisions$' "$HEADING_IN_PROSE" | tail -1 | cut -d: -f1)"
if [ -n "$handoffs_line" ] && [ -n "$real_decisions_line" ] && [ "$handoffs_line" -gt "$real_decisions_line" ]; then
  echo "ok   - heading-in-prose: entry lands at EOF, not spliced at the prose quote"
else
  echo "FAIL - heading-in-prose: entry landed at the wrong location (handoffs=$handoffs_line, real ## Decisions=$real_decisions_line)"; fail=1
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
