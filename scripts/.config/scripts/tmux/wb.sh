#!/usr/bin/env bash
# wb (workbench) — session-per-worktree + the unified picker.
#   wb new [--agent] <slug>          from inside a repo
#   wb new [--agent] <repo> <slug>   from anywhere (a task file's pre-set branch: is adopted as
#                                    the git branch; the worktree dir stays slug-named)
#   wb new --planned <repo> <slug>   seed a worktree-less task file only (status stays
#                                    planned) — no worktree, no tmux session; the
#                                    locked creation path agent-mediated skills use
#   wb new --prospective <repo> <slug>
#                                    same worktree-less/session-less path as --planned,
#                                    but status: prospective (captured, not yet judged
#                                    as work) — /park's work-shaped capture path
#   wb new --planned|--prospective [--jira <url>] [--title <text>] [--body -|--body-file <path>] ...
#                                    --body - reads the ## Plan body from stdin, --body-file
#                                    <path> from a file (mutually exclusive, planned/
#                                    prospective only; new files only). Without one of them
#                                    stdin is never read.
#   wb                               the picker (replaces s + ca)
#   wb help                          this verb list (also --help/-h); any other unknown
#                                    token exits 2 rather than opening the picker
#   wb board                         task-store status table (interim /board); --html writes the
#                                    ratified 3-view page to logs/board.html (feat-board-build)
#   wb done [--close] [--leave-shelved] [<session>]
#                                    safe wind-down (defaults to the current session); --close also kills the tmux
#                                    session; refuses while shelved decision drafts (wb-capture) of the task
#                                    remain unless --leave-shelved
#   wb resume <task>                 recreate a closed/gone worktree+session from its task file
#   wb down [<session>]              close a session, keep the worktree — activity only, status
#                                    untouched except -> review when the branch has an open PR
#   wb pause [<session>]             shelve a task on purpose: status -> paused, then `wb down`
#   wb status <task-ref> <prospective|planned|paused|doing|review>
#                                    set a store-only task's status: field directly, under the
#                                    per-task lock — refuses when a live session's @task already
#                                    points at it (use wb pause/wb down from that session instead)
#   wb set <task-ref> <field> <value|--unset>
#                                    set one board-metadata frontmatter field on a store-only
#                                    task, under the per-task lock — same live-session refusal
#                                    as wb status; status/created/closed/reviewed/claude_sessions/
#                                    repo/worktree are refused (use their own verb instead)
#                                    fields: @@WB_SET_FIELDS@@
#   wb pr-open [<session>]           exit 0 if the session's branch has an open PR, 1 otherwise
#   wb reviewed [<session>]          stamp a task's reviewed: field (marks /ce-code-review done)
#   wb task-file [--edit]            print the current session's task file path (via @task);
#                                    --edit opens it in $EDITOR instead (what prefix+t runs)
#   wb jira-set <repo>--<slug> <url> stamp a created Jira ticket URL into a task's jira: field
#                                    (locked, idempotent-or-refuse) — the /wb-jira-create emit
#                                    flow's only task-store write; never re-derives the URL
#   wb reconcile                     report task-store/git worktree drift (detection only, read-only)
#   wb reconcile --machine           the same drift, as parseable TSV (read-only) — the
#                                    fifth field's meaning differs by kind (orphan: merge
#                                    status; missing: task-file path), see wb_reconcile_collect;
#                                    duplicate rows (see wb_reconcile_collect_duplicates)
#                                    follow the orphan/missing rows
#   wb breakdown --apply <buffer>    execute an approved /wb-breakdown proposal buffer:
#                                    create the children, migrate the worktree, move
#                                    follow-ups — the feature's only task-store write path
#   wb unsafe-rewind "<reason>"      write a time-limited escape-hatch sentinel a git hook honors for a deliberate rewind
#   wb append <task> <heading> [<body>|-]
#                                    append <body> under "## <heading>" in <task>'s file,
#                                    taking the per-task lock (fail-loud on an ambiguous
#                                    or unmatched <task>); <body> omitted or literally
#                                    "-" reads a multi-line body from stdin instead — the
#                                    agent-mediated write path /wb-save, /handoff, and
#                                    /weekly-review use instead of Edit-tool task writes
#   wb family <task> [--sessions|--reseed|--concepts]
#                                    print <task>'s family stems (top parent first, then every
#                                    descendant), read-only and tmux-free; --sessions prints
#                                    stem<TAB>session<TAB>title per live session working on one
#                                    (matched by @task, else session name); --reseed rewrites the
#                                    CLAUDE.local.md concepts pointer in each family worktree;
#                                    --concepts prints <task>'s CONCEPTS.md files, nearest first
#   wb week path                     print the standing weekly-capture doc's path,
#                                    creating it from the four-section template
#                                    (What's working|What's not working|New ideas|Notes)
#                                    when absent
#   wb week append <section> <body>  append <body>, stamped with date/repo/branch and
#                                    an unreviewed marker, under one of the capture
#                                    doc's four sections
#   wb week record [<iso>]           mint (idempotently) $TASKS_DIR/weeks/<iso>-review.md
#                                    (default: the current ISO week), rolling up every
#                                    unreviewed capture entry and marking it reviewed
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
# shellcheck source=wb-board.sh
source "$SCRIPT_DIR/wb-board.sh"

TASKS_DIR="${TASKS_DIR:-$HOME/code/tasks}"
CODE_DIR="${CODE_DIR:-$HOME/code}"
WB_SWEEP_THRESHOLD="${WB_SWEEP_THRESHOLD:-5}"   # follow-ups+parked count that triggers the nudge
# Same default the claude() wrapper (zsh/.zshrc) warns at — set once here so
# wb.sh's own displays (picker header, wb board) can't drift to a different
# fallback than the three call sites below used to inline separately.
WB_AGENT_WARN_AT="${WB_AGENT_WARN_AT:-8}"

# Picker column widths — shared between wb_format_for_display's padding and
# wb_column_header's labels. Keep these in sync or the legend row drifts
# from the data rows under it.
# Columns: REPO (repo/location) · NAME (task title or session/repo name;
# takes whatever width is left, see wb_picker_name_width) · BRANCH (the git
# branch, when there is one; a long one shows its tail) · AGE (time since
# Jet last visited the session). Status is no longer a column: it is the
# colour of the NAME cell.
WB_COL_REPO=16
WB_COL_BRANCH=12
WB_COL_AGE=4

# ---------------------------------------------------------------------------
# Frontmatter helpers — the store's schema is plain `key: value` lines between
# the first two `---` markers (see ~/code/tasks/README.md).
# ---------------------------------------------------------------------------

# wb_get_frontmatter_text <key> — same extraction as wb_get_frontmatter, but
# reads the frontmatter-bearing content from stdin instead of a file path —
# for a kept-branch `git show <branch>:<path>` blob, which has no path on
# disk to hand a file-based reader (wb-lifecycle.sh's kept-branch fallback,
# R6/R8).
wb_get_frontmatter_text() {
  awk -v key="$1" '
    BEGIN { infm = 0 }
    # frontmatter opens only on line 1 (like the duplicate scan); a task file
    # with no frontmatter but a body --- rule must read as having none
    NR == 1 && $0 != "---" { exit }
    /^---$/ { infm++; if (infm == 2) exit; next }
    infm == 1 && $0 ~ "^" key ":" { sub("^" key ":[ \t]*", ""); print; exit }
  '
}

# wb_get_frontmatter <file> <key> — print a single frontmatter value (blank if unset).
wb_get_frontmatter() {
  wb_get_frontmatter_text "$2" < "$1"
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

# wb_set_frontmatter_field <file> <key> <value> [<after_key>] — the
# comment-preserving sibling of wb_set_frontmatter above: overwrite <key>'s
# frontmatter line in place, keeping any trailing inline "# ..." comment
# that line already carries (TEMPLATE.md/README.md's own `key: val  # note`
# shape). When <key> has no existing line ANYWHERE in the frontmatter
# block, insert it right after <after_key>'s line when given and present
# in the file, otherwise just before the closing `---` — same default-
# insertion point as wb_set_frontmatter. Two-pass: first a whole-block scan
# decides whether <key> already exists (so an insertion point that happens
# to come BEFORE the key's real line — e.g. `after_key=size` on
# TEMPLATE.md, where `priority:` ships its own empty line further down —
# never fires and produces a duplicate); if it exists, the FIRST occurrence
# is replaced in place (comment preserved) and every further occurrence in
# the block is dropped (self-healing dedupe for files a prior buggy run
# already duplicated). Extracted from cmd_status's original inline awk (the
# ONE comment-preserving frontmatter rewrite); shared by cmd_status
# (status:, never needs after_key — the key always exists) and cmd_set
# (priority:/value:/size:/parent:/depends_on:/jira:/pr:/tags:/path:, some of
# which land after size: or jira: on a pre-schema task file that predates them).
# _wb_refuse_if_live_session <task-file> <verb> — exit 1 when any live tmux
# session's @task points at <task-file>. Store-only verbs (wb status, wb set)
# share this so the refusal text and scan never drift between them.
_wb_refuse_if_live_session() {
  local file="$1" verb="$2" session cur
  while IFS= read -r session; do
    [ -n "$session" ] || continue
    cur="$(tmux show -t "=$session:" -v @task 2>/dev/null || true)"
    [ "$cur" = "$file" ] || continue
    echo "$verb: $(basename -- "$file") has a live session $session — use wb pause/wb down from that session" >&2
    exit 1
  done < <(tmux list-sessions -F '#{session_name}' 2>/dev/null || true)
}

# _wb_frontmatter_value_ok <verb> <field> <value> — fail loud on a value that
# cannot round-trip through a one-line frontmatter field: an embedded
# newline/CR would inject a second `key: value` line (a status: flip smuggled
# through `wb set tags`), and whitespace+'#' is read as a trailing comment by
# every reader (clip()), so the store would silently disagree with what
# `wb set` echoed back.
_wb_frontmatter_value_ok() {
  local verb="$1" field="$2" value="$3"
  case "$value" in
    *$'\n'*|*$'\r'*)
      echo "$verb: $field value must be a single line (embedded newline)" >&2
      return 1 ;;
  esac
  if printf '%s' "$value" | grep -qE '[[:space:]]#'; then
    echo "$verb: $field value must not contain whitespace followed by '#' (read as a comment by every reader)" >&2
    return 1
  fi
  return 0
}

