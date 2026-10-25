#!/usr/bin/env bash
# Fixture: the clean settings, then a bare <Control>j binding.
bash "$(dirname "${BASH_SOURCE[0]}")/settings-clean.sh"
gsettings set org.gnome.desktop.wm.keybindings switch-to-workspace-2 "['<Control>j']"
