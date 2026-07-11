#!/usr/bin/env bash
# wb (workbench) — session-per-worktree + the unified picker.
#   wb new [--agent] <slug>          from inside a repo
#   wb new [--agent] <repo> <slug>   from anywhere
#   wb                               the picker (replaces s + ca)
#   wb board                         task-store status table (interim /board)
#   wb done [--close] [<session>]    safe wind-down (defaults to the current session); --close also kills the tmux session
#   wb resume <task>                 recreate a closed/gone worktree+session from its task file
#   wb pause [<session>]             mark a task paused — worktree and session both survive
#   wb reconcile                     report task-store/git worktree drift (detection only, read-only)
#
# Design + build order: dotfiles/docs/roadmap.md §2/§3,
# ratified judgment calls: dotfiles/logs/decisions/2026-07-06-review-outstanding.md,
# task store location: dotfiles/logs/decisions/2026-07-06-task-store-location.md.
#
# Row source (picker): one row per task file in the central store
# ($TASKS_DIR/*.md), status from frontmatter, overlaid with live session/agent
# state. Repo-level checkouts (main checkouts, no task) appear as extra rows.
# Never parse repo/slug back out of a tmux session name or filename — both can
# contain the "--" delimiter (e.g. repo `be--monorepo`). Recover repo from a
# task's `repo:` frontmatter and slug from its `worktree:` field
# (`.worktrees/<slug>` — strip the prefix) instead.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SELF="$SCRIPT_DIR/$(basename "${BASH_SOURCE[0]}")"   # for fzf reload/become to re-invoke us
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

TASKS_DIR="${TASKS_DIR:-$HOME/code/tasks}"
CODE_DIR="${CODE_DIR:-$HOME/code}"
WB_SWEEP_THRESHOLD="${WB_SWEEP_THRESHOLD:-5}"   # follow-ups+parked count that triggers the nudge

# Picker column widths — shared between wb_format_for_display's padding and
# wb_column_header's labels. Keep these in sync or the legend row drifts
# from the data rows under it.
# Columns: REPO (repo/location) · NAME (task title or session/repo name) ·
# TYPE (session / agent / both — is there a live agent here, just a bare
# session, or a sub-row for one specific agent pane) · BRANCH (the git
# branch, when there is one) · STATUS (needs you / working / done /
# finished / idle).
WB_COL_REPO=16
WB_COL_LABEL=26
WB_COL_TYPE=8
WB_COL_BRANCH=12
WB_COL_STATUS=9   # status label width, after the icon + one space

# ---------------------------------------------------------------------------
# Frontmatter helpers — the store's schema is plain `key: value` lines between
# the first two `---` markers (see ~/code/tasks/README.md).
# ---------------------------------------------------------------------------

# wb_get_frontmatter <file> <key> — print a single frontmatter value (blank if unset).
wb_get_frontmatter() {
  awk -v key="$2" '
    BEGIN { infm = 0 }
    /^---$/ { infm++; if (infm == 2) exit; next }
    infm == 1 && $0 ~ "^" key ":" { sub("^" key ":[ \t]*", ""); print; exit }
  ' "$1"
}

# wb_set_frontmatter <file> <key> <value> — overwrite a frontmatter value in
# place, or insert it just before the closing `---` when the key has no
# existing line (e.g. a task file that predates this key being added to the
# schema).
wb_set_frontmatter() {
  local file="$1" key="$2" value="$3"
  awk -v key="$key" -v val="$value" '
    BEGIN { infm = 0; done = 0 }
    /^---$/ {
      infm++
      if (infm == 2 && !done) { print key ": " val; done = 1 }
      print; next
    }
    infm == 1 && !done && $0 ~ "^" key ":" { print key ": " val; done = 1; next }
    { print }
  ' "$file" > "$file.tmp.$$" && mv "$file.tmp.$$" "$file"
}

