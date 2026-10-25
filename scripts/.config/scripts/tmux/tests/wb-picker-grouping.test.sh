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
# U3 — rows group by repo, order by visit time, pin the current session's
#      family on top; urgency never moves a row; the dormant tab groups too.
# U4 — the display: REPO/NAME/BRANCH/AGE, status as the REPO and NAME colour
#      (bold magenta for rows that need Jet), (here), width, the snapshot file.
# U5 — the header (count, colour legend, key hint) and the needs-you cursor:
#      _initial-pos, _next-needs, the focus record, the binds that wire them.
#
# Run: bash scripts/.config/scripts/tmux/tests/wb-picker-grouping.test.sh
set -uo pipefail

WB="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/wb.sh"
FIXTURE_BIN="$(mktemp -d -t wb-pg-bin.XXXXXX)"
MAWK_BIN="$(mktemp -d -t wb-pg-mawk.XXXXXX)"
GAWK_BIN="$(mktemp -d -t wb-pg-gawk.XXXXXX)"
FIXTURE="$(mktemp -d -t wb-pg-fixture.XXXXXX)"
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
  rm -rf "$FIXTURE_BIN" "$MAWK_BIN" "$GAWK_BIN" "$FIXTURE"
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

# The formatter sizes NAME from FZF_COLUMNS (fzf exports it) and ages rows
# against WB_PICKER_NOW; pin both so output is the same on every host.
export FZF_COLUMNS=200
export WB_PICKER_NOW=1000000
NW="$(wb_picker_name_width)"

save_fn() { declare -f "$1"; }
ORIG_ATTACHED="$(save_fn wb_session_last_attached)"
ORIG_PANES="$(save_fn tmux_claude_panes)"
ORIG_URGENCY="$(save_fn wb_session_urgency)"
restore_orig_attached() { eval "$ORIG_ATTACHED"; }
restore_orig_panes() { eval "$ORIG_PANES"; }
restore_orig_urgency() { eval "$ORIG_URGENCY"; }

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

