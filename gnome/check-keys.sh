#!/usr/bin/env bash
# Key-conflict check (R5): no accelerator may be owned by two actions, because
# a double-bound key can crash GNOME Shell and end the Wayland session. Also
# fails on bare Ctrl+h/j/k/l (reserved for vim-tmux-navigator, R4).
#
#   check-keys.sh --live   check the running session (read-only)
#   check-keys.sh --repo   apply gnome/settings.sh to a throwaway GNOME settings
#                          database (own dbus session + temp XDG dirs, never
#                          the live one), then check; used by pre-commit
#
# Env: FORGE_SCHEMA_DIR  Forge's compiled schemas (contract with settings.sh)
#      SHORTCUTS_CONF    run-or-raise shortcuts file (default: repo's in --repo,
#                        ~/.config/run-or-raise/shortcuts.conf in --live)
#      SETTINGS_SH       settings script for --repo (default: gnome/settings.sh)
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"
export FORGE_SCHEMA_DIR="${FORGE_SCHEMA_DIR:-$HOME/.local/share/gnome-shell/extensions/forge@jmmaranan.com/schemas}"

usage() { echo "usage: ${0##*/} --live | --repo" >&2; exit 2; }

# Reads every accelerator from the current gsettings database, normalises it
# and reports duplicates. Exit 1 on any conflict or Ctrl+hjkl.
check() {
  python3 -I - "$FORGE_SCHEMA_DIR" "$SHORTCUTS_CONF" <<'PY'
import re, subprocess, sys, collections
forge_dir, conf = sys.argv[1], sys.argv[2]

def gs(*args, schemadir=None):
    cmd = ["gsettings"] + (["--schemadir", schemadir] if schemadir else []) + list(args)
    return subprocess.run(cmd, capture_output=True, text=True, check=True).stdout

STR = re.compile(r"'((?:[^'\\]|\\.)*)'")
MODS = {"primary": "ctrl", "control": "ctrl", "ctrl": "ctrl", "super": "super",
        "mod4": "super", "alt": "alt", "mod1": "alt", "shift": "shift"}

def norm(acc):
    mods = {MODS.get(m.lower(), m.lower()) for m in re.findall(r"<([^>]+)>", acc)}
    return "+".join(sorted(mods) + [re.sub(r"<[^>]+>", "", acc).lower()])

def accel_like(s):  # a modifier-bearing accelerator or an XF86 media keysym
    return bool(s) and ("<" in s or s.startswith("XF86"))

owners = collections.defaultdict(set)   # normalised accel -> {owner}
shown = {}                              # normalised accel -> an original spelling
def add(acc, owner):
    n = norm(acc)
    owners[n].add(owner)
    shown.setdefault(n, acc)

installed = set(gs("list-schemas").split())
installed |= set(gs("list-relocatable-schemas").split())

def schema_rows(schema, schemadir=None):
    for line in gs("list-recursively", schema, schemadir=schemadir).splitlines():
        _, key, value = line.split(" ", 2)
        yield key, value

def want_all(key): return key != "custom-keybindings"
SCHEMAS = [  # (schema, key filter, string filter)
    ("org.gnome.desktop.wm.keybindings", want_all, lambda s: s != "disabled"),
    ("org.gnome.shell.keybindings", want_all, lambda s: s != "disabled"),
    ("org.gnome.mutter.keybindings", want_all, lambda s: s != "disabled"),
    ("org.gnome.mutter.wayland.keybindings", want_all, lambda s: s != "disabled"),
    ("org.gnome.settings-daemon.plugins.media-keys", want_all, lambda s: s != "disabled"),
    ("org.gnome.shell.extensions.dash-to-dock",
     lambda k: re.fullmatch(r"app-(shift-|ctrl-)?hotkey-\d+|shortcut", k) is not None, accel_like),
    ("org.gnome.GPaste", lambda k: True, accel_like),
]
for schema, keyok, strok in SCHEMAS:
    if schema not in installed:
        print(f"check-keys: schema {schema} not installed, skipping", file=sys.stderr)
        continue
    for key, value in schema_rows(schema):
        if keyok(key):
            for s in STR.findall(value):
                if s and strok(s):
                    add(s, f"{schema} {key}")

mk = "org.gnome.settings-daemon.plugins.media-keys"
if mk in installed:
    for path in STR.findall(gs("get", mk, "custom-keybindings")):
        for s in STR.findall(gs("get", f"{mk}.custom-keybinding:{path}", "binding")):
            if s:
                add(s, f"{mk}.custom-keybinding:{path} binding")

forge = "org.gnome.shell.extensions.forge.keybindings"
try:
    rows = list(schema_rows(forge, forge_dir))
except (subprocess.CalledProcessError, OSError):
    sys.exit(f"check-keys: Forge's schema ({forge}) not found in FORGE_SCHEMA_DIR={forge_dir}; "
             "install Forge or point FORGE_SCHEMA_DIR at its schemas directory")
for key, value in rows:
    for s in STR.findall(value):
        if s:
            add(s, f"{forge} {key}")

try:
    lines = open(conf).read().splitlines()
except OSError:
    print(f"check-keys: {conf} not readable, skipping run-or-raise", file=sys.stderr)
    lines = []
for i, line in enumerate(lines, 1):
    if not line.strip() or line.lstrip().startswith("#"):
        continue
    first = line.split(",", 1)[0].strip().split(" ")[0].split(":")[0]  # first chord, no :mode
    if first:
        add(first, f"run-or-raise:{i}")

bad = False
for n in sorted(owners):
    if len(owners[n]) > 1:
        bad = True
        print(f"CONFLICT {shown[n]} ({n}) is bound {len(owners[n])} times:")
        for o in sorted(owners[n]):
            print(f"    {o}")
    parts = n.split("+")
    if parts[:-1] == ["ctrl"] and parts[-1] in "hjkl" and len(parts[-1]) == 1:
        bad = True
        print(f"RESERVED {shown[n]} is Ctrl+{parts[-1]} without Super (vim-tmux-navigator): "
              + ", ".join(sorted(owners[n])))
if bad:
    sys.exit(1)
print(f"check-keys: ok ({len(owners)} accelerators, no conflicts)")
PY
}

