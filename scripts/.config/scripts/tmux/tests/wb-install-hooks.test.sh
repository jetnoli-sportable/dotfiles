#!/usr/bin/env bash
# Tests for `wb install-hooks` (U8) — the one idempotent verb that wires up
# the concurrency-safety machine on a host: sets core.hooksPath + gc/reflog
# hardening (X5) on $TASKS_DIR, pre-creates the git-hook kill-switch (X4)
# unless a later unit's replay tool already left its marker, and VERIFIES
# (never edits — Decision 4A) the live ~/.claude/settings.json's
# hooks.PreToolUse entry against the tracked claude/.claude/
# settings.recommended.json.
#
# Every scenario redirects HOME / TASKS_DIR / XDG_STATE_HOME / CODE_DIR to a
# fresh fixture directory — this file must NEVER touch the real
# ~/code/tasks checkout or the real ~/.claude/settings.json (see this
# plan's own CRITICAL SAFETY CONSTRAINT).
#
# dotfiles_root resolution note: cmd_install_hooks tries `git -C
# "$SCRIPT_DIR" rev-parse --show-toplevel` first, falling back to
# "$CODE_DIR/dotfiles". This checkout may be a linked git WORKTREE whose
# on-disk `.git` FILE points at an absolute path inside the MAIN checkout's
# `.git/worktrees/<name>` dir — the Docker sandbox mounts only this one
# worktree directory at `/repo` (per this suite's own Dockerfile), so that
# main-checkout `.git` dir is never present inside the container and `git
# rev-parse` fails there (confirmed empirically) even though the working
# tree itself is perfectly intact. Every fixture below therefore seeds
# "$CODE_DIR/dotfiles" as a symlink to the REAL repo root (found via fixed
# path arithmetic, same convention wb-append.test.sh's own REPO_ROOT uses,
# for the same reason) so the fallback path resolves to the real, tracked
# settings.recommended.json regardless of which environment this runs in.
#
# MUST run via the project's sandboxed Dockerfile, same reasoning as every
# sibling *.test.sh header in this directory:
#   docker build -t wb-tests -f scripts/.config/scripts/tmux/tests/Dockerfile .
#   docker run --rm -v "$(pwd)":/repo:ro -w /repo wb-tests \
#     bash scripts/.config/scripts/tmux/tests/wb-install-hooks.test.sh
set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WB="$SELF_DIR/wb.sh"
# REPO_ROOT: SELF_DIR is always <repo-root>/scripts/.config/scripts/tmux (4
# path components below repo root) by this whole suite's fixed-layout
# convention — plain path arithmetic, not `git rev-parse`, for the reason
# explained above.
REPO_ROOT="$(cd "$SELF_DIR/../../../.." && pwd)"
RECOMMENDED_REAL="$REPO_ROOT/claude/.claude/settings.recommended.json"

FIXTURE="$(mktemp -d -t wb-install-hooks-fixture.XXXXXX)"
trap 'rm -rf "$FIXTURE"' EXIT

fail=0
assert() { # <desc> <expected-regex> <actual>
  if printf '%s' "$3" | grep -qE "$2"; then
    echo "ok   - $1"
  else
    echo "FAIL - $1"
    echo "       expected match: $2"
    echo "       got: $(printf '%s' "$3" | head -8)"
    fail=1
  fi
}
assert_not() { # <desc> <unexpected-regex> <actual>
  if printf '%s' "$3" | grep -qE "$2"; then
    echo "FAIL - $1 (unexpectedly present)"
    fail=1
  else
    echo "ok   - $1"
  fi
}
assert_eq() { # <desc> <expected> <actual>
  if [ "$2" = "$3" ]; then
    echo "ok   - $1"
  else
    echo "FAIL - $1 (expected '$2', got '$3')"
    fail=1
  fi
}

if [ ! -f "$RECOMMENDED_REAL" ]; then
  echo "FAIL - sanity: real settings.recommended.json not found at $RECOMMENDED_REAL — cannot run this suite"
  exit 1
fi

