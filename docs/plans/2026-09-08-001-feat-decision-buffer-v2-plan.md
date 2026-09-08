---
title: Decision Buffer v2 - Plan
type: feat
date: 2026-09-08
topic: decision-buffer-v2
artifact_contract: ce-unified-plan/v1
artifact_readiness: requirements-only
product_contract_source: ce-brainstorm
execution: code
---

# Decision Buffer v2 - Plan

## Goal Capsule

- **Objective:** Rebuild the `decision-buffer` skill so a buffer opens only after an align check, offers six shapes for six kinds of answer, never acts on a silent close, and shares one bundled open script with its dependents.
- **Product authority:** Jet, via the 2026-09-08 findings review, brainstorm interview, shape buffer and chat confirmation. Evidence in `~/code/tasks/dossiers/dotfiles--decision-buffer-skill-v2/` and `~/code/tasks/dossiers/dotfiles--decision-buffer-skill-audit/`.
- **Open blockers:** None. One deferred-to-planning question (Q1 below).

---

## Product Contract

### Summary

Rewrite the `decision-buffer` skill into one skill with three disclosure levels: a short body that asks "are we aligned, shall I take this to a buffer?" before opening anything and then selects a shape, per-shape reference files, and a bundled open script that the skill and wb.sh both call. Turn off recommendations by default, make a silent close apply nothing in every buffer including the two proposal buffers, and reword the handoff kickoff default and the global rule so neither fires a buffer before alignment.

### Problem Frame

The skill is Jet's most-used tool: 85 buffers across 72 of 127 recent work sessions. Its trigger is a format test, "I have 2+ options", and 75% of opens are the agent reaching for it unprompted after research lands. One buffer in four comes back with no box ticked and prose instead. On 2026-09-04 a scoping spike produced an options-and-recommendation buffer twice, and Jet asked why an investigation had jumped to decisions.

The audit found the mechanism sound and the sequence wrong. Jet's words: planning and brainstorming "has been managed as a single phase but should be broken down into 2. First align and then once direction is established ... we can ask clarifying questions or pop open a decision buffer." Secondary problems compound it. The same template is bent into findings reviews, SQL paste loops and fact confirmations. The tmux recipe is prose in five skills and code once. A silent close means "unanswered" in one skill and "approve everything" in two others. Two of Jet's rules live only in memory files. The handoff skill hard-codes "artifact + decision buffer" as every routed task's first action, which is how the spike got its kickoff line.

### Key Decisions

- **Align check before any buffer, as a question not a gate.** The agent presents findings and a proposed direction in chat, then asks whether to take the remaining points to a buffer. Jet can wave it through. Jet asked for "a happy middle ground between where we are now and what's being proposed." A hard gate was rejected.
- **One skill, three disclosure levels, name kept.** Body under 200 lines holding the align check, shape selection, close contract and parse rules. One reference file per shape. The open mechanism as a bundled script. This came from running the structural question through the skill-creator skill: two skills with near-identical descriptions would create a trigger near-miss pair, and a wb subcommand puts seven dependents and the test suite in the blast radius for nothing the script does not give. Advice at `~/code/tasks/dossiers/dotfiles--decision-buffer-skill-v2/2026-09-08-skill-creator-advice.md`.
- **Six shapes, chosen after alignment by the kind of answer needed.** Choice, findings review, clarifying interview, paste target, confirm-facts, code-review triage. Findings review and interview were dogfooded by hand in this task and worked. Paste target is blessed at Jet's request.
- **Recommendations off by default in every shape.** Jet: "off by default so accidental closes don't trigger actions." Leans go in chat. The 83% follow rate when a box was ticked is a known cost, tracked in the follow-up task.
- **A silent close never acts, in any buffer.** Every shape's header states what an unmarked close means. A `Closing because:` line at the foot lets Jet say why. The wb-breakdown and wb-jira-create proposal buffers gain an explicit approve tick in this task rather than a follow-up.
- **Fold at close, keep the raw buffer as scratch.** Answers are folded into the task file or plan. The raw buffer moves to the task dossier's `decision-records/` folder and is never cited as source of truth.
- **Companion HTML only when it earns its place.** Written when a lot of extra context is needed or the questions are not self-describing. Never for interview, paste or confirm shapes.
- **Feedback is a ledger, not a metric.** A `learnings.md` beside the skill collects one dated line per in-session "this buffer isn't helping" flag.
- **Code questions at planning stage stay, with context.** Not deferred. Jet: "the stage we are at should guide how the questions are asked ... I'll need clear context and code examples as I probably won't know exactly what we are referring to."

