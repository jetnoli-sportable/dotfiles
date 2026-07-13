#!/usr/bin/env bash
# wb (workbench) — session-per-worktree + the unified picker.
#   wb new [--agent] <slug>          from inside a repo
#   wb new [--agent] <repo> <slug>   from anywhere
#   wb new --planned <repo> <slug>   seed a worktree-less task file only (status stays
#                                    planned) — no worktree, no tmux session; the
#                                    locked creation path agent-mediated skills use
#   wb                               the picker (replaces s + ca)
#   wb board                         task-store status table (interim /board)
#   wb done [--close] [<session>]    safe wind-down (defaults to the current session); --close also kills the tmux session
#   wb resume <task>                 recreate a closed/gone worktree+session from its task file
#   wb pause [<session>]             mark a task paused — worktree and session both survive
#   wb reviewed [<session>]          stamp a task's reviewed: field (marks /ce-code-review done)
#   wb reconcile                     report task-store/git worktree drift (detection only, read-only)
#   wb sync                          fetch + fast-forward-only merge for $TASKS_DIR (refuses on dirty tree, divergence, or the wrong branch)
#   wb unsafe-rewind "<reason>"      write a time-limited escape-hatch sentinel a git hook honors for a deliberate rewind
#   wb append <task> <heading> [<body>|-]
#                                    append <body> under "## <heading>" in <task>'s file,
#                                    taking the per-task lock (fail-loud on an ambiguous
#                                    or unmatched <task>); <body> omitted or literally
#                                    "-" reads a multi-line body from stdin instead — the
#                                    agent-mediated write path /wb-save, /handoff, and
#                                    /parked-items use instead of Edit-tool task writes
#   wb install-hooks                 idempotently point $TASKS_DIR's core.hooksPath at the
#                                    stowed tasks-git-hooks/ dir, harden its gc/reflog
#                                    settings, and verify (never edit) ~/.claude/settings.json's
#                                    PreToolUse entry — printing the paste-block + a
#                                    restart-running-sessions reminder when it's missing
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
# shellcheck source=wb-lifecycle.sh
source "$SCRIPT_DIR/wb-lifecycle.sh"
# shellcheck source=wb-locks.sh
source "$SCRIPT_DIR/wb-locks.sh"

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

# wb_session_task_file <session> — KTD7's @task-first task-file resolution.
# Every session cmd_new creates already carries a session-scoped `@task`
# option (set alongside @wb_repo/@wb_slug) — but until wb-breakdown, @task
# and the @wb_repo/@wb_slug-derived file always named the SAME task, so
# nobody needed to pick one over the other. Migration (U3) is the first
# case where they diverge on purpose: a continuing child session keeps its
# ORIGINAL @wb_repo/@wb_slug (its own git identity — see the System-Wide
# Impact note on why that's fine), while @task gets re-pointed at the
# child's file. Every verb that resolves "my task file" from a session must
# prefer @task once that's possible, or `wb done`/`wb pause`/`wb reviewed`
# on a migrated session would silently act on the PARENT (R12's "writes
# nothing beyond its own task" specifically depends on this).
#
# Prints the resolved path and returns 0, or returns 1 with NOTHING on
# stdout when neither @task nor @wb_repo/@wb_slug resolve — callers keep
# printing their OWN existing "not a wb task session" wording so a session
# without @task (every session that predates this feature, and any
# non-cmd_new session) stays byte-for-byte unchanged (characterized in
# wb-breakdown.test.sh's coherence section before this landed).
wb_session_task_file() {
  local session="$1" task_ref
  task_ref="$(tmux show -t "=$session:" -v @task 2>/dev/null || true)"
  if [ -n "$task_ref" ]; then
    if [ -f "$task_ref" ]; then
      printf '%s\n' "$task_ref"
      return 0
    fi
    echo "wb: @task ($task_ref) no longer exists for $session — falling back to repo/slug derivation" >&2
  fi
  local repo slug
  repo="$(tmux show -t "=$session:" -v @wb_repo 2>/dev/null || true)"
  slug="$(tmux show -t "=$session:" -v @wb_slug 2>/dev/null || true)"
  [ -n "$repo" ] && [ -n "$slug" ] || return 1
  wb_task_file "$repo" "$(wb_sanitize "$slug")"
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
# Lock integration (U3) — the L2-L5 caller-side orphan-check-and-retry layer
# built on top of wb-locks.sh's (U1) generic, liveness-agnostic primitives
# and lib.sh's (U2) tmux_session_agent_state. Lives here, not in
# wb-locks.sh: the orphan decision needs wb/claude process-shape and tmux
# session-liveness knowledge, both wb-specific — wb-locks.sh itself stays a
# generic lock module with zero tmux/claude awareness. Every cmd_*/
# wb_reconcile_action_* call site below uses wb_task_lock_acquire_guarded
# instead of calling wb_task_lock_acquire directly, so the four-condition
# check lives in exactly one place instead of being duplicated at every one
# of this file's locking call sites.
# ---------------------------------------------------------------------------

# _wb_lock_cmdline_wb_shaped <pid> — true when /proc/<pid>/cmdline looks like
# a wb.sh/handoff.sh/claude process, not an unrelated process that happens to
# have been assigned this pid after the real holder exited (PID-reuse guard,
# L2's process-identity condition). /proc/<pid>/cmdline is NUL-separated;
# `tr` folds that into plain spaces for a simple substring match.
_wb_lock_cmdline_wb_shaped() {
  local pid="$1" cmdline
  [ -r "/proc/$pid/cmdline" ] || return 1
  cmdline="$(tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null)"
  [ -n "$cmdline" ] || return 1
  case "$cmdline" in
    *wb.sh*|*handoff.sh*|*claude*) return 0 ;;
    *) return 1 ;;
  esac
}

# _wb_lock_holder_is_orphan <task_file> <pid> — L2's four-condition orphan
# predicate. Only ever evaluated AFTER wb_task_lock_acquire has already lost
# a contended acquire, and only for a holder pid the caller has already
# confirmed is still alive (kill -0 succeeded there — a gone pid means the
# kernel already dropped the flock on process death, the cheaper case
# handled directly by the caller, never reaching here). <pid> is passed in
# by the caller (wb_task_lock_acquire_guarded), which already read it off
# the lock file to make that liveness check — reading it a second time here
# would be the same field read twice on every contended acquire, the exact
# path this whole guard exists to handle quickly. Orphan (safe to clear and
# retry once) only when ALL FOUR hold simultaneously:
#   1. the recorded holder pid is alive (the caller's own precondition for
#      calling this at all — see above).
#   2. `/proc/<pid>/cmdline` looks wb/claude-shaped (PID-reuse guard).
#   3. the recorded acquire timestamp is >60s old — a generous multiple of
#      any legitimate wb chain, so a session mid-spawn is never mistaken for
#      dead (incident 1's exact danger zone).
#   4. the holder's OWN recorded tmux_session (never the TARGET task's own
#      session, which legitimately doesn't exist yet during a handoff spawn
#      — signaling the healthy winner there is incident 1's guard-as-weapon
#      scenario) comes back `dead` from tmux_session_agent_state (U2) — no
#      such session exists at all for the holder anymore.
# An empty recorded tmux_session field, or a `tmux_session_agent_state`
# result of `alive`/`unknown`, both fail this check outright (conditions 3/4
# folded together below) — L3/L5: anything less than a confirmed-dead
# holder session never auto-clears. Reads holder-info fields via
# wb-locks.sh's public wb_task_lock_holder_field, never its internal
# _wb_lock_path_for/_wb_lock_field accessors directly.
_wb_lock_holder_is_orphan() {
  local task_file="$1" pid="$2" ts tmux_session state now held_epoch elapsed

  tmux_session="$(wb_task_lock_holder_field "$task_file" tmux_session)"
  [ -n "$tmux_session" ] || return 1   # empty -> unknown, never killable

  state="$(tmux_session_agent_state "$tmux_session")"
  [ "$state" = dead ] || return 1      # alive/unknown -> halt, no clearing (L3/L5)

  _wb_lock_cmdline_wb_shaped "$pid" || return 1

  ts="$(wb_task_lock_holder_field "$task_file" acquired)"
  now="$(date +%s)"
  held_epoch="$(date -d "$ts" +%s 2>/dev/null)" || held_epoch="$now"
  elapsed=$(( now - held_epoch ))
  [ "$elapsed" -gt 60 ] || return 1

  return 0
}

# wb_task_lock_acquire_guarded <task_file> — the ONE call site every cmd_*
# verb, wb_reconcile_action_*, and handoff.sh's own write site uses instead
# of calling wb_task_lock_acquire directly. wb_task_lock_acquire (U1) never
# auto-retries by design (W9) — retry is explicitly a caller-level decision,
# and this is that caller.
#
# On an uncontended win, behaves exactly like wb_task_lock_acquire: 0,
# silent. On a lost contention (75), reads the recorded holder's pid via
# wb-locks.sh's public wb_task_lock_holder_field (never its internal
# `_wb_lock_path_for`/`_wb_lock_field` accessors directly), and decides:
#   - holder pid already gone (`kill -0` fails) -> the kernel already
#     dropped the flock on process death; retry once — the cheap, common
#     crash case (L2's "if the PID is gone" clause).
#   - holder pid alive AND _wb_lock_holder_is_orphan confirms all four L2
#     conditions -> retry once. The already-read `holder_pid` is passed
#     straight into that check (rather than having it re-read the same
#     field a second time) — this whole path exists to resolve a contended
#     acquire quickly.
#   - anything else (alive session, unknown state, missing/empty holder
#     info) -> never retries. wb_task_lock_acquire's own failure — which
#     already printed the one L4 stderr message naming the holder — stands
#     unmodified; this function never prints a second message of its own.
# The retry itself is just another `wb_task_lock_acquire` call: wb-locks.sh
# is not touched by this unit, so there is no standalone non-blocking
# `flock -n` entry point to call directly — a retry against a lock that's
# actually free (the whole premise of clearing it here) returns effectively
# instantly through the existing `flock -w 1` path regardless.
wb_task_lock_acquire_guarded() {
  local task_file="$1"
  wb_task_lock_acquire "$task_file" && return 0
  local rc=$?

  local holder_pid; holder_pid="$(wb_task_lock_holder_field "$task_file" pid)"

  if [ -n "$holder_pid" ] && ! kill -0 "$holder_pid" 2>/dev/null; then
    wb_task_lock_acquire "$task_file"
    return $?
  fi

  if [ -n "$holder_pid" ] && _wb_lock_holder_is_orphan "$task_file" "$holder_pid"; then
    wb_task_lock_acquire "$task_file"
    return $?
  fi

  return "$rc"
}

