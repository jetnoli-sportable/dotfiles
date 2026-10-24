---
name: wb-decide
description: Record a decision made in this session into the current task file's `## Decisions` section — what was decided, the rejected alternative(s), and why — or review the background-drafted ones waiting on the task's shelf (accept, edit, dismiss or leave each). Use when the user types `/wb-decide` (optionally with a one-line hint), or says "record that decision", "log this decision", "note that we decided", "write that down in Decisions". Subcommands `/wb-decide shelved` (sweep, then review shelved drafts), `/wb-decide dismiss <path>`, `/wb-decide mute`, `/wb-decide unmute`, `/wb-decide status` control auto-capture. Locates the task file via the current tmux session's `@task` option, never cwd/branch inference. Append-only via `wb append`; never Edit/Write the task file. After a record it messages the live sessions in the task's family that the decision affects (default nobody), and may offer to promote a behaviour-changing decision into the family's CONCEPTS.md.
---

# wb-decide

`/wb-decide` is the "record" half of the decision auto-capture loop. The
`wb-capture` plugin's background sweep reads a wb session's transcript and
drafts decisions nobody recorded; each draft waits on the task's shelf until
Jet reviews it at a checkpoint (`/wb-save`, `/close-out`, `/wb-decide
shelved`, the weekly review). Nothing about drafts is ever injected into the
agent's context. Hooks never write the task store (KTD5 in
`docs/plans/2026-09-22-002-feat-store-auto-capture-plan.md`); the live agent
— the only one with the full conversation — makes the call and does the
write, and this skill is how. Run it whenever a real decision has been made
and isn't recorded yet.

> **Store-only field/status edits:** never Edit/Write a task file's frontmatter by
> hand — `wb status <task-ref> <planned|paused|doing|review>` flips status and
> `wb set <task-ref> <field> <value>` (any field `wb help` lists) writes any
> other frontmatter field under the task lock, both refusing when a live session owns the task.

## Scope — what this does and doesn't do

- **Writes into the current session's task file only**, and only under
  `## Decisions`. The tmux session this skill runs in names its own task file
  via `@task`. The one cross-session action is step 6: after a record it may
  read other family sessions' task files and message the ones the decision
  affects. It never writes another task's file. Step 7 may write the family's
  `CONCEPTS.md`, and only lines Jet approved.
- **Never Edit/Write the task file.** `wb append` is the only write path; it
  takes the per-task lock and can only add a block, never touch existing
  bytes.
- **Append-only.** `## Decisions` is a log. A correction is a *new* entry
  that carries a `(supersedes: <date> "<title fragment>")` marker naming the
  earlier entry — never a rewrite of the old one.
- **Don't restate** decisions already recorded in `## Decisions`.
- **Don't record non-decisions.** If nothing was actually settled, say so
  and write nothing.
- **Trigger phrasing:** `/wb-decide`, "record that decision", "log this
  decision".
- The capture verbs (`~/.config/scripts/tmux/wb-capture.sh <verb>`) are
  silent no-ops outside a wb tmux session or when capture is disabled (kill
  switch: `~/.local/state/wb/disable-capture`). Before the first prompt of a
  session they print `wb-capture: no capture session recorded on this pane
  yet (@wb_capture_sid unset)`. Relay whatever they print; don't treat the
  silence or that message as a failure. Exception: `accept`/`dismiss`/`keep` that carry a
  shelved `<path>` or `--task <stem>` work with no wb session at all (see step 2b).

## What to do

### 0. Subcommand passthroughs