# wb_read_task <file> — print "status\trepo\tworktree" in one pass (used by
# the picker's row collection, which reads every task file on each refresh).
wb_read_task() {
  awk '
    # clip() strips a trailing inline comment ("value  # note") plus edge
    # whitespace — TEMPLATE.md itself ships "status: doing  # planned|..."
    # so any seeded task carries one, and an uncomment-stripped status
    # breaks every consumer that compares it (board rank, picker column).
    function clip(s) { sub(/[ \t]+#.*$/, "", s); sub(/[ \t]+$/, "", s); return s }
    BEGIN { infm = 0; status = ""; repo = ""; worktree = ""; branch = "" }
    /^---$/ { infm++; if (infm == 2) exit; next }
    infm == 1 && /^status:/   { s = $0; sub(/^status:[ \t]*/,   "", s); status = clip(s) }
    infm == 1 && /^repo:/     { s = $0; sub(/^repo:[ \t]*/,     "", s); repo = clip(s) }
    infm == 1 && /^worktree:/ { s = $0; sub(/^worktree:[ \t]*/, "", s); worktree = clip(s) }
    infm == 1 && /^branch:/   { s = $0; sub(/^branch:[ \t]*/,   "", s); branch = clip(s) }
    END { printf "%s\t%s\t%s\t%s\n", status, repo, worktree, branch }
  ' "$1"
}

# wb_task_title <file> — the first `# ` heading, or empty if none.
wb_task_title() {
  awk '/^# / { sub(/^# /, ""); print; exit }' "$1"
}

# wb_task_file <repo> <disp_slug> — the store path for a repo+slug pair.
wb_task_file() { printf '%s/%s--%s.md\n' "$TASKS_DIR" "$1" "$2"; }

# wb_task_files — every real task file in the store (excludes README/TEMPLATE
# and the dossiers/ directory used by wb done's keeper sweep).
wb_task_files() {
  local f
  for f in "$TASKS_DIR"/*.md; do
    [ -f "$f" ] || continue
    case "$(basename "$f")" in
      TEMPLATE.md|README.md) continue ;;
    esac
    echo "$f"
  done
}

# wb_sanitize <slug> — slug -> display form for tmux session names / filenames
# ("/", "." and ":" become "-"; never parse this back, see header comment).
# ":" matters beyond aesthetics: tmux 3.4 silently rewrites "."/":" to "_"
# in new-session -s, so an unsanitized name diverges from what tmux actually
# created — and a stale ":"-bearing name later fed to kill-session parses as
# session:window and can kill an UNRELATED session.
wb_sanitize() { local s="${1//\//-}"; s="${s//./-}"; echo "${s//:/-}"; }

# wb_resolve_parent_ref <ref> — validate <ref> (a "<repo>--<slug>" task-file
# stem) exists in the store; print its path, or fail loudly. Shared by
# `wb new --parent` and `wb reconcile --apply`'s create-task action so a
# parent must always be a real, pre-existing task file — never an arbitrary
# string, same fail-loud-on-no-match convention as `wb resume`.
wb_resolve_parent_ref() {
  local ref="$1"
  local file="$TASKS_DIR/$ref.md"
  [ -f "$file" ] || { echo "wb: --parent '$ref' has no matching task file in $TASKS_DIR" >&2; return 1; }
  printf '%s\n' "$file"
}

# wb_task_own_parent <candidate_parent_stem> <own_stem> — exit 0 (safe) when
# candidate is NOT own_stem's own file; exit 1 (self-reference) when it is.
# Single shared check for the write path (wb new --parent, wb reconcile
# --apply's create-task action) and both read paths (picker grouping,
# /board's rollup) so the rule can't drift between call sites.
wb_task_own_parent() {
  [ "$1" != "$2" ] || return 1
  return 0
}

# wb_tsv_split <string> <array_name> — split <string> on literal tabs into
# the named array, preserving empty fields. NEVER use `IFS=$'\t' read` for
# this: bash classifies tab as IFS-WHITESPACE regardless of what IFS is set
# to, so a run of consecutive tabs (an empty field, e.g. an idle row's empty
# target) gets silently collapsed into one delimiter and every field after
# it shifts left. awk's -F'\t' has no such behavior — fields stay put.
wb_tsv_split() {
  local -n _wb_tsv_out="$2"
  mapfile -t _wb_tsv_out < <(awk -F'\t' '{ for (i = 1; i <= NF; i++) print $i }' <<< "$1")
}

# ---------------------------------------------------------------------------
# wb new — worktree + bootstrap + task seed + tmux session
# ---------------------------------------------------------------------------

# wb_bootstrap <repo_dir> <worktree_path> — copy/symlink gitignored files a
# fresh worktree needs, per the repo's own gitignored `.worktree-bootstrap`
# manifest (one relative path per line, `#` comments allowed). Defaults to
# `.env*` at the repo root when the repo has no manifest. Files are copied;
# directories are symlinked back to the main checkout (e.g. node_modules) so
# a worktree never needs its own reinstall.
wb_bootstrap() {
  local repo_dir="$1" worktree_path="$2" manifest="$repo_dir/.worktree-bootstrap"
  local -a entries=()
  if [ -f "$manifest" ]; then
    local line
    while IFS= read -r line; do
      line="${line%%#*}"
      line="${line#"${line%%[![:space:]]*}"}"
      line="${line%"${line##*[![:space:]]}"}"
      [ -n "$line" ] && entries+=("$line")
    done < "$manifest"
  else
    local f
    while IFS= read -r -d '' f; do
      entries+=("$(basename "$f")")
    done < <(find "$repo_dir" -maxdepth 1 -name '.env*' -print0 2>/dev/null)
  fi
  local entry src dest
  for entry in "${entries[@]}"; do
    src="$repo_dir/$entry"
    [ -e "$src" ] || continue
    dest="$worktree_path/$entry"
    mkdir -p "$(dirname "$dest")"
    if [ -d "$src" ]; then
      ln -s "$src" "$dest"
    else
      cp -a "$src" "$dest"
    fi
  done
}

# wb_seed_task <repo> <slug> <worktree_rel> [<parent_ref>] — find-or-create
# the task file for a repo+slug pair, filling blank frontmatter fields and
# bumping planned->doing. Never overwrites a field that's already set.
# <parent_ref> is optional (defaults to empty) so wb_reconcile_action_create_task's
# pre-existing 3-arg call keeps working unchanged — it never sets `parent:`.
wb_seed_task() {
  local repo="$1" slug="$2" worktree_rel="$3" parent="${4:-}"
  local disp_slug; disp_slug="$(wb_sanitize "$slug")"
  local file; file="$(wb_task_file "$repo" "$disp_slug")"

  if [ ! -f "$file" ]; then
    mkdir -p "$TASKS_DIR"
    local title="${slug//-/ }"
    # awk -v (not sed -e "s|...$slug...|") — a slug/repo containing the sed
    # delimiter (e.g. "feat/foo" with the default "/", or even "|" once you
    # switch delimiters) breaks the substitution and can abort mid-template
    # after the worktree/branch already exist. awk -v splices values in
    # verbatim with no delimiter to collide with.
    awk -v repo="$repo" -v branch="$slug" -v worktree="$worktree_rel" \
        -v created="$(date +%F)" -v title="$title" '
      BEGIN { infm = 0 }
      /^---$/     { infm++; print; next }
      infm == 1 && /^status:/   { print "status: doing"; next }
      infm == 1 && /^repo:/     { print "repo: " repo; next }
      infm == 1 && /^branch:/   { print "branch: " branch; next }
      infm == 1 && /^worktree:/ { print "worktree: " worktree; next }
      infm == 1 && /^created:/  { print "created: " created; next }
      infm == 2 && /^# Title/   { print "# " title; next }
      { print }
    ' "$TASKS_DIR/TEMPLATE.md" > "$file"
  else
    [ -n "$(wb_get_frontmatter "$file" repo)" ]      || wb_set_frontmatter "$file" repo "$repo"
    [ -n "$(wb_get_frontmatter "$file" branch)" ]    || wb_set_frontmatter "$file" branch "$slug"
    [ -n "$(wb_get_frontmatter "$file" worktree)" ]  || wb_set_frontmatter "$file" worktree "$worktree_rel"
    [ "$(wb_get_frontmatter "$file" status)" != planned ] || wb_set_frontmatter "$file" status doing
  fi
  [ -z "$parent" ] || wb_set_frontmatter "$file" parent "$parent"
  echo "$file"
}

# wb_layout_session <session> <dir> <start_agent> — first-time-only 3-window
# layout: win1 nvim, win2 a plain shell for the agent (LAZY — you run `claude`
# yourself the first time you visit, bounded by the ~10-concurrent-agent
# memory ceiling; pass start_agent=1, i.e. `wb new --agent`, to start it now),
# win3 shell.
wb_layout_session() {
  local session="$1" dir="$2" start_agent="$3"
  tmux rename-window -t "=$session:1" nvim
  # WB_AUTO_RESTORE=1 opts THIS launch into persistence.nvim's
  # auto-restore-on-VimEnter (nvim/.config/nvim/lua/plugins/config/
  # persistence.lua) — a worktree session's nvim window should pick back up
  # where you left it. Typing `nvim .`/`vim .` yourself anywhere else does
  # NOT set this and gets a plain, non-restoring open (2026-07-09: silent
  # auto-restore on every `.` launch was surprising with no escape hatch).
  tmux send-keys -t "=$session:1" "WB_AUTO_RESTORE=1 nvim ." Enter
  tmux new-window -t "=$session" -n agent -c "$dir"
  [ "$start_agent" = 1 ] && tmux send-keys -t "=$session:agent" "claude" Enter
  tmux new-window -t "=$session" -n shell -c "$dir"
  tmux select-window -t "=$session:1"
}

cmd_new() {
  # Index/shift case parser, not a single-token foreach: --parent takes its
  # value as a separate following argument, which a foreach that only
  # detects literal tokens (like --agent) can't consume — the value would
  # fall into the else branch and corrupt the positional repo/slug count.
  local agent_flag=0 parent_ref=""
  local -a args=()
  while [ $# -gt 0 ]; do
    case "$1" in
      --agent)  agent_flag=1; shift ;;
      --parent)
        case "${2-}" in
          ''|--*) echo "wb new: --parent requires a value" >&2; exit 1 ;;
        esac
        parent_ref="$2"; shift 2 ;;
      *)        args+=("$1"); shift ;;
    esac
  done

  local repo slug
  if [ "${#args[@]}" -eq 2 ]; then
    repo="${args[0]}"; slug="${args[1]}"
  elif [ "${#args[@]}" -eq 1 ]; then
    slug="${args[0]}"
    local toplevel
    toplevel="$(git rev-parse --show-toplevel 2>/dev/null)" \
      || { echo "wb new <slug>: not inside a repo — pass 'wb new <repo> <slug>'" >&2; exit 1; }
    repo="$(basename "$toplevel")"
  else
    echo "usage: wb new [--agent] [--parent <repo>--<slug>] <slug> | wb new [--agent] [--parent <repo>--<slug>] <repo> <slug>" >&2
    exit 1
  fi

  [ -n "$slug" ] || { echo "wb new: <slug> must not be empty" >&2; exit 1; }

  local disp_slug; disp_slug="$(wb_sanitize "$slug")"

  # Validate before anything is touched — same fail-loud-on-no-match
  # convention as `wb resume`. Also reject a self-referential --parent, the
  # same guard the picker/board read paths use (wb_task_own_parent).
  if [ -n "$parent_ref" ]; then
    wb_resolve_parent_ref "$parent_ref" >/dev/null || exit 1
    wb_task_own_parent "$parent_ref" "${repo}--${disp_slug}" \
      || { echo "wb new: --parent cannot be the task's own reference" >&2; exit 1; }
  fi

  local repo_dir="$CODE_DIR/$repo"
  [ -d "$repo_dir/.git" ] || { echo "wb new: $repo_dir is not a git repo" >&2; exit 1; }
  local session="${repo}--${disp_slug}"
  local worktree_rel=".worktrees/$slug"
  local worktree_path="$repo_dir/$worktree_rel"

  if [ ! -d "$worktree_path" ]; then
    if git -C "$repo_dir" show-ref --verify --quiet "refs/heads/$slug"; then
      git -C "$repo_dir" worktree add "$worktree_path" "$slug"
    else
      git -C "$repo_dir" worktree add -b "$slug" "$worktree_path"
    fi
    wb_bootstrap "$repo_dir" "$worktree_path"
  fi

  local task_file
  task_file="$(wb_seed_task "$repo" "$slug" "$worktree_rel" "$parent_ref")"

  local is_new=0
  tmux has-session -t "=$session" 2>/dev/null || is_new=1
  tmux_ensure_session "$session" "$worktree_path"
  # A session-only "=name" target (no window/pane part) confuses set-option's
  # pane-target parser on tmux 3.4 ("no such session") even though the session
  # exists — a trailing colon keeps the exact match (lib.sh's =name convention)
  # while giving it a valid target-pane shape.
  tmux set-option -t "=$session:" @wb_repo "$repo" >/dev/null
  tmux set-option -t "=$session:" @wb_slug "$slug" >/dev/null
  tmux set-option -t "=$session:" @task "$task_file" >/dev/null
  [ "$is_new" = 1 ] && wb_layout_session "$session" "$worktree_path" "$agent_flag"

  tmux_focus "$session"
}

# ---------------------------------------------------------------------------
# wb resume — recreate a task's worktree+session from the central store
# ---------------------------------------------------------------------------

# cmd_resume <query> — case-insensitive substring match of <query> against
# every task file's basename (repo--slug, minus .md), then hands off to
# cmd_new's existing worktree/session logic (already idempotent — safe
# whether the worktree still exists or was torn down by a prior `wb done`).
# Never guesses on ambiguity: 0 or 2+ matches both fail loudly instead of
# picking one.
cmd_resume() {
  local query="${1:-}"
  [ -n "$query" ] || { echo "usage: wb resume <task>" >&2; exit 1; }

  local -a matches=()
  local f base
  while IFS= read -r f; do
    base="$(basename "$f" .md)"
    case "${base,,}" in
      *"${query,,}"*) matches+=("$f") ;;
    esac
  done < <(wb_task_files)

  case "${#matches[@]}" in
    0)
      echo "wb resume: no task matches '$query' in $TASKS_DIR" >&2
      exit 1
      ;;
    1)
      local file="${matches[0]}" repo branch
      repo="$(wb_get_frontmatter "$file" repo)"
      branch="$(wb_get_frontmatter "$file" branch)"
      [ -n "$repo" ] && [ -n "$branch" ] \
        || { echo "wb resume: $file has no repo:/branch: frontmatter to resume from" >&2; exit 1; }
      cmd_new "$repo" "$branch"
      ;;
    *)
      echo "wb resume: '$query' matches ${#matches[@]} tasks — be more specific:" >&2
      for f in "${matches[@]}"; do
        echo "  $(basename "$f" .md)" >&2
      done
      exit 1
      ;;
  esac
}

# ---------------------------------------------------------------------------
# wb reconcile — drift detection (task store vs. git worktree reality)
# ---------------------------------------------------------------------------
# Detection only. The review-doc + six-action flow over these findings is a
# separate, still-pending unit — this just reports.

# wb_reconcile_repos — every repo directory to scan for orphaned worktrees.
# Indirection point so tests can stub in fixture repos instead of scanning
# the real $HOME/code.
wb_reconcile_repos() { tmux_code_repos; }

# wb_repo_dir <repo> — <repo>'s directory under CODE_DIR. Indirection point
# so tests can stub in a fixture path instead of the real $HOME/code/<repo>.
wb_repo_dir() { printf '%s/%s\n' "$CODE_DIR" "$1"; }

# wb_repo_worktrees <repo_dir> — "<branch>\t<abs_path>" per worktree in
# <repo_dir>, EXCLUDING the main worktree (the checkout itself). Uses
# substr(), not field-split, so a path containing spaces doesn't corrupt
# the branch/path split.
wb_repo_worktrees() {
  git -C "$1" worktree list --porcelain 2>/dev/null | awk -v main="$1" '
    /^worktree / { path = substr($0, 10); branch = ""; is_main = (path == main) }
    /^branch /   { b = substr($0, 8); sub(/^refs\/heads\//, "", b); branch = b }
    /^detached$/ { branch = "(detached)" }
    /^$/         { if (path != "" && !is_main) printf "%s\t%s\n", branch, path; path = "" }
    END          { if (path != "" && !is_main) printf "%s\t%s\n", branch, path }
  '
}

# wb_pr_merge_status <repo_dir> <branch> — "merged" | "not-merged" | "unknown"
# for <branch>'s most recent PR. Falls back from `gh` to a personal PAT
# (mirroring the `pgh` shell function in ~/.zshrc — reimplemented inline
# since wb.sh is bash and pgh is a zsh function, not a standalone binary)
# when the Sportable-scoped token can't see the repo. Hard rule: never
# silently drop a finding — a gh/pgh failure reports "unknown" rather than
# omitting the row entirely.
wb_pr_merge_status() {
  local repo_dir="$1" branch="$2" out rc
  out="$(cd "$repo_dir" && gh pr list --head "$branch" --state merged --json number 2>&1)"; rc=$?
  if [ "$rc" -ne 0 ] && printf '%s' "$out" | grep -qi 'could not resolve to a repository'; then
    out="$(cd "$repo_dir" && GH_TOKEN="$(secret-tool lookup service gh account personal 2>/dev/null)" gh pr list --head "$branch" --state merged --json number 2>&1)"; rc=$?
  fi
  if [ "$rc" -ne 0 ]; then
    echo unknown
    return
  fi
  if printf '%s' "$out" | grep -q '"number"'; then echo merged; else echo not-merged; fi
}

# cmd_reconcile — two kinds of drift:
#   - orphaned worktree: a real git worktree with no task file pointing at it
#   - missing worktree: a task file's worktree: field points nowhere
# wb_worktree_has_task <repo> <rel_worktree> — true if some task file's
# repo:/worktree: pair matches exactly. Shared by cmd_reconcile's orphan
# detection and /board's untracked-worktree rows (U4) — same question,
# asked from two call sites, must never drift out of sync.
wb_worktree_has_task() {
  local repo="$1" rel="$2" tf
  while IFS= read -r tf; do
    [ "$(wb_get_frontmatter "$tf" repo)" = "$repo" ] || continue
    [ "$(wb_get_frontmatter "$tf" worktree)" = "$rel" ] && return 0
  done < <(wb_task_files)
  return 1
}

# wb_reconcile_collect — one TSV line per drift finding, shared by
# cmd_reconcile's plain-text output and the review-doc generator (U7) so
# detection logic lives in exactly one place. Fields:
#   orphan:  kind=orphan   repo  branch  worktree(rel)  merge-status
#   missing: kind=missing  repo  branch(from frontmatter)  worktree(rel)  taskfile(abs path)
wb_reconcile_collect() {
  local repo_dir repo branch abs_path rel merged
  while IFS= read -r repo_dir; do
    [ -d "$repo_dir/.git" ] || continue
    repo="$(basename "$repo_dir")"
    while IFS=$'\t' read -r branch abs_path; do
      [ -n "$abs_path" ] || continue
      rel="${abs_path#"$repo_dir"/}"
      if ! wb_worktree_has_task "$repo" "$rel"; then
        merged="$(wb_pr_merge_status "$repo_dir" "$branch")"
        printf 'orphan\t%s\t%s\t%s\t%s\n' "$repo" "$branch" "$rel" "$merged"
      fi
    done < <(wb_repo_worktrees "$repo_dir")
  done < <(wb_reconcile_repos)

  local tf t_repo t_worktree t_branch
  while IFS= read -r tf; do
    t_repo="$(wb_get_frontmatter "$tf" repo)"
    t_worktree="$(wb_get_frontmatter "$tf" worktree)"
    [ -n "$t_repo" ] && [ -n "$t_worktree" ] || continue
    [ -d "$(wb_repo_dir "$t_repo")/$t_worktree" ] && continue
    t_branch="$(wb_get_frontmatter "$tf" branch)"
    printf 'missing\t%s\t%s\t%s\t%s\n' "$t_repo" "$t_branch" "$t_worktree" "$tf"
  done < <(wb_task_files)
}

cmd_reconcile() {
  case "${1:-}" in
    --review) shift; wb_reconcile_generate_review "$@"; return ;;
    --apply)  shift; wb_reconcile_apply "$@"; return ;;
  esac

  local -a orphan_rows=() missing_rows=()
  local line kind repo branch worktree extra
  local -a f
  while IFS= read -r line; do
    wb_tsv_split "$line" f
    kind="${f[0]}"; repo="${f[1]}"; branch="${f[2]}"; worktree="${f[3]}"; extra="${f[4]}"
    if [ "$kind" = orphan ]; then
      orphan_rows+=("$repo"$'\t'"$branch"$'\t'"$worktree"$'\t'"$extra")
    else
      missing_rows+=("$repo"$'\t'"$worktree"$'\t'"$(basename "$extra" .md)")
    fi
  done < <(wb_reconcile_collect)

  if [ "${#orphan_rows[@]}" -eq 0 ] && [ "${#missing_rows[@]}" -eq 0 ]; then
    echo "wb reconcile: no drift found"
    return 0
  fi

  if [ "${#orphan_rows[@]}" -gt 0 ]; then
    echo "Orphaned worktrees (no matching task file):"
    { printf 'REPO\tBRANCH\tWORKTREE\tMERGE-STATUS\n'; printf '%s\n' "${orphan_rows[@]}"; } | column -t -s $'\t'
    [ "${#missing_rows[@]}" -gt 0 ] && echo
  fi

  if [ "${#missing_rows[@]}" -gt 0 ]; then
    echo "Tasks referencing a missing worktree:"
    { printf 'REPO\tWORKTREE\tTASK\n'; printf '%s\n' "${missing_rows[@]}"; } | column -t -s $'\t'
  fi
}

# ---------------------------------------------------------------------------
# wb reconcile --review / --apply — the persistent review doc + six-action
# flow (U7). Each finding renders with a `<!-- wb-reconcile: ... -->`
# marker carrying its identifying fields, immune to whatever the user edits
# around it — --apply reads markers back, not prose.
#
# "merge with task" is only semantically distinct from "attach to task" for
# a MISSING-worktree finding (two real task files, two sets of Plan/Done/
# Follow-ups content to reconcile). An orphaned worktree has no task file of
# its own, so "merging" it into an existing task IS attaching — there's
# nothing else to combine. The survivor sub-checkboxes only ever apply to
# a missing-finding merge, and since the target task isn't known until the
# user names it in this same document, the pre-checked default can't be
# computed at generation time — it's computed and appended on the FIRST
# --apply that sees a named target with no survivor choice yet, and the doc
# reopens for confirmation before anything actually merges (same
# append-then-reopen shape wb done's own Sweep flow already uses).
# ---------------------------------------------------------------------------

# wb_reconcile_report_path — logs/reconcile.md in THIS repo (dotfiles),
# same convention as wb_board_render_html's logs/board.html.
wb_reconcile_report_path() {
  local root
  root="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel 2>/dev/null)"
  [ -n "$root" ] || root="$CODE_DIR/dotfiles"
  printf '%s/logs/reconcile.md\n' "$root"
}

# wb_reconcile_generate_review — (re)writes the persistent review doc from
# a fresh detection pass, then opens it for editing. Refuses to clobber a
# prior report that still has unchecked findings (R17) — an unresolved
# review is work in progress, not something to silently discard.
wb_reconcile_generate_review() {
  local path; path="$(wb_reconcile_report_path)"
  if [ -f "$path" ] && grep -q '<!-- wb-reconcile:' "$path" && grep -qE '^- \[ \]' "$path"; then
    echo "wb reconcile --review: $path has unresolved findings from a prior review." >&2
    echo "wb reconcile --review: check/act on them (or delete the file) before re-running." >&2
    return 1
  fi

  mkdir -p "$(dirname "$path")"
  local n=0 line kind repo branch worktree extra
  local -a f
  {
    echo "# wb reconcile — review"
    echo
    echo "> Check the action(s) you want for each finding, save and close."
    echo "> Run \`wb reconcile --apply\` to execute what you checked — nothing"
    echo "> here is automatic, an unchecked finding is left exactly as-is."
    while IFS= read -r line; do
      wb_tsv_split "$line" f
      kind="${f[0]}"; repo="${f[1]}"; branch="${f[2]}"; worktree="${f[3]}"; extra="${f[4]}"
      n=$((n + 1))
      echo
      if [ "$kind" = orphan ]; then
        echo "## $n. orphaned worktree — $repo / $branch"
        echo
        echo "<!-- wb-reconcile: kind=orphan repo=$repo branch=$branch worktree=$worktree -->"
        echo
        echo "- Worktree: \`$worktree\`"
        echo "- Merge status: $extra"
      else
        echo "## $n. missing worktree — $repo / $(basename "$extra" .md)"
        echo
        echo "<!-- wb-reconcile: kind=missing repo=$repo branch=$branch worktree=$worktree taskfile=$extra -->"
        echo
        echo "- Task file: \`$(basename "$extra")\`"
        echo "- Missing worktree: \`$worktree\`"
      fi
      echo
      echo "- [ ] do nothing"
      echo "- [ ] remove"
      echo "- [ ] discuss"
      echo "- [ ] create a task (optional parent: \`___\`)"
      echo "- [ ] attach to task: \`___\`"
      echo "- [ ] merge with task: \`___\`"
    done < <(wb_reconcile_collect)
    [ "$n" -eq 0 ] && { echo; echo "No drift found."; }
  } > "$path"

  echo "wb reconcile --review: wrote $path ($n finding(s))"
  [ "$n" -gt 0 ] && wb_open_buffer "$path"
}

# wb_reconcile_action_remove <kind> <repo> <branch> <worktree> <taskfile>
wb_reconcile_action_remove() {
  local kind="$1" repo="$2" branch="$3" worktree="$4" taskfile="$5" repo_dir
  if [ "$kind" = orphan ]; then
    repo_dir="$(wb_repo_dir "$repo")"
    if [ -d "$repo_dir/$worktree" ]; then
      git -C "$repo_dir" worktree remove "$repo_dir/$worktree" --force
    fi
    git -C "$repo_dir" branch -D "$branch" 2>/dev/null || true
    echo "wb reconcile --apply: removed $repo/$worktree and branch $branch"
  else
    if [ -f "$taskfile" ]; then
      rm -f "$taskfile"
      echo "wb reconcile --apply: removed stale task file $taskfile"
    else
      echo "wb reconcile --apply: $taskfile already gone, nothing to remove" >&2
    fi
  fi
}

# wb_reconcile_action_create_task <kind> <repo> <branch> <worktree> [<parent_ref>]
wb_reconcile_action_create_task() {
  local kind="$1" repo="$2" branch="$3" worktree="$4" parent="${5:-}"
  if [ "$kind" != orphan ]; then
    echo "wb reconcile --apply: 'create a task' is a no-op on a missing-worktree finding (a task already exists) — skipping" >&2
    return 0
  fi
  if [ -n "$parent" ]; then
    if ! wb_resolve_parent_ref "$parent" >/dev/null; then
      echo "wb reconcile --apply: skipping this finding's create-task action — invalid parent" >&2
      return 0
    fi
    if ! wb_task_own_parent "$parent" "${repo}--$(wb_sanitize "$branch")"; then
      echo "wb reconcile --apply: skipping this finding's create-task action — --parent cannot be the task's own reference" >&2
      return 0
    fi
  fi
  local file; file="$(wb_seed_task "$repo" "$branch" "$worktree" "$parent")"
  echo "wb reconcile --apply: created task $file (status: doing)"
}

# wb_reconcile_action_attach <kind> <repo> <worktree> <target_basename>
wb_reconcile_action_attach() {
  local kind="$1" worktree="$2" target="$3" target_file
  if [ "$kind" != orphan ]; then
    echo "wb reconcile --apply: 'attach to task' doesn't apply to a missing-worktree finding (it already is one) — use 'merge with task' instead — skipping" >&2
    return 0
  fi
  target_file="$TASKS_DIR/$target"
  if [ ! -f "$target_file" ]; then
    echo "wb reconcile --apply: attach target '$target' not found in $TASKS_DIR — skipping this finding" >&2
    return 0
  fi
  wb_set_frontmatter "$target_file" worktree "$worktree"
  echo "wb reconcile --apply: attached $worktree to $target_file"
}

# wb_reconcile_merge_content <survivor_file> <loser_file> — appends the
# loser's Plan/Done/Follow-ups content into the survivor's matching
# sections, carries over worktree: if the survivor's is blank, then
# deletes the loser file.
wb_reconcile_merge_content() {
  local survivor="$1" loser="$2" heading section
  for heading in Plan Done Follow-ups; do
    section="$(wb_board_section "$loser" "$heading")"
    [ -n "$(printf '%s' "$section" | tr -d '[:space:]')" ] || continue
    awk -v h="## $heading" -v content="$section" '
      { print }
      $0 == h { print content }
    ' "$survivor" > "$survivor.tmp.$$" && mv "$survivor.tmp.$$" "$survivor"
  done
  local survivor_wt loser_wt
  survivor_wt="$(wb_get_frontmatter "$survivor" worktree)"
  loser_wt="$(wb_get_frontmatter "$loser" worktree)"
  [ -z "$survivor_wt" ] && [ -n "$loser_wt" ] && wb_set_frontmatter "$survivor" worktree "$loser_wt"
  rm -f "$loser"
}

# wb_reconcile_action_merge <kind> <repo> <branch> <worktree> <taskfile> <target> <block>
# For an orphan finding, merge == attach (no task content of its own to
# combine). For a missing-worktree finding, requires the block to already
# carry a resolved survivor choice (exactly one `- [x] survivor:` line) —
# the caller (wb_reconcile_apply) is responsible for appending and
# reopening first when that choice doesn't exist yet.
wb_reconcile_action_merge() {
  local kind="$1" repo="$2" branch="$3" worktree="$4" taskfile="$5" target="$6" block="$7"
  if [ "$kind" = orphan ]; then
    wb_reconcile_action_attach "$kind" "$branch" "$worktree" "$target"
    return
  fi

  local target_file="$TASKS_DIR/$target"
  if [ ! -f "$taskfile" ] || [ ! -f "$target_file" ]; then
    echo "wb reconcile --apply: merge candidate missing ($taskfile or $target_file no longer exists) — skipping this finding" >&2
    return 0
  fi

  local -a survivor_checks=()
  while IFS= read -r line; do survivor_checks+=("$line"); done < <(printf '%s' "$block" | grep -oP '^\s*- \[x\] survivor: \K.*')
  if [ "${#survivor_checks[@]}" -ne 1 ]; then
    echo "wb reconcile --apply: merge for $taskfile <-> $target_file has ${#survivor_checks[@]} survivor choices checked (need exactly 1) — skipping" >&2
    return 0
  fi

  case "${survivor_checks[0]}" in
    "this finding"*) wb_reconcile_merge_content "$taskfile" "$target_file" ;;
    *)                wb_reconcile_merge_content "$target_file" "$taskfile" ;;
  esac
  echo "wb reconcile --apply: merged $taskfile and $target_file"
}

# wb_reconcile_apply — parse the closed review doc's marker-delimited
# blocks and execute exactly the checked actions. Rebuilds any "merge with
# task" block that doesn't have survivor sub-checkboxes yet (appending a
# most-recently-active default) and reopens instead of merging blind.
wb_reconcile_apply() {
  local path; path="$(wb_reconcile_report_path)"
  [ -f "$path" ] || { echo "wb reconcile --apply: no report at $path — run 'wb reconcile --review' first" >&2; return 1; }

  local full_content; full_content="$(cat "$path")"
  local -a blocks=()
  local block="" line in_block=0
  while IFS= read -r line; do
    case "$line" in
      '<!-- wb-reconcile: '*)
        [ "$in_block" = 1 ] && blocks+=("$block")
        block="$line"$'\n'; in_block=1 ;;
      *)
        [ "$in_block" = 1 ] && block+="$line"$'\n' ;;
    esac
  done < "$path"
  [ "$in_block" = 1 ] && blocks+=("$block")

  local reopen_needed=0
  local b kind repo branch worktree taskfile target
  for b in "${blocks[@]}"; do
    kind="$(printf '%s' "$b" | grep -oP 'kind=\K[^ ]+' | head -1)"
    repo="$(printf '%s' "$b" | grep -oP 'repo=\K[^ ]+' | head -1)"
    branch="$(printf '%s' "$b" | grep -oP 'branch=\K[^ ]*' | head -1)"
    worktree="$(printf '%s' "$b" | grep -oP 'worktree=\K[^ ]*' | head -1)"
    taskfile="$(printf '%s' "$b" | grep -oP 'taskfile=\K[^ ]+' | head -1)"

    if printf '%s' "$b" | grep -qE '^- \[x\] do nothing'; then
      continue
    elif printf '%s' "$b" | grep -qE '^- \[x\] discuss'; then
      continue
    elif printf '%s' "$b" | grep -qE '^- \[x\] remove'; then
      wb_reconcile_action_remove "$kind" "$repo" "$branch" "$worktree" "$taskfile"
    elif printf '%s' "$b" | grep -qE '^- \[x\] create a task'; then
      local parent_ref=""
      parent_ref="$(printf '%s' "$b" | grep -oP 'create a task \(optional parent: `\K[^`]+' | head -1)"
      [ "$parent_ref" != '___' ] || parent_ref=""
      wb_reconcile_action_create_task "$kind" "$repo" "$branch" "$worktree" "$parent_ref"
    elif printf '%s' "$b" | grep -qP "^- \[x\] attach to task: \`[^\`_]+\`"; then
      target="$(printf '%s' "$b" | grep -oP '^- \[x\] attach to task: `\K[^`]+' | head -1)"
      wb_reconcile_action_attach "$kind" "$worktree" "$target"
    elif printf '%s' "$b" | grep -qP "^- \[x\] merge with task: \`[^\`_]+\`"; then
      target="$(printf '%s' "$b" | grep -oP '^- \[x\] merge with task: `\K[^`]+' | head -1)"
      if [ "$kind" != orphan ] && ! printf '%s' "$b" | grep -qE '^\s*- \[.\] survivor:'; then
        local target_file="$TASKS_DIR/$target" new_b default_pick
        if [ -f "$target_file" ] && [ -f "$taskfile" ]; then
          local t_self t_target
          t_self="$(stat -c %Y "$taskfile" 2>/dev/null || echo 0)"
          t_target="$(stat -c %Y "$target_file" 2>/dev/null || echo 0)"
          if [ "$t_self" -ge "$t_target" ]; then
            default_pick="self"
          else
            default_pick="target"
          fi
        else
          default_pick="target"
        fi
        local self_box="[ ]" target_box="[ ]"
        [ "$default_pick" = self ] && self_box="[x]" || target_box="[x]"
        new_b="$(printf '%s' "$b" | sed "/^- \\[x\\] merge with task/a\\\\  - $self_box survivor: this finding (new stub)\\n  - $target_box survivor: \`$target\` (existing) <!-- pre-picked: most recently active -->")"
        full_content="${full_content/"$b"/"$new_b"}"
        reopen_needed=1
        continue
      fi
      wb_reconcile_action_merge "$kind" "$repo" "$branch" "$worktree" "$taskfile" "$target" "$b"
    fi
  done

  if [ "$reopen_needed" = 1 ]; then
    printf '%s' "$full_content" > "$path"
    echo "wb reconcile --apply: added survivor choices for new merges — reopening for confirmation"
    wb_open_buffer "$path"
  fi
}

# ---------------------------------------------------------------------------
# wb pause — mark inactive without tearing anything down
# ---------------------------------------------------------------------------

# cmd_pause <session> — flips a task's status to `paused`. Does NOT remove
# the worktree (that's the whole point of "paused, not abandoned") and does
# NOT kill the tmux session (2026-07-08: "I don't want windows or sessions
# to disappear" — same instruction wb done's session-kill removal follows).
# Deliberately skips wb done's dirty-worktree check too: that check exists
# because worktree REMOVAL would destroy uncommitted work, and wb pause
# never removes the worktree, so nothing is at risk to guard against.
cmd_pause() {
  local session="${1:-}"
  if [ -z "$session" ]; then
    [ -n "${TMUX:-}" ] || { echo "wb pause: run inside the target session, or pass a session name" >&2; exit 1; }
    session="$(tmux display-message -p '#S')"
  fi

  local repo slug
  repo="$(tmux show -t "=$session:" -v @wb_repo 2>/dev/null || true)"
  slug="$(tmux show -t "=$session:" -v @wb_slug 2>/dev/null || true)"
  [ -n "$repo" ] && [ -n "$slug" ] \
    || { echo "wb pause: $session has no @wb_repo/@wb_slug — not a wb task session" >&2; exit 1; }

  local disp_slug; disp_slug="$(wb_sanitize "$slug")"
  local task_file; task_file="$(wb_task_file "$repo" "$disp_slug")"
  [ -f "$task_file" ] || { echo "wb pause: no task file for $repo/$slug ($task_file)" >&2; exit 1; }

  wb_set_frontmatter "$task_file" status paused
  echo "wb pause: $session paused — worktree and session untouched, task -> paused ($task_file)"
}

# ---------------------------------------------------------------------------
# wb done — safe wind-down
# ---------------------------------------------------------------------------

# wb_open_buffer <path> — open <path> in nvim, blocking until closed. Same
# tmux-split + wait-for pattern as the decision-buffer / parked-items skills;
# see ~/.claude/skills/decision-buffer/SKILL.md for why the channel must be
# unique per open (a fixed name latches stale signals).
wb_open_buffer() {
  local path="$1"
  if [ -n "${TMUX:-}" ]; then
    local chan="wb-buffer-done-$$-$RANDOM"
    tmux set -p -t "$TMUX_PANE" @claude_blocked nvim-buffer 2>/dev/null || true
    tmux split-window -h -t "$TMUX_PANE" "nvim '$path'; tmux wait-for -S $chan"
    tmux wait-for "$chan"
    tmux set -pu -t "$TMUX_PANE" @claude_blocked 2>/dev/null || true
  else
    "${EDITOR:-nvim}" "$path"
  fi
}

# wb_sweep_section <file> — print only the "## Sweep" section this run
# appended (if present). Keeper extraction must never read checklist-shaped
# lines from the task's own freeform Plan/Follow-ups/Decisions prose.
wb_sweep_section() {
  awk '/^## Sweep \(gitignored/ { found = 1 } found { print }' "$1"
}

# wb_credential_shaped <rel> — succeed when a keeper path looks like a
# credential/secret file. The sweep copies gitignored files into the central
# store — a repo intended for eventual cross-machine git sync — and `wb new`
# bootstraps `.env*` into every worktree by default, so an unguarded
# `- [x] keep .env` would carry live secrets into a repo that may one day
# get a remote (roadmap §2 credential guard, 2026-07-06 review).
wb_credential_shaped() {
  local base
  base="$(basename "$1")"
  shopt -s nocasematch
  local shaped=1
  case "$base" in
    .env|.env.*|*.pem|*.key|*secret*|*credential*|id_rsa*|id_ed25519*|*.p12|*.pfx) shaped=0 ;;
  esac
  shopt -u nocasematch
  return "$shaped"
}

# wb_safe_rel <worktree_path> <rel> — validate that <rel> (as reported by a
# `- [x] keep <rel>` checklist line) resolves to somewhere INSIDE
# <worktree_path>, and print the canonical, `..`-free relative path; prints
# nothing and fails otherwise. The keeper sweep would otherwise `cp -a`
# whatever path a checklist line names with zero containment — an absolute
# path or a `../../` escape can read or overwrite files well outside the
# worktree and the dossier.
wb_safe_rel() {
  local base_real rel="$2" resolved
  case "$rel" in /*) return 1 ;; esac
  base_real="$(realpath -m -- "$1")" || return 1
  resolved="$(realpath -m -- "$1/$rel")" || return 1
  case "$resolved" in
    "$base_real"/*) printf '%s\n' "${resolved#"$base_real"/}" ;;
    *) return 1 ;;
  esac
}

# wb_followup_count — total `## Follow-ups` bullet lines across every task file.
wb_followup_count() {
  local -a files=()
  local f
  while IFS= read -r f; do files+=("$f"); done < <(wb_task_files)
  [ "${#files[@]}" -gt 0 ] || { echo 0; return; }
  awk '
    FNR == 1 { infu = 0 }
    /^## Follow-ups/ { infu = 1; next }
    /^## /           { infu = 0 }
    infu && /^[-*] /  { c++ }
    END { print c + 0 }
  ' "${files[@]}"
}

# wb_parked_count — open items in the /park ledger.
wb_parked_count() {
  jq -c 'select(.status == "open")' "$HOME/.claude/parked-items/ledger.jsonl" 2>/dev/null | wc -l
}

# wb_pending_counts — "<n> follow-ups pending · <m> parked", read by the
# picker's status line and wb done's post-close-out nudge.
wb_pending_counts() {
  printf '%s follow-ups pending · %s parked' "$(wb_followup_count)" "$(wb_parked_count)"
}

# ---------------------------------------------------------------------------
# /board (wb board --html) — 6 status tabs, timeline window, live-session
# badges. `wb board` with no flag keeps the plain-text table below unchanged.
# ---------------------------------------------------------------------------

# wb_board_bucket_for_status <status> — maps a raw task status to one of the
# 6 tabs' underlying buckets. `done` is a real bucket (used by the All tab)
# but has no tab of its own — see R8/R9. Anything unrecognized (including
# a future `pending` status before Deferred is wired up to it) falls to
# `unclassified`, which is a deliberate catch-all, not a bug.
wb_board_bucket_for_status() {
  case "$1" in
    doing|review) echo inprogress ;;
    planned)      echo upcoming ;;
    paused)       echo paused ;;
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
wb_board_collect_rows() {
  local f status repo worktree branch title created closed updated anchor
  local -a t
  while IFS= read -r f; do
    [ -f "$f" ] || continue
    wb_tsv_split "$(wb_read_task "$f")" t
    status="${t[0]:-}"; repo="${t[1]:-}"; worktree="${t[2]:-}"; branch="${t[3]:-}"
    title="$(wb_task_title "$f")"; [ -n "$title" ] || title="$(basename "$f" .md)"
    created="$(wb_get_frontmatter "$f" created)"
    closed="$(wb_get_frontmatter "$f" closed)"
    updated="$(stat -c %Y "$f" 2>/dev/null || echo 0)"
    anchor="$(wb_board_anchor_slug "$(basename "$f" .md)")"
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
      "task" "$(wb_board_bucket_for_status "$status")" "$status" "$repo" \
      "$branch" "$worktree" "$title" "$created" "$closed" "$updated" "$f" "$anchor"
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
      printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
        "untracked" "unclassified" "" "$repo" "$r_branch" "$rel" "$r_branch" \
        "" "" "$updated" "" "$anchor"
    done < <(wb_repo_worktrees "$repo_dir")
  done < <(wb_reconcile_repos)
}

# wb_board_html_escape <string> — minimal HTML-entity escaping for table
# cells, anchor text and attribute values built from task titles/branches,
# which can contain `<`/`&` (R12's escaping test scenario).
wb_board_html_escape() {
  local s="$1"
  # `&` in a bash pattern-substitution REPLACEMENT is a backreference to the
  # match (same as sed) — unescaped, `${s//</&lt;}` produces "<lt;" (match
  # `<` + literal "lt;") instead of "&lt;". `\&` forces a literal ampersand.
  s="${s//&/\&amp;}"; s="${s//</\&lt;}"; s="${s//>/\&gt;}"
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

# wb_board_ledger_matches <worktree_abs_path> — open /park ledger entries
# whose cwd is under this worktree, one compact JSON object per line.
wb_board_ledger_matches() {
  local wt="$1" ledger="$HOME/.claude/parked-items/ledger.jsonl"
  [ -n "$wt" ] && [ -f "$ledger" ] || return 0
  jq -c --arg wt "$wt" \
    'select(.cwd != null and ((.cwd == $wt) or (.cwd | startswith($wt + "/"))))' \
    "$ledger" 2>/dev/null
}

# wb_board_pr_info <repo_dir> <branch> — "#<number> (<state>)" for the most
# recent PR on <branch>, any state (open/closed/merged) — a display nicety
# for a task's detail section, not a drift signal, so unlike
# wb_pr_merge_status this silently returns empty on any gh/pgh failure
# rather than reporting "unknown".
wb_board_pr_info() {
  local repo_dir="$1" branch="$2" out rc
  out="$(cd "$repo_dir" && gh pr list --head "$branch" --state all --json number,state 2>&1)"; rc=$?
  if [ "$rc" -ne 0 ] && printf '%s' "$out" | grep -qi 'could not resolve to a repository'; then
    out="$(cd "$repo_dir" && GH_TOKEN="$(secret-tool lookup service gh account personal 2>/dev/null)" gh pr list --head "$branch" --state all --json number,state 2>&1)"; rc=$?
  fi
  [ "$rc" -eq 0 ] || return 0
  printf '%s' "$out" | jq -r '.[0] // empty | "#\(.number) (\(.state))"' 2>/dev/null
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

# wb_board_related_docs <taskfile> <dotfiles_root> — repo-root-relative
# paths of any docs/plans, docs/brainstorms, docs/solutions, or
# logs/decisions file the task's own prose already names (this repo's
# established convention — see e.g. ~/code/tasks/*.md's "## Decisions"
# sections — is a plain-text path, sometimes backtick-wrapped, sometimes
# prefixed `dotfiles/`, not a markdown link). Deliberately conservative:
# only surfaces a doc the task file already names, never a guessed/fuzzy
# match. When both a .md and its rendered .html sibling exist, prefers the
# .html (nicer to open from a browser); a reference to a since-deleted
# file is dropped rather than linked dead.
wb_board_related_docs() {
  local taskfile="$1" root="$2" rel html_sibling
  [ -f "$taskfile" ] || return 0
  grep -oP '(?:dotfiles/)?(?:docs/(?:plans|brainstorms|solutions)|logs/decisions)/[A-Za-z0-9._/-]+\.(?:md|html)' "$taskfile" 2>/dev/null \
    | sed 's#^dotfiles/##' | sort -u | while IFS= read -r rel; do
      [ -f "$root/$rel" ] || continue
      case "$rel" in
        *.md)
          html_sibling="${rel%.md}.html"
          if [ -f "$root/$html_sibling" ]; then printf '%s\n' "$html_sibling"; else printf '%s\n' "$rel"; fi
          ;;
        *) printf '%s\n' "$rel" ;;
      esac
    done | sort -u
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

# wb_board_render_html — writes the full /board page to stdout: 6 status
# tabs x 2 timeline windows, pre-rendered as 12 panels with CSS-only
# radio-sibling switching (no JS — R8/R10's zero-JS decision), live-session
# badges per row (R11), and per-panel anchor-linked detail sections (R12).
wb_board_render_html() {
  local dotfiles_root
  dotfiles_root="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel 2>/dev/null)"
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
  local cf cparent cstem
  while IFS= read -r cf; do
    cparent="$(wb_get_frontmatter "$cf" parent)"
    [ -n "$cparent" ] || continue
    cstem="$(basename "$cf" .md)"
    wb_task_own_parent "$cparent" "$cstem" || continue
    children_of["$cparent"]+="$cf"$'\n'
  done < <(wb_task_files)

  local -a TABS=(all inprogress upcoming paused deferred unclassified)
  local -A TAB_LABEL=([all]="All" [inprogress]="In Progress" [upcoming]="Upcoming" [paused]="Paused" [deferred]="Deferred" [unclassified]="Unclassified")
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
  local radios_html='' tabs_html='' win_html='' panel_css='' panels_html='' highlight_css=''
  local win tab first_win=1 first_tab=1
  for win in "${WINDOWS[@]}"; do
    local checked=""; [ "$first_win" = 1 ] && checked=" checked" && first_win=0
    radios_html+="<input type=\"radio\" name=\"tl\" id=\"tl-$win\"$checked>"$'\n'
    win_html+="<label for=\"tl-$win\">${WIN_LABEL[$win]}</label>"$'\n'
    highlight_css+="#tl-$win:checked ~ header label[for=\"tl-$win\"] { background: var(--acc); color: white; }"$'\n'
  done
  for tab in "${TABS[@]}"; do
    local checked=""; [ "$first_tab" = 1 ] && checked=" checked" && first_tab=0
    radios_html+="<input type=\"radio\" name=\"st\" id=\"st-$tab\"$checked>"$'\n'
    tabs_html+="<label for=\"st-$tab\">${TAB_LABEL[$tab]}</label>"$'\n'
    highlight_css+="#st-$tab:checked ~ header label[for=\"st-$tab\"] { background: var(--acc); color: white; }"$'\n'
  done

  local row kind bucket status repo branch worktree title created closed updated taskfile anchor_key
  local -a f
  for win in "${WINDOWS[@]}"; do
    local window_start; window_start="$(wb_board_window_start "$win")"
    for tab in "${TABS[@]}"; do
      panel_css+="#tl-$win:checked ~ #st-$tab:checked ~ main #panel-$tab-$win { display: flex; }"$'\n'
      local table_rows='' detail_sections='' any=0
      for row in "${ROWS[@]}"; do
        wb_tsv_split "$row" f
        kind="${f[0]}"; bucket="${f[1]}"; status="${f[2]}"; repo="${f[3]}"; branch="${f[4]}"
        worktree="${f[5]}"; title="${f[6]}"; created="${f[7]}"; closed="${f[8]}"; updated="${f[9]}"
        taskfile="${f[10]}"; anchor_key="${f[11]}"
        [ "$tab" = all ] || [ "$bucket" = "$tab" ] || continue
        wb_board_in_window "$created" "$closed" "$updated" "$window_start" || continue
        any=1
        local view_anchor="t-$tab-$win-$anchor_key"
        local esc_title esc_branch esc_repo pill_class pill_label live_session live_badge
        esc_title="$(wb_board_html_escape "$title")"
        esc_branch="$(wb_board_html_escape "$branch")"
        esc_repo="$(wb_board_html_escape "$repo")"
        pill_class="$status"; pill_label="$status"
        [ "$kind" = untracked ] && { pill_class="unclassified"; pill_label="unclassified"; }
        live_session="$(wb_board_live_session_for "$repo" "$branch")"
        live_badge=""
        [ -n "$live_session" ] && live_badge="<span class=\"live-badge\"><span class=\"dot\">&#9679;</span>$(wb_board_html_escape "$live_session")</span>"
        local link_text="$esc_title"
        [ "$kind" = untracked ] && link_text="$esc_branch <span class=\"repo\">(no task file)</span>"
        table_rows+="<tr class=\"row\"><td><span class=\"pill $pill_class\">$pill_label</span></td><td><a class=\"tasklink\" href=\"#$view_anchor\">$link_text</a> $live_badge</td><td class=\"repo\">$esc_repo</td></tr>"$'\n'

        if [ "$kind" = untracked ]; then
          detail_sections+="<div class=\"task-detail untracked\" id=\"$view_anchor\"><h3>$esc_branch <span class=\"pill unclassified\">unclassified</span>$live_badge<a class=\"back\" href=\"#\">&#8593; back</a></h3><span class=\"repo\">$esc_repo</span><p><b>No task file.</b> Worktree exists on disk (<code>$(wb_board_html_escape "$worktree")</code>) with no matching entry in the task store.</p></div>"$'\n'
        else
          local plan done_txt followups decisions repo_dir wt_abs pr_info detail_extra=""
          detail_extra+="<p>$(wb_board_summary_line "$status" "$esc_repo" "$esc_branch" "$created" "$closed")</p>"
          plan="$(wb_board_first_nonblank_line "$(wb_board_section "$taskfile" Plan)")"
          done_txt="$(wb_board_first_nonblank_line "$(wb_board_section "$taskfile" Done)")"
          [ -n "$plan" ] && detail_extra+="<p><b>Plan:</b> $(wb_board_html_escape "$plan")</p>"
          [ -n "$done_txt" ] && detail_extra+="<p><b>Done:</b> $(wb_board_html_escape "$done_txt")</p>"
          repo_dir="$(wb_repo_dir "$repo")"
          if [ -d "$repo_dir/.git" ]; then
            pr_info="$(wb_board_pr_info "$repo_dir" "$branch")"
            [ -n "$pr_info" ] && detail_extra+="<p><b>Related:</b> <span class=\"artefact-chip\">PR $(wb_board_html_escape "$pr_info")</span></p>"
          fi
          wt_abs="$repo_dir/$worktree"
          local ledger_line ledger_note=""
          while IFS= read -r ledger_line; do
            [ -n "$ledger_line" ] || continue
            ledger_note+="$(printf '%s' "$ledger_line" | jq -r '.note // empty' 2>/dev/null); "
          done < <(wb_board_ledger_matches "$wt_abs")
          [ -n "$ledger_note" ] && detail_extra+="<p><b>Parked:</b> $(wb_board_html_escape "$ledger_note")</p>"
          local own_docs doc_links
          own_docs="$(wb_board_related_docs "$taskfile" "$dotfiles_root")"
          doc_links="$(wb_board_task_doc_chips "$taskfile" "$dotfiles_root")"
          [ -n "$doc_links" ] && detail_extra+="<p><b>Docs:</b> $doc_links</p>"

          local h3="<h3>$esc_title <span class=\"pill $pill_class\">$pill_label</span>$live_badge<a class=\"back\" href=\"#\">&#8593; back</a></h3>"
          local stem; stem="$(basename "$taskfile" .md)"
          if [ -n "${children_of[$stem]:-}" ]; then
            local own_count; own_count="$(printf '%s' "$own_docs" | grep -c . || true)"
            local children_html='' crow_file crow_status crow_title crow_chips
            while IFS= read -r crow_file; do
              [ -n "$crow_file" ] && [ -f "$crow_file" ] || continue
              crow_status="$(wb_get_frontmatter "$crow_file" status)"
              crow_title="$(wb_task_title "$crow_file")"; [ -n "$crow_title" ] || crow_title="$(basename "$crow_file" .md)"
              crow_chips="$(wb_board_task_doc_chips "$crow_file" "$dotfiles_root")"
              children_html+="<div class=\"child-row\"><span class=\"pill $crow_status\">$(wb_board_html_escape "$crow_status")</span> $(wb_board_html_escape "$crow_title") $crow_chips</div>"$'\n'
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

            detail_sections+="<div class=\"task-detail\" id=\"$view_anchor\"><details open class=\"parent-row\"><summary>$h3<span class=\"own-count\">$own_count of its own artifacts</span></summary><span class=\"repo\">$esc_repo</span>$detail_extra<div class=\"children\">$children_html</div>$rollup_html</details></div>"$'\n'
          else
            detail_sections+="<div class=\"task-detail\" id=\"$view_anchor\">$h3<span class=\"repo\">$esc_repo</span>$detail_extra</div>"$'\n'
          fi
        fi
      done

      if [ "$any" = 1 ]; then
        panels_html+="<div class=\"view\" id=\"panel-$tab-$win\"><table><tr><th>Status</th><th>Task</th><th>Repo</th></tr>$table_rows</table><div><p class=\"details-heading\">Task details</p><div class=\"details-stack\">$detail_sections</div></div></div>"$'\n'
      elif [ "$tab" = deferred ]; then
        panels_html+="<div class=\"view\" id=\"panel-$tab-$win\"><div class=\"empty-state\">No deferred tasks yet — reserved for a future <code>pending</code> status once <code>/park</code> items become task-store entries. Not part of this PR.</div></div>"$'\n'
      else
        panels_html+="<div class=\"view\" id=\"panel-$tab-$win\"><div class=\"empty-state\">No tasks in this view.</div></div>"$'\n'
      fi
    done
  done

  cat <<HTMLEOF
<title>&#9673; /board</title>
<meta name="viewport" content="width=device-width, initial-scale=1">
<style>
  :root {
    --bg: #eff1f5; --bg2: #e6e9ef; --panel: #ffffff; --line: #ccd0da;
    --ink: #4c4f69; --ink2: #5c5f77; --mut: #8c8fa1;
    --acc: #8839ef; --acc2: #04a5e5;
    --doing: #04a5e5; --review: #df8e1d; --planned: #8c8fa1; --done: #40a02b; --paused: #209fb5;
    --unclassified: #8839ef; --ok: #40a02b;
    --mono: ui-monospace, "JetBrainsMono Nerd Font", "MesloLGL Nerd Font", "Cascadia Code", Menlo, Consolas, monospace;
    --sans: system-ui, "Segoe UI", Roboto, Ubuntu, sans-serif;
  }
  @media (prefers-color-scheme: dark) {
    :root { --bg: #303446; --bg2: #292c3c; --panel: #363a4f; --line: #51576d; --ink: #c6d0f5; --ink2: #a5adce; --mut: #838ba7;
      --acc: #ca9ee6; --acc2: #99d1db; --doing: #99d1db; --review: #e5c890; --planned: #838ba7; --done: #a6d189; --paused: #85c1dc; --unclassified: #ca9ee6; --ok: #a6d189; }
  }
  :root[data-theme="dark"] { --bg: #303446; --bg2: #292c3c; --panel: #363a4f; --line: #51576d; --ink: #c6d0f5; --ink2: #a5adce; --mut: #838ba7;
    --acc: #ca9ee6; --acc2: #99d1db; --doing: #99d1db; --review: #e5c890; --planned: #838ba7; --done: #a6d189; --paused: #85c1dc; --unclassified: #ca9ee6; --ok: #a6d189; }
  :root[data-theme="light"] { --bg: #eff1f5; --bg2: #e6e9ef; --panel: #ffffff; --line: #ccd0da; --ink: #4c4f69; --ink2: #5c5f77; --mut: #8c8fa1;
    --acc: #8839ef; --acc2: #04a5e5; --doing: #04a5e5; --review: #df8e1d; --planned: #8c8fa1; --done: #40a02b; --paused: #209fb5; --unclassified: #8839ef; --ok: #40a02b; }

  * { box-sizing: border-box; }
  html { color-scheme: light dark; scroll-behavior: smooth; }
  body { background: var(--bg); color: var(--ink); font-family: var(--sans); margin: 0; font-size: 15px; line-height: 1.5; }
  input[type=radio] { display: none; }
  header { padding: 1.2rem 1.5rem; border-bottom: 1px solid var(--line); background: var(--bg2); position: sticky; top: 0; z-index: 5; }
  header h1 { font-family: var(--mono); font-size: 1.1rem; margin: 0 0 .8rem; }
  .tabs { display: flex; gap: .4rem; flex-wrap: wrap; }
  .tabgroup { display: flex; gap: .25rem; background: var(--panel); border: 1px solid var(--line); border-radius: 8px; padding: .25rem; flex-wrap: wrap; }
  .tabgroup label { font-family: var(--mono); font-size: .78rem; padding: .35rem .8rem; border-radius: 6px; cursor: pointer; color: var(--ink2); }

  main { padding: 1.5rem; max-width: 60rem; margin: 0 auto; }
  .view { display: none; flex-direction: column; gap: 2rem; }
  table { width: 100%; border-collapse: collapse; background: var(--panel); border: 1px solid var(--line); border-radius: 8px; overflow: hidden; }
  th { text-align: left; font-family: var(--mono); font-size: .72rem; text-transform: uppercase; letter-spacing: .05em; color: var(--mut); padding: .6rem .9rem; border-bottom: 1px solid var(--line); }
  td { padding: .65rem .9rem; border-bottom: 1px solid var(--line); font-size: .9rem; }
  tr:last-child td { border-bottom: none; }
  tr.row:hover { background: var(--bg2); }
  td a.tasklink { color: var(--acc2); text-decoration: none; font-weight: 600; }
  td a.tasklink:hover { text-decoration: underline; }
  .pill { display: inline-flex; align-items: center; gap: .35em; font-family: var(--mono); font-size: .72rem; padding: .1em .6em; border-radius: 999px; border: 1px solid currentColor; }
  .pill.doing { color: var(--doing); } .pill.review { color: var(--review); } .pill.planned { color: var(--planned); } .pill.done { color: var(--done); } .pill.paused { color: var(--paused); } .pill.unclassified { color: var(--unclassified); }
  .repo { font-family: var(--mono); font-size: .78rem; color: var(--mut); }
  .live-badge { display: inline-flex; align-items: center; gap: .3em; font-family: var(--mono); font-size: .7rem; color: var(--ok); }
  .empty-state { padding: 1.6rem; text-align: center; color: var(--mut); font-family: var(--mono); font-size: .85rem; background: var(--panel); border: 1px dashed var(--line); border-radius: 8px; }

  .details-heading { font-family: var(--mono); font-size: .78rem; text-transform: uppercase; letter-spacing: .05em; color: var(--mut); border-bottom: 1px solid var(--line); padding-bottom: .5rem; margin: 0; }
  .details-stack { display: flex; flex-direction: column; gap: .8rem; }
  .task-detail { background: var(--panel); border: 1px solid var(--line); border-radius: 8px; padding: 1rem 1.2rem; scroll-margin-top: 8rem; }
  .task-detail:target { border-color: var(--acc); box-shadow: 0 0 0 3px color-mix(in srgb, var(--acc) 25%, transparent); }
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
  $panel_css
  $highlight_css
</style>
$radios_html
<header>
  <h1>&#9673; /board</h1>
  <div class="tabs">
    <div class="tabgroup">$win_html</div>
    <div class="tabgroup">$tabs_html</div>
  </div>
</header>
<main>
$panels_html
</main>
HTMLEOF
}

# cmd_board — read-only status table over the whole task store (the interim
# /board, roadmap 9a / Decision 5A). The picker deliberately shows PRESENCE
# only, which hides planned/done tasks entirely — this is the one place they
# stay visible until the full /board feature exists. Reads the same
# frontmatter wb done writes (one-board principle at the data layer); never
# touches tmux, so it works from any shell.
cmd_board() {
  if [ "${1:-}" = "--html" ]; then
    # logs/board.html lives in THIS repo (dotfiles), same as logs/decisions/
    # — derive the root from wb.sh's own location rather than assuming the
    # repo is literally named "dotfiles" under CODE_DIR.
    local dotfiles_root
    dotfiles_root="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel 2>/dev/null)"
    [ -n "$dotfiles_root" ] || dotfiles_root="$CODE_DIR/dotfiles"
    local out="$dotfiles_root/logs/board.html"
    mkdir -p "$(dirname "$out")"
    wb_board_render_html > "$out"
    echo "wb board: wrote $out"
    return 0
  fi

  local f title fu rows=""
  local -a t
  while IFS= read -r f; do
    [ -f "$f" ] || continue
    wb_tsv_split "$(wb_read_task "$f")" t
    title="$(wb_task_title "$f")"
    [ -n "$title" ] || title="$(basename "$f" .md)"
    fu="$(awk '
      BEGIN { infu = 0 }
      /^## Follow-ups/ { infu = 1; next }
      /^## /           { infu = 0 }
      infu && /^[-*] / { c++ }
      END { print c + 0 }
    ' "$f")"
    rows+="$(printf '%s\t%s\t%s\t%s' "${t[0]:-?}" "${t[1]:-?}" "$title" "$fu")"$'\n'
  done < <(wb_task_files)

  if [ -z "$rows" ]; then
    echo "wb board: no tasks in $TASKS_DIR"
    return 0
  fi

  {
    printf 'STATUS\tREPO\tTASK\tFOLLOW-UPS\n'
    # doing < review < paused < planned < done < anything-else; rank prefix
    # keeps the plain-text sort key clean, then drops out before display.
    printf '%s' "$rows" | awk -F'\t' -v OFS='\t' '{
      r = ($1 == "doing") ? 0 : ($1 == "review") ? 1 : ($1 == "paused") ? 2 : ($1 == "planned") ? 3 : ($1 == "done") ? 4 : 5
      print r, $0
    }' | sort -t $'\t' -k1,1n -k3,3 -k4,4 | cut -f2-
  } | column -t -s $'\t'
}

cmd_done() {
  # Index/shift case parser, not a single-token foreach — mirrors cmd_new's
  # --parent handling so --close can appear before, after, or without the
  # optional session positional.
  local close=0
  local -a args=()
  while [ $# -gt 0 ]; do
    case "$1" in
      --close) close=1; shift ;;
      *)       args+=("$1"); shift ;;
    esac
  done

  local session="${args[0]:-}"
  if [ -z "$session" ]; then
    [ -n "${TMUX:-}" ] || { echo "wb done: run inside the target session, or pass a session name" >&2; exit 1; }
    session="$(tmux display-message -p '#S')"
  fi

  # -v alone (no -p) so it cascades to the session-scoped value set-option
  # wrote in cmd_new — -p demands a pane-local value and errors "invalid option".
  local repo slug
  repo="$(tmux show -t "=$session:" -v @wb_repo 2>/dev/null || true)"
  slug="$(tmux show -t "=$session:" -v @wb_slug 2>/dev/null || true)"
  [ -n "$repo" ] && [ -n "$slug" ] \
    || { echo "wb done: $session has no @wb_repo/@wb_slug — not a wb task session" >&2; exit 1; }

  local repo_dir="$CODE_DIR/$repo"
  local worktree_path="$repo_dir/.worktrees/$slug"
  local disp_slug; disp_slug="$(wb_sanitize "$slug")"
  local task_file; task_file="$(wb_task_file "$repo" "$disp_slug")"

  # 1. fail fast — never mutate anything on a dirty tree.
  local dirty
  dirty="$(git -C "$worktree_path" status --porcelain 2>/dev/null || true)"
  if [ -n "$dirty" ]; then
    echo "wb done: $worktree_path is dirty:" >&2
    echo "$dirty" >&2
    echo "commit or stash, then re-run" >&2
    exit 1
  fi

  # 2. review buffer — the task file itself IS the buffer (it already lives
  # centrally and survives `git worktree remove`, so there's no copy to sync
  # back). Append a throwaway ## Sweep section listing every gitignored file
  # `git worktree remove` would otherwise silently destroy; `- [x] keep` marks
  # survivors, same convention as decision-buffer.
  local ignored
  ignored="$(git -C "$worktree_path" status --porcelain --ignored 2>/dev/null \
    | awk '$1 == "!!" { $1 = ""; sub(/^ /, ""); print }' || true)"
  if [ -n "$ignored" ]; then
    {
      echo
      echo "## Sweep (gitignored — check keep before closing; git worktree remove destroys the rest)"
      echo
      while IFS= read -r f; do
        echo "- [ ] keep $f"
      done <<< "$ignored"
    } >> "$task_file"

    wb_open_buffer "$task_file"

    local dossier="$TASKS_DIR/dossiers/${repo}--${disp_slug}"
    local -a safe_kept=()
    local f safe
    # Scope to the section this run appended (never the task's own freeform
    # prose — see wb_sweep_section), and validate every path stays inside
    # the worktree (see wb_safe_rel) before it's ever handed to cp.
    while IFS= read -r f; do
      [ -n "$f" ] || continue
      f="${f%/}"   # git reports whole ignored dirs with a trailing slash (e.g. "logs/")
      safe="$(wb_safe_rel "$worktree_path" "$f")" \
        || { echo "wb done: refusing to sweep unsafe path: $f" >&2; continue; }
      if wb_credential_shaped "$safe"; then
        echo "wb done: NOT sweeping credential-shaped keeper: $safe (the store may sync; copy it by hand if you truly need it)" >&2
        continue
      fi
      [ -e "$worktree_path/$safe" ] || continue
      safe_kept+=("$safe")
    done < <(wb_sweep_section "$task_file" | grep -oP '^- \[x\] keep \K.*' || true)

    # Kept DIRECTORIES are walked file-by-file rather than cp -a'd whole:
    # git reports an ignored dir as one keeper entry ("logs/"), so a blind
    # recursive copy would carry a credential-shaped file INSIDE it (e.g.
    # logs/.env) past the guard that only saw the top-level path.
    local inner rel
    for f in "${safe_kept[@]}"; do
      if [ -d "$worktree_path/$f" ]; then
        while IFS= read -r -d '' inner; do
          rel="${inner#"$worktree_path"/}"
          if wb_credential_shaped "$rel"; then
            echo "wb done: NOT sweeping credential-shaped file inside kept dir: $rel (copy it by hand if you truly need it)" >&2
            continue
          fi
          mkdir -p "$dossier/$(dirname "$rel")"
          cp -a "$inner" "$dossier/$rel"
        done < <(find "$worktree_path/$f" \( -type f -o -type l \) -print0)
      else
        mkdir -p "$dossier/$(dirname "$f")"
        cp -a "$worktree_path/$f" "$dossier/$f"
      fi
    done

    # drop the transient Sweep section; if anything was kept, record where it went.
    awk '/^## Sweep \(gitignored/ { exit } { print }' "$task_file" > "$task_file.tmp.$$"
    mv "$task_file.tmp.$$" "$task_file"
    if [ "${#safe_kept[@]}" -gt 0 ]; then
      {
        echo
        for f in "${safe_kept[@]}"; do
          echo "- kept: \`$f\` -> \`${dossier#"$HOME"/}/$f\`"
        done
      } >> "$task_file"
    fi
  else
    wb_open_buffer "$task_file"
  fi

  # 3. remove the worktree BEFORE flipping status:
  #    - flipping status to "done" before a possibly-failing removal would
  #      leave the store claiming done while the worktree still exists;
  #      removing first means status only ever reflects a real teardown.
  #    - the existence guard makes a retry safe after a prior run was
  #      killed between removal and status-set: `git worktree remove` on an
  #      already-gone path hard-fails under set -e otherwise.
  #    Branch is kept — see logs/decisions/2026-07-06-review-outstanding.md Q2.
  #    The tmux session is deliberately left alive by default — wb done tears
  #    down the worktree, not the window you're sitting in (2026-07-08: "I
  #    don't want windows or sessions to disappear"; same reasoning as wb
  #    pause). See --close below for the explicit opt-in to also kill it.
  if [ -d "$worktree_path" ]; then
    git -C "$repo_dir" worktree remove "$worktree_path" --force
  fi
  wb_set_frontmatter "$task_file" status done
  wb_set_frontmatter "$task_file" closed "$(date +%F)"

  echo "wb done: $session closed — worktree removed, task -> done ($task_file)"

  local total=$(( $(wb_followup_count) + $(wb_parked_count) ))
  if [ "$total" -ge "$WB_SWEEP_THRESHOLD" ]; then
    echo "wb done: $(wb_pending_counts) — consider running /parked-items"
  fi

  # --close is opt-in, not a revert of the wb-pause-era decision above: the
  # session survives by default, and only this explicit flag reaches for
  # the kill. Best-effort (|| true) — by this point the state that matters
  # (worktree removed, status flipped) is already done and echoed, so a
  # racing/already-gone session must not abort the script under set -e.
  [ "$close" -eq 1 ] && tmux kill-session -t "=$session" 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# wb — the picker
# ---------------------------------------------------------------------------
# Rows are sourced from PRESENCE (live tmux state), not inventory — a
# `planned` task with no worktree yet, or a repo under ~/code that's never
# been opened, doesn't show up. Use `wb new <repo> <slug>` directly to start
# or resume one of those; the picker is for "what's live right now."
#
# Three modes, cycled with Tab (persisted in a per-invocation mode file so
# the auto-refresh and manual reloads stay on whichever mode you're in):
#   combined (default) — one row per live tmux session, multi-agent sessions
#                         expanded into sub-rows
#   sessions            — one row per live tmux session, collapsed (no sub-rows)
#   agents              — one row per running claude pane, globally, ranked by
#                         urgency (no session grouping) — replaces `ca`
#
# Row schema, as produced by collect_*_rows (tab-separated), shared by
# task/repo/agent rows:
#   1 repo   2 label   3 branch (git branch, in brackets)   4 urank
#   5 icon_label
#   6 target (hidden pane target, may be empty)
#   7 session (the live tmux session this row belongs to)
#   8 ref (task file path, or repo dir for repo rows)
#   9 kind (task|repo|agent)   10 ucount (claude panes in session)
#   11 slug (task rows only — real, slash-preserving; used to resume via wb new)
#   12 sib (set to "1" by wb_parent_subrows on a live sibling sharing a
#      parent:, so it indents distinctly from an agent-pane sub-row —
#      empty on every other row kind)
# wb_format_for_display (used by render_rows) prepends a pre-rendered,
# fixed-width display string as a NEW field 1, shifting all of the above by
# one (repo becomes field 2, ..., sib becomes field 13) — that's the shape
# fzf and picker()'s final `read` actually see. The displayed TYPE column
# (session/agent/both) isn't a stored field — it's derived at display time
# from kind + ucount.

# wb_status_icon <status> — print "icon\tlabel" for one of the pane statuses
# tmux_claude_panes emits (needs-input/done/waiting/working/idle). Shared by
# wb_session_urgency and wb_agent_subrows so this mapping lives in one place.
wb_status_icon() {
  # Plain ASCII, deliberately: the previous glyphs (◆✔○●·) are Unicode
  # symbol/block characters whose rendered cell width isn't guaranteed
  # across every terminal font (some fall back to a non-monospace symbol
  # font for them), which was throwing off alignment in a way that no
  # amount of correct padding math could fix from this end.
  case "$1" in
    needs-input) printf '!\tneeds you\n' ;;
    done)        printf '+\tfinished\n' ;;
    waiting)     printf 'o\tdone\n' ;;
    working)     printf '*\tworking\n' ;;
    *)           printf -- '-\tidle\n' ;;
  esac
}

# wb_session_urgency <session> — "<rank>\t<icon_label>\t<target>\t<count>" for
# the most-urgent claude pane in <session>, or the "no agent" default.
wb_session_urgency() {
  local rows count rank target status task
  rows="$(tmux_claude_panes "$1" | sort -n)"
  if [ -z "$rows" ]; then
    printf '3\t- no agent\t\t0\n'   # ASCII "-", see wb_status_icon
    return
  fi
  count="$(printf '%s\n' "$rows" | grep -c . || true)"
  IFS=$'\t' read -r rank target status task <<< "$(head -n1 <<< "$rows")"
  local icon label
  IFS=$'\t' read -r icon label < <(wb_status_icon "$status")
  printf '%s\t%s %s\t%s\t%s\n' "$rank" "$icon" "$label" "$target" "$count"
}

# wb_agent_subrows <repo> <session> <ref> <branch> — one sub-row per claude
# pane in a multi-agent session (kept out of the collapsed parent row).
# <branch> repeats the parent row's branch (same session, same checkout) so
# every row is self-contained instead of leaving it blank on sub-rows.
wb_agent_subrows() {
  local repo="$1" session="$2" ref="$3" branch="$4"
  local rank target status task icon label
  while IFS=$'\t' read -r rank target status task; do
    IFS=$'\t' read -r icon label < <(wb_status_icon "$status")
    printf '%s\t%s\t%s\t%s\t%s %s\t%s\t%s\t%s\tagent\t1\t\t\n' \
      "$repo" "$task" "$branch" "$rank" "$icon" "$label" "$target" "$session" "$ref"
  done < <(tmux_claude_panes "$session" | sort -n)
}

# wb_live_session_row <session> — one row for a live tmux session. If it's a
# wb task session (@wb_repo/@wb_slug set), shows the task's title/status from
# the store; otherwise shows the session name and, if its cwd is a git repo,
# the current branch — same shape a plain `s`-created session gets.
wb_live_session_row() {
  local session="$1" repo slug disp_slug task_file branch label statuscol kind ref slug_out=""
  repo="$(tmux show -t "=$session:" -v @wb_repo 2>/dev/null || true)"
  slug="$(tmux show -t "=$session:" -v @wb_slug 2>/dev/null || true)"
  if [ -n "$repo" ] && [ -n "$slug" ]; then
    disp_slug="$(wb_sanitize "$slug")"
    task_file="$(wb_task_file "$repo" "$disp_slug")"
    if [ -f "$task_file" ]; then
      local -a _wt; wb_tsv_split "$(wb_read_task "$task_file")" _wt
      branch="${_wt[3]}"
      label="$(wb_task_title "$task_file")"; [ -n "$label" ] || label="$slug"
    else
      branch="$slug"; label="$slug"
    fi
    statuscol="[$branch]"; kind="task"; ref="$task_file"; slug_out="$slug"
  else
    repo="$session"; label="$session"; kind="repo"
    ref="$(tmux display-message -p -t "=$session:" '#{pane_current_path}' 2>/dev/null || true)"
    statuscol="[$(git -C "$ref" branch --show-current 2>/dev/null || true)]"
  fi

  local -a _u; wb_tsv_split "$(wb_session_urgency "$session")" _u
  local urank="${_u[0]}" uicon="${_u[1]}" target="${_u[2]}" ucount="${_u[3]}"

  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t\n' \
    "$repo" "$label" "$statuscol" "$urank" "$uicon" "$target" "$session" "$ref" "$kind" "$ucount" "$slug_out"
}

# collect_live_rows — one row per live tmux session, no sub-row expansion.
collect_live_rows() {
  local session
  while IFS= read -r session; do
    [ -n "$session" ] || continue
    wb_live_session_row "$session"
  done < <(tmux list-sessions -F '#{session_name}' 2>/dev/null)
}

# wb_emit_with_agents <row> — print <row>, then expand its agent sub-rows
# via wb_agent_subrows when it has more than one live claude pane. Shared by
# every emission point in collect_combined_rows (an ungrouped row, a
# parent-group anchor, or a sibling sub-row) so agent-pane expansion never
# depends on which path a row took to get emitted.
wb_emit_with_agents() {
  local row="$1" repo branch session ref ucount
  printf '%s\n' "$row"
  local -a f; wb_tsv_split "$row" f
  repo="${f[0]}"; branch="${f[2]}"; session="${f[6]}"; ref="${f[7]}"; ucount="${f[9]}"
  [ "${ucount:-0}" -gt 1 ] 2>/dev/null && wb_agent_subrows "$repo" "$session" "$ref" "$branch"; true
}

# wb_parent_subrows <row> — return <row> with its sibling marker (field 12)
# set to "1", so wb_format_for_display indents it as a sibling sub-row,
# distinct from an agent-pane sub-row. Everything else — including kind,
# still "task" — is untouched: a sibling sub-row is an independently live
# session, not a pane within one.
wb_parent_subrows() {
  awk -F'\t' -v OFS='\t' '{ $12 = "1"; print }' <<< "$1"
}

# collect_combined_rows — buffers collect_live_rows' urgency-sorted output
# into an array (two passes, not a stream): deciding a parent-shared group's
# anchor by created: date needs to see every live sibling before emitting
# any of them, the same reason wb_board_render_html buffers its own
# ROWS=() rather than streaming.
#
# Pass 1 reads each row's own task file's parent: field once (empty when the
# row has no task file, no parent set, or the parent equals the row's own
# stem — self-reference is ignored, same guard U3's children map uses).
# Pass 2 emits: an unconsumed row whose parent is shared by at least one
# other unconsumed row picks the earliest-created: sibling as the anchor —
# stable across refreshes, unlike live urgency rank, which cycles as an
# agent works — emits it first (even if it isn't the row the scan is
# currently on), then every other sibling right after as an indented
# sub-row via wb_parent_subrows, marking the whole group consumed. A row
# with no shared-parent sibling emits unchanged, exactly as before this
# grouping existed.
collect_combined_rows() {
  local -a rows=()
  local line
  while IFS= read -r line; do rows+=("$line"); done \
    < <(collect_live_rows | sort -t $'\t' -k4,4n -k1,1 -k2,2)

  local -A parent_of=()
  local i kind ref stem parent
  local -a f
  for i in "${!rows[@]}"; do
    wb_tsv_split "${rows[$i]}" f
    kind="${f[8]}"; ref="${f[7]}"; parent=""
    if [ "$kind" = task ] && [ -f "$ref" ]; then
      parent="$(wb_get_frontmatter "$ref" parent)"
      stem="$(basename "$ref" .md)"
      wb_task_own_parent "$parent" "$stem" || parent=""
    fi
    parent_of[$i]="$parent"
  done

  local -A consumed=()
  local j anchor anchor_created created
  local -a group fj
  for i in "${!rows[@]}"; do
    [ -n "${consumed[$i]:-}" ] && continue
    parent="${parent_of[$i]}"
    if [ -z "$parent" ]; then
      wb_emit_with_agents "${rows[$i]}"
      consumed[$i]=1
      continue
    fi

    group=()
    for j in "${!rows[@]}"; do
      [ -n "${consumed[$j]:-}" ] && continue
      [ "${parent_of[$j]}" = "$parent" ] && group+=("$j")
    done
    if [ "${#group[@]}" -le 1 ]; then
      wb_emit_with_agents "${rows[$i]}"
      consumed[$i]=1
      continue
    fi

    anchor=""; anchor_created=""
    for j in "${group[@]}"; do
      wb_tsv_split "${rows[$j]}" fj
      created="$(wb_get_frontmatter "${fj[7]}" created)"
      if [ -z "$anchor" ]; then
        anchor="$j"; anchor_created="$created"
      elif [ -n "$created" ] && { [ -z "$anchor_created" ] || [[ "$created" < "$anchor_created" ]]; }; then
        anchor="$j"; anchor_created="$created"
      fi
    done

    wb_emit_with_agents "${rows[$anchor]}"
    consumed[$anchor]=1
    for j in "${group[@]}"; do
      [ "$j" = "$anchor" ] && continue
      wb_emit_with_agents "$(wb_parent_subrows "${rows[$j]}")"
      consumed[$j]=1
    done
  done
}

# collect_agent_rows — one row per running claude pane, globally, ranked by
# urgency with no session grouping. Replaces `ca`.
collect_agent_rows() {
  local rank target status task icon label sess
  while IFS=$'\t' read -r rank target status task; do
    IFS=$'\t' read -r icon label < <(wb_status_icon "$status")
    sess="${target%%:*}"
    printf '%s\t%s\t\t%s\t%s %s\t%s\t%s\t%s\tagent\t1\t\t\n' \
      "$sess" "$task" "$rank" "$icon" "$label" "$target" "$sess" "$sess"
  done < <(tmux_claude_panes | sort -n)
}

# wb_format_for_display — prepend a fixed-width, colored display string as a
# NEW field 1, pushing the original 11 fields to 2-12. Must run AFTER sorting
# (coloring/padding first would corrupt any sort keyed on the plain fields).
#
# fzf's --with-nth re-joins displayed fields with the raw tab delimiter, and
# a raw tab always jumps to the terminal's next fixed 8-column stop — so
# variable-length content (a long branch name, a long task title) throws off
# every column after it. Pre-rendering one string with explicit space padding
# (same approach claude-sessions.sh already uses) sidesteps that entirely;
# --with-nth=1 then shows ONLY this field, with the real data addressable as
# hidden fields 2-12 for binds/preview.
wb_format_for_display() {
  awk -F'\t' -v OFS='\t' -v w1="$WB_COL_REPO" -v w2="$WB_COL_LABEL" -v w3="$WB_COL_TYPE" \
      -v w4="$WB_COL_BRANCH" -v w5="$WB_COL_STATUS" '
      function pad(s, w,    n) {
        n = length(s)
        # ASCII "..." on purpose, not a "…" glyph: some terminals render
        # that single codepoint as an ambiguous-width (2-column) character,
        # which silently threw off every column after it on truncated rows
        # while untruncated rows stayed correct — exactly the kind of
        # alignment bug that is invisible until a row actually truncates.
        if (n > w) return substr(s, 1, w - 3) "..."
        return s sprintf("%*s", w - n, "")
      }
      BEGIN { m = "\033[1;35m"; g = "\033[32m"; y = "\033[33m"; d = "\033[90m"; cy = "\033[36m"; r = "\033[0m" }
      {
        icon = $5; sub(/ .*/, "", icon)
        lbl = $5; sub(/^[^ ]+ /, "", lbl)
        if      (lbl == "needs you") c = m
        else if (lbl == "finished")  c = cy
        else if (lbl == "done")      c = g
        else if (lbl == "working")   c = y
        else                         c = d
        # TYPE: is this row a bare session (no agent), a session that also
        # has one, or a sub-row for one specific agent pane? Derived from
        # kind ($9) + agent-pane count ($10), not a separate stored field.
        if      ($9 == "agent")   type = "agent"
        else if ($(10) + 0 >= 1)  type = "both"
        else                      type = "session"
        # Pad the icon and label SEPARATELY, never together: awk counts
        # bytes, not display columns, and padding the combined "icon label"
        # string as one unit overcounts whenever the icon is multi-byte.
        status_field = icon " " pad(lbl, w5)
        # Sub-rows repeat the parent row repo name and had no visual tie
        # back to it, which read as a sort/grouping bug rather than "this
        # belongs to the row above" -- blank the repeated REPO cell and
        # prefix NAME with an indent + ASCII connector so a sub-row is
        # unmistakable at a glance, regardless of what its own status color
        # happens to be. Plain ASCII on purpose, same reasoning as
        # wb_status_icon above: a Unicode tree glyph reintroduces the
        # cell-width alignment bug this file already moved away from.
        #
        # Two independent nesting kinds can indent a row here: an agent
        # pane within one session (kind, field 9), or a live sibling
        # sharing a parent: (field 12, set by wb_parent_subrows). A
        # sibling is an independently live TASK session, not a pane, so
        # reusing the plain kind=="agent" check alone would never catch it
        # -- it needs its own connector, both so the two nesting kinds
        # read as different things and because a sibling can ALSO expand
        # its own agent sub-rows underneath it (U2 stacking scenario).
        # Unlike an agent pane (always the same repo as its parent
        # session), a sibling is explicitly cross-repo (R2), so its repo
        # cell stays visible rather than blanked.
        if ($9 == "agent") {
          repo_cell = pad("", w1); name_cell = pad(" > " $2, w2)
        } else if ($(12) == "1") {
          repo_cell = pad($1, w1); name_cell = pad(" ~ " $2, w2)
        } else {
          repo_cell = pad($1, w1); name_cell = pad($2, w2)
        }
        display = c repo_cell r "  " c name_cell r "  " pad(type, w3) "  " pad($3, w4) "  " c status_field r
        print display, $1, $2, $3, $4, $5, $6, $7, $8, $9, $(10), $(11), $(12)
      }'
}

