---
title: park
status: current
tile: <10s capture of a "deal with this later" item.
group: skills
kind: guide
updated: 2026-07-07
---

## Overview

Zero-ceremony deferral: one JSON line appended to a global ledger
(`~/.claude/parked-items/ledger.jsonl`), stamped with cwd and git branch so
the weekly review can route it later. Exists so "let's discuss this later"
doesn't evaporate when the conversation ends. Capture half of the pair —
[parked-items](parked-items.html) is the review half.

## Try it now

In any Claude Code session:

```
/park try out the new help picker on a real question
```

The agent confirms in one line: `Parked: "…" (dotfiles @ docs/…). It'll show
up in /parked-items.` That's the whole flow.

## Reference

| Trigger | Behavior |
|---|---|
| `/park <note>` | Appends the note verbatim |
| `/park` (no argument) | Agent summarizes the thing under discussion into a one-liner |
| Saying "park this" / "revisit later" / "make a follow-up task for this" in passing | Agent captures proactively and tells you in one line |

Ledger entry shape: `{ts, cwd, branch, note, status:"open", source:"manual"}` —
append-only; status changes (`done`/`dropped`) happen in the weekly review,
never here.

## Known rough edges

- Capture is deliberately dumb: no dedupe, no editing, no categorization at
  park time. If you park the same thought twice, the review dedupes it.
- If something needs action *now*, don't park it — the skill itself will
  refuse the detour and just do the work.

## Next steps / reverting

- Review parked items weekly with [/parked-items](parked-items.html).
- The ledger is a plain file — `cat` it, back it up, or delete a line by
  hand if something should never resurface. Skill source:
  `claude/.claude/skills/park/SKILL.md`.
