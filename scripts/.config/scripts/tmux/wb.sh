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
    BEGIN { infm = 0; status = ""; repo = ""; worktree = "" }
    /^---$/ { infm++; if (infm == 2) exit; next }
    infm == 1 && /^status:/   { s = $0; sub(/^status:[ \t]*/,   "", s); status = s }
    infm == 1 && /^repo:/     { s = $0; sub(/^repo:[ \t]*/,     "", s); repo = s }
    infm == 1 && /^worktree:/ { s = $0; sub(/^worktree:[ \t]*/, "", s); worktree = s }
    END { printf "%s\t%s\t%s\n", status, repo, worktree }
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

# wb_task_fallback_slug <file> <repo> — recover the slug for a task that has
# never had a worktree, by stripping the KNOWN `<repo>--` prefix off its own
# filename. Safe (unlike parsing a tmux session name) because repo is already
# known from frontmatter, not guessed from the split itself.
wb_task_fallback_slug() {
  local base; base="$(basename "$1" .md)"
  case "$base" in
    "$2"--*) echo "${base#"$2"--}" ;;
    *)
      # bash's # prefix-strip is a silent no-op when the pattern doesn't
      # match — surface the drift instead of quietly using the whole
      # basename (repo prefix included) as the slug.
      echo "wb: $1 doesn't match the <repo>--<slug>.md convention for repo '$2'" >&2
      echo "$base"
      ;;
  esac
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
# Row schema (tab-separated), shared by task/repo/agent rows:
#   1 repo   2 label   3 status_or_branch   4 urank   5 icon_label
#   6 target (hidden pane target, may be empty)
#   7 session (empty => creatable/no live session)
#   8 ref (task file path, or repo dir for repo rows)
#   9 kind (task|repo|agent)   10 ucount (claude panes in session)
#   11 slug (task rows only — real, slash-preserving; used to spin up wb new)

# wb_status_icon <status> — print "icon\tlabel" for one of the pane statuses
# tmux_claude_panes emits (needs-input/done/waiting/working/idle). Shared by
# wb_session_urgency and wb_agent_subrows so this mapping lives in one place.
wb_status_icon() {
  case "$1" in
    needs-input) printf '\xe2\x97\x86\tneeds you\n' ;;   # ◆
    done)        printf '\xe2\x9c\x94\tfinished\n' ;;    # ✔
    waiting)     printf '\xe2\x97\x8b\tdone\n' ;;         # ○
    working)     printf '\xe2\x97\x8f\tworking\n' ;;      # ●
    *)           printf '\xc2\xb7\tidle\n' ;;             # ·
  esac
}

# wb_session_urgency <session> — "<rank>\t<icon_label>\t<target>\t<count>" for
# the most-urgent claude pane in <session>, or the "no agent" default.
wb_session_urgency() {
  local rows count rank target status task
  rows="$(tmux_claude_panes "$1" | sort -n)"
  if [ -z "$rows" ]; then
    printf '3\t\xc2\xb7 no agent\t\t0\n'
    return
  fi
  count="$(printf '%s\n' "$rows" | grep -c . || true)"
  IFS=$'\t' read -r rank target status task <<< "$(head -n1 <<< "$rows")"
  local icon label
  IFS=$'\t' read -r icon label < <(wb_status_icon "$status")
  printf '%s\t%s %s\t%s\t%s\n' "$rank" "$icon" "$label" "$target" "$count"
}

# wb_agent_subrows <repo> <session> <ref> — one indented sub-row per claude
# pane in a multi-agent session (kept out of the collapsed parent row).
wb_agent_subrows() {
  local repo="$1" session="$2" ref="$3"
  local rank target status task icon label
  while IFS=$'\t' read -r rank target status task; do
    IFS=$'\t' read -r icon label < <(wb_status_icon "$status")
    printf '%s\t  %s\t\t%s\t%s %s\t%s\t%s\t%s\tagent\t1\t\n' \
      "$repo" "$task" "$rank" "$icon" "$label" "$target" "$session" "$ref"
  done < <(tmux_claude_panes "$session" | sort -n)
}

collect_task_rows() {
  local file status repo worktree title
  while IFS= read -r file; do
    # The picker re-execs this every ~3s; a task file can vanish between
    # wb_task_files' listing and here (e.g. a concurrent `wb done`). A file
    # that's gone by now would otherwise crash this bare `$(...)` under
    # set -e and take collect_repo_rows down with it — skip just this row.
    [ -f "$file" ] || continue
    IFS=$'\t' read -r status repo worktree < <(wb_read_task "$file")
    [ -n "$repo" ] || continue
    title="$(wb_task_title "$file")"; [ -n "$title" ] || title="$(basename "$file" .md)"

    local slug="" disp_slug="" session=""
    if [ -n "$worktree" ]; then
      slug="${worktree#.worktrees/}"
    else
      slug="$(wb_task_fallback_slug "$file" "$repo")"
    fi
    disp_slug="$(wb_sanitize "$slug")"
    local candidate="${repo}--${disp_slug}"
    tmux has-session -t "=$candidate" 2>/dev/null && session="$candidate"

    local urank=3 uicon="· no agent" target="" ucount=0
    [ -n "$session" ] && IFS=$'\t' read -r urank uicon target ucount < <(wb_session_urgency "$session")

    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\ttask\t%s\t%s\n' \
      "$repo" "$title" "$status" "$urank" "$uicon" "$target" "$session" "$file" "$ucount" "$slug"

    [ "${ucount:-0}" -gt 1 ] 2>/dev/null && wb_agent_subrows "$repo" "$session" "$file"; true
  done < <(wb_task_files)
}

