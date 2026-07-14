---
title: tasks-store-guards
status: current
tile: The three-layer concurrency-safety model guarding ~/code/tasks — ask, refuse, serialize — plus runbooks for lock contention, refused rewinds, and enablement.
group: personal-workflow
kind: guide
updated: 2026-07-14
---

## Overview

`~/code/tasks` (`TASKS_DIR`) is a single shared git checkout that every
`wb`-driven Claude Code session touches, regardless of which repo or
worktree that session is actually working in — and this machine routinely
runs 8-10+ concurrent agents. Before this work, nothing serialized or
guarded that checkout at all. Four real incidents proved the gap:

1. **`feat/handoff-v1`'s own code review** found that concurrent
   `handoff.sh` invocations for the same repo/slug can race — no
   lockfile existed anywhere.
2. **A `git reset --hard origin/development`** briefly orphaned another
   session's unpushed commits — caught only because nothing had been
   pushed yet.
3. **A second, independent reset** silently discarded a just-committed
   task-file update; it was recoverable only because the commit object
   hadn't been garbage-collected yet.
4. **A reproduced silent lost write** between `wb_append_handoff` and
   `wb_set_frontmatter` — two unlocked read-modify-write-via-`mv` cycles
   on the same task file, confirmed live 2026-07-11.

Incidents 2-3 are one danger class (**git-history rewinds** — a raw
command discards ref history); incidents 1 and 4 are a completely
different one (**file-write collisions** — two writers race on the same
task file's *content*, which git never sees at all since these are plain
file writes, not commits). No single guard can see both classes, so this
ships as three layers — a cheese-slice model where each layer's blind
spots are covered by one of the other two:

| Layer | Verb | Lives in | What it does |
|---|---|---|---|
| **1 — agent hook** | ASKS | Claude Code `PreToolUse`, `tasks-git-hooks/pretooluse-guard.sh` | Cheap pattern+directory match on dangerous git shapes and raw `Edit`/`Write`/`MultiEdit` calls scoped to `~/code/tasks`, *before* they run. Always `"ask"`, never `"deny"`; fails open on any internal error. |
| **2 — git guard** | REFUSES | `core.hooksPath`, `tasks-git-hooks/reference-transaction` | The real correctness judgment. Caller-agnostic — git enforces it for Claude, a raw terminal, anything — refusing a non-fast-forward ref update that would orphan a commit reachable from no other ref. |
| **3 — file lock** | SERIALIZES | `scripts/.config/scripts/tmux/wb-locks.sh` | One `flock` side-car per task file. Every write burst in `wb.sh`/`handoff.sh`, plus the new `wb append` verb, takes it; a blocked writer halts loudly (exit 75) instead of racing the holder. |

Layers 1+2 cover the GIT dangers (incidents 2-3); layer 3 covers the FILE
dangers (incidents 1 and 4). Remove any one layer and a real,
already-observed incident class goes back to being unguarded.

## Coverage matrix — who is stopped, where

| Dangerous action | L1 agent hook | L2 git guard | L3 file lock |
|---|---|---|---|
| Claude session types `git reset --hard` in `~/code/tasks` *(incidents 2 & 3)* | asks you first | refuses if commits would be orphaned | — |
| You type `git reset --hard` in a raw terminal | can't see it (Claude-only) | refuses; offers a y/N prompt since a real tty is open | — |
| Two writers hit the same task file at once *(incidents 1 & 4)* | asks if either write goes through a raw `Edit`/`Write`/`MultiEdit` under `~/code/tasks` (H24) | git never sees plain file writes | second writer waits ≤1s on `flock -w 1`, then halts loudly (exit 75) rather than racing |
| Two concurrent `wb new`/`wb resume` seed paths for the *same* new task | — | — | one seeds; the other blocks on the same lock, then halts (never an interleaved file) |
| Ordinary safe git (commit, fetch, fast-forward pull) | no match → zero friction | fast-forward check (`merge-base --is-ancestor`) passes instantly | — |
| `git clean -fdx` typed by a human in a raw terminal | — | partial — git has no hook for working-tree wipes | — |

The bottom row is the honest, documented gap: no layer fully covers a
human wiping uncommitted files from a raw terminal (see "What this
deliberately doesn't do" below). Every incident actually observed (all
four) is covered.

## Walkthrough — one dangerous command, traced through all three layers

An agent session runs `git reset --hard origin/development` from inside
`~/code/tasks`:

1. **L1 matches and asks.** `pretooluse-guard.sh`'s `DANGEROUS_RE` matches
   `reset[[:space:]]+--hard`; H4's directory resolution (explicit `-C`/
   `--git-dir`, an in-command `cd`, else the hook payload's `cwd`) scopes
   it to `$HOME/code/tasks`. It emits `permissionDecision: "ask"`, naming
   the matched command, the incident precedent, and `wb sync`/`wb
   unsafe-rewind` as the intended alternatives — and states explicitly
   that approving here does not bypass L2.