# new_scenario <name> — sets TASKS_DIR/HOME/XDG_STATE_HOME/CODE_DIR to a
# fresh, isolated fixture tree under $FIXTURE/<name>/, initializes TASKS_DIR
# as a real git repo (cmd_install_hooks shells out to `git -C "$TASKS_DIR"
# config ...`), and seeds CODE_DIR/dotfiles as a symlink to the real repo
# root (see header note) so the settings.recommended.json fallback lookup
# always finds the real tracked file regardless of environment.
new_scenario() {
  local name="$1"
  TASKS_DIR="$FIXTURE/$name/tasks"
  HOME="$FIXTURE/$name/home"
  XDG_STATE_HOME="$FIXTURE/$name/state"
  CODE_DIR="$FIXTURE/$name/code"
  mkdir -p "$TASKS_DIR" "$HOME" "$XDG_STATE_HOME" "$CODE_DIR"
  git init -q "$TASKS_DIR"
  ln -s "$REPO_ROOT" "$CODE_DIR/dotfiles"
  export TASKS_DIR HOME XDG_STATE_HOME CODE_DIR
}

EXPECTED_HOOKS_DIR_SUFFIX="/.config/scripts/tmux/tasks-git-hooks"

# shellcheck disable=SC1090
source "$WB"
set +e   # wb.sh sets -e; this suite intentionally captures non-zero exits

# =============================================================================
# Scenario 1: first run on a totally fresh $TASKS_DIR / fixture HOME — sets
# core.hooksPath to the expected STOWED path, all three gc keys to
# non-empty (generous) values, creates the disable-git-hook switch file
# (no replay-passed marker in this fixture's XDG_STATE_HOME), and — since
# the fixture "live settings.json" doesn't exist at all — prints the
# paste-block AND the restart reminder.
# =============================================================================

new_scenario first
out1="$(cmd_install_hooks 2>&1)"; rc1=$?
assert_eq "first run: exits 0" 0 "$rc1"

hooks_path_val="$(git -C "$TASKS_DIR" config --get core.hooksPath)"
assert_eq "first run: core.hooksPath set to the stowed path" "$HOME$EXPECTED_HOOKS_DIR_SUFFIX" "$hooks_path_val"

gc_auto_val="$(git -C "$TASKS_DIR" config --get gc.auto)"
assert_eq "first run: gc.auto set to 0" "0" "$gc_auto_val"

reflog_val="$(git -C "$TASKS_DIR" config --get gc.reflogExpire)"
[ -n "$reflog_val" ] && echo "ok   - first run: gc.reflogExpire is non-empty ($reflog_val)" || { echo "FAIL - first run: gc.reflogExpire is empty"; fail=1; }

reflog_unreach_val="$(git -C "$TASKS_DIR" config --get gc.reflogExpireUnreachable)"
[ -n "$reflog_unreach_val" ] && echo "ok   - first run: gc.reflogExpireUnreachable is non-empty ($reflog_unreach_val)" || { echo "FAIL - first run: gc.reflogExpireUnreachable is empty"; fail=1; }

SWITCH_FIRST="$XDG_STATE_HOME/wb/disable-git-hook"
[ -f "$SWITCH_FIRST" ] && echo "ok   - first run: disable-git-hook switch file created" || { echo "FAIL - first run: switch file missing at $SWITCH_FIRST"; fail=1; }

assert "first run: reports installed (not already-installed)" 'installed \(hooksPath=' "$out1"
assert_not "first run: does NOT claim already-installed" 'already installed, nothing to do' "$out1"
assert "first run: prints the paste-this instructions" "paste this into .*settings\.json" "$out1"
assert "first run: paste block names the PreToolUse hooks key" '"PreToolUse"' "$out1"
assert "first run: paste block names the pretooluse-guard.sh command" 'tasks-git-hooks/pretooluse-guard\.sh' "$out1"
assert "first run: prints the restart-running-sessions reminder" 'RESTART every already-running Claude Code session' "$out1"
assert "first run: restart reminder explains snapshot-at-startup" 'snapshotted at session start' "$out1"

# =============================================================================
# Scenario 1b (same fixture, immediately after): a second run is a clean
# no-op — reports "already installed" framing, git config values unchanged,
# switch file still present (not re-created — mtime proves it was never
# touched again), and the settings check still prints the block (repeatable
# prompting is fine/expected — the fixture live file is still missing the
# entry, nothing changed there either).
# =============================================================================

