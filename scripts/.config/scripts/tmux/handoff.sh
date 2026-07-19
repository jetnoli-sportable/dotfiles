#!/usr/bin/env bash
# handoff.sh — route one piece of in-conversation discussion to its worker:
# switch to an already-live session (clipboard handoff) or spawn a fresh one.
#   handoff.sh <repo> <slug>
#
# Entirely mechanical — the /handoff skill (claude/.claude/skills/handoff/
# SKILL.md) owns the conversational judgment (repo/slug inference, rich
# context, first_action); this script only checks for a live session and
# either switches + clipboards, or spawns + injects. `first_action` is never
# a flag here — it lives in the target task file's body (R6).
#
# Design + rationale: docs/plans/2026-07-11-001-feat-handoff-v1-plan.md.
# wb.sh is never modified — see that file's own header and the BASH_SOURCE
# guard at its end, which is exactly what makes sourcing it here safe.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WB="$SCRIPT_DIR/wb.sh"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"
# Safe to source: wb.sh's CLI dispatch is guarded by
# `[ "${BASH_SOURCE[0]}" = "${0}" ]` (wb.sh, end of file), which is false
# when wb.sh is sourced from another script — the same property
# tests/wb-resume.test.sh already relies on. This reuses wb_sanitize/
# wb_task_file (read-only helpers) without hand-copying the sanitize
# transform where it could drift. NOTE: sourcing wb.sh reassigns
# SCRIPT_DIR/SELF/CODE_DIR to its own values (wb.sh:43-44,53) — harmless
# today because handoff.sh never reads $SELF, and CODE_DIR is now guarded
# the same way TASKS_DIR is (`CODE_DIR="${CODE_DIR:-$HOME/code}"`,
# wb.sh:53, fixed in fc95c63 — the exact variable from the 2026-07-10
# deletion incident, where an unconditional reassignment in a sourced
# script clobbered the sourcing script's own value of the same name).
# $WB is captured above, before sourcing, so it's unaffected either way.
# shellcheck source=wb.sh
source "$WB"

# Poll timeouts — env-var overridable, matching wb.sh's own
# WB_SWEEP_THRESHOLD="${WB_SWEEP_THRESHOLD:-5}" convention (wb.sh:32).
HANDOFF_BOOT_TIMEOUT="${HANDOFF_BOOT_TIMEOUT:-30}"
HANDOFF_PERMISSION_TIMEOUT="${HANDOFF_PERMISSION_TIMEOUT:-20}"

# --pane split direction (KTD6) — the one place the horizontal-vs-vertical
# choice lives, so flipping side-by-side to stacked is a single-word change
# (or a per-invocation `HANDOFF_PANE_SPLIT=-v` override) rather than a literal
# scattered through the pane branch. Default `-h` = side-by-side, matching the
# decision-buffer split precedent (claude/.claude/skills/decision-buffer/SKILL.md:174).
HANDOFF_PANE_SPLIT="${HANDOFF_PANE_SPLIT:--h}"

# handoff_wait_for_pane_pattern <target> <timeout_secs> <extended-regex> —
# polls <target>'s recent pane text for <pattern>, 1s between attempts, up
# to <timeout_secs>. Mirrors lib.sh's own tmux_pane_awaiting_input tail-20
# scoping convention — a bounded recent-lines window keeps stale scrollback
# (or handoff.sh's own just-injected pointer sitting in the echoed input
# line before Enter is processed) from ever entering the match.
handoff_wait_for_pane_pattern() {
  local target="$1" timeout="$2" pattern="$3" waited=0 screen
  while [ "$waited" -lt "$timeout" ]; do
    screen="$(tmux capture-pane -ep -t "$target" 2>/dev/null | tail -n 20)"
    if printf '%s' "$screen" | grep -qE "$pattern"; then
      printf '%s\n' "$screen"
      return 0
    fi
    sleep 1; waited=$((waited + 1))
  done
  return 1
}

# handoff_bootstrap_gap <repo_dir> — true (exit 0) when <repo_dir> has
# NEITHER a .worktree-bootstrap manifest NOR any root .env* file (R11).
# Mirrors wb_bootstrap's own detection (wb.sh:142-157) read-only — it never
# performs the actual copy, just answers "would wb_bootstrap have found
# anything to copy?" so the spawn path can decide whether to warn without
# re-implementing the bootstrap step itself.
handoff_bootstrap_gap() {
  local repo_dir="$1"
  if [ -f "$repo_dir/.worktree-bootstrap" ]; then
    return 1
  fi
  local f
  while IFS= read -r -d '' f; do
    return 1
  done < <(find "$repo_dir" -maxdepth 1 -name '.env*' -print0 2>/dev/null)
  return 0
}

