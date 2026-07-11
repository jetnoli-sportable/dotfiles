---
title: Glossary — recurring workflow terms
status: current
tile: One canonical definition per term that keeps coming up. Jump to any of them.
group: personal-workflow
kind: guide
updated: 2026-07-10
---

Terms that recur across this docs project, the task store, and the tmux/wb
tooling — defined once here instead of re-explained inline every time they
come up. Each term is its own section so the sticky table of contents can
jump straight to it.

## Frontmatter

The YAML block delimited by `---` lines at the top of a markdown source.
Every docs page (`docs/*.md`), task file (`~/code/tasks/*.md`), and plan
(`docs/plans/*.md`) carries one. Tools parse it directly — `docgen` reads a
page's `title`/`status`/`tile`/`group`/`kind` to drive its HUB tile and page
chrome without touching prose; `wb` reads a task file's `status`/`repo`/
`branch`/`worktree`/`parent` fields the same way.

## Transcript

The session log a Claude Code conversation leaves behind. Normally just a
debugging aid, but it doubled as the recovery source after the 2026-07-10
`~/code/tasks` deletion incident — both `tasks--task-note-convergence.md`
and the incident's own recovery notes were rebuilt by mining a transcript
that had read the originals in full.

## Ledger

An append-only log file, one entry per event, never edited in place. `/park`
writes to one: a JSON line per captured item at
`~/.claude/parked-items/ledger.jsonl`, read back in full by the weekly
`/parked-items` review.

## Worktree

A git worktree — an isolated checkout of one branch in its own directory,
so more than one branch can be checked out (and worked on by a separate
agent session) at the same time. `wb new` creates one per task under
`.worktrees/<branch>` and points that task's tmux session at it.

## Task store

The central repo at `~/code/tasks`: one markdown file per task, a shared
frontmatter schema (`status`, `repo`, `branch`, `worktree`, `parent`,
`tags`, `created`, `closed`), and a freeform body underneath. `wb` reads
and writes these files directly; humans can too. See `tasks/README.md` for
the full schema.

## Tile

One clickable card on `HUB.html`, grouped under a `group` heading (e.g.
"Personal workflow"). Most tiles come from a page's own frontmatter
(`title`/`tile`/`status`); a sidecar tile (below) is the exception.

## Sidecar

A HUB tile for something that isn't a generated page and has no
frontmatter of its own to drive one — declared directly as an entry in
`docs/docgen.json`'s `hub.sidecar` array (`docgen/config.go:57-65`) with
its own title, tile text, href, and path.

## INDEX entry

One row in the fenced JSONL block (and the human table below it) inside
`docs/INDEX.md`. Produced by `docgen`'s `index` step scanning a declared
source — tmux binds, zsh aliases, skill descriptions, decision records,
`MEMORY.md`, TUI READMEs, the task store — into a common `Entry` shape,
alongside a `doc` entry for every rendered page.

## Decision buffer

A markdown (and, for larger rounds, companion HTML) doc opened in the
user's nvim buffer for a design discussion instead of a chat menu — one
`- [ ] Choose Option X` block per decision, inline code from the real
codebase, pros/cons, and that decision's own inline recommendation and
Questions/Notes, all self-contained per decision. See the `decision-buffer`
skill.

## Parent/child task relationship

A task's `parent:` frontmatter field, set to the coordinating parent
task's filename stem, when that task is one piece of a larger effort
broken into sub-tasks (e.g. a cross-repo feature with separate frontend
and backend halves). The parent task itself is session-less — it carries
a placeholder `repo:` and is never `wb new`'d into its own worktree, since
it coordinates rather than does work directly. Shipped as dotfiles PR #17;
see `tasks/README.md`'s "Parent/child tasks" section for the full schema.
