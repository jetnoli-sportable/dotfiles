#!/usr/bin/env bash
# wb-board-dag.sh — the Family tab's dependency graph: the per-family layering /
# critical-path / startable pass (wb_board_deps_layer) and the inline-SVG
# emitter that draws it (wb_board_v2_dag_html), plus their small helpers.
# Sourced by wb-board.sh, the same way wb-board.sh itself was split out of
# wb.sh — a sibling module so the board renderer doesn't keep growing. Pure
# functions over arrays the renderer already built: no file reads, no forks.
# The region's CSS stays in wb-board.sh's page stylesheet (VIEW 4 block).

# wb_board_deps_layer <nodes_arr> <deps_of_arr> <cycle_member_arr>
#   <unmet_count_arr> <status_arr> <size_arr> <out_layer_arr> <out_order_arr>
#   <out_critical_arr> <out_startable_arr> <out_extblk_arr> <out_tag_arr>
#   <out_edges_arr> <out_backedges_arr> <out_critpath_arr>
#   <out_remaining_var> <out_maxlayer_var>
#
# U3 (family DAG view): the per-family layering/critical-path/startable pass
# that renders a node-link dependency graph of a family's direct children.
# Pure and node-set-agnostic (KTD3): <nodes_arr> is ANY list of stems — the
# real caller (the SVG emitter, next unit) passes one family root's direct
# children — and DEPS_OF/CYCLE_MEMBER/UNMET_COUNT are the SAME store-wide,
# STEM-keyed maps wb_board_render_v2 already builds for R19 (KTD2 — DG_KEY
# there is an identity map, so those arrays are keyed by stem already; see
# the D4 comment on that block). <status_arr>/<size_arr> are a plain
# stem->status / stem->`size:` map (any status value the store uses;
# `size:` one of XS/S/M/L/XL or blank). Every input array is read only —
# never mutated (verified by a dedicated purity test) — and every output
# array/scalar is fully reset at the top of the call, so a stale value from
# a previous family's call can never leak into the next.
#
# In-set edges (R3): only depends_on: edges where BOTH ends are in
# <nodes_arr> are drawn or used for layering — an edge to the family root or
# to another family's task is invisible to layering (though still visible to
# <out_extblk> below, R6). Layer (R4) is the node's longest unweighted
# dependency chain within the set, roots at column 0. Weight (R5, KTD1) is
# stored DOUBLED so bash's integer-only arithmetic is exact: XS=1 S=2 M=4
# L=6 XL=10, blank/unknown=4 (=M), done status=0 regardless of size — the
# render layer divides by 2 for display. Critical path (R5) is the maximum
# such doubled-weight chain of REMAINING (non-done-inclusive, since done
# nodes cost 0) work; ties break by smallest stem, both for the path's own
# endpoint and for each step's best predecessor.
#
# Cycle members (R7, KTD4): reuses CYCLE_MEMBER verbatim rather than a
# second cycle detector — a node already flagged (store-wide) is placed in
# the FINAL column (one past the highest non-cycle layer; 0 if the set has
# no non-cycle nodes) and is excluded entirely from the critical-path
# search (it contributes no weight to any other node's `ef`, and can never
# be picked as a step's best predecessor). An in-set edge is a BACK-EDGE
# iff BOTH ends are cycle members; those are the only edges omitted from
# <out_edges> (they still count for nothing else — no layering, no order,
# no tag). An edge from a non-cycle node INTO a cycle member is an ordinary
# edge (drawn, tag-eligible) but, symmetrically with the point above, is
# never treated as a layering predecessor of anything (cycle members don't
# participate in the non-cycle Kahn pass at all). An edge FROM a cycle
# member TO a non-cycle node is the one shape the design brief calls out as
# not really occurring in a well-formed graph (KTD4); this function's sane
# behaviour for it is to render it as an ordinary (non-back) edge — it can
# still set that non-cycle node's START/END tag — but to simply never let
# it feed that node's layer/critical-path computation, since a cycle
# member's own layer isn't known until after the non-cycle pass completes.
# Termination is structural either way (see below), not dependent on this
# case being rare.
#
# Layering algorithm: Kahn's algorithm restricted to non-cycle nodes, using
# only non-cycle-to-non-cycle in-set edges as the precedence relation.
# CYCLE_MEMBER is computed store-wide via full reachability (see
# wb_board_deps_cycles), so a cycle occurring purely within THIS node set's
# edges already has every one of its members flagged — meaning the non-
# cycle subgraph fed to Kahn is guaranteed acyclic, and the queue-driven
# pass below (bounded by node count, no recursion) always drains and
# terminates whether or not that invariant holds.
#
# startable-now (R6): status is `planned`, not a cycle member, and
# UNMET_COUNT is 0/unset (that count is already store-wide — computed by
# wb_board_deps_blocking over the FULL depends_on: list, not just in-set
# edges — so an external blocker already counts against it here with zero
# extra work). <out_extblk> is purely informational: every depends_on:
# stem of a node that is OUTSIDE this node set and not status `done`.
#
# START/END tag (the design brief's "at most one, never both"): only a node
# touched by >=1 in-set NON-BACK edge gets a tag at all; of those, no in-set
# predecessor -> START, no in-set successor -> END, both present -> "" (a
# node with a non-back edge has at least one of the two, so exactly one of
# START/END/"" applies, never both tags at once).
#
# In-column order (KTD5): one left-to-right barycenter pass — column 0
# sorts by stem; column k>0 sorts by the mean already-assigned order index
# of each node's in-set non-back predecessors (all of which sit in a
# strictly earlier column, by construction), ties broken by stem. A node
# with no such predecessor (only possible for an isolated cycle member)
# sorts last within its column. Deterministic regardless of <nodes_arr>'s
# own input order — proven by a dedicated test that feeds an intentionally
# scrambled node list and checks the resulting order tracks predecessors,
# not the input.
#
# wb_board_v2_bash_sort_lines <arr_name> — in-place ascending sort of an
# array of plain lines by whole-line bash string comparison (`[[ a < b ]]`,
# the SAME collation convention this file's own tie-breaks already use
# elsewhere, e.g. wb_board_deps_layer's `dl_best_p`/`dl_best_stem` picks).
# Pure bash (insertion sort — fine for the tiny per-family edge counts this
# is called on; O(n^2) never matters at n<~50), used instead of piping
# through `sort -u` specifically to avoid a subprocess fork: U5 (family DAG
# view) calls wb_board_deps_layer once per family on the real store, and
# `sort` forked twice per call (this dedupe + one more per DAG column,
# below) was measured adding ~2s to a ~11.5s render.
wb_board_v2_bash_sort_lines() {
  local -n bsl_arr="$1"
  local bsl_i bsl_j bsl_key
  for (( bsl_i=1; bsl_i<${#bsl_arr[@]}; bsl_i++ )); do
    bsl_key="${bsl_arr[$bsl_i]}"
    bsl_j=$((bsl_i - 1))
    while [ "$bsl_j" -ge 0 ] && [[ "${bsl_arr[$bsl_j]}" > "$bsl_key" ]]; do
      bsl_arr[$((bsl_j + 1))]="${bsl_arr[$bsl_j]}"
      bsl_j=$((bsl_j - 1))
    done
    bsl_arr[$((bsl_j + 1))]="$bsl_key"
  done
}

# wb_board_v2_bash_sort_keyed <arr_name> — in-place ascending sort of an
# array of "$numeric_key\t$value" lines: numeric key first (matching
# `sort -k1,1n`), value (bash string comparison) breaks ties (matching
# `sort -k2,2`) — the exact two-key order wb_board_deps_layer's own
# barycenter column sort needs. Same fork-avoidance rationale as
# wb_board_v2_bash_sort_lines above.
wb_board_v2_bash_sort_keyed() {
  local -n bsk_arr="$1"
  local bsk_i bsk_j bsk_key bsk_keynum bsk_keyval bsk_curnum bsk_curval
  for (( bsk_i=1; bsk_i<${#bsk_arr[@]}; bsk_i++ )); do
    bsk_key="${bsk_arr[$bsk_i]}"
    bsk_keynum="${bsk_key%%$'\t'*}"; bsk_keyval="${bsk_key#*$'\t'}"
    bsk_j=$((bsk_i - 1))
    while [ "$bsk_j" -ge 0 ]; do
      bsk_curnum="${bsk_arr[$bsk_j]%%$'\t'*}"; bsk_curval="${bsk_arr[$bsk_j]#*$'\t'}"
      if [ "$bsk_curnum" -gt "$bsk_keynum" ] || \
         { [ "$bsk_curnum" -eq "$bsk_keynum" ] && [[ "$bsk_curval" > "$bsk_keyval" ]]; }; then
        bsk_arr[$((bsk_j + 1))]="${bsk_arr[$bsk_j]}"
        bsk_j=$((bsk_j - 1))
      else
        break
      fi
    done
    bsk_arr[$((bsk_j + 1))]="$bsk_key"
  done
}

# Design choice (documented per the plan's instruction): when all in-set
# critical-path-eligible work is already done, <out_remaining> is 0 and
# <out_critpath> is left EMPTY rather than reporting the longest all-zero
# chain — an empty critical path is a cleaner "nothing left to rush" signal
# for the SVG emitter than a chain of already-done nodes.
wb_board_deps_layer() {
  local -n dl_nodes="$1" dl_deps_of="$2" dl_cycle_member="$3" dl_unmet_count="$4"
  local -n dl_status="$5" dl_size="$6"
  local -n dl_out_layer="$7" dl_out_order="$8" dl_out_critical="$9" dl_out_startable="${10}"
  local -n dl_out_extblk="${11}" dl_out_tag="${12}" dl_out_edges="${13}" dl_out_backedges="${14}"
  local -n dl_out_critpath="${15}" dl_out_remaining="${16}" dl_out_maxlayer="${17}"

  dl_out_layer=(); dl_out_order=(); dl_out_critical=(); dl_out_startable=()
  dl_out_extblk=(); dl_out_tag=(); dl_out_edges=(); dl_out_backedges=(); dl_out_critpath=()
  dl_out_remaining=0; dl_out_maxlayer=-1

  [ "${#dl_nodes[@]}" -gt 0 ] || return 0

  local -A dl_inset=()
  local dl_v
  for dl_v in "${dl_nodes[@]}"; do dl_inset["$dl_v"]=1; done

  # ---- R3: collect in-set edges only, "$dep\t$dependent" per line, deduped
  # and lexicographically sorted for a deterministic <out_edges>/
  # <out_backedges> order regardless of <nodes_arr>'s own order ------------
  local -a dl_raw_edges=()
  local dl_dep
  for dl_v in "${dl_nodes[@]}"; do
    [ -n "${dl_deps_of[$dl_v]:-}" ] || continue
    while IFS= read -r dl_dep; do
      [ -n "$dl_dep" ] || continue
      [ -n "${dl_inset[$dl_dep]:-}" ] || continue
      dl_raw_edges+=("$dl_dep"$'\t'"$dl_v")
    done <<< "${dl_deps_of[$dl_v]}"
  done
  local -a dl_all_edges=()
  if [ "${#dl_raw_edges[@]}" -gt 0 ]; then
    # dedupe (a hand-authored depends_on: can repeat the same pair) then sort
    # — pure bash, no `sort -u` fork (see wb_board_v2_bash_sort_lines's header).
    local -A dl_edge_seen=()
    local dl_re
    for dl_re in "${dl_raw_edges[@]}"; do
      [ -n "${dl_edge_seen[$dl_re]:-}" ] && continue
      dl_edge_seen["$dl_re"]=1
      dl_all_edges+=("$dl_re")
    done
    wb_board_v2_bash_sort_lines dl_all_edges
  fi

  # ---- classify each in-set edge: back-edge (both ends cycle members, KTD4)
  # or ordinary. dl_nbpred/dl_nbsucc (non-back, both cycle & non-cycle ends)
  # feed the tag + barycenter-order passes below; dl_lpred/dl_lsucc (non-back
  # AND the predecessor is non-cycle) feed layering + CPM only ------------
  local -A dl_nbpred=() dl_nbsucc=() dl_lpred=() dl_lsucc=() dl_touched=()
  local dl_e dl_from dl_to
  for dl_e in "${dl_all_edges[@]}"; do
    dl_from="${dl_e%%$'\t'*}"; dl_to="${dl_e#*$'\t'}"
    if [ -n "${dl_cycle_member[$dl_from]:-}" ] && [ -n "${dl_cycle_member[$dl_to]:-}" ]; then
      dl_out_backedges+=("$dl_from $dl_to")
      continue
    fi
    dl_out_edges+=("$dl_from $dl_to")
    dl_touched["$dl_from"]=1; dl_touched["$dl_to"]=1
    dl_nbpred["$dl_to"]+="$dl_from"$'\n'
    dl_nbsucc["$dl_from"]+="$dl_to"$'\n'
    if [ -z "${dl_cycle_member[$dl_from]:-}" ]; then
      dl_lpred["$dl_to"]+="$dl_from"$'\n'
      dl_lsucc["$dl_from"]+="$dl_to"$'\n'
    fi
  done

  # ---- KTD1: doubled weight per node (done -> 0 regardless of size) ------
  local -A dl_w=()
  for dl_v in "${dl_nodes[@]}"; do
    if [ "${dl_status[$dl_v]:-}" = done ]; then
      dl_w["$dl_v"]=0
    else
      case "${dl_size[$dl_v]:-}" in
        XS) dl_w["$dl_v"]=1 ;;
        S)  dl_w["$dl_v"]=2 ;;
        M)  dl_w["$dl_v"]=4 ;;
        L)  dl_w["$dl_v"]=6 ;;
        XL) dl_w["$dl_v"]=10 ;;
        *)  dl_w["$dl_v"]=4 ;;
      esac
    fi
  done

  # ---- Kahn over non-cycle nodes only, using dl_lpred/dl_lsucc — see the
  # header comment above for why the non-cycle subgraph is guaranteed
  # acyclic (so this always fully drains) and for the cycle-adjacent edge
  # cases this deliberately ignores for layering purposes ------------------
  local -A dl_indeg=() dl_layer=() dl_ef=() dl_bestpred=()
  local -a dl_queue=()
  local dl_p dl_cnt
  for dl_v in "${dl_nodes[@]}"; do
    [ -n "${dl_cycle_member[$dl_v]:-}" ] && continue
    dl_cnt=0
    if [ -n "${dl_lpred[$dl_v]:-}" ]; then
      while IFS= read -r dl_p; do [ -n "$dl_p" ] && dl_cnt=$((dl_cnt + 1)); done <<< "${dl_lpred[$dl_v]}"
    fi
    dl_indeg["$dl_v"]="$dl_cnt"
    [ "$dl_cnt" -eq 0 ] && dl_queue+=("$dl_v")
  done

  local dl_qi=0 dl_maxlayer_n0=-1 dl_max_ef=0 dl_best_stem="" dl_s
  while [ "$dl_qi" -lt "${#dl_queue[@]}" ]; do
    dl_v="${dl_queue[$dl_qi]}"; dl_qi=$((dl_qi + 1))
    if [ -z "${dl_lpred[$dl_v]:-}" ]; then
      dl_layer["$dl_v"]=0
      dl_ef["$dl_v"]="${dl_w[$dl_v]}"
      dl_bestpred["$dl_v"]=""
    else
      local dl_max_layer_p=-1 dl_max_ef_p=-1 dl_best_p=""
      while IFS= read -r dl_p; do
        [ -n "$dl_p" ] || continue
        [ "${dl_layer["$dl_p"]}" -gt "$dl_max_layer_p" ] && dl_max_layer_p="${dl_layer["$dl_p"]}"
        if [ "${dl_ef["$dl_p"]}" -gt "$dl_max_ef_p" ] || \
           { [ "${dl_ef["$dl_p"]}" -eq "$dl_max_ef_p" ] && [[ "$dl_p" < "$dl_best_p" ]]; }; then
          dl_max_ef_p="${dl_ef["$dl_p"]}"; dl_best_p="$dl_p"
        fi
      done <<< "${dl_lpred[$dl_v]}"
      dl_layer["$dl_v"]=$((dl_max_layer_p + 1))
      dl_ef["$dl_v"]=$(( dl_max_ef_p + ${dl_w[$dl_v]} ))
      dl_bestpred["$dl_v"]="$dl_best_p"
    fi
    [ "${dl_layer["$dl_v"]}" -gt "$dl_maxlayer_n0" ] && dl_maxlayer_n0="${dl_layer["$dl_v"]}"
    if [ "${dl_ef["$dl_v"]}" -gt "$dl_max_ef" ] || \
       { [ "${dl_ef["$dl_v"]}" -eq "$dl_max_ef" ] && { [ -z "$dl_best_stem" ] || [[ "$dl_v" < "$dl_best_stem" ]]; }; }; then
      dl_max_ef="${dl_ef["$dl_v"]}"; dl_best_stem="$dl_v"
    fi
    if [ -n "${dl_lsucc[$dl_v]:-}" ]; then
      while IFS= read -r dl_s; do
        [ -n "$dl_s" ] || continue
        # A successor reached via dl_lsucc is, by construction, always a
        # non-cycle node (dl_lsucc only records non-cycle -> non-cycle
        # edges — see the classification loop above, which only feeds
        # dl_lsucc[from] when `from` is non-cycle, and here `from` IS the
        # predecessor; the successor side can still be a cycle member
        # though, e.g. C->A in the 2-cycle test — that case has no indeg
        # entry at all (cycle members never enter the Kahn universe) and
        # is skipped rather than decremented.
        [ -n "${dl_indeg["$dl_s"]+x}" ] || continue
        dl_indeg["$dl_s"]=$(( ${dl_indeg["$dl_s"]} - 1 ))
        [ "${dl_indeg["$dl_s"]}" -eq 0 ] && dl_queue+=("$dl_s")
      done <<< "${dl_lsucc[$dl_v]}"
    fi
  done

  # ---- R7: cycle members go in the final column (one past the highest
  # non-cycle layer; 0 if there were no non-cycle nodes at all) -----------
  local dl_cycle_layer=$((dl_maxlayer_n0 + 1))
  local dl_has_cycle=0
  for dl_v in "${dl_nodes[@]}"; do
    if [ -n "${dl_cycle_member[$dl_v]:-}" ]; then
      dl_layer["$dl_v"]="$dl_cycle_layer"
      dl_has_cycle=1
    fi
  done
  if [ "$dl_has_cycle" -eq 1 ]; then dl_out_maxlayer="$dl_cycle_layer"; else dl_out_maxlayer="$dl_maxlayer_n0"; fi

  for dl_v in "${dl_nodes[@]}"; do dl_out_layer["$dl_v"]="${dl_layer[$dl_v]:-0}"; done

  # ---- critical path: prefer an EMPTY path over an all-zero (all-done)
  # chain when nothing remains (documented design choice above) -----------
  dl_out_remaining="$dl_max_ef"
  if [ "$dl_max_ef" -gt 0 ] && [ -n "$dl_best_stem" ]; then
    local -a dl_path_rev=()
    local -A dl_path_seen=()
    local dl_cur="$dl_best_stem" dl_i
    while [ -n "$dl_cur" ]; do
      [ -n "${dl_path_seen[$dl_cur]:-}" ] && break   # defensive; structurally unreachable
      dl_path_seen["$dl_cur"]=1
      dl_path_rev+=("$dl_cur")
      dl_cur="${dl_bestpred[$dl_cur]:-}"
    done
    for (( dl_i=${#dl_path_rev[@]}-1; dl_i>=0; dl_i-- )); do
      dl_out_critpath+=("${dl_path_rev[$dl_i]}")
      dl_out_critical["${dl_path_rev[$dl_i]}"]=1
    done
  fi
  for dl_v in "${dl_nodes[@]}"; do
    [ -n "${dl_out_critical[$dl_v]:-}" ] || dl_out_critical["$dl_v"]=0
  done

  # ---- R6: startable-now — UNMET_COUNT is store-wide (external blockers
  # already counted, wb_board_deps_blocking) ------------------------------
  for dl_v in "${dl_nodes[@]}"; do
    if [ "${dl_status[$dl_v]:-}" = planned ] && [ -z "${dl_cycle_member[$dl_v]:-}" ] && \
       [ "${dl_unmet_count[$dl_v]:-0}" -eq 0 ]; then
      dl_out_startable["$dl_v"]=1
    else
      dl_out_startable["$dl_v"]=0
    fi
  done

  # ---- extblk: every depends_on: stem OUTSIDE this node set that isn't
  # done yet (a done external dep is dropped — nothing to warn about) -----
  for dl_v in "${dl_nodes[@]}"; do
    [ -n "${dl_deps_of[$dl_v]:-}" ] || continue
    local dl_ext=""
    while IFS= read -r dl_dep; do
      [ -n "$dl_dep" ] || continue
      [ -n "${dl_inset[$dl_dep]:-}" ] && continue
      [ "${dl_status[$dl_dep]:-}" = done ] && continue
      dl_ext+="$dl_dep "
    done <<< "${dl_deps_of[$dl_v]}"
    dl_ext="${dl_ext% }"
    [ -n "$dl_ext" ] && dl_out_extblk["$dl_v"]="$dl_ext"
  done

  # ---- START/END tag: only nodes touched by >=1 non-back in-set edge ----
  for dl_v in "${dl_nodes[@]}"; do
    dl_out_tag["$dl_v"]=""
    [ -n "${dl_touched[$dl_v]:-}" ] || continue
    if [ -z "${dl_nbpred[$dl_v]:-}" ]; then
      dl_out_tag["$dl_v"]="START"
    elif [ -z "${dl_nbsucc[$dl_v]:-}" ]; then
      dl_out_tag["$dl_v"]="END"
    fi
  done

  # ---- KTD5: barycenter in-column order, column 0 first, one left-to-
  # right pass so every predecessor's order is already assigned -----------
  local dl_c
  for (( dl_c=0; dl_c<=dl_out_maxlayer; dl_c++ )); do
    local -a dl_col=()
    for dl_v in "${dl_nodes[@]}"; do
      [ "${dl_out_layer[$dl_v]}" -eq "$dl_c" ] && dl_col+=("$dl_v")
    done
    [ "${#dl_col[@]}" -gt 0 ] || continue
    local -a dl_keyed=()
    if [ "$dl_c" -eq 0 ]; then
      for dl_v in "${dl_col[@]}"; do dl_keyed+=("0"$'\t'"$dl_v"); done
    else
      for dl_v in "${dl_col[@]}"; do
        local dl_sum=0 dl_cnt2=0 dl_key
        if [ -n "${dl_nbpred[$dl_v]:-}" ]; then
          while IFS= read -r dl_p; do
            [ -n "$dl_p" ] || continue
            dl_sum=$(( dl_sum + ${dl_out_order["$dl_p"]:-0} ))
            dl_cnt2=$((dl_cnt2 + 1))
          done <<< "${dl_nbpred[$dl_v]}"
        fi
        if [ "$dl_cnt2" -eq 0 ]; then
          dl_key=9999999   # no in-column predecessor (isolated cycle member) -> sorts last
        else
          dl_key=$(( (dl_sum * 1000) / dl_cnt2 ))
        fi
        dl_keyed+=("$dl_key"$'\t'"$dl_v")
      done
    fi
    local -a dl_sorted_col=("${dl_keyed[@]}")
    wb_board_v2_bash_sort_keyed dl_sorted_col
    local dl_idx=0
    for dl_e in "${dl_sorted_col[@]}"; do
      dl_v="${dl_e#*$'\t'}"
      dl_out_order["$dl_v"]="$dl_idx"
      dl_idx=$((dl_idx + 1))
    done
  done
}

# wb_board_v2_dag_short_label <stem> <strip_prefix> <out_var> — the short id
# a DAG card and the critical-path header show. Children usually share their
# root's stem prefix (`<root>-<child>`), which is dropped; when they don't
# (most families whose root was named separately), the `<repo>--` segment is
# dropped instead, so sibling labels still differ in their first characters.
wb_board_v2_dag_short_label() {
  local __sl="$1"
  if [ -n "$2" ] && [[ "$1" == "$2"* ]]; then
    __sl="${1#"$2"}"; __sl="${__sl#-}"
  elif [[ "$1" == *--* ]]; then
    # Through the LAST `--`: repo names can contain one (`be--monorepo`).
    __sl="${1##*--}"
  fi
  [ -n "$__sl" ] || __sl="$1"
  printf -v "$3" '%s' "$__sl"
}

# wb_board_v2_dag_node_dims <size> <w_out> <h_out> — one node's SVG box
# dimensions for a `size:` value (XS/S/M/L/XL, blank reads as M — same
# "blank means M" convention wb_board_deps_layer's own weight table uses).
# Numbers are mockup-3-graph.html's own units, unscaled (1x): the family
# view's ~15px body type is already close enough that U4's allowed scale
# factor isn't needed.
wb_board_v2_dag_node_dims() {
  case "${1:-}" in
    XS) printf -v "$2" '%s' 104; printf -v "$3" '%s' 48 ;;
    S)  printf -v "$2" '%s' 128; printf -v "$3" '%s' 58 ;;
    L)  printf -v "$2" '%s' 176; printf -v "$3" '%s' 84 ;;
    XL) printf -v "$2" '%s' 208; printf -v "$3" '%s' 104 ;;
    *)  printf -v "$2" '%s' 152; printf -v "$3" '%s' 70 ;;   # M / blank
  esac
}

