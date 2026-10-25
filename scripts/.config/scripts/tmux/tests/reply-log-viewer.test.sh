#!/usr/bin/env bash
# Headless check of the reply-log viewer (nvim claude-tmux.replies): after a tick
# that rendered files, a tick whose chain is empty (the new session after /clear
# has no file yet) keeps the buffer instead of blanking it.
# Run: bash scripts/.config/scripts/tmux/tests/reply-log-viewer.test.sh
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../../.." && pwd)"
ROOT="$(mktemp -d -t reply-log-viewer.XXXXXX)"
trap 'rm -rf "$ROOT"' EXIT

printf -- '---\nsession_id: s1\n---\n\nEARLIER-SESSION-TEXT\n' >"$ROOT/s1.md"
# the stub chain: prints the file on its first call, nothing after
cat >"$ROOT/chain.sh" <<STUB
#!/usr/bin/env bash
if [ ! -e "$ROOT/called" ]; then : >"$ROOT/called"; echo "$ROOT/s1.md"; fi
STUB
chmod +x "$ROOT/chain.sh"

out="$(nvim --headless -u NONE \
  -c "lua package.path='$REPO/nvim/.config/nvim/lua/?.lua;'..package.path" \
  -c "lua require('claude-tmux.replies').follow({ pane = '%1', script = '$ROOT/chain.sh' })" \
  -c "lua vim.wait(3500, function() return false end); io.stdout:write(table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), '\n'), '\n')" \
  -c 'qa!' 2>&1)"

fail=0
case "$out" in *EARLIER-SESSION-TEXT*) echo "ok   - buffer keeps the earlier session after an empty chain" ;; *) echo "FAIL - buffer was blanked: [$out]"; fail=1 ;; esac
case "$out" in *Waiting*) echo "FAIL - placeholder shown after a render"; fail=1 ;; *) echo "ok   - no placeholder after a render" ;; esac
[ -e "$ROOT/called" ] && echo "ok   - stub chain ran" || { echo "FAIL - stub chain never ran"; fail=1; }

echo
if [ "$fail" = 0 ]; then echo "ALL PASSED"; else echo "SOME FAILED"; exit 1; fi
