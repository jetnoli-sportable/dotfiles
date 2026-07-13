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
FIXTURE_BIN="$(mktemp -d -t wb-breakdown-bin.XXXXXX)"
REAL_TMUX="$(command -v tmux)"
SOCK="wb-breakdown-sock-$$"
trap '
  "$REAL_TMUX" -L "$SOCK" kill-server 2>/dev/null || true
  rm -rf "$FIXTURE_CODE" "$FIXTURE_TASKS" "$FIXTURE_BIN"
' EXIT

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

# cmd_breakdown --apply's real end-to-end execution (AE1/AE2, the human
# summary, actual writes) is U3's concern — see that section below. Calling
# it here for real would mutate proj--feat-big's shared fixture state
# (migration blanks its branch:/worktree:, the follow-up move empties its
# Follow-ups) that every other scenario in THIS section still depends on.

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

# =============================================================================
# U4 — session/task coherence for migrated families (KTD7)
# =============================================================================

# Isolated tmux socket (wb-new.test.sh's convention): every tmux call below
# hits a throwaway server, never the real attached one — tmux_focus's
# switch-client must not be allowed to hijack this machine's actual client.
cat > "$FIXTURE_BIN/tmux" <<EOF
#!/usr/bin/env bash
exec "$REAL_TMUX" -L "$SOCK" "\$@"
EOF
chmod +x "$FIXTURE_BIN/tmux"
PATH="$FIXTURE_BIN:$PATH"
# No interactive nvim in a test run: cmd_done's Sweep flow appends "- [ ]
# keep <f>" lines then blocks on wb_open_buffer — auto-check every one,
# simulating "the user kept everything," so the dossier-copy path is
# actually exercised instead of silently no-op'd.
wb_open_buffer() { sed -i 's/^- \[ \] keep /- [x] keep /' "$1"; }
wb_bootstrap() { :; }     # no .worktree-bootstrap fixture needed for these scenarios

mk_task_file() { # <stem> <status> <repo> <branch> <worktree> <parent>
  local f="$TASKS_DIR/$1.md"
  printf -- '---\nstatus: %s\nrepo: %s\nbranch: %s\nworktree: %s\nparent: %s\ncreated: 2026-07-01\nclosed:\n---\n# %s\n' \
    "$2" "$3" "$4" "$5" "$6" "$1" > "$f"
}

# --- migrated-family fixture: cmd_done acts on the CHILD, not the parent ---
git -C "$FIXTURE_CODE/proj" worktree add -q -b feat-family ".worktrees/feat-family" >/dev/null 2>&1
mk_task_file proj--feat-family doing proj "" "" ""   # migrated: branch:/worktree: blanked
mk_task_file proj--feat-family-child doing proj feat-family .worktrees/feat-family proj--feat-family
# a gitignored keeper file so the Sweep flow actually exercises the dossier
# path (rather than skipping it entirely on a clean worktree). Via
# .git/info/exclude (shared across every worktree of this repo, unlike a
# tracked .gitignore, which would need to predate the branch point) so
# `feat-family`'s checkout picks it up regardless of branch history.
echo 'scratch-notes.txt' >> "$FIXTURE_CODE/proj/.git/info/exclude"
echo 'kept across the split' > "$FIXTURE_CODE/proj/.worktrees/feat-family/scratch-notes.txt"

fam_session="wb-breakdown-test-family-$$"
tmux new-session -d -s "$fam_session" 2>/dev/null
tmux set-option -t "=$fam_session:" @wb_repo proj >/dev/null      # STALE — the parent's original identity, never re-pointed
tmux set-option -t "=$fam_session:" @wb_slug feat-family >/dev/null
tmux set-option -t "=$fam_session:" @task "$TASKS_DIR/proj--feat-family-child.md" >/dev/null

out_fam="$(cmd_done "$fam_session" 2>&1)"; rc_fam=$?
assert_eq "migrated family: cmd_done exits 0" 0 "$rc_fam"
assert_eq "migrated family: CHILD flipped to done" "done" "$(wb_get_frontmatter "$TASKS_DIR/proj--feat-family-child.md" status)"
assert_eq "migrated family: PARENT untouched (still doing)" "doing" "$(wb_get_frontmatter "$TASKS_DIR/proj--feat-family.md" status)"
if [ -d "$FIXTURE_CODE/proj/.worktrees/feat-family" ]; then
  echo "FAIL - migrated family: worktree not removed"; fail=1
