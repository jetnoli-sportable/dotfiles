---
title: decision-buffer
status: current
tile: Route decisions, reviews, and checklists through an nvim buffer instead of a chat menu.
group: skills
kind: guide
updated: 2026-09-09
---

## Overview

The decision-buffer skill routes work into a markdown doc you answer
asynchronously in nvim **where you already are** (a tmux split), instead of
blocking the turn on chat back-and-forth or firing an `AskUserQuestion` menu.
The trigger is no longer "two or more design options" — it fires whenever an
answer is needed **in writing, asynchronously, once direction is basically
agreed**: a settled choice between named approaches, sure, but also a
findings review, a clarifying interview, or a batch of facts to confirm.

The headline change from the old version: the agent **aligns in chat first**,
always. It presents findings and a proposed direction, and only opens a
buffer once you've confirmed something genuinely needs a written async
answer — never as the first move, even mid-task. If you reply with a
question instead, it's answered in chat, not folded into a freshly-opened
buffer.

Once aligned, the doc's shape depends on the kind of answer needed — six
shapes, each with its own header stating exactly what closing it with
nothing marked means:

| Shape | Used for |
|---|---|
| Choice | A settled decision between named options |
| Findings review | Reacting to claims: agree / disagree / dig deeper / out of scope |
| Clarifying interview | Free-text answers to open questions, agent states a default |
| Paste target | An async execute-and-paste loop |
| Confirm-facts | Ticking a small batch of true/false statements |
| Code-review triage | Apply / Defer / Skip per finding |

Why: a written answer is easier to weigh in an editor than in a chat menu,
and — for design choices specifically — the doc doubles as a starting point
for a durable decision record (`docs/decisions/` in repos that keep one,
`logs/decisions/` scratch otherwise; see "Next steps" below for what
"durable" actually means now).

## Try it now

1. In any Claude Code session, get to a point where an answer is needed in
   writing — a design fork, a findings review, an open question — and say
   **"open a buffer for this"** or **"decision doc"**, or let the agent
   reach that point on its own.
2. First, the agent aligns with you in chat: it states what it found and
   what it proposes, and asks whether the open points should go to a
   buffer. Answer directly, or say to go ahead.
3. A tmux split opens with the doc in nvim. Every shape's own header
   blockquote at the top tells you exactly what to do and what closing it
   with nothing marked means for that particular doc — read that first
   rather than assuming the old checkbox convention.
4. Save and close (`:x`). The split closes, the agent wakes up, answers any
   notes first, then proceeds on what you marked.

## Reference: the choice shape's close contract

The table below describes the **choice shape** specifically — the original
named-options decision, still the most common case. The other five shapes
each state their own close contract in their own header (loaded from
`references/shapes/*.md`); never assume the choice-shape table below applies
to a findings-review or confirm-facts buffer just because it looks similar.

| You do | Agent does |
|---|---|
| Check exactly one option, no notes | Proceeds on it immediately |
| Write questions/notes anywhere | Answers them **before** acting |
| Check multiple options | Asks whether staged/combined or accidental |
| Check nothing, note nothing | Asks in chat what held you back |
| Ask for another round | Rewrites the doc fresh (resolved decisions collapse to a summary, still-open ones keep full detail) |

Doc structure for a choice buffer: `## Decision N — <name>`, per-option
`### Option X` blocks with a Choose checkbox, inline code from the real
codebase, pros/cons, then that decision's **own** `### Questions / Notes`
subsection — directly under it, not one shared section at the doc's end.
Every shape carries this same "every question states why it's being asked
and which stage it belongs to" discipline, not just choice.

## Known rough edges

- The buffer blocks the agent until you close it — the pane shows a working
  spinner meanwhile. The `@claude_blocked` pane marker keeps the `wb` picker
  honest about it ("needs you", not "working").
- **Pane-gone vs. waiter-killed recovery.** If the background process
  waiting on your buffer dies for some unrelated reason (a killed shell, an
  agent restart) but your nvim pane is still open, the agent re-attaches to
  the **same** buffer next time it looks — no data loss, no second buffer
  opened alongside the one you still have open. If instead the pane itself
  is gone (closed out of band, not via `:x`), the agent does **not** guess
  what you meant: it tells you plainly that the close wasn't deliberate and
  reports whatever is on disk as **"unconfirmed"** rather than acting on any
  ticks or notes it finds there. These two cases used to be indistinguishable
  (a stale fixed wait-channel could make the agent return before you'd
  touched the buffer at all) — the buffer's open now records the actual tmux
  pane id, so the two cases are told apart for real, not guessed at.
- Outside tmux it falls back to `gnome-terminal --wait`, then to printing a
  manual `! nvim <path>` command.

## Next steps / reverting

- **The buffer itself is never the durable record.** Its wording is
  deliberately rough — written for a fast answer, not polished prose.
  Answers get folded into the task file or plan that's actually authoritative
  as soon as the buffer closes; nothing is ever cited back to the raw buffer
  file afterward. Where the raw file then goes depends on where it was
  opened: an employer-repo buffer (tracked `docs/decisions/` or gitignored
  `logs/decisions/`) stays right where it is, with a one-line "Folded into:
  `<path>`" note; a buffer opened in **this** dotfiles repo's
  `logs/decisions/` moves into the current task's dossier under
  `decision-records/` instead; a buffer already written inside a dossier is
  left as-is.
- To bypass for one decision, say "just ask in chat". The skill lives at
  `claude/.claude/skills/decision-buffer/SKILL.md`, with its mechanism
  (`references/mechanism.md`) and shapes (`references/shapes/*.md`) as
  separate files the skill loads on demand — unstow or delete the whole
  directory to retire it entirely.