# wb_column_header — the legend row shown above the picker's rows, in the
# SAME widths wb_format_for_display pads to. Keep the two in sync.
# wb_column_header — the legend line, in the SAME widths wb_format_for_display
# pads data rows to. Printed as a real line (trailing newline) so render_rows
# can prepend it straight into the piped rows as a `--header-lines=1` sticky
# row — that keeps it byte-locked to the data widths and pinned to the top of
# the list regardless of scrolling, unlike a separate --header string (which
# fzf always anchors near the prompt, not above the rows).
wb_column_header() {
  # 4 spaces (not 2) before STATUS: data rows prefix their status text with a
  # 1-char icon + 1 space, so the readable label starts 2 columns later than
  # the column's left edge -- matching that keeps "STATUS" over the text,
  # not over the icon.
  printf '\033[90m%-*s  %-*s  %-*s  %-*s    %s\033[0m\n' \
    "$WB_COL_REPO" "REPO" "$WB_COL_LABEL" "NAME" "$WB_COL_TYPE" "TYPE" \
    "$WB_COL_BRANCH" "BRANCH" "STATUS"
}

# render_rows <mode_file> — dispatch to the mode currently recorded in
# <mode_file> (combined/sessions/agents; defaults to combined), with the
# column-header legend prepended as line 1. Also used by the fzf
# `reload`/`load` bindings (via `wb.sh render <mode_file>`).
render_rows() {
  local mode; mode="$(cat "$1" 2>/dev/null || echo combined)"
  wb_column_header
  case "$mode" in
    agents)   collect_agent_rows | sort -t $'\t' -k4,4n -k1,1 | wb_format_for_display ;;
    sessions) collect_live_rows  | sort -t $'\t' -k4,4n -k1,1 -k2,2 | wb_format_for_display ;;
    *)        collect_combined_rows | wb_format_for_display ;;
  esac
}

