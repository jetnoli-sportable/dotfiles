#!/usr/bin/env bash
# wb-board.sh — `wb board --html`'s renderer: collect + section/detail-card + render_html.
# Sourced by wb.sh the same way wb.sh sources lib.sh / wb-lifecycle.sh / wb-locks.sh —
# a sibling module (see wb-lifecycle.sh's own header for that convention), split out of
# wb.sh verbatim (parent task parked item 4) so the board rewrite doesn't grow the
# already-5600-line wb.sh further.

# ---------------------------------------------------------------------------
# /board (wb board --html) — 6 status tabs, timeline window, live-session
# badges. `wb board` with no flag keeps the plain-text table below unchanged.
# ---------------------------------------------------------------------------

# wb_board_bucket_for_status <status> — maps a raw task status to one of the
# 6 tabs' underlying buckets. `done` is a real bucket (used by the All tab)
# but has no tab of its own — see R8/R9. `prospective` (R25) likewise gets
# its own named bucket rather than falling into the `unclassified` catch-all
# — a demoted/captured task must stay distinguishable from an untracked
# worktree, even before `feat-board-build` gives it a dedicated tab/shelf.
# Anything ELSE unrecognized falls to `unclassified`, which remains a
# deliberate catch-all, not a bug.

# wb_board_live_session_for <repo> <branch> — the live tmux session name for
# this repo/branch, or empty. Same @wb_repo/@wb_slug lookup the picker's
# wb_live_session_row already does (wb.sh:627-653) — a live-session badge is
# an annotation on every row, independent of which tab it's in (R11).
wb_board_live_session_for() {
  local repo="$1" branch="$2" s r b
  while IFS= read -r s; do
    [ -n "$s" ] || continue
    r="$(tmux show -t "=$s:" -v @wb_repo 2>/dev/null || true)"
    b="$(tmux show -t "=$s:" -v @wb_slug 2>/dev/null || true)"
    if [ "$r" = "$repo" ] && [ "$b" = "$branch" ]; then
      printf '%s' "$s"
      return 0
    fi
  done < <(tmux list-sessions -F '#{session_name}' 2>/dev/null)
}

# wb_task_activity <repo> <branch> <worktree_rel> [<live_session>] — U6/R7:
# the derived active|dormant|cold classification, factored out of
# wb_board_render_html's pre-pass and cmd_board's ACT column (both computed
# the same three-way check independently before this). <worktree_rel> is
# the relative path stored in a task's `worktree:` frontmatter field. Pass
# <live_session> when the caller already looked it up (wb_board_live_session_for's
# tmux query is not free) to avoid repeating that lookup; omit it to have
# this function do the lookup itself.
wb_task_activity() {
  local repo="$1" branch="$2" worktree_rel="$3" live_session
  if [ $# -ge 4 ]; then live_session="$4"; else live_session="$(wb_board_live_session_for "$repo" "$branch")"; fi
  if [ -n "$live_session" ]; then
    printf 'active\n'
  elif [ -n "$worktree_rel" ] \
       && [ -n "$(wb_transcripts "$(wb_repo_dir "$repo")/$worktree_rel" 2>/dev/null)" ]; then
    printf 'dormant\n'
  else
    printf 'cold\n'
  fi
}

# wb_board_html_escape <string> — minimal HTML-entity escaping for table
# cells, anchor text and attribute values built from task titles/branches,
# which can contain `<`/`&`/`"` (R12's escaping test scenario; `"` added for
# board-display-v2's KTD-9 — blocked/unblocks tooltips put task titles and
# statuses inside `title="…"` attributes, which the original `&<>`-only
# escaping left open to attribute injection).
wb_board_html_escape() {
  local s="$1"
  # `&` in a bash pattern-substitution REPLACEMENT is a backreference to the
  # match (same as sed) — unescaped, `${s//</&lt;}` produces "<lt;" (match
  # `<` + literal "lt;") instead of "&lt;". `\&` forces a literal ampersand.
  s="${s//&/\&amp;}"; s="${s//</\&lt;}"; s="${s//>/\&gt;}"; s="${s//\"/\&quot;}"
  # fix(perf, U5/U6): optional <out_var> ($2, D2A's convention) — the Family
  # view calls this per family member/decision/artifact (hundreds of times
  # across the store), so a `$(...)` subshell here is the same per-call
  # fork cost U2's own timing notes warn against; stdout fallback preserves
  # every existing call site unchanged.
  if [ -n "${2:-}" ]; then printf -v "$2" '%s' "$s"; else printf '%s' "$s"; fi
}

# wb_board_section <file> <heading> — body lines under "## <heading>" up to
# the next "## " heading (or EOF). Same convention wb_sweep_section already
# uses for the "## Sweep" section, generalized to any named section.
#
# General-purpose, NOT board-only despite the name — U4's cutover almost
# deleted this as an orphaned old-renderer helper (nothing in the board
# render path calls it any more) before a full-codebase grep caught real
# callers elsewhere: wb_reconcile_merge_content's Plan/Done/Follow-ups
# section merge (wb.sh) and wb-breakdown's Plan/Follow-ups diffing
# (wb.sh). Keep this one wherever it lives; check callers repo-wide, not
# just within board2, before ever removing it again.
wb_board_section() {
  awk -v h="## $2" '
    $0 == h { insec = 1; next }
    /^## / { insec = 0 }
    insec { print }
  ' "$1"
}

# wb_board_first_nonblank_line <text> — first non-whitespace-only line of
# <text>, or empty. Deliberately NOT `... | sed ... | head -1`: under this
# script's `set -o pipefail`, head closing the pipe after its first line
# sends SIGPIPE to whatever's still writing upstream (real task files often
# have multi-line Plan/Done sections, unlike this repo's short test
# fixtures, which is exactly why this shipped without tripping any test).
# A here-string loop reads a value already fully captured in memory, so
# breaking out of it early has no live process left to SIGPIPE.
wb_board_first_nonblank_line() {
  # fix(review) D2A: optional <out_var> ($2) for plain-statement calls;
  # stdout fallback preserves existing callers.
  local line __r=""
  while IFS= read -r line; do
    if [ -n "${line//[[:space:]]/}" ]; then __r="$line"; break; fi
  done <<< "$1"
  if [ -n "${2:-}" ]; then printf -v "$2" '%s' "$__r"; else printf '%s' "$__r"; fi
}

# wb_board_pr_display <pr_info> — the "#<n> (<state>)" half of a
# wb_board_pr_info string (safe to call on an untabbed legacy-shaped string
# too — a stub or test fixture that doesn't bother with the URL half).
wb_board_pr_display() { printf '%s' "${1%%$'\t'*}"; }

# wb_board_doc_candidates <taskfile> — raw docs/plans, docs/brainstorms,
# docs/solutions, docs/ideation, or logs/decisions paths the task's own
# prose names (this repo's established convention — see e.g.
# ~/code/tasks/*.md's "## Decisions" sections — is a plain-text path,
# sometimes backtick-wrapped, sometimes prefixed `dotfiles/`, not a markdown
# link). Regex extraction only, no existence check — existence differs by
# caller: wb_board_related_docs checks the filesystem, wb_lifecycle_has_doc's
# prose half checks a worktree OR (kept-branch fallback) a git blob. KTD-4:
# every path-detection stage addition updates this pattern — a standing
# invariant, not a one-off.
wb_board_doc_candidates() {
  local taskfile="$1"
  [ -f "$taskfile" ] || return 0
  grep -oP '(?:dotfiles/)?(?:docs/(?:plans|brainstorms|solutions|ideation)|logs/decisions)/[A-Za-z0-9._/-]+\.(?:md|html)' "$taskfile" 2>/dev/null \
    | sed 's#^dotfiles/##' | sort -u
}

# wb_board_parse_deps <depends_on_raw> — comma-separated blocker stems, one
# per line, whitespace-tolerant, empty entries dropped, duplicates dropped
# (mirrors wb_lifecycle_parse_path's dedup — a repeated stem must not
# double-count the ⛔/→ dependency chips). Render-tolerant like path:
# parsing — a hand-edited depends_on: must never crash the render; an
# unresolvable stem is the caller's problem (R18 fail-open), not this
# parser's.
wb_board_parse_deps() {
  # fix(review) D2A: optional <out_var> ($2) for plain-statement calls in the
  # render's full-store loop; stdout fallback preserves existing/test callers.
  # Output is newline-joined stems (the shape DEPS_OF stores and the deps
  # helpers read back), unchanged from the old stdout form.
  local raw="${1:-}" tok __out=""
  if [ -n "$raw" ]; then
    local -a tokens
    IFS=',' read -ra tokens <<< "$raw"
    local -A seen=()
    for tok in "${tokens[@]}"; do
      tok="${tok#"${tok%%[![:space:]]*}"}"; tok="${tok%"${tok##*[![:space:]]}"}"
      if [ -n "$tok" ] && [ -z "${seen[$tok]:-}" ]; then
        seen["$tok"]=1
        __out+="$tok"$'\n'
      fi
    done
  fi
  if [ -n "${2:-}" ]; then printf -v "$2" '%s' "$__out"; else printf '%s' "$__out"; fi
}

# wb_board_normalize_loop <space-separated stems> — sorts and dedupes the
# given cycle-member stems, then joins them starting at the
# lexicographically smallest one and closing the loop back to it (KTD-6),
# so every member of the same cycle renders an identical warning string
# regardless of which member's perspective it's shown from.
wb_board_normalize_loop() {
  local -a stems=($1)
  local -a sorted; mapfile -t sorted < <(printf '%s\n' "${stems[@]}" | sort -u)
  [ "${#sorted[@]}" -gt 0 ] || return 0
  local out="${sorted[0]}" i
  for (( i=1; i<${#sorted[@]}; i++ )); do out+=" -> ${sorted[$i]}"; done
  out+=" -> ${sorted[0]}"
  printf '%s' "$out"
}

# wb_board_deps_validate <deps_of_arr> <stem_anchor_arr> <dangling_warn_arr>
# — R18's dangling-stem half. Takes ASSOCIATIVE ARRAY NAMES (nameref-bound,
# same pattern as wb_tsv_split's array-name parameter), not values, since
# it mutates <deps_of_arr> in place (dropping any stem with no matching
# task file) and writes <dangling_warn_arr> — a task with a dangling
# depends_on: fails open (renders unblocked) with a warning naming the
# unresolvable stem, rather than crashing or silently misrendering.
wb_board_deps_validate() {
  local -n _deps_of="$1" _stem_anchor="$2" _dangling_warn="$3"
  local pp_a pp_dep_line
  for pp_a in "${!_deps_of[@]}"; do
    [ -n "${_deps_of["$pp_a"]}" ] || continue
    local -a pp_valid=() pp_missing=()
    while IFS= read -r pp_dep_line; do
      [ -n "$pp_dep_line" ] || continue
      if [ -n "${_stem_anchor["$pp_dep_line"]:-}" ]; then
        pp_valid+=("$pp_dep_line")
      else
        pp_missing+=("$pp_dep_line")
      fi
    done <<< "${_deps_of["$pp_a"]}"
    if [ "${#pp_missing[@]}" -gt 0 ]; then
      local pp_missing_joined; pp_missing_joined="$(IFS=', '; echo "${pp_missing[*]}")"
      _dangling_warn["$pp_a"]="depends on unresolved stem: $pp_missing_joined"
    fi
    _deps_of["$pp_a"]="$(printf '%s\n' "${pp_valid[@]}")"
  done
}

# wb_board_deps_cycles <deps_of_arr> <stem_anchor_arr> <anchor_stem_arr>
#   <cycle_member_arr> <cycle_warn_arr> — R18's cycle half, KTD-12: an
# iterative, flat BFS reachability walk (no recursion) over the (already
# dangling-free — run wb_board_deps_validate first) dependency map. An
# anchor is on a cycle iff it can reach its own stem again via >=1 blocker
# edge. Writes <cycle_member_arr> (anchor -> 1) and <cycle_warn_arr>
# (anchor -> normalized loop string, KTD-6): every OTHER cycle member
# reachable from this one, sorted lexicographically and closed back to the
# smallest — a simplification for graphs with more than one independent
# cycle (would lump distinct cycles that happen to overlap in
# reachability), acceptable for a warning message on what is, today, a
# zero-occurrence edge case.
wb_board_deps_cycles() {
  local -n _deps_of="$1" _stem_anchor="$2" _anchor_stem="$3" _cycle_member="$4" _cycle_warn="$5"
  local pp_a pp_a_stem pp_cur pp_cur_anchor pp_qi pp_hit pp_line
  for pp_a in "${!_deps_of[@]}"; do
    [ -n "${_deps_of["$pp_a"]:-}" ] || continue
    pp_a_stem="${_anchor_stem["$pp_a"]}"
    local -A pp_seen=()
    local -a pp_queue=()
    while IFS= read -r pp_line; do [ -n "$pp_line" ] && pp_queue+=("$pp_line"); done <<< "${_deps_of["$pp_a"]}"
    pp_qi=0; pp_hit=0
    while [ "$pp_qi" -lt "${#pp_queue[@]}" ]; do
      pp_cur="${pp_queue[$pp_qi]}"; pp_qi=$((pp_qi + 1))
      [ -n "${pp_seen["$pp_cur"]:-}" ] && continue
      pp_seen["$pp_cur"]=1
      if [ "$pp_cur" = "$pp_a_stem" ]; then pp_hit=1; break; fi
      pp_cur_anchor="${_stem_anchor["$pp_cur"]:-}"
      [ -n "$pp_cur_anchor" ] || continue
      while IFS= read -r pp_line; do [ -n "$pp_line" ] && pp_queue+=("$pp_line"); done <<< "${_deps_of["$pp_cur_anchor"]:-}"
    done
    [ "$pp_hit" = 1 ] && _cycle_member["$pp_a"]=1
  done
  for pp_a in "${!_cycle_member[@]}"; do
    pp_a_stem="${_anchor_stem["$pp_a"]}"
    local -A pp_seen2=()
    local -a pp_queue2=() pp_members=("$pp_a_stem")
    pp_seen2["$pp_a_stem"]=1
    while IFS= read -r pp_line; do [ -n "$pp_line" ] && pp_queue2+=("$pp_line"); done <<< "${_deps_of["$pp_a"]}"
    pp_qi=0
    while [ "$pp_qi" -lt "${#pp_queue2[@]}" ]; do
      pp_cur="${pp_queue2[$pp_qi]}"; pp_qi=$((pp_qi + 1))
      [ -n "${pp_seen2["$pp_cur"]:-}" ] && continue
      pp_seen2["$pp_cur"]=1
      pp_cur_anchor="${_stem_anchor["$pp_cur"]:-}"
      [ -n "$pp_cur_anchor" ] || continue
      [ -n "${_cycle_member["$pp_cur_anchor"]:-}" ] && pp_members+=("$pp_cur")
      while IFS= read -r pp_line; do [ -n "$pp_line" ] && pp_queue2+=("$pp_line"); done <<< "${_deps_of["$pp_cur_anchor"]:-}"
    done
    _cycle_warn["$pp_a"]="$(wb_board_normalize_loop "${pp_members[*]}")"
  done
}

# wb_board_deps_blocking <deps_of_arr> <stem_anchor_arr> <stem_status_arr>
#   <anchor_stem_arr> <cycle_member_arr> <unmet_count_arr> <blocker_names_arr>
#   <unblocks_count_arr> <unblocks_names_arr> — R16/R17/R18's blocked-state
# half, from the validated (wb_board_deps_validate), cycle-free
# (wb_board_deps_cycles) dependency edges. A cycle warning supersedes the
# ⛔ blocked treatment for its own members (KTD-6) — a cycle member never
# gets an unmet count of its own (guarded below, at the final write only),
# but its outgoing edges still get walked so a non-cycle blocker it also
# depends on still gets credited in _unblocks_count/_unblocks_names — that
# direction is the blocker's own independent fact, unaffected by whether
# the dependent happens to also sit on an unrelated cycle.
wb_board_deps_blocking() {
  local -n _deps_of="$1" _stem_anchor="$2" _stem_status="$3" _anchor_stem="$4" _cycle_member="$5"
  local -n _unmet_count="$6" _blocker_names="$7" _unblocks_count="$8" _unblocks_names="$9"
  local pp_a pp_a_stem pp_line pp_unmet pp_names pp_blocker_status pp_blocker_anchor
  for pp_a in "${!_deps_of[@]}"; do
    [ -n "${_deps_of["$pp_a"]:-}" ] || continue
    pp_a_stem="${_anchor_stem["$pp_a"]}"
    pp_unmet=0; pp_names=""
    while IFS= read -r pp_line; do
      [ -n "$pp_line" ] || continue
      pp_blocker_status="${_stem_status["$pp_line"]:-}"
      [ "$pp_blocker_status" = done ] && continue
      pp_unmet=$((pp_unmet + 1))
      pp_names+="$pp_line ($pp_blocker_status); "
      pp_blocker_anchor="${_stem_anchor["$pp_line"]:-}"
      [ -n "$pp_blocker_anchor" ] || continue
      _unblocks_count["$pp_blocker_anchor"]=$(( ${_unblocks_count["$pp_blocker_anchor"]:-0} + 1 ))
      _unblocks_names["$pp_blocker_anchor"]+="$pp_a_stem, "
    done <<< "${_deps_of["$pp_a"]}"
    if [ -z "${_cycle_member["$pp_a"]:-}" ] && [ "$pp_unmet" -gt 0 ]; then
      _unmet_count["$pp_a"]="$pp_unmet"
      _blocker_names["$pp_a"]="$pp_names"
    fi
  done
}

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
# below) was measured adding ~2s to a ~11.5s render — see U5's own perf
# note at its call site.
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
      dh_short="$dh_v"
      if [ -n "$dh_strip" ] && [[ "$dh_v" == "$dh_strip"* ]]; then
        dh_short="${dh_v#"$dh_strip"}"; dh_short="${dh_short#-}"
        [ -n "$dh_short" ] || dh_short="$dh_v"
      fi
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
    local dh_fx=$(( dh_marginl + dh_frontier_layer * dh_colw - dh_colw / 2 - 4 ))
    dh_frontier_svg="<line class=\"dag-frontier\" x1=\"${dh_fx}\" y1=\"12\" x2=\"${dh_fx}\" y2=\"$(( dh_svgh - 8 ))\"/><text class=\"dag-frontier-lbl\" x=\"${dh_fx}\" y=\"$(( dh_svgh - 14 ))\" text-anchor=\"middle\">&#9656; YOU ARE HERE</text>"
  fi

  # ---- pass 2: node markup -------------------------------------------------
  local dh_nodes_svg="" dh_cls dh_st_token dh_dashed dh_sig dh_planraw
  local dh_short2 dh_sh2 dh_stemh2 dh_titleh dh_title_clip dh_title_raw dh_maxchars dh_href dh_enc
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
    [ -n "${dh_planraw//[[:space:]]/}" ] && dh_sig=$(( dh_sig + 1 ))
    [ "${_m_accept[$dh_v]:-0}" = 1 ] && dh_sig=$(( dh_sig + 1 ))
    [ -n "${_m_size[$dh_v]:-}" ] && dh_sig=$(( dh_sig + 1 ))
    case "$dh_status_v" in doing|review|done) dh_sig=$(( dh_sig + 1 )) ;; esac
    if [ "$dh_status_v" != done ] && [ "$dh_sig" -lt 3 ]; then dh_dashed=" dag-dashed"; else dh_dashed=""; fi

    [ "${dh_critical[$dh_v]:-0}" = 1 ] && dh_cls+=" dag-crit-node"
    [ "${dh_startable[$dh_v]:-0}" = 1 ] && dh_cls+=" dag-startable"

    # ---- short label (mono, top-left) ----
    dh_short2="$dh_v"
    if [ -n "$dh_strip" ] && [[ "$dh_v" == "$dh_strip"* ]]; then
      dh_short2="${dh_v#"$dh_strip"}"; dh_short2="${dh_short2#-}"
      [ -n "$dh_short2" ] || dh_short2="$dh_v"
    fi
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

    # ---- title: card-width-derived clip, single-char ellipsis (review fix
    # 1 — wb_board_v2_clip is the prose-block clipper with a long
    # "[clipped — open the task file for the rest]" suffix, which overflows
    # a card; this is a SHORT, card-specific clip instead). ~7px/char at the
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

    # ---- status label (bottom row; review fix 2 — dropped entirely for XS,
    # which only has room for two rows: id/badge, then title) --------------
    dh_status_txt="${dh_status_v:-unknown}"
    wb_board_html_escape "$dh_status_txt" dh_status_h

    # ---- size badge (top-right) ----
    dh_badge_txt="${_m_size[$dh_v]:-M}"

    # ---- href (same shape as wb_board_v2_task_open_html) ----
    wb_board_v2_url_escape "$dh_v" dh_enc
    wb_board_html_escape "$dh_enc" dh_enc
    dh_href="${TASK_HREF_PREFIX}${dh_enc}.md"

    # ---- tooltip: "stem · status · size" [+ blocked-by] ----
    dh_title_tt="${dh_stemh2} &middot; ${dh_status_h} &middot; ${dh_badge_txt}"
    dh_extblk_html=""
    if [ -n "${dh_extblk[$dh_v]:-}" ]; then
      dh_extblk_disp="${dh_extblk[$dh_v]// /, }"
      wb_board_html_escape "$dh_extblk_disp" dh_extblk_h
      dh_title_tt+="; blocked by: ${dh_extblk_h}"
      # review fix 3 (round 2): the bottom-right corner collided with the
      # title on an XS card (only 2 rows there, title runs closer to the
      # edge). The TOP row has room on every size — id (+ dot, XS only) on
      # the left, badge on the right, both narrow — so the lock sits
      # between them, vertically aligned with the badge's own baseline;
      # never touches the title row, the status row, or the (above-card)
      # START/END pill.
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

    # ---- review fix 2: three non-overlapping rows — top (id [+ dot for XS]
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

# wb_board_v2_fill_template <template> <tokens_assoc_name> <out_var> —
# substitute every @@TOKEN@@ in <template> with <tokens_assoc>[TOKEN], in a
# single left-to-right walk of the TEMPLATE, appending each fragment to the
# output verbatim.
#
# Why not the obvious `${page_template//@@TOKEN@@/$value}` chain it
# replaced (see wb_board_render_v2's page-assembly comment for the full
# rationale): that chain rescanned the whole, growing page once per token —
# ~650KB by the last pass, and `${var//}` is measurably non-linear in size
# — and, worse, rescanned already-substituted CONTENT, so a task title
# holding a literal `@@FOO@@` corrupted the page. Here, content never
# re-enters the scan.
#
# An unknown token is emitted literally (`@@FOO@@`), which is loud rather
# than silently blanking a region of the page. An odd trailing `@@` with no
# closer is likewise passed through unchanged.
wb_board_v2_fill_template() {
  local __tpl="$1"
  local -n __tok="$2"
  local __out="" __head __name __rest="$__tpl"
  while [ -n "$__rest" ]; do
    case "$__rest" in
      *'@@'*) ;;
      *) __out+="$__rest"; __rest=""; break ;;
    esac
    __head="${__rest%%@@*}"
    __rest="${__rest#*@@}"
    case "$__rest" in
      *'@@'*)
        __name="${__rest%%@@*}"
        # Only a bare NAME between the markers is a token; anything with a
        # newline or another `@@` in it is prose that happens to contain
        # `@@`, and is passed through.
        if [[ "$__name" =~ ^[A-Z0-9_]+$ ]] && [ -n "${__tok[$__name]+x}" ]; then
          __out+="$__head${__tok[$__name]}"
          __rest="${__rest#*@@}"
        else
          __out+="${__head}@@"
        fi
        ;;
      *) __out+="${__head}@@${__rest}"; __rest="" ;;
    esac
  done
  printf -v "$3" '%s' "$__out"
}


# ===========================================================================
# board2 (feat-board-build, U2/U3/U4) — single-pass collect + in-memory
# model + renderer for the ratified 3-view board. Originally built as a NEW
# path alongside the old wb_board_collect_rows/wb_board_render_html (D1's
# parity-then-cutover plan) rather than an extension of them — U4's cutover
# has since confirmed parity and deleted that old renderer entirely, so
# this is now simply THE board renderer, not a parallel "v2" track.
# ===========================================================================

# wb_board_v2_anchor <stem> — same sanitization the old, now-deleted
# wb_board_anchor_slug used (every char outside [A-Za-z0-9_-] -> '-'), but
# pure bash parameter expansion instead of that function's `printf | tr`
# pipe. Not a style preference: this runs once per task in board2's single-
# pass loop (~300 files on the real store today), and the pipe's two forks
# per call were real, measured cost — see the timing note on
# wb_board_collect_rows_v2 below. Was verified byte-identical to that old
# function's output for every character class it handles (ASCII,
# punctuation, empty string) before it was removed in U4's cutover.
# fix(review) D3: unique-by-construction. The sanitizer maps every char outside
# [A-Za-z0-9_-] to '-', so two DISTINCT stems differing only by '.'-vs-punct
# (foo.bar vs foo-bar) used to collapse to ONE id — and U8's shared #detail-pool
# getElementById('detail-'+anchor) would then mount the WRONG task's detail block
# (same for card-/lane-/fam- ids). Now the first stem to claim a base keeps it
# byte-identical to before (no collision exists in real/test data today), and a
# later distinct stem that collides on that base gets a '-2'/'-3'/... suffix.
# Memoized per stem (WB_BOARD_ANCHOR_FOR) so the anchor is a stable function of
# the stem within one render — every call site (collect, deps, the ~15 render
# sites) sees the same value; WB_BOARD_ANCHOR_USED is the cross-stem collision
# set. Both are reset per render at the top of wb_board_collect_rows_v2.
declare -gA WB_BOARD_ANCHOR_FOR=() WB_BOARD_ANCHOR_USED=()
wb_board_v2_anchor() {
  # fix(review) D2A: optional <out_var> so the collect loop can call this as a
  # plain statement (printf -v, no subshell) instead of `$(...)`; stdout
  # fallback keeps existing/test callers working.
  local __key="$1" __a __base
  if [ -n "${WB_BOARD_ANCHOR_FOR["$__key"]+x}" ]; then
    __a="${WB_BOARD_ANCHOR_FOR["$__key"]}"
  else
    __base="${1//[^A-Za-z0-9_-]/-}"; __a="$__base"
    if [ -n "${WB_BOARD_ANCHOR_USED["$__a"]+x}" ]; then
      local __n=2
      while [ -n "${WB_BOARD_ANCHOR_USED["${__base}-${__n}"]+x}" ]; do __n=$((__n + 1)); done
      __a="${__base}-${__n}"
    fi
    WB_BOARD_ANCHOR_FOR["$__key"]="$__a"; WB_BOARD_ANCHOR_USED["$__a"]=1
  fi
  if [ -n "${2:-}" ]; then printf -v "$2" '%s' "$__a"; else printf '%s' "$__a"; fi
}

# wb_board_v2_age_days <mtime_epoch> <now_epoch> — whole days between them,
# R21's staleness clock. Floor division (bash integer arithmetic), so
# "13d 23h" reports as 13, not 14 — matches the U2 test scenario's 13d/14d
# boundary ("13d does not [classify stale]"). Takes <now_epoch> as a
# parameter rather than calling `date +%s` itself: the collect loop below
# forks `date` exactly once for the whole pass and passes it in, not once
# per task (a real, measured cost at ~300 files — see the timing note on
# wb_board_collect_rows_v2).
wb_board_v2_age_days() {
  # fix(review) D2A: optional <out_var> ($3) for plain-statement calls.
  local __d=$(( ("$2" - "$1") / 86400 ))
  if [ -n "${3:-}" ]; then printf -v "$3" '%s' "$__d"; else printf '%s\n' "$__d"; fi
}

# wb_board_v2_bucket <status> <age_days> — R23's single active/stale/shelved
# definition, computed once here so every view (rail counts, Active deck,
# Roadmap readiness, Week) reads the same partition instead of re-deriving
# it. Deliberately only 3 values, no 4th "done"/"next" bucket: R23's test
# scenario requires active+stale+shelved to total the whole store, so a
# planned/paused/prospective/done task must land in "shelved" (not actively
# being worked) rather than falling through uncounted. The sidebar's Next-
# vs-Shelf presentational split (U3) is a further distinction WITHIN
# shelved (status == planned vs not), not a 4th bucket here.
wb_board_v2_bucket() {
  # fix(review) D2A: optional <out_var> ($3) for plain-statement calls.
  local status="$1" age_days="$2" __b
  if [ "$status" = doing ] || [ "$status" = review ]; then
    if [ "$age_days" -ge 14 ]; then __b=stale; else __b=active; fi
  else
    __b=shelved
  fi
  if [ -n "${3:-}" ]; then printf -v "$3" '%s' "$__b"; else printf '%s' "$__b"; fi
}

# wb_board_v2_family_root <stem> <stem_parent_arrayname> — walks the
# parent: chain (STEM_PARENT, built by the same single pass below) to its
# root ancestor, bounded to 50 hops so a hand-edited parent: cycle can never
# spin the render loop forever (fail-open to the stem itself, same
# tolerance-for-bad-frontmatter posture as wb_board_parse_deps).
#
# Nameref param deliberately named `_fr_sp`, NOT `_stem_parent` — a caller
# one frame up (wb_board_build_model) also binds a local nameref literally
# named `_stem_parent`; passing that name straight through here would make
# bash resolve this function's own `-n _stem_parent` against itself
# ("circular name reference") instead of the real backing array. Any two
# nameref parameter names that collide across a call chain hit this, not
# just this pair — kept distinct on purpose.
wb_board_v2_family_root() {
  local -n _fr_sp="$2"
  local cur="$1" hops=0 seen_key
  local -A seen=()
  while [ -n "${_fr_sp["$cur"]:-}" ] && [ "$hops" -lt 50 ]; do
    seen_key="$cur"
    [ -n "${seen["$seen_key"]:-}" ] && break   # cycle guard
    seen["$seen_key"]=1
    cur="${_fr_sp["$cur"]}"
    hops=$((hops + 1))
  done
  printf '%s' "$cur"
}