switch_mtime_before="$(stat -c %Y "$SWITCH_FIRST" 2>/dev/null)"
sleep 1

out2="$(cmd_install_hooks 2>&1)"; rc2=$?
assert_eq "second run: exits 0" 0 "$rc2"
assert "second run: reports already-installed framing" 'already installed, nothing to do' "$out2"

hooks_path_val2="$(git -C "$TASKS_DIR" config --get core.hooksPath)"
assert_eq "second run: core.hooksPath unchanged" "$hooks_path_val" "$hooks_path_val2"
gc_auto_val2="$(git -C "$TASKS_DIR" config --get gc.auto)"
assert_eq "second run: gc.auto unchanged" "$gc_auto_val" "$gc_auto_val2"
reflog_val2="$(git -C "$TASKS_DIR" config --get gc.reflogExpire)"
assert_eq "second run: gc.reflogExpire unchanged" "$reflog_val" "$reflog_val2"

[ -f "$SWITCH_FIRST" ] && echo "ok   - second run: switch file still present" || { echo "FAIL - second run: switch file vanished"; fail=1; }
switch_mtime_after="$(stat -c %Y "$SWITCH_FIRST" 2>/dev/null)"
assert_eq "second run: switch file NOT re-touched (mtime unchanged)" "$switch_mtime_before" "$switch_mtime_after"

assert "second run: settings check still prints the paste block (repeatable prompting expected)" "paste this into .*settings\.json" "$out2"

# =============================================================================
# Scenario 2: a replay-passed marker is present in a FRESH fixture (no prior
# disable-git-hook file) — the switch file must NOT be created even on a
# brand-new install. Assert its absence explicitly.
# =============================================================================

new_scenario replay
mkdir -p "$XDG_STATE_HOME/wb"
: > "$XDG_STATE_HOME/wb/replay-passed"

out3="$(cmd_install_hooks 2>&1)"; rc3=$?
assert_eq "replay-passed present: exits 0" 0 "$rc3"

SWITCH_REPLAY="$XDG_STATE_HOME/wb/disable-git-hook"
if [ -e "$SWITCH_REPLAY" ]; then
  echo "FAIL - replay-passed present: disable-git-hook switch file was created despite the marker — this would silently re-disable an already-enabled hook"
  fail=1
else
  echo "ok   - replay-passed present: disable-git-hook switch file correctly NOT created"
fi
assert "replay-passed present: message names the marker as the reason" 'replay-passed marker present' "$out3"

# gc/hooksPath hardening still applied even when the switch file is skipped.
hooks_path_replay="$(git -C "$TASKS_DIR" config --get core.hooksPath)"
assert_eq "replay-passed present: core.hooksPath still set" "$HOME$EXPECTED_HOOKS_DIR_SUFFIX" "$hooks_path_replay"

# =============================================================================
# Scenario 3: the LIVE settings.json already has the matching PreToolUse
# entry — the settings check prints a brief "already configured" note (no
# paste block / no restart reminder), and — the important part — a
# byte-for-byte checksum of the fixture settings.json before and after
# proves the file was NEVER opened for writing.
# =============================================================================

new_scenario already_configured
mkdir -p "$HOME/.claude"
cat > "$HOME/.claude/settings.json" <<'JSONEOF'
{
  "permissions": {"allow": ["Bash(ls:*)"]},
  "hooks": {
    "PreToolUse": [
      {
        "matcher": "Bash",
        "hooks": [
          {"type": "command", "command": "$HOME/.config/scripts/tmux/tasks-git-hooks/pretooluse-guard.sh"}
        ]
      }
    ]
  }
}
JSONEOF
LIVE_ALREADY="$HOME/.claude/settings.json"
sum_before="$(sha256sum "$LIVE_ALREADY" | awk '{print $1}')"

out4="$(cmd_install_hooks 2>&1)"; rc4=$?
assert_eq "already-configured: exits 0" 0 "$rc4"

sum_after="$(sha256sum "$LIVE_ALREADY" | awk '{print $1}')"
assert_eq "already-configured: settings.json checksum UNCHANGED (never opened for writing)" "$sum_before" "$sum_after"

