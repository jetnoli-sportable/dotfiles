#!/usr/bin/env bash
# pretooluse-guard.sh — Claude Code PreToolUse hook, layer 1 ("ask") of the
# TASKS_DIR concurrency-safety scheme.
#
# ~/code/tasks is a shared git checkout many concurrent Claude Code agent
# sessions write into. Two real incidents happened when an agent typed a raw
# `git reset --hard` (or similar) straight into a Bash tool call scoped at
# that directory, silently orphaning another session's unpushed commits.
# This script is a cheap "dumb pattern + directory matcher": it does NOT try
# to judge whether a command would actually orphan a commit — it only asks
# the operator to confirm before a dangerous-shaped git command runs
# anywhere under ~/code/tasks, or before an Edit/Write/MultiEdit or a
# write-shaped Bash command lands on a task another session is working on
# right now. The real
# correctness judgment lives in a separate git-side hook (a different unit,
# not this script) — that hook still gets its own say even after this one
# says "ask" and the operator approves.
#
# This script NEVER returns permissionDecision "deny" — only "ask" or
# "allow" (the latter only via the wb-unsafe-rewind sentinel escape hatch,
# see below). A broken/misconfigured guard must never block every Bash call
# an agent makes, so any internal error (missing jq, bad JSON, ...) fails
# OPEN: exit 0 with a single stderr note. The git-side hook is the real
# backstop; this is just an early, cheap warning to a human.
#
# Registered twice in claude/.claude/settings.recommended.json's PreToolUse
# block: once matched on tool_name "Bash" (dangerous-git-command + directory
# scoping, below, then H25: write-shaped commands follow H24's contention
# rule), once matched on "Edit|Write|MultiEdit" (H24: writes to a
# task file or its dossier ask only when another live tmux session's @task
# is that task, or its wb side-car lock is held by another session right
# now; everything else gets no decision. An ask on every write was approved
# 526 times out of 526 over two weeks, and Edit/Write already refuse a write
# to a file that changed since it was read).
#
# Style note: this is a sibling of claude-notify-hook.sh (same stdin-guard
# `[ ! -t 0 ]` pattern, same $HOME-based paths) but deliberately departs from
# its "always exit 0" property at the decision path — this script sometimes
# prints an "ask" (or sentinel-gated "allow") JSON payload to stdout instead.
#
# PreToolUse hook contract (code.claude.com/docs/en/hooks):
#   stdin:  JSON with top-level cwd / tool_name / tool_input.{command,file_path}
#   stdout (exit 0): {"hookSpecificOutput":{"hookEventName":"PreToolUse",
#                      "permissionDecision":"ask"|"allow"|"deny",
#                      "permissionDecisionReason":"..."}}
#   exit 0 with no stdout = proceed normally (no explicit decision).
#   Any non-zero-non-2 exit is a non-blocking error (tool call proceeds
#   anyway) — this is what H8's fail-open relies on.
set -uo pipefail

TASKS_DIR="${TASKS_DIR:-$HOME/code/tasks}"
KILL_SWITCH="${XDG_STATE_HOME:-$HOME/.local/state}/wb/disable-agent-hook"
SENTINEL_FILE="$TASKS_DIR/.git/WB_ALLOW_REWIND"
SENTINEL_TTL_SECS=120

# --- X4: agent-layer kill-switch — the very first thing this script does,
# before stdin is even read. No file -> no-op, no exceptions. ----------------
[ -e "$KILL_SWITCH" ] && exit 0

# Nothing on stdin (manual/interactive invocation, e.g. a human running this
# by hand) -> nothing to evaluate.
[ -t 0 ] && exit 0

payload="$(cat)"
[ -z "$payload" ] && exit 0

# H8: fail OPEN on any internal error, with exactly one stderr line.
fail_open() {
  echo "pretooluse-guard: $1 -- failing open (tool call proceeds)" >&2
  exit 0
}