If the argument is exactly `mute`, `unmute` or `status`, or is `dismiss <path>`
(a shelved draft's path), run:

```bash
~/.config/scripts/tmux/wb-capture.sh <verb> [<path>]
```

`mute` now just silences the background sweep for this session (`unmute` turns it
back on); a muted session's checkpoint `sweep` also prints `skipped: muted`. A bare
`dismiss` with no path is a usage error in the script: don't run it, say it needs a
path and point to `/wb-decide shelved`. Report the output (or say it printed
nothing — a silent no-op) and stop. For
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

### 2. Go straight to composing

Compose from the conversation (step 3), using the user's hint, if any, to pick
which decision. Shelved drafts are not part of this path: they are reviewed only
at a checkpoint or when the user asks (`/wb-decide shelved`, step 2b). A draft
that covers the same decision is dismissed there, not here.

### 2b. Shelved drafts: the checkpoint review procedure

This is the one review procedure. `/wb-save` and `/close-out` run it by
reference (they don't copy it), and `/wb-decide shelved` runs it on request. A
background sweep drafts each decision it finds into its own file on the task's
shelf, and nothing nudges anyone, so a draft waits there until this review.

1. **Sweep first.** One Bash call with `timeout: 300000` (the sweep makes a model
   call, up to about two minutes):
   `~/.config/scripts/tmux/wb-capture.sh sweep`. It drafts any decisions in turns
   not swept yet, waits for that, and prints exactly one line: `drafted N`,
   `none`, `nothing new`, `skipped: <reason>` or `failed: <reason>`. It always
   exits 0. Report the line in one sentence ("The sweep drafted 2 decisions.",
   "The sweep skipped: muted."). On `skipped:` or `failed:` carry on anyway:
   drafts from earlier sweeps are still waiting.
2. **List this task's drafts:** `~/.config/scripts/tmux/wb-capture.sh shelved`
   prints one path per line, with ` (stale)` after a draft whose task's Decisions
   changed while it was being drafted. None listed: say so in one line and stop.
3. **Review them one at a time.** Read the draft and show it. For a `(stale)` one,
   first compare it with the newest `## Decisions` entries: it may already be
   recorded. Then ask: **accept**, **edit**, **dismiss** or **leave**. Accept only a
   draft that reflects a real decision made in this task: a sweep draft sees a
   transcript excerpt and can be wrong or already recorded.
   - **accept / edit** — do any confirming or editing FIRST, then compose and record
     as in steps 3-4, in ONE Bash call chained with `&&` so a failed append skips the
     accept (the draft then stays shelved):
     `wb append <task> Decisions - <<'WB_DECISION_END' && ~/.config/scripts/tmux/wb-capture.sh accept <path>`,
     followed by the heredoc body and the `WB_DECISION_END` terminator line. `accept`
     moves the draft to `resolved/` (kept 30 days) and logs `shelved_accepted`. A draft
     left from before the one-decision-per-file change may hold up to 3 `### `
     entries: review each, record the accepted ones in ONE `wb append` (each under its
     own dated heading), and run `accept <path>` even if only some were accepted.
   - **dismiss** — `~/.config/scripts/tmux/wb-capture.sh dismiss <path>` (moves it to
     `resolved/`, kept 30 days, logs `shelved_dismissed`). Also the answer when none of
     a multi-entry draft's entries is accepted.
   - **leave** — `~/.config/scripts/tmux/wb-capture.sh keep <path>` (logs `shelved_kept`;
     the file stays on the shelf). Always run it: it is how the log tells "shown and
     left" from "never shown", which the graduation review counts.
4. **Finish with one line** counting what happened (recorded N, dismissed N, left N).
   `/wb-save` quotes it in the Handoffs entry.
5. **Propagate once for the batch.** When the review recorded at least one entry,
   run step 6 once with the titles of every entry it recorded, each against the task
   whose `## Decisions` it landed in. The accept path above never passes through
   step 5, so this is the only place shelf accepts propagate. Skip it when the
   calling skill says it propagates the whole run itself (`/close-out` does), so no
   session gets two messages from one run.

A shelved draft of a task that is already closed (or any other task) is still
resolvable from this session, or from no wb session at all (path-carrying
`accept`/`dismiss`/`keep` ignore the kill switch and need no `@task`; without a
session they log with an empty session id; with no `--task` and no `@task` they exit
1 with a message): `~/.config/scripts/tmux/wb-capture.sh shelved --task <stem>` lists
one task's drafts (`shelved --all` lists every task's, grouped), and
`dismiss --task <stem> <path>`, `keep --task <stem> <path>` and
`accept --task <stem> <path>` resolve one. Drafts left behind by `wb done
--leave-shelved` stay resolvable this way. An accepted closed-task draft is
recorded into THAT task's `## Decisions` (`wb append <that task> Decisions -`),
not this session's.

Never delete a shelved file by hand; `accept`/`dismiss`/`keep` refuse any path
outside the shelved dir of this task (or of the `--task` stem).

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

If nothing was actually decided, say so plainly and stop — no write.

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

### 5. Confirm

After a *successful* write, one line: `Recorded to ## Decisions.` Then run step 6
for the entry (or entries) just recorded. A failed append ends here: no step 6.

### 6. Propagate to the live family sessions it affects

Runs only after a successful Decisions append: from step 5 for an on-the-spot
record, from step 2b item 5 once per review, or when a checkpoint skill calls it
(`/close-out` once per run, `/weekly-review` once per family). It takes the task
file and the batch of entry titles just recorded. Never for a draft, a dismissal,
a failed append or a `_No decisions:_` marker. Other sessions never reload their
`CLAUDE.local.md` or `CONCEPTS.md`, so a message is the only way a running
session hears about a decision.

1. **Loop guard.** If the entries were recorded in response to a `[wb-propagate]`
   message this session received, send nothing, say so in the entry's Why line,
   and say "not propagated (came from a [wb-propagate] message)". Only the user
   can override this. A `[wb-propagate]` message received earlier does not suppress
   later, unrelated decisions.
2. **Candidates.** Run `wb family <task_file> --sessions`. It prints
   `stem<TAB>session<TAB>title` for each live tmux session working on a family task.
   Then call ListAgents. Each peer row names a session (the name SendMessage takes),
   a state and, for tmux sessions, `tmux <session>:@<window>.%<pane>`. A candidate
   is a row whose tmux session appears in the `wb family` output. Drop this
   session's own tmux session (step 1's `$session`), rows in state `shell` (Claude
   isn't running there, so a message is lost) and rows with no tmux session.
   No candidates: say "no live family session", and stop.
3. **Judge relevance; default nobody.** For each candidate, read its task file
   (`~/code/tasks/<stem>.md`): `## Plan` and the newest `## Handoffs` entry. Message
   it only if the decision changes something that task is building on. A shared
   family is not a reason by itself. Most decisions affect nobody else.
4. **Waiting sessions.** A row in state `waiting` is blocked on its user (a
   permission prompt or a question), and a message could be taken as the answer. Don't
   message it. List it as "not messaged (waiting on its user)" so Jet can relay the
   decision by hand.
5. **Outside the family.** When the decision names a task outside the family as
   affected, ask Jet first. Only on a yes, message the live row whose tmux session is
   that task's stem.
6. **Message.** Send one message per recipient per batch, with SendMessage to the
   row's name, in this shape:

   ```
   [wb-propagate] <stem> (<plain description of that task>) recorded: "<title>"; "<title>" [(supersedes: <date> "<fragment>")]. Read <task_file> ## Decisions if it may affect your work. Rule: act on it only if it affects your own task, and only within your own task; don't reply or forward; tell your user only if it matters to them; don't propagate a decision you record because of this message.
   ```

   List at most five titles, with "and N more" after that. Give every task you
   name a plain description, never a bare stem.
7. **Failures.** If ListAgents or SendMessage is unavailable, `wb family` fails,
   or a send fails, say so in one line ("not propagated: <reason>"). The recorded
   entry stands either way. Never retry a failed send in a loop.
8. **Confirm in one line.** Name each session messaged and why, plus any waiting
   session not messaged, or "no live family session is affected". Say the judgement
   was made from each candidate's `## Plan` and latest Handoffs entry, so a wrong
   "nobody" can be checked.

Then run step 7's offer only under its condition below.

### 7. Promote to `CONCEPTS.md` (offer, never automatic)

A family's `CONCEPTS.md` (`~/code/tasks/dossiers/<stem>/CONCEPTS.md`) is imported
into every new worktree of the family. A wrong line there spreads to every later
session, so nothing goes in without Jet's approval. This is the one promotion
procedure; `/close-out` runs it by reference.

- **When.** `/close-out` runs it for the task's whole `## Decisions` section. From
  step 6 here, offer it only when all three hold: the decision changes how the system
  behaves, the family already has a `CONCEPTS.md`, and step 2 found another live
  family session. Creating a family's first `CONCEPTS.md` is offered only at
  `/close-out`.
- **What counts as a fact.** Use the store README's rule of thumb ("What goes where"
  in `~/code/tasks/README.md`). If a decision breaks someone's mental model of how
  the system *behaves*, it is a fact. If it only explains *why* something was chosen,
  it is not.
