#!/usr/bin/env bash
# Tests for format-on-edit-hook.sh, the PostToolUse hook that formats an edited
# file when the formatter table, the work-plugin skip and the "HEAD version was
# already clean" check all allow it.
#
# Fake formatters on PATH record their argv and "format" by rewriting marker
# strings. Each fails in stdin mode unless given the file's real path, so a
# clean-check that drops the path fails here. Needs jq and git.
#
# Run: bash scripts/.config/scripts/tmux/tests/format-on-edit-hook.test.sh
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK="${HOOK:-$HERE/../format-on-edit-hook.sh}"
PAYLOAD_FIXTURE="$HERE/fixtures/hook-payloads/PostToolUse-Write.json"
EDIT_FIXTURE="$HERE/fixtures/hook-payloads/PostToolUse-Edit.json"
ROOT="$(mktemp -d -t format-hook.XXXXXX)"
trap 'rm -rf "$ROOT"' EXIT

FIXTURE_HOME="$ROOT/home"
SHIMS="$ROOT/shims"
MASON="$FIXTURE_HOME/.local/share/nvim/mason/bin"
FMT_LOG="$ROOT/fmt.log"
mkdir -p "$FIXTURE_HOME/.claude" "$FIXTURE_HOME/code/tasks" "$SHIMS" "$MASON"
export FMT_LOG

fail=0
[ -x "$HOOK" ] || { echo "FAIL - hook is not executable (Claude Code runs it directly): $HOOK"; fail=1; }
[ -f "$PAYLOAD_FIXTURE" ] || { echo "FAIL - missing payload fixture $PAYLOAD_FIXTURE"; fail=1; }

# One shim body serves every formatter; it behaves per $0's basename.
# Marker UNFORMATTED -> formatted. goimports -> imported, gofumpt: imported ->
# formatted, so the go chain only finishes when both run in order.
cat >"$ROOT/shim-body" <<'SHIM'
#!/usr/bin/env bash
name="$(basename "$0")"
printf '%s %s\n' "$name" "$*" >>"$FMT_LOG"
[ "${FMT_FAIL:-}" = "$name" ] && exit 1
case "$name" in
  goimports) tr_cmd=(sed 's/UNFORMATTED/imported/g') ;;
  gofumpt) tr_cmd=(sed 's/imported/formatted/g') ;;
  *) tr_cmd=(sed 's/UNFORMATTED/formatted/g') ;;
esac
has() { local a; for a in "${@:2}"; do [ "$a" = "$1" ] && return 0; done; return 1; }
case "$name" in
  shfmt)     has -w "$@" && mode=file || mode=stdin; pathflag=--filename ;;
  stylua)    has - "$@" && mode=stdin || mode=file; pathflag=--stdin-filepath ;;
  prettier)  has --write "$@" && mode=file || mode=stdin; pathflag=--stdin-filepath ;;
  goimports) has -w "$@" && mode=file || mode=stdin; pathflag=-srcdir ;;
  gofumpt)   has -w "$@" && mode=file || mode=stdin; pathflag= ;;
esac
if [ "$mode" = stdin ]; then
  [ -z "$pathflag" ] || has "$pathflag" "$@" || exit 3
  "${tr_cmd[@]}"
else
  f="${*: -1}"
  "${tr_cmd[@]}" "$f" >"$f.tmp" && mv "$f.tmp" "$f"
fi
SHIM
chmod +x "$ROOT/shim-body"
for t in stylua prettier shfmt goimports gofumpt; do cp "$ROOT/shim-body" "$SHIMS/$t"; done

