#!/usr/bin/env bash
# Tests for `wb page [--no-open] [<task>]` (W12, plan U9) — plain-bash
# assertions, same convention as wb-task-file.test.sh. Sources wb.sh and
# stubs tmux, curl (the /healthz probe), the browser opener and the
# wb-store.sh shim, so no real server, browser or Go build is involved.
# Run: bash scripts/.config/scripts/tmux/tests/wb-page.test.sh
set -uo pipefail

WB="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/wb.sh"
FIXTURE="$(mktemp -d -t wb-page-fixture.XXXXXX)"
trap 'rm -rf "$FIXTURE"' EXIT

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

# A made-up store: a root with one child, and a leaf with no family.
export TASKS_DIR="$FIXTURE/tasks"; mkdir -p "$TASKS_DIR"
mk_task() { # <stem> [<parent>]
  printf -- '---\nstatus: doing\nrepo: dotfiles\nparent: %s\ntags: []\n---\n# %s\n' "${2:-}" "$1" > "$TASKS_DIR/$1.md"
}
mk_task dotfiles--season
mk_task dotfiles--season-child dotfiles--season
mk_task dotfiles--lone

# The shim stub: --bin-path prints a fake binary (its SHA-256 is the build
# id); serve records its args and prints the URL line a real serve prints.
BIN="$FIXTURE/wb-store"; printf 'fake wb-store build\n' > "$BIN"
BUILD_ID="$(sha256sum "$BIN" | cut -c1-12)"
SERVE_LOG="$FIXTURE/serve-calls"
SHIM="$FIXTURE/wb-store.sh"
cat > "$SHIM" <<STUB
#!/usr/bin/env bash
if [ "\$1" = --bin-path ]; then echo "$BIN"; exit 0; fi
echo "\$*" >> "$SERVE_LOG"
echo "wb-store serve: http://127.0.0.1:8768/task/\${@: -1}"
STUB
chmod +x "$SHIM"
export WB_STORE_SHIM="$SHIM"
export XDG_STATE_HOME="$FIXTURE/state"

# shellcheck source=../wb.sh
source "$WB"
set +e   # wb.sh sets -e; the failure cases below must not end the script

# tmux stub: the current session and its @task.
STUB_SESSION="dotfiles--season-child"
STUB_TASK=""
tmux() {
  case "$*" in
    "display-message -p #S") printf '%s\n' "$STUB_SESSION" ;;
    *"-v @task")             [ -n "$STUB_TASK" ] && printf '%s\n' "$STUB_TASK" || return 1 ;;
    *"-v @wb_repo"|*"-v @wb_slug") return 1 ;;
    *) echo "UNSTUBBED tmux call: $*" >&2; return 1 ;;
  esac
}

# curl stub: /healthz answers on HEALTHZ_PORT with HEALTHZ_ID; every other
# port refuses.
# HEALTHZ_BODY, when set, replaces the body (to vary its JSON layout).
HEALTHZ_PORT=""; HEALTHZ_ID=""; HEALTHZ_BODY=""
curl() {
  local url="${*: -1}"
  if [ -n "$HEALTHZ_PORT" ] && [ "$url" = "http://127.0.0.1:$HEALTHZ_PORT/healthz" ]; then
    if [ -n "$HEALTHZ_BODY" ]; then printf '%s\n' "$HEALTHZ_BODY"
    else printf '{"app":"wb-store","build_id":"%s"}\n' "$HEALTHZ_ID"; fi
    return 0
  fi
  return 7
}

OPENED="$FIXTURE/opened"
_wb_page_open() { printf '%s\n' "$1" > "$OPENED"; }

reset() {
  : > "$SERVE_LOG"; rm -f "$OPENED" "$PIDFILE"
  HEALTHZ_PORT=""; HEALTHZ_ID=""; HEALTHZ_BODY=""; STUB_TASK=""; WB_PAGE_PORT=8766
}

# Where cmd_page records the server it started from $BIN.
PIDFILE="$XDG_STATE_HOME/wb/page-server.$(printf '%s' "$BIN" | cksum | cut -d ' ' -f 1).pid"

# A long-running stand-in for an old server, named wb-store as the real
# binary is (cmd_page checks the name before it kills a recorded pid).
mkdir -p "$FIXTURE/old"; cp "$(command -v sleep)" "$FIXTURE/old/wb-store"

