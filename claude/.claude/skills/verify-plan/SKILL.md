---
name: verify-plan
description: Before a non-trivial task is planned, shape with Jet how it will be
  proven, and keep one verification document for it in the task's dossier
  through four stages - shaping, the agreed coverage map and walkthrough, the
  walkthrough run, results. Writes numbered requirements when none exist,
  proposes tests per requirement in four lanes (unit, integration, end-to-end,
  your walkthrough), puts Jet's choices to him through `/decide`, and generates
  a shaping page and a map page from the document. Use when Jet types
  `/verify-plan`, says "how will we prove this", "verification plan", "test
  strategy for this", "what will I check by hand", "walkthrough for this PR",
  or before `/ce-plan` on work with a user-facing surface. NOT for writing the
  tests themselves (`/ce-work` does that), nor for checking shipped behaviour
  in real use (that's `checks.md` and the verify-behaviour watcher), nor for a
  one-line fix.
---

# verify-plan

One verification document per task, `verify/verify.json` in the task's
dossier, taken through four stages:

1. **Shaping.** Numbered requirements, why each matters and how it could be
   wrong while tests pass, a proposed coverage grid, proposed tests and a
   walkthrough outline. Jet's choices are put to him through `/decide`.
2. **Map.** The agreed tests per requirement in four lanes, and the
   walkthrough Jet will run. This is what `/ce-plan` plans against.
3. **Run.** After code review, Jet runs the walkthrough on a published page
   and submits his step outcomes and pasted output.
4. **Results.** Each step passed, failed, skipped or not run, and each test
   planned or built. Close-out treats these as claims to prove.

Every page is generated from the document; the document is what gets edited.

## When to use

(Filled in by U6 of the plan, `docs/plans/2026-11-15-1147-feat-verify-plan-skill-plan.md`.)

## Process

(Filled in by U6.)

## Learnings ledger

Append one dated line to `learnings.md` whenever Jet flags a verification
document, page or walkthrough as unhelpful, confusing or wrong, in his own
words. Never copy work content into it.