wb_set_frontmatter_field() {
  local file="$1" key="$2" value="$3" after_key="${4:-}"
  # `val` goes through ENVIRON, never `awk -v` — awk -v applies C
  # escape-sequence processing to the assigned string, so a free-text
  # value containing the literal two-character sequence `\n` is silently
  # decoded into a REAL newline byte at assignment time. That happens
  # BEFORE `_wb_frontmatter_value_ok`'s embedded-real-newline check ever
  # runs (that check inspects the raw argv, which still only has `\`+`n`,
  # two ordinary characters) — so a value like `urgent\nstatus: pwned`
  # sails through validation and then injects a second frontmatter line.
  # Same reasoning as `_wb_append_under_heading`'s own ENVIRON use.
  # `key`/`after` stay on `-v`: both are always one of a small fixed set
  # of internal field names (never caller-composed free text), so they
  # carry none of this risk.
  WB_SET_FM_VALUE="$value" awk -v key="$key" -v after="$after_key" '
    BEGIN { val = ENVIRON["WB_SET_FM_VALUE"] }
    {
      n++
      lines[n] = $0
      if ($0 ~ /^---$/) {
        infm++
        if (infm == 1) fmstart = n
        else if (infm == 2 && fmend == 0) fmend = n
      }
    }
    END {
      exists = 0; firstidx = 0
      for (i = fmstart + 1; i < fmend; i++) {
        if (lines[i] ~ ("^" key ":")) {
          exists++
          if (firstidx == 0) firstidx = i
        }
      }
      inserted = 0
      for (i = 1; i <= n; i++) {
        line = lines[i]
        if (i > fmstart && i < fmend && line ~ ("^" key ":")) {
          if (i == firstidx) {
            comment = ""
            if (match(line, /[ \t]+#.*$/)) { comment = substr(line, RSTART) }
            print key ": " val comment
          }
          continue   # drop every further duplicate occurrence
        }
        if (!exists && !inserted && i > fmstart && i < fmend && after != "" && line ~ ("^" after ":")) {
          print line
          print key ": " val
          inserted = 1
          continue
        }
        if (!exists && !inserted && i == fmend) {
          print key ": " val
          inserted = 1
        }
        print line
      }
    }
  ' "$file" > "$file.tmp.$$" && mv "$file.tmp.$$" "$file"
}

# wb_read_task <file> — print "status\trepo\tworktree\tbranch\tpath\t
# depends_on\treviewed\tclaude_sessions" in one pass (used by the picker's
# row collection, which reads every task file on each refresh, and by the
# board pre-pass — board-display-v2's KTD-1 extends this rather than adding
# three more per-field wb_get_frontmatter reads per task). claude_sessions
# (U2) is appended as an 8th field, never inserted mid-row — every existing
# caller destructures fields 1-7 by position and would silently shift if a
# new field landed anywhere else.
wb_read_task() {
  awk '
    # clip() strips a trailing inline comment ("value  # note") plus edge
    # whitespace — TEMPLATE.md itself ships "status: doing  # planned|..."
    # so any seeded task carries one, and an uncomment-stripped status
    # breaks every consumer that compares it (board rank, picker column).
    function clip(s) { sub(/[ \t]+#.*$/, "", s); sub(/[ \t]+$/, "", s); return s }
    BEGIN { infm = 0; status = ""; repo = ""; worktree = ""; branch = ""; path = ""; deps = ""; reviewed = ""; sessions = "" }
    /^---$/ { infm++; if (infm == 2) exit; next }
    infm == 1 && /^status:/          { s = $0; sub(/^status:[ \t]*/,          "", s); status   = clip(s) }
    infm == 1 && /^repo:/            { s = $0; sub(/^repo:[ \t]*/,            "", s); repo     = clip(s) }
    infm == 1 && /^worktree:/        { s = $0; sub(/^worktree:[ \t]*/,        "", s); worktree = clip(s) }
    infm == 1 && /^branch:/          { s = $0; sub(/^branch:[ \t]*/,          "", s); branch   = clip(s) }
    infm == 1 && /^path:/            { s = $0; sub(/^path:[ \t]*/,            "", s); path     = clip(s) }
    infm == 1 && /^depends_on:/      { s = $0; sub(/^depends_on:[ \t]*/,      "", s); deps     = clip(s) }
    infm == 1 && /^reviewed:/        { s = $0; sub(/^reviewed:[ \t]*/,        "", s); reviewed = clip(s) }
    infm == 1 && /^claude_sessions:/ { s = $0; sub(/^claude_sessions:[ \t]*/, "", s); sessions = clip(s) }
    END { printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n", status, repo, worktree, branch, path, deps, reviewed, sessions }
  ' "$1"
}

# wb_read_tasks_batch <file>... — same fields as wb_read_task, for many
# files in ONE awk process instead of one process per file (each row is
# prefixed with its own source path, since a multi-file run has no other
# way to tell rows apart). Exists for scan-the-whole-store callers like
# collect_dormant_rows, where forking a fresh awk per task file — cheap in
# isolation — dominates real wall-clock once the store has hundreds of them.
wb_read_tasks_batch() {
  awk '
    function clip(s) { sub(/[ \t]+#.*$/, "", s); sub(/[ \t]+$/, "", s); return s }
    function emit() {
      printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n", \
        file, status, repo, worktree, branch, path, deps, reviewed, sessions
    }
    FNR == 1 {
      if (NR > 1) emit()
      file = FILENAME; infm = 0; done = 0
      status = ""; repo = ""; worktree = ""; branch = ""; path = ""; deps = ""; reviewed = ""; sessions = ""
    }
    done { next }
    /^---$/ { infm++; if (infm == 2) done = 1; next }
    infm == 1 && /^status:/          { s = $0; sub(/^status:[ \t]*/,          "", s); status   = clip(s) }
    infm == 1 && /^repo:/            { s = $0; sub(/^repo:[ \t]*/,            "", s); repo     = clip(s) }
    infm == 1 && /^worktree:/        { s = $0; sub(/^worktree:[ \t]*/,        "", s); worktree = clip(s) }
    infm == 1 && /^branch:/          { s = $0; sub(/^branch:[ \t]*/,          "", s); branch   = clip(s) }
    infm == 1 && /^path:/            { s = $0; sub(/^path:[ \t]*/,            "", s); path     = clip(s) }
    infm == 1 && /^depends_on:/      { s = $0; sub(/^depends_on:[ \t]*/,      "", s); deps     = clip(s) }
    infm == 1 && /^reviewed:/        { s = $0; sub(/^reviewed:[ \t]*/,        "", s); reviewed = clip(s) }
    infm == 1 && /^claude_sessions:/ { s = $0; sub(/^claude_sessions:[ \t]*/, "", s); sessions = clip(s) }
    END { emit() }
  ' "$@"
}

# wb_task_title <file> — the first `# ` heading, or empty if none.
wb_task_title() {
  awk '/^# / { sub(/^# /, ""); print; exit }' "$1"
}

# wb_task_file <repo> <disp_slug> — the store path for a repo+slug pair.
wb_task_file() { printf '%s/%s--%s.md\n' "$TASKS_DIR" "$1" "$2"; }

# wb_task_files — every real task file in the store (excludes README/TEMPLATE,
# RECOVERY-NOTES-2026-07-10.md -- incident documentation, not a task, left in
# $TASKS_DIR itself rather than a subdirectory -- and the dossiers/ directory
# used by wb done's keeper sweep).
wb_task_files() {
  local f base
  for f in "$TASKS_DIR"/*.md; do
    [ -f "$f" ] || continue
    # Parameter expansion, not `$(basename "$f")` — this loop runs once per
    # task file in the store (hundreds, and growing), so a subshell fork
    # per file just to check the basename adds up fast. Same output, no forks.
    base="${f##*/}"
    case "$base" in
      TEMPLATE.md|README.md|RECOVERY-NOTES-2026-07-10.md) continue ;;
    esac
    echo "$f"
  done
}

# ---------------------------------------------------------------------------
# Claude transcript store (U2) — the activity axis's real source of truth.
# Claude Code keeps one .jsonl file per conversation under
# ~/.claude/projects/<encoded-cwd>/, where the encoding is the absolute cwd
# with every "/" replaced by "-". A wb task's worktree IS that cwd, so
# "does this worktree have transcripts" and "how recently was it touched"
# answer both halves of "is this task warm" (KTD1/KTD2) with zero writes of
# our own — no hook state, no sidecar, nothing to go stale except by
# Claude's own retention window (cleanupPeriodDays, default 30 days). File
# mtime is good enough for that age, but not for picking WHICH conversation
# to resume: on shutdown Claude Code appends bookkeeping lines to every
# transcript the dying process touched (the live one and the pre-/clear
# ones), so after a mass kill they share one mtime second (wb_resume_id
# ranks by in-file timestamp instead). The
# claude_sessions: frontmatter field is a snapshot for the board/record
# only (wb_sessions_snapshot, near cmd_down) — it is never consulted here.
# ---------------------------------------------------------------------------

# wb_transcript_dir <worktree_abs> — the directory Claude Code stores
# <worktree_abs>'s conversations under. Claude Code's own encoding replaces
# every "/" AND "." with "-" (verified against this very worktree: path
# .../dotfiles/.worktrees/<slug> encodes to .../dotfiles--worktrees-<slug>,
# not .../dotfiles-.worktrees-<slug> — the "/." pair collapses to "--", not
# "-."). Override CLAUDE_PROJECTS_DIR in tests to point this at a fixture
# root instead of the real ~/.claude/projects.
wb_transcript_dir() {
  printf '%s/%s\n' "${CLAUDE_PROJECTS_DIR:-$HOME/.claude/projects}" "$(printf '%s' "$1" | tr './' '--')"
}

# wb_transcripts <worktree_abs> — "<id>\t<mtime-epoch>" per conversation
# recorded for <worktree_abs>, newest mtime first (an age signal only — see
# wb_resume_id for why mtime can't pick the resume target). Empty output
# (exit 0, not an error) when the directory doesn't exist or holds no
# transcripts — "no transcripts" is the cold/dormant boundary, not a
# failure. Reads only *.jsonl directly under the directory — Claude Code
# also nests a same-named subagent-transcript subdirectory per session
# there, which this deliberately ignores (a subagent run is not a resumable
# top-level conversation).
wb_transcripts() {
  local dir; dir="$(wb_transcript_dir "$1")"
  [ -d "$dir" ] || return 0
  local -a files=("$dir"/*.jsonl)
  [ -e "${files[0]}" ] || return 0
  # One `stat` call covering every file, not one fork per file (this is
  # called once per dormant-row candidate — collect_dormant_rows alone can
  # call it dozens of times per picker render/tab-switch) — same output
  # (id, mtime, newest-first), just without an O(n) fork cost to get there.
  local mtime path id
  while IFS=$'\t' read -r mtime path; do
    id="${path##*/}"; id="${id%.jsonl}"
    printf '%s\t%s\n' "$id" "$mtime"
  done < <(stat -c $'%Y\t%n' "${files[@]}" 2>/dev/null) | sort -t $'\t' -k2,2nr
}

# wb_transcript_rank_key <path> <mtime-epoch> — when <path>'s conversation
# last had real activity: the "timestamp" of its last activity line (one
# starting {"parentUuid":, i.e. a user/assistant/system/attachment turn) in
# the final 256 KiB. Bookkeeping lines start {"type": and are skipped —
# some (frame-link, queue-operation) get crash-time timestamps written into
# conversations idle for days. The ^ anchor also drops the partial first
# line a byte-offset tail produces. `tail -c` seeks, so a 15 MB transcript
# costs the same as a small one. With no activity line in the window, falls
# back to the mtime rendered in the same shape (…SS.000Z — without ".000",
# "Z" sorts above "." and an mtime key would beat activity later in its own
# second). TZ=UTC must be a command prefix: a plain `local TZ=UTC` isn't
# exported, and printf's %(…)T silently renders local time.
wb_transcript_rank_key() {
  local ts
  ts="$(tail -c 262144 "$1" 2>/dev/null \
    | sed -n 's/^{"parentUuid":.*"timestamp":"\([^"]*\)".*/\1/p' | tail -n1)"
  if [ -n "$ts" ]; then printf '%s\n' "$ts"; else TZ=UTC printf '%(%Y-%m-%dT%H:%M:%S)T.000Z\n' "$2"; fi
}

# wb_resume_id <task_file> <worktree_abs> — the session id `--resume` should
# use (R9): the transcript with the newest real activity
# (wb_transcript_rank_key — not wb_transcripts' mtime order, which a mass
# kill turns into a same-second tie broken alphabetically: on 2026-10-25 that
# resumed the pre-/clear conversation in 3 of 21 sessions), else empty
# (nothing to resume — the caller pre-types nothing, a cold start).
# The `@primary` mark in claude_sessions: is deliberately not consulted: only
# `wb down` writes it, from a pane id set when Jet sends a prompt, so it can
# be stale at write time and stays stale across a later /clear. <task_file>
# is unused now but kept for cmd_new's and the tests' call shape.
# Tradeoff: a conversation reopened via /resume with no new turn ranks below
# the one it replaced — "newest activity" means where Jet last typed.
wb_resume_id() {
  local worktree_abs="$2"
  local transcripts; transcripts="$(wb_transcripts "$worktree_abs")"
  [ -n "$transcripts" ] || return 0

  local dir id mtime; dir="$(wb_transcript_dir "$worktree_abs")"
  while IFS=$'\t' read -r id mtime; do
    printf '%s\t%s\n' "$(wb_transcript_rank_key "$dir/$id.jsonl" "$mtime")" "$id"
  done <<< "$transcripts" | sort -t $'\t' -k1,1r | head -n1 | cut -f2
}

# wb_sessions_snapshot <session> <worktree_abs> — "<id>@<iso-ts>[@primary],..."
# oldest first, for every transcript currently on disk for <worktree_abs>.
# When <session> is live, the id belonging to its `agent`-window pane's
# @claude_session_id (set by claude-notify-hook.sh) is marked @primary
# (KTD3) — that pane is the task's main conversation by construction
# (wb_layout_session always creates it there). <session> may be empty or
# already gone; the snapshot still builds from disk, just with no primary
# marked. Record-only (KTD2): nothing downstream re-derives activity from
# this field, and wb_resume_id ignores the mark (see its header).
wb_sessions_snapshot() {
  local session="$1" worktree_abs="$2"
  local transcripts; transcripts="$(wb_transcripts "$worktree_abs")"
  [ -n "$transcripts" ] || return 0

  # "|"-delimited, not tab: a literal "\t" inside a single-quoted -F string
  # is passed to tmux as the two characters backslash+t, not an actual tab
  # (bash single-quotes don't interpret escapes) — the same reason
  # _break_out's own multi-field -F below uses "|".
  local primary_sid="" agent_pane
  if [ -n "$session" ] && tmux has-session -t "=$session" 2>/dev/null; then
    agent_pane="$(tmux list-panes -s -t "=$session:" -F '#{window_name}|#{pane_id}' 2>/dev/null \
      | awk -F'|' '$1 == "agent" { print $2; exit }')"
    [ -n "$agent_pane" ] && primary_sid="$(tmux show -p -v -t "$agent_pane" @claude_session_id 2>/dev/null || true)"
  fi

  local id ts iso line
  local -a entries=()
  while IFS=$'\t' read -r id ts; do
    [ -n "$id" ] || continue
    iso="$(date -u -d "@$ts" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || true)"
    [ -n "$iso" ] || iso="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    line="$id@$iso"
    [ -n "$primary_sid" ] && [ "$id" = "$primary_sid" ] && line="$line@primary"
    entries+=("$line")
  done < <(printf '%s\n' "$transcripts" | tac)

  local IFS=','
  printf '%s\n' "${entries[*]}"
}

# wb_sanitize <slug> — slug -> display form for tmux session names / filenames
# ("/", "." and ":" become "-"; never parse this back, see header comment).
# ":" matters beyond aesthetics: tmux 3.4 silently rewrites "."/":" to "_"
# in new-session -s, so an unsanitized name diverges from what tmux actually
# created — and a stale ":"-bearing name later fed to kill-session parses as
# session:window and can kill an UNRELATED session.
wb_sanitize() { local s="${1//\//-}"; s="${s//./-}"; echo "${s//:/-}"; }

# WB_SIZE_VALUES / _wb_valid_size <value> — the `size:` frontmatter enum,
# defined ONCE as the `|`-joined literal (it doubles as the text of every
# "not one of …" error) and checked by anchoring it as a regex alternation.
# Legal: one of the strict, uppercase XS|S|M|L|XL, or empty (blank means
# "unset", which every reader treats as M — see ~/code/tasks/README.md
# "Size"). Shared by cmd_set and _wb_breakdown_validate's per-child
# `- size:` bullet. Lowercase is deliberately rejected rather than
# normalized (kept strict; normalization is a trivial follow-up if it ever
# proves annoying in practice).
WB_SIZE_VALUES="XS|S|M|L|XL"
_wb_valid_size() {
  [ -n "$1" ] || return 0
  [[ "$1" =~ ^($WB_SIZE_VALUES)$ ]]
}

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

# wb_family_all_done <parent_stem> — KTD8: true when <parent_stem> has at
# least one child (parent: == <parent_stem>) and EVERY one of them is
# status: done — a review/paused/planned sibling suppresses it, an only
# child is enough to fire it. Pure read, no writes; cmd_done decides what
# to do with the result (print-only, D8: closing the parent stays manual).
wb_family_all_done() {
  local parent_stem="$1" f found=0
  for f in $(wb_task_files); do
    [ "$(wb_get_frontmatter "$f" parent)" = "$parent_stem" ] || continue
    found=1
    [ "$(wb_get_frontmatter "$f" status)" = done ] || return 1
  done
  [ "$found" = 1 ]
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
#
# perf(wb-board): pure-bash split, no awk fork. This runs twice per task in
# the board's collect + model passes (~700 awk execs on the real store), and
# an awk exec from a large bash costs more than the whole string walk. It
# keeps awk's record semantics exactly — one record per input line, an empty
# line has no fields (NF=0), every other line yields all its tab-separated
# fields including empty ones — and splits with ${%%}/${#} slicing rather than
# `IFS=$'\t' read`, for the whitespace-collapsing reason above.
#
# The walk runs under a function-local LC_ALL=C (restored on return): in a
# UTF-8 locale bash's `read` mishandles a line that carries an incomplete
# multibyte sequence (a stray lead byte before the newline), merging or
# dropping the record where awk kept it. Bytewise, tab and newline are plain
# ASCII, so C-locale slicing is exact for every input and a no-op for valid
# UTF-8. (A `read ... || [ -n ]` retry was tried and still diverged.)
wb_tsv_split() {
  local LC_ALL=C
  local -n _wb_tsv_out="$2"
  local _wb_tsv_line _wb_tsv_rest
  _wb_tsv_out=()
  while IFS= read -r _wb_tsv_line; do
    [ -n "$_wb_tsv_line" ] || continue
    _wb_tsv_rest="$_wb_tsv_line"
    while [[ "$_wb_tsv_rest" == *$'\t'* ]]; do
      _wb_tsv_out+=("${_wb_tsv_rest%%$'\t'*}")
      _wb_tsv_rest="${_wb_tsv_rest#*$'\t'}"
    done
    _wb_tsv_out+=("$_wb_tsv_rest")
  done <<< "$1"
}

# ---------------------------------------------------------------------------
# Lock integration (U3) — the caller-side dead-holder retry layer built on
# top of wb-locks.sh's (U1) generic, liveness-agnostic primitives. Every
# cmd_*/wb_reconcile_action_* call site below (and handoff.sh's own write
# site) uses wb_task_lock_acquire_guarded instead of calling
# wb_task_lock_acquire directly, so the retry decision lives in exactly one
# place.
# ---------------------------------------------------------------------------

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
#     crash case.
#   - anything else (live holder, missing/empty holder info) -> never
#     retries. wb_task_lock_acquire's own failure — which already printed
#     the one L4 stderr message naming the holder — stands unmodified; this
#     function never prints a second message of its own.
# The retry itself is just another `wb_task_lock_acquire` call: a retry
# against a lock that's actually free returns effectively instantly through
# the existing `flock -w 1` path.
wb_task_lock_acquire_guarded() {
  local task_file="$1"
  wb_task_lock_acquire "$task_file" && return 0
  local rc=$?

  local holder_pid; holder_pid="$(wb_task_lock_holder_field "$task_file" pid)"

  if [ -n "$holder_pid" ] && ! kill -0 "$holder_pid" 2>/dev/null; then
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
# a worktree never needs its own reinstall. Idempotent per entry — an entry
# already present in the worktree is left alone: `ln -s` onto an existing
# directory symlink would nest a link INSIDE the main checkout's dir, and a
# `cp -a` would clobber a worktree-local edit (e.g. a tweaked `.env`). That
# is what makes it safe for cmd_new to call on every run, not just on
# worktree creation.
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
  # Per-entry failures are tracked, not fatal: a caller's `|| warn` disables
  # errexit in here, so without the explicit rc only a failing LAST entry
  # would ever surface.
  local entry src dest rc=0
  for entry in "${entries[@]}"; do
    src="$repo_dir/$entry"
    [ -e "$src" ] || continue
    dest="$worktree_path/$entry"
    { [ -e "$dest" ] || [ -L "$dest" ]; } && continue
    mkdir -p "$(dirname "$dest")" || { rc=1; continue; }
    if [ -d "$src" ]; then
      ln -s "$src" "$dest" || rc=1
    else
      cp -a "$src" "$dest" || rc=1
    fi
  done
  return "$rc"
}

# wb_ensure_repo_ignore <path> [<pattern>] — idempotently register <pattern>
# (default: the queue file's `.claude-queue.md`) as ignored in whatever repo
# <path> belongs to, via that repo's own untracked `.git/info/exclude` —
# never that repo's tracked `.gitignore`, never a machine-wide
# `core.excludesFile` (see
# docs/plans/2026-07-11-003-feat-queue-command-plan.md's Planning Contract:
# a foreign repo under $CODE_DIR is not ours to edit, and a machine-wide
# setting would silently change `git status` for every repo on the machine).
# <path> may be a worktree or the main checkout — `git rev-parse
# --git-common-dir` resolves either to the one shared `.git` dir all of a
# repo's worktrees have in common, so this same call works whether it's
# handed a repo dir (cmd_new, below) or a worktree's cwd (queue.lua's lazy-
# create path, called on every stash, or cmd_new's own CONCEPTS.md seed
# writer registering `CLAUDE.local.md`).
#
# Guarded against two concrete failure modes: a missing trailing newline in
# a pre-existing info/exclude would otherwise glue the new pattern onto the
# end of the prior last line, corrupting both and breaking the `grep -qxF`
# idempotency check on every later call — fixed by ensuring the file ends in
# a newline before ever appending. A race between two concurrent callers for
# the same repo (two terminals, or a script, creating worktrees back to
# back) is fixed with a `flock` on a lockfile scoped to that repo's own
# `.git/info` directory, making the check-then-append atomic — shared across
# every <pattern> for the repo, which only serializes independent callers a
# little more than strictly necessary, never a correctness problem. This
# must NEVER truncate or overwrite existing content in info/exclude — other
# tooling, or the user, may already have entries there.
wb_ensure_repo_ignore() {
  local path="$1" pattern="${2:-.claude-queue.md}"
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
  local lockfile="$info_dir/.wb-ensure-ignore.lock"

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

# _wb_concepts_paths <task_file> — task-family CONCEPTS.md resolver.
#
# Originally scoped (in planning) as a per-prompt hook's lookup; the task's
# own U1 spike (see the origin task file's `## Decisions`) found that Claude
# Code hooks cannot inject context into Task-tool sub-agents at all — the
# exact audience this needs to reach, since that's where the motivating
# drift incident happened. U2 pivoted to seed-automation instead (this
# function, called from cmd_new's worktree-creation path below rather than
# from a hook), which reaches sub-agents because they load a worktree's cwd
# instruction files same as the top-level session does.
#
# Walks the parent: chain starting at <task_file>'s own stem — nearest
# first, so a child's own settled facts are listed before an umbrella's —
# self-parent (wb_task_own_parent) and cycles (seen-set) both stop the walk
# rather than looping; a depth cap is a backstop against either guard
# somehow missing a case. Prints one path per line for every
# $TASKS_DIR/dossiers/<stem>/CONCEPTS.md that exists anywhere in the chain;
# prints nothing (exit 0) when none exist, including when <task_file> itself
# doesn't exist.
_wb_concepts_paths() {
  local task_file="$1"
  [ -f "$task_file" ] || return 0
  local -A seen=()
  local depth=0 max_depth=20
  local current_file="$task_file"
  local current_stem; current_stem="$(basename "$task_file" .md)"

  while [ -n "$current_stem" ] && [ "$depth" -lt "$max_depth" ]; do
    [ -z "${seen[$current_stem]:-}" ] || break
    seen[$current_stem]=1
    depth=$((depth + 1))

    local dossier="$TASKS_DIR/dossiers/$current_stem/CONCEPTS.md"
    [ -f "$dossier" ] && printf '%s\n' "$dossier"

    local parent_ref; parent_ref="$(wb_get_frontmatter "$current_file" parent)"
    [ -n "$parent_ref" ] || break
    wb_task_own_parent "$parent_ref" "$current_stem" || break

    local parent_file="$TASKS_DIR/$parent_ref.md"
    [ -f "$parent_file" ] || break
    current_file="$parent_file"
    current_stem="$parent_ref"
  done
  return 0
}

# _wb_seed_concepts_file <task_file> <worktree_path> — write (or refresh) the
# task family's settled-facts pointer inside <worktree_path>'s untracked
# `CLAUDE.local.md`, giving every agent there — including Task-tool
# sub-agents (D1/U1) — the family CONCEPTS.md file(s) without copying
# content. The pointer lives inside a sentinel-marked managed block
# (`<!-- wb:concepts start -->` … `<!-- wb:concepts end -->`); only that
# block is ever wb's to rewrite, so any hand-added local instructions
# elsewhere in CLAUDE.local.md (the conventional Claude Code local-context
# file, which wb does not exclusively own) survive a `wb new` / resume —
# an existing marked block is replaced in place, a marker-less pre-existing
# file is appended to (never clobbered), and only an absent file is created
# outright. Regenerating the block on every call is the escape hatch for a
# reparent or a newly-added CONCEPTS.md taking effect — there is no runtime
# hook re-resolving this on its own. No-ops (leaves any existing file
# untouched) when _wb_concepts_paths finds nothing in the chain; stale-
# removal of the block for a family that LOSES its last CONCEPTS.md is out
# of scope (narrow edge case, not the common reparent-adds-facts direction).
_wb_seed_concepts_file() {
  local task_file="$1" worktree_path="$2"
  local -a paths=()
  local p
  while IFS= read -r p; do
    [ -n "$p" ] && paths+=("$p")
  done < <(_wb_concepts_paths "$task_file")
  [ "${#paths[@]}" -gt 0 ] || return 0

  local target="$worktree_path/CLAUDE.local.md"
  local family_note; family_note="$(basename "$task_file" .md)"

  # Build the managed block (including its own sentinel markers) into a temp
  # file, then splice it into $target so only the marked region is touched.
  local block_file; block_file="$(mktemp)" || return 1
  {
    printf '%s\n' '<!-- wb:concepts start -->'
    printf '# Task-family context (wb, untracked — managed block, edit around it)\n\n'
    printf 'This worktree belongs to the "%s" task family. Treat the family concepts\n' "$family_note"
    printf 'file(s) below as part of AGENTS.md: settled facts, vocabulary and rules\n'
    printf 'that override older dossier docs where they disagree. Listed nearest-\n'
    printf 'first: the nearer (child) file takes precedence over a farther\n'
    printf '(umbrella) one where they disagree.\n\n'
    for p in "${paths[@]}"; do
      printf '@%s\n' "$p"
    done
    printf '\nCoordinator task file: %s\n' "${task_file/#$HOME/\~}"
    printf '%s\n' '<!-- wb:concepts end -->'
  } > "$block_file"

  local rc=0
  if [ -f "$target" ] \
     && grep -qF '<!-- wb:concepts start -->' "$target" \
     && grep -qF '<!-- wb:concepts end -->' "$target"; then
    # Existing marked block: replace it in place, preserve everything else.
    local tmp; tmp="$(mktemp)" || { rm -f "$block_file"; return 1; }
    if awk -v bf="$block_file" '
         /<!-- wb:concepts start -->/ {
           while ((getline line < bf) > 0) print line
           close(bf); insec = 1; next
         }
         insec && /<!-- wb:concepts end -->/ { insec = 0; next }
         insec { next }
         { print }
       ' "$target" > "$tmp"; then
      mv "$tmp" "$target" || rc=1
    else
      rm -f "$tmp"; rc=1
    fi
  elif [ -f "$target" ]; then
    # Marker-less pre-existing file (user content): append, never clobber.
    { printf '\n'; cat "$block_file"; } >> "$target" || rc=1
  else
    cat "$block_file" > "$target" || rc=1
  fi
  rm -f "$block_file"
  [ "$rc" -eq 0 ] || return 1

  wb_ensure_repo_ignore "$worktree_path" "CLAUDE.local.md" \
    || echo "wb new: warning: could not register .git/info/exclude ignore rule for CLAUDE.local.md (continuing)" >&2
}

# _wb_fill_frontmatter <file> <key> <value> — "explicit wins, else
# blank-fill": a non-empty <value> is written unconditionally; an empty one
# only ensures the key LINE exists (inserted blank when absent), never
# clobbering a value already in the file. wb_seed_task's optional
# board-metadata fields (path, depends_on, size) all share this shape so a
# flag-less re-run leaves an earlier explicit value alone.
_wb_fill_frontmatter() {
  local file="$1" key="$2" value="$3"
  if [ -n "$value" ]; then
    wb_set_frontmatter "$file" "$key" "$value"
  else
    [ -n "$(wb_get_frontmatter "$file" "$key")" ] || wb_set_frontmatter "$file" "$key" ""
  fi
}

# wb_seed_task <repo> <slug> <worktree_rel> [<parent_ref>] [<file_override>]
# [<depends_on_csv>] — find-or-create the task file for a
# repo+slug pair, filling blank frontmatter fields and bumping
# planned->doing. Never overwrites a field that's already set, UNLESS the
# caller explicitly passed a value for it (parent/depends_on) — an
# explicit value always wins, same precedent `parent:` already set below.
# <parent_ref>/<file_override>/<depends_on_csv> are all
# optional (default to empty) so wb_reconcile_action_create_task's
# pre-existing 3/4-arg calls keep working unchanged — it never sets
# `parent:`. <file_override> is KTD7's directional escape hatch for `wb
# resume`: post-migration, a continuing child's own branch:/worktree: equal
# the PARENT's original identity, so re-deriving the task file from
# repo+slug via wb_task_file would resolve back to the PARENT's file —
# cmd_resume already knows the real (child) file from its own stem-based
# lookup and passes it straight through here instead.
wb_seed_task() {
  local repo="$1" slug="$2" worktree_rel="$3" parent="${4:-}" file_override="${5:-}" depends_on="${6:-}"
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

    # R5/U4: resuming a shelved task flips it back to doing, exactly like
    # the pre-existing planned->doing flip below — a `paused` task was
    # deliberately shelved, not abandoned, so `wb new`/`wb resume` bringing
    # it back is itself the "un-shelve" action.
    case "$(wb_get_frontmatter "$file" status)" in
      planned|paused) wb_set_frontmatter "$file" status doing ;;
    esac
    # reviewed: has no inferred value (unlike repo/branch/worktree above) —
    # it starts blank and is only ever stamped by cmd_reviewed. This just
    # backfills the KEY onto task files that predate it in the schema, same
    # as the other blank-field fills above, never overwriting a value
    # that's already set.
    [ -n "$(wb_get_frontmatter "$file" reviewed)" ]  || wb_set_frontmatter "$file" reviewed ""
  fi
  [ -z "$parent" ] || wb_set_frontmatter "$file" parent "$parent"

  # path:/depends_on:/size: — every seeded task file must carry all three
  # keys, per the schema's blank-fill convention (mirrors reviewed: above);
  # depends_on: additionally takes an explicit value the same way parent:
  # does. path:/size: are only ever set later, through `wb set`.
  # wb_set_frontmatter itself inserts the key when TEMPLATE.md (or a
  # pre-existing file) has no line for it yet, so this is correct whether
  # or not the template has caught up to carrying the blank lines. A blank
  # size: reads as M at load, so blank-filling it never manufactures a
  # value.
  _wb_fill_frontmatter "$file" path ""
  _wb_fill_frontmatter "$file" depends_on "$depends_on"
  _wb_fill_frontmatter "$file" size ""

  echo "$file"
}

# wb_seed_task_planned <repo> <slug> [<parent_ref>] [<title>] — W13's
# planned-preserving sibling of wb_seed_task: find-or-create the task file
# for a repo+slug pair WITHOUT ever creating a worktree, and WITHOUT
# wb_seed_task's own planned->doing flip or worktree stamping. <title> is
# only used on a genuinely NEW file (e.g. a Jira ticket's summary, via
# `wb new --planned --jira --title`) — falls back to the slug-derived form
# when omitted; an EXISTING file's title (the body's own `# ` heading,
# not frontmatter) is never touched here, matching this function's own
# fill-blanks-only posture for every other field. Used by `wb new --planned`
# (cmd_new, below), in turn used by /weekly-review's scratch-task creation and
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
#
# Optional trailing <status> (default "planned"; `wb new --prospective`
# passes "prospective", R25) is the status stamped on a genuinely NEW file
# and the fill-blank value on an existing one — same non-clobbering rule,
# just parameterized so `--planned` and `--prospective` share this one
# creation path instead of forking it.
wb_seed_task_planned() {
  local repo="$1" slug="$2" parent="${3:-}"
  local title="${4:-${slug//-/ }}"
  local status_override="${5:-planned}"
  local disp_slug; disp_slug="$(wb_sanitize "$slug")"
  local file; file="$(wb_task_file "$repo" "$disp_slug")"

  if [ ! -f "$file" ]; then
    mkdir -p "$TASKS_DIR"
    # title is free-text (e.g. a Jira ticket summary) — never through awk -v,
    # same reasoning as wb_seed_planned_child's own title fix: getline from a
    # temp file instead of splicing via -v, which would mangle backslashes.
    local titlefile; titlefile="$(mktemp)"
    printf '%s' "$title" > "$titlefile"
    awk -v repo="$repo" -v branch="$slug" -v status="$status_override" \
        -v created="$(date +%F)" -v titlefile="$titlefile" '
      BEGIN { infm = 0; getline title < titlefile; close(titlefile) }
      /^---$/     { infm++; print; next }
      infm == 1 && /^status:/   { print "status: " status; next }
      infm == 1 && /^repo:/     { print "repo: " repo; next }
      infm == 1 && /^branch:/   { print "branch: " branch; next }
      infm == 1 && /^created:/  { print "created: " created; next }
      infm == 2 && /^# Title/   { print "# " title; next }
      { print }
    ' "$TASKS_DIR/TEMPLATE.md" > "$file"
    rm -f "$titlefile"
  else
    [ -n "$(wb_get_frontmatter "$file" repo)" ]     || wb_set_frontmatter "$file" repo "$repo"
    [ -n "$(wb_get_frontmatter "$file" branch)" ]   || wb_set_frontmatter "$file" branch "$slug"
    [ -n "$(wb_get_frontmatter "$file" status)" ]   || wb_set_frontmatter "$file" status "$status_override"
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
# avoids the mangling entirely. No-op when <body> is empty or whitespace-only.
_wb_insert_plan_body() {
  local file="$1" body="$2"
  [[ $body == *[![:space:]]* ]] || return 0
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
#
# Optional trailing <size> (XS|S|M|L|XL, already validated by the caller) and
# <depends_on> (comma-joined, already-resolved `<repo>--<slug>` stems —
# _wb_breakdown_execute does the raw-slug → stem resolution) are written
# via wb_set_frontmatter ONLY when non-empty, so an unset value leaves the
# template's blank line intact (blank size: reads as M; blank depends_on:
# is "no blockers"). Trailing + optional keeps every existing 3/4-arg call
# byte-identical in behavior.
wb_seed_planned_child() {
  local repo="$1" slug="$2" parent="$3"
  local title="${4:-${slug//-/ }}"
  local size="${5:-}" depends_on="${6:-}"
  local disp_slug; disp_slug="$(wb_sanitize "$slug")"
  local file; file="$(wb_task_file "$repo" "$disp_slug")"

  if [ -f "$file" ]; then
    echo "wb_seed_planned_child: $file already exists — refusing to overwrite" >&2
    return 1
  fi

  mkdir -p "$TASKS_DIR"
  local body; body="$(cat)"

  # title is free-text (the buffer's own editable "goal:" line) and MUST NOT
  # go through awk -v — same reasoning as _wb_insert_plan_body's body
  # (awk's C escape-sequence processing on a -v assignment would mangle a
  # goal containing \n/\t/\K, splitting the generated # <title> heading
  # across lines). Read via getline from a temp file instead, exactly like
  # every other free-text value this feature seeds.
  local titlefile; titlefile="$(mktemp)"
  printf '%s' "$title" > "$titlefile"

  awk -v repo="$repo" -v branch="$slug" -v parent="$parent" \
      -v created="$(date +%F)" -v titlefile="$titlefile" '
    BEGIN { infm = 0; getline title < titlefile; close(titlefile) }
    /^---$/     { infm++; print; next }
    infm == 1 && /^repo:/     { print "repo: " repo; next }
    infm == 1 && /^branch:/   { print "branch: " branch; next }
    infm == 1 && /^parent:/   { print "parent: " parent; next }
    infm == 1 && /^created:/  { print "created: " created; next }
    infm == 2 && /^# Title/   { print "# " title; next }
    { print }
  ' "$TASKS_DIR/TEMPLATE.md" > "$file"
  rm -f "$titlefile"

  [ -z "$size" ]       || wb_set_frontmatter "$file" size "$size"
  [ -z "$depends_on" ] || wb_set_frontmatter "$file" depends_on "$depends_on"

  _wb_insert_plan_body "$file" "$body"
  echo "$file"
}

# wb_layout_session <session> <dir> <start_agent> [<agent_cmd>] —
# first-time-only 3-window layout: win1 an editor shell (LAZY — the nvim
# launch is pre-typed but not run, so nvim/LSP start only when you visit and
# press Enter), win2 a plain shell for the agent (LAZY — you run `claude`
# yourself the first time you visit, bounded by the ~10-concurrent-agent
# memory ceiling; pass start_agent=1, i.e. `wb new --agent`, to start it
# now), win3 shell. <agent_cmd> (U4/R9) is the command win2 pre-types
# instead of a bare "claude" — a warm `claude --resume <id>` when the
# caller resolved one, empty otherwise.
wb_layout_session() {
  local session="$1" dir="$2" start_agent="$3" agent_cmd="${4:-}"
  tmux rename-window -t "=$session:1" nvim
  # LAZY editor, mirroring the agent window below: we PRE-TYPE the nvim launch
  # into win1 but deliberately DON'T send Enter, so nvim + its LSP (gopls in
  # be--monorepo is 1-4GB *per session*) only start when you actually land here
  # and press Enter — not eagerly on every `wb new`/`wb resume`. Resuming N
  # sessions at once used to spawn N gopls immediately; that eager cost was a
  # direct contributor to the 2026-08-24 systemd-oomd kill that took down the
  # whole tmux server. WB_AUTO_RESTORE=1 still opts this launch into
  # persistence.nvim's auto-restore-on-VimEnter (nvim/.config/nvim/lua/plugins/
  # config/persistence.lua), so hitting Enter picks back up where you left off;
  # typing `nvim .`/`vim .` yourself anywhere else does NOT set it and gets a
  # plain, non-restoring open (2026-07-09: silent auto-restore on every `.`
  # launch was surprising with no escape hatch).
  tmux send-keys -t "=$session:1" "WB_AUTO_RESTORE=1 nvim ."
  tmux new-window -t "=$session" -n agent -c "$dir"
  # remain-on-exit keeps the agent window as [dead] instead of letting tmux
  # auto-close it the instant its shell exits. The window is a bare shell with
  # claude run inside it (send-keys below), so the ONLY thing keeping it alive
  # after you quit claude is that shell — and a stray Ctrl-D / `exit` (easy to
  # fat-finger, since claude ALSO quits on Ctrl-D) then silently takes the whole
  # window with it. Scoped to this window only, never global: the picker/help/
  # ask/notes windows are launched AS their command and are MEANT to close on
  # exit. Recover a dead one with prefix+E (respawn-pane, tmux.conf). Explicit
  # kills (wb done --close, ctrl-x) are unaffected — they destroy regardless.
  tmux set-option -w -t "=$session:agent" remain-on-exit on
  # U4/R9: <agent_cmd> lets the caller pre-type a warm `claude --resume <id>`
  # instead of the bare "claude" — same lazy-launch
  # rule as the nvim window above, just parameterized: --agent (start_agent=1)
  # presses Enter on whatever command was resolved (falling back to plain
  # "claude" when there's nothing to resume, i.e. today's exact behavior);
  # the default lazy path pre-types it without Enter, and types NOTHING at
  # all when there's no id/history to resume from (a brand-new task) — never
  # eagerly starting an agent just because a command string happens to exist.
  if [ "$start_agent" = 1 ]; then
    tmux send-keys -t "=$session:agent" "${agent_cmd:-claude}" Enter
  elif [ -n "$agent_cmd" ]; then
    tmux send-keys -t "=$session:agent" "$agent_cmd"
  fi
  tmux new-window -t "=$session" -n shell -c "$dir"
  tmux select-window -t "=$session:1"
}

# _wb_new_interactive — true when `wb new` can put a question to a person.
# Agents (the Bash tool) and handoff.sh's agent spawns have no terminal, so
# they get the default answer instead of a menu nobody will see. A function,
# not an inline test, so tests can force the menu on.
_wb_new_interactive() { [ -t 0 ] && [ -t 2 ]; }

# _wb_new_start_point <repo_dir> <repo> <slug> <own_task_file> <depends_on_csv>
# — print the ref a freshly created `wb new` branch should start from, or
# nothing (git's implicit HEAD, the old behavior). A bare `worktree add -b`
# bases every new branch on whatever the main checkout's HEAD happens to be:
# a local default branch that often hasn't been pulled since the last merge
# (handoffs repeatedly came up several PRs behind), and never the commits of
# a blocker the task needs.
#   - Only depends_on stacks. parent: is a family umbrella, not a predecessor
#     whose commits a child needs; a child that really builds on its parent
#     lists the parent in depends_on as well. Explicit --depends-on wins,
#     otherwise the task file's own depends_on: (`wb new --planned
#     --depends-on …` now, a plain `wb new` to start it later).
#   - A blocker is usable when it is in this repo, not `done` (its commits
#     are merged — the default branch has them), its `branch:` exists
#     locally or as origin/<branch>, and that branch has no merged PR. A
#     blocker whose PR merged before its task was marked done would start
#     the branch on pre-squash copies of commits the default already has,
#     so it is skipped with a note pointing at the latest default.
#   - The default branch is always fetched first: it is the fallback, and
#     each blocker's staleness is measured against it. It is resolved from
#     the origin/HEAD symref, then ls-remote, never
#     hard-coded — Sportable repos use dev/development/main.
#   - Usable blockers: with a terminal, a menu of each blocker (ahead/behind
#     the default) plus the latest default; without one, or when the menu
#     would have a single entry, the first blocker.
#     A chosen blocker that is behind the default gets a rebase nudge — it is
#     never rebased for you, its own worktree may be mid-work.
#   - No usable blocker: origin/<default>. No origin, or no resolvable
#     default: print nothing.
_wb_new_start_point() {
  local repo_dir="$1" repo="$2" slug="$3" own_file="$4" deps_csv="$5"
  if [ -z "$deps_csv" ] && [ -f "$own_file" ]; then
    deps_csv="$(wb_get_frontmatter "$own_file" depends_on)"
  fi

  # timeout bounds an unreachable remote or a stalled SSH auth, so a handoff
  # spawn never hangs on the ls-remote or the fetch.
  local -a to=()
  command -v timeout >/dev/null 2>&1 && to=(timeout 30)
  local def=""
  if git -C "$repo_dir" remote get-url origin >/dev/null 2>&1; then
    def="$(git -C "$repo_dir" symbolic-ref -q --short refs/remotes/origin/HEAD 2>/dev/null || true)"
    def="${def#origin/}"
    if [ -z "$def" ]; then
      def="$(GIT_TERMINAL_PROMPT=0 "${to[@]}" git -C "$repo_dir" ls-remote --symref origin HEAD 2>/dev/null \
        | awk '$1 == "ref:" { sub("^refs/heads/", "", $2); print $2; exit }')"
    fi
    if [ -z "$def" ]; then
      echo "wb new: warning: could not determine origin's default branch for $repo_dir — branching from local HEAD" >&2
    else
      local fetched=1
      GIT_TERMINAL_PROMPT=0 "${to[@]}" git -C "$repo_dir" fetch -q origin "$def" 2>/dev/null || fetched=0
      if git -C "$repo_dir" show-ref --verify --quiet "refs/remotes/origin/$def"; then
        [ "$fetched" = 1 ] \
          || echo "wb new: warning: git fetch origin $def failed — using the last-fetched origin/$def" >&2
      else
        echo "wb new: warning: git fetch origin $def failed and there is no cached origin/$def — branching from local HEAD" >&2
        def=""
      fi
    fi
  fi

  local -a stems=() refs=() behinds=() aheads=()
  local -a cands=()
  [ -z "$deps_csv" ] || IFS=',' read -r -a cands <<< "$deps_csv"
  local stem f br ref counts
  for stem in "${cands[@]}"; do
    read -r stem <<< "$stem"
    f="$TASKS_DIR/$stem.md"
    [ -n "$stem" ] && [ -f "$f" ] || continue
    [ "$(wb_get_frontmatter "$f" repo)" = "$repo" ] || continue
    [ "$(wb_get_frontmatter "$f" status)" != done ] || continue
    br="$(wb_get_frontmatter "$f" branch)"
    read -r br <<< "$br"
    [ -n "$br" ] || continue
    if git -C "$repo_dir" show-ref --verify --quiet "refs/heads/$br"; then
      ref="$br"
    elif git -C "$repo_dir" show-ref --verify --quiet "refs/remotes/origin/$br"; then
      ref="origin/$br"
    else
      continue
    fi
    # "unknown" (no gh, no auth, offline) keeps the blocker: a wrong skip
    # would silently drop commits the task needs.
    if [ -n "$def" ] && [ "$(wb_pr_merge_status "$repo_dir" "$br")" = merged ]; then
      echo "wb new: note: $stem's PR ($br) is already merged — its work is in origin/$def, so branch from the latest origin/$def instead (and \`wb done\` $stem)" >&2
      continue
    fi
    counts=""
    [ -z "$def" ] || counts="$(git -C "$repo_dir" rev-list --left-right --count "origin/$def...$ref" 2>/dev/null || true)"
    stems+=("$stem"); refs+=("$ref")
    behinds+=("$(awk '{print $1}' <<< "$counts")"); aheads+=("$(awk '{print $2}' <<< "$counts")")
  done

  if [ "${#refs[@]}" -eq 0 ]; then
    [ -z "$def" ] || printf 'origin/%s\n' "$def"
    return 0
  fi

  local pick=0 i n="${#refs[@]}"
  # A menu needs two choices: one blocker and no default (no origin) is not
  # a question.
  if _wb_new_interactive && { [ "$n" -gt 1 ] || [ -n "$def" ]; }; then
    echo "wb new: $slug depends on unmerged work — branch from:" >&2
    for ((i = 0; i < n; i++)); do
      printf '  %d) %s  (%s%s)\n' "$((i + 1))" "${refs[$i]}" "${stems[$i]}" \
        "${def:+, ${aheads[$i]:-?} ahead / ${behinds[$i]:-?} behind origin/$def}" >&2
    done
    [ -z "$def" ] || printf '  %d) origin/%s  (latest)\n' "$((n + 1))" "$def" >&2
    local max=$n ans
    [ -z "$def" ] || max=$((n + 1))
    while :; do
      read -r -p "Choice [1]: " ans || { ans=1; echo >&2; }
      [ -n "$ans" ] || ans=1
      case "$ans" in
        *[!0-9]*) ;;
        *) if [ "$ans" -ge 1 ] && [ "$ans" -le "$max" ]; then break; fi ;;
      esac
      echo "wb new: enter a number from 1 to $max" >&2
    done
    if [ "$ans" -gt "$n" ]; then
      printf 'origin/%s\n' "$def"
      return 0
    fi
    pick=$((ans - 1))
  else
    for ((i = 1; i < n; i++)); do
      # Already inside the first blocker (stacked on it): nothing to merge.
      git -C "$repo_dir" merge-base --is-ancestor "${refs[$i]}" "${refs[0]}" 2>/dev/null && continue
      echo "wb new: note: $slug also depends on ${stems[$i]} (${refs[$i]}), which is not in its start point — merge it in if needed" >&2
    done
  fi

  if [ -n "$def" ] && [ "${behinds[$pick]:-0}" != 0 ]; then
    echo "wb new: note: ${refs[$pick]} (${stems[$pick]}) is ${behinds[$pick]} commit(s) behind origin/$def — consider rebasing it onto origin/$def, then $slug onto it" >&2
  fi
  printf '%s\n' "${refs[$pick]}"
}

# _wb_new_checked_out_at <repo_dir> <branch> — print the path of the worktree
# (the main checkout included) that has <branch> checked out, or nothing.
_wb_new_checked_out_at() {
  git -C "$1" worktree list --porcelain 2>/dev/null | awk -v ref="refs/heads/$2" '
    $1 == "worktree" { sub(/^worktree /, ""); path = $0 }
    $1 == "branch" && $2 == ref { print path; exit }'
}

# _wb_safe_worktree_field <value> — 0 when a task file's `worktree:` is a
# well-formed `.worktrees/<name>` path: safe charset only and no `.`/`..`/empty
# segment, so it cannot climb out of .worktrees/. Anything else (absolute
# paths, `.worktrees/../../x`) is untrusted and callers fall back to the
# slug-derived path.
_wb_safe_worktree_field() {
  case "$1" in .worktrees/?*) ;; *) return 1 ;; esac
  case "$1" in *[!A-Za-z0-9._/-]*) return 1 ;; esac
  case "/$1/" in *//*|*/../*|*/./*) return 1 ;; esac
  return 0
}

# _wb_new_add_worktree <repo_dir> <repo> <slug> <branch> <worktree_path>
#   <own_task_file> <depends_on_csv> — create <worktree_path> on <branch>.
# <branch> is the task file's pre-set `branch:` when it has one (seeding
# tools — wb breakdown, /handoff, weekly-review — fill it with names like
# feat/foo or fix/foo long before `wb new` runs), otherwise the slug. Every
# branch-keyed lookup (PR badges, the open-PR check in `wb down`, `wb done`'s
# merged check, a dependent's stacking in _wb_new_start_point) reads that
# `branch:`, so the git branch has to BE that name — creating a second,
# slug-named branch left the field pointing at nothing.
#   - Invalid ref name: stop before anything is created.
#   - Already checked out in another worktree: refuse, naming it.
#   - Exists locally: attach as-is.
#   - Adopted (<branch> differs from the slug) and it exists only on origin:
#     check it out tracking origin/<branch> — someone already pushed work
#     under the name the task claims. Not done for a slug-named branch: a
#     leftover remote branch from a finished task must not be resurrected by
#     starting a fresh task under the same slug.
#   - Otherwise a new branch from _wb_new_start_point.
# The worktree directory stays slug-based either way.
_wb_new_add_worktree() {
  local repo_dir="$1" repo="$2" slug="$3" branch="$4" worktree_path="$5" own_file="$6" deps_csv="$7"

  git -C "$repo_dir" check-ref-format --branch "$branch" >/dev/null 2>&1 \
    || { echo "wb new: branch '$branch' (the task's branch: field) is not a valid git branch name — fix it with \`wb set <task> branch <name>\`" >&2; return 1; }

  local elsewhere; elsewhere="$(_wb_new_checked_out_at "$repo_dir" "$branch")"
  if [ -n "$elsewhere" ]; then
    echo "wb new: branch '$branch' is already checked out at $elsewhere — use that worktree, or point the task at another branch (\`wb set <task> branch <name>\`)" >&2
    return 1
  fi

  if git -C "$repo_dir" show-ref --verify --quiet "refs/heads/$branch"; then
    git -C "$repo_dir" worktree add "$worktree_path" "$branch"
    return
  fi

  # Compare sanitized forms: a resume/picker re-entry passes the task file's
  # stem slug (already sanitized, feat-x) while plain `wb new` passes the raw
  # name (feat/x) — both name the same task, so neither counts as adopted.
  if [ "$(wb_sanitize "$branch")" != "$(wb_sanitize "$slug")" ] && git -C "$repo_dir" remote get-url origin >/dev/null 2>&1; then
    # Always ask origin, even when refs/remotes/origin/<branch> is cached: a
    # cached ref can be stale (branch deleted/merged on origin since the last
    # fetch) and must not be resurrected. Bounded like the default-branch
    # fetch, telling "not on origin" (ls-remote --exit-code rc 2: fine, cut a
    # new branch) apart from "couldn't check" (offline / auth / timeout):
    # guessing there would silently cut a divergent local branch under a name
    # that may already exist on origin, so abort before creating anything.
    local -a to=()
    command -v timeout >/dev/null 2>&1 && to=(timeout 30)
    local lsrc=0
    GIT_TERMINAL_PROMPT=0 "${to[@]}" git -C "$repo_dir" ls-remote --exit-code --heads origin \
      "refs/heads/$branch" >/dev/null 2>&1 || lsrc=$?
    if [ "$lsrc" -eq 0 ] && ! git -C "$repo_dir" show-ref --verify --quiet "refs/remotes/origin/$branch"; then
      # On origin but not in the last fetch — pushed since.
      GIT_TERMINAL_PROMPT=0 "${to[@]}" git -C "$repo_dir" fetch -q origin \
        "+refs/heads/$branch:refs/remotes/origin/$branch" >/dev/null 2>&1 || lsrc=1
    fi
    if [ "$lsrc" -ne 0 ] && [ "$lsrc" -ne 2 ]; then
      echo "wb new: couldn't reach origin to check for branch '$branch'; retry when online, or clear branch: / set it to a new name (\`wb set <task> branch <name>\`)" >&2
      return 1
    fi
    if [ "$lsrc" -eq 0 ] && git -C "$repo_dir" show-ref --verify --quiet "refs/remotes/origin/$branch"; then
      echo "wb new: attaching $slug to existing origin/$branch" >&2
      git -C "$repo_dir" worktree add --track -b "$branch" "$worktree_path" "origin/$branch"
      return
    fi
  fi

  local start_point
  start_point="$(_wb_new_start_point "$repo_dir" "$repo" "$branch" "$own_file" "$deps_csv")"
  if [ -n "$start_point" ]; then
    echo "wb new: branching $branch from $start_point" >&2
    # --no-track: branching from origin/<x> would otherwise make that
    # remote branch the new branch's upstream, so a bare `git pull` /
    # `git push` would target the default (or parent) branch.
    git -C "$repo_dir" worktree add --no-track -b "$branch" "$worktree_path" "$start_point"
  else
    git -C "$repo_dir" worktree add -b "$branch" "$worktree_path"
  fi
}

cmd_new() {
  # Index/shift case parser, not a single-token foreach: --parent takes
  # its value as a separate following argument, and --depends-on is
  # repeatable (accumulates into an array) — none of that can be detected by
  # a foreach that only matches literal tokens (like --agent); the value
  # would fall into the else branch and corrupt the positional repo/slug
  # count.
  local -r new_usage="usage: wb new [--agent|--planned|--prospective [--jira <url>] [--title <text>] [--body -|--body-file <path>]] [--parent <repo>--<slug>] [--depends-on <repo>--<slug>]... <slug> | wb new [--agent|--planned|--prospective [--jira <url>] [--title <text>] [--body -|--body-file <path>]] [--parent <repo>--<slug>] [--depends-on <repo>--<slug>]... <repo> <slug>"
  local agent_flag=0 parent_ref="" planned_flag=0 prospective_flag=0 jira_url="" title_override=""
  local body_stdin=0 body_file=""
  local -a depends_on_stems=()
  local -a args=()
  while [ $# -gt 0 ]; do
    case "$1" in
      -h|--help) echo "$new_usage"; return 0 ;;
      --agent)   agent_flag=1; shift ;;
      --planned) planned_flag=1; shift ;;
      # R25/KTD4: `--prospective` is `--planned`'s worktree-less/session-less
      # creation path (wb_seed_task_planned) with `status: prospective`
      # instead of `status: planned` — the direct creation verb /park's
      # work-shaped capture path uses, so it never needs a two-step
      # "create planned, then wb status ... prospective".
      --prospective) planned_flag=1; prospective_flag=1; shift ;;
      --jira)
        case "${2-}" in
          ''|--*) echo "wb new: --jira requires a value" >&2; exit 1 ;;
        esac
        jira_url="$2"; shift 2 ;;
      --title)
        case "${2-}" in
          ''|--*) echo "wb new: --title requires a value" >&2; exit 1 ;;
        esac
        title_override="$2"; shift 2 ;;
      # --body - / --body-file <path>: the ONLY ways a planned/prospective
      # seed gets a ## Plan body. wb new never reads stdin implicitly — a
      # non-tty stdin it did not ask for (a `while read … done < file` loop,
      # a heredoc meant for something else) is left untouched.
      --body)
        [ "${2-}" = "-" ] \
          || { echo "wb new: --body only accepts '-' (read the body from stdin); use --body-file <path> for a file" >&2; exit 1; }
        body_stdin=1; shift 2 ;;
      --body-file)
        case "${2-}" in
          ''|--*) echo "wb new: --body-file requires a path" >&2; exit 1 ;;
        esac
        body_file="$2"; shift 2 ;;
      --parent)
        case "${2-}" in
          ''|--*) echo "wb new: --parent requires a value" >&2; exit 1 ;;
        esac
        parent_ref="$2"; shift 2 ;;
      --depends-on)
        case "${2-}" in
          ''|--*) echo "wb new: --depends-on requires a value" >&2; exit 1 ;;
        esac
        depends_on_stems+=("$2"); shift 2 ;;
      *)        args+=("$1"); shift ;;
    esac
  done

  if [ "$planned_flag" = 1 ] && [ "$agent_flag" = 1 ]; then
    if [ "$prospective_flag" = 1 ]; then
      echo "wb new: --prospective and --agent are mutually exclusive — --prospective never starts a worktree/session for --agent to attach to" >&2
    else
      echo "wb new: --planned and --agent are mutually exclusive — --planned never starts a worktree/session for --agent to attach to" >&2
    fi
    exit 1
  fi

  if [ -n "$jira_url" ] && [ "$planned_flag" != 1 ]; then
    echo "wb new: --jira is only valid together with --planned (ticket-parent seeding never starts a worktree/session)" >&2
    exit 1
  fi

  if [ -n "$title_override" ] && [ "$planned_flag" != 1 ]; then
    echo "wb new: --title is only valid together with --planned (only a fresh, worktree-less seed has a title left to set)" >&2
    exit 1
  fi

  if [ "$body_stdin" = 1 ] && [ -n "$body_file" ]; then
    echo "wb new: --body - and --body-file are mutually exclusive" >&2
    exit 1
  fi

  if { [ "$body_stdin" = 1 ] || [ -n "$body_file" ]; } && [ "$planned_flag" != 1 ]; then
    echo "wb new: --body/--body-file are only valid together with --planned or --prospective (only a worktree-less seed has a ## Plan body to fill)" >&2
    exit 1
  fi

  if [ -n "$body_file" ] && { [ ! -f "$body_file" ] || [ ! -r "$body_file" ]; }; then
    echo "wb new: --body-file '$body_file' is not a readable file" >&2
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
    echo "$new_usage" >&2
    exit 1
  fi

  [ -n "$slug" ] || { echo "wb new: <slug> must not be empty" >&2; exit 1; }

  local disp_slug; disp_slug="$(wb_sanitize "$slug")"
  local own_stem="${repo}--${disp_slug}"

  # Validate before anything is touched — same fail-loud-on-no-match
  # convention as `wb resume`. Also reject a self-referential --parent, the
  # same guard the picker/board read paths use (wb_task_own_parent).
  if [ -n "$parent_ref" ]; then
    wb_resolve_parent_ref "$parent_ref" >/dev/null || exit 1
    wb_task_own_parent "$parent_ref" "$own_stem" \
      || { echo "wb new: --parent cannot be the task's own reference" >&2; exit 1; }
  fi

  # --depends-on: each value must be a real, pre-existing task-file stem in
  # $TASKS_DIR (mirrors wb_resolve_parent_ref's fail-loud pattern, but
  # written inline here so the error names --depends-on rather than reusing
  # that helper's --parent-worded message), must not contain '/' (path
  # traversal) or ',' (the field's own list delimiter — wb_sanitize never
  # strips commas, so a comma-bearing stem would silently split into
  # dangling fragments later), and must not be this task's own stem
  # (self-reference). An already-`done` blocker is legal — trivially met, no
  # special-casing needed.
  local dep
  for dep in "${depends_on_stems[@]}"; do
    case "$dep" in
      */*) echo "wb new: --depends-on '$dep' must not contain '/'" >&2; exit 1 ;;
      *,*) echo "wb new: --depends-on '$dep' must not contain ','" >&2; exit 1 ;;
    esac
    [ "$dep" != "$own_stem" ] \
      || { echo "wb new: --depends-on cannot be the task's own reference" >&2; exit 1; }
    [ -f "$TASKS_DIR/$dep.md" ] \
      || { echo "wb new: --depends-on '$dep' has no matching task file in $TASKS_DIR" >&2; exit 1; }
  done
  local depends_on_joined=""
  [ "${#depends_on_stems[@]}" -eq 0 ] || depends_on_joined="$(IFS=,; echo "${depends_on_stems[*]}")"

  local repo_dir="$CODE_DIR/$repo"
  [ -d "$repo_dir/.git" ] || { echo "wb new: $repo_dir is not a git repo" >&2; exit 1; }

  if [ "$planned_flag" = 1 ]; then
    # W13's planned-preserving creation path: no worktree, no tmux session —
    # just a lock-guarded, idempotent task-file seed via wb_seed_task_planned
    # (above) that preserves `status: planned` (never the ordinary
    # planned->doing flip cmd_new's normal path below performs) and never
    # stamps `worktree:` to a path that doesn't exist yet. This is the verb
    # /weekly-review (scratch tasks with no work started) and /handoff's
    # seeding step (the real doing/worktree transition happens later, for
    # real, whenever something actually calls `wb new [--agent]` on the same
    # repo/slug) both shell out to instead of an Edit-tool task-file write.
    # Prints the resolved task-file path on stdout (the one piece of output
    # a caller capturing `$(wb new --planned ...)` needs), mirroring
    # wb_seed_task_planned's own `echo "$file"` convention.
    #
    # A `## Plan` body (--body -/--body-file, jira or not) lands on a new file, and
    # --jira <url> extends this path (KTD3) for wb-breakdown's ticket-parent
    # seeding: stamps `jira:` — an extension of this same locked seed, never
    # a duplicate path.
    # wb_seed_task_planned's own fill-blanks-only semantics already give
    # KTD9's find-or-create behavior for free (an existing task at this
    # stem is reused, never overwritten).
    local task_file; task_file="$(wb_task_file "$repo" "$disp_slug")"
    local was_new=0; [ -f "$task_file" ] || was_new=1
    _wb_lock_trap_append_if_top_level wb_task_lock_release_all
    wb_task_lock_acquire_guarded "$task_file" || exit $?
    local seed_status="planned"; [ "$prospective_flag" = 1 ] && seed_status="prospective"
    task_file="$(wb_seed_task_planned "$repo" "$slug" "$parent_ref" "$title_override" "$seed_status")"
    # --depends-on: explicit wins. depends_on: is what a later plain
    # `wb new` reads to stack the branch on its blocker
    # (_wb_new_start_point), so dropping it here silently unstacks it.
    [ -z "$depends_on_joined" ] || wb_set_frontmatter "$task_file" depends_on "$depends_on_joined"
    [ -z "$jira_url" ] || wb_set_frontmatter "$task_file" jira "$jira_url"
    # The ## Plan body comes ONLY from an explicit --body - (stdin) or
    # --body-file <path>; without either flag stdin is never touched (an
    # implicit read hung/swallowed input for non-tty callers such as a
    # `while read … done < file` loop). The body lands only on a genuinely
    # NEW file — KTD9's "reused fill-blanks-only, never overwritten" covers
    # the body too, so re-running against an already-seeded task never
    # duplicates it under ## Plan. --body - still consumes stdin on an
    # existing file. Empty/whitespace-only input inserts nothing
    # (_wb_insert_plan_body's own guard).
    local ticket_body=""
    if [ "$body_stdin" = 1 ]; then
      ticket_body="$(cat)"
    elif [ -n "$body_file" ]; then
      ticket_body="$(cat "$body_file")" \
        || { wb_task_lock_release "$task_file"; echo "wb new: could not read --body-file '$body_file'" >&2; exit 1; }
    fi
    [ "$was_new" = 1 ] && [ -n "$ticket_body" ] && _wb_insert_plan_body "$task_file" "$ticket_body"
    wb_task_lock_release "$task_file"
    echo "$task_file"
    return 0
  fi

  # The git branch is the task file's pre-set `branch:` when there is one
  # (see _wb_new_add_worktree), else the slug. The worktree directory and the
  # session name stay slug-based — except on a resume/picker re-entry
  # (_WB_TASK_FILE_OVERRIDE), which passes the BRANCH as <slug>: there the
  # task file's own worktree: names the directory, or an adopted
  # feat/foo-style branch would resolve to a different path and session than
  # the ones the task was started under.
  local own_file="${_WB_TASK_FILE_OVERRIDE:-$(wb_task_file "$repo" "$disp_slug")}"
  local branch="$slug" wt_slug="$slug" add_slug="$slug" preset wt_field wt_unsafe=0
  if [ -f "$own_file" ]; then
    preset="$(wb_get_frontmatter "$own_file" branch)"
    read -r preset <<< "$preset"
    [ -z "$preset" ] || branch="$preset"
    if [ -n "${_WB_TASK_FILE_OVERRIDE:-}" ]; then
      # The override path's <slug> argument is the BRANCH, so derive the real
      # slug from the task file's own stem (<repo>--<slug>.md): it names the
      # directory/session when worktree: is blank or unusable, and is what
      # _wb_new_add_worktree compares against the branch — making picker/
      # resume re-entry identical to `wb new <repo> <slug>` (adoption,
      # remote tracking included).
      local stem_slug; stem_slug="$(basename -- "$own_file" .md)"
      stem_slug="${stem_slug#"${repo}--"}"
      [ -z "$stem_slug" ] || { wt_slug="$stem_slug"; add_slug="$stem_slug"; }
      wt_field="$(wb_get_frontmatter "$own_file" worktree)"
      read -r wt_field <<< "$wt_field"
      if [ -z "$wt_field" ]; then
        :
      elif _wb_safe_worktree_field "$wt_field"; then
        wt_slug="${wt_field#.worktrees/}"
      else
        wt_unsafe=1
        echo "wb new: warning: ignoring worktree: '$wt_field' (must be .worktrees/<name>, no '..' segments) — using .worktrees/$wt_slug" >&2
      fi
    fi
  fi
  local session="${repo}--$(wb_sanitize "$wt_slug")"
  local worktree_rel=".worktrees/$wt_slug"
  local worktree_path="$repo_dir/$worktree_rel"

  if [ ! -d "$worktree_path" ]; then
    _wb_new_add_worktree "$repo_dir" "$repo" "$add_slug" "$branch" "$worktree_path" "$own_file" "$depends_on_joined" \
      || exit 1
  fi

  # Unconditional, for the same self-healing reason as the ignore rule
  # below: a worktree whose dir already existed (ce-worktree, a manual
  # `git worktree add`, a half-finished earlier `wb new`) would otherwise
  # never get bootstrapped. wb_bootstrap skips entries already present, so
  # re-running it is a no-op. Best-effort for the same `set -e` reason.
  wb_bootstrap "$repo_dir" "$worktree_path" \
    || echo "wb new: warning: bootstrap of gitignored files into $worktree_path failed (continuing)" >&2

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
  task_file="$(wb_seed_task "$repo" "$slug" "$worktree_rel" "$parent_ref" "${_WB_TASK_FILE_OVERRIDE:-}" "$depends_on_joined")"
  # An unsafe worktree: was ignored above; fix the field too, since wb down /
  # wb done would otherwise build a teardown path from it.
  [ "$wt_unsafe" = 0 ] || wb_set_frontmatter "$task_file" worktree "$worktree_rel"
  wb_task_lock_release "$task_file"

  # Task-family CONCEPTS.md seed (D2 pivot from a hook to seed-automation —
  # see _wb_seed_concepts_file above). Runs on every call, same
  # unconditional/self-healing/best-effort convention as the queue-file
  # ignore registration just above: covers pre-existing worktrees, a
  # reparent, or a freshly-added CONCEPTS.md on a plain re-run of `wb new`.
  _wb_seed_concepts_file "$task_file" "$worktree_path" \
    || echo "wb new: warning: could not write CLAUDE.local.md concepts pointer for $task_file (continuing)" >&2

  local is_new=0
  tmux has-session -t "=$session" 2>/dev/null || is_new=1
  tmux_ensure_session "$session" "$worktree_path"
  # A session-only "=name" target (no window/pane part) confuses set-option's
  # pane-target parser on tmux 3.4 ("no such session") even though the session
  # exists — a trailing colon keeps the exact match (lib.sh's =name convention)
  # while giving it a valid target-pane shape.
  tmux set-option -t "=$session:" @wb_repo "$repo" >/dev/null
  tmux set-option -t "=$session:" @wb_slug "$wt_slug" >/dev/null
  # The real git branch, for branch-keyed lookups (wb_board_live_session_for):
  # @wb_slug is the worktree slug, which differs from branch: on an adopted
  # task (feat/x in .worktrees/feat-x or a stem-named dir).
  tmux set-option -t "=$session:" @wb_branch "$branch" >/dev/null
  tmux set-option -t "=$session:" @task "$task_file" >/dev/null
  if [ "$is_new" = 1 ]; then
    # R9/U4: resolve what the agent window should pre-type. Only ever
    # `claude --resume <id>` (wb_resume_id, U2) when a real transcript
    # exists on disk for THIS worktree, or nothing at all for a genuinely
    # new task — there is deliberately no `--continue` fallback, because
    # `--continue`'s own resolution is scoped to the exact same directory
    # wb_transcript_dir hashes (its header comment: "verified against this
    # very worktree"), which is precisely what wb_resume_id/wb_transcripts
    # already checked. If wb_resume_id found nothing, `--continue` run
    # from this same worktree finds nothing either — there's no signal
    # (a Handoffs "### " line, claude_sessions: non-empty) that changes
    # that, because none of them speak to whether a transcript exists in
    # THIS specific directory right now.
    #
    # This used to guess `--continue` from two different weaker signals in
    # turn, and both misfired live in exactly this way: first "any Handoffs
    # ### line" (wb_append_handoff stamps that same "### ... (auto)" shape
    # for `wb set`/`wb status`/`wb breakdown`, none of which imply a real
    # session), then "claude_sessions: non-empty" (the field can be
    # populated from an earlier session whose transcript no longer exists
    # under THIS worktree path — reported live as `claude --continue`
    # failing the same way for a be--monorepo task). Both guesses produced
    # "No conversation found to continue" with `--agent`'s auto-Enter,
    # boot-ready never appearing, and handoff.sh's poller timing out.
    local agent_cmd="" resume_id
    resume_id="$(wb_resume_id "$task_file" "$worktree_path")"
    if [ -n "$resume_id" ]; then
      agent_cmd="claude --resume $resume_id"
    fi
    wb_layout_session "$session" "$worktree_path" "$agent_flag" "$agent_cmd"
  fi

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

# _wb_gh_pr_list <repo_dir> <branch> <state> — raw `gh pr list --json
# number` output for <branch>/<state>. Falls back from `gh` to a personal
# PAT (mirroring the `pgh` shell function in ~/.zshrc — reimplemented
# inline since wb.sh is bash and pgh is a zsh function, not a standalone
# binary an agent's Bash tool could see) when the Sportable-scoped token
# can't see the repo. Prints the raw gh output and returns gh's own final
# exit code — callers decide how to read it. Shared by wb_pr_merge_status
# and wb_branch_has_open_pr (U3/KTD6) so the fallback lives in one place.
_wb_gh_pr_list() {
  local repo_dir="$1" branch="$2" state="$3" out rc
  out="$(cd "$repo_dir" && timeout 10 gh pr list --head "$branch" --state "$state" --json number 2>&1)"; rc=$?
  if [ "$rc" -ne 0 ] && printf '%s' "$out" | grep -qi 'could not resolve to a repository'; then
    out="$(cd "$repo_dir" && GH_TOKEN="$(secret-tool lookup service gh account personal 2>/dev/null)" timeout 10 gh pr list --head "$branch" --state "$state" --json number 2>&1)"; rc=$?
  fi
  printf '%s' "$out"
  return "$rc"
}

# wb_pr_merge_status <repo_dir> <branch> — "merged" | "not-merged" | "unknown"
# for <branch>'s most recent PR. Hard rule: never silently drop a finding —
# a gh/pgh failure reports "unknown" rather than omitting the row entirely.
wb_pr_merge_status() {
  local repo_dir="$1" branch="$2" out rc
  out="$(_wb_gh_pr_list "$repo_dir" "$branch" merged)"; rc=$?
  if [ "$rc" -ne 0 ]; then
    echo unknown
    return
  fi
  if printf '%s' "$out" | grep -q '"number"'; then echo merged; else echo not-merged; fi
}

# wb_branch_has_open_pr <repo_dir> <branch> — exit 0 when <branch> has an
# open PR, exit 1 otherwise, including "couldn't tell" (KTD6): any gh/pgh
# failure degrades to "no PR" rather than blocking `wb down`/`wb pr-open`,
# with one stderr line so the degradation is visible, not silent. Exposed
# as `wb pr-open` (cmd_pr_open) so a skill's Bash tool — which can't see
# the zsh `pgh` fallback function — can still ask the question.
wb_branch_has_open_pr() {
  local repo_dir="$1" branch="$2" out rc
  out="$(_wb_gh_pr_list "$repo_dir" "$branch" open)"; rc=$?
  if [ "$rc" -ne 0 ]; then
    echo "wb: could not check PR status for '$branch' (gh unavailable/unauthenticated) — treating as no open PR" >&2
    return 1
  fi
  printf '%s' "$out" | grep -q '"number"'
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

# wb_reconcile_collect_duplicates — one TSV line per duplicate finding, in a
# SINGLE awk pass over every task file's frontmatter (no per-file fork: this
# runs on every /weekly-review over the whole store). Report-only; kept apart
# from wb_reconcile_collect so the review-doc generator, whose actions only
# make sense for orphan/missing rows, never sees these. Done tasks are
# ignored throughout (a finished task legitimately keeps its old branch/jira).
# Fields: kind=duplicate  class  repo  key  task-file path(s), comma-joined
#   class jira:     key = the Jira key, on 2+ non-done tasks (any repos; repo
#                   = the distinct repos, comma-joined)
#   class branch:   key = branch, claimed by 2+ non-done tasks of one repo
#   class worktree: key = worktree(rel), same rule as branch
#   class prefix:   key = task-file basename whose name doubles its repo
#                   prefix (<repo>--<repo>--...); one path
# Same-commit sharing is deliberately NOT flagged: two branches can
# legitimately share a base commit before diverging.
wb_reconcile_collect_duplicates() {
  local -a files=()
  mapfile -t files < <(wb_task_files)
  [ "${#files[@]}" -gt 0 ] || return 0
  awk '
    function val(line, key,    v) {
      v = line; sub("^" key ":[ \t]*", "", v)
      sub(/[ \t]+#.*$/, "", v); sub(/^#.*$/, "", v); sub(/[ \t]+$/, "", v)
      return v
    }
    # explicit if/else: mawk creates arr[k] before the RHS ternary runs
    function addm(arr, k, i) { if (k in arr) arr[k] = arr[k] " " i; else arr[k] = i }
    # Same family: one is the other parent: (stem), or they share a parent.
    function fam(x, y) {
      return (tpar[x] != "" && tpar[x] == tstem[y]) || (tpar[y] != "" && tpar[y] == tstem[x]) \
          || (tpar[x] != "" && tpar[x] == tpar[y])
    }
    # Report a group of task indices only when 2+ of them have a partner
    # outside their own family; the report lists exactly those tasks.
    function group(cls, repos, key, mem,    n, m, i, j, keep, list, nk, rl, r) {
      n = split(mem, m, " ")
      for (i = 1; i <= n; i++) for (j = 1; j <= n; j++)
        if (i != j && !fam(m[i], m[j])) keep[m[i]] = 1
      nk = 0; list = ""; rl = ""
      for (i = 1; i <= n; i++) {
        if (!(m[i] in keep)) continue
        nk++; list = (list == "" ? tfile[m[i]] : list "," tfile[m[i]])
        r = trepo[m[i]]
        if (index("," rl ",", "," r ",") == 0) rl = (rl == "" ? r : rl "," r)
      }
      if (nk < 2) return
      printf "duplicate\t%s\t%s\t%s\t%s\n", cls, (repos == "" ? rl : repos), key, list
    }
    function flush(    base, jk, k, v, nt, toks, t, seenk, idx) {
      if (file == "" || status == "done") return
      base = file; sub(/^.*\//, "", base); sub(/\.md$/, "", base)
      idx = ++ntask
      tfile[idx] = file; tstem[idx] = base; trepo[idx] = repo
      v = parent; gsub("[\"\047]", "", v); sub(/\.md$/, "", v); tpar[idx] = v
      if (repo != "" && index(base, repo "--" repo "--") == 1)
        printf "duplicate\tprefix\t%s\t%s\t%s\n", repo, base, file
      if (jira != "") {
        # A jira: value may carry several keys ("SFB-1, SFB-2"), quotes, or
        # URLs: strip quotes, split on commas/whitespace, normalise each
        # token to its KEY-N, and count every distinct key on its own.
        v = jira; gsub("[\"\047]", "", v)
        nt = split(v, toks, /[, \t]+/)
        delete seenk
        for (t = 1; t <= nt; t++) {
          if (toks[t] == "") continue
          jk = toks[t]
          if (match(jk, /[A-Za-z][A-Za-z0-9]*-[0-9]+/)) jk = toupper(substr(jk, RSTART, RLENGTH))
          if (jk in seenk) continue
          seenk[jk] = 1
          if (!(jk in jm)) jorder[++nj] = jk
          addm(jm, jk, idx)
        }
      }
      if (repo != "" && branch != "") {
        k = repo SUBSEP branch
        if (!(k in bm)) border[++nb] = k
        addm(bm, k, idx)
      }
      if (repo != "" && worktree != "") {
        k = repo SUBSEP worktree
        if (!(k in wm)) worder[++nw] = k
        addm(wm, k, idx)
      }
    }
    FNR == 1 { flush(); file = FILENAME; status = repo = branch = worktree = jira = parent = ""; infm = ($0 == "---") }
    # frontmatter opens only on line 1 (like the other wb.sh parsers); a later --- is body
    /^---$/ { if (infm == 1 && FNR > 1) infm = 2; next }
    infm == 1 {
      if ($0 ~ /^status:/)        status   = val($0, "status")
      else if ($0 ~ /^repo:/)     repo     = val($0, "repo")
      else if ($0 ~ /^branch:/)   branch   = val($0, "branch")
      else if ($0 ~ /^worktree:/) worktree = val($0, "worktree")
      else if ($0 ~ /^jira:/)     jira     = val($0, "jira")
      else if ($0 ~ /^parent:/)   parent   = val($0, "parent")
    }
    END {
      flush()
      for (i = 1; i <= nj; i++) { k = jorder[i]; group("jira", "", k, jm[k]) }
      for (i = 1; i <= nb; i++) { k = border[i]; split(k, a, SUBSEP); group("branch", a[1], a[2], bm[k]) }
      for (i = 1; i <= nw; i++) { k = worder[i]; split(k, a, SUBSEP); group("worktree", a[1], a[2], wm[k]) }
    }
  ' "${files[@]}"
}

cmd_reconcile() {
  case "${1:-}" in
    --review)  shift; wb_reconcile_generate_review "$@"; return ;;
    --apply)   shift; wb_reconcile_apply "$@"; return ;;
    # R28/KTD5: publish wb_reconcile_collect's existing TSV verbatim rather
    # than reshaping it — a caller (the weekly review, U7) parses THIS,
    # never wb_reconcile_collect directly, so a future internal refactor of
    # that function has one public contract to keep, not every caller. The
    # fifth field is NOT one thing (see wb_reconcile_collect's own header):
    # orphan rows carry a merge status there, missing rows a task-file path
    # — a caller that assumes a single field-five meaning misreads one kind
    # as the other. Read-only, same as the human-readable mode below.
    # duplicate rows (a third kind, report-only) follow: field two is the
    # class (jira|branch|worktree|prefix) and the fifth a comma-joined list
    # of task-file paths — see wb_reconcile_collect_duplicates.
    --machine) shift; wb_reconcile_collect; wb_reconcile_collect_duplicates; return ;;
  esac

  local -a orphan_rows=() missing_rows=() dup_rows=()
  local line kind repo branch worktree extra tf dtasks=""
  local -a f tfs
  while IFS= read -r line; do
    wb_tsv_split "$line" f
    kind="${f[0]}"; repo="${f[1]}"; branch="${f[2]}"; worktree="${f[3]}"; extra="${f[4]}"
    if [ "$kind" = orphan ]; then
      orphan_rows+=("$repo"$'\t'"$branch"$'\t'"$worktree"$'\t'"$extra")
    else
      missing_rows+=("$repo"$'\t'"$worktree"$'\t'"$(basename "$extra" .md)")
    fi
  done < <(wb_reconcile_collect)
  while IFS= read -r line; do
    wb_tsv_split "$line" f
    # f = duplicate <class> <repo> <key> <comma-joined task paths>
    IFS=, read -r -a tfs <<<"${f[4]}"
    dtasks=""
    for tf in "${tfs[@]}"; do dtasks+="${dtasks:+, }$(basename "$tf" .md)"; done
    dup_rows+=("${f[1]}"$'\t'"${f[2]}"$'\t'"${f[3]}"$'\t'"$dtasks")
  done < <(wb_reconcile_collect_duplicates)

  if [ "${#orphan_rows[@]}" -eq 0 ] && [ "${#missing_rows[@]}" -eq 0 ] && [ "${#dup_rows[@]}" -eq 0 ]; then
    echo "wb reconcile: no drift found"
    return 0
  fi

  if [ "${#orphan_rows[@]}" -gt 0 ]; then
    echo "Orphaned worktrees (no matching task file):"
    { printf 'REPO\tBRANCH\tWORKTREE\tMERGE-STATUS\n'; printf '%s\n' "${orphan_rows[@]}"; } | column -t -s $'\t'
    { [ "${#missing_rows[@]}" -gt 0 ] || [ "${#dup_rows[@]}" -gt 0 ]; } && echo
  fi

  if [ "${#missing_rows[@]}" -gt 0 ]; then
    echo "Tasks referencing a missing worktree:"
    { printf 'REPO\tWORKTREE\tTASK\n'; printf '%s\n' "${missing_rows[@]}"; } | column -t -s $'\t'
    [ "${#dup_rows[@]}" -gt 0 ] && echo
  fi

  if [ "${#dup_rows[@]}" -gt 0 ]; then
    echo "Duplicate task claims (report-only):"
    { printf 'CLASS\tREPO\tKEY\tTASKS\n'; printf '%s\n' "${dup_rows[@]}"; } | column -t -s $'\t'
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

# _wb_bd_bullet <block-text> <key> — the value of the block's first
# `- <key>: <value>` bullet (the editable per-child fields: goal, size,
# depends_on); empty when the bullet is absent or has no value.
#
# Only the block HEADER is searched — everything before the block's
# `begin-plan` marker. The plan body is free-form markdown that may itself
# contain a line like `- depends_on: …` or `- size: …`, and a header bullet
# left blank (the default, per SKILL.md's blank-unless-verified rule) must
# not fall through to it. GNU grep -o prints nothing for an empty match, so
# a `\K.*`-style extraction over the whole block did exactly that
# fall-through — the first matching LINE has to win, value or not. Trailing
# whitespace is trimmed.
_wb_bd_bullet() {
  printf '%s\n' "$1" \
    | awk '/<!-- wb-breakdown: begin-plan/ { exit } { print }' \
    | grep -P "^\s*-\s+$2:" | head -1 \
    | sed -E "s/^[[:space:]]*-[[:space:]]+$2:[[:space:]]*//; s/[[:space:]]*$//" || true
}

