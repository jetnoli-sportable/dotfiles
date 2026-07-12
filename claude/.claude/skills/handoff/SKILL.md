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
- **Never modifies `scripts/.config/scripts/tmux/wb.sh` and never calls a
  bare `wb new`/`cmd_new` (no `--agent`, no `--planned`).** Only
  `handoff.sh` does that, and only inside its own spawn branch (step 6).
  This skill's own side effects against `~/code/tasks/<repo>--<disp_slug>.md`
  are exactly two locked `wb` verbs — `wb new --planned` (step 3, creation
  only; never touches a worktree or tmux session, see step 3 for why that's
  safe here) and `wb append` (step 5, body writes) — plus exactly one final
  shell-out to `handoff.sh`. **Task files under `~/code/tasks` are never
  written with the Edit/Write tool** (the one narrow exception: the
  `# <title>`/first-action preamble line, step 4 — see step 5's note).
  If something seems to need a `wb.sh` change or helper to work well, don't
  add it — note it as a follow-up in the target task file's `## Follow-ups`
  instead.
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

If it's missing, create it by shelling out to `wb new --planned` — the
locked, planned-preserving creation verb (`scripts/.config/scripts/tmux/wb.sh`,
search `cmd_new`'s `--planned` branch) that seeds the task file via
`wb_seed_task_planned` instead of an Edit/Write-tool file creation:

```bash
DOTFILES="${DOTFILES_ROOT:-$HOME/code/dotfiles}"
task_file="$("$DOTFILES/scripts/.config/scripts/tmux/wb.sh" new --planned "$repo" "$slug")"
```

`wb new --planned` creates the file from `~/code/tasks/TEMPLATE.md` and
fills `status: planned` (deliberately **not** `doing`), `repo:`, `branch:`,
and `created:` when the file is new — it never stamps `worktree:` to a
path, since no worktree exists yet at this point — and it only ever fills
blank fields on an existing file, never overwrites. It does not fill a
`# <title>` heading (see the aside below) — compose that line yourself,
derived from the slug (e.g. `feat/foo-bar` → something like `# Foo bar`;
use judgment for a short, readable title, not a mechanical transform), and
insert it right after the frontmatter's closing `---`.

**This step is simpler than it used to be, deliberately.** An earlier
version of this skill pre-stamped `status: doing` and `worktree:
.worktrees/$slug` right here, by sourcing `wb.sh` and calling its internal
`wb_seed_task` directly — an UNLOCKED write that bypassed every per-task
lock this codebase now enforces. That pre-stamping was always redundant:
the REAL `status: doing` + `worktree:` stamping already happens moments
later, for real, in this same skill's own step 6, when `handoff.sh` calls
`wb new --agent` (which goes through `wb_seed_task`'s existing-file branch,
idempotently filling in exactly those fields once the worktree actually
exists). `wb new --planned` recognizes that redundancy and drops it — it
only ever seeds a worktree-less, `status: planned` placeholder here, and
lets step 6 do the real transition, through the ordinary locked path every
other `wb new` caller uses.

Calling `wb new --planned` here does **not** reintroduce the hazard a bare
`wb new`/`cmd_new` call would: the plan's Key Technical Decision
"Responsibility split" (`docs/plans/2026-07-11-001-feat-handoff-v1-plan.md`)
explains why a bare call is dangerous — `cmd_new`'s `is_new` check would
already see the session as existing by the time `handoff.sh`'s own
`wb new --agent` runs moments later, so the thing that actually types
`claude` into the agent pane would silently never run, and the boot poller
would wait forever for a process that was never started. `--planned` mode
returns before ever touching a worktree or a tmux session at all (see its
own header comment in `wb.sh`), so it can't trip that hazard — the thing
still genuinely forbidden here is a bare `wb new <repo> <slug>` (no
`--agent`, no `--planned`) or `cmd_new` call, which does reach that code.

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

**Default the routed worker's kickoff to artifact + decision buffer,
before whatever stage `first_action` names.** Whichever stage this
routes into — `/ce-ideate`, `/ce-brainstorm`, `/ce-plan`, `/ce-work` —
default `first_action` to starting with a context artifact (how this
surfaced, why, relevant background gathered so far) and an accompanying
decision buffer (`~/.claude/skills/decision-buffer/SKILL.md`) covering
whatever open questions the routed worker will need the requester to
answer, *then* proceeding into the named stage. This is the same
sequence that worked well kicking off `dotfiles--fix-wb-sweep-buffer-
autoformat` by hand (2026-07-11) — front-load context and open questions
into artifacts the requester reacts to once, rather than trickling
clarifying questions back through a routed session one at a time. Write
it as part of the same line, not a separate instruction the routed
worker might skim past:

```
**First action when picked up:** artifact + decision buffer covering
[what's known, why, open questions], then `/ce-plan` from this file.
```

**Overridable — don't force it when it's already redundant.** Skip the
artifact/buffer prefix and write the bare `first_action` (the original
form above) when: the routing discussion already resolved every open
question before handoff (nothing left for a buffer to ask), the user
explicitly says to skip it ("just spin it up and have it start", "skip
the artifact, go straight to work"), or the chosen stage is `/ce-work`
against an already-fully-scoped plan with no decisions left — a decision
buffer with zero real questions is worse than none (see the decision-
buffer skill's own "trivial decision" exception). When in doubt, default
to including it; it's cheap for the routed worker to produce and skip
irrelevant sections, expensive for the requester to get a session that
immediately starts asking questions one at a time in chat instead.

### 5. Write the rich context

This is the payload the routed worker actually reads — `handoff.sh` only
ever injects a short, fixed pointer naming this file (never the context
itself), so whatever isn't captured here is lost to the routed session.

Shell out to `wb append` (the same locked, heading-scoped verb step 3's
creation call goes through) instead of an Edit-tool write on the task
file's prose, passing the full context as a multi-line body via stdin:

- **New task (empty `## Plan`):** target `Plan` as the heading — the rich
  context (what's being discussed, why, relevant constraints, anything
  already decided or ruled out) lands as that section's own content, since
  it's currently empty.

  ```bash
  wb append "$task_file" Plan <<EOF
  <the rich context — what's being discussed, why, constraints, anything
  already decided or ruled out>
  EOF
  ```

- **Existing, already-active task (`## Plan` already holds unrelated
  in-flight narrative):** target `Follow-ups` instead — the new
  discussion's context lands as its own block at the end of that section,
  clearly distinguishable from whatever's already there, never touching
  `## Plan`'s existing prose.

  ```bash
  wb append "$task_file" Follow-ups <<EOF
  <the new discussion's context, as its own block>
  EOF
  ```

Either way, `wb append` is append-only under the named heading by
construction — it can only ever add a new block at the end of that section
(creating the heading first if it's missing, per the same fallback
convention step 3's creation call and `wb_append_handoff` both use), never
touch a byte of what's already in `## Plan`, `## Decisions`, or
`## Follow-ups`. This preserves the "never overwrite" guarantee this
section always carried, now as a structural property of the verb rather
than a habit to remember.

**Never write or edit task-file body content under a `##` section with the
Edit/Write tool — always shell out to `wb append` instead.** The one
narrow, documented exception in this skill: the `# <title>`/first-action
preamble line (step 4) sits *before* any `##` section, a position
`wb append`'s heading-scoped model has no way to express, so that one line
stays a direct Read+Edit insertion.

### 6. Invoke `handoff.sh` and relay the outcome

Run `handoff.sh <repo> <slug>` with no flags — `first_action` already lives
in the task file from step 4, so there's nothing else to pass. **Substitute
the literal repo/slug/path values you already resolved in steps 1-2** —
do not copy the `$DOTFILES`/`$repo`/`$slug` variable names verbatim into a
fresh shell call. Each of steps 2-5 above runs as its own tool call (a
`bash -c` invocation for step 2, a `wb new --planned` Bash call for step 3,
Read/Edit for step 4's title/first-action preamble line, and a `wb append`
Bash call for step 5), and this harness's shell state does not persist
between separate Bash calls — a
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
