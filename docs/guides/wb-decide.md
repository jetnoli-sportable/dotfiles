---
title: wb-decide
status: current
tile: Record a decision into ## Decisions — and the hooks that nudge you to when one goes by unrecorded.
group: skills
kind: guide
updated: 2026-10-18
---

## Overview

`/wb-decide` is the "record" half of decision auto-capture. Decisions made
in a wb session used to vanish unless someone remembered to write them
into the task file's `## Decisions` section. The `wb-capture` plugin
(`claude/.claude/skills/wb-capture/`, hooks only) watches each turn and,
when one read like a decision, injects a one-line nudge into your next
prompt. The live agent — the only one holding the whole conversation —
then decides whether something was really settled and, if so, appends it
via `wb append … Decisions`. Hooks never write the task store; the skill
does.

**What fires when (one turn, in plain words):**

1. You send a prompt. If a nudge is queued, one line is added to that
   prompt's context and logged as `nudge_fired`. (Prompts that are just a
   `<task-notification>` from a finished background sub-agent get nothing.)
2. Claude replies. If it ran `wb append … Decisions`, that is logged as
   `followed` and nothing further is queued.
3. When the turn ends, the reply is phrase-matched against a short list
   ("we decided", "going with", "settled on", …). A hit queues a nudge for
   the next prompt, then a cooldown (3 turns) keeps it from nagging. A
   nudge that was delivered but not acted on by the end of its turn is
   logged `ignored`.
4. Also at turn end, an async background Haiku "sweep" looks at the recent
   transcript if the task file has gone 4 turns unchanged. If it finds an
   unrecorded decision it writes a draft; the next prompt gets a nudge
   pointing at it. It is propose-only, tool-less, and skips itself when
   muted, when a draft is already pending, when nothing new was said, or
   after 3 failed runs in a row (`claude` missing, logged out or rate-limited).
   A draft nudge that is ignored is delivered once more; ignored a second
   time, the draft is **shelved** (logged `draft_shelved`), not deleted, and
   sweeping resumes. A draft is only ever removed by your accept or dismiss.
   If two sweeps overlap and a second draft arrives while one is already
   there, the older one is shelved (reason `superseded`) before the new one
   is written, never overwritten. The exception is a draft you are looking at
   (under review, or its draft nudge still outstanding): that one is left
   exactly as it is, and the *new* answer is shelved instead (also reason
   `superseded`), so a review is never pulled out from under you.
5. Session end writes a tombstone (and logs `pending_at_end` if something
   was still unrecorded) and shelves a pending draft; an hourly reaper cleans
   up old state dirs, shelving any draft it finds first. A sweep draft that
   finishes *after* the session ended is written and shelved too (reason
   `session_end`), not thrown away.

Every nudge resolves exactly once: `followed`, `dismissed` or `ignored`.

**A review over several messages.** When `/wb-decide` shows you a pending
draft it runs `wb-capture.sh review`, which marks the draft *under review*:
while you and Claude go back and forth (questions, edits), the nudge carries
over to the next turn instead of counting as ignored, and nothing new
nudges. It resolves once, when the entry is recorded (`followed`) or
dismissed. After four carried turns with neither, the review counts as
abandoned and is struck like an ignored nudge. Only that draft-review path
calls `review` (and only while the draft's sweep nudge is outstanding; a
repeat call never resets the turn count). `status` is read-only, so just
checking state never puts a session under review.

**Shelved drafts.** A shelved draft waits in
`~/.local/state/wb/capture/shelved/<task>/` (it outlives the session) until
you decide. `/wb-decide status` lists them (`shelved: <path>`), `/wb-decide
shelved` walks through them one at a time, and `/close-out` asks about each
before a task winds down. Rejecting runs `wb-capture.sh dismiss <path>`.
Phrase nudges carry no draft, so ignoring one shelves nothing.

