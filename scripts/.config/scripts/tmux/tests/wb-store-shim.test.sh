#!/usr/bin/env bash
# Tests for wb-store.sh, the shim that rebuilds the wb-store binary when its
# Go source is newer and then runs it against the task store.
#
# Runs the shim as a subprocess against a stub source dir under a throwaway
# HOME. A stub `go` on PATH logs each build and writes a small script as the
# "binary"; that script prints which source it was built from and the
# arguments it got, so one line of output shows both "was it rebuilt" and
# "what did it receive". File and directory ages are set with `touch -t`
# (sources 2020, binaries 2021, "newer" edits 2022) so no assertion depends on
# timing. A step that adds or deletes a file in the source dates the
# directory back to 2020 afterwards.
#
# Run: bash scripts/.config/scripts/tmux/tests/wb-store-shim.test.sh
set -uo pipefail

SHIM="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/wb-store.sh"

FIXTURE="$(mktemp -d -t wb-store-shim.XXXXXX)"
trap 'rm -rf "$FIXTURE"' EXIT

fail=0
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
assert_match() { # <desc> <expected-regex> <actual>
  if grep -qE -- "$2" <<<"$3"; then
    echo "ok   - $1"
  else
    echo "FAIL - $1"
    echo "       expected match: $2"
    echo "       got: $(printf '%s' "$3" | head -5)"
    fail=1
  fi
}

export HOME="$FIXTURE/home"
export XDG_CACHE_HOME="$FIXTURE/cache"
export TASKS_DIR="$FIXTURE/tasks"
unset WB_STORE_SRC
mkdir -p "$HOME" "$TASKS_DIR"

OLD=202001010000   # source files
BUILT=202101010000 # a binary built after them
NEWER=202201010000 # an edit made after the build

# make_src <dir>: a stub wb-store checkout with every kind of file the shim
# looks at or must ignore, all dated before any binary.
make_src() {
  local d="$1"
  mkdir -p "$d/cmd/wb-store" "$d/internal/web/templates" "$d/internal/store/testdata" \
           "$d/.worktrees/other/cmd/wb-store" "$d/.git"
  printf 'package main\n' > "$d/cmd/wb-store/main.go"
  printf 'package main\n' > "$d/cmd/wb-store/extra.go"
  printf 'module example\n' > "$d/go.mod"
  printf '' > "$d/go.sum"
  printf '<html></html>\n' > "$d/internal/web/templates/task.html"
  printf '<html></html>\n' > "$d/internal/store/testdata/page.html"
  printf '# wb-store\n' > "$d/README.md"
  printf 'package main\n' > "$d/.worktrees/other/cmd/wb-store/main.go"
  printf 'package main\n' > "$d/.git/stray.go"
  find "$d" -exec touch -t "$OLD" {} +
}

DEFAULT_SRC="$HOME/code/wb-store"
OTHER_SRC="$FIXTURE/elsewhere/wb-store"
make_src "$DEFAULT_SRC"
make_src "$OTHER_SRC"
DEFAULT_BIN="$HOME/.local/bin/wb-store"
OTHER_BIN="$XDG_CACHE_HOME/wb-store/bin/${OTHER_SRC//\//_}/wb-store"

