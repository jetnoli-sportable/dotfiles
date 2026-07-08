---
title: Clipboard copy diagnosis — Claude Code + GNOME Terminal
status: current
tile: Why "copied N characters" doesn't paste, and the fix that always works.
group: personal-workflow
kind: page
updated: 2026-07-08
---

Claude Code sometimes reports "copied N characters to clipboard" and then
nothing actually pastes. Root cause found; it isn't a bug in Claude, tmux, or
this dotfiles config — it's a hard capability gap in one specific terminal.
This page is the source; edit `docs/clipboard-osc52-diagnosis.md`, not the
rendered `.html`.

**Roadmap:** §9f item 4 (`docs/roadmap.md`) · **PR:** [#10](https://github.com/jetnoli-sportable/dotfiles/pull/10)

## The finding

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

## How it was confirmed

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

## Verify it yourself

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

## What this doesn't fix

Nothing changed in Claude Code's behavior, and there's no tmux/Ghostty
setting that makes GNOME Terminal support OSC52 — it's not configurable,
by design. This page exists so the "says copied but doesn't paste" symptom
is recognizable next time instead of getting re-diagnosed from scratch.

## Related

- `docs/roadmap.md` §9f item 4 — the original task this closes out.
- `tmux/.config/tmux/tmux.conf` — `set-clipboard`/`allow-passthrough`
  settings and the copy-mode binds.
- `ghostty/.config/ghostty/config` — `clipboard-write = allow`.
