---
title: wb — the workbench guide
status: current
tile: How to use wb: session-per-worktree, the unified picker, wind-down.
group: personal-workflow
kind: guide
updated: 2026-07-07
---

Replaces the `s` / `ca` split with a single tmux+fzf tool backed by a
central, git-tracked task store at `~/code/tasks`. Verbs: `wb new` ·
`wb` (picker) · `wb done` · bound on `prefix+m` / `prefix+a`.

## What changed, in one paragraph

Every worktree you open now gets a task file in `~/code/tasks`
automatically, a standard three-window session (nvim / agent / shell), and a
spot in one picker alongside every other repo and running Claude agent on
the machine. Closing a task is now a real, guarded action — `wb done` —
instead of a bare `tmux kill-session` that leaves the worktree and an
untracked task behind.

> **Nothing old was removed.** `s` and `ca` still work if you type them by
> name — only the <kbd>prefix</kbd>+<kbd>m</kbd> / <kbd>prefix</kbd>+<kbd>a</kbd>
> bindings were repointed at `wb`.

## Try it in the next five minutes

1. Reload tmux config so the new bindings are live (only needed once, until
   you reattach):

   ```
   tmux source-file ~/.config/tmux/tmux.conf
   ```

2. Press <kbd>prefix</kbd> then <kbd>a</kbd> (or <kbd>m</kbd> — same picker
   now). You'll see whatever's actually live right now — running sessions
   and agents, grouped by status (needs-you first). Press <kbd>Tab</kbd> to
   cycle between *combined* / *sessions* / *agents* views.

3. From inside any repo, spin up a real task:

   ```
   # from inside ~/code/dotfiles
   wb new try-wb-out
   ```

   This creates `.worktrees/try-wb-out`, a branch of the same name, a task
   file at `~/code/tasks/dotfiles--try-wb-out.md`, and drops you into a
   3-window session.

4. Poke around — edit something in the **nvim** window, switch to the
   **agent** window and start `claude` if you want one running.

5. Wind it down properly instead of just killing the pane:

   ```
   wb done
   ```

   (run it from inside the session — no argument needed). It'll check the
   tree is clean, and if there are any gitignored files it would otherwise
   silently destroy, it opens the task file in a split for you to mark
   `- [x] keep` on anything worth saving before it removes the worktree.

## wb new — start a task

```
$ wb new [--agent] <slug>          # from inside a repo
$ wb new [--agent] <repo> <slug>   # from anywhere
```

The slug becomes the git branch name, the worktree path
(`.worktrees/<slug>`), and — sanitized (`/` and `.` → `-`) — the tmux
session name and task filename. A slug like `feat/onboarding` is completely
fine; it becomes session `reponame--feat-onboarding`.

Re-running `wb new` on the same slug is safe — it reuses the existing
worktree, task file, and session instead of duplicating anything. That's
also how you resume a task after the session got closed without going
through `wb done`.

| Window | Name | What's in it |
|---|---|---|
| 1 | `nvim` | Opens automatically, editing the worktree root. |
| 2 | `agent` | A plain shell — *you* type `claude` when you want an agent running here, unless you passed `--agent`. |
| 3 | `shell` | A plain shell for everything else. |

`--agent` is deliberately opt-in: with ~10 Claude sessions being a
reasonable working ceiling on this machine, `wb new` doesn't start one for
you unless you ask.

## The picker

Press <kbd>prefix</kbd>+<kbd>m</kbd> or <kbd>prefix</kbd>+<kbd>a</kbd> (both
open the same picker now). Rows are **presence, not inventory** — only
things that are actually live right now. A never-started `planned` task or
a repo you haven't opened doesn't get a row; resume it with
`wb new <repo> <slug>` directly instead of browsing for it.

> **Changed after first use.** The first version showed a row for every task
> file and every repo under `~/code` whether or not anything was happening —
> on a normal day that's 20+ rows, nearly all gray "no agent" noise. It's
> presence-only now.

### Three modes, one key: Tab

Press <kbd>Tab</kbd> to cycle. The header always shows which mode you're in,
and it stays put across the auto-refresh — cycling to *sessions* and walking
away doesn't snap back to *combined* a few seconds later.

| Mode | Rows | Replaces |
|---|---|---|
| **combined** (default) | One row per live tmux session; sessions with more than one Claude pane expand into indented sub-rows | today's `wb` |
| **sessions** | One row per live tmux session, collapsed — no sub-rows | `s`, now agent-aware |
| **agents** | One row per running Claude pane, globally, ranked by urgency — no session grouping | `ca`, exactly |

