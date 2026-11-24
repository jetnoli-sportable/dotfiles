#!/usr/bin/env bash
# clipboard.sh copy|paste — the system clipboard for tmux copy mode and nvim's
# "+" register (stdin is copied; paste prints to stdout).
#
# Goes through xclip on XWayland, not wl-copy/wl-paste. GNOME has no Wayland
# data-control protocol, so wl-clipboard opens a tiny window to get focus,
# GNOME's focus-stealing guard refuses it with a "wl-clipboard is ready"
# popup, and the call blocks (freezing nvim) until that popup is clicked.
# GNOME bridges the X clipboard to Wayland apps, and xclip needs no focus.
#
# xclip only needs a valid XAUTHORITY. The tmux server outlives a logout
# (linger, #123), so panes can inherit a key file from an earlier login. That
# file can still exist (mutter leaves old ones behind), so an inherited mutter
# key isn't trusted: use the newest key mutter wrote, which is this login's.
# A non-mutter key (a plain X11 login) is kept while it's readable.
set -uo pipefail

case "${1:-}" in
  copy | paste) ;;
  *) echo "usage: clipboard.sh copy|paste" >&2; exit 2 ;;
esac

live_xauthority() {
  case "${XAUTHORITY:-}" in
    */.mutter-Xwaylandauth.*) ;;
    *)
      if [ -n "${XAUTHORITY:-}" ] && [ -r "$XAUTHORITY" ]; then
        printf '%s' "$XAUTHORITY"
        return
      fi
      ;;
  esac
  local run="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}" newest
  newest="$(ls -t "$run"/.mutter-Xwaylandauth.* 2>/dev/null | head -n 1)"
  printf '%s' "${newest:-${XAUTHORITY:-}}"
}

if command -v xclip >/dev/null; then
  xa="$(live_xauthority)"
  [ -n "$xa" ] && export XAUTHORITY="$xa"
  export DISPLAY="${DISPLAY:-:0}"
  if [ "$1" = copy ]; then
    exec xclip -selection clipboard -i
  else
    exec xclip -selection clipboard -o
  fi
fi

# No xclip: wl-clipboard still works on compositors that have data-control.
if [ "$1" = copy ]; then exec wl-copy; else exec wl-paste --no-newline; fi
