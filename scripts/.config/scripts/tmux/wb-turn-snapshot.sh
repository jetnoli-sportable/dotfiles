#!/usr/bin/env bash
# wb-turn-snapshot.sh — records the worktree's tree at each prompt and at each
# turn end, so the wb review page's "Last turn" view can show only what the
# agent changed (wb-store review, view=turn).
#
#   prompt   UserPromptSubmit hook: take the lock, then re-run detached (stdio
#            closed, so the prompt isn't delayed) to write turn-start
#   stop     Stop and StopFailure hook: in the foreground, record the turn
#
# Refs, private to the linked worktree (refs/worktree/):
#   refs/worktree/wb/turn-start   parentless commit of the tree at the latest
#                                 prompt, moved to the new tree at each turn end
#                                 (a review handed over at turn end counts as a
#                                 new prompt: the review is Jet's instruction)
#   refs/worktree/wb/turn         commit of the tree at a turn end, parent
#                                 turn-start, written only when the tree differs;
#                                 its date is the end time. Message: subject
#                                 "wb turn" or "wb turn (interrupted)", then
#                                 "head <sha>" and "reply <first line>"
# A snapshot is the worktree tree including untracked, non-ignored files, staged
# into a private index (<git-dir>/wb-turn-index, seeded from the real index) and
# written with write-tree; the real index and HEAD are never touched. The open-turn
# marker <git-dir>/wb-turn-open is set by `prompt` and cleared by `stop`; a prompt
# that finds it still set (an Esc interrupt gets no Stop) records that turn first,
# marked interrupted. A review handed over by a Stop block starts a turn no prompt
# announces, so a prompt that finds that hand-over still in flight on this pane
# (wb-review-hook.sh's queue/inflight, cleared at the next Stop) does the same.
# Both verbs hold <git-dir>/wb-turn.lock (flock; the detached child inherits it,
# so a Stop waits for a running prompt), every git call has a timeout, refs move
# with update-ref and the old value, and on any failure the refs stay as they were.
#
# Guards, in plain bash before any fork: the kill switch
# ${XDG_STATE_HOME:-~/.local/state}/wb/disable-turn-snapshot,
# CLAUDE_CODE_SESSION_ATTENDED=0, an sdk* entrypoint (headless `claude -p`
# children), no TMUX_PANE. Then one git call confirms a linked worktree, so a
# Claude in a main checkout writes nothing. Always exits 0; prints nothing.
#
# Several worktrees: a task can span repos (task file: repo:/worktree: and the
# comma list worktrees:). The pane's @task names the task file; its primary and
# extras are recorded alongside Claude's working-folder worktree, each with its
# own lock, git dir and refs. A worktree that is missing, malformed, or not a
# linked worktree is skipped, and so is one whose lock can't be had in time. One
# deadline covers all of them (prompt: 3 s of lock waits, inside the hook's 5 s;
# stop: 8 s, inside its 10 s), and each lock wait and git call gets the smaller
# of its own limit and the time left, so the hook is never killed mid-worktree.
# `prompt` takes every lock in the parent, then one detached child records them.
#
# Tunable (env): WB_TURN_GIT_TIMEOUT (5), whole seconds each git call may take.
set -uo pipefail

WBTS_VERB="${1:-}"
WBTS_INPUT=""

[ -e "${XDG_STATE_HOME:-$HOME/.local/state}/wb/disable-turn-snapshot" ] && exit 0
[ "${CLAUDE_CODE_SESSION_ATTENDED:-}" = 0 ] && exit 0
case "${CLAUDE_CODE_ENTRYPOINT:-}" in sdk*) exit 0 ;; esac
[ -n "${TMUX_PANE:-}" ] || exit 0

WBTS_T="${WB_TURN_GIT_TIMEOUT:-5}"
[[ "$WBTS_T" =~ ^[0-9]+$ ]] || WBTS_T=5
WBTS_T_US=$((WBTS_T * 1000000))
WBTS_DEADLINE="" # microseconds since the epoch; empty means no deadline
WBTS_WT=""       # the worktree directory git_ acts on
GD=""            # that worktree's git dir
WBTS_CT=""
REF_START=refs/worktree/wb/turn-start
REF_TURN=refs/worktree/wb/turn
ZERO=0000000000000000000000000000000000000000

