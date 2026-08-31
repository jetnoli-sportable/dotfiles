---
name: wb-resume
description: Reads a task's `## Handoffs` log in a freshly `/clear`ed Claude Code session and picks the work back up — locates the most recent `/wb-save`-authored rich entry (its `**Done:**`/`**In flight:**`/`**Next:**` fields) and continues directly into the recorded next action, unless one or more terse automatic entries (`wb pause`/`wb done`/`wb resume`) landed after it, in which case it states the recorded plan and the gap explicitly and asks the human to confirm or redirect before proceeding rather than assuming the old plan still holds. Use when the user types `/wb-resume`, or a session that was just `/clear`ed needs to pick a task back up. Read-only against the task file — never appends to `## Handoffs` itself (that's `/wb-save`'s and `wb.sh`'s job) and never shells out to the unrelated `wb resume <task>` CLI command (a different, infra-level mechanism that recreates a torn-down worktree/session).
---

# wb-resume — pick a task back up after `/clear`

`/wb-resume` is the second half of the `/wb-save` → manual `/clear` →
`/wb-resume` pair (`claude/.claude/skills/wb-save/SKILL.md` is the first
half, written in parallel — not this skill's job to describe). Where
`/wb-save` writes a rich, structured snapshot into the task file's
`## Handoffs` section right before the human clears context by hand, this
skill runs in the freshly cleared session and reads that snapshot back —
the read-then-**act** half of the pair, not just read-then-orient. It
mirrors `/handoff`'s own "Determine `first_action`" step
(`claude/.claude/skills/handoff/SKILL.md:167-189`): a freshly spawned agent
that reads an injected pointer doesn't just acknowledge it, it acts on it.
`/wb-resume` holds itself to the same bar for a freshly cleared one.

## Scope — what this does and doesn't do

- **Read-only against the task file.** This skill never writes a
  `## Handoffs` entry itself — that's `/wb-save` (rich entries) and
  `wb.sh`'s `cmd_pause`/`cmd_done`/`cmd_resume` (terse, automatic entries
  via `wb_append_handoff`, `scripts/.config/scripts/tmux/wb.sh:878-937`).
  It may propose edits elsewhere in conversation, but nothing about running
  `/wb-resume` itself touches the file on disk.
- **Not the `wb resume <task>` shell command.** `wb.sh` already has a
  `cmd_resume` (`wb.sh:352-390`, bound to the CLI `wb resume <task>`) that
  recreates a torn-down worktree/tmux session from its task file — an
  infra-level mechanism, already tested
  (`scripts/.config/scripts/tmux/tests/wb-resume.test.sh`). This skill is
  conversation-level: it assumes the worktree/session are already alive
  (you're running inside them right now, mid-`/clear`) and only re-reads
  context. It never shells out to `wb resume`, and the naming collision is
  deliberate — don't conflate the two when reading `wb.sh` or its tests.
- **Single current session only.** Operates on whichever task the current
  tmux session is already bound to (via `@task`) — it does not take a
  repo/slug argument, search across other sessions, or resume a task other
  than the one this session belongs to.
- **Trigger phrasing:** the user types `/wb-resume`, or — equivalently —
  a session was just `/clear`ed as the second step of the save/clear/resume
  cycle and needs to pick the task back up.

## What to do

### 1. Locate the task file via `@task`

Every wb-managed session is stamped with `@task` at `wb new` time
(`cmd_new`, `wb.sh:334-336`) — the exact task-file path, not something to
re-derive from cwd or branch name. Read it directly:

```bash
session="$(tmux display-message -p '#S')"
task_file="$(tmux show -t "=$session:" -v @task 2>/dev/null || true)"
```

**Error path — no `@task` set:** this session was never created by `wb
new` (or the option was otherwise never stamped) — it is not a wb-managed
task session. Report a clear error and stop, mirroring `cmd_pause`'s own
wording for the same situation (`wb.sh:816-820`,
`"wb pause: $session has no @wb_repo/@wb_slug — not a wb task session"`),
adapted to the option this skill actually checks:

```
wb-resume: <session> has no @task — not a wb task session
```

Never fall back to guessing a repo/slug from the working directory, and
never fall back to shelling out to `wb resume` to "fix" this — a missing
`@task` means there is no task to resume in this conversation-level sense.

**Error path — `@task` set but the file doesn't exist on disk:** a second,
distinct error from the one above — the session thinks it's bound to a
task, but that file is gone (moved, deleted, or the store's layout
changed). Mirror `cmd_pause`'s wording for its equivalent case (`wb.sh:824`,
`"wb pause: no task file for $repo/$slug ($task_file)"`):

```
wb-resume: no task file at <task_file> (from this session's @task) — it may have been moved or deleted
```

