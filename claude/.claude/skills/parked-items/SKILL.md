---
name: parked-items
description: Weekly review of everything the user parked for "later" — items they said to discuss later, revisit, or make a scratch/follow-up task for — gathered from the /park ledger plus a backstop scan of session transcripts, reconciled against the central task store (~/code/tasks), and presented as a checklist in an nvim buffer to act on. Use when the user types /parked-items, /parked-items --backfill, says "what did I park", "weekly review", "what was I going to come back to", or "what follow-ups do I owe". Pairs with /park (capture).
---

# Parked Items — weekly review

Surface what the user deferred and turn it into action. Sources, in priority order:
the `/park` ledger (explicit), then a transcript backstop (things said but never `/park`ed),
reconciled against the central task store (`~/code/tasks/<repo>--*.md`) so already-actioned
items drop off. This is the review half; [[park]] is capture.

## Modes

- **Default (`/parked-items`)** — review the **last 7 days**. The ongoing weekly cadence.
- **Backfill (`/parked-items --backfill`)** — scan **all** session history once, to
  establish a clean baseline and sort the current central task store. Run this first, once.
- `--since=<N>d` overrides the window (e.g. `--since=14d`).

## Scope

All repos / all sessions. Read the real working dir from each transcript's `cwd` field —
do **not** try to decode the `~/.claude/projects/<encoded-cwd>` directory name (the
encoding is lossy). Any follow-up task gets routed to the repo named by that `cwd`.

## Step 1 — Gather candidates

**A. Ledger (explicit `/park` items):**

```bash
cat ~/.claude/parked-items/ledger.jsonl 2>/dev/null   # {ts,cwd,branch,note,status,source}
```

**B. Transcript backstop.** Scan the user's typed prompts for parking language. The
reliable "this is a human prompt" discriminator is **string `message.content`** — tool
results are also `type=="user"` but carry array content, and the `origin`/`promptSource`
fields are newer and absent on most lines (do NOT filter on them; it drops ~everything).
For `--backfill` drop the date filter; otherwise keep the `--since` window.

```bash
SINCE=$(date -u -d '7 days ago' +%FT%TZ)   # omit/relax for --backfill
PHRASES='discuss (this|it|that)? ?(later|after)|let'\''s discuss|revisit|come back to|circle back|park (this|it|that)|make a (scratch|follow.?up|jira)? ?(task|ticket)|follow.?up (task|ticket|on)|for now\b.*\blater|remind me|deal with (this|it) later|leave (this|that) for (now|later)|rank .*(task|scratch)|review .*(end of (the )?week)|TODO later'
for f in ~/.claude/projects/*/*.jsonl; do
  jq -rc --arg since "$SINCE" '
    select(.type=="user" and (.message.content|type=="string"))
    | select((.timestamp // "") >= $since)
    | {ts:.timestamp, cwd:.cwd, branch:(.gitBranch // ""), session:.sessionId, text:.message.content}
  ' "$f" 2>/dev/null
done | grep -iE "$PHRASES"
```

