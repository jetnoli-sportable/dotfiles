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
wb_board_bucket_for_status() {
  case "$1" in
    doing|review) echo inprogress ;;
    planned)      echo upcoming ;;
    paused)       echo paused ;;
    prospective)  echo prospective ;;
    done)         echo done ;;
    *)            echo unclassified ;;
  esac
}

# wb_board_anchor_slug <string> — sanitize into a safe HTML id fragment.
wb_board_anchor_slug() { printf '%s' "$1" | tr -c 'A-Za-z0-9_-' '-'; }

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

# wb_board_window_start <today|week> — epoch seconds for the timeline
# window's start.
wb_board_window_start() {
  case "$1" in
    week) date -d '7 days ago 00:00:00' +%s ;;
    *)    date -d 'today 00:00:00' +%s ;;
  esac
}

# wb_board_in_window <created> <closed> <updated_epoch> <window_start> —
# true if created, updated, OR closed falls within the window (R10) — a
# broader check than the old closed-only rule, applied uniformly to every
# tab, not just a default view.
wb_board_in_window() {
  local created="$1" closed="$2" updated="$3" start="$4" e
  if [ -n "$created" ]; then
    e="$(date -d "$created" +%s 2>/dev/null || echo 0)"
    [ "$e" -ge "$start" ] && return 0
  fi
  if [ -n "$closed" ]; then
    e="$(date -d "$closed" +%s 2>/dev/null || echo 0)"
    [ "$e" -ge "$start" ] && return 0
  fi
  [ "${updated:-0}" -ge "$start" ] && return 0
  return 1
}

# wb_board_collect_rows — one TSV line per row, task-store tasks first, then
# untracked worktrees (R9). Fields:
#   1 kind (task|untracked)   2 bucket   3 status (raw, empty for untracked)
#   4 repo   5 branch   6 worktree (relative)   7 title
#   8 created   9 closed   10 updated (mtime, epoch)   11 taskfile (or empty)
#   12 anchor_key (unique, sanitized — view-scoped prefixes are added at
#      render time since the same row gets a different id per visible tab)
#   13 path (raw path: field, task rows only)   14 depends_on (raw field)
#   15 reviewed (raw field) — board-display-v2's U4 pre-pass consumes these
#      three without a second per-field wb_get_frontmatter read per task.
wb_board_collect_rows() {
  local f status repo worktree branch title created closed updated anchor
  local -a t
  while IFS= read -r f; do
    [ -f "$f" ] || continue
    wb_tsv_split "$(wb_read_task "$f")" t
    status="${t[0]:-}"; repo="${t[1]:-}"; worktree="${t[2]:-}"; branch="${t[3]:-}"
    local path="${t[4]:-}" deps="${t[5]:-}" reviewed="${t[6]:-}"
    title="$(wb_task_title "$f")"; [ -n "$title" ] || title="$(basename "$f" .md)"
    created="$(wb_get_frontmatter "$f" created)"
    closed="$(wb_get_frontmatter "$f" closed)"
    updated="$(stat -c %Y "$f" 2>/dev/null || echo 0)"
    anchor="$(wb_board_anchor_slug "$(basename "$f" .md)")"
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
      "task" "$(wb_board_bucket_for_status "$status")" "$status" "$repo" \
      "$branch" "$worktree" "$title" "$created" "$closed" "$updated" "$f" "$anchor" \
      "$path" "$deps" "$reviewed"
  done < <(wb_task_files)

  local repo_dir r_branch abs_path rel
  while IFS= read -r repo_dir; do
    [ -d "$repo_dir/.git" ] || continue
    repo="$(basename "$repo_dir")"
    while IFS=$'\t' read -r r_branch abs_path; do
      [ -n "$abs_path" ] || continue
      rel="${abs_path#"$repo_dir"/}"
      wb_worktree_has_task "$repo" "$rel" && continue
      updated="$(stat -c %Y "$abs_path" 2>/dev/null || echo 0)"
      anchor="$(wb_board_anchor_slug "untracked-${repo}--${r_branch}")"
      printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
        "untracked" "unclassified" "" "$repo" "$r_branch" "$rel" "$r_branch" \
        "" "" "$updated" "" "$anchor" "" "" ""
    done < <(wb_repo_worktrees "$repo_dir")
  done < <(wb_reconcile_repos)
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
  printf '%s' "$s"
}

# wb_board_section <file> <heading> — body lines under "## <heading>" up to
# the next "## " heading (or EOF). Same convention wb_sweep_section already
# uses for the "## Sweep" section, generalized to any named section.
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
  local line
  while IFS= read -r line; do
    if [ -n "${line//[[:space:]]/}" ]; then
      printf '%s' "$line"
      return 0
    fi
  done <<< "$1"
}

# wb_board_capture_matches <repo> <branch> — unreviewed weekly-capture-doc
# entries (U1) stamped with this repo/branch, one raw "- [ ] ..." line per
# line. Replaces the retired /park ledger's wb_board_ledger_matches (U8):
# `wb week append` stamps each entry with { date, repo, branch } — the
# same fields the ledger used to carry, just as capture-doc prose instead
# of a JSON cwd path.
wb_board_capture_matches() {
  local repo="$1" branch="$2" path
  path="$(_wb_week_capture_path)"
  [ -n "$repo" ] && [ -n "$branch" ] && [ -f "$path" ] || return 0
  grep -F "· $repo/$branch ·" "$path" 2>/dev/null | grep '^- \[ \] '
}

# wb_board_pr_info <repo_dir> <branch> — "#<number> (<state>)\t<url>" for
# the most recent PR on <branch>, any state (open/closed/merged) — a
# display nicety for a task's detail section, not a drift signal, so unlike
# wb_pr_merge_status this silently returns empty on any gh/pgh failure
# rather than reporting "unknown". The tab-joined URL (board-display-v2's
# U4/KTD-1) lets work-stage cells and the Pipeline PR column link straight
# to the PR without a second `gh` call — use wb_board_pr_display/
# wb_board_pr_url to pull either half back out; wb_lifecycle_pr_is_live
# already only inspects the display half.
wb_board_pr_info() {
  local repo_dir="$1" branch="$2" out rc
  out="$(cd "$repo_dir" && gh pr list --head "$branch" --state all --json number,state,url 2>&1)"; rc=$?
  if [ "$rc" -ne 0 ] && printf '%s' "$out" | grep -qi 'could not resolve to a repository'; then
    out="$(cd "$repo_dir" && GH_TOKEN="$(secret-tool lookup service gh account personal 2>/dev/null)" gh pr list --head "$branch" --state all --json number,state,url 2>&1)"; rc=$?
  fi
  [ "$rc" -eq 0 ] || return 0
  printf '%s' "$out" | jq -r '.[0] // empty | "#\(.number) (\(.state))\t\(.url)"' 2>/dev/null
}

# wb_board_pr_display <pr_info> — the "#<n> (<state>)" half of a
# wb_board_pr_info string (safe to call on an untabbed legacy-shaped string
# too — a stub or test fixture that doesn't bother with the URL half).
wb_board_pr_display() { printf '%s' "${1%%$'\t'*}"; }

# wb_board_pr_url <pr_info> — the URL half of a wb_board_pr_info string, or
# empty when there's no tab (no PR, or a display-only stub).
wb_board_pr_url() {
  case "$1" in
    *$'\t'*) printf '%s' "${1#*$'\t'}" ;;
    *)       printf '' ;;
  esac
}

# wb_board_summary_line <status> <repo> <branch> <created> <closed> — an
# always-present, plain-language orientation sentence for a task's detail
# card. Deliberately just restating the structured frontmatter facts, not
# summarizing Plan/Done prose — that would need an LLM call at generation
# time, well beyond what a bash-generated static page should do. Plan/Done
# excerpts (when present) still render as their own, richer lines below
# this one; this exists so a task with neither isn't a near-empty card.
wb_board_summary_line() {
  local status="$1" repo="$2" branch="$3" created="$4" closed="$5" s
  s="A <code>$status</code> task in <code>$repo</code>, branch <code>$branch</code>"
  [ -n "$created" ] && s+=", created $created"
  [ -n "$closed" ] && s+=", closed $closed"
  printf '%s.' "$s"
}

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

# wb_board_related_docs <taskfile> <dotfiles_root> — wb_board_doc_candidates,
# filtered to paths that exist under <root> and preferring the rendered
# .html sibling over its .md source when both exist (nicer to open from a
# browser); a reference to a since-deleted file is dropped rather than
# linked dead.
wb_board_related_docs() {
  local taskfile="$1" root="$2" rel html_sibling
  wb_board_doc_candidates "$taskfile" | while IFS= read -r rel; do
      [ -f "$root/$rel" ] || continue
      case "$rel" in
        *.md)
          html_sibling="${rel%.md}.html"
          if [ -f "$root/$html_sibling" ]; then printf '%s\n' "$html_sibling"; else printf '%s\n' "$rel"; fi
          ;;
        *) printf '%s\n' "$rel" ;;
      esac
    done | sort -u
  # grep exits 1 (no lines matched) for the common case of a task file with
  # no docs/plans|brainstorms|solutions or logs/decisions reference at all;
  # under set -o pipefail that becomes THIS function's exit status even
  # though every later pipeline stage succeeds on the empty input, and the
  # bare (non-`local`) `own_docs="$(wb_board_related_docs ...)"` call site
  # does not mask it -- so under set -e that silently aborted the entire
  # `wb board --html` render with no output for any such task.
  return 0
}

# wb_board_task_doc_chips <taskfile> <dotfiles_root> — space-joined
# artefact-chip <a> tags for every doc wb_board_related_docs finds for
# <taskfile>, escaped and linked exactly like a task's own "Docs:" line.
# Shared by that line, each child row, and (via wb_board_children_rollup_docs)
# the rolled-up union, so the chip markup lives in exactly one place.
wb_board_task_doc_chips() {
  local taskfile="$1" root="$2" doc_rel chips=""
  while IFS= read -r doc_rel; do
    [ -n "$doc_rel" ] || continue
    chips+="<a class=\"artefact-chip\" href=\"$(wb_board_doc_link "$doc_rel")\">$(wb_board_html_escape "$(basename "$doc_rel")")</a> "
  done < <(wb_board_related_docs "$taskfile" "$root")
  printf '%s' "$chips"
}

# wb_board_children_rollup_docs <children_files_newline_list> <root> —
# deduplicated union of wb_board_related_docs across every child file.
wb_board_children_rollup_docs() {
  local list="$1" root="$2" cf
  while IFS= read -r cf; do
    [ -n "$cf" ] || continue
    wb_board_related_docs "$cf" "$root"
  done <<< "$list" | sort -u
}