Never surface a raw file-not-found tool error here — always this
human-readable message instead.

### 2. Find the most recent rich (`/wb-save`) entry in `## Handoffs`

Read the task file and locate its `## Handoffs` section. Entries in that
section are appended chronologically, oldest to newest
(`wb_append_handoff`'s own header comment, `wb.sh:868-872`, is explicit
that this ordering is load-bearing for exactly this skill). Two shapes of
entry can appear, distinguished by their heading line:

- **Rich, `/wb-save`-authored:** `### <YYYY-MM-DD HH:MM> — wb-save`,
  followed by `**Done:**` / `**In flight:**` / `**Next:**` bold-leader
  fields. No trailing `(auto)`. Optionally, immediately after `**Next:**`,
  a fenced ` ```run ` block whose content is a literal, machine-readable
  next-action directive — e.g.:

  ````
  **Next:** Run a full code review
  ```run
  /ce-code-review --full --subagents
  ```
  ````

  When present, this block is the authoritative statement of *what to run*
  — `/wb-save`'s own skill only emits it when the user's save-request
  explicitly named a concrete resume action, so its presence means intent
  was unambiguous at save time, not inferred. Extract its content (the line(s)
  between the ` ```run ` fence markers) alongside the three prose fields
  when reading this entry. Not every rich entry has one — a save with no
  stated next action has `**Next:**` prose and no block, which is a normal,
  valid entry, not a gap in the file.
- **Terse, automatic:** `### <YYYY-MM-DD HH:MM> — <source> (auto)` (e.g.
  `wb pause (auto)`, `wb done (auto)`, `wb resume (auto)`), with a single
  one-line body such as `` Session paused via `wb pause`. `` — always ends
  in `(auto)`.

Scan the section top to bottom and remember the **last** heading that
matches the rich shape (ends in `— wb-save`, not `(auto)`) — this is the
entry that actually carries next-action content. **Do not simply read the
last entry in the section** — because entries append at the end
chronologically, a terse automatic entry can land after the last rich one
(e.g. the task was paused, then resumed, after the save), and reading it
as if it were the plan would surface a content-free marker instead of the
real next action.

### 3. Check for a gap after that rich entry, then act

Having found the latest rich entry (if any), check whether any entries —
rich or terse — appear **after** it in the section.

