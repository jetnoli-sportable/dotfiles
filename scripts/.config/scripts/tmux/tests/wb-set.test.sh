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
# Scenario: free-text fields refuse values that cannot round-trip through a
# one-line frontmatter field (embedded newline; whitespace+'#' comment start).
# =============================================================================

mk_task "proj--set-nl.md" set-nl
out="$(cmd_set "set-nl" tags $'action-live\nstatus: done' 2>&1)"; rc=$?
assert_eq "tags with embedded newline: exit 1" 1 "$rc"
assert "tags with embedded newline: message" "must be a single line" "$out"
content="$(cat "$TASKS_DIR/proj--set-nl.md")"
if printf '%s' "$content" | grep -q '^status: done$'; then
  echo "FAIL - tags newline: injected status line landed"; fail=1
else
  echo "ok   - tags newline: no injected frontmatter line"
fi

mk_task "proj--set-hash.md" set-hash
out="$(cmd_set "set-hash" path "plan #1,work" 2>&1)"; rc=$?
assert_eq "path with whitespace-#: exit 1" 1 "$rc"
assert "path with whitespace-#: message" "whitespace followed by '#'" "$out"
content="$(cat "$TASKS_DIR/proj--set-hash.md")"
if printf '%s' "$content" | grep -q '^path: plan'; then
  echo "FAIL - path hash: value should not have been written"; fail=1
else
  echo "ok   - path hash: file untouched"
fi

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

# =============================================================================
# Scenario: R26 canonical `tags:` — list form, idempotent across input
# shapes, additive (merges rather than clobbers, no duplicates), and the
# migration path (re-running against a bare-scalar file normalizes it).
# =============================================================================

# Idempotent across input shapes: comma, comma-space, and already-bracketed
# all produce the identical canonical `[a, b]` result on a fresh field.
mk_task "proj--tags-shape-a.md" tags-shape-a
cmd_set "tags-shape-a" tags "a,b" >/dev/null 2>&1
assert_eq "tags shape 'a,b': canonical list form" "[a, b]" \
  "$(wb_get_frontmatter "$TASKS_DIR/proj--tags-shape-a.md" tags)"

mk_task "proj--tags-shape-b.md" tags-shape-b
cmd_set "tags-shape-b" tags "a, b" >/dev/null 2>&1
assert_eq "tags shape 'a, b': canonical list form" "[a, b]" \
  "$(wb_get_frontmatter "$TASKS_DIR/proj--tags-shape-b.md" tags)"

mk_task "proj--tags-shape-c.md" tags-shape-c
cmd_set "tags-shape-c" tags "[a, b]" >/dev/null 2>&1
assert_eq "tags shape '[a, b]': canonical list form" "[a, b]" \
  "$(wb_get_frontmatter "$TASKS_DIR/proj--tags-shape-c.md" tags)"

# Additive: setting tags on a file that already has a list merges rather
# than clobbers, and does not duplicate an existing tag.
mk_task "proj--tags-merge.md" tags-merge
cmd_set "tags-merge" tags "a,b" >/dev/null 2>&1
cmd_set "tags-merge" tags "b,c" >/dev/null 2>&1
assert_eq "tags merge: union, no duplicate, existing order preserved" "[a, b, c]" \
  "$(wb_get_frontmatter "$TASKS_DIR/proj--tags-merge.md" tags)"

# --unset still clears the field outright (regression on the just-shipped
# behaviour — merge must never apply on the clearing path).
mk_task "proj--tags-unset.md" tags-unset
cmd_set "tags-unset" tags "a,b" >/dev/null 2>&1
out="$(cmd_set "tags-unset" tags --unset 2>&1)"; rc=$?
assert_eq "tags --unset: exit 0" 0 "$rc"
assert_eq "tags --unset: field cleared, not merged" "" \
  "$(wb_get_frontmatter "$TASKS_DIR/proj--tags-unset.md" tags)"

# A tag value containing whitespace-then-'#' is still refused by the shared
# frontmatter validator (same guard as every other field).
mk_task "proj--tags-hash.md" tags-hash
out="$(cmd_set "tags-hash" tags "plan #1,work" 2>&1)"; rc=$?
assert_eq "tags whitespace-#: exit 1" 1 "$rc"
assert "tags whitespace-#: message" "whitespace followed by '#'" "$out"

# Migration path: re-running `wb set tags` against a pre-existing
# bare-scalar `tags: action-live` file with the SAME value normalizes it
# into canonical list form.
mk_task "proj--tags-migrate.md" tags-migrate
sed -i 's/^tags: \[\]$/tags: action-live/' "$TASKS_DIR/proj--tags-migrate.md"
cmd_set "tags-migrate" tags "action-live" >/dev/null 2>&1
assert_eq "tags migration: bare scalar normalized to list form" "[action-live]" \
  "$(wb_get_frontmatter "$TASKS_DIR/proj--tags-migrate.md" tags)"

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
# Scenario: --unset clears a structural field. This is the case the flag was
# added for: parent's validation requires the value to name an existing task
# file, so before --unset there was no way to UN-parent a task through the
# locked path at all (hit 2026-09-15 retiring a date-named skills umbrella).
# =============================================================================