# wb_status_line <mode> <context> — 2-line footer: mode + pending counts,
# then keybind hints for whichever context (normal/search) is actually
# active — showing both at once (the original design) meant half the header
# was always irrelevant to what you could currently type. This is fzf's
# --header, which fzf keeps anchored near the prompt (bottom, with the
# default layout) — the column legend lives separately, see wb_column_header.
wb_status_line() {
  local mode="${1:-combined}" ctx="${2:-normal}" hint
  if [ "$ctx" = search ]; then
    hint='SEARCH: type to filter · esc back to normal'
  else
    hint='j/k move · enter jump · x interrupt · r rename · b break-out agent · p pause · ctrl-x done+close/kill · / search · q quit'
  fi
  printf 'wb · %s (tab to cycle) · %s\n%s' \
    "$mode" "$(wb_pending_counts)" "$hint"
}

# _cycle_mode <mode_file> — advance to the next mode, persisting it so the
# next reload (manual or auto-refresh) renders in the new mode instead of
# resetting to combined.
_cycle_mode() {
  local cur; cur="$(cat "$1" 2>/dev/null || echo combined)"
  case "$cur" in
    combined) echo sessions ;;
    sessions) echo agents ;;
    *)        echo combined ;;
  esac > "$1"
}

# _mode_header <mode_file> [context] — print the header for whatever mode is
# currently recorded (plus an optional normal/search context), for fzf's
# transform-header to swap in after a mode cycle or a NORMAL/SEARCH toggle.
_mode_header() { wb_status_line "$(cat "$1" 2>/dev/null || echo combined)" "${2:-normal}"; }