else
  echo "ok   - migrated family: worktree removed"
fi
assert_eq "migrated family: kept file lands under the CHILD's own dossier stem" \
  "kept across the split" "$(cat "$TASKS_DIR/dossiers/proj--feat-family-child/scratch-notes.txt" 2>/dev/null)"
if [ -e "$TASKS_DIR/dossiers/proj--feat-family/scratch-notes.txt" ]; then
  echo "FAIL - migrated family: kept file must NOT land under the parent's stem"; fail=1
else
  echo "ok   - migrated family: nothing dossiered under the parent's stem"
fi
assert "migrated family: message names the session, not a stale parent reference" 'closed' "$out_fam"

# --- @task pointing at a deleted file: fallback derivation, one warning ----
mk_task_file proj--feat-stale-task doing proj feat-stale-task .worktrees/feat-stale-task ""
stale_session="wb-breakdown-test-stale-$$"
tmux new-session -d -s "$stale_session" 2>/dev/null
tmux set-option -t "=$stale_session:" @wb_repo proj >/dev/null
tmux set-option -t "=$stale_session:" @wb_slug feat-stale-task >/dev/null
tmux set-option -t "=$stale_session:" @task "$TASKS_DIR/proj--this-file-does-not-exist.md" >/dev/null

resolved="$(wb_session_task_file "$stale_session" 2>/tmp/wbd-stale-task.err)"
assert_eq "@task deleted: falls back to repo/slug derivation" "$TASKS_DIR/proj--feat-stale-task.md" "$resolved"
warn_count="$(grep -c . /tmp/wbd-stale-task.err)"
assert_eq "@task deleted: exactly one stderr warning" 1 "$warn_count"
assert "@task deleted: warning names the stale path" 'no longer exists' "$(cat /tmp/wbd-stale-task.err)"

# --- resume-after-breakdown: reattaches the CHILD, not the parent -----------
out_resume="$(cmd_resume "feat-family-child" 2>&1)"; rc_resume=$?
assert_eq "resume-after-breakdown: exits 0" 0 "$rc_resume"
if [ -d "$FIXTURE_CODE/proj/.worktrees/feat-family" ]; then
  echo "ok   - resume-after-breakdown: worktree recreated at the SAME (single) path"
else
  echo "FAIL - resume-after-breakdown: worktree was not recreated"; fail=1
fi
wt_count="$(find "$FIXTURE_CODE/proj/.worktrees" -maxdepth 1 -type d -name 'feat-family*' | wc -l)"
assert_eq "resume-after-breakdown: no second worktree created" 1 "$wt_count"
assert_eq "resume-after-breakdown: CHILD file still owns branch:/worktree:" "feat-family" "$(wb_get_frontmatter "$TASKS_DIR/proj--feat-family-child.md" branch)"
assert_eq "resume-after-breakdown: PARENT's blanked fields still blank" "" "$(wb_get_frontmatter "$TASKS_DIR/proj--feat-family.md" branch)"
resume_session="proj--feat-family"   # cmd_new derives the session name from repo+branch, not the child's own stem
resume_task="$(tmux show -t "=$resume_session:" -v @task 2>/dev/null || true)"
assert_eq "resume-after-breakdown: new session's @task points at the CHILD" "$TASKS_DIR/proj--feat-family-child.md" "$resume_task"
tmux kill-session -t "=$resume_session" 2>/dev/null || true

# --- store-only close: session-less, worktree-less parent -------------------
mk_task_file proj--feat-store-only doing proj "" "" ""
out_store="$(cmd_done "proj--feat-store-only" 2>&1)"; rc_store=$?
assert_eq "store-only close: exits 0" 0 "$rc_store"
assert_eq "store-only close: flips to done" "done" "$(wb_get_frontmatter "$TASKS_DIR/proj--feat-store-only.md" status)"
assert "store-only close: handoff entry appended" 'Session closed' "$(cat "$TASKS_DIR/proj--feat-store-only.md")"
assert "store-only close: message says store-only" 'store-only' "$out_store"

out_neither="$(cmd_done "no-such-session-or-task-$$" 2>&1)"; rc_neither=$?
assert_eq "neither session nor task file: non-zero exit" 1 "$rc_neither"
assert "neither session nor task file: fails loud" 'matches no live tmux session and no task file' "$out_neither"

