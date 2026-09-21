#!/usr/bin/env bash
# Minimal render smoke test for board2's U3 renderer (wb_board_render_v2) —
# added by /ce-code-review of PR 1 (decision D1, Option B). The cutover
# deleted the old 955-line wb-board-html.test.sh; this restores a floor of
# render-output coverage: the pipeline runs, emits all three view containers,
# and the tab badge equals the active+stale bucket count (R23). Fuller
# coverage (R21 stale=red, R22 copy ids, escaping, per-view card counts, the
# parent-cycle regression) is a tracked follow-up — see the task's Follow-ups.
#
# Same convention as wb-board-model.test.sh (source wb.sh, fixture TASKS_DIR,
# tmux/gh/git shims, plain assert helpers) — no bats.
# Run: bash scripts/.config/scripts/tmux/tests/wb-board-render.test.sh
set -uo pipefail

WB="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/wb.sh"
FIXTURE_TASKS="$(mktemp -d -t wb-board-render-tasks.XXXXXX)"
FIXTURE_BIN="$(mktemp -d -t wb-board-render-bin.XXXXXX)"

# tmux/gh/git shims (R16: the render path must not shell out to them).
for bin in tmux gh git; do
  printf '#!/usr/bin/env bash\nexit 0\n' > "$FIXTURE_BIN/$bin"
  chmod +x "$FIXTURE_BIN/$bin"
done
PATH="$FIXTURE_BIN:$PATH"

cleanup() { rm -rf "$FIXTURE_TASKS" "$FIXTURE_BIN"; }
trap cleanup EXIT

fail=0
assert() { # <desc> <expected-regex> <actual>
  if printf '%s' "$3" | grep -qE "$2"; then echo "ok   - $1"
  else echo "FAIL - $1"; echo "       expected match: $2"; echo "       got: $(printf '%s' "$3" | head -4)"; fail=1; fi
}
assert_eq() { # <desc> <expected> <actual>
  if [ "$2" = "$3" ]; then echo "ok   - $1"; else echo "FAIL - $1 (expected '$2', got '$3')"; fail=1; fi
}

mk_task() { # <stem> <status> <mtime_days_ago> [<extra frontmatter>]
  local stem="$1" status="$2" days_ago="$3" extra="${4:-}"
  cat > "$FIXTURE_TASKS/$stem.md" <<EOF
---
status: $status
path:
repo: dotfiles
branch: feat/$stem
worktree: .worktrees/feat/$stem
$extra
---
# Title for $stem
EOF
  touch -d "$days_ago days ago" "$FIXTURE_TASKS/$stem.md"
}

TASKS_DIR="$FIXTURE_TASKS"
source "$WB"

# fixtures: 2 active + 1 stale (active+stale = 3 -> tab badge), 1 planned (shelved)
mk_task alpha  doing   2
mk_task bravo  review  1
mk_task oldie  doing   20
mk_task later  planned 5

# U6 family fixtures — a flat family (fam-parent + 2 children) and a ladder
# family (a "### Version ladder status" table inside Plan, one rung
# resolving to a real child stem, one rung with no child yet). All
# `planned`/`paused` (shelved bucket) so they don't perturb the
# active+stale fixture count above — family membership comes from
# `parent:`, independent of status/bucket.
mk_task fam-parent paused 3
mk_task fam-parent-child1 planned 3 $'parent: fam-parent'
mk_task fam-parent-child2 planned 3 $'parent: fam-parent'
cat >> "$FIXTURE_TASKS/fam-parent.md" <<'EOF'

## Decisions

### 2026-01-05 — Ship it this way
Chose the simpler approach because it was faster to build.

## Follow-ups

See dossiers/fam-parent/plan.md for the writeup.
EOF
# fix(review) P1 regression fixture: two DIFFERENT files that share a
# basename ("plan.md") in different directories — the bug this caught was
# classify_link deduping/copying on the basename alone, which silently
# dropped one family's artifact and made "copy" paste an unopenable
# bare filename instead of the real path.
cat >> "$FIXTURE_TASKS/fam-parent-child1.md" <<'EOF'

## Follow-ups

See dossiers/fam-parent-child1/plan.md for its own writeup.
EOF

