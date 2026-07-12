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
# assert/assert_not use a here-string (<<<), never `printf | grep -q` — U6
# pushed real render fixtures well past the 64KB pipe buffer, and `grep -q`
# exits the instant it finds a match without draining the rest of stdin;
# under this script's own `pipefail`, an upstream `printf` still writing
# when that happens gets SIGPIPE and its non-zero exit becomes the
# pipeline's reported status even though grep DID match — a false FAIL.
# A here-string has no separate producer process to receive that signal.
assert() { # <desc> <expected-regex> <actual>
  if grep -qE "$2" <<< "$3"; then
    echo "ok   - $1"
  else
    echo "FAIL - $1"
    echo "       expected match: $2"
    echo "       got: $(head -5 <<< "$3")"
    fail=1
  fi
}
assert_not() { # <desc> <unexpected-regex> <actual>
  if grep -qE "$2" <<< "$3"; then
    echo "FAIL - $1 (unexpectedly present)"
    fail=1
  else
    echo "ok   - $1"
  fi
}
assert_empty() { # <desc> <actual> — assert's own '^$' pattern never matches
  # a truly empty string (grep sees zero lines, not one empty line).
  if [ -z "$2" ]; then
    echo "ok   - $1"
  else
    echo "FAIL - $1 (expected empty, got: $2)"
    fail=1
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

# --- structure: all 13 panels present (12 bucket + 1 pipeline), valid-
# looking HTML (U5) -----------------------------------------------------
for tab in all inprogress upcoming paused deferred unclassified; do
  for win in today week; do
    assert "panel-$tab-$win present" "id=\"panel-$tab-$win\"" "$html"
  done
done
assert "panel-pipeline present (U5, window-independent, single panel)" 'id="panel-pipeline"' "$html"

css_rule_count="$(printf '%s' "$html" | grep -c 'display: flex; }')"
if [ "$css_rule_count" -eq 14 ]; then
  echo "ok   - 14 CSS toggle rules present (12 bucket + 2 pipeline, one per window)"
else
  echo "FAIL - expected 14 CSS toggle rules, got $css_rule_count"; fail=1
fi

# --- active-tab highlight: every radio has a rule targeting ITS OWN label --
# Regression coverage for a real bug: radios and labels aren't adjacent
# siblings (labels live in <header>, away from the hidden radios), so a
# plain `input:checked + label` rule silently never matches anything —
# every tab looked selected-or-not identically. Each radio needs its own
# `#id:checked ~ header label[for="id"]` rule instead.
highlight_rule_count="$(printf '%s' "$html" | grep -c 'label\[for=')"
if [ "$highlight_rule_count" -eq 9 ]; then
  echo "ok   - 9 active-tab highlight rules present (2 timeline + 6 status + pipeline)"
else
  echo "FAIL - expected 9 active-tab highlight rules, got $highlight_rule_count"; fail=1
fi
assert "pipeline tab is checked by default (approved mockup)" '<input type="radio" name="st" id="st-pipeline" checked>' "$html"
assert "highlight rule targets its own label by for=" '#st-paused:checked ~ header label\[for="st-paused"\]' "$html"
assert_not "no dead adjacent-sibling highlight rule left behind" 'checked \+ label' "$html"

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

# --- always-present summary line ----------------------------------------
assert "summary line present for a task with Plan/Done content too" \
  'A <code>doing</code> task in <code>proj</code>, branch <code>doing-branch</code>, created' \
  "$(extract_panel all-today inprogress-today)"

# --- related-doc links: only for docs the task's own prose already names ---
DOC_ROOT="$(mktemp -d -t wb-board-html-docroot.XXXXXX)"
git init -q "$DOC_ROOT"
mkdir -p "$DOC_ROOT/scripts/.config/scripts/tmux" "$DOC_ROOT/docs/plans" "$DOC_ROOT/logs/decisions"
git -C "$DOC_ROOT" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
echo "plan md" > "$DOC_ROOT/docs/plans/2026-07-08-x-plan.md"
echo "plan html" > "$DOC_ROOT/docs/plans/2026-07-08-x-plan.html"
echo "decision" > "$DOC_ROOT/logs/decisions/2026-07-06-y.md"
echo "gone" > "/tmp/wb-board-html-nonexistent-marker"   # sentinel, never referenced
SCRIPT_DIR_REAL="$SCRIPT_DIR"
SCRIPT_DIR="$DOC_ROOT/scripts/.config/scripts/tmux"

cat > "$FIXTURE_TASKS/proj--doclinks.md" <<EOF
---
status: doing
repo: proj
branch: doclinks-branch
worktree: .worktrees/doclinks-branch
tags: []
created: $TODAY
closed:
---
# Doc Links Task

## Plan

## Done

## Decisions

- \`docs/plans/2026-07-08-x-plan.md\` — the plan (has a rendered .html sibling).
- \`dotfiles/logs/decisions/2026-07-06-y.md\` — a decision (dotfiles/-prefixed, no .html sibling).
- \`docs/plans/2026-07-08-does-not-exist.md\` — never written to disk, must not link dead.
EOF
html3="$(wb_board_render_html 2>&1)"
doclinks_panel="$(printf '%s' "$html3" | tr '\n' ' ')"
doclinks_panel="${doclinks_panel#*id=\"panel-all-today\">}"
doclinks_panel="${doclinks_panel%%id=\"panel-inprogress-today\"*}"

assert "doc reference upgraded to its rendered .html sibling" \
  'href="\.\./docs/plans/2026-07-08-x-plan\.html"' "$doclinks_panel"
assert "dotfiles/-prefixed reference stripped and linked (no .html sibling, stays .md)" \
  'href="decisions/2026-07-06-y\.md"' "$doclinks_panel"
assert_not "reference to a file never written to disk is not linked" \
  'does-not-exist' "$doclinks_panel"

SCRIPT_DIR="$SCRIPT_DIR_REAL"
rm -rf "$DOC_ROOT" "/tmp/wb-board-html-nonexistent-marker"

# --- HTML escaping ------------------------------------------------------------
mk_task 'proj--escaped.md' doing proj escaped-branch '' "$TODAY" '' 'Fix <script> & "quotes"'
html2="$(wb_board_render_html 2>&1)"
assert "title HTML-escaped" 'Fix &lt;script&gt; &amp;' "$html2"
assert_not "raw unescaped title not injected" 'Fix <script>' "$html2"

# --- parent/children rollup disclosure (U3) ---------------------------------
DOC_ROOT2="$(mktemp -d -t wb-board-html-docroot2.XXXXXX)"
git init -q "$DOC_ROOT2"
mkdir -p "$DOC_ROOT2/scripts/.config/scripts/tmux" "$DOC_ROOT2/docs/plans"
git -C "$DOC_ROOT2" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
echo "parent plan"  > "$DOC_ROOT2/docs/plans/2026-07-09-parent-plan.md"
echo "child a plan" > "$DOC_ROOT2/docs/plans/2026-07-09-a-plan.md"
echo "child b plan" > "$DOC_ROOT2/docs/plans/2026-07-09-b-plan.md"
SCRIPT_DIR_REAL2="$SCRIPT_DIR"
SCRIPT_DIR="$DOC_ROOT2/scripts/.config/scripts/tmux"

mk_parent_task() { # <file> <status> <repo> <created> <closed> <title> <doc-ref-line>
  local f="$FIXTURE_TASKS/$1"
  {
    printf -- '---\nstatus: %s\nrepo: %s\nbranch: b\nworktree: .worktrees/x\nparent:\ntags: []\ncreated: %s\nclosed: %s\n---\n' \
      "$2" "$3" "$4" "$5"
    printf '# %s\n\n## Plan\n\n## Done\n\n## Decisions\n\n%s\n' "$6" "$7"
  } > "$f"
}
mk_child_task() { # <file> <status> <repo> <created> <closed> <title> <parent> <doc-ref-line>
  local f="$FIXTURE_TASKS/$1"
  {
    printf -- '---\nstatus: %s\nrepo: %s\nbranch: b\nworktree: .worktrees/x\nparent: %s\ntags: []\ncreated: %s\nclosed: %s\n---\n' \
      "$2" "$3" "$7" "$4" "$5"
    printf '# %s\n\n## Plan\n\n## Done\n\n## Decisions\n\n%s\n' "$6" "$8"
  } > "$f"
}

mk_parent_task 'proj--parent-y.md' doing proj "$TODAY" '' 'Parent Y' \
  '- `docs/plans/2026-07-09-parent-plan.md` — the parent'\''s own plan.'
mk_child_task 'proj--child-p.md' doing proj "$TODAY" '' 'Child P' proj--parent-y \
  '- `docs/plans/2026-07-09-a-plan.md` — child P'\''s plan.'
mk_child_task 'other--child-q.md' planned other "$OLD_DATE" '' 'Child Q' proj--parent-y \
  '- `docs/plans/2026-07-09-b-plan.md` — child Q'\''s plan.'
touch -d "$OLD_DATE" "$FIXTURE_TASKS/other--child-q.md"

# extract_task_card <flattened_html> <anchor_key> — the substring for just
# ONE task's own <div class="task-detail"> card: bounded on both ends (not
# just the opening anchor), since an unbounded suffix would leak whatever
# task's card happens to render next in store order into the assertions.
extract_task_card() {
  local rest="${1#*id=\"t-all-today-$2\">}"
  printf '%s' "${rest%%<div class=\"task-detail\"*}"
}

html4="$(wb_board_render_html 2>&1)"
flat4="$(printf '%s' "$html4" | tr '\n' ' ')"
parent_y_panel="$(extract_task_card "$flat4" proj--parent-y)"

assert "parent card: wraps in a details.parent-row disclosure" '<details open class="parent-row">' "$parent_y_panel"
assert "parent card: own-artifact count shown" '1 of its own artifacts' "$parent_y_panel"
assert "parent card: own doc link present" 'parent-plan\.md' "$parent_y_panel"
assert "parent card: child P listed with its status pill" '<span class="pill doing">doing</span> Child P' "$parent_y_panel"
assert "parent card: child Q listed, cross-repo, own status pill" '<span class="pill planned">planned</span> Child Q' "$parent_y_panel"
assert "parent card: child P's own doc link present in its child-row" 'a-plan\.md' "$parent_y_panel"
assert "parent card: child Q (outside today'\''s window) still listed" 'Child Q' "$parent_y_panel"
assert "parent card: rollup toggle names the correct count (2 docs across children)" 'Show 2 artifacts from sub-tasks too' "$parent_y_panel"
assert "parent card: rollup toggle body has both children'\''s docs" 'a-plan\.md' "$parent_y_panel"
assert "parent card: rollup toggle body has both children'\''s docs (b)" 'b-plan\.md' "$parent_y_panel"

# --- regression: a task with no children renders exactly as before ----------
doing_branch_panel="$(extract_task_card "$flat4" proj--doing-branch)"
assert_not "non-parent task: no details.parent-row wrapper" 'parent-row' "$doing_branch_panel"

# --- edge case: empty rollup (no docs anywhere) omits the nested toggle -----
mk_parent_task 'proj--empty-parent.md' doing proj "$TODAY" '' 'Empty Parent' ''
mk_child_task 'proj--empty-child.md' doing proj "$TODAY" '' 'Empty Child' proj--empty-parent ''
html5="$(wb_board_render_html 2>&1)"
flat5="$(printf '%s' "$html5" | tr '\n' ' ')"
empty_parent_panel="$(extract_task_card "$flat5" proj--empty-parent)"
assert "empty parent: 0 of its own artifacts, no crash" '0 of its own artifacts' "$empty_parent_panel"
# U6: every child row now also carries a compact mini-stepper (glyph +
# label per non-n/a stage) — a child with no docs still gets one, since
# every task has at least the default plan/work/review path declared.
assert "empty parent: child with no docs shows pill, title, and its mini-stepper" \
  '<span class="pill doing">doing</span> Empty Child <div class="mini-stepper">' "$empty_parent_panel"
assert_not "empty parent: no rollup toggle when the union is empty" 'Show .* artifact' "$empty_parent_panel"

# --- edge case: self-reference is excluded from its own children map -------
mk_parent_task 'proj--self.md' doing proj "$TODAY" '' 'Self Ref' ''
wb_set_frontmatter "$FIXTURE_TASKS/proj--self.md" parent 'proj--self'
html6="$(wb_board_render_html 2>&1)"
self_panel="$(extract_task_card "$(printf '%s' "$html6" | tr '\n' ' ')" proj--self)"
assert_not "self-reference: own card is not wrapped as a parent-row" 'parent-row' "$self_panel"

# --- integration: escaping applies to every new insertion point ------------
mk_parent_task 'proj--parent-esc.md' doing proj "$TODAY" '' 'Parent Esc' ''
mk_child_task 'proj--child-esc.md' doing proj "$TODAY" '' 'Fix <script> & "quotes"' proj--parent-esc ''
html7="$(wb_board_render_html 2>&1)"
assert "child title HTML-escaped inside a child-row" 'Fix &lt;script&gt; &amp;' "$html7"
assert_not "raw unescaped child title not injected" 'Fix <script>' "$html7"

SCRIPT_DIR="$SCRIPT_DIR_REAL2"
rm -rf "$DOC_ROOT2"

# =============================================================================
# U4: render pre-pass — html-escape quote regression, dependency-graph
# helpers (unit-tested directly, nameref-style, same pattern wb_tsv_split
# already uses), and PR-fetch dedup.
# =============================================================================

# --- KTD-9: wb_board_html_escape gains `"` without regressing &<> ----------
esc_out="$(wb_board_html_escape '"<&>"')"
assert "wb_board_html_escape: quotes escaped (KTD-9)" '&quot;.*&lt;.*&amp;.*&gt;.*&quot;' "$esc_out"

# --- wb_board_parse_deps: whitespace-tolerant, empty entries dropped -------
assert "parse_deps: whitespace-tolerant, comma-separated" '^a,b,c,$' "$(wb_board_parse_deps 'a, b ,c' | tr '\n' ',')"
assert_empty "parse_deps: blank input -> nothing" "$(wb_board_parse_deps '')"

# --- wb_board_normalize_loop: starts at lexicographically smallest --------
assert "normalize_loop: starts at smallest stem, closes the loop" '^a -> c -> a$' "$(wb_board_normalize_loop 'c a')"

# --- wb_board_deps_validate: resolved stem kept, no dangling warning -------
declare -A DV_DEPS=([anchor-b]=$'a\n')
declare -A DV_STEM_ANCHOR=([a]=anchor-a)
declare -A DV_DANGLE=()
wb_board_deps_validate DV_DEPS DV_STEM_ANCHOR DV_DANGLE
assert "deps_validate: resolved stem kept in deps_of" '^a$' "${DV_DEPS[anchor-b]}"
assert_empty "deps_validate: no dangling warning for a resolved stem" "${DV_DANGLE[anchor-b]:-}"

# --- wb_board_deps_validate: Covers AE9 — dangling stem fails open --------
declare -A DV2_DEPS=([anchor-x]=$'missing-stem\n')
declare -A DV2_STEM_ANCHOR=()
declare -A DV2_DANGLE=()
wb_board_deps_validate DV2_DEPS DV2_STEM_ANCHOR DV2_DANGLE
assert "deps_validate: dangling stem -> warning naming it (AE9)" 'missing-stem' "${DV2_DANGLE[anchor-x]}"
assert_empty "deps_validate: dangling stem dropped from deps_of (renders unblocked)" "${DV2_DEPS[anchor-x]}"

# --- wb_board_deps_cycles: Covers AE5 — mutual dependency both flagged ----
declare -A DC_DEPS=([anchor-a]=$'c\n' [anchor-c]=$'a\n')
declare -A DC_STEM_ANCHOR=([a]=anchor-a [c]=anchor-c)
declare -A DC_ANCHOR_STEM=([anchor-a]=a [anchor-c]=c)
declare -A DC_MEMBER=() DC_WARN=()
wb_board_deps_cycles DC_DEPS DC_STEM_ANCHOR DC_ANCHOR_STEM DC_MEMBER DC_WARN
assert "deps_cycles: a flagged as cycle member (AE5)" '^1$' "${DC_MEMBER[anchor-a]:-}"
assert "deps_cycles: c flagged as cycle member (AE5)" '^1$' "${DC_MEMBER[anchor-c]:-}"
assert "deps_cycles: warning names both stems" 'a.*c|c.*a' "${DC_WARN[anchor-a]}"
if [ "${DC_WARN[anchor-a]}" = "${DC_WARN[anchor-c]}" ]; then
  echo "ok   - deps_cycles: both members show the identical normalized warning string (KTD-6)"
else
  echo "FAIL - deps_cycles: warning strings differ between cycle members"; fail=1
fi

# --- wb_board_deps_blocking: chain a->b->c, a done -> b unblocked, c still
# blocked by b (flat resolution, no transitive met-ness) --------------------
declare -A CH_DEPS=([anchor-b]=$'a\n' [anchor-c]=$'b\n')
declare -A CH_STEM_ANCHOR=([a]=anchor-a [b]=anchor-b [c]=anchor-c)
declare -A CH_STEM_STATUS=([a]=done [b]=doing [c]=doing)
declare -A CH_ANCHOR_STEM=([anchor-a]=a [anchor-b]=b [anchor-c]=c)
declare -A CH_MEMBER=()
declare -A CH_UNMET=() CH_NAMES=() CH_UNBLOCKS=() CH_UNBLOCKS_NAMES=()
wb_board_deps_blocking CH_DEPS CH_STEM_ANCHOR CH_STEM_STATUS CH_ANCHOR_STEM CH_MEMBER \
  CH_UNMET CH_NAMES CH_UNBLOCKS CH_UNBLOCKS_NAMES
assert_empty "deps_blocking: chain — b unblocked once a is done" "${CH_UNMET[anchor-b]:-}"
assert "deps_blocking: chain — c still blocked by b (not transitively met)" '^1$' "${CH_UNMET[anchor-c]:-}"

# --- wb_board_deps_blocking: two blockers, one done -> still blocked,
# unmet count 1; blocker's dependents count reflects both directions -------
declare -A TB_DEPS=([anchor-x]=$'a\nb\n')
declare -A TB_STEM_ANCHOR=([a]=anchor-a [b]=anchor-b [x]=anchor-x)
declare -A TB_STEM_STATUS=([a]=done [b]=doing [x]=doing)
declare -A TB_ANCHOR_STEM=([anchor-a]=a [anchor-b]=b [anchor-x]=x)
declare -A TB_MEMBER=()
declare -A TB_UNMET=() TB_NAMES=() TB_UNBLOCKS=() TB_UNBLOCKS_NAMES=()
wb_board_deps_blocking TB_DEPS TB_STEM_ANCHOR TB_STEM_STATUS TB_ANCHOR_STEM TB_MEMBER \
  TB_UNMET TB_NAMES TB_UNBLOCKS TB_UNBLOCKS_NAMES
assert "deps_blocking: two blockers, one done -> still blocked, unmet=1" '^1$' "${TB_UNMET[anchor-x]:-}"
assert_empty "deps_blocking: done blocker contributes no unblocks count" "${TB_UNBLOCKS[anchor-a]:-}"
assert "deps_blocking: not-done blocker shows 1 dependent waiting (both directions visible, R17)" \
  '^1$' "${TB_UNBLOCKS[anchor-b]:-}"

# --- wb_board_deps_blocking: mid-chain — b is simultaneously blocked (by a)
# and blocking (c waits on it) — both indicators render at once -------------
declare -A MC_DEPS=([anchor-b]=$'a\n' [anchor-c]=$'b\n')
declare -A MC_STEM_ANCHOR=([a]=anchor-a [b]=anchor-b [c]=anchor-c)
declare -A MC_STEM_STATUS=([a]=doing [b]=doing [c]=doing)
declare -A MC_ANCHOR_STEM=([anchor-a]=a [anchor-b]=b [anchor-c]=c)
declare -A MC_MEMBER=()
declare -A MC_UNMET=() MC_NAMES=() MC_UNBLOCKS=() MC_UNBLOCKS_NAMES=()
wb_board_deps_blocking MC_DEPS MC_STEM_ANCHOR MC_STEM_STATUS MC_ANCHOR_STEM MC_MEMBER \
  MC_UNMET MC_NAMES MC_UNBLOCKS MC_UNBLOCKS_NAMES
assert "deps_blocking: mid-chain — b carries an unmet-blocker count (⛔)" '^1$' "${MC_UNMET[anchor-b]:-}"
assert "deps_blocking: mid-chain — b simultaneously carries an unblocks count (→), independent facts" \
  '^1$' "${MC_UNBLOCKS[anchor-b]:-}"

# --- KTD-1: gh call deduped by repo+branch, one fetch per DISTINCT branch,
# not per task. The stub writes to a COUNTER FILE, not a shell variable:
# wb_board_pr_info is invoked via a command-substitution subshell
# ("$(wb_board_pr_info ...)"), so a plain variable increment inside the
# stub would be lost the moment that subshell exits — a file write
# survives across the subshell boundary. The assertion compares counts
# rather than asserting an absolute number, since the store already has
# many earlier fixtures on other branches by this point in the file —
# adding a SECOND task on an ALREADY-fetched branch must not raise the
# fetch count any further than adding just the FIRST one did. ------------
ORIG_PR_INFO="$(declare -f wb_board_pr_info)"
PR_COUNTFILE="$(mktemp -t wb-board-html-prcount.XXXXXX)"
wb_board_pr_info() { echo x >> "$PR_COUNTFILE"; printf '#1 (OPEN)\thttps://example.com/1'; }
mk_task 'proj--prcount-a.md' doing proj prcount-branch '' "$TODAY" '' 'PR Count A'
wb_board_render_html >/dev/null 2>&1
count_one_task="$(wc -l < "$PR_COUNTFILE" | tr -d ' ')"
: > "$PR_COUNTFILE"
mk_task 'proj--prcount-b.md' doing proj prcount-branch '' "$TODAY" '' 'PR Count B'
wb_board_render_html >/dev/null 2>&1
count_two_tasks_same_branch="$(wc -l < "$PR_COUNTFILE" | tr -d ' ')"
assert "pr fetch: a second task on an already-fetched branch adds no extra fetch (KTD-1 dedup)" \
  "^${count_one_task}\$" "$count_two_tasks_same_branch"
rm -f "$PR_COUNTFILE"
eval "$ORIG_PR_INFO"

# --- U4's hoist is behavior-preserving: the entire suite above (doc links,
# escaping, parent/child rollup, untracked-worktree badges) still passes
# unchanged after moving live-session/PR lookups into the pre-pass — that
# IS the before/after-identical-content proof (no separate assertion to
# duplicate here).

# =============================================================================
# U5: Pipeline tab
# =============================================================================

# --- one row per in-flight task regardless of window, including a task
# stale enough to fall outside every window filter; done tasks absent ------
VERY_OLD="$(date -d '90 days ago' +%F)"
add_worktree "$FIXTURE_CODE/proj" pipe-stale
mk_task 'proj--pipe-stale.md' doing proj pipe-stale .worktrees/pipe-stale "$VERY_OLD" '' 'Pipe Stale Task'
touch -d "$VERY_OLD" "$FIXTURE_TASKS/proj--pipe-stale.md"
html_pipe="$(wb_board_render_html 2>&1)"
flat_pipe="$(printf '%s' "$html_pipe" | tr '\n' ' ')"
# NOT extract_panel (that helper reads the top-of-file global $flat,
# captured long before these fixtures existed) — slice the FRESH flat_pipe
# to start at the pipeline panel's own opening tag instead.
pipe_panel="${flat_pipe#*id=\"panel-pipeline\">}"
assert "pipeline: stale task (outside every window) still listed (R9)" 'Pipe Stale Task' "$pipe_panel"
assert_not "pipeline: done task (Old Done Task) absent" 'Old Done Task' "$pipe_panel"
assert_not "pipeline: untracked worktree row absent (no task file, no intent)" 'untracked-branch' "$pipe_panel"

# --- AE1: work cell state via stubbed PR (no real git commits needed —
# R3's PR-any-state signal), work in progress while doing, done once
# status flips to done and the PR is no longer OPEN --------------------------
ORIG_PR_INFO2="$(declare -f wb_board_pr_info)"
add_worktree "$FIXTURE_CODE/proj" pipe-ae1
mk_task 'proj--pipe-ae1.md' doing proj pipe-ae1 .worktrees/pipe-ae1 "$TODAY" '' 'Pipe AE1 Task'
wb_board_pr_info() { printf '#9 (MERGED)\thttps://example.com/pr/9'; }
html_ae1="$(wb_board_render_html 2>&1)"
ae1_card="$(extract_task_card "$(printf '%s' "$html_ae1" | tr '\n' ' ')" proj--pipe-ae1)"
pipe_panel_ae1="$(printf '%s' "$html_ae1" | tr '\n' ' ')"
pipe_panel_ae1="${pipe_panel_ae1#*id=\"panel-pipeline\">}"
assert "pipeline AE1: doing + PR (any state) -> work cell in-progress glyph" '&#9681;' "$pipe_panel_ae1"
wb_set_frontmatter "$FIXTURE_TASKS/proj--pipe-ae1.md" status done
html_ae1b="$(wb_board_render_html 2>&1)"
pipe_panel_ae1b="$(printf '%s' "$html_ae1b" | tr '\n' ' ')"
pipe_panel_ae1b="${pipe_panel_ae1b#*id=\"panel-pipeline\">}"
assert_not "pipeline AE1: status:done task absent from Pipeline (R9 — non-done only)" 'Pipe AE1 Task' "$pipe_panel_ae1b"
eval "$ORIG_PR_INFO2"

# --- AE7: path: work,review -> ideate/brainstorm/plan cells render the n/a
# glyph (faint middle dot), not pending -------------------------------------
add_worktree "$FIXTURE_CODE/proj" pipe-ae7
{
  printf -- '---\nstatus: doing\nrepo: proj\nbranch: pipe-ae7\nworktree: .worktrees/pipe-ae7\npath: work,review\ntags: []\ncreated: %s\nclosed:\n---\n' "$TODAY"
  printf '# Pipe AE7 Task\n\n## Plan\n\n## Done\n\n'
} > "$FIXTURE_TASKS/proj--pipe-ae7.md"
html_ae7="$(wb_board_render_html 2>&1)"
flat_ae7="$(printf '%s' "$html_ae7" | tr '\n' ' ')"
pipe_panel_ae7="${flat_ae7#*id=\"panel-pipeline\">}"
pipe_row_ae7="${pipe_panel_ae7#*Pipe AE7 Task}"
pipe_row_ae7="${pipe_row_ae7%%</tr>*}"
na_count="$(printf '%s' "$pipe_row_ae7" | grep -o '&#183;' | wc -l | tr -d ' ')"
assert "pipeline AE7: path work,review -> exactly 3 n/a stage cells (ideate/brainstorm/plan)" '^3$' "$na_count"

# --- R11/KTD-5: stage cell for a done plan links to the plan doc; work
# cell links to the PR URL when pr_info is stubbed; a branch-only doc
# (worktree gone, unmerged) renders an unlinked glyph with a tooltip -------
add_worktree "$FIXTURE_CODE/proj" pipe-link-live
mkdir -p "$FIXTURE_CODE/proj/.worktrees/pipe-link-live/docs/plans"
printf '# plan\n' > "$FIXTURE_CODE/proj/.worktrees/pipe-link-live/docs/plans/2026-07-11-001-pipe-link-live-plan.md"
mk_task 'proj--pipe-link-live.md' doing proj pipe-link-live .worktrees/pipe-link-live "$TODAY" '' 'Pipe Link Live Task'
ORIG_PR_INFO3="$(declare -f wb_board_pr_info)"
wb_board_pr_info() { printf '#42 (OPEN)\thttps://example.com/pr/42'; }
html_link="$(wb_board_render_html 2>&1)"
flat_link="$(printf '%s' "$html_link" | tr '\n' ' ')"
pipe_panel_link="${flat_link#*id=\"panel-pipeline\">}"
row_link="${pipe_panel_link#*Pipe Link Live Task}"; row_link="${row_link%%</tr>*}"
assert "pipeline: done plan stage cell links to the plan doc (live worktree, KTD-5)" \
  'href="[^"]*2026-07-11-001-pipe-link-live-plan\.md"' "$row_link"
assert "pipeline: work stage cell links to the PR url when pr_info is stubbed" \
  'href="https://example\.com/pr/42"' "$row_link"
eval "$ORIG_PR_INFO3"

add_worktree "$FIXTURE_CODE/proj" pipe-link-kept
mkdir -p "$FIXTURE_CODE/proj/.worktrees/pipe-link-kept/docs/plans"
printf '# plan\n' > "$FIXTURE_CODE/proj/.worktrees/pipe-link-kept/docs/plans/2026-07-11-001-pipe-link-kept-plan.md"
git -C "$FIXTURE_CODE/proj/.worktrees/pipe-link-kept" add docs/plans
git -C "$FIXTURE_CODE/proj/.worktrees/pipe-link-kept" -c user.email=t@t -c user.name=t commit -q -m plan
git -C "$FIXTURE_CODE/proj" worktree remove --force ".worktrees/pipe-link-kept"
mk_task 'proj--pipe-link-kept.md' done proj pipe-link-kept .worktrees/pipe-link-kept "$TODAY" "$TODAY" 'Pipe Link Kept Task'
html_kept="$(wb_board_render_html 2>&1)"
card_kept="$(extract_task_card "$(printf '%s' "$html_kept" | tr '\n' ' ')" proj--pipe-link-kept)"
assert "pipeline/card: branch-only doc (worktree gone) renders unlinked glyph with a tooltip naming it" \
  'title="plan: done \(docs/plans/2026-07-11-001-pipe-link-kept-plan\.md\)"' "$card_kept"
assert_not "pipeline/card: branch-only doc never gets an href (nothing to link on disk)" \
  '<span class="glyph"><a href="[^"]*pipe-link-kept-plan' "$card_kept"

# --- Deps column: blocked fixture shows a blocked chip with tooltip; its
# blocker shows an unblocks chip; dep-free rows show the em-dash -----------
add_worktree "$FIXTURE_CODE/proj" pipe-blocker
add_worktree "$FIXTURE_CODE/proj" pipe-blocked
mk_task 'proj--pipe-blocker.md' doing proj pipe-blocker .worktrees/pipe-blocker "$TODAY" '' 'Pipe Blocker Task'
{
  printf -- '---\nstatus: doing\nrepo: proj\nbranch: pipe-blocked\nworktree: .worktrees/pipe-blocked\ndepends_on: proj--pipe-blocker\ntags: []\ncreated: %s\nclosed:\n---\n' "$TODAY"
  printf '# Pipe Blocked Task\n\n## Plan\n\n## Done\n\n'
} > "$FIXTURE_TASKS/proj--pipe-blocked.md"
html_deps="$(wb_board_render_html 2>&1)"
flat_deps="$(printf '%s' "$html_deps" | tr '\n' ' ')"
pipe_panel_deps="${flat_deps#*id=\"panel-pipeline\">}"
row_blocked="${pipe_panel_deps#*Pipe Blocked Task}"; row_blocked="${row_blocked%%</tr>*}"
row_blocker="${pipe_panel_deps#*Pipe Blocker Task}"; row_blocker="${row_blocker%%</tr>*}"
assert "pipeline deps: blocked task shows the ⛔ chip with count 1" 'dep-chip blocked".*&#9940; 1' "$row_blocked"
assert "pipeline deps: blocked task's row is dimmed" 'class="row blocked"' "$(printf '%s' "$pipe_panel_deps" | grep -o '<tr class="[^"]*"><td><a class="tasklink" href="#t-pipeline-proj--pipe-blocked">.*' | head -c 200)"
assert "pipeline deps: blocker task shows the → unblocks chip with count 1" 'dep-chip unblocks".*&#8594; 1' "$row_blocker"
assert "pipeline deps: dep-free task shows an em-dash" '&mdash;' "${pipe_panel_deps#*Pipe AE1 Task}"

# --- be--monorepo: a literal "--" in the repo name must not corrupt
# stem/anchor/repo-cell handling anywhere in the row -------------------------
mk_repo "$FIXTURE_CODE/be--monorepo"
add_worktree "$FIXTURE_CODE/be--monorepo" sfb-988
mk_task 'be--monorepo--sfb-988.md' doing be--monorepo sfb-988 .worktrees/sfb-988 "$TODAY" '' 'SFB 988 Task'
html_mono="$(wb_board_render_html 2>&1)"
flat_mono="$(printf '%s' "$html_mono" | tr '\n' ' ')"
pipe_panel_mono="${flat_mono#*id=\"panel-pipeline\">}"
assert "pipeline be--monorepo: row present with correct repo cell" 'SFB 988 Task.*<span class="repo">be--monorepo</span>' "$pipe_panel_mono"
assert "pipeline be--monorepo: anchor is well-formed (t-pipeline-be--monorepo--sfb-988)" \
  'id="t-pipeline-be--monorepo--sfb-988"' "$pipe_panel_mono"

# =============================================================================
# U6: two-zone cards, stepper, relationship indicators
# =============================================================================

# --- AE3: done task, worktree removed, branch carries the plan doc ->
# stepper's plan segment shows done, never pending ---------------------------
add_worktree "$FIXTURE_CODE/proj" u6-ae3
mkdir -p "$FIXTURE_CODE/proj/.worktrees/u6-ae3/docs/plans"
printf '# plan\n' > "$FIXTURE_CODE/proj/.worktrees/u6-ae3/docs/plans/2026-07-11-001-u6-ae3-plan.md"
git -C "$FIXTURE_CODE/proj/.worktrees/u6-ae3" add docs/plans
git -C "$FIXTURE_CODE/proj/.worktrees/u6-ae3" -c user.email=t@t -c user.name=t commit -q -m plan
git -C "$FIXTURE_CODE/proj" worktree remove --force ".worktrees/u6-ae3"
mk_task 'proj--u6-ae3.md' done proj u6-ae3 .worktrees/u6-ae3 "$TODAY" "$TODAY" 'U6 AE3 Task'
html_ae3="$(wb_board_render_html 2>&1)"
card_ae3="$(extract_task_card "$(printf '%s' "$html_ae3" | tr '\n' ' ')" proj--u6-ae3)"
# the kept-branch fallback also names the doc in the tooltip (nothing to
# link to once the worktree is gone, KTD-5) — match the prefix only, not
# the exact closing quote, so this doesn't over-constrain the tooltip text.
assert "U6 AE3: worktree removed, branch carries plan doc -> stepper shows plan done" \
  'step done" title="plan: done' "$card_ae3"
assert "U6 AE3: kept-branch match still names the doc, unlinked, in the tooltip/chip" \
  '2026-07-11-001-u6-ae3-plan\.md' "$card_ae3"
assert_not "U6 AE3: plan never renders pending for this task" 'title="plan: pending"' "$card_ae3"
assert "U6: done task card is structurally identical to an in-flight card (two-zone + stepper)" \
  '<div class="card-head">.*<div class="stepper">' "$card_ae3"

# --- AE4: blocked card dimmed with a ⛔ chip + tooltip; indicator clears
# once the blocker is marked done, no manual edit needed --------------------
add_worktree "$FIXTURE_CODE/proj" u6-ae4-blocker
mk_task 'proj--u6-ae4-blocker.md' doing proj u6-ae4-blocker .worktrees/u6-ae4-blocker "$TODAY" '' 'U6 AE4 Blocker'
{
  printf -- '---\nstatus: doing\nrepo: proj\nbranch: u6-ae4-blocked\nworktree: .worktrees/u6-ae4-blocked\ndepends_on: proj--u6-ae4-blocker\ntags: []\ncreated: %s\nclosed:\n---\n' "$TODAY"
  printf '# U6 AE4 Blocked\n\n## Plan\n\n## Done\n\n'
} > "$FIXTURE_TASKS/proj--u6-ae4-blocked.md"
html_ae4="$(wb_board_render_html 2>&1)"
card_ae4="$(extract_task_card "$(printf '%s' "$html_ae4" | tr '\n' ' ')" proj--u6-ae4-blocked)"
assert "U6 AE4: blocked card shows the ⛔ chip" 'dep-chip blocked' "$card_ae4"
wb_set_frontmatter "$FIXTURE_TASKS/proj--u6-ae4-blocker.md" status done
html_ae4b="$(wb_board_render_html 2>&1)"
card_ae4b="$(extract_task_card "$(printf '%s' "$html_ae4b" | tr '\n' ' ')" proj--u6-ae4-blocked)"
assert_not "U6 AE4: blocker done -> indicator gone on next render, no manual edit" 'dep-chip blocked' "$card_ae4b"

# --- AE6: parent with all children done while `doing` shows a 3/3 counter
# and the ready-to-close hint; parent's own pill is never altered; 2/3
# shows the counter but no hint ---------------------------------------------
mk_parent_task 'proj--u6-ae6-parent.md' doing proj "$TODAY" '' 'U6 AE6 Parent' ''
mk_child_task 'proj--u6-ae6-c1.md' done proj "$TODAY" "$TODAY" 'U6 AE6 C1' proj--u6-ae6-parent ''
mk_child_task 'proj--u6-ae6-c2.md' done proj "$TODAY" "$TODAY" 'U6 AE6 C2' proj--u6-ae6-parent ''
mk_child_task 'proj--u6-ae6-c3.md' done proj "$TODAY" "$TODAY" 'U6 AE6 C3' proj--u6-ae6-parent ''
html_ae6="$(wb_board_render_html 2>&1)"
card_ae6="$(extract_task_card "$(printf '%s' "$html_ae6" | tr '\n' ' ')" proj--u6-ae6-parent)"
assert "U6 AE6: 3/3 children done -> counter shown" '3/3 children done' "$card_ae6"
assert "U6 AE6: ready-to-close hint present at 3/3" 'ready-hint' "$card_ae6"
assert "U6 AE6: parent pill still reads doing" '<span class="pill doing">doing</span>' "$card_ae6"
wb_set_frontmatter "$FIXTURE_TASKS/proj--u6-ae6-c3.md" status doing
html_ae6b="$(wb_board_render_html 2>&1)"
card_ae6b="$(extract_task_card "$(printf '%s' "$html_ae6b" | tr '\n' ' ')" proj--u6-ae6-parent)"
assert "U6 AE6: 2/3 children done -> counter shown" '2/3 children done' "$card_ae6b"
assert_not "U6 AE6: 2/3 -> no ready-to-close hint" 'ready-hint' "$card_ae6b"

# --- R14: multiple matching docs for one stage all render as chips; the
# stepper segment itself links only the lexically newest --------------------
add_worktree "$FIXTURE_CODE/proj" u6-multidoc
mkdir -p "$FIXTURE_CODE/proj/.worktrees/u6-multidoc/docs/plans"
printf '# old\n' > "$FIXTURE_CODE/proj/.worktrees/u6-multidoc/docs/plans/2026-07-01-001-u6-multidoc-plan.md"
printf '# new\n' > "$FIXTURE_CODE/proj/.worktrees/u6-multidoc/docs/plans/2026-07-11-001-u6-multidoc-plan.md"
mk_task 'proj--u6-multidoc.md' doing proj u6-multidoc .worktrees/u6-multidoc "$TODAY" '' 'U6 Multidoc Task'
html_md="$(wb_board_render_html 2>&1)"
card_md="$(extract_task_card "$(printf '%s' "$html_md" | tr '\n' ' ')" proj--u6-multidoc)"
assert "U6 R14: older matching plan doc listed as a chip" '2026-07-01-001-u6-multidoc-plan\.md' "$card_md"
assert "U6 R14: newer matching plan doc listed as a chip" '2026-07-11-001-u6-multidoc-plan\.md' "$card_md"
assert "U6 R14: stepper segment links the lexically newest doc" \
  '<span class="glyph"><a href="[^"]*2026-07-11-001-u6-multidoc-plan\.md"' "$card_md"

# --- KTD-9: attribute-context escaping — a dangling depends_on: stem can
# carry arbitrary hand-edited text, and its warning lands inside a title=
# attribute, not just text content -------------------------------------------
{
  printf -- '---\nstatus: doing\nrepo: proj\nbranch: u6-attr-esc\nworktree: .worktrees/x\ndepends_on: proj--<script>\ntags: []\ncreated: %s\nclosed:\n---\n' "$TODAY"
  printf '# U6 Attr Esc Task\n\n## Plan\n\n## Done\n\n'
} > "$FIXTURE_TASKS/proj--u6-attr-esc.md"
html_attr="$(wb_board_render_html 2>&1)"
card_attr="$(extract_task_card "$(printf '%s' "$html_attr" | tr '\n' ' ')" proj--u6-attr-esc)"
assert "U6 KTD-9: dangling-stem warning escaped inside a title= attribute" \
  'title="depends on unresolved stem: proj--&lt;script&gt;"' "$card_attr"
assert_not "U6 KTD-9: no raw unescaped tag inside an attribute value" \
  'title="depends on unresolved stem: proj--<script>' "$card_attr"

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
