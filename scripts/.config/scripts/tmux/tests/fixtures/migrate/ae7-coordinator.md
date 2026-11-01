---
status: doing
path:
repo: proj
branch: feat/pipeline-coordinator
worktree: .worktrees/feat/pipeline-coordinator
parent:
depends_on:
size: L
priority:
value:
tags: []
jira:
created: 2026-08-03
closed:
reviewed:
claude_sessions:
---
# Pipeline coordinator

**First action when picked up:** read the Plan, then the newest handoff.

## Plan

The coordinator owns the rollout of the batch pipeline in four rungs.

```text
## Decisions
(this heading is inside a fence, so it is plan text, not a section)
```

1. Rung one: the queue.
2. Rung two: the workers.

## Handoffs

### 2026-09-01 09:00 — wb-save
**Done:** step 1 finished.
**In flight:** step 1 review.
**Next:** start step 2.

### 2026-09-01 15:30 — wb-save
**Done:** step 2 finished.
**In flight:** step 2 review.
**Next:** start step 3.

### 2026-09-02 09:00 — wb-save
**Done:** step 3 finished.
**In flight:** step 3 review.
**Next:** start step 4.

### 2026-09-02 15:30 — wb-save
**Done:** step 4 finished.
**In flight:** step 4 review.
**Next:** start step 5.

### 2026-09-03 09:00 — wb-save
**Done:** step 5 finished.
**In flight:** step 5 review.
**Next:** start step 6.

### 2026-09-03 15:30 — wb-save
**Done:** step 6 finished.
**In flight:** step 6 review.
**Next:** start step 7.

### 2026-09-04 09:00 — wb pause (auto)

Paused by wb pause.

### 2026-09-04 15:30 — wb-save
**Done:** step 8 finished.
**In flight:** step 8 review.
**Next:** start step 9.

### 2026-09-05 09:00 — wb-save
**Done:** step 9 finished.
**In flight:** step 9 review.
**Next:** start step 10.

### 2026-09-05 15:30 — wb-save
**Done:** step 10 finished.
**In flight:** step 10 review.
**Next:** start step 11.

### 2026-09-06 09:00 — wb-save
**Done:** step 11 finished.
**In flight:** step 11 review.
**Next:** start step 12.

### 2026-09-06 15:30 — wb-save
**Done:** step 12 finished.
**In flight:** step 12 review.
**Next:** start step 13.

### 2026-09-07 09:00 — wb-save
**Done:** step 13 finished.
**In flight:** step 13 review.
**Next:** start step 14.

### 2026-09-07 15:30 — wb pause (auto)

Paused by wb pause.

### 2026-09-08 09:00 — wb-save
**Done:** step 15 finished.
**In flight:** step 15 review.
**Next:** start step 16.

### 2026-09-08 15:30 — wb-save
**Done:** step 16 finished.
**In flight:** step 16 review.
**Next:** start step 17.

### 2026-09-09 09:00 — wb-save
**Done:** step 17 finished.
**In flight:** step 17 review.
**Next:** start step 18.

### 2026-09-09 15:30 — wb-save
**Done:** step 18 finished.
**In flight:** step 18 review.
**Next:** start step 19.

### 2026-09-10 09:00 — wb-save
**Done:** step 19 finished.
**In flight:** step 19 review.
**Next:** start step 20.

### 2026-09-10 15:30 — wb-save
**Done:** step 20 finished.
**In flight:** step 20 review.
**Next:** start step 21.

### 2026-09-11 09:00 — wb pause (auto)

Paused by wb pause.

### 2026-09-11 15:30 — wb-save
**Done:** step 22 finished.
**In flight:** step 22 review.
**Next:** start step 23.

### 2026-09-12 09:00 — wb-save
**Done:** step 23 finished.
**In flight:** step 23 review.
**Next:** start step 24.

### 2026-09-12 15:30 — wb-save
**Done:** step 24 finished.
**In flight:** step 24 review.
**Next:** start step 25.

### 2026-09-13 09:00 — wb-save
**Done:** step 25 finished.
**In flight:** step 25 review.
**Next:** start step 26.

### 2026-09-13 15:30 — wb-save
**Done:** step 26 finished.
**In flight:** step 26 review.
**Next:** start step 27.

### 2026-09-14 09:00 — wb-save
**Done:** step 27 finished.
**In flight:** step 27 review.
**Next:** start step 28.

### 2026-09-14 15:30 — wb pause (auto)

Paused by wb pause.

### 2026-09-15 09:00 — wb-save
**Done:** step 29 finished.
**In flight:** step 29 review.
**Next:** start step 30.

### 2026-09-15 15:30 — wb-save
**Done:** step 30 finished.
**In flight:** step 30 review.
**Next:** start step 31.

### 2026-09-16 09:00 — wb-save
**Done:** step 31 finished.
**In flight:** step 31 review.
**Next:** start step 32.

### 2026-09-16 15:30 — wb-save
**Done:** step 32 finished.
**In flight:** step 32 review.
**Next:** start step 33.

### 2026-09-17 09:00 — wb-save
**Done:** step 33 finished.
**In flight:** step 33 review.
**Next:** start step 34.

### 2026-09-17 15:30 — wb-save
**Done:** step 34 finished.
**In flight:** step 34 review.
**Next:** start step 35.

### 2026-09-18 09:00 — wb pause (auto)

Paused by wb pause.

### 2026-09-18 15:30 — wb-save
**Done:** step 36 finished.
**In flight:** step 36 review.
**Next:** start step 37.

