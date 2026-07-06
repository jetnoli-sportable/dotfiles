# Roadmap — the personal workflow

> Originally "The way forward — synthesis of your takes" (2026-07-06), renamed
> once its scope outgrew a single PR: this is the roadmap for the whole
> personal workflow (tmux/Claude tooling, the central task store, notes-tui,
> the docs project), not just this dotfiles repo — several of the things it
> plans already live in separate repos (`~/code/notes-tui`, `~/code/tasks`).
> Fuses what landed in `logs/2026-07-06-workbench-piece-review.md` into one
> proposal. Each section has **Your take:** — mark what lands, strike what
> doesn't, edit anything in place.

---

## 0. Readback — the shape you described

- **Session per worktree** (not per repo), standard layout: one window each for
  nvim, agent, and running things. Grouped so a repo's sessions are easy to see
  together.
- **One picker to rule them all**: sessions and agents merged into a single
  view, since they're ~1:1. This replaces the `s` + `ca` split. `cad` retires.
- **Notes with a lifecycle**: a notes surface per session/worktree, seeded on
  create, *reviewed on close* with keepers flowing into a central system; plus
  quick capture into long-living topic ledgers, periodically reviewed, with
  future automation proposing quick wins that you just green-light.
- **Record layer stays plain files** serving three goals: per-task backlog /
  follow-ups, progress across all tasks + planned batches, easy review and
  refinement.
- Keep untouched: worktree flow, `/park` + `/parked-items` (fix the channel
  bug), `pr-review-session`, decision-buffer. Keep the nvim bridge to its basic
  loop (output buffer + reply); fancy features on hold.

**Your take:** 

Sounds good, one thing to refine on the record layer and parked items, is that perhaps that shouldn't live in scratch/ on a repo level, perhaps there should be a central location that different agents can access at the same time safely and then we can tag entries there to understand capture context but also to make it easier to factor in other similar cross project tasks

> **answer (2026-07-06):** agreed — central it is. Proposed shape: file-per-task
> markdown in one central location that is itself a git repo (candidate:
> `~/code/tasks`, or a `tasks/` subtree of the notes corpus (`~/code/notes`)
> since notes-tui shares the ground), frontmatter carrying `repo:` + free `tags:`. File-per-task
> keeps concurrent agents safe (no shared file contention), git gives history +
> cross-machine sync, tags give cross-project grouping. `/park`'s ledger stays
> the capture funnel and promotes into the store; `wb` and the worktree-seeding
> rule filter by `repo:` instead of reading `scratch/tasks/`. Exact location +
> notes-corpus overlap goes through a quick decision buffer when we build §3.

---

## 1. Step zero — light up the attention pipeline

Wire the three hooks into `~/.claude/settings.json` (I'll print the block; the
harness makes me ask you to approve/paste it), fix `parked-items`' fixed
wait-channel, and retire the dead `n` alias (see §4). After a week of hook data,
delete the version-pinned content scan. No design needed — this is maintenance
the rest builds on.

*(Done 2026-07-06: hooks wired in settings.json, parked-items channel fixed,
dead alias removed — commit 6015c43. The week-of-hook-data clock is running.)*

**Your take:**

---

## 2. The core — `wb` (workbench): session-per-worktree + the unified picker

One script in the existing `lib.sh` style, three verbs:

```
wb new <slug>          # from inside a repo (or wb new <repo> <slug>)
  → git worktree add .worktrees/<slug>; bootstrap via a per-repo gitignored
    .worktree-bootstrap manifest (paths to copy/symlink), default .env* when absent
  → seed the task file in the CENTRAL store (frontmatter §3; store location is
    decided before this slice — see reordered §8) if none exists
  → tmux session named for display only: sanitized "<repo>--<slug>" (/ and .
    become -); ground truth lives in session options @wb_repo + @wb_slug + @task
    (never parse the name back — be--monorepo already contains the delimiter)
  → win1 nvim · win2 agent (LAZY: window exists, claude starts on first visit
    or wb new --agent — bounded by the ~10-concurrent-agent memory ceiling)
  → win3 shell

wb                     # THE picker (replaces s and ca muscle memory)
  dotfiles                      ● working    [feat/tmux-claude-agent-notification]
  dotfiles--agent-task-flow     ◆ needs you  doing
  be--monorepo                  · no agent
  frontend--sfb-1204            ✔ finished   review
  → ROW SOURCE (decided 2026-07-06): one row per TASK from the central store —
    status from frontmatter, so planned and done tasks are visible — with live
    session/agent state overlaid as glyphs. Repo-level checkouts (main
    checkouts, no task) appear as extra rows. Enter on a session-less task row
    runs the wb new spin-up. Worktrees enumerated via per-repo
    `git worktree list` (authoritative), not directory globbing.
  → grouped by repo (from @wb_repo / frontmatter repo:, never name-parsing);
    SORT: any needs-you / finished row pins to the top of its group, mirroring
    ca's rank order — urgency is never buried by alphabetical grouping.
    *(Changed 2026-07-06, post-launch: grouping is now status-first, not
    repo-first — all needs-you rows surface together across every repo, then
    finished, then working, then idle, so you don't have to scan each repo's
    group to find what's urgent. A session's sub-rows still ride along with
    their parent as one block rather than scattering by their own individual
    rank — see `wb.sh`'s `collect_combined_rows`.)*
  → column 3 rule: task rows show frontmatter status (planned/doing/review/done);
    repo-level rows show the current branch in [brackets] instead.
  → sessions with >1 claude pane expand to one indented sub-row per agent
    (glyph + pane title) — pr-review-session stays legible after ca retires.
  → each row/sub-row carries a hidden field: its most-urgent claude pane target
    (min-rank over collect_rows), empty if no agent. x interrupt and the
    agent-pane preview act on THAT target, never the session's active pane.
    ctrl-x on a worktree-backed task row routes through the wb done flow (raw
    kill only for non-task sessions) — wind-down is the default exit, not an
    optional ritual. No-ops when the target field is empty.
  → status line shows the pending Follow-ups + parked count; wb done offers the
    cross-task sweep when it crosses a threshold (push, not a weekly ritual).
  → Enter jumps (or creates); preview = urgent agent pane, else git status.

wb done [<slug>]       # the wind-down that doesn't exist today — SAFE ORDER:
  1. fail fast: git status --porcelain in the worktree; if dirty, print the
     short status + "commit or stash, then re-run" and abort (nothing mutated)
  2. open task file + session notes in a review buffer (decision-buffer
     pattern); keepers are marked with checkbox lines (`- [x] keep`) — the ONE
     convention shared with §4's digest promotion
  3. on close: sweep worktree-local gitignored keepers into the central store
     (logs/decisions/*.md at minimum — VERIFIED: git worktree remove silently
     destroys gitignored files; the dirty check never protects them) and
     rewrite the task file's Decisions links to the store copies
  4. status → done, keepers captured (§4)
  5. kill session, then git worktree remove
```

Repo-level sessions (`dotfiles`, main checkout) remain plain rows in the same
picker — `s`'s job is absorbed, and the worktree-invisibility bug dies with it.
Keybind (decided 2026-07-06): **cutover** — `prefix+m` and `prefix+a` both
rebind to `wb` the moment it lands; `s`/`ca` stay invocable by name as fallback.

> **Credential guard (added 2026-07-06 review):** `wb new` bootstraps `.env*`
> into worktrees by default, and the keeper sweep copies gitignored files
> into the central store — a repo intended for cross-machine git sync (§0).
> Requirement retrofitted onto the live flow: the sweep must carry an
> exclusion list for credential-shaped files (`.env*`, `*.pem`, `*.key`,
> `*credential*`, …) and warn in the review buffer when a marked keeper
> matches one, so a bootstrapped secret can never ride a `- [x] keep` into
> a repo that later gets a remote.

**Your take:**
Sounds good do you think it should still be a bash script powering this or is it worthy of a go/python implemnetation? Happy to keep it as is btw just curious

