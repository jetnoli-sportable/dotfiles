---
name: wb-done
description: Run `wb done` (the wb workbench's safe wind-down — removes the worktree, flips the task to done) from inside a Claude Code session without hanging the agent's turn on its interactive sweep-review buffer. Use when the user types /wb-done, says "wrap this up", "wind down this task", "close out this worktree", or "run wb done" — and when winding down another session (a batch of finished workers, or a session named from the picker) — passing --close to also kill the tmux session: by default for another session, and for the caller's own session only when the user explicitly asks for that in this invocation. Never shells out to `wb done` synchronously in the foreground.
---

# wb-done

A thin wrapper so `wb done` — the wb workbench's safe wind-down command
(removes the worktree, flips the task's status to `done`) — can be run from
inside a Claude Code session without hanging the agent's turn.

## Why this needs to exist at all

`wb done` almost always opens an interactive review buffer before it does
anything else. `cmd_done` (`scripts/.config/scripts/tmux/wb.sh:1546`) calls
`wb_open_buffer` unconditionally on both its main paths — the ignored-files
sweep branch (`wb.sh:1606`) and the plain else branch (`wb.sh:1661`); only
the dirty-worktree fail-fast (`wb.sh:1578-1586`) skips it. `wb_open_buffer`
itself (`wb.sh:2785-2803`) is a thin shim over the shared
`claude/.claude/skills/decision-buffer/scripts/open-buffer.sh` script: it
calls `open-buffer.sh --tmux <path>` when `$TMUX` is set (or `--direct
<path>` when it isn't), and fails hard (exit 1, naming
`stow --no-folding -t "$HOME" claude`) if the script is missing or not
executable.

That underlying wait is an **untimed, blocking wait** for a human to
close an nvim split — a split that doesn't even exist yet from the human's
point of view until this runs. A Claude Code session always has `$TMUX` set
(wb runs one session per worktree, each a tmux session), so the `--tmux`
path always fires. If this skill invoked `wb done` as a plain synchronous
foreground Bash call, the agent's own Bash tool call would hang right there
— indistinguishable from a stuck process — until the user happened to
notice a new split pane and closed it. That is the exact failure mode the
`decision-buffer` skill's own nvim-buffer flow is built to avoid, and this
skill copies its fix.

## The background-Bash-plus-wait-channel mechanism

`claude/.claude/skills/decision-buffer/references/mechanism.md` documents the
full contract for the shared `open-buffer.sh` script this skill's own
`wb_open_buffer` now delegates to — the state-file fields, the fallback
tiers (`--tmux` → `--terminal` → `--manual`), and the reattach decision
tree. Read that file rather than this section if you need the contract
itself; what follows is only what matters for this skill.

Two things follow from reading `wb_open_buffer` against that contract:

1. **`wb done` already implements this exact mechanism, one layer down.**
   `wb_open_buffer` delegates to `open-buffer.sh`, which generates its own
   unique wait-channel per invocation internally (`gen_chan()` in the
   script) — there is no fixed, reused channel name to latch a stale
   signal here, and this skill does not need to (and must not) mint a
   *second*, redundant wait-channel of its own wrapping `wb done`. `wb
   done` is an ordinary synchronous script: the whole invocation (dirty
   check → buffer open-and-wait → worktree removal → status flip →
   outcome message) does not return to its caller until it is genuinely
   finished, buffer close included.
2. **The one thing this skill is responsible for is not calling that
   synchronous script in the foreground.** Backgrounding the *entire*
   `wb done ...` invocation as a single Bash tool call gives the same
   net effect decision-buffer's explicit wrapper gives: the agent's turn
   is never blocked waiting on a human, and the harness re-invokes the
   agent only once the whole command — including `wb_open_buffer`'s
   internal wait-for — has actually completed.

### What to run

```bash
wb done [--close] [--leave-shelved] [<session>]
```

as a **single Bash tool call with `run_in_background: true`** — never
plain/synchronous. Omit `<session>` in the common case (the skill is
invoked from inside the session being wound down, and `cmd_done` falls back
to `tmux display-message -p '#S'` for the current session when none is
given — `wb.sh:1547-1551`). Whether to pass `--close` depends on whose
session it is (see step 1): for another session it's the default; for the
caller's own session, only when the user explicitly asked for it in *this*
invocation, never carried over from an earlier turn. `--leave-shelved` is
only ever passed when the user asks for it, whoever's session it is.

After launching, tell the user the wind-down is running and end the turn.
Do not poll, do not schedule a wakeup, do not keep talking — the background
command completing is the signal, exactly as decision-buffer's own step 2
puts it ("Do NOT poll, schedule wakeups, or keep talking — the background
command completing IS the signal").

## Flow

### 1. Determine flags

- Default: no flags, no session — `wb done` acting on the current session.
- `--close` on **the caller's own session**: only when the user's own words
  in this invocation ask for it — "`/wb-done --close`", "wrap this up and
  close the session", "kill the session too", etc. If the request is
  ambiguous whether they mean the worktree/task or the tmux session itself,
  ask briefly rather than guessing — the two `--close` edge cases below are
  not reversible.
- `--close` on **another session**: the default. Winding down a finished
  worker from outside it (a batch after a /quick-wins run, a tidy-up from
  the picker's session list) passes `--close`, so the session goes away
  with its worktree. Without it, `wb done` removes the worktree but leaves
  the session running: the 2026-10-18 batch left 14 idle sessions that way
  for five days. Leave `--close` off only when the user says to keep that
  session. Before passing it, compare the target against the caller's own
  session name (`tmux display-message -p '#S'`); if they match, this is the
  own-session case above, so `--close` needs the user's explicit ask. Never
  close the caller's own session as part of a batch.
- `--leave-shelved`: only when the user's own words in this invocation say to
  close anyway and leave the shelved decision drafts (see the refusal below).
  Never add it to get past a refusal on your own initiative.
- An explicit `<session>` name: pass it through if the user named a
  session other than the one this skill is running in (e.g. tidying up a
  different task from the picker's session list). Otherwise omit it. For a
  batch, run one `wb done --close <session>` per worker, one after another
  in a single background command; each may open its own review buffer.

### 2. Launch backgrounded, then end the turn

Run exactly the command from "What to run" above as one Bash tool call with
`run_in_background: true`. Say one short line ("Running `wb done` —
I'll relay the result once it's done.") and stop. Do not narrate further
until the background call reports back.

### 3. Relay the outcome verbatim

When the background call completes, read its stdout/stderr and relay
`wb done`'s own message back to the user in one line — quote it, don't
paraphrase, same posture `/handoff`'s SKILL.md step 6 takes toward
`handoff.sh`'s own messages ("Relay the outcome back to the user in one
line. `handoff.sh`'s own stdout/stderr messages say exactly which case
happened — read the pane output rather than guessing"). `wb done` prints
one of, among others:

- `wb done: <session> — worktree removed, session closed, task -> done (<task_file>)`
  — the happy path with `--close`; relay as-is.
- `wb done: <session> — worktree removed, session left open (pass --close to end it), task -> done (<task_file>)`
  — the happy path without `--close`; relay as-is. The task's `## Handoffs`
  entry says the same ("session left open"), so nobody later reads the
  session as gone.
- `wb done: <worktree_path> is dirty:` followed by `git status --porcelain`
  output and `commit or stash, then re-run` (stderr, exit 1) — the dirty
  edge case; nothing was removed, nothing was closed, relay the error
  verbatim and stop — don't retry or force anything on the user's behalf.
- `wb done: N decision draft(s) (shelved, or pending in a live session) for
  <task> would be stranded (nothing changed):` followed by one line per draft
  (stderr, exit 1) — wb-capture holds unreviewed decision drafts for this task,
  of two kinds, each with its own remedy line. `shelved: <path>` drafts: run
  `/close-out` or `/wb-decide shelved` to accept or dismiss them. `pending in
  session <sid>: <path>` drafts (a live session's unreviewed draft): resolve it
  with `/wb-decide` in that session. Either way, `--leave-shelved` closes
  anyway (SessionEnd or the reaper shelves a pending session draft later;
  resolve it then with `--task`). Nothing was removed or closed. Relay it
  verbatim and stop; the user either resolves the drafts and then runs
  `/wb-done` again, or asks for `/wb-done --leave-shelved` (which closes and
  logs that the drafts were left on purpose). Don't pick for them. Drafts left
  that way (or landing after the close) stay resolvable by task stem, from any
  wb session or none: `~/.config/scripts/tmux/wb-capture.sh shelved --task <stem>` lists them and
  `dismiss --task <stem> <path>` / `accept [--begin] --task <stem> <path>`
  resolve one.
- `wb done: $(wb_pending_counts) — consider running /weekly-review` — an
  optional trailing nudge when follow-ups/unreviewed capture entries pass
  the sweep threshold; include it if present.

### 4. The `--close` self-kill hazard — surface it before launching, not after

`cmd_done`'s self-target guard is deliberately scoped to the interactive
picker's ctrl-x dispatch only, **not** to `cmd_done` itself
(`wb.sh:2165-2167`: "typing `wb done --close` yourself from inside your own
session stays intentional self-close and is untouched"). If `--close` is
requested and no other `<session>` is named, `wb done` will, as its very
last step, `tmux kill-session` on the session this skill is running inside
— the same tmux session carrying the Claude Code process itself. Once that
session dies, the process dies with it, mid-flight, before step 3 above can
ever run: there is no next turn in which to relay a final confirmation.

`tmux kill-session` also takes down every OTHER window in that session, not
just this one — every wb-managed session has a separate nvim window (win1,
`wb_layout_session`, `wb.sh:247-261`) alongside the agent window. The
dirty-tree check earlier in `cmd_done` only inspects `git status
--porcelain` (on-disk state), so an unsaved-but-never-written buffer sitting
open in that other window is invisible to that guard and would be silently
destroyed along with the session — the same blast radius `_ctrl_x`'s own
guard comment already documents for the picker path (`wb.sh:2159-2160`:
"kill the very pane running this command (and any other live window in
that session) with no confirmation").

So: when `--close` applies to the current session, say so **before**
launching the background call, e.g. "This will also kill the current tmux
session — including any other window in it, like an nvim buffer with
unsaved edits — once the wind-down finishes; you won't see a confirmation
message here after that, check `wb board` or the task file afterward." This
is not an extra confirmation prompt (the user already asked for `--close`
explicitly, which is their call) — it's making sure they know the full
blast radius and that the last message they'll see from this session is the
one right before the command runs, not a relay of `wb done`'s own output.

## Test scenarios this skill's behavior must cover

- **Happy path** — clean worktree, `/wb-done`: worktree removed, task status
  flips to `done`, `wb done`'s success line relayed verbatim, the agent's
  turn never hangs (background call + end-turn, per above).
- **Dirty worktree** — `/wb-done` against a worktree with uncommitted
  changes: `wb done`'s own dirty-tree error (path + `git status --porcelain`
  output + "commit or stash, then re-run") is relayed as-is; nothing is
  removed, nothing flips to done.
- **Shelved or live decision drafts** — `/wb-done` for a task with drafts under
  wb-capture's `shelved/<task>/` or a draft still pending in a live session of
  the task: `wb done`'s refusal (paths, the per-kind remedy and
  `--leave-shelved`) is relayed as-is; nothing is removed or flips to done, and
  `--leave-shelved` is passed only if the user asks for it.
- **`/wb-done --close`** — also kills the tmux session once wind-down
  finishes. On the caller's own session, `--close` is passed only because
  the user asked for it in this invocation, never as a default or a
  carry-over from earlier context, and the self-kill hazard in step 4 above
  is surfaced to the user before the background call launches.
- **Winding down other sessions** — a batch of finished workers, or one
  session named from the picker: each gets `wb done --close <session>`, so
  its session ends with its worktree, unless the user said to keep it. A
  target that matches the caller's own session name never gets `--close`
  from the batch rule.

## Notes

- This skill never modifies `scripts/.config/scripts/tmux/wb.sh` — it only
  shells out to the `wb done` CLI already built there. If `wb done`'s own
  behavior seems wrong or missing something, that's a `wb.sh` change, not
  something to work around here.
- `wb` is already an aliased, stowed command (`alias wb="~/.config/scripts/tmux/wb.sh"`
  in `~/.zshrc`) — invoke it as the bare `wb done ...`, no path juggling
  needed (unlike `/handoff`'s `handoff.sh`, which currently needs its full
  in-repo path until its own post-merge alias/stow wiring lands).
