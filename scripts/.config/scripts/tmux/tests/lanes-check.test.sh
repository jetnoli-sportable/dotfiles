#!/usr/bin/env bash
# Tests for lanes-check.sh — the pre-flight that stops an unattended
# "spare-token lanes" work item when its files could conflict with live work
# (other worktrees' uncommitted edits, branches without a PR, open PRs).
#
# Plain-bash assertions, same convention as risky-command-guard.test.sh. Every
# case builds its own throwaway origin + clone + worktrees under a mktemp dir
# and points LANES_GH at a stub that prints canned `gh pr list` JSON, so no
# network, no real repo and no GitHub is touched. Needs git (with
# `merge-tree --write-tree`, 2.38+) and jq.
#
# Run: bash scripts/.config/scripts/tmux/tests/lanes-check.test.sh
# CHECK=/path/to/copy.sh runs the same cases against another copy of the script.
set -uo pipefail

CHECK="${CHECK:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lanes-check.sh}"
T="$(mktemp -d -t lanes-check.XXXXXX)"
trap 'rm -rf "$T"' EXIT
export GIT_CONFIG_NOSYSTEM=1

fail=0
[ -x "$CHECK" ] || {
  echo "FAIL - script is not executable: $CHECK"
  fail=1
}

N=0
new_fixture() { # sets F (fixture dir), R (clone), HOME, LANES_GH
  N=$((N + 1))
  F="$T/f$N"
  R="$F/repo"
  mkdir -p "$F/home" "$F/stub"
  export HOME="$F/home"
  unset LANES_STOW_ROOTS
  git init -q --bare -b development "$F/origin.git"
  git clone -q "$F/origin.git" "$R" 2>/dev/null
  git -C "$R" config user.name t
  git -C "$R" config user.email t@example.com
  git -C "$R" checkout -q -b development
  mkdir -p "$R/docs/guides" "$R/scripts"
  seq 1 10 | sed 's/^/line /' >"$R/docs/INDEX.md"
  echo "guide" >"$R/docs/guides/a.md"
  echo "<p>guide</p>" >"$R/docs/guides/a.html"
  echo "wb" >"$R/wb.sh"
  echo "x" >"$R/x.sh"
  echo "s" >"$R/scripts/keep.sh"
  git -C "$R" add -A
  git -C "$R" commit -q -m init
  git -C "$R" push -q origin development 2>/dev/null
  git -C "$R" remote set-head origin development
  echo '.worktrees/' >>"$R/.git/info/exclude"
  echo '[]' >"$F/stub/open.json"
  echo '[]' >"$F/stub/merged.json"
  cat >"$F/gh.sh" <<'STUB'
#!/usr/bin/env bash
d="$(dirname "$0")/stub"
[ -e "$d/fail" ] && { echo "stub: gh exploded" >&2; exit 1; }
[ -e "$d/garbage" ] && { echo "not json"; exit 0; }
state=
while [ $# -gt 0 ]; do [ "$1" = --state ] && state="$2"; shift; done
cat "$d/$state.json"
STUB
  chmod +x "$F/gh.sh"
  export LANES_GH="$F/gh.sh"
}

add_wt() { # <name> -> branch <name> in $R/.worktrees/<name>
  git -C "$R" worktree add -q -b "$1" "$R/.worktrees/$1" development
}
commit_in() { # <dir> <file> <content...>: write file (append line) and commit
  local d="$1" f="$2"
  shift 2
  mkdir -p "$d/$(dirname "$f")"
  printf '%s\n' "$*" >>"$d/$f"
  git -C "$d" add -A && git -C "$d" commit -q -m "edit $f"
}
branch_only() { # <name> <file> <content>: a local branch with a commit and no worktree
  add_wt "$1"
  commit_in "$R/.worktrees/$1" "$2" "$3"
  git -C "$R" worktree remove --force "$R/.worktrees/$1"
}
plan() { printf 'approved: 2026-11-21 by Jet\n%s\n' "$1" >"$F/plan"; }

run() { # args... -> OUT, ERR, RC (run from the clone)
  OUT="$(cd "$R" && "$CHECK" "$@" 2>"$F/err")"
  RC=$?
  ERR="$(cat "$F/err")"
}
indent() {
  local l
  while IFS= read -r l; do echo "       $1$l"; done
}
check() { # <desc> <condition-result>
  if [ "$2" = 0 ]; then echo "ok   - $1"; else
    echo "FAIL - $1"
    echo "       rc=$RC"
    indent "out: " <<<"$OUT"
    indent "err: " <<<"$ERR"
    fail=1
  fi
}
rc_is() { [ "$RC" = "$1" ]; }
has() { grep -qF -- "$1" <<<"$OUT"; }
has_line() { grep -qxF -- "$1" <<<"$OUT"; }
lacks() { ! grep -qF -- "$1" <<<"$OUT"; }

# 1. approval is required -------------------------------------------------
new_fixture
printf 'i1 wb.sh\n' >"$F/plan"
run start --plan "$F/plan"
check "no approved: line -> exit 2" "$(
  rc_is 2
  echo $?
)"
printf 'approved:   \ni1 wb.sh\n' >"$F/plan"
run start --plan "$F/plan"
check "empty approved: text -> exit 2" "$(
  rc_is 2
  echo $?
)"
printf 'approved: ok\ni1 wb.sh\ni1 x.sh\n' >"$F/plan"
run start --plan "$F/plan"
check "duplicate item id -> exit 2" "$(
  rc_is 2
  echo $?
)"
plan 'i1 wb.sh'
run start --plan "$F/plan" --item nope
check "unknown item -> exit 2 with usage on stderr" "$(
  rc_is 2 && grep -qi usage <<<"$ERR"
  echo $?
)"
run start
check "missing --plan -> exit 2" "$(
  rc_is 2
  echo $?
)"

