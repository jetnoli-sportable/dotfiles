---
name: wb-decide
description: Record a decision made in this session into the current task file's `## Decisions` section — what was decided, the rejected alternative(s), and why — or accept/edit/dismiss a background-drafted one. Use when the user types `/wb-decide` (optionally with a one-line hint), or says "record that decision", "log this decision", "note that we decided", "write that down in Decisions"; also when a `[wb-capture] …` nudge line shows up in context pointing here. Subcommands `/wb-decide dismiss`, `/wb-decide mute`, `/wb-decide unmute`, `/wb-decide status` control the auto-capture nudge. Locates the task file via the current tmux session's `@task` option, never cwd/branch inference. Append-only via `wb append`; never Edit/Write the task file.
---

# wb-decide

`/wb-decide` is the "record" half of the decision auto-capture loop. The
`wb-capture` plugin's hooks watch a wb session for decision-shaped turns and
inject a one-line `[wb-capture] …` nudge into the next prompt — either a
phrase-match ("Last turn read like a decision (…)") or a pointer to a draft a
background Haiku review wrote. Hooks never write the task store (KTD5 in
`docs/plans/2026-09-22-002-feat-store-auto-capture-plan.md`); the live agent
— the only one with the full conversation — makes the call and does the
write, and this skill is how. It also works with no nudge at all: run it
whenever a real decision has been made and isn't recorded yet.

> **Store-only field/status edits:** never Edit/Write a task file's frontmatter by
> hand — `wb status <task-ref> <planned|paused|doing|review>` flips status and
> `wb set <task-ref> <field> <value>` (fields: priority value size parent
> depends_on jira tags path) writes any other frontmatter field under the task
> lock, both refusing when a live session owns the task.

## Scope — what this does and doesn't do

- **Writes into the current session's task file only**, and only under
  `## Decisions`. No cross-repo or cross-session lookups — the tmux session
  this skill runs in names its own task file via `@task`.
- **Never Edit/Write the task file.** `wb append` is the only write path; it
  takes the per-task lock and can only add a block, never touch existing
  bytes.
- **Append-only.** `## Decisions` is a log. A correction is a *new* entry
  that names which earlier entry it supersedes — never a rewrite of the old
  one.
- **Don't restate** decisions already recorded in `## Decisions`.
- **Don't record non-decisions.** A phrase match ("we'll go with…") is only a
  hint. If nothing was actually settled, dismiss instead of writing.
- **Trigger phrasing:** `/wb-decide`, "record that decision", "log this
  decision", a `[wb-capture]` nudge line.
- The capture verbs (`~/.config/scripts/tmux/wb-capture.sh <verb>`) are
  silent no-ops outside a wb tmux session or when capture is disabled (kill
  switch: `~/.local/state/wb/disable-capture`). Before the first prompt of a
  session they print `wb-capture: no capture session recorded on this pane
  yet (@wb_capture_sid unset)`. Relay whatever they print; don't treat the
  silence or that message as a failure.

## What to do

### 0. Subcommand passthroughs

If the argument is exactly `dismiss`, `mute`, `unmute` or `status`, run:

```bash
~/.config/scripts/tmux/wb-capture.sh <verb>
```

Report its output in one line (or say it printed nothing — a silent no-op)
and stop. Nothing else in this skill applies. Any other argument is a
free-text hint for the default mode below.

### 1. Locate the task file via `@task`

```bash
session=$(tmux display-message -p '#S')
task_file=$(tmux show -t "=$session:" -v @task)
```

- **Not set / empty** — not a wb-managed session. Stop before touching any
  file: `wb-decide: <session> has no @task — not a wb task session`. No
  partial write.
- **Set, but the file doesn't exist on disk** (moved, deleted, stale option):
  a second, distinct error — `wb-decide: no task file at <task_file> (from
  this session's @task) — it may have been moved or deleted`. Never let a
  bare file-not-found from Read be the only signal.
- Otherwise proceed with the path in hand.

### 2. Check for a pending draft

```bash
~/.config/scripts/tmux/wb-capture.sh status
```

