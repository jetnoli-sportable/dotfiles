# Shape: Choice

The original decision-buffer shape: 2-4 named options per decision, picked with a checkbox,
each with inline code and pros/cons. Use when a decision is genuinely due — a fork in
implementation approach, architecture, or design where more than one path is real and
Jet's pick changes what gets built next. Not for facts to confirm (see `confirm-facts.md`),
not for open-ended questions (see `interview.md`).

## Header text

Place this blockquote at the top of the doc, right under the title:

```markdown
> Check the option(s) you want with `[x]`, add questions or notes anywhere inline or under
> *Questions / Notes*, then save and close the buffer.
>
> **Close semantics:** no `[x]` and no notes when this closes means no selection was made —
> silence is not read as a pick, and nothing proceeds on a guess. I'll ask in chat what held
> you back rather than reopening this unchanged. Multiple `[x]` on one decision means either a
> staged/combined intent or an accidental double-tick — I'll ask which. Exactly one `[x]` with
> no dangling question against it means I proceed on that option. An edited option, a
> reordered list, or a note anywhere counts as a reaction even without a tick, and is answered
> before I act on anything. Write `Closing because:` at the foot to tell me why you're closing
> without picking (still thinking, wrong framing, etc.) so I don't have to guess.
```

## Body template

```markdown
## Decision 1 — <name>

### Option A — <name>

- [ ] **Choose Option A**

**Problem it solves:** ...
**Solution:** 2-4 sentence summary.

\`\`\`ts
// inline code example of what changes — concrete, from the actual codebase
\`\`\`

**Pros:** ...
**Cons:** ...
**Best when:** ...

### Option B — <name>
(same shape; 2-4 options total, distinct on mechanism not implementation detail)

### Questions / Notes

_(empty — yours)_

## Decision 2 — <name>

(repeat: options → its own Questions / Notes. One `## Decision N` block per decision. For a
single-decision doc there's just one block; drop the number or call it `## Options` if that
reads more naturally.)
```

Rules:
- Inline code examples are mandatory per option — what the change actually looks like in
  this codebase, not pseudocode.
- No option is ever pre-ticked. `- [ ] **Choose Option A**`, never `- [x]`, regardless of
  which option the agent favors.
- **The `**Recommendation:**` line is opt-in, not a ritual.** Per R8, write it only when Jet
  explicitly asked for a recommendation on this decision, or the agent has a specific stated
  reason worth giving. When written, it goes right after that decision's last option, before
  its own Questions / Notes — never deferred to a doc-end section. When omitted, omit it
  entirely: do not write a placeholder like "Recommendation: none to give" (the old ritual
  line the audit found on 92% of blocks, including ones with nothing to recommend — see
  finding F17 in the audit dossier). The absence of the line is itself the signal that no
  recommendation is being made.
- Every decision keeps its own `### Questions / Notes` subsection, directly after its last
  option (or after the recommendation, when one is written) and before the next decision's
  heading. A doc-level `## Questions / Notes` at the very end is reserved only for notes that
  genuinely cross-cut multiple decisions.