# 2. another worktree's uncommitted edit -----------------------------------
new_fixture
plan 'i1 wb.sh'
add_wt wip
echo more >>"$R/.worktrees/wip/wb.sh"
run start --plan "$F/plan"
check "uncommitted edit elsewhere -> STOP, exit 1, (uncommitted) label" \
  "$(
    rc_is 1 && has 'STOP i1' && has_line "  wb.sh  <- worktree $R/.worktrees/wip (uncommitted)"
    echo $?
  )"

# 3. another worktree's committed branch -----------------------------------
new_fixture
plan 'i1 x.sh'
add_wt bw
commit_in "$R/.worktrees/bw" x.sh changed
run start --plan "$F/plan"
check "branch committed in another worktree -> STOP with worktree label" \
  "$(
    rc_is 1 && has_line "  x.sh  <- branch bw (worktree $R/.worktrees/bw)"
    echo $?
  )"

# 4. local branch with no worktree -----------------------------------------
new_fixture
plan 'i1 x.sh'
branch_only lb x.sh changed
run start --plan "$F/plan"
check "local branch without worktree or PR -> STOP branch lb" \
  "$(
    rc_is 1 && has_line "  x.sh  <- branch lb"
    echo $?
  )"

# 5. same branch, PR already merged ----------------------------------------
echo '[{"headRefName":"lb"}]' >"$F/stub/merged.json"
run start --plan "$F/plan"
check "merged-PR branch is ignored, exit 0, and listed as skipped" \
  "$(
    rc_is 0 && has 'CLEAR i1' && has_line 'Skipped (PR already merged): lb'
    echo $?
  )"
echo '[{"number":9,"headRefName":"lb","files":[{"path":"x.sh"}]}]' >"$F/stub/open.json"
run start --plan "$F/plan"
check "branch with a merged PR AND an open PR still blocks" \
  "$(
    rc_is 1 && has 'PR #9 (lb)' && has_line "  x.sh  <- branch lb"
    echo $?
  )"

# 6. open PR ----------------------------------------------------------------
new_fixture
plan 'i1 wb.sh'
echo '[{"number":42,"headRefName":"prbranch","files":[{"path":"wb.sh"},{"path":"other"}]}]' >"$F/stub/open.json"
run start --plan "$F/plan"
check "open PR touching a planned file -> STOP PR #42" \
  "$(
    rc_is 1 && has_line "  wb.sh  <- PR #42 (prbranch)"
    echo $?
  )"

