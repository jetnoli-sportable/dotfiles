#!/usr/bin/env bash
# Tests for `/wb-breakdown` + `wb breakdown --apply` (docs/plans/
# 2026-07-12-001-feat-wb-breakdown-skill-plan.md). Sections are added unit
# by unit; this header + the seed section below are U1's.
#
# Run: bash scripts/.config/scripts/tmux/tests/wb-breakdown.test.sh
set -uo pipefail

WB="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/wb.sh"
FIXTURE_CODE="$(mktemp -d -t wb-breakdown-code.XXXXXX)"
FIXTURE_TASKS="$(mktemp -d -t wb-breakdown-tasks.XXXXXX)"
trap 'rm -rf "$FIXTURE_CODE" "$FIXTURE_TASKS"' EXIT

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

printf -- '---\nstatus: planned\npath:\nrepo:\nbranch:\nworktree:\nparent:\ndepends_on:\ntags: []\ncreated:\nclosed:\nreviewed:\n---\n# Title\n\n## Plan\n\n\n\n## Handoffs\n\n\n\n## Decisions\n\n\n\n## Done\n\n\n\n## Follow-ups\n' \
  > "$FIXTURE_TASKS/TEMPLATE.md"

# real (throwaway) git repo under the fixture CODE_DIR, matching cmd_new's
# own $CODE_DIR/$repo/.git check for the --jira/ticket-parent path below.
mkdir -p "$FIXTURE_CODE/proj"
git init -q "$FIXTURE_CODE/proj"
git -C "$FIXTURE_CODE/proj" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init

export CODE_DIR="$FIXTURE_CODE"
export TASKS_DIR="$FIXTURE_TASKS"

# shellcheck disable=SC1090
source "$WB"
set +e   # wb.sh sets -e; this test intentionally captures non-zero exits

# =============================================================================
# U1 — wb_seed_planned_child / --jira ticket-parent extension
# =============================================================================

# --- happy path: every field round-trips, worktree stays blank --------------
out="$(printf 'absorb: board-embed bullets\nmore plan content\n' \
  | wb_seed_planned_child proj feat-hub-v0-board-embed dotfiles--feat-hub-v0 2>&1)"
child_file="$TASKS_DIR/proj--feat-hub-v0-board-embed.md"
assert_eq "seed: prints the resolved file path" "$child_file" "$out"
assert_eq "seed: file was created" "$child_file" "$([ -f "$child_file" ] && echo "$child_file")"
assert_eq "seed: status: planned" "planned" "$(wb_get_frontmatter "$child_file" status)"
assert_eq "seed: worktree: stays blank" "" "$(wb_get_frontmatter "$child_file" worktree)"
assert_eq "seed: branch: is the raw slug" "feat-hub-v0-board-embed" "$(wb_get_frontmatter "$child_file" branch)"
assert_eq "seed: repo: set" "proj" "$(wb_get_frontmatter "$child_file" repo)"
assert_eq "seed: parent: set" "dotfiles--feat-hub-v0" "$(wb_get_frontmatter "$child_file" parent)"
assert "seed: title falls back to slug-derived form when omitted" "^feat hub v0 board embed$" "$(wb_task_title "$child_file")"
assert "seed: plan body lands under ## Plan" "absorb: board-embed bullets" "$(cat "$child_file")"

# --- explicit title (the buffer's own "goal:" line, per U3's "frontmatter +
# goal title") overrides the slug-derived fallback -----------------------
out_goal="$(printf 'goal-driven plan body\n' \
  | wb_seed_planned_child proj feat-hub-v0-artifact-index dotfiles--feat-hub-v0 'one-line goal for the artifact index' 2>&1)"
child_goal="$TASKS_DIR/proj--feat-hub-v0-artifact-index.md"
assert_eq "seed: explicit title overrides slug-derived form" "one-line goal for the artifact index" "$(wb_task_title "$child_goal")"