# wbts_cap — set WBTS_CT, seconds one git call or lock wait may take: WBTS_T, or
# the time left before WBTS_DEADLINE when that is less. Nonzero when none is left.
wbts_cap() {
  local left
  WBTS_CT="$WBTS_T"
  [ -n "$WBTS_DEADLINE" ] || return 0
  left=$((WBTS_DEADLINE - ${EPOCHREALTIME/[.,]/}))
  ((left > 0)) || return 1
  ((left < WBTS_T_US)) && printf -v WBTS_CT '%d.%06d' $((left / 1000000)) $((left % 1000000))
  return 0
}

git_() {
  wbts_cap || return 1
  timeout "$WBTS_CT" git -C "$WBTS_WT" --no-optional-locks -c commit.gpgsign=false "$@"
}

# wbts_snapshot — print the sha of a commit-less tree of the current worktree.
wbts_snapshot() {
  [ -e "$GD/wb-turn-index" ] || cp "$GD/index" "$GD/wb-turn-index" 2>/dev/null
  GIT_INDEX_FILE="$GD/wb-turn-index" git_ add -A >/dev/null 2>&1 || return 1
  GIT_INDEX_FILE="$GD/wb-turn-index" git_ write-tree 2>/dev/null
}

# wbts_commit <tree> <parent-or-empty> <message> — print a new commit's sha.
wbts_commit() {
  GIT_AUTHOR_NAME=wb-turn-snapshot GIT_AUTHOR_EMAIL=wb@localhost \
    GIT_COMMITTER_NAME=wb-turn-snapshot GIT_COMMITTER_EMAIL=wb@localhost \
    git_ commit-tree "$1" ${2:+-p "$2"} -m "$3" 2>/dev/null
}

# wbts_set <ref> <new> — move a ref to <new>, expecting the value it has now.
wbts_set() {
  local old
  old="$(git_ rev-parse -q --verify "$1" 2>/dev/null)" || old="$ZERO"
  git_ update-ref "$1" "$2" "$old" >/dev/null 2>&1
}

# wbts_read_start — sets WBTS_START and WBTS_START_TREE from turn-start (both
# empty when the ref is missing). One call: for-each-ref prints nothing for a
# missing ref, so that is told apart from a git failure.
wbts_read_start() {
  local row
  WBTS_START="" WBTS_START_TREE=""
  row="$(git_ for-each-ref --format='%(objectname) %(tree)' "$REF_START" 2>/dev/null)" || return 1
  [ -n "$row" ] || return 0
  WBTS_START="${row%% *}" WBTS_START_TREE="${row#* }"
  [ -n "$WBTS_START_TREE" ]
}

# wbts_reply — the first line of the Stop input's last_assistant_message.
wbts_reply() {
  [[ "$WBTS_INPUT" == *last_assistant_message* ]] && command -v jq >/dev/null 2>&1 || return 0
  printf '%s' "$WBTS_INPUT" | jq -r '(.last_assistant_message // "") | tostring | split("\n")[0] | .[0:200]' 2>/dev/null
}

# wbts_record <tree> <interrupted:0|1> — when <tree> differs from turn-start's,
# write the turn ref (the reply line comes from WBTS_INPUT). Returns nonzero on
# a git failure.
wbts_record() {
  local tree="$1" intr="$2" head msg c subject="wb turn"
  wbts_read_start || return 1
  [ -n "$WBTS_START" ] || return 0
  [ "$WBTS_START_TREE" = "$tree" ] && return 0
  head="$(git_ rev-parse -q --verify HEAD 2>/dev/null)"
  [ "$intr" = 1 ] && subject="wb turn (interrupted)"
  msg="$subject"$'\n\n'"head $head"$'\n'"reply $(wbts_reply)"
  c="$(wbts_commit "$tree" "$WBTS_START" "$msg")" && [ -n "$c" ] || return 1
  wbts_set "$REF_TURN" "$c"
}

