#!/usr/bin/env bash
# Tests for the `worktrees:` field validator/reader and `wb worktree add`
# (wb-review-multi-repo U6). Real fixture git repos under a temp CODE_DIR,
# never ~/code.
# MUST run via the project's test Dockerfile, never bare on the host:
#   docker run --rm -v "$(pwd)":/repo:ro -w /repo wb-tests \
#     bash scripts/.config/scripts/tmux/tests/wb-worktree-add.test.sh
set -uo pipefail

WB="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/wb.sh"
FIXTURE_CODE="$(mktemp -d -t wb-wtadd-code.XXXXXX)"
FIXTURE_TASKS="$(mktemp -d -t wb-wtadd-tasks.XXXXXX)"
trap 'rm -rf "$FIXTURE_CODE" "$FIXTURE_TASKS"' EXIT

fail=0
assert() { # <desc> <expected-regex> <actual>
  if printf '%s' "$3" | grep -qE "$2"; then echo "ok   - $1"
  else echo "FAIL - $1"; echo "       expected match: $2"; echo "       got: $(printf '%s' "$3" | head -6)"; fail=1; fi
}
assert_eq() { # <desc> <expected> <actual>
  if [ "$2" = "$3" ]; then echo "ok   - $1"
  else echo "FAIL - $1"; echo "       expected: $2"; echo "       got:      $3"; fail=1; fi
}

mk_repo() { # <name>  — a repo with a committed .gitignore and an ignored .env
  local d="$FIXTURE_CODE/$1"
  git init -q -b main "$d"
  printf '.env\n' > "$d/.gitignore"
  git -C "$d" add .gitignore
  git -C "$d" -c user.email=test@test -c user.name=test commit -q -m init
  echo "SECRET=$1" > "$d/.env"
}
for r in proj other other2 other3 other4 other5 other6 other7 other8; do mk_repo "$r"; done
mkdir -p "$FIXTURE_CODE/nogit"
git -C "$FIXTURE_CODE/proj" worktree add -q -b feat .worktrees/feat >/dev/null 2>&1

TASK="$FIXTURE_TASKS/proj--feat.md"
printf -- '---\nstatus: doing\nrepo: proj\nbranch: feat\nworktree: .worktrees/feat\ntags: []\ncreated: 2026-11-24\nclosed:\n---\n# Title\n' > "$TASK"
mkdir -p "$FIXTURE_TASKS/dossiers/proj--feat"
echo "- family fact" > "$FIXTURE_TASKS/dossiers/proj--feat/concepts.md"

# shellcheck disable=SC1090
source "$WB"
set +e
TASKS_DIR="$FIXTURE_TASKS"
CODE_DIR="$FIXTURE_CODE"
field() { wb_get_frontmatter "$TASK" worktrees; }
wt_count() { git -C "$FIXTURE_CODE/$1" worktree list --porcelain | grep -c '^worktree '; }

echo "# validator"
for ok in other/.worktrees/feat a.b_c-d/.worktrees/x-1 other/.worktrees/a/b; do
  _wb_safe_worktrees_entry "$ok"; assert_eq "accepts $ok" 0 "$?"
done
for bad in "" other .worktrees/feat other/.worktrees other/.worktrees/ ../.worktrees/x ./.worktrees/x \
    a/b/.worktrees/x "o ther/.worktrees/x" other/.worktrees/../x other/.worktrees/a//b /abs/.worktrees/x \
    other/worktrees/x; do
  _wb_safe_worktrees_entry "$bad"; assert_eq "rejects '$bad'" 1 "$?"
done

