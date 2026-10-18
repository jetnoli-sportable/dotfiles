---
name: wb-decide
description: Record a decision made in this session into the current task file's `## Decisions` section — what was decided, the rejected alternative(s), and why — or accept/edit/dismiss a background-drafted one. Use when the user types `/wb-decide` (optionally with a one-line hint), or says "record that decision", "log this decision", "note that we decided", "write that down in Decisions"; also when a `[wb-capture] …` nudge line shows up in context pointing here. Subcommands `/wb-decide parked` (review parked drafts), `/wb-decide dismiss`, `/wb-decide mute`, `/wb-decide unmute`, `/wb-decide status` control the auto-capture nudge. Locates the task file via the current tmux session's `@task` option, never cwd/branch inference. Append-only via `wb append`; never Edit/Write the task file.
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
> `wb set <task-ref> <field> <value>` (any field `wb help` lists) writes any
> other frontmatter field under the task lock, both refusing when a live session owns the task.

## Scope — what this does and doesn't do

- **Writes into the current session's task file only**, and only under
  `## Decisions`. No cross-repo or cross-session lookups — the tmux session
  this skill runs in names its own task file via `@task`.
- **Never Edit/Write the task file.** `wb append` is the only write path; it
  takes the per-task lock and can only add a block, never touch existing
  bytes.
- **Append-only.** `## Decisions` is a log. A correction is a *new* entry
  that carries a `(supersedes: <date> "<title fragment>")` marker naming the
  earlier entry — never a rewrite of the old one.
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
and stop. Nothing else in this skill applies. The argument `parked` is not a
passthrough: run step 1, then follow step 2b. Any other argument is a
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

Running `status` also marks a pending draft as **under review**: the nudge
carries over to the next turn instead of counting as ignored, so a review that
spans several messages (edits, questions) is fine and resolves once. After
four carried turns with no record or dismiss it counts as abandoned and is
struck like an ignored nudge (still parked, never deleted).

Take the **draft-review path** only when a draft is present (status names a
draft file) **and** one of these holds:

- the draft nudge (`[wb-capture] A background review drafted …`) is what sent
  you here, or
- the user ran `/wb-decide` with no hint.

On that path, Read the draft and present it to the user. Accept it as-is, or
edit it first, **only if it reflects a real decision made in this session** —
a Haiku draft sees a transcript excerpt and can be wrong or already-recorded.
If it doesn't, run `~/.config/scripts/tmux/wb-capture.sh dismiss`, say so in
one line, and stop.

If `status` also says the draft **may already be recorded** (the task file
changed while it was being written — usually a `/wb-decide` that landed
meanwhile), it prints the `### ` headings of the Decisions entries added
since. Show the user the draft next to those entries (Read them from
`## Decisions`) and ask whether the draft duplicates one. If it does, run
`wb-capture.sh dismiss` (the log tags it stale, so it doesn't count against
the nudge) and say so in one line; if not, accept or edit as usual.

Otherwise go straight to composing (step 3) and **leave the draft alone** (do
not dismiss it): a phrase nudge sent you here, the user's hint names a
specific decision, or there is no draft. A draft you skipped stays pending;
the hooks re-nudge it once more if it is ignored, then park it (see
step 2b) — a draft is never deleted without the user's accept or dismiss.

### 2b. Parked drafts

`status` ends with one `parked: <path>` line per parked draft of this task
(`(stale)` = the task file changed while it was drafted), or `parked: none`. A
draft gets parked when its nudge was ignored twice, or the session ended or was
reaped with it pending; nothing nudges a parked draft, so it waits for the user.
When the user asks (`/wb-decide parked`, "what's parked"), review them **one at
a time**: Read the draft (and for a stale one compare it with the newest
`## Decisions` entries), then

- **accept / edit** — compose and `wb append` as in steps 3-4, then
  `~/.config/scripts/tmux/wb-capture.sh unpark <path>` (deletes it, logs `followed`);
- **reject** — `~/.config/scripts/tmux/wb-capture.sh dismiss <path>` (deletes it,
  logs `dismissed`).

