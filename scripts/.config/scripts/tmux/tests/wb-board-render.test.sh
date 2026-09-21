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
  # NB: `grep -E >/dev/null`, never `grep -qE`. With `set -o pipefail` (line
  # 13) and a render this size, -q makes grep exit on the first match while
  # printf is still writing — printf dies of SIGPIPE (141), pipefail hands
  # that status to the `if`, and a matching assertion reports FAIL. It bit
  # every pattern that matches EARLY in the page (grep exits soonest), so it
  # looked like a render regression rather than a harness bug. Draining the
  # input keeps the pipeline honest.
  if printf '%s' "$3" | grep -E "$2" >/dev/null 2>&1; then echo "ok   - $1"
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
# `bravo` is touched TODAY on purpose: the Week view only builds a
# .week-card for an active task updated since this Monday, so a fixture
# with nothing touched today renders an empty week and silently skips
# every week-card assertion below (which is how the collapsed-by-default
# contract could regress unnoticed).
mk_task bravo  review  0
mk_task oldie  doing   20
mk_task later  planned 5
# A planned CHILD of an active root: makes `alpha` a family (so the rail's
# Doing tree emits a <details>/<summary> node, not just leaf rows) and puts
# a `ready` bar in alpha's roadmap lane. Planned => shelved bucket, so the
# active+stale count asserted below is unchanged.
mk_task alpha-child planned 2 $'parent: alpha'

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

# A PHANTOM parent: `ghost-parent.md` is never created, so FAMILY_CHILDREN
# gains a key with no collected row. It is a real shape in this store (a
# hand-typed `parent:` with a typo, or a parent that was deleted) and the
# only way to exercise the "no such task file" branch on an open link.
mk_task ghost-child planned 3 $'parent: ghost-parent'

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
assert_eq "Family fixture sanity — 5 families (alpha, fam-parent, xss-parent, ladder-parent, ghost-parent)" "5" "$fam_badge_count"

# UX follow-up: family selection moved from a top-of-page chip grid to a
# rail-row list (#rail-families), toggled with #rail-tasks by showView().
assert "Rail has a #rail-tasks panel (Doing tree + Next/Shelf)"    'id="rail-tasks"'    "$render"
assert "Rail has a #rail-families panel (hidden until Family tab)" 'id="rail-families" style="display:none;"' "$render"
assert "Rail lists a family as a .fam-rail-row with its copy-id"   'class="rail-row fam-rail-row selected" data-fam="[a-z0-9-]+".*onclick="selectFamily' "$render"
assert_eq "Rail lists exactly one .fam-rail-row per family" "$fam_badge_count" "$(printf '%s' "$render" | grep -o 'class="rail-row fam-rail-row' | wc -l)"

# =========================================================================
# UX interaction-model pass (A-F): the client-side SCOPE contract. Every
# assertion below pins a structural promise the JS depends on — if the
# markup stops carrying it, scoping silently does nothing rather than
# erroring, which is exactly the failure mode that needs a test.
# =========================================================================

# (A) rail rows are the scope carriers: data-stem / data-anchor /
# data-family on every leaf row, family summary and shelf row, plus the
# "All doing" escape hatch at the top of the tree.
assert "A: rail leaf rows carry data-stem/-anchor/-family + a select click" \
  '<div class="rail-row" data-stem="[^"]+" data-anchor="[^"]+" data-family="[^"]+"[^>]* onclick="railPick' "$render"
assert "A: family summaries carry the same scope attrs + railSummaryClick" \
  '<summary data-stem="[^"]+" data-anchor="[^"]+" data-family="[^"]+"[^>]* onclick="railSummaryClick' "$render"
assert "A: shelf rows carry the scope attrs + a select click" \
  '<div class="shelf-row" data-stem="[^"]+" data-anchor="[^"]+" data-family="[^"]+"[^>]* onclick="railPick' "$render"
assert "A: an 'All doing' row heads the Doing tree with an empty anchor" \
  'class="rail-row rail-all selected" data-stem="" data-anchor="" data-family=""' "$render"
