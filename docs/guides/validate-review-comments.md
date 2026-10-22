---
title: validate-review-comments
status: current
tile: Before submitting a PR review, check each of your draft comments against the code, get a verdict and a reading for each, and see what you may have missed.
group: skills
kind: guide
updated: 2026-10-22
---

## Overview

A review comment that misreads the code costs the author a round trip and
costs the reviewer credibility; one that undersells a real bug lets it
through. The moment to catch both is after drafting comments and before
submitting them. `/validate-review-comments` reads your pending review (the
comments GitHub holds as drafts until you submit) and publishes one page:

- **Your comments:** for each draft, what it is taken to ask (stated first, so
  a misreading is visible), a verdict of agree, partly or drop with the code
  that settles it, whether the point is stronger or weaker than worded, and an
  optional rewording labelled as Claude's draft.
- **Worth raising:** a short gap pass (plan against code, API docs against
  code, missing tests), each item framed as "is this relevant now?".
- **Checked and fine:** what the gap pass looked at and cleared.

It never posts, edits or submits anything on GitHub; you submit the review
yourself. It is not a code review of the PR (`/ce-code-review`) and not a
pre-review orientation (`/review-guide`).

## How to run it

```text
/validate-review-comments 103             # one PR, number or URL
/validate-review-comments 541 543 544     # a stack, base PR first
```

The model may also start it from phrases like "check my draft comments".
`gh` is used for Sportable-owned repos and `pgh` for everything else, judged by
the `origin` remote. A run is one session with no subagents.

Run it again after editing drafts or after the author pushes: only comments
that are new, edited, or on a file that changed since the last check are
judged again, the rest keep their cards, and the page republishes to the same
URL.

## What happens

1. **Resolve** the PR or stack and create a detached worktree at each head,
   following `/review-guide`'s stage 1.
2. **Land** in the matching task's dossier, and read its plan and decisions.
3. **Fetch** your pending review's comments over `gh`/`pgh` into the run
   directory, `<dossier>/validate-comments/<target>/`.
4. **Map** them to code with `pending_comments.py`. GitHub gives pending
   comments no line number, so the script reads each comment's diff excerpt,
   which ends on the commented line. It flags a comment whose line moved or no
   longer exists at the head, and, for a stack, whether the line survives the
   later PRs.
5. **Judge** each comment: reading, verdict, evidence, stronger or weaker,
   draft.
6. **Gap pass**, at most about five items.
7. **Write** the page source, `validate-comments-<target>.md`.
8. **Render** it with `/review-guide`'s page builder, which shows each verdict
   as a coloured chip.
9. **Deliver:** publish as an Artifact, note it in the dossier's
   `tools/README.md` and the task's handoffs.

## Where the page lands

In the dossier of the task whose `branch:` matches; otherwise
`~/code/tasks/dossiers/<repo>--pr<N>/`. Never dotfiles `docs/`, and Sportable
work never on a personal surface. The Markdown is the source; the HTML is
generated from it.

## Files

- `claude/.claude/skills/validate-review-comments/SKILL.md`: the stages.
- `scripts/pending_comments.py`, with `pending_comments.test.sh` beside it:
  maps comments to code and tracks re-run state.
- The page builder and template are `/review-guide`'s
  (`claude/.claude/skills/review-guide/scripts/build-page.py`), found next to
  this skill at run time.
