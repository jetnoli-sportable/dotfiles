#!/usr/bin/env bash
# Corrects browser MIME/scheme defaults, then locks ~/.config/mimeapps.list
# with chattr +i so Slack's Electron xdg-settings bug can't silently
# reassign text/html back to itself on every cold launch (electron/electron
# #20382 — Electron shells out to xdg-settings for
# app.setAsDefaultProtocolClient(), which mis-registers text/html due to
# the dash in "slack-desktop.desktop"; fixed upstream in Electron 42.3.1,
# but Slack still bundles 41.2.2). Confirmed via journalctl that the
# rewrite lands within seconds of every Slack cold start, not just once
# at install.
#
# The lock is file-level, not per-entry: it blocks ALL future writes to
# mimeapps.list, including legitimate ones (a new app's first-run
# registration, changing your browser via GNOME Settings). To make a
# deliberate change: `sudo chattr -i ~/.config/mimeapps.list`, edit, then
# rerun this script to relock.
#
# Safe to rerun any time — xdg-mime/xdg-settings calls are idempotent, and
# the chattr toggle handles the file already being locked from a prior run.
set -euo pipefail

BROWSER=chromium_chromium.desktop
MIMEAPPS="$HOME/.config/mimeapps.list"

# Fail fast, before touching mimeapps.list at all, if xdg-utils or the
# target desktop entry aren't present. Without this check, a missing
# binary hits bash's "command not found" and a missing desktop file hits
# xdg-settings' own silent `exit 2` -- either aborts under set -e mid-run,
# on whatever machine doesn't already have this exact (snap) Chromium.
if ! command -v xdg-settings >/dev/null || ! command -v xdg-mime >/dev/null; then
  echo "default-browser.sh: xdg-settings/xdg-mime not installed -- skipping browser default setup" >&2
  exit 0
fi
desktop_dirs=("${XDG_DATA_HOME:-$HOME/.local/share}/applications")
IFS=: read -ra xdg_dirs <<< "${XDG_DATA_DIRS:-/usr/local/share:/usr/share}"
for d in "${xdg_dirs[@]}"; do
  desktop_dirs+=("$d/applications")
done
desktop_dirs+=("/var/lib/snapd/desktop/applications")
found=0
for d in "${desktop_dirs[@]}"; do
  [ -f "$d/$BROWSER" ] && found=1 && break
done
if [ "$found" -ne 1 ]; then
  echo "default-browser.sh: $BROWSER not found under any known applications directory -- install Chromium first, skipping" >&2
  exit 0
fi

sudo chattr -i "$MIMEAPPS" 2>/dev/null || true

# Safety net: if anything below fails and the script exits abnormally,
# still attempt to re-lock rather than leaving the file unlocked with no
# recovery path. Suppressed here since we're already mid-failure -- the
# real relock below is NOT suppressed, so a genuine relock failure on the
# success path stays visible instead of being silently swallowed.
trap 'sudo chattr +i "$MIMEAPPS" 2>/dev/null || true' EXIT

xdg-settings set default-web-browser "$BROWSER"
xdg-mime default "$BROWSER" \
  text/html \
  x-scheme-handler/http \
  x-scheme-handler/https \
  x-scheme-handler/about \
  x-scheme-handler/unknown

# Clear the safety-net trap and do the real, visible relock -- if this
# fails, the script exits non-zero with the actual error, not a silent
# no-op, and the "locked" message below correctly never prints.
trap - EXIT
sudo chattr +i "$MIMEAPPS"
echo "Set $BROWSER as the browser default and locked $MIMEAPPS (chattr +i)."
echo "To change a default-app association later: sudo chattr -i \"$MIMEAPPS\", edit, then rerun this script."