# wb_board_v2_read_file <file> — THE single-read primitive (R16): one awk
# process reads <file> ONCE and extracts frontmatter + the Plan/Done/
# Handoffs/Follow-ups body sections together, instead of the fork-per-field/
# fork-per-section style wb_read_task + wb_task_title + wb_get_frontmatter +
# wb_board_section(xN) would cost if called separately for every task (an
# early real-store timing run at ~300 tasks measured that fragmented
# approach at ~3600 forked processes and 16.7s wall-clock — over the R15
# budget; this collapses it to one process per file).
#
# Output on stdout, consumed only by wb_board_v2_parse_record below (never
# hand-parsed at a call site): 7 fields joined by a bare SOH byte (\001, a
# byte that cannot appear in a markdown task file's prose, so no escaping
# is ever needed) — field order is fixed, not labeled, since the caller
# always wants all seven:
#   1 the frontmatter/plan-count TSV line: status \t repo \t worktree \t
#     branch \t path \t deps \t reviewed \t parent \t tags \t created \t
#     closed \t plan_checked \t plan_total \t title \t <stage signal bits
#     "ibpwr" (U7)> \t pr_url \t size \t accept_sig — size/accept_sig (U2,
#     KTD8) are APPENDED AT THE END, after pr_url, so no earlier positional
#     reader needs renumbering
#   2 raw Plan section text
#   3 raw Done section text
#   4 raw Handoff text — the LAST "### " block under "## Handoffs" (heading
#     line included)
#   5 raw Follow-ups section text
#   6 raw Decisions section text (U5, PR2 — the family view's decisions
#     timeline source; unused by U3's 3 views)
#   7 doc/artifact-link candidates, one per line — every line of the WHOLE
#     file (not just Decisions) matching a dossiers/docs-plans/logs-decisions
#     path or a claude.ai URL (U5, PR2 — the family view's artifact links).
#     Scanned unconditionally alongside the section capture above so this
#     stays a single pass (R16) even though link mentions aren't confined to
#     one "## " section in practice (a Decisions entry, a Follow-up, or Plan
#     prose can all cite a doc). Extracted, not just the matching line, so
#     the family-rollup code never re-parses these lines itself.
# An earlier version labeled each field with its own SOH-wrapped sentinel
# line and had wb_board_v2_parse_record split on those with `${var%%pat*}`/
# `${var#*pat}` parameter expansion — correct, but measured at ~10ms/call
# across the real store (pure bash, no forking, but apparently expensive
# glob-pattern matching against a pattern built from concatenated quoted
# expansions). A plain `IFS=$soh read -r -d '"'"''"'"' -a parts` split
# (below) measured over 2x faster on the same data, so the labels were
# dropped — they only existed to make that old split self-documenting.
wb_board_v2_read_file() {
  awk '
    function clip(s) { sub(/[ \t]+#.*$/, "", s); sub(/[ \t]+$/, "", s); return s }
    function extract_links(line,    s) {
      # U5: pull every dossiers/docs-plans-etc path or claude.ai URL out of
      # <line>, appended one per line to links_text. A while(match()) loop
      # (not a single match) so a line citing two paths (rare but real —
      # see e.g. task files pairing a plan with its decision buffer) yields
      # both, not just the first.
      s = line
      while (match(s, linkre)) {
        links_text = links_text substr(s, RSTART, RLENGTH) "\n"
        s = substr(s, RSTART + RLENGTH)
      }
    }
    # wb_board_v2_scan_accept (U2, KTD7) — the acceptance-criteria/
    # definition-of-done signal that feeds M_ACCEPT. Matched case-
    # insensitively (`tolower($0)`), unlike scan_signals below (whose
    # fixed markers are literal paths/commands and stay case-sensitive on
    # purpose) — a hand-written "Acceptance Criteria" or "Definition of
    # Done" heading is exactly the kind of prose that varies in casing.
    # Matched ANYWHERE in the file body (not confined to "## Plan" the way
    # plan_checked/plan_total are), per KTD7 — a Follow-ups bullet naming
    # "Definition of Done" is just as real a signal as a dedicated section.
    # The bare word "acceptance" alone must NOT match (too many false
    # positives — "acceptance" appears in ordinary prose unrelated to a
    # criteria list); only the two full phrases, or a "## DoD"-shaped
    # heading, count.
    function scan_accept(line,    lc) {
      lc = tolower(line)
      if (index(lc, "acceptance criteria") || index(lc, "definition of done")) accept_sig = 1
      else if (lc ~ /^##[ \t]*dod([ \t]|$)/) accept_sig = 1
    }
    # Lifecycle-stage signals (U7). wb-lifecycle.sh owns the stage MODEL
    # (order, the four states, the resolver) and this reuses it, but its
    # detectors shell out to git/tmux/gh once per task, which R16 forbids in
    # the render path. Every signal the board needs is a text fact already
    # sitting in the file this awk is reading, so it is collected here, in
    # the one pass, for free. `index()` (a substring scan) not a regex for
    # the fixed markers: this runs on every line of every task file.
    function scan_signals(line) {
      if (index(line, "docs/ideation/")    || index(line, "/ce-ideate"))     sig_ideate = 1
      if (index(line, "docs/brainstorms/") || index(line, "/ce-brainstorm")) sig_brainstorm = 1
      if (index(line, "docs/plans/")       || index(line, "/ce-plan"))       sig_plan = 1
      if (index(line, "/ce-work")          || index(line, "/goal"))          sig_work = 1
      if (index(line, "/ce-code-review"))                                    sig_review = 1
      # First PR URL wins, and a PR is itself evidence work started (the
      # same AE1 reasoning wb_lifecycle_stage_state uses).
      if (index(line, "github.com/") && match(line, prre)) {
        if (pr_url == "") pr_url = substr(line, RSTART, RLENGTH)
        sig_work = 1
      }
    }
    BEGIN {
      SOH = sprintf("%c", 1)
      status=""; repo=""; worktree=""; branch=""; path=""; deps=""
      reviewed=""; parent=""; tags=""; created=""; closed=""; title=""
      size=""
      infm = 0; donefm = 0; cursec = ""; handoff_capturing = 0; title_found = 0
      plan_checked = 0; plan_total = 0
      sig_ideate = 0; sig_brainstorm = 0; sig_plan = 0; sig_work = 0
      sig_review = 0; pr_url = ""; accept_sig = 0
      prre = "https://github\\.com/[A-Za-z0-9._-]+/[A-Za-z0-9._-]+/pull/[0-9]+"
      # dossiers/*.md|html, docs/{plans,brainstorms,solutions,ideation}/*.md|html,
      # logs/decisions/*.md|html, or a claude.ai URL — same path shapes
      # wb_board_doc_candidates already looks for (plus dossiers/ and
      # claude.ai, which that function does not — U5 needs both since the
      # decision-buffer/dossier convention lives under dossiers/, not
      # logs/decisions/, in this store).
      linkre = "(dossiers/[A-Za-z0-9._/-]+\\.(md|html))|(docs/(plans|brainstorms|solutions|ideation)/[A-Za-z0-9._/-]+\\.(md|html))|(logs/decisions/[A-Za-z0-9._/-]+\\.(md|html))|(https://claude\\.ai/[A-Za-z0-9._/-]+)"
    }
    # wb_task_title <file> equivalent (first "# <heading>" line anywhere in
    # the file, single "#" only — "## Plan" etc. never match) — folded in
    # here so the collect loop below doesn'\''t fork a second awk per file
    # just for the title.
    # A tab in the title would shift every field appended after it in the
    # TSV below, so it is neutralised at capture (a tab in a markdown H1 is
    # not meaningful text anyway).
    !title_found && /^# / { title = $0; sub(/^# /, "", title); gsub(/\t/, " ", title); title_found = 1 }
    { extract_links($0); scan_signals($0); scan_accept($0) }
    /^---$/ { infm++; if (infm == 2) donefm = 1; next }
    infm == 1 && !donefm {
      if ($0 ~ /^status:/)      { s=$0; sub(/^status:[ \t]*/,"",s);      status=clip(s) }
      if ($0 ~ /^repo:/)        { s=$0; sub(/^repo:[ \t]*/,"",s);        repo=clip(s) }
      if ($0 ~ /^worktree:/)    { s=$0; sub(/^worktree:[ \t]*/,"",s);    worktree=clip(s) }
      if ($0 ~ /^branch:/)      { s=$0; sub(/^branch:[ \t]*/,"",s);      branch=clip(s) }
      if ($0 ~ /^path:/)        { s=$0; sub(/^path:[ \t]*/,"",s);        path=clip(s) }
      if ($0 ~ /^depends_on:/)  { s=$0; sub(/^depends_on:[ \t]*/,"",s);  deps=clip(s) }
      if ($0 ~ /^reviewed:/)    { s=$0; sub(/^reviewed:[ \t]*/,"",s);    reviewed=clip(s) }
      if ($0 ~ /^parent:/)      { s=$0; sub(/^parent:[ \t]*/,"",s);      parent=clip(s) }
      if ($0 ~ /^tags:/)        { s=$0; sub(/^tags:[ \t]*/,"",s);        tags=clip(s) }
      if ($0 ~ /^created:/)     { s=$0; sub(/^created:[ \t]*/,"",s);     created=clip(s) }
      if ($0 ~ /^closed:/)      { s=$0; sub(/^closed:[ \t]*/,"",s);      closed=clip(s) }
      if ($0 ~ /^size:/)        { s=$0; sub(/^size:[ \t]*/,"",s);        size=clip(s) }
      next
    }
    donefm && /^## / {
      h = $0; sub(/^## /, "", h); cursec = h; handoff_capturing = 0; next
    }
    donefm && cursec == "Plan" {
      plan_text = plan_text $0 "\n"
      if ($0 ~ /- \[[xX]\]/)      { plan_checked++; plan_total++ }
      else if ($0 ~ /- \[ \]/)    { plan_total++ }
      next
    }
    donefm && cursec == "Done"        { done_text = done_text $0 "\n"; next }
    donefm && cursec == "Follow-ups"  { followups_text = followups_text $0 "\n"; next }
    donefm && cursec == "Decisions"   { decisions_text = decisions_text $0 "\n"; next }
    donefm && cursec == "Handoffs" {
      if (index($0, "wb-save")) sig_work = 1
      if ($0 ~ /^### /) { handoff_text = $0 "\n"; handoff_capturing = 1; next }
      if (handoff_capturing) { handoff_text = handoff_text $0 "\n" }
      next
    }
    END {
      # U2 (KTD8): size and accept_sig are APPENDED AT THE END of this TSV
      # line, after pr_url -- never inserted earlier -- so no existing
      # positional consumer (wb_board_collect_rows_v2 t[] indices) needs
      # renumbering.
      printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s%s%s%s%s\t%s\t%s\t%s", \
        status, repo, worktree, branch, path, deps, reviewed, parent, tags, \
        created, closed, plan_checked, plan_total, title, \
        sig_ideate, sig_brainstorm, sig_plan, sig_work, sig_review, pr_url, \
        size, accept_sig
      printf "%s%s%s%s%s%s%s%s%s%s%s%s%s", SOH, plan_text, SOH, done_text, SOH, handoff_text, SOH, followups_text, SOH, decisions_text, SOH, links_text, ""
    }
  ' "$1"
}

# wb_board_v2_parse_record <record_text> <scalar_array_name> \
#   <plan_array_name> <done_array_name> <handoff_array_name> \
#   <followups_array_name> <decisions_array_name> <links_array_name> —
# splits one wb_board_v2_read_file capture on its 7 bare-SOH-joined fields
# into <scalar_array_name>[0] (the TSV header line, further split by the
# caller with wb_tsv_split) and the six body-text arrays (U5 added
# decisions/links to U2's original four). Pure string manipulation, no
# forking, no file I/O — the read already happened.
#
# `IFS=$soh read -r -d '' -a parts`, not the `${var%%pattern*}` splitting
# an earlier version used: that measured ~10ms/call across the real store
# (pure bash, no forking, but apparently expensive glob-pattern matching
# against a pattern built from concatenated quoted expansions); this
# measured over 2x faster on the same data. `-d ''` (NUL delimiter, which
# never appears in a bash string) is required so `read` consumes the WHOLE
# multi-line input instead of stopping at the first newline — IFS is set to
# only SOH, so embedded newlines within a field are never treated as
# separators and survive in the split fields intact.
wb_board_v2_parse_record() {
  local -n _pr_scalar="$2" _pr_plan="$3" _pr_done="$4" _pr_handoff="$5" _pr_followups="$6"
  local -n _pr_decisions="$7" _pr_links="$8"
  local soh=$'\1'
  local -a parts=()
  IFS="$soh" read -r -d '' -a parts <<< "$1" || true
  _pr_scalar[0]="${parts[0]:-}"
  _pr_plan[0]="${parts[1]:-}"; _pr_done[0]="${parts[2]:-}"
  _pr_handoff[0]="${parts[3]:-}"; _pr_followups[0]="${parts[4]:-}"
  _pr_decisions[0]="${parts[5]:-}"; _pr_links[0]="${parts[6]:-}"
}

# wb_board_v2_mtimes <-n out_array_name> — one `stat` invocation for every
# task file in $TASKS_DIR (not one per file), filling <out_array_name>
# ["<path>"] = mtime epoch. R21's staleness clock reads this, not a
# per-file `stat -c %Y` fork.
wb_board_v2_mtimes() {
  local -n _mt="$1"
  local -a files=()
  local f
  while IFS= read -r f; do files+=("$f"); done < <(wb_task_files)
  [ "${#files[@]}" -gt 0 ] || return 0
  local line mtime path
  while IFS=' ' read -r mtime path; do
    _mt["$path"]="$mtime"
  done < <(stat -c '%Y %n' "${files[@]}" 2>/dev/null)
}

# wb_board_collect_rows_v2 <rows_arrayname> <plan_arrayname> <done_arrayname>
#   <handoff_arrayname> <followups_arrayname> <decisions_arrayname>
#   <links_arrayname> — one pass over $TASKS_DIR/*.md (wb_task_files), one
# wb_board_v2_read_file fork per file, no tmux/gh/git calls (R16). Pushes one
# TSV row per task into <rows_arrayname> (never printed to stdout — see the
# call-convention note below) with fields:
#   1 stem  2 status  3 repo  4 branch  5 worktree  6 title  7 created
#   8 closed  9 updated(mtime epoch)  10 taskfile  11 anchor  12 parent(stem,
#   self-ref guarded)  13 depends_on(raw)  14 tags(raw frontmatter value —
#   parse with _wb_tags_parse, D3 residual)  15 plan_checked  16 plan_total
#   17 age_days  18 bucket(active|stale|shelved)  19 stage_sig  20 pr_url
#   21 size (raw size: frontmatter value, U2)  22 accept_sig (0/1, U2/KTD7) —
#   size/accept_sig are APPENDED AT THE END (KTD8), after the pre-existing
#   stage_sig/pr_url fields, so no earlier positional consumer is renumbered
# and, in the SAME loop iteration (never a second pass/re-read over the file
# list — R16), fills the six text-block arrays keyed by stem with the raw
# Plan/Done/Handoff/Follow-ups/Decisions section text and the doc/artifact-
# link candidates (U5, PR2) wb_board_v2_read_file already captured for that
# file.
#
# Call convention — MUST be invoked as a plain statement, never wrapped in
# `<(...)` or `$(...)`: nameref writes only reach the CALLER's variables
# when this function runs in the caller's own shell. Process substitution
# (`while read ... done < <(wb_board_collect_rows_v2 ...)`, the obvious way
# to stream stdout into an array) forks a SUBSHELL — this function's
# nameref assignments would land in that subshell's private copies of the
# arrays and vanish when it exits, silently leaving every caller-side array
# empty. This bit during development (rows populated fine via stdout, but
# the four text-block arrays came back empty) before rows moved to a
# fifth nameref array instead of stdout, for exactly this reason.
#
# Per-file forking is kept to exactly one (wb_board_v2_read_file's awk
# process) on purpose: `basename`, `wb_task_title`, a second per-file
# wb_board_v2_read_file call (once for the row, once for the text blocks),
# and per-file `date +%s` were all tried here first and each measurably
# added ~300 more forks across the real store. Real-store timing across
# these iterations: fragmented per-field extraction (wb_read_task +
# wb_task_title + wb_get_frontmatter xN + wb_board_section xN) was 16.7s;
# a single-awk-per-file pass that still re-read every file a second time
# for body text was 17.1s (11.1s in this function alone); collapsing to
# exactly one fork per file, with text blocks threaded out via nameref
# instead of re-read, is what gets the whole collect+model pass under the
# R15 budget — verify with `time wb board --html` before extending this further.
wb_board_collect_rows_v2() {
  local -n _cr_rows="$1" _cr_plan="$2" _cr_done="$3" _cr_handoff="$4" _cr_followups="$5"
  local -n _cr_decisions="$6" _cr_links="$7"
  # fix(review) D3: reset the anchor uniqueness maps per render so a repeated
  # render in the same process (the test harness renders several fixtures back to
  # back) starts fresh rather than carrying a prior store's anchors forward.
  WB_BOARD_ANCHOR_FOR=(); WB_BOARD_ANCHOR_USED=()
  local -A _mtimes=()
  wb_board_v2_mtimes _mtimes
  local now; now="$(date +%s)"
  local f stem anchor parent title updated age_days bucket record stage_sig path_bits
  local -a scalar=() t=() plan_a=() done_a=() handoff_a=() followups_a=() decisions_a=() links_a=()
  while IFS= read -r f; do
    [ -f "$f" ] || continue
    record="$(wb_board_v2_read_file "$f")"
    wb_board_v2_parse_record "$record" scalar plan_a done_a handoff_a followups_a decisions_a links_a
    wb_tsv_split "${scalar[0]}" t
    # t: 0 status 1 repo 2 worktree 3 branch 4 path 5 deps 6 reviewed
    #    7 parent 8 tags 9 created 10 closed 11 plan_checked 12 plan_total
    #    13 title 14 stage signal bits "ibpwr" (U7) 15 first PR url
    #    16 size (raw size: frontmatter value, U2) 17 accept_sig (0/1, U2/KTD7)
    stem="${f##*/}"; stem="${stem%.md}"
    # fix(review) D5: enforce the stem invariant [A-Za-z0-9._-] once, here, so
    # every downstream use (HTML text, data-copy, the copied `wb resume <id>`
    # shell command) is safe by construction. A filename outside this class is
    # not a real wb task; skip it rather than emit an unescaped/shell-unsafe id.
    case "$stem" in *[!A-Za-z0-9._-]*) continue ;; esac
    # fix(review) D2A: plain-statement helper calls (printf -v via out-param),
    # not `$(...)` — no subshell fork per task across the ~300-file store.
    wb_board_v2_anchor "$stem" anchor
    parent="${t[7]:-}"
    wb_task_own_parent "$parent" "$stem" || parent=""
    # fix(review) D1: a `parent:` value naming no real file becomes a PHANTOM
    # family root, and unlike a real stem (guarded at line ~707) it never passed
    # the [A-Za-z0-9._-] invariant — wb_task_own_parent only self-ref-guards it.
    # An unsanitized phantom root reaches every family sink (the fam-hero
    # data-copy `wb resume <stem>` clipboard text is HTML-escaped, not
    # shell-escaped). Enforce the same invariant here: a parent with an illegal
    # char is dropped, so the child is simply parentless (its own root) and no
    # metacharacter can reach any sink. Safe by construction, matching D5.
    case "$parent" in *[!A-Za-z0-9._-]*) parent="" ;; esac
    title="${t[13]:-}"; [ -n "$title" ] || title="$stem"
    updated="${_mtimes["$f"]:-0}"
    wb_board_v2_age_days "$updated" "$now" age_days
    wb_board_v2_bucket "${t[0]:-}" "$age_days" bucket
    _cr_plan["$stem"]="${plan_a[0]}"
    _cr_done["$stem"]="${done_a[0]}"
    _cr_handoff["$stem"]="${handoff_a[0]}"
    _cr_followups["$stem"]="${followups_a[0]}"
    _cr_decisions["$stem"]="${decisions_a[0]}"
    _cr_links["$stem"]="${links_a[0]}"
    # U7: stage_sig is the raw "ibpwr" bit string from the awk pass plus the
    # `reviewed:` frontmatter field folded in as a 6th bit — the review
    # stage's primary signal is `wb reviewed` stamping that field, and the
    # /ce-code-review text mention is only its fallback.
    stage_sig="${t[14]:-00000}"
    [ -n "${t[6]:-}" ] && stage_sig="${stage_sig}1" || stage_sig="${stage_sig}0"
    # ...and the `path:` membership mask appended as 5 more bits, resolved
    # HERE because `path:` is only in this loop's scalar split — carrying it
    # as its own model array would be a third new field for something the
    # renderer only ever reads through the resolver anyway.
    wb_board_v2_stage_path_bits "${t[4]:-}" path_bits
    stage_sig="${stage_sig}${path_bits}"
    printf -v record '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s' \
      "$stem" "${t[0]:-}" "${t[1]:-}" "${t[3]:-}" "${t[2]:-}" "$title" "${t[9]:-}" "${t[10]:-}" \
      "$updated" "$f" "$anchor" "$parent" "${t[5]:-}" "${t[8]:-}" "${t[11]:-0}" "${t[12]:-0}" \
      "$age_days" "$bucket" "$stage_sig" "${t[15]:-}" "${t[16]:-}" "${t[17]:-0}"
    _cr_rows+=("$record")
  done < <(wb_task_files)
}

# wb_board_build_model <rows_arrayname> <plan_arrayname> <done_arrayname>
#   <handoff_arrayname> <followups_arrayname> <...scalar output array
#   names...> — takes wb_board_collect_rows_v2's already-populated rows and
# text-block arrays (no file I/O of its own — every read already happened
# in that single pass) and fills the per-field associative-array model
# every v2 view reads from. Nameref-bound output arrays, same convention as
# wb_board_deps_validate/_cycles/_blocking above. Like
# wb_board_collect_rows_v2, this must be called as a plain statement, never
# `<(...)`/`$(...)` — see that function's call-convention note.
#
# Usage:
#   local -a V2ROWS=()
#   local -A M_PLAN_RAW=() M_DONE_RAW=() M_HANDOFF_RAW=() M_FOLLOWUPS_RAW=() \
#     M_DECISIONS_RAW=() M_LINKS_RAW=()
#   wb_board_collect_rows_v2 V2ROWS M_PLAN_RAW M_DONE_RAW M_HANDOFF_RAW M_FOLLOWUPS_RAW \
#     M_DECISIONS_RAW M_LINKS_RAW
#   local -A M_STATUS=() M_REPO=() M_BRANCH=() M_WORKTREE=() M_TITLE=() \
#     M_CREATED=() M_CLOSED=() M_UPDATED=() M_TASKFILE=() M_PARENT=() \
#     M_DEPS=() M_TAGS=() M_PLAN_CHECKED=() M_PLAN_TOTAL=() M_AGE_DAYS=() \
#     M_BUCKET=() M_HANDOFF_SUMMARY=() M_FAMILY_ROOT=() STEM_PARENT=() \
#     STEM_ANCHOR=() FAMILY_CHILDREN=() BUCKET_COUNT=() M_STAGE_SIG=() M_PR_URL=() \
#     M_SIZE=() M_ACCEPT=()
#   wb_board_build_model V2ROWS M_PLAN_RAW M_DONE_RAW M_HANDOFF_RAW M_FOLLOWUPS_RAW \
#     M_STATUS M_REPO M_BRANCH M_WORKTREE M_TITLE M_CREATED M_CLOSED M_UPDATED \
#     M_TASKFILE M_PARENT M_DEPS M_TAGS M_PLAN_CHECKED M_PLAN_TOTAL M_AGE_DAYS \
#     M_BUCKET M_HANDOFF_SUMMARY M_FAMILY_ROOT STEM_PARENT STEM_ANCHOR \
#     FAMILY_CHILDREN BUCKET_COUNT M_STAGE_SIG M_PR_URL M_SIZE M_ACCEPT
#
# NOTE: this comment block already listed only 22 of the function's real
# positional args before U2 (M_STAGE_SIG/M_PR_URL, added later, were never
# folded back in) — count the `local -n` lines below for the true arg
# count/order, not this usage sketch. U2 adds M_SIZE (30) and M_ACCEPT (31)
# at the END, after the pre-existing M_STAGE_SIG(28)/M_PR_URL(29), per KTD8.
wb_board_build_model() {
  local -n _bm_rows="$1" _bm_plan="$2" _bm_done="$3" _bm_handoff="$4" _bm_followups="$5"
  local -n _status="$6" _repo="$7" _branch="$8" _worktree="$9" _title="${10}"
  local -n _created="${11}" _closed="${12}" _updated="${13}" _taskfile="${14}" _parent="${15}"
  local -n _deps="${16}" _tags="${17}" _plan_checked="${18}" _plan_total="${19}" _age_days="${20}"
  local -n _bucket="${21}" _handoff_summary="${22}" _family_root="${23}"
  local -n _stem_parent="${24}" _stem_anchor="${25}" _family_children="${26}" _bucket_count="${27}"
  local -n _stage_sig="${28}" _pr_url="${29}"
  local -n _size="${30}" _accept="${31}"

  local row stem anchor
  local -a f
  for row in "${_bm_rows[@]}"; do
    wb_tsv_split "$row" f
    stem="${f[0]}"; anchor="${f[10]}"
    _status["$stem"]="${f[1]}"; _repo["$stem"]="${f[2]}"; _branch["$stem"]="${f[3]}"
    _worktree["$stem"]="${f[4]}"; _title["$stem"]="${f[5]}"; _created["$stem"]="${f[6]}"
    _closed["$stem"]="${f[7]}"; _updated["$stem"]="${f[8]}"; _taskfile["$stem"]="${f[9]}"
    _parent["$stem"]="${f[11]}"; _deps["$stem"]="${f[12]}"; _tags["$stem"]="${f[13]}"
    _plan_checked["$stem"]="${f[14]}"; _plan_total["$stem"]="${f[15]}"
    _age_days["$stem"]="${f[16]}"; _bucket["$stem"]="${f[17]}"
    _stage_sig["$stem"]="${f[18]}"; _pr_url["$stem"]="${f[19]}"
    # U2 (KTD8): size/accept sit at the END of the row layout (indices 20/21),
    # after the pre-existing stage_sig/pr_url — see the row-layout comment on
    # wb_board_collect_rows_v2 above.
    _size["$stem"]="${f[20]:-}"; _accept["$stem"]="${f[21]:-0}"
    _stem_anchor["$stem"]="$anchor"
    [ -n "${f[11]}" ] && _stem_parent["$stem"]="${f[11]}"
    _bucket_count["${f[17]}"]=$(( ${_bucket_count["${f[17]}"]:-0} + 1 ))
    # fix(review) D2A: plain-statement call into a temp, then assign — avoids a
    # subshell fork per task and sidesteps printf -v onto a nameref array elem.
    local __hs; wb_board_first_nonblank_line "${_bm_handoff["$stem"]:-}" __hs
    _handoff_summary["$stem"]="$__hs"
  done

  # Family roots + children map, from STEM_PARENT (just populated above).
  for stem in "${!_stem_anchor[@]}"; do
    _family_root["$stem"]="$(wb_board_v2_family_root "$stem" _stem_parent)"
    if [ -n "${_stem_parent["$stem"]:-}" ]; then
      _family_children["${_stem_parent["$stem"]}"]+="$stem"$'\n'
    fi
  done
}

# ===========================================================================
# U3 — wb_board_render_v2: the ratified 3-view (Active/Roadmap/Week) HTML
# renderer, driven entirely by U2's in-memory model (wb_board_collect_rows_v2
# + wb_board_build_model above) — no file I/O, no git/gh/tmux of its own
# (R16; every fact used below already lives in the model's associative
# arrays). Structure/CSS/JS translated from the ratified mockup
# (~/code/tasks/dossiers/dotfiles--workflow-strategy-and-ceremonies/board-design/board-reference-final.html,
# "Mockup O — Roadmap final") — its class names and layout are the spec;
# see that file for the canonical rail/card/lane markup this reuses. Three
# deliberate departures from the mockup, all requirements-driven, not
# taste:
#   - the mockup's `.card.stale { filter: saturate(.55); }` rule is
#     DROPPED. R21 requires full-contrast + red for stale, never
#     desaturated — the mockup's own header comment flags that rule as a
#     captured mistake, not part of the spec.
#   - the mockup hardcodes exactly one `.drilldown` (for `#card-1`). Real
#     data has N active-bucket cards, so this renders one drilldown per
#     card and adds a small amount of additional (same-style) JS/CSS so
#     selecting card X reveals X's own drilldown — R18's round-1 bug class
#     ("selecting card X shows X's drilldown, not a hardcoded one") is
#     structurally impossible to reproduce with a single static block.
#   - the mockup never shows tab-count badges. R23 requires them
#     ("tab count badges must equal BUCKET_COUNT model numbers, consistent
#     across all views") so a small badge is added to each view-tab.
# ===========================================================================

# wb_board_v2_dot_class <status> <bucket> <age_days> — the rail/card
# freshness dot color: doing/review tasks grade green (touched today) ->
# yellow (touched this week) -> red (stale bucket, R21's 14+ day rule);
# planned tasks are blue, paused/prospective/done fall to the neutral
# "muted" dot. --mauve is deliberately never returned here (R24 — mauve is
# selection/TODAY only); a selected card's ring is re-pointed to mauve
# purely via CSS (`.card.selected .ring-stroke`), never by this function
# choosing it.
wb_board_v2_dot_class() {
  local status="$1" bucket="$2" age_days="$3"
  case "$status" in
    doing|review)
      if [ "$bucket" = stale ]; then printf 'red'
      elif [ "${age_days:-0}" -le 0 ]; then printf 'green'
      else printf 'yellow'
      fi
      ;;
    planned) printf 'blue' ;;
    paused|prospective) printf 'peach' ;;
    *) printf 'muted' ;;
  esac
}

# wb_board_v2_age_label <age_days> — "today" for 0 (or negative — a task
# touched after the render's `now` snapshot, e.g. a concurrent write mid-
# render), else "<n>d". No "never" sentinel: unlike the mockup's example
# data, every real row here has a real mtime (R21's staleness clock), so
# age_days is always a small whole number, never a distinguishable
# "no activity ever" case.
wb_board_v2_age_label() {
  local d="${1:-0}" __l
  if [ "$d" -le 0 ]; then __l='today'; else __l="${d}d"; fi
  # fix(perf, U5/U6): optional <out_var> ($2, D2A's convention) — see
  # wb_board_html_escape's identical note; stdout fallback preserves every
  # existing call site unchanged.
  if [ -n "${2:-}" ]; then printf -v "$2" '%s' "$__l"; else printf '%s' "$__l"; fi
}

# wb_board_v2_ring_offset <checked> <total> — the Plan-ring's SVG
# stroke-dashoffset, fixed-point (x10) integer arithmetic only, no
# awk/bc/python fork — this runs once per active-bucket card, and U2's own
# timing notes are explicit that per-row forking is exactly the cost that
# blows the R15 budget at real-store scale. Circumference of the mockup's
# r=17 ring, x10: round(2*pi*17*10) = 1068. Empty total (no Plan section)
# prints nothing — the caller omits the progress circle entirely and shows
# the em-dash label instead, matching the mockup's no-Plan ring.
wb_board_v2_ring_offset() {
  local checked="${1:-0}" total="${2:-0}"
  [ "$total" -gt 0 ] || return 0
  local off=$(( 1068 * (total - checked) / total ))
  printf '%d.%d' $((off / 10)) $((off % 10))
}

# wb_board_v2_checklist_html <raw_plan_text> — the drilldown Plan column's
# <li>s from raw "## Plan" markdown: "- [x] ..."/"- [X] ..." -> done-item
# (checked), "- [ ] ..." -> open item; any other line under the section
# (prose, not a checklist row) is skipped. Bash string matching only (no
# awk/grep fork per line) — this is called once per active-bucket card.
wb_board_v2_checklist_html() {
  local raw="${1:-}" line trimmed text out="" __h
  while IFS= read -r line; do
    trimmed="${line#"${line%%[![:space:]]*}"}"
    case "$trimmed" in
      '- [x]'*|'- [X]'*)
        text="${trimmed#*'] '}"
        wb_board_html_escape "$text" __h
        out+="<li class=\"done-item\"><span class=\"chk done\">&#10003;</span> $__h</li>"
        ;;
      '- [ ]'*)
        text="${trimmed#*'] '}"
        wb_board_html_escape "$text" __h
        out+="<li><span class=\"chk todo\">&#9675;</span> $__h</li>"
        ;;
    esac
  done <<< "$raw"
  if [ -n "${3:-}" ]; then printf -v "$3" '%s' "$out"; else printf '%s' "$out"; fi
}

# wb_board_v2_bullet_html <raw_text> [<li_class>] — plain "- "/"* " bullet
# lines (Done, Follow-ups) as <li>s, optionally classed (e.g. "followup").
wb_board_v2_bullet_html() {
  local raw="${1:-}" cls="${2:-}" line trimmed text out="" __h
  while IFS= read -r line; do
    trimmed="${line#"${line%%[![:space:]]*}"}"
    case "$trimmed" in
      '- '*) text="${trimmed#'- '}" ;;
      '* '*) text="${trimmed#'* '}" ;;
      *) continue ;;
    esac
    wb_board_html_escape "$text" __h
    if [ -n "$cls" ]; then out+="<li class=\"$cls\">$__h</li>"; else out+="<li>$__h</li>"; fi
  done <<< "$raw"
  if [ -n "${3:-}" ]; then printf -v "$3" '%s' "$out"; else printf '%s' "$out"; fi
}

# wb_board_v2_handoff_next <raw_handoff_text> — the `/wb-save`-authored
# "**Next:** ..." line from the latest Handoff block, or empty (a terse
# `wb pause`/`wb resume`-authored entry has no such field).
wb_board_v2_handoff_next() {
  local raw="${1:-}" line trimmed
  while IFS= read -r line; do
    trimmed="${line#"${line%%[![:space:]]*}"}"
    case "$trimmed" in
      '**Next:**'*) printf '%s' "${trimmed#'**Next:**'}"; return 0 ;;
    esac
  done <<< "$raw"
}

# wb_board_v2_next_line <raw_plan_text> <raw_handoff_text> <bucket> — the
# Active/Week card's bold "Next:" line: the first still-open Plan item,
# else the latest handoff's "**Next:**" field, else a bucket-aware
# fallback ("resume or drop" for a stale card, matching the mockup's own
# no-signal stale cards; "triage next steps" otherwise).
wb_board_v2_next_line() {
  local plan_raw="${1:-}" handoff_raw="${2:-}" bucket="${3:-}" line trimmed
  while IFS= read -r line; do
    trimmed="${line#"${line%%[![:space:]]*}"}"
    case "$trimmed" in
      '- [ ]'*) printf '%s' "${trimmed#'- [ ] '}"; return 0 ;;
    esac
  done <<< "$plan_raw"
  local n; n="$(wb_board_v2_handoff_next "$handoff_raw")"
  n="${n# }"
  if [ -n "$n" ]; then printf '%s' "$n"; return 0; fi
  if [ "$bucket" = stale ]; then printf 'resume or drop'; else printf 'triage next steps'; fi
}

# wb_board_v2_rail_node_html <stem> — recursive rail entry for <stem>: a
# `<details class="family-node">` tree when it has children
# (_m_family_children, the model's FAMILY_CHILDREN), a plain `.rail-row`
# otherwise. Reads the model's nameref-bound arrays (_m_status, _m_bucket,
# _m_age_days, _m_title, _m_family_children — bound once, in
# wb_board_render_v2 below) by their fixed name via bash's ordinary
# dynamic scoping of `local` variables across a non-subshell call chain —
# the same convention wb_board_deps_chips/wb_board_stepper_html already
# use for their own render-time array lookups — rather than re-binding a
# nameref parameter at every recursion level. A recursive function that
# creates a SAME-named nameref at each level of its own call stack is
# exactly the circular-reference trap wb_board_v2_family_root's header
# comment documents (`local -n x="x"` inside a fresh scope still resolves
# "x" to itself); a plain array READ of an already-bound outer nameref
# carries no such restriction, at any recursion depth, since no new
# nameref is ever created here.
wb_board_v2_rail_node_html() {
  local stem="$1" fam_anchor="${2:-}"
  # Cycle guard (fix(review)): a hand-edited parent: loop (A parent-of B,
  # B parent-of A) makes FAMILY_CHILDREN mutually reference the two stems,
  # and this function recurses on each child — with no visited set that is
  # unbounded recursion (bash has no default FUNCNEST cap), crashing the
  # whole render. wb_board_v2_family_root already guards the same cycle
  # class; the rail render must too. RAIL_SEEN is declared once in
  # wb_board_render_v2's rail section and read here via the same dynamic-
  # scoping convention as the _m_* arrays. Render each stem at most once.
  [ -n "${RAIL_SEEN[$stem]:-}" ] && return 0
  RAIL_SEEN["$stem"]=1
  local status="${_m_status[$stem]:-}" bucket="${_m_bucket[$stem]:-}" age="${_m_age_days[$stem]:-0}"
  local dot; dot="$(wb_board_v2_dot_class "$status" "$bucket" "$age")"
  local title; title="$(wb_board_html_escape "${_m_title[$stem]:-$stem}")"
  local right
  if [ "$status" = planned ]; then
    right='<span class="rail-pill">planned</span>'
  else
    right="<span class=\"rail-row-age mono\">$(wb_board_v2_age_label "$age")</span>"
  fi
  # UX pass (scope model): every rail node carries the three attributes the
  # client-side SCOPE reads — data-stem (the `wb resume` id), data-anchor
  # (its DOM anchor, matching card-/lane-/drilldown- ids) and data-family
  # (its family ROOT's anchor, i.e. the scope key shared by a whole
  # subtree). A phantom stem (a hand-typed `parent:` with no real file —
  # see wb_board_v2_family_root's note) has no STEM_ANCHOR entry, so the
  # anchor is computed fresh rather than looked up, and the stem is escaped
  # before landing in an attribute.
  # data-status is the task's real status, so the Active view's empty state
  # can name it ("No doing card for X (planned)") instead of guessing from
  # which rail widgets happen to be present.
  local anchor; wb_board_v2_anchor "$stem" anchor
  local stem_h; wb_board_html_escape "$stem" stem_h
  local status_h; wb_board_html_escape "$status" status_h
  [ -n "$fam_anchor" ] || fam_anchor="$anchor"
  # R22's click-to-copy moves OFF the row title onto an explicit ⧉ glyph:
  # the primary click on a row now SELECTS (sets scope), and a single click
  # must never both copy and select.
  local repo_attr repo_badge
  wb_board_v2_repo_bits "$stem" repo_attr repo_badge
  right="${repo_badge}${right}"
  local copy_ic="<span class=\"copy-ic copyable\" data-copy=\"wb resume ${stem_h}\" title=\"copy wb resume ${stem_h}\">&#8865;</span>"
  # ...and the other half: an anchor straight to the task's own file.
  local open_ic; wb_board_v2_task_open_html "$stem" open_ic
  copy_ic+="$open_ic"
  local kids="${_m_family_children[$stem]:-}"
  if [ -n "$kids" ]; then
    printf '<details class="family-node" open><summary data-stem="%s" data-anchor="%s" data-family="%s" data-status="%s"%s onclick="railSummaryClick(event,this)"><span class="chev">&#9656;</span><span class="dot %s"></span><span class="rail-row-title">%s</span>%s%s</summary><div class="family-children">' \
      "$stem_h" "$anchor" "$fam_anchor" "$status_h" "$repo_attr" "$dot" "$title" "$copy_ic" "$right"
    local rn_child
    while IFS= read -r rn_child; do
      [ -n "$rn_child" ] || continue
      wb_board_v2_rail_node_html "$rn_child" "$fam_anchor"
    done <<< "$kids"
    printf '</div></details>'
  else
    printf '<div class="rail-row" data-stem="%s" data-anchor="%s" data-family="%s" data-status="%s"%s onclick="railPick(event,this)"><span class="dot %s"></span><span class="rail-row-title">%s</span>%s%s</div>' \
      "$stem_h" "$anchor" "$fam_anchor" "$status_h" "$repo_attr" "$dot" "$title" "$copy_ic" "$right"
  fi
}

# wb_board_v2_shelf_items_html <newline_list_of_stems> — the rail's
# collapsed Next/Shelf group body: one `.shelf-row` per stem, title-only
# (no dot color grading — these are presentational catch-alls, not a
# freshness signal), click-to-copy (R22).
wb_board_v2_shelf_items_html() {
  # UX pass: shelf/next rows join the scope model too (data-stem/-anchor/
  # -family + a primary select click); R22's copy moves onto the explicit
  # ⧉ glyph, same as the Doing tree's rows. __h/__a are scratch out-vars
  # (D2A) — these lists run to the hundreds store-wide, so no `$(...)`.
  # NB: the out-vars are si_-prefixed on purpose. wb_board_v2_anchor's own
  # local scratch is named `__a`, and bash's dynamic scoping means an
  # out-var literally called `__a` is SHADOWED by that local — `printf -v
  # __a` then writes the callee's copy and the caller reads an empty
  # string. (Caught by the render test: every shelf row came out with
  # data-anchor="".) Same class of trap as the nameref-recursion note on
  # wb_board_v2_family_root; out-var names must not collide with the
  # callee's locals.
  local list="$1" si_stem out="" si_h="" si_a="" si_sh="" si_st="" si_open="" si_ra="" si_rb=""
  while IFS= read -r si_stem; do
    [ -n "$si_stem" ] || continue
    wb_board_html_escape "${_m_title[$si_stem]:-$si_stem}" si_h
    wb_board_html_escape "$si_stem" si_sh
    wb_board_html_escape "${_m_status[$si_stem]:-}" si_st
    wb_board_v2_anchor "$si_stem" si_a
    wb_board_v2_task_open_html "$si_stem" si_open
    wb_board_v2_repo_bits "$si_stem" si_ra si_rb
    out+="<div class=\"shelf-row\" data-stem=\"$si_sh\" data-anchor=\"$si_a\" data-family=\"$si_a\" data-status=\"$si_st\"$si_ra onclick=\"railPick(event,this)\"><span class=\"shelf-dot\"></span><span class=\"shelf-text\">$si_h</span>$si_rb<span class=\"copy-ic copyable\" data-copy=\"wb resume $si_sh\" title=\"copy wb resume $si_sh\">&#8865;</span>$si_open</div>"
  done <<< "$list"
  printf '%s' "$out"
}

