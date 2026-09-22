#!/usr/bin/env bash
# Behavioral tests for board2's single-pass collect + model (feat-board-build
# U2): wb_board_v2_read_file, wb_board_v2_parse_record, wb_board_collect_rows_v2
# and wb_board_build_model. Same convention as wb-new.test.sh (source wb.sh,
# fixture TASKS_DIR, plain assert helpers) — no bats, matches this repo's
# `*.test.sh` suite.
#
# Run: bash scripts/.config/scripts/tmux/tests/wb-board-model.test.sh
set -uo pipefail

WB="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/wb.sh"
FIXTURE_TASKS="$(mktemp -d -t wb-board-model-tasks.XXXXXX)"
FIXTURE_BIN="$(mktemp -d -t wb-board-model-bin.XXXXXX)"
FIXTURE_TRACE="$(mktemp -t wb-board-model-trace.XXXXXX)"

# R16's proof: tmux/gh/git shims that only APPEND their own name to a trace
# file instead of doing anything real. If board2's collect path ever shells
# out to one of these, the trace file gains a line and the "no shell-outs"
# assertion below fails loudly instead of just happening to still pass.
for bin in tmux gh git; do
  cat > "$FIXTURE_BIN/$bin" <<EOF
#!/usr/bin/env bash
echo "$bin \$*" >> "$FIXTURE_TRACE"
exit 0
EOF
  chmod +x "$FIXTURE_BIN/$bin"
done
# stat/date/awk/basename/etc. must still resolve to the real system
# binaries — only tmux/gh/git are shimmed, so prepend rather than replace.
PATH="$FIXTURE_BIN:$PATH"

cleanup() { rm -rf "$FIXTURE_TASKS" "$FIXTURE_BIN" "$FIXTURE_TRACE"; }
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

# mk_task <stem> <status> <mtime_days_ago> [<extra frontmatter lines>] —
# writes a fixture task file, then backdates its mtime (R21's staleness
# clock reads mtime, not created:).
mk_task() {
  local stem="$1" status="$2" days_ago="$3" extra="${4:-}"
  local f="$FIXTURE_TASKS/$stem.md"
  cat > "$f" <<EOF
---
status: $status
path:
repo: dotfiles
branch: feat/$stem
worktree: .worktrees/feat/$stem
$extra
---
# Title for $stem
EOF
  touch -d "$days_ago days ago" "$f"
}

TASKS_DIR="$FIXTURE_TASKS"
source "$WB"

# --- fixtures -----------------------------------------------------------
mk_task active-task doing 2
mk_task stale-task doing 14
mk_task border-task doing 13
mk_task planned-task planned 5
mk_task paused-task paused 5

cat > "$FIXTURE_TASKS/plan-task.md" <<'EOF'
---
status: doing
path:
repo: dotfiles
branch: feat/plan-task
worktree: .worktrees/feat/plan-task
---
# Plan task

## Plan
- [x] done one
- [x] done two
- [ ] not done yet
EOF
touch -d "1 days ago" "$FIXTURE_TASKS/plan-task.md"

cat > "$FIXTURE_TASKS/no-plan-task.md" <<'EOF'
---
status: doing
path:
repo: dotfiles
branch: feat/no-plan-task
worktree: .worktrees/feat/no-plan-task
---
# No plan task

## Done
- shipped it
EOF
touch -d "1 days ago" "$FIXTURE_TASKS/no-plan-task.md"

cat > "$FIXTURE_TASKS/no-handoff-task.md" <<'EOF'
---
status: doing
path:
repo: dotfiles
branch: feat/no-handoff-task
worktree: .worktrees/feat/no-handoff-task
---
# No handoff task

## Follow-ups
- a follow-up item
EOF
touch -d "1 days ago" "$FIXTURE_TASKS/no-handoff-task.md"

cat > "$FIXTURE_TASKS/handoff-task.md" <<'EOF'
---
status: doing
path:
repo: dotfiles
branch: feat/handoff-task
worktree: .worktrees/feat/handoff-task
---
# Handoff task

## Handoffs