# --- reattach guard: wb_seed_task doesn't refill a blanked pair another ----
# file already claims (direct unit test — same call shape cmd_new's normal
# path uses, without the tmux/git worktree mechanics around it).
mk_task_file proj--feat-reattach doing proj "" "" ""
mk_task_file proj--feat-reattach-child doing proj feat-reattach .worktrees/feat-reattach proj--feat-reattach
guard_out="$(wb_seed_task proj feat-reattach ".worktrees/feat-reattach" 2>/tmp/wbd-reattach.err)"
assert_eq "reattach guard: parent's branch: stays blank" "" "$(wb_get_frontmatter "$TASKS_DIR/proj--feat-reattach.md" branch)"
assert_eq "reattach guard: parent's worktree: stays blank" "" "$(wb_get_frontmatter "$TASKS_DIR/proj--feat-reattach.md" worktree)"
assert "reattach guard: warning names the claiming child" 'proj--feat-reattach-child' "$(cat /tmp/wbd-reattach.err)"

# --- picker attribution: migrated session's row shows the CHILD ------------
mk_task_file proj--feat-picker doing proj "" "" ""
mk_task_file proj--feat-picker-child doing proj feat-picker .worktrees/feat-picker proj--feat-picker
picker_session="wb-breakdown-test-picker-$$"
tmux new-session -d -s "$picker_session" 2>/dev/null
tmux set-option -t "=$picker_session:" @wb_repo proj >/dev/null
tmux set-option -t "=$picker_session:" @wb_slug feat-picker >/dev/null
tmux set-option -t "=$picker_session:" @task "$TASKS_DIR/proj--feat-picker-child.md" >/dev/null
row="$(wb_live_session_row "$picker_session")"
declare -a row_fields; wb_tsv_split "$row" row_fields   # NEVER `IFS=$'\t' read` — bash treats tab as
                                                          # IFS-whitespace regardless, collapsing the
                                                          # empty urgency-target field (see wb_tsv_split's
                                                          # own header comment; reproduced live here first).
assert_eq "picker attribution: ref names the CHILD's file, not the parent's" "$TASKS_DIR/proj--feat-picker-child.md" "${row_fields[7]}"
tmux kill-session -t "=$picker_session" 2>/dev/null || true

# a session with no @task at all renders byte-identical to before (repo/slug-derived)
mk_task_file proj--feat-nostale doing proj feat-nostale .worktrees/feat-nostale ""
plain_session="wb-breakdown-test-plain-$$"
tmux new-session -d -s "$plain_session" 2>/dev/null
tmux set-option -t "=$plain_session:" @wb_repo proj >/dev/null
tmux set-option -t "=$plain_session:" @wb_slug feat-nostale >/dev/null
row_plain="$(wb_live_session_row "$plain_session")"
declare -a row_plain_fields; wb_tsv_split "$row_plain" row_plain_fields
assert_eq "picker attribution: no-@task session renders the repo/slug-derived file (unchanged)" "$TASKS_DIR/proj--feat-nostale.md" "${row_plain_fields[7]}"
tmux kill-session -t "=$plain_session" 2>/dev/null || true

# --- worktree drift: worktree: set but missing, while .worktrees/$slug exists
git -C "$FIXTURE_CODE/proj" worktree add -q -b feat-drift ".worktrees/feat-drift" >/dev/null 2>&1
mk_task_file proj--feat-drift doing proj feat-drift .worktrees/nonexistent-path ""
drift_session="wb-breakdown-test-drift-$$"
tmux new-session -d -s "$drift_session" 2>/dev/null
tmux set-option -t "=$drift_session:" @wb_repo proj >/dev/null
tmux set-option -t "=$drift_session:" @wb_slug feat-drift >/dev/null
out_drift="$(cmd_done "$drift_session" 2>&1)"; rc_drift=$?
assert_eq "worktree drift: non-zero exit" 1 "$rc_drift"
assert "worktree drift: names the drift" 'refusing to guess' "$out_drift"
assert_eq "worktree drift: task NOT flipped to done" "doing" "$(wb_get_frontmatter "$TASKS_DIR/proj--feat-drift.md" status)"
if [ -d "$FIXTURE_CODE/proj/.worktrees/feat-drift" ]; then
  echo "ok   - worktree drift: real worktree untouched"
