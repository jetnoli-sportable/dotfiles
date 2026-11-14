---
name: close-out
description: End-of-session wind-down for a wb task — sweep the session for anything worth a follow-up task or a park note, fold the session's real decisions and follow-ups into the task's dossier, then either `wb down` (worktree kept, warm resume — when the branch has an open PR) or `wb done` (run directly in the foreground, to remove the worktree and flip the task to done; its output is relayed as it is). Use when the user asks "anything deserving a task or discussion", "wb done and close this out", "wrap this up, what am I missing", "close out this worktree", or types /close-out. Also the place for winding down other sessions with `wb done --close <session>`.
---

# close-out

The thing this replaces: asking, at the end of most sessions, some variant
of "anything worth a task here, and can you wb done this" as two separate
asks. `/close-out` is that pattern as one command — a sweep for loose
threads, then the wind-down, in that order, because the sweep has to happen
**before** `wb done` removes the worktree out from under you.

> **Store-only field/status edits:** never Edit/Write a task file's frontmatter by
> hand — `wb status <task-ref> <planned|paused|doing|review>` flips status and
> `wb set <task-ref> <field> <value>` (any field `wb help` lists) writes any
> other frontmatter field under the task lock, both refusing when a live session owns the task.

## Scope — what this does and doesn't do

- **Reads back over *this conversation***, not the task file's history, to
  find loose threads. It has no separate transcript-mining step; this skill
  only looks at what's already in context.
- **Writes decisions and follow-ups** for the closing task: the
  `wb append … Decisions -` and `… Follow-ups -` commands write files in the task's
  `decisions/` and `open-items/`. There is no `## Done`; what shipped
  goes in the closing handoff. See `docs/wb-guide.md`, "Dossier layout". Never touches `## Handoffs` (that section is
  `/wb-save`'s and `wb.sh`'s own append point, written right before a manual
  `/clear` — a different moment than this one; `wb done` writes its own closing
  entry there).
- **Creates new task files** in `~/code/tasks/` for follow-ups substantial
  enough to need their own plan, and **hands a one-line reminder to `/park`**
  for anything lighter. See "Routing a loose thread" below for which is
  which — don't default to the heavier option out of caution; task-file
  sprawl is its own cost.
- **Runs `wb done` itself, in the foreground.** `wb done` opens no editor
  unless `--review` is passed, so the call returns on its own. This skill
  never passes `--review`. It relays `wb done`'s output as printed and adds
  nothing to it.
- **Does not decide `--close` on its own.** For the caller's own session
  (the one this skill winds down), pass it only when the user's own words in
  *this* invocation ask for it. For *another* session, such as a batch of
  finished workers, `--close` is the default; see "Winding down other
  sessions" below.

## Flow

### 1. Identify the closing task

Resolve the task file the same way `/wb-save` does: via the current tmux
session's `@task` option, not cwd/branch inference. `@task` is a session
option, so a pane lookup (`show -p`) fails with "invalid option":

```bash
tmux show -t "=$(tmux display-message -p '#S'):" -v @task
```

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
own `open-items/`, the standing weekly-capture doc (`wb week path`), and
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
  its decisions, so the next reader isn't starting cold. Link it from a
  follow-up in the closing task's own `open-items/` as `[[<new-slug>]]`.
- **Hand it to `/park`** (follow that skill's own judgement — non-work-shaped
  appends straight to the capture doc, work-shaped proposes a `prospective`
  task and asks) for a one-line reminder, idea, or "revisit this" note with
  no independent plan of its own. Cheaper, reversible, reviewed weekly by
  `/weekly-review` — the right default when a thread is more "don't let this
  slip" than "here's a scoped unit of work."

Tell the user what got created/parked, in one line each, before moving on —
don't let this land silently the way `/park`'s own mid-conversation capture
explicitly avoids.

### 4. Fill in the closing task's own file

(The "still empty" check below is "`decisions/` has no file".)

