---
title: Status bar marks
status: current
tile: What ✳ ✔ ✎ ⚑ on the tmux status bar mean, when each appears, and what clears it.
group: workflow
kind: page
updated: 2026-10-25
---

## Overview

The tmux status bar carries four small marks about Claude sessions. Each one
means something is waiting for you. Each mark appears only while that is true,
so an empty bar means nothing needs you. A number after a mark is a count. The
bar redraws every 5 seconds.

```
 ✳4 ✔1   1 nvim  2 agent  3 shell                 ⚑1 ✎2   agent   dotfiles--verify-behaviour
 └─ left: agents waiting on you                     └─ right: checks and drafts waiting on you
```

## The four marks

| Mark | Where | Colour | Means | Clears when |
|---|---|---|---|---|
| **✳N** | left | magenta | N Claude panes **need you**: a permission prompt, a question, or idle waiting for input | you focus that pane |
| **✔N** | left | cyan | N Claude panes **finished a long turn** (30 s or more) that you haven't looked at yet | you focus that pane |
| **⚑N** | right, leftmost | red | N live checks the [behaviour watcher](verify-behaviour.html) found **broken**, or **proposed** as met and waiting for your yes or no | you next type anything to the watcher |
| **✎N** | right, after ⚑ | peach | N **shelved decision drafts** for this session's task, written by the background capture sweep and waiting for your review | you review them: `/wb-decide shelved`, or the review inside `/wb-save`, `/close-out` and `wb done` |

### ✳ and ✔: agents waiting on you

Claude Code's hooks mark the pane. `claude-notify-hook.sh` sets the pane option
`@claude_blocked` to `needs-input` when Claude needs you, or to `done` when a
turn of 30 seconds or more ends. Shorter turns light nothing, so quick replies
don't nag. Focusing the pane clears the mark (a `pane-focus-in` hook): reaching
the agent counts as seeing it.

The count covers every pane in every tmux session, not just the one you're in.
Use the wb picker (`prefix` + `a`) or `wb board` to find which ones.

### ⚑: the behaviour watcher wants you

The verify-behaviour watcher is a standing Claude session that checks shipped
features in real use. When it records a check as **broken**, or proposes one as
met and needs your yes, its script adds one to the global tmux option
`@verify_alert`. The mark shows in every session's bar, so a misfire reaches
you wherever you're working. Go to the watcher's pane
(`dotfiles--verify-behaviour-watcher`) and read its latest reply. Typing
anything there clears the flag.

### ✎: decision drafts to review

The capture sweep reads a wb session's conversation in the background and
drafts decisions that weren't recorded. It never puts them in front of the
agent. Each draft waits on its task's shelf. The count is per session: a
session shows only its own task's drafts, and a session with no task shows
nothing.

## Reference

| Mark | Set by | Read by | Configured at |
|---|---|---|---|
| ✳ ✔ | `claude-notify-hook.sh` (pane option `@claude_blocked`) | `claude-status.sh` | `tmux.conf`, `status-left` |
| ⚑ | `verify-wait.sh record` / `seen` (global option `@verify_alert`) | tmux format `#{@verify_alert}` | `tmux.conf`, prepended to `status-right` |
| ✎ | the capture sweep (`wb-capture.sh`, shelf files) | `capture-status.sh "#{@task}"` | `tmux.conf`, prepended to `status-right` |

The theme (catppuccin) owns the rest of the right side: the window name, then
the session name. The block before the session name turns red while the tmux
prefix key is active.

Check a mark by hand:

```
tmux show -gv @verify_alert                                        # ⚑ count, empty when clear
~/.config/scripts/tmux/wb-capture.sh shelved --count --task <stem> # ✎ count for a task
tmux list-panes -a -F '#{session_name} #{@claude_blocked}' | grep -v ' $'   # which panes light ✳ ✔
```

## Known rough edges

- **✳ and ✔ don't say which session.** The count is global; the picker or
  `wb board` tells you where.
- **⚑ resets on a tmux restart.** The count lives in a tmux option, so a server
  restart clears it. The watcher's verdicts are kept in each feature's
  `verdicts.md`, and its next reply lists anything still open.
- **✎ only shows in a session with a task.** Drafts for a task whose session is
  closed show on the weekly review and in `wb-capture.sh shelved --all`.

## Turning a mark off

Each mark is one block in `~/.config/tmux/tmux.conf`. Remove `status-left` for
✳ and ✔, or the `run-shell` line that prepends ⚑ or ✎, then reload tmux
(`prefix` + `r`).
