#!/usr/bin/env bash
# Shared helpers for the tmux scripts in this directory.
# Sourced by session.sh, notes.sh and claude-sessions.sh — keeps the
# attach/switch logic (and the fd-binary quirk) in one place.

# fd ships as `fdfind` on Debian/Ubuntu. Shell aliases don't apply inside
# scripts, so resolve the real executable once.
FD_BIN="$(command -v fdfind || command -v fd || true)"

# tmux_ensure_session <name> <dir> — create a detached session if absent.
# Uses the `=` exact-name match so "03" never attaches to "03-foo".
tmux_ensure_session() {
  tmux has-session -t "=$1" 2>/dev/null || tmux new-session -d -s "$1" -c "$2"
}

# tmux_focus <name> — bring a session to the foreground.
tmux_focus() {
  if [ -n "${TMUX:-}" ]; then
    tmux switch-client -t "=$1"
  else
    tmux attach -t "=$1"
  fi
}

# tmux_attach_or_create <name> <dir> — ensure the session exists, then focus it.
tmux_attach_or_create() {
  tmux_ensure_session "$1" "$2"
  tmux_focus "$1"
}

# tmux_find_claude_pane <cwd> — print the session:window.pane target of the
# Claude Code pane running in <cwd> (first match wins), or exit 1 if none.
# Reuses the same `pane_current_command == claude` detection as the picker.
tmux_find_claude_pane() {
  local cwd="$1" cmd sess win pane path
  while IFS='|' read -r cmd sess win pane path; do
    [ "$cmd" = "claude" ] || continue
    [ "$path" = "$cwd" ] || continue
    printf '%s:%s.%s\n' "$sess" "$win" "$pane"
    return 0
  done < <(tmux list-panes -a -F \
    '#{pane_current_command}|#{session_name}|#{window_index}|#{pane_index}|#{pane_current_path}')
  return 1
}

# tmux_goto_pane <target> — focus a specific session:window.pane target.
tmux_goto_pane() {
  local target="$1" session winpane window
  session="${target%%:*}"
  winpane="${target#*:}"   # window.pane
  window="${winpane%%.*}"
  if [ -n "${TMUX:-}" ]; then
    tmux switch-client -t "$session"
    tmux select-window -t "$session:$window"
    tmux select-pane -t "$target"
  else
    tmux attach -t "$session" \; select-window -t "$session:$window" \; select-pane -t "$target"
  fi
}

# tmux_code_repos — every git repo dir under ~/code (by .git presence) plus a
# short allow-list of dirs that live outside ~/code's flat layout. Shared by
# session.sh and wb.sh so repo discovery stays in one place.
tmux_code_repos() {
  local extra=(
    "$HOME/code/notes"
    "$HOME/code/daemon"
  )
  { printf '%s\n' "${extra[@]}"
    "$FD_BIN" --type d --hidden --no-ignore-vcs \
      --exclude .terraform --exclude node_modules \
      '^\.git$' "$HOME/code" -X dirname
  } | sort -u
}

# tmux_pane_awaiting_input <target> — true if the pane is showing a modal that
# needs YOU (a permission prompt or AskUserQuestion menu) rather than sitting
# idle. Calibrated against Claude Code v2.1.179: every such modal drops the
# `-- INSERT --` input box and shows an "Esc to cancel" footer (permission
# prompts additionally say "Do you want to proceed?"). Idle and working panes
# always keep `-- INSERT --`. If a future Claude Code changes this modal UI,
# this pair of greps is the one thing to recalibrate (capture a live prompt
# with `tmux capture-pane -ep -t <target>` and compare).
tmux_pane_awaiting_input() {
  local screen
  screen="$(tmux capture-pane -ep -t "$1" 2>/dev/null | tail -n 20)"
  ! grep -q -- '-- INSERT --' <<<"$screen" \
    && grep -qE 'Esc to cancel|Do you want to (proceed|run)' <<<"$screen"
}