# --- H3: dangerous-pattern set. Each alternative is anchored to an actual
# `git` invocation shape (subcommand + the flag that makes it destructive),
# deliberately broader than the observed incidents -- the "ask" posture (never
# "deny") absorbs false positives cheaply. Recovery-net destroyers (reflog
# expire/delete, gc --prune, bare prune) are included because those void the
# reflog/GC recoverability guarantee this whole scheme depends on: no other
# layer can see object pruning once it happens. ------------------------------
DANGEROUS_RE='reset[[:space:]]+--hard'
DANGEROUS_RE="${DANGEROUS_RE}|push\b.*(--force-with-lease|--force\b|(^|[[:space:]])-f([[:space:]]|\$))"
DANGEROUS_RE="${DANGEROUS_RE}|branch\b.*-D\b"
DANGEROUS_RE="${DANGEROUS_RE}|update-ref\b.*-d\b"
DANGEROUS_RE="${DANGEROUS_RE}|filter-branch|filter-repo"
DANGEROUS_RE="${DANGEROUS_RE}|clean\b[^&;|]*-[a-zA-Z]*f[a-zA-Z]*\b"
DANGEROUS_RE="${DANGEROUS_RE}|reflog\b.*(expire|delete)\b"
DANGEROUS_RE="${DANGEROUS_RE}|gc\b.*--prune\b"
DANGEROUS_RE="${DANGEROUS_RE}|(^|[[:space:]])prune\b"

# --- H25: write shapes. WRITE_RAW_RE is the loose form the pre-filter runs
# on the raw JSON (where a newline is the two characters `\n`). Each command
# segment is then matched exactly (is_write_shaped): WRITE_API_RE, the
# python write calls, on the segment as typed, since a mode needs its
# quotes; WRITE_SHELL_RE and a bare `>` only outside quotes, so
# `jq 'select(.n > 1)'` stays a read. Pattern-matching misses some writes;
# a miss only costs an ask that should have fired under contention.
WRITE_RAW_RE='sed[[:space:]].*(-[a-zA-Z]*i|--in-place)|>'
WRITE_RAW_RE="${WRITE_RAW_RE}|(^|[^[:alnum:]_-]|\\\\n)(tee|cp|mv|rm|touch)([^[:alnum:]_-]|\$)"
WRITE_RAW_RE="${WRITE_RAW_RE}|open\(|write_text\(|\.write\("
WRITE_SHELL_RE='(^|[[:space:]])sed[[:space:]]([^|]*[[:space:]])?(-[a-zA-Z]*i|--in-place)'
WRITE_SHELL_RE="${WRITE_SHELL_RE}|(^|[[:space:]])(tee|cp|mv|rm|touch)([[:space:]]|\$)"
WRITE_API_RE="open\(([^)]*,[[:space:]]*)?(mode=)?['\"][wa][bt+]?['\"]|write_text\(|\.write\("

# --- H2: cheap pre-filter, on the RAW stdin text, before ANY jq call or
# directory-resolution work. Which pre-filter applies depends on which
# matcher this invocation is for, so tool_name is sniffed with a raw grep
# first (same style as claude-notify-hook.sh's no-jq session_id fallback) --
# NOT a full jq parse. Getting this branch wrong would defeat the whole
# point of H2: e.g. an agent sitting in ~/code/tasks running plain `git
# status` mentions "code/tasks" nowhere near a dangerous pattern, but its
# `cwd` field DOES contain the substring "code/tasks" -- a naive combined
# "dangerous-pattern OR code/tasks" filter would treat that as a match and
# do full resolution work on every single Bash call issued from inside the
# tasks dir, which is the common case this hook exists to be cheap around.
# So: Bash calls pass on the dangerous-pattern regex, or on a write shape
# AND the code/tasks substring (in the command, or in a cwd under the
# store -- an agent that has cd'd into a dossier writes with relative
# paths); a plain read from inside the store passes neither.
# Edit/Write/MultiEdit calls are pre-filtered on the code/tasks substring
# ONLY (they have no "command" to pattern-match against). Anything else
# exits immediately, no jq. -------------------------------------------------
raw_tool_name="$(grep -o '"tool_name"[[:space:]]*:[[:space:]]*"[^"]*"' <<<"$payload" \
  | head -n1 | sed -E 's/.*"([^"]*)"$/\1/')"

case "$raw_tool_name" in
  Bash)
    if ! grep -Eq "$DANGEROUS_RE" <<<"$payload"; then
      grep -Eq "$WRITE_RAW_RE" <<<"$payload" && grep -Fq "code/tasks" <<<"$payload" || exit 0
    fi
    ;;
  Edit|Write|MultiEdit)
    grep -Fq "code/tasks" <<<"$payload" || exit 0
    ;;
  *)
    exit 0
    ;;
esac

command -v jq >/dev/null 2>&1 || fail_open "jq not found in PATH"

