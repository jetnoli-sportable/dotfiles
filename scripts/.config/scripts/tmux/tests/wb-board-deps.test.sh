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

# ===========================================================================
# wb_board_deps_layer (U3) — layering, critical path, startable-now, START/
# END tagging, for an arbitrary node set (a family's direct children). All
# inputs below are STEM-keyed (KTD2), matching render_v2's real DEPS_OF/
# CYCLE_MEMBER/UNMET_COUNT (DG_KEY is an identity map there — see the D4
# comment above wb_board_render_v2's dependency-graph block).
# ===========================================================================

# --- chain A->B->C (all M, planned): layers 0/1/2, critical path A,B,C,
# remaining doubled 12 (3*M=3*4), only A startable (B/C carry an unmet
# blocker), A tagged START, C tagged END, B untagged -----------------------
declare -a DL1_NODES=(A B C)
declare -A DL1_DEPS=([B]=$'A\n' [C]=$'B\n')
declare -A DL1_CYCLE=()
declare -A DL1_UNMET=([B]=1 [C]=1)
declare -A DL1_STATUS=([A]=planned [B]=planned [C]=planned)
declare -A DL1_SIZE=([A]=M [B]=M [C]=M)
declare -A DL1_LAYER=() DL1_ORDER=() DL1_CRIT=() DL1_STARTABLE=() DL1_EXTBLK=() DL1_TAG=()
declare -a DL1_EDGES=() DL1_BACKEDGES=() DL1_CRITPATH=()
DL1_REMAIN=0; DL1_MAXLAYER=-1
wb_board_deps_layer DL1_NODES DL1_DEPS DL1_CYCLE DL1_UNMET DL1_STATUS DL1_SIZE \
  DL1_LAYER DL1_ORDER DL1_CRIT DL1_STARTABLE DL1_EXTBLK DL1_TAG \
  DL1_EDGES DL1_BACKEDGES DL1_CRITPATH DL1_REMAIN DL1_MAXLAYER
assert "deps_layer: chain — A layer 0" '^0$' "${DL1_LAYER[A]:-}"
assert "deps_layer: chain — B layer 1" '^1$' "${DL1_LAYER[B]:-}"
assert "deps_layer: chain — C layer 2" '^2$' "${DL1_LAYER[C]:-}"
assert "deps_layer: chain — critical path is A,B,C" '^A B C$' "${DL1_CRITPATH[*]}"
assert "deps_layer: chain — remaining is doubled 12" '^12$' "$DL1_REMAIN"
assert "deps_layer: chain — only A startable" '^1$' "${DL1_STARTABLE[A]:-}"
assert_empty "deps_layer: chain — B not startable (unmet blocker)" "$([ "${DL1_STARTABLE[B]:-0}" = 0 ] || echo bad)"
assert_empty "deps_layer: chain — C not startable (unmet blocker)" "$([ "${DL1_STARTABLE[C]:-0}" = 0 ] || echo bad)"
assert "deps_layer: chain — A tagged START" '^START$' "${DL1_TAG[A]:-}"
assert "deps_layer: chain — C tagged END" '^END$' "${DL1_TAG[C]:-}"
assert_empty "deps_layer: chain — B untagged (mid-chain)" "${DL1_TAG[B]:-}"