Never delete a parked file by hand; `unpark`/`dismiss` refuse any path outside
this task's parked dir. Step 5's `clear` is for the
session's own pending draft, not parked ones.

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
or replaces an earlier entry, add a line `(supersedes: <date> "<title
fragment>")` right under the heading, rather than rewriting the old entry —
e.g. `(supersedes: 2026-10-01 "Store-wide board")`. The marker names the earlier
entry by its date and a quoted substring of its title (the text after
`<date> — `); read `## Decisions` first and quote the fragment from the real
text. Zero or several matches read as unresolved, so make the fragment
specific.

If nothing was actually decided, say so plainly, run
`~/.config/scripts/tmux/wb-capture.sh dismiss`, and stop — no write.

### 4. Append with `wb append`

```bash
wb append "$task_file" Decisions - <<'WB_DECISION_END'
### 2026-10-09 15:30 — <short title>
- Decided: ...
- Rejected: ... (<why not>)
- Why: ...
WB_DECISION_END
```

The delimiter is deliberately unusual: a draft or entry line reading exactly
`EOF` would end a plain `<<'EOF'` heredoc early and truncate the entry.

Use the real current time (`date '+%Y-%m-%d %H:%M'`) in the heading — the
quoted heredoc doesn't expand `$(…)`, so compute it first and paste it in.
`-` reads the body from stdin; `wb append` inserts `## Decisions` if missing
and lands the block at the END of the section.

### 5. Clear the capture state, then confirm

After a *successful* write:

```bash
~/.config/scripts/tmux/wb-capture.sh clear
```

`clear` drops the marker, the draft (even one you didn't review — a recorded
decision usually makes it stale) and the outstanding-nudge flag, without
logging a `dismissed` event (the
`followed` event is logged by the plugin's PostToolUse hook when it sees the
`wb append … Decisions` call; if that hook missed it, `clear` logs `followed`
for a still-outstanding nudge). Only run it after a successful write. Then one
line: `Recorded to ## Decisions.`

## Test scenarios (behavior to follow for each)

- [ ] **Happy path:** a real decision was made, `/wb-decide` run — read
  `@task`, read `## Decisions` for style, compose decided/rejected/why,
  `wb append` it, `wb-capture.sh clear`, confirm in one line.
- [ ] **Draft accept:** `status` shows a draft that matches a real decision —
  present it, append it as-is via `wb append`, `clear`.
- [ ] **Draft edit + accept:** draft is roughly right but misses the
  rejected alternative or the why — edit it from session context, append the
  edited version, `clear`.
- [ ] **Phrase nudge or hinted run with a draft pending:** skip the draft
  path, compose from the conversation, leave the draft untouched (no dismiss);
  `clear` after the write removes it.
- [ ] **Stale draft:** `status` says the draft may already be recorded and
  lists newer Decisions entries — show the draft beside them and ask; a
  duplicate gets `dismiss` (say so), a distinct one is accepted/edited as usual.
- [ ] **Multi-message review:** `status` marked the draft under review; the
  user asks questions / requests edits over several turns — the nudge isn't
  counted ignored, one `followed` (or `dismissed`) results.
- [ ] **Parked drafts:** `status` lists `parked:` lines; `/wb-decide parked`
  reviews them one at a time — accept/edit → `wb append` → `unpark <path>`,
  reject → `dismiss <path>`; never a hand `rm`.
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
- [ ] **Correction supersedes an earlier entry:** new entry carrying a
  `(supersedes: <date> "<title fragment>")` line; the old entry is untouched.

## Notes

- Sibling of `/wb-save` (which writes `## Handoffs`); same `@task` lookup,
  same `wb append` write path, same append-only posture.
- `/close-out` step 4 can call this skill, or run the same `wb append …
  Decisions -` itself, when it finds an unrecorded decision at wind-down.
- Capture tuning (phrase list, cooldown, sweep on/off) lives in the optional
  `~/.config/wb/capture.conf`, not here.