assert "already-configured: reports already configured" 'already configured' "$out4"
assert_not "already-configured: does NOT print the paste-this block" 'paste this into .*settings\.json' "$out4"
assert_not "already-configured: does NOT print the restart reminder (nothing changed, nothing to restart for)" 'RESTART every already-running Claude Code session' "$out4"

# =============================================================================
# Scenario 4: the LIVE settings.json exists but has only UNRELATED hooks
# (Notification/Stop, no PreToolUse at all) — the settings check still
# correctly detects "missing" and prints the paste block, and (same
# checksum proof) never touches the file.
# =============================================================================

new_scenario unrelated_hooks
mkdir -p "$HOME/.claude"
cat > "$HOME/.claude/settings.json" <<'JSONEOF'
{
  "hooks": {
    "Notification": [
      {"matcher": "*", "hooks": [{"type": "command", "command": "notify.sh"}]}
    ],
    "Stop": [
      {"matcher": "*", "hooks": [{"type": "command", "command": "stop.sh"}]}
    ]
  }
}
JSONEOF
LIVE_UNRELATED="$HOME/.claude/settings.json"
sum_before_unrelated="$(sha256sum "$LIVE_UNRELATED" | awk '{print $1}')"

out5="$(cmd_install_hooks 2>&1)"; rc5=$?
assert_eq "unrelated hooks: exits 0" 0 "$rc5"

sum_after_unrelated="$(sha256sum "$LIVE_UNRELATED" | awk '{print $1}')"
assert_eq "unrelated hooks: settings.json checksum UNCHANGED (never opened for writing)" "$sum_before_unrelated" "$sum_after_unrelated"

assert "unrelated hooks: correctly detects the PreToolUse entry is missing" 'paste this into .*settings\.json' "$out5"
assert "unrelated hooks: restart reminder printed (something IS missing)" 'RESTART every already-running Claude Code session' "$out5"
content_unrelated="$(cat "$LIVE_UNRELATED")"
assert "unrelated hooks: pre-existing Notification hook untouched on disk" 'notify\.sh' "$content_unrelated"
assert "unrelated hooks: pre-existing Stop hook untouched on disk" 'stop\.sh' "$content_unrelated"

# =============================================================================
# Scenario 5: gc values are non-trivial/generous — at least on the order of
# weeks/months, not a tiny/default value. Parsed via GNU date rather than a
# hardcoded literal string match, so this holds regardless of the exact
# wording cmd_install_hooks picks, as long as it's genuinely generous.
# Threshold: >= 60 days (double git's own 30-day gc.reflogExpireUnreachable
# default) comfortably separates "generous" from "tiny/default".
# =============================================================================

new_scenario generous
cmd_install_hooks >/dev/null 2>&1

reflog_generous="$(git -C "$TASKS_DIR" config --get gc.reflogExpire)"
reflog_unreach_generous="$(git -C "$TASKS_DIR" config --get gc.reflogExpireUnreachable)"

GENEROUS_THRESHOLD_SECS=$((60 * 24 * 3600))   # 60 days
now_epoch="$(date +%s)"

for pair in "gc.reflogExpire:$reflog_generous" "gc.reflogExpireUnreachable:$reflog_unreach_generous"; do
  key="${pair%%:*}"
  val="${pair#*:}"
  expire_epoch="$(date -d "$val ago" +%s 2>/dev/null)"
  if [ -z "$expire_epoch" ]; then
    echo "FAIL - generous: $key value '$val' is not a GNU-date-parseable duration"
    fail=1
    continue
  fi
  span=$(( now_epoch - expire_epoch ))
  if [ "$span" -ge "$GENEROUS_THRESHOLD_SECS" ]; then
    echo "ok   - generous: $key ('$val') is at least 60 days — genuinely generous, not a tiny/default value"
  else
    echo "FAIL - generous: $key ('$val') is only ${span}s — expected at least ${GENEROUS_THRESHOLD_SECS}s (60 days)"
    fail=1
  fi
done

# =============================================================================
[ "$fail" -eq 0 ] && echo "ALL PASS" || echo "FAILURES"
exit "$fail"
