---
title: wb-decide
status: current
tile: Record a decision into ## Decisions — and the hooks that nudge you to when one goes by unrecorded.
group: skills
kind: guide
updated: 2026-10-12
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
   time, the draft is discarded (logged `draft_discarded`) and sweeping
   resumes.
5. Session end writes a tombstone (and logs `pending_at_end` if something
   was still unrecorded); an hourly reaper cleans up old state dirs.

Every nudge resolves exactly once: `followed`, `dismissed` or `ignored`.

**The two nudge lines** (what Claude sees, verbatim):

```
[wb-capture] Last turn read like a decision ("<matched phrase>"). If it settled something, run /wb-decide; otherwise ignore or /wb-decide dismiss.
[wb-capture] A background review drafted an unrecorded decision (<state dir>/draft). Run /wb-decide to review/accept, or /wb-decide dismiss.
```

The first is `source=phrase`, the second `source=sweep`. A draft nudge
beats a phrase nudge when both are pending.

**Stale drafts.** The sweep takes a snapshot of the task file, then waits up
to a minute for Haiku. If the task file changed in that window (usually
`/wb-decide` recording the very decision being drafted) the draft is still
kept, but flagged possibly stale: the nudge says the task file changed while
the draft was written so it may already be recorded, and `/wb-decide status`
lists the `## Decisions` entries added since. Claude shows you the draft next
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
| draft pending | Claude shows the sweep's draft when the draft nudge sent it (or you ran `/wb-decide` with no hint); accept as-is, or edit it first (add the missing rejected alternative / why), only if it reflects a real decision. A wrong or already-recorded draft is dismissed. A phrase nudge or a hinted `/wb-decide` composes from the conversation and leaves the draft alone (a later `clear` still removes it). |
| `/wb-decide dismiss` | Drop the pending marker/draft, log `dismissed`. Quiet no-op if nothing was pending. |
| `/wb-decide mute` / `unmute` | Per-session mute flag: no phrase nudges, no sweeps for this session. Each is logged. |
| `/wb-decide status` | Print pending marker/draft (with paths), mute state, and the log path; for a stale draft, a warning plus the Decisions entries added since the snapshot. |

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
| Script | `~/.config/scripts/tmux/wb-capture.sh` (verbs: `hook-*`, `clear`, `dismiss`, `mute`, `unmute`, `status`); sweep in `wb-capture-sweep.sh` |

**Config keys** — `KEY=value` lines in `capture.conf`, parsed line by line
(never sourced), unknown keys and bad values ignored/defaulted:

| Key | Default | Meaning |
|---|---|---|
| `phrases` | strong list: `we decided\|decided to\|going with\|let's go with\|we'll go with\|i'll go with\|went with\|settled on\|the decision is\|chose \|opting for\|ruled out` | `\|`-separated, case-insensitive fixed strings |
| `cooldown` | `3` | turns between phrase nudges |
| `sweep_every` | `4` | unchanged turns before a sweep |
| `sweep` | `on` | `on` / `off` — the Haiku background sweep |
| `sweep_timeout` | `60` | seconds for the sweep child |
| `sweep_max_failures` | `3` | consecutive failed sweeps before the sweep stops for the session (`0` = never stop) |

**Log events** (`log.jsonl`, one JSON object per line: `ts`, `session_id`,
`task`, `event`, optional `source`): `nudge_fired{source}`,
`followed{source}`, `dismissed`, `ignored{source}`, `muted`, `unmuted`,
`sweep_ran{result: none|draft|error|timeout}` (`stale: true` added when the
task file changed during a draft sweep; `followed`, `dismissed`, `ignored` and
`draft_discarded` carry `stale: true` too when they resolve a stale draft),
`sweep_skipped{reason: disabled|muted|draft_pending|backoff|no_new_content}`,
`draft_discarded{reason: ignored_twice}`,
`pending_at_end{marker,draft}` (from SessionEnd; the sweep logs it as just
`{draft:true}` when the session ended while Haiku was still running),
`pending_orphaned`.

**Measuring it** — follow / dismissal / ignored rate overall and per source,
plus sweep result counts (dismissals carry no source, so they're overall only):

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
  sweep_results: ([.[] | select(.event == "sweep_ran")] | group_by(.result) | map({(.[0].result): length}) | add)
}' ~/.local/state/wb/capture/log.jsonl
```

**Close-out interaction.** `/close-out` step 4: if `## Decisions` is still
empty at wind-down, the agent either writes a real entry or appends an
affirmed marker (`### <timestamp> — close-out` / `_No decisions: <reason>_`)
via `wb append`. An unmarked empty section keeps meaning "nobody checked".
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
  `rm` the file to re-enable.
- **Sweep only:** `sweep=off` in `~/.config/wb/capture.conf`.
- **One session:** `/wb-decide mute` (and `/wb-decide unmute`).
- **Removal:** delete the plugin dir and restart sessions.
