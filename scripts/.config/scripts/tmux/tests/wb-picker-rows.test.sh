#!/usr/bin/env bash
# Tests for the picker's single-view + dormant rows (U5) — same convention
# as wb-new.test.sh: source wb.sh, a real tmux server on a throwaway
# isolated socket, fixture CODE_DIR/TASKS_DIR/CLAUDE_PROJECTS_DIR. Covers
# collect_dormant_rows directly (no live sessions needed for most of it)
# plus the one scenario that genuinely needs a real session: a renamed live
# session must still suppress its own dormant row (KTD8).
#
# Run: bash scripts/.config/scripts/tmux/tests/wb-picker-rows.test.sh
set -uo pipefail

WB="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/wb.sh"
FIXTURE_CODE="$(mktemp -d -t wb-picker-code.XXXXXX)"
FIXTURE_TASKS="$(mktemp -d -t wb-picker-tasks.XXXXXX)"
FIXTURE_PROJECTS="$(mktemp -d -t wb-picker-projects.XXXXXX)"
FIXTURE_BIN="$(mktemp -d -t wb-picker-bin.XXXXXX)"
SOCK="wb-picker-sock-$$"
REAL_TMUX="$(command -v tmux)"

cat > "$FIXTURE_BIN/tmux" <<EOF
#!/usr/bin/env bash
exec "$REAL_TMUX" -L "$SOCK" "\$@"
EOF
chmod +x "$FIXTURE_BIN/tmux"
PATH="$FIXTURE_BIN:$PATH"

