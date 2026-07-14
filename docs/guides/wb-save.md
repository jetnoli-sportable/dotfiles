---
title: wb-save
status: current
tile: Write a structured done/in-flight/next snapshot before a manual /clear.
group: skills
kind: guide
updated: 2026-07-14
---

## Overview

The "save" half of a human-in-the-loop context-reset pair —
[`/wb-resume`](wb-resume.html) is the other half. It exists because an
agent autonomously clearing its own context was tried and hard-blocked:
Claude Code's auto-mode classifier denied an earlier dry-run's attempt to
`tmux send-keys` `/clear` into its own pane, as "an agent self-driving
its own pane to alter its own session/oversight state." `/wb-save`
writes the state that needs to survive the clear; the human runs
`/clear` themselves.

## Try it now

Right before you're about to `/clear`:

```
/wb-save
```

or any of: "save my progress", "checkpoint this", "save state before I
clear". The agent composes done/in-flight/next from the actual
conversation, appends it to the task file's `## Handoffs` section, and
confirms in one line:

```
Saved to ## Handoffs — /clear when you're ready.
```

## Reference

| Step | What happens |
|---|---|
| Locate the task file | Reads `@task` off the current tmux session (`tmux show -t "=$session:" -v @task`) — never cwd/branch inference |
| Compose the entry | **Done** / **In flight** / **Next**, drawn from what actually happened this session — a genuinely empty field is stated plainly (`**Done:** nothing yet this session`), never invented |
| Append | Shells out to `wb append <task_file> Handoffs` (the locked, heading-scoped append verb) with the three-field block over stdin — never an Edit/Write-tool edit to a task file |
| Entry shape | `### <YYYY-MM-DD HH:MM> — wb-save` heading (no `(auto)` suffix — that's reserved for `wb.sh`'s own mechanical `pause`/`done`/`resume` entries), then `**Done:**`/`**In flight:**`/`**Next:**` |
| No `@task` set | Stops before touching any file: `wb-save: this session has no @task — not a wb task session.` |
| `@task` set but file missing | Stops: `wb-save: no task file at <path> — recorded in this session's @task, but missing on disk.` |

## Known rough edges

- **Append-only, on purpose.** Never touches any existing content —
  prior `## Handoffs` entries, `## Plan`, `## Decisions` — so it can't be
  used to correct or edit something already recorded; that's a manual
  task-file edit instead.
- **Never invokes `/clear` itself, never touches tmux state** beyond the
  one read-only `@task` lookup. This is a closed design boundary, not a
  gap — see Overview.
- **Shared log.** `## Handoffs` also receives `wb.sh`'s own automatic
  `pause`/`done`/`resume` entries. Seeing a terse automatic entry
  interleaved with a rich `/wb-save` one is expected, not a bug.

## Next steps / reverting

- Pairs with [`/wb-resume`](wb-resume.html), which reads this same
  `## Handoffs` section back on the other side of a `/clear`.
- Nothing to revert or unwire — skipping `/wb-save` just means
  `/wb-resume` (or a human) falls back to reading `## Plan` cold instead
  of a written snapshot.