# wbts_move_start <tree> — turn-start becomes a parentless commit of <tree>; left
# alone when it already holds that tree (nothing reads its date). Needs
# WBTS_START_TREE, which wbts_record has just read.
wbts_move_start() {
  local c
  [ -n "$WBTS_START_TREE" ] && [ "$WBTS_START_TREE" = "$1" ] && return 0
  c="$(wbts_commit "$1" "" "wb turn start")" && [ -n "$c" ] || return 1
  wbts_set "$REF_START" "$c"
}

# wbts_review_open — a review hand-over on this pane is still in flight: the
# block's turn got no Stop. A marker older than wb-review-hook.sh's own limit
# (WB_REVIEW_INFLIGHT_MAX_S) is stale, as there.
wbts_review_open() {
  local f pane ts
  for f in "${XDG_STATE_HOME:-$HOME/.local/state}"/wb/review/*/queue/inflight; do
    [ -e "$f" ] || continue
    pane="" ts=""
    read -r pane ts <"$f"
    [ "$pane" = "$TMUX_PANE" ] && [[ "$ts" =~ ^[0-9]+$ ]] &&
      ((EPOCHSECONDS - ts < ${WB_REVIEW_INFLIGHT_MAX_S:-1800})) && return 0
  done
  return 1
}

# wbts_run_prompt — the detached half of `prompt`; the lock is already held.
wbts_run_prompt() {
  local tree
  tree="$(wbts_snapshot)" && [ -n "$tree" ] || return 0
  if [ -e "$GD/wb-turn-open" ] || wbts_review_open; then
    wbts_record "$tree" 1 || return 0
  else
    wbts_read_start || WBTS_START_TREE=""
  fi
  wbts_move_start "$tree" || return 0
  : >"$GD/wb-turn-open"
}

# wbts_run_stop — the lock is already held; WBTS_INPUT holds the hook input.
wbts_run_stop() {
  local tree
  tree="$(wbts_snapshot)" && [ -n "$tree" ] || return 0
  wbts_record "$tree" 0 || return 0
  wbts_move_start "$tree" || return 0
  rm -f "$GD/wb-turn-open"
}

# wbts_gd <dir> — point git_ and GD at the worktree in <dir>. Nonzero unless it
# is a linked worktree (only a linked worktree's git dir differs from the common
# dir), so a Claude in a main checkout writes nothing.
wbts_gd() {
  local dirs
  WBTS_WT="$1"
  dirs="$(git_ rev-parse --absolute-git-dir --path-format=absolute --git-common-dir 2>/dev/null)" || return 1
  GD="${dirs%%$'\n'*}"
  [ -n "$GD" ] && [ "$GD" != "${dirs#*$'\n'}" ]
}

# wbts_task_dirs — print the task's worktree directories, primary first, then the
# valid extras, from the task file named by the pane's @task. The rules are
# wb.sh's (_wb_safe_worktree_field, and _wb_safe_worktrees_entry: the repo part of
# an entry is one [A-Za-z0-9._-] segment, not . or .., split at the first
# /.worktrees/, one entry per repo and none for the primary's), kept here because
# a hook must not source wb.sh.
wbts_task_dirs() {
  local task code line key val repo="" wt="" extras="" stem item erepo rest started=0 slug
  declare -A seen
  wbts_cap || return 0
  task="$(timeout "$WBTS_CT" tmux display-message -p -t "$TMUX_PANE" '#{@task}' 2>/dev/null)" || return 0
  [ -f "$task" ] || return 0
  code="${CODE_DIR:-$HOME/code}"
  while IFS= read -r line; do
    if [ "$line" = --- ]; then
      ((started)) && break
      started=1
      continue
    fi
    ((started)) || break
    key="${line%%:*}"
    val="${line#*:}"
    val="${val%%[[:space:]]#*}"
    val="${val#"${val%%[![:space:]]*}"}"
    val="${val%"${val##*[![:space:]]}"}"
    case "$key" in
      repo) repo="$val" ;;
      worktree) wt="$val" ;;
      worktrees) extras="$val" ;;
    esac
  done <"$task"
  wbts_safe_repo "$repo" || return 0
  stem="${task##*/}"
  stem="${stem%.md}"
  if [ -n "$wt" ] && wbts_safe_wt "$wt"; then
    slug="${wt#.worktrees/}"
  else
    slug="${stem#"${repo}--"}"
    wt=".worktrees/$slug"
  fi
  printf '%s\n' "$code/$repo/$wt"
  seen[$repo]=1
  while IFS= read -r item; do
    item="${item#"${item%%[![:space:]]*}"}"
    item="${item%"${item##*[![:space:]]}"}"
    case "$item" in */.worktrees/?*) ;; *) continue ;; esac
    erepo="${item%%/.worktrees/*}"
    rest=".worktrees/${item#*/.worktrees/}"
    if ! wbts_safe_repo "$erepo" || ! wbts_safe_wt "$rest" || [ -n "${seen[$erepo]:-}" ]; then continue; fi
    seen[$erepo]=1
    printf '%s\n' "$code/$item"
  done <<<"${extras//,/$'\n'}"
}