jq_get() {
  local filter="$1" out rc
  out="$(printf '%s' "$payload" | jq -r "$filter" 2>/dev/null)"
  rc=$?
  [ $rc -eq 0 ] || fail_open "jq failed to parse hook payload"
  printf '%s' "$out"
}

tool_name="$(jq_get '.tool_name // empty')"
top_cwd="$(jq_get '.cwd // empty')"

# --- path helpers (best-effort; not required to handle every shell-quoting
# edge case -- the git-side hook is the real backstop for anything missed
# here on LOCAL ref updates). ------------------------------------------------

# expand_path PATH BASE -- expand a leading ~ or $HOME, then resolve a
# relative PATH against BASE. Does not itself normalize ".." or resolve
# symlinks -- path_under_tasks_dir (below) does that canonicalization on
# the way in, so every caller gets it for free without expand_path needing
# to know about the containment check it feeds.
expand_path() {
  local p="$1" base="$2"
  # strip one layer of surrounding quotes, if any
  p="${p%\"}"; p="${p#\"}"
  p="${p%\'}"; p="${p#\'}"
  case "$p" in
    "~") p="$HOME" ;;
    "~/"*) p="$HOME/${p#\~/}" ;;
    "\$HOME") p="$HOME" ;;
    "\$HOME/"*) p="$HOME/${p#\$HOME/}" ;;
  esac
  case "$p" in
    /*) : ;;
    *) p="${base%/}/$p" ;;
  esac
  printf '%s' "$p"
}

# path_under_tasks_dir PATH -- true if PATH is TASKS_DIR itself or beneath
# it, judged on the CANONICAL form of both sides (`realpath -m` -- resolves
# `..`/symlinks without requiring the path to actually exist yet, since a
# git/Edit target may not). A prior version compared the raw string
# expand_path returned against a raw $TASKS_DIR: `-C ~/code/dotfiles/../tasks`
# expands to a string containing "dotfiles/../tasks", which a plain prefix
# match against "$TASKS_DIR" (= ".../code/tasks") never matches, even though
# the shell/OS resolves that exact path to the real $TASKS_DIR -- the same
# `..`-traversal containment bug wb_safe_rel (wb.sh) already guards against
# correctly, for a lower-stakes purpose, via this same realpath -m pattern.
path_under_tasks_dir() {
  local p="$1" real_p real_tasks_dir
  [ -z "$p" ] && return 1
  real_p="$(realpath -m -- "$p" 2>/dev/null)" || real_p="$p"
  real_tasks_dir="$(realpath -m -- "$TASKS_DIR" 2>/dev/null)" || real_tasks_dir="$TASKS_DIR"
  case "$real_p" in
    "$real_tasks_dir"|"$real_tasks_dir"/*) return 0 ;;
    *) return 1 ;;
  esac
}

# sentinel_is_fresh -- X1's escape hatch. ~/code/tasks/.git/WB_ALLOW_REWIND
# holds one line "<epoch> <reason>"; fresh within a 120s TTL of that epoch.
# This hook only ever READS/checks it -- it never creates it (that's `wb
# unsafe-rewind`, a different unit) and never consumes/deletes it (only the
# git-side hook consumes it). Callers MUST only call this after a dangerous+
# scoped match has already been established (H6) -- never before pattern/
# scope matching, or a 120s sentinel becomes "allow literally everything".
sentinel_is_fresh() {
  [ -f "$SENTINEL_FILE" ] || return 1
  local line epoch now delta
  line="$(head -n1 "$SENTINEL_FILE" 2>/dev/null)" || return 1
  epoch="${line%% *}"
  case "$epoch" in
    ''|*[!0-9]*) return 1 ;;
  esac
  now="$(date +%s)"
  delta=$(( now - epoch ))
  [ "$delta" -ge 0 ] && [ "$delta" -le "$SENTINEL_TTL_SECS" ]
}

emit_decision() {
  local decision="$1" reason="$2"
  jq -n --arg decision "$decision" --arg reason "$reason" \
    '{hookSpecificOutput: {hookEventName: "PreToolUse", permissionDecision: $decision, permissionDecisionReason: $reason}}'
}

# --- contention check (H24) --------------------------------------------------
# A store write only needs a human when another session is working on the
# same task right now. Edit/Write already refuse a stale write on their own;
# what they can't see is that someone else is mid-flight on the task.

# owning_task_file PATH -- the canonical task file PATH belongs to: the
# top-level <task>.md itself, or <task>.md for anything under
# dossiers/<task>/. Prints nothing for shared files (README.md, INDEX*,
# weeks/, context/, the store root), which no single session owns.
owning_task_file() {
  local real_p real_tasks_dir rel name
  real_p="$(realpath -m -- "$1" 2>/dev/null)" || return 0
  real_tasks_dir="$(realpath -m -- "$TASKS_DIR" 2>/dev/null)" || return 0
  rel="${real_p#"$real_tasks_dir"/}"
  [ "$rel" = "$real_p" ] && return 0
  case "$rel" in
    dossiers/*/*|dossiers/*)
      name="${rel#dossiers/}"; name="${name%%/*}" ;;
    */*) return 0 ;;
    *.md) name="${rel%.md}" ;;
    *) return 0 ;;
  esac
  case "$name" in README|INDEX*|'') return 0 ;; esac
  printf '%s/%s.md' "$real_tasks_dir" "$name"
}