- **No entries after it** (the immediate save → clear → resume case, the
  common path): before continuing, glance at `## Plan`/`## Decisions` and
  the frontmatter `status:` for anything that reads as newer than the
  saved entry (a decision recorded after the save's timestamp, a status
  that contradicts it). The terse-entry gap check above only catches a
  `wb pause`/`wb done`/`wb resume` cycle — it says nothing about a manual
  edit or a concurrent `/ce-plan`/`/ce-work` session updating the task file
  without ever touching `## Handoffs`. If nothing looks newer, the recorded
  plan is still current: state in one line what was read (e.g. what's
  done, what's in flight, the recorded next action), then **continue
  directly into that next action** — do not just summarize it and wait.
  This is the same posture `/handoff`'s injected pointer relies on: a
  freshly arrived agent acts on the first-action line it finds, it doesn't
  merely acknowledge it.

  **If the entry carries a ` ```run ` directive, execute it as the
  deterministic first step instead of re-deriving intent from the
  `**Next:**` prose** — the directive exists precisely so this doesn't have
  to be guessed. State the directive's literal command in the one-line
  summary (e.g. "Continuing into the recorded directive:
  `/ce-code-review --full --subagents`"), then run/invoke it directly. If
  the entry has no directive, fall back to the prior behavior: continue
  into the action described in the `**Next:**` prose.

  If something does look newer, treat it the same as the gap case below —
  state what changed and confirm before acting. This applies whether or
  not the entry carries a directive: a directive removes ambiguity about
  *what* was planned, it never overrides this freshness check about
  *whether* the plan is still current.
- **One or more terse entries after it** (a real `wb pause`/`wb done`/`wb
  resume` cycle happened between the save and this resume — the recorded
  next action may now be stale): state the recorded next action **and**
  the gap explicitly — name which automatic entries landed and in what
  order (e.g. "this task was paused, then resumed, since that save") —
  then **ask the human to confirm the old plan still holds, or redirect,
  before proceeding**. Do not barrel into the recorded action as if nothing
  happened in between. If the entry carries a ` ```run ` directive, state
  it verbatim as part of "the recorded plan" being confirmed (e.g. "the
  recorded next action was to run `/ce-code-review --full --subagents`") —
  a directive makes the stated plan more precise, it does not change this
  branch's requirement to ask first. **Never execute the directive before
  the human confirms** when this branch applies.

Either branch, never decide silently which case applies — say which one
you're in as part of the same one-line statement.

### 4. Fallback — no rich entry to find

- **`## Handoffs` exists but has only terse/automatic entries (no
  `/wb-save` entry yet):** there is no done/in-flight/next snapshot to
  read. Say so explicitly, then fall back to the rest of the task file —
  primarily `## Plan` — for context on what the task is and where it
  stands, and state plainly that you're doing this because no `/wb-save`
  entry exists yet.
- **No `## Handoffs` section at all** (heading absent from the file):
  same fallback — state clearly that there's no handoff log to read, then
  read the whole task file (frontmatter + `## Plan` + whatever other
  sections exist) for context instead of failing or refusing to proceed.

In both fallback cases, don't invent a next action that isn't grounded in
the file — describe what the task file actually says and let the human
steer from there if the intended next step isn't obvious from `## Plan`.

### 5. Always state what was read and what happens next

Regardless of which branch above applies, the response must say, in one
line up front: which task file/entry was read (or that none was found and
a fallback was used), and what happens as a result (proceeding directly,
or asking for confirmation because of a gap, or asking for direction
because there's no recorded plan at all). Never a silent continuation —
the human should never have to guess what state `/wb-resume` thinks it
picked up from.

## Behavior for each required scenario

- **Happy path — recent `/wb-save` entry, nothing after it:** state what
  was read (`Read the wb-save entry from <timestamp>: done — …, in flight
  — …`), then proceed straight into the recorded `**Next:**` action.
- **Happy path — recent `/wb-save` entry with a ` ```run ` directive,
  nothing after it:** state what was read, including the directive's
  literal command, then execute that directive directly as the first step
  — no re-deriving intent from `**Next:**` prose, no asking for
  confirmation (there's no gap).
- **Edge case — a terse entry (or entries) landed after the last
  `/wb-save` entry:** state the recorded next action (quoting the
  ` ```run ` directive verbatim if the entry has one), name the gap (e.g.
  "paused via `wb pause`, then resumed via `wb resume`, since that save"),
  and ask whether to proceed with the old plan or redirect — don't act
  until answered, and never auto-run the directive in this branch.
- **Edge case — no terse entries after the save, but `## Plan`/`## Decisions`/
  frontmatter status reads as newer than it** (e.g. a manual edit or a
  concurrent `/ce-plan`/`/ce-work` session touched the task file without
  going through `## Handoffs`): treat this the same as the terse-entry gap
  case — state what changed and confirm before acting, rather than trusting
  the absence of a terse entry as proof nothing changed.
- **Edge case — `## Handoffs` has only automatic entries, no `/wb-save`
  entry yet:** say explicitly that no rich save entry exists, fall back to
  `## Plan` (and the rest of the task file) for context, and summarize
  what was found there instead of a done/in-flight/next snapshot.
- **Edge case — no `## Handoffs` section at all:** say explicitly that
  there's no handoff log in this task file, then fall back to reading the
  whole task file for context, same as the previous case.
- **Error path — not a wb-managed session (no `@task`):** stop with the
  `wb-resume: <session> has no @task — not a wb task session` message from
  step 1 — no fallback read, no partial action.
- **Error path — `@task` set but the file doesn't exist:** stop with the
  `wb-resume: no task file at <task_file> (from this session's @task) — it
  may have been moved or deleted` message from step 1 — never a raw
  file-not-found error.

## Notes

- `/wb-save` and `wb.sh`'s automatic entries are the only writers of
  `## Handoffs`; this skill only ever reads it. If a genuinely new
  decision or plan revision comes out of the confirm-first conversation in
  step 3, that's a fresh `/wb-save` (or a direct edit under `## Plan`), not
  something this skill does on its own.
- The naming collision with the `wb resume <task>` CLI command
  (`wb.sh:352-390`) is intentional and pre-existing (see
  `~/code/tasks/dotfiles--feat-self-handoff.md`'s "Naming collision to
  resolve, not conflate" note) — that command is infra-level
  (worktree/session recreation), this skill is conversation-level (context
  re-read). If the session/worktree themselves are gone, that's out of
  scope here — the human runs `wb resume <task>` first to get a live
  session back, and only then would `/wb-resume` apply.
- `~/code/tasks/README.md`'s "Task body" section documents the
  `## Handoffs` convention (append-only, oldest-to-newest, terse vs. rich
  entries) this skill relies on.
- **Next-action directive syntax:** a fenced ` ```run ` block right after
  `**Next:**` in a rich entry (`claude/.claude/skills/wb-save/SKILL.md`'s
  "Compose the entry" section documents when `/wb-save` emits it). It
  makes *what was intended* explicit and machine-actionable, but it does
  **not** change the gap-check contract above — a directive is only ever
  auto-run on the no-gap path; on the gap path it is surfaced as part of
  "the recorded plan" and still requires human confirmation first.
