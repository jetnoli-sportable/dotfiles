#!/usr/bin/env bash
# Tests for U4: `wb append` (cmd_append + the extracted
# _wb_append_under_heading insertion helper), the planned-preserving
# `wb new --planned` creation path (wb_seed_task_planned), and the W14 grep
# smoke-check that the three rewired SKILL.md files no longer instruct an
# Edit/Write-tool write against a task file.
#
# Two families of fixtures: plain-bash assertions against static task-file
# fixtures (mirroring wb-handoffs.test.sh's style — cmd_append's insertion
# algorithm IS _wb_append_under_heading, the exact same extracted core
# wb_append_handoff itself now calls, so these scenarios double as a second
# angle on that shared logic), and a real concurrent background lock holder
# for the contention scenario (mirroring wb-lock-integration.test.sh's
# spawn_holder pattern, trimmed to what this file actually needs).
#
# Run: bash scripts/.config/scripts/tmux/tests/wb-append.test.sh
set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WB="$SELF_DIR/wb.sh"
WB_LOCKS="$SELF_DIR/wb-locks.sh"
# Repo root, by fixed path arithmetic rather than `git rev-parse
# --show-toplevel`: this checkout may be a linked git WORKTREE whose
# on-disk `.git` file points at an absolute path inside the MAIN
# checkout's `.git/worktrees/<name>` dir (e.g.
# `/home/you/code/dotfiles/.git/worktrees/some-branch`) — the Docker
# sandbox mounts only this one worktree directory at `/repo` (per this
# file's own header, `-v "$(pwd)":/repo:ro`), so that main-checkout `.git`
# dir is never present inside the container and `git rev-parse` fails
# there with "not a git repository" even though the working tree itself is
# perfectly intact. SELF_DIR is always `<repo-root>/scripts/.config/scripts/tmux`
# (4 path components below repo root) by this whole test suite's own
# fixed-layout convention, so plain path arithmetic is both simpler and
# more robust here than depending on git working at all.
REPO_ROOT="$(cd "$SELF_DIR/../../../.." && pwd)"

FIXTURE="$(mktemp -d -t wb-append-fixture.XXXXXX)"
HOLDER_PIDS=()

