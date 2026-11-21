#!/usr/bin/env bash
# Tests for `wb decision` (wb-decide.sh): recording an answer in a task's
# Decisions with supersede-by-title, identical-body no-op, "default taken"
# records that never override Jet's answer, and the lock.
#
# Run: bash scripts/.config/scripts/tmux/tests/wb-decision.test.sh
set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WB="$SELF_DIR/wb.sh"

FIX="$(mktemp -d -t wb-decision-fixture.XXXXXX)"
HOLDER=""
# shellcheck disable=SC2329  # runs from the EXIT trap
cleanup() {
  [ -z "$HOLDER" ] || kill "$HOLDER" 2>/dev/null
  rm -rf "$FIX"
}
trap cleanup EXIT

export HOME="$FIX/home" XDG_STATE_HOME="$FIX/state" CODE_DIR="$FIX/code" TASKS_DIR="$FIX/tasks"
mkdir -p "$HOME" "$XDG_STATE_HOME" "$CODE_DIR" "$TASKS_DIR"
unset TMUX TMUX_PANE

fail=0
assert() { # <desc> <expected-regex> <actual>
  if printf '%s' "$3" | grep -qE "$2"; then echo "ok   - $1"
  else echo "FAIL - $1"; echo "       expected match: $2"; echo "       got: $(printf '%s' "$3" | head -8)"; fail=1; fi
}
assert_not() { # <desc> <regex> <actual>
  if printf '%s' "$3" | grep -qE "$2"; then echo "FAIL - $1"; echo "       unexpected match: $2"; echo "       got: $(printf '%s' "$3" | head -8)"; fail=1
  else echo "ok   - $1"; fi
}
assert_eq() { # <desc> <expected> <actual>
  if [ "$2" = "$3" ]; then echo "ok   - $1"
  else echo "FAIL - $1 (expected '$2', got '$3')"; fail=1; fi
}

mk_task() { # <stem> [layout line]
  { printf -- '---\nstatus: doing\nrepo: proj\nbranch: b\n'
    [ -z "${2:-}" ] || printf '%s\n' "$2"
    printf 'tags: []\ncreated: 2026-07-01\nclosed:\n---\n# Title\n\n## Plan\n\nplan text\n\n## Follow-ups\n\n## Decisions\n'
  } > "$TASKS_DIR/$1.md"
}
decision() { # <task> <args…> — body on stdin
  local t="$1"; shift
  bash "$WB" decision --task "$t" "$@" 2>&1
}
files() { ls "$TASKS_DIR/dossiers/$1/decisions" 2>/dev/null | sort; }
nth() { files "$1" | sed -n "${2}p"; }
fm() { sed -n "s/^$3: //p" "$TASKS_DIR/dossiers/$1/decisions/$2" | head -1; }
id_of() { local f; f="$(nth "$1" "$2")"; printf '%s' "${f%.md}"; }

# A first record: one decisions/ file, in force, the title on its # line once.
mk_task proj--dec-a "layout: dossier"
out="$(printf 'Keep it as is.\nBecause it works.\n' | decision proj--dec-a "Fixture format")"; rc=$?
assert_eq "first record: exit 0" 0 "$rc"
assert_eq "first record: one decisions file" 1 "$(files proj--dec-a | wc -l | tr -d ' ')"
F1="$(nth proj--dec-a 1)"
assert "first record: names the new id and the task" "wb decision: wrote ${F1%.md} in proj--dec-a.md" "$out"
assert_not "first record: supersedes nothing" 'supersedes ' "$out"
assert_eq "first record: status in-force" "in-force" "$(fm proj--dec-a "$F1" status)"
c="$(cat "$TASKS_DIR/dossiers/proj--dec-a/decisions/$F1")"
assert "first record: title on the # line" '^# Fixture format$' "$c"
assert_eq "first record: title appears once" 1 "$(printf '%s\n' "$c" | grep -c 'Fixture format')"
assert "first record: body kept" '^Because it works\.$' "$c"
assert_not "task file gained no entry under ## Decisions" 'Fixture format' "$(cat "$TASKS_DIR/proj--dec-a.md")"

