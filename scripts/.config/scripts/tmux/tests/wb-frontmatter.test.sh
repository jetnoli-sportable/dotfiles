#!/usr/bin/env bash
# Tests for the frontmatter writer and the small helpers whose only tests
# went with the bash board: wb_fm_write, cmd_reviewed, wb_tsv_split and
# _wb_tags_parse. cmd_reviewed needs tmux sessions, so a shim pins every
# tmux call to one private socket.
# Run: bash scripts/.config/scripts/tmux/tests/wb-frontmatter.test.sh
set -uo pipefail

WB="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/wb.sh"
FIXTURE="$(mktemp -d -t wb-frontmatter.XXXXXX)"
FIXTURE_BIN="$FIXTURE/bin"
mkdir -p "$FIXTURE_BIN" "$FIXTURE/tasks" "$FIXTURE/code"
PREFIX="wb-fm-test-$$"
SOCK="wb-fm-sock-$$"
REAL_TMUX="$(command -v tmux)"
printf '#!/usr/bin/env bash\nexec %q -L %q -f /dev/null "$@"\n' "$REAL_TMUX" "$SOCK" >"$FIXTURE_BIN/tmux"
chmod +x "$FIXTURE_BIN/tmux"
PATH="$FIXTURE_BIN:$PATH"

cleanup() {
  "$REAL_TMUX" -L "$SOCK" kill-server 2>/dev/null || true
  rm -rf "$FIXTURE"
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
assert_eq() { # <desc> <expected> <actual>
  if [ "$2" = "$3" ]; then
    echo "ok   - $1"
  else
    echo "FAIL - $1"
    echo "       expected: $(printf '%q' "$2")"
    echo "       got:      $(printf '%q' "$3")"
    fail=1
  fi
}

# shellcheck disable=SC1090
source "$WB"
set +e # wb.sh sets -e; this test captures non-zero exits
TASKS_DIR="$FIXTURE/tasks"
CODE_DIR="$FIXTURE/code"

F="$FIXTURE/fm.md"
fm() { printf -- "$1" >"$F"; }

# =============================================================================
# wb_fm_write
# =============================================================================
fm '---\nstatus: doing\nrepo: proj\n---\n# Title\n'
wb_fm_write "$F" status done closed 2026-11-28
assert_eq "fm_write: several keys in one pass, missing key inserted before ---" \
  $'---\nstatus: done\nrepo: proj\nclosed: 2026-11-28\n---\n# Title' "$(cat "$F")"

fm '---\nstatus: doing\nrepo: proj\nsize:\nbranch: b\n---\n'
wb_fm_write "$F" --after repo priority high
assert_eq "fm_write: --after puts a missing key after that key's line" \
  $'---\nstatus: doing\nrepo: proj\npriority: high\nsize:\nbranch: b\n---' "$(cat "$F")"

fm '---\nstatus: doing  # a note\n---\n'
wb_fm_write "$F" status paused
assert_eq "fm_write: keeps a trailing inline comment" \
  $'---\nstatus: paused  # a note\n---' "$(cat "$F")"

fm '---\nstatus: doing\nstatus: review\n---\n'
wb_fm_write "$F" status done
assert_eq "fm_write: duplicate lines collapse to the first" \
  $'---\nstatus: done\n---' "$(cat "$F")"

fm '---\nsize: L\nreviewed:\n---\n'
wb_fm_write "$F" '?size' '' '?reviewed' '' '?created' 2026-11-28
assert_eq "fm_write: ?key keeps a non-blank value, leaves a blank one, fills a missing one" \
  $'---\nsize: L\nreviewed: \ncreated: 2026-11-28\n---' "$(cat "$F")"

fm '---\nsize:\nsize: L\n---\n'
wb_fm_write "$F" '?size' ''
assert_eq "fm_write: ?key keeps a later non-blank duplicate and drops the blank one" \
  $'---\nsize: L\n---' "$(cat "$F")"

fm '---\ntags: []\n---\n'
wb_fm_write "$F" tags 'a\nstatus: done'
assert_eq "fm_write: a literal backslash-n stays on one line" \
  $'---\ntags: a\\nstatus: done\n---' "$(cat "$F")"

fm '---\nstatus: doing\n# no closing marker\n'
before="$(cat "$F")"
wb_fm_write "$F" status done
rc=$?
assert "fm_write: unclosed frontmatter -> non-zero exit" '^[1-9]' "$rc"
assert_eq "fm_write: unclosed frontmatter leaves the file as it was" "$before" "$(cat "$F")"
leftover="$(find "$FIXTURE" -maxdepth 1 -name 'fm.md.tmp.*' | wc -l)"
assert_eq "fm_write: no temp file left behind on failure" "0" "$leftover"

fm '# no frontmatter\n'
wb_fm_write "$F" status done
rc=$?
assert_eq "fm_write: a file without frontmatter is left alone" "0|# no frontmatter" "$rc|$(cat "$F")"

# =============================================================================
# cmd_reviewed
# =============================================================================
mk_task() { # <file> <repo> <branch>
  printf -- '---\nstatus: doing\nrepo: %s\nbranch: %s\nworktree: .worktrees/x\ntags: []\ncreated: 2026-07-07\nclosed:\n---\n# Title\n' \
    "$2" "$3" >"$TASKS_DIR/$1"
}
mk_session() { # <suffix> <repo> <slug>
  tmux new-session -d -s "${PREFIX}-$1" 2>/dev/null
  tmux set-option -t "=${PREFIX}-$1:" @wb_repo "$2" >/dev/null
  tmux set-option -t "=${PREFIX}-$1:" @wb_slug "$3" >/dev/null
}

mk_task 'proj--feat-review-b.md' proj feat/review-b
mk_session reviewb proj feat/review-b
out="$(cmd_reviewed "${PREFIX}-reviewb" 2>&1)"
rc=$?
assert_eq "cmd_reviewed: exits 0" "0" "$rc"
assert "cmd_reviewed: confirmation message" 'marked reviewed' "$out"
assert_eq "cmd_reviewed: stamps today's date" "$(date +%F)" \
  "$(wb_get_frontmatter "$TASKS_DIR/proj--feat-review-b.md" reviewed)"

out="$(
  unset TMUX
  cmd_reviewed 2>&1
)"
rc=$?
assert "cmd_reviewed: no session arg + no TMUX -> non-zero exit" '^[1-9]' "$rc"
assert "cmd_reviewed: no session arg + no TMUX -> clear error" 'run inside the target session' "$out"

