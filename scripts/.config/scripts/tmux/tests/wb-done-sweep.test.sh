#!/usr/bin/env bash
# Tests for the `wb done` sweep classifier (wb_sweep_lists, wb_sweep_classify,
# the extended wb_credential_shaped). Runs the classifier assertions under the
# default awk and again under mawk.
#
# Run in the Docker sandbox (see tests/Dockerfile):
#   docker run --rm -v "$(pwd)":/repo:ro -w /repo wb-tests \
#     bash scripts/.config/scripts/tmux/tests/wb-done-sweep.test.sh
set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WB="$SELF_DIR/wb.sh"

FIXTURE="$(mktemp -d -t wb-done-sweep-fixture.XXXXXX)"
trap 'rm -rf "$FIXTURE"' EXIT

fail=0
assert_eq() { # <desc> <expected> <actual>
  if [ "$2" = "$3" ]; then echo "ok   - $1"
  else echo "FAIL - $1"; echo "       expected: $2"; echo "       got:      $3"; fail=1; fi
}
assert() { # <desc> <regex> <actual>
  if printf '%s' "$3" | grep -qE -- "$2"; then echo "ok   - $1"
  else echo "FAIL - $1"; echo "       expected match: $2"; echo "       got: $3"; fail=1; fi
}

export XDG_STATE_HOME="$FIXTURE/state"
export HOME="$FIXTURE/home"
export CODE_DIR="$FIXTURE/code"
export TASKS_DIR="$FIXTURE/tasks"
unset TMUX
mkdir -p "$XDG_STATE_HOME" "$HOME" "$CODE_DIR" "$TASKS_DIR"

# shellcheck disable=SC1090
source "$WB"
set +e

# cls <output> <path> — the class column of the line for <path>.
cls() { printf '%s\n' "$1" | awk -F'\t' -v p="$2" '$2 == p { print $1 }'; }
note() { printf '%s\n' "$1" | awk -F'\t' -v p="$2" '$2 == p { print $3 }'; }

git_q() { git -c user.email=t@t -c user.name=t "$@"; }

# mkrepo <name> <manifest-or-empty> — a main checkout plus a worktree of it.
mkrepo() {
  local name="$1" manifest="$2" main="$FIXTURE/$1/main"
  mkdir -p "$main"
  git init -q "$main"
  printf 'node_modules/\ndist\nlogs/\n*.log\n.env*\nconfig.hjson\n.claude/\nscratch/\nCLAUDE.local.md\n.claude-queue.md\napps/\nkeepdir/\nbootdir\nextra.txt\nstray.txt\nnotes.txt\nokdir/\n' > "$main/.gitignore"
  [ -n "$manifest" ] && printf '%b' "$manifest" > "$main/.worktree-bootstrap"
  git_q -C "$main" add -A
  git_q -C "$main" commit -q -m init
  git_q -C "$main" worktree add -q -b "wt-$name" "$FIXTURE/$name/wt"
  echo "$FIXTURE/$name"
}