# handoff_append_followup <task_file> <line> — insert "- <line>" under a
# "## Follow-ups" heading, the durable channel R3 establishes for exactly
# this kind of note (R11), so a spawn nobody is watching the terminal for
# doesn't leave the gap's only record in a scrollback buffer. The live
# ~/code/tasks/TEMPLATE.md has no such heading at all, and it's absent
# from real pre-existing task files too — not just ones freshly created
# from the template — so this ensures the heading exists rather than
# requiring the caller to have added it: inserts "## Follow-ups" right
# before "## Decisions" when that heading exists, or appends a new
# section at EOF when neither heading is present. Mirrors
# wb_reconcile_merge_content's own awk-based body-insertion style (wb.sh).
handoff_append_followup() {
  local file="$1" line="$2"
  awk -v line="$line" '
    $0 == "## Decisions" && !inserted {
      print "## Follow-ups"
      print ""
      print "- " line
      print ""
      inserted = 1
    }
    { print }
    $0 == "## Follow-ups" && !inserted { print "- " line; inserted = 1 }
    END {
      if (!inserted) {
        print ""
        print "## Follow-ups"
        print ""
        print "- " line
      }
    }
  ' "$file" > "$file.tmp.$$" && mv "$file.tmp.$$" "$file"
}

# handoff_permission_prompt_matches <pane_text> <pointer> — true when
# <pane_text>, with handoff.sh's own injected <pointer> line stripped out
# first, contains BOTH the literal permission-prompt phrase and a
# ~/code/tasks or Read substring (R10) — the co-occurrence requirement
# that keeps a differently-shaped dialog from ever being blind-approved.
# The strip is load-bearing, not defensive: the pointer's own fixed text
# ("Read the task file at...") starts with "Read" and sits in the exact
# pane this scans, so without stripping it first, the co-occurrence check
# is satisfied by our own injection regardless of which dialog actually
# appeared — a real dialog's own "Read(<path>)" tool-invocation line is
# what should satisfy this, not text we typed ourselves moments earlier.
handoff_permission_prompt_matches() {
  local text="$1" pointer="$2" filtered
  filtered="$(printf '%s' "$text" | grep -vF "$pointer")"
  printf '%s' "$filtered" | grep -qE 'Do you want to proceed\?' \
    && printf '%s' "$filtered" | grep -qE '~/code/tasks|Read'
}

# Below this point: the actual routing run. Guarded exactly like wb.sh's own
# CLI dispatch (wb.sh, end of file) — false when this file is sourced rather
# than executed directly, so a caller (a test, or a future script) can reach
# the functions above without triggering a real run. Same BASH_SOURCE[0]-
# vs-$0 property already relied on above to source wb.sh safely.
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then

# Arg parse — split flags from positionals in one pass. The original
# two-positional switch/spawn contract is preserved untouched: an invocation
# with no --pane still collects exactly <repo> <slug> and takes the unchanged
# path below. --pane selects the mode; --await-perm is the child-binding
# handshake flag (KTD5); --pane's payload and switch/spawn's repo/slug both
# fall through as positionals.
mode="switch"
await_perm=0
args=()
while [ "$#" -gt 0 ]; do
  case "$1" in
    --pane) mode="pane" ;;
    --await-perm) await_perm=1 ;;
    *) args+=("$1") ;;
  esac
  shift
done

