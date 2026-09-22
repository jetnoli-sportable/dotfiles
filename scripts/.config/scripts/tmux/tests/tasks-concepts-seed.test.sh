#!/usr/bin/env bash
# Tests for the task-family CONCEPTS.md seed mechanism: _wb_concepts_paths
# (the parent-chain resolver) and _wb_seed_concepts_file (the CLAUDE.local.md
# writer cmd_new/`wb new` calls automatically). Same fixture convention as
# wb-new.test.sh (real git repo under a fixture CODE_DIR, real tmux session
# on a throwaway socket, source wb.sh directly).
#
# This mechanism started life planned as a per-prompt hook. The task's own
# U1 spike (see ~/code/tasks/dotfiles--feat-task-family-concepts-hook.md's
# `## Decisions`) found that Claude Code hooks cannot inject context into
# Task-tool sub-agents at all -- the exact audience this needs to reach --
# so U2 pivoted to seed-automation: `wb new` writes an untracked
# `CLAUDE.local.md` `@import` pointer at worktree-creation time instead,
# which reaches sub-agents because they load a worktree's cwd instruction
# files the same way the top-level session does. There is no hook, no
# settings.json wiring, and no runtime $PWD/@task resolution to test here --
# cmd_new always already knows its own task_file directly.
#
# Run: bash scripts/.config/scripts/tmux/tests/tasks-concepts-seed.test.sh
set -uo pipefail

WB="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/wb.sh"
FIXTURE_CODE="$(mktemp -d -t wb-concepts-code.XXXXXX)"
FIXTURE_TASKS="$(mktemp -d -t wb-concepts-tasks.XXXXXX)"
FIXTURE_BIN="$(mktemp -d -t wb-concepts-bin.XXXXXX)"
FIXTURE_PROJECTS="$(mktemp -d -t wb-concepts-projects.XXXXXX)"
SOCK="wb-concepts-sock-$$"
REAL_TMUX="$(command -v tmux)"

cat > "$FIXTURE_BIN/tmux" <<EOF
#!/usr/bin/env bash
exec "$REAL_TMUX" -L "$SOCK" "\$@"
EOF
chmod +x "$FIXTURE_BIN/tmux"
PATH="$FIXTURE_BIN:$PATH"

