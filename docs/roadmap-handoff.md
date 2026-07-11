---
title: /handoff — route a discussion to the right worker
status: current
tile: Take what's being discussed and either switch to the agent already on it, or spin up a new task for it.
group: personal-workflow
kind: page
updated: 2026-07-10
---

Queued 2026-07-08, marked for pickup soon. This page is the source; edit
`docs/roadmap-handoff.md`, not the rendered `.html`.

**Roadmap:** new item, not from the original numbered list · **Status:**
queued for build; the sub-task relationship it depends on is now
fully designed (see below), not built; the single-target flow was run
**by hand** in a real session 2026-07-10 — mechanical findings below

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

## Dry-run findings — 2026-07-10 (the flow run by hand, single-target)

A `be--monorepo` session ran the exact single-target flow `/handoff` is
meant to automate, **by hand** — not a test of `/handoff` (it doesn't
exist yet), but doing manually what it's supposed to do: mid-conversation,
a clearly-standalone piece of follow-up work (a flaky test root-caused in
one repo, needing its own fix in a separate worktree/branch/PR) got its
own agent via `wb new --agent <repo> <slug>`, a hand-seeded task file, and
a tmux-injected briefing. The steps below all surfaced as real, every-time
mechanics — v1 must treat them as **first-class scope, not implementation
detail to figure out later**. Nothing here reopens D9–D12
(schema/topology/rendering stay as resolved); this feeds the parts of v1
that were still open.

1. **Task-file-as-payload.** `/handoff`'s job splits in two: write the
   rich context (diagnosis, decisions, intended approach) into the task
   file — in the dry run, directly under `## Plan` so the new agent never
   re-derives it — then send a **short** pointer prompt naming that file
   and the explicit first action. Do not try to inline full context into
   injected tmux keystrokes. (Injection detail that mattered: one long
   single-line string — literal newlines risk premature submission —
   followed by a separate Enter keystroke.)
2. **Boot-readiness detection.** The freshly spawned bare `claude`
   process takes time to boot; the injector must poll for the ready state
   (`tmux capture-pane`, watching for the ready prompt) before sending
   the briefing. A fixed sleep is not reliable. Open sub-question for the
   build: what exact ready-signal to poll for.
3. **The permission-prompt handshake.** The briefing's first instruction —
   read the task file — points at `~/code/tasks/`, deliberately outside
   the repo root, so every spawned agent hits a Read-outside-cwd approval
   prompt as its **literal first action**. Not an edge case; it fires
   unconditionally. v1 must decide how to clear it without a human in the
   loop each time — e.g. pre-scoped settings allowing reads from
   `~/code/tasks/` for wb/handoff-spawned sessions, vs. some other
   mechanism. A decision to make up front, not discover.
4. **First-action selection.** "This needs a plan, not straight-to-work"
   was a live judgment call — the dry run pointed the new agent at
   `/ce-plan`, not implementation. v1 must state whether the first action
   is hardcoded (e.g. always `/ce-plan`) or inferred from context. Real
   decision point, encountered live, not hypothetical.
5. **Fan-out is a real gap, not an implicit extension.** The dry run spun
   up ONE agent. When a discussion splits into several
   independent-but-related pieces (three separate flaky tests; a
   cross-repo FE+BE pair), `/handoff` as scoped computes a single
   repo/slug and has **no batch path** — this is covered nowhere in the
   current docs. The already-resolved parent/child design (D9–D12:
   `parent:` field, repo-agnostic coordinating parent, one tmux session
   per child repo) is the right target shape; multi-target `/handoff`
   should be an explicit loop over it — per piece: compute repo/slug →
   check existing task + live session (the same lookups as
   single-target) → `wb new` or switch → stitch the set via the shared
   `parent:`. Say so in v1's scope rather than leaving multi-target as a
   "probably fine" extension of the single-target case.