### 2026-01-01 00:00 — wb pause (auto)
Session paused via `wb pause`.

### 2026-01-02 00:00 — wb-save
**Done:** first thing
**Next:** second thing
EOF
touch -d "1 days ago" "$FIXTURE_TASKS/handoff-task.md"

cat > "$FIXTURE_TASKS/tags-bare.md" <<'EOF'
---
status: planned
path:
repo: dotfiles
branch: feat/tags-bare
worktree: .worktrees/feat/tags-bare
tags: solo
---
# Tags bare
EOF
touch -d "1 days ago" "$FIXTURE_TASKS/tags-bare.md"

cat > "$FIXTURE_TASKS/tags-csv.md" <<'EOF'
---
status: planned
path:
repo: dotfiles
branch: feat/tags-csv
worktree: .worktrees/feat/tags-csv
tags: a,b
EOF
touch -d "1 days ago" "$FIXTURE_TASKS/tags-csv.md"

cat > "$FIXTURE_TASKS/tags-list.md" <<'EOF'
---
status: planned
path:
repo: dotfiles
branch: feat/tags-list
worktree: .worktrees/feat/tags-list
tags: [a, b]
---
# Tags list
EOF
touch -d "1 days ago" "$FIXTURE_TASKS/tags-list.md"

cat > "$FIXTURE_TASKS/parent-a.md" <<'EOF'
---
status: doing
path:
repo: dotfiles
branch: feat/parent-a
worktree: .worktrees/feat/parent-a
---
# Family root

## Plan
See docs/plans/2026-01-01-001-feat-parent-a-plan.md for the writeup.

## Decisions

### 2026-01-02 — Chose the simple approach
Went with the direct fix instead of a bigger refactor.
EOF
touch -d "1 days ago" "$FIXTURE_TASKS/parent-a.md"

cat > "$FIXTURE_TASKS/parent-a--child-b.md" <<'EOF'
---
status: doing
path:
repo: dotfiles
branch: feat/child-b
worktree: .worktrees/feat/child-b
parent: parent-a
---
# Family child
EOF
touch -d "1 days ago" "$FIXTURE_TASKS/parent-a--child-b.md"

# --- U2/R2: size + acceptance-signal fixtures ----------------------------
# size: L + an "## Acceptance criteria" heading -> M_SIZE=L, M_ACCEPT=1.
cat > "$FIXTURE_TASKS/size-accept.md" <<'EOF'
---
status: doing
path:
repo: dotfiles
branch: feat/size-accept
worktree: .worktrees/feat/size-accept
size: L
---
# Size and accept fixture

## Acceptance criteria
- must do the thing
EOF
touch -d "1 days ago" "$FIXTURE_TASKS/size-accept.md"

# Blank size:, no acceptance text -> M_SIZE empty, M_ACCEPT=0. Also the
# trailing-empty-field hazard (KTD8): size/accept are the LAST two fields of
# both TSV layers, and this fixture pins one of them (accept_sig) to its
# falsy "0" default while size is truly empty, so an off-by-one in the new
# tab positions would corrupt PR_URL (an EARLIER field, checked below) or
# leave M_TAGS/M_TITLE misaligned (also checked below) rather than just this
# fixture's own two new fields.
cat > "$FIXTURE_TASKS/blank-size-no-accept.md" <<'EOF'
---
status: doing
path:
repo: dotfiles
branch: feat/blank-size-no-accept
worktree: .worktrees/feat/blank-size-no-accept
size:
tags: solo
---
# Blank size no accept fixture

See https://github.com/acme/repo/pull/42 for the PR.

## Done
- shipped it, no accept language here
EOF
touch -d "1 days ago" "$FIXTURE_TASKS/blank-size-no-accept.md"

# "Definition of Done" in a Follow-ups bullet (not the Plan section) still
# sets M_ACCEPT=1 — KTD7's "matched anywhere in the file body" requirement.
cat > "$FIXTURE_TASKS/dod-in-followups.md" <<'EOF'
---
status: doing
path:
repo: dotfiles
branch: feat/dod-in-followups
worktree: .worktrees/feat/dod-in-followups
---
# DoD in follow-ups fixture

