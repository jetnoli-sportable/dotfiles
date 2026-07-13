---
name: wb-save
description: Write a rich, structured snapshot of the current session's progress — what's done, what's in flight, the immediate next action — into the current task file's `## Handoffs` section, so the human can safely `/clear` without losing continuity. Use when the user types `/wb-save`, or says "save my progress", "checkpoint this", "save state before I clear", "write a handoff snapshot" — always immediately before a manual `/clear`. Locates the task file via the current tmux session's `@task` option, never cwd/branch inference. Append-only; never invokes `/clear` or touches tmux state itself.
---

# wb-save

`/wb-save` is the "save" half of a human-in-the-loop context-reset pair for
a single task's own session — `/wb-resume` (a sibling skill, not this one)
is the other half. It exists because an agent autonomously clearing its own
context was tried and hard-blocked: Claude Code's auto-mode classifier
denied an earlier dry-run's attempt to `tmux send-keys` `/clear` into its
own pane, twice, both times as "an agent self-driving its own pane to alter
its own session/oversight state." `/wb-save` writes the state that needs
to survive the clear; the human runs `/clear` themselves.

## Scope — what this does and doesn't do

- **Writes into the current session's task file only.** No cross-repo or
  cross-session lookups, no picking among multiple candidate tasks — the
  tmux session this skill runs in names its own task file via `@task`.
- **Never invokes `/clear`, never sends any keystroke to any pane, never
  touches tmux session state beyond the one read-only `@task` lookup in
  step 1.** This boundary is load-bearing, not incidental caution — see
  the intro above. Don't attempt `send-keys`, `capture-pane`, or anything
  else pane-directed as a workaround; if something seems to need it,
  that's a sign the request is out of scope for this skill, not a gap to
  route around.
- **Append-only.** Never overwrites any existing content in the task file —
  including prior `## Handoffs` entries, `## Plan`, `## Decisions`, or
  anything else already there.
- **Trigger phrasing:** `/wb-save`, "save my progress", "checkpoint this",
  "save state before I clear", "write a handoff snapshot".

## What to do

### 1. Locate the task file via `@task`

```bash
tmux show -t "=$(tmux display-message -p '#S'):" -v @task
```

This mirrors the session-option lookup convention `cmd_pause`/`cmd_done`
already use (`scripts/.config/scripts/tmux/wb.sh:816-820`), but reads
`@task` directly — the exact task-file path `cmd_new` already stamps onto
every wb-managed session (`wb.sh:334-336`) — instead of re-deriving
`repo`/`slug` from `@wb_repo`/`@wb_slug` and reconstructing the path by
hand.

- **Not set / empty output** — this is not a wb-managed session. Stop
  immediately, before touching any file. Tell the user clearly, in the
  same error class `cmd_pause`/`cmd_done` already produce for a missing
  `@wb_repo`/`@wb_slug` (`wb.sh:820`: `"$session has no @wb_repo/@wb_slug —
  not a wb task session"`) — e.g. `wb-save: this session has no @task —
  not a wb task session.` No partial write, nothing appended anywhere.
- **Set, but the file it points to doesn't exist on disk** (deleted,
  moved, or a stale option left over from a torn-down task) — this is a
  second, distinct error. Don't let a raw "file not found" from the
  Read/Edit tool be the only signal the user sees. Mirror `cmd_pause`'s own
  shape for this case (`wb.sh:824`: `"no task file for $repo/$slug
  ($task_file)"`) — e.g. `wb-save: no task file at <path> — recorded in
  this session's @task, but missing on disk.`
- Otherwise, proceed to step 2 with the path in hand.

### 2. Compose the entry from the current conversation

Draw all three fields from what has actually happened in this
conversation — never generic filler:

- **Done** — what has actually been completed this session, concrete and
  specific enough to be useful without the rest of the transcript.
