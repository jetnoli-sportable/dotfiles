---
title: Roadmap — the personal workflow
status: current
tile: One table, one status column, one click to the detail behind each row.
group: personal-workflow
kind: guide
updated: 2026-07-08
---

The roadmap for the whole personal workflow (tmux/Claude tooling, the
central task store, notes-tui, the docs project) — several pieces already
live in separate repos (`~/code/notes-tui`, `~/code/tasks`).

> **Restructured 2026-07-08.** This used to be one 832-line document with
> everything at the same flat depth. Every item below now gets its own
> page — click through for the design rationale, the full runbook, or
> whatever detail used to live inline here. This page stays short on
> purpose.

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

## Overview

| Item | Status | Doc | What it is |
|---|---|---|---|
| Step zero (hooks, alias cleanup) | Done | — | Attention-pipeline hooks wired, dead `n` alias removed |
| Central task store + frontmatter | Done | [wb design](roadmap-wb-design.html) | `~/code/tasks`, file-per-task schema |
| `wb` core (new / picker / done) | Done | [wb design](roadmap-wb-design.html) · [wb-guide](wb-guide.html) | Session-per-worktree + unified picker — PR #7 |
| Notes-tui integration (4a / 4b) | 4a done · 4b gated ~2026-07-14 | [deep dive](slice-4b-deep-dive.html) | Capture habit shipped; real wiring waits on the usage-window verdict |
| Docs platform (generated pages, Hub, INDEX, `/help`) | Done | [docgen](docgen.html) · [slice-5 recap](slice-5-recap.html) | One generator, three outputs — slice 5 |
| Per-skill/TUI guide pages + tile dashboard | Done | `docs/guides/*` · [slice-5 recap](slice-5-recap.html) | Born-generated guides, `HUB.html` |
| `/board` — full HTML task-board view | Open (interim shipped) | [detail](roadmap-board.html) | Zoomable today/task/week; `wb board` covers the visibility gap now |
| Day bookends (`wb up` / `wb down`) | Open, gated on 4b | [detail](roadmap-day-bookends.html) | Startup/shutdown flows |
| Task recall | Open, unblocked | [detail](roadmap-task-recall.html) | Resume any work from any session by referencing it |
| Editor/tmux ergonomics batch | Done | [9f recap](9f-ergonomics-recap.html) | 6 small nvim/tmux/Claude-Code items |
| GPaste clipboard-history manager | Done | [9g recap](9g-gpaste-recap.html) | Configured, `<Ctrl><Shift>G` opens history |
| Unify copy/paste (terminal paste never needed) | Open, not started | [9g recap](9g-gpaste-recap.html) | Needs its own design pass |
| Cross-repo/cross-machine doc registry | Proposal, unratified | — | Only revisit if artifacts still go missing after the landing-path rule |
| Jira integration (`/board` + day-bookends halves) | Proposal, not scheduled | — | Same open questions both times: credential location, persistence into the sync-bound store |
| Personal/employer boundary rule | Deferred — **final** item | [open questions](roadmap-open-questions.html) | Made only after every other follow-up is in place |
| `docgen.sh`'s pre-commit hook targets the wrong repo from a worktree | Done | — | Fixed by exporting `DOTFILES="$repo_root"` in the hook, using the root it already correctly computed via `git rev-parse --show-toplevel`. Verified with a real divergence test: a marker page committed from a throwaway worktree landed in that worktree's `HUB.html` only, main checkout untouched |

**Dated clocks** (not tasks — check-in points): delete the version-pinned
content scan `tmux_pane_awaiting_input` (~2026-07-13, if hook data held) ·
4a capture-window verdict, gates 4b's shape (~2026-07-14) · push-vs-weekly-
ritual validation check-in (~2026-07-20).

Full detail on every deferred decision the 2026-07-07 doc review left open:
[Open Questions](roadmap-open-questions.html).

## Keep / retire / hold

- **Retire:** `cad` dashboard (unused, `wb` absorbs it), dead `n` alias.
- **Hold:** nvim bridge fancy features (`:ClaudePick`, yank-code, `gf`) —
  stay installed, no further investment until the basic loop + workbench
  are further along.
- **Keep as-is:** decision-buffer, `/park` + `/parked-items`,
  `pr-review-session`, the worktree flow (its ritual is absorbed by
  `wb new`, not replaced).
