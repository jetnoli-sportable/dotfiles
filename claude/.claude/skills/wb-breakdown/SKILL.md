---
name: wb-breakdown
description: Split one oversized task in `~/code/tasks` (or an incoming Jira ticket) into a linked parent/child family of session-sized tasks, through a human-approved proposal buffer and a locked multi-file apply. Use when the user types `/wb-breakdown`, says "split this task up", "break this down into smaller pieces", "this task has gotten too big", "turn this ticket into a task", "wb-breakdown", or names a Jira ticket key/URL they want scoped into a family of children. With no argument, lists tasks already tagged `breakdown-candidate`. Never writes task files itself — authors a proposal buffer and hands it to `wb breakdown --apply`, which owns every store write.
---

# wb-breakdown

Splits one oversized task — a `.md` file in `~/code/tasks` whose `## Plan`
has grown into a week of work, or a Jira ticket that hasn't become a task
yet — into a **parent/child family**: the original task turns into a
session-less coordinator, and one or more new, session-sized children carry
the actual work forward. One of the children (the "continuing" one)
inherits the parent's real git branch/worktree/session, so whatever was
already in flight keeps running uninterrupted; the rest start fresh as
`status: planned`.

This skill is entirely the **authoring half** of the split (D5 in the
design doc): it gathers evidence, decides what the family should look like,
and writes a proposal for a human to check and edit. It never writes a task
file itself. `wb breakdown --apply` (`scripts/.config/scripts/tmux/wb.sh`,
search `cmd_breakdown`) is the other half — it validates the approved
proposal and performs every store write, under a locked multi-file
transaction.

## Scope — what this does and doesn't do

- **Never writes to `~/code/tasks` with the Edit/Write tool, and never
  calls a wb.sh verb that mutates the store on this skill's own initiative.**
  The only two `wb` verbs this skill ever invokes are `wb new --planned`
  (ticket-parent seeding, step 2b below — the same locked, planned-
  preserving creation path `/handoff`'s SKILL.md already uses for exactly
  this reason) and, at the very end, `wb breakdown --apply <buffer-path>`
  — the one place that actually creates children, migrates the parent, and
  moves follow-ups. Every other family decision (which children, what
  slugs, what moves) lives in a proposal buffer the human edits and
  approves; nothing about it is a store write until `--apply` runs.
- **The buffer itself lives in the dotfiles repo** (`logs/breakdowns/`),
  not `~/code/tasks` — it's a proposal, not task-store content, and this
  keeps it entirely outside the task-store git hooks' write-detection
  scope by construction.