# _wb_bd_resolve_deps <repo> <deps_raw> — turn a buffer's raw `- depends_on:`
# value into the comma-joined `<repo>--<slug>` stem list the frontmatter
# stores. Split on commas; per token strip backticks + edge whitespace and
# skip empties; a token already containing `--` is a full stem (an external
# or cross-repo dep) kept verbatim; a bare token is a sibling's RAW slug and
# becomes <repo>--<wb_sanitize(token)> — the same raw-slug-resolved-at-apply
# convention migrate/move targets use. NO existence check (D2/R4): a
# same-apply sibling needn't be seeded yet, and the board already fails open
# on a dangling depends_on: (README "Dependencies").
#
# Shape checks live here too, so the validator (which calls this once,
# discarding stdout, to turn a bad token into a hard parse error) and the
# executor (which keeps the stdout) can never disagree on what's legal:
# no interior whitespace in a token (wb_sanitize strips none, mirroring the
# create-child slug rule), no `..`, a full stem may not contain `/` (it's
# used verbatim as a filename stem — a bare slug's `/` is fine, it
# sanitizes to `-`), and the RESOLVED stem must stay within
# [A-Za-z0-9_.-] — the same charset the parent marker's repo= field is
# held to. That last check is load-bearing, not cosmetic: the stem is fed
# to wb_set_frontmatter's `awk -v`, which interprets backslash escapes, so
# an unfiltered `\n` would inject a second frontmatter line into the child.
# Returns 1 with the reason on stderr.
_wb_bd_resolve_deps() {
  local repo="$1" raw="$2" out="" tok
  local -a toks
  IFS=',' read -r -a toks <<< "$raw"
  for tok in "${toks[@]}"; do
    tok="${tok//\`/}"
    tok="${tok#"${tok%%[![:space:]]*}"}"; tok="${tok%"${tok##*[![:space:]]}"}"
    [ -n "$tok" ] || continue
    if [[ "$tok" == *[[:space:]]* ]]; then
      echo "token '$tok' contains whitespace (one backticked slug or <repo>--<slug> stem per comma)" >&2; return 1
    fi
    if [[ "$tok" == *..* ]]; then
      echo "token '$tok' contains '..'" >&2; return 1
    fi
    case "$tok" in
      *--*)
        if [[ "$tok" == */* ]]; then
          echo "full stem '$tok' must not contain '/'" >&2; return 1
        fi ;;
      *) tok="$repo--$(wb_sanitize "$tok")" ;;
    esac
    if [[ "$tok" =~ [^A-Za-z0-9_.-] ]]; then
      echo "token '$tok' has characters outside [A-Za-z0-9_.-]" >&2; return 1
    fi
    out="${out:+$out,}$tok"
  done
  printf '%s' "$out"
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
  local parent_stem="" seen_ns="" mig_count=0 mig_lines="" approve_count=0
  for b in "${blocks[@]}"; do
    kind="$(_wb_bd_field "$b" block)"
    parent="$(_wb_bd_field "$b" parent)"

    if [ -z "$parent_stem" ]; then
      parent_stem="$parent"
    elif [ "$parent" != "$parent_stem" ]; then
      echo "wb breakdown --apply: buffer references more than one parent ($parent_stem and $parent) — a breakdown buffer is single-parent" >&2
      return 2
    fi

    if [ "$kind" = approve ]; then
      # No plan body on this block — validate its own checkbox line for
      # malformed-ness (never silently "none"), then move on; the actual
      # checked/unchecked state is read separately by wb_breakdown_apply
      # (approve is a run-level gate, not a create/migrate/move action row).
      approve_count=$((approve_count + 1))
      if [ "$approve_count" -gt 1 ]; then
        echo "wb breakdown --apply: more than one Approve block in this buffer — a run-level gate must be singular, never silently pick one" >&2
        return 2
      fi
      local aline; aline="$(printf '%s' "$b" | grep -P '^\s*[-*]\s*\[' | head -1)"
      local astate; astate="$(_wb_bd_checkbox_state "$aline")"
      if [ "$astate" = malformed ]; then
        echo "wb breakdown --apply: malformed checkbox on the Approve line: $aline" >&2
        return 2
      fi
      continue
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

      # repo= is a marker field, not a checkbox-line value like raw_slug, so
      # it never went through the whitespace/backtick check above — but it
      # feeds the exact same wb_task_file path-construction (and, once the
      # child is seeded, its own repo: frontmatter, which cmd_new/cmd_resume/
      # cmd_done later trust to build repo_dir="$CODE_DIR/$repo" for real git
      # worktree operations). A repo value containing `/` or `..` would
      # write/read outside $TASKS_DIR / $CODE_DIR entirely — restrict it to
      # a plain repo basename, the same charset real repo directory names
      # actually use (alphanumeric, `-`, `_`, `.`, including the `--` this
      # store's own cross-repo naming convention relies on).
      local repo_field; repo_field="$(_wb_bd_field "$b" repo)"
      if [ -z "$repo_field" ] || [[ "$repo_field" == *[/]* ]] || [[ "$repo_field" == *..* ]] || [[ "$repo_field" =~ [^A-Za-z0-9_.-] ]]; then
        echo "wb breakdown --apply: child n=$n's repo=$repo_field is missing or unsafe (must be a plain repo basename — no / or ..): $(printf '%s' "$b" | head -1)" >&2
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

    local raw_slug disp_slug title size deps_raw
    raw_slug="$(printf '%s' "$create_line" | grep -oP 'create child: `\K[^`]*')"
    disp_slug="$(wb_sanitize "$raw_slug")"
    title="$(_wb_bd_bullet "$b" goal)"
    # `- size:` / `- depends_on:` are optional sibling bullets of `- goal:`
    # (D1). A missing or blank bullet is fine (blank size reads as M); a
    # NON-empty size outside the XS|S|M|L|XL enum is a hard parse error —
    # whole-apply abort, like the block's other structural guards — never a
    # silently-dropped value. depends_on is passed through RAW here; the
    # execute side resolves slugs to stems (_wb_bd_resolve_deps).
    size="$(_wb_bd_bullet "$b" size)"
    deps_raw="$(_wb_bd_bullet "$b" depends_on)"
    if ! _wb_valid_size "$size"; then
      echo "wb breakdown --apply: child n=$n ($raw_slug) size '$size' is not one of $WB_SIZE_VALUES (or blank)" >&2
      return 2
    fi
    local deps_err
    if ! deps_err="$(_wb_bd_resolve_deps "$repo" "$deps_raw" 2>&1 >/dev/null)"; then
      echo "wb breakdown --apply: child n=$n ($raw_slug) depends_on: $deps_err" >&2
      return 2
    fi
    # A literal tab in any bullet value would split the tab-separated create
    # row below and shift every later field (a tabbed goal lands its tail in
    # the size slot, past the enum check above) — hard parse error, like the
    # other structural guards.
    case "$title$size$deps_raw" in
      *$'\t'*)
        echo "wb breakdown --apply: child n=$n ($raw_slug) goal/size/depends_on must not contain a tab character" >&2
        return 2 ;;
    esac

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
      # KTD5 idempotent re-apply: an existing file already claimed by THIS
      # parent (a prior run created it) is "already created, skipping" —
      # not a real collision, just convergence. Anything else (a genuine
      # collision with an unrelated file) keeps the generic message.
      if [ "$(wb_get_frontmatter "$TASKS_DIR/$repo--$disp_slug.md" parent)" = "$parent_stem" ]; then
        echo "wb breakdown --apply: child n=$n ($raw_slug) -> $repo--$disp_slug already created, skipping" >&2
      else
        echo "wb breakdown --apply: skipping child n=$n ($raw_slug) — $repo--$disp_slug already exists in the store" >&2
      fi
      continue
    fi

    confirmed_child_stems+=("$repo--$disp_slug")
    # 8 tab fields: create⇥n⇥repo⇥raw⇥disp⇥title⇥size⇥deps_raw. The last two
    # are usually empty — wb_tsv_split keeps trailing empty
    # fields in place, so the execute side's f[6]/f[7] reads stay positional.
    printf 'create\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$n" "$repo" "$raw_slug" "$disp_slug" "$title" "$size" "$deps_raw"
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
      # `[^"]*` used to stop at the first double quote, so a bullet
      # containing one could never be moved — the buffer's own checkbox
      # line has nowhere to put that quote unescaped without prematurely
      # closing the "..." span. `(?:\\"|[^"])*` accepts a backslash-escaped
      # `\"` as part of the quoted span instead of ending it, then the sed
      # below undoes the escaping so $move_text matches the ACTUAL
      # (unescaped) bullet text in ## Follow-ups.
      move_text="$(printf '%s' "$line" | grep -oP 'move follow-up: "\K(?:\\"|[^"])*' | sed 's/\\"/"/g')"
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
_wb_breakdown_buffer_parent() {
  grep -oP '(?<= )parent=\K[^ ]+' "$1" 2>/dev/null | head -1
}

# _wb_breakdown_child_plan_body <path> <n> / _wb_breakdown_parent_plan_body
# <path> — re-parse the buffer to pull ONE block's plan body on demand.
# Re-parsing (rather than threading multi-line bodies through the TSV
# action rows) keeps _wb_breakdown_validate's stdout contract flat and
# grep-able; these buffers are small local files, not a perf concern.
_wb_breakdown_child_plan_body() {
  local path="$1" want_n="$2"
  local -a blocks=(); _wb_breakdown_parse_blocks "$path" blocks
  local b
  for b in "${blocks[@]}"; do
    [ "$(_wb_bd_field "$b" block)" = child ] || continue
    [ "$(_wb_bd_field "$b" n)" = "$want_n" ] || continue
    _wb_bd_plan_body "$b"
    return 0
  done
}

_wb_breakdown_parent_plan_body() {
  local path="$1"
  local -a blocks=(); _wb_breakdown_parse_blocks "$path" blocks
  local b
  for b in "${blocks[@]}"; do
    [ "$(_wb_bd_field "$b" block)" = parent ] || continue
    _wb_bd_plan_body "$b"
    return 0
  done
}

# _wb_breakdown_replace_section <file> <heading> <body> — REPLACE
# everything under "## <heading>" (up to the next "## " heading or EOF)
# with <body>. Never routes <body> through awk -v — same reasoning as
# _wb_insert_plan_body: awk's C escape-sequence processing on a -v
# assignment would mangle a buffer-authored body's backslashes.
# Trailing blank lines in <body> are dropped and exactly one blank line is
# re-emitted before the next heading: a heading left flush against the body
# fails _wb_append_under_heading's blank-line guard, and the next
# wb_append_handoff then splices in a duplicate "## Handoffs".
# Only the FIRST "## <heading>" is replaced: a second copy (a duplicated
# heading) is left untouched --
# re-matching it after bodyfile is drained would re-emit the heading bare and
# drop that copy's original content.
_wb_breakdown_replace_section() {
  local file="$1" heading="$2" body="$3" bodyfile
  bodyfile="$(mktemp)"
  printf '%s\n' "$body" > "$bodyfile"
  awk -v h="## $heading" -v bodyfile="$bodyfile" '
    BEGIN { insec = 0; replaced = 0 }
    $0 == h && !replaced {
      replaced = 1
      print; print ""
      nblank = 0
      while ((getline line < bodyfile) > 0) {
        if (line == "") { nblank++; continue }
        for (; nblank > 0; nblank--) print ""
        print line
      }
      insec = 1; next
    }
    insec && /^## / { insec = 0; print "" }
    insec { next }
    { print }
  ' "$file" > "$file.tmp.$$" && mv "$file.tmp.$$" "$file"
  rm -f "$bodyfile"
}

# _wb_breakdown_append_section <file> <heading> <body> — append <body>
# right after "## <heading>" — same insertion point wb_reconcile_merge_content
# already uses (never at the end of existing content). File-based, not
# awk -v, for the same backslash-fidelity reason as every other body
# insertion in this feature.
_wb_breakdown_append_section() {
  local file="$1" heading="$2" body="$3" bodyfile
  bodyfile="$(mktemp)"
  printf '%s\n' "$body" > "$bodyfile"
  awk -v h="## $heading" -v bodyfile="$bodyfile" '
    { print }
    $0 == h { while ((getline line < bodyfile) > 0) print line }
  ' "$file" > "$file.tmp.$$" && mv "$file.tmp.$$" "$file"
  rm -f "$bodyfile"
}

# _wb_breakdown_move_followup <parent_file> <target_file> <bullet_text> —
# R11's "a move, never a copy": relocates the bullet line "- <bullet_text>"
# (or "* <bullet_text>") PLUS any immediately-following indented
# continuation lines from <parent_file>'s ## Follow-ups to <target_file>'s.
# <bullet_text> is compared via a getline-read value, never awk -v, so a
# bullet containing backslashes still matches correctly (the same class of
# bug U1's Execution note flags for -v assignments).
_wb_breakdown_move_followup() {
  local parent_file="$1" target_file="$2" bullet_text="$3"
  local textfile; textfile="$(mktemp)"
  printf '%s\n' "$bullet_text" > "$textfile"

  local block
  block="$(awk -v textfile="$textfile" '
    BEGIN { getline want < textfile; close(textfile) }
    /^## Follow-ups/ { infu = 1; next }
    /^## / { if (infu) infu = 0 }
    infu && inblock && /^[-*] / { inblock = 0 }
    infu && !inblock && ($0 == "- " want || $0 == "* " want) { inblock = 1; print; next }
    infu && inblock { print }
  ' "$parent_file")"
  [ -n "$block" ] || return 1

  awk -v textfile="$textfile" '
    BEGIN { getline want < textfile; close(textfile) }
    /^## Follow-ups/ { infu = 1; print; next }
    /^## / { if (infu) infu = 0 }
    infu && inblock && /^[-*] / { inblock = 0 }
    infu && !inblock && ($0 == "- " want || $0 == "* " want) { inblock = 1; next }
    infu && inblock { next }
    { print }
  ' "$parent_file" > "$parent_file.tmp.$$" && mv "$parent_file.tmp.$$" "$parent_file"
  rm -f "$textfile"

  _wb_breakdown_append_section "$target_file" "Follow-ups" "$block"
}

# _wb_breakdown_acquire_locks <array_name> <target...> — sorted-path,
# all-or-nothing acquisition (KTD6): on any failure, releases everything
# already acquired and returns the failing exit code (75); on success,
# populates <array_name> (nameref) with the sorted, deduplicated list
# actually held. MUST be called directly, never via `$(...)`/`<(...)` — a
# process substitution runs in a subshell, and the locks this function
# acquires would die with that subshell the instant it exits, silently
# releasing everything before the caller ever saw the result.
_wb_breakdown_acquire_locks() {
  local -n _wbd_acquired="$1"; shift
  _wbd_acquired=()
  local -a sorted=()
  mapfile -t sorted < <(printf '%s\n' "$@" | sort -u)
  local t rc
  for t in "${sorted[@]}"; do
    # `if cmd; then rc=0; else rc=$?; fi` — the only form that is BOTH safe
    # under this file's `set -e` AND captures the real exit code. Two other
    # shapes look plausible and are both wrong: `if ! cmd; then rc=$?; fi`
    # captures the NEGATED condition's own (always-0) status, not cmd's
    # (wb_reconcile_action_merge's own comment documents that one, caught
    # live by wb-lock-integration.test.sh). `cmd; rc=$?` as bare statements
    # looks right and even reads correctly under this file's OWN test
    # suite — but every test here does `source wb.sh; set +e` before
    # calling into it, which silently disables the exact errexit behavior
    # production hits: a bare failing statement (not an if/while/&&/||
    # condition) triggers `set -e` immediately, aborting the whole PROCESS
    # before `rc=$?` on the next line ever runs. Reproduced live: `set -e;
    # inner() { return 75; }; inner; rc=$?; echo reached` never prints
    # "reached" and exits 75 — confirmed this exact class of bug is what
    # made the "release everything already acquired" loop below
    # unreachable in real (non-test) use.
    if wb_task_lock_acquire_guarded "$t"; then
      rc=0
    else
      rc=$?
    fi
    if [ "$rc" -ne 0 ]; then
      local already
      for already in "${_wbd_acquired[@]}"; do
        wb_task_lock_release "$already"
      done
      _wbd_acquired=()
      return "$rc"
    fi
    _wbd_acquired+=("$t")
  done
  return 0
}

# _wb_breakdown_execute <path> <parent_file> <parent_stem> <actions_tsv> —
# KTD5's write order, run only once every lock in the sorted set is held
# and <actions_tsv> reflects a fresh re-validate against live store state.
# Per-item failures are reported and skipped (reconcile's warn-and-skip
# posture) — never abort the rest of the batch. Prints the migration
# target's file path on its own final line when a migration happened (the
# caller needs it to re-point @task after releasing the locks), empty
# otherwise.
_wb_breakdown_execute() {
  local path="$1" parent_file="$2" parent_stem="$3" actions="$4"
  local parent_repo; parent_repo="$(wb_get_frontmatter "$parent_file" repo)"
  local did_something=0 migration_target_file=""
  local -a created_children=()
  local line

  # 1. seed checked children -------------------------------------------------
  #    Pre-pass: every create row's resolved stem, so a depends_on: naming a
  #    sibling seeded LATER in this same apply (order-independence) isn't
  #    mistaken for a dangling ref by the advisory warning below.
  local all_create_stems=" "
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    local -a f; wb_tsv_split "$line" f
    [ "${f[0]}" = create ] || continue
    all_create_stems="$all_create_stems${f[2]}--${f[4]} "
  done <<< "$actions"

  while IFS= read -r line; do
    [ -n "$line" ] || continue
    local -a f; wb_tsv_split "$line" f
    [ "${f[0]}" = create ] || continue
    local n="${f[1]}" repo="${f[2]}" raw="${f[3]}" disp="${f[4]}" title="${f[5]}" size="${f[6]:-}" deps_raw="${f[7]:-}"
    local deps; deps="$(_wb_bd_resolve_deps "$repo" "$deps_raw")"
    # Advisory only (D2 fail-open): warn, never abort, on a resolved dep
    # that is neither a checked sibling in this buffer nor an existing file.
    local dep; local -a _dep_arr=()
    IFS=, read -r -a _dep_arr <<<"$deps"
    for dep in "${_dep_arr[@]}"; do
      case "$all_create_stems" in *" $dep "*) continue ;; esac
      [ -f "$TASKS_DIR/$dep.md" ] \
        || echo "wb breakdown --apply: warning: child n=$n ($raw) depends_on '$dep' matches neither a checked child in this buffer nor an existing task file (kept as-is; the board fails open on dangling deps)" >&2
    done
    local body; body="$(_wb_breakdown_child_plan_body "$path" "$n")"
    local child_file
    if child_file="$(printf '%s' "$body" | wb_seed_planned_child "$repo" "$raw" "$parent_stem" "$title" "$size" "$deps")"; then
      created_children+=("$(basename "$child_file" .md)")
      did_something=1
    else
      echo "wb breakdown --apply: failed to seed child n=$n ($raw) — skipping" >&2
    fi
  done <<< "$actions"

  # 2. parent content edits: ## Plan rewrite, then follow-up moves ----------
  #    Content-idempotent on re-apply: a rewrite to byte-identical content
  #    (the buffer's checkbox left checked after a prior successful apply)
  #    doesn't count toward did_something, or every re-run would duplicate
  #    the archive+handoff step below for no real new progress.
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    local -a f; wb_tsv_split "$line" f
    [ "${f[0]}" = plan_rewrite ] || continue
    local body; body="$(_wb_breakdown_parent_plan_body "$path")"
    local before_plan; before_plan="$(wb_board_section "$parent_file" "Plan")"
    _wb_breakdown_replace_section "$parent_file" "Plan" "$body"
    local after_plan; after_plan="$(wb_board_section "$parent_file" "Plan")"
    [ "$before_plan" = "$after_plan" ] || did_something=1
  done <<< "$actions"

  while IFS= read -r line; do
    [ -n "$line" ] || continue
    local -a f; wb_tsv_split "$line" f
    [ "${f[0]}" = move ] || continue
    local target_disp="${f[2]}" bullet_text="${f[3]}"
    local target_file="$TASKS_DIR/$parent_repo--$target_disp.md"
    if _wb_breakdown_move_followup "$parent_file" "$target_file" "$bullet_text"; then
      did_something=1
    else
      echo "wb breakdown --apply: failed to move follow-up (\"$bullet_text\") — skipping" >&2
    fi
  done <<< "$actions"

  # 3. migration: child <- parent's branch/worktree, child -> doing, parent
  #    blanked. Exactly one file may claim a worktree at any time. ---------
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    local -a f; wb_tsv_split "$line" f
    [ "${f[0]}" = migrate ] || continue
    local target_disp="${f[2]}"
    local target_file="$TASKS_DIR/$parent_repo--$target_disp.md"
    local p_branch p_worktree
    p_branch="$(wb_get_frontmatter "$parent_file" branch)"
    p_worktree="$(wb_get_frontmatter "$parent_file" worktree)"
    wb_set_frontmatter "$target_file" branch "$p_branch"
    wb_set_frontmatter "$target_file" worktree "$p_worktree"
    [ "$(wb_get_frontmatter "$target_file" status)" != planned ] || wb_set_frontmatter "$target_file" status doing
    wb_set_frontmatter "$parent_file" branch ""
    wb_set_frontmatter "$parent_file" worktree ""
    migration_target_file="$target_file"
    did_something=1
  done <<< "$actions"

  # 4. archive the closed buffer + one handoff entry naming it (KTD5) ------
  #    R6's durable record must outlive gitignored scratch — never skip
  #    this even when the ONLY thing that happened was a plan_rewrite/move.
  if [ "$did_something" = 1 ]; then
    local dossier_dir="$TASKS_DIR/dossiers/$parent_stem"
    mkdir -p "$dossier_dir"
    local archived="$dossier_dir/$(basename "$path")"
    cp -a "$path" "$archived"
    local note="Family split applied via \`wb breakdown --apply\`. Archived buffer: \`${archived#"$HOME"/}\`."
    if [ "${#created_children[@]}" -gt 0 ]; then
      local joined; joined="$(printf '%s, ' "${created_children[@]}")"; joined="${joined%, }"
      note="$note Created: $joined."
    fi
    wb_append_handoff "$parent_file" "wb breakdown" "$note"
  fi

  printf '%s\n' "$migration_target_file"
}

# _wb_breakdown_repoint_task <parent_file> <target_file> — re-points @task
# on every LIVE session whose @task currently equals <parent_file> to
# <target_file> instead (KTD6: after lock release, never inside the
# critical section — a tmux call is not a task-file write). Warns rather
# than errors when nothing matches (a session-less parent, or every
# migrated session already re-pointed by a prior apply).
_wb_breakdown_repoint_task() {
  local parent_file="$1" target_file="$2"
  local session matched=0 cur
  while IFS= read -r session; do
    [ -n "$session" ] || continue
    cur="$(tmux show -t "=$session:" -v @task 2>/dev/null || true)"
    [ "$cur" = "$parent_file" ] || continue
    tmux set-option -t "=$session:" @task "$target_file" >/dev/null
    matched=$((matched + 1))
  done < <(tmux list-sessions -F '#{session_name}' 2>/dev/null || true)
  if [ "$matched" -eq 0 ]; then
    echo "wb breakdown --apply: no live session had @task pointing at $parent_file — nothing to re-point" >&2
  fi
}

# _wb_bd_approve_checked <path> — true (state=checked) if the buffer's
# run-level Approve block is ticked; false for unticked or absent
# (missing entirely is treated as unapproved — the safe default, so an
# older buffer authored before this gate existed never silently applies).
_wb_bd_approve_checked() {
  local path="$1"
  local -a blocks=()
  _wb_breakdown_parse_blocks "$path" blocks
  local b
  for b in "${blocks[@]}"; do
    [ "$(_wb_bd_field "$b" block)" = approve ] || continue
    local aline; aline="$(printf '%s' "$b" | grep -P '^\s*[-*]\s*\[' | head -1)"
    [ "$(_wb_bd_checkbox_state "$aline")" = checked ]
    return
  done
  return 1
}

# wb_breakdown_apply <path> — U3: the full locked apply. Validates twice
# (once to determine the lock set, once more after acquiring it — KTD5's
# "never trust the buffer snapshot"), executes under the sorted multi-lock,
# releases, then re-points @task outside the critical section.
wb_breakdown_apply() {
  local path="${1:-}"
  local pre_out rc
  # `if cmd; then rc=0; else rc=$?; fi`, never a bare `cmd; rc=$?` — see
  # _wb_breakdown_acquire_locks's own comment for why the bare-statement
  # form silently aborts the whole process under this file's `set -e`
  # before `rc=$?` ever runs, masked only by this suite's own `set +e`.
  if pre_out="$(_wb_breakdown_validate "$path")"; then rc=0; else rc=$?; fi
  [ "$rc" -eq 0 ] || return "$rc"

  if ! _wb_bd_approve_checked "$path"; then
    echo "wb breakdown --apply: not approved — the top-level Approve line is unticked, nothing applied"
    return 0
  fi

  if [ -z "$pre_out" ]; then
    echo "wb breakdown --apply: nothing checked — no-op"
    return 0
  fi

  local parent_stem; parent_stem="$(_wb_breakdown_buffer_parent "$path")"
  local parent_file; parent_file="$(wb_resolve_parent_ref "$parent_stem")" || return 2
  local parent_repo; parent_repo="$(wb_get_frontmatter "$parent_file" repo)"

  local -a lock_targets=("$parent_file")
  local line
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    local -a f; wb_tsv_split "$line" f
    case "${f[0]}" in
      create)            lock_targets+=("$TASKS_DIR/${f[2]}--${f[4]}.md") ;;
      migrate|move)       lock_targets+=("$TASKS_DIR/$parent_repo--${f[2]}.md") ;;
    esac
  done <<< "$pre_out"

  _wb_lock_trap_append_if_top_level wb_task_lock_release_all
  local -a acquired=()
  local acquire_rc
  if _wb_breakdown_acquire_locks acquired "${lock_targets[@]}"; then acquire_rc=0; else acquire_rc=$?; fi
  [ "$acquire_rc" -eq 0 ] || return "$acquire_rc"

  # Re-validate against live store state — never trust the buffer snapshot
  # (KTD5): something could have changed in the window between the
  # pre-lock parse above and now.
  local out
  if out="$(_wb_breakdown_validate "$path")"; then rc=0; else rc=$?; fi
  if [ "$rc" -ne 0 ]; then
    local t; for t in "${acquired[@]}"; do wb_task_lock_release "$t"; done
    return "$rc"
  fi
  if ! _wb_bd_approve_checked "$path"; then
    local t; for t in "${acquired[@]}"; do wb_task_lock_release "$t"; done
    echo "wb breakdown --apply: not approved — the top-level Approve line is unticked, nothing applied"
    return 0
  fi
  if [ -z "$out" ]; then
    local t; for t in "${acquired[@]}"; do wb_task_lock_release "$t"; done
    echo "wb breakdown --apply: nothing checked — no-op"
    return 0
  fi

  local migration_target_file
  migration_target_file="$(_wb_breakdown_execute "$path" "$parent_file" "$parent_stem" "$out")"

  local t; for t in "${acquired[@]}"; do wb_task_lock_release "$t"; done

  if [ -n "$migration_target_file" ]; then
    _wb_breakdown_repoint_task "$parent_file" "$migration_target_file"
  fi

  local n_create n_migrate n_move
  n_create="$(printf '%s\n' "$out" | grep -c $'^create\t')"
  n_migrate="$(printf '%s\n' "$out" | grep -c $'^migrate\t')"
  n_move="$(printf '%s\n' "$out" | grep -c $'^move\t')"
  echo "wb breakdown --apply: $n_create child(ren) created, migration: $([ "$n_migrate" -gt 0 ] && echo yes || echo no), $n_move follow-up move(s) applied"
  return 0
}

cmd_breakdown() {
  case "${1:-}" in
    --apply)
      shift
      wb_breakdown_apply "${1:-}"
      ;;
    *)
      echo "usage: wb breakdown --apply <buffer-path>" >&2
      return 1
      ;;
  esac
}

# ---------------------------------------------------------------------------
# wb down / wb pause — close a session without tearing the worktree down
# ---------------------------------------------------------------------------
# Two axes, deliberately kept apart (KTD1): PROGRESS (`status:`, stored,
# changed only by an explicit verb) and ACTIVITY (derived at read time from
# a live tmux session plus Claude's own transcript store for the worktree —
# see wb_transcripts, U2 — never stored). `wb down` is the activity-only
# verb: it closes the session and keeps the worktree, touching `status:`
# only to mark `review` when the branch has an open PR. `wb pause` is the
# progress verb: shelving a task on purpose, which composes `wb down` so a
# paused task never has a live session left behind (the exact conflation
# the two-axis model exists to rule out).

# _wb_resolve_session_and_task <verb> <session-var> <task-file-var> [<arg>]
# — the session/task-file resolution cmd_down, cmd_pr_open, cmd_pause and
# cmd_reviewed all open with: take the session from <arg>, or from the
# current tmux session when <arg> is empty (refusing outside tmux), resolve
# its task file via wb_session_task_file, and require the file to exist.
# Results land in the caller's variables named by <session-var> and
# <task-file-var> (namerefs, not `$(...)`: the failure paths `exit 1`, and
# inside a command substitution that would only end the subshell). Every
# error is prefixed "wb <verb>:" and is the exact text each verb printed
# before this was extracted — tests pin it byte-for-byte.
_wb_resolve_session_and_task() {
  local _wb_rst_verb="$1"
  local -n _wb_rst_session="$2" _wb_rst_task="$3"
  _wb_rst_session="${4:-}"
  if [ -z "$_wb_rst_session" ]; then
    [ -n "${TMUX:-}" ] || { echo "wb $_wb_rst_verb: run inside the target session, or pass a session name" >&2; exit 1; }
    _wb_rst_session="$(tmux display-message -p '#S')"
  fi
  _wb_rst_task="$(wb_session_task_file "$_wb_rst_session")" \
    || { echo "wb $_wb_rst_verb: $_wb_rst_session has no @wb_repo/@wb_slug — not a wb task session" >&2; exit 1; }
  [ -f "$_wb_rst_task" ] || { echo "wb $_wb_rst_verb: no task file for $_wb_rst_session ($_wb_rst_task)" >&2; exit 1; }
}

# cmd_down [--keep-session] [<session>] — close <session> (or the current
# one) while leaving the worktree untouched: snapshot every conversation
# id currently on disk for the worktree into claude_sessions: (record-only,
# KTD2), mark `review` when wb_branch_has_open_pr says the branch has one,
# append a Handoffs entry, then kill the tmux session. --keep-session does
# everything except the kill — the picker's `_down` wrapper uses it for the
# self-target case (mirrors _ctrl_x's task-row guard: the picker commonly
# opens inside whatever session you're already in via a bare `new-window`,
# so closing THAT row would otherwise kill the very pane running the
# picker). Typing `wb down` yourself from inside your own session is
# intentional self-close and stays unguarded here, same precedent as
# `wb done --close` (_ctrl_x's own header comment).
cmd_down() {
  local keep_session=0 no_status_flip=0
  local -a args=()
  while [ $# -gt 0 ]; do
    case "$1" in
      --keep-session)   keep_session=1; shift ;;
      --no-status-flip) no_status_flip=1; shift ;;
      *)                args+=("$1"); shift ;;
    esac
  done

  local session task_file
  _wb_resolve_session_and_task down session task_file "${args[0]:-}"

  local repo branch worktree_rel worktree_path
  repo="$(wb_get_frontmatter "$task_file" repo)"
  branch="$(wb_get_frontmatter "$task_file" branch)"
  worktree_rel="$(wb_get_frontmatter "$task_file" worktree)"
  [ -n "$worktree_rel" ] || worktree_rel=".worktrees/$branch"
  worktree_path="$(wb_repo_dir "$repo")/$worktree_rel"

  # Read the snapshot and the PR-open probe BEFORE the lock — both are pure
  # reads (task lock, not tmux/disk/network locks), and computing either
  # while a lock is held would extend the critical section over a `tmux
  # list-panes` call or a `gh pr list` network round trip for no reason —
  # the latter has no bound on how long it can hang (network partition,
  # GitHub outage), which would otherwise starve every other `wb append`/
  # `wb pause`/`wb down` on the same task file for as long as it stalls.
  local snapshot; snapshot="$(wb_sessions_snapshot "$session" "$worktree_path")"
  local has_open_pr=1
  wb_branch_has_open_pr "$(wb_repo_dir "$repo")" "$branch" && has_open_pr=0

  _wb_lock_trap_append_if_top_level wb_task_lock_release_all
  wb_task_lock_acquire_guarded "$task_file" || exit $?
  [ -z "$snapshot" ] || wb_set_frontmatter "$task_file" claude_sessions "$snapshot"
  [ "$has_open_pr" = 0 ] && [ "$no_status_flip" = 0 ] && wb_set_frontmatter "$task_file" status review
  if [ "$keep_session" = 1 ]; then
    wb_append_handoff "$task_file" "wb down" 'Worktree kept, session left open (`wb down --keep-session`).'
  else
    wb_append_handoff "$task_file" "wb down" 'Session closed via `wb down` — worktree kept.'
  fi
  wb_task_lock_release "$task_file"

  if [ "$keep_session" = 0 ]; then
    tmux kill-session -t "=$session" 2>/dev/null || true
  fi

  echo "wb down: $session set aside — worktree and record kept, resume via the picker or \`wb resume\` ($task_file)"
}

# cmd_pr_open [<session>] — CLI wrapper over wb_branch_has_open_pr (R16):
# exits 0 when the session's branch has an open PR, 1 otherwise. Exists so
# a skill (whose Bash tool can't see the zsh `pgh` fallback function
# wb_branch_has_open_pr shares with wb_pr_merge_status) can ask the
# question without shelling out to `gh` directly.
cmd_pr_open() {
  local session task_file
  _wb_resolve_session_and_task pr-open session task_file "${1:-}"

  local repo branch
  repo="$(wb_get_frontmatter "$task_file" repo)"
  branch="$(wb_get_frontmatter "$task_file" branch)"
  wb_branch_has_open_pr "$(wb_repo_dir "$repo")" "$branch"
}

# cmd_pause <session> — shelves a task ON PURPOSE (KTD1's progress axis):
# sets `status: paused`, then composes cmd_down so a paused task never has
# a live session left behind. The lock here is released BEFORE cmd_down
# acquires its own — wb_task_lock_acquire's flock is not re-entrant, so a
# nested acquire from the same process would time out (exit 75) and leave
# the task paused with the session still running, exactly the crossed-axes
# state this model rules out (see cmd_resume's own never-nested note for
# the same hazard in a different verb). Deliberately skips wb done's
# dirty-worktree check: that check guards worktree REMOVAL, and neither
# `wb pause` nor `wb down` ever removes the worktree.
cmd_pause() {
  local session task_file
  _wb_resolve_session_and_task pause session task_file "${1:-}"

  _wb_lock_trap_append_if_top_level wb_task_lock_release_all
  wb_task_lock_acquire_guarded "$task_file" || exit $?
  wb_set_frontmatter "$task_file" status paused
  wb_append_handoff "$task_file" "wb pause" 'Session paused via `wb pause`.'
  wb_task_lock_release "$task_file"
  echo "wb pause: $task_file -> paused"

  # --no-status-flip: pause is the explicit verb here (KTD1's "status is
  # progress, changed only by an explicit verb") — it must win over
  # cmd_down's own inferred review flip, or a task paused while its branch
  # already has an open PR would silently end at status:review instead of
  # the paused status just printed above.
  cmd_down --no-status-flip "$session"
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
  local session task_file
  _wb_resolve_session_and_task reviewed session task_file "${1:-}"

  _wb_lock_trap_append_if_top_level wb_task_lock_release_all
  wb_task_lock_acquire_guarded "$task_file" || exit $?
  wb_set_frontmatter "$task_file" reviewed "$(date +%F)"
  wb_task_lock_release "$task_file"
  echo "wb reviewed: $session marked reviewed ($task_file)"
}

# cmd_jira_set <repo>--<slug> <url> — stamp a created Jira ticket's URL into
# an existing task's `jira:` frontmatter field, under the task-store lock.
# The ONE store write in the /wb-jira-create emit flow (KTD1/KTD2): the skill
# calls this once per successfully created ticket, each an independent guarded
# lock burst. Modeled on cmd_reviewed's single-field locked write above.
#
# Idempotent-or-refuse (KTD3) — the defense-in-depth behind the skill's R11
# gather-time skip: an empty `jira:` is written; an IDENTICAL value is a no-op
# success (a create-then-stamp partial failure is safe to retry); a DIFFERENT
# non-empty value fails loud and writes nothing, so a double-emit bug fails
# safe rather than clobbering an existing ticket link. The URL is stored
# VERBATIM (KTD6) — never normalized or re-derived here, matching
# cmd_new's --jira path and ~/code/tasks/README.md's "stored exactly as
# normalized when the task was created … never re-derived or rewritten."
#
# Takes an EXACT stem (the wb_resolve_parent_ref pattern, above), never the
# fuzzy matcher: the caller derives the stem from the task's already-resolved
# file, so an absent or ambiguous stem must fail loud rather than guess.
cmd_jira_set() {
  local stem="${1:-}" url="${2:-}"
  if [ -z "$stem" ] || [ -z "$url" ]; then
    echo "wb jira-set: usage: wb jira-set <repo>--<slug> <url>" >&2
    exit 1
  fi

  local file="$TASKS_DIR/$stem.md"
  [ -f "$file" ] \
    || { echo "wb jira-set: '$stem' has no matching task file in $TASKS_DIR" >&2; exit 1; }

  # Fast path (KTD3): a pure retry against an already-correctly-stamped task is
  # a no-op that must not contend on the lock at all. This pre-lock read is
  # ONLY that optimization for the identical-value case — never the authority
  # for the write decision.
  if [ "$(wb_get_frontmatter "$file" jira)" = "$url" ]; then
    echo "wb jira-set: $stem already stamped with $url (no-op)"
    return 0
  fi

  _wb_lock_trap_append_if_top_level wb_task_lock_release_all
  wb_task_lock_acquire_guarded "$file" || exit $?

  # The authoritative idempotent-or-refuse decision (KTD3) is made UNDER the
  # lock and is atomic with the write below (W5: check-then-write must run
  # inside the held lock, the same ordering cmd_new documents at its own
  # wb_seed_task call site — never trust a value read before the lock). Without
  # this re-read, two concurrent writers could both observe an empty field
  # pre-lock, serialize on the lock, and the second would clobber the first's
  # URL with no refusal — the exact silent-lost-write class this repo's lock
  # work exists to prevent.
  local existing; existing="$(wb_get_frontmatter "$file" jira)"
  if [ -n "$existing" ]; then
    wb_task_lock_release "$file"
    if [ "$existing" = "$url" ]; then
      echo "wb jira-set: $stem already stamped with $url (no-op)"
      return 0
    fi
    echo "wb jira-set: $stem already has a different jira: value ($existing) — refusing to overwrite" >&2
    exit 1
  fi

  wb_set_frontmatter "$file" jira "$url"
  wb_task_lock_release "$file"
  echo "wb jira-set: $stem jira set to $url"
}

# ---------------------------------------------------------------------------
# Shared git guard
# ---------------------------------------------------------------------------

# _wb_git_dirty_guard <path> <verb-label> — fail loud (exit 1, naming
# <verb-label>) if <path>'s git status is non-empty; silent no-op
# otherwise. Used by cmd_done.
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

# wb_open_buffer <path> — open <path> in nvim, blocking until closed. Thin
# shim over the shared decision-buffer script
# (~/.claude/skills/decision-buffer/scripts/open-buffer.sh), which owns the
# tmux-split + wait-for recipe (and its channel-uniqueness rule) for every
# caller of it — decision-buffer, wb-done, parked-items, wb.sh's own
# internal callers below. See
# ~/.claude/skills/decision-buffer/references/mechanism.md for the full
# contract. A missing or non-executable script (a stale, un-restowed
# environment) is a hard error naming the stow command.
wb_open_buffer() {
  local path="$1"
  local script="$HOME/.claude/skills/decision-buffer/scripts/open-buffer.sh"

  if [ ! -x "$script" ]; then
    echo "wb_open_buffer: $script missing or not executable — re-stow with: stow --no-folding -t \"\$HOME\" claude" >&2
    return 1
  fi

  if [ -n "${TMUX:-}" ]; then
    "$script" --tmux "$path"
  else
    "$script" --direct "$path"
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
# behavior; handoff.sh's handoff_append_followup delegates here too):
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
#   - "## <heading>" is missing entirely (checked over the WHOLE file up
#     front, not just the part scanned so far), but "## Decisions" exists
#     as a real heading — insert a fresh "## <heading>" section immediately
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
    function isHeadingLine() { return (prev == "" || FNR == 1) }
    BEGIN { insection = 0; inserted = 0; exists = 0; pass = 0 }
    # The file is read twice (see the invocation below). Pass 1 only
    # records whether the target heading exists ANYWHERE, so the
    # missing-heading fallback in pass 2 cannot fire just because the scan
    # reached "## Decisions" before the target — true of every target that
    # follows Decisions in TEMPLATE.md (Done, Follow-ups), which used to
    # get a duplicate heading spliced in before Decisions. A counter rather
    # than the usual NR == FNR test, which misfires when the file is empty.
    FNR == 1 { pass++; prev = "" }
    pass == 1 { if ($0 == target && isHeadingLine()) exists = 1; prev = $0; next }
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
    # target section right before it.
    $0 == "## Decisions" && !exists && !inserted && isHeadingLine() {
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
  ' "$file" "$file" > "$file.tmp.$$" && mv "$file.tmp.$$" "$file"
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
# /handoff, and /weekly-review are rewired (U4) to touch a task file's body
# instead of an Edit-tool write that bypasses every lock this plan built.
# ---------------------------------------------------------------------------

# _wb_append_resolve_task <query> [<verb-label>] — the file cmd_append should write into.
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
  local query="${1:-}" verb="${2:-wb append}"
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

  _wb_resolve_task_fuzzy "$query" "$verb"
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
# wb status — set a STORE-ONLY task's status: field directly (no live
# session to route the change through `wb pause`/`wb down`/`wb resume`).
# ---------------------------------------------------------------------------

# cmd_status <task-ref> <prospective|planned|paused|doing|review> — resolves
# <task-ref> via _wb_append_resolve_task (the same exact-then-fuzzy resolver
# `wb append` uses — fail-loud on ambiguity), refuses when any LIVE tmux
# session's @task already points at the resolved file (this verb is for
# tasks with no session to carry the transition — a live session must go
# through wb pause/wb down, which also handle the session side), then
# rewrites `status:` in the frontmatter block only, under the per-task lock,
# preserving a trailing inline comment on that line if present (TEMPLATE.md/
# README.md's own `status: planned|doing|...  # lifecycle state ...` shape) —
# the same frontmatter-scoped awk idiom wb_set_frontmatter/wb_seed_task_planned
# use, specialized here only for the comment-preserving requirement.
# `prospective` (R25/KTD4) is captured-but-unjudged work — a real lifecycle
# position the weekly review moves tasks in and out of (planned <->
# prospective), not just a tag. `done` is deliberately NOT a valid value
# here: `wb done` is a whole wind-down (worktree removal, board bookkeeping)
# this verb must never shortcut around.
cmd_status() {
  local query="${1:-}" new="${2:-}"
  if [ -z "$query" ] || [ -z "$new" ]; then
    echo "usage: wb status <task-ref> <prospective|planned|paused|doing|review>" >&2
    exit 1
  fi

  case "$new" in
    prospective|planned|paused|doing|review) ;;
    done)
      echo "wb status: use \`wb done <task>\` instead" >&2
      exit 1
      ;;
    *)
      echo "usage: wb status <task-ref> <prospective|planned|paused|doing|review>" >&2
      exit 1
      ;;
  esac

  local file
  file="$(_wb_append_resolve_task "$query" "wb status")" || exit 1

  # Refuse when a live session's @task already points at this file — this
  # verb is for store-only tasks; a live session must route the change
  # through wb pause/wb down instead.
  _wb_refuse_if_live_session "$file" "wb status"

  local old
  old="$(wb_get_frontmatter "$file" status)"

  if [ "$old" = "$new" ]; then
    echo "wb status: $(basename -- "$file") already $new"
    exit 0
  fi

  _wb_lock_trap_append_if_top_level wb_task_lock_release_all
  wb_task_lock_acquire_guarded "$file" || exit $?
  wb_set_frontmatter_field "$file" status "$new"
  wb_task_lock_release "$file"
  echo "wb status: $(basename -- "$file") $old -> $new"
}

# ---------------------------------------------------------------------------
# wb set — generalizes `wb status` (above) to a controlled subset of
# board-metadata frontmatter fields: set exactly one field on a STORE-ONLY
# task, under the per-task lock, via the shared wb_set_frontmatter_field
# rewrite core. Same live-session-refusal scan as cmd_status — this verb
# is for tasks with no session to carry the change.
# ---------------------------------------------------------------------------

# _wb_tags_parse <raw> — split a `tags:` value in any of its accepted input
# shapes (`a,b` | `a, b` | `[a, b]`) into one trimmed token per line. Strips
# a wrapping `[...]` (the canonical list form, R26) if present; a bare
# scalar (no brackets, e.g. the legacy `action-live`) reads as one token.
_wb_tags_parse() {
  local raw="$1"
  raw="${raw#\[}"; raw="${raw%\]}"
  [ -n "$raw" ] || return 0
  local -a toks=()
  IFS=',' read -r -a toks <<< "$raw"
  local t
  for t in "${toks[@]}"; do
    t="${t#"${t%%[![:space:]]*}"}"
    t="${t%"${t##*[![:space:]]}"}"
    [ -n "$t" ] && printf '%s\n' "$t"
  done
}

# _wb_tags_join <tag>... — "a, b, c", the canonical list form's inner text.
_wb_tags_join() {
  local out="" first=1 t
  for t in "$@"; do
    if [ "$first" = 1 ]; then out="$t"; first=0; else out="$out, $t"; fi
  done
  printf '%s' "$out"
}

# _wb_tags_merge <old-raw> <new-raw> — R26's canonical writer: union <old>'s
# tags with <new>'s (existing order preserved, new-only tags appended,
# de-duplicated), rendered as `[a, b, c]`. `wb set tags <value>` is
# additive, never a replace — the field is a free-tag collection, and a
# plain overwrite would silently drop whatever was already there. This is
# also the migration path (U5): re-running it against a bare-scalar
# `tags: action-live` file with the SAME value merges the one existing
# token with itself and re-emits it in canonical list form.
_wb_tags_merge() {
  local old="$1" new="$2"
  local -a result=()
  local -A seen=()
  local t
  while IFS= read -r t; do
    [ -n "$t" ] || continue
    [ -n "${seen["$t"]:-}" ] && continue
    seen["$t"]=1
    result+=("$t")
  done < <(_wb_tags_parse "$old"; _wb_tags_parse "$new")
  printf '[%s]' "$(_wb_tags_join "${result[@]}")"
}

# WB_SET_FIELDS — the field allowlist `wb set` accepts, one space-separated
# literal so cmd_set's case statement and its own usage/error text can't
# drift apart. Deliberately excludes every field owned by a dedicated verb
# (status: -> wb status/wb done, reviewed: -> wb reviewed, jira: creation ->
# /wb-jira-create's `wb jira-set`, though jira: itself stays editable here
# for a plain URL correction) and every field the tooling derives/stamps
# itself (created/closed/claude_sessions/repo/worktree). branch: is settable
# because seeding tools pre-fill it and `wb new` adopts it as the git branch —
# a stale value has to be correctable before the worktree exists. pr: is the
# task's GitHub PR URLs, read by generated status pages (e.g. a ladder's
# per-ticket Status cell) — a task often spans several PRs across repos.
WB_SET_FIELDS="priority value size parent depends_on jira pr tags path branch"

# cmd_set <task-ref> <field> <value> — resolves <task-ref> the same way
# cmd_status does (_wb_append_resolve_task), refuses a field this verb
# doesn't own with a message naming the right verb (status:) or simply
# saying it isn't settable here (created/closed/reviewed/claude_sessions/
# repo/worktree), refuses an unknown field, validates the value for
# the fields that have an enum or a must-exist-in-$TASKS_DIR constraint
# (priority/value/size/parent/depends_on/jira/pr/branch — same fail-loud-before-any-
# write convention `wb new`'s --depends-on validation uses), then
# rewrites just that one frontmatter line under the per-task lock. Inserts
# the field right after `size:` when it's missing entirely (priority:/
# value: land there in TEMPLATE.md's own field order) — every other
# missing field falls back to wb_set_frontmatter_field's own default
# (just before the closing `---`). No write when the value already
# matches — except `--unset` on a key missing entirely, which inserts it
# empty (schema backfill). Never appends a Handoffs entry: a frontmatter
# change is its own record.
cmd_set() {
  local query="${1:-}" field="${2:-}" value="${3:-}"
  if [ -z "$query" ] || [ -z "$field" ] || [ "$#" -lt 3 ]; then
    echo "usage: wb set <task-ref> <field> <value|--unset>   (field: $WB_SET_FIELDS)" >&2
    exit 1
  fi

  case "$field" in
    status)
      echo "wb set: 'status' is not settable via \`wb set\` — use \`wb status\`/\`wb done\` instead" >&2
      exit 1
      ;;
    created|closed|reviewed|claude_sessions|repo|worktree)
      echo "wb set: '$field' is not settable via \`wb set\` (tooling-owned field)" >&2
      exit 1
      ;;
    priority|value|size|parent|depends_on|jira|pr|tags|path|branch)
      ;;
    *)
      echo "wb set: unknown field '$field' (allowed: $WB_SET_FIELDS)" >&2
      exit 1
      ;;
  esac

  # `--unset` (or an empty value) clears the field. Every field this verb owns
  # is optional per $TASKS_DIR/README.md, so clearing is always legal — and the
  # validation below polices real values, not their absence: parent's and
  # depends_on's must-exist-in-$TASKS_DIR checks have no file to match when
  # there is no value, which is what made un-parenting a task impossible
  # through the locked path before this existed.
  local unset_req=0
  if [ "$value" = "--unset" ] || [ -z "$value" ]; then
    unset_req=1
    value=""
  fi

  if [ "$unset_req" -eq 0 ]; then
    case "$field" in
      priority)
        case "$value" in
          P1|P2|P3) ;;
          *) echo "wb set: priority '$value' is not one of P1|P2|P3" >&2; exit 1 ;;
        esac
        ;;
      value)
        case "$value" in
          high|med|low) ;;
          *) echo "wb set: value '$value' is not one of high|med|low" >&2; exit 1 ;;
        esac
        ;;
      size)
        if ! _wb_valid_size "$value"; then
          echo "wb set: size '$value' is not one of $WB_SIZE_VALUES" >&2
          exit 1
        fi
        ;;
      parent)
        case "$value" in
          */*) echo "wb set: parent '$value' must not contain '/'" >&2; exit 1 ;;
        esac
        [ -f "$TASKS_DIR/$value.md" ] \
          || { echo "wb set: parent '$value' has no matching task file in $TASKS_DIR" >&2; exit 1; }
        ;;
      depends_on)
        local dep
        local -a _wb_set_deps
        IFS=',' read -r -a _wb_set_deps <<< "$value"
        for dep in "${_wb_set_deps[@]}"; do
          case "$dep" in
            */*) echo "wb set: depends_on '$dep' must not contain '/'" >&2; exit 1 ;;
          esac
          [ -f "$TASKS_DIR/$dep.md" ] \
            || { echo "wb set: depends_on '$dep' has no matching task file in $TASKS_DIR" >&2; exit 1; }
        done
        ;;
      jira)
        case "$value" in
          https://*) ;;
          *) echo "wb set: jira '$value' must start with https://" >&2; exit 1 ;;
        esac
        ;;
      pr)
        # Comma-separated full GitHub PR URLs, in the order they were opened.
        # Each entry is trimmed and the list re-joined with ", ", so readers
        # split on ',' and strip. An empty entry (",," or a trailing comma)
        # is refused rather than dropped — `read -a` would drop it silently.
        # The single-line check runs on the raw value first: the per-entry
        # `read -r` trim keeps only an entry's first line.
        _wb_frontmatter_value_ok "wb set" "$field" "$value" || exit 1
        local _wb_set_rest="$value," _wb_set_pr _wb_set_prs=""
        while [ -n "$_wb_set_rest" ]; do
          _wb_set_pr="${_wb_set_rest%%,*}"; _wb_set_rest="${_wb_set_rest#*,}"
          read -r _wb_set_pr <<< "$_wb_set_pr"
          [[ "$_wb_set_pr" =~ ^https://github\.com/[^/[:space:]]+/[^/[:space:]]+/pull/[0-9]+$ ]] \
            || { echo "wb set: pr '${_wb_set_pr:-(empty entry)}' is not a full GitHub PR URL (https://github.com/<owner>/<repo>/pull/<n>)" >&2; exit 1; }
          _wb_set_prs="${_wb_set_prs:+$_wb_set_prs, }$_wb_set_pr"
        done
        value="$_wb_set_prs"
        ;;
      branch)
        # The name `wb new` will adopt as the git branch. `--branch` also
        # expands @{-N} to a previous branch — reject any value it rewrites.
        # -C /: the check needs no repo, and must not depend on the caller's
        # cwd being one.
        local _wb_set_ref
        _wb_set_ref="$(git -C / check-ref-format --branch "$value" 2>/dev/null)" && [ "$_wb_set_ref" = "$value" ] \
          || { echo "wb set: branch '$value' is not a valid git branch name" >&2; exit 1; }
        ;;
      tags|path) ;;   # free text — no enum, no existence check
    esac
  fi
  _wb_frontmatter_value_ok "wb set" "$field" "$value" || exit 1

  local file
  file="$(_wb_append_resolve_task "$query" "wb set")" || exit 1

  # Refuse when a live session's @task already points at this file — this
  # verb is for store-only tasks.
  _wb_refuse_if_live_session "$file" "wb set"

  # Locked BEFORE `old` is read — not just before the write. For every
  # field except tags, `old` is used only for the no-op check and the
  # confirmation message, so a stale unlocked read was harmless (the
  # write below always replaces unconditionally with the literal argv
  # value). tags is different: the WRITTEN value is *computed from* `old`
  # (see the merge below), so an unlocked read-then-merge-then-write is
  # exactly the lost-update race this module's locking exists to prevent
  # — two concurrent `wb set <task> tags <x>` calls could each read the
  # same stale `old`, merge independently, and the second writer would
  # silently discard the first writer's tag. Acquiring the lock here
  # covers read+merge+write as one atomic section for every field.
  _wb_lock_trap_append_if_top_level wb_task_lock_release_all
  wb_task_lock_acquire_guarded "$file" || exit $?

  local old
  old="$(wb_get_frontmatter "$file" "$field")"

  # branch: with a worktree already on disk — every branch-keyed lookup (PR
  # badge, wb down, wb done) follows the field, while resume reattaches the
  # existing dir without checking its branch. So the only legal value is the
  # branch actually checked out there (the real repair case: field says
  # feat/x, worktree is on feat-x). No worktree dir: free to change. Runs under the task lock, and a
  # no-op set (value already equals branch:) skips it — re-asserting the
  # current value is always legal.
  if [ "$field" = "branch" ] && [ "$value" != "$old" ]; then
    local _wb_set_repo _wb_set_wt _wb_set_dir _wb_set_cur
    _wb_set_repo="$(wb_get_frontmatter "$file" repo)"; read -r _wb_set_repo <<< "$_wb_set_repo"
    _wb_set_wt="$(wb_get_frontmatter "$file" worktree)"; read -r _wb_set_wt <<< "$_wb_set_wt"
    if [ -n "$_wb_set_repo" ] && _wb_safe_worktree_field "$_wb_set_wt" \
        && [ -d "$CODE_DIR/$_wb_set_repo/$_wb_set_wt" ]; then
      _wb_set_dir="$CODE_DIR/$_wb_set_repo/$_wb_set_wt"
      _wb_set_cur="$(git -C "$_wb_set_dir" symbolic-ref -q --short HEAD 2>/dev/null || true)"
      if [ "$value" != "$_wb_set_cur" ]; then
        echo "wb set: $(basename -- "$file") already has a worktree at $_wb_set_wt, checked out on '${_wb_set_cur:-(detached HEAD)}' — branch: can only be set to that branch (or remove the worktree first)" >&2
        wb_task_lock_release "$file"
        exit 1
      fi
    fi
  fi

  # R26: `tags:` is additive, never a replace — merge the argv value into
  # whatever the file already has (bare-scalar, list, or blank), canonical
  # `[a, b]` form, deduplicated. Skipped on --unset (clearing IS a replace,
  # of the whole field, and unset_req's branch below already handles it).
  if [ "$field" = "tags" ] && [ "$unset_req" -eq 0 ]; then
    value="$(_wb_tags_merge "$old" "$value")"
  fi

  # A file with duplicate `$field:` lines (e.g. left behind by the old
  # buggy insert-without-checking wb_set_frontmatter_field) must never
  # short-circuit as a no-op even when the FIRST occurrence already reads
  # $value — the awk rewrite below is what dedupes the file down to one
  # line, and skipping it here would leave the duplicates in place.
  local dup_count
  dup_count="$(awk -v key="$field" 'BEGIN{infm=0} /^---$/{infm++; if(infm==2) exit; next} infm==1 && $0 ~ "^" key ":" {c++} END{print c+0}' "$file")"

  local after_key=""
  case "$field" in
    priority|value) after_key="size" ;;
    pr) after_key="jira" ;;
  esac

  # --unset on a key that is MISSING entirely (dup_count 0 — `old` reads
  # blank either way) materialises it as an empty line instead of no-op'ing:
  # the schema-backfill path, so every optional key can be made present
  # through this locked verb. The value didn't change, so no Handoffs entry
  # even for the structural fields.
  if [ "$unset_req" -eq 1 ] && [ "$dup_count" -eq 0 ]; then
    wb_set_frontmatter_field "$file" "$field" "" "$after_key"
    wb_task_lock_release "$file"
    echo "wb set: $(basename -- "$file") $field: key added (empty)"
    exit 0
  fi

  if [ "$old" = "$value" ] && [ "$dup_count" -le 1 ]; then
    wb_task_lock_release "$file"
    if [ "$unset_req" -eq 1 ]; then
      echo "wb set: $(basename -- "$file") $field already empty"
    else
      echo "wb set: $(basename -- "$file") $field already '$value'"
    fi
    exit 0
  fi

  wb_set_frontmatter_field "$file" "$field" "$value" "$after_key"
  wb_task_lock_release "$file"
  if [ "$unset_req" -eq 1 ]; then
    echo "wb set: $(basename -- "$file") $field '$old' -> (cleared)"
  else
    echo "wb set: $(basename -- "$file") $field '$old' -> '$value'"
  fi
}

# ---------------------------------------------------------------------------
# wb week — the ONE writer for the standing weekly-capture doc and the
# per-week output record (U1, KTD1-KTD3). Not a task file: `wb week` never
# resolves a <task-ref>, it always targets $TASKS_DIR/weeks/.
# ---------------------------------------------------------------------------

# WB_WEEK_SECTIONS — the capture doc's four authored sections, canonical
# order and exact spelling (D5/KTD1). `wb week append`'s <section> argument
# is matched against this list verbatim — no case-folding, no abbreviation —
# so a typo fails loud instead of silently inventing a fifth section
# `_wb_append_under_heading` would never route entries into again.
WB_WEEK_SECTIONS=("What's working" "What's not working" "New ideas" "Notes")

# _wb_week_dir / _wb_week_capture_path — $TASKS_DIR/weeks/ is invisible to
# the board/picker by construction (KTD2: the row source globs
# "$TASKS_DIR"/*.md, non-recursive). The capture doc is standing, not
# per-week (D5) — one file, never cleared.
_wb_week_dir() { printf '%s/weeks\n' "$TASKS_DIR"; }
_wb_week_capture_path() { printf '%s/capture.md\n' "$(_wb_week_dir)"; }

# _wb_week_ensure_capture — create the capture doc from its four-section
# template iff absent. Idempotent: a second call is a no-op. A blank line
# precedes every "## " heading (notes-for-implementer gotcha) —
# _wb_append_under_heading's heading detector only recognizes "## " as a
# heading when it follows a blank line or is line 1, so a template that
# skipped this would silently break every section's routing.
_wb_week_ensure_capture() {
  local path; path="$(_wb_week_capture_path)"
  [ -f "$path" ] && return 0
  mkdir -p "$(_wb_week_dir)"
  {
    echo "# Weekly capture"
    echo
    echo "Standing capture doc for \`/park\` and the weekly review — bounded to only"
    echo "unreviewed entries. Each entry is \`- [ ]\` until \`wb week record\` rolls it"
    echo "into that week's output record (the durable copy) and removes it here."
    local section
    for section in "${WB_WEEK_SECTIONS[@]}"; do
      echo
      echo "## $section"
    done
  } > "$path"
}

# _wb_week_valid_section <name> — exact match against WB_WEEK_SECTIONS.
_wb_week_valid_section() {
  local name="$1" s
  for s in "${WB_WEEK_SECTIONS[@]}"; do
    [ "$s" = "$name" ] && return 0
  done
  return 1
}

# _wb_week_stamp — "<ISO-date> · <repo>/<branch>" prefix (KTD1: the same
# {ts, cwd, branch} the old /park ledger carried, and for the same reason —
# the review routes a follow-up task to the right repo, and `wb new` needs a
# repo argument). Best-effort: outside a git repo, both fields read "?"
# rather than failing the append.
#
# `repo` is derived from `--git-common-dir`, NOT `--show-toplevel`: inside a
# git WORKTREE (the common case — this is a session-per-worktree tool, and
# `/park` is meant to be invoked mid-task), `--show-toplevel` returns the
# worktree's own directory, so `basename` of it is the worktree's leaf name
# (e.g. "feat-weekly-review"), not the repo ("dotfiles") — silently wrong,
# not a failure, so it would never be noticed until a promoted task pointed
# `wb new` at a nonexistent (or wrong) repo directory. `--git-common-dir`
# resolves to the SAME shared `.git` for a worktree and its main checkout
# alike, so `basename(dirname(...))` gives the real repo name either way.
_wb_week_stamp() {
  local common_dir repo branch
  common_dir="$(git rev-parse --git-common-dir 2>/dev/null)" || true
  repo="?"; [ -n "$common_dir" ] && repo="$(basename -- "$(cd "$(dirname -- "$common_dir")" && pwd)")"
  branch="$(git rev-parse --abbrev-ref HEAD 2>/dev/null)" || branch="?"
  printf '%s · %s/%s' "$(date +%F)" "$repo" "$branch"
}

# _wb_week_iso [<date>] — ISO 8601 week identifier, "<year>-W<week>"
# (%G/%V — the ISO week-numbering year, which can differ from %Y in the
# first/last days of a year — and the ISO week number itself).
_wb_week_iso() {
  date ${1:+-d "$1"} +%G-W%V
}

# cmd_week path — print the capture doc's path, creating it first if absent.
_wb_week_cmd_path() {
  _wb_week_ensure_capture
  _wb_week_capture_path
}

# cmd_week append <section> <body> — insert a stamped, unreviewed
# (`- [ ]`) entry under one of the four capture sections, under the
# per-task lock (KTD3: composes _wb_append_under_heading, the same
# primitive wb_append_handoff uses, never a second writer).
_wb_week_cmd_append() {
  local section="${1:-}" body="${2:-}"
  if [ -z "$section" ] || [ -z "$body" ]; then
    echo "usage: wb week append <section> <body>   (section: ${WB_WEEK_SECTIONS[*]})" >&2
    exit 1
  fi
  if ! _wb_week_valid_section "$section"; then
    echo "wb week append: unknown section '$section' (valid: ${WB_WEEK_SECTIONS[*]})" >&2
    exit 1
  fi

  _wb_week_ensure_capture
  local path; path="$(_wb_week_capture_path)"
  local entry; entry="- [ ] $(_wb_week_stamp) · $body"

  _wb_lock_trap_append_if_top_level wb_task_lock_release_all
  wb_task_lock_acquire_guarded "$path" || exit $?
  _wb_append_under_heading "$path" "$section" "$entry"
  wb_task_lock_release "$path"
  echo "wb week: appended under \"## $section\" in $(basename -- "$path")"
}

# _wb_week_previous_record <iso> — the most recent existing
# weeks/<iso>-review.md OTHER than <iso> itself, by filename sort (ISO week
# identifiers sort lexicographically in chronological order). Empty when
# none exist yet.
_wb_week_previous_record() {
  local iso="$1" dir; dir="$(_wb_week_dir)"
  [ -d "$dir" ] || return 0
  # `|| true`: under set -o pipefail, grep finding zero matches (the
  # guaranteed case on the first-ever review, and any time no prior week
  # has been recorded) exits 1, which would otherwise make this whole
  # pipeline — and this function's return status — non-zero. Callers do
  # `prev="$(_wb_week_previous_record "$iso")"` under set -e, so a
  # non-zero return here (despite "empty" being the documented, valid
  # result) killed the entire `wb week record` call before it wrote
  # anything.
  ls "$dir" 2>/dev/null \
    | grep -E '^[0-9]{4}-W[0-9]{2}-review\.md$' \
    | grep -v -F "$iso-review.md" \
    | sort \
    | tail -1 \
    || true
}

# cmd_week record [<iso>] — mint $TASKS_DIR/weeks/<iso>-review.md
# (default: the current ISO week) if absent, rolling up every unreviewed
# (`- [ ]`) capture entry per section into the record and then REMOVING it
# from the capture doc so the next review never re-offers it (KTD1 — the
# exact stranding failure that left 12 of 58 /park ledger entries untriaged
# across two reviews) and the capture doc never grows unboundedly (Jet,
# 2026-09-16: flipping entries to `- [x]` in place instead of removing them
# meant the doc would carry every entry ever captured, forever — the
# per-week record already IS the durable, immutable copy, so keeping a
# second flipped-in-place copy in the standing doc served no purpose).
# Idempotent: a second call for an already-minted <iso> just prints its
# path — no re-scan, no re-removal, so re-running `wb week record` mid-week
# never double-reviews (or double-deletes) an entry.
_wb_week_cmd_record() {
  local iso="${1:-$(_wb_week_iso)}"
  # <iso> becomes a path component below (record="$dir/$iso-review.md") —
  # reject anything not shaped like an ISO week identifier BEFORE that,
  # so a value like "../../../../tmp/pwned" can't escape weeks/.
  case "$iso" in
    [0-9][0-9][0-9][0-9]-W[0-9][0-9]) ;;
    *)
      echo "wb week record: '$iso' is not a valid ISO week (expected <YYYY>-W<WW>, e.g. 2026-W38)" >&2
      exit 1
      ;;
  esac
  _wb_week_ensure_capture
  local dir; dir="$(_wb_week_dir)"
  local record="$dir/$iso-review.md"

  if [ -f "$record" ]; then
    echo "$record"
    return 0
  fi

  local capture; capture="$(_wb_week_capture_path)"
  _wb_lock_trap_append_if_top_level wb_task_lock_release_all
  wb_task_lock_acquire_guarded "$capture" || exit $?

  # Re-check under the lock (classic double-checked locking): the check
  # above ran BEFORE acquiring the lock, so a second concurrent `wb week
  # record` call for the same not-yet-existing ISO week can reach here
  # after a first call already won the race, built the record, and
  # removed the capture doc's rolled-up entries. Without this re-check,
  # the second caller would re-scan the now-emptied capture doc, find
  # nothing left unreviewed, and silently overwrite the first caller's
  # real roll-up with an empty one.
  if [ -f "$record" ]; then
    wb_task_lock_release "$capture"
    echo "$record"
    return 0
  fi

  local prev; prev="$(_wb_week_previous_record "$iso")"

  {
    echo "# Week $iso review"
    echo
    if [ -n "$prev" ]; then
      echo "Previous record: \`$prev\`"
    else
      echo "Previous record: none — first review."
    fi
    local section
    for section in "${WB_WEEK_SECTIONS[@]}"; do
      echo
      echo "## $section"
      echo
      local target="## $section" insection=0 found=0 line
      while IFS= read -r line; do
        if [ "$line" = "$target" ]; then insection=1; continue; fi
        if [ "$insection" = 1 ] && [[ "$line" == "## "* ]]; then insection=0; fi
        if [ "$insection" = 1 ] && [[ "$line" == "- [ ] "* ]]; then
          echo "$line"
          found=1
        fi
      done < "$capture"
      [ "$found" = 1 ] || echo "(none)"
    done
    echo
    echo "## Retro"
    echo
    echo "(filled in by /weekly-review)"
    echo
    echo "## Sprint planning"
    echo
    echo "(filled in by /weekly-review)"
    echo
    echo "## Actioned vs. carried over"
    echo
    echo "(filled in by /weekly-review)"
  } > "$record"

  # Remove every entry just rolled into the record — its text already
  # lives verbatim in $record (built above), which is the durable,
  # immutable copy from here on, so the capture doc doesn't need a second
  # (flipped) copy of the same line kept forever. Every "- [ ] " line
  # still in the doc at this point was just captured into $record above
  # (the scan loop covers all four sections unconditionally), so this is
  # a plain unconditional removal, not a per-section operation. Each
  # entry's own trailing blank line (inserted by _wb_append_under_heading,
  # which always follows an entry with exactly one blank line) is removed
  # alongside it, so a fully-emptied section collapses back to the same
  # "heading, blank, next heading" shape _wb_week_ensure_capture's own
  # template produces — never a stray double-blank or dangling line.
  awk '
    /^- \[ \] / { skip_blank = 1; next }
    skip_blank && $0 == "" { skip_blank = 0; next }
    { skip_blank = 0; print }
  ' "$capture" > "$capture.tmp.$$" && mv "$capture.tmp.$$" "$capture"

  wb_task_lock_release "$capture"
  echo "$record"
}

cmd_week() {
  local sub="${1:-}"; shift || true
  case "$sub" in
    path)   _wb_week_cmd_path ;;
    append) _wb_week_cmd_append "$@" ;;
    record) _wb_week_cmd_record "$@" ;;
    *)
      echo "usage: wb week path | wb week append <section> <body> | wb week record [<iso>]" >&2
      exit 1
      ;;
  esac
}

# ---------------------------------------------------------------------------
# wb install-hooks — the one idempotent verb that wires up everything the
# concurrency-safety machine needs on this host: points $TASKS_DIR's
# core.hooksPath at U6's reference-transaction hook (stowed path — a real
# checkout of $TASKS_DIR needs to actually find the file at runtime, not a
# dotfiles-repo-relative path), hardens gc/reflog retention (X5) so a
# sentinel-blessed rewind stays recoverable by policy rather than GC luck,
# pre-creates the git-hook kill-switch (X4) unless the operator has marked
# the hook as deliberately enabled, and VERIFIES (never edits — Decision
# 4A) the live ~/.claude/settings.json's PreToolUse entry against the
# tracked reference copy in claude/.claude/settings.recommended.json.
# ---------------------------------------------------------------------------

# cmd_install_hooks — no arguments. Every step is safe to re-run: git config
# writes are naturally idempotent for a single value, the switch file is
# only ever created when both the enabled marker is absent AND it isn't
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

  # 3. X4 kill-switch: pre-create disable-git-hook UNLESS the optional
  # replay-passed marker exists — checked FIRST, every run, so an
  # idempotent re-run after a human deliberately enabled the hook (rm'd the
  # switch, touched the marker) never silently re-disables it. The marker
  # is hand-made (`touch`); its name predates the retired replay tool that
  # used to write it. Never remove an existing switch file here — that's
  # the operator's job, not this verb's.
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
      switch_msg="git-hook switch file created (hook installed but dormant — to enable: rm $switch_file && touch $replay_marker)"
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

# wb_week_unreviewed_count — `- [ ]` (unreviewed) entries across the
# standing capture doc, regardless of section. 0 when the doc doesn't exist
# yet (never creates it just to count).
wb_week_unreviewed_count() {
  local path; path="$(_wb_week_capture_path)"
  [ -f "$path" ] || { echo 0; return; }
  # `grep -c` already prints "0" (not nothing) on zero matches, and only
  # exits 1 to signal that — `|| echo 0` on that nonzero exit prints a
  # SECOND "0" line, corrupting any caller (cmd_done's arithmetic, under
  # `set -e`, aborts on the resulting two-line value). Capture the count
  # unconditionally instead of branching on grep's exit status.
  local n
  n="$(grep -c '^- \[ \] ' "$path" 2>/dev/null)" || true
  printf '%s\n' "${n:-0}"
}

# wb_week_days_since_last_record — days since the most recently minted
# weeks/<iso>-review.md's mtime, or empty when none exist yet (no review
# has ever run).
wb_week_days_since_last_record() {
  local dir; dir="$(_wb_week_dir)"
  local latest
  latest="$( [ -d "$dir" ] && ls "$dir" 2>/dev/null | grep -E '^[0-9]{4}-W[0-9]{2}-review\.md$' | sort | tail -1)"
  [ -n "$latest" ] || return 0
  local mtime now
  mtime="$(stat -c %Y "$dir/$latest" 2>/dev/null || stat -f %m "$dir/$latest" 2>/dev/null)"
  [ -n "$mtime" ] || return 0
  now="$(date +%s)"
  echo $(( (now - mtime) / 86400 ))
}

# wb_pending_counts — "<n> follow-ups pending · <m> unreviewed capture
# entries (Nd since last review)", read by the picker's status line and
# wb done's post-close-out nudge. KTD2a: repointed from the retired /park
# ledger's open count at the standing capture doc instead — the ledger's
# invisibility to the board/picker was only safe because this ambient
# nudge existed; losing the signal here would reproduce the exact
# structural rot this plan exists to end.
wb_pending_counts() {
  local unreviewed days
  unreviewed="$(wb_week_unreviewed_count)"
  days="$(wb_week_days_since_last_record)"
  if [ -n "$days" ]; then
    printf '%s follow-ups pending · %s unreviewed capture entries (%sd since last review)' \
      "$(wb_followup_count)" "$unreviewed" "$days"
  else
    printf '%s follow-ups pending · %s unreviewed capture entries (no review yet)' \
      "$(wb_followup_count)" "$unreviewed"
  fi
}


# wb_shelved_counts <assoc-array-name> — fill <name>[<task-stem>]=<number of shelved
# decision drafts> from ONE `wb-capture.sh shelved --all` call (the board's DRAFTS column
# and drafts chip). Stems with no drafts get no key; read with ${arr[$stem]:-0}. The
# verb prints `<stem>:` then two-space-indented draft paths, so this counts indented lines
# per stem and never learns where drafts live. Best-effort: a missing or failing
# wb-capture.sh leaves the array empty and the board renders with 0s.
wb_shelved_counts() {
  local -n _wsc_out="$1"
  local line stem="" listing
  listing="$(_wb_capture_verb shelved --all 2>/dev/null)" || return 0
  while IFS= read -r line; do
    case "$line" in
      "  "*) [ -n "$stem" ] && _wsc_out["$stem"]=$(( ${_wsc_out["$stem"]:-0} + 1 )) ;;
      ?*:)   stem="${line%:}" ;;
    esac
  done <<<"$listing"
  return 0
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

    # U4 cutover: the ratified 3-view renderer (feat-board-build), replacing
    # the old wb_board_render_html after its parity check (task set,
    # per-status counts, per-family membership) passed clean against the
    # real ~301-task store. R16's single collect pass, no tmux/gh/git calls.
    local -a V2ROWS=()
    local -A M_PLAN_RAW=() M_DONE_RAW=() M_HANDOFF_RAW=() M_FOLLOWUPS_RAW=() \
      M_DECISIONS_RAW=() M_LINKS_RAW=()
    wb_board_collect_rows_v2 V2ROWS M_PLAN_RAW M_DONE_RAW M_HANDOFF_RAW M_FOLLOWUPS_RAW \
      M_DECISIONS_RAW M_LINKS_RAW

    local -A M_STATUS=() M_REPO=() M_BRANCH=() M_WORKTREE=() M_TITLE=() \
      M_CREATED=() M_CLOSED=() M_UPDATED=() M_TASKFILE=() M_PARENT=() \
      M_DEPS=() M_TAGS=() M_PLAN_CHECKED=() M_PLAN_TOTAL=() M_AGE_DAYS=() \
      M_BUCKET=() M_HANDOFF_SUMMARY=() M_FAMILY_ROOT=() STEM_PARENT=() \
      STEM_ANCHOR=() FAMILY_CHILDREN=() BUCKET_COUNT=() M_STAGE_SIG=() M_PR_URL=() \
      M_SIZE=() M_ACCEPT=() M_DRAFTS=()
    # U3 (capture-nudge-rework): shelved-draft counts, one verb call for the whole
    # board, filled BEFORE build_model (which defaults the stems without drafts to 0).
    wb_shelved_counts M_DRAFTS
    # fix(review) P2 follow-up: the 22-name model-array sequence was hand-typed
    # identically at both call sites below (found in PR 1 review) — hoisted to
    # one constant so U5's 2 new trailing arrays only had to be added once,
    # and any future model field only ever needs adding here. U2 (KTD8) adds
    # M_SIZE/M_ACCEPT at the END of this list, after M_PR_URL, for the same
    # reason — both call sites below pick them up automatically. U3
    # (capture-nudge-rework) appends M_DRAFTS the same way.
    local -a WB_BOARD_MODEL_ARGS=(
      M_STATUS M_REPO M_BRANCH M_WORKTREE M_TITLE M_CREATED M_CLOSED M_UPDATED \
      M_TASKFILE M_PARENT M_DEPS M_TAGS M_PLAN_CHECKED M_PLAN_TOTAL M_AGE_DAYS \
      M_BUCKET M_HANDOFF_SUMMARY M_FAMILY_ROOT STEM_PARENT STEM_ANCHOR \
      FAMILY_CHILDREN BUCKET_COUNT M_STAGE_SIG M_PR_URL M_SIZE M_ACCEPT M_DRAFTS
    )
    wb_board_build_model V2ROWS M_PLAN_RAW M_DONE_RAW M_HANDOFF_RAW M_FOLLOWUPS_RAW \
      "${WB_BOARD_MODEL_ARGS[@]}"

    wb_board_render_v2 V2ROWS M_PLAN_RAW M_DONE_RAW M_HANDOFF_RAW M_FOLLOWUPS_RAW \
      "${WB_BOARD_MODEL_ARGS[@]}" M_DECISIONS_RAW M_LINKS_RAW > "$out"
    echo "wb board: wrote $out"
    return 0
  fi

  local f title fu rows="" repo status worktree branch activity
  local -a t
  # U6/R17: an ACT column, only when the terminal is wide enough to take it
  # without wrapping the existing four columns — a plain `wb board` run in a
  # narrow split pane shouldn't have to trade STATUS/REPO/TASK legibility
  # for it. 100 cols is a rough floor, not a measured one; the HTML board's
  # data-activity attribute (U6) is the place to look for this
  # width-independently.
  local term_width show_act=0
  term_width="$(tput cols 2>/dev/null || echo 0)"
  [ "${term_width:-0}" -ge 100 ] && show_act=1
  # DRAFTS column (capture-nudge-rework R5): shelved decision drafts per task, one verb call.
  local -A shelved_n=()
  wb_shelved_counts shelved_n
  local dr
  while IFS= read -r f; do
    [ -f "$f" ] || continue
    wb_tsv_split "$(wb_read_task "$f")" t
    status="${t[0]:-?}"; repo="${t[1]:-?}"; worktree="${t[2]:-}"; branch="${t[3]:-}"
    title="$(wb_task_title "$f")"
    [ -n "$title" ] || title="$(basename "$f" .md)"
    fu="$(awk '
      BEGIN { infu = 0 }
      /^## Follow-ups/ { infu = 1; next }
      /^## /           { infu = 0 }
      infu && /^[-*] / { c++ }
      END { print c + 0 }
    ' "$f")"
    f="${f##*/}"; dr="${shelved_n["${f%.md}"]:-0}"
    if [ "$show_act" = 1 ]; then
      activity="$(wb_task_activity "$repo" "$branch" "$worktree")"
      rows+="$(printf '%s\t%s\t%s\t%s\t%s\t%s' "$status" "$repo" "$title" "$fu" "$dr" "$activity")"$'\n'
    else
      rows+="$(printf '%s\t%s\t%s\t%s\t%s' "$status" "$repo" "$title" "$fu" "$dr")"$'\n'
    fi
  done < <(wb_task_files)

  printf 'live agents: %s (warn >= %s)\n' "$(wb_live_agent_count)" "$WB_AGENT_WARN_AT"

  if [ -z "$rows" ]; then
    echo "wb board: no tasks in $TASKS_DIR"
    return 0
  fi

  {
    if [ "$show_act" = 1 ]; then
      printf 'STATUS\tREPO\tTASK\tFOLLOW-UPS\tDRAFTS\tACT\n'
    else
      printf 'STATUS\tREPO\tTASK\tFOLLOW-UPS\tDRAFTS\n'
    fi
    # doing < review < paused < planned < done < anything-else; rank prefix
    # keeps the plain-text sort key clean, then drops out before display.
    printf '%s' "$rows" | awk -F'\t' -v OFS='\t' '{
      r = ($1 == "doing") ? 0 : ($1 == "review") ? 1 : ($1 == "paused") ? 2 : ($1 == "planned") ? 3 : ($1 == "done") ? 4 : 5
      print r, $0
    }' | sort -t $'\t' -k1,1n -k3,3 -k4,4 | cut -f2-
  } | column -t -s $'\t'
}