# U6 flat-family escaping fixture — a title with `<`, `>`, `&`, `"` to
# prove the Family view's html-escaping path is exercised, not just
# assumed safe (a fresh code path per the perf-motivated per-family
# re-escaping restructure).
cat > "$FIXTURE_TASKS/xss-parent.md" <<'EOF'
---
status: paused
path:
repo: dotfiles
branch: feat/xss-parent
worktree: .worktrees/feat/xss-parent
---
# <script>alert('x')</script> & "quoted"
EOF
touch -d "3 days ago" "$FIXTURE_TASKS/xss-parent.md"
mk_task xss-parent-child1 planned 3 $'parent: xss-parent'

mk_task ladder-parent-child1 planned 4 $'parent: ladder-parent'
cat > "$FIXTURE_TASKS/ladder-parent.md" <<'EOF'
---
status: paused
path:
repo: dotfiles
branch: feat/ladder-parent
worktree: .worktrees/feat/ladder-parent
---
# Ladder parent

## Plan

### Version ladder status

| Rung | Ticket(s) | wb task | Status |
|---|---|---|---|
| v0.1 | T-1 | `ladder-parent-child1` | planned |
| v0.2 | T-2 | not yet created | not started |
EOF
touch -d "4 days ago" "$FIXTURE_TASKS/ladder-parent.md"

# --- run the full pipeline: collect -> build_model -> render_v2 ----------
declare -a V2ROWS=()
declare -A M_PLAN_RAW=() M_DONE_RAW=() M_HANDOFF_RAW=() M_FOLLOWUPS_RAW=() \
  M_DECISIONS_RAW=() M_LINKS_RAW=()
wb_board_collect_rows_v2 V2ROWS M_PLAN_RAW M_DONE_RAW M_HANDOFF_RAW M_FOLLOWUPS_RAW \
  M_DECISIONS_RAW M_LINKS_RAW
declare -A M_STATUS=() M_REPO=() M_BRANCH=() M_WORKTREE=() M_TITLE=() \
  M_CREATED=() M_CLOSED=() M_UPDATED=() M_TASKFILE=() M_PARENT=() \
  M_DEPS=() M_TAGS=() M_PLAN_CHECKED=() M_PLAN_TOTAL=() M_AGE_DAYS=() \
  M_BUCKET=() M_HANDOFF_SUMMARY=() M_FAMILY_ROOT=() STEM_PARENT=() \
  STEM_ANCHOR=() FAMILY_CHILDREN=() BUCKET_COUNT=()
wb_board_build_model V2ROWS M_PLAN_RAW M_DONE_RAW M_HANDOFF_RAW M_FOLLOWUPS_RAW \
  M_STATUS M_REPO M_BRANCH M_WORKTREE M_TITLE M_CREATED M_CLOSED M_UPDATED \
  M_TASKFILE M_PARENT M_DEPS M_TAGS M_PLAN_CHECKED M_PLAN_TOTAL M_AGE_DAYS \
  M_BUCKET M_HANDOFF_SUMMARY M_FAMILY_ROOT STEM_PARENT STEM_ANCHOR \
  FAMILY_CHILDREN BUCKET_COUNT

render="$(wb_board_render_v2 V2ROWS M_PLAN_RAW M_DONE_RAW M_HANDOFF_RAW M_FOLLOWUPS_RAW \
  M_STATUS M_REPO M_BRANCH M_WORKTREE M_TITLE M_CREATED M_CLOSED M_UPDATED \
  M_TASKFILE M_PARENT M_DEPS M_TAGS M_PLAN_CHECKED M_PLAN_TOTAL M_AGE_DAYS \
  M_BUCKET M_HANDOFF_SUMMARY M_FAMILY_ROOT STEM_PARENT STEM_ANCHOR \
  FAMILY_CHILDREN BUCKET_COUNT M_DECISIONS_RAW M_LINKS_RAW)"
rc=$?

# --- assertions ----------------------------------------------------------
assert_eq "render_v2 exits 0" "0" "$rc"
assert "renders the Active view container"  'id="view-active"'  "$render"
assert "renders the Roadmap view container" 'id="view-roadmap"' "$render"
assert "renders the Week view container"    'id="view-week"'    "$render"
assert "emits well-formed closing </html>"  '</html>'           "$render"

# R23: the tab badge equals the active+stale bucket count from the model.
badge="$(printf '%s' "$render" | grep -o 'class="tab-badge">[0-9]*' | head -1 | grep -o '[0-9]*$')"
expected_badge=$(( ${BUCKET_COUNT[active]:-0} + ${BUCKET_COUNT[stale]:-0} ))
assert_eq "R23: tab badge equals active+stale bucket count" "$expected_badge" "$badge"
assert_eq "R23: fixture sanity — 2 active + 1 stale = 3" "3" "$expected_badge"