# --pane branch (KTD1) — entirely mechanical and self-contained: resolve the
# invoking pane's worktree, split the current window, boot-poll + inject, and
# (only for child binding, KTD5) clear the one-time tasks/ read prompt. It
# never writes the task store and never takes a task-file lock, and it returns
# before any switch/spawn logic below. Everything conversational — binding
# choice, posture, payload authoring, child seeding — is the /handoff-pane
# skill's job (claude/.claude/skills/handoff-pane/SKILL.md).
if [ "$mode" = "pane" ]; then
  # $TMUX/$TMUX_PANE are this branch's only environment inputs. Fail loudly if
  # either is missing — the $TMUX case mirrors the switch/spawn guard below;
  # $TMUX_PANE is the invoking agent's own pane, and its cwd is the worktree
  # both agents will share.
  if [ -z "${TMUX:-}" ]; then
    echo "handoff: --pane must run from inside a tmux client" >&2
    exit 1
  fi
  if [ -z "${TMUX_PANE:-}" ]; then
    echo "handoff: --pane needs \$TMUX_PANE set (the invoking pane, whose cwd is the shared worktree)" >&2
    exit 1
  fi
  if [ "${#args[@]}" -ne 1 ]; then
    echo "usage: handoff.sh --pane [--await-perm] <payload>" >&2
    exit 1
  fi
  payload="${args[0]}"

  # KTD3: resolve the worktree from the invoking pane's cwd — pane mode has no
  # <repo> <slug> to derive it from — then verify it really is a git worktree.
  # A drifted cwd (the agent cd'd elsewhere earlier in this long-lived shell)
  # must fail loudly here, never silently split into the wrong directory.
  worktree="$(tmux display -p -t "$TMUX_PANE" '#{pane_current_path}')"
  if ! git -C "$worktree" rev-parse --show-toplevel >/dev/null 2>&1; then
    echo "handoff: $worktree is not a git worktree — refusing to split (\$TMUX_PANE's cwd may have drifted off the worktree)" >&2
    exit 1
  fi

  # KTD3: split a PLAIN pane (no trailing command) in the current window, then
  # launch claude by typing it into the new pane's interactive shell. Never
  # `split-window ... 'claude'` — that runs claude under `/bin/sh -c` (missing
  # the interactive-shell PATH that puts claude on $PATH) and, with no
  # remain-on-exit set, would leave no shell behind to diagnose a failed
  # launch. Mirrors wb_layout_session's own send-keys launch (wb.sh:800).
  # Split direction is the HANDOFF_PANE_SPLIT constant (KTD6), never a literal.
  pane="$(tmux split-window "$HANDOFF_PANE_SPLIT" -t "$TMUX_PANE" -c "$worktree" -P -F '#{pane_id}')"
  tmux send-keys -t "$pane" -l 'claude'
  tmux send-keys -t "$pane" Enter

  # R6: reuse the existing boot-ready poller (same anchor set as the spawn
  # path), pointed at the new pane instead of a spawned :agent window.
  if ! handoff_wait_for_pane_pattern "$pane" "$HANDOFF_BOOT_TIMEOUT" '\? for shortcuts|Try "|[0-9]+% ctx' >/dev/null; then
    echo "handoff: split a helper pane ($pane) but it never showed a boot-ready anchor within ${HANDOFF_BOOT_TIMEOUT}s — check it by hand" >&2
    exit 1
  fi

  # R6/R7: inject the payload exactly like the spawn path — one literal-flag
  # send-keys call, Enter as a SEPARATE call (never one call with an embedded
  # newline: premature-submission risk), plus the same resend-Enter guard for
  # the first-Enter-dropped-mid-TUI-transition case documented at the spawn
  # injector above. The payload is opaque here (posture-blind, KTD7) — the
  # skill composed it. Never sends /model (R7).
  tmux send-keys -t "$pane" -l "$payload"
  tmux send-keys -t "$pane" Enter
  sleep 1
  tmux send-keys -t "$pane" Enter

  # KTD5: run the permission handshake ONLY when the skill passed --await-perm
  # (child binding, whose payload points at a ~/code/tasks file outside the
  # worktree). The common ephemeral path reads only inside the already-trusted
  # worktree, so no outside-cwd prompt appears — skip the poll entirely.
  # Gating is on the explicit flag, never on payload content (payload-sniffing
  # would silently flip behavior when a prompt is reworded).
  if [ "$await_perm" = 1 ]; then
    if ! pane_text="$(handoff_wait_for_pane_pattern "$pane" "$HANDOFF_PERMISSION_TIMEOUT" 'Do you want to proceed\?')"; then
      echo "handoff: split the helper pane ($pane) and injected the pointer — no permission prompt seen within ${HANDOFF_PERMISSION_TIMEOUT}s (it may already be clear, or the agent hasn't reached its first action yet)" >&2
      exit 0
    fi
    if handoff_permission_prompt_matches "$pane_text" "$payload"; then
      # Same single-keystroke menu answer the spawn path uses — this menu
      # selects and submits on the keystroke itself, no trailing Enter.
      tmux send-keys -t "$pane" -l '2'
      echo "handoff: split the helper pane ($pane), injected the pointer, cleared the tasks/ read permission prompt"
    else
      echo "handoff: split the helper pane ($pane) and injected the pointer — a permission prompt appeared but didn't match the expected tasks/Read shape; leaving it for you to answer" >&2
    fi
  else
    echo "handoff: split a helper pane ($pane), booted claude, and injected the payload"
  fi
  exit 0
