---
title: wb Go store and task page - Plan
type: feat
date: 2026-10-17
updated: 2026-11-01
topic: wb-go-store-and-task-page
artifact_contract: ce-unified-plan/v1
product_contract_source: ce-brainstorm
execution: code
task: dotfiles--wb-future-direction
---

# wb Go store and task page - Plan

## Goal Capsule

**Objective:** Jet runs wb the same way on Linux and macOS. They can open any task or task family in a browser page that already holds its artifacts, decisions, children and current state, instead of rebuilding that picture by hand. Every task and family in the store has the same, predictable layout. And wb's task-store logic is small and typed enough to change without fear.

**Means:** a smaller wb in which a Go component owns reading and writing the task store, with bash kept for the tmux, worktree and fzf glue. Before the Go reader is built, the store moves to one dossier layout (short task file, one file per decision, handoff and open item, generated views). The first consumer of the reader is a per-task / per-family browser page (KTD13, KTD15).

**Product authority:** Jet. Decisions marked `session-settled` were made by Jet in the 2026-10-17 brainstorm, the 2026-10-18 planning alignment, the 2026-10-30 re-validation answers and the 2026-11-01 layout design session (stage 0). All are recorded in `~/code/tasks/dotfiles--wb-future-direction.md` § Decisions.

**Plan scope:** the work runs as six stages inside one task, one PR (or a small set of PRs) each, in the order **0 → 1 → 2 → 5 → 3 → 4**:

| Stage | What it does | Units | State |
|---|---|---|---|
| 0 · Layout design | Settles the dossier and family layout, page tags, the ladder, `brief.md` and file formats | (design session, no code) | done 2026-11-01 |
| 1 · Plan update | This rewrite, rebased and merged as PR #96 (the plan itself) | (this document) | in progress |
| 2 · Layout into wb | Builds the layout into `wb.sh` and the skills, rehearses the migration on a store copy, trials it on this family, switches the whole store in one commit | U10–U14 | planned in full |
| 5 · `wb done` rework | `wb done` stops opening the task file, sorts gitignored files by lists, and the `wb-done` skill goes | U1–U3 | planned in full |
| 3 · Go reader | `wb-store show`, `list`, `family`, reading the new layout only; the build-on-demand shim | U6, U7, U9 (shim) | planned in full |
| 4 · Task page | The local page server, a week of layout iteration, Jet's yes or no; `wb page` | U8, U9 (`wb page`) | planned in full |

Stage numbers are labels from the 2026-10-30 plan; the run order is the table's order. Phases 2 (Go-owned writes) and 3 (tmux and PR data, the live page) are outlined only (see Phased Delivery); they get their own planning pass after Jet's yes at the end of the prototype week. This plan's share of the Mac objective is that wb-store builds and runs on macOS (R8); the bash glue's macOS port, which the Mac success criterion also needs, is owned by `dotfiles--feat-macos-cross-platform`.

**Stop conditions:**
- Jet says no at the end of the prototype week (R17): stop after U8, keep the reader (U6, U7), drop the page templates.
- The stage 2 trial shows the layout reads badly and the fix is bigger than a stage 2 change: stop before the switch (U14), revert this family's migration commit, and take it back to Jet. Nothing else in the store has moved at that point.
- Any unit discovers a caller or behaviour that contradicts a settled decision: stop that unit and ask Jet; don't work around it.

**Execution profile:** one task with stages, not child tasks (session-settled, 2026-10-30). Each stage runs in this task's wb session, with `/wb-save` and `/clear` between stages. Implementation can run on Sonnet subagents; the orchestrating session reviews diffs and test output before calling a unit done. Code review runs in a fresh context after `/clear`, never in the build session.

---

## Product Contract

**Product Contract preservation:** changed on 2026-11-01 (stage 1):
- Key Decisions gained the 2026-10-26, 2026-10-30 and 2026-11-01 entries.
- R3, R9, R10, R16, R17, R18 and R22 are reworded for the dossier layout and the reply log.
- R24–R33 are new: the dossier layout, its migration and the store switch.
- AE1 is rewritten against decision files; AE5 is made generic (dotfiles will be public); AE7–AE10 are new.
- U4 and U5 (the `## Artifacts` section and the prose supersede marker) are retired, replaced by stage 2's U10–U12.
- R1, R2, R4–R8, R11–R15, R19–R21, R23 and AE2–AE4, AE6 are unchanged.

### Summary

Shrink wb (done: the deletion pass and quick wins shipped on 2026-10-18). Move the whole task store to one dossier layout: a short task file, one file per decision, handoff and open item, and generated read-only views. Then move ownership of the task store into a Go component that reads the new layout and answers in machine-readable form, and build a browser task page for one task or one family as its first consumer.

The layout comes first because the Go reader, the task page and the `wb done` rework all read or write it; building any of them on the old layout would mean building them twice. The layout reaches the store in one switch, after a rehearsal on a full copy and a 3–5 day trial on this family.

The Go work then starts with a one-week prototype: the real reader's first slice plus the page, with only the page's layout iterated. Jet's yes or no ends the week. Writes then move to Go behind unchanged wb commands, and the reader grows tmux and PR data as the page needs it.

### Problem Frame

Jet runs many Claude sessions in parallel through wb, the bash workbench under `scripts/.config/scripts/tmux/`. Four things work against them:

- **Linux only.** wb depends on Linux-only behaviour in about thirty places. Examples: `flock`, `date -d`, `stat -c`, and bash 4+ features. macOS ships bash 3.2.
- **Hard to reason about.** `wb.sh` is about 7,000 lines. Three separate awk-based frontmatter writers each encode the task-file format, and the bash readers disagree with each other on details such as which duplicate key wins.
- **Task files and families don't scale.** Big task files are 40–50% handoff history: the post-processor coordinator's task file is 1,722 lines, 805 of them Handoffs, and its dossier is 179 flat files. Every family has a bespoke structure, decisions have no stable ids (47 entries across two families carry zero supersede markers), and a fresh session reads the whole file to find the current state.
- **The HTML board doesn't fit how Jet works.** `wb board --html` is a store-wide page that Jet doesn't use. What they actually reach for is one task or one family.

The cost shows up each time Jet returns to a task. They rebuild its picture by hand:

- scrolling back through the Claude window;
- hunting browser tabs for the artifact;
- asking the agent to summarise, which adds more to scroll through.

`wb done` adds its own friction: it opens a blocking review buffer on every run, which is why a separate background-and-relay skill (`wb-done`) exists just to call it from an agent.

Several other overview pains came up in the same review. Each already has its own home (see How This Work Fits Together).

### Key Decisions

**From the brainstorm and planning alignment (2026-10-17, 2026-10-18)**

- **Hybrid: Go owns the task store; bash keeps the tmux, worktree and fzf glue.** (session-settled: user-directed — chosen over a full Go rewrite or staying all-bash: an adversarial read put the bash-induced complexity in the store read/write layer, not the tmux layer.) Governs R3, R8.
- **Delete before building.** (session-settled: user-directed — chosen over porting everything as-is.) Governs R1. Done: PR #94 (nine retired features deleted) and PR #93 (`prefix+t` and the ctrl-x `cd "$HOME"` fix).
- **`wb done` stops opening the task file by default; review is opt-in.** (session-settled: user-directed — chosen over keeping the pre-teardown review buffer on every run.) Governs R19.
- **The gitignored-file sweep is automatic, driven by explicit keep and throwaway lists; anything unlisted stops the run for Jet to classify.** (session-settled: user-directed — chosen over the interactive checklist buffer, and over discarding unlisted files silently.) Governs R20, R21, R22.
- **The `wb-done` skill is deleted; close-out runs `wb done` directly.** (session-settled: user-directed — chosen over keeping the background+relay workaround.) Governs R19.
- **Build order B': the prototype is the real reader's first slice.** (session-settled: user-directed — chosen over building the full shared reader first, a throwaway script prototype, Mac-first via bash fixes, and Go-owns-writes up front.) Governs R17, R18.
- **Go owns writes too, after the prototype week.** (session-settled: user-directed — chosen over keeping writes in bash.) Governs R3, R6, R7.
- **The store-wide `wb board --html` stays, side by side with the task page, for now.** Jet first chose to delete it, then stepped back. (session-settled: user-directed.) Governs R2.
- **The task page is served by a local process that re-reads the store on each request.** (session-settled: user-directed — chosen over static HTML regenerated by hand.) Governs R14, R17.
- **Artifact records carry the durable on-disk path as well as the claude.ai link.** (session-settled: user-directed — chosen over URL-only records.) Governs R9, R16, R28.
- **`size`, `priority` and `value` are optional; absent means empty; nothing is backfilled, including `closed:`.** (session-settled: user-approved.) Governs R5.
- **store-specialist's lookups move to the Go reader once it exists;** in stage 2 it learns the new layout's file locations only. (session-settled: user-approved.) Governs R5.
- **The schema-owner family is retired into this work, and MCP is dropped for now.** (session-settled: user-approved.) Governs R5.
- **The terminal context card is a separate surface owned elsewhere, reading the same data.** (session-settled: user-directed.) It shipped in PRs #112, #115 and #121 (the reply log, its viewer, and the card in the picker preview).
- **Testing gaps are resolved during the port, not up front.** (session-settled: user-directed.)

**From the re-validation (2026-10-26, 2026-10-30)**

