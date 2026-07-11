#!/usr/bin/env bash
# Behavioral tests for wb_ensure_repo_ignore and its wiring into cmd_new —
# same convention as wb-new.test.sh (source wb.sh, real tmux session on a
# throwaway socket, real git repos under a fixture CODE_DIR). Covers R10 /
# AE5 / AE6 (docs/plans/2026-07-11-003-feat-queue-command-plan.md, U1) plus
# a regression check that cmd_done's existing generic gitignored-file sweep
# already covers the (not-yet-existing) queue file with no new code (R9 /
# AE3).
#
# Run: bash scripts/.config/scripts/tmux/tests/wb-queue.test.sh
set -uo pipefail

WB="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/wb.sh"
FIXTURE_CODE="$(mktemp -d -t wb-queue-code.XXXXXX)"
FIXTURE_TASKS="$(mktemp -d -t wb-queue-tasks.XXXXXX)"
FIXTURE_BIN="$(mktemp -d -t wb-queue-bin.XXXXXX)"
SOCK="wb-queue-sock-$$"
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
  if printf '%s' "$3" | grep -qE -- "$2"; then
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

mk_repo() { # <dir>
  mkdir -p "$1"
  git init -q "$1"
  git -C "$1" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
}

printf -- '---\nstatus: planned\nrepo:\nbranch:\nworktree:\nparent:\ntags: []\ncreated:\nclosed:\n---\n# Title\n' \
  > "$FIXTURE_TASKS/TEMPLATE.md"

# CODE_DIR/TASKS_DIR exported BEFORE sourcing so wb.sh's override-safe
# defaults (CODE_DIR="${CODE_DIR:-$HOME/code}") pick up the fixtures, not
# the real ~/code.
export CODE_DIR="$FIXTURE_CODE"
export TASKS_DIR="$FIXTURE_TASKS"

# shellcheck disable=SC1090
source "$WB"
set +e   # wb.sh sets -e; this test intentionally captures non-zero exits

# cmd_done opens the task file's transient "## Sweep" checklist interactively
# (wb_open_buffer), then ALWAYS strips that section afterward regardless of
# what got checked — so the checklist only exists for the instant the buffer
# is open. Snapshot it here (into SWEEP_SNAPSHOT, a plain global) before
# simulating the user checking "keep" on the queue file, the same way
# wb-reconcile-review.test.sh simulates a checked box via sed.
SWEEP_SNAPSHOT=""
wb_open_buffer() {
  local path="$1"
  SWEEP_SNAPSHOT="$(wb_sweep_section "$path")"
  sed -i 's/^- \[ \] keep \.claude-queue\.md$/- [x] keep .claude-queue.md/' "$path"
}

# =============================================================================
# 1. Happy path: fresh repo, no pre-existing info/exclude
# =============================================================================
mk_repo "$FIXTURE_CODE/proj1"
cmd_new proj1 alpha >/dev/null 2>&1
excl1="$FIXTURE_CODE/proj1/.git/info/exclude"
assert_eq "happy path: exclude file has exactly one pattern occurrence" \
  "1" "$(grep -cxF '.claude-queue.md' "$excl1" 2>/dev/null)"
if [ -f "$FIXTURE_CODE/proj1/.worktrees/alpha/.claude-queue.md" ]; then
  echo "FAIL - happy path: queue file should not exist yet (creation is lazy-only)"; fail=1
else
  echo "ok   - happy path: no queue file created eagerly by cmd_new"
fi
tmux kill-session -t "=proj1--alpha" 2>/dev/null

# =============================================================================
# 2. Idempotency (Covers AE6): second cmd_new, different slug, same repo
# =============================================================================
cmd_new proj1 beta >/dev/null 2>&1
assert_eq "idempotency: exclude file still has exactly one occurrence after 2nd cmd_new" \
  "1" "$(grep -cxF '.claude-queue.md' "$excl1" 2>/dev/null)"
tmux kill-session -t "=proj1--beta" 2>/dev/null

# =============================================================================
# 3. Non-destructive append — pre-existing exclude WITH a trailing newline
# =============================================================================
mk_repo "$FIXTURE_CODE/proj2"
mkdir -p "$FIXTURE_CODE/proj2/.git/info"
printf '*.log\n' > "$FIXTURE_CODE/proj2/.git/info/exclude"
cmd_new proj2 gamma >/dev/null 2>&1
excl2="$FIXTURE_CODE/proj2/.git/info/exclude"
assert "with-trailing-newline: pre-existing line intact" '^\*\.log$' "$(cat "$excl2")"
assert "with-trailing-newline: pattern lands as its own line" '^\.claude-queue\.md$' "$(cat "$excl2")"
assert_eq "with-trailing-newline: exactly 2 lines, nothing glued together" \
  "2" "$(awk 'END{print NR}' "$excl2")"
