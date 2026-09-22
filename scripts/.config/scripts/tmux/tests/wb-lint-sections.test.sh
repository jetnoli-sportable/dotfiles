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
