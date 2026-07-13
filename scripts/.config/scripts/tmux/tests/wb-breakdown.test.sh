#!/usr/bin/env bash
# Tests for `/wb-breakdown` + `wb breakdown --apply` (docs/plans/
# 2026-07-12-001-feat-wb-breakdown-skill-plan.md). Sections are added unit
# by unit; this header + the seed section below are U1's.
#
# Run: bash scripts/.config/scripts/tmux/tests/wb-breakdown.test.sh
set -uo pipefail

WB="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/wb.sh"
FIXTURE_CODE="$(mktemp -d -t wb-breakdown-code.XXXXXX)"
FIXTURE_TASKS="$(mktemp -d -t wb-breakdown-tasks.XXXXXX)"
trap 'rm -rf "$FIXTURE_CODE" "$FIXTURE_TASKS"' EXIT

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

printf -- '---\nstatus: planned\npath:\nrepo:\nbranch:\nworktree:\nparent:\ndepends_on:\ntags: []\ncreated:\nclosed:\nreviewed:\n---\n# Title\n\n## Plan\n\n\n\n## Handoffs\n\n\n\n## Decisions\n\n\n\n## Done\n\n\n\n## Follow-ups\n' \
  > "$FIXTURE_TASKS/TEMPLATE.md"

# real (throwaway) git repo under the fixture CODE_DIR, matching cmd_new's
# own $CODE_DIR/$repo/.git check for the --jira/ticket-parent path below.
mkdir -p "$FIXTURE_CODE/proj"
git init -q "$FIXTURE_CODE/proj"
git -C "$FIXTURE_CODE/proj" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init

export CODE_DIR="$FIXTURE_CODE"
export TASKS_DIR="$FIXTURE_TASKS"

# shellcheck disable=SC1090
source "$WB"
set +e   # wb.sh sets -e; this test intentionally captures non-zero exits

# =============================================================================
# U1 — wb_seed_planned_child / --jira ticket-parent extension
# =============================================================================

# --- happy path: every field round-trips, worktree stays blank --------------
out="$(printf 'absorb: board-embed bullets\nmore plan content\n' \
  | wb_seed_planned_child proj feat-hub-v0-board-embed dotfiles--feat-hub-v0 2>&1)"
child_file="$TASKS_DIR/proj--feat-hub-v0-board-embed.md"
assert_eq "seed: prints the resolved file path" "$child_file" "$out"
assert_eq "seed: file was created" "$child_file" "$([ -f "$child_file" ] && echo "$child_file")"
assert_eq "seed: status: planned" "planned" "$(wb_get_frontmatter "$child_file" status)"
assert_eq "seed: worktree: stays blank" "" "$(wb_get_frontmatter "$child_file" worktree)"
assert_eq "seed: branch: is the raw slug" "feat-hub-v0-board-embed" "$(wb_get_frontmatter "$child_file" branch)"
assert_eq "seed: repo: set" "proj" "$(wb_get_frontmatter "$child_file" repo)"
assert_eq "seed: parent: set" "dotfiles--feat-hub-v0" "$(wb_get_frontmatter "$child_file" parent)"
assert "seed: title falls back to slug-derived form when omitted" "^feat hub v0 board embed$" "$(wb_task_title "$child_file")"
assert "seed: plan body lands under ## Plan" "absorb: board-embed bullets" "$(cat "$child_file")"

# --- explicit title (the buffer's own "goal:" line, per U3's "frontmatter +
# goal title") overrides the slug-derived fallback -----------------------
out_goal="$(printf 'goal-driven plan body\n' \
  | wb_seed_planned_child proj feat-hub-v0-artifact-index dotfiles--feat-hub-v0 'one-line goal for the artifact index' 2>&1)"
child_goal="$TASKS_DIR/proj--feat-hub-v0-artifact-index.md"
assert_eq "seed: explicit title overrides slug-derived form" "one-line goal for the artifact index" "$(wb_task_title "$child_goal")"

