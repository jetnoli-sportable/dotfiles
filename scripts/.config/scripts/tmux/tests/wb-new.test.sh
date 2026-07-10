#!/usr/bin/env bash
# Behavioral tests for cmd_new's --parent flag parsing — same convention as
# wb-parent-child.test.sh (source wb.sh, real tmux session on a throwaway
# socket, real git repo under a fixture CODE_DIR). Added during PR #17's
# code review: wb-schema.test.sh's --parent assertions only regex-match
# cmd_new's source text, never actually invoke it — both bugs fixed in
# 17da53f (the --parent unbound-variable crash and the --parent/--agent
# flag-order swallow) lived exactly in this untested surface.
#
# Run: bash scripts/.config/scripts/tmux/tests/wb-new.test.sh
set -uo pipefail

WB="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/wb.sh"
FIXTURE_CODE="$(mktemp -d -t wb-new-code.XXXXXX)"
FIXTURE_TASKS="$(mktemp -d -t wb-new-tasks.XXXXXX)"
FIXTURE_BIN="$(mktemp -d -t wb-new-bin.XXXXXX)"
SOCK="wb-new-sock-$$"
REAL_TMUX="$(command -v tmux)"

cat > "$FIXTURE_BIN/tmux" <<EOF
#!/usr/bin/env bash
exec "$REAL_TMUX" -L "$SOCK" "\$@"
EOF
chmod +x "$FIXTURE_BIN/tmux"
PATH="$FIXTURE_BIN:$PATH"

cleanup() {
  "$REAL_TMUX" -L "$SOCK" kill-server 2>/dev/null || true
  rm -rf "$FIXTURE_CODE" "$FIXTURE_TASKS" "$FIXTURE_BIN"
}
trap cleanup EXIT

fail=0
assert() { # <desc> <expected-regex> <actual>
  if printf '%s' "$3" | grep -qE "$2"; then
    echo "ok   - $1"
  else
    echo "FAIL - $1"
    echo "       expected match: $2"
    echo "       got: $(printf '%s' "$3" | head -8)"
    fail=1
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

# real (throwaway) git repo under the fixture CODE_DIR, matching cmd_new's
# own $CODE_DIR/$repo/.git check
mkdir -p "$FIXTURE_CODE/proj"
git init -q "$FIXTURE_CODE/proj"
git -C "$FIXTURE_CODE/proj" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init

printf -- '---\nstatus: planned\nrepo:\nbranch:\nworktree:\nparent:\ntags: []\ncreated:\nclosed:\n---\n# Title\n' \
  > "$FIXTURE_TASKS/TEMPLATE.md"
printf -- '---\nstatus: doing\nrepo: proj\nbranch: existing\nworktree: .worktrees/existing\nparent:\ntags: []\ncreated: 2026-07-01\nclosed:\n---\n# Existing\n' \
  > "$FIXTURE_TASKS/proj--existing.md"

# CODE_DIR/TASKS_DIR exported BEFORE sourcing so wb.sh's override-safe
# defaults (CODE_DIR="${CODE_DIR:-$HOME/code}") pick up the fixtures, not
# the real ~/code — this is exactly the variable this branch's own incident
# was about; never touch $HOME/code from this test.
export CODE_DIR="$FIXTURE_CODE"
export TASKS_DIR="$FIXTURE_TASKS"

# shellcheck disable=SC1090
source "$WB"
set +e   # wb.sh sets -e; this test intentionally captures non-zero exits

# --- dangling --parent (no value) errors cleanly, doesn't crash -------------
out="$(cmd_new proj dangle-a --parent 2>&1)"; code=$?
assert "dangling --parent: clean usage error, not a raw unbound-variable crash" \
  '^wb new: --parent requires a value$' "$out"
assert_eq "dangling --parent: exit code 1" 1 "$code"
[ -f "$FIXTURE_TASKS/proj--dangle-a.md" ] && { echo "FAIL - dangling --parent: task file should not have been created"; fail=1; } \
  || echo "ok   - dangling --parent: no task file created"

# --- --parent immediately followed by --agent no longer swallows --agent ----
out="$(cmd_new --parent --agent proj swallow-a 2>&1)"; code=$?
assert "parent-swallows-agent order: clean usage error naming --parent" \
  '^wb new: --parent requires a value$' "$out"
assert_eq "parent-swallows-agent order: exit code 1" 1 "$code"

# --- --parent and --agent together, --agent first, both take effect ---------
# (not asserting cmd_new's own exit code here: its last action is
# tmux_focus -> `tmux attach`, which fails outside a real attached client
# regardless of the flags this test cares about -- side effects are the
# real assertion.)
cmd_new --agent --parent proj--existing proj both-a >/dev/null 2>&1
parent_val="$(wb_get_frontmatter "$FIXTURE_TASKS/proj--both-a.md" parent)"
assert_eq "both flags (--agent first): parent: recorded" "proj--existing" "$parent_val"
tmux has-session -t "=proj--both-a:agent" 2>/dev/null
assert_eq "both flags (--agent first): agent window exists (--agent took effect)" 0 $?
tmux kill-session -t "=proj--both-a" 2>/dev/null

# --- --parent and --agent together, --parent first, both take effect -------
cmd_new --parent proj--existing --agent proj both-b >/dev/null 2>&1
parent_val="$(wb_get_frontmatter "$FIXTURE_TASKS/proj--both-b.md" parent)"
assert_eq "both flags (--parent first): parent: recorded" "proj--existing" "$parent_val"
tmux has-session -t "=proj--both-b:agent" 2>/dev/null
assert_eq "both flags (--parent first): agent window exists (--agent took effect)" 0 $?
tmux kill-session -t "=proj--both-b" 2>/dev/null

# --- self-referential --parent is rejected (D3 / wb_task_own_parent) -------
# First create proj--self-ref for real (no --parent), then re-run naming
# its own now-existing file as --parent -- the exact repro adversarial used.
cmd_new proj self-ref >/dev/null 2>&1
tmux kill-session -t "=proj--self-ref" 2>/dev/null
out="$(cmd_new proj self-ref --parent proj--self-ref 2>&1)"; code=$?
assert "self-referential --parent: rejected with a clear message" \
  "cannot be the task's own reference" "$out"
assert_eq "self-referential --parent: exit code 1" 1 "$code"
parent_val="$(wb_get_frontmatter "$FIXTURE_TASKS/proj--self-ref.md" parent)"
assert_eq "self-referential --parent: parent: was never set" "" "$parent_val"

exit "$fail"
