#!/usr/bin/env bash
# Tests for U2 (`wb lint-sections` / `--machine` detection) and U3 (`--diff`
# / `--fix` merge writer) — see
# docs/plans/2026-09-23-001-fix-tasks-store-dedupe-headings-plan.md's U2/U3
# sections and KTD1-KTD7. Fixture shapes below are modeled on real
# duplicate/flush section bugs found (read-only grep) in ~/code/tasks: a
# content-bearing Follow-ups copy sitting above ## Decisions with an empty
# template copy below plus a near-miss "Follow-ups (superseded ...)"
# section (be--monorepo--club-half-projection-reporting.md), a flushed
# ## Handoffs immediately followed by a real duplicate holding a `wb
# breakdown` auto-entry (be--monorepo--customer-download-files.md), and a
# hand-edited ## Decisions sitting ABOVE ## Handoffs with an empty template
# copy below (be--monorepo--unify-single-session-read-auth.md).
#
# Fixtures are always ONE `printf -- '...'` call per file (never composed
# from two separate `$(...)` pieces concatenated together): command
# substitution strips ALL of a piece's OWN trailing newlines before
# concatenation, which silently eats exactly the blank-line-before-heading
# byte this whole feature cares about most. Confirmed live while writing
# this file — mirrors wb-append.test.sh's own fixture style for the same
# reason.
#
# Every scenario runs twice: once under this container's default `awk`
# (gawk) and once with `awk` PATH-shimmed to `/usr/bin/mawk` (KTD6 — the
# live `wb` runs on mawk 1.3.4; gawk-only constructs would pass here and
# break there). The shim FAILS LOUDLY if /usr/bin/mawk is missing rather
# than silently skipping the second pass.
#
# Run: bash scripts/.config/scripts/tmux/tests/wb-lint-sections.test.sh
set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WB="$SELF_DIR/wb.sh"
WB_LOCKS="$SELF_DIR/wb-locks.sh"

