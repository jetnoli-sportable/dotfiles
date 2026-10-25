#!/usr/bin/env bash
# Tests for gnome/check-keys.sh (U5, R5), gnome/settings.sh's optional schemas
# and the pre-commit wiring. Every scenario runs against a throwaway settings
# database (own dbus session + temp XDG dirs), never the live session.
# Forge-dependent cases need Forge's compiled schemas: set FORGE_SCHEMA_DIR
# (they are skipped, and counted in the last line, when it is absent).
# Run: FORGE_SCHEMA_DIR=<dir> bash gnome/tests/check-keys.test.sh
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
SCRIPT="$REPO/gnome/check-keys.sh"
FX="$HERE/fixtures"

TMP="$(mktemp -d -t check-keys-test.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT

fail=0
skipped=0
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
skip() { # <count> <reason>
  echo "skip - $2 ($1 assertions)"; skipped=$((skipped + $1))
}
fx() { case "$1" in /*) echo "$1" ;; *) echo "$FX/$1" ;; esac; }

# run_repo <settings-fixture> <conf-fixture>: sets $out and $rc. Fixtures are
# names under fixtures/ or absolute paths (generated ones live in $TMP).
run_repo() {
  out="$(SETTINGS_SH="$(fx "$1")" SHORTCUTS_CONF="$(fx "$2")" bash "$SCRIPT" --repo 2>&1)"; rc=$?
}

# run_live <settings-fixture> <conf-fixture>: applies the fixture to a fresh
# isolated session, then runs --live inside it. Sets $out and $rc.
run_live() {
  local t; t="$(mktemp -d "$TMP/live.XXXXXX")"
  mkdir -p "$t/cfg" "$t/run" && chmod 700 "$t/run"
  out="$(env -u DBUS_SESSION_BUS_ADDRESS XDG_CONFIG_HOME="$t/cfg" XDG_RUNTIME_DIR="$t/run" \
    SHORTCUTS_CONF="$(fx "$2")" dbus-run-session -- \
    bash -c 'bash "$1" >/dev/null && bash "$2" --live' _ "$(fx "$1")" "$SCRIPT" 2>&1)"; rc=$?
}

# gen <name> <body>: a settings fixture in $TMP that applies the clean fixture,
# then <body>. Prints its path.
gen() {
  printf '#!/usr/bin/env bash\nbash %q\n%s\n' "$FX/settings-clean.sh" "$2" > "$TMP/$1"
  echo "$TMP/$1"
}
has_schema() { gsettings list-schemas | grep -x "$1" >/dev/null; }

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

  # ---------------------------------------------------------------------------
  # Every key source is collected: put <Super>u (free in the clean fixture) on
  # one source at a time, against a shortcuts.conf that also uses it.
  # ---------------------------------------------------------------------------
  printf '<Super>u,term.desktop,term,\n' > "$TMP/super-u.conf"
  run_repo settings-clean.sh "$TMP/super-u.conf"
  assert_eq "<Super>u is free in the clean fixture" 0 "$rc"

  custom=/org/gnome/settings-daemon/plugins/media-keys/custom-keybindings/custom0/
  sources=(
    "forge|gsettings --schemadir \"\$FORGE_SCHEMA_DIR\" set org.gnome.shell.extensions.forge.keybindings focus-border-toggle \"['<Super>u']\"|org.gnome.shell.extensions.forge.keybindings focus-border-toggle"
    "custom|gsettings set org.gnome.settings-daemon.plugins.media-keys custom-keybindings \"['$custom']\"; gsettings set org.gnome.settings-daemon.plugins.media-keys.custom-keybinding:$custom binding \"'<Super>u'\"|custom-keybinding:$custom binding"
  )
  if has_schema org.gnome.shell.extensions.dash-to-dock; then
    sources+=("dock|gsettings set org.gnome.shell.extensions.dash-to-dock app-hotkey-1 \"['<Super>u']\"|dash-to-dock app-hotkey-1")
  else skip 2 "Ubuntu Dock schema not installed: dock source case"; fi
  if has_schema org.gnome.GPaste; then
    sources+=("gpaste|gsettings set org.gnome.GPaste launch-ui \"'<Super>u'\"|org.gnome.GPaste launch-ui")
  else skip 2 "GPaste schema not installed: GPaste source case"; fi
  for src in "${sources[@]}"; do
    IFS='|' read -r name body owner <<<"$src"
    run_repo "$(gen "settings-$name-u.sh" "$body")" "$TMP/super-u.conf"
    assert_eq "$name key clashing with shortcuts.conf: exit 1" 1 "$rc"
    assert "$name owner named in the conflict" "$owner" "$out"
  done

  # shortcuts.conf syntax: a :mode suffix and a chord still clash on their
  # first key.
  printf '<Super>s:raise,term.desktop,term,\n' > "$TMP/raise.conf"
  printf '<Super>s h,term.desktop,term,\n' > "$TMP/chord.conf"
  for conf in raise chord; do
    run_repo settings-super-s.sh "$TMP/$conf.conf"
    assert_eq "$conf line's first key clashes with workspace 2: exit 1" 1 "$rc"
    assert "$conf line named as run-or-raise:1" 'run-or-raise:1' "$out"
  done

  # ---------------------------------------------------------------------------
  # --live checks whatever session it runs in.
  # ---------------------------------------------------------------------------
  run_live settings-clean.sh clean.conf
  assert_eq "--live, clean session: exit 0" 0 "$rc"
  assert "--live, clean session reports ok" 'check-keys: ok' "$out"
  run_live settings-super-s.sh super-s.conf
  assert_eq "--live, clashing session: exit 1" 1 "$rc"
  assert "--live names both owners" 'switch-to-workspace-2' "$out"

  # ---------------------------------------------------------------------------
  # The real gnome/settings.sh + shortcuts.conf pass, also on a machine without
  # GPaste (settings.sh must skip it and still move Forge's keys).
  # ---------------------------------------------------------------------------
  out="$(bash "$SCRIPT" --repo 2>&1)"; rc=$?
  assert_eq "real settings.sh + shortcuts.conf: exit 0" 0 "$rc"
  assert "real config reports ok" 'check-keys: ok' "$out"

  if command -v glib-compile-schemas >/dev/null && [ -d /usr/share/glib-2.0/schemas ]; then
    share="$TMP/share-no-gpaste"
    mkdir -p "$share/glib-2.0/schemas"
    find /usr/share/glib-2.0/schemas -maxdepth 1 \( -name '*.xml' -o -name '*.override' \) \
      ! -name 'org.gnome.GPaste*' -exec cp {} "$share/glib-2.0/schemas/" \;
    glib-compile-schemas "$share/glib-2.0/schemas"
    ln -s /usr/share/dbus-1 "$share/dbus-1"  # dconf's service file, for dbus activation
    out="$(XDG_DATA_DIRS="$share" XDG_DATA_HOME="$TMP/data-home" bash "$SCRIPT" --repo 2>&1)"; rc=$?
    assert_eq "real config without GPaste: exit 0" 0 "$rc"
    assert "settings.sh skipped GPaste" 'settings.sh: GPaste not installed, skipping' "$out"
    assert "Forge keys still moved (no conflict reported)" 'check-keys: ok' "$out"
  else
    skip 3 "glib-compile-schemas not found: no-GPaste case"
  fi
else
  skip 34 "Forge schema not found (set FORGE_SCHEMA_DIR): every --repo and --live case"
fi

# =============================================================================
# Scenario: usage error
# =============================================================================
out="$(bash "$SCRIPT" 2>&1)"; rc=$?
assert_eq "no mode: exit 2" 2 "$rc"

# =============================================================================
# Scenario: the pre-commit hook. A stub check script records its calls and
# fails when the shortcuts.conf beside it (in whatever tree it runs from)
# contains CLASH; it is committed so the hook's index export includes it.
# =============================================================================
H="$TMP/hook-repo"
CALLS="$TMP/calls"
mkdir -p "$H/.githooks" "$H/gnome" "$H/other" "$H/run-or-raise/.config/run-or-raise"
cp "$REPO/.githooks/pre-commit" "$H/.githooks/pre-commit"
cat > "$H/gnome/check-keys.sh" <<'STUB'
#!/usr/bin/env bash
echo "$@" >> "$CALLS"
conf="$(dirname "$0")/../run-or-raise/.config/run-or-raise/shortcuts.conf"
if [ -f "$conf" ] && grep -q CLASH "$conf"; then echo "CONFLICT (stub)"; exit 1; fi
exit "${STUB_RC:-0}"
STUB
chmod +x "$H/gnome/check-keys.sh"
hook() { # <n> [env...]: runs the hook, records rc in $TMP/hook<n>.rc
  local n="$1"; shift
  env HOME="$TMP/home" CALLS="$CALLS" "$@" bash .githooks/pre-commit >"$TMP/hook$n.out" 2>&1
  echo $? > "$TMP/hook$n.rc"
}
(
  cd "$H" && git init -q .
  commit() { git -c core.hooksPath=/dev/null -c user.name=t -c user.email=t@example.com commit -qm "$1"; }
  git add gnome/check-keys.sh && commit stub
  echo x > other/file.txt && git add other/file.txt
  hook 1
  [ -e "$CALLS" ] && echo ran > "$TMP/hook1.ran" || echo none > "$TMP/hook1.ran"
  echo y > gnome/settings.sh && git add gnome/settings.sh
  hook 2
  cp "$CALLS" "$TMP/calls2"
  hook 3 STUB_RC=1
  commit settings && rm -f "$CALLS"
  conf=run-or-raise/.config/run-or-raise/shortcuts.conf
  echo clean > "$conf" && git add "$conf"
  hook 4
  [ -e "$CALLS" ] && echo ran > "$TMP/hook4.ran" || echo none > "$TMP/hook4.ran"
  echo CLASH > "$conf" && git add "$conf" && echo clean > "$conf"
  hook 5
)
assert_eq "hook: unrelated staged file exits 0" 0 "$(cat "$TMP/hook1.rc")"
assert_eq "hook: nothing staged under gnome/ or run-or-raise/ -> check not run" none "$(cat "$TMP/hook1.ran")"
assert_eq "hook: staged gnome/ file runs check --repo" 0 "$(cat "$TMP/hook2.rc")"
assert "hook: check invoked with --repo" '^--repo$' "$(cat "$TMP/calls2")"
assert_eq "hook: failing check blocks the commit" 1 "$(cat "$TMP/hook3.rc")"
assert_eq "hook: staged run-or-raise/ file alone runs the check" ran "$(cat "$TMP/hook4.ran")"
assert_eq "hook: staged clash blocks even when the working tree hides it" 1 "$(cat "$TMP/hook5.rc")"
assert "hook: the staged clash is what the check saw" 'CONFLICT \(stub\)' "$(cat "$TMP/hook5.out")"

if [ "$fail" -ne 0 ]; then echo "FAILURES"
elif [ "$skipped" -gt 0 ]; then echo "PASS ($skipped skipped)"
else echo "ALL PASS"; fi
exit "$fail"
