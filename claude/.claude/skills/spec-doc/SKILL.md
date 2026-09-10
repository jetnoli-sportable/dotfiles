---
name: spec-doc
description: Write a requirements spec (PRD) for a non-trivial feature or restructure as a PRODUCT spec — Summary, Non-goals, User Stories, numbered testable Behavior invariants, Test Seams, Open Questions — synthesised from the current conversation and repo without an interview, then optionally a companion TECH spec via write-tech-spec. Use when the user asks for a PRD, spec, requirements doc, "something the team can read", or wants requirements pinned down before ce-doc-review / ce-plan / wb-breakdown. Not for trivial fixes, and not for implementation plans on their own (use ce-plan).
---

# spec-doc — requirements spec, synthesised, with seams

A composition of three vendored skills, taking the part of each that earned
its place when compared on the same content (see `example.md`):

- **Process** from mattpocock `to-spec`: no interview, synthesise what the
  conversation and repo already say; confirm the *test seams* before writing.
- **Shape** from Warp `write-product-spec`: numbered, testable Behavior
  invariants from the consumer's perspective, implementation kept out.
- **User Stories** from `to-spec`, kept because they name *who* wants each
  behaviour, which invariants alone do not.

The vendored skills stay unmodified; this file owns the composition. If it
disagrees with them, this file wins for `/spec-doc` invocations.

## When to use

- The work spans several modules or a migration, and someone who has not
  followed the discussion needs to read what is being built and why.
- Requirements are about to go through `ce-doc-review`, `ce-brainstorm`,
  `ce-plan` or `wb-breakdown` and need a single input document.
- Skip for single-module changes with an obvious approach; go straight to
  `ce-plan`.

## Process

1. **Do not interview.** Read the conversation, the task file, the dossier
   and the relevant code. Only ask when a gap would change the *shape* of
   the spec, not to fill in detail — unknown detail becomes an Open question.

2. **State the decided points first.** Before drafting, list in chat what
   the conversation has already settled (architecture choices, sequencing,
   non-goals) so the spec does not reopen them. If the user corrects the
   list, redraft from the corrected list.

3. **Sketch the test seams and confirm them.** Where will this be tested?
   Prefer existing seams over new ones, the highest seam possible, the
   fewest possible — ideally one. Present the seam(s) in one short
   paragraph and wait for a yes before writing the spec. A spec whose
   invariants cannot be tested at the agreed seam is not finished.

4. **Write the PRODUCT spec** using the template below. Land it at
   `docs/plans/<yyyy-mm-dd>-<slug>-spec.md` in the repo the code lives in
   (or the dossier when it is not tracked-worthy yet). Never scratch-only.

5. **Offer the TECH spec.** Once the product spec is agreed, invoke the
   vendored `write-tech-spec` for the same slug, overriding its path to
   `docs/plans/<yyyy-mm-dd>-<slug>-tech.md` and telling it to reference
   the product spec's invariant numbers in its Testing table. Do not write
   the verification table into the product spec.

## Template

```markdown
# <Feature> — requirements

## Summary
1–3 sentences: what changes and the outcome, from the consumer's view.

## Non-goals
What this explicitly does not do. Contested scope goes here, not in prose.

## User Stories
Numbered. `As a <actor>, I want <capability>, so that <benefit>.`
Actors may be systems (the cloud job, the finalise step) or roles (a DS
developer, an on-call engineer). Cover every consumer of the surface.

## Behavior
Numbered, testable invariants. Each one a sentence a reviewer could
turn into a test at the agreed seam. Cover: default flow, every state
and transition, inputs and responses, failure and missing-input states,
idempotence / re-run, things that must not regress. Inline
`**Open question:**` under the invariant it belongs to.

## Test Seams
Where the invariants are tested (not how). Name the seam(s), why they
were chosen over alternatives, and which existing fixtures or harnesses
are reused. Verification steps live in the TECH spec.

## Open Questions
Only questions not already inline. Each with who can answer it.
```

## Writing rules

- Consumer's perspective throughout. "Consumer" is whoever uses the
  surface: a caller, a job, a developer running a command — not only an
  end user.
- No implementation in Behavior: no module names, file paths, types or
  algorithms. Those belong in the TECH spec and go stale.
- No ticket numbers, PR numbers or scratch paths in the body (filename
  may carry the ticket). Describe deferred work inline.
- Decided vs open must be visible: a decision the user has made is stated
  as fact; anything still being clarified is an open question, never
  "assumed" or "will land".
- Behavior is the spec; keep Summary and Non-goals thin so its length
  reflects the feature, not the template.
- Plain words. Define coined terms at first use.

## Companion files

- `example.md` — the artifact-layer sample in this exact shape, plus the
  four-way format comparison that motivated the composition.

## Learnings

<!-- Append one-line observations (date — observation — source) when the
     template misses a section a real spec needed, a seam-confirmation
     step misfired, or the split with write-tech-spec proved wrong. -->
