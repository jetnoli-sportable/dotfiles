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
