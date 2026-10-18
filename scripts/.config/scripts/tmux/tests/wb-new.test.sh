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
FIXTURE_PROJECTS="$(mktemp -d -t wb-new-projects.XXXXXX)"   # fixture ~/.claude/projects (U4)
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
export CLAUDE_PROJECTS_DIR="$FIXTURE_PROJECTS"

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

# --- U3: --depends-on, blank-filled path: (wb-board-display, R5/R19) --------

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

# --path / --size were removed from wb new (wb set covers both): either flag
# now fails the positional count, and nothing is created.
for flag in --path --size; do
  out="$(cmd_new "$flag" X proj flag-gone 2>&1)"; code=$?
  assert_eq "$flag: no longer accepted (exit 1)" 1 "$code"
  [ -f "$FIXTURE_TASKS/proj--flag-gone.md" ] && { echo "FAIL - $flag: task file should not have been created"; fail=1; } \
    || echo "ok   - $flag: no task file created"
done

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

# --- size-depends-capture U5: blank-filled size: ---------------------------

# size: key present but blank (blank-fill convention, same as
# path:/depends_on:) — the fixture TEMPLATE.md has no size: line at all, so
# this also proves the key gets INSERTED, not just left absent.
size_val="$(wb_get_frontmatter "$FIXTURE_TASKS/proj--path-none.md" size)"
assert_eq "no flags: size: is blank" "" "$size_val"
grep -qE '^size:' "$FIXTURE_TASKS/proj--path-none.md"
assert_eq "no flags: size: key line was actually inserted" 0 $?

# --prospective (R25/KTD4) -> same worktree-less/session-less path as
# --planned, but status: prospective instead of status: planned, and no
# worktree or tmux session either.
out="$(cmd_new --prospective proj prospective-a 2>&1)"; code=$?
assert_eq "--prospective: exit 0" 0 "$code"
assert_eq "--prospective: status is prospective" "prospective" "$(wb_get_frontmatter "$FIXTURE_TASKS/proj--prospective-a.md" status)"
[ -d "$FIXTURE_CODE/proj/.worktrees/prospective-a" ] \
  && { echo "FAIL - --prospective: no worktree should have been created"; fail=1; } \
  || echo "ok   - --prospective: no worktree created"
tmux has-session -t "=proj--prospective-a" 2>/dev/null \
  && { echo "FAIL - --prospective: no tmux session should have been created"; fail=1; } \
  || echo "ok   - --prospective: no tmux session created"

# --prospective and --agent are mutually exclusive, same shape as --planned.
out="$(cmd_new --prospective --agent proj prospective-agent 2>&1)"; code=$?
assert_eq "--prospective + --agent: exit 1" 1 "$code"
assert "--prospective + --agent: names both flags" \
  '\-\-prospective and \-\-agent are mutually exclusive' "$out"

# existing prospective task file -> a flag-less `wb new` re-run backfills
# repo:/branch: but never bumps status: past prospective (same
# non-clobbering convention --planned already has).
cmd_new proj prospective-a >/dev/null 2>&1
tmux kill-session -t "=proj--prospective-a" 2>/dev/null
assert_eq "existing prospective: flag-less re-run does not advance status" \
  "prospective" "$(wb_get_frontmatter "$FIXTURE_TASKS/proj--prospective-a.md" status)"

# existing task file with size:/path: already set (as `wb set` would) -> a
# `wb new` re-run blank-fills only, never overwrites either.
cmd_new proj meta-existing >/dev/null 2>&1
tmux kill-session -t "=proj--meta-existing" 2>/dev/null
wb_set_frontmatter "$FIXTURE_TASKS/proj--meta-existing.md" size L
wb_set_frontmatter "$FIXTURE_TASKS/proj--meta-existing.md" path work,review
cmd_new proj meta-existing >/dev/null 2>&1
tmux kill-session -t "=proj--meta-existing" 2>/dev/null
assert_eq "existing size: re-run does not overwrite" "L" "$(wb_get_frontmatter "$FIXTURE_TASKS/proj--meta-existing.md" size)"
assert_eq "existing path: re-run does not overwrite" "work,review" "$(wb_get_frontmatter "$FIXTURE_TASKS/proj--meta-existing.md" path)"

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

