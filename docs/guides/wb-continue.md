---
title: wb-continue
status: current
tile: Save and carry on in a fresh context, without visiting the pane to type /clear and /wb-resume.
group: skills
kind: guide
updated: 2026-11-15
---

## Overview

A wb session that needs a fresh context used to stop and wait for you to type
`/clear` and then `/wb-resume`. With several sessions running, most of those
visits decided nothing: the save already said what was done and what came next.
`/wb-continue` removes them.

```
/wb-continue <instruction>
```

means: save, restart this pane with a fresh Claude, and do this. It runs
`/wb-save`'s procedure, then asks for a restart. When the turn ends, the
wb-continue Stop hook checks that nothing is still running and restarts the same
pane with a fresh Claude. That Claude is handed the save through
`/wb-resume --continue`, which a script checks: it is exactly the save that asked
for the restart, nothing newer landed, and the branch and working tree haven't
moved since.

A Claude can't clear its own context: Claude Code's auto-mode check refused an
agent typing `/clear` into its own pane, twice, in July 2026. So nothing here
types into a Claude. The hook restarts the pane's shell and types the launch
command into the shell.

Saves that shouldn't restart by themselves wait in the picker's **ready to
continue** list, and one key starts them.

## Try it now

In a wb session, at a point where the next step can run in a fresh context:

```
/wb-continue tell me where things stand on the entrypoint PR
```

The session saves, says the pane will restart when the turn ends, and stops.
While shadow mode is on (see below), nothing restarts: the log records what would
have happened, and you `/clear` and `/wb-resume` as usual. With shadow mode off,
the same pane shows a fresh Claude a few seconds later. Its first line names the
save it received, and then it answers your instruction.

Any plain `/wb-save` can be continued later too:

- In the pane: <kbd>prefix</kbd> <kbd>y</kbd>.
- In the picker: the row shows **ready to continue** when the save has a next
  command. <kbd>c</kbd> releases that row, <kbd>C</kbd> every ready row.

## Who decides whether it restarts by itself

| Who asked | The command | Restarts by itself? |
|---|---|---|
| You typed `/wb-continue …` (the turn opened with it) | anything | yes, with your words passed on verbatim |
| The session called it by itself (a build reaching its review) | a read-only code review: `/ce-code-review`, `/compound-engineering:ce-code-review` or `/code-review`, with no arguments or only the read-only ones listed below | yes, unless you're looking at the pane, then it waits in the ready list |
| The session called it by itself | a review with any other argument, or anything else | no, it waits in the ready list |
| The session declined (you have to act first, e.g. switch the model) | anything | no, it waits in the ready list |
| A session started by a restart, by itself | anything | no, it waits in the ready list |
| A plain `/wb-save` | any or none | no, it's staged for a release |

The read-only arguments are, for `/ce-code-review` and
`/compound-engineering:ce-code-review`: `plan:<path>`, `base:<ref>`,
`depth:<value>`, `grouping:<value>`, `mode:agent`, `mode:headless` and a bare PR
number. For `/code-review`: `low`, `medium`, `high`, `xhigh`, `--max-findings <n>`
(or `=<n>`, or `all`) and a bare PR number. Anything else on a session-written
review sends it to the ready list with the reason "the review command has
arguments that are not read-only review options": `apply:local`, `--fix`,
`--comment`, `max`, free words (`/ce-code-review then push and open the PR`), a
second line, or `&&` and `;`. A command that is not a review at all gets "the
command is not a code review". What you typed is never checked this way: any
`/wb-continue` instruction you typed restarts by itself.

The fresh Claude is told who wrote the command: its pick-up prints a `Command
source:` line, "typed by Jet" for your words or "written by the saving session,
not by Jet" for the session's own plan, which it carries out as written without
treating it as something you said. When you released the restart yourself
(<kbd>c</kbd>, <kbd>C</kbd>, <kbd>prefix</kbd> <kbd>y</kbd>) for a session-written
command, the line adds "; Jet released the restart": you approved the restart,
not the words. Only the line directly above "Command to carry out:" counts.

A script decides the row, never the session: it reads the transcript's record of
the prompt that opened the turn. A cron job, a task notification, a message from
another session or a usage-limit resume never counts as typed by you. "Looking at
the pane" means it's in copy mode, or it's the active pane of the active window
of a session whose client was used in the last minute.

## When it waits, and when it refuses

Nothing restarts while any of these hold. The request waits for the next quiet
turn end; if it is still waiting 30 minutes after the save, the next turn end
moves it to the ready list:

- background work is running (monitors don't count);
- a scheduled job is pending;
- a `/decide` surface is open for the task;
- a new turn started, or there's text or a dialog on the input line.

A release (<kbd>c</kbd>, <kbd>C</kbd>, <kbd>prefix</kbd> <kbd>y</kbd>) that only
has to wait for one of these, or for a turn in progress, text on the input line, a
locked request or a missing turn-end record, tells you why in the tmux message
(or the picker's line) and in `continue.log`, and leaves the status line alone:
waiting is not a failure, so the yellow mark never shows for it.

A release of a saved (not armed) request that waits on background work says "background
work was still running at the last turn end; when it finishes, save again": the work's
own turn end would count as the session working on after the save, so the release would
then be refused.

A release also waits, with "no turn end was recorded since the save (is the
wb-continue hook loaded?)", when the Stop hook has not recorded a turn end for the
save yet; without that record it can't tell whether background work is running.

A restart is **refused**, and the save is left untouched, when the save entry
changed, a newer Handoffs entry landed, the branch moved, or the working tree
changed since the save. A release is also refused with "the session kept working
after the save; save again" when a turn ended after the save's own turn: the
fresh Claude would start from an older save and silently drop those turns (the
old session is still there with `claude --resume <old-id>`). Run `/wb-save`
again, then release. A request that was armed and waited through turn ends for
background work is not counted against this: those turn ends belong to the same
continue. A turn *you* open while an armed request waits does count: the next turn
end refuses the request with the same reason (it never restarts a session you kept
working in), and you save again. A background task's notification turn or other
non-human turn doesn't. Only a refusal or a failed restart shows as a yellow `↻N` in the status
line (its reason is on the pane, and the row's reason in the picker); the next
save in that pane clears it. `/clear` then `/wb-resume` always works as before.

A restart that began but never finished (the helper was killed, or its pane is
gone) stops blocking after five minutes (longer if you raised the prompt or pick-up
timeouts: never shorter than the helper's own waits plus a minute): the next save or
release turns it into a failed request naming the old session, and a failed request can
be released again. A request that already respawned its pane keeps the fresh session's
id through any wait, so it stays releasable: the release accepts the fresh Claude, the
Claude that saved (a helper killed before the respawn) or none, never another Claude.
A release also refuses when the restarted Claude has been used: if its transcript
shows a prompt you sent other than the pick-up prompt (a turn you opened, or a
message you typed while it was working), the request is refused with
"the restarted session was used; save again there", so a release never kills a
Claude you have been working in.

A pane at a plain shell is free to restart only when that shell has no child process:
a script, a loop or a background job in it blocks the release ("a command is still
running in the pane's shell"). Text typed after a bare shell prompt is not detected.

## Output you missed

A restart takes the old session's last replies off the screen. Gaining and
losing focus both stamp a Claude pane, so the stamp is when you last left it.
Before a restart, the turns that finished after that stamp are counted (by when
each turn ended, so a turn you watched start but not finish counts). The count
shows as `(N unseen)` on the picker row and an amber `●N unseen` in the status
bar, and adds up across restarts. <kbd>prefix</kbd> <kbd>v</kbd> opens the reply
viewer at a divider above the first unseen turn and clears the marks. A restart of
the pane you're looking at (a `/wb-continue` you typed) counts nothing. Reload
tmux (<kbd>prefix</kbd> <kbd>r</kbd>) once after the stow for the stamps to
start.

## Reference

| Piece | What it is |
|---|---|
| `wb continue stage [<task>]` | What `/wb-save` runs after its entry lands: records the save as a ready request |
| `wb continue arm [--decline] [<task>]` | What `/wb-continue` runs: records the request and picks its row |
| `wb continue status [<task>]` / `drop [<task>]` | Show or remove the task's request |
| `wb continue release <task> \| --all \| --pane <pane>` | Your release: the same checks, then the restart (picker <kbd>c</kbd>/<kbd>C</kbd>, <kbd>prefix</kbd> <kbd>y</kbd>) |
| `wb continue pickup <request-id>` | Run by the fresh Claude through `/wb-resume --continue`; single use |
| `~/.local/state/wb/continue/<task>/` | The request: a frozen copy of the save entry, the instruction, the branch tip and working-tree hash at save time |
| `~/.local/state/wb/continue.log` | One line per change: `<time> wbc event=… stem=… id=… state=… reason="…"` |
| `wb-continue-hook` plugin | The Stop and SessionStart hooks (`wb-continue-hook.sh`); never also wire them in `settings.json` |
| Handoffs | Each restart adds one `wb continue (auto)` entry naming the old session; `claude --resume <old-id>` reopens it |

## Shadow mode and the off switch

The automatic restart ships in **shadow mode**: every check runs and the log gets
`event=would-restart`, but nothing restarts. Your own releases (<kbd>c</kbd>,
<kbd>C</kbd>, <kbd>prefix</kbd> <kbd>y</kbd>) are live from the start. After a
few days of the log agreeing with what you did by hand, turn shadow mode off:

```
touch ~/.local/state/wb/continue-live
```

To turn the feature off entirely (the hooks exit at once, sessions behave as they
did before): `touch ~/.local/state/wb/disable-continue`.

## Known rough edges

- **One Claude per tmux session.** A second Claude in the same session never
  claims a request, and that's all the handling it gets.
- **Messages sent during the restart's few seconds** go to a session that no
  longer exists. The sender's own task file still records the decision.
- **The input-line check reads Claude's screen.** If Claude Code changes its
  prompt glyph, every restart waits (it fails closed) until the check is updated.

## Next steps / reverting

- Pairs with [`/wb-save`](wb-save.html) (save and stay) and
  [`/wb-resume`](wb-resume.html), whose `--continue` mode is what the fresh
  Claude runs.
- To revert: `touch ~/.local/state/wb/disable-continue`, or remove the
  `wb-continue-hook` plugin link from `~/.claude/skills/` and restart Claude.
