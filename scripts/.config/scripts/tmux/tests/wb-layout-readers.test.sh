#!/usr/bin/env bash
# Tests for U12 (script half, part A): wb.sh / handoff.sh readers of the
# dossier — _wb_concepts_paths, `wb new`'s seed (+ brief.md), `wb notes`, the
# follow-up count, the picker preview, `wb breakdown --apply`'s follow-up
# moves, the reconcile merge refusal and handoff.sh's follow-up writer — and
# the prefix+T notes key. Every task is on the dossier layout.
#
# Run in the Docker sandbox (see tests/Dockerfile):
#   docker run --rm -v "$(pwd)":/repo:ro -w /repo wb-tests \
#     bash scripts/.config/scripts/tmux/tests/wb-layout-readers.test.sh
set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPO_ROOT="$(cd "$SELF_DIR/../../../.." && pwd)"
WB="$SELF_DIR/wb.sh"
HANDOFF="$SELF_DIR/handoff.sh"

FIXTURE="$(mktemp -d -t wb-layout-readers-fixture.XXXXXX)"
REAL_TMUX="$(command -v tmux)"
SOCK="wb-layout-readers-sock-$$"
mkdir -p "$FIXTURE/bin"
# One fixed private socket for every tmux call (never the default server).
cat > "$FIXTURE/bin/tmux" <<EOF
#!/usr/bin/env bash
exec "$REAL_TMUX" -L "$SOCK" -f /dev/null "\$@"
EOF
chmod +x "$FIXTURE/bin/tmux"
PATH="$FIXTURE/bin:$PATH"
trap '"$REAL_TMUX" -L "$SOCK" kill-server 2>/dev/null || true; rm -rf "$FIXTURE"' EXIT

fail=0
assert() { # <desc> <expected-regex> <actual>
  if printf '%s' "$3" | grep -qE "$2"; then echo "ok   - $1"
  else echo "FAIL - $1"; echo "       expected match: $2"; echo "       got: $(printf '%s' "$3" | head -8)"; fail=1; fi
}
assert_not() { # <desc> <regex> <actual>
  if printf '%s' "$3" | grep -qE "$2"; then echo "FAIL - $1"; echo "       unexpected match: $2"; fail=1
  else echo "ok   - $1"; fi
}
assert_eq() { # <desc> <expected> <actual>
  if [ "$2" = "$3" ]; then echo "ok   - $1"
  else echo "FAIL - $1 (expected '$2', got '$3')"; fail=1; fi
}

export XDG_STATE_HOME="$FIXTURE/state"
export HOME="$FIXTURE/home"
export CODE_DIR="$FIXTURE/code"
export TASKS_DIR="$FIXTURE/tasks"
unset TMUX
mkdir -p "$XDG_STATE_HOME" "$HOME" "$CODE_DIR/proj" "$TASKS_DIR"
git init -q "$CODE_DIR/proj"
git -C "$CODE_DIR/proj" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init

printf -- '---\nstatus: planned\npath:\nrepo:\nbranch:\nworktree:\nparent:\ndepends_on:\nsize:\ntags: []\ncreated:\nclosed:\nreviewed:\n---\n# Title\n\n## Plan\n\n\n\n## Handoffs\n\n\n\n## Decisions\n\n\n\n## Done\n\n\n\n## Follow-ups\n' \
  > "$TASKS_DIR/TEMPLATE.md"

# shellcheck disable=SC1090
source "$HANDOFF"      # sources wb.sh too (the dispatch is guarded)
set +e

mk_task() { # <stem> [extra frontmatter lines...]
  local stem="$1"; shift
  { printf -- '---\nstatus: doing\nrepo: proj\nbranch: b\nlayout: dossier\n'
    printf 'tags: []\ncreated: 2026-07-01\nclosed:\n'
    for l in "$@"; do printf '%s\n' "$l"; done
    printf -- '---\n# Title %s\n\n' "$stem"
    printf '## Now\n\nnow text for %s\n\n' "$stem"
    printf '## Plan\n\nplan text\n\n## Handoffs\n\n'
  } > "$TASKS_DIR/$stem.md"
}
mk_item() { # <stem> <name> <status> <text>
  mkdir -p "$TASKS_DIR/dossiers/$1/open-items"
  printf -- '---\nwho:\nsince: 2026-07-01\nkind:\nstatus: %s\n---\n%s\n' "$3" "$4" > "$TASKS_DIR/dossiers/$1/open-items/$2.md"
}