# =============================================================================
echo "# inside a session whose @task is a child task: that child's page"
reset; export TMUX=fake STUB_TASK="$TASKS_DIR/dotfiles--season-child.md"
HEALTHZ_PORT=8766; HEALTHZ_ID="$BUILD_ID"
out=$(cmd_page 2>&1); rc=$?
assert_eq "exit 0" 0 "$rc"
assert_eq "the child's task page on the running server" "http://127.0.0.1:8766/task/dotfiles--season-child" "$out"
assert_eq "opened it" "http://127.0.0.1:8766/task/dotfiles--season-child" "$(cat "$OPENED" 2>/dev/null)"
assert_eq "started no server" "" "$(cat "$SERVE_LOG")"

# =============================================================================
echo "# a task ref passes through; a task with children opens its family page"
reset; HEALTHZ_PORT=8770; HEALTHZ_ID="$BUILD_ID"
out=$(cmd_page --no-open dotfiles--season 2>&1); rc=$?
assert_eq "exit 0" 0 "$rc"
assert_eq "the family page, on the port that answered" "http://127.0.0.1:8770/family/dotfiles--season" "$out"
assert_eq "--no-open opens nothing" no "$([ -f "$OPENED" ] && echo yes || echo no)"
out=$(cmd_page --no-open dotfiles--lone 2>&1)
assert_eq "a leaf task opens its task page" "http://127.0.0.1:8770/task/dotfiles--lone" "$out"

# =============================================================================
echo "# a server of another build: start a new one"
reset; HEALTHZ_PORT=8766; HEALTHZ_ID="0123456789ab"
out=$(cmd_page --no-open dotfiles--lone 2>&1); rc=$?
assert_eq "exit 0" 0 "$rc"
assert_eq "the new server's URL, from its first line" "http://127.0.0.1:8768/task/dotfiles--lone" "$out"
assert_eq "started serve --no-open from the first port, for the task" "serve --no-open --port 8766 dotfiles--lone" "$(cat "$SERVE_LOG")"
assert "recorded the server's pid" '^[0-9]+$' "$(cat "$PIDFILE" 2>/dev/null)"
assert "logged to wb's state directory" "wb-store serve: http://127.0.0.1:8768/" "$(cat "$XDG_STATE_HOME/wb/page-server.log")"

echo "# no server at all: start one"
reset
out=$(cmd_page --no-open dotfiles--lone 2>&1)
assert_eq "started one" "serve --no-open --port 8766 dotfiles--lone" "$(cat "$SERVE_LOG")"

# =============================================================================
echo "# a /healthz body with other field order and spacing still matches"
reset; HEALTHZ_PORT=8766; HEALTHZ_BODY="{ \"build_id\": \"$BUILD_ID\", \"app\": \"wb-store\" }"
out=$(cmd_page --no-open dotfiles--lone 2>&1)
assert_eq "reused it" "http://127.0.0.1:8766/task/dotfiles--lone" "$out"
assert_eq "started no server" "" "$(cat "$SERVE_LOG")"
reset; HEALTHZ_PORT=8766; HEALTHZ_BODY="{\"app\":\"other\",\"build_id\":\"$BUILD_ID\"}"
cmd_page --no-open dotfiles--lone >/dev/null 2>&1
assert_eq "another app with the same id isn't reused" "serve --no-open --port 8766 dotfiles--lone" "$(cat "$SERVE_LOG")"

echo "# WB_PAGE_PORT moves both the probe and serve's --port"
reset; WB_PAGE_PORT=9100; HEALTHZ_PORT=9109; HEALTHZ_ID="$BUILD_ID"
out=$(cmd_page --no-open dotfiles--lone 2>&1)
assert_eq "probed up to the tenth port" "http://127.0.0.1:9109/task/dotfiles--lone" "$out"
reset; WB_PAGE_PORT=9100; HEALTHZ_PORT=9110; HEALTHZ_ID="$BUILD_ID"
cmd_page --no-open dotfiles--lone >/dev/null 2>&1
assert_eq "not past it; serve starts from WB_PAGE_PORT" "serve --no-open --port 9100 dotfiles--lone" "$(cat "$SERVE_LOG")"

