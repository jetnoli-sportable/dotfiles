# Shape: Confirm Facts

For plain fact-checking, not a decision: a short list of statements to confirm or correct,
each ticked independently, with no options and no recommendation. This is the "zero-option
state checklist" the audit found buffers being bent into anyway (finding F18) — made an
explicit shape so it stops carrying the choice template's unused scaffolding (options,
pros/cons, a recommendation line with nothing to recommend).

Use this when nothing is actually being chosen — only facts the agent believes are true and
wants confirmed or corrected before proceeding, e.g. "here's my understanding of the current
state, tell me if I've got it right."

## Header text

Place this blockquote at the top of the doc, right under the title:

```markdown
> **Shape: confirm facts, not a decision buffer.** These are plain statements to confirm, not
> options to choose between — there is no recommendation to give here, and no
> `**Recommendation:**` line appears anywhere in this doc. Tick `[x]` next to each fact that's
> correct as stated; leave a fact unticked and add a note if it's wrong or needs qualifying.
>
> **Batch size, kept small on purpose:** this buffer holds a handful of facts, not a long
> ledger. Long fact lists overwhelm and get skimmed rather than actually checked line by line
> — a bigger set gets split across more than one buffer rather than crammed into one.
>
> **Close semantics:** an unticked fact means "not confirmed", not "false" — it hasn't been
> checked off, and it's treated as still open rather than assumed either way. A fact whose
> text was edited inline, even without a tick, counts as a correction and is read as one. If
> every fact is ticked and nothing was edited, the whole batch is taken as confirmed and work
> proceeds on that basis. Write `Closing because:` at the foot if you're closing with facts
> still unticked for a reason worth recording (need to check something first, etc.).
```

## Body template

```markdown
## <Topic>

- [ ] <Fact 1, stated plainly as a single verifiable claim>
- [ ] <Fact 2>
- [ ] <Fact 3>
(a handful per buffer — split into a second buffer rather than growing this list long)

Notes: _(yours — corrections or qualifications go here, or inline next to the fact itself)_
```

No `**Recommendation:**` line, no per-item pros/cons, no code blocks unless a fact needs a
`file:line` citation to be checkable at all — this shape is deliberately thinner than
`choice.md`.
