---
name: close-out
description: End-of-session wind-down for a wb task — sweep the session for anything worth a follow-up task or a park note, fold the session's real Decisions/Done/Follow-ups into the task file, then run `wb done` (via the wb-done skill's background+relay mechanism) to remove the worktree and flip the task to done. Use when the user asks "anything deserving a task or discussion", "wb done and close this out", "wrap this up, what am I missing", "close out this worktree", or types /close-out. Composes wb-done for the actual wind-down rather than reimplementing its async nvim-buffer handling.
---

# close-out

The thing this replaces: asking, at the end of most sessions, some variant
of "anything worth a task here, and can you wb done this" as two separate
asks. `/close-out` is that pattern as one command — a sweep for loose
threads, then the wind-down, in that order, because the sweep has to happen
**before** `wb done` removes the worktree out from under you.

## Scope — what this does and doesn't do

- **Reads back over *this conversation***, not the task file's history, to
  find loose threads. It has no separate transcript-mining step — see
  `parked-items/SKILL.md`'s backstop scan for that; this skill only looks at
  what's already in context.
- **Writes to `## Decisions`, `## Done`, and `## Follow-ups`** in the closing
  task's own file. Never touches `## Handoffs` (that section is
  `/wb-save`'s and `wb.sh`'s own append point, written right before a manual
  `/clear` — a different moment than this one) and never touches `## Sweep`
  (that section is `wb done`'s own gitignored-files review, written by the
  wind-down step this skill launches, not by this skill directly).
- **Creates new task files** in `~/code/tasks/` for follow-ups substantial
  enough to need their own plan, and **appends to the `/park` ledger**
  (`~/.claude/parked-items/ledger.jsonl`) for one-line reminders that don't.
  See "Routing a loose thread" below for which is which — don't default to
  the heavier option out of caution; task-file sprawl is its own cost.
- **Delegates the actual wind-down to the `wb-done` skill's mechanism**,
  verbatim (background Bash, no polling, relay the outcome as-is). This
  skill does not open its own copy of that async-nvim-buffer problem — see
  `wb-done/SKILL.md`'s "Why this needs to exist at all" for why a plain
  synchronous `wb done` call would hang the turn.
- **Does not decide `--close` on its own.** Same rule as `wb-done`: only
  pass it when the user's own words in *this* invocation ask for it.

## Flow

### 1. Identify the closing task

Resolve the task file the same way `/wb-save` does: via the current tmux
session's `@task` option (`tmux show -p @task`), not cwd/branch inference.
If that's unset (not a wb-managed session), say so and stop — this skill
has nothing to wind down.

### 2. Sweep the session for loose threads

Read back over the conversation since this task's work began (or since the
last `/close-out`/`/wb-save`, if one already ran this session) for things
that came up but were deliberately not acted on in the main line of work:

- A code-review or debug-skill finding that was found valid but explicitly
  deferred (scope, risk, or an unconfirmed assumption) rather than fixed.
- A "we should also do X" aside that never got its own turn.
- An assumption someone flagged as unverified that the work now depends on
  ("this should still hold, but confirm before relying on it further").
- A decision that was made but has a real tradeoff worth recording so a
  future reader doesn't re-litigate it blind.

Skip this step cleanly (say "nothing came up worth flagging" and move on)
when the session was a straight-line execution with no such asides — don't
manufacture findings to justify running the sweep.

**Before creating anything, check what already exists** — grep the task's
own `## Follow-ups`, `` `~/.claude/parked-items/ledger.jsonl` ``, and
`~/code/tasks/*.md` for the topic so a thread the user already parked or
already spun into a task mid-session doesn't get a duplicate.

### 3. Route each loose thread

For each thread that survives step 2, pick one of two homes — **default to
the lighter one** when genuinely unsure:

- **New task file** (`~/code/tasks/<repo>--<slug>.md`, from `TEMPLATE.md`,
  `status: planned`) when it needs its own investigation, a design decision,
  or more than a sentence to state — i.e. someone would actually sit down
  and work it as its own unit later. Write a `## Plan` that explains *why*
  it exists (link back `[[<closing-task-slug>]]`) and carry forward whatever
  context/tradeoffs/proposed-fix already came up in conversation into
  `## Decisions`, so the next reader isn't starting cold. Link it from the
  closing task's own `## Follow-ups` as `[[<new-slug>]]`.
