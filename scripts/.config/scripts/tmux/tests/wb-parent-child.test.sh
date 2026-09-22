#!/usr/bin/env bash
# Tests for parent/child picker grouping (U2) — plain-bash assertions
# against a fixture task store and real (but throwaway) tmux sessions, same
# convention as wb-pause.test.sh. collect_combined_rows/wb_live_session_row
# had zero existing test coverage before this file (confirmed: no other
# test file references them) — a fresh suite, not wedged into
# wb-schema.test.sh, following the established one-file-per-feature
# convention (wb-pause.test.sh, wb-resume.test.sh).
#
# Isolated to a private tmux server: collect_live_rows/collect_combined_rows
# enumerate EVERY session on the server (unlike wb-pause.test.sh's cmd_pause,
# which only ever touches a session by exact name), so running against the
# real default server would leak the developer's actual sessions into every
# assertion. A fake `tmux` shim earlier in PATH pins every invocation — ours
# and wb.sh's internal ones alike — to a throwaway `-L` socket.
# Run: bash scripts/.config/scripts/tmux/tests/wb-parent-child.test.sh
set -uo pipefail

WB="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/wb.sh"
FIXTURE="$(mktemp -d -t wb-pc-fixture.XXXXXX)"
FIXTURE_BIN="$(mktemp -d -t wb-pc-bin.XXXXXX)"
PREFIX="wb-pc-test-$$"
SOCK="wb-pc-sock-$$"
REAL_TMUX="$(command -v tmux)"

cat > "$FIXTURE_BIN/tmux" <<EOF
#!/usr/bin/env bash
exec "$REAL_TMUX" -L "$SOCK" "\$@"
EOF
chmod +x "$FIXTURE_BIN/tmux"
PATH="$FIXTURE_BIN:$PATH"

cleanup() {
  "$REAL_TMUX" -L "$SOCK" kill-server 2>/dev/null || true
  rm -rf "$FIXTURE" "$FIXTURE_BIN"
}
trap cleanup EXIT

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

# shellcheck disable=SC1090
source "$WB"
set +e   # wb.sh sets -e; this test intentionally captures non-zero exits
TASKS_DIR="$FIXTURE"

# save_fn/restore_fn — redefining a function in bash overwrites it outright
# (there is no shadow-then-pop); `unset -f` after an override destroys the
# ORIGINAL too. Capture the real definition before overriding, restore it
# by re-eval'ing that capture, never by unsetting.
save_fn() { declare -f "$1"; }
restore_orig_urgency() { eval "$ORIG_URGENCY"; }
restore_orig_panes() { eval "$ORIG_PANES"; }
ORIG_URGENCY="$(save_fn wb_session_urgency)"
ORIG_PANES="$(save_fn tmux_claude_panes)"

mk_task() { # <file> <repo> <parent> <created>
  local f="$FIXTURE/$1"
  printf -- '---\nstatus: doing\nrepo: %s\nbranch: b\nworktree: .worktrees/x\nparent: %s\ntags: []\ncreated: %s\nclosed:\n---\n# %s\n' \
    "$2" "$3" "$4" "${1%.md}" > "$f"
}

mk_session() { # <suffix> <repo> <slug>
  tmux new-session -d -s "${PREFIX}-$1" 2>/dev/null
  tmux set-option -t "=${PREFIX}-$1:" @wb_repo "$2" >/dev/null
  tmux set-option -t "=${PREFIX}-$1:" @wb_slug "$3" >/dev/null
}
kill_sessions() { local s; for s in "$@"; do tmux kill-session -t "=${PREFIX}-$s" 2>/dev/null || true; done; }

strip_ansi() { sed -E 's/\x1b\[[0-9;]*m//g'; }

# --- two live siblings, different repos, sharing a parent -------------------
mk_task 'alpha--child-a.md' alpha 'meta--big-feature' 2026-07-05
mk_task 'beta--child-b.md'  beta  'meta--big-feature' 2026-07-01
mk_session a alpha child-a
mk_session b beta  child-b

out="$(collect_combined_rows)"
assert "two siblings: earlier-created sibling (beta) is the anchor" $'^beta\t' "$out"
assert "two siblings: other sibling (alpha) carries the sibling marker" $'\nalpha\t.*\t1$' "$out"
assert_not "two siblings: anchor row has no sibling marker" $'^beta\t.*\t1$' "$out"