tmux kill-session -t "=proj2--gamma" 2>/dev/null

# =============================================================================
# 4. Non-destructive append — pre-existing exclude WITHOUT a trailing newline
# =============================================================================
mk_repo "$FIXTURE_CODE/proj3"
mkdir -p "$FIXTURE_CODE/proj3/.git/info"
printf '*.log' > "$FIXTURE_CODE/proj3/.git/info/exclude"   # no trailing newline
cmd_new proj3 delta >/dev/null 2>&1
excl3="$FIXTURE_CODE/proj3/.git/info/exclude"
assert "without-trailing-newline: pre-existing line intact, not glued to" '^\*\.log$' "$(cat "$excl3")"
assert "without-trailing-newline: pattern lands as its own line" '^\.claude-queue\.md$' "$(cat "$excl3")"
assert_eq "without-trailing-newline: exactly 2 lines" \
  "2" "$(awk 'END{print NR}' "$excl3")"
tmux kill-session -t "=proj3--delta" 2>/dev/null

# =============================================================================
# 5. Concurrency: two cmd_new invocations for the same repo, backgrounded
# =============================================================================
mk_repo "$FIXTURE_CODE/proj4"
cmd_new proj4 conc-a >/dev/null 2>&1 &
pid1=$!
cmd_new proj4 conc-b >/dev/null 2>&1 &
pid2=$!
wait "$pid1" "$pid2"
excl4="$FIXTURE_CODE/proj4/.git/info/exclude"
assert_eq "concurrency: exactly one occurrence, no corrupted/duplicated line" \
  "1" "$(grep -cxF '.claude-queue.md' "$excl4" 2>/dev/null)"
tmux kill-session -t "=proj4--conc-a" 2>/dev/null
tmux kill-session -t "=proj4--conc-b" 2>/dev/null

# =============================================================================
# 6. Acceptance check (Covers AE5): touched queue file reports !!, never ??
# =============================================================================
mk_repo "$FIXTURE_CODE/proj5"
cmd_new proj5 epsilon >/dev/null 2>&1
wt5="$FIXTURE_CODE/proj5/.worktrees/epsilon"
touch "$wt5/.claude-queue.md"
status5="$(git -C "$wt5" status --porcelain --ignored -- .claude-queue.md)"
assert "acceptance: queue file reported ignored (!!), not untracked (??)" \
  '^!! \.claude-queue\.md$' "$status5"
tmux kill-session -t "=proj5--epsilon" 2>/dev/null

# =============================================================================
# 7. Sweep participation (Covers AE3, R9): non-empty queue file appears in
#    cmd_done's existing generic gitignored-file Sweep checklist, proving R9
#    with an actual assertion rather than only reading cmd_done's source.
# =============================================================================
mk_repo "$FIXTURE_CODE/proj6"
cmd_new proj6 zeta >/dev/null 2>&1
wt6="$FIXTURE_CODE/proj6/.worktrees/zeta"
printf '## 2026-07-11T12:00:00\n\na stashed follow-up\n' > "$wt6/.claude-queue.md"
task_file="$FIXTURE_TASKS/proj6--zeta.md"
# Not wrapped in command substitution: cmd_done calls wb_open_buffer, whose
# stub below sets the global SWEEP_SNAPSHOT — a $(...) subshell would run
# cmd_done (and the stub) in a forked subshell, and that assignment would
# never make it back to this shell.
cmd_done "proj6--zeta" >/dev/null 2>&1
code=$?
assert_eq "sweep: cmd_done exits 0 on a clean-except-ignored worktree" "0" "$code"
assert "sweep: queue file listed as a keep candidate in ## Sweep" \
  '- \[ \] keep \.claude-queue\.md' "$SWEEP_SNAPSHOT"
dossier="$FIXTURE_TASKS/dossiers/proj6--zeta"
assert "sweep: checked queue file copied into the task's dossier" \
  'kept: `\.claude-queue\.md`' "$(cat "$task_file")"
if [ -f "$dossier/.claude-queue.md" ]; then
  echo "ok   - sweep: dossier copy of the queue file exists on disk"
else
  echo "FAIL - sweep: dossier copy of the queue file missing at $dossier/.claude-queue.md"; fail=1
fi

[ "$fail" -eq 0 ] && echo "ALL PASS" || echo "FAILURES"
exit "$fail"