If the task's `decisions/` is still empty (or thin
relative to what actually happened), write them now: the real calls that
got made and why — not a
restatement of the diff, the *why* a `git log` can't show. Add a
follow-up (a file in `open-items/`) for every task file spun off in step 3 (park lines
don't need a mirror entry here — they live in their own ledger).

Then settle the task's **open follow-ups**: run `wb followups <task>` (read-only,
`<ref><TAB><title>` per open item) and compare the list with what
this session actually did. Offer the ones this session resolved to the user in one
short list, and mark each confirmed one with `wb followup-done <task> <ref> "<one-line
note of how it was resolved>"`. Never mark one the session did not finish, and never
Edit the task file or a record file for this.

If the task file already has this filled in from earlier in the session
(e.g. a mid-session `/wb-save` already wrote rich decision files),
don't duplicate — extend only where the sweep in step 2 added something new.

Then check for **decision drafts**: background-drafted decisions nobody has
accepted or dismissed. Run `/wb-decide`'s step 2b, the shared checkpoint review
procedure, here: one `~/.config/scripts/tmux/wb-capture.sh sweep` (Bash `timeout:
300000`) with its result line reported in one sentence, then each of this task's
shelved drafts one at a time for accept / edit / dismiss / leave. Don't restate the
procedure here; follow it there, except its item 5: skip the review's own propagate
call, because this skill propagates the whole run once at the end of this step. Never
drop one silently. `wb done` refuses while a shelved draft remains for the task, so
skipping this only defers it.

After folding real Decisions, if `decisions/` is **still empty**, review the
session and decide whether anything was actually decided:

- **Yes** — write it now (via `/wb-decide`, or the same `wb append <task>
  Decisions -`), as a real entry. No marker.
- **No** — the draft review above has already run, so append a marker entry
  through `wb append <task> Decisions -`:

  ```
  ### <YYYY-MM-DD HH:MM> — close-out
  _No decisions: <one-line reason>_
  ```

The marker is always an affirmed judgment by the agent, never automatic —
an unmarked empty `decisions/` keeps meaning "nobody checked", which is
what the graduation review counts as a likely miss versus a marked "nothing
to record". Tasks closed by bare `wb done` without `/close-out` stay
unmarked (accepted). Never Edit the task file for this; `wb append` only.

**Propagate once, then offer promotion.** Both run here, before the exit step,
because `wb down` and `wb done` end the session:

- **Propagate.** Once this step's last Decisions append has landed, run `/wb-decide`'s
  step 6 once, covering every real entry this run recorded: the drafts accepted in the
  review above, plus the entries folded or written directly in this step. When you
  write one here through `/wb-decide`, tell it this skill propagates the whole run, so
  its step 5 skips step 6; this one call covers it. Never include the `_No decisions:_` marker. If the run recorded nothing,
  skip this.
- **Promotion.** Read all of the task's decision files in `decisions/`, not just this run's
  entries, and run `/wb-decide`'s step 7 (the promotion procedure) for the entries that
  are facts about how the system behaves. Unlike the mid-session offer, this one may
  create the family's first `concepts.md` (lowercase, in the top parent's dossier). When nothing is fact-shaped, say so in one
  line and move on.

### 5. Check for other active or pending work tied to this task

Before handing off to `wb done`, look for anything that would make winding
down this task premature or would get silently lost with it:

- **Other live panes/windows in this same tmux session** — a co-located
  `/handoff-pane` helper, an nvim buffer with unsaved edits. `wb done`'s own
  dirty-tree check only looks at `git status --porcelain` (on-disk state);
  it cannot see an unsaved-but-never-written buffer in another window, and a
  `--close` wind-down would take that window down with the session, no
  confirmation (see "The `--close` self-kill hazard" in step 6). If one
  exists, say so before proceeding — don't just let `wb done` roll over it.
