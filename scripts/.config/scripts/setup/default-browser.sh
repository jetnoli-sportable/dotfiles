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

sudo chattr -i "$MIMEAPPS" 2>/dev/null || true

xdg-settings set default-web-browser "$BROWSER"
xdg-mime default "$BROWSER" \
  text/html \
  x-scheme-handler/http \
  x-scheme-handler/https \
  x-scheme-handler/about \
  x-scheme-handler/unknown

sudo chattr +i "$MIMEAPPS"
echo "Set $BROWSER as the browser default and locked $MIMEAPPS (chattr +i)."
echo "To change a default-app association later: sudo chattr -i \"$MIMEAPPS\", edit, then rerun this script."
