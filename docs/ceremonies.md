---
title: Ceremonies — dated clocks and recurring reviews
status: current
tile: Check-in points, not automatic triggers. What each one is for, and what happens when it passes.
group: workflow
kind: page
updated: 2026-07-10
---

**Dated clocks** are check-in points, not tasks — "on this date, come back
and make a call," never "on this date, code runs automatically." Moved
here from `docs/roadmap.md` so this page has room to grow into future
recurring reviews beyond today's clocks.

## Active

### ~2026-07-13 — delete `tmux_pane_awaiting_input`

This is a version-pinned content-scan fallback for detecting "is this
tmux pane waiting on input" — a stopgap until the newer hook-based
attention pipeline (the workflow's Step zero) proved reliable. The action:
if the hook-based detection has held up without regressions by this date,
delete the old fallback scan; if it hasn't, keep it a while longer.

### ~2026-07-20 — combined calibration ceremony

Originally two separate check-ins, folded together by the 2026-07-10
calibration round (Decision 6):

- **Push-vs-weekly-ritual validation.** Compare whether proactive push
  notifications or batched weekly review (the `/parked-items` model)
  actually fits real usage better, to inform how similar future features
  get designed.
- **Skill/tool/command usage audit.** Monthly-ish audit of what's unused
  (prune candidates) and what's underused but already solves a current
  pain point (before building something new). The 2026-07-10 workflow
  review counts as run #1. Measurement source: agent-run review; output:
  dossiers under `~/code/tasks/dossiers/`.

### ~2026-07-24 — capture fix-forward experiment verdict

Successor to the 4a capture-window clock below, which resolved early and
unused. The fix-forward experiment (reach: tmux bind · read-back: passive
surface) wires in after the notes-dir audit; this date is when its actual
usage gets a verdict. Notes-tui integration 4b's original real-wiring plan
only proceeds if this experiment changes real usage; store convergence
(task store ↔ notes corpus) is tabled to the ~2026-07-20 combined
ceremony above.

## Resolved

### 4a capture-window verdict — resolved early, 2026-07-10 (unused)

Originally scheduled for ~2026-07-14: look at how notes-tui's capture
habit (4a, shipped) actually got used over the observation window, then
decide whether that usage justifies building 4b's real wiring, and in
what shape. **Outcome:** measured unused before the window even closed —
a 1-byte inbox — so 4b's original wiring plan is superseded by the capture
fix-forward experiment (see the ~2026-07-24 clock above) rather than
proceeding as originally scoped.
