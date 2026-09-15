---
title: weekly-review
status: current
tile: The weekly ceremony — evidence, review page, output record.
group: skills
kind: guide
updated: 2026-09-15
---

## Overview

Replaces the three dated clocks that lapsed for seven weeks in
`docs/ceremonies.md`, plus `/parked-items` (retired) and `/hindsight`.
Gathers four evidence sources in a fixed order — `wb reconcile`
drift, the [park](park.html) capture doc's unreviewed entries, tasks moved /
PRs merged since last review, and skill-usage counts — classifies each
capture entry (task idea / skill idea / grievance / workflow improvement),
and presents at most five candidate suggestions on the [review
page](review-page.html), never an nvim buffer. Emits one output record per
ISO week under `~/code/tasks/weeks/` with Retro and Sprint-planning rollups.

## Try it now

```
/weekly-review
```

Run it from the main dotfiles checkout (not a worktree — `wb week`/`wb
reconcile` are stowed there). The agent gathers evidence, classifies every
capture-doc entry, opens a review page for the task/skill-idea candidates,
then writes `~/code/tasks/weeks/<ISO>-review.md` once you close the page.

## Reference

| Evidence step | Source |
|---|---|
| 1. Reconcile | `wb reconcile --machine` — task-store/git drift |
| 2. Capture doc | `wb week record` — rolls up every unreviewed entry, marks it reviewed |
| 3. Moved/merged | Last record's seeded tasks, checked against `status: done` / merged PRs |
| 4. Skill usage | `scripts/.config/scripts/skill-usage.sh` — reproducible counts, stated blind spots |

| Classification | Routes to |
|---|---|
| Task idea | Sprint planning (candidate suggestion) |
| Skill idea | Sprint planning (candidate suggestion) |
| Grievance | Retro |
| Workflow improvement | Retro, and Sprint planning if it implies a concrete change |

Accepted suggestions are seeded via `wb new --prospective`/`--planned` then
tagged `wb set <task> tags weekly-review` — two locked-verb calls, `wb new`
has no `--tags` flag.

## Known rough edges

- The ceremony is manually invoked — no calendar/hook trigger — until a few
  real runs prove it earns its keep (see the plan's own Risks section and
  its dated week-3 re-evaluation task).
- Classification at capture time (in `/park`) and at review time (here) are
  both one-line judgement calls, not infallible — correct them inline when
  wrong.
- Skill-usage counts can't see a skill invoked by natural-language
  description alone — a zero there means "not detected," never "unused."

## Next steps / reverting

- The capture doc is a plain standing file at `~/code/tasks/weeks/capture.md`
  (`wb week path` to print it) — read it, edit an entry, or move something
  out any time, not just during a review.
- Every output record lives under `~/code/tasks/weeks/` — plain markdown,
  one file per ISO week. Skill source:
  `claude/.claude/skills/weekly-review/SKILL.md`.
