#!/usr/bin/env bash
# Tests for `wb views <task>...|--all` (rebuild a dossier's generated views
# under the task lock) and for the store's post-merge / post-rewrite git
# hooks (tasks-git-hooks/), which run it for the dossiers a pull or rebase
# changed. The hooks run against a throwaway git repo with a fake `wb` first
# on PATH that records its arguments. All fixture text is made up.
#
# Run in the Docker sandbox (see tests/Dockerfile):
#   docker run --rm -v "$(pwd)":/repo:ro -w /repo wb-tests \
#     bash scripts/.config/scripts/tmux/tests/wb-views.test.sh
set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WB="$SELF_DIR/wb.sh"
HOOKS="$SELF_DIR/tasks-git-hooks"

FIXTURE="$(mktemp -d -t wb-views-fixture.XXXXXX)"
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
cd "$FIXTURE" || exit 1   # the sandbox mount is a linked worktree whose .git file points at a host path
export GIT_CONFIG_GLOBAL="$FIXTURE/gitconfig" GIT_CONFIG_SYSTEM=/dev/null
git config --global user.email t@example.com; git config --global user.name tester
git config --global init.defaultBranch main

# shellcheck disable=SC1090
source "$WB"
set +e

mk_task() { # <stem> [layout]
  { printf -- '---\nstatus: doing\nrepo: proj\nbranch: b\n'
    [ "${2:-}" = old ] || printf 'layout: dossier\n'
    printf 'tags: []\ncreated: 2026-07-01\nclosed:\n---\n# Title\n\n## Plan\n\nplan\n'
  } > "$TASKS_DIR/$1.md"
}
mk_dec() { # <stem> <id> <title>
  mkdir -p "$TASKS_DIR/dossiers/$1/decisions"
  printf -- '---\nstatus: in-force\nsupersedes: []\nsuperseded_by: []\nreview_at:\n---\n# %s\n\nbody\n' "$3" > "$TASKS_DIR/dossiers/$1/decisions/$2.md"
}

