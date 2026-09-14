#!/usr/bin/env bash
# Tests for `wb set` (cmd_set) — set one board-metadata frontmatter field on
# a STORE-ONLY task, under the per-task lock, via the shared
# wb_set_frontmatter_field rewrite core also used by `wb status`. Same
# fixture/harness convention as wb-status.test.sh (fixture TASKS_DIR, source
# wb.sh, set +e to capture non-zero exits, a real throwaway tmux session for
# the live-session-refusal scenario).
# Run: bash scripts/.config/scripts/tmux/tests/wb-set.test.sh
set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WB="$SELF_DIR/wb.sh"

FIXTURE="$(mktemp -d -t wb-set-fixture.XXXXXX)"
SESSION="wb-set-test-$$"
trap 'rm -rf "$FIXTURE"; tmux kill-session -t "=$SESSION" 2>/dev/null || true' EXIT

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
assert_eq() { # <desc> <expected> <actual>
  if [ "$2" = "$3" ]; then
    echo "ok   - $1"
  else
    echo "FAIL - $1 (expected '$2', got '$3')"
    fail=1
  fi
}

export XDG_STATE_HOME="$FIXTURE/state"
export HOME="$FIXTURE/home"
export CODE_DIR="$FIXTURE/code"
export TASKS_DIR="$FIXTURE/tasks"
mkdir -p "$XDG_STATE_HOME" "$HOME" "$CODE_DIR" "$TASKS_DIR"

# shellcheck disable=SC1090
source "$WB"
set +e   # wb.sh sets -e; this suite intentionally captures non-zero exits

mk_task() { # <file> <branch> [extra frontmatter lines...]
  local f="$TASKS_DIR/$1" branch="$2"
  shift 2
  {
    printf -- '---\nstatus: doing\nrepo: proj\nbranch: %s\nworktree: .worktrees/%s\nsize:\ntags: []\ncreated: 2026-07-01\nclosed:\n' \
      "$branch" "$branch"
    local extra
    for extra in "$@"; do printf '%s\n' "$extra"; done
    printf -- '---\n# Title\n'
  } > "$f"
}

# =============================================================================
# Scenario: set priority — valid value.
# =============================================================================

mk_task "proj--set-a.md" set-a
out="$(cmd_set "set-a" priority P1 2>&1)"; rc=$?
assert_eq "priority valid: exit 0" 0 "$rc"
assert "priority valid: confirmation" "proj--set-a\.md priority '' -> 'P1'" "$out"
content="$(cat "$TASKS_DIR/proj--set-a.md")"
assert "priority valid: frontmatter updated" '^priority: P1$' "$content"
after_size="$(printf '%s\n' "$content" | grep -A1 '^size:$' | tail -1)"
assert_eq "priority valid: inserted right after size:" "priority: P1" "$after_size"
if printf '%s' "$content" | grep -q '## Handoffs'; then
  echo "FAIL - priority valid: no Handoffs entry should be appended (noise field)"; fail=1
else
  echo "ok   - priority valid: no Handoffs entry appended"
fi

# =============================================================================
# Scenario: set priority — invalid value.
# =============================================================================

mk_task "proj--set-b.md" set-b
out="$(cmd_set "set-b" priority bogus 2>&1)"; rc=$?
assert_eq "priority invalid: exit 1" 1 "$rc"
assert "priority invalid: message" "not one of P1\|P2\|P3" "$out"
content="$(cat "$TASKS_DIR/proj--set-b.md")"
if printf '%s' "$content" | grep -q '^priority:'; then
  echo "FAIL - priority invalid: no priority: line should have been written"; fail=1
else
  echo "ok   - priority invalid: file untouched"
fi

# =============================================================================
# Scenario: set value — valid + invalid.
# =============================================================================

mk_task "proj--set-c.md" set-c
out="$(cmd_set "set-c" value high 2>&1)"; rc=$?
assert_eq "value valid: exit 0" 0 "$rc"
content="$(cat "$TASKS_DIR/proj--set-c.md")"
assert "value valid: frontmatter updated" '^value: high$' "$content"

