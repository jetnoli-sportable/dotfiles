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

# U7 stage-strip fixture: a doing task with a docs/plans link (plan done),
# `reviewed:` stamped (review done) and NO work signal at all — so work must
# resolve to `pending` (in the default path, nothing fired), and ideate /
# brainstorm to `na` (not in the default path, nothing fired). Also carries a
# PR URL, which IS a work signal, so a second fixture keeps them apart.
cat > "$FIXTURE_TASKS/stagey.md" <<'EOF'
---
status: doing
path:
repo: dotfiles
branch: feat/stagey
worktree: .worktrees/feat/stagey
reviewed: 2026-09-01
---
# Stage fixture

## Plan

- [ ] nothing started

## Follow-ups

Wrote it up in docs/plans/2026-09-01-001-stagey-plan.md first.
EOF
touch -d "2 days ago" "$FIXTURE_TASKS/stagey.md"

# A task whose only work signal is a PR URL, with an explicit `path:` that
# names every stage — so ideate/brainstorm render as pending rather than na.
cat > "$FIXTURE_TASKS/prtask.md" <<'EOF'
---
status: doing
path: ideate, brainstorm, plan, work, review
repo: dotfiles
branch: feat/prtask
worktree: .worktrees/feat/prtask
---
# PR fixture

## Handoffs

### 2026-09-02 12:00 — note
Opened https://github.com/jetnoli-sportable/dotfiles/pull/4242 for this.
EOF
touch -d "2 days ago" "$FIXTURE_TASKS/prtask.md"

# A handoff entry longer than the 2200-char clip, so the truncation path is
# exercised rather than assumed. (Real task files reach 18KB here, which is
# what made escaping them the render's biggest single CPU cost.)
{
  printf -- '---\nstatus: doing\npath:\nrepo: dotfiles\nbranch: feat/longhand\nworktree: .worktrees/feat/longhand\n---\n'
  printf '# Long handoff fixture\n\n## Handoffs\n\n### 2026-09-03 09:00 — wb-save\n'
  i=0; while [ "$i" -lt 60 ]; do
    printf '**Done:** padding line %s with enough words on it to push this entry well past the clip threshold.\n' "$i"
    i=$((i + 1))
  done
} > "$FIXTURE_TASKS/longhand.md"
touch -d "2 days ago" "$FIXTURE_TASKS/longhand.md"

# Repo-filter fixtures (round 3 follow-up). mk_task always writes
# `repo: dotfiles`, so these hand-written ones give the store six repos
# with deliberately distinct counts: the control must show All + the top 5
# (dotfiles pinned first, then by count desc, then by name) and fold the
# rest into `other` as a real SET.
mk_repo_task() { # <stem> <repo>
  cat > "$FIXTURE_TASKS/$1.md" <<EOF
---
status: planned
path:
repo: $2
branch: feat/$1
worktree: .worktrees/feat/$1
---
# Repo fixture $1
EOF
  touch -d "5 days ago" "$FIXTURE_TASKS/$1.md"
}
mk_repo_task rf-zeta-1 zeta; mk_repo_task rf-zeta-2 zeta; mk_repo_task rf-zeta-3 zeta
mk_repo_task rf-yank-1 yank; mk_repo_task rf-yank-2 yank
mk_repo_task rf-vega-1 vega
mk_repo_task rf-whisk-1 whisk
mk_repo_task rf-xray-1 xray

# U6 family fixtures — a flat family (fam-parent + 2 children) and a ladder
# family (a "### Version ladder status" table inside Plan, one rung
# resolving to a real child stem, one rung with no child yet). All
# `planned`/`paused` (shelved bucket) so they don't perturb the
# active+stale fixture count above — family membership comes from
# `parent:`, independent of status/bucket.
mk_task fam-parent paused 3
mk_task fam-parent-child1 planned 3 $'parent: fam-parent'
# U5 (family DAG view): child2 depends on child1 — this family's ONE
# intra-family edge, exercised by the "flat family with edges" scenario
# below (fam-parent's own edge count is otherwise 0, same as every other
# flat fixture in this file).
mk_task fam-parent-child2 planned 3 $'parent: fam-parent\ndepends_on: fam-parent-child1'
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
# U5 (family DAG view): a second child, real edge FROM ghost-child (via
# depends_on ghost-child,ghost-parent — two deps, one in-family, one to the
# family's own (phantom) root). Covers two scenarios at once: (1) a family
# whose root is a phantom stem still renders its children's graph (R3 never
# needed the root's own row, only fr_members[1:]); (2) an edge to the
# family root itself is NOT drawn (R3 — the root is never a node), so this
# family's rendered edge count must be exactly 1, not 2.
mk_task ghost-child2 planned 3 $'parent: ghost-parent\ndepends_on: ghost-child,ghost-parent'

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

# U5 (family DAG view): a SECOND ladder family, distinct from ladder-parent
# above, whose two real rungs' children carry a depends_on edge — ladder-
# parent itself stays edge-free (0 edges) so it keeps covering the "ladder
# family without edges shows neither region nor empty-state" scenario.
mk_task ladder2-parent-child1 planned 4 $'parent: ladder2-parent'
mk_task ladder2-parent-child2 planned 4 $'parent: ladder2-parent\ndepends_on: ladder2-parent-child1'
cat > "$FIXTURE_TASKS/ladder2-parent.md" <<'EOF'
---
status: paused
path:
repo: dotfiles
branch: feat/ladder2-parent
worktree: .worktrees/feat/ladder2-parent
---
# Ladder2 parent (with dependency edges)

## Plan

### Version ladder status

| Rung | Ticket(s) | wb task | Status |
|---|---|---|---|
| v0.1 | T-1 | `ladder2-parent-child1` | planned |
| v0.2 | T-2 | `ladder2-parent-child2` | planned |
EOF
touch -d "4 days ago" "$FIXTURE_TASKS/ladder2-parent.md"

# fix(review) D1 regression: a `parent:` value carrying shell metacharacters.
# The D1 collect-time guard drops a parent outside [A-Za-z0-9._-], so it never
# becomes a (phantom) family root and its raw value can never reach the fam-hero
# data-copy="wb resume <stem>" clipboard text (HTML-escaped is NOT shell-escaped).
# Without the guard this would add a 6th family AND smuggle `;`/space onto the
# clipboard. `metachar-child` is planned (shelved), so it can't perturb the
# active+stale badge.
mk_task metachar-child planned 3 $'parent: evil; touch /tmp/pwned'

# fix(review) D3 regression: two DISTINCT stems that sanitize to the SAME anchor
# base — `coll.ide` -> "coll-ide" and `coll-ide` -> "coll-ide". Before D3 they
# collapsed to one DOM id, so U8's #detail-pool getElementById('detail-'+anchor)
# mounted the WRONG task's detail block. Both `done` (shelved, excluded from the
# Shelf list) so they don't perturb the active/stale/shelf assertions.
mk_task coll.ide done 1
mk_task coll-ide done 1

# fix(review) D5: exercise the stage-strip DONE branches the stagey/prtask
# fixtures don't reach — ideate + brainstorm done (awk bits 0/1 fire on
# docs/ideation/ and docs/brainstorms/ text, wb-board.sh:521-522) and the work
# stage's status:done branch (wb_board_v2_stage_states, wb-board.sh:~1458).
cat > "$FIXTURE_TASKS/donestage.md" <<'EOF'
---
status: done
path:
repo: dotfiles
branch: feat/donestage
worktree: .worktrees/feat/donestage
---
# Done-stage fixture

## Follow-ups

Ideated in docs/ideation/2026-09-01-x.md, then docs/brainstorms/2026-09-02-y.md.
EOF
touch -d "2 days ago" "$FIXTURE_TASKS/donestage.md"

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
  STEM_ANCHOR=() FAMILY_CHILDREN=() BUCKET_COUNT=() M_STAGE_SIG=() M_PR_URL=() \
  M_SIZE=() M_ACCEPT=()
wb_board_build_model V2ROWS M_PLAN_RAW M_DONE_RAW M_HANDOFF_RAW M_FOLLOWUPS_RAW \
  M_STATUS M_REPO M_BRANCH M_WORKTREE M_TITLE M_CREATED M_CLOSED M_UPDATED \
  M_TASKFILE M_PARENT M_DEPS M_TAGS M_PLAN_CHECKED M_PLAN_TOTAL M_AGE_DAYS \
  M_BUCKET M_HANDOFF_SUMMARY M_FAMILY_ROOT STEM_PARENT STEM_ANCHOR \
  FAMILY_CHILDREN BUCKET_COUNT M_STAGE_SIG M_PR_URL M_SIZE M_ACCEPT

render="$(wb_board_render_v2 V2ROWS M_PLAN_RAW M_DONE_RAW M_HANDOFF_RAW M_FOLLOWUPS_RAW \
  M_STATUS M_REPO M_BRANCH M_WORKTREE M_TITLE M_CREATED M_CLOSED M_UPDATED \
  M_TASKFILE M_PARENT M_DEPS M_TAGS M_PLAN_CHECKED M_PLAN_TOTAL M_AGE_DAYS \
  M_BUCKET M_HANDOFF_SUMMARY M_FAMILY_ROOT STEM_PARENT STEM_ANCHOR \
  FAMILY_CHILDREN BUCKET_COUNT M_STAGE_SIG M_PR_URL M_SIZE M_ACCEPT \
  M_DECISIONS_RAW M_LINKS_RAW)"
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
assert_eq "R23: fixture sanity — 5 active + 1 stale = 6" "6" "$expected_badge"

