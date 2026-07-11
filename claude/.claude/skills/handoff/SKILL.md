---
name: handoff
description: Route one piece of the current, in-conversation discussion to the worker that should own it — switch to an already-live tmux session (clipboard handoff) or spin up a fresh one via `wb new --agent`, seeding the target task file with rich context first. Use when the user types `/handoff`, says "hand this off", "route this to <repo>", "spin up an agent for this", or mid-conversation asks to send a tangential piece of the discussion to its own worker. Single-target only — not for splitting one discussion into several linked tasks.
---

# Handoff

`/handoff` takes something being discussed right now and routes it to the
worker that should own it: an already-live tmux session for that repo/slug
(switch it into focus, put a pointer on the clipboard), or a fresh one
(`wb new --agent`, then inject the pointer once it boots). The mechanical
half — checking for a live session, spawning, polling for boot-ready,
clearing the one-time permission prompt — is entirely `scripts/.config/scripts/tmux/handoff.sh`,
already built: `handoff.sh <repo> <slug>`, no flags. This skill is
everything that script can't do on its own: deciding which repo/slug the
conversation actually maps to, and making sure the target task file
carries the context and instructions the routed worker will need before
`handoff.sh` ever runs.

## Scope — what this does and doesn't do

- **Single-target only.** One repo/slug per invocation. Splitting a single
  discussion into several linked tasks (fan-out) is explicitly out of
  scope for v1 — it depends on the task parent/child relationship, which
  is designed (`logs/decisions/2026-07-09-hub-v0-scoping.md` D9–D12) but
  not yet built (parallel `feat/task-parent-child` branch). If a
  discussion genuinely has multiple independent targets, route the single
  most relevant one and say so — don't try to approximate fan-out by
  looping this skill yourself.
- **Never modifies `scripts/.config/scripts/tmux/wb.sh` and never calls
  `wb new` directly.** Only `handoff.sh` does that, and only inside its
  own spawn branch. This skill's own side effects are: Read/Write against
  `~/code/tasks/<repo>--<disp_slug>.md`, and exactly one final shell-out to
  `handoff.sh`. If something seems to need a `wb.sh` change or helper to
  work well, don't add it — note it as a follow-up in the target task
  file's `## Follow-ups` instead.
- **Trigger phrasing:** `/handoff`, "hand this off", "route this to
  <repo>", "spin up an agent for this", "send this to its own worker", or
  any mid-conversation ask to move a tangential piece of the current
  discussion out to its own session rather than keep working it here.

## What to do

### 1. Infer `repo` and `slug`

Decide which repo and which slug (task-file topic string, branch-shaped —
e.g. `feat/foo-bar`) the discussion maps to.

Reuse the existing worktree-seeding lookup convention (`~/.claude/CLAUDE.md`
"Worktree setup → seed from an existing task record") rather than
reinventing it: check `~/code/tasks/<repo>--*.md` for a task that already
represents this discussion before minting a new slug. Match by `repo:`
frontmatter first, then judgment on the task's title/`branch:` against
what's actually being discussed — not just an exact filename hit. A
discussion about "the flaky auth test" should be recognized against an
existing `be--monorepo--fix-flaky-auth-test.md` even though nobody typed
that exact string.

- If a matching task already exists, reuse its `repo`/`slug` (read `slug`
  back off its `branch:` frontmatter field) — do not mint a second slug
  for the same work.
- If nothing matches, mint a new slug: short, kebab/branch-shaped,
  descriptive of the piece being routed (e.g. `feat/retry-backoff`,
  `fix-flaky-auth-test`).
- **Ask the user (one brief clarifying question) only when genuinely
  ambiguous** — a cross-repo discussion where the target repo isn't
  obvious, or unclear which piece of a multi-threaded conversation "this"
  refers to. Otherwise proceed directly: this runs in an auto-mode-biased,
  low-ceremony personal workflow, so don't over-ask when the answer is
  reasonably inferable from context.

### 2. Compute the task-file path exactly the way `handoff.sh` will

`handoff.sh` builds its target path as
`wb_task_file "$repo" "$(wb_sanitize "$slug")"` — the slug run through
`wb_sanitize` (`/`, `.`, `:` → `-`) before it's ever used to build a
filename. Every real consumer of this path (`wb_seed_task`, `cmd_new`,
`cmd_pause`, the board) computes it from the *sanitized* slug, never the
raw one — a slug containing `/` (the common case: branch-shaped slugs like
`feat/foo-bar`) resolves to two different files if the skill's write uses
the raw slug while `handoff.sh`'s later read uses the sanitized one. That
mismatch was a real gap two independent doc-review personas caught in an
earlier draft of this plan, and it's exactly the kind of thing that fails
silently (the skill writes rich context into one file; `wb new --agent`
seeds and the agent reads a different, blank one).

Don't re-derive the sanitize transform by hand — shell out to `wb.sh`'s
own helpers so the path can never drift from what `wb_task_file`/
`wb_sanitize` actually compute:

