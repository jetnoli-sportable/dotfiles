---
name: wb-jira-create
description: Turn a wb task (or a /wb-breakdown family) into new Jira tickets in a chosen project (SFB by default, or SW, or another) through a human-approved proposal buffer, writing each created ticket's URL back into the task's jira: field. Use when the user types `/wb-jira-create`, says "create tickets for this", "file these as SFB tickets", "file these as SW tickets", "make Jira tickets from this family", "emit these tasks to Jira", or asks — often right after /wb-breakdown — to turn a scoped task or family into real tickets for the team. Create-only: never updates, transitions, or edits existing tickets. The only task-store write is `wb jira-set`; every ticket is created agent-side over the Atlassian MCP behind an approval gate.
---

# wb-jira-create

> **⚠ NOT YET VERIFIED END-TO-END — do not run against live Jira yet (as of 2026-07-20).**
> The emit flow passes every automated gate but has never been run against a live Atlassian
> MCP (the shared tracker has no sandbox project). Until the verification checklist is worked
> through and green, do **not** invoke this skill to create real tickets — if asked to, surface
> this banner and get explicit confirmation first. Checklist:
> `docs/verification/2026-07-16-jira-emit-verification.html` in the dotfiles repo (PR #32).
> Remove this banner once the checklist passes.

Turns a wb task, or a whole `/wb-breakdown` **family** (a parent plus its
`parent:`-linked children), into new Jira tickets in a chosen project
(**SFB** by default, or another such as **SW**) — one issue per
task that doesn't already carry a `jira:` value — and writes each created
ticket's canonical URL back into that task's `jira:` frontmatter. This is
the *emit* direction: an idea scoped into tasks locally becomes real tickets
the team can see, without leaving the workbench.

Like `/wb-breakdown`, this skill is the **authoring + orchestration half**:
it gathers the tasks, decides the proposed tickets, and writes a proposal
buffer for a human to check and edit. Nothing is created in Jira until the
human approves the buffer. The tickets themselves are created **agent-side
over the Atlassian MCP** (bash cannot create them) — so, unlike
`/wb-breakdown`, there is no all-in-one bash apply. The only task-store
write is the per-ticket URL stamp, and that goes through one dedicated
locked verb, `wb jira-set` (`scripts/.config/scripts/tmux/wb.sh`, search
`cmd_jira_set`).

## Scope — what this does and doesn't do

- **Never writes to `~/code/tasks` with the Edit/Write tool, and never
  mutates the store on this skill's own initiative.** The one and only
  store write this skill performs is `wb jira-set <repo>--<slug> <url>`
  (once per created ticket) — the locked, idempotent-or-refuse write-back
  verb. Every other decision (which tickets, what type, what parent) lives
  in the proposal buffer the human approves; nothing is a store write until
  `wb jira-set` runs, after a ticket actually exists.
- **Create-only — never updates, transitions, comments on, or edits an
  existing Jira ticket (R12).** The only Jira writes are `createJiraIssue`
  (a new issue) and `createIssueLink` (a "Relates" link between issues).
  The granted `write:jira-work` scope technically permits transition/edit/
  delete across the whole instance; this skill deliberately never does any
  of that. The human-approval buffer is the primary gate, and it shows the
  full description that will publish to the shared tracker.
- **The buffer lives in the dotfiles repo** (`logs/jira-create/`), not
  `~/code/tasks` — it's a proposal, not task-store content, which keeps it
  outside the task-store git hooks' write-detection scope by construction.
- **Single input per invocation** — one task or one family at a time. No
  chaining multiple unrelated inputs in one run.
- **Never invents a Jira outcome.** The MCP's own returned result (the
  created issue key/URL, or an error) is what actually happened — relay it,
  never paraphrase a guess. On a mid-run failure, report exactly which
  tickets were created/reused and stamped and which were not (KTD2).
