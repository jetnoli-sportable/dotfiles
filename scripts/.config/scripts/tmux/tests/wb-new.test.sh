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
# a second real, pre-existing stem — needed so a repeated --depends-on test
# has two distinct real targets to accumulate.
printf -- '---\nstatus: doing\nrepo: proj\nbranch: existing2\nworktree: .worktrees/existing2\nparent:\ntags: []\ncreated: 2026-07-01\nclosed:\n---\n# Existing 2\n' \
  > "$FIXTURE_TASKS/proj--existing2.md"
# a real stem already at status: done — --depends-on naming it must still be
# accepted (a done blocker is trivially met, not a special case to reject).
printf -- '---\nstatus: done\nrepo: proj\nbranch: done-task\nworktree: .worktrees/done-task\nparent:\ntags: []\ncreated: 2026-07-01\nclosed: 2026-07-05\n---\n# Done Task\n' \
  > "$FIXTURE_TASKS/proj--done-task.md"

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

# --- U3: --path / --depends-on (wb-board-display, R5/R19) -------------------

# no flags at all -> path: is blank (not a literal default string), and the
# key line itself is actually present (blank-fill convention, not just
# "absent reads as empty").
cmd_new proj path-none >/dev/null 2>&1
tmux kill-session -t "=proj--path-none" 2>/dev/null
path_val="$(wb_get_frontmatter "$FIXTURE_TASKS/proj--path-none.md" path)"
assert_eq "no flags: path: is blank" "" "$path_val"
grep -qE '^path:' "$FIXTURE_TASKS/proj--path-none.md"
assert_eq "no flags: path: key line was actually inserted" 0 $?
depends_val="$(wb_get_frontmatter "$FIXTURE_TASKS/proj--path-none.md" depends_on)"
assert_eq "no flags: depends_on: is blank" "" "$depends_val"
grep -qE '^depends_on:' "$FIXTURE_TASKS/proj--path-none.md"
assert_eq "no flags: depends_on: key line was actually inserted" 0 $?

# --path work,review -> stored exactly as passed, no reordering/dedup (that's
# the render-time parser's job, not creation-time's).
cmd_new proj path-wr --path work,review >/dev/null 2>&1
tmux kill-session -t "=proj--path-wr" 2>/dev/null
path_val="$(wb_get_frontmatter "$FIXTURE_TASKS/proj--path-wr.md" path)"
assert_eq "--path work,review: path: stored exactly" "work,review" "$path_val"

# --path bogus -> loud failure, exit non-zero, NOTHING created (worktree dir,
# task file, tmux session — all three).
out="$(cmd_new proj path-bad --path bogus 2>&1)"; code=$?
assert "--path bogus: clean error naming the bad token" \
  "wb new: --path has unknown stage 'bogus'" "$out"
assert_eq "--path bogus: exit code 1" 1 "$code"
[ -d "$FIXTURE_CODE/proj/.worktrees/path-bad" ] && { echo "FAIL - --path bogus: worktree should not have been created"; fail=1; } \
  || echo "ok   - --path bogus: no worktree created"
[ -f "$FIXTURE_TASKS/proj--path-bad.md" ] && { echo "FAIL - --path bogus: task file should not have been created"; fail=1; } \
  || echo "ok   - --path bogus: no task file created"
tmux has-session -t "=proj--path-bad" 2>/dev/null \
  && { echo "FAIL - --path bogus: tmux session should not have been created"; fail=1; } \
  || echo "ok   - --path bogus: no tmux session created"

# --depends-on <real-stem> -> depends_on: written with that stem.
cmd_new proj dep-one --depends-on proj--existing >/dev/null 2>&1
tmux kill-session -t "=proj--dep-one" 2>/dev/null
depends_val="$(wb_get_frontmatter "$FIXTURE_TASKS/proj--dep-one.md" depends_on)"
assert_eq "--depends-on <real-stem>: depends_on: recorded" "proj--existing" "$depends_val"

# repeated --depends-on flags -> values accumulate, comma-joined.
cmd_new proj dep-two --depends-on proj--existing --depends-on proj--existing2 >/dev/null 2>&1
tmux kill-session -t "=proj--dep-two" 2>/dev/null
depends_val="$(wb_get_frontmatter "$FIXTURE_TASKS/proj--dep-two.md" depends_on)"
assert_eq "repeated --depends-on: values accumulate comma-joined" "proj--existing,proj--existing2" "$depends_val"

# --depends-on <missing-stem> -> loud failure before any worktree/session/
# task-file creation.
out="$(cmd_new proj dep-missing --depends-on proj--nope 2>&1)"; code=$?
assert "--depends-on <missing-stem>: clean error" \
  "has no matching task file" "$out"
assert_eq "--depends-on <missing-stem>: exit code 1" 1 "$code"
[ -d "$FIXTURE_CODE/proj/.worktrees/dep-missing" ] && { echo "FAIL - --depends-on <missing-stem>: worktree should not have been created"; fail=1; } \
  || echo "ok   - --depends-on <missing-stem>: no worktree created"
[ -f "$FIXTURE_TASKS/proj--dep-missing.md" ] && { echo "FAIL - --depends-on <missing-stem>: task file should not have been created"; fail=1; } \
  || echo "ok   - --depends-on <missing-stem>: no task file created"
tmux has-session -t "=proj--dep-missing" 2>/dev/null \
  && { echo "FAIL - --depends-on <missing-stem>: tmux session should not have been created"; fail=1; } \
  || echo "ok   - --depends-on <missing-stem>: no tmux session created"