cleanup() {
  "$REAL_TMUX" -L "$SOCK" kill-server 2>/dev/null || true
  rm -rf "$FIXTURE_CODE" "$FIXTURE_TASKS" "$FIXTURE_PROJECTS" "$FIXTURE_BIN"
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

export CODE_DIR="$FIXTURE_CODE"
export TASKS_DIR="$FIXTURE_TASKS"
export CLAUDE_PROJECTS_DIR="$FIXTURE_PROJECTS"

# shellcheck disable=SC1090
source "$WB"
set +e   # wb.sh sets -e; this test intentionally captures non-zero exits

mk_task() { # <stem> <status> <repo> <branch> [worktree-override]
  local f="$FIXTURE_TASKS/$1.md" wt="${5:-.worktrees/$4}"
  printf -- '---\nstatus: %s\nrepo: %s\nbranch: %s\nworktree: %s\ntags: []\ncreated: 2026-07-07\nclosed:\n---\n# %s\n' \
    "$2" "$3" "$4" "$wt" "$1" > "$f"
}

mk_transcript() { # <worktree_abs> <id> <touch-date>
  local dir; dir="$(wb_transcript_dir "$1")"
  mkdir -p "$dir"
  printf '{}' > "$dir/$2.jsonl"
  touch -d "$3" "$dir/$2.jsonl"
}

# --- fixture store: exactly the shape the plan's test scenario describes ---
mk_task 'proj--doing-live'    doing   proj feat/doing-live
mk_task 'proj--doing-dormant' doing   proj feat/doing-dormant
mk_task 'proj--in-review'     review  proj feat/in-review
mk_task 'proj--shelved'       paused  proj feat/shelved
mk_task 'proj--planned-task'  planned proj feat/planned-task
mk_task 'proj--doing-cold'    doing   proj feat/doing-cold
mk_task 'proj--no-worktree'   doing   proj feat/no-worktree ""

for stem in doing-live doing-dormant in-review shelved doing-cold; do
  mkdir -p "$FIXTURE_CODE/proj/.worktrees/feat/$stem"
done
mk_transcript "$FIXTURE_CODE/proj/.worktrees/feat/doing-dormant" dormant-id 2026-09-05T00:00:00
mk_transcript "$FIXTURE_CODE/proj/.worktrees/feat/in-review"     review-id  2026-09-06T00:00:00
mk_transcript "$FIXTURE_CODE/proj/.worktrees/feat/shelved"       shelved-id 2026-09-02T00:00:00
# doing-cold and no-worktree deliberately get no transcript.
# doing-live gets a live tmux session instead of a transcript fixture.
tmux new-session -d -s "proj--doing-live" -c "$FIXTURE_CODE/proj/.worktrees/feat/doing-live" 2>/dev/null
tmux set-option -t "=proj--doing-live:" @wb_repo proj >/dev/null
tmux set-option -t "=proj--doing-live:" @wb_slug feat/doing-live >/dev/null

# --- default (normal) mode: two dormant rows, nothing else ------------------
out="$(collect_dormant_rows normal)"
assert "normal mode: doing-dormant present" 'proj--doing-dormant\.md' "$out"
assert "normal mode: in-review present" 'proj--in-review\.md' "$out"
if printf '%s' "$out" | grep -q 'proj--shelved\.md'; then
  echo "FAIL - normal mode: paused task must not appear outside search"; fail=1
else
  echo "ok   - normal mode: paused task absent"
fi
for absent in doing-live planned-task doing-cold no-worktree; do
  if printf '%s' "$out" | grep -q "proj--$absent\.md"; then
    echo "FAIL - normal mode: proj--$absent must not appear"; fail=1
  else
    echo "ok   - normal mode: proj--$absent absent"
  fi
done
row_count="$(printf '%s\n' "$out" | grep -c 'proj--')"
if [ "$row_count" -eq 2 ]; then
  echo "ok   - normal mode: exactly 2 dormant rows"
else
  echo "FAIL - normal mode: expected exactly 2 dormant rows, got $row_count"; fail=1
fi

# --- search mode: paused joins the pool, planned still doesn't --------------
out="$(collect_dormant_rows search)"
assert "search mode: shelved (paused) appears" 'proj--shelved\.md' "$out"
if printf '%s' "$out" | grep -q 'proj--planned-task\.md'; then
  echo "FAIL - search mode: planned task must still be absent"; fail=1
else
  echo "ok   - search mode: planned task still absent"
fi

# --- row shape: kind=task, empty session/target, slug populated ------------
row="$(printf '%s\n' "$out" | grep 'proj--doing-dormant\.md')"
field_count="$(printf '%s' "$row" | awk -F'\t' '{print NF}')"
assert "dormant row: 12 raw fields" '^12$' "$field_count"
kind_field="$(printf '%s' "$row" | cut -f9)"
assert "dormant row: kind=task" '^task$' "$kind_field"
target_field="$(printf '%s' "$row" | cut -f6)"
session_field="$(printf '%s' "$row" | cut -f7)"
if [ -z "$target_field" ] && [ -z "$session_field" ]; then
  echo "ok   - dormant row: target and session both empty"
else
  echo "FAIL - dormant row: target/session should both be empty (got target='$target_field' session='$session_field')"; fail=1
fi
slug_field="$(printf '%s' "$row" | cut -f11)"
assert "dormant row: slug populated from branch:" '^feat/doing-dormant$' "$slug_field"

# --- age rendering: a transcript 2 days old reads "...2d" -------------------
mk_task 'proj--two-days-old' doing proj feat/two-days-old
mkdir -p "$FIXTURE_CODE/proj/.worktrees/feat/two-days-old"
mk_transcript "$FIXTURE_CODE/proj/.worktrees/feat/two-days-old" agedid "$(date -u -d '2 days ago' +%Y-%m-%dT%H:%M:%S)"
out="$(collect_dormant_rows normal | grep 'proj--two-days-old\.md')"
assert "age rendering: 2 days old reads 2d" '2d' "$out"
tmux kill-session -t "=proj--doing-live" 2>/dev/null

# --- KTD8: a renamed live session still suppresses its dormant row ---------
mk_task 'proj--renamed-src' doing proj feat/renamed-src
mkdir -p "$FIXTURE_CODE/proj/.worktrees/feat/renamed-src"
mk_transcript "$FIXTURE_CODE/proj/.worktrees/feat/renamed-src" renamed-id 2026-09-07T00:00:00
tmux new-session -d -s "proj--renamed-src" -c "$FIXTURE_CODE/proj/.worktrees/feat/renamed-src" 2>/dev/null
tmux set-option -t "=proj--renamed-src:" @wb_repo proj >/dev/null
tmux set-option -t "=proj--renamed-src:" @wb_slug feat/renamed-src >/dev/null
# Confirm it WOULD be dormant before the rename (session name still matches
# the stem, but there's no @task option pointing at it yet — wb_new always
# sets one; simulate that here too so wb_session_task_file resolves it).
tmux set-option -t "=proj--renamed-src:" @task "$FIXTURE_TASKS/proj--renamed-src.md" >/dev/null
tmux rename-session -t "=proj--renamed-src:" "totally-different-name"
out="$(collect_dormant_rows normal)"
if printf '%s' "$out" | grep -q 'proj--renamed-src\.md'; then
  echo "FAIL - a renamed live session's task must not read as dormant"; fail=1
else
  echo "ok   - a renamed live session's task correctly stays off the dormant list"
fi
tmux kill-session -t "=totally-different-name" 2>/dev/null

# --- picker's periodic auto-refresh never blocks on typing (R14) -----------
# The fix is at the bind level: the periodic `load:` reload uses plain
# `reload(...)`, not the blocking `reload-sync(...)` every other action
# bind uses — render_rows itself re-reads the mode file fresh on every
# call, so a stale in-flight refresh mid-search still renders the correctly
# widened pool rather than clobbering it (see render_rows's own header
# comment). Source-text guard, same convention as wb-schema.test.sh's
# _ctrl_x self-guard check — a live "typing is never interrupted" claim
# needs a genuinely attached client to observe, disproportionate here.
picker_block="$(awk '/^picker\(\) \{/{p=1} p{print} p&&/^}/{exit}' "$WB")"
assert "picker: periodic load bind uses async reload, not reload-sync" \
  'load:reload\(sleep 3' "$picker_block"
if printf '%s' "$picker_block" | grep -q 'load:reload-sync'; then
  echo "FAIL - picker: the periodic load bind must not be reload-sync (blocks typing)"; fail=1
else
  echo "ok   - picker: the periodic load bind is not reload-sync"
fi
assert "picker: entering search widens the pool via a reload" \
  'i:.*_set-mode.*search.*reload-sync' "$picker_block"

# --- tmux.conf: the picker launches with a neutral cwd (R15) ---------------
TMUX_CONF="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../../.." && pwd)/tmux/.config/tmux/tmux.conf"
if [ -f "$TMUX_CONF" ]; then
  bind_m="$(grep '^bind m new-window' "$TMUX_CONF")"
  bind_a="$(grep '^bind a new-window' "$TMUX_CONF")"
  assert "tmux.conf: bind m launches the picker with -c \$HOME" '.-c "\$HOME"' "$bind_m"
  assert "tmux.conf: bind a launches the picker with -c \$HOME" '.-c "\$HOME"' "$bind_a"
else
  echo "FAIL - could not locate tmux.conf at $TMUX_CONF"; fail=1
fi

[ "$fail" -eq 0 ] && echo "ALL PASS" || echo "FAILURES"
exit "$fail"
