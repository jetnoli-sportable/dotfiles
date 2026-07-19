---
title: wb reconcile — task-store/git drift detection
status: current
tile: Cross-reference the task store against real git state; report drift, never auto-apply.
group: design-notes
parent: roadmap
kind: page
updated: 2026-07-08
---

Scoped via a decision-buffer round on 2026-07-08
(`logs/decisions/2026-07-08-wb-reconcile-scoping.md`, gitignored scratch —
this page is the durable record of what got decided). This page is the
source; edit `docs/roadmap-wb-reconcile.md`, not the rendered `.html`.

**Roadmap:** new item, not from the original numbered list · **Status:**
scoped, ready to plan — not yet built

## The gap this closes

The task store (`~/code/tasks/*.md`) and actual git state (worktrees,
branches, merge status) can silently diverge in both directions — a
worktree gets created outside `wb new`, a branch gets merged and never
cleaned up, a task's worktree gets removed by hand outside `wb done`.
Nothing today detects this.

Not hypothetical: a first pass over `be--monorepo` alone found four
worktrees with no matching task file — `fix/sfb-1046-byid-gates` (untouched
over a month), `refactor/state-management` (last commit references an
already-merged PR, worktree just never got cleaned up), `fix/sfb-985-
pitch-map-regression` (real uncommitted work, completely invisible to `wb
board`), and `fix/sfb-988-af-sprints` (shares a commit with the already-
tracked `sfb-988` task — a likely duplicate branch for the same work).

## What v1 detects

Presence-diff (worktree/branch with no task file, or a task file whose
`worktree:` no longer exists on disk) plus a GitHub merged-status check per
candidate branch (via `gh`/`pgh`, same call pattern as
`pr-review-session`'s driver, `claude/.claude/skills/pr-review-session/driver.py:130`).
Same-commit duplicate flagging (the `fix/sfb-988-af-sprints`-style case) is
a later addition, kept report-only given how easily it can be wrong — two
branches can legitimately share a base commit before diverging.

**Hard rule:** `wb reconcile` never auto-applies a correction. It always
shows everything possibly diverged, including anything it's genuinely
unsure about — over-reporting (a false positive to dismiss) beats
under-reporting (real drift that never surfaces).

## The review flow

Not a `--apply` flag plus a live `git diff`. `wb reconcile` writes one
markdown review doc, one item per finding, with per-item options: do
nothing / remove / discuss / create a task (the expected common case — a
branch or worktree from real work that never got a task file) / **attach to
task** (attach an orphaned worktree to an existing task record) / **merge
with task** (two task records that turn out to be the same work). The last
two started as a single overloaded "combine" action in the initial scoping
pass, then got split during a follow-up `ce-brainstorm` validation
specifically so the destructive operation (merge) stays visually distinct
from the additive one (attach) — merging drops one task record's Plan/
Done/Follow-ups prose, attaching only edits one field. Closing the doc is
the answer — the exact same [[decision-buffer]] convention used everywhere
else in this workflow, applied here as a purpose-specific review buffer
rather than a bespoke UI.

Also decided in that same brainstorm pass: `wb reconcile` always writes to
one persistent file (no dated snapshots), warning before overwriting any
unaddressed prior review; a task created via "Create a task" seeds
`status: doing`, not the template default `planned`, since the work it
represents is already in progress by definition.

## Sequencing

Scoped, not yet planned or built. Pick up with `/ce-plan` when ready — the
decision-buffer doc above has the full option/tradeoff record for both the
detection scope and the review-flow shape.