# AE4: a second record with the same title supersedes the first.
sleep 1  # ids carry HHMM; the -2 suffix keeps them distinct within a minute
out="$(printf 'Use JSON instead.\n' | decision proj--dec-a "Fixture format")"
assert_eq "second record: two files" 2 "$(files proj--dec-a | wc -l | tr -d ' ')"
NEW2=""
for f in $(files proj--dec-a); do [ "$f" = "$F1" ] || NEW2="$f"; done
assert_eq "second record: old one is superseded" "superseded" "$(fm proj--dec-a "$F1" status)"
assert_eq "second record: old one points at the new one" "[${NEW2%.md}]" "$(fm proj--dec-a "$F1" superseded_by)"
assert_eq "second record: new one supersedes the old one" "[${F1%.md}]" "$(fm proj--dec-a "$NEW2" supersedes)"
assert_eq "second record: new one is in force" "in-force" "$(fm proj--dec-a "$NEW2" status)"
assert "supersede is reported by id and title" "supersedes ${F1%.md} \"Fixture format\"" "$out"

# A third record supersedes the second, not the first.
out="$(printf 'Back to markdown.\n' | decision proj--dec-a "Fixture format")"
NEW3=""
for f in $(files proj--dec-a); do [ "$f" = "$F1" ] || [ "$f" = "$NEW2" ] || NEW3="$f"; done
assert_eq "third record: three files" 3 "$(files proj--dec-a | wc -l | tr -d ' ')"
assert_eq "third record: second is superseded" "superseded" "$(fm proj--dec-a "$NEW2" status)"
assert_eq "third record: it supersedes the second only" "[${NEW2%.md}]" "$(fm proj--dec-a "$NEW3" supersedes)"
assert_eq "third record: first stays superseded by the second" "[${NEW2%.md}]" "$(fm proj--dec-a "$F1" superseded_by)"
assert "third record: reports the second" "supersedes ${NEW2%.md} \"Fixture format\"" "$out"
assert_not "third record: does not name the first" "${F1%.md}[^-0-9]" "$out"

# An identical body writes nothing.
before="$(files proj--dec-a)"
out="$(printf 'Back to markdown.\n' | decision proj--dec-a "Fixture format")"; rc=$?
assert_eq "identical body: exit 0" 0 "$rc"
assert "identical body: says unchanged and names the record" "wb decision: unchanged — ${NEW3%.md} already says this" "$out"
assert_eq "identical body: nothing written" "$before" "$(files proj--dec-a)"
out="$(printf '\nBack to markdown.\n\n' | decision proj--dec-a "Fixture format  ")"
assert "identical body, padded: still unchanged (title trailing space trimmed)" 'unchanged' "$out"

# Title matching: trailing space matches, a different case does not.
out="$(printf 'Other body.\n' | decision proj--dec-a "Fixture format ")"
assert "trailing space on the title matches the live entry" 'supersedes ' "$out"
n_before="$(files proj--dec-a | wc -l | tr -d ' ')"
out="$(printf 'Other body.\n' | decision proj--dec-a "fixture format")"
assert_not "different case does not match" 'supersedes ' "$out"
assert_eq "different case writes a separate record" "$((n_before + 1))" "$(files proj--dec-a | wc -l | tr -d ' ')"

# --default never supersedes an answer Jet gave.
mk_task proj--dec-b "layout: dossier"
printf 'md.\n' | decision proj--dec-b "Pick format" >/dev/null
A1="$(id_of proj--dec-b 1)"
out="$(printf 'json.\n' | decision proj--dec-b --default "Pick format")"
assert_eq "default over an answer: new entry written" 2 "$(files proj--dec-b | wc -l | tr -d ' ')"
assert_eq "default over an answer: the answer stays in force" "in-force" "$(fm proj--dec-b "$A1.md" status)"
D1=""
for f in $(files proj--dec-b); do [ "$f" = "$A1.md" ] || D1="$f"; done
assert "default over an answer: new entry names the answer" "$A1" "$(cat "$TASKS_DIR/dossiers/proj--dec-b/decisions/$D1")"
assert "default over an answer: new entry marked Default taken." '^Default taken\.$' "$(cat "$TASKS_DIR/dossiers/proj--dec-b/decisions/$D1")"
assert_eq "default over an answer: supersedes nothing" "[]" "$(fm proj--dec-b "$D1" supersedes)"
assert "default over an answer: output says the answer stands" "$A1" "$out"
# and a default over a default supersedes it normally
mk_task proj--dec-c "layout: dossier"
printf 'one.\n' | decision proj--dec-c --default "Pick colour" >/dev/null
C1="$(id_of proj--dec-c 1)"
out="$(printf 'two.\n' | decision proj--dec-c --default "Pick colour")"
assert_eq "default over a default: old one superseded" "superseded" "$(fm proj--dec-c "$C1.md" status)"
assert "default over a default: reported" "supersedes $C1 \"Pick colour\"" "$out"
# a later answer from Jet supersedes the default
out="$(printf 'three.\n' | decision proj--dec-c "Pick colour")"
live=0; for f in $(files proj--dec-c); do [ "$(fm proj--dec-c "$f" status)" = in-force ] && live=$((live + 1)); done
assert_eq "answer after defaults: exactly one entry in force" 1 "$live"

