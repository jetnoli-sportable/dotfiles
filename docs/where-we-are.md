---
title: Where we are
status: current
tile: The current state of the personal-workflow build — what's shipped, what's in review (PR #32), and what's queued next. The at-a-glance snapshot behind the roadmap's detail.
group: where-we-are
kind: guide
updated: 2026-07-16
---

A point-in-time status snapshot of the whole personal-workflow build — the
one-screen answer to "where are we?". The [Roadmap](roadmap.html) holds the
forward-looking plan and the design rationale; this page is the current
state. Every shipped item links back to its recap or roadmap detail.

## In one paragraph

The workbench is real and in daily use: `wb` runs a session-per-worktree
picker over a central task store, tasks carry lifecycle state, and a
generated docs platform (this Hub, `INDEX`, `/help`) keeps it all
navigable. The last build run hardened the store against concurrent agents
(PR #22), then stacked task-family tooling on top of those lock primitives
(`/wb-breakdown`, PR #29) and refreshed the board (PR #30) and Hub (PR #31).
**In review right now:** Jira interop — emitting a task or family as SFB
tickets (PR #32). Next up is the one-time task-store schema migration and
closing two known `wb` gaps.

## Shipped

<span class="chip ok">21 merged</span> — full history and rationale live on
the linked recaps; this is the chronological ledger. Foundations before
PR&nbsp;#11 (the docs platform, `wb` core, notes-tui capture) are folded into
the [Roadmap's shipped section](roadmap.html#detail-step-zero).

| PR | What | Detail |
|---|---|---|
| #11 | GPaste clipboard-history manager | [recap](9g-gpaste-recap.html) |
| #12 | Roadmap restructured into overview + detail pages | [roadmap](roadmap.html) |
| #13 | `docgen.sh` pre-commit hook targets the real worktree | — |
| #14 | **wb workbench extensions** — `wb resume` / `wb pause` / `/board` / `wb reconcile` | [recap](pr1-wb-workbench-recap.html) |
| #15 | nvim session auto-restore escape hatch | — |
| #16 | Roadmap sync after PR #1 shipped | — |
| #17 | **Task parent/child relationship** (incl. cross-repo families) | [detail](roadmap-handoff.html) |
| #18 | **Hub v0** — glossary, limitations, ceremonies, `/board` tile, roadmap reshape | [roadmap](roadmap.html#detail-hub-v0) |
| #19 | `wb done --close` + self-kill guard | — |
| #20 | `wb` lifecycle-stage detection functions | — |
| #21 | **`/handoff` v1** — route a discussion to the right worker | [guide](handoff-guide.html) |
| #22 | **Task-store concurrency safety** — ask/refuse/serialize, per-task locks | [guide](guides/tasks-store-guards.html) |
| #23 | Limitations doc — roadmap link-integrity recorded as manual | [limitations](limitations.html) |
| #24 | Per-worktree `/queue` for stashing follow-ups | — |
| #25 | tmux: land in another session on kill, detach-on-destroy off | — |
| #26 | **`wb-save` / `wb-resume` / `wb-done` / `wb-board` skills** | [wb-guide](wb-guide.html) |
| #27 | Sweep-review buffer no longer autoformats itself | — |
| #28 | `xdg-open`/Slack default-browser hijack fix | — |
| #29 | **`/wb-breakdown`** — split an oversized task/ticket into a family | [recap](2026-07-13-wb-breakdown-recap.html) |
| #30 | **Board display v2** — stepper, Pipeline/Live/Stale tabs, dependencies | [recap](wb-board-display-v2-recap.html) |
| #31 | **Hub + roadmap refresh** — currency, guide gaps, sectioning, docgen lint | [roadmap](roadmap.html) |

## In review

- **Jira interop — emit (Phase 1)** — [PR&nbsp;#32](https://github.com/jetnoli-sportable/dotfiles/pull/32),
  branch `feat/jira-integration`. A `wb jira-set` locked write-back verb plus
  a `/wb-jira-create` skill that turns a task or `/wb-breakdown` family into
  new SFB tickets over the Atlassian MCP, behind an approval buffer, stamping
  each ticket URL back into the task. **Create-only.** All automated gates are
  green; the remaining gate is a manual end-to-end run against a live MCP
  (there's no sandbox SFB project) — a step-by-step verification checklist
  lives in the task dossier
  (`~/code/tasks/dossiers/dotfiles--feat-jira-integration/test-plan.html`).
  [recap](2026-07-16-jira-interop-recap.html)

## Next up

The queue behind the current work — full context on the
[Roadmap](roadmap.html#up-next-max-3).

1. **Task-store schema migration** — one-time pass bringing every existing
   `~/code/tasks/*.md` up to the settled schema (`parent:`, `closed:`,
   consistent `status:`). Documented in PR #17; not yet run.
2. **`wb new` bootstrap gap** — `wb_bootstrap` skips `be--monorepo`'s
   `config.hjson`; fix is a `.worktree-bootstrap` manifest there.
3. **`wb reconcile` duplicate-task detection** — two valid worktrees for the
   same real work aren't flagged today.

Queued behind those: **Task recall** (needs the boundary rule), **full day
bookends** `wb up`/`wb down` (needs notes-tui 4b wiring, clock 2026-07-24),
and the **personal/employer boundary rule** (deliberately the last decision).

## Deferred / parked

- **Jira interop — Phase 2 (sprint pull)** — list current-sprint SFB tickets
  and convert the chosen ones into wb tasks via `/wb-breakdown`'s existing
  ticket→task path. In the plan, independent of Phase 1, not started —
  task `dotfiles--loop-jira-watch`.
- **Real Epic hierarchy** for emit (parent → Epic + epic-linked children) —
  the generic "Relates" link ships first; the `Parent ticket:` field is
  forward-compatible with the upgrade.
- **Notes-dir "everything is a note" convergence** — the north-star reduction
  of `~/code/notes`; parked to the ledger.
- **`/second-opinion` skill**, **cross-repo doc registry**, **unify
  copy/paste** — see the [Roadmap's parked pool](roadmap.html#parked).
