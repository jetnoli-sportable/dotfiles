---
title: Open Questions — deferred decisions from the 2026-07-07 doc review
status: current
tile: Five things deliberately left unresolved. Revisit triggers noted per item.
group: personal-workflow
kind: page
updated: 2026-07-08
---

Findings from the 7-persona review in
`logs/decisions/2026-07-07-roadmap-review-findings.md` that the owner
checked **Defer** on. Kept here, not resolved, so they resurface rather
than silently drop. This page is the source; edit
`docs/roadmap-open-questions.md`, not the rendered `.html`.

**Roadmap:** §11 (superseded — this page is the detail)

## GPaste's GNOME Shell dependency vs. the Sway direction

9g's GPaste config is GNOME-Shell-specific; the owner's WM direction is
Sway, at a later unscheduled date (see the WM pointer note in the [9g
recap](9g-gpaste-recap.html)). Revisit 9g's mechanism when the Sway
migration is actually scheduled — GPaste's extension model has no Sway
equivalent, so this isn't a config tweak, it's a re-pick of the whole tool.

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

## Credential guard is warn-only, not a hard block

The [`wb` design page](roadmap-wb-design.html)'s guard is a dismissible
warning in the close-out review buffer, not an enforced block, and has no
content-based fallback (doesn't scan file *contents* for secret-shaped
strings, only filenames). Acceptable while the task store stays local-only
and single-user; revisit if the store ever gets a remote (same trigger as
the personal/employer boundary rule below) or if a credential-shaped
filename ever slips past the denylist.

## GPaste's persistent clipboard history has no secrets policy

Clipboard history persists to disk indefinitely (`save-history true`) with
no expiry or secret-detection — copying a token or password puts it in the
history store with no automatic cleanup. Shipped as-is for a personal
single-user machine; revisit if it turns out to be a real problem in
practice (e.g. add a max-age prune or a "don't persist this clip" gesture).

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
