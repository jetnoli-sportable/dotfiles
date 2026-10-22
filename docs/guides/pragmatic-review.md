---
title: pragmatic-review
status: current
tile: Reorder a long-term plan so real use comes first, and give every step a needed-now / later / not-needed verdict judged against the business's real size.
group: skills
kind: guide
updated: 2026-10-22
---

## Overview

`/pragmatic-review` reviews a long-term plan, a version ladder or a wb task
family for two things. First, and mainly, **order**: plans written by agents
tend to follow textbook order, so hardening lands before the first user, a
generic layer before its second consumer, and a step needs a later step's
output. The skill checks every step against seven ordering patterns and
proposes one revised order, with steps that can run side by side named as
parallel groups. Second, **size**: every step gets one verdict (needed now,
needed later with the event that would trigger it, not needed, or move),
judged against how big the business really is and what actually goes wrong
in it.

The skill starts knowing nothing about any business. Each run asks only the
questions its verdicts depend on, and keeps the answers you confirm in
`~/code/tasks/context/<business>/pragmatic-review-learnings.md`, so the next
run for the same business asks fewer. Nothing changes until you approve:
for a task family, approved reorders become `depends_on` edits and a
Decisions entry on the parent; the reviewed plan's text is never edited.

Not the tool for: whether a plan is coherent or feasible (`ce-doc-review`),
what a plan changes (the plan-diff view), or splitting one task into
children (`/wb-breakdown`).

## Try it now

Run it on a dotfiles plan:

```
/pragmatic-review docs/plans/2026-10-17-2223-feat-wb-go-store-and-task-page-plan.md
```

The skill lists the plan's units as steps, works out the business from the
repo's origin owner, asks a few questions in chat (or opens an interview
buffer if there are more than three), then writes
`pragmatic-review-<date>.md` into the plan's task dossier and opens a
verdict buffer. A standalone plan like this one has no task family, so the
review document is the whole output.

For a task family, name the parent's stem instead of a path:

```
/pragmatic-review <repo>--<parent-slug>
```

## Reference

| Part | What it does | Where |
|---|---|---|
| Targets | A plan file (`.md`/`.html`), a ladder doc in a task dossier, or a task family by parent stem | SKILL.md step 1 |
| Business key | From the target repo's origin owner; an unknown owner is asked once, never guessed | SKILL.md step 2 |
| Questions | Only what the verdicts depend on; 3 or fewer in chat, 4+ in an interview buffer; each names the steps it affects and its default if left blank | SKILL.md step 4 |
| Sequencing checks | Abstraction before its second consumer; hardening before first use; forward dependency; habit order over unblock-real-use order; false serialisation; buried prerequisite; step with no consumer | `references/sequencing-checks.md` |
| Sizing test | Needed only if leaving it out causes harm nobody catches in time, or adding it later is expensive (stored data, shared interface, money, security); plus the foundation rule and two traps (survival needs that look like polish, trust work timed to its consumer) | `references/sizing-test.md` |
| Review document | Revised order, one verdict per step, context used, changes to apply | the target's task dossier |
| Verdict surface | About 15 steps or more: review page (untouched row accepts its suggestion). Fewer: a decision-buffer with options per step, Defer and Skip last (silent close applies nothing) | SKILL.md step 8 |
| Another session's plan | When the owning task has a live session or an unfinished plan, the review is input only: per-step options in the review doc and a `wb append` pointer in the owner's `## Follow-ups`; nothing is applied | SKILL.md step 8 |
| Applying | Task families only: preflight for live sessions, `wb set <stem> depends_on <full list>`, one `wb append <parent> Decisions` entry | SKILL.md step 8 |
| Learnings | Facts (rewritten in place) and Calibration (append-only, one line per verdict you overrode); written only after you confirm | `~/code/tasks/context/README.md` |

Paths under `references/` are relative to
`claude/.claude/skills/pragmatic-review/`.

## Known rough edges

- **Thresholds are rough.** "About 15 steps" for the review page and
  "3 questions" for chat versus a buffer are first guesses; the first few
  runs will show whether they hold.
- **Live sessions block reorders.** `wb set` refuses a task whose session is
  running, so a reorder touching a live task stops at the preflight until
  that session is down.
- **Calibration promotion has no example yet.** The rule for turning a
  repeated calibration line into a Fact, or into a business-neutral edit to
  the references, hasn't been exercised by a real run.
- **Large families load into one session.** Step extraction happens in the
  main session. A family much larger than a dozen tasks may crowd it;
  a step-extractor subagent is a deferred follow-up for that case.

## Next steps / reverting

Next: share `references/sequencing-checks.md` with `/wb-breakdown` proposals
and `spec-doc`, so a breakdown is checked for order as it's written.

To turn it off, delete `claude/.claude/skills/pragmatic-review/` and re-stow.
The learnings files in `~/code/tasks/context/` stay where they are and are
harmless without the skill.