cleanup() {
  "$REAL_TMUX" -L "$SOCK" kill-server 2>/dev/null || true
  rm -rf "$FIXTURE_CODE" "$FIXTURE_TASKS" "$FIXTURE_BIN" "$FIXTURE_PROJECTS"
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
assert_file_missing() { # <desc> <path>
  if [ -e "$2" ]; then
    echo "FAIL - $1 (expected no file at $2)"
    fail=1
  else
    echo "ok   - $1"
  fi
}

mkdir -p "$FIXTURE_CODE/proj"
git init -q "$FIXTURE_CODE/proj"
git -C "$FIXTURE_CODE/proj" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init

mk_task() { # <stem> <parent_ref>
  printf -- '---\nstatus: doing\nrepo: proj\nbranch: %s\nworktree:\nparent: %s\ntags: []\ncreated: 2026-09-22\nclosed:\n---\n# %s\n' \
    "${1#proj--}" "$2" "$1" > "$FIXTURE_TASKS/$1.md"
}
mk_dossier() { # <stem>
  mkdir -p "$FIXTURE_TASKS/dossiers/$1"
  printf '# %s CONCEPTS\n\nsettled fact.\n' "$1" > "$FIXTURE_TASKS/dossiers/$1/CONCEPTS.md"
}

# --- 3-level family, CONCEPTS.md at two levels (umbrella + child) -----------
mk_task proj--umbrella ""
mk_dossier proj--umbrella
mk_task proj--child proj--umbrella
mk_dossier proj--child
mk_task proj--grandchild proj--child   # no dossier of its own

# --- no dossier anywhere in the chain ---------------------------------------
mk_task proj--nodossier ""

# --- mutual cycle, no dossier anywhere --------------------------------------
mk_task proj--cyclea proj--cycleb
mk_task proj--cycleb proj--cyclea

# --- self-parent, own dossier present ----------------------------------------
mk_task proj--selfp proj--selfp
mk_dossier proj--selfp

export CODE_DIR="$FIXTURE_CODE"
export TASKS_DIR="$FIXTURE_TASKS"
export CLAUDE_PROJECTS_DIR="$FIXTURE_PROJECTS"

# shellcheck disable=SC1090
source "$WB"
set +e   # wb.sh sets -e; this test intentionally captures non-zero exits

# ============================================================================
# _wb_concepts_paths: direct resolver assertions
# ============================================================================

out="$(_wb_concepts_paths "$FIXTURE_TASKS/proj--grandchild.md")"
assert_eq "grandchild: two ancestor dossiers, nearest-first" \
  "$FIXTURE_TASKS/dossiers/proj--child/CONCEPTS.md
$FIXTURE_TASKS/dossiers/proj--umbrella/CONCEPTS.md" "$out"

out="$(_wb_concepts_paths "$FIXTURE_TASKS/proj--child.md")"
assert_eq "child: own dossier before umbrella's" \
  "$FIXTURE_TASKS/dossiers/proj--child/CONCEPTS.md
$FIXTURE_TASKS/dossiers/proj--umbrella/CONCEPTS.md" "$out"

out="$(_wb_concepts_paths "$FIXTURE_TASKS/proj--nodossier.md")"
assert_eq "no dossier anywhere: empty output" "" "$out"

out="$(timeout 5 bash -c 'source "'"$WB"'" >/dev/null 2>&1; _wb_concepts_paths "'"$FIXTURE_TASKS"'/proj--cyclea.md"')"
code=$?
assert_eq "mutual cycle: terminates (no hang)" 0 "$code"
assert_eq "mutual cycle: no dossier anywhere -> empty output" "" "$out"

out="$(_wb_concepts_paths "$FIXTURE_TASKS/proj--selfp.md")"
assert_eq "self-parent: own dossier once, walk stops (no loop/dup)" \
  "$FIXTURE_TASKS/dossiers/proj--selfp/CONCEPTS.md" "$out"

# ============================================================================
# _wb_seed_concepts_file / cmd_new integration: the actual worktree file
# ============================================================================

cmd_new proj grandchild >/dev/null 2>&1
tmux kill-session -t "=proj--grandchild" 2>/dev/null
seed_file="$FIXTURE_CODE/proj/.worktrees/grandchild/CLAUDE.local.md"
assert "grandchild worktree: CLAUDE.local.md imports child dossier first" \
  "@$FIXTURE_TASKS/dossiers/proj--child/CONCEPTS.md" "$(cat "$seed_file" 2>/dev/null)"
assert "grandchild worktree: CLAUDE.local.md also imports umbrella dossier" \
  "@$FIXTURE_TASKS/dossiers/proj--umbrella/CONCEPTS.md" "$(cat "$seed_file" 2>/dev/null)"
child_line="$(grep -n '^@' "$seed_file" | head -1)"
case "$child_line" in
  *dossiers/proj--child/CONCEPTS.md) echo "ok   - grandchild worktree: child import line comes before umbrella (nearest-first order)" ;;
  *) echo "FAIL - grandchild worktree: import order is not nearest-first (got: $child_line)"; fail=1 ;;
esac
grep -qxF 'CLAUDE.local.md' "$FIXTURE_CODE/proj/.git/info/exclude"
assert_eq "grandchild worktree: CLAUDE.local.md registered in .git/info/exclude" 0 $?

cmd_new proj nodossier >/dev/null 2>&1
tmux kill-session -t "=proj--nodossier" 2>/dev/null
assert_file_missing "nodossier worktree: no CLAUDE.local.md written" \
  "$FIXTURE_CODE/proj/.worktrees/nodossier/CLAUDE.local.md"

# --- idempotent refresh: adding a dossier after the fact, then re-running
# `wb new`, must pick it up (no runtime hook to do this automatically). ------
mk_dossier proj--nodossier
cmd_new proj nodossier >/dev/null 2>&1
tmux kill-session -t "=proj--nodossier" 2>/dev/null
assert "nodossier worktree: re-running wb new refreshes the seed once a dossier exists" \
  "@$FIXTURE_TASKS/dossiers/proj--nodossier/CONCEPTS.md" \
  "$(cat "$FIXTURE_CODE/proj/.worktrees/nodossier/CLAUDE.local.md" 2>/dev/null)"

[ "$fail" -eq 0 ] && echo "ALL PASS" || echo "FAILURES"
exit "$fail"