# tmux_claude_panes [session] — emit one row per running Claude pane, tab-separated:
#   <rank>\t<target>\t<status>\t<task>
# rank orders needs-input(0) before done/waiting(1) before working(2) before
# idle(3), so callers surface the agent that's actually blocking you first.
# Pass a session name to scope to just that session's panes (used by wb's
# per-session urgency check); omit to scan every session (claude-sessions.sh).
# See tmux_pane_awaiting_input for the "needs input" modal-detection note —
# this is the single shared home for that calibration.
#
# The title glyph alone can no longer tell "working" from "idle at the
# prompt": this case was calibrated against Claude Code v2.1.179, where an
# active turn showed a distinct braille-spinner glyph and only an idle prompt
# showed "✳". Confirmed live against v2.1.241: the title glyph is a static
# "✳" during BOTH an actively-generating turn and a genuinely idle one, so
# the glyph case can no longer reach its
# "working" branch for a real agent — every in-progress session read back as
# "waiting" until Stop fired. @claude_working (claude-notify-hook.sh, set at
# UserPromptSubmit, cleared at Stop) is the ground-truth fix for that; the
# glyph stays as the fallback for a pane with no hook data (e.g. an older
# Claude Code build, or claude launched outside wb's hook-managed settings).
tmux_claude_panes() {
  local scope="${1:-}"
  local cmd sess win pane blocked working title target glyph task status rank
  while IFS='|' read -r cmd sess win pane blocked working title; do
    [ "$cmd" = "claude" ] || continue
    [ -z "$scope" ] || [ "$sess" = "$scope" ] || continue
    target="$sess:$win.$pane"
    glyph="${title%% *}"          # leading token
    task="${title#* }"            # everything after it
    [ "$task" = "$title" ] && task=""   # no space => no task text
    case "$glyph" in
      ✳)               status="waiting"; rank=1 ;;   # turn finished, idle at the prompt
      ""|[A-Za-z0-9]*) status="idle";    rank=3 ;;   # plain text, no spinner
      *)               status="working"; rank=2 ;;   # a spinner glyph
    esac
    # "needs input" — BLOCKED on you, not merely idle. Two signals:
    #   (1) @claude_blocked: a marker the agent sets on its own pane before it
    #       blocks on an nvim buffer (decision-buffer skill). That block shows a
    #       spinner in the pane, so a content scan can't see it — hence the
    #       explicit marker. Its value (e.g. "nvim-buffer") is the reason why.
    #   (2) a live permission / AskUserQuestion menu (tmux_pane_awaiting_input).
    #       Such modals carry the ✳ glyph, so only ✳ ("waiting") panes are scanned.
    # A pushed marker (claude-notify-hook.sh) is ground truth and beats the glyph:
    #   "done"  -> a long turn just finished (Stop hook); awaiting you, rank 1
    #   any other non-empty value (needs-input / nvim-buffer / ...) -> blocked, rank 0
    # With hooks installed the content scan is a fallback for unmarked ✳ panes.
    if [ "$blocked" = done ]; then
      status="done"; rank=1
    elif [ -n "$blocked" ]; then
      status="needs-input"; rank=0
    elif [ "$status" = "waiting" ] && tmux_pane_awaiting_input "$target"; then
      status="needs-input"; rank=0
    elif [ "$status" = "waiting" ] && [ "$working" = "1" ]; then
      status="working"; rank=2   # @claude_working: a turn is actually running (see above)
    fi
    [ -n "$task" ] || task="Claude Code"
    printf '%d\t%s\t%s\t%s\n' "$rank" "$target" "$status" "$task"
  done < <(tmux list-panes -a -F \
    '#{pane_current_command}|#{session_name}|#{window_index}|#{pane_index}|#{@claude_blocked}|#{@claude_working}|#{pane_title}')
}

# wb_live_agent_count — total live `claude` panes across every tmux session
# on this server (R7). Deliberately NOT built on tmux_claude_panes: that
# function does a full needs-input/working/waiting classification for every
# pane — including a `tmux capture-pane` + two greps per "waiting" pane
# (tmux_pane_awaiting_input, above) — all of which this count would discard.
# This is the same minimal `pane_current_command == claude` query the
# claude() wrapper (zsh/.zshrc) uses directly, since zsh can't call this bash
# function (separate process) — the two are independently-maintained copies
# of one predicate, not a shared implementation; keep them in sync if the
# definition of "live" ever changes.
wb_live_agent_count() {
  # `|| true`: grep -c exits 1 on zero matches (the common case — no live
  # agents), which would otherwise abort any caller running under `set -e`
  # (wb.sh does) at this command substitution — same idiom wb.sh's own
  # zero-count helpers already use (e.g. wb.sh:3846, :5254).
  tmux list-panes -a -F '#{pane_current_command}' 2>/dev/null | grep -cx claude || true
}

# tmux_session_agent_state <session> — tri-state liveness check for a wb
# session's ":agent" window: "dead" (no exact "=<session>" tmux session
# exists at all), "unknown" (the session exists, but its ":agent" pane
# either doesn't exist or isn't running a claude process — e.g. a prior
# spawn's boot-ready timeout leaves the session behind with nothing killing
# it, or a bare `wb new` (no --agent) deliberately leaves the "agent"
# window as an idle shell, wb_layout_session wb.sh:210-214), or "alive"
# (the session exists AND the ":agent" pane's pane_current_command is
# exactly "claude"). Extracted from handoff.sh's own switch-path check — a
# pure relocation of that field-proven two-stage check (see that call
# site's own comment for the "zombie session" scenario it guards against),
# not a rewrite: only the return value changed shape, from a 0/1 flag to
# this 3-way string. handoff.sh's own caller today still only tells alive
# apart from not-alive and folds dead/unknown into the same branch; a
# lock-contention caller (a future, separate unit) needs the two told
# apart to decide whether a lock holder can be treated as an orphan.
tmux_session_agent_state() {
  local session="$1"
  tmux has-session -t "=$session" 2>/dev/null || { echo dead; return; }
  if [ "$(tmux list-panes -t "=$session:agent" -F '#{pane_current_command}' 2>/dev/null)" = "claude" ]; then
    echo alive
  else
    echo unknown
  fi
}
