#!/usr/bin/env bash
# Tests for `wb reconcile` (U6, detection only) — plain-bash assertions,
# same convention as wb-board.test.sh. Sources wb.sh (safe: see the
# BASH_SOURCE guard at the bottom of wb.sh), stubs wb_reconcile_repos to
# point at real fixture git repos (worktree detection needs real git state),
# and injects a fake `gh` via PATH so no live network call ever happens.
# Run: bash scripts/.config/scripts/tmux/tests/wb-reconcile.test.sh
set -uo pipefail

WB="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/wb.sh"
FIXTURE_CODE="$(mktemp -d -t wb-reconcile-code.XXXXXX)"
FIXTURE_TASKS="$(mktemp -d -t wb-reconcile-tasks.XXXXXX)"
FIXTURE_BIN="$(mktemp -d -t wb-reconcile-bin.XXXXXX)"
trap 'rm -rf "$FIXTURE_CODE" "$FIXTURE_TASKS" "$FIXTURE_BIN"' EXIT

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

# --- fake `gh` — no live network call, ever -----------------------------
cat > "$FIXTURE_BIN/gh" <<'EOF'
#!/usr/bin/env bash
head=""
while [ $# -gt 0 ]; do
  case "$1" in
    --head) head="$2"; shift 2 ;;
    *) shift ;;
  esac
done
case "$head" in
  merged-orphan) echo '[{"number":42,"mergedAt":"2026-07-01T00:00:00Z"}]' ;;
  stale-orphan)  echo '[]' ;;
  broken-orphan) echo 'gh: some unrelated failure' >&2; exit 1 ;;
  *) echo '[]' ;;
esac
EOF
chmod +x "$FIXTURE_BIN/gh"
PATH="$FIXTURE_BIN:$PATH"

# --- fixture repo with 4 worktrees: 3 orphaned (one per merge status), ------
# --- 1 tracked by a task file (must NOT show up as drift) -------------------
mk_repo() {
  local dir="$1"
  git init -q "$dir"
  git -C "$dir" -c user.email=test@test -c user.name=test commit -q --allow-empty -m init
}
add_worktree() { # <repo_dir> <branch>
  git -C "$1" worktree add -q -b "$2" ".worktrees/$2" >/dev/null 2>&1
}

mk_repo "$FIXTURE_CODE/proj"
add_worktree "$FIXTURE_CODE/proj" merged-orphan
add_worktree "$FIXTURE_CODE/proj" stale-orphan
add_worktree "$FIXTURE_CODE/proj" broken-orphan
add_worktree "$FIXTURE_CODE/proj" tracked-branch

mk_task() { # <file> <repo> <branch> <worktree>
  local f="$FIXTURE_TASKS/$1"
  printf -- '---\nstatus: doing\nrepo: %s\nbranch: %s\nworktree: %s\ntags: []\ncreated: 2026-07-07\nclosed:\n---\n# Title\n' \
    "$2" "$3" "$4" > "$f"
}
mk_task 'proj--tracked.md' proj tracked-branch '.worktrees/tracked-branch'
mk_task 'proj--ghost.md'   proj ghost-branch   '.worktrees/ghost-branch'   # worktree never created -> missing

# shellcheck disable=SC1090
source "$WB"
set +e   # wb.sh sets -e; this test captures non-zero exits by design
TASKS_DIR="$FIXTURE_TASKS"
CODE_DIR="$FIXTURE_CODE"
wb_reconcile_repos() { printf '%s\n' "$FIXTURE_CODE/proj"; }

out="$(cmd_reconcile 2>&1)"; rc=$?

assert "exits 0" '^' "$rc-ok"; [ "$rc" -eq 0 ] || { echo "FAIL - exit code $rc: $out"; fail=1; }
assert "header for orphan section"  'Orphaned worktrees' "$out"
assert "header for missing section" 'Tasks referencing a missing worktree' "$out"

assert "merged orphan reported as merged"     'proj +merged-orphan +\.worktrees/merged-orphan +merged' "$out"
assert "stale orphan reported as not-merged"  'proj +stale-orphan +\.worktrees/stale-orphan +not-merged' "$out"
assert "gh failure reported as unknown, not dropped" 'proj +broken-orphan +\.worktrees/broken-orphan +unknown' "$out"
assert "missing-worktree task reported"       'proj +\.worktrees/ghost-branch +proj--ghost' "$out"