- **Single parent per invocation.** One family split at a time — this
  skill does not chain multiple parents in one run, and does not merge two
  existing families back together (out of scope for v1, see the design
  doc's Scope Boundaries).
- **Never invents an apply outcome.** `wb breakdown --apply`'s own
  stdout/stderr is what actually happened — relay it, don't paraphrase a
  guess about what should have happened.
- **Trigger phrasing:** `/wb-breakdown`, `/wb-breakdown <stem>`,
  `/wb-breakdown <ticket-key-or-url>`, "split this task up", "break this
  down", "this task's grown too big, split it", "turn SFB-1234 into a
  task and split it", or a bare `/wb-breakdown` to list current
  `breakdown-candidate`-tagged tasks.

## Flow

### 1. No argument: list candidates

`/wb-breakdown` with nothing after it lists tasks already tagged as
breakdown candidates (D10) — read-only, no evidence-gathering, no buffer.

```bash
grep -l '^tags:.*breakdown-candidate' ~/code/tasks/*.md 2>/dev/null \
  | grep -vE '/(README|TEMPLATE)\.md$'
```

Anchored on the frontmatter `tags:` line specifically (`^tags:.*`), not a
bare substring match — a task whose `## Plan` prose happens to *mention*
"breakdown candidate" must never show up in this list, only one whose
`tags: [...]` array actually carries the tag. `README.md`/`TEMPLATE.md`
never carry real frontmatter tags, but filter them out explicitly anyway
in case a future template gains a stray example line. Report the list (repo,
title, one-line reason if the task's `## Plan` has an optional rationale
line per D10) and stop — no argument means look, not act.

### 2. Determine input: stem or ticket

- **Stem**: an existing task-file stem (`<repo>--<slug>`, with or without
  `.md`) or a fuzzy match against one (same substring-with-ambiguity-guard
  convention `wb resume`/`wb append` already use — 0 or 2+ matches fail
  loud rather than guessing). Resolve it to a real file before continuing;
  if it doesn't resolve, say so and stop.
- **Ticket**: a Jira issue key (`SFB-1234`) or a full ticket URL. Continue
  to step 2b.

#### 2b. Ticket path: fetch, normalize, seed the parent

**Fetch before any write (KTD9) — no store file is created until the
fetch succeeds.** Use the Atlassian MCP:

```
getAccessibleAtlassianResources()          # -> cloudId for the site
getJiraIssue({ cloudId, issueIdOrKey: "SFB-1234",
               fields: ["summary","description","subtasks"] })
```

If the MCP is unavailable, or the fetch 404s/auth-errors, report a clear
error and stop — **the stem path above is entirely unaffected** by this
failure; don't fall back to inventing ticket content.

Normalize whatever the user gave you (bare key, `/browse/SFB-1234`, a full
URL with query params) into the **full canonical ticket URL** — that
exact string is what lands in `jira:` frontmatter (R13), verbatim,
forever; never re-derive or re-normalize it later.

**Find-or-create, fill-blanks-only (KTD9):** before seeding anything, check
whether a task already exists for this exact `jira:` URL or the ticket-
derived stem — reuse it (a re-run against the same ticket must never
duplicate or clobber). Otherwise, seed a session-less parent via the
locked, planned-preserving verb (`scripts/.config/scripts/tmux/wb.sh`,
search `cmd_new`'s `--planned` branch, extended with `--jira`/`--title`):

```bash
wb new --planned --jira "https://sportable.atlassian.net/browse/SFB-1234" \
  --title "Ticket summary text here" \
  proj feat-ticket-slug <<'EOF'
<ticket description, rendered to markdown>
EOF
```

**Pass `--title` explicitly with the ticket's summary** — without it, the
parent's title falls back to a mechanical slug-derived form
(`feat-ticket-slug` → "feat ticket slug"), which is never what you want for
a ticket-seeded parent. The description lands under the seeded parent's
`## Plan`, exactly like the stdin body path `wb_seed_planned_child` uses
for children — and, matching KTD9's find-or-create guarantee, both the
title and the body land ONLY on a genuinely new file; re-running this same
command against an already-seeded ticket reuses the existing parent
untouched (fill-blanks-only applies to frontmatter only — an existing
file's title/body are never overwritten). Once the parent exists, continue
identically to the stem path from here — the rest of this flow doesn't
know or care whether the parent came from a ticket or was already there.

### 3. Climb the evidence ladder (R3)

Find the richest available evidence for how to split, in order, stopping
at the first rung that has real content. Every rung must emit the
*identical* buffer format (AE4) — nothing downstream can tell which rung
produced the proposal.

1. **Ticket subtasks/description** — if the ticket (step 2b) already has
   subtasks, each one is a natural candidate child.
2. **A linked ce-plan doc's Implementation Units** — if the task's `## Plan`
   references a `docs/plans/*.md` with `Implementation Units` (check via
   `wb_lifecycle_has_plan`, `scripts/.config/scripts/tmux/wb-lifecycle.sh`),
   each unit (or a natural cluster of units) is a candidate child.
3. **A substantive `## Plan`** — apply **the substantive-plan test**: the
   section counts as substantive when it holds **≥3 actionable items**
   (top-level bullets or `###` sub-headings) **or ≥10 non-blank content
   lines**, excluding template stub text. When it passes, read the
   structure of the Plan itself (its own headings/bullet clusters) as the
   proposed split. This exact test is also cited by
   `~/code/tasks/dotfiles--loop-scope-planned-tasks.md`'s own "no `## Plan`
   content beyond a stub" detection — keep both readings in sync if this
   definition ever changes.
4. **Fresh agent pass** — none of the above apply: read the task/repo
   context yourself and propose a reasonable split from scratch. The
   buffer this produces must be indistinguishable in format from every
   other rung (AE4) — only the goals/plan bodies differ.

**Re-breakdown**: if the parent already has children (some `parent:
<this-stem>` tasks exist), list them as read-only context in the buffer —
*not* as new create-checkboxes — so the human sees the whole family
picture while approving whatever's still being proposed (more children,
a migration that hasn't happened yet, more follow-up moves).

### 4. Decide the family shape

- **Continuing child**: if the parent currently has a real
  `branch:`/`worktree:` (i.e. it's an in-flight `doing` task, not one
  seeded from a ticket), exactly one proposed child inherits them via the
  migration line (step 5). Default to the child that best matches
  whatever's *already* in progress in the parent's worktree — your
  judgment, not always child #1. A ticket-seeded parent (never had a
  worktree) omits the migration line entirely — there's nothing to give.
- **Child slugs (R7, D7)**: default to parent-prefixed
  (`feat/hub-v0` → `feat/hub-v0-board-embed`), editable by the human in
  the buffer before apply. Use real, distinct git-branch-shaped slugs.
- **Follow-up moves (R11)**: a parent bullet under `## Follow-ups` that
  clearly belongs to one specific child's slice becomes a proposed move
  line, quoting the bullet's exact current text (the match at apply time
  is exact-string, not fuzzy). Bullets that don't clearly belong to one
  child stay put by default — checked moves are a move, never a copy.
- **Parent `## Plan` rewrite**: propose a short post-split summary plus
  whatever didn't get absorbed into any child — this replaces the
  parent's entire `## Plan` section at apply time (not appended), so
  don't propose it unless the rewrite is genuinely meant to replace the
  existing content wholesale.

### 5. Author the proposal buffer

One buffer per parent, at `logs/breakdowns/<parent-stem>.md` in the
dotfiles repo. **Refuse to clobber a prior unresolved buffer** — the same
guard `wb_reconcile_generate_review` uses (`scripts/.config/scripts/tmux/wb.sh`,
search `wb_reconcile_generate_review`): if a file already exists at that
path, still carries a `<!-- wb-breakdown:` marker, and still has any
unchecked `- [ ]` box, stop and tell the human an unresolved review already
exists there rather than overwriting it.

Grammar (exact — `cmd_breakdown --apply`'s parser is strict about this
shape; see `scripts/.config/scripts/tmux/wb.sh`, search
`_wb_breakdown_validate` for the authoritative parse/validate rules):

```markdown
# wb breakdown — <raw-parent-branch> (<parent-stem>)

> Check what you approve, edit slugs/goals/bodies in place, save and close.
> `wb breakdown --apply logs/breakdowns/<parent-stem>.md` executes
> exactly what's checked — an unchecked item is left exactly as-is.

## child 1 — <short label> (continuing)
<!-- wb-breakdown: block=child n=1 parent=<parent-stem> repo=<repo> -->
- [x] create child: `<raw-slug>`
- goal: <one-line goal, editable — becomes the child's title>
- size: <S|M|L|XL or blank — see "size/depends_on" rule below>
- depends_on: <blank, or `<sibling-raw-slug>`, `<repo>--<slug>`, … comma-separated>
<!-- wb-breakdown: begin-plan n=1 -->
<child's plan body, verbatim markdown, written into the child's ## Plan>
<!-- wb-breakdown: end-plan -->

## child 2 — <short label>
<!-- wb-breakdown: block=child n=2 parent=<parent-stem> repo=<repo> -->
- [ ] create child: `<raw-slug>`
- goal: <one-line goal>
- size:
- depends_on:
<!-- wb-breakdown: begin-plan n=2 -->
…
<!-- wb-breakdown: end-plan -->

## parent edits
<!-- wb-breakdown: block=parent parent=<parent-stem> -->
- [x] migrate branch/worktree + re-aim @task → continuing child: `<raw-slug>`
- [ ] rewrite parent ## Plan as below
<!-- wb-breakdown: begin-plan parent -->
<skill-authored post-split summary + unabsorbed remainder>
<!-- wb-breakdown: end-plan -->
- [ ] move follow-up: "<exact existing bullet text>" → child: `<raw-slug>`
```

Rules worth restating because the parser enforces them exactly:

- Backticked values are the machine-read fields — `___` means "you must
  fill this in before it can be checked." Never leave a checked box with
  an unfilled `___` target.
- The migration line appears **at most once**, and only when the parent
  actually has a worktree/session to give (step 4). Leave it unchecked
  by default only if you're genuinely unsure which child continues —
  otherwise pre-check your best judgment; the human edits it either way.
- Every child block's `create child:` line is checked by default (you're
  proposing it), except an existing child re-listed as context (step 3's
  re-breakdown case) — which gets no checkbox line at all, just its
  current state noted in prose.