# 7. PR lookup failure fails closed ----------------------------------------
touch "$F/stub/fail"
run start --plan "$F/plan"
check "gh exits 1 -> exit 2" "$(
  rc_is 2 && ! has 'CLEAR'
  echo $?
)"
rm "$F/stub/fail"
touch "$F/stub/garbage"
run start --plan "$F/plan"
check "gh prints invalid JSON -> exit 2" "$(
  rc_is 2 && ! has 'CLEAR'
  echo $?
)"

# 8. planned directory -------------------------------------------------------
new_fixture
plan 'i1 scripts/'
branch_only sb scripts/foo.sh new
run start --plan "$F/plan"
check "planned dir scripts/ matches live scripts/foo.sh" \
  "$(
    rc_is 1 && has_line "  scripts/foo.sh  <- branch sb"
    echo $?
  )"
new_fixture
plan 'i1 scripts/foo'
branch_only sb scripts/foo.sh new
run start --plan "$F/plan"
check "planned path without trailing slash is not a directory prefix" \
  "$(
    rc_is 0 && has 'CLEAR i1'
    echo $?
  )"

# 9. generated files ---------------------------------------------------------
new_fixture
plan 'i1 docs/INDEX.md docs/guides/a.html'
branch_only gen docs/INDEX.md "tail edit"
branch_only gen2 docs/guides/a.html "<p>more</p>"
run start --plan "$F/plan"
check "start: generated-file overlap is CLEAR plus NOTE" \
  "$(
    rc_is 0 && has 'CLEAR i1' && has 'NOTE i1: docs/INDEX.md' && has 'NOTE i1: docs/guides/a.html'
    echo $?
  )"

new_fixture
plan 'i1 docs/INDEX.md'
branch_only liv docs/INDEX.md "tail edit" # appends after line 10
add_wt itm
sed -i '1s/.*/line one edited/' "$R/.worktrees/itm/docs/INDEX.md"
git -C "$R/.worktrees/itm" commit -q -am "head edit"
run commit --plan "$F/plan" --item i1 --worktree "$R/.worktrees/itm"
check "commit: different parts of a generated file merge cleanly -> CLEAR" \
  "$(
    rc_is 0 && has 'CLEAR i1'
    echo $?
  )"
git -C "$R/.worktrees/itm" reset -q --hard development
echo "head conflicting edit" >>"$R/.worktrees/itm/docs/INDEX.md"
git -C "$R/.worktrees/itm" commit -q -am "tail edit, differently"
run commit --plan "$F/plan" --item i1 --worktree "$R/.worktrees/itm"
check "commit: same lines edited differently -> STOP with merge dry run" \
  "$(
    rc_is 1 && has 'STOP i1' && has 'merge dry run vs branch liv'
    echo $?
  )"
# the check runs BEFORE the item commits, so the dry run must see uncommitted edits
git -C "$R/.worktrees/itm" reset -q --hard development
echo "head conflicting edit" >>"$R/.worktrees/itm/docs/INDEX.md"
run commit --plan "$F/plan" --item i1 --worktree "$R/.worktrees/itm"
check "commit: an uncommitted conflicting edit -> STOP with merge dry run" \
  "$(
    rc_is 1 && has 'merge dry run vs branch liv'
    echo $?
  )"
check "commit: the dry run leaves the item's index untouched" \
  "$(
    git -C "$R/.worktrees/itm" diff --cached --quiet
    echo $?
  )"

new_fixture
plan 'i1 docs/INDEX.md'
echo '[{"number":5,"headRefName":"remote-only","files":[{"path":"docs/INDEX.md"}]}]' >"$F/stub/open.json"
add_wt itm
commit_in "$R/.worktrees/itm" docs/INDEX.md "mine"
run commit --plan "$F/plan" --item i1 --worktree "$R/.worktrees/itm"
check "commit: open PR sharing a generated file with no local ref -> STOP can't dry-run" \
  "$(
    rc_is 1 && has "can't dry-run"
    echo $?
  )"