if printf '%s' "$out" | grep -q 'tracked-branch.*not-merged\|tracked-branch.*merged\|tracked-branch.*unknown'; then
  echo "FAIL - tracked-branch (has a matching task file) reported as orphaned drift"
  fail=1
else
  echo "ok   - tracked-branch excluded (matched by task file)"
fi

# =============================================================================
# `wb reconcile --machine` (R28/KTD5) — the same drift as parseable TSV.
# =============================================================================

# Read-only: snapshot the store + worktrees before, compare after.
before_tasks="$(find "$FIXTURE_TASKS" -type f | sort | xargs -r md5sum 2>/dev/null)"
before_worktrees="$(git -C "$FIXTURE_CODE/proj" worktree list --porcelain)"

out_m="$(cmd_reconcile --machine 2>&1)"; rc_m=$?
assert "machine mode: exits 0" '^' "$rc_m-ok"; [ "$rc_m" -eq 0 ] || { echo "FAIL - machine mode exit code $rc_m: $out_m"; fail=1; }

# Orphan row: kind=orphan, fifth field is a merge status (merged/not-merged/unknown).
assert "machine mode: orphan row, fifth field is a merge status" \
  '^orphan	proj	merged-orphan	\.worktrees/merged-orphan	merged$' "$out_m"
assert "machine mode: not-merged orphan, fifth field is a merge status" \
  '^orphan	proj	stale-orphan	\.worktrees/stale-orphan	not-merged$' "$out_m"

# Missing row: kind=missing, fifth field is a TASK-FILE PATH — a different
# meaning for the same column position, asserted separately so a caller
# reading field five as a single fixed meaning is caught here.
assert "machine mode: missing row, fifth field is a task-file path (not a merge status)" \
  '^missing	proj	ghost-branch	\.worktrees/ghost-branch	.*proj--ghost\.md$' "$out_m"

after_tasks="$(find "$FIXTURE_TASKS" -type f | sort | xargs -r md5sum 2>/dev/null)"
after_worktrees="$(git -C "$FIXTURE_CODE/proj" worktree list --porcelain)"
if [ "$before_tasks" = "$after_tasks" ] && [ "$before_worktrees" = "$after_worktrees" ]; then
  echo "ok   - machine mode: read-only (store + worktrees byte-identical)"
else
  echo "FAIL - machine mode: store or worktrees changed by a read-only call"; fail=1
fi

# --- clean tree: no orphans, no missing worktrees -> explicit no-drift ------
CLEAN_CODE="$(mktemp -d -t wb-reconcile-clean-code.XXXXXX)"
CLEAN_TASKS="$(mktemp -d -t wb-reconcile-clean-tasks.XXXXXX)"
mk_repo "$CLEAN_CODE/proj"
add_worktree "$CLEAN_CODE/proj" only-branch
TASKS_DIR="$CLEAN_TASKS"
CODE_DIR="$CLEAN_CODE"
printf -- '---\nstatus: doing\nrepo: proj\nbranch: only-branch\nworktree: .worktrees/only-branch\ntags: []\ncreated: 2026-07-07\nclosed:\n---\n# Title\n' \
  > "$CLEAN_TASKS/proj--only.md"
wb_reconcile_repos() { printf '%s\n' "$CLEAN_CODE/proj"; }
out_clean="$(cmd_reconcile 2>&1)"; rc_clean=$?
assert "clean tree exits 0" '^' "$rc_clean-ok"; [ "$rc_clean" -eq 0 ] || { echo "FAIL - exit code $rc_clean: $out_clean"; fail=1; }
assert "clean tree reports no drift" 'no drift found' "$out_clean"

# Machine mode on a clean tree: prints NOTHING and exits 0 — distinct from
# the human mode's "no drift found" line above.
out_clean_m="$(cmd_reconcile --machine 2>&1)"; rc_clean_m=$?
assert "clean tree, machine mode: exits 0" '^' "$rc_clean_m-ok"; [ "$rc_clean_m" -eq 0 ] || { echo "FAIL - exit code $rc_clean_m: $out_clean_m"; fail=1; }
if [ -z "$out_clean_m" ]; then
  echo "ok   - clean tree, machine mode: prints nothing"