run_hook() { # <payload-json> -> sets out, rc
  out="$(printf '%s' "$1" | env HOME="$FIXTURE_HOME" PATH="$SHIMS:/usr/bin:/bin" "$HOOK" 2>/dev/null)"
  rc=$?
}
payload_for() { # <file> [fixture] -> payload built from a captured real payload
  jq --arg f "$1" --arg cwd "$(dirname "$1")" \
    '.cwd=$cwd | .tool_input.file_path=$f' "${2:-$PAYLOAD_FIXTURE}"
}
mkrepo() { # <dir>
  mkdir -p "$1"
  git -C "$1" init -q
  git -C "$1" config user.name t
  git -C "$1" config user.email t@t
}
commit_file() { # <repo> <relpath> <content>
  mkdir -p "$(dirname "$1/$2")"
  printf '%s\n' "$3" >"$1/$2"
  git -C "$1" add "$2"
  git -C "$1" commit -q -m c
}
plugin() { # on|off
  printf '{"enabledPlugins":{"sportable@sportabletech-harness":%s}}\n' \
    "$([ "$1" = on ] && echo true || echo false)" >"$FIXTURE_HOME/.claude/settings.json"
}
check() { # <name> <condition-result: 0 pass>
  if [ "$2" = 0 ]; then echo "ok   - $1"; else echo "FAIL - $1"; fail=1; fi
}
content_is() { [ "$(cat "$1")" = "$2" ]; }
log_has() { /usr/bin/grep -q -- "$1" "$FMT_LOG" 2>/dev/null; }
quiet_ok() { [ "$rc" = 0 ] && [ -z "$out" ]; }
log_empty() { [ ! -s "$FMT_LOG" ]; }
reset() { : >"$FMT_LOG"; }

plugin off

# --- formatter table ----------------------------------------------------
R="$ROOT/r1"; mkrepo "$R"
commit_file "$R" a.lua 'local x = formatted'
echo 'local x = UNFORMATTED' >"$R/a.lua"
reset; run_hook "$(payload_for "$R/a.lua")"
check "clean HEAD .lua: stylua runs, file formatted, silent exit 0" \
  "$(content_is "$R/a.lua" 'local x = formatted' && log_has '^stylua ' && [ "$rc" = 0 ] && [ -z "$out" ]; echo $?)"
check "clean-check passed the real path (stylua --stdin-filepath)" \
  "$(log_has "stylua .*--stdin-filepath $R/a.lua" && echo 0 || echo 1)"

reset; run_hook "$(payload_for "$R/a.lua" "$EDIT_FIXTURE")"
check "real Edit payload shape works too" "$(quiet_ok; echo $?)"

R="$ROOT/r2"; mkrepo "$R"
commit_file "$R" a.lua 'local x = UNFORMATTED'
echo 'local x = UNFORMATTED more' >"$R/a.lua"
reset; run_hook "$(payload_for "$R/a.lua")"
check "unclean HEAD .lua: file left alone, no in-place call" \
  "$(content_is "$R/a.lua" 'local x = UNFORMATTED more' && ! log_has 'stylua [^-]*a.lua$' && [ "$rc" = 0 ]; echo $?)"

R="$ROOT/r3"; mkrepo "$R"
commit_file "$R" readme.txt hi
echo 'const a = UNFORMATTED' >"$R/new.ts"
reset; run_hook "$(payload_for "$R/new.ts")"
check "new untracked .ts: prettier --write runs" \
  "$(content_is "$R/new.ts" 'const a = formatted' && log_has "^prettier --write $R/new.ts" && echo 0 || echo 1)"

# staged-but-never-committed file in a repo that has a HEAD commit
echo 'const b = UNFORMATTED' >"$R/staged.ts"; git -C "$R" add staged.ts
reset; run_hook "$(payload_for "$R/staged.ts")"
check "added-but-uncommitted file counts as new" \
  "$(content_is "$R/staged.ts" 'const b = formatted'; echo $?)"

R="$ROOT/r4"; mkrepo "$R"
commit_file "$R" x.txt hi
printf 'echo UNFORMATTED\n' >"$R/s.sh"
printf '#!/usr/bin/env bash\necho UNFORMATTED\n' >"$R/runme"
printf '#!/bin/sh\necho UNFORMATTED\n' >"$R/runsh"
printf 'plain UNFORMATTED text\n' >"$R/notes"
printf '#!/usr/bin/env python3\nUNFORMATTED\n' >"$R/py"
reset; run_hook "$(payload_for "$R/s.sh")"
check ".sh goes to shfmt" "$(content_is "$R/s.sh" 'echo formatted' && log_has "^shfmt -w $R/s.sh"; echo $?)"
run_hook "$(payload_for "$R/runme")"
check "extensionless bash shebang goes to shfmt" "$(content_is "$R/runme" "$(printf '#!/usr/bin/env bash\necho formatted')"; echo $?)"
run_hook "$(payload_for "$R/runsh")"
check "extensionless /bin/sh shebang goes to shfmt" "$(content_is "$R/runsh" "$(printf '#!/bin/sh\necho formatted')"; echo $?)"
reset; run_hook "$(payload_for "$R/notes")"; run_hook "$(payload_for "$R/py")"
check "extensionless non-shell files are skipped" "$(log_empty; echo $?)"