# --- diamond A->{B,C}->D, B=XL C=S: critical path goes through the heavier
# branch (A,B,D); C shares B's layer but is not critical ---------------------
declare -a DL2_NODES=(A B C D)
declare -A DL2_DEPS=([B]=$'A\n' [C]=$'A\n' [D]=$'B\nC\n')
declare -A DL2_CYCLE=()
declare -A DL2_UNMET=()
declare -A DL2_STATUS=([A]=planned [B]=planned [C]=planned [D]=planned)
declare -A DL2_SIZE=([A]=S [B]=XL [C]=S [D]=M)
declare -A DL2_LAYER=() DL2_ORDER=() DL2_CRIT=() DL2_STARTABLE=() DL2_EXTBLK=() DL2_TAG=()
declare -a DL2_EDGES=() DL2_BACKEDGES=() DL2_CRITPATH=()
DL2_REMAIN=0; DL2_MAXLAYER=-1
wb_board_deps_layer DL2_NODES DL2_DEPS DL2_CYCLE DL2_UNMET DL2_STATUS DL2_SIZE \
  DL2_LAYER DL2_ORDER DL2_CRIT DL2_STARTABLE DL2_EXTBLK DL2_TAG \
  DL2_EDGES DL2_BACKEDGES DL2_CRITPATH DL2_REMAIN DL2_MAXLAYER
assert "deps_layer: diamond — B and C share layer 1" '^1 1$' "${DL2_LAYER[B]:-} ${DL2_LAYER[C]:-}"
assert "deps_layer: diamond — critical path is A,B,D (heavier branch)" '^A B D$' "${DL2_CRITPATH[*]}"
assert_empty "deps_layer: diamond — C is not critical" "$([ "${DL2_CRIT[C]:-0}" = 0 ] || echo bad)"

# --- done nodes weigh 0: chain A(done)->B(M)->C(L), remaining doubled 10,
# B startable (its only blocker, A, is done) --------------------------------
declare -a DL3_NODES=(A B C)
declare -A DL3_DEPS=([B]=$'A\n' [C]=$'B\n')
declare -A DL3_CYCLE=()
declare -A DL3_UNMET=([C]=1)
declare -A DL3_STATUS=([A]=done [B]=planned [C]=planned)
declare -A DL3_SIZE=([A]=XL [B]=M [C]=L)
declare -A DL3_LAYER=() DL3_ORDER=() DL3_CRIT=() DL3_STARTABLE=() DL3_EXTBLK=() DL3_TAG=()
declare -a DL3_EDGES=() DL3_BACKEDGES=() DL3_CRITPATH=()
DL3_REMAIN=0; DL3_MAXLAYER=-1
wb_board_deps_layer DL3_NODES DL3_DEPS DL3_CYCLE DL3_UNMET DL3_STATUS DL3_SIZE \
  DL3_LAYER DL3_ORDER DL3_CRIT DL3_STARTABLE DL3_EXTBLK DL3_TAG \
  DL3_EDGES DL3_BACKEDGES DL3_CRITPATH DL3_REMAIN DL3_MAXLAYER
assert "deps_layer: done weighs 0 — remaining is doubled 10" '^10$' "$DL3_REMAIN"
assert "deps_layer: done weighs 0 — B startable (blocker A is done)" '^1$' "${DL3_STARTABLE[B]:-}"

# --- a lone XS node: remaining doubled 1, no tag (isolated) ----------------
declare -a DL4_NODES=(X)
declare -A DL4_DEPS=()
declare -A DL4_CYCLE=()
declare -A DL4_UNMET=()
declare -A DL4_STATUS=([X]=planned)
declare -A DL4_SIZE=([X]=XS)
declare -A DL4_LAYER=() DL4_ORDER=() DL4_CRIT=() DL4_STARTABLE=() DL4_EXTBLK=() DL4_TAG=()
declare -a DL4_EDGES=() DL4_BACKEDGES=() DL4_CRITPATH=()
DL4_REMAIN=0; DL4_MAXLAYER=-1
wb_board_deps_layer DL4_NODES DL4_DEPS DL4_CYCLE DL4_UNMET DL4_STATUS DL4_SIZE \
  DL4_LAYER DL4_ORDER DL4_CRIT DL4_STARTABLE DL4_EXTBLK DL4_TAG \
  DL4_EDGES DL4_BACKEDGES DL4_CRITPATH DL4_REMAIN DL4_MAXLAYER
assert "deps_layer: lone XS node — remaining is doubled 1" '^1$' "$DL4_REMAIN"
assert_empty "deps_layer: lone node — no tag" "${DL4_TAG[X]:-}"