else
  echo "FAIL - worktree drift: real worktree was removed despite the drift guard"; fail=1
fi
tmux kill-session -t "=$drift_session" 2>/dev/null || true

# =============================================================================
# U3 — locked family apply execution (real writes)
# =============================================================================

U3_BUF="$(mktemp -d -t wb-breakdown-u3.XXXXXX)"

mk_u3_parent() { # <stem> <branch> <worktree>
  local f="$TASKS_DIR/$1.md"
  {
    printf -- '---\nstatus: doing\nrepo: proj\nbranch: %s\nworktree: %s\nparent:\ncreated: 2026-07-01\n---\n' "$2" "$3"
    printf '# U3 Family\n\n## Plan\n\noriginal plan content\n\n## Follow-ups\n\n'
    printf -- '- explore artifact indexing further\n  - needs API design first (sub-note)\n'
    printf -- '- unrelated follow-up that stays on the parent\n'
  } > "$f"
}

u3_buffer() {
  cat <<'EOF'
# wb breakdown — proj--feat-u3

## child 1 — continuing
<!-- wb-breakdown: block=child n=1 parent=proj--feat-u3 repo=proj -->
- [x] create child: `feat-u3-one`
- goal: continuing slice
<!-- wb-breakdown: begin-plan n=1 -->
child one plan body
<!-- wb-breakdown: end-plan -->

## child 2 — artifact index
<!-- wb-breakdown: block=child n=2 parent=proj--feat-u3 repo=proj -->
- [x] create child: `feat-u3-two`
- goal: artifact indexing slice
<!-- wb-breakdown: begin-plan n=2 -->
child two plan body
<!-- wb-breakdown: end-plan -->

## child 3 — unchecked
<!-- wb-breakdown: block=child n=3 parent=proj--feat-u3 repo=proj -->
- [ ] create child: `feat-u3-three`
- goal: not this time
<!-- wb-breakdown: begin-plan n=3 -->
child three plan body
<!-- wb-breakdown: end-plan -->

## parent edits
<!-- wb-breakdown: block=parent parent=proj--feat-u3 -->
- [x] migrate branch/worktree + re-aim @task → continuing child: `feat-u3-one`
- [x] rewrite parent ## Plan as below
<!-- wb-breakdown: begin-plan parent -->
post-split summary — see the continuing child for the rest
<!-- wb-breakdown: end-plan -->
- [x] move follow-up: "explore artifact indexing further" → child: `feat-u3-two`
EOF
}

git -C "$FIXTURE_CODE/proj" worktree add -q -b feat-u3 ".worktrees/feat-u3" >/dev/null 2>&1
mk_u3_parent proj--feat-u3 feat-u3 .worktrees/feat-u3
u3_buffer > "$U3_BUF/family.md"

out_u3="$(cmd_breakdown --apply "$U3_BUF/family.md" 2>&1)"; rc_u3=$?
assert_eq "U3 apply: exits 0" 0 "$rc_u3"

# --- AE1: exactly two child files, unchecked child absent -------------------
assert_eq "U3 AE1: child 1 file created" "feat-u3-one" "$(wb_get_frontmatter "$TASKS_DIR/proj--feat-u3-one.md" branch >/dev/null 2>&1 && echo feat-u3-one)"
[ -f "$TASKS_DIR/proj--feat-u3-one.md" ] && echo "ok   - U3 AE1: child 1 file exists" || { echo "FAIL - U3 AE1: child 1 file missing"; fail=1; }
[ -f "$TASKS_DIR/proj--feat-u3-two.md" ] && echo "ok   - U3 AE1: child 2 file exists" || { echo "FAIL - U3 AE1: child 2 file missing"; fail=1; }
if [ -f "$TASKS_DIR/proj--feat-u3-three.md" ]; then
  echo "FAIL - U3 AE1: unchecked child 3 must not exist"; fail=1
else
  echo "ok   - U3 AE1: unchecked child 3 never created"