# _wb_capture_verb <verb> [args...] — run a wb-capture.sh store verb, best-effort. The
# script is looked up next to wb.sh (like lib.sh and the other sibling helpers), run in
# its own bash and never sourced, so wb.sh knows nothing of the capture layout. Prints
# the verb's stdout; returns 1 when the script is missing or the verb fails.
_wb_capture_verb() {
  local sh="$SCRIPT_DIR/wb-capture.sh"
  [ -f "$sh" ] || return 1
  bash "$sh" "$@"
}

cmd_done() {
  # Index/shift case parser, not a single-token foreach — mirrors cmd_new's
  # --parent handling so --close can appear before, after, or without the
  # optional session positional.
  local close=0 leave_shelved=0
  local -a args=()
  while [ $# -gt 0 ]; do
    case "$1" in
      --close)         close=1; shift ;;
      --leave-shelved) leave_shelved=1; shift ;;
      *)               args+=("$1"); shift ;;
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

  # Read unconditionally (not just inside the store_only==0 branch below):
  # U10's roadmap-currency nudge near the end needs repo: on a store-only
  # close too, and a conditionally-scoped local would be unbound there
  # under set -u.
  local repo; repo="$(wb_get_frontmatter "$task_file" repo)"

  # Draft guard: the background sweep shelves unreviewed decision drafts under
  # <capture root>/shelved/<task-stem>/ (outliving the session), where only
  # /close-out or /wb-decide shelved can accept or dismiss them. Closing the task
  # first would strand them, so refuse — before any mutation, store-only closes
  # included — unless --leave-shelved says leaving them is deliberate. What counts
  # as a draft of this task, and where it lives, is wb-capture.sh's business
  # (`pending-for-task`); wb.sh only counts the paths it prints. Best-effort: a
  # missing or failing wb-capture.sh lets the close proceed, with a note.
  local -a shelved_drafts=()
  local sf pending_out
  if pending_out="$(_wb_capture_verb pending-for-task "$task_file" 2>/dev/null)"; then
    while IFS= read -r sf; do
      [ -n "$sf" ] && shelved_drafts+=("$sf")
    done <<<"$pending_out"
  else
    echo "wb done: wb-capture.sh unavailable next to wb.sh; skipping the decision-draft guard" >&2
  fi
  if [ "${#shelved_drafts[@]}" -gt 0 ] && [ "$leave_shelved" = 0 ]; then
    {
      echo "wb done: ${#shelved_drafts[@]} decision draft(s) shelved for $task_stem would be stranded (nothing changed):"
      for sf in "${shelved_drafts[@]}"; do echo "  shelved: $sf"; done
      echo "wb done: run /close-out or /wb-decide shelved first to accept or dismiss them, or re-run with --leave-shelved to close anyway"
    } >&2
    exit 1
  fi

  local repo_dir worktree_path
  if [ "$store_only" = 0 ]; then
    # worktree_rel/slug derived from the TASK FILE's own frontmatter, never
    # from @wb_repo/@wb_slug directly — a migrated child's worktree:/branch:
    # are its OWN (received from the parent during migration), and a
    # store-only parent has neither to derive from in the first place.
    local worktree_rel slug
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
  # U6/R6: a done task has no worktree left to resume into, so the
  # claude_sessions: snapshot (a record of resumable conversations) is
  # stale the instant the worktree is removed — blank it rather than let a
  # future reader mistake a done task for one with a warm history.
  wb_set_frontmatter "$task_file" claude_sessions ""
  # Say what was actually torn down: without --close the session survives,
  # and a 2026-10-18 batch left 14 idle sessions whose Handoffs all claimed
  # "Session closed". A store-only close never touches a worktree, but a
  # dormant picker row (ctrl-x after `wb down`) still has one on disk, so
  # it says nothing was torn down rather than that nothing existed.
  local done_note
  if [ "$store_only" = 1 ]; then
    done_note='Closed in the store only (`wb done`): no live session, nothing torn down'
  elif [ "$close" -eq 1 ]; then
    done_note='Worktree removed, session closed (`wb done --close`)'
  else
    done_note='Worktree removed, session left open (`wb done` without `--close`)'
  fi
  if [ "${#shelved_drafts[@]}" -gt 0 ]; then
    local left_dirs="" left_d
    for sf in "${shelved_drafts[@]}"; do
      left_d="${sf%/*}"
      case ", $left_dirs," in *", $left_d,"*) ;; *) left_dirs="${left_dirs:+$left_dirs, }$left_d" ;; esac
    done
    done_note="$done_note; --leave-shelved: ${#shelved_drafts[@]} decision draft(s) left in place: $left_dirs"
  fi
  wb_append_handoff "$task_file" "wb done" "$done_note."
  wb_task_lock_release "$task_file"
  if [ "${#shelved_drafts[@]}" -gt 0 ]; then
    _wb_capture_verb log-shelved-left "$task_stem" "${#shelved_drafts[@]}" >/dev/null 2>&1 || true
  fi

  if [ "$store_only" = 1 ]; then
    echo "wb done: $task_file closed (store-only — no live session, nothing torn down)"
  elif [ "$close" -eq 1 ]; then
    echo "wb done: $session — worktree removed, session closed, task -> done ($task_file)"
  else
    echo "wb done: $session — worktree removed, session left open (pass --close to end it), task -> done ($task_file)"
  fi

  local total=$(( $(wb_followup_count) + $(wb_week_unreviewed_count) ))
  if [ "$total" -ge "$WB_SWEEP_THRESHOLD" ]; then
    echo "wb done: $(wb_pending_counts) — consider running /weekly-review"
  fi

  # KTD8's last-child nudge: pure read + print, guarded so a scan failure
  # can never abort cmd_done under set -e (an `if` condition's exit status
  # is exempt from errexit either way, but the explicit -f guard also keeps
  # a missing parent file silent rather than probing wb_family_all_done
  # against a store with no matching file at all). D8: manual parent
  # closing stays manual — this only ever prints, never writes.
  local task_parent; task_parent="$(wb_get_frontmatter "$task_file" parent)"
  if [ -n "$task_parent" ] && [ -f "$TASKS_DIR/$task_parent.md" ] && wb_family_all_done "$task_parent"; then
    echo "wb done: all children of $task_parent are done — close it with: wb done $task_parent"
  fi

  # KTD5's roadmap-currency nudge: pure read + print, never gates or writes.
  # Matched against a small fixed list of roadmap-tracked repos — never a
  # raw substring match against the bracketed tags: text, which could
  # false-positive on an unrelated tag.
  case "$repo" in
    dotfiles|docgen)
      echo "wb done: $repo is roadmap-tracked — worth a check of docs/roadmap.md"
      ;;
  esac

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
#   1 repo   2 label   3 branch (git branch, in brackets)   4 urank (status
#      rank; shown, but no longer an ordering key)
#   5 icon_label
#   6 target (hidden pane target, may be empty)
#   7 session (the live tmux session this row belongs to)
#   8 ref (task file path, or repo dir for repo rows)
#   9 kind (task|repo|agent)   10 ucount (claude panes in session)
#   11 slug (task rows only — real, slash-preserving; used to resume via wb new)
#   12 nest (set by collect_combined_rows, empty on an unnested row):
#      "1"  a live sibling sharing a parent: with the group's anchor row
#      "cN" a live child nested N levels (1..WB_NEST_MAX) under its own
#           live parent's row
#      "aN" an agent-pane sub-row whose owning row sits at nesting level N
#           (empty when the owner is a top-level row)
#   13 visit time (epoch seconds, never empty): when Jet last attached to the
#      row's session (tmux's session_last_attached; 0 = never attached) on a
#      live row, the owning row's time on an agent sub-row, and the newest
#      transcript's mtime on a dormant row. The picker orders and ages rows
#      by it. Appended last so the fzf placeholders {7}-{10} and the accept
#      path's indexes stay where they were.
# wb_format_for_display (used by render_rows) prepends a pre-rendered,
# fixed-width display string as a NEW field 1, shifting all of the above by
# one (repo becomes field 2, ..., nest becomes field 13, visit time field
# 14) — that's the shape fzf and picker()'s final `read` actually see. The
# display shows REPO, NAME, BRANCH and AGE only; status is the NAME colour,
# derived at display time from field 5 (and field 4 for "needs you").

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

