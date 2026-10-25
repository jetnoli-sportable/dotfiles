#!/usr/bin/env bash
# Fixture: the clean settings, then GNOME workspace 2 on <Super>s.
bash "$(dirname "${BASH_SOURCE[0]}")/settings-clean.sh"
gsettings set org.gnome.desktop.wm.keybindings switch-to-workspace-2 "['<Super>s']"
