---
title: /board — task-board visualization
status: current
tile: Full HTML board shipped — lifecycle stepper, Pipeline tab, relationships, filters, Key Findings.
group: design-notes
parent: roadmap
kind: page
updated: 2026-07-14
---

Renamed from `/roadmap` (2026-07-07, Decision 5A) once "roadmap" collided
with this document's own name — "roadmap" now unambiguously means
`docs/roadmap.md`, the feature is `/board`. This page is the source; edit
`docs/roadmap-board.md`, not the rendered `.html`.

**Roadmap:** 9a (superseded — this page is the detail) · **Status:**
v1 HTML board shipped, then v2 (stepper/Pipeline/relationships/filters/Key
Findings) shipped on top of it — see [What shipped in v2](#what-shipped-in-v2-board-display-v2) below.

## The gap this closes

The picker redesign (`wb`, PR #7) made rows presence-only — live
sessions/agents only, the right call for signal-to-noise — but it meant
there was no single view of live + deferred (`## Follow-ups`) + parked
(`/park` ledger) work; each lived in a different place (`wb`, `grep
~/code/tasks/*.md`, `/parked-items`). Closing that gap is exactly what
`/board` is for.

## What shipped already: `wb board`

An interim, read-only `wb board` subcommand — a plain-text table over
store frontmatter, reusing `wb_read_task` — landed in the pre-slice-5
remediation pass specifically to close the visibility gap immediately
rather than waiting for the full HTML feature.

## What's still deferred: the full HTML `/board`

Scoped via a decision-buffer round on 2026-07-08
(`logs/decisions/2026-07-08-board-scoping.md`, gitignored scratch — this
page is the durable record of what got decided). Superseding the earlier
2026-07-06 constraints below it — the docgen/zoom-level shape originally
planned was replaced by a simpler bash-native design once actually scoped:

- **Output shape:** one gitignored file, `logs/board.html`, regenerated
  live by extending `wb.sh` in bash — **not** the docgen HTML pipeline
  (the original 2026-07-06 plan assumed docgen; superseded).
- **Query model:** two composable filters, not zoom levels — **status**
  (All / Upcoming = `planned` / Paused = a new status value / in-progress
  is the implicit default) and **timeline** (today / this week).
  In-progress tasks always show regardless of timeline; timeline
  additionally pulls in tasks *closed* within the window, via a new
  `closed:` frontmatter field stamped when a task flips to `done`.
  **v2 pass (2026-07-12 plan):** added a third, window-independent
  **Pipeline** tab (every non-done task, regardless of timeline — see
  below) plus two more composable filters, **Repo** and **Family**, that
  narrow every tab/timeline combination at once.
- **Per-task drill-down:** inline `<details>`/`<summary>` expansion in the
  single HTML file, not separate per-task pages (per-task files stay an
  explicit, deferred follow-up).
- **Transcript-to-task matching, if/when built:** exact `.cwd`/`.gitBranch`
  match only, no fuzzy slug/keyword search — deferred to a follow-up
  alongside per-task file output, since it has no existing precedent
  anywhere in this codebase.
- **`wb pause`:** a new status value plus both a `wb pause [<session>]`
  subcommand (mirrors `wb done`, skips worktree teardown) and a picker
  keybind (`p`), needed to support the Paused status filter above.
- Sourced from the store + parked ledger + decision docs + (deferred)
  transcripts.
- **Jira integration is explicitly excluded** — it's its own later,
  separately-ratified addition (same open questions as 9b's Jira half:
  where the API credential lives, whether Jira-derived text may be
  persisted into the sync-bound task store).

Sequencing: fully scoped, part of the current PR (alongside `wb reconcile`
and `wb resume`/`wb pause`) — see `logs/decisions/2026-07-08-session-recap.md`.

## What shipped in v2 (board display v2)

Planned in `docs/plans/2026-07-12-001-feat-wb-board-display-plan.md` and
implemented in the same PR. Four additions on top of the v1 shape above,
all CSS-only (no JS added anywhere in this file):

- **Lifecycle stepper.** The old presence/absence badges are replaced by a
  five-stage stepper per task (Ideate · Brainstorm · Plan · Work · Review),
  each computed live to one of four states (n/a / pending / in-progress /
  done) from detection signals plus an optional `path:` frontmatter field
  declaring which stages a task intends to pass through — PR #20.
- **Pipeline tab.** One row per non-done task, window-independent —
  the one place a stale, long-untouched in-flight task is still visible
  even outside the today/week timeline.
- **Relationships.** `depends_on:` (comma-separated blocker stems) renders
  as a blocked/unblocks chip pair in both directions; existing `parent:`
  rollup gained a children-done counter and a ready-to-close hint.
- **Key Findings.** A board-wide, filter-immune section per tab: most-
  blocking task, parents ready to close, done-but-unreviewed count, oldest
  in-flight task, unclassified-status tasks, and branchless tasks whose
  stem already matches a doc on disk.

See `docs/wb-guide.md`'s board section for the human-facing walkthrough of
all of the above.
