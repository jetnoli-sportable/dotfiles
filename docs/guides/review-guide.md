---
title: review-guide
status: current
tile: Turn a big PR or a stack of PRs into one page that says what changed, how risky it is, where to focus, what to skim, and whether each design decision holds up.
group: skills
kind: guide
updated: 2026-10-22
---

## Overview

A large PR, or a stack of PRs that build on each other, gives a reviewer
thousands of changed lines and no map. Attention spreads evenly over generated
files, fixtures and the few lines that can actually break something.
`/review-guide` reads the change first and publishes one page with four parts:

- **A. Overview:** why the change matters, an at-a-glance table (PR, size,
  plan, task), a component table pointing each part at where to look, scope,
  impact and risk, and a short "how it got here" of the review rounds.
- **B. Review focus:** ranked hotspots, a reading order, what can be skimmed
  (with the grounds for skimming it), whether the explanation is in proportion
  to the change, and "simplify before merge" notes.
- **C. Explainer:** each critical design decision, with a diagram and real code.
- **D. Design evaluation:** each decision against at least two real
  alternatives, with a recommendation.

It is not a line-by-line review; that stays with `/ce-code-review`. It posts no
PR comments; the page is the only output.

## How to run it

Type it yourself; the model never starts it on its own, because one run costs
seven or more agents, one of them Opus.

```text
/review-guide 95                 # one PR, number or URL
/review-guide 541 543 544        # a stack, base PR first
/review-guide development..feat/c
/review-guide fix/capture-handback-none   # a branch with no PR yet
```

`gh` is used for Sportable-owned repos and `pgh` for everything else, judged by
the `origin` remote. A stack whose PRs don't chain (each PR's base must be the
previous PR's branch, or the default branch once the previous PR has merged)
stops with a message naming the break. A stack of more than 5 PRs stops and
asks first, since it would use more than 10 agents.

## What happens

Nine stages, each writing a file to the run directory
`<dossier>/review-guide/<target>/` (kept, so a re-run can reuse stages and every
claim on the page is traceable):

1. **Resolve** the commits once and pin them (`target.json`), and create a
   detached worktree per PR head in the target repo so agents read exactly the
   code under review.
2. **Gather** the intent (PR body, commits, the matching task file, the Jira
   ticket) and the repo's rules (`context.md`).
3. **Inventory** every changed line into buckets and hot flags by script
   (`inventory.json`).
4. **Brief** the agents from one shared pack.
5. **Dispatch** five Sonnet lenses (L1 risk, L2 design, L3 intent, L4 tests,
   L5 reuse) and one Opus coordinator's quick pass, in parallel. In a stack, L1
   runs once per PR.
6. **Verify:** a script checks every finding's quoted excerpt is really at its
   cited line; the coordinator then tries to refute each medium-or-higher
   finding, merges duplicates, and checks spots no lens covered; the script
   checks again.
7. **Synthesise** the page (this session), then a **clarity sweep**: one
   Sonnet agent reads it cold and proposes rewrites for anything not explained
   where it's used (a bare "R1", a ticket key, a SHA), for jargon or
   overlong sentences, and for length: cuts for what the reader doesn't need,
   and collapsed toggle blocks for detail that helps but isn't needed. This
   session accepts or rejects each, and a script applies them without letting
   a finding id go missing or hiding a finding in a toggle.
8. **Render** the Markdown source to HTML.
9. **Deliver:** publish as an Artifact, note it in the dossier's
   `tools/README.md` and the task's handoffs.

## Where the page lands

In the dossier of the task whose `branch:` matches; otherwise
`~/code/tasks/dossiers/<repo>--pr<N>/`, or `<repo>--<branch-slug>/` for a branch
with no PR. Never dotfiles `docs/`, and Sportable work never on a personal
surface. The Markdown (`review-guide-<target>.md`) is the source; the HTML is
generated from it. The chat summary names both the path and the URL, and lists
the review worktrees it created with an offer to remove them.

## Files

- `claude/.claude/skills/review-guide/SKILL.md`: the stages.
- `references/briefs.md`: lens and coordinator instructions and the finding
  schema.
- `references/clarity.md`: the clarity sweep's instructions.
- `scripts/inventory.py`, `scripts/cite_check.py`, `scripts/build-page.py`,
  `scripts/apply_edits.py`,
  each with a `.test.sh` beside it.
- `scripts/mdpage.py` and `templates/page.template.html`: the Markdown-to-page
  core and page shell that `build-page.py` and pragmatic-review's own
  `build-page.py` share. A change here changes both skills' pages; run both
  skills' `build-page.test.sh`.