## Follow-ups
- write up a Definition of Done for the next phase
EOF
touch -d "1 days ago" "$FIXTURE_TASKS/dod-in-followups.md"

# Lowercase "definition of done" matches; the bare word "acceptance" alone
# (no "criteria") must NOT match.
cat > "$FIXTURE_TASKS/lowercase-dod.md" <<'EOF'
---
status: doing
path:
repo: dotfiles
branch: feat/lowercase-dod
worktree: .worktrees/feat/lowercase-dod
---
# Lowercase dod fixture

## Notes
lowercase definition of done mention here, and separately the word
acceptance on its own with no "criteria" after it.
EOF
touch -d "1 days ago" "$FIXTURE_TASKS/lowercase-dod.md"

cat > "$FIXTURE_TASKS/bare-acceptance-word.md" <<'EOF'
---
status: doing
path:
repo: dotfiles
branch: feat/bare-acceptance-word
worktree: .worktrees/feat/bare-acceptance-word
---
# Bare acceptance word fixture

## Notes
We need broad market acceptance before shipping this.
EOF
touch -d "1 days ago" "$FIXTURE_TASKS/bare-acceptance-word.md"

# size: XS round-trip (2026-09-23's XS addition to the size: enum).
cat > "$FIXTURE_TASKS/size-xs.md" <<'EOF'
---
status: planned
path:
repo: dotfiles
branch: feat/size-xs
worktree: .worktrees/feat/size-xs
size: XS
---
# Size XS fixture
EOF
touch -d "1 days ago" "$FIXTURE_TASKS/size-xs.md"

# --- run the collector ---------------------------------------------------
declare -a V2ROWS=()
declare -A M_PLAN_RAW=() M_DONE_RAW=() M_HANDOFF_RAW=() M_FOLLOWUPS_RAW=() \
  M_DECISIONS_RAW=() M_LINKS_RAW=()
wb_board_collect_rows_v2 V2ROWS M_PLAN_RAW M_DONE_RAW M_HANDOFF_RAW M_FOLLOWUPS_RAW \
  M_DECISIONS_RAW M_LINKS_RAW

declare -A M_STATUS=() M_REPO=() M_BRANCH=() M_WORKTREE=() M_TITLE=() \
  M_CREATED=() M_CLOSED=() M_UPDATED=() M_TASKFILE=() M_PARENT=() \
  M_DEPS=() M_TAGS=() M_PLAN_CHECKED=() M_PLAN_TOTAL=() M_AGE_DAYS=() \
  M_BUCKET=() M_HANDOFF_SUMMARY=() M_FAMILY_ROOT=() STEM_PARENT=() \
  STEM_ANCHOR=() FAMILY_CHILDREN=() BUCKET_COUNT=() M_STAGE_SIG=() M_PR_URL=() \
  M_SIZE=() M_ACCEPT=()
wb_board_build_model V2ROWS M_PLAN_RAW M_DONE_RAW M_HANDOFF_RAW M_FOLLOWUPS_RAW \
  M_STATUS M_REPO M_BRANCH M_WORKTREE M_TITLE M_CREATED M_CLOSED M_UPDATED \
  M_TASKFILE M_PARENT M_DEPS M_TAGS M_PLAN_CHECKED M_PLAN_TOTAL M_AGE_DAYS \
  M_BUCKET M_HANDOFF_SUMMARY M_FAMILY_ROOT STEM_PARENT STEM_ANCHOR \
  FAMILY_CHILDREN BUCKET_COUNT M_STAGE_SIG M_PR_URL M_SIZE M_ACCEPT

# --- R16: no tmux/gh/git shell-outs during collect -----------------------
assert_eq "R16: no tmux/gh/git calls during collect" "" "$(cat "$FIXTURE_TRACE" 2>/dev/null || true)"

# --- R21: 14d stale, 13d not ---------------------------------------------
assert_eq "R21: task touched 14d ago classifies stale" "stale" "${M_BUCKET[stale-task]:-}"
assert_eq "R21: task touched 13d ago does not classify stale" "active" "${M_BUCKET[border-task]:-}"
assert_eq "R21: task touched 2d ago is active" "active" "${M_BUCKET[active-task]:-}"