# --- U6: Family view (fourth tab) ----------------------------------------
assert "renders the Family view container" 'id="view-family"' "$render"

# R23: the Family tab badge equals the number of families (roots with >=1
# child) in the model, and both fixture families are present.
fam_badge_count=0
for s in "${!FAMILY_CHILDREN[@]}"; do [ -n "${FAMILY_CHILDREN[$s]:-}" ] && fam_badge_count=$((fam_badge_count + 1)); done
fam_badge="$(printf '%s' "$render" | grep -oE '>Family <span class="tab-badge">[0-9]+<' | grep -oE '[0-9]+')"
assert_eq "R23: Family tab badge equals the model's family count" "$fam_badge_count" "$fam_badge"
assert_eq "Family fixture sanity — 6 families (alpha, fam-parent, xss-parent, ladder-parent, ladder2-parent, ghost-parent)" "6" "$fam_badge_count"

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
  '<div class="card-slot[^"]*" data-stem="[^"]+" data-anchor="[^"]+" data-family="[^"]+"[^>]*>' "$render"
# NB: every count below ends in `|| true`. wb.sh (sourced above) turns on
# errexit, so a grep that finds nothing aborts this whole file silently —
# which is exactly what happened when U8 removed the inline drilldown and
# `grep -o 'class="drilldown'` started matching zero times.
slot_count="$(printf '%s' "$render" | grep -o 'class="card-slot' | wc -l || true)"
assert_eq "C: fixture sanity — 6 active+stale cards => 6 slots" "6" "$slot_count"
# U8: the expanded detail is no longer emitted per card. Each slot carries
# an empty mount host and the JS moves the one pooled block into it.
host_count="$(printf '%s' "$render" | grep -o 'class="detail-host" data-anchor="' | wc -l || true)"
assert "C: each card slot carries a detail mount host" '<div class="detail-host" data-anchor="[^"]+"></div></div>' "$render"
if printf '%s' "$render" | grep -E 'class="drilldown' >/dev/null 2>&1; then
  echo "FAIL - C: the per-card drilldown is gone (replaced by the shared block)"; fail=1
else
  echo "ok   - C: the per-card drilldown is gone (replaced by the shared block)"
fi
if printf '%s' "$render" | grep -E 'DRILLDOWNS_HTML' >/dev/null 2>&1; then
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
assert "C: selecting a slot mounts the shared detail block" 'mountDetail\(slot.getAttribute' "$render"
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
# Round-3 item 2: a scope now HIDES the other lanes rather than dimming
# them — among 18 lanes, hunting for the un-faded one is still hunting.
assert "D: a scoped roadmap hides the other lanes" "l.classList.toggle\('scope-hidden', !!fam && !isScoped\)" "$render"
assert "D: and never leaves them merely dimmed"    "l.classList.remove\('scope-dim'\)" "$render"
# The grid header, TODAY marker and readiness line sit outside .rm-lane, so
# scoping must not take them with it.
assert "D: the grid header survives a scope" 'class="rm-grid-header"' "$render"
assert "D: the TODAY marker survives a scope" 'class="rm-today-line"' "$render"

# (E) Week: cards collapse by default and carry the scope attrs; the
# shelved count is a real toggle over a compact list.
assert "E: week cards carry the scope attrs and a toggle click" \
  '<div class="week-card" data-stem="[^"]+" data-anchor="[^"]+" data-family="[^"]+"[^>]* onclick="toggleWeekCard' "$render"
if printf '%s' "$render" | grep -E 'class="week-card expanded"' >/dev/null 2>&1; then
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
# Round-3 item 5: the visible text is the BASENAME (a column of near
# identical 90-char paths was unreadable); the full absolute path moves to
# title= and stays on the clipboard and in the href.
assert "L: the anchor's TEXT is the file name" \
  "title=\"$FIXTURE_TASKS/dossiers/fam-parent/plan\.md\">plan\.md</a>" "$render"
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
# U8 moved the expanded body into the shared detail block, so the task-file
# link that used to sit on each drilldown heading now sits in that block's
# header, once, where the id is.
assert "L: the detail block header links to the task file" 'class="detail-id mono copyable" data-copy="wb resume [^"]+">[^<]*</span><a class="open-ic' "$render"
# A phantom stem (a `parent:` naming a file that does not exist) must be
# flagged, not rendered as a live link that 404s.
assert "L: a phantom stem's open link is marked .missing" 'class="open-ic missing" href="[^"]+" target="_blank" title="no such task file"' "$render"

assert "L: week meta ids link to the task file"       'data-copy="wb resume bravo">bravo</span><a class="open-ic"' "$render"
assert "L: family tree rows link to the task file"    'class="t-id mono">[^<]*</span>.*</div><a class="open-ic"' "$render"
assert "L: the decisions timeline source links too"   'class="fam-tl-source [^"]*copyable" data-copy="[^"]+">[^<]*</span><a class="open-ic"' "$render"
# Every open-ic href must be an absolute file:// URL under TASKS_DIR —
# a relative one would 404 from the rendered page's own directory.
bad_open="$(printf '%s' "$render" | grep -oE 'class="open-ic[^"]*" href="[^"]*"' | grep -vcE "href=\"file://$FIXTURE_TASKS/" || true)"
assert_eq "L: no open-ic href is relative or outside TASKS_DIR" "0" "${bad_open:-0}"

# =========================================================================
# U7: the lifecycle stage strip. The stage MODEL is wb-lifecycle.sh's
# (order, four states, resolver precedence); only the signal detection is
# reimplemented here, store-only, so these assertions pin the resolver's
# answers rather than the detectors' internals.
# =========================================================================
# `stagey`: docs/plans link => plan done; reviewed: set => review done;
# nothing started => work pending (it IS in the default path); ideate and
# brainstorm are absent from the default path and nothing fired => na, so
# they must not render at all.
# NB: no `| head -1` here. A pipe consumer that exits early makes grep die
# of SIGPIPE, and bash re-raises a command substitution's fatal signal in
# the parent — which silently KILLED this whole test file mid-run (the same
# class of trap as the `grep -qE` note on assert() above). Take the window
# with one grep and the first line with parameter expansion instead.
strip_stagey="$(printf '%s' "$render" | grep -oE 'id="card-stagey".{0,1400}' || true)"
strip_stagey="${strip_stagey%%$'\n'*}"
assert "U7: stagey renders a stage strip"                'class="stage-strip"' "$strip_stagey"
assert "U7: stagey plan is done (docs/plans link)"       'class="stage done" title="plan: done"' "$strip_stagey"
assert "U7: stagey review is done (reviewed: stamped)"   'class="stage done" title="review: done"' "$strip_stagey"
assert "U7: stagey work is pending (in path, nothing fired)" 'class="stage pending" title="work: pending"' "$strip_stagey"
if printf '%s' "$strip_stagey" | grep -E 'title="(ideate|brainstorm):' >/dev/null 2>&1; then
  echo "FAIL - U7: an na stage is omitted from the strip entirely"; fail=1
else
  echo "ok   - U7: an na stage is omitted from the strip entirely"
fi
# The old renderer's half-filled glyph read as "50% done" rather than "in
# progress" (this task's own quick-wins note) — it must not come back.
if printf '%s' "$render" | grep -F '&#9681;' >/dev/null 2>&1; then
  echo "FAIL - U7: the half-filled progress glyph is not used"; fail=1
else
  echo "ok   - U7: the half-filled progress glyph is not used"
fi
# `prtask`: a PR URL is itself evidence work started (AE1), and its explicit
# `path:` names every stage, so the never-fired doc stages are pending here
# rather than na.
strip_pr="$(printf '%s' "$render" | grep -oE 'id="card-prtask".{0,1400}' || true)"
strip_pr="${strip_pr%%$'\n'*}"
assert "U7: a PR URL puts work in progress"              'class="stage progress" title="work: progress"' "$strip_pr"
assert "U7: an explicit path: makes an unfired stage pending, not na" 'title="ideate: pending"' "$strip_pr"
assert "U7: the PR chip links to the pull request"       'class="pr-chip" href="https://github.com/jetnoli-sportable/dotfiles/pull/4242" target="_blank"' "$render"
assert "U7: the PR chip shows its number"                '>PR #4242</a>' "$render"
# The strip appears on cards and as a mini strip in the Family view, never
# in the rail.
assert "U7: family tree child rows carry a mini strip" 'class="stage-strip mini"' "$render"
rail_strip="$(printf '%s' "$render" | grep -oE 'id="rail-tasks".*id="rail-families"' | grep -c 'stage-strip' || true)"
assert_eq "U7: the rail carries no stage strip" "0" "${rail_strip:-0}"

# Ladder family: a resolvable rung shows the live child status (R23 —
# reads the model, not the table's own stale text) and a "now" marker; an
# unresolvable rung falls back to "not yet filed".
assert "Ladder family renders a rung" 'class="rung ' "$render"
assert "Ladder family: resolvable rung shows live status class" 'rung planned' "$render"
assert "Ladder family: unresolvable rung falls back to unfiled" 'not yet filed' "$render"
assert "Ladder family: R22 copy-id present for the resolved child" 'data-copy="wb resume ladder-parent-child1"' "$render"