out="$(cmd_set "set-c" value bogus 2>&1)"; rc=$?
assert_eq "value invalid: exit 1" 1 "$rc"
assert "value invalid: message" "not one of high\|med\|low" "$out"

# =============================================================================
# Scenario: insert-when-missing — a field absent from the file entirely
# (e.g. `jira:`, which mk_task above never seeds) gets inserted, not
# refused.
# =============================================================================

mk_task "proj--set-d.md" set-d
content_before="$(cat "$TASKS_DIR/proj--set-d.md")"
if printf '%s' "$content_before" | grep -q '^jira:'; then
  echo "FAIL - insert-when-missing setup: fixture unexpectedly already has jira:"; fail=1
fi
out="$(cmd_set "set-d" jira https://example.atlassian.net/browse/SFB-1 2>&1)"; rc=$?
assert_eq "insert-when-missing: exit 0" 0 "$rc"
content="$(cat "$TASKS_DIR/proj--set-d.md")"
assert "insert-when-missing: jira line inserted" '^jira: https://example\.atlassian\.net/browse/SFB-1$' "$content"

# =============================================================================
# Scenario: parent must name an existing task file.
# =============================================================================

mk_task "proj--set-e.md" set-e
mk_task "proj--set-parent.md" set-parent
out="$(cmd_set "set-e" parent proj--set-parent 2>&1)"; rc=$?
assert_eq "parent exists: exit 0" 0 "$rc"
content="$(cat "$TASKS_DIR/proj--set-e.md")"
assert "parent exists: frontmatter updated" '^parent: proj--set-parent$' "$content"
assert "parent exists: Handoffs entry appended (structural)" 'wb set \(auto\)' "$content"

out="$(cmd_set "set-e" parent proj--nonexistent 2>&1)"; rc=$?
assert_eq "parent missing: exit 1" 1 "$rc"
assert "parent missing: message" "has no matching task file" "$out"

# =============================================================================
# Scenario: depends_on — comma-separated list, each validated.
# =============================================================================

mk_task "proj--set-f.md" set-f
mk_task "proj--set-dep1.md" set-dep1
mk_task "proj--set-dep2.md" set-dep2
out="$(cmd_set "set-f" depends_on "proj--set-dep1,proj--set-dep2" 2>&1)"; rc=$?
assert_eq "depends_on valid list: exit 0" 0 "$rc"
content="$(cat "$TASKS_DIR/proj--set-f.md")"
assert "depends_on valid list: frontmatter updated" '^depends_on: proj--set-dep1,proj--set-dep2$' "$content"
assert "depends_on valid list: Handoffs entry appended (structural)" 'wb set \(auto\)' "$content"

mk_task "proj--set-g.md" set-g
out="$(cmd_set "set-g" depends_on "proj--set-dep1,proj--nonexistent" 2>&1)"; rc=$?
assert_eq "depends_on invalid entry: exit 1" 1 "$rc"
assert "depends_on invalid entry: message" "has no matching task file" "$out"
content="$(cat "$TASKS_DIR/proj--set-g.md")"
if printf '%s' "$content" | grep -q '^depends_on: proj'; then
  echo "FAIL - depends_on invalid entry: no partial write should have landed"; fail=1
else
  echo "ok   - depends_on invalid entry: file untouched"
fi

# =============================================================================
# Scenario: refuses status (points at wb status/wb done) and other
# tooling-owned/unknown fields.
# =============================================================================

mk_task "proj--set-h.md" set-h
out="$(cmd_set "set-h" status doing 2>&1)"; rc=$?
assert_eq "refuses status: exit 1" 1 "$rc"
assert "refuses status: points at wb status/wb done" 'wb status.*wb done' "$out"

out="$(cmd_set "set-h" created 2026-01-01 2>&1)"; rc=$?
assert_eq "refuses created: exit 1" 1 "$rc"
assert "refuses created: message" "not settable via" "$out"