# U4 re-based this guard on the REPO/NAME/BRANCH/AGE layout (FZF_COLUMNS=200,
# WB_PICKER_NOW=1000000): five ASCII rows -- a short name, a truncated
# name+repo+branch, an agent sub-row, a level-2 child, a sibling -- whose
# bytes are pinned, and mawk must equal gawk. ^[ is the ESC byte, as `cat -v`
# prints it.
ascii_rows=(
$'alpha\ta short name\t[feat/x]\t2\t* working\ts:0.0\ts\t/r\ttask\t1\t\t\t0'
$'a-very-long-repo-name\tthis is a very long task name exceeding width exceeding width exceeding width\t[feat/very-long-branch-name]\t1\t+ finished\ts:0.0\ts\t/r\ttask\t2\t\t\t999940'
$'alpha\tpane task\t[feat/x]\t3\t- idle\ts:1.1\ts\t/r\tagent\t1\t\ta1\t0'
$'beta\tchild name\t[b]\t1\t+ finished\ts:0.0\ts\t/r\ttask\t1\t\tc2\t990000'
$'gamma\tsibling name\t[b]\t1\to done\ts:0.0\ts\t/r\ttask\t0\t\t1\t0'
)
ascii_expected='^[[33malpha           ^[[0m  ^[[33ma short name                                     ^[[0m  feat/x        -   
^[[36ma-very-long-r...^[[0m  ^[[36mthis is a very long task name exceeding width ...^[[0m  ...anch-name  1m  
^[[90m                ^[[0m  ^[[90m   > pane task                                   ^[[0m  feat/x            
^[[36mbeta            ^[[0m  ^[[36m   |- child name                                 ^[[0m  b             2h  
^[[32mgamma           ^[[0m  ^[[32m ~ sibling name                                  ^[[0m  b             -   '
for awkname in mawk gawk; do
  bindir="$MAWK_BIN"; [ "$awkname" = gawk ] && bindir="$GAWK_BIN"
  got="$(printf '%s\n' "${ascii_rows[@]}" | PATH="$bindir:$PATH" wb_format_for_display | cut -f1 | cat -v)"
  assert_eq "U1 ascii rows render byte-identical to the pinned layout ($awkname)" "$ascii_expected" "$got"
done

# --- a name cut at the NAME width never splits a multi-byte character -------
# The 2-byte "·" is placed so each of the characters around the cut (the
# NAME cell keeps NW-3 characters before the "...") starts a
# different byte offset; a byte-wise substr would cut it in half for some.
keep=$((NW - 3))
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
mb_long="/verify-behaviour · checks.md norm and watcher, plus a tail"   # > NAME width, "·" mid-name
mb_short="caf— au lait"                                      # < NAME width, has "—"
for awkname in mawk gawk; do
  bindir="$MAWK_BIN"; [ "$awkname" = gawk ] && bindir="$GAWK_BIN"
  for n in "$mb_long" "$mb_short" "résumé review"; do
    w="$(fmt_under "$bindir" "$n" '[branch-x]' | strip_ansi | char_len)"
    assert_eq "U1 row width equals the ASCII row's for '$n' ($awkname)" "$ascii_w" "$w"
  done
done

# --- a long name's truncated cell ends in "..." and keeps whole characters --
# NAME cell = characters WB_COL_REPO+3 .. +NW of the plain line
cell="$(fmt_under "$MAWK_BIN" "$mb_long" | strip_ansi | LC_ALL=en_US.UTF-8 gawk -v a=$((WB_COL_REPO + 3)) -v w="$NW" '{ print substr($0, a, w) }')"
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

# --- a really attached session: list-sessions' format yields its attach time -
# The stubs above never see a real time, so a typo in collect_live_rows'
# '#{session_last_attached} #{session_name}' format would pass them. Attach a
# client for a moment (script(1) gives it a terminal) so tmux records a time.
if command -v script >/dev/null 2>&1; then
  mk_session r
  TERM=xterm timeout 5 script -qec "tmux attach-session -t '=${PREFIX}-r' \\; detach-client" /dev/null >/dev/null 2>&1
  out="$(collect_live_rows | awk -F'\t' -v s="${PREFIX}-r" '$7 == s')"
  assert "U2 a really attached session: collect_live_rows reads its attach time from list-sessions" '^[0-9]{9,}$' "$(field "$out" 13)"
  kill_sessions r
else
  echo "FAIL - U2 real attach: script(1) is not installed in this image"; fail=1
fi

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
assert "U6 picker: the preview falls back to the _preview helper fed {7} target, {9} ref, {10} kind (after the context card)" \
  "_preview \\{7\\} \\{9\\} \\{10\\}" "$(declare -f wb_preview_cmd)"
assert "U6 picker: focus updates the preview label from _preview-label" \
  'focus:transform-preview-label\(.*_preview-label \{7\} \{9\}\)' "$picker_block"
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

# ============================================================================
# U3 — group by repo, order by visit, pin the current session's family
# ============================================================================
TASKS_DIR="$FIXTURE"

mk_task() { # <file> <repo> <parent> <created>
  printf -- '---\nstatus: doing\nrepo: %s\nbranch: b\nworktree: .worktrees/x\nparent: %s\ntags: []\ncreated: %s\nclosed:\n---\n# %s\n' \
    "$2" "$3" "$4" "${1%.md}" > "$FIXTURE/$1"
}
# mk <suffix> <repo> <slug> <visit> [parent] [created] — a task file plus its
# live session, with <visit> as the session's stubbed last-attached time.
declare -A VISIT=()
wb_session_last_attached() { printf '%s\n' "${VISIT[$1]:-0}"; }
mk() {
  mk_task "$2--$3.md" "$2" "${5:-}" "${6:-2026-07-01}"
  mk_session "$1"; tmux set-option -t "=${PREFIX}-$1:" @wb_repo "$2" >/dev/null
  tmux set-option -t "=${PREFIX}-$1:" @wb_slug "$3" >/dev/null
  VISIT["${PREFIX}-$1"]="$4"
}
reset_u3() { # kill every session the scenario made, forget the visit stubs
  local k; for k in "${!VISIT[@]}"; do tmux kill-session -t "=$k" 2>/dev/null || true; done
  VISIT=(); rm -f "${FIXTURE:?}"/*.md
}
# ord — the render order as session suffixes (agent sub-rows tagged
# "<suffix>/agent"), one line, from the real collect_combined_rows.
ord() {
  collect_combined_rows | awk -F'\t' -v p="${PREFIX}-" '{ s = $7; sub("^" p, "", s); print ($9 == "agent" ? s "/agent" : s) }' | paste -sd' '
}

# --- two repos whose sessions interleave by visit time: two contiguous groups
# flat visit order would be b1 a2 a1 b2; beta's newest visit (300) beats alpha's (200)
mk a1 alpha one 100;  mk b1 beta one 300;  mk a2 alpha two 200;  mk b2 beta two 50
assert_eq "U3 interleaved repos: two contiguous groups, newest-visited group first, newest first inside" \
  "b1 b2 a2 a1" "$(ord)"
reset_u3

# --- a cross-repo family stays contiguous in its ROOT's repo group ----------
# be--monorepo parent P (visit 100) with a lib--algorithms child C (500); an
# unrelated lib--algorithms session L (400) and zeta session Z (300). The
# family's 500 lifts the be--monorepo group; C keeps its own repo name and
# does NOT join L's group.
mk p be--monorepo parent 100
mk c lib--algorithms kid 500 be--monorepo--parent
mk q be--monorepo other 50
mk l lib--algorithms solo 400
mk z zeta zed 300
assert_eq "U3 cross-repo family: contiguous under the root's repo group; other repos by their own newest visit" \
  "p c q l z" "$(ord)"
child_repo="$(collect_combined_rows | awk -F'\t' -v s="${PREFIX}-c" '$7 == s { print $1 }')"
assert_eq "U3 cross-repo family: the child keeps its own repo name" lib--algorithms "$child_repo"
reset_u3

# --- a sibling group under a non-live parent lands in the anchor's repo group
# bx is the earliest-created (the anchor, beta); ay (alpha) is its sibling and
# was visited most recently (900). alpha has no other row, so nothing may
# surface an "alpha" group.
mk bx beta x 100 meta--gone 2026-07-01
mk ay alpha y 900 meta--gone 2026-07-05
mk bz beta z 200
mk g  gamma g 500
assert_eq "U3 sibling group: stays together in the anchor's repo group, which its newest member lifts" \
  "bx ay bz g" "$(ord)"
reset_u3

# --- the current session pinned: its whole family first, the rest unchanged -
# family meta--fam: P (visit 100) with children C1 (300) and C2 (200).
# Others: dotfiles D (800), zeta Z (500).
mk fp meta fam 100
mk c1 alpha one 300 meta--fam
mk c2 alpha two 200 meta--fam
mk d  dotfiles d 800
mk z  zeta z 500
unset WB_PICKER_SESSION
unpinned="$(ord)"
assert_eq "U3 unpinned baseline: the family (newest member 300) sits below D and Z" "d z fp c1 c2" "$unpinned"
export WB_PICKER_SESSION="${PREFIX}-c1"
pinned="$(ord)"
assert_eq "U3 pinned child: its whole family is first (parent, then children by visit)" "fp c1 c2" "$(printf '%s\n' "$pinned" | cut -d' ' -f1-3)"
assert_eq "U3 pinned child: the order below the family is unchanged" "d z" "$(printf '%s\n' "$pinned" | cut -d' ' -f4-)"
export WB_PICKER_SESSION="${PREFIX}-fp"
assert_eq "U3 pinning the parent instead pins the same family block" "$pinned" "$(ord)"

# --- nothing pinned without a current session -------------------------------
unset WB_PICKER_SESSION
assert_eq "U3 WB_PICKER_SESSION unset: nothing pinned" "$unpinned" "$(ord)"
export WB_PICKER_SESSION=""
assert_eq "U3 WB_PICKER_SESSION empty: nothing pinned" "$unpinned" "$(ord)"
unset WB_PICKER_SESSION
reset_u3

# --- the pinned family does not lift its own repo's group -------------------
# dotfiles: pinned family F (visit 900), plus two others D2 (300), D3 (200).
# zeta Z (350). Without the exclusion the dotfiles group would be worth 900
# and sort before Z; with it the group is worth 300, so Z comes first.
mk f  dotfiles pinned 900
mk d2 dotfiles two 300
mk d3 dotfiles three 200
mk z  zeta z 350
export WB_PICKER_SESSION="${PREFIX}-f"
assert_eq "U3 pinned family in dotfiles: the other dotfiles families form one group ordered as if it were absent" \
  "f z d2 d3" "$(ord)"
unset WB_PICKER_SESSION
reset_u3

# --- flipping urgency leaves the order identical ---------------------------
mk u1 alpha one 100
mk u2 alpha two 200
mk u3 beta three 300
mk u4 beta four 50
urgency_a() { case "$1" in "${PREFIX}-u1") printf '0\t! needs you\t%s:0.0\t1\n' "$1" ;; *) printf '3\t- no agent\t\t0\n' ;; esac; }
urgency_b() { case "$1" in "${PREFIX}-u4") printf '0\t! needs you\t%s:0.0\t1\n' "$1" ;; *) printf '2\t* working\t%s:0.0\t1\n' "$1" ;; esac; }
wb_session_urgency() { urgency_a "$@"; }
order_a="$(ord)"; ranks_a="$(collect_combined_rows | cut -f4 | paste -sd' ')"
wb_session_urgency() { urgency_b "$@"; }
order_b="$(ord)"; ranks_b="$(collect_combined_rows | cut -f4 | paste -sd' ')"
restore_orig_urgency
if [ "$ranks_a" != "$ranks_b" ]; then echo "ok   - U3 urgency stubs really differ between the two renders ($ranks_a vs $ranks_b)"
else echo "FAIL - U3 urgency stubs produced the same ranks, so the next check proves nothing"; fail=1; fi
assert_eq "U3 flipping urgency between renders leaves the order identical" "$order_a" "$order_b"
assert_eq "U3 ... and that order is the visit order" "u3 u4 u2 u1" "$order_a"
reset_u3

# --- equal visit times order by repo, then label, the same every run --------
mk e1 beta  mm 100
mk e2 alpha zz 100
mk e3 alpha aa 100
mk e4 beta  bb 100
first_run="$(ord)"
assert_eq "U3 equal visit times: by repo, then label" "e3 e2 e4 e1" "$first_run"
assert_eq "U3 equal visit times: repeated runs agree" "$first_run $first_run" "$(ord) $(ord)"
reset_u3

# --- agent sub-rows stay directly under their owner -------------------------
# M (visit 100, two live panes) sits below N (200) and Z (150) in alpha; its
# agent rows carry M's time and must not drift up past Z or N.
mk n alpha nn 200
mk zz alpha zz 150
mk m alpha mm 100
tmux_claude_panes() {
  [ "${1:-}" = "${PREFIX}-m" ] || return 0
  printf '2\t%s:1.0\tworking\ttask-one\n' "${PREFIX}-m"
  printf '3\t%s:1.1\tidle\ttask-two\n' "${PREFIX}-m"
}
assert_eq "U3 agent sub-rows stay directly under their owner" "n zz m m/agent m/agent" "$(ord)"
restore_orig_panes
reset_u3

# --- agent sub-rows keep pane order when a pane's status changes ------------
# Pane order, not urgency: a pane that starts waiting must not jump above its
# siblings on the next refresh (1.10 after 1.9: the pane number sorts as a
# number).
tmux_claude_panes() {
  [ "${1:-}" = "${PREFIX}-m" ] || return 0
  printf '%s\t%s:1.10\tworking\tc\n' "$R2" "${PREFIX}-m"
  printf '%s\t%s:1.0\tworking\ta\n' "$R0" "${PREFIX}-m"
  printf '%s\t%s:1.9\tidle\tb\n' "$R1" "${PREFIX}-m"
}
subrow_panes() { wb_agent_subrows alpha "${PREFIX}-m" /r b 100 | cut -f6 | sed "s/^${PREFIX}-m://" | paste -sd' '; }
R0=2 R1=3 R2=1
before="$(subrow_panes)"
assert_eq "U3 agent sub-rows are listed in pane order" "1.0 1.9 1.10" "$before"
R0=0 R2=2
assert_eq "U3 agent sub-rows do not swap when a pane starts waiting" "$before" "$(subrow_panes)"
unset R0 R1 R2
restore_orig_panes

# --- the stream marks never reach the output -------------------------------
mk k1 alpha one 100
mk k2 beta  two 200
raw="$(collect_combined_rows | od -An -c | tr -d ' \n')"
if [[ "$raw" == *'001'* ]]; then echo "FAIL - U3 block marks leaked into collect_combined_rows output"; fail=1
else echo "ok   - U3 block marks never reach the output"; fi
reset_u3

# --- the dormant tab: repos group, newest transcript first ------------------
collect_dormant_rows() { # synthetic dormant rows (13 fields, field 13 = transcript time)
  local r
  for r in "alpha one 100" "beta one 300" "alpha two 200" "beta two 50"; do
    # shellcheck disable=SC2086
    set -- $r
    printf '%s\t%s\t[b]\t0\t~ doing 1d\t\t\t/f.md\ttask\t0\t%s\t\t%s\n' "$1" "$1--$2" "$2" "$3"
  done
}
dmode="$FIXTURE/dmode"; dview="$FIXTURE/dview"; printf normal > "$dmode"; printf dormant > "$dview"
_refresh_dormant "$dmode" "$dview"
assert_eq "U3 dormant tab: repos grouped, newest transcript's repo first, newest first inside" \
  "beta--one beta--two alpha--two alpha--one" "$(cut -f2 "$dview.cache" | paste -sd' ')"
assert_eq "U3 dormant cache rows keep all 13 fields" 13 "$(nfields "$(sed -n 1p "$dview.cache")")"

# ============================================================================
# U4 — slim display: colour status, AGE, branch tail, width, snapshot
# ============================================================================
# Synthetic rows straight through the formatter: no tmux needed. Fields:
# repo name branch urank label target session ref kind ucount slug nest visit.
u4row() { # repo name branch urank label session [kind] [nest] [visit]
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t/r\t%s\t1\t\t%s\t%s\n' \
    "$1" "$2" "$3" "$4" "$5" "${6:+t:0.0}" "$6" "${7:-task}" "${8:-}" "${9:-0}"
}
has()  { printf '%s' "$2" | /usr/bin/grep -qF -- "$1"; }
assert_has()   { if has "$2" "$3"; then echo "ok   - $1"; else echo "FAIL - $1"; echo "       expected to contain: $(printf '%s' "$2" | cat -v)"; echo "       got: $(printf '%s' "$3" | cat -v | head -6)"; fail=1; fi; }
assert_lacks() { if has "$2" "$3"; then echo "FAIL - $1"; echo "       expected NOT to contain: $(printf '%s' "$2" | cat -v)"; echo "       got: $(printf '%s' "$3" | cat -v | head -6)"; fail=1; else echo "ok   - $1"; fi; }
disp()  { wb_format_for_display "$@" | cut -f1; }                 # display field only
line_n() { sed -n "${1}p"; }
ESC=$'\033'
G90="${ESC}[90m"; Y33="${ESC}[33m"; C36="${ESC}[36m"; N32="${ESC}[32m"
MAG="${ESC}[1;35m"

# --- no TYPE words, no status labels, a new header ---------------------------
rows="$(u4row alpha 'alpha-one' '[b]' 2 '* working' s1)
$(u4row alpha 'alpha-two' '[b]' 1 '+ finished' s2)
$(u4row alpha 'alpha-three' '[b]' 1 'o done' s3)
$(u4row alpha 'pane-x' '[b]' 3 '- idle' s2 agent a1)"
plain="$(printf '%s\n' "$rows" | disp | strip_ansi)"
assert_lacks "U4 no TYPE words in the rows" "session" "$plain"
for w in both agent working finished idle "needs you"; do
  assert_lacks "U4 no '$w' text in the rows" "$w" "$plain"
done
assert_lacks "U4 no standalone 'done' status label" "done " "$(printf '%s\n' "$plain" | sed 's/alpha-three//')"
hdr="$(wb_column_header | strip_ansi)"
assert_eq "U4 header names exactly REPO NAME BRANCH AGE" "REPO NAME BRANCH AGE" "$(printf '%s' "$hdr" | tr -s ' ')"

# --- (here): only the current session's row, grey, never reverse ------------
rows="$(u4row alpha 'mine' '[b]' 1 '+ finished' s1)
$(u4row alpha 'other' '[b]' 1 '+ finished' s2)"
out="$(printf '%s\n' "$rows" | WB_PICKER_SESSION=s1 disp)"
assert_has   "U4 the current session's row carries (here)" "(here)" "$(printf '%s\n' "$out" | line_n 1)"
assert_lacks "U4 no other row carries (here)" "(here)" "$(printf '%s\n' "$out" | line_n 2)"
l1="$(printf '%s\n' "$out" | line_n 1)"
assert_eq "U4 the (here) row starts in grey" "$G90" "${l1:0:5}"
assert "U4 the (here) row uses no status colour (finished is cyan)" '^[^m]*m[^'"$ESC"']*'"$ESC"'\[0m$' "$l1"
assert_lacks "U4 the (here) row is not magenta" "$MAG" "$l1"
out="$(printf '%s\n' "$rows" | disp)"
assert_lacks "U4 no (here) without a current session" "(here)" "$out"
# a long name keeps the tag: the name is cut, never "(here)"
long="$(printf 'n%.0s' $(seq 1 90))"
l1="$(u4row alpha "$long" '[b]' 1 '+ finished' s1 | WB_PICKER_SESSION=s1 disp | strip_ansi)"
assert "U4 a long name is cut to keep the (here) tag" '\.\.\. \(here\) ' "$l1"
assert_eq "U4 ... and the row is no wider than a short one" "$(u4row alpha x '[b]' 1 '+ finished' s1 | WB_PICKER_SESSION=s1 disp | strip_ansi | char_len)" "$(printf '%s\n' "$l1" | char_len)"

# --- a separator row under the pinned family --------------------------------
rows="$(u4row alpha 'mine' '[b]' 1 '+ finished' s1)
$(u4row alpha 'kid' '[b]' 2 '* working' s2 task c1)
$(u4row alpha 'kid-pane' '[b]' 2 '* working' s2 agent a1)
$(u4row beta 'next' '[b]' 0 '! needs you' s3)
$(u4row beta 'after' '[b]' 1 'o done' s4)"
snap="$FIXTURE/sep.snap"; rm -f "$snap" "$snap".*
for awkname in mawk gawk; do
  bindir="$MAWK_BIN"; [ "$awkname" = gawk ] && bindir="$GAWK_BIN"
  out="$(printf '%s\n' "$rows" | WB_PICKER_SESSION=s2 PATH="$bindir:$PATH" wb_format_for_display "$snap")"
  assert_eq "U4 separator ($awkname): six rows, the line fourth" "mine kid kid-pane sep next after" \
    "$(printf '%s\n' "$out" | awk -F'\t' '{ print ($10 == "sep" ? "sep" : $3) }' | paste -sd' ')"
  assert "U4 separator ($awkname): a grey line of box-drawing dashes" "^$(printf '\033')\\[90m(─)+$(printf '\033')\\[0m$" "$(printf '%s\n' "$out" | line_n 4 | cut -f1)"
done
assert_eq "U4 separator: as wide as a data row" "$(printf '%s\n' "$out" | line_n 1 | cut -f1 | strip_ansi | char_len)" "$(printf '%s\n' "$out" | line_n 4 | cut -f1 | strip_ansi | char_len)"
assert_eq "U4 separator: no session, pane or ref for a key to act on" "|||" "$(printf '%s\n' "$out" | line_n 4 | awk -F'\t' '{ print $7 "|" $8 "|" $9 "|" $12 }')"
assert_eq "U4 separator: the snapshot counts it, so positions match fzf" "4		0	0		sep" "$(sed -n 5p "$snap")"
assert_eq "U4 separator: ... and the waiting row below it is pos 5" "5	s3	1	0	t:0.0	task" "$(awk -F'\t' '$3 == 1' "$snap")"
assert_eq "U4 separator: none without a current session" 0 "$(printf '%s\n' "$rows" | wb_format_for_display | awk -F'\t' '$10 == "sep"' | /usr/bin/grep -c .)"
assert_eq "U4 separator: none when the pinned family is the whole list" 0 \
  "$(printf '%s\n' "$rows" | head -3 | WB_PICKER_SESSION=s2 wb_format_for_display | awk -F'\t' '$10 == "sep"' | /usr/bin/grep -c .)"
assert_eq "U4 separator: a one-row pinned family gets it too" "next sep mine kid kid-pane after" \
  "$({ printf '%s\n' "$rows" | sed -n 4p; printf '%s\n' "$rows" | sed -n '1,3p;5p'; } | WB_PICKER_SESSION=s3 wb_format_for_display | awk -F'\t' '{ print ($10 == "sep" ? "sep" : $3) }' | paste -sd' ')"
assert_eq "U4 separator: the dormant tab never has one" 0 \
  "$(u4row alpha 'dn' '[b]' 0 '~ doing 3d' '' task '' 5 | WB_PICKER_SESSION=s1 wb_format_for_display | awk -F'\t' '$10 == "sep"' | /usr/bin/grep -c .)"

# --- each repo name once per group; every name in search mode ---------------
# Repo cells as words: the repo, "-" for a blank cell, "sep" for the separator.
repos() { cut -f1 | strip_ansi | awk '{ if ($0 ~ /^─/) print "sep"; else if (substr($0, 1, 1) == " ") print "-"; else print $1 }' | paste -sd' '; }
rows="$(u4row alpha 'a1' '[b]' 1 '+ finished' s1)
$(u4row beta 'b-kid' '[b]' 1 '+ finished' s2 task c1)
$(u4row beta 'b-kid2' '[b]' 1 '+ finished' s3 task c1)
$(u4row alpha 'a-kid' '[b]' 1 '+ finished' s4 task c1)
$(u4row alpha 'a-kid-pane' '[b]' 1 '+ finished' s4 agent a1)
$(u4row alpha 'a2' '[b]' 1 '+ finished' s5)
$(u4row beta 'b1' '[b]' 1 '+ finished' s6)
$(u4row beta 'b2' '[b]' 1 '+ finished' s7)"
for awkname in mawk gawk; do
  bindir="$MAWK_BIN"; [ "$awkname" = gawk ] && bindir="$GAWK_BIN"
  assert_eq "U4 repo once ($awkname): named on a group's first row and on a child in another repo, blank otherwise" \
    "alpha beta - alpha - - beta -" "$(printf '%s\n' "$rows" | PATH="$bindir:$PATH" wb_format_for_display | repos)"
  assert_eq "U4 repo once ($awkname): the group restarts below the pinned family" \
    "alpha beta - alpha - sep alpha beta -" "$(printf '%s\n' "$rows" | WB_PICKER_SESSION=s1 PATH="$bindir:$PATH" wb_format_for_display | repos)"
  assert_eq "U4 repo once ($awkname): search mode names every row but agent panes, so a repo search finds them all" \
    "alpha beta beta alpha - alpha beta beta" "$(printf '%s\n' "$rows" | WB_PICKER_MODE=search PATH="$bindir:$PATH" wb_format_for_display | repos)"
done
assert_eq "U4 repo once: a blank cell keeps the row's real repo in field 2 for the keys" "alpha" \
  "$(printf '%s\n' "$rows" | wb_format_for_display | sed -n 6p | cut -f2)"

# --- needs you: bold magenta repo and name, on that row only ----------------
# (calm is in another repo so the waiting row heads its group and shows its repo)
rows="$(u4row beta 'calm' '[b]' 1 '+ finished' s1)
$(u4row alpha 'waiting' '[b]' 0 '! needs you' s2)
$(u4row alpha 'busy' '[b]' 2 '* working' s3)"
out="$(printf '%s\n' "$rows" | disp)"
assert_lacks "U4 a calm row is not magenta" "$MAG" "$(printf '%s\n' "$out" | line_n 1)"
assert_has   "U4 a needs-you row's repo is bold magenta" "${MAG}alpha" "$(printf '%s\n' "$out" | line_n 2)"
assert_has   "U4 ... and so is its name" "${MAG}waiting" "$(printf '%s\n' "$out" | line_n 2)"
assert_lacks "U4 a working row is not magenta" "$MAG" "$(printf '%s\n' "$out" | line_n 3)"
assert_lacks "U4 no reverse-video anywhere" "${ESC}[1;7m" "$out"

# --- finished and done share urank 1 but not a colour -----------------------
rows="$(u4row alpha 'fin-name' '[b]' 1 '+ finished' s1)
$(u4row alpha 'done-name' '[b]' 1 'o done' s2)
$(u4row alpha 'work-name' '[b]' 2 '* working' s3)
$(u4row alpha 'idle-name' '[b]' 3 '- idle' s4)"
out="$(printf '%s\n' "$rows" | disp)"
assert_has "U4 finished NAME is cyan"  "${C36}fin-name"  "$out"
assert_has "U4 done NAME is green"     "${N32}done-name" "$out"
assert_has "U4 working NAME is yellow" "${Y33}work-name" "$out"
assert_has "U4 idle NAME is grey"      "${G90}idle-name" "$out"

# --- the (here) row's own agent waiting on Jet stays grey, uncounted --------
snap="$FIXTURE/here.snap"; rm -f "$snap" "$snap".*
rows="$(u4row alpha 'mine' '[b]' 0 '! needs you' s1)
$(u4row alpha 'mine-pane' '[b]' 0 '! needs you' s1 agent a1)
$(u4row alpha 'later' '[b]' 1 '+ finished' s2)"
out="$(printf '%s\n' "$rows" | WB_PICKER_SESSION=s1 disp "$snap")"
assert_lacks "U4 (here) row whose agent needs Jet: no magenta on any row" "$MAG" "$out"
assert_eq "U4 ... its agent sub-row is grey too" "$G90" "$(printf '%s\n' "$out" | line_n 2 | cut -c1-5)"
assert_eq "U4 ... not in the snapshot: count 0" "count	0" "$(head -1 "$snap")"

# --- a multi-agent session: the waiting pane counts once, on its sub-row ----
snap="$FIXTURE/multi.snap"; rm -f "$snap" "$snap".*
owner="$(u4row alpha 'two-agents' '[b]' 0 '! needs you' s2 | awk -F'\t' -v OFS='\t' '{ $10 = 2; print }')"
rows="$owner
$(u4row alpha 'pane-wait' '[b]' 0 '! needs you' s2 agent)
$(u4row alpha 'pane-work' '[b]' 2 '* working' s2 agent)"
out="$(printf '%s\n' "$rows" | disp "$snap")"
assert_eq "U4 one waiting pane in a multi-agent session counts once" "count	1" "$(head -1 "$snap")"
assert_eq "U4 ... and the count lands on the waiting sub-row (pos 2)" "2	s2	1	0	t:0.0	agent" "$(awk -F'\t' '$3 == 1' "$snap")"
assert_has   "U4 ... the waiting sub-row is bold magenta" "${MAG}" "$(printf '%s\n' "$out" | line_n 2)"
assert_lacks "U4 ... the working sub-row is not" "$MAG" "$(printf '%s\n' "$out" | line_n 3)"

# --- dormant rows: status word picks the colour, never needs-you ------------
snap="$FIXTURE/dormant.snap"; rm -f "$snap" "$snap".*
rows="$(u4row alpha 'dn-doing' '[b]' 0 '~ doing 3d' '' task '' 5)
$(u4row alpha 'dn-review' '[b]' 10000000000 '~ review 2d' '' task '' 5)
$(u4row alpha 'dn-paused' '[b]' 20000000000 '~ paused 9d' '' task '' 5)"
out="$(printf '%s\n' "$rows" | WB_PICKER_SESSION=s1 disp)"
assert_has "U4 dormant doing is yellow"  "${Y33}dn-doing"  "$out"
assert_has "U4 dormant review is cyan"   "${C36}dn-review" "$out"
assert_has "U4 dormant paused is grey"   "${G90}dn-paused" "$out"
assert_lacks "U4 a dormant row at urank 0 is never magenta" "$MAG" "$out"

# --- render_rows: the live tab writes the snapshot, the dormant tab does not -
ORIG_CCR="$(save_fn collect_combined_rows)"
collect_combined_rows() {
  u4row alpha 'a1' '[b]' 1 '+ finished' s1
  u4row alpha 'a2' '[b]' 0 '! needs you' s2
  u4row beta 'b1' '[b]' 1 '+ finished' s3
}
mf="$FIXTURE/rr.mode"; vf="$FIXTURE/rr.view"; echo normal > "$mf"; echo live > "$vf"
rm -f "$vf.snap" "$vf.snap".*
render_rows "$mf" "$vf" >/dev/null
assert_eq "U4 render_rows (live, view file given) writes <view>.snap with the needs-you count" "count	1" "$(head -1 "$vf.snap" 2>/dev/null)"
printf 'keep-me\n' > "$vf.snap"
echo dormant > "$vf"; printf '%s\n' "$(u4row alpha 'dn' '[b]' 0 '~ doing 1d' '' task '' 5)" > "$vf.cache"
render_rows "$mf" "$vf" >/dev/null
assert_eq "U4 render_rows (dormant) leaves the live snapshot alone" "keep-me" "$(cat "$vf.snap")"
rm -f "$vf.snap"; render_rows "$mf" "$vf" >/dev/null
assert_eq "U4 render_rows (dormant) writes no snapshot" "no" "$([ -e "$vf.snap" ] && echo yes || echo no)"
echo live > "$vf"; : > "$vf.cache"
out="$(render_rows 2>/dev/null)"     # no view file at all
assert "U4 render_rows with no view file still renders the live rows" 'a1' "$out"
echo normal > "$mf"
assert_eq "U4 render_rows (normal mode) prints a repeated repo once" "-" \
  "$(render_rows "$mf" "$vf" | sed -n 3p | cut -f1 | strip_ansi | awk '{ print (substr($0, 1, 1) == " " ? "-" : $1) }')"
echo search > "$mf"
assert_eq "U4 render_rows (search mode) prints it on every row" "alpha" \
  "$(render_rows "$mf" "$vf" | sed -n 3p | cut -f1 | strip_ansi | awk '{ print $1 }')"
eval "$ORIG_CCR"
rm -f "$vf" "$vf.cache" "$vf.snap" "$mf"
picker_block="$(awk '/^picker\(\) \{/{p=1} p{print} p&&/^}/{exit}' "$WB")"
assert "U4 picker removes the snapshot with its other temp files" 'trap .rm -f .*"\$view_file\.snap"' "$picker_block"

# --- no group marker: only the waiting row itself is magenta ---------------
rows="$(u4row alpha 'a-first' '[b]' 1 '+ finished' s1)
$(u4row alpha 'a-wait' '[b]' 0 '! needs you' s2)"
out="$(printf '%s\n' "$rows" | disp)"
assert_eq "U4 the first row of a group with a waiting row keeps its own colour" "${C36}alpha" "$(printf '%s\n' "$out" | line_n 1 | cut -c1-10)"

# --- AGE ----------------------------------------------------------------------
now=1000000
rows="$(u4row alpha 'age-a' '[b]' 1 '+ finished' s1 task '' $((now - 30)))
$(u4row alpha 'age-b' '[b]' 1 '+ finished' s2 task '' $((now - 720)))
$(u4row alpha 'age-c' '[b]' 1 '+ finished' s3 task '' $((now - 10800)))
$(u4row alpha 'age-d' '[b]' 1 '+ finished' s4 task '' $((now - 345600)))
$(u4row alpha 'age-e' '[b]' 1 '+ finished' s5 task '' 0)
$(u4row alpha 'age-f' '[b]' 1 '+ finished' s5 agent a1 $((now - 30)))"
ages="$(printf '%s\n' "$rows" | WB_PICKER_NOW=$now disp | strip_ansi | sed -E 's/^.*(.{4})$/\1/' | sed -E 's/ +$//' | tr '\n' ',')"
assert_eq "U4 AGE: 30 s now, 12 min 12m, 3 h 3h, 4 days 4d, never -, agent sub-row blank" "now,12m,3h,4d,-,," "$ages"
assert_eq "U4 AGE column is exactly 4 characters" 4 "$(printf '%s\n' "$rows" | WB_PICKER_NOW=$now disp | strip_ansi | sed -E 's/^.{'"$((WB_COL_REPO + NW + WB_COL_BRANCH + 6))"'}//' | head -1 | char_len)"
nowreal="$(printf '%(%s)T' -1)"
out="$(u4row alpha 'age-r' '[b]' 1 '+ finished' s1 task '' $((nowreal - 120)) | env -u WB_PICKER_NOW bash -c "source '$WB'; set +e; export FZF_COLUMNS=200; wb_format_for_display" | cut -f1 | strip_ansi)"
assert "U4 AGE with WB_PICKER_NOW unset uses the clock" ' 2m +$' "$out"

# --- BRANCH keeps its tail when long, shows a short one whole ----------------
out="$(printf '%s\n%s\n' "$(u4row alpha 'br-long' '[feat/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaend-xy]' 1 '+ finished' s1)" "$(u4row alpha 'br-short' '[b-12]' 1 '+ finished' s2)" | disp | strip_ansi)"
assert "U4 a 40-char branch shows ... then its last characters" '\.\.\.a+end-xy  ' "$(printf '%s\n' "$out" | line_n 1)"
assert "U4 a short branch shows whole" ' b-12 {9,}[-0-9a-z]+ +$' "$(printf '%s\n' "$out" | line_n 2)"
assert_lacks "U4 ... with no ... in it" "..." "$(printf '%s\n' "$out" | line_n 2)"

# --- width: NAME fills the list pane; header and rows line up ---------------
for cols in 200 160 100; do
  export FZF_COLUMNS=$cols
  nw="$(wb_picker_name_width)"
  eval "nw_$cols=$nw"
  d="$(u4row alpha 'wide' '[branch]' 1 '+ finished' s1 task '' 5 | disp | strip_ansi)"
  h="$(wb_column_header | strip_ansi)"
  bh="${h%%BRANCH*}"; ah="${h%%AGE*}"; bd="${d%%branch *}"
  assert_eq "U4 width $cols: BRANCH header sits over the BRANCH cells" "${#bh}" "${#bd}"
  assert_eq "U4 width $cols: AGE header sits over the AGE cells" "${#ah}" "$((${#bd} + WB_COL_BRANCH + 2))"
  assert_eq "U4 width $cols: header and rows are equally wide (to the AGE cell)" "$((${#ah} + 3))" "$((${#d} - 1))"
done
export FZF_COLUMNS=200
assert "U4 NAME at 200 columns is wider than at 100" '^1$' "$([ "$nw_200" -gt "$nw_100" ] && echo 1 || echo 0)"
# fzf 0.65.2, picker()'s flags: a row of exactly 87 / 69 characters fits at 200 / 160 columns
for pair in 200:87 160:69; do
  export FZF_COLUMNS="${pair%%:*}"
  w="$(u4row alpha 'x' '[b]' 1 '+ finished' s1 | disp | strip_ansi | char_len)"
  assert_eq "U4 a row is exactly the list pane's text width at ${pair%%:*} columns" "${pair##*:}" "$w"
done
export FZF_COLUMNS=200
# no FZF_COLUMNS: the terminal width less the 2 padding columns stands in
tput() { echo 200; }
w200="$(unset FZF_COLUMNS; wb_picker_name_width)"
assert_eq "U4 without FZF_COLUMNS NAME comes from tput cols less the padding" "$nw_200" "$w200"
tput() { return 1; }
w160="$(unset FZF_COLUMNS; wb_picker_name_width)"
assert_eq "U4 without FZF_COLUMNS or a terminal NAME assumes 160 columns" "$nw_160" "$w160"
unset -f tput

# --- snapshot: positions of needs-you rows, their count, atomic -------------
snap="$FIXTURE/live.snap"; rm -f "$snap" "$snap".*
rows="$(u4row alpha 'mine' '[b]' 1 '+ finished' s1)
$(u4row alpha 'wait-1' '[b]' 0 '! needs you' s2)
$(u4row alpha 'pane' '[b]' 0 '! needs you' s1 agent a1)
$(u4row beta 'calm' '[b]' 1 '+ finished' s3)
$(u4row beta 'wait-2' '[b]' 0 '! needs you' s4)"
printf '%s\n' "$rows" | WB_PICKER_SESSION=s1 wb_format_for_display "$snap" >/dev/null
assert_eq "U4 snapshot: count line, then pos/session/needs/here/target/kind per data row" \
  "count	2
1	s1	0	1	t:0.0	task
2		0	0		sep
3	s2	1	0	t:0.0	task
4	s1	0	1	t:0.0	agent
5	s3	0	0	t:0.0	task
6	s4	1	0	t:0.0	task" "$(cat "$snap")"
assert_eq "U4 snapshot: no temp file left behind" "live.snap" "$(ls "$FIXTURE" | /usr/bin/grep '^live\.snap' | tr '\n' ' ' | sed 's/ $//')"
printf '' | wb_format_for_display "$snap" >/dev/null
assert_eq "U4 snapshot of an empty list: count 0 and nothing else" "count	0" "$(cat "$snap")"
rm -f "$snap"

# --- mawk and gawk agree on the whole slimmed display, snapshot included ------
mixed="$rows
$(u4row 'a-very-long-repo-name' 'caf— · résumé review of a very long task name that is cut somewhere past the width' '[feat/ünï·codé-a-very-long-branch]' 1 'o done' s6 task c1 $((now - 4000)))
$(u4row alpha 'dn' '[b]' 0 '~ review 3d' '' task '' $((now - 90000)))"
for awkname in mawk gawk; do
  bindir="$MAWK_BIN"; [ "$awkname" = gawk ] && bindir="$GAWK_BIN"
  rm -f "$snap"
  eval "out_$awkname=\"\$(printf '%s\n' \"\$mixed\" | PATH=\"$bindir:\$PATH\" WB_PICKER_SESSION=s1 wb_format_for_display \"\$snap\" | cat -v)\"; snap_$awkname=\"\$(cat \"\$snap\")\""
done
assert_eq "U4 mawk and gawk render the display identically" "$out_gawk" "$out_mawk"
assert_eq "U4 mawk and gawk write the same snapshot" "$snap_gawk" "$snap_mawk"
assert "U4 multi-byte name row is still valid UTF-8 under mawk" '^0$' "$(printf '%s\n' "$mixed" | PATH="$MAWK_BIN:$PATH" wb_format_for_display | cut -f1 | iconv -f UTF-8 -t UTF-8 >/dev/null 2>&1; echo $?)"
rm -f "$snap"

# ============================================================================
# U5 — header, legend, needs-you navigation
# ============================================================================
U5_DIR="$(mktemp -d -t wb-pg-u5.XXXXXX)"
U5_MF="$U5_DIR/mode"; U5_VF="$U5_DIR/view"
u5_reset() { # [mode] [view] — fresh picker files, no snapshot/focus/flag
  rm -f "$U5_VF".snap "$U5_VF".focus "$U5_VF".initpos
  printf '%s' "${1:-normal}" > "$U5_MF"; printf '%s' "${2:-live}" > "$U5_VF"
}
u5_snap() { # <count>, then one "pos session needs here target kind" string per row
  local count="$1" r; shift
  { printf 'count\t%s\n' "$count"
    for r in "$@"; do
      # shellcheck disable=SC2086
      set -- $r; printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$4" "$5" "${6:-task}"
    done; } > "$U5_VF.snap"
}
# a nine-row list: rows 3 and 7 need Jet
u5_nine() {
  u5_snap 2 "1 a 0 0 t:1 task" "2 b 0 0 t:2 task" "3 c 1 0 t:3 task" "4 d 0 0 t:4 task" "5 e 0 0 t:5 task" \
    "6 f 0 0 t:6 task" "7 g 1 0 t:7 task" "8 h 0 0 t:8 task" "9 i 0 0 t:9 task"
}

# --- the header: no follow-up/capture counts, no whole-store awk -------------
ORIG_PENDING="$(save_fn wb_pending_counts)"; ORIG_AGENTS="$(save_fn wb_live_agent_count)"
wb_pending_counts() { : > "$U5_DIR/pending-called"; echo "5 follow-ups pending · 2 unreviewed capture entries"; }
wb_live_agent_count() { echo 4; }
u5_reset; u5_snap 2 "1 a 1 0 t:1 task" "2 b 1 0 t:2 task"
hdr="$(wb_status_line normal live "$U5_VF.snap")"
plain="$(printf '%s' "$hdr" | strip_ansi)"
assert_lacks "U5 header: no follow-ups pending" "follow-ups pending" "$plain"
assert_lacks "U5 header: no capture count" "capture" "$plain"
assert_eq "U5 header: wb_pending_counts is not called" no "$([ -e "$U5_DIR/pending-called" ] && echo yes || echo no)"
assert_eq "U5 header: three lines" 3 "$(printf '%s\n' "$hdr" | wc -l)"
assert_eq "U5 header: every line is at most 120 characters" 0 \
  "$(printf '%s\n' "$plain" | char_len | awk '$1 > 120' | wc -l)"
assert_eq "U5 header: LIVE line carries the count and the agent total" \
  "wb · LIVE · 2 need you · 4 agents live (warn >= $WB_AGENT_WARN_AT)" "$(printf '%s\n' "$plain" | line_n 1)"
assert_eq "U5 header: missing snapshot file, no need-you part" \
  "wb · LIVE · 4 agents live (warn >= $WB_AGENT_WARN_AT)" "$(wb_status_line normal live "$U5_DIR/missing.snap" | strip_ansi | line_n 1)"
assert_eq "U5 header: no snapshot argument at all, same" \
  "wb · LIVE · 4 agents live (warn >= $WB_AGENT_WARN_AT)" "$(wb_status_line normal live | strip_ansi | line_n 1)"
assert_eq "U5 header: a count of zero reads 0 need you" "wb · LIVE · 0 need you · 4 agents live (warn >= $WB_AGENT_WARN_AT)" \
  "$(printf 'count\t0\n' > "$U5_DIR/zero.snap"; wb_status_line normal live "$U5_DIR/zero.snap" | strip_ansi | line_n 1)"
# the legend: each word in the colour wb_format_for_display gives it
leg="$(printf '%s\n' "$hdr" | line_n 2)"
assert_has "U5 legend (live): needs you is bold magenta" "${MAG}needs you" "$leg"
assert_has "U5 legend (live): finished is cyan" "${C36}finished" "$leg"
assert_has "U5 legend (live): done is green"    "${N32}done" "$leg"
assert_has "U5 legend (live): working is yellow" "${Y33}working" "$leg"
assert_has "U5 legend (live): idle is grey"     "${G90}idle" "$leg"
assert_has "U5 legend (live): the (here) tag is explained" "(here)" "$(printf '%s' "$leg" | strip_ansi)"
assert_lacks "U5 legend (live): no task statuses" "doing" "$(printf '%s' "$leg" | strip_ansi)"
# the same codes the rows use
rows="$(u4row alpha fin '[b]' 1 '+ finished' s1)
$(u4row alpha dn '[b]' 1 'o done' s2)
$(u4row alpha wk '[b]' 2 '* working' s3)"
out="$(printf '%s\n' "$rows" | disp)"
assert_has "U5 legend colours match the rows: cyan finished" "${C36}fin" "$out"
assert_has "U5 legend colours match the rows: green done"    "${N32}dn"  "$out"
assert_has "U5 legend colours match the rows: yellow working" "${Y33}wk" "$out"
# dormant: no count even when a snapshot exists, its own legend
dh="$(wb_status_line normal dormant "$U5_VF.snap")"
dplain="$(printf '%s' "$dh" | strip_ansi)"
assert_eq "U5 header (dormant): DORMANT line, no need-you count" \
  "wb · DORMANT · 4 agents live (warn >= $WB_AGENT_WARN_AT)" "$(printf '%s\n' "$dplain" | line_n 1)"
dleg="$(printf '%s\n' "$dh" | line_n 2)"
assert_has "U5 legend (dormant): doing is yellow" "${Y33}doing"  "$dleg"
assert_has "U5 legend (dormant): review is cyan"  "${C36}review" "$dleg"
assert_has "U5 legend (dormant): paused is grey"  "${G90}paused" "$dleg"
assert_lacks "U5 legend (dormant): no live statuses" "finished" "$(printf '%s' "$dleg" | strip_ansi)"
assert_eq "U5 header (dormant): three lines, none over 120 characters" "3 0" \
  "$(printf '%s\n' "$dh" | wc -l) $(printf '%s\n' "$dplain" | char_len | awk '$1 > 120' | wc -l)"
# the key hint
hint="$(printf '%s\n' "$plain" | line_n 3)"
for k in 'j/k' 'g/G' 'l/enter' 'h/q' 'u needs-you' 'n new' 'p down' 'r rename' 'b break' 'ctrl-x' 'ctrl-r' 'tab' '/ search'; do
  assert_has "U5 hint (normal) lists '$k'" "$k" "$hint"
done
assert_eq "U5 hint (dormant tab) is the same normal hint" "$hint" "$(printf '%s\n' "$dplain" | line_n 3)"
shint="$(wb_status_line search live "$U5_VF.snap" | strip_ansi | line_n 3)"
assert_has "U5 hint (search) keeps its own text" "SEARCH: type to filter" "$shint"
assert_lacks "U5 hint (search) is not the normal hint" "ctrl-x" "$shint"
# _mode_header reads the mode, view and snapshot itself
u5_reset search live; u5_snap 2 "1 a 1 0 t:1 task" "2 b 1 0 t:2 task"
assert_has "U5 _mode_header: search mode shows the search hint" "SEARCH: type to filter" "$(_mode_header "$U5_MF" "$U5_VF")"
printf 'normal' > "$U5_MF"
assert_has "U5 _mode_header: carries the count from <view>.snap" "2 need you" "$(_mode_header "$U5_MF" "$U5_VF" | strip_ansi)"
printf 'dormant' > "$U5_VF"
assert_lacks "U5 _mode_header: the dormant view has no count" "need you" "$(_mode_header "$U5_MF" "$U5_VF" | strip_ansi | line_n 1)"
eval "$ORIG_PENDING"; eval "$ORIG_AGENTS"

# --- _next-needs ------------------------------------------------------------
u5_reset; u5_nine
nn() { FZF_POS="$1" _next_needs "$U5_MF" "$U5_VF"; }
assert_eq "U5 next-needs: from 3 (needs 3,7) goes to 7" "pos(7)" "$(nn 3)"
assert_eq "U5 next-needs: from 7 wraps to 3"            "pos(3)" "$(nn 7)"
assert_eq "U5 next-needs: from a calm row 5 goes to 7"  "pos(7)" "$(nn 5)"
assert_eq "U5 next-needs: from row 1 goes to 3"         "pos(3)" "$(nn 1)"
assert_eq "U5 next-needs: from the last row wraps to 3" "pos(3)" "$(nn 9)"
u5_snap 1 "1 a 0 0 t:1 task" "2 b 1 0 t:2 task" "3 c 0 0 t:3 task"
assert_eq "U5 next-needs: a single needs-you row is its own next" "pos(2)" "$(nn 2)"
u5_snap 0 "1 a 0 0 t:1 task" "2 b 0 0 t:2 task"
assert_eq "U5 next-needs: no needs-you rows prints nothing" "" "$(nn 1)"
u5_snap 0
assert_eq "U5 next-needs: a snapshot with no rows prints nothing" "" "$(nn 1)"
rm -f "$U5_VF.snap"
assert_eq "U5 next-needs: no snapshot prints nothing" "" "$(nn 1)"
u5_nine; printf 'dormant' > "$U5_VF"
assert_eq "U5 next-needs: the dormant tab prints nothing" "" "$(nn 3)"
printf 'live' > "$U5_VF"; printf 'search' > "$U5_MF"
assert_eq "U5 next-needs: search mode prints nothing (positions refer to the filtered list)" "" "$(nn 3)"

# --- _initial-pos: the first call -------------------------------------------
ip() { _initial_pos "$U5_MF" "$U5_VF"; }
u5_reset; u5_nine
assert_eq "U5 initial-pos: first call lands on the first needs-you row" "pos(3)" "$(ip)"
assert_eq "U5 initial-pos: ... and leaves its one-shot flag" yes "$([ -e "$U5_VF.initpos" ] && echo yes || echo no)"
assert_eq "U5 initial-pos: second call, no focus recorded, prints nothing" "" "$(ip)"
u5_reset; u5_snap 1 "1 me 0 1 t:1 task" "2 x 0 0 t:2 task" "3 y 1 0 t:3 task"
assert_eq "U5 initial-pos: needs-you beats the row after (here)" "pos(3)" "$(ip)"
u5_reset; u5_snap 0 "1 a 0 0 t:1 task" "2 me 0 1 t:2 task" "3 b 0 0 t:3 task" "4 c 0 0 t:4 task"
assert_eq "U5 initial-pos: no needs-you, the row after (here)" "pos(3)" "$(ip)"
u5_reset; u5_snap 0 "1 me 0 1 t:1 task" "2 me 0 1 t:2 agent" "3 b 0 0 t:3 task"
assert_eq "U5 initial-pos: the row after (here) and its agent sub-row" "pos(3)" "$(ip)"
u5_reset; u5_snap 0 "1 a 0 0 t:1 task" "2 me 0 1 t:2 task"
assert_eq "U5 initial-pos: (here) is last, so pos(1)" "pos(1)" "$(ip)"
u5_reset; u5_snap 0 "1 a 0 0 t:1 task" "2 b 0 0 t:2 task"
assert_eq "U5 initial-pos: no (here) row (no current session), so pos(1)" "pos(1)" "$(ip)"
u5_reset; u5_snap 0 "1 me 0 1 t:1 task" "2 . 0 0 . sep" "3 b 0 0 t:3 task"
sed -i 's/\t\.\t/\t\t/g' "$U5_VF.snap"
assert_eq "U5 initial-pos: the row after (here) skips the separator" "pos(3)" "$(ip)"
u5_reset; u5_snap 0
assert_eq "U5 initial-pos: an empty list prints nothing" "" "$(ip)"
u5_reset
assert_eq "U5 initial-pos: no snapshot prints nothing" "" "$(ip)"
u5_reset normal dormant; u5_nine
assert_eq "U5 initial-pos: the dormant tab prints nothing" "" "$(ip)"
u5_reset search live; u5_nine
assert_eq "U5 initial-pos: search mode prints nothing" "" "$(ip)"
assert_eq "U5 initial-pos: ... and does not spend the one-shot" no "$([ -e "$U5_VF.initpos" ] && echo yes || echo no)"

# --- _initial-pos: later calls restore the focused row ----------------------
focus() { printf '%s\t%s\t%s\n' "$1" "$2" "$3" > "$U5_VF.focus"; }
u5_reset; u5_nine; ip >/dev/null     # spend the one-shot
focus g t:7 task
assert_eq "U5 restore: the focused session's current position" "pos(7)" "$(ip)"
u5_snap 1 "1 new 0 0 t:0 task" "2 a 0 0 t:1 task" "3 b 0 0 t:2 task" "4 c 1 0 t:3 task" "5 d 0 0 t:4 task" "6 e 0 0 t:5 task" \
  "7 f 0 0 t:6 task" "8 g 0 0 t:7 task" "9 h 0 0 t:8 task"
assert_eq "U5 restore: follows the row to its new position (a session started above)" "pos(8)" "$(ip)"
u5_snap 1 "1 a 0 0 t:1 task" "2 b 0 0 t:2 task" "3 g 1 0 t:7 task"
assert_eq "U5 restore: a status flip does not lose the row" "pos(3)" "$(ip)"
u5_snap 1 "1 a 0 0 t:1 task" "2 b 1 0 t:2 task"
assert_eq "U5 restore: the focused session is gone, prints nothing" "" "$(ip)"
: > "$U5_VF.focus"
assert_eq "U5 restore: an empty focus file prints nothing" "" "$(ip)"
rm -f "$U5_VF.focus"
assert_eq "U5 restore: no focus file prints nothing" "" "$(ip)"
focus "" "" task
assert_eq "U5 restore: a focus record with no session (a dormant row) prints nothing" "" "$(ip)"
# an agent sub-row shares its session AND pane with the owner row; the kind tells them apart
u5_snap 1 "1 own 0 0 t:1 task" "2 two 0 0 t:5 task" "3 two 1 0 t:5 agent" "4 two 0 0 t:6 agent" "5 z 0 0 t:9 task"
focus two t:5 agent
assert_eq "U5 restore: the agent sub-row, not its owner row (same session, same pane)" "pos(3)" "$(ip)"
focus two t:5 task
assert_eq "U5 restore: the owner row, not its sub-row" "pos(2)" "$(ip)"
focus two t:6 agent
assert_eq "U5 restore: another sub-row of the same session" "pos(4)" "$(ip)"
focus two t:99 agent
assert_eq "U5 restore: pane gone, falls back to the session's first row" "pos(2)" "$(ip)"
# the owner row's pane is whichever is most urgent, so a status change moves it
# to another pane; the owner row must still be found, not the old pane's sub-row
u5_snap 1 "1 own 0 0 t:1 task" "2 two 0 0 t:6 task" "3 two 0 0 t:5 agent" "4 two 1 0 t:6 agent" "5 z 0 0 t:9 task"
focus two t:5 task
assert_eq "U5 restore: the owner row, after a different pane became the most urgent" "pos(2)" "$(ip)"
u5_snap 0 "1 me 0 1 t:1 task" "2 me 0 1 t:2 agent" "3 b 0 0 t:3 task"
focus me t:2 agent
assert_eq "U5 restore: the (here) session's sub-row" "pos(2)" "$(ip)"
printf 'dormant' > "$U5_VF"
assert_eq "U5 restore: the dormant tab prints nothing" "" "$(ip)"
printf 'live' > "$U5_VF"; printf 'search' > "$U5_MF"
assert_eq "U5 restore: search mode prints nothing" "" "$(ip)"
printf 'normal' > "$U5_MF"

# --- the formatter writes what the helpers read -----------------------------
u5_reset
rows="$(u4row alpha 'mine' '[b]' 1 '+ finished' s1)
$(u4row alpha 'calm' '[b]' 1 '+ finished' s2)
$(u4row beta 'wait-a' '[b]' 0 '! needs you' s3)
$(u4row beta 'calm-b' '[b]' 1 'o done' s4)
$(u4row beta 'wait-b' '[b]' 0 '! needs you' s5)"
printf '%s\n' "$rows" | WB_PICKER_SESSION=s1 wb_format_for_display "$U5_VF.snap" >/dev/null
# positions count the separator row under the pinned family (pos 2)
assert_eq "U5 end to end: the first call lands on the first waiting row" "pos(4)" "$(ip)"
assert_eq "U5 end to end: u from there goes to the next waiting row" "pos(6)" "$(nn 4)"
assert_eq "U5 end to end: u from the last waiting row wraps" "pos(4)" "$(nn 6)"
assert_has "U5 end to end: the header count is the snapshot's" "2 need you" "$(wb_status_line normal live "$U5_VF.snap" | strip_ansi)"

# --- picker(): the binds, the trap, the dispatch ----------------------------
picker_block="$(awk '/^picker\(\) \{/{p=1} p{print} p&&/^}/{exit}' "$WB")"
load_bind="$(printf '%s\n' "$picker_block" | /usr/bin/grep -F -- '"load:')"
assert "U5 picker: the load bind keeps its exact reload prefix" '"load:reload\(sleep 3; \\"\$SELF\\" render \\"\$mode_file\\" \\"\$view_file\\"\)\+refresh-preview' "$load_bind"
assert "U5 picker: the load bind then refreshes the header" '\+transform-header\(\\"\$SELF\\" _mode-header \\"\$mode_file\\" \\"\$view_file\\"\)' "$load_bind"
assert "U5 picker: the load bind then runs _initial-pos" '\+transform\(\\"\$SELF\\" _initial-pos \\"\$mode_file\\" \\"\$view_file\\"\)"' "$load_bind"
assert "U5 picker: u:transform runs _next-needs" '"u:transform\(\\"\$SELF\\" _next-needs \\"\$mode_file\\" \\"\$view_file\\"\)"' "$picker_block"
navkeys_line="$(printf '%s\n' "$picker_block" | /usr/bin/grep -F "local navkeys=")"
assert "U5 picker: u is in the NORMAL key list (so SEARCH unbinds it)" "navkeys='[^']*,u,[^']*'" "$navkeys_line"
assert "U5 picker: the other nav keys are still in the list" "navkeys='j,k,g,G,q,i,r,b,p,n,u,/'" "$navkeys_line"
focus_bind="$(printf '%s\n' "$picker_block" | /usr/bin/grep -F -- '"focus:')"
assert "U5 picker: the focus bind keeps the preview label" 'focus:transform-preview-label\(.*_preview-label \{7\} \{9\}\)' "$focus_bind"
assert "U5 picker: ... and chains the focus record (session {8}, target {7}, kind {10}) onto it, skipping dormant rows (no session)" \
  '_preview-label \{7\} \{9\}\)\+execute-silent\(\[ -z \{8\} \] \|\| printf .%s\\t%s\\t%s\\n. \{8\} \{7\} \{10\} > \\"\$view_file\.focus\\"\)"' "$focus_bind"
assert_eq "U5 picker: exactly one focus bind (fzf keeps only the last per event)" 1 "$(printf '%s\n' "$picker_block" | /usr/bin/grep -cF -- '"focus:')"
assert "U5 picker: the trap also removes the focus record and the one-shot flag" \
  'trap .rm -f .*"\$view_file\.focus" "\$view_file\.initpos"' "$picker_block"
assert "U5 picker: the first header is built from the snapshot the first render wrote" \
  ' --header="\$\(wb_status_line normal live "\$view_file\.snap"\)"' "$picker_block"
render_ln="$(printf '%s\n' "$picker_block" | /usr/bin/grep -n 'rendered="$(render_rows' | head -1 | cut -d: -f1)"
fzf_ln="$(printf '%s\n' "$picker_block" | /usr/bin/grep -n '| fzf ' | head -1 | cut -d: -f1)"
assert_eq "U5 picker: the list renders (writing the snapshot) before fzf starts" 1 "$([ -n "$render_ln" ] && [ -n "$fzf_ln" ] && [ "$render_ln" -lt "$fzf_ln" ] && echo 1 || echo 0)"
assert "U5 picker: the ctrl-x bind is unchanged" 'ctrl-x:become\(\\"\$SELF\\" _ctrl-x \{10\} \{8\} \{7\} \{9\}\)' "$picker_block"
status_body="$(awk '/^wb_status_line\(\) \{/{p=1} p{print} p&&/^}/{exit}' "$WB")"
assert_lacks "U5 wb_status_line no longer calls wb_pending_counts" "wb_pending_counts" "$status_body"
dispatch="$(awk '/^  case / {p=1} p{print}' "$WB")"
assert "U5 dispatch: _initial-pos verb" '^    _initial-pos\) +shift; _initial_pos "\$@"' "$dispatch"
assert "U5 dispatch: _next-needs verb" '^    _next-needs\) +shift; _next_needs "\$@"' "$dispatch"
rm -rf "$U5_DIR"

# ============================================================================
# U6 — _preview helper
# ============================================================================
PV_DIR="$(mktemp -d -t wb-pg-preview.XXXXXX)"

mk_task() { # <file> <handoffs-block>
  cat > "$1" <<EOT
---
repo: alpha
status: active
branch: feat/x
---
# The Task Title

## Context

Some context.

## Handoffs
$2

## Decisions

none
EOT
}

# --- two rich Handoffs, then a later automatic one: the second rich wins ----
mk_task "$PV_DIR/rich.md" '
### 2026-10-25 17:00 — wb-save

**Done:** first rich entry

### 2026-10-25 19:07 — wb-save

**Done:** second rich entry
**Next:** keep going

### 2026-10-25 20:00 — wb resume (auto)

resumed automatically'
out="$(_preview "" "$PV_DIR/rich.md" task | strip_ansi)"
assert_eq "U6 preview: task starts with its title" "The Task Title" "$(printf '%s\n' "$out" | sed -n 1p)"
assert_eq "U6 preview: second line is status, branch and when the Handoff was saved" "active · feat/x · saved 2026-10-25 19:07" "$(printf '%s\n' "$out" | sed -n 2p)"
assert "U6 preview: the Handoff's fields are laid out under labels" 'keep going' "$out"
assert_eq "U6 preview: Next comes before Done" "Next Done" "$(printf '%s\n' "$out" | /usr/bin/grep -xE 'Next|Done' | paste -sd' ')"
assert_eq "U6 preview: no raw **Field:** markup" 0 "$(printf '%s\n' "$out" | /usr/bin/grep -c '\*\*')"
assert_eq "U6 preview: no earlier rich entry" 0 "$(printf '%s\n' "$out" | /usr/bin/grep -c 'first rich entry')"
assert_eq "U6 preview: no automatic entry" 0 "$(printf '%s\n' "$out" | /usr/bin/grep -c '(auto)\|resumed automatically')"
assert_eq "U6 preview: entry stops before the next ## section" 0 "$(printf '%s\n' "$out" | /usr/bin/grep -c 'Decisions\|^none')"
_preview "" "$PV_DIR/rich.md" task >/dev/null; assert_eq "U6 preview: task exits 0" 0 "$?"

# --- no Handoffs: title and status line only --------------------------------
mk_task "$PV_DIR/bare.md" ''
out="$(_preview "" "$PV_DIR/bare.md" task | strip_ansi)"
assert_eq "U6 preview: no Handoffs prints exactly title + status line" \
  "The Task Title"$'\n'"active · feat/x" "$out"

# --- the layout: Next, its run directive, In flight, then Done dimmed -------
mk_task "$PV_DIR/fields.md" '
### 2026-10-25 21:00 — wb-save
**Done:** built it
  and tested it
**In flight:** nothing
**Next:** open the PR
```run
/ce-commit-push-pr
```'
raw="$(_preview "" "$PV_DIR/fields.md" task)"; out="$(printf '%s\n' "$raw" | strip_ansi)"
assert_eq "U6 preview: fields in reading order" "Next In flight Done" "$(printf '%s\n' "$out" | /usr/bin/grep -xE 'Next|In flight|Done' | paste -sd' ')"
assert_eq "U6 preview: the run directive is one line under Next" "run: /ce-commit-push-pr" "$(printf '%s\n' "$out" | /usr/bin/grep '^run:')"
assert "U6 preview: a field's continuation lines stay with it" 'built it.*and tested it' "$(printf '%s\n' "$out" | paste -sd' ')"
assert "U6 preview: Done's text is dimmed" "$(printf '\033')\\[90mbuilt it" "$raw"
assert_eq "U6 preview: no code fence shown" 0 "$(printf '%s\n' "$out" | /usr/bin/grep -c '```')"

# --- an entry with no **Field:** lines prints as written ---------------------
mk_task "$PV_DIR/plainhand.md" '
### 2026-10-25 21:30 — note
Just a free-form note.'
out="$(_preview "" "$PV_DIR/plainhand.md" task | strip_ansi)"
assert "U6 preview: a free-form Handoff body is shown as written" 'Just a free-form note\.' "$out"

# --- neither file nor git dir ------------------------------------------------
out="$(_preview "" "$PV_DIR/missing" repo)"; rc=$?
assert_eq "U6 preview: unknown ref prints the fallback" "nothing to preview" "$out"
assert_eq "U6 preview: fallback exits 0" 0 "$rc"
mkdir "$PV_DIR/plain"
assert_eq "U6 preview: a non-git dir is also the fallback" "nothing to preview" "$(_preview "" "$PV_DIR/plain" repo)"

# --- git dir: status, or "clean" ---------------------------------------------
git init -q "$PV_DIR/repo"
assert_eq "U6 preview: clean git dir says clean" "clean" "$(_preview "" "$PV_DIR/repo" repo)"
: > "$PV_DIR/repo/new.txt"
assert "U6 preview: dirty git dir shows status" 'new\.txt' "$(_preview "" "$PV_DIR/repo" repo)"

# --- pane: trailing blanks stripped, tailed to FZF_PREVIEW_LINES -------------
wb_capture_pane() {
  local i
  for i in $(seq 1 15); do printf 'line %s\n' "$i"; done
  for i in $(seq 1 20); do
    if [ $((i % 2)) -eq 0 ]; then printf '\n'; else printf '\033[0m   \n'; fi
  done
}
out="$(FZF_PREVIEW_LINES=10 _preview "s:0.0" "/ignored" agent)"
assert_eq "U6 preview: pane tail is the last 10 lines before the blank tail" \
  "line 6 line 7 line 8 line 9 line 10 line 11 line 12 line 13 line 14 line 15" "$(printf '%s\n' "$out" | tr '\n' ' ' | sed 's/ $//')"
assert_eq "U6 preview: a pane target wins over a file ref" "line 15" "$(FZF_PREVIEW_LINES=1 _preview "s:0.0" "$PV_DIR/rich.md" agent)"

# --- the label names what is shown -------------------------------------------
assert_eq "U6 label: pane"       " pane "       "$(_preview_label "s:0.0" "$PV_DIR/rich.md")"
assert_eq "U6 label: task"       " task "       "$(_preview_label "" "$PV_DIR/rich.md")"
assert_eq "U6 label: git status" " git status " "$(_preview_label "" "$PV_DIR/repo")"
assert_eq "U6 label: nothing"    " wb "         "$(_preview_label "" "$PV_DIR/missing")"

# --- dispatch: both verbs are wired (and hidden from wb help as internal) ----
dispatch="$(awk '/^  case / {p=1} p{print}' "$WB")"
assert "U6 dispatch: _preview verb" '^    _preview\) +shift; _preview "\$@"' "$dispatch"
assert "U6 dispatch: _preview-label verb" '^    _preview-label\) +shift; _preview_label "\$@"' "$dispatch"
rm -rf "$PV_DIR"

[ "$fail" -eq 0 ] && echo "ALL PASS" || echo "FAILURES"
exit "$fail"
