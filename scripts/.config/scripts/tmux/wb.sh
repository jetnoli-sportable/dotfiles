#!/usr/bin/env bash
# wb (workbench) — session-per-worktree + the unified picker.
#   wb new [--agent] <slug>          from inside a repo
#   wb new [--agent] <repo> <slug>   from anywhere
#   wb                               the picker (replaces s + ca)
#   wb done [<session>]              safe wind-down (defaults to the current session)
#
# Design + build order: dotfiles/logs/2026-07-06-way-forward.md §2/§3,
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
CODE_DIR="$HOME/code"
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

# wb_set_frontmatter <file> <key> <value> — overwrite a frontmatter value in place.
wb_set_frontmatter() {
  local file="$1" key="$2" value="$3"
  awk -v key="$key" -v val="$value" '
    BEGIN { infm = 0; done = 0 }
    /^---$/ { infm++; print; next }
    infm == 1 && !done && $0 ~ "^" key ":" { print key ": " val; done = 1; next }
    { print }
  ' "$file" > "$file.tmp.$$" && mv "$file.tmp.$$" "$file"
}

# wb_read_task <file> — print "status\trepo\tworktree" in one pass (used by
# the picker's row collection, which reads every task file on each refresh).
wb_read_task() {
  awk '
    BEGIN { infm = 0; status = ""; repo = ""; worktree = ""; branch = "" }
    /^---$/ { infm++; if (infm == 2) exit; next }
    infm == 1 && /^status:/   { s = $0; sub(/^status:[ \t]*/,   "", s); status = s }
    infm == 1 && /^repo:/     { s = $0; sub(/^repo:[ \t]*/,     "", s); repo = s }
    infm == 1 && /^worktree:/ { s = $0; sub(/^worktree:[ \t]*/, "", s); worktree = s }
    infm == 1 && /^branch:/   { s = $0; sub(/^branch:[ \t]*/,   "", s); branch = s }
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
# ("/" and "." become "-"; never parse this back, see header comment).
wb_sanitize() { local s="${1//\//-}"; echo "${s//./-}"; }

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

# wb_seed_task <repo> <slug> <worktree_rel> — find-or-create the task file for
# a repo+slug pair, filling blank frontmatter fields and bumping
# planned->doing. Never overwrites a field that's already set.
wb_seed_task() {
  local repo="$1" slug="$2" worktree_rel="$3"
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
  tmux send-keys -t "=$session:1" "nvim ." Enter
  tmux new-window -t "=$session" -n agent -c "$dir"
  [ "$start_agent" = 1 ] && tmux send-keys -t "=$session:agent" "claude" Enter
  tmux new-window -t "=$session" -n shell -c "$dir"
  tmux select-window -t "=$session:1"
}

cmd_new() {
  local agent_flag=0
  local -a args=()
  local a
  for a in "$@"; do
    if [ "$a" = "--agent" ]; then agent_flag=1; else args+=("$a"); fi
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
    echo "usage: wb new [--agent] <slug> | wb new [--agent] <repo> <slug>" >&2
    exit 1
  fi

  [ -n "$slug" ] || { echo "wb new: <slug> must not be empty" >&2; exit 1; }

  local repo_dir="$CODE_DIR/$repo"
  [ -d "$repo_dir/.git" ] || { echo "wb new: $repo_dir is not a git repo" >&2; exit 1; }

  local disp_slug; disp_slug="$(wb_sanitize "$slug")"
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
  task_file="$(wb_seed_task "$repo" "$slug" "$worktree_rel")"

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

cmd_done() {
  local session="${1:-}"
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
      [ -e "$worktree_path/$safe" ] || continue
      safe_kept+=("$safe")
    done < <(wb_sweep_section "$task_file" | grep -oP '^- \[x\] keep \K.*' || true)

    for f in "${safe_kept[@]}"; do
      mkdir -p "$dossier/$(dirname "$f")"
      cp -a "$worktree_path/$f" "$dossier/$f"
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

  # 3. remove the worktree BEFORE flipping status or killing the session:
  #    - wb done typically runs from inside the session it's tearing down,
  #      so kill-session first would kill this very script mid-flight and
  #      the removal below would never run.
  #    - flipping status to "done" before a possibly-failing removal would
  #      leave the store claiming done while the worktree/session still
  #      exist; removing first means status only ever reflects a real
  #      teardown.
  #    - the existence guard makes a retry safe after a prior run was
  #      killed between removal and status-set: `git worktree remove` on an
  #      already-gone path hard-fails under set -e otherwise.
  #    Branch is kept — see logs/decisions/2026-07-06-review-outstanding.md Q2.
  if [ -d "$worktree_path" ]; then
    git -C "$repo_dir" worktree remove "$worktree_path" --force
  fi
  wb_set_frontmatter "$task_file" status done
  tmux kill-session -t "=$session" 2>/dev/null || true

  echo "wb done: $session closed — worktree removed, task -> done ($task_file)"

  local total=$(( $(wb_followup_count) + $(wb_parked_count) ))
  if [ "$total" -ge "$WB_SWEEP_THRESHOLD" ]; then
    echo "wb done: $(wb_pending_counts) — consider running /parked-items"
  fi
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
# wb_format_for_display (used by render_rows) prepends a pre-rendered,
# fixed-width display string as a NEW field 1, shifting all of the above by
# one (repo becomes field 2, ..., slug becomes field 12) — that's the shape
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
    *)           printf '-\tidle\n' ;;
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
    printf '%s\t%s\t%s\t%s\t%s %s\t%s\t%s\t%s\tagent\t1\t\n' \
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

  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
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

# collect_combined_rows — collect_live_rows, expanding multi-agent sessions
# into indented sub-rows (see wb_agent_subrows).
collect_combined_rows() {
  local line repo branch session ref ucount
  local -a f
  while IFS= read -r line; do
    printf '%s\n' "$line"
    wb_tsv_split "$line" f
    repo="${f[0]}"; branch="${f[2]}"; session="${f[6]}"; ref="${f[7]}"; ucount="${f[9]}"
    [ "${ucount:-0}" -gt 1 ] 2>/dev/null && wb_agent_subrows "$repo" "$session" "$ref" "$branch"; true
  done < <(collect_live_rows)
}

# collect_agent_rows — one row per running claude pane, globally, ranked by
# urgency with no session grouping. Replaces `ca`.
collect_agent_rows() {
  local rank target status task icon label sess
  while IFS=$'\t' read -r rank target status task; do
    IFS=$'\t' read -r icon label < <(wb_status_icon "$status")
    sess="${target%%:*}"
    printf '%s\t%s\t\t%s\t%s %s\t%s\t%s\t%s\tagent\t1\t\n' \
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
        display = c pad($1, w1) r "  " c pad($2, w2) r "  " pad(type, w3) "  " pad($3, w4) "  " c status_field r
        print display, $1, $2, $3, $4, $5, $6, $7, $8, $9, $(10), $(11)
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
    sessions) collect_live_rows  | sort -t $'\t' -k1,1 -k4,4n -k2,2 | wb_format_for_display ;;
    *)        collect_combined_rows | sort -t $'\t' -k1,1 -k4,4n -k2,2 | wb_format_for_display ;;
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
    hint='j/k move · enter jump · x interrupt · r rename · b new session · ctrl-x done/kill · / search · q quit'
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
_rename() {
  local session="$1" new
  [ -n "$session" ] || return 0
  read -r -p "Rename '$session' to: " new
  [ -n "$new" ] || return 0
  tmux rename-session -t "=$session:" "$new" 2>/dev/null
}

# _break_out <target> — move a single pane out of a shared session into a
# brand new one of its own (bound to `b`). Only makes sense on an
# agent/sub-row, hence taking the pane target ({7}), not the session — no-op
# on an empty target, same convention as _interrupt.
# tmux's break-pane can't create its destination session itself (errors
# "can't find session"), so this creates a one-window scratch session first,
# breaks the pane into it (landing as a second window), then kills the
# scratch window — leaving the extracted pane as the new session's only one.
_break_out() {
  local target="$1" new
  [ -n "$target" ] || return 0
  read -r -p "Break '$target' into new session: " new
  [ -n "$new" ] || return 0
  if tmux has-session -t "=$new" 2>/dev/null; then
    echo "wb: session '$new' already exists" >&2
    return 1
  fi
  tmux new-session -d -s "$new"
  if tmux break-pane -d -s "$target" -t "$new:" 2>/dev/null; then
    tmux kill-window -t "$new:1" 2>/dev/null
  else
    tmux kill-session -t "$new" 2>/dev/null
    echo "wb: could not break '$target' into '$new'" >&2
    return 1
  fi
}

# _ctrl_x <kind> <session> <target> — the picker's ctrl-x dispatch: task rows
# route through the full wb done wind-down; repo sessions get a raw kill;
# a single agent sub-row kills just that pane. No-ops on an empty session/target.
_ctrl_x() {
  local kind="$1" session="$2" target="$3"
  case "$kind" in
    task)  [ -n "$session" ] && cmd_done "$session" ;;
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
  local navkeys='j,k,g,G,q,i,x,r,b,/'

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
        --bind "load:reload-sync(sleep 3; \"$SELF\" render $mode_file)+refresh-preview" \
        --bind 'j:down' --bind 'k:up' --bind 'g:first' --bind 'G:last' \
        --bind 'ctrl-d:half-page-down' --bind 'ctrl-u:half-page-up' \
        --bind 'l:accept' --bind 'h:abort' --bind 'q:abort' \
        --bind "ctrl-r:reload-sync(\"$SELF\" render $mode_file)+refresh-preview" \
        --bind "tab:execute-silent($SELF _cycle-mode $mode_file)+reload-sync(\"$SELF\" render $mode_file)+transform-header($SELF _mode-header $mode_file)" \
        --bind "x:execute-silent($SELF _interrupt {7})" \
        --bind "r:execute($SELF _rename {8})+reload-sync(\"$SELF\" render $mode_file)+refresh-preview" \
        --bind "b:execute($SELF _break-out {7})+reload-sync(\"$SELF\" render $mode_file)+refresh-preview" \
        --bind "ctrl-x:become($SELF _ctrl-x {10} {8} {7})" \
        --bind "i:unbind($navkeys)+enable-search+change-prompt(SEARCH )+transform-header($SELF _mode-header $mode_file search)" \
        --bind "/:clear-query+unbind($navkeys)+enable-search+change-prompt(SEARCH )+transform-header($SELF _mode-header $mode_file search)" \
        --bind "esc:rebind($navkeys)+disable-search+change-prompt(NORMAL )+transform-header($SELF _mode-header $mode_file)")" || exit 0

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

case "${1:-}" in
  new)         shift; cmd_new "$@" ;;
  done)        shift; cmd_done "$@" ;;
  render)      shift; render_rows "$@" ;;
  _interrupt)  shift; _interrupt "$@" ;;
  _rename)     shift; _rename "$@" ;;
  _break-out)  shift; _break_out "$@" ;;
  _ctrl-x)     shift; _ctrl_x "$@" ;;
  _cycle-mode) shift; _cycle_mode "$@" ;;
  _mode-header) shift; _mode_header "$@" ;;
  *)           picker "${1:-}" ;;
esac