# --- regression: --parent and --agent still work alongside --depends-on ---
cmd_new --agent --parent proj--existing --depends-on proj--existing proj combo-a >/dev/null 2>&1
parent_val="$(wb_get_frontmatter "$FIXTURE_TASKS/proj--combo-a.md" parent)"
assert_eq "combined flags: parent: recorded" "proj--existing" "$parent_val"
depends_val="$(wb_get_frontmatter "$FIXTURE_TASKS/proj--combo-a.md" depends_on)"
assert_eq "combined flags: depends_on: recorded" "proj--existing" "$depends_val"
tmux has-session -t "=proj--combo-a:agent" 2>/dev/null
assert_eq "combined flags: agent window exists (--agent still took effect)" 0 $?
tmux kill-session -t "=proj--combo-a" 2>/dev/null

# --- U4: warm relaunch — what wb_layout_session pre-types in win2 ----------

mk_transcript() { # <worktree_abs> <id> <touch-date>
  local dir; dir="$(wb_transcript_dir "$1")"
  mkdir -p "$dir"
  printf '{}' > "$dir/$2.jsonl"
  touch -d "$3" "$dir/$2.jsonl"
}

# a brand-new task -> nothing pre-typed in the agent window (today's exact
# behavior; no transcript, no Handoffs history to fall back to either).
cmd_new proj fresh >/dev/null 2>&1
pane="$(tmux capture-pane -p -t "=proj--fresh:agent" 2>/dev/null)"
if printf '%s' "$pane" | grep -q claude; then
  echo "FAIL - fresh task: agent window unexpectedly has 'claude' pre-typed"; fail=1
else
  echo "ok   - fresh task: agent window has nothing pre-typed"
fi
tmux kill-session -t "=proj--fresh" 2>/dev/null

# an existing task, no live session, a transcript on disk for its worktree
# -> the agent window pre-types `claude --resume <id>` with NO Enter (the
# lazy-launch rule): create the task file + worktree directly (bypassing
# cmd_new's own creation path, mirroring "a session that was closed with
# wb down and is now being resumed"), seed one transcript, then call
# cmd_new to bring the session back.
printf -- '---\nstatus: doing\nrepo: proj\nbranch: feat/warm\nworktree: .worktrees/feat/warm\nparent:\ntags: []\ncreated: 2026-07-01\nclosed:\n---\n# Warm\n' \
  > "$FIXTURE_TASKS/proj--feat-warm.md"
git -C "$FIXTURE_CODE/proj" worktree add -q -b feat/warm "$FIXTURE_CODE/proj/.worktrees/feat/warm" >/dev/null 2>&1
mk_transcript "$FIXTURE_CODE/proj/.worktrees/feat/warm" warm-id-123 2026-09-05T00:00:00
cmd_new proj feat/warm >/dev/null 2>&1
pane="$(tmux capture-pane -p -t "=proj--feat-warm:agent" 2>/dev/null)"
assert "resume with a transcript: pre-types claude --resume <id>" 'claude --resume warm-id-123' "$pane"
tmux kill-session -t "=proj--feat-warm" 2>/dev/null

# Regression (post-PR#52): an existing task with a Handoffs entry from an
# AUTO verb (wb breakdown stamps "### ... (auto)" the same way wb pause
# does; older files also carry the retired wb set/wb status stamps) but NO claude_sessions: field and NO transcript on
# disk must NOT pre-type `claude --continue` — there is nothing to
# continue. This is exactly last night's misfire: a brand-new task
# re-parented by `wb set` before its first `wb new --agent` used to get a
# pre-typed `--continue` that failed with "No conversation found to
# continue" and left handoff.sh's boot-ready poller waiting forever.
printf -- '---\nstatus: doing\nrepo: proj\nbranch: feat/auto-only\nworktree: .worktrees/feat/auto-only\nparent:\nclaude_sessions:\ntags: []\ncreated: 2026-07-01\nclosed:\n---\n# Auto Only\n\n## Handoffs\n\n### 2026-09-01 09:00 — wb set (auto)\n\n`parent:` set to `proj--other` via `wb set` (was ``).\n' \
  > "$FIXTURE_TASKS/proj--feat-auto-only.md"
git -C "$FIXTURE_CODE/proj" worktree add -q -b feat/auto-only "$FIXTURE_CODE/proj/.worktrees/feat/auto-only" >/dev/null 2>&1
cmd_new proj feat/auto-only >/dev/null 2>&1
pane="$(tmux capture-pane -p -t "=proj--feat-auto-only:agent" 2>/dev/null)"
if printf '%s' "$pane" | grep -q claude; then
  echo "FAIL - auto-verb Handoffs entry, no claude_sessions:/transcript: agent window unexpectedly has 'claude' pre-typed"; fail=1