# --- _wb_concepts_paths: concepts.md only (CONCEPTS.md is ignored) -------------
mk_task proj--cp-new
mk_task proj--cp-par
mkdir -p "$TASKS_DIR/dossiers/proj--cp-new" "$TASKS_DIR/dossiers/proj--cp-par"
: > "$TASKS_DIR/dossiers/proj--cp-new/concepts.md"
: > "$TASKS_DIR/dossiers/proj--cp-new/CONCEPTS.md"
: > "$TASKS_DIR/dossiers/proj--cp-par/concepts.md"
assert_eq "concepts: resolves concepts.md only" "$TASKS_DIR/dossiers/proj--cp-new/concepts.md" "$(_wb_concepts_paths "$TASKS_DIR/proj--cp-new.md")"
mk_task proj--cp-kid "parent: proj--cp-par"
mkdir -p "$TASKS_DIR/dossiers/proj--cp-kid"; : > "$TASKS_DIR/dossiers/proj--cp-kid/concepts.md"
assert_eq "concepts: chain, nearest first" \
  "$TASKS_DIR/dossiers/proj--cp-kid/concepts.md"$'\n'"$TASKS_DIR/dossiers/proj--cp-par/concepts.md" \
  "$(_wb_concepts_paths "$TASKS_DIR/proj--cp-kid.md")"
assert_eq "wb family --concepts follows concepts.md" "$TASKS_DIR/dossiers/proj--cp-new/concepts.md" "$(cmd_family proj--cp-new --concepts 2>&1)"

# --- wb new --planned under a parent -----------------------------------
mk_task proj--par-lay
out="$(printf 'Because the board lies.\n\nSecond paragraph stays out.\n' | cmd_new --planned --parent proj--par-lay --body - proj child-lay 2>&1)"; rc=$?
CL="$TASKS_DIR/proj--child-lay.md"
assert_eq "new --planned (parent): exit 0" 0 "$rc"
assert_eq "new --planned (parent): layout: dossier" "dossier" "$(wb_get_frontmatter "$CL" layout)"
assert "new --planned (parent): ## Now placeholder" '^## Now$' "$(cat "$CL")"
assert_not "new --planned (parent): no First-action line" 'First action' "$(cat "$CL")"
assert_not "new --planned (parent): no ## Decisions" '^## Decisions' "$(cat "$CL")"
assert_not "new --planned (parent): no ## Follow-ups" '^## Follow-ups' "$(cat "$CL")"
assert_not "new --planned (parent): no ## Done" '^## Done' "$(cat "$CL")"
assert "new --planned (parent): ## Plan kept with the body" 'Because the board lies' "$(cat "$CL")"
assert "new --planned (parent): ## Handoffs kept" '^## Handoffs$' "$(cat "$CL")"
assert_eq "new --planned (parent): sections in order" "Now Plan Handoffs" "$(grep '^## ' "$CL" | sed 's/^## //' | tr '\n' ' ' | sed 's/ $//')"
BR="$TASKS_DIR/dossiers/proj--child-lay/brief.md"
if [ -f "$BR" ]; then echo "ok   - new --planned (parent): brief.md written"; else echo "FAIL - brief.md missing"; fail=1; fi
assert "brief.md: type task" '^type: task$' "$(cat "$BR" 2>/dev/null)"
assert "brief.md: why filled from the seed's first paragraph" '^\*\*Why:\*\* Because the board lies\.$' "$(cat "$BR" 2>/dev/null)"
assert_not "brief.md: only the first paragraph" 'Second paragraph' "$(cat "$BR" 2>/dev/null)"
assert "brief.md: done when / not doing / claims fields" 'Done when:.*Not doing:.*Claims' "$(tr '\n' ' ' < "$BR" 2>/dev/null)"
assert "brief.md: claims line names checked/assumed + today's date" "checked\* or \*assumed\*.*assumed $(date +%F)" "$(cat "$BR" 2>/dev/null)"
assert_not "brief.md: no bug fields on a plain task" 'Repro' "$(cat "$BR" 2>/dev/null)"

