# Testing the Claude ⇄ nvim/tmux bridge

The `lua/claude-tmux/` module turns Claude Code's output (read from its session
transcript JSONL) into a navigable nvim markdown buffer, and lets you reply /
send context back to Claude's tmux pane. This is how to exercise it.

## Prerequisites

- nvim and Claude Code running in **separate tmux panes** of the same project
  (same cwd). The bridge finds the Claude pane by matching `pane_current_path`
  to nvim's cwd.
- The shared helper `tmux_find_claude_pane` must exist in
  `~/.config/scripts/tmux/lib.sh` (added alongside this feature). Sanity check:

  ```sh
  bash -c 'source ~/.config/scripts/tmux/lib.sh; tmux_find_claude_pane "$(pwd)"'
  ```

  Run that from the project dir while a Claude pane is open there — it should
  print a `session:window.pane` target (e.g. `18:1.1`).
- Reload nvim after pulling these changes (`:source $MYVIMRC` is not enough for
  a new module — restart nvim).

## Keymaps (all under `<leader>a`, the "[A]gent" group)

| Key          | Command          | What it does |
|--------------|------------------|--------------|
| `<leader>ao` | `:ClaudeGrab`    | Grab Claude's **latest** message into a read-only markdown buffer |
| `<leader>ap` | `:ClaudePick`    | Telescope picker over **every** assistant message in the session |
| `<leader>af` | `:ClaudeFollow`  | Toggle **live-follow** — buffer auto-refreshes as Claude responds |
| `<leader>ay` | `:ClaudeYankCode`| Pick a fenced code block from the output buffer and yank it clean |
| `<leader>ar` | `:ClaudeReply`   | Open the **reply** buffer (type your answer here) |
| `<leader>as` | `:ClaudeSend`    | Normal: send the reply. Visual: send the selection as context |
| `<leader>ac` | —                | Send the current file to Claude as an `@path` reference |
| `<leader>aj` / `gf` | —         | Jump to a `file:line` reference under the cursor (`gf` works inside the output buffer) |

## Test checklist

### 1. Read the latest message
1. In the Claude pane, ask Claude something that produces a multi-paragraph
   reply with at least one code block.
2. In nvim: `<leader>ao`. A split should open showing the response rendered as
   markdown (render-markdown.nvim styling), read-only, cursor at the top.
3. Confirm headings/lists/code fences render, and you can fold/search normally.

### 2. Browse the session
1. `<leader>ap` → a Telescope picker lists prior assistant messages (newest
   first) with a live markdown preview.
2. Select one → it opens in the output buffer.
3. (No Telescope? It falls back to `vim.ui.select`.)

### 3. Yank a code block
1. With a message containing code in the output buffer, `<leader>ay`.
2. One block → yanked immediately. Multiple → pick from `vim.ui.select`.
3. Paste elsewhere (`p`) — the code should be clean, no terminal wrapping.

### 4. Live-follow
1. `<leader>af` → notice "live-follow on". The buffer seeds with the latest
   message.
2. In the Claude pane, send another prompt and let it answer.
3. Within ~1s the output buffer updates to the new message **without** moving
   your cursor or stealing window focus.
4. `<leader>af` again → "live-follow off".

