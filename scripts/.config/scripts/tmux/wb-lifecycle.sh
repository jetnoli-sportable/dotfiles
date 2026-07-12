#!/usr/bin/env bash
# wb-lifecycle.sh — lifecycle-stage pipeline detection for `wb board --html`.
# Sourced by wb.sh (wb.sh:28-29) the same way wb.sh sources lib.sh — a
# sibling module, not inline in wb.sh/cmd_board, following this file's own
# convention for indirection points that need independent testing
# (wb_reconcile_repos, wb_repo_dir).
#
# 8 independent yes/no signals for how far a task has gotten through
# ideate -> plan -> build -> review -> ship (design: docs/plans/2026-07-11-
# 001-feat-wb-board-lifecycle-plan.md; detection rationale: logs/decisions/
# 2026-07-11-wb-board-lifecycle-detection.md; the board-display-v2 plan,
# docs/plans/2026-07-12-001-feat-wb-board-display-plan.md, adds signal 8 and
# hardens 3/4 — R6/R7/R8/R27):
#   1. worktree exists       wb_lifecycle_has_worktree
#   2. live agent             wb_lifecycle_has_live_agent
#   3. /ce-plan done           wb_lifecycle_has_plan
#   4. /ce-brainstorm done     wb_lifecycle_has_brainstorm
#   5. /ce-work done           wb_lifecycle_work_done
#   6. /ce-code-review done    wb_lifecycle_review_done
#   7. live PR                 wb_lifecycle_pr_is_live
#   8. /ce-ideate done         wb_lifecycle_has_ideate
#
# The stage-state resolver (wb_lifecycle_stage_state — four-state model:
# n/a/pending/progress/done, composing these boolean signals with the
# `path:` intent field) and wb_board_render_html's wiring both live in
# wb.sh, not here — this module stays detection-only.
#
# All signals take plain repo/branch/worktree/taskfile values already
# available in wb_board_render_html's per-row loop — no new global state,
# and no new network call (signal 7 reuses the $pr_info wb_board_render_html
# already computes via wb_board_pr_info). Boolean predicates return via exit
# code (0 = true, 1 = false), matching this codebase's existing convention
# (wb_task_own_parent, wb.sh:145; wb_worktree_has_task, wb.sh:444) rather
# than printing "true"/"false".

# ---------------------------------------------------------------------------
# signal 1: worktree exists
# ---------------------------------------------------------------------------

# wb_lifecycle_has_worktree <repo> <worktree_rel> — same presence check
# cmd_reconcile's missing-worktree detection uses (wb.sh:478).
wb_lifecycle_has_worktree() {
  local repo="${1:-}" worktree="${2:-}"
  [ -d "$(wb_repo_dir "$repo")/$worktree" ]
}

# ---------------------------------------------------------------------------
# signal 2: live agent
# ---------------------------------------------------------------------------

# wb_lifecycle_has_live_agent <repo> <branch> — true only when a real
# `claude` pane is running in the task's session, not merely when the
# session exists (a session can hold only an nvim/shell window with no
# agent actually running). Reuses wb_board_live_session_for (wb.sh:943) to
# find the session, then tmux_claude_panes (lib.sh:99) — the same detection
# claude-sessions.sh already relies on — scoped to that one session.
wb_lifecycle_has_live_agent() {
  local repo="${1:-}" branch="${2:-}" session
  session="$(wb_board_live_session_for "$repo" "$branch")"
  [ -n "$session" ] || return 1
  [ -n "$(tmux_claude_panes "$session")" ]
}

# ---------------------------------------------------------------------------
# signals 3/4/8: /ce-plan, /ce-brainstorm, /ce-ideate done
# ---------------------------------------------------------------------------

# wb_lifecycle_doc_dirs_for_kind <kind> — which docs/ subdirectories count as
# candidates for stage <kind> (plans|brainstorms|ideation). "brainstorms"
# scans its own legacy directory AND docs/plans/ — ce-brainstorm's current
# output format is a requirements-only *plan* file (R8), discriminated by
# frontmatter rather than location, not a separate docs/brainstorms/ file.
wb_lifecycle_doc_dirs_for_kind() {
  case "$1" in
    brainstorms) printf '%s\n' brainstorms plans ;;
    *)           printf '%s\n' "$1" ;;
  esac
}