out="$(cmd_set "set-h" bogus-field foo 2>&1)"; rc=$?
assert_eq "refuses unknown field: exit 1" 1 "$rc"
assert "refuses unknown field: message" "unknown field" "$out"

# =============================================================================
# Scenario: no-op when unchanged.
# =============================================================================

mk_task "proj--set-i.md" set-i "priority: P2"
before_mtime="$(stat -c %Y "$TASKS_DIR/proj--set-i.md" 2>/dev/null || stat -f %m "$TASKS_DIR/proj--set-i.md")"
sleep 1
out="$(cmd_set "set-i" priority P2 2>&1)"; rc=$?
assert_eq "no-op: exit 0" 0 "$rc"
assert "no-op: message says already" "already 'P2'" "$out"
after_mtime="$(stat -c %Y "$TASKS_DIR/proj--set-i.md" 2>/dev/null || stat -f %m "$TASKS_DIR/proj--set-i.md")"
assert_eq "no-op: file not rewritten (mtime unchanged)" "$before_mtime" "$after_mtime"

# =============================================================================
# Scenario: structural vs noise Handoffs — priority/value/size/tags changes
# append no Handoffs entry (covered above for priority; spot-check size and
# tags here), while jira (structural) does.
# =============================================================================

mk_task "proj--set-j.md" set-j
out="$(cmd_set "set-j" size M 2>&1)"; rc=$?
assert_eq "size noise: exit 0" 0 "$rc"
content="$(cat "$TASKS_DIR/proj--set-j.md")"
if printf '%s' "$content" | grep -q '## Handoffs'; then
  echo "FAIL - size noise: no Handoffs entry should be appended"; fail=1
else
  echo "ok   - size noise: no Handoffs entry appended"
fi

out="$(cmd_set "set-j" tags "foo,bar" 2>&1)"; rc=$?
assert_eq "tags noise: exit 0" 0 "$rc"
content="$(cat "$TASKS_DIR/proj--set-j.md")"
if printf '%s' "$content" | grep -q '## Handoffs'; then
  echo "FAIL - tags noise: no Handoffs entry should be appended"; fail=1
else
  echo "ok   - tags noise: no Handoffs entry appended"
fi

out="$(cmd_set "set-j" jira "https://example.atlassian.net/browse/SFB-2" 2>&1)"; rc=$?
assert_eq "jira structural: exit 0" 0 "$rc"
content="$(cat "$TASKS_DIR/proj--set-j.md")"
assert "jira structural: Handoffs entry appended" 'wb set \(auto\)' "$content"

# jira must start with https://
out="$(cmd_set "set-j" jira "http://example.com" 2>&1)"; rc=$?
assert_eq "jira invalid scheme: exit 1" 1 "$rc"
assert "jira invalid scheme: message" "must start with https://" "$out"

# =============================================================================
# Scenario: wb_set_frontmatter_field / cmd_set dedupe regression — a
# TEMPLATE.md-shaped file already ships an empty `priority:`/`value:` line
# right after `size:`. The `after_key=size` insertion path must not fire
# just because it walks past `size:` before reaching that existing (empty,
# further-down-in-source-order-wise-adjacent) line — it must REPLACE the
# existing line, never insert a second one.
# =============================================================================

mk_template_task() { # <file> <branch> — TEMPLATE.md's own frontmatter field
  # order, with priority:/value: already present (empty) right after size:,
  # same shape as a freshly `wb new`-created task file.
  local f="$TASKS_DIR/$1" branch="$2"
  printf -- '---\nstatus: doing\npath:\nrepo: proj\nbranch: %s\nworktree: .worktrees/%s\nparent:\ndepends_on:\nsize:\npriority:\nvalue:\ntags: []\njira:\ncreated: 2026-07-01\nclosed:\nreviewed:\nclaude_sessions:\n---\n# Title\n' \
    "$branch" "$branch" > "$f"
}