# Stub go: logs "<cwd> <args>" per call; `build -o <out> ...` writes a
# script to <out> (removing it first and setting the mode, as real go does)
# unless $GO_FAIL is set.
STUB_BIN="$FIXTURE/bin"; mkdir -p "$STUB_BIN"
GO_LOG="$FIXTURE/go.log"; : > "$GO_LOG"
cat > "$STUB_BIN/go" <<'STUB'
#!/usr/bin/env bash
echo "$PWD $*" >> "$GO_LOG"
if [ -n "${GO_FAIL:-}" ]; then echo "stub go: build failed" >&2; exit 1; fi
out=""
while [ $# -gt 0 ]; do
  if [ "$1" = "-o" ]; then out="$2"; shift; fi
  shift
done
rm -f "$out"
printf '#!/usr/bin/env bash\necho "built-from=%s $*"\n' "$PWD" > "$out"
chmod 755 "$out"
STUB
chmod +x "$STUB_BIN/go"
export GO_LOG
BASE_PATH="$PATH"
export PATH="$STUB_BIN:$PATH"

builds() { wc -l < "$GO_LOG" | tr -d ' '; }
run() { bash "$SHIM" "$@" 2>"$FIXTURE/stderr"; }

# =============================================================================
echo "# no binary yet: builds from the default source, then runs it"
out=$(run show dotfiles--foo); rc=$?
assert_eq "exit 0" 0 "$rc"
assert_eq "one build" 1 "$(builds)"
assert_match "go ran in the source dir with -o to a temp file beside the binary" \
  "^$DEFAULT_SRC build -o $HOME/\.local/bin/\.wb-store\.[A-Za-z0-9]+ \./cmd/wb-store$" "$(tail -1 "$GO_LOG")"
assert_eq "binary got --store and the caller's args" \
  "built-from=$DEFAULT_SRC --store $TASKS_DIR show dotfiles--foo" "$out"
assert_eq "binary installed at ~/.local/bin/wb-store" yes "$([ -x "$DEFAULT_BIN" ] && echo yes || echo no)"
assert_eq "no temp file left" "" "$(find "$HOME/.local/bin" -name '.wb-store.*')"
assert_match "says it is building, on stderr" "building" "$(cat "$FIXTURE/stderr")"

# =============================================================================
echo "# binary newer than every source: no rebuild"
touch -t "$BUILT" "$DEFAULT_BIN"
out=$(run list); rc=$?
assert_eq "exit 0" 0 "$rc"
assert_eq "still one build" 1 "$(builds)"
assert_eq "ran the existing binary" "built-from=$DEFAULT_SRC --store $TASKS_DIR list" "$out"
assert_eq "nothing on stderr" "" "$(cat "$FIXTURE/stderr")"

# =============================================================================
echo "# a .go file newer than the binary: rebuild"
touch -t "$NEWER" "$DEFAULT_SRC/cmd/wb-store/main.go"
run list >/dev/null
assert_eq "rebuilt" 2 "$(builds)"
touch -t "$OLD" "$DEFAULT_SRC/cmd/wb-store/main.go"; touch -t "$BUILT" "$DEFAULT_BIN"

echo "# go.mod newer: rebuild"
touch -t "$NEWER" "$DEFAULT_SRC/go.mod"
run list >/dev/null
assert_eq "rebuilt" 3 "$(builds)"
touch -t "$OLD" "$DEFAULT_SRC/go.mod"; touch -t "$BUILT" "$DEFAULT_BIN"

echo "# go.sum newer: rebuild"
touch -t "$NEWER" "$DEFAULT_SRC/go.sum"
run list >/dev/null
assert_eq "rebuilt" 4 "$(builds)"
touch -t "$OLD" "$DEFAULT_SRC/go.sum"; touch -t "$BUILT" "$DEFAULT_BIN"

echo "# a template newer: rebuild"
touch -t "$NEWER" "$DEFAULT_SRC/internal/web/templates/task.html"
run list >/dev/null
assert_eq "rebuilt" 5 "$(builds)"
touch -t "$OLD" "$DEFAULT_SRC/internal/web/templates/task.html"; touch -t "$BUILT" "$DEFAULT_BIN"

# =============================================================================
echo "# newer files under .worktrees/ and .git/, a test fixture and a README: no rebuild"
touch -t "$NEWER" "$DEFAULT_SRC/.worktrees/other/cmd/wb-store/main.go" "$DEFAULT_SRC/.git/stray.go" \
  "$DEFAULT_SRC/internal/store/testdata/page.html" "$DEFAULT_SRC/README.md"
mkdir "$DEFAULT_SRC/.worktrees/new-branch"   # a new worktree
printf 'x\n' > "$DEFAULT_SRC/.git/new-object" # git writing its own files
run list >/dev/null
assert_eq "no rebuild" 5 "$(builds)"

# =============================================================================
echo "# a .go file deleted, nothing else changed: rebuild"
rm "$DEFAULT_SRC/cmd/wb-store/extra.go"
run list >/dev/null
assert_eq "rebuilt" 6 "$(builds)"
touch -t "$OLD" "$DEFAULT_SRC/cmd/wb-store"; touch -t "$BUILT" "$DEFAULT_BIN"

echo "# a template deleted, nothing else changed: rebuild"
rm "$DEFAULT_SRC/internal/web/templates/task.html"
run list >/dev/null
assert_eq "rebuilt" 7 "$(builds)"
touch -t "$OLD" "$DEFAULT_SRC/internal/web/templates"; touch -t "$BUILT" "$DEFAULT_BIN"

echo "# after the deletions, sources and directories older again: no rebuild"
run list >/dev/null
assert_eq "no rebuild" 7 "$(builds)"

# =============================================================================
echo "# a failed build: old binary kept, no temp file, non-zero exit"
cp "$DEFAULT_BIN" "$FIXTURE/bin-before"
touch -t "$NEWER" "$DEFAULT_SRC/go.mod"
out=$(GO_FAIL=1 run list); rc=$?
assert_eq "exit non-zero" yes "$([ "$rc" -ne 0 ] && echo yes || echo no)"
assert_eq "binary not run" "" "$out"
assert_match "go's error reaches stderr" "stub go: build failed" "$(cat "$FIXTURE/stderr")"
assert_eq "old binary untouched" same "$(cmp -s "$DEFAULT_BIN" "$FIXTURE/bin-before" && echo same || echo changed)"
assert_eq "no temp file left" "" "$(find "$HOME/.local/bin" -name '.wb-store.*')"
run list >/dev/null   # rebuild for real, so the default binary is current again
touch -t "$OLD" "$DEFAULT_SRC/go.mod"; touch -t "$BUILT" "$DEFAULT_BIN"
n=$(builds)

# =============================================================================
echo "# another source: its own binary under the cache dir; ~/.local/bin untouched"
cp "$DEFAULT_BIN" "$FIXTURE/bin-before"
out=$(WB_STORE_SRC="$OTHER_SRC" run show x); rc=$?
assert_eq "exit 0" 0 "$rc"
assert_eq "built once" $((n + 1)) "$(builds)"
assert_eq "ran the other source's binary" "built-from=$OTHER_SRC --store $TASKS_DIR show x" "$out"
assert_eq "binary in the cache dir" yes "$([ -x "$OTHER_BIN" ] && echo yes || echo no)"
assert_eq "default binary untouched" same "$(cmp -s "$DEFAULT_BIN" "$FIXTURE/bin-before" && echo same || echo changed)"
assert_eq "default binary's age untouched" "" "$(find "$DEFAULT_BIN" -newermt '2021-01-02' 2>/dev/null)"

echo "# back to the default source: runs the default binary, no rebuild"
out=$(run show x)
assert_eq "no rebuild" $((n + 1)) "$(builds)"
assert_eq "default source's binary ran" "built-from=$DEFAULT_SRC --store $TASKS_DIR show x" "$out"

echo "# WB_STORE_SRC spelled differently but naming the default checkout: default binary"
out=$(WB_STORE_SRC="$HOME/code/../code/wb-store/" run show x)
assert_eq "no rebuild" $((n + 1)) "$(builds)"
assert_eq "default source's binary ran" "built-from=$DEFAULT_SRC --store $TASKS_DIR show x" "$out"

echo "# WB_STORE_SRC a symlink to the default checkout: default binary"
ln -s "$DEFAULT_SRC" "$FIXTURE/link-to-default"
out=$(WB_STORE_SRC="$FIXTURE/link-to-default" run show x)
assert_eq "no rebuild" $((n + 1)) "$(builds)"
assert_eq "default source's binary ran" "built-from=$DEFAULT_SRC --store $TASKS_DIR show x" "$out"

# =============================================================================
echo "# TASKS_DIR unset: --store defaults to ~/code/tasks"
out=$(env -u TASKS_DIR bash "$SHIM" list 2>/dev/null)
assert_eq "default store" "built-from=$DEFAULT_SRC --store $HOME/code/tasks list" "$out"

# =============================================================================
echo "# --bin-path: rebuilds when stale, prints the binary's path, runs nothing"
touch -t "$NEWER" "$DEFAULT_SRC/cmd/wb-store/main.go"
n=$(builds)
out=$(run --bin-path); rc=$?
assert_eq "exit 0" 0 "$rc"
assert_eq "rebuilt first" $((n + 1)) "$(builds)"
assert_eq "printed the default binary's path" "$DEFAULT_BIN" "$out"
touch -t "$OLD" "$DEFAULT_SRC/cmd/wb-store/main.go"; touch -t "$BUILT" "$DEFAULT_BIN"
out=$(WB_STORE_SRC="$OTHER_SRC" run --bin-path)
assert_eq "another source prints its own binary's path" "$OTHER_BIN" "$out"
out=$(run --bin-path extra)
assert_eq "--bin-path with more args passes through to the binary" "built-from=$DEFAULT_SRC --store $TASKS_DIR --bin-path extra" "$out"

# =============================================================================
echo "# no source dir: clear error"
out=$(WB_STORE_SRC="$FIXTURE/missing" run list); rc=$?
assert_eq "exit 1" 1 "$rc"
assert_match "names the path and WB_STORE_SRC" "no source at $FIXTURE/missing.*WB_STORE_SRC" "$(cat "$FIXTURE/stderr")"

# =============================================================================
echo "# rebuild needed but no go on PATH: clear error"
touch -t "$NEWER" "$DEFAULT_SRC/go.mod"
# PATH without the stub, and without a host Go install (the sandbox has none)
NOGO_PATH="$(printf '%s' "$BASE_PATH" | tr ':' '\n' | grep -v '/go/bin' | paste -sd:)"
out=$(PATH="$NOGO_PATH" bash "$SHIM" list 2>"$FIXTURE/stderr"); rc=$?
if PATH="$NOGO_PATH" command -v go >/dev/null; then
  echo "skip - a real go is on PATH outside /go/bin; can't hide it"
else
  assert_eq "exit 1" 1 "$rc"
  assert_match "says go is needed" "go not found" "$(cat "$FIXTURE/stderr")"
fi
touch -t "$OLD" "$DEFAULT_SRC/go.mod"

exit "$fail"
