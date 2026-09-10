---
name: decision-buffer
description: Route work into a markdown doc the user answers asynchronously in
  nvim — a settled choice between named options, a findings/audit
  review needing a reaction, a clarifying interview, an
  execute-and-paste checklist, a batch of facts to confirm, or
  code-review triage — instead of blocking the turn on chat
  back-and-forth or firing an AskUserQuestion menu. Use once the
  direction is basically agreed and what's left needs a written,
  async answer, or when Jet says "decision doc", "open a buffer for
  this", "put this in a buffer", "which approach", or invokes
  /decision-buffer.
---

# Decision Buffer

Route a decision, review, or checklist into a markdown doc the user edits in
nvim instead of AskUserQuestion. Checked checkboxes and inline notes in the
closed buffer ARE the answer — never also fire AskUserQuestion for the same
ground.

## 1. Align first, in chat — before any buffer

Before writing anything, present findings and a proposed direction in chat and
ask whether the remaining open points should go to a buffer. Never open a
buffer as the first move, even when a task file's "first action: decision
buffer" line says to — that line does not bypass this check; align first,
buffer second.

Three outcomes:

- **Jet waves it through, or answers directly.** Proceed accordingly — open a
  buffer only if something genuinely needing a written async answer remains;
  otherwise just act on the chat answer.
- **Jet replies with a question.** Answer it in chat. Do NOT open a buffer on
  the same turn — re-ask alignment in one line on a later turn instead.
- **Jet doesn't reply** (turn ends, or gets interrupted). Treat this as
  not-aligned. Do not open a buffer on the next turn without re-asking
  alignment first.

A spike or scoping task defaults to a findings-review or interview buffer
here, never straight to a choice buffer — jumping to
options-and-recommendation before the ground is even understood is the
repeated wrong-tool pattern (2026-09-04: a scoping spike got an options buffer
twice) this rewrite exists to fix.

## 2. Pick a shape

After alignment, choose the shape by the kind of answer needed. Each is a
self-contained reference file with its own close-contract header — load ONLY
the one selected, never inline a template here:

| Shape | File | Used for |
|---|---|---|
| Choice | `references/shapes/choice.md` | A settled decision between named options |
| Findings review | `references/shapes/findings-review.md` | Reacting to claims: agree / disagree / dig deeper / out of scope |
| Clarifying interview | `references/shapes/interview.md` | Free-text answers to open questions, agent states a default |
| Paste target | `references/shapes/paste-target.md` | An async execute-and-paste loop |
| Confirm-facts | `references/shapes/confirm-facts.md` | Ticking a small batch of true/false statements |
| Code-review triage | `references/shapes/code-review-triage.md` | Apply / Defer / Skip per finding |

## 3. Every question states why, and its stage

Standing rule across all six shapes: every question in a buffer states why
it's being asked and which stage it belongs to (planning, review, scoping,
etc.) — never a bare question with no framing. A code-level question asked
during planning carries the relevant code excerpt and enough context to judge
it without opening files — e.g. a question asking which of two functions
should own a check includes both functions' bodies and the downstream
consequence of each answer, right there inline.

## 4. Mechanism

The skill opens the doc by calling `scripts/open-buffer.sh <path>` (default
`--tmux`, falling back to `--terminal` outside tmux, `--manual` if neither is
available) as a **backgrounded** Bash call (`run_in_background: true`) — never
foreground; the tool-call timeout would kill it before Jet ever closes the
buffer. See `references/mechanism.md` for the full state-file field contract,
the fallback-tier rationale, and the `--reattach` recovery decision tree —
that content is not re-derived here.

## 5. Runtime check before opening

Before calling the script or loading a shape reference, confirm
`scripts/open-buffer.sh` exists and is executable, and that the selected
shape's reference file exists. If either is missing, report the exact fix —
`stow --no-folding -t "$HOME" claude` — and STOP. Do not fall back to
hand-writing the tmux recipe from memory.

## 6. Parse rules

- **Tick-line grammar.** A real answer is a checkbox-pattern line (`- [ ]` /
  `- [x]` and variants) that is OUTSIDE any fenced code block, blockquote, or
  HTML comment, and BELOW the doc's first section heading. A literal `[x]`
  inside instructional or example text (the header blockquote, a template
  fragment) is never counted as an answer.
