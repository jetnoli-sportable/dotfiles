#!/usr/bin/env bash
# GNOME tiling setup: install Forge + Run or Raise at pinned versions, disable
# Tiling Assistant, apply settings.sh, then check no key is bound twice.
# Called by the root install.sh after it stows run-or-raise. Safe to re-run.
set -euo pipefail
cd "$(dirname "$0")"

# extensions.gnome.org version tags for the GNOME 46 builds (Forge v89, Run or
# Raise v47). Re-pin after a GNOME upgrade: see README.md.
extensions=(
  "forge@jmmaranan.com 67175"
  "run-or-raise@edvard.cz 75680"
)

# If shortcuts.conf is missing when Run or Raise is first enabled, the
# extension writes its own default file, and stow then refuses to replace it.
conf="$HOME/.config/run-or-raise/shortcuts.conf"
if [ ! -L "$conf" ]; then
  echo "gnome/install.sh: $conf is not the stowed symlink; run the root install.sh (it stows run-or-raise first)" >&2
  exit 1
fi

tmp="$(mktemp -d)"
trap 'rm -f "$tmp"/*.zip; rmdir "$tmp"' EXIT

needs_logout=0
for entry in "${extensions[@]}"; do
  read -r uuid tag <<<"$entry"
  if ! gnome-extensions info "$uuid" >/dev/null 2>&1; then
    curl -fsSL -o "$tmp/$uuid.zip" \
      "https://extensions.gnome.org/download-extension/$uuid.shell-extension.zip?version_tag=$tag"
    gnome-extensions install --force "$tmp/$uuid.zip"
  fi
  # On Wayland the shell only sees a newly installed extension after a re-login.
  gnome-extensions enable "$uuid" 2>/dev/null || needs_logout=1
done

gnome-extensions disable tiling-assistant@ubuntu.com 2>/dev/null || true

bash ./settings.sh
bash ./check-keys.sh --live

if [ "$needs_logout" = 1 ]; then
  echo "Installed. Log out and back in, then run gnome/install.sh again to enable the extensions."
fi
