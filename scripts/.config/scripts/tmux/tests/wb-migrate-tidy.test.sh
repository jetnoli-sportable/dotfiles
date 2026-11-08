#!/usr/bin/env bash
# Tests for `wb migrate --tidy <task>|--all [--dry-run]` — the one-off repair
# of tasks that were ALREADY migrated to the dossier layout before `wb migrate`
# stopped repeating each `###` heading in a decision record's body and marking
# missing times as 0000 names: it moves a clipped title back to its full form,
# drops the repeated heading, adds `time: none` where the source had no time,
# and does nothing to a record that is not such a duplicate. All fixture text
# is made up.
#
# Run in the Docker sandbox (see tests/Dockerfile):
#   docker run --rm -v "$(pwd)":/repo:ro -w /repo wb-tests \
#     bash scripts/.config/scripts/tmux/tests/wb-migrate-tidy.test.sh
set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WB="$SELF_DIR/wb.sh"

FIXTURE="$(mktemp -d -t wb-tidy-fixture.XXXXXX)"
trap 'rm -rf "$FIXTURE"' EXIT

fail=0
assert() { # <desc> <expected-regex> <actual>
  if printf '%s' "$3" | grep -qE "$2"; then echo "ok   - $1"
  else echo "FAIL - $1"; echo "       expected match: $2"; echo "       got: $(printf '%s' "$3" | head -8)"; fail=1; fi
}
assert_not() { # <desc> <regex> <actual>
  if printf '%s' "$3" | grep -qE "$2"; then echo "FAIL - $1"; echo "       unexpected match: $2"; fail=1
  else echo "ok   - $1"; fi
}
assert_eq() { # <desc> <expected> <actual>
  if [ "$2" = "$3" ]; then echo "ok   - $1"
  else echo "FAIL - $1 (expected '$2', got '$3')"; fail=1; fi
}

export XDG_STATE_HOME="$FIXTURE/state"
export HOME="$FIXTURE/home"
export CODE_DIR="$FIXTURE/code"
export TASKS_DIR="$FIXTURE/tasks"
mkdir -p "$XDG_STATE_HOME" "$HOME" "$CODE_DIR" "$TASKS_DIR"

# shellcheck disable=SC1090
source "$WB"
source "$SELF_DIR/wb-migrate.sh"
set +e

store_sum() { (cd "$TASKS_DIR" && find . -type f | LC_ALL=C sort | xargs -r md5sum | md5sum | cut -d' ' -f1); }

LONGFULL='Adopt the shared queue for every worker, and retire the per-worker cron jobs, the lock files and the polling scripts entirely!'
LONGCLIP='Adopt the shared queue for every worker, and retire the per-worker cron jobs, the lock files and'

mk_layout_task() { # <stem> [layout-line]
  printf -- '---\nstatus: doing\nrepo: proj\nbranch: b\n%s\ntags: []\ncreated: 2026-10-01\nclosed:\n---\n# Title\n\n## Plan\n\nplan\n' "${2-layout: dossier}" > "$TASKS_DIR/$1.md"
  mkdir -p "$TASKS_DIR/dossiers/$1/decisions" "$TASKS_DIR/dossiers/$1/handoffs"
}
dec() { # <stem> <id> <title> <body-text>   (old migrate shape: heading kept in the body)
  printf -- '---\nstatus: in-force\nsupersedes: []\nsuperseded_by: []\nreview_at:\n---\n# %s\n\n%s\n' "$3" "$4" > "$TASKS_DIR/dossiers/$1/decisions/$2.md"
}
hand() { # <stem> <id> <source> <auto> <heading>
  printf -- '---\nsource: %s\nauto: %s\n---\n%s\n**Done:** something.\n' "$3" "$4" "$5" > "$TASKS_DIR/dossiers/$1/handoffs/$2.md"
}

S=proj--td; D="$TASKS_DIR/dossiers/$S"
mk_layout_task "$S"
dec "$S" 2026-10-18-0915-adopt-the-shared-queue "$LONGCLIP" "### 2026-10-18 09:15 — **$LONGFULL**

- Decided: one queue.
- Why: simpler."
dec "$S" 2026-10-20-0000-dated-heading-no-time "Dated heading, no time" "### 2026-10-20 — Dated heading, no time
- Decided: no time."
dec "$S" 2026-10-19-0830-timed "Timed" "### 2026-10-19 08:30 — Timed

