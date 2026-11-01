#!/usr/bin/env bash
# Tests for U12 (script half, part A): wb.sh / handoff.sh readers that learn
# the dossier layout (`layout: dossier`) — _wb_concepts_paths, `wb new`'s
# layout seed (+ brief.md), `wb notes`, the follow-up count, the picker
# preview, `wb breakdown --apply`'s follow-up moves, the reconcile merge
# refusal and handoff.sh's follow-up writer — plus the invariant that a task
# WITHOUT `layout:` takes exactly the old path, and the prefix+T notes key.
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

mk_task() { # <stem> <layout|old> [extra frontmatter lines...]
  local stem="$1" kind="$2"; shift 2
  { printf -- '---\nstatus: doing\nrepo: proj\nbranch: b\n'
    [ "$kind" = layout ] && printf 'layout: dossier\n'
    printf 'tags: []\ncreated: 2026-07-01\nclosed:\n'
    for l in "$@"; do printf '%s\n' "$l"; done
    printf -- '---\n# Title %s\n\n' "$stem"
    [ "$kind" = layout ] && printf '## Now\n\nnow text for %s\n\n' "$stem"
    printf '## Plan\n\nplan text\n\n## Handoffs\n\n'
    [ "$kind" = layout ] || printf '## Decisions\n\n## Done\n\n## Follow-ups\n\n'
  } > "$TASKS_DIR/$stem.md"
}
mk_item() { # <stem> <name> <status> <text>
  mkdir -p "$TASKS_DIR/dossiers/$1/open-items"
  printf -- '---\nwho:\nsince: 2026-07-01\nkind:\nstatus: %s\n---\n%s\n' "$3" "$4" > "$TASKS_DIR/dossiers/$1/open-items/$2.md"
}

# --- _wb_concepts_paths: concepts.md for a layout task, CONCEPTS.md otherwise
mk_task proj--cp-new layout
mk_task proj--cp-old old
mkdir -p "$TASKS_DIR/dossiers/proj--cp-new" "$TASKS_DIR/dossiers/proj--cp-old"
: > "$TASKS_DIR/dossiers/proj--cp-new/concepts.md"
: > "$TASKS_DIR/dossiers/proj--cp-new/CONCEPTS.md"
: > "$TASKS_DIR/dossiers/proj--cp-old/CONCEPTS.md"
: > "$TASKS_DIR/dossiers/proj--cp-old/concepts.md"
assert_eq "concepts: layout task resolves concepts.md only" "$TASKS_DIR/dossiers/proj--cp-new/concepts.md" "$(_wb_concepts_paths "$TASKS_DIR/proj--cp-new.md")"
assert_eq "concepts: old task still resolves CONCEPTS.md only" "$TASKS_DIR/dossiers/proj--cp-old/CONCEPTS.md" "$(_wb_concepts_paths "$TASKS_DIR/proj--cp-old.md")"
# mixed chain: a layout child under an old parent takes each link's own name
mk_task proj--cp-kid layout "parent: proj--cp-old"
mkdir -p "$TASKS_DIR/dossiers/proj--cp-kid"; : > "$TASKS_DIR/dossiers/proj--cp-kid/concepts.md"
assert_eq "concepts: mixed chain, nearest first, per-link name" \
  "$TASKS_DIR/dossiers/proj--cp-kid/concepts.md"$'\n'"$TASKS_DIR/dossiers/proj--cp-old/CONCEPTS.md" \
  "$(_wb_concepts_paths "$TASKS_DIR/proj--cp-kid.md")"
assert_eq "wb family --concepts follows the layout name" "$TASKS_DIR/dossiers/proj--cp-new/concepts.md" "$(cmd_family proj--cp-new --concepts 2>&1)"

