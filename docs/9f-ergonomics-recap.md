---
title: 9f recap — editor/tmux ergonomics batch
status: current
tile: Six small nvim/tmux items shipped in one PR. What to verify yourself.
group: personal-workflow
kind: page
updated: 2026-07-08
---

Six small, independent nvim/tmux/Claude-Code workflow items from roadmap §9f,
all shipped in one PR. This page is the source; edit
`docs/9f-ergonomics-recap.md`, not the rendered `.html`.

**Roadmap:** §9f (`docs/roadmap.md`) · **PR:** [#10](https://github.com/jetnoli-sportable/dotfiles/pull/10) · **Branch:** `feat/editor-tmux-ergonomics` → `development`

## What we added

| # | Item | What it does | Where |
|---|---|---|---|
| 1 | Oil → new tmux window | `<Leader>I` opens the entry under the cursor in a **new tmux window** (mirrors `<Leader>o`'s split-window version) | `nvim/.../plugins/config/oil.lua` |
| 2 | Reopen vim where you left off | **persistence.nvim**, cwd-scoped — auto-restores on a bare `nvim`/`nvim .` launch; manual `<leader>ps`/`pl`/`pd` | `nvim/.../plugins/config/persistence.lua` |
| 3 | Search changed files | `<leader>sc` → telescope's `builtin.git_status`, a fuzzy changed-files list (gitsigns/diffview didn't cover this) | `nvim/.../plugins/config/telescope.lua` |
| 4 | Claude Code clipboard reliability | **Diagnosed, not a code fix** — root cause is GNOME Terminal lacking OSC52 support. Full writeup: [clipboard diagnosis](clipboard-osc52-diagnosis.html) | `docs/clipboard-osc52-diagnosis.md` |
| 5 | Quick-ask shortcut | `prefix+q` opens a scratch Claude Code window (`ask.sh`) — corrected from the roadmap's original `prefix+A` pick, which turned out to already be bound to lazydocker | `scripts/.../tmux/ask.sh`, `tmux.conf` |
| 6 | Inline diff plugin trial | **inline-diff.nvim** on `<leader>vi` — word-level diff rendered in-buffer, no separate tabpage. Substituted for the roadmap's ambiguously-named "vscode-diff.nvim" (see commit `1b0a8d4` for why) | `nvim/.../plugins/config/inline-diff.lua` |

## Test / verify it yourself

- [ ] **Reload tmux** (`prefix r`), then try `prefix+q` — confirm it opens a
      new window named `ask` with Claude Code starting in it, in your
      current session.
- [ ] **Oil:** open oil (`-`), navigate to a file, press `<Leader>I` —
      confirm it opens a **new tmux window** (not a split) with that file
      in nvim.
- [ ] **Telescope:** press `<leader>sc` in a dirty git repo — confirm it
      shows a fuzzy-searchable list of changed files, not something else.
- [ ] **Persistence:** edit a file in some directory, quit nvim
      (`:wa | :qa`), then run `nvim .` (or bare `nvim`) in that same
      directory — confirm your buffers come back. Try `<leader>pd` to stop
      saving a session you don't want remembered.
- [ ] **Inline diff:** make an uncommitted change to a tracked file, open
      it in nvim, press `<leader>vi` — confirm word-level highlighting
      appears in the buffer itself (no new window/tabpage).
- [ ] **Clipboard:** see the [dedicated verification checklist](clipboard-osc52-diagnosis.html#verify-it-yourself) —
      it's its own page since the diagnosis has real content worth keeping
      separately findable.
- [ ] **Regenerate and confirm it's a no-op**: run `docgen.sh` from the repo
      root and check `git status` shows nothing changed.
- [ ] **Skim the PR** ([#10](https://github.com/jetnoli-sportable/dotfiles/pull/10))
      for anything that looks off before merging to `development`.

## Next steps

- **Merge PR #10** once you've walked the checklist above.
- **§9g — GPaste clipboard-history manager** is next in the backlog, now
  non-blocking (reclassified from a hard gate during the 2026-07-07 doc
  review) — configure gsettings/dconf, shortcut `<Ctrl><Shift>G`.
- **Standing pattern going forward:** one of these recap pages per PR while
  this batch of follow-up work (9f/9g and beyond) is in flight, not just at
  the end of a slice — owner ask, 2026-07-08.
