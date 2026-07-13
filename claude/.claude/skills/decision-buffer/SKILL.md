---
name: decision-buffer
description: Run design discussions through a markdown decision doc edited in the user's nvim buffer instead of AskUserQuestion menus. Use whenever presenting 2+ design/architecture options for a non-trivial decision, or when the user says "decision doc", "open a buffer for this", "which approach" in a design context, or invokes /decision-buffer explicitly.
---

# Decision Buffer

Present design decisions as a markdown doc the user edits in nvim. Checked checkboxes and inline notes in the closed buffer ARE the user's answer — do not also fire AskUserQuestion for the same decision.

## When this applies

- You are about to present two or more design/architecture/approach options for a decision that isn't trivial.
- The user asked for a decision doc or to review options in a buffer.

When a decision is trivial (one obvious option, yes/no with an obvious default), skip this skill and just proceed or ask in chat.

## Flow

### 1. Write the decision doc

Path: `docs/decisions/YYYY-MM-DD-<topic>.md` if the repo has `docs/decisions/`; otherwise `./logs/decisions/YYYY-MM-DD-<topic>.md` (gitignored scratch). Use the repo the discussion concerns — for worktree-based discussions, write inside that worktree.

Structure — every decision (even when the doc holds only one) is a fully
self-contained block: its options, then ITS OWN recommendation, then ITS OWN
questions/notes. Never collect recommendations or notes into a single
section at the end of the doc — Jet reacts to each decision while reading
it, not after reading all of them (user rule, 2026-07-06 for notes,
2026-07-08 for recommendations; a doc-end "Recommendation: 1A, 2A, 3A" list
forces re-scrolling to match each pick back to its reasoning).

```markdown
# <Decision title>

> Check the option(s) you want with `[x]`, add questions or notes anywhere
> inline or under *Questions / Notes*, then save and close the buffer.

## Context

Problem statement, constraints, relevant facts verified in the codebase
(with `file:line` references), and anything already ruled out and why.
Shared/global context goes here; a specific decision can add its own
context inline within its own section below if it doesn't apply globally.

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

**Recommendation:** agent's pick for *this* decision and a short why, placed
right here — immediately after this decision's own options, never deferred
to a section at the end of the doc. State trade-offs honestly; do not pad.

### Questions / Notes

_(empty — yours)_

## Decision 2 — <name>

(repeat the exact same shape: options → inline **Recommendation:** → its
own ### Questions / Notes. One `## Decision N` block per decision. For a
single-decision doc there's just one block; drop the number or call it
`## Options` if that reads more naturally — the inline-recommendation and
per-decision-notes shape still applies.)

## Questions / Notes

_(doc-level — ONLY for notes that cross-cut multiple decisions and don't
belong to one specifically. Still seed with `_(empty — yours)_`. This is
never where an individual decision's recommendation or notes live.)_
```

Rules:
- Inline code examples are mandatory per option — what the change actually looks like in this codebase, not pseudocode.
- Repo-relative paths only inside the doc.
- Keep context honest: include facts that argue *against* the recommendation too.
- **Every decision gets its own inline `**Recommendation:**` line AND its
  own `### Questions / Notes` subsection**, both directly after that
  decision's last option and before the next decision's heading. Never a
  single `## Recommendation` or a single `## Questions / Notes` covering
  multiple decisions — both read poorly because Jet reacts to a decision
  immediately after seeing its options, not after scrolling through every
  other decision first. The doc-level `## Questions / Notes` at the very
  end is the only exception, reserved for genuinely cross-cutting notes.
  Parse every per-decision subsection plus the doc-level one on return.

### 1b. Companion HTML doc (sufficiently large buffers)

For a buffer with 2+ decisions, or a single decision whose background
context is substantial, also write a companion HTML doc at the same path
with `.html` in place of `.md` (e.g. `logs/decisions/2026-07-08-board-
scoping.md` pairs with `logs/decisions/2026-07-08-board-scoping.html`).
The markdown stays the concise, actionable artifact (checkboxes, options,
inline recommendations) — the HTML is where richer context lives, so the
markdown never has to bloat to carry it:

- Fuller background/context than the markdown's terse Context section —
  including short quotes from (not just links to) prior decisions or docs
  that shaped this one, so the reader never has to go find something they
  haven't seen recently.
- Diagrams/charts/visuals where they clarify a tradeoff (a sequence diagram
  for a flow decision, a comparison chart for a cost tradeoff) — markdown
  has no good native equivalent for these.
- Relevant glossary terms surfaced inline, once a glossary page exists to
  link to.

Follow the `artifact-design` skill's guidance for the HTML itself
(self-contained, theme-aware light/dark, no external assets) and match this
repo's existing generated-doc visual language (see `docs/wb-guide.html`'s
inline `<style>` block — Catppuccin-based light/dark palette) rather than
inventing a new look per doc.

