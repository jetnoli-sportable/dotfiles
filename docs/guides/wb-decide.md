---
title: wb-decide
status: current
tile: Record a decision into ## Decisions — and review the ones a background sweep drafted, waiting on a per-task shelf, at /wb-save, /close-out and the weekly review.
group: skills
kind: guide
updated: 2026-10-25
---

## Overview

`/wb-decide` is the "record" half of decision auto-capture. Decisions made
in a wb session used to vanish unless someone remembered to write them
into the task file's `## Decisions` section. That matters because
`## Decisions` is what a later session, a reviewer, or you in a month
reads to learn *why* the code looks the way it does.

The `wb-capture` plugin (`claude/.claude/skills/wb-capture/`, hooks only)
closes the gap in the background. A model "sweep" reads the session's
transcript, finds decisions nobody recorded, and drafts each one as its
own small file on the task's **shelf** (a per-task folder of drafts
waiting for your review). Nobody is nudged and nothing is injected into
the agent's context. A draft just waits until you are already reviewing
work: a `/wb-save`, a `/close-out`, or the weekly review. In between, a
count of waiting drafts shows in the tmux status bar and on `wb board`.
Hooks never write the task store; accepting a draft is an ordinary
`wb append … Decisions` that the review step runs for you.

**The lifecycle, in plain words:**

```
  async sweep (Stop hook, after 4 quiet turns) ─┐
  checkpoint sweep (/wb-save, /close-out,       ├─> model reads the new turns,
                    /wb-decide shelved)        ─┘    your ## Decisions, and the shelf
                                                          │
                          one file per drafted decision   ▼
              ~/.local/state/wb/capture/shelved/<task>/<timestamp>-<session>.md
                          │                                │
        ✎N in the status bar,                              ▼
        DRAFTS column and chip on wb board       review at a checkpoint:
        (you can see it is waiting)              /wb-save · /close-out · /wb-decide shelved
                                                 ├─ accept / edit -> wb append Decisions, then
                                                 │                   accept: file moves to resolved/
                                                 ├─ dismiss       -> file moves to resolved/
                                                 └─ leave         -> stays on the shelf (logged)
                                                          │
                          weekly review: drafts older than 7 days, whatever the task's
                          status, plus any left at 3+ reviews (offered for dismissal)
```

**Step by step:**

1. **The sweep drafts.** After the task file has gone 4 turns unchanged
   (the *async sweep*, an async `Stop` hook), or whenever a checkpoint
   asks for one (the *checkpoint sweep*), a headless model reads the new
   part of the transcript. It also sees three lists: your recorded
   `## Decisions`, the drafts already waiting on the shelf, and the
   drafts you dismissed in the last 14 days, so a later turn that recaps
   a decision does not draft it twice or revive a rejected one. If it
   finds unrecorded decisions it writes up to 3 entries, and each entry
   is shelved as its own file (so "one draft" always means "one
   decision"). If it finds none it answers NONE and nothing is written.
2. **The count shows.** The tmux status bar shows `✎N` (peach) for the
   current session's task when N drafts are waiting, and nothing at zero
   or when the session has no task. `wb board` shows a DRAFTS column
   (text view) and a drafts chip beside the PR chip (HTML view).
3. **A checkpoint reviews.** `/wb-save`, `/close-out` and `/wb-decide
   shelved` all run the same procedure ("step 2b" in the `wb-decide`
   skill): run one checkpoint sweep and wait for it, then show each of
   the task's drafts one at a time and ask accept, edit, dismiss or
   leave. Accepting records the entry into `## Decisions` and moves the
   draft to `resolved/`. Dismissing moves it to `resolved/`. Leaving
   keeps it on the shelf and logs that this review showed it.
4. **The weekly review catches stragglers.** `/weekly-review` lists
   every shelved draft older than seven days, whatever its task's
   status (so tasks that never close still get reviewed), together with
   drafts left behind by finished tasks. A draft you have seen and left
   at 3 or more reviews is offered for dismissal: it is probably not a
   real decision, or the review has become tiresome. The skill offers,
   it never dismisses unasked.

Nothing is ever deleted unseen. An accepted or dismissed draft is moved
to `~/.local/state/wb/capture/resolved/<task>/`, where the reaper keeps
it for 30 days.

**What changed (2026-10-24).** The agent-facing nudge and phrase
matching are gone. The log from the first five days showed why: of 38
nudges, 3 were genuinely followed by the agent, and phrase matches were
nearly all recaps of old decisions. Every draft that was ever accepted
was accepted by a person reviewing it (10 of 12 reviewed), so the drafts
now go to you at moments you are reviewing, not to the agent in the
middle of a request. The strikes, follow/ignore bookkeeping and the
two-phase `accept --begin` went with the nudge.

**After a record: telling the rest of the family (2026-10-25).** A
recorded decision now reaches the other live sessions it affects in the
same task family. Other running sessions never re-read their task files,
so without this a sibling session could keep building on an assumption
that had just changed. After any successful Decisions append, the skill
(step 6) lists the family's live sessions (`wb family <task> --sessions`,
matched against ListAgents), reads each one's `## Plan` and latest
Handoffs entry, and messages only those the decision changes something
for. The default is nobody. A session waiting on its user is named but
not messaged. A shelf review sends once at its end, `/close-out` once per
run, and the weekly review once per family, never once per draft. Each
message starts `[wb-propagate]` and tells the recipient to act only
within its own task, not to reply or forward, and not to send on any
decision it records because of the message.