fi

# Switch/spawn path — the unchanged two-positional contract.
if [ "${#args[@]}" -ne 2 ]; then
  echo "usage: handoff.sh <repo> <slug>" >&2
  echo "       handoff.sh --pane [--await-perm] <payload>" >&2
  exit 1
fi

# Every path below eventually calls tmux_focus (lib.sh) via either this
# script's own switch branch or wb.sh's cmd_new — and tmux_focus falls
# back to a blocking, interactive `tmux attach` whenever $TMUX is unset.
# Fail loudly here instead of silently hanging (or aborting mid-spawn,
# after the worktree/session already exist) the first time that branch
# is reached deep inside a subprocess call.
if [ -z "${TMUX:-}" ]; then
  echo "handoff: must run from inside a tmux client (wb new --agent's own tmux_focus finale blocks on tmux attach otherwise)" >&2
  exit 1
fi

repo="${args[0]}"
slug="${args[1]}"

# wb_task_file/wb_seed_task (wb.sh) never sanitize $repo, and $slug's only
# sanitize step (wb_sanitize) rewrites `/`/`.`/`:` for the display name —
# it doesn't reject a leading `/` or a `..` traversal segment before that
# raw slug is used to build `worktree: .worktrees/$slug` and a real git
# branch. Reject both here, before either value touches any path/command
# construction below — this is handoff.sh's job since wb.sh can't be
# modified to add it there.
case "$repo" in
  *[!A-Za-z0-9_.-]*|*..*) echo "handoff: invalid repo: $repo" >&2; exit 1 ;;
