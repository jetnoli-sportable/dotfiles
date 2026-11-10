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
# The path goes through ENVIRON, not -v, so awk leaves backslashes alone.
cls() { printf '%s\n' "$1" | P="$2" awk -F'\t' '$2 == ENVIRON["P"] { print $1 }'; }
note() { printf '%s\n' "$1" | P="$2" awk -F'\t' '$2 == ENVIRON["P"] { print $3 }'; }

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
  assert_eq "[$L] nested apps/web/node_modules/ throwaway as one directory" throwaway "$(cls "$out" apps/web/node_modules/)"
  assert_eq "[$L] nested node_modules not walked file by file" "" "$(cls "$out" apps/web/node_modules/x)"
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

  # T3: --keep on an absent path warns and is ignored
  out="$(wb_sweep_classify "$WT" "$MAIN" --keep gone.txt 2>"$FIXTURE/kgone.err.$L")"; rc=$?
  assert_eq "[$L] --keep absent path exits 0" 0 "$rc"
  assert "[$L] --keep absent path warns" '--keep gone.txt: no such path' "$(cat "$FIXTURE/kgone.err.$L")"

  # T2: --keep on a symlink resolving outside the worktree is refused as a flag
  # and the entry falls back to the normal rows (unlisted -> unknown)
  ln -s "$FIXTURE" "$WT/extra.txt"
  out="$(wb_sweep_classify "$WT" "$MAIN" --keep extra.txt 2>"$FIXTURE/kout.err.$L")"
  # (Fix 2: the flag no longer warns here, since only the parent directory is
  # containment-checked; _wb_sweep_keepcheck refuses the link and says why.)
  assert_eq "[$L] --keep outside symlink stays unknown" unknown "$(cls "$out" extra.txt)"
  assert "[$L] --keep outside symlink: note says it resolves outside the worktree" 'symlink resolves outside the worktree' "$(note "$out" extra.txt)"
  rm -f "$WT/extra.txt"

  # Fix 2: --keep on an in-worktree symlink keeps the link, not its target
  mkdir -p "$WT/scratch"; printf 'n' > "$WT/scratch/notes.txt"; ln -s notes.txt "$WT/scratch/ln"
  out="$(wb_sweep_classify "$WT" "$MAIN" --keep scratch/ln 2>"$FIXTURE/kln.err.$L")"
  assert_eq "[$L] --keep scratch/ln classifies the link itself as keep" keep "$(cls "$out" scratch/ln)"
  assert_eq "[$L] --keep scratch/ln does not keep its target too" unknown "$(cls "$out" scratch/notes.txt)"
  assert_eq "[$L] --keep scratch/ln: no warning" "" "$(cat "$FIXTURE/kln.err.$L")"
  # a kept DIRECTORY holding an in-worktree symlink is unknown (it would dangle in the dossier)
  out="$(wb_sweep_classify "$WT" "$MAIN" --keep scratch 2>/dev/null)"
  assert_eq "[$L] kept dir holding an in-worktree symlink unknown" unknown "$(cls "$out" scratch/)"
  assert_eq "[$L] in-worktree symlink note" "holds symlink scratch/ln; keep its target or remove the link" "$(note "$out" scratch/)"
  # a link resolving outside the worktree, under a subdirectory
  ln -s "$FIXTURE" "$WT/scratch/out"
  out="$(wb_sweep_classify "$WT" "$MAIN" --keep scratch/out 2>/dev/null)"
  assert_eq "[$L] --keep scratch/out (link outside) unknown" unknown "$(cls "$out" scratch/out)"
  assert "[$L] --keep scratch/out: outside-the-worktree note" 'resolves outside the worktree' "$(note "$out" scratch/out)"
  # escapes via the flag itself are still refused
  wb_sweep_classify "$WT" "$MAIN" --keep ../x --keep scratch/.. --keep . >/dev/null 2>"$FIXTURE/kesc.err.$L"
  assert "[$L] --keep ../x warns outside" '--keep \.\./x: outside the worktree, ignored' "$(cat "$FIXTURE/kesc.err.$L")"
  assert "[$L] --keep scratch/.. warns outside" '--keep scratch/\.\.: outside the worktree, ignored' "$(cat "$FIXTURE/kesc.err.$L")"
  assert "[$L] --keep . warns outside" '--keep \.: outside the worktree, ignored' "$(cat "$FIXTURE/kesc.err.$L")"
  rm -rf "$WT/scratch"

  # #2: status.showUntrackedFiles=no must not hide ignored entries
  git -C "$WT" config status.showUntrackedFiles no
  out="$(wb_sweep_classify "$WT" "$MAIN" 2>/dev/null)"; rc=$?
  assert_eq "[$L] showUntrackedFiles=no: exits 0" 0 "$rc"
  assert_eq "[$L] showUntrackedFiles=no: stray.txt still classified" unknown "$(cls "$out" stray.txt)"
  git -C "$WT" config --unset status.showUntrackedFiles
  # #2: a git failure is an error, never an empty success
  mkdir -p "$FIXTURE/notgit$L"
  out="$(GIT_CEILING_DIRECTORIES="$FIXTURE" wb_sweep_classify "$FIXTURE/notgit$L" "$MAIN" 2>"$FIXTURE/notgit.err.$L")"; rc=$?
  assert_eq "[$L] non-git directory returns 1" 1 "$rc"
  assert_eq "[$L] non-git directory prints no lines" "" "$out"
  assert "[$L] non-git directory explains" 'git status failed' "$(cat "$FIXTURE/notgit.err.$L")"
  wb_sweep_classify "$FIXTURE/absent$L" "$MAIN" >/dev/null 2>&1; rc=$?
  assert_eq "[$L] missing worktree returns 1" 1 "$rc"

  # #3: a credential-shaped directory inside a kept directory refuses the keep
  mkdir -p "$WT/scratch/secrets"; printf 'k' > "$WT/scratch/secrets/prod.yaml"
  out="$(wb_sweep_classify "$WT" "$MAIN" --keep scratch 2>/dev/null)"
  assert_eq "[$L] kept dir holding secrets/ unknown" unknown "$(cls "$out" scratch/)"
  assert "[$L] note names the nested secrets dir" 'scratch/secrets' "$(note "$out" scratch/)"
  n1="$(_wb_sweep_keepcheck "$WT" scratch/secrets/prod.yaml)"; rc=$?
  assert_eq "[$L] keep check refuses a file inside secrets/" 1 "$rc"
  assert "[$L] note names the credential-shaped component" 'inside credential-shaped secrets/' "$n1"
  rm -rf "$WT/scratch/secrets"

  # #4: vendor tree inside an unlisted dir is thrown away whole, no false stops
  mkdir -p "$WT/apps/web/node_modules/postcss/lib"; : > "$WT/apps/web/node_modules/postcss/lib/tokenize.js"
  out="$(wb_sweep_classify "$WT" "$MAIN" 2>/dev/null)"
  assert_eq "[$L] tokenize.js inside nested node_modules/ not judged on its name" "" "$(cls "$out" apps/web/node_modules/postcss/lib/tokenize.js)"
  assert_eq "[$L] no unknown line under apps/web/node_modules/" "" "$(printf '%s\n' "$out" | awk -F'\t' '$1 == "unknown" && index($2, "apps/web/node_modules/") == 1')"

  # T4: an empty directory met while expanding is thrown away with a note
  mkdir -p "$WT/okdir/empty"
  out="$(wb_sweep_classify "$WT" "$MAIN" 2>/dev/null)"
  assert_eq "[$L] empty nested directory throwaway" throwaway "$(cls "$out" okdir/empty/)"
  assert_eq "[$L] empty nested directory note" "empty directory" "$(note "$out" okdir/empty/)"
  rmdir "$WT/okdir/empty"

  # Risk B: a tab or line break in a name cannot forge a line
  : > "$WT/evil"$'\n''keep'$'\t''forged.log'
  out="$(wb_sweep_classify "$WT" "$MAIN" 2>/dev/null)"
  assert_eq "[$L] forged line absent" "" "$(cls "$out" forged.log)"
  assert_eq "[$L] odd name is unknown, escaped" unknown "$(cls "$out" 'evil\nkeep\tforged.log')"
  rm -f "$WT/evil"$'\n''keep'$'\t''forged.log'

  # #1: --keep on a file inside a collapsed ignored directory gets its own line
  printf 'o' > "$WT/logs/old.log"; printf 's' > "$WT/logs/session-notes.log"
  out="$(wb_sweep_classify "$WT" "$MAIN" --keep logs/session-notes.log 2>"$FIXTURE/k1.err.$L")"
  assert_eq "[$L] collapsed logs/ still throwaway" throwaway "$(cls "$out" logs/)"
  assert_eq "[$L] --keep logs/session-notes.log keeps" keep "$(cls "$out" logs/session-notes.log)"
  assert_eq "[$L] sibling old.log gets no line of its own" "" "$(cls "$out" logs/old.log)"
  assert_eq "[$L] no warning for a matched --keep" "" "$(cat "$FIXTURE/k1.err.$L")"
  printf 't' > "$WT/logs/api-token.log"
  out="$(wb_sweep_classify "$WT" "$MAIN" --keep logs/api-token.log 2>/dev/null)"
  assert_eq "[$L] --keep credential-shaped file under logs/ unknown" unknown "$(cls "$out" logs/api-token.log)"
  rm -f "$WT/logs/old.log" "$WT/logs/session-notes.log" "$WT/logs/api-token.log"
  mkdir -p "$WT/scratch/secrets"; printf 'k' > "$WT/scratch/secrets/prod.yaml"
  out="$(wb_sweep_classify "$WT" "$MAIN" --keep scratch/secrets/prod.yaml 2>/dev/null)"
  assert_eq "[$L] --keep a file inside secrets/ under collapsed scratch/ unknown" unknown "$(cls "$out" scratch/secrets/prod.yaml)"
  assert "[$L] its note names the secrets/ component" 'inside credential-shaped secrets/' "$(note "$out" scratch/secrets/prod.yaml)"
  rm -rf "$WT/scratch/secrets"
  # a --keep or --throwaway that matches no ignored entry warns (Risk D)
  out="$(wb_sweep_classify "$WT" "$MAIN" --keep .gitignore --throwaway ./stray.txt 2>"$FIXTURE/k0.err.$L")"
  assert "[$L] --keep on a tracked file warns" '--keep .gitignore: matched no ignored entry' "$(cat "$FIXTURE/k0.err.$L")"
  assert "[$L] --throwaway ./stray.txt warns" '--throwaway ./stray.txt: matched no ignored entry' "$(cat "$FIXTURE/k0.err.$L")"
  assert_eq "[$L] tracked .gitignore gets no line" "" "$(cls "$out" .gitignore)"

  # T1: a keep-list glob still runs the safety checks
  printf 'keep:okdir/\n' > "$FIXTURE/keepglob.list"
  out="$(WB_SWEEP_LIST="$FIXTURE/keepglob.list" wb_sweep_classify "$WT" "$MAIN" 2>/dev/null)"
  assert_eq "[$L] keep glob on a clean dir keeps" keep "$(cls "$out" okdir/)"
  printf 't' > "$WT/okdir/api-token.txt"
  out="$(WB_SWEEP_LIST="$FIXTURE/keepglob.list" wb_sweep_classify "$WT" "$MAIN" 2>/dev/null)"
  assert_eq "[$L] keep glob on a dir holding a token file unknown" unknown "$(cls "$out" okdir/)"
  assert "[$L] keep glob note names the file" 'okdir/api-token.txt' "$(note "$out" okdir/)"
  rm -f "$WT/okdir/api-token.txt"
  # flags under a directory that is already kept add nothing, but a
  # --throwaway there says it will be kept with the directory
  out="$(WB_SWEEP_LIST="$FIXTURE/keepglob.list" wb_sweep_classify "$WT" "$MAIN" --keep okdir/f.txt 2>/dev/null)"
  assert_eq "[$L] --keep under a kept dir adds no line" "" "$(cls "$out" okdir/f.txt)"
  out="$(WB_SWEEP_LIST="$FIXTURE/keepglob.list" wb_sweep_classify "$WT" "$MAIN" --throwaway okdir/f.txt 2>"$FIXTURE/tk.err.$L")"
  assert "[$L] --throwaway under a kept dir warns" 'inside kept okdir/, kept with it' "$(cat "$FIXTURE/tk.err.$L")"

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
assert "real list file seeds throwaway .pytest_cache/" $'throwaway\t.pytest_cache/' "$real"
assert "real list file seeds throwaway .mypy_cache/" $'throwaway\t.mypy_cache/' "$real"