else
  echo "FAIL - clean tree, machine mode: expected empty output, got: $out_clean_m"; fail=1
fi

rm -rf "$CLEAN_CODE" "$CLEAN_TASKS"

# =============================================================================
# Duplicate detection (report-only, third finding kind): same jira on 2+
# non-done tasks, same branch/worktree claimed twice in one repo, doubled repo
# prefix in a task filename. Done tasks and legit same-base branches are NOT
# flagged. Uses its own fixture store; no git repos needed (frontmatter only),
# so wb_reconcile_repos yields nothing and orphan/missing stay empty.
# =============================================================================
DUP_TASKS="$(mktemp -d -t wb-reconcile-dup-tasks.XXXXXX)"
DUP_CODE="$(mktemp -d -t wb-reconcile-dup-code.XXXXXX)"
TASKS_DIR="$DUP_TASKS"
CODE_DIR="$DUP_CODE"
wb_reconcile_repos() { :; }
mk_dup() { # <file> <status> <repo> <branch> <worktree> <jira> [parent]
  printf -- '---\nstatus: %s\npath:\nrepo: %s\nbranch: %s\nworktree: %s\njira: %s\ntags: []\nparent: %s\ncreated: 2026-10-01\nclosed:\n---\n# T\n' \
    "$2" "$3" "$4" "$5" "$6" "${7:-}" > "$DUP_TASKS/$1"
}
# (a) same jira: one bare key, one URL form of the same key -> flagged once
mk_dup 'proj--jira-a.md' doing proj branch-ja '.worktrees/ja' 'SFB-100'
mk_dup 'proj--jira-b.md' planned proj branch-jb '.worktrees/jb' 'https://x.atlassian.net/browse/SFB-100'
# (b) same branch / same worktree, same repo
mk_dup 'proj--br-a.md' doing proj shared-branch '.worktrees/wt-a' ''
mk_dup 'proj--br-b.md' paused proj shared-branch '.worktrees/wt-b' ''
mk_dup 'proj--wt-a.md' doing proj branch-w1 '.worktrees/shared-wt' ''
mk_dup 'proj--wt-b.md' doing proj branch-w2 '.worktrees/shared-wt' ''
# (c) doubled repo prefix in the filename
mk_dup 'proj--proj--stutter.md' planned proj stutter-br '.worktrees/stutter' ''
# negatives: same branch name in a DIFFERENT repo; a done task sharing
# jira/branch/worktree with a live one; a doubled-prefix done file
mk_dup 'other--br-a.md' doing other shared-branch '.worktrees/other-a' ''
mk_dup 'proj--old-done.md' done proj shared-branch '.worktrees/shared-wt' 'SFB-100'
mk_dup 'proj--proj--old-stutter.md' done proj old-stutter-br '.worktrees/old-stutter' ''
mk_dup 'proj--solo.md' doing proj solo-br '.worktrees/solo' 'SFB-200'

