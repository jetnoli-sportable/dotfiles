---
name: review-guide
description: Turn a PR, a stack of PRs, or a branch into one review-guide page.
  The published page has A overview and risk, B where to focus / reading order /
  what to skim / proportion / simplify notes, C an explainer of the critical
  design decisions with diagrams, D each decision against its alternatives —
  built from five Sonnet review lenses and one Opus coordinator, with every
  finding cite-checked by script. Use when Jet types /review-guide with a PR
  number or URL, a list of stacked PRs, a base..tip range, or a branch. Not a
  line-by-line review (that's /ce-code-review).
disable-model-invocation: true
---

# review-guide

One page that tells a reviewer how to spend their review time on a big change.
Scripts count and check; five Sonnet lenses read deeply, one question each;
one Opus coordinator takes a fast independent look and then judges the lenses'
findings; this session decides what goes on the page.

`<skill>` below is the real directory holding this file (`realpath` of
`SKILL.md`'s directory), never a hard-coded `~/.claude/skills` path: before
merge the skill runs from a worktree. Scripts: `<skill>/scripts/`.

Every stage writes its file in the run directory `<run>` =
`<dossier>/review-guide/<target>/`, and the files are kept, so a re-run after
new commits can start from any stage. `<target>` is `pr<N>`, `stack<first>-<last>`
or the branch slug.

## 1. Resolve → `target.json`

In this session's shell (scripts never call `gh`/`pgh`; `pgh` is a zsh
function a subprocess can't see):

- **CLI:** `git remote get-url origin`. A Sportable-owned repo uses `gh`;
  every other owner (including `jetnoli-sportable/*`) uses `pgh`.
- **PR:** `<cli> pr view <n> --json number,title,body,state,headRefName,baseRefName,headRefOid,commits,url`.
  Fetch it: `git fetch origin pull/<n>/head` and `git fetch origin <baseRefName>`.
  `base` = `git merge-base origin/<baseRefName> <headRefOid>`, never
  `baseRefOid` (a moved base would show other merged work, reversed).
- **Stack** (ordered list, or `base..tip` mapped to PRs with `<cli> pr list --head <branch>`):
  each PR's `baseRefName` must be the previous PR's `headRefName`, **or** the
  default branch when the previous PR has merged (GitHub moves the base there
  on merge). Anything else stops the run with a message naming the break.
  A later PR's `base` is the previous PR's head when that is an ancestor
  (`git merge-base --is-ancestor`), else the merge-base as above. The range is
  the first PR's base to the last PR's head.
- **Branch with no PR:** `base` = `git merge-base origin/<default> <branch>`;
  intent comes from commit messages and the task file.
- **Agent cap:** a stack of more than 5 PRs means more than 10 agents. Stop and
  ask before going further.
- **Worktrees:** for each PR head (one for a single PR or branch),
  `git -C <repo> worktree add --detach <repo>/.worktrees/review-guide-<target>[-<pr>] <sha>`.
  If `.worktrees/` isn't ignored there, add it to `<repo>/.git/info/exclude`.
  Agents read only these, never this session's checkout.
- Write `target.json` in the shape documented at the top of
  `<skill>/scripts/cite_check.py`.

## 2. Land and gather → `context.md`

**Landing path** (decide now; `<run>` lives under it):
the dossier of the task whose `branch:` matches the head branch
(`grep -l '^branch: <branch>$' ~/code/tasks/*.md` → `~/code/tasks/dossiers/<repo>--<slug>/`);
else `dossiers/<repo>--pr<N>/`, or `dossiers/<repo>--<branch-slug>/` for a
branch with no PR (`/` and `.` become `-`). Never dotfiles `docs/`, even for
a dotfiles PR, and **Sportable work never on any personal surface**.

`context.md`, written by this session:
- **Intent**, at most 300 words, a source on each claim: the PR body, commit
  messages, the matched task's `## Plan` and `## Decisions`, and the Jira
  ticket (Atlassian connector) when a key like `SW-6698` is in the title or
  branch. Where sources disagree, say which you took and why.
- **Rules:** excerpts of `AGENTS.md`/`CLAUDE.md` at the root and in touched
  directories, and `CONTRIBUTING.md`.
- **State:** existing review comments (`<cli> api repos/<o>/<r>/pulls/<n>/comments`)
  and CI (`<cli> pr checks <n>`), so the page doesn't repeat a point already
  made. Known-failing tests on the base branch, if the repo has them.

## 3. Inventory → `inventory.json`

```bash
python3 <skill>/scripts/inventory.py <repo> <base> <head> --words <PR-body words> > <run>/inventory.json
```

For a stack, run it on the range and once per PR (`inventory-<pr>.json`).
Add `--generated <glob>` for a repo's built outputs that the script can't
detect. Generated and rename-only files never go into a brief.

## 4. Briefs → `briefs/`

Follow `<skill>/references/briefs.md`: `briefs/common.md` (run context,
inventory table, logic files with changed ranges, skim list, worktrees, then
the Shared rules word for word, plus the Stack note for a stack) and one brief
per agent (`L1.md`… or `L1-<pr>.md` per PR in a stack, `L2.md`–`L5.md`,
`coordinator.md`).

## 5. Dispatch

In one message, all with `run_in_background: true`:
- the coordinator, `model: "opus"`, briefed with `common.md` + the quick-pass
  part of `coordinator.md`;
- the lenses, `model: "sonnet"`: L1 (one per PR in a stack), L2, L3, L4, L5.

Each prompt is just: read `<run>/briefs/common.md` and `<run>/briefs/<own>.md`,
then follow them. One PR = 6 agents; a stack of *n* = *n* + 5.

## 6. Verify → `verified.json`

1. When every lens is back: `python3 <skill>/scripts/cite_check.py <run>/target.json <run>/lens-<x>.json`
   for each report. Drop `missing` findings, or fix one by hand if the claim
   is clearly right and only the excerpt is off, then re-check.
2. Resume the coordinator with `SendMessage`: part 2 of `coordinator.md`, with
   the `.cited.json` paths. If it can't be resumed, start a fresh Opus agent
   with `quick-pass.json` plus those paths, and say so in the chat summary. If
   `quick-pass.json` is missing or unreadable as well, stop and ask.
3. Run `cite_check.py` on `verified.json` (it catches the coordinator's own
   findings). Drop `REJECTED` and `missing`. `PLAUSIBLE` ones go on the page,
   labelled as such.
4. Read each agent's `rulings`, and judge the coordinator's `disagreements`
   yourself.

## 7. Synthesise → `review-guide-<target>.md`

Write it in `<dossier>`, frontmatter `title`, `eyebrow`, `updated`; each `##`
is a nav entry. Load `artifact-design` and `artifact-diagramming` first.

| Part | Built from |
|---|---|
| **A. Overview:** what changed, impact, scope, risk (low / medium / high, with reasons) | intent, inventory and hot flags, the coordinator's overall read, confirmed L1 findings |
| **B. Review focus:** ranked hotspots, reading order, skim list, proportion, simplify notes | L1 + L4 (hotspots, test gaps), L3 (order, proportion, skim extras), L5 (simplify notes, never risk items), inventory and `checked_clean` lists (skim, with grounds) |
| **C. Explainer:** one subsection per critical decision, with a diagram and a real code excerpt | L2 decisions and component map |
| **D. Design evaluation:** each decision against at least two alternatives, pros, cons, a recommendation | L2 alternatives, judged here |

Every finding shown keeps its `file:line` and excerpt. Diagrams are inline
`<figure><svg>` using the template's classes (`k-script`, `k-orch`, `k-sub`,
`k-ver`, `b-*`, `t-b`/`t-s`/`t-m`, `ln`, `arrowhead`). Follow Jet's
explaining rules (`~/.claude/CLAUDE.md`, "Explaining"): each point why first,
terms defined at first use, real excerpts, a conclusion and recommendation.
For a stack, tag every item with its PR.

## 8. Render

```bash
uv run -q --with markdown python <skill>/scripts/build-page.py <dossier> review-guide-<target>
```

Never edit the HTML; change the `.md` and re-run.

## 9. Deliver

- Publish `<dossier>/review-guide-<target>.html` as an Artifact (a re-run
  republishes to the same URL).
- Add a row to `<dossier>/tools/README.md`'s page table (create the file with
  the render command if absent).
- If a task matched: `wb append <task> Handoffs "review-guide page: <path> — <url>"`.
- Chat summary: the path and the URL, the top three focus points, agent count,
  any coordinator fallback, and the worktrees created, with an offer to remove
  them (`git worktree remove`). Don't remove them unasked.

## Learnings ledger

Append to `<skill>/learnings.md` (one dated line) whenever a run surprises:
a stage that broke, a lens that drifted, a page Jet found unhelpful.
