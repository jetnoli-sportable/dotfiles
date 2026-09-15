---
name: park
description: Capture a "deal with this later" item — routed to the standing weekly-capture doc, or proposed as a prospective task when it's work-shaped — so the weekly /weekly-review ceremony surfaces it. Use when the user types /park <note>, or says "park this", "let's discuss this later", "make a scratch/follow-up task for this", "revisit this later", "remind me to come back to this" — capture the item rather than letting it slip. Pairs with /weekly-review (the weekly ceremony that reviews everything captured here).
---

# Park

One-line capture for "deal with this later." Fast, almost no ceremony — this is the
manual-capture half of the weekly-review workflow ([[weekly-review]] is the ceremony
that reviews everything captured here).

## When this applies

- The user types `/park <note>` (the note is everything after `/park`).
- The user says, in passing, to park / defer / revisit / "discuss later" / "make a
  scratch or follow-up task for" something. When you detect this mid-conversation,
  capture it proactively AND tell the user in one line what you did (so capture isn't
  silent). If a `/park` argument is empty, summarize the thing under discussion into a
  one-line note yourself.
- If the user is mid-task and clearly wants the item actioned *now* (not later), don't
  park it — just do it. Park is for things deferred out of the current flow.

## What to do

**1. Judge whether the note is work-shaped**, and say which way you judged it in your
one-line confirmation — a wrong call is corrected in seconds, but only if it's visible.
Work-shaped means it describes a concrete change to make (a bug, a feature, a task);
everything else — a grievance, friction, a process observation, a loose idea — is not.

**2a. Not work-shaped → append to the capture doc, no asking.** A week-file append is
cheap and reversible, so just do it and report it in one line:

```bash
wb week append "<section>" "<note>"
```

`<section>` is exactly one of the four capture doc sections — pick the one that fits:

| Section | For |
|---|---|
| `What's not working` | Grievances, friction, things that are annoying or broken about the *process* |
| `What's working` | Positive feedback / things worth noting as settled |
| `New ideas` | Loose ideas — skill ideas, workflow improvements, things to consider |
| `Notes` | Anything that doesn't fit the other three |

Pass `<note>` (and `<section>`) as **separate argv values to `wb week append`** — never
compose them into a single interpolated shell string. This is the PR #52 finding:
free text containing a `"` or `#` breaks a composed string but round-trips fine as a
plain argument.

Then confirm: `Parked (not work-shaped) to "<section>": "<note>"`.

**2b. Work-shaped → propose a prospective task and ask first.** A task is a real
store write, so — unlike the capture doc — this always asks before creating one:

> This looks like work: "<note>" — want me to capture it as a task (repo: `<repo>`),
> or would you rather it just go to the weekly capture doc instead?

- On yes: `wb new --prospective <repo> <slug>`, using a short slug derived from the
  note. Confirm: `Captured as a prospective task: <repo>--<slug>. /weekly-review will
  judge it.`
- On "just the capture doc instead": fall back to 2a (append under `New ideas`
  unless the user says otherwise).
- If you cannot confidently infer `<repo>` from the current working directory /
  conversation context, ask for it as part of the same question rather than guessing.

## Notes

- `wb week append`/`wb new --prospective` are the ONLY writers — never hand-edit the
  capture doc or a task file directly, and never route through the retired
  `~/.claude/parked-items/ledger.jsonl` (gone — see [[weekly-review]]).
- Do not dedupe or edit existing capture-doc entries here — that is `/weekly-review`'s
  job (it marks each entry reviewed as it rolls it into a week record).
- `wb week path` prints the capture doc's path if you need to check what's already
  there before appending.
