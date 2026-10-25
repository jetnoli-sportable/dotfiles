#!/usr/bin/env bash
# Every gsettings value this setup owns: Forge, workspaces, displaced GNOME
# keys, Ubuntu Dock hotkeys, GPaste. set -e stops at the first bad line, so a
# misspelt key or wrong value type fails at install instead of silently.
# Forge comes first: its stock keys clash with Run or Raise and the workspace
# keys, so nothing optional may stop the script before they are moved.
set -euo pipefail

# Forge's schema is not installed system-wide; it lives in the extension folder.
# check-keys.sh overrides this to point at a test copy.
FORGE_SCHEMA_DIR="${FORGE_SCHEMA_DIR:-$HOME/.local/share/gnome-shell/extensions/forge@jmmaranan.com/schemas}"

# The Ubuntu Dock and GPaste are optional (a fresh Ubuntu has no GPaste); their
# blocks are skipped when the schema isn't installed, as check-keys.sh does.
# No grep -q: an early exit would SIGPIPE gsettings and, under pipefail, read
# as "not installed".
has_schema() { gsettings list-schemas | grep -x "$1" >/dev/null; }

# Forge's plain Super+letter defaults would eat app letters, and Shift+Super+S
# collides with "send to workspace 2": every layout extra moves to Super+Alt.
gsettings --schemadir "$FORGE_SCHEMA_DIR" set org.gnome.shell.extensions.forge.keybindings window-toggle-float "['<Super><Alt>c']"
gsettings --schemadir "$FORGE_SCHEMA_DIR" set org.gnome.shell.extensions.forge.keybindings window-toggle-always-float "['<Super><Alt><Shift>c']"
gsettings --schemadir "$FORGE_SCHEMA_DIR" set org.gnome.shell.extensions.forge.keybindings con-split-layout-toggle "['<Super><Alt>g']"
gsettings --schemadir "$FORGE_SCHEMA_DIR" set org.gnome.shell.extensions.forge.keybindings con-split-horizontal "['<Super><Alt>z']"
gsettings --schemadir "$FORGE_SCHEMA_DIR" set org.gnome.shell.extensions.forge.keybindings con-split-vertical "['<Super><Alt>v']"
gsettings --schemadir "$FORGE_SCHEMA_DIR" set org.gnome.shell.extensions.forge.keybindings focus-border-toggle "['<Super><Alt>x']"
gsettings --schemadir "$FORGE_SCHEMA_DIR" set org.gnome.shell.extensions.forge.keybindings prefs-tiling-toggle "['<Super><Alt>w']"
gsettings --schemadir "$FORGE_SCHEMA_DIR" set org.gnome.shell.extensions.forge.keybindings workspace-active-tile-toggle "['<Super><Alt><Shift>w']"
gsettings --schemadir "$FORGE_SCHEMA_DIR" set org.gnome.shell.extensions.forge.keybindings con-stacked-layout-toggle "['<Super><Alt>s']"
gsettings --schemadir "$FORGE_SCHEMA_DIR" set org.gnome.shell.extensions.forge.keybindings con-tabbed-layout-toggle "['<Super><Alt>t']"

# Snap keys only act on floating windows and Forge tiles everything; cleared
# rather than moved, which also frees Ctrl+Alt+D/G for GNOME and GPaste.
gsettings --schemadir "$FORGE_SCHEMA_DIR" set org.gnome.shell.extensions.forge.keybindings window-snap-one-third-left '[]'
gsettings --schemadir "$FORGE_SCHEMA_DIR" set org.gnome.shell.extensions.forge.keybindings window-snap-one-third-right '[]'
gsettings --schemadir "$FORGE_SCHEMA_DIR" set org.gnome.shell.extensions.forge.keybindings window-snap-two-third-right '[]'
gsettings --schemadir "$FORGE_SCHEMA_DIR" set org.gnome.shell.extensions.forge.keybindings window-snap-two-third-left '[]'
gsettings --schemadir "$FORGE_SCHEMA_DIR" set org.gnome.shell.extensions.forge.keybindings window-snap-center '[]'

# Seven fixed workspaces; Forge needs a fixed count, and both monitors switch
# together so every window belongs to a workspace.
gsettings set org.gnome.mutter dynamic-workspaces false
gsettings set org.gnome.desktop.wm.preferences num-workspaces 7
gsettings set org.gnome.mutter workspaces-only-on-primary false