- Decided: has a time."
dec "$S" 2026-10-21-1000-live "Live record" "- Decided: written by wb append, no heading."
dec "$S" 2026-10-22-1000-differs "Other title" "### 2026-10-22 10:00 — A completely different title

- Decided: x."
dec "$S" 2026-10-23-1000-notes "Notes" "### Notes
- a sub-heading that is not a dated heading."
dec "$S" 2026-10-24-1000-wrongdate "Wrong date" "### 2026-10-25 10:00 — Wrong date

- Decided: heading date differs from the file's."
dec "$S" 2026-10-26-1000-headonly "Heading only" "### 2026-10-26 10:00 — Heading only"
hand "$S" 2026-10-18-0000 "" false "### 2026-10-18 RESAVE — wb-save"
hand "$S" 2026-10-18-1700 wb-save false "### 2026-10-18 17:00 — wb-save"
hand "$S" 2026-10-02-0000 migrate true "### 2026-10-02 00:00 — migrate (auto)"
hand "$S" 2026-10-19-1432 "" false "### 2026-10-19 — wb-save"
mk_layout_task proj--old ""        # a task not on the layout, with a duplicate heading that must stay
dec proj--old 2026-10-18-0915-x "X" "### 2026-10-18 09:15 — X"
mk_layout_task proj--clean
dec proj--clean 2026-10-21-1000-live "Live record" "- Decided: nothing to do."
wb_render_views "$TASKS_DIR/$S.md"; wb_render_views "$TASKS_DIR/proj--clean.md"

# ---- dry run: reports, writes nothing --------------------------------------
sum0="$(store_sum)"
out="$(cmd_migrate --tidy --dry-run --all 2>&1)"; rc=$?
assert_eq "dry-run: exit 0" 0 "$rc"
assert_eq "dry-run: the store is byte-identical afterwards" "$sum0" "$(store_sum)"
assert "dry-run: counts the dropped headings (long, no-time, timed, heading-only)" 'headings dropped 4,' "$out"
assert "dry-run: counts the restored titles (the long one only)" 'titles restored 1,' "$out"
assert "dry-run: counts decisions given time: none (the dated heading without a time)" 'decisions time: none 1,' "$out"
assert "dry-run: counts handoffs given time: none (loose heading + the migrate history file)" 'handoffs time: none 2,' "$out"
assert "dry-run: counts records left alone (different title, sub-heading, wrong date)" 'left alone 3' "$out"
assert "dry-run: names the records it would change" 'decisions/2026-10-18-0915-adopt-the-shared-queue' "$out"
assert "dry-run: says nothing was written" 'dry run' "$out"
assert_not "dry-run: a non-layout task is not listed" 'proj--old +headings' "$out"

# ---- the real run ---------------------------------------------------------------
out="$(cmd_migrate --tidy proj--td 2>&1)"; rc=$?
assert_eq "tidy: exit 0" 0 "$rc"
long="$D/decisions/2026-10-18-0915-adopt-the-shared-queue.md"
assert_eq "tidy: the long title is on the # line in full" 1 "$(grep -cxF -- "# $LONGFULL" "$long")"
assert_eq "tidy: no ### line left in it" 0 "$(grep -c '^### ' "$long")"
assert "tidy: its bullets are untouched" '^- Why: simpler\.$' "$(cat "$long")"
assert_not "tidy: a timed heading gets no time field" '^time:' "$(cat "$long")"
expected_nt='---
status: in-force
supersedes: []
superseded_by: []
review_at:
time: none
---
# Dated heading, no time

- Decided: no time.'
assert_eq "tidy: the no-time record is exactly the new migrate shape" "$expected_nt" "$(cat "$D/decisions/2026-10-20-0000-dated-heading-no-time.md")"
expected_t='---
status: in-force
supersedes: []
superseded_by: []
review_at:
---
# Timed

- Decided: has a time.'
assert_eq "tidy: the timed record is exactly the new migrate shape" "$expected_t" "$(cat "$D/decisions/2026-10-19-0830-timed.md")"
assert_eq "tidy: a heading-only record keeps just its title" "# Heading only" "$(sed -n '/^---$/,/^---$/!p' "$D/decisions/2026-10-26-1000-headonly.md" | grep -v '^$')"
# untouched records
live_before='---
status: in-force
supersedes: []
superseded_by: []
review_at:
---
# Live record