```bash
DOTFILES="${DOTFILES_ROOT:-$HOME/code/dotfiles}"
task_file="$(cd "$DOTFILES" && bash -c '
  source scripts/.config/scripts/tmux/wb.sh
  wb_task_file "$1" "$(wb_sanitize "$2")"
' _ "$repo" "$slug")"
```

(The `scripts/.config/scripts/tmux/wb.sh` path is relative to the dotfiles
repo root — `cd` there first, exactly the way the command above does,
rather than trying to make the path work from whatever directory the
current conversation happens to be in.) Sourcing `wb.sh` this way is
safe — its CLI dispatch is guarded (`wb.sh`, end of file) and never fires
when it's sourced rather than executed, the same property
`tests/wb-resume.test.sh` and `handoff.sh` itself already rely on.

### 3. Ensure the task file exists at that path

If a file already exists at `$task_file`, skip to step 4 — never
overwrite existing frontmatter or body content wholesale.

If it's missing, create it by shelling out to `wb.sh`'s own `wb_seed_task`
helper (`scripts/.config/scripts/tmux/wb.sh:176-208`) — the same helper
`cmd_new` itself calls to seed a task file, so this guarantees byte-
identical frontmatter-fill behavior instead of re-deriving it by hand
(same reasoning as step 2's `wb_task_file`/`wb_sanitize` shell-out):

```bash
DOTFILES="${DOTFILES_ROOT:-$HOME/code/dotfiles}"
task_file="$(cd "$DOTFILES" && bash -c '
  source scripts/.config/scripts/tmux/wb.sh
  wb_seed_task "$1" "$2" ".worktrees/$2"
' _ "$repo" "$slug")"
```

`wb_seed_task` creates the file from `~/code/tasks/TEMPLATE.md` and fills
`status: doing`, `repo:`, `branch:`, `worktree:`, and `created:` when the
file is new; it only ever fills blank fields on an existing file, never
overwrites. It does not fill a `# <title>` heading (see the aside below) —
compose that line yourself, derived from the slug (e.g. `feat/foo-bar` →
something like `# Foo bar`; use judgment for a short, readable title, not
a mechanical transform), and insert it right after the frontmatter's
closing `---`.

Never do this by calling `wb new` (or `cmd_new`) itself, even bare with no
`--agent` flag. The plan's Key Technical Decision "Responsibility split"
(`docs/plans/2026-07-11-001-feat-handoff-v1-plan.md`) explains why in
full — in short: `cmd_new`'s `is_new` check would already see the session
as existing by the time `handoff.sh`'s own `wb new --agent` runs moments
later, so the thing that actually types `claude` into the agent pane would
silently never run, and the boot poller would wait forever for a process
that was never started. `wb_seed_task` itself (the plain file-fill helper,
no tmux/worktree side effects) has no such hazard — this skill just never
goes through the `wb new` CLI path.

**IMPORTANT — the live `~/code/tasks/TEMPLATE.md` currently has NO
`## Follow-ups` heading** (only `## Plan` / `## Decisions` / `## Done`),
even though live, in-flight task files (e.g. `~/code/tasks/dotfiles--feat-handoff-v1.md`)
do have one. If this skill only copies the template verbatim, a
brand-new task created this way silently lacks the heading
`handoff.sh`'s R11 bootstrap-gap warning (`handoff_append_followup`) needs
to append into — that append becomes a silent no-op against a file with no
matching heading to insert after. **When creating a new task file, always
check that a `## Follow-ups` heading exists in the body, and add one if it
doesn't** — immediately before `## Decisions` if that heading exists, or
at the end of the file if it doesn't either. Do this every time a new file
is created from the template; never trust that the template already has
it.

(Aside, not something to fix here: the current `TEMPLATE.md` also has no
`# Title` placeholder line at all, which means `wb_seed_task`'s own
title-substitution logic is a no-op against it today. This skill sidesteps
that by composing the `# <title>` line directly rather than relying on
template substitution, per the bullet above — but it's worth knowing the
gap exists if `TEMPLATE.md` is ever revisited.)

### 4. Determine `first_action` and write it into the file

Default: `/ce-plan`. Only pick something else (e.g. `/ce-work`) when the
work is already fully scoped with no open design decisions left to make.
Always state explicitly, to the user, which action was chosen and why —
never let this be a silent inference.

Write it directly into the task file's body as a line immediately under
the `#` title (before any `##` section) — mirroring this exact
convention, already in use in this very task file
(`~/code/tasks/dotfiles--feat-handoff-v1.md`):

```
**First action when picked up:** `/ce-plan` from this file.
```

- If the task file is brand new (step 3), add this line right after the
  `# <title>` heading.
- If the task file already existed and already has a line like this
  (routing a new, related discussion to an already-active task), leave it
  alone unless the new discussion genuinely calls for a *different* first
  action than what's already there — update it only in that case, and say
  so explicitly (same rule: never silent).

### 5. Write the rich context

This is the payload the routed worker actually reads — `handoff.sh` only
ever injects a short, fixed pointer naming this file (never the context
itself), so whatever isn't captured here is lost to the routed session.

- **New task (empty `## Plan`):** write the rich context — what's being
  discussed, why, relevant constraints, anything already decided or ruled
  out — into `## Plan`.
- **Existing, already-active task (`## Plan` already holds unrelated
  in-flight narrative):** don't clobber it. Append the new discussion's
  context under `## Follow-ups` instead, as its own bullet or short block,
  clearly distinguishable from whatever's already there.

Either way, never overwrite existing content in `## Plan`, `## Decisions`,
or `## Follow-ups` — only add to it.

### 6. Invoke `handoff.sh` and relay the outcome

Run `handoff.sh <repo> <slug>` with no flags — `first_action` already lives
in the task file from step 4, so there's nothing else to pass. **Substitute
the literal repo/slug/path values you already resolved in steps 1-2** —
do not copy the `$DOTFILES`/`$repo`/`$slug` variable names verbatim into a
fresh shell call. Each of steps 2-5 above runs as its own tool call (a
`bash -c` invocation for steps 2-3, Read/Write/Edit for step 5), and this
harness's shell state does not persist between separate Bash calls — a
literal `"$DOTFILES/.../handoff.sh" "$repo" "$slug"` composed as a new,
independent command would see all three as empty:

```bash
/home/jetnoli/code/dotfiles/scripts/.config/scripts/tmux/handoff.sh dotfiles feat/foo-bar
```

(Until the plan's deferred post-merge wiring lands — a `~/.zshrc` alias
and a `stow` re-run so `~/.config/scripts/tmux/handoff.sh` exists — invoke
it via its path in the dotfiles checkout as above, not a bare `handoff`
command.)

Relay the outcome back to the user in one line. `handoff.sh`'s own
stdout/stderr messages say exactly which case happened — read the pane
output rather than guessing. Messages below are quoted verbatim from the
script; a trailing internal source-reference like `(see wb_bootstrap,
wb.sh:142-171)` can be dropped when relaying to the user, it's there for
whoever debugs handoff.sh itself, not user-facing content.

**Argument validation (before anything else runs):**
- `handoff: must run from inside a tmux client (...)` (exit 1) — this
  skill's own invocation always runs from inside a tmux-backed session,
  so this should not fire in normal use; if it does, something about the
  invoking environment is unusual and worth surfacing as-is.
- `handoff: invalid repo: <repo>` / `handoff: invalid slug: <slug>` (exit
  1) — the repo/slug you inferred in step 1 contained a path-traversal
  segment (`..`), a leading `/`, a `:`, or another disallowed character.
  Re-derive a clean repo/slug rather than retrying the same values.

**Switch path** (a live session already existed for this repo/slug):
- `handoff: switched to live session <session> — pointer copied to
  clipboard` (exit 0) — clean success; tell the user it switched them and
  the pointer's on the clipboard.
- `handoff: switched to live session <session>, but its agent window has
  no running claude process — pointer copied to clipboard` (stderr, exit
  0) — the session exists but nobody started `claude` there (or a prior
  spawn's boot never completed); tell the user they switched in, but may
  need to start the agent themselves.
- Either of the above may instead end `— clipboard copy failed — pointer
  not on clipboard` if `wl-copy` itself failed; the switch still happened,
  just paste manually isn't available.
- `handoff: warning: <session> is live but <task_file> does not exist`
  (stderr, alongside either switch message above) — an inconsistent state
  worth mentioning, but the switch itself still succeeded.

**Spawn path** (no live session; `wb new --agent` ran):
- `handoff: spawned <session>, injected pointer, cleared the tasks/ read
  permission prompt` (exit 0) — fully clean; tell the user it spawned,
  injected, and is ready with no manual step needed.
- `handoff: spawned <session> but it never showed a boot-ready anchor
  within <N>s — check <target> by hand` (exit 1) — tell the user the
  spawn may need a manual look at that pane.
- `handoff: spawned and injected <session> — no permission prompt seen
  within <N>s (...)` (stderr, exit 0 — not a failure) — tell the user it
  spawned and injected fine; the permission state just isn't confirmed.
- `handoff: spawned and injected <session> — a permission prompt appeared
  but didn't match the expected tasks/Read shape; leaving it for you to
  answer at <target>` (stderr, exit 0) — tell the user to answer that
  prompt by hand.
- `handoff: warning: <repo_dir> has neither a .worktree-bootstrap manifest
  nor a root .env* file — ...` (stderr, may appear alongside any spawn
  outcome above) — R11's bootstrap-gap surfacing; `handoff.sh` also
  durably records this under the task file's `## Follow-ups` itself
  (inserting the heading first if the file didn't have one), so it's not
  just scrollback. Mention it if it fires, but it's non-blocking.

## Notes

- This skill never checks `tmux has-session` itself — that decision (R5)
  belongs entirely to `handoff.sh`. The skill's job ends at "task file is
  ready, here's `<repo> <slug>`" — everything about switch-vs-spawn is the
  script's call.
- `~/code/tasks/README.md` has the full frontmatter schema and the
  parent/child convention (not used by this v1 skill — single-target
  only, see Scope above).
- If this skill is ever extended to fan-out, that's a different unit
  entirely (post `feat/task-parent-child`) — don't grow this one to
  half-support it.