# bug signal: a fix/ branch
cmd_new --planned --parent proj--par-lay proj fix/stuck-tab >/dev/null 2>&1
BB="$TASKS_DIR/dossiers/proj--fix-stuck-tab/brief.md"
assert "brief.md (fix/ branch): type bug" '^type: bug$' "$(cat "$BB" 2>/dev/null)"
assert "brief.md (fix/ branch): seen/expected/repro fields" 'Seen:.*Expected:.*Repro:' "$(tr '\n' ' ' < "$BB" 2>/dev/null)"

# re-running over the existing child never rewrites brief.md / the file
echo "hand edit" >> "$BR"
cmd_new --planned --parent proj--par-lay proj child-lay >/dev/null 2>&1
assert "re-run keeps a hand-edited brief.md" 'hand edit' "$(cat "$BR")"

# no parent at all: seeded the same way
cmd_new --planned proj orphan-new >/dev/null 2>&1
assert_eq "new --planned (no parent): brief.md drafted" "yes" "$([ -e "$TASKS_DIR/dossiers/proj--orphan-new/brief.md" ] && echo yes || echo no)"
assert_eq "new --planned (no parent): layout: dossier" "dossier" "$(wb_get_frontmatter "$TASKS_DIR/proj--orphan-new.md" layout)"
assert_not "new --planned (no parent): no ## Decisions skeleton" '^## (Decisions|Done|Follow-ups)' "$(cat "$TASKS_DIR/proj--orphan-new.md")"
assert "new --planned (no parent): ## Now placeholder" '^## Now$' "$(cat "$TASKS_DIR/proj--orphan-new.md")"

# --- wb notes --------------------------------------------------------------------
assert_eq "notes <task>: prints the dossier notes.md path (file absent)" "$TASKS_DIR/dossiers/proj--par-lay/notes.md" "$(cmd_notes proj--par-lay 2>&1)"
assert_eq "notes <task>: does not create the file" "no" "$([ -e "$TASKS_DIR/dossiers/proj--par-lay/notes.md" ] && echo yes || echo no)"
out="$(unset TMUX; cmd_notes 2>&1)"; rc=$?
assert_eq "notes (no arg, outside tmux): exit 1" 1 "$rc"
assert "notes (no arg, outside tmux): names tmux" 'not inside tmux' "$out"
out="$(cmd_notes a b 2>&1)"; rc=$?
assert_eq "notes: two args is a usage error" 1 "$rc"
assert "wb help lists wb notes" 'wb notes \[<task>\]' "$(cmd_help 2>&1)"

# --- prefix+T binding ---------------------------------------------------------------
CONF="$REPO_ROOT/tmux/.config/tmux/tmux.conf"
assert "tmux.conf: prefix+T opens notes via wb notes in a popup" '^bind T display-popup .*wb\.sh notes' "$(cat "$CONF")"
assert "tmux.conf: the popup edits notes.md" 'EDITOR:-nvim' "$(grep '^bind T ' "$CONF")"
assert_eq "tmux.conf: T bound exactly once" 1 "$(grep -c '^bind T \|^bind-key T ' "$CONF")"

# --- wb_followup_count ----------------------------------------------------------------
# (fresh store so the count is deterministic)
CNT_TASKS="$FIXTURE/tasks-count"; mkdir -p "$CNT_TASKS"
(
  export TASKS_DIR="$CNT_TASKS"
  mk_task proj--fc-lay
  mk_item proj--fc-lay 2026-07-01-a open "one open"
  mk_item proj--fc-lay 2026-07-01-b closed "done already"
  mk_item proj--fc-lay 2026-07-02-c open "two open"
  wb_followup_count > "$FIXTURE/count.out"
)
assert_eq "followup count: open items, closed items skipped" 2 "$(cat "$FIXTURE/count.out")"