- Raw slugs must be real git-branch-shaped strings with no whitespace and
  no backtick — `wb_sanitize` (the sanitizer apply uses to turn a raw slug
  into a filename stem) strips neither.
- **`- size:` / `- depends_on:` are always emitted on every child block,
  values blank by default.** Both bullets sit directly under `- goal:` so
  they're discoverable and one keystroke to fill, but the skill writes a
  value only when the child's own plan/goal already states a clear,
  verified basis: an explicit effort estimate already in the plan body →
  `size`; a dependency already named in prose (e.g. "needs the schema from
  child 1 first") → `depends_on`. Never a blind `size: M`, never a
  "predecessor chain" that makes each child depend on the previous one by
  default — parallel is the norm, a dependency is the exception, and a
  blank `size:` already reads as `M` at load, so blank costs nothing and
  never manufactures false precision.
- `size` must be exactly one of `S`, `M`, `L`, `XL` (uppercase) or blank.
  Anything else (`XXL`, `medium`, lowercase `l`) is a hard parse error
  that aborts the **whole** apply before any write, like the other
  structural guards — not a per-item skip.
- `depends_on` lists **raw sibling slugs** (backticked, comma-separated,
  the same raw form as the `create child:` line), which apply resolves to
  `<repo>--<sanitize(slug)>` stems at write time — exactly the
  raw-slug-resolved-at-apply convention the migrate/move targets already
  use. A token that already contains `--` is a full `<repo>--<slug>` stem
  and is written verbatim (for cross-repo/external blockers). There is
  **no existence check**: a sibling seeded later in the same apply is fine,
  and a dep matching neither a checked sibling nor an existing file only
  warns (the board fails open on dangling deps). Shape rules the parser
  does enforce, all hard whole-apply errors: a token may not contain
  whitespace or `..`; a full stem may not contain `/` (a bare slug may —
  it sanitizes to `-`); and the resolved stem must stay within
  `[A-Za-z0-9_.-]` (it's written into frontmatter and used as a filename
  stem verbatim).
- No literal tab characters in `- goal:`, `- size:` or `- depends_on:`
  values — the parser carries them in a tab-separated row, so a tab is a
  hard parse error rather than a silently shifted field.
- Only the block **header** (the bullets above `begin-plan`) is read for
  `- goal:`/`- size:`/`- depends_on:`. Plan-body lines that happen to
  start the same way are prose and are never picked up, so a blank header
  bullet stays blank.

### 6. Open the buffer, blocking

Same recipe `decision-buffer`/`wb-done` use
(`claude/.claude/skills/decision-buffer/SKILL.md`, search "auto-open" —
the `tmux split-window` + unique-per-invocation `wait-for` channel):

```
Bash (run_in_background: true):
  CHAN="wb-breakdown-done-$$-$RANDOM"
  tmux set -p -t "$TMUX_PANE" @claude_blocked nvim-buffer
  WB_REVIEW_BUFFER=1 tmux split-window -h -t "$TMUX_PANE" \
    "nvim 'logs/breakdowns/<parent-stem>.md'; tmux wait-for -S $CHAN" \
    && tmux wait-for "$CHAN"
  tmux set -pu -t "$TMUX_PANE" @claude_blocked
```

`WB_REVIEW_BUFFER=1` is required — it's the flag conform.nvim's
format-on-save checks before running, so it can't silently mangle the
buffer's HTML-comment markers (the exact PR #27 Sweep-buffer regression
this convention exists to prevent). After launching, tell the user the
buffer is open and end the turn — do not poll, schedule a wakeup, or keep
talking; the background command completing is the signal.

