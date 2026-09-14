---
title: "Workflow strategy and weekly review - Plan"
date: 2026-09-14
type: feat
topic: workflow-strategy-and-weekly-review
artifact_contract: ce-unified-plan/v1
artifact_readiness: requirements-only
execution: code
product_contract_source: ce-brainstorm
origin: ~/code/tasks/dotfiles--workflow-strategy-and-ceremonies.md
---

# Workflow strategy and weekly review - Plan

## Goal Capsule

- **Objective:** Turn the personal tool set (wb, decision-buffer, park, close-out, handoff, quick-wins, the docs Hub) into one stated way of working, with a weekly review loop that improves it incrementally, and a task board that is opened because it answers real questions.
- **Product authority:** the task file `~/code/tasks/dotfiles--workflow-strategy-and-ceremonies.md` (its Decisions section holds every ratified call from the 2026-09-14 scoping interview, mockup rounds and UX review); this document is the requirements record derived from it.
- **Open blockers:** none for planning. Two forks are deferred to planning (see Outstanding Questions).
- **Shape:** one parent with five session-sized children; this doc is the parent's Product Contract and the children are enumerated under Implementation shape.

---

## Product Contract

### Summary

Build a weekly workflow-review loop around a week file that absorbs `/park`, rewrite `docs/where-we-are.md` into the strategy doc (usage-grounded inventory, prune/keep list, which-tool-when guidance), triage the ~60 `doing` tasks so the loop starts from a clean store, and redesign `wb board` as a multi-view surface per the ratified design reference, rendering in under 10 seconds.

### Problem Frame

Twenty personal skills, fifteen `wb` verbs and ~40 docs pages accreted over ten weeks, each useful on its own, with no statement of how they compose. Measured usage since 2026-07-01 shows the set is carried by three skills — `wb-resume` (81 sessions), `wb-save` (51), `decision-buffer` (34) — and 26 of 40 tracked skills had no transcript hits at all; 34 of 40 docs pages have not been touched since July. The task store holds 117 planned and ~60 `doing` tasks, most of the latter with no Handoffs activity for weeks. `docs/ceremonies.md` scheduled three review clocks for July; all three lapsed unnoticed for seven weeks because a date in a document has no trigger. `wb board --html`, the intended overview, takes seven minutes against the real store and is rarely opened; the plain `wb board` shows status and nothing else. The `/park` ledger has 55 entries marked `open` and none ever marked resolved — capture works, the review half never closed the loop.

### Key Decisions

- **One weekly ceremony replaces dated clocks.** The three 2026-07 clocks in `docs/ceremonies.md` are resolved (kept, absorbed, unused respectively — see that file); recurring review becomes a single weekly ritual with a trigger the user controls, not a date.
- **The ceremony starts as a manually invoked skill.** No `wb up` hook, no calendar nag in v1 — prove the review is worth its cost before forcing it into the workflow. Escalation paths stay open.
- **A week file is the unit, and it absorbs `/park`.** One file minted per week carries last week's recap, is appended to during the week with friction and wins, and is reviewed at week's end. `/park` becomes the capture verb into the current week file; `/parked-items` becomes the review step rather than a separate ritual. One capture surface, in the spirit of the bloat complaint.
- **The week file lives in the task store's dossier area, not the notes store.** `~/code/notes/` has no conventions and its daily files were measured unused; the task store already has locked write verbs, a dossier convention and a git remote.
- **Improvements become tasks through the existing planning flow.** Suggestions accepted in the weekly review are seeded as `planned` tasks via locked `wb` verbs and worked through `ce-plan → ce-work → review`. No new execution path.
- **The strategy doc is a rewrite of `docs/where-we-are.md`.** It is already one of the five current pages; a new page would repeat the failure mode that killed the clocks. Contents: inventory grounded in measured usage, an explicit prune/keep list, and which-tool-when guidance.
- **Prune list distinguishes personal skills from plugin skills.** Most zero-hit skills are `ce-*` plugin skills that cannot be deleted, only documented differently. The list separates "idle personal skill — cut or keep" from "plugin skill — reach for deliberately", so it reads as a plan, not an indictment.
- **`wb board` is redesigned, not pruned.** The user's three jobs — active work with drill-down, roadmap/sequencing, shelved items to fold in — justify a real surface once the 7-minute render was shown to be specific to the `--html` path (plain `wb board` walks the same store in 2.4s). The ratified design is a multi-view board: hierarchical sidebar, Active deck, Roadmap lanes, Week view. Reference: `~/code/tasks/dossiers/dotfiles--workflow-strategy-and-ceremonies/board-design/board-reference-final.html`.
- **The board build is a child, not this task.** This task delivers the design reference, requirements and plan; building happens in its own session-sized task.
- **Triage of `doing` tasks happens now.** Many are `doing` in name only. Cleaning them before the first review gives the strategy doc real numbers and the loop a clean start.

