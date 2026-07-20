---
title: /handoff — route a discussion to the right worker
status: current
tile: Route something being discussed right now to a live session or a fresh one, without retyping context by hand.
group: workflow
kind: guide
updated: 2026-07-14
---

`/handoff` takes something being discussed in the current conversation and
routes it to the worker that should own it — an already-live tmux session
(switch + clipboard) or a freshly spawned one (`wb new --agent` + inject).
Single-target only: one repo/slug per invocation.

## Try it

Mid-conversation, once a clearly-standalone piece of work has come up:

```
/handoff
```

The skill infers `repo`/`slug` from context (checking `~/code/tasks/` for a
task that already represents this, same lookup the worktree-seeding rule
already uses), seeds or updates that task file, then hands off to
`scripts/.config/scripts/tmux/handoff.sh <repo> <slug>` — no flags to pass,
no path to type by hand.

What happens next depends on whether that repo/slug already has a live
session:

- **Live session exists** → switches you into it and puts a short pointer
  on the clipboard (`wl-copy`), naming the task file. Paste it in whenever
  you're ready.
- **No live session** → `wb new --agent` spawns one, `handoff.sh` polls for
  the boot-ready screen, injects the pointer, then polls for and clears the
  one-time `~/code/tasks/` read-permission prompt automatically. You land
  on a session that's already read its task file and started working.

## The first action lives in the task file, not a flag

Unlike a typical CLI tool, `handoff.sh` takes no `--first-action` flag.
`/handoff` writes a line directly into the target task file's body,
immediately under its title — the exact convention this task file itself
used to bootstrap its own `/ce-plan` pass:

```
**First action when picked up:** `/ce-plan` from this file.
```

Defaults to `/ce-plan`; the skill only picks something else (e.g.
`/ce-work`) when the work is already fully scoped, and always says which
it chose and why. This isn't just a style choice — it also means the
pointer `handoff.sh` injects is a single fixed string with nothing
runtime-variable in it, which is what makes the boot-ready/permission-
prompt anchors safe to match against (see `docs/roadmap-handoff.md`'s
dry-run findings for the mechanical reasoning).

## What v1 doesn't do

- **Fan-out.** One discussion → several linked tasks depends on the task
  parent/child relationship — already shipped (PR #17), not just designed.
  The gap is that `/handoff` itself isn't wired to loop over it yet.
  `/handoff` routes the single most relevant target and says so.
- **Instructing an already-busy live agent directly.** The switch path is
  clipboard-only — you paste the pointer in yourself when the agent is
  ready for it, rather than `/handoff` injecting into a pane that might be
  mid-turn on something else.
- **Non-blocking invocation.** Running independently of the current
  turn — not blocking on it, not affecting its response — is a real,
  different idea raised while planning v1, deliberately parked until v1
  has seen real usage (`docs/roadmap-handoff.md` "Follow-on idea").
- **Self-handoff between stages.** Clearing your own context mid-task
  (e.g. after `/ce-plan` finishes, before `/ce-work` starts) is a
  different mechanic entirely — same session, not a different one — and
  its own not-yet-planned follow-up (`docs/roadmap-handoff.md`
  "Follow-on idea: self-handoff between stages").

Full mechanical rationale — the anchor sets, the permission handshake, why
`wb.sh` is never touched, all three dry-run findings — lives in
[`roadmap-handoff.md`](roadmap-handoff.html), not repeated here.