# --- blank size weighted as M: lone node, blank size -> remaining doubled 4
declare -a DL5_NODES=(Y)
declare -A DL5_DEPS=()
declare -A DL5_CYCLE=()
declare -A DL5_UNMET=()
declare -A DL5_STATUS=([Y]=planned)
declare -A DL5_SIZE=([Y]="")
declare -A DL5_LAYER=() DL5_ORDER=() DL5_CRIT=() DL5_STARTABLE=() DL5_EXTBLK=() DL5_TAG=()
declare -a DL5_EDGES=() DL5_BACKEDGES=() DL5_CRITPATH=()
DL5_REMAIN=0; DL5_MAXLAYER=-1
wb_board_deps_layer DL5_NODES DL5_DEPS DL5_CYCLE DL5_UNMET DL5_STATUS DL5_SIZE \
  DL5_LAYER DL5_ORDER DL5_CRIT DL5_STARTABLE DL5_EXTBLK DL5_TAG \
  DL5_EDGES DL5_BACKEDGES DL5_CRITPATH DL5_REMAIN DL5_MAXLAYER
assert "deps_layer: blank size weighted as M — remaining is doubled 4" '^4$' "$DL5_REMAIN"

# --- external blocker: a dep outside the node set is ignored for layering
# but an unmet one blocks startable and is named in extblk; a done external
# dep is not listed ---------------------------------------------------------
declare -a DL6_NODES=(V)
declare -A DL6_DEPS=([V]=$'ext1\next2\n')
declare -A DL6_CYCLE=()
declare -A DL6_UNMET=([V]=1)
declare -A DL6_STATUS=([V]=planned [ext1]=doing [ext2]=done)
declare -A DL6_SIZE=([V]=M)
declare -A DL6_LAYER=() DL6_ORDER=() DL6_CRIT=() DL6_STARTABLE=() DL6_EXTBLK=() DL6_TAG=()
declare -a DL6_EDGES=() DL6_BACKEDGES=() DL6_CRITPATH=()
DL6_REMAIN=0; DL6_MAXLAYER=-1
wb_board_deps_layer DL6_NODES DL6_DEPS DL6_CYCLE DL6_UNMET DL6_STATUS DL6_SIZE \
  DL6_LAYER DL6_ORDER DL6_CRIT DL6_STARTABLE DL6_EXTBLK DL6_TAG \
  DL6_EDGES DL6_BACKEDGES DL6_CRITPATH DL6_REMAIN DL6_MAXLAYER
assert "deps_layer: external dep ignored for layering — V layer 0" '^0$' "${DL6_LAYER[V]:-}"
assert "deps_layer: external unmet dep named in extblk" '^ext1$' "${DL6_EXTBLK[V]:-}"
assert_empty "deps_layer: V not startable (unmet external blocker)" "$([ "${DL6_STARTABLE[V]:-0}" = 0 ] || echo bad)"

# --- START/END: single edge A->B, plus an isolated C in the same set -------
declare -a DL7_NODES=(A B C)
declare -A DL7_DEPS=([B]=$'A\n')
declare -A DL7_CYCLE=()
declare -A DL7_UNMET=()
declare -A DL7_STATUS=([A]=planned [B]=planned [C]=planned)
declare -A DL7_SIZE=([A]=M [B]=M [C]=M)
declare -A DL7_LAYER=() DL7_ORDER=() DL7_CRIT=() DL7_STARTABLE=() DL7_EXTBLK=() DL7_TAG=()
declare -a DL7_EDGES=() DL7_BACKEDGES=() DL7_CRITPATH=()
DL7_REMAIN=0; DL7_MAXLAYER=-1
wb_board_deps_layer DL7_NODES DL7_DEPS DL7_CYCLE DL7_UNMET DL7_STATUS DL7_SIZE \
  DL7_LAYER DL7_ORDER DL7_CRIT DL7_STARTABLE DL7_EXTBLK DL7_TAG \
  DL7_EDGES DL7_BACKEDGES DL7_CRITPATH DL7_REMAIN DL7_MAXLAYER