# wb_lifecycle_doc_qualifies <kind> <artifact_readiness> <product_contract_source>
# — the R8 discriminator: only meaningful for a docs/plans/ candidate (the
# one directory two different kinds can both match), so callers only invoke
# this when the candidate's directory is "plans". A docs/plans/ file counts
# for "plans" unless it's still requirements-only (a brainstorm output that
# hasn't been deepened yet); it counts for "brainstorms" only when it
# carries the ce-brainstorm source field (the field persists through later
# enrichment, so brainstorm-done never regresses once true). Legacy plans
# with neither field: plans=true (readiness unset != requirements-only),
# brainstorms=false (source unset != ce-brainstorm) — ordinary plans never
# fire the brainstorm signal.
wb_lifecycle_doc_qualifies() {
  local kind="$1" readiness="$2" source="$3"
  case "$kind" in
    plans)       [ "$readiness" != "requirements-only" ] ;;
    brainstorms) [ "$source" = "ce-brainstorm" ] ;;
    *)           return 0 ;;
  esac
}

# wb_lifecycle_has_doc <repo> <branch> <worktree_rel> <taskfile> <kind> —
# shared implementation for wb_lifecycle_has_plan/has_brainstorm/has_ideate
# (kind selects the docs/ subdirectory set via wb_lifecycle_doc_dirs_for_kind).
# Guards first, per the plan's Key Technical Decisions — on the field VALUES,
# never on a composed path (an empty worktree: would otherwise degenerate
# `$repo_dir/$worktree` to the repo dir itself, which exists, and silently
# scan the main checkout as if it were this task's own worktree; an empty
# branch: would make the glob-match fragment "", substring-matching every
# filename in the directory):
#   - empty branch: -> not-found (R27, AE8).
#   - empty worktree: -> not-found (AE8) — this task never had one; distinct
#     from a worktree whose directory is merely gone (handled below).
# Then two independent, cheap checks, OR-ed together (neither alone is
# reliable in practice against this repo's currently-open lanes — see the
# plan's Key Technical Decisions), run in one of two modes:
#   - live (worktree directory exists): glob a docs/<dir>/*.md|*.html file
#     whose filename contains the branch's sanitized form, OR prose-match
#     via wb_board_doc_candidates re-rooted at the worktree.
#   - kept-branch fallback (worktree directory gone, R6/AE3): the same two
#     checks against git objects on the kept branch instead — `git ls-tree`
#     for the filename listing, `git cat-file -e`/`git show` for prose-path
#     existence and content. Never hard-fails on a git error (mirrors
#     wb_lifecycle_work_done's convention): a deleted branch just falls
#     through to the final `return 1`.
# The R8 discriminator (wb_lifecycle_doc_qualifies) is applied to every
# docs/plans/ candidate in both modes and both halves before it can win the
# match — the glob half used to fire on any filename hit with no frontmatter
# read at all, which would call a requirements-only brainstorm output
# plan-done.
wb_lifecycle_has_doc() {
  local repo="${1:-}" branch="${2:-}" worktree="${3:-}" taskfile="${4:-}" kind="${5:-}"
  [ -n "$branch" ] || return 1
  [ -n "$worktree" ] || return 1

  local repo_dir; repo_dir="$(wb_repo_dir "$repo")"
  local wt="$repo_dir/$worktree"
  local frag; frag="$(wb_sanitize "$branch")"
  local live=1
  [ -d "$wt" ] || live=0
  if [ "$live" = 0 ]; then
    git -C "$repo_dir" cat-file -e "$branch" 2>/dev/null || return 1
  fi

  local dir f candidate content readiness source
  while IFS= read -r dir; do
    [ -n "$dir" ] || continue

    # --- glob half -----------------------------------------------------
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
              return 0
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
            return 0
            ;;
        esac
      done < <(git -C "$repo_dir" ls-tree -r --name-only "$branch" -- "docs/$dir" 2>/dev/null)
    fi

    # --- prose half ------------------------------------------------------
    while IFS= read -r candidate; do
      [ -n "$candidate" ] || continue
      case "$candidate" in
        "docs/$dir/"*) : ;;
        *) continue ;;
      esac
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
      return 0
    done < <(wb_board_doc_candidates "$taskfile")
  done < <(wb_lifecycle_doc_dirs_for_kind "$kind")

  return 1
}