Skip the companion HTML for a single small decision with an obvious,
low-context choice — the markdown alone is the whole point there.

**Render actual states, not just describe them, when the decision is about
concrete UI/display output.** If the decision is "what does this render as"
(badge states, card layouts, a status matrix — anything the user will look
at), the companion HTML should show the real rendered states side by side
(reusing the actual CSS classes/visual language already shipped, not a new
look), not just prose-describe them. A markdown text sketch of "4 of 7
badges read off, which looks like an unstarted task" is fine as backup, but
the rendered mockup is what actually lets the user evaluate in one glance
instead of building the picture in their head first (2026-07-11, wb board
lifecycle: a rendered 4-card mockup made the ambiguity click immediately
— prior rounds of prose description alone hadn't). Budget the extra
mockup-building effort into the round; it's cheaper than a round that
doesn't land.

**A mockup can reveal the decision itself was framed wrong — that's a
good outcome, not a failure to route around.** Presenting a concrete
rendering sometimes shows the user that neither offered option is right,
or that the whole approach needs rethinking together rather than picked
from a menu (2026-07-11: seeing the actual badge states led to "let's
redesign this as a table, not badges — take our time"). When that
happens, don't force the original A/B/C framing to a close. Either open a
live, iterative mockup exploration in chat/artifact instead of another
buffer round (buffers suit picking between settled options; a genuinely
open design conversation is faster in chat with the artifact as a shared
canvas), or fold the reframed decision into the next buffer round with
new options that reflect it. Say so plainly in the buffer's next
`## Decisions made` pass rather than quietly dropping the original
framing.

Mention the companion doc's absolute path once, alongside the buffer-open
message, so the user can open it in a browser at their own pace. It is
read-only reference material, not routed through the nvim buffer flow —
don't wait on it before opening the markdown buffer.

### 2. Hand off to the buffer — auto-open

Auto-open the doc in nvim where the user already is, as a **background** Bash command so the agent is re-invoked the moment the user closes the buffer. Detection ladder, first match wins:

**(a) Inside tmux** (`$TMUX` non-empty — Jet's usual setup): open a split pane next to the session and block on a wait-channel:

```
Bash (run_in_background: true):
  CHAN="decision-buffer-done-$$-$RANDOM"   # MUST be unique per open — see below
  tmux set -p -t "$TMUX_PANE" @claude_blocked nvim-buffer
  tmux split-window -h -t "$TMUX_PANE" "nvim '<abs path>'; tmux wait-for -S $CHAN" \
    && tmux wait-for "$CHAN"
  tmux set -pu -t "$TMUX_PANE" @claude_blocked
```

Closing nvim closes the pane, fires the signal, completes the background task → agent re-invoked. This is the preferred mode: same terminal window, Ctrl+G-like feel.

**The channel name MUST be unique per invocation** (`$$-$RANDOM` above; a pane id or timestamp works too). `tmux wait-for` *latches* a signal when no client is waiting: if any earlier `wait-for -S <chan>` ran with no waiter present (a buffer from a prior session, an aborted open), tmux remembers one pending signal on that channel, and the next `wait-for <chan>` returns **instantly** — re-invoking the agent before the user has closed (or even touched) the buffer. A fixed channel name like `decision-buffer-done` is shared across every session on the tmux server, so this misfire is not rare. A fresh per-open channel name cannot carry a stale signal. The inner `$CHAN` is expanded by the outer shell before being passed to the pane, so both sides use the same unique value. If you ever must reuse a fixed channel, drain it first with a non-blocking `tmux wait-for -S <chan>` immediately followed by a waiter — but unique names are simpler and correct.

The `@claude_blocked` pane option marks this agent as *blocked on you* (vs. merely
idle) while the buffer is open. The `claude-sessions.sh` overview reads it to sort
this agent into its "needs your input" tier — necessary here because a decision-buffer
block runs as a background command, so the pane shows a working spinner that no
content scan can distinguish from real work. The trailing `set -pu` clears the
marker the instant the buffer closes and control returns. (Permission prompts and
AskUserQuestion menus don't need the marker — the overview detects those from the
pane's own modal UI.)

**(b) Graphical session, no tmux** (`$DISPLAY`/`$WAYLAND_DISPLAY` set): spawn a terminal window that blocks until close:

```
Bash (run_in_background: true):
  gnome-terminal --wait -- nvim <abs path>
```

(`--wait` is required — gnome-terminal otherwise forks to its server and returns immediately, losing the close signal. kitty/alacritty/foot block by default with `<term> -e nvim <path>`; detect with `command -v`.)

**(c) Fallback** (headless, or spawn fails): manual handoff. End the turn with the literal command the user can copy:

```
! nvim <path to the doc>
```

and explain once per session: the `!` prefix runs nvim in this session; closing it returns control.

After launching (a) or (b), tell the user the buffer is open and end the turn. Do NOT poll, schedule wakeups, or keep talking — the background command completing IS the signal.

### 3. Parse on return

When the background command completes (window closed), the `!` command returns, or the user sends any message — Read the doc fresh and interpret:

- `[x]` on a Choose line → that option is selected.
- Exactly one `[x]` and no questions → proceed on that option immediately.
- Prose under **Questions / Notes** or inline edits/comments anywhere → answer them BEFORE acting on any selection. Quote each question and answer it.
- Multiple `[x]` → ask (in chat) whether it's a staged/combined intent or an accident.
- Zero `[x]` and no notes → ask in chat what held them back; do not re-fire the same doc unchanged.

### 4. Iterate — rewrite fresh, don't append

When another round is warranted, do NOT keep appending `> **answer:**` blockquotes onto the existing structure and reopening the same growing doc — that's how a buffer turns into an unreadable stack of appended rounds (this happened, 2026-07-08: "the buffer is confusing as the original doc is there with our updates and decisions appended on").

Instead, rewrite the doc fresh each round:

- **Clearly resolved decisions** (an unambiguous `[x]` with no dangling question, or a note that fully closes the question) collapse into a compact `## Decisions made` summary at the top of the rewritten doc — one bullet per decision: what was decided and a one-line why. Do not keep their full options/pros/cons scaffolding around — that already did its job.
- **Still-open items** — an unresolved choice, a decision whose note raises a new question needing an answer, or a restated understanding awaiting confirmation — keep their full appropriate form (options block, or a restated-understanding-plus-confirm-checkbox, whichever fits) in the body below the summary, exactly as before.
- Seed `## Decisions made` with an instruction that the user can flag anything wrong about it inline or in that section's own notes — a summary is a claim to verify, not a fait accompli.
- If the whole doc resolves to zero open items, don't reopen it at all — report completion in chat instead (see Afterwards).

This keeps every re-opened buffer as short as the genuinely unresolved surface, not a growing transcript of the whole negotiation. The doc still accumulates as a durable record (via `## Decisions made` entries growing each round), just compacted instead of appended.

### 5. Afterwards

The doc is a durable decision record. If a decision is finalized and the doc lives in `docs/decisions/`, update it with a final `**Decided:** Option X (YYYY-MM-DD)` line at the top. Docs in `./logs/` are scratch and need no upkeep.
