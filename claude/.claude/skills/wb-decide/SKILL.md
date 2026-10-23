---
name: wb-decide
description: Record a decision made in this session into the current task file's `## Decisions` section — what was decided, the rejected alternative(s), and why — or accept/edit/dismiss a background-drafted one. Use when the user types `/wb-decide` (optionally with a one-line hint), or says "record that decision", "log this decision", "note that we decided", "write that down in Decisions"; also when a `[wb-capture] …` nudge line shows up in context pointing here. Subcommands `/wb-decide shelved` (review shelved drafts), `/wb-decide dismiss`, `/wb-decide mute`, `/wb-decide unmute`, `/wb-decide status` control the auto-capture nudge. Locates the task file via the current tmux session's `@task` option, never cwd/branch inference. Append-only via `wb append`; never Edit/Write the task file.
---

# wb-decide

`/wb-decide` is the "record" half of the decision auto-capture loop. The
`wb-capture` plugin's hooks watch a wb session for decision-shaped turns and
inject a one-line `[wb-capture] …` nudge into the next prompt — either a
phrase-match ("Last turn read like a decision (…)") or a pointer to a draft a
background model review wrote. Hooks never write the task store (KTD5 in
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
  silence or that message as a failure. Exception: `accept`/`dismiss` that carry a
  shelved `<path>` or `--task <stem>` work with no wb session at all (see step 2b).

## What to do

### 0. Subcommand passthroughs

If the argument is exactly `dismiss`, `mute`, `unmute` or `status`, run:

```bash
~/.config/scripts/tmux/wb-capture.sh <verb>
```

Report its output (or say it printed nothing — a silent no-op) and stop. For
`status`, relay **every** `shelved:` line verbatim (path and any `(stale)`
marker) — don't compress them into a count or a one-line summary; the user
needs the paths to pick one. Nothing else in this skill applies. The argument
`shelved` is not a passthrough: run step 1, then follow step 2b. Any other
argument is a free-text hint for the default mode below.

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

`status` is read-only. When a draft is present it prints a `draft_sha: <sha1>` line:
note it, because the dismisses below pass it as `--expect <sha>` (compare-before-delete:
a draft the sweep wrote after your `status` is never deleted unseen). A draft is marked **under review** by a separate
`~/.config/scripts/tmux/wb-capture.sh review`, which the draft-review path below
runs right after it shows the draft: the nudge then carries over to the next
turn instead of counting as ignored, so a review that spans several messages
(edits, questions) is fine and resolves once. After four carried turns with no
record or dismiss it counts as abandoned and is struck like an ignored nudge
(still shelved, never deleted). Run `review` only on that path, never for a
bare `status` check or any other path through this skill.

Take the **draft-review path** only when a draft is present (status names a
draft file) **and** one of these holds:

- the draft nudge (`[wb-capture] A background review drafted …`) is what sent
  you here, or
- the user ran `/wb-decide` with no hint.

On that path, Read the draft and present it to the user, then run
`~/.config/scripts/tmux/wb-capture.sh review` (a quiet no-op unless the draft's
nudge is outstanding). Accept it as-is, or edit it first, **only if it reflects
a real decision made in this session** — a sweep draft sees a transcript excerpt
and can be wrong or already-recorded. If it doesn't, run
`~/.config/scripts/tmux/wb-capture.sh dismiss --expect <draft_sha>` (the sha from the
`status` you showed), then re-run `status`: if it still prints `draft: present` (a
phrase nudge was outstanding, so `dismiss` kept the draft), run the same `dismiss
--expect <draft_sha>` again — the first only resolved that nudge. If a dismiss exits 1
(`draft changed since status`), nothing was removed: the sweep replaced the draft, so
show the new one (re-run `status`, note its new `draft_sha`) instead. Say so in one
line, and stop.

**A draft may hold up to 3 entries** (one `### ` block per decision the sweep found).
Review each entry on its own: accept it as-is, edit it, or drop it. Record the
accepted ones in ONE `wb append … Decisions -` call (step 4), each with its own
`### <YYYY-MM-DD HH:MM> — <title>` heading, then resolve the draft as usual (step 5's
`clear --draft`) even when only some entries were accepted: the rest were reviewed and
rejected, and the draft is not kept for them. If none is accepted, it is a dismiss, not
a `clear --draft`.

If `status` also says the draft **may already be recorded** (the task file
changed while it was being written — usually a `/wb-decide` that landed
meanwhile), it prints the `### ` headings of the Decisions entries added
since. Show the user the draft next to those entries (Read them from
`## Decisions`) and ask whether the draft duplicates one. If it does, run
`wb-capture.sh dismiss --expect <draft_sha>` (the log tags it stale, so it doesn't
count against the nudge; re-run `status` and `dismiss --expect <draft_sha>` again if
the draft is still present, as above) and say so in one line; if not, accept or edit as usual.

Otherwise go straight to composing (step 3) and **leave the draft alone** (do
not dismiss it): a phrase nudge sent you here, the user's hint names a
specific decision, or there is no draft. A draft you skipped stays pending;
the hooks re-nudge it once more if it is ignored, then shelve it (see
step 2b) — a draft is never deleted without the user's accept or dismiss.

### 2b. Shelved drafts

`status` ends with one `shelved: <path>` line per shelved draft of this task
(`(stale)` = the task file changed while it was drafted), or `shelved: none`. A
draft gets shelved when its nudge was ignored twice, or the session ended or was
reaped with it pending; nothing nudges a shelved draft, so it waits for the user.
When the user asks (`/wb-decide shelved`, "what's shelved"), review them **one at
a time**: Read the draft (and for a stale one compare it with the newest
`## Decisions` entries), then

- **accept / edit** — three commands, in this order, so the record isn't mistaken
  for an answer to whatever nudge is live in this session. Do any user
  confirmation or editing FIRST, then run
  `~/.config/scripts/tmux/wb-capture.sh accept --begin <path>` immediately before
  the `wb append` (it writes a one-shot flag, changes nothing else; the append's
  PostToolUse hook consumes the flag, and a real prompt in between would expire
  it), then compose and `wb append` as in steps 3-4, then
  `~/.config/scripts/tmux/wb-capture.sh accept <path>` (moves the draft to
  `resolved/`, kept 30 days, and logs `shelved_accepted`; it does not touch the
  flag). Run all three in ONE Bash call, chained with `&&` so a failed append
  skips the final accept (the draft then stays shelved):
  `~/.config/scripts/tmux/wb-capture.sh accept --begin <path> && wb append <task> Decisions - <<'WB_DECISION_END' && ~/.config/scripts/tmux/wb-capture.sh accept <path>`,
  followed by the heredoc body and the `WB_DECISION_END` terminator line. A shelved draft may hold up to 3 entries: review each,
  record the accepted ones in ONE `wb append` (each under its own dated heading), and
  run `accept <path>` even if only some were accepted. If the append is abandoned,
  skip the last command: the draft stays shelved and the flag expires with the turn;
- **reject** — `~/.config/scripts/tmux/wb-capture.sh dismiss <path>` (moves it to
  `resolved/`, kept 30 days, logs `shelved_dismissed`); also the answer when none of a multi-entry draft's
  entries is accepted.

A shelved draft of a task that is already closed (or any other task) is still
resolvable from this session, or from no wb session at all (path-carrying
`accept`/`dismiss` ignore the kill switch and need no `@task`; without a session they
log with an empty session id, and `accept --begin` writes no flag, as there is
nothing to protect; with no `--task` and no `@task` they exit 1 with a message): `wb-capture.sh shelved --task <stem>` lists one
task's drafts (`shelved --all` lists every task's, grouped), and
`dismiss --task <stem> <path>`, `accept --begin --task <stem> <path>` and
`accept --task <stem> <path>` resolve one. Drafts left behind by `wb done
--leave-shelved` stay resolvable this way. An accepted closed-task draft is
recorded into THAT task's `## Decisions` (`wb append <that task> Decisions -`),
not this session's.