Five columns, always: **REPO** (location) · **NAME** (task title or
session/repo name) · **TYPE** (`session` / `agent` / `both`) · **BRANCH**
(the git branch, when there is one) · **STATUS** (the most urgent agent in
that row). A realistic **combined** view — three live sessions, one of them
(`be--monorepo`) running two agents:

```
0              0                          both     [main]       o done
be--monorepo   be--monorepo               both     [dev]        ! needs you
  ↳            state management refactor  agent    [dev]        o done
  ↳            reporting tool issues      agent    [dev]        ! needs you
frontend       frontend                   session  [sfb-985-…]  - no agent
```

Status glyphs: `!` needs you · `+` finished · `o` done · `*` working ·
`-` idle / no agent.

TYPE tells you at a glance whether a row is a bare tmux session, a bare
agent pane, or both at once. Sub-rows (indented, one per Claude pane) always
show `agent` and inherit the parent row's BRANCH. Any row with a *needs you*
or *finished* agent sorts first.

| Key | Does |
|---|---|
| <kbd>Tab</kbd> | Cycle combined → sessions → agents → combined |
| <kbd>j</kbd> / <kbd>k</kbd> | Move down / up |
| <kbd>g</kbd> / <kbd>G</kbd> | Jump to top / bottom |
| <kbd>l</kbd> / <kbd>Enter</kbd> | Jump to the row's session or agent pane |
| <kbd>x</kbd> | Send <kbd>Esc</kbd> to the row's most-urgent agent pane (interrupt), without leaving the picker |
| <kbd>r</kbd> | Rename the row's tmux session (prompts inline, cosmetic only — doesn't touch the task file or worktree) |
| <kbd>b</kbd> | Break the row's agent pane out into a brand new session of its own (prompts for a name) — for a second agent you started ad hoc in a shared session and now want on its own. On a parent session row this takes the session's *most-urgent* agent pane; on a row with no agent it does nothing. |
| <kbd>Ctrl</kbd>+<kbd>x</kbd> | On a task row: the full `wb done` wind-down. On a plain session/agent row: a raw kill. |
| <kbd>Ctrl</kbd>+<kbd>r</kbd> | Force a refresh (it also auto-refreshes every few seconds) |
| <kbd>i</kbd> or <kbd>/</kbd> | Start typing to search; <kbd>Esc</kbd> to go back to normal mode |
| <kbd>q</kbd> / <kbd>h</kbd> | Close the picker |

> **Preview pane** shows the live agent screen for a session row, or the
> task file's contents / `git status` for anything else — so you can usually
> tell what a row needs without leaving the list.

> **Multiple agents, one session.** `wb new` only provisions one dedicated
> `agent` window, but nothing limits you to that. Open another window or
> split a pane in the same session and start `claude` there — the picker
> scans every pane in the session, not just that one window, so it's
> automatically picked up as another sub-row (`both`/`agent` in TYPE) with
> no extra step.

> **But not visually, at the tmux level.** tmux's window list itself won't
> tell you a second agent is running — window names (`nvim`/`agent`/`shell`)
> are set explicitly at creation and don't auto-rename to reflect what's
> running, so a second `claude` started in the `shell` window still just
> says "shell" in the status bar. What you actually have: a global,
> session-independent indicator — `status-left` shows a live `✳N`/`✔N`
> count of agents needing you or just finished, pushed by Claude Code's own
> hooks (`claude-notify-hook.sh`), plus the picker's sub-rows for "which
> one, exactly." If a stray agent in a shared session gets annoying to
> track, press <kbd>b</kbd> on it to give it its own session.

## wb done — wind down, safely

```
$ wb done [<session>]   # no argument = the session you're in
```

In order, every time:

1. **Fails fast** if the worktree is dirty — prints `git status --porcelain`
   and stops. Nothing is touched.
2. If there are gitignored files or directories the worktree removal would
   otherwise silently destroy, appends a checklist to the task file and
   opens it in a split — **tick `- [x] keep <path>`** on anything worth
   keeping, save, close.
3. Copies anything you kept into `~/code/tasks/dossiers/<repo>--<slug>/`
   and records where it went in the task file, then removes the temporary
   checklist.
4. Removes the git worktree, flips the task's `status:` to `done`, kills
   the tmux session.

> If you're several tasks behind on tidying up, `wb done` will nudge you:
> *"N follow-ups pending · M parked — consider running `/parked-items`."*
> The same count shows in the picker's status line at all times.