echo "# reader: valid entries only, one per repo, never the primary's"
R="$FIXTURE_TASKS/proj--reader.md"
printf -- '---\nstatus: doing\nrepo: proj\nworktrees: other/.worktrees/a, bad, other/.worktrees/b, proj/.worktrees/z, o2/.worktrees/../x, o3/.worktrees/c # note\n---\n' > "$R"
out="$(_wb_task_worktrees "$R" 2>"$FIXTURE_TASKS/notes")"
assert_eq "keeps the first entry per repo and valid ones" $'other/.worktrees/a\no3/.worktrees/c' "$out"
notes="$(cat "$FIXTURE_TASKS/notes")"
assert "notes the malformed entry" "skipping worktrees: entry 'bad'" "$notes"
assert "notes the repeated repo" "entry 'other/.worktrees/b'" "$notes"
assert "notes the primary's repo" "entry 'proj/.worktrees/z'" "$notes"
assert "notes the climbing entry" "entry 'o2/.worktrees/../x'" "$notes"
_wb_task_worktrees "$R" quiet >/dev/null 2>"$FIXTURE_TASKS/notes"
assert_eq "quiet mode prints no note" "" "$(cat "$FIXTURE_TASKS/notes")"
rm -f "$R"

echo "# add: creates the worktree on the task's branch with bootstrap files, family context and the field"
out="$(cmd_worktree add other proj--feat 2>&1)"; rc=$?
assert_eq "exit 0" 0 "$rc"
assert "says created" "created" "$out"
P="$FIXTURE_CODE/other/.worktrees/feat"
assert_eq "worktree is on the task's branch" feat "$(git -C "$P" symbolic-ref --short HEAD)"
assert_eq "the gitignored .env was copied in" "SECRET=other" "$(cat "$P/.env" 2>/dev/null)"
assert "CLAUDE.local.md names the family concepts file" "dossiers/proj--feat/concepts.md" "$(cat "$P/CLAUDE.local.md" 2>/dev/null)"
assert_eq "worktrees: written" "other/.worktrees/feat" "$(field)"
assert_eq "worktrees: sits right after worktree:" "worktrees: other/.worktrees/feat" "$(grep -A1 '^worktree:' "$TASK" | tail -1)"

echo "# add: a second repo appends with ', ' and keeps frontmatter comments"
sed -i 's|^worktrees: .*|& # keep this|' "$TASK"
out="$(cmd_worktree add other2 proj--feat 2>&1)"; rc=$?
assert_eq "exit 0" 0 "$rc"
assert_eq "both entries" "other/.worktrees/feat, other2/.worktrees/feat # keep this" "$(field)"
assert_eq "other frontmatter lines kept" 1 "$(grep -c '^tags: \[\]$' "$TASK")"

echo "# add: running it twice leaves one entry and changes nothing on disk"
before="$(wt_count other)"
out="$(cmd_worktree add other proj--feat 2>&1)"; rc=$?
assert_eq "exit 0" 0 "$rc"
assert "second run adopts" "adopted" "$out"
assert_eq "still two entries" "other/.worktrees/feat, other2/.worktrees/feat # keep this" "$(field)"
assert_eq "no extra worktree" "$before" "$(wt_count other)"

echo "# add: an unlisted worktree at the target path on the task's branch is adopted (AE6)"
git -C "$FIXTURE_CODE/other3" worktree add -q -b feat .worktrees/feat >/dev/null 2>&1
before="$(wt_count other3)"
out="$(cmd_worktree add other3 proj--feat 2>&1)"; rc=$?
assert_eq "exit 0" 0 "$rc"
assert "says adopted" "adopted" "$out"
assert_eq "created nothing" "$before" "$(wt_count other3)"
assert "listed it" "other3/.worktrees/feat" "$(field)"
assert_eq "bootstrap still ran on it" "SECRET=other3" "$(cat "$FIXTURE_CODE/other3/.worktrees/feat/.env" 2>/dev/null)"

echo "# add: the task's branch checked out in the main checkout is refused, naming it (AE6)"
git -C "$FIXTURE_CODE/other4" checkout -q -b feat
snap="$(cat "$TASK")"
out="$(cmd_worktree add other4 proj--feat 2>&1)"; rc=$?
assert_eq "exit 1" 1 "$rc"
assert "names where" "already checked out at $FIXTURE_CODE/other4" "$out"
assert_eq "no worktree made" no "$([ -e "$FIXTURE_CODE/other4/.worktrees/feat" ] && echo yes || echo no)"
assert_eq "task file unchanged" "$snap" "$(cat "$TASK")"