# =========================================================================
# U8: the shared summary-first detail block. One node per EXPANDABLE task,
# parked in #detail-pool and moved into whichever slot opens.
# =========================================================================
pool_blocks="$(printf '%s' "$render" | grep -o 'class="detail" id="detail-' | wc -l || true)"
hosts="$(printf '%s' "$render" | grep -o 'class="detail-host" data-anchor="' | wc -l || true)"
assert "U8: there is a hidden #detail-pool" '<div id="detail-pool" hidden>' "$render"
assert_eq "U8: the pool is non-empty" "1" "$([ "${pool_blocks:-0}" -gt 0 ] && echo 1 || echo 0)"
# A block exists iff something can mount it; hosts may outnumber blocks
# (a task on the deck AND in a family has two hosts, one block) but never
# the other way round.
assert_eq "U8: never more blocks than mount hosts" "1" "$([ "${pool_blocks:-0}" -le "${hosts:-0}" ] && echo 1 || echo 0)"
dup="$(printf '%s' "$render" | grep -o 'id="detail-alpha"' | wc -l || true)"
assert_eq "U8: exactly one block per task, not one per view" "1" "$dup"
# Block anatomy: header (title/status/age/id), the Now line, and sections
# with counts — Latest handoff open, everything else collapsed.
assert "U8: header carries title, status pill and age" 'class="detail-head"><div class="detail-title">[^<]+</div><span class="detail-pill st-[a-z]+">[a-z]+</span>.*<span class="detail-age mono">touched ' "$render"
assert "U8: the block leads with a Now line"          'class="detail-now"><span class="lbl">Now</span><span class="txt">' "$render"
assert "U8: Latest handoff is the one open section"   '<details class="dsec" open><summary>Latest handoff</summary>' "$render"
assert "U8: Plan is collapsed and shows checked/total" '<details class="dsec"><summary>Plan <span class="n">[0-9]+/[0-9]+</span>' "$render"
assert "U8: Done is collapsed and counted"            '<details class="dsec"><summary>Done <span class="n">[0-9]+</span>' "$render"
assert "U8: Follow-ups is collapsed and counted"      '<details class="dsec"><summary>Follow-ups <span class="n">[0-9]+</span>' "$render"
assert "U8: a child block links back to its family scope" 'class="detail-parent" onclick="setScope\(' "$render"
# Budget shape: a done task gets the compact block, a planned one keeps
# Plan/Follow-ups but drops Decisions/Artifacts.
assert "U8: the stage strip appears inside the detail header too" 'class="detail-now"' "$render"
# Family: child rows are the expand hook and carry the caret.
assert "U8: family child rows are expandable and carry a caret" \
  '<div class="fam-tree-row child-row expandable" data-anchor="[^"]+"[^>]* onclick="toggleFamDetail\(event,this\)"><span class="fam-caret">' "$render"
assert "U8: each family child row is followed by its own mount host" \
  '</div><div class="detail-host" data-anchor="[^"]+"></div>' "$render"
assert "U8: only one detail is open per family block" 'querySelectorAll\(.\.detail-host\.open.\)\.forEach\(unmountHost\)' "$render"
# Long raw text is clipped before escaping (a CPU lever as much as a size
# one) and says so rather than silently ending mid-sentence.
assert "U8: over-long raw text is clipped with a marker" 'clipped &mdash; open the task file for the rest|clipped — open the task file for the rest' "$render"

# =========================================================================
# Round 3, items 3/4/6: repo filter, repo badges, family top-level summary.
# =========================================================================
# The fixture store has 2 repos (dotfiles + the `repo:` the mk_task helper
# writes), so it takes the "one chip per repo" branch rather than the
# All/dotfiles/other fallback.
assert "R3: the rail carries a repo segmented control" 'class="repo-chips" id="repo-chips"' "$render"
assert "R3: All is the default selection"              'class="repo-chip selected" data-repo-pick=""' "$render"
# Round 3 follow-up: All, then the top 5 repos by task count (dotfiles
# pinned first), then `other` holding the rest AS A SET. The previous rule
# bailed out to All/dotfiles/other above six repos, which on the real store
# made its own biggest repo unselectable.
assert "R3: dotfiles is pinned as the first repo chip" \
  '>All</span><span class="repo-chip" data-repo-pick="dotfiles"' "$render"
# Fixture counts: zeta 3, yank 2, vega/whisk/xray 1 each (ties break by
# name), so the five named are dotfiles, zeta, yank, vega, whisk.
assert "R3: the remaining chips follow task count descending" \
  'data-repo-pick="zeta"[^>]*>zeta</span><span class="repo-chip" data-repo-pick="yank"' "$render"
assert "R3: a tie is broken by name, not hash order" \
  'data-repo-pick="vega"[^>]*>vega</span><span class="repo-chip" data-repo-pick="whisk"' "$render"
assert "R3: a chip titles itself with its task count" 'title="only zeta \(3\)"' "$render"
# `other` is a real set of the leftover names, never "not dotfiles".
assert "R3: other carries the remaining repos as a set" 'data-repo-pick="__other__" data-repo-set="xray"' "$render"
if printf '%s' "$render" | grep -E 'data-repo-pick="xray"' >/dev/null 2>&1; then
  echo "FAIL - R3: a repo folded into other has no chip of its own"; fail=1
else
  echo "ok   - R3: a repo folded into other has no chip of its own"
fi
for named in dotfiles zeta yank vega whisk; do
  if printf '%s' "$render" | grep -E "data-repo-set=\"[^\"]*${named}" >/dev/null 2>&1; then
    echo "FAIL - R3: other excludes the named repo $named"; fail=1
  else
    echo "ok   - R3: other excludes the named repo $named"
  fi
done
assert "R3: other matches by set membership, not by negation" 'return otherSet\(\)\[r\] === 1' "$render"
if printf '%s' "$render" | grep -F "r !== 'dotfiles'" >/dev/null 2>&1; then
  echo "FAIL - R3: the old not-dotfiles negation is gone"; fail=1
else
  echo "ok   - R3: the old not-dotfiles negation is gone"
fi
# No blank-repo task in this fixture, so the set must NOT carry the empty
# member that folds those in.
if printf '%s' "$render" | grep -E 'data-repo-set="[^"]*\|"' >/dev/null 2>&1; then
  echo "FAIL - R3: no empty member unless the store has repo-less tasks"; fail=1
else
  echo "ok   - R3: no empty member unless the store has repo-less tasks"
fi
assert "R3: the repo filter persists"                  "wbBoard.repo" "$render"
assert "R3: the repo filter owns its own hiding class"  "classList.toggle\('repo-hidden', !repoOk\(el\)\)" "$render"
# Composition: three independent hiding classes, so clearing one never
# resurrects what another hid.
assert "R3: repo/scope/text filters each hide independently" '\.repo-hidden \{ display: none' "$render"
# data-repo has to be on the things being filtered, not just the rail.
assert "R3: rail rows carry data-repo"   '<div class="rail-row" data-stem="[^"]+"[^>]* data-repo="[^"]+"' "$render"
assert "R3: card slots carry data-repo"  '<div class="card-slot[^"]*"[^>]* data-repo="[^"]+"' "$render"
assert "R3: roadmap lanes carry data-repo" '<div class="rm-lane[^"]*" id="lane-[^"]+"[^>]* data-repo="[^"]+"' "$render"
assert "R3: week cards carry data-repo"  '<div class="week-card"[^>]* data-repo="[^"]+"' "$render"
# Regression (fix(review) P1): the Week view's queue/shelf .qs-chip rows are in
# applyRepo()'s selector too, so they must carry data-repo like every other
# filtered surface — else picking any specific repo silently empties the Shelf
# row. Both the unblocked (planned) and shelf (paused) chip builders must emit it.
assert "R3: queue/shelf chips carry data-repo" 'class="qs-chip [a-z]+ copyable" data-stem="[^"]+" data-anchor="[^"]+" data-family="[^"]+" data-repo="[^"]+"' "$render"
# R23: the tab badges are store-wide and must NOT move with the filter.
badge_after="$(printf '%s' "$render" | grep -o 'class="tab-badge">[0-9]*' | head -1 | grep -o '[0-9]*$' || true)"
assert_eq "R23: the repo filter does not restate the tab badge" "$expected_badge" "$badge_after"

# Item 4: which repo a task belongs to, wherever a task is named.
assert "R4: rail rows show a repo badge"    '<span class="repo-badge mono">' "$render"
assert "R4: cards show a repo badge in the id row" 'class="card-id mono copyable"[^>]*>[^<]*</span><a class="open-ic[^>]*>[^<]*</a><span class="repo-badge mono">' "$render"
assert "R4: the detail header shows a repo badge" 'class="detail-pill st-[a-z]+">[a-z]+</span><span class="repo-badge mono">' "$render"

# Item 6: a family block opens with the SAME summary component an expanded
# task uses, built by the same helper so the two cannot drift.
assert "R6: a family block leads with a summary-first header" '<div class="fam-summary detail"><div class="detail-head">' "$render"
assert "R6: that summary carries the Now line too" '<div class="fam-summary detail">.*<div class="detail-now"><span class="lbl">Now</span>' "$render"
fam_summaries="$(printf '%s' "$render" | grep -o 'class="fam-summary detail"' | wc -l || true)"
assert_eq "R6: one top-level summary per family" "$fam_badge_count" "$fam_summaries"
# A ladder rung expands into the shared block, like every other expansion.
assert "R6: a rung mounts the shared detail block on expand" 'function toggleRung' "$render"
assert "R6: a rung carries a mount host for its child" '<div class="detail-host" data-anchor="[^"]+"></div><div class="rung-body">' "$render"
assert "R6: a pre-expanded rung is mounted on load" "querySelectorAll\('\.rung\.expanded > \.detail-host'\)" "$render"