### Requirements

**Trigger and alignment**

- R1. The skill's trigger is intent-based: an answer is needed in writing, asynchronously, in Jet's editor, and the direction has been agreed. The "2+ options" clause is removed from the skill and from the global rule in the user's CLAUDE.md.
- R2. Before writing any buffer, the agent presents findings and a proposed direction in chat and asks whether to take the open points to a buffer. Jet may answer, redirect, or wave it through.
- R3. Every question in a buffer states why it is being asked and which stage it belongs to. A code-level question asked during planning carries the relevant code excerpt and enough context to judge it without opening files.
- R4. A task file's "first action: decision buffer" line does not bypass R2.

**Shapes**

- R5. The skill offers six shapes: choice, findings review, clarifying interview, paste target, confirm-facts, code-review triage. Shape is selected after alignment from the kind of answer needed, using a selection table in the skill body.
- R6. Each shape is a reference file loaded only when selected, holding its template and header text.
- R7. Every shape's header states what an unmarked or unchanged close means for that shape.
- R8. The choice shape carries no recommendation line unless Jet asks or the agent has a stated reason; nothing is ever pre-ticked.
- R9. The confirm-facts shape is limited to a small batch per buffer, because long fact lists overwhelm.
- R10. The paste-target shape presents each item as a query or step, a paste slot, and a verify line, and expects to be reopened per result.

**Close contract**

- R11. A silent close, meaning no tick and no note, applies nothing in any shape. The agent reports that nothing was applied and continues in chat.
- R12. Every buffer ends with a `Closing because:` line. When filled, the agent reads it before any tick or note.
- R13. Prose notes are answered before any selection is acted on.
- R14. The wb-breakdown and wb-jira-create proposal buffers require an explicit approve tick; an unchanged close applies nothing.

**Mechanism**

- R15. The tmux open recipe exists once, as a script bundled with the skill. The skill and wb.sh call that script; the four skills that currently carry prose copies point at it.
- R16. The script records its wait-channel beside the document when it opens. If the waiting process dies while the nvim pane is alive, the agent re-attaches to the recorded channel rather than opening a second buffer, and says so.
- R17. The open is always run in the background so the tool timeout cannot kill it.
- R18. If the pane is gone when the agent returns, the document on disk is read as-is and Jet is told the close was not deliberate.

**Upstream defaults and dependents**

- R19. The handoff skill's kickoff default becomes "present findings and direction, check alignment", followed by a shape chosen by task kind: spike or scoping tasks get a findings review or interview, settled plans get a choice.
- R20. The global rule in the user's CLAUDE.md is reworded to the intent trigger and the align check, and points at the skill for shapes.

**Records and feedback**

- R21. At close, answers are folded into the task file or plan, and the raw buffer plus any companion moves to the task dossier's `decision-records/` folder. The buffer is never cited as a decision record.
- R22. A `learnings.md` beside the skill receives one dated line, with Jet's words and the buffer path, each time Jet flags a buffer as unhelpful in session.
- R23. The two memory-only rules, self-contained plus glossary and buffer-is-rough-not-durable, are written into the skill as the first unit of work.
- R24. Companion HTML is written only when extra context is substantial or questions are not self-describing, and never for interview, paste or confirm shapes.

**Repo hygiene**

- R25. New files under the skill directory are made live by re-stowing the `claude` package, and the plan carries that step, because the package is stowed per-file.
- R26. The human guide, docgen index, and memory files that name the skill are updated to the new sections; the skill name is unchanged.

### Key Flows

- F1. Research lands and the agent has options
  - **Trigger:** Subagents return or the agent finishes reading.
  - **Steps:** Agent posts findings and a proposed direction in chat. Agent asks whether the direction holds and whether to take open points to a buffer. Jet answers or waves it through. Agent selects a shape and writes the buffer with a header stating the close contract. Script opens the split in the background and records its channel. Jet closes. Agent reads `Closing because:`, then notes, then ticks, and answers notes first. Answers are folded into the task or plan; the raw buffer moves to `decision-records/`.
  - **Covers:** R1 to R3, R5 to R8, R11 to R13, R15 to R17, R21.
