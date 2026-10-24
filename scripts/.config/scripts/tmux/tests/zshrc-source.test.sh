#!/usr/bin/env bash
# Regression coverage for sourcing zsh/.zshrc from a non-interactive shell.
# Claude Code's command shell is non-interactive and runs with
# nobareglobqual; before the interactive-only guard, zinit's
# `*.plugin.zsh(DN)` glob failed there ("no matches found") and every
# `source ~/.zshrc && …` chain aborted. Also covers the nvm block that puts
# the default alias's install on PATH without `nvm use`.
#
# Each scenario runs under a throwaway HOME (so ~/.zshrc.local, nvm, pyenv,
# gcloud are whatever the fixture says) and a minimal PATH (so the caller's
# own node install can't satisfy an assertion). Interactive shells aren't
# covered here: they'd clone zinit over the network.
#
# Run: bash scripts/.config/scripts/tmux/tests/zshrc-source.test.sh
set -uo pipefail

ZSHRC="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../../.." && pwd)/zsh/.zshrc"
ZSH="$(command -v zsh)" || { echo "FAIL - zsh not found on PATH"; exit 1; }

SCRATCH="$(mktemp -d -t zshrc-source.XXXXXX)"
cleanup() { rm -rf "$SCRATCH"; }
trap cleanup EXIT

fail=0
assert_eq() { # <desc> <expected> <actual>
  if [ "$2" = "$3" ]; then
    echo "ok   - $1"
  else
    echo "FAIL - $1 (expected '$2', got '$3')"
    fail=1
  fi
}
assert_not_contains() { # <desc> <file> <needle>
  if grep -qF -- "$3" "$2"; then
    echo "FAIL - $1 (found '$3' in $2)"
    fail=1
  else
    echo "ok   - $1"
  fi
}

# new_home <name> — a fresh HOME for one scenario; prints its path.
new_home() {
  local h="$SCRATCH/$1"
  mkdir -p "$h"
  echo "$h"
}

# fake_nvm <home> <default-alias> <version>... — an nvm tree whose nvm.sh
# only records how `nvm` gets called.
fake_nvm() {
  local nvm_dir="$1/.config/nvm" alias="$2" v
  shift 2
  mkdir -p "$nvm_dir/alias"
  printf '%s\n' "$alias" > "$nvm_dir/alias/default"
  for v in "$@"; do mkdir -p "$nvm_dir/versions/node/$v/bin"; done
  cat > "$nvm_dir/nvm.sh" <<'EOF'
nvm() { print -r -- "nvm $*" >> "$NVM_DIR/calls"; }
EOF
}

# source_rc <home> <stderr-file> [zsh setup…] — sources the rc in a
# non-interactive `zsh -f`, then prints the first node bin dir on PATH (or
# "none"), then NVM_BIN and NVM_INC on a second line ("unset" if empty).
# The rc's exit status is the function's.
source_rc() {
  local home="$1" err="$2" setup="${3:-}"
  env -i HOME="$home" PATH=/usr/bin:/bin TERM=dumb "$ZSH" -f -c "
    $setup
    source '$ZSHRC' || exit \$?
    print -r -- \${\${path[(r)*/versions/node/*]}:-none}
    print -r -- \${NVM_BIN:-unset} \${NVM_INC:-unset}
  " 2>"$err"
}

# --- 1. agent shell: nobareglobqual, no plugins installed ----------------
h="$(new_home agent)"
out="$(source_rc "$h" "$h.err" 'setopt nobareglobqual')"
assert_eq "agent shell (nobareglobqual): source exits 0" 0 $?
assert_not_contains "agent shell: no zinit glob error" "$h.err" "no matches found"
# Offline, a missing guard fails the clone and the glob error never fires;
# the zinit dir is mkdir'd before the clone either way.
assert_eq "agent shell: zinit bootstrap skipped" absent \
  "$([ -e "$h/.local/share/zinit" ] && echo present || echo absent)"
assert_eq "agent shell: no nvm, no node on PATH" none "${out%%$'\n'*}"

# --- 2. plain non-interactive zsh, no ~/.zshrc.local ---------------------
h="$(new_home plain)"
source_rc "$h" "$h.err" >/dev/null
assert_eq "plain zsh -f: source exits 0 without ~/.zshrc.local" 0 $?

# --- 3. nvm: major-version alias picks the newest matching install -------
h="$(new_home nvm-major)"
fake_nvm "$h" v24 v20.19.5 v24.1.0 v24.11.1
out="$(source_rc "$h" "$h.err" 'setopt nobareglobqual')"
assert_eq "nvm alias v24: source exits 0" 0 $?
assert_eq "nvm alias v24 -> v24.11.1 on PATH" "$h/.config/nvm/versions/node/v24.11.1/bin" "${out%%$'\n'*}"
v="$h/.config/nvm/versions/node/v24.11.1"
assert_eq "nvm alias v24: NVM_BIN/NVM_INC set as nvm use would" "$v/bin $v/include/node" "${out#*$'\n'}"
assert_eq "nvm alias v24: no nvm use at load" "" "$(cat "$h/.config/nvm/calls" 2>/dev/null)"

# --- 4. nvm: a minor-version alias matches like nvm (v24.1 != v24.11) ----
h="$(new_home nvm-minor)"
fake_nvm "$h" 24.1 v24.1.0 v24.10.2 v24.11.1
out="$(source_rc "$h" "$h.err")"
assert_eq "nvm alias 24.1 -> v24.1.0 on PATH, not v24.11.1" "$h/.config/nvm/versions/node/v24.1.0/bin" "${out%%$'\n'*}"

# --- 5. nvm: an alias the glob can't resolve falls back to nvm use -------
h="$(new_home nvm-lts)"
fake_nvm "$h" 'lts/*' v24.11.1
out="$(source_rc "$h" "$h.err")"
assert_eq "nvm alias lts/*: nothing globbed onto PATH" none "${out%%$'\n'*}"
assert_eq "nvm alias lts/*: falls back to nvm use default" "nvm use default --silent" "$(cat "$h/.config/nvm/calls" 2>/dev/null)"

if [ "$fail" -eq 0 ]; then
  echo "ALL PASS"
else
  exit 1
fi