Never delete a shelved file by hand; `accept`/`dismiss` refuse any path outside
the shelved dir of this task (or of the `--task` stem). Step 5's `clear` is for the
session's own pending draft, not shelved ones.

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
and lands the block at the END of the section. When several draft entries were
accepted, put them all in the one heredoc, one dated `###` heading each, so the
record is a single `wb append` call.

### 5. Clear the capture state, then confirm

After a *successful* write, pick the form by what you just recorded:

```bash
# you recorded the session's own pending draft (draft accept / draft edit + accept):
~/.config/scripts/tmux/wb-capture.sh clear --draft
# you composed from the conversation (phrase nudge, hinted run, no nudge at all):
~/.config/scripts/tmux/wb-capture.sh clear
```

Plain `clear` drops the marker, the reviewing flag and the outstanding-nudge flag,
and **keeps** a pending sweep draft: you didn't review it, so it isn't yours to
archive, and it gets nudged at the next real prompt (a duplicate costs the user one
`/wb-decide dismiss`, and `status` lists the Decisions entries added since). `clear
--draft` does the same and also moves the draft to `resolved/` (kept 30 days) and
removes its stale/strike state, because that draft is what just got recorded. Neither logs a `dismissed` event (the
`followed` event is logged by the plugin's PostToolUse hook when it sees the
`wb append … Decisions` call; if that hook missed it, either form logs `followed`
for a still-outstanding nudge). Only run it after a successful write. Then one
line: `Recorded to ## Decisions.`

