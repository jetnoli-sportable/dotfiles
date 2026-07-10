---
date: 2026-07-09
topic: hub-v0
---

## Summary

Hub v0 extends the existing docgen/Hub pipeline with six pieces of
meta-documentation about the personal workflow itself: a glossary, a
two-tab artifact index (auto-scanned, with optional hand-written
overrides), a curated limitations page, a hand-maintained left-to-right
roadmap visual alongside the existing table, a `/board` Hub tile, and a
standalone ceremonies page. All six ship in one PR. The artifact index is
the one piece that reaches into the separate `~/code/docgen` tool repo
(extending its existing scan-and-derive parsers to drive a real page); the
roadmap visual stays hand-authored specifically to avoid a second such
change.

## Problem Frame

Several small gaps accumulated across the docs platform and prior PRs: the
same jargon (frontmatter, worktree, task store, tile, sidecar) gets
re-explained inline every time it comes up rather than defined once; every
one-off doc this workflow generates (decision-buffer companions, PR
recaps, brainstorm/plan outputs) has no central index; known gaps and
caveats are scattered across recap pages and `docs/roadmap-open-questions.md`
with no single browsable view; the roadmap's Overview table conflates
"needs a slot" follow-ups with "parked at the end" deferred items, because
that distinction lives only in a human's judgment each time a row changes;
the already-shipped `wb board --html` output isn't reachable from the Hub;
the roadmap's dated clocks require asking what they mean instead of
reading it; and docgen structurally cannot detect staleness for the
handful of sources — memory, the task store, other repos' READMEs — that
live outside this repo's git tree.

## Key Decisions

- **Audience is future-me, mainly.** Shapes tone and depth for the
  glossary, limitations, and ceremonies content — not written defensively
  for a cold agent session with no shared context.
- **Artifact index scope is one-off docs only, in a two-tab view,
  auto-scanned rather than hand-maintained.** Canonical living pages
  (`roadmap.html`, `wb-guide.html`, `docs/guides/*`) already have Hub tiles
  via their own frontmatter and are excluded from the default tab; a
  second tab adds them in for whoever wants the exhaustive view. Both tabs
  are discovered automatically (reusing docgen's existing scan-and-derive
  pattern already used for `INDEX.md`); each artifact's description is
  auto-derived from its own content by default, with an optional
  hand-written override when the auto version reads awkwardly — never a
  required step, so nothing can silently fall out of date by being
  forgotten.