formatted="$(collect_combined_rows | wb_format_for_display | strip_ansi)"
alpha_line="$(printf '%s\n' "$formatted" | grep -F $'\talpha\t')"
assert "sibling sub-row: connector is the sibling marker, not the agent one" ' ~ ' "$alpha_line"
assert "sibling sub-row: repo cell still shows alpha (cross-repo, never blanked)" '^alpha' "$alpha_line"
kill_sessions a b

# --- three live siblings sharing one parent ----------------------------------
mk_task 'alpha--child-c.md' alpha 'meta--three' 2026-07-03
mk_task 'beta--child-d.md'  beta  'meta--three' 2026-07-01
mk_task 'gamma--child-e.md' gamma 'meta--three' 2026-07-02
mk_session a alpha child-c
mk_session b beta  child-d
mk_session c gamma child-e

out="$(collect_combined_rows)"
sib_count="$(printf '%s\n' "$out" | grep -cE $'\t1$')"
assert "three siblings: anchor is the earliest-created (beta)" $'^beta\t' "$out"
[ "$sib_count" -eq 2 ] && echo "ok   - three siblings: exactly two sibling sub-rows" || { echo "FAIL - three siblings: expected 2 sibling sub-rows, got $sib_count"; fail=1; }
kill_sessions a b c

# --- anchor stays stable across refreshes even as live urgency flaps --------
mk_task 'alpha--child-f.md' alpha 'meta--stable' 2026-07-04
mk_task 'beta--child-g.md'  beta  'meta--stable' 2026-07-01
mk_session a alpha child-f
mk_session b beta  child-g

flap=0
wb_session_urgency() {
  flap=$((flap + 1))
  if [ $((flap % 2)) -eq 0 ]; then printf '0\t%s:0.0\tneeds you\t1\n' "${PREFIX}-$1"
  else printf '2\t%s:0.0\tworking\t1\n' "${PREFIX}-$1"; fi
}
first="$(collect_combined_rows | head -1 | cut -f1)"
second="$(collect_combined_rows | head -1 | cut -f1)"
restore_orig_urgency
if [ "$first" = beta ] && [ "$second" = beta ]; then
  echo "ok   - anchor stays beta across refreshes despite flapping urgency"
else
  echo "FAIL - anchor changed across refreshes (first=$first second=$second)"; fail=1
fi
kill_sessions a b

# --- edge case: parent shared by no other live session -----------------------
mk_task 'alpha--lone.md' alpha 'meta--nobody-else' 2026-07-01
mk_session lone alpha lone

out="$(collect_combined_rows)"
assert "lone sibling: renders as a normal top-level row" $'^alpha\t' "$out"
assert_not "lone sibling: no sibling marker" $'\t1$' "$out"
kill_sessions lone

# --- edge case: no parent: at all --------------------------------------------
mk_task 'alpha--noparent.md' alpha '' 2026-07-01
mk_session noparent alpha noparent

out="$(collect_combined_rows)"
assert "no parent: renders unchanged" $'^alpha\t' "$out"
assert_not "no parent: no sibling marker" $'\t1$' "$out"
kill_sessions noparent

# --- edge case: self-reference (parent: == own stem) -------------------------
mk_task 'alpha--self.md' alpha 'alpha--self' 2026-07-01
mk_session self alpha self

out="$(collect_combined_rows)"
assert "self-reference: renders as a normal top-level row" $'^alpha\t' "$out"
assert_not "self-reference: does not carry a sibling marker" $'\t1$' "$out"
kill_sessions self

# --- integration: a sibling that is also a multi-agent session --------------
mk_task 'alpha--child-h.md' alpha 'meta--multi' 2026-07-05
mk_task 'beta--child-i.md'  beta  'meta--multi' 2026-07-01
mk_session a alpha child-h
mk_session b beta  child-i

