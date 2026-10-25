# gnome — keyboard tiling on stock GNOME

An i3/AeroSpace-style workflow on Ubuntu's GNOME session (Wayland), without
switching compositor: one key per app, keyboard tiling, and seven workspaces.
Why GNOME and not Sway, and every key choice, are in
[`docs/plans/2026-06-21-001-feat-gnome-tiling-trifecta-plan.md`](../docs/plans/2026-06-21-001-feat-gnome-tiling-trifecta-plan.md).

## Keys

| Keys | Action |
|---|---|
| `Super+<letter>` | Jump to that app (switching workspace if needed) or start it. Letters live in `run-or-raise/.config/run-or-raise/shortcuts.conf` |
| `Super+h/j/k/l` | Focus the tile left/down/up/right (Forge) |
| `Super+Shift+h/j/k/l` | Move the window that way (Forge) |
| `Super+Ctrl+h/j/k/l` | Swap with the neighbour (Forge) |
| `Super+A/S/D/F/1/2/3` | Switch to workspace 1–7, both monitors together |
| `Super+Shift+A/S/D/F/1/2/3` | Send the window to workspace 1–7 |
| `Super+Alt+<letter>` | Forge layout extras: float `C`, split toggle `G`, stacked `S`, tabbed `T`, … |
| `Super+Ctrl+Shift+L` | Lock screen |

`ctrl+h/j/k/l` is left alone for tmux/nvim (vim-tmux-navigator).

## What's here

- `install.sh` installs Forge and Run or Raise at pinned versions, disables
  Ubuntu's Tiling Assistant, runs `settings.sh`, then `check-keys.sh --live`.
  The root `install.sh` calls it after stowing `run-or-raise`.
- `settings.sh` is every GNOME, Ubuntu Dock, GPaste and Forge setting this
  setup owns, as `gsettings` lines. GNOME settings live in a database, not
  files, so they can't be stowed; `gsettings` (unlike `dconf load`) rejects a
  misspelt key, so a typo fails the install instead of being ignored.
- `check-keys.sh` fails if any key is bound twice, across GNOME, the dock,
  GPaste, Forge and `shortcuts.conf`. A double-bound Run or Raise key can crash
  GNOME Shell, which on Wayland ends the session. The pre-commit hook runs
  `--repo` (a throwaway settings database, starting from GNOME's defaults)
  when `gnome/` or `run-or-raise/` changes; `--live` checks the running session.
- `tests/` covers `check-keys.sh`: `bash gnome/tests/check-keys.test.sh`.

## Notes

- **One log-out.** On Wayland a newly installed extension can't be enabled until
  you log out and back in. `install.sh` says so; run it again after logging in.
- **After editing `shortcuts.conf`:**
  `gnome-extensions disable run-or-raise@edvard.cz && gnome-extensions enable run-or-raise@edvard.cz`.
  Find an app's window class with Looking Glass (`Alt+F2`, `lg`, Windows tab).
- **After a GNOME upgrade:** run `gnome/check-keys.sh --live` (an upgrade can add
  default keys the commit hook never saw), and re-pin the extension version tags
  in `install.sh` from `https://extensions.gnome.org/extension-info/?uuid=<uuid>&shell_version=<N>`.
  Forge has no maintainer; if it breaks, the fallback is Pop Shell, installed
  without its `configure.sh` (which rewrites GNOME shortcuts).
- **Pre-commit needs Forge's schema.** `check-keys.sh --repo` reads it from the
  installed extension, so commits touching `gnome/` or `run-or-raise/` fail on a
  machine without Forge installed (set `FORGE_SCHEMA_DIR` to a copy to override).
