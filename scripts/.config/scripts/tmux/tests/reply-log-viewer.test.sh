#!/usr/bin/env bash
# Headless checks of the reply-log viewer (nvim claude-tmux.replies):
#   - after a tick that rendered files, a tick whose chain is empty (the new
#     session after /clear has no file yet) keeps the buffer instead of blanking it;
#   - a chain script that is missing at first, or that hangs past the 5 s timeout,
#     doesn't wedge the follow loop: a later tick still renders.
# Run: bash scripts/.config/scripts/tmux/tests/reply-log-viewer.test.sh
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../../.." && pwd)"
ROOT="$(mktemp -d -t reply-log-viewer.XXXXXX)"
trap 'rm -rf "$ROOT"' EXIT

printf -- '---\nsession_id: s1\n---\n\nEARLIER-SESSION-TEXT\n' >"$ROOT/s1.md"

fail=0
ok()  { echo "ok   - $1"; }
bad() { echo "FAIL - $1"; fail=1; }

# view <chain script> <ms> — follow in headless nvim for <ms>, print the buffer
view() {
  nvim --headless -u NONE \
    -c "lua package.path='$REPO/nvim/.config/nvim/lua/?.lua;'..package.path" \
    -c "lua require('claude-tmux.replies').follow({ pane = '%1', script = '$1' })" \
    -c "lua vim.wait($2, function() return false end); io.stdout:write(table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), '\n'), '\n')" \
    -c 'qa!' 2>&1
}

echo "# an empty chain after a render keeps the buffer"
# the stub chain: prints the file on its first call, nothing after; logs each call
cat >"$ROOT/chain.sh" <<STUB
#!/usr/bin/env bash
echo x >>"$ROOT/calls"
[ "\$(wc -l <"$ROOT/calls")" -eq 1 ] && echo "$ROOT/s1.md"
exit 0
STUB
chmod +x "$ROOT/chain.sh"
out="$(view "$ROOT/chain.sh" 3500)"
case "$out" in *EARLIER-SESSION-TEXT*) ok "buffer keeps the earlier session after an empty chain" ;; *) bad "buffer was blanked: [$out]" ;; esac
case "$out" in *Waiting*) bad "placeholder shown after a render" ;; *) ok "no placeholder after a render" ;; esac
calls="$(wc -l <"$ROOT/calls" 2>/dev/null || echo 0)"
[ "$calls" -ge 2 ] && ok "empty ticks ran after the render ($calls calls)" || bad "only $calls chain call(s): the empty tick never ran"

echo "# a chain script missing at first: the loop recovers once it appears"
missing="$ROOT/later.sh"
( sleep 1.5; printf '#!/usr/bin/env bash\necho "%s"\n' "$ROOT/s1.md" >"$missing.tmp"; chmod +x "$missing.tmp"; mv "$missing.tmp" "$missing" ) &
out="$(view "$missing" 4000)"
wait
case "$out" in *EARLIER-SESSION-TEXT*) ok "rendered after the script appeared" ;; *) bad "loop wedged by the missing script: [$out]" ;; esac

echo "# a chain that hangs past the timeout: the next tick still renders"
cat >"$ROOT/hang.sh" <<STUB
#!/usr/bin/env bash
if [ ! -e "$ROOT/hung" ]; then : >"$ROOT/hung"; exec sleep 30; fi
echo "$ROOT/s1.md"
STUB
chmod +x "$ROOT/hang.sh"
out="$(view "$ROOT/hang.sh" 8000)"
case "$out" in *EARLIER-SESSION-TEXT*) ok "rendered after the hung call timed out" ;; *) bad "loop wedged by the hung chain: [$out]" ;; esac

echo
if [ "$fail" = 0 ]; then echo "ALL PASSED"; else echo "SOME FAILED"; exit 1; fi