# --- existing file: refuse, file untouched -----------------------------------
before="$(cat "$child_file")"
err="$(printf 'ignored\n' | wb_seed_planned_child proj feat-hub-v0-board-embed dotfiles--feat-hub-v0 2>&1 1>/dev/null)"
rc=$?
assert_eq "seed: existing file returns 1" 1 "$rc"
assert "seed: existing-file error names the stem" "proj--feat-hub-v0-board-embed" "$err"
assert_eq "seed: existing file left byte-identical" "$before" "$(cat "$child_file")"

# --- backslash-bearing body round-trips byte-identical -----------------------
backslash_body='```
a regex: \K\[foo\]
a path: C:\Users\jet\.claude
tabs:\there
```'
out2="$(printf '%s\n' "$backslash_body" \
  | wb_seed_planned_child proj feat-hub-v0-backslash dotfiles--feat-hub-v0 2>&1)"
child2="$TASKS_DIR/proj--feat-hub-v0-backslash.md"
plan_section="$(awk '/^## Plan/{f=1;next} /^## Handoffs/{f=0} f' "$child2" | sed '/^$/d')"
expected_section="$(printf '%s\n' "$backslash_body" | sed '/^$/d')"
assert_eq "seed: backslash body round-trips byte-identical" "$expected_section" "$plan_section"

# --- AE2 (half): a planned child (blank worktree:) is invisible to reconcile -
recon_out="$(wb_reconcile_collect 2>/dev/null)"
if printf '%s' "$recon_out" | grep -qE '^missing\s+proj\s'; then
  echo "FAIL - seed: planned child with blank worktree: should not be flagged by wb_reconcile_collect"
  fail=1
else
  echo "ok   - seed: planned child with blank worktree: produces zero reconcile findings"
fi

# --- ticket-parent path: `wb new --planned --jira <url>` --------------------
jira_body='ticket description line 1
ticket description line 2 with a \K escape'
out3="$(printf '%s\n' "$jira_body" \
  | cmd_new --planned --jira 'https://sportable.atlassian.net/browse/SFB-1234' proj feat-ticket-parent 2>&1)"
ticket_file="$TASKS_DIR/proj--feat-ticket-parent.md"
assert_eq "ticket-parent: prints the resolved file path" "$ticket_file" "$out3"
assert_eq "ticket-parent: jira: stores the full URL" "https://sportable.atlassian.net/browse/SFB-1234" "$(wb_get_frontmatter "$ticket_file" jira)"
assert_eq "ticket-parent: status: planned" "planned" "$(wb_get_frontmatter "$ticket_file" status)"
assert_eq "ticket-parent: worktree: stays blank" "" "$(wb_get_frontmatter "$ticket_file" worktree)"
assert "ticket-parent: stdin plan body lands under ## Plan" "ticket description line 1" "$(cat "$ticket_file")"
assert "ticket-parent: body byte-identical incl. backslash sequence" 'ticket description line 2 with a \\K escape' "$(cat "$ticket_file")"

# --- --jira without --planned is a clean usage error -------------------------
err2="$(cmd_new --jira 'https://x/y' proj feat-bad 2>&1 1>/dev/null)"
rc2=$?
assert_eq "--jira without --planned: exit 1" 1 "$rc2"
assert "--jira without --planned: clear error" 'only valid together with --planned' "$err2"
assert_eq "--jira without --planned: no file created" "" "$([ -f "$TASKS_DIR/proj--feat-bad.md" ] && echo exists)"

# --- existing paths unchanged: wb_seed_task still flips planned->doing ------
wb_seed_task proj feat-regression '.worktrees/feat-regression' >/dev/null
assert_eq "regression: wb_seed_task still stamps status: doing" "doing" "$(wb_get_frontmatter "$TASKS_DIR/proj--feat-regression.md" status)"
assert_eq "regression: wb_seed_task still stamps worktree:" ".worktrees/feat-regression" "$(wb_get_frontmatter "$TASKS_DIR/proj--feat-regression.md" worktree)"

[ "$fail" -eq 0 ] && echo "ALL PASS"
exit "$fail"