echo "# add: the branch checked out in a worktree under another name is refused, naming it (AE6)"
git -C "$FIXTURE_CODE/other5" worktree add -q -b feat .worktrees/elsewhere >/dev/null 2>&1
out="$(cmd_worktree add other5 proj--feat 2>&1)"; rc=$?
assert_eq "exit 1" 1 "$rc"
assert "names where" "already checked out at $FIXTURE_CODE/other5/.worktrees/elsewhere" "$out"
assert_eq "task file unchanged" "$snap" "$(cat "$TASK")"

echo "# add: refusals"
out="$(cmd_worktree add proj proj--feat 2>&1)"; rc=$?
assert_eq "the primary's repo: exit 1" 1 "$rc"
assert "the primary's repo: says so" "own repo" "$out"
out="$(cmd_worktree add nogit proj--feat 2>&1)"; rc=$?
assert_eq "a dir with no .git: exit 1" 1 "$rc"
assert "a dir with no .git: says so" "not a git repo" "$out"
out="$(cmd_worktree add nonesuch proj--feat 2>&1)"; rc=$?
assert_eq "a missing repo: exit 1" 1 "$rc"
mkdir -p "$FIXTURE_CODE/other6/.worktrees/feat"
out="$(cmd_worktree add other6 proj--feat 2>&1)"; rc=$?
assert_eq "a plain directory at the target path: exit 1" 1 "$rc"
assert "a plain directory: says it is not a registered worktree" "not a registered worktree" "$out"
out="$(cmd_worktree add ../other proj--feat 2>&1)"; rc=$?
assert_eq "a path-shaped repo name: exit 1" 1 "$rc"
out="$(cmd_worktree add 2>&1)"; rc=$?
assert_eq "no repo: usage, exit 1" 1 "$rc"
assert "no repo: usage" "usage: wb worktree add" "$out"
assert_eq "task file unchanged by every refusal" "$snap" "$(cat "$TASK")"

echo "# add: a repo already listed with a different path is refused"
OTHER_TASK="$FIXTURE_TASKS/proj--feat-two.md"
printf -- '---\nstatus: doing\nrepo: proj\nbranch: feat-two\nworktree: .worktrees/feat-two\nworktrees: other7/.worktrees/old-name\n---\n' > "$OTHER_TASK"
git -C "$FIXTURE_CODE/proj" worktree add -q -b feat-two .worktrees/feat-two >/dev/null 2>&1
out="$(cmd_worktree add other7 proj--feat-two 2>&1)"; rc=$?
assert_eq "exit 1" 1 "$rc"
assert "names the listed entry" "already lists other7/.worktrees/old-name" "$out"
assert_eq "field unchanged" "other7/.worktrees/old-name" "$(wb_get_frontmatter "$OTHER_TASK" worktrees)"

echo "# add: a failure after creation leaves the field unchanged, and a re-run adopts the worktree"
orig_bootstrap="$(declare -f wb_bootstrap)"
wb_bootstrap() { return 1; }
snap="$(cat "$TASK")"
out="$(cmd_worktree add other8 proj--feat 2>&1)"; rc=$?
assert_eq "exit 1" 1 "$rc"
assert "says to re-run" "re-run to adopt" "$out"
assert_eq "the worktree was created" yes "$([ -e "$FIXTURE_CODE/other8/.worktrees/feat/.git" ] && echo yes || echo no)"
assert_eq "task file unchanged" "$snap" "$(cat "$TASK")"
eval "$orig_bootstrap"
out="$(cmd_worktree add other8 proj--feat 2>&1)"; rc=$?
assert_eq "re-run: exit 0" 0 "$rc"
assert "re-run adopts" "adopted" "$out"
assert "re-run lists it" "other8/.worktrees/feat" "$(field)"

echo "# add: with no task argument and no tmux, it asks for one"
unset TMUX
out="$(cmd_worktree add other 2>&1)"; rc=$?
assert_eq "exit 1" 1 "$rc"
assert "says to pass a task" "not inside tmux" "$out"

[ "$fail" -eq 0 ] && echo "ALL PASS" || echo "FAILURES"
exit "$fail"