- **One task with stages, not five child tasks.** (session-settled: user-directed — chosen over the five-child breakdown drafted on 2026-10-18, never applied.)
- **The task page shows recent replies from the reply log** (`~/.claude/replies/<session-id>.md`). (session-settled: user-directed — chosen over keeping the prototype to task files only: it lets the page show which session is waiting on Jet, and the log's format is documented.) Governs R17.
- **The family depth limit is 20,** the one `wb family` already uses. (session-settled: user-approved — chosen over the plan's earlier 50, so two readers never disagree on a deep chain.)
- **wb-store's test files are made up,** never copied from the store, because dotfiles will become public. (session-settled: user-approved.)
- **The `wb-done` skill's batch rules move into close-out and the wb guide** before the skill is deleted. (session-settled: user-approved.)
- **The prototype gate is Jet's yes or no on the layout, plus live checks in `checks.md`** for the verify-behaviour watcher. (session-settled: user-approved — the tickable HTML checklist was retired on 2026-10-25.)

**From the stage 0 layout session (2026-11-01)**

- **A layout design session comes before the plan rewrite (stage 0).** (session-settled: user-directed — chosen over rewriting the plan first and fitting the layout in later, which would rebuild the Go reader and the task page.)
- **The task file becomes short:** frontmatter, a `## Now` block of about 10 lines that `/wb-save` rewrites, and only the newest handoff. History and the plan body move to the dossier. (session-settled: user-directed — chosen over relying on the task page for a readable view.) Governs R24.
- **`notes.md` is Jet's scratch file in the dossier.** Agents never write it and read it only when Jet points to it. (session-settled: user-directed — chosen over reading it at every session start.) Governs R27.
- **Decisions are one file each, with a generated read-only log.** Superseding writes the new file and flips the old one's status in one locked operation. (session-settled: user-directed — chosen over one append-only `decisions.md` and over keeping Decisions in the task file: separate files never conflict across clones, get stable ids, and carry status as a field.) A decision can carry `review_at:` naming a rung or an event. Governs R25, R26.
- **The general rule:** records written by tools (decisions, handoffs, open items) are one file each plus a generated view; documents people write (spec, ladder, notes, brief) are one Markdown file each. Governs R25, R27.
- **A child's dossier is created on its first write and holds only what it uses;** family-wide content lives in the parent. (session-settled: user-directed — chosen over the full layout for every child and over no child dossiers.) Governs R29.
- **Pages carry a frontmatter block of tags, not exclusive roles.** (session-settled: user-directed — chosen over the post-processor family's eight exclusive roles in a hand-edited `INDEX.toml`.) Governs R28.
- **The ladder:** one `ladder.md` per family, hand-written only; per rung a claim, an exit check, an "in short", an effort and an optional "not in this rung", plus the events it holds. Status, tasks, decisions due and pages are generated into the page and index, never into `ladder.md`. (session-settled: user-directed, after the planning-patterns research child.) Governs R33.
- **`brief.md` is the task's opening prompt and overview, not its source of truth.** It replaces the "First action" seed. (session-settled: user-directed.) Governs R27.
- **Formats:** every file in the layout is Markdown; records and pages carry restricted YAML frontmatter; one file per handoff; generated views are committed Markdown with a "generated, do not edit" line; JSON only as a git-ignored cache. (session-settled: user-directed — chosen over TOML frontmatter and JSONL handoffs.) Governs R30.
- **Follow-ups become `open-items/` records,** one file each. (session-settled: user-directed.) Governs R25.
- **Stage order 0 → 1 → 2 → 5 → 3 → 4; stage 2 ends with one store-wide switch after a rehearsal and a short trial.** (session-settled: user-directed — chosen over piloting this family early with both layouts live for weeks, and over switching the store only after stage 4.) Governs R31, R32.

### How This Work Fits Together

<!-- ce-section: work-relationships -->

This plan covers the dossier layout, the `wb done` rework, the Go store (reads, then writes) and the browser task page. The data flow, once all stages land:

| Source | Read by | Used by |
|---|---|---|
| Task files (`~/code/tasks/<stem>.md`): frontmatter, `## Now`, newest handoff | wb-store (stage 3) | task page, agents, later the wb verbs |
| Dossier records: `decisions/`, `handoffs/`, `open-items/` | wb-store; bash renders their generated views (stage 2) | task page, `/wb-resume`, the capture sweep, the context card |
| Dossier documents: `spec.md`, `ladder.md`, `concepts.md`, `brief.md`, pages | wb-store | task page; `concepts.md` is imported into every family worktree |
| Reply log (`~/.claude/replies/<id>.md`) | wb-store (stage 3, read-only) | task page's recent replies |
| tmux and PR state | wb-store (phase 3, later) | the live page |

- **Shipped children of this task:** [[dotfiles--wb-deletion-pass]] (PR #94, nine retired features deleted) and [[dotfiles--wb-bash-glue-quickwins]] (PR #93, `prefix+t` and the ctrl-x fix). This plan builds on both and does not re-plan them.
- **Folded in:** `dotfiles--feat-task-file-structure` (its scope is the stage 0 layout).
- **Child on hold:** [[dotfiles--feat-store-cross-agent-sync]]. It is re-planned on the Go reader once that exists, and designs its own "what changed" query then (see Considered and not built). `/wb-decide`'s propagation (PR #111) already pushes decisions to live family sessions; the sync covers the rest (handoffs, status, plan).
- **Research child, done:** `dotfiles--research-ladder-planning-patterns` delivered the Q6 (ladder) and Q7 (`brief.md`) verdicts.
- **Terminal context card** (`dotfiles--feat-claude-reply-log`, shipped). It reads the reply log; stage 2 points it at the `decisions/` record files.
- **Task page requirements** (`dotfiles--wb-board-scoped`). That task holds the seven requirements this plan's page group implements (R9–R15). It has no separate build.
- **Decision-page skill** (shipped, PR #97). It records answers through `wb append`, so stage 2's writers cover it; U12 adds the page-frontmatter step.
- **Walk-through of what needs Jet** (`dotfiles--workflow-walkthrough-what-needs-me`, its own task). It runs before stage 4; its ranked pain list shapes what the task page shows first. Day-start and day-end are designed there too.
- **Mac port of the bash glue** (`dotfiles--feat-macos-cross-platform`). Its scope shrinks once Go owns writes.
- **Independent, not in this plan:** answer navigation (`dotfiles--feat-reply-navigation`), browser tabs per family (`dotfiles--browser-tabs-per-family`), the spare-token weekend lanes (`dotfiles--spare-token-lanes`), the Ubuntu upgrade (its own task), store/Jira/merge drift (`dotfiles--lanes-store-reconcile`) and follow-up harvest (`dotfiles--lanes-followup-harvest`).
- **Still to decide:** the store-wide board's fate, once the task page has been in use.

### Requirements

**Deletion pass** (done)
- R1. Remove wb features Jet confirms as unused, one confirmation per feature, before porting anything.
- R2. Keep the store-wide `wb board --html` working alongside the new task page until Jet decides its fate.

**Dossier layout** (stage 2)
- R24. A task file holds frontmatter, a `## Now` block (goal, current rung, next action, what waits on Jet; about 10 lines, rewritten on every `/wb-save`) and only the newest handoff. Nothing else accumulates in it.
- R25. Records written by tools are one file each in the task's dossier: `decisions/<YYYY-MM-DD-HHMM>-<slug>.md`, `handoffs/<YYYY-MM-DD-HHMM>.md` and `open-items/<YYYY-MM-DD>-<slug>.md`. Each series has a generated, read-only Markdown view (`decisions.md`, `handoffs.md`), and the dossier has a generated `index.md`. Views are rebuilt after every write and carry a "generated, do not edit" line.
- R26. Superseding a decision writes the new decision file and flips the old one's `status` to `superseded` (with `superseded_by`) in one locked operation. This is the only edit an existing decision file ever gets.
- R27. Documents people write are one Markdown file each: `notes.md` (Jet's; agents never write it), `brief.md` (the opening prompt, drafted when the task is created), `spec.md`, `ladder.md` (hand-written only) and `concepts.md` (settled facts and vocabulary, today's `CONCEPTS.md`).
- R28. Every dossier page carries a frontmatter block: `tags:`, optional `rung:`, `links:`, optional `retire_when:`, `visibility:` and `url:`. A page with no Markdown source carries the same block as an HTML comment at the top. The block is added when a page is next edited, not in bulk.
- R29. A child's dossier is created on its first write and holds only what it uses. Family-wide content (`spec.md`, `ladder.md`, `concepts.md`, `components/`) lives in the parent. The parent's overview walks `parent:` links and lists each child's pages under that child.
- R30. Every file in the layout is Markdown. Frontmatter is restricted YAML: at byte 0, flow-style short lists, `key:` with no value means none, no anchors or aliases. JSON appears only as a git-ignored cache.
- R31. A one-off migration command converts a task file into the layout. Every decision, handoff and follow-up lands in exactly one new file, and running it twice changes nothing.
- R32. The store moves in one switch: a rehearsal on a full copy of the store, a trial on this family behind a per-task switch for 3–5 days (capped at a week), then one commit that migrates every task. The old code path is deleted after a day of normal work on the switched store.
- R33. A family's `ladder.md` is hand-written only. Status per rung, the tasks on each rung (from children's `rung:`), decisions due for review and pages per rung appear only in generated output (the index and, later, the task page).

**Go task store** (stage 3, phase 2)
- R3. One Go component owns parsing (stage 3) and then writing (phase 2) the task store: task-file frontmatter and `## Now`, record files and their frontmatter, and dossier pages' frontmatter. It reads the dossier layout only. No second writer of the format remains once writes have moved.
- R4. The store answers for one task or one family fast enough that the page feels instant on the real store, about 480 task files.
- R5. The store produces machine-readable output shaped like the store, not like any one view. It serves agents, the task page, the terminal card and later consumers.
- R6. Every wb verb used by skills, hooks or the nvim plugin keeps its name, arguments and observable behaviour.
- R7. While bash and Go writers coexist, both honour the same per-task lock, so they can never interleave writes to one task.
- R8. The Go store runs on Linux and macOS with no OS-specific dependency.

**Browser task page** (stage 4; from `dotfiles--wb-board-scoped`)
- R9. A page for one task, or one family, lists every artifact relevant to it: dossier pages (from their frontmatter, grouped by tag, retired ones behind one link), published artifacts, PRs.
- R10. The page shows every decision with its rationale, including decisions later superseded, shown beside the decision that replaced them.
- R11. For a parent or family, the page shows each child's state and the dependencies between children.
- R12. The page makes open items and deferred work clear.
- R13. The page links each task to its Claude session and tmux session.
- R14. While a session is active, the page shows current state and refreshes more often than a manual rebuild. Current state means: whether a plan exists, what the session is doing now, whether a PR is open, and the latest exchange.
- R15. For an umbrella or parent task, the page helps plan a new family, by showing what is planned, missing or blocked across the children, and the ladder's generated status.
- R23. `wb page` opens the task page for the current session's task, or for a named task, so the page is one command away from any wb session.

**Task-store conventions**
- R16. Artifacts and decision reversals are recorded in a form the store can recognise, so R9 and R10 don't depend on guessing from prose: page frontmatter (R28) for artifacts, decision-file frontmatter (R26) for reversals.

**`wb done`** (stage 5)
- R19. `wb done` closes without opening any editor by default; `--review` opens the task file for review before teardown.
- R20. Before removing a worktree, `wb done` sorts every gitignored entry into keep, throwaway or unknown. Keep entries are copied to the task's dossier, throwaway entries are deleted with the worktree, and any unknown entry stops the run before anything changes, naming the entries and how to resolve them.
- R21. A credential-shaped file is never copied into the task store.
- R22. The `wb done` handoff record lists which gitignored entries were kept and which were discarded.

**Delivery shape**
- R17. The first week of the Go work is a prototype in which the reader is the real first slice: the dossier layout plus recent replies from the reply log, covering R9–R13 and R15. Only the page's layout is iterated. Jet's yes or no ends the week.
- R18. tmux and PR data (the rest of R14) are added to the store only after the prototype week, as the page shows each is needed.

### Acceptance Examples

- AE1. **Covers R10, R26.** On 2026-10-17 Jet decided to delete the store-wide board (Probe 6), then stepped back from it the same day. After this family's migration, the step-back is recorded as its own decision file that supersedes the Probe 6 file. The Probe 6 file has `status: superseded` and `superseded_by` naming the step-back; the page shows both together with the reason for the reversal, not as two unrelated entries.
- AE2. **Covers R6.** After writes move to Go, `/wb-save` runs `wb append <task> Handoffs -`. The resulting handoff file and regenerated view are the same as before the move, and the skill needed no change.
- AE3. **Covers R7.** A bash verb and a Go write target the same task at the same moment. One waits for or reports contention on the shared lock, and no write is lost.
- AE4. **Covers R17.** At the end of the prototype week Jet says no. The work stops, and only the page templates are lost; the reader slice is kept.
- AE5. **Covers R20, R21.** A worktree holds `config.hjson`, copied in at `wb new` from the repo's `.worktree-bootstrap`. If the worktree copy is byte-identical to the main checkout's, `wb done` treats it as throwaway and closes normally. If Jet edited it inside the worktree, `wb done` stops before removing anything, names `config.hjson`, and never offers to copy it into the dossier.
- AE6. **Covers R20, R22.** A worktree holds an unlisted `scratch/notes.txt`. `wb done` stops and names it. Jet re-runs with `--keep scratch/notes.txt`; the file lands in `~/code/tasks/dossiers/<task>/scratch/notes.txt`, the `wb done` handoff record gains a `kept:` line for it, and the worktree is removed.
- AE7. **Covers R31.** A synthetic task file shaped like the post-processor coordinator holds 30 decisions in all four written styles (two of them carrying a `(supersedes: …)` marker), 40 handoffs, 12 open follow-ups and 5 ticked ones, a `## Done` section and a `## Plan`. After migration: 30 decision files (the two markers kept as raw text and listed as exceptions), 39 handoff files plus the newest kept in the task file, 12 `open-items/` files, one migrated-history handoff file holding the 5 ticked items and `## Done`, and `## Plan` untouched. A second run changes no byte.
- AE8. **Covers R25, R32.** During the trial, `wb append dotfiles--wb-future-direction Decisions -` writes a new file under `decisions/` and regenerates `decisions.md`; the same command on a task without `layout: dossier` appends under `## Decisions` as today.
- AE9. **Covers R24.** `/wb-save` on a migrated task rewrites `## Now`, moves the previous newest handoff to `handoffs/`, and writes the new one into the task file. The task file stays under about 40 lines however many saves run.
- AE10. **Covers R32.** The rehearsal on a full store copy reports, per task file, the entry counts before and after; every count matches or the task is listed as an exception for Jet before the switch.

### Success Criteria

- wb's day-to-day verbs and the task page work on Jet's Mac.
- Every task and family in the store has the same layout, and a fresh session finds the current state of any task from its short task file.
- Jet says yes at the end of the prototype week, and goes on opening the task page during real sessions instead of scrolling for context.
- The task-store logic lives in one typed component, and `wb.sh` is substantially smaller than its current ~7,000 lines.
- An agent can run `wb done` in the foreground and get a result or a clear stop message in the same turn, with no buffer to wait on.

### Scope Boundaries

**Deferred for later**
- MCP access to the store.
- Deciding the store-wide board's fate (R2).
- Phase 2 (Go-owned writes) and phase 3 (tmux and PR data; the live page, R14, R18): outlined under Phased Delivery, planned after Jet's yes.
- Splitting other families' `## Plan` into `spec.md` and `ladder.md`, and adding page frontmatter to their existing pages: each family does this when next worked on, not at the switch.
- The shared diagram tool (one JSON spec and renderer in the inline-SVG house style, viewable from nvim): stage 2 or later, since it doesn't change the layout.

**Owned by other work** (see How This Work Fits Together)
- The terminal context card (shipped).
- Jira, merge and follow-up reconciliation.
- Automation of capture.
- Porting the bash glue to macOS.
- The inbox and day-start/day-end (the walk-through task).

**Outside this work**
- Rewriting the tmux, worktree or fzf glue in Go.

**Considered and not built** (each with what would change the call)
- A confirmation popup before every picker ctrl-x close. The picker already asks y/N before closing a task row (`_ctrl_x`); the kept/discarded record (R22) and the stop-on-unknown rule (R20) cover the loss case. Revisit if an unlisted file Jet wanted is ever discarded via a throwaway pattern that was too broad.
- Per-repo sweep lists. One global list file starts; `.worktree-bootstrap` already covers the per-repo config files. Revisit when a repo needs a pattern that would be wrong for others.
- A dated-suffix rule for dossier name collisions. Kept files overwrite their earlier dossier copy, as today. Revisit if a kept file is ever clobbered by a later session's copy and that matters.
- A repo filter on the page server to hide employer tasks. It binds to 127.0.0.1 only and checks the Host header. Revisit if the page is ever exposed beyond loopback.
- A sandboxing Content-Security-Policy on `/dossier/` responses. Dossier HTML pages legitimately run scripts, and every dossier file is Jet's or an agent's own output. Revisit if dossier files ever come from outside the store's own writers.
- Content scanning of kept files for secrets. Kept files are a short explicit list of wb's own files plus what Jet names with `--keep`; the filename guard (KTD4) covers the common leaks. Revisit if a secret is ever found in a dossier.
- A generated block inside `ladder.md`. A generator rewriting a file Jet edits risks clobbers; generated ladder status lives in the index and the page instead. Revisit if Jet wants status visible while editing the ladder in nvim.
- A `changes --since` query in wb-store. Nothing in this plan uses it; its consumer is the on-hold cross-agent sync task. Revisit when that task is re-planned; it must then include uncommitted and untracked files, not just the git log.
- Keeping both layouts live for weeks (the first stage 0 pilot design). Rejected for two code paths and a manual step at every save; the trial window is days, on one family.

#### Deferred to Follow-Up Work
- A tmux key binding for `wb page` (likely next to `prefix+t`), once the page earns daily use.
- A store-wide index page on the server, decided together with the store-wide board's fate (R2).
- goreleaser for wb-store, once it is installed anywhere other than by the shim.
- A `.cache/store.json` derived cache, only if the reader or the page proves slow.

### Dependencies / Assumptions

- The reply log format (`docs/guides/reply-log.md`: frontmatter `session_id, task, cwd, branch, created`, one `## <time> · <prompt>` section per turn with `### Prompt`, `### Reply`, `### Artifacts`) stays stable. R17's recent replies depend on it.
- tmux pane options set by `claude-notify-hook.sh` (`@claude_blocked`, `@claude_working`, `@claude_session_id`), Claude Code's session registry `~/.claude/sessions/<pid>.json` and the statusline cache `~/.cache/claude-status/<session-id>.json` are the sources of live session state (phase 3). The registry and statusline payload are undocumented internals.
- PR state comes from `gh` for Sportable repos and `pgh` for personal repos.
- Go 1.24 is installed on Jet's machines; the shim builds wb-store from source on first use.
- The store has about 480 task files today, and its working tree usually holds other sessions' uncommitted edits.

### Sources / Research

All in `~/code/tasks/dossiers/dotfiles--wb-future-direction/` unless noted:

- `brainstorm-scratch/adversarial-bash-vs-go.md`, `brainstorm-scratch/wb-grounding.md`, `brainstorm-scratch/pov-build-order.md`: complexity split, command and caller inventory, the B' assessment.
- `planning-research.md`, `wb-components.md`, `deletion-audit.html`: deletion candidates, component map, the item-by-item deletion decisions.
- `plan-revalidation-2026-10-25.md` and `-detail.md`: per-unit verdicts against the 25 merges between 2026-10-18 and 2026-10-26, with rulings.
- `pragmatic-review-2026-10-22.md`: ordering and sizing review.
- `research-multi-session-coordination.md`: the cut `changes` query (its §7a), for the cross-agent sync re-plan.
- `stage-0-grounding.md`: the layout questions Q1–Q8 and their answers.
- `stage-0-pilot-plan.md`: stage 2's steps, risks and undo.
- `research-file-formats.md`: formats per file and the YAML rules.
- `dossiers/dotfiles--research-ladder-planning-patterns/`: the ladder and brief research.
- In dotfiles: `scripts/.config/scripts/tmux/wb.sh` (`cmd_append`, `_wb_append_under_heading`, `wb_append_handoff`, `cmd_done`, `_ctrl_x`, `_wb_family_stems`, `_wb_family_tree`, `wb_family_all_done`, `wb_family_close_target`, `_wb_concepts_paths`, `wb_task_files`, `wb_credential_shaped`, `wb_session_task_file`, `cmd_task_file`), `wb-board.sh`, `wb-locks.sh`, `wb-capture.sh`, `docgen.sh` (the build-on-demand shim pattern), `claude/.claude/skills/review-page/scripts/review-page.py` (the localhost-server precedent).
- Existing Go tools: `~/code/docgen` (goldmark, `html/template`), `~/code/notes-tui` and `~/code/replay-tui` (cobra, `cmd/` + `internal/`, `embed.FS`).

---

## Planning Contract

### Key Technical Decisions

**Dossier layout (stage 2)**

- KTD16. **The layout is written through the existing locked verbs.** `wb append <task> Decisions|Handoffs|Follow-ups -` keeps its name, arguments and stdin contract. On a task whose frontmatter has `layout: dossier`, `Decisions` and `Follow-ups` write a record file instead of appending under a heading. `Handoffs` (what `/wb-save` calls) does KTD20's move-and-replace instead, through the same helper `wb_append_handoff` uses for automatic stamps. The per-task side-car lock is still taken, because the write and the view rebuild must not interleave. Why: 11 skills, the hooks and the nvim Lua call these verbs, and most skills then need no change. Governs R6, R25, AE8.
- KTD17. **Record files.** One directory per series inside `dossiers/<stem>/`:

  | Series | File name | Frontmatter | Body |
  |---|---|---|---|
  | `decisions/` | `<YYYY-MM-DD-HHMM>-<slug>.md` | `status: in-force\|superseded`, `supersedes: []`, `superseded_by: []`, `review_at:` | `# <title>`, then the Decided / Rejected / Why bullets as `/wb-decide` writes them today |
  | `handoffs/` | `<YYYY-MM-DD-HHMM>.md` | `source:` (`wb-save`, `wb done`, …), `auto: true\|false` | Done / In flight / Next, the optional `run` block, or the one-line automatic note |
  | `open-items/` | `<YYYY-MM-DD>-<slug>.md` | `who:`, `since:`, `kind:`, `status: open\|closed` | the item text |

  The slug comes from the title: lowercase, hyphens, at most 50 characters. A name collision gets `-2`, `-3`. A `### <ts> — <title>` heading in the piped text supplies the timestamp and title; text with no heading gets the current time and its first line as title. Governs R25, R30.
- KTD18. **Generated views are rebuilt by one bash function inside the lock.** `wb_render_views <task>` writes `decisions.md` (in force first, superseded collapsed under one heading), `handoffs.md` (newest first) and `index.md` (pages grouped by their `tags:`, plans and specs pinned first, retired pages behind one link, child pages under each child). It is deterministic, so a rebuild with nothing new is a no-op, and it is plain bash plus POSIX awk (the test sandbox runs both gawk and mawk). Its first line is `<!-- generated by wb from dossiers/<stem>/…; do not edit -->`. Generated views are committed, never read back by wb itself; readers that need records read the record files. The Go reader replaces this function in phase 2. Governs R25, R33.
- KTD19. **Superseding is one locked operation.** `wb decide-supersede <task> <old-id> -` (old id = the old file's name without `.md`) writes the new decision with `supersedes: [<old-id>]` and sets the old file's `status: superseded` and `superseded_by: [<new-id>]`, then rebuilds the views. `/wb-decide` calls it whenever it would have written a `(supersedes: …)` line. Governs R26, AE1.
- KTD20. **`## Now` is replaced, never appended.** `wb now <task> -` replaces the task file's `## Now` block with stdin, under the lock. `/wb-save` writes it; it holds goal, current rung, next action and what waits on Jet. The newest handoff stays in the task file under `## Handoffs`; each new one moves the previous one to `handoffs/` first. Governs R24, AE9.
- KTD21. **A per-task switch for the trial only.** `layout: dossier` in a task's frontmatter selects the new paths in every writer and reader that U10–U12 touch. Tasks without it keep today's paths. At the switch (U14) every task gets the layout, then the old paths and the switch itself are deleted from `wb.sh` and the skills. Governs R32.
- KTD22. **Migration rules.** `wb migrate <task>|--all [--dry-run]` takes each task's own lock (`wb_task_lock_acquire_guarded`) while it converts that task; wb has no store-wide lock. A task whose lock is held is skipped and listed, and `--all` ends by reporting every skipped task. Per task, it:
  - parses `## Decisions` in four written styles: `2026-10-17 — **Bold lead.** …`; `### 2026-10-09 15:30 — <title>` with Decided/Rejected/Why bullets; `2026-10-18 decision-page <slug> r1: …`; and the most common one, a dated top-level bullet such as `- **2026-10-18 (Jet): <title>.** …` or `- 2026-10-18 — …`, whose indented lines belong to it. It moves `_No decisions: <reason>_` markers to the migrated-history file;
  - loses nothing: every non-blank line of `## Decisions` lands in exactly one output file. A `## Decisions` section with any line the parser can't attribute to an entry is not split: the whole section, verbatim, becomes one decision record titled "Decisions before the dossier layout", dated from `created:`, and is listed as an exception with those line numbers (amended 2026-11-02: the U13 rehearsal found 83 tasks with free-form decision text, which this rule had left unmigrated);
  - keeps each prose `(supersedes: …)` marker as raw text in the new decision's body, leaves that decision `in-force` and lists the marker as an exception. Only about four task files hold one, so the real ones are linked by hand with `wb decide-supersede` after migration;
  - gives an entry with no time the date at `0000`, then `0001`, … in file order, and an entry with no date the previous entry's date, listing each as an exception;
  - moves all but the newest `## Handoffs` entry to `handoffs/`; moves open `## Follow-ups` items to `open-items/`;
  - writes ticked follow-ups, `## Done` and the `_No decisions:` markers into one migrated-history file per task: a handoff record named `handoffs/<created date>-0000.md` (so it sorts as the oldest), with `source: migrate` and `auto: true`;
  - leaves `## Plan` in place (families split it when next worked on), and adds an empty `## Now` for the next `/wb-save` to fill;
  - writes into a temporary directory, checks the counts, then moves the files in. A task that already has the layout is skipped, so a second run changes nothing.

  It prints one count line per task (decisions, handoffs, open items, history items, exceptions). The "before" figures are counted straight from the source text (dated entry lines and headings, handoff headings, checkbox lines), not by the parser, so a misparse shows up as a mismatch. Governs R31, AE7, AE10.
- KTD23. **The reader list is built by search, not memory.** U12 starts by searching dotfiles and the store tooling for every reader of `## Decisions`, `## Handoffs`, `## Follow-ups`, `## Done`, `## Plan` and `CONCEPTS.md` (24 scripts and skills at the last count) and commits that list in the PR body. Each entry is either updated, or noted as reading frontmatter only. Governs R32.
- KTD24. **`concepts.md` replaces `CONCEPTS.md` at the switch.** `_wb_concepts_paths` reads `concepts.md` (and, during the trial, `CONCEPTS.md` for tasks without the layout). The `@` import lines in each live worktree's `CLAUDE.local.md` managed block are rewritten by `wb family <task> --reseed`. Running sessions pick up the rename only after `/clear` or a restart, because a new import line takes effect only then. Governs R27.
- KTD25. **`brief.md` replaces the "First action" seed.** `wb new` and the handoff skill write a `brief.md` draft (type, why, done when, not doing, claims marked checked or assumed with their date; bug fields for bugs) instead of a "First action" line in the task file. The first session confirms the blank or assumed fields one question at a time. Governs R27.

**`wb done` rework (stage 5, written for the new layout only)**

- KTD1. **Classify every gitignored entry first, mutate only after the whole set is classified.** The order of gates is: the undecided-drafts check (since PR #110, which made decision capture shelf-only), then the dirty-worktree check, then classification. `wb done` reads `git status --porcelain --ignored`, sorts each entry into keep / throwaway / unknown, and exits non-zero before any copy, worktree removal or task-store write if an unknown remains. Why: `git worktree remove --force` is irreversible, and a stop halfway through a copy would leave a half-swept dossier. Governs R20.
- KTD2. **Sweep lists live in one stowed file, read through `wb.sh`'s resolved path.** The file is `scripts/.config/scripts/tmux/wb-done-sweep.list` (named apart from the decision-capture sweep), with `keep:` and `throwaway:` glob lines, located via `readlink -f` on `wb.sh`. Patterns use gitignore-style matching: a pattern without a `/` matches at any depth, and a trailing `/` matches a directory or a symlink to one. Seed keep: `.claude-queue.md`, `CLAUDE.local.md`. Seed throwaway: `node_modules/`, `dist/`, `build/`, `.venv/`, `venv/`, `__pycache__/`, `target/`, `coverage/`, `logs/`, `*.log`. (session-settled: user-directed.) Governs R20.
- KTD3. **Bootstrap copies identical to main are throwaway.** An entry listed in the repo's `.worktree-bootstrap` is throwaway when it is a symlink, or when it is a file byte-identical (`cmp -s`) to the main checkout's copy. A differing copy is unknown. A fully ignored directory arrives as one collapsed entry (`.claude/`); a collapsed entry that no list pattern matches is expanded to its files (`find -P`) and each file is classified on its own. Governs R20 (AE5).
- KTD4. **Credential-shaped entries can never be kept.** `wb_credential_shaped` grows to cover `config.hjson`, `*.env.json`, `.npmrc`, `.netrc`, `*.tfvars`, `.pgpass`, `id_ecdsa*`, `*.keystore`, `*.kdbx`, `*token*` and `*password*`. A credential-shaped entry matched by a keep pattern or named in `--keep` is reported as unknown with a "credential-shaped, copy it yourself" note. Directories being kept are walked without following symlinks; a credential-shaped file inside one, or a symlink resolving outside the worktree, also stops the run. Vendor directories on the throwaway list are never walked. Governs R21.
- KTD5. **One-off resolution is a re-run flag; there is no prompt.** `--keep <path>` and `--throwaway <path>` are repeatable flags that classify a named entry for this run only. A flag naming a path that is no longer present warns and continues. Why: agents run `wb done` in background Bash and the picker runs it inside an fzf binding, so neither has a TTY. Governs R20 (AE6).
- KTD6. **One locked burst after teardown; `--review` is the only buffer.** Every keep copy must succeed before teardown. The default path holds no lock until after `git worktree remove`, then in a single locked burst writes the `wb done` handoff record (the existing `done_note` wording, plus `kept:` and `discarded:` lines), `status done`, `closed` and `claude_sessions ""`. `--review` calls `wb_open_buffer` on the task file after classification and before teardown, with no lock held, and also applies to store-only closes. The `## Sweep` machinery and `wb_sweep_section` are removed. Governs R19, R22.
- KTD7. **Picker ctrl-x shows a stop in a tmux popup.** `_ctrl_x` keeps its y/N prompt, captures `cmd_done`'s output and, on a non-zero exit, shows it with `tmux display-popup` (falling back to `display-message`), so neither an unknown-entry stop nor the undecided-drafts refusal vanishes in the fzf redraw. Governs R20.
- KTD8. **close-out runs `wb done` in the foreground and relays its output verbatim.** The `--close` self-kill hazard, the "never retry or add `--leave-shelved` after a stop" rule, and the rules for winding down other sessions (pass `--close` by default; take names from `tmux list-sessions`, never a task stem; one `wb done --close <session>` per worker) move from the deleted `wb-done` skill into close-out and the wb guide. close-out keeps its `_No decisions: <reason>_` step. `wb done` keeps its "all children of <task> are done" hint (`wb_family_all_done`, `wb_family_close_target`). Governs R19.

**Retired**

- KTD9 (the `## Artifacts` line grammar) and KTD10 (the prose `(supersedes: …)` marker as the reversal record) are retired, replaced by page frontmatter (R28) and KTD19. The migration keeps KTD10's existing markers as raw text and lists them for linking by hand (KTD22).
- KTD28 (the `changes` query) is cut from this plan: nothing in it uses the query. It returns when the on-hold cross-agent sync task is re-planned, and must then cover uncommitted and untracked files, because the store's working tree usually holds other sessions' edits.

**Go store (stages 3 and 4)**

- KTD11. **wb-store is its own repo, built on demand by a dotfiles shim.** The repo is `~/code/wb-store` (module `github.com/jetnoli-sportable/wb-store`, Go 1.24, cobra, `cmd/` + `internal/`, following replay-tui). The shim `scripts/.config/scripts/wb-store.sh` follows `docgen.sh`, with three differences: a recursive source `find` that prunes `.git` and `.worktrees` and counts embedded templates; building to a temp file and then `mv`; and `TASKS_DIR` passed through as `--store`. Test data is made up, shaped like real files, never copied from the store. (session-settled: user-approved.) Governs R3, R8.
- KTD12. **The reader reads the dossier layout only, with strict frontmatter.**
  - a task file is a `<repo>--<slug>.md` file whose line 1 is exactly `---`;
  - frontmatter follows R30's YAML rules with YAML 1.2 semantics (check the chosen library's version before writing the parser); a file whose frontmatter doesn't parse is reported by path and skipped by `list`, and is an error for `show`;
  - `## Now` and `## Handoffs` are found with fence-aware heading detection (the rules from `_wb_lint_sections_records`, recovered from git history before the deletion pass removed it);
  - records are read from their files, never from the generated views;
  - absent and empty values are null; lists are never null.

  Governs R3, R5, R30.
- KTD13. **Output is plain text by default, with `--json` as a normalised document carrying `schema_version: 1`.** `show`, `family` and `list` share one model. Lists are always arrays, absent scalars are null, and dates are strings. (session-settled: user-approved.) Governs R5.
- KTD14. **Task resolution order:** exact stem, then `<query>.md`, then a literal path, then a unique case-insensitive substring. Several substring matches list the candidates and exit 2. Governs R5.
- KTD15. **The page server re-reads the whole store on every request, with no cache.** Go `net/http`, bound to `127.0.0.1`, port 8766 falling forward up to 10 ports; a Host-header check; templates in `embed.FS`; dossier files served through `/dossier/<stem>/<path>` (so snap Chromium never needs `file://`) only if the symlink-resolved path stays inside the real dossier root; `serve` runs in the foreground; `wb page` probes `/healthz` on ports 8766–8775 and reuses a server reporting the current build id, starting a detached one only when none answers; the browser opens with snap chromium, `xdg-open` or macOS `open` unless `--no-open`. (session-settled: user-directed.) Governs R4, R14, R17.
- KTD26. **Family walks match `wb family`.** The root is found by walking `parent` up to 20 levels, with a cycle guard that fails open, and children come from reverse `parent` edges, in the same order as `_wb_family_tree`. A parity test runs both on the same fixture store. Governs R11.
- KTD27. **Recent replies come from the reply log, read-only.** The reader matches `~/.claude/replies/<id>.md` to a task by the log's `task:` frontmatter key and returns the last few turns (prompt, the start of the reply, artifacts). The resume command it shows uses the newest in-file activity, computed as `wb_resume_id` does, never the `@primary` mark. Governs R13, R17.

### High-Level Technical Design

**The dossier layout after stage 2:**

```text
~/code/tasks/
  <stem>.md                 frontmatter (+ layout: dossier during the trial), ## Now, newest handoff
  dossiers/<stem>/
    index.md                generated: pages by tag, retired behind one link, children's pages
    notes.md                Jet's scratch; agents read only when pointed to, never write
    brief.md                opening prompt and overview, drafted at task creation
    spec.md                 what is being built and what done means (parent or standalone task)
    ladder.md               rungs, hand-written only (family parent)
    concepts.md             settled facts and vocabulary, imported into family worktrees
    decisions/              <YYYY-MM-DD-HHMM>-<slug>.md, one per decision
    decisions.md            generated, read-only
    handoffs/               <YYYY-MM-DD-HHMM>.md, one per snapshot
    handoffs.md             generated, read-only
    open-items/             <YYYY-MM-DD>-<slug>.md, one per open item
    components/             architecture pages and diagrams, phased by rung
    <page>.md / <page>.html pages, each with the frontmatter block (R28)
```

A child's dossier has only the parts it writes (R29).

**Stage 2 in four steps** (from `stage-0-pilot-plan.md`):

| Step | Units | Where | Ends when |
|---|---|---|---|
| Build | U10, U11, U12 | one dotfiles PR | merged and re-stowed |
| Rehearse | U13 | a full store copy under `~/.cleanroom/` | every count matches or is an approved exception |
| Trial | U14 | this family, `layout: dossier`, 3–5 days (cap a week) | the two pilot reviews are held and their fixes merged |
| Switch | U14 | the whole store, one commit; then a second dotfiles PR deletes the old path | a day of normal work on the switched store |

**`wb done` after the rework.** Every path that changes anything sits below the gates.

| Step | What happens | On failure |
|---|---|---|
| 1 | Undecided-drafts check (unless `--leave-shelved`) | exit 1, nothing changed |
| 2 | Live worktree? If not, skip to step 7 (store-only close) | |
| 3 | Drift and dirty-worktree checks | exit 1, nothing changed |
| 4 | Classify every gitignored entry | any unknown: exit 1 naming each entry and the flags, nothing changed |
| 5 | `--review`: open the task file buffer, no lock held | |
| 6 | Copy keep entries to the dossier; `git worktree remove --force` | failed copy: exit 1, nothing removed |
| 7 | Locked burst: the handoff record with `kept:`/`discarded:` lines, status, `closed`, `claude_sessions` | |
| 8 | `--close`: kill the tmux session | |

**Sweep classification**, applied per `git status --ignored` entry (directories arrive collapsed with a trailing `/`). The first matching row wins.

| Order | Condition | Class |
|---|---|---|
| 1 | named by `--throwaway <path>` | throwaway |
| 2 | named by `--keep <path>` and not credential-shaped | keep |
| 3 | listed in `.worktree-bootstrap` and a symlink, or `cmp -s` identical to main | throwaway |
| 4 | credential-shaped, or a kept dir contains a credential-shaped file | unknown (credential note) |
| 5 | matches a `keep:` glob | keep |
| 6 | matches a `throwaway:` glob | throwaway |
| 7 | anything else | unknown |

**wb-store components.** Every request starts from a fresh `store.Load`.

| Component | Reads | Feeds |
|---|---|---|
| `store.Load` | task files, dossier records and page frontmatter | the task model |
| task model | | decisions with supersession links, open items, artifacts, session hints, recent replies |
| family | the task model | root, children, deps met/unmet/dangling/cycle, planning summary, ladder status |
| CLI | model and family | `show`, `list`, `family`, text or `--json` |
| web | model and family | `/task`, `/family`, `/dossier`, `/healthz` |
| dotfiles shim `wb-store.sh` | | builds when stale; used by the CLI callers and `wb page` |

**`--json` shape** (directional; the golden files in U6/U7 are authoritative):

```text
{ schema_version: 1,
  task: { stem, repo, title, status, layout, path[], parent, rung, depends_on[{stem, state, status}],
          size, priority, value, tags[], jira, pr[], created, closed, reviewed, mtime,
          now, latest_handoff{at, source, body},
          decisions[{id, at, title, status, supersedes[], superseded_by[], review_at, body}],
          open_items[{id, who, since, kind, text}],
          artifacts{ pages[{path, tags[], rung, links[], url, visibility, retired}],
                     other_files[{path, kind}], prs[] },
          session{ expected_tmux, worktree, branch, resume_id, recent_replies[{at, prompt, reply_head, artifacts[]}] } },
  family: { root, children[], unblocks[], ladder{ rungs[{label, status, tasks[], decisions_due[]}] },
            planning{ startable[], blocked[], missing[] } },
  warnings[{kind, detail}] }
```

**Unit order.**

| Stage | Units, in order | Can run beside |
|---|---|---|
| 2 | U10 → U11 → U12 (one PR), then U13, then U14 | nothing; it changes the store |
| 5 | U1 → U2 → U3 | U6 once U14's switch has landed |
| 3 | U6 → U7; U9's shim after U6 | stage 5 |
| 4 | U8, then U9's `wb page` | — |

### Output Structure

The new repo, `~/code/wb-store`:

```text
wb-store/
  go.mod
  README.md
  cmd/wb-store/main.go
  internal/store/        frontmatter.go taskfile.go records.go pages.go task.go resolve.go discover.go
                         family.go ladder.go replies.go session.go
                         *_test.go
                         testdata/store/   (made-up task files and dossiers)
                         testdata/golden/  (show/family/list text + json)
  internal/render/       text.go json.go *_test.go
  internal/web/          server.go open.go *_test.go
                         templates/        layout.html task.html family.html
```

### Phased Delivery

- **Phase 1 (this plan: stages 2, 5, 3, 4).** The layout and store switch, the `wb done` rework, and the prototype week. Phase 1 ends with Jet's yes/no on the page.
- **Phase 2: Go owns writes (outline only).** `wb-store` gains `set`, `status`, `jira-set`, `append`, `now`, `decide-supersede`, `new` (seeding, including `brief.md`), `breakdown --apply` and the view rendering that `wb_render_views` does in bash. Each wb verb keeps its name, arguments and messages (R6), and becomes a thin bash wrapper that runs its tmux-aware checks and then calls the binary. Go takes the same side-car lock through `syscall.Flock`, with the same 1-second wait and exit-75 contention message (R7, AE3). One file per record makes this smaller than it was: most writes create a new file, and only the view rebuild and the supersede flip touch existing ones. The byte-identical proof against today's writers (AE2) covers `wb set`'s `pr`, `branch` and `--unset` forms and the varying `done_note` handoff wording. Raw `Edit`/`Write` under `~/code/tasks` already asks first (the store-guard hook). store-specialist's reads move to `show`/`family`. Worth adding while here: bash `wb family` takes its member list from `wb-store family --json` and keeps only its tmux and worktree work (`--sessions`, `--reseed`, `--concepts`), so one family walk remains instead of two (`_wb_family_tree` and Go's `Store.Family`). Until then the two agree because `wb_task_files` lists files in byte order, as Go does, and wb-store's parity test runs bash under an en_US locale to keep it that way (W9 review, 2026-11-04).
- **Phase 3: tmux and PR data plus the live page (outline only).** The reader adds live `@task` / `@claude_*` pane state, the session registry and statusline cache, and PR state from `gh` / `pgh` with a short cache. The page gains R14's live strip, refreshed on a short poll. Each source is added only once the page shows it is needed (R18). The terminal context card can read the same model.
- **Inbox (not in this plan).** The picker already highlights waiting sessions and shows each one's context card (PRs #120 and #121). What is left (waiting sessions in order, time since blocked) is designed in the walk-through task, together with day-start and day-end.

### Assumptions

- `wb_open_buffer` keeps its signature; a missing `open-buffer.sh` makes it `return 1` with the stow command, so `wb done --review` aborts under `set -e` before any change.
- `wb family <task> --reseed` rewrites the managed `CLAUDE.local.md` block in every live worktree of the family (shipped in PR #111).
- The store's own git history is the undo for the migration: a baseline commit before the switch, the switch as one commit.

---

## Implementation Units

Units are listed in run order: stage 2, stage 5, stage 3, stage 4. U4 and U5 are retired (end of this section).

### Stage 2 · Layout into wb

### U10. Layout writers, generated views and the trial switch

- **Goal:** on a `layout: dossier` task, every locked write lands in the dossier layout and the views stay current; every other task behaves exactly as today.
- **Requirements:** R24, R25, R26, R30, R32; KTD16–KTD21.
- **Dependencies:** stage 1 merged.
- **Files:**
  - `scripts/.config/scripts/tmux/wb.sh` (`cmd_append`, `_wb_append_under_heading`, `wb_append_handoff`; new `wb_layout_of`, `wb_record_write`, `wb_render_views`, `cmd_now`, `cmd_decide_supersede`; dispatch and `cmd_help`)
  - `scripts/.config/scripts/tmux/tests/wb-layout-writes.test.sh` (new)
  - `scripts/.config/scripts/tmux/tests/wb-append.test.sh` (old-path scenarios must still pass)
- **Approach:**
  1. `wb_layout_of <task_file>` reads the `layout:` key once; every writer branches on it.
  2. `wb_record_write <task> <series> -` parses an optional `### <ts> — <title>` heading from stdin, picks the file name (KTD17), writes the file atomically (temp then `mv`) and calls `wb_render_views`, all under the task lock.
  3. `cmd_append` routes `Decisions` and `Follow-ups` to `wb_record_write` on a layout task, and `Handoffs` to the step 4 helper; any other heading keeps today's behaviour.
  4. One shared helper, called by both `wb append <task> Handoffs -` and `wb_append_handoff`, moves the current newest handoff from the task file to `handoffs/` and writes the new one in its place (KTD20).
  5. `wb now <task> -` replaces the `## Now` block. `wb decide-supersede <task> <old-id> -` follows KTD19 and refuses if the old id doesn't exist or is already superseded.
  6. `wb_render_views` follows KTD18; `index.md` reads page frontmatter and, for a parent, walks children with `_wb_family_stems`.
- **Patterns to follow:** `_wb_append_under_heading` (lock use, stdin handling); `wb_task_lock_acquire_guarded`; `_wb_family_stems`.
- **Test scenarios:**
  - `wb append <layout task> Decisions -` with a `### 2026-11-01 18:45 — Stage 0 Q3: …` heading creates `decisions/2026-11-01-1845-stage-0-q3-….md` with `status: in-force`, and `decisions.md` lists it. (Covers AE8.)
  - The same command on a task without `layout:` appends under `## Decisions`, byte-identical to today. (Covers AE8.)
  - Two decisions in the same minute with the same title get `-2` on the second.
  - `wb append <layout task> Follow-ups -` creates an `open-items/` file with `since:` set to today.
  - `wb decide-supersede` writes the new file and flips the old one in one call; an unknown or already-superseded old id exits 1 with nothing written. (Covers AE1's mechanism.)
  - Three `wb_append_handoff` calls leave one handoff in the task file and two in `handoffs/`, and `handoffs.md` lists them newest first. (Covers AE9.)
  - Three `wb append <layout task> Handoffs -` calls (the `/wb-save` path) give the same result. (Covers AE9.)
  - `wb now` replaces `## Now` and leaves the rest of the file unchanged; a file without `## Now` gains it after the frontmatter.
  - `wb_render_views` run twice in a row produces no diff, under gawk and mawk.
  - `index.md` groups a fixture dossier's pages by tag, puts a `retire_when`-matched page under the retired link, and lists a child's pages under the child.
  - A concurrent `wb append` from two shells on one layout task produces two files and a view listing both.
- **Verification:** the new and touched tests pass in the Docker sandbox; shellcheck reports nothing new; `wb help` lists `now` and `decide-supersede`.

### U11. The migration command

- **Goal:** `wb migrate` converts any task file into the layout, losing nothing and changing nothing on a second run.
- **Requirements:** R31; KTD22.
- **Dependencies:** U10.
- **Files:**
  - `scripts/.config/scripts/tmux/wb.sh` (`cmd_migrate`, dispatch, help) or, if it passes about 300 lines, a sourced `wb-migrate.sh` beside it
  - `scripts/.config/scripts/tmux/tests/wb-migrate.test.sh` (new)
  - `scripts/.config/scripts/tmux/tests/fixtures/migrate/` (new, made-up task files)
- **Approach:**
  1. Parse sections fence-aware. Split `## Decisions` into entries using the four styles in KTD22, and check that every non-blank line was attributed.
  2. Keep prose supersede markers as raw text and list each as an exception.
  3. Write everything for one task into a temporary directory, count, then move into `dossiers/<stem>/` and rewrite the task file (frontmatter + `layout: dossier` + empty `## Now` + newest handoff + untouched `## Plan` and any unknown sections).
  4. `--dry-run` prints the count lines and exceptions only. `--all` walks `wb_task_files`.
- **Test scenarios:**
  - The AE7 fixture yields exactly the counts in AE7, and a second run is a no-op (`git diff` empty on a fixture repo). (Covers AE7.)
  - Dated top-level bullets (`- **2026-10-18 (Jet): …**` with indented follow-on lines) each become one decision file.
  - A `## Decisions` line that fits no style turns the whole section into one verbatim decision record dated from `created:`, and lists that line number as an exception.
  - A `(supersedes: 2026-10-17 "Probe 6")` marker stays as raw text in the new decision, which stays in force, and is listed as an exception.
  - The "before" counts come from the source text: a fixture whose entry the parser would merge into its neighbour shows a mismatch.
  - A task whose lock is held is skipped and named in `--all`'s report.
  - Entries with no time and no date get the KTD22 stamps and appear as exceptions.
  - A `_No decisions:` marker goes to the migrated-history handoff file, not `decisions/`.
  - A task with an unknown `## Notes for later` section keeps it in the task file and lists it as an exception.
  - `--dry-run` writes nothing.
- **Verification:** tests pass in the sandbox, including under mawk.

### U12. Skills and readers learn the layout

- **Goal:** every skill and script that reads or writes the old sections works on a layout task, found by search (KTD23).
- **Requirements:** R24, R27–R29, R32; KTD20, KTD23–KTD25.
- **Dependencies:** U10.
- **Files** (the search may add more; each is listed in the PR body):
  - `claude/.claude/skills/wb-save/SKILL.md` (write `## Now` via `wb now`; mention `notes.md` when it changed since the last save)
  - `claude/.claude/skills/wb-resume/SKILL.md` (read `## Now` and the newest handoff in the task file, then `handoffs/` if needed; mention a changed `notes.md`)
  - `claude/.claude/skills/close-out/SKILL.md`, `claude/.claude/skills/handoff/SKILL.md` (and `scripts/.config/scripts/tmux/handoff.sh`: open items to `open-items/`; seed `brief.md` instead of a "First action" line)
  - `claude/.claude/skills/wb-decide/SKILL.md` (supersede through `wb decide-supersede`)
  - `claude/.claude/skills/decision-page/SKILL.md` (published pages get the R28 frontmatter block)
  - `claude/.claude/agents/store-specialist.md` (where each record now lives)
  - `scripts/.config/scripts/tmux/wb-capture.sh` and `wb-capture-sweep.sh` (read `decisions.md` or `decisions/`; the `.stale` side-car counted `### ` entries in `## Decisions`)
  - `scripts/.config/scripts/tmux/claude-card.sh` (last decisions from `decisions/`)
  - `scripts/.config/scripts/tmux/wb-board.sh` (its decisions feed reads `## Decisions`, which the switch removes; read `decisions/` instead, so R2's board keeps working)
  - `scripts/.config/scripts/tmux/wb.sh` (`_wb_concepts_paths`, `wb new`'s seed, a tmux-free `wb notes` that prints the `notes.md` path; the ghost-row fix from retired U4: `wb_task_files` accepts only `<repo>--<slug>.md` stems, which `wb migrate --all` relies on)
  - `tmux/.config/tmux/tmux.conf` (a key that opens `notes.md`, next to `prefix+t`)
  - `~/code/tasks/README.md` and `TEMPLATE.md` (the layout, the frontmatter rules, `pr:` and `layout:` keys; committed in the store, staging only these two files)
  - `docs/wb-guide.md`, `docs/guides/*.md` that describe the old sections
- **Approach:**
  1. Run the KTD23 search and commit its list.
  2. Update each reader to check `layout:` and read the new location; keep the old path for tasks without it until U14.
  3. Skills that only call `wb append` need no change; confirm each one.
  4. Regenerate docs with docgen and commit `docs/*.md` edits in their own commit.
- **Test scenarios:**
  - Skill walkthrough on a scratch layout task: `/wb-save` rewrites `## Now` and moves the old handoff; `/wb-resume` then finds the entry it wrote.
  - `/wb-decide` reversing a decision produces a superseded pair, not a prose marker.
  - The capture sweep, run against a layout task with three decisions, counts three.
  - The context card shows the newest decision from `decisions/`.
  - `_wb_concepts_paths` returns `concepts.md` for a layout task and `CONCEPTS.md` for an old one.
  - `wb new --planned` writes `brief.md` and no "First action" line.
  - `wb_task_files` does not return `AGENTS.md`, `CLAUDE.md`, `README.md` or `TEMPLATE.md`.
  - The notes key opens `dossiers/<stem>/notes.md` for the current session's task.
- **Verification:** touched tests pass in the sandbox; the KTD23 list in the PR body has an outcome for every entry; docgen is idempotent.

### U13. Rehearsal on a full store copy

- **Goal:** the migration has run over every real task file before it touches the live store, and every exception has been seen by Jet.
- **Requirements:** R31, R32; KTD22.
- **Dependencies:** U10–U12 merged and re-stowed.
- **Files:** none in dotfiles unless a fix is needed. Output: `~/code/tasks/dossiers/dotfiles--wb-future-direction/rehearsal-<date>.md` (the count lines and exceptions).
- **Approach:**
  1. Copy the store to `~/.cleanroom/wb-future-direction-rehearsal/` (never `/tmp`, and never the live store).
  2. Run `wb migrate --all` there with `TASKS_DIR` pointing at the copy.
  3. Check counts for every task; read the post-processor coordinator's result by hand.
  4. Run `/wb-resume` and `/wb-save` against a copied task in a scratch session pointed at the copy.
  5. Fix what breaks in a small follow-up PR, then re-run from a fresh copy.
- **Test scenarios:**
  - Every task's counts match, or it is listed as an exception with the reason. (Covers AE10.)
  - A second `wb migrate --all` on the copy changes nothing.
- **Verification:** Jet has read the exceptions list and said go for the trial.

### U14. Trial on this family, the pilot reviews and the store switch

- **Goal:** the layout runs for real on this family for a few days, its two pilot reviews are held, and then the whole store switches in one commit.
- **Requirements:** R24–R33, AE1; KTD21, KTD24.
- **Dependencies:** U13.
- **Files:**
  - Store: this family's task files and dossiers (migration commit); later every task (switch commit)
  - This family's `spec.md` and `ladder.md`, hand-split from `## Plan` and reviewed by Jet
  - `dossiers/dotfiles--wb-future-direction/open-items/pilot-friction.md` (friction noted during the trial)
  - A second dotfiles PR: delete the old paths and the `layout:` switch from `wb.sh` and the skills
- **Approach:**
  1. **Trial start:** set `layout: dossier` on this family's tasks, run `wb migrate` on them, commit. Record the AE1 step-back as a decision superseding Probe 6 with `wb decide-supersede`. Split `## Plan` into `spec.md` and `ladder.md`; add the R28 frontmatter block to this family's pages.
  2. **Trial:** work normally for 3–5 days (cap a week). Anything not fixed by then becomes an open item after the switch, not a reason to wait.
  3. **Reviews at the end of the trial:** does one file per decision plus a generated log read well? Does `brief.md` cut the early "what does X mean" questions (count of `reframe`-tagged decisions; how often Jet asks what something means in the first five turns)? How should the committed generated views behave when two clones write (they conflict on pull): a regenerate-after-pull step with a merge rule, or views kept out of git? Record each answer as a decision.
  4. **Switch:** ask every live session to `/wb-save` and stop writing; commit the store as a baseline; run `wb migrate --all` and commit it as one commit; `wb family <task> --reseed` for each family with a live worktree; re-stow.
  5. **After a day of normal work:** merge the deletion PR and re-stow. Until then, `git -C ~/code/tasks revert <switch commit>` is the undo, but it is clean only before sessions write new record files; after that, fix forward.
- **Test scenarios:**
  - After step 1, the task page's future data is present on disk: AE1's pair has the right `status` and links.
  - Store-wide counts before and after the switch commit match the rehearsal's numbers, apart from tasks changed since.
  - After the deletion PR, the full wb test suite shows no new failures against a clean-room baseline.
- **Verification:** both reviews are recorded in Decisions; the switch is one store commit after a baseline commit; no task file in the store still has a `## Decisions` section.

### Stage 5 · `wb done` rework

### U1. Sweep classifier and lists

- **Goal:** a pure, testable classifier that sorts a worktree's gitignored entries into keep / throwaway / unknown, plus the seeded list file.
- **Requirements:** R20, R21; KTD1–KTD5.
- **Dependencies:** U14 (the store has switched).
- **Files:**
  - `scripts/.config/scripts/tmux/wb.sh` (new classifier helpers near `wb_credential_shaped`; extend `wb_credential_shaped`; keep `wb_safe_rel`)
  - `scripts/.config/scripts/tmux/wb-done-sweep.list` (new)
  - `scripts/.config/scripts/tmux/tests/wb-done-sweep.test.sh` (new)
- **Approach:**
  1. Add a list loader that reads `wb-done-sweep.list` from `wb.sh`'s resolved directory (KTD2), ignoring blanks and `#` comments. Mirror `wb_bootstrap`'s manifest-reading style.
  2. Add a classifier function that takes the worktree, the main checkout and the one-off `--keep`/`--throwaway` paths. It prints one `class<TAB>path<TAB>note` line per entry, applying the classification table in order (KTD3, KTD4, KTD5).
  3. Extend `wb_credential_shaped` with the KTD4 patterns. It stays basename-based and case-insensitive.
  4. The walk of a directory being kept uses `find -P` (no symlink following) and checks each file with `wb_credential_shaped`.
  5. Plain bash and POSIX awk only, so it also runs under mawk and macOS awk.
- **Patterns to follow:** `wb_bootstrap` (manifest parse); `wb-board.sh`'s `readlink -f` load of `wb-board-dag.sh`; `wb_safe_rel` containment.
- **Test scenarios:**
  - `.claude-queue.md` in the worktree classifies as keep.
  - `node_modules/` and `app.log` classify as throwaway, and `node_modules/` is not walked even if it contains `aws-credentials.js`.
  - A bootstrap-listed `config.hjson` identical to main classifies as throwaway; the same file with one byte changed classifies as unknown with the credential note. (Covers AE5.)
  - A bootstrap-listed directory that is a symlink into main classifies as throwaway.
  - Nested `apps/web/node_modules/` and a symlinked `node_modules` both classify as throwaway.
  - A collapsed `.claude/` entry holding only a bootstrap-listed `settings.local.json` identical to main classifies as throwaway; with an extra unlisted file beside it, that file classifies as unknown.
  - A kept directory holding a symlink to a file outside the worktree classifies as unknown.
  - Unlisted `scratch/notes.txt` classifies as unknown; with `--keep scratch/notes.txt` it classifies as keep. (Covers AE6.)
  - `--keep .env` still classifies as unknown with the credential note.
  - A kept directory holding a nested `.env` classifies the directory as unknown.
  - `--throwaway gone.txt` for an absent path prints a warning and doesn't fail.
  - A list file with comments, blank lines and trailing spaces parses cleanly.
  - An entry escaping the worktree via `..` or a symlink is rejected by `wb_safe_rel`.
- **Verification:** the new test passes in the Docker sandbox under gawk and mawk, and shellcheck reports nothing new.

### U2. `wb done` rewired: stop before change, keep, discard record, `--review`

- **Goal:** `cmd_done` uses the classifier, stops before any change on unknowns, copies keep entries, records kept/discarded entries in its handoff record, and opens a buffer only under `--review`.
- **Requirements:** R19, R20, R22; KTD1, KTD5, KTD6, KTD7.
- **Dependencies:** U1.
- **Files:**
  - `scripts/.config/scripts/tmux/wb.sh` (`cmd_done`, the usage header, `_ctrl_x`; remove `wb_sweep_section` and the `## Sweep` awk; update comments that describe the sweep)
  - `scripts/.config/scripts/tmux/tests/wb-done.test.sh`
  - `scripts/.config/scripts/tmux/tests/wb-queue.test.sh`
  - `scripts/.config/scripts/tmux/tests/wb-breakdown.test.sh`
  - `scripts/.config/scripts/tmux/tests/wb-lock-integration.test.sh`
  - `scripts/.config/scripts/tmux/tests/wb-schema.test.sh` (verify only)
- **Approach:**
  1. Parse `--review`, `--keep <path>`, `--throwaway <path>` alongside `--close` and `--leave-shelved`, and add usage lines so `wb help` shows all five.
  2. Keep the undecided-drafts check first. After it and the existing drift and dirty checks, run the classifier. On any unknown, print the stop message and exit 1. The message names each entry and its note, and suggests the list file and the one-off flags. Nothing has changed at that point.
  3. Under `--review` (live or store-only), call `wb_open_buffer "$task_file"` with no lock held.
  4. Copy keep entries into `$TASKS_DIR/dossiers/<stem>/<rel>` with `cp -a`. Any failed copy exits 1 before step 5 (KTD6).
  5. Run the existing `git worktree remove --force` guarded by `[ -d ]`, so a retry after a killed run is safe.
  6. Write one locked burst (KTD6): `wb_append_handoff "$task_file" "wb done" "$done_note."` with the `kept:` and `discarded:` lines added to its body, then status, `closed` and `claude_sessions`. Keep `done_note`'s wording, the `--leave-shelved` suffix and the "all children are done" hint.
  7. In `_ctrl_x`, keep the y/N prompt, capture `cmd_done`'s output and show it in `tmux display-popup` (fallback `display-message`) on a non-zero exit (KTD7).
- **Patterns to follow:** `cmd_done`'s current bursts and `done_note`; `wb_task_lock_acquire_guarded`; `_wb_git_dirty_guard` for stop-message style.
- **Test scenarios:**
  - Default `wb done` on a clean worktree never calls `wb_open_buffer` (the stub fails the test if invoked). The worktree is removed, status is done, `closed` is stamped, the handoff record is written with today's `done_note` wording and `claude_sessions` is blank.
  - The undecided-drafts check still exits before any change, for both live and store-only closes.
  - `.claude-queue.md` lands in the dossier, and the handoff record has `kept: .claude-queue.md` (rewrite of wb-queue §7).
  - `node_modules/` and `app.log` are removed, and the handoff record has one `discarded:` line naming them.
  - An unknown `scratch/notes.txt` gives exit 1. The worktree still exists, status is unchanged, no dossier file is created, the task file and dossier are byte-identical to before, and the message names the file and the flags. (Covers AE6.)
  - A re-run with `--keep scratch/notes.txt` succeeds, with the file in the dossier and a `kept:` line. (Covers AE6.)
  - A keep copy forced to fail (read-only dossier directory) exits 1 with the worktree present, status unchanged and the task file byte-identical.
  - An edited bootstrap `config.hjson` stops the run, and an identical one is discarded. (Covers AE5.)
  - `--review` calls `wb_open_buffer` exactly once, the task lock can be acquired while it is open, and an edit made in the buffer survives the final burst.
  - `--review` on a store-only close opens the buffer, and the task is marked done.
  - A dirty worktree fails before classification, as today.
  - A retry after the worktree is already gone skips the sweep and still flips status.
  - `--close` is still the only `kill-session` in `cmd_done` (wb-schema source guard).
  - ctrl-x on a worktree with an unknown entry, after answering y, leaves the session alive and shows the stop text via the popup path (stubbed tmux).
- **Verification:** the touched test files pass in the Docker sandbox. The full suite shows no new failures against a clean-room baseline of development. `wb help` lists the new flags.

### U3. Retire the `wb-done` skill; close-out runs `wb done` directly

- **Goal:** remove the background+relay skill, and make close-out call `wb done` synchronously, carry the `--close` hazard and the batch rules itself.
- **Requirements:** R19; KTD8.
- **Dependencies:** U2.
- **Files:**
  - `claude/.claude/skills/wb-done/` (delete)
  - `claude/.claude/skills/close-out/SKILL.md`
  - `claude/.claude/skills/decision-buffer/references/mechanism.md` and `decision-buffer/scripts/open-buffer.sh` (caller lists)
  - `scripts/.config/scripts/tmux/tests/parked-items-retirement.test.sh` (drop the wb-done live-file entry)
  - `docs/wb-guide.md` (done section, a "winding down other sessions" paragraph, Known rough edges, the sweep list next to the bootstrap section)
  - `docs/guides/wb-decide.md`, `docs/where-we-are.md`, `docs/docgen.json`, `docs/guide-format.md` (if its example is a live mapping), `docs/roadmap.md` (a changelog line)
- **Approach:**
  1. Rewrite close-out's description, scope bullets, step 5 and step 6, leaving step 4 (shelf review, `_No decisions:` marker, propagation, concepts promotion) untouched. Run `wb done` in the foreground, relay stdout/stderr verbatim, and on a stop (unknown entries or undecided drafts) relay the message and end the turn with no retry and no flags added. Inline the `--close` self-kill warning, including the unsaved-buffer-in-another-window hazard.
  2. Move the batch rules for other sessions into close-out and the wb guide (KTD8).
  3. Delete the wb-done skill and update every live reference. Leave historical plans, archive, ideation, and decision-page's illustrative `wb-done` label and its test untouched.
  4. Regenerate docs with docgen. Commit `docs/*.md` edits in their own commit.
  5. After merge, re-stow `claude` and confirm `~/.claude/skills/wb-done` no longer exists. Update the memory note on the `wb done` buffer stall to say it applies only to `wb done --review`.
- **Test scenarios:**
  - `parked-items-retirement.test.sh` passes without the wb-done entry.
  - A repo-wide search for `wb-done` outside `docs/plans`, `docs/archive`, `docs/ideation`, generated files and the decision-page fixture finds nothing.
  - docgen regenerates without diffs on a second run.
  - Skill walkthrough: close-out on a task whose worktree holds an unknown file relays the stop message and does not re-run `wb done`.
  - Skill walkthrough: close-out with undecided drafts relays the refusal and does not add `--leave-shelved`.
  - Skill walkthrough: winding down two other sessions runs one `wb done --close <session>` each, by session name.
- **Verification:** tests pass; `wb help` and `/help wb done` describe the new behaviour; after re-stow, `ls ~/.claude/skills/wb-done` fails. Live checks (close-out relays a stop) go in this task's `checks.md` with `live_since` set at re-stow.

### Stage 3 · Go reader

### U6. wb-store: repo, reader core, `list` and `show`

- **Goal:** a buildable wb-store repo whose reader parses the dossier layout, with `list` and `show` in text and `--json`.
- **Requirements:** R3 (read side), R4, R5, R8, R17, R30; KTD11–KTD14.
- **Dependencies:** U14 (the store has switched). Runs beside stage 5.
- **Files** (target repo `wb-store`, created at `~/code/wb-store` with a personal GitHub remote; confirm with Jet before creating the remote):
  - `go.mod`, `README.md`, `cmd/wb-store/main.go`
  - `internal/store/discover.go`, `frontmatter.go`, `taskfile.go`, `records.go`, `pages.go`, `task.go`, `resolve.go`
  - `internal/render/text.go`, `json.go`
  - `internal/store/*_test.go`, `internal/render/*_test.go`, `cmd/wb-store/cli_test.go`
  - `internal/store/testdata/store/` (made-up task files and dossiers shaped like the real ones), `internal/store/testdata/golden/`
- **Approach:**
  1. Scaffold following replay-tui's layout. README states the "made-up test data only" rule.
  2. `store.Load(dir)` reads every task file and its dossier records once and returns tasks plus warnings. Parsing functions are pure, so table tests need no disk.
  3. Implement KTD12, the KTD14 resolution order, and the KTD13 schema for the fields this unit owns (frontmatter including `pr:` and `layout:`, title, `## Now`, latest handoff, decisions, open items, page frontmatter, mtime).
  4. Golden tests use an `-update` flag.
- **Execution note:** recover the fence rules from `git show 76f31d4^:scripts/.config/scripts/tmux/wb.sh` (search `_wb_lint_sections_records`, deleted with the nine retired features) and copy them into `taskfile.go`'s doc comment.
- **Patterns to follow:** `~/code/docgen/frontmatter.go` and its tests; replay-tui's cobra root and `testdata/` use.
- **Test scenarios:**
  - Frontmatter is recognised only when line 1 is `---`; a file whose frontmatter doesn't parse is reported by path, skipped by `list`, and an error for `show`.
  - `tags: [a, b]` gives a two-item array; empty `jira:` gives JSON `null`; absent `tags:` gives `[]`.
  - Discovery skips `README.md`, `TEMPLATE.md`, `AGENTS.md`, a `CLAUDE.md` symlink, `*.md.buffer-state`, directories and an illegal stem like `foo bar--x.md`.
  - Resolution: an exact stem beats a substring; a unique substring resolves; an ambiguous substring lists candidates and exits 2; `<stem>.md` and a literal path both resolve.
  - A `## Now` heading inside a fenced block (backtick and tilde) is not a heading.
  - Decisions come from `decisions/` files, in time order, with `status` and both link lists; a generated `decisions.md` that disagrees with the files is ignored.
  - Open items come from `open-items/`, with `who`, `since` and `kind`.
  - A page with an HTML-comment frontmatter block is read the same as a Markdown one.
  - `show` text and `--json` match the goldens. Every list in the JSON is an array, never null, and `schema_version` is 1.
  - `list` over a generated 500-task store finishes under 200 ms (logged, generous budget).
- **Verification:** `go test ./...`, `go vet ./...` and `gofmt -l` are clean. `wb-store show dotfiles--wb-future-direction` against the real store prints its decisions, open items and pages, and `wb-store list` reports no parse warnings.

### U7. wb-store: family, dependencies, ladder, artifacts, replies, session hints

- **Goal:** the model the page needs for R9–R13 and R15, exposed through `family` and an enriched `show`.
- **Requirements:** R9–R13, R15, R16 (reader side), R17; KTD13, KTD26, KTD27.
- **Dependencies:** U6.
- **Files** (target repo `wb-store`):
  - `internal/store/family.go`, `ladder.go`, `replies.go`, `session.go` and matching `*_test.go`
  - `internal/render/` (family, text and JSON)
  - `cmd/wb-store/main.go` (the `family` command)
  - testdata: a made-up parent with five children across two rungs, a `ladder.md`, a supersede pair shaped like AE1, made-up reply logs, and synthetic cycle, dangling, phantom-parent, self-parent and 21-level chain files
- **Approach:**
  1. **Family:** KTD26. Phantom parents are allowed as roots.
  2. **Deps:** comma-separated bare stems with duplicates dropped; state is met, unmet, dangling (with a warning) or cycle; cycle members are never counted as unmet; `unblocks` comes from reverse edges.
  3. **Planning summary (R15):** each child is `startable`, `blocked` or `missing`. Missing means no `brief.md` and no `spec.md`, no size, or no deps declared on a planned task.
  4. **Ladder:** read rung labels and hand-written fields from the parent's `ladder.md`; status per rung from its children's `rung:` and status; decisions due from `review_at:`.
  5. **Artifacts:** dossier pages from their frontmatter (retired when `retire_when` is met); other dossier files classified by kind (`checks`, `verdicts`, `concepts`, `notes`, `brief`); PRs from `pr:` first, then PR URLs found in records.
  6. **Replies and session:** KTD27. The expected tmux name is `repo--sanitize(worktree minus .worktrees/)`, or the stem slug when `worktree:` is blank; labelled "expected", not live.
- **Test scenarios:**
  - The made-up family: root and all children found; a child depending on an unfinished sibling is unmet and listed under `blocked`.
  - Synthetic a→b→a cycle: both flagged `cycle`, neither counts as unmet.
  - A dangling dep produces a warning, and the task is not blocked.
  - Phantom parent: the child's root is the phantom stem. Self-parent is dropped.
  - A 21-level chain stops at 20 with a warning, and `wb-store family` lists the same stems in the same order as `wb family` on the fixture store.
  - Covers AE1: the supersede pair shows `superseded_by` on the old decision and `supersedes` on the new one.
  - Ladder: rung 1 with all children done is `done`; rung 2 with one child doing is `doing`; a decision with `review_at: rung-2` is listed under rung 2.
  - A page whose `retire_when` names a merged PR in `links:` is retired.
  - Replies: the last three turns of the matching reply log are returned; a log for another task is ignored; the resume id is the log with the newest activity.
  - `family` text and `--json` match the goldens.
- **Verification:** the tests are clean. On the real store, `wb-store family dotfiles--wb-future-direction --json` lists the same children as `wb family`.

### U9. dotfiles: `wb-store.sh` shim (stage 3) and `wb page` (stage 4)

- **Goal:** wb-store is one command away from any wb session, and builds itself when stale.
- **Requirements:** R23, R8; KTD11.
- **Dependencies:** U6 for the shim (ships with stage 3); U8 for `wb page` (ships with stage 4).
- **Files:**
  - `scripts/.config/scripts/wb-store.sh` (new)
  - `scripts/.config/scripts/tmux/wb.sh` (the `page` verb: dispatch, usage line, `cmd_page`)
  - `scripts/.config/scripts/tmux/tests/wb-page.test.sh` (new)
  - `docs/wb-guide.md` (a `wb page` row, and a wb-store section with the source repo, shim and port)
- **Approach:**
  1. **Shim:** follow `docgen.sh`, using `WB_STORE_SRC` (default `~/code/wb-store`) and the binary `~/.local/bin/wb-store`. Rebuild when the binary is missing or any `*.go`, `go.mod`, `go.sum` or template is newer, using a recursive find that prunes `.git` and `.worktrees`. Build to a temp file and `mv -f`, then exec with `--store "$TASKS_DIR"`. Use no `stat -c` or `date -d`.
  2. **`wb page [<task>]`:**
     - with no argument, it resolves the current session's task via `wb_session_task_file` (the `@task` session option, never `show -p`);
     - it reuses a running same-build server (the `/healthz` probe in KTD15) and opens `/family/<stem>` on it when the task has children, `/task/<stem>` otherwise; otherwise it starts `wb-store.sh serve <stem>` detached, logging to wb's state directory;
     - outside tmux with no argument, it errors with usage;
     - the shim is found through `wb.sh`'s resolved directory, so a missing re-stow gives a clear "run stow" message.
  3. Re-stow `scripts` once after each merge.
- **Patterns to follow:** `cmd_task_file` (session resolution and failure wording).
- **Test scenarios:**
  - `wb page` inside a session whose `@task` points at a child task resolves to the child's stem (stub the shim and capture its args).
  - `wb page dotfiles--foo` passes the stem through.
  - `wb page` on a task with children opens its `/family/` URL; on a leaf task, its `/task/` URL.
  - With a stub `/healthz` answering the current build id on 8766, `wb page` opens the URL on it and starts no new server; with a different build id answering, it starts a new one.
  - `wb page` outside tmux with no argument prints usage and exits 1.
  - A missing shim prints the stow hint and exits 1.
  - The shim against a stub source dir rebuilds when a `.go` file is newer than the binary, skips the rebuild otherwise, and ignores newer files under `.worktrees/`.
- **Verification:** the tests pass. `wb help` lists `page`. In a real session, `wb page` opens the current task's page.

### Stage 4 · Task page

### U8. wb-store: page server and the prototype-week gate

- **Goal:** a local page server for one task or one family, iterated on layout only, ending in Jet's yes/no.
- **Requirements:** R4, R9–R13, R15, R17; KTD15.
- **Dependencies:** U7; the walk-through task's ranked pain list (it decides what the page shows first).
- **Files** (target repo `wb-store`):
  - `internal/web/server.go`, `open.go`, `templates/layout.html`, `task.html`, `family.html`
  - `internal/web/*_test.go`
  - `cmd/wb-store/main.go` (the `serve` command)
- **Approach:**
  1. **Server:** `serve [--port N] [--no-open] <task>` binds, opens the browser at the task page, and runs in the foreground until interrupted (KTD15). Each handler calls `store.Load` afresh.
  2. **Routes:** `/task/<stem>` and `/family/<stem>` link to each other; every task page has a breadcrumb of its ancestors up to the root, and each child row on a family page links to that child's task page; `/dossier/<stem>/<path>` after the containment check; `/healthz` reports the build id.
  3. **Layout:**
     - central content at about 80–85% of viewport width, with an always-visible section nav; the document scrolls as a whole, the nav kept visible with `position: sticky` (no inner scroll box);
     - light and dark modes; inline CSS, no external assets;
     - record text (decisions, handoffs, open items, `## Now`, reply heads) is escaped by `html/template`, or rendered by goldmark without raw HTML (unlike docgen, whose `page.go` uses `html.WithUnsafe()`), because agent-written text can carry markup copied from tickets or web pages;
     - every section shows a one-line empty message instead of hiding; store warnings appear in a banner naming each path; a task whose file won't parse shows its parse error instead of a 404;
     - a header with a status pill, size, `## Now` and the current rung;
     - a session card with copyable `tmux switch-client -t =<name>` and `claude --resume <id>` commands, and the last few replies;
     - decisions in force, with superseded pairs shown together and the rest behind one link;
     - open items, then pages grouped by tag (retired behind one link), the latest handoff;
     - on the family page, the ladder's generated status, a child table with state chips and dependency edges, and the Planned / Missing / Blocked / Startable box.
  4. **Iteration:** during the week only the templates and CSS change. Data-model changes go back to U7.
  5. **Gate:** Jet's yes or no, recorded as a decision. Two `judge` checks in this task's `checks.md` (format: `claude/.claude/skills/verify-behaviour/references/checks-format.md`): "is the page's picture of a task useful" and "does the live strip still need building", with `evidence: Jet`.
- **Execution note:** use the `visual-explore` skill for layout rounds if Jet wants side-by-side variants.
- **Patterns to follow:** `review-page.py` (loopback bind, fall-forward, browser-open order, quiet logging); replay-tui `config/embed.go`.
- **Test scenarios** (`httptest`):
  - `GET /task/<stem>` returns 200 and contains the title, `## Now`, a decision, a page link, a recent reply and the expected tmux command.
  - Adding a decision file on disk between two requests changes the second response (current on refresh).
  - `GET /family/<root>` lists every child with its state and the ladder's rung statuses.
  - Unknown stem returns 404; a task whose frontmatter doesn't parse returns a page showing the parse error.
  - A decision body holding `<script>alert(1)</script>` and `<img src=x onerror=…>` appears escaped in `GET /task/<stem>`.
  - A task with no replies, decisions or open items shows each section's empty message.
  - A family page's child rows link to each child's task page, and a child's task page has a breadcrumb back to the root.
  - `/dossier/<stem>/../../etc/passwd` and an absolute-path variant return 404.
  - A dossier symlink pointing outside the dossier root returns 404, and a `<stem>` segment that isn't a plain task stem returns 404.
  - A request with `Host: evil.example` is rejected.
  - `/healthz` returns the build id, and the page footer shows the same id.
  - Port fall-forward: with 8766 occupied, the server binds 8767 and prints that URL.
- **Verification:** tests are clean. Jet opens their real task and family pages during the week; the yes/no is recorded in Decisions. On no, stop per AE4.

### Retired units

- **U4. Task-file conventions** (`## Artifacts` in TEMPLATE, README and the guide; the ghost-row fix). Replaced by U10–U12. The ghost-row fix (`wb_task_files` accepting only `<repo>--<slug>.md` stems, so `AGENTS.md` and `CLAUDE.md` stop showing as tasks) moves into U12's `wb.sh` changes, with its test.
- **U5. Writers** (wb-save `## Artifacts` lines, the AE1 prose entry, the decision-page note). Replaced by U12 (wb-save, decision-page) and U14 (the AE1 supersede pair).

---

## Verification Contract

| Scope | Gate |
|---|---|
| wb bash (U1, U2, U9, U10–U12, U14's deletion PR) | Build the sandbox image from `scripts/.config/scripts/tmux/tests/Dockerfile` and run each touched `*.test.sh` in it; never run wb tests against the real `~/code`. The full suite has an environment-dependent known-failure floor, so compare per-file failure sets against a clean-room run of `development` rather than a static list. Clean-room copies and mounts go under `~/.cleanroom/<task>-<purpose>/` (snap Docker can't mount `/tmp`, and the risky-command guard lets that path through). |
| Shell hygiene | `bash -n` and `shellcheck` report nothing new in touched scripts; awk is POSIX (the sandbox runs gawk and mawk). |
| Migration (U11, U13, U14) | Counts per task before and after; the rehearsal runs on a full copy only; the switch is one commit after a baseline commit. |
| tmux config | One new bind (the `notes.md` key, U12). |
| Docs (U3, U12, U9) | Edit `docs/*.md` only, rerun `scripts/.config/scripts/docgen.sh`, confirm a second run is a no-op, and commit doc edits separately (the pre-commit hook stages pending docs edits). |
| Skills (U3, U12) | Walk each new or changed scenario by hand in a scratch task, and record the result in the PR body. |
| wb-store (U6–U8) | `go test ./...`, `go vet ./...`, `gofmt -l .` (empty). Goldens are updated only via `-update`, with the diff reviewed. |
| Real-store spot checks | Read-only: `wb-store show` / `family` against `~/code/tasks`, and `git -C ~/code/tasks status` unchanged by them. |
| Live checks | Behaviour that can only be seen live goes in `dossiers/dotfiles--wb-future-direction/checks.md`, with `live_since` set when the main checkout is re-stowed after a merge. |
| Stow | After each dotfiles merge, fast-forward the main checkout and re-stow the touched packages (ask first). |

## Definition of Done

- **Global:**
  - every unit's test scenarios exist and pass under its gate;
  - no new shellcheck findings;
  - docgen is idempotent;
  - dotfiles PRs target `development` via `pgh`, each with a short test guide;
  - abandoned-attempt code and debug output are removed from every diff;
  - each stage's outcome is recorded in this task's Decisions or handoff log.
- **Stage 2 (U10–U14):** every task in the store uses the layout; no task file has a `## Decisions` section; the old paths and the `layout:` switch are gone from `wb.sh` and the skills; the two pilot reviews are recorded.
- **Stage 5 (U1–U3):** an agent can run `wb done` in the foreground and get either a close or a stop message in the same turn. The `wb-done` skill is gone from the repo and from `~/.claude/skills/`.
- **Stage 3 (U6, U7, U9 shim):** the reader passes its goldens on fixtures, and answers `show`/`family` on the real store with no crash and no warnings beyond known-dangling deps.
- **Stage 4 (U8, U9 `wb page`):** Jet's yes/no is recorded in this task's Decisions. A no applies AE4, and U9's `wb page` is not built. A yes leads to phase 2 planning, and `wb page` opens the current session's task page from any wb session.