# _interrupt <target> — send Escape to a pane; no-op on an empty target (bound to `x`).
_interrupt() { [ -n "${1:-}" ] && tmux send-keys -t "$1" Escape 2>/dev/null; }

# _rename <session> — prompt for a new tmux session name (bound to `r`).
# Cosmetic only: wb's task linkage lives on the session object via
# @wb_repo/@wb_slug (session-scoped tmux options), which survive a rename,
# so this is safe to do at any point without breaking `wb done` or the picker.
# Errors stay visible: no stderr suppression, and the `read` holds the
# terminal until acknowledged — fzf repaints the instant execute() returns,
# so an unheld message is overdrawn before it can be read.
_rename() {
  local session="$1" new
  [ -n "$session" ] || return 0
  read -r -p "Rename '$session' to: " new
  [ -n "$new" ] || return 0
  new="$(wb_sanitize "$new")"
  if ! tmux rename-session -t "=$session:" "$new"; then
    read -rn1 -p "wb: rename failed — press any key "
    return 1
  fi
}

# _pause <session> — bound to `p`; wraps cmd_pause with the same
# hold-the-terminal-on-failure convention as _rename (fzf repaints the
# instant execute() returns, so an unheld error message is overdrawn
# before it can be read).
_pause() {
  local session="$1"
  [ -n "$session" ] || return 0
  if ! cmd_pause "$session"; then
    read -rn1 -p "wb: pause failed — press any key "
    return 1
  fi
}