Step 7 is the promotion offer: copying a decision that changes how the
system behaves into the family's `CONCEPTS.md`, which every new session
in the family loads. It shows the exact lines, the target file, which
tasks it reaches and what each line supersedes, and writes only what you
approve. `/close-out` always offers it. Mid-session it is offered only
when the family already has a `CONCEPTS.md` and another family session
is live. Creating a family's first `CONCEPTS.md` happens only at
`/close-out`, followed by `wb family <task> --reseed` so existing
worktrees import it.

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

To review what the sweep drafted, any time:

```
/wb-decide shelved
```

It runs a checkpoint sweep first (so turns not yet swept are covered),
then walks the drafts. And to check the machinery:

```
/wb-decide status
```

## Reference

**Modes of `/wb-decide`**

| Invocation | What it does |
|---|---|
| `/wb-decide [hint]` | Compose a new entry from the conversation and `wb append` it under `## Decisions`. If nothing was actually decided it says so and writes nothing. Shelved drafts are not part of this path. |
| `/wb-decide shelved` | Run the checkpoint review: one checkpoint sweep, then each of this task's drafts one at a time: accept (optionally edited), dismiss, or leave. Ends with one line counting recorded / dismissed / left. |
| `/wb-decide dismiss <path>` | Dismiss one shelved draft by path (moves it to `resolved/`). A bare `dismiss` with no path is a usage error. |
| `/wb-decide mute` / `unmute` | Per-session mute flag: silences the async sweep and makes a checkpoint sweep print `skipped: muted`. Existing drafts can still be reviewed. Each is logged. |
| `/wb-decide status` | Print mute state, the session id, the log path, and one `shelved: <path>` line per draft on this task's shelf (`(stale)` after a stale one; `shelved: none`). Read-only. |

Entries are append-only; a correction is a new entry carrying a
`(supersedes: <date> "<title fragment>")` line that names the one it replaces
(the date plus a quoted substring of its title). The write uses a
`<<'WB_DECISION_END'` heredoc rather than `<<'EOF'`, so a draft line reading
exactly `EOF` can't end it early.

**Accepting is one step.** Chain the append and the accept with `&&`, so
a failed append skips the accept and the draft stays shelved:

```
wb append <task> Decisions - <<'WB_DECISION_END' && ~/.config/scripts/tmux/wb-capture.sh accept <path>
…the entry…
WB_DECISION_END
```

**The checkpoint sweep.** `wb-capture.sh sweep` runs the sweep in forced
mode and waits for it (up to about two minutes: its child timeout is 60
seconds, doubled for its one stale rerun, about $0.12 at the default
model). It ignores the four-quiet-turns rule and the failure backoff,
because one attempt at a checkpoint is the point, and it skips the model
call when nothing was written since the last sweep. It prints exactly one
line and always exits 0, so a skill always goes on to the review:

| Line | Meaning |
|---|---|
| `drafted N` | N drafts were shelved for this task |
| `none` | the model found nothing unrecorded |
| `nothing new` | nothing written to the transcript since the last sweep (no model call) |
| `skipped: <reason>` | `off` (kill switch, `WB_CAPTURE_SWEEP` or `sweep=off`), `muted`, `no session`, `no transcript`, `no jq` |
| `failed: <reason>` | `timeout`, `error` (model or shelving failed) or `invalid` (the model broke the output contract) |

It does not wait on an async sweep. If the two overlap, the worst case
is a duplicate draft, which the review dismisses in one step.