- **In flight** — what's partially done or mid-change right now.
- **Next** — the immediate next action to take on resume, specific enough
  that a future `/wb-resume` reader (a fresh session with none of this
  conversation's context) can act on it directly, not just orient toward
  it.

If a field is genuinely empty (e.g. the session just started and nothing
is done yet), say so plainly — `**Done:** nothing yet this session` —
rather than omitting the field or inventing content to fill it.

### 3. Append into `## Handoffs` — exact section shape

This must match `wb.sh`'s own `wb_append_handoff` helper
(`scripts/.config/scripts/tmux/wb.sh`, search `wb_append_handoff`) section
conventions exactly — `/wb-resume` and `wb.sh`'s own automatic
pause/done/resume entries share this one append-only log, so a drift here
silently breaks that shared contract:

- **Heading position when missing:** insert `## Handoffs` immediately
  before `## Decisions` if that heading exists in the file; otherwise at
  the very end of the file. (The same insertion point
  `handoff_append_followup` uses for a missing `## Follow-ups`, and the
  same rule `wb_append_handoff` itself follows for this section.)
- **New entries always go at the END of the existing `## Handoffs`
  section** — immediately before whatever `##` heading comes next, or at
  EOF if none — never right after the heading. The section reads
  oldest-first; `wb.sh`'s own automatic entries write into this same
  section under this same rule, so entries from both sources interleave
  chronologically regardless of which side wrote them.
- **Entry format** — a `### <timestamp> — wb-save` heading (no `(auto)`
  suffix; that suffix belongs only to `wb.sh`'s own terse mechanical
  entries), timestamp in the same `date '+%Y-%m-%d %H:%M'` format, followed
  by three bold-leader fields:

```
### 2026-07-11 18:42 — wb-save
**Done:** ...
**In flight:** ...
**Next:** ...
```

- Shell out to `wb append` — the locked, heading-scoped append verb
  (`scripts/.config/scripts/tmux/wb.sh`, search `cmd_append`) every
  agent-mediated task-file write in this codebase now goes through, instead
  of an Edit-tool write. Pass the task file resolved in step 1, `Handoffs`
  as the heading, and the whole three-line block above as one multi-line
  body via stdin:

```bash
wb append "$task_file" Handoffs <<EOF
### $(date '+%Y-%m-%d %H:%M') — wb-save
**Done:** ...
**In flight:** ...
**Next:** ...
EOF
```

  `wb append` takes the per-task `flock` lock itself (the same one every
  other task-file writer in this codebase — `wb.sh`'s own `cmd_pause`/
  `cmd_done`/`cmd_resume`, and `handoff.sh` — already goes through) and
  reuses `wb_append_handoff`'s exact heading-fallback/end-of-section
  insertion rule: inserting `## Handoffs` first if it's missing (per the
  position rule above), and always landing the new block at the END of the
  section, never right after the heading. **Do not shell out to
  `wb_append_handoff` itself** — that helper hardcodes the `(auto)` suffix
  meant for its own mechanical callers (`cmd_pause`/`cmd_done`/
  `cmd_resume`) and writes a single-line message body, not this
  three-field structured entry; `wb append`'s multi-line stdin form exists
  specifically for this richer shape.
- **Never write or edit task files under `~/code/tasks` with the Edit/Write
  tool.** `wb append` is append-only by construction — it can only ever add
  a new block under a named heading, never touch a byte of what's already
  there — so shelling out to it *is* the "never overwrite every prior
  character" guarantee this section always carried; there is no separate
  manual-carefulness step left to describe.

### 4. Tell the user, relay, and stop

One line confirming the save landed and that running `/clear` is the next
manual step — e.g. `Saved to ## Handoffs — /clear when you're ready.`

Never invoke `/clear` yourself, never send it (or anything else) via
`tmux send-keys`, never touch tmux session state beyond the read-only
`@task` lookup in step 1. This is intentional, not an oversight to work
around — see the intro above for why it's a closed door, not an open
question.

## Test scenarios (behavior to follow for each)

- **Happy path:** mid-task session, `/wb-save` run — read `@task`, read the
  task file, compose done/in-flight/next from actual conversation content,
  append the entry under `## Handoffs` (creating the heading first if
  missing), confirm in one line.
- **Edge case — no `## Handoffs` heading yet:** insert it immediately
  before `## Decisions` if that heading exists, else at EOF, then the
  entry — the heading and the first entry appear together, not the heading
  alone or the entry with no heading.
- **Edge case — not a wb-managed session (no `@task` set):** stop before
  touching the file at all; one clear error line, no partial write
  anywhere.
- **Edge case — `@task` is set but the file it points to doesn't exist on
  disk:** a distinct, clear error mirroring `cmd_pause`'s "no task file
  for ..." shape — never let this surface as a bare file-not-found from
  the Read/Edit tool.
- **Integration note:** `/wb-save` → a manual `/clear` → `/wb-resume` (a
  sibling skill, not this one) is the intended round-trip. `/wb-resume`
  reads this same `## Handoffs` section back to pick the work up; nothing
  about its internals needs to be understood here.

## Notes

- `## Handoffs` is a shared log — entries from `/wb-save` and from `wb.sh`'s
  own automatic `pause`/`done`/`resume` entries interleave chronologically
  in the same section. Seeing a terse automatic entry after a rich
  `/wb-save` one (or vice versa) is expected, not a bug.
- `~/code/tasks/README.md` documents the `## Handoffs` convention for the
  whole task-store schema.
