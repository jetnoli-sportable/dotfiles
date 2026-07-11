---
name: wb-board
description: Pull up the task-store status table from inside a Claude Code session — default invocation shells out to `wb board` and relays its plain-text table inline, unmodified, in a fenced code block; asking for the html/detailed/full view shells out to `wb board --html` and reports back the absolute `logs/board.html` path it prints (never opens a browser). Use when the user types `/wb-board`, says "show me the board", "what's the task board look like", "what am I working on across repos", or asks for the html/detailed/full board view specifically. Named `/wb-board` (not `/board`) for consistency with the sibling `/wb-save`, `/wb-resume`, `/wb-done` skill family — no `/board` skill exists elsewhere in this repo; "/board" has only ever meant the underlying `wb board --html` feature in the docs.
---

# wb-board

`/wb-board` is a thin relay: shell out to `wb board` (default) or `wb board
--html` (when asked for the detailed/html view) and hand back exactly what
that command printed — no reformatting, no summarizing, no inventing output
it didn't produce. See `cmd_board`
(`scripts/.config/scripts/tmux/wb.sh:1486-1532`) for what each mode actually
does; this skill has no logic of its own beyond picking which of the two to
run and how to relay it.

## When this applies

- `/wb-board` with no argument, or a plain-language ask like "show me the
  board", "what's the task board look like", "what am I working on across
  repos" — default (plain-text) mode.
- `/wb-board html`, or an ask that names "html", "detailed", "full board",
  "board detail" — HTML mode. Treat these as example phrasings, not an
  exhaustive list — judge intent the same way the sibling skills do.

## What to do

### Default: plain-text table

Run:

```bash
wb board
```

Relay stdout back to the user **verbatim, wrapped in a fenced code block**
— the output is `column -t`-aligned, and a code block is what keeps that
alignment monospace/legible. Don't re-sort rows, don't drop the
`FOLLOW-UPS` column, don't summarize ("3 tasks are doing, 1 is paused")
instead of showing the table itself — relay the table.

**Empty store:** if there are no task files, `wb board` doesn't print a
table at all — it prints a single line, `wb board: no tasks in
<TASKS_DIR>`. Relay that line as-is (still fine to fence it). Don't treat
it as a failure, and don't fabricate an empty-looking table in its place.

### HTML / detailed view

Run:

```bash
wb board --html
```

This regenerates `logs/board.html` at the dotfiles repo root (gitignored,
overwritten on every call — that's expected) and prints exactly one line,
`wb board: wrote <absolute path>`. Relay **that path**, not the file's
contents — e.g. "Wrote the board to
`/home/jetnoli/code/dotfiles/logs/board.html`." Do not try to open it
(`xdg-open`, a browser tool, etc.) — no browser-launching primitive is
assumed available here; reporting the path is the whole job.

## Notes

- Read-only both ways — `wb board`/`wb board --html` never touch the task
  store or git state (`cmd_board`, `wb.sh:1486-1532`), and this skill adds
  no side effects of its own.
- Named `/wb-board`, not `/board` — no `/board` skill exists anywhere in
  this repo today; "/board" up to now has only ever meant the underlying
  `wb board --html` feature as described in `docs/roadmap.md` /
  `docs/roadmap-board.md`. This is the first time it becomes an actual
  slash command, deliberately named to match the sibling `/wb-save` /
  `/wb-resume` / `/wb-done` skill family rather than reusing the bare
  feature name.
- Never reformat or re-derive a table from `wb board`'s output — this
  skill's entire value is a byte-faithful relay of a command that already
  does the formatting.
