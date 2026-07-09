---
title: /handoff — route a discussion to the right worker
status: current
tile: Take what's being discussed and either switch to the agent already on it, or spin up a new task for it.
group: personal-workflow
kind: page
updated: 2026-07-08
---

Queued 2026-07-08, marked for pickup soon. This page is the source; edit
`docs/roadmap-handoff.md`, not the rendered `.html`.

**Roadmap:** new item, not from the original numbered list · **Status:**
queued, not yet scoped in a decision-buffer round

## The ask, verbatim

Take something currently being discussed and either (a) indicate an
existing agent/session who should be the one to work it — ideally
instructing them directly, though that's a follow-up; v1 can just switch
the tmux session and put the text on the clipboard buffer — or (b), the
more common case, just `wb new` it.

## Why v1 is likely cheaper than it first sounds

Both paths look like they can lean entirely on things `wb.sh` already
does, rather than needing new matching logic:

- **Does a task already exist for this?** Already solved — the
  worktree-seeding rule (`~/.claude/CLAUDE.md`) already looks up
  `~/code/tasks/<repo>--<slug>.md` by `repo:` before seeding a new
  worktree. `/handoff` doesn't need its own lookup; it computes the same
  `repo`/`slug` and asks the same question.
- **Is there a *live* session for it right now?** Also cheap: the session
  name is deterministic (`${repo}--${disp_slug}`, `wb.sh:250`), so a plain
  `tmux has-session -t "=$session"` check (the same check `cmd_new` already
  does at `wb.sh:267`) tells you whether to switch-and-clipboard or spin up
  fresh.
- **Spinning up fresh** is exactly `cmd_new`, already idempotent and
  already handling the "task file exists but no session" case.

So the harder part isn't the mechanics — it's deciding *which* repo/slug
the current discussion actually maps to, which (unlike Task Recall's
cross-session trigger problem) `/handoff` gets to solve with the full
context of the conversation it's invoked from, not a bare topic reference
from cold.

## The real open gap this surfaced: no sub-task relationship exists

Raised alongside the `/handoff` ask: "do we have a relationship in place
for sub-tasks? ... being able to take something big and break it down into
a bunch of smaller pieces." Checked the actual schema
(`~/code/tasks/README.md`) — no, nothing today represents "this task is a
piece of that task." The frontmatter is `status / repo / branch / worktree
/ tags / created`; `tags:` is documented as "free tags for cross-project
grouping," not a parent/child relationship. This is a genuine gap, not
just an unbuilt feature — worth its own decision-buffer round (a `parent:`
frontmatter field pointing at another task file? an inline sub-task list
in the parent's `## Plan` section? something tag-based?) rather than
guessing an answer inline here.

## A concrete case to factor in: full-stack tasks (FE + BE)

Noted 2026-07-09, ahead of the decision-buffer round: a parent/child
relationship isn't just "one task broken into smaller pieces of the same
kind" — a common real shape is one piece of work spanning two repos (a
frontend change and its backend counterpart), which stresses the schema
differently than same-repo sub-tasks do:

- **Schema:** `repo:` is a single field per task file today
  (`~/code/tasks/README.md`) — a full-stack task doesn't have one `repo:`,
  it has (at least) two. Whatever parent/child representation gets chosen
  needs to handle "the child tasks disagree on `repo:`" as a normal case,
  not an edge case.
- **tmux/session topology — genuinely open, not yet a preference:**
  - **(a) One session, multiple windows** — a single tmux session for the
    parent task, with an extra nvim window opened in the FE worktree
    alongside the existing BE one (`wb_layout_session`, `wb.sh:210-223`,
    would need a second worktree path, not just a second window in the
    same one).
  - **(b) One session per repo, linked by the parent/child relationship** —
    closer to how `wb.sh` already works today (one worktree = one session),
    just with the picker/board aware that two sessions share a parent.
  - Both need an answer to: does ONE agent manage both worktrees (single
    `claude` pane, working across two directories), or TWO agents (one per
    repo, each scoped to its own worktree) — which is really a question
    about whether an agent should ever operate outside its own worktree's
    cwd, not just a session-layout preference.
- **`/board` and the picker both need a rendering answer, and they're not
  the same question:**
  - The picker already has a working precedent for "one thing with
    sub-rows" — `wb_agent_subrows` (`wb.sh:609-621`) expands a
    multi-agent session into indented sub-rows under one parent row. A
    full-stack task's two sessions (option b above) could plausibly reuse
    that exact rendering, once the sessions know they're linked.
  - `/board` doesn't have an equivalent precedent yet — U4/U5 (this
    session's `/board` build) never needed one, since nothing in that
    scope spans two repos. The parent/sub-task artifact rollup already
    mocked up for `/board` (`logs/decisions/2026-07-08-board-mockup-a-
    table.html`'s speculative section) is the closest existing sketch, but
    it was drawn for "one parent, several same-repo children," not
    specifically for a two-repo pair.

None of this is decided — recording it so the eventual decision-buffer
round scopes the representation against a real multi-repo case, not just
the same-repo "big task into smaller pieces" framing it started from.

## Sequencing

Queued, not yet scoped. When picked up: a decision-buffer round covering
(1) the sub-task relationship representation — including the full-stack
(multi-repo) case above, not just same-repo decomposition — since
`/handoff`'s "break something big into pieces" framing depends on it
existing, and (2) the follow-up (deferred on purpose) of actually
instructing an existing agent rather than just switching to their session.
