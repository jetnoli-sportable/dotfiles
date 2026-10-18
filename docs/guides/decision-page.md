---
title: decision-page
status: current
tile: Put a batch of about 4-25 decisions, each with its own options and evidence, on one page you answer at your own pace and paste back.
group: skills
kind: guide
updated: 2026-10-18
---

## Overview

`decision-page` turns a batch of decisions into one self-contained `.html` page.
The agent writes a JSON spec into the task dossier, runs one generator command,
and the page opens in your browser. Each decision has its own options, evidence
and a recommended pick. Your answers save in the browser as you click, so you
can leave and come back; **Copy answers** then puts everything on the clipboard
for you to paste into the session. A plain local file is the default; the agent
can also publish the same page to claude.ai if you want to answer from another
device.

**The headline contract:** an item you did not touch is *unanswered*, never
silently filled in from the recommendation. That is the opposite of
`review-page`, where leaving a row alone accepts its suggestion.

## When to use it vs the other two

The shape of each item's answer picks the tool; trigger phrases never override
it. In short: items that each have their own options go to a `decision-buffer`
choice doc (1-3 decisions) or `decision-page` (about 4-25); a batch answered
from one shared verdict list goes to `review-page` (roughly 15 or more) or a
`decision-buffer` findings-review doc. The full rule, including batches over 25
and the `/weekly-review` and `/wb-breakdown` exemption, is owned by
`claude/.claude/skills/decision-page/SKILL.md`.

## Try it

A fixture spec ships with the skill. Generate its page:

```bash
python3 claude/.claude/skills/decision-page/scripts/decision-page.py \
  --spec claude/.claude/skills/decision-page/fixtures/example-spec.json \
  --out ~/code/tasks/dossiers/decision-page-example.html
```

The command prints `wrote:`, `spec_hash:` and `opened:` lines and returns at
once. Output goes under a non-hidden, non-`/tmp` path because snap Chromium
cannot read files in either.

## On the page

Keys (none active while typing in a note): `j` `k` move between items; `Enter`
opens the first open item; `e` expands an item's details, `E` expands every
item; `n` writes a note on the item; `[` collapses the sidebar; `?` lists the
keys; `1`-`9` pick an option; `a` picks the recommendation (again to undo); `c`
clears the item back to untouched.

Defer is a real option on every open item and counts as an answer.

## Copy answers and round 2

Copy answers produces a short readable summary plus a fenced JSON block carrying
the spec hash. Paste it into the session. The agent checks the hash against the
spec, answers any note before acting on the choice beside it, records resolved
decisions in the task file, and leaves unanswered items open.

If anything is left open, the agent writes a round-2 spec containing only those
items (settled ones collapse into a summary, and an item you wrote a note on
shows your note and the agent's reply). Round 2 is a new page; earlier answers
never pre-fill it.