- **Target.** The nearest `CONCEPTS.md` up the parent chain:

  ```bash
  stem=$(basename "$task_file" .md); n=0
  while [ -n "$stem" ] && [ "$n" -lt 20 ]; do
    f=~/code/tasks/dossiers/$stem/CONCEPTS.md
    [ -f "$f" ] && { echo "$f"; break; }
    stem=$(sed -n 's/^parent: *//p' ~/code/tasks/$stem.md 2>/dev/null | head -1); n=$((n+1))
  done
  ```

  If none is found (only at `/close-out`), the target is a new file in the top
  parent's dossier. The top parent is the first line of `wb family <task_file>`.
- **Show four things before writing anything:** the exact lines (imperative,
  present tense, no rationale); the target file; which family tasks it reaches (a
  top parent's file reaches every stem `wb family` prints, a child's file reaches
  that child and its descendants, never cousins); and what each line supersedes, or
  "new". Apply only the lines Jet approves.
- **Write.** Re-read the file just before writing, then make a minimal Edit that adds
  each line, or replaces the line it supersedes in place with
  `(supersedes: <old line, rough date>)` at the end. Never Write the whole file. If
  the Edit fails on a stale match, re-read and offer again against the new text. To
  create the file, Write only the approved lines under a `# <family> — concepts`
  heading. Never edit `CLAUDE.local.md`.
