---
title: Open Questions — deferred decisions from the 2026-07-07 doc review
status: current
tile: Deliberately unresolved decisions and process record. Standing limitations moved to their own page.
group: roadmap
kind: page
updated: 2026-07-10
---

Findings from the 7-persona review in
`logs/decisions/2026-07-07-roadmap-review-findings.md` that the owner
checked **Defer** on. Kept here, not resolved, so they resurface rather
than silently drop. This page is the source; edit
`docs/roadmap-open-questions.md`, not the rendered `.html`.

**Roadmap:** §11 (superseded — this page is the detail)

> **2026-07-10 — three entries promoted.** GPaste's Sway coupling, the
> warn-only credential guard, and GPaste's no-expiry clipboard history were
> standing, by-design constraints rather than open decisions — they moved
> to [Limitations](limitations.html), each keeping its own revisit trigger.
> What's left here is genuinely still open, or process record.

## Notes corpus shape

Resolved for now, re-confirmed 2026-07-07: **keep `~/code/tasks` and
`~/code/notes` as separate repos** — this re-confirms the standing call
already parked in `~/code/tasks/tasks--task-note-convergence.md`
(2026-07-06), which explicitly deferred merging until `wb` + notes-tui's
`--context` flag both have real usage behind them (4a/4b). Capture-anywhere
and end-of-day-aggregation are already live today via `note`/`notes
digest` (slice 4a) — no new plumbing needed for those two asks
specifically. Cross-querying `wb` + personal notes stays [task recall's](roadmap-task-recall.html)
job, not a directory merge. **Standing instruction:** flag it again if the
split ever becomes a real hindrance rather than a theoretical one, so it
goes through a proper decision instead of drifting. "Where documentation
lives" stays explicitly open, not addressed by this resolution.

## "(F4)" in the task template

Traced via grep sweep (owner ask, 2026-07-07): `F4` was finding-ID
shorthand from the now-retired `agent-workbench-findings.html` — "Task
history is reviewable" (the gap it named: task discussion/decisions
scattered across three stores with nothing assembling a per-task dossier).
The task template's `## Decisions` section exists specifically to satisfy
this. Now explained inline in `roadmap.md`'s Origins note instead of
pointing at a deleted file — **this question is resolved**, kept here for
the record of how it was traced.

## Personal/employer boundary rule (the FINAL follow-up)

Deliberately not "deferred" in the same sense as the others above — this
one is the intentional last item. The personal/employer boundary rule for
the task store and all aggregation surfaces (classification convention vs.
split stores vs. permanent local-only) is deliberately the **final**
follow-up decision, to be made after every other follow-up in this whole
push, once the full flow is in place. Interim guardrails until then: the
task store gets no remote; slice 5's INDEX/HTML outputs carry a minimal
work-reference redaction guard; the credential guard and the cross-repo
doc-registry boundary axis stand as written.
