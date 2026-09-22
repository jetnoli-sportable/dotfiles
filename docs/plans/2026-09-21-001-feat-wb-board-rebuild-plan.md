---
artifact_contract: ce-unified-plan/v1
artifact_readiness: implementation-ready
execution: code
product_contract_source: ce-plan-bootstrap
origin: ../../../tasks/dotfiles--feat-board-build.md
created: 2026-09-21
type: feat
---

# feat: Rebuild `wb board` as a fast multi-view surface + stacked family view

**Target file:** `scripts/.config/scripts/tmux/wb.sh` (moving board code to a new sibling `scripts/.config/scripts/tmux/wb-board.sh`).

## Summary

Rebuild `wb board`'s HTML renderer to match the ratified reference design (`~/code/tasks/dossiers/dotfiles--workflow-strategy-and-ceremonies/board-design/board-reference-final.html`, mockup "O") — a 340px sidebar rail plus three client-side views (Active, Roadmap, Week) — rendering in ≤10s (5s target) against the real ~235-task store, down from today's ~7min. The slowness is not the frontmatter pass; it is two per-row/per-repo shell-outs (`tmux list-sessions`, `gh pr view`) whose output the new design doesn't render, so the perf win is deletion. Delivered as two stacked PRs: **PR 1** ships the fast 3-view board via a new verb with a parity check before cutover; **PR 2** stacks the fourth "Family" view (family-recall — recall a family's decisions and grab its artifacts, shaped as a version-ladder) on top.

**Product Contract preservation:** requirements R15–R24 carried verbatim from the origin task file; D3 corrected in origin after in-code discovery (tags already list-form, see Problem Frame).

---

## Problem Frame

`wb board --html` renders the whole `~/code/tasks/` store to a self-contained HTML dashboard. Three problems:

1. **Speed (R15/R16).** `wb_board_render_html` (wb.sh:5308–6323, ~1015 lines) runs one clean frontmatter pass (`wb_board_collect_rows`, wb.sh:4480) but then two expensive sub-passes: `wb_board_live_session_for` shells to `tmux list-sessions` per row, and `wb_board_pr_info` shells to `gh pr view` per unique repo+branch. On ~235 tasks this is the ~7min cost the shelf item flags. The ratified design renders **neither** a live-session badge nor a PR chip — so R16 ("nothing in the render loop calls git, gh, tmux, or reads transcripts") is satisfied by *removing* those passes, not optimizing them.

2. **Shape.** Today's board is a status-oriented table with lifecycle-stage glyphs. The ratified design is a rail + three time/status-sliced views with per-card drilldowns, a roadmap of family lanes, and an ISO-week view. This is a rewrite of the render half, not an edit.

3. **Missing family-recall (the stated main value).** Neither today's board nor the ratified 3 views let you pick a task family and see its decisions + artifacts in one place. This is added in PR 2 as a fourth view.