new_fixture
plan 'i1 docs/INDEX.md'
add_wt wip
echo "wip" >>"$R/.worktrees/wip/docs/INDEX.md"
add_wt itm
commit_in "$R/.worktrees/itm" docs/INDEX.md "mine"
run commit --plan "$F/plan" --item i1 --worktree "$R/.worktrees/itm"
check "commit: uncommitted generated-file edit elsewhere is a NOTE only" \
  "$(
    rc_is 0 && has 'CLEAR i1' && has 'NOTE i1:'
    echo $?
  )"

# 10. commit mode ------------------------------------------------------------
new_fixture
plan 'i1 x.sh'
branch_only other new.txt "from other branch"
add_wt item-br
commit_in "$R/.worktrees/item-br" x.sh "own commit"
echo "own uncommitted" >>"$R/.worktrees/item-br/wb.sh"
echo "untracked" >"$R/.worktrees/item-br/new.txt"
run commit --plan "$F/plan" --item i1 --worktree "$R/.worktrees/item-br"
check "commit: own untracked file overlapping a live branch -> STOP" \
  "$(
    rc_is 1 && has_line "  new.txt  <- branch other"
    echo $?
  )"
check "commit: own worktree and branch are not live sources" \
  "$(
    lacks 'item-br' && lacks '(uncommitted)'
    echo $?
  )"
check "commit: actual file outside the plan is a NOTE, not a STOP" \
  "$(
    has 'NOTE i1: changed file not in plan: wb.sh' && lacks '  wb.sh  <-'
    echo $?
  )"

new_fixture
plan 'i1 x.sh'
add_wt item-br
git -C "$R/.worktrees/item-br" mv wb.sh renamed.sh
branch_only other wb.sh "other edit"
run commit --plan "$F/plan" --item i1 --worktree "$R/.worktrees/item-br"
check "commit: a rename counts both old and new path" \
  "$(
    rc_is 1 && has_line "  wb.sh  <- branch other"
    echo $?
  )"

# 11. blocks summary ---------------------------------------------------------
new_fixture
printf 'approved: ok\ni1 wb.sh\ni2 x.sh\ni3 scripts/keep.sh\n' >"$F/plan"
add_wt liv
commit_in "$R/.worktrees/liv" wb.sh a
commit_in "$R/.worktrees/liv" x.sh b
run start --plan "$F/plan"
check "one branch blocking two items -> 'blocks 2 item(s)'" \
  "$(
    rc_is 1 && has 'Blocks per live source:' && has "branch liv (worktree $R/.worktrees/liv): blocks 2 item(s) via wb.sh, x.sh" && has 'CLEAR i3'
    echo $?
  )"
run start --plan "$F/plan" --item i2
check "--item limits the check to that item" \
  "$(
    rc_is 1 && has 'STOP i2' && lacks 'i1' && lacks 'i3'
    echo $?
  )"

# 12. stowed config warning ---------------------------------------------------
new_fixture
plan 'i1 wb.sh'
mkdir -p "$HOME/.config" "$R/.worktrees/feat/sub"
touch "$R/.worktrees/feat/sub/y"
ln -s "$R/.worktrees/feat/sub/y" "$HOME/.config/x"
ln -s "$R/.worktrees/feat/sub" "$HOME/.config/z"
ln -s "$R/wb.sh" "$HOME/.config/fine"
run start --plan "$F/plan"
check "symlink into a feature worktree -> WARN with count, exit unchanged" \
  "$(
    rc_is 0 && has "WARN live config stowed from a feature worktree: 2 link(s) into $R/.worktrees/feat"
    echo $?
  )"
rm "$HOME/.config/x" "$HOME/.config/z"
run start --plan "$F/plan"
check "no such symlink -> no WARN" "$(
  rc_is 0 && lacks 'WARN'
  echo $?
)"

# 13. all clear ---------------------------------------------------------------
new_fixture
printf 'approved: ok\n# comment\n\ni1 wb.sh\ni2 x.sh scripts/\n' >"$F/plan"
run start --plan "$F/plan"
check "nothing live -> every item CLEAR, exit 0" \
  "$(
    rc_is 0 && has 'CLEAR i1' && has 'CLEAR i2' && lacks 'STOP' && lacks 'Blocks per'
    echo $?
  )"

exit "$fail"