# --- review fixes: D1 (phantom-parent shell-safety), D3 (anchor collision),
#     D5 (stage-strip DONE branches) --------------------------------------
# D1: the metachar `parent:` was dropped at collect, so it created no family
# (still 5, asserted above) and no data-copy smuggled a shell metacharacter.
if printf '%s' "$render" | grep -E 'data-copy="wb resume [^"]*[;&|$<> ]' >/dev/null 2>&1; then
  echo "FAIL - D1: a data-copy contains a shell metacharacter (phantom parent leaked)"; fail=1
else
  echo "ok   - D1: no data-copy contains a shell metacharacter"
fi
assert_eq "D1: a metachar parent: does not create a phantom family" "6" "$fam_badge_count"

# D3: two distinct stems that sanitize to the same base get DISTINCT anchors,
# so U8's #detail-pool getElementById() can't mount the wrong task's block.
assert "D3: coll.ide gets an anchor" '.' "${STEM_ANCHOR[coll.ide]:-}"
assert "D3: coll-ide gets an anchor" '.' "${STEM_ANCHOR[coll-ide]:-}"
assert_eq "D3: colliding stems get DISTINCT anchors" "yes" \
  "$([ -n "${STEM_ANCHOR[coll.ide]:-}" ] && [ "${STEM_ANCHOR[coll.ide]:-}" != "${STEM_ANCHOR[coll-ide]:-}" ] && echo yes || echo no)"
assert_eq "D3: the collision is disambiguated to base + base-2" "coll-ide coll-ide-2" \
  "$(printf '%s\n%s\n' "${STEM_ANCHOR[coll.ide]}" "${STEM_ANCHOR[coll-ide]}" | sort | tr '\n' ' ' | sed 's/ $//')"

# D5: wb_board_v2_stage_states' DONE branches (a done task renders no card, so
# call the resolver directly, binding the model arrays under the nameref names
# it reads). donestage: ideate+brainstorm text (sig bits 0/1) and status:done
# (work stage) all resolve DONE; plan+review have no done/progress signal but
# ARE in the default path membership (empty path: => bits 00111), so they show
# as `p` (pending) => "ddpdp" (ideate d, brainstorm d, plan p, work d, review p).
declare -n _m_stage_sig=M_STAGE_SIG _m_status=M_STATUS _m_plan_checked=M_PLAN_CHECKED
donestage_states=""; wb_board_v2_stage_states donestage donestage_states
unset -n _m_stage_sig _m_status _m_plan_checked
assert_eq "D5: ideate/brainstorm text + status:done fire the stage DONE branches" "ddpdp" "$donestage_states"

# --- U5: Dependencies region wiring (R8) -----------------------------------
# fam_block <anchor> extracts one family's own <div class="fam-block" id="fam-
# <anchor>">...</div> slice out of the full render — grep -Pzo (null-delimited,
# PCRE, (?s) so `.` spans real newlines) with a non-greedy `.*?` up to the NEXT
# family block's own id, so a match can never spill into another family's
# markup, no matter how the whole page happens to be laid out on-disk (single
# giant line vs many).
fam_block() { # <anchor>
  printf '%s' "$render" \
    | grep -Pzo "(?s)<div class=\"fam-block\" id=\"fam-$1\".*?(?=<div class=\"fam-block\" id=\"fam-|\z)" \
    | tr -d '\0'
}

flat_with_edges="$(fam_block fam-parent)"
assert "U5: flat family WITH edges shows the Dependencies region" 'class="fam-dag"' "$flat_with_edges"
assert "U5: flat family WITH edges — region sits above Family tree" \
  'region-label">Dependencies</h2>.*Family tree' "$flat_with_edges"
# NB: `class="scope-empty"` (the actual empty-state div's class attribute),
# never bare `scope-empty` — the page's shared <script> block (page-wide,
# trailing every family block, including whichever family sorts last) also
# contains the LITERAL STRING 'active-scope-empty' (an unrelated
# getElementById id, the Active view's own separate empty-state element),
# which a substring-only check would false-positive on whenever this
# family happens to be last in title-sort order.
if printf '%s' "$flat_with_edges" | grep -F 'class="scope-empty"' >/dev/null 2>&1; then
  echo "FAIL - U5: flat family WITH edges should not show the empty-state"; fail=1
else
  echo "ok   - U5: flat family WITH edges shows no empty-state"
fi

flat_no_edges="$(fam_block xss-parent)"
if printf '%s' "$flat_no_edges" | grep -F 'class="fam-dag"' >/dev/null 2>&1; then
  echo "FAIL - U5: flat family WITHOUT edges should not render a dag SVG"; fail=1
else
  echo "ok   - U5: flat family WITHOUT edges renders no dag SVG"
fi
assert "U5: flat family WITHOUT edges shows the depends_on: empty-state" \
  'scope-empty">No dependency data yet.*<code>depends_on:</code>' "$flat_no_edges"

ladder_with_edges="$(fam_block ladder2-parent)"
assert "U5: ladder family WITH edges shows the Dependencies region" 'class="fam-dag"' "$ladder_with_edges"
assert "U5: ladder family WITH edges — region sits above Version ladder" \
  'region-label">Dependencies</h2>.*Version ladder' "$ladder_with_edges"

ladder_no_edges="$(fam_block ladder-parent)"
if printf '%s' "$ladder_no_edges" | grep -F 'class="fam-dag"' >/dev/null 2>&1; then
  echo "FAIL - U5: ladder family WITHOUT edges should not render a dag SVG"; fail=1
else
  echo "ok   - U5: ladder family WITHOUT edges renders no dag SVG"
fi
if printf '%s' "$ladder_no_edges" | grep -F 'class="scope-empty"' >/dev/null 2>&1; then
  echo "FAIL - U5: ladder family WITHOUT edges should show neither region nor empty-state"; fail=1
else
  echo "ok   - U5: ladder family WITHOUT edges shows no empty-state either (R8: ladder shape never shows it)"
fi

ghost_block="$(fam_block ghost-parent)"
assert "U5: a phantom-root family still renders its children's graph" 'class="fam-dag"' "$ghost_block"
ghost_edge_count="$(printf '%s' "$ghost_block" | grep -o 'class="dag-edge ' | wc -l || true)"
assert_eq "U5: phantom-root family — exactly 1 rendered edge (child->child, not child->root)" "1" "$ghost_edge_count"

