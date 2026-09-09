#!/usr/bin/env bash
# open-buffer.sh — the bundled tmux open/wait/reattach/fallback recipe for
# the decision-buffer skill (and anything else that needs a blocking,
# agent-resumable nvim buffer: wb-done, parked-items, wb-breakdown,
# wb-jira-create, wb_open_buffer() in wb.sh).
#
# One executable implementation instead of the recipe copied as prose in
# five places (dotfiles roadmap R15). See references/mechanism.md for the
# full state-file field contract, the fallback-tier rationale, and the
# reattach decision tree — this header only summarizes the CLI surface.
#
# Starting point: wb_open_buffer() in
# scripts/.config/scripts/tmux/wb.sh:2785-2803 (the tmux-split + wait-for
# recipe + the WB_REVIEW_BUFFER=1 format-on-save-skip signal). Convention
# borrowed from scripts/.config/scripts/tmux/claude-notify-hook.sh: a
# script other tools depend on should fail loudly on usage errors but never
# hang — every blocking path here is a single tmux wait-for, never a poll
# loop.
#
# Usage:
#   open-buffer.sh [--tmux] <path>     tmux split + wait-for (default mode)
#   open-buffer.sh --terminal <path>   gnome-terminal --wait fallback
#   open-buffer.sh --direct <path>     synchronous ${EDITOR:-nvim}, blocks
#                                       the calling shell, NO state file
#   open-buffer.sh --manual <path>     print a copyable "! nvim <path>"
#                                       command; does not block
#   open-buffer.sh --reattach <path>   resume the wait recorded by an
#                                       earlier --tmux open of the same path
#
# IMPORTANT (R17): run the --tmux/--terminal/--manual/--reattach modes in
# the BACKGROUND from the calling agent (Bash run_in_background: true).
# They block until the buffer closes; a foregrounded call would eat the
# tool-call timeout. --direct is the one mode meant to run synchronously
# in the foreground — it matches wb.sh's own non-agent callers, which
# already block on it today.
#
# Exit codes: 0 on a normal close, a treated-as-closed reattach outcome, or
# a manual-mode print. Non-zero only for usage errors (2) and the
# already-waiting / nothing-to-reattach / reattach-outside-tmux refusals
# (1) — never for "buffer closed with ticks unresolved", which is a
# parsing question for the caller, not this script's concern.

set -uo pipefail

SCRIPT_NAME="$(basename "$0")"

usage() {
  cat <<EOF
Usage:
  $SCRIPT_NAME [--tmux] <path>     open in a tmux split, block until closed
  $SCRIPT_NAME --terminal <path>   open in a spawned terminal, block until closed
  $SCRIPT_NAME --direct <path>     open synchronously in this shell, no state file
  $SCRIPT_NAME --manual <path>     print a copyable "! nvim <path>" command
  $SCRIPT_NAME --reattach <path>   resume a wait recorded by an earlier --tmux open

See references/mechanism.md for the state-file contract and the reattach
decision tree.
EOF
}

# ---------------------------------------------------------------------------
# state file helpers
# ---------------------------------------------------------------------------

# state_path_for <doc-path> -> the state file path beside the document.
state_path_for() {
  printf '%s.buffer-state' "$1"
}