fi
assert_eq "U3 AE1: child 1 parent: set" "proj--feat-u3" "$(wb_get_frontmatter "$TASKS_DIR/proj--feat-u3-one.md" parent)"
assert "U3 AE1: child 1 plan body landed" "child one plan body" "$(cat "$TASKS_DIR/proj--feat-u3-one.md")"
assert "U3 AE1: child 2 plan body landed" "child two plan body" "$(cat "$TASKS_DIR/proj--feat-u3-two.md")"
assert "U3 AE1: parent's ## Plan replaced with the buffer's rewrite" "post-split summary" "$(cat "$TASKS_DIR/proj--feat-u3.md")"
if grep -q "original plan content" "$TASKS_DIR/proj--feat-u3.md"; then
  echo "FAIL - U3 AE1: parent's OLD Plan content must be replaced, not appended alongside"; fail=1
else
  echo "ok   - U3 AE1: parent's old Plan content is gone (replaced, not appended)"
fi

# --- AE2: migration -----------------------------------------------------
assert_eq "U3 AE2: child 1 (continuing) inherits parent's branch:" "feat-u3" "$(wb_get_frontmatter "$TASKS_DIR/proj--feat-u3-one.md" branch)"
assert_eq "U3 AE2: child 1 inherits parent's worktree:" ".worktrees/feat-u3" "$(wb_get_frontmatter "$TASKS_DIR/proj--feat-u3-one.md" worktree)"
assert_eq "U3 AE2: child 1 status flips to doing" "doing" "$(wb_get_frontmatter "$TASKS_DIR/proj--feat-u3-one.md" status)"
assert_eq "U3 AE2: parent's branch: blanked" "" "$(wb_get_frontmatter "$TASKS_DIR/proj--feat-u3.md" branch)"
assert_eq "U3 AE2: parent's worktree: blanked" "" "$(wb_get_frontmatter "$TASKS_DIR/proj--feat-u3.md" worktree)"
# Scoped to THIS test's own files: the accumulated fixture store from
# earlier sections in this same test file carries plenty of synthetic
# worktree: values with no real directory behind them (unrelated "missing"
# noise) — AE2's claim is specifically about proj--feat-u3(-one), not a
# clean bill of health for the whole accumulated fixture store.
recon_u3="$(wb_reconcile_collect 2>/dev/null)"
if printf '%s' "$recon_u3" | grep -E '^missing' | grep -qE 'proj--feat-u3(-one)?\.md$'; then
  echo "FAIL - U3 AE2: wb_reconcile_collect must report zero findings for proj--feat-u3/-one post-migration"; fail=1
else
  echo "ok   - U3 AE2: wb_reconcile_collect reports zero findings for proj--feat-u3/-one post-migration"
fi

# --- follow-up move: whole block (incl. sub-bullet) moves, count unchanged -
assert "U3 move: bullet landed on child 2's Follow-ups" "explore artifact indexing further" "$(cat "$TASKS_DIR/proj--feat-u3-two.md")"
assert "U3 move: sub-bullet moved WITH its parent bullet (whole block)" "needs API design first" "$(cat "$TASKS_DIR/proj--feat-u3-two.md")"
if grep -q "explore artifact indexing further" "$TASKS_DIR/proj--feat-u3.md"; then
  echo "FAIL - U3 move: bullet must be REMOVED from the parent (a move, not a copy)"; fail=1
else
  echo "ok   - U3 move: bullet removed from the parent"
fi
assert "U3 move: the OTHER follow-up stays on the parent" "unrelated follow-up that stays" "$(cat "$TASKS_DIR/proj--feat-u3.md")"

# --- archived buffer + handoff entry naming it ------------------------------
assert_eq "U3 archive: closed buffer archived under dossiers/<parent-stem>/" "family.md" "$(basename "$TASKS_DIR/dossiers/proj--feat-u3/family.md" 2>/dev/null)"
assert "U3 archive: handoff entry names the archived path" 'dossiers/proj--feat-u3/family.md' "$(cat "$TASKS_DIR/proj--feat-u3.md")"
handoff_count_1="$(grep -c '^### .* — wb breakdown (auto)$' "$TASKS_DIR/proj--feat-u3.md")"
assert_eq "U3 handoff: exactly one entry after the first apply" 1 "$handoff_count_1"