# an empty open-items/ must not crash under mawk
CNT2_TASKS="$FIXTURE/tasks-count2"; mkdir -p "$CNT2_TASKS"
MAWKDIR="$FIXTURE/awkshim-mawk"; mkdir -p "$MAWKDIR"; ln -sf "$(command -v mawk)" "$MAWKDIR/awk"
(
  export TASKS_DIR="$CNT2_TASKS"
  mk_task proj--fc-empty
  mkdir -p "$CNT2_TASKS/dossiers/proj--fc-empty/open-items"
  PATH="$MAWKDIR:$PATH"; hash -r
  wb_followup_count > "$FIXTURE/count2.out" 2>"$FIXTURE/count2.err"; echo $? > "$FIXTURE/count2.rc"
)
assert_eq "followup count (mawk): empty open-items/ does not crash, exit 0" 0 "$(cat "$FIXTURE/count2.rc")"
assert_eq "followup count (mawk): nothing open" 0 "$(cat "$FIXTURE/count2.out")"

# --- picker preview ------------------------------------------------------------------------
mk_task proj--pv-lay
sed -i 's/^## Handoffs$/## Handoffs\n\n### 2026-07-05 10:00 — wb pause (auto)\n\nPaused./' "$TASKS_DIR/proj--pv-lay.md"
mkdir -p "$TASKS_DIR/dossiers/proj--pv-lay/handoffs"
printf -- '---\nsource: wb-save\nauto: false\n---\n### 2026-07-04 09:00 — wb-save\n\n**Done:** the rich thing\n**Next:** do the next thing\n' > "$TASKS_DIR/dossiers/proj--pv-lay/handoffs/2026-07-04-0900.md"
printf -- '---\nsource: wb pause\nauto: true\n---\n### 2026-07-03 09:00 — wb pause (auto)\n\nOld stamp.\n' > "$TASKS_DIR/dossiers/proj--pv-lay/handoffs/2026-07-03-0900.md"
out="$(_preview "" "$TASKS_DIR/proj--pv-lay.md" task 2>&1 | sed 's/\x1b\[[0-9;]*m//g')"
assert "preview shows ## Now" 'now text for proj--pv-lay' "$out"
assert "preview falls back to the newest auto:false handoff" 'do the next thing' "$out"
assert_not "preview the (auto) stamp is not the shown entry" 'Old stamp' "$out"
# a rich entry in the task file wins over handoffs/
mk_task proj--pv-lay2
sed -i 's/^## Handoffs$/## Handoffs\n\n### 2026-07-06 10:00 — wb-save\n\n**Next:** the current entry/' "$TASKS_DIR/proj--pv-lay2.md"
mkdir -p "$TASKS_DIR/dossiers/proj--pv-lay2/handoffs"
printf -- '---\nsource: wb-save\nauto: false\n---\n### 2026-07-04 09:00 — wb-save\n\n**Next:** an older entry\n' > "$TASKS_DIR/dossiers/proj--pv-lay2/handoffs/2026-07-04-0900.md"
out="$(_preview "" "$TASKS_DIR/proj--pv-lay2.md" task 2>&1 | sed 's/\x1b\[[0-9;]*m//g')"
assert "preview task-file rich entry shown" 'the current entry' "$out"
assert_not "preview handoffs/ not consulted when the file has a rich one" 'an older entry' "$out"
# --- wb breakdown --apply: an open item moves -------------------------------------------------
BD_BUF="$FIXTURE/bd"; mkdir -p "$BD_BUF"
mk_task proj--bd-par
mk_item proj--bd-par 2026-07-01-index open "explore artifact indexing"
printf '\nAPI design needed first.\n' >> "$TASKS_DIR/dossiers/proj--bd-par/open-items/2026-07-01-index.md"
mk_item proj--bd-par 2026-07-01-stay open "stays on the parent"
cat > "$BD_BUF/buf.md" <<'EOF'
# wb breakdown — proj--bd-par

<!-- wb-breakdown: block=approve parent=proj--bd-par -->
- [x] Approve — apply everything ticked below

## child 1 — new slice
<!-- wb-breakdown: block=child n=1 parent=proj--bd-par repo=proj -->
- [x] create child: `bd-new`
- goal: new slice
<!-- wb-breakdown: begin-plan n=1 -->
new child plan
<!-- wb-breakdown: end-plan -->