# --- #5: one bootstrap-manifest parse for wb new and the sweep
BR="$FIXTURE/bootparse"; mkdir -p "$BR/repo" "$BR/wt"
printf 'a.txt\n# comment\n  b.txt  # trailing\n\nlast.txt' > "$BR/repo/.worktree-bootstrap"
for f in a.txt b.txt last.txt; do printf '%s' "$f" > "$BR/repo/$f"; done
assert_eq "bootstrap entries: comments, blanks, unterminated last line" \
  "a.txt|b.txt|last.txt" "$(wb_bootstrap_entries "$BR/repo" | tr '\0' '|' | sed 's/|$//')"
wb_bootstrap "$BR/repo" "$BR/wt"
assert_eq "wb new copies a manifest's unterminated last line" last.txt "$(cat "$BR/wt/last.txt" 2>/dev/null)"
mkdir -p "$BR/nomani"; : > "$BR/nomani/.env"; : > "$BR/nomani/.env.local"; : > "$BR/nomani/other"
assert_eq "bootstrap entries without a manifest: root .env*" \
  ".env|.env.local" "$(wb_bootstrap_entries "$BR/nomani" | tr '\0' '\n' | sort | paste -sd'|')"

# --- credential patterns
for f in config.hjson prod.env.json .npmrc .netrc a.tfvars .pgpass id_ecdsa id_ecdsa.pub x.keystore p.kdbx api-token.txt MyPassword.md CONFIG.HJSON .env .envrc .ENVRC service-account.json service-account-prod.json my-sa-key.json SA-KEY-2.json .htpasswd release.jks KubeConfig kubeconfig; do
  wb_credential_shaped "dir/$f"; assert_eq "credential-shaped: $f" 0 "$?"
