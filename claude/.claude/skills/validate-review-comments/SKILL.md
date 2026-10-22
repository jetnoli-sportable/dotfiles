---
name: validate-review-comments
description: Check Jet's unsubmitted (pending) PR review comments against the code before Jet submits — for each draft comment, state what it is taken to ask, give a verdict (agree, partly, drop) with code evidence, say whether the point is stronger or weaker than worded, and run a short "is this relevant now?" gap pass — then publish the result as a page in the task's dossier. Use when Jet types /validate-review-comments with a PR number or URL or a stacked list of PRs, or says "check my draft comments", "validate my review comments", "do my comments hold up", "check my pending review before I submit". A re-run re-checks only comments edited since the last run. Never posts, edits or submits anything on GitHub. NOT a code review of the PR (use /ce-code-review), NOT a pre-review orientation (use /review-guide).
---

# validate-review-comments

Jet drafts review comments on a PR, then runs this before submitting. The page
answers, per comment: does the code back this up, and is it worded as strongly
as it deserves? It also says what Jet may have missed. One session, no
subagents: scripts map comments to code, this session judges.

`<skill>` below is the real directory holding this file (`realpath` of
`SKILL.md`'s directory). `<rg>` is `<skill>/../review-guide`, the review-guide
skill beside it, whose stages and page builder this skill reuses. Never a
hard-coded `~/.claude/skills` path: before merge the skill runs from a worktree.

Run directory `<run>` = `<dossier>/validate-comments/<target>/`, `<target>` =
`pr<N>` or `stack<first>-<last>`. Files are kept, so a re-run can compare.

## Hard rules

- **Read-only on GitHub.** Never post, edit, resolve, delete or submit a review
  or comment. Every `gh`/`pgh` call this skill makes is a read.
- **Never write as Jet.** A suggested rewording is labelled "Claude's draft" in
  a fenced block, never a paste-ready reply in Jet's voice.
- **Identifiers get a plain description** (a commit, PR, ticket, comment
  number), in the same sentence. Sportable comment text, code and run state
  stay in the task store; nothing from a run goes into dotfiles.
- **Explaining:** follow `~/.claude/CLAUDE.md` "Explaining": why it matters
  first, terms defined at first use, real code excerpts, a plain conclusion.

## 1. Resolve → `target.json`

Follow `<rg>/SKILL.md` stage 1 for the CLI choice (`gh` for Sportable-owned
repos, `pgh` for the rest), the merge-base rule, the stack chain check and the
detached worktrees, with these differences: a PR or stack only (a pending
review needs a PR); no agent cap; worktrees named
`<repo>/.worktrees/validate-comments-<target>[-<pr>]`. Reuse a live worktree
already at the same head. Write `target.json` in the shape documented at the
top of `<rg>/scripts/cite_check.py`, `prs` filled for a single PR too.

## 2. Land

The landing path rule of `<rg>/SKILL.md` stage 2: the dossier of the task whose
`branch:` matches the head branch, else `~/code/tasks/dossiers/<repo>--pr<N>/`.
Never dotfiles `docs/`. From the matched task, read `## Plan` and
`## Decisions` (for the gap pass, and for findings Jet already set aside).

## 3. Fetch → `comments.json`

In this session's shell, per PR (only Jet's own pending review is visible to
Jet's token, and there is at most one per PR):

```bash
id=$(<cli> api repos/<o>/<r>/pulls/<n>/reviews --paginate --jq '.[] | select(.state=="PENDING") | .id')
<cli> api --paginate repos/<o>/<r>/pulls/<n>/reviews/$id/comments > <run>/comments-<n>.json
jq -s 'add' <run>/comments-*.json > <run>/comments.json
```

No pending review on any PR: stop and say so (it may have been submitted
already). A review with no comments, only a body: say there is nothing to check.

## 4. Map → `comments.mapped.json`

```bash
python3 <skill>/scripts/pending_comments.py <run>/target.json <run>/comments.json
```

Each record gives the file, the line and an excerpt on the comment's side
(`head`, or `base` for a comment on a deleted line), a stable page number `n`,
`cite` (`ok`, `moved`, `gone`, `file`), `ambiguous`, `later` (stack: does the
line survive later PRs) and `changed`. The script's docstring has the details.
Read code from the worktree for the head side, `git show <base>:<path>` for the
base side.

## 5. Judge

For every record with `changed: true`, in this order:

1. **My reading:** one sentence on what the comment asks the author to do.
   If the wording allows two readings (a word that names both a concept and a
   stored value; "this" with two antecedents), state both, judge the likelier,
   and say which you took. A misread comment was the first run's worst miss.
2. **Verdict:** `agree` (the code backs it up as worded), `partly` (right in
   part, or right for a different reason), `drop` (the code doesn't support
   it). Evidence: `file:line` plus the real excerpt, and the callers, tests or
   docs that settle it, read from the worktree.
3. **Stronger or weaker than worded:** for example a "nit" that is a real bug,
   or a "must fix" that the tests already cover.
4. **Claude's draft** (only when the wording should change): a fenced block
   under the label "Claude's draft".
5. **Stack:** from `later`, whether the code survives the later PRs. When it
   doesn't, name the PR that changes it, so the point lands where it's cheapest.

`moved` and `gone` go on the card: "drafted at line 86, now line 88" or "this
line no longer exists at the head". `ambiguous` means the line was matched
by guesswork; check it by eye.

## 6. Gap pass

A short pass for what the comments missed, at most about five items:
**plan vs code** (the task's `## Plan` and the PR body against what shipped),
**API doc vs code** (README, docstrings or schema the PR touches), **tests**
(changed logic with no test change). Frame each as "is this relevant now?"
and say why it might not be: a feature that isn't live yet, or a point already
raised on the base PR. Skip anything one of Jet's comments covers and anything
the task's Decisions set aside. Keep what was checked and found fine for
"Checked and fine".

## 7. Write → `validate-comments-<target>.md`

In `<dossier>`, frontmatter `title` (a two-to-four-word name such as "Draft
comments check", no colon), `eyebrow` (repo, target, head SHA), `updated`.
Load `artifact-design` first. Sections, each a nav entry:

- `## At a glance`: verdict counts, then the comments most worth changing
  before submitting, one line each.
- `## Your comments`: one card per comment in `n` order.
- `## Worth raising`: the gap pass items.
- `## Checked and fine`: what the gap pass looked at and cleared.

A card, using `<rg>`'s verdict-chip form exactly:

````markdown
### Comment 3 · pkg/x.go:88

**Comment 3** partly · drafted at line 86, now line 88

> the comment's text, quoted

```go
the excerpt
```

**My reading:** ...

**Evidence:** ...

**Stronger or weaker:** ...

**Claude's draft:**

```text
...
```
````

A file-level card's heading is `### Comment N · <path>`, with no excerpt.

## 8. Render

```bash
uv run -q --with markdown --with pygments python <rg>/scripts/build-page.py <dossier> validate-comments-<target>
```

Never edit the HTML; change the `.md` and re-run.

## 9. Deliver

- Publish `<dossier>/validate-comments-<target>.html` as an Artifact. A re-run
  republishes to the URL in `<dossier>/tools/README.md`'s page table.
- Then `mv <run>/state.next.json <run>/state.json`: the next run compares
  against what was published, not against an unfinished run.
- Add a row to `<dossier>/tools/README.md`'s page table (create the file with
  the render command if absent).
- If a task matched: `wb append <task> Handoffs "validate-comments page: <path> — <url>"`.
- Chat summary: the path and the URL, the verdict counts, the comments most
  worth changing, any `moved`/`gone`, and the worktrees created, with an offer
  to remove them (`git worktree remove`). Don't remove anything unasked.

## Re-run

Same invocation after Jet edits drafts or the author pushes. Stages 1–4 run
again; the script reads `<run>/state.json` and marks `changed` only for
comments that are new, whose `updated_at` moved, or whose file changed between
the previously checked head and the current one. Judge only those. Keep every
other card as it was in the page source, list `removed` comment numbers, and
open the page with a `**Changed since last check:**` line naming what was
re-checked and why. Re-run the gap pass only when the head moved.

## Learnings ledger

Append one dated line to `<skill>/learnings.md` when a run surprises: a
mapping the script got wrong, a misread comment, a page Jet found unhelpful.
For a Sportable target, write that line to `<dossier>/validate-comments/learnings.md`
instead, and add a line to `<skill>/learnings.md` only for a lesson that
changes the skill, with no repo, PR, commit, path or comment detail: the skill
lives in dotfiles, which will become public.
