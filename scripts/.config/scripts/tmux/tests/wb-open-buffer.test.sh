#!/usr/bin/env bash
# Tests for `wb_open_buffer`: a missing shared open-buffer.sh is a hard error
# naming the stow command, and the non-tmux path hands off to the script's
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

REPO_SCRIPT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../../.." && pwd)/claude/.claude/skills/decision-buffer/scripts/open-buffer.sh"

# --- script missing: hard error naming the stow command, editor never runs --
EMPTY_HOME="$FIXTURE/home-empty"
mkdir -p "$EMPTY_HOME"
err="$(env -u TMUX -u TMUX_PANE HOME="$EMPTY_HOME" EDITOR="$FIXTURE/fake-editor.sh" bash -c '
  source "'"$WB"'"
  set +e
  wb_open_buffer "'"$SCRATCH"'"
  echo "rc=$?"
' 2>&1)"
assert "missing script: returns non-zero" 'rc=1' "$err"
assert "missing script: names the stow command" 'stow --no-folding -t "\$HOME" claude' "$err"
[ ! -e "$ENV_CAPTURE" ] && echo "ok   - missing script: editor never ran" \
  || { echo "FAIL - missing script: editor ran anyway"; fail=1; }

# --- script stowed, non-tmux: --direct, WB_REVIEW_BUFFER=1 reaches the editor
STOWED_HOME="$FIXTURE/home-stowed"
mkdir -p "$STOWED_HOME/.claude/skills/decision-buffer/scripts"
ln -s "$REPO_SCRIPT" "$STOWED_HOME/.claude/skills/decision-buffer/scripts/open-buffer.sh"
env -u TMUX -u TMUX_PANE HOME="$STOWED_HOME" EDITOR="$FIXTURE/fake-editor.sh" bash -c '
  source "'"$WB"'"
  wb_open_buffer "'"$SCRATCH"'"
'
assert "non-tmux: WB_REVIEW_BUFFER=1 reached the editor process" \
  '^WB_REVIEW_BUFFER=1$' "$(cat "$ENV_CAPTURE" 2>/dev/null)"

echo
[ "$fail" -eq 0 ] && echo "ALL PASS" || echo "FAILURES"
exit "$fail"