- **Open child tasks** (`parent:` pointing at this task's stem) — not a
  blocker, but worth one line noting they're still open if any exist, so
  closing the parent doesn't read as "the whole family is done."
- **Uncommitted changes in the worktree** — don't duplicate `wb done`'s own
  check here; if it's dirty, `wb done` will fail fast with its own message
  and this skill relays that verbatim in step 6, same as any other outcome.

### 6. Determine the exit — `wb down` at the PR moment, `wb done` otherwise

Run `wb pr-open` against the closing session first. It changes which verb
is right, not just a flag on the same one:

- **Exit 0 (the branch has an open PR):** the session has nothing left to
  do until a human reviews it — winding it all the way down and removing
  the worktree would throw away a warm, resumable conversation for no
  reason. Offer `wb down` instead of `wb done` in one line ("PR's up —
  close the session and keep the worktree so this resumes warm later, or
  wind it all the way down with `wb done`?") and act on the answer. `wb
  down` runs synchronously in the foreground (a single Bash call) and never
  removes the worktree. Relay its stdout verbatim, same posture as the
  `wb done` relay below.
- **Exit non-zero (no open PR, or the probe couldn't tell):** fall through
  to the ordinary `wb done` wind-down:
  - `--close` only if the user's words in *this* invocation asked for it
    ("close the session too", "kill it when you're done", etc.) — never by
    default, never carried over from an earlier turn.
  - If `--close` applies to the current session, surface the self-kill
    hazard below **before** running the command.
  - Run `wb done [--close]` as one plain, synchronous Bash call. Never pass
    `--review`, and never pass `--keep`, `--throwaway` or `--leave-shelved`
    on your own.
  - Relay `wb done`'s own stdout/stderr verbatim, whatever it printed: the
    closing line, a stop, the optional pending-counts nudge. Quote it; don't
    paraphrase.

What `wb done` does, so you can tell a stop from a success. With no flags it
opens no editor. It sorts every gitignored entry of the worktree into keep,
throwaway or unknown, using `wb-done-sweep.list` (beside `wb.sh`), the repo's
`.worktree-bootstrap`, and any `--keep <path>` / `--throwaway <path>` flags.
Keepers are copied into `~/code/tasks/dossiers/<task>/`, then it removes the
worktree and writes the closing handoff and status `done`. It stops, with
nothing changed, on:

- **Unknown gitignored entries** (or a keep that would overwrite a different
  file already in the dossier, a keep named like a dossier record such as
  `decisions` or `notes.md`, or a kept directory holding a symlink). The
  message names each entry and the ways to settle it.
- **A dirty worktree** (`git status --porcelain` output follows).
- **Undecided shelved decision drafts** (`N decision draft(s) shelved for
  <task> would be stranded (nothing changed)`, one `shelved: <path>` line each).

**On any stop: relay the message and end the turn.** Do not re-run `wb done`.
Do not add `--keep`, `--throwaway` or `--leave-shelved` to get past it, and do
not guess what the user wants for an unknown entry. The user decides: they
add a `wb-done-sweep.list` rule or answer with the flags, resolve the drafts
(`/wb-decide shelved`, or step 4 again), or ask for `--leave-shelved`, which
closes anyway and logs that the drafts were left on purpose. Drafts left that
way stay resolvable by task stem from any session:
`~/.config/scripts/tmux/wb-capture.sh shelved --task <stem>` lists them, and
`dismiss --task <stem> <path>` / `accept --task <stem> <path>` resolve one.
A flag the user names in a later message is theirs to give; pass it then.

#### The `--close` self-kill hazard

`wb done --close` with no other session named ends with `tmux kill-session`
on the session this skill is running in, which is the one carrying the
Claude Code process itself. The process dies with it, so there is no later
turn in which to relay a confirmation. Only the picker's <kbd>Ctrl</kbd>+<kbd>x</kbd>
has a self-target guard; typing `wb done --close` yourself is treated as an
intentional self-close.

`kill-session` also takes down every other window of that session. Each wb
session has a separate nvim window next to the agent window. The dirty-tree
check reads only on-disk state, so an unsaved buffer open in that other
window is invisible to it and is destroyed with the session.

So when `--close` applies to the current session, say so **before** running
the command, for example: "This will also kill the current tmux session,
including any other window in it, like an nvim buffer with unsaved edits,
once the wind-down finishes. You won't see a confirmation here after that;
check `wb board` or the task file afterward." This is not an extra
confirmation prompt (the user already asked for `--close`); it makes sure
they know the full blast radius.

#### Winding down other sessions

Used when the user asks to wind down a finished worker, a batch of workers
(for example after a `/quick-wins` run), or a session picked from the
picker's list.

- **Pass `--close` by default.** Without it `wb done` removes the worktree
  but leaves the session idle; the 2026-10-18 batch left 14 idle sessions
  that way for five days. Leave it off only when the user says to keep that
  session.
- **Never close the caller's own session as part of a batch.** Compare each
  target with `tmux display-message -p '#S'`; a match is the own-session
  case above, and `--close` then needs the user's explicit ask.
- **Take each target's name from `tmux list-sessions -F '#S'`**, never from
  a task-file stem. A name that matches no live session sends `wb done` down
  its store-only path, which marks the task done with no dirty-tree check
  and no worktree removal. Leave such a target out and tell the user which
  ones you skipped.
- **Run one `wb done --close <session>` per session**, each as its own
  foreground call, and relay each result verbatim, refusals and stops
  included, in the order they ran. One session's stop does not stop the
  rest; do not retry it or add flags.

The sweep (steps 2-4) and the other-work check (step 5) run identically
either way — the PR check only changes which verb finishes the session,
never whether the record gets written first.

## Test scenarios this skill's behavior must cover

- **Nothing came up** — straight-line session, no asides: step 2 says so
  explicitly, steps 3-4 are skipped (nothing to route, nothing new to add
  beyond what's already there), straight to the wind-down.
- **Mixed weight** — one thread substantial enough for its own task file,
  one a quick park-worthy note: both get created, both get mentioned in one
  line each, the task gets a follow-up in `open-items/` only for the former.
- **Already captured mid-session** — the user ran `/park` or spun off a task
  themselves earlier in this same session: step 2's existence check finds it
  and skips re-creating it.
- **Dirty worktree at wind-down** — sweep and file updates still happen
  (they don't touch the worktree's tracked files), but `wb done` itself
  fails fast with its own dirty-tree message, relayed as-is; nothing is
  removed, task stays open.
- **Unknown gitignored file at wind-down** — `wb done` stops with its message
  naming the entry; the message is relayed, the turn ends, and `wb done` is
  not run again and no `--keep`/`--throwaway` is added.
- **Undecided drafts at wind-down** — `wb done` refuses; the refusal is
  relayed and `--leave-shelved` is not added.
- **Winding down two other sessions** — one `wb done --close <session>` each,
  by name from `tmux list-sessions`, results relayed one by one; the caller's
  own session never gets `--close` from the batch.
- **Other live window in the session** — step 5 surfaces it before the
  wind-down launches, especially when `--close` was also requested.
- **Empty Decisions, nothing decided** — the draft review (sweep, then each shelved
  draft) has run; step 4 then appends the `### <timestamp> — close-out` /
  `_No decisions: <reason>_` marker.
- **Shelved drafts at close-out** — step 4 runs `/wb-decide` step 2b: `sweep`, then
  each draft accepted (`wb append … && accept <path>`), dismissed (`dismiss <path>`)
  or left (`keep <path>`) before the wind-down. A `skipped:`/`failed:` sweep line
  doesn't stop the review.
- **Empty Decisions, but the sweep found a decision** — a real entry is
  written; no marker.
- **Decisions already populated** — no marker.
- **Marker write path** — always `wb append <task> Decisions -`, never Edit.
- **Propagate once per close-out** — two shelved drafts accepted and one entry
  written directly: one `/wb-decide` step 6 run covers all three, the step 2b review
  inside step 4 sends nothing itself, and it all happens before `wb down`/`wb done`.
- **Marker only** — a run whose only append is the `_No decisions:_` marker sends
  nothing.
- **Promotion offer** — a Decisions entry that changes how the system behaves gets
  `/wb-decide` step 7's offer (lines, target, reach, supersedes). An entry that only
  gives a rationale gets none.
- **First `concepts.md` in a family** — Jet approves a line, the file is created in
  the top parent's dossier, and `wb family <task> --reseed` runs and its lines are
  relayed.

## Notes

- This skill never re-implements `wb done`'s dirty-check, keeper sweep, or
  worktree-removal logic, and never re-implements `/park`'s capture-doc-append
  or prospective-task recipe — it calls `wb done` and follows
  `park/SKILL.md` for those. If either's own behavior seems wrong, that's a
  change to that skill (or to `wb.sh`), not something to work around here.
- Not every session needs this. A session that's just answering questions,
  or one where `/wb-save` already ran and the human is winding down by hand,
  doesn't need `/close-out` invoked reflexively — it's for the moment the
  human is actually done with the task and wants the loose-thread sweep and
  the wind-down handled together.