# --- R23: active+stale+shelved partition is disjoint and total agrees ---
total_files="$(find "$FIXTURE_TASKS" -maxdepth 1 -name '*.md' | wc -l)"
bucket_sum=$(( ${BUCKET_COUNT[active]:-0} + ${BUCKET_COUNT[stale]:-0} + ${BUCKET_COUNT[shelved]:-0} ))
assert_eq "R23: active+stale+shelved totals the store count" "$total_files" "$bucket_sum"
assert_eq "R23: planned task lands in shelved (not a 4th bucket)" "shelved" "${M_BUCKET[planned-task]:-}"
assert_eq "R23: paused task lands in shelved" "shelved" "${M_BUCKET[paused-task]:-}"

# --- fix(review) D3: cutover parity invariants ---------------------------
# U4's old-vs-new parity was a one-off manual check and the old collector is
# now deleted, so lock the model-level facts parity implied as standing
# assertions (drift now fails here instead of passing CI silently).
model_stem_count="${#M_STATUS[@]}"
assert_eq "Parity: collect emits exactly one model row per store file" "$total_files" "$model_stem_count"
missing_bucket=0
for s in "${!M_STATUS[@]}"; do [ -n "${M_BUCKET[$s]:-}" ] || missing_bucket=$((missing_bucket + 1)); done
assert_eq "Parity: every model stem carries a bucket (no half-populated row)" "0" "$missing_bucket"
dangling_root=0
for s in "${!M_FAMILY_ROOT[@]}"; do
  r="${M_FAMILY_ROOT[$s]}"; [ -n "${M_STATUS[$r]:-}" ] || dangling_root=$((dangling_root + 1))
done
assert_eq "Parity: every family root resolves to a real task in the model" "0" "$dangling_root"

# --- R18: Plan checklist ratio (0/n, n/n, no-Plan) -----------------------
assert_eq "Plan ratio: 2 checked of 3 total" "2" "${M_PLAN_CHECKED[plan-task]:-}"
assert_eq "Plan ratio: 2 checked of 3 total (total)" "3" "${M_PLAN_TOTAL[plan-task]:-}"
assert_eq "Plan ratio: no Plan section -> 0 checked" "0" "${M_PLAN_CHECKED[no-plan-task]:-}"
assert_eq "Plan ratio: no Plan section -> 0 total (renderer's em-dash sentinel signal)" "0" "${M_PLAN_TOTAL[no-plan-task]:-}"

# --- R16/R18: latest Handoff (last "### " block), empty when absent -----
assert_eq "Empty Handoffs -> empty raw text, not a crash" "" "${M_HANDOFF_RAW[no-handoff-task]:-}"
assert "Latest Handoff is the LAST ### block, not the first" "wb-save" "${M_HANDOFF_RAW[handoff-task]:-}"
assert_eq "Latest Handoff excludes the earlier block's body" "0" "$(printf '%s' "${M_HANDOFF_RAW[handoff-task]:-}" | grep -c 'Session paused' || true)"
assert "Handoff summary is the first non-blank line of the latest block" "wb-save" "${M_HANDOFF_SUMMARY[handoff-task]:-}"

# --- tags: bare/csv/list all parse to the same token set -----------------
bare_tokens="$(_wb_tags_parse "${M_TAGS[tags-bare]:-}" | sort | tr '\n' ',')"
csv_tokens="$(_wb_tags_parse "${M_TAGS[tags-csv]:-}" | sort | tr '\n' ',')"
list_tokens="$(_wb_tags_parse "${M_TAGS[tags-list]:-}" | sort | tr '\n' ',')"
assert_eq "tags: bare scalar parses to one token" "solo," "$bare_tokens"
assert_eq "tags: csv and list form parse to the same set" "a,b," "$csv_tokens"
assert_eq "tags: csv and list form agree with each other" "$csv_tokens" "$list_tokens"

