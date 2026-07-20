---
title: Recap — the Hub-v0 + agent-fleet push (2026-07-10 → 12)
status: current
tile: Two days, 14 PRs — ideation, an rm -rf incident + full recovery, and a parallel agent fleet. What shipped and where things stand.
group: recaps
kind: page
updated: 2026-07-12
---

The record of a two-day push on the personal workflow. Started as a single
`/ce-ideate` on the Hub v0 roadmap section; became a calibration of the
whole workflow, survived a destructive incident with a full recovery, and
ended with a fleet of parallel agents shipping the backlog. This page is
the source; edit `docs/2026-07-12-workflow-push-recap.md`.

## The arc

1. **Ideation (2026-07-10)** — `/ce-ideate` on "what should the roadmap
   section of Hub v0 contain": 7 verified survivor directions (stage ×
   impediment status grammar, "blocked" as a written waits-on link, the
   commitment queue, the "Not doing" lane, calibration-as-ritual). Doc:
   `docs/ideation/2026-07-10-hub-v0-roadmap-section-ideation.html`.
2. **Calibration round** — a 6-decision decision-buffer
   (`logs/decisions/2026-07-10-workflow-calibration.md`) driven by a
   parallel workflow review: resequenced parent/child ahead of Hub v0,
   trimmed Hub v0 (deferred the artifact index), reshaped the roadmap,
   ratified the **"everything is a note"** north star.
3. **The deletion incident** — a code-review subagent `source`d `wb.sh`,
   whose unconditional `CODE_DIR=$HOME/code` clobbered the script's own
   var, and its cleanup `rm -rf "$CODE_DIR"` wiped `~/code`. Full account:
   `[[2026-07-10-deletion-incident-and-recovery]]` memory.
4. **Recovery** — notes corpus rebuilt from nvim swap/undo artifacts;
   decision records + Hub v0 docs replayed verbatim from session
   transcripts; `~/code/tasks` and `~/code/notes` got their **first-ever
   git remotes** as the lasting fix. Records: `RECOVERY-NOTES-2026-07-10.md`
   in the tasks store.
5. **The parallel fleet (2026-07-11)** — with parent/child merged, a fleet
   of agents spun up via the pseudo-handoff pattern (each dogfooding the
   `/handoff` flow being built), converging to 14 merged PRs.

## What shipped (merged PRs)

| PR | What |
|---|---|
| #13 | pre-commit hook targets the actual worktree, not always main |
| #14 | wb workbench extensions: `wb resume` / `wb pause` / `/board` / `wb reconcile` |
| #15 | nvim: `vim .` no longer silently auto-restores a session |
| #16 | roadmap sync after PR #1 |
| #17 | **task parent/child relationship** (+ the CODE_DIR override-safe fix) |
| #18 | **Hub v0**: glossary, limitations, ceremonies pages, `/board` tile, roadmap reshape |
| #19 | `wb done --close` (opt-in session kill + self-kill guard) |
| #20 | `wb board` lifecycle-stage detection functions (U1–U3) |
| #21 | **`/handoff` v1** — route a discussion to the right worker (now a real skill) |
| #23 | limitations: roadmap anchor/link integrity recorded as manually verified |
| #24 | **`/queue`** — per-worktree queue for stashing follow-ups |
| #25 | tmux `detach-on-destroy off` — land in another session on kill |
| #26 | `wb-save`/`wb-resume`/`wb-done`/`wb-board` skills (context-handoff) |
| #27 | fix: Sweep-review buffer no longer autoformats itself |

Plus one un-PR'd win: `.worktree-bootstrap` seeds `logs/decisions` into
every new worktree (kills the manual copy step). All three stores
(dotfiles, tasks, notes) are pushed.

## Current roadmap state

`docs/roadmap.md` is the reshaped page from #18 — sections: **At a glance**
(an anchor-linked, stage-coloured timeline), **Up next (max 3)**, **Live**,
**Parked** (every entry names a revisit trigger), **Not doing** (86'd
items), **Shipped** (14 items). Statuses use the stage × impediment
grammar with waits-on links (e.g. Task recall · `needs: boundary-rule`).

**Known drift to fix (small):** the reshape was built *while* Hub v0 and
`/handoff` were in flight, so At-a-glance/Live still label **Hub v0 as
"active"** and **`/handoff` as "in build"** — both have since merged
(#18, #21). A one-pass status refresh (Hub v0 → shipped, `/handoff` →
shipped, and move the schema-migration item forward) is owed.

## Hub v0 — done, trimmed as planned

Merged (#18). Live and Hub-tiled: **glossary**, **limitations**,
**ceremonies**. The **artifact index** (U5/U6) was deliberately deferred
(revisit when a one-off doc actually goes un-findable). The roadmap
reshape (U7) shipped. So Hub v0's remaining scope is complete except the
consciously-parked artifact index.

## Still in flight / open

- **#22** (open) — docs note: `~/code/tasks` has no locking across
  concurrent `wb` agents. A live **concurrency-safety lane** is exploring
  the actual fix (ideation: `docs/ideation/2026-07-11-tasks-dir-concurrency-safety-ideation.html`).
- **wb-board-display lane** — the display/render half of the lifecycle
  board (detection shipped in #20).
- **Held, gate now cleared:** `dotfiles--audit-tmux-jump-to` — jump-to gap
  audit; its blockers (`/handoff` #21 + `/queue` #24) are both merged, so
  it's ready to spawn.
- **Task-store schema migration** — the per-file pass across
  `~/code/tasks/*.md` still hasn't run (only #17's two files carry the new
  fields). Top of "Up next."

## Key learnings captured

- **zsh implicit-modifier / tied-array footguns** (`CODE_DIR`, `path=`,
  `$var:agent`→`:a`) — all bite unbraced vars *in zsh*; the shipped bash
  scripts are safe. See the incident memory.
- **Editor state dirs (undo/swap) are a first-class recovery source** when
  git can't help.
- **Roadmap.md is a serialization point** — only one lane touching it at a
  time, rebase-before-PR (a #26 conflict proved this).
- **Pseudo-handoff mechanics** (task-file-as-payload, anchored readiness
  markers scoped to the output region, session-scoped tasks-read allow,
  no `/model` for per-spawn model) — now formalized in the `/handoff` skill.

## What's next (suggested order)

1. Refresh the roadmap's stale statuses (Hub v0 / `/handoff` → shipped).
2. Land #22; decide whether to *implement* task-store locking before
   scaling agent-count further.
3. Run the task-store schema migration.
4. Spawn the held jump-to audit.
5. The parked end-of-day **notes-dir audit** ("everything is a note").
