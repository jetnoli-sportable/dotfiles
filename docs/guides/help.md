---
title: help
status: current
tile: Why-do-I-have-X / what-does-Y-do / how-do-I-use-Z, answered from the INDEX with citations.
group: skills
kind: guide
updated: 2026-07-14
---

## Overview

Answers questions about the personal workflow — tmux binds, zsh aliases
and functions, scripts, Claude skills, TUIs, docs, decisions — by reading
the generated `docs/INDEX.md` and following its links, never by grepping
cold. This is the *reasoning* half of the help system: it can chain
`source` → `guide` → decision records to answer a "why" question with a
quoted `file:line`, not just a lookup. The deterministic twin is the
`prefix+?` fzf picker (`help.sh`) — no LLM, straight index lookup;
`/help` is for when the question needs actual reasoning over that same
data.

## Try it now

In any Claude Code session:

```
/help why do I have prefix+m bound to the wb picker
```

The agent reads `docs/INDEX.md`'s JSONL block, matches the entry by name/
tag, follows its `source` line and any linked decision record, then
answers in chat with a `file:line` citation — never from the one-liner
alone.

## Reference

| Question shape | What gets followed |
|---|---|
| *what / how* | The entry's `source`; its `guide` page's markdown sibling when one exists (`docs/*.html` → `docs/*.md`); `SKILL.md` for skills, `README` for TUIs |
| *why* | `kind: decision` entries — `logs/decisions/*.md` and task-store `## Decisions` sections (`~/code/tasks/*.md`) — plus the comment block at the entry's `source` line; quotes the deciding line, not a paraphrase |
| No match | Names the 2–3 nearest entries by name/tag so you can redirect — never invents a binding, entry, or rationale that isn't in the INDEX or its linked sources |
| INDEX missing/stale | Says so and points at `docgen.sh index` |

Every INDEX entry carries `id`, `kind` (bind / alias / function / script
/ skill / tui / doc / decision), `name`, `oneliner`, `source` (path:line),
`invoke`, `guide`, `tags`. Repo-relative sources resolve under
`~/code/dotfiles/`; `~/`-form sources resolve under `$HOME`.

## Known rough edges

- **Only as current as the last rebuild.** The INDEX is generated
  (`docgen index`), not live — a binding added since the last
  `docgen.sh` run won't show up until the next one.
- **Employer-repo content is deliberately withheld** (the redaction
  guard) — a question that runs into that wall gets "out of scope for
  the personal INDEX," not a guess.
- **Reasoning, not search** — for a large-surface "find me everything
  matching X" sweep, the `prefix+?` picker's fzf fuzzy-match over every
  entry is often faster than a conversational round-trip.

## Next steps / reverting

- The deterministic twin, `prefix+?` in tmux (`help.sh`,
  `scripts/.config/scripts/tmux/help.sh`), is the fzf picker over the
  same `docs/INDEX.md` — Enter opens the thing (`xdg-open` for
  docs/guides, `nvim +line` for everything else), preview shows source
  context or a skill's own description. See [setup](../setup.html) for
  where it's introduced alongside the rest of the shell/terminal stack.
- Nothing to unwire: `/help` only ever reads `docs/INDEX.md` and its
  linked sources — it never writes anything.
