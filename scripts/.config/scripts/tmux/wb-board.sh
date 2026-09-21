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

# wb_board_escape_replacement <text> — escape <text> for safe use as the
# REPLACEMENT side of bash's ${var//pattern/replacement} (U7's page-
# template substitution). An unescaped `&` there means "insert whatever
# matched the pattern" (mirrors sed's replacement syntax) — silently
# corrupting every HTML entity (&amp;, &#183;, &lt;, ...) in the value
# being substituted, since HTML-escaped content is FULL of literal `&`.
# Backslash is escaped FIRST, or a real backslash already in the text
# would combine with the newly-inserted `\&` and change meaning.
wb_board_escape_replacement() {
  local s="$1"
  s="${s//\\/\\\\}"
  s="${s//&/\\&}"
  printf '%s' "$s"
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
wb_board_v2_anchor() {
  # fix(review) D2A: optional <out_var> so the collect loop can call this as a
  # plain statement (printf -v, no subshell) instead of `$(...)`; stdout
  # fallback keeps existing/test callers working.
  local __a="${1//[^A-Za-z0-9_-]/-}"
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
#     closed \t plan_checked \t plan_total \t title
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
    BEGIN {
      SOH = sprintf("%c", 1)
      status=""; repo=""; worktree=""; branch=""; path=""; deps=""
      reviewed=""; parent=""; tags=""; created=""; closed=""; title=""
      infm = 0; donefm = 0; cursec = ""; handoff_capturing = 0; title_found = 0
      plan_checked = 0; plan_total = 0
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
    !title_found && /^# / { title = $0; sub(/^# /, "", title); title_found = 1 }
    { extract_links($0) }
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
      if ($0 ~ /^### /) { handoff_text = $0 "\n"; handoff_capturing = 1; next }
      if (handoff_capturing) { handoff_text = handoff_text $0 "\n" }
      next
    }
    END {
      printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s", \
        status, repo, worktree, branch, path, deps, reviewed, parent, tags, \
        created, closed, plan_checked, plan_total, title
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
#   17 age_days  18 bucket(active|stale|shelved)
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
  local -A _mtimes=()
  wb_board_v2_mtimes _mtimes
  local now; now="$(date +%s)"
  local f stem anchor parent title updated age_days bucket record
  local -a scalar=() t=() plan_a=() done_a=() handoff_a=() followups_a=() decisions_a=() links_a=()
  while IFS= read -r f; do
    [ -f "$f" ] || continue
    record="$(wb_board_v2_read_file "$f")"
    wb_board_v2_parse_record "$record" scalar plan_a done_a handoff_a followups_a decisions_a links_a
    wb_tsv_split "${scalar[0]}" t
    # t: 0 status 1 repo 2 worktree 3 branch 4 path 5 deps 6 reviewed
    #    7 parent 8 tags 9 created 10 closed 11 plan_checked 12 plan_total
    #    13 title
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
    printf -v record '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s' \
      "$stem" "${t[0]:-}" "${t[1]:-}" "${t[3]:-}" "${t[2]:-}" "$title" "${t[9]:-}" "${t[10]:-}" \
      "$updated" "$f" "$anchor" "$parent" "${t[5]:-}" "${t[8]:-}" "${t[11]:-0}" "${t[12]:-0}" \
      "$age_days" "$bucket"
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
#     STEM_ANCHOR=() FAMILY_CHILDREN=() BUCKET_COUNT=()
#   wb_board_build_model V2ROWS M_PLAN_RAW M_DONE_RAW M_HANDOFF_RAW M_FOLLOWUPS_RAW \
#     M_STATUS M_REPO M_BRANCH M_WORKTREE M_TITLE M_CREATED M_CLOSED M_UPDATED \
#     M_TASKFILE M_PARENT M_DEPS M_TAGS M_PLAN_CHECKED M_PLAN_TOTAL M_AGE_DAYS \
#     M_BUCKET M_HANDOFF_SUMMARY M_FAMILY_ROOT STEM_PARENT STEM_ANCHOR \
#     FAMILY_CHILDREN BUCKET_COUNT
wb_board_build_model() {
  local -n _bm_rows="$1" _bm_plan="$2" _bm_done="$3" _bm_handoff="$4" _bm_followups="$5"
  local -n _status="$6" _repo="$7" _branch="$8" _worktree="$9" _title="${10}"
  local -n _created="${11}" _closed="${12}" _updated="${13}" _taskfile="${14}" _parent="${15}"
  local -n _deps="${16}" _tags="${17}" _plan_checked="${18}" _plan_total="${19}" _age_days="${20}"
  local -n _bucket="${21}" _handoff_summary="${22}" _family_root="${23}"
  local -n _stem_parent="${24}" _stem_anchor="${25}" _family_children="${26}" _bucket_count="${27}"

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
  local raw="${1:-}" line trimmed text out=""
  while IFS= read -r line; do
    trimmed="${line#"${line%%[![:space:]]*}"}"
    case "$trimmed" in
      '- [x]'*|'- [X]'*)
        text="${trimmed#*'] '}"
        out+="<li class=\"done-item\"><span class=\"chk done\">&#10003;</span> $(wb_board_html_escape "$text")</li>"
        ;;
      '- [ ]'*)
        text="${trimmed#*'] '}"
        out+="<li><span class=\"chk todo\">&#9675;</span> $(wb_board_html_escape "$text")</li>"
        ;;
    esac
  done <<< "$raw"
  printf '%s' "$out"
}

# wb_board_v2_bullet_html <raw_text> [<li_class>] — plain "- "/"* " bullet
# lines (Done, Follow-ups) as <li>s, optionally classed (e.g. "followup").
wb_board_v2_bullet_html() {
  local raw="${1:-}" cls="${2:-}" line trimmed text out=""
  while IFS= read -r line; do
    trimmed="${line#"${line%%[![:space:]]*}"}"
    case "$trimmed" in
      '- '*) text="${trimmed#'- '}" ;;
      '* '*) text="${trimmed#'* '}" ;;
      *) continue ;;
    esac
    if [ -n "$cls" ]; then
      out+="<li class=\"$cls\">$(wb_board_html_escape "$text")</li>"
    else
      out+="<li>$(wb_board_html_escape "$text")</li>"
    fi
  done <<< "$raw"
  printf '%s' "$out"
}