assert "deps_layer: single edge — A tagged START" '^START$' "${DL7_TAG[A]:-}"
assert "deps_layer: single edge — B tagged END" '^END$' "${DL7_TAG[B]:-}"
assert_empty "deps_layer: single edge — isolated C untagged" "${DL7_TAG[C]:-}"

# --- 2-node cycle A<->B plus C->A: A/B placed in the final column, the A<->B
# edges are back-edges, and C (not a cycle member) still gets a layer -------
declare -a DL8_NODES=(A B C)
declare -A DL8_DEPS=([A]=$'B\nC\n' [B]=$'A\n')
declare -A DL8_CYCLE=([A]=1 [B]=1)
declare -A DL8_UNMET=()
declare -A DL8_STATUS=([A]=planned [B]=planned [C]=planned)
declare -A DL8_SIZE=([A]=M [B]=M [C]=M)
declare -A DL8_LAYER=() DL8_ORDER=() DL8_CRIT=() DL8_STARTABLE=() DL8_EXTBLK=() DL8_TAG=()
declare -a DL8_EDGES=() DL8_BACKEDGES=() DL8_CRITPATH=()
DL8_REMAIN=0; DL8_MAXLAYER=-1
wb_board_deps_layer DL8_NODES DL8_DEPS DL8_CYCLE DL8_UNMET DL8_STATUS DL8_SIZE \
  DL8_LAYER DL8_ORDER DL8_CRIT DL8_STARTABLE DL8_EXTBLK DL8_TAG \
  DL8_EDGES DL8_BACKEDGES DL8_CRITPATH DL8_REMAIN DL8_MAXLAYER
assert "deps_layer: cycle — C has a layer (0)" '^0$' "${DL8_LAYER[C]:-}"
assert "deps_layer: cycle — A and B share the final column (1)" '^1 1$' "${DL8_LAYER[A]:-} ${DL8_LAYER[B]:-}"
assert "deps_layer: cycle — 2 back-edges recorded" '^2$' "${#DL8_BACKEDGES[@]}"
assert_empty "deps_layer: cycle — A not startable (cycle member)" "$([ "${DL8_STARTABLE[A]:-0}" = 0 ] || echo bad)"

# --- ties: two equal-weight parallel branches, smaller stem wins the
# critical path; repeated runs are identical (determinism) -----------------
declare -a DL9_NODES=(A B C)
declare -A DL9_DEPS=([B]=$'A\n' [C]=$'A\n')
declare -A DL9_CYCLE=()
declare -A DL9_UNMET=()
declare -A DL9_STATUS=([A]=planned [B]=planned [C]=planned)
declare -A DL9_SIZE=([A]=S [B]=M [C]=M)
declare -A DL9_LAYER=() DL9_ORDER=() DL9_CRIT=() DL9_STARTABLE=() DL9_EXTBLK=() DL9_TAG=()
declare -a DL9_EDGES=() DL9_BACKEDGES=() DL9_CRITPATH=()
DL9_REMAIN=0; DL9_MAXLAYER=-1
wb_board_deps_layer DL9_NODES DL9_DEPS DL9_CYCLE DL9_UNMET DL9_STATUS DL9_SIZE \
  DL9_LAYER DL9_ORDER DL9_CRIT DL9_STARTABLE DL9_EXTBLK DL9_TAG \
  DL9_EDGES DL9_BACKEDGES DL9_CRITPATH DL9_REMAIN DL9_MAXLAYER
