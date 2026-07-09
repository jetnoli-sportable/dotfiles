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
> everything at the same flat depth. Most active or notable items below
> get their own page — click through for the design rationale, the full
> runbook, or whatever detail used to live inline here. Small completed
> items and unratified proposals are noted inline instead (`—` in the Doc
> column) rather than given a page each. This page stays short on purpose.

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
| Notes-tui integration, 4a (capture) | Done | [deep dive](slice-4b-deep-dive.html) | Capture habit shipped; 4b (real wiring) tracked separately below |
| Docs platform (generated pages, Hub, INDEX, `/help`) | Done | [docgen](docgen.html) · [slice-5 recap](slice-5-recap.html) | One generator, three outputs — slice 5 |
| Per-skill/TUI guide pages + tile dashboard | Done | `docs/guides/*` · [slice-5 recap](slice-5-recap.html) | Born-generated guides, `HUB.html` |
| `/board` — full HTML task-board view | Done — PR #14 | [PR #1 recap](pr1-wb-workbench-recap.html) · [detail](roadmap-board.html) | `wb board --html`: 6 status tabs × timeline window, live-session badges, untracked-worktree rows |
| `wb pause` (new status + subcommand + keybind) | Done — PR #14 | [PR #1 recap](pr1-wb-workbench-recap.html) · [detail](roadmap-board.html) | Also stopped `wb done` from killing the tmux session — same instruction, both wind-down paths |
| `wb reconcile` — task-store/git drift detection | Detection + review/apply flow done — PR #14; combining two already-tracked duplicate tasks is a real, separate gap, still open | [PR #1 recap](pr1-wb-workbench-recap.html) · [detail](roadmap-wb-reconcile.html) | `wb reconcile` / `--review` / `--apply` ship drift detection (orphaned worktree, missing worktree) with a six-action review doc; **not yet covered:** two tasks that both have valid worktrees but represent the same real work — reconcile has no way to see that as a finding at all today |
| Day bookends (`wb up` / `wb down`) | `wb resume <task>` shipped (PR #14); full up/down gated on 4b | [detail](roadmap-day-bookends.html) | Startup/shutdown flows; single-task resume ships first |
| Task recall | Open, **actually blocked** on the personal/employer boundary rule below, despite reading as unblocked | [detail](roadmap-task-recall.html) | Resume any work from any session by referencing it — see Open Questions for the boundary dependency |
| `/handoff` — route a discussion to the right worker | Queued, marked for pickup soon | [detail](roadmap-handoff.html) | Switch to an existing agent's session or `wb new` it; surfaced a real gap (no sub-task relationship exists yet) |
| Notes-tui integration, 4b (real wiring) | Sequenced after `/handoff`, pending 4a's ~2026-07-14 verdict | [deep dive](slice-4b-deep-dive.html) | Placement decided 2026-07-08 — may move if the Hub v0 roadmap-visual work finds something more relevant |
| Hub v0 (meta-documentation bundle) | Scoped (parked); next up once the `wb reconcile` duplicate-task gap above is resolved | — | Artifact index, limitations list, glossary, roadmap visual, a ceremonies/rituals section (tracking exactly the dated clocks and process rituals below), plus the docgen-freshness hygiene fixes |
| Editor/tmux ergonomics batch | Done | [9f recap](9f-ergonomics-recap.html) | 6 small nvim/tmux/Claude-Code items |
| GPaste clipboard-history manager | Done | [9g recap](9g-gpaste-recap.html) | Configured, `<Ctrl><Shift>G` opens history |
| Unify copy/paste (terminal paste never needed) | Open, not started | [9g recap](9g-gpaste-recap.html) | Needs its own design pass |
| Cross-repo/cross-machine doc registry | Proposal, unratified | — | Only revisit if artifacts still go missing after the landing-path rule |
| Jira integration (`/board` + day-bookends halves) | Proposal, not scheduled | — | Same open questions both times: credential location, persistence into the sync-bound store |
| Personal/employer boundary rule | Deferred — **final** item | [open questions](roadmap-open-questions.html) | Made only after every other follow-up is in place — Task recall above already depends on it landing |
| Task-store schema migration/reconciliation | Proposal, tied to Hub v0 launch | — | One-time pass to bring every existing task file up to whatever schema `/board` + `wb reconcile` finalize (`closed:`, `paused`, etc. are being added piecemeal this session); do the migration once the schema settles rather than per-field |
| Skill/tool/command usage audit | Proposal, unscheduled | — | Monthly-ish audit of what's unused (prune candidates) AND what's underused but already solves a current pain point (before building something new) — measurement source and output location still undecided |
| `docgen.sh`'s pre-commit hook targets the wrong repo from a worktree | Done | — | Fixed by exporting `DOTFILES="$repo_root"` in the hook, using the root it already correctly computed via `git rev-parse --show-toplevel`. Verified with a real divergence test: a marker page committed from a throwaway worktree landed in that worktree's `HUB.html` only, main checkout untouched |

**Dated clocks** (not tasks — check-in points, i.e. "on this date, come back and
make a call," not "on this date, code runs automatically"). What's actually
expected to happen at each:

- **~2026-07-13 — delete `tmux_pane_awaiting_input`** (if hook data held).
  This is a version-pinned content-scan fallback for detecting "is this
  tmux pane waiting on input" — a stopgap until the newer hook-based
  attention pipeline (Step zero, above) proved reliable. The action: if the
  hook-based detection has held up without regressions by this date, delete
  the old fallback scan; if it hasn't, keep it a while longer.
- **~2026-07-14 — 4a capture-window verdict.** Look at how notes-tui's
  capture habit (4a, shipped) actually got used over the observation
  window, then decide whether that usage justifies building 4b's real
  wiring, and in what shape. A go/shape decision, not an automatic trigger.
- **~2026-07-20 — push-vs-weekly-ritual validation check-in.** Compare
  whether proactive push notifications or batched weekly review (the
  `/parked-items` model) actually fits real usage better, to inform how
  similar future features get designed.

Full detail on every deferred decision the 2026-07-07 doc review left open:
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