# wb_board_v2_handoff_heading <raw_handoff_text> — the latest Handoff
# block's own "### <timestamp> — <source>" heading line, minus the "### "
# marker, or empty. wb_board_v2_read_file already scoped <raw_handoff_text>
# to just the LAST such block (R16's single pass), so this is just the
# first line here, no re-filtering.
wb_board_v2_handoff_heading() {
  local raw="${1:-}" line
  while IFS= read -r line; do
    case "$line" in
      '### '*) printf '%s' "${line#'### '}"; return 0 ;;
    esac
  done <<< "$raw"
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
  local stem="$1"
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
  local kids="${_m_family_children[$stem]:-}"
  if [ -n "$kids" ]; then
    printf '<details class="family-node" open><summary><span class="chev">&#9656;</span><span class="dot %s"></span><span class="rail-row-title copyable" data-copy="wb resume %s">%s</span>%s</summary><div class="family-children">' \
      "$dot" "$stem" "$title" "$right"
    local rn_child
    while IFS= read -r rn_child; do
      [ -n "$rn_child" ] || continue
      wb_board_v2_rail_node_html "$rn_child"
    done <<< "$kids"
    printf '</div></details>'
  else
    printf '<div class="rail-row"><span class="dot %s"></span><span class="rail-row-title copyable" data-copy="wb resume %s">%s</span>%s</div>' \
      "$dot" "$stem" "$title" "$right"
  fi
}