# wb_agent_subrows <repo> <session> <ref> <branch> [visit] — one sub-row per
# claude pane in a multi-agent session (kept out of the collapsed parent row).
# <branch> repeats the parent row's branch (same session, same checkout) so
# every row is self-contained instead of leaving it blank on sub-rows.
# <visit> is the owning row's visit time (field 13): a sub-row is part of its
# owner's block, so it orders by the owner's time, never its own.
wb_agent_subrows() {
  local repo="$1" session="$2" ref="$3" branch="$4" visit="${5:-0}"
  local rank target status task icon label
  while IFS=$'\t' read -r rank target status task; do
    IFS=$'\t' read -r icon label < <(wb_status_icon "$status")
    printf '%s\t%s\t%s\t%s\t%s %s\t%s\t%s\t%s\tagent\t1\t\t\t%s\n' \
      "$repo" "$task" "$branch" "$rank" "$icon" "$label" "$target" "$session" "$ref" "$visit"
  done < <(tmux_claude_panes "$session" | sort -n)
}

# wb_session_last_attached <session> [listed] — print the epoch Jet last
# attached to <session>, 0 when never. A seam: tests override it, since a
# detached test session has no attach time. wb_live_session_row only calls it
# when the caller didn't already have the time. collect_live_rows gets every
# session's time from its ONE list-sessions call, so a caller that passes a
# second argument is saying "list-sessions found nothing" (a never-attached
# session): answer 0 without another tmux round-trip. With one argument (a
# direct call) ask tmux.
wb_session_last_attached() {
  if [ $# -ge 2 ]; then printf '0\n'; return; fi
  local t
  t="$(tmux display-message -p -t "=$1:" '#{session_last_attached}' 2>/dev/null || true)"
  printf '%s\n' "${t:-0}"
}

# wb_live_session_row <session> [visit] — one row for a live tmux session. If it's a
# wb task session (@wb_repo/@wb_slug set), shows the task's title/status from
# the store; otherwise shows the session name and, if its cwd is a git repo,
# the current branch — same shape a plain `s`-created session gets.
# [visit] is the session's last-attached epoch when the caller already has it
# (collect_live_rows reads it for every session in one list-sessions call, so
# no per-row fork); absent, empty or 0 falls back to the seam above.
wb_live_session_row() {
  local session="$1" repo slug task_file branch label statuscol kind ref slug_out="" visit="${2:-}"
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

  case "$visit" in ''|0) visit="$(wb_session_last_attached "$@")" ;; esac
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t\t%s\n' \
    "$repo" "$label" "$statuscol" "$urank" "$uicon" "$target" "$session" "$ref" "$kind" "$ucount" "$slug_out" "${visit:-0}"
}