# --- U5: family-rollup.json side-output ----------------------------------
rollup="$FIXTURE_TASKS/.board-cache/family-rollup.json"
assert_eq "family-rollup.json is written" "0" "$([ -f "$rollup" ] && echo 0 || echo 1)"
if command -v jq >/dev/null 2>&1 && [ -f "$rollup" ]; then
  assert_eq "family-rollup.json validates (jq parses it)" "0" "$(jq empty "$rollup" >/dev/null 2>&1; echo $?)"
  rollup_families="$(jq 'length' "$rollup" 2>/dev/null || echo -1)"
  assert_eq "family-rollup.json has one entry per model family" "$fam_badge_count" "$rollup_families"
  ladder_child="$(jq -r '.[] | select(.root=="ladder-parent") | .rungs[0].child' "$rollup" 2>/dev/null)"
  assert_eq "family-rollup.json ladder rung resolves the same child as the HTML" "ladder-parent-child1" "$ladder_child"

  # fix(review) D2: children carry `repo` so a multi-repo /handoff consumer can
  # route each without re-deriving it.
  child_repo="$(jq -r '.[] | select(.root=="fam-parent") | .children[0].repo' "$rollup" 2>/dev/null)"
  assert_eq "D2: rollup children carry repo" "dotfiles" "$child_repo"

  # fix(review) D2: artifacts carry the RESOLVED link (abs path, file:// href,
  # boolean missing) the HTML uses — not just the raw as-authored path an agent
  # can't open. (fam-parent's dossiers/*.md fixtures aren't on disk, so missing
  # is true; abs/href are still resolved.)
  art_resolved="$(jq -r '.[] | select(.root=="fam-parent") | all(.artifacts[]; (.abs|length>0) and (.href|startswith("file://")) and (.missing|type=="boolean"))' "$rollup" 2>/dev/null)"
  assert_eq "D2: rollup artifacts carry resolved abs/href/missing" "true" "$art_resolved"
  # raw path is kept too (additive, back-compat).
  art_has_path="$(jq -r '.[] | select(.root=="fam-parent") | all(.artifacts[]; .path|length>0)' "$rollup" 2>/dev/null)"
  assert_eq "D2: rollup artifacts keep the raw path (additive)" "true" "$art_has_path"

  # deep coverage: the two same-basename plan.md artifacts (fam-parent's own and
  # fam-parent-child1's) both survive as DISTINCT paths — not deduped on basename.
  plan_paths="$(jq -r '.[] | select(.root=="fam-parent") | [.artifacts[].path] | map(select(endswith("plan.md"))) | unique | length' "$rollup" 2>/dev/null)"
  assert_eq "deep: same-basename plan.md artifacts kept distinct in the rollup" "2" "$plan_paths"

  # deep coverage: the family's Decisions text is aggregated into the entry.
  dec_count="$(jq -r '.[] | select(.root=="fam-parent") | .decisions | length' "$rollup" 2>/dev/null)"
  assert_eq "deep: rollup aggregates the family's decision(s)" "1" "$dec_count"
  dec_text="$(jq -r '.[] | select(.root=="fam-parent") | .decisions[0].text' "$rollup" 2>/dev/null)"
  assert "deep: the aggregated decision carries its text" 'Ship it this way|simpler approach|Chose' "$dec_text"

  # --- U5: family-rollup.json — size/layer/critical/startable/critical_path/
  # remaining (R13). fam-parent-child2 depends_on fam-parent-child1, a
  # 2-node chain, so child1 is layer 0/critical/startable, child2 is layer
  # 1/critical/not-startable (blocked by child1) -----------------------------
  c1_layer="$(jq -r '.[] | select(.root=="fam-parent") | .children[] | select(.id=="fam-parent-child1") | .layer' "$rollup" 2>/dev/null)"
  assert_eq "R13: rollup child1 (chain start) is layer 0" "0" "$c1_layer"
  c2_layer="$(jq -r '.[] | select(.root=="fam-parent") | .children[] | select(.id=="fam-parent-child2") | .layer' "$rollup" 2>/dev/null)"
  assert_eq "R13: rollup child2 (chain end) is layer 1" "1" "$c2_layer"
  c1_critical="$(jq -r '.[] | select(.root=="fam-parent") | .children[] | select(.id=="fam-parent-child1") | .critical' "$rollup" 2>/dev/null)"
  assert_eq "R13: rollup child1 is on the critical path" "true" "$c1_critical"
  c1_startable="$(jq -r '.[] | select(.root=="fam-parent") | .children[] | select(.id=="fam-parent-child1") | .startable' "$rollup" 2>/dev/null)"
  assert_eq "R13: rollup child1 (no blocker) is startable" "true" "$c1_startable"
  c2_startable="$(jq -r '.[] | select(.root=="fam-parent") | .children[] | select(.id=="fam-parent-child2") | .startable' "$rollup" 2>/dev/null)"
  assert_eq "R13: rollup child2 (blocked by child1) is not startable" "false" "$c2_startable"
  c1_size="$(jq -r '.[] | select(.root=="fam-parent") | .children[] | select(.id=="fam-parent-child1") | .size' "$rollup" 2>/dev/null)"
  assert_eq "R13: rollup child carries size (blank when unset)" "" "$c1_size"
  parent_layer="$(jq -r '.[] | select(.root=="fam-parent") | .children[] | select(.is_parent==true) | .layer' "$rollup" 2>/dev/null)"
  assert_eq "R13: rollup parent entry has layer: null" "null" "$parent_layer"
  parent_critical="$(jq -r '.[] | select(.root=="fam-parent") | .children[] | select(.is_parent==true) | .critical' "$rollup" 2>/dev/null)"
  assert_eq "R13: rollup parent entry critical is false" "false" "$parent_critical"
  parent_startable="$(jq -r '.[] | select(.root=="fam-parent") | .children[] | select(.is_parent==true) | .startable' "$rollup" 2>/dev/null)"
  assert_eq "R13: rollup parent entry startable is false" "false" "$parent_startable"
  fam_parent_critpath="$(jq -r '.[] | select(.root=="fam-parent") | .critical_path | join(",")' "$rollup" 2>/dev/null)"
  assert_eq "R13: rollup critical_path names the 2-node chain in order" "fam-parent-child1,fam-parent-child2" "$fam_parent_critpath"
  fam_parent_remaining="$(jq -r '.[] | select(.root=="fam-parent") | .remaining' "$rollup" 2>/dev/null)"
  assert "R13: rollup remaining is a bare JSON number" '^[0-9]+(\.5)?$' "$fam_parent_remaining"

  # A zero-edge family still gets defaulted, well-typed fields (no edges ->
  # no critical path, layer 0 for its lone child, remaining is its own weight).
  xss_child_layer="$(jq -r '.[] | select(.root=="xss-parent") | .children[] | select(.is_parent==false) | .layer' "$rollup" 2>/dev/null)"
  assert_eq "R13: zero-edge family's lone child still gets layer 0" "0" "$xss_child_layer"
  xss_critpath_len="$(jq -r '.[] | select(.root=="xss-parent") | .critical_path | length' "$rollup" 2>/dev/null)"
  assert_eq "R13: zero-edge family's critical_path can still be non-empty (lone node's own weight)" "1" "$xss_critpath_len"

  # ghost-parent: phantom root, two children, ghost-child -> ghost-child2 is
  # the only real edge (the ghost-child2 -> ghost-parent edge is to the root,
  # never a node — R3).
  ghost_edges="$(jq -r '.[] | select(.root=="ghost-parent") | .critical_path | join(",")' "$rollup" 2>/dev/null)"
  assert_eq "R13: phantom-root family's critical_path is the real in-family chain" "ghost-child,ghost-child2" "$ghost_edges"
fi

# ===========================================================================
# U4 — wb_board_v2_dag_html: the Dependencies region's SVG emitter. Calls the
# function directly with hand-built wb_board_deps_layer-shaped output arrays
# (same style as wb-board-deps.test.sh's DL1..DLn fixtures) plus a minimal
# set of `_m_*` model maps bound the same way D5 above binds M_STAGE_SIG/
# M_STATUS/M_PLAN_CHECKED under wb_board_v2_stage_states's nameref names:
# `declare -n` to this function's expected dynamic-scope names, call, then
# `unset -n` so later assertions in this file are unaffected.
# ===========================================================================
TASK_HREF_PREFIX="file:///tasks/"

# --- DAG1: three-node chain (all S, all planned) — three node groups, two
# edge paths, header names the path and "3 pts remaining" (3 * S(2)=6 doubled
# -> 3 pts) -------------------------------------------------------------
declare -a DAG1_NODES=(a1 a2 a3)
declare -A DAG1_LAYER=([a1]=0 [a2]=1 [a3]=2)
declare -A DAG1_ORDER=([a1]=0 [a2]=0 [a3]=0)
declare -A DAG1_CRIT=([a1]=1 [a2]=1 [a3]=1)
declare -A DAG1_STARTABLE=([a1]=1 [a2]=0 [a3]=0)
declare -A DAG1_EXTBLK=()
declare -A DAG1_TAG=([a1]=START [a2]="" [a3]=END)
declare -a DAG1_EDGES=("a1 a2" "a2 a3")
declare -a DAG1_BACKEDGES=()
declare -a DAG1_CRITPATH=(a1 a2 a3)
declare -A M_STATUS=([a1]=planned [a2]=planned [a3]=planned)
declare -A M_TITLE=([a1]="Node A1" [a2]="Node A2" [a3]="Node A3")
declare -A M_SIZE=([a1]=S [a2]=S [a3]=S)
declare -A M_ACCEPT=([a1]=0 [a2]=0 [a3]=0)
declare -A M_PLAN_RAW=([a1]="" [a2]="" [a3]="")
declare -A M_STEM_ANCHOR=([a1]=anchor-a1 [a2]=anchor-a2 [a3]=anchor-a3)
declare -n _m_status=M_STATUS _m_title=M_TITLE _m_size=M_SIZE _m_accept=M_ACCEPT \
  _m_plan_raw=M_PLAN_RAW _m_stem_anchor=M_STEM_ANCHOR
dag1_html=""
wb_board_v2_dag_html fam1 DAG1_NODES DAG1_LAYER DAG1_ORDER DAG1_CRIT DAG1_STARTABLE \
  DAG1_EXTBLK DAG1_TAG DAG1_EDGES DAG1_BACKEDGES DAG1_CRITPATH 6 2 "" dag1_html
unset -n _m_status _m_title _m_size _m_accept _m_plan_raw _m_stem_anchor

# Trailing space distinguishes a real per-node/per-edge class attribute
# ("dag-node dag-st-planned...") from the wrapper groups' own
# class="dag-nodes"/class="dag-edges" (no space after the 's').
dag1_node_groups="$(printf '%s' "$dag1_html" | grep -o 'class="dag-node ' | wc -l || true)"
assert_eq "U4 DAG1: three node groups" "3" "$dag1_node_groups"
dag1_edge_paths="$(printf '%s' "$dag1_html" | grep -o 'class="dag-edge ' | wc -l || true)"
assert_eq "U4 DAG1: two edge paths" "2" "$dag1_edge_paths"
assert "U4 DAG1: header names the path" 'Critical path.*a1.*a2.*a3' "$dag1_html"
assert "U4 DAG1: header reports 3 pts remaining" '3 pts remaining' "$dag1_html"
if printf '%s' "$dag1_html" | grep -F '<script' >/dev/null 2>&1; then
  echo "FAIL - U4 DAG1: output contains <script"; fail=1
else
  echo "ok   - U4 DAG1: output contains no <script"
fi