- **`/park` ledger line** (follow that skill's own recipe: `jq -nc` into
  `~/.claude/parked-items/ledger.jsonl`, never hand-concatenated JSON) for a
  one-line reminder, idea, or "revisit this" note with no independent plan
  of its own. Cheaper, reversible, reconciled weekly by `/parked-items` — the
  right default when a thread is more "don't let this slip" than "here's a
  scoped unit of work."

Tell the user what got created/parked, in one line each, before moving on —
don't let this land silently the way `/park`'s own mid-conversation capture
explicitly avoids.

### 4. Fill in the closing task's own file

If `## Decisions` and `## Done` are still an empty skeleton (or thin
relative to what actually happened), write them now: the real calls that
got made and why, and what actually shipped/got verified — not a
restatement of the diff, the *why* a `git log` can't show. Add a
`## Follow-ups` line for every task file spun off in step 3 (park lines
don't need a mirror entry here — they live in their own ledger).

If the task file already has this filled in from earlier in the session
(e.g. a mid-session `/wb-save` already wrote rich `## Decisions` content),
don't duplicate — extend only where the sweep in step 2 added something new.

### 5. Check for other active or pending work tied to this task

Before handing off to `wb done`, look for anything that would make winding
down this task premature or would get silently lost with it:

- **Other live panes/windows in this same tmux session** — a co-located
  `/handoff-pane` helper, an nvim buffer with unsaved edits. `wb done`'s own
  dirty-tree check only looks at `git status --porcelain` (on-disk state);
  it cannot see an unsaved-but-never-written buffer in another window, and
  (per `wb-done/SKILL.md`'s own `--close` hazard section) a `--close`
  wind-down would take that window down with the session, no confirmation.
  If one exists, say so before proceeding — don't just let `wb done` roll
  over it.
- **Open child tasks** (`parent:` pointing at this task's stem) — not a
  blocker, but worth one line noting they're still open if any exist, so
  closing the parent doesn't read as "the whole family is done."
- **Uncommitted changes in the worktree** — don't duplicate `wb done`'s own
  check here; if it's dirty, `wb done` will fail fast with its own message
  and this skill relays that verbatim in step 6, same as any other outcome.

### 6. Determine `--close` and run the wind-down

Exactly `wb-done/SKILL.md`'s own flow, not a re-derivation of it:

- `--close` only if the user's words in *this* invocation asked for it
  ("close the session too", "kill it when you're done", etc.) — never by
  default, never carried over from an earlier turn.
- If `--close` applies to the current session, surface the self-kill hazard
  from `wb-done/SKILL.md` step 4 **before** launching — the last message the
  user sees from this session is the one right before the background call,
  not a relay of `wb done`'s own output.
- Launch `wb done [--close]` as a single Bash tool call with
  `run_in_background: true`. Say one short line and stop — do not poll, do
  not schedule a wakeup, do not keep talking. The background command
  completing is the signal.
- When it returns, relay `wb done`'s own stdout/stderr message verbatim
  (happy path, dirty-tree error, or the optional pending-counts/roadmap
  nudges) — same posture as `wb-done/SKILL.md` step 3.

## Test scenarios this skill's behavior must cover

- **Nothing came up** — straight-line session, no asides: step 2 says so
  explicitly, steps 3-4 are skipped (nothing to route, nothing new to add
  beyond what's already there), straight to the wind-down.
- **Mixed weight** — one thread substantial enough for its own task file,
  one a quick park-worthy note: both get created, both get mentioned in one
  line each, the task file gets a `## Follow-ups` entry only for the former.
- **Already captured mid-session** — the user ran `/park` or spun off a task
  themselves earlier in this same session: step 2's existence check finds it
  and skips re-creating it.
- **Dirty worktree at wind-down** — sweep and file updates still happen
  (they don't touch the worktree's tracked files), but `wb done` itself
  fails fast with its own dirty-tree message, relayed as-is; nothing is
  removed, task stays open.
- **Other live window in the session** — step 5 surfaces it before the
  wind-down launches, especially when `--close` was also requested.

## Notes

- This skill never re-implements `wb done`'s dirty-check, sweep-buffer, or
  worktree-removal logic, and never re-implements `/park`'s ledger-append
  recipe — it calls into `wb-done/SKILL.md` and `park/SKILL.md` for those.
  If either's own behavior seems wrong, that's a change to that skill (or to
  `wb.sh`), not something to work around here.
- Not every session needs this. A session that's just answering questions,
  or one where `/wb-save` already ran and the human is winding down by hand,
  doesn't need `/close-out` invoked reflexively — it's for the moment the
  human is actually done with the task and wants the loose-thread sweep and
  the wind-down handled together.