2. **Operator approves.** The Bash tool call actually runs.
3. **git invokes L2.** Because `wb install-hooks` pointed
   `core.hooksPath` at `tasks-git-hooks/`, git calls `reference-transaction`
   in its `"prepared"` state before the ref update is finalized.
4. **L2 checks reachability.** Is `old` an ancestor of `new`
   (`merge-base --is-ancestor`)? If this reset is a true fast-forward,
   it passes instantly. If not, L2 computes the would-be-orphaned set
   (`git rev-list <old> --not <every other ref>`, per `build_refusal_message`
   in `reference-transaction`). If anything in it is reachable from no
   other ref, L2 refuses: exit 1, and the transaction never happens — the
   ref pointer itself never moves.
5. **The refusal message's own words matter.** `build_refusal_message`
   states, verified live on git 2.43.0: the refusal does **not** undo
   what the git command already did to the index and working tree — those
   have *already* moved to the target, so any uncommitted tracked changes
   are already gone by the time the hook runs. "Refused" means the ref
   didn't move and history is preserved; it does not mean nothing
   happened. See the aftermath runbook below.
6. **The escape hatch, if the operator genuinely means it.**
   `wb unsafe-rewind "<reason>"` writes `<epoch> <reason>` to
   `$TASKS_DIR/.git/WB_ALLOW_REWIND` (refuses an empty reason). L1 sees a
   fresh sentinel *only after* it has already matched and scoped the
   command (H6 — never before, or a 120s sentinel becomes "allow
   everything") and emits `"allow"` instead of `"ask"`. L2 sees the fresh
   sentinel, consumes it (deletes the file, tracked per-`PPID` so a single
   git porcelain command's multiple internal `"prepared"` calls don't each
   need their own sentinel), and allows exactly one transaction. The TTL
   is 120 seconds either way.

## The paved path: `wb sync`

`wb sync` removes the reason to reach for `git reset --hard` in the first
place: it fetches, checks for a clean fast-forward, and refuses loudly on
anything else. It's the alternative L1's own "ask" message points you at —
reach for it before a raw rewind, not after.

## Kill switches

Each layer checks its own switch file, under
`${XDG_STATE_HOME:-$HOME/.local/state}/wb/`, before doing anything else —
presence alone disables that layer (content is never read). Files, not
environment variables: an already-running session never picks up a new
env var, but every next command re-reads the filesystem.

| Switch file | Turns off | Where it's checked | Notes |
|---|---|---|---|
| `disable-agent-hook` | L1 asking | first line of `pretooluse-guard.sh`, before stdin is even read | Use if the hook misfires on safe commands. |
| `disable-git-hook` | L2 refusing | first check in `reference-transaction`, before the `"prepared"`-state gate | **Ships pre-created** by `wb install-hooks` — the hook installs but stays dormant — unless the `replay-passed` marker already exists. Removed only by hand (`rm`), only after a human reads the X7 replay output and is satisfied. Recreate it any time for an emergency rollback. |
| `disable-locks` | L3 locking | first line of `wb_task_lock_acquire` in `wb-locks.sh` | Manual escape if lock infrastructure itself ever breaks; acquire becomes an instant no-op success. |

## Runbook — lock contention (exit 75)

An exit-75 halt means `wb_task_lock_acquire` tried `flock -w 1` on a task
file's side-car lock (`${XDG_STATE_HOME:-$HOME/.local/state}/wb/locks/<basename>.lock`)
and timed out because another process already holds it. The one stderr
line it prints names the recorded **holder identity** (`${repo}--${disp_slug}`),
**PID**, and **held-seconds** — read straight from the lock file's own
holder/pid/acquired fields, which are only ever written *after* a
successful acquire (never blanked by a losing contended attempt).

The message carries an explicit addressee split, and it matters:

- **Agents:** stop and report the contention upward. Never clear the lock
  yourselves — you cannot reliably tell "the holder is dead" from "the
  holder is mid-spawn" from inside a session, and clearing a live
  holder's lock is exactly the incident-1 danger (the guard becomes the
  weapon).
- **Operator only:** `rm <lock-path>` is the manual override, and it is
  addressed to you specifically — and only *after* you've confirmed the
  recorded holder is genuinely dead (its PID is gone, or its own recorded
  tmux pane/session no longer exists), never just because "the command is
  taking a while." `wb_task_lock_acquire_guarded` (the wrapper every
  `cmd_*`/`wb_reconcile_action_*` call site actually uses) already
  automates the safe half of this: on a lost contention it checks whether
  the holder PID is gone outright (kernel already dropped the flock — an
  instant, automatic retry) or whether all four orphan conditions hold at
  once (PID alive but confirmed wb/claude-shaped via `/proc/<pid>/cmdline`,
  held >60s, and the holder's *own* recorded tmux session confirmed `dead`
  via `tmux_session_agent_state`) before ever retrying on your behalf.
  Anything less — an alive holder, an `unknown` tmux state, a missing
  holder field — never auto-clears; it halts, which is what puts you in
  this runbook in the first place.