# collect_live_rows — one row per live tmux session, no sub-row expansion.
collect_live_rows() {
  local line session attached
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    # Last-attached epoch (empty for a never-attached session), a space, the
    # name. Time first so the empty case still splits cleanly, and a space
    # rather than a tab because tmux prints control characters in a format
    # as "_". Split by expansion: no fork.
    attached="${line%% *}"; session="${line#* }"
    [ -n "$session" ] || continue
    wb_live_session_row "$session" "$attached"
  done < <(tmux list-sessions -F '#{session_last_attached} #{session_name}' 2>/dev/null)
}

# wb_emit_with_agents <row> [level] — print <row>, then expand its agent
# sub-rows via wb_agent_subrows when it has more than one live claude pane.
# Shared by every emission point in collect_combined_rows (an ungrouped
# row, a group anchor, a sibling, or a nested child) so agent-pane
# expansion never depends on which path a row took to get emitted. A
# non-zero <level> (the owning row's nesting level) marks each agent
# sub-row "a<level>" so wb_format_for_display indents it beneath that row
# rather than at top-level depth.
wb_emit_with_agents() {
  local row="$1" level="${2:-0}" repo branch session ref ucount visit
  printf '%s\n' "$row"
  local -a f; wb_tsv_split "$row" f
  repo="${f[0]}"; branch="${f[2]}"; session="${f[6]}"; ref="${f[7]}"; ucount="${f[9]}"; visit="${f[12]:-0}"
  [ "${ucount:-0}" -gt 1 ] 2>/dev/null || return 0
  if [ "$level" -gt 0 ]; then
    wb_agent_subrows "$repo" "$session" "$ref" "$branch" "$visit" | wb_parent_subrows - "a$level"
  else
    wb_agent_subrows "$repo" "$session" "$ref" "$branch" "$visit"
  fi
}