# wb_lifecycle_has_plan <repo> <branch> <worktree_rel> <taskfile>
wb_lifecycle_has_plan() { wb_lifecycle_has_doc "$1" "$2" "$3" "$4" plans; }

# wb_lifecycle_has_brainstorm <repo> <branch> <worktree_rel> <taskfile>
wb_lifecycle_has_brainstorm() { wb_lifecycle_has_doc "$1" "$2" "$3" "$4" brainstorms; }

# wb_lifecycle_has_ideate <repo> <branch> <worktree_rel> <taskfile> — R7:
# same mechanism as has_plan/has_brainstorm, against docs/ideation/.
wb_lifecycle_has_ideate() { wb_lifecycle_has_doc "$1" "$2" "$3" "$4" ideation; }

# ---------------------------------------------------------------------------
# signal 7: live PR (out of numeric order in this file on purpose — it has
# no dependency on U2/U3 below and reads more naturally grouped with the
# other "cheap signal" detections above; render order for the badges
# themselves is a U4 concern, not this file's)
# ---------------------------------------------------------------------------

# wb_lifecycle_pr_is_live <pr_info> — parses the state out of the SAME
# $pr_info string wb_board_render_html already computes once per row via
# wb_board_pr_info (wb.sh:1080, called at wb.sh:1264) for the existing PR
# chip — no new network call. Only "#N (OPEN)" counts as live; CLOSED/MERGED
# means the task has moved past this stage entirely (into done territory),
# empty means no PR at all.
wb_lifecycle_pr_is_live() {
  local pr_info="${1:-}"
  [ -n "$pr_info" ] || return 1
  case "$pr_info" in
    *'(OPEN)') return 0 ;;
    *)         return 1 ;;
  esac
}

# ---------------------------------------------------------------------------
# signal 5: /ce-work done
# ---------------------------------------------------------------------------

