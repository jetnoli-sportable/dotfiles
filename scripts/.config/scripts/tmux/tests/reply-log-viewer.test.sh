#!/usr/bin/env bash
# Headless checks of the reply-log viewer (nvim claude-tmux.replies):
#   - after a tick that rendered files, a tick whose chain is empty (the new
#     session after /clear has no file yet) keeps the buffer instead of blanking it;
#   - a chain script that is missing at first, or that hangs past the 5 s timeout,
#     doesn't wedge the follow loop: a later tick still renders.
# (The runtimepath is prepended too: nvim's own loader finds an installed copy of the
# module, e.g. the stowed one, before package.path, and the test must run this tree's.)
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
    -c "lua package.path='$REPO/nvim/.config/nvim/lua/?.lua;'..package.path; vim.opt.rtp:prepend('$REPO/nvim/.config/nvim')" \
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

echo "# U6: the divider above the first unseen turn, and the view opening there"
cat >"$ROOT/three.md" <<'MD'
---
session_id: s3
---

# task · 2026-11-15 10:00
## 2026-11-15 10:00 · first
<!-- turn {"prompt_id":"p1","session_id":"s3","ts":"2026-11-15T10:00:00.000Z"} -->
### Prompt
> one
### Reply
SEEN-REPLY-ONE

## 2026-11-15 10:05 · second
<!-- turn {"prompt_id":"p2","session_id":"s3","ts":"2026-11-15T10:05:00.000Z"} -->
### Prompt
> two
### Reply
MISSED-REPLY-TWO

## 2026-11-15 10:10 · third
<!-- turn {"prompt_id":"p3","session_id":"s3","ts":"2026-11-15T10:10:00.000Z"} -->
### Prompt
> three
### Reply
MISSED-REPLY-THREE
MD
printf '#!/usr/bin/env bash\necho "%s"\n' "$ROOT/three.md" >"$ROOT/three-chain.sh"; chmod +x "$ROOT/three-chain.sh"
# view_unseen <opts text> <ms> — buffer lines, then the cursor line on a last line "CURSOR=<n>"
view_unseen() {
  nvim --headless -u NONE \
    -c "lua package.path='$REPO/nvim/.config/nvim/lua/?.lua;'..package.path; vim.opt.rtp:prepend('$REPO/nvim/.config/nvim')" \
    -c "lua require('claude-tmux.replies').follow({ pane = '%1', script = '$ROOT/three-chain.sh'$1 })" \
    -c "lua vim.wait($2, function() return false end); io.stdout:write(table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), '\n'), '\nCURSOR=', vim.api.nvim_win_get_cursor(0)[1], '\n')" \
    -c 'qa!' 2>&1
}
out="$(view_unseen ", unseen = { ids = { 'p2', 'p3' }, count = 2 }" 2500)"
div="$(printf '%s\n' "$out" | grep -n 'unseen since you left' | head -1 | cut -d: -f1)"
two="$(printf '%s\n' "$out" | grep -n '^## 2026-11-15 10:05' | cut -d: -f1)"
one="$(printf '%s\n' "$out" | grep -n '^## 2026-11-15 10:00' | cut -d: -f1)"
if [ -n "$div" ]; then ok "a divider is drawn"; else bad "no divider: [$out]"; fi
case "$out" in *"──── 2 unseen since you left ────"*) ok "divider says how many" ;; *) bad "divider text: [$out]" ;; esac
if [ "$(printf '%s\n' "$out" | grep -c 'unseen since you left')" = 1 ]; then ok "one divider only (not one per id)"; else bad "several dividers"; fi
if [ -n "$div" ] && [ -n "$two" ] && [ "$two" -gt "$div" ] && [ "$two" -le $((div + 3)) ]; then ok "the divider sits directly above the first unseen turn's heading"; else bad "divider $div, heading $two"; fi
if [ -n "$one" ] && [ "$one" -lt "$div" ]; then ok "the seen turn stays above it"; else bad "seen turn at $one"; fi
cur="$(printf '%s\n' "$out" | sed -n 's/^CURSOR=//p')"
if [ "$cur" = "$div" ]; then ok "the view opens with the cursor on the divider ($cur)"; else bad "cursor $cur, divider $div"; fi
out="$(view_unseen "" 2500)"
case "$out" in *"unseen since you left"*) bad "divider without an unseen option" ;; *) ok "no unseen option: no divider" ;; esac
cur="$(printf '%s\n' "$out" | sed -n 's/^CURSOR=//p')"
total="$(printf '%s\n' "$out" | sed '$d' | wc -l)"
if [ "$cur" = "$total" ]; then ok "no unseen option: pinned to the bottom as before ($cur of $total)"; else bad "cursor $cur of $total"; fi
out="$(view_unseen ", unseen = { ids = { 'nope' }, count = 1 }" 2500)"
case "$out" in *"unseen since you left"*) bad "divider for an id no turn carries" ;; *) ok "an id with no turn in the files: no divider, no error" ;; esac
cur="$(printf '%s\n' "$out" | sed -n 's/^CURSOR=//p')"
total="$(printf '%s\n' "$out" | sed '$d' | wc -l)"
if [ "$cur" = "$total" ]; then ok "... and the view stays pinned to the bottom"; else bad "cursor $cur of $total"; fi

echo
if [ "$fail" = 0 ]; then echo "ALL PASSED"; else echo "SOME FAILED"; exit 1; fi
