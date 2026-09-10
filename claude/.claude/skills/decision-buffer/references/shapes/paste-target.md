# Shape: Paste Target

A todo-list-style execute-and-paste flow, not a decision at all: each item is a query or
step to run outside the buffer, a slot to paste the result into, and a verify line to check
once the result looks right. This is the SQL-results pattern Jet was already using the
block-until-closed nvim mechanism for (audit finding F7: "open a decision buffer where I can
copy the query and paste the results") — made an explicit first-class shape rather than a
bent choice buffer.

Use this when there's no decision or judgment call at all, only a batch of steps whose
output needs to land somewhere durable and then get glanced at.

## Header text

Place this blockquote at the top of the doc, right under the title:

```markdown
> **Shape: paste target, not a decision buffer.** This is a todo-list-style execute-and-paste
> flow, not a set of options to pick between. For each item: run the query/step, paste the
> result into the paste slot, then check the verify line once the result looks right. Strike
> through an item with `~~like this~~` to mark it skipped instead of pasted.
>
> **Close semantics:** a slot is "done" once it carries either a pasted result or an explicit
> strike-through — a slot with nothing pasted and nothing struck means that item is still
> outstanding, not skipped, and this buffer reopens on it. If every slot has a paste or a
> strike-through, closing is silent-safe: nothing needs to be applied, I summarize the verify
> lines and move on rather than reopening. Write `Closing because:` at the foot to stop the
> reopen loop early for any other reason (blocked, doing it a different way, etc.) — that's
> honored immediately, no cap needed.
>
> **Reopen cap:** after three reopens in a row with no new paste added anywhere in the doc, I
> stop reopening this buffer and ask in chat instead — repeatedly reopening an unchanged
> buffer isn't productive, and something else is blocking progress at that point.
```

## Body template

```markdown
## <Section heading, if items group naturally — omit for a flat list>

### Item <N> — <short label>

**Query / step:**

\`\`\`
<the exact query or step to run — copy-pasteable as-is>
\`\`\`

**Paste result here:**

\`\`\`
_(yours — paste the output, or replace this whole block with `~~skipped: <why>~~` to skip)_
\`\`\`

**Verify:** - [ ] <what "looks right" means for this specific result, so ticking this
confirms something concrete rather than just "I pasted something">

### Item <N+1> — <next item>
(repeat per item)
```

Keep the verify line concrete per item — "row count matches expectation" or "no error in
output" reads better than a generic "looks good", since that's what actually gets checked
before the box is ticked.