> **answer (2026-07-06):** bash for v1. `wb` is tmux/fzf orchestration — bash is
> the native tongue there, `lib.sh` already has the helpers, no build step, and
> it stows like everything else. A compiled implementation earns its keep only
> if the task *index* grows real querying/aggregation needs — and that's
> notes-tui / cli-kit territory (Go you already own), not a reason to start `wb`
> in Go. Python only if we lifted `driver.py` wholesale, which we aren't.

---

## 3. The record — task files that can back a board

```markdown
---
status: doing        # planned | doing | review | done
repo: dotfiles       # worktree resolves as ~/code/<repo>/<worktree> — task
branch: feat/agent-task-workflow          # files live centrally, so paths
worktree: .worktrees/feat/agent-task-workflow   # must reconstruct from repo:
tags: []             # free tags for cross-project grouping (§0 amendment)
created: 2026-07-06
---
# Agent task workflow
## Plan          ← batches of intended work (your goal 2)
## Done          ← running log of what landed
## Follow-ups    ← per-task backlog (your goal 1); /parked-items review reads these
## Decisions     ← links to logs/decisions/*.md + key calls inline (F4)
```

Your three goals map: **backlog** = `## Follow-ups` (+ global `/park` for
cross-task strays); **progress tracker** = `status:` rendered as the picker's
third column — the board is *inside* `wb`, not a separate surface; **review &
refinement** = `wb done`'s close-out buffer plus a PUSH trigger (decided
2026-07-06): the picker status line carries the pending Follow-ups + parked
count and `wb done` offers the cross-task sweep past a threshold — the weekly
`/parked-items` ritual stays available but is no longer the load-bearing path.

> **Validation clock (added 2026-07-06 review, mirroring §1's):** the
> demotion above is a behavioral bet on event-driven pushes whose events are
> sparse (the nudge fires only at task completion; the count only renders
> when the picker is open). Check-in: **two weeks after slices 2–3 merged**
> (~2026-07-20), inspect the parked ledger's open-item ages. If the oldest
> open item exceeds ~10 days, the push bet failed — restore the weekly
> ritual as load-bearing or surface the count somewhere time-driven (e.g.
> tmux status-left), not just inside the picker.

**Your take:**

---

## 4. Notes — `notes-tui` is already the system you described

Finding: the `n` alias points at `~/Desktop/Projects/go-notes/notes.exe`, which
no longer exists on this machine — but the project lives on as
`jetnoli-sportable/notes-tui` (private, last touched 2026-06-19), and its README
is your take #2 almost verbatim:

- `note "thought"` / `cmd | note` — sub-second, zero-decision capture to an
  inbox, **auto-stamped with cwd, git repo+branch, and tmux session** — the
  task-linkage the daily notes lack.
- `notes digest day|week --by context` — the periodic review you asked for.
- `notes process` — mechanical cleanup proposals (your "automation scouts, I
  approve" — and its roadmap's AI layer is exactly that, grown up).
- Roadmap Phase 2 is a Bubble Tea TUI on the same corpus (`~/code/notes`, which
  `notes.sh` already uses).

Proposal: it's already cloned at `~/code/notes-tui` (branch feat/usage-guide;
the dead alias is now removed) — source its `note.sh` and make it the notes
backbone. Then the lifecycle wiring is small:
`wb new` stamps the session so every `note` during the task is already
context-tagged; `wb done` runs `notes digest --by context --context <session>`
into the close-out buffer so keepers get promoted deliberately — marked with
the same `- [x] keep` checkbox convention as §2's close-out. (Verified: the
current digest CLI has no per-session filter — slice 4 includes adding a small
`--context <tmux-session>` flag to notes-tui; the ctx metadata already records
`tmux:<session>` per capture. **Corrected 2026-07-06:** the flag alone is NOT
sufficient — corpus.Load parses one Note per file, so the whole inbox reads
as a single note carrying only the FIRST capture's context; slice 4 must
first teach the corpus to split `inbox.md` into per-capture notes, each with
its own timestamp and ctx stamp. Captures made before that lands can't be
retro-digested per-session without reprocessing raw stamps.) Topic ledgers = tags in
its Denote scheme (`__workflow`, `__vim`) rather than a parallel system we'd
build from scratch. `notes.sh` daily flow keeps working untouched on the same
corpus.

