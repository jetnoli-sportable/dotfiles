---
title: claude-tmux
status: current
tile: The nvim ⇄ tmux bridge to a live Claude Code pane — read its output, compose a reply, send context.
group: nvim
kind: guide
updated: 2026-07-11
---

## Overview

`claude-tmux` (`nvim/.config/nvim/lua/claude-tmux/`) is a small nvim plugin
that bridges a live Claude Code session running in a tmux pane with nvim
buffers, so you can read Claude's output and compose replies without
leaving the editor or fighting tmux copy-mode. It's entirely local to this
repo — not a published plugin — and every keymap lives under one leader
prefix (default `<leader>a`), registered by `claude-tmux.init`'s
`setup(opts)`.

It was written for the "keep a basic grab/reply loop, hold off on fancy
nvim-bridge features" direction ratified 2026-07-06, and stayed there
deliberately — see `docs/roadmap.md`'s "Keep / retire / hold" section.

## Finding the pane

Every submodule that needs to talk to a live Claude pane goes through
`pane.lua`, which delegates discovery to the shared tmux helper library
(`scripts/.config/scripts/tmux/lib.sh`) so pane-detection logic lives in
one place — the same `pane_current_command == claude` check the `wb`
session picker itself uses:

- `pane.find(cwd)` — resolves the `session:window.pane` target running
  Claude Code in the given cwd (defaults to the current one).
- `pane.paste_text(target, text)` — pastes text into the target's prompt
  via a tmux buffer + bracketed paste, without submitting. Used when you
  want Claude to see context you'll follow up on yourself.
- `pane.send_text(target, text)` — same, then sends `Enter` to submit.

Multi-line text always goes through tmux's paste-buffer mechanism rather
than `send-keys -l` directly — that's what keeps a multi-line reply from
submitting early on an embedded newline.

## Reading Claude's output — `output.lua`

- `:ClaudeGrab` (`<leader>ao`) — grabs Claude's latest message into a
  read-only markdown buffer.
- `:ClaudePick` (`<leader>ap`) — opens a picker over messages from the
  current session (a real Telescope custom picker when available, falling
  back to `vim.ui.select`), reading Claude Code's own session transcripts
  under `~/.claude/projects` to build the list.
- `:ClaudeFollow` (`<leader>af`) — toggles live-follow of Claude's output.
- `:ClaudeYankCode` (`<leader>ay`) — yanks a code block out of the output
  buffer.

This is the picker pattern `queue.lua`'s `<leader>aq` reuses directly for
browsing queued messages (see below), rather than inventing a second picker
mechanism.

## Composing a reply — `reply.lua`

This is the piece most directly adjacent to `/queue`. `reply.lua` gives you
a place to type a reply, then sends the whole thing to the target pane in
one shot:

- `:ClaudeReply` (`<leader>ar`) — opens the reply surface in a split.
- `:ClaudeSend` (`<leader>as`) — sends the current draft to the pane
  (`pane.send_text`) and clears it.

Two modes (`config.reply.mode`), sharing one `send()` core:

- **`"scratch"`** (the default) — an unnamed, unnamed-buffer draft in a
  split. Once you close the split, the draft is gone.
- **`"file"`** — a per-cwd file under `vim.fn.stdpath("state") ..
  "/claude-tmux/reply<slug>.md"` (nvim's own hidden state directory, e.g.
  `~/.local/state/nvim/claude-tmux/`), so the draft survives closing the
  split. The send gate in this mode is literally "is the file non-empty" —
  writing nothing and saving triggers nothing.

Either way, **there is exactly one draft at a time**, and sending happens
immediately when you trigger it — there's no notion of holding several
distinct stashed messages, and no check for whether the target pane is
actually idle before the text lands. `queue.lua` (below) closes both gaps:
a multi-item queue instead of one draft, stored inside the worktree (so
Telescope can find it) instead of nvim's hidden state directory, with
delivery staying manual either way.