R="$ROOT/r5"; mkrepo "$R"
commit_file "$R" g.go 'package formatted'
echo 'package UNFORMATTED' >"$R/g.go"
reset; run_hook "$(payload_for "$R/g.go")"
check ".go runs goimports then gofumpt" \
  "$(content_is "$R/g.go" 'package formatted' && [ "$(/usr/bin/grep -c -e '-w' "$FMT_LOG")" = 2 ] \
     && [ "$(/usr/bin/grep -e '-w' "$FMT_LOG" | head -1 | cut -d' ' -f1)" = goimports ] \
     && [ "$(/usr/bin/grep -e '-w' "$FMT_LOG" | tail -1 | cut -d' ' -f1)" = gofumpt ]; echo $?)"
check ".go clean-check passes goimports -srcdir" \
  "$(log_has "goimports .*-srcdir $R" && echo 0 || echo 1)"

# --- binary lookup ------------------------------------------------------
R="$ROOT/r6"; mkrepo "$R"
commit_file "$R" a.lua 'x'
echo 'local x = UNFORMATTED' >"$R/a.lua"
mv "$SHIMS/stylua" "$MASON/stylua"
reset; run_hook "$(payload_for "$R/a.lua")"
check "formatter found in the mason bin folder is used" \
  "$(content_is "$R/a.lua" 'local x = formatted'; echo $?)"
rm "$MASON/stylua"
echo 'local x = UNFORMATTED' >"$R/a.lua"
reset; run_hook "$(payload_for "$R/a.lua")"
check "formatter missing everywhere: silent skip" \
  "$(content_is "$R/a.lua" 'local x = UNFORMATTED' && [ "$rc" = 0 ] && [ -z "$out" ]; echo $?)"
cp "$ROOT/shim-body" "$SHIMS/stylua"

# --- work-plugin skip ---------------------------------------------------
plugin on
R="$ROOT/gomod"; mkrepo "$R"; : >"$R/go.mod"
commit_file "$R" g.go 'package formatted'; commit_file "$R" a.lua 'x'
echo 'package UNFORMATTED' >"$R/g.go"; echo 'local x = UNFORMATTED' >"$R/a.lua"
reset; run_hook "$(payload_for "$R/g.go")"
check "plugin on, go.mod repo: .go skipped" "$(log_empty && content_is "$R/g.go" 'package UNFORMATTED'; echo $?)"
reset; run_hook "$(payload_for "$R/a.lua")"
check "plugin on, go.mod repo: .lua still formatted" "$(content_is "$R/a.lua" 'local x = formatted'; echo $?)"

R="$ROOT/prettier"; mkrepo "$R"
echo '{"dependencies":{"prettier":"3"}}' >"$R/package.json"; echo '{}' >"$R/.prettierrc"
git -C "$R" add -A; git -C "$R" commit -q -m c
echo '{"a": "UNFORMATTED"}' >"$R/d.json"; echo 'const a = UNFORMATTED' >"$R/t.ts"
reset; run_hook "$(payload_for "$R/d.json")"; run_hook "$(payload_for "$R/t.ts")"
check "plugin on, prettier repo: .json and .ts skipped" "$(log_empty; echo $?)"

R="$ROOT/noprettierrc"; mkrepo "$R"
echo '{"dependencies":{"prettier":"3"}}' >"$R/package.json"
git -C "$R" add -A; git -C "$R" commit -q -m c
echo 'const a = UNFORMATTED' >"$R/t.ts"
reset; run_hook "$(payload_for "$R/t.ts")"
check "plugin on, package.json without prettier config: .ts formatted" "$(content_is "$R/t.ts" 'const a = formatted'; echo $?)"

