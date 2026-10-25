---
title: "feat: GNOME tiling trifecta (Run or Raise app keys + Forge tiling + 7 letter/number workspaces)"
status: active
date: 2026-06-21
revised: 2026-10-25
type: feat
origin: logs/decisions/2026-06-18-window-manager.md
---

# feat: GNOME tiling trifecta (Run or Raise app keys + Forge tiling + 7 workspaces)

## Summary

Bring the **basic i3/AeroSpace workflow** to the existing Ubuntu 24.04 / Wayland / GNOME 46 session **without switching to Sway**: one letter key per app that jumps to it or starts it (the **Run or Raise** extension), keyboard tiling (the **Forge** extension), and seven fixed workspaces reached and filled by keyboard. All of it lives in the dotfiles repo: a `gnome/` folder holding a `gsettings` script and an install script, a `run-or-raise/` stow package holding the app-key file, and a key-conflict check that runs on every commit and every install. Everything binds to `Super`; `ctrl+hjkl` stays with `vim-tmux-navigator`.

This revision (2026-10-25) replaces the June draft's choices with the ones made on the comparison page (`~/code/tasks/dossiers/dotfiles--gnome-tiling-wm-migration/gnome-tiling-choices.html`) and in chat that day. The June draft used the dock-order `Super+1..9` keys for apps, four workspaces and dconf fragment files; all three changed (see Key Technical Decisions).

---

## Problem Frame

GNOME manages whole apps mostly by mouse and ships no i3-style keyboard tiling. The goal is the AeroSpace muscle memory from macOS: a fixed key per app, tiles moved by keyboard, windows thrown to named workspaces. Sway was assessed as overkill (a full shell rebuild, and GNOME already handles the hybrid Intel+NVIDIA GPU and the Wayland clipboard; see `origin`). GNOME plus two extensions covers the trifecta and keeps the session intact.

GNOME settings are not files; they live in the **dconf** settings database. So most of this config is a script that writes settings, not a stow symlink. The one exception is Run or Raise, whose config is a plain text file and stows like every other package.

**What the machine looks like today (checked live 2026-10-25):** Ubuntu 24.04.3, GNOME Shell 46.0, Wayland, two landscape monitors (laptop `eDP-1` primary, `HDMI-1`). Ubuntu's Tiling Assistant extension is enabled and owns `Super+arrows`. Neither Forge nor Run or Raise is installed. Several of the keys this plan uses already have GNOME meanings (`Super+A` app grid, `Super+S` quick settings, `Super+D` show desktop, `Super+H` minimise, `Super+L` lock, `Super+1..9` dock apps); the plan moves or clears each one.

---

## Requirements

- **R1. App keys.** One `Super+letter` per app: focus it if running (cycling its windows on repeat presses), start it if not. If the app's window is on another workspace, jump to that workspace (Run or Raise's default behaviour; no `:move-window-to-active-workspace`).
- **R2. Keyboard tiling.** Focus and move tiles directionally with `Super+hjkl` / `Super+Shift+hjkl`.
- **R3. Workspaces.** Seven fixed workspaces. `Super+A/S/D/F/1/2/3` switch to workspaces 1–7; add `Shift` to send the focused window there. Switching changes both monitors together.
- **R4. Super only.** Every binding uses `Super`. Nothing binds `ctrl+h/j/k/l` (owned by vim-tmux-navigator, `tmux/.config/tmux/tmux.conf`).
- **R5. No key is ever bound twice.** A key bound by both Run or Raise and GNOME (or Forge) can crash GNOME Shell, which on Wayland ends the whole session. A check enforces this on every commit that touches the config and on every install.
- **R6. Reproducible.** `install.sh` applies the whole setup on a fresh machine; re-running it is safe.
- **R7 (documented limitation).** Per-monitor workspace sets (the AeroSpace model) are not possible on GNOME. See Scope Boundaries.

---

## Key Technical Decisions

Decided 2026-10-25 (comparison page + chat; the tiler and storage choices were each checked with `/ce-pov`):

