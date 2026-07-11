---
title: "wb board: lifecycle-stage pipeline view - Plan"
type: feat
date: 2026-07-11
origin: ~/code/tasks/dotfiles--feat-wb-board-lifecycle.md (central task store, separate repo)
product_contract_source: ce-plan-bootstrap
artifact_contract: ce-unified-plan/v1
artifact_readiness: implementation-ready
execution: code
---

# wb board: lifecycle-stage pipeline view

## HARD GATE — CLEARED (2026-07-11)

`feat/wb-done-close` merged to `development` as PR #19
(`feat(wb): add opt-in --close to wb done, guard against self-kill`,
commit `74e219a`) while this plan was in its post-write decision round.
This worktree has been fast-forwarded onto that commit
(`git merge --ff-only origin/development` — safe: this worktree had no
local commits of its own and no changes to `wb.sh`, so the update pulled
in cleanly with zero conflicts). All `wb.sh` line-number citations in this
plan have been re-verified and updated against the post-merge file
(only citations inside/after `cmd_done` shifted, since PR #19 added ~19
lines there; everything this plan actually touches —
`wb_board_live_session_for`, `wb_board_pr_info`, `wb_board_related_docs`,
`wb_board_render_html`, `cmd_pause` — sits earlier in the file and is
unaffected).

**`/ce-work` can start once the decision buffer's remaining open items are
resolved** (see `logs/decisions/2026-07-11-wb-board-lifecycle-scoping.md`)
— there is no longer a merge-conflict reason to wait.

## Implementation status (2026-07-11, mid-scoping-round)

The 7 detection functions (U1-U3) are settled and decoupled from *how*
they get displayed — implementation on those is proceeding now, in
parallel with an open, live redesign of the display layer (originally
Decision 3/4 in the scoping buffer, now a broader conversation: badges
turned out to possibly be the wrong model — see below). Split:

**Proceeding now** (implementation dispatched separately from this
planning thread): U1 (cheap-signal detections), U2 (`/ce-work` done), U3
(`/ce-code-review` done + `reviewed:` schema field), U5's test coverage
for U1-U3 only, and U6's `logs/decisions/` detection-rationale entry
(documents the heuristics themselves, not their display).

**Paused — depends on the display redesign below, do not implement yet:**
U4 (board render wiring — the whole premise of "7 badges" is under
reconsideration), U5's `wb-board-html.test.sh` extension (asserts against
whatever the final display shape turns out to be), and U6's
`docs/roadmap-board.md`/`docs/wb-guide.md` user-facing sections (they
describe the feature to end users, so they need the final shape first).

