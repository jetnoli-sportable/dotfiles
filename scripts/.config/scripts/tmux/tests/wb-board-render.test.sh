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

# --- run the full pipeline: collect -> build_model -> render_v2 ----------
declare -a V2ROWS=()
declare -A M_PLAN_RAW=() M_DONE_RAW=() M_HANDOFF_RAW=() M_FOLLOWUPS_RAW=()
wb_board_collect_rows_v2 V2ROWS M_PLAN_RAW M_DONE_RAW M_HANDOFF_RAW M_FOLLOWUPS_RAW
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
  FAMILY_CHILDREN BUCKET_COUNT)"
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

echo
if [ "$fail" = 0 ]; then echo "wb-board-render.test.sh: all assertions passed"
else echo "wb-board-render.test.sh: FAILURES"; fi
exit "$fail"