wbts_safe_repo() {
  case "$1" in '' | . | .. | *[!A-Za-z0-9._-]*) return 1 ;; esac
}

wbts_safe_wt() {
  case "$1" in .worktrees/?*) ;; *) return 1 ;; esac
  case "$1" in *[!A-Za-z0-9._/-]*) return 1 ;; esac
  case "/$1/" in *//* | */../* | */./*) return 1 ;; esac
}

# wbts_list — fill WT_DIRS and WT_GDS (parallel arrays): the working folder's
# worktree, then the task's, each once by git dir.
wbts_list() {
  local d
  declare -A seen
  WT_DIRS=() WT_GDS=()
  while IFS= read -r d; do
    if [ -z "$d" ] || [ ! -d "$d" ] || ! wbts_gd "$d" || [ -n "${seen[$GD]:-}" ]; then continue; fi
    seen[$GD]=1
    WT_DIRS+=("$d")
    WT_GDS+=("$GD")
  done < <(
    printf '%s\n' "$PWD"
    [ -n "${TMUX_PANE:-}" ] && wbts_task_dirs
  )
}

main() {
  local i fd held="" US=$'\037' dir gd
  case "$WBTS_VERB" in prompt | stop | _prompt) ;; *) return 0 ;; esac
  if [ "$WBTS_VERB" = _prompt ]; then
    # The parent's locks sit on inherited descriptors; each line is fd, git dir, directory.
    while IFS="$US" read -r fd gd dir; do
      [ -n "$fd" ] || continue
      WBTS_WT="$dir" GD="$gd"
      wbts_run_prompt
      exec {fd}>&-
    done <<<"${WBTS_HELD:-}"
    return 0
  fi
  [ "$WBTS_VERB" = stop ] && { [ -t 0 ] || WBTS_INPUT="$(cat)"; }
  local budget=3
  [ "$WBTS_VERB" = stop ] && budget=8
  WBTS_DEADLINE=$((${EPOCHREALTIME/[.,]/} + budget * 1000000))
  wbts_list
  for i in "${!WT_DIRS[@]}"; do
    WBTS_WT="${WT_DIRS[i]}" GD="${WT_GDS[i]}"
    exec {fd}>>"$GD/wb-turn.lock" || continue
    if wbts_cap; then
      flock -w "$WBTS_CT" "$fd" || {
        exec {fd}>&-
        continue
      }
    else
      flock -n "$fd" || {
        exec {fd}>&-
        continue
      }
    fi
    if [ "$WBTS_VERB" = stop ]; then
      wbts_run_stop
      exec {fd}>&-
    else
      held+="$fd$US$GD$US$WBTS_WT"$'\n'
    fi
  done
  # The descriptors carry the locks into the child; the parent's copies close on exit.
  [ -n "$held" ] && WBTS_HELD="$held" setsid -f bash "${BASH_SOURCE[0]}" _prompt </dev/null >/dev/null 2>&1
}

main
exit 0