# wb_lifecycle_planning_path <repo-relative path> — true if <path> is one of
# the planning-artifact directories a change must fall OUTSIDE of to count
# as "work done" (docs/plans/, docs/brainstorms/, docs/ideation/,
# logs/decisions/). Deliberate limitation: a task whose actual deliverable
# lives entirely inside one of these paths (e.g. this plan's own U6) reports
# work_done=false even once complete — see the plan's Key Technical
# Decisions.
wb_lifecycle_planning_path() {
  case "${1:-}" in
    docs/plans/*|docs/brainstorms/*|docs/ideation/*|logs/decisions/*) return 0 ;;
    *) return 1 ;;
  esac
}

# wb_lifecycle_any_real_work_path — reads newline-separated repo-relative
# paths on stdin; exits 0 if any of them is NOT a planning-artifact path
# (i.e. counts as real, non-scaffolding work).
wb_lifecycle_any_real_work_path() {
  local path
  while IFS= read -r path; do
    [ -n "$path" ] || continue
    wb_lifecycle_planning_path "$path" || return 0
  done
  return 1
}

# wb_lifecycle_default_branch <repo_dir> — the repo's default branch name,
# via origin/HEAD's symbolic ref, falling back to the main (non-worktree)
# checkout's currently-checked-out branch. Prints empty (not an error) when
# neither resolves (e.g. a detached-HEAD main checkout with no origin/HEAD
# set) — callers must treat empty as "can't compute this half," not a crash.
wb_lifecycle_default_branch() {
  local repo_dir="${1:-}" ref
  ref="$(git -C "$repo_dir" symbolic-ref refs/remotes/origin/HEAD 2>/dev/null)"
  if [ -n "$ref" ]; then
    printf '%s\n' "${ref#refs/remotes/origin/}"
    return 0
  fi
  git -C "$repo_dir" branch --show-current 2>/dev/null
}

# wb_lifecycle_work_done <repo> <worktree_rel> <branch> — true if
# implementation has happened: any COMMITTED change beyond the merge-base
# with the default branch, OR any UNCOMMITTED change, that touches a path
# outside the planning-artifact directories (wb_lifecycle_planning_path).
# Split into two independently-guarded halves (see the plan's Key Technical
# Decisions):
#   - committed half: runs against $repo_dir (the main checkout) using the
#     branch NAME, never a worktree path — committed refs survive `wb
#     done`'s `git worktree remove` (wb.sh:1591-1593, "Branch is kept"), so
#     this half needs no live worktree and must not be skipped just because
#     one is gone.
#   - uncommitted half: needs a live worktree; vacuously false (skipped, not
#     an error) when $(wb_repo_dir "$repo")/$worktree_rel doesn't exist —
#     `wb.sh` runs under `set -euo pipefail` and a `done`-bucket task's
#     worktree removal is the common case this guard exists for, not a rare
#     edge (mirrors has_plan/has_brainstorm's own is_dir guard above).
# Never hard-fails on a git-command error (no resolvable default branch, no
# merge-base, not a git repo at all) — mirrors wb_pr_merge_status's "report a
# safe default, never silently abort" convention (wb.sh:417-424).
#
# Both halves also guard on their field being non-empty (board-display-v2's
# KTD-3, extending the same guard-on-field-values-not-composed-paths
# discipline as wb_lifecycle_has_doc): an empty worktree_rel would otherwise
# degenerate $repo_dir/$worktree_rel to the repo dir itself, which exists,
# so the uncommitted half would run `git status` against the MAIN CHECKOUT —
# any dirty main checkout would then render every branchless, worktree-less
# planned task as work-in-progress (AE8; the store has eight such tasks).
wb_lifecycle_work_done() {
  local repo="${1:-}" worktree_rel="${2:-}" branch="${3:-}"
  local repo_dir; repo_dir="$(wb_repo_dir "$repo")"
  [ -d "$repo_dir/.git" ] || return 1

  if [ -n "$branch" ]; then
    local default_branch merge_base
    default_branch="$(wb_lifecycle_default_branch "$repo_dir")"
    if [ -n "$default_branch" ]; then
      merge_base="$(git -C "$repo_dir" merge-base "$branch" "$default_branch" 2>/dev/null)"
      if [ -n "$merge_base" ]; then
        git -C "$repo_dir" diff --name-only "$merge_base..$branch" 2>/dev/null \
          | wb_lifecycle_any_real_work_path && return 0
      fi
    fi
  fi

  if [ -n "$worktree_rel" ]; then
    local wt="$repo_dir/$worktree_rel"
    if [ -d "$wt" ]; then
      git -C "$wt" status --porcelain 2>/dev/null | cut -c4- \
        | wb_lifecycle_any_real_work_path && return 0
    fi
  fi

  return 1
}

# ---------------------------------------------------------------------------
# signal 6: /ce-code-review done
# ---------------------------------------------------------------------------

# wb_lifecycle_review_done <taskfile> — true once `wb reviewed` (wb.sh,
# cmd_reviewed) has stamped the task file's `reviewed:` frontmatter field.
# No staleness invalidation: this records "a review happened at some point,"
# not "the current HEAD was reviewed" — see the plan's Key Technical
# Decisions and logs/decisions/2026-07-11-wb-board-lifecycle-detection.md.
wb_lifecycle_review_done() {
  local taskfile="${1:-}"
  [ -n "$(wb_get_frontmatter "$taskfile" reviewed)" ]
}

# ---------------------------------------------------------------------------
# Stage-state resolver (board-display-v2 U2) — composes the signals above
# with the `path:` intent field into the four-state model per stage: n/a |
# pending | progress | done. Stage-state strings are a second, documented
# convention alongside this module's boolean (0/1 exit code) predicates —
# four values can't be an exit code.
# ---------------------------------------------------------------------------

# Canonical stage order — every stage-list output (parsed path, resolver
# iteration) renders in this order, regardless of the order stages were
# declared or fired in.
WB_LIFECYCLE_STAGES=(ideate brainstorm plan work review)

# _wb_lifecycle_trim <string> — strip leading/trailing whitespace.
_wb_lifecycle_trim() {
  local s="$1"
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%"${s##*[![:space:]]}"}"
  printf '%s' "$s"
}

# wb_lifecycle_parse_path <path_field> — normalize a task's `path:`
# frontmatter value into its intended stage list, one stage per line, in
# canonical order. Render-tolerant (R4): comma-separated, whitespace-
# tolerant, an optional surrounding `[...]` is stripped, unknown stage
# tokens are silently ignored, duplicates are dropped — a hand-edited
# `path:` must never crash the `set -euo pipefail` render; loud validation
# on write lives only in `wb new --path` (U3). Absent or blank (the two are
# indistinguishable through wb_get_frontmatter, and both mean "not
# declared" — "no stages at all" is deliberately inexpressible) yields the
# default `plan,work,review`, the ~90% real shape.
wb_lifecycle_parse_path() {
  local raw; raw="$(_wb_lifecycle_trim "${1:-}")"
  case "$raw" in
    \[*\]) raw="$(_wb_lifecycle_trim "${raw#\[}")"; raw="$(_wb_lifecycle_trim "${raw%\]}")" ;;
  esac
  [ -n "$raw" ] || raw="plan,work,review"

  local -A want=()
  local -a tokens
  IFS=',' read -ra tokens <<< "$raw"
  local tok
  for tok in "${tokens[@]}"; do
    tok="$(_wb_lifecycle_trim "$tok")"
    case "$tok" in
      ideate|brainstorm|plan|work|review) want["$tok"]=1 ;;
      *) : ;; # unknown stage name — ignored, not an error
    esac
  done

  local stage
  for stage in "${WB_LIFECYCLE_STAGES[@]}"; do
    [ -n "${want[$stage]:-}" ] && printf '%s\n' "$stage"
  done
}

# wb_lifecycle_stage_state <stage> <repo> <branch> <worktree_rel> <taskfile>
#   <status> <pr_info> <path_lines> — prints one of na|pending|progress|done
# for <stage> of this task. <path_lines> is wb_lifecycle_parse_path's
# newline-separated output — callers compute it once per task (it's
# identical across all 5 stage calls), not once per stage.
#
# Signals are evaluated BEFORE path membership (R4's upgrade rule): a fired
# completion/started signal always wins, even for a stage the declared (or
# default) path never named — "n/a" only applies when nothing fired AND the
# stage isn't in the intended path.
#
# Work-stage semantics (R2/R3): done = task `status: done` AND (no PR ever,
# or the PR is CLOSED/MERGED — reusing $pr_info, no new fetch);
# progress = not done AND (wb_lifecycle_work_done OR a PR in ANY state — a
# PR is itself evidence work started, AE1 under both squash and
# merge-commit merges). "Closed" means `status: done` — never the `closed:`
# date field (single-authority principle). Doc stages and review have no
# progress state: pending -> done directly.
wb_lifecycle_stage_state() {
  local stage="$1" repo="$2" branch="$3" worktree_rel="$4" taskfile="$5"
  local status="$6" pr_info="$7" path_lines="$8"

  local in_path=0
  printf '%s\n' "$path_lines" | grep -qxF "$stage" && in_path=1

  local done=0 progress=0
  case "$stage" in
    ideate)     wb_lifecycle_has_ideate     "$repo" "$branch" "$worktree_rel" "$taskfile" && done=1 ;;
    brainstorm) wb_lifecycle_has_brainstorm "$repo" "$branch" "$worktree_rel" "$taskfile" && done=1 ;;
    plan)       wb_lifecycle_has_plan       "$repo" "$branch" "$worktree_rel" "$taskfile" && done=1 ;;
    review)     wb_lifecycle_review_done "$taskfile" && done=1 ;;
    work)
      if [ "$status" = done ]; then
        wb_lifecycle_pr_is_live "$pr_info" && progress=1 || done=1
      else
        { wb_lifecycle_work_done "$repo" "$worktree_rel" "$branch" || [ -n "$pr_info" ]; } && progress=1
      fi
      ;;
  esac

  if [ "$done" = 1 ]; then
    printf 'done\n'
  elif [ "$progress" = 1 ]; then
    printf 'progress\n'
  elif [ "$in_path" = 1 ]; then
    printf 'pending\n'
  else
    printf 'na\n'
  fi
}