# --- wb new --planned under a layout parent -----------------------------------
mk_task proj--par-lay layout
out="$(printf 'Because the board lies.\n\nSecond paragraph stays out.\n' | cmd_new --planned --parent proj--par-lay --body - proj child-lay 2>&1)"; rc=$?
CL="$TASKS_DIR/proj--child-lay.md"
assert_eq "new --planned (layout parent): exit 0" 0 "$rc"
assert_eq "new --planned (layout parent): layout: dossier" "dossier" "$(wb_get_frontmatter "$CL" layout)"
assert "new --planned (layout parent): ## Now placeholder" '^## Now$' "$(cat "$CL")"
assert_not "new --planned (layout parent): no First-action line" 'First action' "$(cat "$CL")"
assert_not "new --planned (layout parent): no ## Decisions" '^## Decisions' "$(cat "$CL")"
assert_not "new --planned (layout parent): no ## Follow-ups" '^## Follow-ups' "$(cat "$CL")"
assert_not "new --planned (layout parent): no ## Done" '^## Done' "$(cat "$CL")"
assert "new --planned (layout parent): ## Plan kept with the body" 'Because the board lies' "$(cat "$CL")"
assert "new --planned (layout parent): ## Handoffs kept" '^## Handoffs$' "$(cat "$CL")"
assert_eq "new --planned (layout parent): sections in order" "Now Plan Handoffs" "$(grep '^## ' "$CL" | sed 's/^## //' | tr '\n' ' ' | sed 's/ $//')"
BR="$TASKS_DIR/dossiers/proj--child-lay/brief.md"
if [ -f "$BR" ]; then echo "ok   - new --planned (layout parent): brief.md written"; else echo "FAIL - brief.md missing"; fail=1; fi
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

# a normal parent: byte-for-byte the old shape, no layout, no brief
mk_task proj--par-old old
cmd_new --planned --parent proj--par-old proj child-old >/dev/null 2>&1
CO="$TASKS_DIR/proj--child-old.md"
assert_eq "new --planned (old parent): no layout key value" "" "$(wb_get_frontmatter "$CO" layout)"
assert "new --planned (old parent): template sections intact" '^## Decisions$' "$(cat "$CO")"
assert "new --planned (old parent): ## Follow-ups intact" '^## Follow-ups$' "$(cat "$CO")"
assert_not "new --planned (old parent): no ## Now" '^## Now$' "$(cat "$CO")"
assert_eq "new --planned (old parent): no brief.md" "no" "$([ -e "$TASKS_DIR/dossiers/proj--child-old/brief.md" ] && echo yes || echo no)"
# no parent at all: same
cmd_new --planned proj orphan-new >/dev/null 2>&1
assert_eq "new --planned (no parent): no brief.md" "no" "$([ -e "$TASKS_DIR/dossiers/proj--orphan-new/brief.md" ] && echo yes || echo no)"
assert_eq "new --planned (no parent): no layout key value" "" "$(wb_get_frontmatter "$TASKS_DIR/proj--orphan-new.md" layout)"

# --- wb notes --------------------------------------------------------------------
assert_eq "notes <task>: prints the dossier notes.md path (file absent)" "$TASKS_DIR/dossiers/proj--par-lay/notes.md" "$(cmd_notes proj--par-lay 2>&1)"
assert_eq "notes <task>: does not create the file" "no" "$([ -e "$TASKS_DIR/dossiers/proj--par-lay/notes.md" ] && echo yes || echo no)"
assert_eq "notes <task>: also works on a task with no layout" "$TASKS_DIR/dossiers/proj--par-old/notes.md" "$(cmd_notes proj--par-old 2>&1)"
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
  mk_task proj--fc-lay layout
  mk_item proj--fc-lay 2026-07-01-a open "one open"
  mk_item proj--fc-lay 2026-07-01-b closed "done already"
  mk_item proj--fc-lay 2026-07-02-c open "two open"
  mk_task proj--fc-old old
  printf -- '- an old bullet\n' >> "$CNT_TASKS/proj--fc-old.md"
  wb_followup_count > "$FIXTURE/count.out"
)
assert_eq "followup count: open items + old bullets, closed items skipped" 3 "$(cat "$FIXTURE/count.out")"