## Test scenarios (behavior to follow for each)

- [ ] **Happy path:** a real decision was made, `/wb-decide` run — read
  `@task`, read `## Decisions` for style, compose decided/rejected/why,
  `wb append` it, plain `wb-capture.sh clear`, confirm in one line.
- [ ] **Draft accept:** `status` shows a draft that matches a real decision —
  present it, append it as-is via `wb append`, `clear --draft`.
- [ ] **Multi-entry draft (up to 3 `### ` blocks):** review each entry; append the
  accepted ones in ONE `wb append` (each with its own dated heading), then
  `clear --draft` (session draft) or `accept <path>` (shelved) even though only some
  were accepted; if none is accepted, `dismiss --expect <draft_sha>` (or `dismiss
  <path>` for a shelved one) instead.
- [ ] **Draft edit + accept:** draft is roughly right but misses the
  rejected alternative or the why — edit it from session context, append the
  edited version, `clear --draft`.
- [ ] **Phrase nudge or hinted run with a draft pending:** skip the draft
  path, compose from the conversation, leave the draft untouched (no dismiss);
  plain `clear` after the write keeps it, so it stays pending and is nudged again.
- [ ] **Stale draft:** `status` says the draft may already be recorded and
  lists newer Decisions entries — show the draft beside them and ask; a
  duplicate gets `dismiss` (say so), a distinct one is accepted/edited as usual.
- [ ] **Multi-message review:** the draft-review path ran `review` after
  showing the draft (a bare `status` never does); the user asks questions /
  requests edits over several turns — the nudge isn't counted ignored, one
  `followed` (or `dismissed`) results.
- [ ] **Shelved drafts:** `status` lists `shelved:` lines; `/wb-decide shelved`
  reviews them one at a time — accept/edit → `accept --begin <path>` (right
  before the append) → `wb append` → `accept <path>`, reject → `dismiss <path>`; a closed task's
  drafts take `--task <stem>` on each; never a hand `rm`.
- [ ] **Draft reject → dismiss:** draft doesn't reflect a real decision (or
  is already recorded) — `wb-capture.sh dismiss --expect <draft_sha>`, then `status`;
  if it still prints `draft: present` (a phrase nudge was outstanding, so dismiss kept
  the draft), the same `dismiss --expect <draft_sha>` again; exit 1 means a new draft
  landed, so show that instead; say so, no write.
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