# --- family: parent/child rollup -----------------------------------------
assert "Family: child appears in parent's children list" "child-b" "${FAMILY_CHILDREN[parent-a]:-}"
assert_eq "Family: child's family root resolves to the parent" "parent-a" "${M_FAMILY_ROOT[parent-a--child-b]:-}"
assert_eq "Family: root task's family root is itself" "parent-a" "${M_FAMILY_ROOT[parent-a]:-}"

# --- U5: Decisions/links raw-text round-trip through the collect pass ----
assert "M_DECISIONS_RAW captures the dated entry" "2026-01-02 . Chose the simple approach" "${M_DECISIONS_RAW[parent-a]:-}"
assert "M_DECISIONS_RAW captures the entry body" "Went with the direct fix" "${M_DECISIONS_RAW[parent-a]:-}"
assert_eq "M_DECISIONS_RAW is empty for a task with no Decisions section" "" "${M_DECISIONS_RAW[no-handoff-task]:-}"
assert "M_LINKS_RAW captures a doc path cited outside Decisions (Plan prose)" "docs/plans/2026-01-01-001-feat-parent-a-plan\.md" "${M_LINKS_RAW[parent-a]:-}"
# Links is the LAST SOH-joined field wb_board_v2_parse_record splits, so an
# empty value still picks up the enclosing here-string's own trailing
# newline (a pre-existing artifact of that split, not a U5 regression —
# every consumer already reads this line-by-line and skips blank lines, so
# it's inert in practice); assert on that functional emptiness rather than
# a byte-exact "".
no_links_trimmed="$(printf '%s' "${M_LINKS_RAW[no-handoff-task]:-}" | grep -c . || true)"
assert_eq "M_LINKS_RAW has no non-blank lines for a task with no cited doc paths" "0" "$no_links_trimmed"

# --- U2/R2: M_SIZE + M_ACCEPT (KTD7/KTD8) ---------------------------------
assert_eq "size: L + '## Acceptance criteria' heading -> M_SIZE=L" "L" "${M_SIZE[size-accept]:-}"
assert_eq "size: L + '## Acceptance criteria' heading -> M_ACCEPT=1" "1" "${M_ACCEPT[size-accept]:-}"

assert_eq "blank size: -> M_SIZE empty" "" "${M_SIZE[blank-size-no-accept]:-}"
assert_eq "no acceptance text -> M_ACCEPT=0" "0" "${M_ACCEPT[blank-size-no-accept]:-}"
# Trailing-empty-field hazard: size/accept are the LAST two fields of both
# TSV layers. An earlier field (PR URL, from the read-file layer) and
# M_TAGS/M_TITLE (from the collect-row layer) must still parse correctly
# after the insertion — a misaligned tab here would corrupt these, not just
# the new fields themselves.
assert_eq "trailing-field hazard: PR URL still parses after size/accept insertion" \
  "https://github.com/acme/repo/pull/42" "${M_PR_URL[blank-size-no-accept]:-}"
assert_eq "trailing-field hazard: M_TAGS still parses after size/accept insertion" \
  "solo" "${M_TAGS[blank-size-no-accept]:-}"
assert_eq "trailing-field hazard: M_TITLE still parses after size/accept insertion" \
  "Blank size no accept fixture" "${M_TITLE[blank-size-no-accept]:-}"

assert_eq "'Definition of Done' in a Follow-ups bullet (not Plan) -> M_ACCEPT=1" \
  "1" "${M_ACCEPT[dod-in-followups]:-}"

assert_eq "lowercase 'definition of done' matches -> M_ACCEPT=1" "1" "${M_ACCEPT[lowercase-dod]:-}"
assert_eq "the bare word 'acceptance' alone (no 'criteria') does not match" \
  "0" "${M_ACCEPT[bare-acceptance-word]:-}"

assert_eq "size: XS round-trips" "XS" "${M_SIZE[size-xs]:-}"

echo
if [ "$fail" = 0 ]; then
  echo "wb-board-model.test.sh: all assertions passed"
else
  echo "wb-board-model.test.sh: FAILURES"
fi
exit "$fail"