# --- picker preview ------------------------------------------------------------------------
mk_task proj--pv-lay layout
sed -i 's/^## Handoffs$/## Handoffs\n\n### 2026-07-05 10:00 — wb pause (auto)\n\nPaused./' "$TASKS_DIR/proj--pv-lay.md"
mkdir -p "$TASKS_DIR/dossiers/proj--pv-lay/handoffs"
printf -- '---\nsource: wb-save\nauto: false\n---\n### 2026-07-04 09:00 — wb-save\n\n**Done:** the rich thing\n**Next:** do the next thing\n' > "$TASKS_DIR/dossiers/proj--pv-lay/handoffs/2026-07-04-0900.md"
printf -- '---\nsource: wb pause\nauto: true\n---\n### 2026-07-03 09:00 — wb pause (auto)\n\nOld stamp.\n' > "$TASKS_DIR/dossiers/proj--pv-lay/handoffs/2026-07-03-0900.md"
out="$(_preview "" "$TASKS_DIR/proj--pv-lay.md" task 2>&1 | sed 's/\x1b\[[0-9;]*m//g')"
assert "preview (layout): shows ## Now" 'now text for proj--pv-lay' "$out"
assert "preview (layout): falls back to the newest auto:false handoff" 'do the next thing' "$out"
assert_not "preview (layout): the (auto) stamp is not the shown entry" 'Old stamp' "$out"
# a rich entry in the task file wins over handoffs/
mk_task proj--pv-lay2 layout
sed -i 's/^## Handoffs$/## Handoffs\n\n### 2026-07-06 10:00 — wb-save\n\n**Next:** the current entry/' "$TASKS_DIR/proj--pv-lay2.md"
mkdir -p "$TASKS_DIR/dossiers/proj--pv-lay2/handoffs"
printf -- '---\nsource: wb-save\nauto: false\n---\n### 2026-07-04 09:00 — wb-save\n\n**Next:** an older entry\n' > "$TASKS_DIR/dossiers/proj--pv-lay2/handoffs/2026-07-04-0900.md"
out="$(_preview "" "$TASKS_DIR/proj--pv-lay2.md" task 2>&1 | sed 's/\x1b\[[0-9;]*m//g')"
assert "preview (layout): task-file rich entry shown" 'the current entry' "$out"
assert_not "preview (layout): handoffs/ not consulted when the file has a rich one" 'an older entry' "$out"
# an old task: no Now block, same as before
mk_task proj--pv-old old
sed -i 's/^## Handoffs$/## Handoffs\n\n### 2026-07-06 10:00 — wb-save\n\n**Next:** old shape/' "$TASKS_DIR/proj--pv-old.md"
out="$(_preview "" "$TASKS_DIR/proj--pv-old.md" task 2>&1 | sed 's/\x1b\[[0-9;]*m//g')"
assert "preview (old task): handoff shown" 'old shape' "$out"
assert_not "preview (old task): no Now block" '^Now$' "$out"

# --- wb breakdown --apply: an open item moves -------------------------------------------------
BD_BUF="$FIXTURE/bd"; mkdir -p "$BD_BUF"
mk_task proj--bd-par layout
mk_item proj--bd-par 2026-07-01-index open "explore artifact indexing"
printf '\nAPI design needed first.\n' >> "$TASKS_DIR/dossiers/proj--bd-par/open-items/2026-07-01-index.md"
mk_item proj--bd-par 2026-07-01-stay open "stays on the parent"
mk_item proj--bd-par 2026-07-01-old open "goes to the older child"
mk_task proj--bd-oldkid old "parent: proj--bd-par"
wb_set_frontmatter "$TASKS_DIR/proj--bd-oldkid.md" branch bd-oldkid
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
- [x] move follow-up: "goes to the older child" → child: `bd-oldkid`
EOF
out="$(cmd_breakdown --apply "$BD_BUF/buf.md" 2>&1)"; rc=$?
assert_eq "breakdown (layout parent): apply exits 0" 0 "$rc"
NK="$TASKS_DIR/proj--bd-new.md"
assert_eq "breakdown: new child under a layout parent has the layout" "dossier" "$(wb_get_frontmatter "$NK" layout)"
MOVED="$TASKS_DIR/dossiers/proj--bd-new/open-items/2026-07-01-index.md"
if [ -f "$MOVED" ]; then echo "ok   - breakdown: open item file moved into the layout child's dossier"; else echo "FAIL - breakdown: item not in child dossier ($out)"; fail=1; fi
assert "breakdown: moved item kept its body" 'API design needed first' "$(cat "$MOVED" 2>/dev/null)"
assert_eq "breakdown: item gone from the parent (a move, not a copy)" "no" "$([ -e "$TASKS_DIR/dossiers/proj--bd-par/open-items/2026-07-01-index.md" ] && echo yes || echo no)"
assert_eq "breakdown: unmoved item stays on the parent" "yes" "$([ -e "$TASKS_DIR/dossiers/proj--bd-par/open-items/2026-07-01-stay.md" ] && echo yes || echo no)"
assert "breakdown: child's views rebuilt (index.md written)" '^<!-- generated by wb' "$(head -1 "$TASKS_DIR/dossiers/proj--bd-new/index.md" 2>/dev/null)"
assert_eq "breakdown: old child gets a ## Follow-ups bullet" "yes" "$(grep -qx -- '- goes to the older child' "$TASKS_DIR/proj--bd-oldkid.md" && echo yes || echo no)"
assert_eq "breakdown: that item left the parent's open-items/" "no" "$([ -e "$TASKS_DIR/dossiers/proj--bd-par/open-items/2026-07-01-old.md" ] && echo yes || echo no)"
# an unknown title is skipped with the usual message
sed -i 's/"explore artifact indexing"/"no such open item"/; s/^- \[x\] create child.*/- [ ] create child: `bd-new`/' "$BD_BUF/buf.md"
out="$(cmd_breakdown --apply "$BD_BUF/buf.md" 2>&1)"
assert "breakdown (layout parent): unmatched title skipped" 'matched 0 bullet' "$out"