tmux_claude_panes() {
  [ "${1:-}" = "${PREFIX}-a" ] || return 0
  printf '2\t%s:1.0\tworking\ttask-one\n' "${PREFIX}-a"
  printf '3\t%s:1.1\tidle\ttask-two\n' "${PREFIX}-a"
}
out="$(collect_combined_rows)"
restore_orig_panes
sib_line_no="$(printf '%s\n' "$out" | grep -nE $'^alpha\t' | head -1 | cut -d: -f1)"
agent_line_no="$(printf '%s\n' "$out" | grep -n $'\tagent\t' | head -1 | cut -d: -f1)"
assert "stacked nesting: alpha (sibling, multi-agent) is present" $'^alpha\t' "$out"
if [ -n "$sib_line_no" ] && [ -n "$agent_line_no" ] && [ "$agent_line_no" -gt "$sib_line_no" ]; then
  echo "ok   - stacked nesting: agent sub-row(s) follow the sibling row that owns them"
else
  echo "FAIL - stacked nesting: agent sub-rows not positioned after their sibling row"; fail=1
fi
kill_sessions a b

# --- regression: no shared parent sorts/renders exactly as before -----------
mk_task 'alpha--regress-a.md' alpha '' 2026-07-01
mk_task 'beta--regress-b.md'  beta  '' 2026-07-01
mk_session a alpha regress-a
mk_session b beta  regress-b

out="$(collect_combined_rows)"
assert "regression: alpha present, top-level" $'^alpha\t' "$out"
assert "regression: beta present, top-level" $'\nbeta\t' "$out"
assert_not "regression: no sibling markers anywhere" $'\t1$' "$out"
kill_sessions a b

# --- live parent heads its children, even when it's the least urgent -------
# The reported bug: the parent's own row was ignored, the earliest-created
# child anchored unindented, and the parent sat wherever urgency put it.
# beta is the earliest-created child — the one that used to wrongly anchor.
mk_task 'meta--rework.md'  meta  ''             2026-09-04
mk_task 'beta--load.md'    beta  'meta--rework' 2026-09-10
mk_task 'alpha--runner.md' alpha 'meta--rework' 2026-09-16
mk_task 'gamma--infra.md'  gamma 'meta--rework' 2026-09-16
mk_session p meta  rework
mk_session a beta  load
mk_session b alpha runner
mk_session c gamma infra
wb_session_urgency() { # parent least urgent, a child most urgent
  case "$1" in
    "${PREFIX}-p") printf '3\t- no agent\t\t0\n' ;;
    "${PREFIX}-b") printf '0\t! needs you\t%s:0.0\t1\n' "$1" ;;
    *)             printf '2\t* working\t%s:0.0\t1\n' "$1" ;;
  esac
}
out="$(collect_combined_rows)"
formatted="$(collect_combined_rows | wb_format_for_display | strip_ansi)"
restore_orig_urgency
assert "live parent: parent row is emitted first" '^meta$' "$(printf '%s\n' "$out" | head -1 | cut -f1)"
assert_not "live parent: parent row carries no nest marker" $'^meta\t.*\t(1|c[0-9])$' "$out"
child_count="$(printf '%s\n' "$out" | grep -cE $'\tc1$')"
[ "$child_count" -eq 3 ] && echo "ok   - live parent: all three children marked c1" || { echo "FAIL - live parent: expected 3 c1 children, got $child_count"; fail=1; }
assert "live parent: the earliest-created child is indented too" $'^beta\t.*\tc1$' "$out"
assert_not "live parent: no sibling markers when the parent is live" $'\t1$' "$out"
beta_line="$(printf '%s\n' "$formatted" | grep -F $'\tbeta\t')"
assert "live parent: child connector is ' |- '" ' \|- beta--load' "$beta_line"
assert "live parent: child repo cell still visible (cross-repo)" '^beta' "$beta_line"
row_total="$(printf '%s\n' "$out" | grep -c .)"
[ "$row_total" -eq 4 ] && echo "ok   - live parent: each row emitted exactly once" || { echo "FAIL - live parent: expected 4 rows, got $row_total"; fail=1; }
kill_sessions p a b c

# --- live parent with a single live child still nests ----------------------
mk_task 'meta--solo.md'   meta  ''           2026-09-01
mk_task 'alpha--only.md'  alpha 'meta--solo' 2026-09-02
mk_session p meta  solo
mk_session a alpha only
out="$(collect_combined_rows)"
assert "single child: parent first" '^meta$' "$(printf '%s\n' "$out" | head -1 | cut -f1)"
assert "single child: child nested as c1" $'\nalpha\t.*\tc1$' "$out"
kill_sessions p a

