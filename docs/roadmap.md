---
title: Roadmap — the personal workflow
status: current
tile: Up next, a live table, a parked pool, what we're not doing, and a shipped ledger — one click to the detail behind each item.
group: personal-workflow
kind: guide
updated: 2026-07-18
---

The roadmap for the whole personal workflow (tmux/Claude tooling, the
central task store, notes-tui, the docs project) — several pieces already
live in separate repos (`~/code/notes-tui`, `~/code/tasks`).

> **Restructured 2026-07-08.** This used to be one 832-line document with
> everything at the same flat depth. Most active or notable items below
> get their own page — click through for the design rationale, the full
> runbook, or whatever detail used to live inline here. Small completed
> items and unratified proposals are noted inline instead (`—` in the Doc
> column) rather than given a page each. This page stays short on purpose.

> **Reshaped again 2026-07-10** (calibration Decision 3, Option C). The
> single Overview table split into an Up-next queue (max 3), a live table,
> a parked pool, a Not-doing lane, and a shipped ledger. Every status is
> now a fixed stage word plus a free-prose impediment; an ordering claim is
> always a waits-on link (`needs:`/`clock:`/`after: — chosen`), never a bare
> "blocked". Dated clocks moved to [Ceremonies](ceremonies.html); three
> standing limitations moved to [Limitations](limitations.html) — see those
> pages for content that used to live inline here. Verification for this
> reshape is content review, not a byte-diff (R11).

## Origins

Six things a 2026-07-06 findings pass ("Agent Workbench," now retired —
its content lives here) said the workflow needed. Kept as a short list
since the task template's `## Decisions` section still refers to "F4":

- **F1 — capture a note in under 5 seconds.** Resolved: `notes.sh` +
  `/park` both already did this; notes-tui's `note` command generalized it.
- **F2 — jump between tasks instantly.** Resolved: the `wb` picker.
- **F3 — every task has an agent.** Resolved: `wb new --agent`.
- **F4 — task history is reviewable.** Resolved: the task record's
  `## Decisions` section links to `logs/decisions/*.md` — this is the
  finding that section exists to satisfy.
- **F5 — at-a-glance board (done/planned/todo).** Resolved: task-file
  frontmatter + `wb board`.