assert "deps_layer: tie — smaller stem (B) wins the critical path" '^A B$' "${DL9_CRITPATH[*]}"
declare -A DL9B_LAYER=() DL9B_ORDER=() DL9B_CRIT=() DL9B_STARTABLE=() DL9B_EXTBLK=() DL9B_TAG=()
declare -a DL9B_EDGES=() DL9B_BACKEDGES=() DL9B_CRITPATH=()
DL9B_REMAIN=0; DL9B_MAXLAYER=-1
wb_board_deps_layer DL9_NODES DL9_DEPS DL9_CYCLE DL9_UNMET DL9_STATUS DL9_SIZE \
  DL9B_LAYER DL9B_ORDER DL9B_CRIT DL9B_STARTABLE DL9B_EXTBLK DL9B_TAG \
  DL9B_EDGES DL9B_BACKEDGES DL9B_CRITPATH DL9B_REMAIN DL9B_MAXLAYER
if [ "${DL9_CRITPATH[*]}" = "${DL9B_CRITPATH[*]}" ] && [ "$DL9_REMAIN" = "$DL9B_REMAIN" ]; then
  echo "ok   - deps_layer: repeated runs give identical output (determinism)"
else
  echo "FAIL - deps_layer: repeated runs diverged"; fail=1
fi

# --- barycenter: column-1 order follows predecessor order, not input array
# order (P1 before P2 in column 0; NodeY depends on P1, NodeX depends on P2,
# but NODES lists X before Y — Y must still sort first) --------------------
declare -a DL10_NODES=(NodeX NodeY p1 p2)
declare -A DL10_DEPS=([NodeX]=$'p2\n' [NodeY]=$'p1\n')
declare -A DL10_CYCLE=()
declare -A DL10_UNMET=()
declare -A DL10_STATUS=([NodeX]=planned [NodeY]=planned [p1]=planned [p2]=planned)
declare -A DL10_SIZE=([NodeX]=M [NodeY]=M [p1]=M [p2]=M)
declare -A DL10_LAYER=() DL10_ORDER=() DL10_CRIT=() DL10_STARTABLE=() DL10_EXTBLK=() DL10_TAG=()
declare -a DL10_EDGES=() DL10_BACKEDGES=() DL10_CRITPATH=()
DL10_REMAIN=0; DL10_MAXLAYER=-1
wb_board_deps_layer DL10_NODES DL10_DEPS DL10_CYCLE DL10_UNMET DL10_STATUS DL10_SIZE \
  DL10_LAYER DL10_ORDER DL10_CRIT DL10_STARTABLE DL10_EXTBLK DL10_TAG \
  DL10_EDGES DL10_BACKEDGES DL10_CRITPATH DL10_REMAIN DL10_MAXLAYER
if [ "${DL10_ORDER[NodeY]:-}" -lt "${DL10_ORDER[NodeX]:-}" ] 2>/dev/null; then
  echo "ok   - deps_layer: barycenter — column order follows predecessor order, not input order"
else
  echo "FAIL - deps_layer: barycenter order wrong (NodeY=${DL10_ORDER[NodeY]:-?} NodeX=${DL10_ORDER[NodeX]:-?})"; fail=1
fi

# --- empty node set: maxlayer -1, no edges/tags ----------------------------
declare -a DL11_NODES=()
declare -A DL11_DEPS=() DL11_CYCLE=() DL11_UNMET=() DL11_STATUS=() DL11_SIZE=()
declare -A DL11_LAYER=() DL11_ORDER=() DL11_CRIT=() DL11_STARTABLE=() DL11_EXTBLK=() DL11_TAG=()
declare -a DL11_EDGES=() DL11_BACKEDGES=() DL11_CRITPATH=()
DL11_REMAIN=0; DL11_MAXLAYER=0
wb_board_deps_layer DL11_NODES DL11_DEPS DL11_CYCLE DL11_UNMET DL11_STATUS DL11_SIZE \
  DL11_LAYER DL11_ORDER DL11_CRIT DL11_STARTABLE DL11_EXTBLK DL11_TAG \
  DL11_EDGES DL11_BACKEDGES DL11_CRITPATH DL11_REMAIN DL11_MAXLAYER