# wb_board_v2_shelf_items_html <newline_list_of_stems> — the rail's
# collapsed Next/Shelf group body: one `.shelf-row` per stem, title-only
# (no dot color grading — these are presentational catch-alls, not a
# freshness signal), click-to-copy (R22).
wb_board_v2_shelf_items_html() {
  local list="$1" si_stem out=""
  while IFS= read -r si_stem; do
    [ -n "$si_stem" ] || continue
    out+="<div class=\"shelf-row\"><span class=\"shelf-dot\"></span><span class=\"shelf-text copyable\" data-copy=\"wb resume $si_stem\">$(wb_board_html_escape "${_m_title[$si_stem]:-$si_stem}")</span></div>"
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
wb_board_v2_plan_ul() {
  local stem="$1" items; items="$(wb_board_v2_checklist_html "${_m_plan_raw[$stem]:-}")"
  if [ -n "$items" ]; then printf '<ul>%s</ul>' "$items"
  else printf '<p style="color:var(--subtext);font-size:14.5px;margin:0;">No plan logged yet.</p>'
  fi
}
wb_board_v2_done_ul() {
  local stem="$1" items; items="$(wb_board_v2_bullet_html "${_m_done_raw[$stem]:-}")"
  if [ -n "$items" ]; then printf '<ul>%s</ul>' "$items"
  else printf '<p style="color:var(--subtext);font-size:14.5px;margin:0;">No activity logged yet.</p>'
  fi
}
wb_board_v2_followups_ul() {
  local stem="$1" items; items="$(wb_board_v2_bullet_html "${_m_followups_raw[$stem]:-}" followup)"
  if [ -n "$items" ]; then printf '<ul>%s</ul>' "$items"
  else printf '<p style="color:var(--subtext);font-size:14.5px;margin:0;">No follow-ups.</p>'
  fi
}

# wb_board_v2_handoff_meta <stem> — "Latest handoff · <heading> — "<summary>""
# for the drilldown/wdrill's meta line, or a placeholder when the task has
# no Handoffs section at all.
wb_board_v2_handoff_meta() {
  local stem="$1" raw heading summary
  raw="${_m_handoff_raw[$stem]:-}"
  if [ -z "$raw" ]; then printf 'No handoff logged yet.'; return 0; fi
  heading="$(wb_board_v2_handoff_heading "$raw")"
  summary="${_m_handoff_summary[$stem]:-}"
  printf 'Latest handoff &middot; %s' "$(wb_board_html_escape "$heading")"
  [ -n "$summary" ] && printf ' &mdash; &ldquo;%s&rdquo;' "$(wb_board_html_escape "$summary")"
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
    printf '%s\t<div class="rm-bar active-bar" title="doing &middot; %s">doing &middot; %s</div>' \
      "$track" "$(wb_board_v2_age_label "$age")" "$(wb_board_v2_age_label "$age")"
  elif [ "$status" = planned ]; then
    if [ -n "${UNMET_COUNT[$stem]:-}" ]; then   # fix(review) D4: keyed by stem, not anchor
      printf '6\t<div class="rm-bar blocked-bar"><span class="lock-ic">&#128274;</span>%s<span class="rm-after-tag">after: %s</span></div>' \
        "$title_attr" "$(wb_board_html_escape "${BLOCKER_NAMES[$stem]:-}")"
    else
      printf '5\t<div class="rm-bar ready-bar" title="%s">%s</div>' "$title_attr" "$title_attr"
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

# wb_board_render_v2 <27 model array names, exactly wb_board_build_model's
# own output-array list, PLUS M_DECISIONS_RAW M_LINKS_RAW (U5, PR2 — the
# Family view's own raw text, never touched by build_model since they carry
# no per-field model derivation, just pass-through text like M_PLAN_RAW)> —
# the ratified 3-view (Active/Roadmap/Week) HTML page (U3) plus the Family
# view (U6). Deliberately takes the SAME 27 names cmd_board's --html branch
# already builds for wb_board_build_model, in the SAME order, plus the 2
# trailing raw arrays, so a caller does:
#   wb_board_collect_rows_v2 V2ROWS M_PLAN_RAW M_DONE_RAW M_HANDOFF_RAW M_FOLLOWUPS_RAW \
#     M_DECISIONS_RAW M_LINKS_RAW
#   wb_board_build_model V2ROWS M_PLAN_RAW ... BUCKET_COUNT
#   wb_board_render_v2   V2ROWS M_PLAN_RAW ... BUCKET_COUNT M_DECISIONS_RAW M_LINKS_RAW
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
  local -n _m_decisions_raw="${28}" _m_links_raw="${29}"

  local now; now="$(date +%s)"

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
  local rail_doing_html="" rd_stem
  for rd_stem in "${active_family_roots_sorted[@]}"; do
    rail_doing_html+="$(wb_board_v2_rail_node_html "$rd_stem")"
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

  local rail_html
  rail_html="<input type=\"text\" id=\"board-filter\" class=\"rail-filter\" placeholder=\"Filter&hellip; (press /)\" autocomplete=\"off\">"
  rail_html+="<div><div class=\"rail-heading\">Doing</div><div class=\"rail-tree\">${rail_doing_html}</div></div>"
  rail_html+="<div class=\"group\" id=\"next-group\"><div class=\"group-head\" onclick=\"toggleGroup('next-group')\"><span class=\"group-caret\">&#9656;</span><span class=\"group-label\">Next &middot; <span class=\"count-blue\">${#next_items[@]}</span></span></div><div class=\"group-body\">${next_html}</div></div>"
  rail_html+="<div class=\"group expanded\" id=\"shelf-group\"><div class=\"group-head\" onclick=\"toggleGroup('shelf-group')\"><span class=\"group-caret\">&#9656;</span><span class=\"group-label\">Shelf &middot; <span class=\"count-peach\">${#shelf_items[@]}</span></span></div><div class=\"group-body\">${shelf_html}</div></div>"

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

  local deck_html="" drilldowns_html="" dk_idx=0
  for dk_stem in "${deck_order[@]}"; do
    dk_idx=$((dk_idx + 1))
    local dk_anchor="${_m_stem_anchor[$dk_stem]}"
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

    deck_html+="<div class=\"card${dk_sel_cls}${dk_stale_cls}\" id=\"card-${dk_anchor}\" data-drilldown=\"drilldown-${dk_anchor}\">"
    deck_html+="<div class=\"card-top\"><div><div class=\"card-title\">${dk_title}</div><span class=\"card-id mono copyable\" data-copy=\"wb resume ${dk_stem}\">${dk_stem}</span></div>"
    deck_html+="<div class=\"ring-wrap\"><svg width=\"42\" height=\"42\" viewBox=\"0 0 42 42\"><circle cx=\"21\" cy=\"21\" r=\"17\" fill=\"none\" stroke=\"var(--overlay)\" stroke-width=\"4\"/>${dk_ring_circle}</svg><span class=\"ring-label\">${dk_ring_label}</span></div></div>"
    deck_html+="${dk_quote_html}"
    deck_html+="<div class=\"next-line\">Next: <b>$(wb_board_html_escape "$dk_next")</b></div>"
    deck_html+="<div class=\"card-foot\"><span class=\"dot ${dk_dot}\"></span><span class=\"mono\">$(wb_board_v2_age_label "$dk_age")</span></div>"
    deck_html+="</div>"

    local dk_active_cls=""
    [ "$dk_idx" = 1 ] && dk_active_cls=" active"
    drilldowns_html+="<div class=\"drilldown${dk_active_cls}\" id=\"drilldown-${dk_anchor}\">"
    drilldowns_html+="<div><h3>Plan</h3>$(wb_board_v2_plan_ul "$dk_stem")</div>"
    drilldowns_html+="<div><h3>Done</h3>$(wb_board_v2_done_ul "$dk_stem")<div class=\"dd-meta\">$(wb_board_v2_handoff_meta "$dk_stem")</div></div>"
    drilldowns_html+="<div><h3>Follow-ups</h3>$(wb_board_v2_followups_ul "$dk_stem")</div>"
    drilldowns_html+="</div>"
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
    if [ -n "$rm_kids" ]; then
      local rm_total=${#rm_members[@]} rm_done=0
      for rm_member in "${rm_members[@]}"; do
        [ "${_m_status[$rm_member]:-}" = done ] && rm_done=$((rm_done + 1))
      done
      rm_lanes_html+="<div class=\"rm-lane milestone-lane\"><div class=\"rm-lane-label\" title=\"${rm_title}\"><div class=\"rm-title-row\">${rm_title} <span class=\"rm-mfrac mono\">${rm_done} / ${rm_total}</span></div></div>"
      rm_lanes_html+="<div class=\"rm-bracket\" style=\"grid-column: ${rm_min_track} / ${rm_span_end};\"></div>"
      rm_lanes_html+="<div class=\"rm-bars\" style=\"grid-column: ${rm_min_track} / ${rm_span_end};\">${rm_bars}</div></div>"
    else
      local rm_dot; rm_dot="$(wb_board_v2_dot_class "${_m_status[$rm_stem]}" "${_m_bucket[$rm_stem]}" "${_m_age_days[$rm_stem]:-0}")"
      rm_lanes_html+="<div class=\"rm-lane\"><div class=\"rm-lane-label\" title=\"${rm_title}\"><div class=\"rm-title-row\">${rm_title}</div><div class=\"rm-standalone-meta\"><span class=\"dot ${rm_dot}\"></span><span class=\"mono\">$(wb_board_v2_age_label "${_m_age_days[$rm_stem]:-0}")</span></div></div>"
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
  local rm_readiness_html=""
  [ -n "$ready_html" ] && rm_readiness_html+="<div class=\"rm-readiness-group\"><span class=\"rm-readiness-label\">Ready now &middot; ${#ready_planned[@]}</span>${ready_html}</div>"
  [ -n "$blocked_html" ] && rm_readiness_html+="<div class=\"rm-readiness-group\"><span class=\"rm-readiness-label\">Blocked &middot; ${#blocked_planned[@]}</span>${blocked_html}</div>"

  # stale toggle content — flat, store-wide, shared shape by both the
  # Roadmap and Week views (each renders it into its own container markup).
  local -a stale_stems=()
  local st_stem
  for st_stem in "${!_m_stem_anchor[@]}"; do
    [ "${_m_bucket[$st_stem]:-}" = stale ] && stale_stems+=("$st_stem")
  done
  local rm_stale_rows_html="" week_stale_rows_html=""
  if [ "${#stale_stems[@]}" -gt 0 ]; then
    local ss_stem
    while IFS= read -r ss_stem; do
      rm_stale_rows_html+="<div class=\"rm-stale-row\"><div class=\"rm-lane-label\" title=\"$(wb_board_html_escape "${_m_title[$ss_stem]:-$ss_stem}")\"><span class=\"dot red\"></span>$(wb_board_html_escape "${_m_title[$ss_stem]:-$ss_stem}")<span class=\"age-red mono\">$(wb_board_v2_age_label "${_m_age_days[$ss_stem]:-0}")</span></div></div>"
      week_stale_rows_html+="<div class=\"carried-row\"><span class=\"dot red\"></span><span class=\"row-title\"><span class=\"id mono copyable\" data-copy=\"wb resume $ss_stem\">$ss_stem</span>$(wb_board_html_escape "${_m_title[$ss_stem]:-$ss_stem}")</span><span class=\"age\" style=\"color:var(--red);\">$(wb_board_v2_age_label "${_m_age_days[$ss_stem]:-0}")</span></div>"
    done < <(wb_board_v2_sort_stems_by_age desc "${stale_stems[@]}")
  fi

  local roadmap_view_html
  roadmap_view_html='<div class="rm-board"><div class="rm-grid-header"><div class="col-label"></div><div class="col-label">2 wks ago</div><div class="col-label">last wk</div><div class="col-label this-week">THIS WEEK</div><div class="col-label">next</div><div class="col-label">later</div></div>'
  [ -n "$rm_readiness_html" ] && roadmap_view_html+="<div class=\"rm-readiness-strip\">${rm_readiness_html}</div>"
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

  local week_cards_html=""
  if [ "${#this_week_stems[@]}" -gt 0 ]; then
    local wc_stem
    while IFS= read -r wc_stem; do
      local wc_dot; wc_dot="$(wb_board_v2_dot_class "${_m_status[$wc_stem]}" "${_m_bucket[$wc_stem]}" "${_m_age_days[$wc_stem]:-0}")"
      local wc_title; wc_title="$(wb_board_html_escape "${_m_title[$wc_stem]:-$wc_stem}")"
      local wc_parent_html=""
      [ -n "${_m_stem_parent[$wc_stem]:-}" ] && wc_parent_html=" &middot; <span class=\"parent-chip mono\">child of $(wb_board_html_escape "${_m_stem_parent[$wc_stem]}")</span>"
      week_cards_html+="<div class=\"week-card\"><div class=\"top-row\"><span class=\"dot ${wc_dot}\"></span><span class=\"title\">${wc_title}</span><span class=\"week-badge\">$(wb_board_html_escape "${_m_status[$wc_stem]:-}")</span></div>"
      week_cards_html+="<div class=\"meta\"><span class=\"mono copyable\" data-copy=\"wb resume $wc_stem\">$wc_stem</span> &middot; touched $(wb_board_v2_age_label "${_m_age_days[$wc_stem]:-0}")${wc_parent_html}</div>"
      week_cards_html+="<div class=\"wdrill\"><div><div class=\"wdrill-block\"><h4>Plan</h4>$(wb_board_v2_plan_ul "$wc_stem")</div><div class=\"wdrill-block\"><h4>Done</h4>$(wb_board_v2_done_ul "$wc_stem")</div></div>"
      week_cards_html+="<div><div class=\"wdrill-block\"><h4>Latest handoff</h4><div class=\"handoff\">$(wb_board_v2_handoff_meta "$wc_stem")</div></div><div class=\"wdrill-block\"><h4>Follow-ups</h4>$(wb_board_v2_followups_ul "$wc_stem")</div></div></div></div>"
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
      family_blocks_html+="<div class=\"family-block\"><div class=\"fam-row\"><span class=\"dot ${cw_dot}\"></span><span class=\"row-title\"><span class=\"id mono copyable\" data-copy=\"wb resume $cw_stem\">$cw_stem</span>${cw_title}</span><span class=\"age\">$(wb_board_v2_age_label "${_m_age_days[$cw_stem]:-0}")</span></div><div class=\"fam-kids\">"
      local cw_child cw_pill_cls cw_pill_text
      while IFS= read -r cw_child; do
        [ -n "$cw_child" ] || continue
        case "${_m_status[$cw_child]:-}" in
          planned) cw_pill_cls="planned"; cw_pill_text="planned" ;;
          doing|review) cw_pill_cls="doing"; cw_pill_text="doing" ;;
          *) cw_pill_cls="planned"; cw_pill_text="${_m_status[$cw_child]:-}" ;;
        esac
        family_blocks_html+="<div class=\"fam-kid-row\"><span class=\"title copyable\" data-copy=\"wb resume $cw_child\">$(wb_board_html_escape "${_m_title[$cw_child]:-$cw_child}")</span><span class=\"right\"><span class=\"pill ${cw_pill_cls}\">$(wb_board_html_escape "$cw_pill_text")</span><span class=\"age mono\">$(wb_board_v2_age_label "${_m_age_days[$cw_child]:-0}")</span></span></div>"
      done <<< "$cw_kids"
      family_blocks_html+='</div></div>'
    else
      [ "${_m_bucket[$cw_stem]:-}" = active ] || continue
      [ -n "${THIS_WEEK_SET[$cw_stem]:-}" ] && continue
      carried_standalone_stems+=("$cw_stem")
    fi
  done
  if [ "${#carried_standalone_stems[@]}" -gt 0 ]; then
    local cl_stem cl_dot
    while IFS= read -r cl_stem; do
      cl_dot="$(wb_board_v2_dot_class "${_m_status[$cl_stem]}" "${_m_bucket[$cl_stem]}" "${_m_age_days[$cl_stem]:-0}")"
      carried_list_html+="<div class=\"carried-row\"><span class=\"dot ${cl_dot}\"></span><span class=\"row-title\"><span class=\"id mono copyable\" data-copy=\"wb resume $cl_stem\">$cl_stem</span>$(wb_board_html_escape "${_m_title[$cl_stem]:-$cl_stem}")</span><span class=\"age\">$(wb_board_v2_age_label "${_m_age_days[$cl_stem]:-0}")</span></div>"
    done < <(wb_board_v2_sort_stems_by_age asc "${carried_standalone_stems[@]}")
  fi

  # "Unblocked next" reuses the Roadmap's own ready_planned set (R23: the
  # same readiness computation everywhere, not a second one here); "Shelf"
  # is every status:paused task store-wide.
  local unblocked_chips_html=""
  if [ "${#ready_planned[@]}" -gt 0 ]; then
    local uq_i=0 uq_stem uq_root uq_breadcrumb
    while IFS= read -r uq_stem; do
      uq_i=$((uq_i + 1)); [ "$uq_i" -gt 12 ] && break
      uq_root="${_m_family_root[$uq_stem]:-$uq_stem}"
      uq_breadcrumb="top-level"
      [ "$uq_root" != "$uq_stem" ] && uq_breadcrumb="$(wb_board_html_escape "${_m_title[$uq_root]:-$uq_root}")"
      unblocked_chips_html+="<span class=\"qs-chip planned copyable\" data-copy=\"wb resume $uq_stem\">$(wb_board_html_escape "${_m_title[$uq_stem]:-$uq_stem}") <span class=\"breadcrumb\">&#8618; ${uq_breadcrumb}</span></span>"
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
    local sc_i=0 sc_stem
    while IFS= read -r sc_stem; do
      sc_i=$((sc_i + 1)); [ "$sc_i" -gt 12 ] && break
      shelf_chips_html+="<span class=\"qs-chip shelf copyable\" data-copy=\"wb resume $sc_stem\">$(wb_board_html_escape "${_m_title[$sc_stem]:-$sc_stem}")</span>"
    done < <(wb_board_v2_sort_stems_by_title "${shelf_paused[@]}")
    [ "${#shelf_paused[@]}" -gt 12 ] && shelf_chips_html+="<span class=\"qs-chip shelf\" style=\"opacity:.6;\">+$(( ${#shelf_paused[@]} - 12 )) more</span>"
  fi

  local week_view_html
  week_view_html="<header class=\"week-header\"><h1>Week ${week_num} &middot; ${mon_label}&ndash;${sun_label}</h1><div class=\"summary\"><b class=\"n-active\">${_m_bucket_count[active]:-0} active</b> &middot; <b class=\"n-stale\">${_m_bucket_count[stale]:-0} stale</b> &middot; <b class=\"n-shelved\">${_m_bucket_count[shelved]:-0} shelved</b></div></header>"
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
  local __h="" __h2="" __h3="" __al=""
  local fam_picker_html="" fam_blocks_html="" fam_idx=0 fam_json_entries=""
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
    local fr_kids="${_m_family_children[$fr_stem]}"
    local -a fr_members=("$fr_stem")
    local fr_c
    while IFS= read -r fr_c; do [ -n "$fr_c" ] && fr_members+=("$fr_c"); done <<< "$fr_kids"
    local fr_total=${#fr_members[@]} fr_done=0 fr_m
    for fr_m in "${fr_members[@]}"; do [ "${_m_status[$fr_m]:-}" = done ] && fr_done=$((fr_done + 1)); done

    local fam_sel_cls=""
    [ "$fam_idx" = 1 ] && fam_sel_cls=" selected"
    wb_board_html_escape "${_m_title[$fr_stem]:-$fr_stem}" __h
    fam_picker_html+="<span class=\"fam-chip${fam_sel_cls}\" data-fam=\"${fr_anchor}\" onclick=\"selectFamily('${fr_anchor}')\">${__h} <span class=\"fam-chip-frac mono\">${fr_done}/${fr_total}</span></span>"

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
    local fr_m3 fr_link_line fr_kind fr_label fr_path
    for fr_m3 in "${fr_members[@]}"; do
      while IFS= read -r fr_link_line; do
        [ -n "$fr_link_line" ] || continue
        wb_board_v2_classify_link "$fr_link_line" fr_kind fr_label fr_path
        local fr_dedupe_key="${fr_kind}"$'\x1f'"${fr_path}"
        [ -n "${fr_link_seen[$fr_dedupe_key]:-}" ] && continue
        fr_link_seen["$fr_dedupe_key"]=1
        fr_link_kind+=("$fr_kind"); fr_link_label+=("$fr_label"); fr_link_path+=("$fr_path"); fr_link_source+=("$fr_m3")
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
      fr_json_children+="{\"id\":\"${__h2}\",\"title\":\"${__h}\",\"status\":\"${_m_status[$fr_jc_m]:-}\",\"age_days\":${_m_age_days[$fr_jc_m]:-0},\"is_parent\":$([ "$fr_jc_i" = 0 ] && printf true || printf false)}"
    done
    local fr_json_decisions="" fr_jd_first=1 fr_jd_date fr_jd_text fr_jd_src
    if [ -n "$fr_decisions_full_sorted" ]; then
      while IFS=$'\t' read -r fr_jd_date fr_jd_text fr_jd_src; do
        [ -n "${fr_jd_date:-}" ] || continue
        [ "$fr_jd_first" = 1 ] || fr_json_decisions+=","
        fr_jd_first=0
        wb_board_v2_json_escape "$fr_jd_text" __h
        fr_json_decisions+="{\"date\":\"${fr_jd_date}\",\"text\":\"${__h}\",\"source\":\"${fr_jd_src}\"}"
      done <<< "$fr_decisions_full_sorted"
    fi
    local fr_json_artifacts="" fr_ja_i
    for fr_ja_i in "${!fr_link_kind[@]}"; do
      [ "$fr_ja_i" -gt 0 ] && fr_json_artifacts+=","
      wb_board_v2_json_escape "${fr_link_label[$fr_ja_i]}" __h
      wb_board_v2_json_escape "${fr_link_path[$fr_ja_i]}" __h2
      fr_json_artifacts+="{\"kind\":\"${fr_link_kind[$fr_ja_i]}\",\"label\":\"${__h}\",\"path\":\"${__h2}\",\"source\":\"${fr_link_source[$fr_ja_i]}\"}"
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
        fr_json_rungs+="{\"rung\":\"${__h}\",\"ticket\":\"${__h2}\",\"child\":\"${fr_jr_child}\",\"status\":\"${fr_jr_cls}\"}"
      done <<< "$fr_ladder"
    fi
    wb_board_v2_json_escape "${_m_title[$fr_stem]:-$fr_stem}" __h
    wb_board_v2_json_escape "$fr_stem" __h2
    [ "$fam_idx" -gt 1 ] && fam_json_entries+=","
    fam_json_entries+="{\"root\":\"${__h2}\",\"title\":\"${__h}\",\"shape\":\"$([ -n "$fr_ladder" ] && printf ladder || printf flat)\",\"children\":[${fr_json_children}],\"decisions\":[${fr_json_decisions}],\"artifacts\":[${fr_json_artifacts}],\"rungs\":[${fr_json_rungs}]}"

    if [ -n "$fr_ladder" ]; then
      # ---- LADDER SHAPE (mockup D) ----
      fam_body_html+="<h2 class=\"region-label\">Family &middot; ladder view</h2>"
      wb_board_html_escape "${_m_title[$fr_stem]:-$fr_stem}" __h
      fam_body_html+="<div class=\"fam-title-row\"><div><h1>${__h}</h1><span class=\"fam-id mono copyable\" data-copy=\"wb resume ${fr_stem_h}\">${fr_stem_h}</span></div></div>"
      fam_body_html+='<div class="ladder">'
      local fr_rung_line fr_rung_i=0
      while IFS= read -r fr_rung_line; do
        [ -n "$fr_rung_line" ] || continue
        fr_rung_i=$((fr_rung_i + 1))
        local fr_rung="${fr_rung_line%%$'\t'*}" fr_rest="${fr_rung_line#*$'\t'}"
        local fr_ticket="${fr_rest%%$'\t'*}"; fr_rest="${fr_rest#*$'\t'}"
        local fr_wbtask_cell="${fr_rest%%$'\t'*}" fr_status_cell="${fr_rest#*$'\t'}"
        local fr_child; wb_board_v2_ladder_child_stem "$fr_wbtask_cell" fr_child
        local fr_resolved_status="" fr_rung_child_html='<span class="rung-child none">no child task yet</span>'
        if [ -n "$fr_child" ] && [ -n "${_m_status[$fr_child]:-}" ]; then
          fr_resolved_status="${_m_status[$fr_child]}"
          fr_rung_child_html="<span class=\"rung-child mono copyable\" data-copy=\"wb resume ${fr_child}\">&#8618; <span class=\"id\">${fr_child}</span></span>"
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
            wb_board_html_escape "${fr_link_label[$fr_ra_i]}" __h
            wb_board_html_escape "${fr_link_path[$fr_ra_i]}" __h2
            fam_body_html+="<li><span class=\"artifact-link copyable\" data-copy=\"${__h2}\" title=\"${__h2}\"><span class=\"label\">${__h}</span></span></li>"
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
      fam_body_html+="<h2 class=\"region-label\">Family view</h2>"
      wb_board_html_escape "${_m_title[$fr_stem]:-$fr_stem}" __h
      wb_board_v2_age_label "${_m_age_days[$fr_stem]:-0}" __al
      fam_body_html+="<div class=\"fam-hero\"><div class=\"fam-hero-top\"><div><div class=\"fam-hero-title\">${__h}</div><span class=\"fam-hero-id mono copyable\" data-copy=\"wb resume ${fr_stem_h}\">${fr_stem_h}</span></div><div class=\"fam-hero-meta\"><span class=\"dot ${fr_dot}\"></span><span class=\"age mono\">${__al}</span></div></div>"
      fam_body_html+='<div class="fam-tree">'
      local fr_p_status="${_m_status[$fr_stem]:-}" fr_p_pill_cls="planned"
      case "$fr_p_status" in doing|review) fr_p_pill_cls="doing" ;; esac
      wb_board_html_escape "${_m_title[$fr_stem]:-$fr_stem}" __h
      wb_board_v2_age_label "${_m_age_days[$fr_stem]:-0}" __al
      wb_board_html_escape "$fr_p_status" __h2
      fam_body_html+="<div class=\"fam-tree-row parent-row\"><span class=\"branch\">&#9679;</span><div><div class=\"t-title copyable\" data-copy=\"wb resume ${fr_stem_h}\">${__h}</div><span class=\"t-id mono\">${fr_stem_h} &middot; parent</span></div><span class=\"fam-status-pill ${fr_p_pill_cls}\">${__h2}</span><span class=\"t-age mono\">${__al}</span></div>"
      local fr_child_row
      while IFS= read -r fr_child_row; do
        [ -n "$fr_child_row" ] || continue
        local fr_c_status="${_m_status[$fr_child_row]:-}" fr_c_pill_cls="planned"
        case "$fr_c_status" in doing|review) fr_c_pill_cls="doing" ;; esac
        wb_board_html_escape "${_m_title[$fr_child_row]:-$fr_child_row}" __h
        wb_board_v2_age_label "${_m_age_days[$fr_child_row]:-0}" __al
        wb_board_html_escape "$fr_c_status" __h2
        wb_board_html_escape "$fr_child_row" __h3
        fam_body_html+="<div class=\"fam-tree-row child-row\"><span class=\"branch\">&#9492;</span><div><div class=\"t-title copyable\" data-copy=\"wb resume ${__h3}\">${__h}</div><span class=\"t-id mono\">${__h3}</span></div><span class=\"fam-status-pill ${fr_c_pill_cls}\">${__h2}</span><span class=\"t-age mono\">${__al}</span></div>"
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
          fr_timeline_html+="<div class=\"fam-tl-item ${fr_src_cls}\"><div class=\"fam-tl-date mono\">${__h}</div><div class=\"fam-tl-text\">${__h2}</div><span class=\"fam-tl-source ${fr_src_badge_cls} copyable\" data-copy=\"wb resume ${__h3}\">${__h3}</span></div>"
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
            wb_board_html_escape "${fr_link_path[$fr_gi]}" __h
            wb_board_html_escape "${fr_link_source[$fr_gi]}" __h2
            if [ "$fr_kind_want" = claude-ai ]; then
              fr_group_html+="<div class=\"fam-art-row\"><span class=\"fam-art-icon\">&#128279;</span><a class=\"fam-art-path mono\" href=\"${__h}\" target=\"_blank\" rel=\"noopener\">${__h}</a><span class=\"fam-art-tag\">${__h2}</span></div>"
            else
              # fix(review) P1: data-copy and the visible path text now both
              # use the full path (fr_link_path), not the basename-only
              # fr_link_label — a basename alone can't be opened/found again.
              fr_group_html+="<div class=\"fam-art-row copyable\" data-copy=\"${__h}\"><span class=\"fam-art-icon\">&#128196;</span><span class=\"fam-art-path mono\">${__h}</span><span class=\"fam-art-tag\">${__h2}</span><span class=\"fam-art-grab\">copy</span></div>"
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

    # fix(perf, U5/U6): escape THIS family's body now, per-block, rather
    # than once over the whole concatenated family_view_html at page
    # assembly. wb_board_escape_replacement's `${s//&/\&}` global
    # substitution measured NON-linear in the size of a single call — a
    # 230KB single call over all 32 families' content cost ~0.85s, the
    # SAME aggregate content split into ~32 per-family calls cost ~0.29s,
    # further improving as each family's own size drops (a 21KB single
    # call costs only ~0.018s) — verified during this unit's real-store
    # timing pass. Escaping here (not at the bottom substitution line)
    # means `family_view_html` arrives at the page template ALREADY safe
    # for the `${page_template//@@FAMILY_HTML@@/...}` swap.
    fam_body_html="$(wb_board_escape_replacement "$fam_body_html")"
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
    fam_picker_html="$(wb_board_escape_replacement "$fam_picker_html")"
    family_view_html="<div class=\"fam-picker-row\"><span class=\"fam-picker-label\">Family</span>${fam_picker_html}</div>${fam_blocks_html}"
  else
    # Static text, pre-escaped by hand (no dynamic content to run through
    # wb_board_escape_replacement) — this is the same @@FAMILY_HTML@@ token
    # that skips the escape wrapper below, so any literal `&` here must
    # already be `\&`.
    family_view_html='<h2 class="region-label">Family</h2><p style="color:var(--subtext);">No families yet \&mdash; a family appears once a task has a <span class="mono">parent:</span> field or at least one child.</p>'
  fi
  local fam_tab_badge="${#all_family_roots_sorted[@]}"

  # =========================================================================
  # PAGE ASSEMBLY — heredoc + @@TOKEN@@ substitution, the same templating
  # convention the deleted old renderer used: the
  # CSS/skeleton/script are entirely static (translated from
  # board-reference-final.html, "Mockup O"), so they live directly in the
  # single-quoted heredoc; only the per-render HTML fragments built above
  # are substituted in, each through wb_board_escape_replacement (R16
  # n/a here, but the same substitution-safety concern as the old
  # renderer's own template — a raw `&` in escaped HTML content is a
  # backreference on the RHS of `${var//pat/repl}` otherwise).
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
  .rail { width: 340px; flex: 0 0 340px; display: flex; flex-direction: column; gap: 20px; padding: 8px; }
  .rail-filter { width: 100%; box-sizing: border-box; padding: 7px 10px; border-radius: 8px; border: 1px solid var(--overlay); background: var(--surface); color: var(--text); font-size: 14px; }
  .rail-filter::placeholder { color: var(--subtext); }
  .rail-heading { font-size: 12.5px; letter-spacing: 0.06em; text-transform: uppercase; color: var(--subtext); padding: 0 4px 6px 4px; }
  .rail-tree { display: flex; flex-direction: column; gap: 1px; }

  .rail-row { display: flex; align-items: center; gap: 8px; padding: 7px 10px; border-radius: 8px; border: 1px solid transparent; cursor: pointer; font-size: 15px; }
  .rail-row:hover { background: var(--surface); }
  .filter-hidden { display: none !important; }

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

  .card { flex: 1 1 340px; max-width: 420px; background: var(--surface); border: 1px solid var(--overlay); border-radius: 12px; padding: 18px 18px 16px; display: flex; flex-direction: column; gap: 12px; position: relative; transition: transform .15s ease; cursor: pointer; }
  /* R21: stale renders FULL CONTRAST + red, never desaturated — the
     mockup's own `.card.stale { filter: saturate(.55); }` rule is a
     captured mistake (its own header comment says so), dropped here; a
     tinted border is the only stale-specific treatment. */
  .card.stale { border-color: rgba(243,139,168,.5); }
  .card.selected { border: 1.5px solid var(--mauve); box-shadow: 0 8px 28px -8px rgba(203,166,247,.35), 0 0 0 1px rgba(203,166,247,.08); transform: translateY(-6px); background: linear-gradient(180deg, rgba(203,166,247,.06), var(--surface) 40%); }
  .card.selected .ring-stroke { stroke: var(--mauve) !important; }
  .card-top { display: flex; align-items: flex-start; justify-content: space-between; gap: 10px; }
  .card-title { font-size: 17px; font-weight: 600; color: var(--text); line-height: 1.4; }
  .card-id { display: block; color: var(--subtext); margin-top: 4px; font-size: 13px; }
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
  .rm-lane-label .rm-standalone-meta { display: flex; align-items: center; gap: 6px; margin-top: 4px; font-size: 12.5px; color: var(--subtext); }

  .rm-lane.milestone-lane { position: relative; z-index: 1; }
  .rm-lane.milestone-lane::before { content: ""; position: absolute; inset: -6px -14px; background: rgba(203,166,247,.05); border: 1px solid rgba(203,166,247,.12); border-radius: 12px; z-index: -1; }

  .rm-bracket { grid-row: 1; align-self: end; height: 7px; margin: 0 6px; position: relative; border-top: 1px solid var(--overlay); }
  .rm-bracket::before, .rm-bracket::after { content: ""; position: absolute; top: 0; width: 1px; height: 7px; background: var(--overlay); }
  .rm-bracket::before { left: 0; }
  .rm-bracket::after { right: 0; }

  .rm-bars { grid-row: 2; display: flex; gap: 8px; align-items: center; min-width: 0; position: relative; }
  .rm-bar { height: 28px; border-radius: 8px; display: flex; align-items: center; padding: 0 12px; font-size: 12.5px; white-space: nowrap; overflow: hidden; text-overflow: ellipsis; min-width: 0; position: relative; flex: 1; }
  .rm-bar.active-bar { background: var(--green); color: var(--base); font-weight: 600; }
  .rm-bar.ready-bar { background: transparent; border: 2px solid var(--blue); color: var(--blue); padding-right: 46px; }
  .rm-bar.ready-bar::after { content: "ready"; position: absolute; right: 10px; top: 50%; transform: translateY(-50%); font-family: "SFMono-Regular", Consolas, "Liberation Mono", Menlo, monospace; font-size: 11px; color: var(--blue); opacity: .85; letter-spacing: .02em; }
  .rm-bar.blocked-bar { background: rgba(69,71,90,.55); border: 1px solid var(--overlay); color: var(--subtext); flex-wrap: wrap; height: auto; min-height: 28px; white-space: normal; padding: 6px 12px; row-gap: 2px; }
  .rm-bar .lock-ic { margin-right: 5px; font-size: 11px; }
  .rm-after-tag { flex-basis: 100%; margin-left: 19px; font-size: 11.5px; color: var(--red); white-space: nowrap; opacity: 1; }

  .rm-readiness-strip { display: flex; flex-wrap: wrap; gap: 10px 32px; align-items: center; margin: 2px 0 18px 0; padding: 12px 16px; background: rgba(137,180,250,.04); border: 1px solid var(--overlay); border-radius: 10px; }
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
  .wdrill { display: grid; grid-template-columns: 1.15fr 1fr; gap: 20px 32px; }
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
  .family-block .fam-row .row-title { font-size: 15.5px; color: var(--text); }
  .family-block .fam-row .row-title .id { color: var(--subtext); font-size: 13.5px; margin-right: 8px; }
  .family-block .fam-row .age { color: var(--red); font-size: 14px; }
  .family-block .fam-kids { margin: 2px 0 6px 30px; border-left: 1px solid var(--overlay); padding-left: 16px; display: flex; flex-direction: column; gap: 2px; }
  .fam-kid-row { display: flex; align-items: center; justify-content: space-between; gap: 10px; padding: 6px 8px; border-radius: 6px; }
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
  .fam-picker-row { display: flex; align-items: center; gap: 10px; flex-wrap: wrap; margin-bottom: 22px; }
  .fam-picker-label { font-size: 12.5px; text-transform: uppercase; letter-spacing: .06em; color: var(--subtext); font-weight: 600; margin-right: 2px; }
  .fam-chip { display: inline-flex; align-items: center; gap: 8px; font-size: 14.5px; padding: 7px 14px; border-radius: 999px; border: 1px solid var(--overlay); background: var(--surface); color: var(--subtext); cursor: pointer; white-space: nowrap; }
  .fam-chip:hover { color: var(--text); }
  .fam-chip.selected { border-color: var(--mauve); color: var(--mauve); background: rgba(203,166,247,.12); }
  .fam-chip .fam-chip-frac { font-size: 12.5px; color: var(--subtext); }
  .fam-chip.selected .fam-chip-frac { color: var(--mauve); opacity: .85; }
  .fam-block { display: none; }

  .fam-title-row { display: flex; align-items: baseline; justify-content: space-between; gap: 16px; margin: 2px 2px 20px 2px; flex-wrap: wrap; }
  .fam-title-row h1 { margin: 0; font-size: 25px; font-weight: 650; letter-spacing: -0.01em; color: var(--text); }
  .fam-id, .fam-hero-id { color: var(--subtext); font-size: 13.5px; }

  .fam-hero { background: var(--surface); border: 1px solid var(--overlay); border-radius: 14px; padding: 24px 28px; margin-bottom: 26px; }
  .fam-hero-top { display: flex; align-items: flex-start; justify-content: space-between; gap: 16px; margin-bottom: 18px; }
  .fam-hero-title { font-size: 21px; font-weight: 650; color: var(--text); }
  .fam-hero-id { display: block; margin-top: 5px; }
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

  .fam-art-groups { display: grid; grid-template-columns: 1fr 1fr; gap: 16px; }
  .fam-art-group { background: var(--surface); border: 1px solid var(--overlay); border-radius: 12px; padding: 16px 18px; }
  .fam-art-group h4 { margin: 0 0 10px; font-size: 12px; text-transform: uppercase; letter-spacing: .06em; color: var(--subtext); font-weight: 700; }
  .fam-art-list { display: flex; flex-direction: column; gap: 2px; }
  .fam-art-row { display: flex; align-items: center; gap: 10px; padding: 8px 8px; border-radius: 8px; font-size: 14.5px; color: var(--text); }
  .fam-art-row:hover { background: var(--base); }
  .fam-art-icon { flex: 0 0 auto; font-size: 14px; color: var(--subtext); width: 16px; text-align: center; }
  .fam-art-path { flex: 1; min-width: 0; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; color: var(--text); text-decoration: none; }
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
  .artifact-link { display: flex; align-items: center; gap: 8px; font-size: 14px; color: var(--text); cursor: pointer; }
  .fam-today-tag { display: inline-flex; align-items: center; gap: 6px; font-size: 11px; font-weight: 700; letter-spacing: .09em; text-transform: uppercase; color: var(--mauve); background: rgba(203,166,247,.12); border: 1px solid rgba(203,166,247,.4); padding: 2px 9px; border-radius: 999px; margin-left: 8px; }