**What's actually being reconsidered:** the original framing (7
independent on/off badges) surfaced two problems once mocked up
concretely: (1) a `done` task's badges read confusingly similar to a
brand-new task's (both mostly "off") — the immediate trigger; (2) more
fundamentally, on/off badges answer "did X happen" but not "what did we
*intend* to do here, and where are we in that" — which is the actually
useful question (e.g., knowing a brainstorm ran is only informative
relative to whether this task's own path was supposed to include one). A
possible 8th signal surfaced in this discussion: `/ce-ideate` done
(detectable the same way as plan/brainstorm — this repo already has
`docs/ideation/` as a real, precedented path per `feat/hub-v0`'s task
file and this plan's own U2 exclusion list). Also surfaced: task files
already often declare an intended path in their own opening prose (e.g.,
`feat/queue-command`'s "Do NOT jump to `/ce-plan` or `/ce-work`") — a
possible source for "what was this task's plan" without inventing a new
frontmatter field. None of this is resolved yet; it grew large enough (display redesign +
task-relationship visualization, both wanted) to warrant its own task
rather than staying inside this one: **`dotfiles--feat-wb-board-display`**
(`~/code/tasks/dotfiles--feat-wb-board-display.md`, worktree
`.worktrees/feat/wb-board-display`) now owns U4 and the display-dependent
parts of U5/U6 listed above, plus the new task-relationship-visualization
scope. This plan and task stay scoped to the 7 detection functions
(U1-U3) and their decoupled test/doc coverage only.

---

## Product Contract

### Summary

Add a lifecycle-stage pipeline — 7 independent yes/no signals (worktree,
live agent, `/ce-plan`, `/ce-brainstorm`, `/ce-work` done, `/ce-code-review`
done, live PR) — to each task's detail card on `wb board --html`, as a
dimension orthogonal to the board's existing 6 status tabs. Five signals
reuse detection code that already exists in `wb.sh`; two (`/ce-work` done,
`/ce-code-review` done) have no durable marker today, and this plan
resolves both with a researched heuristic grounded in how those skills
actually behave, validated against the four lanes currently open in this
repo (`feat/hub-v0`, `feat/handoff-v1`, `feat/wb-done-close`,
`feat/queue-command`).

### Problem Frame

`wb board`'s 6 status tabs (`doing`/`review`/`paused`/`planned`/`done`/
`unclassified`, `wb.sh:926-934`) answer "what bucket is this task in" but
say nothing about *how far along* a `doing` task actually is. Right now
`feat/hub-v0`, `feat/handoff-v1`, `feat/wb-done-close`, and
`feat/wb-board-lifecycle` (this task) are all `status: doing`, but sit at
four completely different points in the plan -> build -> review -> ship
sequence — one has a plan and an open PR, another is mid-implementation
with nothing committed yet, another has only a plan. (`feat/queue-command`
— the fourth lane used for the compound-heuristic validation below —
is `status: doing` too, but at the time of this research it hadn't
started its own `/ce-brainstorm` yet: a fifth, less-far-along data point,
not a contradiction of the four named here.) Of the 7 signals this plan
adds, live-agent and live-PR already have *some* visibility today (the
picker's session badge, this board's existing PR chip); worktree presence
is visible via `wb reconcile`. The genuinely new information is the
plan/brainstorm/work/review signals — this plan's contribution is putting
all 7 in one scannable place, not inventing 7 facts from nothing.

Two of the seven signals have no existing durable marker to detect from:
`/ce-work` and `/ce-code-review` are both external compound-engineering
skills this repo doesn't own, and neither stamps a task-file field or
writes a durable artifact when it finishes (confirmed by reading both
skills' `SKILL.md` — see Key Technical Decisions below). Resolving *how*
to detect those two, without modifying the external skills, is the main
design work this plan does.

### Requirements

- R1. `wb board --html`'s per-task detail card shows all 7 lifecycle
  signals as independent, non-sequential badges for every non-`done`-
  bucket task (a task can have a brainstorm and no plan, or a plan and no
  brainstorm — see KTD "Stages are independent booleans, not a progress
  bar"; `done`-bucket tasks are excluded — see Scope Boundaries).
- R2. Worktree, live agent, and live PR call existing detection functions
  directly (`cmd_reconcile`'s check, `wb_board_live_session_for`/
  `tmux_claude_panes`, `wb_board_pr_info`). `/ce-plan` and `/ce-brainstorm`
  presence reuse the existing scan *pattern* (`wb_board_related_docs`),
  re-rooted and combined with a new glob check — see Key Technical
  Decisions for why a straight function call isn't sufficient there.
- R3. `/ce-work` done and `/ce-code-review` done each get one durable,
  justified detection heuristic (this plan picks and defends one per
  signal — see Key Technical Decisions).
- R4. No new network call is added to the interactive picker's hot path
  (`picker()`, `wb.sh:2100+`). `wb board --html` is a separate,
  deliberately-invoked generator, not the picker — it already makes a
  `gh`/`pgh` call per row for the existing PR-info chip, and this plan's
  live-PR signal must reuse that already-computed value rather than add
  a second network call.
- R5. ~~This plan's implementation is gated behind `feat/wb-done-close`
  merging to `development`~~ — cleared 2026-07-11 (see HARD GATE above).

### Scope Boundaries

- The plain-text `wb board` (no `--html`) table is unchanged — lifecycle
  badges are an `--html`-only feature, matching the existing precedent
  that live-session badges, PR-info chips, and doc chips are already
  HTML-only.
- No change to the picker (`picker()`), `cmd_reconcile`, or any of the
  parent/child rollup logic beyond what's needed to read a task's own
  detail-card fields.
- No change to the external `ce-work` or `ce-code-review` skills
  themselves — detection works entirely from artifacts those skills
  already leave behind (git state, the filesystem, task frontmatter this
  repo owns), never by asking those skills to change their behavior.
- **Lifecycle badges render only for non-`done`-bucket tasks** (`doing`,
  `review`, `paused`, `planned`, `unclassified`) — never for the `done`
  bucket. This is a deliberate scope cut, not an oversight: a task that
  reaches `done` has had its worktree removed by `wb done` (`wb.sh:1591-
  1593`), so "worktree exists" and "live PR" (once merged/closed) would
  otherwise render `off` for a *finished* task in exactly the same visual
  state as a brand-new, unplanned one — undermining the feature's own
  point of showing how far along something is. Since the pipeline exists
  specifically to show progress on work still in flight, skipping `done`
  sidesteps the ambiguity at its root rather than inventing a third visual
  state. The underlying detection functions still guard against a missing
  worktree defensively (see `/ce-work` done KTD) in case a `review`- or
  `paused`-bucket task's worktree is ever removed by some other path.
- **The `/ce-plan`/`/ce-brainstorm` compound heuristic is validated only
  against `dotfiles`-convention tasks** (`docs/plans/`/`docs/brainstorms/`
  at the worktree root, task-file prose citing them under `## Decisions`).
  The central task store also carries tasks for other repos
  (`be--monorepo`, `frontend`, etc.) that may not share this convention;
  for those, the heuristic may under-report `/ce-plan`/`/ce-brainstorm`
  presence until validated against a non-`dotfiles` example. Not blocking
  for this plan (every currently-open task in the store happens to be a
  `dotfiles` task, and the failure mode is a clean "false," never a
  crash), but flagged as a follow-up: revisit at the next natural
  checkpoint where this signal is actually exercised against a
  non-`dotfiles` task (see `~/code/tasks/dotfiles--feat-wb-board-
  lifecycle.md`'s `## Follow-ups`), rather than left as a silent gap.

#### Deferred to Follow-Up Work

- **`wb_board_related_docs`'s existing cross-worktree blind spot.** While
  researching the `/ce-plan`/`/ce-brainstorm` signals, direct testing
  showed the *existing*, already-shipped "Docs:" chip feature
  (`wb_board_related_docs`, `wb.sh:1105-1129`) scans `$dotfiles_root` (the
  main checkout wb.sh actually runs from, confirmed via `which wb` ->
  `~/.config/scripts/tmux/wb.sh`, symlinked to the main checkout on
  `development`) — not the task's own worktree. A plan doc committed only
  inside `feat/wb-done-close`'s worktree (confirmed: present in that
  worktree, absent from the main checkout) is invisible to that function
  today. This plan's own new detection avoids the bug (see KTD below), but
  does not fix the existing "Docs:" chip — that's a separate, already-
  shipped feature and fixing it isn't part of this task's remit. Flagging
  it here so it doesn't get lost.
- Extending lifecycle badges to the plain-text `cmd_board` table.
- A manual-override UI for a wrong detection (e.g., un-stamping a
  mistaken `reviewed:` field) — hand-editing the task file's frontmatter
  is the existing escape hatch for every other field and stays that way.
- Surfacing GitHub-native PR review state (approved / changes-requested)
  as a signal. That's conceptually different from "has `/ce-code-review`
  been run" (a local, no-push tool) — conflating the two would misreport
  a locally-reviewed-but-not-yet-pushed task as unreviewed, or a pushed-
  but-locally-unreviewed PR as reviewed.

---

## Planning Contract

### Key Technical Decisions

- **Detection logic lives in a new sourced module, not inline in
  `cmd_board`.** `wb.sh` already sources `lib.sh` for shared helpers
  (`wb.sh:28`). This plan adds a sibling `wb-lifecycle.sh`, sourced the
  same way, holding all 7 detection functions plus the badge-HTML
  renderer. `wb.sh`'s own diff shrinks to one `source` line, the
  per-row call inside `wb_board_render_html`'s loop, and CSS —
  minimizing the footprint in a file `feat/wb-done-close` is actively
  editing, and following the file's own established pattern for
  indirection points that need independent testing (`wb_reconcile_repos`,
  `wb_repo_dir`).

- **Stages are independent booleans, not a progress bar.** The task
  file's stage list (worktree -> agent -> plan -> brainstorm -> work ->
  review -> PR) reads like a sequence, but real tasks in this repo don't
  follow it monotonically: `feat/queue-command`'s task file requires
  `/ce-brainstorm` *before* any `/ce-plan` and explicitly forbids planning
  first; `feat/hub-v0`, `feat/wb-done-close`, `feat/handoff-v1`, and this
  task all went straight to `/ce-plan` with no brainstorm at all. A
  strict left-to-right progress bar would render `feat/queue-command` as
  "stuck" at stage 3 forever once it gets a brainstorm (stage 4) without
  a plan (stage 3), which misrepresents a perfectly normal path. Render
  all 7 as independently lit/unlit badges (reusing the existing
  disconnected `.pill`/`.artefact-chip` visual language, not a connected
  stepper component), each computed on its own.
  - **Render order is fixed left-to-right (worktree, agent, plan,
    brainstorm, work, review, PR) purely for scan consistency across
    tasks — it carries no sequence meaning**, and the disconnected-badge
    shape alone doesn't make that obvious to a reader (the same order the
    task file and this plan enumerate signals in happens to put `/ce-plan`
    before `/ce-brainstorm`, which is backwards for the one validated
    brainstorm-first lane). U4's badge renderer should give the badge row
    a `title`/tooltip or brief inline label (e.g. a small "independent
    signals" caption) making the non-sequential framing explicit, not
    just rely on CSS shape.

  **Badge labels** (rendered text inside each of the 7 badges, left to
  right): `Worktree`, `Agent`, `Plan`, `Brainstorm`, `Work`, `Review`,
  `PR` — plain words, no abbreviation, matching the terse style
  `TAB_LABEL` already uses for the 6 status tabs (`wb.sh:1195`).

- **`/ce-plan` and `/ce-brainstorm` presence: scan the task's own worktree
  filesystem, OR-ed with a task-file prose reference — never the
  board-generating repo's fixed root.** Two independent, cheap, filesystem-
  only signals, because neither alone is reliable in practice (validated
  against all 4 open lanes' actual current state):
  - **Glob match** — does any `docs/plans/*.md`/`.html` file inside
    `$(wb_repo_dir "$repo")/$worktree/docs/plans/` contain the task's
    sanitized branch (`wb_sanitize "$branch"`, e.g. `feat-wb-done-close`)
    as a substring of its filename? True for `feat/wb-done-close`
    (`2026-07-11-001-feat-wb-done-close-plan.md`), `feat/hub-v0`
    (`...-feat-hub-v0-meta-documentation-plan.md`), and `feat/handoff-v1`
    (`...-feat-handoff-v1-plan.md`) — 3/3 observed cases. Known failure
    mode: a plan whose descriptive name doesn't echo the branch words.
  - **Prose-reference match** — same conservative scan
    `wb_board_related_docs` already does (grep the task file's own prose
    for a `docs/plans/...` path), but rooted at the task's own worktree
    path instead of `$dotfiles_root` (see the deferred-bug note above).
    True for `feat/hub-v0` (whose task file's `## Decisions` section names
    its plan explicitly) but **false** for `feat/wb-done-close` and
    `feat/handoff-v1` — neither task file's `## Decisions` section had
    been updated to cite its own (just-written) plan doc yet at the time
    of this research. 1/3 observed cases alone.
  - Combining both (OR) catches all 3 observed cases; either alone misses
    at least one. Same construction for `/ce-brainstorm`, against
    `docs/brainstorms/`.
  - This is why the check must run against `$(wb_repo_dir "$repo")/
    $worktree`, not `$dotfiles_root`: `feat/wb-done-close`'s plan doc is
    physically absent from the main checkout (confirmed:
    `ls ~/code/dotfiles/docs/plans/` doesn't have it) since it's
    uncommitted-to-`development`. Scanning the fixed root would report
    zero plans for every currently-open, unmerged lane — exactly the
    tasks this feature exists to give visibility into.
  - **Alternative considered and rejected: reuse U2's merge-base-diff
    scoping instead of filename matching.** U2 (`/ce-work` done) already
    computes "files touched beyond merge-base, plus uncommitted changes"
    for a different purpose; that same mechanism would catch a new
    `docs/plans/` file regardless of its filename, sidestepping the
    glob's branch-name-echo dependency entirely. Not adopted here because
    it trades one dependency for another rather than removing it: the
    diff-based check still needs the same worktree-existence guard as
    U2 (see that KTD) for its uncommitted-changes half, and it would still
    need the glob step for `has_plan` results that are outside the
    detected diff (a plan doc merged from a prior branch and just being
    referenced, not authored, on this one). The glob+prose combination is
    simpler — no git dependency at all for these two signals — and is
    already validated against 3/3 observed cases. Revisit if the filename-
    echo assumption is later observed to fail in practice.

- **`/ce-work` done: git state in the task's own worktree, not a skill
  marker.** Reading `ce-work`'s own `SKILL.md` (`references` aside, the
  top-level file) confirms it deliberately never stamps a task-file field
  or edits the plan doc to record progress — "the plan is a decision
  artifact; progress lives in git commits... `ce-work` does not mutate
  the plan." Asking the skill to change that would mean patching an
  external plugin skill, working against its own stated design, for a
  detection this repo can compute itself. Heuristic: **any commit beyond
  the merge-base with the default branch, OR any uncommitted change
  (`git status --porcelain`), that touches a path outside
  `docs/plans/`, `docs/brainstorms/`, `docs/ideation/`, `logs/decisions/`**
  (the planning-artifact paths) counts as "work done." Broader than the
  task file's original "commits beyond the plan-doc commit" candidate —
  that phrasing assumes every task has a plan doc to anchor against and
  assumes the change is committed. Neither holds in practice:
  `feat/handoff-v1`'s worktree right now has its plan doc *and* several
  implementation-adjacent edits (`claude/README.md`,
  `docs/roadmap-handoff.md`, a new `claude/.claude/settings.recommended.json`)
  entirely uncommitted — a commit-only heuristic would report "no work
  yet" on a lane that's actively mid-implementation. Default branch is
  resolved via `git symbolic-ref refs/remotes/origin/HEAD`, falling back
  to whatever branch the repo's main (non-worktree) checkout currently
  has checked out — this tool's own convention keeps that checkout on the
  default branch.
  - **Must not assume the worktree still exists.** `wb done` permanently
    removes a task's worktree on successful wind-down while keeping its
    branch (`git worktree remove ... --force`, `wb.sh:1591-1593`, "Branch
    is kept" per that function's own comment) — a `done`-bucket task is
    the guaranteed, common case of this, not a rare edge. `wb.sh` runs
    under `set -euo pipefail` (`wb.sh:23`), so an unguarded git command
    against a missing worktree path would abort the entire `wb board
    --html` generation, not just skip one badge. Split the heuristic:
    the "commits beyond merge-base" half runs against `$repo_dir` using
    the branch *name* directly (`git -C "$repo_dir" merge-base
    "$branch" "$default_branch"`, `git -C "$repo_dir" diff --name-only`)
    — this needs no live worktree, since committed refs persist after
    `worktree remove`. The "uncommitted changes" half (`git status
    --porcelain`) is skipped (vacuously false — there is no working tree
    to be dirty) whenever `$(wb_repo_dir "$repo")/$worktree` doesn't
    exist, mirroring the `is_dir` guard `has_plan`/`has_brainstorm`
    already use. (Per the Scope Boundaries cut above, `done`-bucket tasks
    never actually reach this function in the shipped UI — this guard is
    defense-in-depth for `review`/`paused` tasks whose worktree could in
    principle be removed by some other path.)
  - Deliberate limitation: this reports "work started/exists," not
    "work is 100% finished with nothing further coming" — there is no
    way to distinguish those without a marker the skill itself would need
    to write, which this plan avoids for the reason above. Documented
    here so a future reader doesn't mistake it for a stronger guarantee.
  - Deliberate limitation: a task whose *actual deliverable* is content
    inside one of the four excluded paths (e.g., a task scoped to writing
    a `logs/decisions/` entry, or editing `TEMPLATE.md`'s own schema)
    reports `work_done=false` even once genuinely complete, since the
    heuristic can't distinguish "planning scaffolding to ignore" from
    "the real output happens to live here." This plan's own U6 is exactly
    such a case (its only file changes are `docs/roadmap-board.md` and a
    new `logs/decisions/` entry). Rare in practice — most tasks in this
    store are code changes — but real; see U2's test scenarios for the
    explicit case.

- **`/ce-code-review` done: a new task-file frontmatter field
  (`reviewed:`), stamped by a new `wb reviewed` subcommand.** Reading
  `ce-code-review`'s `SKILL.md` confirms its artifacts are written to
  `/tmp/compound-engineering/ce-code-review/<run-id>/` — an ephemeral
  temp path, not a repo artifact — and in `mode:agent` (or any review that
  finds nothing to fix) it may touch **zero** files, leaving no git trace
  at all. Unlike `/ce-work`, there is no git-observable signal for "a
  review happened," so of the task file's three candidates (a
  `logs/decisions/` artifact, a task-file field, a skill marker), only
  the task-file field is buildable without modifying the external skill.
  New subcommand `wb reviewed [<session>]` mirrors `cmd_pause`'s shape
  exactly (resolve the current session via tmux if no arg, look up its
  `@wb_repo`/`@wb_slug`, resolve the task file, `wb_set_frontmatter "$file"
  reviewed "$(date +%F)"`). Detection is `[ -n "$(wb_get_frontmatter
  "$taskfile" reviewed)" ]`.
  - Deliberate limitation, stated plainly: this requires a habit — running
    `wb reviewed` after a review pass — same trade-off `wb pause` already
    accepts for `status: paused`. If it's never run, the badge just stays
    unlit, which is the honest default (no review recorded) rather than a
    guess.
  - Deliberate limitation: no staleness invalidation. Once stamped, a task
    that receives further commits still shows `review done` even though
    the newest code was never reviewed — the field records "a review
    happened at some point," not "the current HEAD was reviewed." Fixing
    this (e.g., comparing the commit SHA at stamp-time against current
    HEAD, graying the badge out on drift) is real follow-up work, deferred
    rather than folded in here to keep U3 to the same scope as `cmd_pause`'s
    existing one-shot stamp.
  - Cross-repo note: the new `reviewed:` field is added to the central
    task store's schema (`~/code/tasks/TEMPLATE.md`, and `wb_seed_task`'s
    blank-field-fill logic in `wb.sh`) — the task store is a **separate
    repo** (`git@github.com:jetnoli-sportable/tasks.git`) from `dotfiles`.
    U3 below touches both repos explicitly.

- **Live PR: reuse the already-computed `$pr_info` value, add no new
  network call.** `wb_board_render_html` already calls `wb_board_pr_info`
  once per task row with a git repo (`wb.sh:1264`) to build the existing
  "Related: PR" chip — this is already-accepted, already-shipped
  synchronous-per-render behavior, and it already lives outside the
  picker's hot path (`wb board --html` is a deliberately-invoked
  generator command, never called from `picker()`). The lifecycle badge
  parses the state out of that same string (`"#18 (OPEN)"` -> `OPEN`)
  instead of issuing a second `gh`/`pgh` call. Only `OPEN` counts as
  "live" — a `CLOSED` or `MERGED` PR means the task has moved past this
  stage entirely (into `status: done` territory), not that it's
  currently sitting at the PR stage. This resolves the "keep the PR
  check out of the hot path / cache or opt-in it" question from the
  original task file: there is no *new* network cost to gate, because
  there is no new call.

- **Live agent: a real `claude` pane, not just session existence.**
  `wb_board_live_session_for` (already exists, `wb.sh:943-954`) confirms
  a tmux session matching this task's `@wb_repo`/`@wb_slug` exists, but a
  session can exist with only an `nvim`/shell window and no agent
  actually running. The lifecycle signal additionally calls
  `tmux_claude_panes "$session"` (`lib.sh:99`, already accepts an optional
  session scope) and treats any returned row as "live agent" — reusing
  the exact detection `claude-sessions.sh` already relies on, scoped to
  this task's session.

### Sequencing

U1 (cheap signals + module scaffold) has no dependency. U2 (`/ce-work`
done) and U3 (`/ce-code-review` done + schema field) can proceed in
parallel with each other once U1's module exists, since neither depends
on the other's detection function. U4 (render wiring) depends on U1-U3
all being present. U5 (tests) depends on U1-U4. U6 (docs) depends on
everything.

---

## High-Level Technical Design

**Stage-detection matrix** — source, cost, and reuse for each of the 7
signals:

| # | Stage | Source | Network? | Reuses existing code |
|---|-------|--------|----------|----------------------|
| 1 | Worktree exists | filesystem (`[ -d ... ]`) | no | `cmd_reconcile`'s presence-diff check |
| 2 | Live agent | tmux | no | `wb_board_live_session_for` + `tmux_claude_panes` |
| 3 | Has `/ce-plan` | filesystem glob OR task-file prose scan, rooted at the task's own worktree | no | pattern only (new root scoping) |
| 4 | Has `/ce-brainstorm` | same as #3, against `docs/brainstorms/` | no | pattern only |
| 5 | `/ce-work` done | git merge-base diff (against `$repo_dir`, no worktree needed) + git status (needs a live worktree, guarded), scoped to non-planning paths | no | none (new) |
| 6 | `/ce-code-review` done | task-file frontmatter (`reviewed:`) | no | `wb_get_frontmatter`/`wb_set_frontmatter`, `cmd_pause`'s stamp pattern |
| 7 | Live PR | reuses `$pr_info` already computed for the existing PR chip | reused, not new | `wb_board_pr_info` |

**Compound heuristic for signals 3/4** (the only genuinely non-obvious
piece — both independent checks are cheap, so evaluate both rather than
short-circuiting):

```
has_plan(repo, worktree_rel, taskfile):
    wt = repo_dir(repo) / worktree_rel
    if not is_dir(wt): return false
    frag = sanitize(branch_of(taskfile))            # "feat-wb-done-close"
    glob_hit  = any file in wt/docs/plans/*.md|*.html
                whose basename contains frag
    prose_hit = wb_board_related_docs(taskfile, root=wt)
                any result under docs/plans/
    return glob_hit or prose_hit
```

**Render composition point** — inside `wb_board_render_html`'s existing
per-row loop (`wb.sh:1231+`), right after `live_badge` is computed
(`wb.sh:1246-1248`) and before `detail_extra` is assembled: call the new
`wb_lifecycle_badges_html` with the row's already-in-scope `repo`,
`branch`, `worktree`, `taskfile`, and `pr_info`. `pr_info` itself is
computed later today (`wb.sh:1264`), so U4 moves that one line earlier,
ahead of the badges call, with no behavior change to the existing PR
chip. Append the badges output into `detail_extra` — the same place
`wb_board_summary_line`, the Plan/Done excerpt, and the PR chip already
get appended today.

---

## Output Structure

```
dotfiles/
  scripts/.config/scripts/tmux/
    wb-lifecycle.sh                 (new — 7 detection fns + badge renderer)
    wb.sh                           (modified — source line, render wiring,
                                      new `wb reviewed` subcommand, CSS)
    tests/
      wb-lifecycle.test.sh          (new)
      wb-board-html.test.sh         (modified — badge assertions)

tasks (separate repo, git@github.com:jetnoli-sportable/tasks.git)/
  TEMPLATE.md                       (modified — add `reviewed:` field)

dotfiles/ (continued)
  docs/
    roadmap-board.md                 (modified — lifecycle pipeline subsection)
    wb-guide.md                      (modified — wb board + wb reviewed section)
  logs/decisions/
    2026-07-11-wb-board-lifecycle-detection.md (new)
```

---

## Implementation Units

### U1. Cheap-signal detections + module scaffold

**Goal:** create `wb-lifecycle.sh`, sourced by `wb.sh`, holding the 5
signals with existing detection precedent: worktree, live agent,
`/ce-plan`, `/ce-brainstorm`, live PR.

**Requirements:** R1 (partial — 5 of 7 signals), R2, R4 (live-PR reuse).

**Dependencies:** none.

**Files:**
- `scripts/.config/scripts/tmux/wb-lifecycle.sh` (new)
- `scripts/.config/scripts/tmux/wb.sh` (add one `source` line near
  `wb.sh:28`)

**Approach:** `wb_lifecycle_has_worktree`, `wb_lifecycle_has_live_agent`,
`wb_lifecycle_has_plan`, `wb_lifecycle_has_brainstorm`,
`wb_lifecycle_pr_is_live` per the Key Technical Decisions and the
compound-heuristic pseudo-code above. Each takes plain repo/branch/
worktree/taskfile values already available in `wb_board_render_html`'s
loop — no new global state. `wb_lifecycle_has_plan`/
`wb_lifecycle_has_brainstorm` take a `kind` parameter (`plans` |
`brainstorms`) rather than duplicating the function body, since the only
difference is the subdirectory name.

**Patterns to follow:** `wb_reconcile_repos`/`wb_repo_dir`'s
indirection-point convention (so tests can stub the repo-directory
lookup); `wb_board_related_docs`'s conservative grep-and-verify-exists
scan (reused, re-rooted).

**Test scenarios:**
- Happy path: worktree directory exists -> true; removed -> false.
- Happy path: a `claude` pane running in the task's session ->
  live-agent true; session exists but only `nvim`/shell panes -> false;
  no session at all -> false.
- Happy path: a `docs/plans/*<branch-frag>*.md` file present in the
  task's own worktree -> plan true, even when absent from
  `$dotfiles_root` (regression guard for the deferred-bug scenario).
- Happy path: task file's prose names a `docs/plans/...` path that
  exists under the worktree -> plan true, even with no filename-substring
  match.
- Edge case: neither glob nor prose match -> false.
- Edge case: `docs/plans/` directory doesn't exist in the worktree at all
  -> false, no error.
- Happy path: `$pr_info` state `OPEN` -> live-PR true; `CLOSED`/`MERGED`
  -> false; empty `$pr_info` -> false.

**Verification:** `bash scripts/.config/scripts/tmux/tests/wb-lifecycle.test.sh`
(added in U5) covers all functions added here; run standalone during this
unit for a fast inner loop.

---

### U2. `/ce-work` done detection

**Goal:** implement the git-state compound heuristic for "implementation
has happened."

**Requirements:** R3 (work-done half).

**Dependencies:** U1 (module file must exist).

**Files:**
- `scripts/.config/scripts/tmux/wb-lifecycle.sh`

**Approach:** `wb_lifecycle_work_done(repo, worktree_rel, branch)` per
the Key Technical Decision above, split into two independently-guarded
halves:
1. **Committed-changes half** (works with or without a live worktree):
   resolve the default branch (`git symbolic-ref refs/remotes/origin/HEAD`,
   falling back to the repo's main checkout's current branch), then
   `git -C "$repo_dir" merge-base "$branch" "$default_branch"` and
   `git -C "$repo_dir" diff --name-only "$merge_base..$branch"` — both
   run against `$repo_dir` (the main checkout) using the branch name, not
   a worktree path, since committed refs survive `wb done`'s `worktree
   remove` (`wb.sh:1591-1593`).
2. **Uncommitted-changes half** (needs a live worktree): `[ -d
   "$(wb_repo_dir "$repo")/$worktree_rel" ]` guards `git status
   --porcelain` run against that path; skip this half (vacuously false)
   when the directory doesn't exist.

True if either half finds a touched path outside `docs/plans/`,
`docs/brainstorms/`, `docs/ideation/`, `logs/decisions/`.

**Patterns to follow:** `wb_pr_merge_status`'s "never silently drop a
finding, report a safe default on any git-command failure" convention;
`has_plan`/`has_brainstorm`'s `is_dir` guard (U1) for the same
missing-worktree hazard.

**Test scenarios:**
- Happy path: a fixture branch with one committed non-planning-path
  change beyond its merge-base -> true.
- Happy path: a fixture branch with only an uncommitted (unstaged or
  untracked) non-planning-path change, zero commits beyond merge-base ->
  true (the `feat/handoff-v1` regression case).
- Happy path: a fixture branch whose worktree has been removed (`git
  worktree remove`) but whose branch still carries a committed
  non-planning-path change beyond merge-base -> true, no error (the
  `done`-bucket regression this unit exists to prevent crashing on).
- Edge case: a fixture branch with commits/changes touching only
  `docs/plans/`/`docs/brainstorms/`/`docs/ideation/`/`logs/decisions/`
  paths -> false, even when that content is the task's actual deliverable
  (documented limitation, not a bug to fix here — see the KTD).
- Edge case: a fixture branch with zero commits beyond merge-base and a
  clean working tree -> false.
- Edge case: a fixture branch whose worktree is gone AND has zero commits
  beyond merge-base -> false, no error (distinguishes "nothing happened"
  from "worktree removed after real work").
- Edge case: no resolvable default branch (no `origin/HEAD` symbolic ref
  and main checkout detached) -> false, no error (documented safe
  default, not a hard failure).

**Verification:** `bash scripts/.config/scripts/tmux/tests/wb-lifecycle.test.sh`.

---

### U3. `/ce-code-review` done detection + `reviewed:` schema field

**Goal:** add the `reviewed:` frontmatter field to the task-store schema,
a `wb reviewed` subcommand to stamp it, and the detection read.

**Requirements:** R3 (review-done half).

**Dependencies:** U1 (module file must exist).

**Target repos:** this unit touches **two** repos — `dotfiles`
(detection function, new subcommand, dispatch wiring, usage banner) and
the separate central task store (`TEMPLATE.md`'s frontmatter schema).
Paths below are repo-relative to `dotfiles` unless prefixed
`tasks-repo:`.

**Files:**
- `scripts/.config/scripts/tmux/wb-lifecycle.sh` (`wb_lifecycle_review_done`)
- `scripts/.config/scripts/tmux/wb.sh` (new `cmd_reviewed`, top-level
  dispatch case, top-of-file usage banner line, `wb_seed_task` blank-field
  fill for the new key)
- `tasks-repo:TEMPLATE.md` (add `reviewed:` to the frontmatter block)

**Approach:** `cmd_reviewed` mirrors `cmd_pause` exactly (`wb.sh:805-824`):
resolve session from arg or current tmux session, read `@wb_repo`/
`@wb_slug`, resolve the task file, `wb_set_frontmatter "$file" reviewed
"$(date +%F)"`, echo confirmation. `wb_lifecycle_review_done(taskfile)` is
`[ -n "$(wb_get_frontmatter "$taskfile" reviewed)" ]`.

**Cross-repo commit step (not part of `ce-work`'s dotfiles-checkout
commits):** the `TEMPLATE.md` schema edit is a separate, one-time change
made and committed directly in a local checkout of the `tasks` repo
(`~/code/tasks`, not this worktree) — `cd ~/code/tasks`, edit
`TEMPLATE.md`, commit, and push via `pgh` (the tasks repo is under the
personal `jetnoli-sportable` owner, per this user's established `gh`-
can't-see-personal-repos / `pgh`-fallback convention). This does not run
inside the `wb-tests` Dockerfile sandbox (which has no `~/code` at all by
design) and is not exercised by any `*.test.sh` file — it is a manual step
performed once, verified by inspection (`grep -q '^reviewed:'
~/code/tasks/TEMPLATE.md`), not by an automated test.

**Patterns to follow:** `cmd_pause`'s exact structure and error messages;
`wb_seed_task`'s "never overwrite an already-set field" rule extended to
the new key (not applicable here since `reviewed` starts unset and is
only ever set by `cmd_reviewed`, never by `wb_seed_task` itself).

**Test scenarios:**
- Happy path: `wb reviewed SESSION` against a fixture task with no
  `reviewed:` field -> field set to today's date, confirmation echoed.
- Happy path: `wb_lifecycle_review_done` on a task file with a
  `reviewed:` value -> true; without one -> false.
- Edge case: `wb reviewed` with no session arg, run outside any `wb`
  session (`$TMUX` unset or no `@wb_repo`/`@wb_slug`) -> fails loudly,
  same message shape as `cmd_pause`'s equivalent guard.
- Regression: existing `wb_seed_task` blank-field behavior for
  `repo`/`branch`/`worktree`/`status` is unaffected by the new key.

**Verification:** `bash scripts/.config/scripts/tmux/tests/wb-lifecycle.test.sh`
plus a `wb-schema.test.sh` regression run (confirms the new frontmatter
key doesn't break existing source-text assertions there) for the
`dotfiles`-side change. The `tasks`-repo schema edit is verified
separately and manually: `grep -q '^reviewed:' ~/code/tasks/TEMPLATE.md`
after the commit lands there.

---

### U4. Board render wiring

**Goal:** call all 7 detection functions per task row inside
`wb_board_render_html` and render the badge block into each detail card.

**Requirements:** R1, R4.

**Dependencies:** U1, U2, U3.

**Files:**
- `scripts/.config/scripts/tmux/wb-lifecycle.sh` (`wb_lifecycle_badges_html`)
- `scripts/.config/scripts/tmux/wb.sh` (`wb_board_render_html`'s per-row
  loop, the `<style>` block)

**Approach:** immediately after `live_badge` is computed
(`wb.sh:1246-1248`), call the 7 detection functions with values already
in scope (`repo`, `branch`, `worktree`, `taskfile`, `pr_info` — note
`pr_info` itself is computed a few lines later at `wb.sh:1264` today, so
this unit reorders that one line earlier, before the badges call, with
no behavior change to the existing PR chip). Pass the 7 booleans to
`wb_lifecycle_badges_html`, append its output into `detail_extra`
alongside the existing summary/Plan/Done/PR-chip lines. Add
`.lifecycle`/`.stage.on`/`.stage.off` CSS reusing the existing `--ok`/
`--mut` color tokens (no new color variables needed) and the
`.pill`/`.artefact-chip` disconnected-badge shape (explicitly not a
connected stepper — see the "independent booleans" Key Technical
Decision).

**Patterns to follow:** the existing per-row enrichment sequence
(`wb_board_summary_line`, `wb_board_first_nonblank_line`, doc chips) —
add one more call in the same style, not a structural change to the loop.

**Test scenarios:**
- Happy path: a fixture task with all 7 signals true -> all 7 badges
  render `on`.
- Happy path: a fixture task with zero signals beyond worktree -> only
  the worktree badge renders `on`.
- Edge case: `feat/queue-command`-shaped fixture (brainstorm true, plan
  false) -> badges show that exact combination, not a broken/stuck-
  looking partial progress bar (visual-shape assertion: both badges are
  independently classed, neither depends on the other).
- Edge case: a fixture task in the `done` bucket -> no lifecycle badge
  block rendered at all (per the Scope Boundaries cut), regardless of
  what the 7 detection functions would individually return.
- Regression: existing PR-info chip content is unchanged by the
  `pr_info` computation reorder.
- Regression: existing live-session badge, doc chips, and Plan/Done
  excerpt lines are unaffected.

**Verification:** `bash scripts/.config/scripts/tmux/tests/wb-board-html.test.sh`.

---

### U5. Test coverage

**Goal:** fixture-backed, network-free coverage for every new function
and the render wiring.

**Requirements:** verification for R1-R4.

**Dependencies:** U1, U2, U3, U4.

**Files:**
- `scripts/.config/scripts/tmux/tests/wb-lifecycle.test.sh` (new)
- `scripts/.config/scripts/tmux/tests/wb-board-html.test.sh` (extend)

**Approach:** follow `wb-reconcile.test.sh`'s conventions directly: real
`git init` + `git worktree add` fixture repos for the worktree/plan/
brainstorm/work-done signals (these need real git state, not stubs); a
fake `gh` injected via `FIXTURE_BIN`/`PATH` prepend (same pattern as
`wb-reconcile.test.sh:27-38`) for the live-PR signal, so no test ever
makes a live network call; a real (but throwaway) tmux session, cleaned
up via `trap`, for the live-agent signal, following `wb-pause.test.sh`'s
real-session convention. Stub `wb_open_buffer() { :; }` if any path under
test reaches it (per `wb-reconcile-review.test.sh:84`'s established fix).

**Test scenarios:** the full list enumerated per-function under U1-U4
above; this unit is where they're actually written and run.

**Verification:** `bash scripts/.config/scripts/tmux/tests/wb-lifecycle.test.sh`
and `bash scripts/.config/scripts/tmux/tests/wb-board-html.test.sh` both
print `ALL PASS` (or this suite's established pass marker).

---

### U6. Documentation

**Goal:** record the design in the durable docs this repo already
maintains for `/board`, so the two resolved OPEN detection heuristics
don't have to be re-derived from a future git-log archaeology pass, and
give the lifecycle pipeline + `wb reviewed` user-facing coverage in the
manual.

**Requirements:** none directly — supports discoverability of R1-R3.

**Dependencies:** U1-U5.

**Files:**
- `docs/roadmap-board.md` (add a "Lifecycle-stage pipeline" subsection)
- `logs/decisions/2026-07-11-wb-board-lifecycle-detection.md` (new — the
  two OPEN-question resolutions, mirroring the existing
  `logs/decisions/2026-07-08-wb-reconcile-scoping.md` precedent)
- `docs/wb-guide.md` (add a "`wb board` — task overview + lifecycle
  pipeline" section, covering `wb reviewed` inline; this repo's
  user-facing manual, docgen-indexed the same way as `roadmap-board.md`)

**Approach:** `docs/roadmap-board.md` and `docs/wb-guide.md` are both
docgen-indexed source files (front matter `kind: page`/`kind: guide`) —
after editing either, rerun this repo's docgen step so the generated
`.html`/`INDEX.md` reflect the change (per this user's standing docgen
convention: docs are generated, never hand-edit the `.html`). The
`logs/decisions/` note captures the compound-heuristic rationale for
`/ce-plan`/`/ce-brainstorm` detection and the git-state heuristic for
`/ce-work` done, so a future reader hits the reasoning directly instead
of re-deriving it from this plan.

**Scope note on `docs/wb-guide.md`:** the guide currently has no section
for `wb board`, `wb pause`, or `wb reconcile` at all (it predates PR #14)
— this unit adds only what's needed to explain the lifecycle pipeline
(a concise `wb board` overview plus the new badges and `wb reviewed`),
matching the existing "wb new"/"The picker"/"wb done" section depth.
Backfilling full `wb pause`/`wb reconcile` coverage is a separate,
pre-existing gap this unit doesn't take on.

**Test scenarios:** `Test expectation: none -- documentation only, no
behavior change.`

**Verification:** docgen step runs clean; `logs/decisions/` file follows
the existing per-entry format used by prior entries in that directory;
`docs/wb-guide.md`'s new section reads consistently with its existing
section depth/style.

---

## Verification Contract

| Command | Applicability | Done signal |
|---|---|---|
| `bash scripts/.config/scripts/tmux/tests/wb-lifecycle.test.sh` | U1-U3 | all assertions pass |
| `bash scripts/.config/scripts/tmux/tests/wb-board-html.test.sh` | U4 | all assertions pass |
| `bash scripts/.config/scripts/tmux/tests/wb-schema.test.sh` | U3 (regression) | all assertions pass |
| Full suite via `scripts/.config/scripts/tmux/tests/Dockerfile` | All units, sandboxed | every `*.test.sh` prints its pass marker |
| `grep -q '^reviewed:' ~/code/tasks/TEMPLATE.md` (manual, outside the Dockerfile sandbox — see U3) | U3's cross-repo schema edit | field present |

## Definition of Done

- ~~Not started until `feat/wb-done-close` has merged to `development`
  and this worktree has rebased onto the merged result.~~ **Cleared
  2026-07-11** — merged as PR #19, this worktree fast-forwarded onto it.
- All 7 lifecycle signals compute correctly against the fixture cases
  above, including the two dogfood-validated compound heuristics
  (`/ce-plan`/`/ce-brainstorm` presence, `/ce-work` done), and correctly
  avoid crashing or misreporting on a task whose worktree has been
  removed (the `/ce-work` done KTD's guard).
- `wb board --html`'s detail cards render all 7 as independent badges for
  every non-`done`-bucket task, visually distinct from a connected
  progress bar, and are not rendered at all for `done`-bucket tasks (see
  Scope Boundaries).
- `wb reviewed` stamps the resolved task file's `reviewed:` field at
  runtime; separately, the task-store repo's `TEMPLATE.md` has been
  edited, committed, and pushed (via `pgh`) to add `reviewed:` to the
  schema so newly seeded tasks carry the placeholder.
- No new network call in the picker's hot path; the live-PR signal
  reuses the existing per-render `gh`/`pgh` call rather than adding one.
- `docs/roadmap-board.md`, `docs/wb-guide.md`, and a new
  `logs/decisions/` entry record the design; docgen has been rerun.

---

## Sources / Research

- `~/code/tasks/dotfiles--feat-wb-board-lifecycle.md` — origin task file,
  fully specifying this feature and its two OPEN detection questions.
- `scripts/.config/scripts/tmux/wb.sh:926-1460` (`wb_board_bucket_for_status`
  through `cmd_board`) — the existing board rendering this plan extends.
- `scripts/.config/scripts/tmux/wb.sh:437-518` (`cmd_reconcile` family) —
  worktree presence-diff detection, reused for signal 1.
- `scripts/.config/scripts/tmux/lib.sh:91-136` (`tmux_claude_panes`),
  `scripts/.config/scripts/tmux/claude-sessions.sh` — live-agent detection,
  reused for signal 2.
- `scripts/.config/scripts/tmux/wb.sh:1105-1129` (`wb_board_related_docs`) —
  pattern reused (re-rooted) for signals 3/4; also where the deferred
  cross-worktree bug was discovered.
- `scripts/.config/scripts/tmux/wb.sh:805-824` (`cmd_pause`) — the
  frontmatter-stamp pattern `wb reviewed` (U3) mirrors exactly.
- `scripts/.config/scripts/tmux/wb.sh:1080-1088` (`wb_board_pr_info`) —
  reused directly (no new call) for signal 7.
- `~/.claude/plugins/.../compound-engineering/3.19.0/skills/ce-work/SKILL.md` —
  confirms `ce-work` never stamps a marker; progress is git-only by
  design, grounding the U2 heuristic.
- `~/.claude/plugins/.../compound-engineering/3.19.0/skills/ce-code-review/SKILL.md` —
  confirms `ce-code-review`'s artifacts are ephemeral (`/tmp/...`) and it
  may mutate nothing at all in `mode:agent`, grounding the U3 heuristic.
- Direct filesystem/git inspection of the four dogfood worktrees
  (`feat/hub-v0`, `feat/handoff-v1`, `feat/wb-done-close`,
  `feat/queue-command`) performed during this planning session — the
  empirical basis for the compound-heuristic Key Technical Decisions
  above (not simulated; actual `git log`, `git status`, `ls`, and `tmux
  list-panes` output against the real worktrees).
- `docs/plans/2026-07-11-001-feat-wb-done-close-plan.md` (read from
  inside `feat/wb-done-close`'s own worktree) — confirms the exact
  functions/lines that plan touches, used to verify this plan's own diff
  surface doesn't line-overlap (only file-overlap, which the HARD GATE
  already accounts for).
- `scripts/.config/scripts/tmux/tests/wb-reconcile.test.sh:27-38` — the
  `FIXTURE_BIN`/fake-`gh` test convention U5 follows.
