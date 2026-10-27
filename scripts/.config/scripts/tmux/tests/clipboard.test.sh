#!/usr/bin/env bash
# Tests for clipboard.sh — the system clipboard for tmux copy mode and nvim's
# "+" register. Plain-bash assertions with a stub xclip/wl-copy on PATH that
# records its arguments and environment; nothing touches the real clipboard.
#
# Run: bash scripts/.config/scripts/tmux/tests/clipboard.test.sh
set -uo pipefail

CLIP="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/clipboard.sh"
SANDBOX="$(mktemp -d -t clipboard-test.XXXXXX)"
trap 'rm -rf "$SANDBOX"' EXIT
RUN="$SANDBOX/run"
STUBS="$SANDBOX/stubs"
LOG="$SANDBOX/log"
mkdir -p "$RUN" "$STUBS"

fail=0
assert_eq() { # <desc> <expected> <actual>
  if [ "$2" = "$3" ]; then echo "ok   - $1"; else echo "FAIL - $1 (expected '$2', got '$3')"; fail=1; fi
}

# A stub that logs "<name> <args> | XAUTHORITY=… DISPLAY=… | stdin=…" and
# prints "pasted" for a paste.
make_stub() { # <name>
  cat >"$STUBS/$1" <<EOF
#!/usr/bin/env bash
in=""; [ -t 0 ] || in="\$(cat)"
echo "$1 \$* | XAUTHORITY=\${XAUTHORITY:-} DISPLAY=\${DISPLAY:-} | stdin=\$in" >>"$LOG"
case "\$*" in *-o* | *--no-newline*) printf pasted ;; esac
EOF
  chmod +x "$STUBS/$1"
}
make_stub xclip

# Runs clipboard.sh with the stubs first on PATH and a sandboxed runtime dir.
run_clip() { # <env assignments...> -- <args...>
  local -a envs=()
  while [ "$1" != -- ]; do envs+=("$1"); shift; done
  shift
  : >"$LOG"
  env -u XAUTHORITY -u DISPLAY XDG_RUNTIME_DIR="$RUN" PATH="$STUBS:$PATH" "${envs[@]}" bash "$CLIP" "$@"
}

[ -x "$CLIP" ] && echo "ok   - clipboard.sh is executable (it runs under stow)" || { echo "FAIL - clipboard.sh not executable"; fail=1; }

# Two key files from mutter; the newer one is this login's.
: >"$RUN/.mutter-Xwaylandauth.OLD111"
touch -d '2026-01-01' "$RUN/.mutter-Xwaylandauth.OLD111"
: >"$RUN/.mutter-Xwaylandauth.NEW222"

printf 'hello' | run_clip XAUTHORITY="$RUN/gone-from-last-login" -- copy
assert_eq "stale XAUTHORITY: replaced by the newest mutter key" \
  "xclip -selection clipboard -i | XAUTHORITY=$RUN/.mutter-Xwaylandauth.NEW222 DISPLAY=:0 | stdin=hello" "$(cat "$LOG")"

: >"$SANDBOX/live-key"
printf 'hi' | run_clip XAUTHORITY="$SANDBOX/live-key" DISPLAY=:1 -- copy
assert_eq "live XAUTHORITY and DISPLAY: kept as they are" \
  "xclip -selection clipboard -i | XAUTHORITY=$SANDBOX/live-key DISPLAY=:1 | stdin=hi" "$(cat "$LOG")"

printf 'x' | run_clip -- copy
assert_eq "no XAUTHORITY at all: the newest mutter key is used" \
  "xclip -selection clipboard -i | XAUTHORITY=$RUN/.mutter-Xwaylandauth.NEW222 DISPLAY=:0 | stdin=x" "$(cat "$LOG")"

out="$(run_clip -- paste </dev/null)"
assert_eq "paste: prints what xclip returns" "pasted" "$out"
assert_eq "paste: reads the clipboard selection" \
  "xclip -selection clipboard -o | XAUTHORITY=$RUN/.mutter-Xwaylandauth.NEW222 DISPLAY=:0 | stdin=" "$(cat "$LOG")"

rm -f "$RUN"/.mutter-Xwaylandauth.*
printf 'y' | run_clip XAUTHORITY="$RUN/gone" -- copy
assert_eq "no mutter key to fall back to: the inherited value is left alone" \
  "xclip -selection clipboard -i | XAUTHORITY=$RUN/gone DISPLAY=:0 | stdin=y" "$(cat "$LOG")"

out="$(run_clip -- bogus 2>&1)"; rc=$?
assert_eq "unknown verb: exit 2" "2" "$rc"
assert_eq "unknown verb: usage on stderr" "usage: clipboard.sh copy|paste" "$out"

# Without xclip on PATH it falls back to wl-clipboard. The PATH below holds
# only the stubs plus the few tools the script and the stubs need.
rm "$STUBS/xclip"
make_stub wl-copy
make_stub wl-paste
for t in bash cat env id ls head; do ln -sf "$(command -v "$t")" "$STUBS/$t"; done
: >"$LOG"
printf 'z' | env -u XAUTHORITY -u DISPLAY XDG_RUNTIME_DIR="$RUN" PATH="$STUBS" bash "$CLIP" copy
assert_eq "no xclip: copy falls back to wl-copy" "wl-copy  | XAUTHORITY= DISPLAY= | stdin=z" "$(cat "$LOG")"
: >"$LOG"
out="$(env -u XAUTHORITY -u DISPLAY XDG_RUNTIME_DIR="$RUN" PATH="$STUBS" bash "$CLIP" paste </dev/null)"
assert_eq "no xclip: paste falls back to wl-paste" "pasted" "$out"

[ "$fail" -eq 0 ] && echo "ALL PASS" || { echo "SOME FAILED"; exit 1; }