### 7. Parse on return

When the background command completes, read the closed buffer fresh:

- Prose under any inline note, or an edited `parent=` field, gets answered
  or resolved before acting on anything else — same contract
  decision-buffer's own step 3 uses.
- **All-unchecked close**: if nothing at all is checked, report that
  nothing was approved and stop. Do not re-fire (re-generate/re-open) the
  same buffer automatically — the human closed it on purpose; ask before
  trying again.
- Otherwise, continue to apply.

### 8. Invoke `wb breakdown --apply`

**An ordinary synchronous Bash call — never backgrounded.** Unlike `wb
done`/the buffer-open above, `--apply` never opens a buffer of its own: it's
single-phase, non-interactive, and lock-bounded (`flock -w 1` per file it
touches), so its stdout/stderr come back inline immediately.

```bash
wb breakdown --apply logs/breakdowns/<parent-stem>.md
```

Two different failure shapes to tell apart when relaying the result — see
`scripts/.config/scripts/tmux/wb.sh`, search `_wb_breakdown_validate` for
the authoritative list of each:

- **Hard parse errors** (a malformed/mangled marker, a duplicate `n=`, more
  than one migration line, a whitespace/backtick-bearing slug) abort the
  *whole* apply — nothing was written. Relay the error verbatim and stop;
  don't hand-patch the buffer yourself and re-run, let the human fix it and
  re-invoke.
