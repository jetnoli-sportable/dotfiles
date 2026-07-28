#!/usr/bin/env bash
# Tests for `wb task-file [--edit]` — plain-bash assertions, same convention
# as wb-resume.test.sh. Sources wb.sh (safe: see the BASH_SOURCE guard at the
# bottom of wb.sh) and stubs `tmux` + the editor, so resolution is tested
# without a live tmux server or opening a real buffer.
# Run: bash scripts/.config/scripts/tmux/tests/wb-task-file.test.sh
set -uo pipefail

WB="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/wb.sh"
FIXTURE="$(mktemp -d -t wb-task-file-fixture.XXXXXX)"
EDITCALL_FILE="$(mktemp -t wb-task-file-editcall.XXXXXX)"
trap 'rm -rf "$FIXTURE" "$EDITCALL_FILE"' EXIT

fail=0
assert() { # <desc> <expected-regex> <actual>
  if printf '%s' "$3" | grep -qE "$2"; then
    echo "ok   - $1"
  else
    echo "FAIL - $1"
    echo "       expected match: $2"
    echo "       got: $(printf '%s' "$3" | head -5)"
    fail=1
  fi
}
assert_eq() { # <desc> <expected> <actual>
  if [ "$2" = "$3" ]; then
    echo "ok   - $1"
  else
    echo "FAIL - $1"
    echo "       expected: $2"
    echo "       got:      $3"
    fail=1
  fi
}

# Stub state, read by the tmux stub below.
STUB_SESSION="dotfiles--demo"
STUB_TASK=""       # what `tmux show -v @task` returns
STUB_REPO=""       # what `tmux show -v @wb_repo` returns
STUB_SLUG=""

# tmux stub — covers only the three forms cmd_task_file and
# wb_session_task_file actually invoke. Anything else returns 1 loudly rather
# than silently succeeding, so a future refactor that reaches for a new tmux
# call can't pass these tests by accident.
tmux() {
  case "$*" in
    "display-message -p #S") printf '%s\n' "$STUB_SESSION" ;;
    *"-v @task")             [ -n "$STUB_TASK" ] && printf '%s\n' "$STUB_TASK" || return 1 ;;
    *"-v @wb_repo")          [ -n "$STUB_REPO" ] && printf '%s\n' "$STUB_REPO" || return 1 ;;
    *"-v @wb_slug")          [ -n "$STUB_SLUG" ] && printf '%s\n' "$STUB_SLUG" || return 1 ;;
    *) echo "UNSTUBBED tmux call: $*" >&2; return 1 ;;
  esac
}

# Editor stub — records that --edit opened something, and what.
fake_editor() { printf '%s\n' "$1" > "$EDITCALL_FILE"; }

mk_task() { # <abs-file>
  printf -- '---\nstatus: doing\nrepo: dotfiles\nbranch: b\nworktree: .worktrees/x\ntags: []\ncreated: 2026-07-26\nclosed:\n---\n# Title\n\n## Plan\n\n## Handoffs\n' > "$1"
}

# run_tf [args...] — invokes cmd_task_file in a command substitution so its
# `return`s and any `exit` only affect that subshell. The editor stub writes to
# $EDITCALL_FILE because a subshell assignment can't escape back to us.
run_tf() {
  : > "$EDITCALL_FILE"
  out="$(EDITOR=fake_editor cmd_task_file "$@" 2>&1)"
  rc=$?
  edited="$(cat "$EDITCALL_FILE")"
}

# shellcheck disable=SC1090
source "$WB"
set +e   # wb.sh sets -e; this test intentionally captures non-zero exits
export -f fake_editor 2>/dev/null || true

echo "== wb task-file =="

# --- 1. happy path, print mode: @task wins and the path lands on stdout -----
TASK_A="$FIXTURE/dotfiles--demo.md"
mk_task "$TASK_A"
STUB_TASK="$TASK_A"; STUB_REPO=""; STUB_SLUG=""
TMUX="/tmp/fake-tmux-socket,1,0"
run_tf
assert_eq "print mode outputs exactly the @task path" "$TASK_A" "$out"
assert_eq "print mode exits 0" "0" "$rc"
assert_eq "print mode does NOT open an editor" "" "$edited"

# --- 2. --edit opens the resolved file (and prints nothing) -----------------
run_tf --edit
assert_eq "--edit opens the resolved task file" "$TASK_A" "$edited"
assert_eq "--edit exits 0" "0" "$rc"
assert_eq "--edit stays quiet on success" "" "$out"

# --- 3. not a wb session: no @task and no @wb_repo/@wb_slug ----------------
STUB_TASK=""; STUB_REPO=""; STUB_SLUG=""
run_tf
assert "no @task/@wb_repo reports 'not a wb task session'" "not a wb task session" "$out"
assert "the failure names the session" "dotfiles--demo" "$out"
assert_eq "no @task exits 1" "1" "$rc"
assert_eq "no @task opens no editor" "" "$edited"

# --- 4. @task points at a file that no longer exists ------------------------
# wb_session_task_file warns and falls through to repo/slug derivation; with
# no @wb_repo to fall back to, this must surface as a clean failure rather
# than a raw file-not-found.
STUB_TASK="$FIXTURE/gone.md"; STUB_REPO=""; STUB_SLUG=""
run_tf
assert "stale @task fails cleanly, not with a raw shell error" "(not a wb task session|no task file at)" "$out"
assert "stale @task failure is prefixed 'wb task-file:'" "^wb task-file:|wb task-file:" "$out"
assert_eq "stale @task exits 1" "1" "$rc"
assert_eq "stale @task opens no editor" "" "$edited"

# --- 5. repo/slug fallback resolves a path that doesn't exist on disk -------
# wb_session_task_file's fallback only BUILDS a path (wb_task_file) and never
# checks it — cmd_task_file's own -f test is what must catch this.
STUB_TASK=""; STUB_REPO="dotfiles"; STUB_SLUG="never-created-$$"
run_tf
assert "unresolvable repo/slug reports the missing path" "no task file at" "$out"
assert "and says where it came from" "resolved from dotfiles--demo" "$out"
assert_eq "missing fallback file exits 1" "1" "$rc"
assert_eq "missing fallback file opens no editor" "" "$edited"

# --- 6. outside tmux entirely ----------------------------------------------
STUB_TASK="$TASK_A"
unset TMUX
run_tf
assert "outside tmux reports there's no session" "not inside tmux" "$out"
assert_eq "outside tmux exits 1" "1" "$rc"
assert_eq "outside tmux opens no editor" "" "$edited"

# --- 7. the CLI dispatch arm exists ---------------------------------------
# Guards the wiring, not the function: a task-file case must be present in
# wb.sh's dispatch or the tmux bind silently falls through to the picker.
dispatch="$(grep -cE '^\s+task-file\)\s+shift; cmd_task_file' "$WB")"
assert_eq "wb.sh dispatches 'task-file' to cmd_task_file" "1" "$dispatch"

echo
if [ "$fail" = 0 ]; then
  echo "All wb task-file tests passed."
else
  echo "Some wb task-file tests FAILED."
fi
exit "$fail"
