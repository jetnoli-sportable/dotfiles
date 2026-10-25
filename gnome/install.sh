#!/usr/bin/env bash
# GNOME tiling setup: install Forge + Run or Raise at pinned versions, disable
# Tiling Assistant, apply settings.sh, check no key is bound twice, then enable
# the extensions. Called by the root install.sh after it stows run-or-raise.
# Safe to re-run.
set -euo pipefail
cd "$(dirname "$0")"

# uuid, extensions.gnome.org version tag, and the extension version that tag
# serves, for the GNOME 46 builds. Re-pin all three after a GNOME upgrade (see
# README.md); a changed version reinstalls on the next run.
extensions=(
  "forge@jmmaranan.com 67175 89"
  "run-or-raise@edvard.cz 75680 47"
)

# If shortcuts.conf is missing when Run or Raise is first enabled, the
# extension writes its own default file, and stow then refuses to replace it.
# Stow either links the file or folds the whole directory into one symlink, so
# check where the path resolves to, not whether it is a symlink itself.
conf="$HOME/.config/run-or-raise/shortcuts.conf"
case "$(readlink -f "$conf" 2>/dev/null || true)" in
  */run-or-raise/.config/run-or-raise/shortcuts.conf) ;;
  *)
    echo "gnome/install.sh: $conf is not the stowed repo file; run the root install.sh (it stows run-or-raise first)" >&2
    exit 1
    ;;
esac

# Installed version from the extension's metadata, empty when absent. Read from
# disk because the shell itself only knows a new install after a re-login.
installed_version() {
  local meta="$HOME/.local/share/gnome-shell/extensions/$1/metadata.json"
  [ -f "$meta" ] || return 0
  python3 -I -c 'import json, sys; print(json.load(open(sys.argv[1])).get("version", ""))' "$meta"
}

tmp="$(mktemp -d)"
trap 'rm -f "$tmp"/*.zip; rmdir "$tmp"' EXIT

needs_logout=0
for entry in "${extensions[@]}"; do
  read -r uuid tag version <<<"$entry"
  if [ "$(installed_version "$uuid")" != "$version" ]; then
    curl -fsSL --connect-timeout 10 --max-time 60 --retry 2 -o "$tmp/$uuid.zip" \
      "https://extensions.gnome.org/download-extension/$uuid.shell-extension.zip?version_tag=$tag"
    gnome-extensions install --force "$tmp/$uuid.zip"
    # A running shell keeps the old code (or doesn't see the new extension at
    # all) until the next login.
    needs_logout=1
  fi
done

gnome-extensions disable tiling-assistant@ubuntu.com 2>/dev/null || true

# Settings and the key check run before anything is enabled, so a failure in
# either never switches an extension on. It doesn't switch one off either: on a
# re-run, extensions enabled by an earlier run stay on.
bash ./settings.sh
bash ./check-keys.sh --live

for entry in "${extensions[@]}"; do
  read -r uuid _ <<<"$entry"
  if ! err="$(gnome-extensions enable "$uuid" 2>&1)"; then
    # Unknown to the running shell means installed this session (Wayland can't
    # load it until a re-login); anything else is a real failure.
    if gnome-extensions info "$uuid" >/dev/null 2>&1; then
      echo "gnome/install.sh: enabling $uuid failed: $err" >&2
      exit 1
    fi
    needs_logout=1
  fi
done

if [ "$needs_logout" = 1 ]; then
  echo "Installed. Log out and back in, then run gnome/install.sh again to enable the extensions."
fi
