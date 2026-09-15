#!/usr/bin/env bash
# Tests for U8 (docs/plans/2026-09-15-001-feat-weekly-review-loop-plan.md) —
# retiring /parked-items and archiving the /park ledger. Runs against the
# real repo/task-store checkout (read-only except the docgen dry check,
# which only regenerates already-tracked .html outputs), not a fixture —
# there is nothing to fixture: this is a one-time retirement, not a
# reusable verb.
# Run: bash scripts/.config/scripts/tmux/tests/parked-items-retirement.test.sh
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../../.." && pwd)"
TASKS_DIR="${TASKS_DIR:-$HOME/code/tasks}"
ARCHIVE="$TASKS_DIR/dossiers/dotfiles--feat-weekly-review/ledger-archive-2026-09-15.md"

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

# =============================================================================
# The skill and its guide are gone; the .html twin was hand-deleted (docgen
# never prunes).
# =============================================================================

if [ -d "$REPO_ROOT/claude/.claude/skills/parked-items" ]; then
  echo "FAIL - skills/parked-items/ still exists"; fail=1
else
  echo "ok   - skills/parked-items/ deleted"
fi
if [ -f "$REPO_ROOT/docs/guides/parked-items.md" ]; then
  echo "FAIL - docs/guides/parked-items.md still exists"; fail=1
else
  echo "ok   - docs/guides/parked-items.md deleted"
fi
if [ -f "$REPO_ROOT/docs/guides/parked-items.html" ]; then
  echo "FAIL - docs/guides/parked-items.html still exists (docgen never prunes — must be hand-deleted)"; fail=1
else
  echo "ok   - docs/guides/parked-items.html deleted"
fi

# =============================================================================
# ledger.jsonl itself is gone.
# =============================================================================

if [ -f "$HOME/.claude/parked-items/ledger.jsonl" ]; then
  echo "FAIL - ~/.claude/parked-items/ledger.jsonl still exists"; fail=1
else
  echo "ok   - ~/.claude/parked-items/ledger.jsonl deleted"
fi

# =============================================================================
# The archive: every one of the 58 entries present, with timestamp, repo,
# and note. Skipped (not failed) if the archive isn't reachable from this
# checkout (e.g. TASKS_DIR overridden in a sandboxed run).
# =============================================================================

if [ -f "$ARCHIVE" ]; then
  n="$(grep -c '^### ' "$ARCHIVE")"
  assert_eq "archive: all 58 entries present" 58 "$n"
  assert "archive: entries carry a timestamp" '^### [0-9]+\. [0-9]{4}-[0-9]{2}-[0-9]{2}T' "$(head -20 "$ARCHIVE")"
  assert "archive: entries carry a repo" '— [a-zA-Z0-9_.-]+ @ ' "$(head -20 "$ARCHIVE")"
  # A note can itself span multiple lines (each rendered as its own "> "
  # line), so this asserts AT LEAST one note line per entry, not exactly
  # one.
  n_notes="$(grep -c '^> ' "$ARCHIVE")"
  if [ "$n_notes" -ge 58 ]; then
    echo "ok   - archive: at least one note line per entry ($n_notes >= 58)"
  else
    echo "FAIL - archive: expected at least 58 note lines, got $n_notes"; fail=1
  fi
else
  echo "skip - archive not found at $ARCHIVE (TASKS_DIR=$TASKS_DIR) — skipping content checks"
fi

# =============================================================================
# No task file references the deleted skill in parent:/depends_on:.
# =============================================================================

if [ -d "$TASKS_DIR" ]; then
  bad="$(grep -lE '^(parent|depends_on): .*parked-items' "$TASKS_DIR"/*.md 2>/dev/null || true)"
  if [ -z "$bad" ]; then
    echo "ok   - no task file references parked-items in parent:/depends_on:"
  else
    echo "FAIL - task file(s) still reference parked-items in parent:/depends_on::"
    echo "$bad" | sed 's/^/       /'
    fail=1
  fi
else
  echo "skip - TASKS_DIR ($TASKS_DIR) not found — skipping parent:/depends_on: check"
fi

# =============================================================================
# The five named live readers (plan U8's Files list) no longer reference
# ledger.jsonl or /parked-items — this is the check that would have caught
# all five readers, scoped to the files the plan actually names rather than
# a repo-wide grep (which would also flag legitimate historical mentions in
# docs/plans, docs/archive, docs/roadmap*, docs/brainstorms, and dated
# learnings logs — none of those are live readers).
# =============================================================================

LIVE_FILES=(
  "$REPO_ROOT/scripts/.config/scripts/tmux/wb.sh"
  "$REPO_ROOT/claude/.claude/skills/close-out/SKILL.md"
  "$REPO_ROOT/claude/.claude/skills/quick-wins/SKILL.md"
  "$REPO_ROOT/claude/.claude/skills/wb-done/SKILL.md"
  "$REPO_ROOT/claude/.claude/skills/review-page/SKILL.md"
  "$REPO_ROOT/docs/wb-guide.md"
  "$REPO_ROOT/docs/glossary.md"
  "$REPO_ROOT/claude/README.md"
  "$REPO_ROOT/install.sh"
)

for f in "${LIVE_FILES[@]}"; do
  [ -f "$f" ] || { echo "FAIL - expected live file missing: $f"; fail=1; continue; }
  hit="$(grep -nE 'ledger\.jsonl|/parked-items\b' "$f" 2>/dev/null || true)"
  if [ -z "$hit" ]; then
    echo "ok   - $(basename "$f") (${f#"$REPO_ROOT"/}): no ledger.jsonl/parked-items reference"
  else
    echo "FAIL - ${f#"$REPO_ROOT"/} still references ledger.jsonl or /parked-items:"
    echo "$hit" | sed 's/^/       /'
    fail=1
  fi
done

# wb.sh specifically: no live function still reads the ledger path.
if grep -qE 'HOME/\.claude/parked-items' "$REPO_ROOT/scripts/.config/scripts/tmux/wb.sh" 2>/dev/null; then
  echo "FAIL - wb.sh still reads a path under ~/.claude/parked-items/"; fail=1
else
  echo "ok   - wb.sh no longer reads any path under ~/.claude/parked-items/"
fi

# wb_parked_count is gone entirely (repointed to wb_week_unreviewed_count).
if grep -q '^wb_parked_count()' "$REPO_ROOT/scripts/.config/scripts/tmux/wb.sh" 2>/dev/null; then
  echo "FAIL - wb_parked_count() still defined"; fail=1
else
  echo "ok   - wb_parked_count() removed"
fi

[ "$fail" -eq 0 ] && echo "ALL PASS" || echo "FAILURES"
exit "$fail"