assert "deps_layer: empty node set — maxlayer -1" '^-1$' "$DL11_MAXLAYER"
assert_empty "deps_layer: empty node set — no edges" "${DL11_EDGES[*]:-}"

# --- node set with no in-set edges: maxlayer 0, zero edges -----------------
declare -a DL12_NODES=(A B)
declare -A DL12_DEPS=() DL12_CYCLE=() DL12_UNMET=()
declare -A DL12_STATUS=([A]=planned [B]=planned)
declare -A DL12_SIZE=([A]=M [B]=M)
declare -A DL12_LAYER=() DL12_ORDER=() DL12_CRIT=() DL12_STARTABLE=() DL12_EXTBLK=() DL12_TAG=()
declare -a DL12_EDGES=() DL12_BACKEDGES=() DL12_CRITPATH=()
DL12_REMAIN=0; DL12_MAXLAYER=-1
wb_board_deps_layer DL12_NODES DL12_DEPS DL12_CYCLE DL12_UNMET DL12_STATUS DL12_SIZE \
  DL12_LAYER DL12_ORDER DL12_CRIT DL12_STARTABLE DL12_EXTBLK DL12_TAG \
  DL12_EDGES DL12_BACKEDGES DL12_CRITPATH DL12_REMAIN DL12_MAXLAYER
assert "deps_layer: no in-set edges — maxlayer 0" '^0$' "$DL12_MAXLAYER"
assert_empty "deps_layer: no in-set edges — zero edges" "${DL12_EDGES[*]:-}"

# --- purity: DEPS_OF/CYCLE_MEMBER/UNMET_COUNT/STATUS/SIZE are never
# mutated (KTD3) -------------------------------------------------------------
declare -A DL13_DEPS=([B]=$'A\n')
declare -A DL13_CYCLE=([Z]=1)
declare -A DL13_UNMET=([B]=1)
declare -A DL13_STATUS=([A]=planned [B]=planned)
declare -A DL13_SIZE=([A]=M [B]=M)
dl13_deps_before="$(declare -p DL13_DEPS)"
dl13_cycle_before="$(declare -p DL13_CYCLE)"
dl13_unmet_before="$(declare -p DL13_UNMET)"
dl13_status_before="$(declare -p DL13_STATUS)"
dl13_size_before="$(declare -p DL13_SIZE)"
declare -a DL13_NODES=(A B)
declare -A DL13_LAYER=() DL13_ORDER=() DL13_CRIT=() DL13_STARTABLE=() DL13_EXTBLK=() DL13_TAG=()
declare -a DL13_EDGES=() DL13_BACKEDGES=() DL13_CRITPATH=()
DL13_REMAIN=0; DL13_MAXLAYER=-1
wb_board_deps_layer DL13_NODES DL13_DEPS DL13_CYCLE DL13_UNMET DL13_STATUS DL13_SIZE \
  DL13_LAYER DL13_ORDER DL13_CRIT DL13_STARTABLE DL13_EXTBLK DL13_TAG \
  DL13_EDGES DL13_BACKEDGES DL13_CRITPATH DL13_REMAIN DL13_MAXLAYER
if [ "$dl13_deps_before" = "$(declare -p DL13_DEPS)" ] && [ "$dl13_cycle_before" = "$(declare -p DL13_CYCLE)" ] && \
   [ "$dl13_unmet_before" = "$(declare -p DL13_UNMET)" ] && [ "$dl13_status_before" = "$(declare -p DL13_STATUS)" ] && \
   [ "$dl13_size_before" = "$(declare -p DL13_SIZE)" ]; then
  echo "ok   - deps_layer: inputs never mutated (KTD3)"
else
  echo "FAIL - deps_layer: an input array was mutated"; fail=1
fi

echo
if [ "$fail" = 0 ]; then
  echo "wb-board-deps.test.sh: all assertions passed"
else
  echo "wb-board-deps.test.sh: FAILURES"
fi
exit "$fail"
