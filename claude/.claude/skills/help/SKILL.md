---
name: help
description: Answer "why do I have binding X", "what does Y do", "how do I use Z" questions about the personal workflow with provenance, not grep — reads the generated docs/INDEX.md in ~/code/dotfiles, follows source/guide links (including decision records for "why" questions), and cites file:line. Use when the user types /help <question>, or asks why a keybind/alias/skill exists, what a workflow piece does, or how to use one. Deterministic lookup twin: the prefix+? tmux picker (help.sh).
---

# Help — Q&A over the workflow INDEX

Answer questions about the personal workflow (tmux binds, zsh aliases and
functions, scripts, Claude skills, TUIs, docs, decisions) from the generated
INDEX, with citations. This is the reasoning half of the help system; the
deterministic half is the `prefix+?` fzf picker (`help.sh`), which does
lookup without an LLM.

## When this applies

- The user types `/help <question>`.
- The user asks a why/what/how question about their own setup: "why do I
  have binding X", "what does Y do", "how do I use Z", "where is W defined".

## What to do

1. **Read the INDEX first**: `~/code/dotfiles/docs/INDEX.md`. The fenced
   ` ```jsonl ` block is the machine half — every entry carries `id`, `kind`
   (bind | alias | function | script | skill | tui | doc | decision),
   `name`, `oneliner`, `source` (path:line), `invoke`, `guide`, `tags`.
   Repo-relative sources resolve under `~/code/dotfiles/`; `~/` sources
   resolve under `$HOME`.
2. **Match the question to entries** by name, invoke, oneliner, and tags.
   Then **follow the links** — never answer from the oneliner alone:
   - *what / how* questions: open the entry's `source`, and its `guide`
     page's markdown sibling when one exists (`docs/*.html` → `docs/*.md`,
     `docs/guides/*.html` → `docs/guides/*.md`). For skills read the
     SKILL.md; for TUIs the README.
   - *why* questions: provenance lives in `kind: decision` entries —
     `logs/decisions/*.md` records and task-store `## Decisions` sections
     (`~/code/tasks/*.md`) — plus the comment block at the entry's `source`
     line. Quote the deciding line, not a paraphrase.
3. **Answer in chat, citing `file:line`** for every claim (the INDEX's
   `source` field gives the anchor; cite the deeper file you actually read
   when you followed a link). Keep it short: what it is, why it exists (if
   asked), how to run it (`invoke`), where to read more (`guide`).
4. **No match: say so** — name the 2–3 nearest entries (closest name/tag
   matches) so the user can redirect. **Never invent** an entry, binding, or
   rationale that isn't in the INDEX or its linked sources. If the INDEX
   looks stale or missing, say that and point at `docgen.sh index`.

## Notes

- The INDEX is generated (`docgen index`) — treat it as the map, not the
  territory: the `source` files it points at are the truth to quote.
- Employer-repo content is deliberately withheld from the INDEX (redaction
  guard); if a question runs into that wall, say the entry is out of scope
  for the personal INDEX rather than guessing.
- This lookup shape (INDEX read → source-follow → cited answer) is the same
  machinery roadmap 9e "task recall" will reuse — keep answers grounded in
  entries + files so that pattern stays reliable.