</style>
</head>
<body>
<div class="caption">wb board &middot; generated @@GENERATED_TS@@</div>
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
      <div class="deck-row" id="deckRow">
@@DECK_HTML@@
      </div>
@@DRILLDOWNS_HTML@@
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
</div>

<script>
  function toggleGroup(id) { document.getElementById(id).classList.toggle('expanded'); }
  function showView(name) {
    document.querySelectorAll('.view').forEach(function(v){ v.classList.remove('active'); });
    document.getElementById('view-' + name).classList.add('active');
    document.querySelectorAll('.view-tab').forEach(function(t){
      t.classList.toggle('active', t.getAttribute('data-view') === name);
    });
  }
  function toggleStale() {
    document.getElementById('rm-stale-toggle').classList.toggle('open');
    document.getElementById('rm-stale-detail').classList.toggle('open');
  }
  function toggleWeekStale() {
    document.getElementById('wk-stale-toggle').classList.toggle('open');
    document.getElementById('wk-stale-detail').classList.toggle('open');
  }
  function selectFamily(anchor) {
    document.querySelectorAll('.fam-block').forEach(function(b){ b.style.display = 'none'; });
    var b = document.getElementById('fam-' + anchor);
    if (b) b.style.display = 'block';
    document.querySelectorAll('.fam-chip').forEach(function(c){
      c.classList.toggle('selected', c.getAttribute('data-fam') === anchor);
    });
  }
  function toggleRung(id) { document.getElementById(id).classList.toggle('expanded'); }

  document.querySelectorAll('#deckRow .card').forEach(function(c){
    c.addEventListener('click', function(){
      document.querySelectorAll('#deckRow .card').forEach(function(x){ x.classList.remove('selected'); });
      document.querySelectorAll('.drilldown').forEach(function(x){ x.classList.remove('active'); });
      c.classList.add('selected');
      var dd = document.getElementById(c.dataset.drilldown);
      if (dd) dd.classList.add('active');
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

  // UX-review mandate: 1/2/3 view switch, j/k card nav, `/` filter focus.
  document.addEventListener('keydown', function(e){
    if (e.target && e.target.id === 'board-filter') {
      if (e.key === 'Escape') { e.target.value = ''; filterBoard(''); e.target.blur(); }
      return;
    }
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
    if (e.key === 'j' || e.key === 'k') {
      var cards = Array.prototype.slice.call(document.querySelectorAll('#deckRow .card'));
      if (!cards.length) return;
      var idx = cards.findIndex(function(c){ return c.classList.contains('selected'); });
      if (idx === -1) idx = 0;
      idx = e.key === 'j' ? Math.min(idx + 1, cards.length - 1) : Math.max(idx - 1, 0);
      cards[idx].click();
      cards[idx].scrollIntoView({block: 'nearest'});
    }
  });

  function filterBoard(q) {
    q = q.toLowerCase();
    document.querySelectorAll('.rail > div > .rail-tree > .rail-row, .rail > div > .rail-tree > details.family-node').forEach(function(el){
      var t = (el.querySelector('.rail-row-title') || el).textContent.toLowerCase();
      el.classList.toggle('filter-hidden', q.length > 0 && t.indexOf(q) === -1);
    });
    document.querySelectorAll('#deckRow .card').forEach(function(el){
      var t = (el.querySelector('.card-title') || el).textContent.toLowerCase();
      el.classList.toggle('filter-hidden', q.length > 0 && t.indexOf(q) === -1);
    });
  }
  (function(){
    var f = document.getElementById('board-filter');
    if (f) f.addEventListener('input', function(){ filterBoard(f.value); });
  })();
</script>
</body>
</html>
HTMLEOF
)"
  page_template="${page_template//@@RAIL_HTML@@/$(wb_board_escape_replacement "$rail_html")}"
  page_template="${page_template//@@DECK_HTML@@/$(wb_board_escape_replacement "$deck_html")}"
  page_template="${page_template//@@DRILLDOWNS_HTML@@/$(wb_board_escape_replacement "$drilldowns_html")}"
  page_template="${page_template//@@ROADMAP_HTML@@/$(wb_board_escape_replacement "$roadmap_view_html")}"
  page_template="${page_template//@@WEEK_HTML@@/$(wb_board_escape_replacement "$week_view_html")}"
  page_template="${page_template//@@FAMILY_HTML@@/$family_view_html}"   # already escaped per-family above (perf)
  page_template="${page_template//@@TAB_BADGE@@/$(wb_board_escape_replacement "$tab_badge")}"
  page_template="${page_template//@@FAM_TAB_BADGE@@/$(wb_board_escape_replacement "$fam_tab_badge")}"
  page_template="${page_template//@@GENERATED_TS@@/$(wb_board_escape_replacement "$generated_ts")}"
  printf '%s\n' "$page_template"
}
