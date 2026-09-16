#!/usr/bin/env bash
# Tests for scripts/.config/scripts/skill-usage.sh (U4, KTD6) — reproducible
# per-skill usage counts over the local Claude Code transcript store.
# Fixture-based, subprocess invocation (the script is a standalone CLI, not
# sourced), same assert-function convention as the wb-*.test.sh suites.
# Run: bash scripts/.config/scripts/tmux/tests/skill-usage.test.sh
set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SCRIPT="$SELF_DIR/skill-usage.sh"

FIXTURE="$(mktemp -d -t skill-usage-fixture.XXXXXX)"
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
refute() { # <desc> <unexpected-regex> <actual>
  if printf '%s' "$3" | grep -qE "$2"; then
    echo "FAIL - $1"
    echo "       unexpected match: $2"
    fail=1
  else
    echo "ok   - $1"
  fi
}

mk_skill() { # <skills-dir> <name>
  mkdir -p "$1/$2"
  : > "$1/$2/SKILL.md"
}

# =============================================================================
# Scenario: against a fixture transcript containing both invocation forms
# (slash-command tag, Skill-tool block) for the SAME skill, each is counted
# once — and a plugin-prefixed name normalizes to its bare form and merges
# with a bare-form hit for the same skill.
# =============================================================================

T1="$FIXTURE/t1"; S1="$FIXTURE/s1"
mkdir -p "$T1/proj"
cat > "$T1/proj/a.jsonl" <<'JSONL'
{"type":"user","message":{"role":"user","content":"<command-name>/ce-review</command-name>\n<command-message>ce-review</command-message>"}}
{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Skill","input":{"skill":"myplugin:ce-review"}}]}}
JSONL
mk_skill "$S1" ce-review

out="$(bash "$SCRIPT" --dir "$T1" --skills-dir "$S1" 2>&1)"; rc=$?
assert_eq "both forms + merge: exit 0" 0 "$rc"
assert "both forms + merge: ce-review counted twice (once per form, merged under the bare name)" \
  '^ce-review[[:space:]]+2[[:space:]]' "$out"

# =============================================================================
# Scenario: with --skills-dir given, a detected `<command-name>` hit that is
# NOT a real skill (a built-in slash command like /clear or /model — the
# tag shape is identical, so the script can't tell them apart on its own)
# does not leak into the report as a spurious row. Only the known roster
# (from --skills-dir) is reported; detected-but-unknown names are dropped,
# not unioned in.
# =============================================================================

T1b="$FIXTURE/t1b"; S1b="$FIXTURE/s1b"
mkdir -p "$T1b/proj"
cat > "$T1b/proj/a.jsonl" <<'JSONL'
{"type":"user","message":{"role":"user","content":"<command-name>/clear</command-name>\n<command-message>clear</command-message>"}}
{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Skill","input":{"skill":"ce-review"}}]}}
JSONL
mk_skill "$S1b" ce-review

out="$(bash "$SCRIPT" --dir "$T1b" --skills-dir "$S1b" 2>&1)"; rc=$?
assert_eq "built-in-command leak guard: exit 0" 0 "$rc"
assert "built-in-command leak guard: the real skill is reported" \
  '^ce-review[[:space:]]+1[[:space:]]' "$out"
if printf '%s' "$out" | grep -qE '^clear[[:space:]]'; then
  echo "FAIL - built-in-command leak guard: '/clear' (not a skill) leaked into the report as a row"
  fail=1
else
  echo "ok   - built-in-command leak guard: '/clear' (not a skill) did not leak into the report"
fi

# =============================================================================
# Scenario: a skill mentioned only in prose (no tag, no tool block) is
# reported as zero, and the output carries the not-detected caveat.
# =============================================================================

T2="$FIXTURE/t2"; S2="$FIXTURE/s2"
mkdir -p "$T2/proj"
cat > "$T2/proj/a.jsonl" <<'JSONL'
{"type":"assistant","message":{"content":[{"type":"text","text":"I used the ghost-skill approach here, roughly."}]}}
JSONL
mk_skill "$S2" ghost-skill

out="$(bash "$SCRIPT" --dir "$T2" --skills-dir "$S2" 2>&1)"; rc=$?
assert_eq "prose-only mention: exit 0" 0 "$rc"
assert "prose-only mention: ghost-skill reported as zero" '^ghost-skill[[:space:]]+0[[:space:]]' "$out"
assert "prose-only mention: not-detected caveat present" 'not-detected' "$out"
assert "output: general caveat about natural-language invisibility" 'invisible to this method' "$out"

# =============================================================================
# Scenario: --since excludes a transcript outside the window.
# =============================================================================

T3="$FIXTURE/t3"; S3="$FIXTURE/s3"
mkdir -p "$T3/proj"
cat > "$T3/proj/old.jsonl" <<'JSONL'
{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Skill","input":{"skill":"old-skill"}}]}}
JSONL
# Force the "old" file's mtime well in the past so --since excludes it.
touch -d "2020-01-01" "$T3/proj/old.jsonl"
cat > "$T3/proj/new.jsonl" <<'JSONL'
{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Skill","input":{"skill":"new-skill"}}]}}
JSONL
mk_skill "$S3" old-skill
mk_skill "$S3" new-skill

out="$(bash "$SCRIPT" --dir "$T3" --skills-dir "$S3" --since "$(date +%F)" 2>&1)"; rc=$?
assert_eq "--since window: exit 0" 0 "$rc"
assert "--since window: new-skill (in window) detected" '^new-skill[[:space:]]+1[[:space:]]' "$out"
assert "--since window: old-skill (outside window) reported as zero" '^old-skill[[:space:]]+0[[:space:]]' "$out"

# =============================================================================
# Scenario: a malformed/truncated JSONL line does not abort the run — the
# script skips it and continues, still counting the valid line alongside it.
# =============================================================================

T4="$FIXTURE/t4"
mkdir -p "$T4/proj"
cat > "$T4/proj/a.jsonl" <<'JSONL'
not even json {{{ truncated
{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Skill","input":{"skill":"survives-malformed-sibling"}}]}}
JSONL

out="$(bash "$SCRIPT" --dir "$T4" 2>&1)"; rc=$?
assert_eq "malformed line: exit 0 (run not aborted)" 0 "$rc"
assert "malformed line: valid sibling line still counted" \
  '^survives-malformed-sibling[[:space:]]+1[[:space:]]' "$out"

# =============================================================================
# Scenario: exit code is 0 when the transcript directory exists but matches
# nothing.
# =============================================================================

T5="$FIXTURE/t5-empty"
mkdir -p "$T5"
out="$(bash "$SCRIPT" --dir "$T5" 2>&1)"; rc=$?
assert_eq "empty transcript dir, no matches: exit 0" 0 "$rc"
refute "empty transcript dir: no skill rows printed" '^[a-z].*[[:space:]][0-9]' "$out"

[ "$fail" -eq 0 ] && echo "ALL PASS" || echo "FAILURES"
exit "$fail"