# wb_board_v2_sort_stems_by_title <stem>... — the given stems, one per
# line, sorted case-insensitively by _m_title. A tiny single `sort` fork
# (not per-stem) shared by every rail/roadmap/week list that wants a
# stable, readable order rather than hash-iteration order.
wb_board_v2_sort_stems_by_title() {
  local sb_stem
  for sb_stem in "$@"; do
    printf '%s\t%s\n' "${_m_title[$sb_stem]:-$sb_stem}" "$sb_stem"
  done | sort -f | cut -f2
}

# wb_board_v2_sort_stems_by_age <asc|desc> <stem>... — the given stems,
# one per line, sorted by _m_age_days.
wb_board_v2_sort_stems_by_age() {
  local order="$1"; shift
  local sa_stem sort_flag="-n"
  [ "$order" = desc ] && sort_flag="-rn"
  for sa_stem in "$@"; do
    printf '%s\t%s\n' "${_m_age_days[$sa_stem]:-0}" "$sa_stem"
  done | sort $sort_flag -k1,1 | cut -f2
}

# wb_board_v2_plan_ul / _done_ul / _followups_ul <stem> — the Active-view
# drilldown's and Week-view wdrill's Plan/Done/Follow-ups columns, from the
# model's raw text-block arrays (_m_plan_raw/_m_done_raw/_m_followups_raw
# — U2's already-captured section text, no re-read). Shared by both views
# so the checklist/bullet parsing rules live in exactly one place.
#
# fix(perf, U8): all three (and wb_board_v2_checklist_html /
# wb_board_v2_bullet_html underneath them) take an optional out-var, D2A's
# convention. The summary-first detail block is built for EVERY task in the
# store, not just the 24 on the deck, so the `$(...)` form these used
# internally was about to become ~800 subshell forks per render.
wb_board_v2_plan_ul() {
  local stem="$1" items; wb_board_v2_checklist_html "${_m_plan_raw[$stem]:-}" "" items
  local __o
  if [ -n "$items" ]; then __o="<ul>$items</ul>"
  else __o='<p style="color:var(--subtext);font-size:14.5px;margin:0;">No plan logged yet.</p>'
  fi
  if [ -n "${2:-}" ]; then printf -v "$2" '%s' "$__o"; else printf '%s' "$__o"; fi
}
wb_board_v2_done_ul() {
  local stem="$1" items; wb_board_v2_bullet_html "${_m_done_raw[$stem]:-}" "" items
  local __o
  if [ -n "$items" ]; then __o="<ul>$items</ul>"
  else __o='<p style="color:var(--subtext);font-size:14.5px;margin:0;">No activity logged yet.</p>'
  fi
  if [ -n "${2:-}" ]; then printf -v "$2" '%s' "$__o"; else printf '%s' "$__o"; fi
}
wb_board_v2_followups_ul() {
  local stem="$1" items; wb_board_v2_bullet_html "${_m_followups_raw[$stem]:-}" followup items
  local __o
  if [ -n "$items" ]; then __o="<ul>$items</ul>"
  else __o='<p style="color:var(--subtext);font-size:14.5px;margin:0;">No follow-ups.</p>'
  fi
  if [ -n "${2:-}" ]; then printf -v "$2" '%s' "$__o"; else printf '%s' "$__o"; fi
}

# wb_board_v2_roadmap_bar <stem> — "<track>\t<bar_html>" for one Roadmap
# lane member, or empty when <stem> doesn't place on the grid at all
# (done tasks; paused/prospective tasks; and STALE ones — a stale task
# surfaces only via the Stale toggle, R21, never desaturated into a lane
# bar). <track> is the 1-based grid-track index among the 5 week columns
# (2=2 wks ago, 3=last wk, 4=this week, 5=next, 6=later).
#
# Single-column placement only (never a multi-track "duration" bar the way
# the mockup's example data shows a task spanning last-wk through
# this-week): the model has no per-task start/target date, only
# `created:`/mtime (R16's single pass never reads git/gh/tmux for a
# richer schedule), so a duration bar would have to invent a start date
# from nothing. A doing/review task places by age (0-6d -> this week,
# 7-13d -> last wk — stale, 14+, is excluded above); a planned task places
# by readiness (no unmet blocker -> next, else -> later, tagged with the
# blocker).
wb_board_v2_roadmap_bar() {
  local stem="$1"
  local status="${_m_status[$stem]:-}" bucket="${_m_bucket[$stem]:-}" age="${_m_age_days[$stem]:-0}"
  local anchor="${_m_stem_anchor[$stem]:-}"
  local title_attr; title_attr="$(wb_board_html_escape "${_m_title[$stem]:-$stem}")"
  if [ "$status" = doing ] || [ "$status" = review ]; then
    [ "$bucket" = stale ] && return 0
    local track=4
    [ "$age" -gt 6 ] && track=3
    # UX pass: the bar carries the task's own title (it used to read only
    # "doing · 3d", which in a multi-member lane clipped to 2-4 chars) plus
    # data-anchor so a task-level scope can highlight this exact bar, and a
    # title= tooltip with the full text for whatever the ellipsis eats.
    # The label text lives in its OWN span, not as a bare text node: an
    # anonymous flex item can't be given `text-overflow: ellipsis`, so a
    # bare text node either overruns the bar's padding (and, on a ready
    # bar, the "ready" tag) or forces the bar to grow. One span per label
    # is what keeps every bar exactly one line tall with a clean ellipsis.
    printf '%s\t<div class="rm-bar active-bar" data-anchor="%s" title="%s &mdash; doing &middot; %s"><span class="rm-bar-t">%s</span><span class="rm-bar-age">%s</span></div>' \
      "$track" "$anchor" "$title_attr" "$(wb_board_v2_age_label "$age")" "$title_attr" "$(wb_board_v2_age_label "$age")"
  elif [ "$status" = planned ]; then
    if [ -n "${UNMET_COUNT[$stem]:-}" ]; then   # fix(review) D4: keyed by stem, not anchor
      local blockers_attr; blockers_attr="$(wb_board_html_escape "${BLOCKER_NAMES[$stem]:-}")"
      printf '6\t<div class="rm-bar blocked-bar" data-anchor="%s" title="%s &mdash; blocked after: %s"><span class="lock-ic">&#128274;</span><span class="rm-bar-t">%s</span><span class="rm-after-tag">after: %s</span></div>' \
        "$anchor" "$title_attr" "$blockers_attr" "$title_attr" "$blockers_attr"
    else
      printf '5\t<div class="rm-bar ready-bar" data-anchor="%s" title="%s"><span class="rm-bar-t">%s</span></div>' "$anchor" "$title_attr" "$title_attr"
    fi
  fi
}

# ===========================================================================
# U5/U6 (feat-board-build PR2, D2) — family rollup + the fourth "Family"
# view: a version-ladder (mockup D) when the family root's Plan section
# carries a "### Version ladder status" table, else a flat family (children
# tree + mockup A's aggregated decisions timeline + artifact links).
# Everything below reads only text U2's single pass already captured
# (M_PLAN_RAW for the ladder table, M_DECISIONS_RAW/M_LINKS_RAW added by
# this unit alongside it) — no second file read, R16 holds.
# ===========================================================================

# wb_board_v2_decisions_entries <raw_decisions_text> <source_stem>
#   [<out_var>] — one TSV line per dated "### YYYY-MM-DD... — <title>" entry
# under a task's "## Decisions": date \t text \t source_stem. <text> is the
# entry's first non-blank body line (its lede), falling back to <title> for
# a bare one-line decision with no body. An entry whose heading isn't
# date-led (a stray "### Open questions" subheading, say) is skipped — U5's
# timeline is date-ordered by construction, so an undated entry has nowhere
# to sit on it.
#
# fix(perf, U5): optional <out_var> (printf -v, D2A's convention) — the
# Family view calls this once per family MEMBER across the whole store
# (~200 files with a parent:/child), so a `$(...)` subshell here is exactly
# the per-file fork cost U2's own timing notes warn against; a plain-
# statement call avoids it. Same for the nested first-nonblank-line lookup
# below, which already supports this out-var form itself.
wb_board_v2_decisions_entries() {
  local raw="${1:-}" source="${2:-}" line heading date="" title="" body="" __out="" text
  local in_entry=0
  while IFS= read -r line; do
    case "$line" in
      '### '*)
        if [ "$in_entry" = 1 ]; then
          wb_board_first_nonblank_line "$body" text; [ -n "$text" ] || text="$title"
          __out+="$date"$'\t'"$text"$'\t'"$source"$'\n'
        fi
        heading="${line#'### '}"
        case "$heading" in
          [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]*)
            date="${heading:0:10}"
            title="${heading#*" — "}"
            [ "$title" = "$heading" ] && title="$heading"
            body=""; in_entry=1
            ;;
          *) in_entry=0 ;;
        esac
        ;;
      *) [ "$in_entry" = 1 ] && body+="$line"$'\n' ;;
    esac
  done <<< "$raw"
  if [ "$in_entry" = 1 ]; then
    wb_board_first_nonblank_line "$body" text; [ -n "$text" ] || text="$title"
    __out+="$date"$'\t'"$text"$'\t'"$source"$'\n'
  fi
  if [ -n "${3:-}" ]; then printf -v "$3" '%s' "$__out"; else printf '%s' "$__out"; fi
}

# wb_board_v2_classify_link <raw_link_line> <kind_outvar> <label_outvar>
#   <path_outvar> — fills <kind_outvar>/<label_outvar>/<path_outvar> for one
# link line from U2's links_text capture, grouping it for the Family view's
# Artifacts section. <label_outvar> is the SHORT display text (basename for
# a file path, the URL itself for a claude.ai link) — <path_outvar> is
# always the full matched string (the real relative path or URL). fix(review)
# P1: an earlier version only kept the basename and used it for BOTH display
# and the `data-copy`/dedup value — useless for actually opening the file
# (this store's own dossier convention is `dossiers/<repo>--<slug>/plan.md`,
# so a basename collision across families is the norm, not an edge case) and
# it silently dropped one family's artifact whenever two files shared a
# basename, since dedup keyed on the same lossy label. Callers must use
# <path_outvar> for `data-copy` and the dedup key, <label_outvar> only for
# the short visible text. Required nameref out-params, not the usual
# optional-3rd-arg/stdout-fallback convention (there are multiple values to
# return) — called once per link line per family member across the whole
# store, so no `$(...)` form is offered at all here.
wb_board_v2_classify_link() {
  local link="${1:-}"
  local -n _cl_kind="$2" _cl_label="$3" _cl_path="$4"
  _cl_path="$link"
  case "$link" in
    */decision-records/*) _cl_kind=decision-records; _cl_label="${link##*/}" ;;
    logs/decisions/*)     _cl_kind=decision-records; _cl_label="${link##*/}" ;;
    dossiers/*)           _cl_kind=dossiers; _cl_label="${link##*/}" ;;
    docs/plans/*|docs/brainstorms/*|docs/solutions/*|docs/ideation/*)
                           _cl_kind=plans; _cl_label="${link##*/}" ;;
    https://claude.ai/*)  _cl_kind=claude-ai; _cl_label="$link" ;;
    *)                    _cl_kind=other; _cl_label="${link##*/}" ;;
  esac
}

# wb_board_v2_url_escape <path> <out_var> — percent-encode the handful of
# characters that actually break a `file://` URL. NOT a general URL
# encoder: `/`, `.`, `-`, `_` and every other path character must survive
# verbatim or the link stops pointing at the file. `%` goes first, or the
# escapes introduced below would themselves be re-encoded. Pure parameter
# expansion, no fork — this runs once per link and once per task id.
wb_board_v2_url_escape() {
  local __u="${1:-}"
  __u="${__u//'%'/%25}"
  __u="${__u// /%20}"
  __u="${__u//'#'/%23}"
  __u="${__u//'?'/%3F}"
  __u="${__u//'['/%5B}"
  __u="${__u//']'/%5D}"
  printf -v "$2" '%s' "$__u"
}

# wb_board_v2_resolve_link <raw_link> <owning_repo> <href_out> <text_out>
#   <missing_out> — turn one of U2's raw link candidates into something a
# browser can actually open, plus the absolute text to show for it.
#
# The capture pass records links exactly as the task file wrote them, which
# is almost never openable from the board: `dossiers/x/plan.md` is relative
# to the task STORE, `docs/plans/y.md` is relative to the owning task's
# REPO, and neither is relative to logs/board.html. The resolution rules:
#
#   https:// , http://      left alone (claude.ai artifacts and friends)
#   /absolute               left alone
#   ~/...                   $HOME/...
#   dossiers/...            $TASKS_DIR/dossiers/...
#   docs/... , logs/...     $CODE_DIR/<repo>/...   (repo from the owning
#                           task's `repo:` frontmatter)
#   anything else relative  $CODE_DIR/<repo>/...   (same assumption: a
#                           bare relative path in a task file means "in the
#                           repo this task is about")
#
# A task with an empty `repo:` falls back to $CODE_DIR/dotfiles — the repo
# the board itself lives in, which is where an unqualified docs/ or logs/
# path in this store overwhelmingly means.
#
# <missing_out> is set to "1" when the resolved path does not exist on
# disk. Missing links are MARKED, never dropped: a link that has gone stale
# is exactly the thing worth seeing on the board. `[ -e ]` is a builtin
# (no fork) and links are deduped per family, so this is cheap.
wb_board_v2_resolve_link() {
  local __raw="${1:-}" __repo="${2:-}"
  local -n _rl_href="$3" _rl_text="$4" _rl_missing="$5"
  _rl_missing=""
  case "$__raw" in
    https://*|http://*)
      _rl_href="$__raw"; _rl_text="$__raw"; return 0 ;;
  esac
  local __abs
  case "$__raw" in
    /*)            __abs="$__raw" ;;
    '~/'*)         __abs="$HOME/${__raw#\~/}" ;;
    dossiers/*)    __abs="${TASKS_DIR:-$HOME/code/tasks}/$__raw" ;;
    *)             __abs="${CODE_DIR:-$HOME/code}/${__repo:-dotfiles}/$__raw" ;;
  esac
  [ -e "$__abs" ] || _rl_missing=1
  _rl_text="$__abs"
  local __enc; wb_board_v2_url_escape "$__abs" __enc
  _rl_href="file://$__enc"
}

# wb_board_v2_task_open_html <stem> <out_var> — the small "↗" anchor that
# opens a task's own markdown file. Every place the board shows a task id
# already offered `wb resume <stem>` on the clipboard; this is the other
# half of the ask — a link you can actually click to read the file.
#
# TASK_HREF_PREFIX is declared once in wb_board_render_v2 and read here via
# the same dynamic-scoping convention as the _m_* arrays (the alternative,
# re-escaping $TASKS_DIR at every one of the ~500 call sites a full store
# produces, is exactly the per-row cost this file's D2A convention exists
# to avoid). The stem still goes through both escapes per call: a phantom
# stem from a hand-typed `parent:` never passed through the real files'
# [A-Za-z0-9._-] filename invariant.
#
# The markup is kept deliberately lean. At ~800 of these on the real store
# every byte is multiplied: a per-link `title="open <stem>.md"` and a
# `rel="noopener"` added ~45 bytes each, ~35KB to the page and measurable
# time to R15's budget, for no information the href doesn't already carry
# (the browser shows it on hover anyway, and `target="_blank"` has implied
# noopener since 2021). A static title carries the affordance instead.
#
# A stem with no entry in the model is a PHANTOM — a hand-typed `parent:`
# naming a task file that does not exist (the pre-existing P3 this file
# documents in several places). Its link would 404, so it is marked the
# same way a missing artifact is, rather than looking like a live link.
# That is an array lookup, not a `[ -e ]` per call: cheaper, and it is the
# authoritative answer, since the model IS the set of files that were read.
wb_board_v2_task_open_html() {
  # Memoised per stem, like the stage strip and the repo bits: ~800 calls
  # for ~190 distinct answers, each otherwise doing a percent-encode plus
  # two HTML escapes.
  if [ -n "${OPEN_CACHE[${1:-}]+x}" ]; then
    printf -v "$2" '%s' "${OPEN_CACHE[${1:-}]}"
    return 0
  fi
  local __enc __cls="open-ic" __t="open task file"
  if [ -z "${_m_stem_anchor[${1:-}]+x}" ]; then
    __cls="open-ic missing"; __t="no such task file"
  fi
  wb_board_v2_url_escape "${1:-}" __enc
  wb_board_html_escape "$__enc" __enc
  local __a="<a class=\"${__cls}\" href=\"${TASK_HREF_PREFIX}${__enc}.md\" target=\"_blank\" title=\"${__t}\">&#8599;</a>"
  OPEN_CACHE["${1:-}"]="$__a"
  printf -v "$2" '%s' "$__a"
}

# ---------------------------------------------------------------------------
# U7 — lifecycle stage strip. wb-lifecycle.sh remains the OWNER of the stage
# model: the order (ideate, brainstorm, plan, work, review), the four states
# (na|pending|progress|done), `path:` semantics and the resolver's
# precedence (done > progress > pending-if-in-path > na) are all its
# decisions and are reproduced faithfully here. What is NOT reused is its
# detectors: they run git/tmux/gh once per task, which R16 forbids on this
# path. Every signal is instead a text fact the single awk pass already
# collected (see scan_signals), so the strip costs no extra I/O at all.
# ---------------------------------------------------------------------------

# wb_board_v2_stage_path_bits <path_field> <out_var> — wb_lifecycle_parse_path
# re-expressed as a 5-character membership mask over WB_LIFECYCLE_STAGES
# ("ideate brainstorm plan work review"), e.g. "00111" for the default.
# Same tolerance contract as the original (R4): comma separated, whitespace
# and an optional surrounding [...] tolerated, unknown tokens ignored,
# duplicates collapsed, and absent/blank means the default plan,work,review.
# A hand-edited `path:` must never crash the render.
#
# A case statement over the trimmed field, not `IFS=, read -ra` + a loop:
# this runs once per task across the whole store and the original's shape
# (two trims per token, an assoc array, a stage loop) is more work than the
# answer needs. `,${raw},` padding makes each membership test a single
# substring match that cannot alias a longer token (`plan` vs `planning`).
wb_board_v2_stage_path_bits() {
  local __raw="${1:-}" __bits=""
  __raw="${__raw#"${__raw%%[![:space:]]*}"}"; __raw="${__raw%"${__raw##*[![:space:]]}"}"
  case "$__raw" in
    \[*\]) __raw="${__raw#\[}"; __raw="${__raw%\]}" ;;
  esac
  [ -n "$__raw" ] || __raw="plan,work,review"
  # Strip every space so ", work , review" and ",work,review" agree.
  __raw=",${__raw// /},"
  local __st
  for __st in ideate brainstorm plan work review; do
    case "$__raw" in *",$__st,"*) __bits+=1 ;; *) __bits+=0 ;; esac
  done
  printf -v "$2" '%s' "$__bits"
}

# wb_board_v2_stage_states <stem> <out_var> — the five stage states for one
# task, as a 5-character string of n|p|g|d (na|pending|proGress|Done), in
# canonical stage order. Reads the model by dynamic scope (_m_* — the same
# convention wb_board_v2_roadmap_bar already uses); _m_stage_sig is the
# 11-bit string the collect loop packed (6 signal bits + 5 `path:` bits).
#
# Resolver, straight from wb_lifecycle_stage_state: a fired signal ALWAYS
# wins over path membership ("n/a" only when nothing fired and the stage
# isn't in the intended path), doc stages and review go pending -> done with
# no progress state, and work is the only stage with a progress state.
#
# The one deliberate simplification: the original's work-stage rule consults
# LIVE PR state (`status: done` + an open PR => still progress). That needs a
# `gh` call per task, so this treats `status: done` as done, full stop. The
# PR is surfaced next to the strip as its own chip instead, where its number
# is a link rather than a hidden input to a glyph.
wb_board_v2_stage_states() {
  local __stem="$1"
  local __sig="${_m_stage_sig[$__stem]:-00000000111}"
  local __status="${_m_status[$__stem]:-}"
  # sig bits: 0 ideate 1 brainstorm 2 plan 3 work-started 4 /ce-code-review
  #           5 reviewed: frontmatter non-empty, then 6..10 = the `path:`
  #           membership mask (resolved in the collect loop).
  local __bits="${__sig:6:5}"
  local __out="" __i __done __prog __stage
  for __i in 0 1 2 3 4; do
    __done=0; __prog=0
    case "$__i" in
      0|1|2) [ "${__sig:$__i:1}" = 1 ] && __done=1 ;;
      3)
        if [ "$__status" = done ]; then
          __done=1
        elif [ "$__status" = doing ] || [ "$__status" = review ]; then
          # started = any checked Plan box, or a /ce-work | /goal | wb-save
          # mention, or a PR — the awk pass folded all but the checkbox into
          # bit 3.
          { [ "${__sig:3:1}" = 1 ] || [ "${_m_plan_checked[$__stem]:-0}" -gt 0 ]; } && __prog=1
        fi
        ;;
      4) { [ "${__sig:5:1}" = 1 ] || [ "${__sig:4:1}" = 1 ]; } && __done=1 ;;
    esac
    if [ "$__done" = 1 ]; then __out+=d
    elif [ "$__prog" = 1 ]; then __out+=g
    elif [ "${__bits:$__i:1}" = 1 ]; then __out+=p
    else __out+=n
    fi
  done
  printf -v "$2" '%s' "$__out"
}

# wb_board_v2_stage_strip_html <stem> <out_var> [mini] — the compact strip:
# one glyph+label per stage whose state isn't `na`, in stage order, plus the
# PR chip when the task has one.
#
# Glyphs are ✓ / ● / ○, never the old renderer's half-filled ◑ — this task's
# own quick-wins note records that ◑ read as "50% done" rather than "in
# progress", which is a different claim. Progress is BLUE, not mauve: mauve
# is reserved for selection/current/TODAY (R24).
wb_board_v2_stage_strip_html() {
  local __stem="$1" __mini="${3:-}"
  # Memoised per (stem, mini): a task's strip is identical everywhere it
  # appears, and it appears in up to four places (its card, its detail
  # block, a family tree row, a ladder rung). Recomputing it ~450 times
  # meant ~4500 resolver iterations per render for ~190 distinct answers.
  # Same cache convention as REPO_ATTR_CACHE.
  local __ck="${__mini:-f}:$__stem"
  if [ -n "${STRIP_CACHE[$__ck]+x}" ]; then
    printf -v "$2" '%s' "${STRIP_CACHE[$__ck]}"
    return 0
  fi
  local __states; wb_board_v2_stage_states "$__stem" __states
  local __out="" __i __s __cls __glyph __name
  local -a __names=(ideate brainstorm plan work review)
  for __i in 0 1 2 3 4; do
    __s="${__states:$__i:1}"
    [ "$__s" = n ] && continue
    __name="${__names[$__i]}"
    case "$__s" in
      d) __cls=done;     __glyph='&#10003;' ;;
      g) __cls=progress; __glyph='&#9679;'  ;;
      *) __cls=pending;  __glyph='&#9675;'  ;;
    esac
    __out+="<span class=\"stage ${__cls}\" title=\"${__name}: ${__cls}\"><span class=\"stage-g\">${__glyph}</span>"
    [ -n "$__mini" ] || __out+="<span class=\"stage-l\">${__name}</span>"
    __out+="</span>"
  done
  local __pr="${_m_pr_url[$__stem]:-}"
  if [ -n "$__pr" ]; then
    local __n="${__pr##*/}" __h
    wb_board_html_escape "$__pr" __h
    __out+="<a class=\"pr-chip\" href=\"${__h}\" target=\"_blank\" title=\"open pull request\">PR #${__n}</a>"
  fi
  [ -z "$__out" ] || __out="<div class=\"stage-strip${__mini:+ mini}\">${__out}</div>"
  STRIP_CACHE["$__ck"]="$__out"
  printf -v "$2" '%s' "$__out"
}

# ---------------------------------------------------------------------------
# U8 — the summary-first task detail. "When expanding and digging into
# things it feels confusing — we need a clear summary that the expanded text
# can give us."
#
# The old drilldown threw three equal-weight columns (Plan / Done /
# Follow-ups) at you at once, with no answer to "so what IS this, and what's
# next". This block leads with the answer — title, status, stage strip,
# parent, and a "Now" line — and puts everything else behind collapsed
# sections with counts, so depth is available without being imposed.
#
# ONE block per task, rendered once into a hidden #detail-pool and MOVED by
# the JS into whichever slot is expanding (Active card slot, Week card,
# Family child row, ladder rung). Emitting it three times, once per view,
# would triple the biggest content on the page for no benefit.
# ---------------------------------------------------------------------------

# wb_board_v2_clip <text> <max_chars> <out_var> — <text>, truncated to
# <max_chars> with a visible marker when it was cut.
#
# This is both a page-weight and a CPU lever, and the second matters more:
# wb_board_html_escape is four global `${var//}` substitutions, which this
# file's own per-family escaping note measured as NON-linear in the size of
# a single call. One task's Handoffs entry runs to 18KB and one Decisions
# section to 12KB; clipping BEFORE escaping keeps every block cheap. The
# full text is always one click away — the header's open link goes straight
# to the file, which is the whole point of the link work in this branch.
wb_board_v2_clip() {
  local __t="${1:-}" __max="${2:-2000}"
  if [ "${#__t}" -gt "$__max" ]; then
    __t="${__t:0:$__max}"$'\n\n[clipped — open the task file for the rest]'
  fi
  printf -v "$3" '%s' "$__t"
}

# wb_board_v2_repo_attr <stem> <out_var> / wb_board_v2_repo_badge <stem>
#   <out_var> — ` data-repo="X"` for the rail's repo filter, and the small
# dim `X` badge that tells you which repo a task belongs to without opening
# it. Both empty when the task has no `repo:`.
#
# Memoised in REPO_ATTR_CACHE / REPO_BADGE_CACHE (declared once in
# wb_board_render_v2, read here by the same dynamic-scoping convention as
# the _m_* arrays): these are called at ~800 sites but the real store has
# only eight distinct repo values, so escaping per call would be eight
# useful escapes and 790 wasted ones.
# (The cache key is "k$repo", not "$repo": a bash associative array cannot
# take an empty subscript, and a task with no `repo:` is a real case.)
wb_board_v2_repo_attr() {
  local __r="${_m_repo[${1:-}]:-}" __k
  __k="k$__r"
  if [ -z "${REPO_ATTR_CACHE[$__k]+x}" ]; then
    local __e=""
    [ -z "$__r" ] || { wb_board_html_escape "$__r" __e; __e=" data-repo=\"$__e\""; }
    REPO_ATTR_CACHE["$__k"]="$__e"
  fi
  printf -v "$2" '%s' "${REPO_ATTR_CACHE[$__k]}"
}
wb_board_v2_repo_badge() {
  local __r="${_m_repo[${1:-}]:-}" __k
  __k="k$__r"
  if [ -z "${REPO_BADGE_CACHE[$__k]+x}" ]; then
    local __e=""
    # No title= — it would just repeat the badge's own text, and at ~750
    # badges that is 15KB of the page for nothing.
    [ -z "$__r" ] || { wb_board_html_escape "$__r" __e; __e="<span class=\"repo-badge mono\">$__e</span>"; }
    REPO_BADGE_CACHE["$__k"]="$__e"
  fi
  printf -v "$2" '%s' "${REPO_BADGE_CACHE[$__k]}"
}

# wb_board_v2_repo_bits <stem> <attr_out> <badge_out> — both of the above in
# one call. Most sites want both, and at this scale halving the call count
# is worth a three-line wrapper.
wb_board_v2_repo_bits() {
  local __r="${_m_repo[${1:-}]:-}" __k
  __k="k$__r"
  local __discard
  [ -n "${REPO_ATTR_CACHE[$__k]+x}" ]  || wb_board_v2_repo_attr  "$1" __discard
  [ -n "${REPO_BADGE_CACHE[$__k]+x}" ] || wb_board_v2_repo_badge "$1" __discard
  printf -v "$2" '%s' "${REPO_ATTR_CACHE[$__k]}"
  printf -v "$3" '%s' "${REPO_BADGE_CACHE[$__k]}"
}

# wb_board_v2_count_li <html> <out_var> — how many <li>s a rendered list
# fragment holds, by length difference after deleting the tag. Pure
# expansion; no grep/wc fork, and this is called several times per task.
wb_board_v2_count_li() {
  local __s="${1:-}" __stripped="${1:-}"
  __stripped="${__stripped//<li/}"
  printf -v "$2" '%s' "$(( (${#__s} - ${#__stripped}) / 3 ))"
}

# wb_board_v2_now_line <stem> <out_var> — the one line that answers "what
# happens next on this task": the latest handoff's **Next:** field, else the
# first non-blank Plan line, else a placeholder. Escaped, full text (the
# card's own next-line is clamped by CSS; here it is meant to be read).
wb_board_v2_now_line() {
  # Two statements, not one `local a=$1 b=${...[$a]}`: bash expands EVERY
  # word of a `local` command before performing any of its assignments, so
  # the second would read an as-yet-unset __stem (and die under `set -u`).
  local __stem="$1"
  local __raw="${_m_handoff_raw[$__stem]:-}" __line __t __found=""
  while IFS= read -r __line; do
    __t="${__line#"${__line%%[![:space:]]*}"}"
    case "$__t" in
      '**Next:**'*) __found="${__t#'**Next:**'}"; break ;;
      'Next:'*)     __found="${__t#'Next:'}"; break ;;
      '- **Next:**'*) __found="${__t#'- **Next:**'}"; break ;;
    esac
  done <<< "$__raw"
  if [ -z "$__found" ]; then
    while IFS= read -r __line; do
      __t="${__line#"${__line%%[![:space:]]*}"}"
      case "$__t" in
        ''|'#'*) continue ;;
        '- ['*) __found="${__t#*'] '}"; break ;;
        '- '*)  __found="${__t#'- '}"; break ;;
        *) __found="$__t"; break ;;
      esac
    done <<< "${_m_plan_raw[$__stem]:-}"
  fi
  __found="${__found#"${__found%%[![:space:]]*}"}"
  __found="${__found%"${__found##*[![:space:]]}"}"
  if [ -z "$__found" ]; then
    printf -v "$2" '%s' '<span class="placeholder">No handoff or plan yet.</span>'
  else
    local __h; wb_board_html_escape "$__found" __h
    printf -v "$2" '%s' "$__h"
  fi
}

# wb_board_v2_summary_header_html <stem> <out_var> — the "what is this and
# what happens next" part of a task detail: title, status pill, repo, age,
# a parent link that scopes the board, the id with open/copy, the lifecycle
# stage strip (with its PR chip), and the Now line.
#
# Factored out of wb_board_v2_detail_html because the Family view needs the
# SAME summary at the top of a family block, where it is rendered inline
# rather than mounted — the family root's pool block may be mounted in
# another view at the time, and a block is a single node that can only be
# in one place. Sharing the builder is what keeps "the top-level summary"
# identical to "the expanded summary" instead of a lookalike that drifts.
wb_board_v2_summary_header_html() {
  local sh_stem="$1" sh_h sh_open sh_strip sh_badge sh_out
  wb_board_html_escape "${_m_title[$sh_stem]:-$sh_stem}" sh_h
  sh_out="<div class=\"detail-head\"><div class=\"detail-title\">${sh_h}</div>"
  wb_board_html_escape "${_m_status[$sh_stem]:-}" sh_h
  sh_out+="<span class=\"detail-pill st-${sh_h}\">${sh_h}</span>"
  wb_board_v2_repo_badge "$sh_stem" sh_badge
  sh_out+="$sh_badge"
  wb_board_v2_age_label "${_m_age_days[$sh_stem]:-0}" sh_h
  sh_out+="<span class=\"detail-age mono\">touched ${sh_h}</span>"
  local sh_root="${_m_family_root[$sh_stem]:-$sh_stem}"
  if [ "$sh_root" != "$sh_stem" ]; then
    local sh_ra; wb_board_v2_anchor "$sh_root" sh_ra
    wb_board_html_escape "${_m_title[$sh_root]:-$sh_root}" sh_h
    sh_out+="<span class=\"detail-parent\" onclick=\"setScope('${sh_ra}','')\" title=\"scope the board to this family\">&#8627; ${sh_h}</span>"
  fi
  wb_board_html_escape "$sh_stem" sh_h
  wb_board_v2_task_open_html "$sh_stem" sh_open
  sh_out+="<span class=\"detail-id mono copyable\" data-copy=\"wb resume ${sh_h}\">${sh_h}</span>${sh_open}</div>"
  wb_board_v2_stage_strip_html "$sh_stem" sh_strip
  sh_out+="$sh_strip"
  wb_board_v2_now_line "$sh_stem" sh_h
  sh_out+="<div class=\"detail-now\"><span class=\"lbl\">Now</span><span class=\"txt\">${sh_h}</span></div>"
  printf -v "$2" '%s' "$sh_out"
}

# wb_board_v2_detail_html <stem> <compact 0|1> <out_var> — one task's whole
# detail block.
#
# <compact> is the R15 budget talking, not the design — the full block for
# every expandable task overshot 10s:
#   0  everything (doing/review/paused/prospective)
#   2  planned: no Decisions, no Artifacts. A planned task has essentially
#      no decision history yet, and its cited docs are one click away via
#      the header's open link; these two sections were 200KB of the page.
#   1  done: header + Now + Done only. Nobody digs a checklist out of a
#      finished task, and there are ~90 of them.
#
# Raw multi-line text (the handoff entry, the Decisions section) is escaped
# and dropped into a <pre> rather than parsed into markup: it preserves the
# author's own line structure, and it avoids a per-line loop over text that
# runs to hundreds of KB store-wide.
wb_board_v2_detail_html() {
  # Every local here is d_-prefixed, not __-prefixed, and that is load-
  # bearing: bash's dynamic scoping means an out-var whose name matches a
  # CALLEE's own local gets shadowed, and the caller silently reads an empty
  # string (or, under `set -u`, dies). This function calls eight helpers
  # whose scratch locals are all __-prefixed — wb_board_v2_now_line has its
  # own `__h`, wb_board_v2_resolve_link its own `__abs`. Same trap as the
  # `__a` collision in wb_board_v2_shelf_items_html.
  local d_stem="$1" d_compact="${2:-0}"
  local d_anchor; wb_board_v2_anchor "$d_stem" d_anchor
  local d_h d_h2 d_n d_body="" d_sec=""
  local d_status="${_m_status[$d_stem]:-}"

  # ---- header + Now line (shared with the Family view's own top-level
  #      summary, so the two can never drift apart) ----
  wb_board_v2_summary_header_html "$d_stem" d_h
  local d_repo_attr; wb_board_v2_repo_attr "$d_stem" d_repo_attr
  d_body="<div class=\"detail\" id=\"detail-${d_anchor}\" data-stem=\"${d_stem}\" data-anchor=\"${d_anchor}\"${d_repo_attr}>${d_h}"

  # ---- latest handoff: the only section open by default ----
  local d_hraw=""; wb_board_v2_clip "${_m_handoff_raw[$d_stem]:-}" 1600 d_hraw
  if [ -n "$d_hraw" ]; then
    wb_board_html_escape "$d_hraw" d_h
    d_body+="<details class=\"dsec\" open><summary>Latest handoff</summary><pre class=\"dsec-pre\">${d_h}</pre></details>"
  else
    d_body+="<details class=\"dsec\" open><summary>Latest handoff</summary><div class=\"dsec-body placeholder\">No handoff logged yet.</div></details>"
  fi

  if [ "$d_compact" != 1 ]; then
    wb_board_v2_plan_ul "$d_stem" d_sec
    d_body+="<details class=\"dsec\"><summary>Plan <span class=\"n\">${_m_plan_checked[$d_stem]:-0}/${_m_plan_total[$d_stem]:-0}</span></summary><div class=\"dsec-body\">${d_sec}</div></details>"
  fi

  wb_board_v2_done_ul "$d_stem" d_sec
  wb_board_v2_count_li "$d_sec" d_n
  d_body+="<details class=\"dsec\"><summary>Done <span class=\"n\">${d_n}</span></summary><div class=\"dsec-body\">${d_sec}</div></details>"

  if [ "$d_compact" != 1 ]; then
    wb_board_v2_followups_ul "$d_stem" d_sec
    wb_board_v2_count_li "$d_sec" d_n
    d_body+="<details class=\"dsec\"><summary>Follow-ups <span class=\"n\">${d_n}</span></summary><div class=\"dsec-body\">${d_sec}</div></details>"

    if [ "$d_compact" = 0 ]; then
    local d_draw=""; wb_board_v2_clip "${_m_decisions_raw[$d_stem]:-}" 1600 d_draw
    if [ -n "${d_draw//[[:space:]]/}" ]; then
      wb_board_html_escape "$d_draw" d_h
      d_body+="<details class=\"dsec\"><summary>Decisions</summary><pre class=\"dsec-pre\">${d_h}</pre></details>"
    fi

    # Artifacts, resolved the same way the Family view resolves them (item 1
    # of this round) so a missing file stays visibly missing here too.
    local d_art="" d_ln d_kind d_label d_path d_href d_abs d_gone d_base d_na=0
    local -A d_seen=()
    while IFS= read -r d_ln; do
      [ -n "$d_ln" ] || continue
      wb_board_v2_classify_link "$d_ln" d_kind d_label d_path
      [ -n "${d_seen[$d_path]:-}" ] && continue
      d_seen["$d_path"]=1
      wb_board_v2_resolve_link "$d_path" "${_m_repo[$d_stem]:-}" d_href d_abs d_gone
      wb_board_html_escape "$d_abs" d_h
      wb_board_html_escape "${d_abs##*/}" d_base
      wb_board_html_escape "$d_href" d_h2
      d_art+="<li><a class=\"artifact-link mono${d_gone:+ missing}\" href=\"${d_h2}\" target=\"_blank\" rel=\"noopener\" title=\"${d_h}\">${d_base}</a><span class=\"copy-ic copyable\" data-copy=\"${d_h}\" title=\"copy path\">&#8865;</span></li>"
      d_na=$((d_na + 1))
      [ "$d_na" -ge 10 ] && break   # same page-weight cap as RM_CAP / the chip rows
    done <<< "${_m_links_raw[$d_stem]:-}"
    [ -n "$d_art" ] && d_body+="<details class=\"dsec\"><summary>Artifacts <span class=\"n\">${d_na}</span></summary><div class=\"dsec-body\"><ul class=\"art-ul\">${d_art}</ul></div></details>"
    fi
  fi

  d_body+="</div>"
  printf -v "$3" '%s' "$d_body"
}