esac
case "$slug" in
  /*|*..*|*:*|*[!A-Za-z0-9/_.-]*) echo "handoff: invalid slug: $slug" >&2; exit 1 ;;
esac

disp_slug="$(wb_sanitize "$slug")"
session="${repo}--${disp_slug}"
task_file="$(wb_task_file "$repo" "$disp_slug")"
# U3: wb_task_lock_acquire_guarded/wb_task_lock_release/
# _wb_lock_trap_append_if_top_level all come from wb-locks.sh + wb.sh, both
# already sourced above — this installs the EXIT-trap lock-release safety
# net once for this whole run, same convention every locking wb.sh cmd_*
# verb uses (the _if_top_level guard, not a raw wb_lock_trap_append call,
# for the same subshell-safety reason documented at that function's own
# definition in wb.sh — this file's own real run body is never itself
# invoked via command substitution, but staying consistent with every
# other call site avoids re-litigating the same footgun here later).
_wb_lock_trap_append_if_top_level wb_task_lock_release_all

# Fully fixed — no variable substitution beyond $task_file. first_action
# never appears here (R6); the pointer's disjointness from the boot/
# permission anchor sets (U2) depends on this string never varying.
pointer="Read the task file at $task_file - it carries the full context and states the first action to take."

agent_state="$(tmux_session_agent_state "$session")"
if [ "$agent_state" != "dead" ]; then
  # Switch path: a live session already exists for this repo/slug. A live
  # session is not the same as a live agent — a prior spawn's boot-ready
  # timeout leaves the session behind with nothing killing it, and a bare
  # `wb new` (no --agent) deliberately leaves the "agent" window as an
  # idle shell (wb_layout_session, wb.sh:210-214). tmux_session_agent_state
  # (lib.sh) owns the has-session + pane_current_command check this branch
  # used to do inline; "dead" and "unknown" both still land in the same
  # "not alive" message below — this call site only tells alive apart from
  # not-alive today (a future caller needs the finer distinction; see
  # tmux_session_agent_state's own doc comment).
  [ -f "$task_file" ] \
    || echo "handoff: warning: $session is live but $task_file does not exist" >&2
  # Focus first, clipboard second: the switch is the primary action of
  # this branch and must not fail as a side effect of the clipboard step
  # (secondary, convenience-only) failing.
  tmux_focus "$session"
  if printf '%s' "$pointer" | wl-copy >/dev/null 2>&1; then
    # wl-copy daemonizes to keep serving the selection after this line
    # returns; without redirecting its own stdout/stderr away from
    # whatever they're inherited from (e.g. a caller capturing this
    # script's output via command substitution), that lingering
    # background process holds the caller's pipe open forever, hanging
    # any reader waiting for EOF.
    clip_status="pointer copied to clipboard"
  else
    clip_status="clipboard copy failed — pointer not on clipboard"
  fi
  if [ "$agent_state" = "alive" ]; then
    echo "handoff: switched to live session $session — $clip_status"
  else
    echo "handoff: switched to live session $session, but its agent window has no running claude process — $clip_status" >&2
  fi
  exit 0
fi

# Spawn path — no live session for this repo/slug. `wb new --agent` is
# idempotent, safe whether the worktree/task file already exist or not.
"$WB" new --agent "$repo" "$slug"

# R11: surface (never fix) a bootstrap gap — the fix is a per-repo
# .worktree-bootstrap manifest, tracked as its own roadmap line item.
repo_dir="$(wb_repo_dir "$repo")"
if handoff_bootstrap_gap "$repo_dir"; then
  gap_msg="$repo_dir has neither a .worktree-bootstrap manifest nor a root .env* file — wb new's bootstrap step likely left this worktree incomplete (see wb_bootstrap, wb.sh:142-171)"
  echo "handoff: warning: $gap_msg" >&2
  # Best-effort: R11 is a non-blocking warning, and must stay one even if
  # the write itself fails — under set -e, an unguarded call here would
  # abort the rest of the spawn (boot poll, injection, permission
  # handshake) over a failure to record a note about an unrelated gap.
  if [ -f "$task_file" ]; then
    # Its own lock burst (W5) — best-effort like the rest of this R11 note:
    # a contended/failed acquire warns and moves on rather than aborting the
    # whole spawn over a missed note.
    if wb_task_lock_acquire_guarded "$task_file"; then
      handoff_append_followup "$task_file" "$gap_msg" \
        || echo "handoff: warning: could not record the bootstrap-gap note in $task_file" >&2
      wb_task_lock_release "$task_file"
    else
      echo "handoff: warning: could not acquire the task-file lock — bootstrap-gap note not recorded in $task_file" >&2
    fi
  fi
fi

# wb_layout_session (wb.sh:225) names the agent window "agent".
target="=$session:agent"

if ! handoff_wait_for_pane_pattern "$target" "$HANDOFF_BOOT_TIMEOUT" '\? for shortcuts|Try "|[0-9]+% ctx' >/dev/null; then
  echo "handoff: spawned $session but it never showed a boot-ready anchor within ${HANDOFF_BOOT_TIMEOUT}s — check $target by hand" >&2
  exit 1
fi

# R7/R9: the pointer is fully fixed (no first_action substitution), sent as
# one literal-flag send-keys call, Enter as a SEPARATE call — never
# combined into one call, never a literal embedded newline (premature-
# submission risk). Never sends `/model` to the pane (R7).
tmux send-keys -t "$target" -l "$pointer"
tmux send-keys -t "$target" Enter
# The very first Enter sent right as the boot-ready anchor first appears can
# be silently dropped — observed live (2026-07-11 smoke test): the TUI was
# still mid-transition from the welcome banner to interactive at that exact
# instant, and the pointer sat unsubmitted in the input box until a second
# Enter went through. Resending Enter once more after a short pause is a
# safe no-op if the first one already landed (Enter on an empty,
# already-submitted input box does nothing) and closes the gap when it
# didn't.
sleep 1
tmux send-keys -t "$target" Enter

if ! pane_text="$(handoff_wait_for_pane_pattern "$target" "$HANDOFF_PERMISSION_TIMEOUT" 'Do you want to proceed\?')"; then
  echo "handoff: spawned and injected $session — no permission prompt seen within ${HANDOFF_PERMISSION_TIMEOUT}s (it may already be clear, or the agent hasn't reached its first action yet)" >&2
  exit 0
fi

if handoff_permission_prompt_matches "$pane_text" "$pointer"; then
  # R10: single keystroke, no trailing Enter — confirmed live, this menu
  # selects and submits on the keystroke itself, unlike the main input box.
  tmux send-keys -t "$target" -l '2'
  echo "handoff: spawned $session, injected pointer, cleared the tasks/ read permission prompt"
else
  echo "handoff: spawned and injected $session — a permission prompt appeared but didn't match the expected tasks/Read shape; leaving it for you to answer at $target" >&2
fi

exit 0

fi
