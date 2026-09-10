# Buffer mechanism reference

How `scripts/open-buffer.sh` opens a document for the user to edit, waits
for it to close, and recovers if that wait gets interrupted. `SKILL.md`
points here instead of re-deriving any of this — read this file, not the
script's comments, when you need the contract rather than the
implementation.

## Why a script, not prose

The tmux open/wait recipe used to be prose copied into five places
(decision-buffer, wb-done, parked-items, wb-breakdown, wb-jira-create) plus
one real implementation (`wb_open_buffer()` in
`scripts/.config/scripts/tmux/wb.sh`). One executable implementation now
backs all of them; the other skills call this script instead of repeating
the recipe.

## The four modes

Exactly one of these runs per invocation, chosen by the caller (this script
never auto-detects and silently falls back — a caller that guesses wrong
about its environment should see an explicit error, not a silent wrong
mode):

| Flag | Who calls it | Blocks? | Writes state file? | Sets `@claude_blocked`? |
|---|---|---|---|---|
| `--tmux` (default) | decision-buffer et al., inside tmux | yes (`tmux wait-for`) | yes | yes |
| `--terminal` | decision-buffer et al., graphical session, no tmux | yes (`gnome-terminal --wait`) | yes | best-effort, only if a tmux pane happens to be present |
| `--manual` | decision-buffer et al., headless (no tmux, no terminal spawn) | no — prints a copyable `! nvim <path>` command and returns immediately | yes (records the offer was made) | no |
| `--direct` | `wb.sh`'s own non-agent callers (`wb reconcile --review`, sweep-review call sites) | yes, synchronously in the calling shell | **no** | no |
| `--reattach` | any caller resuming an interrupted `--tmux` wait | yes (`tmux wait-for` again), or returns immediately if the wait shouldn't resume | rewrites nothing; only deletes the state file on completion | yes, while re-waiting |

`--direct` exists only to reproduce `wb_open_buffer()`'s pre-existing
non-tmux branch (`scripts/.config/scripts/tmux/wb.sh:2800-2802`) exactly —
same synchronous block, no state, no pane marker — for callers that were
never agent-driven and have nothing to reattach to. Don't route an
agent-driven open through `--direct`; it has no way to signal an agent
that was told to end its turn.

## Backgrounding (R17)

`--tmux`, `--terminal`, `--manual`, and `--reattach` all either block until
the buffer closes or (for `--manual`) hand off to a process outside this
script's control. **Always invoke them as a backgrounded Bash call**
(`run_in_background: true`) — a foregrounded call sits inside the normal
tool-call timeout and gets killed before the human ever closes the buffer.
`--direct` is the one mode meant to run in the foreground: it's used by
non-agent shell callers that are supposed to block synchronously (`wb
reconcile --review` et al.), not by an agent turn.

## The state file

Written beside the document as `<doc>.buffer-state` — e.g.
`logs/decisions/2026-09-08-foo.md.buffer-state`. Plain `key=value` lines,
one per line:

```text
chan=<unique wait channel>
pane_id=<tmux pane id, tmux mode only>
mode=tmux|terminal|direct|manual
opened_at=<unix time>
caller_pid=<pid of the opening process, for duplicate-waiter detection>
content_hash=<hash of the document's content at open time>
reopen_count=<count of consecutive reopens with no new content>
closed=<0 while open, 1 once a --tmux/--terminal wait completes normally>
```

**Which modes write it:** `tmux`, `terminal`, and `manual` all write one.
`direct` never does — those callers block synchronously in the same
process and have nothing later to reattach to or reopen.

**Field semantics:**

- `chan` — the `tmux wait-for` channel name, unique per open
  (`decision-buffer-done-$$-$RANDOM`). Never reused: `tmux wait-for`
  latches an unclaimed signal, so a fixed channel name risks a stale
  signal from a prior open making the *next* `wait-for` on it return
  instantly, before the user has touched the new buffer. Empty in
  `terminal`/`manual` mode (nothing to wait on via tmux).
- `pane_id` — the tmux pane id the split opened in, captured via
  `split-window -P -F '#{pane_id}'`. Empty outside `tmux` mode.
- `mode` — which of the four modes wrote this file. `--reattach` reads it
  first and refuses outright if it isn't `tmux` (see below).
- `opened_at` — unix timestamp of this open. Informational; nothing in
  the script currently acts on staleness by age.
- `caller_pid` — the pid of the process that did this open (`$$` inside
  the script). This is what the duplicate-waiter check and the reattach
  decision tree both key off of, via `kill -0 <pid>`.
- `content_hash` — `sha256sum`/`shasum -a 256` of the document's content
  **at open time, before the editor runs**. Falls back to the literal
  string `nohash` if neither tool is present (documented degradation
  below).
- `reopen_count` — see next section.
- `closed` — `0` while the wait is genuinely in flight (written at open
  time by every state-writing mode); `--tmux`/`--terminal` rewrite it to
  `1` in place, in the SAME state file, once their wait completes normally
  — they no longer `rm -f` the file on a clean close. This is what lets
  `reopen_count`/`content_hash` survive to the *next* open's carry-forward
  check (see below): deleting the file on every close made the counter
  reset to 0 on every single reopen, silently defeating R10's three-
  reopen cap in the two modes that matter most. `--reattach` checks this
  flag first (see the decision tree below) so it never mistakes "already
  closed, deliberately" for the interrupted-wait case it exists to
  recover. `--manual` never sets it to `1` — it has no completion signal
  to react to, so its state file already persisted across closes before
  this field existed, unaffected by this change.