# An answer after default + answer leaves nothing stale in force.
out="$(printf 'changed my mind.\n' | decision proj--dec-b "Pick format")"
live=0; for f in $(files proj--dec-b); do [ "$(fm proj--dec-b "$f" status)" = in-force ] && live=$((live + 1)); done
assert_eq "answer after answer + default: exactly one entry in force" 1 "$live"
# That answer superseded two live records (the first answer and the default): it lists
# both in supersedes: and the output reports both.
M="$(for f in $(files proj--dec-b); do [ "$(fm proj--dec-b "$f" status)" = in-force ] && echo "$f"; done)"
assert_eq "multi-supersede: the new record lists both older ids" "[${D1%.md}, $A1]" "$(fm proj--dec-b "$M" supersedes)"
assert "multi-supersede: output reports both, newest first" "supersedes ${D1%.md} \"Pick format\", $A1 \"Pick format\"\)" "$out"
assert_eq "multi-supersede: both older records point at the new one" "[${M%.md}] [${M%.md}]" \
  "$(fm proj--dec-b "$A1.md" superseded_by) $(fm proj--dec-b "$D1" superseded_by)"

# Two rounds of one batch keep both.
mk_task proj--dec-d "layout: dossier"
printf 'r1.\n' | decision proj--dec-d "Triage (round 1)" >/dev/null
printf 'r2.\n' | decision proj--dec-d "Triage (round 2)" >/dev/null
assert_eq "two rounds: both stay in force" "in-force in-force" \
  "$(for f in $(files proj--dec-d); do fm proj--dec-d "$f" status; done | tr '\n' ' ' | sed 's/ $//')"

# An empty body is an error and writes nothing.
out="$(printf '' | decision proj--dec-d "Empty one")"; rc=$?
assert_eq "empty body: exit 1" 1 "$rc"
assert "empty body: says so" 'empty body' "$out"

# A held task lock: exit 75, nothing written.
mk_task proj--dec-f "layout: dossier"
export WB_LOCKS="$SELF_DIR/wb-locks.sh" TASK_F="$TASKS_DIR/proj--dec-f.md"
bash -c '
  source "$WB_LOCKS"
  wb_task_lock_acquire "$TASK_F" || exit 1
  sleep 5
' &
HOLDER=$!
sleep 1
out="$(printf 'x.\n' | decision proj--dec-f "Locked")"; rc=$?
assert_eq "held lock: exit 75" 75 "$rc"
assert_eq "held lock: nothing written" 0 "$(files proj--dec-f | wc -l | tr -d ' ')"
kill "$HOLDER" 2>/dev/null; wait "$HOLDER" 2>/dev/null; HOLDER=""

# Usage: no title, unknown task.
out="$(printf 'x\n' | bash "$WB" decision --task proj--dec-a 2>&1)"; rc=$?
assert_eq "no title: exit 1" 1 "$rc"
assert "no title: usage" 'usage: wb decision' "$out"
out="$(printf 'x\n' | bash "$WB" decision --task no-such-task-zzz "T" 2>&1)"; rc=$?
assert_eq "unknown task: exit 1" 1 "$rc"

[ "$fail" -eq 0 ] && echo "ALL PASS" || { echo "SOME FAILED"; exit 1; }
