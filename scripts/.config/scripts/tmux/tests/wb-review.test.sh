#!/usr/bin/env bash
# Tests for `wb review [--no-open] [--task] [<task>]` (wb-diff-viewer plan U7)
# and the picker's `v` key and prefix+R binding. Plain-bash assertions like
# wb-page.test.sh: wb.sh is sourced and tmux, curl, the opener and the
# wb-store.sh shim are stubbed, so no real server, browser or Go build runs.
# Run: bash scripts/.config/scripts/tmux/tests/wb-review.test.sh
set -uo pipefail

WB="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/wb.sh"
TMUXCONF="$(cd "$(dirname "$WB")/../../../.." && pwd)/tmux/.config/tmux/tmux.conf"
FIXTURE="$(mktemp -d -t wb-review-fixture.XXXXXX)"
trap 'rm -rf "$FIXTURE"' EXIT

fail=0
assert() { # <desc> <expected-regex> <actual>
  if printf '%s' "$3" | grep -qE "$2"; then echo "ok   - $1"
  else echo "FAIL - $1"; echo "       expected match: $2"; echo "       got: $(printf '%s' "$3" | head -5)"; fail=1; fi
}
assert_eq() { # <desc> <expected> <actual>
  if [ "$2" = "$3" ]; then echo "ok   - $1"
  else echo "FAIL - $1"; echo "       expected: $2"; echo "       got:      $3"; fail=1; fi
}

export TASKS_DIR="$FIXTURE/tasks"; mkdir -p "$TASKS_DIR"
export CODE_DIR="$FIXTURE/code"
mkdir -p "$CODE_DIR/dotfiles/.worktrees/with-wt"
mk_task() { # <stem> <worktree-field>
  printf -- '---\nstatus: doing\nrepo: dotfiles\nworktree: %s\ntags: []\n---\n# %s\n' "$2" "$1" > "$TASKS_DIR/$1.md"
}
mk_task dotfiles--with-wt .worktrees/with-wt
mk_task dotfiles--no-field ""
mk_task dotfiles--gone-dir .worktrees/not-on-disk

BIN="$FIXTURE/wb-store"; printf 'fake wb-store build\n' > "$BIN"
BUILD_ID="$(sha256sum "$BIN" | cut -c1-12)"
SERVE_LOG="$FIXTURE/serve-calls"
SHIM="$FIXTURE/wb-store.sh"
cat > "$SHIM" <<STUB
#!/usr/bin/env bash
if [ "\$1" = --bin-path ]; then echo "$BIN"; exit 0; fi
echo "\$*" >> "$SERVE_LOG"
echo "wb-store review: http://127.0.0.1:8777/t/\${@: -1}"
STUB
chmod +x "$SHIM"
export WB_STORE_SHIM="$SHIM"
export XDG_STATE_HOME="$FIXTURE/state"

# shellcheck source=../wb.sh
source "$WB"
set +e

STUB_SESSION="dotfiles--with-wt"; STUB_TASK=""
tmux() {
  case "$*" in
    "display-message -p #S") printf '%s\n' "$STUB_SESSION" ;;
    *"-v @task")             [ -n "$STUB_TASK" ] && printf '%s\n' "$STUB_TASK" || return 1 ;;
    *"-v @wb_repo"|*"-v @wb_slug") return 1 ;;
    "display-message "*) printf '%s\n' "${*: -1}" >> "$FIXTURE/messages" ;;
    *) echo "UNSTUBBED tmux call: $*" >&2; return 1 ;;
  esac
}

# curl stub: only the ports in HEALTHZ answer, each with its own body.
declare -A HEALTHZ=()
curl() {
  local url="${*: -1}" port
  port="${url#http://127.0.0.1:}"; port="${port%%/*}"
  if [ -n "${HEALTHZ[$port]:-}" ]; then printf '%s\n' "${HEALTHZ[$port]}"; return 0; fi
  return 7
}
hz() { printf '{"app":"%s","build_id":"%s"}' "$1" "$2"; }

OPENED="$FIXTURE/opened"
_wb_review_open() { printf '%s\n' "$1" > "$OPENED"; }
PIDFILE="$XDG_STATE_HOME/wb/review-server.$(printf '%s' "$BIN" | cksum | cut -d ' ' -f 1).pid"
reset() { : > "$SERVE_LOG"; rm -f "$OPENED" "$PIDFILE" "$FIXTURE/messages"; HEALTHZ=(); STUB_TASK=""; }

echo "# a running review server with this build id is reused"
reset; HEALTHZ[8779]="$(hz wb-store-review "$BUILD_ID")"
out=$(cmd_review dotfiles--with-wt 2>&1); rc=$?
assert_eq "exit 0" 0 "$rc"
assert_eq "the task's review URL on the port that answered" "http://127.0.0.1:8779/t/dotfiles--with-wt" "$out"
assert_eq "opened it" "http://127.0.0.1:8779/t/dotfiles--with-wt" "$(cat "$OPENED" 2>/dev/null)"
assert_eq "started no second server" "" "$(cat "$SERVE_LOG")"