- **F6 — attention routing (agents pull you, don't poll them).** Resolved:
  the hook → marker → count → jump/preview pipeline, shipped first of all
  of these.

## North star (2026-07-10)

Everything is a note. A task is a note labelled a task (created with
`wb`). Tasks tie to each other (sibling or parent/child); notes tie to
tasks. Where things live matters less than always moving toward this —
first concrete step: an end-of-day notes-dir audit (2026-07-10, parked to
the ledger) reducing `~/code/notes` to just `inbox.md`, with `tasks/*`
holding all wb items, then clarifying the note↔task linking and starting
fresh. (Stated in the 2026-07-10 calibration round, Decision 5's note —
`logs/decisions/2026-07-10-workflow-calibration.md`.)

## At a glance

<style>
.roadmap-timeline {
  display: flex; align-items: flex-end; gap: .3rem; overflow-x: auto;
  padding: 1.2rem .5rem .5rem; background: var(--panel); border: 1px solid var(--line);
  border-radius: 8px; margin: 1rem 0;
}
.roadmap-timeline .step {
  flex: 0 0 auto; min-width: 6.5rem; padding: .6rem .7rem; border-radius: 6px;
  font-size: .78rem; position: relative; border: 1px solid var(--line);
  text-decoration: none; color: var(--ink); display: block;
}
.roadmap-timeline .step::after { content: "→"; position: absolute; right: -1.05rem; top: 50%; transform: translateY(-50%); color: var(--mut); }
.roadmap-timeline .step:last-child::after { content: none; }
.roadmap-timeline .step b { display: block; font-family: var(--mono); margin-bottom: .2rem; }
.roadmap-timeline .step.done { background: color-mix(in srgb, var(--ok) 12%, var(--panel)); border-color: color-mix(in srgb, var(--ok) 40%, var(--line)); }
.roadmap-timeline .step.active { background: color-mix(in srgb, var(--acc) 14%, var(--panel)); border-color: var(--acc); }
.roadmap-timeline .step.followup { background: var(--bg2); }
.roadmap-timeline .step.deferred { background: var(--bg2); border-style: dashed; opacity: .75; }
</style>

<div class="roadmap-timeline">
  <a class="step done" href="#detail-docs-platform"><b>Docs platform</b>slice 5, shipped</a>
  <a class="step done" href="#detail-wb-core"><b>wb core</b>PR #7, shipped</a>
  <a class="step active" href="#detail-hub-v0"><b>Hub v0</b>this work</a>
  <a class="step done" href="#detail-parent-child"><b>Parent/child</b>PR #17, shipped</a>
  <a class="step done" href="#detail-board-v2"><b>Board v2</b>PR #30, shipped</a>
  <a class="step active" href="#detail-handoff"><b>/handoff</b>in build</a>
  <a class="step followup" href="#detail-task-recall"><b>Task recall</b>needs: boundary-rule</a>
  <a class="step deferred" href="#detail-boundary-rule"><b>Boundary rule</b>final item, by design</a>
</div>

## Up next (max 3)

The next things actually queued to start, in priority order — everything
else below is either already active, waiting on something named, or
deliberately set aside.

1. <a id="detail-schema-migration"></a>**Task-store schema migration** —
   one-time pass to bring every existing task file up to the settled
   schema (`parent:`, `closed:`, consistent `status:` values). PR #17
   documented the schema but the per-file migration across
   `~/code/tasks/*.md` hasn't run yet — see [Limitations](limitations.html).
   Tied to Hub v0's launch.
2. <a id="detail-wb-new-bootstrap-gap"></a>**`wb new` bootstrap gap** —
   `wb_bootstrap` (`wb.sh:136-157`) only copies files named by a repo's
   `.worktree-bootstrap` manifest, else root `.env*`; `be--monorepo`'s
   `config.hjson` (root + `apps/metrics_server/`) is silently skipped.
   Fix: add that manifest in `be--monorepo`. Found 2026-07-10 during the
   `/handoff` dry-run — [detail](roadmap-handoff.html).
3. <a id="detail-wb-reconcile-duplicate-gap"></a>**`wb reconcile` duplicate-task detection** —
   two tasks that both have valid worktrees but represent the same real
   work aren't recognized as a finding at all today; the user still has to
   manually name the merge target — [detail](roadmap-wb-reconcile.html).

## Live

Ongoing or queued work. Every status is a fixed stage word (`active` /
`queued` / `proposed`) plus a free-prose impediment clause. An ordering
claim is always a waits-on link — `needs: <item>`, `clock: <date>`, or
`after: <item> — chosen` — never a bare "blocked".

| Item | Status | Doc | What it is |
|---|---|---|---|
| <a id="detail-hub-v0"></a>**Hub v0** (meta-documentation bundle) | active — this work; U5/U6 artifact index deferred | [requirements](brainstorms/2026-07-09-hub-v0-requirements.md) | Glossary, limitations, ceremonies pages, `/board` tile, this reshape, and cataloging the `wb-save`/`wb-resume`/`wb-done`/`wb-board` skill family (added to the plan 2026-07-11) |
| <a id="detail-handoff"></a>**`/handoff`** — route a discussion to the right worker | active — building on `feat/handoff-v1`; single-target validated by hand 2026-07-10; fan-out after: parent/child (PR #17) — chosen | [detail](roadmap-handoff.html) | Switch to an existing agent's session or `wb new` it |
| <a id="detail-task-recall"></a>**Task recall** | queued — needs: boundary-rule | [detail](roadmap-task-recall.html) | Resume any work from any session by referencing it |
| <a id="detail-day-bookends-full"></a>**Day bookends** — full `wb up` / `wb down` | queued — needs: notes-tui-4b | [detail](roadmap-day-bookends.html) | Single-task `wb resume` already shipped (PR #14); full startup/shutdown flow waits on real notes-tui wiring |
| <a id="detail-notes-tui-4b"></a>**Notes-tui integration, 4b** (real wiring) | queued — clock: 2026-07-24 (fix-forward experiment verdict) | [deep dive](slice-4b-deep-dive.html) · [ceremonies](ceremonies.html) | Original 4b wiring only proceeds if the fix-forward experiment changes real usage |
| <a id="detail-boundary-rule"></a>**Personal/employer boundary rule** | queued — after: every other follow-up — chosen | [limitations](limitations.html) | Deliberately the final decision; Task recall above already depends on it landing |
| <a id="detail-jira-integration"></a>**Jira integration** (`/board` + day-bookends halves) | active — Phase 1 (emit tasks → SFB tickets) open as PR #32; Phase 2 (sprint-pull) deferred | — | task: `dotfiles--feat-jira-integration` |
| <a id="detail-second-opinion"></a>**`/second-opinion`** — ask the best available model at high effort, context-aware | proposed — raised 2026-07-11; new skill vs. tweaking an existing `/btw` still undecided | — | Formalizes today's ad-hoc pattern (spawn a top-tier-model subagent, full conversation context, high reasoning effort, to sanity-check a decision) as a reusable skill; no `/btw` skill or alias exists anywhere in this repo, so confirm what that refers to before building |

## Parked

Set aside on purpose. Every entry names what would actually bring it back.

- <a id="detail-doc-registry"></a>**Cross-repo/cross-machine doc registry** — parked. Revisit trigger: artifacts still going missing after the landing-path rule.
- <a id="detail-unify-copy-paste"></a>**Unify copy/paste** (terminal paste never needed) — parked. Revisit trigger: a design pass gets scheduled — [9g recap](9g-gpaste-recap.html).

## Not doing

Considered, and decided against — kept here so the reasoning isn't lost.

- <a id="detail-computed-staleness"></a>**Computed staleness detection + an existence-aware `/board` tile** — traded for the static hints Hub v0 actually shipped (the `/board` tile + intro banner, U4).
- <a id="detail-wb-reconcile-glossary"></a>**`wb reconcile --glossary`** (auto-detecting glossary gaps) — a `wb.sh` feature, not a docgen/Hub one; not this push's job.

## Shipped

<span class="chip ok">17 shipped</span> — full history and rationale live
on each linked recap page; these no longer take a queue/live/parked slot.

- <a id="detail-step-zero"></a>**Step zero** (hooks, alias cleanup) — attention-pipeline hooks wired, dead `n` alias removed.
- <a id="detail-task-store-frontmatter"></a>**Central task store + frontmatter** — [wb design](roadmap-wb-design.html)
- <a id="detail-wb-core"></a>**`wb` core** (new / picker / done) — [wb design](roadmap-wb-design.html) · [wb-guide](wb-guide.html) — PR #7
- <a id="detail-notes-tui-4a"></a>**Notes-tui integration, 4a** (capture) — [deep dive](slice-4b-deep-dive.html)
- <a id="detail-docs-platform"></a>**Docs platform** (generated pages, Hub, INDEX, `/help`) — [docgen](docgen.html) · [slice-5 recap](slice-5-recap.html)
- <a id="detail-guide-pages-hub"></a>**Per-skill/TUI guide pages + tile dashboard** — `docs/guides/*` · [slice-5 recap](slice-5-recap.html)
- <a id="detail-board-html"></a>**`/board`** — full HTML task-board view — [PR #1 recap](pr1-wb-workbench-recap.html) · [detail](roadmap-board.html) — PR #14
- <a id="detail-wb-pause"></a>**`wb pause`** (new status + subcommand + keybind) — [PR #1 recap](pr1-wb-workbench-recap.html) · [detail](roadmap-board.html) — PR #14
- <a id="detail-wb-reconcile-core"></a>**`wb reconcile`** — drift detection + review/apply flow — [PR #1 recap](pr1-wb-workbench-recap.html) · [detail](roadmap-wb-reconcile.html) — PR #14
- <a id="detail-wb-resume"></a>**`wb resume <task>`** (day bookends, single-task) — [detail](roadmap-day-bookends.html) — PR #14
- <a id="detail-ergonomics-batch"></a>**Editor/tmux ergonomics batch** — [9f recap](9f-ergonomics-recap.html)
- <a id="detail-gpaste"></a>**GPaste clipboard-history manager** — [9g recap](9g-gpaste-recap.html)
- <a id="detail-precommit-hook-fix"></a>**`docgen.sh`'s pre-commit hook** — fixed the wrong-repo-from-a-worktree bug, verified with a real divergence test
- <a id="detail-parent-child"></a>**Task parent/child relationship** (incl. cross-repo/full-stack tasks) — [detail](roadmap-handoff.html) — PR #17
- <a id="detail-tasks-concurrency-safety"></a>**Central task-store git/file safety across concurrent agents** — three-layer guard (agent-side "ask" hook, git-side refuse hook, per-task-file lock) closing four real incidents; git-side hook ships installed but dormant until a human runs the X7 replay — [guide](guides/tasks-store-guards.html) · [recap](2026-07-12-tasks-dir-concurrency-safety-recap.html) — task: `dotfiles--docs-roadmap-tasks-concurrency-safety`
- <a id="detail-wb-breakdown"></a>**`wb breakdown`** — split one oversized task or Jira ticket into a linked parent/child family via a human-approved proposal buffer + a locked multi-file apply; built on the concurrency-safety work's lock primitives, lands after that PR — [recap](2026-07-13-wb-breakdown-recap.html) — task: `dotfiles--feat-wb-breakdown-skill`
- <a id="detail-board-v2"></a>**Board display v2** — lifecycle stage stepper, Pipeline/Live/Stale tabs, dependency + parent/child relationships, repo/family filters, Key Findings, column sorting (the parent/family progress view lives here) — [recap](wb-board-display-v2-recap.html) — PR #30

Ceremonies (dated clocks, recurring reviews) now live on their own page:
[Ceremonies](ceremonies.html). Standing workflow constraints now live on
their own page: [Limitations](limitations.html). Full detail on every
deferred decision the 2026-07-07 doc review left open:
[Open Questions](roadmap-open-questions.html).

## Window management

**Unblocked 2026-07-09** — the trigger this section existed to track
("workbench core" landing) fired: `/board` + `wb reconcile` +
`wb resume`/`wb pause` shipped as PR #14. GNOME tiling trifecta plan
(focus-or-launch + Forge + workspaces) already written on unmerged branch
`feat/gnome-tiling`; `walker` decided as the launcher. Its own doc review
is now available to pick up whenever it's next in line — not
auto-scheduled, just no longer blocked. Keybind constraint stands
regardless of timing: `ctrl+hjkl` stays reserved for vim-tmux-navigator.

## Keep / retire / hold

- **Retire:** `cad` dashboard (unused, `wb` absorbs it), dead `n` alias.
- **Hold:** nvim bridge fancy features (`:ClaudePick`, yank-code, `gf`) —
  stay installed, no further investment until the basic loop + workbench
  are further along.
- **Keep as-is:** decision-buffer, `/park` + `/parked-items`,
  `pr-review-session`, the worktree flow (its ritual is absorbed by
  `wb new`, not replaced).