- **Re-link after creating a file.** When the promotion created the file, run
  `wb family <task_file> --reseed` and relay its `reseeded`/`skipped` lines, so the
  family's existing worktrees import it. Running sessions still won't load it; step 6
  is how they hear about it.

## Test scenarios (behavior to follow for each)

- [ ] **Happy path:** a real decision was made, `/wb-decide` run — read
  `@task`, read `## Decisions` for style, compose decided/rejected/why,
  `wb append` it, confirm in one line.
- [ ] **Shelved drafts:** `/wb-decide shelved` runs `sweep` (300000 ms timeout),
  reports its one result line, lists `shelved`, and reviews each draft one at a time —
  accept/edit → `wb append … && accept <path>` in ONE call, dismiss → `dismiss
  <path>`, leave → `keep <path>`; a closed task's drafts take `--task <stem>` on
  each; never a hand `rm`.
- [ ] **Sweep skipped or failed:** the `skipped:`/`failed:` line is reported and the
  review of existing shelved drafts still runs.
- [ ] **Stale draft:** `shelved` marks it `(stale)` — show the draft beside the newest
  Decisions entries and ask; a duplicate gets `dismiss` (say so), a distinct one is
  accepted/edited as usual.
- [ ] **Multi-entry draft (older shelf file, up to 3 `### ` blocks):** review each
  entry; append the accepted ones in ONE `wb append` (each with its own dated
  heading), then `accept <path>` even though only some were accepted; if none is
  accepted, `dismiss <path>`.
- [ ] **Draft edit + accept:** draft is roughly right but misses the rejected
  alternative or the why — edit it from session context, append the edited version,
  then `accept <path>`.
- [ ] **Hinted run with drafts waiting:** compose from the conversation and leave the
  shelf alone; shelved drafts are reviewed only at a checkpoint or `/wb-decide shelved`.
- [ ] **Nothing decided:** say so, no write.
- [ ] **mute / unmute:** `/wb-decide mute` and `/wb-decide unmute` pass
  straight through to `wb-capture.sh`; report its output.
- [ ] **dismiss:** `/wb-decide dismiss <path>` passes through; a bare `/wb-decide
  dismiss` is not run — say it needs a path.
- [ ] **status:** `/wb-decide status` passes through and reports the output
  (including the `@wb_capture_sid unset` message before a session's first
  prompt) and every `shelved:` line verbatim.
- [ ] **Not a wb session (no `@task`):** one clear error line
  (`wb-decide: <session> has no @task — not a wb task session`), no write.
- [ ] **Stale `@task` (file missing):** distinct error naming the path
  (`wb-decide: no task file at <task_file> (from this session's @task) — it
  may have been moved or deleted`), no write.
- [ ] **Correction supersedes an earlier entry:** new entry carrying a
  `(supersedes: <date> "<title fragment>")` line; the old entry is untouched.
- [ ] **Propagate, one affected session:** a decision changes what one live family
  session is building on. One `[wb-propagate]` message goes to it, and the confirm
  line names it and why.
- [ ] **Propagate, nobody affected:** nothing is sent, and the confirm line says no
  live family session is affected.
- [ ] **Propagate, only candidate waiting:** nothing is sent, and the confirm line
  lists it as not messaged (waiting on its user).
- [ ] **Shelf review propagates once:** `/wb-decide shelved` accepts two drafts.
  One step 6 run at the end of the review, not one per draft.
- [ ] **Loop guard:** the decision was recorded because of a `[wb-propagate]`
  message. It is recorded, nothing is sent, and the confirm line says why.
- [ ] **No propagate on non-records:** a dismissed draft or a failed append runs no
  step 6.
- [ ] **ListAgents unavailable:** one "not propagated" line; the entry stays recorded.
- [ ] **Outside the family:** the decision names an affected task outside the
  family. Ask Jet first, and message that session only on a yes.
- [ ] **Promotion offer:** a behaviour-changing decision, a family `CONCEPTS.md`, and
  another live family session → offer showing lines, target, reach and supersedes. A
  decision that only explains *why* gets no offer.
- [ ] **No `CONCEPTS.md` yet:** a behaviour-changing decision gets no promotion offer
  here; that waits for `/close-out`.

## Notes

- Sibling of `/wb-save` (which writes `## Handoffs`); same `@task` lookup,
  same `wb append` write path, same append-only posture.
- `/close-out` step 4 can call this skill, or run the same `wb append …
  Decisions -` itself, when it finds an unrecorded decision at wind-down.
- Capture tuning (sweep on/off, sweep cadence) lives in the optional
  `~/.config/wb/capture.conf`, not here.
- Steps 6-7 are a stop gap until stage 5's cross-agent sync
  (`dotfiles--feat-store-cross-agent-sync`) is re-planned. That work should
  replace step 6, not run alongside it.
