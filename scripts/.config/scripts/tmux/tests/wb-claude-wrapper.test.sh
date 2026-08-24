#!/usr/bin/env bash
# Regression coverage for the wb agent-isolation `claude()` wrapper in
# zsh/.zshrc (docs/plans/2026-08-24-001-feat-wb-session-cgroup-isolation-plan.md,
# U1+U2). The wrapper is zsh (uses `whence -p`, `[[ ]]`, `(( ))`), so rather
# than sourcing this bash driver against it, it's extracted from zsh/.zshrc
# (between the `wb-claude-wrapper:begin`/`:end` markers) and exercised via
# `zsh -c` per scenario — sourcing the whole .zshrc would trigger a network
# `zinit` clone on a cold cache and is unrelated to what's under test here.
#
# `tmux` and `systemd-run` are stubbed on PATH: the fake `tmux` answers only
# the three queries the wrapper makes (so no real tmux server is needed for
# most scenarios), and the fake `systemd-run` records its argv then execs the
# trailing command, so the invocation SHAPE can be asserted without a real
# systemd --user manager (the read-only Docker suite has none — see the
# plan's Test-harness-limitation risk; real cgroup behavior is covered by the
# manual verification checklist, not here). The final scenario is the
# exception: it needs a REAL tmux pane to assert `pane_current_command`,
# using the same isolated-private-socket + renamed-`sleep`-as-claude
# convention as lib-claude-panes.test.sh; it skips (not fails) when
# `systemd-run --user` isn't usable in the harness.
#
# Run: bash scripts/.config/scripts/tmux/tests/wb-claude-wrapper.test.sh
set -uo pipefail

ZSHRC="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../../.." && pwd)/zsh/.zshrc"
FUNC_SRC="$(sed -n '/# wb-claude-wrapper:begin/,/# wb-claude-wrapper:end/p' "$ZSHRC" | sed '1d;$d')"
if [ -z "$FUNC_SRC" ]; then
  echo "FAIL - could not extract claude() wrapper from $ZSHRC (markers missing or renamed?)"
  exit 1
fi

command -v zsh >/dev/null 2>&1 || { echo "FAIL - zsh not found on PATH; the wrapper under test is a zsh function"; exit 1; }

FIXTURE_BIN="$(mktemp -d -t wb-claude-wrapper-bin.XXXXXX)"
LOG_DIR="$(mktemp -d -t wb-claude-wrapper-log.XXXXXX)"
cleanup() { rm -rf "$FIXTURE_BIN" "$LOG_DIR"; }
trap cleanup EXIT

fail=0
assert_eq() { # <desc> <expected> <actual>
  if [ "$2" = "$3" ]; then
    echo "ok   - $1"
  else
    echo "FAIL - $1 (expected '$2', got '$3')"
    fail=1
  fi
}
assert_contains() { # <desc> <file> <needle>
  if [ -f "$2" ] && grep -qF -- "$3" "$2"; then
    echo "ok   - $1"
  else
    echo "FAIL - $1 (expected '$3' in $2)"
    fail=1
  fi
}
assert_matches() { # <desc> <file> <ere>
  if [ -f "$2" ] && grep -qE -- "$3" "$2"; then
    echo "ok   - $1"
  else
    echo "FAIL - $1 (expected a line matching /$3/ in $2)"
    fail=1
  fi
}
assert_empty_file() { # <desc> <file>
  if [ ! -s "$2" ]; then
    echo "ok   - $1"
  else
    echo "FAIL - $1 (expected $2 empty/absent, got: $(cat "$2" 2>/dev/null))"
    fail=1
  fi
}

# --- stub "the real claude binary" (what `command claude`/`whence -p claude`
#     must resolve to) -------------------------------------------------------
cat > "$FIXTURE_BIN/claude" <<'STUB'
#!/usr/bin/env bash
echo "real-claude-ran $*" >> "$WB_TEST_LOG_DIR/claude.log"
STUB
chmod +x "$FIXTURE_BIN/claude"

