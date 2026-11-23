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
# marked interrupted. Both verbs hold <git-dir>/wb-turn.lock (flock; the detached
# child inherits it, so a Stop waits for a running prompt), every git call has a
# timeout, refs move with update-ref and the old value, and on any failure the refs
# stay as they were.
#
# Guards, in plain bash before any fork: the kill switch
# ${XDG_STATE_HOME:-~/.local/state}/wb/disable-turn-snapshot,
# CLAUDE_CODE_SESSION_ATTENDED=0, an sdk* entrypoint (headless `claude -p`
# children), no TMUX_PANE. Then one git call confirms a linked worktree, so a
# Claude in a main checkout writes nothing. Always exits 0; prints nothing.
#
# Tunable (env): WB_TURN_GIT_TIMEOUT (5), seconds each git call may take.
set -uo pipefail

WBTS_VERB="${1:-}"

[ -e "${XDG_STATE_HOME:-$HOME/.local/state}/wb/disable-turn-snapshot" ] && exit 0
[ "${CLAUDE_CODE_SESSION_ATTENDED:-}" = 0 ] && exit 0
case "${CLAUDE_CODE_ENTRYPOINT:-}" in sdk*) exit 0 ;; esac
[ -n "${TMUX_PANE:-}" ] || exit 0

WBTS_T="${WB_TURN_GIT_TIMEOUT:-5}"
REF_START=refs/worktree/wb/turn-start
REF_TURN=refs/worktree/wb/turn
ZERO=0000000000000000000000000000000000000000

git_() { timeout "$WBTS_T" git --no-optional-locks -c commit.gpgsign=false "$@"; }

# wbts_snapshot — print the sha of a commit-less tree of the current worktree.
wbts_snapshot() {
  [ -e "$GD/wb-turn-index" ] || cp "$GD/index" "$GD/wb-turn-index" 2>/dev/null
  GIT_INDEX_FILE="$GD/wb-turn-index" git_ add -A >/dev/null 2>&1 || return 1
  GIT_INDEX_FILE="$GD/wb-turn-index" git_ write-tree 2>/dev/null
}

# wbts_commit <tree> [<parent>] <message> — print a new commit's sha.
wbts_commit() {
  local tree="$1" parent="" msg
  if [ "$#" -eq 3 ]; then parent="$2"; msg="$3"; else msg="$2"; fi
  GIT_AUTHOR_NAME=wb-turn-snapshot GIT_AUTHOR_EMAIL=wb@localhost \
    GIT_COMMITTER_NAME=wb-turn-snapshot GIT_COMMITTER_EMAIL=wb@localhost \
    git_ commit-tree "$tree" ${parent:+-p "$parent"} -m "$msg" 2>/dev/null
}

# wbts_set <ref> <new> — move a ref to <new>, expecting the value it has now.
wbts_set() {
  local old
  old="$(git_ rev-parse -q --verify "$1" 2>/dev/null)" || old="$ZERO"
  git_ update-ref "$1" "$2" "$old" >/dev/null 2>&1
}

# wbts_record <tree> <interrupted:0|1> <reply> — when <tree> differs from
# turn-start's, write the turn ref. Returns nonzero on a git failure.
wbts_record() {
  local tree="$1" intr="$2" reply="$3" start start_tree head msg subject="wb turn"
  start="$(git_ rev-parse -q --verify "$REF_START" 2>/dev/null)" || return 0
  start_tree="$(git_ rev-parse "$start^{tree}" 2>/dev/null)" || return 1
  [ "$start_tree" = "$tree" ] && return 0
  head="$(git_ rev-parse -q --verify HEAD 2>/dev/null)"
  [ "$intr" = 1 ] && subject="wb turn (interrupted)"
  msg="$subject"$'\n\n'"head $head"$'\n'"reply $reply"
  local c
  c="$(wbts_commit "$tree" "$start" "$msg")" && [ -n "$c" ] || return 1
  wbts_set "$REF_TURN" "$c"
}

# wbts_move_start <tree> — turn-start becomes a parentless commit of <tree>.
wbts_move_start() {
  local c
  c="$(wbts_commit "$1" "wb turn start")" && [ -n "$c" ] || return 1
  wbts_set "$REF_START" "$c"
}

# wbts_run_prompt — the detached half of `prompt`; the lock is already held.
wbts_run_prompt() {
  local tree
  tree="$(wbts_snapshot)" && [ -n "$tree" ] || return 0
  if [ -e "$GD/wb-turn-open" ]; then
    wbts_record "$tree" 1 "" || return 0
  fi
  wbts_move_start "$tree" || return 0
  : >"$GD/wb-turn-open"
}

wbts_run_stop() {
  local input reply="" tree
  if [ ! -t 0 ]; then
    input="$(cat)"
    if [[ "$input" == *last_assistant_message* ]] && command -v jq >/dev/null 2>&1; then
      reply="$(printf '%s' "$input" | jq -r '(.last_assistant_message // "") | tostring | split("\n")[0] | .[0:200]' 2>/dev/null)"
    fi
  fi
  flock -w 8 9 || return 0
  tree="$(wbts_snapshot)" && [ -n "$tree" ] || return 0
  wbts_record "$tree" 0 "$reply" || return 0
  wbts_move_start "$tree" || return 0
  rm -f "$GD/wb-turn-open"
}

main() {
  local dirs
  case "$WBTS_VERB" in prompt | stop | _prompt) ;; *) return 0 ;; esac
  dirs="$(git_ rev-parse --absolute-git-dir --path-format=absolute --git-common-dir 2>/dev/null)" || return 0
  GD="${dirs%%$'\n'*}"
  [ -n "$GD" ] && [ "$GD" != "${dirs#*$'\n'}" ] || return 0
  case "$WBTS_VERB" in
    _prompt) wbts_run_prompt ;;
    stop)
      exec 9>>"$GD/wb-turn.lock" || return 0
      wbts_run_stop
      ;;
    prompt)
      exec 9>>"$GD/wb-turn.lock" || return 0
      flock -w 3 9 || return 0
      # fd 9 carries the lock into the child; the parent's copy closes on exit.
      setsid -f bash "${BASH_SOURCE[0]}" _prompt </dev/null >/dev/null 2>&1
      ;;
  esac
}

main
exit 0
