---
title: review-page
status: current
tile: Serve a large batch review (25+ rows) as a local HTML page with defaults, grouping, and questions — instead of an unreadable nvim buffer.
group: skills
kind: guide
updated: 2026-09-14
---

## Overview

`review-page` serves a large review — a task-store triage, a piece/skill
audit, a prune list, a `wb-breakdown` proposal, a weekly review — as a
locally-hosted HTML page instead of a markdown buffer in nvim. It split out
of `decision-buffer`'s seventh shape once it became clear the mechanism (a
spec file, an HTTP server, a browser tab, filtering, keyboard navigation) is
different enough from the other six nvim-buffer shapes to be its own thing.
Every row carries evidence, a suggested verdict, and an optional note; the
page can be filtered, searched, and grouped, and closes by POSTing an
`answers.json` back to the waiting agent — same open/wait/parse contract as
every `decision-buffer` shape, just served over `http://127.0.0.1` instead
of opened in a tmux pane.

**The headline contract, worth stating up front:** in this flow, leaving a
row alone means you **accept its suggested verdict** — the opposite of the
nvim `decision-buffer` rule, where silence applies nothing. Opting a row out
takes an explicit act: changing its verdict, writing a note on it, or a word
in the page's global questions box.

## Try it

A 3-row fixture spec ships at
`claude/.claude/skills/review-page/fixtures/example-spec.json` — run the
script against it to see the page live:

```bash
python3 claude/.claude/skills/review-page/scripts/review-page.py \
  --spec claude/.claude/skills/review-page/fixtures/example-spec.json \
  --out /tmp/review-page-example-answers.json \
  --title "Example Review"
```

This blocks in your terminal (it's meant to run backgrounded when an agent
calls it) and opens a browser tab on a free `127.0.0.1` port. Two of the
fixture's three rows have a suggested verdict pre-selected; the third
(`row-3`) has none, so it shows as "needs me" and stays unresolved even if
you leave it alone. Click Submit (with or without touching anything) to see
`answers.json` written to `/tmp/review-page-example-answers.json`, then
Ctrl-C the script if it's still running.

## How it differs from decision-buffer

| | `decision-buffer` (six nvim shapes) | `review-page` |
|---|---|---|
| Surface | markdown buffer in nvim, opened in a tmux split | HTML page served on `127.0.0.1`, opened in a browser tab |
| Scale | small batches, a handful of options/questions | large batches, ≳25 rows |
| Untouched-row default | **nothing applies** — silence is never consent | **the suggested verdict applies** — silence is consent unless a note says otherwise |
| Per-row extras | none needed at that scale | evidence toggle, dependency chips, free-text grouping, Agree button |
| Opting out | leave everything unmarked | change the verdict, or leave a row/global note |

Use `decision-buffer` instead for a settled 2-4 option choice or a short
interview — the review-page machinery (spec file, HTTP server, filters) is
overkill below its threshold. See `claude/.claude/skills/review-page/SKILL.md`
for the fuller when-to-use guidance and the exact spec-writing rules.

## The close rule

1. A **row note** or the page's **global questions box** must be answered
   before anything tied to it is acted on.
2. A row with no note, left untouched, and carrying a non-empty `suggested`
   verdict: **that suggestion applies** — same as if the user had clicked
   Agree.
3. A row with **no suggestion at all** (empty `suggested`) and left
   untouched is **unresolved** — there's nothing to silently accept, so it
   gets re-asked rather than defaulted or skipped.
4. The footer's "accept remaining defaults for untouched rows" checkbox is
   pre-ticked by default (a spec can turn this off with
   `"accept_defaults_default": false`); unticking it flips untouched rows
   back to "apply nothing" — Submit only warns in that case.
5. A second round rewrites the spec fresh with only the still-unresolved
   rows — settled ones collapse into a summary rather than being reshown.

Full field-by-field detail lives in
`claude/.claude/skills/review-page/references/spec-and-close-contract.md`.