**Overwrite rule (R16):** every field except `reopen_count` is
overwritten unconditionally on every fresh open (`--tmux`/`--terminal`/
`--manual`) — a state file left over from an earlier run at the same doc
path is never reused as a signal source, only ever superseded. The one
exception: if a *live* process still holds the prior file (see
"duplicate-waiter guard" below), the fresh open refuses instead of
overwriting out from under it.

**`reopen_count` carry-forward:** on a fresh open, the script hashes the
document as it currently sits on disk and compares it to the prior state
file's `content_hash` (if one exists and no live waiter holds it):

- same hash (no new content landed since the last open) → `reopen_count`
  = previous value + 1.
- different hash, or no prior state file → `reopen_count` = 0.

This is the mechanical half of R10's three-reopen-then-ask-in-chat rule
for the paste-target shape — the script just maintains the counter
generically; it's the calling skill's job to read it back and decide when
to stop reopening. The counter carries forward across mode changes too
(e.g. a `--manual` open followed by a `--tmux` reopen of the same path
still sees the prior count) — it's keyed on content, not on which mode
wrote the previous file.

**Hash-unavailable degradation:** if neither `sha256sum` nor `shasum` is
on `PATH`, `hash_doc` returns the literal string `nohash`. Since `nohash`
is compared for equality against the previous hash and a `nohash` value
never matches (a fresh `hash_doc` call also returns `nohash`, but the
comparison is explicitly guarded to treat `nohash` as always-different —
see `prepare_open` in the script), `reopen_count` always resets to 0 in
this environment. That undercounts reopens rather than overcounting: the
three-reopen cap exists to stop endless silent reopening, not to
under-tolerate a slow user, so failing toward "never trips the cap" is
the safe direction.

## Duplicate-waiter guard

Before writing a fresh state file (any of `--tmux`/`--terminal`/
`--manual`) or before starting a reattached wait (`--reattach`), the
script checks the *existing* state file's `caller_pid` with `kill -0`. If
that process is still alive, it means another live process already holds
the wait on this document — the script reports `already waiting on <path>
(pid ..., chan ..., mode ...)` to stderr and exits 1 without touching the
state file or starting a second wait. This is what keeps two concurrent
agents (or an agent and a leftover reattach) from both blocking on the
same buffer.

If the recorded `caller_pid` is dead (the common case — the prior opener
already exited normally, or was killed), the guard passes and the fresh
open proceeds to unconditionally overwrite the state file as described
above.

Caveat: `kill -0` can false-positive if the OS has recycled the pid for
an unrelated process in the meantime. This is a known, accepted
limitation — not handled specially.

## Reattach decision tree (R18)

`--reattach <path>` resumes a wait recorded by an earlier `--tmux` open
of the same path, for when the background process that was running the
wait died while the pane itself is still open (a killed shell, an agent
restart, a crashed session — not a deliberate close). Directional logic:

```text
on --reattach <doc>:
  if no state file for <doc>:            → "nothing to reattach", exit 1
  if state.closed == 1:                  → "already closed normally", delete state file, exit 0
  if state.mode != tmux:                 → "reattach not supported outside tmux", exit 1
  if state.caller_pid is alive:          → "already waiting", exit 1  (duplicate-waiter guard)
  if not inside tmux right now:          → "reattach requires being inside tmux", exit 1
  panes = tmux list-panes -a
  if state.pane_id not in panes:         → PaneGone: report, delete state file, exit 0 — DO NOT WAIT
  elif panes[state.pane_id].command == "nvim":
                                          → wait-for(state.chan) again, then delete state file, exit 0
  else:                                  → CLOSED_NO_SIGNAL: report, delete state file, exit 0 — treat as a normal close
```

The three outcomes map directly to what the calling agent should tell
Jet:

- **Pane still alive, still running nvim** — the wait itself died, not
  the buffer. Re-attach to the *same* recorded channel rather than
  opening a second buffer, and say so out loud ("re-attaching to the
  buffer you still have open"). This is the only branch that blocks
  again.
- **Pane gone** — the close was **not** deliberate (the pane closing is
  what would normally fire the `wait-for` signal; if the pane is simply
  gone with no signal ever recorded, something ended it out of band).
  Do not wait, do not re-open a fresh buffer. Read the document on disk
  as found and tell Jet plainly that the close wasn't deliberate — any
  ticks or notes found in it are reported as **"on disk, unconfirmed"**,
  never applied without asking first.
- **Pane alive but not running nvim** — nvim already exited in that pane
  (the wait-for signal may simply have been missed). Treat this exactly
  like a normal close: read the document and parse it as usual.

In every branch, the buffer is parsed only when the wait or the reattach
actually completes, or Jet explicitly says the buffer is closed — never
because an unrelated chat message arrived while the recorded pane is
still open with the wait still live.

## What the script does NOT do

- It never polls. Every blocking path is exactly one `tmux wait-for` (or
  one synchronous `gnome-terminal --wait` / direct editor invocation).
- It never decides content-shape questions (three-reopen cap, tick
  parsing, `Closing because:` precedence). It hands back a `reopen_count`
  and an exit code; the calling skill's own parse rules do the rest.
- It never retries a failed `tmux split-window`/`gnome-terminal` spawn —
  a spawn failure surfaces as a non-zero exit and an stderr message, for
  the caller to fall back to the next tier (`--tmux` failing outside tmux
  → try `--terminal`; that failing → `--manual`).
