#!/usr/bin/env bash
# wb-store.sh — run the Go task-store reader, rebuilding it when stale.
# Thin wrapper around ~/code/wb-store, the reader of the wb task store:
# rebuilds the binary when its Go source changed, then runs it with --store
# pointed at $TASKS_DIR. Any wb-store command and flags pass straight through:
#
#   wb-store.sh show <task>          # one task, as text
#   wb-store.sh --json family <task> # a family, as JSON
#   WB_STORE_SRC=~/code/wb-store/.worktrees/x wb-store.sh show <task>
#   wb-store.sh --bin-path           # rebuild if stale, then print the binary's path
#
# The default source builds to ~/.local/bin/wb-store. Any other
# WB_STORE_SRC builds to its own binary under ~/.cache/wb-store/bin/:
# staleness is judged by file age alone, so one shared binary would let a
# switch back to an unchanged checkout run the other checkout's build.
#
# A rebuild holds the lock directory $BIN.lock (mkdir, since macOS has no
# flock), so two callers that find the binary stale at once build it once:
# the second waits up to WB_STORE_LOCK_WAIT seconds (default 60), then
# re-checks staleness and skips the build if the first made it fresh.
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
# dependency bump rebuilds. Any directory newer than the binary counts too:
# deleting or renaming a file changes no remaining file's age, only its
# directory's, so a pull that only removes a .go file or template would
# otherwise keep running the old build. The cost is a spare rebuild when
# something else adds or removes a file in the source (an editor swap file).
stale() {
  [ -x "$BIN" ] || return 0
  [ -n "$(find "$src" \( -name .git -o -name .worktrees \) -prune -o \
          \( -type d -o -type f \( -name '*.go' -o -name go.mod -o -name go.sum \
             -o -path '*/templates/*' \) \) \
          -newer "$BIN" -print -quit 2>/dev/null)" ]
}

lock="$BIN.lock"
lock_wait="${WB_STORE_LOCK_WAIT:-60}"
have_lock=0

# Stale when its holder is dead, or after 5 minutes whatever the pid says
# (a reused pid, or a holder killed between mkdir and writing its pid). A
# real build takes seconds, a cold module download well under a minute, so
# an older lock is abandoned. Two waiters breaking the same lock at once cost
# only a duplicate build: the temp-and-rename below keeps the binary whole.
lock_is_stale() {
  local pid
  pid=$(cat "$lock/pid" 2>/dev/null) || pid=""
  if [ -n "$pid" ] && ! kill -0 "$pid" 2>/dev/null; then return 0; fi
  [ -n "$(find "$lock" -maxdepth 0 -mmin +5 2>/dev/null)" ]
}

# A failed pid write means another caller broke our new lock in between:
# go round again rather than build without one.
take_lock() {
  local deadline=$((SECONDS + lock_wait))
  while :; do
    if mkdir "$lock" 2>/dev/null; then
      have_lock=1
      if { echo "$$" > "$lock/pid"; } 2>/dev/null; then return 0; fi
      have_lock=0
      continue
    fi
    if lock_is_stale; then
      echo "wb-store.sh: breaking stale build lock $lock" >&2
      rm -rf "$lock" 2>/dev/null || true
    fi
    if [ "$SECONDS" -ge "$deadline" ]; then
      echo "wb-store.sh: gave up after ${lock_wait}s waiting for another build of $BIN (lock $lock, pid $(cat "$lock/pid" 2>/dev/null || echo unknown)); remove the lock if no build is running" >&2
      exit 1
    fi
    sleep 0.2
  done
}

# Only our own lock: one broken as stale and retaken by another caller
# carries that caller's pid.
release_lock() {
  local owner
  [ "$have_lock" = 1 ] || return 0
  owner=$(cat "$lock/pid" 2>/dev/null) || owner=""
  if [ -z "$owner" ] || [ "$owner" = "$$" ]; then rm -rf "$lock"; fi
  have_lock=0
}

if stale; then
  command -v go >/dev/null || { echo "wb-store.sh: go not found; it is needed to build $BIN from $src" >&2; exit 1; }
  mkdir -p "$(dirname "$BIN")"
  tmp=""
  cleanup() { if [ -n "$tmp" ]; then rm -f "$tmp"; fi; release_lock; }
  trap cleanup EXIT
  trap 'exit 1' INT TERM HUP
  take_lock
  if stale; then
    echo "wb-store.sh: building wb-store from $src" >&2
    # build beside the binary and rename, so a failed or interrupted build
    # never leaves a half-written binary for another caller to run
    tmp=$(mktemp "$(dirname "$BIN")/.wb-store.XXXXXX")
    (cd "$src" && go build -o "$tmp" ./cmd/wb-store)
    mv -f "$tmp" "$BIN"
    tmp=""
  fi
  cleanup
  trap - EXIT INT TERM HUP
fi

# --bin-path, alone: `wb page` hashes the binary to find a running page
# server of the same build (the build id /healthz reports).
if [ "$#" -eq 1 ] && [ "$1" = --bin-path ]; then
  printf '%s\n' "$BIN"
  exit 0
fi

exec "$BIN" --store "$TASKS_DIR" "$@"