**Your take:**


---

## 5. HTML docs in the flow — ideas to pick from

You liked the findings doc's format for visualizing/comparing. Ways to make
that a habit rather than a one-off (not mutually exclusive):

- **(a) Visual mode for decision buffers** — when a decision is
  comparison-heavy, I emit an HTML companion next to the md doc and `xdg-open`
  it; checkboxes stay in the md buffer. Zero new tooling, just a skill rule.
- **(b) A docs shelf per repo** — convention: generated HTML lands in
  `docs/` (tracked) or `logs/html/` (scratch); `wb docs` fzf-picks across them
  and opens in the browser; task files link their docs so F4 dossiers include
  visuals.
- **(c) Standing agent rule** in global CLAUDE.md: any multi-option comparison,
  architecture map, or audit ≥ some size ships as HTML alongside the chat
  summary — the way this session's findings doc happened, made default.
- **(d) The help dashboard (§6) indexes recent HTML docs** so they're
  re-findable weeks later.

**Your take:** (which of a–d, or riff)
I'd like a combo of a and c. And then yes to d.

> **landing-path rule (decided 2026-07-06):** (a)/(c) HTML writes to ONE fixed
> location — `docs/` when tracked-worthy, else the central task store's dossier
> area (never worktree-local scratch, which `wb done` deletes) — so (d)'s index
> has a deterministic scan target. (b)'s `wb docs` picker stays unbuilt.

> **addition (2026-07-06, post-ratification):** every `.md`/`.html` pair built
> so far (this doc, the dotfiles overview) was hand-authored twice — write the
> markdown, then manually keep an HTML render in sync alongside it. That's
> exactly the kind of drift this section exists to prevent. Look at a proper
> **doc-sync tool**: one markdown file in a specific, defined format
> (frontmatter + section conventions), and a small generator that renders the
> HTML from it — single source of truth, regenerate on demand instead of
> hand-editing two files in parallel. Scope this alongside slice 5 (it's the
> same "generated, not hand-maintained" principle as the help dashboard's
> index); the exact format/generator choice can go through a quick decision
> buffer when it's built.

---

## 6. Help dashboard — one index of your whole personal stack

The ask: a place that answers "what do I have and how do I drive it" across
dotfiles scripts, tmux binds, aliases, Claude skills/memories, and TUIs. Ideas:

- **(a) Generated HTML manual** — a `/workbench-manual` skill scans the real
  sources (tmux.conf binds, zshrc aliases/functions, the repo's
  `instructions.md` files at their real stow-nested paths —
  `scripts/.config/scripts/tmux/instructions.md`,
  `nvim/.config/nvim/instructions.md` — `~/.claude/skills/*/SKILL.md`
  descriptions, `MEMORY.md`, TUI READMEs, plus `logs/decisions/*.md` and the
  task store's `## Decisions` sections so provenance questions are
  answerable) and renders one searchable page in the findings-doc style.
  Regenerate on demand — never hand-maintained, so it can't drift like
  instructions.md did.
- **(b) Terminal-first** — same scan emits a flat index; `help.sh` fzf over
  it (name → one-liner → source path), preview shows the doc excerpt, Enter
  opens the source. Keybinds (decided 2026-07-06): `prefix+h` KEEPS its
  existing direct-open-HUB behavior (muscle memory); the fzf help picker
  lands on `prefix+?`.
- **(c) Both from one source** — the scan produces a machine-readable
  `INDEX.md`; the HTML page and the fzf picker are two renderers of it. My
  pick: build the index + fzf first (10× more used day-to-day), HTML render
  second.

**Your take:** (a/b/c, and where it should live — dotfiles repo?)
c