## Bringing a gitignored file into a new worktree

A fresh worktree only has tracked files — anything gitignored (a local
`config.hjson`, `node_modules`, credentials) is missing until you seed it.
Drop a `.worktree-bootstrap` file at a repo's root, one path per line:

```
# be--monorepo/.worktree-bootstrap
apps/metrics_server/config.hjson
node_modules
.env.local
```

Files are copied; directories are symlinked back to the main checkout, so a
worktree never needs its own `npm install`. No manifest? `wb new` falls
back to copying whatever `.env*` files exist at the repo root.

## The task store

`~/code/tasks` is a plain git repo, local for now (no remote pushed yet —
that's a five-minute follow-up whenever you want cross-machine sync). One
markdown file per task, named `<repo>--<slug>.md`:

```
---
status: doing        # planned | doing | review | done
repo: dotfiles
branch: feat/onboarding
worktree: .worktrees/feat/onboarding
tags: []
created: 2026-07-06
---
# Title

## Plan
## Done
## Follow-ups
## Decisions
```

It's a real git repo you can `cd` into, `git log`, or open in `wb` itself
(it shows up as a repo row like anything else under `~/code`).
`/parked-items` now promotes follow-ups here instead of a per-repo
`scratch/tasks/`, and worktree setup checks it for existing context before
starting from scratch.

The planned/backlog tasks the presence-only picker hides are one command
away:

```
wb board    # read-only status table over the whole store (the interim /board)
```

## `wb board --html` — the full board (v2)

`wb board --html` writes `logs/board.html` (gitignored, overwritten on every
call) — a richer, filterable view over the whole store that goes well beyond
the plain-text table above. Open it with `xdg-open logs/board.html` or via
`/wb-board html` from inside a session.

**Pipeline tab, first and default.** One row per task that isn't `done` yet,
regardless of the today/week window — a task untouched for two weeks still
shows up here, since the point is a complete in-flight surface, not a
recency filter. Five stage columns (**Ideate · Brainstorm · Plan · Work ·
Review**) each render one of four states:

| Glyph | State | Meaning |
|---|---|---|
| ✓ | done | The stage's artifact exists (a doc, a stamped `reviewed:` date, or — for Work — the task is closed with no open PR) |
| ◐ | in progress | Work only: real changes exist, or a PR is open in any state |
| ○ | pending | Declared (or defaulted) into the task's intended path, nothing has happened yet |
| · (faint) | n/a | Not part of this task's intended path, and nothing has fired to upgrade it |

A stage's state is **computed live** every render, never stored — a task's
`path:` frontmatter field declares which stages it intends to go through
(defaults to `plan,work,review` when absent), but a real signal always wins
even for an undeclared stage: if a plan doc shows up for a task that never
declared `plan` in its path, that stage renders done anyway. Stage cells
link to their backing artifact (the doc, or the PR) when one exists on disk;
a task whose worktree is gone but whose branch still carries the doc shows
an unlinked glyph with a tooltip naming it, rather than losing the signal.

**Every detail card** (bucket tabs and Pipeline alike, done tasks included)
shows the same stepper as a two-zone card: identity (title, status, repo ·
branch) on the left, live-agent badge / worktree indicator / PR chip on the
right. Doc stages list every matching artifact as a chip, not just the
newest.

**Relationships.** A task can declare `depends_on: <repo>--<slug>[,...]` —
comma-separated blocker stems, met once the blocker's `status:` is `done`. A
blocked task renders dimmed with a ⛔ count (tooltip names the blockers); its
blocker shows a → count of tasks waiting on it — both directions visible at
once, independently. A dangling stem or a dependency cycle fails open (fail
loud would be worse: it renders the task unblocked with a visible warning
naming the problem) rather than breaking the render. A parent task (via
`parent:`) shows an `n/m children done` counter and a ready-to-close hint
once every child is done — the parent's own status pill is never touched by
this.

**Filters.** The header carries the today/week window as a segmented
control, plus two independent, AND-composing dropdown filters: **Repo**
(every repo present in the store) and **Family** (a parent and its
children — only appears at all once the store has at least one parent/child
pair). Both default to "All"; picking a specific option narrows every tab's
table and cards at once, never Key Findings (below).

**Key Findings**, at the bottom of every tab, is board-global and explicitly
tagged *board-wide · ignores filters* — no repo/family filter narrows it,
since it's meant to answer "what needs attention across everything," not
"what's in this slice." Six starter insights, each omitted when empty
(never an empty heading): the task blocking the most others, parents ready
to close, a count of done-but-unreviewed tasks, the oldest in-flight task,
tasks whose status maps to no known bucket, and branchless tasks whose stem
already matches a doc in this repo's own `docs/` tree (a "wrote the plan,
haven't started the branch yet" pattern that's otherwise invisible).

