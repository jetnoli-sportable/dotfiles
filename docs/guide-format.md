---
title: Guide format — the shapes a skill/TUI guide page follows
status: current
tile: The single-skill 5-section shape, and the command-family alternate — which to use, and how docgen finds either.
group: workflow
kind: page
updated: 2026-07-14
---

`docs/guides/*.md` pages already converge on a shape without being told
to — this page names it, so the next new guide follows it on purpose
instead of by accident, and covers the one alternate shape that's
equally real: one page documenting a whole command family.

## The standard shape: single-skill guide

Five sections, in this order, followed exactly by `decision-buffer.md`,
`notes-tui.md`, `parked-items.md`, `park.md`, `pr-review-session.md`, and
`replay-tui.md`:

1. **Overview** — what the thing is, one paragraph.
2. **Try it now** — the shortest real invocation that produces output,
   copy-pasteable.
3. **Reference** — the full command/flag surface, usually a table.
4. **Known rough edges** — real gaps and their scope, not hidden.
5. **Next steps / reverting** — what's next for this feature, and how to
   turn it off if it doesn't work out.

This is the default for any new single-skill guide. Two existing pages —
`claude-tmux.md` (six module-specific sections) and `tasks-store-guards.md`
(a coverage matrix + three runbooks) — flex the shape for genuine depth
rather than deviating by accident: both are reference docs for a
multi-part subsystem, not a single command. Reach for that flex only when
a subsystem genuinely doesn't fit five sections, not as a default.

## The alternate shape: command-family guide

`wb-guide.md` and `handoff-guide.md` don't document one skill — they
document a family of related subcommands (`wb new`/`wb done`/`wb
breakdown`/`wb board --html`, or the whole `/handoff` surface) on one
page, each subcommand getting its own `##`/`###` section rather than its
own file. Use this shape when a set of skills are tightly coupled enough
that reading them separately would mean constantly flipping between
pages — the same judgment call already made for `wb-guide.md`.

## How docgen finds either shape

docgen's indexer resolves a skill's `guide` field by checking
`docs/guides/<skill-name>.html` — the single-skill shape lands there and
needs no config. A command-family guide doesn't live at that
conventional path (it's a different filename entirely, and possibly not
even in `docs/guides/`), so it needs an explicit override in
`docs/docgen.json`'s `skills` index source, `guideOverrides`:

```json
{ "kind": "skills", "path": "claude/.claude/skills", "guideOverrides": {
  "wb-done": "docs/wb-guide.html#wb-done--wind-down-safely",
  "handoff": "docs/handoff-guide.html"
}}
```

Point at an in-page anchor (`#section-id`) when the family guide covers
several skills and each has its own subsection; point at the bare page
when one guide is entirely about one skill (`handoff-guide.md` has no
`#handoff` anchor and doesn't need one). An override pointing at a path
that doesn't exist on disk resolves to no guide, the same as a skill with
no guide at all — never a silently dead link.
