---
title: Recap — wb-breakdown (split an oversized task into a family)
status: current
tile: A human-approved proposal buffer plus a locked multi-file apply — turning one oversized task or Jira ticket into a session-sized parent/child family.
group: personal-workflow
kind: page
updated: 2026-07-13
---

`~/code/tasks` accumulates tasks that are really epics: one `.md` whose
`## Plan` holds a week of work. A single session chews on a file like that
for days, handoff entries pile up, and the board shows one opaque card.
The parent/child mechanism (PR #17) gave the store family semantics —
`parent:` frontmatter, picker sibling grouping, a board rollup card — but
nothing *produced* a family except hand-editing frontmatter. Separately,
work arrives as Jira tickets, and turning a ticket into a scoped task was
entirely manual. wb-breakdown builds the missing piece: a skill that
proposes the split, and a locked `wb.sh` verb that actually writes it.

## What got built

A `/wb-breakdown` skill (`claude/.claude/skills/wb-breakdown/SKILL.md`)
climbs the richest available evidence — a ticket's own subtasks, a linked
`ce-plan` doc's implementation units, a substantive `## Plan` (a named,
shared "substantive-plan test" — ≥3 actionable items or ≥10 non-blank
content lines), or a fresh agent pass when none of those exist — and
authors a reconcile-style proposal buffer the human checks and edits
before anything is written. `wb breakdown --apply` (`wb.sh`) is the other
half: it validates the closed buffer twice (once to determine the exact
set of files to lock, once more after acquiring every lock — never
trusting the buffer snapshot), then executes the family write as one
sorted, all-or-nothing multi-file transaction — seed the checked children,
rewrite the parent's `## Plan`, move follow-up bullets to the child they
belong to, migrate the continuing child's branch/worktree/session away
from the parent, archive the closed buffer under
`~/code/tasks/dossiers/<parent-stem>/`, and append one handoff entry
naming it.

The apply is idempotent by construction — an existing child whose
`parent:` already matches is "already created, skipping," an
already-blanked parent skips migration — so a crash or a contended lock
mid-run (exit 75, zero writes) never leaves the store in a state a re-run
can't finish cleanly. Every verb that resolves "my task file" from a live
tmux session (`wb done`/`wb pause`/`wb reviewed`, the picker's live-session
row) now checks the session's `@task` option first, since a migrated
continuing session's `@wb_repo`/`@wb_slug` deliberately stay pointed at
its own real git identity while `@task` gets re-aimed at the new child —
without that change, closing the "same" session post-split would have
silently acted on the parent instead. `wb done` also gained a store-only
close path (a stem argument matching no live session resolves as a
task-file stem instead) and a last-child nudge: closing the final open
child of a family prints `wb done <parent>` as the exact command to close
the parent, too.

## Why this needed the concurrency-safety work first

`wb breakdown --apply` is the store's first true multi-file writer — every
existing verb before this touched at most two files (a reconcile merge).
It's built directly on `wb-locks.sh`'s per-task-file `flock` side-cars and
the sorted-path multi-lock precedent `wb_reconcile_action_merge` already
established, both from the `TASKS_DIR` concurrency-safety work
([recap](2026-07-12-tasks-dir-concurrency-safety-recap.html)). That work's
own PR hadn't landed in `development` yet when this one was built, so this
branch merged its commits in directly to build and test against the real
primitives rather than a guessed API — both PRs land in dependency order.

## Where to go next

The roadmap row is
[detail-wb-breakdown](roadmap.html#detail-wb-breakdown). The store schema
gained `jira:` (a task's full ticket URL) and the `breakdown-candidate`
tag convention — see `~/code/tasks/README.md`. Deferred follow-ups: the
Jira-watch loop that would auto-tag candidates, family-aware count
rollups in the picker/board, and un-breakdown (merging a family back into
one task) — none of them block using the feature as built.
