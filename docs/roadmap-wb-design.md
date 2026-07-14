---
title: wb design — the picker, wb done, and the task record schema
status: current
tile: Why wb works the way it does — sort logic, safe wind-down, decision history.
group: roadmap
kind: guide
updated: 2026-07-08
---

The design rationale behind `wb` and the task-record schema it's built on —
distinct from [`wb-guide.md`](wb-guide.html), which is the usage-focused
"how do I run it" doc. This page is the "why it works this way" companion:
sort order, safe-wind-down ordering, and the review decisions that shaped
both. This page is the source; edit `docs/roadmap-wb-design.md`, not the
rendered `.html`.

**Roadmap:** §2/§3 (superseded — this page is the detail, `docs/roadmap.md`
carries only the status row) · **Built:** PR #7, 2026-07-06 · **Usage
guide:** [`wb-guide.md`](wb-guide.html)

## The picker's row source and sort order

One row per **task** from the central store — status from frontmatter, so
planned and done tasks are visible, not just live ones — with live
session/agent state overlaid as glyphs. Repo-level checkouts (main
checkouts, no task) appear as extra rows. Worktrees are enumerated via
per-repo `git worktree list` (authoritative), never directory globbing.

Grouping is **status-first, not repo-first** (changed 2026-07-06, post-
launch): all needs-you rows surface together across every repo, then
finished, then working, then idle — so urgency is never buried inside a
repo's alphabetical group. A session's sub-rows still ride along with their
parent as one block rather than scattering by their own individual rank
(see `wb.sh`'s `collect_combined_rows`).

Column 3 shows frontmatter status (`planned`/`doing`/`review`/`done`) for
task rows, or the current branch in `[brackets]` for repo-level rows.
Sessions with more than one Claude pane expand into one indented sub-row
per agent. Each row/sub-row carries a hidden field — its most-urgent Claude
pane target — so `x` (interrupt) and the agent-pane preview always act on
the right target, never just "the session's active pane."

`ctrl-x` on a worktree-backed task row routes through the full `wb done`
flow (a raw kill only happens for non-task sessions) — wind-down is the
default exit, not an optional ritual you have to remember.

> **Enter's preview fallback chain (Decision 11, 2026-07-07 review):**
> urgent agent pane, else `git status`, else — for session-less,
> worktree-less task rows (planned tasks with no live session and no
> worktree yet) — the task file's `## Plan` section rendered as text. Added
> because a planned-but-not-started task previously had nothing useful to
> preview at all.

## `wb done` — the safe wind-down

1. **Fail fast**: `git status --porcelain` in the worktree; if dirty, print
   the short status and abort — nothing mutated.
2. Open the task file + session notes in a review buffer (decision-buffer
   pattern); keepers are marked `- [x] keep` — the one convention shared
   with the notes-digest promotion (slice 4b).
3. On close: sweep worktree-local gitignored keepers into the central store
   (`logs/decisions/*.md` at minimum — verified: `git worktree remove`
   silently destroys gitignored files, and the dirty check never protects
   them) and rewrite the task file's Decisions links to the store copies.
4. Status → `done`, keepers captured.
5. Kill the session, then `git worktree remove`.

> **Bypass guard (Decision 8, 2026-07-07 review):** nothing catches a
> worktree torn down via raw `git worktree remove`/`tmux kill-session`
> instead of `wb done` — the task file is left stale with no signal. Add a
> lightweight periodic check: any task-store entry whose `worktree:` path
> no longer exists in `git worktree list` AND whose `status:` isn't `done`
> gets flagged as a picker-row warning (not a hard block), so a skipped
> `wb done` is caught rather than silently lost. *(Not yet built.)*

> **Credential guard (2026-07-06 review):** `wb new` bootstraps `.env*`
> into worktrees by default, and the keeper sweep copies gitignored files
> into the central store — a repo intended for cross-machine git sync. The
> sweep carries an exclusion list for credential-shaped files (`.env*`,
> `*.pem`, `*.key`, `*credential*`, …) and warns in the review buffer when a
> marked keeper matches one, so a bootstrapped secret can't ride a
> `- [x] keep` into a repo that later gets a remote. **Known limitation**
> (§11 Open Questions): this is a dismissible warning, not an enforced
> block, and doesn't scan file *contents* — only filenames.

## Why bash, not Go or Python

`wb` is tmux/fzf orchestration — bash is the native tongue there, `lib.sh`
already had the helpers, no build step, and it stows like everything else.
A compiled implementation would only earn its keep if the task *index*
grows real querying/aggregation needs — that's notes-tui/cli-kit territory,
not a reason to start `wb` itself in Go.

## The task record schema

```markdown
---
status: doing        # planned | doing | review | done
repo: dotfiles        # worktree resolves as ~/code/<repo>/<worktree>
branch: feat/agent-task-workflow
worktree: .worktrees/feat/agent-task-workflow
tags: []              # free tags for cross-project grouping
created: 2026-07-06
---
# Agent task workflow
## Plan          ← batches of intended work
## Done          ← running log of what landed
## Follow-ups    ← per-task backlog; /parked-items review reads these
## Decisions     ← links to logs/decisions/*.md + key calls inline
```

Three goals map onto this schema directly: **backlog** = `## Follow-ups`
(+ global `/park` for cross-task strays); **progress tracker** = `status:`
rendered as the picker's status column — the board is *inside* `wb`, not a
separate surface; **review & refinement** = `wb done`'s close-out buffer
plus a push trigger (the picker's status line carries the pending
Follow-ups + parked count, and `wb done` offers a cross-task sweep past a
threshold — the weekly `/parked-items` ritual stays available but isn't
the load-bearing path anymore).

> **Validation clock:** this demotion is a behavioral bet on event-driven
> pushes whose events are sparse (the nudge fires only at task completion;
> the count only renders when the picker is open). Check-in **~2026-07-20**
> — inspect the parked ledger's open-item ages. If the oldest open item
> exceeds ~10 days, the bet failed: restore the weekly ritual as
> load-bearing, or surface the count somewhere time-driven (e.g. tmux
> `status-left`) instead of only inside the picker.
