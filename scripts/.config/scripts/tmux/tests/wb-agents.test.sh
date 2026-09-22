#!/usr/bin/env bash
# Tests for `wb agents` (cmd_agents): lists the claude() wrapper's wb-agent-*
# scopes and flags ORPHANs (no claude process left inside). Runs `bash wb.sh
# agents` as a real subprocess (the verb lives in the CLI dispatch, which the
# BASH_SOURCE guard skips when sourced) against a stub `systemctl` on PATH and
# fixture cgroup/proc trees via WB_CGROUP_ROOT/WB_PROC_ROOT — no systemd
# --user manager needed, and nothing real is ever stopped.
# Run: bash scripts/.config/scripts/tmux/tests/wb-agents.test.sh
set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WB="$SELF_DIR/wb.sh"

FIXTURE="$(mktemp -d -t wb-agents-fixture.XXXXXX)"
trap 'rm -rf "$FIXTURE"' EXIT

fail=0
assert() { # <desc> <expected-regex> <actual>
  if printf '%s' "$3" | grep -qE -- "$2"; then
    echo "ok   - $1"
  else
    echo "FAIL - $1"
    echo "       expected match: $2"
    echo "       got: $(printf '%s' "$3" | head -12)"
    fail=1
  fi
}
refute() { # <desc> <regex> <actual>
  if printf '%s' "$3" | grep -qE -- "$2"; then
    echo "FAIL - $1 (unexpected match: $2)"
    fail=1
  else
    echo "ok   - $1"
  fi
}
assert_eq() { # <desc> <expected> <actual>
  if [ "$2" = "$3" ]; then
    echo "ok   - $1"
  else
    echo "FAIL - $1 (expected '$2', got '$3')"
    fail=1
  fi
}

export XDG_STATE_HOME="$FIXTURE/state" HOME="$FIXTURE/home" CODE_DIR="$FIXTURE/code" TASKS_DIR="$FIXTURE/tasks"
mkdir -p "$XDG_STATE_HOME" "$HOME" "$CODE_DIR" "$TASKS_DIR"
unset TMUX

export WB_CGROUP_ROOT="$FIXTURE/cgroup" WB_PROC_ROOT="$FIXTURE/proc"
# mk_scope <unit> <pid:comm>... — a fixture cgroup whose cgroup.procs lists
# the pids; a pid given as "<pid>:" (no comm) has no /proc entry, i.e. it
# exited between the two reads.
mk_scope() {
  local unit="$1"; shift
  local dir="$WB_CGROUP_ROOT/user.slice/app.slice/$unit"
  mkdir -p "$dir"; : > "$dir/cgroup.procs"
  local pc
  for pc in "$@"; do
    echo "${pc%%:*}" >> "$dir/cgroup.procs"
    if [ -n "${pc#*:}" ]; then
      mkdir -p "$WB_PROC_ROOT/${pc%%:*}"; echo "${pc#*:}" > "$WB_PROC_ROOT/${pc%%:*}/comm"
    fi
  done
  echo "$unit" >> "$FIXTURE/units"
}
: > "$FIXTURE/units"
mk_scope wb-agent-dotfiles--live-100-1.scope 101:claude 102:github-mcp-serv 103:gopls 104:gopls
mk_scope wb-agent-dotfiles--orphan-200-2.scope 201:wl-copy
mk_scope wb-agent-be--monorepo--server-300-3.scope 301:go 302:match-tracker-a
mk_scope wb-agent-dotfiles--racy-400-4.scope 401:claude 402:

STUB_BIN="$FIXTURE/bin"; mkdir -p "$STUB_BIN"
SYSTEMCTL_CALLS="$FIXTURE/systemctl-calls"
cat > "$STUB_BIN/systemctl" <<STUB
#!/usr/bin/env bash
echo "\$*" >> "$SYSTEMCTL_CALLS"
case "\$*" in
  *list-units*) while read -r u; do printf '%s loaded active running Scope\n' "\$u"; done < "$FIXTURE/units" ;;
  *"show -p ControlGroup --value "*) printf '/user.slice/app.slice/%s\n' "\${@: -1}" ;;
  *) exit 1 ;;
esac
STUB
chmod +x "$STUB_BIN/systemctl"
export PATH="$STUB_BIN:$PATH"

echo "=== wb-agents.test.sh ==="

out="$(bash "$WB" agents 2>&1)"; rc=$?
assert_eq "exit 0 on a normal listing" "0" "$rc"
assert "live scope: claude inside -> live, processes counted" '^live +wb-agent-dotfiles--live-100-1\.scope +claude:1 github-mcp-serv:1 gopls:2' "$out"
assert "wl-copy-only scope -> ORPHAN" '^ORPHAN +wb-agent-dotfiles--orphan-200-2\.scope +wl-copy:1' "$out"
assert "leftover dev server -> ORPHAN (shows what's inside)" '^ORPHAN +wb-agent-be--monorepo--server-300-3\.scope +go:1 match-tracker-a:1' "$out"
assert "pid that exited mid-scan is skipped, scan continues (set -e/pipefail safe)" '^live +wb-agent-dotfiles--racy-400-4\.scope +claude:1 *$' "$out"
assert "summary counts totals and orphans" '4 scope\(s\), 2 orphaned' "$out"
assert "prints the stop line for each orphan" 'systemctl --user stop wb-agent-dotfiles--orphan-200-2\.scope' "$out"
refute "no stop line for a live scope" 'stop wb-agent-dotfiles--live-100-1' "$out"
refute "read-only: never invokes systemctl stop/kill itself" '^(stop|kill)|--user (stop|kill)' "$(cat "$SYSTEMCTL_CALLS")"

out="$(bash "$WB" agents --orphans 2>&1)"
refute "--orphans hides live rows" '^live ' "$out"
assert "--orphans keeps orphan rows" '^ORPHAN +wb-agent-dotfiles--orphan-200-2' "$out"

: > "$FIXTURE/units"
out="$(bash "$WB" agents 2>&1)"; rc=$?
assert_eq "no scopes: still exit 0" "0" "$rc"
assert "no scopes: zero summary, no stop hint" '0 scope\(s\), 0 orphaned' "$out"
refute "no scopes: no stop hint" 'systemctl --user stop' "$out"

bash "$WB" agents --bogus >/dev/null 2>&1; rc=$?
assert_eq "unknown flag exits 2" "2" "$rc"

exit $fail