## parent edits
<!-- wb-breakdown: block=parent parent=proj--bd-par -->
- [ ] rewrite parent ## Plan as below
<!-- wb-breakdown: begin-plan parent -->
unused
<!-- wb-breakdown: end-plan -->
- [x] move follow-up: "explore artifact indexing" → child: `bd-new`
EOF
out="$(cmd_breakdown --apply "$BD_BUF/buf.md" 2>&1)"; rc=$?
assert_eq "breakdown (parent): apply exits 0" 0 "$rc"
NK="$TASKS_DIR/proj--bd-new.md"
assert_eq "breakdown: new child has the layout" "dossier" "$(wb_get_frontmatter "$NK" layout)"
MOVED="$TASKS_DIR/dossiers/proj--bd-new/open-items/2026-07-01-index.md"
if [ -f "$MOVED" ]; then echo "ok   - breakdown: open item file moved into the child's dossier"; else echo "FAIL - breakdown: item not in child dossier ($out)"; fail=1; fi
assert "breakdown: moved item kept its body" 'API design needed first' "$(cat "$MOVED" 2>/dev/null)"
assert_eq "breakdown: item gone from the parent (a move, not a copy)" "no" "$([ -e "$TASKS_DIR/dossiers/proj--bd-par/open-items/2026-07-01-index.md" ] && echo yes || echo no)"
assert_eq "breakdown: unmoved item stays on the parent" "yes" "$([ -e "$TASKS_DIR/dossiers/proj--bd-par/open-items/2026-07-01-stay.md" ] && echo yes || echo no)"
assert "breakdown: child's views rebuilt (index.md written)" '^<!-- generated by wb' "$(head -1 "$TASKS_DIR/dossiers/proj--bd-new/index.md" 2>/dev/null)"
# an unknown title is skipped with the usual message
sed -i 's/"explore artifact indexing"/"no such open item"/; s/^- \[x\] create child.*/- [ ] create child: `bd-new`/' "$BD_BUF/buf.md"
out="$(cmd_breakdown --apply "$BD_BUF/buf.md" 2>&1)"
assert "breakdown (parent): unmatched title skipped" 'matched 0 of .* open follow-ups' "$out"

# --- reconcile merge: refused, each task's records live in its own dossier ----
mk_task proj--rc-a
mk_task proj--rc-b
RC_BLOCK=$'<!-- wb-reconcile: kind=missing -->\n- [x] survivor: this finding\n'
before_a="$(cat "$TASKS_DIR/proj--rc-a.md")"; before_b="$(cat "$TASKS_DIR/proj--rc-b.md")"
out="$(wb_reconcile_action_merge missing proj b w "$TASKS_DIR/proj--rc-a.md" proj--rc-b.md "$RC_BLOCK" 2>&1)"; rc=$?
assert_eq "reconcile merge: returns 0 (skipped)" 0 "$rc"
assert "reconcile merge: says to merge by hand" 'merge them by hand' "$out"
assert_eq "reconcile merge: first file untouched" "$before_a" "$(cat "$TASKS_DIR/proj--rc-a.md")"
assert_eq "reconcile merge: second file untouched (not deleted)" "$before_b" "$(cat "$TASKS_DIR/proj--rc-b.md" 2>/dev/null)"

# --- handoff.sh: follow-up writer -----------------------------------------------------------
mk_task proj--ho-lay
wb_task_lock_acquire_guarded "$TASKS_DIR/proj--ho-lay.md"
handoff_append_followup "$TASKS_DIR/proj--ho-lay.md" "repo has no bootstrap manifest — worktree likely incomplete"; rc=$?
wb_task_lock_release "$TASKS_DIR/proj--ho-lay.md"
assert_eq "handoff follow-up exit 0" 0 "$rc"
HI="$(ls "$TASKS_DIR/dossiers/proj--ho-lay/open-items/" 2>/dev/null)"
assert "handoff follow-up wrote an open-items/ record" 'repo-has-no-bootstrap' "$HI"
assert "handoff follow-up record is status: open" '^status: open$' "$(cat "$TASKS_DIR/dossiers/proj--ho-lay/open-items/"*.md 2>/dev/null)"
assert_not "handoff follow-up no ## Follow-ups heading added to the task file" '^## Follow-ups' "$(cat "$TASKS_DIR/proj--ho-lay.md")"
assert "handoff follow-up views rebuilt (index.md written)" '^<!-- generated by wb' "$(head -1 "$TASKS_DIR/dossiers/proj--ho-lay/index.md" 2>/dev/null)"
echo
if [ "$fail" -eq 0 ]; then echo "ALL PASS"; else echo "SOME FAILED"; exit 1; fi