# --- reconcile merge refuses when a side is a layout task ---------------------------------------
mk_task proj--rc-lay layout
mk_task proj--rc-old old
RC_BLOCK=$'<!-- wb-reconcile: kind=missing -->\n- [x] survivor: this finding\n'
before_l="$(cat "$TASKS_DIR/proj--rc-lay.md")"; before_o="$(cat "$TASKS_DIR/proj--rc-old.md")"
out="$(wb_reconcile_action_merge missing proj b w "$TASKS_DIR/proj--rc-lay.md" proj--rc-old.md "$RC_BLOCK" 2>&1)"; rc=$?
assert_eq "reconcile merge (layout+old): returns 0 (skipped)" 0 "$rc"
assert "reconcile merge: names wb migrate and the old side" 'wb migrate proj--rc-old' "$out"
assert_eq "reconcile merge: layout file untouched" "$before_l" "$(cat "$TASKS_DIR/proj--rc-lay.md")"
assert_eq "reconcile merge: old file untouched (not deleted)" "$before_o" "$(cat "$TASKS_DIR/proj--rc-old.md" 2>/dev/null)"
mk_task proj--rc-lay2 layout
out="$(wb_reconcile_action_merge missing proj b w "$TASKS_DIR/proj--rc-lay.md" proj--rc-lay2.md "$RC_BLOCK" 2>&1)"
assert "reconcile merge (both layout): refused, no dossier merge" 'no dossier merge exists' "$out"
# old+old still merges
mk_task proj--rc-old2 old
printf -- '- carried bullet\n' >> "$TASKS_DIR/proj--rc-old2.md"
out="$(wb_reconcile_action_merge missing proj b w "$TASKS_DIR/proj--rc-old.md" proj--rc-old2.md "$RC_BLOCK" 2>&1)"
assert "reconcile merge (old+old): still merges" 'merged ' "$out"

# --- handoff.sh: follow-up on a layout task -----------------------------------------------------------
mk_task proj--ho-lay layout
mk_task proj--ho-old old
wb_task_lock_acquire_guarded "$TASKS_DIR/proj--ho-lay.md"
handoff_append_followup "$TASKS_DIR/proj--ho-lay.md" "repo has no bootstrap manifest — worktree likely incomplete"; rc=$?
wb_task_lock_release "$TASKS_DIR/proj--ho-lay.md"
assert_eq "handoff follow-up (layout): exit 0" 0 "$rc"
HI="$(ls "$TASKS_DIR/dossiers/proj--ho-lay/open-items/" 2>/dev/null)"
assert "handoff follow-up (layout): wrote an open-items/ record" 'repo-has-no-bootstrap' "$HI"
assert "handoff follow-up (layout): record is status: open" '^status: open$' "$(cat "$TASKS_DIR/dossiers/proj--ho-lay/open-items/"*.md 2>/dev/null)"
assert_not "handoff follow-up (layout): no ## Follow-ups heading added to the task file" '^## Follow-ups' "$(cat "$TASKS_DIR/proj--ho-lay.md")"
assert "handoff follow-up (layout): views rebuilt (index.md written)" '^<!-- generated by wb' "$(head -1 "$TASKS_DIR/dossiers/proj--ho-lay/index.md" 2>/dev/null)"
wb_task_lock_acquire_guarded "$TASKS_DIR/proj--ho-old.md"
handoff_append_followup "$TASKS_DIR/proj--ho-old.md" "old-shape note"
wb_task_lock_release "$TASKS_DIR/proj--ho-old.md"
assert "handoff follow-up (old): bullet under ## Follow-ups as before" '^- old-shape note$' "$(cat "$TASKS_DIR/proj--ho-old.md")"
assert_eq "handoff follow-up (old): no dossier written" "no" "$([ -d "$TASKS_DIR/dossiers/proj--ho-old" ] && echo yes || echo no)"

echo
if [ "$fail" -eq 0 ]; then echo "ALL PASS"; else echo "SOME FAILED"; exit 1; fi
