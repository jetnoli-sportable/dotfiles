#!/usr/bin/env bash
# wb-store.sh — run wb-store, the Go reader of the wb task store, against
# the real store. Thin wrapper around ~/code/wb-store: rebuilds the binary
# when its Go source changed, then runs it with --store pointed at
# $TASKS_DIR. Any wb-store command and flags pass straight through:
#
#   wb-store.sh show <task>          # one task, as text
#   wb-store.sh --json family <task> # a family, as JSON
#   WB_STORE_SRC=~/code/wb-store/.worktrees/x wb-store.sh show <task>
#
# The default source builds to ~/.local/bin/wb-store. Any other
# WB_STORE_SRC builds to its own binary under ~/.cache/wb-store/bin/:
# staleness is judged by file age alone, so one shared binary would let a
# switch back to an unchanged checkout run the other checkout's build.
set -euo pipefail

default_src="$HOME/code/wb-store"
WB_STORE_SRC="${WB_STORE_SRC:-$default_src}"
TASKS_DIR="${TASKS_DIR:-$HOME/code/tasks}"

[ -d "$WB_STORE_SRC" ] || { echo "wb-store.sh: no source at $WB_STORE_SRC (set WB_STORE_SRC to a wb-store checkout)" >&2; exit 1; }
src=$(cd "$WB_STORE_SRC" && pwd -P)
default_real=$(cd "$default_src" 2>/dev/null && pwd -P || true)

if [ "$src" = "$default_real" ]; then
  BIN="$HOME/.local/bin/wb-store"
else
  BIN="${XDG_CACHE_HOME:-$HOME/.cache}/wb-store/bin/${src//\//_}/wb-store"
fi

# Recursive, unlike docgen.sh: the source has cmd/ and internal/ packages.
# .git and .worktrees are pruned so another branch's checkout never counts.
# templates/ holds the page server's embedded HTML (W11); a file embedded
# from anywhere else must be added here too. go.mod/go.sum count, so a
# dependency bump rebuilds.
stale() {
  [ -x "$BIN" ] || return 0
  [ -n "$(find "$src" \( -name .git -o -name .worktrees \) -prune -o -type f \
          \( -name '*.go' -o -name go.mod -o -name go.sum -o -path '*/templates/*' \) \
          -newer "$BIN" -print -quit 2>/dev/null)" ]
}

if stale; then
  command -v go >/dev/null || { echo "wb-store.sh: go not found; it is needed to build $BIN from $src" >&2; exit 1; }
  echo "wb-store.sh: building wb-store from $src" >&2
  mkdir -p "$(dirname "$BIN")"
  # build beside the binary and rename, so a failed or interrupted build
  # never leaves a half-written binary for another caller to run
  tmp=$(mktemp "$(dirname "$BIN")/.wb-store.XXXXXX")
  trap 'rm -f "$tmp"' EXIT
  trap 'exit 1' INT TERM HUP
  (cd "$src" && go build -o "$tmp" ./cmd/wb-store)
  mv -f "$tmp" "$BIN"
  trap - EXIT INT TERM HUP
fi

exec "$BIN" --store "$TASKS_DIR" "$@"
