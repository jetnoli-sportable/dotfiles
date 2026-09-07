---
title: Try it — a live catalog of what you can actually run
status: current
tile: One row per roadmap feature that has a real, runnable example — command and expected result lifted straight from that feature's own guide or recap. Auto-generated; never hand-edit — rerun build-try-it.sh + docgen.sh.
group: where-we-are
kind: page
updated: 2026-08-31
---

Generated from [the roadmap](roadmap.html): every item there that links to a
doc carrying its own `## Try it` / `## Test it` section contributes one
row here, with the command and the one-line "expect" lifted verbatim from
that doc — nothing below is hand-typed. Regenerate with
`scripts/.config/scripts/build-try-it.sh` (runs automatically before
`docgen.sh` via `.githooks/pre-commit`). A feature missing here just
means its linked doc doesn't carry a fenced Try-it command yet, not that it
isn't real — check the roadmap for its actual status.

| Feature | Status | Try it | Expect |
|---|---|---|---|
| `wb` core | Built | `tmux source-file ~/.config/tmux/tmux.conf` | — |
| `/handoff` | Built | `/handoff` | The skill infers `repo`/`slug` from context (checking `~/code/tasks/` for a |
