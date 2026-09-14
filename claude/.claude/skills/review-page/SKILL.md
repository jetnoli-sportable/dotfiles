---
name: review-page
description: Serve a large batch of items — a task-store triage, a piece/skill
  audit, a prune list, a wb-breakdown proposal, a weekly review — as a
  locally-served HTML page with per-row evidence, a suggested verdict, free-text
  grouping, and per-row/global questions, instead of an unreadable 40+-checkbox
  nvim buffer. Use when Jet says "audit page", "review page", "put this on a
  page", "this is too big for a buffer", "let's go through these one by one", or
  when a review exceeds ~25 rows or needs defaults + grouping + questions at
  once. NOT for a settled choice between 2-4 options or a short interview —
  those stay in the `decision-buffer` skill.
---

# review-page

Serve a large review as a locally-hosted HTML page instead of an nvim buffer.
This skill split out of `decision-buffer`'s seventh shape (2026-09-14) once it
became clear the review-page mechanism — a spec file, an HTTP server, a
browser tab — is a genuinely different beast from the other six nvim-buffer
shapes, not just another entry in their table.

## When to use (vs decision-buffer)

Use `review-page` when a batch is too large or too structured for a markdown
buffer: **more than ~25 rows**, or when what's needed is per-row defaults (a
suggested verdict per item), free-text grouping, AND per-row questions all at
once. A markdown buffer with 40+ checkbox blocks is unreadable and slow to
scan.

Typical uses:

- Task-store triage (sweeping `~/code/tasks` for stale/duplicate/mis-scoped
  tasks)
- Piece/skill audits (reviewing every skill or workflow piece for
  keep/merge/retire)
- Prune lists (files, branches, dependencies flagged for removal)
- `wb-breakdown` proposals with many candidate child tasks
- The weekly review (`/parked-items` and similar recurring sweeps)

Stay in `decision-buffer` instead for:

- **A settled choice between 2-4 named options** — that's the `choice` shape;
  a review page's per-row machinery (evidence toggles, grouping, filters) is
  overkill for one decision.
- **A short interview** (free-text answers to a handful of open questions) —
  that's the `interview` shape; there's no batch of rows to triage.
- Any batch under ~25 items with no need for defaults/grouping/per-row
  questions — `findings-review` or `code-review-triage` handle those fine in
  an nvim buffer.

The ~25-row threshold is a guideline, not a hard gate — a 15-row batch that
genuinely needs per-row grouping and questions can still justify a page; a
30-row batch that's just a flat agree/disagree list might still fit
`findings-review`. Use judgement, and when in doubt, ask which the user
prefers.

## Align first

Same rule as `decision-buffer` SKILL.md §1: before building anything, present
findings and a proposed direction in chat, and confirm a page is wanted before
writing a spec or invoking the script. Never jump straight to a review page as
the first move — even when the batch is obviously large. Three outcomes,
identical to decision-buffer's:

- Jet waves it through, or answers directly in chat — proceed accordingly.
- Jet replies with a question — answer it in chat, don't open a page on the
  same turn.
- Jet doesn't reply — treat as not-aligned; re-ask before opening a page next
  turn.

## Build the spec

Rules learned building and running this mechanism (2026-09-14, see
`learnings.md`):

- **One row per item.** Don't collapse related items into one row hoping
  the user disentangles them — that's what `depends_on`/`depended_on_by` and
  `group` are for.
- **Every row carries evidence the user can check without opening files.**
  The `evidence` field (a string or list of strings, behind an "evidence"
  toggle) must contain enough — a code excerpt, a grep result, a timestamp,
  a linked PR — that the verdict can be judged from the page alone.
- **Exactly one suggested verdict per row, derived from evidence — or EMPTY
  when there is no signal.** `suggested: ""` means the page shows the row as
  "needs me" (no verdict pre-selected) and — per the close contract below —
  it stays unresolved even if left untouched. Never force a guess into
  `suggested` just to fill the field.
- **`suggested_reason` is at most one sentence.** State the reasoning, or say
  "unclear" explicitly if the evidence really doesn't point anywhere — don't
  pad it into a paragraph.
- **Verdict labels must be unambiguous.** Never a bare "Review" — say what
  reviewing means and who does it: e.g. `"Set status: review (PR open)"` vs
  `"Investigate — agent looks deeper"`. A user scanning 40 rows fast must be
  able to tell two verdicts apart from the label alone, without opening the
  reason.
