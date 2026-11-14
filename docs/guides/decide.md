---
title: decide
status: current
tile: Ask Jet a batch of questions on an nvim buffer or a claude.ai page, wake the session on his answer, and record each answer in the task.
group: skills
kind: guide
updated: 2026-11-14
---

## Overview

`/decide` is the one way to be asked several things at once. The agent first
agrees the direction in chat, then puts the open points on the surface that
fits: an **nvim buffer** in a tmux split (a handful of choices, a
code-review triage, a run-and-paste loop) or a private **claude.ai page**
(options with evidence, more than about six items, a shared-verdict audit, or
answers from your phone). When you finish, the session wakes, reads the
answers, and records each one in the task's `## Decisions` through
`wb decision`. It replaces `decision-buffer`, `decision-page` and
`review-page`; what those three taught is folded into the one skill.

**The headline contract:** an item you did not touch is *unanswered*, never
silently filled in from the recommendation, and no option is ever pre-ticked.
A buffer that closes unchanged applies nothing. A stated default is taken only
when you answered other items in the same batch, and the entry then says
"Default taken."

## When to use it

| The questions are... | Surface |
|---|---|
| a handful of choices or free-text answers (about six or fewer), a small code-review triage | buffer |
| a run-and-paste loop (you run commands elsewhere and paste output) | buffer |
| options with tables, code or evidence, more than about six items, or answered away from the terminal | page (`items` layout) |
| every item takes one shared verdict list (a triage, an audit, a prune list), about 15 or more | page (`verdicts` layout) |
| a paste loop that needs visuals | both |

The shape of the answer picks the surface, not a trigger phrase; "a buffer"
or "a page" in your own words overrides the table. A page past about 25 rich
items is split by group. One question, or a trivial one, stays in chat.

## The buffer and the page

**The buffer.** `wb decide-path` prints a fresh answer file under the task's
dossier `decision-records/`; the agent writes the questions into it (Questions,
Interview, Code-review triage or Run and paste shape) and runs
`wb decide-buffer <file>` in the background. That opens nvim in a split of the
task's tmux session and blocks until you `:wq`. The command reports
`changed: yes|no`; unchanged means nothing is applied.

**The page.** The agent writes a JSON spec in the dossier
(`wb decide-path --page <slug>`), checks it with `wb decide-spec-check`,
publishes the shared page template as a private claude.ai artifact, and hands
you the link. Answers save as you click, so you can stop halfway and finish
elsewhere. Nothing is coloured until you pick; evidence sits one click away.
Press **Submit** when done (if the session does not pick it up, type `done`).

## How answers come back and get recorded

The buffer's close, or the page's Submit, wakes the session. It reads the
answer file or the page's answer documents (never a paste or memory), answers
any Questions/Notes first, then records one decision per item with
`wb decision "<title>" <<'ENTRY' ... ENTRY`. The same title again supersedes
the live record (the old one stays, marked superseded); an identical body
writes nothing. A `verdicts` page records one summary decision per round.
After a batch, decisions you made yourself are propagated once to the live
family sessions they affect (the `/wb-decide` propagation step); defaults
taken are not. The raw answer file stays in the dossier as the audit trail, but
the entry in Decisions is the record. A second round rewrites the surface
fresh, with resolved items collapsed into a short summary.

## The needs-you mark and surviving a /clear

While a surface is open, the tmux picker marks the task as **needing you**,
so you can find the waiting question from any session. The mark clears when
every surface from the batch is recorded (`wb decide-clear`). `/wb-save` lists
any open buffer or page in its handoff, and `/wb-resume` reopens the buffer
(re-running `wb decide-buffer <file>` attaches to a split still open, or reports
`changed: yes` when the file changed while the session was gone) and re-arms
the page's watch.

## Try it now

```
/decide
```

Or say "put these in a buffer" or "put these on a page" after the agent has
laid out what is open and which way it leans.

## Reference

| Command | What it does |
|---|---|
| `wb decide-path [--page <slug>]` | Prints a fresh reserved answer file (or a page spec path, folder created) under the task's dossier `decision-records/`. |
| `wb decide-buffer [--reopen] <file>` | Opens the file in an nvim split of the task's tmux session, marks the task as needing you, blocks until you close it; prints `file:`, `sha:`, `changed:`. Re-running it reattaches; `--reopen` opens the next round of a file the session rewrote. |
| `wb decide-open page <url> <rev>` | Records a published page (and its revision) as an open surface. |
| `wb decide-spec-check [--previous <spec>] <spec>` | Checks a page spec before publishing; `--previous` also checks that saved answers still match the earlier rev. |
| `wb decision "<title>"` (body on stdin) | Records one answer in `## Decisions`; `--default` marks it "Default taken." and never supersedes an answer you gave. |
| `wb decide-clear <file or url>` / `--all` | Drops the needs-you mark for a recorded surface, or for every surface when a batch is abandoned. |

The skill lives at `claude/.claude/skills/decide/` (`SKILL.md`, with
`references/` for the buffer shapes and the page spec, and `learnings.md`
for what you flagged as unhelpful). The page template is shared with
`compare-page` under `claude/.claude/skills/compare-page/kit/`.

## Known rough edges

- Publishing the page and holding its watch happen in the main session only; a
  subagent cannot hold an artifact watch.
- If the page's auto-reply says "recorded" it has not: the session writes the
  task file, not the page.
- Outside a wb task there is no Decisions section; answers are recorded where
  the work keeps its notes, and the surface belongs to the tmux session.

## Next steps / reverting

Flag anything unhelpful or confusing and it lands in `learnings.md`. The three
retired skills' guides ([decision-buffer](decision-buffer.html),
[decision-page](decision-page.html), [review-page](review-page.html)) stay as
history. To bypass for one decision, say "just ask in chat".