FIXTURE="$(mktemp -d -t wb-lint-sections-fixture.XXXXXX)"
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
assert_not() { # <desc> <regex> <actual>
  if printf '%s' "$3" | grep -qE "$2"; then
    echo "FAIL - $1"
    echo "       unexpected match: $2"
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

export XDG_STATE_HOME="$FIXTURE/state"
export HOME="$FIXTURE/home"
export CODE_DIR="$FIXTURE/code"
export TASKS_DIR="$FIXTURE/tasks"
mkdir -p "$XDG_STATE_HOME" "$HOME" "$CODE_DIR" "$TASKS_DIR"

# shellcheck disable=SC1090
source "$WB"
set +e   # wb.sh sets -e; this suite intentionally captures non-zero exits

# =============================================================================
# run_scenarios <tag> — every U2+U3 scenario, with fixture basenames suffixed
# by <tag> so the gawk pass and the mawk-shimmed pass never collide inside
# the same $TASKS_DIR.
# =============================================================================
run_scenarios() {
local tag="$1"
local awk_bin; awk_bin="$(command -v awk)"
echo "--- scenario pass: tag=$tag (awk -> $awk_bin) ---"

# ---- U2: clean TEMPLATE-shaped file -> no findings ----
local CLEAN="$TASKS_DIR/proj--clean-$tag.md"
printf -- '---\nstatus: doing\nrepo: proj\nbranch: clean-%s\nworktree: .worktrees/clean-%s\ntags: []\ncreated: 2026-07-01\nclosed:\n---\n# Title\n\n## Plan\n\n\n\n## Handoffs\n\n\n\n## Decisions\n\n\n\n## Done\n\n\n\n## Follow-ups\n' \
  "$tag" "$tag" > "$CLEAN"
out="$(_wb_lint_sections_findings "$CLEAN")"
assert_eq "$tag: clean TEMPLATE-shaped file has no findings" "" "$out"

# ---- U2: Follow-ups dup above Decisions + empty near-miss + empty
# template copy (real club-half-projection-reporting.md shape) ----
local BUG="$TASKS_DIR/proj--followups-superseded-$tag.md"
printf -- '---\nstatus: doing\nrepo: proj\nbranch: followups-superseded-%s\nworktree: .worktrees/followups-superseded-%s\ntags: []\ncreated: 2026-08-26\nclosed:\n---\n# Title\n\n## Plan\n\n\n\n## Handoffs\n\n\n\n## Follow-ups\n\n- worktree bootstrap note\n\n## Decisions\n\n\n\n## Done\n\n\n\n## Follow-ups (superseded — see ## Decisions)\n\n\n\n## Follow-ups\n\n' \
  "$tag" "$tag" > "$BUG"
findings="$(_wb_lint_sections_findings "$BUG")"
assert_eq "$tag: bug-signature file: exactly one finding line" 1 "$(printf '%s\n' "$findings" | grep -c .)"
assert "$tag: bug-signature file: dup Follow-ups copies=2 nonempty=1" '^dup	Follow-ups	2	1$' "$findings"
records="$(_wb_lint_sections_records "$BUG")"
assert_eq "$tag: bug-signature file: near-miss section is non-canonical (canonical=0)" 1 \
  "$(printf '%s\n' "$records" | grep -cE '^0	Follow-ups \(superseded')"

# ---- U2: flush Handoffs (Plan prose flush against it) + a real duplicate
# holding content (real customer-download-files.md shape) ----
local FLUSH="$TASKS_DIR/proj--flush-handoffs-$tag.md"
printf -- '---\nstatus: doing\nrepo: proj\nbranch: flush-handoffs-%s\nworktree: .worktrees/flush-handoffs-%s\ntags: []\ncreated: 2026-07-01\nclosed:\n---\n# Title\n\n## Plan\n\nSome plan prose ending right before the heading.\n## Handoffs\n\n\n\n## Handoffs\n\n### 2026-07-17 15:58 — wb breakdown (auto)\n\nFamily split applied.\n\n## Follow-ups\n' \
  "$tag" "$tag" > "$FLUSH"
findings="$(_wb_lint_sections_findings "$FLUSH")"
assert "$tag: flush file: dup Handoffs copies=2 nonempty=1" '^dup	Handoffs	2	1$' "$findings"
assert "$tag: flush file: flush Handoffs also reported" '^flush	Handoffs	2	1$' "$findings"
assert_not "$tag: flush file: Plan and Follow-ups (single, blank-preceded) are not findings" '(Plan|Follow-ups)' "$findings"

# ---- U2: hand-edited Decisions above Handoffs + empty template copy
# below (real unify-single-session-read-auth.md shape) ----
local DEC="$TASKS_DIR/proj--decisions-handedit-$tag.md"
printf -- '---\nstatus: planned\nrepo: proj\nbranch: decisions-handedit-%s\nworktree:\ntags: []\ncreated: 2026-08-21\nclosed:\n---\n# Title\n\n## Plan\n\nDeferred plan text.\n\n## Decisions\n\n### 2026-09-21 — reconciliation review\n\nHand-edited decision content.\n\n## Handoffs\n\n\n\n## Decisions\n\n\n\n## Done\n\n\n\n## Follow-ups\n' \
  "$tag" > "$DEC"
findings="$(_wb_lint_sections_findings "$DEC")"
assert_eq "$tag: hand-edited Decisions: exactly one finding" 1 "$(printf '%s\n' "$findings" | grep -c .)"
assert "$tag: hand-edited Decisions: dup copies=2 nonempty=1" '^dup	Decisions	2	1$' "$findings"

# ---- U2: a canonical heading inside a fenced code block is ignored ----
local FENCE="$TASKS_DIR/proj--fence-$tag.md"
printf -- '---\nstatus: doing\nrepo: proj\nbranch: fence-%s\nworktree: .worktrees/fence-%s\ntags: []\ncreated: 2026-07-01\nclosed:\n---\n# Title\n\n## Plan\n\nExample transcript:\n\n```\n## Decisions\n```\n\nEnd of example.\n\n## Handoffs\n\n\n\n## Decisions\n\n\n\n## Done\n\n\n\n## Follow-ups\n' \
  "$tag" "$tag" > "$FENCE"
findings="$(_wb_lint_sections_findings "$FENCE")"
assert_eq "$tag: fenced canonical heading: not counted, no findings" "" "$findings"
records="$(_wb_lint_sections_records "$FENCE")"
assert_eq "$tag: fenced canonical heading: only ONE real Decisions record" 1 \
  "$(printf '%s\n' "$records" | grep -cE '^1	Decisions	')"

# ---- U2: heading-shaped prose (no blank line before) is not a boundary ----
local PROSE="$TASKS_DIR/proj--prose-$tag.md"
printf -- '---\nstatus: doing\nrepo: proj\nbranch: prose-%s\nworktree: .worktrees/prose-%s\ntags: []\ncreated: 2026-07-01\nclosed:\n---\n# Title\n\n## Plan\n\nSome text quoting a heading inline:\n## Notes\nmore text right after.\n\n## Handoffs\n\n\n\n## Decisions\n\n\n\n## Done\n\n\n\n## Follow-ups\n' \
  "$tag" "$tag" > "$PROSE"
findings="$(_wb_lint_sections_findings "$PROSE")"
assert_eq "$tag: heading-shaped prose (no blank before): no findings" "" "$findings"
records="$(_wb_lint_sections_records "$PROSE")"
assert_not "$tag: heading-shaped prose: never becomes its own section record" '	Notes	' "$records"

# ---- U2: near-miss headings alongside real ones -> no dup, near-miss is
# non-canonical ("## Done when" vs real "## Done") ----
local DW="$TASKS_DIR/proj--done-when-$tag.md"
printf -- '---\nstatus: doing\nrepo: proj\nbranch: done-when-%s\nworktree: .worktrees/done-when-%s\ntags: []\ncreated: 2026-07-01\nclosed:\n---\n# Title\n\n## Plan\n\n\n\n## Handoffs\n\n\n\n## Decisions\n\n\n\n## Done\n\n- shipped thing\n\n## Done when\n\nCriteria for closing this out.\n\n## Follow-ups\n' \
  "$tag" "$tag" > "$DW"
findings="$(_wb_lint_sections_findings "$DW")"
assert_eq "$tag: near-miss 'Done when' alongside real Done: no findings" "" "$findings"
records="$(_wb_lint_sections_records "$DW")"
assert_eq "$tag: near-miss 'Done when': recorded as non-canonical" 1 \
  "$(printf '%s\n' "$records" | grep -cE '^0	Done when	')"

# ---- U2: --machine columns are stable; hash changes on a 1-byte edit ----
local FU="$TASKS_DIR/proj--fu-dup-$tag.md"
printf -- '---\nstatus: doing\nrepo: proj\nbranch: fu-dup-%s\nworktree: .worktrees/fu-dup-%s\ntags: []\ncreated: 2026-07-01\nclosed:\n---\n# Title\n\n## Plan\n\nSome plan text.\n\n## Handoffs\n\n\n\n## Follow-ups\n\n- upper follow-up one\n- upper follow-up two\n\n## Decisions\n\n\n\n## Done\n\n\n\n## Follow-ups\n\n- lower follow-up\n' \
  "$tag" "$tag" > "$FU"
machine_before="$(cmd_lint_sections "$FU" --machine 2>&1)"
assert_eq "$tag: --machine: exactly one row for the single dup" 1 "$(printf '%s\n' "$machine_before" | grep -c .)"
IFS=$'\t' read -r m_file m_kind m_section m_copies m_nonempty m_hash <<< "$machine_before"
assert_eq "$tag: --machine column 1 is the file path" "$FU" "$m_file"
assert_eq "$tag: --machine column 2 is the kind" "dup" "$m_kind"
assert_eq "$tag: --machine column 3 is the section name" "Follow-ups" "$m_section"
assert_eq "$tag: --machine column 4 is copies" "2" "$m_copies"
assert_eq "$tag: --machine column 5 is nonempty-copies" "2" "$m_nonempty"
assert "$tag: --machine column 6 is a 64-hex-char sha256" '^[0-9a-f]{64}$' "$m_hash"
printf ' ' >> "$FU"   # one extra byte, same lines/sections
machine_after="$(cmd_lint_sections "$FU" --machine 2>&1)"
hash_after="$(printf '%s' "$machine_after" | awk -F'\t' '{print $6}')"
assert_not "$tag: --machine hash changes on a one-byte edit" "^$m_hash\$" "$hash_after"

# ---- U2: no refs -> iterates the whole store (wb_task_files), skipping
# TEMPLATE.md ----
printf -- '---\nstatus: planned\nrepo:\nbranch:\nworktree:\nparent:\ntags: []\ncreated:\nclosed:\n---\n# Title\n\n## Plan\n\n\n\n## Handoffs\n\n\n\n## Follow-ups\n\n- should never be reported\n\n## Decisions\n\n\n\n## Done\n\n\n\n## Follow-ups\n' > "$TASKS_DIR/TEMPLATE.md"
whole_store="$(cmd_lint_sections --machine 2>&1)"
assert "$tag: no-refs run finds the flush-handoffs fixture" "proj--flush-handoffs-$tag\\.md" "$whole_store"
assert_not "$tag: no-refs run never reports TEMPLATE.md (wb_task_files skip list)" 'TEMPLATE\.md' "$whole_store"

# =============================================================================
# U3: --diff and --fix
# =============================================================================

# ---- --diff: read-only, always exit 0, shows the removed duplicate ----
diff_out="$(cmd_lint_sections "$FLUSH" --diff 2>&1)"; diff_rc=$?
assert_eq "$tag: --diff exits 0 even though files differ" 0 "$diff_rc"
assert "$tag: --diff shows the removed duplicate Handoffs heading" '^-## Handoffs$' "$diff_out"

# ---- --diff via a REAL subprocess, not the sourced function (P1
# regression): wb.sh runs under `set -euo pipefail`, and
# _wb_lint_sections_diff runs a bare `diff -u ...` (exit 1 = "files
# differ") inside a `while read` loop with nothing guarding it. That abort
# never shows up when this suite just sources cmd_lint_sections and calls
# it inside `$(...)` (this whole file runs with `set +e`, which a
# subshell forked from it also inherits) -- only a genuine `bash wb.sh
# lint-sections --diff` invocation, which starts fresh with wb.sh's own
# set -e intact, can catch it. Only run once (gawk pass); the double-pass
# structure adds nothing for a real-process invocation. Uses $FLUSH and
# $BUG, which are still unfixed at this point in the scenario order, so
# both differ from their merged form. ----
if [ "$tag" = "gawk" ]; then
  real_diff_out="$(bash "$WB" lint-sections --diff "$FLUSH" "$BUG" 2>&1)"; real_diff_rc=$?
  assert_eq "$tag: real CLI --diff over two differing files: exit 0" 0 "$real_diff_rc"
  assert "$tag: real CLI --diff: shows FLUSH's removed duplicate Handoffs heading" '^-## Handoffs$' "$real_diff_out"
  assert "$tag: real CLI --diff: FLUSH's diff header appears" "a/$(basename -- "$FLUSH")" "$real_diff_out"
  assert "$tag: real CLI --diff: BUG's diff header also appears (both files' diffs shown)" "a/$(basename -- "$BUG")" "$real_diff_out"
fi

# ---- --fix usage errors: no targets / bare path -> nothing written ----
out="$(cmd_lint_sections --fix 2>&1)"; rc=$?
assert_eq "$tag: --fix with no targets: exit 1" 1 "$rc"
assert "$tag: --fix with no targets: usage error, mentions no --all" 'no --all' "$out"
before="$(cat "$FLUSH")"
out="$(cmd_lint_sections --fix "$FLUSH" 2>&1)"; rc=$?
assert_eq "$tag: --fix with a bare path (no :hash): exit 1" 1 "$rc"
assert_eq "$tag: --fix with a bare path: file untouched" "$before" "$(cat "$FLUSH")"

# ---- --fix: flush Handoffs file -> one Handoffs, blank before it,
# holding the real entry ----
hash="$(sha256sum "$FLUSH" | awk '{print $1}')"
before_pre="$(sed -n '1,10p' "$FLUSH")"   # frontmatter+title, byte-identical check
out="$(cmd_lint_sections --fix "$FLUSH:$hash" 2>&1)"; rc=$?
assert_eq "$tag: --fix flush Handoffs: exit 0" 0 "$rc"
assert_eq "$tag: --fix flush Handoffs: exactly one ## Handoffs" 1 "$(grep -c '^## Handoffs$' "$FLUSH")"
assert "$tag: --fix flush Handoffs: real entry survives" 'wb breakdown \(auto\)' "$(cat "$FLUSH")"
h_line="$(grep -n '^## Handoffs$' "$FLUSH" | cut -d: -f1)"
prev_line="$(sed -n "$((h_line - 1))p" "$FLUSH")"
assert_eq "$tag: --fix flush Handoffs: now preceded by a blank line" "" "$prev_line"
assert_eq "$tag: --fix flush Handoffs: preamble byte-identical" "$before_pre" "$(sed -n '1,10p' "$FLUSH")"
findings_after="$(_wb_lint_sections_findings "$FLUSH")"
assert_eq "$tag: --fix flush Handoffs: re-lint finds nothing" "" "$findings_after"

# second --fix with the NEW current hash: no findings, untouched, rc 0
hash2="$(sha256sum "$FLUSH" | awk '{print $1}')"
out="$(cmd_lint_sections --fix "$FLUSH:$hash2" 2>&1)"; rc=$?
assert_eq "$tag: second --fix (idempotent, R8): exit 0" 0 "$rc"
assert "$tag: second --fix: reports no findings, untouched" 'has no findings' "$out"

# ---- --fix: file with NO findings passed -> untouched, exit 0 ----
clean_hash="$(sha256sum "$CLEAN" | awk '{print $1}')"
clean_before="$(cat "$CLEAN")"
out="$(cmd_lint_sections --fix "$CLEAN:$clean_hash" 2>&1)"; rc=$?
assert_eq "$tag: --fix on a file with no findings: exit 0" 0 "$rc"
assert_eq "$tag: --fix on a file with no findings: untouched" "$clean_before" "$(cat "$CLEAN")"

# ---- --fix: Follow-ups dup, BOTH copies non-empty -> upper's lines then
# lower's, in the canonical slot ----
hash="$(sha256sum "$FU" | awk '{print $1}')"
out="$(cmd_lint_sections --fix "$FU:$hash" 2>&1)"; rc=$?
assert_eq "$tag: --fix both-nonempty Follow-ups: exit 0" 0 "$rc"
assert_eq "$tag: --fix both-nonempty Follow-ups: exactly one heading" 1 "$(grep -c '^## Follow-ups$' "$FU")"
l_upper="$(grep -nF 'upper follow-up one' "$FU" | cut -d: -f1)"
l_lower="$(grep -nF 'lower follow-up' "$FU" | cut -d: -f1)"
if [ -n "$l_upper" ] && [ -n "$l_lower" ] && [ "$l_upper" -lt "$l_lower" ]; then
  echo "ok   - $tag: --fix both-nonempty Follow-ups: upper copy's lines precede lower's"
else
  echo "FAIL - $tag: --fix both-nonempty Follow-ups: wrong order (upper=$l_upper lower=$l_lower)"; fail=1
fi

# ---- --fix: hand-edited Decisions -> one Decisions AFTER Handoffs,
# content kept ----
hash="$(sha256sum "$DEC" | awk '{print $1}')"
out="$(cmd_lint_sections --fix "$DEC:$hash" 2>&1)"; rc=$?
assert_eq "$tag: --fix hand-edited Decisions: exit 0" 0 "$rc"
assert_eq "$tag: --fix hand-edited Decisions: exactly one heading" 1 "$(grep -c '^## Decisions$' "$DEC")"
assert "$tag: --fix hand-edited Decisions: content kept" 'Hand-edited decision content\.' "$(cat "$DEC")"
h_line="$(grep -n '^## Handoffs$' "$DEC" | cut -d: -f1)"
d_line="$(grep -n '^## Decisions$' "$DEC" | cut -d: -f1)"
if [ -n "$h_line" ] && [ -n "$d_line" ] && [ "$h_line" -lt "$d_line" ]; then
  echo "ok   - $tag: --fix hand-edited Decisions: Decisions now lands AFTER Handoffs"
else
  echo "FAIL - $tag: --fix hand-edited Decisions: wrong order (handoffs=$h_line decisions=$d_line)"; fail=1
fi

# ---- --fix: ## Sweep after Follow-ups stays there, unchanged, when some
# OTHER finding (dup Handoffs) triggers the rewrite ----
local SW="$TASKS_DIR/proj--sweep-$tag.md"
printf -- '---\nstatus: doing\nrepo: proj\nbranch: sweep-%s\nworktree: .worktrees/sweep-%s\ntags: []\ncreated: 2026-07-01\nclosed:\n---\n# Title\n\n## Plan\n\n\n\n## Handoffs\n\n\n\n## Handoffs\n\n- second handoffs entry\n\n## Decisions\n\n\n\n## Done\n\n\n\n## Follow-ups\n\n- a follow-up\n\n## Sweep (gitignored, not for review)\n\n- leftover file note\n' \
  "$tag" "$tag" > "$SW"
hash="$(sha256sum "$SW" | awk '{print $1}')"
out="$(cmd_lint_sections --fix "$SW:$hash" 2>&1)"; rc=$?
assert_eq "$tag: --fix Sweep-after-Follow-ups: exit 0" 0 "$rc"
fu_line="$(grep -n '^## Follow-ups$' "$SW" | cut -d: -f1)"
sw_line="$(grep -n '^## Sweep' "$SW" | cut -d: -f1)"
if [ -n "$fu_line" ] && [ -n "$sw_line" ] && [ "$fu_line" -lt "$sw_line" ]; then
  echo "ok   - $tag: --fix Sweep-after-Follow-ups: Sweep still comes after Follow-ups"
else
  echo "FAIL - $tag: --fix Sweep-after-Follow-ups: wrong order (followups=$fu_line sweep=$sw_line)"; fail=1
fi
assert "$tag: --fix Sweep-after-Follow-ups: Sweep content unchanged" 'leftover file note' "$(cat "$SW")"

# ---- --fix: bug-signature file (dup Follow-ups + near-miss superseded) ->
# only the exact copies merge, the superseded section is untouched ----
hash="$(sha256sum "$BUG" | awk '{print $1}')"
out="$(cmd_lint_sections --fix "$BUG:$hash" 2>&1)"; rc=$?
assert_eq "$tag: --fix bug-signature file: exit 0" 0 "$rc"
assert_eq "$tag: --fix bug-signature file: exactly one ## Follow-ups" 1 "$(grep -c '^## Follow-ups$' "$BUG")"
assert_eq "$tag: --fix bug-signature file: superseded section still present, untouched" 1 \
  "$(grep -cF 'Follow-ups (superseded — see ## Decisions)' "$BUG")"
assert "$tag: --fix bug-signature file: real content survives" 'worktree bootstrap note' "$(cat "$BUG")"

# ---- --fix: stale hash -> skipped, message, file untouched, nonzero ----
local STALE="$TASKS_DIR/proj--stale-$tag.md"
printf -- '---\nstatus: doing\nrepo: proj\nbranch: stale-%s\nworktree: .worktrees/stale-%s\ntags: []\ncreated: 2026-07-01\nclosed:\n---\n# Title\n\n## Follow-ups\n\n- one\n\n## Follow-ups\n\n- two\n' \
  "$tag" "$tag" > "$STALE"
oldhash="$(sha256sum "$STALE" | awk '{print $1}')"
printf '\n<!-- concurrent edit -->\n' >> "$STALE"
stale_before="$(cat "$STALE")"
out="$(cmd_lint_sections --fix "$STALE:$oldhash" 2>&1)"; rc=$?
assert_eq "$tag: --fix stale hash: exit 1" 1 "$rc"
assert "$tag: --fix stale hash: message names the file" "proj--stale-$tag\\.md" "$out"
assert "$tag: --fix stale hash: message says changed since review" 'changed since review' "$out"
assert_eq "$tag: --fix stale hash: file untouched" "$stale_before" "$(cat "$STALE")"

# ---- --fix: self-check refuses a write that would drop a line. Stubs
# _wb_lint_sections_merge with `declare -f` saved/restored around the call
# (never re-sources wb.sh here -- that would re-run its own `set -e` and
# abort the rest of this suite, confirmed live while writing this test). ----
local SC="$TASKS_DIR/proj--selfcheck-$tag.md"
printf -- '---\nstatus: doing\nrepo: proj\nbranch: selfcheck-%s\nworktree: .worktrees/selfcheck-%s\ntags: []\ncreated: 2026-07-01\nclosed:\n---\n# Title\n\n## Follow-ups\n\n- one\n\n## Follow-ups\n\n- two\n' \
  "$tag" "$tag" > "$SC"
sc_hash="$(sha256sum "$SC" | awk '{print $1}')"
sc_before="$(cat "$SC")"
local orig_merge_def; orig_merge_def="$(declare -f _wb_lint_sections_merge)"
_wb_lint_sections_merge() {
  printf '%s\n' "## Follow-ups" "" "- one"   # deliberately drops "- two"
}
out="$(_wb_lint_sections_fix_one "$SC" "$sc_hash" 2>&1)"; rc=$?
eval "$orig_merge_def"
assert_eq "$tag: self-check trip: fix_one returns non-zero" 1 "$rc"
assert "$tag: self-check trip: message names the refusal" 'content self-check' "$out"
assert_eq "$tag: self-check trip: file untouched" "$sc_before" "$(cat "$SC")"

# ---- --fix under a non-C locale (P1 regression): the self-check builds
# its inputs with LC_ALL=C sort/awk but ran the actual `comm -23`
# comparison in the calling shell's locale -- under en_US.UTF-8 that
# `comm` call re-collates lines that were only sorted for C and mis-pairs
# them, so the self-check refused nearly every real merge. Fixture
# mirrors the shapes that actually trip locale-dependent sort: an
# indented nested bullet, a punctuation-leading (quote/paren) line,
# alongside a plain duplicated section. Fails loudly (not skip) if the
# image lacks en_US.utf8, same convention as the mawk-shim check below. ----
if ! locale -a 2>/dev/null | grep -qiE '^en_US\.utf-?8$'; then
  echo "FAIL - $tag: non-C locale self-check: en_US.utf8 not installed -- cannot verify the LC_ALL=C comm fix"
  fail=1
else
  local LOC="$TASKS_DIR/proj--locale-merge-$tag.md"
  printf -- '---\nstatus: doing\nrepo: proj\nbranch: locale-merge-%s\nworktree: .worktrees/locale-merge-%s\ntags: []\ncreated: 2026-07-01\nclosed:\n---\n# Title\n\n## Follow-ups\n\n- item\n  - nested\n- "quoted" thing\n- (parenthetical) note\n\n## Follow-ups\n\n- another item\n' \
    "$tag" "$tag" > "$LOC"
  local loc_hash; loc_hash="$(sha256sum "$LOC" | awk '{print $1}')"
  out="$(LC_ALL=en_US.UTF-8 cmd_lint_sections --fix "$LOC:$loc_hash" 2>&1)"; rc=$?
  assert_eq "$tag: non-C locale self-check: --fix exits 0 (merge NOT refused)" 0 "$rc"
  assert_not "$tag: non-C locale self-check: no refusal message" 'content self-check' "$out"
  assert_eq "$tag: non-C locale self-check: exactly one ## Follow-ups" 1 "$(grep -c '^## Follow-ups$' "$LOC")"
  assert "$tag: non-C locale self-check: nested bullet survives" '  - nested' "$(cat "$LOC")"
  assert "$tag: non-C locale self-check: punctuation-leading line survives" '"quoted" thing' "$(cat "$LOC")"
  assert "$tag: non-C locale self-check: second copy's content survives" 'another item' "$(cat "$LOC")"
fi

# ---- --fix: lock held by a background holder -> never writes unlocked
# (spawn_holder pattern from wb-lock-integration.test.sh / wb-append.test.sh,
# trimmed to what this file needs) ----
local LOCKED="$TASKS_DIR/proj--lockheld-$tag.md"
printf -- '---\nstatus: doing\nrepo: proj\nbranch: lockheld-%s\nworktree: .worktrees/lockheld-%s\ntags: []\ncreated: 2026-07-01\nclosed:\n---\n# Title\n\n## Follow-ups\n\n- one\n\n## Follow-ups\n\n- two\n' \
  "$tag" "$tag" > "$LOCKED"
locked_hash="$(sha256sum "$LOCKED" | awk '{print $1}')"
locked_before="$(cat "$LOCKED")"

local HOLDER_LOG="$FIXTURE/holder-$tag.log"
local HOLDER_SCRIPT="$FIXTURE/holder-$tag.sh"
cat > "$HOLDER_SCRIPT" <<HOLDEREOF
#!/usr/bin/env bash
exec >>"$HOLDER_LOG" 2>&1
unset TMUX TMUX_PANE
source "$WB_LOCKS"
wb_task_lock_acquire "$LOCKED" || exit 1
sleep 2
HOLDEREOF
chmod +x "$HOLDER_SCRIPT"
( exec bash "$HOLDER_SCRIPT" ) &
local HPID=$!
HOLDER_PIDS+=("$HPID")
local LOCKFILE; LOCKFILE="$(_wb_lock_path_for "$LOCKED")"
local waited=0
while [ "$waited" -lt 30 ]; do
  [ "$(_wb_lock_field "$LOCKFILE" pid)" = "$HPID" ] && break
  sleep 0.1; waited=$((waited + 1))
done

out="$(cmd_lint_sections --fix "$LOCKED:$locked_hash" 2>&1)"; rc=$?
assert_eq "$tag: --fix contended: non-zero exit, never interleaves" 0 "$([ "$rc" -ne 0 ] && echo 0 || echo 1)"
assert_eq "$tag: --fix contended: file untouched while locked" "$locked_before" "$(cat "$LOCKED")"

wait "$HPID" 2>/dev/null

out="$(cmd_lint_sections --fix "$LOCKED:$locked_hash" 2>&1)"; rc=$?
assert_eq "$tag: --fix after lock release: exit 0" 0 "$rc"
assert_eq "$tag: --fix after lock release: exactly one heading" 1 "$(grep -c '^## Follow-ups$' "$LOCKED")"

# ---- --fix: write failure (P1 regression) -- `mv` failing after the
# `printf ... > tmp && mv tmp file` write used to fall straight through to
# the unconditional "merged" success message and `return 0`. Stub `mv` as
# a shell function (this suite sources wb.sh into this same shell, so a
# function named `mv` shadows the command for every call in it) and unset
# it again right after so nothing downstream is affected. Only run once
# (gawk pass) -- this is exercising the write-failure branch itself, not
# anything awk-flavor-dependent. ----
if [ "$tag" = "gawk" ]; then
  local WF="$TASKS_DIR/proj--writefail-$tag.md"
  printf -- '---\nstatus: doing\nrepo: proj\nbranch: writefail-%s\nworktree: .worktrees/writefail-%s\ntags: []\ncreated: 2026-07-01\nclosed:\n---\n# Title\n\n## Follow-ups\n\n- one\n\n## Follow-ups\n\n- two\n' \
    "$tag" "$tag" > "$WF"
  local wf_hash wf_before; wf_hash="$(sha256sum "$WF" | awk '{print $1}')"
  wf_before="$(cat "$WF")"

  mv() { return 1; }
  out="$(_wb_lint_sections_fix_one "$WF" "$wf_hash" 2>&1)"; rc=$?
  unset -f mv

  assert_eq "$tag: write failure: fix_one returns non-zero" 1 "$rc"
  assert "$tag: write failure: message says write failed" 'write failed' "$out"
  assert "$tag: write failure: message names the file" "$(basename -- "$WF")" "$out"
  assert_eq "$tag: write failure: file byte-identical to before" "$wf_before" "$(cat "$WF")"
  shopt -s nullglob
  local -a wf_tmp_leftover=("$WF".tmp.*)
  shopt -u nullglob
  assert_eq "$tag: write failure: no leftover tmp file" 0 "${#wf_tmp_leftover[@]}"

  # lock released -> a following --fix on the same file succeeds
  out="$(cmd_lint_sections --fix "$WF:$wf_hash" 2>&1)"; rc=$?
  assert_eq "$tag: write failure: lock was released, following --fix succeeds" 0 "$rc"
  assert_eq "$tag: write failure: following --fix actually merged" 1 "$(grep -c '^## Follow-ups$' "$WF")"
fi

# ---- --fix: multiple targets, one with a stale hash -> the valid target
# is merged, the stale one is skipped with its own message naming the
# file, and the overall exit is nonzero (R7's per-target independence). ----
local M1="$TASKS_DIR/proj--multi1-$tag.md"
printf -- '---\nstatus: doing\nrepo: proj\nbranch: multi1-%s\nworktree: .worktrees/multi1-%s\ntags: []\ncreated: 2026-07-01\nclosed:\n---\n# Title\n\n## Follow-ups\n\n- one\n\n## Follow-ups\n\n- two\n' \
  "$tag" "$tag" > "$M1"
local M2="$TASKS_DIR/proj--multi2-$tag.md"
printf -- '---\nstatus: doing\nrepo: proj\nbranch: multi2-%s\nworktree: .worktrees/multi2-%s\ntags: []\ncreated: 2026-07-01\nclosed:\n---\n# Title\n\n## Handoffs\n\n\n\n## Handoffs\n\n- second\n' \
  "$tag" "$tag" > "$M2"
local m1_hash m2_hash m2_before
m1_hash="$(sha256sum "$M1" | awk '{print $1}')"
m2_hash="$(sha256sum "$M2" | awk '{print $1}')"
printf '\n<!-- concurrent edit -->\n' >> "$M2"   # invalidate M2's reviewed hash
m2_before="$(cat "$M2")"
out="$(cmd_lint_sections --fix "$M1:$m1_hash" "$M2:$m2_hash" 2>&1)"; rc=$?
assert_eq "$tag: multi-target (one stale): overall exit is nonzero" 0 "$([ "$rc" -ne 0 ] && echo 0 || echo 1)"
assert_eq "$tag: multi-target (one stale): the valid target still merged" 1 "$(grep -c '^## Follow-ups$' "$M1")"
assert "$tag: multi-target (one stale): stale message names M2" "proj--multi2-$tag\\.md" "$out"
assert "$tag: multi-target (one stale): stale message says changed since review" 'changed since review' "$out"
assert_eq "$tag: multi-target (one stale): M2 left untouched" "$m2_before" "$(cat "$M2")"

# ---- --fix: one malformed target (bare path, no :hash) among otherwise
# valid ones -> whole call is a usage error, NOTHING written to any
# target (targets are format-validated before anything is locked). ----
local M4="$TASKS_DIR/proj--multi4-$tag.md"
printf -- '---\nstatus: doing\nrepo: proj\nbranch: multi4-%s\nworktree: .worktrees/multi4-%s\ntags: []\ncreated: 2026-07-01\nclosed:\n---\n# Title\n\n## Done\n\n\n\n## Done\n\n- shipped\n' \
  "$tag" "$tag" > "$M4"
local m4_hash m4_before
m4_hash="$(sha256sum "$M4" | awk '{print $1}')"
m4_before="$(cat "$M4")"
out="$(cmd_lint_sections --fix "$M4:$m4_hash" "$M4" 2>&1)"; rc=$?
assert_eq "$tag: multi-target malformed: exit 1" 1 "$rc"
assert "$tag: multi-target malformed: usage error, format-validated before anything writes" 'is not <file>:<hash>' "$out"
assert "$tag: multi-target malformed: message names the malformed target" "$(basename -- "$M4")" "$out"
assert_eq "$tag: multi-target malformed: valid target left untouched too" "$m4_before" "$(cat "$M4")"

# ---- unknown flag -> exit 1, names the flag ----
out="$(cmd_lint_sections --bogus 2>&1)"; rc=$?
assert_eq "$tag: unknown flag: exit 1" 1 "$rc"
assert "$tag: unknown flag: message" "unknown flag '--bogus'" "$out"

# ---- --fix: a duplicate section where BOTH copies are entirely blank ->
# merge collapses to exactly one bare heading, correct blank-line layout
# on both sides, idempotent on a second run. ----
local BLANK="$TASKS_DIR/proj--blank-handoffs-$tag.md"
printf -- '---\nstatus: doing\nrepo: proj\nbranch: blank-handoffs-%s\nworktree: .worktrees/blank-handoffs-%s\ntags: []\ncreated: 2026-07-01\nclosed:\n---\n# Title\n\n## Plan\n\n\n\n## Handoffs\n\n\n\n## Handoffs\n\n\n\n## Decisions\n\n\n\n## Done\n\n\n\n## Follow-ups\n' \
  "$tag" "$tag" > "$BLANK"
findings="$(_wb_lint_sections_findings "$BLANK")"
assert "$tag: all-blank duplicate Handoffs: dup copies=2 nonempty=0" $'^dup\tHandoffs\t2\t0$' "$findings"
local blank_hash; blank_hash="$(sha256sum "$BLANK" | awk '{print $1}')"
out="$(cmd_lint_sections --fix "$BLANK:$blank_hash" 2>&1)"; rc=$?
assert_eq "$tag: all-blank duplicate: fix exit 0" 0 "$rc"
assert_eq "$tag: all-blank duplicate: exactly one ## Handoffs" 1 "$(grep -c '^## Handoffs$' "$BLANK")"
local blank_h_line blank_prev blank_next
blank_h_line="$(grep -n '^## Handoffs$' "$BLANK" | cut -d: -f1)"
blank_prev="$(sed -n "$((blank_h_line - 1))p" "$BLANK")"
blank_next="$(sed -n "$((blank_h_line + 1))p" "$BLANK")"
assert_eq "$tag: all-blank duplicate: preceded by exactly one blank line" "" "$blank_prev"
assert_eq "$tag: all-blank duplicate: followed by exactly one blank line" "" "$blank_next"
local blank_hash2; blank_hash2="$(sha256sum "$BLANK" | awk '{print $1}')"
out="$(cmd_lint_sections --fix "$BLANK:$blank_hash2" 2>&1)"; rc=$?
assert_eq "$tag: all-blank duplicate: idempotent second run exit 0" 0 "$rc"
assert "$tag: all-blank duplicate: idempotent second run reports no findings" 'has no findings' "$out"

# ---- a non-canonical section anchored to the PREAMBLE (appears before
# the first canonical heading), alongside a duplicate canonical section
# later in the same file -> after --fix, the preamble-anchored section
# stays directly after the preamble and before the first canonical
# heading -- the merge must not relocate it just because SOME other
# section in the file needed merging. ----
local NC="$TASKS_DIR/proj--preamble-notes-$tag.md"
printf -- '---\nstatus: doing\nrepo: proj\nbranch: preamble-notes-%s\nworktree: .worktrees/preamble-notes-%s\ntags: []\ncreated: 2026-07-01\nclosed:\n---\n# Title\n\n## Notes\n\nSome notes content.\n\n## Plan\n\nPlan text.\n\n## Plan\n\nMore plan text (dup).\n\n## Handoffs\n\n\n\n## Decisions\n\n\n\n## Done\n\n\n\n## Follow-ups\n' \
  "$tag" "$tag" > "$NC"
findings="$(_wb_lint_sections_findings "$NC")"
assert "$tag: preamble Notes: dup Plan copies=2 nonempty=2" $'^dup\tPlan\t2\t2$' "$findings"
records="$(_wb_lint_sections_records "$NC")"
assert_eq "$tag: preamble Notes: Notes recorded as non-canonical" 1 \
  "$(printf '%s\n' "$records" | grep -cE $'^0\tNotes\t')"
local nc_hash; nc_hash="$(sha256sum "$NC" | awk '{print $1}')"
out="$(cmd_lint_sections --fix "$NC:$nc_hash" 2>&1)"; rc=$?
assert_eq "$tag: preamble Notes: fix exit 0" 0 "$rc"
assert_eq "$tag: preamble Notes: exactly one ## Plan" 1 "$(grep -c '^## Plan$' "$NC")"
local nc_title_line nc_notes_line nc_plan_line
nc_title_line="$(grep -n '^# Title$' "$NC" | cut -d: -f1)"
nc_notes_line="$(grep -n '^## Notes$' "$NC" | cut -d: -f1)"
nc_plan_line="$(grep -n '^## Plan$' "$NC" | cut -d: -f1)"
if [ -n "$nc_title_line" ] && [ -n "$nc_notes_line" ] && [ -n "$nc_plan_line" ] \
  && [ "$nc_title_line" -lt "$nc_notes_line" ] && [ "$nc_notes_line" -lt "$nc_plan_line" ]; then
  echo "ok   - $tag: preamble Notes: Notes stays directly after the preamble, before Plan"
else
  echo "FAIL - $tag: preamble Notes: wrong order (title=$nc_title_line notes=$nc_notes_line plan=$nc_plan_line)"; fail=1
fi
local nc_notes_prev nc_plan_prev
nc_notes_prev="$(sed -n "$((nc_notes_line - 1))p" "$NC")"
nc_plan_prev="$(sed -n "$((nc_plan_line - 1))p" "$NC")"
assert_eq "$tag: preamble Notes: blank line before Notes" "" "$nc_notes_prev"
assert_eq "$tag: preamble Notes: blank line before merged Plan" "" "$nc_plan_prev"
assert "$tag: preamble Notes: Notes content survives" 'Some notes content\.' "$(cat "$NC")"
assert "$tag: preamble Notes: both Plan copies merged" 'More plan text \(dup\)\.' "$(cat "$NC")"
}

# =============================================================================
# Pass 1: default (gawk) PATH.
# =============================================================================
run_scenarios gawk

# =============================================================================
# Pass 2: PATH-shimmed so `awk` resolves to /usr/bin/mawk (KTD6). Fails
# loudly — never silently skips — if the sandbox image lost mawk.
# =============================================================================
if [ ! -x /usr/bin/mawk ]; then
  echo "FAIL - mawk shim: /usr/bin/mawk not found — cannot verify mawk 1.3.4 compatibility"
  fail=1
else
  MAWK_SHIM_DIR="$(mktemp -d -t wb-lint-sections-mawk-shim.XXXXXX)"
  ln -s /usr/bin/mawk "$MAWK_SHIM_DIR/awk"
  PATH="$MAWK_SHIM_DIR:$PATH"
  if [ "$(command -v awk)" != "$MAWK_SHIM_DIR/awk" ]; then
    echo "FAIL - mawk shim: PATH shim did not take effect (awk resolved to $(command -v awk))"
    fail=1
  else
    run_scenarios mawk
  fi
  rm -rf "$MAWK_SHIM_DIR"
fi

[ "$fail" -eq 0 ] && echo "ALL PASS" || echo "FAILURES"
exit "$fail"