### 5. Reply (write-back) — the core loop
1. `<leader>ar` → reply buffer opens in a split, insert mode.
2. Type a reply (try **multiple lines** to confirm they don't submit early).
3. `<leader>as` → text appears in Claude's pane prompt and is submitted; the
   reply buffer clears; you see "sent to <target>".
4. **Empty-draft gate:** open the reply buffer, leave it blank, `<leader>as` →
   "nothing to send (reply is empty)", and nothing is sent to Claude.

### 6. Send context
1. Normal mode in any file: `<leader>ac` → `@<relative-path>` is pasted into
   Claude's prompt **without** submitting, so you can add a question and send it
   yourself.
2. Visual mode: select lines, `<leader>as` → a fenced snippet tagged
   `path:start-end` is pasted into the prompt (not submitted).

### 7. Jump to a file reference
1. In the output buffer, put the cursor on a `file:line` reference Claude wrote
   (e.g. `lua/plugins/index.lua:42`).
2. `gf` (or `<leader>aj`) → opens that file at that line in your editing window.

## Reply modes (A/B test)

Default is **scratch** mode (draft lost when the split closes). To try the
**file-backed** mode (draft persists on disk, optional send-on-save), set in
`lua/core/index.lua`:

```lua
require("claude-tmux").setup({
  reply = { mode = "file", send = "save" }, -- "save" sends on :w; omit for keymap-only
})
```

- `scratch`: send gate is "buffer has non-blank lines".
- `file`: draft lives at `stdpath("state")/claude-tmux/reply<slug>.md`, survives
  closing the buffer; with `send = "save"`, writing the file sends it.

## Troubleshooting

- **"no Claude pane running in …"** — no Claude pane has `pane_current_path`
  equal to nvim's cwd. Confirm both panes are in the same project dir, and that
  the `tmux_find_claude_pane` sanity check above prints a target.
- **"no Claude session transcript found"** — Claude hasn't written a transcript
  for this cwd yet (start a conversation), or the cwd→slug mapping differs.
- **"not inside tmux"** — nvim isn't running under tmux (`$TMUX` unset).
- **Nothing pastes into Claude** — bracketed paste relies on tmux
  `allow-passthrough on` (already set in `~/.config/tmux/tmux.conf`).

## Headless self-tests

Pure logic (parser, code-block extraction, jump parsing) is covered by:

```sh
nvim -l /tmp/claude_tmux_test.lua   # transcript parser + live resolution
nvim -l /tmp/claude_tmux_test2.lua  # jump.parse + empty-reply gate
```

(These live in `/tmp`; move them into the repo if you want them permanent.)

---

## Addendum — what shipped and how it was committed

This feature landed on `fix/config-bugs-and-cleanup` as three stacked commits:

| Commit    | Contents |
|-----------|----------|
| `7cc95a0` | **Initial branch work** — nvim-dap setup, delve, `[D]ebug` which-key group, indexing-aware LSP pickers, README/docs, lazy-lock |
| `4050e38` | **Claude ⇄ nvim/tmux bridge** — `lua/claude-tmux/` (8 modules) + this `instructions.md` + wiring |
| `1b7734f` | **diffview.nvim** — config, `[V]iew/Diff` group, lock entry |

The `whichkey.lua` group lines were split across commits: `[D]ebug` in commit 1,
`[A]gent` in commit 2, `[V]iew/Diff` in commit 3.

### Two things to know

1. **`~/.config/scripts/lib.sh` is not version-controlled.** `~/.config/scripts`
   is not a git repo, so the `tmux_find_claude_pane` helper the bridge depends on
   lives only on disk — not backed up anywhere. Worth folding `~/.config/scripts`
   into a dotfiles repo at some point.

2. **The large `lazy-lock.json` diff in commit 3 is a stale-lock resync, not a
   plugin change.** `Lazy! install` (run to fetch diffview) rewrote the lock to
   match the plugin commits already checked out on disk. The committed lock was
   behind on ~30 plugins; **no plugin versions changed on disk** — the lock just
   now reflects reality. Verified: on-disk HEADs (telescope `7d32479`, mini
   `232ceeb`, treesitter `cf12346`) already matched the new lock values.

### diffview.nvim keymaps

Given a separate `[V]iew/Diff` group (because `<leader>g` = "[G]o" and
`<leader>h` = git hunks were taken):

| Key          | Action |
|--------------|--------|
| `<leader>vo` | Open (working tree vs HEAD) |
| `<leader>vc` | Close |
| `<leader>vh` | Repo file history |
| `<leader>vf` | Current file history |

Rebind in `lua/plugins/config/diffview.lua` if you'd prefer a different prefix.