Merge A+B, dedupe near-identical notes, sort by recency. (For `--backfill` this will be
noisy — that's expected; the judging step prunes it.)

## Step 2 — Judge each candidate: still open?

For each candidate, read enough surrounding transcript context (the same `cwd`'s session
JSONL around that `ts`) to decide. Drop / mark **resolved** when:

- It was clearly handled later in the **same** session (e.g. the discussion happened, a
  fix landed, a ticket/task was created). Keep these only for the "resolved this week"
  footer, not the action list.
- A matching task file already exists for that repo, or a Jira ticket was filed for it.
  Reconcile by reading `~/code/tasks/<repo>--*.md` (repo basename from `cwd`) and grepping
  for the topic.

Keep as **open** anything genuinely still pending. Phrase-match false positives (e.g.
"let's discuss the options" that was then immediately resolved) get dropped here.

## Step 3 — Present as an nvim buffer checklist

Write `~/.claude/parked-items/review-<YYYY-MM-DD>.md`: one row per open item — when, repo,
the quote, your read, and a checkbox-per-action. Recommended action pre-checked.

```markdown
# Parked items — week of <date>   (<open> open · <resolved> resolved)

> Check ONE action per item, add notes inline, save & close. I'll act on what's checked.
> Apply = create the scratch task / take the action · Defer = keep parked · Drop = dismiss.

## Open

### 1. <topic>  ·  <repo> @ <branch>  ·  <date>
> "<the quote>"
My read: <still-open because …>
- [x] Make a scratch task   - [ ] Make a Jira ticket   - [ ] Discuss now   - [ ] Keep parked   - [ ] Drop

### 2. …

## Resolved this week (record only — no action)
- <topic> — <how it was resolved> (<repo>, <date>)
```

Open it where the user is, blocking until they close it (same mechanism as
`[[decision-buffer]]`): inside tmux, mark the pane blocked and `split-window` running
`nvim` with a `wait-for` signal; fall back to `gnome-terminal --wait`, then to a manual
`! nvim <path>`. Run the launch as a background Bash command so closing the buffer
re-invokes you.

```bash
CHAN="parked-review-done-$$-$RANDOM"   # MUST be unique per open — a fixed name
                                       # latches stale signals (see decision-buffer)
tmux set -p -t "$TMUX_PANE" @claude_blocked nvim-buffer
tmux split-window -h -t "$TMUX_PANE" "nvim '<abs path>'; tmux wait-for -S $CHAN" \
  && tmux wait-for "$CHAN"
tmux set -pu -t "$TMUX_PANE" @claude_blocked
```

## Step 4 — Act on the returned buffer

Re-read the file. For each item:

- **Make a scratch task** → create it via `wb new --planned <repo> <slug>` (repo basename
  from `cwd`, slug a short kebab-case derivation of `<topic>`) — the locked,
  planned-preserving creation verb (`scripts/.config/scripts/tmux/wb.sh`, search
  `cmd_new`'s `--planned` branch), instead of a Write-tool file creation. It seeds the
  file from the central store's frontmatter schema (`~/code/tasks/TEMPLATE.md`) with
  `status: planned` (never flipped to `doing` — that only happens later, for real, if
  this scratch task is ever picked up via a real `wb new`/`wb new --agent`) and `repo:`/
  `branch:` filled in, leaving `worktree:` blank since no worktree exists yet. Then
  append the origin quote, why it was parked, and any pointers under `## Follow-ups`
  via `wb append` (its locked, heading-scoped append verb) instead of an Edit-tool
  write:

  ```bash
  DOTFILES="${DOTFILES_ROOT:-$HOME/code/dotfiles}"
  WB="$DOTFILES/scripts/.config/scripts/tmux/wb.sh"
  task_file="$("$WB" new --planned "$repo" "$slug")"
  "$WB" append "$task_file" Follow-ups <<EOF
  - Parked from chat on <date>: "<the origin quote>"
    Why parked: <your read from Step 2 — still-open rationale>
  EOF
  ```

  Follow the user's convention: minor follow-ups go to the central store, not real Jira,
  unless they explicitly chose "Jira". **Never create or edit task files under
  `~/code/tasks` with the Write/Edit tool** — `wb new --planned` (creation) and
  `wb append` (body content) are the only two writes this step ever makes.
- **Make a Jira ticket** → only when explicitly checked. Confirm project/summary before
  creating (outward-facing). Search first to avoid a duplicate.
- **Discuss now** → bring it up in chat this turn.
- **Keep parked** → leave the ledger entry `open`; it resurfaces next week.
- **Drop** → mark the ledger entry `status:"dropped"` (rewrite that line) so it stops
  resurfacing. For transcript-only items with no ledger entry, append a `status:"dropped"`
  tombstone keyed by a short hash of the note so the backstop won't re-raise it.

Then mark actioned ledger entries `status:"done"` (with the resulting task path / ticket
key) so the next run reconciles cleanly. Summarize what you did in chat.

## Step 5 — Offer to automate (only after it has earned trust)

Once the output is reliably useful, offer to promote to a scheduled local routine:
`/schedule` a weekly run (e.g. Mon 09:00) of `/parked-items`. Keep it **local** — a
headless/cloud run can't read `~/.claude/projects` transcripts. Don't set this up
unprompted; the manual cadence is the default.

## Notes

- Ledger status lifecycle: `open` → `done` (actioned) | `dropped` (dismissed). Never
  delete lines; rewriting status keeps an audit trail and prevents re-raising.
- Keep the action list to genuinely-open items; over-listing erodes trust in the review.
- The `--backfill` run is a one-time baseline: expect to Drop a lot of phrase-match noise
  on the first pass; subsequent weekly runs are small.