# =============================================================================
# wb views
# =============================================================================
mk_task proj--va; mk_dec proj--va 2026-11-01-0900-one "One"
mk_task proj--vb; mk_dec proj--vb 2026-11-01-0900-two "Two"
mk_task proj--old old
out="$(cmd_views proj--va 2>&1)"; rc=$?
assert_eq "views: named layout task exits 0" 0 "$rc"
assert "views: says what it rebuilt" 'proj--va' "$out"
assert "views: decisions.md rebuilt" '^### One$' "$(cat "$TASKS_DIR/dossiers/proj--va/decisions.md")"
assert "views: index.md rebuilt" 'dossier index' "$(cat "$TASKS_DIR/dossiers/proj--va/index.md")"
# stale view repaired
printf 'stale\n' > "$TASKS_DIR/dossiers/proj--va/decisions.md"
cmd_views proj--va >/dev/null 2>&1
assert_not "views: a stale view is rewritten" '^stale$' "$(cat "$TASKS_DIR/dossiers/proj--va/decisions.md")"
# a second run changes no byte
sum1="$(cd "$TASKS_DIR" && find dossiers -type f | LC_ALL=C sort | xargs md5sum | md5sum)"
cmd_views proj--va >/dev/null 2>&1
assert_eq "views: second run changes nothing" "$sum1" "$(cd "$TASKS_DIR" && find dossiers -type f | LC_ALL=C sort | xargs md5sum | md5sum)"
# the exact stem wins over a longer stem that contains it
mk_task proj--v; mk_dec proj--v 2026-11-01-0900-solo "Solo"
cmd_views proj--v >/dev/null 2>&1
assert "views: an exact stem is not a fuzzy match (proj--v vs proj--va)" '^### Solo$' "$(cat "$TASKS_DIR/dossiers/proj--v/decisions.md")"
# non-layout, named
out="$(cmd_views proj--old 2>&1)"; rc=$?
assert_eq "views: a non-layout task named: exit 1" 1 "$rc"
assert "views: a non-layout task named: one-line message" 'not on the dossier layout' "$out"
assert_eq "views: a non-layout task named: one line only" 1 "$(printf '%s\n' "$out" | wc -l | tr -d ' ')"
[ ! -e "$TASKS_DIR/dossiers/proj--old" ] && echo "ok   - views: a non-layout task gets no dossier" || { echo "FAIL - views created a dossier for a non-layout task"; fail=1; }
# several tasks
rm -f "$TASKS_DIR/dossiers/proj--vb/decisions.md"
cmd_views proj--va proj--vb >/dev/null 2>&1; rc=$?
assert_eq "views: two named tasks: exit 0" 0 "$rc"
[ -f "$TASKS_DIR/dossiers/proj--vb/decisions.md" ] && echo "ok   - views: the second named task rebuilt" || { echo "FAIL - second named task not rebuilt"; fail=1; }
# --all
rm -f "$TASKS_DIR"/dossiers/proj--va/decisions.md "$TASKS_DIR"/dossiers/proj--vb/decisions.md
out="$(cmd_views --all 2>&1)"; rc=$?
assert_eq "views --all: exit 0 even with a non-layout task" 0 "$rc"
[ -f "$TASKS_DIR/dossiers/proj--va/decisions.md" ] && [ -f "$TASKS_DIR/dossiers/proj--vb/decisions.md" ] && echo "ok   - views --all: every layout task rebuilt" || { echo "FAIL - --all missed a task"; fail=1; }
assert "views --all: summary counts rebuilt and skipped" '3 rebuilt.*1 not on the dossier layout' "$out"
# usage
out="$(cmd_views 2>&1)"; rc=$?
assert_eq "views: no argument: exit 1" 1 "$rc"
assert "views: no argument: usage" 'usage: wb views' "$out"
# lock held by someone else: skipped, not blocked
wb_task_lock_acquire_guarded "$TASKS_DIR/proj--va.md" >/dev/null 2>&1
out="$(bash -c 'source "$1"; set +e; cmd_views proj--va' _ "$WB" 2>&1)"; rc=$?
wb_task_lock_release "$TASKS_DIR/proj--va.md" >/dev/null 2>&1
assert "views: a held lock is reported and skipped" 'lock held' "$out"
# help + dispatch
help="$(cmd_help)"
assert "wb help lists views" '^  wb views ' "$help"
out="$(bash "$WB" views proj--va 2>&1)"; rc=$?
assert_eq "views: reachable through the dispatch" 0 "$rc"

# =============================================================================
# hooks: post-merge and post-rewrite
# =============================================================================
[ -x "$HOOKS/post-merge" ] && echo "ok   - hooks: post-merge exists and is executable" || { echo "FAIL - no executable post-merge"; fail=1; }
[ -x "$HOOKS/post-rewrite" ] && echo "ok   - hooks: post-rewrite exists and is executable" || { echo "FAIL - no executable post-rewrite"; fail=1; }

# a fake wb that records its arguments and the TASKS_DIR it saw
BIN="$FIXTURE/bin"; mkdir -p "$BIN"
cat > "$BIN/wb" <<'EOF'
#!/usr/bin/env bash
printf '%s|%s\n' "$TASKS_DIR" "$*" >> "$WB_FAKE_LOG"
exit "${WB_FAKE_RC:-0}"
EOF
chmod +x "$BIN/wb"
export WB_FAKE_LOG="$FIXTURE/fake-wb.log"
BASEPATH="$PATH"

# the hooks as the stow lays them out (links into the checkout), minus the
# reference-transaction hook, which would veto the rebase and amend below
LINKED="$FIXTURE/linked-hooks"; mkdir -p "$LINKED"
for h in post-merge post-rewrite views-lib.sh; do ln -s "$HOOKS/$h" "$LINKED/$h"; done