- **Limitations is a curated, standing-constraint list, not a mirror of
  every backlog item.** Three of `docs/roadmap-open-questions.md`'s five
  entries (the GPaste/Sway coupling, the warn-only credential guard,
  GPaste's no-expiry clipboard history) get promoted in because they
  explain surprising behavior by design; the other two (a re-confirmed
  notes-corpus decision, a fully-resolved trace) stay where they are as
  process record, not limitations.
- **The roadmap visual is hand-authored, same as the table it sits
  beside.** Considered a data-driven approach (one structured source
  generating both views), but most current roadmap rows don't correspond
  to a task-store file — retrospective groupings and unstarted proposals
  have no file to generate from — so real generation would silently drop
  most of today's table rather than reproduce it faithfully. Full
  generation is real future work once the task parent/child relationship
  (below) and a `/board`-driven roadmap view exist; for now this page
  stays entirely hand-maintained, and Hub v0 never touches the separate
  docgen tool repo as a result.
- **Static hints over computed checks, twice.** Both the `/board` tile and
  the cross-repo staleness note use a plain, always-true hint rather than
  a computed flag — in each case, the computed version couldn't tell you
  more than the plain fact already does.
- **Ceremonies gets its own standalone page.** Not folded into the
  roadmap, so it has room to grow into future recurring reviews beyond the
  three dated clocks that exist today.
- **The task parent/child relationship is fully designed but ships
  separately.** Raised mid-brainstorm as a related concern (full-stack
  work spanning a `be--monorepo` worktree and a `frontend` worktree tied
  to one unit of work) and resolved in the same session, but it's real new
  application behavior (a task-store schema field, `wb.sh` session
  handling, two renderer changes) distinct in kind from Hub v0's
  documentation-only scope — see Scope Boundaries.

## Requirements

**Glossary**

- R1. A new page renders one canonical explanation per recurring term
  (frontmatter, transcript, ledger, worktree, task store, tile, sidecar,
  INDEX entry, decision buffer, etc.), seeded from a sweep of current docs.
- R2. The page uses a sticky-table-of-contents layout so individual terms
  are directly jump-to-able.

**Artifact index**

- R3. A new page lists one-off generated docs — decision-buffer
  companions, brainstorm/plan outputs, PR recap pages — each with a link,
  a one-line description, and why it was generated. Discovery is
  automatic; descriptions are auto-derived from each file's own content by
  default, with an optional per-artifact hand-written override.
- R4. The page offers a second view that additionally includes canonical
  living pages already reachable via their own Hub tile.
- R5. The default view excludes canonical living pages; only the
  one-off-only view is the entry point.

**Limitations**

- R6. A new page lists standing, by-design properties of the workflow that
  explain otherwise-surprising behavior — e.g. the credential guard being
  warn-only and filename-only, GPaste's GNOME-Shell coupling, GPaste's
  clipboard history having no expiry or secret detection.
- R7. The personal/employer boundary rule gets a one-line pointer into this
  page; its full writeup stays on its existing dedicated page.
- R8. The page notes that the task parent/child relationship is designed
  but not yet built, covering the interim between Hub v0 shipping and that
  follow-on PR landing.

**Roadmap visual**

- R9. A new left-to-right visual sits alongside the existing Overview
  table on `docs/roadmap.md`, hand-authored and kept in sync by hand — the
  same page, the same Hub tile, genuinely reworked to house the visual
  well rather than a section bolted onto the unchanged page.
- R10. Each item on the visual is categorized (active / follow-up /
  deferred) rather than leaving the distinction to prose judgment.
- R11. The Overview table's rendered content — including Done rows — is
  unchanged by this work.
- R12. Where the currently-unplaced items (Task Recall, "Unify
  copy/paste") land on the new visual is resolved when the visual is
  actually built, not pre-decided here.

**`/board` tile**

- R13. The Hub gets one tile linking to the already-shipped `wb board
  --html` output, with tile text that sets the expectation that the file
  is generated on demand.

**Ceremonies**

- R14. A new standalone page tracks the three existing dated clocks
  (with their rationale) and has room to track future recurring reviews as
  they appear.
- R15. When a dated clock's date passes and gets resolved, it moves to a
  compact "resolved" sub-list on the same page rather than being deleted.

**Cross-repo staleness**

- R16. The Hub carries a static note that sources living outside this
  repo's git tree (memory, the task store, notes-tui/replay-tui READMEs)
  aren't auto-indexed by the pre-commit hook, naming the command to run
  after editing them.

## Scope Boundaries

Deferred for later:

- `wb reconcile --glossary` (auto-detecting glossary gaps) — a `wb.sh`
  feature, not a docgen/Hub one; parked as its own follow-up.
- Computed staleness detection and an existence-aware `/board` tile — both
  traded for the simpler static versions in Key Decisions above.
- Generating the roadmap from the task store — real future work once
  every piece of work always has a task file and `/board` grows a roadmap
  view; not practical today since most current roadmap rows have no
  corresponding task file.
- **The task parent/child relationship build** — fully designed this
  session (a new `parent:` frontmatter field on child tasks; parent tasks
  are repo-agnostic so same-repo and cross-repo children use one
  mechanism; one tmux session per repo linked by `parent:`, not a shared
  multi-worktree session; a new parent-aware picker sub-row function, and
  making the existing `/board` rollup mockup real) but ships as its own,
  immediately-following PR rather than inside Hub v0. Full resolved design:
  `logs/decisions/2026-07-09-hub-v0-scoping.md`, Decisions 9–12.

## Dependencies / Assumptions

- Assumes the existing docgen pipeline (`~/code/docgen`: frontmatter →
  rendered HTML, `HUB.html`, `INDEX.md`) as the extension point for every
  new page here — no replacement of that pipeline, and this work stays
  entirely within it (extending existing scan patterns, not adding new
  parser capability).
- The `/board` tile depends on `docs/pr1-wb-workbench-recap.md`'s already
  -shipped `wb board --html` output (`logs/board.html`) existing to link to.

## Outstanding Questions

Deferred to Build:

- Where Task Recall and "Unify copy/paste" land on the new visual (R12) —
  resolved when the visual is actually built.

## Sources / Research

- `~/.claude/parked-items/ledger.jsonl` (2026-07-08T16:45Z–19:33Z) —
  original bundle framing, quoted verbatim during scoping.
- `docs/docgen.md`, `docs/slice-5-recap.md` — the existing generated-docs
  pipeline this work extends.
- `docs/roadmap.md`, `docs/roadmap-open-questions.md`,
  `docs/roadmap-board.md`, `docs/pr1-wb-workbench-recap.md` — existing
  roadmap and `/board` context.
- `logs/decisions/2026-07-08-followups-scoping.md`,
  `logs/decisions/2026-07-08-roadmap-sequencing.md` — prior sequencing
  decisions this brainstorm builds on.
- `logs/decisions/2026-07-09-hub-v0-scoping.md` (+ companion `.html`) —
  the full decision-buffer record (12 decisions) this document synthesizes.
- `docs/roadmap-handoff.md`, `~/code/tasks/README.md`,
  `scripts/.config/scripts/tmux/wb.sh` — origin of the task parent/child
  question and the schema/mechanics verified directly for its design.

> Re-instated 2026-07-10 (evening) verbatim from a same-day session's full
> read, after the deletion incident — the original was committed in
> `d2fa8f9`, which was never pushed and did not survive the reclone.