# --- DAG2: under-defined planned node is dashed; a done node with the same
# 0 signals is never dashed (KTD6 — done always solid) -----------------------
declare -a DAG2_NODES=(u1 d1)
declare -A DAG2_LAYER=([u1]=0 [d1]=0)
declare -A DAG2_ORDER=([u1]=0 [d1]=1)
declare -A DAG2_CRIT=([u1]=0 [d1]=0)
declare -A DAG2_STARTABLE=([u1]=1 [d1]=0)
declare -A DAG2_EXTBLK=()
declare -A DAG2_TAG=([u1]="" [d1]="")
declare -a DAG2_EDGES=()
declare -a DAG2_BACKEDGES=()
declare -a DAG2_CRITPATH=()
declare -A M2_STATUS=([u1]=planned [d1]=done)
declare -A M2_TITLE=([u1]="Underdefined" [d1]="Done zero-signal")
declare -A M2_SIZE=([u1]="" [d1]="")
declare -A M2_ACCEPT=([u1]=0 [d1]=0)
declare -A M2_PLAN_RAW=([u1]="" [d1]="")
declare -A M2_STEM_ANCHOR=([u1]=anchor-u1 [d1]=anchor-d1)
declare -n _m_status=M2_STATUS _m_title=M2_TITLE _m_size=M2_SIZE _m_accept=M2_ACCEPT \
  _m_plan_raw=M2_PLAN_RAW _m_stem_anchor=M2_STEM_ANCHOR
dag2_html=""
wb_board_v2_dag_html fam2 DAG2_NODES DAG2_LAYER DAG2_ORDER DAG2_CRIT DAG2_STARTABLE \
  DAG2_EXTBLK DAG2_TAG DAG2_EDGES DAG2_BACKEDGES DAG2_CRITPATH 0 0 "" dag2_html
unset -n _m_status _m_title _m_size _m_accept _m_plan_raw _m_stem_anchor