- **Target project is selectable — `SFB` by default.** The run's project is
  one run-level `Project:` field in the buffer, defaulting to **SFB**
  ("Software Features and Bugs") but editable to another Sportable project
  the OAuth identity can reach — e.g. **SW** — or any valid project key. An
  invocation phrased "file these as SW tickets" just seeds that default; the
  buffer field is the authority. **Issue types are project-specific**, so the
  selectable types are resolved from the chosen project's own metadata at
  preflight (step 2b), not hard-coded — for SFB those are Feature | Defect |
  Bug | Improvement | New Feature (Epic exists in SFB but is deliberately not
  offered as a per-ticket type in v1; Epic-as-hierarchy is a deferred upgrade,
  see Notes — the single `Parent ticket:` field carries hierarchy here).
  Default type is **Feature** when the project has it, else the project's own
  default type.
- **Trigger phrasing:** `/wb-jira-create`, `/wb-jira-create <stem>`,
  "create tickets for this", "file these as SFB tickets", "file these as SW
  tickets", "make Jira tickets from this family", "emit these to Jira", or the
  natural chain
  after `/wb-breakdown` ("...now create the tickets").

## Flow

### 1. Resolve the input: a task or a family

- **Single task**: a task-file stem (`<repo>--<slug>`, with or without
  `.md`) or a fuzzy match against one — the same substring-with-ambiguity
  guard `wb resume`/`wb append`/`/wb-breakdown` use (0 or 2+ matches fail
  loud rather than guessing). Resolve it to a real file before continuing.
