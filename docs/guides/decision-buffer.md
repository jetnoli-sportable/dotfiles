---
title: decision-buffer
status: current
tile: Design decisions through an nvim buffer instead of a chat menu.
group: skills
kind: guide
updated: 2026-07-07
---

## Overview

When an agent is about to present two or more non-trivial design options, it
writes a markdown decision doc and opens it in nvim **where you already are**
(a tmux split), instead of firing an `AskUserQuestion` chat menu. You react
in the editor — check boxes, strike lines, write notes inline — and closing
the buffer hands control back: the edited doc *is* your answer.

Why: decisions with real options are easier to weigh in an editor than in a
menu, and the doc doubles as a durable decision record (`docs/decisions/` in
repos that keep one, `logs/decisions/` scratch otherwise).

## Try it now

1. In any Claude Code session, get to a fork in the road and say
   **"open a buffer for this"** or **"decision doc"** — or just let the
   agent hit a 2+-option design choice; the skill fires on its own.
2. A tmux split opens with the doc in nvim. Read the Context, then:
   - mark the option you want: `- [x] **Choose Option A**`
   - write questions inline or under any *Questions / Notes* section
3. Save and close (`:x`). The split closes, the agent wakes up, answers
   your notes first, then proceeds on the checked option.

## Reference

| You do | Agent does |
|---|---|
| Check exactly one option, no notes | Proceeds on it immediately |
| Write questions/notes anywhere | Answers them **before** acting |
| Check multiple options | Asks whether staged/combined or accident |
| Check nothing, note nothing | Asks in chat what held you back |
| Ask for another round | Edits the same doc in place (answers appear as `> **answer:**` quotes) |

Doc structure the agent must produce: `## Context` (with `file:line` facts),
per-option `### Option X` blocks with a Choose checkbox, inline code from the
real codebase, pros/cons, then `## Recommendation` and `## Questions / Notes`.
**Multi-decision docs carry a `### Questions / Notes` subsection under every
decision** — not one notes section at the end (user rule, 2026-07-06).

## Known rough edges

- The buffer blocks the agent until you close it — the pane shows a working
  spinner meanwhile. The `@claude_blocked` pane marker keeps the `wb` picker
  honest about it ("needs you", not "working").
- Wait-channel names must be unique per open; a stale fixed channel makes
  the agent return before you've touched the buffer. Fixed in the skill —
  worth knowing if a buffer ever "answers itself".
- Outside tmux it falls back to `gnome-terminal --wait`, then to printing a
  manual `! nvim <path>` command.

## Next steps / reverting

- Finalized decisions in `docs/decisions/` get a `**Decided:** Option X`
  line; scratch docs in `logs/` need no upkeep.
- To bypass for one decision, say "just ask in chat". The skill is a file at
  `claude/.claude/skills/decision-buffer/SKILL.md` — unstow or delete to
  retire it entirely.
