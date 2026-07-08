---
title: Slice 4b deep dive — notes-tui integration + the 4a usage-window verdict
status: current
tile: What 4b actually builds, why it's gated, and what the verdict decides.
group: personal-workflow
kind: page
updated: 2026-07-08
---

Slice 4b is the next scheduled feature after §9f/§9g, but it's blocked until
~2026-07-14 by a deliberate usage-observation window (4a). This page explains
both in depth: what 4b actually builds, why the gate exists, and what the
verdict changes depending on the answer. This page is the source; edit
`docs/slice-4b-deep-dive.md`, not the rendered `.html`.

**Roadmap:** §4, §8 build-order item 4, §9b · **Plan:** `docs/plans/2026-07-07-003-slice-4b-notes-tui-plan.md` (status: draft, gated) · **Tracking:** `~/code/tasks/dotfiles--agent-task-workflow.md` Follow-ups

## Why 4a and 4b are split at all

The picker-redesign lesson from building `wb` itself (2026-07-06): don't
ratify wiring before usage. `wb`'s picker went through a real redesign after
it shipped and got used for a few days — the initial design's assumptions
didn't survive contact with actually using it. Notes-tui integration applies
the same discipline: **4a** ships the minimal capture habit with zero
lifecycle wiring, **4b** builds the real integration only after real usage
data exists to build it against.

## What 4a already shipped (2026-07-07)

- `note.sh` sourced into `.zshrc` — `note "thought"` / `cmd | note` capture
  to `~/code/notes/inbox.md` from anywhere, auto-stamped with cwd, git
  repo+branch, and tmux session.
- No `wb` wiring, no digest automation — manual `notes digest` only, for a
  bounded ~1-week observation window (mirrors §1's hook-data clock: ship the
  minimum, watch real behavior, decide from data not guesses).
- Window started 2026-07-07, verdict due **~2026-07-14**.

## The usage-window verdict — two questions, not one

The 4a follow-up entry (`~/code/tasks/dotfiles--agent-task-workflow.md`)
frames the verdict as answering two things:

1. **Is `note` actually being used?** If capture didn't become a habit, 4b's
   whole premise (wiring a digest into `wb done`) has nothing to wire —
   the fix is a capture-ergonomics problem, not a 4b problem.
2. **Is task-end the right review moment, or did day-end win?** 4b's plan
   assumes reviewing captures when a task closes (`wb done`). If real usage
   shows people naturally reviewing at day-end instead, that's a **different
   hook point** than the plan currently assumes.

Question 2 is the one worth understanding precisely, because the plan
document itself says not to execute blindly if the answer comes back
"day-end": U3 (see below) is written against `wb done`, but if day-end wins,
**U3 needs to be re-shaped to hook the future `wb down` (§9b) instead** —
a structural change to which implementation unit does what, not just a
go/no-go gate on starting 4b at all.

## What slice 4b actually builds

Four implementation units, in dependency order, spanning two repos
(`~/code/notes-tui` and `~/code/dotfiles`):

### U1 — Per-capture inbox parsing (notes-tui, Go)

**The actual blocker**, verified 2026-07-06: `corpus.Load` parses one `Note`
per *file*, not per capture. A whole day's `inbox.md` — however many times
you ran `note` — reads back as a single Note carrying only the **first**
capture's context stamp. A `--context <session>` filter is meaningless until
this is fixed; there's nothing to filter, everything collapses into one row.

- Detect capture-block boundaries as `note.sh` actually writes them
  (`## <timestamp>` heading + `<!-- ctx: ... -->` stamp) and split `inbox.md`
  into N Notes, each with its own timestamp and context.
- Denote-format files (the daily-notes flow) keep their existing one-note-
  per-file behavior untouched — this only changes inbox parsing.
- Files: `~/code/notes-tui/internal/corpus/corpus.go` + tests.

### U2 — `--context` filter + session-aware grouping (notes-tui, Go)

- `notes digest --context <tmux-session>` filters to one session's captures.
- `--by context` grouping gains a session dimension — today it only groups
  by repo:branch, which the usage guide has been claiming incorrectly.
- Files: `~/code/notes-tui/cmd/notes/digest.go` + tests, guide/README updates.

### U3 — `wb done` digest injection (dotfiles, bash)

- The close-out review buffer opens with the session's digest already
  inline (`notes digest --by context --context "$session"`), so keepers get
  promoted deliberately with the same `- [x] keep` convention `wb done`
  already uses for the task file itself.
- **The placement constraint that makes this fiddly:** `wb done`'s cleanup
  truncates the task file at the `## Sweep` heading — anything generated
  needs to land *above* that heading and get stripped on close, mirroring
  how `wb_sweep_section` already works. Get the ordering wrong and either
  the digest never gets cleaned up, or it gets deleted before the user sees
  it.
- Kept items promote into the task file's `## Follow-ups` section (the
  plan's recommendation — matches the store-centric model everything else
  in `wb` uses); promoting into new Denote notes instead is the one
  explicitly open call, deferred to whenever this actually gets built.
- Degrades gracefully when `notes` isn't on `PATH` — skip the section, no
  error, `wb done` still works exactly as it does today.
- **This is the unit that moves to `wb down` if day-end wins the verdict.**

### U4 — Retire the interim, update the docs

Housekeeping: roadmap status notes, guide pages gain the digest step,
the 4a follow-up entry in the task store closes out with whatever verdict
gated the slice in the first place.

## Deferred to implementation time (not decided yet)

- Promotion target if the 4a window's real usage contradicts the
  recommendation (task-file Follow-ups vs. new Denote notes).
- Whether `--by context` adds the session dimension to the group key by
  default, or only behind a flag — decided at U2 based on how noisy real
  grouped output actually looks.

## Verification bar (whole slice, not just unit tests)

The plan's own bar for "done": a full `wb new` → work + `note` captures →
`wb done` cycle where the close-out buffer actually shows both captures, a
kept one lands in `## Follow-ups`, the task file carries no leftover
generated content after close, notes-tui's test suite is green, and the
daily `notes.sh` flow is completely untouched by any of this.

## The dependency chain

```
4a capture window (started 2026-07-07)
        │
        ▼
~2026-07-14 verdict ── used? task-end or day-end the review moment?
        │
        ├── day-end wins ──► re-shape U3 to hook wb down (§9b), not wb done
        │
        ▼
4b: U1 (corpus split) → U2 (--context flag) → U3 (wb done/down hook) → U4 (docs)
        │
        ▼
9b Day bookends (wb up / wb down) — consumes 4b's session-id capture,
already landing independently of this gate
```