else
  echo "ok   - auto-verb Handoffs entry, no claude_sessions:/transcript: nothing pre-typed (no false --continue)"
fi
tmux kill-session -t "=proj--feat-auto-only" 2>/dev/null

# Regression (live, post-first-fix): claude_sessions: populated by a prior
# `wb down`/`wb pause`, but the recorded transcript no longer exists on
# disk (retention purge, or the worktree path it was recorded against has
# since changed) — must NOT pre-type `claude --continue` either.
# `--continue`'s own resolution is scoped to the exact same
# wb_transcript_dir-hashed directory wb_resume_id already checked and found
# empty, so it can't find anything `wb_resume_id` didn't — there is no
# claude_sessions:-based signal that changes that. (This is exactly what
# `claude_sessions: non-empty -> --continue`, the first attempt at this
# fix, still got wrong: reported live as `claude --continue` failing for a
# be--monorepo task the same way the original Handoffs-scan bug did.)
printf -- '---\nstatus: doing\nrepo: proj\nbranch: feat/history\nworktree: .worktrees/feat/history\nparent:\nclaude_sessions: purged-id-999@2026-09-01T09:00:00Z@primary\ntags: []\ncreated: 2026-07-01\nclosed:\n---\n# History\n\n## Handoffs\n\n### 2026-09-01 09:00 — wb pause (auto)\n\nSession paused via `wb pause`.\n' \
  > "$FIXTURE_TASKS/proj--feat-history.md"
git -C "$FIXTURE_CODE/proj" worktree add -q -b feat/history "$FIXTURE_CODE/proj/.worktrees/feat/history" >/dev/null 2>&1
cmd_new proj feat/history >/dev/null 2>&1
pane="$(tmux capture-pane -p -t "=proj--feat-history:agent" 2>/dev/null)"
if printf '%s' "$pane" | grep -q claude; then
  echo "FAIL - claude_sessions: set, no surviving transcript: agent window unexpectedly has 'claude' pre-typed (a --continue with nothing to continue)"; fail=1
else
  echo "ok   - claude_sessions: set, no surviving transcript: nothing pre-typed (no false --continue)"
fi
tmux kill-session -t "=proj--feat-history" 2>/dev/null

# --agent + a transcript: the resume command is actually SENT (Enter
# pressed), not left sitting at the prompt — asserted by the command text
# still being visible in the pane (either as the shell's own echo of what
# it ran, or the "command not found" tail if the fixture PATH has no real
# `claude` binary — either way proves send-keys included Enter with the
# resolved command, not a bare "claude").
printf -- '---\nstatus: doing\nrepo: proj\nbranch: feat/warm-agent\nworktree: .worktrees/feat/warm-agent\nparent:\ntags: []\ncreated: 2026-07-01\nclosed:\n---\n# Warm Agent\n' \
  > "$FIXTURE_TASKS/proj--feat-warm-agent.md"
git -C "$FIXTURE_CODE/proj" worktree add -q -b feat/warm-agent "$FIXTURE_CODE/proj/.worktrees/feat/warm-agent" >/dev/null 2>&1
mk_transcript "$FIXTURE_CODE/proj/.worktrees/feat/warm-agent" warm-agent-id 2026-09-06T00:00:00
cmd_new --agent proj feat/warm-agent >/dev/null 2>&1
sleep 0.2   # let the shell finish echoing the submitted command line
pane="$(tmux capture-pane -p -t "=proj--feat-warm-agent:agent" 2>/dev/null)"
assert "--agent + transcript: resume command was submitted, not left bare" 'claude --resume warm-agent-id' "$pane"
tmux kill-session -t "=proj--feat-warm-agent" 2>/dev/null

# --- wb_bootstrap self-heal: a pre-existing worktree dir still gets seeded ---
# A worktree made outside `wb new` (ce-worktree, a manual `git worktree add`,
# a half-finished earlier run) used to skip bootstrap permanently, because
# the call only ran when `wb new` itself created the dir.
printf '.env\ndeps\n' > "$FIXTURE_CODE/proj/.worktree-bootstrap"
printf 'SECRET=main\n' > "$FIXTURE_CODE/proj/.env"
mkdir -p "$FIXTURE_CODE/proj/deps"
boot_wt="$FIXTURE_CODE/proj/.worktrees/boot-pre"
git -C "$FIXTURE_CODE/proj" worktree add -q -b boot-pre "$boot_wt" >/dev/null 2>&1
cmd_new proj boot-pre >/dev/null 2>&1
tmux kill-session -t "=proj--boot-pre" 2>/dev/null
assert_eq "pre-existing worktree dir: .env copied in" "SECRET=main" "$(cat "$boot_wt/.env" 2>/dev/null)"
assert_eq "pre-existing worktree dir: deps symlinked to main checkout" \
  "$FIXTURE_CODE/proj/deps" "$(readlink "$boot_wt/deps" 2>/dev/null)"