mk_task "proj--unset-parent.md" unset-parent
mk_task "proj--unset-mum.md" unset-mum
cmd_set "unset-parent" parent "proj--unset-mum" >/dev/null 2>&1
out="$(cmd_set "unset-parent" parent --unset 2>&1)"; rc=$?
assert_eq "--unset parent: exit 0" 0 "$rc"
assert "--unset parent: confirmation says cleared" "parent 'proj--unset-mum' -> \\(cleared\\)" "$out"
content="$(cat "$TASKS_DIR/proj--unset-parent.md")"
assert "--unset parent: frontmatter value is empty" '^parent:[[:space:]]*$' "$content"
assert "--unset parent: Handoffs records the clear" 'cleared via .wb set --unset.' "$content"

# =============================================================================
# Scenario: --unset on a noise field writes no Handoffs entry, matching the
# same signal-over-noise split cmd_set already applies to real values.
# =============================================================================

mk_task "proj--unset-prio.md" unset-prio
cmd_set "unset-prio" priority P1 >/dev/null 2>&1
out="$(cmd_set "unset-prio" priority --unset 2>&1)"; rc=$?
assert_eq "--unset priority: exit 0" 0 "$rc"
content="$(cat "$TASKS_DIR/proj--unset-prio.md")"
assert "--unset priority: frontmatter value is empty" '^priority:[[:space:]]*$' "$content"
if printf '%s' "$content" | grep -q '## Handoffs'; then
  echo "FAIL - --unset priority: no Handoffs entry should be appended (noise field)"; fail=1
else
  echo "ok   - --unset priority: no Handoffs entry appended"
fi

# =============================================================================
# Scenario: --unset on an already-empty field is a no-op, and says so.
# =============================================================================

mk_task "proj--unset-noop.md" unset-noop "parent:"
before="$(cat "$TASKS_DIR/proj--unset-noop.md")"
out="$(cmd_set "unset-noop" parent --unset 2>&1)"; rc=$?
assert_eq "--unset no-op: exit 0" 0 "$rc"
assert "--unset no-op: says already empty" "parent already empty" "$out"
assert_eq "--unset no-op: file untouched" "$before" "$(cat "$TASKS_DIR/proj--unset-noop.md")"

# =============================================================================
# Scenario: --unset on a field whose key is MISSING entirely materialises it
# as an empty line (the schema-backfill path: every optional key present,
# value blank). Nothing semantically changed, so no Handoffs entry even for
# a structural field.
# =============================================================================

mk_task "proj--unset-missing.md" unset-missing
out="$(cmd_set "unset-missing" depends_on --unset 2>&1)"; rc=$?
assert_eq "--unset missing key: exit 0" 0 "$rc"
assert "--unset missing key: says key added" "depends_on: key added \\(empty\\)" "$out"
content="$(cat "$TASKS_DIR/proj--unset-missing.md")"
assert "--unset missing key: empty key line inserted" '^depends_on:[[:space:]]*$' "$content"
assert_eq "--unset missing key: exactly one key line" 1 \
  "$(grep -c '^depends_on:' "$TASKS_DIR/proj--unset-missing.md")"
if printf '%s' "$content" | grep -q 'wb set (auto)'; then
  echo "FAIL - --unset missing key: no Handoffs entry should be appended (value unchanged)"; fail=1
else
  echo "ok   - --unset missing key: no Handoffs entry appended"
fi
out="$(cmd_set "unset-missing" depends_on --unset 2>&1)"
assert "--unset missing key: second run is the plain no-op" "depends_on already empty" "$out"

# =============================================================================
# Scenario: size accepts XS; the enum stays strict uppercase and the error
# lists every legal value.
# =============================================================================

mk_task "proj--size-xs.md" size-xs
out="$(cmd_set "size-xs" size XS 2>&1)"; rc=$?
assert_eq "size XS: exit 0" 0 "$rc"
assert "size XS: frontmatter written" '^size: XS$' "$(cat "$TASKS_DIR/proj--size-xs.md")"
out="$(cmd_set "size-xs" size xs 2>&1)"; rc=$?
assert_eq "size xs (lowercase): exit 1" 1 "$rc"
assert "size xs (lowercase): error lists the enum" "size 'xs' is not one of XS\\|S\\|M\\|L\\|XL" "$out"

# =============================================================================
# Scenario: an empty value behaves exactly like --unset (so a caller passing
# "" doesn't hit the enum/existence validation either).
# =============================================================================

mk_task "proj--unset-empty.md" unset-empty
cmd_set "unset-empty" size L >/dev/null 2>&1
out="$(cmd_set "unset-empty" size "" 2>&1)"; rc=$?
assert_eq "empty value: exit 0" 0 "$rc"
content="$(cat "$TASKS_DIR/proj--unset-empty.md")"
assert "empty value: frontmatter cleared" '^size:[[:space:]]*$' "$content"

# =============================================================================
# Scenario: REGRESSION — --unset must not weaken validation of real values.
# =============================================================================

mk_task "proj--unset-guard.md" unset-guard
out="$(cmd_set "unset-guard" parent "proj--does-not-exist" 2>&1)"; rc=$?
assert_eq "real value still validated: exit 1" 1 "$rc"
assert "real value still validated: message" "has no matching task file" "$out"
out="$(cmd_set "unset-guard" priority bogus 2>&1)"; rc=$?
assert_eq "real enum still validated: exit 1" 1 "$rc"
out="$(cmd_set "unset-guard" bogusfield --unset 2>&1)"; rc=$?
assert_eq "--unset on unknown field still refused: exit 1" 1 "$rc"
assert "--unset on unknown field: message" "unknown field" "$out"

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
