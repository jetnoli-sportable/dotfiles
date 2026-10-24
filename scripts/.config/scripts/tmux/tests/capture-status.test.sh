#!/usr/bin/env bash
# Tests for capture-status.sh — the status-right segment that shows how many
# shelved decision drafts wait on the session's task (capture-nudge-rework R4).
# Plain-bash assertions against a sandboxed XDG_STATE_HOME; no tmux needed
# (the count verb makes no tmux call; the task path arrives as an argument).
#
# Run: bash scripts/.config/scripts/tmux/tests/capture-status.test.sh
set -uo pipefail

CS="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/capture-status.sh"
SANDBOX="$(mktemp -d -t capture-status.XXXXXX)"
trap 'rm -rf "$SANDBOX"' EXIT
export HOME="$SANDBOX/home" XDG_STATE_HOME="$SANDBOX/state"
mkdir -p "$HOME"
SHELF="$XDG_STATE_HOME/wb/capture/shelved"

fail=0
assert() { # <desc> <expected-regex> <actual>
  if printf '%s' "$3" | grep -qE -- "$2"; then
    echo "ok   - $1"
  else
    echo "FAIL - $1"; echo "       expected match: $2"; echo "       got: $3"; fail=1
  fi
}
assert_eq() { # <desc> <expected> <actual>
  if [ "$2" = "$3" ]; then echo "ok   - $1"; else echo "FAIL - $1 (expected '$2', got '$3')"; fail=1; fi
}

[ -x "$CS" ] && echo "ok   - capture-status.sh is executable (it runs under stow)" || { echo "FAIL - capture-status.sh not executable"; fail=1; }

# two shelved drafts for proj--two (a .stale sidecar is not a draft), one for proj--one
mkdir -p "$SHELF/proj--two" "$SHELF/proj--one" "$SHELF/proj--zero"
: >"$SHELF/proj--two/20261018T100000-a.md"; : >"$SHELF/proj--two/20261018T110000-b.md"
: >"$SHELF/proj--two/20261018T110000-b.md.stale"
: >"$SHELF/proj--one/20261018T100000-c.md"

out="$(bash "$CS" /tasks/proj--two.md)"; rc=$?
assert_eq "2 drafts: exit 0" "0" "$rc"
assert "2 drafts: output carries the count" '✎2' "$out"
assert "2 drafts: trailing space after the reset, so the next module doesn't touch it" '#\[default\] $' "$out"
assert "2 drafts: coloured with a tmux style" '^#\[fg=[^]]+\]' "$out"

out="$(bash "$CS" /tasks/proj--one.md)"
assert "1 draft: count 1" '✎1' "$out"

out="$(bash "$CS" /tasks/proj--zero.md)"; rc=$?
assert_eq "empty shelf dir: no output" "" "$out"
assert_eq "empty shelf dir: exit 0" "0" "$rc"

out="$(bash "$CS" /tasks/proj--never-seen.md)"; rc=$?
assert_eq "no shelf dir: no output" "" "$out"
assert_eq "no shelf dir: exit 0" "0" "$rc"

out="$(bash "$CS" '')"; rc=$?
assert_eq "empty task argument: no output" "" "$out"
assert_eq "empty task argument: exit 0" "0" "$rc"

out="$(bash "$CS")"; rc=$?
assert_eq "no argument: no output" "" "$out"
assert_eq "no argument: exit 0" "0" "$rc"

# the stem is derived like tmux_task does: basename, .md stripped (so a bare stem works too)
out="$(bash "$CS" proj--two)"
assert "bare stem (no directory, no .md): still counted" '✎2' "$out"
out="$(bash "$CS" /a/b/c/proj--two.md)"
assert "deep path: only the basename counts" '✎2' "$out"

# a task path whose stem is unsafe for the store verb (it exits 1) prints nothing, exits 0
out="$(bash "$CS" '/tasks/../x y.md')"; rc=$?
assert_eq "unsafe stem: no output" "" "$out"
assert_eq "unsafe stem: exit 0" "0" "$rc"

# runs from any cwd and through a symlink (stow links the script into ~/.config/scripts/tmux/)
LINKDIR="$SANDBOX/link"; mkdir -p "$LINKDIR"; ln -s "$(dirname "$CS")" "$LINKDIR/tmux"
out="$(cd / && bash "$LINKDIR/tmux/capture-status.sh" /tasks/proj--two.md)"
assert "via a symlinked scripts dir, from another cwd: counted" '✎2' "$out"

[ "$fail" -eq 0 ] && echo "ALL PASS" || echo "FAILURES"
exit "$fail"