run_all() { # <label>
  local L="$1" R MAIN WT out
  R="$(mkrepo "a$L" 'config.hjson\n.env\n.claude/settings.local.json # comment\nbootdir\n')"
  MAIN="$R/main"; WT="$R/wt"
  printf 'x' > "$MAIN/config.hjson"; cp "$MAIN/config.hjson" "$WT/config.hjson"
  printf 'E=1' > "$MAIN/.env"; printf 'E=1' > "$WT/.env"
  mkdir -p "$MAIN/.claude" "$WT/.claude" "$MAIN/bootdir"
  printf '{}' > "$MAIN/.claude/settings.local.json"; cp "$MAIN/.claude/settings.local.json" "$WT/.claude/"
  ln -s "$MAIN/bootdir" "$WT/bootdir"
  printf 'q' > "$WT/.claude-queue.md"
  mkdir -p "$WT/node_modules/pkg" "$WT/apps/web/node_modules" "$WT/logs"
  printf 's' > "$WT/node_modules/pkg/aws-credentials.js"
  : > "$WT/app.log"; : > "$WT/apps/web/node_modules/x"
  ln -s "$MAIN/bootdir" "$WT/dist"
  mkdir -p "$WT/scratch" "$WT/keepdir/sub"
  printf 'n' > "$WT/scratch/notes.txt"
  printf 'p' > "$WT/keepdir/sub/.env"
  ln -s "$MAIN/config.hjson" "$WT/keepdir/outlink"
  printf 'g' > "$WT/stray.txt"
  # an ordinary kept dir
  mkdir -p "$WT/okdir"; printf 'ok' > "$WT/okdir/f.txt"

  out="$(wb_sweep_classify "$WT" "$MAIN" 2>"$FIXTURE/err.$L")"
  assert_eq "[$L] .claude-queue.md keeps" keep "$(cls "$out" .claude-queue.md)"
  assert_eq "[$L] node_modules/ throwaway" throwaway "$(cls "$out" node_modules/)"
  assert_eq "[$L] node_modules/ not walked (aws-credentials.js unseen)" "" "$(cls "$out" node_modules/pkg/aws-credentials.js)"
  assert_eq "[$L] app.log throwaway" throwaway "$(cls "$out" app.log)"
  assert_eq "[$L] nested apps/web/node_modules throwaway" throwaway "$(cls "$out" apps/web/node_modules/x)"
  assert_eq "[$L] bootstrap config.hjson identical to main throwaway" throwaway "$(cls "$out" config.hjson)"
  assert_eq "[$L] bootstrap .env identical throwaway" throwaway "$(cls "$out" .env)"
  assert_eq "[$L] bootstrap dir symlink throwaway" throwaway "$(cls "$out" bootdir)"
  assert_eq "[$L] symlinked dist (list match) throwaway" throwaway "$(cls "$out" dist)"
  assert_eq "[$L] collapsed .claude/ expands; bootstrap settings.local.json identical throwaway" throwaway "$(cls "$out" .claude/settings.local.json)"
  assert_eq "[$L] unlisted scratch/ file unknown" unknown "$(cls "$out" scratch/notes.txt)"
  assert_eq "[$L] kept dir via glob-less path: unlisted dir expands, nested .env unknown" unknown "$(cls "$out" keepdir/sub/.env)"
  assert_eq "[$L] stray.txt unknown" unknown "$(cls "$out" stray.txt)"
  assert_eq "[$L] an unlisted dir expands to its file" unknown "$(cls "$out" okdir/f.txt)"

  # byte change to bootstrap file -> unknown with credential note
  printf 'xy' > "$WT/config.hjson"
  out="$(wb_sweep_classify "$WT" "$MAIN" 2>/dev/null)"
  assert_eq "[$L] edited config.hjson unknown" unknown "$(cls "$out" config.hjson)"
  assert "[$L] edited config.hjson has credential note" 'credential-shaped' "$(note "$out" config.hjson)"
  printf 'x' > "$WT/config.hjson"

  # extra unlisted file beside the bootstrap file in .claude/
  printf 'z' > "$WT/.claude/extra.txt"
  out="$(wb_sweep_classify "$WT" "$MAIN" 2>/dev/null)"
  assert_eq "[$L] .claude/extra.txt unknown" unknown "$(cls "$out" .claude/extra.txt)"
  assert_eq "[$L] .claude/settings.local.json still throwaway" throwaway "$(cls "$out" .claude/settings.local.json)"
  rm -f "$WT/.claude/extra.txt"

  # --keep / --throwaway
  out="$(wb_sweep_classify "$WT" "$MAIN" --keep scratch/notes.txt 2>/dev/null)"
  assert_eq "[$L] --keep scratch/notes.txt keeps" keep "$(cls "$out" scratch/notes.txt)"
  out="$(wb_sweep_classify "$WT" "$MAIN" --keep .env 2>/dev/null)"
  assert_eq "[$L] --keep .env unknown" unknown "$(cls "$out" .env)"
  assert "[$L] --keep .env credential note" 'credential-shaped' "$(note "$out" .env)"
  out="$(wb_sweep_classify "$WT" "$MAIN" --keep keepdir 2>/dev/null)"
  assert_eq "[$L] kept dir holding nested .env unknown" unknown "$(cls "$out" keepdir/)"
  assert "[$L] kept dir note names the nested file" 'keepdir/sub/.env' "$(note "$out" keepdir/)"
  out="$(wb_sweep_classify "$WT" "$MAIN" --keep okdir/ 2>/dev/null)"
  assert_eq "[$L] --keep okdir/ (trailing slash stripped) keeps dir" keep "$(cls "$out" okdir/)"
  rm -rf "$WT/keepdir/sub"
  out="$(wb_sweep_classify "$WT" "$MAIN" --keep keepdir 2>/dev/null)"
  assert_eq "[$L] kept dir holding symlink to outside file unknown" unknown "$(cls "$out" keepdir/)"
  assert "[$L] outside-symlink note" 'outside' "$(note "$out" keepdir/)"
  out="$(wb_sweep_classify "$WT" "$MAIN" --throwaway bootdir --throwaway stray.txt 2>/dev/null)"
  assert_eq "[$L] --throwaway on a bootstrap symlink" throwaway "$(cls "$out" bootdir)"
  assert_eq "[$L] --throwaway stray.txt" throwaway "$(cls "$out" stray.txt)"
  printf 'h' > "$WT/scratch/stray.txt"
  out="$(wb_sweep_classify "$WT" "$MAIN" --throwaway stray.txt 2>/dev/null)"
  assert_eq "[$L] --throwaway names one exact path, not a name at any depth" unknown "$(cls "$out" scratch/stray.txt)"
  rm -f "$WT/scratch/stray.txt"
  out="$(wb_sweep_classify "$WT" "$MAIN" --throwaway /stray.txt 2>"$FIXTURE/abs.err.$L")"
  assert "[$L] absolute --throwaway rejected" '--throwaway /stray.txt: outside' "$(cat "$FIXTURE/abs.err.$L")"
  out="$(wb_sweep_classify "$WT" "$MAIN" --throwaway gone.txt 2>"$FIXTURE/gone.err.$L")"; rc=$?
  assert_eq "[$L] --throwaway absent path exits 0" 0 "$rc"
  assert "[$L] --throwaway absent path warns" 'gone.txt' "$(cat "$FIXTURE/gone.err.$L")"
  out="$(wb_sweep_classify "$WT" "$MAIN" --keep ../escape --keep /etc/hostname --throwaway ../x 2>"$FIXTURE/esc.err.$L")"; rc=$?
  assert_eq "[$L] escaping flag paths exit 0" 0 "$rc"
  assert "[$L] escaping --keep rejected with warning" '--keep \.\./escape' "$(cat "$FIXTURE/esc.err.$L")"
  assert "[$L] absolute --keep rejected" '--keep /etc/hostname' "$(cat "$FIXTURE/esc.err.$L")"
  assert "[$L] escaping --throwaway rejected" '--throwaway \.\./x' "$(cat "$FIXTURE/esc.err.$L")"
  wb_sweep_classify "$WT" "$MAIN" --bogus x >/dev/null 2>&1; rc=$?
  assert_eq "[$L] unknown argument returns 2" 2 "$rc"

  # no-manifest repo: root .env* are the bootstrap entries
  R="$(mkrepo "b$L" '')"; MAIN="$R/main"; WT="$R/wt"
  printf 'E=1' > "$MAIN/.env"; printf 'E=1' > "$WT/.env"
  out="$(wb_sweep_classify "$WT" "$MAIN" 2>/dev/null)"
  assert_eq "[$L] no manifest: unchanged .env throwaway" throwaway "$(cls "$out" .env)"
  printf 'E=2' > "$WT/.env"
  out="$(wb_sweep_classify "$WT" "$MAIN" 2>/dev/null)"
  assert_eq "[$L] no manifest: edited .env unknown" unknown "$(cls "$out" .env)"
  assert "[$L] no manifest: edited .env credential note" 'credential-shaped' "$(note "$out" .env)"
}

