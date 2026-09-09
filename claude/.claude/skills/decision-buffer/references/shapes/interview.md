# Shape: Clarifying Interview

For open-ended questions where free-text answers are what's needed, not a pick between
options — clarifying a brainstorm, filling in intent the agent can't infer, or surfacing
assumptions before planning. Each question states why it matters and what the agent will
assume if Jet leaves it blank, so a blank answer is never a silent gap. Generalized from the
shape actually used and worked well in
`~/code/tasks/dossiers/dotfiles--decision-buffer-skill-v2/2026-09-08-brainstorm-interview.md`
— copy that working shape, don't reinvent it.

Use this instead of `choice.md` when there's no menu of options to pick from — only
questions the agent needs Jet's actual judgment on, where an educated guess exists but
shouldn't be assumed silently. Use instead of `findings-review.md` when there isn't yet a
set of findings to react to — the questions come first, findings second.

## Header text

Place this blockquote at the top of the doc, right under the title:

```markdown
> **Shape: clarifying interview, not a decision buffer.** Nothing here is an option to pick.
> Each question states _why it matters_ and _my default if you leave it blank_. Write your
> answer under `Answer:` in free text, as short or long as you like; annotate anywhere inline.
>
> **Close semantics:** a filled answer replaces my stated default outright. A blank answer
> means the stated default goes forward as an **explicit assumption**, labelled as yours by
> silence, not as a decision — I will say so plainly wherever that assumption gets used next,
> so it stays visible and reversible rather than quietly baked in. You can also write "ask me
> in chat" under any question to take it live instead of in the buffer. Write
> `Closing because:` at the foot if you're closing with answers still blank for a reason worth
> recording (need more time, wrong question, etc.).
```

## Body template

```markdown
## I<N> — <short topic name>

<the question itself, with enough standalone context to answer without re-reading a separate
doc — restate background inline rather than assuming familiarity with a prior doc or term.>

**Why it matters:** <what this answer changes downstream — which decision or design choice
it feeds>.

**My default if blank:** <the concrete assumption that gets used if left blank, stated
specifically enough that "silence = this" is unambiguous>.

Answer: _(yours)_
```

A question can carry the four review marks (`agree / disagree / dig deeper / out of scope`)
instead of free text when that fits better than an open answer — typically when checking the
agent's own reading of something Jet already said, rather than asking something new:

```markdown
## I<N> — <topic>, now explained

<restate what was previously said or inferred, and the agent's reading of it>

- [ ] agree - [ ] disagree - [ ] dig deeper - [ ] out of scope

Notes: _(yours)_
```

Here unmarked carries the same meaning as in `findings-review.md`: "still no reaction", not
agreement — state that explicitly in the header if a doc mixes both question forms, so which
close semantics apply to which item is never ambiguous.

End with a free-text catch-all:

```markdown
## Anything else

_(yours)_
```
