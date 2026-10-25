#!/usr/bin/env bash
# Tests for gnome/check-keys.sh (U5, R5) and its pre-commit wiring. Every
# scenario runs against a throwaway settings database (--repo isolates itself)
# using fixture settings scripts, never the live session.
# Forge-dependent cases need Forge's compiled schemas: set FORGE_SCHEMA_DIR
# (they are skipped with a message when it is absent).
# Run: FORGE_SCHEMA_DIR=<dir> bash gnome/tests/check-keys.test.sh
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
SCRIPT="$REPO/gnome/check-keys.sh"
FX="$HERE/fixtures"

TMP="$(mktemp -d -t check-keys-test.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT

fail=0
assert() { # <desc> <expected-regex> <actual>
  if printf '%s' "$3" | grep -qE "$2"; then echo "ok   - $1"
  else echo "FAIL - $1"; echo "       expected match: $2"; echo "       got: $(printf '%s' "$3" | head -8)"; fail=1; fi
}
assert_eq() { # <desc> <expected> <actual>
  if [ "$2" = "$3" ]; then echo "ok   - $1"
  else echo "FAIL - $1 (expected '$2', got '$3')"; fail=1; fi
}
refute() { # <desc> <unexpected-regex> <actual>
  if printf '%s' "$3" | grep -qE "$2"; then echo "FAIL - $1"; echo "       unexpected match: $2"; fail=1
  else echo "ok   - $1"; fi
}

# run_repo <settings-fixture> <conf-fixture>: sets $out and $rc
run_repo() {
  out="$(SETTINGS_SH="$FX/$1" SHORTCUTS_CONF="$FX/$2" bash "$SCRIPT" --repo 2>&1)"; rc=$?
}

# =============================================================================
# Scenarios needing Forge's schema
# =============================================================================
if [ -n "${FORGE_SCHEMA_DIR:-}" ] && [ -f "$FORGE_SCHEMA_DIR/gschemas.compiled" ]; then
  export FORGE_SCHEMA_DIR

  run_repo settings-clean.sh clean.conf
  assert_eq "clean config passes" 0 "$rc"
  assert "clean config reports ok" 'check-keys: ok' "$out"

  run_repo settings-super-s.sh super-s.conf
  assert_eq "<Super>s reused by shortcuts.conf: exit 1" 1 "$rc"
  assert "conflict names the GNOME workspace-2 owner" 'org.gnome.desktop.wm.keybindings switch-to-workspace-2' "$out"
  assert "conflict names the run-or-raise owner with its line" 'run-or-raise:1' "$out"

  run_repo settings-clean.sh dup-norm.conf
  assert_eq "<Primary><Super>l vs <Super><Control>L: exit 1" 1 "$rc"
  assert "aliases detected as one key, both owners named" 'run-or-raise:1' "$out"
  assert "second spelling named too" 'run-or-raise:2' "$out"

  run_repo settings-ctrl-j.sh clean.conf
  assert_eq "bare <Control>j: exit 1" 1 "$rc"
  assert "reserved-key message" 'RESERVED.*Ctrl\+j' "$out"

  # Forge schema missing in --repo is an explicit failure, not a skip.
  out="$(FORGE_SCHEMA_DIR="$TMP/nope" SETTINGS_SH="$FX/settings-clean.sh" SHORTCUTS_CONF="$FX/clean.conf" bash "$SCRIPT" --repo 2>&1)"; rc=$?
  assert "missing Forge schema fails" 'Forge.s schema.*not found' "$out"
  assert_eq "missing Forge schema: exit non-zero" 1 "$([ "$rc" -ne 0 ] && echo 1 || echo 0)"
else
  echo "skip - Forge schema not found (set FORGE_SCHEMA_DIR): 6 --repo scenarios skipped"
fi

# =============================================================================
# Scenario: usage error
# =============================================================================
out="$(bash "$SCRIPT" 2>&1)"; rc=$?
assert_eq "no mode: exit 2" 2 "$rc"

# =============================================================================
# Scenario: the pre-commit hook does nothing when neither gnome/ nor
# run-or-raise/ is staged, and runs the check when one is. A stub check script
# records invocations in a throwaway git repo.
# =============================================================================
H="$TMP/hook-repo"
mkdir -p "$H/.githooks" "$H/gnome" "$H/other"
cp "$REPO/.githooks/pre-commit" "$H/.githooks/pre-commit"
printf '#!/usr/bin/env bash\necho "$@" >> "$(dirname "$0")/calls"\nexit "${STUB_RC:-0}"\n' > "$H/gnome/check-keys.sh"
chmod +x "$H/gnome/check-keys.sh"
(
  cd "$H" && git init -q . && echo x > other/file.txt && git add other/file.txt
  HOME="$TMP/home" bash .githooks/pre-commit >"$TMP/hook1.out" 2>&1
  echo $? > "$TMP/hook1.rc"
  [ -e gnome/calls ] && echo ran > "$TMP/hook1.ran" || echo none > "$TMP/hook1.ran"
  echo y > gnome/settings.sh && git add gnome/settings.sh
  HOME="$TMP/home" bash .githooks/pre-commit >"$TMP/hook2.out" 2>&1
  echo $? > "$TMP/hook2.rc"
  HOME="$TMP/home" STUB_RC=1 bash .githooks/pre-commit >"$TMP/hook3.out" 2>&1
  echo $? > "$TMP/hook3.rc"
)
assert_eq "hook: unrelated staged file exits 0" 0 "$(cat "$TMP/hook1.rc")"
assert_eq "hook: nothing staged under gnome/ or run-or-raise/ -> check not run" none "$(cat "$TMP/hook1.ran")"
assert_eq "hook: staged gnome/ file runs check --repo" 0 "$(cat "$TMP/hook2.rc")"
assert "hook: check invoked with --repo" '^--repo$' "$(cat "$H/gnome/calls")"
assert_eq "hook: failing check blocks the commit" 1 "$(cat "$TMP/hook3.rc")"

[ "$fail" -eq 0 ] && echo "ALL PASS" || echo "FAILURES"
exit "$fail"