# wb_board_doc_link <root_relative_path> — that path's href from
# logs/board.html's own location, since board.html isn't served over
# http and an absolute href would resolve against the filesystem root,
# not the repo root.
wb_board_doc_link() {
  case "$1" in
    logs/*) printf '%s' "${1#logs/}" ;;
    *)      printf '../%s' "$1" ;;
  esac
}

# wb_board_stage_key <anchor_key> <stage> — the STAGE_STATE lookup key
# (board-display-v2's U4 pre-pass, KTD-1) — a single shared constructor so
# writers and readers never drift on the delimiter.
wb_board_stage_key() { printf '%s\x1e%s' "$1" "$2"; }

# wb_board_parse_deps <depends_on_raw> — comma-separated blocker stems, one
# per line, whitespace-tolerant, empty entries dropped, duplicates dropped
# (mirrors wb_lifecycle_parse_path's dedup — a repeated stem must not
# double-count the ⛔/→ dependency chips). Render-tolerant like path:
# parsing — a hand-edited depends_on: must never crash the render; an
# unresolvable stem is the caller's problem (R18 fail-open), not this
# parser's.
wb_board_parse_deps() {
  local raw="${1:-}" tok
  [ -n "$raw" ] || return 0
  local -a tokens
  IFS=',' read -ra tokens <<< "$raw"
  local -A seen=()
  for tok in "${tokens[@]}"; do
    tok="${tok#"${tok%%[![:space:]]*}"}"; tok="${tok%"${tok##*[![:space:]]}"}"
    if [ -n "$tok" ] && [ -z "${seen[$tok]:-}" ]; then
      seen["$tok"]=1
      printf '%s\n' "$tok"
    fi
  done
  return 0
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

# wb_board_stage_glyph <state> — the four-state glyph (R1), n/a rendered
# as the faint middle-dot per the approved mockup's legend.
wb_board_stage_glyph() {
  case "$1" in
    done)     printf '&#10003;' ;;   # check
    progress) printf '&#9679;'  ;;   # solid circle — active (discrete state, not a fill gauge)
    pending)  printf '&#9675;'  ;;   # open circle
    *)        printf '&#183;'  ;;    # na — faint middle dot
  esac
}

# wb_board_stage_doc_kind <stage> — maps a board-display stage name to the
# directory/kind identifier wb_lifecycle_has_doc's family of functions use
# — these DON'T all match 1:1 (ideate's directory is docs/ideation/, not
# docs/ideate/; brainstorm/plan keep their plural directory names).
# wb_lifecycle_stage_state sidesteps this by dispatching to the specific
# wb_lifecycle_has_plan/_brainstorm/_ideate wrapper for each stage; the
# display layer needs the mapping explicitly since it calls the shared
# wb_lifecycle_doc_dirs_for_kind/_doc_qualifies helpers directly. Only
# called for the three doc stages — work/review have no doc directory.
wb_board_stage_doc_kind() {
  case "$1" in
    ideate)     printf 'ideation' ;;
    brainstorm) printf 'brainstorms' ;;
    plan)       printf 'plans' ;;
  esac
}

# wb_board_stage_doc_candidates <repo> <branch> <worktree_rel> <taskfile>
#   <stage> — every worktree-relative doc path currently on disk backing a
# DOC stage (ideate/brainstorm/plan), sorted, one per line — empty when
# there's no live worktree (a kept-branch-only match has nothing to link,
# KTD-5) or nothing matches. Mirrors wb_lifecycle_has_doc's own directory/
# candidate/discriminator logic but collects every match instead of
# stopping at the first (R14 — the card lists all matched docs per stage).
wb_board_stage_doc_candidates() {
  local repo="$1" branch="${2:-}" worktree="${3:-}" taskfile="$4" stage="$5"
  [ -n "$branch" ] && [ -n "$worktree" ] || return 0
  local repo_dir; repo_dir="$(wb_repo_dir "$repo")"
  local wt="$repo_dir/$worktree"
  local live=1
  [ -d "$wt" ] || live=0
  if [ "$live" = 0 ]; then
    git -C "$repo_dir" cat-file -e "$branch" 2>/dev/null || return 0
  fi

  local kind; kind="$(wb_board_stage_doc_kind "$stage")"
  local frag; frag="$(wb_sanitize "$branch")"
  local -a candidates=()
  local dir f readiness source candidate content

  while IFS= read -r dir; do
    [ -n "$dir" ] || continue
    if [ "$live" = 1 ]; then
      if [ -d "$wt/docs/$dir" ]; then
        for f in "$wt/docs/$dir"/*.md "$wt/docs/$dir"/*.html; do
          [ -f "$f" ] || continue
          case "$(basename "$f")" in
            *"$frag"*)
              if [ "$dir" = plans ]; then
                readiness="$(wb_get_frontmatter "$f" artifact_readiness)"
                source="$(wb_get_frontmatter "$f" product_contract_source)"
                wb_lifecycle_doc_qualifies "$kind" "$readiness" "$source" || continue
              fi
              candidates+=("docs/$dir/$(basename "$f")")
              ;;
          esac
        done
      fi
    else
      while IFS= read -r candidate; do
        [ -n "$candidate" ] || continue
        case "$(basename "$candidate")" in
          *"$frag"*)
            if [ "$dir" = plans ]; then
              content="$(git -C "$repo_dir" show "$branch:$candidate" 2>/dev/null)"
              readiness="$(printf '%s\n' "$content" | wb_get_frontmatter_text artifact_readiness)"
              source="$(printf '%s\n' "$content" | wb_get_frontmatter_text product_contract_source)"
              wb_lifecycle_doc_qualifies "$kind" "$readiness" "$source" || continue
            fi
            candidates+=("$candidate")
            ;;
        esac
      done < <(git -C "$repo_dir" ls-tree -r --name-only "$branch" -- "docs/$dir" 2>/dev/null)
    fi

    while IFS= read -r candidate; do
      [ -n "$candidate" ] || continue
      case "$candidate" in "docs/$dir/"*) : ;; *) continue ;; esac
      if [ "$live" = 1 ]; then
        [ -f "$wt/$candidate" ] || continue
        if [ "$dir" = plans ]; then
          readiness="$(wb_get_frontmatter "$wt/$candidate" artifact_readiness)"
          source="$(wb_get_frontmatter "$wt/$candidate" product_contract_source)"
          wb_lifecycle_doc_qualifies "$kind" "$readiness" "$source" || continue
        fi
      else
        git -C "$repo_dir" cat-file -e "$branch:$candidate" 2>/dev/null || continue
        if [ "$dir" = plans ]; then
          content="$(git -C "$repo_dir" show "$branch:$candidate" 2>/dev/null)"
          readiness="$(printf '%s\n' "$content" | wb_get_frontmatter_text artifact_readiness)"
          source="$(printf '%s\n' "$content" | wb_get_frontmatter_text product_contract_source)"
          wb_lifecycle_doc_qualifies "$kind" "$readiness" "$source" || continue
        fi
      fi
      candidates+=("$candidate")
    done < <(wb_board_doc_candidates "$taskfile")
  done < <(wb_lifecycle_doc_dirs_for_kind "$kind")

  [ "${#candidates[@]}" -gt 0 ] || return 0
  printf '%s\n' "${candidates[@]}" | sort -u
}

# wb_board_stage_doc_path <repo> <branch> <worktree_rel> <taskfile> <stage>
# — the lexically newest (R14) of wb_board_stage_doc_candidates' matches,
# for stepper/stage-cell link targets (only one link per segment).
wb_board_stage_doc_path() {
  wb_board_stage_doc_candidates "$@" | tail -1
}

# wb_board_stage_link_href <repo_dir> <worktree_rel> <candidate_relpath> —
# KTD-5's link precedence: the dotfiles-root-relative form (via
# wb_board_doc_link, reads $dotfiles_root from the caller's scope) when
# the doc happens to exist there (true for dotfiles' own tasks, or any
# already-merged doc); empty otherwise.
#
# B5: a doc that exists ONLY inside the task's own worktree is deliberately
# NOT linked. It used to emit file://$repo_dir/$worktree_rel/$candidate — a
# volatile absolute path that 404s the moment `wb done` removes the worktree
# and leaks $HOME into the page. Returning empty makes every caller fall back
# to a non-navigating glyph/chip whose tooltip still names the doc, which is
# honest (the link would rot) rather than a link that silently breaks.
wb_board_stage_link_href() {
  local repo_dir="$1" worktree_rel="$2" candidate="$3"
  [ -n "$candidate" ] || return 0
  if [ -f "$dotfiles_root/$candidate" ]; then
    wb_board_doc_link "$candidate"
    return 0
  fi
  return 0
}

# wb_board_pr_number <pr_info> — just "#N" from a wb_board_pr_info string
# ("#N (STATE)\turl"), for compact PR-column display.
wb_board_pr_number() {
  local d; d="$(wb_board_pr_display "$1")"
  printf '%s' "${d%% *}"
}

# wb_board_stage_render_info <stage> <state> <repo> <branch> <worktree_rel>
#   <taskfile> <pr_info> — prints "glyph\thref\ttooltip" (href empty when
# unlinked). KTD-5's link precedence in exactly one place, shared by the
# Pipeline table cell (wb_board_stage_cell) and (U6) the card stepper
# segment (wb_board_stepper_html): work links to the PR url; doc stages
# link to the newest matching doc when it's on disk; review's tooltip
# carries the reviewed: date. A kept-branch-only doc match (nothing to
# link) falls back to a tooltip naming the doc instead.
wb_board_stage_render_info() {
  local stage="$1" state="$2" repo="$3" branch="$4" worktree="$5" taskfile="$6" pr_info="$7"
  local glyph; glyph="$(wb_board_stage_glyph "$state")"
  local href="" tooltip="$stage: $state"
  case "$stage" in
    work)
      [ -n "$pr_info" ] && href="$(wb_board_pr_url "$pr_info")"
      ;;
    review)
      local reviewed_date; reviewed_date="$(wb_get_frontmatter "$taskfile" reviewed)"
      [ -n "$reviewed_date" ] && tooltip="review: $state (reviewed $reviewed_date)"
      ;;
    *)
      if [ "$state" = done ] || [ "$state" = progress ]; then
        local candidate; candidate="$(wb_board_stage_doc_path "$repo" "$branch" "$worktree" "$taskfile" "$stage")"
        if [ -n "$candidate" ]; then
          href="$(wb_board_stage_link_href "$(wb_repo_dir "$repo")" "$worktree" "$candidate")"
          [ -n "$href" ] || tooltip="$stage: $state ($candidate)"
        fi
      fi
      ;;
  esac
  printf '%s\t%s\t%s' "$glyph" "$href" "$tooltip"
}

# wb_board_stage_cell <stage> <state> <repo> <branch> <worktree_rel>
#   <taskfile> <pr_info> — one <td> for the Pipeline table (R9/R11): the
# state glyph, linked when wb_board_stage_render_info found an artifact,
# otherwise just a title= tooltip.
wb_board_stage_cell() {
  local state="$2"
  local -a info
  wb_tsv_split "$(wb_board_stage_render_info "$@")" info
  local glyph="${info[0]:-}" href="${info[1]:-}" tooltip="${info[2]:-}"
  if [ -n "$href" ]; then
    printf '<td class="stage-cell %s"><a href="%s" title="%s">%s</a></td>' \
      "$state" "$(wb_board_html_escape "$href")" "$(wb_board_html_escape "$tooltip")" "$glyph"
  else
    printf '<td class="stage-cell %s" title="%s">%s</td>' "$state" "$(wb_board_html_escape "$tooltip")" "$glyph"
  fi
}

# wb_board_stepper_html <repo> <branch> <worktree_rel> <taskfile>
#   <anchor_key> <pr_info> [compact] — the stepper for one task's detail
# card (R13), in canonical stage order, skipping any stage whose state is
# n/a (STAGE_STATE already folds R4's upgrade rule in, so a fired-but-
# undeclared stage still appears — "only path/fired stages render" is
# exactly "state != na"). Each segment is glyph-over-label; a DOC stage
# also lists every matched doc as an artifact chip below it (R14 — the
# glyph itself links only the lexically newest, via
# wb_board_stage_render_info). [compact]=1 renders the child-row mini-
# stepper instead (glyph + label only, no links/chips) — same per-child
# summary the approved mockup's parent group card shows.
wb_board_stepper_html() {
  local repo="$1" branch="$2" worktree="$3" taskfile="$4" anchor_key="$5" pr_info="$6" compact="${7:-0}"
  local out="" stage state
  for stage in "${WB_LIFECYCLE_STAGES[@]}"; do
    state="${STAGE_STATE["$(wb_board_stage_key "$anchor_key" "$stage")"]:-na}"
    [ "$state" = na ] && continue
    local label; label="$(tr '[:lower:]' '[:upper:]' <<< "${stage:0:1}")${stage:1}"

    if [ "$compact" = 1 ]; then
      out+="<span class=\"mini-step $state\" title=\"$(wb_board_html_escape "$stage: $state")\">$(wb_board_stage_glyph "$state") $label</span>"
      continue
    fi

    local -a info
    wb_tsv_split "$(wb_board_stage_render_info "$stage" "$state" "$repo" "$branch" "$worktree" "$taskfile" "$pr_info")" info
    local glyph="${info[0]:-}" href="${info[1]:-}" tooltip="${info[2]:-}"
    local seg_glyph="$glyph"
    [ -n "$href" ] && seg_glyph="<a href=\"$(wb_board_html_escape "$href")\">$glyph</a>"

    local chips=""
    if [ "$stage" != work ] && [ "$stage" != review ] && { [ "$state" = done ] || [ "$state" = progress ]; }; then
      local cand chip_href
      while IFS= read -r cand; do
        [ -n "$cand" ] || continue
        chip_href="$(wb_board_stage_link_href "$(wb_repo_dir "$repo")" "$worktree" "$cand")"
        if [ -n "$chip_href" ]; then
          chips+="<a class=\"artefact-chip\" href=\"$(wb_board_html_escape "$chip_href")\">$(wb_board_html_escape "$(basename "$cand")")</a> "
        else
          chips+="<span class=\"artefact-chip\" title=\"$(wb_board_html_escape "$cand — worktree-local, not linked (would rot on wb done)")\">$(wb_board_html_escape "$(basename "$cand")")</span> "
        fi
      done < <(wb_board_stage_doc_candidates "$repo" "$branch" "$worktree" "$taskfile" "$stage")
    fi

    out+="<div class=\"step $state\" title=\"$(wb_board_html_escape "$tooltip")\"><span class=\"glyph\">$seg_glyph</span><span class=\"label\">$label</span>"
    [ -n "$chips" ] && out+="<div class=\"step-chips\">$chips</div>"
    out+="</div>"
  done
  printf '%s' "$out"
}

# wb_board_deps_chips <anchor_key> — the ⛔/→/warning chip markup for one
# task's dependency relationships (KTD-6), shared by the Pipeline Deps
# column and (U6) card chips. Empty output means "no deps at all" — the
# caller renders its own dash, since panels use different dash markup.
# A cycle or dangling-stem warning takes precedence over the plain ⛔
# blocked chip (KTD-6) — the pre-pass never sets UNMET_COUNT for a cycle
# member in the first place, but dangling still needs the explicit branch
# since a dangling depends_on: can coexist with an otherwise-fine graph.
wb_board_deps_chips() {
  local anchor_key="$1" out=""
  if [ -n "${CYCLE_WARN["$anchor_key"]:-}" ]; then
    out+="<span class=\"dep-chip warn\" title=\"$(wb_board_html_escape "${CYCLE_WARN["$anchor_key"]}")\">&#9888; cycle</span> "
  elif [ -n "${DANGLING_WARN["$anchor_key"]:-}" ]; then
    out+="<span class=\"dep-chip warn\" title=\"$(wb_board_html_escape "${DANGLING_WARN["$anchor_key"]}")\">&#9888; unresolved</span> "
  elif [ -n "${UNMET_COUNT["$anchor_key"]:-}" ]; then
    out+="<span class=\"dep-chip blocked\" title=\"$(wb_board_html_escape "${BLOCKER_NAMES["$anchor_key"]}")\">&#9940; ${UNMET_COUNT["$anchor_key"]}</span> "
  fi
  if [ -n "${UNBLOCKS_COUNT["$anchor_key"]:-}" ]; then
    out+="<span class=\"dep-chip unblocks\" title=\"$(wb_board_html_escape "${UNBLOCKS_NAMES["$anchor_key"]}")\">&#8594; ${UNBLOCKS_COUNT["$anchor_key"]}</span>"
  fi
  printf '%s' "$out"
}

# WB_REVIEW_CONVENTION_DATE (KTD-11, R22, R24) — the date the R23/R24
# review-stamp convention commit landed. Scopes the Key Findings
# "done-but-unreviewed" count: the nine pre-convention done tasks are
# grandfathered (never counted), so this is a literal constant, not
# derived at render time — there is no other way to tell "the R23/R24
# convention commit" apart from any other commit.
WB_REVIEW_CONVENTION_DATE="2026-07-12"

# wb_board_kf_link <anchor_key> <bucket> — the href fragment for a Key
# Findings insight's task link (KTD-7): the Pipeline-panel copy for any
# in-flight (non-done) task — always reachable, Pipeline is window-
# independent and unconditional for bucket != done; the All/Week copy for
# a done task, but ONLY when that task actually rendered there (a done
# task outside the week window renders in no reachable panel at all).
# Empty return means "no reachable anchor" — the caller renders plain
# text instead of a dead link (a generation-time existence check, since
# the render already knows every anchor it emitted).
wb_board_kf_link() {
  local ak="$1" bk="$2"
  if [ "$bk" != done ]; then
    printf '#t-pipeline-%s' "$ak"
  elif [ -n "${ALL_WEEK_RENDERED["$ak"]:-}" ]; then
    printf '#t-all-week-%s' "$ak"
  fi
}

# wb_board_render_detail_card — the one <div class="task-detail"> card
# renderer, shared by every panel that needs one: the bucket panels' per-
# window loop in wb_board_render_html below, and (board-display-v2's U5)
# the window-independent Pipeline panel — so a later card-markup change
# (U6's two-zone/stepper rework) only needs editing in this one place, and
# the Pipeline panel picks it up automatically with no second pass.
#
# Deliberately takes NO parameters: every call site is a loop iteration
# inside wb_board_render_html using the exact same local-variable names
# for the current row (kind, status, repo, branch, worktree, title,
# created, closed, taskfile, anchor_key, esc_title, esc_branch, esc_repo,
# pill_class, pill_label, live_badge, view_anchor) — bash resolves them via
# normal (dynamic) scoping from the calling function's own locals, the same
# mechanism wb_tsv_split's array-name parameter relies on, just without
# needing an explicit nameref for plain scalars.
wb_board_render_detail_card() {
  # U7: data-repo/data-family (R26/R28) — read from the U4 pre-pass,
  # keyed by this row's own anchor_key.
  local card_repo_attr="${ANCHOR_REPO["$anchor_key"]:-}"
  local card_family_attr="${ANCHOR_FAMILY["$anchor_key"]:-}"
  local card_attrs=" data-repo=\"$card_repo_attr\""
  [ -n "$card_family_attr" ] && card_attrs+=" data-family=\"$card_family_attr\""

  if [ "$kind" = untracked ]; then
    printf '<div class="task-detail untracked"%s id="%s"><h3>%s <span class="pill unclassified">unclassified</span>%s<a class="back" href="#row-%s">&#8593; back</a></h3><span class="repo">%s</span><p><b>No task file.</b> Worktree exists on disk (<code>%s</code>) with no matching entry in the task store.</p></div>\n' \
      "$card_attrs" "$view_anchor" "$esc_branch" "$live_badge" "$view_anchor" "$esc_repo" "$(wb_board_html_escape "$worktree")"
    return
  fi

  local plan done_txt pr_info detail_extra=""
  detail_extra+="<p>$(wb_board_summary_line "$status" "$esc_repo" "$esc_branch" "$created" "$closed")</p>"
  plan="$(wb_board_first_nonblank_line "$(wb_board_section "$taskfile" Plan)")"
  done_txt="$(wb_board_first_nonblank_line "$(wb_board_section "$taskfile" Done)")"
  [ -n "$plan" ] && detail_extra+="<p><b>Plan:</b> $(wb_board_html_escape "$plan")</p>"
  [ -n "$done_txt" ] && detail_extra+="<p><b>Done:</b> $(wb_board_html_escape "$done_txt")</p>"
  pr_info="${PR_INFO["$anchor_key"]:-}"
  local capture_line capture_note=""
  while IFS= read -r capture_line; do
    [ -n "$capture_line" ] || continue
    capture_note+="$(printf '%s' "$capture_line" | sed -E 's/^- \[ \] [0-9]{4}-[0-9]{2}-[0-9]{2} · [^·]+ · //'); "
  done < <(wb_board_capture_matches "$repo" "$branch")
  [ -n "$capture_note" ] && detail_extra+="<p><b>Captured:</b> $(wb_board_html_escape "$capture_note")</p>"
  local own_docs doc_links
  own_docs="$(wb_board_related_docs "$taskfile" "$dotfiles_root")"
  doc_links="$(wb_board_task_doc_chips "$taskfile" "$dotfiles_root")"
  [ -n "$doc_links" ] && detail_extra+="<p><b>Docs:</b> $doc_links</p>"

  # --- U6: two-zone head — identity left, lane-meta (agent/worktree/PR)
  # top-right — replacing the old single-line <h3> for every card, done
  # tasks included (R13: the superseded lifecycle-plan's done-bucket
  # skip must not carry forward). --------------------------------------
  local wt_glyph=""
  wb_lifecycle_has_worktree "$repo" "$worktree" && wt_glyph="<span class=\"wt-indicator\" title=\"worktree present\">&#8962;</span>"
  local pr_chip=""
  [ -n "$pr_info" ] && pr_chip="<a class=\"artefact-chip pr-chip\" href=\"$(wb_board_html_escape "$(wb_board_pr_url "$pr_info")")\">PR $(wb_board_html_escape "$(wb_board_pr_display "$pr_info")")</a>"
  local identity="<div class=\"identity\"><h3>$esc_title <span class=\"pill $pill_class\">$pill_label</span></h3><div class=\"meta-line\">$esc_repo &middot; $esc_branch</div></div>"
  local lane_meta="<div class=\"lane-meta\">$live_badge$wt_glyph$pr_chip</div>"
  local card_head="<div class=\"card-head\">$identity$lane_meta<a class=\"back\" href=\"#row-$view_anchor\">&#8593; back</a></div>"

  # --- U6: stepper + relationship chips (R13-R18) -------------------------
  local stepper_html; stepper_html="<div class=\"stepper\">$(wb_board_stepper_html "$repo" "$branch" "$worktree" "$taskfile" "$anchor_key" "$pr_info" 0)</div>"
  local deps_html; deps_html="$(wb_board_deps_chips "$anchor_key")"
  [ -n "$deps_html" ] && deps_html="<div class=\"deps-chips\">$deps_html</div>"

  local stem; stem="$(basename "$taskfile" .md)"
  if [ -n "${children_of[$stem]:-}" ]; then
    local own_count; own_count="$(printf '%s' "$own_docs" | grep -c . || true)"
    local children_html='' crow_file crow_status crow_title crow_chips
    local crow_stem crow_anchor crow_repo crow_branch crow_worktree crow_pr crow_stepper
    while IFS= read -r crow_file; do
      [ -n "$crow_file" ] && [ -f "$crow_file" ] || continue
      crow_status="$(wb_get_frontmatter "$crow_file" status)"
      crow_title="$(wb_task_title "$crow_file")"; [ -n "$crow_title" ] || crow_title="$(basename "$crow_file" .md)"
      crow_chips="$(wb_board_task_doc_chips "$crow_file" "$dotfiles_root")"
      crow_stem="$(basename "$crow_file" .md)"
      crow_anchor="${STEM_ANCHOR["$crow_stem"]:-}"
      crow_stepper=""
      if [ -n "$crow_anchor" ]; then
        crow_repo="$(wb_get_frontmatter "$crow_file" repo)"
        crow_branch="$(wb_get_frontmatter "$crow_file" branch)"
        crow_worktree="$(wb_get_frontmatter "$crow_file" worktree)"
        crow_pr="${PR_INFO["$crow_anchor"]:-}"
        crow_stepper="<div class=\"mini-stepper\">$(wb_board_stepper_html "$crow_repo" "$crow_branch" "$crow_worktree" "$crow_file" "$crow_anchor" "$crow_pr" 1)</div>"
      fi
      children_html+="<div class=\"child-row\"><span class=\"pill $crow_status\">$(wb_board_html_escape "$crow_status")</span> $(wb_board_html_escape "$crow_title") $crow_chips$crow_stepper</div>"$'\n'
    done <<< "${children_of[$stem]}"

    local rollup_docs rollup_html=""
    rollup_docs="$(wb_board_children_rollup_docs "${children_of[$stem]}" "$dotfiles_root")"
    if [ -n "$rollup_docs" ]; then
      local rn; rn="$(printf '%s\n' "$rollup_docs" | grep -c .)"
      local plural=""; [ "$rn" = 1 ] || plural="s"
      local rollup_chips="" rdoc
      while IFS= read -r rdoc; do
        [ -n "$rdoc" ] || continue
        rollup_chips+="<a class=\"artefact-chip\" href=\"$(wb_board_doc_link "$rdoc")\">$(wb_board_html_escape "$(basename "$rdoc")")</a> "
      done <<< "$rollup_docs"
      rollup_html="<details><summary>Show $rn artifact$plural from sub-tasks too</summary><p>$rollup_chips</p></details>"
    fi

    # R20: children-done counter + ready-to-close hint, never touching the
    # parent's own status pill.
    local rollup_counter=""
    if [ -n "${CHILDREN_TOTAL["$stem"]:-}" ]; then
      rollup_counter="<span class=\"children-counter\">${CHILDREN_DONE["$stem"]}/${CHILDREN_TOTAL["$stem"]} children done</span>"
      [ -n "${READY_TO_CLOSE["$stem"]:-}" ] && rollup_counter+="<span class=\"ready-hint\">&#10003; ready to close</span>"
    fi

    printf '<div class="task-detail"%s id="%s"><details open class="parent-row"><summary>%s<span class="own-count">%s of its own artifacts</span>%s</summary>%s%s%s<div class="children">%s</div>%s</details></div>\n' \
      "$card_attrs" "$view_anchor" "$card_head" "$own_count" "$rollup_counter" "$stepper_html" "$deps_html" "$detail_extra" "$children_html" "$rollup_html"
  else
    printf '<div class="task-detail"%s id="%s">%s%s%s%s</div>\n' "$card_attrs" "$view_anchor" "$card_head" "$stepper_html" "$deps_html" "$detail_extra"
  fi
}

# wb_board_render_html — writes the full /board page to stdout: 5 status
# tabs x 2 timeline windows, pre-rendered as 10 panels (+ Pipeline/Live/Stale)
# with radio-sibling tab switching. The switching mechanism itself is CSS-only
# (R8/R10); JS is limited to three deliberate, offline, dependency-free
# enhancements — column sort, theme toggle, and last-selected-tab persistence.
# Plus live-session badges per row (R11) and per-panel anchor-linked detail
# sections (R12).
wb_board_render_html() {
  local dotfiles_root
  dotfiles_root="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel 2>/dev/null)" || true
  [ -n "$dotfiles_root" ] || dotfiles_root="$CODE_DIR/dotfiles"

  local -a ROWS=()
  local line
  while IFS= read -r line; do ROWS+=("$line"); done < <(wb_board_collect_rows)

  # Parent-stem -> newline-joined list of children task files, one pass
  # over the whole store (not ROWS, which is tab/window-filtered — the
  # relationship is store-wide, independent of which panel a parent's card
  # happens to render in). Skips a task that names itself as its own
  # parent, the same self-reference guard U2's picker grouping uses.
  local -A children_of=()
  local -A STEM_PARENT=()   # stem -> parent stem (U7 family attribute, R21/R28)
  local cf cparent cstem
  while IFS= read -r cf; do
    cparent="$(wb_get_frontmatter "$cf" parent)"
    [ -n "$cparent" ] || continue
    cstem="$(basename "$cf" .md)"
    wb_task_own_parent "$cparent" "$cstem" || continue
    children_of["$cparent"]+="$cf"$'\n'
    STEM_PARENT["$cstem"]="$cparent"
  done < <(wb_task_files)

  # =========================================================================
  # U4 pre-pass (KTD-1) — every per-task fact any surface needs, computed
  # ONCE here (not once per panel — a task can appear in several of the
  # window x tab panels below), keyed by anchor_key (stems exist only for
  # task rows; untracked rows have no stem but still need their live-
  # session badge to survive the hoist, so LIVE_SESSION covers both kinds).
  # Mirrors the existing children_of pre-pass above.
  # =========================================================================
  local -A LIVE_SESSION=()   # anchor_key -> live tmux session name (or unset/empty)
  local -A ACTIVITY=()       # anchor_key -> active|dormant|cold (U6/R7, derived, never stored)
  local -A PR_INFO=()        # anchor_key -> this task's pr_info ("#n (state)\turl", task rows only)
  local -A PATH_LINES=()     # anchor_key -> newline-joined intended stages (task rows only)
  local -A STAGE_STATE=()    # wb_board_stage_key(anchor,stage) -> na|pending|progress|done
  local -A STEM_ANCHOR=()    # stem -> anchor_key
  local -A ANCHOR_STEM=()    # anchor_key -> stem
  local -A STEM_STATUS=()    # stem -> raw status
  local -A DEPS_OF=()        # anchor_key -> newline-joined blocker stems (dangling ones dropped after validation)
  local -A DANGLING_WARN=()  # anchor_key -> warning text (a declared stem has no task file)
  local -A CYCLE_MEMBER=()   # anchor_key -> 1 if on a dependency cycle
  local -A CYCLE_WARN=()     # anchor_key -> normalized loop warning text
  local -A UNMET_COUNT=()    # anchor_key -> count of currently-unmet blockers
  local -A BLOCKER_NAMES=()  # anchor_key -> "stem (status); ..." tooltip text
  local -A UNBLOCKS_COUNT=() # anchor_key -> count of other tasks currently waiting on this one
  local -A UNBLOCKS_NAMES=() # anchor_key -> waiter stems, tooltip text
  local -A CHILDREN_TOTAL=() # parent stem -> total children count
  local -A CHILDREN_DONE=()  # parent stem -> done children count
  local -A READY_TO_CLOSE=() # parent stem -> 1 when all children done and parent isn't
  local -A ALL_WEEK_RENDERED=() # anchor_key -> 1 if it got a card in All/Week (U9's link-reachability check for done tasks, KTD-7)
  local -A ANCHOR_REPO=()    # anchor_key -> slugged repo (U7, task and untracked rows alike)
  local -A ANCHOR_FAMILY=()  # anchor_key -> "slug(stem) [slug(parent_stem)]" (U7, task rows only)
  local -A ALL_REPOS=()      # slugged repo -> display repo (for the fr-* filter group)
  local -A REPO_NAME_TO_SLUG=() # raw repo name -> its (collision-disambiguated) slug

  local -a f
  local pp_row pp_kind pp_repo pp_branch pp_worktree pp_status pp_taskfile pp_anchor pp_stem

  # --- sub-pass A: live session, stem/status lookups, path, raw deps -----
  for pp_row in "${ROWS[@]}"; do
    wb_tsv_split "$pp_row" f
    pp_kind="${f[0]}"; pp_status="${f[2]}"; pp_repo="${f[3]}"; pp_branch="${f[4]}"
    pp_worktree="${f[5]}"; pp_taskfile="${f[10]}"; pp_anchor="${f[11]}"
    LIVE_SESSION["$pp_anchor"]="$(wb_board_live_session_for "$pp_repo" "$pp_branch")"
    # U6/R7: activity, via the shared wb_task_activity classifier, passing
    # the live-session lookup just above so it isn't repeated — derived
    # here, never stored, same rule the picker's own dormant rows follow.
    ACTIVITY["$pp_anchor"]="$(wb_task_activity "$pp_repo" "$pp_branch" "$pp_worktree" "${LIVE_SESSION["$pp_anchor"]}")"
    # Guard on the empty VALUE, not just for tidiness: bash treats an
    # associative-array subscript that evaluates to the empty string via
    # command substitution as "no subscript" ("bad array subscript"),
    # not as a literal empty key — a blank repo: (a malformed task file,
    # or anything else that isn't a real task) would otherwise crash the
    # whole render. anchor_key itself is always non-empty (derived from a
    # real filename), so it's always safe as a key.
    local pp_repo_slug=""
    if [ -n "$pp_repo" ]; then
      pp_repo_slug="${REPO_NAME_TO_SLUG["$pp_repo"]:-}"
      if [ -z "$pp_repo_slug" ]; then
        # wb_board_anchor_slug is lossy (every char outside [A-Za-z0-9_-]
        # collapses to '-'), so two distinct raw repo names (e.g. sibling
        # checkouts "next.js" and "next-js") can naively slug identically.
        # Disambiguate with a numeric suffix on collision so the fr-*
        # filter/data-repo attribute never conflates two different repos.
        pp_repo_slug="$(wb_board_anchor_slug "$pp_repo")"
        local pp_repo_suffix=2
        while [ -n "${ALL_REPOS["$pp_repo_slug"]:-}" ] && [ "${ALL_REPOS["$pp_repo_slug"]}" != "$pp_repo" ]; do
          pp_repo_slug="$(wb_board_anchor_slug "$pp_repo")-$pp_repo_suffix"
          pp_repo_suffix=$((pp_repo_suffix + 1))
        done
        REPO_NAME_TO_SLUG["$pp_repo"]="$pp_repo_slug"
        ALL_REPOS["$pp_repo_slug"]="$pp_repo"
      fi
    fi
    ANCHOR_REPO["$pp_anchor"]="$pp_repo_slug"
    [ "$pp_kind" = task ] || continue
    pp_stem="$(basename "$pp_taskfile" .md)"
    STEM_ANCHOR["$pp_stem"]="$pp_anchor"
    ANCHOR_STEM["$pp_anchor"]="$pp_stem"
    STEM_STATUS["$pp_stem"]="$pp_status"
    PATH_LINES["$pp_anchor"]="$(wb_lifecycle_parse_path "${f[12]}")"
    DEPS_OF["$pp_anchor"]="$(wb_board_parse_deps "${f[13]}")"
    # data-family carries SLUGGED tokens (wb_board_anchor_slug), mirroring
    # data-repo/ANCHOR_REPO — parent: is freeform frontmatter text with no
    # validation, and the raw stem previously landed straight in this HTML
    # attribute and in the [data-family~=...] CSS selector below unescaped.
    if [ -n "${STEM_PARENT["$pp_stem"]:-}" ]; then
      ANCHOR_FAMILY["$pp_anchor"]="$(wb_board_anchor_slug "$pp_stem") $(wb_board_anchor_slug "${STEM_PARENT["$pp_stem"]}")"
    else
      ANCHOR_FAMILY["$pp_anchor"]="$(wb_board_anchor_slug "$pp_stem")"
    fi
  done

  # --- sub-pass B: PR fetch, deduped by repo+branch (KTD-1's "one gh call
  # per task, not per panel"; also dedupes across tasks that SHARE a
  # branch), skipped entirely for an empty branch: ------------------------
  local -A pr_cache=()   # "repo\x1fbranch" -> pr_info, fetched at most once
  local pp_repo_dir pp_cache_key
  for pp_row in "${ROWS[@]}"; do
    wb_tsv_split "$pp_row" f
    [ "${f[0]}" = task ] || continue
    pp_repo="${f[3]}"; pp_branch="${f[4]}"; pp_anchor="${f[11]}"
    [ -n "$pp_branch" ] || continue
    pp_repo_dir="$(wb_repo_dir "$pp_repo")"
    [ -d "$pp_repo_dir/.git" ] || continue
    pp_cache_key="$pp_repo"$'\x1f'"$pp_branch"
    if [ -z "${pr_cache["$pp_cache_key"]+x}" ]; then
      pr_cache["$pp_cache_key"]="$(wb_board_pr_info "$pp_repo_dir" "$pp_branch")"
    fi
    PR_INFO["$pp_anchor"]="${pr_cache["$pp_cache_key"]}"
  done

  # --- sub-pass C: per-stage state (needs PATH_LINES + PR_INFO above) -----
  local pp_stage
  for pp_row in "${ROWS[@]}"; do
    wb_tsv_split "$pp_row" f
    [ "${f[0]}" = task ] || continue
    pp_repo="${f[3]}"; pp_branch="${f[4]}"; pp_worktree="${f[5]}"; pp_status="${f[2]}"
    pp_taskfile="${f[10]}"; pp_anchor="${f[11]}"
    for pp_stage in "${WB_LIFECYCLE_STAGES[@]}"; do
      STAGE_STATE["$(wb_board_stage_key "$pp_anchor" "$pp_stage")"]="$(wb_lifecycle_stage_state \
        "$pp_stage" "$pp_repo" "$pp_branch" "$pp_worktree" "$pp_taskfile" "$pp_status" \
        "${PR_INFO["$pp_anchor"]:-}" "${PATH_LINES["$pp_anchor"]}")"
    done
  done

  # --- sub-passes D/E/F: dependency-graph validation, cycle detection, and
  # blocked/unblocks counts — factored into standalone, nameref-based
  # functions (wb_board_deps_validate/_cycles/_blocking) so they're
  # directly unit-testable, same pattern wb_tsv_split already uses for its
  # array-name parameter. -----------------------------------------------
  wb_board_deps_validate DEPS_OF STEM_ANCHOR DANGLING_WARN
  wb_board_deps_cycles DEPS_OF STEM_ANCHOR ANCHOR_STEM CYCLE_MEMBER CYCLE_WARN
  wb_board_deps_blocking DEPS_OF STEM_ANCHOR STEM_STATUS ANCHOR_STEM CYCLE_MEMBER \
    UNMET_COUNT BLOCKER_NAMES UNBLOCKS_COUNT UNBLOCKS_NAMES

  # --- sub-pass G: children rollup counts (R20) ---------------------------
  local pp_parent_stem pp_child_file pp_total pp_done pp_child_status pp_parent_status
  for pp_parent_stem in "${!children_of[@]}"; do
    pp_total=0; pp_done=0
    while IFS= read -r pp_child_file; do
      [ -n "$pp_child_file" ] && [ -f "$pp_child_file" ] || continue
      pp_total=$((pp_total + 1))
      pp_child_status="$(wb_get_frontmatter "$pp_child_file" status)"
      [ "$pp_child_status" = done ] && pp_done=$((pp_done + 1))
    done <<< "${children_of["$pp_parent_stem"]}"
    CHILDREN_TOTAL["$pp_parent_stem"]="$pp_total"
    CHILDREN_DONE["$pp_parent_stem"]="$pp_done"
    pp_parent_status="${STEM_STATUS["$pp_parent_stem"]:-}"
    if [ "$pp_total" -gt 0 ] && [ "$pp_total" = "$pp_done" ] && [ "$pp_parent_status" != done ]; then
      READY_TO_CLOSE["$pp_parent_stem"]=1
    fi
  done

  # B3: the always-empty-by-design Deferred tab is dropped (reserved for a
  # future `pending` status that doesn't exist yet — an empty tab is noise).
  local -a TABS=(all inprogress upcoming paused unclassified)
  local -A TAB_LABEL=([all]="All" [inprogress]="In Progress" [upcoming]="Upcoming" [paused]="Paused" [unclassified]="Unclassified")
  local -a WINDOWS=(today week)
  local -A WIN_LABEL=([today]="Today" [week]="This week")

  # Radios are declared ONCE here, before <header>/<main> — the CSS below
  # relies on both radio groups being earlier siblings of <main> so the
  # `~` sibling combinator can reach it (label position doesn't matter,
  # since labels reference these ids via for= rather than nesting).
  # Highlight CSS is generated per-radio here too (not a single
  # `input:checked + label` rule) for the same reason panel visibility
  # needs `~ main #panel-...`: since the radios and their labels are no
  # longer adjacent siblings (labels live in <header>, away from the
  # hidden radios), `+`/plain `~` can't reach a label by position alone —
  # each rule targets the specific label by its for= attribute instead.
  local radios_html='' tabs_html='' status_tabs_html='' win_html='' panel_css='' panels_html='' highlight_css=''
  # R7 parity with the picker/plain-text board (wb_status_line / cmd_board) —
  # same wb_live_agent_count, just rendered into this page's own header.
  local live_agents_html; live_agents_html="<span class=\"live-agents\">agents: $(wb_live_agent_count) live (warn &ge; ${WB_AGENT_WARN_AT})</span>"
  local win tab first_win=1
  for win in "${WINDOWS[@]}"; do
    local checked=""; [ "$first_win" = 1 ] && checked=" checked" && first_win=0
    radios_html+="<input type=\"radio\" name=\"tl\" id=\"tl-$win\"$checked>"$'\n'
    win_html+="<label for=\"tl-$win\">${WIN_LABEL[$win]}</label>"$'\n'
    highlight_css+="#tl-$win:checked ~ header label[for=\"tl-$win\"] { background: var(--acc); color: white; }"$'\n'
  done
  # Pipeline is the first tab and default-checked (approved mockup) — the
  # rest of the TABS array is never checked by default anymore. It gets its
  # own hand-written visibility rules below (KTD-7) rather than the
  # generic per-(win,tab) rule the loop after this generates for the
  # original 6 bucket tabs, since its one panel renders under EITHER
  # window radio, not one panel per window.
  radios_html+="<input type=\"radio\" name=\"st\" id=\"st-pipeline\" checked>"$'\n'
  tabs_html+="<label for=\"st-pipeline\">Pipeline</label>"$'\n'
  highlight_css+="#st-pipeline:checked ~ header label[for=\"st-pipeline\"] { background: var(--acc); color: white; }"$'\n'
  # Live/Stale — same window-independent treatment as Pipeline (KTD-7):
  # cross-cutting views over in-flight work, not another status bucket.
  for tab in live stale; do
    radios_html+="<input type=\"radio\" name=\"st\" id=\"st-$tab\">"$'\n'
    highlight_css+="#st-$tab:checked ~ header label[for=\"st-$tab\"] { background: var(--acc); color: white; }"$'\n'
  done
  tabs_html+="<label for=\"st-live\">Live</label>"$'\n'
  tabs_html+="<label for=\"st-stale\">Stale</label>"$'\n'
  # B3: bucket tabs land in their own "Status" tabgroup (status_tabs_html),
  # visually separated from the Views tabgroup (Pipeline/Live/Stale) above.
  # The radios stay one shared name="st" group, so they're still mutually
  # exclusive across both visual clusters.
  for tab in "${TABS[@]}"; do
    radios_html+="<input type=\"radio\" name=\"st\" id=\"st-$tab\">"$'\n'
    status_tabs_html+="<label for=\"st-$tab\">${TAB_LABEL[$tab]}</label>"$'\n'
    highlight_css+="#st-$tab:checked ~ header label[for=\"st-$tab\"] { background: var(--acc); color: white; }"$'\n'
  done

  # Pipeline's panel is window-independent (KTD-7): it renders once, but
  # must be reachable under EITHER window radio, hence two rules pointing
  # at the same single #panel-pipeline id (not one rule per window x tab
  # combination like the loop below generates for the 6 bucket tabs).
  for win in "${WINDOWS[@]}"; do
    panel_css+="#tl-$win:checked ~ #st-pipeline:checked ~ main #panel-pipeline { display: flex; }"$'\n'
    panel_css+="#tl-$win:checked ~ #st-live:checked ~ main #panel-live { display: flex; }"$'\n'
    panel_css+="#tl-$win:checked ~ #st-stale:checked ~ main #panel-stale { display: flex; }"$'\n'
  done

  # --- U7: repo/family filter radio groups (KTD-8) — declared here,
  # before <header>/<main> (same reason as tl/st above), with fr-*/fp-*
  # AFTER tl/st in DOM order per the plan's document-order sketch. "All
  # repos"/"All families" are always first and checked (R26); the family
  # group is omitted ENTIRELY when the store has no parent/child pairs at
  # all — a lone "All families" control would be noise. Repo/family
  # filters AND-compose by construction: two independent rule families,
  # never a combined selector (R28).
  local -a repo_slugs_sorted
  mapfile -t repo_slugs_sorted < <(for s in "${!ALL_REPOS[@]}"; do printf '%s\t%s\n' "${ALL_REPOS[$s]}" "$s"; done | sort | cut -f2)
  local repo_options_html="<label for=\"fr-all\">All repos</label>"$'\n'
  local repo_summary_labels="<span class=\"filter-label\" data-for=\"all\">Repo &#9662;</span>"
  local repo_hide_css='' repo_summary_css='' repo_slug repo_display
  radios_html+="<input type=\"radio\" name=\"fr\" id=\"fr-all\" checked>"$'\n'
  for repo_slug in "${repo_slugs_sorted[@]}"; do
    radios_html+="<input type=\"radio\" name=\"fr\" id=\"fr-$repo_slug\">"$'\n'
    repo_display="$(wb_board_html_escape "${ALL_REPOS[$repo_slug]}")"
    repo_options_html+="<label for=\"fr-$repo_slug\">$repo_display</label>"$'\n'
    repo_summary_labels+="<span class=\"filter-label\" data-for=\"$repo_slug\">Repo: $repo_display &#9662;</span>"
    repo_hide_css+="#fr-$repo_slug:checked ~ main .view tr.row:not([data-repo=\"$repo_slug\"]), #fr-$repo_slug:checked ~ main .view .task-detail:not([data-repo=\"$repo_slug\"]) { display: none; }"$'\n'
    repo_summary_css+="#fr-$repo_slug:checked ~ header .repo-filter .filter-label { display: none; } #fr-$repo_slug:checked ~ header .repo-filter .filter-label[data-for=\"$repo_slug\"] { display: inline; }"$'\n'
  done

  local -a fam_stems_sorted=()
  local family_options_html='' family_summary_labels='' family_hide_css='' family_summary_css=''
  if [ "${#children_of[@]}" -gt 0 ]; then
    mapfile -t fam_stems_sorted < <(printf '%s\n' "${!children_of[@]}" | sort)
    radios_html+="<input type=\"radio\" name=\"fp\" id=\"fp-all\" checked>"$'\n'
    family_options_html="<label for=\"fp-all\">All families</label>"$'\n'
    family_summary_labels="<span class=\"filter-label\" data-for=\"all\">Family &#9662;</span>"
    local fam_stem fam_slug fam_label
    for fam_stem in "${fam_stems_sorted[@]}"; do
      fam_slug="$(wb_board_anchor_slug "$fam_stem")"
      radios_html+="<input type=\"radio\" name=\"fp\" id=\"fp-$fam_slug\">"$'\n'
      fam_label="$(wb_board_html_escape "$fam_stem")"
      family_options_html+="<label for=\"fp-$fam_slug\">$fam_label</label>"$'\n'
      family_summary_labels+="<span class=\"filter-label\" data-for=\"$fam_slug\">Family: $fam_label &#9662;</span>"
      # Matching value is the SAME slug used for the radio id (not the raw
      # $fam_stem) — data-family attributes above are populated with
      # wb_board_anchor_slug'd tokens, and this selector must match those,
      # not raw (unescaped, attribute-injectable) frontmatter text.
      family_hide_css+="#fp-$fam_slug:checked ~ main .view tr.row:not([data-family~=\"$fam_slug\"]), #fp-$fam_slug:checked ~ main .view .task-detail:not([data-family~=\"$fam_slug\"]) { display: none; }"$'\n'
      family_summary_css+="#fp-$fam_slug:checked ~ header .family-filter .filter-label { display: none; } #fp-$fam_slug:checked ~ header .family-filter .filter-label[data-for=\"$fam_slug\"] { display: inline; }"$'\n'
    done
  fi

  local family_dropdown_html=""
  if [ "${#children_of[@]}" -gt 0 ]; then
    family_dropdown_html="<details class=\"filter-dropdown family-filter\"><summary>$family_summary_labels</summary><div class=\"filter-options\">$family_options_html</div></details>"
  fi

  # U6/R17: "Dormant only" — a single checkbox toggle (not a radio dropdown
  # like repo/family) since activity is a plain on/off filter, not a
  # many-valued choice; AND-composes with repo/family the same way those
  # two already AND-compose with each other (R28).
  radios_html+="<input type=\"checkbox\" id=\"dormant-only\">"$'\n'
  local dormant_toggle_html='<label for="dormant-only" class="dormant-toggle">Dormant only</label>'
  local dormant_hide_css='#dormant-only:checked ~ main .view tr.row:not([data-activity="dormant"]), #dormant-only:checked ~ main .view .task-detail:not([data-activity="dormant"]) { display: none; }'

  # U7: per-panel (repo,family) presence tracking (KTD-8) — populated as
  # rows are collected below, consumed after all 13 panels are built to
  # generate empty-intersection reveal rules (a filter combination that
  # empties an otherwise non-empty panel reveals its own pre-rendered
  # empty-state, rather than showing a stale table/blank space).
  local -A PANEL_ANY=()      # panelkey -> 1 if the panel has any row at all
  local -A PANEL_REPO=()     # "panelkey\x1frepo" -> 1
  local -A PANEL_FAMILY=()   # "panelkey\x1ffamily" -> 1
  local -A PANEL_COMBO=()    # "panelkey\x1frepo\x1ffamily" -> 1

  local row kind bucket status repo branch worktree title created closed updated taskfile anchor_key
  local -a f
  for win in "${WINDOWS[@]}"; do
    local window_start; window_start="$(wb_board_window_start "$win")"
    for tab in "${TABS[@]}"; do
      panel_css+="#tl-$win:checked ~ #st-$tab:checked ~ main #panel-$tab-$win { display: flex; }"$'\n'
      local panelkey="$tab-$win"
      local table_rows='' detail_sections='' any=0
      for row in "${ROWS[@]}"; do
        wb_tsv_split "$row" f
        kind="${f[0]}"; bucket="${f[1]}"; status="${f[2]}"; repo="${f[3]}"; branch="${f[4]}"
        worktree="${f[5]}"; title="${f[6]}"; created="${f[7]}"; closed="${f[8]}"; updated="${f[9]}"
        taskfile="${f[10]}"; anchor_key="${f[11]}"
        [ "$tab" = all ] || [ "$bucket" = "$tab" ] || continue
        wb_board_in_window "$created" "$closed" "$updated" "$window_start" || continue
        any=1
        PANEL_ANY["$panelkey"]=1
        [ "$tab" = all ] && [ "$win" = week ] && ALL_WEEK_RENDERED["$anchor_key"]=1
        local view_anchor="t-$tab-$win-$anchor_key"
        local esc_title esc_branch esc_repo pill_class pill_label live_session live_badge
        esc_title="$(wb_board_html_escape "$title")"
        esc_branch="$(wb_board_html_escape "$branch")"
        esc_repo="$(wb_board_html_escape "$repo")"
        pill_class="$status"; pill_label="$status"
        [ "$kind" = untracked ] && { pill_class="unclassified"; pill_label="unclassified"; }
        live_session="${LIVE_SESSION["$anchor_key"]:-}"
        live_badge=""
        [ -n "$live_session" ] && live_badge="<span class=\"live-badge\"><span class=\"dot\">&#9679;</span>$(wb_board_html_escape "$live_session")</span>"
        local link_text="$esc_title"
        [ "$kind" = untracked ] && link_text="$esc_branch <span class=\"repo\">(no task file)</span>"
        local row_repo_attr="${ANCHOR_REPO["$anchor_key"]:-}" row_family_attr="${ANCHOR_FAMILY["$anchor_key"]:-}"
        local row_attrs=" id=\"row-$view_anchor\" data-repo=\"$row_repo_attr\" data-status=\"$pill_class\" data-activity=\"${ACTIVITY["$anchor_key"]:-cold}\""
        [ -n "$row_family_attr" ] && row_attrs+=" data-family=\"$row_family_attr\""
        PANEL_REPO["$panelkey"$'\x1f'"$row_repo_attr"]=1
        if [ -n "$row_family_attr" ]; then
          local fam_tok
          for fam_tok in $row_family_attr; do
            PANEL_FAMILY["$panelkey"$'\x1f'"$fam_tok"]=1
            PANEL_COMBO["$panelkey"$'\x1f'"$row_repo_attr"$'\x1f'"$fam_tok"]=1
          done
        fi
        table_rows+="<tr class=\"row\"$row_attrs><td><span class=\"pill $pill_class\">$pill_label</span></td><td><div class=\"task-cell\"><a class=\"tasklink\" href=\"#$view_anchor\">$link_text</a>$live_badge</div></td><td class=\"repo\">$esc_repo</td></tr>"$'\n'

        detail_sections+="$(wb_board_render_detail_card)"$'\n'
      done

      if [ "$any" = 1 ]; then
        panels_html+="<div class=\"view\" id=\"panel-$tab-$win\"><div class=\"table-wrap\"><table><tr><th class=\"sortable\" data-sort=\"status\">Status</th><th>Task</th><th class=\"sortable\" data-sort=\"repo\">Repo</th></tr>$table_rows</table></div><div><p class=\"details-heading\">Task details</p><div class=\"details-stack\">$detail_sections</div></div><div class=\"empty-state filtered-empty\" id=\"empty-$tab-$win\">No tasks match this filter combination.</div></div>"$'\n'
      else
        panels_html+="<div class=\"view\" id=\"panel-$tab-$win\"><div class=\"empty-state\">No tasks in this view.</div></div>"$'\n'
      fi
    done
  done

  # ===========================================================================
  # U5: Pipeline panel — one row per in-flight (non-done) task, window-
  # independent (KTD-7), sharing the same wb_board_render_detail_card
  # renderer bucket panels use. Untracked rows are excluded (R9/Assumptions
  # — no task file means no path/intent).
  # ===========================================================================
  local pipe_rows='' pipe_details='' pipe_any=0
  for row in "${ROWS[@]}"; do
    wb_tsv_split "$row" f
    kind="${f[0]}"; bucket="${f[1]}"; status="${f[2]}"; repo="${f[3]}"; branch="${f[4]}"
    worktree="${f[5]}"; title="${f[6]}"; created="${f[7]}"; closed="${f[8]}"; updated="${f[9]}"
    taskfile="${f[10]}"; anchor_key="${f[11]}"
    [ "$kind" = task ] || continue
    [ "$bucket" = done ] && continue
    pipe_any=1

    local view_anchor="t-pipeline-$anchor_key"
    local esc_title esc_branch esc_repo pill_class pill_label live_session live_badge
    esc_title="$(wb_board_html_escape "$title")"
    esc_branch="$(wb_board_html_escape "$branch")"
    esc_repo="$(wb_board_html_escape "$repo")"
    pill_class="$status"; pill_label="$status"
    live_session="${LIVE_SESSION["$anchor_key"]:-}"
    live_badge=""
    [ -n "$live_session" ] && live_badge="<span class=\"live-badge\"><span class=\"dot\">&#9679;</span>$(wb_board_html_escape "$live_session")</span>"

    local row_class="row"
    [ -n "${UNMET_COUNT["$anchor_key"]:-}" ] && row_class+=" blocked"
    local row_repo_attr="${ANCHOR_REPO["$anchor_key"]:-}" row_family_attr="${ANCHOR_FAMILY["$anchor_key"]:-}"
    local row_attrs=" id=\"row-$view_anchor\" data-repo=\"$row_repo_attr\" data-status=\"$pill_class\" data-activity=\"${ACTIVITY["$anchor_key"]:-cold}\""
    [ -n "$row_family_attr" ] && row_attrs+=" data-family=\"$row_family_attr\""
    PANEL_ANY["pipeline"]=1
    PANEL_REPO["pipeline"$'\x1f'"$row_repo_attr"]=1
    if [ -n "$row_family_attr" ]; then
      local fam_tok
      for fam_tok in $row_family_attr; do
        PANEL_FAMILY["pipeline"$'\x1f'"$fam_tok"]=1
        PANEL_COMBO["pipeline"$'\x1f'"$row_repo_attr"$'\x1f'"$fam_tok"]=1
      done
    fi

    local stage_cells='' pp_stage
    for pp_stage in "${WB_LIFECYCLE_STAGES[@]}"; do
      stage_cells+="$(wb_board_stage_cell "$pp_stage" \
        "${STAGE_STATE["$(wb_board_stage_key "$anchor_key" "$pp_stage")"]:-na}" \
        "$repo" "$branch" "$worktree" "$taskfile" "${PR_INFO["$anchor_key"]:-}")"
    done

    local wt_cell pr_cell deps_cell
    if wb_lifecycle_has_worktree "$repo" "$worktree"; then wt_cell="&#10003;"; else wt_cell="&mdash;"; fi
    local pipe_pr_info="${PR_INFO["$anchor_key"]:-}"
    if [ -n "$pipe_pr_info" ]; then
      pr_cell="<a href=\"$(wb_board_html_escape "$(wb_board_pr_url "$pipe_pr_info")")\">$(wb_board_html_escape "$(wb_board_pr_number "$pipe_pr_info")")</a>"
    else
      pr_cell="&mdash;"
    fi
    deps_cell="$(wb_board_deps_chips "$anchor_key")"; [ -n "$deps_cell" ] || deps_cell="&mdash;"

    pipe_rows+="<tr class=\"$row_class\"$row_attrs><td><div class=\"task-cell\"><a class=\"tasklink\" href=\"#$view_anchor\">$esc_title</a><span class=\"repo\">$esc_repo</span>$live_badge</div></td><td><span class=\"pill $pill_class\">$pill_label</span></td>$stage_cells<td>$wt_cell</td><td>$pr_cell</td><td>$deps_cell</td></tr>"$'\n'
    detail_sections="$(wb_board_render_detail_card)"
    pipe_details+="$detail_sections"$'\n'
  done

  if [ "$pipe_any" = 1 ]; then
    panels_html+="<div class=\"view\" id=\"panel-pipeline\"><p class=\"stage-legend\"><b>Stages:</b> &#10003; done &middot; &#9679; active &middot; &#9675; pending &middot; &#183; n/a</p><div class=\"table-wrap\"><table><tr><th>Task</th><th class=\"sortable\" data-sort=\"status\">Status</th><th>Ideate</th><th>Brainstorm</th><th>Plan</th><th>Work</th><th>Review</th><th>Worktree</th><th>PR</th><th>Deps</th></tr>$pipe_rows</table></div><div><p class=\"details-heading\">Task details</p><div class=\"details-stack\">$pipe_details</div></div><div class=\"empty-state filtered-empty\" id=\"empty-pipeline\">No tasks match this filter combination.</div></div>"$'\n'
  else
    panels_html+="<div class=\"view\" id=\"panel-pipeline\"><div class=\"empty-state\">No in-flight tasks.</div></div>"$'\n'
  fi

  # ===========================================================================
  # Live tab — every task or untracked row with a currently-running tmux
  # session (LIVE_SESSION non-empty), window-independent like Pipeline.
  # Reuses the bucket-tab's 3-column table + wb_board_render_detail_card,
  # not Pipeline's stage-cell table -- this is "what's running right now",
  # not a lifecycle view.
  # ===========================================================================
  local live_rows='' live_details='' live_any=0
  for row in "${ROWS[@]}"; do
    wb_tsv_split "$row" f
    kind="${f[0]}"; bucket="${f[1]}"; status="${f[2]}"; repo="${f[3]}"; branch="${f[4]}"
    worktree="${f[5]}"; title="${f[6]}"; created="${f[7]}"; closed="${f[8]}"; updated="${f[9]}"
    taskfile="${f[10]}"; anchor_key="${f[11]}"
    local live_session="${LIVE_SESSION["$anchor_key"]:-}"
    [ -n "$live_session" ] || continue
    live_any=1
    local view_anchor="t-live-$anchor_key"
    local esc_title esc_branch esc_repo pill_class pill_label live_badge
    esc_title="$(wb_board_html_escape "$title")"
    esc_branch="$(wb_board_html_escape "$branch")"
    esc_repo="$(wb_board_html_escape "$repo")"
    pill_class="$status"; pill_label="$status"
    [ "$kind" = untracked ] && { pill_class="unclassified"; pill_label="unclassified"; }
    live_badge="<span class=\"live-badge\"><span class=\"dot\">&#9679;</span>$(wb_board_html_escape "$live_session")</span>"
    local link_text="$esc_title"
    [ "$kind" = untracked ] && link_text="$esc_branch <span class=\"repo\">(no task file)</span>"
    local row_repo_attr="${ANCHOR_REPO["$anchor_key"]:-}" row_family_attr="${ANCHOR_FAMILY["$anchor_key"]:-}"
    local row_attrs=" id=\"row-$view_anchor\" data-repo=\"$row_repo_attr\" data-status=\"$pill_class\" data-activity=\"${ACTIVITY["$anchor_key"]:-cold}\""
    [ -n "$row_family_attr" ] && row_attrs+=" data-family=\"$row_family_attr\""
    PANEL_ANY["live"]=1
    PANEL_REPO["live"$'\x1f'"$row_repo_attr"]=1
    if [ -n "$row_family_attr" ]; then
      local fam_tok
      for fam_tok in $row_family_attr; do
        PANEL_FAMILY["live"$'\x1f'"$fam_tok"]=1
        PANEL_COMBO["live"$'\x1f'"$row_repo_attr"$'\x1f'"$fam_tok"]=1
      done
    fi
    live_rows+="<tr class=\"row\"$row_attrs><td><span class=\"pill $pill_class\">$pill_label</span></td><td><div class=\"task-cell\"><a class=\"tasklink\" href=\"#$view_anchor\">$link_text</a>$live_badge</div></td><td class=\"repo\">$esc_repo</td></tr>"$'\n'
    live_details+="$(wb_board_render_detail_card)"$'\n'
  done
  if [ "$live_any" = 1 ]; then
    panels_html+="<div class=\"view\" id=\"panel-live\"><div class=\"table-wrap\"><table><tr><th class=\"sortable\" data-sort=\"status\">Status</th><th>Task</th><th class=\"sortable\" data-sort=\"repo\">Repo</th></tr>$live_rows</table></div><div><p class=\"details-heading\">Task details</p><div class=\"details-stack\">$live_details</div></div><div class=\"empty-state filtered-empty\" id=\"empty-live\">No tasks match this filter combination.</div></div>"$'\n'
  else
    panels_html+="<div class=\"view\" id=\"panel-live\"><div class=\"empty-state\">No live sessions right now.</div></div>"$'\n'
  fi

  # ===========================================================================
  # Stale tab — in-flight (non-done) tasks whose created/closed/updated all
  # predate the staleness threshold, i.e. the inverse of wb_board_in_window
  # widened past "week". WB_STALE_DAYS is a plain tunable constant, not a
  # frontmatter field or a third window radio -- staleness is a Pipeline-
  # scoped lens ("which of my in-flight tasks am I neglecting"), not a
  # dimension the other 6 bucket tabs' today/week pairing needs too.
  # ===========================================================================
  local -r WB_STALE_DAYS=14
  local stale_start; stale_start="$(date -d "${WB_STALE_DAYS} days ago 00:00:00" +%s)"
  local stale_rows='' stale_details='' stale_any=0
  for row in "${ROWS[@]}"; do
    wb_tsv_split "$row" f
    kind="${f[0]}"; bucket="${f[1]}"; status="${f[2]}"; repo="${f[3]}"; branch="${f[4]}"
    worktree="${f[5]}"; title="${f[6]}"; created="${f[7]}"; closed="${f[8]}"; updated="${f[9]}"
    taskfile="${f[10]}"; anchor_key="${f[11]}"
    [ "$kind" = task ] || continue
    [ "$bucket" = done ] && continue
    wb_board_in_window "$created" "$closed" "$updated" "$stale_start" && continue
    stale_any=1
    local view_anchor="t-stale-$anchor_key"
    local esc_title esc_branch esc_repo pill_class pill_label live_session live_badge
    esc_title="$(wb_board_html_escape "$title")"
    esc_branch="$(wb_board_html_escape "$branch")"
    esc_repo="$(wb_board_html_escape "$repo")"
    pill_class="$status"; pill_label="$status"
    live_session="${LIVE_SESSION["$anchor_key"]:-}"
    live_badge=""
    [ -n "$live_session" ] && live_badge="<span class=\"live-badge\"><span class=\"dot\">&#9679;</span>$(wb_board_html_escape "$live_session")</span>"
    local row_repo_attr="${ANCHOR_REPO["$anchor_key"]:-}" row_family_attr="${ANCHOR_FAMILY["$anchor_key"]:-}"
    local row_attrs=" id=\"row-$view_anchor\" data-repo=\"$row_repo_attr\" data-status=\"$pill_class\" data-activity=\"${ACTIVITY["$anchor_key"]:-cold}\""
    [ -n "$row_family_attr" ] && row_attrs+=" data-family=\"$row_family_attr\""
    PANEL_ANY["stale"]=1
    PANEL_REPO["stale"$'\x1f'"$row_repo_attr"]=1
    if [ -n "$row_family_attr" ]; then
      local fam_tok
      for fam_tok in $row_family_attr; do
        PANEL_FAMILY["stale"$'\x1f'"$fam_tok"]=1
        PANEL_COMBO["stale"$'\x1f'"$row_repo_attr"$'\x1f'"$fam_tok"]=1
      done
    fi
    stale_rows+="<tr class=\"row\"$row_attrs><td><span class=\"pill $pill_class\">$pill_label</span></td><td><div class=\"task-cell\"><a class=\"tasklink\" href=\"#$view_anchor\">$esc_title</a>$live_badge</div></td><td class=\"repo\">$esc_repo</td></tr>"$'\n'
    stale_details+="$(wb_board_render_detail_card)"$'\n'
  done
  if [ "$stale_any" = 1 ]; then
    panels_html+="<div class=\"view\" id=\"panel-stale\"><div class=\"table-wrap\"><table><tr><th class=\"sortable\" data-sort=\"status\">Status</th><th>Task</th><th class=\"sortable\" data-sort=\"repo\">Repo</th></tr>$stale_rows</table></div><div><p class=\"details-heading\">Task details</p><div class=\"details-stack\">$stale_details</div></div><div class=\"empty-state filtered-empty\" id=\"empty-stale\">No tasks match this filter combination.</div></div>"$'\n'
  else
    panels_html+="<div class=\"view\" id=\"panel-stale\"><div class=\"empty-state\">Nothing in-flight has gone quiet for ${WB_STALE_DAYS}+ days.</div></div>"$'\n'
  fi

  # =========================================================================
  # U9: Key Findings — board-global insights computed from the pre-pass,
  # rendered once outside every .view (R22) so no repo/family filter can
  # ever reach it. Starter six; an insight with no results is omitted
  # entirely (no empty heading); only when ALL SIX are empty does the
  # section render a single muted line — the section itself never
  # vanishes, which would read as breakage.
  # =========================================================================
  local -A KF_TITLE=() KF_CREATED=() KF_CLOSED=() KF_BRANCH=() KF_BUCKET=() KF_REVIEWED=()
  for row in "${ROWS[@]}"; do
    wb_tsv_split "$row" f
    [ "${f[0]}" = task ] || continue
    anchor_key="${f[11]}"
    KF_TITLE["$anchor_key"]="${f[6]}"
    KF_CREATED["$anchor_key"]="${f[7]}"
    KF_CLOSED["$anchor_key"]="${f[8]}"
    KF_BRANCH["$anchor_key"]="${f[4]}"
    KF_BUCKET["$anchor_key"]="${f[1]}"
    KF_REVIEWED["$anchor_key"]="${f[14]}"
  done

  # kf_item <anchor_key> <label_extra> — one <li> for an insight, linked
  # via wb_board_kf_link when reachable, plain text otherwise.
  kf_item() {
    local ak="$1" extra="${2:-}" href title_esc
    title_esc="$(wb_board_html_escape "${KF_TITLE["$ak"]:-$ak}")"
    href="$(wb_board_kf_link "$ak" "${KF_BUCKET["$ak"]:-}")"
    if [ -n "$href" ]; then
      printf '<li><a href="%s">%s</a>%s</li>' "$href" "$title_esc" "$extra"
    else
      printf '<li>%s%s</li>' "$title_esc" "$extra"
    fi
  }

  local kf_html=''

  # 1. Most-blocking task (max unblocks count; ties all listed)
  local kf_max=0 kf_ak
  for kf_ak in "${!UNBLOCKS_COUNT[@]}"; do
    [ "${UNBLOCKS_COUNT["$kf_ak"]}" -gt "$kf_max" ] && kf_max="${UNBLOCKS_COUNT["$kf_ak"]}"
  done
  if [ "$kf_max" -gt 0 ]; then
    local kf_blocking_items=''
    for kf_ak in "${!UNBLOCKS_COUNT[@]}"; do
      [ "${UNBLOCKS_COUNT["$kf_ak"]}" = "$kf_max" ] && kf_blocking_items+="$(kf_item "$kf_ak" " — blocks $kf_max")"
    done
    kf_html+="<div class=\"kf-item\"><b>Most blocking:</b><ul>$kf_blocking_items</ul></div>"
  fi

  # 2. Parents ready to close
  if [ "${#READY_TO_CLOSE[@]}" -gt 0 ]; then
    local kf_ready_items=''
    for kf_ak in "${!READY_TO_CLOSE[@]}"; do
      local kf_ready_anchor="${STEM_ANCHOR["$kf_ak"]:-}"
      [ -n "$kf_ready_anchor" ] && kf_ready_items+="$(kf_item "$kf_ready_anchor" " — ${CHILDREN_DONE["$kf_ak"]}/${CHILDREN_TOTAL["$kf_ak"]} children done")"
    done
    [ -n "$kf_ready_items" ] && kf_html+="<div class=\"kf-item\"><b>Ready to close:</b><ul>$kf_ready_items</ul></div>"
  fi

  # 3. Done-but-unreviewed count (grandfathered: only counts closed: on/
  # after the convention date, KTD-11)
  local kf_unreviewed_count=0
  for kf_ak in "${!KF_BUCKET[@]}"; do
    [ "${KF_BUCKET["$kf_ak"]}" = done ] || continue
    [ -n "${KF_REVIEWED["$kf_ak"]:-}" ] && continue
    local kf_closed="${KF_CLOSED["$kf_ak"]:-}"
    [ -n "$kf_closed" ] || continue
    [[ "$kf_closed" > "$WB_REVIEW_CONVENTION_DATE" || "$kf_closed" == "$WB_REVIEW_CONVENTION_DATE" ]] || continue
    kf_unreviewed_count=$((kf_unreviewed_count + 1))
  done
  [ "$kf_unreviewed_count" -gt 0 ] && kf_html+="<div class=\"kf-item\"><b>Done but unreviewed:</b> $kf_unreviewed_count</div>"

  # 4. Oldest in-flight task (min created: among non-done)
  local kf_oldest_ak='' kf_oldest_created=''
  for kf_ak in "${!KF_BUCKET[@]}"; do
    [ "${KF_BUCKET["$kf_ak"]}" = done ] && continue
    local kf_created="${KF_CREATED["$kf_ak"]:-}"
    [ -n "$kf_created" ] || continue
    if [ -z "$kf_oldest_created" ] || [[ "$kf_created" < "$kf_oldest_created" ]]; then
      kf_oldest_created="$kf_created"; kf_oldest_ak="$kf_ak"
    fi
  done
  [ -n "$kf_oldest_ak" ] && kf_html+="<div class=\"kf-item\"><b>Oldest in-flight:</b><ul>$(kf_item "$kf_oldest_ak" " — created $kf_oldest_created")</ul></div>"

  # 5. No-bucket statuses (a real task whose status maps to no known bucket)
  local kf_nobucket_items=''
  for kf_ak in "${!KF_BUCKET[@]}"; do
    [ "${KF_BUCKET["$kf_ak"]}" = unclassified ] && kf_nobucket_items+="$(kf_item "$kf_ak")"
  done
  [ -n "$kf_nobucket_items" ] && kf_html+="<div class=\"kf-item\"><b>No-bucket status:</b><ul>$kf_nobucket_items</ul></div>"

  # 6. Branchless tasks whose stem matches a store doc filename (R27's
  # docs-before-branch pattern, suppressed from state, surfaced here)
  local kf_docs_items=''
  for kf_ak in "${!KF_BUCKET[@]}"; do
    [ -n "${KF_BRANCH["$kf_ak"]:-}" ] && continue
    local kf_stem="${ANCHOR_STEM["$kf_ak"]:-}"
    [ -n "$kf_stem" ] || continue
    local kf_dir kf_match=0
    for kf_dir in plans brainstorms ideation; do
      [ -d "$dotfiles_root/docs/$kf_dir" ] || continue
      local kf_f
      for kf_f in "$dotfiles_root/docs/$kf_dir"/*"$kf_stem"*; do
        [ -f "$kf_f" ] || continue
        kf_match=1; break
      done
      [ "$kf_match" = 1 ] && break
    done
    [ "$kf_match" = 1 ] && kf_docs_items+="$(kf_item "$kf_ak" " — docs exist, no branch yet")"
  done
  [ -n "$kf_docs_items" ] && kf_html+="<div class=\"kf-item\"><b>Docs before branch:</b><ul>$kf_docs_items</ul></div>"

  [ -n "$kf_html" ] || kf_html='<p class="kf-empty">Nothing notable right now.</p>'
  local key_findings_html="<section class=\"key-findings\"><h2>Key Findings <span class=\"kf-tag\">board-wide &middot; ignores filters</span></h2>$kf_html</section>"

  # --- U7: empty-intersection reveal rules (KTD-8) — for each panel and
  # each (repo, family) combination that would leave zero VISIBLE rows
  # despite the panel having SOME rows overall, reveal that panel's own
  # pre-rendered .filtered-empty div. Bounded at panels x repos x
  # families (low hundreds of rules at most) — no :has() dependency, the
  # same pre-render-everything approach the rest of this page already
  # uses for its 13 panels.
  local -a repo_opts=("all" "${repo_slugs_sorted[@]}")
  local -a family_opts=("all")
  [ "${#children_of[@]}" -gt 0 ] && for fam_stem in "${fam_stems_sorted[@]}"; do family_opts+=("$(wb_board_anchor_slug "$fam_stem")"); done
  local reveal_css='' panelkey ro fo empty ptab pwin
  for panelkey in "${!PANEL_ANY[@]}"; do
    for ro in "${repo_opts[@]}"; do
      for fo in "${family_opts[@]}"; do
        [ "$ro" = all ] && [ "$fo" = all ] && continue
        empty=0
        if [ "$fo" = all ]; then
          [ -n "${PANEL_REPO["$panelkey"$'\x1f'"$ro"]:-}" ] || empty=1
        elif [ "$ro" = all ]; then
          # $fo is already the slug PANEL_FAMILY was populated with
          # (data-family's tokens, per row_family_attr above) — no
          # slug->stem reverse lookup needed.
          [ -n "${PANEL_FAMILY["$panelkey"$'\x1f'"$fo"]:-}" ] || empty=1
        else
          [ -n "${PANEL_COMBO["$panelkey"$'\x1f'"$ro"$'\x1f'"$fo"]:-}" ] || empty=1
        fi
        [ "$empty" = 1 ] || continue

        local fr_sel="#fr-$ro:checked ~ "
        local fp_sel=""
        [ "${#children_of[@]}" -gt 0 ] && fp_sel="#fp-$fo:checked ~ "
        if [ "$panelkey" = pipeline ] || [ "$panelkey" = live ] || [ "$panelkey" = stale ]; then
          for pwin in "${WINDOWS[@]}"; do
            reveal_css+="#tl-$pwin:checked ~ #st-$panelkey:checked ~ $fr_sel$fp_sel main #panel-$panelkey .filtered-empty { display: block; }"$'\n'
          done
        else
          ptab="${panelkey%-*}"; pwin="${panelkey##*-}"
          reveal_css+="#tl-$pwin:checked ~ #st-$ptab:checked ~ $fr_sel$fp_sel main #panel-$ptab-$pwin .filtered-empty { display: block; }"$'\n'
        fi
      done
    done
  done

  # U7: the page is built from a QUOTED heredoc (<<'HTMLEOF', no shell
  # expansion at all) with @@TOKEN@@ placeholders, then each is substituted
  # via ${var//search/replace} — a literal string replacement, never
  # re-parsed for shell syntax. This is load-bearing, not stylistic: an
  # UNQUOTED heredoc (the original design) expands embedded backticks/
  # $(...) not per-variable but over the FULLY-SUBSTITUTED TEXT AS A
  # WHOLE — an odd backtick count in one task's title/prose (e.g. a
  # single, unpaired `` `code` `` mention) pairs across to the NEXT
  # backtick anywhere later in the page (a completely unrelated task's
  # content), and bash attempts to execute everything in between as a
  # command. U5's window-independent Pipeline tab surfaces enough real
  # prose that this fired for the first time against the live store
  # ("bad array subscript"-adjacent bug, found via wb-lifecycle's own
  # backtick-heavy conventions). Placeholder substitution closes this for
  # every current and future call site at once, not just today's data.
  local page_template
  page_template="$(cat <<'HTMLEOF'
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<title>&#9673; /board</title>
<meta name="viewport" content="width=device-width, initial-scale=1">
<script>
  /* No-FOUC theme toggle (mirrors docs/_templates/head.html; Decision 2A =
     a deliberate second copy). "auto" = no data-theme, falling back to the
     @media (prefers-color-scheme) block below. */
  (function () {
    try { var t = localStorage.getItem('theme');
          if (t === 'dark' || t === 'light') document.documentElement.dataset.theme = t; } catch (e) {}
    document.addEventListener('DOMContentLoaded', function () {
      var b = document.createElement('button');
      b.className = 'theme-toggle'; b.type = 'button';
      function lbl() { var c = document.documentElement.dataset.theme;
        b.textContent = c === 'dark' ? '◐ dark' : c === 'light' ? '○ light' : '◑ auto';
        b.setAttribute('aria-label', 'Theme: ' + (c || 'auto (system)') + ' — click to change'); }
      lbl();
      b.addEventListener('click', function () {
        var r = document.documentElement, c = r.dataset.theme;
        var n = c === 'dark' ? 'light' : c === 'light' ? '' : 'dark';
        try { if (n) { r.dataset.theme = n; localStorage.setItem('theme', n); }
              else { delete r.dataset.theme; localStorage.removeItem('theme'); } } catch (e) {}
        lbl();
      });
      document.body.appendChild(b);
    });
  })();
</script>
<style>
  /* Tokyo Night (dark) / Tokyo Night Day (light) — matches the docs Hub/guides.
     Status hues: doing=blue, review=yellow, planned=muted, done=green,
     paused=cyan, prospective=purple, unclassified=grey. */
  :root {
    --bg: #e1e2e7; --bg2: #d6d8df; --panel: #ffffff; --line: #b6b9c6;
    --ink: #2c2e40; --ink2: #4a4d5e; --mut: #8990b3;
    --acc: #2e7de9; --acc2: #007197;
    --doing: #2e7de9; --review: #8c6c3e; --planned: #8990b3; --done: #587539; --paused: #007197;
    --prospective: #7847bd;
    --unclassified: #6c7399; --ok: #587539;
    --mono: ui-monospace, "JetBrainsMono Nerd Font", "MesloLGL Nerd Font", "Cascadia Code", Menlo, Consolas, monospace;
    --sans: system-ui, "Segoe UI", Roboto, Ubuntu, sans-serif;
  }
  @media (prefers-color-scheme: dark) {
    :root { --bg: #1a1b26; --bg2: #16161e; --panel: #1f2335; --line: #2f3549; --ink: #c0caf5; --ink2: #9aa5ce; --mut: #565f89;
      --acc: #7aa2f7; --acc2: #7dcfff; --doing: #7aa2f7; --review: #e0af68; --planned: #737aa2; --done: #9ece6a; --paused: #7dcfff; --prospective: #bb9af7; --unclassified: #9aa5ce; --ok: #9ece6a; }
  }
  :root[data-theme="dark"] { --bg: #1a1b26; --bg2: #16161e; --panel: #1f2335; --line: #2f3549; --ink: #c0caf5; --ink2: #9aa5ce; --mut: #565f89;
    --acc: #7aa2f7; --acc2: #7dcfff; --doing: #7aa2f7; --review: #e0af68; --planned: #737aa2; --done: #9ece6a; --paused: #7dcfff; --prospective: #bb9af7; --unclassified: #9aa5ce; --ok: #9ece6a; }
  :root[data-theme="light"] { --bg: #e1e2e7; --bg2: #d6d8df; --panel: #ffffff; --line: #b6b9c6; --ink: #2c2e40; --ink2: #4a4d5e; --mut: #8990b3;
    --acc: #2e7de9; --acc2: #007197; --doing: #2e7de9; --review: #8c6c3e; --planned: #8990b3; --done: #587539; --paused: #007197; --prospective: #7847bd; --unclassified: #6c7399; --ok: #587539; }

  * { box-sizing: border-box; }
  html { color-scheme: light dark; scroll-behavior: smooth; }
  body { background: var(--bg); color: var(--ink); font-family: var(--sans); margin: 0; font-size: 15px; line-height: 1.5; }
  input[type=radio] { display: none; }
  header { padding: 1.2rem 1.5rem; border-bottom: 1px solid var(--line); background: var(--bg2); position: sticky; top: 0; z-index: 5; }
  header h1 { font-family: var(--mono); font-size: 1.1rem; margin: 0; }
  .board-head { display: flex; align-items: baseline; gap: 1rem; flex-wrap: wrap; margin-bottom: .8rem; }
  .board-nav { display: flex; gap: .9rem; font-family: var(--mono); font-size: .78rem; }
  .board-nav a { color: var(--acc2); text-decoration: none; }
  .board-nav a:hover { text-decoration: underline; }
  .board-foot { max-width: min(1560px, 95vw); margin: 2rem auto 0; padding: 1.2rem 1.5rem; border-top: 1px solid var(--line); color: var(--mut); font-family: var(--mono); font-size: .78rem; }
  .board-foot a { color: var(--acc2); text-decoration: none; }
  .theme-toggle { position: fixed; bottom: 1rem; right: 1rem; z-index: 50; font-family: var(--mono); font-size: .72rem; padding: .35rem .7rem; background: var(--panel); color: var(--ink2); border: 1px solid var(--line); border-radius: 999px; cursor: pointer; box-shadow: 0 2px 10px -4px color-mix(in srgb, var(--ink) 40%, transparent); }
  .theme-toggle:hover { border-color: var(--acc); color: var(--ink); }
  .theme-toggle:focus-visible { outline: 2px solid var(--acc); outline-offset: 2px; }
  .tabs { display: flex; gap: .5rem; flex-wrap: wrap; align-items: center; justify-content: space-between; }
  .tabs-left { display: flex; gap: .5rem; flex-wrap: wrap; align-items: center; flex: 1 1 auto; min-width: 0; }
  .tabgroup { display: flex; gap: .25rem; background: var(--panel); border: 1px solid var(--line); border-radius: 8px; padding: .25rem; flex-wrap: wrap; }
  .tabgroup label { font-family: var(--mono); font-size: .78rem; padding: .35rem .8rem; border-radius: 6px; cursor: pointer; color: var(--ink2); }
  .tabgroup-label { font-family: var(--mono); font-size: .62rem; text-transform: uppercase; letter-spacing: .08em; color: var(--mut); align-self: center; padding: 0 .35rem 0 .15rem; }
  /* U7: window segmented control — same tabgroup styling, visually
     separated from the tab row (R12) by header-level flex gap/order. */
  .tabgroup.window-control { order: -1; }
  /* B4: the Today/This-week window filter only affects the Status bucket
     tabs; on the window-independent views (Pipeline/Live/Stale) it does
     nothing, so dim + disable it there rather than leave an inert control
     looking live. Pipeline is the default tab, so it starts dimmed. */
  #st-pipeline:checked ~ header .window-control,
  #st-live:checked ~ header .window-control,
  #st-stale:checked ~ header .window-control { opacity: .4; pointer-events: none; }
  .stage-legend { font-family: var(--mono); font-size: .74rem; color: var(--mut); margin: 0 0 .2rem; }
  .stage-legend b { color: var(--ink2); }
  /* U7: repo/family filters — always the far-right cluster. margin-left:
     auto is a belt-and-suspenders fallback for when .tabs wraps and
     .header-controls ends up alone on its own line. */
  .header-controls { display: flex; gap: .5rem; margin-left: auto; align-items: center; flex-wrap: nowrap; flex: 0 0 auto; }
  /* Same outer gutter as .tabgroup (.25rem wrapper + .35rem inner padding)
     so a filter dropdown renders the same overall size as a tabgroup pill. */
  .filter-dropdown { position: relative; background: var(--panel); border: 1px solid var(--line); border-radius: 8px; padding: .25rem; }
  .filter-dropdown summary { font-family: var(--mono); font-size: .78rem; padding: .35rem .8rem; cursor: pointer; color: var(--ink2); list-style: none; }
  .filter-dropdown summary::-webkit-details-marker { display: none; }
  .filter-dropdown .filter-label { display: none; white-space: nowrap; }
  .filter-dropdown .filter-label[data-for="all"] { display: inline; }
  .filter-dropdown .filter-options { position: absolute; right: 0; top: 100%; margin-top: .3rem; background: var(--panel); border: 1px solid var(--line); border-radius: 8px; padding: .3rem; display: flex; flex-direction: column; gap: .1rem; z-index: 6; min-width: 8rem; }
  .filter-dropdown .filter-options label { font-family: var(--mono); font-size: .78rem; padding: .3rem .6rem; border-radius: 6px; cursor: pointer; color: var(--ink2); white-space: nowrap; }
  .filter-dropdown .filter-options label:hover { background: var(--bg2); }
  .dormant-toggle { display: flex; align-items: center; gap: .35rem; background: var(--panel); border: 1px solid var(--line); border-radius: 8px; padding: .35rem .8rem; font-family: var(--mono); font-size: .78rem; color: var(--ink2); cursor: pointer; white-space: nowrap; }
  .dormant-toggle input { cursor: pointer; }

  main { padding: 1.5rem; max-width: min(1560px, 95vw); margin: 0 auto; }
  .view { display: none; flex-direction: column; gap: 2.2rem; min-width: 0; }
  .table-wrap { overflow-x: auto; min-width: 0; }
  table { width: auto; border-collapse: collapse; background: var(--panel); border: 1px solid var(--line); border-radius: 8px; overflow: hidden; }
  th { text-align: left; font-family: var(--mono); font-size: .72rem; text-transform: uppercase; letter-spacing: .05em; color: var(--mut); padding: .85rem 1.2rem; border-bottom: 1px solid var(--line); white-space: nowrap; }
  th.sortable { cursor: pointer; user-select: none; }
  th.sortable:hover { color: var(--acc2); }
  th.sortable::after { content: " \21C5"; opacity: .5; font-size: .85em; }
  td { padding: 1rem 1.2rem; border-bottom: 1px solid var(--line); font-size: .9rem; white-space: nowrap; }
  tr:last-child td { border-bottom: none; }
  tr.row:hover { background: var(--bg2); }
  tr.row.blocked { opacity: .82; }
  tr.row.blocked td:first-child { box-shadow: inset 3px 0 var(--review); }
  td a.tasklink { color: var(--acc2); text-decoration: none; font-weight: 600; }
  td a.tasklink:hover { text-decoration: underline; }
  .task-cell { display: flex; flex-direction: column; align-items: flex-start; gap: .3rem; }
  .pill { display: inline-flex; align-items: center; gap: .35em; font-family: var(--mono); font-size: .72rem; padding: .2em .7em; border-radius: 999px; border: 1px solid currentColor; }
  .pill.doing { color: var(--doing); } .pill.review { color: var(--review); } .pill.planned { color: var(--planned); } .pill.done { color: var(--done); } .pill.paused { color: var(--paused); } .pill.prospective { color: var(--prospective); } .pill.unclassified { color: var(--unclassified); }
  .repo { font-family: var(--mono); font-size: .78rem; color: var(--mut); }
  .live-badge { display: inline-flex; align-items: center; gap: .35em; font-family: var(--mono); font-size: .7rem; color: var(--ok); }
  .empty-state { padding: 1.6rem; text-align: center; color: var(--mut); font-family: var(--mono); font-size: .85rem; background: var(--panel); border: 1px dashed var(--line); border-radius: 8px; }
  .stage-cell { text-align: center; font-size: 1rem; color: var(--mut); }
  .stage-cell.na { opacity: .4; }
  .stage-cell.pending { color: var(--ink); }
  .stage-cell.progress { color: var(--doing); font-weight: 600; }
  .stage-cell.done { color: var(--ok); }
  .stage-cell a { color: inherit; text-decoration: none; border-bottom: 1px dotted currentColor; }
  .dep-chip { display: inline-flex; align-items: center; font-family: var(--mono); font-size: .72rem; padding: .05em .5em; border-radius: 999px; border: 1px solid currentColor; margin-right: .2em; }
  .dep-chip.blocked { color: var(--review); }
  .dep-chip.unblocks { color: var(--acc2); }
  .dep-chip.warn { color: var(--review); border-style: dashed; }

  .details-heading { font-family: var(--mono); font-size: .78rem; text-transform: uppercase; letter-spacing: .05em; color: var(--mut); border-bottom: 1px solid var(--line); padding-bottom: .5rem; margin: 0; }
  .details-stack { display: flex; flex-direction: column; gap: .8rem; }
  .task-detail { background: var(--panel); border: 1px solid var(--line); border-radius: 8px; padding: 1rem 1.2rem; scroll-margin-top: 8rem; }
  /* U7 KTD-7: a repo/family filter must never dead-end an in-panel
     anchor — :target always wins over any filter's `display: none`. */
  .task-detail:target { border-color: var(--acc); box-shadow: 0 0 0 3px color-mix(in srgb, var(--acc) 25%, transparent); display: block !important; }
  /* U7 KTD-8: per-panel placeholder for a filter combination that empties
     an otherwise non-empty panel — hidden by default, revealed only by a
     generated reveal rule (never by the panel's own natural emptiness,
     which uses the plain .empty-state div declared alongside it instead). */
  .filtered-empty { display: none; }
  .task-detail h3 { margin: 0 0 .3rem; font-size: 1rem; display: flex; align-items: center; gap: .6rem; flex-wrap: wrap; }
  .task-detail .back { font-family: var(--mono); font-size: .74rem; color: var(--acc2); text-decoration: none; margin-left: auto; }
  .task-detail p { margin: .4rem 0; font-size: .87rem; color: var(--ink2); }
  .task-detail p b { color: var(--ink); }
  .task-detail.untracked { border-style: dashed; }
  .artefact-chip { display: inline-flex; font-family: var(--mono); font-size: .74rem; background: var(--bg2); border: 1px solid var(--line); border-radius: 999px; padding: .1em .6em; margin-right: .3em; color: var(--ink2); text-decoration: none; }
  a.artefact-chip:hover { border-color: var(--acc2); color: var(--acc2); }
  .task-detail details.parent-row > summary { cursor: pointer; list-style: none; display: flex; align-items: center; gap: .6rem; flex-wrap: wrap; }
  .task-detail details.parent-row > summary::-webkit-details-marker { display: none; }
  .task-detail details.parent-row > summary h3 { margin: 0; }
  .task-detail details.parent-row .own-count { font-size: .78rem; color: var(--mut); margin-left: auto; white-space: nowrap; }
  .task-detail .children { margin: .6rem 0 0; padding-left: 1rem; border-left: 2px solid var(--line); display: flex; flex-direction: column; gap: .4rem; }
  .task-detail .child-row { font-size: .87rem; color: var(--ink2); display: flex; align-items: center; gap: .5rem; flex-wrap: wrap; }
  .task-detail .children .pill { font-size: .68rem; }
  .task-detail details.parent-row details { margin-top: .6rem; }
  .task-detail details.parent-row details summary { cursor: pointer; color: var(--acc2); font-family: var(--mono); font-size: .78rem; list-style: none; }
  .task-detail details.parent-row details summary::-webkit-details-marker { display: none; }

  /* U6: two-zone card head (identity left, lane-meta + back top-right) */
  .card-head { display: flex; align-items: flex-start; gap: .6rem; flex-wrap: wrap; width: 100%; }
  .card-head .identity { flex: 1 1 auto; min-width: 0; }
  .card-head .identity h3 { margin: 0 0 .2rem; font-size: 1rem; display: flex; align-items: center; gap: .5rem; flex-wrap: wrap; }
  .meta-line { font-family: var(--mono); font-size: .78rem; color: var(--mut); }
  .card-head .lane-meta { display: flex; align-items: center; gap: .5rem; flex-wrap: wrap; }
  .wt-indicator { font-size: .9rem; color: var(--mut); }
  .card-head .back { font-family: var(--mono); font-size: .74rem; color: var(--acc2); text-decoration: none; margin-left: auto; }

  /* U6: stepper — glyph-over-label segments in path order */
  .stepper { display: flex; gap: .9rem; margin: .7rem 0; flex-wrap: wrap; }
  .step { display: flex; flex-direction: column; align-items: center; gap: .15rem; font-size: .72rem; color: var(--mut); min-width: 3rem; }
  .step.pending { color: var(--mut); }
  .step.progress { color: var(--doing); font-weight: 600; }
  .step.done { color: var(--ok); }
  .step .glyph { font-size: 1.15rem; }
  .step .glyph a { color: inherit; text-decoration: none; border-bottom: 1px dotted currentColor; }
  .step .label { font-family: var(--mono); font-size: .64rem; text-transform: uppercase; letter-spacing: .03em; }
  .step-chips { margin-top: .25rem; }
  .mini-stepper { display: flex; gap: .5rem; flex-wrap: wrap; margin-top: .25rem; width: 100%; }
  .mini-step { font-family: var(--mono); font-size: .68rem; color: var(--mut); }
  .mini-step.pending { color: var(--ink); font-weight: 600; }
  .mini-step.progress { color: var(--doing); font-weight: 600; }
  .mini-step.done { color: var(--ok); }

  /* U6: dependency/rollup indicators */
  .deps-chips { margin: .4rem 0; }
  .children-counter { font-size: .78rem; color: var(--mut); margin-left: auto; white-space: nowrap; }
  .ready-hint { font-size: .74rem; color: var(--ok); margin-left: .5rem; white-space: nowrap; }

  /* U9: Key Findings — board-global, sits outside every .view so no
     repo/family filter rule (which only ever targets `.view` descendants)
     can reach it (R22). */
  .key-findings { background: var(--panel); border: 1px solid var(--line); border-radius: 8px; padding: 1.2rem 1.5rem; }
  .key-findings h2 { font-family: var(--mono); font-size: .95rem; margin: 0 0 .8rem; display: flex; align-items: center; gap: .6rem; flex-wrap: wrap; }
  .kf-tag { font-size: .7rem; font-weight: normal; color: var(--mut); text-transform: uppercase; letter-spacing: .04em; }
  .kf-item { margin: .6rem 0; font-size: .87rem; }
  .kf-item ul { margin: .3rem 0 0; padding-left: 1.2rem; }
  .kf-item li { margin: .15rem 0; }
  .kf-item a { color: var(--acc2); text-decoration: none; }
  .kf-empty { color: var(--mut); font-family: var(--mono); font-size: .85rem; margin: 0; }
  @@PANEL_CSS@@
  @@HIGHLIGHT_CSS@@
  @@REPO_HIDE_CSS@@
  @@REPO_SUMMARY_CSS@@
  @@FAMILY_HIDE_CSS@@
  @@FAMILY_SUMMARY_CSS@@
  @@DORMANT_HIDE_CSS@@
  @@REVEAL_CSS@@
</style>
</head>
<body>
@@RADIOS_HTML@@
<header>
  <div class="board-head">
    <h1>&#9673; /board</h1>
    @@LIVE_AGENTS_HTML@@
    <nav class="board-nav"><a href="../docs/HUB.html">⌂ Hub</a><a href="../docs/wb-guide.html">wb guide</a><a href="../docs/roadmap.html">roadmap</a></nav>
  </div>
  <div class="tabs">
    <div class="tabs-left">
      <div class="tabgroup window-control">@@WIN_HTML@@</div>
      <div class="tabgroup tabs-row views"><span class="tabgroup-label">views</span>@@TABS_HTML@@</div>
      <div class="tabgroup tabs-row statuses"><span class="tabgroup-label">status</span>@@STATUS_TABS_HTML@@</div>
    </div>
    <div class="header-controls">
      <details class="filter-dropdown repo-filter"><summary>@@REPO_SUMMARY_LABELS@@</summary><div class="filter-options">@@REPO_OPTIONS_HTML@@</div></details>
      @@FAMILY_DROPDOWN_HTML@@
      @@DORMANT_TOGGLE_HTML@@
    </div>
  </div>
</header>
<main>
@@PANELS_HTML@@
@@KEY_FINDINGS_HTML@@
</main>
<footer class="board-foot">Part of the <a href="../docs/HUB.html">personal-workflow docs</a> &middot; <a href="../docs/wb-guide.html">wb guide</a> &middot; <a href="../docs/roadmap.html">roadmap</a> &middot; regenerate with <code>wb board --html</code></footer>
<script>
// The board is otherwise entirely CSS-only (see wb_board_render_html's
// header comment) -- this is a deliberate, explicit exception for
// click-to-sort, not an accidental one. Fully static, offline, no
// dependency, no network call; every row already carries the data-repo/
// data-status attributes this reads (populated alongside data-family for
// the U7 filters), so this adds zero new markup weight per row.
document.querySelectorAll('th[data-sort]').forEach(function (th) {
  th.addEventListener('click', function () {
    var table = th.closest('table');
    var rows = Array.from(table.querySelectorAll('tr.row'));
    var key = th.dataset.sort;
    rows.sort(function (a, b) {
      return (a.dataset[key] || '').localeCompare(b.dataset[key] || '');
    });
    rows.forEach(function (r) { table.appendChild(r); });
  });
});
// Persist the last-selected view/status tab across reloads (localStorage, the
// same store the theme toggle uses). The tabs are otherwise CSS-only radios
// that reset to the default (Pipeline) on every reload/regen; this restores
// the one you left on. Same deliberate-exception rationale as the sort above.
(function () {
  var KEY = 'wb-board-tab';
  try {
    var saved = localStorage.getItem(KEY);
    if (saved) { var el = document.getElementById(saved); if (el) el.checked = true; }
  } catch (e) {}
  document.querySelectorAll('input[name="st"]').forEach(function (r) {
    r.addEventListener('change', function () {
      try { if (r.checked) localStorage.setItem(KEY, r.id); } catch (e) {}
    });
  });
})();
</script>
</body>
</html>
HTMLEOF
)"
  page_template="${page_template//@@PANEL_CSS@@/$(wb_board_escape_replacement "$panel_css")}"
  page_template="${page_template//@@HIGHLIGHT_CSS@@/$(wb_board_escape_replacement "$highlight_css")}"
  page_template="${page_template//@@REPO_HIDE_CSS@@/$(wb_board_escape_replacement "$repo_hide_css")}"
  page_template="${page_template//@@REPO_SUMMARY_CSS@@/$(wb_board_escape_replacement "$repo_summary_css")}"
  page_template="${page_template//@@FAMILY_HIDE_CSS@@/$(wb_board_escape_replacement "$family_hide_css")}"
  page_template="${page_template//@@FAMILY_SUMMARY_CSS@@/$(wb_board_escape_replacement "$family_summary_css")}"
  page_template="${page_template//@@DORMANT_HIDE_CSS@@/$(wb_board_escape_replacement "$dormant_hide_css")}"
  page_template="${page_template//@@REVEAL_CSS@@/$(wb_board_escape_replacement "$reveal_css")}"
  page_template="${page_template//@@RADIOS_HTML@@/$(wb_board_escape_replacement "$radios_html")}"
  page_template="${page_template//@@LIVE_AGENTS_HTML@@/$(wb_board_escape_replacement "$live_agents_html")}"
  page_template="${page_template//@@WIN_HTML@@/$(wb_board_escape_replacement "$win_html")}"
  page_template="${page_template//@@TABS_HTML@@/$(wb_board_escape_replacement "$tabs_html")}"
  page_template="${page_template//@@STATUS_TABS_HTML@@/$(wb_board_escape_replacement "$status_tabs_html")}"
  page_template="${page_template//@@REPO_SUMMARY_LABELS@@/$(wb_board_escape_replacement "$repo_summary_labels")}"
  page_template="${page_template//@@REPO_OPTIONS_HTML@@/$(wb_board_escape_replacement "$repo_options_html")}"
  page_template="${page_template//@@FAMILY_DROPDOWN_HTML@@/$(wb_board_escape_replacement "$family_dropdown_html")}"
  page_template="${page_template//@@DORMANT_TOGGLE_HTML@@/$(wb_board_escape_replacement "$dormant_toggle_html")}"
  page_template="${page_template//@@PANELS_HTML@@/$(wb_board_escape_replacement "$panels_html")}"
  page_template="${page_template//@@KEY_FINDINGS_HTML@@/$(wb_board_escape_replacement "$key_findings_html")}"
  printf '%s\n' "$page_template"
}


# ===========================================================================
# board2 (feat-board-build, U2) — single-pass collect + in-memory model for
# the ratified 3-view renderer (wb_board_render_v2, U3). Deliberately a NEW
# collect path, not an extension of wb_board_collect_rows above: that
# function's 15-field TSV is a public-ish contract for the OLD renderer
# (wb_board_render_html), which stays live and untouched until D1's parity
# check passes (U4) — this section, and everything under it, is additive.
# ===========================================================================

# wb_board_v2_anchor <stem> — same sanitization as wb_board_anchor_slug
# (every char outside [A-Za-z0-9_-] -> '-'), but pure bash parameter
# expansion instead of that function's `printf | tr` pipe. Not a style
# preference: this runs once per task in board2's single-pass loop (~300
# files on the real store today), and the pipe's two forks per call were
# real, measured cost — see the timing note on wb_board_collect_rows_v2
# below. Verified byte-identical to wb_board_anchor_slug's output for every
# character class it handles (ASCII, punctuation, empty string).
wb_board_v2_anchor() { printf '%s' "${1//[^A-Za-z0-9_-]/-}"; }

# wb_board_v2_age_days <mtime_epoch> <now_epoch> — whole days between them,
# R21's staleness clock. Floor division (bash integer arithmetic), so
# "13d 23h" reports as 13, not 14 — matches the U2 test scenario's 13d/14d
# boundary ("13d does not [classify stale]"). Takes <now_epoch> as a
# parameter rather than calling `date +%s` itself: the collect loop below
# forks `date` exactly once for the whole pass and passes it in, not once
# per task (a real, measured cost at ~300 files — see the timing note on
# wb_board_collect_rows_v2).
wb_board_v2_age_days() {
  echo $(( ("$2" - "$1") / 86400 ))
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
  local status="$1" age_days="$2"
  if [ "$status" = doing ] || [ "$status" = review ]; then
    if [ "$age_days" -ge 14 ]; then printf 'stale'; else printf 'active'; fi
  else
    printf 'shelved'
  fi
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
# hand-parsed at a call site): 5 fields joined by a bare SOH byte (\001, a
# byte that cannot appear in a markdown task file's prose, so no escaping
# is ever needed) — field order is fixed, not labeled, since the caller
# always wants all five:
#   1 the frontmatter/plan-count TSV line: status \t repo \t worktree \t
#     branch \t path \t deps \t reviewed \t parent \t tags \t created \t
#     closed \t plan_checked \t plan_total \t title
#   2 raw Plan section text
#   3 raw Done section text
#   4 raw Handoff text — the LAST "### " block under "## Handoffs" (heading
#     line included)
#   5 raw Follow-ups section text
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
    BEGIN {
      SOH = sprintf("%c", 1)
      status=""; repo=""; worktree=""; branch=""; path=""; deps=""
      reviewed=""; parent=""; tags=""; created=""; closed=""; title=""
      infm = 0; donefm = 0; cursec = ""; handoff_capturing = 0; title_found = 0
      plan_checked = 0; plan_total = 0
    }
    # wb_task_title <file> equivalent (first "# <heading>" line anywhere in
    # the file, single "#" only — "## Plan" etc. never match) — folded in
    # here so the collect loop below doesn'\''t fork a second awk per file
    # just for the title.
    !title_found && /^# / { title = $0; sub(/^# /, "", title); title_found = 1 }
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
    donefm && cursec == "Handoffs" {
      if ($0 ~ /^### /) { handoff_text = $0 "\n"; handoff_capturing = 1; next }
      if (handoff_capturing) { handoff_text = handoff_text $0 "\n" }
      next
    }
    END {
      printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s", \
        status, repo, worktree, branch, path, deps, reviewed, parent, tags, \
        created, closed, plan_checked, plan_total, title
      printf "%s%s%s%s%s%s%s%s%s", SOH, plan_text, SOH, done_text, SOH, handoff_text, SOH, followups_text, ""
    }
  ' "$1"
}

# wb_board_v2_parse_record <record_text> <scalar_array_name> \
#   <plan_array_name> <done_array_name> <handoff_array_name> \
#   <followups_array_name> — splits one wb_board_v2_read_file capture on its
# 5 bare-SOH-joined fields into <scalar_array_name>[0] (the TSV header
# line, further split by the caller with wb_tsv_split) and the four
# body-text arrays. Pure string manipulation, no forking, no file I/O — the
# read already happened.
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
  local soh=$'\1'
  local -a parts=()
  IFS="$soh" read -r -d '' -a parts <<< "$1" || true
  _pr_scalar[0]="${parts[0]:-}"
  _pr_plan[0]="${parts[1]:-}"; _pr_done[0]="${parts[2]:-}"
  _pr_handoff[0]="${parts[3]:-}"; _pr_followups[0]="${parts[4]:-}"
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
#   <handoff_arrayname> <followups_arrayname> — one pass over $TASKS_DIR/*.md
# (wb_task_files), one wb_board_v2_read_file fork per file, no tmux/gh/git
# calls (R16). Pushes one TSV row per task into <rows_arrayname> (never
# printed to stdout — see the call-convention note below) with fields:
#   1 stem  2 status  3 repo  4 branch  5 worktree  6 title  7 created
#   8 closed  9 updated(mtime epoch)  10 taskfile  11 anchor  12 parent(stem,
#   self-ref guarded)  13 depends_on(raw)  14 tags(raw frontmatter value —
#   parse with _wb_tags_parse, D3 residual)  15 plan_checked  16 plan_total
#   17 age_days  18 bucket(active|stale|shelved)
# and, in the SAME loop iteration (never a second pass/re-read over the file
# list — R16), fills the four text-block arrays keyed by stem with the raw
# Plan/Done/Handoff/Follow-ups section text wb_board_v2_read_file already
# captured for that file.
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
# R15 budget — verify with `time wb board2` before extending this further.
wb_board_collect_rows_v2() {
  local -n _cr_rows="$1" _cr_plan="$2" _cr_done="$3" _cr_handoff="$4" _cr_followups="$5"
  local -A _mtimes=()
  wb_board_v2_mtimes _mtimes
  local now; now="$(date +%s)"
  local f stem anchor parent title updated age_days bucket record
  local -a scalar=() t=() plan_a=() done_a=() handoff_a=() followups_a=()
  while IFS= read -r f; do
    [ -f "$f" ] || continue
    record="$(wb_board_v2_read_file "$f")"
    wb_board_v2_parse_record "$record" scalar plan_a done_a handoff_a followups_a
    wb_tsv_split "${scalar[0]}" t
    # t: 0 status 1 repo 2 worktree 3 branch 4 path 5 deps 6 reviewed
    #    7 parent 8 tags 9 created 10 closed 11 plan_checked 12 plan_total
    #    13 title
    stem="${f##*/}"; stem="${stem%.md}"
    anchor="$(wb_board_v2_anchor "$stem")"
    parent="${t[7]:-}"
    wb_task_own_parent "$parent" "$stem" || parent=""
    title="${t[13]:-}"; [ -n "$title" ] || title="$stem"
    updated="${_mtimes["$f"]:-0}"
    age_days="$(wb_board_v2_age_days "$updated" "$now")"
    bucket="$(wb_board_v2_bucket "${t[0]:-}" "$age_days")"
    _cr_plan["$stem"]="${plan_a[0]}"
    _cr_done["$stem"]="${done_a[0]}"
    _cr_handoff["$stem"]="${handoff_a[0]}"
    _cr_followups["$stem"]="${followups_a[0]}"
    _cr_rows+=("$(printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s' \
      "$stem" "${t[0]:-}" "${t[1]:-}" "${t[3]:-}" "${t[2]:-}" "$title" "${t[9]:-}" "${t[10]:-}" \
      "$updated" "$f" "$anchor" "$parent" "${t[5]:-}" "${t[8]:-}" "${t[11]:-0}" "${t[12]:-0}" \
      "$age_days" "$bucket")")
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
#   local -A M_PLAN_RAW=() M_DONE_RAW=() M_HANDOFF_RAW=() M_FOLLOWUPS_RAW=()
#   wb_board_collect_rows_v2 V2ROWS M_PLAN_RAW M_DONE_RAW M_HANDOFF_RAW M_FOLLOWUPS_RAW
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
    _handoff_summary["$stem"]="$(wb_board_first_nonblank_line "${_bm_handoff["$stem"]:-}")"
  done

  # Family roots + children map, from STEM_PARENT (just populated above).
  for stem in "${!_stem_anchor[@]}"; do
    _family_root["$stem"]="$(wb_board_v2_family_root "$stem" _stem_parent)"
    if [ -n "${_stem_parent["$stem"]:-}" ]; then
      _family_children["${_stem_parent["$stem"]}"]+="$stem"$'\n'
    fi
  done
}
