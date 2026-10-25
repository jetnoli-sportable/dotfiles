#!/usr/bin/env bash
# Tests for the picker grouping rework (docs/plans/2026-10-25-1830-fix-wb-picker-
# grouping-plan.md). Same convention as wb-parent-child.test.sh: source wb.sh,
# a real tmux server on a throwaway private socket (the PATH shim pins EVERY
# tmux call, ours and wb.sh's, to `-L "$SOCK"` — never the default socket).
#
# U1 — wb_format_for_display counts and truncates by character, under both
#      mawk (the host's awk) and gawk.
# U2 — every row carries its visit time as field 13; picker() exports the
#      current session and the frozen "now" to its fzf children.
#
# Run: bash scripts/.config/scripts/tmux/tests/wb-picker-grouping.test.sh
set -uo pipefail

WB="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/wb.sh"
FIXTURE_BIN="$(mktemp -d -t wb-pg-bin.XXXXXX)"
MAWK_BIN="$(mktemp -d -t wb-pg-mawk.XXXXXX)"
GAWK_BIN="$(mktemp -d -t wb-pg-gawk.XXXXXX)"
PREFIX="wb-pg-test-$$"
SOCK="wb-pg-sock-$$"
REAL_TMUX="$(command -v tmux)"

cat > "$FIXTURE_BIN/tmux" <<EOF
#!/usr/bin/env bash
exec "$REAL_TMUX" -L "$SOCK" "\$@"
EOF
chmod +x "$FIXTURE_BIN/tmux"
# One directory per awk, each holding just an `awk` symlink: prepending it to
# PATH makes wb.sh's bare `awk` resolve to that implementation.
ln -s "$(command -v mawk)" "$MAWK_BIN/awk"
ln -s "$(command -v gawk)" "$GAWK_BIN/awk"
PATH="$FIXTURE_BIN:$PATH"

cleanup() {
  "$REAL_TMUX" -L "$SOCK" kill-server 2>/dev/null || true
  rm -rf "$FIXTURE_BIN" "$MAWK_BIN" "$GAWK_BIN"
}
trap cleanup EXIT

fail=0
assert() { # <desc> <expected-regex> <actual>
  if printf '%s' "$3" | /usr/bin/grep -qE "$2"; then
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
    echo "FAIL - $1"
    echo "       expected: $2"
    echo "       got:      $3"
    fail=1
  fi
}

# shellcheck disable=SC1090
source "$WB"
set +e   # wb.sh sets -e; this test intentionally captures non-zero exits

save_fn() { declare -f "$1"; }
ORIG_ATTACHED="$(save_fn wb_session_last_attached)"
ORIG_PANES="$(save_fn tmux_claude_panes)"
restore_orig_attached() { eval "$ORIG_ATTACHED"; }
restore_orig_panes() { eval "$ORIG_PANES"; }

strip_ansi() { sed -E 's/\x1b\[[0-9;]*m//g'; }
# Character count of each line, measured in a UTF-8 locale by gawk (the only
# awk here that can count characters) — independent of the code under test.
char_len() { LC_ALL=en_US.UTF-8 gawk '{ print length($0) }'; }
valid_utf8() { iconv -f UTF-8 -t UTF-8 >/dev/null 2>&1; }

# ============================================================================
# U1 — character-aware padding
# ============================================================================

# fmt_row <name> [branch] — one live task row through the formatter, display
# field only (field 1), under whichever awk PATH currently resolves.
fmt_row() {
  printf 'alpha\t%s\t%s\t2\t* working\ts:0.0\ts\t/r\ttask\t1\t\t\t0\n' "$1" "${2:-[b]}" \
    | wb_format_for_display | cut -f1
}
fmt_under() { # <awk-bin-dir> <name> [branch]
  PATH="$1:$PATH" fmt_row "${@:2}"
}