# _break_out <target> — move a single pane out of a shared session into a
# brand new one of its own (bound to `b`). On an agent sub-row it takes that
# pane; on a PARENT session row {7} is the session's most-urgent agent pane,
# so it breaks that agent out. No-op on an empty target (no-agent rows).
# tmux's break-pane can't create its destination session itself, so this
# creates a one-window scratch session first, breaks the pane into it, then
# kills the scratch window. Identity, never index: new-session -P returns
# the name tmux ACTUALLY created (it silently rewrites "."/":" to "_") plus
# the scratch window's @id — a base-index-0 config puts the scratch at :0
# and the rescued pane at :1, so `kill-window -t $new:1` would destroy the
# pane we just rescued. Window ids are immune to base-index and renumbering.
_break_out() {
  local target="$1" new created new_name scratch_win
  [ -n "$target" ] || return 0
  read -r -p "Break '$target' into new session: " new
  [ -n "$new" ] || return 0
  new="$(wb_sanitize "$new")"
  if tmux has-session -t "=$new" 2>/dev/null; then
    read -rn1 -p "wb: session '$new' already exists — press any key "
    return 1
  fi
  if ! created="$(tmux new-session -d -P -F '#{session_name}|#{window_id}' -s "$new")"; then
    read -rn1 -p "wb: could not create session '$new' — press any key "
    return 1
  fi
  new_name="${created%%|*}"
  scratch_win="${created##*|}"
  if tmux break-pane -d -s "$target" -t "=$new_name:"; then
    tmux kill-window -t "$scratch_win"
  else
    tmux kill-session -t "=$new_name" 2>/dev/null
    read -rn1 -p "wb: could not break '$target' into '$new_name' — press any key "
    return 1
  fi
}

