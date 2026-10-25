# checks.md — how a feature describes its live checks

A feature that needs checking in real use (something automated tests can't
show, like "a session that records a decision gets a message in the next
session") writes its checks into `checks.md` in its task-store dossier:

```
~/code/tasks/dossiers/<task-stem>/checks.md
```

Writing the file is the registration. The verify-behaviour watcher finds every
`dossiers/*/checks.md` on its own, waits for evidence, and records verdicts in
`verdicts.md` beside it. Nobody ticks anything. This file replaces the old
hand-ticked HTML verification checklist.

The watcher never writes `checks.md`. The feature's own session writes it, and
edits it later if a check needs rewording.

## Header

Everything above the first `## ` heading is the header. Three fields:

```
# <Feature name> — live checks
feature: <short name>          (defaults to the dossier folder name)
scope: <task stems or family root this feature touches>
live_since: <ISO time, or empty>
```

`live_since` gates everything:

- **Empty** means the behaviour is not live yet (not merged, or merged but not
  stowed). The checks show as *waiting for rollout*, produce no verdicts, and
  every watcher digest lists the file with how long it has waited.
- **Set** (for example `live_since: 2026-11-02T09:30:00Z`) means the behaviour
  is live from that moment. The session that re-stows the main checkout after
  the merge sets it, in the same step as the stow. Only sessions *started*
  after `live_since` count as evidence, because skills and hooks load when a
  session starts. The first time the watcher sees a file go live it scans the
  transcript and capture-log history since `live_since` once, so behaviour
  that already happened is judged too.

Rollout notes (what has to happen before the feature is live) go in the header
as prose. They are not checks.

## A check

Each check is a `## <id>. <title>` heading followed by fields, one per line:

```
## C3. Child session gets the decision
kind: match
trigger: transcript /<cross-session-message[^>]*>[^<]*\[demo-relay\]/
evidence: the receiving session's transcript
met when: a child session receives a message carrying the [demo-relay] tag within a minute of the decision
broken when: the decision was recorded and no child received a message
```

- **id** is the first word of the heading (`C3`). Keep it stable: verdicts are
  keyed on it.
- **kind:** `match` or `judge`.
  - `match`: the watcher can tell from the quoted evidence alone. When it has
    checked the quote against `met when`, the check retires itself (state
    *met*), and its next reply says so; Jet can reopen it.
  - `judge`: needs judgement ("the recipient followed the rule", "the colour
    looked right"). The watcher proposes it to Jet as "looks met, confirm?"
    with its quote, and only Jet's yes retires it. Checks only Jet can see,
    such as how the status bar looks, are `judge` with `evidence: Jet`.
- **trigger:** one or more lines, `trigger: <source> /<regex>/`. Any trigger
  matching wakes the watcher for this check. Sources:
  - `transcript` — new lines in any session transcript under
    `~/.claude/projects`. Matched against the *decoded text* of user and
    assistant messages, received peer messages, and hook output injected into
    a session. Tool results, subagent hand-backs and skill listings are never
    matched, and neither is the watcher's own session.
  - `capture-log` — new lines in the decision-capture log
    (`~/.local/state/wb/capture/log.jsonl`), matched against the raw JSON line,
    so `/"event":"draft_shelved"/` works. Lines logged for the watcher's own
    task are skipped.
  - `decisions:<task-stem>` — a bullet *added* under `## Decisions` in that
    task file, matched against the bullet's text. Editing an existing bullet,
    or any other section, never fires. Bullets carry no time, so ones already
    in the file when the watcher first watches it are history it can't date:
    they never count, and the first-live scan skips this source.
  The regex is a jq (Oniguruma) regex, written between the first and the last
  `/` on the line. An invalid regex never matches.
- **evidence:** where to look when judging. It may name a read-only command
  (`wb board --json`, `tmux show -gv status-right`). A command is never a
  trigger, because there is nothing to poll.
- **met when:** the observable condition, written so a quote can show it.
- **broken when:** the observable failure. If the watcher sees it, it records
  *broken* and raises the status-bar alert.

## Picking a trigger that won't match quoted text

The commonest false wake is a trigger that matches someone *talking about* the
behaviour: a plan, a subagent report, a code review quoting the tag. Anchor on
something only the real event produces:

- For a message between sessions, anchor on the received-message frame:
  `/<cross-session-message[^>]*>[^<]*\[demo-relay\]/`, not bare `/\[demo-relay\]/`.
- For hook output, anchor on the exact line shape the hook prints
  (`/^\[demo-hook\] /`), not a word from it.
- For the capture log, anchor on the event name: `/"event":"draft_shelved"/`.
- For a decision, prefer a `decisions:<stem>` trigger over a transcript one:
  it fires only when the bullet really lands.

Checks about *absence* ("nothing gets sent when the decision touches only this
task") and *exactly one* ("one message, not two") still need a trigger: the
event that starts the window. The watcher holds such a check as *partial*
and decides it at its next wake or when Jet says "done" or "check now".

## States

| State | Meaning |
|---|---|
| waiting | `live_since` is empty: not live yet |
| open | live, not seen yet |
| partial | some evidence, more needed (staged, absence, exactly-one checks) |
| proposed | a judge check that looks met, waiting for Jet |
| met | confirmed working |
| broken | the broken-when condition was seen |

## verdicts.md

The watcher's wait script owns `verdicts.md`; nobody edits it by hand. One line
per verdict, newest last, and a check's current state is its last line:

```
- 2026-11-02T10:14:03Z | demo-relay/C3 | met | transcript demo--child @1840-2210 | <cross-session-message from="demo--parent">[demo-relay] use the v2 schema</cross-session-message>
```

Listing `~/code/tasks/dossiers/*/verdicts.md` shows what has been verified.

## Worked example

```
# Demo relay — live checks
feature: demo-relay
scope: demo--parent demo--child
live_since:

Rollout: merge the demo-relay branch, re-stow, then set live_since.

## C1. Decision reaches the child
kind: match
trigger: transcript /<cross-session-message[^>]*>[^<]*\[demo-relay\]/
evidence: the child session's transcript
met when: a child session receives a [demo-relay] message after a decision is recorded in the parent
broken when: a decision is recorded in the parent and no child session receives a message

## C2. Unrelated decisions stay put
kind: judge
trigger: decisions:demo--parent /.*/
evidence: the parent's new Decisions bullet, then child transcripts for the next few minutes
met when: a decision that concerns only the parent produces no [demo-relay] message
broken when: such a decision produces a message in a child

## C3. The recipient acts on it
kind: judge
trigger: transcript /<cross-session-message[^>]*>[^<]*\[demo-relay\]/
evidence: the child's next assistant turns after the message
met when: the child acknowledges the decision and its next change follows it
broken when: the child ignores the message or contradicts the decision
```
