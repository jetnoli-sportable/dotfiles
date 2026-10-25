#!/usr/bin/env bash
# Tests for gnome/install.sh's shortcuts.conf guard: it must accept the file
# however stow linked it and refuse anything else. Runs against a scratch
# $HOME; a stub curl stops the script at the first download, so nothing
# reaches gsettings, gnome-extensions or the live session.
# Run: bash gnome/tests/install.test.sh
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"

TMP="$(mktemp -d -t gnome-install-test.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT

fail=0
assert_eq() { # <desc> <expected> <actual>
  if [ "$2" = "$3" ]; then echo "ok   - $1"
  else echo "FAIL - $1 (expected '$2', got '$3')"; fail=1; fi
}

mkdir -p "$TMP/bin"
printf '#!/usr/bin/env bash\necho reached-download\nexit 99\n' > "$TMP/bin/curl"
printf '#!/usr/bin/env bash\necho "gnome-extensions stub: $*" >&2\nexit 98\n' > "$TMP/bin/gnome-extensions"
chmod +x "$TMP/bin/curl" "$TMP/bin/gnome-extensions"

# run_install <home>: sets $out and $rc
run_install() {
  out="$(env -u DBUS_SESSION_BUS_ADDRESS HOME="$1" PATH="$TMP/bin:$PATH" bash "$REPO/gnome/install.sh" 2>&1)"; rc=$?
}
reached() { grep -q reached-download <<<"$out" && echo yes || echo no; }

# Folded: ~/.config exists, ~/.config/run-or-raise doesn't, so stow links the
# whole directory (what happens on this laptop and any fresh machine).
h="$TMP/folded"; mkdir -p "$h/.config"
stow -d "$REPO" -t "$h" run-or-raise
assert_eq "stow folded the directory (precondition)" yes "$([ -L "$h/.config/run-or-raise" ] && echo yes || echo no)"
run_install "$h"
assert_eq "folded stow: guard passes, install reaches the download" yes "$(reached)"

# Unfolded: the directory already exists, so stow links the file itself.
h="$TMP/unfolded"; mkdir -p "$h/.config/run-or-raise"
stow -d "$REPO" -t "$h" run-or-raise
assert_eq "stow linked the file (precondition)" yes "$([ -L "$h/.config/run-or-raise/shortcuts.conf" ] && echo yes || echo no)"
run_install "$h"
assert_eq "file-level stow: guard passes, install reaches the download" yes "$(reached)"

# A plain file (what Run or Raise writes when it starts with no file) is refused.
h="$TMP/plain"; mkdir -p "$h/.config/run-or-raise"
echo '<Super>t,gnome-terminal,,' > "$h/.config/run-or-raise/shortcuts.conf"
run_install "$h"
assert_eq "extension-written file: exit 1" 1 "$rc"
assert_eq "extension-written file: no download" no "$(reached)"

# Not stowed at all is refused.
h="$TMP/missing"; mkdir -p "$h/.config"
run_install "$h"
assert_eq "missing file: exit 1" 1 "$rc"
assert_eq "missing file: no download" no "$(reached)"

[ "$fail" -eq 0 ] && echo "ALL PASS" || echo "FAILURES"
exit "$fail"
