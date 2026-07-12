#!/usr/bin/env bash
# wb-locks.sh — per-task-file flock side-car lock primitives.
# Sourced by wb.sh and handoff.sh the same way wb.sh sources lib.sh /
# wb-lifecycle.sh — a sibling module (see wb-lifecycle.sh's own header for
# that convention), side-effect-free on source: this file only defines
# functions below, no top-level command ever runs just by sourcing it.
#
# Design: docs/plans/2026-07-11-001-feat-tasks-dir-concurrency-safety-plan.md
# (U1: W1-W4, W6 helper, W7-W9, X4 disable-locks, L4 message shape).
#
# Fixes a reproduced silent-lost-write race (incident 4): two unlocked
# read-modify-write-via-mv cycles on the same task file can interleave and
# drop a write. wb_task_lock_acquire/wb_task_lock_release wrap a single
# side-car flock per task file (never the task file's own path — an
# atomic-rename inode swap would defeat a path-based lock, since a fresh
# inode at the same path would carry no memory of who held it locked).
#
# Lock file: ${XDG_STATE_HOME:-$HOME/.local/state}/wb/locks/<basename>.lock
# — derived purely from the task file's basename (W1), so two different
# paths to the same logical task file (a worktree-relative path vs. an
# absolute one, say) still serialize against the very same lock.
#
# fd handling: a bash function can't hand its caller an open fd through a
# normal return value, and separate acquire/release calls don't share
# local scope, so the fd bash's `exec {fd}<>file` allocates is stashed in
# a global associative array (WB_LOCK_FDS, keyed by the resolved lock file
# path) between the acquire call and its matching release call. Closing an
# fd whose number lives in a variable reuses the very same `{varname}`
# redirection form bash uses to allocate one: `exec {fd}<&-` closes
# whatever fd number is CURRENTLY held in $fd, even when that value was
# assigned by an earlier, unrelated `{fd}` allocation or read back out of
# an associative array — verified against bash 5.2's documented
# `{varname}<&-` close-by-variable behavior before relying on it here.
#
# No `set -e` of its own (lib.sh's convention: sourced modules don't force
# an errexit posture onto whatever sources them). Every module-scoped
# variable this file reads uses `VAR="${VAR:-default}"` so sourcing this
# file never clobbers a caller's variable of the same name — the
# 2026-07-10 deletion-incident convention: wb.sh's own unconditional
# `SCRIPT_DIR="$(...)"` / `SELF=...` reassignment (wb.sh:26-27) is exactly
# the pattern NOT to repeat here.

# ---------------------------------------------------------------------------
# internal: paths, state
# ---------------------------------------------------------------------------

# _wb_lock_state_home — XDG state dir root, override-safe.
_wb_lock_state_home() {
  printf '%s\n' "${XDG_STATE_HOME:-$HOME/.local/state}"
}

# _wb_lock_dir — the directory all side-car lock files live under.
_wb_lock_dir() {
  printf '%s/wb/locks\n' "$(_wb_lock_state_home)"
}

# _wb_lock_disable_file — X4 kill-switch path. Presence alone (content is
# never read) makes wb_task_lock_acquire a silent no-op success — the
# manual escape if the lock infrastructure itself breaks.
_wb_lock_disable_file() {
  printf '%s/wb/disable-locks\n' "$(_wb_lock_state_home)"
}

# _wb_lock_path_for <task_file> — the side-car lock path, derived PURELY
# from <task_file>'s basename (W1) — never its directory — so callers
# passing differently-rooted paths to the same logical task file still
# serialize against the same lock.
_wb_lock_path_for() {
  printf '%s/%s.lock\n' "$(_wb_lock_dir)" "$(basename -- "$1")"
}

# _wb_lock_identity_for <task_file> — the holder identity string W3 wants
# recorded, "${repo}--${disp_slug}" — which is exactly a task file's
# basename with the .md extension stripped (wb_task_file's own naming
# convention: "$TASKS_DIR/$repo--$disp_slug.md", wb.sh:108).
_wb_lock_identity_for() {
  local base; base="$(basename -- "$1")"
  printf '%s\n' "${base%.md}"
}

# _wb_lock_init_state — lazily declares the global fd-tracking map. Kept
# inside a function (called at the top of every public primitive) rather
# than at this file's top level, so sourcing this file stays a pure
# function-definition exercise with no top-level statement execution.
# `declare -gA` on an already-declared associative array is a no-op on its
# contents (doesn't clear it), so calling this repeatedly is safe.
_wb_lock_init_state() {
  if ! declare -p WB_LOCK_FDS >/dev/null 2>&1; then
    declare -gA WB_LOCK_FDS
  fi
}

# _wb_lock_own_tmux_pane / _wb_lock_own_tmux_session — the ACQUIRING
# process's OWN tmux identity (W3), empty when not inside tmux. Deliberately
# not the target task's tmux identity: a later liveness-check unit (not
# this one) reads this field to ask "is the holder's OWN pane still
# alive?", a question the target task's identity alone can't answer.
_wb_lock_own_tmux_pane() {
  if [ -n "${TMUX:-}" ]; then
    printf '%s' "${TMUX_PANE:-}"
  fi
  return 0
}

