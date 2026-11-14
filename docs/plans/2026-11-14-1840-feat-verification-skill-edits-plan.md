---
title: Verification skill edits - Plan
type: feat
date: 2026-11-14
artifact_contract: ce-unified-plan/v1
product_contract_source: ce-plan-bootstrap
execution: code
---

# Verification skill edits - Plan

## Goal Capsule

- **Objective:** a branch reaches code review with its comments already trimmed to real intent, a task is only called done when each completion claim has been proved by a command run at close, and every save says in one line whether the work has drifted from what the task was scoped for.
- **Means:** three skill-text edits plus one global instruction line: a new `/haircut` skill (KTD1, KTD2), a prove-it step in `/close-out` (KTD3), and a drift line in `/wb-save` (KTD4).
- **Authority:** the task file `dotfiles--verification-skill-edits` and its decision records of 14 Nov 2026 win over this plan; this plan wins over the child task files where they differ (the child prove-before-done task still names the retired `wb-done` skill).
- **Stop conditions:** stop and ask if any edit seems to need a `wb.sh` change or a Claude Code hook; both are out of scope.
- **Execution profile:** text-only edits to skill and instruction Markdown; no code, no automated tests. Proof is the docgen pre-commit passing and the hands-on test guide.
- **Who ships:** one branch (`verification-skill-edits`), one PR against `development`; code review runs in a fresh context after `/wb-save`.

## Product Contract

### Summary

Add `/haircut`, a comment-only sweep of the branch diff, and make it run before code review without being asked. Add a step to `/close-out` that proves each completion claim with a command run at close, keeps the result as a dossier page, and stops the wind-down on a false claim. Add a drift line to every `/wb-save` handoff.

### Problem Frame

Three gaps in the verification family (`dotfiles--verification-workflow`). Jet trims comments by hand before most reviews by asking for a comment sweep. Agents claim "done, tests pass, installed X" and the claim is only checked later; on 17 Oct two unchecked research-agent claims were relayed and both were wrong. Alignment with the parent's plan is checked before a task and at its end, never from inside a task someone has been heads-down in.

### Requirements

**/haircut**
- R1. `/haircut` changes only comment lines added or changed on the branch (committed since the merge base with the default branch, plus uncommitted work); it never edits code and never touches comments that predate the branch.
- R2. It removes comments that restate the code when the code reads clearly without them, change narration, references to the session, plan or task, commented-out code, and links to anything other than reference documentation.
- R3. A comment explaining what code does, where the code does not read clearly without it, stays, and the code is reported as a rework or simplification candidate; in a wb session each candidate also becomes a task follow-up.
- R4. It keeps why/intent, workarounds with their cause, invariants, links to reference documentation, license headers, and any comment a tool reads (directives, doc generators, help text).
- R5. Its changes land as one separate commit, followed by a short report of what was removed, kept and flagged.
- R6. `/haircut` runs after implementation and before code review without being asked, whenever review runs through `ce-work`'s shipping step.

**/close-out proof**
- R7. Before `wb down` or `wb done`, `/close-out` lists every completion claim the session is about to make, each with a command run at that moment and its result.
- R8. A claim with no proving command is dropped from the claims and reported as unproven; hedged wording ("should work", "probably") and a subagent's success report count as claims needing proof.
- R9. A claim whose command shows it false stops `/close-out` before the exit step.
- R10. The table is shown in chat and written as a page in the task's dossier.