# (a) set on a template that already has the empty key -> exactly one
# priority: line afterward, holding the new value.
mk_template_task "proj--set-tmpl.md" set-tmpl
out="$(cmd_set "set-tmpl" priority P3 2>&1)"; rc=$?
assert_eq "template dedupe: exit 0" 0 "$rc"
content="$(cat "$TASKS_DIR/proj--set-tmpl.md")"
count="$(printf '%s\n' "$content" | grep -c '^priority:')"
assert_eq "template dedupe: exactly one priority: line" "1" "$count"
assert "template dedupe: it holds the new value" '^priority: P3$' "$content"

# (b) a file with a pre-existing duplicate -> after set, exactly one line
# with the new value.
{
  printf -- '---\nstatus: doing\nrepo: proj\nbranch: set-dup\nworktree: .worktrees/set-dup\n'
  printf -- 'size:\npriority: P1\npriority:\nvalue:\ntags: []\ncreated: 2026-07-01\nclosed:\n'
  printf -- '---\n# Title\n'
} > "$TASKS_DIR/proj--set-dup.md"
out="$(cmd_set "set-dup" priority P2 2>&1)"; rc=$?
assert_eq "pre-existing duplicate: exit 0" 0 "$rc"
content="$(cat "$TASKS_DIR/proj--set-dup.md")"
count="$(printf '%s\n' "$content" | grep -c '^priority:')"
assert_eq "pre-existing duplicate: exactly one priority: line" "1" "$count"
assert "pre-existing duplicate: it holds the new value" '^priority: P2$' "$content"

# (c) re-running set with the SAME value on a duplicated file repairs it —
# must not be treated as a no-op even though the first occurrence already
# matches.
{
  printf -- '---\nstatus: doing\nrepo: proj\nbranch: set-dup2\nworktree: .worktrees/set-dup2\n'
  printf -- 'size:\npriority: P1\npriority:\nvalue:\ntags: []\ncreated: 2026-07-01\nclosed:\n'
  printf -- '---\n# Title\n'
} > "$TASKS_DIR/proj--set-dup2.md"
out="$(cmd_set "set-dup2" priority P1 2>&1)"; rc=$?
assert_eq "same-value repair: exit 0" 0 "$rc"
if printf '%s' "$out" | grep -q 'already'; then
  echo "FAIL - same-value repair: must not short-circuit as a no-op"; fail=1
else
  echo "ok   - same-value repair: did not short-circuit as a no-op"
fi
content="$(cat "$TASKS_DIR/proj--set-dup2.md")"
count="$(printf '%s\n' "$content" | grep -c '^priority:')"
assert_eq "same-value repair: exactly one priority: line" "1" "$count"
assert "same-value repair: it holds the value" '^priority: P1$' "$content"

# =============================================================================
# Scenario: refuses when a LIVE tmux session's @task points at the resolved
# file. Skipped if this harness has no usable tmux server.
# =============================================================================

if tmux new-session -d -s "$SESSION" 2>/dev/null; then
  mk_task "proj--set-live.md" set-live
  LIVE_FILE="$TASKS_DIR/proj--set-live.md"
  tmux set-option -t "=$SESSION:" @task "$LIVE_FILE" >/dev/null

  out="$(cmd_set "set-live" priority P1 2>&1)"; rc=$?
  assert_eq "live session refusal: exit 1" 1 "$rc"
  assert "live session refusal: names the live session" "has a live session $SESSION" "$out"
  content="$(cat "$LIVE_FILE")"
  if printf '%s' "$content" | grep -q '^priority: P1'; then
    echo "FAIL - live session refusal: priority should not have been written"; fail=1
  else
    echo "ok   - live session refusal: file untouched"
  fi

  tmux kill-session -t "=$SESSION" 2>/dev/null
else
  echo "skip - live session refusal: no usable tmux server in this harness"
fi

[ "$fail" -eq 0 ] && echo "ALL PASS" || echo "FAILURES"
exit "$fail"