# --- a multi-agent child under a live parent: agent rows stack beneath it ---
mk_task 'meta--stack.md'  meta  ''            2026-09-01
mk_task 'alpha--busy.md'  alpha 'meta--stack' 2026-09-02
mk_session p meta  stack
mk_session a alpha busy
tmux_claude_panes() {
  [ "${1:-}" = "${PREFIX}-a" ] || return 0
  printf '2\t%s:1.0\tworking\ttask-one\n' "${PREFIX}-a"
  printf '3\t%s:1.1\tidle\ttask-two\n' "${PREFIX}-a"
}
out="$(collect_combined_rows)"
formatted="$(collect_combined_rows | wb_format_for_display | strip_ansi)"
restore_orig_panes
lines="$(printf '%s\n' "$out" | cut -f1,9,12 | tr '\t' ' ')"
expected=$'meta task \nalpha task c1\nalpha agent a1\nalpha agent a1'
[ "$lines" = "$expected" ] && echo "ok   - stacking: parent, child, then the child's agent rows (a1)" || { echo "FAIL - stacking: unexpected order/markers"; echo "       got: $lines"; fail=1; }
agent_line="$(printf '%s\n' "$formatted" | grep -F 'task-one')"
assert "stacking: agent row under a level-1 child is indented past the child connector" \
  "^ {$((WB_COL_REPO + 2))}   > task-one" "$agent_line"
kill_sessions p a

# --- nesting depth is capped at WB_NEST_MAX (3); deeper rows clamp, not drop -
mk_task 'd0--root.md' d0 ''         2026-09-01
mk_task 'd1--one.md'  d1 'd0--root' 2026-09-01
mk_task 'd2--two.md'  d2 'd1--one'  2026-09-01
mk_task 'd3--three.md' d3 'd2--two' 2026-09-01
mk_task 'd4--four.md' d4 'd3--three' 2026-09-01
mk_session r d0 root; mk_session s1 d1 one; mk_session s2 d2 two
mk_session s3 d3 three; mk_session s4 d4 four
out="$(collect_combined_rows)"
formatted="$(collect_combined_rows | wb_format_for_display | strip_ansi)"
lines="$(printf '%s\n' "$out" | cut -f1,12 | tr '\t' ' ')"
expected=$'d0 \nd1 c1\nd2 c2\nd3 c3\nd4 c3'
[ "$lines" = "$expected" ] && echo "ok   - depth cap: levels 1..3, the 4th-deep child clamps to c3" || { echo "FAIL - depth cap: unexpected levels"; echo "       got: $lines"; fail=1; }
assert "depth cap: a level-3 row is indented four spaces before its connector" '     \|- d3--three' "$(printf '%s\n' "$formatted" | grep -F $'\td3\t')"
kill_sessions r s1 s2 s3 s4

# --- a parent: cycle among live rows terminates, each row once --------------
mk_task 'cyc--a.md' cyc 'cyc--b' 2026-09-01
mk_task 'cyc--b.md' cyc 'cyc--a' 2026-09-01
mk_session ca cyc a; mk_session cb cyc b
out="$(collect_combined_rows)"
row_total="$(printf '%s\n' "$out" | grep -c .)"
[ "$row_total" -eq 2 ] && echo "ok   - cycle: terminates with each row emitted once" || { echo "FAIL - cycle: expected 2 rows, got $row_total"; fail=1; }
kill_sessions ca cb

# --- parent not live: siblings still group, and a sibling's own live child --
# --- nests beneath that sibling -------------------------------------------
mk_task 'beta--sib-anchor.md' beta  'meta--gone'      2026-07-01
mk_task 'alpha--sib-other.md' alpha 'meta--gone'      2026-07-05
mk_task 'gamma--grandkid.md'  gamma 'alpha--sib-other' 2026-07-06
mk_session a beta  sib-anchor
mk_session b alpha sib-other
mk_session c gamma grandkid
out="$(collect_combined_rows)"
lines="$(printf '%s\n' "$out" | cut -f1,12 | tr '\t' ' ')"
expected=$'beta \nalpha 1\ngamma c2'
[ "$lines" = "$expected" ] && echo "ok   - dead parent: sibling grouping unchanged, a sibling's child nests at c2" || { echo "FAIL - dead parent: unexpected grouping"; echo "       got: $lines"; fail=1; }
kill_sessions a b c

[ "$fail" -eq 0 ] && echo "ALL PASS" || echo "FAILURES"
exit "$fail"