# Re-running over an already-bootstrapped worktree is a no-op per entry: no
# `ln -s` error on the existing symlink (nor a nested deps/deps link through
# it), and a worktree-local edit to a copied file survives.
printf 'SECRET=local-edit\n' > "$boot_wt/.env"
out="$(cmd_new proj boot-pre 2>&1)"
tmux kill-session -t "=proj--boot-pre" 2>/dev/null
if printf '%s' "$out" | grep -qE 'ln: |File exists'; then
  echo "FAIL - re-bootstrap: errored on an existing entry"; echo "       got: $out"; fail=1
else
  echo "ok   - re-bootstrap: no error on existing entries"
fi
assert_eq "re-bootstrap: modified .env not overwritten" "SECRET=local-edit" "$(cat "$boot_wt/.env")"
[ -e "$FIXTURE_CODE/proj/deps/deps" ] && { echo "FAIL - re-bootstrap: nested deps/deps link created through the existing symlink"; fail=1; } \
  || echo "ok   - re-bootstrap: no nested link through the existing symlink"

# A failing entry (its parent path is a FILE in the worktree, so mkdir -p
# fails) warns, doesn't stop the later entries, and doesn't abort `wb new`.
printf 'blocker/x\n.env\n' > "$FIXTURE_CODE/proj/.worktree-bootstrap"
mkdir -p "$FIXTURE_CODE/proj/blocker" && printf 'x\n' > "$FIXTURE_CODE/proj/blocker/x"
fail_wt="$FIXTURE_CODE/proj/.worktrees/boot-fail"
git -C "$FIXTURE_CODE/proj" worktree add -q -b boot-fail "$fail_wt" >/dev/null 2>&1
printf 'not a dir\n' > "$fail_wt/blocker"
out="$(cmd_new proj boot-fail 2>&1)"
assert "failing bootstrap entry: warns and continues" 'bootstrap of gitignored files .* failed \(continuing\)' "$out"
assert_eq "failing bootstrap entry: later entries still seeded" "SECRET=main" "$(cat "$fail_wt/.env" 2>/dev/null)"
tmux has-session -t "=proj--boot-fail" 2>/dev/null
assert_eq "failing bootstrap entry: wb new still created the session" 0 $?
tmux kill-session -t "=proj--boot-fail" 2>/dev/null

# --- planned/prospective: --body - / --body-file land under ## Plan ----------
# wb new NEVER reads stdin implicitly; the body comes only from --body - or
# --body-file. The fixture TEMPLATE has no "## Plan" heading (nothing above
# needed one); the real TEMPLATE.md does, so give this block one.
printf -- '---\nstatus: planned\nrepo:\nbranch:\nworktree:\nparent:\ntags: []\ncreated:\nclosed:\n---\n# Title\n\n## Plan\n\n## Done\n' \
  > "$FIXTURE_TASKS/TEMPLATE.md"
plan_body() { # <file> — the text between "## Plan" and the next "## " heading
  awk '/^## Plan$/ {on=1; next} /^## / {on=0} on' "$1"
}

printf 'step one\nstep two with \\n and C:\\keep\n' | cmd_new --planned --body - proj body-planned >/dev/null 2>&1
assert "--planned --body -: lands under ## Plan" 'step one' "$(plan_body "$FIXTURE_TASKS/proj--body-planned.md")"
assert "--planned --body -: backslashes preserved verbatim" 'step two with \\n and C:\\keep' "$(plan_body "$FIXTURE_TASKS/proj--body-planned.md")"
assert_eq "--planned --body -: no jira: stamped" "" "$(wb_get_frontmatter "$FIXTURE_TASKS/proj--body-planned.md" jira)"