collect_repo_rows() {
  local dir repo branch session urank uicon target ucount
  while IFS= read -r dir; do
    [ -n "$dir" ] || continue
    dir="${dir%/}"
    repo="$(basename "$dir")"
    branch="$(git -C "$dir" branch --show-current 2>/dev/null || true)"
    session=""
    tmux has-session -t "=$repo" 2>/dev/null && session="$repo"

    urank=3; uicon="· no agent"; target=""; ucount=0
    [ -n "$session" ] && IFS=$'\t' read -r urank uicon target ucount < <(wb_session_urgency "$session")

    printf '%s\t%s\t[%s]\t%s\t%s\t%s\t%s\t%s\trepo\t%s\t\n' \
      "$repo" "$repo" "$branch" "$urank" "$uicon" "$target" "$session" "$dir" "$ucount"

    [ "${ucount:-0}" -gt 1 ] 2>/dev/null && wb_agent_subrows "$repo" "$session" "$dir"; true
  done < <(tmux_code_repos)
}

# render_rows — merge task + repo (+ agent sub-) rows, color by urgency label,
# group by repo with the most-urgent row of each group pinned to the top.
# Also used by the fzf `reload` binding (via `wb.sh render`).
render_rows() {
  # Sort on the plain fields FIRST, then colorize — coloring before sorting
  # would splice a urgency-dependent ANSI prefix onto field 1 (repo), so the
  # sort key becomes "color code + repo name" instead of "repo name" and the
  # documented group-by-repo invariant breaks for any row that isn't idle-gray.
  { collect_task_rows; collect_repo_rows; } \
    | sort -t $'\t' -k1,1 -k4,4n -k2,2 \
    | awk -F'\t' -v OFS='\t' '
        BEGIN { m = "\033[1;35m"; g = "\033[32m"; y = "\033[33m"; d = "\033[90m"; cy = "\033[36m"; r = "\033[0m" }
        {
          lbl = $5; sub(/^[^ ]+ /, "", lbl)
          if      (lbl == "needs you") c = m
          else if (lbl == "finished")  c = cy
          else if (lbl == "done")      c = g
          else if (lbl == "working")   c = y
          else                         c = d
          $1 = c $1 r
          $2 = c $2 r
          $5 = c $5 r
          print
        }'
}

# wb_status_line — header text for the picker: pending counts, keybind hints.
wb_status_line() {
  printf 'wb · %s\nNORMAL: j/k move · g/G top/bottom · l/enter jump-or-create · x interrupt · ctrl-x done/kill · ctrl-r refresh · i,/ search · q quit\nSEARCH: type to filter · esc back to normal' \
    "$(wb_pending_counts)"
}

# _interrupt <target> — send Escape to a pane; no-op on an empty target (bound to `x`).
_interrupt() { [ -n "${1:-}" ] && tmux send-keys -t "$1" Escape 2>/dev/null; }

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
  local rendered selection
  rendered="$(render_rows)"
  if [ -z "$rendered" ]; then
    echo "wb: no tasks or repos found." >&2
    exit 0
  fi

  # Modal navigation mirrors claude-sessions.sh: NORMAL disables search so
  # unbound keys are inert; i or / enters SEARCH.
  local navkeys='j,k,g,G,q,i,x,/'

  selection="$(printf '%s\n' "$rendered" | fzf --ansi --query="${1:-}" --select-1 --track \
        --delimiter=$'\t' --with-nth=1,2,3,5 \
        --prompt='NORMAL ' \
        --header="$(wb_status_line)" \
        --no-sort \
        --preview '[ -n {6} ] && tmux capture-pane -ep -t {6} || ([ -f {8} ] && cat {8} || git -C {8} -c color.status=always status -s)' \
        --preview-window 'right,55%,wrap,border-left' \
        --preview-label ' wb ' \
        --bind 'start:disable-search' \
        --bind "load:reload-sync(sleep 3; \"$SELF\" render)+refresh-preview" \
        --bind 'j:down' --bind 'k:up' --bind 'g:first' --bind 'G:last' \
        --bind 'ctrl-d:half-page-down' --bind 'ctrl-u:half-page-up' \
        --bind 'l:accept' --bind 'h:abort' --bind 'q:abort' \
        --bind "ctrl-r:reload-sync(\"$SELF\" render)+refresh-preview" \
        --bind "x:execute-silent($SELF _interrupt {6})" \
        --bind "ctrl-x:become($SELF _ctrl-x {9} {7} {6})" \
        --bind "i:unbind($navkeys)+enable-search+change-prompt(SEARCH )" \
        --bind "/:clear-query+unbind($navkeys)+enable-search+change-prompt(SEARCH )" \
        --bind "esc:rebind($navkeys)+disable-search+change-prompt(NORMAL )")" || exit 0

  [ -n "$selection" ] || exit 0
  local repo label statuscol urank uicon target session ref kind ucount slug
  IFS=$'\t' read -r repo label statuscol urank uicon target session ref kind ucount slug <<< "$selection"

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
  new)        shift; cmd_new "$@" ;;
  done)       shift; cmd_done "$@" ;;
  render)     render_rows ;;
  _interrupt) shift; _interrupt "$@" ;;
  _ctrl-x)    shift; _ctrl_x "$@" ;;
  *)          picker "${1:-}" ;;
esac
