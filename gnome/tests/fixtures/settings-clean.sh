#!/usr/bin/env bash
# Fixture settings script for check-keys.test.sh: clears every GNOME/dock/
# GPaste/Forge default that collides, standing in for the real gnome/settings.sh.
# Each call is best-effort so a machine without the dock or GPaste still works.
set -u
s() { gsettings "$@" 2>/dev/null || true; }
f() { gsettings --schemadir "$FORGE_SCHEMA_DIR" set org.gnome.shell.extensions.forge.keybindings "$1" "$2"; }
for n in 1 2 3 4 5 6 7 8 9; do
  s set org.gnome.shell.keybindings "switch-to-application-$n" '[]'
  s set org.gnome.shell.keybindings "open-new-window-application-$n" '[]'
  s set org.gnome.shell.extensions.dash-to-dock "app-hotkey-$n" '[]'
  s set org.gnome.shell.extensions.dash-to-dock "app-shift-hotkey-$n" '[]'
  s set org.gnome.shell.extensions.dash-to-dock "app-ctrl-hotkey-$n" '[]'
done
s set org.gnome.shell.extensions.dash-to-dock shortcut '[]'
s set org.gnome.GPaste launch-ui ''
s set org.gnome.desktop.wm.keybindings show-desktop '[]'
s set org.gnome.desktop.wm.keybindings minimize '[]'
s set org.gnome.settings-daemon.plugins.media-keys screensaver '[]'
s set org.gnome.shell.keybindings toggle-message-tray '[]'
for k in window-snap-one-third-left window-snap-one-third-right window-focus-left window-focus-right con-split-vertical window-snap-two-third-right; do
  f "$k" '[]'
done