> **addition (2026-07-06, post-ratification):** also build a quick way to *ask
> questions* about the config — "why do I have binding X", "what does skill Y
> do", "how do I use notes-tui" — answered by querying the generated index
> (INDEX.md) rather than requiring a manual grep across source files. This is
> a query mode over the same index from (a)/(c), not a new data source or a
> separate scan. Scope it as part of slice 5 when the help dashboard is built,
> not a standalone slice. *(Amended same day: "why do I have X" is a
> provenance question — answerable only because (a)'s scan list now includes
> `logs/decisions/*.md` and the task store's Decisions sections. Without
> those sources the query mode could answer what/how but not why.)*

> **manual precursor started (2026-07-06, PR #8):** built `docs/HUB.md` (index
> of every doc in this project) and `docs/overview.md` (guides for
> every skill and TUI, with full command/flag and keybind tables where
> possible) as the hand-maintained stand-in for (a)/(c) until the real scanned
> index exists. Both are meant to fall away once slice 5 lands — HUB.md's own
> footer says so. When slice 5 is built, its generated index should absorb and
> then delete these two files rather than maintain three sources of truth.

---

## 7. Keep / retire / hold

- **Retire:** `cad` dashboard (unused; `wb` absorbs it), dead `n` alias.
- **Hold:** nvim bridge fancy features (`:ClaudePick`, yank-code, `gf`) — they
  stay installed but we stop investing until the basic loop + workbench are in.
- **Keep as-is:** decision-buffer, `/park` + `/parked-items` (channel fix only),
  `pr-review-session`, worktree flow (its ritual gets absorbed by `wb new`).

**Your take:**
Look at notes above on park and scratch tasks

---

## 8. Build order (each slice usable on its own)

1. **Step zero** (§1) — hooks, channel fix, alias cleanup. *DONE 2026-07-06.*
2. **Central store + task frontmatter** (§3 — REORDERED ahead of `wb` per the
   2026-07-06 doc review: four reviewers flagged that building `wb` against
   `scratch/tasks/` then relocating one slice later reworks its whole
   read/write model). Quick decision buffer on store location, then the
   frontmatter convention + seed template; migrate the two existing task files
   (`scratch/tasks/jump-cycle-on-repeat.md`, `scratch/tasks/stow-claude-config.md`).
   *DONE 2026-07-06 — store at `~/code/tasks`, decision:
   `logs/decisions/2026-07-06-task-store-location.md`.*
3. **`wb` core** (§2) — new/picker/done, built against the central store from
   day one. Board column comes free from the §3 frontmatter. *DONE 2026-07-06
   — see `~/code/tasks/dotfiles--agent-task-workflow.md` for the full build
   log, the 8-persona code review, and the post-launch picker redesign
   (presence-only rows, 5-column layout, `r` rename / `b` break-out-to-own-
   session added during live usage). PR #7.*