- **A `group` tag means one verdict, one action for the whole set.** Only
  group rows the user should be able to treat identically — don't invent
  groups the evidence doesn't support.
- **Order areas by where the user's attention is most needed first.** Put
  the area with the most "needs me" / no-suggestion rows, or the highest-risk
  verdicts, at the top — don't default to filesystem or alphabetical order.
- **`intro_md` is at most 6 lines.** Cover exactly: what this page is, how to
  read a row, the close rule (see below — and it MUST state "leaving a row
  alone accepts its suggestion", not just link to it), and what happens after
  submit. Keep it terse; the per-row detail carries the rest.
- **`accept_defaults_default: true` on re-runs against mostly-untouched
  rows.** This is now also the spec-level default when the key is omitted at
  all (see Close contract) — set it to `false` explicitly only when you want
  the user to have to opt every row in by hand.

Full field-by-field spec format, verdict/area/item schema, and the answers
format are in `references/spec-and-close-contract.md` — load it before
writing a spec, don't reconstruct the JSON shape from memory.

## Open it

Invoke the script as a **backgrounded** Bash call (`run_in_background: true`)
— a foregrounded call sits inside the tool-call timeout and gets killed
before the page is ever submitted:

```bash
python3 claude/.claude/skills/review-page/scripts/review-page.py \
  --spec /path/to/spec.json --out /path/to/answers.json --title "Something Review"
# run_in_background: true — this blocks until the page POSTs /submit
```

- `--port auto` (the default) picks a free port — don't hardcode one unless
  there's a specific reason to.
- Served on `127.0.0.1`, not `file://` — snap-packaged Chromium can't open
  `file://` URLs under hidden directories (a documented environment
  limitation); serving over HTTP sidesteps this entirely, so it isn't a
  decision to revisit per use.
- It opens the browser itself (`/snap/bin/chromium` if present, else
  `xdg-open`) — don't also try to open one yourself.

## Close contract

**Headline rule (read this before anything else): no action on a row means
accept its suggested verdict.** Opt-out is explicit — a changed verdict, a
row note, or a word in the global questions box — never silence. This is the
*opposite* of the nvim `decision-buffer` rule, where a silent close applies
nothing; say so plainly if there's ever a risk of confusing the two.

In order:

1. **Touched rows apply as picked.** A row where the user changed the
   verdict, typed a group, or left a note is acted on per what it says.
2. **Agree = an explicit yes**, functionally identical to picking the
   suggested verdict by hand — it's a convenience for marking a row as
   reviewed, not a requirement. A row is not "less accepted" for having been
   left untouched instead of Agreed.
3. **Untouched rows apply only with "accept remaining defaults" ticked** —
   which is pre-ticked by default (`accept_defaults_default: true` unless the
   spec says otherwise). They take their `suggested` verdict.
4. **A row whose `suggested` is EMPTY (no signal) and is untouched is
   UNRESOLVED, never defaulted** — re-ask about it rather than silently
   skipping it or guessing.
5. **Any row `note` is answered before acting on that row.** A note is how a
   row opts out of the accept-by-default rule.
6. **A non-empty `global_note` is answered before acting on anything at
   all** — it's a blocking question over the whole review, not one row.
7. **Zero touched rows and accept-defaults off applies nothing** — report
   this plainly; it usually means the user looked and left without deciding.
8. **A second round rewrites the spec fresh, containing only unresolved
   rows** — collapse settled ones into a summary the same way
   `decision-buffer` §7 collapses resolved decisions; don't reopen a page
   with 150 rows to re-ask about the 3 that had notes.

Full ordering and edge cases are in
`references/spec-and-close-contract.md` — this section is the summary, that
file is the source of truth.

## Afterwards

Fold answers into the task file via `wb append` (never a raw Edit/Write
against a file under `~/code/tasks`) — the page's own wording, like a
decision-buffer's, is rough and never the durable record. Keep the spec and
answers files in the task's dossier (`~/code/tasks/dossiers/<repo>--<slug>/`)
so a later round or an audit trail can reference exactly what was shown and
answered. The page itself — the served HTML, the browser tab — is never the
durable record; the folded task-file entry is.

## Learnings ledger

`learnings.md`, beside this file, receives one dated line — Jet's own words
plus the spec/answers path — every time Jet flags a review page as
unhelpful, confusing, or in need of a contract change, in-session. Append to
it rather than losing the signal; it's the running record of what to fix
next.