- **App keys: Run or Raise, replacing the dock-order number keys.** Run or Raise (`run-or-raise@edvard.cz`, extensions.gnome.org version 49, GNOME 45–51) reads `~/.config/run-or-raise/shortcuts.conf`, one line per key: `<key>,<command or .desktop name>,<window class>,<title>`. It focuses the window itself, which gets around GNOME's focus-stealing prevention on Wayland. GNOME's `switch-to-application-1..9` (`Super+1..9` by dock order) are cleared: letters replace them and `Super+1..3` become workspaces. *Rejected:* the built-in number keys alone (nine apps max, order tied to the dock); walker (on GNOME it runs only as an ordinary window, can't focus open windows, and needs a Rust + Go source build). Walker is deferred, reversing the 2026-07-06 pick; it revives only if the parked compositor switch does.
- **Tiler: Forge** (`forge@jmmaranan.com`, GNOME 45–51, on extensions.gnome.org). It has no maintainer, so the plan names a fallback. *Rejected:* **Pop Shell**, which is better maintained (GNOME 50 support landed March 2026) but is a Node/TypeScript source build, moves tiles through an "adjust mode" rather than `Super+Shift+hjkl`, and its `make local-install` runs `scripts/configure.sh`, which rewrites GNOME shortcuts on its own (`Super+F` home folder, `Super+E/B/T` launchers, `Super+Q` close). That last point works directly against R5. Pop Shell stays the fallback, installed without `configure.sh`, if a GNOME upgrade breaks Forge.
- **Workspaces: 7 fixed** (`dynamic-workspaces=false`, `num-workspaces=7`), keys `A S D F 1 2 3`. Forge requires a fixed count anyway. GNOME workspaces have numbers only; the letter is just the key bound to workspace N.
- **Both monitors switch together** (`workspaces-only-on-primary=false`), so every window belongs to a workspace and can be sent anywhere.
- **Storage: a `gsettings` script, not dconf fragments.** Tested 2026-10-25 in an isolated settings database: `dconf load` accepts a misspelt key silently (exit 0), while `gsettings set` rejects an unknown key ("No such key", exit 1) and a wrong value type (exit 1). `dconf load` merges (keeps keys not in the file), contrary to the June draft's risk note. A script can also express "back to GNOME's default" with `gsettings reset`. Cost: Forge's schema sits in its extension folder, so Forge lines need `--schemadir ~/.local/share/gnome-shell/extensions/forge@jmmaranan.com/schemas`.
- **Displaced GNOME keys** (agreed 2026-10-25): minimise (`Super+H`), app grid (`Super+A`), quick settings (`Super+S`) and the plain `Super+D` show-desktop binding are dropped (`Super+Ctrl+D` and `Ctrl+Alt+D` still show the desktop). Lock screen moves off `Super+L` to `Super+Ctrl+Shift+L` (the first pick, `Super+Ctrl+L`, is Forge's default swap-right; `Ctrl+Shift+Super+L` is unused by GNOME and by Forge, whose `Ctrl+Shift+Super` keys are only y/u/i/o).
- **Tiling Assistant is disabled**, not uninstalled (it's an Ubuntu package). Its `Super+arrow` keys are left unbound.

---

## Keymap (end state)

| Keys | Action | Owner |
|---|---|---|
| `Super+<letter>` (per app) | Jump to the app (switching workspace if needed), or start it | Run or Raise |
| `Super+h/j/k/l` | Focus tile left/down/up/right | Forge |
| `Super+Shift+h/j/k/l` | Move window to the tile that way | Forge |
| `Super+Ctrl+h/j/k/l` | Swap window with its neighbour | Forge (default) |
| `Super+A/S/D/F/1/2/3` | Switch to workspace 1–7 (both monitors) | GNOME `switch-to-workspace-N` |
| `Super+Shift+A/S/D/F/1/2/3` | Send window to workspace 1–7 | GNOME `move-to-workspace-N` |
| `Super+Alt+<letter>` | Forge layout extras (float, splits, stacked/tabbed) | Forge, rebound (table below) |
| `Super+Ctrl+Shift+L` | Lock screen | GNOME, moved from `Super+L` |
| `ctrl+h/j/k/l` | tmux panes / nvim splits | vim-tmux-navigator, untouched |

### App letters

Chosen in the app-keys buffer, 2026-10-25:

| Key | App | `.desktop` name (command) | Window class |
|---|---|---|---|
| `Super+I` | Ghostty | `com.mitchellh.ghostty.desktop` | read at build |
| `Super+B` | Chromium | `chromium_chromium.desktop` | read at build |
| `Super+V` | VS Code | `code_code.desktop` | read at build |
| `Super+G` | GoLand | `goland_goland.desktop` | read at build |
| `Super+C` | Slack | `slack.desktop` | read at build |
| `Super+Q` | Claude Desktop | `claude-desktop.desktop` | `claude-desktop` |
| `Super+O` | Outlook web app | `chrome-faolnafnngnfdaknnbpnkhgohbobgegn-Default.desktop` | `crx_faolnafnngnfdaknnbpnkhgohbobgegn` |
| `Super+T` | Teams web app | `chrome-ompifgpmddkgmclendfeacglnodjjndh-Default.desktop` | `crx_ompifgpmddkgmclendfeacglnodjjndh` |
| `Super+Y` | Spotify | `spotify_spotify.desktop` | read at build |
| `Super+E` | Files | `org.gnome.Nautilus.desktop` | read at build |

Beekeeper Studio gets no key. Files is on `E` because `F` is workspace 4. Teams and Outlook stay in the tracked file (decided: the split into a local untracked part isn't worth the complexity).

Plain `Super` letters still free after this: R, U, W, X, Z. (`Super+M` stays GNOME's message list, since `Super+V` now goes to VS Code.)

### Forge defaults that move

Forge's shipped defaults (from its `org.gnome.shell.extensions.forge.keybindings` schema) put six actions on plain `Super+letter`, which would eat app letters, and `Shift+Super+S` (stacked layout), which collides with "send to workspace 2". All layout extras move to `Super+Alt`, and its five `Ctrl+Alt` window-snap keys are cleared:

| Forge action | Default | New |
|---|---|---|
| `window-toggle-float` | `Super+C` | `Super+Alt+C` |
| `window-toggle-always-float` | `Shift+Super+C` | `Super+Alt+Shift+C` |
| `con-split-layout-toggle` | `Super+G` | `Super+Alt+G` |
| `con-split-horizontal` | `Super+Z` | `Super+Alt+Z` |
| `con-split-vertical` | `Super+V` | `Super+Alt+V` |
| `focus-border-toggle` | `Super+X` | `Super+Alt+X` |
| `prefs-tiling-toggle` | `Super+W` | `Super+Alt+W` |
| `workspace-active-tile-toggle` | `Shift+Super+W` | `Super+Alt+Shift+W` |
| `con-stacked-layout-toggle` | `Shift+Super+S` | `Super+Alt+S` (clears GNOME's screen-reader toggle there) |
| `con-tabbed-layout-toggle` | `Shift+Super+T` | `Super+Alt+T` |
| `window-snap-one-third-left` | `Ctrl+Alt+D` | Cleared (show desktop keeps `Ctrl+Alt+D`) |
| `window-snap-one-third-right` | `Ctrl+Alt+G` | Cleared (GPaste's `launch-ui`) |
| `window-snap-two-third-right` | `Ctrl+Alt+T` | Cleared (on a fresh machine it would clash with GNOME's terminal default, which this setup also clears; see the next table) |
| `window-snap-two-third-left` | `Ctrl+Alt+E` | Cleared |
| `window-snap-center` | `Ctrl+Alt+C` | Cleared |

The window-snap keys act only on floating windows and Forge tiles everything, so all five are cleared rather than moved (doc review, 2026-10-25).

Unchanged Forge defaults: focus/move/swap on hjkl, resize on `Ctrl(+Shift)+Super+y/u/i/o`, gaps on `Ctrl+Super+plus/minus`, `Super+Return` swap-last-active, `Super+Period` preferences.

### GNOME bindings cleared or moved

| Key today | GNOME action | Change |
|---|---|---|
| `Super+1..9` | `switch-to-application-N` | Cleared (all nine) |
| `Super+A` | app grid | Cleared |
| `Super+S` | quick settings | Cleared |
| `Super+D` | show desktop | That one entry cleared; `Super+Ctrl+D`, `Ctrl+Alt+D` kept |
| `Super+H` | minimise | Cleared |
| `Super+L` | lock screen | Moved to `Super+Ctrl+Shift+L` |
| `Super+B` / `Super+I` | launch browser / terminal | Cleared (launch-only; letters go to Run or Raise). Clearing the terminal key also removes GNOME's default `Ctrl+Alt+T` on a fresh machine; Super+I (Ghostty) replaces it (code review triage, 2026-10-25) |
| `Super+V` | message list (also on `Super+M`) | `Super+V` entry cleared (VS Code); `Super+M` kept |
| `Super+O` | rotation lock | Cleared (both monitors are fixed landscape) |
| `Super+Alt+S` | screen reader toggle | Cleared (Forge stacked layout) |
| `Super+arrows` | Tiling Assistant snaps | Freed by disabling the extension; left unbound |
| `Super+0..9`, `Shift+Super+0..9`, `Ctrl+Super+0..9` | Ubuntu Dock app hotkeys (`org.gnome.shell.extensions.dash-to-dock` `app-hotkey-1..10`, `app-shift-hotkey-1..10`, `app-ctrl-hotkey-1..10`) | Cleared, and `hot-keys` set false. The dock binds these separately from `switch-to-application-N`, so `Super+1..3` and `Shift+Super+1..3` would otherwise be bound twice with workspaces 5–7 |
| `Super+Q` | Ubuntu Dock "show dock and app numbers" (`dash-to-dock` `shortcut`) | Cleared (Claude Desktop's Run or Raise key) |

---

## Output Structure

```
gnome/
  install.sh        # install + enable Forge and Run or Raise (pinned versions),
                    # disable Tiling Assistant, run settings.sh, run check-keys.sh --live
  settings.sh       # every gsettings set/reset this setup owns (GNOME, Forge, GPaste)
  check-keys.sh     # R5 conflict check: --repo (isolated settings db) and --live
  README.md         # what this does, the one log-out, why not stow
run-or-raise/
  .config/run-or-raise/shortcuts.conf   # stow package: one line per app key
.githooks/pre-commit  # gains: run gnome/check-keys.sh --repo when gnome/ or run-or-raise/ change
install.sh            # gains: run-or-raise in the stow list, then gnome/install.sh
gpaste.dconf          # removed; its 8 settings move into settings.sh
```

---

## Implementation Units

### U1. Install the extensions and disable Tiling Assistant

- **Goal:** Forge and Run or Raise installed and enabled at pinned versions; Tiling Assistant disabled.
- **Requirements:** R2, R1, R6
- **Files:** `gnome/install.sh`, `gnome/README.md`
- **Approach:** Download each extension's zip for the pinned version from extensions.gnome.org and `gnome-extensions install --force` it when the installed version (from its `metadata.json`) differs from the pin, so a re-pin takes effect. `gnome-extensions disable tiling-assistant@ubuntu.com`. Then run `settings.sh` and `check-keys.sh --live`, and only then `gnome-extensions enable` each extension, so a failure never switches one on while GNOME still owns its keys (code review triage, 2026-10-25). It doesn't switch off an extension an earlier run enabled (second review, 2026-10-25: rewording chosen over disabling on failure). On Wayland a newly installed extension usually needs one log-out before it can be enabled; the script reports this instead of failing, and the README says so. Run or Raise must be enabled only **after** `shortcuts.conf` is stowed (U4): if the file is missing on first enable, the extension writes a default one, and stow then refuses to replace that real file. The guard checks where the path resolves, since stow may fold the whole `~/.config/run-or-raise` directory into one symlink.
- **Test scenarios:** `gnome-extensions list --enabled` shows both extensions and not Tiling Assistant; a second run changes nothing and exits 0.

### U2. GNOME settings: workspaces and displaced keys

- **Goal:** seven fixed workspaces on `A S D F 1 2 3`, both monitors switching, every displaced GNOME key cleared or moved.
- **Requirements:** R3, R4, R5
- **Files:** `gnome/settings.sh`
- **Approach:** Plain `gsettings set` / `gsettings reset` lines, grouped by schema with a one-line comment per group. `org.gnome.mutter dynamic-workspaces false`, `org.gnome.desktop.wm.preferences num-workspaces 7`, `org.gnome.mutter workspaces-only-on-primary false`. `switch-to-workspace-1..7` and `move-to-workspace-1..7` in `org.gnome.desktop.wm.keybindings` (keep `Super+Home`/`Super+Shift+Home` on workspace 1). Clear the bindings in the "GNOME bindings cleared or moved" table, including the Ubuntu Dock's own hotkeys (`org.gnome.shell.extensions.dash-to-dock`: `hot-keys false`, every `app-*hotkey-N` and `shortcut` set to `[]`). GPaste's 8 settings move here from `gpaste.dconf`. The script stops at the first failing line (`set -e`), so a typo surfaces at install.
- **Test scenarios:** run against an isolated settings database (see U5) and spot-check `gsettings get` for workspace 4 (`['<Super>f']`), workspace 5 (`['<Super>1']`) and `switch-to-application-1` (`[]`).

### U3. Forge settings

- **Goal:** Forge's keys match the keymap; no Forge default lands on an app letter, a workspace key, or `ctrl+hjkl`.
- **Requirements:** R2, R4, R5
- **Files:** `gnome/settings.sh` (Forge section)
- **Approach:** `gsettings --schemadir <forge schemas> set org.gnome.shell.extensions.forge.keybindings <key> <value>` for each row of "Forge defaults that move". The rest of Forge's defaults stay as shipped; the U5 check covers them because it reads Forge's whole schema, not only the keys this script sets.
- **Test scenarios:** with Forge enabled, `Super+l` focuses the tile to the right, `Super+Shift+l` moves the window right, `Super+Alt+C` floats it; inside tmux/nvim, `ctrl+h/j/k/l` still moves between panes and splits.

### U4. Run or Raise package

- **Goal:** one `Super+letter` per app, as chosen in the app-keys buffer.
- **Requirements:** R1, R5
- **Files:** `run-or-raise/.config/run-or-raise/shortcuts.conf`, `install.sh` (stow list)
- **Approach:** One line per app: the `.desktop` file name as the command (the same name the dock uses, e.g. `code_code.desktop`), the window class from `StartupWMClass` where the `.desktop` file has one (e.g. `claude-desktop`, `crx_<app-id>` for Chromium web apps), otherwise read once with GNOME's Looking Glass (`Alt+F2`, `lg`, Windows tab). No mode suffixes, so a press on an app open elsewhere switches to its workspace (R1). After editing, reload with `gnome-extensions disable run-or-raise@edvard.cz && gnome-extensions enable run-or-raise@edvard.cz`; README documents this.
- **Test scenarios:** each key starts its app when closed, focuses it when open, cycles its windows on repeat, and switches workspace when the window lives on another one.

### U5. Key-conflict check (R5)

- **Goal:** no accelerator is ever owned by two actions, checked on commit and on install.
- **Requirements:** R5, R4
- **Files:** `gnome/check-keys.sh`, `.githooks/pre-commit`, tests beside it following `scripts/.config/scripts/tmux/tests/`
- **Approach:**
  - Collect every binding: all keybinding-typed keys in `org.gnome.desktop.wm.keybindings`, `org.gnome.shell.keybindings`, `org.gnome.mutter.keybindings`, `org.gnome.mutter.wayland.keybindings`, `org.gnome.settings-daemon.plugins.media-keys` (including custom keybindings), the Ubuntu Dock's `org.gnome.shell.extensions.dash-to-dock` (its `app-*hotkey-N` and `shortcut` keys), GPaste's `org.gnome.GPaste` (its accelerator keys: `launch-ui`, `show-history`, `pop`, `upload`, `sync-*`), Forge's keybindings schema, plus every key in `shortcuts.conf`.
  - Normalise each accelerator: modifier aliases (`<Primary>` = `<Ctrl>` = `<Control>`), modifier order, letter case. Fail listing every accelerator with two or more owners. Also fail on any `ctrl+h/j/k/l` without `Super` (R4).
  - `--repo` (pre-commit, when `gnome/` or `run-or-raise/` is staged): start an isolated session (`dbus-run-session` with a throwaway `XDG_CONFIG_HOME`/`XDG_RUNTIME_DIR`, the method used for the 2026-10-25 storage test), so the database starts at GNOME's defaults; apply `settings.sh`; then check. This catches a repo change that collides with a GNOME default, without touching the live session. Needs Forge's schema on disk; if it's missing the hook fails with an explicit message rather than skipping Forge.
  - `--live` (end of `gnome/install.sh`, and by hand after any GNOME upgrade): check the running session, which also catches bindings added by a GNOME upgrade or another extension.
- **Test scenarios:** a fixture `shortcuts.conf` reusing `<Super>s` fails and names both owners; `<Primary><Super>l` and `<Super><Control>L` are detected as the same key; a clean config passes; the hook does nothing when neither folder is staged.

### U6. Bootstrap wiring, docs, live checks

- **Goal:** one command reproduces everything; docs say how it works.
- **Requirements:** R6
- **Files:** `install.sh`, `gnome/README.md`, `readme.md` (WM section), `docs/` via docgen, the task dossier's `checks.md`
- **Approach:** root `install.sh` stows `run-or-raise` then calls `gnome/install.sh`. Remove `gpaste.dconf`. Update the readme's WM note (it still says "dconf dump/load"). Write the live keymap checks as `checks.md` in the task dossier for the verify-behaviour watcher. Rerun docgen.
- **Test scenarios:** on a clean settings database plus a fresh stow, `bash install.sh` followed by one log-out yields the keymap above, and `gnome/check-keys.sh --live` passes.

---

## Scope Boundaries

### In scope
R1–R6.

### Documented limitation: per-monitor workspaces are not achievable on GNOME (R7)
GNOME either switches workspaces on the primary monitor only (other monitors stay fixed, outside the workspace system) or on all monitors together. This plan picks all monitors. A separate workspace set per monitor (AeroSpace's model) needs a compositor switch (Sway/niri), reopening the parked decision in `origin`.

### Deferred
- **Walker.** Revisit only with a compositor switch.
- **Per-app workspace assignment** (`assign`-style rules). Forge has limited support.
- **Pop Shell.** Fallback only, if Forge breaks on a GNOME upgrade.

---

---

## Risks & Dependencies

- **Forge has no maintainer.** Pin the version; re-check on every GNOME upgrade (next: Ubuntu 26.04, GNOME 50). Fallback: Pop Shell without `configure.sh`.
- **A GNOME upgrade can add default bindings.** The commit hook can't see that; `check-keys.sh --live` does, so run it after each upgrade (README says so).
- **Extension crash ends the session on Wayland.** Two extensions are two chances; R5 removes the known trigger (a double-bound key).
- **Wayland enable timing.** First enable after install needs a log-out; the README says so to avoid reading the install as broken.
- **Public repo.** `shortcuts.conf` names the Teams and Outlook web apps. Accepted 2026-10-25: app names don't identify an employer, and a tracked/untracked split isn't worth the complexity.

---

## Verification

On a fresh login after `bash install.sh`: each app letter jumps to or starts its app, `Super+hjkl` moves between tiles, `Super+A/S/D/F/1/2/3` switch both monitors, `Super+Shift+` the same keys send windows, `ctrl+hjkl` still works inside tmux/nvim, and `gnome/check-keys.sh --live` passes.
