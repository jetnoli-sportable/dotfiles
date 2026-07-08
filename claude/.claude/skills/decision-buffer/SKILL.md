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

Structure (every section required):

```markdown
# <Decision title>

> Check the option(s) you want with `[x]`, add questions or notes anywhere
> inline or under *Questions / Notes*, then save and close the buffer.

## Context

Problem statement, constraints, relevant facts verified in the codebase
(with `file:line` references), and anything already ruled out and why.

## Options

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

## Recommendation

Agent's pick and a one-paragraph why. State trade-offs honestly; do not pad.

## Questions / Notes

_(empty — yours)_
```

Rules:
- Inline code examples are mandatory per option — what the change actually looks like in this codebase, not pseudocode.
- Repo-relative paths only inside the doc.
- Keep context honest: include facts that argue *against* the recommendation too.
- **Multi-decision docs: a `### Questions / Notes` subsection under EVERY
  decision** (directly after its last option, before the next decision's
  heading), each seeded with `_(empty — yours)_` — Jet reacts to decisions
  inline while reading; one trailing notes section forces bottom-of-file
  cross-referencing by number (user rule, 2026-07-06). The doc-level
  `## Questions / Notes` at the end stays for cross-cutting notes. Parse
  BOTH the per-decision subsections and the doc-level one on return.

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

### 4. Iterate in the buffer when asked

If the user's notes warrant another round: edit the doc in place — append `> **answer:** ...` blockquotes directly under their questions, revise option sections if their notes change the analysis — then offer the same `! nvim` command again. The doc accumulates the dialogue; do not start a new file per round.

### 5. Afterwards

The doc is a durable decision record. If a decision is finalized and the doc lives in `docs/decisions/`, update it with a final `**Decided:** Option X (YYYY-MM-DD)` line at the top. Docs in `./logs/` are scratch and need no upkeep.