new_pair() { # <name> — a store repo "<name>-a" (origin) and a clone "<name>-b" with the hooks wired
  local n="$1"
  git init -q "$FIXTURE/$n-a"
  (cd "$FIXTURE/$n-a" \
    && printf -- '---\nstatus: doing\nlayout: dossier\n---\n# A\n' > proj--ha.md \
    && printf -- '---\nstatus: doing\nlayout: dossier\n---\n# B\n' > proj--hb.md \
    && printf -- '---\nstatus: doing\n---\n# Old\n' > proj--hold.md \
    && mkdir -p dossiers/proj--ha/decisions dossiers/proj--hb/decisions dossiers/proj--hold \
    && echo x > dossiers/proj--ha/decisions/2026-11-01-0900-x.md \
    && echo x > dossiers/proj--hb/decisions/2026-11-01-0900-x.md \
    && echo x > dossiers/proj--hold/notes.md \
    && git add -A && git commit -qm init)
  git clone -q "$FIXTURE/$n-a" "$FIXTURE/$n-b"
  git -C "$FIXTURE/$n-b" config core.hooksPath "$LINKED"
}
commit_in_a() { # <name> <path> — change a file in origin
  (cd "$FIXTURE/$1-a" && mkdir -p "$(dirname "$2")" && echo "$RANDOM" >> "$2" && git add -A && git commit -qm "change $2")
}

# --- post-merge: a fast-forward pull that changed one dossier -----------------
new_pair m1
commit_in_a m1 dossiers/proj--ha/decisions/2026-11-02-1000-new.md
: > "$WB_FAKE_LOG"
out="$(cd "$FIXTURE/m1-b" && PATH="$BIN:$BASEPATH" git pull -q 2>&1)"; rc=$?
assert_eq "post-merge: the pull succeeds" 0 "$rc"
assert "post-merge: runs wb views for the changed dossier, with TASKS_DIR set to the store" "m1-b\|views proj--ha\$" "$(cat "$WB_FAKE_LOG")"
assert_not "post-merge: not for an untouched dossier" 'proj--hb' "$(cat "$WB_FAKE_LOG")"
assert_eq "post-merge: one wb call" 1 "$(wc -l < "$WB_FAKE_LOG" | tr -d ' ')"

# --- two dossiers, one non-layout dossier, a generated view and a plain task file
new_pair m2
commit_in_a m2 dossiers/proj--ha/decisions/2026-11-02-1000-new.md
commit_in_a m2 dossiers/proj--hb/open-items/2026-11-02-thing.md
commit_in_a m2 dossiers/proj--hold/notes.md
commit_in_a m2 proj--ha.md
: > "$WB_FAKE_LOG"
(cd "$FIXTURE/m2-b" && PATH="$BIN:$BASEPATH" git pull -q >/dev/null 2>&1)
assert "post-merge: both changed layout dossiers in one call" 'views proj--ha proj--hb$' "$(cat "$WB_FAKE_LOG")"
assert_not "post-merge: a dossier whose task is not on the layout is left out" 'proj--hold' "$(cat "$WB_FAKE_LOG")"

# --- only a task file changed: nothing to rebuild
new_pair m3
commit_in_a m3 proj--ha.md
: > "$WB_FAKE_LOG"
(cd "$FIXTURE/m3-b" && PATH="$BIN:$BASEPATH" git pull -q >/dev/null 2>&1)
assert_eq "post-merge: no record changed -> wb not called" 0 "$(wc -c < "$WB_FAKE_LOG" | tr -d ' ')"

# --- a real merge commit (diverged histories)
new_pair m4
commit_in_a m4 dossiers/proj--hb/decisions/2026-11-03-1000-up.md
(cd "$FIXTURE/m4-b" && echo local > local.txt && git add -A && git commit -qm local)
: > "$WB_FAKE_LOG"
(cd "$FIXTURE/m4-b" && PATH="$BIN:$BASEPATH" git pull --no-rebase --no-edit -q >/dev/null 2>&1)
assert "post-merge: a merge commit also runs wb views" 'views proj--hb$' "$(cat "$WB_FAKE_LOG")"

# --- never fails the git operation: wb exits non-zero
new_pair m5
commit_in_a m5 dossiers/proj--ha/decisions/2026-11-02-1000-new.md
: > "$WB_FAKE_LOG"
out="$(cd "$FIXTURE/m5-b" && WB_FAKE_RC=3 PATH="$BIN:$BASEPATH" git pull -q 2>&1)"; rc=$?
assert_eq "post-merge: wb failing does not fail the pull" 0 "$rc"
assert "post-merge: one line on error" 'post-merge: .*wb views.*failed' "$out"
assert_eq "post-merge: only one error line" 1 "$(printf '%s\n' "$out" | grep -c 'wb views')"