# R22's copy moves OFF the row title onto an explicit glyph, so a primary
# click selects and never also copies.
assert "A: copy affordance is a separate .copy-ic, not the row title" \
  'class="copy-ic copyable" data-copy="wb resume ' "$render"
if printf '%s' "$render" | grep -qE 'class="rail-row-title copyable"'; then
  echo "FAIL - A: the rail row title no longer carries data-copy"; fail=1
else
  echo "ok   - A: the rail row title no longer carries data-copy"
fi
# A family's children inherit the ROOT's anchor as data-family (the scope
# key a whole subtree shares).
fam_root_anchor="$(printf '%s' "$render" | grep -o 'data-stem="fam-parent-child1" data-anchor="[^"]*" data-family="[^"]*"' | head -1 | sed 's/.*data-family="\([^"]*\)".*/\1/')"
assert_eq "A: a child row's data-family is its family root's anchor" "fam-parent" "$fam_root_anchor"

# (B) the SCOPE state machine + localStorage persistence, and the filter
# reaching the main pane rather than the rail alone.
assert "B: a global SCOPE object drives every view"       'var SCOPE = .family' "$render"
assert "B: setScope persists to localStorage wbBoard.scope" "wbBoard.scope"    "$render"
assert "B: the current view persists to wbBoard.view"       "wbBoard.view"     "$render"
assert "B: filterBoard also narrows the main pane"          "#deckRow .card-slot, .rm-lane" "$render"
assert "B: j/k walk the rail rows, not the deck"            'function moveRailCursor'      "$render"

# (C) Active: each drilldown is emitted INSIDE its own card's slot, so it
# opens in place; the batched trailing drilldown block is gone.
assert "C: cards are wrapped in a per-card .card-slot with scope attrs" \
  '<div class="card-slot[^"]*" data-stem="[^"]+" data-anchor="[^"]+" data-family="[^"]+">' "$render"
slot_count="$(printf '%s' "$render" | grep -o 'class="card-slot' | wc -l)"
dd_count="$(printf '%s' "$render" | grep -o 'class="drilldown' | wc -l)"
assert_eq "C: exactly one drilldown per card slot" "$slot_count" "$dd_count"
assert_eq "C: fixture sanity — 3 active+stale cards => 3 slots" "3" "$slot_count"
# Placement: the drilldown must sit between its own card's open tag and
# the slot's close, i.e. immediately after the card it belongs to.
assert "C: the drilldown follows its own card inside the slot" \
  'id="card-alpha" data-drilldown="drilldown-alpha">.*id="drilldown-alpha"' "$render"
if printf '%s' "$render" | grep -q 'DRILLDOWNS_HTML'; then
  echo "FAIL - C: the batched @@DRILLDOWNS_HTML@@ token is gone"; fail=1
else
  echo "ok   - C: the batched @@DRILLDOWNS_HTML@@ token is gone"
fi
assert "C: the deck has a scope header + empty-state slot" 'id="active-scope-header"' "$render"
assert "C: the deck has a not-in-doing-set empty state"    'id="active-scope-empty"'  "$render"
# The empty state names the task's real status, so the rail has to carry it
# (it used to be inferred from which widgets a row happened to render).
assert "C: rail rows carry data-status for the empty-state line" \
  '<div class="rail-row" data-stem="[^"]+" data-anchor="[^"]+" data-family="[^"]+" data-status="[a-z]+"' "$render"
assert "C: family summaries carry data-status too" \
  '<summary data-stem="[^"]+" data-anchor="[^"]+" data-family="[^"]+" data-status="[a-z]+"' "$render"
assert "C: shelf rows carry data-status too" \
  '<div class="shelf-row" data-stem="[^"]+" data-anchor="[^"]+" data-family="[^"]+" data-status="[a-z]+"' "$render"
assert "C: a planned child row's data-status is planned" 'data-stem="alpha-child"[^>]*data-status="planned"' "$render"
# The empty-state copy is a "here is where it lives" pointer, not a
# bug-sounding "not in the doing set".
assert "C: the empty state points at Roadmap/Week rather than reading as an error" \
  "No doing card for" "$render"
assert "C: the empty state names the other two views" 'see it in Roadmap or Week' "$render"
if printf '%s' "$render" | grep -E 'not in the doing set' >/dev/null 2>&1; then
  echo "FAIL - C: the old bug-like empty-state wording is gone"; fail=1
else
  echo "ok   - C: the old bug-like empty-state wording is gone"
fi
# Selecting a card must scroll the whole SLOT (card + drilldown), not the
# card alone — block:'nearest' on an already-visible card is a no-op and
# left the drilldown below the fold.
assert "C: card selection scrolls the slot, not just the card" 'function scrollSlotIntoView' "$render"
if printf '%s' "$render" | grep -E "card\.scrollIntoView" >/dev/null 2>&1; then
  echo "FAIL - C: nothing scrolls the bare card any more"; fail=1
else
  echo "ok   - C: nothing scrolls the bare card any more"
fi

# (D) Roadmap: lanes are addressable by family, bars name their task, and
# the readiness strip is a one-line toggle by default.
assert "D: lanes carry id=lane-ANCHOR and data-family" 'class="rm-lane[^"]*" id="lane-[^"]+" data-family="[^"]+"' "$render"
assert "D: the readiness strip is a collapsible #rm-strip" 'class="rm-readiness-strip" id="rm-strip"' "$render"
assert "D: the strip's default state is the collapsed one-line head" 'class="rm-strip-head" onclick="toggleRmStrip' "$render"
if printf '%s' "$render" | grep -q 'class="rm-readiness-strip open"'; then
  echo "FAIL - D: the strip does not render pre-expanded"; fail=1
else
  echo "ok   - D: the strip does not render pre-expanded"
fi
assert "D: roadmap bars carry data-anchor + a full-title tooltip" 'class="rm-bar ready-bar" data-anchor="[^"]+" title="' "$render"
# The scoped lane needs a positive signal, not just 17 faded neighbours.
assert "D: the scoped lane gets a mauve left rule on its label" '\.rm-lane\.selected \.rm-lane-label \{ border-left: 3px solid var\(--mauve\)' "$render"
assert "D: dimmed lanes stay legible (opacity, not display:none)" '\.rm-lane\.scope-dim \{ opacity:' "$render"

# (E) Week: cards collapse by default and carry the scope attrs; the
# shelved count is a real toggle over a compact list.
assert "E: week cards carry the scope attrs and a toggle click" \
  '<div class="week-card" data-stem="[^"]+" data-anchor="[^"]+" data-family="[^"]+" onclick="toggleWeekCard' "$render"
if printf '%s' "$render" | grep -q 'class="week-card expanded"'; then
  echo "FAIL - E: week cards render collapsed, not pre-expanded"; fail=1
else
  echo "ok   - E: week cards render collapsed, not pre-expanded"
fi
assert "E: carried rows carry the scope attrs"  '<div class="carried-row" data-stem="[^"]+" data-anchor="[^"]+" data-family="[^"]+"' "$render"
assert "E: queue/shelf chips carry the scope attrs" 'class="qs-chip [a-z]+ copyable" data-stem="[^"]+" data-anchor="[^"]+" data-family="[^"]+"' "$render"
assert "E: the shelved count is a toggle"       'id="wk-shelf-toggle" onclick="toggleWeekShelf' "$render"
assert "E: the shelf toggle reveals a compact row list" 'id="wk-shelf-detail"' "$render"
assert "E: the shelf list holds a row per non-done shelved task" 'class="wk-shelf-row" data-stem="later"' "$render"

# (F) Family: selection in either rail syncs the shared scope.
assert "F: fam rail rows also carry data-stem/-anchor/-family" \
  'class="rail-row fam-rail-row[^"]*" data-fam="[^"]*" data-stem="[^"]*" data-anchor="[^"]*" data-family="' "$render"
assert "F: selectFamily feeds the shared SCOPE" 'function selectFamily' "$render"

# The rail must stay on screen while a long view scrolls (friction #6).
assert "A: the rail is sticky with its own scroll" '\.rail \{[^}]*position: sticky' "$render"

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
# (The paths are now resolved to ABSOLUTE, under the fixture's own
# TASKS_DIR — a relative `dossiers/...` is not openable from the rendered
# page, which is what the file:// links below exist to fix. The P1
# regression this guards is unchanged: two same-basename files must stay
# two distinct entries.)
assert "Artifacts: parent's plan.md keeps its real path"      "data-copy=\"$FIXTURE_TASKS/dossiers/fam-parent/plan\.md\""        "$render"
assert "Artifacts: child's plan.md keeps its own real path"   "data-copy=\"$FIXTURE_TASKS/dossiers/fam-parent-child1/plan\.md\"" "$render"
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

# =========================================================================
# Round-2 item 1: artifacts and task ids are OPENABLE, not just copyable.
# Every path the board shows is resolved to an absolute file:// href — a
# relative `dossiers/x/plan.md` cannot be opened from logs/board.html.
# =========================================================================
assert "L: an artifact renders as an anchor with a file:// absolute href" \
  "<a class=\"fam-art-path mono\" href=\"file://$FIXTURE_TASKS/dossiers/fam-parent/plan\.md\"" "$render"
assert "L: the anchor's TEXT is the full absolute path, not a basename" \
  ">$FIXTURE_TASKS/dossiers/fam-parent/plan\.md</a>" "$render"
assert "L: artifact anchors open in a new tab" 'class="fam-art-path mono" href="file://[^"]+" target="_blank" rel="noopener"' "$render"
# The fixture's dossiers/ paths are cited in prose but never created on
# disk, so they exercise the missing-link branch: marked, never dropped.
assert "L: an artifact with no file on disk is marked .missing" 'class="fam-art-row copyable missing" data-copy="[^"]+" title="not found on disk"' "$render"
if printf '%s' "$render" | grep -E "dossiers/fam-parent-child1/plan\.md" >/dev/null 2>&1; then
  echo "ok   - L: a missing artifact is still rendered, not dropped"
else
  echo "FAIL - L: a missing artifact is still rendered, not dropped"; fail=1
fi
# A claude.ai / http(s) link keeps its own scheme rather than being
# rewritten to file://.
assert "L: task ids gain an open-ic anchor at the fixture's own task file" \
  "<a class=\"open-ic\" href=\"file://$FIXTURE_TASKS/alpha\.md\" target=\"_blank\"" "$render"
assert "L: the card id carries one too" "class=\"card-id mono copyable\" data-copy=\"wb resume alpha\">alpha</span><a class=\"open-ic\" href=\"file://$FIXTURE_TASKS/alpha\.md\"" "$render"
assert "L: drilldown headings link to the task file"  '<h3>Plan<a class="open-ic"' "$render"
# A phantom stem (a `parent:` naming a file that does not exist) must be
# flagged, not rendered as a live link that 404s.
assert "L: a phantom stem's open link is marked .missing" 'class="open-ic missing" href="[^"]+" target="_blank" title="no such task file"' "$render"
assert "L: the handoff block links to the task file"  'class="dd-meta">.*<a class="open-ic"' "$render"
assert "L: week meta ids link to the task file"       'data-copy="wb resume bravo">bravo</span><a class="open-ic"' "$render"
assert "L: family tree rows link to the task file"    'class="t-id mono">[^<]*</span></div><a class="open-ic"' "$render"
assert "L: the decisions timeline source links too"   'class="fam-tl-source [^"]*copyable" data-copy="[^"]+">[^<]*</span><a class="open-ic"' "$render"
# Every open-ic href must be an absolute file:// URL under TASKS_DIR —
# a relative one would 404 from the rendered page's own directory.
bad_open="$(printf '%s' "$render" | grep -oE 'class="open-ic[^"]*" href="[^"]*"' | grep -vcE "href=\"file://$FIXTURE_TASKS/" || true)"
assert_eq "L: no open-ic href is relative or outside TASKS_DIR" "0" "${bad_open:-0}"

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