# re-run against the existing stem with a different body -> untouched
# (compare the ## Plan body only: a re-run legitimately blank-fills schema
# keys like reviewed:, which is frontmatter, not the body under test)
before="$(plan_body "$FIXTURE_TASKS/proj--body-planned.md")"
printf 'REPLACEMENT body\n' | cmd_new --planned --body - proj body-planned >/dev/null 2>&1
assert_eq "--planned --body - re-run on existing stem: body untouched (not duplicated/overwritten)" "$before" "$(plan_body "$FIXTURE_TASKS/proj--body-planned.md")"
printf 'REPLACEMENT file body\n' > "$FIXTURE_BIN/repl.md"
cmd_new --planned --body-file "$FIXTURE_BIN/repl.md" proj body-planned >/dev/null 2>&1
assert_eq "--planned --body-file re-run on existing stem: body untouched" "$before" "$(plan_body "$FIXTURE_TASKS/proj--body-planned.md")"

# --prospective shares the path -> same behavior, status stays prospective
printf 'prospective body line\n' | cmd_new --prospective --body - proj body-prospective >/dev/null 2>&1
assert "--prospective --body -: lands under ## Plan" 'prospective body line' "$(plan_body "$FIXTURE_TASKS/proj--body-prospective.md")"
assert_eq "--prospective --body -: status prospective" "prospective" "$(wb_get_frontmatter "$FIXTURE_TASKS/proj--body-prospective.md" status)"

# --jira + --body -
printf 'jira body line\n' | cmd_new --planned --jira https://x.atlassian.net/browse/SFB-1 --body - proj body-jira >/dev/null 2>&1
assert "--planned --jira --body -: lands under ## Plan" 'jira body line' "$(plan_body "$FIXTURE_TASKS/proj--body-jira.md")"
assert_eq "--planned --jira --body -: jira: stamped" "https://x.atlassian.net/browse/SFB-1" "$(wb_get_frontmatter "$FIXTURE_TASKS/proj--body-jira.md" jira)"

# --depends-on alongside a body (the #73 half, end to end)
printf 'dep body\n' | cmd_new --planned --depends-on proj--existing --body - proj body-dep >/dev/null 2>&1
assert "--planned --depends-on + body: body lands" 'dep body' "$(plan_body "$FIXTURE_TASKS/proj--body-dep.md")"
assert_eq "--planned --depends-on + body: depends_on: written" "proj--existing" "$(wb_get_frontmatter "$FIXTURE_TASKS/proj--body-dep.md" depends_on)"

# --body-file (with and without --jira, and --prospective)
printf 'file body one\nfile body two\n' > "$FIXTURE_BIN/body.md"
cmd_new --planned --body-file "$FIXTURE_BIN/body.md" proj body-file >/dev/null 2>&1
assert "--planned --body-file: lands under ## Plan" 'file body two' "$(plan_body "$FIXTURE_TASKS/proj--body-file.md")"
cmd_new --planned --jira https://x.atlassian.net/browse/SFB-2 --body-file "$FIXTURE_BIN/body.md" proj body-file-jira >/dev/null 2>&1
assert "--planned --jira --body-file: lands under ## Plan" 'file body one' "$(plan_body "$FIXTURE_TASKS/proj--body-file-jira.md")"
cmd_new --prospective --body-file "$FIXTURE_BIN/body.md" proj body-file-prosp >/dev/null 2>&1
assert "--prospective --body-file: lands under ## Plan" 'file body one' "$(plan_body "$FIXTURE_TASKS/proj--body-file-prosp.md")"
err_missing="$(cmd_new --planned --body-file "$FIXTURE_BIN/no-such-file.md" proj body-file-missing 2>&1 1>/dev/null)"; rc_missing=$?
assert_eq "--body-file missing: exit 1" 1 "$rc_missing"
assert "--body-file missing: clear error" 'not a readable file' "$err_missing"
assert_eq "--body-file missing: no task file created" "" "$([ -f "$FIXTURE_TASKS/proj--body-file-missing.md" ] && echo exists)"

# empty / whitespace-only body inserts nothing
cmd_new --planned --body - proj body-empty </dev/null >/dev/null 2>&1
assert_eq "--planned --body - </dev/null: Plan section empty" "" "$(plan_body "$FIXTURE_TASKS/proj--body-empty.md" | tr -d '[:space:]')"
printf '  \n\n\t\n' | cmd_new --planned --body - proj body-ws >/dev/null 2>&1
assert_eq "--planned --body - whitespace-only: Plan section stays empty" "" "$(plan_body "$FIXTURE_TASKS/proj--body-ws.md" | tr -d '[:space:]')"

# a slow writer is still read to EOF under --body -
( sleep 1; printf 'slow body\n' ) | cmd_new --planned --body - proj body-slow >/dev/null 2>&1
assert "--planned --body - slow piped body: read to EOF" 'slow body' "$(plan_body "$FIXTURE_TASKS/proj--body-slow.md")"