# dag-dashed appears exactly once (only u1's node — d1 is done, KTD6: done
# is always solid regardless of signal count), and it's u1's <a> that carries
# it, not d1's.
dag2_dashed_count="$(printf '%s' "$dag2_html" | grep -o 'dag-dashed' | wc -l || true)"
assert_eq "U4 DAG2: dag-dashed appears exactly once (u1 only, d1 never dashed)" "1" "$dag2_dashed_count"
dag2_u1_tag="$(printf '%s' "$dag2_html" | grep -oE '<a href="[^"]*u1\.md"[^>]*>' || true)"
dag2_d1_tag="$(printf '%s' "$dag2_html" | grep -oE '<a href="[^"]*d1\.md"[^>]*>' || true)"
assert "U4 DAG2: u1's own node carries dag-dashed" 'dag-dashed' "$dag2_u1_tag"
if printf '%s' "$dag2_d1_tag" | grep -F 'dag-dashed' >/dev/null 2>&1; then
  echo "FAIL - U4 DAG2: d1 (done, 0 signals) incorrectly carries dag-dashed"; fail=1
else
  echo "ok   - U4 DAG2: d1 (done, 0 signals) never carries dag-dashed"
fi

# --- DAG3: a `doing` node carries the pulse class; CSS gates the animation
# behind reduced-motion; a startable node carries the static outline class
# and never the pulse; `doing` never carries startable ----------------------
declare -a DAG3_NODES=(doer readyer)
declare -A DAG3_LAYER=([doer]=0 [readyer]=0)
declare -A DAG3_ORDER=([doer]=0 [readyer]=1)
declare -A DAG3_CRIT=([doer]=0 [readyer]=0)
declare -A DAG3_STARTABLE=([doer]=0 [readyer]=1)
declare -A DAG3_EXTBLK=()
declare -A DAG3_TAG=([doer]="" [readyer]="")
declare -a DAG3_EDGES=()
declare -a DAG3_BACKEDGES=()
declare -a DAG3_CRITPATH=()
declare -A M3_STATUS=([doer]=doing [readyer]=planned)
declare -A M3_TITLE=([doer]="Doing thing" [readyer]="Ready thing")
declare -A M3_SIZE=([doer]=M [readyer]=M)
declare -A M3_ACCEPT=([doer]=1 [readyer]=0)
declare -A M3_PLAN_RAW=([doer]="- [x] done bit" [readyer]="")
declare -A M3_STEM_ANCHOR=([doer]=anchor-doer [readyer]=anchor-readyer)
declare -n _m_status=M3_STATUS _m_title=M3_TITLE _m_size=M3_SIZE _m_accept=M3_ACCEPT \
  _m_plan_raw=M3_PLAN_RAW _m_stem_anchor=M3_STEM_ANCHOR
dag3_html=""
wb_board_v2_dag_html fam3 DAG3_NODES DAG3_LAYER DAG3_ORDER DAG3_CRIT DAG3_STARTABLE \
  DAG3_EXTBLK DAG3_TAG DAG3_EDGES DAG3_BACKEDGES DAG3_CRITPATH 4 0 "" dag3_html
unset -n _m_status _m_title _m_size _m_accept _m_plan_raw _m_stem_anchor

assert "U4 DAG3: a doing node carries the pulse-ring class" 'dag-pulse-ring' "$dag3_html"
# The animation rule itself lives in wb-board.sh's <style> block (emitted
# once, page-wide), not in this function's per-family HTML fragment — read
# the source file directly for the CSS gate.
dag_css="$(sed -n '/^<style>$/,/^<\/style>$/p' "$(dirname "$WB")/wb-board.sh")"
# grep -E is line-oriented, and the media block spans several lines, so this
# is a plain bash substring/ordering check rather than a single regex: the
# ONLY `animation:` declaration in the whole stylesheet is .dag-pulse-ring's,
# and it must appear between the reduced-motion query's opening and closing
# braces (i.e. inside the guard, not floating free elsewhere).
dag_css_media="${dag_css#*'@media (prefers-reduced-motion: no-preference)'}"
dag_css_media="${dag_css_media%%$'\n  }'*}"
if [[ "$dag_css_media" == *'dag-pulse-ring'* ]] && [[ "$dag_css_media" == *'animation'* ]]; then
  echo "ok   - U4 DAG3: the pulse animation is gated behind prefers-reduced-motion: no-preference"
else
  echo "FAIL - U4 DAG3: the pulse animation is not gated behind prefers-reduced-motion: no-preference"; fail=1
fi
assert "U4 DAG3: a startable node carries the startable-outline class" 'dag-startable-ring' "$dag3_html"
dag3_pulse_count="$(printf '%s' "$dag3_html" | grep -o 'dag-pulse-ring' | wc -l || true)"
assert_eq "U4 DAG3: exactly one pulse ring (doer only)" "1" "$dag3_pulse_count"
dag3_startable_count="$(printf '%s' "$dag3_html" | grep -o 'dag-startable-ring' | wc -l || true)"
assert_eq "U4 DAG3: exactly one startable ring (readyer only, doer never startable)" "1" "$dag3_startable_count"

# --- DAG4: an out-of-family blocker shows the lock marker with a tooltip
# naming the blocker stem ---------------------------------------------------
declare -a DAG4_NODES=(blocked1)
declare -A DAG4_LAYER=([blocked1]=0)
declare -A DAG4_ORDER=([blocked1]=0)
declare -A DAG4_CRIT=([blocked1]=0)
declare -A DAG4_STARTABLE=([blocked1]=0)
declare -A DAG4_EXTBLK=([blocked1]="ext-cousin")
declare -A DAG4_TAG=([blocked1]="")
declare -a DAG4_EDGES=()
declare -a DAG4_BACKEDGES=()
declare -a DAG4_CRITPATH=()
declare -A M4_STATUS=([blocked1]=planned)
declare -A M4_TITLE=([blocked1]="Blocked node")
declare -A M4_SIZE=([blocked1]=M)
declare -A M4_ACCEPT=([blocked1]=0)
declare -A M4_PLAN_RAW=([blocked1]="")
declare -A M4_STEM_ANCHOR=([blocked1]=anchor-blocked1)
declare -n _m_status=M4_STATUS _m_title=M4_TITLE _m_size=M4_SIZE _m_accept=M4_ACCEPT \
  _m_plan_raw=M4_PLAN_RAW _m_stem_anchor=M4_STEM_ANCHOR
dag4_html=""
wb_board_v2_dag_html fam4 DAG4_NODES DAG4_LAYER DAG4_ORDER DAG4_CRIT DAG4_STARTABLE \
  DAG4_EXTBLK DAG4_TAG DAG4_EDGES DAG4_BACKEDGES DAG4_CRITPATH 4 0 "" dag4_html
unset -n _m_status _m_title _m_size _m_accept _m_plan_raw _m_stem_anchor

assert "U4 DAG4: lock marker present for an externally-blocked node" 'dag-lock' "$dag4_html"
assert "U4 DAG4: the lock tooltip names the out-of-family blocker stem" 'blocked by:[^<]*ext-cousin' "$dag4_html"

# --- DAG5: START/END tags appear on the chain's first/last nodes and
# nowhere else (reuses DAG1's chain-of-3 fixture, already tagged) -----------
dag5_start_count="$(printf '%s' "$dag1_html" | grep -o '>START<' | wc -l || true)"
assert_eq "U4 DAG5: exactly one START tag" "1" "$dag5_start_count"
dag5_end_count="$(printf '%s' "$dag1_html" | grep -o '>END<' | wc -l || true)"
assert_eq "U4 DAG5: exactly one END tag" "1" "$dag5_end_count"

# --- DAG6: an XS node renders a smaller width attribute than an S node -----
declare -a DAG6_NODES=(xs1 s1)
declare -A DAG6_LAYER=([xs1]=0 [s1]=1)
declare -A DAG6_ORDER=([xs1]=0 [s1]=0)
declare -A DAG6_CRIT=([xs1]=0 [s1]=0)
declare -A DAG6_STARTABLE=([xs1]=0 [s1]=0)
declare -A DAG6_EXTBLK=()
declare -A DAG6_TAG=([xs1]="" [s1]="")
declare -a DAG6_EDGES=()
declare -a DAG6_BACKEDGES=()
declare -a DAG6_CRITPATH=()
declare -A M6_STATUS=([xs1]=planned [s1]=planned)
declare -A M6_TITLE=([xs1]="XS node" [s1]="S node")
declare -A M6_SIZE=([xs1]=XS [s1]=S)
declare -A M6_ACCEPT=([xs1]=0 [s1]=0)
declare -A M6_PLAN_RAW=([xs1]="" [s1]="")
declare -A M6_STEM_ANCHOR=([xs1]=anchor-xs1 [s1]=anchor-s1)
declare -n _m_status=M6_STATUS _m_title=M6_TITLE _m_size=M6_SIZE _m_accept=M6_ACCEPT \
  _m_plan_raw=M6_PLAN_RAW _m_stem_anchor=M6_STEM_ANCHOR
dag6_html=""
wb_board_v2_dag_html fam6 DAG6_NODES DAG6_LAYER DAG6_ORDER DAG6_CRIT DAG6_STARTABLE \
  DAG6_EXTBLK DAG6_TAG DAG6_EDGES DAG6_BACKEDGES DAG6_CRITPATH 0 1 "" dag6_html
unset -n _m_status _m_title _m_size _m_accept _m_plan_raw _m_stem_anchor

xs_w="$(printf '%s' "$dag6_html" | grep -oE 'class="dag-card"[^>]*width="[0-9]+"' | head -1 | grep -oE '[0-9]+"$' | tr -d '"' || true)"
s_w="$(printf '%s' "$dag6_html" | grep -oE 'class="dag-card"[^>]*width="[0-9]+"' | sed -n '2p' | grep -oE '[0-9]+"$' | tr -d '"' || true)"
assert_eq "U4 DAG6: XS node width" "104" "$xs_w"
assert_eq "U4 DAG6: S node width" "128" "$s_w"
if [ -n "$xs_w" ] && [ -n "$s_w" ] && [ "$xs_w" -lt "$s_w" ]; then
  echo "ok   - U4 DAG6: XS renders smaller (width attr) than S"
else
  echo "FAIL - U4 DAG6: XS ($xs_w) not smaller than S ($s_w)"; fail=1
fi

# --- DAG7: a title with <, & and quotes is escaped in both the label and
# the tooltip -----------------------------------------------------------
declare -a DAG7_NODES=(nasty)
declare -A DAG7_LAYER=([nasty]=0)
declare -A DAG7_ORDER=([nasty]=0)
declare -A DAG7_CRIT=([nasty]=0)
declare -A DAG7_STARTABLE=([nasty]=0)
declare -A DAG7_EXTBLK=()
declare -A DAG7_TAG=([nasty]="")
declare -a DAG7_EDGES=()
declare -a DAG7_BACKEDGES=()
declare -a DAG7_CRITPATH=()
declare -A M7_STATUS=([nasty]=planned)
declare -A M7_TITLE=([nasty]='<b>"q" & <i>t</i>')
declare -A M7_SIZE=([nasty]=M)
declare -A M7_ACCEPT=([nasty]=0)
declare -A M7_PLAN_RAW=([nasty]="")
declare -A M7_STEM_ANCHOR=([nasty]=anchor-nasty)
declare -n _m_status=M7_STATUS _m_title=M7_TITLE _m_size=M7_SIZE _m_accept=M7_ACCEPT \
  _m_plan_raw=M7_PLAN_RAW _m_stem_anchor=M7_STEM_ANCHOR
dag7_html=""
wb_board_v2_dag_html fam7 DAG7_NODES DAG7_LAYER DAG7_ORDER DAG7_CRIT DAG7_STARTABLE \
  DAG7_EXTBLK DAG7_TAG DAG7_EDGES DAG7_BACKEDGES DAG7_CRITPATH 0 0 "" dag7_html
unset -n _m_status _m_title _m_size _m_accept _m_plan_raw _m_stem_anchor

assert "U4 DAG7: escaped title reaches the output" '&lt;b&gt;&quot;q&quot; &amp; &lt;i&gt;t&lt;/i&gt;' "$dag7_html"
if printf '%s' "$dag7_html" | grep -F '<b>"q"' >/dev/null 2>&1; then
  echo "FAIL - U4 DAG7: raw unescaped title leaked into the output"; fail=1
else
  echo "ok   - U4 DAG7: no raw unescaped title leaked"
fi

# --- DAG12 (review fix 1): a long title is clipped with a single ellipsis
# and NEVER carries wb_board_v2_clip's long prose-block suffix -------------
declare -a DAG12_NODES=(longtitle)
declare -A DAG12_LAYER=([longtitle]=0)
declare -A DAG12_ORDER=([longtitle]=0)
declare -A DAG12_CRIT=([longtitle]=0)
declare -A DAG12_STARTABLE=([longtitle]=0)
declare -A DAG12_EXTBLK=()
declare -A DAG12_TAG=([longtitle]="")
declare -a DAG12_EDGES=()
declare -a DAG12_BACKEDGES=()
declare -a DAG12_CRITPATH=()
declare -A M12_STATUS=([longtitle]=planned)
declare -A M12_TITLE=([longtitle]="This is a very long title that will not fit on one card at all")
declare -A M12_SIZE=([longtitle]=XS)
declare -A M12_ACCEPT=([longtitle]=0)
declare -A M12_PLAN_RAW=([longtitle]="")
declare -A M12_STEM_ANCHOR=([longtitle]=anchor-longtitle)
declare -n _m_status=M12_STATUS _m_title=M12_TITLE _m_size=M12_SIZE _m_accept=M12_ACCEPT \
  _m_plan_raw=M12_PLAN_RAW _m_stem_anchor=M12_STEM_ANCHOR
dag12_html=""
wb_board_v2_dag_html fam12 DAG12_NODES DAG12_LAYER DAG12_ORDER DAG12_CRIT DAG12_STARTABLE \
  DAG12_EXTBLK DAG12_TAG DAG12_EDGES DAG12_BACKEDGES DAG12_CRITPATH 0 0 "" dag12_html
unset -n _m_status _m_title _m_size _m_accept _m_plan_raw _m_stem_anchor

assert "U4 DAG12: a long title is clipped with a single ellipsis" '&#8230;</text>' "$dag12_html"
if printf '%s' "$dag12_html" | grep -F '[clipped' >/dev/null 2>&1; then
  echo "FAIL - U4 DAG12: the long prose-block clip suffix leaked onto a card"; fail=1
else
  echo "ok   - U4 DAG12: never carries the prose-block clip suffix"
fi

# --- DAG8: two calls with different family anchors produce distinct marker
# ids (dag1 used anchor fam1 above; dag6 used fam6) --------------------------
dag1_marker="$(printf '%s' "$dag1_html" | grep -oE '<marker id="[^"]*"' | head -1 || true)"
dag6_marker="$(printf '%s' "$dag6_html" | grep -oE '<marker id="[^"]*"' | head -1 || true)"
assert "U4 DAG8: fam1's marker id carries its anchor" 'fam1' "$dag1_marker"
assert "U4 DAG8: fam6's marker id carries its anchor" 'fam6' "$dag6_marker"
assert_eq "U4 DAG8: marker ids differ across anchors" "yes" "$([ "$dag1_marker" != "$dag6_marker" ] && echo yes || echo no)"

# --- DAG9: an all-done family omits the frontier line and reports "0 pts
# remaining" ------------------------------------------------------------
declare -a DAG9_NODES=(fin1 fin2)
declare -A DAG9_LAYER=([fin1]=0 [fin2]=1)
declare -A DAG9_ORDER=([fin1]=0 [fin2]=0)
declare -A DAG9_CRIT=([fin1]=0 [fin2]=0)
declare -A DAG9_STARTABLE=([fin1]=0 [fin2]=0)
declare -A DAG9_EXTBLK=()
declare -A DAG9_TAG=([fin1]=START [fin2]=END)
declare -a DAG9_EDGES=("fin1 fin2")
declare -a DAG9_BACKEDGES=()
declare -a DAG9_CRITPATH=()
declare -A M9_STATUS=([fin1]=done [fin2]=done)
declare -A M9_TITLE=([fin1]="Fin one" [fin2]="Fin two")
declare -A M9_SIZE=([fin1]=M [fin2]=M)
declare -A M9_ACCEPT=([fin1]=1 [fin2]=1)
declare -A M9_PLAN_RAW=([fin1]="- [x] done" [fin2]="- [x] done")
declare -A M9_STEM_ANCHOR=([fin1]=anchor-fin1 [fin2]=anchor-fin2)
declare -n _m_status=M9_STATUS _m_title=M9_TITLE _m_size=M9_SIZE _m_accept=M9_ACCEPT \
  _m_plan_raw=M9_PLAN_RAW _m_stem_anchor=M9_STEM_ANCHOR
dag9_html=""
wb_board_v2_dag_html fam9 DAG9_NODES DAG9_LAYER DAG9_ORDER DAG9_CRIT DAG9_STARTABLE \
  DAG9_EXTBLK DAG9_TAG DAG9_EDGES DAG9_BACKEDGES DAG9_CRITPATH 0 1 "" dag9_html
unset -n _m_status _m_title _m_size _m_accept _m_plan_raw _m_stem_anchor

assert "U4 DAG9: an all-done family reports 0 pts remaining" '0 pts remaining' "$dag9_html"
if printf '%s' "$dag9_html" | grep -F 'dag-frontier' >/dev/null 2>&1; then
  echo "FAIL - U4 DAG9: an all-done family should omit the frontier line"; fail=1
else
  echo "ok   - U4 DAG9: all-done family omits the frontier line"
fi

# --- DAG9b: the frontier sits before the first unfinished column, and is
# omitted when column 0 already holds unfinished work (no done region to its
# left). A long short-id is clipped with a single ellipsis. -----------------
declare -a DAG9B_NODES=(fin1 todo2)
declare -A DAG9B_LAYER=([fin1]=0 [todo2]=1)
declare -A DAG9B_ORDER=([fin1]=0 [todo2]=0)
declare -A DAG9B_CRIT=([fin1]=0 [todo2]=1)
declare -A DAG9B_STARTABLE=([fin1]=0 [todo2]=1)
declare -A DAG9B_EXTBLK=()
declare -A DAG9B_TAG=([fin1]=START [todo2]=END)
declare -a DAG9B_EDGES=("fin1 todo2")
declare -a DAG9B_BACKEDGES=()
declare -a DAG9B_CRITPATH=(todo2)
declare -A M9B_STATUS=([fin1]=done [todo2]=planned)
declare -A M9B_TITLE=([fin1]="Fin one" [todo2]="Todo two")
declare -A M9B_SIZE=([fin1]=M [todo2]=S)
declare -A M9B_ACCEPT=([fin1]=1 [todo2]=1)
declare -A M9B_PLAN_RAW=([fin1]="- [x] done" [todo2]="- [ ] todo")
declare -A M9B_STEM_ANCHOR=([fin1]=anchor-fin1 [todo2]=anchor-todo2)
declare -n _m_status=M9B_STATUS _m_title=M9B_TITLE _m_size=M9B_SIZE _m_accept=M9B_ACCEPT \
  _m_plan_raw=M9B_PLAN_RAW _m_stem_anchor=M9B_STEM_ANCHOR
dag9b_html=""
wb_board_v2_dag_html fam9b DAG9B_NODES DAG9B_LAYER DAG9B_ORDER DAG9B_CRIT DAG9B_STARTABLE \
  DAG9B_EXTBLK DAG9B_TAG DAG9B_EDGES DAG9B_BACKEDGES DAG9B_CRITPATH 2 1 "" dag9b_html
M9B_STATUS[fin1]=planned
dag9c_html=""
wb_board_v2_dag_html fam9c DAG9B_NODES DAG9B_LAYER DAG9B_ORDER DAG9B_CRIT DAG9B_STARTABLE \
  DAG9B_EXTBLK DAG9B_TAG DAG9B_EDGES DAG9B_BACKEDGES DAG9B_CRITPATH 6 1 "" dag9c_html
declare -a DAG9D_NODES=(proj--a-very-long-child-stem-that-overflows)
declare -A DAG9D_LAYER=([proj--a-very-long-child-stem-that-overflows]=0)
declare -A DAG9D_ORDER=([proj--a-very-long-child-stem-that-overflows]=0)
declare -A DAG9D_CRIT=() DAG9D_STARTABLE=() DAG9D_EXTBLK=() DAG9D_TAG=()
declare -a DAG9D_EDGES=() DAG9D_BACKEDGES=() DAG9D_CRITPATH=()
M9B_STATUS[proj--a-very-long-child-stem-that-overflows]=planned
M9B_SIZE[proj--a-very-long-child-stem-that-overflows]=S
dag9d_html=""
wb_board_v2_dag_html fam9d DAG9D_NODES DAG9D_LAYER DAG9D_ORDER DAG9D_CRIT DAG9D_STARTABLE \
  DAG9D_EXTBLK DAG9D_TAG DAG9D_EDGES DAG9D_BACKEDGES DAG9D_CRITPATH 2 0 "" dag9d_html
unset -n _m_status _m_title _m_size _m_accept _m_plan_raw _m_stem_anchor

assert "U4 DAG9b: frontier drawn before the first unfinished column" 'class="dag-frontier"' "$dag9b_html"
if printf '%s' "$dag9c_html" | grep -F 'dag-frontier' >/dev/null 2>&1; then
  echo "FAIL - U4 DAG9b: unfinished column 0 should omit the frontier line"; fail=1
else
  echo "ok   - U4 DAG9b: unfinished column 0 omits the frontier line"
fi
assert "U4 DAG9b: a long short-id is clipped with an ellipsis" 'class="dag-id"[^>]*>proj--a-v[^<]*&#8230;</text>' "$dag9d_html"
if printf '%s' "$dag9d_html" | grep -F 'that-overflows</text>' >/dev/null 2>&1; then
  echo "FAIL - U4 DAG9b: the full long stem should not appear as the id label"; fail=1
else
  echo "ok   - U4 DAG9b: the full long stem is not rendered as the id label"
fi

# --- DAG10: remaining weight 15 (doubled) displays "7.5 pts" ---------------
declare -a DAG10_NODES=(only1)
declare -A DAG10_LAYER=([only1]=0)
declare -A DAG10_ORDER=([only1]=0)
declare -A DAG10_CRIT=([only1]=1)
declare -A DAG10_STARTABLE=([only1]=1)
declare -A DAG10_EXTBLK=()
declare -A DAG10_TAG=([only1]="")
declare -a DAG10_EDGES=()
declare -a DAG10_BACKEDGES=()
declare -a DAG10_CRITPATH=(only1)
declare -A M10_STATUS=([only1]=planned)
declare -A M10_TITLE=([only1]="Odd weight")
declare -A M10_SIZE=([only1]=L)
declare -A M10_ACCEPT=([only1]=0)
declare -A M10_PLAN_RAW=([only1]="")
declare -A M10_STEM_ANCHOR=([only1]=anchor-only1)
declare -n _m_status=M10_STATUS _m_title=M10_TITLE _m_size=M10_SIZE _m_accept=M10_ACCEPT \
  _m_plan_raw=M10_PLAN_RAW _m_stem_anchor=M10_STEM_ANCHOR
dag10_html=""
wb_board_v2_dag_html fam10 DAG10_NODES DAG10_LAYER DAG10_ORDER DAG10_CRIT DAG10_STARTABLE \
  DAG10_EXTBLK DAG10_TAG DAG10_EDGES DAG10_BACKEDGES DAG10_CRITPATH 15 0 "" dag10_html
unset -n _m_status _m_title _m_size _m_accept _m_plan_raw _m_stem_anchor

assert "U4 DAG10: doubled remaining 15 displays as 7.5 pts" '7\.5 pts remaining' "$dag10_html"

# --- DAG11: a back-edge renders with the warning class ---------------------
declare -a DAG11_NODES=(cyc1 cyc2 lead)
declare -A DAG11_LAYER=([cyc1]=1 [cyc2]=1 [lead]=0)
declare -A DAG11_ORDER=([cyc1]=0 [cyc2]=1 [lead]=0)
declare -A DAG11_CRIT=([cyc1]=0 [cyc2]=0 [lead]=0)
declare -A DAG11_STARTABLE=([cyc1]=0 [cyc2]=0 [lead]=1)
declare -A DAG11_EXTBLK=()
declare -A DAG11_TAG=([cyc1]="" [cyc2]="" [lead]=START)
declare -a DAG11_EDGES=("lead cyc1")
declare -a DAG11_BACKEDGES=("cyc1 cyc2")
declare -a DAG11_CRITPATH=()
declare -A M11_STATUS=([cyc1]=planned [cyc2]=planned [lead]=planned)
declare -A M11_TITLE=([cyc1]="Cyc one" [cyc2]="Cyc two" [lead]="Lead")
declare -A M11_SIZE=([cyc1]=M [cyc2]=M [lead]=M)
declare -A M11_ACCEPT=([cyc1]=0 [cyc2]=0 [lead]=0)
declare -A M11_PLAN_RAW=([cyc1]="" [cyc2]="" [lead]="")
declare -A M11_STEM_ANCHOR=([cyc1]=anchor-cyc1 [cyc2]=anchor-cyc2 [lead]=anchor-lead)
declare -n _m_status=M11_STATUS _m_title=M11_TITLE _m_size=M11_SIZE _m_accept=M11_ACCEPT \
  _m_plan_raw=M11_PLAN_RAW _m_stem_anchor=M11_STEM_ANCHOR
dag11_html=""
wb_board_v2_dag_html fam11 DAG11_NODES DAG11_LAYER DAG11_ORDER DAG11_CRIT DAG11_STARTABLE \
  DAG11_EXTBLK DAG11_TAG DAG11_EDGES DAG11_BACKEDGES DAG11_CRITPATH 0 1 "" dag11_html
unset -n _m_status _m_title _m_size _m_accept _m_plan_raw _m_stem_anchor

assert "U4 DAG11: a back-edge renders with the warning class" 'dag-edge-warn' "$dag11_html"

echo
if [ "$fail" = 0 ]; then echo "wb-board-render.test.sh: all assertions passed"
else echo "wb-board-render.test.sh: FAILURES"; fi
exit "$fail"
