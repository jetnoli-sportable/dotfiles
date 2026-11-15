---
title: verify-plan
status: current
tile: Before planning, shape with Jet how a task will be proven, then run his walkthrough and record its results, from one verification document per task.
group: skills
kind: guide
updated: 2026-11-15
---

## Overview

Passing tests only prove what they were built to check, and nothing used to
show you what that was or where it stopped. `/verify-plan` runs before
`/ce-plan` and keeps one verification document per task,
`verify/verify.json` in the task's dossier. From it the skill generates two
pages:

- **The shaping page:** the numbered requirements, why each matters and how
  it could be wrong while tests pass, the proposed tests and walkthrough, and
  the choices that are yours, each answered through `/decide`.
- **The map page:** the agreed proof per requirement in four lanes (unit,
  integration, end-to-end, your walkthrough), the same tests by system part,
  and the walkthrough you run after code review.

When you submit the walkthrough, the session records each step's outcome in
the document, and `/close-out` treats them as claims to prove.

## When to use it

Before `/ce-plan` on non-trivial work, especially work with something you
will check by hand. Not for a one-line fix, and not for checking behaviour
that has already shipped (that is `checks.md` and the
[verify-behaviour](verify-behaviour.html) watcher).

## How a task goes through it

Everything is under `verify/` in the task's dossier. `verify.json` is the
source. The pages are generated from it and are never edited by hand.

1. **Requirements.** The skill uses a numbered list if the task has one.
   Otherwise it writes one, after agreeing with you where the behaviour will
   be tested.
2. **Shaping.** It reads the nearest test and the repo's test command, then
   checks the usual ways a test passes for the wrong reason: how a local run
   gets the caller's identity, what the real client sends, whether a "cheap to
   reuse" test layer is reachable, what else could make a gating test pass,
   and whether every entry point of a gate is covered. It lists what it
   checked and what it could not. It then builds the shaping page.
3. **Decisions.** Your choices (how you will see it working, where the main
   automated proof sits, what to do about an untested requirement) go through
   `/decide`. Each answer is recorded with `wb decision` and written back into
   the document. To change one later, press "Change in /decide" on the page,
   which copies `/verify-plan`.
4. **Map and hand-off.** When no decision is open, the map page shows the
   agreed proof. The skill then offers `/ce-plan` with the document's path.
   Walkthrough needs become planned work, and each agreed test becomes
   proof-first work citing its requirement.
5. **Run.** After code review the skill marks each test built or planned and
   publishes the map page. You run the walkthrough, tick the steps, paste
   output and press Submit. A partial run can be continued later.
6. **Results.** The skill exports your state into `verify/run-state/`,
   records it in the document and republishes the page. For each requirement
   marked lasting it offers a draft live check for the task's `checks.md`.

## Commands

```bash
S=~/.claude/skills/verify-plan/scripts/verify-plan.py
python3 $S check  <dossier>/verify/verify.json
python3 $S build  <dossier>/verify/verify.json
python3 $S record-run <dossier>/verify/verify.json <dossier>/verify/run-state
```

`check` runs after every edit of the source. `build` writes `shaping.html` and
`map.html` beside it.

## The PR's "How to test"

The PR's "How to test" section is taken from the walkthrough, step by step.
This replaces the separate hands-on test guide.
