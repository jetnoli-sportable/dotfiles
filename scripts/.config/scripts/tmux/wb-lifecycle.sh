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
