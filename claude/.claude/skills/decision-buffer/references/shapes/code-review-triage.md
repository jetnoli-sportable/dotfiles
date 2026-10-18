# Shape: Code Review Triage

For per-finding triage of a code review pass: each finding carries a `Recommendation:` line,
then its options as a checkbox list — the recommended fix first, 1–4 real alternative fixes,
then `Defer` and `Skip` last — every checkbox on its own line. The audit found this is the
shape the choice template already fit best in practice (finding F6: code-review triage had
the least pushback per volume of any buffer purpose) — made explicit here rather than left as
an implicit bend of `choice.md`.

Why options and not a flat `Apply / Defer / Skip` row: Jet flagged the flat row twice
(2026-09-15 on findings-review, 2026-10-12 on a 17-finding triage buffer — see
`learnings.md`). A bare "Apply" hides the design choice inside the fix; Jet wants to see the
recommended fix next to the other ways to address the finding, with Defer and Skip as two of
the options rather than a separate verdict. Checkboxes stacked one per line also work better
in nvim than several on one row.

Use this for reviewing a batch of code-review findings, PR feedback, or lint/audit output
where each item needs an independent fix/defer/skip call.

## Header text

Place this blockquote at the top of the doc, right under the title:

```markdown
> **Shape: code review triage, not a decision buffer.** Each finding has a recommendation and
> a list of options, one per line: the recommended fix first, the alternative fixes, then
> `Defer` and `Skip`. Mark ONE option per finding with `[x]`.
>
> **Close semantics:** a silent close — this file's content unchanged from what I wrote, no
> mark on anything, no `Closing because:` line — applies NOTHING. Not "apply everything", not
> "apply the recommendations": nothing gets applied on any finding, in this shape or any
> other, on a silent close. I'll report that the buffer closed unchanged and continue in chat
> rather than guess at intent. The same rule holds per finding inside an otherwise-marked
> buffer: a finding left unmarked while others are marked is not applied either — the
> recommendation is never applied on silence. A ticked fix option gets applied as written;
> `Defer` is carried forward into a follow-up note or task, not acted on now; `Skip` is dropped
> with no further action. Two ticks on one finding means I ask which you meant before touching
> it. Editing a finding's text or an option inline, even without a mark, counts as a note and
> is answered before I act on that finding, never treated as silence. Write
> `Closing because:` at the foot for anything worth recording about why you're closing (need
> more context before triaging, etc.).
```

## Body template

```markdown
## <File or area heading>

### Finding <N> — <one-line summary>

<description of the issue, with a `file:line` reference so it's checkable against the
actual diff or codebase>

\`\`\`<lang>
// relevant snippet — what the finding is actually pointing at
\`\`\`

**Recommendation:** <option A> — <one line on why it beats the alternatives here>

- [ ] **A — <recommended fix>** — <what changes, one line>
- [ ] **B — <alternative fix>** — <what changes, and the trade-off against A>
- [ ] **Defer** — carry to a follow-up task/note, don't change it in this pass
- [ ] **Skip** — not worth acting on; drop it

Notes: _(yours)_

### Finding <N+1> — <next finding>
(repeat per finding, grouped under file/area headings that make sense for this review)
```

Rules:
- **Recommendation first, then the options.** The `**Recommendation:**` line names one of
  the fix options and says why in one line. The recommended option is always listed first
  (`A`). No option is ever pre-ticked, including the recommended one.
- **1–4 real alternatives, five options at most before Defer/Skip.** An alternative must
  differ in what gets built (a different place for the check, a narrower or wider fix, a
  test-only change), not restate option A in other words. When a finding genuinely has only
  one sensible fix (a typo, a missing `set -u` guard), list just that fix, then Defer and
  Skip — don't pad with a straw-man alternative.
- **`Defer` and `Skip` are always the last two options**, on every finding, in that order.
- **Every checkbox on its own line.** Never put two or more `- [ ]` on one row.
- Each finding keeps its own `Notes:` line directly under its options.