# --- pure-ASCII rows are byte-identical to the pre-change formatter --------
# Captured from the formatter at the commit before this change (the five rows
# below: a short name, a truncated name+repo+branch, an agent sub-row, a
# level-2 child, a sibling). ^[ is the ESC byte, as `cat -v` prints it.
ascii_rows=(
$'alpha\ta short name\t[feat/x]\t2\t* working\ts:0.0\ts\t/r\ttask\t1\t\t\t0'
$'a-very-long-repo-name\tthis is a very long task name exceeding width\t[feat/very-long-branch-name]\t0\t! needs you\ts:0.0\ts\t/r\ttask\t2\t\t\t0'
$'alpha\tpane task\t[feat/x]\t3\t- idle\ts:1.1\ts\t/r\tagent\t1\t\ta1\t0'
$'beta\tchild name\t[b]\t1\t+ finished\ts:0.0\ts\t/r\ttask\t1\t\tc2\t0'
$'gamma\tsibling name\t[b]\t1\to done\ts:0.0\ts\t/r\ttask\t0\t\t1\t0'
)
ascii_expected='^[[33malpha           ^[[0m  ^[[33ma short name              ^[[0m  both      [feat/x]      ^[[33m* working  ^[[0m
^[[1;35ma-very-long-r...^[[0m  ^[[1;35mthis is a very long tas...^[[0m  both      [feat/ver...  ^[[1;35m! needs you^[[0m
^[[90m                ^[[0m  ^[[90m   > pane task            ^[[0m  agent     [feat/x]      ^[[90m- idle     ^[[0m
^[[36mbeta            ^[[0m  ^[[36m   |- child name          ^[[0m  both      [b]           ^[[36m+ finished ^[[0m
^[[32mgamma           ^[[0m  ^[[32m ~ sibling name           ^[[0m  session   [b]           ^[[32mo done     ^[[0m'
for awkname in mawk gawk; do
  bindir="$MAWK_BIN"; [ "$awkname" = gawk ] && bindir="$GAWK_BIN"
  got="$(printf '%s\n' "${ascii_rows[@]}" | PATH="$bindir:$PATH" wb_format_for_display | cut -f1 | cat -v)"
  assert_eq "U1 ascii rows render byte-identical to before ($awkname)" "$ascii_expected" "$got"
done

# --- a name cut at the NAME width never splits a multi-byte character -------
# The 2-byte "·" is placed so each of the characters around the cut (the
# NAME cell keeps WB_COL_LABEL-3 characters before the "...") starts a
# different byte offset; a byte-wise substr would cut it in half for some.
keep=$((WB_COL_LABEL - 3))
for glyph in "·" "—" "é"; do
  for p in $((keep - 2)) $((keep - 1)) "$keep" $((keep + 1)) $((keep + 2)); do
    name="$(printf 'a%.0s' $(seq 1 $((p - 1))))${glyph}bbbbbbbbbbbbbbbb"
    for awkname in mawk gawk; do
      bindir="$MAWK_BIN"; [ "$awkname" = gawk ] && bindir="$GAWK_BIN"
      line="$(fmt_under "$bindir" "$name")"
      if printf '%s\n' "$line" | valid_utf8 && ! printf '%s' "$line" | /usr/bin/grep -q $'\xef\xbf\xbd'; then
        echo "ok   - U1 '$glyph' at char $p: valid UTF-8, no replacement char ($awkname)"
      else
        echo "FAIL - U1 '$glyph' at char $p: invalid UTF-8 or U+FFFD in the row ($awkname)"
        printf '%s\n' "$line" | cat -v | head -3
        fail=1
      fi
    done
  done
done

# --- visible width of a multi-byte row equals an ASCII row's, every cell ----
ascii_line="$(fmt_under "$MAWK_BIN" "abcdefghijklmnopqrstuvwxyz0123456789" '[branch-x]' | strip_ansi)"
ascii_w="$(printf '%s\n' "$ascii_line" | char_len)"
mb_long="/verify-behaviour · checks.md norm and watcher"      # > NAME width, "·" mid-name
mb_short="caf— au lait"                                      # < NAME width, has "—"
for awkname in mawk gawk; do
  bindir="$MAWK_BIN"; [ "$awkname" = gawk ] && bindir="$GAWK_BIN"
  for n in "$mb_long" "$mb_short" "résumé review"; do
    w="$(fmt_under "$bindir" "$n" '[branch-x]' | strip_ansi | char_len)"
    assert_eq "U1 row width equals the ASCII row's for '$n' ($awkname)" "$ascii_w" "$w"
  done
done

# --- a long name's truncated cell ends in "..." and keeps whole characters --
# NAME cell = characters WB_COL_REPO+3 .. +WB_COL_LABEL of the plain line
cell="$(fmt_under "$MAWK_BIN" "$mb_long" | strip_ansi | LC_ALL=en_US.UTF-8 gawk -v a=$((WB_COL_REPO + 3)) -v w="$WB_COL_LABEL" '{ print substr($0, a, w) }')"
assert "U1 truncated multi-byte name keeps the ASCII ... suffix" '\.\.\.$' "$cell"

# --- both awks produce identical output on the same multi-byte input --------
multi_in=$'alpha\t/verify-behaviour · checks.md norm and watcher\t[feat/ünïcode-branch-name]\t2\t* working\ts:0.0\ts\t/r\ttask\t1\t\t\t0\nbeta\tcafé — au lait\t[b]\t1\t+ finished\ts:0.0\ts\t/r\ttask\t1\t\tc1\t0'
mawk_out="$(printf '%s\n' "$multi_in" | PATH="$MAWK_BIN:$PATH" wb_format_for_display | cat -v)"
gawk_out="$(printf '%s\n' "$multi_in" | PATH="$GAWK_BIN:$PATH" wb_format_for_display | cat -v)"
assert_eq "U1 mawk and gawk render multi-byte rows identically" "$gawk_out" "$mawk_out"
# ... and gawk under a UTF-8 locale must not change anything either (the
# formatter forces byte semantics itself, KTD10).
utf_out="$(printf '%s\n' "$multi_in" | PATH="$GAWK_BIN:$PATH" LC_ALL=en_US.UTF-8 wb_format_for_display | cat -v)"
assert_eq "U1 gawk in a UTF-8 locale renders the same (formatter forces byte mode)" "$gawk_out" "$utf_out"

# --- padtail: "..." + the last (w-3) characters, whole characters only ------
for awkname in mawk gawk; do
  bindir="$MAWK_BIN"; [ "$awkname" = gawk ] && bindir="$GAWK_BIN"
  tails="$(PATH="$bindir:$PATH" LC_ALL=C awk "$_WB_AWK_TEXT"'
    BEGIN { printf "[%s]\n[%s]\n[%s]\n", padtail("feat/a-rather-long-branch", 12), padtail("short", 12), padtail("feat/ünï·codé-long", 12) }')"
  assert_eq "U1 padtail ($awkname): ascii tail" '[...ng-branch]' "$(printf '%s\n' "$tails" | sed -n 1p)"
  assert_eq "U1 padtail ($awkname): short value pads whole" '[short       ]' "$(printf '%s\n' "$tails" | sed -n 2p)"
  assert_eq "U1 padtail ($awkname): multi-byte tail is whole characters" '[...codé-long]' "$(printf '%s\n' "$tails" | sed -n 3p)"
done

# ============================================================================
# U2 — visit time (field 13) and the picker environment
# ============================================================================

mk_session() { tmux new-session -d -s "${PREFIX}-$1" 2>/dev/null; }
kill_sessions() { local s; for s in "$@"; do tmux kill-session -t "=${PREFIX}-$s" 2>/dev/null || true; done; }
field() { printf '%s\n' "$1" | cut -f"$2"; }
nfields() { printf '%s\n' "$1" | awk -F'\t' '{ print NF }'; }

# --- live row: 13 fields, field 13 is the stubbed visit time ----------------
mk_session a
wb_session_last_attached() { printf '1700000123\n'; }
row="$(wb_live_session_row "${PREFIX}-a")"
assert_eq "U2 live row has 13 fields" 13 "$(nfields "$row")"
assert_eq "U2 live row field 13 is the visit time from the seam" 1700000123 "$(field "$row" 13)"

# an explicit time passed by the caller wins; the seam is not consulted
row="$(wb_live_session_row "${PREFIX}-a" 1700000777)"
assert_eq "U2 live row takes an explicit visit time over the seam" 1700000777 "$(field "$row" 13)"
restore_orig_attached

# --- never-attached session: the real seam yields 0 (field 13 never empty) --
row="$(wb_live_session_row "${PREFIX}-a")"
assert_eq "U2 never-attached session has field 13 = 0 (default seam)" 0 "$(field "$row" 13)"
row="$(wb_live_session_row "${PREFIX}-a" "")"
assert_eq "U2 empty listed time also reads as 0" 0 "$(field "$row" 13)"

# --- collect_live_rows reads the time via list-sessions (empty -> seam) -----
wb_session_last_attached() { case "$1" in "${PREFIX}-a") echo 1700000500 ;; *) echo 0 ;; esac; }
out="$(collect_live_rows | /usr/bin/grep -F "${PREFIX}-a")"
assert_eq "U2 collect_live_rows row has 13 fields" 13 "$(nfields "$out")"
assert_eq "U2 collect_live_rows field 13 honours a stubbed seam" 1700000500 "$(field "$out" 13)"
restore_orig_attached
kill_sessions a

# --- agent sub-rows carry their owning session's visit time -----------------
mk_session m
wb_session_last_attached() { printf '1700000900\n'; }
tmux_claude_panes() {
  [ "${1:-}" = "${PREFIX}-m" ] || return 0
  printf '2\t%s:1.0\tworking\ttask-one\n' "${PREFIX}-m"
  printf '3\t%s:1.1\tidle\ttask-two\n' "${PREFIX}-m"
}
out="$(collect_combined_rows | /usr/bin/grep -F "${PREFIX}-m")"
agent_rows="$(printf '%s\n' "$out" | awk -F'\t' '$9 == "agent"')"
parent_row="$(printf '%s\n' "$out" | awk -F'\t' '$9 != "agent"')"
assert_eq "U2 multi-agent session: two agent sub-rows emitted" 2 "$(printf '%s\n' "$agent_rows" | /usr/bin/grep -c .)"
assert_eq "U2 agent sub-rows have 13 fields" "13 13" "$(printf '%s\n' "$agent_rows" | awk -F'\t' '{ printf "%s%s", (NR > 1 ? " " : ""), NF } END { print "" }')"
assert_eq "U2 agent sub-rows carry the owner's visit time" "1700000900 1700000900" \
  "$(printf '%s\n' "$agent_rows" | cut -f13 | paste -sd' ')"
assert_eq "U2 the owning row keeps field 13 too" 1700000900 "$(field "$parent_row" 13)"
restore_orig_panes
restore_orig_attached

# --- wb_parent_subrows sets the nest marker without disturbing field 13 -----
marked="$(wb_parent_subrows "$parent_row" c2)"
assert_eq "U2 nest marker lands in field 12, visit time stays in field 13" "c2 1700000900" \
  "$(printf '%s\n' "$marked" | cut -f12,13 | tr '\t' ' ')"
kill_sessions m

# --- the formatter passes field 13 through (14 fields once display is in) ---
fmt="$(printf '%s\n' "$row" | wb_format_for_display)"
assert_eq "U2 formatted row has 14 fields (display + 13 raw)" 14 "$(nfields "$fmt")"
assert_eq "U2 formatted row ends with the visit time" 0 "$(field "$fmt" 14)"

# --- picker(): fzf binds still address fields 7-10, and the env is exported -
picker_block="$(awk '/^picker\(\) \{/{p=1} p{print} p&&/^}/{exit}' "$WB")"
assert "U2 picker: ctrl-x bind still passes {10} {8} {7} {9} (kind, ref, session, target order)" \
  'ctrl-x:become\(.*_ctrl-x \{10\} \{8\} \{7\} \{9\}\)' "$picker_block"
assert "U2 picker: preview still reads {7} target and {9} kind/ref" \
  "preview '\[ -n \{7\} \] && tmux capture-pane -ep -t \{7\} \|\| \(\[ -f \{9\} \]" "$picker_block"
assert "U2 picker: rename/down binds still use {8}" '"r:execute\(.*_rename \{8\}\)' "$picker_block"
assert "U2 picker: break-out bind still uses {7}" '"b:execute\(.*_break-out \{7\}\)' "$picker_block"
assert "U2 picker: exports WB_PICKER_SESSION from tmux display-message" \
  'export WB_PICKER_SESSION="\$\(tmux display-message -p .#S. 2>/dev/null \|\| true\)"' "$picker_block"
assert "U2 picker: exports WB_PICKER_NOW as the open-time epoch" \
  'export WB_PICKER_NOW="\$\(date \+%s\)"' "$picker_block"
# both must be exported before the first render, or the first frame uses the
# real clock / no current session while every later reload uses the frozen one
exp_line="$(printf '%s\n' "$picker_block" | /usr/bin/grep -n 'export WB_PICKER_NOW' | head -1 | cut -d: -f1)"
first_render="$(printf '%s\n' "$picker_block" | /usr/bin/grep -n 'render_rows "\$mode_file"' | head -1 | cut -d: -f1)"
if [ -n "$exp_line" ] && [ -n "$first_render" ] && [ "$exp_line" -lt "$first_render" ]; then
  echo "ok   - U2 picker: env exported before the first render_rows"
else
  echo "FAIL - U2 picker: env must be exported before the first render_rows (export line=$exp_line, render line=$first_render)"; fail=1
fi

[ "$fail" -eq 0 ] && echo "ALL PASS" || echo "FAILURES"
exit "$fail"