_wb_lock_own_tmux_session() {
  if [ -n "${TMUX:-}" ]; then
    tmux display -p '#S' 2>/dev/null
  fi
  return 0
}

# _wb_lock_field <lockfile> <key> — read a single "key: value" line out of
# a holder-info file. Read-only: never truncates or writes. Prints empty
# if the file is absent or the key isn't present (e.g. a lock that has
# never been held) — callers must tolerate an empty result, not treat it
# as an error.
_wb_lock_field() {
  local file="$1" key="$2" line
  [ -f "$file" ] || return 0
  line="$(grep -m1 "^${key}: " "$file" 2>/dev/null)" || return 0
  printf '%s\n' "${line#*: }"
}

# wb_task_lock_holder_field <task_file> <key> — public reader for a
# contended lock's recorded holder-info fields (holder/pid/acquired/
# tmux_pane/tmux_session), for callers outside this module (e.g. wb.sh's
# orphan-check layer) that need to inspect a lock they lost — without
# reaching into this module's own internal path/field accessors
# (_wb_lock_path_for/_wb_lock_field) directly. Same tolerant, read-only
# contract: empty if the lock file doesn't exist or the key isn't set.
wb_task_lock_holder_field() {
  _wb_lock_field "$(_wb_lock_path_for "$1")" "$2"
}

# ---------------------------------------------------------------------------
# public primitives
# ---------------------------------------------------------------------------

# wb_task_lock_acquire <task_file> — acquire the per-task-file side-car
# lock (W1-W9, X4). Zero stdout/stderr output on a successful, uncontended
# acquire (W7). Never auto-retries (W9) — retry is a caller-level decision.
#
# Sequence: X4 kill-switch check -> mkdir -p the lock dir (fail closed,
# exit 75, on failure) -> open the side-car file `<>` WITHOUT truncation
# on a dedicated fd (fail closed, exit 75, on failure — a message distinct
# from the mkdir failure) -> `flock -w 1` on that fd -> on success,
# truncate-and-write holder info; on timeout, read (never touch) the
# current holder info and print the one-line W8/L4 contention message,
# returning 75 without retrying.
wb_task_lock_acquire() {
  local task_file="$1"
  _wb_lock_init_state

  if [ -z "$task_file" ]; then
    echo "wb lock: wb_task_lock_acquire requires a task file argument" >&2
    return 75
  fi

  # X4 kill-switch: a FILE, not an env var, so a long-running session sees
  # a switch flipped mid-session on its very next call without a restart.
  # Silent no-op success — skips everything below, "acquires" instantly.
  if [ -e "$(_wb_lock_disable_file)" ]; then
    return 0
  fi

  local lock_dir; lock_dir="$(_wb_lock_dir)"
  if ! mkdir -p "$lock_dir" 2>/dev/null; then
    echo "wb lock: could not create lock directory: $lock_dir" >&2
    return 75
  fi

  local lockfile; lockfile="$(_wb_lock_path_for "$task_file")"

  # W3: open WITHOUT truncation (`<>`, read-write, create-if-missing). The
  # idiomatic `exec {fd}>file` truncates before flock is even attempted,
  # which would blank the current holder's info on every losing contended
  # attempt. Wrapped in `{ ; }` (NOT a subshell `( )`) so `fd` survives
  # into the rest of this function and, via WB_LOCK_FDS, beyond it.
  local fd
  if ! { exec {fd}<>"$lockfile"; } 2>/dev/null; then
    echo "wb lock: could not open lock file: $lockfile" >&2
    return 75
  fi

  if ! flock -w 1 "$fd"; then
    local holder_id holder_pid holder_ts now held_epoch elapsed
    holder_id="$(_wb_lock_field "$lockfile" holder)"
    holder_pid="$(_wb_lock_field "$lockfile" pid)"
    holder_ts="$(_wb_lock_field "$lockfile" acquired)"
    now="$(date +%s)"
    held_epoch="$(date -d "$holder_ts" +%s 2>/dev/null)" || held_epoch="$now"
    elapsed=$(( now - held_epoch ))
    [ "$elapsed" -ge 0 ] || elapsed=0
    # L4 addressee split: agents get told to stop and escalate, never to
    # clear the lock themselves; the `rm` override is for the operator
    # only. No blocking stdin read here, and — per the guard above — no
    # write of any kind into the contended lock file on this path.
    echo "wb lock: contended on $(basename -- "$task_file") — held by ${holder_id:-unknown} (pid ${holder_pid:-?}) for ${elapsed}s. Agents: STOP and report this contention upward — never clear the lock yourselves. Operator-only, if the holder is confirmed dead: rm \"$lockfile\"." >&2
    { exec {fd}<&-; } 2>/dev/null || true
    return 75
  fi

  WB_LOCK_FDS["$lockfile"]="$fd"

  # Truncate-and-write holder info only now, after successful acquisition
  # (W3) — via the lock file's PATH, not the held fd. We already hold the
  # exclusive flock, so a plain truncating redirect here can't race any
  # other cooperating locker (mirrors wb_ensure_repo_ignore's own
  # flock-then-write idiom, wb.sh's pre-existing flock precedent, wb.sh
  # ~line 228 — that one is fine truncating up front only because it
  # stores no holder info; this is exactly what W3 changes for task locks).
  {
    printf 'holder: %s\n' "$(_wb_lock_identity_for "$task_file")"
    printf 'pid: %s\n' "$$"
    printf 'acquired: %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    printf 'tmux_pane: %s\n' "$(_wb_lock_own_tmux_pane)"
    printf 'tmux_session: %s\n' "$(_wb_lock_own_tmux_session)"
  } > "$lockfile"

  return 0
}