# --- idempotent re-apply: second run is a clean no-op, store byte-identical
snapshot_before="$(find "$TASKS_DIR" -maxdepth 1 -name 'proj--feat-u3*.md' -exec cat {} \;)"
out_u3_again="$(cmd_breakdown --apply "$U3_BUF/family.md" 2>&1)"; rc_u3_again=$?
assert_eq "U3 idempotent re-apply: exits 0" 0 "$rc_u3_again"
snapshot_after="$(find "$TASKS_DIR" -maxdepth 1 -name 'proj--feat-u3*.md' -exec cat {} \;)"
assert_eq "U3 idempotent re-apply: store byte-identical" "$snapshot_before" "$snapshot_after"
handoff_count_2="$(grep -c '^### .* — wb breakdown (auto)$' "$TASKS_DIR/proj--feat-u3.md")"
assert_eq "U3 idempotent re-apply: handoff NOT duplicated" 1 "$handoff_count_2"

# --- crash simulation: child already seeded, migration not yet done --------
git -C "$FIXTURE_CODE/proj" worktree add -q -b feat-u3-crash ".worktrees/feat-u3-crash" >/dev/null 2>&1
mk_u3_parent proj--feat-u3-crash feat-u3-crash .worktrees/feat-u3-crash
cat > "$U3_BUF/crash.md" <<'EOF'
# wb breakdown — proj--feat-u3-crash

## child 1 — continuing
<!-- wb-breakdown: block=child n=1 parent=proj--feat-u3-crash repo=proj -->
- [x] create child: `feat-u3-crash-one`
- goal: continuing slice
<!-- wb-breakdown: begin-plan n=1 -->
child one plan body
<!-- wb-breakdown: end-plan -->

## parent edits
<!-- wb-breakdown: block=parent parent=proj--feat-u3-crash -->
- [x] migrate branch/worktree + re-aim @task → continuing child: `feat-u3-crash-one`
<!-- wb-breakdown: begin-plan parent -->
n/a
<!-- wb-breakdown: end-plan -->
EOF
# Simulate "crashed after step 1, before migration": pre-seed the child
# exactly as wb_seed_planned_child would have, by hand.
printf -- '---\nstatus: planned\nrepo: proj\nbranch: feat-u3-crash-one\nworktree:\nparent: proj--feat-u3-crash\ncreated: 2026-07-01\n---\n# continuing slice\n\n## Plan\n\nchild one plan body\n' \
  > "$TASKS_DIR/proj--feat-u3-crash-one.md"

out_crash="$(cmd_breakdown --apply "$U3_BUF/crash.md" 2>&1)"; rc_crash=$?
assert_eq "U3 crash recovery: exits 0" 0 "$rc_crash"
assert "U3 crash recovery: child NOT re-created (already existed), just skipped" 'already created, skipping' "$out_crash"
assert_eq "U3 crash recovery: migration STILL completes on the resumed run" "feat-u3-crash" "$(wb_get_frontmatter "$TASKS_DIR/proj--feat-u3-crash-one.md" branch)"
assert_eq "U3 crash recovery: child flips to doing" "doing" "$(wb_get_frontmatter "$TASKS_DIR/proj--feat-u3-crash-one.md" status)"
assert_eq "U3 crash recovery: parent blanked" "" "$(wb_get_frontmatter "$TASKS_DIR/proj--feat-u3-crash.md" branch)"
if [ -f "$TASKS_DIR/proj--feat-u3-crash-one.md" ]; then
  echo "ok   - U3 crash recovery: no file was deleted"
else
  echo "FAIL - U3 crash recovery: the pre-existing child file is gone"; fail=1
fi

# --- lock contention: a held sibling lock -> exit 75, zero writes -----------
mk_u3_parent proj--feat-u3-lock feat-u3-lock .worktrees/feat-u3-lock
cat > "$U3_BUF/lock.md" <<'EOF'
# wb breakdown — proj--feat-u3-lock

## child 1
<!-- wb-breakdown: block=child n=1 parent=proj--feat-u3-lock repo=proj -->
- [x] create child: `feat-u3-lock-one`
- goal: contended
<!-- wb-breakdown: begin-plan n=1 -->
body
<!-- wb-breakdown: end-plan -->

## parent edits
<!-- wb-breakdown: block=parent parent=proj--feat-u3-lock -->
- [ ] rewrite parent ## Plan as below
<!-- wb-breakdown: begin-plan parent -->
n/a
<!-- wb-breakdown: end-plan -->
EOF
before_lock_snapshot="$(cat "$TASKS_DIR/proj--feat-u3-lock.md")"
wb_task_lock_acquire "$TASKS_DIR/proj--feat-u3-lock.md" >/dev/null 2>&1
out_contend="$(cmd_breakdown --apply "$U3_BUF/lock.md" 2>&1)"; rc_contend=$?
wb_task_lock_release "$TASKS_DIR/proj--feat-u3-lock.md"
assert_eq "U3 lock contention: exit 75" 75 "$rc_contend"
if [ -f "$TASKS_DIR/proj--feat-u3-lock-one.md" ]; then
  echo "FAIL - U3 lock contention: child must NOT have been created"; fail=1
