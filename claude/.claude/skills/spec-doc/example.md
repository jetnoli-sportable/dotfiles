# spec-doc — worked example

The same slice (a batch pipeline's "artifact layer": stages read and write
files in a per-run folder instead of sharing an in-memory object) written in
the `spec-doc` shape. Trimmed to a page; a real spec would carry more
invariants and stories.

The composition was chosen after writing this slice in four formats — Warp
`write-product-spec`, mattpocock `to-spec`, addyosmani
`spec-driven-development`, github/awesome-copilot `prd` — and comparing:

| | Warp | to-spec | spec-driven-dev | awesome-copilot |
|---|---|---|---|---|
| Load-bearing section | Behavior invariants | User stories + seams | Capability map + boundaries | Success KPIs |
| Best at | Acceptance bar a reviewer can test | Where to test; fast synthesis | Ordering a multi-module initiative | Exec-readable summary |
| Weakest at | Multi-module ordering | Behaviour precision; needs tracker setup | Onboarding boilerplate crowds the spec | Personas/KPIs forced for a pipeline |
| Reader it serves | Reviewer, implementer | Implementing agent | Planner | Stakeholder |

Kept: Warp's skeleton and invariants, to-spec's process and stories and
seams. Dropped: capability map (lives in `wb` task dependencies, not the
spec), KPIs/personas, commands/code-style sections.

---

# Pipeline artifact layer — requirements

## Summary

Every pipeline stage reads its inputs from files in a per-run folder and
writes its outputs there. The shared parse runs once per run and is saved as
a file all later stages read. No stage depends on another stage's in-memory
state.

## Non-goals

Splitting stages into separate executions. Changing any stage's numeric
output. Changing the destinations stages feed or what is written to them.
Porting any stage to another language.

## User Stories

1. As a developer, I want to run one stage from a saved parse in seconds,
   so that I can iterate without a full pipeline run.
2. As a developer, I want to diff two runs, so that I can prove a refactor
   changed nothing before merging it.
3. As the batch job, I want to skip a stage whose output already exists
   with unchanged inputs, so that a crashed run resumes instead of restarts.
4. As the batch job, I want a missing input to fail with the file's name,
   so that a partial run is diagnosable from the manifest alone.
5. As the load step, I want to write destinations from the run folder, so
   that a re-send is a copy rather than a recompute.
6. As an on-call engineer, I want one manifest per run, so that I can tell
   "this stage failed" from "this stage did not apply".
7. As a stage author, I want to own exactly one versioned feature-layer
   file, so that two stages can never compute the same thing differently.
8. As the orchestrator, I want each branch to load the parse artifact
   rather than re-parse, so that N branches cost one parse.

## Behavior

1. A run is identified by a run id. All files a run reads or writes live
   under one folder named by that id. Two runs never share a folder.
2. The shared parse produces a saved artifact in the run folder, named by
   the parse code version and a hash of its inputs.
3. Every stage that today adopts the in-memory parse reads the artifact
   instead. A stage that cannot find it fails naming the missing file; it
   does not fall back to a private re-parse.
   - **Open question:** two stages also read the raw source frame today.
     Second artifact, or keep reading the source directly?
4. Values stages write onto shared objects today each become a named,
   versioned file owned by exactly one stage. A requester that finds it
   absent fails as in (3).
5. Running a stage whose output exists with matching input hashes and stage
   version writes nothing, exits success, and is recorded `skipped`.
6. Deleting a stage's output and re-running re-executes that stage and
   every stage downstream of it, and nothing else.
7. Each run folder has a manifest listing per stage: outcome (`succeeded`,
   `skipped`, `not-applicable`, `failed`), timings, input hashes, output
   names, stage version.
8. A stage that does not apply to the run's kind reports `not-applicable`
   and produces no files. This is a normal outcome, not a failure.
9. For any fixture, outputs under this design are numerically identical
   (within fixture tolerance) to today's for the same stage. A diff
   command compares two run folders per stage and column; zero differences
   is the acceptance bar for every stage ported.
10. Destinations are written from the run folder in a separate load step.
    Re-loading re-reads files; it never re-runs a stage.
11. Behaviour is identical on a developer machine and in the batch job.
    The same command runs both.

## Test Seams

One seam: **the run folder.** Every invariant is tested by placing input
files in a folder, running a stage or the diff command, and comparing output
files against fixtures. No seam inside a stage. Reuses the existing
per-session fixture directory and its regeneration flow; the half-built
visual diff mode is the starting point for the diff command.

Chosen over per-stage unit seams because the invariants are about files,
skips and manifests, none of which exist inside a stage.

## Open Questions

- Artifact retention: how long do run folders live, and who owns the
  lifecycle rule? (platform owner)
- Does the manifest replace the current completion signal downstream
  consumers watch for, or sit alongside it? (downstream owner)