# wb_board_v2_parse_ladder_table <raw_plan_text> — TSV rows "rung \t ticket
# \t wbtask_cell \t status_cell" for a nested "### Version ladder status"
# markdown table inside a family root's Plan section (the
# be--monorepo--spike-port-post-processor-to-metric-server pattern, D2), or
# empty when the heading is absent. Rows are matched generically (any
# "| a | b | ... |" line under the heading, first two skipped as the
# header + "---" separator) rather than requiring a fixed 4-column table —
# a hand-edited row with a missing/extra cell degrades gracefully (empty
# cells default to "", never a crash) rather than requiring the table stay
# byte-exact.
wb_board_v2_parse_ladder_table() {
  local raw="${1:-}" line found=0 row_i=0 out=""
  local -a cells
  while IFS= read -r line; do
    if [ "$found" = 0 ]; then
      case "$line" in '### Version ladder status'*) found=1 ;; esac
      continue
    fi
    case "$line" in
      '### '*) break ;;
      '|'*'|'*)
        row_i=$((row_i + 1))
        [ "$row_i" -le 2 ] && continue   # 1: header row, 2: |---|---| separator
        IFS='|' read -ra cells <<< "$line"
        local rung="${cells[1]:-}" ticket="${cells[2]:-}" wbtask="${cells[3]:-}" status="${cells[4]:-}"
        rung="${rung#"${rung%%[![:space:]]*}"}"; rung="${rung%"${rung##*[![:space:]]}"}"
        ticket="${ticket#"${ticket%%[![:space:]]*}"}"; ticket="${ticket%"${ticket##*[![:space:]]}"}"
        wbtask="${wbtask#"${wbtask%%[![:space:]]*}"}"; wbtask="${wbtask%"${wbtask##*[![:space:]]}"}"
        status="${status#"${status%%[![:space:]]*}"}"; status="${status%"${status##*[![:space:]]}"}"
        [ -n "$rung" ] || continue
        out+="$rung"$'\t'"$ticket"$'\t'"$wbtask"$'\t'"$status"$'\n'
        ;;
    esac
  done <<< "$raw"
  printf '%s' "$out"
}

# wb_board_v2_ladder_child_stem <wbtask_cell> [<out_var>] — the
# backtick-quoted task stem from a ladder table's "wb task" cell (e.g.
# "`lib--algorithms--foo`"), or empty for prose like "not yet created" /
# "same task as T1 — no separate wb task".
#
# fix(review) P2: optional out-var (D2A's convention) — called once per
# rung, and a ladder family's rungs are walked twice in the same pass (once
# for the JSON side-output, once for the HTML), so a `$(...)` fork here was
# 2x the fork count this function needed. Rare in practice (ladder tables
# are a small subset of families today) so not a budget risk, but the fix
# is free — stdout fallback preserves any future `$(...)` caller.
wb_board_v2_ladder_child_stem() {
  local cell="${1:-}" __cs=""
  if [[ "$cell" =~ \`([A-Za-z0-9._-]+)\` ]]; then __cs="${BASH_REMATCH[1]}"; fi
  if [ -n "${2:-}" ]; then printf -v "$2" '%s' "$__cs"; else printf '%s' "$__cs"; fi
}

# wb_board_v2_ladder_status_class <resolved_status_or_empty> <status_cell>
#   [<out_var>] — the rung's done|active|planned|unfiled class. Prefers the
# LIVE model status of the resolved child task (so the rung reflects
# reality even if the ladder table's own free-text status cell has gone
# stale) and falls back to keyword-matching the status cell's prose only
# when no wb task is resolvable. Optional out-var, same rationale as
# wb_board_v2_ladder_child_stem above.
wb_board_v2_ladder_status_class() {
  local resolved="${1:-}" cell="${2:-}" __cls
  case "$resolved" in
    done) __cls=done ;;
    doing|review) __cls=active ;;
    planned|paused|prospective) __cls=planned ;;
    *)
      case "$cell" in
        *[Dd]one*|*shipped*|*merged*) __cls=done ;;
        *doing*|*active*|*implemented*|*in\ progress*) __cls=active ;;
        *planned*) __cls=planned ;;
        *) __cls=unfiled ;;
      esac
      ;;
  esac
  if [ -n "${3:-}" ]; then printf -v "$3" '%s' "$__cls"; else printf '%s' "$__cls"; fi
}

# wb_board_v2_json_escape <string> <out_var> — minimal JSON string escaping
# (backslash, double-quote, newline/tab/CR — the control chars real task
# prose can actually contain; task titles/decisions never carry other C0
# control bytes) for the U5 family-rollup.json side-output. Always an
# out-var, no stdout fallback: every caller in the Family view's JSON
# assembly is a hot per-family/per-child loop (D2A's convention — see
# wb_board_html_escape's identical note).
wb_board_v2_json_escape() {
  local s="$1"
  s="${s//\\/\\\\}"; s="${s//\"/\\\"}"
  s="${s//$'\n'/\\n}"; s="${s//$'\t'/\\t}"; s="${s//$'\r'/}"
  printf -v "$2" '%s' "$s"
}

# wb_board_render_v2 <31 model array names, exactly wb_board_build_model's
# own output-array list (U2 grew this from 29 to 31 — see that function's
# header), PLUS M_DECISIONS_RAW M_LINKS_RAW (U5, PR2 — the Family view's own
# raw text, never touched by build_model since they carry no per-field model
# derivation, just pass-through text like M_PLAN_RAW)> — the ratified 3-view
# (Active/Roadmap/Week) HTML page (U3) plus the Family view (U6).
# Deliberately takes the SAME names cmd_board's --html branch already builds
# for wb_board_build_model, in the SAME order, plus the 2 trailing raw
# arrays, so a caller does:
#   wb_board_collect_rows_v2 V2ROWS M_PLAN_RAW M_DONE_RAW M_HANDOFF_RAW M_FOLLOWUPS_RAW \
#     M_DECISIONS_RAW M_LINKS_RAW
#   wb_board_build_model V2ROWS M_PLAN_RAW ... M_SIZE M_ACCEPT
#   wb_board_render_v2   V2ROWS M_PLAN_RAW ... M_SIZE M_ACCEPT M_DECISIONS_RAW M_LINKS_RAW
# — one collect, one model build, one render, over the SAME arrays (R16:
# no second file read). Nameref parameter names are prefixed `_m_`
# (model), never bare (`_status`, `_stem_anchor`, ...) precisely because
# this function goes on to call wb_board_deps_validate/_cycles/_blocking,
# whose OWN internal nameref parameters use those exact bare names —
# passing a same-named local into a function whose own local is bound to
# that identical name is bash's circular-nameref trap (documented at
# length on wb_board_v2_family_root above); every helper this function
# calls after it (wb_board_v2_rail_node_html, _roadmap_bar, _plan_ul, ...)
# reads these `_m_*` names back out via ordinary dynamic scoping, not a
# second layer of namerefs — see wb_board_v2_rail_node_html's header
# comment for why that's both safe and required for its recursion.
wb_board_render_v2() {
  local -n _m_rows="$1" _m_plan_raw="$2" _m_done_raw="$3" _m_handoff_raw="$4" _m_followups_raw="$5"
  local -n _m_status="$6" _m_repo="$7" _m_branch="$8" _m_worktree="$9" _m_title="${10}"
  local -n _m_created="${11}" _m_closed="${12}" _m_updated="${13}" _m_taskfile="${14}" _m_parent="${15}"
  local -n _m_deps="${16}" _m_tags="${17}" _m_plan_checked="${18}" _m_plan_total="${19}" _m_age_days="${20}"
  local -n _m_bucket="${21}" _m_handoff_summary="${22}" _m_family_root="${23}"
  local -n _m_stem_parent="${24}" _m_stem_anchor="${25}" _m_family_children="${26}" _m_bucket_count="${27}"
  local -n _m_stage_sig="${28}" _m_pr_url="${29}"
  # U2: M_SIZE/M_ACCEPT, the same trailing pair wb_board_build_model now
  # produces (positions 30/31 there) — render_v2 takes the identical 31-name
  # sequence build_model does, in the same order (see this function's own
  # header note), so these land at the same positions here too. Not yet read
  # by anything below (later units use them) — this unit only threads them
  # through.
  local -n _m_size="${30}" _m_accept="${31}"
  local -n _m_decisions_raw="${32}" _m_links_raw="${33}"

  local now; now="$(date +%s)"

  # TASK_HREF_PREFIX: "file:///abs/path/to/tasks/" — escaped ONCE here and
  # read by wb_board_v2_task_open_html at every task-id site (see its own
  # note), rather than re-escaping $TASKS_DIR a few hundred times.
  local -A REPO_ATTR_CACHE=() REPO_BADGE_CACHE=() STRIP_CACHE=() OPEN_CACHE=()
  local TASK_HREF_PREFIX
  wb_board_v2_url_escape "${TASKS_DIR:-$HOME/code/tasks}" TASK_HREF_PREFIX
  wb_board_html_escape "$TASK_HREF_PREFIX" TASK_HREF_PREFIX
  TASK_HREF_PREFIX="file://${TASK_HREF_PREFIX}/"

  # ---- dependency graph (Roadmap/Week readiness cues, R19) — reuses the
  # OLD renderer's wb_board_deps_validate/_cycles/_blocking (U1's split,
  # unmodified — scope boundary: this unit doesn't touch them), fed from
  # the v2 model's M_DEPS/STEM_ANCHOR instead of the old collect pass'
  # ROWS. UNMET_COUNT/BLOCKER_NAMES read back by wb_board_v2_roadmap_bar
  # and the readiness-strip/queue-chip code below via the same dynamic-
  # scoping convention as wb_board_deps_chips already relies on. ----
  local -A DEPS_OF=() DG_KEY=() DANGLING_WARN=() CYCLE_MEMBER=() CYCLE_WARN=()
  local -A UNMET_COUNT=() BLOCKER_NAMES=() UNBLOCKS_COUNT=() UNBLOCKS_NAMES=()
  # fix(review) D4: key the dependency graph off the STEM (unique — it IS the
  # filename), not the sanitized anchor (many-to-one: two stems can collapse to
  # one anchor and silently overwrite each other's edges / cross-wire deps).
  # The deps helpers only use their stem_anchor/anchor_stem args to map a
  # dep-line stem to a graph key and back; feeding them an identity map
  # (DG_KEY: stem->stem) keys the whole graph — and its UNMET_COUNT/
  # BLOCKER_NAMES/… outputs — by stem, with ZERO change to those shared, tested
  # helpers. depends_on: already names stems, so resolution is unchanged; the
  # anchor stays DOM-ids-only. (fix(review) D2A also hoists wb_board_parse_deps
  # to a plain statement — printf -v into the DEPS_OF element, no subshell.)
  local dg_stem
  for dg_stem in "${!_m_stem_anchor[@]}"; do
    DG_KEY["$dg_stem"]="$dg_stem"
    wb_board_parse_deps "${_m_deps[$dg_stem]:-}" "DEPS_OF[$dg_stem]"
  done
  wb_board_deps_validate DEPS_OF DG_KEY DANGLING_WARN
  wb_board_deps_cycles DEPS_OF DG_KEY DG_KEY CYCLE_MEMBER CYCLE_WARN
  wb_board_deps_blocking DEPS_OF DG_KEY _m_status DG_KEY CYCLE_MEMBER \
    UNMET_COUNT BLOCKER_NAMES UNBLOCKS_COUNT UNBLOCKS_NAMES

  # ---- family roots currently "doing" (root or any descendant in bucket
  # active/stale) — the shared scoping set for the rail's Doing tree and
  # the Roadmap's lanes (R17/R19). Everything else (planned/paused/done)
  # surfaces via the rail's Next/Shelf groups and the readiness strips
  # instead of a full lane/tree entry — on this real ~300-task store that
  # would otherwise be several dozen always-empty single-bar lanes. ----
  # U8: the exact set of tasks something can actually EXPAND. Every mount
  # host below registers its stem here, and the #detail-pool is built from
  # this set alone — emitting a block for a task with no host (a rail-only
  # or roadmap-only task) is pure page weight nothing can ever reach. On the
  # real store that is 186 blocks instead of 303.
  local -A DETAIL_WANT=()
  local -A ACTIVE_FAMILY_ROOTS=() RAIL_COVERED=()
  local af_stem
  for af_stem in "${!_m_stem_anchor[@]}"; do
    if [ "${_m_bucket[$af_stem]}" = active ] || [ "${_m_bucket[$af_stem]}" = stale ]; then
      ACTIVE_FAMILY_ROOTS["${_m_family_root[$af_stem]}"]=1
    fi
  done
  for af_stem in "${!_m_stem_anchor[@]}"; do
    [ -n "${ACTIVE_FAMILY_ROOTS["${_m_family_root[$af_stem]}"]:-}" ] && RAIL_COVERED["$af_stem"]=1
  done
  local -a active_family_roots_sorted=()
  local afs_stem
  while IFS= read -r afs_stem; do active_family_roots_sorted+=("$afs_stem"); done < <(
    [ "${#ACTIVE_FAMILY_ROOTS[@]}" -gt 0 ] && wb_board_v2_sort_stems_by_age asc "${!ACTIVE_FAMILY_ROOTS[@]}"
  )

  # =========================================================================
  # RAIL (R17): the Doing tree (families as collapsible <details>, plain
  # rows otherwise), then the collapsed Next/Shelf groups for everything
  # not already covered by an active family.
  # =========================================================================
  # RAIL_SEEN: visited set for wb_board_v2_rail_node_html's recursion, so a
  # parent: cycle renders each stem once instead of recursing forever — see
  # that function's cycle-guard comment.
  local -A RAIL_SEEN=()
  # UX pass: an "All doing" row heads the tree — the explicit way back to
  # "no scope" once a family/task pick has narrowed every view (the scope
  # model's identity element, not a filter).
  local rail_doing_html='<div class="rail-row rail-all selected" data-stem="" data-anchor="" data-family="" onclick="railPick(event,this)"><span class="dot muted"></span><span class="rail-row-title">All doing</span></div>'
  local rd_stem rd_anchor
  for rd_stem in "${active_family_roots_sorted[@]}"; do
    wb_board_v2_anchor "$rd_stem" rd_anchor
    rail_doing_html+="$(wb_board_v2_rail_node_html "$rd_stem" "$rd_anchor")"
  done

  local -a next_items=() shelf_items=()
  local ri_stem
  for ri_stem in "${!_m_stem_anchor[@]}"; do
    [ -n "${RAIL_COVERED[$ri_stem]:-}" ] && continue
    [ -z "${_m_stem_parent[$ri_stem]:-}" ] || continue
    case "${_m_status[$ri_stem]:-}" in
      planned) next_items+=("$ri_stem") ;;
      paused|prospective) shelf_items+=("$ri_stem") ;;
    esac
  done
  local next_html="" shelf_html=""
  [ "${#next_items[@]}" -gt 0 ] && next_html="$(wb_board_v2_shelf_items_html "$(wb_board_v2_sort_stems_by_title "${next_items[@]}")")"
  [ "${#shelf_items[@]}" -gt 0 ] && shelf_html="$(wb_board_v2_shelf_items_html "$(wb_board_v2_sort_stems_by_title "${shelf_items[@]}")")"

  # U6 follow-up (UX feedback on PR #60): the rail switches content by
  # active view — #rail-tasks (Doing tree + Next/Shelf, this block) for
  # Active/Roadmap/Week, #rail-families (built alongside the family loop
  # below) for Family. showView() toggles which one is visible; family
  # selection moves from the old cramped top-of-page chip grid (33+
  # families in a wrapping grid read as "overwhelming") to this same rail
  # nav surface every other view already uses.
  local rail_html
  # Round 3 item 3: a repo segmented control under the filter box —
  # All, then the five biggest repos by task count (dotfiles pinned first
  # when it is present, since it is the repo the board itself lives in),
  # then `other`.
  #
  # The earlier rule bailed out to All/dotfiles/other whenever the store
  # held more than six repos, which on the real store (eight) meant the
  # 184-task be--monorepo could not be selected at all — the filter
  # excluded its own biggest case. Top-5-by-count always names the repos
  # that actually carry the work.
  #
  # `other` is a real SET, not a negation: it carries the remaining repo
  # names in data-repo-set and matches membership. A task with no `repo:`
  # at all is folded in too (the trailing separator below puts "" in the
  # set) — otherwise those tasks would be reachable only through All. The
  # tab badges stay store-wide (R23): this filters what you SEE, it does
  # not restate what the store contains.
  local -A REPO_COUNT=()
  local rf_stem rf_repo rf_blank=0
  for rf_stem in "${!_m_stem_anchor[@]}"; do
    rf_repo="${_m_repo[$rf_stem]:-}"
    if [ -n "$rf_repo" ]; then
      REPO_COUNT["$rf_repo"]=$(( ${REPO_COUNT["$rf_repo"]:-0} + 1 ))
    else
      rf_blank=1
    fi
  done
  # dotfiles first, then by task count descending, then by name so the
  # order is stable between renders when counts tie. One `sort` fork for
  # the whole control, not one per repo.
  local -a rf_ranked=()
  if [ "${#REPO_COUNT[@]}" -gt 0 ]; then
    local rf_line
    while IFS= read -r rf_line; do
      [ -n "$rf_line" ] && rf_ranked+=("${rf_line#*$'\t'}")
    done < <(
      for rf_repo in "${!REPO_COUNT[@]}"; do
        if [ "$rf_repo" = dotfiles ]; then
          printf '0\t%s\n' "$rf_repo"          # pinned ahead of everything
        else
          printf '%s\t%s\n' "$(( 1000000 - ${REPO_COUNT[$rf_repo]} ))" "$rf_repo"
        fi
      done | sort -t $'\t' -k1,1n -k2,2
    )
  fi
  local RF_TOP=5
  local repo_chips_html="<span class=\"repo-chip selected\" data-repo-pick=\"\" onclick=\"pickRepo(event,this)\">All</span>"
  local rf_i=0 rf_h rf_rest=""
  for rf_repo in "${rf_ranked[@]}"; do
    rf_i=$((rf_i + 1))
    wb_board_html_escape "$rf_repo" rf_h
    if [ "$rf_i" -le "$RF_TOP" ]; then
      repo_chips_html+="<span class=\"repo-chip\" data-repo-pick=\"${rf_h}\" onclick=\"pickRepo(event,this)\" title=\"only ${rf_h} (${REPO_COUNT[$rf_repo]})\">${rf_h}</span>"
    else
      rf_rest+="${rf_h}|"
    fi
  done
  rf_rest="${rf_rest%|}"    # no trailing separator...
  if [ "$rf_blank" = 1 ]; then
    # ...except when the store holds tasks with no `repo:` at all: a
    # trailing "|" leaves an empty member after split(), which is how those
    # tasks join the set. Without it `other` would silently match them
    # anyway, which is the same negation bug in miniature.
    rf_rest="${rf_rest}|"
  fi
  if [ -n "$rf_rest" ]; then
    repo_chips_html+="<span class=\"repo-chip\" data-repo-pick=\"__other__\" data-repo-set=\"${rf_rest}\" onclick=\"pickRepo(event,this)\" title=\"every repo not named above\">other</span>"
  fi

  rail_html="<input type=\"text\" id=\"board-filter\" class=\"rail-filter\" placeholder=\"Filter&hellip; (press /)\" autocomplete=\"off\">"
  rail_html+="<div class=\"repo-chips\" id=\"repo-chips\">${repo_chips_html}</div>"
  rail_html+="<div id=\"rail-tasks\">"
  rail_html+="<div><div class=\"rail-heading\">Doing</div><div class=\"rail-tree\">${rail_doing_html}</div></div>"
  rail_html+="<div class=\"group\" id=\"next-group\"><div class=\"group-head\" onclick=\"toggleGroup('next-group')\"><span class=\"group-caret\">&#9656;</span><span class=\"group-label\">Next &middot; <span class=\"count-blue\">${#next_items[@]}</span></span></div><div class=\"group-body\">${next_html}</div></div>"
  rail_html+="<div class=\"group expanded\" id=\"shelf-group\"><div class=\"group-head\" onclick=\"toggleGroup('shelf-group')\"><span class=\"group-caret\">&#9656;</span><span class=\"group-label\">Shelf &middot; <span class=\"count-peach\">${#shelf_items[@]}</span></span></div><div class=\"group-body\">${shelf_html}</div></div>"
  rail_html+='</div>'

  # =========================================================================
  # ACTIVE VIEW (R18): one card per doing/review task, stale ones included
  # (full-contrast red, R21) but ordered after the fresh ones so a wrap
  # pushes them to a later row, not the first one. One drilldown per card,
  # toggled together with `.selected` by the script below — see this
  # function group's header comment for why that's a deliberate departure
  # from the mockup's single hardcoded drilldown (R18's round-1 bug class).
  # =========================================================================
  local -a deck_active=() deck_stale=()
  local dk_stem
  for dk_stem in "${!_m_stem_anchor[@]}"; do
    case "${_m_bucket[$dk_stem]:-}" in
      active) deck_active+=("$dk_stem") ;;
      stale)  deck_stale+=("$dk_stem") ;;
    esac
  done
  local -a deck_order=()
  if [ "${#deck_active[@]}" -gt 0 ]; then
    while IFS= read -r dk_stem; do deck_order+=("$dk_stem"); done < <(wb_board_v2_sort_stems_by_age asc "${deck_active[@]}")
  fi
  if [ "${#deck_stale[@]}" -gt 0 ]; then
    while IFS= read -r dk_stem; do deck_order+=("$dk_stem"); done < <(wb_board_v2_sort_stems_by_age asc "${deck_stale[@]}")
  fi

  # UX pass: each card and its drilldown live together in a `.card-slot`
  # so the expanded detail opens IN PLACE beneath the card that was
  # clicked, instead of in one shared slot far down the page (the old
  # batched @@DRILLDOWNS_HTML@@ block, now gone). The slot also carries the
  # scope attributes (data-anchor = the task, data-family = its family
  # root's anchor) the rail's setScope() narrows the deck by.
  local deck_html="" dk_idx=0 dk_fam_anchor=""
  for dk_stem in "${deck_order[@]}"; do
    dk_idx=$((dk_idx + 1))
    local dk_anchor="${_m_stem_anchor[$dk_stem]}"
    wb_board_v2_anchor "${_m_family_root[$dk_stem]:-$dk_stem}" dk_fam_anchor
    local dk_bucket="${_m_bucket[$dk_stem]}"
    local dk_age="${_m_age_days[$dk_stem]:-0}"
    local dk_dot; dk_dot="$(wb_board_v2_dot_class "${_m_status[$dk_stem]}" "$dk_bucket" "$dk_age")"
    local dk_sel_cls="" dk_stale_cls=""
    [ "$dk_idx" = 1 ] && dk_sel_cls=" selected"
    [ "$dk_bucket" = stale ] && dk_stale_cls=" stale"
    local dk_checked="${_m_plan_checked[$dk_stem]:-0}" dk_total="${_m_plan_total[$dk_stem]:-0}"
    local dk_ring_label="&mdash;" dk_ring_circle=""
    if [ "$dk_total" -gt 0 ]; then
      dk_ring_label="$dk_checked/$dk_total"
      dk_ring_circle="<circle class=\"ring-stroke\" cx=\"21\" cy=\"21\" r=\"17\" fill=\"none\" stroke=\"var(--${dk_dot})\" stroke-width=\"4\" stroke-dasharray=\"106.8\" stroke-dashoffset=\"$(wb_board_v2_ring_offset "$dk_checked" "$dk_total")\" stroke-linecap=\"round\" transform=\"rotate(-90 21 21)\"/>"
    fi
    local dk_quote_html
    if [ -n "${_m_handoff_summary[$dk_stem]:-}" ]; then
      dk_quote_html="<div class=\"quote\">&ldquo;$(wb_board_html_escape "${_m_handoff_summary[$dk_stem]}")&rdquo;</div>"
    else
      dk_quote_html='<div class="quote placeholder">No handoff logged yet.</div>'
    fi
    local dk_next; dk_next="$(wb_board_v2_next_line "${_m_plan_raw[$dk_stem]:-}" "${_m_handoff_raw[$dk_stem]:-}" "$dk_bucket")"
    local dk_title; dk_title="$(wb_board_html_escape "${_m_title[$dk_stem]:-$dk_stem}")"

    local dk_repo_attr dk_repo_badge
    wb_board_v2_repo_bits "$dk_stem" dk_repo_attr dk_repo_badge
    deck_html+="<div class=\"card-slot${dk_sel_cls}\" data-stem=\"${dk_stem}\" data-anchor=\"${dk_anchor}\" data-family=\"${dk_fam_anchor}\"${dk_repo_attr}>"
    deck_html+="<div class=\"card${dk_sel_cls}${dk_stale_cls}\" id=\"card-${dk_anchor}\" data-drilldown=\"drilldown-${dk_anchor}\">"
    # The card id gains an "open the task file" anchor beside its existing
    # copy behaviour, and each drilldown heading carries the same link so
    # the expanded detail is one click from the source it summarises.
    local dk_open; wb_board_v2_task_open_html "$dk_stem" dk_open
    deck_html+="<div class=\"card-top\"><div><div class=\"card-title\">${dk_title}</div><span class=\"card-id mono copyable\" data-copy=\"wb resume ${dk_stem}\">${dk_stem}</span>${dk_open}${dk_repo_badge}</div>"
    deck_html+="<div class=\"ring-wrap\"><svg width=\"42\" height=\"42\" viewBox=\"0 0 42 42\"><circle cx=\"21\" cy=\"21\" r=\"17\" fill=\"none\" stroke=\"var(--overlay)\" stroke-width=\"4\"/>${dk_ring_circle}</svg><span class=\"ring-label\">${dk_ring_label}</span></div></div>"
    local dk_strip; wb_board_v2_stage_strip_html "$dk_stem" dk_strip
    deck_html+="$dk_strip"
    deck_html+="${dk_quote_html}"
    deck_html+="<div class=\"next-line\">Next: <b>$(wb_board_html_escape "$dk_next")</b></div>"
    deck_html+="<div class=\"card-foot\"><span class=\"dot ${dk_dot}\"></span><span class=\"mono\">$(wb_board_v2_age_label "$dk_age")</span><span class=\"card-caret\" title=\"expand\">&#9656;</span></div>"
    deck_html+="</div>"

    # U8: the expanded detail is no longer built here. Every task has ONE
    # block in #detail-pool and the JS moves it into this host — the same
    # block the Week and Family views mount, so "expanded" means the same
    # thing wherever you are.
    DETAIL_WANT["$dk_stem"]=1
    deck_html+="<div class=\"detail-host\" data-anchor=\"${dk_anchor}\"></div>"
    deck_html+="</div>"
  done

  # =========================================================================
  # ROADMAP VIEW (R19): one lane per family/standalone task currently
  # touching "doing" work, positioned on the 5-week grid by bucket+age —
  # see wb_board_v2_roadmap_bar's header comment for why this is a
  # single-column placement, not the mockup's duration-style bars.
  # =========================================================================
  local rm_lanes_html="" rm_stem
  for rm_stem in "${active_family_roots_sorted[@]}"; do
    local rm_kids="${_m_family_children[$rm_stem]:-}"
    local -a rm_members=("$rm_stem")
    if [ -n "$rm_kids" ]; then
      local rm_c
      while IFS= read -r rm_c; do [ -n "$rm_c" ] && rm_members+=("$rm_c"); done <<< "$rm_kids"
    fi
    local rm_bars="" rm_min_track=99 rm_max_track=0 rm_member rm_bar_line rm_track rm_bar_html
    for rm_member in "${rm_members[@]}"; do
      rm_bar_line="$(wb_board_v2_roadmap_bar "$rm_member")"
      [ -n "$rm_bar_line" ] || continue
      rm_track="${rm_bar_line%%$'\t'*}"
      rm_bar_html="${rm_bar_line#*$'\t'}"
      rm_bars+="$rm_bar_html"
      [ "$rm_track" -lt "$rm_min_track" ] && rm_min_track="$rm_track"
      [ "$rm_track" -gt "$rm_max_track" ] && rm_max_track="$rm_track"
    done
    [ -n "$rm_bars" ] || continue
    local rm_span_end=$((rm_max_track + 1))
    local rm_title; rm_title="$(wb_board_html_escape "${_m_title[$rm_stem]:-$rm_stem}")"
    # UX pass: the lane names its family so setScope() can outline it,
    # scroll it into view and dim (never hide — a roadmap of one lane is
    # useless) the rest.
    local rm_anchor; wb_board_v2_anchor "$rm_stem" rm_anchor
    local rm_repo_attr; wb_board_v2_repo_attr "$rm_stem" rm_repo_attr
    if [ -n "$rm_kids" ]; then
      local rm_total=${#rm_members[@]} rm_done=0
      for rm_member in "${rm_members[@]}"; do
        [ "${_m_status[$rm_member]:-}" = done ] && rm_done=$((rm_done + 1))
      done
      rm_lanes_html+="<div class=\"rm-lane milestone-lane\" id=\"lane-${rm_anchor}\" data-family=\"${rm_anchor}\" data-anchor=\"${rm_anchor}\"${rm_repo_attr}><div class=\"rm-lane-label\" title=\"${rm_title}\"><div class=\"rm-title-row\"><span class=\"rm-lane-t\">${rm_title}</span><span class=\"rm-mfrac mono\">${rm_done} / ${rm_total}</span></div></div>"
      rm_lanes_html+="<div class=\"rm-bracket\" style=\"grid-column: ${rm_min_track} / ${rm_span_end};\"></div>"
      rm_lanes_html+="<div class=\"rm-bars\" style=\"grid-column: ${rm_min_track} / ${rm_span_end};\">${rm_bars}</div></div>"
    else
      local rm_dot; rm_dot="$(wb_board_v2_dot_class "${_m_status[$rm_stem]}" "${_m_bucket[$rm_stem]}" "${_m_age_days[$rm_stem]:-0}")"
      rm_lanes_html+="<div class=\"rm-lane\" id=\"lane-${rm_anchor}\" data-family=\"${rm_anchor}\" data-anchor=\"${rm_anchor}\"${rm_repo_attr}><div class=\"rm-lane-label\" title=\"${rm_title}\"><div class=\"rm-title-row\"><span class=\"rm-lane-t\">${rm_title}</span></div><div class=\"rm-standalone-meta\"><span class=\"dot ${rm_dot}\"></span><span class=\"mono\">$(wb_board_v2_age_label "${_m_age_days[$rm_stem]:-0}")</span></div></div>"
      rm_lanes_html+="<div class=\"rm-bars\" style=\"grid-column: ${rm_min_track} / ${rm_span_end};\">${rm_bars}</div></div>"
    fi
  done

  # readiness strip: EVERY planned task store-wide (not just the lanes
  # above — this is the "what could I pick up next" queue, R19), capped
  # for page size/readability with a "+N more" tail.
  local -a ready_planned=() blocked_planned=()
  local rp2_stem
  for rp2_stem in "${!_m_stem_anchor[@]}"; do
    [ "${_m_status[$rp2_stem]:-}" = planned ] || continue
    if [ -n "${UNMET_COUNT[$rp2_stem]:-}" ]; then   # fix(review) D4: keyed by stem
      blocked_planned+=("$rp2_stem")
    else
      ready_planned+=("$rp2_stem")
    fi
  done
  local RM_CAP=8
  local ready_html="" blocked_html=""
  if [ "${#ready_planned[@]}" -gt 0 ]; then
    local rp_i=0 rp_stem
    while IFS= read -r rp_stem; do
      rp_i=$((rp_i + 1)); [ "$rp_i" -gt "$RM_CAP" ] && break
      ready_html+="<span class=\"rm-ready-pill copyable\" data-copy=\"wb resume $rp_stem\">$(wb_board_html_escape "${_m_title[$rp_stem]:-$rp_stem}")</span>"
    done < <(wb_board_v2_sort_stems_by_title "${ready_planned[@]}")
    [ "${#ready_planned[@]}" -gt "$RM_CAP" ] && ready_html+="<span class=\"rm-ready-pill\" style=\"opacity:.6;\">+$(( ${#ready_planned[@]} - RM_CAP )) more</span>"
  fi
  if [ "${#blocked_planned[@]}" -gt 0 ]; then
    local bp_i=0 bp_stem bp_anchor
    while IFS= read -r bp_stem; do
      bp_i=$((bp_i + 1)); [ "$bp_i" -gt "$RM_CAP" ] && break
      blocked_html+="<span class=\"rm-blocked-pill\"><span class=\"lock-ic\">&#128274;</span>$(wb_board_html_escape "${_m_title[$bp_stem]:-$bp_stem}")<span class=\"after-inline\">after: $(wb_board_html_escape "${BLOCKER_NAMES[$bp_stem]:-}")</span></span>"
    done < <(wb_board_v2_sort_stems_by_title "${blocked_planned[@]}")
    [ "${#blocked_planned[@]}" -gt "$RM_CAP" ] && blocked_html+="<span class=\"rm-blocked-pill\" style=\"opacity:.6;\">+$(( ${#blocked_planned[@]} - RM_CAP )) more</span>"
  fi
  # UX pass: the strip used to eat 602px of a 1000px viewport before the
  # first lane — the roadmap's actual content started below the fold. It
  # now collapses to a single summary line ("Ready now · N · Blocked · N
  # ▸") and only renders its pills when opened (state in localStorage).
  local rm_readiness_html=""
  [ -n "$ready_html" ] && rm_readiness_html+="<div class=\"rm-readiness-group\"><span class=\"rm-readiness-label\">Ready now &middot; ${#ready_planned[@]}</span>${ready_html}</div>"
  [ -n "$blocked_html" ] && rm_readiness_html+="<div class=\"rm-readiness-group\"><span class=\"rm-readiness-label\">Blocked &middot; ${#blocked_planned[@]}</span>${blocked_html}</div>"
  if [ -n "$rm_readiness_html" ]; then
    rm_readiness_html="<div class=\"rm-strip-head\" onclick=\"toggleRmStrip()\"><span class=\"rm-strip-caret\">&#9656;</span><span class=\"rm-readiness-label\">Ready now</span><span class=\"rm-strip-n ready\">${#ready_planned[@]}</span><span class=\"rm-readiness-label\">Blocked</span><span class=\"rm-strip-n blocked\">${#blocked_planned[@]}</span></div><div class=\"rm-strip-body\">${rm_readiness_html}</div>"
  fi

  # stale toggle content — flat, store-wide, shared shape by both the
  # Roadmap and Week views (each renders it into its own container markup).
  local -a stale_stems=()
  local st_stem
  for st_stem in "${!_m_stem_anchor[@]}"; do
    [ "${_m_bucket[$st_stem]:-}" = stale ] && stale_stems+=("$st_stem")
  done
  local rm_stale_rows_html="" week_stale_rows_html="" ss_anchor="" ss_fam_anchor="" ss_open="" ss_ra=""
  if [ "${#stale_stems[@]}" -gt 0 ]; then
    local ss_stem
    while IFS= read -r ss_stem; do
      wb_board_v2_anchor "$ss_stem" ss_anchor
      wb_board_v2_anchor "${_m_family_root[$ss_stem]:-$ss_stem}" ss_fam_anchor
      wb_board_v2_task_open_html "$ss_stem" ss_open
      rm_stale_rows_html+="<div class=\"rm-stale-row\"><div class=\"rm-lane-label\" title=\"$(wb_board_html_escape "${_m_title[$ss_stem]:-$ss_stem}")\"><span class=\"dot red\"></span>$(wb_board_html_escape "${_m_title[$ss_stem]:-$ss_stem}")<span class=\"age-red mono\">$(wb_board_v2_age_label "${_m_age_days[$ss_stem]:-0}")</span></div></div>"
      wb_board_v2_repo_attr "$ss_stem" ss_ra
      week_stale_rows_html+="<div class=\"carried-row\" data-stem=\"$ss_stem\" data-anchor=\"$ss_anchor\" data-family=\"$ss_fam_anchor\"${ss_ra}><span class=\"dot red\"></span><span class=\"row-title\"><span class=\"id mono copyable\" data-copy=\"wb resume $ss_stem\">$ss_stem</span>${ss_open}$(wb_board_html_escape "${_m_title[$ss_stem]:-$ss_stem}")</span><span class=\"age\" style=\"color:var(--red);\">$(wb_board_v2_age_label "${_m_age_days[$ss_stem]:-0}")</span></div>"
    done < <(wb_board_v2_sort_stems_by_age desc "${stale_stems[@]}")
  fi

  local roadmap_view_html
  roadmap_view_html='<div class="rm-board"><div class="rm-grid-header"><div class="col-label"></div><div class="col-label">2 wks ago</div><div class="col-label">last wk</div><div class="col-label this-week">THIS WEEK</div><div class="col-label">next</div><div class="col-label">later</div></div>'
  [ -n "$rm_readiness_html" ] && roadmap_view_html+="<div class=\"rm-readiness-strip\" id=\"rm-strip\">${rm_readiness_html}</div>"
  roadmap_view_html+='<div class="rm-lanes"><div class="rm-grid-lines"><div class="vline" style="left: calc(260px + 1 * ((100% - 260px) / 5));"></div><div class="vline" style="left: calc(260px + 2 * ((100% - 260px) / 5));"></div><div class="vline" style="left: calc(260px + 3 * ((100% - 260px) / 5));"></div><div class="vline" style="left: calc(260px + 4 * ((100% - 260px) / 5));"></div></div>'
  roadmap_view_html+='<div class="rm-thisweek-band" style="left: calc(260px + 2 * ((100% - 260px) / 5)); width: calc((100% - 260px) / 5);"></div>'
  roadmap_view_html+='<div class="rm-today-line" style="left: calc(260px + 3 * ((100% - 260px) / 5));"></div>'
  roadmap_view_html+='<div class="rm-today-tag" style="left: calc(260px + 3 * ((100% - 260px) / 5));">Today</div>'
  if [ -n "$rm_lanes_html" ]; then
    roadmap_view_html+="$rm_lanes_html"
  else
    roadmap_view_html+='<p style="color:var(--subtext);padding:20px 4px;">No active work to place on the roadmap right now.</p>'
  fi
  roadmap_view_html+='</div>'
  if [ "${#stale_stems[@]}" -gt 0 ]; then
    roadmap_view_html+="<div class=\"stale-toggle\" id=\"rm-stale-toggle\" onclick=\"toggleStale()\"><span class=\"caret\">&#9656;</span><span class=\"dot red\"></span>Stale &middot; ${#stale_stems[@]} doing, needs review</div>"
    roadmap_view_html+="<div class=\"stale-detail\" id=\"rm-stale-detail\">${rm_stale_rows_html}</div>"
  fi
  roadmap_view_html+='</div>'

  # =========================================================================
  # WEEK VIEW (R20): ISO-week grouping — tasks touched since this Monday
  # get a full drilldown card; carried-over active work groups by family;
  # stale collapses; a queue/shelf row closes it out. A handful of `date`
  # forks here (not per-row — once for the week boundary, matching U2's
  # own "fork once, not per task" discipline).
  # =========================================================================
  local today_ymd dow monday_epoch week_num mon_label sun_label
  today_ymd="$(date -d "@$now" +%Y-%m-%d)"
  dow="$(date -d "$today_ymd" +%u)"
  monday_epoch="$(date -d "$today_ymd -$((dow - 1)) days" +%s)"
  week_num="$(date -d "$today_ymd" +%V)"
  mon_label="$(date -d "@$monday_epoch" +'%-d %b')"
  sun_label="$(date -d "@$((monday_epoch + 6 * 86400))" +'%-d %b')"

  local -a this_week_stems=()
  local wk_stem
  for wk_stem in "${!_m_stem_anchor[@]}"; do
    [ "${_m_bucket[$wk_stem]:-}" = active ] || continue
    [ "${_m_updated[$wk_stem]:-0}" -ge "$monday_epoch" ] && this_week_stems+=("$wk_stem")
  done

  # UX pass: week cards render COLLAPSED (top row + meta) and expand on
  # click — 23 always-open full drilldowns made this view 8579px tall. They
  # also carry the scope attributes so a rail pick narrows the week the
  # same way it narrows the deck, and auto-expands the scoped task.
  local week_cards_html="" wc_anchor="" wc_fam_anchor="" wc_open="" wc_ra=""
  if [ "${#this_week_stems[@]}" -gt 0 ]; then
    local wc_stem
    while IFS= read -r wc_stem; do
      wb_board_v2_anchor "$wc_stem" wc_anchor
      wb_board_v2_anchor "${_m_family_root[$wc_stem]:-$wc_stem}" wc_fam_anchor
      local wc_dot; wc_dot="$(wb_board_v2_dot_class "${_m_status[$wc_stem]}" "${_m_bucket[$wc_stem]}" "${_m_age_days[$wc_stem]:-0}")"
      local wc_title; wc_title="$(wb_board_html_escape "${_m_title[$wc_stem]:-$wc_stem}")"
      local wc_parent_html=""
      [ -n "${_m_stem_parent[$wc_stem]:-}" ] && wc_parent_html=" &middot; <span class=\"parent-chip mono\">child of $(wb_board_html_escape "${_m_stem_parent[$wc_stem]}")</span>"
      wb_board_v2_repo_attr "$wc_stem" wc_ra
      week_cards_html+="<div class=\"week-card\" data-stem=\"${wc_stem}\" data-anchor=\"${wc_anchor}\" data-family=\"${wc_fam_anchor}\"${wc_ra} onclick=\"toggleWeekCard(event,this)\"><div class=\"top-row\"><span class=\"dot ${wc_dot}\"></span><span class=\"title\">${wc_title}</span><span class=\"week-badge\">$(wb_board_html_escape "${_m_status[$wc_stem]:-}")</span><span class=\"wk-caret\">&#9656;</span></div>"
      wb_board_v2_task_open_html "$wc_stem" wc_open
      week_cards_html+="<div class=\"meta\"><span class=\"mono copyable\" data-copy=\"wb resume $wc_stem\">$wc_stem</span>${wc_open} &middot; touched $(wb_board_v2_age_label "${_m_age_days[$wc_stem]:-0}")${wc_parent_html}</div>"
      DETAIL_WANT["$wc_stem"]=1
      week_cards_html+="<div class=\"detail-host\" data-anchor=\"${wc_anchor}\"></div></div>"
    done < <(wb_board_v2_sort_stems_by_age asc "${this_week_stems[@]}")
  fi

  local -A THIS_WEEK_SET=()
  local tw_stem
  for tw_stem in "${this_week_stems[@]}"; do THIS_WEEK_SET["$tw_stem"]=1; done

  local family_blocks_html="" carried_list_html=""
  local -a carried_standalone_stems=()
  local cw_stem
  for cw_stem in "${active_family_roots_sorted[@]}"; do
    local cw_kids="${_m_family_children[$cw_stem]:-}"
    if [ -n "$cw_kids" ]; then
      [ -n "${THIS_WEEK_SET[$cw_stem]:-}" ] && continue
      local cw_dot; cw_dot="$(wb_board_v2_dot_class "${_m_status[$cw_stem]}" "${_m_bucket[$cw_stem]}" "${_m_age_days[$cw_stem]:-0}")"
      local cw_title; cw_title="$(wb_board_html_escape "${_m_title[$cw_stem]:-$cw_stem}")"
      local cw_anchor; wb_board_v2_anchor "$cw_stem" cw_anchor
      local cw_open cw_child_open; wb_board_v2_task_open_html "$cw_stem" cw_open
      local cw_ra; wb_board_v2_repo_attr "$cw_stem" cw_ra
      family_blocks_html+="<div class=\"family-block\" data-stem=\"$cw_stem\" data-anchor=\"$cw_anchor\" data-family=\"$cw_anchor\"${cw_ra}><div class=\"fam-row\"><span class=\"dot ${cw_dot}\"></span><span class=\"row-title\"><span class=\"id mono copyable\" data-copy=\"wb resume $cw_stem\">$cw_stem</span>${cw_open}${cw_title}</span><span class=\"age\">$(wb_board_v2_age_label "${_m_age_days[$cw_stem]:-0}")</span></div><div class=\"fam-kids\">"
      local cw_child cw_pill_cls cw_pill_text
      while IFS= read -r cw_child; do
        [ -n "$cw_child" ] || continue
        case "${_m_status[$cw_child]:-}" in
          planned) cw_pill_cls="planned"; cw_pill_text="planned" ;;
          doing|review) cw_pill_cls="doing"; cw_pill_text="doing" ;;
          *) cw_pill_cls="planned"; cw_pill_text="${_m_status[$cw_child]:-}" ;;
        esac
        wb_board_v2_task_open_html "$cw_child" cw_child_open
        family_blocks_html+="<div class=\"fam-kid-row\"><span class=\"title copyable\" data-copy=\"wb resume $cw_child\">$(wb_board_html_escape "${_m_title[$cw_child]:-$cw_child}")</span>${cw_child_open}<span class=\"right\"><span class=\"pill ${cw_pill_cls}\">$(wb_board_html_escape "$cw_pill_text")</span><span class=\"age mono\">$(wb_board_v2_age_label "${_m_age_days[$cw_child]:-0}")</span></span></div>"
      done <<< "$cw_kids"
      family_blocks_html+='</div></div>'
    else
      [ "${_m_bucket[$cw_stem]:-}" = active ] || continue
      [ -n "${THIS_WEEK_SET[$cw_stem]:-}" ] && continue
      carried_standalone_stems+=("$cw_stem")
    fi
  done
  if [ "${#carried_standalone_stems[@]}" -gt 0 ]; then
    local cl_stem cl_dot cl_anchor cl_fam_anchor cl_open cl_ra
    while IFS= read -r cl_stem; do
      cl_dot="$(wb_board_v2_dot_class "${_m_status[$cl_stem]}" "${_m_bucket[$cl_stem]}" "${_m_age_days[$cl_stem]:-0}")"
      wb_board_v2_anchor "$cl_stem" cl_anchor
      wb_board_v2_anchor "${_m_family_root[$cl_stem]:-$cl_stem}" cl_fam_anchor
      wb_board_v2_task_open_html "$cl_stem" cl_open
      wb_board_v2_repo_attr "$cl_stem" cl_ra
      carried_list_html+="<div class=\"carried-row\" data-stem=\"$cl_stem\" data-anchor=\"$cl_anchor\" data-family=\"$cl_fam_anchor\"${cl_ra}><span class=\"dot ${cl_dot}\"></span><span class=\"row-title\"><span class=\"id mono copyable\" data-copy=\"wb resume $cl_stem\">$cl_stem</span>${cl_open}$(wb_board_html_escape "${_m_title[$cl_stem]:-$cl_stem}")</span><span class=\"age\">$(wb_board_v2_age_label "${_m_age_days[$cl_stem]:-0}")</span></div>"
    done < <(wb_board_v2_sort_stems_by_age asc "${carried_standalone_stems[@]}")
  fi

  # "Unblocked next" reuses the Roadmap's own ready_planned set (R23: the
  # same readiness computation everywhere, not a second one here); "Shelf"
  # is every status:paused task store-wide.
  local unblocked_chips_html=""
  if [ "${#ready_planned[@]}" -gt 0 ]; then
    local uq_i=0 uq_stem uq_root uq_breadcrumb uq_anchor uq_fam_anchor uq_ra
    while IFS= read -r uq_stem; do
      uq_i=$((uq_i + 1)); [ "$uq_i" -gt 12 ] && break
      uq_root="${_m_family_root[$uq_stem]:-$uq_stem}"
      uq_breadcrumb="top-level"
      [ "$uq_root" != "$uq_stem" ] && uq_breadcrumb="$(wb_board_html_escape "${_m_title[$uq_root]:-$uq_root}")"
      wb_board_v2_anchor "$uq_stem" uq_anchor
      wb_board_v2_anchor "$uq_root" uq_fam_anchor
      wb_board_v2_repo_attr "$uq_stem" uq_ra
      unblocked_chips_html+="<span class=\"qs-chip planned copyable\" data-stem=\"$uq_stem\" data-anchor=\"$uq_anchor\" data-family=\"$uq_fam_anchor\"${uq_ra} data-copy=\"wb resume $uq_stem\">$(wb_board_html_escape "${_m_title[$uq_stem]:-$uq_stem}") <span class=\"breadcrumb\">&#8618; ${uq_breadcrumb}</span></span>"
    done < <(wb_board_v2_sort_stems_by_title "${ready_planned[@]}")
    [ "${#ready_planned[@]}" -gt 12 ] && unblocked_chips_html+="<span class=\"qs-chip planned\" style=\"opacity:.6;\">+$(( ${#ready_planned[@]} - 12 )) more</span>"
  fi

  local -a shelf_paused=()
  local sp_stem
  for sp_stem in "${!_m_stem_anchor[@]}"; do
    [ "${_m_status[$sp_stem]:-}" = paused ] && shelf_paused+=("$sp_stem")
  done
  local shelf_chips_html=""
  if [ "${#shelf_paused[@]}" -gt 0 ]; then
    local sc_i=0 sc_stem sc_h="" sc_sh="" sc_a="" sc_fa="" sc_ra=""
    while IFS= read -r sc_stem; do
      sc_i=$((sc_i + 1)); [ "$sc_i" -gt 12 ] && break
      wb_board_html_escape "${_m_title[$sc_stem]:-$sc_stem}" sc_h
      wb_board_html_escape "$sc_stem" sc_sh
      wb_board_v2_anchor "$sc_stem" sc_a
      wb_board_v2_anchor "${_m_family_root[$sc_stem]:-$sc_stem}" sc_fa
      # fix(review) P1: carry data-repo like the sibling unblocked_chips_html
      # (both are .qs-chip). Without it, applyRepo()'s data-repo match drops
      # every shelf chip when any specific repo is picked (empty Shelf row, no
      # empty-state), since a missing data-repo reads as '' and never matches.
      wb_board_v2_repo_attr "$sc_stem" sc_ra
      shelf_chips_html+="<span class=\"qs-chip shelf copyable\" data-stem=\"$sc_sh\" data-anchor=\"$sc_a\" data-family=\"$sc_fa\"${sc_ra} data-copy=\"wb resume $sc_sh\">$sc_h</span>"
    done < <(wb_board_v2_sort_stems_by_title "${shelf_paused[@]}")
    [ "${#shelf_paused[@]}" -gt 12 ] && shelf_chips_html+="<span class=\"qs-chip shelf\" style=\"opacity:.6;\">+$(( ${#shelf_paused[@]} - 12 )) more</span>"
  fi

  # UX pass: "N shelved" in the week header used to be a dead number with
  # no way to see what it counted. It's now a toggle whose body lists the
  # whole shelved bucket MINUS done (paused/prospective/planned — the
  # things you could actually pull back off the shelf); `done` is most of
  # the bucket's mass and listing it would be noise, so the body carries
  # its own "N of M shelved" count line rather than silently disagreeing
  # with the header. Rendered with out-var escape/anchor calls (D2A), no
  # per-row subshell — this runs to a couple of hundred rows store-wide.
  local -a wk_shelf_stems=()
  local wsh_stem
  for wsh_stem in "${!_m_stem_anchor[@]}"; do
    [ "${_m_bucket[$wsh_stem]:-}" = shelved ] || continue
    [ "${_m_status[$wsh_stem]:-}" = done ] && continue
    wk_shelf_stems+=("$wsh_stem")
  done
  local wk_shelf_rows_html=""
  if [ "${#wk_shelf_stems[@]}" -gt 0 ]; then
    local ws_stem ws_h="" ws_sh="" ws_a="" ws_fa="" ws_st="" ws_open="" ws_ra=""
    while IFS= read -r ws_stem; do
      wb_board_html_escape "${_m_title[$ws_stem]:-$ws_stem}" ws_h
      wb_board_html_escape "$ws_stem" ws_sh
      wb_board_html_escape "${_m_status[$ws_stem]:-}" ws_st
      wb_board_v2_anchor "$ws_stem" ws_a
      wb_board_v2_anchor "${_m_family_root[$ws_stem]:-$ws_stem}" ws_fa
      wb_board_v2_task_open_html "$ws_stem" ws_open
      wb_board_v2_repo_attr "$ws_stem" ws_ra
      wk_shelf_rows_html+="<div class=\"wk-shelf-row\" data-stem=\"$ws_sh\" data-anchor=\"$ws_a\" data-family=\"$ws_fa\"${ws_ra}><span class=\"shelf-dot\"></span><span class=\"t\">$ws_h</span><span class=\"st\">$ws_st</span><span class=\"id mono copyable\" data-copy=\"wb resume $ws_sh\">$ws_sh</span>${ws_open}</div>"
    done < <(wb_board_v2_sort_stems_by_title "${wk_shelf_stems[@]}")
  fi

  local week_view_html
  week_view_html="<header class=\"week-header\"><h1>Week ${week_num} &middot; ${mon_label}&ndash;${sun_label}</h1><div class=\"summary\"><b class=\"n-active\">${_m_bucket_count[active]:-0} active</b> &middot; <b class=\"n-stale\">${_m_bucket_count[stale]:-0} stale</b> &middot; <b class=\"n-shelved\" id=\"wk-shelf-toggle\" onclick=\"toggleWeekShelf()\" title=\"show the shelf\">${_m_bucket_count[shelved]:-0} shelved <span class=\"caret\">&#9656;</span></b></div></header>"
  week_view_html+="<div class=\"wk-shelf-detail\" id=\"wk-shelf-detail\"><p class=\"region-label\">Shelf &middot; ${#wk_shelf_stems[@]} of ${_m_bucket_count[shelved]:-0} shelved &mdash; done excluded</p><div class=\"wk-shelf-list\">${wk_shelf_rows_html:-<span style=\"color:var(--subtext);\">Shelf is empty.</span>}</div></div>"
  week_view_html+='<div class="scope-header" id="week-scope-header" style="display:none;"></div>'
  week_view_html+='<section class="region"><p class="region-label">This week</p>'
  if [ -n "$week_cards_html" ]; then
    week_view_html+="$week_cards_html"
  else
    week_view_html+='<p style="color:var(--subtext);">Nothing touched yet this week.</p>'
  fi
  week_view_html+='</section><section class="region"><p class="region-label">Carried over</p>'
  [ -n "$family_blocks_html" ] && week_view_html+="$family_blocks_html"
  [ -n "$carried_list_html" ] && week_view_html+="<div class=\"carried-list\">${carried_list_html}</div>"
  if [ "${#stale_stems[@]}" -gt 0 ]; then
    week_view_html+="<div class=\"week-stale-toggle\" id=\"wk-stale-toggle\" onclick=\"toggleWeekStale()\"><span class=\"caret\">&#9656;</span><span class=\"dot red\"></span>Stale &middot; ${#stale_stems[@]} &mdash; needs review</div>"
    week_view_html+="<div class=\"week-stale-detail\" id=\"wk-stale-detail\"><div class=\"carried-list\" style=\"margin-top:8px;\">${week_stale_rows_html}</div></div>"
  fi
  if [ -z "$family_blocks_html" ] && [ -z "$carried_list_html" ] && [ "${#stale_stems[@]}" -eq 0 ]; then
    week_view_html+='<p style="color:var(--subtext);">Nothing carried over.</p>'
  fi
  week_view_html+='</section><section class="region"><p class="region-label">Queue &amp; shelf</p>'
  week_view_html+="<div class=\"qs-subrow\"><div class=\"qs-label\">Unblocked next</div><div class=\"qs-chip-row\">${unblocked_chips_html:-<span style=\"color:var(--subtext);font-size:14px;\">Nothing ready.</span>}</div></div>"
  week_view_html+="<div class=\"qs-subrow\"><div class=\"qs-label\">Shelf</div><div class=\"qs-chip-row\">${shelf_chips_html:-<span style=\"color:var(--subtext);font-size:14px;\">Shelf is empty.</span>}</div></div>"
  week_view_html+='</section>'

  # =========================================================================
  # FAMILY VIEW (U6, R17's fourth view + D2): a version-ladder (mockup D)
  # when the family root's Plan carries a "### Version ladder status" table,
  # else a flat family (children tree + mockup A's decisions timeline +
  # artifact links). Every family (any stem with >=1 child) gets a block,
  # ALL pre-rendered and toggled client-side by the family picker — a
  # server-side "render just the selected family" would need a second pass
  # per pick, which R15's single ≤10s render doesn't have room for.
  # =========================================================================
  local -a all_family_roots=()
  local fr_stem
  for fr_stem in "${!_m_family_children[@]}"; do
    [ -n "${_m_family_children[$fr_stem]:-}" ] && all_family_roots+=("$fr_stem")
  done
  local -a all_family_roots_sorted=()
  if [ "${#all_family_roots[@]}" -gt 0 ]; then
    while IFS= read -r fr_stem; do all_family_roots_sorted+=("$fr_stem"); done < <(wb_board_v2_sort_stems_by_title "${all_family_roots[@]}")
  fi

  # fix(perf, U5/U6): __h/__al below are scratch out-vars for the
  # plain-statement forms of wb_board_html_escape/wb_board_v2_age_label
  # (D2A's convention) — this loop runs per family member/decision/
  # artifact across the whole store, so a `$(...)` subshell at every call
  # site here would be exactly the per-call fork cost U2's own timing
  # notes warn against. Reused across iterations on purpose (scratch,
  # consumed immediately after each call, never read stale).
  local __h="" __h2="" __h3="" __h4="" __al="" __open="" __strip="" __ca="" __cra="" __crb=""
  local rail_family_html="" fam_blocks_html="" fam_idx=0 fam_json_entries=""
  for fr_stem in "${all_family_roots_sorted[@]}"; do
    fam_idx=$((fam_idx + 1))
    # A dangling `parent:` (no existence check, a known pre-existing P3 —
    # see wb_board_v2_family_root's cycle-guard comment) can make a
    # FAMILY_CHILDREN key a phantom stem with no real collected row, so
    # STEM_ANCHOR has no entry for it — compute the anchor fresh instead of
    # looking it up, which is also safer: a hand-typed parent: value is
    # never run through the real stems' [A-Za-z0-9._-] filename invariant,
    # so it needs its own sanitizing before landing in a DOM id/JS call.
    local fr_anchor; wb_board_v2_anchor "$fr_stem" fr_anchor
    # fix(review) P1: the same "phantom stem" risk above applies to fr_stem
    # ITSELF wherever it's rendered as HTML text/attribute, not just to the
    # DOM anchor — a hand-typed `parent:` value can carry `<`/`"`/`&` and
    # this codebase's own comment on the anchor above already names the
    # risk without closing it out here. Escape once, reuse everywhere below
    # (element text AND `data-copy="..."` — wb_board_html_escape's `"`
    # handling makes it safe for both contexts) instead of interpolating
    # the raw stem at each site.
    local fr_stem_h; wb_board_html_escape "$fr_stem" fr_stem_h
    local fr_open; wb_board_v2_task_open_html "$fr_stem" fr_open
    local fr_ra fr_rb; wb_board_v2_repo_bits "$fr_stem" fr_ra fr_rb
    local fr_strip fr_strip_mini
    wb_board_v2_stage_strip_html "$fr_stem" fr_strip
    wb_board_v2_stage_strip_html "$fr_stem" fr_strip_mini mini
    local fr_kids="${_m_family_children[$fr_stem]}"
    local -a fr_members=("$fr_stem")
    local fr_c
    while IFS= read -r fr_c; do [ -n "$fr_c" ] && fr_members+=("$fr_c"); done <<< "$fr_kids"
    local fr_total=${#fr_members[@]} fr_done=0 fr_m
    for fr_m in "${fr_members[@]}"; do [ "${_m_status[$fr_m]:-}" = done ] && fr_done=$((fr_done + 1)); done

    # U5 (family DAG view): build the child node list (fr_members minus index
    # 0, the root — R3) and call wb_board_deps_layer (U3) ONCE per family.
    # DEPS_OF/CYCLE_MEMBER/UNMET_COUNT are the store-wide, stem-keyed maps
    # this function already builds above (R19); _m_status/_m_size are
    # render_v2's own model namerefs — passing a nameref-to-a-nameref as an
    # argument here is ordinary bash indirection, not the circular-nameref
    # trap (that trap is same-NAME collision, and dl_status/dl_size inside
    # wb_board_deps_layer are differently named). fd_* out-arrays are
    # `local` INSIDE this `for` loop body, so bash re-declares (and thus
    # resets) them fresh every family iteration — U3 also resets its own
    # outputs unconditionally at its own top, so no value can ever leak
    # from one family into the next either way. Called unconditionally
    # (every family, edges or not) because the rollup JSON below (R13)
    # always needs layer/critical/startable/remaining/critical_path, even
    # for a zero-edge family — only the HTML region itself (below) is
    # gated on there being >=1 edge to draw (R8).
    local -a fd_nodes=("${fr_members[@]:1}")
    local -A fd_layer=() fd_order=() fd_critical=() fd_startable=() fd_extblk=() fd_tag=()
    local -a fd_edges=() fd_backedges=() fd_critpath=()
    local fd_remaining=0 fd_maxlayer=-1

    wb_board_deps_layer fd_nodes DEPS_OF CYCLE_MEMBER UNMET_COUNT _m_status _m_size \
      fd_layer fd_order fd_critical fd_startable fd_extblk fd_tag fd_edges fd_backedges \
      fd_critpath fd_remaining fd_maxlayer
    local fd_edge_count=$(( ${#fd_edges[@]} + ${#fd_backedges[@]} ))
    # U4's HTML region, built now (needs fr_anchor, computed above) so it's
    # ready to splice in right after fam-summary below regardless of which
    # shape (ladder/flat) follows it (R8: same region, both shapes).
    local fd_dag_html=""
    if [ "$fd_edge_count" -gt 0 ]; then
      wb_board_v2_dag_html "$fr_anchor" fd_nodes fd_layer fd_order fd_critical fd_startable \
        fd_extblk fd_tag fd_edges fd_backedges fd_critpath "$fd_remaining" "$fd_maxlayer" \
        "$fr_stem" fd_dag_html
    fi
    # R13 rollup fields: remaining in size POINTS (doubled/2, ".5" when odd —
    # same convention wb_board_v2_dag_html's own header line uses), and the
    # critical-path stem array, JSON-escaped.
    local fd_pts_whole=$(( fd_remaining / 2 )) fd_pts_rem=$(( fd_remaining % 2 )) fd_remaining_json
    if [ "$fd_pts_rem" -eq 0 ]; then fd_remaining_json="$fd_pts_whole"; else fd_remaining_json="${fd_pts_whole}.5"; fi
    local fd_json_critpath="" fd_cp_i __hcp
    for fd_cp_i in "${!fd_critpath[@]}"; do
      [ "$fd_cp_i" -gt 0 ] && fd_json_critpath+=","
      wb_board_v2_json_escape "${fd_critpath[$fd_cp_i]}" __hcp
      fd_json_critpath+="\"${__hcp}\""
    done

    local fam_sel_cls=""
    [ "$fam_idx" = 1 ] && fam_sel_cls=" selected"
    wb_board_html_escape "${_m_title[$fr_stem]:-$fr_stem}" __h
    # UX follow-up: family selection moved from a top-of-page chip grid
    # (33+ families wrapped into an "overwhelming" block) to a rail-row
    # list, the same nav surface Active/Roadmap/Week already use. Reuses
    # the rail's own `.dot`/`.rail-row-title` visual language so it reads
    # as "the same sidebar, a different list" rather than a new widget.
    local fam_dot; fam_dot="$(wb_board_v2_dot_class "${_m_status[$fr_stem]:-}" "${_m_bucket[$fr_stem]:-}" "${_m_age_days[$fr_stem]:-0}")"
    rail_family_html+="<div class=\"rail-row fam-rail-row${fam_sel_cls}\"${fr_ra} data-fam=\"${fr_anchor}\" data-stem=\"${fr_stem_h}\" data-anchor=\"${fr_anchor}\" data-family=\"${fr_anchor}\" onclick=\"selectFamily('${fr_anchor}')\"><span class=\"dot ${fam_dot}\"></span><span class=\"rail-row-title\">${__h}</span><span class=\"rail-row-age mono\">${fr_done}/${fr_total}</span></div>"

    # Decisions timeline: parent + every child, date-sorted. One `sort`
    # fork per family (bounded to the family count, not the whole store) —
    # the per-member entry extraction itself is a plain-statement call
    # (zero forks; see wb_board_v2_decisions_entries's perf note).
    local fr_decisions_raw="" fr_m2 __fr_dec_entry
    for fr_m2 in "${fr_members[@]}"; do
      wb_board_v2_decisions_entries "${_m_decisions_raw[$fr_m2]:-}" "$fr_m2" __fr_dec_entry
      fr_decisions_raw+="$__fr_dec_entry"
    done
    local fr_decisions_sorted="" fr_decisions_total=0
    # Cap to the fr_dec_cap most recent entries (tail of the ascending
    # sort) — a large family's full-store decisions text can run into
    # hundreds of KB once every member's history is concatenated, and
    # bash's `${var//pat/repl}` substitution (wb_board_escape_replacement +
    # the page-template token swap below) measurably does not scale
    # linearly at that size (verified: ~0.85s for a 210KB string with many
    # `&` entities alone) — capping content volume is the same lever
    # RM_CAP/the 12-item chip caps elsewhere in this file already use for
    # exactly this class of store-wide-scale concern.
    local -i fr_dec_cap=20
    local fr_decisions_full_sorted=""
    if [ -n "$fr_decisions_raw" ]; then
      fr_decisions_sorted="$(printf '%s' "$fr_decisions_raw" | sort -t $'\t' -k1,1)"
      fr_decisions_full_sorted="$fr_decisions_sorted"   # U5 JSON side-output: uncapped
      fr_decisions_total="$(printf '%s\n' "$fr_decisions_sorted" | grep -c . || true)"
      if [ "$fr_decisions_total" -gt "$fr_dec_cap" ]; then
        fr_decisions_sorted="$(printf '%s\n' "$fr_decisions_sorted" | tail -n "$fr_dec_cap")"
      fi
    fi

    # Artifact links: parent + every child, deduped on (kind,PATH — fix(review)
    # P1: was (kind,label), and label is just a basename, so two distinct
    # files sharing a name (e.g. two dossiers each with their own plan.md)
    # collapsed into one and silently dropped the other's link) — a doc
    # cited by both a parent and a child collapses to one entry, first-seen
    # source wins the tag. wb_board_v2_classify_link is a plain-statement
    # nameref call (no `$(...)` fork) — this loop runs once per link line
    # per family member across the whole store, so a subshell here would be
    # the same per-file fork cost U2's timing notes warn against.
    local -A fr_link_seen=()
    local -a fr_link_kind=() fr_link_label=() fr_link_path=() fr_link_source=()
    local -a fr_link_href=() fr_link_abs=() fr_link_missing=()
    local fr_m3 fr_link_line fr_kind fr_label fr_path fr_href fr_abs fr_gone
    for fr_m3 in "${fr_members[@]}"; do
      while IFS= read -r fr_link_line; do
        [ -n "$fr_link_line" ] || continue
        wb_board_v2_classify_link "$fr_link_line" fr_kind fr_label fr_path
        local fr_dedupe_key="${fr_kind}"$'\x1f'"${fr_path}"
        [ -n "${fr_link_seen[$fr_dedupe_key]:-}" ] && continue
        fr_link_seen["$fr_dedupe_key"]=1
        # Resolve to an openable absolute path/URL once, here, where the
        # OWNING member's `repo:` is still in hand — the render sites below
        # group by kind and no longer know which task cited what.
        wb_board_v2_resolve_link "$fr_path" "${_m_repo[$fr_m3]:-}" fr_href fr_abs fr_gone
        fr_link_kind+=("$fr_kind"); fr_link_label+=("$fr_label"); fr_link_path+=("$fr_path"); fr_link_source+=("$fr_m3")
        fr_link_href+=("$fr_href"); fr_link_abs+=("$fr_abs"); fr_link_missing+=("$fr_gone")
      done <<< "${_m_links_raw[$fr_m3]:-}"
    done

    local fam_body_html=""
    local fr_ladder; fr_ladder="$(wb_board_v2_parse_ladder_table "${_m_plan_raw[$fr_stem]:-}")"

    # U5 (parked item 6): the machine-readable rollup, built from the SAME
    # per-family data the HTML above reads (no second pass) — written to
    # family-rollup.json after the loop as a by-product for future
    # `/handoff` fan-out. Decisions here are the FULL (uncapped) set, not
    # the display-capped one — a downstream consumer fanning out to
    # `/handoff` wants the whole history, not just what fits on one page.
    local fr_json_children="" fr_jc_i
    for fr_jc_i in "${!fr_members[@]}"; do
      [ "$fr_jc_i" -gt 0 ] && fr_json_children+=","
      local fr_jc_m="${fr_members[$fr_jc_i]}"
      wb_board_v2_json_escape "${_m_title[$fr_jc_m]:-$fr_jc_m}" __h
      # fix(review) P2: id is a raw stem — real child stems are already
      # filename-safe (D5's collect-time invariant), but fr_jc_m at index 0
      # is fr_stem itself, which for a family root can be an unsanitized
      # hand-typed `parent:` value (the same "phantom stem" risk noted
      # below) — escape uniformly rather than special-casing index 0.
      wb_board_v2_json_escape "$fr_jc_m" __h2
      # fix(review): status comes from frontmatter and is otherwise interpolated
      # raw — escape it like id/title so a hand-edited status: never breaks the
      # rollup's JSON validity for a downstream jq consumer.
      local __hs; wb_board_v2_json_escape "${_m_status[$fr_jc_m]:-}" __hs
      # fix(review) D2: emit repo so a multi-repo /handoff consumer can route each
      # child without re-deriving it (_m_repo is already in scope).
      local __hrepo; wb_board_v2_json_escape "${_m_repo[$fr_jc_m]:-}" __hrepo
      # U5 (family DAG view, R13): size/layer/critical/startable. The ROOT
      # (index 0) is never a wb_board_deps_layer node (R3 — fd_nodes is
      # fr_members MINUS the root), so it never has an fd_layer/fd_critical/
      # fd_startable entry to look up — its layer is the literal JSON `null`
      # and critical/startable are `false`, per the unit brief, rather than
      # falling through to a fd_*[$fr_jc_m]:-0 default that would silently
      # read as layer 0 instead. Its `size:` is still emitted raw, same as
      # every child.
      local __hsize; wb_board_v2_json_escape "${_m_size[$fr_jc_m]:-}" __hsize
      local fr_jc_layer_json fr_jc_crit_json fr_jc_start_json fr_jc_parent_json
      if [ "$fr_jc_i" = 0 ]; then
        fr_jc_layer_json="null"; fr_jc_crit_json="false"; fr_jc_start_json="false"; fr_jc_parent_json="true"
      else
        fr_jc_layer_json="${fd_layer[$fr_jc_m]:-0}"; fr_jc_parent_json="false"
        [ "${fd_critical[$fr_jc_m]:-0}" = 1 ] && fr_jc_crit_json="true" || fr_jc_crit_json="false"
        [ "${fd_startable[$fr_jc_m]:-0}" = 1 ] && fr_jc_start_json="true" || fr_jc_start_json="false"
      fi
      fr_json_children+="{\"id\":\"${__h2}\",\"title\":\"${__h}\",\"repo\":\"${__hrepo}\",\"status\":\"${__hs}\",\"age_days\":${_m_age_days[$fr_jc_m]:-0},\"is_parent\":${fr_jc_parent_json},\"size\":\"${__hsize}\",\"layer\":${fr_jc_layer_json},\"critical\":${fr_jc_crit_json},\"startable\":${fr_jc_start_json}}"
    done
    local fr_json_decisions="" fr_jd_first=1 fr_jd_date fr_jd_text fr_jd_src
    if [ -n "$fr_decisions_full_sorted" ]; then
      while IFS=$'\t' read -r fr_jd_date fr_jd_text fr_jd_src; do
        [ -n "${fr_jd_date:-}" ] || continue
        [ "$fr_jd_first" = 1 ] || fr_json_decisions+=","
        fr_jd_first=0
        wb_board_v2_json_escape "$fr_jd_text" __h
        local __hsrc; wb_board_v2_json_escape "$fr_jd_src" __hsrc
        fr_json_decisions+="{\"date\":\"${fr_jd_date}\",\"text\":\"${__h}\",\"source\":\"${__hsrc}\"}"
      done <<< "$fr_decisions_full_sorted"
    fi
    local fr_json_artifacts="" fr_ja_i
    for fr_ja_i in "${!fr_link_kind[@]}"; do
      [ "$fr_ja_i" -gt 0 ] && fr_json_artifacts+=","
      wb_board_v2_json_escape "${fr_link_label[$fr_ja_i]}" __h
      wb_board_v2_json_escape "${fr_link_path[$fr_ja_i]}" __h2
      local __hasrc; wb_board_v2_json_escape "${fr_link_source[$fr_ja_i]}" __hasrc
      # fix(review) D2: also emit the RESOLVED link the HTML uses (abs path,
      # file:// href, missing-on-disk flag), computed at :2639 just above — so a
      # /handoff-consuming agent gets the same openable path a human gets from
      # the HTML, not the raw as-authored relative path it can't resolve alone.
      # `path` stays for back-compat / provenance (additive, per D2 option A).
      local __habs __href __amiss
      wb_board_v2_json_escape "${fr_link_abs[$fr_ja_i]}" __habs
      wb_board_v2_json_escape "${fr_link_href[$fr_ja_i]}" __href
      [ -n "${fr_link_missing[$fr_ja_i]}" ] && __amiss=true || __amiss=false
      fr_json_artifacts+="{\"kind\":\"${fr_link_kind[$fr_ja_i]}\",\"label\":\"${__h}\",\"path\":\"${__h2}\",\"abs\":\"${__habs}\",\"href\":\"${__href}\",\"missing\":${__amiss},\"source\":\"${__hasrc}\"}"
    done
    local fr_json_rungs="" fr_jr_first=1 fr_jr_line
    if [ -n "$fr_ladder" ]; then
      while IFS= read -r fr_jr_line; do
        [ -n "$fr_jr_line" ] || continue
        local fr_jr_rung="${fr_jr_line%%$'\t'*}" fr_jr_rest="${fr_jr_line#*$'\t'}"
        local fr_jr_ticket="${fr_jr_rest%%$'\t'*}"; fr_jr_rest="${fr_jr_rest#*$'\t'}"
        local fr_jr_wbtask="${fr_jr_rest%%$'\t'*}" fr_jr_status_cell="${fr_jr_rest#*$'\t'}"
        local fr_jr_child; wb_board_v2_ladder_child_stem "$fr_jr_wbtask" fr_jr_child
        local fr_jr_resolved=""
        [ -n "$fr_jr_child" ] && fr_jr_resolved="${_m_status[$fr_jr_child]:-}"
        local fr_jr_cls; wb_board_v2_ladder_status_class "$fr_jr_resolved" "$fr_jr_status_cell" fr_jr_cls
        [ "$fr_jr_first" = 1 ] || fr_json_rungs+=","
        fr_jr_first=0
        wb_board_v2_json_escape "$fr_jr_rung" __h
        wb_board_v2_json_escape "$fr_jr_ticket" __h2
        local __hchild; wb_board_v2_json_escape "$fr_jr_child" __hchild
        fr_json_rungs+="{\"rung\":\"${__h}\",\"ticket\":\"${__h2}\",\"child\":\"${__hchild}\",\"status\":\"${fr_jr_cls}\"}"
      done <<< "$fr_ladder"
    fi
    wb_board_v2_json_escape "${_m_title[$fr_stem]:-$fr_stem}" __h
    wb_board_v2_json_escape "$fr_stem" __h2
    [ "$fam_idx" -gt 1 ] && fam_json_entries+=","
    local fr_shape_json=flat; [ -n "$fr_ladder" ] && fr_shape_json=ladder
    fam_json_entries+="{\"root\":\"${__h2}\",\"title\":\"${__h}\",\"shape\":\"${fr_shape_json}\",\"children\":[${fr_json_children}],\"decisions\":[${fr_json_decisions}],\"artifacts\":[${fr_json_artifacts}],\"rungs\":[${fr_json_rungs}],\"critical_path\":[${fd_json_critpath}],\"remaining\":${fd_remaining_json}}"

    # Round 3 item 6: every family block opens with the SAME summary-first
    # header the Active and Week views show when you expand a task — status,
    # repo, stage strip, PR, and the Now line for the family's parent task.
    # Selecting a family used to drop you straight into a tree/ladder with
    # no answer to "what is this and what's happening on it".
    #
    # Rendered INLINE, not mounted from #detail-pool: a pool block is one
    # node and may already be mounted in another view, and moving it here
    # would silently empty that slot. Both paths build it from
    # wb_board_v2_summary_header_html, so they cannot drift.
    local fr_summary; wb_board_v2_summary_header_html "$fr_stem" fr_summary
    fam_body_html+="<div class=\"fam-summary detail\">${fr_summary}</div>"

    # U5 (family DAG view, R8): the Dependencies region sits right after the
    # summary header and BEFORE the ladder/flat branch below, so both shapes
    # share the identical region rather than each needing its own copy — a
    # family with zero intra-family edges renders neither (ladder shape) or
    # a `depends_on:` empty-state instead (flat shape only, inside that
    # branch, right before "Family tree" — see below).
    if [ "$fd_edge_count" -gt 0 ]; then
      fam_body_html+="$fd_dag_html"
    fi

    if [ -n "$fr_ladder" ]; then
      # ---- LADDER SHAPE (mockup D) ----
      fam_body_html+="<h2 class=\"region-label\">Version ladder</h2>"
      fam_body_html+='<div class="ladder">'
      local fr_rung_line fr_rung_i=0
      while IFS= read -r fr_rung_line; do
        [ -n "$fr_rung_line" ] || continue
        fr_rung_i=$((fr_rung_i + 1))
        local fr_rung="${fr_rung_line%%$'\t'*}" fr_rest="${fr_rung_line#*$'\t'}"
        local fr_ticket="${fr_rest%%$'\t'*}"; fr_rest="${fr_rest#*$'\t'}"
        local fr_wbtask_cell="${fr_rest%%$'\t'*}" fr_status_cell="${fr_rest#*$'\t'}"
        local fr_child; wb_board_v2_ladder_child_stem "$fr_wbtask_cell" fr_child
        local fr_resolved_status="" fr_child_anchor=""
        local fr_rung_child_html='<span class="rung-child none">no child task yet</span>'
        if [ -n "$fr_child" ] && [ -n "${_m_status[$fr_child]:-}" ]; then
          fr_resolved_status="${_m_status[$fr_child]}"
          wb_board_v2_task_open_html "$fr_child" __open
          wb_board_v2_stage_strip_html "$fr_child" __strip mini
          wb_board_v2_anchor "$fr_child" fr_child_anchor
          DETAIL_WANT["$fr_child"]=1
          fr_rung_child_html="<span class=\"rung-child mono copyable\" data-copy=\"wb resume ${fr_child}\">&#8618; <span class=\"id\">${fr_child}</span></span>${__open}${__strip}"
        fi
        local fr_rcls; wb_board_v2_ladder_status_class "$fr_resolved_status" "$fr_status_cell" fr_rcls
        local fr_active_cls=""
        [ "$fr_rcls" = active ] && fr_active_cls=" active expanded"
        local fr_now_tag=""
        [ "$fr_rcls" = active ] && fr_now_tag='<span class="fam-today-tag">now</span>'
        local fr_status_label="$fr_rcls"
        [ "$fr_rcls" = unfiled ] && fr_status_label="not yet filed"
        fam_body_html+="<div class=\"rung ${fr_rcls}${fr_active_cls}\" id=\"rung-${fr_anchor}-${fr_rung_i}\">"
        fam_body_html+="<span class=\"rung-node ${fr_rcls}\"></span>"
        fam_body_html+="<div class=\"rung-head\" onclick=\"toggleRung('rung-${fr_anchor}-${fr_rung_i}')\">"
        wb_board_html_escape "$fr_rung" __h
        fam_body_html+="<span class=\"rung-ver mono\" title=\"${__h}\">${__h}</span>"
        wb_board_html_escape "$fr_ticket" __h
        fam_body_html+="<span class=\"rung-goal\" title=\"${__h}\">${__h}</span>"
        wb_board_html_escape "$fr_status_label" __h
        fam_body_html+="<span class=\"rung-status-pill ${fr_rcls}\">${__h}${fr_now_tag}</span>"
        fam_body_html+="${fr_rung_child_html}"
        fam_body_html+='<span class="rung-caret">&#9656;</span></div>'
        [ -z "$fr_child" ] || fam_body_html+="<div class=\"detail-host\" data-anchor=\"${fr_child_anchor}\"></div>"
        fam_body_html+='<div class="rung-body"><div class="rung-grid"><div><h4>Decisions</h4><ul>'
        local fr_rd_found=0
        if [ -n "$fr_child" ] && [ -n "$fr_decisions_sorted" ]; then
          local fr_rd_date fr_rd_text fr_rd_src
          while IFS=$'\t' read -r fr_rd_date fr_rd_text fr_rd_src; do
            [ -n "${fr_rd_date:-}" ] || continue
            [ "$fr_rd_src" = "$fr_child" ] || continue
            wb_board_html_escape "$fr_rd_text" __h
            fam_body_html+="<li class=\"decision-item\">${__h}</li>"
            fr_rd_found=1
          done <<< "$fr_decisions_sorted"
        fi
        [ "$fr_rd_found" = 1 ] || fam_body_html+='<li class="empty">None yet.</li>'
        fam_body_html+='</ul></div><div><h4>Artifacts</h4><ul>'
        local fr_ra_found=0 fr_ra_i
        if [ -n "$fr_child" ]; then
          for fr_ra_i in "${!fr_link_source[@]}"; do
            [ "${fr_link_source[$fr_ra_i]}" = "$fr_child" ] || continue
            wb_board_html_escape "${fr_link_abs[$fr_ra_i]}" __h2
            wb_board_html_escape "${fr_link_abs[$fr_ra_i]##*/}" __h4
            wb_board_html_escape "${fr_link_href[$fr_ra_i]}" __h3
            local fr_ra_cls=""
            [ -n "${fr_link_missing[$fr_ra_i]}" ] && fr_ra_cls=" missing"
            fam_body_html+="<li><a class=\"artifact-link mono${fr_ra_cls}\" href=\"${__h3}\" target=\"_blank\" rel=\"noopener\" title=\"${__h2}\">${__h4}</a><span class=\"copy-ic copyable\" data-copy=\"${__h2}\" title=\"copy path\">&#8865;</span></li>"
            fr_ra_found=1
          done
        fi
        [ "$fr_ra_found" = 1 ] || fam_body_html+='<li class="empty">None yet.</li>'
        fam_body_html+='</ul></div></div></div></div>'
      done <<< "$fr_ladder"
      fam_body_html+='</div>'
    else
      # ---- FLAT SHAPE (mockup A) ----
      local fr_dot; fr_dot="$(wb_board_v2_dot_class "${_m_status[$fr_stem]:-}" "${_m_bucket[$fr_stem]:-}" "${_m_age_days[$fr_stem]:-0}")"
      # U5 (family DAG view, R8): a flat family with zero intra-family edges
      # gets an empty-state here instead of the Dependencies region (which
      # was skipped above) — reuses .scope-empty (the same dashed-grey
      # empty-state class the Active view's repo-filter panel uses) rather
      # than inventing a new visual language for "nothing here yet".
      if [ "$fd_edge_count" -eq 0 ]; then
        fam_body_html+='<div class="scope-empty">No dependency data yet &mdash; add <code>depends_on:</code> to its children to see the graph.</div>'
      fi
      fam_body_html+="<h2 class=\"region-label\">Family tree</h2>"
      wb_board_html_escape "${_m_title[$fr_stem]:-$fr_stem}" __h
      wb_board_v2_age_label "${_m_age_days[$fr_stem]:-0}" __al
      fam_body_html+="<div class=\"fam-hero\"><div class=\"fam-hero-top\"><div><div class=\"fam-hero-title\">${__h}</div><span class=\"fam-hero-id mono copyable\" data-copy=\"wb resume ${fr_stem_h}\">${fr_stem_h}</span>${fr_open}${fr_strip}</div><div class=\"fam-hero-meta\"><span class=\"dot ${fr_dot}\"></span><span class=\"age mono\">${__al}</span></div></div>"
      fam_body_html+='<div class="fam-tree">'
      local fr_p_status="${_m_status[$fr_stem]:-}" fr_p_pill_cls="planned"
      case "$fr_p_status" in doing|review) fr_p_pill_cls="doing" ;; esac
      wb_board_html_escape "${_m_title[$fr_stem]:-$fr_stem}" __h
      wb_board_v2_age_label "${_m_age_days[$fr_stem]:-0}" __al
      wb_board_html_escape "$fr_p_status" __h2
      fam_body_html+="<div class=\"fam-tree-row parent-row\"><span class=\"branch\">&#9679;</span><div><div class=\"t-title copyable\" data-copy=\"wb resume ${fr_stem_h}\">${__h}</div><span class=\"t-id mono\">${fr_stem_h} &middot; parent</span>${fr_rb}${fr_strip_mini}</div>${fr_open}<span class=\"fam-status-pill ${fr_p_pill_cls}\">${__h2}</span><span class=\"t-age mono\">${__al}</span></div>"
      local fr_child_row
      while IFS= read -r fr_child_row; do
        [ -n "$fr_child_row" ] || continue
        local fr_c_status="${_m_status[$fr_child_row]:-}" fr_c_pill_cls="planned"
        case "$fr_c_status" in doing|review) fr_c_pill_cls="doing" ;; esac
        wb_board_html_escape "${_m_title[$fr_child_row]:-$fr_child_row}" __h
        wb_board_v2_age_label "${_m_age_days[$fr_child_row]:-0}" __al
        wb_board_html_escape "$fr_c_status" __h2
        wb_board_html_escape "$fr_child_row" __h3
        wb_board_v2_task_open_html "$fr_child_row" __open
        wb_board_v2_stage_strip_html "$fr_child_row" __strip mini
        wb_board_v2_anchor "$fr_child_row" __ca
        wb_board_v2_repo_bits "$fr_child_row" __cra __crb
        DETAIL_WANT["$fr_child_row"]=1
        fam_body_html+="<div class=\"fam-tree-row child-row expandable\" data-anchor=\"${__ca}\"${__cra} onclick=\"toggleFamDetail(event,this)\"><span class=\"fam-caret\">&#9656;</span><span class=\"branch\">&#9492;</span><div><div class=\"t-title copyable\" data-copy=\"wb resume ${__h3}\">${__h}</div><span class=\"t-id mono\">${__h3}</span>${__crb}${__strip}</div>${__open}<span class=\"fam-status-pill ${fr_c_pill_cls}\">${__h2}</span><span class=\"t-age mono\">${__al}</span></div><div class=\"detail-host\" data-anchor=\"${__ca}\"></div>"
      done <<< "$fr_kids"
      fam_body_html+='</div></div>'

      local fr_timeline_html=""
      if [ -n "$fr_decisions_sorted" ]; then
        local fr_td_date fr_td_text fr_td_src
        while IFS=$'\t' read -r fr_td_date fr_td_text fr_td_src; do
          [ -n "${fr_td_date:-}" ] || continue
          local fr_src_cls="from-child" fr_src_badge_cls="child-src"
          [ "$fr_td_src" = "$fr_stem" ] && fr_src_cls="from-parent" && fr_src_badge_cls="parent-src"
          wb_board_html_escape "$fr_td_date" __h
          wb_board_html_escape "$fr_td_text" __h2
          wb_board_html_escape "$fr_td_src" __h3
          wb_board_v2_task_open_html "$fr_td_src" __open
          fr_timeline_html+="<div class=\"fam-tl-item ${fr_src_cls}\"><div class=\"fam-tl-date mono\">${__h}</div><div class=\"fam-tl-text\">${__h2}</div><span class=\"fam-tl-source ${fr_src_badge_cls} copyable\" data-copy=\"wb resume ${__h3}\">${__h3}</span>${__open}</div>"
        done <<< "$fr_decisions_sorted"
      fi
      fam_body_html+="<div class=\"fam-section\"><div class=\"fam-section-head\"><h3>Decisions &middot; across the whole family</h3><span class=\"fam-section-sub\">${fr_decisions_total} decisions</span></div>"
      if [ -n "$fr_timeline_html" ]; then
        if [ "$fr_decisions_total" -gt "$fr_dec_cap" ]; then
          fam_body_html+="<p style=\"color:var(--subtext);font-size:13px;margin:0 0 10px;\">Showing the ${fr_dec_cap} most recent &mdash; $(( fr_decisions_total - fr_dec_cap )) earlier decision(s) not shown.</p>"
        fi
        fam_body_html+="<div class=\"fam-timeline\">${fr_timeline_html}</div>"
      else
        fam_body_html+='<p style="color:var(--subtext);">No decisions logged yet.</p>'
      fi
      fam_body_html+='</div>'

      fam_body_html+="<div class=\"fam-section\"><div class=\"fam-section-head\"><h3>Artifacts &middot; grab from the family</h3><span class=\"fam-section-sub\">${#fr_link_kind[@]} links</span></div>"
      if [ "${#fr_link_kind[@]}" -gt 0 ]; then
        fam_body_html+='<div class="fam-art-groups">'
        local fr_kind_want fr_kind_heading
        for fr_kind_want in decision-records plans dossiers claude-ai other; do
          local fr_group_html="" fr_gi
          for fr_gi in "${!fr_link_kind[@]}"; do
            [ "${fr_link_kind[$fr_gi]}" = "$fr_kind_want" ] || continue
            # Every artifact is a real anchor now, showing (and copying)
            # the ABSOLUTE path — a relative `dossiers/x/plan.md` is not
            # openable from logs/board.html, which was the whole point of
            # the ask. fix(review) P1 still holds: the full path, never the
            # basename, is what is displayed, copied and deduped on.
            # Basename as the visible text, full absolute path in title=
            # and on the clipboard. A column of 90-character paths that all
            # share their first 60 characters is unreadable; the name is the
            # part that identifies the doc, and the path is one hover (or
            # one click, via the href) away.
            wb_board_html_escape "${fr_link_abs[$fr_gi]}" __h
            wb_board_html_escape "${fr_link_abs[$fr_gi]##*/}" __h4
            wb_board_html_escape "${fr_link_source[$fr_gi]}" __h2
            wb_board_html_escape "${fr_link_href[$fr_gi]}" __h3
            local fr_gone_cls="" fr_gone_title=""
            if [ -n "${fr_link_missing[$fr_gi]}" ]; then
              fr_gone_cls=" missing"; fr_gone_title=" title=\"not found on disk\""
            fi
            if [ "$fr_kind_want" = claude-ai ]; then
              fr_group_html+="<div class=\"fam-art-row copyable\" data-copy=\"${__h}\"><span class=\"fam-art-icon\">&#128279;</span><a class=\"fam-art-path mono\" href=\"${__h3}\" target=\"_blank\" rel=\"noopener\" title=\"${__h}\">${__h4}</a><span class=\"fam-art-tag\">${__h2}</span><span class=\"fam-art-grab\">copy</span></div>"
            else
              fr_group_html+="<div class=\"fam-art-row copyable${fr_gone_cls}\" data-copy=\"${__h}\"${fr_gone_title}><span class=\"fam-art-icon\">&#128196;</span><a class=\"fam-art-path mono\" href=\"${__h3}\" target=\"_blank\" rel=\"noopener\" title=\"${__h}\">${__h4}</a><span class=\"fam-art-tag\">${__h2}</span><span class=\"fam-art-grab\">copy</span></div>"
            fi
          done
          [ -n "$fr_group_html" ] || continue
          case "$fr_kind_want" in
            decision-records) fr_kind_heading="Decision records" ;;
            plans) fr_kind_heading="Plans" ;;
            dossiers) fr_kind_heading="Dossiers" ;;
            claude-ai) fr_kind_heading="claude.ai artifacts" ;;
            *) fr_kind_heading="Other" ;;
          esac
          fam_body_html+="<div class=\"fam-art-group\"><h4>${fr_kind_heading}</h4><div class=\"fam-art-list\">${fr_group_html}</div></div>"
        done
        fam_body_html+='</div>'
      else
        fam_body_html+='<p style="color:var(--subtext);">No artifacts linked yet.</p>'
      fi
      fam_body_html+='</div>'
    fi

    # (Historical note: this used to call wb_board_escape_replacement per
    # family, because the page template was assembled with a chain of
    # `${page_template//@@TOKEN@@/...}` substitutions and a raw `&` in the
    # REPLACEMENT is a backreference there. Page assembly now walks the
    # template once and appends fragments verbatim — see its own comment —
    # so no fragment needs replacement-escaping at all, and the non-linear
    # `${s//&/\&}` cost this used to split up is simply gone.)
    # .fam-block defaults to display:none in CSS (every block hidden until
    # selectFamily shows one) — the first family needs an explicit inline
    # override, not just the ABSENCE of a hiding style, or it renders blank
    # on load (caught in browser verification: picker chip selected but no
    # body visible).
    local fam_display_style=' style="display:none;"'
    [ "$fam_idx" = 1 ] && fam_display_style=' style="display:block;"'
    fam_blocks_html+="<div class=\"fam-block\" id=\"fam-${fr_anchor}\"${fam_display_style}>${fam_body_html}</div>"
  done

  # U5 (parked item 6): write the family rollup as a machine-readable
  # by-product of this same render pass — no second pass over the store
  # (R16). $TASKS_DIR is the same global cmd_board's own --html branch
  # resolves the task store from. A write failure (e.g. read-only mount in
  # a sandboxed test run) must never break the HTML render itself — this
  # is a side-output, not part of R15's contract.
  mkdir -p "$TASKS_DIR/.board-cache" 2>/dev/null \
    && printf '[%s]\n' "$fam_json_entries" > "$TASKS_DIR/.board-cache/family-rollup.json" 2>/dev/null || true

  local family_view_html=""
  if [ "${#all_family_roots_sorted[@]}" -gt 0 ]; then
    family_view_html="$fam_blocks_html"
  else
    family_view_html='<h2 class="region-label">Family</h2><p style="color:var(--subtext);">No families yet &mdash; a family appears once a task has a <span class="mono">parent:</span> field or at least one child.</p>'
  fi
  local fam_tab_badge="${#all_family_roots_sorted[@]}"

  # =========================================================================
  # U8 — #detail-pool: one summary-first detail block per task, rendered
  # once and moved into place by the JS. Done tasks get the compact shape
  # (header + Now + Done); everything else gets the full set of sections.
  # That split is the R15 budget talking, not the design: there are ~90 done
  # tasks in this store and nobody digs a checklist out of a finished one.
  # =========================================================================
  local detail_pool_html="" dp_stem dp_block=""
  for dp_stem in "${!DETAIL_WANT[@]}"; do
    case "${_m_status[$dp_stem]:-}" in
      done)    wb_board_v2_detail_html "$dp_stem" 1 dp_block ;;
      planned) wb_board_v2_detail_html "$dp_stem" 2 dp_block ;;
      *)       wb_board_v2_detail_html "$dp_stem" 0 dp_block ;;
    esac
    detail_pool_html+="$dp_block"
  done

  # UX follow-up: the family list joins the rail as a second, initially-
  # hidden panel (#rail-families) — showView('family') swaps to it,
  # everything else swaps back to #rail-tasks (see rail_html's own note
  # above).
  if [ -z "$rail_family_html" ]; then
    rail_family_html='<p style="color:var(--subtext);font-size:14px;padding:0 4px;">No families yet.</p>'
  fi
  rail_html+="<div id=\"rail-families\" style=\"display:none;\"><div class=\"rail-heading\">Family</div><div class=\"rail-tree\">${rail_family_html}</div></div>"

  # =========================================================================
  # PAGE ASSEMBLY — heredoc + @@TOKEN@@ substitution: the CSS/skeleton/
  # script are entirely static (translated from board-reference-final.html,
  # "Mockup O"), so they live directly in the single-quoted heredoc; only
  # the per-render HTML fragments built above are substituted in.
  #
  # fix(perf/P3, UX pass): the swap is now a SINGLE walk over the template
  # (wb_board_v2_fill_template below), not the old chain of nine
  # `${page_template//@@TOKEN@@/...}` substitutions. Two reasons, both
  # real:
  #   * cost — each of those nine passes rescanned the whole, already-
  #     grown page (650KB by the last one) for the next token, and bash's
  #     `${var//pat/repl}` is the same non-linear-in-size operation this
  #     file's per-family escaping note already measured. R15's ≤10s
  #     budget was down to ~0.1s of headroom before this.
  #   * correctness — a substituted fragment was itself rescanned by every
  #     LATER substitution, so a task title containing a literal
  #     `@@SOMETHING@@` corrupted the page (a known P3, and there is a task
  #     in the real store whose title says exactly that). The walk appends
  #     fragments verbatim and never looks at them again, which closes it.
  # It also removes the need for wb_board_escape_replacement on every
  # fragment: nothing is a substitution RHS any more, so a raw `&` is just
  # an `&`.
  # =========================================================================
  local tab_badge=$(( ${_m_bucket_count[active]:-0} + ${_m_bucket_count[stale]:-0} ))
  local generated_ts; generated_ts="$(date -d "@$now" '+%Y-%m-%d %H:%M %Z')"

  local page_template
  page_template="$(cat <<'HTMLEOF'
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<title>wb board</title>
<style>
  :root {
    color-scheme: dark;
    --base: #1e1e2e;
    --surface: #313244;
    --overlay: #45475a;
    --text: #cdd6f4;
    --subtext: #a6adc8;
    --mauve: #cba6f7;
    --green: #a6e3a1;
    --yellow: #f9e2af;
    --red: #f38ba8;
    --blue: #89b4fa;
    --peach: #fab387;
  }
  * { box-sizing: border-box; }
  html, body {
    margin: 0; padding: 0; background: var(--base); color: var(--text);
    font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Inter, system-ui, sans-serif;
    font-size: 17px; line-height: 1.65;
  }
  .mono { font-family: "SFMono-Regular", Consolas, "Liberation Mono", Menlo, monospace; }
  .caption { font-size: 13.5px; color: var(--subtext); padding: 10px 24px 0 24px; }
  .gen-ts { margin-top: 28px; padding-top: 14px; border-top: 1px solid var(--overlay); font-size: 12.5px; color: var(--subtext); }

  .page { display: flex; width: min(96vw, 1800px); margin: 0 0 0 24px; padding: 14px 24px 40px 0; gap: 40px; align-items: flex-start; }

  /* ================= LEFT RAIL (outline) ================= */
  /* UX pass: the rail is the board's nav surface, so it must stay on
     screen while a 4000px view scrolls past it — sticky with its own
     scrollbar, filter box pinned at its top. */
  .rail { width: 340px; flex: 0 0 340px; display: flex; flex-direction: column; gap: 20px; padding: 8px; position: sticky; top: 14px; max-height: calc(100vh - 28px); overflow-y: auto; overscroll-behavior: contain; }
  .rail::-webkit-scrollbar { width: 8px; }
  .rail::-webkit-scrollbar-thumb { background: var(--overlay); border-radius: 4px; }
  .rail-filter { width: 100%; box-sizing: border-box; padding: 7px 10px; border-radius: 8px; border: 1px solid var(--overlay); background: var(--surface); color: var(--text); font-size: 14px; }
  .rail-filter::placeholder { color: var(--subtext); }
  .rail-heading { font-size: 12.5px; letter-spacing: 0.06em; text-transform: uppercase; color: var(--subtext); padding: 0 4px 6px 4px; }
  .rail-tree { display: flex; flex-direction: column; gap: 1px; }

  .rail-row { display: flex; align-items: center; gap: 8px; padding: 7px 10px; border-radius: 8px; border: 1px solid transparent; cursor: pointer; font-size: 15px; }
  .rail-row:hover { background: var(--surface); }
  .filter-hidden { display: none !important; }
  .scope-hidden { display: none !important; }
  /* Scope, text filter and repo filter each own their own hiding class, so
     clearing one never resurrects what another hid. */
  .repo-hidden { display: none !important; }

  .repo-chips { display: flex; flex-wrap: wrap; gap: 4px; margin-top: -10px; }
  .repo-chip { font-size: 11.5px; padding: 2px 9px; border-radius: 999px; border: 1px solid var(--overlay); color: var(--subtext); cursor: pointer; user-select: none; white-space: nowrap; }
  .repo-chip:hover { color: var(--text); border-color: var(--subtext); }
  .repo-chip.selected { background: rgba(203,166,247,.14); border-color: var(--mauve); color: var(--mauve); }

  /* Which repo a task belongs to, everywhere a task is named. Dim on
     purpose: it is orientation, not content. */
  .repo-badge { flex: 0 0 auto; font-size: 10.5px; color: var(--subtext); opacity: .7; border: 1px solid var(--overlay); border-radius: 4px; padding: 0 5px; white-space: nowrap; max-width: 120px; overflow: hidden; text-overflow: ellipsis; }
  .card-id + .open-ic + .repo-badge { margin-left: 8px; }
  .detail-head .repo-badge { font-size: 11px; }

  /* UX pass (scope model): `.selected` is the picked rail row, `.scoped`
     the family whose subtree the whole board is narrowed to — both mauve,
     the reserved selection/current colour, nothing else. */
  .rail-row.selected, details.family-node > summary.selected { background: rgba(203,166,247,.12); border-color: var(--mauve); }
  .rail-row.selected .rail-row-title, details.family-node > summary.selected .rail-row-title { color: var(--mauve); }
  details.family-node > summary { border: 1px solid transparent; }
  details.family-node > summary.scoped .rail-row-title { color: var(--mauve); }
  .shelf-row.selected { background: rgba(203,166,247,.12); }
  .shelf-row.selected .shelf-text { color: var(--mauve); }
  .rail-all { color: var(--subtext); }

  /* R22's copy affordance, split off the row title so a primary click
     selects and only this glyph copies. */
  .copy-ic { flex: 0 0 auto; font-size: 12px; color: var(--subtext); opacity: 0; padding: 0 2px; transition: opacity .12s ease; }
  .rail-row:hover .copy-ic, details.family-node > summary:hover .copy-ic, .shelf-row:hover .copy-ic { opacity: .75; }
  .copy-ic:hover { opacity: 1; color: var(--mauve); }

  /* "↗ open the file" — the other half of the copy glyph. Hidden until
     hover in the dense rail; always visible where a task id is the point
     of the row (cards, drilldown headings, family tree, timeline). */
  .open-ic { flex: 0 0 auto; font-size: 12px; color: var(--subtext); text-decoration: none; padding: 0 2px; opacity: .55; transition: opacity .12s ease, color .12s ease; }
  .open-ic:hover { opacity: 1; color: var(--blue); }
  .rail-row .open-ic, details.family-node > summary .open-ic, .shelf-row .open-ic { opacity: 0; }
  .rail-row:hover .open-ic, details.family-node > summary:hover .open-ic, .shelf-row:hover .open-ic { opacity: .75; }
  .drilldown h3 .open-ic { margin-left: 8px; color: var(--mauve); }
  .card-id + .open-ic { margin-left: 6px; }

  /* An artifact whose resolved path is not on disk is MARKED, never
     dropped — a link that has gone stale is worth seeing. */
  .missing .fam-art-path, a.artifact-link.missing { color: var(--red); text-decoration: line-through; text-decoration-color: rgba(243,139,168,.45); }
  .missing .fam-art-icon { color: var(--red); opacity: .8; }
  a.open-ic.missing { color: var(--red); }

  .dot { width: 8px; height: 8px; border-radius: 50%; flex: 0 0 8px; }
  .dot.green { background: var(--green); }
  .dot.yellow { background: var(--yellow); }
  .dot.red { background: var(--red); }
  .dot.blue { background: var(--blue); }
  .dot.muted { background: var(--overlay); }
  .dot.peach { background: var(--peach); }

  .rail-row-title { flex: 1; min-width: 0; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; color: var(--text); }
  .rail-row-age { font-size: 13px; color: var(--subtext); flex: 0 0 auto; text-align: right; min-width: 38px; }
  .rail-pill { flex: 0 0 auto; font-size: 11.5px; font-weight: 600; padding: 1px 7px; border-radius: 20px; background: rgba(137,180,250,0.16); color: var(--blue); letter-spacing: 0.02em; }

  details.family-node { border: none; }
  details.family-node > summary { list-style: none; cursor: pointer; display: flex; align-items: center; gap: 8px; padding: 7px 10px; border-radius: 8px; font-size: 15px; user-select: none; }
  details.family-node > summary::-webkit-details-marker { display: none; }
  details.family-node > summary:hover { background: var(--surface); }
  .chev { width: 10px; flex: 0 0 10px; text-align: center; font-size: 11.5px; color: var(--subtext); transition: transform 0.12s ease; }
  details.family-node[open] > summary .chev { transform: rotate(90deg); }

  .family-children { margin: 1px 0 2px 24px; padding-left: 14px; border-left: 1px solid var(--overlay); display: flex; flex-direction: column; gap: 1px; }
  .family-children .rail-row { font-size: 14.5px; padding: 6px 8px; }

  .group { border-top: 1px solid var(--overlay); padding-top: 14px; }
  .group-head { display: flex; align-items: center; gap: 8px; padding: 4px; cursor: pointer; user-select: none; }
  .group-caret { font-size: 11.5px; color: var(--subtext); width: 10px; text-align: center; transition: transform 0.15s ease; }
  .group.expanded .group-caret { transform: rotate(90deg); }
  .group-label { font-size: 15px; font-weight: 500; }
  .group-label .count-blue { color: var(--blue); }
  .group-label .count-peach { color: var(--peach); }
  .group-body { display: none; flex-direction: column; gap: 1px; margin-top: 6px; padding-left: 18px; }
  .group.expanded .group-body { display: flex; }

  .shelf-row { display: flex; align-items: center; gap: 8px; padding: 6px 8px; border-radius: 6px; font-size: 14px; color: var(--subtext); position: relative; }
  .shelf-row:hover { background: var(--surface); color: var(--text); }
  .shelf-dot { width: 6px; height: 6px; border-radius: 50%; background: var(--peach); flex: 0 0 6px; }
  .shelf-text { flex: 1; min-width: 0; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }

  /* ================= MAIN AREA ================= */
  .main { flex: 1; min-width: 0; padding: 8px; }

  .view-switcher { display: flex; gap: 4px; background: var(--surface); border: 1px solid var(--overlay); border-radius: 10px; padding: 4px; width: fit-content; margin-bottom: 20px; }
  .view-tab { font-size: 14.5px; padding: 7px 16px; border-radius: 7px; color: var(--subtext); cursor: pointer; user-select: none; border: 1px solid transparent; }
  .view-tab:hover { color: var(--text); }
  .view-tab.active { background: rgba(203,166,247,0.14); color: var(--mauve); border-color: rgba(203,166,247,0.35); }
  .tab-badge { font-size: 11.5px; margin-left: 6px; padding: 1px 7px; border-radius: 10px; background: rgba(166,227,161,.14); color: var(--green); }

  .view { display: none; }
  .view.active { display: block; }

  /* ---------- VIEW 1: Active (deck) ---------- */
  h2.region-label { font-size: 12.5px; text-transform: uppercase; letter-spacing: .08em; color: var(--subtext); font-weight: 600; margin: 0 0 12px 2px; }
  .deck-row { display: flex; flex-wrap: wrap; gap: 18px; padding: 8px 4px 14px 4px; }

  /* UX pass: the flex item is now the SLOT (card + its own drilldown), so
     the detail opens in place; a selected slot takes the whole row so the
     3-column drilldown has room and the deck reflows around it. */
  .card-slot { flex: 1 1 340px; max-width: 420px; min-width: 0; display: flex; flex-direction: column; gap: 10px; }
  .card-slot.selected { flex: 1 1 100%; max-width: 100%; }
  .card-caret { color: var(--subtext); font-size: 11.5px; transition: transform .12s ease; }
  .card-slot.selected .card-caret { transform: rotate(90deg); color: var(--mauve); }

  .scope-header { display: flex; align-items: center; gap: 10px; flex-wrap: wrap; margin: 0 4px 12px 4px; padding: 8px 14px; border-radius: 9px; background: rgba(203,166,247,.08); border: 1px solid rgba(203,166,247,.3); font-size: 14.5px; color: var(--text); }
  .scope-header .scope-label { font-size: 12.5px; text-transform: uppercase; letter-spacing: .06em; color: var(--subtext); font-weight: 600; }
  .scope-header .scope-name { color: var(--mauve); font-weight: 600; }
  .scope-header .scope-count { color: var(--subtext); font-size: 13.5px; }
  .scope-header .scope-clear { margin-left: auto; cursor: pointer; font-size: 13.5px; color: var(--blue); border: 1px solid var(--overlay); border-radius: 7px; padding: 2px 10px; }
  .scope-header .scope-clear:hover { border-color: var(--blue); }
  .scope-empty { margin: 4px 4px 0 4px; padding: 14px 16px; border: 1px dashed var(--overlay); border-radius: 10px; color: var(--subtext); font-size: 15px; }

  .card { width: 100%; background: var(--surface); border: 1px solid var(--overlay); border-radius: 12px; padding: 18px 18px 16px; display: flex; flex-direction: column; gap: 12px; position: relative; transition: transform .15s ease; cursor: pointer; }
  /* R21: stale renders FULL CONTRAST + red, never desaturated — the
     mockup's own `.card.stale { filter: saturate(.55); }` rule is a
     captured mistake (its own header comment says so), dropped here; a
     tinted border is the only stale-specific treatment. */
  .card.stale { border-color: rgba(243,139,168,.5); }
  .card.selected { border: 1.5px solid var(--mauve); box-shadow: 0 8px 28px -8px rgba(203,166,247,.35), 0 0 0 1px rgba(203,166,247,.08); transform: translateY(-6px); background: linear-gradient(180deg, rgba(203,166,247,.06), var(--surface) 40%); }
  .card.selected .ring-stroke { stroke: var(--mauve) !important; }
  .card-top { display: flex; align-items: flex-start; justify-content: space-between; gap: 10px; }
  .card-title { font-size: 17px; font-weight: 600; color: var(--text); line-height: 1.4; }
  .card-id { display: inline-block; color: var(--subtext); margin-top: 4px; font-size: 13px; }
  .ring-wrap { flex: 0 0 auto; display: flex; flex-direction: column; align-items: center; gap: 2px; }
  .ring-label { font-size: 11.5px; color: var(--subtext); }
  .quote { font-size: 14.5px; color: var(--subtext); font-style: italic; border-left: 2px solid var(--overlay); padding-left: 10px; display: -webkit-box; -webkit-line-clamp: 2; -webkit-box-orient: vertical; overflow: hidden; }
  .quote.placeholder { opacity: .6; }
  .next-line { font-size: 15px; color: var(--text); display: -webkit-box; -webkit-line-clamp: 2; -webkit-box-orient: vertical; overflow: hidden; }
  .next-line b { color: var(--mauve); font-weight: 600; }
  .card-foot { margin-top: auto; display: flex; align-items: center; justify-content: flex-end; gap: 6px; font-size: 13.5px; color: var(--subtext); }

  .drilldown { display: none; background: var(--surface); border: 1px solid var(--mauve); border-radius: 12px; padding: 22px 26px; margin-top: 2px; grid-template-columns: 1.3fr 1fr 1fr; gap: 28px; }
  .drilldown.active { display: grid; }
  .drilldown h3 { margin: 0 0 12px; font-size: 12.5px; text-transform: uppercase; letter-spacing: .07em; color: var(--mauve); font-weight: 700; }
  .drilldown ul { list-style: none; margin: 0; padding: 0; display: flex; flex-direction: column; gap: 9px; }
  .drilldown li { font-size: 15px; display: flex; gap: 8px; align-items: flex-start; line-height: 1.5; }
  .chk { flex: 0 0 auto; margin-top: 2px; font-size: 14.5px; }
  .chk.done { color: var(--green); }
  .chk.todo { color: var(--subtext); }
  li.done-item { color: var(--subtext); text-decoration: line-through; text-decoration-color: var(--overlay); }
  .dd-meta { color: var(--subtext); font-size: 13.5px; margin-top: 14px; }
  .followup { color: var(--yellow); }

  /* ---------- U7: lifecycle stage strip ---------- */
  /* Progress is BLUE. Mauve stays reserved for selection/current/TODAY
     (R24), so a "this stage is running" glyph must not use it. */
  .stage-strip { display: flex; align-items: center; flex-wrap: wrap; gap: 4px 12px; margin: 2px 0 2px; font-size: 12px; }
  .stage { display: inline-flex; align-items: center; gap: 5px; color: var(--subtext); white-space: nowrap; }
  .stage-g { font-size: 11px; line-height: 1; }
  .stage-l { letter-spacing: .02em; }
  .stage.done { color: var(--green); }
  .stage.progress { color: var(--blue); }
  .stage.pending { color: var(--subtext); opacity: .55; }
  .stage-strip.mini { gap: 0 5px; margin: 3px 0 0; }
  .stage-strip.mini .stage-g { font-size: 10px; }
  .pr-chip { font-size: 11px; font-weight: 600; padding: 1px 7px; border-radius: 999px; border: 1px solid rgba(137,180,250,.4); background: rgba(137,180,250,.1); color: var(--blue); text-decoration: none; white-space: nowrap; }
  .pr-chip:hover { border-color: var(--blue); }

  /* ---------- U8: the shared summary-first detail block ---------- */
  #detail-pool { display: none; }
  .detail-host { display: none; }
  .detail-host.open { display: block; margin-top: 10px; }

  .detail { background: var(--surface); border: 1px solid var(--mauve); border-radius: 12px; padding: 18px 22px 16px; display: flex; flex-direction: column; gap: 10px; text-align: left; }
  .detail-head { display: flex; align-items: baseline; flex-wrap: wrap; gap: 6px 12px; }
  .detail-title { font-size: 18px; font-weight: 650; color: var(--text); flex: 1 1 320px; min-width: 0; line-height: 1.35; }
  .detail-pill { flex: 0 0 auto; font-size: 11.5px; font-weight: 600; padding: 2px 9px; border-radius: 999px; background: var(--overlay); color: var(--subtext); text-transform: lowercase; }
  .detail-pill.st-doing, .detail-pill.st-review { background: rgba(166,227,161,.16); color: var(--green); }
  .detail-pill.st-planned { background: rgba(137,180,250,.16); color: var(--blue); }
  .detail-pill.st-paused, .detail-pill.st-prospective { background: rgba(250,179,135,.16); color: var(--peach); }
  .detail-age { font-size: 12.5px; color: var(--subtext); flex: 0 0 auto; }
  .detail-parent { font-size: 12.5px; color: var(--blue); cursor: pointer; flex: 0 0 auto; max-width: 340px; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
  .detail-parent:hover { text-decoration: underline; }
  .detail-id { font-size: 12px; color: var(--subtext); flex: 0 0 auto; }

  /* The answer line: what happens next, in full, before anything else. */
  .detail-now { display: flex; gap: 10px; align-items: baseline; background: var(--base); border-left: 2px solid var(--mauve); border-radius: 0 8px 8px 0; padding: 9px 14px; }
  .detail-now .lbl { flex: 0 0 auto; font-size: 11px; font-weight: 700; letter-spacing: .08em; text-transform: uppercase; color: var(--mauve); }
  .detail-now .txt { font-size: 15px; color: var(--text); line-height: 1.5; }
  .detail-now .placeholder { color: var(--subtext); font-style: italic; }

  .dsec { border-top: 1px solid var(--overlay); padding-top: 8px; }
  .dsec > summary { list-style: none; cursor: pointer; user-select: none; display: flex; align-items: center; gap: 8px; font-size: 12.5px; font-weight: 600; text-transform: uppercase; letter-spacing: .06em; color: var(--subtext); padding: 2px 0; }
  .dsec > summary::-webkit-details-marker { display: none; }
  .dsec > summary::before { content: "\25B8"; font-size: 10px; transition: transform .12s ease; display: inline-block; }
  .dsec[open] > summary::before { transform: rotate(90deg); }
  .dsec > summary:hover { color: var(--text); }
  .dsec > summary .n { font-weight: 400; color: var(--subtext); opacity: .85; text-transform: none; letter-spacing: 0; }
  .dsec-body { padding: 8px 0 6px 18px; font-size: 14.5px; }
  .dsec-body ul { list-style: none; margin: 0; padding: 0; display: flex; flex-direction: column; gap: 7px; }
  .dsec-body li { display: flex; gap: 8px; align-items: flex-start; line-height: 1.5; }
  .dsec-body .placeholder, .dsec-body.placeholder { color: var(--subtext); font-style: italic; }
  .dsec-pre { margin: 6px 0 4px 18px; padding: 10px 13px; background: var(--base); border: 1px solid var(--overlay); border-radius: 8px; font-family: "SFMono-Regular", Consolas, "Liberation Mono", Menlo, monospace; font-size: 12.5px; line-height: 1.55; color: var(--text); white-space: pre-wrap; word-break: break-word; max-height: 460px; overflow: auto; }
  .art-ul li { align-items: baseline; }

  /* Family tree rows become expandable in place. */
  .fam-tree-row.expandable { cursor: pointer; grid-template-columns: 12px 20px 1fr auto auto; }
  .fam-caret { font-size: 10px; color: var(--subtext); transition: transform .12s ease; }
  .fam-tree-row.expanded .fam-caret { transform: rotate(90deg); color: var(--mauve); }
  .fam-tree-row.expanded { background: rgba(203,166,247,.07); border-color: rgba(203,166,247,.3); }
  .fam-tree-row.child-row + .detail-host.open { margin-left: 26px; }

  .copyable { cursor: pointer; }
  .copyable:hover { text-decoration: underline; text-decoration-color: var(--mauve); }
  .copyable.copied { color: var(--green) !important; }

  /* ---------- VIEW 2: Roadmap ---------- */
  .rm-board { position: relative; }
  .rm-grid-header { display: grid; grid-template-columns: 260px repeat(5, 1fr); column-gap: 0; margin-bottom: 4px; }
  .rm-grid-header .col-label { text-align: center; font-size: 12px; letter-spacing: .05em; text-transform: uppercase; color: var(--subtext); padding-bottom: 10px; border-bottom: 1px solid var(--overlay); }
  .rm-grid-header .col-label.this-week { color: var(--mauve); font-weight: 700; }
  .rm-grid-header .col-label:first-child { border-bottom: none; }

  .rm-lanes { position: relative; padding-top: 6px; }
  .rm-grid-lines { position: absolute; top: 0; bottom: 0; left: 0; right: 0; pointer-events: none; z-index: 0; }
  .rm-grid-lines .vline { position: absolute; top: 0; bottom: 0; width: 1px; background: var(--overlay); opacity: .32; }
  .rm-thisweek-band { position: absolute; top: 0; bottom: 0; z-index: 0; background: rgba(203,166,247,.05); border-left: 1px solid rgba(203,166,247,.18); border-right: 1px solid rgba(203,166,247,.18); }
  .rm-today-line { position: absolute; top: -26px; bottom: 0; width: 2px; background: var(--mauve); z-index: 4; pointer-events: none; box-shadow: 0 0 0 3px rgba(203,166,247,.12); }
  .rm-today-tag { position: absolute; top: -26px; transform: translateX(-50%); font-size: 11px; font-weight: 700; letter-spacing: .09em; text-transform: uppercase; color: var(--mauve); background: var(--base); padding: 1px 6px; border-radius: 4px; white-space: nowrap; }

  .rm-lane { display: grid; grid-template-columns: 260px repeat(5, 1fr); grid-template-rows: 9px auto; column-gap: 0; row-gap: 4px; align-items: center; padding: 13px 0; border-bottom: 1px solid rgba(69,71,90,.4); position: relative; z-index: 1; }
  .rm-lane:last-child { border-bottom: none; }
  .rm-lane-label { grid-column: 1 / 2; grid-row: 1 / 3; font-size: 14.5px; color: var(--text); padding-right: 16px; overflow: hidden; }
  .rm-lane-label .id { display: block; font-size: 11.5px; color: var(--subtext); margin-top: 3px; white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
  .rm-lane-label .rm-title-row { white-space: nowrap; overflow: hidden; text-overflow: ellipsis; display: flex; align-items: baseline; gap: 10px; }
  .rm-lane-label .rm-title-row .rm-mfrac { font-size: 15px; color: var(--subtext); flex: 0 0 auto; }
  /* The lane title needs its own span for the same reason .rm-bar-t does:
     as a bare text node it is an anonymous flex item, so the ellipsis
     landed on the ROW and ate the "3 / 13" milestone fraction instead. */
  .rm-lane-label .rm-title-row .rm-lane-t { flex: 0 1 auto; min-width: 0; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
  .rm-lane-label .rm-standalone-meta { display: flex; align-items: center; gap: 6px; margin-top: 4px; font-size: 12.5px; color: var(--subtext); }

  /* UX pass (scope): a scoped roadmap shows ONLY that family's lane. This
     started as a dim (.scope-dim, kept below for anything that still wants
     it) on the theory that a roadmap of one lane is useless; live use said
     otherwise — among 18 lanes, hunting for the un-faded one is still
     hunting. Clearing the scope brings every lane straight back. */
  .rm-lane.scope-dim { opacity: .34; filter: saturate(.55); }
  .rm-lane.selected { outline: 1.5px solid var(--mauve); outline-offset: 4px; border-radius: 10px; background: rgba(203,166,247,.055); }
  .rm-lane.selected .rm-lane-label { border-left: 3px solid var(--mauve); padding-left: 12px; margin-left: -15px; }
  .rm-lane.selected .rm-lane-label .rm-title-row .rm-lane-t { color: var(--mauve); font-weight: 600; }
  .rm-lane.milestone-lane { position: relative; z-index: 1; }
  .rm-lane.milestone-lane::before { content: ""; position: absolute; inset: -6px -14px; background: rgba(203,166,247,.05); border: 1px solid rgba(203,166,247,.12); border-radius: 12px; z-index: -1; }

  .rm-bracket { grid-row: 1; align-self: end; height: 7px; margin: 0 6px; position: relative; border-top: 1px solid var(--overlay); }
  .rm-bracket::before, .rm-bracket::after { content: ""; position: absolute; top: 0; width: 1px; height: 7px; background: var(--overlay); }
  .rm-bracket::before { left: 0; }
  .rm-bracket::after { right: 0; }

  /* UX pass: bars WRAP rather than share one row down to a 2-char stub —
     a readable label beats a perfectly single-row lane. Each also carries
     a title= tooltip with its full text for whatever the ellipsis eats. */
  .rm-bars { grid-row: 2; display: flex; flex-wrap: wrap; gap: 6px 8px; align-items: center; min-width: 0; position: relative; }
  .rm-bar { height: 28px; border-radius: 8px; display: flex; align-items: center; gap: 8px; padding: 0 12px; font-size: 12.5px; white-space: nowrap; overflow: hidden; min-width: 150px; position: relative; flex: 1 1 150px; }
  .rm-bar-t { flex: 1 1 auto; min-width: 0; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
  .rm-bar-age { flex: 0 0 auto; opacity: .75; font-size: 11.5px; }
  .rm-bar.selected { outline: 2px solid var(--mauve); outline-offset: 2px; }
  .rm-bar.active-bar { background: var(--green); color: var(--base); font-weight: 600; }
  .rm-bar.ready-bar { background: transparent; border: 2px solid var(--blue); color: var(--blue); padding-right: 46px; }
  .rm-bar.ready-bar::after { content: "ready"; position: absolute; right: 10px; top: 50%; transform: translateY(-50%); font-family: "SFMono-Regular", Consolas, "Liberation Mono", Menlo, monospace; font-size: 11px; color: var(--blue); opacity: .85; letter-spacing: .02em; }
  /* Two lines at most (title, then its "after:" tag) — with the narrower
     wrapped columns the UX pass introduced, the old `white-space: normal`
     turned a blocked bar into a 10-line paragraph and a lane into a
     500px block. */
  .rm-bar.blocked-bar { background: rgba(69,71,90,.55); border: 1px solid var(--overlay); color: var(--subtext); flex-wrap: wrap; height: auto; min-height: 28px; padding: 5px 12px; row-gap: 1px; }
  .rm-bar .lock-ic { margin-right: 5px; font-size: 11px; }
  .rm-after-tag { flex-basis: 100%; margin-left: 19px; font-size: 11.5px; color: var(--red); white-space: nowrap; overflow: hidden; text-overflow: ellipsis; min-width: 0; opacity: 1; }

  .rm-readiness-strip { margin: 2px 0 14px 0; padding: 8px 16px; background: rgba(137,180,250,.04); border: 1px solid var(--overlay); border-radius: 10px; }
  .rm-strip-head { display: flex; align-items: center; gap: 9px; cursor: pointer; user-select: none; font-size: 13px; }
  .rm-strip-caret { font-size: 11.5px; color: var(--subtext); width: 10px; text-align: center; transition: transform .12s ease; }
  .rm-readiness-strip.open .rm-strip-caret { transform: rotate(90deg); }
  .rm-strip-n { font-size: 14px; font-weight: 700; }
  .rm-strip-n.ready { color: var(--blue); }
  .rm-strip-n.blocked { color: var(--subtext); }
  .rm-strip-head .rm-readiness-label { margin-right: 0; }
  .rm-strip-body { display: none; flex-wrap: wrap; gap: 10px 32px; align-items: center; padding-top: 12px; }
  .rm-readiness-strip.open .rm-strip-body { display: flex; }
  .rm-readiness-group { display: flex; align-items: center; gap: 10px; flex-wrap: wrap; }
  .rm-readiness-label { font-size: 12.5px; text-transform: uppercase; letter-spacing: .06em; color: var(--subtext); font-weight: 600; margin-right: 2px; white-space: nowrap; }
  .rm-ready-pill { font-size: 14px; padding: 5px 12px; border-radius: 999px; border: 1.5px solid var(--blue); color: var(--blue); background: rgba(137,180,250,.08); white-space: nowrap; }
  .rm-blocked-pill { font-size: 14px; padding: 5px 12px; border-radius: 999px; border: 1px solid var(--overlay); color: var(--subtext); background: rgba(69,71,90,.4); white-space: nowrap; display: inline-flex; align-items: center; gap: 7px; }
  .rm-blocked-pill .lock-ic { font-size: 11px; }
  .rm-blocked-pill .after-inline { color: var(--red); font-size: 12px; margin-left: 2px; }

  .rm-stale-row { display: grid; grid-template-columns: 260px repeat(5, 1fr); column-gap: 0; align-items: center; padding: 9px 0; }
  .rm-stale-row .rm-lane-label { grid-row: auto; font-size: 14.5px; color: var(--text); display: flex; align-items: center; gap: 8px; }
  .rm-stale-row .rm-lane-label .age-red { color: var(--red); font-size: 12.5px; margin-left: auto; padding-right: 16px; }

  .stale-toggle { margin-top: 10px; padding: 11px 14px; color: var(--red); font-size: 14.5px; background: rgba(243,139,168,.06); border: 1px dashed rgba(243,139,168,.35); border-radius: 10px; cursor: pointer; display: flex; align-items: center; gap: 8px; user-select: none; }
  .stale-toggle:hover { background: rgba(243,139,168,.1); }
  .stale-toggle .caret { font-size: 11.5px; transition: transform .12s ease; }
  .stale-toggle.open .caret { transform: rotate(90deg); }
  .stale-detail { display: none; margin-top: 4px; }
  .stale-detail.open { display: block; }

  /* ---------- VIEW 3: Week ---------- */
  header.week-header { margin-bottom: 28px; display: flex; align-items: baseline; justify-content: space-between; flex-wrap: wrap; gap: 10px; }
  header.week-header h1 { margin: 0; font-size: 28px; font-weight: 650; letter-spacing: -0.01em; color: var(--text); }
  header.week-header .summary { color: var(--subtext); font-size: 15.5px; white-space: nowrap; }
  header.week-header .summary b.n-active { color: var(--green); font-weight: 600; }
  header.week-header .summary b.n-stale { color: var(--red); font-weight: 600; }
  header.week-header .summary b.n-shelved { color: var(--peach); font-weight: 600; }

  section.region { margin-bottom: 36px; }

  .week-card { background: var(--surface); border: 1px solid var(--mauve); border-radius: 12px; padding: 22px 26px 24px; box-shadow: 0 0 0 1px rgba(203,166,247,0.08), 0 8px 28px -14px rgba(203,166,247,0.35); }
  .week-card .top-row { display: flex; align-items: center; gap: 12px; margin-bottom: 4px; }
  .week-card .title { font-size: 21px; font-weight: 600; color: var(--text); }
  .week-badge { font-size: 12.5px; font-weight: 600; padding: 2px 9px; border-radius: 999px; background: var(--overlay); color: var(--subtext); text-transform: lowercase; }
  .week-card .meta { color: var(--subtext); font-size: 14.5px; margin: 4px 0 18px 21px; }
  .week-card .meta .parent-chip { color: var(--blue); opacity: 0.9; }
  /* UX pass: collapsed by default (23 always-open drilldowns made this
     view 8579px tall); the caret + pointer cursor say it opens. */
  .week-card { cursor: pointer; margin-bottom: 10px; }
  .week-card .wk-caret { margin-left: auto; font-size: 11.5px; color: var(--subtext); transition: transform .12s ease; }
  .week-card.expanded .wk-caret { transform: rotate(90deg); color: var(--mauve); }
  .week-card .meta { margin-bottom: 0; }
  .week-card.expanded .meta { margin-bottom: 18px; }
  .wdrill { display: none; grid-template-columns: 1.15fr 1fr; gap: 20px 32px; }
  .week-card.expanded .wdrill { display: grid; }

  header.week-header .summary b.n-shelved { cursor: pointer; user-select: none; }
  header.week-header .summary b.n-shelved .caret { display: inline-block; font-size: 11px; transition: transform .12s ease; }
  header.week-header .summary b.n-shelved.open .caret { transform: rotate(90deg); }
  .wk-shelf-detail { display: none; margin: -14px 0 28px 0; padding: 14px 16px; border: 1px solid var(--overlay); border-radius: 10px; background: rgba(250,179,135,.04); max-height: 420px; overflow-y: auto; }
  .wk-shelf-detail.open { display: block; }
  .wk-shelf-detail .region-label { margin: 0 0 8px 0; }
  .wk-shelf-list { display: flex; flex-direction: column; gap: 1px; }
  .wk-shelf-row { display: flex; align-items: center; gap: 10px; padding: 5px 8px; border-radius: 6px; font-size: 14px; color: var(--text); }
  .wk-shelf-row:hover { background: var(--surface); }
  .wk-shelf-row .t { flex: 1; min-width: 0; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
  .wk-shelf-row .id { flex: 0 0 auto; font-size: 12px; color: var(--subtext); }
  .wk-shelf-row .st { flex: 0 0 auto; font-size: 11.5px; color: var(--subtext); border: 1px solid var(--overlay); border-radius: 999px; padding: 0 8px; }
  .wdrill h4 { margin: 0 0 9px; font-size: 13.5px; font-weight: 600; text-transform: uppercase; letter-spacing: .06em; color: var(--subtext); }
  .wdrill ul { margin: 0; padding: 0; list-style: none; }
  .wdrill li { position: relative; padding-left: 22px; margin-bottom: 8px; color: var(--text); font-size: 15.5px; }
  .wdrill li::before { content: ""; position: absolute; left: 0; top: 6px; width: 8px; height: 8px; border-radius: 3px; border: 1.5px solid var(--overlay); }
  .wdrill li.done-item::before { background: var(--green); border-color: var(--green); }
  .wdrill .handoff { font-size: 14.5px; color: var(--subtext); background: var(--base); border: 1px solid var(--overlay); border-radius: 8px; padding: 10px 13px; margin-bottom: 8px; }
  .wdrill-block { margin-bottom: 16px; }
  .wdrill-block:last-child { margin-bottom: 0; }

  .carried-list { display: flex; flex-direction: column; gap: 2px; }
  .carried-row { display: grid; grid-template-columns: 14px 1fr auto; align-items: center; gap: 12px; padding: 9px 14px; border-radius: 8px; }
  .carried-row:hover { background: var(--surface); }
  .carried-row .row-title { font-size: 15.5px; color: var(--text); }
  .carried-row .row-title .id { color: var(--subtext); font-size: 13.5px; margin-right: 8px; }
  .carried-row .age { color: var(--subtext); font-size: 14px; white-space: nowrap; }

  .family-block { margin: 4px 0 8px 0; }
  .family-block .fam-row { display: grid; grid-template-columns: 14px 1fr auto; align-items: center; gap: 12px; padding: 9px 14px; border-radius: 8px; }
  .family-block .fam-row .row-title { font-size: 15.5px; color: var(--text); text-align: left; }
  .family-block, .carried-list, .carried-row, .family-block .fam-row, .fam-kid-row { text-align: left; }
  .carried-row .row-title, .carried-row .age { text-align: left; }
  .family-block .fam-row .row-title .id { color: var(--subtext); font-size: 13.5px; margin-right: 8px; }
  .family-block .fam-row .age { color: var(--red); font-size: 14px; }
  .family-block .fam-kids { margin: 2px 0 6px 30px; border-left: 1px solid var(--overlay); padding-left: 16px; display: flex; flex-direction: column; gap: 2px; }
  /* Left-aligned, always. `justify-content: space-between` pushed the title
     into the middle of the row (the open-glyph sat at the far left and the
     pill/age at the far right), so a column of child tasks read as ragged
     centred text instead of a list. Titles start at the left edge; only the
     pill and age are pushed right, by an auto margin. */
  .fam-kid-row { display: flex; align-items: center; justify-content: flex-start; gap: 10px; padding: 6px 8px; border-radius: 6px; text-align: left; }
  .fam-kid-row .title { flex: 1 1 auto; min-width: 0; text-align: left; }
  .fam-kid-row .right { margin-left: auto; flex: 0 0 auto; }
  .fam-kid-row:hover { background: var(--surface); }
  .fam-kid-row .title { font-size: 15px; color: var(--text); }
  .fam-kid-row .right { display: flex; align-items: center; gap: 8px; }
  .fam-kid-row .age { color: var(--subtext); font-size: 13.5px; }
  .pill { font-size: 12px; font-weight: 600; padding: 2px 8px; border-radius: 999px; letter-spacing: .02em; }
  .pill.planned { background: rgba(137,180,250,.16); color: var(--blue); }
  .pill.doing { background: rgba(166,227,161,.14); color: var(--green); }

  .week-stale-toggle { margin-top: 16px; padding: 11px 14px; color: var(--red); font-size: 14.5px; background: rgba(243,139,168,.06); border: 1px dashed rgba(243,139,168,.35); border-radius: 10px; cursor: pointer; display: flex; align-items: center; gap: 8px; user-select: none; }
  .week-stale-toggle:hover { background: rgba(243,139,168,.1); }
  .week-stale-toggle .caret { font-size: 11.5px; transition: transform .12s ease; }
  .week-stale-toggle.open .caret { transform: rotate(90deg); }
  .week-stale-detail { display: none; margin-top: 8px; }
  .week-stale-detail.open { display: block; }

  .qs-subrow { margin-bottom: 18px; }
  .qs-subrow:last-child { margin-bottom: 0; }
  .qs-subrow .qs-label { font-size: 13px; text-transform: uppercase; letter-spacing: .06em; color: var(--subtext); font-weight: 600; margin-bottom: 10px; }
  .qs-chip-row { display: flex; flex-wrap: wrap; align-items: center; gap: 10px; }
  .qs-chip { display: inline-flex; align-items: baseline; gap: 7px; padding: 7px 13px; border-radius: 999px; font-size: 14.5px; border: 1px solid transparent; white-space: nowrap; }
  .qs-chip.planned { background: rgba(137,180,250,.10); border-color: rgba(137,180,250,.35); color: var(--blue); }
  .qs-chip.planned .breadcrumb { color: var(--subtext); font-size: 12.5px; }
  .qs-chip.shelf { background: rgba(250,179,135,.10); border-color: rgba(250,179,135,.35); color: var(--peach); }

  /* ---------- VIEW 4: Family (U6, mockups D + A) ---------- */
  /* Family selection lives in the rail (#rail-families, a peer of
     #rail-tasks — see showView()'s own note) as .fam-rail-row, reusing
     .rail-row/.dot/.rail-row-title/.rail-row-age wholesale; only the
     selected-state accent below is Family-specific (mirrors the mauve
     "selection" language .card.selected already uses on the Active deck,
     translated from a card to a rail row). */
  .fam-rail-row.selected { background: rgba(203,166,247,.12); border-color: var(--mauve); }
  .fam-rail-row.selected .rail-row-title { color: var(--mauve); }
  .fam-rail-row.selected .rail-row-age { color: var(--mauve); opacity: .85; }
  .fam-block { display: none; }
  /* The family's own top-level summary: same component as an expanded task,
     so a family reads the way a task does. */
  .fam-summary { margin: 0 2px 22px 2px; }

  .fam-title-row { display: flex; align-items: baseline; justify-content: space-between; gap: 16px; margin: 2px 2px 20px 2px; flex-wrap: wrap; }
  .fam-title-row h1 { margin: 0; font-size: 25px; font-weight: 650; letter-spacing: -0.01em; color: var(--text); }
  .fam-id, .fam-hero-id { color: var(--subtext); font-size: 13.5px; }

  .fam-hero { background: var(--surface); border: 1px solid var(--overlay); border-radius: 14px; padding: 24px 28px; margin-bottom: 26px; }
  .fam-hero-top { display: flex; align-items: flex-start; justify-content: space-between; gap: 16px; margin-bottom: 18px; }
  .fam-hero-title { font-size: 21px; font-weight: 650; color: var(--text); }
  .fam-hero-id { display: inline-block; margin-top: 5px; }
  .fam-hero-meta { display: flex; align-items: center; gap: 10px; flex: 0 0 auto; }
  .fam-hero-meta .age { font-size: 13.5px; color: var(--subtext); }

  .fam-tree { display: flex; flex-direction: column; gap: 8px; }
  .fam-tree-row { display: grid; grid-template-columns: 20px 1fr auto auto; align-items: center; gap: 12px; padding: 10px 12px; border-radius: 9px; background: var(--base); border: 1px solid transparent; }
  .fam-tree-row.parent-row { background: rgba(203,166,247,.06); border-color: rgba(203,166,247,.22); }
  .fam-tree-row.child-row { margin-left: 26px; width: calc(100% - 26px); }
  .fam-tree-row .branch { color: var(--overlay); font-size: 14px; text-align: center; }
  .fam-tree-row .t-title { font-size: 15.5px; color: var(--text); }
  .fam-tree-row .t-id { display: block; font-size: 12.5px; color: var(--subtext); margin-top: 2px; }
  .fam-status-pill { font-size: 11.5px; font-weight: 600; padding: 2px 9px; border-radius: 999px; letter-spacing: .02em; white-space: nowrap; }
  .fam-status-pill.doing { background: rgba(166,227,161,.16); color: var(--green); }
  .fam-status-pill.planned { background: rgba(137,180,250,.16); color: var(--blue); }
  .fam-tree-row .t-age { font-size: 13px; color: var(--subtext); white-space: nowrap; text-align: right; min-width: 42px; }

  .fam-section { margin-bottom: 28px; }
  .fam-section-head { display: flex; align-items: baseline; justify-content: space-between; margin-bottom: 14px; }
  .fam-section-head h3 { margin: 0; font-size: 13px; text-transform: uppercase; letter-spacing: .07em; color: var(--subtext); font-weight: 700; }
  .fam-section-sub { font-size: 13px; color: var(--subtext); }

  .fam-timeline { position: relative; padding-left: 22px; }
  .fam-timeline::before { content: ""; position: absolute; left: 5px; top: 6px; bottom: 6px; width: 1px; background: var(--overlay); }
  .fam-tl-item { position: relative; padding-bottom: 20px; }
  .fam-tl-item:last-child { padding-bottom: 0; }
  .fam-tl-item::before { content: ""; position: absolute; left: -22px; top: 4px; width: 9px; height: 9px; border-radius: 50%; background: var(--mauve); box-shadow: 0 0 0 3px var(--base); }
  .fam-tl-item.from-child::before { background: var(--blue); }
  .fam-tl-date { font-size: 13px; color: var(--subtext); margin-bottom: 4px; }
  .fam-tl-text { font-size: 15.5px; color: var(--text); line-height: 1.5; display: -webkit-box; -webkit-line-clamp: 2; -webkit-box-orient: vertical; overflow: hidden; }
  .fam-tl-source { display: inline-flex; align-items: center; gap: 6px; margin-top: 6px; font-size: 12.5px; padding: 2px 9px; border-radius: 999px; border: 1px solid var(--overlay); color: var(--subtext); cursor: pointer; }
  .fam-tl-source.parent-src { border-color: rgba(203,166,247,.35); color: var(--mauve); }
  .fam-tl-source.child-src { border-color: rgba(137,180,250,.35); color: var(--blue); }

  /* j/k rail cursor (UX pass: j/k now walks the rail, not the deck). */
  .rail-cursor { box-shadow: inset 0 0 0 1px var(--blue); }
  .key-legend { color: var(--subtext); }
  .key-legend kbd { font-family: "SFMono-Regular", Consolas, "Liberation Mono", Menlo, monospace; font-size: 11.5px; border: 1px solid var(--overlay); border-radius: 4px; padding: 0 5px; margin: 0 1px; color: var(--text); }

  .fam-art-groups { display: grid; grid-template-columns: 1fr 1fr; gap: 16px; }
  .fam-art-group { background: var(--surface); border: 1px solid var(--overlay); border-radius: 12px; padding: 16px 18px; }
  .fam-art-group h4 { margin: 0 0 10px; font-size: 12px; text-transform: uppercase; letter-spacing: .06em; color: var(--subtext); font-weight: 700; }
  .fam-art-list { display: flex; flex-direction: column; gap: 2px; }
  .fam-art-row { display: flex; align-items: center; gap: 10px; padding: 8px 8px; border-radius: 8px; font-size: 14.5px; color: var(--text); }
  .fam-art-row:hover { background: var(--base); }
  .fam-art-icon { flex: 0 0 auto; font-size: 14px; color: var(--subtext); width: 16px; text-align: center; }
  /* The whole point of the ask is to SEE and use the full path, so it
     wraps rather than ellipsising away the filename. */
  /* The visible text is a basename now, so it needs neither break-all nor
     a wrapping row — the full path lives in title= and on the clipboard. */
  .fam-art-path { flex: 1; min-width: 0; color: var(--text); text-decoration: none; font-size: 13px; line-height: 1.45; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
  .fam-art-path:hover { text-decoration: underline; text-decoration-color: var(--mauve); }
  .fam-art-row { align-items: center; }
  .fam-art-tag { flex: 0 0 auto; font-size: 12px; color: var(--subtext); }
  .fam-art-grab { flex: 0 0 auto; font-size: 12px; color: var(--mauve); border: 1px solid rgba(203,166,247,.35); background: rgba(203,166,247,.08); border-radius: 6px; padding: 2px 8px; opacity: 0; transition: opacity .12s ease; }
  .fam-art-row:hover .fam-art-grab { opacity: 1; }

  /* ---------- Ladder (mockup D) ---------- */
  .ladder { position: relative; margin: 0 2px; padding-left: 26px; }
  .ladder::before { content: ""; position: absolute; left: 9px; top: 6px; bottom: 6px; width: 2px; background: var(--overlay); }
  .rung { position: relative; margin-bottom: 4px; border-radius: 12px; }
  .rung-node { position: absolute; left: -26px; top: 20px; width: 20px; height: 20px; border-radius: 50%; background: var(--base); border: 2px solid var(--overlay); display: flex; align-items: center; justify-content: center; z-index: 2; }
  .rung-node.done { border-color: var(--green); background: var(--green); }
  .rung-node.done::after { content: "\2713"; color: var(--base); font-size: 11px; font-weight: 700; }
  .rung-node.active { border-color: var(--mauve); background: var(--base); box-shadow: 0 0 0 4px rgba(203,166,247,.18); }
  .rung-node.active::after { content: ""; width: 8px; height: 8px; border-radius: 50%; background: var(--mauve); }
  .rung-node.planned { border-color: var(--blue); }
  .rung-node.unfiled { border-color: var(--overlay); }
  .rung-head { display: flex; align-items: center; gap: 14px; padding: 14px 18px; border-radius: 12px; border: 1px solid var(--overlay); background: var(--surface); cursor: pointer; user-select: none; }
  .rung.active .rung-head { border-color: var(--mauve); background: linear-gradient(180deg, rgba(203,166,247,.07), var(--surface) 55%); box-shadow: 0 8px 24px -12px rgba(203,166,247,.4); }
  .rung.unfiled .rung-head { opacity: 0.68; }
  .rung.unfiled .rung-head:hover { opacity: 0.9; }
  .rung-ver { font-size: 15px; font-weight: 700; color: var(--text); flex: 0 0 auto; max-width: 130px; white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
  .rung.active .rung-ver { color: var(--mauve); }
  .rung-goal { flex: 1; min-width: 0; font-size: 15.5px; color: var(--text); overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
  .rung.unfiled .rung-goal { color: var(--subtext); font-style: italic; }
  .rung-status-pill { flex: 0 0 auto; font-size: 11.5px; font-weight: 700; text-transform: uppercase; letter-spacing: .04em; padding: 3px 10px; border-radius: 999px; }
  .rung-status-pill.done { background: rgba(166,227,161,.16); color: var(--green); }
  .rung-status-pill.active { background: rgba(203,166,247,.18); color: var(--mauve); }
  .rung-status-pill.planned { background: rgba(137,180,250,.16); color: var(--blue); }
  .rung-status-pill.unfiled { background: rgba(69,71,90,.6); color: var(--subtext); }
  .rung-child { flex: 0 0 auto; font-size: 13px; color: var(--subtext); cursor: pointer; }
  .rung-child .id { color: var(--subtext); }
  .rung-child.none { font-style: italic; cursor: default; }
  .rung-caret { flex: 0 0 auto; font-size: 11.5px; color: var(--subtext); transition: transform .12s ease; width: 10px; text-align: center; }
  .rung.expanded .rung-caret { transform: rotate(90deg); }
  .rung-body { display: none; padding: 4px 18px 18px 60px; }
  .rung.expanded .rung-body { display: block; }
  .rung-grid { display: grid; grid-template-columns: 1.2fr 1fr; gap: 10px 32px; margin-top: 6px; }
  .rung-grid h4 { margin: 0 0 8px; font-size: 12px; font-weight: 600; text-transform: uppercase; letter-spacing: .06em; color: var(--subtext); }
  .rung-grid ul { list-style: none; margin: 0; padding: 0; display: flex; flex-direction: column; gap: 8px; }
  .rung-grid li { font-size: 14.5px; color: var(--text); line-height: 1.5; }
  .rung-grid li.empty { color: var(--subtext); font-style: italic; font-size: 14px; }
  .decision-item { padding-left: 16px; position: relative; }
  .decision-item::before { content: "\2014"; position: absolute; left: 0; color: var(--mauve); }
  .artifact-link { display: inline-block; max-width: 100%; font-size: 13px; color: var(--text); text-decoration: none; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; vertical-align: bottom; }
  .artifact-link:hover { text-decoration: underline; text-decoration-color: var(--mauve); }
  .rung-grid li .copy-ic { opacity: .5; }
  .rung-grid li:hover .copy-ic { opacity: 1; }
  .fam-today-tag { display: inline-flex; align-items: center; gap: 6px; font-size: 11px; font-weight: 700; letter-spacing: .09em; text-transform: uppercase; color: var(--mauve); background: rgba(203,166,247,.12); border: 1px solid rgba(203,166,247,.4); padding: 2px 9px; border-radius: 999px; margin-left: 8px; }

  /* ---------- Family DAG (U4) — Dependencies region, inline SVG ----------
     Colour choices (KTD9/KTD10, documented here so a future pass doesn't
     re-litigate them):
       - status ladder REUSES .rung-node's own mapping: done=--green,
         doing/review (active)=--mauve, planned=--blue, anything else
         (prospective/unknown)=--subtext (grey) — set per node via the
         `--st` custom property, same pattern mockup-3-graph.html uses.
       - critical path (spine edges + node halo) = --peach — free of every
         status colour above.
       - startable-now static outline = --yellow — likewise free of the
         status ladder AND distinct from --peach, so "critical" and
         "startable" never read as the same signal.
       - under-defined (KTD6) dashed border = --overlay, a NEUTRAL grey —
         deliberately NOT --red, so a merely-fuzzy node never reads as a
         warning (KTD9).
       - cycle back-edges = --red, dashed, ON PURPOSE — these ARE warnings
         (KTD9), the one dashed usage in this block that means "danger". */
  .fam-dag-wrap { margin-bottom: 28px; overflow-x: auto; overflow-y: hidden; border: 1px solid var(--overlay); border-radius: 12px; background: var(--surface); padding: 10px 6px; }
  .fam-dag-head { font-size: 14px; color: var(--text); margin: 2px 4px 14px 4px; }
  .fam-dag-head .dag-arw { color: var(--subtext); padding: 0 3px; }
  .fam-dag-head .dag-path-hop { font-family: "SFMono-Regular", Consolas, "Liberation Mono", Menlo, monospace; font-size: 13px; font-weight: 700; color: var(--peach); }
  svg.fam-dag { display: block; }
  .dag-frontier { stroke: var(--blue); stroke-width: 1.6; stroke-dasharray: 2 7; stroke-linecap: round; opacity: .8; }
  .dag-frontier-lbl { font-family: monospace; font-size: 10px; font-weight: 700; letter-spacing: .1em; fill: var(--blue); }
  .dag-edge { fill: none; stroke: var(--overlay); stroke-width: 2; opacity: .85; }
  .dag-edge-crit { stroke: var(--peach); stroke-width: 3; opacity: .95; }
  .dag-edge-warn { stroke: var(--red); stroke-width: 2; stroke-dasharray: 5 4; opacity: .9; }
  .dag-node { cursor: pointer; }
  .dag-card { fill: var(--base); stroke: var(--st); stroke-width: 2; }
  .dag-node.dag-dashed .dag-card { stroke-dasharray: 7 5; stroke: var(--overlay); }
  .dag-node.dag-st-done .dag-card { fill: var(--surface); }
  .dag-node.dag-crit-node .dag-card { stroke: var(--peach); stroke-width: 2.5; }
  .dag-startable-ring { fill: none; stroke: var(--yellow); stroke-width: 1.6; opacity: .9; }
  .dag-pulse-ring { fill: none; stroke: var(--mauve); stroke-width: 2; opacity: .35; }
  @media (prefers-reduced-motion: no-preference) {
    .dag-pulse-ring { animation: dagPulse 2.2s ease-in-out infinite; }
  }
  @keyframes dagPulse { 0%, 100% { opacity: .15; } 50% { opacity: .55; } }
  .dag-id { font-family: monospace; font-size: 11px; fill: var(--subtext); }
  .dag-title { font-family: inherit; font-size: 13px; font-weight: 600; fill: var(--text); }
  .dag-node.dag-st-done .dag-title { fill: var(--subtext); }
  .dag-badge { fill: none; stroke: var(--st); stroke-width: 1.2; opacity: .85; }
  .dag-badge-t { font-family: monospace; font-size: 10.5px; font-weight: 700; fill: var(--st); }
  .dag-dot { fill: var(--st); }
  .dag-status-t { font-family: inherit; font-size: 10.5px; font-weight: 700; fill: var(--st); }
  .dag-tag-rect { fill: none; stroke: var(--peach); stroke-width: 1.2; }
  .dag-tag-t { font-family: monospace; font-size: 9.5px; font-weight: 700; fill: var(--peach); letter-spacing: .08em; }
  .dag-lock { fill: var(--red); }
</style>
</head>
<body>
<div class="caption">wb board &middot; generated @@GENERATED_TS@@ &middot; <span class="key-legend"><kbd>1</kbd>&ndash;<kbd>4</kbd> views &middot; <kbd>j</kbd>/<kbd>k</kbd> rail &middot; <kbd>Enter</kbd> scope &middot; <kbd>a</kbd> all &middot; <kbd>/</kbd> filter</span></div>
<div class="page">

  <div class="rail">
@@RAIL_HTML@@
  </div>

  <div class="main">
    <div class="view-switcher">
      <div class="view-tab active" data-view="active" onclick="showView('active')">Active <span class="tab-badge">@@TAB_BADGE@@</span></div>
      <div class="view-tab" data-view="roadmap" onclick="showView('roadmap')">Roadmap <span class="tab-badge">@@TAB_BADGE@@</span></div>
      <div class="view-tab" data-view="week" onclick="showView('week')">Week <span class="tab-badge">@@TAB_BADGE@@</span></div>
      <div class="view-tab" data-view="family" onclick="showView('family')">Family <span class="tab-badge">@@FAM_TAB_BADGE@@</span></div>
    </div>

    <div class="view active" id="view-active">
      <h2 class="region-label">Active tasks</h2>
      <div class="scope-header" id="active-scope-header" style="display:none;"></div>
      <div class="deck-row" id="deckRow">
@@DECK_HTML@@
      </div>
      <div class="scope-empty" id="active-scope-empty" style="display:none;"></div>
    </div>

    <div class="view" id="view-roadmap">
@@ROADMAP_HTML@@
    </div>

    <div class="view" id="view-week">
@@WEEK_HTML@@
    </div>

    <div class="view" id="view-family">
@@FAMILY_HTML@@
    </div>

    <div class="gen-ts">Generated @@GENERATED_TS@@ by <span class="mono">wb board --html</span></div>
  </div>
  <div id="detail-pool" hidden>
@@DETAIL_POOL_HTML@@
  </div>
</div>

<script>
  // =====================================================================
  // SCOPE — one global narrowing, driven by the rail, shared by every
  // view. `family` is a family ROOT's anchor (the subtree the board is
  // narrowed to), `task` a single task's anchor inside it. Both empty =
  // no scope = the whole board, which is the default and what the rail's
  // "All doing" row (and the `a` key) restores. Persisted, with the
  // current view, in localStorage so a re-render lands where you left it.
  // =====================================================================
  var SCOPE = {family: '', task: ''};
  var CURRENT_VIEW = 'active';
  var LS = {
    get: function(k, d){ try { var v = localStorage.getItem(k); return v === null ? d : v; } catch (e) { return d; } },
    set: function(k, v){ try { localStorage.setItem(k, v); } catch (e) {} }
  };

  function toggleGroup(id) { document.getElementById(id).classList.toggle('expanded'); }

  function showView(name) {
    CURRENT_VIEW = name;
    LS.set('wbBoard.view', name);
    // A tab is a <div>, so clicking one never moves focus off the filter
    // input. Leave it focused and the next `/` is typed INTO the query
    // ("abc/") instead of focusing the filter — the box silently stops
    // matching anything. Blur on every view switch.
    var bf = document.getElementById('board-filter');
    if (bf && document.activeElement === bf) bf.blur();
    document.querySelectorAll('.view').forEach(function(v){ v.classList.remove('active'); });
    var el = document.getElementById('view-' + name);
    if (el) el.classList.add('active');
    document.querySelectorAll('.view-tab').forEach(function(t){
      t.classList.toggle('active', t.getAttribute('data-view') === name);
    });
    // The rail is the nav surface for every view — Family swaps it to the
    // family list, everything else swaps back to the Doing tree.
    var isFamily = name === 'family';
    document.getElementById('rail-tasks').style.display = isFamily ? 'none' : '';
    document.getElementById('rail-families').style.display = isFamily ? '' : 'none';
    // Scope survives a tab switch; re-apply so the newly visible view
    // picks up the narrowing (and scrolls its scoped lane into view).
    applyScope();
  }

  function toggleStale() {
    document.getElementById('rm-stale-toggle').classList.toggle('open');
    document.getElementById('rm-stale-detail').classList.toggle('open');
  }
  function toggleWeekStale() {
    document.getElementById('wk-stale-toggle').classList.toggle('open');
    document.getElementById('wk-stale-detail').classList.toggle('open');
  }
  function toggleWeekShelf() {
    document.getElementById('wk-shelf-toggle').classList.toggle('open');
    document.getElementById('wk-shelf-detail').classList.toggle('open');
  }
  function toggleRmStrip() {
    var s = document.getElementById('rm-strip');
    if (!s) return;
    s.classList.toggle('open');
    LS.set('wbBoard.rmStrip', s.classList.contains('open') ? '1' : '0');
  }
  // A rung expands into the SAME summary-first block as everything else —
  // its own body (decisions/artifacts for that rung) stays underneath.
  function toggleRung(id) {
    var r = document.getElementById(id);
    if (!r) return;
    var host = r.querySelector(':scope > .detail-host');
    if (r.classList.toggle('expanded')) {
      if (host) mountDetail(host.getAttribute('data-anchor'), host);
    } else {
      unmountHost(host);
    }
  }

  // ---- repo filter (a task's `repo:`) -------------------------------
  var REPO = '';
  function pickRepo(ev, el) {
    if (ev) ev.stopPropagation();
    REPO = el.getAttribute('data-repo-pick') || '';
    LS.set('wbBoard.repo', REPO);
    applyRepo();
  }
  // `other` is a set of the repo names that did not earn their own chip
  // (plus the empty string, for tasks with no `repo:`), never "not
  // dotfiles" — a negation would have quietly included the named repos the
  // moment the top-5 list changed.
  var OTHER_SET = null;
  function otherSet() {
    if (OTHER_SET) return OTHER_SET;
    OTHER_SET = {};
    var c = document.querySelector('#repo-chips [data-repo-pick="__other__"]');
    if (c) (c.getAttribute('data-repo-set') || '').split('|').forEach(function(r){ OTHER_SET[r] = 1; });
    return OTHER_SET;
  }
  function repoOk(el) {
    if (!REPO) return true;
    var r = el.getAttribute('data-repo') || '';
    if (REPO === '__other__') return otherSet()[r] === 1;
    return r === REPO;
  }
  // Composes with scope and the text filter by owning its OWN class: each
  // of the three hides independently and `display:none` needs only one of
  // them to be true, so clearing one never resurrects what another hid.
  function applyRepo() {
    document.querySelectorAll('#repo-chips .repo-chip').forEach(function(c){
      c.classList.toggle('selected', (c.getAttribute('data-repo-pick') || '') === REPO);
    });
    var sel = '#rail-tasks [data-repo], #rail-families [data-repo], #deckRow .card-slot,' +
              ' .rm-lane, .week-card, .family-block, .carried-row, .qs-chip, .wk-shelf-row, .fam-tree-row';
    document.querySelectorAll(sel).forEach(function(el){
      el.classList.toggle('repo-hidden', !repoOk(el));
    });
  }

  // ---- U8: the shared summary-first detail block --------------------
  // Every task has exactly ONE detail node, parked in #detail-pool. Mounting
  // is a move (appendChild relocates), so a block can never be duplicated
  // and never drifts out of sync between views; unmounting parks it again.
  function mountDetail(anchor, host) {
    if (!anchor || !host) return null;
    var d = document.getElementById('detail-' + anchor);
    if (!d) return null;
    if (d.parentNode !== host) {
      // The block is a single node, so mounting it MOVES it. Whoever held
      // it must stop advertising itself as open, or it is left showing an
      // empty expanded box. (This bit: applyScope's Week auto-expand was
      // silently stealing the block the Active deck had just mounted.)
      var prev = d.parentNode;
      if (prev && prev.classList && prev.classList.contains('detail-host')) prev.classList.remove('open');
      host.appendChild(d);
    }
    host.classList.add('open');
    return d;
  }
  function unmountHost(host) {
    if (!host) return;
    var d = host.querySelector(':scope > .detail');
    if (d) document.getElementById('detail-pool').appendChild(d);
    host.classList.remove('open');
  }
  function hostFor(el) { return el ? el.querySelector(':scope > .detail-host') : null; }

  function toggleWeekCard(ev, el) {
    if (ev && ev.target && ev.target.closest('.copyable')) return;
    if (ev && ev.target && ev.target.closest('.detail')) return;
    if (ev && ev.target && ev.target.closest('a')) return;
    var host = hostFor(el);
    if (el.classList.toggle('expanded')) mountDetail(el.getAttribute('data-anchor'), host);
    else unmountHost(host);
  }

  // Family view: one expanded child per family block, so a family stays
  // readable as a family rather than becoming a wall of open details.
  function toggleFamDetail(ev, el) {
    if (ev && ev.target && ev.target.closest('.copyable')) return;
    if (ev && ev.target && ev.target.closest('a')) return;
    var host = el.nextElementSibling;
    if (!host || !host.classList.contains('detail-host')) return;
    var block = el.closest('.fam-block') || document;
    var wasOpen = host.classList.contains('open');
    block.querySelectorAll('.detail-host.open').forEach(unmountHost);
    block.querySelectorAll('.fam-tree-row.expanded').forEach(function(r){ r.classList.remove('expanded'); });
    if (!wasOpen) { el.classList.add('expanded'); mountDetail(el.getAttribute('data-anchor'), host); }
  }

  // ---- rail clicks ----------------------------------------------------
  // The primary click on any rail row SELECTS (sets scope); copying is the
  // explicit ⧉ glyph only, so one click never both copies and scopes.
  function railPick(ev, el) {
    if (ev && ev.target && ev.target.closest('.copyable')) return;
    var fam = el.getAttribute('data-family') || '';
    var anchor = el.getAttribute('data-anchor') || '';
    setScope(fam, anchor);
  }
  // A family <summary> keeps its native open/close on the chevron only;
  // anywhere else on the row scopes to that family instead of toggling.
  function railSummaryClick(ev, el) {
    if (ev.target.closest('.copyable')) return;
    if (ev.target.closest('.chev')) return;
    ev.preventDefault();
    var fam = el.getAttribute('data-family') || '';
    var anchor = el.getAttribute('data-anchor') || '';
    setScope(fam, anchor === fam ? '' : anchor);
  }

  function setScope(family, task) {
    SCOPE.family = family || '';
    SCOPE.task = task || '';
    LS.set('wbBoard.scope', JSON.stringify(SCOPE));
    applyScope();
  }

  function railTitleFor(anchor) {
    if (!anchor) return '';
    var r = document.querySelector('#rail-tasks [data-anchor="' + anchor + '"]');
    if (!r) return anchor;
    var t = r.querySelector('.rail-row-title, .shelf-text');
    return t ? t.textContent.trim() : anchor;
  }
  // The rail carries the real `status:` in data-status, so the empty state
  // can say "(planned)" rather than inferring it from which widgets the
  // row happens to have rendered.
  function railStatusFor(anchor) {
    var r = document.querySelector('#rail-tasks [data-anchor="' + anchor + '"]');
    if (!r) return '';
    return (r.getAttribute('data-status') || '').trim();
  }

  // `mount` is false when the Active view isn't the one on screen: only the
  // CURRENT view may hold the shared block, and showView() re-runs
  // applyScope(), so switching tabs re-mounts it wherever it now belongs.
  function selectCardSlot(slot, scroll, mount) {
    document.querySelectorAll('#deckRow .card-slot').forEach(function(s){ s.classList.remove('selected'); });
    document.querySelectorAll('#deckRow .card').forEach(function(c){ c.classList.remove('selected'); });
    document.querySelectorAll('#deckRow .detail-host.open').forEach(unmountHost);
    if (!slot) return;
    slot.classList.add('selected');
    var card = slot.querySelector('.card');
    if (card) card.classList.add('selected');
    if (mount !== false) mountDetail(slot.getAttribute('data-anchor'), hostFor(slot));
    if (scroll) scrollSlotIntoView(slot);
  }

  // Scrolling the CARD with block:'nearest' is not enough: the card is
  // already on screen (that is why it was clicked), so 'nearest' is a
  // no-op, and the drilldown that just opened underneath it lands below
  // the fold — the exact complaint this pass set out to fix, reproduced
  // for any card low in the viewport. Scroll the whole SLOT (card +
  // drilldown) instead, and when the slot is taller than the viewport
  // fall back to aligning its top, so the drilldown's headings are the
  // thing you see rather than its tail.
  function scrollSlotIntoView(slot) {
    var vh = window.innerHeight || document.documentElement.clientHeight;
    var h = slot.getBoundingClientRect().height;
    slot.scrollIntoView(h > vh - 40 ? {block: 'start'} : {block: 'nearest'});
  }

  function applyScope() {
    var fam = SCOPE.family, task = SCOPE.task;

    // --- rail selection -----------------------------------------------
    document.querySelectorAll('#rail-tasks [data-anchor]').forEach(function(r){
      var a = r.getAttribute('data-anchor') || '';
      var f = r.getAttribute('data-family') || '';
      var isSel = task ? (a === task) : (fam ? (a === fam) : (a === ''));
      r.classList.toggle('selected', isSel);
      r.classList.toggle('scoped', !!fam && !!a && f === fam && !isSel);
    });
    // Family tab selection follows the same scope.
    document.querySelectorAll('.fam-rail-row').forEach(function(r){
      r.classList.toggle('selected', !!fam && r.getAttribute('data-fam') === fam);
    });
    if (fam && document.getElementById('fam-' + fam)) showFamilyBlock(fam);

    // --- Active --------------------------------------------------------
    var slots = Array.prototype.slice.call(document.querySelectorAll('#deckRow .card-slot'));
    var visible = [], taskSlot = null;
    slots.forEach(function(s){
      var hide = !!fam && s.getAttribute('data-family') !== fam;
      s.classList.toggle('scope-hidden', hide);
      if (!hide) visible.push(s);
      if (task && s.getAttribute('data-anchor') === task) taskSlot = s;
    });
    // A task scope with no card of its own must NOT quietly fall back to
    // the family's first card — picking "Job entrypoint" and watching a
    // different task light up reads as a bug. It gets the same honest
    // empty-state line the shelf case already got; only a family-level
    // scope (or none) auto-selects.
    var taskMissing = !!task && !taskSlot;
    selectCardSlot(taskSlot || (taskMissing ? null : visible[0]) || null,
                   !!taskSlot && CURRENT_VIEW === 'active',
                   CURRENT_VIEW === 'active');

    var hdr = document.getElementById('active-scope-header');
    if (hdr) {
      if (fam) {
        hdr.style.display = '';
        hdr.innerHTML = '';
        var lab = document.createElement('span'); lab.className = 'scope-label'; lab.textContent = 'Family';
        var nm = document.createElement('span'); nm.className = 'scope-name'; nm.textContent = railTitleFor(fam) || fam;
        var cnt = document.createElement('span'); cnt.className = 'scope-count';
        cnt.textContent = '· ' + visible.length + (visible.length === 1 ? ' card' : ' cards');
        var clr = document.createElement('span'); clr.className = 'scope-clear'; clr.textContent = 'All';
        clr.addEventListener('click', function(){ setScope('', ''); });
        hdr.appendChild(lab); hdr.appendChild(nm); hdr.appendChild(cnt); hdr.appendChild(clr);
      } else {
        hdr.style.display = 'none';
        hdr.textContent = '';
      }
    }
    var empty = document.getElementById('active-scope-empty');
    if (empty) {
      if (taskMissing || (visible.length === 0 && (fam || task))) {
        empty.style.display = '';
        var who = taskMissing ? task : (task || fam);
        var st = railStatusFor(who);
        empty.textContent = 'No doing card for ' + (railTitleFor(who) || who) +
          (st ? ' (' + st + ')' : '') + ' — see it in Roadmap or Week.';
      } else {
        empty.style.display = 'none';
        empty.textContent = '';
      }
    }

    // --- Roadmap: dim, never hide (a roadmap of one lane is useless) ----
    // A scope now HIDES the other lanes outright rather than dimming them:
    // live use showed that at 18 lanes, "find the one that isn't faded" is
    // still a search. Unscoped still shows everything, and the grid header,
    // TODAY marker and readiness line are outside .rm-lane so they stay.
    var scopedLane = null;
    document.querySelectorAll('.rm-lane').forEach(function(l){
      var f = l.getAttribute('data-family') || '';
      var isScoped = !!fam && f === fam;
      l.classList.toggle('scope-hidden', !!fam && !isScoped);
      l.classList.remove('scope-dim');
      l.classList.toggle('selected', isScoped);
      if (isScoped) scopedLane = l;
    });
    document.querySelectorAll('.rm-bar').forEach(function(b){
      b.classList.toggle('selected', !!task && b.getAttribute('data-anchor') === task);
    });
    if (scopedLane && CURRENT_VIEW === 'roadmap') scopedLane.scrollIntoView({block: 'center'});

    // --- Week ----------------------------------------------------------
    document.querySelectorAll('#view-week [data-family]').forEach(function(el){
      el.classList.toggle('scope-hidden', !!fam && el.getAttribute('data-family') !== fam);
    });
    if (task && CURRENT_VIEW === 'week') {
      document.querySelectorAll('.week-card').forEach(function(c){
        if (c.getAttribute('data-anchor') === task) {
          c.classList.add('expanded');
          mountDetail(task, hostFor(c));
        }
      });
    }
    var whdr = document.getElementById('week-scope-header');
    if (whdr) {
      if (fam) {
        whdr.style.display = '';
        whdr.innerHTML = '';
        var wl = document.createElement('span'); wl.className = 'scope-label'; wl.textContent = 'Family';
        var wn = document.createElement('span'); wn.className = 'scope-name'; wn.textContent = railTitleFor(fam) || fam;
        var wc = document.createElement('span'); wc.className = 'scope-clear'; wc.textContent = 'All';
        wc.addEventListener('click', function(){ setScope('', ''); });
        whdr.appendChild(wl); whdr.appendChild(wn); whdr.appendChild(wc);
      } else {
        whdr.style.display = 'none';
        whdr.textContent = '';
      }
    }
  }

  // ---- Family tab -----------------------------------------------------
  function showFamilyBlock(anchor) {
    document.querySelectorAll('.fam-block').forEach(function(b){ b.style.display = 'none'; });
    var b = document.getElementById('fam-' + anchor);
    if (b) b.style.display = 'block';
    document.querySelectorAll('.fam-rail-row').forEach(function(r){
      r.classList.toggle('selected', r.getAttribute('data-fam') === anchor);
    });
  }
  // Picking in #rail-families also sets the global scope, so switching to
  // Active/Roadmap/Week keeps the same family.
  function selectFamily(anchor) {
    showFamilyBlock(anchor);
    if (SCOPE.family !== anchor) setScope(anchor, '');
  }

  // ---- Active deck clicks ---------------------------------------------
  document.querySelectorAll('#deckRow .card').forEach(function(c){
    c.addEventListener('click', function(e){
      if (e.target.closest('.copyable')) return;
      selectCardSlot(c.closest('.card-slot'), true);
    });
  });

  // R22: click-to-copy `wb resume <id>` for any .copyable element.
  document.addEventListener('click', function(e){
    var el = e.target.closest('.copyable');
    if (!el) return;
    var text = el.getAttribute('data-copy');
    if (!text) return;
    var mark = function(){ el.classList.add('copied'); setTimeout(function(){ el.classList.remove('copied'); }, 900); };
    if (navigator.clipboard && navigator.clipboard.writeText) {
      navigator.clipboard.writeText(text).then(mark).catch(mark);
    } else {
      var ta = document.createElement('textarea');
      ta.value = text; document.body.appendChild(ta); ta.select();
      try { document.execCommand('copy'); } catch (err) {}
      document.body.removeChild(ta);
      mark();
    }
  });

  // ---- keyboard: 1-4 views, / filter, j/k rail, Enter scope, a all ----
  function visibleRailRows() {
    var panel = document.getElementById('rail-families').style.display === 'none' ? '#rail-tasks' : '#rail-families';
    var sel = panel + ' .rail-row, ' + panel + ' details.family-node > summary, ' + panel + ' .shelf-row';
    return Array.prototype.slice.call(document.querySelectorAll(sel)).filter(function(el){
      return el.offsetParent !== null && !el.classList.contains('filter-hidden');
    });
  }
  function moveRailCursor(delta) {
    var rows = visibleRailRows();
    if (!rows.length) return;
    var idx = rows.findIndex(function(r){ return r.classList.contains('rail-cursor'); });
    if (idx === -1) idx = rows.findIndex(function(r){ return r.classList.contains('selected'); });
    if (idx === -1) idx = delta > 0 ? -1 : 0;
    idx = Math.min(Math.max(idx + delta, 0), rows.length - 1);
    rows.forEach(function(r){ r.classList.remove('rail-cursor'); });
    rows[idx].classList.add('rail-cursor');
    rows[idx].scrollIntoView({block: 'nearest'});
  }
  document.addEventListener('keydown', function(e){
    if (e.target && e.target.id === 'board-filter') {
      if (e.key === 'Escape') { e.target.value = ''; filterBoard(''); e.target.blur(); }
      // `/` is "focus the filter". Already focused, so make it mean
      // "start over": select the whole query so the next keystroke
      // replaces it, rather than appending a literal slash.
      if (e.key === '/') { e.preventDefault(); e.target.select(); }
      return;
    }
    if (e.metaKey || e.ctrlKey || e.altKey) return;
    if (e.key === '1') { showView('active'); return; }
    if (e.key === '2') { showView('roadmap'); return; }
    if (e.key === '3') { showView('week'); return; }
    if (e.key === '4') { showView('family'); return; }
    if (e.key === '/') {
      e.preventDefault();
      var f = document.getElementById('board-filter');
      if (f) f.focus();
      return;
    }
    if (e.key === 'a') { setScope('', ''); return; }
    if (e.key === 'Escape') {
      document.querySelectorAll('.rail-cursor').forEach(function(r){ r.classList.remove('rail-cursor'); });
      return;
    }
    if (e.key === 'j') { e.preventDefault(); moveRailCursor(1); return; }
    if (e.key === 'k') { e.preventDefault(); moveRailCursor(-1); return; }
    if (e.key === 'Enter') {
      var cur = document.querySelector('.rail-cursor');
      if (cur) { e.preventDefault(); cur.click(); }
      return;
    }
  });

  // ---- filter: rail tree AND the main pane of every view --------------
  function filterBoard(q) {
    q = q.toLowerCase();
    // Descendant selector (not a fixed-depth child chain) so this matches
    // both #rail-tasks's tree (nested one level deeper, under its own
    // wrapper div) and #rail-families's flat list — whichever is visible.
    // The "All doing" row is scope, not content — never filtered away.
    document.querySelectorAll('.rail .rail-tree > .rail-row, .rail .rail-tree > details.family-node').forEach(function(el){
      if (el.classList.contains('rail-all')) return;
      var t = (el.querySelector('.rail-row-title') || el).textContent.toLowerCase();
      el.classList.toggle('filter-hidden', q.length > 0 && t.indexOf(q) === -1);
    });
    // UX pass: the filter used to narrow the rail only, leaving the deck
    // at its full 24 cards. It now narrows the main pane of every view by
    // the same query.
    var mainSel = '#deckRow .card-slot, .rm-lane, .rm-stale-row, .week-card, .family-block, .carried-row, .qs-chip, .wk-shelf-row, .fam-tree-row';
    document.querySelectorAll(mainSel).forEach(function(el){
      var t = (el.querySelector('.card-title, .rm-title-row, .title, .row-title, .t-title, .t') || el).textContent.toLowerCase();
      el.classList.toggle('filter-hidden', q.length > 0 && t.indexOf(q) === -1);
    });
  }
  (function(){
    var f = document.getElementById('board-filter');
    if (f) f.addEventListener('input', function(){ filterBoard(f.value); });
  })();

  // ---- restore persisted view + scope ---------------------------------
  (function(){
    var s = document.getElementById('rm-strip');
    if (s && LS.get('wbBoard.rmStrip', '0') === '1') s.classList.add('open');
    // The ladder's "now" rung renders pre-expanded; mount its block so it
    // is not an open rung with an empty summary slot.
    document.querySelectorAll('.rung.expanded > .detail-host').forEach(function(h){
      mountDetail(h.getAttribute('data-anchor'), h);
    });
    var saved = LS.get('wbBoard.scope', '');
    if (saved) {
      try {
        var o = JSON.parse(saved);
        // Only restore a scope whose family/task still exists in this
        // render — the store moves between renders and a stale anchor
        // would silently blank every view.
        var fam = o && o.family ? String(o.family) : '';
        var task = o && o.task ? String(o.task) : '';
        if (fam && !document.querySelector('[data-family="' + fam + '"]')) { fam = ''; task = ''; }
        if (task && !document.querySelector('#deckRow [data-anchor="' + task + '"], #rail-tasks [data-anchor="' + task + '"]')) task = '';
        SCOPE.family = fam; SCOPE.task = task;
      } catch (err) {}
    }
    REPO = LS.get('wbBoard.repo', '');
    if (REPO && !document.querySelector('#repo-chips [data-repo-pick="' + REPO + '"]')) REPO = '';
    applyRepo();
    var view = LS.get('wbBoard.view', 'active');
    if (!document.getElementById('view-' + view)) view = 'active';
    showView(view);
  })();
</script>
</body>
</html>
HTMLEOF
)"
  local -A PAGE_TOKENS=(
    [RAIL_HTML]="$rail_html"
    [DECK_HTML]="$deck_html"
    [ROADMAP_HTML]="$roadmap_view_html"
    [WEEK_HTML]="$week_view_html"
    [FAMILY_HTML]="$family_view_html"
    [DETAIL_POOL_HTML]="$detail_pool_html"
    [TAB_BADGE]="$tab_badge"
    [FAM_TAB_BADGE]="$fam_tab_badge"
    [GENERATED_TS]="$generated_ts"
  )
  local page_out
  wb_board_v2_fill_template "$page_template" PAGE_TOKENS page_out
  printf '%s\n' "$page_out"
}