**Creating a task with intent:** `wb new` accepts `--path <stages>` (a
comma-separated subset of the five stage names, validated against unknown
names before anything is created) and repeatable `--depends-on <stem>` (each
validated against a real task file). Both are optional — every task still
gets the `plan,work,review` default when `--path` is omitted.

**Review-stamp convention.** After any `/ce-code-review` pass completes
inside a `wb` session, run `wb reviewed` — it stamps the task's `reviewed:`
field, which is what makes the Review stage (and the unreviewed-count
insight) tell the truth. This is a convention, not automation — nothing
enforces it, it only works if it's actually run.

## Known rough edges (not blocking, worth knowing)

- The picker's auto-refresh briefly pauses input while it runs (every few
  seconds) — it's doing more work per refresh than the old `ca` did, since
  it now scans every repo too. Not broken, just occasionally a beat behind
  a keypress.
- `wb done` always opens the review buffer and waits for you to close it —
  there's no way to run it unattended yet. If you want a fully scripted
  teardown later, that's a small follow-up flag to add.
- Two people (or two panes) running `wb done` on the exact same session at
  the exact same time can still race each other. Unlikely on a
  single-operator machine, but worth knowing.

## Next steps

### Finding parked items and follow-ups

The picker went presence-only, so parked items and follow-ups don't get
rows anymore — only live sessions/agents do. Two places to look instead:

- **Follow-ups** live under each task's `## Follow-ups` heading in
  `~/code/tasks/*.md`. Scan them all at once:
  `grep -A5 '^## Follow-ups' ~/code/tasks/*.md`, or open one task file
  directly.
- **Parked items** live in `~/.claude/parked-items/ledger.jsonl`. Run
  `/parked-items` to review, promote, or dismiss them — that's the intended
  interface, not the picker.

The counts you see in the picker's status line and in `wb done`'s nudge
(`wb_pending_counts`) are a heads-up that these exist, not a drill-down.

> **There's no single "full picture" view yet** — live sessions, deferred
> follow-ups, and parked items are three separate places to look. That gap
> already has a name: **`/roadmap`**, ratified as a follow-up in
> `logs/decisions/2026-07-06-review-outstanding.md` §7 and
> [`roadmap.md`](roadmap.html) §9a — a snapshot over the same task-store
> board (no second status computation), zoomable today/task/week,
> deliberately deferred until slices 2+3 (this PR) are done. It's tracked
> as a Follow-up on this task's own record so it isn't lost.

### Merging this PR

Everything in this guide is ready to merge as-is. What's deliberately *not*
in this PR:

- **`wb adopt`** — a command to retroactively tag an existing plain tmux
  session as a wb task (sets `@wb_repo`/`@wb_slug`, seeds a task file)
  without creating a new worktree. Useful if you're migrating hand-rolled
  sessions like an ad-hoc `be--monorepo` or `frontend` session into this
  workflow. Not built — say the word if the manual path (open a task file
  by hand, `tmux set-option` the two variables) gets old.
- **A remote for `~/code/tasks`** — it's a real git repo but local-only
  right now. Five-minute follow-up whenever cross-machine sync matters.
- **Slices 4 and 5** from the original plan (`roadmap.md` §8) — notes-tui
  revival and an HTML-in-flow help dashboard. Separate, not-yet-started
  work.

[`roadmap.md`](roadmap.html) *is* the overarching plan doc — build order,
later-additions log, and the day-bookend design principle all live there
already. It's had a status pass alongside this guide: §8 now marks slices
1–3 done, and §9a carries the visibility-gap note above.

## If something misbehaves

Nothing was deleted — `s` and `ca` are still there. Two ways back:

```
# by hand, right now
s     # the old repo picker
ca    # the old claude-agent picker

# or revert the keybind cutover commit and reload
git revert 7e02be6
tmux source-file ~/.config/tmux/tmux.conf
```

The cutover, the picker, and the store are three separate commits on
`feat/agent-task-workflow` (PR #7) — any of them can be reverted
independently if one part turns out to need more work than the others.

---

Built alongside PR
[jetnoli-sportable/dotfiles#7](https://github.com/jetnoli-sportable/dotfiles/pull/7)
· task record: `~/code/tasks/dotfiles--agent-task-workflow.md`
