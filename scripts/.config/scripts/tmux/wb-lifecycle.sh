#!/usr/bin/env bash
# wb-lifecycle.sh — lifecycle-stage pipeline detection for `wb board --html`.
# Sourced by wb.sh (wb.sh:28-29) the same way wb.sh sources lib.sh — a
# sibling module, not inline in wb.sh/cmd_board, following this file's own
# convention for indirection points that need independent testing
# (wb_reconcile_repos, wb_repo_dir).
#
# 7 independent yes/no signals for how far a task has gotten through
# plan -> build -> review -> ship (design: docs/plans/2026-07-11-001-feat-wb-
# board-lifecycle-plan.md; detection rationale: logs/decisions/2026-07-11-
# wb-board-lifecycle-detection.md):
#   1. worktree exists       wb_lifecycle_has_worktree
#   2. live agent             wb_lifecycle_has_live_agent
#   3. /ce-plan done           wb_lifecycle_has_plan
#   4. /ce-brainstorm done     wb_lifecycle_has_brainstorm
#   5. /ce-work done           wb_lifecycle_work_done
#   6. /ce-code-review done    wb_lifecycle_review_done
#   7. live PR                 wb_lifecycle_pr_is_live
#
# U4 (board render wiring, wb_lifecycle_badges_html, and wb_board_render_html
# itself) is DELIBERATELY NOT in this file — the display layer is under
# active redesign as of this writing (the original "7 independent badges"
# premise may not survive it). Only the 7 detection functions below are
# settled and implemented; nothing here calls or is called by
# wb_board_render_html yet.
#
# All 7 take plain repo/branch/worktree/taskfile values already available in
# wb_board_render_html's per-row loop (wb.sh:1231-1235) — no new global
# state, and no new network call (signal 7 reuses the $pr_info
# wb_board_render_html already computes via wb_board_pr_info, wb.sh:1264).
# Boolean predicates return via exit code (0 = true, 1 = false), matching
# this codebase's existing convention (wb_task_own_parent, wb.sh:145;
# wb_worktree_has_task, wb.sh:444) rather than printing "true"/"false".

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
# signals 3/4: /ce-plan, /ce-brainstorm done
# ---------------------------------------------------------------------------

# wb_lifecycle_has_doc <repo> <branch> <worktree_rel> <taskfile> <kind> —
# shared implementation for wb_lifecycle_has_plan/wb_lifecycle_has_brainstorm
# (kind is "plans" or "brainstorms" — the only difference between the two
# signals is which docs/ subdirectory they look at). Two independent, cheap,
# filesystem-only checks, OR-ed together (neither alone is reliable in
# practice against this repo's currently-open lanes — see the plan's Key
# Technical Decisions):
#   - glob:  a docs/<kind>/*.md|*.html file in the task's OWN worktree whose
#            filename contains the branch's sanitized form as a substring.
#   - prose: wb_board_related_docs (wb.sh:1115), re-rooted at the task's own
#            worktree instead of the fixed $dotfiles_root, so a doc that's
#            only committed on this (unmerged) branch is still visible.
# Both re-rooted at the task's own worktree, never $dotfiles_root — a doc
# committed only inside an unmerged worktree is invisible from the main
# checkout (the deferred cross-worktree bug this detection sidesteps; see
# the plan's "Deferred to Follow-Up Work").
wb_lifecycle_has_doc() {
  local repo="${1:-}" branch="${2:-}" worktree="${3:-}" taskfile="${4:-}" kind="${5:-}"
  local wt; wt="$(wb_repo_dir "$repo")/$worktree"
  [ -d "$wt" ] || return 1

  local frag; frag="$(wb_sanitize "$branch")"
  local f
  if [ -d "$wt/docs/$kind" ]; then
    for f in "$wt/docs/$kind"/*.md "$wt/docs/$kind"/*.html; do
      [ -f "$f" ] || continue
      case "$(basename "$f")" in
        *"$frag"*) return 0 ;;
      esac
    done
  fi

  wb_board_related_docs "$taskfile" "$wt" | grep -q "^docs/$kind/" && return 0
  return 1
}

# wb_lifecycle_has_plan <repo> <branch> <worktree_rel> <taskfile>
wb_lifecycle_has_plan() { wb_lifecycle_has_doc "$1" "$2" "$3" "$4" plans; }

# wb_lifecycle_has_brainstorm <repo> <branch> <worktree_rel> <taskfile>
wb_lifecycle_has_brainstorm() { wb_lifecycle_has_doc "$1" "$2" "$3" "$4" brainstorms; }

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
wb_lifecycle_work_done() {
  local repo="${1:-}" worktree_rel="${2:-}" branch="${3:-}"
  local repo_dir; repo_dir="$(wb_repo_dir "$repo")"
  [ -d "$repo_dir/.git" ] || return 1

  local default_branch merge_base
  default_branch="$(wb_lifecycle_default_branch "$repo_dir")"
  if [ -n "$default_branch" ]; then
    merge_base="$(git -C "$repo_dir" merge-base "$branch" "$default_branch" 2>/dev/null)"
    if [ -n "$merge_base" ]; then
      git -C "$repo_dir" diff --name-only "$merge_base..$branch" 2>/dev/null \
        | wb_lifecycle_any_real_work_path && return 0
    fi
  fi

  local wt="$repo_dir/$worktree_rel"
  if [ -d "$wt" ]; then
    git -C "$wt" status --porcelain 2>/dev/null | cut -c4- \
      | wb_lifecycle_any_real_work_path && return 0
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