**Stale drafts.** The sweep snapshots the task's `## Decisions` section
(the exact text the model is shown), then waits up to a minute for the
model. Edits elsewhere in the task file don't count. If `## Decisions`
changed in that window (usually `/wb-decide` recording the very
decision being drafted), the answer is thrown away and the model is
asked once more against the current section, so it either answers NONE
or drafts something genuinely new (`sweep_ran` logs `rerun: true`). Only
if the section changes *again* during the rerun is the draft shelved but
flagged stale (a `.stale` sidecar file beside it): the review shows it
next to the newest `## Decisions` entries and asks whether it is already
recorded. Events about a stale draft carry `"stale":true`.

**Closed tasks and no session.** A shelved draft whose task is already
closed is still resolvable from any wb session, or from none: path-carrying
`accept`, `dismiss` and `keep` ignore the kill switch and need no `@task`.
The task stem comes from `--task <stem>`, else the session's task, else
the command exits 1 with a message. With no session the event is logged
with an empty `session_id`. `wb-capture.sh shelved --task <stem>` lists
one task's drafts and `shelved --all` lists every task's, grouped by task.
Drafts left by `wb done --leave-shelved` are reachable this way.

**`wb done` won't strand decision drafts.** `wb done` refuses (before it
touches anything, including a store-only close) while the task's shelf
holds any draft. It asks `wb-capture.sh pending-for-task` rather than
reading the state dir itself, prints each path as `shelved: <path>`, and
points to `/close-out` or `/wb-decide shelved`, or to re-running with
`wb done --leave-shelved` to close anyway. `--leave-shelved` closes, logs
one `shelved_left{count}` line to the capture log (via `wb-capture.sh
log-shelved-left`) and notes the left drafts in the task's `wb done`
Handoffs entry. A `wb done` invoked through `/wb-done` relays the refusal;
it never adds `--leave-shelved` on its own.

**Paths**