### 2026-09-19 09:00 — wb-save
**Done:** step 37 finished.
**In flight:** step 37 review.
**Next:** start step 38.

### 2026-09-19 15:30 — wb-save
**Done:** step 38 finished.
**In flight:** step 38 review.
**Next:** start step 39.

### 2026-09-20 09:00 — wb-save
**Done:** step 39 finished.
**In flight:** step 39 review.
**Next:** start step 40.

### 2026-09-20 15:30 — wb-save
**Done:** step 40 finished.
**In flight:** step 40 review.
**Next:** start step 41.

## Decisions

2026-08-01 — **Decision 1 lead.** The queue keeps a dead-letter lane for case 1.

### 2026-08-02 10:02 — Decision 2 title
- Decided (Jet): option 2 wins.
- Rejected: option 2-b, which costs more.
- Why: simpler to run.

2026-08-03 decision-page topic-3 r1: answered all questions on the page.

- **2026-08-04 (Jet): Decision 4 title.** The workers retry three times.
  - detail line one for 4
  - detail line two for 4

2026-08-05 — **Decision 5 lead.** The queue keeps a dead-letter lane for case 5.
1. first consequence;
2. second consequence.

### 2026-08-06 10:06 — Decision 6 title
- Decided (Jet): option 6 wins.
- Rejected: option 6-b, which costs more.
- Why: simpler to run. (supersedes: 2026-08-02 "Probe 6")

2026-08-07 decision-page topic-7 r1: answered all questions on the page.

- **2026-08-08 (Jet): Decision 8 title.** The workers retry three times.
  - detail line one for 8
  - detail line two for 8

2026-08-09 — **Decision 9 lead.** The queue keeps a dead-letter lane for case 9.

### 2026-08-10 10:10 — Decision 10 title
- Decided (Jet): option 10 wins.
- Rejected: option 10-b, which costs more.
- Why: simpler to run.

2026-08-11 decision-page topic-11 r1: answered all questions on the page. (supersedes: 2026-08-05 "Probe 2")

- **2026-08-12 (Jet): Decision 12 title.** The workers retry three times.
  - detail line one for 12
  - detail line two for 12

2026-08-13 — **Decision 13 lead.** The queue keeps a dead-letter lane for case 13.

### 2026-08-14 10:14 — Decision 14 title
- Decided (Jet): option 14 wins.
- Rejected: option 14-b, which costs more.
- Why: simpler to run.

2026-08-15 decision-page topic-15 r1: answered all questions on the page.

- **2026-08-16 (Jet): Decision 16 title.** The workers retry three times.
  - detail line one for 16
  - detail line two for 16

2026-08-17 — **Decision 17 lead.** The queue keeps a dead-letter lane for case 17.

### 2026-08-18 10:18 — Decision 18 title
- Decided (Jet): option 18 wins.
- Rejected: option 18-b, which costs more.
- Why: simpler to run.

2026-08-19 decision-page topic-19 r1: answered all questions on the page.

- **2026-08-20 (Jet): Decision 20 title.** The workers retry three times.
  - detail line one for 20
  - detail line two for 20

2026-08-21 — **Decision 21 lead.** The queue keeps a dead-letter lane for case 21.

### 2026-08-22 10:22 — Decision 22 title
- Decided (Jet): option 22 wins.
- Rejected: option 22-b, which costs more.
- Why: simpler to run.

2026-08-23 decision-page topic-23 r1: answered all questions on the page.

- **2026-08-24 (Jet): Decision 24 title.** The workers retry three times.
  - detail line one for 24
  - detail line two for 24

2026-08-25 — **Decision 25 lead.** The queue keeps a dead-letter lane for case 25.

### 2026-08-26 10:26 — Decision 26 title
- Decided (Jet): option 26 wins.
- Rejected: option 26-b, which costs more.
- Why: simpler to run.

2026-08-27 decision-page topic-27 r1: answered all questions on the page.

- **2026-08-28 (Jet): Decision 28 title.** The workers retry three times.
  - detail line one for 28
  - detail line two for 28

2026-08-29 — **Decision 29 lead.** The queue keeps a dead-letter lane for case 29.

### 2026-08-30 10:30 — Decision 30 title
- Decided (Jet): option 30 wins.
- Rejected: option 30-b, which costs more.
- Why: simpler to run.

## Done

2026-08-04 — Kickoff finished; the queue prototype shipped.
- tidied the repo layout

## Follow-ups

- [ ] Follow-up 1 without a date.

- [x] Ticked item 1, already done.

- [ ] Follow-up 2 without a date.

- [x] Ticked item 2, already done.

- [ ] **2026-09-03:** follow-up 3, check the retry numbers.
  - sub-point for 3

- [x] Ticked item 3, already done.

- [ ] Follow-up 4 without a date.

- [x] Ticked item 4, already done.

- [ ] Follow-up 5 without a date.

- [x] Ticked item 5, already done.

- [ ] **2026-09-06:** follow-up 6, check the retry numbers.
  - sub-point for 6

- [ ] Follow-up 7 without a date.

- [ ] Follow-up 8 without a date.

- [ ] **2026-09-09:** follow-up 9, check the retry numbers.
  - sub-point for 9

- [ ] Follow-up 10 without a date.

- [ ] Follow-up 11 without a date.

- [ ] **2026-09-12:** follow-up 12, check the retry numbers.
  - sub-point for 12