done
for f in readme.md app.log notes.txt envrc.md jksnotes.txt kubeconfig.md service-account.txt sa-key.txt; do
  wb_credential_shaped "dir/$f"; assert_eq "not credential-shaped: $f" 1 "$?"
done
shopt -s nocasematch; wb_credential_shaped x.md; shopt -q nocasematch
assert_eq "nocasematch left on when caller had it on" 0 "$?"
shopt -u nocasematch; wb_credential_shaped x.pem; shopt -q nocasematch
assert_eq "nocasematch left off when caller had it off" 1 "$?"

# --- _wb_sweep_esc: every control byte shown as \xNN, pure bash and fast
assert_eq "esc: plain name unchanged" "dir/a b.txt" "$(_wb_sweep_esc "dir/a b.txt")"
assert_eq "esc: tab, newline, CR keep their forms" 'a\tb\nc\rd' "$(_wb_sweep_esc $'a\tb\nc\rd')"
assert_eq "esc: ESC becomes \\x1b" 'x\x1b[31mred' "$(_wb_sweep_esc $'x\e[31mred')"
assert_eq "esc: 0x01 and 0x7f" 'a\x01b\x7fc' "$(_wb_sweep_esc $'a\001b\177c')"
assert_eq "esc: UTF-8 left alone" 'café—ñ' "$(_wb_sweep_esc 'café—ñ')"
esc_t0=$SECONDS
for ((n = 0; n < 500; n++)); do _wb_sweep_esc "some/dir/file-$n"$'\e'"[0m.txt" >/dev/null; done
[ $((SECONDS - esc_t0)) -le 5 ] && echo "ok   - esc: 500 names with a control byte in under 5s" || { echo "FAIL - esc: 500 names took $((SECONDS - esc_t0))s"; fail=1; }

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