# --- stub systemd-run: record argv, then exec the trailing command ----------
# The trailing command is the absolute path `whence -p claude` resolved (this
# fixture's own claude stub) followed by the wrapped args; everything before
# it is systemd-run's own flags (--user --scope --quiet --unit=... -p ... -p
# ...), none of which start with '/'.
cat > "$FIXTURE_BIN/systemd-run" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$@" >> "$WB_TEST_LOG_DIR/systemd-run.argv"
args=("$@")
for i in "${!args[@]}"; do
  case "${args[$i]}" in
    /*) exec "${args[@]:$i}" ;;
  esac
done
exit 1
STUB
chmod +x "$FIXTURE_BIN/systemd-run"

# --- stub tmux: answers only the three queries the wrapper makes ------------
cat > "$FIXTURE_BIN/tmux" <<'STUB'
#!/usr/bin/env bash
case "$1 $2" in
  "show-options -qv")
    [ "${3:-}" = "@wb_repo" ] && printf '%s' "${FAKE_WB_REPO:-}"
    ;;
  "display-message -p")
    printf '%s' "${FAKE_SESSION_NAME:-testsess}"
    ;;
  "list-panes -a")
    printf '%s\n' "${FAKE_PANE_LIST:-}"
    ;;
  *)
    exit 1
    ;;
esac
STUB
chmod +x "$FIXTURE_BIN/tmux"

# run_claude <KEY=VAL>... — invokes `claude arg1 arg2` in a clean-env zsh with
# the extracted wrapper sourced first. Additional KEY=VAL pairs (TMUX,
# FAKE_WB_REPO, FAKE_SESSION_NAME, FAKE_PANE_LIST, WB_AGENT_*) layer onto the
# clean env before launch.
run_claude() {
  : > "$LOG_DIR/claude.log"
  : > "$LOG_DIR/systemd-run.argv"
  : > "$LOG_DIR/stderr.log"
  env -i HOME="$HOME" PATH="$FIXTURE_BIN:/usr/bin:/bin" WB_TEST_LOG_DIR="$LOG_DIR" "$@" \
    zsh -c "$FUNC_SRC"$'\n''claude arg1 arg2' 2>"$LOG_DIR/stderr.log"
}

echo "=== wb-claude-wrapper.test.sh ==="

# --- Passthrough, no tmux (R3) ----------------------------------------------
run_claude
assert_contains "passthrough/no-tmux: real claude ran directly" "$LOG_DIR/claude.log" "real-claude-ran arg1 arg2"
assert_empty_file "passthrough/no-tmux: systemd-run never invoked" "$LOG_DIR/systemd-run.argv"

# --- Passthrough, tmux but no @wb_repo (R3) ---------------------------------
run_claude TMUX=1
assert_contains "passthrough/no-wb_repo: real claude ran directly" "$LOG_DIR/claude.log" "real-claude-ran arg1 arg2"
assert_empty_file "passthrough/no-wb_repo: systemd-run never invoked" "$LOG_DIR/systemd-run.argv"

# --- Isolate, wb pane (R1, KTD5) ---------------------------------------------
run_claude TMUX=1 FAKE_WB_REPO=dotfiles FAKE_SESSION_NAME=testsess
assert_contains "isolate: systemd-run invoked with --scope" "$LOG_DIR/systemd-run.argv" "--scope"
assert_contains "isolate: systemd-run invoked with --user" "$LOG_DIR/systemd-run.argv" "--user"
assert_contains "isolate: default MemoryHigh=6G" "$LOG_DIR/systemd-run.argv" "MemoryHigh=6G"
assert_contains "isolate: default MemoryMax=8G" "$LOG_DIR/systemd-run.argv" "MemoryMax=8G"
assert_matches "isolate: --unit names the session" "$LOG_DIR/systemd-run.argv" '^--unit=wb-agent-testsess-[0-9]+$'
assert_contains "isolate: resolved absolute claude path, not literal 'command'" "$LOG_DIR/systemd-run.argv" "$FIXTURE_BIN/claude"
assert_contains "isolate: wrapped claude still ran (stub execs trailing cmd)" "$LOG_DIR/claude.log" "real-claude-ran arg1 arg2"

# --- Env override (R8) -------------------------------------------------------
run_claude TMUX=1 FAKE_WB_REPO=dotfiles WB_AGENT_MEM_MAX=4G
assert_contains "env override: MemoryMax reflects WB_AGENT_MEM_MAX=4G" "$LOG_DIR/systemd-run.argv" "MemoryMax=4G"

# --- Unit-name sanitization (R1 robustness) ----------------------------------
run_claude TMUX=1 FAKE_WB_REPO=dotfiles FAKE_SESSION_NAME='weird.name/here'
assert_matches "sanitize: --unit strips chars outside [A-Za-z0-9_-]" "$LOG_DIR/systemd-run.argv" '^--unit=wb-agent-weird-name-here-[0-9]+$'

# --- U2: below threshold, silent (R6) ---------------------------------------
run_claude TMUX=1 FAKE_WB_REPO=dotfiles FAKE_PANE_LIST=$'claude\nbash'
assert_empty_file "warn/below-threshold: no warning on stderr" "$LOG_DIR/stderr.log"

# --- U2: at threshold, warns but still starts (R6, KTD3) ---------------------
run_claude TMUX=1 FAKE_WB_REPO=dotfiles WB_AGENT_WARN_AT=2 FAKE_PANE_LIST=$'claude\nclaude'
assert_contains "warn/at-threshold: warning printed to stderr" "$LOG_DIR/stderr.log" "2 claude agents already running"
assert_contains "warn/at-threshold: agent still starts (systemd-run invoked)" "$LOG_DIR/systemd-run.argv" "--scope"

# --- U2: threshold override shifts where the warning fires (R8) -------------
run_claude TMUX=1 FAKE_WB_REPO=dotfiles WB_AGENT_WARN_AT=5 FAKE_PANE_LIST=$'claude\nclaude\nclaude\nbash'
assert_empty_file "warn/override-below: 3 agents < WARN_AT=5, silent" "$LOG_DIR/stderr.log"
run_claude TMUX=1 FAKE_WB_REPO=dotfiles WB_AGENT_WARN_AT=3 FAKE_PANE_LIST=$'claude\nclaude\nclaude\nbash'
assert_contains "warn/override-at: 3 agents == WARN_AT=3, warns" "$LOG_DIR/stderr.log" "3 claude agents already running"

# --- Detection contract (integration, R4): real tmux pane -------------------
# Needs a real `systemd-run --user` (no systemd user manager inside the
# read-only Docker suite) — skip with an explicit message rather than fail.
if systemd-run --user --scope --quiet true >/dev/null 2>&1; then
  REAL_TMUX="$(command -v tmux)"
  DETECT_BIN="$(mktemp -d -t wb-claude-wrapper-detect-bin.XXXXXX)"
  CLAUDE_STUB_DIR="$(mktemp -d -t wb-claude-wrapper-detect-claude.XXXXXX)"
  SOCK="wb-cw-sock-$$"
  SESSION="wb-cw-test-$$"

  cat > "$DETECT_BIN/tmux" <<EOF
#!/usr/bin/env bash
exec "$REAL_TMUX" -L "$SOCK" "\$@"
EOF
  chmod +x "$DETECT_BIN/tmux"
  cp "$(command -v sleep)" "$CLAUDE_STUB_DIR/claude"
  chmod +x "$CLAUDE_STUB_DIR/claude"

  FUNC_FILE="$LOG_DIR/wrapper.zsh"
  printf '%s\n' "$FUNC_SRC" > "$FUNC_FILE"

  detect_cleanup() {
    tmux -L "$SOCK" kill-server 2>/dev/null || true
    rm -rf "$DETECT_BIN" "$CLAUDE_STUB_DIR"
  }
  trap 'detect_cleanup; cleanup' EXIT

  PATH="$DETECT_BIN:$PATH" tmux new-session -d -s "$SESSION" -c /tmp "zsh -f"
  PANE="$(PATH="$DETECT_BIN:$PATH" tmux list-panes -t "=$SESSION" -F '#{session_name}:#{window_index}.#{pane_index}')"
  sleep 1
  PATH="$DETECT_BIN:$PATH" tmux set-option -t "=$SESSION:" @wb_repo dotfiles
  PATH="$DETECT_BIN:$PATH" tmux send-keys -t "$PANE" "source '$FUNC_FILE'" Enter
  sleep 1
  PATH="$DETECT_BIN:$PATH" tmux send-keys -t "$PANE" "PATH=\"$CLAUDE_STUB_DIR:\$PATH\" claude 300" Enter
  sleep 2

  pane_cmd="$(PATH="$DETECT_BIN:$PATH" tmux list-panes -t "=$SESSION" -F '#{pane_current_command}')"
  assert_eq "detection contract: pane_current_command reads 'claude' under real isolation" "claude" "$pane_cmd"

  detect_cleanup
  trap cleanup EXIT
else
  echo "ok   - (skipped) detection contract: systemd-run --user unavailable in this harness — covered by manual verification checklist instead"
fi

exit $fail