6. **Separate wb-level follow-up (not `/handoff`'s to fix):** `wb new`'s
   bootstrap only copies gitignored files named by a repo's
   `.worktree-bootstrap` manifest, falling back to root `.env*` files
   when there's no manifest (`wb_bootstrap`, `wb.sh:136-157`). A repo
   with neither — `be--monorepo`'s `config.hjson` at root and
   `apps/metrics_server/config.hjson` — gets **silently skipped**, and
   the dry run had to copy them by hand. Fix lives in that repo (add the
   manifest); tracked as its own roadmap line item so it isn't painfully
   rediscovered.

**Dry-run #2 — 2026-07-10, later the same day (dotfiles, agent-orchestrated
end-to-end).** The full flow above was repeated, this time driven by the
orchestrating agent rather than by hand, to spawn the parent/child planning
session itself. Three additions to the findings:

- **Finding 3 confirmed + an answer candidate:** the `~/code/tasks/` read
  prompt fired exactly as predicted, as the spawned agent's literal first
  action. It was answered with the dialog's own session-scoped option
  ("Yes, allow reading from tasks/ during this session") — evidence that a
  pre-scoped tasks-read allowance per spawned session is the natural
  mechanism, and it already exists as a one-keystroke dialog option.
- **Readiness/prompt detection needs anchored markers, not keyword greps.**
  A `capture-pane | grep` watcher matching "allow" false-positived on the
  welcome banner's release-notes text ("auto-allows `git push`…"). Reliable
  anchors observed: `? for shortcuts` (boot-ready) and `Do you want to
  proceed` (permission dialog). `/handoff`'s poller should match those
  exact strings.
- **Model selection has a side effect:** `/model sonnet` sent to the
  spawned session also *saved Sonnet as the user's default for new
  sessions* — per-spawn model choice must not go through `/model` unless
  that's intended; a launch-time flag/config on the `claude` invocation is
  the clean mechanism.

*(Re-instated 2026-07-10 evening from the orchestrating session's record —
this block was uncommitted when the deletion incident hit.)*

**Dry-run #3 — 2026-07-10, same day (dotfiles, the orchestrating session
spawning the /handoff-v1 planning session itself — a live run of the flow
being designed).** Two additions, both sharpening readiness/permission
detection specifically:

- **The boot-ready marker is not a single stable string — poll a SET of
  anchors.** A poller waiting on `? for shortcuts` timed out because that
  boot showed `Try "…"` instead. Reliable approach: match any of the ready
  anchors — the shortcuts hint (`? for shortcuts`), the `Try "` quote
  placeholder, or the `% ctx` statusline — not one literal. Sharpens
  finding 3 above ("what exact ready-signal to poll for"); confirmed
  independently the same day via a live tmux+claude probe (see the task's
  own plan for the exact anchor set and the single-keystroke permission-menu
  behavior).
- **Scope the marker match to the agent's OUTPUT region, not the whole
  pane — the input box echoes your own injected prompt.** A
  readiness/skill watcher grepping the full `capture-pane` for `ce-plan`
  fired a false positive by matching the literal string inside the
  briefing text still sitting in the input box, before the skill actually
  invoked. Only a marker confirmed in the transcript/output area is real.
  Same failure class as the "allow" banner false-positive above,
  generalized: any marker that can also appear in the briefing you just
  sent will match prematurely if the poller scans the input region. The
  poller must exclude the input line (and the welcome banner) from its
  match window.

**Net rule for v1's readiness/permission detection:** match an anchor set,
and only within the agent's output region — never the input echo or the
static banner.

## The sub-task relationship gap — resolved design, 2026-07-09

Raised alongside the `/handoff` ask: "do we have a relationship in place
for sub-tasks? ... being able to take something big and break it down into
a bunch of smaller pieces." Checked the actual schema
(`~/code/tasks/README.md`) — nothing today represents "this task is a
piece of that task"; `tags:` is documented as "free tags for cross-project
grouping," not a parent/child relationship.

Folded into the Hub v0 scoping session's own decision-buffer round rather
than deferred to a separate one — resolved as its own PR, sequenced
immediately after Hub v0, with the design (not the build) done now. Full
decision record: `logs/decisions/2026-07-09-hub-v0-scoping.md`, Decisions
9–12; requirements-level summary: `docs/brainstorms/2026-07-09-hub-v0-requirements.md`.

