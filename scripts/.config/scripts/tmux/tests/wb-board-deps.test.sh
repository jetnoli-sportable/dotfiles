#!/usr/bin/env bash
# Unit tests for the dependency-graph + escaping helpers in wb-board.sh
# that outlived U4's cutover: wb_board_html_escape, wb_board_parse_deps,
# wb_board_normalize_loop, wb_board_deps_validate, wb_board_deps_cycles,
# wb_board_deps_blocking. All still load-bearing for wb_board_render_v2's
# Roadmap readiness cues (R19) even though the old wb_board_render_html
# they were originally written alongside is gone.
#
# Extracted from wb-board-html.test.sh (U4) rather than deleted with it:
# that file's ~800 other assertions tested wb_board_render_html's own HTML
# structure (panels/tabs/filters/cards) and are gone for good with it, but
# these are pure nameref-array unit tests with no dependency on the old
# renderer (same pattern wb_tsv_split's own tests use) — losing them would
# have silently dropped coverage for functions this repo still ships.
#
# Run: bash scripts/.config/scripts/tmux/tests/wb-board-deps.test.sh
set -uo pipefail

WB="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/wb.sh"
TASKS_DIR="$(mktemp -d -t wb-board-deps-tasks.XXXXXX)"
trap 'rm -rf "$TASKS_DIR"' EXIT
export TASKS_DIR
source "$WB"

fail=0
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
assert_empty() { # <desc> <actual> — grep's own '^$' never matches a truly
  # empty string (zero lines, not one empty line).
  if [ -z "$2" ]; then
    echo "ok   - $1"
  else
    echo "FAIL - $1 (expected empty, got: $2)"
    fail=1
  fi
}

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

echo
if [ "$fail" = 0 ]; then
  echo "wb-board-deps.test.sh: all assertions passed"
else
  echo "wb-board-deps.test.sh: FAILURES"
fi
exit "$fail"