# wb_parent_subrows <row|-> [marker] — return <row> (or every row on stdin,
# given "-") with its nesting marker (field 12) set to [marker], default
# "1" (sibling) — see the row schema above for the "cN"/"aN" forms.
# Everything else — including kind, still "task" on a sibling or child —
# is untouched: a nested task row is an independently live session, not a
# pane within one.
wb_parent_subrows() {
  local marker="${2:-1}"
  if [ "$1" = - ]; then cat; else printf '%s\n' "$1"; fi |
    awk -F'\t' -v OFS='\t' -v m="$marker" '{ $12 = m; print }'
}

# WB_NEST_MAX — deepest nesting level the picker indents a child to. A
# family deeper than this still nests (nothing is dropped or reordered out
# of its family); its deeper rows just render at this level. The cap is
# about NAME-column width, not termination — see _wb_emit_family.
WB_NEST_MAX=3

# _wb_emit_family <idx> <level> <marker> — emit row <idx> (field 12 set to
# <marker> when non-empty) plus its agent sub-rows, then recurse into every
# unconsumed live row whose parent: is <idx>'s own stem, one level deeper
# (clamped at WB_NEST_MAX), in the order `rows` holds them (most recent visit
# first, see collect_combined_rows). Termination doesn't rely on
# the cap: <idx> is marked consumed BEFORE recursing and only unconsumed
# rows are ever visited, so each row is emitted at most once and a parent:
# cycle (A -> B -> A) just ends where it closes. Reads _collect_combined_blocks'
# rows / parent_of / stem_of / consumed through bash's dynamic scoping.
_wb_emit_family() {
  local idx="$1" level="$2" marker="$3" row next j
  consumed[$idx]=1
  row="${rows[$idx]}"
  [ -n "$marker" ] && row="$(wb_parent_subrows "$row" "$marker")"
  wb_emit_with_agents "$row" "$level"
  [ -n "${stem_of[$idx]}" ] || return 0
  next=$(( level + 1 )); [ "$next" -le "$WB_NEST_MAX" ] || next="$WB_NEST_MAX"
  for j in "${!rows[@]}"; do
    [ -n "${consumed[$j]:-}" ] && continue
    [ "${parent_of[$j]}" = "${stem_of[$idx]}" ] || continue
    _wb_emit_family "$j" "$next" "c$next"
  done
}

# _WB_BLOCK_MARK — the line collect_combined_rows prints before each block,
# for wb_order_blocks to split the stream on. \001 can never open a real row
# (those start with a repo name), so it cannot be mistaken for one.
_WB_BLOCK_MARK=$'\001block'

# wb_order_blocks [each] — the picker's one ordering step. Reads rows with a
# _WB_BLOCK_MARK line before each block (the unit that must stay contiguous:
# one family, or one sibling group with its anchor, plus agent sub-rows) and
# prints the rows, marks dropped, in this order:
#   1. the block holding WB_PICKER_SESSION first (empty = nothing pinned);
#   2. then repos, the repo whose most recently visited block is newest first;
#   3. then blocks within a repo, most recently visited first;
# ties break by repo name, then the block's first label, then the order the
# walk emitted. A block's repo is its FIRST row's (the root or anchor), so a
# cross-repo child never drags its family into another repo's group, and the
# pinned block is left out of its repo's newest-visit so the rest of that
# repo sorts as if the pinned family were absent. Rows within a block share
# every key but their position, so the stable sort keeps the walk's own order
# (parent, children in visit order, agent sub-rows under their owner).
# Urgency is deliberately not a key anywhere: a status change must never move
# a row while the picker is open. "each" makes every row its own block, which
# is the dormant tab (no families there; field 13 is the transcript time).
# Two processes and a cut per call, never per row.
wb_order_blocks() {
  LC_ALL=C awk -F'\t' -v mark="$_WB_BLOCK_MARK" -v here="${WB_PICKER_SESSION:-}" -v each="${1:-}" '
    $0 == mark { open = 0; next }
    {
      if (!open || each != "") {
        nb++; open = 1; repo[nb] = $1; label[nb] = $2; bmax[nb] = 0; pin[nb] = 0
      }
      if ($13 + 0 > bmax[nb]) bmax[nb] = $13 + 0
      if (here != "" && $7 == here) pin[nb] = 1
      n++; line[n] = $0; blk[n] = nb
    }
    END {
      for (b = 1; b <= nb; b++)
        if (!pin[b] && bmax[b] > gmax[repo[b]] + 0) gmax[repo[b]] = bmax[b]
      for (i = 1; i <= n; i++) {
        b = blk[i]
        printf "%d\t%.0f\t%s\t%.0f\t%s\t%d\t%s\n", \
          (pin[b] ? 0 : 1), gmax[repo[b]] + 0, repo[b], bmax[b], label[b], b, line[i]
      }
    }' |
    LC_ALL=C sort -s -t $'\t' -k1,1n -k2,2nr -k3,3 -k4,4nr -k5,5 -k6,6n |
    cut -f7-
}

# collect_combined_rows — buffers collect_live_rows' output into an array
# (two passes, not a stream): deciding a group's anchor needs to see every
# live family member before emitting any of them, the same reason
# wb_board_render_html buffers its own ROWS=() rather than streaming.
#
# Rows are read most recently visited first (field 13), NOT most urgent
# first: urgency cycles as an agent works, and an order driven by it would
# shuffle rows under the cursor on every refresh. That one sort makes both
# the walk below and each family's child order visit order; wb_order_blocks
# then groups the finished blocks by repo and puts the current session's
# family on top.
#
# Pass 1 reads each row's own task file's parent: field once (empty when the
# row has no task file, no parent set, or the parent equals the row's own
# stem — self-reference is ignored, same guard U3's children map uses), and
# indexes live task rows by stem so a parent's own row can be found.
# Pass 2 emits, for each unconsumed row in that order, the family it
# belongs to, behind a _WB_BLOCK_MARK line:
#   - climb to the row's topmost LIVE ancestor (the family root);
#   - if the root's own parent isn't live but is shared by other unconsumed
#     rows, those are siblings: the earliest-created: one anchors (stable
#     across refreshes, unlike a live visit time, which moves every time
#     Jet attaches) and the rest follow as "~" sibling rows;
#   - each emitted row then pulls its own live children in beneath it via
#     _wb_emit_family, so a live parent's row always heads its children
#     (none of them left looking top-level).
# A row with no live relatives is a block of one. The marks, not a $(...)
# capture per family, are how blocks reach wb_order_blocks: _wb_emit_family
# records consumed[] in this scope, which a subshell would lose.
collect_combined_rows() { _collect_combined_blocks | wb_order_blocks; }

_collect_combined_blocks() {
  local -a rows=()
  local line
  while IFS= read -r line; do rows+=("$line"); done \
    < <(collect_live_rows | LC_ALL=C sort -t $'\t' -k13,13nr -k1,1 -k2,2)

  local -A parent_of=() stem_of=() idx_of_stem=()
  local i kind ref stem parent
  local -a f
  for i in "${!rows[@]}"; do
    wb_tsv_split "${rows[$i]}" f
    kind="${f[8]}"; ref="${f[7]}"; parent=""; stem=""
    if [ "$kind" = task ] && [ -f "$ref" ]; then
      parent="$(wb_get_frontmatter "$ref" parent)"
      stem="$(basename "$ref" .md)"
      wb_task_own_parent "$parent" "$stem" || parent=""
      [ -n "${idx_of_stem[$stem]:-}" ] || idx_of_stem[$stem]="$i"
    fi
    parent_of[$i]="$parent"; stem_of[$i]="$stem"
  done

  local -A consumed=() climbed=()
  local j root up anchor anchor_created created
  local -a group fj
  for i in "${!rows[@]}"; do
    [ -n "${consumed[$i]:-}" ] && continue

    # Climb to the topmost live, unconsumed ancestor. climbed[] guards a
    # parent: cycle among live rows — the climb stops at the first repeat.
    root="$i"; climbed=([$i]=1)
    while parent="${parent_of[$root]}"; [ -n "$parent" ]; do
      up="${idx_of_stem[$parent]:-}"
      [ -n "$up" ] && [ -z "${consumed[$up]:-}" ] && [ -z "${climbed[$up]:-}" ] || break
      climbed[$up]=1; root="$up"
    done

    parent="${parent_of[$root]}"
    group=()
    if [ -n "$parent" ] && [ -z "${idx_of_stem[$parent]:-}" ]; then
      for j in "${!rows[@]}"; do
        [ -n "${consumed[$j]:-}" ] && continue
        [ "${parent_of[$j]}" = "$parent" ] && group+=("$j")
      done
    fi
    if [ "${#group[@]}" -le 1 ]; then
      printf '%s\n' "$_WB_BLOCK_MARK"
      _wb_emit_family "$root" 0 ""
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

    printf '%s\n' "$_WB_BLOCK_MARK"
    _wb_emit_family "$anchor" 0 ""
    for j in "${group[@]}"; do
      [ -n "${consumed[$j]:-}" ] && continue
      _wb_emit_family "$j" 1 "1"
    done
  done
}

# collect_dormant_rows <mode> — dormant task rows (R10): status doing|review
# always, plus paused when <mode> is "search" (KTD9/R11 — the July
# presence-only decision keeps planned tasks out of every mode). A task only
# qualifies when it has a non-empty worktree: and at least one Claude
# transcript still on disk for that worktree (R7 — "dormant" IS "has a
# resumable conversation", not merely "not live"; retention purging every
# transcript degrades a task straight to cold with no verb run). Liveness is
# checked by resolving each LIVE session's own task file via
# wb_session_task_file (option-based, the same @task/@wb_repo/@wb_slug
# lookup wb_live_session_row itself uses) rather than matching on the
# session's NAME — a session renamed with `r` must still suppress its
# dormant row (KTD8). Rows reuse the same 13-field shape live rows do (field
# 13, the visit time, holds the newest transcript's epoch here), with
# kind=task and empty session/target, so picker()'s existing accept branch
# (`elif [ "$kind" = task ]; then cmd_new "$repo" "$slug"`) needs no change
# at all to resume one.
collect_dormant_rows() {
  local mode="$1" now; now="$(date +%s)"
  local -A live_files=()
  local session tf
  while IFS= read -r session; do
    [ -n "$session" ] || continue
    tf="$(wb_session_task_file "$session" 2>/dev/null)" || continue
    [ -n "$tf" ] && live_files["$tf"]=1
  done < <(tmux list-sessions -F '#{session_name}' 2>/dev/null)

  local -a all_files
  mapfile -t all_files < <(wb_task_files)
  [ "${#all_files[@]}" -gt 0 ] || return 0

  # Batch every task file's frontmatter through ONE awk process (see
  # wb_read_tasks_batch) rather than forking wb_read_task per file — this
  # loop runs against the WHOLE store (hundreds of files, most of which
  # aren't doing/review/paused at all), not just the handful that end up
  # qualifying, so per-file fork overhead here scales with store size, not
  # with how many dormant rows actually exist.
  local f status repo worktree branch title rank urank
  local worktree_abs transcripts newest age
  while IFS=$'\t' read -r f status repo worktree branch _path _deps _reviewed _sessions; do
    [ -n "$f" ] || continue
    [ -z "${live_files[$f]:-}" ] || continue
    case "$status" in
      doing|review) ;;
      paused)       [ "$mode" = search ] || continue ;;
      *)            continue ;;
    esac
    [ -n "$worktree" ] || continue
    worktree_abs="$(wb_repo_dir "$repo")/$worktree"
    transcripts="$(wb_transcripts "$worktree_abs")"
    [ -n "$transcripts" ] || continue
    newest="$(printf '%s\n' "$transcripts" | head -n1 | cut -f2)"
    age=$(( (now - newest) / 86400 ))
    [ "$age" -ge 0 ] || age=0
    title="$(wb_task_title "$f")"
    if [ -z "$title" ]; then title="${f##*/}"; title="${title%.md}"; fi
    case "$status" in
      doing) rank=0 ;; review) rank=1 ;; *) rank=2 ;;
    esac
    # Field 4 keeps the schema's status-rank-then-newest shape, but nothing
    # orders by it any more: _refresh_dormant groups by repo and sorts on
    # field 13 (the newest transcript), like the live tab.
    urank=$(( rank * 10000000000 + (9999999999 - newest) ))
    printf '%s\t%s\t%s\t%s\t~ %s %sd\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
      "$repo" "$title" "[$branch]" "$urank" "$status" "$age" "" "" "$f" task 0 "$branch" "" "$newest"
  done < <(wb_read_tasks_batch "${all_files[@]}")
}

# _WB_AWK_TEXT — awk helpers shared by the picker's formatters: count, cut
# and pad text by CHARACTER, not byte. They assume the awk runs under
# LC_ALL=C (every caller sets it), so mawk and gawk both see plain bytes and
# a UTF-8 name like "/verify-behaviour · checks.md" can be measured the same
# way under either: a character is one byte that is NOT a UTF-8 continuation
# byte (\200-\277), so its length is the byte length minus the continuation
# bytes. That needs no fork and no locale, and truncation walks forward by
# characters so it can never stop mid-sequence (which printed U+FFFD and, as
# the cell came up a byte short, shifted every column after it). Double-width
# glyphs (CJK) still count as one column; accepted, names here are Latin.
_WB_AWK_TEXT='
  function nch(s,    t) { t = s; return length(s) - gsub(/[\200-\277]/, "", t) }
  # cbytes(s, k) — byte length of the first k characters of s
  function cbytes(s, k,    p, len, c) {
    len = length(s); p = 0; c = 0
    while (c < k && p < len) {
      p++
      while (p < len && substr(s, p + 1, 1) ~ /[\200-\277]/) p++
      c++
    }
    return p
  }
  function pad(s, w,    n) {
    n = nch(s)
    # ASCII "..." on purpose, not a "…" glyph: some terminals render
    # that single codepoint as an ambiguous-width (2-column) character,
    # which silently threw off every column after it on truncated rows
    # while untruncated rows stayed correct — exactly the kind of
    # alignment bug that is invisible until a row actually truncates.
    if (n > w) return substr(s, 1, cbytes(s, w - 3)) "..."
    return s sprintf("%*s", w - n, "")
  }
  # padtail(s, w) — like pad(), but a value too long for w keeps its END
  # behind a leading "...": the tail of a branch name (its last segment)
  # says more than its head.
  function padtail(s, w,    n) {
    n = nch(s)
    if (n > w) return "..." substr(s, cbytes(s, n - (w - 3)) + 1)
    return s sprintf("%*s", w - n, "")
  }
'

# wb_picker_name_width — the NAME column's width: whatever the list pane has
# left once REPO, BRANCH, AGE and the three two-space separators are paid
# for. One function, so wb_format_for_display (the data rows) and
# wb_column_header (the legend) cannot disagree.
#
# The list pane is what fzf leaves beside the 55% preview. Measured against
# fzf 0.65.2 with picker()'s flags (--padding=6,1,2,1, --pointer='>',
# --preview-window right,55%,border-left) at 100, 160 and 200 columns: fzf
# exports FZF_COLUMNS = terminal width minus the 2 padding columns (C); the
# preview takes C*55/100 of that; and a row's text then gets C - 3 -
# C*55/100 columns, the 3 being the 2-column pointer/marker gutter plus the
# one column before the preview's border. A row exactly that wide fits; one
# column more ends in fzf's own ".." marker. Without FZF_COLUMNS (wb render
# by hand, picker()'s very first render before fzf runs) the terminal's
# width less the same 2 padding columns stands in, else 160.
# Below about 120 columns the floor below wins and fzf cuts the right edge.
wb_picker_name_width() {
  local c="${FZF_COLUMNS:-}" w
  case "$c" in ''|*[!0-9]*) c="$(tput cols 2>/dev/null)"; case "$c" in ''|*[!0-9]*) c=160 ;; esac; c=$((c - 2)) ;; esac
  w=$(( c - 3 - c * 55 / 100 - WB_COL_REPO - WB_COL_BRANCH - WB_COL_AGE - 6 ))
  [ "$w" -ge 20 ] || w=20
  printf '%s\n' "$w"
}

# wb_format_for_display [<snapshot_path>] — prepend a fixed-width, colored
# display string as a NEW field 1, pushing the original 13 fields to 2-14.
# Must run AFTER sorting (coloring/padding first would corrupt any sort
# keyed on the plain fields).
#
# fzf's --with-nth re-joins displayed fields with the raw tab delimiter, and
# a raw tab always jumps to the terminal's next fixed 8-column stop — so
# variable-length content (a long branch name, a long task title) throws off
# every column after it. Pre-rendering one string with explicit space padding
# (same approach claude-sessions.sh already uses) sidesteps that entirely;
# --with-nth=1 then shows ONLY this field, with the real data addressable as
# hidden fields 2-14 for binds/preview.
#
# What the string shows: REPO, NAME, BRANCH, AGE. Status is the NAME colour
# (finished cyan, done green, working yellow, else grey; a dormant row by
# its task status: doing yellow, review cyan, paused grey). A row that needs
# Jet (a live row at urank 0, not in the session Jet is in) is bold
# reverse-video, drawn with no other colour inside so it stays readable. The
# session Jet is in (WB_PICKER_SESSION) is all grey and tagged "(here)", and
# never needs anyone: its agent waiting on Jet is Jet's own business. A
# group's repo name is bold magenta on its first row when any row in the
# group needs Jet, so every row is read before any is drawn (render in END).
#
# <snapshot_path> (live tab only): the same pass writes what the picker's
# jump-to-next, header count and cursor restore need to a file — "count<TAB>N",
# then one "<pos><TAB><session><TAB><needs 0|1><TAB><here 0|1><TAB><target>
# <TAB><kind>" line per data row. pos counts from 1 over the data rows, which
# is exactly fzf's own pos() / $FZF_POS: with --header-lines the legend line
# is not counted (checked against fzf 0.65.2). An agent sub-row shares its
# owner's session, and often its pane too, so restoring a focused row takes
# session + target + kind. It goes to a private temp name and is mv'd into
# place, so a reader never sees half of it.
wb_format_for_display() {
  local snap="${1:-}" nw now
  nw="$(wb_picker_name_width)"
  # The clock the picker froze when it opened (ages must not tick while it
  # stays open); the bash builtin when unset, so no fork for it.
  printf -v now '%(%s)T' -1
  now="${WB_PICKER_NOW:-$now}"
  # LC_ALL=C: see _WB_AWK_TEXT — pad() relies on byte semantics.
  LC_ALL=C awk -F'\t' -v OFS='\t' -v wr="$WB_COL_REPO" -v wn="$nw" \
      -v wb="$WB_COL_BRANCH" -v wa="$WB_COL_AGE" -v now="$now" \
      -v snap="${snap:+$snap.$$.tmp}" "$_WB_AWK_TEXT"'
      # fit(s, w) — s cut to w characters with a "..." end, NOT padded
      function fit(s, w) {
        if (nch(s) > w) return substr(s, 1, cbytes(s, w - 3)) "..."
        return s
      }
      # age(v) — time since epoch second v: now, 12m, 3h, 4d; "-" = never
      function age(v,    dt) {
        if (v + 0 <= 0) return "-"
        dt = now - v
        if (dt < 60)    return "now"
        if (dt < 3600)  return int(dt / 60) "m"
        if (dt < 86400) return int(dt / 3600) "h"
        return int(dt / 86400) "d"
      }
      BEGIN {
        cur = ENVIRON["WB_PICKER_SESSION"]
        mg = "\033[1;35m"; gr = "\033[32m"; ye = "\033[33m"; dim = "\033[90m"
        cy = "\033[36m"; rs = "\033[0m"; rev = "\033[1;7m"
      }
      {
        n++
        lbl = $5; sub(/^[^ ]+ /, "", lbl)
        # A dormant row has no session and a "~ <status> <age>" label.
        dorm = ($7 == "" && $5 ~ /^~ /)
        # The session Jet is in, and the agent panes listed under it.
        hs = (!dorm && cur != "" && $7 == cur)
        # Needs Jet: urank 0 is the only signal (finished and done share
        # urank 1, so urank cannot choose colours; the label does that). A
        # session with more than one agent lists them as sub-rows and its own
        # row only repeats the most urgent one, so the sub-row that is
        # waiting counts and the owner row does not: one waiting pane, one
        # count, and `u` lands on the pane itself.
        nd = (!dorm && !hs && $4 != "" && $4 + 0 == 0 && ($9 == "agent" || $(10) + 0 <= 1))
        if (dorm) {
          w = lbl; sub(/ .*/, "", w)
          c = (w == "doing") ? ye : (w == "review") ? cy : dim
        } else if (lbl == "finished") c = cy
        else if (lbl == "done")       c = gr
        else if (lbl == "working")    c = ye
        else                          c = dim
        # Sub-rows repeat the parent row repo name and had no visual tie
        # back to it, which read as a sort/grouping bug rather than "this
        # belongs to the row above" -- blank the repeated REPO cell and
        # prefix NAME with an indent + ASCII connector so a sub-row is
        # unmistakable at a glance, regardless of what its own status color
        # happens to be. Plain ASCII on purpose, same reasoning as
        # wb_status_icon above: a Unicode tree glyph reintroduces the
        # cell-width alignment bug this file already moved away from.
        #
        # Independent nesting kinds can indent a row here: an agent
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
        #
        # A third kind, a child nested under its own live parent row
        # ("cN", N = level), gets " |- " rather than " ~ " so "child of
        # the row above" and "sibling of the row above" read differently.
        # Each level adds two leading spaces, and an agent sub-row owned by
        # a nested row ("aN") is indented to match, so the connectors stack.
        # Children are cross-repo too, so their repo cell stays visible.
        nest = $(12); lvl = 0
        if (nest ~ /^[ac][0-9]+$/) lvl = substr(nest, 2) + 0
        ind = ""; for (k = 1; k < lvl; k++) ind = ind "  "
        pre = ""
        if ($9 == "agent") {
          if (lvl > 0) ind = ind "  "
          pre = ind " > "; rcell[n] = pad("", wr)
        } else {
          rcell[n] = pad($1, wr)
          if (nest == "1")         pre = " ~ "
          else if (nest ~ /^c/)    pre = ind " |- "
        }
        txt = pre $2
        # The (here) tag is cut around, never cut off: shorten the name, not it.
        if (hs && $9 != "agent") ncell[n] = pad(fit(txt, wn - 7) " (here)", wn)
        else                     ncell[n] = pad(txt, wn)
        npre[n] = pre; ncol[n] = c
        # The stored "[branch]" brackets would spend two of the few
        # characters in the column on a truncated branch, so the cell drops
        # them.
        br = $3; sub(/^\[/, "", br); sub(/\]$/, "", br)
        bcell[n] = padtail(br, wb)
        # Agent sub-rows repeat the owner row time; show it once, on the owner.
        acell[n] = ($9 == "agent") ? pad("", wa) : pad(age($13), wa)
        mode[n] = hs ? 1 : (nd ? 2 : 0)
        sess[n] = $7; ishere[n] = hs; isneed[n] = nd; tgt[n] = $6; kd[n] = $9
        pt[n] = $1 OFS $2 OFS $3 OFS $4 OFS $5 OFS $6 OFS $7 OFS $8 OFS $9 OFS $(10) OFS $(11) OFS $(12) OFS $(13)
        # A block (a family: its root, children, siblings and agent
        # sub-rows) starts at a row that is not an agent sub-row and is not
        # nested; wb_order_blocks keeps each block whole.
        if (n == 1 || ($9 != "agent" && $12 == "")) { nb++; brepo[nb] = $1; bfirst[nb] = n }
        blk[n] = nb
        if (hs) bhere[nb] = 1
        if (nd) { bneed[nb] = 1; cnt++ }
      }
      END {
        # A group is a run of blocks whose first rows share a repo; the
        # block holding the current session is pinned first and is a group
        # of its own, so the rest of its repo forms a group below it.
        for (b = 1; b <= nb; b++) {
          if (b == 1 || brepo[b] != brepo[b - 1] || (b == 2 && bhere[1])) { g++; gfirst[g] = bfirst[b] }
          bg[b] = g
          if (bneed[b]) gneed[g] = 1
        }
        for (g = 1; g <= nb; g++) if (gfirst[g] != "" && gneed[g]) magenta[gfirst[g]] = 1
        for (i = 1; i <= n; i++) {
          if (mode[i] == 2) {
            # Reverse video swaps the colours, so the repo mark inside it
            # becomes a magenta block; the rest stays plain default colour.
            rc = magenta[i] ? "\033[35m" rcell[i] "\033[39m" : rcell[i]
            disp = rev rc "  " ncell[i] "  " bcell[i] "  " acell[i] rs
          } else if (mode[i] == 1) {
            disp = dim rcell[i] "  " ncell[i] "  " bcell[i] "  " acell[i] rs
          } else {
            # The connector is grey, the name carries the status colour.
            k = length(npre[i])
            nm = (k ? dim npre[i] rs : "") ncol[i] substr(ncell[i], k + 1) rs
            disp = (magenta[i] ? mg : dim) rcell[i] rs "  " nm "  " dim bcell[i] rs "  " dim acell[i] rs
          }
          print disp, pt[i]
        }
        if (snap != "") {
          print "count", cnt + 0 > snap
          for (i = 1; i <= n; i++) print i, sess[i], isneed[i] + 0, ishere[i] + 0, tgt[i], kd[i] > snap
          close(snap)
        }
      }'
  [ -z "$snap" ] || mv -f "$snap.$$.tmp" "$snap" 2>/dev/null || true
}

# wb_column_header — the legend line, in the SAME widths wb_format_for_display
# pads data rows to. Printed as a real line (trailing newline) so render_rows
# can prepend it straight into the piped rows as a `--header-lines=1` sticky
# row — that keeps it byte-locked to the data widths and pinned to the top of
# the list regardless of scrolling, unlike a separate --header string (which
# fzf always anchors near the prompt, not above the rows).
wb_column_header() {
  local nw; nw="$(wb_picker_name_width)"
  printf '\033[90m%-*s  %-*s  %-*s  %s\033[0m\n' \
    "$WB_COL_REPO" "REPO" "$nw" "NAME" "$WB_COL_BRANCH" "BRANCH" "AGE"
}

# render_rows <mode_file> [<view_file>] — the picker is two tabs, not one
# combined list: LIVE (default, <view_file> missing/"live") renders
# collect_combined_rows fresh on every call (repo groups, most recently
# visited first, the current session's family on top; see wb_order_blocks);
# DORMANT renders whatever's in
# <view_file>.cache, a snapshot _refresh_dormant last wrote. This split
# exists because collect_dormant_rows is genuinely expensive against a
# real task store (a full-store scan + a wb_transcripts stat-loop per
# candidate — ~2.7s measured against 232 tasks, vs ~0.4s for the live
# rows) and the picker's own periodic auto-refresh reloads every ~3s
# (see picker()'s `load:` bind) — recomputing it on that cadence made the
# dormant section visibly flash in and out every cycle. Caching means the
# fast periodic reload only ever touches the cheap live path; dormant
# content refreshes on tab-entry (_toggle_view) and ctrl-r
# (_refresh_dormant), never silently on a timer.
# <mode_file> holds "normal" or "search" (R11/KTD9) — read fresh on every
# call, since each invocation is its own process with no memory of the
# last one, so a stale in-flight auto-refresh still renders whatever the
# CURRENT mode actually is, never a stale pool. Also used by the fzf
# `reload`/`load` bindings (via `wb.sh render <mode_file> <view_file>`).
render_rows() {
  local view; view="$(cat "${2:-}" 2>/dev/null || echo live)"
  wb_column_header
  if [ "$view" = dormant ]; then
    # No snapshot here: a dormant row never needs Jet, and the live
    # snapshot stays as the live tab last left it.
    cat "${2}.cache" 2>/dev/null | wb_format_for_display
  else
    collect_combined_rows | wb_format_for_display "${2:+$2.snap}"
  fi
}

# _refresh_dormant <mode_file> <view_file> — recompute the dormant-tab cache
# (a no-op while the LIVE tab is active, so it's safe to fire unconditionally
# from ctrl-r regardless of which tab is showing). See render_rows' header
# comment for why this is cached rather than recomputed on every reload.
# Ordered the way the live tab is, with the newest transcript standing in for
# the visit time: grouped by repo, the repo with the newest transcript first,
# newest first inside it. Every row is its own block (no families here) and
# the empty session field means nothing is ever pinned.
_refresh_dormant() {
  local view; view="$(cat "${2:-}" 2>/dev/null || echo live)"
  [ "$view" = dormant ] || return 0
  local mode; mode="$(cat "$1" 2>/dev/null || echo normal)"
  collect_dormant_rows "$mode" | wb_order_blocks each > "${2}.cache"
}

# _toggle_view <mode_file> <view_file> — bound to `tab`: flips live<->dormant
# and, only when landing ON dormant, populates its cache synchronously
# before the caller's reload-sync render (see picker()'s `tab:` bind) so the
# very first render of the tab is never empty/stale.
_toggle_view() {
  local cur; cur="$(cat "${2:-}" 2>/dev/null || echo live)"
  if [ "$cur" = live ]; then printf 'dormant' > "$2"; else printf 'live' > "$2"; fi
  _refresh_dormant "$1" "$2"
}

