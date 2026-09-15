---
name: weekly-review
description: The weekly ceremony that replaces the three lapsed dated clocks (docs/ceremonies.md) — gathers wb-reconcile drift, the standing capture doc's unreviewed entries, tasks moved / PRs merged since last review, and skill-usage counts, classifies each capture (task idea / skill idea / grievance / workflow improvement), presents at most a handful of suggestions on the review page (never an nvim buffer), and emits a per-week output record with Retro + Sprint-planning rollups plus what was actioned vs. carried over. Accepted suggestions are seeded as tasks tagged weekly-review via locked wb verbs. Use when the user types /weekly-review, says "run the weekly review", "let's do the weekly review", or it's been roughly a week since the last one (`wb_pending_counts`/the picker status line surfaces the due signal). Pairs with /park (capture) and retires /parked-items.
---

# Weekly review

The single ceremony that replaces the three dated clocks that lapsed for seven weeks in
`docs/ceremonies.md`. `/park` ([[park]]) is capture; this skill is the review half — it
also absorbs `/parked-items`' reconciliation (R6) and `/hindsight`'s process-retro framing.

## Evidence, in this fixed order

Gather all four before classifying anything — later steps route items collected in
earlier ones, so order matters. Run from the dotfiles repo (main checkout, not a
worktree — `wb week`/`wb reconcile` are stowed there).

**1. `wb reconcile --machine`** — task-store/git worktree drift, machine-readable (R6,
first evidence step, replacing `/parked-items`' reconciliation). Parse per
`scripts/.config/scripts/tmux/wb.sh`'s own header comment on `--machine`: an `orphan`
row's fifth field is a merge status, a `missing` row's fifth field is a task-file path —
NOT the same meaning, don't conflate them.

**2. The capture doc's unreviewed entries** — mint this week's record, which rolls up
every `- [ ]` entry per section and marks it reviewed in the same call:

```bash
WB="$DOTFILES/scripts/.config/scripts/tmux/wb.sh"
record="$("$WB" week record)"
```

`$record` now holds the raw entries under each of the four capture-doc sections
(`What's working` / `What's not working` / `New ideas` / `Notes`), plus a link to the
previous record if one exists. This is your classification input for the next section —
read `$record`, don't re-read the capture doc (its entries are already flipped to
reviewed).

**3. Tasks moved and PRs merged since the last review.** Find the previous record from
the "Previous record" line `wb week record` just printed (or `none` on the first-ever
run). If one exists, read its "Actioned vs. carried over" section for the task refs it
seeded, then check each: `status: done`? A merged PR (`gh pr list --state merged` /
`wb reconcile`'s orphan rows already surface merged branches)? This is R5 — the review
opens by checking whether last week's accepted increments actually shipped, not just
trusting the plan.

**4. Skill-usage counts** — reproducible per-skill counts with stated blind spots (R29):

```bash
scripts/.config/scripts/skill-usage.sh --skills-dir claude/.claude/skills --since <last-record-date-or-30d-ago>
```

A zero count is NOT DETECTED, never "unused" — carry that caveat forward if you cite a
count in a suggestion.

## Classify each capture entry

For every entry gathered in evidence step 2, classify it and state the classification —
this is D2's judge-and-say-so-in-one-line contract, applied per item rather than to the
whole run:

| Classification | Routes to |
|---|---|
| **Task idea** — a concrete change worth doing | Sprint planning, as a candidate suggestion |
| **Skill idea** — a new/changed agent skill | Sprint planning, as a candidate suggestion |
| **Grievance** — friction, something that didn't work | Retro |
| **Workflow improvement** — a process observation, not a specific task | Retro, and Sprint planning if it implies a concrete change |

`What's working` entries are a fourth feed and are **never auto-closing** — a positive
note may let you *ask* whether it settles an open question from a prior review, but it
never closes one on its own (Jet's own correction during design: "if it allows us to
consider something settled we can ask that during the review").

## Present on the review page

**Never an nvim buffer** — the parent plan's own live-use Follow-ups are explicit that a
50+-row-capable format needs the review page (`[[review-page]]`). Load
`claude/.claude/skills/review-page/references/spec-and-close-contract.md` before writing
the spec. Build one row per Task-idea/Skill-idea candidate (Retro-routed
grievances/workflow items don't need a row — they're narrative, not a decision — unless
one implies a concrete action worth a verdict too). Cap candidate rows at **five** (R4) —
if classification produced more, pick the five most load-bearing and note the rest
explicitly as carried over to next week's capture doc rather than silently dropped.

Each row's `suggested` verdict is one of: `Seed as prospective task` / `Seed as planned
task` / `Already covered (name the existing task)` / `Drop`. Cite the evidence (which
capture entry, plus anything from steps 1/3/4 that bears on it) so the verdict can be
judged from the page alone.

Open the page **with `--timeout`**, and if it exits 4 (tab closed without submit, or a
stuck backgrounded call), recover with `--reattach` rather than re-running from scratch —
see the review-page skill's own "Open it" section for the exact recipe.

## Seed accepted suggestions

For every row that resolves to `Seed as prospective task` or `Seed as planned task`, two
locked-verb calls — `wb new` has no `--tags` flag, so tagging is always a second call:

```bash
task_file="$("$WB" new --prospective "$repo" "$slug")"   # or --planned, per the verdict
"$WB" set "$repo--$slug" tags weekly-review
```

Never Write/Edit a file under `$TASKS_DIR` directly for this — creation and tagging are
the only two writes this step makes, both through locked verbs, both taking argv values
(never a composed/interpolated string).

## Emit the output record

`wb week record` already minted `$record` with placeholder `## Retro`, `## Sprint
planning`, and `## Actioned vs. carried over` sections (each reading `(filled in by
/weekly-review)`). Edit that file (a plain doc under `weeks/`, not a task file — outside
the locked-verb requirement, same as `/parked-items`' own review file) to replace those
placeholders with:

- **Retro** — every Grievance/Workflow-improvement item, one line each, plus what — if
  anything — a `What's working` entry settled this round (asked, not assumed).
- **Sprint planning** — the review-page's resolved rows: what was seeded (task ref),
  what was dropped (one-line why), what was already covered (link the existing task).
- **Actioned vs. carried over** — the two numbers U9's acceptance criterion wants
  recorded in every record: (1) suggestions accepted vs. dropped, (2) suggestions already
  covered by an existing task (the review's duplicate rate) — plus the >5-candidate
  carry-over list from the page step, if any.

## Notes

- Evidence order is fixed (reconcile → capture doc → moved/merged → skill-usage) because
  later classification depends on earlier evidence, not just for tidiness.
- `wb week append`/`wb week record`/`wb new`/`wb set` are the only writers this skill
  ever calls — never a raw Edit/Write against `$TASKS_DIR` task files. The week record
  itself is the one exception (see "Emit the output record" above).
- The ceremony stays **manually invoked** — no calendar/hook trigger — until it proves
  itself across a few real runs (parent plan's own Scope Boundaries).
- If suggestion counts or duplicate rates trend toward "nothing new surfaced" over a few
  weeks, that's the signal to reconsider the ceremony, not to automate it harder — see
  the plan's own Risks section and its dated week-3 re-evaluation task.