R="$ROOT/ruff"; mkrepo "$R"
printf '[tool.ruff]\nline-length = 88\n' >"$R/pyproject.toml"; : >"$R/uv.lock"
echo '{"dependencies":{"prettier":"3"}}' >"$R/package.json"; echo '{}' >"$R/.prettierrc"
git -C "$R" add -A; git -C "$R" commit -q -m c
echo 'const a = UNFORMATTED' >"$R/t.ts"
reset; run_hook "$(payload_for "$R/t.ts")"
check "plugin on, ruff repo also holding prettier config: ruff wins, .ts formatted" "$(content_is "$R/t.ts" 'const a = formatted'; echo $?)"

plugin off
echo 'package UNFORMATTED' >"$ROOT/gomod/g.go"
reset; run_hook "$(payload_for "$ROOT/gomod/g.go")"
check "plugin off, go.mod repo: .go formatted" "$(content_is "$ROOT/gomod/g.go" 'package formatted'; echo $?)"

# --- never-format paths -------------------------------------------------
R="$ROOT/r7"; mkrepo "$R"
commit_file "$R" x.txt hi
echo 'UNFORMATTED' >"$R/n.md"
reset; run_hook "$(payload_for "$R/n.md")"
check ".md is never formatted" "$(log_empty && content_is "$R/n.md" UNFORMATTED; echo $?)"

mkrepo "$FIXTURE_HOME/code/tasks"
echo 'local x = UNFORMATTED' >"$FIXTURE_HOME/code/tasks/t.lua"
reset; run_hook "$(payload_for "$FIXTURE_HOME/code/tasks/t.lua")"
check "file under ~/code/tasks is never formatted" "$(log_empty; echo $?)"

# --- fail-open ----------------------------------------------------------
mkdir -p "$ROOT/norepo"; echo 'local x = UNFORMATTED' >"$ROOT/norepo/a.lua"
reset; run_hook "$(payload_for "$ROOT/norepo/a.lua")"
check "file outside a git repo: no-op" "$(log_empty && [ "$rc" = 0 ] && [ -z "$out" ]; echo $?)"

reset; run_hook ''
check "empty payload: exit 0, no output" "$([ "$rc" = 0 ] && [ -z "$out" ] && log_empty; echo $?)"
run_hook 'not json {'
check "malformed payload: exit 0, no output" "$(quiet_ok; echo $?)"
run_hook "$(jq 'del(.tool_input.file_path)' "$PAYLOAD_FIXTURE")"
check "payload without file_path: exit 0, no output" "$([ "$rc" = 0 ] && [ -z "$out" ] && log_empty; echo $?)"
run_hook "$(payload_for "$R/deleted.lua")"
check "deleted/missing file: exit 0, no output" "$([ "$rc" = 0 ] && [ -z "$out" ] && log_empty; echo $?)"

R="$ROOT/r8"; mkrepo "$R"
commit_file "$R" a.lua 'x'
echo 'local x = UNFORMATTED' >"$R/a.lua"
reset
out="$(payload_for "$R/a.lua" | env HOME="$FIXTURE_HOME" PATH="$SHIMS:/usr/bin:/bin" FMT_FAIL=stylua "$HOOK" 2>/dev/null)"; rc=$?
check "failing formatter: exit 0, empty stdout" "$(quiet_ok; echo $?)"

# a failing clean-check must not format either
echo 'local x = UNFORMATTED' >"$R/a.lua"
reset
out="$(payload_for "$R/a.lua" | env HOME="$FIXTURE_HOME" PATH="$SHIMS:/usr/bin:/bin" FMT_FAIL=stylua "$HOOK" 2>/dev/null)"
check "failing clean-check leaves the file alone" "$(content_is "$R/a.lua" 'local x = UNFORMATTED'; echo $?)"

echo 'const a = UNFORMATTED' >"$R/new.ts"
out="$(payload_for "$R/new.ts" | env HOME="$FIXTURE_HOME" PATH="$SHIMS:/usr/bin:/bin" FMT_FAIL=prettier "$HOOK" 2>/dev/null)"; rc=$?
check "failing in-place formatter on a new file: exit 0, empty stdout" "$(quiet_ok; echo $?)"

if [ "$fail" = 0 ]; then echo "ALL PASS"; else echo "SOME FAILED"; exit 1; fi