- **Item-level issues** (a slug collision, an unresolvable migration/move
  target, an unfilled `___` field) are a per-item *skip*, not a whole-apply
  abort — `--apply` still runs and reports success for everything else,
  with a warning on stderr naming what it skipped. Relay both the success
  summary and the skip warning(s) together in the family report (step 9) —
  don't report a partial success as a total failure.

### 9. Report the family

Relay `wb breakdown --apply`'s own summary line verbatim (it names how
many children were created, whether migration/moves happened), then name
the resulting family: the parent's own stem, each child's stem and
whether it's the continuing one, and the archived buffer's path under
`~/code/tasks/dossiers/<parent-stem>/` (the durable record of what was
approved — R6).

## Test scenarios this skill's behavior must cover

- **No-arg listing**: only tasks with `tags: [..., breakdown-candidate,
  ...]` in real frontmatter appear; a task whose prose merely mentions the
  phrase does not; `README.md`/`TEMPLATE.md` never appear.
- **Stem happy path**: an existing, non-ticket task with a substantive
  `## Plan` produces a buffer, gets approved, and `--apply` reports the
  expected family.
- **Ticket happy path**: a bare key and a full URL both normalize to the
  same `jira:` value; re-running against the same ticket reuses the
  existing parent (fill-blanks-only) rather than creating a second one.
- **MCP-unavailable degradation**: the ticket fetch fails cleanly (clear
  error, zero files touched) and the stem path is completely unaffected by
  the failure — verify by running the stem path directly afterward in the
  same session.
- **AE4** — a bare task with no ticket, no linked plan doc, and no
  substantive `## Plan` still produces a buffer in the exact same format
  as every other rung; only the goals/plan-body content differs.
- **All-unchecked close**: closing the buffer with every box left
  unchecked reports a clean no-op and does not reopen or regenerate the
  buffer.
- **Buffer-already-unresolved refusal**: invoking this skill again against
  a parent whose prior buffer still has a marker and an unchecked box
  relays wb.sh's/step 5's own refusal rather than silently overwriting it.

Plus one repo-level check enforced by `tests/wb-breakdown.test.sh` itself
(not something this skill can self-test): a grep assertion that this
SKILL.md contains no Edit/Write-tool instructions targeting `~/code/tasks`
— the same precedent the concurrency-safety plan's U4 established for
sibling skills.

## Notes

- This skill never modifies `scripts/.config/scripts/tmux/wb.sh` — every
  behavior described above (the buffer grammar's parse/validate rules, the
  locked apply, the planned-seed primitives) is already built there. If
  something here seems to need a `wb.sh` change to work well, that's a
  follow-up for the task file, not something to patch around in this
  skill.
- `~/code/tasks/README.md` documents the `jira:` frontmatter field, the
  `breakdown-candidate` tag convention this skill reads/writes, and the
  `size:` field ("Size" section: `S|M|L|XL`, absent/blank reads as `M`, no
  retroactive backfill of older task files).
- The Jira-watch loop that would auto-tag candidates
  (`dotfiles--loop-jira-watch`) and bash-side `wb new <ticket>`
  (`feat-jira-integration`) are separate, later work — this skill's own
  ticket path (step 2b) is deliberately the only place Jira input is
  handled today.
- Family-aware `wb resume` niceties (e.g. resuming a parent suggesting its
  children) and cycle-tolerant picker/board rendering are deferred
  follow-ups, not gaps in this skill — see the design doc's Scope
  Boundaries.
