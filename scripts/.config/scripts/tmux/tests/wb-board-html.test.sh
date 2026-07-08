#!/usr/bin/env bash
# Tests for `wb board --html` (U4/U5) — plain-bash assertions against a
# fixture task store + fixture git repos, same convention as
# wb-board.test.sh. Sources wb.sh (safe: see the BASH_SOURCE guard at the
# bottom of wb.sh) and stubs wb_reconcile_repos to point at real fixture
# git repos, since untracked-worktree detection needs real git state.
# Run: bash scripts/.config/scripts/tmux/tests/wb-board-html.test.sh
set -uo pipefail

WB="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/wb.sh"
FIXTURE_TASKS="$(mktemp -d -t wb-board-html-tasks.XXXXXX)"
FIXTURE_CODE="$(mktemp -d -t wb-board-html-code.XXXXXX)"
trap 'rm -rf "$FIXTURE_TASKS" "$FIXTURE_CODE"' EXIT

fail=0
assert() { # <desc> <expected-regex> <actual>
  if printf '%s' "$3" | grep -qE "$2"; then
    echo "ok   - $1"
  else
    echo "FAIL - $1"
    echo "       expected match: $2"
    echo "       got: $(printf '%s' "$3" | head -5)"
    fail=1
  fi
}
assert_not() { # <desc> <unexpected-regex> <actual>
  if printf '%s' "$3" | grep -qE "$2"; then
    echo "FAIL - $1 (unexpectedly present)"
    fail=1
  else
    echo "ok   - $1"
  fi
}

mk_repo() {
  git init -q "$1"
  git -C "$1" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
}
add_worktree() { git -C "$1" worktree add -q -b "$2" ".worktrees/$2" >/dev/null 2>&1; }

mk_task() { # <file> <status> <repo> <branch> <worktree> <created> <closed> <title>
  local f="$FIXTURE_TASKS/$1"
  {
    printf -- '---\nstatus: %s\nrepo: %s\nbranch: %s\nworktree: %s\ntags: []\ncreated: %s\nclosed: %s\n---\n' \
      "$2" "$3" "$4" "$5" "$6" "$7"
    printf '# %s\n\n## Plan\n\nDo the thing.\n\n## Done\n\n' "$8"
  } > "$f"
}

mk_repo "$FIXTURE_CODE/proj"
add_worktree "$FIXTURE_CODE/proj" doing-branch
add_worktree "$FIXTURE_CODE/proj" planned-branch
add_worktree "$FIXTURE_CODE/proj" untracked-branch

TODAY="$(date +%F)"
OLD_DATE="$(date -d '3 days ago' +%F)"

mk_task 'proj--doing-branch.md'   doing   proj doing-branch   .worktrees/doing-branch   "$TODAY" ''       'Doing Task'
mk_task 'proj--planned-branch.md' planned proj planned-branch .worktrees/planned-branch "$OLD_DATE" ''    'Planned Task'
mk_task 'proj--old-done.md'       done    proj old-done       ''                        "$OLD_DATE" "$OLD_DATE" 'Old Done Task'
# Backdate mtime too — otherwise "updated" (file mtime, freshly created by
# this test) would satisfy the timeline window regardless of the created:
# frontmatter, defeating the point of testing created-date-only inclusion.
touch -d "$OLD_DATE" "$FIXTURE_TASKS/proj--planned-branch.md" "$FIXTURE_TASKS/proj--old-done.md"

# shellcheck disable=SC1090
source "$WB"
set +e   # wb.sh sets -e; this test captures non-zero exits by design
TASKS_DIR="$FIXTURE_TASKS"
CODE_DIR="$FIXTURE_CODE"
wb_reconcile_repos() { printf '%s\n' "$FIXTURE_CODE/proj"; }

html="$(wb_board_render_html 2>&1)"
# Flattened to one line: panels wrap embedded newlines from their own row/
# detail loops, so a line-based sed/awk range is fragile — extract_panel
# below works on the flattened blob instead, using the actual emission
# order (win outer loop: today, week; tab inner loop: all, inprogress,
# upcoming, paused, deferred, unclassified — see wb_board_render_html).
flat="$(printf '%s' "$html" | tr '\n' ' ')"

