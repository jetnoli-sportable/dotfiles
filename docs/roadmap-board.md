---
title: "/board — task-board visualization"
status: current
tile: Status+timeline filters over the task store, fully scoped; the interim wb board is live now.
group: personal-workflow
kind: page
updated: 2026-07-08
---

Renamed from `/roadmap` (2026-07-07, Decision 5A) once "roadmap" collided
with this document's own name — "roadmap" now unambiguously means
`docs/roadmap.md`, the feature is `/board`. This page is the source; edit
`docs/roadmap-board.md`, not the rendered `.html`.

**Roadmap:** 9a (superseded — this page is the detail) · **Status:**
interim shipped (`wb board`); full feature fully scoped, ready to
implement

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