- **`Closing because:` is read first and controls everything else.** A reason
  that signals abort ("too early", "wrong shape", "ignore", "let's talk")
  means nothing is applied; any ticks present are echoed back as "you also
  ticked X — carry into the next round?" rather than acted on. Any other
  reason proceeds to the normal notes-then-ticks handling below. An ambiguous
  reason is asked about in chat before anything is applied.
- **Silent close is defined by content hash, not by absence of ticks.** A
  silent close means the file's content is unchanged from what the agent wrote
  — compared against the hash recorded when the buffer opened (`content_hash`
  in the state file, per `references/mechanism.md`) — with no `Closing
  because:` line. A silent close applies nothing in any shape; report that and
  continue in chat. Any diff from the recorded content — an edited fact, a
  reordered option, a struck-through line, not only a tick or a note — counts
  as a note and is acknowledged, never treated as silence.
- **Notes are answered before any selection is acted on.** In a shape with an
  approve gate (built in a later unit — see wb-breakdown/wb-jira-create
  proposal buffers), a note requesting a change means the approve tick is not
  acted on until the note is resolved and the buffer is reopened.
- **Parsing only happens when the wait actually completes.** The buffer is
  parsed only when the background wait (or a `--reattach`) completes, or Jet
  explicitly says the buffer is closed. An unrelated message arriving while
  the recorded pane is still open is answered on its own terms — restate that
  the buffer is still open, don't treat the message as a close.

## 7. Iterate — rewrite fresh, don't append

When another round is warranted, don't append `> **answer:**` blockquotes onto
the existing structure — that turns a buffer into an unreadable stack of
appended rounds. Rewrite the doc fresh each round instead:

- Clearly resolved decisions collapse into a compact `## Decisions made`
  summary at the top — one bullet per decision, what was decided and a
  one-line why. Drop their full options/pros/cons scaffolding; it already did
  its job.
- Still-open items keep their full appropriate form in the body below the
  summary, exactly as before.
- Seed `## Decisions made` with an instruction that Jet can flag anything
  wrong about it inline — a summary is a claim to verify, not a fait accompli.
- If the whole doc resolves to zero open items, don't reopen it — report
  completion in chat instead.

## 8. Afterwards — fold, then move per where it was opened

At close, answers are folded into the task file or plan — the buffer's own
wording is deliberately rough (written fast, for a quick answer) and is never
treated as the polished, final record. The fold-in is what's authoritative;
the buffer file itself is never cited as the source of truth once its answers
are folded.

Where the raw buffer file then goes depends on where it was opened:

- A buffer in an employer repo's tracked `docs/decisions/` stays in place with
  a one-line "Folded into: `<path>`" note (no `git mv` — that history is the
  record).
- A buffer in an employer repo's gitignored `logs/decisions/` also stays in
  that repo, with the same note — employer-repo content never lands on a
  personal surface.
- A buffer in the personal dotfiles repo's `logs/decisions/` moves into the
  current task's dossier under `decision-records/` (created if absent).
- A buffer already written inside a dossier is left as-is.

## 9. Two standing rules, written explicitly

- **Self-contained / glossary discipline.** Define any coined term, piece of
  jargon, or bare cross-reference (a "§2", "the tripwire", a term from a doc
  the reader hasn't necessarily seen recently) inline, at first use, in every
  buffer — never assume the reader remembers something from earlier in the doc
  or from a different doc.
- **A buffer is rough, never the durable record.** A buffer's wording is
  deliberately rough — written for a fast answer, not polished prose. It gets
  folded into a plan's own decisions section, a task file, or a purpose-built
  decisions doc, then treated as scratch (moved/archived per §8), never kept
  as-is as the final wording.

## 10. Feedback ledger

`learnings.md`, beside this file, receives one dated line — Jet's own words
plus the buffer path — every time Jet flags a buffer as unhelpful in-session.
Append to it rather than losing the signal; it's the running record of what to
fix next.

## 11. Companion HTML — only when it earns its place

Write a companion HTML doc at the same path (`.html` in place of `.md`) only
when a lot of extra context is needed, or the buffer's questions aren't
self-describing — a choice buffer with substantial background, or a findings
review spanning a lot of source material. Never for interview, paste-target,
or confirm-facts shapes: free text, paste-and-verify, and plain fact ticks are
inherently self-describing and don't benefit from a companion doc. When one is
warranted, follow the `artifact-design` skill for the HTML's own visual
conventions rather than restating them here — mention its absolute path once,
alongside the buffer-open message, so Jet can open it in a browser at their
own pace; it's read-only reference material, not routed through the nvim
buffer flow.