## Runbook — refused-rewind aftermath

A refused `reset --hard` (or any other rewind-shaped ref update L2 vetoes)
has **already moved the index and working tree** to the target by the
time the hook's refusal even reaches your terminal — uncommitted tracked
changes are already gone. "Refused" only means the ref pointer itself
didn't move and the commit history behind it is preserved; it does *not*
mean nothing happened. Treat the aftermath as: history is safe, your
working copy currently reflects the (refused) target state, not what you
had before.

The always-safe resync, straight from `build_refusal_message`'s own
wording: `git reset --hard HEAD`. This can never itself be refused — `old`
and `new` are identical, which trivially passes L2's fast-forward check
(`merge-base --is-ancestor` on equal values), so it always gets through.
Run it to snap your working tree/index back to what the (unmoved) ref
actually points at.

If you genuinely meant the rewind: `wb unsafe-rewind "<reason>"` first,
then re-run the same command within 120 seconds (see the walkthrough
above for exactly how the sentinel is consumed).

## Runbook — install & enablement

`wb install-hooks` is the one idempotent verb that wires up everything a
host needs — safe to re-run any time:

1. Sets `core.hooksPath` on `$TASKS_DIR` to the stowed
   `tasks-git-hooks/` directory, and hardens `gc.auto=0` plus generous
   `gc.reflogExpire`/`gc.reflogExpireUnreachable` (180 days) so a
   sentinel-blessed rewind stays recoverable by policy, not GC luck.
2. Pre-creates the `disable-git-hook` switch file — **unless** the
   `replay-passed` marker already exists — so the git layer installs but
   stays dormant by default.
3. **Verifies, never edits,** the live `~/.claude/settings.json`'s
   `PreToolUse` entries against the tracked reference copy in
   `claude/.claude/settings.recommended.json`, printing the exact block to
   paste by hand when it's missing. This is deliberate: the live settings
   file is untracked and carries other hooks (the notify pipeline behind
   the picker's needs-input tier) that a script must never risk clobbering.
   After pasting, **restart every already-running Claude Code session** —
   hook config is snapshotted at session start, so a running session won't
   see the new entry until it restarts.

Enabling the git guard is a separate, later, deliberately manual act —
never bundled into `wb install-hooks` itself:

4. Run `replay-refusals.sh --repo <path>` (read-only, mutates nothing) —
   it walks `$TASKS_DIR`'s real reflog history and approximates, per ref
   transition, what `reference-transaction` would have refused. It prints
   a report; **you** read it and judge whether the refusals are exactly
   the known incidents and nothing else. The script has no way to make
   that call itself.
5. Only once you're satisfied, run it again with `--record-pass`. This
   writes the `replay-passed` marker — which does **one thing only**: it
   stops a future `wb install-hooks` re-run from re-creating the
   `disable-git-hook` switch file. **Writing this marker is not the same
   as enabling the hook** — treat it as a separate, sequential decision
   from the next step, not a shortcut to it.
6. The actual enablement act is a manual
   `rm ${XDG_STATE_HOME:-$HOME/.local/state}/wb/disable-git-hook`. Nothing
   automates this step; it is a human, one-time decision performed once
   per host, after step 5.

## What this deliberately doesn't do

- **Not adversary-proof.** These guards catch honest multi-agent
  mistakes between your own sessions — they are not a security boundary.
  Anyone can edit the hook files or remove a lock.
- **No conflict resolution.** The lock makes writers take turns; it does
  not merge two legitimate, sequential edits to the same key. A second
  writer's value still overwrites the first's — just never silently
  mid-write.
- **No intent queue, daemon, or drain lifecycle**, and no per-agent
  worktree topology for `TASKS_DIR` itself — a single-writer-daemon
  design was considered and cut; the control-plane-state-outside-TASKS_DIR
  idea it contributed lives on in the lock module instead.
- **Raw-terminal working-tree destruction is only partially covered** —
  git has no hook for working-tree/index mutations (`clean -fdx`,
  `checkout -- .`, `stash drop` typed by a human outside Claude).
- **`push --force` has no git-side backstop.** The local
  `reference-transaction` hook never sees a remote's ref update; L1
  catches an agent-typed force-push, a raw-terminal one is accepted
  residue (every observed incident so far has been local).
- **No session-liveness TTLs or auto-cleanup** beyond the lock-contention
  path covered above — no `wb reconcile`-time stale-lock sweep.
- **`~/code/tasks` only; single machine.** `~/code/notes` is a confirmed
  structural twin, deferred to its own follow-up task, not covered here.
- **wb.sh's own repo-level git calls across *different* task files are
  not serialized against each other** — repo-wide contention (as opposed
  to per-task-file contention) is a distinct, unaddressed domain.