else
  echo "ok   - U3 lock contention: zero writes (child never created)"
fi
assert_eq "U3 lock contention: parent file untouched" "$before_lock_snapshot" "$(cat "$TASKS_DIR/proj--feat-u3-lock.md")"
# the lock we held ourselves must still be releasable cleanly afterward —
# confirms apply's own failed acquisition attempt didn't corrupt it.
wb_task_lock_acquire "$TASKS_DIR/proj--feat-u3-lock.md" >/tmp/wbd-lock-recheck.out 2>&1
recheck_rc=$?
wb_task_lock_release "$TASKS_DIR/proj--feat-u3-lock.md"
assert_eq "U3 lock contention: lock is clean and acquirable again after" 0 "$recheck_rc"

rm -rf "$U3_BUF"

# =============================================================================
# U5 — wb done last-child nudge (KTD8)
# =============================================================================

mk_nudge_task() { # <stem> <status> <parent>
  local f="$TASKS_DIR/$1.md"
  printf -- '---\nstatus: %s\nrepo: proj\nbranch: %s\nworktree: .worktrees/%s\nparent: %s\ncreated: 2026-07-01\n---\n# %s\n' \
    "$2" "$1" "$1" "$3" "$1" > "$f"
}
mk_nudge_session() { # <slug> — real session + real worktree, matching that slug's task file
  git -C "$FIXTURE_CODE/proj" worktree add -q -b "$1" ".worktrees/$1" >/dev/null 2>&1
  local s="wb-breakdown-test-nudge-$1-$$"
  tmux new-session -d -s "$s" 2>/dev/null
  tmux set-option -t "=$s:" @wb_repo proj >/dev/null
  tmux set-option -t "=$s:" @wb_slug "$1" >/dev/null
  printf '%s\n' "$s"
}

# --- AE3: two-child family, closing the last one fires the nudge ----------
mk_nudge_task proj--feat-nudge2 doing ""
mk_nudge_task proj--feat-nudge2-a done proj--feat-nudge2
mk_nudge_task proj--feat-nudge2-b doing proj--feat-nudge2
sess_b="$(mk_nudge_session feat-nudge2-b)"
out_b="$(cmd_done "$sess_b" 2>&1)"
assert "AE3: closing the last child fires the nudge, naming the parent" \
  'all children of proj--feat-nudge2 are done' "$out_b"
assert "AE3: nudge names the exact close command" \
  'close it with: wb done proj--feat-nudge2' "$out_b"

# --- AE3: three-child family, one sibling still open -> silent -------------
mk_nudge_task proj--feat-nudge3 doing ""
mk_nudge_task proj--feat-nudge3-a done proj--feat-nudge3
mk_nudge_task proj--feat-nudge3-b doing proj--feat-nudge3
mk_nudge_task proj--feat-nudge3-c review proj--feat-nudge3
sess_3b="$(mk_nudge_session feat-nudge3-b)"
out_3b="$(cmd_done "$sess_3b" 2>&1)"
if printf '%s' "$out_3b" | grep -q 'all children of'; then
  echo "FAIL - AE3: a still-open sibling (review) must suppress the nudge"; fail=1
else
  echo "ok   - AE3: still-open sibling (status: review) suppresses the nudge"
fi

# --- only child: fires immediately -----------------------------------------
mk_nudge_task proj--feat-nudge-only doing ""
mk_nudge_task proj--feat-nudge-only-a doing proj--feat-nudge-only
sess_only="$(mk_nudge_session feat-nudge-only-a)"
out_only="$(cmd_done "$sess_only" 2>&1)"
assert "only child: nudge fires" 'all children of proj--feat-nudge-only are done' "$out_only"

