---
title: 9f recap — editor/tmux ergonomics batch
status: current
tile: Six small nvim/tmux items shipped in one PR. What to verify yourself.
group: recaps
kind: page
updated: 2026-07-08
---

Six small, independent nvim/tmux/Claude-Code workflow items from roadmap §9f,
all shipped in one PR. This page is the source; edit
`docs/9f-ergonomics-recap.md`, not the rendered `.html`.

**Roadmap:** 9f (superseded — this page is the detail) · **PR:** [#10](https://github.com/jetnoli-sportable/dotfiles/pull/10) · **Branch:** `feat/editor-tmux-ergonomics` → `development`

## What we added

| # | Item | What it does | Where |
|---|---|---|---|
| 1 | Oil → new tmux window | `<Leader>I` opens the entry under the cursor in a **new tmux window** (mirrors `<Leader>o`'s split-window version) | `nvim/.../plugins/config/oil.lua` |
| 2 | Reopen vim where you left off | **persistence.nvim**, cwd-scoped — auto-restores on a bare `nvim`/`nvim .` launch; manual `<leader>ps`/`pl`/`pd` | `nvim/.../plugins/config/persistence.lua` |
| 3 | Search changed files | `<leader>sc` → telescope's `builtin.git_status`, a fuzzy changed-files list (gitsigns/diffview didn't cover this) | `nvim/.../plugins/config/telescope.lua` |
| 4 | Claude Code clipboard reliability | **Diagnosed, not a code fix** — see [item 4 deep dive](#item-4-deep-dive-claude-code-clipboard-reliability) | merged in below |
| 5 | Quick-ask shortcut | `prefix+q` opens a scratch Claude Code window (`ask.sh`) — corrected from the roadmap's original `prefix+A` pick, which turned out to already be bound to lazydocker | `scripts/.../tmux/ask.sh`, `tmux.conf` |
| 6 | VSCode-style diff plugin | **codediff.nvim** (owner pick, `<leader>vi`/`<leader>vI`) — full explorer/history/conflict-resolution UI with two-tier line+character highlighting, side-by-side or inline. See [item 6: codediff.nvim vs diffview.nvim](#item-6-codediffnvim-vs-diffviewnvim) for how it compares to the diff tool already installed | `nvim/.../plugins/config/codediff.lua` |

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
- [ ] **codediff.nvim:** make an uncommitted change to a tracked file,
      open it in nvim, press `<leader>vi` — confirm a new tab opens with
      the diff explorer (first run downloads a small C library, needs
      network once). See [item 6](#item-6-codediffnvim-vs-diffviewnvim)
      for commands to compare it against diffview.nvim.
- [ ] **Clipboard:** see [clipboard verification steps](#clipboard-verification-steps) below.
- [ ] **Regenerate and confirm it's a no-op**: run `docgen.sh` from the repo
      root and check `git status` shows nothing changed.
- [ ] **Skim the PR** ([#10](https://github.com/jetnoli-sportable/dotfiles/pull/10))
      for anything that looks off before merging to `development`.

## Item 4 deep dive: Claude Code clipboard reliability

Claude Code sometimes reports "copied N characters to clipboard" and then
nothing actually pastes. Root cause found; it isn't a bug in Claude, tmux, or
this dotfiles config — it's a hard capability gap in one specific terminal.

### The finding

Claude Code's clipboard shortcut writes via **OSC 52**, a terminal escape
sequence that asks whichever terminal is attached to set the system
clipboard directly — no shelling out to `wl-copy`/`xclip` involved. The
write call itself doesn't error, so Claude reports success honestly. Whether
anything actually lands in the clipboard depends entirely on the terminal
receiving that sequence.

**GNOME Terminal (VTE) still does not implement OSC 52 at all, as of 2026** —
a deliberate upstream decision (letting a remote program silently write your
clipboard is a real security concern) — so it just drops the sequence.
**Ghostty does implement it** (`clipboard-write = allow` is already set in
this repo's `ghostty/.config/ghostty/config`).

A first hypothesis — that `allow-passthrough` in `tmux.conf` was colliding
with Claude's OSC52 emission — was checked and ruled out along the way:
`allow-passthrough` only governs a *different* mechanism (DCS-wrapped
passthrough, used by things like terminal image protocols). The setting
that actually matters for raw OSC52 is `set-clipboard`, which was already
`on`. The stale comment conflating the two has been corrected in
`tmux.conf`.

### How it was confirmed

1. `wl-copy`/`wl-paste` tested standalone (outside tmux and Claude
   entirely) — worked fine, ruling out a broken Wayland clipboard.
2. tmux's live settings checked directly (`tmux show-options -g
   allow-passthrough` / `set-clipboard`) — both already correctly set.
3. A raw OSC52 sequence sent directly to a real terminal pane, bypassing
   Claude entirely:
   ```bash
   wl-copy < /dev/null   # clear it first
   printf '\033]52;c;%s\007' "$(printf 'osc52-relay-test' | base64 -w0)"
   wl-paste              # prints nothing => OSC52 isn't reaching the clipboard
   ```
   This printed nothing in the GNOME Terminal pane where the bug was first
   reported — confirming the break was in the terminal itself, not in
   Claude, tmux, or Wayland.

### Clipboard verification steps

- [ ] **Run the three-line test above** in a GNOME Terminal pane — confirm
      `wl-paste` prints nothing after the OSC52 write.
- [ ] **Run the same three lines in a Ghostty pane** — confirm `wl-paste`
      *does* print `osc52-relay-test` this time, isolating the terminal as
      the variable.
- [ ] **Try tmux's own copy-mode** next time you need to copy something out
      of a GNOME Terminal pane: <kbd>prefix</kbd> <kbd>[</kbd> to enter
      copy-mode, move/select, <kbd>Enter</kbd> to copy — bound to `wl-copy`
      directly in `tmux.conf`, so it works regardless of OSC52 support.
- [ ] **If you want Claude's own "copied N characters" shortcut to just
      work**, do that specific work in a Ghostty pane instead of GNOME
      Terminal.

### What this doesn't fix

Nothing changed in Claude Code's behavior, and there's no tmux/Ghostty
setting that makes GNOME Terminal support OSC52 — it's not configurable,
by design. This section exists so the "says copied but doesn't paste"
symptom is recognizable next time instead of getting re-diagnosed from
scratch.

## Item 6: codediff.nvim vs diffview.nvim

Two diff tools now live side by side on the `<leader>v*` prefix:
**diffview.nvim** (already installed, owns `<leader>vo`/`vc`/`vh`/`vf`) and
**codediff.nvim** (new, `<leader>vi`/`vI`). They overlap in scope more than
9f-6 originally assumed — codediff.nvim isn't a lightweight inline-only
tool, it's a full explorer/history/conflict-resolution UI comparable in
size to diffview.nvim. Worth actually comparing before deciding whether to
keep both, or drop one. Try these side by side on the same repo:

| What to check | diffview.nvim | codediff.nvim |
|---|---|---|
| Working tree vs HEAD, all changed files | `<leader>vo` (`:DiffviewOpen`) | `<leader>vi` (`:CodeDiff --inline`) or bare `:CodeDiff` for side-by-side |
| Just the current file vs HEAD | `:DiffviewOpen %` | `<leader>vI` (`:CodeDiff file HEAD --inline`) |
| Per-file commit history | `<leader>vh` / `<leader>vf` (current file) | `:CodeDiff history HEAD~20 %` |
| Toggle side-by-side ⇄ inline live | not built in — separate commands | press `t` inside any codediff view |
| Character-level (not just line-level) highlighting | no | yes — this is codediff's headline feature |
| "PR diff" — only what *my* branch introduced | needs a manual `:DiffviewOpen main...HEAD` range | `:CodeDiff main...HEAD` (merge-base aware, same semantics as `git diff main...HEAD`) |
| Merge-conflict resolution UI | no (falls back to vim's native `do`/`dp`) | yes — `<leader>ct`/`co`/`cb`/`cx` accept-incoming/current/both/discard, per-hunk or whole-file |
| First-run cost | none, pure Lua | downloads a small prebuilt C library once (~few MB, needs network) |

If codediff.nvim's PR-diff mode and conflict UI earn their keep, diffview.nvim
becomes redundant and could come out later. If the extra weight (C library,
bigger keymap surface) isn't worth it for how often you actually use
per-file history, keep diffview.nvim and drop codediff.nvim instead — no
need to decide today, this section is here so the comparison is easy
whenever you do.

## Next steps

- **Merge PR #10** once you've walked the checklist above.
- **§9g — GPaste clipboard-history manager** is next in the backlog, now
  non-blocking (reclassified from a hard gate during the 2026-07-07 doc
  review) — configure gsettings/dconf, shortcut `<Ctrl><Shift>G`.
- **Standing pattern going forward:** one of these recap pages per PR while
  this batch of follow-up work (9f/9g and beyond) is in flight, not just at
  the end of a slice — owner ask, 2026-07-08.
