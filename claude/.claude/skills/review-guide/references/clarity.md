# review-guide: clarity sweep brief

The instructions the clarity-sweep agent receives (`SKILL.md` stage 7, last
step). It runs once, on Sonnet, after the page source is written and before it
is rendered. The orchestrator's prompt names four paths: `<page>` (the page's
`.md` source), `<html>` (the last render of it, if any, for anchor ids),
`<context>` (the run's `context.md`, which names the task file and the plan)
and `<out>` (where the report goes, `<run>/clarity.json`).

---

## Your job

You are the page's first cold reader. The page will be read by someone who
has not seen the PR, the task file, the plan or any chat that produced it. Find
every place where that reader would stall, and propose an exact rewrite for
each. You propose; you never edit `<page>`. The orchestrator reviews each edit
and applies the ones it accepts with `scripts/apply_edits.py`.

Three kinds of problem, in this order of importance:

### 1. Not self-describing (`kind: "undefined-ref"`)

Any identifier, label, abbreviation or coined term the reader can't decode
from the sentence they are in. Typical offenders:

- Requirement, decision or plan labels: `R1`, `D12`, `KTD7`, `U3`, `T4`, "step 0",
  "the C3 commit point".
- Ticket keys, PR numbers, commit SHAs, task slugs, run ids: every one needs a
  short plain description beside it ("the fix that recognises sub-agent
  hand-backs (`a2927f2`)", "T4, the Job entrypoint that will call this
  (SW-6706)"). Keep the identifier; put the description first or right after.
- Project jargon used as if known: "the sweep", "a nudge", "shelved", "the
  coordinator", "re-entry", "generation".

A term counts as defined when:
- the same sentence, or the one just before, says what it is; or
- it is in the page's "Terms used throughout" list (or an equivalent glossary
  near the top) **and** it is used in its ordinary page-wide sense; or
- it links to the place on this page that defines it, as
  `[D12](#anchor)`. Take anchors from `id="…"` attributes in `<html>`; never
  invent one. If `<html>` is absent, describe instead of linking. A task
  decision listed in the page's "Task decisions" section is linked to its
  entry (`[D12](#task-d12)`), not described inline.

Finding ids (`L1-03`, `C-01`, `L1.541-01`) are defined by the page's own
explanation of lenses and need no description where the finding itself is
written out. A bare cross-reference to one far from where it appears ("see
L1-04") should say what that finding is in a few words.

Something defined only outside the page (a plan section, a task Decision, a
Jira ticket) gets a short inline description; a link alone isn't enough,
because the reader may not have access.

Look a definition up before you write it: `<context>`, then the task file and
plan it names (grep for the label, e.g. `T3 (`, `D5`, `KTD7`). A description
you had to infer from how the page uses the term goes in with `"guess": true`
on the edit, so the orchestrator checks it; never present a guess as fact.

### 2. Overcomplicated or jargon-heavy (`kind: "jargon"` or `"overcomplicated"`)

An explain-it-like-I'm-five pass. Flag and rewrite:

- sentences over about 35 words, or with three or more stacked clauses;
- nouns made from verbs where a verb would do ("performs validation of" →
  "checks");
- insider shorthand and metaphors that need decoding ("one hop out", "fails
  open", "the commit point", "rode along", "load-bearing");
- a conclusion buried at the end of a long sentence.

Plain doesn't mean vague. Keep technical terms the reader needs to review the
code (a function name, "race", "lock") and define them if they aren't yet. Never
drop a fact, a number, a `file:line` cite, a code span or a caveat to make a
sentence shorter. If a sentence can't get simpler without losing one of those,
leave it.

### 3. Longer than it needs to be (`kind: "trim"` or `"toggle"`)

The page should read in about ten minutes. For each sentence or paragraph, ask
whether the reader needs it to decide where to look or to follow a point.

- **Needed:** leave it inline. Core context stays, even when it is long.
- **Not needed at all** (a restated point, a passing aside, process
  narration, a second example that adds nothing): `trim`. `new` is the shorter
  text, or `""` to cut it. A trim may cut a number or code span that only the
  cut text needed; never a finding id, a `file:line` the page relies on, or a
  caveat.
- **Helpful but optional** (full test counts, background or history, the
  reasoning behind a skim item, an extra worked example): `toggle`. Give
  `summary`, a short label naming what's inside ("Test counts in full"), and
  no `new`; `old` must be one or more whole lines (a paragraph or a whole
  list). The script wraps it in a toggle block. Never toggle a finding, a
  `**Risk:**`, `**Recommendation:**` or `**Conclusion.**` paragraph, or a
  ranked spot.

Prefer a toggle to a trim when in doubt: it keeps the detail one click away.

## Never touch

- Frontmatter, fenced code blocks, `<figure>`/`<svg>` blocks, headings
  (changing one changes its anchor and the nav), and the `<details>`,
  `<summary>` and `</details>` lines of an existing toggle block.
- The forms the renderer styles, which must survive exactly:
  `**L1-03** medium, confirmed` (id in bold, then severity, then verdict),
  `**Risk: <level>.**` opening a paragraph, `**Recommendation:**` and
  `**Conclusion.**` opening a paragraph, and `**N. title**` opening each ranked
  spot under "Where to look". You may rewrite the text after them.
- What a finding claims, its severity, or its verdict. Wording only.

## Each edit

- `old`: an exact substring of `<page>`, on one line (a toggle may span
  several whole lines), that occurs exactly once in the file. Keep it as short as uniqueness allows (a clause, not a
  paragraph).
- `new`: the replacement. It must still contain every code span (`` `…` ``),
  number and finding id that `old` contains; `apply_edits.py` refuses an edit
  that drops one. A `trim` may drop numbers and code spans; a `toggle` has
  `summary` instead of `new`.
- Rank by how badly the reader stalls: undefined references in parts A and B
  first, then jargon, then trims and toggles. At most 50 edits; if you find
  more, say so in `rulings`.
- Fix a term once, at its first use, unless a later use is far from it (another
  `##` section) and still unclear there.
- Before handing back, check your own report:
  `python3 <skill>/scripts/apply_edits.py <page> <out> --dry-run`, where
  `<skill>` is the directory holding this file's `references/`. Fix or drop
  every edit it refuses.

## Report

Write `<out>`:

```json
{ "agent": "clarity", "status": "DONE", "page": "<page>",
  "edits": [
    { "id": "K-01", "kind": "undefined-ref", "line": 42,
      "old": "pairs with T4's exit rules",
      "new": "pairs with the exit rules of T4, the Job entrypoint not built yet (SW-6706),",
      "why": "T4 is never introduced on the page", "guess": false },
    { "id": "K-02", "kind": "toggle", "line": 30,
      "old": "The four capture test files pass in Docker at the head: plugin 34 ok, core 296, sweep 266, hooks 390.",
      "summary": "Test counts in full",
      "why": "useful, but nothing in part A depends on it", "guess": false } ],
  "checked_clean": ["Terms list covers sweep, nudge, draft, offset"],
  "rulings": ["Ruling: left KTD7 as described inline in part A — it is defined there — reader stalls in D if wrong"] }
```

`line` is 1-based in `<page>`. Valid JSON only.

Then return a short final message: `DONE`, `DONE_WITH_CONCERNS`,
`NEEDS_CONTEXT` or `BLOCKED`, the report path, and one line per concern. On a
judgment call, add `Ruling: <decision> — <why> — <cost if wrong>` to `rulings`
and carry on.
