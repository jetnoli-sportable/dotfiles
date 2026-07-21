---
name: handoff-pane
description: Route a piece of the current discussion to a second `claude` agent in a split pane of THIS tmux window, sharing this session's worktree — so the helper can see and act on uncommitted changes the requester hasn't committed yet. Use when the user types `/handoff-pane`, says "spin up a helper here", "get a second agent to review these uncommitted changes", "split off a reviewer in this window", or asks for another agent in the current worktree (not a fresh worktree, not a different live session). Single-target only. For routing to a different repo/slug (a fresh or already-live session), use `/handoff` instead.
---

# Handoff pane

`/handoff-pane` puts a **second `claude` agent in a split pane of the current
tmux window, sharing this session's worktree**. It is the mode you reach for
when you want another agent to look at the work in the worktree you're *already
in* — most concretely, to code-review changes you **haven't committed yet** and
either report or fix them. Neither `/handoff` mode can do this: a fresh
`wb new --agent` worktree is a clean checkout that physically cannot see
uncommitted changes, and switching to a live session abandons your pane and
points at a *different* worktree.

The mechanical half — resolve the invoking pane's worktree, split the window,
boot-poll the new pane, inject the payload, and (only for a child-task binding)
clear the one-time `~/code/tasks/` read prompt — is entirely
`scripts/.config/scripts/tmux/handoff.sh --pane`, already built. This skill is
everything that script can't do on its own: deciding whether the helper is a
throwaway or a tracked child task, authoring its prompt/context, choosing its
posture toward the shared worktree, and (for a child) seeding the task record.

## Scope — what this does and doesn't do

- **Same window, same worktree, this session.** The helper is a pane split of
  the *current* window (`handoff.sh --pane` reads `$TMUX_PANE`'s
  `pane_current_path` and splits there). If the work belongs in a *different*
  repo/slug — a fresh worktree or an already-live session elsewhere — that's
  `/handoff`, not this.
- **Single-target only.** One helper pane per invocation. Fan-out (several
  panes at once) is explicitly out of scope, the same v1 boundary `/handoff`
  keeps.
- **Never modifies `scripts/.config/scripts/tmux/wb.sh`, and never calls
  `wb_seed_planned_child` (breakdown-internal) directly.** A tracked child task
  is created **only** through the public locked verb
  `wb new --planned --parent <parent-stem> <repo> <slug>`. If something seems
  to need a `wb.sh` change to work well, don't add it — note it as a follow-up
  in the relevant task file's `## Follow-ups` instead.
- **Trigger phrasing:** `/handoff-pane`, "spin up a helper here", "get a second
  agent to review these uncommitted changes", "split off a reviewer in this
  window", "another agent in this worktree", or any ask for a co-located helper
  in the current worktree rather than a fresh/different session.

## What to do

### 1. Decide the binding — ephemeral or child task

- **Ephemeral (default for a throwaway helper):** no task file, no store entry,
  no `@task`. Pick this when the helper is a one-shot — review this worktree, a
  quick spike, a second pair of eyes — with no need for a durable record. By
  construction it can't contend on any task-file lock with the parent.
- **Child task:** a planned child task in the store. Pick this when a tracked,
  durable record is wanted (the helper's work should show up on the board, be
  resumable, or be referenced later). Created via
  `wb new --planned --parent`, which seeds `status: planned`, `parent:` set,
  and a **blank `worktree:`** — so the child owns no worktree of its own, and
  its eventual `wb done` takes the store-only path, never removing the parent's
  worktree.

**Child binding requires a resolvable parent.** It's only available when the
current session has a resolvable `@task`. If none resolves (see step 4), child
binding is unavailable — fall back to ephemeral and say so.

### 2. Decide the posture toward the shared worktree (R10) — never silent

Both agents share one worktree with **no lock** over its files. State which
posture you chose and why; never let it be a silent inference.