# _ctrl_x <kind> <session> <target> — the picker's ctrl-x dispatch: task rows
# route through the full wb done wind-down plus --close (mark done AND close
# the session — the one caller where that combination is always what's
# wanted); repo sessions get a raw kill; a single agent sub-row kills just
# that pane. No-ops on an empty session/target.
#
# Self-target guard (task rows only): the picker is commonly launched via
# `new-window` with no `-t` (tmux.conf's `bind m`/`bind a`), so it opens
# inside whatever session the user is already in, and that session shows up
# as a selectable row like any other. Blindly closing it from ctrl-x would
# kill the very pane running this command (and any other live window in
# that session) with no confirmation and no way to abort mid-keypress — the
# 2026-07-08 "sessions don't disappear" guarantee this feature is built on
# top of, silently undone for the one row users are statistically most
# likely to pick. Still complete the wind-down (worktree removed, task
# marked done) either way; only the close is skipped. This guard is
# deliberately scoped to ctrl-x's dispatch, not cmd_done itself — typing
# `wb done --close` yourself from inside your own session stays intentional
# self-close and is untouched.
_ctrl_x() {
  local kind="$1" session="$2" target="$3"
  case "$kind" in
    task)
      if [ -n "$session" ]; then
        if [ -n "${TMUX:-}" ] && [ "$session" = "$(tmux display-message -p '#S' 2>/dev/null)" ]; then
          cmd_done "$session"
          echo "wb: not closing '$session' via ctrl-x — it's your current session; run 'wb done --close' yourself once you're ready to leave it" >&2
        else
          cmd_done "$session" --close
        fi
      fi
      ;;
    repo)  [ -n "$session" ] && tmux kill-session -t "=$session" 2>/dev/null ;;
    agent) [ -n "$target" ]  && tmux kill-pane -t "$target" 2>/dev/null ;;
  esac
}