# _wb_lock_trap_append_if_top_level <cleanup-command> — every cmd_*/
# wb_reconcile_action_*/handoff.sh call site below uses THIS instead of
# calling wb_lock_trap_append (U1) directly, guarding it on
# `$BASH_SUBSHELL = 0` (i.e. this process IS the top-level shell, not a
# subshell forked for a command substitution, background job, or explicit
# `( )`).
#
# Why the guard: wb_lock_trap_append's whole job is to call `trap ... EXIT`
# — that's necessary and correct composition when this IS the real,
# possibly-long-lived process (a fresh `bash wb.sh <verb>` invocation, or
# picker()'s own in-process `cmd_new` call composing with its pre-existing
# `trap 'rm -f "$mode_file"' EXIT`, W6's own worked example). But bash does
# NOT auto-fire an inherited EXIT trap in a subshell UNLESS that subshell
# itself calls `trap ... EXIT` again — which wb_lock_trap_append does
# unconditionally. So if a cmd_* function runs inside a subshell (the
# ubiquitous `out="$(cmd_pause ...)"` test idiom every existing wb.sh test
# file uses to capture output), calling wb_lock_trap_append there RE-ARMS,
# and then immediately FIRES on that subshell's own exit, whatever EXIT
# trap the ENCLOSING caller happened to have installed — which in every
# existing test file is a destructive `trap 'rm -rf "$FIXTURE" ...' EXIT`.
# Confirmed live while building wb-lock-integration.test.sh: wrapping
# wb_reconcile_action_merge in `$(...)` to capture its stderr silently
# deleted the test's own fixture mid-run, and the SAME shape broke
# wb-pause.test.sh's `out="$(cmd_pause "$SESSION" 2>&1)"` the moment
# cmd_pause gained its own wb_lock_trap_append call.
#
# The guard is safe to skip in the subshell case for a second, independent
# reason, not just "it would misbehave": a subshell's own natural process
# exit ALREADY closes every fd it holds (kernel auto-release, the final
# backstop behind even wb_task_lock_release_all itself) — the EXIT-trap
# safety net is pure redundancy there, so skipping it costs nothing.
#
# Installs at most once per top-level process (_WB_LOCK_TRAP_INSTALLED),
# regardless of how many cmd_*/wb_reconcile_action_* calls run in it — e.g.
# `wb reconcile --apply` looping over N checked findings would otherwise
# re-append the identical `wb_task_lock_release_all` cleanup N times, and
# wb_lock_trap_append's own `trap -p EXIT` + eval re-parse of the whole
# accumulated trap string on every call makes that cost grow with N, not
# just once. Every call site passes this function the SAME cleanup command
# (wb_task_lock_release_all), so once it's in the trap, appending it again
# changes nothing observable — the trap fires it exactly the same way at
# real process exit either way.
_wb_lock_trap_append_if_top_level() {
  [ "${BASH_SUBSHELL:-0}" -eq 0 ] || return 0
  [ "${_WB_LOCK_TRAP_INSTALLED:-0}" -eq 1 ] && return 0
  wb_lock_trap_append "$1"
  _WB_LOCK_TRAP_INSTALLED=1
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

# wb_ensure_repo_ignore <path> — idempotently register the queue file's
# pattern (`.claude-queue.md`) as ignored in whatever repo <path> belongs to,
# via that repo's own untracked `.git/info/exclude` — never that repo's
# tracked `.gitignore`, never a machine-wide `core.excludesFile` (see
# docs/plans/2026-07-11-003-feat-queue-command-plan.md's Planning Contract:
# a foreign repo under $CODE_DIR is not ours to edit, and a machine-wide
# setting would silently change `git status` for every repo on the machine).
# <path> may be a worktree or the main checkout — `git rev-parse
# --git-common-dir` resolves either to the one shared `.git` dir all of a
# repo's worktrees have in common, so this same call works whether it's
# handed a repo dir (cmd_new, below) or a worktree's cwd (queue.lua's lazy-
# create path, called on every stash).
#
# Guarded against two concrete failure modes: a missing trailing newline in
# a pre-existing info/exclude would otherwise glue the new pattern onto the
# end of the prior last line, corrupting both and breaking the `grep -qxF`
# idempotency check on every later call — fixed by ensuring the file ends in
# a newline before ever appending. A race between two concurrent callers for
# the same repo (two terminals, or a script, creating worktrees back to
# back) is fixed with a `flock` on a lockfile scoped to that repo's own
# `.git/info` directory, making the check-then-append atomic. This must
# NEVER truncate or overwrite existing content in info/exclude — other
# tooling, or the user, may already have entries there.
wb_ensure_repo_ignore() {
  local path="$1" pattern='.claude-queue.md'
  local git_common_dir
  git_common_dir="$(git -C "$path" rev-parse --git-common-dir 2>/dev/null)" || return 1
  # git prints a relative path when <path> is the main checkout (e.g.
  # ".git"), and an absolute one when <path> is a linked worktree — resolve
  # relative to <path> itself (not $PWD) since that's what `-C` scoped it to.
  case "$git_common_dir" in
    /*) : ;;
    *)  git_common_dir="$path/$git_common_dir" ;;
  esac
  git_common_dir="$(cd "$git_common_dir" && pwd)" || return 1

  local info_dir="$git_common_dir/info"
  mkdir -p "$info_dir"
  local exclude_file="$info_dir/exclude"
  local lockfile="$info_dir/.claude-queue.lock"

  (
    flock -x 9
    touch "$exclude_file"
    # A non-empty file whose last byte isn't a newline needs one before the
    # append below, or the new pattern would land glued onto the prior last
    # line instead of as its own line.
    if [ -s "$exclude_file" ] && [ -n "$(tail -c1 "$exclude_file")" ]; then
      printf '\n' >> "$exclude_file"
    fi
    # grep failing here (pattern not yet present) is the expected, common
    # case, not an error — see wb.sh's `set -e` note at the top of this
    # file; a non-final command in an && list doesn't trigger errexit.
    grep -qxF "$pattern" "$exclude_file" && exit 0
    printf '%s\n' "$pattern" >> "$exclude_file"
  ) 9>"$lockfile"
}

# wb_seed_task <repo> <slug> <worktree_rel> [<parent_ref>] [<file_override>]
# — find-or-create the task file for a repo+slug pair, filling blank
# frontmatter fields and bumping planned->doing. Never overwrites a field
# that's already set. <parent_ref> is optional (defaults to empty) so
# wb_reconcile_action_create_task's pre-existing 3-arg call keeps working
# unchanged — it never sets `parent:`. <file_override> is KTD7's directional
# escape hatch for `wb resume`: post-migration, a continuing child's own
# branch:/worktree: equal the PARENT's original identity, so re-deriving
# the task file from repo+slug via wb_task_file would resolve back to the
# PARENT's file — cmd_resume already knows the real (child) file from its
# own stem-based lookup and passes it straight through here instead.
wb_seed_task() {
  local repo="$1" slug="$2" worktree_rel="$3" parent="${4:-}" file_override="${5:-}"
  local file
  if [ -n "$file_override" ]; then
    file="$file_override"
  else
    local disp_slug; disp_slug="$(wb_sanitize "$slug")"
    file="$(wb_task_file "$repo" "$disp_slug")"
  fi

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
    [ -n "$(wb_get_frontmatter "$file" repo)" ] || wb_set_frontmatter "$file" repo "$repo"

    # Reattach guard (KTD7): don't backfill a blank branch:/worktree: pair
    # when another task file already claims that exact pair — a muscle-
    # memory `wb new <old-slug>` after a wb-breakdown migration would
    # otherwise silently refill the parent's deliberately-blanked fields,
    # leaving two files claiming one worktree.
    local claiming_file="" f
    if [ -z "$(wb_get_frontmatter "$file" branch)" ] || [ -z "$(wb_get_frontmatter "$file" worktree)" ]; then
      for f in $(wb_task_files); do
        [ "$f" != "$file" ] || continue
        [ "$(wb_get_frontmatter "$f" branch)" = "$slug" ] || continue
        [ "$(wb_get_frontmatter "$f" worktree)" = "$worktree_rel" ] || continue
        claiming_file="$f"
        break
      done
    fi
    if [ -n "$claiming_file" ]; then
      echo "wb_seed_task: not backfilling branch:/worktree: on $file — $claiming_file already claims branch=$slug worktree=$worktree_rel" >&2
    else
      [ -n "$(wb_get_frontmatter "$file" branch)" ]    || wb_set_frontmatter "$file" branch "$slug"
      [ -n "$(wb_get_frontmatter "$file" worktree)" ]  || wb_set_frontmatter "$file" worktree "$worktree_rel"
    fi

    [ "$(wb_get_frontmatter "$file" status)" != planned ] || wb_set_frontmatter "$file" status doing
    # reviewed: has no inferred value (unlike repo/branch/worktree above) —
    # it starts blank and is only ever stamped by cmd_reviewed. This just
    # backfills the KEY onto task files that predate it in the schema, same
    # as the other blank-field fills above, never overwriting a value
    # that's already set.
    [ -n "$(wb_get_frontmatter "$file" reviewed)" ]  || wb_set_frontmatter "$file" reviewed ""
  fi
  [ -z "$parent" ] || wb_set_frontmatter "$file" parent "$parent"
  echo "$file"
}

# wb_seed_task_planned <repo> <slug> [<parent_ref>] — W13's planned-preserving
# sibling of wb_seed_task: find-or-create the task file for a repo+slug pair
# WITHOUT ever creating a worktree, and WITHOUT wb_seed_task's own
# planned->doing flip or worktree stamping. Used by `wb new --planned`
# (cmd_new, below), in turn used by /parked-items' scratch-task creation and
# /handoff's task-file seeding step — both cases where no work has actually
# started yet, so there is no real worktree path to stamp and the task must
# stay `status: planned` rather than jump straight to `doing`. The REAL
# doing/worktree transition happens later, for real, the ordinary way,
# whenever something actually calls `wb new [--agent]` on the same repo/slug
# — that goes through wb_seed_task's own EXISTING-file branch above, which
# idempotently fills in exactly those fields without this function's
# involvement.
#
# New file: status is hardcoded to "planned" (never "doing"), repo:/branch:
# are filled from the arguments, worktree: is left exactly as TEMPLATE.md
# already has it (blank) — no substitution rule for it at all, unlike
# wb_seed_task's new-file branch above.
#
# Existing file: same non-clobbering backfill convention as wb_seed_task for
# repo:/branch:/reviewed:, but status: is ONLY backfilled when blank —
# never bumped or otherwise touched when already set, to ANY value (planned,
# doing, paused, done, ...). This is what makes a second call against the
# same repo/slug (idempotent re-run — e.g. /handoff routing a second,
# related discussion to an already-seeded task) safe: it can never clobber
# a status a real `wb new`/`wb new --agent` run already advanced past
# "planned" in the meantime.
wb_seed_task_planned() {
  local repo="$1" slug="$2" parent="${3:-}"
  local disp_slug; disp_slug="$(wb_sanitize "$slug")"
  local file; file="$(wb_task_file "$repo" "$disp_slug")"

  if [ ! -f "$file" ]; then
    mkdir -p "$TASKS_DIR"
    local title="${slug//-/ }"
    awk -v repo="$repo" -v branch="$slug" \
        -v created="$(date +%F)" -v title="$title" '
      BEGIN { infm = 0 }
      /^---$/     { infm++; print; next }
      infm == 1 && /^status:/   { print "status: planned"; next }
      infm == 1 && /^repo:/     { print "repo: " repo; next }
      infm == 1 && /^branch:/   { print "branch: " branch; next }
      infm == 1 && /^created:/  { print "created: " created; next }
      infm == 2 && /^# Title/   { print "# " title; next }
      { print }
    ' "$TASKS_DIR/TEMPLATE.md" > "$file"
  else
    [ -n "$(wb_get_frontmatter "$file" repo)" ]     || wb_set_frontmatter "$file" repo "$repo"
    [ -n "$(wb_get_frontmatter "$file" branch)" ]   || wb_set_frontmatter "$file" branch "$slug"
    [ -n "$(wb_get_frontmatter "$file" status)" ]   || wb_set_frontmatter "$file" status planned
    [ -n "$(wb_get_frontmatter "$file" reviewed)" ] || wb_set_frontmatter "$file" reviewed ""
  fi
  [ -z "$parent" ] || wb_set_frontmatter "$file" parent "$parent"
  echo "$file"
}

# _wb_insert_plan_body <file> <body> — insert <body> verbatim under <file>'s
# "## Plan" heading. Never routes <body> through awk -v: awk applies C
# escape-sequence processing to a -v assignment's value, which would mangle
# \n/\t/\K sequences a real plan body can legitimately carry (regex
# snippets, Windows paths, fenced-code examples) — the cited wb_seed_task/
# wb_reconcile_merge_content splices get away with awk -v only because their
# values never carry backslashes. Writing <body> to a temp file with `printf
# '%s'` (which never interprets backslashes in the value) and reading it back
# with awk's `getline` (which reads literal lines, no escape processing)
# avoids the mangling entirely. No-op when <body> is empty.
_wb_insert_plan_body() {
  local file="$1" body="$2"
  [ -n "$body" ] || return 0
  local bodyfile; bodyfile="$(mktemp)"
  printf '%s\n' "$body" > "$bodyfile"
  awk -v bodyfile="$bodyfile" '
    { print }
    $0 == "## Plan" {
      print ""
      while ((getline line < bodyfile) > 0) print line
    }
  ' "$file" > "$file.tmp.$$" && mv "$file.tmp.$$" "$file"
  rm -f "$bodyfile"
}

# wb_seed_planned_child <repo> <slug> <parent_ref> [<title>] — KTD3's child
# seeder for `wb breakdown --apply` (U3): creates a NEW planned child task
# file and NOTHING ELSE. <title> is the buffer's own editable "goal:" line
# (U3's "frontmatter + goal title" — the family's whole point is
# session-sized, human-named slices, not slug-derived titles); when omitted
# it falls back to the slug-derived form wb_seed_task/wb_seed_task_planned
# already use. Unlike wb_seed_task_planned (which fills blanks on an
# existing file and is reachable as the public `wb new --planned` verb),
# this function ALWAYS creates fresh and REFUSES on collision — an existing
# file at this stem means cmd_breakdown's own validation pass failed to
# catch a collision upstream, never something to merge into. Not a public
# verb; called only from cmd_breakdown's locked apply, which already holds
# this file's path lock before calling in (this function does no locking of
# its own).
#
# `status:` is left exactly as TEMPLATE.md has it (`planned`) — no
# substitution rule, matching wb_seed_task_planned's own new-file branch.
# `worktree:` is likewise left blank/untouched: wb_reconcile_collect only
# flags a MISSING worktree when both a task's repo: AND worktree: are set,
# so a planned child with a blank worktree: produces zero reconcile
# findings (AE2). `parent:` is set unconditionally — a child always has
# one, unlike wb_seed_task_planned's optional 3rd arg.
#
# The child's `## Plan` body is read from stdin (the buffer-carried plan
# text) and landed via _wb_insert_plan_body — see that function's own
# comment for why this never touches awk -v.
wb_seed_planned_child() {
  local repo="$1" slug="$2" parent="$3"
  local title="${4:-${slug//-/ }}"
  local disp_slug; disp_slug="$(wb_sanitize "$slug")"
  local file; file="$(wb_task_file "$repo" "$disp_slug")"

  if [ -f "$file" ]; then
    echo "wb_seed_planned_child: $file already exists — refusing to overwrite" >&2
    return 1
  fi

  mkdir -p "$TASKS_DIR"
  local body; body="$(cat)"

  awk -v repo="$repo" -v branch="$slug" -v parent="$parent" \
      -v created="$(date +%F)" -v title="$title" '
    BEGIN { infm = 0 }
    /^---$/     { infm++; print; next }
    infm == 1 && /^repo:/     { print "repo: " repo; next }
    infm == 1 && /^branch:/   { print "branch: " branch; next }
    infm == 1 && /^parent:/   { print "parent: " parent; next }
    infm == 1 && /^created:/  { print "created: " created; next }
    infm == 2 && /^# Title/   { print "# " title; next }
    { print }
  ' "$TASKS_DIR/TEMPLATE.md" > "$file"

  _wb_insert_plan_body "$file" "$body"
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
  local agent_flag=0 parent_ref="" planned_flag=0 jira_url=""
  local -a args=()
  while [ $# -gt 0 ]; do
    case "$1" in
      --agent)   agent_flag=1; shift ;;
      --planned) planned_flag=1; shift ;;
      --jira)
        case "${2-}" in
          ''|--*) echo "wb new: --jira requires a value" >&2; exit 1 ;;
        esac
        jira_url="$2"; shift 2 ;;
      --parent)
        case "${2-}" in
          ''|--*) echo "wb new: --parent requires a value" >&2; exit 1 ;;
        esac
        parent_ref="$2"; shift 2 ;;
      *)        args+=("$1"); shift ;;
    esac
  done

  if [ "$planned_flag" = 1 ] && [ "$agent_flag" = 1 ]; then
    echo "wb new: --planned and --agent are mutually exclusive — --planned never starts a worktree/session for --agent to attach to" >&2
    exit 1
  fi

  if [ -n "$jira_url" ] && [ "$planned_flag" != 1 ]; then
    echo "wb new: --jira is only valid together with --planned (ticket-parent seeding never starts a worktree/session)" >&2
    exit 1
  fi

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
    echo "usage: wb new [--agent|--planned [--jira <url>]] [--parent <repo>--<slug>] <slug> | wb new [--agent|--planned [--jira <url>]] [--parent <repo>--<slug>] <repo> <slug>" >&2
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

  if [ "$planned_flag" = 1 ]; then
    # W13's planned-preserving creation path: no worktree, no tmux session —
    # just a lock-guarded, idempotent task-file seed via wb_seed_task_planned
    # (above) that preserves `status: planned` (never the ordinary
    # planned->doing flip cmd_new's normal path below performs) and never
    # stamps `worktree:` to a path that doesn't exist yet. This is the verb
    # /parked-items (scratch tasks with no work started) and /handoff's
    # seeding step (the real doing/worktree transition happens later, for
    # real, whenever something actually calls `wb new [--agent]` on the same
    # repo/slug) both shell out to instead of an Edit-tool task-file write.
    # Prints the resolved task-file path on stdout (the one piece of output
    # a caller capturing `$(wb new --planned ...)` needs), mirroring
    # wb_seed_task_planned's own `echo "$file"` convention.
    #
    # --jira <url> extends this path (KTD3) for wb-breakdown's ticket-parent
    # seeding: stamps `jira:` and, if piped, lands a stdin `## Plan` body —
    # an extension of this same locked seed, never a duplicate path.
    # wb_seed_task_planned's own fill-blanks-only semantics already give
    # KTD9's find-or-create behavior for free (an existing task at this
    # stem is reused, never overwritten).
    local task_file; task_file="$(wb_task_file "$repo" "$disp_slug")"
    _wb_lock_trap_append_if_top_level wb_task_lock_release_all
    wb_task_lock_acquire_guarded "$task_file" || exit $?
    task_file="$(wb_seed_task_planned "$repo" "$slug" "$parent_ref")"
    if [ -n "$jira_url" ]; then
      wb_set_frontmatter "$task_file" jira "$jira_url"
      local ticket_body; ticket_body="$(cat)"
      _wb_insert_plan_body "$task_file" "$ticket_body"
    fi
    wb_task_lock_release "$task_file"
    echo "$task_file"
    return 0
  fi

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

  # Unconditional — not just for the branch above. This is self-healing for
  # a repo's OTHER, older worktrees that predate this feature: every `wb new`
  # call re-checks (idempotently) that this repo's .git/info/exclude has the
  # queue-file pattern registered, regardless of whether *this* invocation's
  # own worktree was newly created just now. Best-effort: under `set -e`, an
  # unguarded call here would abort the whole `wb new` (including a plain
  # reattach to an already-existing worktree/session) on any failure in this
  # unrelated step — warn and continue instead.
  wb_ensure_repo_ignore "$worktree_path" \
    || echo "wb new: warning: could not register .git/info/exclude ignore rule for $repo_dir (continuing)" >&2

  # W5: acquire BEFORE the $(wb_seed_task ...) command substitution, using
  # the wb_task_file-derived path computed here in the OUTER (cmd_new)
  # scope — the lock's fd must be owned by this process, not by the
  # subshell that command substitution spawns for wb_seed_task, or it
  # evaporates the instant that subshell exits.
  #
  # _WB_TASK_FILE_OVERRIDE (KTD7): set only by cmd_resume, for exactly the
  # post-migration case where repo+slug (the child's OWN inherited git
  # identity) would otherwise re-derive the PARENT's file via wb_task_file
  # — cmd_resume already resolved the real (child) file from its own
  # stem-based lookup and hands it straight through.
  local task_file
  if [ -n "${_WB_TASK_FILE_OVERRIDE:-}" ]; then
    task_file="$_WB_TASK_FILE_OVERRIDE"
  else
    task_file="$(wb_task_file "$repo" "$disp_slug")"
  fi
  _wb_lock_trap_append_if_top_level wb_task_lock_release_all
  wb_task_lock_acquire_guarded "$task_file" || exit $?
  task_file="$(wb_seed_task "$repo" "$slug" "$worktree_rel" "$parent_ref" "${_WB_TASK_FILE_OVERRIDE:-}")"
  wb_task_lock_release "$task_file"

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

# _wb_resolve_task_fuzzy <query> <verb-label> — case-insensitive substring
# match of <query> against every task file's basename (repo--slug, minus
# .md). Never guesses on ambiguity: 0 or 2+ matches both fail loudly
# (messages prefixed with <verb-label>, e.g. "wb resume"/"wb append", so
# each caller's errors still read as its own) instead of picking one. On
# exactly one match, prints its path to stdout and returns 0. Shared by
# cmd_resume and _wb_append_resolve_task's fuzzy fallback — both used to
# hand-duplicate this exact match/ambiguity-guard block.
_wb_resolve_task_fuzzy() {
  local query="$1" verb="$2"
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
      echo "$verb: no task matches '$query' in $TASKS_DIR" >&2
      return 1
      ;;
    1)
      printf '%s\n' "${matches[0]}"
      return 0
      ;;
    *)
      echo "$verb: '$query' matches ${#matches[@]} tasks — be more specific:" >&2
      for f in "${matches[@]}"; do
        echo "  $(basename "$f" .md)" >&2
      done
      return 1
      ;;
  esac
}

# cmd_resume <query> — resolves <query> (_wb_resolve_task_fuzzy, above),
# then hands off to cmd_new's existing worktree/session logic (already
# idempotent — safe whether the worktree still exists or was torn down by
# a prior `wb done`).
cmd_resume() {
  local query="${1:-}"
  [ -n "$query" ] || { echo "usage: wb resume <task>" >&2; exit 1; }

  local file
  file="$(_wb_resolve_task_fuzzy "$query" "wb resume")" || exit 1

  local repo branch
  repo="$(wb_get_frontmatter "$file" repo)"
  branch="$(wb_get_frontmatter "$file" branch)"
  [ -n "$repo" ] && [ -n "$branch" ] \
    || { echo "wb resume: $file has no repo:/branch: frontmatter to resume from" >&2; exit 1; }
  # KTD7: post-migration, a continuing child's branch:/worktree: equal the
  # PARENT's original identity — cmd_new deriving the task file from
  # repo+branch alone would resolve back to the PARENT's file. $file is
  # already the REAL target (resolved above by stem, not by branch), so
  # hand it straight through; cleared unconditionally right after so it
  # can never leak into an unrelated later cmd_new call in this process.
  _WB_TASK_FILE_OVERRIDE="$file" cmd_new "$repo" "$branch"
  unset _WB_TASK_FILE_OVERRIDE
  # Handoffs-append lives HERE, not inside cmd_new — cmd_new is also
  # the path every fresh `wb new` takes, and a fresh task must not
  # gain a Handoffs entry (see wb_append_handoff's own header comment).
  # A SEPARATE lock burst from cmd_new's own internal one above (which
  # has already released by the time cmd_new returns) — never nested.
  _wb_lock_trap_append_if_top_level wb_task_lock_release_all
  wb_task_lock_acquire_guarded "$file" || exit $?
  wb_append_handoff "$file" "wb resume" 'Session resumed via `wb resume`.'
  wb_task_lock_release "$file"
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
  root="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel 2>/dev/null)" || true
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
    # W10: a bare `rm -f` racing another writer's tmp+mv can resurrect the
    # file if unlocked — lock the target task file for this remove too.
    _wb_lock_trap_append_if_top_level wb_task_lock_release_all
    wb_task_lock_acquire_guarded "$taskfile" || return $?
    if [ -f "$taskfile" ]; then
      rm -f "$taskfile"
      echo "wb reconcile --apply: removed stale task file $taskfile"
    else
      echo "wb reconcile --apply: $taskfile already gone, nothing to remove" >&2
    fi
    wb_task_lock_release "$taskfile"
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
  # Same W5 shape as cmd_new: acquire in THIS (outer) scope before the
  # $(wb_seed_task ...) command substitution, using the wb_task_file-derived
  # path — wb_seed_task's own file resolution is repo + sanitize(branch).
  local file; file="$(wb_task_file "$repo" "$(wb_sanitize "$branch")")"
  _wb_lock_trap_append_if_top_level wb_task_lock_release_all
  wb_task_lock_acquire_guarded "$file" || return $?
  file="$(wb_seed_task "$repo" "$branch" "$worktree" "$parent")"
  wb_task_lock_release "$file"
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
  _wb_lock_trap_append_if_top_level wb_task_lock_release_all
  wb_task_lock_acquire_guarded "$target_file" || return $?
  wb_set_frontmatter "$target_file" worktree "$worktree"
  wb_task_lock_release "$target_file"
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

  # W11: this action touches TWO files (survivor + loser) — acquire BOTH
  # locks in sorted-path order (lexically first path first) so a concurrent
  # dual-file operation over the same pair can never deadlock by acquiring
  # in opposite order.
  _wb_lock_trap_append_if_top_level wb_task_lock_release_all
  local -a sorted_pair
  mapfile -t sorted_pair < <(printf '%s\n%s\n' "$taskfile" "$target_file" | sort)
  wb_task_lock_acquire_guarded "${sorted_pair[0]}" || return $?
  # Deliberately NOT `if ! wb_task_lock_acquire_guarded ...; then` — `$?`
  # inside that `then` branch reflects the NEGATED condition's own exit
  # status (always 0, since `!` flipped the real failure to make the branch
  # taken at all), not the original acquire's 75; confirmed live (`if ! foo;
  # then echo $?; fi` prints 0 even when foo returns 75). Calling it as a
  # plain statement first and reading `$?` immediately after is the only
  # reliable way to capture the REAL failing exit code here — this exact
  # class of bug (silently clobbering a captured 75 into a false 0) already
  # bit this same line once via a *different* mistake (a `|| { release;
  # return $?; }` where `release`'s own always-0 return clobbered `$?`),
  # caught live by wb-lock-integration.test.sh's sorted-second-locked
  # scenario — this rewrite avoids both footguns at once.
  wb_task_lock_acquire_guarded "${sorted_pair[1]}"
  local second_rc=$?
  if [ "$second_rc" -ne 0 ]; then
    wb_task_lock_release "${sorted_pair[0]}"
    return "$second_rc"
  fi

  case "${survivor_checks[0]}" in
    "this finding"*) wb_reconcile_merge_content "$taskfile" "$target_file" ;;
    *)                wb_reconcile_merge_content "$target_file" "$taskfile" ;;
  esac
  echo "wb reconcile --apply: merged $taskfile and $target_file"

  wb_task_lock_release "${sorted_pair[1]}"
  wb_task_lock_release "${sorted_pair[0]}"
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

  local reopen_needed=0 applied_count=0 skipped_count=0
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
      # Every action call below is guarded with `|| { ...; continue; }`:
      # each one now goes through a lock (W10), which can return 75 on
      # contention -- routine, not rare, at this feature's ~10-concurrent-
      # agent scale. wb.sh runs under `set -e`, so an UNGUARDED bare call
      # here would abort this WHOLE --apply batch on the very first
      # contended finding, silently skipping every finding after it with
      # no report distinguishing "skipped" from "intentionally left
      # alone" — degrade to a per-finding skip instead.
      wb_reconcile_action_remove "$kind" "$repo" "$branch" "$worktree" "$taskfile" \
        || { echo "wb reconcile --apply: skipped this finding (remove, rc=$?)" >&2; skipped_count=$((skipped_count + 1)); continue; }
      applied_count=$((applied_count + 1))
    elif printf '%s' "$b" | grep -qE '^- \[x\] create a task'; then
      local parent_ref=""
      parent_ref="$(printf '%s' "$b" | grep -oP 'create a task \(optional parent: `\K[^`]+' | head -1)"
      [ "$parent_ref" != '___' ] || parent_ref=""
      wb_reconcile_action_create_task "$kind" "$repo" "$branch" "$worktree" "$parent_ref" \
        || { echo "wb reconcile --apply: skipped this finding (create a task, rc=$?)" >&2; skipped_count=$((skipped_count + 1)); continue; }
      applied_count=$((applied_count + 1))
    elif printf '%s' "$b" | grep -qP "^- \[x\] attach to task: \`[^\`_]+\`"; then
      target="$(printf '%s' "$b" | grep -oP '^- \[x\] attach to task: `\K[^`]+' | head -1)"
      wb_reconcile_action_attach "$kind" "$worktree" "$target" \
        || { echo "wb reconcile --apply: skipped this finding (attach to task, rc=$?)" >&2; skipped_count=$((skipped_count + 1)); continue; }
      applied_count=$((applied_count + 1))
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
      wb_reconcile_action_merge "$kind" "$repo" "$branch" "$worktree" "$taskfile" "$target" "$b" \
        || { echo "wb reconcile --apply: skipped this finding (merge with task, rc=$?)" >&2; skipped_count=$((skipped_count + 1)); continue; }
      applied_count=$((applied_count + 1))
    fi
  done

  if [ "$skipped_count" -gt 0 ]; then
    echo "wb reconcile --apply: $applied_count applied, $skipped_count skipped (contended or otherwise failed — re-run \`wb reconcile --apply\` to retry the skipped finding(s); the review doc is unchanged, so already-applied findings won't be re-applied)" >&2
  fi

  if [ "$reopen_needed" = 1 ]; then
    printf '%s' "$full_content" > "$path"
    echo "wb reconcile --apply: added survivor choices for new merges — reopening for confirmation"
    wb_open_buffer "$path"
  fi
}

# ---------------------------------------------------------------------------
# wb breakdown — split one oversized task into a linked parent/child family
# (docs/plans/2026-07-12-001-feat-wb-breakdown-skill-plan.md). U2 builds the
# buffer grammar's parse + validate half only — no store writes here; U3
# adds the locked apply execution on top of this same parse/validate core.
# ---------------------------------------------------------------------------

# wb_breakdown_report_path <parent_stem> — twin of wb_reconcile_report_path,
# keeping the `|| true` on the git lookup (a bare failing `$(git …)` under
# `set -e` was a real shipped bug there). One buffer per parent, unlike
# reconcile's single global report.
wb_breakdown_report_path() {
  local stem="$1" root
  root="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel 2>/dev/null)" || true
  [ -n "$root" ] || root="$CODE_DIR/dotfiles"
  printf '%s/logs/breakdowns/%s.md\n' "$root" "$stem"
}

# _wb_bd_checkbox_state <line> — classify a line against KTD1's checkbox
# grammar. "extra indentation" and `*` bullets are accepted forms (test
# scenario); a line that LOOKS like an attempted checkbox (bullet + `[`)
# but doesn't match the strict well-formed shape is "malformed", never
# silently "none" — KTD1: never silently treated as unchecked. Anything
# that doesn't even attempt a checkbox (a bare `- goal: ...` bullet, a
# blockquote, prose) is "none".
_wb_bd_checkbox_state() {
  local line="$1"
  if [[ "$line" =~ ^[[:space:]]*[-*][[:space:]]+\[([[:space:]xX])\][[:space:]] ]]; then
    case "${BASH_REMATCH[1]}" in
      x|X) echo checked ;;
      *)   echo unchecked ;;
    esac
    return 0
  fi
  if [[ "$line" =~ ^[[:space:]]*[-*][[:space:]]*\[ ]]; then
    echo malformed
    return 0
  fi
  echo none
}

# _wb_bd_field <block-text> <key> — extract key=value from <block-text>'s
# own opening marker line (its first line, always a `block=...` marker by
# construction of _wb_breakdown_parse_blocks).
_wb_bd_field() {
  printf '%s' "$1" | head -1 | grep -oP "(?<= )$2=\K[^ ]+"
}

# _wb_bd_plan_markers_ok <block-text> — exactly one begin-plan then exactly
# one end-plan, in that order; anything else is unbalanced (KTD1: hard
# parse error, never silently ignored).
_wb_bd_plan_markers_ok() {
  local block="$1" begins ends first_kind
  begins="$(printf '%s' "$block" | grep -c '<!-- wb-breakdown: begin-plan')"
  ends="$(printf '%s' "$block" | grep -c '<!-- wb-breakdown: end-plan')"
  [ "$begins" -eq 1 ] && [ "$ends" -eq 1 ] || return 1
  first_kind="$(printf '%s' "$block" | grep -oE '<!-- wb-breakdown: (begin|end)-plan' | head -1)"
  [ "$first_kind" = "<!-- wb-breakdown: begin-plan" ]
}

# _wb_bd_plan_body <block-text> — lines strictly between begin-plan and
# end-plan. Caller must have already confirmed _wb_bd_plan_markers_ok.
_wb_bd_plan_body() {
  printf '%s' "$1" | awk '
    /<!-- wb-breakdown: begin-plan/ { inbody = 1; next }
    /<!-- wb-breakdown: end-plan/   { inbody = 0; next }
    inbody { print }
  '
}

# _wb_breakdown_parse_blocks <path> <array_name> — split <path> into raw
# block strings, one per `<!-- wb-breakdown: block=... -->` marker (mirrors
# wb_reconcile_apply's own block splitter). begin-plan/end-plan sub-markers
# stay embedded inside their owning block's text — only a `block=` marker
# starts a NEW block.
_wb_breakdown_parse_blocks() {
  local path="$1"
  local -n _wbd_out="$2"
  _wbd_out=()
  local block="" line in_block=0
  while IFS= read -r line; do
    case "$line" in
      '<!-- wb-breakdown: block='*)
        [ "$in_block" = 1 ] && _wbd_out+=("$block")
        block="$line"$'\n'; in_block=1 ;;
      *)
        [ "$in_block" = 1 ] && block+="$line"$'\n' ;;
    esac
  done < "$path"
  [ "$in_block" = 1 ] && _wbd_out+=("$block")
}

# _wb_breakdown_validate <path> — parse + validate a closed buffer. Prints
# one TSV row per CONFIRMED (checked and valid) action to stdout:
#   create\t<n>\t<repo>\t<raw_slug>\t<disp_slug>\t<title>
#   migrate\t<raw_slug>\t<disp_slug>
#   plan_rewrite\tparent
#   move\t<raw_slug>\t<disp_slug>\t<bullet_text>
# Hard parse errors (mangled/missing markers, duplicate n=, a second
# migration line, a multi-parent buffer, a whitespace/backtick-bearing
# slug) abort the WHOLE validate — nothing is trustworthy once the buffer's
# own structure can't be trusted (KTD1). Per-item validation failures
# (collisions, an unresolvable migration/move target) print a warning to
# stderr and are simply left out of the stdout action list (reconcile's
# warn-and-skip posture) — the caller decides what "skipped" means for
# exit-code purposes.
_wb_breakdown_validate() {
  local path="$1"
  [ -n "$path" ] || { echo "wb breakdown --apply: usage: wb breakdown --apply <buffer-path>" >&2; return 1; }
  [ -s "$path" ] || { echo "wb breakdown --apply: no buffer at $path (or it's empty) — nothing to apply" >&2; return 1; }

  # --- orphan-checkbox pre-pass: any real or attempted checkbox line before
  # the first block= marker means a marker went missing/mangled above it. --
  local line lineno=0 saw_marker=0 state
  while IFS= read -r line; do
    lineno=$((lineno + 1))
    case "$line" in
      '<!-- wb-breakdown: block='*) saw_marker=1; continue ;;
    esac
    [ "$saw_marker" = 0 ] || continue
    state="$(_wb_bd_checkbox_state "$line")"
    if [ "$state" != none ]; then
      echo "wb breakdown --apply: checkbox-shaped line before any wb-breakdown block marker (line $lineno) — a block marker is missing or mangled: $line" >&2
      return 2
    fi
  done < "$path"

  local -a blocks=()
  _wb_breakdown_parse_blocks "$path" blocks
  [ "${#blocks[@]}" -gt 0 ] || { echo "wb breakdown --apply: $path has no wb-breakdown blocks — malformed or empty buffer" >&2; return 2; }

  # --- structural (hard) checks across all blocks ---------------------------
  local b kind n parent repo
  local parent_stem="" seen_ns="" mig_count=0 mig_lines=""
  for b in "${blocks[@]}"; do
    kind="$(_wb_bd_field "$b" block)"
    parent="$(_wb_bd_field "$b" parent)"

    if [ -z "$parent_stem" ]; then
      parent_stem="$parent"
    elif [ "$parent" != "$parent_stem" ]; then
      echo "wb breakdown --apply: buffer references more than one parent ($parent_stem and $parent) — a breakdown buffer is single-parent" >&2
      return 2
    fi

    if ! _wb_bd_plan_markers_ok "$b"; then
      echo "wb breakdown --apply: unbalanced begin-plan/end-plan markers in a $kind block (marker line: $(printf '%s' "$b" | head -1))" >&2
      return 2
    fi

    if [ "$kind" = child ]; then
      n="$(_wb_bd_field "$b" n)"
      case " $seen_ns " in
        *" $n "*) echo "wb breakdown --apply: duplicate n=$n across child blocks" >&2; return 2 ;;
      esac
      seen_ns="$seen_ns $n"

      local -a create_lines=()
      while IFS= read -r line; do
        printf '%s' "$line" | grep -q 'create child:' && create_lines+=("$line")
      done < <(printf '%s' "$b")
      if [ "${#create_lines[@]}" -ne 1 ]; then
        echo "wb breakdown --apply: child block n=$n must have exactly one 'create child:' line, found ${#create_lines[@]} (marker: $(printf '%s' "$b" | head -1))" >&2
        return 2
      fi
      local cl_state; cl_state="$(_wb_bd_checkbox_state "${create_lines[0]}")"
      if [ "$cl_state" = malformed ] || [ "$cl_state" = none ]; then
        echo "wb breakdown --apply: malformed checkbox on child n=$n's create-child line: ${create_lines[0]}" >&2
        return 2
      fi
      local raw_slug; raw_slug="$(printf '%s' "${create_lines[0]}" | grep -oP 'create child: `\K[^`]*')"
      if [ -z "$raw_slug" ]; then
        echo "wb breakdown --apply: child n=$n's create-child line has no backticked slug: ${create_lines[0]}" >&2
        return 2
      fi
      if [[ "$raw_slug" == *[[:space:]]* ]] || [[ "$raw_slug" == *'`'* ]]; then
        echo "wb breakdown --apply: child n=$n's slug \`$raw_slug\` contains whitespace or a backtick — wb_sanitize doesn't strip either: ${create_lines[0]}" >&2
        return 2
      fi
    fi

    if [ "$kind" = parent ]; then
      local -a mig_lines_here=()
      while IFS= read -r line; do
        [ "$(_wb_bd_checkbox_state "$line")" = none ] && continue
        printf '%s' "$line" | grep -qP 'migrate branch/worktree .* continuing child:' && mig_lines_here+=("$line")
      done < <(printf '%s' "$b")
      mig_count=$((mig_count + ${#mig_lines_here[@]}))
      if [ "${#mig_lines_here[@]}" -gt 1 ]; then
        echo "wb breakdown --apply: more than one migration line in the parent block (checked or not): ${mig_lines_here[*]}" >&2
        return 2
      fi
      if [ "$mig_count" -gt 1 ]; then
        echo "wb breakdown --apply: more than one migration line across the parent block" >&2
        return 2
      fi
    fi
  done

  if [ -z "$parent_stem" ]; then
    echo "wb breakdown --apply: no parent= field found on any block" >&2
    return 2
  fi

  local parent_file parent_repo
  parent_file="$(wb_resolve_parent_ref "$parent_stem")" || return 2
  parent_repo="$(wb_get_frontmatter "$parent_file" repo)"
  if ! _wb_bd_check_no_cycle "$parent_stem"; then
    return 2
  fi

  # --- item-level validation + stdout action rows ---------------------------
  local -a confirmed_child_stems=()
  for b in "${blocks[@]}"; do
    [ "$(_wb_bd_field "$b" block)" = child ] || continue
    n="$(_wb_bd_field "$b" n)"
    repo="$(_wb_bd_field "$b" repo)"
    local create_line; create_line="$(printf '%s' "$b" | grep -P '^\s*[-*]\s+\[[ xX]\]\s+create child:' | head -1)"
    [ "$(_wb_bd_checkbox_state "$create_line")" = checked ] || continue

    local raw_slug disp_slug title
    raw_slug="$(printf '%s' "$create_line" | grep -oP 'create child: `\K[^`]*')"
    disp_slug="$(wb_sanitize "$raw_slug")"
    title="$(printf '%s' "$b" | grep -oP '^\s*-\s+goal:\s*\K.*' | head -1)"

    local collision=0
    local other
    for other in "${confirmed_child_stems[@]}"; do
      [ "$other" != "$repo--$disp_slug" ] || { collision=1; break; }
    done
    if [ "$collision" = 1 ]; then
      echo "wb breakdown --apply: skipping child n=$n ($raw_slug) — sanitizes to $repo--$disp_slug, already claimed by another checked child in this buffer" >&2
      continue
    fi
    if [ -f "$TASKS_DIR/$repo--$disp_slug.md" ]; then
      echo "wb breakdown --apply: skipping child n=$n ($raw_slug) — $repo--$disp_slug already exists in the store" >&2
      continue
    fi

    confirmed_child_stems+=("$repo--$disp_slug")
    printf 'create\t%s\t%s\t%s\t%s\t%s\n' "$n" "$repo" "$raw_slug" "$disp_slug" "$title"
  done

  for b in "${blocks[@]}"; do
    [ "$(_wb_bd_field "$b" block)" = parent ] || continue

    local mig_line; mig_line="$(printf '%s' "$b" | grep -P 'migrate branch/worktree .* continuing child:' | head -1)"
    if [ -n "$mig_line" ] && [ "$(_wb_bd_checkbox_state "$mig_line")" = checked ]; then
      local mig_target; mig_target="$(printf '%s' "$mig_line" | grep -oP 'continuing child: `\K[^`]*')"
      if [ -z "$mig_target" ] || [ "$mig_target" = ___ ]; then
        echo "wb breakdown --apply: skipping migration — target field is unfilled (\`___\`)" >&2
      elif [ -z "$(wb_get_frontmatter "$parent_file" branch)" ] && [ -z "$(wb_get_frontmatter "$parent_file" worktree)" ]; then
        echo "wb breakdown --apply: skipping migration — parent $parent_stem is already session-less (no branch:/worktree: to give)" >&2
      else
        local mig_disp; mig_disp="$(wb_sanitize "$mig_target")"
        local mig_ok=0 cs
        for cs in "${confirmed_child_stems[@]}"; do
          [ "$cs" != "$parent_repo--$mig_disp" ] || { mig_ok=1; break; }
        done
        if [ "$mig_ok" = 0 ]; then
          local existing_child
          for existing_child in $(wb_task_files); do
            [ "$(wb_get_frontmatter "$existing_child" parent)" = "$parent_stem" ] || continue
            [ "$(wb_get_frontmatter "$existing_child" branch)" = "$mig_target" ] || continue
            mig_ok=1; break
          done
        fi
        if [ "$mig_ok" = 1 ]; then
          printf 'migrate\t%s\t%s\n' "$mig_target" "$mig_disp"
        else
          echo "wb breakdown --apply: skipping migration — target \`$mig_target\` is neither a checked child in this buffer nor an existing child of $parent_stem" >&2
        fi
      fi
    fi

    local rewrite_line; rewrite_line="$(printf '%s' "$b" | grep -P '^\s*[-*]\s+\[[ xX]\]\s+rewrite parent ## Plan as below' | head -1)"
    if [ -n "$rewrite_line" ] && [ "$(_wb_bd_checkbox_state "$rewrite_line")" = checked ]; then
      printf 'plan_rewrite\tparent\n'
    fi

    local followups; followups="$(wb_board_section "$parent_file" "Follow-ups")"
    while IFS= read -r line; do
      [ "$(_wb_bd_checkbox_state "$line")" = checked ] || continue
      printf '%s' "$line" | grep -qP "move follow-up:" || continue
      local move_text move_target
      move_text="$(printf '%s' "$line" | grep -oP 'move follow-up: "\K[^"]*')"
      move_target="$(printf '%s' "$line" | grep -oP 'child: `\K[^`]*')"
      local match_count; match_count="$(printf '%s' "$followups" | grep -cxF -- "- $move_text")"
      if [ "$match_count" -ne 1 ]; then
        echo "wb breakdown --apply: skipping follow-up move (\"$move_text\") — matched $match_count bullet(s) in $parent_stem's ## Follow-ups (need exactly 1)" >&2
        continue
      fi
      local move_disp; move_disp="$(wb_sanitize "$move_target")"
      local move_ok=0 cs2
      for cs2 in "${confirmed_child_stems[@]}"; do
        [ "$cs2" != "$parent_repo--$move_disp" ] || { move_ok=1; break; }
      done
      if [ "$move_ok" = 0 ]; then
        local existing_child2
        for existing_child2 in $(wb_task_files); do
          [ "$(wb_get_frontmatter "$existing_child2" parent)" = "$parent_stem" ] || continue
          [ "$(wb_get_frontmatter "$existing_child2" branch)" = "$move_target" ] || continue
          move_ok=1; break
        done
      fi
      if [ "$move_ok" = 1 ]; then
        printf 'move\t%s\t%s\t%s\n' "$move_target" "$move_disp" "$move_text"
      else
        echo "wb breakdown --apply: skipping follow-up move (\"$move_text\") — target \`$move_target\` is neither a checked child in this buffer nor an existing child of $parent_stem" >&2
      fi
    done < <(printf '%s' "$b")
  done

  return 0
}

# _wb_bd_check_no_cycle <stem> — walk <stem>'s own parent: chain (bounded to
# 50 hops) and fail loud if it ever revisits a stem already seen. Defends
# the (unrelated to this operation) case of a corrupted store already
# carrying an A->B->A parent chain — this operation never creates one
# itself, since every new child's parent: is <stem>, a leaf write.
_wb_bd_check_no_cycle() {
  local stem="$1" seen=" $1 " cur="$1" depth=0 next_file next_parent
  while [ "$depth" -lt 50 ]; do
    next_file="$TASKS_DIR/$cur.md"
    [ -f "$next_file" ] || return 0
    next_parent="$(wb_get_frontmatter "$next_file" parent)"
    [ -n "$next_parent" ] || return 0
    case "$seen" in
      *" $next_parent "*)
        echo "wb breakdown --apply: cycle detected in $stem's existing parent chain at $next_parent — refusing" >&2
        return 1 ;;
    esac
    seen="$seen$next_parent "
    cur="$next_parent"
    depth=$((depth + 1))
  done
  echo "wb breakdown --apply: $stem's parent chain exceeds 50 hops — refusing (possible cycle)" >&2
  return 1
}

# cmd_breakdown --apply <buffer-path> — U2: parse + validate only, no writes
# (U3 extends this same function with the locked write execution).
cmd_breakdown() {
  case "${1:-}" in
    --apply)
      shift
      local path="${1:-}"
      local -a actions=()
      local out rc
      out="$(_wb_breakdown_validate "$path")"; rc=$?
      [ "$rc" -eq 0 ] || return "$rc"
      if [ -z "$out" ]; then
        echo "wb breakdown --apply: nothing checked — no-op"
        return 0
      fi
      local n_create n_migrate n_rewrite n_move
      n_create="$(printf '%s\n' "$out" | grep -c $'^create\t')"
      n_migrate="$(printf '%s\n' "$out" | grep -c $'^migrate\t')"
      n_rewrite="$(printf '%s\n' "$out" | grep -c $'^plan_rewrite\t')"
      n_move="$(printf '%s\n' "$out" | grep -c $'^move\t')"
      echo "wb breakdown --apply: validated $n_create child(ren) to create, migration: $([ "$n_migrate" -gt 0 ] && echo yes || echo no), parent Plan rewrite: $([ "$n_rewrite" -gt 0 ] && echo yes || echo no), $n_move follow-up move(s) — no writes yet (U3)"
      ;;
    *)
      echo "usage: wb breakdown --apply <buffer-path>" >&2
      return 1
      ;;
  esac
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

  local task_file
  task_file="$(wb_session_task_file "$session")" \
    || { echo "wb pause: $session has no @wb_repo/@wb_slug — not a wb task session" >&2; exit 1; }
  [ -f "$task_file" ] || { echo "wb pause: no task file for $session ($task_file)" >&2; exit 1; }

  _wb_lock_trap_append_if_top_level wb_task_lock_release_all
  wb_task_lock_acquire_guarded "$task_file" || exit $?
  wb_set_frontmatter "$task_file" status paused
  wb_append_handoff "$task_file" "wb pause" 'Session paused via `wb pause`.'
  wb_task_lock_release "$task_file"
  echo "wb pause: $session paused — worktree and session untouched, task -> paused ($task_file)"
}

# ---------------------------------------------------------------------------
# wb reviewed — stamp a task's /ce-code-review pass as done
# ---------------------------------------------------------------------------

# cmd_reviewed <session> — stamps a task's `reviewed:` frontmatter field with
# today's date. Mirrors cmd_pause's shape exactly (wb.sh:805-824): resolve
# session from arg or current tmux session, read @wb_repo/@wb_slug, resolve
# the task file, stamp the field. /ce-code-review's own artifacts are
# ephemeral (/tmp/compound-engineering/...) and it may touch zero repo files
# in mode:agent, so unlike /ce-work there is no git-observable signal for
# "a review happened" — this field is the only buildable detection without
# modifying the external skill. Detection is wb_lifecycle_review_done
# (wb-lifecycle.sh) — `[ -n "$(wb_get_frontmatter "$taskfile" reviewed)" ]`.
# Deliberate limitation, same trade-off wb pause already accepts for
# `status: paused`: this requires a habit (running `wb reviewed` after a
# review pass); no staleness invalidation either — a task that receives
# further commits after being stamped still shows reviewed done. See
# logs/decisions/2026-07-11-wb-board-lifecycle-detection.md.
cmd_reviewed() {
  local session="${1:-}"
  if [ -z "$session" ]; then
    [ -n "${TMUX:-}" ] || { echo "wb reviewed: run inside the target session, or pass a session name" >&2; exit 1; }
    session="$(tmux display-message -p '#S')"
  fi

  local task_file
  task_file="$(wb_session_task_file "$session")" \
    || { echo "wb reviewed: $session has no @wb_repo/@wb_slug — not a wb task session" >&2; exit 1; }
  [ -f "$task_file" ] || { echo "wb reviewed: no task file for $session ($task_file)" >&2; exit 1; }

  _wb_lock_trap_append_if_top_level wb_task_lock_release_all
  wb_task_lock_acquire_guarded "$task_file" || exit $?
  wb_set_frontmatter "$task_file" reviewed "$(date +%F)"
  wb_task_lock_release "$task_file"
  echo "wb reviewed: $session marked reviewed ($task_file)"
}

# ---------------------------------------------------------------------------
# wb sync — the paved path for pulling shared $TASKS_DIR changes: fetch, then
# fast-forward-only merge, refusing loudly on anything that isn't a clean
# fast-forward. Exists so nobody reaches for `git reset --hard
# origin/<branch>` (or a force-push) to "fix" a stuck TASKS_DIR — that IS
# the anti-pattern that caused the 2026-07-10 incident this concurrency-
# safety effort responds to. This command NEVER pushes, under any
# circumstance.
# ---------------------------------------------------------------------------

# _wb_git_dirty_guard <path> <verb-label> — fail loud (exit 1, naming
# <verb-label>) if <path>'s git status is non-empty; silent no-op
# otherwise. Shared by cmd_sync and cmd_done, which used to hand-duplicate
# this exact guard (only the path and the verb name differed).
_wb_git_dirty_guard() {
  local path="$1" verb="$2" dirty
  dirty="$(git -C "$path" status --porcelain 2>/dev/null || true)"
  if [ -n "$dirty" ]; then
    echo "$verb: $path is dirty:" >&2
    echo "$dirty" >&2
    echo "commit or stash, then re-run" >&2
    exit 1
  fi
}

# cmd_sync — guard order: fetch (loud abort on failure) -> dirty-tree guard
# -> branch/detached-HEAD guard -> ahead/behind decision (ff-merge / no-op /
# refuse-diverged).
cmd_sync() {
  # 1. fetch FIRST — never compare against a possibly-stale local
  # origin/<branch> ref. A failed fetch (offline, no SSH agent, unreachable
  # remote, ...) aborts loudly, not a silent no-op against stale refs.
  if ! git -C "$TASKS_DIR" fetch origin; then
    echo "wb sync: git fetch origin failed for $TASKS_DIR — offline, no SSH agent, or the remote is unreachable; aborting without comparing refs" >&2
    exit 1
  fi

  # 2. dirty-tree guard.
  _wb_git_dirty_guard "$TASKS_DIR" "wb sync"

  # 3. branch guard — refuse on a detached HEAD or on any branch other than
  # the remote's own tracked default branch. Deliberately NOT hardcoded to
  # "development" or "main" — that's a per-repo convention, and this task
  # store's default branch is whatever origin/HEAD actually says, not an
  # assumption baked into this script. Prefer the locally-cached
  # refs/remotes/origin/HEAD symref (set by `git clone`); fall back to
  # asking the remote directly (`ls-remote --symref`, same primitive) when
  # that symref was never established — e.g. a checkout built by `init` +
  # `remote add` + `fetch` rather than `clone` (confirmed against a real
  # ~/code/tasks checkout, which hit exactly this fallback path).
  local expected_branch
  expected_branch="$(git -C "$TASKS_DIR" symbolic-ref -q --short refs/remotes/origin/HEAD 2>/dev/null || true)"
  expected_branch="${expected_branch#origin/}"
  if [ -z "$expected_branch" ]; then
    expected_branch="$(git -C "$TASKS_DIR" ls-remote --symref origin HEAD 2>/dev/null \
      | awk '$1 == "ref:" { sub("^refs/heads/", "", $2); print $2; exit }')"
  fi
  if [ -z "$expected_branch" ]; then
    echo "wb sync: could not determine origin's default branch for $TASKS_DIR (no origin/HEAD symref, and ls-remote --symref failed) — refusing to guess" >&2
    exit 1
  fi

  local current_ref
  current_ref="$(git -C "$TASKS_DIR" symbolic-ref -q HEAD 2>/dev/null || true)"
  if [ -z "$current_ref" ]; then
    echo "wb sync: $TASKS_DIR has a detached HEAD — refusing to fast-forward-merge into a detached state; check out $expected_branch first" >&2
    exit 1
  fi
  local current_branch="${current_ref#refs/heads/}"
  if [ "$current_branch" != "$expected_branch" ]; then
    echo "wb sync: $TASKS_DIR is on '$current_branch', not '$expected_branch' (the tracked default branch) — refusing to fast-forward-merge into the wrong branch" >&2
    exit 1
  fi

  # 4. ahead/behind decision.
  local counts ahead behind
  counts="$(git -C "$TASKS_DIR" rev-list --left-right --count "HEAD...origin/$expected_branch" 2>/dev/null)" || {
    echo "wb sync: could not compare $TASKS_DIR against origin/$expected_branch after fetch" >&2
    exit 1
  }
  ahead="$(printf '%s' "$counts" | awk '{print $1}')"
  behind="$(printf '%s' "$counts" | awk '{print $2}')"
  ahead="${ahead:-0}"
  behind="${behind:-0}"

  if [ "$ahead" -eq 0 ] && [ "$behind" -eq 0 ]; then
    echo "wb sync: $TASKS_DIR already up to date with origin/$expected_branch"
  elif [ "$ahead" -eq 0 ]; then
    git -C "$TASKS_DIR" merge --ff-only "origin/$expected_branch"
    echo "wb sync: pulled $behind commit(s) — $TASKS_DIR now matches origin/$expected_branch"
  elif [ "$behind" -eq 0 ]; then
    echo "wb sync: $TASKS_DIR is $ahead commit(s) ahead of origin/$expected_branch — nothing to pull, consider pushing (wb sync never pushes)"
  else
    echo "wb sync: $TASKS_DIR has DIVERGED from origin/$expected_branch ($ahead ahead, $behind behind) — refusing to auto-merge" >&2
    echo "wb sync: resolve by hand, e.g.:" >&2
    echo "  git -C \"$TASKS_DIR\" log --oneline HEAD..origin/$expected_branch    # see what's incoming" >&2
    echo "  git -C \"$TASKS_DIR\" log --oneline origin/$expected_branch..HEAD    # see what's local-only" >&2
    echo "  git -C \"$TASKS_DIR\" merge origin/$expected_branch                  # or: git -C \"$TASKS_DIR\" rebase origin/$expected_branch" >&2
    echo "wb sync: do NOT run 'git reset --hard origin/$expected_branch' (or force-push) to make this go away — that SILENTLY DISCARDS your local commits and is the exact anti-pattern this command exists to prevent" >&2
    exit 1
  fi
}

# ---------------------------------------------------------------------------
# wb unsafe-rewind — the ONLY sanctioned producer of the WB_ALLOW_REWIND
# sentinel a sibling git hook (tasks-git-hooks/, not touched here) consults
# before allowing a rewind-shaped operation (reset --hard, force-push, ...)
# against $TASKS_DIR. Deliberately interactive/explicit: it requires a
# non-empty reason and prints the sentinel's time-limited, one-time-use
# contract so the caller understands what they just unlocked. The TTL/
# one-use ENFORCEMENT itself lives in that hook, not here.
# ---------------------------------------------------------------------------

# cmd_unsafe_rewind "<reason>" — writes "<epoch> <reason>" to
# $TASKS_DIR/.git/WB_ALLOW_REWIND (relative to whatever $TASKS_DIR resolves
# to). Refuses with a usage error on a missing or empty reason — this is a
# rare, deliberate escape hatch, not something that should ever fire with a
# blank/placeholder reason.
cmd_unsafe_rewind() {
  local reason="$*"
  if [ -z "$reason" ]; then
    echo "wb unsafe-rewind: usage: wb unsafe-rewind \"<reason>\" — a non-empty reason is required" >&2
    exit 1
  fi

  local sentinel="$TASKS_DIR/.git/WB_ALLOW_REWIND"
  printf '%s %s\n' "$(date +%s)" "$reason" > "$sentinel"

  echo "wb unsafe-rewind: sentinel written to $sentinel"
  echo "wb unsafe-rewind: reason: $reason"
  echo "wb unsafe-rewind: this allows exactly ONE rewind-shaped git operation (e.g. reset --hard, a force-push) against $TASKS_DIR — the hook consumes/deletes the sentinel on first use, or once it goes stale (120s TTL), whichever comes first"
  echo "wb unsafe-rewind: if you don't run that operation within the next 120 seconds, re-run this command when you're actually ready"
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
  # WB_REVIEW_BUFFER=1 tells conform.nvim (nvim/.config/nvim/lua/plugins/
  # index.lua) to skip format-on-save for this one-shot checkbox-review pass
  # — the target file itself may be persistent (a central-store task file),
  # but the review pass is brief and shouldn't run Prettier over the whole
  # file. Same env-var-signal convention as WB_AUTO_RESTORE (wb.sh:265),
  # set unconditionally on both branches: a non-nvim $EDITOR just never
  # reads it, so no "is this nvim" guard is needed.
  if [ -n "${TMUX:-}" ]; then
    local chan="wb-buffer-done-$$-$RANDOM"
    tmux set -p -t "$TMUX_PANE" @claude_blocked nvim-buffer 2>/dev/null || true
    tmux split-window -h -t "$TMUX_PANE" "WB_REVIEW_BUFFER=1 nvim '$path'; tmux wait-for -S $chan"
    tmux wait-for "$chan"
    tmux set -pu -t "$TMUX_PANE" @claude_blocked 2>/dev/null || true
  else
    WB_REVIEW_BUFFER=1 "${EDITOR:-nvim}" "$path"
  fi
}

# wb_sweep_section <file> — print only the "## Sweep" section this run
# appended (if present). Keeper extraction must never read checklist-shaped
# lines from the task's own freeform Plan/Follow-ups/Decisions prose.
wb_sweep_section() {
  awk '/^## Sweep \(gitignored/ { found = 1 } found { print }' "$1"
}

# _wb_append_under_heading <file> <heading> <body> — the shared insertion
# algorithm behind both wb_append_handoff (below) and cmd_append (U4,
# `wb append`), extracted so there is exactly ONE heading-fallback/
# end-of-section insertion implementation in this file, parameterized on an
# arbitrary "## <heading>" name and an arbitrary — possibly multi-line —
# <body> block, rather than wb_append_handoff's original hardcoded
# "## Handoffs" + single-line-message shape. <body> is inserted VERBATIM
# (embedded newlines print as real line breaks); this helper only manages
# blank-line hygiene AROUND the block, never inside it — a caller wanting a
# blank line between two of its own body lines (wb_append_handoff's
# "entry heading, blank, message" shape) bakes that into <body> itself.
#
# Insertion rule (identical to wb_append_handoff's own pre-extraction
# behavior, and the missing-heading fallback handoff_append_followup
# (handoff.sh:84-116) established for "## Follow-ups"):
#   - "## <heading>" exists as a real heading (isHeadingLine() below — only
#     a line preceded by a blank line, or the file's first line, counts;
#     without this guard, heading-shaped TEXT inside another section's own
#     prose, e.g. a Plan paragraph quoting "## Decisions" as an example,
#     would exact-match and splice the entry mid-paragraph — confirmed live
#     before this guard existed) — the new <body> block lands at the END of
#     that section: immediately before whatever "## " heading comes next,
#     or at EOF if the section runs to the end of the file. NEVER right
#     after the heading line itself. Repeated calls therefore read
#     oldest-first — load-bearing for /wb-resume (not in scope here), which
#     needs to find the most recent rich entry reliably.
#   - "## <heading>" is missing entirely, but "## Decisions" exists as a
#     real heading — insert a fresh "## <heading>" section immediately
#     before it.
#   - Neither exists anywhere — append a fresh "## <heading>" section at
#     EOF.
_wb_append_under_heading() {
  local file="$1" heading="$2" body="$3"
  local target="## $heading"
  # Passed via ENVIRON, never `awk -v` -- POSIX awk's `-v var=value` runs C
  # escape-sequence processing on the assigned string, so a body containing
  # a literal `\b`/`\t`/etc. (exactly the kind of text this regex-quoting,
  # shell-adjacent codebase's own handoff notes routinely contain -- e.g.
  # "push\b force-flag") gets silently rewritten (`\b` -> a real backspace
  # byte) with no error anywhere in the chain. Reproduced live; confirmed
  # `ENVIRON["..."]` preserves the value byte-for-byte since env-var
  # assignment does no such processing.
  WB_APPEND_TARGET="$target" WB_APPEND_BODY="$body" awk '
    BEGIN { target = ENVIRON["WB_APPEND_TARGET"]; body = ENVIRON["WB_APPEND_BODY"] }
    function isHeadingLine() { return (prev == "" || NR == 1) }
    BEGIN { insection = 0; inserted = 0; prev = "" }
    $0 == target && isHeadingLine() { insection = 1 }
    # Leaving an existing target section (any other "## " heading reached
    # while inside it) — insert the body right here, at the end of that
    # section, before falling through to print the heading that closes it.
    # Excludes the target heading line itself (the very record that just
    # turned insection on above) so a fresh heading with content following
    # it does not immediately self-trigger this branch.
    insection && /^## / && $0 != target && !inserted && isHeadingLine() {
      if (prev != "") print ""
      print body; print ""
      inserted = 1; insection = 0
    }
    # Heading missing entirely, but "## Decisions" exists — insert a fresh
    # target section right before it (the same missing-heading insertion
    # point handoff_append_followup uses for its own heading).
    $0 == "## Decisions" && !insection && !inserted && isHeadingLine() {
      print target
      print ""
      print body
      print ""
      inserted = 1
    }
    { print; prev = $0 }
    END {
      if (insection && !inserted) {
        # Section existed but ran to EOF with no following heading.
        if (prev != "") print ""
        print body
      } else if (!inserted) {
        # Neither the target heading nor "## Decisions" found anywhere —
        # append a fresh section at EOF.
        if (prev != "") print ""
        print target
        print ""
        print body
      }
    }
  ' "$file" > "$file.tmp.$$" && mv "$file.tmp.$$" "$file"
}

# wb_append_handoff <task_file> <source> <message> — appends a terse,
# timestamped "### <timestamp> — <source> (auto)" entry (with <message> as
# its one-line body) to <task_file>'s "## Handoffs" section. A thin
# composer over _wb_append_under_heading (above): builds the "### ...
# (auto)" header line, joins it to <message> with a blank line between
# (the one piece of internal body formatting this caller wants that
# cmd_append's own callers, e.g. /wb-save's pre-formatted multi-line block,
# don't), then hands the whole thing off as one opaque <body> block.
#
# Called by cmd_pause/cmd_done/cmd_resume, always right after their own
# state-changing line — deliberately never from cmd_new itself: cmd_new is
# also the path every FRESH `wb new` takes, and a fresh task must not gain
# a Handoffs entry (only a resume of a previously paused/done task should).
wb_append_handoff() {
  local file="$1" source="$2" message="$3"
  local entry; entry="### $(date '+%Y-%m-%d %H:%M') — $source (auto)"
  local body; body="$entry"$'\n\n'"$message"
  _wb_append_under_heading "$file" "Handoffs" "$body"
}

# ---------------------------------------------------------------------------
# wb append — locked, heading-scoped text insertion for agent-mediated
# task-file writes (round-2 Decision 1B / W13-W14): the ONE way /wb-save,
# /handoff, and /parked-items are rewired (U4) to touch a task file's body
# instead of an Edit-tool write that bypasses every lock this plan built.
# ---------------------------------------------------------------------------

# _wb_append_resolve_task <query> — the file cmd_append should write into.
# Two-stage resolution:
#   1. Exact fast path: <query> already names a real file directly (as
#      given, or as "$TASKS_DIR/<query>", or "$TASKS_DIR/<query>.md") —
#      resolves to itself immediately, bypassing substring matching
#      entirely. This matters because every SKILL.md rewired in this unit
#      already computed the exact task-file path/ref before calling
#      `wb append` (wb-save's `@task` lookup, handoff's own wb_task_file
#      call) — those callers must never risk a FALSE ambiguity just
#      because their own task's name happens to be a literal substring of
#      a sibling task's name (e.g. "repo--foo" is a substring of
#      "repo--foo-bar"), which the fuzzy fallback below would otherwise hit.
#   2. Fuzzy fallback: the SAME case-insensitive substring-match-with-
#      ambiguity-guard convention cmd_resume already uses against every
#      task file's basename — 0 or 2+ matches both fail loudly rather than
#      guessing, never silently picking one.
_wb_append_resolve_task() {
  local query="${1:-}"
  [ -n "$query" ] || return 1

  if [ -f "$query" ]; then
    printf '%s\n' "$query"
    return 0
  fi
  if [ -f "$TASKS_DIR/$query" ]; then
    printf '%s\n' "$TASKS_DIR/$query"
    return 0
  fi
  if [ -f "$TASKS_DIR/$query.md" ]; then
    printf '%s\n' "$TASKS_DIR/$query.md"
    return 0
  fi

  _wb_resolve_task_fuzzy "$query" "wb append"
}

# cmd_append <task-ref> <heading> [<body>|-] — resolve <task-ref>
# (_wb_append_resolve_task, above), take the per-task lock
# (wb_task_lock_acquire_guarded, same convention every other cmd_* verb
# uses), insert <body> under "## <heading>" via _wb_append_under_heading,
# release. <body> is either:
#   - a single trailing argument — the short one-liner convenience; or
#   - omitted, or given literally as "-" — read the (possibly multi-line)
#     body from stdin instead, heredoc-friendly:
#       wb append <task-ref> Handoffs <<'EOF'
#       ### 2026-07-11 18:42 — wb-save
#       **Done:** ...
#       **In flight:** ...
#       **Next:** ...
#       EOF
# This is W13's capability floor: /wb-save's ###-timestamped, three-field
# block entries need the multi-line stdin form (its own skill contract
# forbids wb_append_handoff's single-line-message shape); a terse one-off
# note fits the trailing-argument form.
cmd_append() {
  local query="${1:-}" heading="${2:-}"
  if [ -z "$query" ] || [ -z "$heading" ]; then
    echo "usage: wb append <task-ref> <heading> [<body>|-]   (body omitted or '-' reads multi-line stdin)" >&2
    exit 1
  fi

  local body
  if [ $# -lt 3 ] || [ "$3" = "-" ]; then
    body="$(cat)"
  else
    body="$3"
  fi
  [ -n "$body" ] || { echo "wb append: empty body — nothing to append" >&2; exit 1; }

  local file
  file="$(_wb_append_resolve_task "$query")" || exit 1

  _wb_lock_trap_append_if_top_level wb_task_lock_release_all
  wb_task_lock_acquire_guarded "$file" || exit $?
  _wb_append_under_heading "$file" "$heading" "$body"
  wb_task_lock_release "$file"
  echo "wb append: appended under \"## $heading\" in $(basename -- "$file")"
}

# ---------------------------------------------------------------------------
# wb install-hooks — the one idempotent verb that wires up everything the
# concurrency-safety machine needs on this host: points $TASKS_DIR's
# core.hooksPath at U6's reference-transaction hook (stowed path — a real
# checkout of $TASKS_DIR needs to actually find the file at runtime, not a
# dotfiles-repo-relative path), hardens gc/reflog retention (X5) so a
# sentinel-blessed rewind stays recoverable by policy rather than GC luck,
# pre-creates the git-hook kill-switch (X4) unless the X7 replay tool has
# already recorded an accepting run, and VERIFIES (never edits — Decision
# 4A) the live ~/.claude/settings.json's PreToolUse entry against the
# tracked reference copy in claude/.claude/settings.recommended.json.
# ---------------------------------------------------------------------------

# cmd_install_hooks — no arguments. Every step is safe to re-run: git config
# writes are naturally idempotent for a single value, the switch file is
# only ever created when both the replay marker is absent AND it isn't
# already there, and the settings check only ever reads.
cmd_install_hooks() {
  local hooks_dir="$HOME/.config/scripts/tmux/tasks-git-hooks"
  local reflog_span="180 days"   # generous — months, not days; git's own
                                  # defaults are 90/30 days, both unset on a
                                  # real $TASKS_DIR as of 2026-07-11.
  local changed=0

  # 1. core.hooksPath -> the STOWED path (matches
  # settings.recommended.json's own $HOME-based PreToolUse command path),
  # not a dotfiles-repo-relative one.
  local cur
  cur="$(git -C "$TASKS_DIR" config --get core.hooksPath 2>/dev/null || true)"
  [ "$cur" = "$hooks_dir" ] || changed=1
  git -C "$TASKS_DIR" config core.hooksPath "$hooks_dir"

  # 2. X5 gc/reflog hardening.
  cur="$(git -C "$TASKS_DIR" config --get gc.auto 2>/dev/null || true)"
  [ "$cur" = "0" ] || changed=1
  git -C "$TASKS_DIR" config gc.auto 0

  cur="$(git -C "$TASKS_DIR" config --get gc.reflogExpire 2>/dev/null || true)"
  [ "$cur" = "$reflog_span" ] || changed=1
  git -C "$TASKS_DIR" config gc.reflogExpire "$reflog_span"

  cur="$(git -C "$TASKS_DIR" config --get gc.reflogExpireUnreachable 2>/dev/null || true)"
  [ "$cur" = "$reflog_span" ] || changed=1
  git -C "$TASKS_DIR" config gc.reflogExpireUnreachable "$reflog_span"

  # 3. X4 kill-switch: pre-create disable-git-hook UNLESS the X7 replay
  # tool has already left its replay-passed marker — checked FIRST, every
  # run, so an idempotent re-run after a human deliberately enabled the
  # hook (rm'd the switch post-replay) never silently re-disables it. Never
  # remove an existing switch file here — that's the replay tool's/
  # operator's job elsewhere, not this verb's.
  local state_home="${XDG_STATE_HOME:-$HOME/.local/state}"
  local wb_state_dir="$state_home/wb"
  local replay_marker="$wb_state_dir/replay-passed"
  local switch_file="$wb_state_dir/disable-git-hook"
  local switch_msg
  if [ -e "$replay_marker" ]; then
    switch_msg="replay-passed marker present — git-hook switch file left as-is"
  else
    mkdir -p "$wb_state_dir"
    if [ -e "$switch_file" ]; then
      switch_msg="git-hook switch file already present (still dormant)"
    else
      : > "$switch_file"
      changed=1
      switch_msg="git-hook switch file created (hook installed but dormant until the X7 replay passes)"
    fi
  fi

  # 4. X3 settings verification — read-only against the LIVE file; the
  # reference block lives in the tracked settings.recommended.json,
  # resolved via wb.sh's own on-disk location (mirrors cmd_board --html's
  # dotfiles_root resolution) rather than assuming dotfiles is checked out
  # literally at $CODE_DIR/dotfiles.
  local dotfiles_root
  dotfiles_root="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel 2>/dev/null)" || true
  [ -n "$dotfiles_root" ] || dotfiles_root="$CODE_DIR/dotfiles"
  local recommended="$dotfiles_root/claude/.claude/settings.recommended.json"
  local live="$HOME/.claude/settings.json"
  local settings_msg

  if [ ! -f "$recommended" ]; then
    settings_msg="reference settings.recommended.json not found at $recommended — cannot verify"
  else
    local present=false
    if [ -f "$live" ] && jq -e '
        (.hooks.PreToolUse // [])
        | any(.[]; (.hooks // []) | any(.[]; (.command // "") | contains("tasks-git-hooks/pretooluse-guard.sh")))
      ' "$live" >/dev/null 2>&1; then
      present=true
    fi

    if [ "$present" = true ]; then
      settings_msg="already configured — $live's hooks.PreToolUse already has the pretooluse-guard.sh entry"
    else
      echo "wb install-hooks: $live is missing the pretooluse-guard.sh PreToolUse entry."
      echo "wb install-hooks: paste this into ~/.claude/settings.json's top-level object (merge by hand — this is reference only, never auto-merged):"
      echo
      jq '{hooks: .hooks}' "$recommended"
      echo
      echo "wb install-hooks: after pasting, RESTART every already-running Claude Code session — hook config is snapshotted at session start (X6), so a session already running won't pick this up until it's restarted, in addition to any brand-new session started after the paste."
      settings_msg="missing — paste-block + restart reminder printed above"
    fi
  fi

  # 5. Final one-line summary, matching this codebase's terse
  # `echo "wb <verb>: ..."` convention.
  if [ "$changed" -eq 0 ]; then
    echo "wb install-hooks: already installed, nothing to do (hooksPath=$hooks_dir; gc.auto=0, reflogExpire/reflogExpireUnreachable=$reflog_span; $switch_msg); settings check: $settings_msg"
  else
    echo "wb install-hooks: installed (hooksPath=$hooks_dir; gc.auto=0, reflogExpire/reflogExpireUnreachable=$reflog_span; $switch_msg); settings check: $settings_msg"
  fi
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
    dotfiles_root="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel 2>/dev/null)" || true
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

  # KTD7's store-only close: <session> matching no LIVE tmux session at all
  # is resolved as a task-file stem instead — a session-less parent (the
  # whole point of wb-breakdown's family split) never had a session for
  # @wb_repo/@wb_slug to be missing FROM; there's simply nothing to attach
  # to. This is also the exact path KTD8's printed last-child nudge
  # ("wb done <parent-stem>") depends on to actually work.
  local task_file store_only=0
  if tmux has-session -t "=$session" 2>/dev/null; then
    # @task-first resolution (KTD7) — @wb_repo/@wb_slug stay intentionally
    # stale on a migrated continuing session (its OWN git identity never
    # changes, only which task file owns it), so trusting them here would
    # act on the wrong file post-migration. wb_session_task_file falls back
    # to today's @wb_repo/@wb_slug derivation byte-for-byte when @task isn't
    # set — every session that predates this feature.
    task_file="$(wb_session_task_file "$session")" \
      || { echo "wb done: $session has no @wb_repo/@wb_slug — not a wb task session" >&2; exit 1; }
    [ -f "$task_file" ] || { echo "wb done: no task file for $session ($task_file)" >&2; exit 1; }
  else
    task_file="$TASKS_DIR/$session.md"
    [ -f "$task_file" ] \
      || { echo "wb done: '$session' matches no live tmux session and no task file in $TASKS_DIR" >&2; exit 1; }
    store_only=1
  fi

  local task_stem; task_stem="$(basename "$task_file" .md)"
  _wb_lock_trap_append_if_top_level wb_task_lock_release_all

  local repo_dir worktree_path
  if [ "$store_only" = 0 ]; then
    # Derived from the TASK FILE's own frontmatter, never from
    # @wb_repo/@wb_slug directly — a migrated child's worktree:/branch: are
    # its OWN (received from the parent during migration), and a
    # store-only parent has neither to derive from in the first place.
    local repo worktree_rel slug
    repo="$(wb_get_frontmatter "$task_file" repo)"
    slug="$(wb_get_frontmatter "$task_file" branch)"
    worktree_rel="$(wb_get_frontmatter "$task_file" worktree)"
    [ -n "$worktree_rel" ] || worktree_rel=".worktrees/$slug"
    repo_dir="$CODE_DIR/$repo"
    worktree_path="$repo_dir/$worktree_rel"

    # Worktree drift guard (KTD7): worktree: is SET but doesn't exist, while
    # the ordinary .worktrees/$slug derivation DOES — never guess which one
    # is right (tearing down against the wrong target destroys real work).
    if [ -n "$(wb_get_frontmatter "$task_file" worktree)" ] \
       && [ ! -d "$worktree_path" ] \
       && [ -d "$repo_dir/.worktrees/$slug" ]; then
      echo "wb done: $task_file's worktree: ($worktree_rel) doesn't exist, but $repo_dir/.worktrees/$slug does — refusing to guess which is right; fix the drift by hand" >&2
      exit 1
    fi

    # 1. fail fast — never mutate anything on a dirty tree.
    _wb_git_dirty_guard "$worktree_path" "wb done"
  fi

  # Steps 2-3 (Sweep review buffer + worktree removal) are meaningless for a
  # store-only close — a session-less parent never had a worktree to sweep
  # or remove (KTD7: "no sweep, worktree, or session teardown"). Only the
  # shared status/closed/Handoffs burst below applies to it.
  if [ "$store_only" = 0 ]; then

  # 2. review buffer — the task file itself IS the buffer (it already lives
  # centrally and survives `git worktree remove`, so there's no copy to sync
  # back). Append a throwaway ## Sweep section listing every gitignored file
  # `git worktree remove` would otherwise silently destroy; `- [x] keep` marks
  # survivors, same convention as decision-buffer.
  local ignored
  ignored="$(git -C "$worktree_path" status --porcelain --ignored 2>/dev/null \
    | awk '$1 == "!!" { $1 = ""; sub(/^ /, ""); print }' || true)"
  if [ -n "$ignored" ]; then
    # Burst 1: Sweep-section append — release BEFORE wb_open_buffer (the
    # operator's interactive, human-supervised, minutes-long nvim session).
    # A critical section must never span it (W5, round-2 Decision 2).
    wb_task_lock_acquire_guarded "$task_file" || exit $?
    {
      echo
      echo "## Sweep (gitignored — check keep before closing; git worktree remove destroys the rest)"
      echo
      while IFS= read -r f; do
        echo "- [ ] keep $f"
      done <<< "$ignored"
    } >> "$task_file"
    wb_task_lock_release "$task_file"

    wb_open_buffer "$task_file"

    local dossier="$TASKS_DIR/dossiers/$task_stem"
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

    # Burst 2: post-buffer Sweep-strip + kept-notes append — its own,
    # separate lock burst, acquired only now (after the unlocked buffer
    # session above has closed), released again before anything below it.
    wb_task_lock_acquire_guarded "$task_file" || exit $?
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
    wb_task_lock_release "$task_file"
  else
    # No ignored files -> burst 1 never happened, nothing was written yet —
    # nothing to lock before the buffer here; go straight to it.
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

  fi   # store_only == 0 (steps 2-3)

  # Burst 3 (shared): final status/closed stamps + Handoffs entry — its own
  # lock burst, acquired only now, AFTER the (unlocked) worktree removal
  # above. `git worktree remove` is a slow-ish external operation and isn't
  # a task-FILE write at all, so it must never happen while the lock is
  # held. Applies to both paths — a store-only close still needs its own
  # status/closed/handoff burst (KTD7/KTD8: the printed nudge names a
  # parent that must actually flip to done when someone acts on it).
  wb_task_lock_acquire_guarded "$task_file" || exit $?
  wb_set_frontmatter "$task_file" status done
  wb_set_frontmatter "$task_file" closed "$(date +%F)"
  wb_append_handoff "$task_file" "wb done" 'Session closed via `wb done`.'
  wb_task_lock_release "$task_file"

  if [ "$store_only" = 1 ]; then
    echo "wb done: $task_file closed (store-only — no live session or worktree to tear down)"
  else
    echo "wb done: $session closed — worktree removed, task -> done ($task_file)"
  fi

  local total=$(( $(wb_followup_count) + $(wb_parked_count) ))
  if [ "$total" -ge "$WB_SWEEP_THRESHOLD" ]; then
    echo "wb done: $(wb_pending_counts) — consider running /parked-items"
  fi

  # --close is opt-in, not a revert of the wb-pause-era decision above: the
  # session survives by default, and only this explicit flag reaches for
  # the kill. Best-effort (|| true) — by this point the state that matters
  # (worktree removed, status flipped) is already done and echoed, so a
  # racing/already-gone session must not abort the script under set -e.
  # Store-only has no session to kill in the first place.
  [ "$store_only" = 0 ] && [ "$close" -eq 1 ] && tmux kill-session -t "=$session" 2>/dev/null || true
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
  local session="$1" repo slug task_file branch label statuscol kind ref slug_out=""
  repo="$(tmux show -t "=$session:" -v @wb_repo 2>/dev/null || true)"
  slug="$(tmux show -t "=$session:" -v @wb_slug 2>/dev/null || true)"
  if [ -n "$repo" ] && [ -n "$slug" ]; then
    # @task-first (KTD7): @wb_repo/@wb_slug alone would re-derive the
    # PARENT's file on a migrated session (apply re-points @task, never
    # these two) — repo/slug_out below stay the session's own real git
    # identity regardless; only which task file drives the row's title/
    # branch/ref changes.
    task_file="$(wb_session_task_file "$session")"
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
    breakdown)   shift; cmd_breakdown "$@" ;;
    board)       shift; cmd_board "$@" ;;
    done)        shift; cmd_done "$@" ;;
    pause)       shift; cmd_pause "$@" ;;
    reviewed)    shift; cmd_reviewed "$@" ;;
    sync)          shift; cmd_sync "$@" ;;
    unsafe-rewind) shift; cmd_unsafe_rewind "$@" ;;
    append)      shift; cmd_append "$@" ;;
    install-hooks) shift; cmd_install_hooks "$@" ;;
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
