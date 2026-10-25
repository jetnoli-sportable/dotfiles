---
title: reply-log
status: current
tile: Every Claude turn — your prompt, Claude's reply text, the files and pages it produced — in a markdown file per session, with prefix+v to read it live beside the Claude pane, and a context card (prefix+i, the wb picker preview) saying where each session stands.
group: workflow
kind: guide
updated: 2026-10-25
---

## Overview

Coming back to a Claude session means rebuilding its context: what you
asked, what Claude last said and asked you, which pages or files it made.
The Claude window mixes all of that with thinking and tool output, so
anything older than the last message or two means scrolling, and asking
the agent to summarise only adds more to scroll past.

The reply log keeps a clean copy. After every turn, a Stop hook (the
`reply-log` plugin, `claude/.claude/skills/reply-log/`, hooks only) writes
that turn to `~/.claude/replies/<session-id>.md` (a SessionEnd hook, in the
same plugin, completes a session's last turn when it ends): your full prompt, every
piece of text Claude wrote (not just the last), and the turn's artifacts.
Thinking, tool calls and tool output never appear.
<kbd>prefix</kbd>+<kbd>v</kbd> opens the file in a split beside the
Claude pane and follows new turns as they land. The **context card**
(<kbd>prefix</kbd>+<kbd>i</kbd>, and the wb picker's preview) sums up
where a session stands without opening anything; see "The context card"
below.

A turn in the file looks like this:

```markdown
## 2026-10-25 16:27 · Write the text 'Step one.' then use the Write tool to create…
<!-- turn {"prompt_id":"9d5f19a2-…","session_id":"767e964c-…","ts":"2026-10-25T14:27:30.979Z"} -->
### Prompt
> Write the text 'Step one.' then use the Write tool to create hello.txt …
### Reply
Step one.

#### Done

I created `hello.txt` containing `hi`.
### Artifacts
- wrote: /tmp/…/sbx-work/hello.txt
```

- **Headings nest under the turn.** Claude's own `#`/`##` headings become
  `###`/`####`, so the outline (and render-markdown's heading icons) reads
  as a list of your prompts. Code blocks are never touched.
- **Other kinds of turn are labelled.** A turn started by a finished
  background agent is headed `(background agent finished)` with its
  one-line summary. A message from another Claude session is headed
  `(message from another session)`. A skill invocation reads `/wb-save
  before clear`, not the raw command markup. A prompt you type while
  Claude is still working is added to that turn's Prompt.
- **Interrupted turns stay.** If you press Esc mid-turn, the turn is kept,
  with whatever text Claude had written, and its heading ends
  `(interrupted)` once the next turn finishes. Quitting Claude Code mid-turn
  does the same when the session ends.
- **Artifacts:** claude.ai pages Claude published, and files it wrote or
  edited, including those written by a background agent it launched (listed
  on the turn where that agent finished).

**These files hold your work.** Every prompt and reply, Sportable work
included, ends up here, so the files stay on this machine: under
`~/.claude/replies/` (mode 0700, files 0600), never in this repo, the task
store or the generated docs. Claude Code already keeps the full transcript
in `~/.claude/projects/`, so the reply log adds no new exposure.

## Try it now

The plugin loads once the `claude` package is stowed and Claude Code is
restarted (see "Next steps" below). Then:

1. In any Claude session, send a prompt and let it finish.
2. Press <kbd>prefix</kbd>+<kbd>v</kbd> in the Claude pane. A split opens
   on the right with the session's turns, rendered, scrolled to the latest.
3. Send another prompt. The new turn appears in the split within a second
   or two, without touching it.
4. Press <kbd>prefix</kbd>+<kbd>v</kbd> again, from the Claude pane or the
   view: it closes the view. <kbd>q</kbd> in the view closes it too.

Or read the raw file: `ls -t ~/.claude/replies/ | head -1` is the newest.

To try it **before** going live, without touching your config, load the
plugin into one throwaway session from the worktree:

```sh
REPLY_LOG_BIN=~/code/dotfiles/.worktrees/feat/claude-reply-log/scripts/.config/scripts/tmux \
REPLY_LOG_DIR=/tmp/reply-log-try \
claude --plugin-dir ~/code/dotfiles/.worktrees/feat/claude-reply-log/claude/.claude/skills/reply-log
```

Its turns land in `/tmp/reply-log-try/<session-id>.md`.

## Reference

| Piece | What it is |
|---|---|
| `~/.claude/replies/<session-id>.md` | One reply file per Claude session id. YAML frontmatter on line 1 (`session_id`, `task`, `cwd`, `branch`, `created`), a `#` heading naming the task (or the folder) and the start time, then one `##` turn per prompt. |
| `~/.claude/replies/.<session-id>.cursor` | Where the last turn starts, in the reply file and in the transcript, plus that turn's final reply text for the SessionEnd hook; how the hook re-renders it. Safe to delete: the next turn is then appended after the existing ones. |
| `claude-reply-log.sh hook-stop` | The Stop hook. Reads the hook payload on stdin, always exits 0 and prints nothing. |
| `claude-reply-log.sh hook-session-end` | The SessionEnd hook (`/clear` or exit). Re-renders the last logged turn from the finished transcript; never creates a file. Same guards as the Stop hook. |
| `claude-reply-log.sh chain <file\|session-id>` | Prints the reply files to show for a session, oldest first. |
| `claude-reply-log.sh chain --pane <pane-id>` | The same, for the session live in that tmux pane. |
| `claude-reply-log.sh view [pane-id]` | What <kbd>prefix</kbd>+<kbd>v</kbd> runs. |
| `claude-card.sh <pane\|tmux target\|session-id\|task file>` | The context card. Prints nothing when there is no session or history to show. Width from `FZF_PREVIEW_COLUMNS`, then `COLUMNS`. |
| `~/.cache/claude-status/<session-id>.json` | Model, context %, cost and when they were seen, written by `claude/.claude/statusline.sh` on every refresh (`CLAUDE_STATUS_CACHE_DIR` overrides the directory). |
| `nvim/.config/nvim/lua/claude-tmux/replies.lua` | The viewer: one read-only markdown buffer, rebuilt when any file in the chain changes (checked every second). |
| `~/.claude/replies/.disabled` | Kill switch: while this file exists, the hook writes nothing. |
| `REPLY_LOG_DIR` | Overrides `~/.claude/replies` (tests, a sandbox). |
| `REPLY_LOG_LOCK_WAIT` | Seconds a Stop waits for the session's lock before giving up quietly (default 4; tests). |
| `REPLY_LOG_BIN` | Where the plugin looks for `claude-reply-log.sh` (default `~/.config/scripts/tmux`). |

**How sessions chain across `/clear`.** `/clear` starts a new session id,
so a new reply file. Inside a wb session the hook records the task file in
each reply file's `task:` field, and the view stacks every reply file with
the same `task:`, oldest first, plus any session ids listed in the task
file's `claude_sessions:`. So after `/clear` the new session's turns appear
below the earlier ones under a new `#` heading. Outside wb, `task:` is
empty and the view shows the current session only. After `/clear` the new
session has no file until its first turn finishes; until then an open view
keeps showing what it had (the earlier sessions), and a view opened in a wb
session in that gap still stacks the task's earlier sessions. It switches
over as soon as the first turn lands.

**What is skipped.** Subagent turns (no SubagentStop hook), headless
`claude -p` runs, the wb-capture sweep's own child session, `/clear` and
other local commands, `!` shell commands, and compaction summaries.

## The context card

The card answers "where is this session, and what does it want from me?"
before you switch in. It is the wb picker's preview for every row, and
<kbd>prefix</kbd>+<kbd>i</kbd> shows it in a popup for the Claude pane
you're in (from a <kbd>prefix</kbd>+<kbd>v</kbd> view, for the pane that
view belongs to; <kbd>q</kbd> closes it). It reads only local files and
renders in about 50 ms or less, so the preview keeps up with the cursor.

```text
idle 4m · Opus 5.5 · 34% ctx · $1.25 · as of 1m
task: dotfiles--feat-claude-reply-log

── Recap · 3m ago ─────────────────────────────────────────
You're wiring the parser into the CLI. Next: pick a flag name.

── You asked · 10:30 ──────────────────────────────────────
Now wire it into the CLI and tell me what's left
before that: Set up the widget parser

── Claude replied ─────────────────────────────────────────
The CLI calls the parser
It runs on every invocation now.
…
── Needs you ──────────────────────────────────────────────
- Pick the flag name: `-w` or `-p`?

── Artifacts ──────────────────────────────────────────────
- https://claude.ai/artifact/…
- edited: /work/demo/cli.sh

── Decisions ──────────────────────────────────────────────
- 2026-10-25 — prefix+v becomes a toggle, shipped as its own small PR (Jet)
```

- **State** comes from Claude Code's session registry
  (`~/.claude/sessions/<pid>.json`): `busy`, `running a command` (a Bash
  tool call or a `!` command), `waiting on you`, or `idle`. A session that
  has been busy or running a command for 10 minutes with no transcript
  activity reads `quiet <age>`, since a long tool run and a
  stuck session look the same from outside. An entry counts only while its
  process is alive with the same start time; otherwise the state is
  `state unknown`.
- **Model, context % and cost** come from a small cache the status line
  writes per session (`~/.cache/claude-status/<session-id>.json`), so they
  appear once the session's status line has refreshed after this change
  went live. `as of` says how old they are.
- **Recap** is Claude Code's own: the automatic summary it writes after a
  few unfocused minutes, or the output of `/recap`. It is left out once a
  newer prompt has started, because the exchange below is then newer.
- **Open questions:** the reply's "Needs you" section when it has one. A
  reply laid out as one heading per point, each restating its question in
  italics, shows "no open questions", since those questions are answered.
  Otherwise up to five lines ending in `?` appear as "possibly open".
- **Artifacts** are the last five across the task's reply files, so they
  survive `/clear`. **Decisions** are the last three entries under the task
  file's `## Decisions`: `###` titles, and top-level bullets that start
  with a date.
- **A task with no live Claude session** (the picker's dormant rows) gets a
  `dormant` card built from its newest reply file. A task with no reply
  history, a repo row, a pane with no Claude session, or a live task
  session with no Claude pane gets no card, and
  the picker shows what it showed before: the task file, the pane's
  screen, or `git status`.
- **A live session with no logged turns yet** (started before the reply
  log went live, or the hook skipped it) shows its state lines with the
  pane's screen below them in the picker. Right after `/clear`, a session
  shows the task's newest earlier exchange, marked `from an earlier session
  on this task`.

## Known rough edges

- **The last reply arrives a turn late in the transcript.** When the Stop
  hook runs, Claude Code usually hasn't yet written the turn to its
  transcript, so the final text comes from the hook payload and earlier
  text blocks of the same turn may be missing. They are filled in when the
  next turn finishes, so a text block written between tool calls can show
  up one turn late. A session's final turn has no next turn: the SessionEnd
  hook completes it when the session ends (`/clear` or exit), by which
  point the transcript is whole. If the session is killed before the
  transcript catches up, the hook keeps the final text the last Stop saved.
- **The first turn of a session already in progress.** A session that was
  running before the plugin loaded (or one resumed with `claude --resume`)
  starts its file at the next turn. Older turns are not backfilled.
- **Batched prompts.** When several messages arrive at once and get one
  answer (two background agents finishing together, say), they become one
  turn, listing each message under Prompt.
- **Nothing is ever deleted.** Files accumulate in `~/.claude/replies/`.
  They are small (a long session is tens of KB); prune by hand if it ever
  matters.

## Next steps / reverting

**Going live** (after the PR merges):

1. Fast-forward the main checkout (`~/.config/nvim` links the whole nvim
   directory, so the viewer module is live from here), then re-stow the two
   packages that gain new files: `stow -t "$HOME" scripts` for
   `claude-reply-log.sh` and `stow --no-folding -t "$HOME" claude` for the
   plugin.
2. Reload tmux (`prefix`+`r`, or `tmux source-file ~/.config/tmux/tmux.conf`)
   for <kbd>prefix</kbd>+<kbd>v</kbd> and <kbd>prefix</kbd>+<kbd>i</kbd>.
   The picker's card preview and the status-line cache need nothing more
   than the fast-forward.
3. Restart Claude Code sessions: hooks load at session start.

**Turning it off:** `touch ~/.claude/replies/.disabled` stops all writing
at once (remove the file to resume). To remove it entirely, unstow the
plugin directory (`~/.claude/skills/reply-log`) and restart Claude Code.
The reply files stay until you delete them.

**Turning the card off:** `prefix`+`i` is a plain tmux binding; the
picker falls back to its old preview whenever `claude-card.sh` prints
nothing or is missing.
