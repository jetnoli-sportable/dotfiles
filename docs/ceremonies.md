---
title: Ceremonies — dated clocks and recurring reviews
status: current
tile: Check-in points, not automatic triggers. What each one is for, and what happens when it passes.
group: workflow
kind: page
updated: 2026-09-14
---

**Dated clocks** are check-in points, not tasks — "on this date, come back
and make a call," never "on this date, code runs automatically." Moved
here from `docs/roadmap.md` so this page has room to grow into future
recurring reviews beyond today's clocks.

**2026-09-14 note:** all three clocks below sat unresolved for ~7-8 weeks
past their dates — the failure mode this page itself warns against, since a
date in a doc has no trigger. Resolved as part of scoping
`dotfiles--workflow-strategy-and-ceremonies`; a weekly ceremony (see
`## Recurring` below, once built) replaces bare dated clocks as the
mechanism going forward.

## Recurring

### Weekly workflow review — not yet built

Replaces this page's original "combined calibration ceremony" clock.
Starts as a manually-invoked skill (not hooked to `wb up`, not calendar-
nagged) — force it into the workflow incrementally once it's proven useful,
rather than over-building the trigger up front. Gathers the week's
evidence (transcript grep for skill usage, tasks-repo git log, `/park`
ledger, merged PRs) and reviews it in a findings-review buffer: what
worked, what didn't, one increment to the workflow or skills. First run's
agenda includes triaging the task store's "doing" backlog. Scoped in
`dotfiles--workflow-strategy-and-ceremonies`; not yet built.

## Resolved

### ~2026-07-13 — delete `tmux_pane_awaiting_input` — resolved 2026-09-14 (KEEP)

Was scoped as a stopgap content-scan fallback for "is this tmux pane
waiting on input," to be deleted once the newer hook-based attention
pipeline proved reliable. **Outcome: keep it, not delete.** The premise
was wrong — the hook pipeline (`@claude_blocked`/`@claude_working`) didn't
make the content scan obsolete, it complements it. `lib.sh`'s
`tmux_claude_panes` deliberately falls back to `tmux_pane_awaiting_input`
for any `✳`-glyph pane with no hook marker set (an older Claude Code build,
or `claude` launched outside wb's hook-managed settings) — still actively
tested (`tests/lib-claude-panes.test.sh`'s "modal-scan fallback still
outranks @claude_working" case) and touched as recently as PR #38/#41.
Deleting it would silently break needs-input detection for any unmarked
pane.

### ~2026-07-20 — combined calibration ceremony — resolved 2026-09-14 (absorbed)

Originally two separate check-ins, folded together by the 2026-07-10
calibration round (Decision 6): push-vs-weekly-ritual validation, and a
monthly-ish skill/tool/command usage audit (run #1: 2026-07-10, never
re-run). **Outcome:** absorbed into the weekly workflow review above — it
*is* this ceremony now, not a separately-tracked clock. The
push-vs-weekly-ritual question is answered implicitly by that choice
(weekly ritual, not push).

### ~2026-07-24 — capture fix-forward experiment verdict — resolved 2026-09-14 (unused)

Successor to the 4a capture-window clock below. Whether the fix-forward
experiment (tmux-bind capture, passive read-back) changed real notes-tui
usage, gating whether 4b's original real-wiring plan proceeds. **Outcome:
unused, no contrary evidence found** — 4b's original wiring plan does not
proceed, consistent with the 4a verdict below.

### 4a capture-window verdict — resolved early, 2026-07-10 (unused)

Originally scheduled for ~2026-07-14: look at how notes-tui's capture
habit (4a, shipped) actually got used over the observation window, then
decide whether that usage justifies building 4b's real wiring, and in
what shape. **Outcome:** measured unused before the window even closed —
a 1-byte inbox — so 4b's original wiring plan is superseded by the capture
fix-forward experiment (see the ~2026-07-24 clock above) rather than
proceeding as originally scoped.
