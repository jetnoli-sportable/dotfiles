#!/usr/bin/env bash
# Tests for `wb_open_buffer`: with no stowed open-buffer.sh it falls back to the
# checkout's copy; with neither it is a hard error naming both paths and the
# stow command, and the non-tmux path hands off to the script's
# --direct mode with the WB_REVIEW_BUFFER=1 env-var signal
# (dotfiles--fix-wb-sweep-buffer-autoformat) reaching the editor. A fixture
# $EDITOR that just dumps its own environment lets us call the real,
# unstubbed wb_open_buffer; a fixture $HOME controls whether the script is
# "stowed".
# Run: bash scripts/.config/scripts/tmux/tests/wb-open-buffer.test.sh
set -uo pipefail

WB="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/wb.sh"
FIXTURE="$(mktemp -d -t wb-open-buffer-fixture.XXXXXX)"
trap 'rm -rf "$FIXTURE"' EXIT

fail=0
assert() { # <desc> <expected-regex> <actual>
  if printf '%s' "$3" | grep -qE "$2"; then
    echo "ok   - $1"
  else
    echo "FAIL - $1"
    echo "       expected match: $2"
    echo "       got: $(printf '%s' "$3" | head -5)"
    fail=1
  fi
}

# shellcheck disable=SC1090
source "$WB"
set +e   # wb.sh sets -e; this test intentionally captures non-zero exits

# --- fixture $EDITOR: dump env to a file instead of actually opening anything
ENV_CAPTURE="$FIXTURE/captured-env"
cat > "$FIXTURE/fake-editor.sh" <<EOF
#!/usr/bin/env bash
env > "$ENV_CAPTURE"
EOF
chmod +x "$FIXTURE/fake-editor.sh"

SCRATCH="$FIXTURE/scratch.md"
echo "placeholder" > "$SCRATCH"

REPO_SCRIPT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../../.." && pwd)/claude/.claude/skills/decide/scripts/open-buffer.sh"

# --- neither copy exists: hard error naming both paths and the stow command,
# editor never runs. wb_open_buffer is lifted out of wb.sh into a temp dir so
# its checkout fallback (resolved from its own file) points at nothing.
EMPTY_HOME="$FIXTURE/home-empty"
mkdir -p "$EMPTY_HOME" "$FIXTURE/iso"
sed -n '/^wb_open_buffer() {$/,/^}$/p' "$WB" > "$FIXTURE/iso/fn.sh"
err="$(env -u TMUX -u TMUX_PANE HOME="$EMPTY_HOME" EDITOR="$FIXTURE/fake-editor.sh" bash -c '
  source "'"$FIXTURE/iso/fn.sh"'"
  wb_open_buffer "'"$SCRATCH"'"
  echo "rc=$?"
' 2>&1)"
assert "missing script: returns non-zero" 'rc=1' "$err"
assert "missing script: names the stowed path" "$EMPTY_HOME/.claude/skills/decide/scripts/open-buffer.sh" "$err"
assert "missing script: names the checkout path" "$FIXTURE/iso/../../../../claude/.claude/skills/decide/scripts/open-buffer.sh" "$err"
# shellcheck disable=SC2016  # a literal $HOME in the expected message
assert "missing script: names the stow command" 'stow --no-folding -t "\$HOME" claude' "$err"
if [ -e "$ENV_CAPTURE" ]; then
  echo "FAIL - missing script: editor ran anyway"; fail=1
else
  echo "ok   - missing script: editor never ran"
fi

# --- nothing stowed, real wb.sh from the repo: the checkout copy runs ------
env -u TMUX -u TMUX_PANE HOME="$EMPTY_HOME" EDITOR="$FIXTURE/fake-editor.sh" bash -c '
  source "'"$WB"'"
  wb_open_buffer "'"$SCRATCH"'"
'
assert "no stowed script: checkout copy ran the editor" \
  '^WB_REVIEW_BUFFER=1$' "$(cat "$ENV_CAPTURE" 2>/dev/null)"
rm -f "$ENV_CAPTURE"

# --- script stowed, non-tmux: --direct, WB_REVIEW_BUFFER=1 reaches the editor
STOWED_HOME="$FIXTURE/home-stowed"
mkdir -p "$STOWED_HOME/.claude/skills/decide/scripts"
ln -s "$REPO_SCRIPT" "$STOWED_HOME/.claude/skills/decide/scripts/open-buffer.sh"
env -u TMUX -u TMUX_PANE HOME="$STOWED_HOME" EDITOR="$FIXTURE/fake-editor.sh" bash -c '
  source "'"$WB"'"
  wb_open_buffer "'"$SCRATCH"'"
'
assert "non-tmux: WB_REVIEW_BUFFER=1 reached the editor process" \
  '^WB_REVIEW_BUFFER=1$' "$(cat "$ENV_CAPTURE" 2>/dev/null)"

echo
[ "$fail" -eq 0 ] && echo "ALL PASS" || echo "FAILURES"
exit "$fail"
