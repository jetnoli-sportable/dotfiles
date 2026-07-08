---
title: "/board — task-board visualization"
status: current
tile: The full zoomable board, deferred; the interim wb board is already live.
group: personal-workflow
kind: page
updated: 2026-07-08
---

Renamed from `/roadmap` (2026-07-07, Decision 5A) once "roadmap" collided
with this document's own name — "roadmap" now unambiguously means
`docs/roadmap.md`, the feature is `/board`. This page is the source; edit
`docs/roadmap-board.md`, not the rendered `.html`.

**Roadmap:** 9a (superseded — this page is the detail) · **Status:**
interim shipped (`wb board`), full feature deferred

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

Owner's call from the 2026-07-06 doc-review buffer: **constrain harder, and
defer**. Constraints locked in for whenever it's picked up:

- Renders a snapshot computed **from task-store frontmatter — the same
  single source `wb`'s done-flow writes** (one-board principle at the data
  layer).
- Zoomable *today / task `<slug>` / week*.
- Sourced from the store + parked ledger + decision docs + transcripts.
- **Jira integration is explicitly excluded** — it's its own later,
  separately-ratified addition (same open questions as 9b's Jira half:
  where the API credential lives, whether Jira-derived text may be
  persisted into the sync-bound task store).
- Output rides the HTML pipeline (docgen) — same convention as everything
  else in `docs/`.

Sequencing: after slice 5 (already shipped) — design discussion happens
when this is actually picked up, not before.
