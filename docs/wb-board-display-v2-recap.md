---
title: "wb board display v2 — recap"
status: current
tile: Lifecycle stepper, Pipeline tab, dependency relationships, filters, Key Findings — shipped, Docker-verified, ready for review.
group: personal-workflow
kind: page
updated: 2026-07-13
---

Ten implementation units on `feat/wb-board-display`, executed against
[`docs/plans/2026-07-12-001-feat-wb-board-display-plan.md`](plans/2026-07-12-001-feat-wb-board-display-plan.md)
to its Definition of Done. This page is the source; edit
`docs/wb-board-display-v2-recap.md`, not the rendered `.html`. A richer,
visual walkthrough of the same material is linked at the bottom.

## What shipped

| Unit | What | Where |
|---|---|---|
| U1 | Doc-detection hardening — branchless guard, kept-branch fallback, `ideate` stage, R8 frontmatter discriminator | `wb-lifecycle.sh` |
| U2 | Four-state stage resolver (`na`/`pending`/`progress`/`done`) + `path:` parsing | `wb-lifecycle.sh` |
| U3 | `wb new --path`/`--depends-on` flags + task seeding | `wb.sh`, `wb new` |
| U4 | Render pre-pass — one per-task computation pass (~15 associative arrays) feeding every panel | `wb.sh` |
| U5 | Pipeline tab — every non-done task, window-independent | `wb.sh` |
| U6 | Two-zone detail cards, full/mini stepper, dependency chips, children-done counter | `wb.sh` |
| U7 | Header window control + independent Repo/Family filters (AND-composing) | `wb.sh` |
| U8 | Tasks-repo schema fix (`path:`/`depends_on:` in template, status vocabulary correction, restored `# Title`/`## Follow-ups`) | `~/code/tasks` (external repo) |
| U9 | Board-wide Key Findings — most-blocking, ready-to-close, unreviewed count, oldest in-flight, unclassified, docs-before-branch | `wb.sh` |
| U10 | `wb reviewed` convention (`~/.claude/CLAUDE.md` + `wb-guide.md`), doc refresh, docgen rerun | docs, skills, docgen |

All CSS-only — no JavaScript was added anywhere in this feature.

## Verification Contract — results

- **Plain-text `wb board` is byte-identical** to the pre-change baseline, checked by diffing output against a `git worktree` checkout of the branch's merge-base against a live copy of the real store.
- **Docker sandbox** (`scripts/.config/scripts/tmux/tests/Dockerfile`) — every board-relevant suite (`wb-board-html`, `wb-board`, `wb-lifecycle`, `wb-new`, `wb-schema`, `wb-parent-child`) is **all-pass**. Two unrelated, pre-existing failures surfaced (`handoff*.test.sh`, `wb-reconcile-review.test.sh`) — see **Known gaps** below; both confirmed via `git diff --stat` to have zero lines touched by this branch.
- **Real-store smoke test** — rendered the actual `logs/board.html` against the live `~/code/tasks` store: Pipeline tab, stepper, filters, and Key Findings all present, no injection leakage, 397 lines / 168KB.
- **Regression sweep** — `wb-lifecycle`, `wb-new`, `wb-board`, `wb-schema`, `wb-parent-child` all green on host.
- **R23/R24 landed**: the tasks-repo schema commit (`1226ce1`) is pushed to `origin/development` in `~/code/tasks`, with the grandfathering decision stated verbatim in its message; the `wb reviewed` convention sentence is in both `~/.claude/CLAUDE.md` and `docs/wb-guide.md`.
- **Docs regenerated** via `docgen.sh all` — no stale board description remains in the Hub tile, the `wb-board` skill, or the guide.

## How to verify it yourself

```bash
cd ~/code/dotfiles   # or this worktree
wb board --html
xdg-open logs/board.html
```

Things to look for:

1. **Pipeline is the default tab.** Every non-done task across every repo shows up, with five stage cells (Ideate/Brainstorm/Plan/Work/Review) each rendering `·` (n/a), `○` (pending), `◑` (in progress), or `✓` (done).
2. **Open a done task's card** (any bucket tab) — it has the same two-zone layout and stepper as an in-flight task, just with every applicable stage checked off.
3. **Repo and Family dropdowns** (header, top right) narrow every tab's rows/cards at once. Key Findings at the bottom of any tab does **not** shrink when you narrow a filter — that's deliberate (R22).
4. **Key Findings**, bottom of every tab: look for the `board-wide · ignores filters` tag next to the heading, and however many of the six insights are non-empty right now (grep `logs/board.html` for `key-findings` if you want the raw markup).
5. **A task with `depends_on:`** (if one exists in your store right now) shows a `⛔ n` chip; its blocker shows a `→ n` chip — both directions, independently.

To re-run the test gates yourself:

```bash
bash scripts/.config/scripts/tmux/tests/wb-board-html.test.sh   # slow: real gh calls per branch, ~10-15 min
bash scripts/.config/scripts/tmux/tests/wb-lifecycle.test.sh
bash scripts/.config/scripts/tmux/tests/wb-new.test.sh
docker build -t wb-tests -f scripts/.config/scripts/tmux/tests/Dockerfile .
docker run --rm -v "$(pwd)":/repo:ro -w /repo wb-tests
```

## How this ties into other work in flight

The store currently has 4 other dotfiles branches moving in parallel
(`wb board --html` shows all of them under Pipeline). The one that
actually matters for this PR:

> **Heads-up: real merge-conflict risk with `feat/wb-breakdown-skill`.**
> That branch (status `doing`) has an uncommitted, in-progress diff
> against `wb.sh` that adds **187 lines to `wb_seed_task` and `cmd_new`**
> — the exact two functions this PR's U3 also extended (to add
> `--path`/`--depends-on`). The plan's own Definition of Done anticipated
> a conflict here in general terms ("whichever branch lands second
> rebases, confined to `cmd_new`/`wb_seed_task`") — this confirms it's a
> real, concrete collision, not a hypothetical one. Whichever of these two
> lands second should rebase and expect to manually reconcile that
> region.

The other three, for context:

| Branch | Status | Relationship |
|---|---|---|
| `docs/roadmap-tasks-concurrency-safety` | doing (brainstorm stage) | Scoping a fix for `~/code/tasks`'s lack of locking. Still relevant: this session's own U8 push was a manual safe-fast-forward check (verify clean FF, don't touch someone else's uncommitted work) — exactly the kind of care that lane wants to make automatic. No code overlap with this PR. |
| `feat/jira-integration` | doing | `/board` + day-bookends halves. Board v2 explicitly excludes Jira integration from scope (plan's own Assumptions) — this is the follow-up that will eventually consume the Pipeline tab's data model. No code overlap yet. |
| `fix/xdg-open-slack-hijack` | review | Unrelated (desktop default-browser handling). No overlap. |

## Known gaps (pre-existing, not introduced here)

Both confirmed via `git diff --stat <merge-base>..HEAD` showing **zero**
lines touched in the relevant files — neither is a regression from this
branch:

- `handoff.test.sh` / `handoff-poller.test.sh` fail inside the Docker
  sandbox — they need a live tmux session/clipboard the container doesn't
  have. Pass fine on host.
- `wb-reconcile-review.test.sh` fails inside Docker only — the image's
  `gawk` (Ubuntu 24.04) handles an escape-sequence regex (`\.`, `\[`,
  `\]`) differently than the host's `mawk`. Passes clean on host (0
  failures).

## Links

- Plan: [`docs/plans/2026-07-12-001-feat-wb-board-display-plan.md`](plans/2026-07-12-001-feat-wb-board-display-plan.md)
- Human guide: [`docs/wb-guide.md`](wb-guide.html) (v2 board section + refreshed `wb new` docs)
- Roadmap detail: [`docs/roadmap-board.md`](roadmap-board.html) (v2 pass, "what shipped in v2" section)
- Skill: `claude/.claude/skills/wb-board/SKILL.md`
- Richer visual walkthrough: `docs/wb-board-display-v2-recap.artifact.html` (published separately as a claude.ai Artifact)
