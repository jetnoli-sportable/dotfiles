---
title: verify-behaviour
status: current
tile: A standing watcher session that confirms shipped behaviour works in real use, from checks.md files, with no ticking.
group: skills
kind: guide
updated: 2026-10-25
---

## Overview

Some behaviour can only be checked in real use: a message reaching the
right session, a hook's output landing in an agent's context, a status-bar
count clearing after a review. These used to be handed off as tickable HTML
checklists, which mostly never got ticked, and whose ticks lived in one
browser's storage where nothing else could see them.

`/verify-behaviour` replaces the ticking. A feature writes its live checks
into `checks.md` in its task-store dossier. One standing watcher session,
on Sonnet, waits for evidence at no token cost. When a transcript, the
decision-capture log or a task's `## Decisions` shows something a check is
waiting for, the watcher wakes, judges it, and records **met**, **broken**,
**partial** or a **proposal** in `verdicts.md` beside the checks. Every
verdict quotes its evidence. Checks that need judgement go to Jet as "looks
met, confirm?". Because the watcher is live, it can flag a misfire within
seconds, while Jet still remembers what just happened, and it can ask Jet to
trigger a check on the spot.

The watcher is read-only toward every other session: it never messages
them, types into their panes or writes their task files. It talks only to
Jet, in its own pane.

## Try it now

Once, create the watcher's standing task, then start it in that task's agent
pane:

```
wb new dotfiles verify-behaviour-watcher
verify-behaviour
```

It replies with a digest: proposals waiting for you, partial and open checks
per feature, and every checks file still waiting for rollout. Then it goes
quiet until something happens. Talk to it any time ("what's verified?",
"stage C4", "yes 2").

To restart it, quit the session and type `verify-behaviour` again. **Never
restart it with `wb resume`**: that types a plain `claude --resume`, without
the settings below, and the watcher's wait refuses to arm without them. All
of its state is on disk, so a fresh session picks up where the old one
stopped.

## Reference

**What `verify-behaviour` sets** (a zsh function beside the `claude` wrapper
in `zsh/.zshrc`):

| Setting | Why |
|---|---|
| `--model sonnet`, `--autocompact 100k` | cheap turns, small context |
| `WB_AGENT_MEM_HIGH=1G` | the watcher's memory scope is squeezed first under pressure; `MemoryMax` is unchanged, so it is slowed, never the cause of a kill |
| `WB_VERIFY_WATCHER=1` | the marker the wait script requires before arming |
| `--disallowedTools` | keeps it out of other panes and other tasks' files: `SendMessage`, `Edit`, `Write`, `NotebookEdit`; tmux `send`/`paste`/`run` in any abbreviation or flag order; every wb verb that writes (`append`, `set`, `done`, `pause`, …), bare or by `wb.sh` path; the `wb-capture.sh` shelf verbs. Read-only commands such as `wb board` still work. A prefix list can't see inside `bash -c` or a redirect; the skill's read-only rule covers those |

**Writing checks.** A feature that needs live checking writes
`~/code/tasks/dossiers/<task>/checks.md`. Writing the file is the
registration; the watcher finds every `dossiers/*/checks.md` itself. The
format, with a worked example, is in the skill's
`references/checks-format.md`. In short:

```
# Demo relay — live checks
feature: demo-relay
scope: demo--parent demo--child
live_since:

## C1. Decision reaches the child
kind: match
trigger: transcript /<cross-session-message[^>]*>[^<]*\[demo-relay\]/
evidence: the child session's transcript
met when: a child session receives a [demo-relay] message after a decision is recorded
broken when: a decision is recorded and no child session receives a message
```

`live_since` stays empty until the feature is merged and stowed. The
session that re-stows the main checkout sets it, in the same step.

**Check states.**

| State | Meaning |
|---|---|
| waiting | `live_since` is empty: not live yet |
| open | live, not seen yet |
| partial | some evidence, more needed |
| proposed | a judge check that looks met, waiting for Jet's yes |
| met | confirmed working; a `match` check gets here on its own, a `judge` check only with Jet's yes |
| broken | the broken-when condition was seen |

**Where results land.** One line per verdict in `verdicts.md` beside each
`checks.md` (the newest line for a check is its state), and the same line in
the watcher task's `## Verdicts`. `ls ~/code/tasks/dossiers/*/verdicts.md`
shows what has been verified. A broken verdict or a new proposal puts a red
`⚑N` at the left of the status bar in every session; it clears when Jet next
talks to the watcher.

**How it waits.** The watcher runs
`claude/.claude/skills/verify-behaviour/scripts/verify-wait.sh wait` in the
background. The script polls with one `stat` pass every 5 seconds, reads only
new lines, and exits only when new content matches an open check's trigger,
a checks file changes, or the watching session is gone. Its exit wakes the
watcher. It never exits on a timer, so a quiet day costs no tokens. Hits are
written to disk before they are delivered and stay listed until the watcher
acks them, so nothing is lost to a crash or an interrupted turn.

## Known rough edges

- **Judge quality on fuzzy checks.** Sonnet judges checks like "the recipient
  followed the rule". That is why judge checks need Jet's yes, and why every
  verdict quotes its evidence.
- **Transcript format drift.** Claude Code's transcript format is internal
  and can change between versions. The watcher runs a self-test at start and
  tells Jet if transcript triggers can't be trusted.
- **Restarts through `wb resume` don't work**, as above. The wait answers
  `BAD-LAUNCH` and the watcher tells Jet to relaunch.
- **`live_since` is set by hand** after a stow. Until it is set, the checks
  stay waiting, and every digest lists them so they aren't forgotten.
- **Staged, absence and exactly-one checks** are held as partial and decided
  at the next wake or when Jet says "done"; there is no settle timer.

## Next steps / reverting

Next: set `live_since` automatically when a stow lands, and a `wb verify`
shortcut if the two-step start proves awkward.

To turn it off, quit the watcher session. Nothing else depends on it: the
`checks.md` and `verdicts.md` files stay as plain records, and the status-bar
segment shows nothing while `@verify_alert` is unset (`tmux set -gu
@verify_alert` clears a stale one).