# --- parent: empty -> no scan, no nudge, no error ---------------------------
mk_nudge_task proj--feat-nudge-noparent doing ""
sess_np="$(mk_nudge_session feat-nudge-noparent)"
out_np="$(cmd_done "$sess_np" 2>&1)"; rc_np=$?
assert_eq "parent: empty — exits 0" 0 "$rc_np"
if printf '%s' "$out_np" | grep -q 'all children of'; then
  echo "FAIL - parent: empty must never scan/print a nudge"; fail=1
else
  echo "ok   - parent: empty — no nudge attempted"
fi

# --- parent file missing (stale parent: pointing nowhere) -> silent, still succeeds
mk_nudge_task proj--feat-nudge-ghostparent doing proj--feat-nudge-nonexistent-parent
sess_ghost="$(mk_nudge_session feat-nudge-ghostparent)"
out_ghost="$(cmd_done "$sess_ghost" 2>&1)"; rc_ghost=$?
assert_eq "missing parent file: exits 0 (cmd_done still succeeds)" 0 "$rc_ghost"
if printf '%s' "$out_ghost" | grep -q 'all children of'; then
  echo "FAIL - missing parent file: must not print a nudge for a parent that doesn't exist"; fail=1
else
  echo "ok   - missing parent file: silent, no crash"
fi

# --- nudge is stdout-only: store byte-identical apart from the closed task's own flip
mk_nudge_task proj--feat-nudge-byte doing ""
mk_nudge_task proj--feat-nudge-byte-a done proj--feat-nudge-byte
mk_nudge_task proj--feat-nudge-byte-b doing proj--feat-nudge-byte
parent_snapshot_before="$(cat "$TASKS_DIR/proj--feat-nudge-byte.md")"
sibling_snapshot_before="$(cat "$TASKS_DIR/proj--feat-nudge-byte-a.md")"
sess_byte="$(mk_nudge_session feat-nudge-byte-b)"
cmd_done "$sess_byte" >/dev/null 2>&1
assert_eq "nudge is stdout-only: parent file byte-identical" "$parent_snapshot_before" "$(cat "$TASKS_DIR/proj--feat-nudge-byte.md")"
assert_eq "nudge is stdout-only: sibling (already-done) file byte-identical" "$sibling_snapshot_before" "$(cat "$TASKS_DIR/proj--feat-nudge-byte-a.md")"

# =============================================================================
# U6 — /wb-breakdown skill: write-boundary grep check
# =============================================================================
# Same convention wb-append.test.sh's W14 scenario already established for
# handoff/parked-items/wb-save — a reasonable grep-based smoke check (not
# exhaustive NLP) that this new skill never instructs an Edit/Write-tool
# write against ~/code/tasks, and DOES reference the locked verbs + state
# the never-Edit/Write-tool rule.

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../../.." && pwd)"
SKILL_FILE="$REPO_ROOT/claude/.claude/skills/wb-breakdown/SKILL.md"

if [ ! -f "$SKILL_FILE" ]; then
  echo "FAIL - U6 skill grep check: $SKILL_FILE not found"
  fail=1
else
  if grep -niE 'use read then edit|(edit|write) tool.*(task file|~/code/tasks)|write .?~/code/tasks/[^ ]*\.md' "$SKILL_FILE" >/dev/null; then
    echo "FAIL - U6 skill grep check: wb-breakdown/SKILL.md contains an Edit/Write-tool task-file write instruction:"
    grep -niE 'use read then edit|(edit|write) tool.*(task file|~/code/tasks)|write .?~/code/tasks/[^ ]*\.md' "$SKILL_FILE" | sed 's/^/       /'
    fail=1
  else
    echo "ok   - U6 skill grep check: wb-breakdown/SKILL.md has no Edit/Write-tool task-file write instruction"
  fi

  if grep -qE 'wb (breakdown --apply|new --planned)' "$SKILL_FILE"; then
    echo "ok   - U6 skill grep check: references wb breakdown --apply / wb new --planned"
  else
    echo "FAIL - U6 skill grep check: does not reference wb breakdown --apply or wb new --planned"
    fail=1
  fi

  if grep -Pzoqi '(?s)never[^.]{0,200}?(edit|write)[\s/-]*tool' "$SKILL_FILE"; then
    echo "ok   - U6 skill grep check: states the never-Edit/Write-tool-task-files rule"
  else
    echo "FAIL - U6 skill grep check: missing the never-Edit/Write-tool-task-files rule"
    fail=1
  fi
fi

[ "$fail" -eq 0 ] && echo "ALL PASS"
exit "$fail"