# --- U6: Family view (fourth tab) ----------------------------------------
assert "renders the Family view container" 'id="view-family"' "$render"

# R23: the Family tab badge equals the number of families (roots with >=1
# child) in the model, and both fixture families are present.
fam_badge_count=0
for s in "${!FAMILY_CHILDREN[@]}"; do [ -n "${FAMILY_CHILDREN[$s]:-}" ] && fam_badge_count=$((fam_badge_count + 1)); done
fam_badge="$(printf '%s' "$render" | grep -oE '>Family <span class="tab-badge">[0-9]+<' | grep -oE '[0-9]+')"
assert_eq "R23: Family tab badge equals the model's family count" "$fam_badge_count" "$fam_badge"
assert_eq "Family fixture sanity — 3 families (fam-parent, xss-parent, ladder-parent)" "3" "$fam_badge_count"

# Flat family: children listed with status pills, R22 copy ids present,
# decisions timeline shows the fixture's dated entry.
assert "Flat family lists child 1 by title" 'fam-parent-child1' "$render"
assert "Flat family lists child 2 by title" 'fam-parent-child2' "$render"
assert "Flat family: R22 copy-id present for a child" 'data-copy="wb resume fam-parent-child1"' "$render"
assert "Flat family: decisions timeline shows the fixture entry" 'Chose the simpler approach' "$render"

# fix(review) P1 regression: artifact links must carry the full path, not
# just a basename — both fam-parent's and fam-parent-child1's "plan.md"
# (different directories, same basename) must survive, each copyable to
# its OWN real path, not collapsed into one entry by a basename-only dedup.
assert "Artifacts: parent's plan.md keeps its real path"      'data-copy="dossiers/fam-parent/plan\.md"'        "$render"
assert "Artifacts: child's plan.md keeps its own real path"   'data-copy="dossiers/fam-parent-child1/plan\.md"' "$render"
parent_plan_count="$(printf '%s' "$render" | grep -c 'dossiers/fam-parent/plan\.md' || true)"
child_plan_count="$(printf '%s' "$render" | grep -c 'dossiers/fam-parent-child1/plan\.md' || true)"
assert_eq "Artifacts: both same-basename links present, not deduped away" "1" "$([ "${parent_plan_count:-0}" -ge 1 ] && [ "${child_plan_count:-0}" -ge 1 ] && echo 1 || echo 0)"

# fix(review) P1 regression: family-view content is HTML-escaped, including
# the family root's own title (a fresh per-family re-escaping code path).
assert "Family view escapes a title with <script>/&/\""      '&lt;script&gt;alert' "$render"
if printf '%s' "$render" | grep -qF '<script>alert'; then
  echo "FAIL - Family view never emits the raw unescaped <script> tag"; fail=1
else
  echo "ok   - Family view never emits the raw unescaped <script> tag"
fi

# Ladder family: a resolvable rung shows the live child status (R23 —
# reads the model, not the table's own stale text) and a "now" marker; an
# unresolvable rung falls back to "not yet filed".
assert "Ladder family renders a rung" 'class="rung ' "$render"
assert "Ladder family: resolvable rung shows live status class" 'rung planned' "$render"
assert "Ladder family: unresolvable rung falls back to unfiled" 'not yet filed' "$render"
assert "Ladder family: R22 copy-id present for the resolved child" 'data-copy="wb resume ladder-parent-child1"' "$render"

# --- U5: family-rollup.json side-output ----------------------------------
rollup="$FIXTURE_TASKS/.board-cache/family-rollup.json"
assert_eq "family-rollup.json is written" "0" "$([ -f "$rollup" ] && echo 0 || echo 1)"
if command -v jq >/dev/null 2>&1 && [ -f "$rollup" ]; then
  assert_eq "family-rollup.json validates (jq parses it)" "0" "$(jq empty "$rollup" >/dev/null 2>&1; echo $?)"
  rollup_families="$(jq 'length' "$rollup" 2>/dev/null || echo -1)"
  assert_eq "family-rollup.json has one entry per model family" "$fam_badge_count" "$rollup_families"
  ladder_child="$(jq -r '.[] | select(.root=="ladder-parent") | .rungs[0].child' "$rollup" 2>/dev/null)"
  assert_eq "family-rollup.json ladder rung resolves the same child as the HTML" "ladder-parent-child1" "$ladder_child"
fi

echo
if [ "$fail" = 0 ]; then echo "wb-board-render.test.sh: all assertions passed"
else echo "wb-board-render.test.sh: FAILURES"; fi
exit "$fail"