# abs_path <path> -> best-effort absolute form (no readlink -f dependency —
# not portable across macOS/Linux). Callers are expected to pass an
# already-absolute path (every skill that drives this script writes one);
# this is only a defensive fallback for a relative one.
abs_path() {
  case "$1" in
    /*) printf '%s' "$1" ;;
    *) printf '%s/%s' "$(pwd)" "$1" ;;
  esac
}

# hash_doc <path> -> sha256 of the file's current content, or "nohash" if
# neither sha256sum (Linux) nor shasum (macOS) is available. "nohash"
# never matches a prior hash, so reopen_count degrades to always-reset
# (undercounts reopens rather than overcounting — the safe direction,
# since the three-reopen cap exists to stop endless silent reopening, not
# to under-tolerate a slow user).
hash_doc() {
  local f="$1"
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$f" 2>/dev/null | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$f" 2>/dev/null | awk '{print $1}'
  else
    printf 'nohash'
  fi
}

# pid_alive <pid> -> true if a process with that pid exists (best-effort:
# pid recycling by the OS can produce a false positive; see mechanism.md).
pid_alive() {
  [ -n "${1:-}" ] && kill -0 "$1" 2>/dev/null
}

# gen_chan -> a wait-channel name unique to this invocation. Never reuse a
# fixed name: tmux wait-for latches an unclaimed signal, so a stale signal
# on a shared channel makes the next wait-for on it return instantly.
gen_chan() {
  printf 'decision-buffer-done-%s-%s' "$$" "$RANDOM"
}

STATE_CHAN=""
STATE_PANE_ID=""
STATE_MODE=""
STATE_OPENED_AT=""
STATE_CALLER_PID=""
STATE_CONTENT_HASH=""
STATE_REOPEN_COUNT=0

# read_state <state-file> -> populates STATE_* globals, returns 1 if the
# file doesn't exist. Parsed field-by-field (not sourced) even though
# every field is script-generated and currently safe to source — parsing
# keeps it that way if a future field ever carries freeform text.
read_state() {
  local sf="$1" key val
  STATE_CHAN="" STATE_PANE_ID="" STATE_MODE="" STATE_OPENED_AT=""
  STATE_CALLER_PID="" STATE_CONTENT_HASH="" STATE_REOPEN_COUNT=0
  [ -f "$sf" ] || return 1
  while IFS='=' read -r key val; do
    case "$key" in
      chan) STATE_CHAN="$val" ;;
      pane_id) STATE_PANE_ID="$val" ;;
      mode) STATE_MODE="$val" ;;
      opened_at) STATE_OPENED_AT="$val" ;;
      caller_pid) STATE_CALLER_PID="$val" ;;
      content_hash) STATE_CONTENT_HASH="$val" ;;
      reopen_count) STATE_REOPEN_COUNT="$val" ;;
    esac
  done < "$sf"
  return 0
}

# write_state <state-file> <chan> <pane_id> <mode> <caller_pid> <hash> <reopen_count>
# Every field is overwritten unconditionally except reopen_count, whose
# carry-forward value is computed by the caller (prepare_open, below)
# before write_state is invoked — write_state itself just writes whatever
# it's given.
write_state() {
  local sf="$1" chan="$2" pane_id="$3" mode="$4" caller_pid="$5" hash="$6" reopen="$7"
  {
    printf 'chan=%s\n' "$chan"
    printf 'pane_id=%s\n' "$pane_id"
    printf 'mode=%s\n' "$mode"
    printf 'opened_at=%s\n' "$(date +%s)"
    printf 'caller_pid=%s\n' "$caller_pid"
    printf 'content_hash=%s\n' "$hash"
    printf 'reopen_count=%s\n' "$reopen"
  } > "$sf"
}

# prepare_open <path> -> sets OPEN_HASH and OPEN_REOPEN for a fresh open of
# <path>, in every mode that writes a state file (tmux, terminal, manual).
# Exits 1 ("already waiting") if a live process still holds the prior
# state file for this path — this is the duplicate-waiter guard, checked
# BEFORE the state file is overwritten, so a live waiter's file is never
# clobbered out from under it. Any other prior state file (stale
# caller_pid, or none at all) is unconditionally superseded by the fresh
# open that follows (R16) — never reused as a signal source.
OPEN_HASH=""
OPEN_REOPEN=0
prepare_open() {
  local path="$1" sf
  sf="$(state_path_for "$path")"
  OPEN_HASH="$(hash_doc "$path")"
  OPEN_REOPEN=0
  if read_state "$sf"; then
    if pid_alive "$STATE_CALLER_PID"; then
      echo "$SCRIPT_NAME: already waiting on $path (pid $STATE_CALLER_PID, chan $STATE_CHAN, mode $STATE_MODE) — not starting a second wait" >&2
      exit 1
    fi
    if [ "$OPEN_HASH" != "nohash" ] && [ "$STATE_CONTENT_HASH" = "$OPEN_HASH" ]; then
      OPEN_REOPEN=$((STATE_REOPEN_COUNT + 1))
    fi
  fi
}

# ---------------------------------------------------------------------------
# modes
# ---------------------------------------------------------------------------

mode_tmux() {
  local path sf chan pane_id
  path="$(abs_path "$1")"

  if [ -z "${TMUX:-}" ]; then
    echo "$SCRIPT_NAME: not inside tmux — use --terminal, --direct, or --manual" >&2
    exit 2
  fi

  prepare_open "$path"
  sf="$(state_path_for "$path")"
  chan="$(gen_chan)"

  tmux set -p -t "$TMUX_PANE" @claude_blocked nvim-buffer 2>/dev/null || true

  pane_id="$(tmux split-window -h -P -F '#{pane_id}' -t "$TMUX_PANE" \
    "WB_REVIEW_BUFFER=1 ${EDITOR:-nvim} '$path'; tmux wait-for -S $chan")"

  write_state "$sf" "$chan" "$pane_id" "tmux" "$$" "$OPEN_HASH" "$OPEN_REOPEN"

  tmux wait-for "$chan"
  tmux set -pu -t "$TMUX_PANE" @claude_blocked 2>/dev/null || true
  rm -f "$sf"
  exit 0
}

mode_terminal() {
  local path sf rc
  path="$(abs_path "$1")"

  if ! command -v gnome-terminal >/dev/null 2>&1; then
    echo "$SCRIPT_NAME: gnome-terminal not found — use --manual instead" >&2
    exit 2
  fi

  prepare_open "$path"
  sf="$(state_path_for "$path")"

  # No pane to record — a spawned terminal isn't a tmux pane, so there is
  # nothing for --reattach to find later (R16: "a process id in the
  # terminal case, nothing to re-attach to"). pane_id stays empty.
  write_state "$sf" "" "" "terminal" "$$" "$OPEN_HASH" "$OPEN_REOPEN"

  # Best-effort only: terminal mode runs when there's usually no tmux
  # pane to mark, but if this agent does happen to have one (e.g. tmux is
  # present but a split isn't viable), mark it the same way tmux mode does.
  [ -n "${TMUX_PANE:-}" ] && tmux set -p -t "$TMUX_PANE" @claude_blocked nvim-buffer 2>/dev/null

  gnome-terminal --wait -- "${EDITOR:-nvim}" "$path"
  rc=$?

  [ -n "${TMUX_PANE:-}" ] && tmux set -pu -t "$TMUX_PANE" @claude_blocked 2>/dev/null
  rm -f "$sf"
  exit "$rc"
}

mode_manual() {
  local path sf
  path="$(abs_path "$1")"

  prepare_open "$path"
  sf="$(state_path_for "$path")"

  # Nothing this script can wait on — the human runs the editor themselves
  # in their own shell. State file records only that a manual handoff was
  # offered (caller_pid, hash, reopen_count); chan/pane_id stay empty.
  write_state "$sf" "" "" "manual" "$$" "$OPEN_HASH" "$OPEN_REOPEN"

  cat <<EOF
$SCRIPT_NAME: no tmux and no terminal spawn available. Run this yourself:

! ${EDITOR:-nvim} $path

Closing it returns control to the agent.
EOF
  exit 0
}

mode_direct() {
  local path="$1"
  # No state file, no @claude_blocked (R16) — matches wb_open_buffer()'s
  # existing non-tmux branch (wb.sh:2800-2802) exactly, for wb.sh's own
  # non-agent callers (wb reconcile --review, sweep-review call sites)
  # that block synchronously and were never agent-driven.
  WB_REVIEW_BUFFER=1 "${EDITOR:-nvim}" "$path"
}

mode_reattach() {
  local path sf pane_id found pane_cmd pid cmd
  path="$(abs_path "$1")"
  sf="$(state_path_for "$path")"

  if ! read_state "$sf"; then
    echo "$SCRIPT_NAME: nothing to reattach for $path (no state file)" >&2
    exit 1
  fi

  if [ "$STATE_MODE" != "tmux" ]; then
    echo "$SCRIPT_NAME: reattach not supported outside tmux (recorded mode: $STATE_MODE)" >&2
    exit 1
  fi

  if pid_alive "$STATE_CALLER_PID"; then
    echo "$SCRIPT_NAME: already waiting on $path (pid $STATE_CALLER_PID, chan $STATE_CHAN) — not starting a second wait" >&2
    exit 1
  fi

  if [ -z "${TMUX:-}" ]; then
    echo "$SCRIPT_NAME: reattach requires being inside tmux" >&2
    exit 1
  fi

  found=0
  pane_cmd=""
  while IFS=' ' read -r pid cmd; do
    if [ "$pid" = "$STATE_PANE_ID" ]; then
      found=1
      pane_cmd="$cmd"
      break
    fi
  done < <(tmux list-panes -a -F '#{pane_id} #{pane_current_command}' 2>/dev/null)

  if [ "$found" -ne 1 ]; then
    # PaneGone: the recorded pane no longer exists. Do not wait — the
    # close was not deliberate. Report and let the caller read the
    # document on disk as found; any ticks/notes are "on disk,
    # unconfirmed" until Jet says otherwise (R18).
    echo "$SCRIPT_NAME: recorded pane $STATE_PANE_ID is gone — reading $path as found, not waiting (close was not deliberate)" >&2
    rm -f "$sf"
    exit 0
  fi

  if [ "$pane_cmd" != "nvim" ]; then
    # CLOSED_NO_SIGNAL: the pane is alive but nvim already exited (e.g.
    # the wait-for signal was lost). Treat exactly like a normal close.
    echo "$SCRIPT_NAME: recorded pane $STATE_PANE_ID is alive but not running nvim (command: $pane_cmd) — treating as already closed" >&2
    rm -f "$sf"
    exit 0
  fi

  # Pane alive and still running nvim: the background wait died for some
  # other reason (e.g. its process was killed). Re-attach to the SAME
  # recorded channel rather than opening a second buffer (R18).
  echo "$SCRIPT_NAME: re-attaching to $path — recorded pane $STATE_PANE_ID is still open in nvim" >&2
  tmux set -p -t "$TMUX_PANE" @claude_blocked nvim-buffer 2>/dev/null || true
  tmux wait-for "$STATE_CHAN"
  tmux set -pu -t "$TMUX_PANE" @claude_blocked 2>/dev/null || true
  rm -f "$sf"
  exit 0
}

# ---------------------------------------------------------------------------
# dispatch
# ---------------------------------------------------------------------------

MODE="tmux"
case "${1:-}" in
  --tmux) MODE="tmux"; shift ;;
  --terminal) MODE="terminal"; shift ;;
  --direct) MODE="direct"; shift ;;
  --manual) MODE="manual"; shift ;;
  --reattach) MODE="reattach"; shift ;;
  -h|--help) usage; exit 0 ;;
  --*) echo "$SCRIPT_NAME: unknown flag: $1" >&2; usage >&2; exit 2 ;;
  *) MODE="tmux" ;;
esac

TARGET="${1:-}"
if [ -z "$TARGET" ]; then
  echo "$SCRIPT_NAME: missing <path>" >&2
  usage >&2
  exit 2
fi

case "$MODE" in
  tmux) mode_tmux "$TARGET" ;;
  terminal) mode_terminal "$TARGET" ;;
  direct) mode_direct "$TARGET" ;;
  manual) mode_manual "$TARGET" ;;
  reattach) mode_reattach "$TARGET" ;;
esac
