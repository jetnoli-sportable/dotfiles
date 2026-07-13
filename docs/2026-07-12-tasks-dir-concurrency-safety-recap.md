---
title: Recap — TASKS_DIR concurrency safety (hook guards + per-task write locks)
status: current
tile: Ten units, three layers, four real incidents — how ~/code/tasks got safe for concurrent agents, and what's still deliberately dormant.
group: personal-workflow
kind: page
updated: 2026-07-12
---

`~/code/tasks` is a single shared git checkout every `wb`-driven Claude
Code session reads and writes, and this machine routinely runs 8-10+
agents at once. Nothing guarded that checkout before this work — and it
showed. A code review flagged that concurrent `handoff.sh` invocations for
the same task could race. Two separate `git reset --hard` calls each
briefly orphaned another session's unpushed commits, one caught only
because a garbage-collected object hadn't actually been swept yet. And a
fourth incident was reproduced live, not just observed: `wb_append_handoff`
and `wb_set_frontmatter` running as two unlocked read-modify-write-via-`mv`
cycles on the same task file, silently dropping a write. Four incidents,
two genuinely different danger classes — git-history rewinds and
file-write collisions — and no existing guard covered either.

## What got built

Three layers, because no single guard can see both danger classes. A
Claude Code `PreToolUse` hook (`pretooluse-guard.sh`) now **asks** before
any dangerous-shaped git command or raw file edit runs against
`~/code/tasks` — cheap, pattern-based, fails open, never blocks outright.
A `reference-transaction` git hook now **refuses**, at the git level
itself, any non-fast-forward ref update that would orphan a commit
reachable from nowhere else — caller-agnostic, so it catches a raw
terminal command exactly as well as an agent's. And a per-task-file
`flock` side-car lock (`wb-locks.sh`) now **serializes** every write burst
across `wb.sh`, `handoff.sh`, and a new locked `wb append` verb that
`/wb-save`, `/handoff`, and `/parked-items` now shell out to instead of
editing task files directly with an editor tool.

Around those three mechanisms: a one-time escape hatch
(`wb unsafe-rewind "<reason>"`, a 120-second one-use sentinel) for the rare
deliberate rewind; a paved path (`wb sync`) that fetches, checks for a
clean fast-forward, and refuses loudly on anything else — removing the
reason to reach for `reset --hard` in the first place; `wb install-hooks`
to wire a host up idempotently; and an X7 replay tool
(`replay-refusals.sh`) that walks a repo's real reflog history read-only
and reports what the git hook *would* have refused, so a human can judge
the logic against real history before trusting it live.

## What's deliberately not enabled yet

The git-side hook ships **installed but dormant**. `wb install-hooks`
pre-creates its kill-switch file unless a `replay-passed` marker already
exists, so the hook is inert from day one on any host that runs it. Two
separate, sequential human decisions stand between "installed" and
"live": first, running `replay-refusals.sh` and reading its output to
confirm it refuses only the known incidents and nothing else, optionally
recording that pass; second — and only after that — manually deleting the
`disable-git-hook` switch file. Nothing automates either step, and
writing the replay-passed marker is explicitly not the same act as
enabling the hook. Locks and the agent-side "ask" hook, by contrast, are
live immediately — the agent hook just needs the one-time settings paste
and a restart of any already-running sessions, since hook config is
snapshotted at session start.

## Where to go next

The full reference — the layer model, a coverage matrix, a command traced
through all three layers, the kill-switch table, and runbooks for lock
contention, a refused-rewind's aftermath, and the install/enablement
sequence — lives in the
[tasks-store-guards guide](tasks-store-guards.html). The roadmap row is
[detail-tasks-concurrency-safety](roadmap.html#detail-tasks-concurrency-safety),
now in Shipped. The one planned follow-up this work didn't attempt:
`~/code/notes` is a confirmed structural twin to `~/code/tasks` with the
same unguarded-checkout shape, deferred to its own task rather than
folded in here.
