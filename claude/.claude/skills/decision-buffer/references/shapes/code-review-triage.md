# Shape: Code Review Triage

For per-finding triage of a code review pass: each finding gets Apply, Defer, or Skip, no
options and no recommendation — the call is Jet's per finding, not a menu the agent is
steering toward a pick. The audit found this is the shape the choice template already fit
best in practice (finding F6: code-review triage had the least pushback per volume of any
buffer purpose) — made explicit here rather than left as an implicit bend of `choice.md`.

Use this for reviewing a batch of code-review findings, PR feedback, or lint/audit output
where each item needs an independent accept/defer/reject call.

## Header text

Place this blockquote at the top of the doc, right under the title:

```markdown
> **Shape: code review triage, not a decision buffer.** For each finding, mark ONE of
> `Apply / Defer / Skip` with `[x]`. There is no recommendation line — the triage call on each
> finding is yours to make.
>
> **Close semantics:** a silent close — this file's content unchanged from what I wrote, no
> mark on anything, no `Closing because:` line — applies NOTHING. Not "apply everything", not
> "apply the obvious ones": nothing gets applied on any finding, in this shape or any other,
> on a silent close. I'll report that the buffer closed unchanged and continue in chat rather
> than guess at intent. The same rule holds per finding inside an otherwise-marked buffer: an
> individual finding left unmarked while others are marked is not applied either — only
> `Apply` gets applied. `Defer` is carried forward into a follow-up note or task, not acted on
> now; `Skip` is dropped with no further action. Editing a finding's text inline, even without
> a mark, counts as a note and is acknowledged, never treated as silence. Write
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

- [ ] Apply - [ ] Defer - [ ] Skip

Notes: _(yours)_

### Finding <N+1> — <next finding>
(repeat per finding, grouped under file/area headings that make sense for this review)
```