- **Family**: **always run the child-scan on the resolved stem** — you can't
  know a task is a family parent without it. Enumerate every task whose
  `parent:` **frontmatter** value equals the resolved stem, the same rule
  `wb_family_all_done` uses (`scripts/.config/scripts/tmux/wb.sh`): iterate the
  real task files (excluding `README.md`/`TEMPLATE.md`/`RECOVERY-NOTES-*.md`)
  and compare each file's `wb_get_frontmatter "$f" parent` against the stem —
  a frontmatter-scoped read, **not** a whole-file grep (a `parent:` line in a
  `## Plan` body must never count). If the scan returns one or more children,
  treat the input as a family (parent + those children); if it returns zero,
  it's a single standalone task. A quick `grep -l "^parent: <stem>$"
  ~/code/tasks/*.md` is fine as a first cut, but confirm each hit's match is
  in the frontmatter block and drop the non-task files above.

### 2. Gather each task and drop the already-ticketed ones (R11)

For each task in the input set, read:

- its `# ` title (`wb_task_title`) → the ticket **summary**;
- its `## Plan` section body → the ticket **description** (sent verbatim as
  markdown; `createJiraIssue`'s default `contentFormat` is `markdown`).

**Drop any task that already carries a non-empty `jira:` value** — it is
already ticketed. These become the buffer's read-only "skipped" list (R11,
AE1); they are never proposed as create-blocks. (The `jira:` skip is the
fast path; the Jira-side dedup in step 6 is the correctness backstop on a
retry.)

If every task is skipped, report that everything is already ticketed and
stop — no buffer, no MCP calls.

### 2b. MCP preflight — validate depth, not just reachability (KTD9)

Before authoring the buffer, confirm the Atlassian MCP can actually do the
work — reachability alone is insufficient. Resolve, once, up front, for the
**target project** (default `SFB`, or the project the invocation hinted):

```
getAccessibleAtlassianResources()     # -> cloudId for the Atlassian site
atlassianUserInfo()                    # -> the current user's accountId (for the assignee, R3)
getJiraProjectIssueTypesMetadata({ cloudId, projectKey })  # -> the project's own issue types
```

and confirm the tools the emit loop needs are present:
`createJiraIssue`, `createIssueLink`, `searchJiraIssuesUsingJql`,
`getIssueLinkTypes`. Jira Cloud takes an **`accountId`** for the assignee,
never a name — resolve it here (`atlassianUserInfo` gives the current
user's). Resolve the target project's **issue types** here too — they are
project-specific, so the buffer's editable `type:` options come from this
metadata (default `Feature` when the project has it, else the project's
default), not a hard-coded list. Confirm the OAuth identity can actually
reach the chosen project (a mistyped or inaccessible key fails here, not
mid-create).

If the MCP is unavailable, the fetch auth-errors, or a needed tool is
missing → report the specific gap clearly, **touch nothing** (no buffer, no
store write, no Jira call), and stop. This pre-buffer check is advisory; it
is re-run after approval (step 5b), because the approval wait is unbounded
and the MCP has been observed to drop mid-session.

### 3. Author the proposal buffer

One buffer per invocation, at `logs/jira-create/<stem>.md` in the dotfiles
repo (`<stem>` = the resolved single task's, or the family parent's, stem).
**Refuse to clobber a prior unresolved buffer** — the same guard
`/wb-breakdown` step 5 cites (`wb_reconcile_generate_review`,
`scripts/.config/scripts/tmux/wb.sh`): if a file already exists at that
path, still carries a `<!-- wb-jira-create:` marker, and still has any
unchecked `- [ ]` box, stop and tell the human an unresolved proposal
already exists there rather than overwriting it.

Grammar — one checkbox block per ticket to create; the agent (not bash)
reads this back on return, so it is a human+agent approval surface, never a
bash-parsed grammar (KTD4):

```markdown
# wb jira-create — <input label> (<N> ticket(s) proposed)

> Check the tickets to create; edit `Project:` / `type:` / `summary:` /
> `Parent ticket:` in place; save and close. Only checked blocks are created.
> The description shown under each block is EXACTLY the text published to the
> shared tracker — edit it here if it should read differently.

Project: SFB          <!-- the target project key; edit to SW (or another) — types re-resolve at re-preflight -->
<!-- wb-jira-create: project-field default=SFB -->
Parent ticket: <blank | SFB-1234 | batch:feat-coordinator-slug>
<!-- wb-jira-create: parent-field default=<batch:coordinator-slug | blank> -->

## ticket 1 — <task title>
<!-- wb-jira-create: block=ticket n=1 stem=<repo>--<slug> -->
- [x] create ticket
- type: Feature      (editable — one of the Project's own issue types, from preflight)
- summary: <task title>
<!-- wb-jira-create: begin-description n=1 -->
<the task's entire ## Plan body, verbatim — the ticket description>
<!-- wb-jira-create: end-description n=1 -->

## ticket 2 — <task title>
<!-- wb-jira-create: block=ticket n=2 stem=<repo>--<slug> -->
- [x] create ticket
- type: Feature
- summary: <task title>
<!-- wb-jira-create: begin-description n=2 -->
…
<!-- wb-jira-create: end-description n=2 -->

## skipped — already has jira: (not proposed)
<!-- wb-jira-create: block=skipped -->
- `<repo>--<slug>` — already linked to <existing jira: URL>
```

Buffer rules:

- **The description is shown in full, verbatim — never a truncated
  preview.** The approver must see exactly what publishes to the shared
  tracker. If a `## Plan` is empty, note that and still show the (empty)
  block so the human can fill it before checking.
- **`Project:` is one run-level field**, default `SFB`, editable to another
  accessible project key (e.g. `SW`). It sets `projectKey` for every ticket
  in the run, the dedup JQL's `project = …`, and the `<KEY>-<n>` shape the
  returned URL is validated against. If the human edits it, the post-approval
  re-preflight (step 5b) re-resolves that project's metadata and issue types
  before anything is created.
- **`type:` defaults to `Feature`** (or the project's default when it has no
  Feature type), editable to any one of the **chosen project's** own issue
  types as resolved at preflight — for SFB that's Feature | Defect | Bug |
  Improvement | New Feature (no Story, no Sub-task); another project's set may
  differ. Don't offer a type the preflight metadata didn't return.
- **`Parent ticket:` is one run-level field** applied to every created
  child in the run (R5). It resolves three ways (R6):
  - **blank** → tickets created flat, no links (AE2);
  - **an existing key/URL** (e.g. `SFB-1234`) → children "Relates"-linked to
    it, no parent ticket created (AE4);
  - **a batch row** (`batch:<slug>`, default the **family coordinator**
    when the input is a family with one) → that row's ticket is created
    first so its key exists, then children link to it (AE3, R8). If the
    coordinator row already carries `jira:` (the common case — it was
    skipped in step 2), resolve the parent to its **existing** URL and
    create no second coordinator ticket (KTD10).
  - Default the field to the family coordinator's `batch:` row when the
    input is a family that has one; leave it **blank** for a single
    standalone task.
- Every proposed ticket's `create ticket` box is **checked by default**
  (you're proposing it). A skipped task appears only in the skipped list,
  never as a create-block.

### 4. Open the buffer, blocking

Same recipe `/wb-breakdown` step 6 and `decision-buffer` use — a
`tmux split-window` with a unique-per-invocation `wait-for` channel:

```
Bash (run_in_background: true):
  CHAN="wb-jira-create-done-$$-$RANDOM"
  tmux set -p -t "$TMUX_PANE" @claude_blocked nvim-buffer
  WB_REVIEW_BUFFER=1 tmux split-window -h -t "$TMUX_PANE" \
    "nvim 'logs/jira-create/<stem>.md'; tmux wait-for -S $CHAN" \
    && tmux wait-for "$CHAN"
  tmux set -pu -t "$TMUX_PANE" @claude_blocked
```

`WB_REVIEW_BUFFER=1` is required — it is the flag conform.nvim's
format-on-save checks before running, so it can't silently mangle the
buffer's HTML-comment markers (the PR #27 Sweep-buffer regression this
convention prevents). After launching, tell the user the buffer is open and
**end the turn** — do not poll, schedule a wakeup, or keep talking; the
background command completing is the signal.

### 5. Parse on return

When the background command completes, read the closed buffer fresh:

- Resolve any inline prose note, or an edited `Project:` / `Parent ticket:` /
  `type:` / `summary:` field, before acting — same contract `decision-buffer`
  step 3 uses.
- **All-unchecked close**: if nothing at all is checked, report that
  nothing was approved and stop. Do **not** re-fire (re-generate/re-open)
  the buffer automatically or call the MCP — the human closed it on
  purpose; ask before trying again.
- Otherwise, collect the run-level `Project:` value, the checked blocks
  (stem, resolved `type`, edited `summary`, verbatim description) and the
  resolved `Parent ticket:` value, and continue.

### 5b. Re-run the MCP preflight (KTD9)

The approval wait is unbounded and the MCP can drop during it. **Re-run the
step-2b preflight** (cloudId, accountId, tool presence) immediately before
the first `createJiraIssue` — **against the `Project:` the human approved**,
which may differ from the pre-buffer default. Re-resolve that project's
metadata and issue types, and validate every checked row's `type:` against
them (a type valid for SFB may not exist in SW). If the preflight now fails,
the project is unreachable, or a chosen type isn't valid there, stop and
report — zero tickets created, zero writes. The pre-buffer check was
advisory; this is the load-bearing one.

Also probe the link type once, if a parent will resolve (KTD5): call
`getIssueLinkTypes({ cloudId })` and confirm a usable **"Relates"**-
equivalent type exists (and note whether a nicer directional type is
available for a future upgrade). If no usable link type comes back, skip
linkage cleanly and report flat tickets rather than failing each
`createIssueLink`.

### 6. Emit — create tickets, link, write back

One sub-routine is shared by both the parent and the children — call it
**create-or-reuse(row)**:

- **Dedup first (KTD8)** — a prior run can leave a real ticket in the project
  whose task never got stamped, which the `jira:` skip would miss. Query
  candidates with `searchJiraIssuesUsingJql({ cloudId, jql: 'project = <PROJECT> AND labels = wb AND summary ~ "<summary>"' })`
  (`<PROJECT>` = the run's `Project:` — e.g. `SFB` or `SW`), but treat `~` as a
  **coarse, tokenized full-text filter, NOT an exact match** — it can match
  partial-word overlaps. Then compare each returned issue's `summary` field to
  the task's exact title string **agent-side**; only a byte-exact summary match
  counts as a hit. This prevents `~`'s fuzzy matching from reusing (and
  stamping) an unrelated ticket's URL — a silent wrong-link that `jira:`'s
  one-way verbatim semantics (KTD6) make hard to undo. If the summary contains
  a `"`, escape it in the JQL literal, or drop the `summary ~` clause and
  filter the `project = <PROJECT> AND labels = wb` candidates entirely
  agent-side.
- On a byte-exact hit, **reuse** that ticket. Otherwise **create it**:
  ```
  createJiraIssue({
    cloudId,
    projectKey: <the run's Project — e.g. "SFB" or "SW">,
    issueTypeName: <the row's type>,
    summary: <the row's summary>,
    description: <the task's ## Plan body, verbatim markdown>,
    assignee_account_id: <the resolved accountId>,
    additional_fields: { labels: ["wb"] }
  })
  ```
- **Validate the returned URL's shape** — expected Atlassian host and a
  `<PROJECT>-<n>` key matching the run's project (e.g. `SFB-1234`, `SW-42`). A
  malformed, wrong-site, or wrong-project string is refused: report it and
  leave that task's `jira:` unset (never stamp a bad URL). Returns the
  ticket's key + URL.

Order the work by parent resolution (per R8 / the plan's parent-resolution
diagram):

1. **Resolve the parent once** from the `Parent ticket:` field:
   - blank → no parent; every ticket is flat.
   - existing key/URL → the parent key is that ticket; create nothing for it,
     and it is **not** one of the batch rows.
   - batch row → if that row already carries `jira:`, resolve to its existing
     ticket URL/key (KTD10, no create). Otherwise run **create-or-reuse** on
     the coordinator row **first**, capture its key, and **write its own URL
     back** with `wb jira-set` now. The coordinator is now fully handled — it
     is **excluded from the per-child loop below** (do not dedup, create, or
     link it a second time, and never link it to itself).
2. **Then, per remaining checked row** (the children — every checked row
   except a batch-row parent already handled in step 1):
   - Run **create-or-reuse(row)**.
   - **Link, if a parent resolved (R7, KTD5):**
     `createIssueLink({ cloudId, type: "Relates", inwardIssue: <parent key>, outwardIssue: <child key> })`.
     "Relates" is symmetric, so direction is immaterial; a blank parent skips
     this entirely (flat).
   - **Write it back:** derive the task's exact `<repo>--<slug>` stem from its
     resolved file (basename minus `.md`) and call `wb jira-set <stem> <url>`
     (the one store write, R4). `wb jira-set` is idempotent-or-refuse: a
     re-run against an already-correctly-stamped task is a safe no-op; a
     *different* existing value fails loud (it never clobbers) — surface that
     as a per-ticket failure, don't fight it.

Because `createJiraIssue` (agent) and `wb jira-set` (bash) are not one
transaction (KTD2), a ticket can be created and then its stamp fail (lock
contention, a mis-derived stem). That is honest partial state — created
tickets cannot be un-created, so there is no rollback. Report it truthfully
(step 7); the Jira-side dedup (KTD8) makes a later retry safe.

### 7. Report the result

Relay, per the MCP's actual returns (never a guess):

- **Created**: each new ticket's key/URL and the task it was stamped onto.
- **Reused**: any ticket the dedup step matched instead of re-creating.
- **Linked**: which children were "Relates"-linked to which parent (or
  "flat, no parent" / "link type unavailable, flat").
- **Skipped**: the already-`jira:` tasks from step 2 (R11).
- **Failed**: any ticket that was created but not stamped, or not created —
  named explicitly, with what to do (usually: re-run the same command; the
  dedup makes it safe).

Record the `getIssueLinkTypes` finding as a note so the "Relates" choice
can be revisited for a directional link or Epic upgrade later (KTD5).
Optionally archive the approved buffer under
`~/code/tasks/dossiers/<stem>/`, mirroring `/wb-breakdown`'s durable record.

## Test scenarios this skill's behavior must cover

- **AE2 — flat single task**: one standalone task, `Parent ticket:` blank →
  one flat ticket in the run's project, no `createIssueLink`, `jira:` stamped
  via `wb jira-set`.
- **AE3 — family with coordinator parent**: `Parent ticket:` = the
  coordinator batch row → the coordinator ticket is created first, then each
  child is created and "Relates"-linked to it, each `jira:` stamped.
- **AE4 — existing parent key**: `Parent ticket:` = `SFB-1234` → children
  "Relates"-linked to `SFB-1234`, no parent ticket created.
- **Project selection (SFB / SW)**: `Project:` left `SFB` → tickets land in
  SFB with the `SFB-<n>` shape; `Project:` edited to `SW` → the re-preflight
  re-resolves SW's issue types, the dedup JQL scopes to `project = SW`,
  tickets land in SW with the `SW-<n>` shape, and a type not valid in SW is
  rejected before any create.
- **AE1 / R11 — already-ticketed skip**: a family of three where one child
  already has `jira:` → the buffer proposes two, lists the third as skipped;
  it is never double-created.
- **MCP-down preflight**: the pre-buffer (2b) or post-approval (5b) preflight
  fails → clean stop, zero tickets, zero writes.
- **Mid-run failure (KTD2)**: `createJiraIssue`/`wb jira-set` fails on ticket
  N → tickets 1..N-1 reported created+stamped, N reported failed, no
  rollback claimed.
- **Coordinator already ticketed (KTD10)**: the batch-row coordinator
  already carries `jira:` → children link to its existing URL, no second
  coordinator ticket created.
- **Retry-safe dedup (KTD8)**: a prior-run `wb`-labelled ticket with the same
  summary exists but the task was never stamped → the dedup search reuses it
  and stamps, never double-creates.
- **MCP drops during the approval wait (KTD9)**: the post-approval
  re-preflight (5b) catches it and stops before any `createJiraIssue`.
- **Malformed/wrong-site URL**: shape validation refuses the write-back,
  reports it, and leaves `jira:` unset.
- **All-unchecked close**: closing the buffer with nothing checked reports a
  clean no-op — no MCP calls, no re-open.
- **Full-description render**: the buffer shows each ticket's entire `## Plan`
  body, not a truncated preview.

Plus one repo-level check enforced by `tests/wb-jira-set.test.sh` itself (not
something this skill can self-test): a grep assertion that this SKILL.md
contains no Edit/Write-tool instruction targeting `~/code/tasks`, references
`wb jira-set`, states the never-Edit/Write-tool rule, and names no
ticket-update/transition tool — so the only store write is `wb jira-set` and
Jira access stays create-only.

## Notes

- This skill never modifies `scripts/.config/scripts/tmux/wb.sh` — the one
  store-write primitive it relies on (`wb jira-set`) is already built there.
  If something here seems to need a `wb.sh` change, that's a follow-up for
  the task file, not something to patch around in this skill.
- `~/code/tasks/README.md` documents the `jira:` frontmatter field
  (verbatim, one-way, never re-derived) this skill stamps via `wb jira-set`.
- The reverse direction — pulling the user's current-sprint SFB tickets into
  wb tasks — is Phase 2 (a separate `wb-jira-pull` companion that reuses
  `/wb-breakdown`'s ticket→task path); it is not part of this skill.
- A real Epic hierarchy (parent → Epic + epic-linked children) and the
  native `parent` field are a deferred upgrade; the single `Parent ticket:`
  field is forward-compatible and can later drive an epic-link with no
  buffer change.