| What | Where |
|---|---|
| State root | `~/.local/state/wb/capture/` (honours `XDG_STATE_HOME`) |
| Per-session state | `~/.local/state/wb/capture/<session_id>/` (sweep bookkeeping: `taskhash`, `unchanged`, `muted`, `ended`, `taskpath`, `transcript`, `sweep_offset`, …) |
| Event log | `~/.local/state/wb/capture/log.jsonl` (rotated to `log.jsonl.1` above 5 MB) |
| Config (optional, untracked) | `~/.config/wb/capture.conf` |
| Kill switch | `~/.local/state/wb/disable-capture` |
| Shelved drafts | `~/.local/state/wb/capture/shelved/<task-stem>/<timestamp>-<session>.md`, one decision per file (a `.stale` sidecar marks a stale one; `shelved/_unknown/` when the task wasn't known) |
| Resolved drafts | `~/.local/state/wb/capture/resolved/<task-stem>/<timestamp>-<outcome>-<name>.md`, where `<outcome>` is `shelved_accepted` or `shelved_dismissed` and `<name>` is the shelved file's name (kept 30 days, then pruned by the hourly reaper; to recover one, copy it back into `shelved/<task>/`) |
| Scripts | `~/.config/scripts/tmux/wb-capture.sh` (verbs: `hook-prompt`, `hook-stop`, `hook-end`, `hook-posttool` (a silent no-op kept for sessions started before the change); `accept\|dismiss\|keep [--task <stem>] <shelved path>`; `sweep`; `mute`, `unmute`, `status`; store verbs that need no session: `shelved [--all [--min-age-days <N>] \| --task <stem> \| --count --task <stem>]`, `pending-for-task <task-file>`, `log-shelved-left <stem> <count>`); the sweep itself is `wb-capture-sweep.sh`; the status-bar segment is `capture-status.sh` |

The hooks do a few small jobs: `hook-prompt` and `hook-stop` record the
session's transcript path (the checkpoint sweep reads it from there),
`hook-stop` also records the task path and counts quiet turns, `hook-end`
marks the session ended, and an hourly reaper tidies old session dirs, moves any leftover pre-change
per-session draft to the shelf (reason `reaped`) and prunes `resolved/`.

**Config keys** — `KEY=value` lines in `capture.conf`, parsed line by line
(never sourced), unknown keys and bad values ignored/defaulted:

| Key | Default | Meaning |
|---|---|---|
| `sweep_every` | `4` | unchanged turns before an async sweep |
| `sweep` | `on` | `on` / `off` — the background model sweep (a checkpoint sweep then prints `skipped: off`) |
| `sweep_timeout` | `60` | seconds for the sweep child (`0` means the default 60; the reaper's grace for an ended session, 2 x timeout + 60s, uses the same fallback) |
| `sweep_max_failures` | `3` | consecutive failed sweeps before the async sweep stops for the session (`0` = never stop) |
| `sweep_model` | `sonnet` | model alias or id for the sweep child (letters, digits, `.`, `_`, `-`, not starting with `-`; anything else falls back to the default). Measured 2026-10-22 on a sweep-sized call: Haiku about $0.006, Sonnet 5.5 at medium effort about $0.124, both about 2s |
| `sweep_effort` | `medium` | `low` / `medium` / `high` / `xhigh` / `max` — the child's `--effort` (anything else falls back to the default) |

**Log events** (`log.jsonl`, one JSON object per line: `ts`, `session_id`,
`task`, `event`, plus event fields). Every event about one drafted decision
carries a `draft` field holding the shelf file's name, which is how a
decision is followed from shelving to review:

| Event | Fields | Logged when |
|---|---|---|
| `draft_shelved` | `reason` (`sweep`, or `reaped` for a leftover pre-change draft), `draft`, `stale: true` when stale | a drafted decision is written to the shelf (once per file) |
| `shelved_accepted` | `draft`, `stale: true` when stale | `accept` moved a draft to `resolved/` |
| `shelved_dismissed` | `draft`, `stale: true` when stale | `dismiss` moved a draft to `resolved/` |
| `shelved_kept` | `draft` | `keep` — a review showed the draft and you left it; the file stays |
| `shelved_left` | `count` (empty `session_id`) | `wb done --leave-shelved` closed a task with drafts still shelved |
| `sweep_ran` | `result` (`none`, `draft`, `invalid`, `error`, `timeout`), `model`, `effort`; `entries` on a draft (1-3: how many files it became); `rerun: true`; `stale: true` | a sweep's model call finished. `invalid` means an answer that is neither NONE nor a `### ` entry: its excerpt is retried once, then skipped, and it never counts toward `sweep_max_failures` |
| `sweep_skipped` | `reason`: `disabled`, `muted`, `backoff`, `no_new_content` | a sweep ended without a model call |
| `muted` / `unmuted` | none | `/wb-decide mute` / `unmute` |

Events from before the 2026-10-24 change (`nudge_fired`, `followed`,
`ignored`, `dismissed`, `pending_at_end`, `pending_orphaned`) stay in old
logs but nothing writes them now. `draft_shelved`, `shelved_accepted` and
`shelved_dismissed` lines from before it have no `draft` field, which is
how the queries below tell old drafts from new ones.

**Measuring it** — three measures, over drafts shelved after the
2026-10-24 rollout only (a draft with no `draft` field is older and is
left out). They match the graduation review's gates:

- **Accuracy** — accepted out of accepted + dismissed. It says whether
  drafts are *right*. A draft you chose to leave counts for neither side,
  because leaving is often legitimate (not decided yet, waiting on
  something outside the session). The review's gate is at least 70% over
  at least 10 resolved drafts.
- **Delivery** — every draft is shown at a review (a `shelved_kept`,
  `shelved_accepted` or `shelved_dismissed` event) within 7 days of being
  shelved. It says whether drafts actually *reach you*. A draft nobody
  showed you for a week is a failure of the checkpoints, not of the
  model.
- **Left 3+ times** — drafts shown at 3 or more reviews and still on the
  shelf. Reported, not gated: probably not real decisions, or review
  fatigue. The weekly review offers them for dismissal.

```bash
jq -s --argjson now "$(date +%s)" '
def epoch: capture("^(?<t>.*)(?<s>[+-])(?<h>[0-9]{2}):(?<m>[0-9]{2})$")
  | ((.t + "Z") | fromdateiso8601)
    - (if .s == "+" then 1 else -1 end) * ((.h | tonumber) * 3600 + (.m | tonumber) * 60);
def pct($a;$b): if $b == 0 then null else (($a * 1000 / $b | round) / 10) end;
def has_draft: ((.draft // "") != "");
[ .[] | select(.event == "draft_shelved" and has_draft) ] as $shelved
| [ .[] | select(.event | IN("shelved_kept","shelved_accepted","shelved_dismissed"))
          | select(has_draft) ] as $reviews
| ( $shelved | map( . as $s
    | ($reviews | map(select(.draft == $s.draft))) as $r
    | { draft: $s.draft, task: $s.task, shelved_at: ($s.ts | epoch),
        first_shown_at: ($r | map(.ts | epoch) | min),
        kept: ($r | map(select(.event == "shelved_kept")) | length),
        outcome: ( if   any($r[]; .event == "shelved_accepted")  then "accepted"
                   elif any($r[]; .event == "shelved_dismissed") then "dismissed"
                   else "waiting" end ) } ) ) as $d
| ($d | map(select(.outcome == "accepted"))  | length) as $acc
| ($d | map(select(.outcome == "dismissed")) | length) as $dis
| 604800 as $week
| {
    shelved_since_rollout: ($d | length),
    accuracy: { accepted: $acc, dismissed: $dis, resolved: ($acc + $dis),
                accuracy_pct: pct($acc; $acc + $dis),
                enough_sample: (($acc + $dis) >= 10) },
    delivery: {
      shown_within_7d: ($d | map(select(.first_shown_at != null and (.first_shown_at - .shelved_at) <= $week)) | length),
      shown_late:      ($d | map(select(.first_shown_at != null and (.first_shown_at - .shelved_at) >  $week)) | length),
      never_shown_over_7d: ($d | map(select(.first_shown_at == null and ($now - .shelved_at) > $week)) | length),
      waiting_under_7d:    ($d | map(select(.first_shown_at == null and ($now - .shelved_at) <= $week)) | length) },
    left_3_plus_times: ($d | map(select(.outcome == "waiting" and .kept >= 3) | {task, draft, kept}))
  }' ~/.local/state/wb/capture/log.jsonl
```

Reading it: the delivery gate passes when `shown_late` and
`never_shown_over_7d` are both 0. The accuracy gate passes when
`enough_sample` is true and `accuracy_pct` is 70 or more. Fewer than 10
resolved drafts by the review date moves the review out a week.

**Close-out interaction.** `/close-out` step 4 runs the same checkpoint
review (sweep, then each draft) before the wind-down. If `## Decisions`
is still empty after it, the agent either writes a real entry or appends
an affirmed marker (`### <timestamp> — close-out` / `_No decisions:
<reason>_`) via `wb append`. An unmarked empty section keeps meaning
"nobody checked". Tasks closed with bare `wb done` (no `/close-out`) are
left unmarked.

**`/wb-save` interaction.** `/wb-save` runs the review before composing
its entry, so the Handoffs entry can say how many decisions were
recorded, dismissed and left.

**Rollout.** Stow (`stow --no-folding -t "$HOME" claude scripts tmux` from
the main checkout after fast-forwarding) and restart Claude sessions. The
plugin loads automatically as `wb-capture@skills-dir`. Already-running
sessions keep calling the old `hook-posttool` registration (a silent
no-op) until restarted; editing the scripts takes effect live, but
adding or removing a hook entry needs a restart. A draft left in the old
per-session slot is moved to the shelf once by hand at rollout; nothing
writes that slot any more.

## Known rough edges

- Only works inside a wb tmux session with `@task` set; elsewhere the
  agent verbs are silent no-ops (the store verbs and path-carrying
  `accept`, `dismiss`, `keep` work anywhere).
- A draft sees only a transcript excerpt, so it can be wrong or already
  recorded. Accuracy (above) measures how often.
- A checkpoint sweep and an async sweep don't lock against each other: the
  worst case is a duplicate draft (dismissed in one step) or a draft that
  lands just after a review (it stays on the shelf and in the count).
- The status count follows the current session's task, not a total across
  tasks. `wb board` shows every task's count.
- `/clear` and `wb resume` session-id behaviour is still being confirmed
  live.

## Next steps / reverting

A graduation review (`dotfiles--capture-graduation-review`, due
2026-11-02) decides, from the accuracy, delivery and left-3+-times
figures above, whether to keep the feature, retune it, or drop it. It
also gates on no task closing after rollout with an unmarked empty
`## Decisions`.

To turn it off, in order of bluntness:

- **Kill switch (all sessions, instant):** `touch ~/.local/state/wb/disable-capture`;
  `rm` the file to re-enable. (Resolving a shelved draft by path or `--task` still
  works with it on: that is cleanup of existing drafts, not capture.)
- **Sweep only:** `sweep=off` in `~/.config/wb/capture.conf`.
- **One session:** `/wb-decide mute` (and `/wb-decide unmute`).
- **Removal:** delete the plugin dir and restart sessions.