# wb_task_lock_release <task_file> — release the lock acquired for
# <task_file> by closing its fd; the kernel drops the flock the instant
# the last fd referencing that open file description closes (also the
# final backstop on process death, with no code required here at all).
# Silent no-op if nothing is currently tracked as held for this task file
# (kill-switch was active, acquire failed, or it was already released) —
# release is idempotent and always safe to call speculatively.
#
# NEVER deletes the lock file itself: a next opener could otherwise lock a
# ghost inode while a third process opens/locks a fresh file at the same
# path, defeating mutual exclusion between the two.
#
# The `2>/dev/null` MUST be scoped to a `{ ; }` group around the close, not
# attached directly to the bare `exec` statement: `exec {fd}<&- 2>/dev/null`
# (no group) applies that redirect to the CURRENT SHELL's own fd 2
# permanently — every stderr write for the rest of THIS PROCESS's lifetime
# silently vanishes from the moment the first lock is ever released.
# Reproduced live: a script's own later `echo ... >&2` after calling this
# function stopped printing anything at all. `{ exec {fd}<&-; } 2>/dev/null`
# scopes the suppression to the fd-close's own (rare) failure only, exactly
# matching wb_task_lock_acquire's own `{ exec {fd}<>"$lockfile"; } 2>/dev/null`
# a few lines up — this function had drifted from that established pattern.
wb_task_lock_release() {
  local task_file="$1"
  _wb_lock_init_state

  [ -n "$task_file" ] || return 0

  local lockfile; lockfile="$(_wb_lock_path_for "$task_file")"
  local fd="${WB_LOCK_FDS[$lockfile]:-}"
  [ -n "$fd" ] || return 0

  { exec {fd}<&-; } 2>/dev/null || true
  unset "WB_LOCK_FDS[$lockfile]"
  return 0
}

# ---------------------------------------------------------------------------
# EXIT-trap safety net (W6)
# ---------------------------------------------------------------------------

# wb_lock_trap_append <cleanup-command> — append <cleanup-command> to the
# process's EXIT trap, COMPOSING with whatever is already installed
# rather than clobbering it. Bash keeps exactly one EXIT trap per process;
# wb.sh's picker() already owns one (`trap 'rm -f "$mode_file"' EXIT`,
# wb.sh:2318) before it calls into cmd_new in-process, so a naive
# `trap ... EXIT` here would silently delete that cleanup. Generic, not
# lock-specific — reusable by anything that needs to layer one more EXIT
# action on top of one that might already exist.
wb_lock_trap_append() {
  local new_cmd="$1"
  if [ -z "$new_cmd" ]; then
    echo "wb lock: wb_lock_trap_append requires a cleanup command" >&2
    return 1
  fi

  local prev_trap prev_cmd=""
  prev_trap="$(trap -p EXIT)"
  if [ -n "$prev_trap" ]; then
    # `trap -p EXIT` prints: trap -- '<cmd>' EXIT — <cmd> is single-quoted
    # with any embedded single quotes already shell-escaped, so stripping
    # the fixed "trap -- " prefix and " EXIT" suffix leaves a well-formed
    # single-quoted string; `eval` un-quotes it back into a plain variable
    # without us hand-parsing quoting ourselves.
    local quoted="${prev_trap#trap -- }"
    quoted="${quoted% EXIT}"
    eval "prev_cmd=$quoted"
  fi

  if [ -n "$prev_cmd" ]; then
    trap "$prev_cmd
$new_cmd" EXIT
  else
    trap "$new_cmd" EXIT
  fi
}

# wb_task_lock_release_all — closes every fd this process currently holds
# open via wb_task_lock_acquire. The ready-made safety-net body callers
# wire up via `wb_lock_trap_append wb_task_lock_release_all` — a backstop
# for a burst that forgot its own explicit release; kernel auto-release on
# process death is the final backstop behind even this.
wb_task_lock_release_all() {
  _wb_lock_init_state
  local lockfile fd
  for lockfile in "${!WB_LOCK_FDS[@]}"; do
    fd="${WB_LOCK_FDS[$lockfile]}"
    { exec {fd}<&-; } 2>/dev/null || true
    unset "WB_LOCK_FDS[$lockfile]"
  done
  return 0
}