4. **notes-tui revival** (§4) — split per the 2026-07-06 slice-review (the
   picker-redesign lesson: don't ratify wiring before usage):
   - **4a — capture habit, no wiring:** source `note.sh` into zshrc, merge
     notes-tui's `feat/usage-guide` branch down first, and just *use* capture
     + manual `notes digest` for a bounded window (~1 week, mirroring §1's
     hook-data clock). Verified 2026-07-06: notes-tui builds clean on local
     go1.24; `note()` does not collide with the `N`/notes.sh daily flow.
   - **4b — the real integration, gated on 4a confirming digest-at-close is
     the right review moment:** per-capture inbox parsing in the corpus
     loader (VERIFIED 2026-07-06: corpus.Load parses one Note per FILE,
     first ctx stamp wins — without splitting inbox.md into per-capture
     notes, a `--context` filter returns at most one row, ever), THEN the
     `--context <tmux-session>` digest flag on top, THEN the `wb` lifecycle
     hooks (`wb new` stamps; `wb done` runs the digest into the close-out
     buffer — placement must respect the sweep-strip: anything after the
     generated `## Sweep` heading gets truncated by `wb done`'s cleanup awk).
5. **HTML-in-flow + help dashboard** (§5/§6) — no longer one line of scope;
   post-ratification additions grew it to four sub-deliverables, listed here
   so the build-order entry matches reality: (i) the scanned index + fzf
   picker, (ii) the HTML manual render, (iii) the doc-sync tool (§5
   addition), (iv) the Q&A query mode (§6 addition). Sequencing/splitting
   decided at plan time. **Prerequisite:** the pending stow-claude-config
   task (at minimum the `skills/` subset) — the scan reads `~/.claude`
   sources that are currently version-controlled nowhere, and a durable
   index over unversioned sources rebuilds the drift problem one level
   down. The scan must fail loudly (not emit a silently partial index)
   when a declared source root is absent.

**Your take:** (reorder / cut / merge freely)

---

## 9. Later additions (captured 2026-07-06, post-ratification)

> Provenance: both items below were requested verbatim by the owner in chat on
> 2026-07-06 ("add a note to the plan… roadmap visualization on any level" /
> "startup/shutdown flow… factor this in"). Recorded here since they post-date
> the buffer round the rest of the doc went through; strike or edit as usual.

### 9a. Roadmap visualization skill — FOLLOW-UP (re-scoped 2026-07-06 review)

Owner's call from the doc-review buffer: **constrain harder, and defer** — add
the roadmap view as a follow-up once everything else is working, then discuss
in detail. Constraints locked in now: it renders a snapshot computed **from
task-store frontmatter — the same single source `wb`'s done-flow writes**
(one-board principle at the data layer; reworded 2026-07-06: the original
"snapshot of the board `wb` shows" became unsatisfiable when the picker went
presence-only and stopped rendering a store-backed board at all), zoomable
*today / task <slug> / week*, sourced from the store + parked ledger +
decision docs + transcripts. **Jira integration is excluded** and becomes its
own later, separately ratified addition. Output rides the HTML pipeline (md
source in a buffer → HTML at the §5 landing path, indexed by the help
dashboard).

> **Visibility gap identified 2026-07-06 (post-launch, during live usage):**
> the picker redesign in build-order item 3 made rows presence-only (live
> sessions/agents only) — the right call for signal-to-noise, but it means
> there is currently no single view of live + deferred (`## Follow-ups`) +
> parked (`/park` ledger) work; each lives in a different place (`wb`, `grep
> ~/code/tasks/*.md`, `/parked-items`). This is exactly the gap `/roadmap` is
> meant to close — recorded here so the motivating reason isn't lost by the
> time this follow-up gets picked up. Also tracked as a Follow-up on
> `~/code/tasks/dotfiles--agent-task-workflow.md`.

### 9b. Day bookends — startup/shutdown flows (follow-up, factor into design now)

Two workflows, `wb up` / `wb down` (or `/sod` `/eod`), composing the capture/recall
skills: **startup** — review yesterday's close-out + parked items + task board,
propose today's focus, recreate tmux sessions for the chosen tasks;
**shutdown** — sweep every live session, capture a quick status into each task file,
run the notes digest, then close all sessions cleanly so the PC can power off.
*(Amended 2026-07-06 review: the Jira sprint pull originally listed in startup
is REMOVED from 9b's scope and joins 9a's Jira exclusion as its own later,
separately ratified addition — same integration, same open questions: where
the API credential lives, and whether Jira-derived text may be persisted into
the sync-bound task store. 9a already set this precedent; 9b now follows it.)*

Design principle to honor while building slices 2–4: **sessions are regenerative,
not precious.** Because a `wb` session is fully derived from its task record (repo,
worktree path, standard 3-window layout), resume = re-running `wb new`-equivalent
from the store — no fragile tmux state snapshotting needed. tmux-resurrect/continuum
remain an optional complement for raw scrollback, but the task store is the source
of truth. Concretely: keep everything `wb` creates reconstructable from the task
file alone, and give `wb` a `down --all` / `up --resume` pair later.
*(Amended 2026-07-06 review: the reconstructable set must include each agent
pane's Claude session id, recorded at spawn — a session/window option or a
task-file field — so `up --resume` can `claude --resume <id>` instead of
restarting every agent cold. The 3-window layout is cheap to rebuild; the
in-flight agent conversation is the one genuinely precious state, and the id
is cheap to capture now but impossible to recover for sessions already
killed.)*

### 9c. Per-skill/TUI dedicated guide pages + tile-grid dashboard (follow-up, PR #8)

The owner's ask: not just a summary line per skill in `overview.md`, but a
proper standalone guide per skill and per TUI — the same treatment `wb-guide.html`
already gets — with `HUB.html` as a dashboard of tiles (grid, one card per
skill/TUI/doc, click through to the full guide). **Started as an interim
step** (PR #8): `HUB.html` is now a real tile-grid dashboard, but the 4
Claude-skill tiles deep-link into `overview.md`'s skills section rather than
their own page, since those dedicated pages don't exist yet. Full scope:
- Build `decision-buffer-guide.html`, `park-guide.html`, `parked-items-guide.html`,
  `pr-review-session-guide.html` (or one per skill, naming TBD) — each in the
  `wb-guide.html` style: overview, try-it-now, full command/flag reference,
  rough edges.
- **Born generated, not hand-built (added 2026-07-06 review):** these pages
  are authored as markdown-with-frontmatter and rendered via the §5 doc-sync
  tool — never hand-authored HTML like the current wb-guide.html. Building
  them by hand first would add four more permanently hand-maintained files
  at the exact moment §5 is trying to cut that count to one generated
  source. Sequencing consequence: 9c's pages land *after* (or together
  with) the doc-sync tool, not before.
- Same for TUIs — notes-tui already has one (`notes-guide.html`) and its
  HUB.html tile landed with PR #8; a future `wb` TUI-equivalent would get
  one too.
- Once built, repoint `HUB.html`'s skill tiles from `overview.html#<skill>`
  anchors to the dedicated pages, and `overview.md` shrinks back to short
  summaries + links (its current per-skill depth was a stopgap for the same
  reason the anchors are).

### 9d. Cross-repo, cross-session doc referencing (follow-up, PR #8)

The docs project already spans repos — `dotfiles/docs/`, `~/code/notes-tui/notes-guide.html`,
`~/code/tasks/*.md` — and `HUB.html`'s "Other artifacts" section proved a third
problem: HTML docs get built as Claude Artifacts during sessions and never
committed anywhere, discoverable (if at all) only by grepping `/tmp/claude-1000/*`
on whichever machine happened to run that session, until its scratch dir is
cleaned up.

**Split 2026-07-06 review — the two halves have very different costs:**

- **Now (cheap, closes the actual incident):** extend §5's landing-path rule
  into a standing skill rule covering ALL session-generated HTML artifacts —
  any doc worth publishing as an Artifact gets written to `docs/` (tracked)
  or the task-store dossier area at creation time, never left only in
  session scratch. "Commit it or lose it," enforced where the artifact is
  born. This alone stops the loss incident that motivated 9d.
- **Later (open-ended, needs its own decision buffer):** the cross-repo /
  cross-machine registry — referencing docs across every repo so they stay
  findable from the Hub including artifacts from any past session on any
  machine. Ratify only if artifacts still go missing after the standing rule
  lands. Depends on / composes with 9c and the §5 doc-sync tool. **Boundary
  constraint carried into that buffer as a named axis, not an
  implementation afterthought:** whatever mechanism wins must scope
  aggregation to an explicit personal allow-list of repos — employer-owned
  content (Sportable) never gets indexed into, or published from, personal
  surfaces (this session's near-miss is the motivating incident).

> **Naming note:** this doc is now called "Roadmap," and §9a above describes a
> *planned feature* also called `/roadmap` (a snapshot dashboard over the task
> store). They are not the same thing — this file is the plan-of-record for
> the whole personal workflow; `/roadmap` would be a live status view once
> built. Flagging so future-you doesn't conflate them.