echo "# a page server on 8766 (app wb-store) is never taken for the review server"
reset; HEALTHZ[8766]="$(hz wb-store "$BUILD_ID")"
out=$(cmd_review --no-open dotfiles--with-wt 2>&1)
assert_eq "started a review server" "review --no-open --port 8776 dotfiles--with-wt" "$(cat "$SERVE_LOG")"
echo "# ... and a page server answering inside the review range is not taken either"
reset; HEALTHZ[8776]="$(hz wb-store "$BUILD_ID")"
cmd_review --no-open dotfiles--with-wt >/dev/null 2>&1
assert_eq "still started one" "review --no-open --port 8776 dotfiles--with-wt" "$(cat "$SERVE_LOG")"
echo "# a review server of another build is not reused"
reset; HEALTHZ[8776]="$(hz wb-store-review 0123456789ab)"
cmd_review --no-open dotfiles--with-wt >/dev/null 2>&1
assert_eq "started a new one" "review --no-open --port 8776 dotfiles--with-wt" "$(cat "$SERVE_LOG")"

echo "# nothing running: start the server, read its port from the log, open /t/<stem>"
reset
out=$(cmd_review dotfiles--with-wt 2>&1); rc=$?
assert_eq "exit 0" 0 "$rc"
assert_eq "URL from the server's first line" "http://127.0.0.1:8777/t/dotfiles--with-wt" "$out"
assert_eq "opened it" "http://127.0.0.1:8777/t/dotfiles--with-wt" "$(cat "$OPENED" 2>/dev/null)"
assert "recorded the server's pid" '^[0-9]+$' "$(cat "$PIDFILE" 2>/dev/null)"
assert "logged under wb's state directory" "wb-store review: http://127.0.0.1:8777/" "$(cat "$XDG_STATE_HOME/wb/review-server.log")"

echo "# a task without a worktree: one-line refusal, nothing opened or started"
for t in dotfiles--no-field dotfiles--gone-dir; do
  reset
  out=$(cmd_review "$t" 2>&1); rc=$?
  assert_eq "$t: exit 1" 1 "$rc"
  assert_eq "$t: one line" 1 "$(printf '%s\n' "$out" | wc -l | tr -d ' ')"
  assert "$t: says it has no worktree" "^wb review: .*no worktree" "$out"
  assert_eq "$t: opened nothing" no "$([ -f "$OPENED" ] && echo yes || echo no)"
  assert_eq "$t: started nothing" "" "$(cat "$SERVE_LOG")"
done

echo "# inside a task session with no argument: the session's @task"
reset; export TMUX=fake STUB_TASK="$TASKS_DIR/dotfiles--with-wt.md"
HEALTHZ[8776]="$(hz wb-store-review "$BUILD_ID")"
out=$(cmd_review --no-open 2>&1); rc=$?
assert_eq "exit 0" 0 "$rc"
assert_eq "that task's page" "http://127.0.0.1:8776/t/dotfiles--with-wt" "$out"
echo "# the prefix+R form: --task with the session's @task, or empty"
out=$(cmd_review --no-open --task "$TASKS_DIR/dotfiles--with-wt.md" 2>&1)
assert_eq "a full @task path resolves" "http://127.0.0.1:8776/t/dotfiles--with-wt" "$out"
out=$(cmd_review --no-open --task "" 2>&1)
assert_eq "an empty ref falls back to @task" "http://127.0.0.1:8776/t/dotfiles--with-wt" "$out"
STUB_TASK=""
out=$(cmd_review --no-open --task "" 2>&1); rc=$?
assert_eq "no @task either: exit 1" 1 "$rc"
assert "names the session" "has no @task" "$out"
unset TMUX
out=$(cmd_review 2>&1); rc=$?
assert_eq "outside tmux, no task: exit 1" 1 "$rc"
assert "says to pass a task" "not inside tmux" "$out"

echo "# the picker verb _review: needs a task file; failures show as a tmux message"
reset; export TMUX=fake
out=$(bash "$WB" _review "" 2>&1); rc=$?
assert_eq "empty row ref: exit 0 (the picker stays up)" 0 "$rc"

echo "# the picker's v binding calls _review with the row's task file (field 9)"
assert "v is bound to _review {9}" '"v:execute-silent\(.*_review \{9\}' "$(grep -n '"v:execute-silent' "$WB")"
assert "v is among the keys search mode unbinds" "local navkeys='[^']*,v[,']" "$(grep -n "local navkeys=" "$WB")"
assert "no other picker bind uses v" '^1$' "$(grep -c -E -- '--bind "v:|--bind .v:' "$WB")"
hint_plain="$(wb_status_line normal live | sed -n 3p | sed -e $'s/\033\\[[0-9;]*m//g')"
assert "the legend lists v review" 'v review' "$hint_plain"
assert "the legend stays within 120 columns" '^.{1,120}$' "$hint_plain"
assert "wb help lists wb review" '^ +wb review ' "$(cmd_help)"

echo "# prefix+R opens this session's review page, like prefix+P"
assert "R is bound to wb review --task with the session's @task" "^bind R run-shell -b '.*wb\.sh review --task \"#\{@task\}\".*tmux display-message" "$(grep -E '^bind R ' "$TMUXCONF")"
assert_eq "R is bound once" 1 "$(grep -c -E '^bind R ' "$TMUXCONF")"

exit "$fail"