### Actors

- A1. **Jet** — sole user; captures during the week, runs the weekly review, ticks proposals in decision buffers, opens the board.
- A2. **Claude Code session (orchestrator)** — runs the weekly-review skill, gathers evidence, drafts suggestions, seeds tasks through locked `wb` verbs; never writes to `~/code/tasks` directly.
- A3. **`wb` (shell tooling)** — owns every task-store write, mints the week file, renders the board.

### Requirements

**Weekly review loop**

- R1. A week file is minted once per ISO week under this task's dossier area, named by week, and carries a recap of the previous week's review (what worked, what did not, increments accepted and their task links).
- R2. Capture during the week appends a dated entry to the current week file; the existing `/park` verb is the capture path and writes there instead of its standalone ledger.
- R3. The weekly review is a skill Jet invokes; it gathers the week's evidence — the week file's entries, tasks moved and merged PRs since the last review, skill invocations from transcripts — and presents it in a findings-review decision buffer.
- R4. The review produces at most a handful of improvement suggestions, each of which Jet accepts, defers or rejects in the buffer; accepted ones are seeded as `planned` tasks tagged `weekly-review` via locked `wb` verbs.
- R5. The next review opens by checking whether last week's accepted increments shipped, so the loop closes on itself.
- R6. `/parked-items` is retired as a separate ritual; its reconciliation logic (drop items already promoted to a task or PR) is reused inside the weekly review.
- R7. Existing `/park` ledger entries are migrated into the first week file or explicitly closed, so no open item is lost in the switch.

**Strategy doc**

- R8. `docs/where-we-are.md` is rewritten in place as the strategy doc; no new page is added.
- R9. It contains an inventory of skills, `wb` verbs and docs pages with measured usage since 2026-07-01 and a verdict per item: keep, prune candidate, or too new to judge (shipped within the last three weeks).
- R10. Plugin-provided skills are listed separately from personal skills, with "reach for deliberately" guidance rather than a prune verdict.
- R11. It contains which-tool-when guidance covering at least: capturing a loose end, making a settled choice, scoping an open question, ending a session, handing work to another session, and starting the week.
- R12. Every prune-candidate item links to its own small follow-up task; nothing is deleted by this task.

**Task-store triage**

- R13. Every task with `status: doing` is reviewed in a code-review-triage-shaped buffer with one verdict each: keep doing, move to `paused`, move to `planned`, or close as `done`.
- R14. Verdicts are applied through locked `wb` verbs only, and the resulting status counts are recorded in the strategy doc's inventory.

**Board redesign**

- R15. The board renders in at most 10 seconds against the real store (~235 tasks); 5 seconds is the target.
- R16. All views are produced from one pass over task-file frontmatter plus the last `### ` Handoffs heading per file; nothing in the render loop calls `git`, `gh`, tmux or reads transcripts per task.
- R17. The board has a hierarchical sidebar (families as collapsible trees, staleness dot, age) and three views switched client-side: Active, Roadmap, Week — matching the ratified reference.
- R18. Active shows each `doing` task as a card with a Plan progress indicator; the selected card expands into the task's Plan (with completion state), Done, latest Handoff and Follow-ups.
- R19. Roadmap shows one lane per family over a week grid with a TODAY marker, milestone lane headers (progress, next unblocked child), readiness cues (ready, blocked with its blocker) and a ready-now strip.
- R20. Week shows the current ISO week: tasks touched this week expanded, carried-over tasks grouped by family with stale ones collapsed, and a queue-and-shelf row.
- R21. Stale items (no activity in 14 days or more) render at full contrast with a red indicator; they are never de-emphasised.
- R22. Task ids are click-to-copy `wb resume <id>` commands, so the board acts as a control surface without a backend.
- R23. Counts shown in any view agree with each other and with the store.
- R24. Dark mode is native (not filter-inverted); layout is left-anchored and fluid up to ~1800px.

### Key Flows

- F1. Week in, week out
  - **Trigger:** first capture of a new ISO week, or the weekly review being invoked in a new week.
  - **Actors:** A1, A2, A3
  - **Steps:** `wb` mints the week file with last week's recap; during the week `/park` appends entries; at week's end Jet invokes the review skill; the session gathers evidence and opens a findings-review buffer; Jet ticks suggestions; accepted ones become `planned` tasks; the recap is written back to the week file.
  - **Covered by:** R1–R5