# Workspace N on A S D F 1 2 3; Shift sends the focused window there.
# Workspace 1 keeps GNOME's Super+Home alongside its letter.
gsettings set org.gnome.desktop.wm.keybindings switch-to-workspace-1 "['<Super>a', '<Super>Home']"
gsettings set org.gnome.desktop.wm.keybindings switch-to-workspace-2 "['<Super>s']"
gsettings set org.gnome.desktop.wm.keybindings switch-to-workspace-3 "['<Super>d']"
gsettings set org.gnome.desktop.wm.keybindings switch-to-workspace-4 "['<Super>f']"
gsettings set org.gnome.desktop.wm.keybindings switch-to-workspace-5 "['<Super>1']"
gsettings set org.gnome.desktop.wm.keybindings switch-to-workspace-6 "['<Super>2']"
gsettings set org.gnome.desktop.wm.keybindings switch-to-workspace-7 "['<Super>3']"
gsettings set org.gnome.desktop.wm.keybindings move-to-workspace-1 "['<Super><Shift>a', '<Super><Shift>Home']"
gsettings set org.gnome.desktop.wm.keybindings move-to-workspace-2 "['<Super><Shift>s']"
gsettings set org.gnome.desktop.wm.keybindings move-to-workspace-3 "['<Super><Shift>d']"
gsettings set org.gnome.desktop.wm.keybindings move-to-workspace-4 "['<Super><Shift>f']"
gsettings set org.gnome.desktop.wm.keybindings move-to-workspace-5 "['<Super><Shift>1']"
gsettings set org.gnome.desktop.wm.keybindings move-to-workspace-6 "['<Super><Shift>2']"
gsettings set org.gnome.desktop.wm.keybindings move-to-workspace-7 "['<Super><Shift>3']"

# Super+1..9 (dock-order app switching) is replaced by Run or Raise letters.
for n in 1 2 3 4 5 6 7 8 9; do
  gsettings set org.gnome.shell.keybindings "switch-to-application-$n" '[]'
done

# Letters and keys the tiling setup takes over: app grid, quick settings,
# minimise, plain Super+D (Ctrl+Super+D and Ctrl+Alt+D still show the desktop),
# Super+V in the message list (Super+M stays), and the screen reader toggle.
gsettings set org.gnome.shell.keybindings toggle-application-view '[]'
gsettings set org.gnome.shell.keybindings toggle-quick-settings '[]'
gsettings set org.gnome.shell.keybindings toggle-message-tray "['<Super>m']"
gsettings set org.gnome.desktop.wm.keybindings minimize '[]'
gsettings set org.gnome.desktop.wm.keybindings show-desktop "['<Primary><Super>d', '<Primary><Alt>d']"
gsettings set org.gnome.settings-daemon.plugins.media-keys screenreader '[]'

# Lock moves off Super+L (Forge's focus-right); browser and terminal launchers
# free Super+B/I for Run or Raise (clearing them also drops GNOME's default
# Ctrl+Alt+T terminal key on a fresh machine: Super+I opens Ghostty instead);
# rotation lock loses Super+O (fixed landscape monitors) but keeps the hardware
# key.
gsettings set org.gnome.settings-daemon.plugins.media-keys screensaver "['<Super><Control><Shift>l']"
gsettings set org.gnome.settings-daemon.plugins.media-keys www '[]'
gsettings set org.gnome.settings-daemon.plugins.media-keys terminal '[]'
gsettings set org.gnome.settings-daemon.plugins.media-keys rotate-video-lock-static "['XF86RotationLockToggle']"

# Ubuntu Dock binds Super+N / Shift+Super+N / Ctrl+Super+N separately from
# switch-to-application, which would double-bind Super+1..3; Super+Q (show dock)
# is Claude Desktop's key.
if has_schema org.gnome.shell.extensions.dash-to-dock; then
  gsettings set org.gnome.shell.extensions.dash-to-dock hot-keys false
  for n in 1 2 3 4 5 6 7 8 9 10; do
    gsettings set org.gnome.shell.extensions.dash-to-dock "app-hotkey-$n" '[]'
    gsettings set org.gnome.shell.extensions.dash-to-dock "app-shift-hotkey-$n" '[]'
    gsettings set org.gnome.shell.extensions.dash-to-dock "app-ctrl-hotkey-$n" '[]'
  done
  gsettings set org.gnome.shell.extensions.dash-to-dock shortcut '[]'
else
  echo "settings.sh: Ubuntu Dock not installed, skipping" >&2
fi

# GPaste (moved here from gpaste.dconf).
if has_schema org.gnome.GPaste; then
  gsettings set org.gnome.GPaste history-name 'history'
  gsettings set org.gnome.GPaste images-support true
  gsettings set org.gnome.GPaste launch-ui "'<Ctrl><Alt>g'"
  gsettings set org.gnome.GPaste max-history-size 200
  gsettings set org.gnome.GPaste open-centered true
  gsettings set org.gnome.GPaste save-history true
  gsettings set org.gnome.GPaste show-history "'<Ctrl><Shift>G'"
  gsettings set org.gnome.GPaste track-extension-state true
else
  echo "settings.sh: GPaste not installed, skipping" >&2
fi