A shelved draft whose task is already closed is still resolvable from any wb
session, or from none: path-carrying `accept`/`dismiss` ignore the kill switch and
need no `@task`. The stem comes from `--task`, else the session's task, else the
command exits 1 with a message. With no session the event is logged with an empty
`session_id` and `accept --begin` writes no flag (the hooks are inert, so there is
nothing to protect). `wb-capture.sh shelved --task <stem>` lists one task's drafts,
`wb-capture.sh shelved --all` lists every task's grouped by task, and
`dismiss --task <stem> <path>` / `accept [--begin] --task <stem> <path>`
resolve one (accepting records it into *that* task's `## Decisions`).
Drafts left behind by `wb done --leave-shelved` are reachable this way, and
`/weekly-review` runs `shelved --all` to surface the ones whose task is done.

Accepting is **two-phase**: `wb-capture.sh accept --begin <path>` immediately
before `wb append <task> Decisions -` (after any confirmation or editing), then
`wb-capture.sh accept <path>`. Recording a
shelved draft is an ordinary `wb append … Decisions`, which the PostToolUse
hook would otherwise count as the answer to whatever *other* nudge is live
in the session (marking it `followed` and wiping its strikes and review
state). The `--begin` call leaves a one-shot flag; the hook consumes it, notes
the turn as recorded and leaves the live nudge alone; the final `accept`
deletes the draft and logs `shelved_accepted` (it does not touch the flag, so
all three commands in one Bash call still work: PostToolUse fires after the
whole call). An abandoned accept just leaves the draft shelved: the flag is
dropped by the next real prompt.

**`wb done` won't strand decision drafts.** A shelved draft only gets reviewed
by `/close-out` or `/wb-decide shelved`, and a draft still pending in a live
session of the task would be shelved by SessionEnd right after the close, so
`wb done` refuses (before it touches anything, including a store-only close)
while `shelved/<task>/` holds any draft or a live session dir whose `taskpath`
is this task holds a `draft`. It asks `wb-capture.sh pending-for-task` rather
than reading the state dir itself. It prints each path, labelled by kind, with that
kind's way forward. A shelved draft (`shelved: <path>`): run `/close-out` or
`/wb-decide shelved`, or re-run `wb done --leave-shelved` to close anyway. A live
session's pending draft (`pending in session <sid>: <path>`): resolve it with
`/wb-decide` in that session, or re-run with `--leave-shelved` (SessionEnd or the
reaper shelves it later, and `--task <stem>` resolves it then).
`--leave-shelved` closes, logs one `shelved_left{count}` line to the capture
log (via `wb-capture.sh log-shelved-left`) and notes the left drafts in the
task's `wb done` Handoffs entry; `/close-out` routes a `draft: present` line
through the draft-review path first, so a bare `wb done` is the only way to hit
the refusal for a live draft. (A
`wb done` invoked through `/wb-done` relays the refusal; it never adds
`--leave-shelved` on its own.)

**The two nudge lines** (what Claude sees, verbatim):

```
[wb-capture] Last turn read like a decision ("<matched phrase>"). If it settled something, run /wb-decide; otherwise ignore or /wb-decide dismiss.
[wb-capture] A background review drafted an unrecorded decision (<state dir>/draft). Run /wb-decide to review/accept, or /wb-decide dismiss.
```

The first is `source=phrase`, the second `source=sweep`. A draft nudge
beats a phrase nudge when both are pending.

**Stale drafts.** The sweep snapshots the task's `## Decisions` section (the
exact text Haiku is shown), then waits up to a minute for Haiku. Edits
elsewhere in the task file don't count. If `## Decisions` changed in that
window (usually `/wb-decide` recording the very decision being drafted), the
answer is thrown away and Haiku is asked once more against the current
section, so it either answers NONE or drafts something genuinely new
(`sweep_ran` logs `rerun: true`). Only if the section changes *again* during
that rerun is the draft kept but flagged possibly stale: the nudge says it
may already be recorded, and `/wb-decide status` lists the `## Decisions`
entries added since. Claude shows you the draft next
to those entries and asks whether it is a duplicate; if so it dismisses it.
The events that resolve a stale draft's nudge carry `"stale":true`, so
dismissals of duplicates don't distort the graduation review's `dismissed`
count.

## Try it now

In any wb session, after something is actually settled:

```
/wb-decide
```

or `/wb-decide <one-line hint>` to say which decision. Claude reads the
task's existing `## Decisions` for style, composes decided / rejected /
why, appends it with `wb append`, and confirms:

```
Recorded to ## Decisions.
```

Check the machinery any time:

```
/wb-decide status
```

## Reference

**Modes of `/wb-decide`**