**/wb-save drift line**
- R11. Every `/wb-save` handoff carries one `**Drift:**` line comparing the session's work with the parent's current rung (or the parent's `## Now`), the task's `rung:`, its brief's "Done when" and "Not doing", and the family's `concepts.md`.
- R12. On drift the save's reply also says so; the drift check never blocks the save and never changes scope.

### Key Decisions

- **`/haircut` keep/remove rules as Jet set them on 14 Nov** (links only to reference docs; self-describing code loses its restating comment, otherwise the code is flagged). Governs R2, R3, R4. (session-settled: user-directed — chosen over letting `/haircut` rewrite code to make it self-describing: it must stay a comment-only sweep that is safe to run unasked)
- **Unasked trigger now through `ce-work`, enforced gate later in the hooks session.** Governs R6. (session-settled: user-approved — chosen over a hook at the end of a `ce-work` pass and over running it from `/wb-save`: Claude Code has no "skill finished" event, and `/wb-save` only covers reviews set up through a save)
- **Evidence table kept as a dossier page.** Governs R10. (session-settled: user-approved — chosen over chat only: chat is gone once `wb done` removes the worktree or `--close` ends the session, so a later "was this ever proved?" has no answer)

### Scope Boundaries

- No Claude Code hook. The review-start gate (`PreToolUse` on the Skill tool matching `ce-code-review`, plus `UserPromptSubmit` for a typed `/ce-code-review`) is recorded as a follow-up on `dotfiles--feat-auto-stamp-reviewed` for the hooks session.
- No `wb.sh` change, no new `wb` verb.
- No acceptance-criteria skill (the family's lead task) and no separate `/on-track` skill.
- `/haircut` does not sweep prose files (`.md`, skill text); those are writing, not code comments.

---

## Planning Contract

### Key Technical Decisions

- KTD1. **`/haircut` is a standalone skill whose rules live only in its own `SKILL.md`.** The `CLAUDE.md` line and any later hook point at it rather than restating the rules, so the rules drift in one place. Implements R1-R5.
- KTD2. **The unasked trigger is one line in the global instructions (`claude/.claude/CLAUDE.md`) aimed at `ce-work`'s shipping step.** `ce-work`'s shipping workflow, step 2 ("Simplify"), applies "the project's simplification threshold when one is specified" from the instructions in context before code review, and its step 3 runs `ce-code-review`; a global instruction saying "after simplification and before any code review, run `/haircut` on the branch diff" lands in that gap. It also covers hand-run reviews when the agent follows its instructions. Inherits the user-approved label of the trigger Key Decision; governs R6.
- KTD3. **The evidence page is a plain Markdown file in the dossier, written before the exit step: `evidence-<YYYY-MM-DD>.md` with `title:` and `tags: [evidence]` frontmatter.** The store treats dossier working docs as freely writable (`~/code/tasks/README.md`, "What goes where"); records (`decisions/`, `handoffs/`, `open-items/`) are the only files needing `wb` verbs. `wb views`' page index already lists any `*.md` at depth 2 or less and reads `title:`/`tags:` for grouping (`scripts/.config/scripts/tmux/wb.sh`, `_wb_index_pages`), so no `wb` change is needed. A same-day second close-out overwrites in place; it is the newer proof. Governs R10.
- KTD4. **`**Drift:**` goes first in the handoff entry, before `**Done:**`.** The run directive must stay directly after `**Next:**` (`/wb-save`, "Next-action directive") and `**Received:**` goes last. Both readers tolerate an extra field: `/wb-resume` reads the three named fields and the `run` block, and the board's preview prints Next, In flight, then "any other field", then Done (`wb.sh`, preview awk near the `emit("In flight", "")` call). Governs R11.
- KTD5. **`/close-out`'s proof runs as a new step between today's step 5 (other active work) and step 6 (the exit),** so it runs after decisions are folded and before anything is torn down; a false claim ends the turn the same way a `wb done` stop does. Governs R7-R9.

### Assumptions

- `ce-work` reads global `CLAUDE.md` instructions at its shipping step the same way it reads project instructions; both are in the session context.

---

## Implementation Units

### U1. The `/haircut` skill

- **Goal:** a skill that trims comments in the branch diff to real intent and flags code that needs its comment to be understood.
- **Requirements:** R1-R5; KTD1.
- **Dependencies:** none. Commit it first: the docgen pre-commit refuses any commit while a skill folder lacks `SKILL.md`.
- **Files:** create `claude/.claude/skills/haircut/SKILL.md`.
- **Approach:**
  1. Frontmatter description says only when to use it ("/haircut", "comment sweep", "trim the comments", "clean up comments before review", and the unasked run before code review).
  2. Scope section: resolve the default branch (`git symbolic-ref refs/remotes/origin/HEAD`, never hard-coded), take the merge base, collect comment lines added or changed in committed and uncommitted work; skip `.md`, generated, vendored and lock files.
  3. Rules section: the remove / keep / flag lists from R2-R4, each with one short example. "Comment a tool reads" names this repo's case: docgen takes the comment block above a keybind or alias and a script's first comment line as its index one-liner (`~/code/docgen/index.go`, `commentAbove` and `parseScripts`), plus shellcheck/eslint directives, `//go:build`, godoc on exported symbols.
  4. Edge cases: `#`-lines inside heredocs and strings are not comments; shebangs and encoding lines stay.
  5. Output: one commit holding only the sweep's own comment edits, then a report of removed / kept / flagged counts with each flag's `file:line`; in a wb session, one `wb append <task> Follow-ups -` per flagged spot. Uncommitted code changes in the same files stay unstaged and uncommitted (stage only the sweep's hunks, for example by applying a comment-only patch to the index); when a hunk cannot be separated from uncommitted code, stop and report the file instead of committing. Never use the shared stash.
  6. Test scenarios section in the skill, following the shape `close-out` and `wb-save` use.
- **Patterns to follow:** `claude/.claude/skills/close-out/SKILL.md` and `claude/.claude/skills/wb-save/SKILL.md` (Scope, Flow, Test scenarios, Notes sections).
- **Test scenarios** (written into the skill's own Test scenarios section and exercised by the test guide):
  - A branch adding `# increment the counter` above `count += 1`: the comment is removed.
  - A branch adding `# retry because the API returns 503 during deploys` above a retry loop: kept.
  - A branch adding `# see SW-1234` or a PR link: removed; `# see https://www.rfc-editor.org/rfc/rfc9110` kept.
  - A branch adding a tmux keybind with a comment above it in `tmux/`: kept (docgen reads it).
  - A dense regex with `# match YYYY-MM-DD or YYYY/MM/DD`: the code does not read clearly without it, so the comment stays and the line is flagged as a rework candidate.
  - A comment that predates the branch, on a line the branch did not touch: untouched.
  - A `#` line inside a heredoc: untouched.
  - No comments in the diff: reports "nothing to trim" and makes no commit.
  - Dirty tree with an uncommitted code edit in a file whose branch comment is trimmed: the haircut commit holds only the comment change and the code edit is still uncommitted afterwards.
- **Verification:** the skill appears in the docs index after docgen runs, and the test guide's haircut steps behave as the scenarios say.

### U2. The unasked trigger line

- **Goal:** `/haircut` runs after simplification and before code review without anyone asking.
- **Requirements:** R6; KTD2.
- **Dependencies:** U1.
- **Files:** modify `claude/.claude/CLAUDE.md`.
- **Approach:** a short new section next to "wb sessions → stamp reviews immediately": after implementation and any simplification pass, and before any code review (including `ce-work`'s shipping step), run `/haircut` on the branch diff and commit its result. Say that the review-start hook will enforce it later. Point at the skill for the rules; restate none.
- **Patterns to follow:** the existing `## <topic> → <rule>` sections in that file.
- **Test expectation:** none -- instruction text; the test guide checks it fires in a `ce-work` run.
- **Verification:** a `ce-work` run on a small branch runs `/haircut` between simplify and review without being asked.

### U3. The prove-it step in `/close-out`

- **Goal:** `/close-out` proves each completion claim before winding down, keeps the proof, and stops on a false claim.
- **Requirements:** R7-R10; KTD3, KTD5.
- **Dependencies:** none.
- **Files:** modify `claude/.claude/skills/close-out/SKILL.md`.
- **Approach:**
  1. New step between today's 5 and 6, renumbering the exit to 7 and fixing the in-text step references ("step 6" in the self-kill hazard section, "steps 2-4" / "step 5" near the end of the exit section).
  2. The step: gather claims from the session and from the closing message `/close-out` is about to give (PR open, tests passing, installed, stowed, docs regenerated, child task closed); run one proving command per claim now; build the table (claim, command, result, outcome); drop unproven claims into an "unproven" list; treat hedged wording and subagent reports as claims (R8).
  3. Write the table to `~/code/tasks/dossiers/<task>/evidence-<YYYY-MM-DD>.md` (KTD3) and show it in chat.
  4. On a false claim: say which, end the turn, do not run the exit (KTD5).
  5. The step covers only the closing session's own claims. When winding down other sessions (`wb done --close <session>`), it is skipped: the closing agent makes no completion claims for them beyond relaying `wb done`'s output.
  6. Update the Scope section (it now writes one dossier page) and add test scenarios. Renumber only `/close-out`'s own step references; its citations of `/wb-decide`'s steps 2b, 5, 6 and 7 stay as they are.
- **Patterns to follow:** the existing step layout and "On any stop: relay the message and end the turn" wording in the same file.
- **Test scenarios** (added to the skill's Test scenarios list):
  - All claims proved: the table is shown, the page written, the exit runs.
  - A claim with no possible command ("works well"): listed as unproven, not in the table's proved rows, exit still runs.
  - A false claim (a child task still `planned`): the table shows it, `/close-out` stops before `wb pr-open` and `wb done`.
  - A subagent's "DONE, tests pass" with no test run this session: the agent runs the tests or the claim is unproven.
  - A straight-line session that claims nothing beyond "PR is open": a one-row table.
  - Winding down two other finished sessions: no proof step and no evidence page for them; each `wb done --close <session>` result is relayed as today.
- **Verification:** the test guide's close-out step on a throwaway task produces the page and stops on a planted false claim.

### U4. The drift line in `/wb-save`

- **Goal:** every save states in one line whether the work still matches what the task was scoped for.
- **Requirements:** R11, R12; KTD4.
- **Dependencies:** none.
- **Files:** modify `claude/.claude/skills/wb-save/SKILL.md`.
- **Approach:**
  1. New step between today's 2 (shelf review) and 3 (compose), renumbering later steps and their in-text references.
  2. Inputs, read-only: the parent named by `parent:`; its dossier's `ladder.md` current rung and "Not in this rung", else its `## Now`; this task's `rung:` and `brief.md` "Done when" / "Not doing"; the top parent's `concepts.md`.
  3. Output: `**Drift:** none` or one concrete sentence naming what drifted and which line it conflicts with; with no parent and no brief, `**Drift:** nothing to check against`.
  4. Entry-format examples and the `wb append` heredoc examples gain the `**Drift:**` line first (KTD4); on drift the reply step (step 6 after renumbering) adds one sentence.
  5. Update the Scope section: it currently calls the propagate call "the one cross-session lookup"; name the drift check's read-only reads of the parent and `concepts.md` alongside it.
  6. Add test scenarios.
- **Patterns to follow:** the existing step and Test scenarios layout in the same file.
- **Test scenarios:**
  - Work matches the brief: `**Drift:** none`.
  - The session touched something the brief's "Not doing" lists (for this task: any `wb.sh` change): the line names it and the reply says so.
  - Parent with no `ladder.md`: falls back to the parent's `## Now`.
  - No parent and no brief: `**Drift:** nothing to check against`, the save proceeds.
  - Save with a `run` directive: `**Drift:**` first, the `run` block still directly after `**Next:**`, `**Received:**` last.
- **Verification:** a real `/wb-save` in this session's task writes the line, and `wb board`'s preview shows it among the other fields.

### U5. Test guide and PR

- **Goal:** Jet can try each change by hand, and the PR carries the same steps.
- **Requirements:** the task's done condition (merged with a test guide, docs index regenerated).
- **Dependencies:** U1-U4.
- **Files:** `~/code/tasks/dossiers/dotfiles--verification-skill-edits/test-guide.md`, its `tools/build.sh` and `tools/page-template.html` (copied from `dossiers/dotfiles--wb-old-path-deletion/tools/`), and the generated `test-guide.html`, published as an Artifact.
- **Approach:** one short section per change, each with the scenario to set up, what to run, and what to expect, taken from U1, U3 and U4's scenarios; the same steps go in the PR's "How to test" section.
- **Test expectation:** none -- documentation.
- **Verification:** the page builds, publishes, and its steps match the merged skill text.

---

## Verification Contract

| Check | How | Applies to |
|---|---|---|
| Docs index regenerated, skill folders complete | the dotfiles docgen pre-commit hook passes on each commit | U1-U4 |
| Skill text matches scenarios | read each skill's Test scenarios section against U1, U3, U4 | U1, U3, U4 |
| Hands-on behaviour | the test guide's steps, run by Jet | U1-U4 |
| `/haircut` on this PR's own diff | run `/haircut` before review; expect nothing to trim, since the diff is all Markdown | U1, U2 |

## Definition of Done

- U1-U4 committed on `verification-skill-edits`, with `haircut/SKILL.md` in the first commit.
- No change to `wb.sh` and no hook added.
- The test guide is published and its steps are in the PR's "How to test" section.
- The three child tasks (`dotfiles--feat-prove-before-done`, `dotfiles--skill-haircut`, `dotfiles--wb-save-drift-check`) are closed after merge.
- No leftover draft text or abandoned wording in the skill files.