# The caller's own tmux session (empty outside tmux) and every live
# session's @task, each looked up at most once per run. Mirrors
# _wb_refuse_if_live_session in wb.sh without sourcing wb.sh, whose
# top-level CODE_DIR assignment caused the 2026-07-10 deletion incident.
own_session=""
live_owners=""
tmux_ok=0
load_tmux_state() {
  local out
  if [ -n "${TMUX:-}" ] && [ -n "${TMUX_PANE:-}" ]; then
    own_session="$(tmux display -p -t "$TMUX_PANE" '#S' 2>/dev/null)" || own_session=""
  fi
  if out="$(tmux list-sessions -F $'#{session_name}\t#{@task}' 2>&1)"; then
    live_owners="$out"
    tmux_ok=1
  elif grep -qE 'no server running|error connecting to' <<<"$out"; then
    # No tmux server means no live sessions, not a broken lookup.
    tmux_ok=1
  else
    echo "pretooluse-guard: tmux session lookup failed -- skipping the live-session check" >&2
  fi
}

# other_live_owner TASK_FILE -- the first live session other than the
# caller's own whose @task is TASK_FILE.
other_live_owner() {
  local task_file="$1" name task
  [ "$tmux_ok" -eq 1 ] || return 0
  while IFS=$'\t' read -r name task; do
    [ -n "$name" ] && [ -n "$task" ] || continue
    [ "$name" = "$own_session" ] && continue
    [ "$(realpath -m -- "$task" 2>/dev/null)" = "$task_file" ] || continue
    printf '%s' "$name"
    return 0
  done <<<"$live_owners"
}

# Lock probe: wb-locks.sh owns the side-car lock path, so source it rather
# than re-derive it. The stowed guard is a symlink, so resolve the real
# script dir first. A failed source, or no flock, only drops the lock half
# of the check, with one stderr line like the tmux half's.
locks_ok=0
load_locks() {
  local guard_dir
  guard_dir="$(dirname -- "$(realpath -- "${BASH_SOURCE[0]}" 2>/dev/null || printf '%s' "${BASH_SOURCE[0]}")")"
  # shellcheck source=../wb-locks.sh
  if source "$guard_dir/../wb-locks.sh" 2>/dev/null && declare -F _wb_lock_path_for >/dev/null \
    && command -v flock >/dev/null 2>&1; then
    locks_ok=1
  else
    echo "pretooluse-guard: wb-locks.sh or flock unavailable -- skipping the wb lock check" >&2
  fi
}

# lock_holder TASK_FILE -- succeeds when TASK_FILE's wb lock is held right
# now by someone other than the caller's own session, printing the holder's
# recorded tmux session (possibly empty). Probes with a non-blocking flock
# that releases at once, so a real wb command never waits on it.
lock_holder() {
  local task_file="$1" lockfile rc holder
  [ "$locks_ok" -eq 1 ] || return 1
  lockfile="$(_wb_lock_path_for "$task_file")"
  [ -f "$lockfile" ] || return 1
  flock -n -E 75 "$lockfile" true 2>/dev/null
  rc=$?
  [ $rc -eq 75 ] || return 1
  holder="$(wb_task_lock_holder_field "$task_file" tmux_session)"
  [ -n "$holder" ] && [ "$holder" = "$own_session" ] && return 1
  printf '%s' "$holder"
}