# wb_status_line <context> <view> [<snapshot>] — fzf's --header, three lines:
# which tab (LIVE/DORMANT) with the need-you count and live-agent total, a
# colour legend for the statuses that tab shows, then the key hint for
# whichever search context (normal/search) is active — showing both at once
# (the original design) meant half the header was always irrelevant to what
# you could currently type. fzf keeps --header anchored near the prompt
# (bottom, with the default layout); the column names live separately, see
# wb_column_header. The count comes from the live render's snapshot (one
# line read) because this runs on every 3-second reload: the follow-up and
# capture counts it used to carry cost a whole-store awk each time, so they
# are gone. Legend colours are the codes wb_format_for_display draws rows
# with; keep the two in step.
wb_status_line() {
  local ctx="${1:-normal}" view="${2:-live}" snap="${3:-}" hint label legend need=""
  local rs=$'\033[0m'
  if [ "$ctx" = search ]; then
    hint='SEARCH: type to filter (includes paused) · esc back to normal'
  else
    # Thirteen keys in 120 columns leaves one space between pairs, so each key
    # is bold to keep the pairs apart (the text without the codes is 120).
    local b=$'\033[1m' n0=$'\033[22m'
    hint="${b}j/k g/G${n0} move ${b}l/enter${n0} open ${b}h/q${n0} quit ${b}u${n0} needs-you ${b}n${n0} new ${b}p${n0} down"
    hint+=" ${b}r${n0} rename ${b}b${n0} break ${b}ctrl-x${n0} done ${b}ctrl-r${n0} reload ${b}tab${n0} view ${b}/${n0} search"
  fi
  if [ "$view" = dormant ]; then
    label=DORMANT
    legend=$'\033[33mdoing'"$rs"$' \033[36mreview'"$rs"$' \033[90mpaused'"$rs"
  else
    label=LIVE
    legend=$'\033[1;7mneeds you'"$rs"$' \033[36mfinished'"$rs"$' \033[32mdone'"$rs"$' \033[33mworking'"$rs"$' \033[90midle'"$rs"$' \033[90m(here) you are here'"$rs"
    if [ -n "$snap" ]; then
      local _tag="" n=""
      { IFS=$'\t' read -r _tag n; } 2>/dev/null < "$snap" || true
      [[ "$_tag" == count && "$n" =~ ^[0-9]+$ ]] && need="$n need you · "
    fi
  fi
  printf 'wb · %s · %s%s agents live (warn >= %s)\n%s\n%s' \
    "$label" "$need" "$(wb_live_agent_count)" "$WB_AGENT_WARN_AT" "$legend" "$hint"
}

# _set_mode <mode_file> <value> — persist "normal"/"search" (KTD9), read
# fresh by render_rows on every call. Orthogonal to the LIVE/DORMANT view
# (_toggle_view) — search widens whichever tab is currently showing.
_set_mode() { printf '%s' "$2" > "$1"; }

# _mode_header <mode_file> <view_file> — the header for fzf's
# transform-header to swap in after entering/leaving search or switching
# tabs. Reads both files itself (rather than taking literal words) so it
# always reflects current state regardless of which bind fired it.
_mode_header() {
  wb_status_line "$(cat "${1:-}" 2>/dev/null || echo normal)" "$(cat "${2:-}" 2>/dev/null || echo live)" "${2:-}.snap"
}

# _next_needs <mode_file> <view_file> — bound to `u` through fzf's transform:
# prints the pos(N) action for the next row that needs Jet after the cursor
# ($FZF_POS), wrapping round to the first. Nothing to print on the dormant tab
# (no row there needs anyone) or in search mode (the snapshot's positions are
# the full list's, not the filtered one's), or with no such row.
_next_needs() {
  local mode view
  mode="$(cat "${1:-}" 2>/dev/null || echo normal)"
  view="$(cat "${2:-}" 2>/dev/null || echo live)"
  [ "$view" = live ] && [ "$mode" = normal ] || return 0
  awk -F'\t' -v cur="${FZF_POS:-0}" '
    NR > 1 && $3 == 1 { if (!first) first = $1; if (!nxt && $1 + 0 > cur + 0) nxt = $1 }
    END { p = nxt ? nxt : first; if (p) print "pos(" p ")" }
  ' "${2:-}.snap" 2>/dev/null || true
}

# _initial_pos <mode_file> <view_file> — chained onto fzf's `load` bind through
# transform, so it runs after every reload (fzf's own first `load` is for the
# list picker() rendered before starting it). Prints a pos(N) action, or
# nothing.
#   First call (the one-shot flag <view>.initpos absent): the opening cursor
#   (R14) — the first row that needs Jet; else the row below Jet's own row (and
#   its agent sub-rows); else row 1.
#   Later calls: put the cursor back on the row Jet was on. fzf's --track
#   matches whole lines and a status flip changes the line, so a reload can
#   strand the cursor; the focus bind records "<session><TAB><target><TAB>
#   <kind>" in <view>.focus, and this finds that row again by the same three,
#   else by session and pane, else by session alone (the pane went away).
# Silent on the dormant tab and in search mode (positions there are the
# filtered list's), with no snapshot, or when the session is gone.
_initial_pos() {
  local mode view snap="${2:-}.snap"
  mode="$(cat "${1:-}" 2>/dev/null || echo normal)"
  view="$(cat "${2:-}" 2>/dev/null || echo live)"
  [ "$view" = live ] && [ "$mode" = normal ] && [ -r "$snap" ] || return 0
  if [ ! -e "${2:-}.initpos" ]; then
    : > "${2:-}.initpos"
    awk -F'\t' '
      NR > 1 { n++; if ($3 == 1 && !need) need = $1; if ($4 == 1) here = $1 }
      END {
        if (!n) exit
        p = need ? need : (here && here < n) ? here + 1 : 1
        print "pos(" p ")"
      }
    ' "$snap"
    return 0
  fi
  [ -s "${2:-}.focus" ] || return 0
  local -a fc; wb_tsv_split "$(cat "${2:-}.focus")" fc
  [ -n "${fc[0]:-}" ] || return 0
  awk -F'\t' -v s="${fc[0]}" -v t="${fc[1]:-}" -v k="${fc[2]:-}" '
    # "" forces a string compare: a session named 12 must not equal 12.0
    NR > 1 && ($2 "") == (s "") {
      if (!a) a = $1
      if (!b && ($5 "") == (t "")) b = $1
      if (($5 "") == (t "") && ($6 "") == (k "")) { c = $1; exit }
    }
    END { p = c ? c : b ? b : a; if (p) print "pos(" p ")" }
  ' "$snap"
}

# wb_capture_pane <target> — the pane's current screen, colours kept. A seam
# so tests can stand in for a live pane without a tmux shim.
wb_capture_pane() { tmux capture-pane -ep -t "$1" 2>/dev/null; }

# _preview <target> <ref> <kind> — what fzf shows beside the focused row
# (KTD9). Four cases, first match wins: a live pane (its bottom), a task file
# (title, status/branch, latest hand-written Handoff), a git dir (status, or
# "clean"), else a plain "nothing to preview" so the pane never shows a git
# error. <kind> is accepted because fzf passes {10}, but the shape of <ref>
# already decides. Always exits 0: fzf paints a non-zero preview as an error.
_preview() {
  local target="${1:-}" ref="${2:-}" out
  if [ -n "$target" ]; then
    # Trailing blank screen lines are what a half-empty pane is made of;
    # without trimming them, tailing to the window shows only empty rows.
    # A line holding only colour codes and spaces counts as blank.
    wb_capture_pane "$target" | awk -v n="${FZF_PREVIEW_LINES:-40}" '
      { line[NR] = $0; t = $0; gsub(/\033\[[0-9;?]*[A-Za-z]/, "", t); if (t ~ /[^ \t\r]/) last = NR }
      END { s = last - n + 1; if (s < 1) s = 1; for (i = s; i <= last; i++) print line[i] }
    '
  elif [ -f "$ref" ]; then
    wb_task_title "$ref"
    printf 'status: %s · branch: %s\n' "$(wb_get_frontmatter "$ref" status)" "$(wb_get_frontmatter "$ref" branch)"
    # Latest entry under ## Handoffs whose heading does not end in "(auto)":
    # the automatic ones only record that wb paused/resumed, never what the
    # work was. Entries run to the next ### or ## heading.
    awk '
      /^## / { inh = ($0 ~ /^## Handoffs[ \t]*$/); keep = 0; next }
      !inh { next }
      /^### / { keep = ($0 !~ /\(auto\)[ \t]*$/); if (keep) { buf = $0; blanks = ""; found = 1 }; next }
      keep { if ($0 ~ /^[ \t]*$/) blanks = blanks "\n"; else { buf = buf blanks "\n" $0; blanks = "" } }
      END { if (found) print "\n" buf }
    ' "$ref"
  elif [ -d "$ref" ] && git -C "$ref" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    out="$(git -C "$ref" -c color.status=always status -s 2>/dev/null)"
    printf '%s\n' "${out:-clean}"
  else
    echo "nothing to preview"
  fi
  return 0
}

# _preview_label <target> <ref> — the preview border label for the same four
# cases, so Jet can tell a pane from a task summary at a glance (R21).
_preview_label() {
  local target="${1:-}" ref="${2:-}"
  if [ -n "$target" ]; then printf ' pane '
  elif [ -f "$ref" ]; then printf ' task '
  elif [ -d "$ref" ] && git -C "$ref" rev-parse --is-inside-work-tree >/dev/null 2>&1; then printf ' git status '
  else printf ' wb '
  fi
}

# cmd_task_file [--edit] — resolve the CURRENT tmux session's task file and
# either print its path (default: composable, so `nvim "$(wb task-file)"` and
# scripts both work) or open it in $EDITOR (--edit, what prefix+t uses).
#
# Resolution is wb_session_task_file's @task-first lookup — the same one
# /wb-save and /wb-resume use — never a cwd- or branch-derived guess, so a
# session migrated by `wb breakdown --apply` opens its OWN file rather than
# its parent's. That resolver's repo/slug fallback only BUILDS a path and
# doesn't check it exists, hence the explicit -f test below.
#
# Under --edit the error paths hold the terminal: prefix+t runs this in a
# `new-window` that closes the instant the command returns, so an unheld
# message is overdrawn before it can be read (same convention as _rename).
# Printing mode stays quiet and script-friendly.
cmd_task_file() {
  local edit=0
  [ "${1:-}" = --edit ] && edit=1

  _tf_fail() {
    echo "wb task-file: $1" >&2
    [ "$edit" = 1 ] && read -rn1 -p "wb task-file: press any key "
    return 1
  }

  if [ -z "${TMUX:-}" ]; then
    _tf_fail "not inside tmux — there's no session to resolve a task from"
    return 1
  fi

  local session task_file
  session="$(tmux display-message -p '#S' 2>/dev/null || true)"
  if [ -z "$session" ]; then
    _tf_fail "could not determine the current tmux session"
    return 1
  fi

  # Ends in the same "not a wb task session" wording that
  # _wb_resolve_session_and_task (pause/down/reviewed) and cmd_done use, so
  # the verbs report an identical failure identically.
  if ! task_file="$(wb_session_task_file "$session")" || [ -z "$task_file" ]; then
    _tf_fail "$session has no @task/@wb_repo — not a wb task session"
    return 1
  fi
  if [ ! -f "$task_file" ]; then
    _tf_fail "no task file at $task_file (resolved from $session) — it may have been moved or deleted"
    return 1
  fi

  if [ "$edit" = 1 ]; then
    "${EDITOR:-nvim}" "$task_file"
  else
    printf '%s\n' "$task_file"
  fi
}

# ---------------------------------------------------------------------------
# wb family — a task's parent/child family, for the decision-propagation step.
# ---------------------------------------------------------------------------

# _wb_family_stems <task_file> — the family's stems, one per line: the top
# parent first, then every descendant depth-first, each once. The climb is
# _wb_concepts_paths' guarded walk (seen-set, depth cap 20, self-parent,
# stop at a missing parent file); the descent uses a parent -> children map
# built in ONE pass over wb_task_files (as wb_board_v2_build does) with its
# own seen-set, so a hand-edited cycle can't loop either direction.
_wb_family_stems() {
  local task_file="$1"
  local -A seen=() kids=() out=()
  local depth=0 max_depth=20 stem parent_ref parent_file
  local current_file="$task_file"
  local root; root="$(basename "$task_file" .md)"

  while [ "$depth" -lt "$max_depth" ]; do
    stem="$(basename "$current_file" .md)"
    seen[$stem]=1
    root="$stem"
    depth=$((depth + 1))
    parent_ref="$(wb_get_frontmatter "$current_file" parent)"
    [ -n "$parent_ref" ] || break
    wb_task_own_parent "$parent_ref" "$stem" || break
    [ -z "${seen[$parent_ref]:-}" ] || break
    parent_file="$TASKS_DIR/$parent_ref.md"
    [ -f "$parent_file" ] || break
    current_file="$parent_file"
  done

  local f
  while IFS= read -r f; do
    stem="$(basename "$f" .md)"
    parent_ref="$(wb_get_frontmatter "$f" parent)"
    [ -n "$parent_ref" ] || continue
    wb_task_own_parent "$parent_ref" "$stem" || continue
    kids[$parent_ref]+=" $stem"
  done < <(wb_task_files)

  local -a stack=("$root") children=()
  local i
  while [ "${#stack[@]}" -gt 0 ]; do
    stem="${stack[-1]}"
    unset 'stack[-1]'
    [ -z "${out[$stem]:-}" ] || continue
    out[$stem]=1
    printf '%s\n' "$stem"
    read -ra children <<< "${kids[$stem]:-}"
    for ((i = ${#children[@]} - 1; i >= 0; i--)); do
      stack+=("${children[i]}")
    done
  done
}

# cmd_family <task-ref> [--sessions|--reseed]
#   (none)      the family's stems, one per line (_wb_family_stems).
#   --sessions  stem<TAB>session<TAB>title per live tmux session working on a
#               family task. A session is matched by its @task option (KTD2:
#               after `wb breakdown --apply` a continuing child keeps the
#               parent's session NAME while @task points at the child), and
#               by session name only when @task is unset.
#   --reseed    re-run _wb_seed_concepts_file for every family worktree that
#               exists, so a newly-written CONCEPTS.md is linked without a
#               `wb new`. Prints `reseeded <stem> <path>` / `skipped <stem>
#               (<reason>)` / `failed <stem> (<path>)`; best-effort like the
#               seed in cmd_new (a failure doesn't stop the rest) but exits 1
#               if any seed failed. Writes only the untracked CLAUDE.local.md
#               block: no tmux, no task lock, no task-store write.
#   --concepts  <task>'s CONCEPTS.md files up its parent chain, nearest first
#               (_wb_concepts_paths, the same walk the seed links), so the
#               promotion step writes to the file worktrees actually import.
# --reseed is the only mode that touches the disk. Stdout stays script-friendly, like
# cmd_task_file; diagnostics go to stderr.
cmd_family() {
  local query="${1:-}" mode="${2:-}"
  case "$mode" in
    ''|--sessions|--reseed|--concepts) ;;
    *) echo "usage: wb family <task-ref> [--sessions|--reseed|--concepts]" >&2; exit 1 ;;
  esac
  if [ -z "$query" ] || [ $# -gt 2 ]; then
    echo "usage: wb family <task-ref> [--sessions|--reseed|--concepts]" >&2
    exit 1
  fi

  local file
  file="$(_wb_append_resolve_task "$query" "wb family")" || exit 1
  if [ "$mode" = --concepts ]; then
    _wb_concepts_paths "$file"
    return 0
  fi

  local -a stems=()
  local stem
  while IFS= read -r stem; do
    stems+=("$stem")
  done < <(_wb_family_stems "$file")

  case "$mode" in
    '')
      printf '%s\n' "${stems[@]}"
      ;;
    --sessions)
      local -A member=()
      for stem in "${stems[@]}"; do member[$stem]=1; done
      local session cur
      while IFS= read -r session; do
        [ -n "$session" ] || continue
        cur="$(tmux show -t "=$session:" -v @task 2>/dev/null || true)"
        if [ -n "$cur" ]; then
          stem="$(basename -- "$cur" .md)"
        else
          stem="$session"
        fi
        [ -n "${member[$stem]:-}" ] || continue
        printf '%s\t%s\t%s\n' "$stem" "$session" "$(wb_task_title "$TASKS_DIR/$stem.md")"
      done < <(tmux list-sessions -F '#{session_name}' 2>/dev/null || true)
      ;;
    --reseed)
      local rc=0 member_file repo wt_field worktree_path
      for stem in "${stems[@]}"; do
        member_file="$TASKS_DIR/$stem.md"
        # _wb_seed_concepts_file returns 0 both when it seeds and when there
        # is nothing to seed, so ask the resolver directly which it was.
        if [ -z "$(_wb_concepts_paths "$member_file")" ]; then
          echo "skipped $stem (no concepts file)"
          continue
        fi
        repo="$(wb_get_frontmatter "$member_file" repo)"
        wt_field="$(wb_get_frontmatter "$member_file" worktree)"
        read -r wt_field <<< "$wt_field"
        if [ -z "$wt_field" ]; then
          echo "skipped $stem (no worktree: field)"
          continue
        fi
        if [ -z "$repo" ] || ! _wb_safe_worktree_field "$wt_field"; then
          echo "skipped $stem (unsafe or unusable worktree: field)"
          continue
        fi
        worktree_path="$(wb_repo_dir "$repo")/$wt_field"
        if [ ! -d "$worktree_path" ]; then
          echo "skipped $stem (no worktree dir)"
          continue
        fi
        if _wb_seed_concepts_file "$member_file" "$worktree_path" 2>/dev/null; then
          echo "reseeded $stem $worktree_path"
        else
          echo "failed $stem ($worktree_path)"
          rc=1
        fi
      done
      return "$rc"
      ;;
  esac
}

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

# _down <session> — bound to `p`; wraps cmd_down with the picker's usual
# self-target guard: the picker is commonly launched via `new-window` with
# no `-t` (tmux.conf's `bind m`/`bind a`), so it opens inside whatever
# session you're already in, and that session shows up as a selectable row
# like any other — closing THAT row would otherwise kill the very pane
# running the picker (mirrors _ctrl_x's own task-row self-target guard).
# cmd_down --keep-session still writes the snapshot and marks `review` on
# an open PR either way; only the kill is skipped. Same hold-the-terminal-
# on-failure convention as _rename.
_down() {
  local session="$1"
  [ -n "$session" ] || return 0
  if [ -n "${TMUX:-}" ] && [ "$session" = "$(tmux display-message -p '#S' 2>/dev/null)" ]; then
    if ! cmd_down --keep-session "$session"; then
      read -rn1 -p "wb: down failed — press any key "
      return 1
    fi
    read -rn1 -p "wb: not closing '$session' via p — it's your current session; run 'wb down' yourself once you're ready — press any key "
    return 0
  fi
  if ! cmd_down "$session"; then
    read -rn1 -p "wb: down failed — press any key "
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

# _new — bound to `n` (R12): prompts for a repo, defaulting to the picker's
# OWN launching session's @wb_repo when it has one (no default outside a wb
# session — the picker's `-c "$HOME"` launch means the current directory no
# longer says which repo you're in), then a slug. An empty slug opens a
# plain repo session instead of a task (tmux_attach_or_create), mirroring
# what typing `:new` in tmux itself already does. Bound with `become`, not
# execute+reload, since cmd_new/tmux_attach_or_create already switch the
# client themselves — returning to the picker's own list afterward would
# just show a stale render for a beat before the switch takes effect.
_new() {
  local default_repo repo slug
  default_repo="$(tmux display-message -p '#{@wb_repo}' 2>/dev/null || true)"
  read -r -p "New — repo${default_repo:+ [$default_repo]}: " repo
  repo="${repo:-$default_repo}"
  if [ -z "$repo" ]; then
    read -rn1 -p "wb: a repo is required — press any key "
    return 1
  fi
  read -r -p "New — slug (blank = plain session): " slug
  if [ -n "$slug" ]; then
    cmd_new "$repo" "$slug"
  else
    tmux_attach_or_create "$repo" "$(wb_repo_dir "$repo")"
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
  local kind="$1" session="$2" target="$3" ref="${4:-}"
  case "$kind" in
    task)
      if [ -n "$session" ]; then
        # Never run the wind-down from inside the doomed worktree. tmux.conf's
        # `bind m`/`bind a` anchor the picker at $HOME, which covers the
        # keybind path — but `wb` is also a zsh alias run from an ordinary
        # shell, and that shell's cwd IS commonly the worktree ctrl-x is about
        # to tear down. cmd_done itself is cwd-independent (its removal is
        # `git -C "$repo_dir" worktree remove "$worktree_path"`, both
        # absolute), so this only protects THIS process from ending up with a
        # deleted cwd mid-teardown. Guarded so a missing $HOME can't abort the
        # wind-down under set -e.
        cd "$HOME" 2>/dev/null || true
        if [ -n "${TMUX:-}" ] && [ "$session" = "$(tmux display-message -p '#S' 2>/dev/null)" ]; then
          cmd_done "$session"
          echo "wb: not closing '$session' via ctrl-x — it's your current session; run 'wb done --close' yourself once you're ready to leave it" >&2
        else
          cmd_done "$session" --close
        fi
      elif [ -n "$ref" ]; then
        # Dormant row (R10): no live session for @wb_repo/@wb_slug to
        # resolve from at all — cmd_done's own KTD7 store-only path
        # resolves a task-file stem instead, same mechanism the printed
        # "wb done <parent-stem>" nudge already relies on.
        cmd_done "$(basename "$ref" .md)"
      fi
      ;;
    repo)  [ -n "$session" ] && tmux kill-session -t "=$session" 2>/dev/null ;;
    agent) [ -n "$target" ]  && tmux kill-pane -t "$target" 2>/dev/null ;;
  esac
}

# wb_preview_cmd — the picker's --preview: the session context card
# (claude-card.sh) for a live row's pane ({7}) or a dormant row's task file
# ({9}; dormant rows have no session, {8}); when the card prints nothing (a
# pane with no Claude session, a live session with no Claude pane, a repo
# row), _preview below: the pane's bottom, the task's laid-out summary, the
# repo's git status, or "nothing to preview". A card that exits 3 (a live
# session with no logged turns yet) is only its state lines, so _preview
# follows it.
# fzf runs it with $SHELL, so it stays plain sh that zsh also reads.
wb_preview_cmd() {
  printf '%s' "c=\$('$SCRIPT_DIR/claude-card.sh' \"\$([ -n {7} ] && echo {7} || { [ -z {8} ] && echo {9}; })\"); rc=\$?;" \
    " [ -n \"\$c\" ] && printf '%s\\n\\n' \"\$c\";" \
    " if [ -z \"\$c\" ] || [ \"\$rc\" = 3 ]; then" \
    " '$SELF' _preview {7} {9} {10}; fi"
}

picker() {
  # Not `local`: an EXIT trap fires when the whole script exits, which for
  # the success path (no explicit `exit` below) happens AFTER picker()
  # already returned and popped its locals — referencing a local
  # mode_file/view_file from the trap at that point is an unbound-variable
  # crash under set -u. A plain (script-global) variable stays in scope
  # for the trap either way.
  mode_file="$(mktemp -t wb-mode.XXXXXX)"
  view_file="$(mktemp -t wb-view.XXXXXX)"
  echo normal > "$mode_file"
  echo live > "$view_file"
  trap 'rm -f "$mode_file" "$view_file" "$view_file.cache" "$view_file.snap" "$view_file.focus" "$view_file.initpos"' EXIT

  # The session Jet is in and the moment the picker opened, for every fzf
  # child (render/transform/preview inherit the environment) to pin the
  # current session's family and age rows against one frozen clock instead
  # of re-reading a ticking one on each 3s reload. Unset (wb render run by
  # hand, tests) means no pinning and the real clock.
  export WB_PICKER_SESSION="$(tmux display-message -p '#S' 2>/dev/null || true)"
  export WB_PICKER_NOW="$(date +%s)"

  local rendered selection
  rendered="$(render_rows "$mode_file" "$view_file")"
  if [ -z "$rendered" ]; then
    echo "wb: no live sessions found." >&2
    exit 0
  fi

  # Modal navigation mirrors claude-sessions.sh: NORMAL disables search so
  # unbound keys are inert; i or / enters SEARCH. `x` is gone with the old
  # interrupt key; `n` is new; `tab` is back, now toggling LIVE<->DORMANT
  # (not the old combined/sessions/agents cycle it used to drive).
  local navkeys='j,k,g,G,q,i,r,b,p,n,u,/'

  # Field 1 is the pre-rendered display string (see wb_format_for_display);
  # fields 2-14 are the real data, shown to fzf only as hidden/addressable
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
        --header="$(wb_status_line normal live "$view_file.snap")" \
        --no-sort \
        --preview "$(wb_preview_cmd)" \
        --preview-window 'right,55%,wrap,border-left' \
        --preview-label ' wb ' \
        --bind 'start:disable-search' \
        --bind "focus:transform-preview-label(\"$SELF\" _preview-label {7} {9})+execute-silent(printf '%s\t%s\t%s\n' {8} {7} {10} > \"$view_file.focus\")" \
        --bind "load:reload(sleep 3; \"$SELF\" render \"$mode_file\" \"$view_file\")+refresh-preview+transform-header(\"$SELF\" _mode-header \"$mode_file\" \"$view_file\")+transform(\"$SELF\" _initial-pos \"$mode_file\" \"$view_file\")" \
        --bind "u:transform(\"$SELF\" _next-needs \"$mode_file\" \"$view_file\")" \
        --bind 'j:down' --bind 'k:up' --bind 'g:first' --bind 'G:last' \
        --bind 'ctrl-d:half-page-down' --bind 'ctrl-u:half-page-up' \
        --bind 'l:accept' --bind 'h:abort' --bind 'q:abort' \
        --bind "ctrl-r:execute-silent(\"$SELF\" _refresh-dormant \"$mode_file\" \"$view_file\")+reload-sync(\"$SELF\" render \"$mode_file\" \"$view_file\")+refresh-preview" \
        --bind "tab:execute-silent(\"$SELF\" _toggle-view \"$mode_file\" \"$view_file\")+reload-sync(\"$SELF\" render \"$mode_file\" \"$view_file\")+transform-header(\"$SELF\" _mode-header \"$mode_file\" \"$view_file\")" \
        --bind "r:execute(\"$SELF\" _rename {8})+reload-sync(\"$SELF\" render \"$mode_file\" \"$view_file\")+refresh-preview" \
        --bind "b:execute(\"$SELF\" _break-out {7})+reload-sync(\"$SELF\" render \"$mode_file\" \"$view_file\")+refresh-preview" \
        --bind "p:execute(\"$SELF\" _down {8})+reload-sync(\"$SELF\" render \"$mode_file\" \"$view_file\")+refresh-preview" \
        --bind "n:become(\"$SELF\" _new)" \
        --bind "ctrl-x:become(\"$SELF\" _ctrl-x {10} {8} {7} {9})" \
        --bind "i:execute-silent(\"$SELF\" _set-mode \"$mode_file\" search)+unbind($navkeys)+enable-search+change-prompt(SEARCH )+reload-sync(\"$SELF\" render \"$mode_file\" \"$view_file\")+transform-header(\"$SELF\" _mode-header \"$mode_file\" \"$view_file\")" \
        --bind "/:clear-query+execute-silent(\"$SELF\" _set-mode \"$mode_file\" search)+unbind($navkeys)+enable-search+change-prompt(SEARCH )+reload-sync(\"$SELF\" render \"$mode_file\" \"$view_file\")+transform-header(\"$SELF\" _mode-header \"$mode_file\" \"$view_file\")" \
        --bind "esc:enable-search+clear-query+disable-search+execute-silent(\"$SELF\" _set-mode \"$mode_file\" normal)+rebind($navkeys)+change-prompt(NORMAL )+reload-sync(\"$SELF\" render \"$mode_file\" \"$view_file\")+transform-header(\"$SELF\" _mode-header \"$mode_file\" \"$view_file\")")" || exit 0

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
    # KTD7: a dormant row's `slug` field is $branch, not the task's real
    # slug (see collect_dormant_rows) — for an ordinary task branch equals
    # the raw slug, but for a wb-breakdown migrated child, branch: is the
    # PARENT's inherited identity while the child's own file is a distinct
    # stem. Deriving the task file from repo+slug here (cmd_new's default)
    # would resolve back onto the parent. $ref is already the real target
    # file this row was read from — hand it through, same override
    # cmd_resume uses for the identical hazard.
    _WB_TASK_FILE_OVERRIDE="$ref" cmd_new "$repo" "$slug"
    unset _WB_TASK_FILE_OVERRIDE
  fi
}

# ---------------------------------------------------------------------------
# wb help — the verb list
# ---------------------------------------------------------------------------

# cmd_help — prints this file's OWN header usage block (the `#   wb <verb>`
# lines at the top) instead of a second, hand-maintained copy. That block is
# already formatted as a usage screen, and tests/wb-help.test.sh asserts
# every verb the dispatch at the bottom accepts actually appears in it, so
# the two can't silently drift — the drift this verb was added to fix
# (`wb breakdown` had been missing from the header since it shipped).
# @@WB_SET_FIELDS@@ is substituted with the live allowlist so the printed
# help can never disagree with what cmd_set itself accepts.
cmd_help() {
  local body
  body="$(awk '
    /^#   wb / { inblock = 1 }
    inblock && !/^#   / { exit }
    inblock { sub(/^# ?/, ""); print }
  ' "$SELF")"
  if [ -z "$body" ]; then
    echo "wb help: could not read the usage block from $SELF" >&2
    return 1
  fi
  printf 'wb (workbench) — session-per-worktree tasks + the unified picker.\n\nUsage:\n'
  printf '%s\n' "${body//@@WB_SET_FIELDS@@/$WB_SET_FIELDS}"
  printf '\nGuide: dotfiles/docs/wb-guide.md\n'
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
    down)        shift; cmd_down "$@" ;;
    pr-open)     shift; cmd_pr_open "$@" ;;
    reviewed)    shift; cmd_reviewed "$@" ;;
    task-file)   shift; cmd_task_file "$@" ;;
    jira-set)    shift; cmd_jira_set "$@" ;;
    unsafe-rewind) shift; cmd_unsafe_rewind "$@" ;;
    append)      shift; cmd_append "$@" ;;
    family)      shift; cmd_family "$@" ;;
    week)        shift; cmd_week "$@" ;;
    status)      shift; cmd_status "$@" ;;
    set)         shift; cmd_set "$@" ;;
    install-hooks) shift; cmd_install_hooks "$@" ;;
    render)      shift; render_rows "$@" ;;
    _new)        shift; _new "$@" ;;
    _down)       shift; _down "$@" ;;
    _rename)     shift; _rename "$@" ;;
    _break-out)  shift; _break_out "$@" ;;
    _ctrl-x)     shift; _ctrl_x "$@" ;;
    _set-mode)   shift; _set_mode "$@" ;;
    _toggle-view)   shift; _toggle_view "$@" ;;
    _refresh-dormant) shift; _refresh_dormant "$@" ;;
    _mode-header) shift; _mode_header "$@" ;;
    _initial-pos) shift; _initial_pos "$@" ;;
    _next-needs) shift; _next_needs "$@" ;;
    _preview)    shift; _preview "$@" ;;
    _preview-label) shift; _preview_label "$@" ;;
    help|--help|-h) cmd_help ;;
    # Bare `wb` is the picker; an unknown TOKEN is a typo, not a picker
    # query. It used to be handed to fzf as --query, so `wb set` typed on a
    # checkout without the verb opened the picker instead of erroring —
    # and in a non-tty context that surfaced as fzf's "inappropriate ioctl
    # for device" rather than anything about wb. Nothing invokes `wb
    # <query>` (tmux.conf binds plain `wb.sh`), so the query pass-through
    # had no caller to keep.
    '')          picker "" ;;
    *)           printf "wb: unknown verb '%s' — try wb help\n" "$1" >&2; exit 2 ;;
  esac
fi