tmux new-session -d -s "${PREFIX}-bare" 2>/dev/null
out="$(cmd_reviewed "${PREFIX}-bare" 2>&1)"
rc=$?
assert "cmd_reviewed: bare session -> non-zero exit" '^[1-9]' "$rc"
assert "cmd_reviewed: bare session -> clear error" 'not a wb task session' "$out"

# =============================================================================
# wb_tsv_split: the awk-era semantics it keeps
# =============================================================================
wb_tsv_split "a"$'\t\t'"b"$'\t' _tsv
assert_eq "tsv_split keeps empty + trailing-empty fields" "4|a||b|" "${#_tsv[@]}|${_tsv[0]}|${_tsv[1]}|${_tsv[2]}|${_tsv[3]}"
wb_tsv_split "" _tsv
assert_eq "tsv_split: empty string -> no fields" "0" "${#_tsv[@]}"
wb_tsv_split $'x\ty\n\nz' _tsv
assert_eq "tsv_split: blank line in a multi-line record adds no fields" "3|x|y|z" "${#_tsv[@]}|${_tsv[0]}|${_tsv[1]}|${_tsv[2]}"
wb_tsv_split $'a\rb\t\\c\td\xc3\xa9\t' _tsv
assert_eq "tsv_split: CR, backslash, valid multibyte pass through" \
  "4|a"$'\r'"b|\\c|d"$'\xc3\xa9'"|" "${#_tsv[@]}|${_tsv[0]}|${_tsv[1]}|${_tsv[2]}|${_tsv[3]}"
# Incomplete UTF-8 tails, under C and under each UTF-8 locale the image has
# (the Dockerfile generates en_US.UTF-8 for this loop).
for _loc in C en_US.UTF-8 C.UTF-8; do
  [ "$_loc" = C ] || locale -a 2>/dev/null | /usr/bin/grep -qix "${_loc/UTF-8/utf8}\|$_loc" || continue
  _saved_lc="${LC_ALL-}"
  _had_lc="${LC_ALL+x}"
  export LC_ALL="$_loc"
  wb_tsv_split $'a\tb\xc3' _t
  assert_eq "tsv_split [$_loc]: trailing incomplete UTF-8 byte keeps both fields" "2|a|b"$'\xc3' "${#_t[@]}|${_t[0]}|${_t[1]}"
  wb_tsv_split $'\xc3' _t
  assert_eq "tsv_split [$_loc]: a lone incomplete byte is one field" "1|"$'\xc3' "${#_t[@]}|${_t[0]}"
  wb_tsv_split $'x\ny\xe2\x80' _t
  assert_eq "tsv_split [$_loc]: incomplete 3-byte tail on the last line keeps the record" "2|x|y"$'\xe2\x80' "${#_t[@]}|${_t[0]}|${_t[1]}"
  wb_tsv_split $'\r\xf0\x9f\n\xffa' _t
  assert_eq "tsv_split [$_loc]: incomplete bytes before a newline do not merge records" "2|"$'\r\xf0\x9f'"|"$'\xffa' "${#_t[@]}|${_t[0]}|${_t[1]}"
  assert_eq "tsv_split [$_loc]: LC_ALL is restored after the call" "$_loc" "$LC_ALL"
  if [ -n "$_had_lc" ]; then export LC_ALL="$_saved_lc"; else unset LC_ALL; fi
done

# =============================================================================
# _wb_tags_parse: bare, csv and list forms
# =============================================================================
assert_eq "tags: bare scalar parses to one token" "solo," "$(_wb_tags_parse 'solo' | sort | tr '\n' ',')"
assert_eq "tags: csv form" "a,b," "$(_wb_tags_parse 'a, b' | sort | tr '\n' ',')"
assert_eq "tags: list form agrees with csv" "a,b," "$(_wb_tags_parse '[a, b]' | sort | tr '\n' ',')"
assert_eq "tags: empty list -> no tokens" "" "$(_wb_tags_parse '[]')"

# =============================================================================
# dispatcher: every listed verb routes to a defined function
# =============================================================================
read_list() { awk -v n="$1" '$0 ~ "^  " n "=\\($" {p=1; next} p && /^  \)$/ {exit} p' "$WB" | tr -s ' ' '\n' | tr -d '"' | /usr/bin/grep -v '^$'; }
missing=""
while read -r v; do declare -F "cmd_${v//-/_}" >/dev/null || missing+=" $v"; done < <(read_list wb_verbs)
while read -r v; do declare -F "${v//-/_}" >/dev/null || missing+=" $v"; done < <(read_list picker_verbs)
assert_eq "dispatcher: every wb_verbs/picker_verbs name has a function" "" "$missing"
assert "dispatcher: the lists were read" '^[0-9]{2}' "$(read_list wb_verbs | wc -l | tr -d ' ')"

[ "$fail" -eq 0 ] && echo "ALL PASS" || {
  echo "SOME FAILED"
  exit 1
}