# --- list loader
cat > "$FIXTURE/test.list" <<'LIST'
# a comment

keep:.claude-queue.md   
   throwaway:node_modules/  
  # indented comment
bogus line
throwaway:*.log
LIST
WB_SWEEP_LIST="$FIXTURE/test.list" wb_sweep_lists > "$FIXTURE/lists.out"
assert_eq "list loader: comments, blanks, trailing spaces" \
  "$(printf 'keep\t.claude-queue.md\nthrowaway\tnode_modules/\nthrowaway\t*.log')" "$(cat "$FIXTURE/lists.out")"
real="$(wb_sweep_lists)"
assert "real list file seeds keep CLAUDE.local.md" $'keep\tCLAUDE.local.md' "$real"
assert "real list file seeds throwaway __pycache__/" $'throwaway\t__pycache__/' "$real"

# --- credential patterns
for f in config.hjson prod.env.json .npmrc .netrc a.tfvars .pgpass id_ecdsa id_ecdsa.pub x.keystore p.kdbx api-token.txt MyPassword.md CONFIG.HJSON .env; do
  wb_credential_shaped "dir/$f"; assert_eq "credential-shaped: $f" 0 "$?"
done
for f in readme.md app.log notes.txt; do
  wb_credential_shaped "dir/$f"; assert_eq "not credential-shaped: $f" 1 "$?"
done
shopt -s nocasematch; wb_credential_shaped x.md; shopt -q nocasematch
assert_eq "nocasematch left on when caller had it on" 0 "$?"
shopt -u nocasematch; wb_credential_shaped x.pem; shopt -q nocasematch
assert_eq "nocasematch left off when caller had it off" 1 "$?"

run_all gawk
MAWKDIR="$FIXTURE/awkshim-mawk"; mkdir -p "$MAWKDIR"
if command -v mawk >/dev/null; then
  ln -sf "$(command -v mawk)" "$MAWKDIR/awk"
  OLD_PATH="$PATH"; PATH="$MAWKDIR:$PATH"; hash -r
  assert_eq "awk shim resolves to mawk" "$MAWKDIR/awk" "$(command -v awk)"
  run_all mawk
  PATH="$OLD_PATH"; hash -r
else
  echo "FAIL - mawk not installed"; fail=1
fi

exit $fail
