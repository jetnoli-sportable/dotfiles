# Shape: Findings Review

For presenting research/audit output that isn't a decision yet — findings from a fan-out,
an audit, a spike's discoveries — where what's wanted is Jet's reaction to each finding
(agree it's real and worth acting on, disagree, dig deeper, out of scope) plus free-text
answers to genuinely open questions, not a pick between options. Generalized from the shape
actually used and worked well in
`~/code/tasks/dossiers/dotfiles--decision-buffer-skill-v2/2026-09-07-audit-findings-review.md`
— copy that working shape, don't reinvent it.

Use this instead of `choice.md` whenever there's nothing yet to choose between — only
things to confirm, push back on, or flag as needing more digging before a decision is even
framed. This is also the shape a spike or scoping task should default to before any options
buffer, per the audit: buffers that jumped straight to options-and-recommendation on
not-yet-understood ground were a repeated wrong-tool moment.

## Header text

Place this blockquote at the top of the doc, right under the title:

```markdown
> This is a **findings review, not a decision buffer.** Nothing here is an option to pick and
> there is no recommendation. For each finding, mark ONE of
> `agree / disagree / dig deeper / out of scope` with `[x]` and write anything you like on the
> free-text Notes line, or anywhere inline. Open questions at the end take free text only.
>
> **Close semantics:** a finding left unmarked means "no reaction", not "agree" — silence is
> never read as consent, and an unmarked finding only gets followed up on if it turns out to
> matter for what comes next. A changed mark, edited finding text, a reordered item, or an
> added note all count as a reaction and are read as one, even without the obvious box ticked.
> Save and close when done. Write `Closing because:` at the foot if you're closing before
> reacting to everything, for a reason worth recording (still forming a view, ran out of time,
> etc.) — otherwise I'll just note which findings got no reaction and move on.
```

## Body template

```markdown
## <Category heading, e.g. "A. Usage and outcomes">

### F<N> — <finding, one-line headline>

<1-3 sentence description of the finding, grounded in what was actually found — cite the
source evidence, e.g. _(source doc "section name")_ or a file:line reference.>

- [ ] agree - [ ] disagree - [ ] dig deeper - [ ] out of scope

Notes: _(yours)_

### F<N+1> — <next finding>
(repeat per finding, grouped under category headings that make sense for this review)
```

For hypotheses or proposals surfaced alongside findings (not evidence, but "worth testing"
candidates), use the same four-mark shape but say up front what the marks mean in that
section, since it differs from a plain finding:

```markdown
## <Hypotheses section>

Same four marks. Here `agree` means "worth testing/pursuing", `disagree` means "drop it",
`dig deeper` means "needs more evidence before it's even a hypothesis".

### H<N> — <hypothesis, one line>

<what it proposes and why it's on the table>

- [ ] agree - [ ] disagree - [ ] dig deeper - [ ] out of scope

Notes: _(yours)_
```

End with a free-text section for anything the marks can't capture:

```markdown
## Open questions — free text only

### Q<N> — <question>

<context the answer needs>

Answer: _(yours)_

## Anything else

_(yours — anything the findings missed, or a reaction to the review shape itself)_
```