# --depends-on value containing '/' is rejected.
out="$(cmd_new proj dep-slash --depends-on foo/bar 2>&1)"; code=$?
assert "--depends-on with '/': rejected" "must not contain '/'" "$out"
assert_eq "--depends-on with '/': exit code 1" 1 "$code"
[ -f "$FIXTURE_TASKS/proj--dep-slash.md" ] && { echo "FAIL - --depends-on with '/': task file should not have been created"; fail=1; } \
  || echo "ok   - --depends-on with '/': no task file created"

# --depends-on value containing ',' is rejected.
out="$(cmd_new proj dep-comma --depends-on foo,bar 2>&1)"; code=$?
assert "--depends-on with ',': rejected" "must not contain ','" "$out"
assert_eq "--depends-on with ',': exit code 1" 1 "$code"
[ -f "$FIXTURE_TASKS/proj--dep-comma.md" ] && { echo "FAIL - --depends-on with ',': task file should not have been created"; fail=1; } \
  || echo "ok   - --depends-on with ',': no task file created"

# --depends-on equal to the task's own computed stem is rejected (self-reference).
out="$(cmd_new proj dep-self --depends-on proj--dep-self 2>&1)"; code=$?
assert "--depends-on self-reference: rejected" "cannot be the task's own reference" "$out"
assert_eq "--depends-on self-reference: exit code 1" 1 "$code"
[ -f "$FIXTURE_TASKS/proj--dep-self.md" ] && { echo "FAIL - --depends-on self-reference: task file should not have been created"; fail=1; } \
  || echo "ok   - --depends-on self-reference: no task file created"

# --depends-on naming an already-`done` task is accepted (trivially met, no
# special-casing needed).
cmd_new proj dep-done --depends-on proj--done-task >/dev/null 2>&1
tmux kill-session -t "=proj--dep-done" 2>/dev/null
depends_val="$(wb_get_frontmatter "$FIXTURE_TASKS/proj--dep-done.md" depends_on)"
assert_eq "--depends-on <done stem>: accepted, recorded" "proj--done-task" "$depends_val"

# existing task file with path: already set -> a flag-less `wb new` re-run
# does NOT overwrite it; --path <other> on the same file DOES overwrite it.
cmd_new proj path-existing --path work,review >/dev/null 2>&1
tmux kill-session -t "=proj--path-existing" 2>/dev/null
cmd_new proj path-existing >/dev/null 2>&1
tmux kill-session -t "=proj--path-existing" 2>/dev/null
path_val="$(wb_get_frontmatter "$FIXTURE_TASKS/proj--path-existing.md" path)"
assert_eq "existing path: flag-less re-run does not overwrite" "work,review" "$path_val"
cmd_new proj path-existing --path plan >/dev/null 2>&1
tmux kill-session -t "=proj--path-existing" 2>/dev/null
path_val="$(wb_get_frontmatter "$FIXTURE_TASKS/proj--path-existing.md" path)"
assert_eq "existing path: explicit --path overwrites" "plan" "$path_val"

# a task file predating path:/depends_on: entirely (no lines for them at all
# in its frontmatter, not even blank ones) -> a flag-less `wb new` backfills
# both keys blank. Built directly (not from TEMPLATE.md) so this regresses
# even once the external template has caught up to carrying the keys.
printf -- '---\nstatus: doing\nrepo: proj\nbranch: legacy\nworktree: .worktrees/legacy\nparent:\ntags: []\ncreated: 2026-07-01\nclosed:\n---\n# Legacy\n' \
  > "$FIXTURE_TASKS/proj--legacy.md"
cmd_new proj legacy >/dev/null 2>&1
tmux kill-session -t "=proj--legacy" 2>/dev/null
path_val="$(wb_get_frontmatter "$FIXTURE_TASKS/proj--legacy.md" path)"
assert_eq "pre-existing file with no path:/depends_on: lines: path: backfilled blank" "" "$path_val"
grep -qE '^path:' "$FIXTURE_TASKS/proj--legacy.md"
assert_eq "pre-existing file with no path:/depends_on: lines: path: key line inserted" 0 $?
depends_val="$(wb_get_frontmatter "$FIXTURE_TASKS/proj--legacy.md" depends_on)"
assert_eq "pre-existing file with no path:/depends_on: lines: depends_on: backfilled blank" "" "$depends_val"
grep -qE '^depends_on:' "$FIXTURE_TASKS/proj--legacy.md"
assert_eq "pre-existing file with no path:/depends_on: lines: depends_on: key line inserted" 0 $?

# --- regression: --parent and --agent still work alongside --path/--depends-on ---
cmd_new --agent --parent proj--existing --path work --depends-on proj--existing proj combo-a >/dev/null 2>&1
parent_val="$(wb_get_frontmatter "$FIXTURE_TASKS/proj--combo-a.md" parent)"
assert_eq "combined flags: parent: recorded" "proj--existing" "$parent_val"
path_val="$(wb_get_frontmatter "$FIXTURE_TASKS/proj--combo-a.md" path)"
assert_eq "combined flags: path: recorded" "work" "$path_val"
depends_val="$(wb_get_frontmatter "$FIXTURE_TASKS/proj--combo-a.md" depends_on)"
assert_eq "combined flags: depends_on: recorded" "proj--existing" "$depends_val"
tmux has-session -t "=proj--combo-a:agent" 2>/dev/null
assert_eq "combined flags: agent window exists (--agent still took effect)" 0 $?
tmux kill-session -t "=proj--combo-a" 2>/dev/null

exit "$fail"