**Resolved via decision buffer** (`~/code/tasks/dossiers/dotfiles--feat-board-build/decision-records/2026-09-21-board-build-open-points.md`):
- **D1** — new verb `wb board2` alongside the old renderer, parity-check against the real store, then flip dispatch + delete old path in the same PR.
- **D2** — the Family view is in scope (the task's end goal), sequenced as stacked PR 2, based on mockup **D** (version-ladder) borrowing mockup **A**'s decisions-timeline rendering, and must surface child tasks in the parent view.
- **D3 — superseded by current code.** The `tags:` divergence was already fixed by R26: `_wb_tags_merge` (wb.sh:3708) writes canonical `[a, b, c]`, `_wb_tags_parse` (wb.sh:3677) reads every form, and all 302 tagged files are already bracketed (0 bare-scalar). Residual: the new reader reuses `_wb_tags_parse`. No standalone commit, no migration.

---

## Requirements (carried from origin R15–R24)

- **R15** — render in ≤10s (5s target) against the real ~235-task store.
- **R16** — one pass over frontmatter + the last `### ` Handoffs heading per file; nothing in the render loop calls `git`, `gh`, `tmux`, or reads transcripts.
- **R17** — hierarchical sidebar (families as collapsible trees, staleness dot, age) + three client-side views: Active, Roadmap, Week.
- **R18** — Active: one card per `doing` task with a Plan progress ring; selected card expands into Plan (with completion state), Done, latest Handoff, Follow-ups.
- **R19** — Roadmap: one lane per family over a week grid with a TODAY marker, milestone lane headers, readiness cues (ready / blocked + blocker), ready-now strip.
- **R20** — Week: tasks touched this ISO week expanded; carried-over grouped by family, stale ones collapsed; queue-and-shelf row.
- **R21** — stale = 14+ days, full contrast + red, never de-emphasised (no `filter: saturate()`).
- **R22** — task ids click-to-copy `wb resume <id>`.
- **R23** — counts agree across views and with the store (single active/stale/shelved definition).
- **R24** — native dark mode, left-anchored fluid layout `min(96vw, 1800px)`, 340px rail.

UX-review mandates folded into the above: drop redundant `doing` badges; `--mauve` = selection/TODAY only; `/` filter + j/k + 1/2/3 keys; Active deck wraps stale-first; drilldown must follow selection; one home per fact (rail vs. chip-row de-duplication); generated-timestamp line; empty-state drops the quote line.

---

## High-Level Technical Design

Data flows one direction, computed once, rendered per view client-side:

```
wb-board.sh
  wb_board_collect_rows        ── single pass over $TASKS_DIR/*.md ──┐
    per file: frontmatter (wb_read_task) + last "### " Handoffs      │
             + Plan/Done/Follow-ups (wb_board_section, in-pass)      │
             + tags (_wb_tags_parse)                                 │
    NO tmux list-sessions, NO gh pr view                            ▼
  wb_board_build_model         → in-memory model (rows + family rollup)
                                   {task: {status,age,plan_ratio,handoff,...}}
                                   {family: {children[], decisions[], artifacts[]}}  (PR2)
  wb_board_render_v2           → one self-contained HTML doc:
      rail (families as <details> trees)  +  <main>
      [Active] [Roadmap] [Week] [Family(PR2)]  ← client-side tab switch
      ~40 lines JS: showView / toggleGroup / toggleStale / card-select / copy-id
```

Cutover (D1): `board2` runs the new path beside `board` (old) until a parity script confirms count/content agreement on the real store; then one commit flips `board)` → `wb_board_render_v2` and deletes `wb_board_render_html` + the now-orphan `wb_board_live_session_for` / `wb_board_pr_info` helpers.

The Family view (PR 2) renders a family either as a **version-ladder** (when the parent carries a "Version ladder status" table — the pattern from `be--monorepo--spike-port-post-processor-to-metric-server`) or as a **flat family** (children + aggregated decisions/artifacts) otherwise:

```
Family view (mockup D + A):
  family picker
  ├─ ladder present?  → rungs (v0.1…v1.x), each: goal · status pill · child task(s) · decisions/artifacts   + "now" marker + living-status table
  └─ no ladder        → children list (status pills) + aggregated Decisions timeline (mockup A) + Artifacts
```

---

## Output Structure

```
scripts/.config/scripts/tmux/
  wb.sh            (board code removed; sources wb-board.sh)
  wb-board.sh      (NEW — all wb_board_* fns + wb_board_render_v2 + family rollup)
```

---

## Implementation Units

### U1. Split `wb_board_*` into `wb-board.sh`

**Goal:** move every `wb_board_*` function out of `wb.sh` into a new sibling `wb-board.sh`, sourced by `wb.sh`, with zero behavior change. (Parent parked item 4.)
**Requirements:** enabling refactor for R15–R24; keeps the rewrite out of the 5600-line `wb.sh`.
**Dependencies:** none (first unit).
**Files:** `scripts/.config/scripts/tmux/wb.sh` (remove defs, add `source`), `scripts/.config/scripts/tmux/wb-board.sh` (new).
**Approach:** identify the full `wb_board_*` span (collect/section/deps/render/stage helpers, wb.sh:4393–6323 plus stragglers like the pre-pass at 5188). Move verbatim. Add `source "$(dirname "${BASH_SOURCE[0]}")/wb-board.sh"` in `wb.sh` before the dispatch. Confirm the docgen pre-commit hook and the wb Docker test suite still pass. Mind stow: the file must land where the stow package expects (same dir), so a fresh worktree/checkout sources it correctly.
**Patterns to follow:** existing single-file sourcing conventions in the tmux scripts dir; keep function names identical so all internal call sites resolve unchanged.
**Execution note:** pure move — verify by running the existing board (`wb board --html`) before and after and diffing the output; it must be byte-identical.
**Test scenarios:** `Covers R16 (indirect).` Run the current wb Docker suite — the known-failing floor (handoff, handoff-pane, handoff-poller, lib-claude-panes, wb-reconcile-review) must be unchanged; no *new* failures. Board render output byte-identical pre/post move.
**Verification:** `wb board --html` output identical before/after; test suite failing-set unchanged; docgen pre-commit passes.

### U2. Single-pass collect + in-memory model (no git/gh/tmux)

**Goal:** extend the collect pass to gather everything the new views need in one read per file, and drop the live-session/PR sub-passes from the new path.
**Requirements:** R16, R18 (per-task Plan/Done/Handoff/Follow-ups), R23 (single source for counts), D3 residual (reuse `_wb_tags_parse`).
**Dependencies:** U1.
**Files:** `scripts/.config/scripts/tmux/wb-board.sh` (extend `wb_board_collect_rows`; new `wb_board_build_model`), test: `scripts/.config/scripts/tmux/tests/wb-board-model.bats` (or the repo's existing wb test harness location — match it).
**Approach:** inside the existing single `wb_task_files` loop, additionally capture per task: Plan checklist ratio (checked/total from `wb_board_section "$f" "Plan"`), latest Handoff line (last `### ` under `## Handoffs`), Done list, Follow-ups, and `tags` via `_wb_tags_parse`. Compute the staleness bucket (R21: 14+ days) and the active/stale/shelved classification **once** here so every view reads the same numbers (R23). Do **not** call `wb_board_live_session_for` or `wb_board_pr_info` in this path. Emit a stable in-memory model (assoc arrays keyed by anchor, or a single intermediate TSV/JSON) consumed by the renderer.
**Patterns to follow:** `wb_board_section` (wb.sh:4544), `wb_board_bucket_for_status` (4401), `wb_board_anchor_slug` (4413); reuse the dep helpers `wb_board_parse_deps`/`deps_validate`/`deps_cycles`/`deps_blocking` (4715–4871) as-is for R19.
**Execution note:** this is the perf-critical unit — time it against the real store early (`time wb board2 >/dev/null`) to confirm the ≤10s budget before building the renderer on top.
**Test scenarios:** `Covers R16.` No `tmux`/`gh`/`git` invocation during collect (assert via a PATH shim or trace). `Covers R18.` Plan ratio computed correctly (0/n, n/n, no-Plan → em-dash sentinel). `Covers R21.` A task last-touched 14d ago classifies stale; 13d does not. `Covers R23.` active+stale+shelved partition is disjoint and totals the store count. Tags: bare-scalar, `a,b`, and `[a, b]` inputs all parse to the same token set. Empty Handoffs → no-handoff sentinel (not a crash).
**Verification:** `time wb board2` ≤10s on the real store; counts printed by the model match `wb board`'s table counts.

### U3. `wb board2` — ratified 3-view renderer

**Goal:** emit the ratified 3-view HTML (rail + Active/Roadmap/Week) from the model, behind the new `board2` verb.
**Requirements:** R17, R18, R19, R20, R21, R22, R24 + UX-review mandates.
**Dependencies:** U2.
**Files:** `scripts/.config/scripts/tmux/wb-board.sh` (new `wb_board_render_v2`), `scripts/.config/scripts/tmux/wb.sh` (add `board2)` dispatch case near wb.sh:7386).
**Approach:** translate `board-reference-final.html` into the heredoc renderer. Rail: `Doing` heading + rows, families as `<details class="family-node">` trees, staleness dot + mono age; collapsible `Next`/`Shelf` groups. Active: `.deck-row` cards (Plan SVG ring, clamped handoff quote, bold Next line, dot+age footer, no `doing` badge), click-select reveals a drilldown that **follows selection** (3-col Plan/Done+Handoff/Follow-ups). Roadmap: 5-col week grid, readiness strip, family lanes, TODAY line, dashed blocker connectors (reuse dep helpers). Week: ISO-week expanded + carried-over family blocks + stale-toggle + queue/shelf. `~40` lines vanilla JS: `showView` (1/2/3 keys), `toggleGroup`, `toggleStale`, card-select (j/k), `/` filter, copy-id (R22 → clipboard `wb resume <id>`). Palette: Catppuccin Mocha, `--mauve` = selection/TODAY only; layout `min(96vw,1800px)`, 340px rail; native dark mode (no CSS filter). Add a generated-`<timestamp>` line.
**Patterns to follow:** `board-reference-final.html` verbatim for structure/CSS/JS; existing heredoc HTML emission style in the old `wb_board_render_html`; the two-scoped-`<script>` (no external libs) constraint.
**Execution note:** build against the ratified mockup as the spec; render to `logs/board2.html` and eyeball each view before wiring keyboard nav.
**Test scenarios:** `Covers R17.` All three views present; rail lists families as collapsible trees. `Covers R18.` Selecting card X shows X's drilldown (not a hardcoded card) — the round-1 top bug. `Covers R21.` A stale card renders full-contrast red, not desaturated. `Covers R22.` Clicking a task id copies `wb resume <id>`. `Covers R24.` Page is `min(96vw,1800px)`, rail 340px, dark by default. `Covers R23.` Tab count badges equal the model counts. Empty store / single-task / a family with 3 children all render without layout break.
**Verification:** open `logs/board2.html`, walk all three views + keyboard nav in the browser; every view's counts agree (R23); render ≤10s.

### U4. Parity check + cutover (delete old path)

**Goal:** confirm `board2` reaches parity with `board` on the real store, then make `board` use the new renderer and delete the old one.
**Requirements:** R15, R16, R23 (parity is the proof).
**Dependencies:** U3.
**Files:** `scripts/.config/scripts/tmux/wb.sh` (flip `board)` dispatch, remove `board2)`), `scripts/.config/scripts/tmux/wb-board.sh` (delete `wb_board_render_html`, `wb_board_live_session_for`, `wb_board_pr_info`, `wb_board_pr_display`/`_url`, and any other now-orphan helpers), `docs/` regen.
**Approach:** write a throwaway parity check (not shipped) that runs both renderers against the real store and diffs the task set + per-status counts + per-family membership — the numbers must match (live-session/PR chips legitimately differ and are excluded from the diff). Once parity holds, one commit: point `board)` at `wb_board_render_v2`, delete the old renderer and its orphaned shell-out helpers, run `/deadcode`-style grep to confirm no dangling callers, regen docgen.
**Patterns to follow:** clean-room regen via git-archive (never `git checkout` a concurrently-edited worktree); the wb test sandbox known-failure floor as the baseline.
**Execution note:** the deletion is the R15/R16 payoff — verify no remaining caller references the deleted helpers (`grep -rn wb_board_live_session_for wb_board_pr_info`).
**Test scenarios:** `Covers R23.` Parity script reports identical task set + counts + family membership. `Covers R16.` Post-deletion grep finds zero references to the removed shell-out helpers. wb Docker suite failing-set unchanged (no new failures). docgen pre-commit passes.
**Verification:** `wb board --html` now renders the new design ≤10s; old function names absent from the tree; tests + docgen green.

### U5. Family rollup data (PR 2 — parked item 6)

**Goal:** build the machine-readable parent/children rollup as the Family view's data source (and a by-product for future `/handoff` fan-out).
**Requirements:** R23 (family counts agree), D2.
**Dependencies:** U2 (rides the same collect pass).
**Files:** `scripts/.config/scripts/tmux/wb-board.sh` (extend `wb_board_build_model` with a family map), test: wb-board-model test file from U2.
**Approach:** during the single pass, group tasks by `parent` frontmatter into families; per family aggregate: children (id, status, age), the union of `## Decisions` entries (`wb_board_section "$f" "Decisions"` across parent+children, dated, tagged with source task — the data mockup A's timeline renders), and the artifact links (`wb_board_task_doc_chips` / `wb_board_related_docs`, deduped across the family via `wb_board_children_rollup_docs`, wb.sh:4691). Detect a "Version ladder status" table in the parent body → parse rungs (id, goal, status, realizing child) for the ladder shape; absent → flat family. Emit as a JSON side-output (e.g. `~/code/tasks/.board-cache/family-rollup.json`) plus the in-memory map.
**Patterns to follow:** `wb_board_children_rollup_docs` (4691), `wb_board_related_docs` (4653); the ladder-table pattern in `be--monorepo--spike-port-post-processor-to-metric-server.md` (§"Version ladder status").
**Execution note:** keep this inside the U2 pass — a second file read would break R16's one-pass constraint.
**Test scenarios:** `Covers R23.` Family child counts sum to the store's task count with no double-count. A family with a ladder table parses N rungs each mapped to its child; a family without one yields the flat shape. Decisions aggregation preserves source-task attribution and date order. Artifact dedup across parent+children.
**Verification:** `family-rollup.json` validates; counts reconcile with U2's model.

### U6. Fourth "Family" view (PR 2 — mockup D + A)

**Goal:** add the Family view as a first-class fourth tab, ladder-shaped when a ladder exists, surfacing child tasks in the parent view.
**Requirements:** D2, R22, R24; R17 (fourth view).
**Dependencies:** U5, U3 (cutover done — this stacks on the shipped 3-view board).
**Files:** `scripts/.config/scripts/tmux/wb-board.sh` (extend `wb_board_render_v2` with the Family view + tab), family-view smoke test.
**Approach:** tab bar gains `[ Family ]`. A family picker selects a family from the rollup. Render mockup **D**'s ladder (ordered rungs → child task(s), status pills, a `--mauve` "now" marker on the active rung, a compact living-status table) for ladder families; render the flat shape (children list + mockup **A**'s aggregated decisions timeline + artifact links) otherwise. Child/sub-tasks are surfaced inline in the parent view (D2's explicit requirement). Reuse the U3 click-to-copy for `wb resume <child-id>` (R22) and the artifact chips as grab-able links. Keep the JS additive (`showView` already handles a 4th tab).
**Patterns to follow:** `~/design-mocks/wb-board-family/d-ladder-view.html` (ladder structure) and `a-fourth-view.html` (decisions timeline rendering); the ratified board's rail/card/pill CSS conventions.
**Execution note:** build against mockups D+A; render to `logs/board2.html`, verify the Family tab in the browser for both a ladder family and a flat family.
**Test scenarios:** `Covers D2.` Family view lists a family's children with status; a ladder family renders rungs with a now-marker; a flat family renders the decisions timeline + artifacts. `Covers R22.` Child id copies `wb resume <child-id>`. `Covers R23.` Family-view counts match the rollup and the other views. `Covers R24.` Fourth tab respects the palette (mauve = selection/now only) and layout. Family with no decisions / no artifacts → clean empty state, no placeholder spam.
**Verification:** open `logs/board2.html`, exercise the Family tab for a ladder family (`dotfiles--workflow-strategy-and-ceremonies` or the post-processor spike) and a flat family; counts reconcile; render still ≤10s.

---

## Scope Boundaries

**In scope:** the ≤10s 3-view board (PR 1) and the Family view (PR 2), the `wb-board.sh` split, the parent/children rollup, reuse of `_wb_tags_parse`.

### Deferred to Follow-Up Work
- Full version-ladder authoring/maintenance tooling (living-status-table auto-upkeep) — that is `dotfiles--wb-hooks-parent-task-roadmap-upkeep`'s job; U5/U6 only *read* a ladder table if present.
- htmx / server-driven interactivity migration (raised in the absorbed ux-review task) — the board stays self-contained CSS + ~40 lines vanilla JS; no external libs.
- Any board-served write actions (fold-in, checkbox persistence, comments) — explicitly out per the UX review's do-NOT-add list.

### Explicitly not building
Status kanban, burndown/velocity, drag-drop, persisted localStorage checkbox state, comments/notifications (UX-review do-NOT-add list).

---

## Risks & Dependencies

- **Perf regression risk:** if U2's in-pass Plan/Done/Follow-ups extraction is naive (re-scanning each file per section), it could reintroduce cost. Mitigation: single read per file, parse all sections from the buffered content; time against the real store in U2 before building U3.
- **Cutover risk (U4):** deleting `wb_board_render_html` before parity is confirmed would remove the fallback. Mitigation: parity script must pass first; the old path stays live behind `board)` until the flip commit.
- **Concurrent-worktree risk:** the shared task store and stash stack have other writers. Mitigation: read-only collect; clean-room regen via git-archive, never `git checkout`/`reset` this worktree.
- **Test-sandbox baseline:** the wb Docker suite has a known 5-file failing floor (env-dependent). Do not read raw exit 1 as regression — baseline-compare the failing-file set (~15–20 min run).
- **Dependency on cutover for PR 2:** U6 stacks on the shipped 3-view board; PR 2 branch bases on PR 1.

---

## Definition of Done

- `wb board --html` renders the ratified 3-view design in ≤10s on the real store (R15), with no `git`/`gh`/`tmux`/transcript access in the render path (R16).
- All of R17–R24 satisfied and verified live in a browser (not just by tests).
- Old `wb_board_render_html` + orphaned shell-out helpers deleted; no dangling callers; docgen + wb test suite failing-set unchanged.
- PR 2: Family view live as a fourth tab, ladder-shaped when a ladder table exists, flat otherwise, surfacing child tasks; family rollup emitted; counts reconcile across all four views (R23).
- Reviewed via `/ce-code-review`, then `wb reviewed` stamped.

---

## Sources & Research

- Ratified design: `~/code/tasks/dossiers/dotfiles--workflow-strategy-and-ceremonies/board-design/board-reference-final.html`
- UX review: `~/code/tasks/dossiers/dotfiles--workflow-strategy-and-ceremonies/ux-review-board-m-2026-09-14.md`
- Decision buffer (D1/D2/D3): `~/code/tasks/dossiers/dotfiles--feat-board-build/decision-records/2026-09-21-board-build-open-points.md`
- Family-view mockups: `~/design-mocks/wb-board-family/{a-fourth-view,d-ladder-view}.html`
- Version-ladder pattern: `~/code/tasks/be--monorepo--spike-port-post-processor-to-metric-server.md` (§"Version ladder status"); upkeep task `dotfiles--wb-hooks-parent-task-roadmap-upkeep`
- Current code: `scripts/.config/scripts/tmux/wb.sh` — `wb_board_*` (4393–6323), `wb_board_render_html` (5308), tags helpers `_wb_tags_parse`/`_wb_tags_merge` (3677/3708), dispatch (7386).
