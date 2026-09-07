---
title: Where we are
status: current
tile: The current state of the personal-workflow build — what's shipped, what's verified, and what's queued next. The at-a-glance snapshot behind the roadmap's detail.
group: where-we-are
kind: guide
updated: 2026-09-07
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
Since then: Jira interop Phase 1 shipped (PR #32) and was **verified against
live Jira on 2026-09-07**; the docs platform and board got a UX overhaul
(PR #33); `/handoff --pane`, `/parked-items` and `/quick-wins` landed; and a
run of tmux memory fixes (PRs #37–#41) made many concurrent agent sessions
survivable. Nothing is in review right now. Next up is the one-time
task-store schema migration and closing two known `wb` gaps.

## Shipped

<span class="chip ok">35 merged</span> — full history and rationale live on
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
| #32 | **Jira interop — emit (Phase 1)** — `wb jira-set` + `/wb-jira-create`; verified live 2026-09-07 | [recap](2026-07-16-jira-interop-recap.html) · [verification](verification/2026-07-16-jira-emit-verification.html) |
| #33 | **Docs platform + board UX overhaul** — Tokyo Night theme, Hub grouping, real back-links | [verification](verification/2026-07-21-post-crash-merge-batch-verification.html) |
| #34 | **`/handoff --pane`** — a co-located helper agent in the current worktree | [handoff guide](handoff-guide.html) |
| #35 | Post-crash merge-batch verification checklist (#32/#33/#34) | [verification](verification/2026-07-21-post-crash-merge-batch-verification.html) |
| #36 | **`/parked-items`** — wb-task vocabulary, `/handoff` action, carry-forward rounds | [guide](guides/parked-items.html) |
| #37 | tmux: keep agent windows alive on shell exit (`remain-on-exit`) | — |
| #38 | tmux: wb picker no longer misreports in-progress agents as idle/done | — |
| #39 | **`/quick-wins`** — effort/isolation/ownership triage across the deferred backlog | — |
| #40 | tmux: lazy nvim window per wb session to curb memory | — |
| #41 | **wb session memory mitigations** — per-agent cgroup isolation | [verification](verification/2026-08-24-wb-session-cgroup-isolation-verification.html) |
| #42 | Auto-generated try-it catalog from the roadmap + linked docs | [try it](try-it.html) |
| #43 | Machine-readable next-action directive for `/wb-save` / `/wb-resume` | [wb-guide](wb-guide.html) |
| #44 | `/wb-jira-create`: checkbox-select for Project/type | [recap](2026-07-16-jira-interop-recap.html) |
| #45 | `wb breakdown` captures `size:` + `depends_on:` at apply-time; `wb new --size` | [wb-guide](wb-guide.html) |

## In review

Nothing right now. The last item through this gate was Jira interop — emit
(PR&nbsp;#32): its end-to-end run against the live Atlassian MCP passed on
2026-09-07, closing the one gate that stayed open after merge
([checklist](verification/2026-07-16-jira-emit-verification.html)).

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
