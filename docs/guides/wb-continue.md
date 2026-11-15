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
| The session called it by itself (a build reaching its review) | a code review: `/ce-code-review`, `/compound-engineering:ce-code-review`, `/code-review` | yes, unless you're looking at the pane, then it waits in the ready list |
| The session called it by itself | anything else | no, it waits in the ready list |
| The session declined (you have to act first, e.g. switch the model) | anything | no, it waits in the ready list |
| A session started by a restart, by itself | anything | no, it waits in the ready list |
| A plain `/wb-save` | any or none | no, it's staged for a release |

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

A restart is **refused**, and the save is left untouched, when the save entry
changed, a newer Handoffs entry landed, the branch moved, or the working tree
changed since the save. A refusal or a failed restart shows as a yellow `↻N` in
the status line and as the row's reason in the picker. `/clear` then
`/wb-resume` always works as before.

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