# --- no wb at all: does nothing, exits 0 (hooks copied away from any wb.sh)
new_pair m6
NOWB="$FIXTURE/nowb-hooks"; mkdir -p "$NOWB"
cp "$HOOKS"/post-merge "$HOOKS"/post-rewrite "$NOWB"/
[ ! -f "$HOOKS/views-lib.sh" ] || cp "$HOOKS/views-lib.sh" "$NOWB"/
git -C "$FIXTURE/m6-b" config core.hooksPath "$NOWB"
commit_in_a m6 dossiers/proj--ha/decisions/2026-11-02-1000-new.md
: > "$WB_FAKE_LOG"
out="$(cd "$FIXTURE/m6-b" && PATH="$(dirname "$(command -v git)"):/usr/bin:/bin" git pull -q 2>&1)"; rc=$?
assert_eq "post-merge: no wb on PATH -> the pull succeeds" 0 "$rc"
assert_eq "post-merge: no wb on PATH -> nothing printed" "" "$out"
(cd "$FIXTURE/m6-b" && PATH="/usr/bin:/bin" bash "$NOWB/post-merge" 0 >/dev/null 2>&1); rc=$?
assert_eq "post-merge: no wb on PATH -> direct run exits 0" 0 "$rc"
(cd "$FIXTURE/m6-b" && printf 'a b\n' | PATH="/usr/bin:/bin" bash "$NOWB/post-rewrite" rebase >/dev/null 2>&1); rc=$?
assert_eq "post-rewrite: no wb on PATH -> exits 0" 0 "$rc"

# --- outside a git repo / no ORIG_HEAD: falls back to --all, still exit 0
new_pair m7
rm -f "$FIXTURE/m7-b/.git/ORIG_HEAD"
: > "$WB_FAKE_LOG"
(cd "$FIXTURE/m7-b" && PATH="$BIN:$BASEPATH" bash "$HOOKS/post-merge" 0 >/dev/null 2>&1); rc=$?
assert_eq "post-merge: no ORIG_HEAD -> exit 0" 0 "$rc"
assert "post-merge: no ORIG_HEAD -> falls back to --all" 'views --all$' "$(cat "$WB_FAKE_LOG")"

# --- post-rewrite after a rebase
new_pair r1
commit_in_a r1 dossiers/proj--hb/decisions/2026-11-04-1000-up.md
(cd "$FIXTURE/r1-b" && echo local > local.txt && git add -A && git commit -qm local)
: > "$WB_FAKE_LOG"
out="$(cd "$FIXTURE/r1-b" && PATH="$BIN:$BASEPATH" git pull --rebase -q 2>&1)"; rc=$?; [ "$rc" -eq 0 ] || echo "       git said: $out"
assert_eq "post-rewrite: pull --rebase succeeds" 0 "$rc"
assert "post-rewrite: runs wb views for the dossier the rebase brought in" 'views proj--hb$' "$(cat "$WB_FAKE_LOG")"
assert_not "post-rewrite: not for untouched dossiers" 'proj--ha' "$(cat "$WB_FAKE_LOG")"

# --- post-rewrite after an amend of a record file
new_pair r2
(cd "$FIXTURE/r2-b" && echo more >> dossiers/proj--ha/decisions/2026-11-01-0900-x.md && git add -A && git commit -qm c1 \
  && : > "$WB_FAKE_LOG" && echo more2 >> dossiers/proj--ha/decisions/2026-11-01-0900-x.md && git add -A && PATH="$BIN:$BASEPATH" git commit -q --amend --no-edit >/dev/null 2>&1)
assert "post-rewrite: an amend that touches a record runs wb views" 'views proj--ha$' "$(cat "$WB_FAKE_LOG")"

# --- wb install-hooks: hooksPath is the directory, so the new hooks need no extra wiring
assert "install-hooks: the header names the new hooks" 'post-merge' "$(sed -n '/^# wb install-hooks/,/^cmd_install_hooks()/p' "$WB")"

echo
[ "$fail" -eq 0 ] && echo "ALL PASS" || echo "FAILURES"
exit "$fail"
