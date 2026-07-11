#!/usr/bin/env bash
# Tests for `wb_open_buffer`'s WB_REVIEW_BUFFER=1 env-var signal
# (dotfiles--fix-wb-sweep-buffer-autoformat) — the tmux branch needs a real
# attached client to exercise end-to-end, but the non-tmux $EDITOR fallback
# branch (wb.sh:896) doesn't: a fixture $EDITOR that just dumps its own
# environment lets us call the real, unstubbed wb_open_buffer and assert
# the flag actually reached the child process, closing the gap every other
# wb_open_buffer-touching test leaves open by stubbing it to a no-op.
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

# --- non-tmux fallback branch: WB_REVIEW_BUFFER=1 must reach the editor ------
env -u TMUX -u TMUX_PANE EDITOR="$FIXTURE/fake-editor.sh" bash -c '
  source "'"$WB"'"
  wb_open_buffer "'"$SCRATCH"'"
'
assert "non-tmux branch: WB_REVIEW_BUFFER=1 reached the editor process" \
  '^WB_REVIEW_BUFFER=1$' "$(cat "$ENV_CAPTURE" 2>/dev/null)"

echo
[ "$fail" -eq 0 ] && echo "ALL PASS" || echo "FAILURES"
exit "$fail"