# wb_board_v2_dag_html <family_anchor> <nodes_arr> <layer_assoc> <order_assoc>
#   <critical_assoc> <startable_assoc> <extblk_assoc> <tag_assoc> <edges_arr>
#   <backedges_arr> <critpath_arr> <remaining_doubled> <maxlayer>
#   <strip_prefix> <out_var>
#
# U4 (family DAG view): turns U3's wb_board_deps_layer output plus model data
# into the Dependencies region's HTML — a header line naming the critical
# path/remaining weight/startable count, PLUS a zero-JS inline SVG node-link
# graph. Does NOT call wb_board_deps_layer itself (KTD3/scope boundary): the
# caller (U5) calls that once per family and passes ITS out-array NAMES
# straight through here, unmodified — <layer_assoc>..<critpath_arr> are
# exactly wb_board_deps_layer's own out_layer/out_order/out_critical/
# out_startable/out_extblk/out_tag/out_edges/out_backedges/out_critpath, and
# <remaining_doubled>/<maxlayer> are its out_remaining/out_maxlayer SCALARS
# (plain values here, not namerefs — U3 already resolved them to numbers).
#
# <strip_prefix>: when non-empty and a stem starts with it (followed
# optionally by a single `-`), that prefix (and the separator) is stripped
# for the short mono label shown top-left on each card (matching the
# mockup's "c1"-style short ids) — the FULL stem is always still shown, in
# the tooltip and the header's path. This function does not know the family
# root's own name, hence the caller-supplied prefix (documented here per the
# unit brief) rather than deriving it. Pass "" to show stems unstripped.
#
# THIS FUNCTION EMITS ITS OWN `<h2 class="region-label">Dependencies</h2>` —
# U5 must NOT wrap the result in a second one; it only needs to concatenate
# <out_var> into the family block at the right place (same convention as
# every other `wb_board_v2_*_html` region builder in this file).
#
# Model data (_m_status/_m_title/_m_size/_m_accept/_m_plan_raw/
# _m_stem_anchor) is read via ordinary dynamic scoping from the caller's
# scope (render_v2's own `_m_*` namerefs), exactly like every other
# `wb_board_v2_*` helper below reads them — NOT a second layer of namerefs.
# Local variables in this function are prefixed `dh_`, deliberately distinct
# from `_m_*`/`dl_*`/every other prefix already in use in this file, per the
# circular-nameref trap documented at length on wb_board_v2_family_root and
# wb_board_render_v2's own header — this function takes NINE namerefs of its
# own (nodes/layer/order/critical/startable/extblk/tag/edges/backedges/
# critpath), so a collision here would be exactly that trap.
#
# Layout (KTD11's Plan-ring precedent: bash-computed geometry, literal SVG
# string, CSS classes only, out-var escaping helpers — no per-node fork):
#   colW = 208 (widest node, XL) + 64px gap  = 272, uniform for every column
#   rowH = 104 (tallest node, XL) + 20px gap = 124, uniform for every row
# so x = layer*colW, y = order*rowH (both plus a fixed margin), regardless
# of which sizes are actually present in this family — a safe superset of
# "column width >= widest node present" that keeps every family's grid
# arithmetic identical and avoids a second pass just to find the family's
# own local max.
#
# Marker ids are suffixed with <family_anchor> (`dag-arrow-<anchor>`) so
# multiple family SVGs on one page (Family tab renders every family's block,
# just hidden via `.fam-block{display:none}` until selected) never collide
# on the same `<marker id>` — the arrowhead uses `fill="context-stroke"`, so
# one marker id serves every edge class (default/critical/back-edge) in this
# family's SVG; each family still needs its OWN id since SVG `<marker>` ids
# are page-global.
wb_board_v2_dag_html() {
  local dh_anchor="$1"
  local -n dh_nodes="$2" dh_layer="$3" dh_order="$4" dh_critical="$5" dh_startable="$6"
  local -n dh_extblk="$7" dh_tag="$8" dh_edges="$9" dh_backedges="${10}" dh_critpath="${11}"
  local dh_remaining="${12}" dh_maxlayer="${13}" dh_strip="${14}"

  local dh_out="<h2 class=\"region-label\">Dependencies</h2>"

  if [ "${#dh_nodes[@]}" -eq 0 ]; then
    dh_out+="<p style=\"color:var(--subtext);\">No children in this family.</p>"
    printf -v "${15}" '%s' "$dh_out"
    return 0
  fi

  # ---- geometry constants (see header comment) ---------------------------
  local dh_colw=272 dh_rowh=124 dh_marginl=40 dh_margint=40 dh_marginr=28 dh_marginb=40

  # ---- pass 1: per-node geometry + column row-counts + frontier layer ----
  local -A dh_x=() dh_y=() dh_w=() dh_h=()
  local -A dh_colcount=()
  local dh_v dh_w1 dh_h1 dh_l dh_o
  local dh_frontier_layer=-1 dh_status_v
  for dh_v in "${dh_nodes[@]}"; do
    wb_board_v2_dag_node_dims "${_m_size[$dh_v]:-}" dh_w1 dh_h1
    dh_l="${dh_layer[$dh_v]:-0}"; dh_o="${dh_order[$dh_v]:-0}"
    dh_w["$dh_v"]="$dh_w1"; dh_h["$dh_v"]="$dh_h1"
    dh_x["$dh_v"]=$(( dh_marginl + dh_l * dh_colw ))
    dh_y["$dh_v"]=$(( dh_margint + dh_o * dh_rowh + (dh_rowh - dh_h1) / 2 ))
    dh_colcount["$dh_l"]=$(( ${dh_colcount[$dh_l]:-0} + 1 ))
    dh_status_v="${_m_status[$dh_v]:-}"
    if [ "$dh_status_v" != done ] && { [ "$dh_frontier_layer" -lt 0 ] || [ "$dh_l" -lt "$dh_frontier_layer" ]; }; then
      dh_frontier_layer="$dh_l"
    fi
  done
  local dh_maxrows=0 dh_ck
  for dh_ck in "${!dh_colcount[@]}"; do
    [ "${dh_colcount[$dh_ck]}" -gt "$dh_maxrows" ] && dh_maxrows="${dh_colcount[$dh_ck]}"
  done
  local dh_svgw=$(( (dh_maxlayer + 1) * dh_colw + dh_marginl + dh_marginr ))
  local dh_svgh=$(( dh_maxrows * dh_rowh + dh_margint + dh_marginb ))

  # ---- header line (R11) --------------------------------------------------
  local dh_head="" dh_pts_whole dh_pts_rem dh_pts
  dh_pts_whole=$(( dh_remaining / 2 )); dh_pts_rem=$(( dh_remaining % 2 ))
  if [ "$dh_pts_rem" -eq 0 ]; then dh_pts="$dh_pts_whole"; else dh_pts="${dh_pts_whole}.5"; fi
  local dh_startable_n=0
  for dh_v in "${dh_nodes[@]}"; do
    [ "${dh_startable[$dh_v]:-0}" = 1 ] && dh_startable_n=$(( dh_startable_n + 1 ))
  done
  if [ "${#dh_critpath[@]}" -gt 0 ]; then
    local dh_path_html="" dh_short dh_sh dh_stemh dh_i
    for (( dh_i=0; dh_i<${#dh_critpath[@]}; dh_i++ )); do
      dh_v="${dh_critpath[$dh_i]}"
      wb_board_v2_dag_short_label "$dh_v" "$dh_strip" dh_short
      wb_board_html_escape "$dh_short" dh_sh
      wb_board_html_escape "$dh_v" dh_stemh
      [ "$dh_i" -gt 0 ] && dh_path_html+="<span class=\"dag-arw\">&#8594;</span>"
      dh_path_html+="<span class=\"dag-path-hop mono\" title=\"$dh_stemh\">$dh_sh</span>"
    done
    dh_head="Critical path: ${dh_path_html} &middot; ${dh_pts} pts remaining &middot; ${dh_startable_n} startable now"
  else
    dh_head="${dh_pts} pts remaining &middot; ${dh_startable_n} startable now"
  fi
  dh_out+="<div class=\"fam-dag-head\">${dh_head}</div>"

  # ---- frontier line (R10) ------------------------------------------------
  local dh_frontier_svg=""
  # Omitted when every node is done (-1) AND when column 0 already holds
  # unfinished work (0): there is no done region to its left, and the line
  # would land left of the first column, outside the drawing.
  if [ "$dh_frontier_layer" -gt 0 ]; then
    # Midway through the gap between the previous column's widest card (XL,
    # 208) and this column's left edge, so it never cuts through a card.
    local dh_fx=$(( dh_marginl + dh_frontier_layer * dh_colw - (dh_colw - 208) / 2 ))
    dh_frontier_svg="<line class=\"dag-frontier\" x1=\"${dh_fx}\" y1=\"12\" x2=\"${dh_fx}\" y2=\"$(( dh_svgh - 8 ))\"/><text class=\"dag-frontier-lbl\" x=\"${dh_fx}\" y=\"$(( dh_svgh - 14 ))\" text-anchor=\"middle\">&#9656; YOU ARE HERE</text>"
  fi

  # ---- pass 2: node markup -------------------------------------------------
  local dh_nodes_svg="" dh_cls dh_st_token dh_dashed dh_sig dh_planraw
  local dh_short2 dh_sh2 dh_stemh2 dh_titleh dh_title_clip dh_title_raw dh_maxchars dh_href
  local dh_toprowh=22 dh_bottomrowh dh_title_y dh_dot_html dh_status_html
  local dh_badge_txt dh_status_txt dh_status_h dh_tag_html dh_lock_html dh_pulse_html dh_startable_html
  local dh_title_tt dh_extblk_h dh_extblk_disp dh_extblk_html
  for dh_v in "${dh_nodes[@]}"; do
    dh_w1="${dh_w[$dh_v]}"; dh_h1="${dh_h[$dh_v]}"
    local dh_nx="${dh_x[$dh_v]}" dh_ny="${dh_y[$dh_v]}"
    dh_status_v="${_m_status[$dh_v]:-}"

    case "$dh_status_v" in
      done) dh_cls="dag-st-done"; dh_st_token="green" ;;
      doing|review) dh_cls="dag-st-active"; dh_st_token="mauve" ;;
      planned) dh_cls="dag-st-planned"; dh_st_token="blue" ;;
      *) dh_cls="dag-st-other"; dh_st_token="subtext" ;;
    esac

    # ---- KTD6: definedness signal count ----
    dh_sig=0
    dh_planraw="${_m_plan_raw[$dh_v]:-}"
    # A glob test, not `${x//[[:space:]]/}`: bash's class-substitution is
    # quadratic in practice (~300ms on a 12KB Plan), and this runs per node.
    [[ "$dh_planraw" == *[![:space:]]* ]] && dh_sig=$(( dh_sig + 1 ))
    [ "${_m_accept[$dh_v]:-0}" = 1 ] && dh_sig=$(( dh_sig + 1 ))
    [ -n "${_m_size[$dh_v]:-}" ] && dh_sig=$(( dh_sig + 1 ))
    case "$dh_status_v" in doing|review|done) dh_sig=$(( dh_sig + 1 )) ;; esac
    if [ "$dh_status_v" != done ] && [ "$dh_sig" -lt 3 ]; then dh_dashed=" dag-dashed"; else dh_dashed=""; fi

    [ "${dh_critical[$dh_v]:-0}" = 1 ] && dh_cls+=" dag-crit-node"
    [ "${dh_startable[$dh_v]:-0}" = 1 ] && dh_cls+=" dag-startable"

    # ---- short label (mono, top-left) ----
    wb_board_v2_dag_short_label "$dh_v" "$dh_strip" dh_short2
    # Real stems run long (`doc-review-skeptic-lens`, or a whole
    # `<repo>--<slug>` when the child doesn't share the root's prefix), so
    # the id gets the same single-ellipsis clip as the title, sized to the
    # gap between the left padding and the size badge (and the lock / XS dot
    # when those share the top row). ~7px per char at the 11px mono size.
    local dh_id_right=$(( dh_w1 - 40 ))
    [ -n "${dh_extblk[$dh_v]:-}" ] && dh_id_right=$(( dh_w1 - 60 ))
    [ "${_m_size[$dh_v]:-}" = XS ] && dh_id_right=$(( dh_id_right - 14 ))
    local dh_id_max=$(( (dh_id_right - 10) / 7 ))
    [ "$dh_id_max" -lt 3 ] && dh_id_max=3
    local dh_id_clipped=0
    if [ "${#dh_short2}" -gt "$dh_id_max" ]; then dh_short2="${dh_short2:0:$(( dh_id_max - 1 ))}"; dh_id_clipped=1; fi
    wb_board_html_escape "$dh_short2" dh_sh2
    [ "$dh_id_clipped" = 1 ] && dh_sh2+="&#8230;"
    wb_board_html_escape "$dh_v" dh_stemh2

    # ---- title: card-width-derived clip, single-char ellipsis. Not
    # wb_board_v2_clip: that is the prose-block clipper, and its long
    # "[clipped — open the task file for the rest]" suffix would overflow a
    # card. ~7px/char at the
    # 13px title font, minus ~24px of left/right padding, floored at 4 chars
    # so even the narrowest (XS) card never collapses to nothing. ----------
    dh_maxchars=$(( (dh_w1 - 24) / 7 ))
    [ "$dh_maxchars" -lt 4 ] && dh_maxchars=4
    dh_title_raw="${_m_title[$dh_v]:-$dh_v}"
    if [ "${#dh_title_raw}" -gt "$dh_maxchars" ]; then
      dh_title_clip="${dh_title_raw:0:$(( dh_maxchars - 1 ))}&#8230;"
      wb_board_html_escape "${dh_title_raw:0:$(( dh_maxchars - 1 ))}" dh_titleh
      dh_titleh+="&#8230;"
    else
      wb_board_html_escape "$dh_title_raw" dh_titleh
    fi

    # ---- status label (bottom row; dropped entirely for XS, which only has
    # room for two rows: id/badge, then title) -----------------------------
    dh_status_txt="${dh_status_v:-unknown}"
    wb_board_html_escape "$dh_status_txt" dh_status_h

    # ---- size badge (top-right) ----
    # Only enum values reach the SVG: a hand-edited size: is otherwise raw
    # frontmatter text interpolated into markup.
    case "${_m_size[$dh_v]:-}" in XS|S|M|L|XL) dh_badge_txt="${_m_size[$dh_v]}" ;; *) dh_badge_txt=M ;; esac

    wb_board_v2_task_href "$dh_v" dh_href

    # ---- tooltip: "stem · status · size" [+ blocked-by] ----
    dh_title_tt="${dh_stemh2} &middot; ${dh_status_h} &middot; ${dh_badge_txt}"
    dh_extblk_html=""
    if [ -n "${dh_extblk[$dh_v]:-}" ]; then
      dh_extblk_disp="${dh_extblk[$dh_v]// /, }"
      wb_board_html_escape "$dh_extblk_disp" dh_extblk_h
      dh_title_tt+="; blocked by: ${dh_extblk_h}"
      # In the TOP row, between the id and the badge: a bottom corner
      # collides with the title on an XS card (only two rows there), while
      # the top row has room on every size and never touches the title,
      # status, or the above-card START/END pill.
      dh_extblk_html="<g class=\"dag-lock\" transform=\"translate($(( dh_w1 - 56 )),8)\"><title>blocked by: ${dh_extblk_h}</title><text x=\"0\" y=\"11\" font-size=\"13\">&#128274;</text></g>"
    fi

    # ---- START/END tag (above the card) ----
    dh_tag_html=""
    if [ -n "${dh_tag[$dh_v]:-}" ]; then
      local dh_tagtxt="${dh_tag[$dh_v]}" dh_tagw
      dh_tagw=$(( ${#dh_tagtxt} * 7 + 16 ))
      dh_tag_html="<g transform=\"translate(${dh_nx},$(( dh_ny - 24 )))\"><rect class=\"dag-tag-rect\" x=\"0\" y=\"0\" width=\"${dh_tagw}\" height=\"16\" rx=\"8\" ry=\"8\"/><text class=\"dag-tag-t\" x=\"$(( dh_tagw / 2 ))\" y=\"12\" text-anchor=\"middle\">${dh_tagtxt}</text></g>"
    fi

    # ---- in-progress pulse / startable static outline (mutually exclusive
    # in practice: startable only ever applies to a `planned` node) --------
    dh_pulse_html=""
    case "$dh_status_v" in
      doing|review)
        dh_pulse_html="<rect class=\"dag-pulse-ring\" x=\"-4\" y=\"-4\" width=\"$(( dh_w1 + 8 ))\" height=\"$(( dh_h1 + 8 ))\" rx=\"17\" ry=\"17\"/>" ;;
    esac
    dh_startable_html=""
    if [ "${dh_startable[$dh_v]:-0}" = 1 ]; then
      dh_startable_html="<rect class=\"dag-startable-ring\" x=\"-4\" y=\"-4\" width=\"$(( dh_w1 + 8 ))\" height=\"$(( dh_h1 + 8 ))\" rx=\"17\" ry=\"17\"/>"
    fi

    # ---- three non-overlapping rows — top (id [+ dot for XS]
    # left, size badge right), title (centred in whatever's left), and a
    # bottom status row (dot + label) EXCEPT for XS, which only has room for
    # two rows and drops the status row (keeping the dot, moved up next to
    # the id) rather than let it collide with the title. ---------------------
    if [ "${_m_size[$dh_v]:-}" = XS ]; then
      dh_bottomrowh=0
      dh_dot_html="<circle class=\"dag-dot\" cx=\"$(( 22 + (${#dh_short2} + dh_id_clipped) * 6 ))\" cy=\"11\" r=\"3.5\"/>"
      dh_status_html=""
    else
      dh_bottomrowh=18
      dh_dot_html="<circle class=\"dag-dot\" cx=\"16\" cy=\"$(( dh_h1 - 14 ))\" r=\"4\"/>"
      dh_status_html="<text class=\"dag-status-t\" x=\"26\" y=\"$(( dh_h1 - 10 ))\">${dh_status_h}</text>"
    fi
    dh_title_y=$(( dh_toprowh + (dh_h1 - dh_toprowh - dh_bottomrowh) / 2 + 4 ))

    dh_nodes_svg+="${dh_tag_html}<a href=\"${dh_href}\" target=\"_blank\" class=\"dag-node ${dh_cls}${dh_dashed}\" style=\"--st:var(--${dh_st_token})\"><title>${dh_title_tt}</title><g transform=\"translate(${dh_nx},${dh_ny})\">${dh_pulse_html}${dh_startable_html}<rect class=\"dag-card\" x=\"0\" y=\"0\" width=\"${dh_w1}\" height=\"${dh_h1}\" rx=\"14\" ry=\"14\"/><text class=\"dag-id\" x=\"10\" y=\"18\">${dh_sh2}</text><rect class=\"dag-badge\" x=\"$(( dh_w1 - 34 ))\" y=\"8\" width=\"26\" height=\"15\" rx=\"7\" ry=\"7\"/><text class=\"dag-badge-t\" x=\"$(( dh_w1 - 21 ))\" y=\"19\" text-anchor=\"middle\">${dh_badge_txt}</text><text class=\"dag-title\" x=\"$(( dh_w1 / 2 ))\" y=\"${dh_title_y}\" text-anchor=\"middle\">${dh_titleh}</text>${dh_dot_html}${dh_status_html}${dh_extblk_html}</g></a>"
  done

  # ---- pass 3: edges (drawn behind nodes, so emitted into a group placed
  # before the nodes group below) -------------------------------------------
  local dh_edges_svg="" dh_from dh_to dh_x1 dh_y1 dh_x2 dh_y2 dh_dx dh_c1x dh_c2x dh_e dh_ecls
  local -A dh_crit_pair=()
  local dh_j
  for (( dh_j=0; dh_j+1<${#dh_critpath[@]}; dh_j++ )); do
    dh_crit_pair["${dh_critpath[$dh_j]} ${dh_critpath[$(( dh_j + 1 ))]}"]=1
  done
  for dh_e in "${dh_edges[@]}"; do
    dh_from="${dh_e%% *}"; dh_to="${dh_e#* }"
    dh_x1=$(( dh_x[$dh_from] + dh_w[$dh_from] )); dh_y1=$(( dh_y[$dh_from] + dh_h[$dh_from] / 2 ))
    dh_x2="${dh_x[$dh_to]}"; dh_y2=$(( dh_y[$dh_to] + dh_h[$dh_to] / 2 ))
    dh_dx=$(( dh_x2 - dh_x1 )); dh_c1x=$(( dh_x1 + dh_dx / 2 )); dh_c2x=$(( dh_x2 - dh_dx / 2 ))
    dh_ecls="dag-edge"
    [ -n "${dh_crit_pair["$dh_from $dh_to"]:-}" ] && dh_ecls+=" dag-edge-crit"
    dh_edges_svg+="<path class=\"${dh_ecls}\" d=\"M ${dh_x1} ${dh_y1} C ${dh_c1x} ${dh_y1} ${dh_c2x} ${dh_y2} ${dh_x2} ${dh_y2}\" marker-end=\"url(#dag-arrow-${dh_anchor})\"/>"
  done
  for dh_e in "${dh_backedges[@]}"; do
    dh_from="${dh_e%% *}"; dh_to="${dh_e#* }"
    dh_x1=$(( dh_x[$dh_from] + dh_w[$dh_from] )); dh_y1=$(( dh_y[$dh_from] + dh_h[$dh_from] / 2 ))
    dh_x2="${dh_x[$dh_to]}"; dh_y2=$(( dh_y[$dh_to] + dh_h[$dh_to] / 2 ))
    dh_dx=$(( dh_x2 - dh_x1 )); dh_c1x=$(( dh_x1 + dh_dx / 2 )); dh_c2x=$(( dh_x2 - dh_dx / 2 ))
    dh_edges_svg+="<path class=\"dag-edge dag-edge-warn\" d=\"M ${dh_x1} ${dh_y1} C ${dh_c1x} ${dh_y1} ${dh_c2x} ${dh_y2} ${dh_x2} ${dh_y2}\" marker-end=\"url(#dag-arrow-${dh_anchor})\"/>"
  done

  local dh_anchor_h; wb_board_html_escape "$dh_anchor" dh_anchor_h
  local dh_svg="<div class=\"fam-dag-wrap\"><svg class=\"fam-dag\" viewBox=\"0 0 ${dh_svgw} ${dh_svgh}\" width=\"${dh_svgw}\" height=\"${dh_svgh}\" role=\"img\" aria-label=\"Dependency graph\"><defs><marker id=\"dag-arrow-${dh_anchor_h}\" viewBox=\"0 0 10 10\" refX=\"8.5\" refY=\"5\" markerWidth=\"7\" markerHeight=\"7\" orient=\"auto-start-reverse\"><path d=\"M0,0 L10,5 L0,10 z\" fill=\"context-stroke\"/></marker></defs>${dh_frontier_svg}<g class=\"dag-edges\">${dh_edges_svg}</g><g class=\"dag-nodes\">${dh_nodes_svg}</g></svg></div>"

  dh_out+="$dh_svg"
  printf -v "${15}" '%s' "$dh_out"
}