# ask_if_contended TOOL TARGET TASK_FILE... -- emit an ask naming the first
# contending session for any TASK_FILE; otherwise emit nothing.
ask_if_contended() {
  local tool="$1" target="$2" task_file task who holder
  shift 2
  [ $# -gt 0 ] || return 0
  load_tmux_state
  load_locks
  for task_file in "$@"; do
    task="$(basename -- "$task_file" .md)"
    who="$(other_live_owner "$task_file")"
    if [ -n "$who" ]; then
      emit_decision "ask" \
        "$tool is writing $target, which belongs to task $task -- and tmux session '$who' is working on that task right now. Check with that session first so neither of you overwrites the other's changes."
      return 0
    fi
    if holder="$(lock_holder "$task_file")"; then
      emit_decision "ask" \
        "$tool is writing $target, which belongs to task $task -- and a wb command${holder:+ from tmux session '$holder'} is writing that task right now. Wait for it to finish, then re-read the file before writing."
      return 0
    fi
  done
}

# --- Bash store writes (H25) -------------------------------------------------
# Best effort: pattern-match each segment, never parse shell. Lines and
# segments are scanned in pure bash (a python heredoc can be long); only a
# write-shaped segment forks, to resolve its paths.

# trim STRING -- sets TRIMMED, without the fork a $(...) would cost.
trim() {
  TRIMMED="${1#"${1%%[![:space:]]*}"}"
  TRIMMED="${TRIMMED%"${TRIMMED##*[![:space:]]}"}"
}

# strip_quoted STRING -- sets UNQUOTED to STRING without its '…' and "…"
# spans. An unterminated quote (a segment split inside one) drops the rest.
strip_quoted() {
  local s="$1" out="" q rest
  while [[ "$s" =~ ^([^\'\"]*)([\'\"])(.*)$ ]]; do
    out+="${BASH_REMATCH[1]}"; q="${BASH_REMATCH[2]}"; rest="${BASH_REMATCH[3]}"
    if [[ "$rest" != *"$q"* ]]; then s=""; break; fi
    s="${rest#*"$q"}"
  done
  UNQUOTED="$out$s"
}

# is_write_shaped SEGMENT [api] -- WRITE_API_RE on the segment as typed, or
# WRITE_SHELL_RE or a `>` outside quotes once fd duplications (2>&1, >&2),
# /dev/null redirects and arrows or comparisons (->, =>, >=) are removed.
# With `api`, the segment is a heredoc body line fed to an interpreter or
# read as data, where `>` and `rm` are not shell, so only WRITE_API_RE counts.
is_write_shaped() {
  local s="$1"
  [[ "$s" =~ $WRITE_API_RE ]] && return 0
  [ "${2:-}" = api ] && return 1
  while [[ "$s" =~ ^(.*)\>\>?[[:space:]]*(\&[0-9-]*|/dev/null)(.*)$ ]]; do
    s="${BASH_REMATCH[1]}${BASH_REMATCH[3]}"
  done
  s="${s//->/}"; s="${s//=>/}"; s="${s//>=/}"
  # A quoted `sh -c` string is itself shell, so its quotes stay.
  if [[ "$s" =~ (^|[[:space:]])(bash|sh|zsh|dash)[[:space:]]+-c ]]; then
    UNQUOTED="$s"
  else
    strip_quoted "$s"
  fi
  [[ "$UNQUOTED" =~ $WRITE_SHELL_RE || "$UNQUOTED" == *'>'* ]]
}

# command_word SEGMENT -- sets WORD to the segment's command name, past any
# VAR=value prefixes and a leading path.
command_word() {
  local s="$1"
  while [[ "$s" =~ ^[A-Za-z_][A-Za-z0-9_]*=[^[:space:]]*[[:space:]]+(.*)$ ]]; do
    s="${BASH_REMATCH[1]}"
  done
  WORD="${s%%[[:space:]]*}"; WORD="${WORD##*/}"
}

# is_wb_segment SEGMENT -- the command word is wb (sets WORD). Its locked
# verbs do their own flock, so they are never checked.
is_wb_segment() {
  command_word "$1"
  case "$WORD" in wb|wb.sh) return 0 ;; *) return 1 ;; esac
}

HEREDOC_RE="(^|[^<])<<-?[[:space:]]*['\"]?([A-Za-z_][A-Za-z0-9_]*)['\"]?"

# check_bash_writes COMMAND -- collect the owning task of every store path a
# write-shaped segment could touch, then hand them to ask_if_contended. A
# write-shaped segment counts its working directory (payload cwd, or the
# latest `cd`) and, when that is in the store, its relative paths. Store
# paths named anywhere in the non-wb text count too, so `D=~/code/tasks/…;
# echo x > $D/n.md` is caught without expanding $D.
check_bash_writes() {
  local command="$1" current_dir="$top_cwd" line seg segs scan_text="" first_write=""
  local heredoc_end="" heredoc_skip=0 heredoc_dir="" heredoc_mode="" line_heredoc_wb=0
  local line_heredoc_mode="" piece task_file
  local -A owners=()

  add_owner() { # PATH BASE
    local p
    p="$(expand_path "$1" "$2")"
    path_under_tasks_dir "$p" || return 0
    p="$(owning_task_file "$p")"
    [ -n "$p" ] && owners["$p"]=1
    return 0
  }
  note_write() { # SEGMENT DIR
    [ -n "$first_write" ] || first_write="$1"
    path_under_tasks_dir "$2" || return 0
    add_owner "$2" /
    while IFS= read -r piece; do
      case "$piece" in -*|'') continue ;; esac
      add_owner "$piece" "$2"
    done < <(grep -oE "[^[:space:]'\"\`(),;<>|&=]+" <<<"$1")
  }

  while IFS= read -r line; do
    if [ -n "$heredoc_end" ]; then
      trim "$line"
      if [ "$TRIMMED" = "$heredoc_end" ]; then
        heredoc_end=""
      elif [ "$heredoc_skip" -eq 0 ]; then
        scan_text+="$line"$'\n'
        is_write_shaped "$line" $heredoc_mode && note_write "$line" "$heredoc_dir"
      fi
      continue
    fi

    line_heredoc_wb=0; line_heredoc_mode=""
    segs="${line//&&/$'\n'}"; segs="${segs//||/$'\n'}"
    segs="${segs//;/$'\n'}"; segs="${segs//|/$'\n'}"
    while IFS= read -r seg; do
      trim "$seg"; seg="$TRIMMED"
      [ -z "$seg" ] && continue
      if is_wb_segment "$seg"; then
        [[ "$seg" =~ $HEREDOC_RE ]] && line_heredoc_wb=1
        continue
      fi
      # A heredoc body is shell only when a shell reads it.
      if [[ "$seg" =~ $HEREDOC_RE ]]; then
        case "$WORD" in bash|sh|zsh|dash) line_heredoc_mode="" ;; *) line_heredoc_mode=api ;; esac
      fi
      scan_text+="$seg"$'\n'
      if [[ "$seg" =~ ^cd[[:space:]]+(.+)$ ]]; then
        current_dir="$(expand_path "${BASH_REMATCH[1]}" "$current_dir")"
        continue
      fi
      is_write_shaped "$seg" && note_write "$seg" "$current_dir"
    done <<<"$segs"

    if [[ "$line" =~ $HEREDOC_RE ]]; then
      heredoc_end="${BASH_REMATCH[2]}"
      heredoc_skip="$line_heredoc_wb"
      heredoc_mode="$line_heredoc_mode"
      heredoc_dir="$current_dir"
    fi
  done <<<"$command"

  [ -n "$first_write" ] || return 0
  while IFS= read -r piece; do
    [ -n "$piece" ] && add_owner "$piece" "$top_cwd"
  done < <(grep -oE "[^[:space:]'\"\`(),;<>|&=]*code/tasks[^[:space:]'\"\`(),;<>|&=]*" <<<"$scan_text")

  [ "${#first_write}" -le 160 ] || first_write="${first_write:0:157}..."
  ask_if_contended "Bash" "a store file (\`$first_write\`)" "${!owners[@]}"
}

# --- Bash matcher (H1-H6) ----------------------------------------------------
handle_bash() {
  local command matched=0 matched_inv="" current_dir="$top_cwd" normalized inv dir

  command="$(jq_get '.tool_input.command // empty')"
  [ -z "$command" ] && exit 0

  # Marker for the "no directory-resolution work at all" tests: only touched
  # once we are actually about to do per-invocation resolution (H4).
  if [ -n "${GUARD_TEST_MARKER_FILE:-}" ]; then
    : > "$GUARD_TEST_MARKER_FILE"
  fi

  # Split the command into individual invocations on &&, ||, ;, |. Order
  # matters: collapse the two-char operators first so a lone `|` split
  # doesn't fire in the middle of a `||`.
  normalized="$(printf '%s' "$command" | sed -E 's/(&&|\|\|)/\n/g' | sed -E 's/[;|]/\n/g')"

  while IFS= read -r inv; do
    inv="$(printf '%s' "$inv" | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//')"
    [ -z "$inv" ] && continue

    # `cd <path>` sets the working directory for subsequent invocations in
    # this same command that don't carry their own -C/--git-dir.
    if [[ "$inv" =~ ^cd[[:space:]]+(.+)$ ]]; then
      current_dir="$(expand_path "${BASH_REMATCH[1]}" "$current_dir")"
      continue
    fi

    # H3's DANGEROUS_RE patterns are already shaped like git subcommands
    # ("reset --hard", "branch...-D", ...) -- they don't need a literal
    # leading "git" token to be meaningful, and requiring one here let an
    # ordinary env-prefixed or wrapper-prefixed invocation
    # (`TASKS_DIR=/tmp/x git reset --hard`, `\git reset --hard` -- the
    # everyday alias-bypass idiom, `env git reset --hard`,
    # `sh -c "git reset --hard ..."`) skip this check ENTIRELY: none of
    # these are adversarial obfuscation, just ordinary shell idioms an
    # honest agent could type, and the outer H2 pre-filter (which gates
    # entry into this whole script) already matches DANGEROUS_RE against
    # the raw command text with no such prefix requirement -- this inner
    # anchor had drifted stricter than that outer gate. Do the
    # dangerous-pattern + directory-scope check directly against every
    # invocation; a former `^git` requirement used to `continue` past
    # non-git-prefixed lines entirely before ever reaching it.

    # H4: resolve THIS invocation's target dir -- explicit -C/--git-dir
    # first, else the tracked `cd` state, else the fallback top-level cwd.
    # Attempting -C/--git-dir extraction against a non-git invocation is
    # harmless (the regex simply won't match) now that this no longer
    # gates on a literal git prefix first.
    dir="$current_dir"
    if [[ "$inv" =~ -C[[:space:]]+([^[:space:]]+) ]]; then
      dir="$(expand_path "${BASH_REMATCH[1]}" "$current_dir")"
    elif [[ "$inv" =~ --git-dir=([^[:space:]]+) ]]; then
      dir="$(expand_path "${BASH_REMATCH[1]}" "$current_dir")"
      dir="${dir%/.git}"
    fi

    if grep -Eq "$DANGEROUS_RE" <<<"$inv" && path_under_tasks_dir "$dir"; then
      matched=1
      matched_inv="$inv"
      break
    fi
  done <<<"$normalized"

  if [ "$matched" -ne 1 ]; then
    check_bash_writes "$command"
    exit 0
  fi

  # H6: sentinel check happens ONLY here, strictly after H3+H4 already
  # matched and scoped this specific command.
  if sentinel_is_fresh; then
    emit_decision "allow" \
      "A fresh 'wb unsafe-rewind' sentinel authorizes this specific dangerous command ($matched_inv) scoped to \$HOME/code/tasks. The separate git-side hook still has final say."
    exit 0
  fi

  emit_decision "ask" \
    "Matched dangerous git command: \`$matched_inv\` -- scoped to \$HOME/code/tasks, the shared multi-agent task store. This mirrors two real past incidents where a raw destructive git command in that directory silently orphaned another session's unpushed commits. Prefer \`git -C ~/code/tasks pull --ff-only\` or \`wb unsafe-rewind\` instead of running this directly. Approving here does NOT bypass the separate git-side reference-transaction hook -- it still gets its own say."
  exit 0
}

# --- Edit/Write/MultiEdit matcher (H24) --------------------------------------
handle_edit() {
  local file_path task_file

  file_path="$(jq_get '.tool_input.file_path // empty')"
  [ -z "$file_path" ] && exit 0

  file_path="$(expand_path "$file_path" "$top_cwd")"
  path_under_tasks_dir "$file_path" || exit 0

  task_file="$(owning_task_file "$file_path")"
  [ -n "$task_file" ] || exit 0
  ask_if_contended "$tool_name" "$file_path" "$task_file"
  exit 0
}

case "$tool_name" in
  Bash) handle_bash ;;
  Edit|Write|MultiEdit) handle_edit ;;
  *) exit 0 ;;
esac