- **Report-only (default-safe):** the helper inspects and reports, makes no
  edits. Concretely, a prompt like `/ce-code-review mode:agent` (report
  findings, don't fix). Safe to run while the parent keeps working.
- **Apply-fixes (only when the user asks and accepts the risk):** the helper
  edits the shared worktree. Because there is **no lock**, if the parent is not
  actually idle, concurrent edits to the same file **silently overwrite each
  other's uncommitted work, with no git recovery path**. The interim safety is
  the requester **pausing the parent** for the duration. Only choose this when
  the user explicitly asks for it and accepts pausing the parent — and say so.

The posture lives entirely in the prompt/first-action text you compose; the
script is posture-blind.

### 3. Ephemeral path

Compose a **short one-line prompt** that carries the posture directly (e.g.
`Review the uncommitted changes in this worktree with /ce-code-review
mode:agent and report findings — do not edit.`). The payload is that prompt.
Invoke `handoff.sh --pane` **without** `--await-perm` — an ephemeral prompt
reads only within the already-trusted worktree, so no outside-cwd permission
prompt appears and no handshake is needed. Go to step 5.

If the helper needs more than one line of context, put a short brief in a
scratch file **inside the worktree** (e.g. `./REVIEW-BRIEF.md`) and point the
one-line prompt at it — still no `~/code/tasks/` read, so still no
`--await-perm`.

### 4. Child path

Resolve the **parent stem** from the current session's `@task`. Shell out to
`wb.sh`'s own helper so the path can't drift — `wb_session_task_file` returns
the task-file *path*, and `wb new --parent` wants the bare `<repo>--<slug>`
stem, so take `basename … .md`:

```bash
DOTFILES="${DOTFILES_ROOT:-$HOME/code/dotfiles}"
parent_stem="$(cd "$DOTFILES" && bash -c '
  source scripts/.config/scripts/tmux/wb.sh
  f="$(wb_session_task_file "$(tmux display -p "#S")")" || exit 1
  basename "$f" .md
')"
```

(Sourcing `wb.sh` is safe — its CLI dispatch is guarded and never fires when
sourced, the same property `handoff.sh` itself relies on.) If `parent_stem` is
empty / the command failed, **there is no resolvable parent** — fall back to
the ephemeral path (step 3) and tell the user child binding wasn't available.

Otherwise create the child and seed it, then set the payload to the fixed
pointer:

1. **Create the planned child** (locked, public verb — never
   `wb_seed_planned_child`, never a `wb.sh` edit). Pick `repo` (normally the
   same repo as the parent) and a short child-slug describing the helper's job:

   ```bash
   child_task_file="$("$DOTFILES/scripts/.config/scripts/tmux/wb.sh" \
     new --planned --parent "$parent_stem" "$repo" "$child_slug")"
   ```

   This seeds `status: planned`, `parent: <parent-stem>`, and a **blank
   `worktree:`** from `~/code/tasks/TEMPLATE.md`.

2. **Write the first-action + the brief**, following `/handoff`'s task-file
   conventions (see `claude/.claude/skills/handoff/SKILL.md` steps 4–5):
   - The `# <title>` and a `**First action when picked up:**` line go in as a
     direct Read+Edit of the preamble (the one position `wb append` can't
     target). Carry the posture into the first action.
   - The rich context (what to review, why, constraints, the posture and the
     apply-fixes caution if relevant) goes under `## Plan` via `wb append`
     (append-only, never Edit/Write under a `##` heading):

     ```bash
     wb append "$child_task_file" Plan <<EOF
     <the rich context — what to look at, why, the chosen posture>
     EOF
     ```
   - **Check the child has a `## Follow-ups` heading** (the live `TEMPLATE.md`
     lacks one) and add one if missing — same safeguard `/handoff` documents,
     so any later follow-up note has a heading to land under.

3. **Set the payload** to the same fixed pointer `/handoff` uses (nothing
   runtime-variable in it beyond the path):

   ```
   Read the task file at <child_task_file> - it carries the full context and states the first action to take.
   ```

### 5. Invoke `handoff.sh --pane` and relay the outcome

Substitute the **literal** payload/path values you resolved — do not copy
`$variable` names into a fresh shell call (harness shell state doesn't persist
between separate Bash calls). Until the deferred post-merge wiring lands (a
`~/.zshrc` alias + a `stow` re-run so `~/.config/scripts/tmux/handoff.sh`
resolves), invoke it by its path in the dotfiles checkout.

- **Ephemeral:** no `--await-perm`.

  ```bash
  /home/jetnoli/code/dotfiles/scripts/.config/scripts/tmux/handoff.sh --pane "<the one-line prompt>"
  ```

- **Child:** add `--await-perm` so the script clears the one-time
  `~/code/tasks/` read prompt (the pointer points outside the worktree).

  ```bash
  /home/jetnoli/code/dotfiles/scripts/.config/scripts/tmux/handoff.sh --pane --await-perm "Read the task file at <child_task_file> - it carries the full context and states the first action to take."
  ```

Relay `handoff.sh`'s own one-line outcome back to the user verbatim (drop any
trailing internal source-reference). The messages you'll see:

- `handoff: split a helper pane (<pane>), booted claude, and injected the
  payload` (exit 0) — ephemeral success; the helper is up in a pane sharing
  this worktree.
- `handoff: split the helper pane (<pane>), injected the pointer, cleared the
  tasks/ read permission prompt` (exit 0) — child success, fully clean.
- `handoff: split the helper pane (<pane>) and injected the pointer — no
  permission prompt seen within <N>s (...)` (stderr, exit 0) — child injected
  fine; the tasks/ prompt just isn't confirmed (it may already be clear).
- `handoff: split the helper pane (<pane>) and injected the pointer — a
  permission prompt appeared but didn't match the expected tasks/Read shape;
  leaving it for you to answer` (stderr, exit 0) — tell the user to answer that
  prompt in the helper pane.
- `handoff: split a helper pane (<pane>) but it never showed a boot-ready
  anchor within <N>s — check it by hand` (exit 1) — the helper pane may need a
  manual look.
- `handoff: <worktree> is not a git worktree — refusing to split (...)` (exit
  1) — `$TMUX_PANE`'s cwd drifted off the worktree; the split was refused.
  Surface it; the requester likely `cd`'d elsewhere earlier in this shell.
- `handoff: --pane needs $TMUX_PANE ...` / `handoff: --pane must run from
  inside a tmux client` (exit 1) — the invoking environment is unusual; surface
  as-is.

### 6. Surface the lifecycle footguns (once, briefly) when a helper is left live

State these to the user the first time a helper pane is left running — they're
documented (see `docs/handoff-guide.md`), not code-enforced this version:

- **`wb done --close` kills the whole session — the helper pane with it.**
  Close the helper pane before winding the parent down with `--close`.
- **`wb done` can remove the shared worktree under a live helper.** `wb done`
  never enumerates panes; its `git worktree remove --force` can delete the
  worktree the helper is still sitting in.
- **Uncommitted helper changes make `wb done` refuse** (the dirty guard) — a
  feature, not a bug: commit or discard the helper's work first.
- **A child-bound helper shares this session's `@task`.** `@task` is
  session-scoped, so a `/wb-save` (or any `@task`-resolving verb) run *from the
  helper pane* resolves to the **parent's** task file, not the child's — it
  would write the parent's `## Handoffs`. Until pane-scoped `@task` resolution
  exists (a deferred follow-up that needs a `wb.sh` change), don't rely on
  `/wb-save` from a child helper; the helper reads its own file via the injected
  pointer, which is unaffected.

## Notes

- This skill never splits the pane itself and never checks tmux state — that's
  entirely `handoff.sh --pane`'s job. The skill's work ends at "payload composed
  (and, for a child, the task seeded), here's the `--pane` invocation."
- Sibling of `/handoff` (routing to a different repo/slug) and the `/wb-*`
  family; keep each skill legible rather than folding pane mode into `/handoff`.
- Full mechanical rationale (worktree resolution, the plain-pane-then-send-keys
  launch, the handshake gating, why `wb.sh` is never touched) lives in
  `docs/handoff-guide.md` and the plan
  (`docs/plans/2026-07-19-001-feat-handoff-pane-mode-plan.md`).