# (d) multi-key and quoted jira values: "SFB-300, SFB-301" pairs with a task on
# either key; a quoted "SFB-302" matches a bare SFB-302
mk_dup 'proj--multi-a.md' doing proj branch-ma '.worktrees/ma' 'SFB-300, SFB-301'
mk_dup 'proj--multi-b.md' doing proj branch-mb '.worktrees/mb' 'SFB-301'
mk_dup 'proj--multi-c.md' doing proj branch-mc '.worktrees/mc' '"SFB-302"'
mk_dup 'proj--multi-d.md' doing proj branch-md '.worktrees/md' 'SFB-302'
# (e) families are not duplicates: a child sharing its parent's jira, a child
# that took over the parent's worktree, and two siblings sharing a branch.
# fam-c is unrelated and also shares the jira key, so that key still reports
# (fam-p, fam-c1 are paired through fam-c; fam-c2 sibling of fam-c1 is not).
mk_dup 'proj--fam-p.md' doing proj branch-fp '.worktrees/fp' 'SFB-400'
mk_dup 'proj--fam-c1.md' doing proj branch-fc1 '.worktrees/fp-mig' 'SFB-400' 'proj--fam-p'
mk_dup 'proj--fam-c2.md' doing proj branch-fc1 '.worktrees/fc2' '' 'proj--fam-p'
mk_dup 'proj--fam-x.md' doing proj branch-fx '.worktrees/fx' 'SFB-401'
mk_dup 'proj--fam-y.md' doing proj branch-fy '.worktrees/fy' 'SFB-401' 'proj--fam-x'
mk_dup 'proj--fam-z.md' doing proj branch-fz '.worktrees/fz' 'SFB-402' 'proj--fam-x'
mk_dup 'proj--fam-w.md' doing proj branch-fw '.worktrees/fw' 'SFB-402' 'proj--fam-x'
mk_dup 'proj--fam-u.md' doing proj branch-fu '.worktrees/fu' 'SFB-403' 'proj--fam-q'
mk_dup 'proj--fam-v.md' doing proj branch-fv '.worktrees/fv' 'SFB-403'
# (f) a file with no leading frontmatter: a later --- rule in the body must not
# open a fake frontmatter block whose fields then count as a branch claim
printf '# Notes\n\n---\nstatus: doing\nrepo: proj\nbranch: shared-branch\nworktree: .worktrees/nofm\n---\nbody\n' > "$DUP_TASKS/proj--nofm.md"
# every fixture worktree exists on disk, so no "missing" rows muddy the output
for wt in nofm fp fp-mig fc2 fx fy fz fw fu fv ma mb mc md ja jb wt-a wt-b shared-wt stutter other-a old-stutter solo; do
  mkdir -p "$DUP_CODE/proj/.worktrees/$wt" "$DUP_CODE/other/.worktrees/$wt"
done
out_d="$(cmd_reconcile --machine 2>&1)"; rc_d=$?
[ "$rc_d" -eq 0 ] || { echo "FAIL - dup machine mode exit code $rc_d"; fail=1; }
# Row-shape assertions run under the default awk AND a PATH-shimmed mawk (the
# live `wb` runs mawk; a leading-comma bug in the path list only shows there).
# Path lists must start with `/`, never `,` — hence [^,]* before each basename.
MAWK_SHIM_DIR="$(mktemp -d -t wb-reconcile-mawk-shim.XXXXXX)"
if [ ! -x /usr/bin/mawk ]; then
  echo "FAIL - mawk shim: /usr/bin/mawk not found, cannot verify mawk behaviour"; fail=1
else
  ln -s /usr/bin/mawk "$MAWK_SHIM_DIR/awk"
fi
out_dm="$(PATH="$MAWK_SHIM_DIR:$PATH" cmd_reconcile --machine 2>&1)"
check_dup_machine() { # <label> <output>
  assert "dup machine [$1]: jira class, key normalised across bare key and URL, both tasks listed, no leading comma" \
    '^duplicate	jira	proj	SFB-100	/[^,]*proj--jira-a\.md,/[^,]*proj--jira-b\.md$' "$2"
  assert "dup machine [$1]: branch class (same repo)" \
    '^duplicate	branch	proj	shared-branch	/[^,]*proj--br-a\.md,/[^,]*proj--br-b\.md$' "$2"
  assert "dup machine [$1]: worktree class (same repo)" \
    '^duplicate	worktree	proj	\.worktrees/shared-wt	/[^,]*proj--wt-a\.md,/[^,]*proj--wt-b\.md$' "$2"
  assert "dup machine [$1]: prefix class" \
    '^duplicate	prefix	proj	proj--proj--stutter	/[^,]*proj--proj--stutter\.md$' "$2"
  assert "dup machine [$1]: multi-key jira pairs on the shared second key" \
    '^duplicate	jira	proj	SFB-301	/[^,]*proj--multi-a\.md,/[^,]*proj--multi-b\.md$' "$2"
  assert "dup machine [$1]: quoted jira matches the bare key" \
    '^duplicate	jira	proj	SFB-302	/[^,]*proj--multi-c\.md,/[^,]*proj--multi-d\.md$' "$2"
  assert "dup machine [$1]: unshared first key SFB-300 not flagged" '^0$' "$(printf '%s\n' "$2" | /usr/bin/grep -c 'SFB-300	')"
  assert "dup machine [$1]: same-family jira (parent/child, siblings) not flagged" '^0$' "$(printf '%s\n' "$2" | /usr/bin/grep -cE 'SFB-40[012]|fam-p|fam-c|fam-[xyzw]')"
  assert "dup machine [$1]: unrelated tasks sharing a key still flagged" \
    '^duplicate	jira	proj	SFB-403	/[^,]*proj--fam-u\.md,/[^,]*proj--fam-v\.md$' "$2"
  assert "dup machine [$1]: body --- without line-1 frontmatter is not parsed" '^0$' "$(printf '%s\n' "$2" | /usr/bin/grep -c 'nofm')"
  assert "dup machine [$1]: exactly 7 duplicate rows" '^7$' "$(printf '%s\n' "$2" | /usr/bin/grep -c '^duplicate	')"
}
check_dup_machine default "$out_d"
check_dup_machine mawk "$out_dm"
for neg in 'other--br-a' 'old-done' 'old-stutter' 'proj--solo' 'SFB-200'; do
  if printf '%s' "$out_d" | /usr/bin/grep -q "$neg"; then
    echo "FAIL - dup negative: '$neg' must not be flagged"; fail=1
  else
    echo "ok   - dup negative: '$neg' not flagged (other repo / done / unique)"
  fi