# NO body flag: piped stdin is never read and never lands in the file.
printf 'ignored body\n' | cmd_new --planned proj body-noflag >/dev/null 2>&1
assert_eq "--planned without --body: piped stdin ignored (Plan empty)" "" "$(plan_body "$FIXTURE_TASKS/proj--body-noflag.md" | tr -d '[:space:]')"
printf 'ignored jira body\n' | cmd_new --planned --jira https://x.atlassian.net/browse/SFB-3 proj body-noflag-jira >/dev/null 2>&1
assert_eq "--planned --jira without --body: piped stdin ignored (Plan empty)" "" "$(plan_body "$FIXTURE_TASKS/proj--body-noflag-jira.md" | tr -d '[:space:]')"

# ...and is left unread for the caller: a `while read` loop calling
# `wb new --planned` per line must process ALL its lines (the old implicit
# `cat` swallowed everything after line one).
printf 'loop-a\nloop-b\nloop-c\n' > "$FIXTURE_BIN/loop.txt"
loop_seen=""
while read -r loop_slug; do
  cmd_new --planned proj "body-$loop_slug" >/dev/null 2>&1
  loop_seen="$loop_seen $loop_slug"
done < "$FIXTURE_BIN/loop.txt"
assert_eq "while-read loop calling wb new --planned: every line processed" " loop-a loop-b loop-c" "$loop_seen"
assert_eq "while-read loop: all three task files created" "3" "$(ls "$FIXTURE_TASKS"/proj--body-loop-*.md 2>/dev/null | wc -l | tr -d ' ')"

# the unread stdin is still fully readable by the caller afterwards
remaining="$(printf 'caller-line-1\ncaller-line-2\n' | { cmd_new --planned proj body-unread >/dev/null 2>&1; cat; })"
assert_eq "--planned without --body: stdin still readable by the caller afterwards" $'caller-line-1\ncaller-line-2' "$remaining"

# validation errors
err_np="$(cmd_new --body - proj body-nonplanned </dev/null 2>&1 1>/dev/null)"; rc_np=$?
assert_eq "--body without --planned: exit 1" 1 "$rc_np"
assert "--body without --planned: clear error" 'only valid together with --planned' "$err_np"
err_npf="$(cmd_new --body-file "$FIXTURE_BIN/body.md" proj body-nonplanned 2>&1 1>/dev/null)"; rc_npf=$?
assert_eq "--body-file without --planned: exit 1" 1 "$rc_npf"
assert "--body-file without --planned: clear error" 'only valid together with --planned' "$err_npf"
assert_eq "--body without --planned: no task file created" "" "$([ -f "$FIXTURE_TASKS/proj--body-nonplanned.md" ] && echo exists)"
err_both="$(cmd_new --planned --body - --body-file "$FIXTURE_BIN/body.md" proj body-both </dev/null 2>&1 1>/dev/null)"; rc_both=$?
assert_eq "--body - with --body-file: exit 1" 1 "$rc_both"
assert "--body - with --body-file: mutually exclusive error" 'mutually exclusive' "$err_both"
assert_eq "--body - with --body-file: no task file created" "" "$([ -f "$FIXTURE_TASKS/proj--body-both.md" ] && echo exists)"
err_bv="$(cmd_new --planned --body notdash proj body-badval 2>&1 1>/dev/null)"; rc_bv=$?
assert_eq "--body <not ->: exit 1" 1 "$rc_bv"
assert "--body <not ->: points at --body-file" 'body-file' "$err_bv"

# interactive (tty) stdin: never read (no body flag), never blocks. Needs a
# pty — `script` provides one.
if command -v script >/dev/null 2>&1; then
  timeout 20 script -qec "bash -c 'source \"$WB\" >/dev/null 2>&1; cmd_new --planned proj body-tty >/dev/null 2>&1; echo done-tty'" /dev/null </dev/null > "$FIXTURE_BIN/tty.out" 2>&1
  assert "--planned on a tty stdin: returns without blocking" 'done-tty' "$(cat "$FIXTURE_BIN/tty.out")"
  [ -f "$FIXTURE_TASKS/proj--body-tty.md" ] && echo "ok   - --planned on a tty stdin: task file created" \
    || { echo "FAIL - --planned on a tty stdin: task file created"; fail=1; }
else
  echo "skip - no script(1) available for the tty-stdin check"
fi

exit "$fail"
