---
name: park
description: Capture a "deal with this later" item to the parked-items ledger so the weekly /parked-items review surfaces it. Use when the user types /park <note>, or says "park this", "let's discuss this later", "make a scratch/follow-up task for this", "revisit this later", "remind me to come back to this" — append the item rather than letting it slip. Pairs with /parked-items (the weekly review).
---

# Park

Append one "later" item to the parked-items ledger. Fast, no ceremony — this is the
manual-capture half of the parked-items workflow ([[parked-items]] is the weekly review).

## When this applies

- The user types `/park <note>` (the note is everything after `/park`).
- The user says, in passing, to park / defer / revisit / "discuss later" / "make a
  scratch or follow-up task for" something. When you detect this mid-conversation,
  append it proactively AND tell the user in one line that you parked it (so capture
  isn't silent). If a `/park` argument is empty, summarize the thing under discussion
  into a one-line note yourself.

## What to do

Append a single JSON line to `~/.claude/parked-items/ledger.jsonl`. Build the object with
`jq -n` so the note is escaped safely — never hand-concatenate JSON. Capture the working
context automatically:

```bash
note="<the user's note, or your one-line summary of what to revisit>"
mkdir -p ~/.claude/parked-items
jq -nc \
  --arg ts "$(date -u +%FT%TZ)" \
  --arg cwd "$(pwd)" \
  --arg branch "$(git branch --show-current 2>/dev/null)" \
  --arg note "$note" \
  '{ts:$ts, cwd:$cwd, branch:$branch, note:$note, status:"open", source:"manual"}' \
  >> ~/.claude/parked-items/ledger.jsonl
```

Then confirm in one line, e.g. `Parked: "<note>" (<repo> @ <branch>). It'll show up in /parked-items.`

## Notes

- The ledger is append-only and global (one file across all repos). `cwd` + `branch`
  record where the item came from so the weekly review can route any follow-up task to
  the right repo.
- Do not dedupe or edit existing lines here — that is the weekly review's job.
- If the user is mid-task and clearly wants the item actioned *now* (not later), don't
  park it — just do it. Park is for things deferred out of the current flow.