| Invocation | What it does |
|---|---|
| `/wb-decide [hint]` | Compose a new entry from the conversation (or accept a pending draft) and `wb append` it under `## Decisions`, then clear capture state. If nothing was actually decided it says so and dismisses instead of writing. |
| draft pending | Claude shows the sweep's draft when the draft nudge sent it (or you ran `/wb-decide` with no hint); accept as-is, or edit it first (add the missing rejected alternative / why), only if it reflects a real decision. A wrong or already-recorded draft is dismissed. A phrase nudge or a hinted `/wb-decide` composes from the conversation and leaves the draft alone; its closing plain `clear` keeps the draft, which gets nudged again (so does any `wb append … Decisions` that resolves the nudge while the draft survives). Only the draft-accept path runs `clear --draft`, which removes it. |
| `/wb-decide dismiss` | Drop the pending marker/draft, log `dismissed`. Quiet no-op if nothing was pending. The draft-review path and `/close-out` call `wb-capture.sh dismiss --expect <draft_sha>` (or `--expect none`): `status` prints the draft's sha1 as `draft_sha:`, and the dismiss refuses (exit 1, nothing removed or logged) if a different draft, or any draft for `none`, is present, so a draft the sweep wrote after you looked is never deleted unseen. Bare `dismiss` is unchanged. |
| `/wb-decide mute` / `unmute` | Per-session mute flag: no phrase nudges, no sweeps for this session. Each is logged. |
| `/wb-decide status` | Print pending marker/draft (with paths), mute state, the log path, and this task's shelved drafts (every `shelved:` line is relayed verbatim); for a stale draft, a warning plus the Decisions entries added since the snapshot. Read-only. |
| `/wb-decide shelved` | Walk this task's shelved drafts one at a time: accept/edit (`accept --begin <path>` right before the record, then `accept <path>`) or reject (`dismiss <path>`). A closed task's drafts take `--task <stem>` on each. |

Entries are append-only; a correction is a new entry carrying a
`(supersedes: <date> "<title fragment>")` line that names the one it replaces
(the date plus a quoted substring of its title). The write uses a
`<<'WB_DECISION_END'` heredoc rather than `<<'EOF'`, so a draft line reading
exactly `EOF` can't end it early.

**Paths**

| What | Where |
|---|---|
| State root | `~/.local/state/wb/capture/` (honours `XDG_STATE_HOME`) |
| Per-session state | `~/.local/state/wb/capture/<session_id>/` (marker, draft, muted, cooldown, ended, …) |
| Event log | `~/.local/state/wb/capture/log.jsonl` (rotated to `log.jsonl.1` above 5 MB) |
| Config (optional, untracked) | `~/.config/wb/capture.conf` |
| Kill switch | `~/.local/state/wb/disable-capture` |
| Shelved drafts | `~/.local/state/wb/capture/shelved/<task-stem>/<timestamp>-<session>.md` (a `.stale` sidecar marks a stale one) |
| Script | `~/.config/scripts/tmux/wb-capture.sh` (verbs: `hook-*`, `clear [--draft]`, `dismiss [--expect none|<sha1>] [--task <stem>] [<shelved path>]`, `accept [--begin] [--task <stem>] <shelved path>`, `review`, `mute`, `unmute`, `status`; store verbs that need no session: `shelved [--all | --task <stem>]`, `pending-for-task <task-file>`, `log-shelved-left <stem> <count>`); sweep in `wb-capture-sweep.sh` |

**Config keys** — `KEY=value` lines in `capture.conf`, parsed line by line
(never sourced), unknown keys and bad values ignored/defaulted:

| Key | Default | Meaning |
|---|---|---|
| `phrases` | strong list: `we decided\|decided to\|going with\|let's go with\|we'll go with\|i'll go with\|went with\|settled on\|the decision is\|chose \|opting for\|ruled out` | `\|`-separated, case-insensitive fixed strings |
| `cooldown` | `3` | turns between phrase nudges |
| `sweep_every` | `4` | unchanged turns before a sweep |
| `sweep` | `on` | `on` / `off` — the Haiku background sweep |
| `sweep_timeout` | `60` | seconds for the sweep child (`0` means the default 60; the reaper's grace for an ended session, 2 x timeout + 60s, uses the same fallback) |
| `sweep_max_failures` | `3` | consecutive failed sweeps before the sweep stops for the session (`0` = never stop) |

**Log events** (`log.jsonl`, one JSON object per line: `ts`, `session_id`,
`task`, `event`, optional `source`): `nudge_fired{source}`,
`followed{source}`, `dismissed`, `ignored{source}` (these three mean only "a
nudge resolved"), `muted`, `unmuted`,
`sweep_ran{result: none|draft|error|timeout}` (`rerun: true` when `## Decisions`
changed during the first run and Haiku was asked again; `stale: true` when it
changed again during the rerun; `followed`, `dismissed`, `ignored` and
`draft_shelved` carry `stale: true` too when they resolve a stale draft),
`sweep_skipped{reason: disabled|muted|draft_pending|backoff|no_new_content}`,
`draft_shelved{reason: ignored_twice|session_end|reaped|superseded}`,
`shelved_accepted` / `shelved_dismissed` (a shelved draft accepted or
rejected; no `source`, and `stale: true` when it was a stale one, so they
never count toward the nudge follow rate), `shelved_left{count}` (logged by
`wb done --leave-shelved`; its `session_id` is empty and it carries no `source`),
`pending_at_end{marker,draft}` (from SessionEnd; the sweep logs it as just
`{draft:true}` when the session ended while Haiku was still running, and
shelves the draft right after), `pending_orphaned` (the reaper logs it only
once the dir is really removed, after its `ignored` and `draft_shelved`).

**Measuring it** — follow / dismissal / ignored rate overall and per source,
plus sweep result counts (dismissals carry no source, so they're overall only)
and a shelved-draft rollup (how many were shelved, accepted, dismissed; kept
apart because nothing nudges a shelved draft):

```bash
jq -s '. as $all
| def pct($a;$b): if $b == 0 then null else (($a * 1000 / $b | round) / 10) end;
{
  by_source: (
    [.[] | select(.event == "nudge_fired")] | group_by(.source)
    | map({ source: .[0].source, fired: length })
    | map(. as $r | $r + {
        followed: ([$all[] | select(.event == "followed" and .source == $r.source)] | length),
        ignored:  ([$all[] | select(.event == "ignored"  and .source == $r.source)] | length) }
      | . + { follow_pct: pct(.followed; .fired), ignored_pct: pct(.ignored; .fired) })
  ),
  overall: ( ([.[] | select(.event == "nudge_fired")] | length) as $n
    | { fired: $n,
        followed_pct:  pct([.[] | select(.event == "followed")]  | length; $n),
        dismissed_pct: pct([.[] | select(.event == "dismissed")] | length; $n),
        ignored_pct:   pct([.[] | select(.event == "ignored")]   | length; $n) } ),
  sweep_results: ([.[] | select(.event == "sweep_ran")] | group_by(.result) | map({(.[0].result): length}) | add),
  shelved: { shelved:   ([$all[] | select(.event == "draft_shelved")]     | length),
             accepted:  ([$all[] | select(.event == "shelved_accepted")]  | length),
             dismissed: ([$all[] | select(.event == "shelved_dismissed")] | length) }
}' ~/.local/state/wb/capture/log.jsonl
```

**Close-out interaction.** `/close-out` step 4: if `## Decisions` is still
empty at wind-down, the agent either writes a real entry or appends an
affirmed marker (`### <timestamp> — close-out` / `_No decisions: <reason>_`)
via `wb append`, after running `wb-capture.sh dismiss --expect none` so no nudge is
outstanding when the marker lands (otherwise it would be logged `followed`); `--expect none`
refuses if a sweep landed a draft meanwhile, and the draft is then reviewed first.
A pending draft is routed through the draft-review path first. An unmarked
empty section keeps meaning "nobody checked".
Tasks closed with bare `wb done` (no `/close-out`) are left unmarked.

**Rollout.** Stow (`stow --no-folding -t "$HOME" claude scripts` from the
main checkout after fast-forwarding) and restart Claude sessions. The
plugin loads automatically as `wb-capture@skills-dir`. Already-running
sessions don't get the hooks; editing the scripts takes effect live, but
adding or removing a hook entry needs a restart.

## Known rough edges

- Phrase matching is deliberately conservative (<1% of messages); decisions
  phrased differently are the sweep's job, and the sweep only runs after 4
  unchanged turns.
- Phrase nudges are hints — many will be non-decisions; that's what
  `dismissed` and `ignored` measure.
- Only works inside a wb tmux session with `@task` set; elsewhere every
  verb is a silent no-op.
- Hooks can't force the agent to act; a nudge may simply be ignored.
- `/clear` and `wb resume` session-id behaviour is still being confirmed
  live (see the dossier's live-verification checklist).

## Next steps / reverting

A graduation review (merge date + 14 days) decides, from the log numbers
above, whether to keep, retune the phrase list, or drop the feature.

To turn it off, in order of bluntness:

- **Kill switch (all sessions, instant):** `touch ~/.local/state/wb/disable-capture`;
  `rm` the file to re-enable. (Resolving a shelved draft by path or `--task` still
  works with it on: that is cleanup of existing drafts, not capture.)
- **Sweep only:** `sweep=off` in `~/.config/wb/capture.conf`.
- **One session:** `/wb-decide mute` (and `/wb-decide unmute`).
- **Removal:** delete the plugin dir and restart sessions.