# =============================================================================
echo "# an older server this binary path started: stopped before a new one starts"
reset; HEALTHZ_PORT=8766; HEALTHZ_ID="0123456789ab"
"$FIXTURE/old/wb-store" 300 & old=$!
mkdir -p "$(dirname "$PIDFILE")"; echo "$old" > "$PIDFILE"
cmd_page --no-open dotfiles--lone >/dev/null 2>&1
# Poll rather than `wait`: if the stop regresses, this fails in ~2 s
# instead of blocking on the 300 s stand-in. A killed child is a zombie
# until reaped, so reap it once kill has landed.
for _ in $(seq 1 40); do
  [ "$(ps -p "$old" -o stat= 2>/dev/null | cut -c1)" = Z ] && break
  kill -0 "$old" 2>/dev/null || break
  command sleep 0.05
done
case "$(ps -p "$old" -o stat= 2>/dev/null | cut -c1)" in Z|'') state=gone ;; *) state=alive ;; esac
assert_eq "the old server is gone" gone "$state"
kill "$old" 2>/dev/null; wait "$old" 2>/dev/null
assert "the pidfile names the new server" '^[0-9]+$' "$(cat "$PIDFILE" 2>/dev/null)"
assert_eq "not the old pid" yes "$([ "$(cat "$PIDFILE")" != "$old" ] && echo yes || echo no)"

echo "# a recorded pid that is no longer wb-store: left alone"
reset
command sleep 300 & other=$!
mkdir -p "$(dirname "$PIDFILE")"; echo "$other" > "$PIDFILE"
cmd_page --no-open dotfiles--lone >/dev/null 2>&1
assert_eq "the other process still runs" alive "$(kill -0 "$other" 2>/dev/null && echo alive || echo gone)"
kill "$other" 2>/dev/null; wait "$other" 2>/dev/null

# =============================================================================
echo "# outside tmux with no task: usage, exit 1"
reset; unset TMUX
out=$(cmd_page 2>&1); rc=$?
assert_eq "exit 1" 1 "$rc"
assert "says to pass a task, with usage" "not inside tmux.*usage: wb page" "$(printf '%s' "$out" | tr '\n' ' ')"

echo "# a session with no @task: not a wb task session"
reset; export TMUX=fake
out=$(cmd_page 2>&1); rc=$?
assert_eq "exit 1" 1 "$rc"
assert "names the session" "dotfiles--season-child has no @task" "$out"

echo "# two task refs: usage"
out=$(cmd_page a b 2>&1); rc=$?
assert_eq "exit 1" 1 "$rc"
assert "prints usage" "^usage: wb page" "$out"

# =============================================================================
echo "# a missing shim: the stow hint, exit 1"
reset
out=$(WB_STORE_SHIM="$FIXTURE/nowhere/wb-store.sh" cmd_page dotfiles--lone 2>&1); rc=$?
assert_eq "exit 1" 1 "$rc"
assert "says to run stow" "no wb-store shim at .*run stow" "$out"

# =============================================================================
echo "# a server that never prints its URL: names the log"
reset
cat > "$FIXTURE/silent.sh" <<STUB
#!/usr/bin/env bash
if [ "\$1" = --bin-path ]; then echo "$BIN"; exit 0; fi
echo "no free port on 127.0.0.1 in 8766-8775: address already in use" >&2
exit 1
STUB
chmod +x "$FIXTURE/silent.sh"
# every port held by an older build, so serve has nowhere to bind
HEALTHZ_PORT=8766; HEALTHZ_ID="0123456789ab"
SLEEPS="$FIXTURE/sleeps"; : > "$SLEEPS"
sleep() { echo x >> "$SLEEPS"; command sleep 0.05; }
out=$(WB_STORE_SHIM="$FIXTURE/silent.sh" cmd_page --no-open dotfiles--lone 2>&1); rc=$?
unset -f sleep
assert_eq "exit 1" 1 "$rc"
assert "points at the log" "printed no URL; see .*/wb/page-server.log" "$out"
assert "shows the log's last lines" "no free port on 127.0.0.1" "$out"
assert_eq "stopped waiting once serve exited (well under 50 polls)" yes "$([ "$(wc -l < "$SLEEPS")" -lt 20 ] && echo yes || echo no)"
assert_eq "a dead server's pid isn't kept" no "$([ -f "$PIDFILE" ] && echo yes || echo no)"

exit "$fail"
