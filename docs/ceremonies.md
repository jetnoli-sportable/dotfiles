---
title: Ceremonies — dated clocks and recurring reviews
status: current
tile: Check-in points, not automatic triggers. What each one is for, and what happens when it passes.
group: workflow
kind: page
updated: 2026-09-22
---

**Dated clocks** are check-in points, not tasks — "on this date, come back
and make a call," never "on this date, code runs automatically." Moved
here from `docs/roadmap.md` so this page has room to grow into future
recurring reviews beyond today's clocks.

**2026-09-14 note:** all three clocks below sat unresolved for ~7-8 weeks
past their dates — the failure mode this page itself warns against, since a
date in a doc has no trigger. Resolved as part of scoping
`dotfiles--workflow-strategy-and-ceremonies`. The weekly review (see
`## Recurring` below, shipped 2026-09-15) replaces bare dated clocks as the
mechanism going forward.

## Recurring

### Weekly workflow review — `/weekly-review`

Replaces this page's original "combined calibration ceremony" clock, plus
the retired `/parked-items`. Shipped in #55–#58 and first run for 2026-W38.
Full usage is in the [weekly-review guide](guides/weekly-review.html).

- **Capture, all week:** [`/park <note>`](guides/park.html) appends to the
  standing capture doc (`~/code/tasks/weeks/capture.md`, which
  <kbd>prefix</kbd>+<kbd>N</kbd> opens). Work-shaped items get proposed as
  `prospective` tasks instead.
- **Review, weekly:** `/weekly-review`, run from the main dotfiles
  checkout. It gathers four kinds of evidence in a fixed order: `wb
  reconcile` drift, unreviewed capture entries, tasks moved and PRs merged
  since the last record, and skill-usage counts. It sorts each capture
  entry into one of four kinds (task idea, skill idea, grievance, workflow
  improvement) and shows at most five suggestions on the review page. It
  then writes `~/code/tasks/weeks/<ISO>-review.md`. Accepted suggestions
  become `planned` tasks tagged `weekly-review`.
- **Trigger:** manual, on purpose. There is no calendar or hook nudge. The
  only prompt is the "unreviewed capture entries (Nd since last review)"
  count in the picker status line and at the end of `wb done`. It stays
  manual until a few real runs show it's worth keeping. If the suggestions
  keep coming up empty, rethink the ceremony rather than automating it.

### Fortnightly Retro and Sprint planning — fed by the weekly review

Retro and Sprint planning are real meetings, held every two weeks. They
are not agent ceremonies, and nothing here schedules them. The weekly
review's job is to make sure both meetings start from captured evidence
rather than memory. Each week's record has one section for each meeting:

| Captured as | Feeds | Lands in the week record as |
|---|---|---|
| Grievance / friction | **Retro** | One line under `## Retro`, plus any "what's working" item settled that round |
| Workflow improvement | **Retro**, plus **Sprint planning** if it implies a concrete change | Under `## Retro`, plus a planning row when it's actionable |
| Task idea / skill idea / deferred work | **Sprint planning** | Under `## Sprint planning`: what was seeded (task ref), what was dropped (and why), what an existing task already covered |

To prepare for either meeting, read the last two `weeks/*-review.md`
records. Their `## Retro` or `## Sprint planning` sections are the agenda.

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
