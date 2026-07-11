---
name: wb-done
description: Run `wb done` (the wb workbench's safe wind-down — removes the worktree, flips the task to done) from inside a Claude Code session without hanging the agent's turn on its interactive sweep-review buffer. Use when the user types /wb-done, says "wrap this up", "wind down this task", "close out this worktree", or "run wb done" — optionally with --close to also kill the tmux session, but only when the user explicitly asks for that in this invocation. Never shells out to `wb done` synchronously in the foreground.
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
itself (`wb.sh:839-850`) is:

```bash
wb_open_buffer() {
  local path="$1"
  if [ -n "${TMUX:-}" ]; then
    local chan="wb-buffer-done-$$-$RANDOM"
    tmux set -p -t "$TMUX_PANE" @claude_blocked nvim-buffer 2>/dev/null || true
    tmux split-window -h -t "$TMUX_PANE" "nvim '$path'; tmux wait-for -S $chan"
    tmux wait-for "$chan"
    tmux set -pu -t "$TMUX_PANE" @claude_blocked 2>/dev/null || true
  else
    "${EDITOR:-nvim}" "$path"
  fi
}
```

That `tmux wait-for "$chan"` is an **untimed, blocking wait** for a human to
close an nvim split — a split that doesn't even exist yet from the human's
point of view until this runs. A Claude Code session always has `$TMUX` set
(wb runs one session per worktree, each a tmux session), so this branch
always fires. If this skill invoked `wb done` as a plain synchronous
foreground Bash call, the agent's own Bash tool call would hang right there
— indistinguishable from a stuck process — until the user happened to
notice a new split pane and closed it. That is the exact failure mode the
`decision-buffer` skill's own nvim-buffer flow is built to avoid, and this
skill copies its fix.

## The background-Bash-plus-wait-channel mechanism

`decision-buffer/SKILL.md` (`claude/.claude/skills/decision-buffer/SKILL.md:143-148` for the
invocation, `:152` for the uniqueness rule) documents the pattern this skill mirrors:

```
Bash (run_in_background: true):
  CHAN="decision-buffer-done-$$-$RANDOM"   # MUST be unique per open — see below
  tmux set -p -t "$TMUX_PANE" @claude_blocked nvim-buffer
  tmux split-window -h -t "$TMUX_PANE" "nvim '<abs path>'; tmux wait-for -S $CHAN" \
    && tmux wait-for "$CHAN"
  tmux set -pu -t "$TMUX_PANE" @claude_blocked
```

> **The channel name MUST be unique per invocation** (`$$-$RANDOM` above...).
> `tmux wait-for` *latches* a signal when no client is waiting: if any
> earlier `wait-for -S <chan>` ran with no waiter present ... the next
> `wait-for <chan>` returns **instantly** — re-invoking the agent before the
> user has closed (or even touched) the buffer. A fixed channel name ... is
> shared across every session on the tmux server, so this misfire is not
> rare. A fresh per-open channel name cannot carry a stale signal.

Two things follow from reading `wb_open_buffer` against that:

1. **`wb done` already implements this exact mechanism, one layer down.**
   `wb_open_buffer`'s `chan="wb-buffer-done-$$-$RANDOM"` is the same
   `$$-$RANDOM`-per-invocation uniqueness rule decision-buffer's SKILL.md
   requires, generated fresh on every `wb done` call — there is no fixed,
   reused channel name to latch a stale signal here. This skill does not
   need to (and must not) mint a *second*, redundant wait-channel of its
   own wrapping `wb done` — there's no async gap to bridge at this layer
   the way `tmux split-window`'s fork-and-return behavior forces one
   inside `wb_open_buffer`. `wb done` is an ordinary synchronous script:
   the whole invocation (dirty check → buffer open-and-wait → worktree
   removal → status flip → outcome message) does not return to its caller
   until it is genuinely finished, buffer close included.
2. **The one thing this skill is responsible for is not calling that
   synchronous script in the foreground.** Backgrounding the *entire*
   `wb done ...` invocation as a single Bash tool call gives the same
   net effect decision-buffer's explicit wrapper gives: the agent's turn
   is never blocked waiting on a human, and the harness re-invokes the
   agent only once the whole command — including `wb_open_buffer`'s
   internal wait-for — has actually completed.

### What to run

```bash
wb done [--close] [<session>]
```

as a **single Bash tool call with `run_in_background: true`** — never
plain/synchronous. Omit `<session>` in the common case (the skill is
invoked from inside the session being wound down, and `cmd_done` falls back
to `tmux display-message -p '#S'` for the current session when none is
given — `wb.sh:1547-1551`). Only pass `--close` when the user explicitly
asked for it in *this* invocation (see below) — never by default, and never
carried over from an earlier turn.

After launching, tell the user the wind-down is running and end the turn.
Do not poll, do not schedule a wakeup, do not keep talking — the background
command completing is the signal, exactly as decision-buffer's own step 2
puts it ("Do NOT poll, schedule wakeups, or keep talking — the background
command completing IS the signal").

## Flow

### 1. Determine flags

- Default: no flags, no session — `wb done` acting on the current session.
- `--close`: only when the user's own words in this invocation ask for it
  — "`/wb-done --close`", "wrap this up and close the session", "kill the
  session too", etc. If the request is ambiguous whether they mean the
  worktree/task or the tmux session itself, ask briefly rather than
  guessing — the two `--close` edge cases below are not reversible.
- An explicit `<session>` name: pass it through if the user named a
  session other than the one this skill is running in (e.g. tidying up a
  different task from the picker's session list). Otherwise omit it.

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

- `wb done: <session> closed — worktree removed, task -> done (<task_file>)`
  — the happy path; relay as-is.
- `wb done: <worktree_path> is dirty:` followed by `git status --porcelain`
  output and `commit or stash, then re-run` (stderr, exit 1) — the dirty
  edge case; nothing was removed, nothing was closed, relay the error
  verbatim and stop — don't retry or force anything on the user's behalf.
- `wb done: $(wb_pending_counts) — consider running /parked-items` — an
  optional trailing nudge when follow-ups/parked items pass the sweep
  threshold; include it if present.

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
- **`/wb-done --close`** — also kills the tmux session once wind-down
  finishes. `--close` is passed only because the user asked for it in this
  invocation, never as a default or a carry-over from earlier context; when
  it targets the current session, the self-kill hazard in step 4 above is
  surfaced to the user before the background call launches.

## Notes

- This skill never modifies `scripts/.config/scripts/tmux/wb.sh` — it only
  shells out to the `wb done` CLI already built there. If `wb done`'s own
  behavior seems wrong or missing something, that's a `wb.sh` change, not
  something to work around here.
- `wb` is already an aliased, stowed command (`alias wb="~/.config/scripts/tmux/wb.sh"`
  in `~/.zshrc`) — invoke it as the bare `wb done ...`, no path juggling
  needed (unlike `/handoff`'s `handoff.sh`, which currently needs its full
  in-repo path until its own post-merge alias/stow wiring lands).