cleanup() {
  for pid in "${HOLDER_PIDS[@]:-}"; do
    [ -n "$pid" ] && kill "$pid" 2>/dev/null
  done
  for pid in "${HOLDER_PIDS[@]:-}"; do
    [ -n "$pid" ] && wait "$pid" 2>/dev/null
  done
  rm -rf "$FIXTURE"
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
assert_not() { # <desc> <regex> <actual> — passes when <regex> does NOT match
  if printf '%s' "$3" | grep -qE "$2"; then
    echo "FAIL - $1"
    echo "       unexpected match: $2"
    echo "       got: $(printf '%s' "$3" | head -8)"
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
# assert_no_double_blank <desc> <file> — same style check as
# wb-handoffs.test.sh: a stray double blank line betrays sloppy
# insertion-point bookkeeping.
assert_no_double_blank() {
  if grep -Pzq '\n\n\n' "$2"; then
    echo "FAIL - $1: found a stray double blank line"
    fail=1
  else
    echo "ok   - $1: no stray double blank lines"
  fi
}

# Isolate lock state + task store + code dir under fixture paths — never
# touch the real ~/.local/state/wb/locks, ~/code/tasks, or ~/code on
# whatever host or container runs this (same convention as
# wb-lock-integration.test.sh / wb-new.test.sh).
export XDG_STATE_HOME="$FIXTURE/state"
export HOME="$FIXTURE/home"
export CODE_DIR="$FIXTURE/code"
export TASKS_DIR="$FIXTURE/tasks"
mkdir -p "$XDG_STATE_HOME" "$HOME" "$CODE_DIR" "$TASKS_DIR"
printf -- '---\nstatus: planned\nrepo:\nbranch:\nworktree:\nparent:\ntags: []\ncreated:\nclosed:\n---\n# Title\n' \
  > "$TASKS_DIR/TEMPLATE.md"

# shellcheck disable=SC1090
source "$WB"
set +e   # wb.sh sets -e; this suite intentionally captures non-zero exits

mk_task() { # <file> <branch>
  printf -- '---\nstatus: doing\nrepo: proj\nbranch: %s\nworktree: .worktrees/%s\ntags: []\ncreated: 2026-07-01\nclosed:\n---\n# Title\n%s\n' \
    "$2" "$2" "${3:-}" > "$1"
}

# =============================================================================
# Scenario: append under an EXISTING heading lands at the END of the
# section (not right after the heading), matching wb_append_handoff's own
# ordering convention (both now share _wb_append_under_heading).
# =============================================================================

EXIST_TASK="$TASKS_DIR/proj--append-exist.md"
printf -- '---\nstatus: doing\nrepo: proj\nbranch: append-exist\nworktree: .worktrees/append-exist\ntags: []\ncreated: 2026-07-01\nclosed:\n---\n# Title\n\n## Follow-ups\n\n- existing follow-up\n\n## Decisions\n' \
  > "$EXIST_TASK"

out="$(cmd_append "append-exist" "Follow-ups" "new follow-up note" 2>&1)"; rc=$?
assert_eq "existing heading: cmd_append exits 0" 0 "$rc"
assert "existing heading: confirmation message names the heading + file" 'appended under "## Follow-ups" in proj--append-exist\.md' "$out"
content="$(cat "$EXIST_TASK")"
assert "existing heading: existing follow-up survives" 'existing follow-up' "$content"
assert "existing heading: new body present" 'new follow-up note' "$content"
l1="$(grep -nF 'existing follow-up' "$EXIST_TASK" | cut -d: -f1)"
l2="$(grep -nF 'new follow-up note' "$EXIST_TASK" | cut -d: -f1)"
d_line="$(grep -n '^## Decisions$' "$EXIST_TASK" | cut -d: -f1)"
if [ -n "$l1" ] && [ -n "$l2" ] && [ "$l1" -lt "$l2" ] && [ -n "$d_line" ] && [ "$l2" -lt "$d_line" ]; then
  echo "ok   - existing heading: new body lands at the END of the section, before ## Decisions"
else
  echo "FAIL - existing heading: wrong ordering (existing=$l1, new=$l2, decisions=$d_line)"; fail=1
fi
assert_no_double_blank "existing heading" "$EXIST_TASK"

# =============================================================================
# Scenario: missing-heading fallback — inserted right before "## Decisions"
# when that heading exists, else at EOF (same convention as
# wb_append_handoff / handoff_append_followup).
# =============================================================================

MISSING_TASK="$TASKS_DIR/proj--append-missing.md"
printf -- '---\nstatus: doing\nrepo: proj\nbranch: append-missing\nworktree: .worktrees/append-missing\ntags: []\ncreated: 2026-07-01\nclosed:\n---\n# Title\n\n## Plan\n\nsome plan text\n\n## Decisions\n' \
  > "$MISSING_TASK"

out="$(cmd_append "append-missing" "Follow-ups" "first follow-up" 2>&1)"; rc=$?
assert_eq "missing heading + Decisions exists: exit 0" 0 "$rc"
content="$(cat "$MISSING_TASK")"
assert "missing heading: creates ## Follow-ups" '^## Follow-ups$' "$content"
assert "missing heading: body present" 'first follow-up' "$content"
assert "missing heading: prior ## Plan content untouched" 'some plan text' "$content"
h_line="$(grep -n '^## Follow-ups$' "$MISSING_TASK" | cut -d: -f1)"
d_line="$(grep -n '^## Decisions$' "$MISSING_TASK" | cut -d: -f1)"
if [ -n "$h_line" ] && [ -n "$d_line" ] && [ "$h_line" -lt "$d_line" ]; then
  echo "ok   - missing heading: Follow-ups lands before Decisions"
else
  echo "FAIL - missing heading: wrong order (h=$h_line, d=$d_line)"; fail=1
fi
assert_no_double_blank "missing heading + Decisions" "$MISSING_TASK"

EOF_TASK="$TASKS_DIR/proj--append-eof.md"
printf -- '---\nstatus: doing\nrepo: proj\nbranch: append-eof\nworktree: .worktrees/append-eof\ntags: []\ncreated: 2026-07-01\nclosed:\n---\n# Title\n\n## Plan\n\nsome plan text\n' \
  > "$EOF_TASK"

out="$(cmd_append "append-eof" "Sweep" "eof body" 2>&1)"; rc=$?
assert_eq "neither heading present: exit 0" 0 "$rc"
content="$(cat "$EOF_TASK")"
assert "neither heading: creates ## Sweep at EOF" '^## Sweep$' "$content"
assert "neither heading: body present" 'eof body' "$content"
assert_no_double_blank "neither heading (EOF fallback)" "$EOF_TASK"

# =============================================================================
# Scenario: multi-line body round-trips — the /wb-save shape (a
# "###"-timestamped block with three bold-leader lines), read from stdin.
# All lines present, in order, adjacent to each other (no stray blank line
# _wb_append_under_heading might otherwise splice INTO the caller's own
# body — that hygiene is the caller's job, not this helper's), and the
# block lands at the END of the section (after an existing auto entry),
# never right after the heading.
# =============================================================================

SAVE_TASK="$TASKS_DIR/proj--append-save.md"
printf -- '---\nstatus: doing\nrepo: proj\nbranch: append-save\nworktree: .worktrees/append-save\ntags: []\ncreated: 2026-07-01\nclosed:\n---\n# Title\n\n## Handoffs\n\n### 2026-07-01 09:00 — wb pause (auto)\n\nEarlier entry.\n\n## Decisions\n' \
  > "$SAVE_TASK"

SAVE_BODY=$'### 2026-07-11 18:42 — wb-save\n**Done:** did the thing.\n**In flight:** doing another thing.\n**Next:** do the next thing.'
out="$(printf '%s' "$SAVE_BODY" | cmd_append "append-save" "Handoffs" 2>&1)"; rc=$?
assert_eq "wb-save shape (stdin, body arg omitted): exit 0" 0 "$rc"
content="$(cat "$SAVE_TASK")"
assert "wb-save shape: earlier auto entry survives" 'Earlier entry\.' "$content"
assert "wb-save shape: heading line present" '^### 2026-07-11 18:42 — wb-save$' "$content"
assert "wb-save shape: Done line present" '^\*\*Done:\*\* did the thing\.$' "$content"
assert "wb-save shape: In flight line present" '^\*\*In flight:\*\* doing another thing\.$' "$content"
assert "wb-save shape: Next line present" '^\*\*Next:\*\* do the next thing\.$' "$content"
assert_not "wb-save shape: no (auto) suffix on the wb-save heading (that's wb_append_handoff's own marker, not used here)" 'wb-save \(auto\)' "$content"

l_head="$(grep -n '^### 2026-07-11 18:42 — wb-save$' "$SAVE_TASK" | cut -d: -f1)"
l_done="$(grep -n '^\*\*Done:\*\*' "$SAVE_TASK" | cut -d: -f1)"
l_flight="$(grep -n '^\*\*In flight:\*\*' "$SAVE_TASK" | cut -d: -f1)"
l_next="$(grep -n '^\*\*Next:\*\*' "$SAVE_TASK" | cut -d: -f1)"
if [ -n "$l_head" ] && [ "$l_done" -eq $((l_head + 1)) ] && [ "$l_flight" -eq $((l_done + 1)) ] && [ "$l_next" -eq $((l_flight + 1)) ]; then
  echo "ok   - wb-save shape: all four lines adjacent, in order, no stray blank line spliced in"
else
  echo "FAIL - wb-save shape: lines not adjacent (head=$l_head done=$l_done flight=$l_flight next=$l_next)"; fail=1
fi
assert_no_double_blank "wb-save shape" "$SAVE_TASK"

l_earlier="$(grep -nF 'Earlier entry.' "$SAVE_TASK" | cut -d: -f1)"
if [ -n "$l_earlier" ] && [ -n "$l_head" ] && [ "$l_earlier" -lt "$l_head" ]; then
  echo "ok   - wb-save shape: new block lands after the earlier auto entry (oldest-first ordering preserved)"
else
  echo "FAIL - wb-save shape: ordering wrong (earlier=$l_earlier, new head=$l_head)"; fail=1
fi

# Explicit "-" body arg also reads stdin (the other documented convention).
DASH_TASK="$TASKS_DIR/proj--append-dash.md"
mk_task "$DASH_TASK" append-dash $'\n## Follow-ups\n'
out="$(printf 'via dash arg' | cmd_append "append-dash" "Follow-ups" - 2>&1)"; rc=$?
assert_eq "explicit '-' body arg: exit 0" 0 "$rc"
assert "explicit '-' body arg: body landed" 'via dash arg' "$(cat "$DASH_TASK")"

# Trailing one-line body argument (the short convenience form) also works.
ARG_TASK="$TASKS_DIR/proj--append-arg.md"
mk_task "$ARG_TASK" append-arg $'\n## Follow-ups\n'
out="$(cmd_append "append-arg" "Follow-ups" "one-line convenience body" 2>&1)"; rc=$?
assert_eq "trailing one-line body arg: exit 0" 0 "$rc"
assert "trailing one-line body arg: body landed" 'one-line convenience body' "$(cat "$ARG_TASK")"

# =============================================================================
# Scenario: ambiguous (2+ matches) and unmatched (0 matches) task refs both
# fail loud rather than guessing — same message shape as cmd_resume.
# =============================================================================

AMBIG_A="$TASKS_DIR/proj--dup-topic.md"
AMBIG_B="$TASKS_DIR/proj--dup-topic-two.md"
mk_task "$AMBIG_A" dup-topic $'\n## Follow-ups\n'
mk_task "$AMBIG_B" dup-topic-two $'\n## Follow-ups\n'

out="$(cmd_append "dup-topic" "Follow-ups" "should not land anywhere" 2>&1)"; rc=$?
assert_eq "ambiguous ref: exit 1" 1 "$rc"
assert "ambiguous ref: fails loud naming the match count" 'matches 2 tasks' "$out"
assert_not "ambiguous ref: neither candidate file was touched" 'should not land anywhere' "$(cat "$AMBIG_A"; cat "$AMBIG_B")"

out="$(cmd_append "no-such-task-xyz" "Follow-ups" "body" 2>&1)"; rc=$?
assert_eq "no match: exit 1" 1 "$rc"
assert "no match: fails loud" 'no task matches' "$out"

# =============================================================================
# Scenario: an exact task-ref (a real basename or absolute path already
# known to the caller — the shape every rewired SKILL.md actually uses)
# resolves to ITSELF, bypassing the fuzzy substring fallback entirely —
# proven against a pair whose names are literal PREFIX substrings of each
# other (a case the fuzzy fallback alone would treat as ambiguous).
# =============================================================================

PREFIX_A="$TASKS_DIR/proj--foo.md"
PREFIX_B="$TASKS_DIR/proj--foo-bar.md"
mk_task "$PREFIX_A" foo $'\n## Follow-ups\n'
mk_task "$PREFIX_B" foo-bar $'\n## Follow-ups\n'

out="$(cmd_append "proj--foo" "Follow-ups" "resolved via exact basename" 2>&1)"; rc=$?
assert_eq "exact basename ref: exit 0 (fast path, not ambiguous)" 0 "$rc"
assert "exact basename ref: landed in proj--foo.md" 'resolved via exact basename' "$(cat "$PREFIX_A")"
assert_not "exact basename ref: sibling proj--foo-bar.md left untouched" 'resolved via exact basename' "$(cat "$PREFIX_B")"

out="$(cmd_append "$PREFIX_A" "Follow-ups" "resolved via absolute path" 2>&1)"; rc=$?
assert_eq "absolute path ref: exit 0" 0 "$rc"
assert "absolute path ref: landed in proj--foo.md" 'resolved via absolute path' "$(cat "$PREFIX_A")"

# =============================================================================
# Scenario: the lock is ACTUALLY held during append — a real concurrent
# background holder proves a second `wb append` on the SAME task file
# halts (75) rather than interleaving, and the losing attempt's body never
# lands. After the holder releases, a retry succeeds cleanly.
# =============================================================================

CONTEND_TASK="$TASKS_DIR/proj--append-contend.md"
mk_task "$CONTEND_TASK" append-contend $'\n## Follow-ups\n'

HOLDER_LOG="$FIXTURE/holder-output.log"
HOLDER_SCRIPT="$FIXTURE/lock-holder-wb.sh"
cat > "$HOLDER_SCRIPT" <<HOLDEREOF
#!/usr/bin/env bash
exec >>"$HOLDER_LOG" 2>&1
unset TMUX TMUX_PANE
source "$WB_LOCKS"
wb_task_lock_acquire "$CONTEND_TASK" || exit 1
sleep 2
HOLDEREOF
chmod +x "$HOLDER_SCRIPT"

( exec bash "$HOLDER_SCRIPT" ) &
HOLDER_PID=$!
HOLDER_PIDS+=("$HOLDER_PID")

# Poll the side-car lock file for the holder's own pid instead of a blind
# sleep — spawn setup time is Docker-load-dependent (same reasoning as
# wb-lock-integration.test.sh's _wait_for_holder).
CONTEND_LOCKFILE="$(_wb_lock_path_for "$CONTEND_TASK")"
waited=0
while [ "$waited" -lt 30 ]; do
  [ "$(_wb_lock_field "$CONTEND_LOCKFILE" pid)" = "$HOLDER_PID" ] && break
  sleep 0.1
  waited=$((waited + 1))
done

out="$(cmd_append "append-contend" "Follow-ups" "should not land while contended" 2>&1)"; rc=$?
assert_eq "contention: cmd_append halts (75) rather than interleaving" 75 "$rc"
assert "contention: message names the contended file" "contended on $(basename "$CONTEND_TASK")" "$out"
assert_not "contention: body did NOT land while contended" 'should not land while contended' "$(cat "$CONTEND_TASK")"

wait "$HOLDER_PID" 2>/dev/null

out="$(cmd_append "append-contend" "Follow-ups" "landed after release" 2>&1)"; rc=$?
assert_eq "post-release retry: exit 0" 0 "$rc"
assert "post-release retry: body landed" 'landed after release' "$(cat "$CONTEND_TASK")"

# =============================================================================
# Scenario: planned-preserving creation (`wb new --planned`) — new task has
# status: planned (not doing), worktree: left blank; a second, idempotent
# creation call never clobbers a status a real `wb new`/`wb new --agent`
# run already advanced past "planned".
# =============================================================================

mkdir -p "$CODE_DIR/plannedrepo"
git init -q "$CODE_DIR/plannedrepo"
git -C "$CODE_DIR/plannedrepo" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init

out="$(cmd_new --planned plannedrepo feat/scratch-idea 2>&1)"; rc=$?
assert_eq "planned creation: exit 0" 0 "$rc"
PLANNED_FILE="$TASKS_DIR/plannedrepo--feat-scratch-idea.md"
if [ -f "$PLANNED_FILE" ]; then
  echo "ok   - planned creation: task file created"
else
  echo "FAIL - planned creation: task file missing ($PLANNED_FILE)"; fail=1
fi
assert "planned creation: status stays planned, not doing" '^status: planned$' "$(cat "$PLANNED_FILE")"
worktree_val="$(wb_get_frontmatter "$PLANNED_FILE" worktree)"
assert_eq "planned creation: worktree: left blank" "" "$worktree_val"
assert "planned creation: repo: filled" '^repo: plannedrepo$' "$(cat "$PLANNED_FILE")"
assert "planned creation: branch: filled from the raw slug" '^branch: feat/scratch-idea$' "$(cat "$PLANNED_FILE")"

if [ -e "$CODE_DIR/plannedrepo/.worktrees" ]; then
  echo "FAIL - planned creation: a worktree directory was created, should not have been"; fail=1
else
  echo "ok   - planned creation: no worktree created"
fi

# idempotent re-run must not clobber a status a real transition already set
wb_set_frontmatter "$PLANNED_FILE" status doing
out2="$(cmd_new --planned plannedrepo feat/scratch-idea 2>&1)"; rc2=$?
assert_eq "planned creation: idempotent re-run exits 0" 0 "$rc2"
assert "planned creation: idempotent re-run does NOT clobber status back to planned" '^status: doing$' "$(cat "$PLANNED_FILE")"

# --agent and --planned are mutually exclusive
out3="$(cmd_new --planned --agent plannedrepo feat/another-idea 2>&1)"; rc3=$?
assert_eq "planned + agent together: exit 1" 1 "$rc3"
assert "planned + agent together: clean usage error, not a crash" 'mutually exclusive' "$out3"

# =============================================================================
# Scenario (W14): the three rewired SKILL.md files contain no Edit/Write-
# tool instruction for a task-file write, and DO reference the new locked
# verb(s) plus an explicit never-Edit/Write-tool rule. A reasonable
# grep-based smoke check — not exhaustive NLP — tuned to the ACTUAL old
# wording this unit eliminates ("Use Read then Edit directly on the task
# file's prose", raw `wb_seed_task`/`bash -c` shell-outs, a bare
# `write ~/code/tasks/<repo>--<slug>.md` instruction).
# =============================================================================

if [ -z "$REPO_ROOT" ]; then
  echo "FAIL - skill grep check: could not resolve repo root via git rev-parse --show-toplevel"
  fail=1
else
  for skill in handoff parked-items wb-save; do
    skill_file="$REPO_ROOT/claude/.claude/skills/$skill/SKILL.md"
    if [ ! -f "$skill_file" ]; then
      echo "FAIL - skill grep check: $skill_file not found"
      fail=1
      continue
    fi

    if grep -niE 'use read then edit|(edit|write) tool.*(task file|~/code/tasks)|write .?~/code/tasks/[^ ]*\.md' "$skill_file" >/dev/null; then
      echo "FAIL - skill grep check: $skill still contains an Edit/Write-tool task-file write instruction:"
      grep -niE 'use read then edit|(edit|write) tool.*(task file|~/code/tasks)|write .?~/code/tasks/[^ ]*\.md' "$skill_file" | sed 's/^/       /'
      fail=1
    else
      echo "ok   - skill grep check: $skill has no Edit/Write-tool task-file write instruction"
    fi

    if grep -qE 'wb (append|new --planned)' "$skill_file"; then
      echo "ok   - skill grep check: $skill references wb append / wb new --planned"
    else
      echo "FAIL - skill grep check: $skill does not reference wb append or wb new --planned"
      fail=1
    fi

    # Spans a markdown line-wrap in practice, so match across the whole
    # file (null-separated, dotall) rather than a single grep -E line.
    if grep -Pzoqi '(?s)never[^.]{0,200}?(edit|write)[\s/-]*tool' "$skill_file"; then
      echo "ok   - skill grep check: $skill states the never-Edit/Write-tool-task-files rule"
    else
      echo "FAIL - skill grep check: $skill is missing the never-Edit/Write-tool-task-files rule"
      fail=1
    fi
  done
fi

[ "$fail" -eq 0 ] && echo "ALL PASS" || echo "FAILURES"
exit "$fail"
