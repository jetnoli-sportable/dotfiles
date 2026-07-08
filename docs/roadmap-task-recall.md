---
title: Task recall — resume any work from any session
status: current
tile: Reference a task from anywhere and get a recap + resume options.
group: personal-workflow
kind: page
updated: 2026-07-08
---

Tie the memories, skills, task store, and Hub together so that referencing
a task or piece of work in ANY session makes the agent check for context
and offer to resume it. This page is the source; edit
`docs/roadmap-task-recall.md`, not the rendered `.html`.

**Roadmap:** 9e (superseded — this page is the detail) · **Status:** open,
unblocked (only depended on slice 5, which shipped)

## The ask, verbatim

Referencing a task or piece of work in any session — e.g. "let's continue
planning the reporting investigation" — should make the agent check the
Hub/task store for context and offer to **resume, update, or recap** that
work, rather than starting from scratch or asking the user to re-explain.

## Building blocks that already exist

- The central task store (per-task record, `~/code/tasks/*.md`).
- `wb board` (status view over the same store).
- The worktree-seeding rule in `~/.claude/CLAUDE.md` — already does this
  for worktree *setup* specifically (checks `~/code/tasks/` for an existing
  task file matching the target repo/slug before starting fresh).
- Slice 5's INDEX + `/help` Q&A — the lookup machinery this would reuse.
- `MEMORY.md`.

## The likely shape

Generalize the worktree-seeding rule into a standing "task-recall"
behavior: on a task reference, match against `~/code/tasks/*.md`
(title/slug/tags), read the record plus its linked decisions/dossiers, and
open with a recap + resume options — not just at worktree-setup time, but
any time a task gets referenced in conversation.

Sequencing: unblocked now (only needed slice 5's INDEX/lookup machinery,
which shipped). Design goes through a decision buffer when actually picked
up — the exact matching heuristic (fuzzy title match? tag-based? both?) and
how aggressively to auto-trigger vs. wait for an explicit ask are real
open questions.

## Boundary note

Recall output must respect the same personal/employer boundary rules as
every other aggregation surface in this system (§10/Decision 4) — a task
recall triggered in a personal-repo session must never surface or
cross-reference employer-repo (Sportable) task records.