done

out_dh="$(cmd_reconcile 2>&1)"; rc_dh=$?
[ "$rc_dh" -eq 0 ] || { echo "FAIL - dup human mode exit code $rc_dh"; fail=1; }
assert "dup human: section header" 'Duplicate task claims \(report-only\):' "$out_dh"
assert "dup human: header row" 'CLASS +REPO +KEY +TASKS' "$out_dh"
assert "dup human: jira row lists basenames, comma-joined" 'jira +proj +SFB-100 +proj--jira-a, proj--jira-b' "$out_dh"
assert "dup human: prefix row" 'prefix +proj +proj--proj--stutter +proj--proj--stutter' "$out_dh"
if printf '%s' "$out_dh" | /usr/bin/grep -q 'no drift found'; then
  echo "FAIL - dup human: duplicates present but 'no drift found' printed"; fail=1
else
  echo "ok   - dup human: not reported as no-drift"
fi

# Only-live-unique store: no duplicates -> existing 'no drift found' output.
rm -f "$DUP_TASKS"/proj--multi-[bcd].md "$DUP_TASKS"/proj--fam-*.md "$DUP_TASKS"/proj--nofm.md "$DUP_TASKS"/proj--jira-b.md "$DUP_TASKS"/proj--br-b.md "$DUP_TASKS"/proj--wt-b.md "$DUP_TASKS"/proj--proj--stutter.md
assert "dup cleared: human mode back to no drift" 'no drift found' "$(cmd_reconcile 2>&1)"
if [ -z "$(cmd_reconcile --machine 2>&1)" ]; then
  echo "ok   - dup cleared: machine mode prints nothing"
else
  echo "FAIL - dup cleared: machine mode not empty"; fail=1
fi

# The review-doc generator never sees duplicate rows (they have no action).
mk_dup 'proj--jira-b.md' planned proj branch-jb '.worktrees/jb' 'SFB-100'
mk_dup 'proj--ghost2.md' doing proj ghost2-br '.worktrees/ghost2' ''   # missing worktree -> a real review finding
REVIEW_PATH="$DUP_TASKS/review.md"
wb_reconcile_report_path() { printf '%s\n' "$REVIEW_PATH"; }
wb_open_buffer() { :; }
wb_reconcile_generate_review >/dev/null 2>&1
if /usr/bin/grep -q 'ghost2' "$REVIEW_PATH" && ! /usr/bin/grep -qi 'duplicate\|SFB-100\|jira-b' "$REVIEW_PATH"; then
  echo "ok   - review doc excludes duplicate findings (still has the real missing one)"
else
  echo "FAIL - review doc must hold the missing finding and no duplicate findings"; fail=1
fi

rm -rf "$DUP_TASKS" "$DUP_CODE" "$MAWK_SHIM_DIR"

[ "$fail" -eq 0 ] && echo "ALL PASS" || echo "FAILURES"
exit "$fail"