**Schema:** a new `parent: <repo>--<slug>` frontmatter field on each child
task, pointing at its parent's filename stem. The parent task itself
carries no real `repo:` (a placeholder) since it coordinates rather than
does the work — this is what makes the representation identical for
same-repo and cross-repo (full-stack FE+BE) parents alike, rather than
needing a special case for `repo:` disagreeing across children.

**Session topology + agent model:** one tmux session per repo, exactly as
`wb.sh` already works today (`cmd_new`, `wb.sh:231-288`) — linked by the
shared `parent:` field, not a shared multi-worktree session. Chosen over a
single session with an extra window per child worktree specifically to
avoid breaking the "one worktree = one agent's cwd" assumption the
attention-pipeline hooks, the credential guard, and `wb reconcile`'s drift
detection all already rely on.

**Rendering:** a new parent-aware picker sub-row function
(`wb_parent_subrows`, grouping by shared `parent:` — distinct from the
existing `wb_agent_subrows`, `wb.sh:1516-1528`, which groups by
multi-agent-per-session instead) plus making real the `/board` rollup
already mocked up in `logs/decisions/2026-07-08-board-mockup-a-
table.html`'s speculative section.

## Sequencing

Design resolved (above); build not yet started. When picked up: (1) the
schema/topology/rendering design above, already resolved — no re-scoping
needed; (2) the mechanical v1 requirements from the 2026-07-10 dry-run
findings above (task-file-as-payload, boot-readiness polling, the
permission-prompt handshake, explicit first-action selection) are
first-class scope, not discovered-during-build detail; (3) multi-target
fan-out rides the parent/child loop (finding 5) and belongs in v1's
scope statement even if the batch path itself lands later; and (4) the
follow-up (deferred on purpose) of actually instructing an existing
agent rather than just switching to their session, which `/handoff`
itself still needs once this lands — findings 1–4 apply to that path
too, since it uses the same injection mechanics.

## Follow-on idea (not v1, not yet planned): self-handoff between stages

Raised 2026-07-11, while /handoff v1 itself was mid-plan: keep a single
task's context clean across its own stage boundaries (e.g. `/ce-plan`
finishes, `/ce-work` begins) by having the *same* agent update the task
file's state, `/clear` its own context, then re-arrive and read the task
file fresh for the next stage — rather than one long session accumulating
all of planning's research/back-and-forth before implementation even
starts.

This is a different mechanic from v1's routing, not a variant of it:
v1 takes a *tangential* discussion and sends it to a *different*
repo/slug's agent (existing session via switch+clipboard, or a fresh one
via spawn+inject). This idea keeps the *same* repo/slug/session and clears
*its own* context mid-flow — the "session already live" check v1 relies
on (`tmux has-session`) would always be true here (it's asking about
itself), so neither of v1's two delivery paths actually fits; a third
mechanic is needed. Two real open questions it would have to answer before
being planned for real:

- **Self-`/clear` timing.** `/clear` would need to be sent (`tmux
  send-keys`) to the agent's own pane from within its own turn, then that
  turn would need to actually end before `/clear` gets processed — an
  unverified mechanic, not a reuse of anything v1 already dry-ran. Needs
  its own dry-run before being trusted, the same way v1's boot/permission
  mechanics did.
- **Stage-tracking convention.** The task-store schema has no notion of
  "which stage of this task is done" today (`status:` is
  planned/doing/review/done/paused, not per-stage) — this would need its
  own schema decision, potentially overlapping with the parent/child
  work's own schema changes in flight on `feat/task-parent-child`.

Parked as its own future PR, sequenced after v1 (reuses v1's task-file-as-
payload and clipboard/inject mechanics once they exist) — not built or
scoped further here. Owner's framing: "happy to have this be a new skill
and come in a separate PR... that should basically be a follow-up PR we
plan after this."