- F2. Increment ships
  - **Trigger:** a `weekly-review`-tagged task is picked up.
  - **Actors:** A1, A2
  - **Steps:** `ce-plan → ce-work → review` as for any task; on the next review the skill reports it as shipped or still open.
  - **Covered by:** R4, R5

- F3. Opening the board
  - **Trigger:** `wb board --html` (or its successor verb).
  - **Actors:** A1, A3
  - **Steps:** one pass over the store; page opens on Active with the most recently touched task selected; Jet switches views client-side; clicking an id copies `wb resume <id>`.
  - **Covered by:** R15–R24

### Acceptance Examples

- AE1. **Covers R2, R7.** Given the switch has happened and the old ledger has 55 open entries, when the first week file is minted, then each entry is either present in that file or closed with a reason, and `/park` appends to the week file.
- AE2. **Covers R5.** Given last week's review accepted two increments, when this week's review runs, then it opens with both increments and whether each has a merged PR or a `done` task.
- AE3. **Covers R9.** Given `quick-wins` shipped on 2026-08-24 and has no transcript hits, when the inventory is generated on 2026-09-14, then its verdict is "too new to judge", not "prune candidate".
- AE4. **Covers R15, R16.** Given the real store, when the board renders, then wall-clock is under 10 seconds and no per-task subprocess is spawned.
- AE5. **Covers R21.** Given a `doing` task whose last Handoff is 56 days old, when Active renders, then its card is at full contrast with a red indicator and sorts before fresh cards.

### Success Criteria

- The weekly review runs on three consecutive weeks and at least one accepted increment ships per fortnight.
- The `open`-forever pattern ends: no captured item is older than two reviews without a verdict.
- `docs/where-we-are.md` is opened at least once in the first review as the reference for which-tool-when.
- The board is opened by choice at least weekly after it ships.

### Scope Boundaries

- Building the board — a child task; this task ends with the reference and requirements.
- Deleting or disabling anything on the prune list — each cut is its own small task.
- `wb up` startup review, bulk `wb down --all`, picker changes (shipped in PRs #49–51), and `wire-quick-wins-into-workflows` (own task).
- Calendar or hook-based triggering of the review — revisit once the manual skill has run for a few weeks.
- Notes-store convergence and notes-tui wiring — out; the week file lives in the task store.
- Any per-task `git`/`gh` state on the board — read from caches the `wb` verbs already write, or omitted.

### Dependencies / Assumptions

- `wb append`, `wb new --planned` and the task-store lock are the only write path for A2; this holds today and is assumed to keep holding.
- Transcript grep under-counts skills reached other than by slash command; the inventory labels such cases rather than treating zero as unused.
- The board reference files under the task dossier are the visual authority; the mockups under `~/design-mocks/` are throwaway.

### Outstanding Questions

**Resolve before planning**

- None.

**Deferred to planning**

- Whether the week file is minted by a `wb` verb or lazily by the first `/park` of the week.
- Whether the redesigned board replaces `wb board --html` in place or ships as a new verb with the old one removed once parity is confirmed.
- The skill's name (`/weekly-review` is the working name).

### Implementation shape

Five session-sized children, sequenced:

1. **Doing-task triage** — the decision buffer and status moves (R13–R14). First, because everything downstream reads cleaner numbers.
2. **Weekly-review skill + week file + `/park` migration** — R1–R7.
3. **Strategy doc rewrite** — R8–R12; depends on 1 for counts and on the inventory dossier already written.
4. **Board build** — R15–R24; depends on nothing above but is the largest.
5. **Ceremonies doc refresh** — fold the shipped ceremony into `docs/ceremonies.md`'s Recurring section and remove the "not yet built" marker; last, small.

### Sources

- Usage inventory: `~/code/tasks/dossiers/dotfiles--workflow-strategy-and-ceremonies/usage-inventory-2026-09-14.md`
- Grounding on `/park`, notes store, task-store conventions: `~/code/tasks/dossiers/dotfiles--workflow-strategy-and-ceremonies/grounding-weekly-file-2026-09-14.md`
- Scoping interview and mockup feedback: `~/code/tasks/dossiers/dotfiles--workflow-strategy-and-ceremonies/decision-records/`
- UX review of the board design: `~/code/tasks/dossiers/dotfiles--workflow-strategy-and-ceremonies/ux-review-board-m-2026-09-14.md`
- Board design reference: `~/code/tasks/dossiers/dotfiles--workflow-strategy-and-ceremonies/board-design/board-reference-final.html`
- Resolved clocks and the ceremony placeholder: `docs/ceremonies.md`
- Prior state of the workflow: `docs/where-we-are.md`, `docs/roadmap-day-bookends.md`