picker() {
  # Not `local`: an EXIT trap fires when the whole script exits, which for
  # the success path (no explicit `exit` below) happens AFTER picker()
  # already returned and popped its locals — referencing a local mode_file
  # from the trap at that point is an unbound-variable crash under set -u.
  # A plain (script-global) variable stays in scope for the trap either way.
  mode_file="$(mktemp -t wb-mode.XXXXXX)"
  echo combined > "$mode_file"
  trap 'rm -f "$mode_file"' EXIT

  local rendered selection
  rendered="$(render_rows "$mode_file")"
  if [ -z "$rendered" ]; then
    echo "wb: no live sessions found." >&2
    exit 0
  fi

  # Modal navigation mirrors claude-sessions.sh: NORMAL disables search so
  # unbound keys are inert; i or / enters SEARCH.
  local navkeys='j,k,g,G,q,i,x,r,b,p,/'

  # Field 1 is the pre-rendered display string (see wb_format_for_display);
  # fields 2-12 are the real data, shown to fzf only as hidden/addressable
  # fields via --with-nth=1 so binds/preview can still reach them by index.
  # --layout=reverse-list: prompt/--header stay at the bottom (fzf's default
  # position) but the match list renders top-down instead of bottom-up, so
  # the --header-lines column legend — which sits logically "above" the
  # first match — actually lands at the top of the screen. Plain default
  # layout keeps header-lines pinned next to the prompt instead (i.e. still
  # near the bottom), which is what "the header is at the bottom again" was.
  selection="$(printf '%s\n' "$rendered" | fzf --ansi --query="${1:-}" --select-1 --track \
        --delimiter=$'\t' --with-nth=1 --header-lines=1 \
        --layout=reverse-list --pointer='>' \
        --height=100% --padding=6,1,2,1 \
        --prompt='NORMAL ' \
        --header="$(wb_status_line combined)" \
        --no-sort \
        --preview '[ -n {7} ] && tmux capture-pane -ep -t {7} || ([ -f {9} ] && cat {9} || git -C {9} -c color.status=always status -s)' \
        --preview-window 'right,55%,wrap,border-left' \
        --preview-label ' wb ' \
        --bind 'start:disable-search' \
        --bind "load:reload-sync(sleep 3; \"$SELF\" render \"$mode_file\")+refresh-preview" \
        --bind 'j:down' --bind 'k:up' --bind 'g:first' --bind 'G:last' \
        --bind 'ctrl-d:half-page-down' --bind 'ctrl-u:half-page-up' \
        --bind 'l:accept' --bind 'h:abort' --bind 'q:abort' \
        --bind "ctrl-r:reload-sync(\"$SELF\" render \"$mode_file\")+refresh-preview" \
        --bind "tab:execute-silent(\"$SELF\" _cycle-mode \"$mode_file\")+reload-sync(\"$SELF\" render \"$mode_file\")+transform-header(\"$SELF\" _mode-header \"$mode_file\")" \
        --bind "x:execute-silent(\"$SELF\" _interrupt {7})" \
        --bind "r:execute(\"$SELF\" _rename {8})+reload-sync(\"$SELF\" render \"$mode_file\")+refresh-preview" \
        --bind "b:execute(\"$SELF\" _break-out {7})+reload-sync(\"$SELF\" render \"$mode_file\")+refresh-preview" \
        --bind "p:execute(\"$SELF\" _pause {8})+reload-sync(\"$SELF\" render \"$mode_file\")+refresh-preview" \
        --bind "ctrl-x:become(\"$SELF\" _ctrl-x {10} {8} {7})" \
        --bind "i:unbind($navkeys)+enable-search+change-prompt(SEARCH )+transform-header(\"$SELF\" _mode-header \"$mode_file\" search)" \
        --bind "/:clear-query+unbind($navkeys)+enable-search+change-prompt(SEARCH )+transform-header(\"$SELF\" _mode-header \"$mode_file\" search)" \
        --bind "esc:enable-search+clear-query+disable-search+rebind($navkeys)+change-prompt(NORMAL )+transform-header(\"$SELF\" _mode-header \"$mode_file\")")" || exit 0

  [ -n "$selection" ] || exit 0
  local -a f; wb_tsv_split "$selection" f
  local repo="${f[1]}" target="${f[6]}" session="${f[7]}" ref="${f[8]}" kind="${f[9]}" slug="${f[11]}"

  if [ -n "$target" ]; then
    tmux_goto_pane "$target"
  elif [ -n "$session" ]; then
    tmux_focus "$session"
  elif [ "$kind" = "repo" ]; then
    tmux_attach_or_create "$repo" "$ref"
  elif [ "$kind" = "task" ]; then
    cmd_new "$repo" "$slug"
  fi
}

# Guarded so tests can `source` this file to reach individual functions
# (e.g. to stub cmd_new and unit-test cmd_resume's match logic) without
# triggering the CLI dispatch below — real invocation (`bash wb.sh ...` /
# `./wb.sh ...`) always has BASH_SOURCE[0] == $0, so behavior is unchanged.
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  case "${1:-}" in
    new)         shift; cmd_new "$@" ;;
    resume)      shift; cmd_resume "$@" ;;
    reconcile)   shift; cmd_reconcile "$@" ;;
    board)       shift; cmd_board "$@" ;;
    done)        shift; cmd_done "$@" ;;
    pause)       shift; cmd_pause "$@" ;;
    _pause)      shift; _pause "$@" ;;
    render)      shift; render_rows "$@" ;;
    _interrupt)  shift; _interrupt "$@" ;;
    _rename)     shift; _rename "$@" ;;
    _break-out)  shift; _break_out "$@" ;;
    _ctrl-x)     shift; _ctrl_x "$@" ;;
    _cycle-mode) shift; _cycle_mode "$@" ;;
    _mode-header) shift; _mode_header "$@" ;;
    *)           picker "${1:-}" ;;
  esac
fi
