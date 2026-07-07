---
title: parked-items
status: current
tile: Weekly review of everything parked, as an nvim checklist.
group: skills
kind: guide
updated: 2026-07-07
---

## Overview

The forcing function that makes [park](park.html) worth anything: gathers
the `/park` ledger plus a transcript backstop (things you *said* to revisit
but never parked), reconciles against the central task store
(`~/code/tasks`), and presents one nvim checklist of genuinely-open items.
You check an action per item; the agent executes them when you close the
buffer.

## Try it now

```
/parked-items --backfill    # first ever run: full-history baseline (noisy, expected)
/parked-items               # the weekly cadence: last 7 days
```

The buffer opens in a tmux split. For each item: keep the pre-checked
recommendation or move the `[x]`, add notes inline, save, close. The agent
then creates tasks / discusses / drops as instructed and summarizes.

## Reference

| Checkbox | What happens |
|---|---|
| Make a scratch task | Task file in `~/code/tasks/<repo>--<slug>.md` (central store schema), routed by the item's captured cwd |
| Make a Jira ticket | Only when explicitly checked; agent confirms project/summary first |
| Discuss now | Raised in chat that same turn |
| Keep parked | Stays `open`, resurfaces next week |
| Drop | Ledger line rewritten `status:"dropped"` — audit trail kept, never re-raised |

Flags: `--since=14d` widens the window; `--backfill` scans all history.
Sources in priority order: ledger → transcript scan → task-store
reconciliation (already-actioned items drop off automatically).

## Known rough edges

- The transcript backstop is phrase-matching — the first `--backfill` run
  surfaces false positives by design; Drop them once and they stay dropped.
- Needs local transcripts (`~/.claude/projects/`) — a cloud/headless run
  can't do the backstop half, which is why this stays a local ritual.
- `wb done` nudges you ("N follow-ups pending · M parked") when you fall
  behind; the picker status line carries the same count.

## Next steps / reverting

- Once the weekly output has earned trust, ask to `/schedule` it (e.g.
  Monday 09:00, local) — deliberately not set up by default.
- Everything is plain files: the ledger, the review buffers
  (`~/.claude/parked-items/review-*.md`), the task store. Skill source:
  `claude/.claude/skills/parked-items/SKILL.md`.