case "${1:-}" in
  --live)
    SHORTCUTS_CONF="${SHORTCUTS_CONF:-$HOME/.config/run-or-raise/shortcuts.conf}"
    check
    ;;
  --repo)
    export SHORTCUTS_CONF="${SHORTCUTS_CONF:-$repo_root/run-or-raise/.config/run-or-raise/shortcuts.conf}"
    export SETTINGS_SH="${SETTINGS_SH:-$here/settings.sh}"
    if [ ! -f "$FORGE_SCHEMA_DIR/gschemas.compiled" ]; then
      echo "check-keys: Forge's schema not found in FORGE_SCHEMA_DIR=$FORGE_SCHEMA_DIR; install Forge or point FORGE_SCHEMA_DIR at its schemas directory" >&2
      exit 1
    fi
    # Fresh dbus session + throwaway XDG dirs: the settings database starts at
    # GNOME's defaults and nothing reaches the live session.
    tmp="$(mktemp -d "${TMPDIR:-/tmp}/check-keys.XXXXXX")"
    trap 'rm -rf "$tmp"' EXIT
    mkdir -p "$tmp/cfg" "$tmp/run" && chmod 700 "$tmp/run"
    env -u DBUS_SESSION_BUS_ADDRESS XDG_CONFIG_HOME="$tmp/cfg" XDG_RUNTIME_DIR="$tmp/run" \
      dbus-run-session -- bash "$here/check-keys.sh" --repo-inner
    ;;
  --repo-inner)  # internal: runs inside the isolated session
    bash "$SETTINGS_SH" >/dev/null
    check
    ;;
  *) usage ;;
esac