- Decided: written by wb append, no heading.'
assert_eq "tidy: a record with no duplicate heading is left byte for byte" "$live_before" "$(cat "$D/decisions/2026-10-21-1000-live.md")"
assert "tidy: a heading with a different title is left (nothing may be lost)" '^### 2026-10-22 10:00 — A completely different title$' "$(cat "$D/decisions/2026-10-22-1000-differs.md")"
assert "tidy: a non-dated ### sub-heading is left" '^### Notes$' "$(cat "$D/decisions/2026-10-23-1000-notes.md")"
assert "tidy: a heading whose date differs from the file name is left" '^### 2026-10-25 10:00 — Wrong date$' "$(cat "$D/decisions/2026-10-24-1000-wrongdate.md")"
assert "tidy: a record under a non-layout task is left" '^### 2026-10-18 09:15 — X$' "$(cat "$TASKS_DIR/dossiers/proj--old/decisions/2026-10-18-0915-x.md")"
# handoffs
assert "tidy: loose-heading handoff gets time: none" '^time: none$' "$(cat "$D/handoffs/2026-10-18-0000.md")"
assert "tidy: its heading and text are untouched" '^### 2026-10-18 RESAVE — wb-save$' "$(cat "$D/handoffs/2026-10-18-0000.md")"
assert "tidy: the migrate history handoff gets time: none" '^time: none$' "$(cat "$D/handoffs/2026-10-02-0000.md")"
assert_not "tidy: a handoff with a real time is left" '^time:' "$(cat "$D/handoffs/2026-10-18-1700.md")"
assert_not "tidy: a handoff whose name time is not a 00NN sequence is left" '^time:' "$(cat "$D/handoffs/2026-10-19-1432.md")"
assert "tidy: handoffs view heads the no-time record with the date alone" '^## 2026-10-18$' "$(cat "$D/handoffs.md")"
assert "tidy: decisions view carries the full title" "^### $LONGFULL\$" "$(cat "$D/decisions.md")"
assert_not "tidy: decisions view no longer repeats the heading" '^### 2026-10-20 — ' "$(cat "$D/decisions.md")"

# ---- idempotent ------------------------------------------------------------------
sum1="$(store_sum)"
out="$(cmd_migrate --tidy --all 2>&1)"; rc=$?
assert_eq "second run: exit 0" 0 "$rc"
assert_eq "second run: the store is byte-identical" "$sum1" "$(store_sum)"
assert "second run: nothing to change" '0 changed' "$out"

# ---- help ----------------------------------------------------------------------
assert "wb help lists migrate --tidy" 'wb migrate --tidy' "$(cmd_help)"

# ---- errors and locks --------------------------------------------------------
out="$(cmd_migrate --tidy 2>&1)"; rc=$?
assert_eq "no target: exit 1" 1 "$rc"
assert "no target: usage mentions --tidy" 'usage: wb migrate' "$out"
out="$(cmd_migrate --tidy proj--old 2>&1)"; rc=$?
assert "a named non-layout task: one line, nothing changed" 'not on the dossier layout' "$out"
assert_eq "tidy leaves the non-layout task alone" "$sum1" "$(store_sum)"
# a held lock skips the task
dec "$S" 2026-10-27-1000-late "Late" "### 2026-10-27 10:00 — Late"
wb_task_lock_acquire_guarded "$TASKS_DIR/$S.md" >/dev/null 2>&1
out="$(bash -c 'source "$1"; source "$2"; set +e; cmd_migrate --tidy proj--td' _ "$WB" "$SELF_DIR/wb-migrate.sh" 2>&1)"; rc=$?
wb_task_lock_release "$TASKS_DIR/$S.md" >/dev/null 2>&1
assert "held lock: reported as skipped" 'SKIPPED, lock held' "$out"
assert "held lock: the record was not touched" '^### 2026-10-27 10:00 — Late$' "$(cat "$D/decisions/2026-10-27-1000-late.md")"
out="$(cmd_migrate --tidy proj--td 2>&1)"
assert_eq "after the lock is free the record is tidied" 0 "$(grep -c '^### ' "$D/decisions/2026-10-27-1000-late.md")"

echo
[ "$fail" -eq 0 ] && echo "ALL PASS" || echo "FAILURES"
exit "$fail"