- **A draft is present** (status names a draft file): Read it and present it
  to the user. Accept it as-is, or edit it first, **only if it reflects a
  real decision made in this session** — a Haiku draft sees a transcript
  excerpt and can be wrong or already-recorded. If it doesn't, run
  `~/.config/scripts/tmux/wb-capture.sh dismiss`, say so in one line, and
  stop.
- **No draft**: compose from session context (step 3).

### 3. Compose the entry

Read the task file's `## Decisions` section first and match its existing
style — entries are `### <YYYY-MM-DD HH:MM> — <short title>` headings
followed by bullets. Cover:

- **What was decided** — concrete, specific enough to stand without the
  transcript.
- **The rejected alternative(s)** — what was on the table and not chosen.
- **Why** — the reasoning a `git log` can't show.

Draw it from what actually happened in this conversation (use the user's
hint, if any, to pick which decision), never generic filler. If it corrects
or replaces an earlier entry, name that entry ("Supersedes the 2026-10-01
14:20 — … entry") rather than rewriting it.

If nothing was actually decided, say so plainly, run
`~/.config/scripts/tmux/wb-capture.sh dismiss`, and stop — no write.

### 4. Append with `wb append`

```bash
wb append "$task_file" Decisions - <<'EOF'
### 2026-10-09 15:30 — <short title>
- Decided: ...
- Rejected: ... (<why not>)
- Why: ...
EOF
```

Use the real current time (`date '+%Y-%m-%d %H:%M'`) in the heading — the
quoted heredoc doesn't expand `$(…)`, so compute it first and paste it in.
`-` reads the body from stdin; `wb append` inserts `## Decisions` if missing
and lands the block at the END of the section.

### 5. Clear the capture state, then confirm

After a *successful* write:

```bash
~/.config/scripts/tmux/wb-capture.sh clear
```

`clear` drops the marker and draft without logging a `dismissed` event (the
`followed` event is logged by the plugin's PostToolUse hook when it sees the
`wb append … Decisions` call). Then one line: `Recorded to ## Decisions.`

## Test scenarios (behavior to follow for each)

- [ ] **Happy path:** a real decision was made, `/wb-decide` run — read
  `@task`, read `## Decisions` for style, compose decided/rejected/why,
  `wb append` it, `wb-capture.sh clear`, confirm in one line.
- [ ] **Draft accept:** `status` shows a draft that matches a real decision —
  present it, append it as-is via `wb append`, `clear`.
- [ ] **Draft edit + accept:** draft is roughly right but misses the
  rejected alternative or the why — edit it from session context, append the
  edited version, `clear`.
- [ ] **Draft reject → dismiss:** draft doesn't reflect a real decision (or
  is already recorded) — `wb-capture.sh dismiss`, say so, no write.
- [ ] **Nothing decided:** phrase-match nudge but nothing was settled —
  say so, `dismiss`, no write.
- [ ] **mute / unmute:** `/wb-decide mute` and `/wb-decide unmute` pass
  straight through to `wb-capture.sh`; report its output.
- [ ] **status:** `/wb-decide status` passes through and reports the output
  (including the `@wb_capture_sid unset` message before a session's first
  prompt).
- [ ] **Not a wb session (no `@task`):** one clear error line
  (`wb-decide: <session> has no @task — not a wb task session`), no write.
- [ ] **Stale `@task` (file missing):** distinct error naming the path
  (`wb-decide: no task file at <task_file> (from this session's @task) — it
  may have been moved or deleted`), no write.
- [ ] **Correction supersedes an earlier entry:** new entry naming the
  entry it supersedes; the old entry is untouched.

## Notes

- Sibling of `/wb-save` (which writes `## Handoffs`); same `@task` lookup,
  same `wb append` write path, same append-only posture.
- `/close-out` step 4 can call this skill, or run the same `wb append …
  Decisions -` itself, when it finds an unrecorded decision at wind-down.
- Capture tuning (phrase list, cooldown, sweep on/off) lives in the optional
  `~/.config/wb/capture.conf`, not here.