# --- existing file: refuse, file untouched -----------------------------------
before="$(cat "$child_file")"
err="$(printf 'ignored\n' | wb_seed_planned_child proj feat-hub-v0-board-embed dotfiles--feat-hub-v0 2>&1 1>/dev/null)"
rc=$?
assert_eq "seed: existing file returns 1" 1 "$rc"
assert "seed: existing-file error names the stem" "proj--feat-hub-v0-board-embed" "$err"
assert_eq "seed: existing file left byte-identical" "$before" "$(cat "$child_file")"

# --- backslash-bearing body round-trips byte-identical -----------------------
backslash_body='```
a regex: \K\[foo\]
a path: C:\Users\jet\.claude
tabs:\there
```'
out2="$(printf '%s\n' "$backslash_body" \
  | wb_seed_planned_child proj feat-hub-v0-backslash dotfiles--feat-hub-v0 2>&1)"
child2="$TASKS_DIR/proj--feat-hub-v0-backslash.md"
plan_section="$(awk '/^## Plan/{f=1;next} /^## Handoffs/{f=0} f' "$child2" | sed '/^$/d')"
expected_section="$(printf '%s\n' "$backslash_body" | sed '/^$/d')"
assert_eq "seed: backslash body round-trips byte-identical" "$expected_section" "$plan_section"

# --- AE2 (half): a planned child (blank worktree:) is invisible to reconcile -
recon_out="$(wb_reconcile_collect 2>/dev/null)"
if printf '%s' "$recon_out" | grep -qE '^missing\s+proj\s'; then
  echo "FAIL - seed: planned child with blank worktree: should not be flagged by wb_reconcile_collect"
  fail=1
else
  echo "ok   - seed: planned child with blank worktree: produces zero reconcile findings"
fi

# --- ticket-parent path: `wb new --planned --jira <url>` --------------------
jira_body='ticket description line 1
ticket description line 2 with a \K escape'
out3="$(printf '%s\n' "$jira_body" \
  | cmd_new --planned --jira 'https://sportable.atlassian.net/browse/SFB-1234' proj feat-ticket-parent 2>&1)"
ticket_file="$TASKS_DIR/proj--feat-ticket-parent.md"
assert_eq "ticket-parent: prints the resolved file path" "$ticket_file" "$out3"
assert_eq "ticket-parent: jira: stores the full URL" "https://sportable.atlassian.net/browse/SFB-1234" "$(wb_get_frontmatter "$ticket_file" jira)"
assert_eq "ticket-parent: status: planned" "planned" "$(wb_get_frontmatter "$ticket_file" status)"
assert_eq "ticket-parent: worktree: stays blank" "" "$(wb_get_frontmatter "$ticket_file" worktree)"
assert "ticket-parent: stdin plan body lands under ## Plan" "ticket description line 1" "$(cat "$ticket_file")"
assert "ticket-parent: body byte-identical incl. backslash sequence" 'ticket description line 2 with a \\K escape' "$(cat "$ticket_file")"

# --- --jira without --planned is a clean usage error -------------------------
err2="$(cmd_new --jira 'https://x/y' proj feat-bad 2>&1 1>/dev/null)"
rc2=$?
assert_eq "--jira without --planned: exit 1" 1 "$rc2"
assert "--jira without --planned: clear error" 'only valid together with --planned' "$err2"
assert_eq "--jira without --planned: no file created" "" "$([ -f "$TASKS_DIR/proj--feat-bad.md" ] && echo exists)"

# --- existing paths unchanged: wb_seed_task still flips planned->doing ------
wb_seed_task proj feat-regression '.worktrees/feat-regression' >/dev/null
assert_eq "regression: wb_seed_task still stamps status: doing" "doing" "$(wb_get_frontmatter "$TASKS_DIR/proj--feat-regression.md" status)"
assert_eq "regression: wb_seed_task still stamps worktree:" ".worktrees/feat-regression" "$(wb_get_frontmatter "$TASKS_DIR/proj--feat-regression.md" worktree)"

# =============================================================================
# U2 — wb breakdown --apply: buffer parse + validate (no writes yet)
# =============================================================================

BUF_DIR="$(mktemp -d -t wb-breakdown-buf.XXXXXX)"

mk_parent() { # <stem> <branch> <worktree>
  local f="$TASKS_DIR/$1.md"
  {
    printf -- '---\nstatus: doing\nrepo: proj\nbranch: %s\nworktree: %s\nparent:\ncreated: 2026-07-01\n---\n' "$2" "$3"
    printf '# Big Task\n\n## Plan\n\nsome big plan\n\n## Follow-ups\n\n- explore wb breakdown verb further\n'
  } > "$f"
}
mk_parent proj--feat-big feat-big .worktrees/feat-big
printf -- '---\nstatus: planned\nrepo: proj\nbranch: feat-big-existing\nworktree:\nparent:\ncreated: 2026-07-01\n---\n# Existing\n' \
  > "$TASKS_DIR/proj--feat-big-existing.md"

base_buffer() {
  cat <<'EOF'
# wb breakdown — proj--feat-big

## child 1 — first slice
<!-- wb-breakdown: block=child n=1 parent=proj--feat-big repo=proj -->
- [x] create child: `feat-big-one`
- goal: first slice of the big task
<!-- wb-breakdown: begin-plan n=1 -->
plan body for child one
<!-- wb-breakdown: end-plan -->

## child 2 — second slice
<!-- wb-breakdown: block=child n=2 parent=proj--feat-big repo=proj -->
- [x] create child: `feat-big-two`
- goal: second slice
<!-- wb-breakdown: begin-plan n=2 -->
plan body for child two
<!-- wb-breakdown: end-plan -->

## child 3 — third slice (unchecked)
<!-- wb-breakdown: block=child n=3 parent=proj--feat-big repo=proj -->
- [ ] create child: `feat-big-three`
- goal: third slice
<!-- wb-breakdown: begin-plan n=3 -->
plan body for child three
<!-- wb-breakdown: end-plan -->

## parent edits
<!-- wb-breakdown: block=parent parent=proj--feat-big -->
- [x] migrate branch/worktree + re-aim @task → continuing child: `feat-big-one`
- [ ] rewrite parent ## Plan as below
<!-- wb-breakdown: begin-plan parent -->
post split summary
<!-- wb-breakdown: end-plan -->
- [x] move follow-up: "explore wb breakdown verb further" → child: `feat-big-two`
EOF
}

# --- AE1 (parse half): 2 of 3 children checked -> exactly 2 create actions --
base_buffer > "$BUF_DIR/happy.md"
out="$(_wb_breakdown_validate "$BUF_DIR/happy.md")"
n_creates="$(printf '%s\n' "$out" | grep -c $'^create\t')"
assert_eq "AE1: exactly two create actions from three blocks, two checked" 2 "$n_creates"
if printf '%s\n' "$out" | grep -q 'feat-big-three'; then
  echo "FAIL - AE1: unchecked child's slug must not appear in the action list"
  fail=1
else
  echo "ok   - AE1: unchecked child's slug never appears"
fi
assert "AE1: migration action present" $'^migrate\t' "$out"
assert "AE1: follow-up move action present" $'^move\t' "$out"
if printf '%s\n' "$out" | grep -q $'^plan_rewrite\t'; then
  echo "FAIL - AE1: unchecked parent Plan-rewrite must not appear"; fail=1
else
  echo "ok   - AE1: unchecked parent Plan-rewrite absent"
fi

out_cmd="$(cmd_breakdown --apply "$BUF_DIR/happy.md" 2>&1)"
assert "cmd_breakdown --apply: human summary names 2 children" '2 child' "$out_cmd"
assert "cmd_breakdown --apply: no writes yet (U2)" 'no writes yet' "$out_cmd"
assert_eq "cmd_breakdown --apply: no file actually created in U2" "" "$([ -f "$TASKS_DIR/proj--feat-big-one.md" ] && echo exists)"

# --- checkbox grammar: accepted forms ---------------------------------------
cat > "$BUF_DIR/grammar.md" <<'EOF'
# wb breakdown — proj--feat-big

## child 1 — [X] uppercase
<!-- wb-breakdown: block=child n=1 parent=proj--feat-big repo=proj -->
- [X] create child: `feat-big-upper`
- goal: uppercase X
<!-- wb-breakdown: begin-plan n=1 -->
body
<!-- wb-breakdown: end-plan -->

## child 2 — extra indentation
<!-- wb-breakdown: block=child n=2 parent=proj--feat-big repo=proj -->
   - [x] create child: `feat-big-indent`
- goal: extra indentation
<!-- wb-breakdown: begin-plan n=2 -->
body
<!-- wb-breakdown: end-plan -->

## child 3 — trailing prose
<!-- wb-breakdown: block=child n=3 parent=proj--feat-big repo=proj -->
- [x] create child: `feat-big-prose` (continuing, first child)
- goal: trailing prose
<!-- wb-breakdown: begin-plan n=3 -->
body
<!-- wb-breakdown: end-plan -->

## child 4 — asterisk bullet
<!-- wb-breakdown: block=child n=4 parent=proj--feat-big repo=proj -->
* [x] create child: `feat-big-star`
- goal: asterisk bullet
<!-- wb-breakdown: begin-plan n=4 -->
body
<!-- wb-breakdown: end-plan -->

## parent edits
<!-- wb-breakdown: block=parent parent=proj--feat-big -->
- [ ] rewrite parent ## Plan as below
<!-- wb-breakdown: begin-plan parent -->
body
<!-- wb-breakdown: end-plan -->
EOF
out_grammar="$(_wb_breakdown_validate "$BUF_DIR/grammar.md")"
assert_eq "checkbox grammar: all four accepted forms yield 4 creates" 4 "$(printf '%s\n' "$out_grammar" | grep -c $'^create\t')"

# --- malformed checkbox (attempted but invalid) is a hard parse error -------
cat > "$BUF_DIR/malformed.md" <<'EOF'
# wb breakdown — proj--feat-big

## child 1
<!-- wb-breakdown: block=child n=1 parent=proj--feat-big repo=proj -->
- [y] create child: `feat-big-bad`
- goal: bad checkbox
<!-- wb-breakdown: begin-plan n=1 -->
body
<!-- wb-breakdown: end-plan -->

## parent edits
<!-- wb-breakdown: block=parent parent=proj--feat-big -->
- [ ] rewrite parent ## Plan as below
<!-- wb-breakdown: begin-plan parent -->
body
<!-- wb-breakdown: end-plan -->
EOF
err_malformed="$(_wb_breakdown_validate "$BUF_DIR/malformed.md" 2>&1 1>/dev/null)"; rc_malformed=$?
assert_eq "malformed checkbox: hard error exit code" 2 "$rc_malformed"
assert "malformed checkbox: error names the line" 'malformed checkbox' "$err_malformed"

# --- mangled/deleted marker on a checked block: hard error ------------------
# Delete child 2's block= marker so its checkbox merges into child 1's block,
# giving child 1 two "create child:" lines.
sed '/block=child n=2/d' "$BUF_DIR/happy.md" > "$BUF_DIR/mangled.md"
err_mangled="$(_wb_breakdown_validate "$BUF_DIR/mangled.md" 2>&1 1>/dev/null)"; rc_mangled=$?
assert_eq "mangled marker: hard error exit code" 2 "$rc_mangled"
assert "mangled marker: error names the structural problem" 'must have exactly one|unbalanced begin-plan/end-plan' "$err_mangled"

# --- duplicate n= across child blocks: hard error ---------------------------
sed 's/n=2/n=1/' "$BUF_DIR/happy.md" > "$BUF_DIR/dup-n.md"
err_dupn="$(_wb_breakdown_validate "$BUF_DIR/dup-n.md" 2>&1 1>/dev/null)"; rc_dupn=$?
assert_eq "duplicate n=: hard error exit code" 2 "$rc_dupn"
assert "duplicate n=: error names it" 'duplicate n=1' "$err_dupn"

# --- two raw slugs sanitizing to the same stem: collision error ------------
# child 2 proposes a slug that sanitizes to the same stem as child 1
# (different raw slug, same sanitized form).
cat > "$BUF_DIR/collide-intra.md" <<'EOF'
# wb breakdown — proj--feat-big

## child 1
<!-- wb-breakdown: block=child n=1 parent=proj--feat-big repo=proj -->
- [x] create child: `feat/big-one`
- goal: first
<!-- wb-breakdown: begin-plan n=1 -->
body
<!-- wb-breakdown: end-plan -->

## child 2
<!-- wb-breakdown: block=child n=2 parent=proj--feat-big repo=proj -->
- [x] create child: `feat.big-one`
- goal: second, sanitizes to the same stem as child 1
<!-- wb-breakdown: begin-plan n=2 -->
body
<!-- wb-breakdown: end-plan -->

## parent edits
<!-- wb-breakdown: block=parent parent=proj--feat-big -->
- [ ] rewrite parent ## Plan as below
<!-- wb-breakdown: begin-plan parent -->
body
<!-- wb-breakdown: end-plan -->
EOF
out_collide_intra="$(_wb_breakdown_validate "$BUF_DIR/collide-intra.md" 2>/tmp/wbd-collide-intra.err)"
rc_collide_intra=$?
assert_eq "intra-buffer stem collision: not a hard error (item-level skip)" 0 "$rc_collide_intra"
assert_eq "intra-buffer stem collision: only one create action survives" 1 "$(printf '%s\n' "$out_collide_intra" | grep -c $'^create\t')"
assert "intra-buffer stem collision: warning on stderr" 'already claimed' "$(cat /tmp/wbd-collide-intra.err)"

cat > "$BUF_DIR/collide-store.md" <<'EOF'
# wb breakdown — proj--feat-big

## child 1
<!-- wb-breakdown: block=child n=1 parent=proj--feat-big repo=proj -->
- [x] create child: `feat-big-existing`
- goal: collides with an existing store file
<!-- wb-breakdown: begin-plan n=1 -->
body
<!-- wb-breakdown: end-plan -->

## parent edits
<!-- wb-breakdown: block=parent parent=proj--feat-big -->
- [ ] rewrite parent ## Plan as below
<!-- wb-breakdown: begin-plan parent -->
body
<!-- wb-breakdown: end-plan -->
EOF
out_collide_store="$(_wb_breakdown_validate "$BUF_DIR/collide-store.md" 2>/tmp/wbd-collide-store.err)"
assert_eq "store collision: zero create actions survive" 0 "$(printf '%s\n' "$out_collide_store" | grep -c $'^create\t')"
assert "store collision: warning names the existing file" 'already exists in the store' "$(cat /tmp/wbd-collide-store.err)"

# --- migration edge cases ----------------------------------------------------
# target is an unchecked child -> skip with warning
sed 's/continuing child: `feat-big-one`/continuing child: `feat-big-three`/' "$BUF_DIR/happy.md" \
  > "$BUF_DIR/mig-unchecked-target.md"
out_mig_bad="$(_wb_breakdown_validate "$BUF_DIR/mig-unchecked-target.md" 2>/tmp/wbd-mig-bad.err)"
assert_eq "migration to unchecked child: no migrate action" 0 "$(printf '%s\n' "$out_mig_bad" | grep -c $'^migrate\t')"
assert "migration to unchecked child: warning" 'neither a checked child' "$(cat /tmp/wbd-mig-bad.err)"

# target field still ___ (unfilled placeholder) -> skip with warning
sed 's/continuing child: `feat-big-one`/continuing child: `___`/' "$BUF_DIR/happy.md" \
  > "$BUF_DIR/mig-unfilled.md"
out_mig_unfilled="$(_wb_breakdown_validate "$BUF_DIR/mig-unfilled.md" 2>/tmp/wbd-mig-unfilled.err)"
assert_eq "migration target unfilled (___): no migrate action" 0 "$(printf '%s\n' "$out_mig_unfilled" | grep -c $'^migrate\t')"
assert "migration target unfilled: warning" 'unfilled' "$(cat /tmp/wbd-mig-unfilled.err)"

# parent already session-less (no branch:/worktree:) -> skip with warning
mk_parent proj--feat-sessionless "" ""
sed 's/proj--feat-big/proj--feat-sessionless/g' "$BUF_DIR/happy.md" > "$BUF_DIR/mig-sessionless.md"
out_mig_sl="$(_wb_breakdown_validate "$BUF_DIR/mig-sessionless.md" 2>/tmp/wbd-mig-sl.err)"
assert_eq "migration on session-less parent: no migrate action" 0 "$(printf '%s\n' "$out_mig_sl" | grep -c $'^migrate\t')"
assert "migration on session-less parent: warning" 'already session-less' "$(cat /tmp/wbd-mig-sl.err)"

# a second migration line in the parent block: hard parse error
cat > "$BUF_DIR/mig-duplicate.md" <<'EOF'
# wb breakdown — proj--feat-big

## child 1
<!-- wb-breakdown: block=child n=1 parent=proj--feat-big repo=proj -->
- [x] create child: `feat-big-one`
- goal: first
<!-- wb-breakdown: begin-plan n=1 -->
body
<!-- wb-breakdown: end-plan -->

## parent edits
<!-- wb-breakdown: block=parent parent=proj--feat-big -->
- [x] migrate branch/worktree + re-aim @task → continuing child: `feat-big-one`
- [ ] migrate branch/worktree + re-aim @task → continuing child: `feat-big-one`
<!-- wb-breakdown: begin-plan parent -->
body
<!-- wb-breakdown: end-plan -->
EOF
err_mig_dup="$(_wb_breakdown_validate "$BUF_DIR/mig-duplicate.md" 2>&1 1>/dev/null)"; rc_mig_dup=$?
assert_eq "duplicate migration line: hard error exit code" 2 "$rc_mig_dup"
assert "duplicate migration line: names it" 'more than one migration line' "$err_mig_dup"

# --- slug with whitespace or a backtick: hard parse error -------------------
cat > "$BUF_DIR/bad-slug-space.md" <<'EOF'
# wb breakdown — proj--feat-big

## child 1
<!-- wb-breakdown: block=child n=1 parent=proj--feat-big repo=proj -->
- [x] create child: `feat big one`
- goal: has a space
<!-- wb-breakdown: begin-plan n=1 -->
body
<!-- wb-breakdown: end-plan -->

## parent edits
<!-- wb-breakdown: block=parent parent=proj--feat-big -->
- [ ] rewrite parent ## Plan as below
<!-- wb-breakdown: begin-plan parent -->
body
<!-- wb-breakdown: end-plan -->
EOF
err_bad_slug="$(_wb_breakdown_validate "$BUF_DIR/bad-slug-space.md" 2>&1 1>/dev/null)"; rc_bad_slug=$?
assert_eq "slug with whitespace: hard error exit code" 2 "$rc_bad_slug"
assert "slug with whitespace: names it" 'contains whitespace or a backtick' "$err_bad_slug"

# --- follow-up move: zero or two bullet matches --------------------------
sed 's/move follow-up: "explore wb breakdown verb further"/move follow-up: "no such bullet exists"/' "$BUF_DIR/happy.md" \
  > "$BUF_DIR/move-zero.md"
out_move_zero="$(_wb_breakdown_validate "$BUF_DIR/move-zero.md" 2>/tmp/wbd-move-zero.err)"
assert_eq "follow-up move, zero matches: no move action" 0 "$(printf '%s\n' "$out_move_zero" | grep -c $'^move\t')"
assert "follow-up move, zero matches: warning" 'matched 0 bullet' "$(cat /tmp/wbd-move-zero.err)"

mk_parent proj--feat-dup-followup feat-dup-followup .worktrees/feat-dup-followup
cat >> "$TASKS_DIR/proj--feat-dup-followup.md" <<'EOF'
- explore wb breakdown verb further
EOF
sed 's/proj--feat-big/proj--feat-dup-followup/g' "$BUF_DIR/happy.md" > "$BUF_DIR/move-two.md"
out_move_two="$(_wb_breakdown_validate "$BUF_DIR/move-two.md" 2>/tmp/wbd-move-two.err)"
assert_eq "follow-up move, two matches: no move action" 0 "$(printf '%s\n' "$out_move_two" | grep -c $'^move\t')"
assert "follow-up move, two matches: warning" 'matched 2 bullet' "$(cat /tmp/wbd-move-two.err)"

# move target is an unchecked child -> skipped (falls under the same
# neither-checked-nor-existing-child validity check as migration)
sed '/move follow-up/ s/`feat-big-two`/`feat-big-three`/' "$BUF_DIR/happy.md" > "$BUF_DIR/move-unchecked-target.md"
out_move_bad="$(_wb_breakdown_validate "$BUF_DIR/move-unchecked-target.md" 2>/tmp/wbd-move-bad.err)"
assert_eq "follow-up move to unchecked child: no move action" 0 "$(printf '%s\n' "$out_move_bad" | grep -c $'^move\t')"
assert "follow-up move to unchecked child: warning" 'neither a checked child' "$(cat /tmp/wbd-move-bad.err)"

# --- zero checked items: clean no-op exit 0 ---------------------------------
cat > "$BUF_DIR/zero-checked.md" <<'EOF'
# wb breakdown — proj--feat-big

## child 1
<!-- wb-breakdown: block=child n=1 parent=proj--feat-big repo=proj -->
- [ ] create child: `feat-big-none`
- goal: nothing checked
<!-- wb-breakdown: begin-plan n=1 -->
body
<!-- wb-breakdown: end-plan -->

## parent edits
<!-- wb-breakdown: block=parent parent=proj--feat-big -->
- [ ] rewrite parent ## Plan as below
<!-- wb-breakdown: begin-plan parent -->
body
<!-- wb-breakdown: end-plan -->
EOF
out_zero="$(cmd_breakdown --apply "$BUF_DIR/zero-checked.md" 2>&1)"; rc_zero=$?
assert_eq "zero checked: exit 0" 0 "$rc_zero"
assert "zero checked: clean no-op message" 'nothing checked' "$out_zero"

# --- missing/empty buffer path: non-zero with a distinct message -----------
out_missing="$(cmd_breakdown --apply "$BUF_DIR/does-not-exist.md" 2>&1)"; rc_missing=$?
assert_eq "missing buffer: non-zero exit" 1 "$rc_missing"
assert "missing buffer: distinct message" 'no buffer at' "$out_missing"

: > "$BUF_DIR/empty.md"
out_empty="$(cmd_breakdown --apply "$BUF_DIR/empty.md" 2>&1)"; rc_empty=$?
assert_eq "empty buffer: non-zero exit" 1 "$rc_empty"
assert "empty buffer: distinct message" 'or it.s empty' "$out_empty"

# --- edited parent= field pointing at a different task: rejected -----------
sed '0,/parent=proj--feat-big/! s/parent=proj--feat-big/parent=proj--feat-big-existing/' "$BUF_DIR/happy.md" \
  > "$BUF_DIR/multi-parent.md"
err_multi_parent="$(_wb_breakdown_validate "$BUF_DIR/multi-parent.md" 2>&1 1>/dev/null)"; rc_multi_parent=$?
assert_eq "multi-parent buffer: hard error exit code" 2 "$rc_multi_parent"
assert "multi-parent buffer: names both stems" 'more than one parent' "$err_multi_parent"

rm -rf "$BUF_DIR"

[ "$fail" -eq 0 ] && echo "ALL PASS"
exit "$fail"