## Stashing a follow-up for later — `queue.lua`

A per-worktree scratch queue for thoughts aimed at the pane you're already
watching but don't want to interrupt. Stashing is a pure file append — it
never touches the live pane, so it can't distract or interrupt Claude's
current turn (unlike `reply.lua`'s immediate send).

- `:ClaudeQueueStash` (`<leader>aQ`) — prompts for one line and appends it
  to the current worktree's queue file immediately, no buffer to open or
  close.
- `:ClaudeQueue` (`<leader>aq`) — opens a picker over the current
  worktree's queued items (newest first), reusing `output.lua`'s exact
  Telescope-plus-`vim.ui.select`-fallback shape. Selecting an entry copies
  its text to the unnamed and `+` registers — the v1 floor. In the
  Telescope picker specifically, `<C-s>` on a selection sends it straight
  to the target pane instead (`pane.send_text`) — a stretch addition on
  top of copy, not required to use the feature.

The queue file is `.claude-queue.md` at the worktree root, gitignored, and
whitelisted in `find_files` (see `plugins/config/telescope.lua`'s
`always_include_globs`) so `<leader>sf` finds it like any other file.
Each stash appends a `## <ISO 8601 timestamp>` block; the picker splits on
that exact heading pattern (not a bare `## ` prefix), so pasting a message
that itself contains a markdown heading doesn't fracture into extra
entries.

**Creation is lazy, not eager.** The file doesn't exist until the first
stash in a given worktree. That same first stash also registers the
worktree's repo as ignoring `.claude-queue.md` — via `wb.sh`'s
`wb_ensure_repo_ignore`, appended idempotently to that repo's own
`.git/info/exclude` (never its tracked `.gitignore`, never a machine-wide
git setting). `wb new` registers the same rule eagerly for brand-new
worktrees, but the lazy call from `queue.lua` is the one that matters in
practice: most real stashes land in a worktree that predates this feature,
or predates that repo's most recent `wb new`, and would otherwise never
get registered.

When `wb done` runs on a worktree with a non-empty queue file, it shows up
in the task file's `## Sweep` checklist exactly like any other gitignored
file — no queue-specific teardown code exists or is needed.

## Sending context — `context.lua`

- `:leader ac` sends the current file as context to the pane.
- Visual-mode `<leader>as` sends the current selection as context instead
  of a reply.

## Jumping to references — `jump.lua`

- `<leader>aj` (also bound to `gf` inside the output buffer) jumps to a
  file reference under the cursor in Claude's output — so a path Claude
  printed becomes a real jump target instead of plain text.

## Configuration

`claude-tmux.setup(opts)` deep-merges `opts` over `config.lua`'s defaults.
The knobs that matter most:

```lua
require("claude-tmux").setup({
  prefix = "<leader>a",         -- leader prefix for every keymap here
  output = { split = "vertical", focus = true },
  reply = {
    mode = "scratch",            -- "scratch" | "file"
    split = "horizontal",
    height = 10,
    send = "keymap",             -- "keymap" | "save" (file mode only)
  },
})
```

## Related

- `scripts/.config/scripts/tmux/lib.sh` — shared pane-discovery and the
  pane-status pipeline (`tmux_claude_panes`, `tmux_pane_awaiting_input`)
  that already classifies a Claude pane as needs-input / done / working /
  idle, powering the attention-routing pipeline this plugin's `output.lua`
  builds on. `queue.lua`'s v1 doesn't surface pane status in its picker,
  but this pipeline is what a later iteration would build on to do so.
- `scripts/.config/scripts/tmux/wb.sh` — `wb_ensure_repo_ignore`, the
  idempotent per-repo `.git/info/exclude` registration `queue.lua` calls
  on a worktree's first stash.
- `docs/plans/2026-07-11-003-feat-queue-command-plan.md` — the `/queue`
  plan `queue.lua` and the `always_include_globs` whitelist entry above
  were built from.