# extract_panel <panel_id> [<next_panel_id>] — the substring between this
# panel's opening tag and the next panel's opening tag (or EOF if omitted).
extract_panel() {
  local rest="${flat#*id=\"panel-$1\">}"
  if [ -n "${2:-}" ]; then
    printf '%s' "${rest%%id=\"panel-$2\"*}"
  else
    printf '%s' "$rest"
  fi
}

# --- structure: all 12 panels present, valid-looking HTML -------------------
for tab in all inprogress upcoming paused deferred unclassified; do
  for win in today week; do
    assert "panel-$tab-$win present" "id=\"panel-$tab-$win\"" "$html"
  done
done
css_rule_count="$(printf '%s' "$html" | grep -c 'display: flex; }')"
if [ "$css_rule_count" -eq 12 ]; then
  echo "ok   - 12 CSS toggle rules present"
else
  echo "FAIL - expected 12 CSS toggle rules, got $css_rule_count"; fail=1
fi

# --- bucketing -----------------------------------------------------------
all_today="$(extract_panel all-today inprogress-today)"
assert "doing task appears in All/Today (created today)" 'Doing Task' "$all_today"

inprogress_today="$(extract_panel inprogress-today upcoming-today)"
assert "doing task appears in In Progress/Today" 'Doing Task' "$inprogress_today"
assert_not "planned task absent from In Progress/Today" 'Planned Task' "$inprogress_today"

upcoming_week="$(extract_panel upcoming-week paused-week)"
assert "planned task (created 3d ago) appears in Upcoming/Week" 'Planned Task' "$upcoming_week"

upcoming_today="$(extract_panel upcoming-today paused-today)"
assert_not "planned task (created 3d ago) absent from Upcoming/Today" 'Planned Task' "$upcoming_today"

# --- untracked worktree lands in Unclassified, not elsewhere -----------------
unclassified_week="$(extract_panel unclassified-week)"
assert "untracked worktree appears in Unclassified" 'untracked-branch' "$unclassified_week"
assert "untracked worktree marked no task file" 'no task file' "$unclassified_week"

paused_week="$(extract_panel paused-week deferred-week)"
assert_not "untracked worktree absent from Paused" 'untracked-branch' "$paused_week"

# --- done task only in All, never in a named status tab ----------------------
all_week="$(extract_panel all-week inprogress-week)"
assert "done task (closed 3d ago) appears in All/Week" 'Old Done Task' "$all_week"
assert_not "done task absent from In Progress/Week" 'Old Done Task' "$(extract_panel inprogress-week upcoming-week)"

# --- Deferred is always empty with its own message ---------------------------
deferred_today="$(extract_panel deferred-today unclassified-today)"
assert "Deferred empty-state message" 'reserved for a future' "$deferred_today"

# --- HTML escaping ------------------------------------------------------------
mk_task 'proj--escaped.md' doing proj escaped-branch '' "$TODAY" '' 'Fix <script> & "quotes"'
html2="$(wb_board_render_html 2>&1)"
assert "title HTML-escaped" 'Fix &lt;script&gt; &amp;' "$html2"
assert_not "raw unescaped title not injected" 'Fix <script>' "$html2"

# --- empty store: no crash, empty-state everywhere ---------------------------
EMPTY_TASKS="$(mktemp -d -t wb-board-html-empty.XXXXXX)"
EMPTY_CODE="$(mktemp -d -t wb-board-html-empty-code.XXXXXX)"
TASKS_DIR="$EMPTY_TASKS"
CODE_DIR="$EMPTY_CODE"
wb_reconcile_repos() { :; }
empty_html="$(wb_board_render_html 2>&1)"; rc=$?
assert "empty store: exits 0" '^' "$rc-ok"; [ "$rc" -eq 0 ] || { echo "FAIL - exit $rc"; fail=1; }
assert "empty store: All/Today shows empty state" 'No tasks in this view' "$empty_html"
rm -rf "$EMPTY_TASKS" "$EMPTY_CODE"

[ "$fail" -eq 0 ] && echo "ALL PASS" || echo "FAILURES"
exit "$fail"
