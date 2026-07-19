---
title: Day bookends — wb up / wb down
status: current
tile: Startup and shutdown flows, and the "sessions are regenerative" principle.
group: design-notes
parent: roadmap
kind: page
updated: 2026-07-08
---

Two workflows composing the capture/recall pieces already built: `wb up`
(startup) and `wb down` (shutdown). This page is the source; edit
`docs/roadmap-day-bookends.md`, not the rendered `.html`.

**Roadmap:** 9b (superseded — this page is the detail) · **Status:** the
full `wb up`/`wb down` bulk flow is gated on slice 4b's session-id capture
landing; `wb resume <task>` (single-task slice, see below) is open and
unblocked

## The two workflows

**Startup (`wb up`)** — review yesterday's close-out + parked items + task
board, propose today's focus, recreate tmux sessions for the chosen tasks.

**Shutdown (`wb down`)** — sweep every live session, capture a quick status
into each task file, run the notes digest, then close all sessions cleanly
so the PC can power off.

## `wb up`'s task selection (Decision 10, 2026-07-07 review)

Reuses the decision-buffer checkbox convention already shared by `wb
done`'s close-out and the notes-digest promotion: `wb up` opens a review
buffer listing yesterday's close-out + parked items + task-board candidates
as `- [ ] pick` lines; closing the buffer recreates a session per checked
task. First-run fallback (no prior close-out to review yet): fall back to a
plain picker over the task store's `planned`/`doing` rows.

## `wb down`'s dirty-check (Decision 7, 2026-07-07 review)

`wb down` inherits `wb done`'s per-session dirty-check-and-abort exactly —
a dirty worktree aborts that session's wind-down by default, same as a
single `wb done`. Owner call: no silent skip-and-report bulk mode for now —
an override flag can be added later; its exact behavior (skip-dirty-and-
report vs. force vs. something else) is a decision for whenever that flag
actually gets built, not now.

## Jira exclusion

The Jira sprint pull originally listed in `wb up`'s scope is removed and
joins `/board`'s Jira exclusion as its own later, separately-ratified
addition — same open questions: where the API credential lives, and
whether Jira-derived text may be persisted into the sync-bound task store.

## Design principle: sessions are regenerative, not precious

Because a `wb` session is fully derived from its task record (repo,
worktree path, standard 3-window layout), resume = re-running a
`wb new`-equivalent from the store — no fragile tmux state snapshotting
needed. tmux-resurrect/continuum remain an optional complement for raw
scrollback, but the task store is the source of truth. Concretely: keep
everything `wb` creates reconstructable from the task file alone, and give
`wb` a `down --all` / `up --resume` pair.

> **The one genuinely precious piece of state:** each agent pane's Claude
> session id, recorded at spawn (a session/window option or a task-file
> field), so `up --resume` can `claude --resume <id>` instead of restarting
> every agent cold. The 3-window layout is cheap to rebuild; an in-flight
> agent conversation is not — and the id is cheap to capture now but
> impossible to recover for sessions already killed. This capture is
> landing as part of slice 4b's groundwork, ahead of `wb up`/`wb down`
> themselves.

## `wb resume <task>` — an early, ungated slice (2026-07-08)

The full `wb up`/`wb down` pair above stays gated on 4b's session-id
capture, needed for warm-restarting an agent mid-conversation. A
single-task resume needs none of that: `cmd_new`
(`scripts/.config/scripts/tmux/wb.sh:222-279`) is already idempotent — it
skips worktree creation when the worktree dir exists, no-ops task-seeding
when the task file exists, and always `tmux_ensure_session` + focuses
regardless of whether the session was already live. Task frontmatter
(`repo:`/`branch:`/`worktree:`) is already durable, on disk, in a git repo
— there is nothing new to "track" for this slice.

So `wb resume <task>` can ship now as a thin wrapper: fuzzy-match a task by
slug against the store, read its frontmatter, call the same worktree/session
logic `cmd_new` already runs. This is "stage 1" of the crash/reboot-recovery
need that motivated it — bring a specific task's environment back after a
shutdown or crash, by name, without retyping `<repo> <slug>`. `wb up` later
becomes "stage 2": run this same resume logic over every checked task in
the startup review buffer, plus the session-id warm-restart on top.

No tmux-resurrect/continuum is installed today (`tmux/.config/tmux/tmux.conf`
only lists `tpm`, `tmux-sensible`, `vim-tmux-navigator`, `catppuccin-tmux`)
— consistent with this doc's regenerative-sessions principle, this slice
doesn't need it either.
