#!/usr/bin/env bash
# gen-ae7.sh — prints the AE7 fixture (a made-up coordinator task file in the
# OLD single-file shape) on stdout: 30 decisions in all four written styles
# (two carrying a prose supersede marker), 40 handoffs, 12 open and 5 ticked
# follow-ups, a ## Done and a ## Plan. ae7-coordinator.md is this script's
# output, kept in the repo so the test reads a plain file. Deterministic:
# no clock, no randomness. All content is invented and generic.
set -euo pipefail

cat <<'EOF'
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

EOF

for i in $(seq 1 40); do
  day=$((1 + (i - 1) / 2)); [ $((i % 2)) -eq 1 ] && hm="09:00" || hm="15:30"
  if [ $((i % 7)) -eq 0 ]; then
    printf '### 2026-09-%02d %s — wb pause (auto)\n\nPaused by wb pause.\n\n' "$day" "$hm"
  else
    printf '### 2026-09-%02d %s — wb-save\n**Done:** step %d finished.\n**In flight:** step %d review.\n**Next:** start step %d.\n\n' "$day" "$hm" "$i" "$i" "$((i + 1))"
  fi
done

printf '## Decisions\n\n'
for i in $(seq 1 30); do
  d=$(printf '2026-08-%02d' "$i")
  case $((i % 4)) in
    1) printf '%s — **Decision %d lead.** The queue keeps a dead-letter lane for case %d.\n' "$d" "$i" "$i"
       if [ "$i" -eq 5 ]; then printf '1. first consequence;\n2. second consequence.\n'; fi
       printf '\n' ;;
    2) printf '### %s 10:%02d — Decision %d title\n- Decided (Jet): option %d wins.\n- Rejected: option %d-b, which costs more.\n' "$d" "$i" "$i" "$i" "$i"
       if [ "$i" -eq 6 ]; then printf -- '- Why: simpler to run. (supersedes: 2026-08-02 "Probe 6")\n\n'; else printf -- '- Why: simpler to run.\n\n'; fi ;;
    3) printf '%s decision-page topic-%d r1: answered all questions on the page.' "$d" "$i"
       if [ "$i" -eq 11 ]; then printf ' (supersedes: 2026-08-05 "Probe 2")'; fi
       printf '\n\n' ;;
    0) printf -- '- **%s (Jet): Decision %d title.** The workers retry three times.\n  - detail line one for %d\n  - detail line two for %d\n\n' "$d" "$i" "$i" "$i" ;;
  esac
done

printf '## Done\n\n2026-08-04 — Kickoff finished; the queue prototype shipped.\n- tidied the repo layout\n\n'

printf '## Follow-ups\n\n'
for i in $(seq 1 12); do
  if [ $((i % 3)) -eq 0 ]; then
    printf -- '- [ ] **2026-09-%02d:** follow-up %d, check the retry numbers.\n  - sub-point for %d\n\n' "$i" "$i" "$i"
  else
    printf -- '- [ ] Follow-up %d without a date.\n\n' "$i"
  fi
  if [ "$i" -le 5 ]; then printf -- '- [x] Ticked item %d, already done.\n\n' "$i"; fi
done
