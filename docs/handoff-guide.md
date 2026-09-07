---
title: /handoff & /handoff-pane — route a discussion to the right worker
status: current
tile: Route something being discussed right now to a live session, a fresh one, or a helper agent in this very window — without retyping context by hand.
group: workflow
kind: guide
updated: 2026-07-19
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

## Pane mode — a second agent in *this* window (`/handoff-pane`)

Sometimes you don't want to route work *elsewhere* — you want a second agent
right here, in the worktree you're already in, looking at changes you
**haven't committed yet**. That's `/handoff-pane`: it splits a new pane in the
current tmux window and boots a `claude` there with its cwd set to this
session's worktree, so both agents share one working tree. Neither `/handoff`
mode can do this — a fresh `wb new --agent` worktree is a clean checkout that
can't see your uncommitted changes, and switching to a live session abandons
your pane and points at a *different* worktree.

The script side is `handoff.sh --pane [--await-perm] <payload>` — the same file
as `/handoff`, one new mode reusing its boot poller, injector, and permission
handshake in place. The split is horizontal (side-by-side) by default; flip it
to a stacked split for one call with `HANDOFF_PANE_SPLIT=-v`. The skill
`/handoff-pane` owns the judgment below; the script is entirely mechanical.

### Two bindings

- **Ephemeral (default).** No task file, no store entry — the payload is a
  short one-line prompt. Use it for a throwaway: review this worktree, a quick
  spike, a second pair of eyes. Nothing to clean up afterwards, and no lock to
  contend with the parent over.
- **Child task.** A planned child task created via
  `wb new --planned --parent <parent-stem> <repo> <slug>`, seeded with
  `parent:` set and a **blank `worktree:`** — so the child owns no worktree of
  its own and its eventual `wb done` closes store-only, never removing the
  parent's worktree. Use it when you want a durable, board-visible record. Only
  available when the current session has a resolvable `@task` (otherwise
  `/handoff-pane` falls back to ephemeral and says so).

### Two postures — always stated, never silent

Both agents share one worktree with **no lock** over its files, so the helper's
posture toward it is chosen per call and stated out loud:

- **Report-only (default-safe).** The helper inspects and reports, makes no
  edits — e.g. `/ce-code-review mode:agent`. Safe to run while you keep working
  in the parent.
- **Apply-fixes.** The helper edits the shared worktree. ⚠️ Because there is
  **no lock**, if the parent is not actually idle, concurrent edits to the same
  file **silently overwrite each other's uncommitted work, with no git recovery
  path**. Only choose this when you **pause the parent** for the duration —
  that pause is the interim safety until the cross-cutting "check for
  uncommitted work before acting" convention exists (a separate initiative, not
  this feature). The posture lives in the helper's prompt; the script never
  inspects or enforces it.

### Lifecycle — the footguns (documented, not enforced yet)

`wb done` was written before pane mode existed and **never enumerates panes**,
so a live helper pane in a shared worktree is invisible to it. Until pane-aware
`wb done` lands (a deferred follow-up — see
[`roadmap-handoff.md`](roadmap-handoff.html)), mind these by hand:

- **`wb done --close` kills the whole session — the helper pane with it.**
  Close the helper pane before winding the parent down with `--close`.
- **`wb done`'s `git worktree remove --force` can delete the shared worktree
  out from under a live helper**, pulling its cwd away mid-thought.
- **Uncommitted helper changes make `wb done` refuse** (the dirty guard) — a
  feature, not a bug: commit or discard the helper's work first.
- **A child helper shares this session's `@task`.** `@task` is session-scoped,
  so a `/wb-save` run *from the helper pane* resolves to the **parent's** task
  file, not the child's. The helper reads its own file via the injected pointer
  (unaffected); just don't lean on `/wb-save` from a child helper until
  pane-scoped `@task` resolution exists (another deferred follow-up).

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