- F2. The waiting process dies
  - **Trigger:** The background wait is killed by the system.
  - **Steps:** Agent checks whether the nvim pane is alive. If alive, it re-attaches a waiter to the recorded channel and tells Jet. If gone, it reads the document as-is and tells Jet the close was not deliberate.
  - **Covers:** R16, R18.
- F3. A task is routed via handoff
  - **Trigger:** The handoff skill seeds a task file.
  - **Steps:** The first action reads "present findings and direction, check alignment", then names a shape by task kind. The routed worker follows F1.
  - **Covers:** R4, R19.

### Acceptance Examples

- AE1. **Covers R2, R4.** Given a spike task whose file says "first action: decision buffer", when the worker picks it up, then it presents findings and direction in chat and asks about alignment before any buffer, and if a buffer follows it is a findings review or interview.
- AE2. **Covers R11, R12.** Given a choice buffer closed with no ticks, no notes and `Closing because: too early`, when the agent returns, then it applies nothing, quotes the reason, and returns to alignment in chat.
- AE3. **Covers R14.** Given a wb-breakdown proposal buffer closed unchanged, when the apply step runs, then no task files are written and the agent reports that nothing was applied.
- AE4. **Covers R16.** Given an open buffer whose background waiter is killed while nvim is still open, when the agent handles the kill, then it re-attaches to the recorded channel and no second buffer opens.
- AE5. **Covers R3.** Given a planning-stage buffer that asks which of two functions should own a check, when Jet reads it, then the question carries both function excerpts and the downstream consequence of each answer.
- AE6. **Covers R8.** Given a choice buffer where Jet did not ask for a recommendation, when it opens, then no option is pre-ticked and no recommendation line is present.

### Success Criteria

- No spike or scoping task receives a choice buffer as its first buffer.
- Every `learnings.md` entry names a specific buffer and Jet's words, and the file is the starting point of the next redesign.
- Zero-tick closes that are not crashes carry a `Closing because:` line.
- The tmux recipe appears in exactly one executable place.

### Scope Boundaries

- The tmux OOM root cause stays in `dotfiles--tmux-oom-crash-decision-log`.
- No change to tmux or nvim as the editor and split mechanism.
- The living-doc versus bloat tension and the rewrite-fresh rule are unchanged.
- Alignment as a session-wide rule for brainstorm and plan sessions that never open a buffer is deferred to `dotfiles--decision-buffer-v2-unsolved`, along with the other six gaps listed there.
- The broader UX of the seven dependent skills is untouched beyond R14 and R15.

### Dependencies / Assumptions

- The `claude` package is stowed with `--no-folding`, so `~/.claude/skills/decision-buffer/` is a directory of per-file symlinks and new files need a re-stow (verified in `install.sh`).
- `wb_open_buffer()` in `scripts/.config/scripts/tmux/wb.sh` is the only existing code implementation of the recipe and can become a shim that calls the bundled script.
- docgen indexes skills by name; keeping the name avoids an index collision.
- The user's CLAUDE.md is untracked; R20 is an edit to a file outside the repo and is recorded in the task file rather than a commit.

### Outstanding Questions

**Deferred to Planning**

- Q1. wb-done and parked-items also carry prose copies of the recipe. Migrate them to the script in this task, or leave them until next touched? Planning decides by the size of the diff.
- Q2. Whether the skill-creator description optimizer is run on the new description as a verification step, using early-question prompts as the should-not set.

### Sources / Research

- Audit dossier: `~/code/tasks/dossiers/dotfiles--decision-buffer-skill-audit/` (docs audit, two transcript audits, skill evolution, reopen causes).
- Task dossier: `~/code/tasks/dossiers/dotfiles--decision-buffer-skill-v2/` (findings review and overview, interview, shape decisions, skill-creator advice, system diff).
- Grounding quotes with line pointers: `/tmp/compound-engineering/ce-brainstorm/decision-buffer-v2/grounding.md` (session scratch; the current skill is `claude/.claude/skills/decision-buffer/SKILL.md`, the recipe copies are in `claude/.claude/skills/{wb-done,wb-breakdown,wb-jira-create,parked-items}/SKILL.md`, the code implementation is `wb_open_buffer()` in `scripts/.config/scripts/tmux/wb.sh`).
