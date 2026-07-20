---
title: wb-resume
status: current
tile: Pick a task back up after /clear — reads the last /wb-save snapshot and acts on it.
group: skills
kind: guide
updated: 2026-07-14
---

## Overview

The second half of the `/wb-save` → manual `/clear` → `/wb-resume` pair.
Where `/wb-save` writes a rich done/in-flight/next snapshot into the task
file's `## Handoffs` section right before the human clears context by
hand, `/wb-resume` runs in the freshly cleared session and reads that
snapshot back — then **acts** on the recorded next step, the same way a
freshly spawned `/handoff` agent acts on its injected pointer rather than
just acknowledging it. Read-only: it never writes to the task file
itself, and it's not the `wb resume <task>` shell command (see Known
rough edges) — this is conversation-level context re-read, not
worktree/session recreation.

## Try it now

Right after a manual `/clear` that followed a `/wb-save`:

```
/wb-resume
```

The agent states what it found in one line, then continues directly:

```
Read the wb-save entry from 2026-07-14 13:20: done — U3 landed, in
flight — U4. Continuing into: fix roadmap-wb-reconcile.md's status line.
```

If a `wb pause`/`wb done`/`wb resume` cycle happened after the last save,
it states the recorded plan **and** the gap, then asks before proceeding
rather than assuming the old plan still holds.

## Reference

| Situation | Behavior |
|---|---|
| Recent `/wb-save` entry, nothing after it | States what was read, proceeds straight into the recorded **Next** action |
| A terse automatic entry (`wb pause`/`wb done`/`wb resume`) landed after the last `/wb-save` entry | States the recorded next action and the gap, asks to confirm or redirect before acting |
| No terse entry after the save, but `## Plan`/`## Decisions`/frontmatter `status:` reads as newer | Treated the same as the gap case above — confirm before acting |
| `## Handoffs` has only automatic entries, no `/wb-save` entry yet | Says so explicitly, falls back to `## Plan` for context |
| No `## Handoffs` section at all | Says so explicitly, falls back to reading the whole task file |
| No `@task` set on this session | Stops: `wb-resume: <session> has no @task — not a wb task session` |
| `@task` set but the file doesn't exist on disk | Stops: `wb-resume: no task file at <task_file> (from this session's @task) — it may have been moved or deleted` |

## Known rough edges

- **Single current session only.** Operates on whichever task this tmux
  session is already bound to via `@task` — no repo/slug argument, no
  searching across other sessions.
- **Naming collision with `wb resume <task>`, deliberate.** `wb.sh`'s
  `cmd_resume` (`wb.sh:352-390`) is a different, infra-level mechanism
  that recreates a torn-down worktree/tmux session from its task file.
  `/wb-resume` never shells out to it — if the worktree/session
  themselves are gone, run `wb resume <task>` first to get a live
  session back, then `/wb-resume` applies once you're in it.
- **Doesn't detect drift with certainty.** The gap check catches
  automatic `wb pause`/`wb done`/`wb resume` entries and an eyeballed
  read of `## Plan`/`## Decisions`/status — it isn't a diff against every
  possible out-of-band edit.

## Next steps / reverting

- Pairs with [`/wb-save`](wb-save.html) — save before clearing, resume
  after. Neither skill invokes `/clear` itself; that stays a manual step.
- If `/wb-resume` ever picks the wrong context back up, the task file's
  `## Handoffs` section is a plain markdown log — read it yourself
  (`nvim` the task file) instead of trusting the skill's summary.
