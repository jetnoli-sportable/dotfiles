---
name: review-page
description: Serve a large batch of items — a task-store triage, a piece/skill
  audit, a prune list, a wb-breakdown proposal, a weekly review — as a
  locally-served HTML page with per-row evidence, a suggested verdict, free-text
  grouping, and per-row/global questions, instead of an unreadable 40+-checkbox
  nvim buffer. Use when every item is answered from the same short verdict list
  and most suggestions are expected to be right (roughly 15 or more items), or
  when /weekly-review or /wb-breakdown calls for it. NOT for items that each
  have their own options and evidence (use `decision-page`), nor a settled
  choice or short interview (use `decision-buffer`). A trigger phrase like
  "audit page" does not override the answer shape.
---

# review-page

Serve a large review as a locally-hosted HTML page instead of an nvim buffer.
This skill split out of `decision-buffer`'s seventh shape (2026-09-14) once it
became clear the review-page mechanism — a spec file, an HTTP server, a
browser tab — is a genuinely different beast from the other six nvim-buffer
shapes, not just another entry in their table.

## When to use (vs decision-buffer and decision-page)

The shape of each item's answer picks the tool; trigger phrases never override
it. Use `review-page` when every item is answered from the same short verdict
list and most suggestions are expected to be right, roughly 15 or more items.
For fewer, use a `decision-buffer` findings-review doc. When each item has
options written for it, use a `decision-buffer` choice doc (1-3 decisions) or
`decision-page` (about 4-25). The full rule, including the split for batches
over 25 and the shape-wins-over-trigger-phrase handling, is owned by
`claude/.claude/skills/decision-page/SKILL.md` ("When to use"); read it there
rather than here.

A skill whose own flow fixes its presentation tool keeps it: `/weekly-review`
and `/wb-breakdown` both use review-page regardless of size.

Typical uses:

- Task-store triage (sweeping `~/code/tasks` for stale/duplicate/mis-scoped
  tasks)
- Piece/skill audits (reviewing every skill or workflow piece for
  keep/merge/retire)
- Prune lists (files, branches, dependencies flagged for removal)
- `wb-breakdown` proposals and the weekly review (fixed by those skills)

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

- **Use `description` + `fields` when the row IS the artefact** (a proposed
  child task, a ticket to create): the long body goes in the collapsed details
  panel, the machine-read values (slug, goal, size, deps) go in editable
  `fields` so the answers can feed the apply step directly. Put a summary of
  the *directions* the batch could take — the alternatives you considered and
  why the rows are shaped the way they are — in a top-of-page `sections`
  panel, not in the intro (Jet, 2026-09-14: "do a summary of possible
  breakdown directions on top of the page").
- **`meta` chips carry the facts a reviewer compares across rows** (size,
  stage, deps count) so the table reads like a table, not a list of prose.

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

- The page is served on **`http://127.0.0.1:8765`** by default — one stable, bookmarkable
  URL; a new review just refreshes the tab. If 8765 is busy (a second page open at once) it
  falls forward to the next free port and prints it. `--port N` overrides.
- Served on `127.0.0.1`, not `file://` — snap-packaged Chromium can't open
  `file://` URLs under hidden directories (a documented environment
  limitation); serving over HTTP sidesteps this entirely, so it isn't a
  decision to revisit per use.
- It opens the browser itself (`/snap/bin/chromium` if present, else
  `xdg-open`) — don't also try to open one yourself.
- **A never-returning backgrounded call usually means the tab got closed
  without Submit** (or never opened at all) — the server waits forever by
  default, so check on it rather than assuming it's still being read.
  `--timeout SECS` bounds the wait: past it, the process exits 4, writes no
  `answers.json`, and leaves the state file at `closed=0` (nothing was
  fabricated). Recover either way — a stuck backgrounded call, or a `--timeout`
  exit-4 you want to keep waiting past — with
  `review-page.py --reattach /path/to/answers.json` (also backgrounded; see
  `references/spec-and-close-contract.md`), or just kill the process and
  re-run with a fresh `--spec`/`--out`.

## The page

The page opens on an overview band (where this sits, counts, the intro), with a
collapsible sidebar and one card per row, grouped by area; the close-out block
(accept defaults, global questions, Submit) is at the end. It shares its look
and key map with `decision-page`. Keyboard, none of it active while typing:

| Key | Does |
|---|---|
| `j` / `k` | next / previous: overview, each row, close-out |
| `a` | agree with the suggestion (again to undo) |
| `1`-`9` | pick a verdict |
| `c` | clear the row back to untouched |
| `n` | note (global questions on the close-out block) |
| `g` / `t` | group tag |
| `e` / `o` | expand / collapse evidence and details; `E` does every row |
| `u` | jump to the next row that needs you |
| `/` | search |
| `[` | collapse / expand the sidebar |
| `Enter` | overview: first row that needs you; close-out: Submit |
| `?` | list the keys |

The old `A` and `d` / `D` keys are retired. Spec additions (`context`, row
`prior`) and the full key map are in `references/spec-and-close-contract.md`.

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
