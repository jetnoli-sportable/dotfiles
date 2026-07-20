#!/usr/bin/env bash
# Tests for handoff.sh's --pane mode (U1) — plain-bash assertions against real
# throwaway tmux sessions, same convention as handoff.test.sh /
# handoff-poller.test.sh: real tmux operations, never a mocked tmux, and never
# a real `claude` process.
#
# How "no real claude" is enforced without mocking tmux: each throwaway session
# sets a session-scoped `default-command` that bakes a stub-first $PATH into a
# `bash --norc` shell (see mk_pane_session). Because a pane split by handoff.sh
# inherits the session's default-command, the `claude` handoff.sh types into
# the new pane resolves to a fixture stub — a small script that prints a
# boot-ready anchor and then behaves per scenario — never the real binary on
# $PATH. `--norc` keeps rc files (this machine's default is a slow, PATH-
# rebuilding zsh) from clobbering the stub-first PATH, which is why a bare
# `set-environment PATH` is NOT enough on its own. tmux's own split-window,
# send-keys, capture-pane, and display all run for real against these sessions.
#
# The full spawn-to-permission-clear against a REAL `claude` boot is the plan's
# manual smoke walkthrough (Verification Contract), not this automated suite —
# a stub can't reproduce a real TUI's render-transition timing, the same reason
# handoff-poller.test.sh gives for keeping the real spawn out of automation.
#
# handoff.sh's whole run body — the --pane branch AND the switch/spawn path —
# sits under one `[ "${BASH_SOURCE[0]}" = "${0}" ]` guard, so nothing dispatches
# when the file is sourced (that is exactly what lets the sibling
# handoff-poller.test.sh source it to reach the helper functions). This suite
# therefore exercises the pane branch by running handoff.sh as a real
# subprocess. $TMUX is inherited from the suite's own tmux client; $TMUX_PANE is
# overridden per call to point at a throwaway fixture pane so a split can never
# land in the real window.
# Run: bash scripts/.config/scripts/tmux/tests/handoff-pane.test.sh
set -uo pipefail

HANDOFF="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/handoff.sh"

if [ -z "${TMUX:-}" ]; then
  echo "FAIL - this suite must run from inside a tmux client (it exercises real tmux sessions)" >&2
  exit 1
fi

# Fast, bounded timeouts — every booting scenario matches its anchor within a
# second or two; the deliberate-timeout scenarios override these even shorter
# right before their own invocation.
export HANDOFF_BOOT_TIMEOUT=15
export HANDOFF_PERMISSION_TIMEOUT=3

STUBROOT="$(mktemp -d -t handoff-pane-stub.XXXXXX)"
WTROOT="$(mktemp -d -t handoff-pane-wt.XXXXXX)"     # git-worktree fixtures live here
NONGIT="$(mktemp -d -t handoff-pane-nongit.XXXXXX)" # a dir that is NOT a git worktree

SESSIONS_TO_KILL=()
cleanup() {
  local s
  for s in "${SESSIONS_TO_KILL[@]}"; do
    tmux kill-session -t "=$s" 2>/dev/null || true
  done
  rm -rf "$STUBROOT" "$WTROOT" "$NONGIT"
}
trap cleanup EXIT

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
assert_eq() { # <desc> <expected-exact> <actual>
  if [ "$3" = "$2" ]; then
    echo "ok   - $1"
  else
    echo "FAIL - $1"
    echo "       expected: $2"
    echo "       got:      $3"
    fail=1
  fi
}
refute() { # <desc> <unexpected-regex> <actual> — passes when NOT matched
  if printf '%s' "$3" | grep -qE "$2"; then
    echo "FAIL - $1"
    echo "       unexpectedly matched: $2"
    fail=1
  else
    echo "ok   - $1"
  fi
}

# ---- stub claude scripts (one dir per behavior; each dir goes on a session's
#      baked PATH) ----------------------------------------------------------
# A real `claude` boot fills its pane with a banner well before the ready
# anchor, so capture-pane's `tail -n 20` (both production's poller and here)
# lands on recent lines. A bare stub that prints one line leaves the anchor at
# the top with blank rows below, so the tail window would miss it — the same
# gap handoff-poller.test.sh documents. FILLER reproduces a filled pane so the
# anchor reliably lands inside the tail window.
FILLER='for i in $(seq 1 200); do echo "pad-line-$i"; done'

mk_stub() { # <name> <body-after-anchor...>  -> echoes the stub dir
  local name="$1"; shift
  local dir="$STUBROOT/$name"
  mkdir -p "$dir"
  {
    printf '#!/usr/bin/env bash\n'
    printf '%s\n' "$*"
  } > "$dir/claude"
  chmod +x "$dir/claude"
  printf '%s\n' "$dir"
}

# boots + stays alive, echoing injected stdin back into the pane (so an
# injection can be observed landing in the pane).
STUB_BOOT="$(mk_stub boot "$FILLER"$'\n''echo "? for shortcuts"'$'\n''exec cat')"
# boots then exits immediately — proves the pane's own shell survives the
# launched command exiting (a plain split, not `split-window claude`).
STUB_EXIT="$(mk_stub exit "$FILLER"$'\n''echo "? for shortcuts"'$'\n''exit 0')"
# never emits a boot anchor — drives the boot-timeout path.
STUB_NOANCHOR="$(mk_stub noanchor 'exec cat >/dev/null')"
# boots, consumes the injected pointer line, then presents the tasks/ Read
# permission dialog — exercises the reused handshake end to end against a pane.
STUB_PERM="$(mk_stub perm \
  "$FILLER"$'\n''echo "? for shortcuts"'$'\n''read -r _'$'\n''echo "Read(~/code/tasks/dotfiles--child.md)"'$'\n''echo "Do you want to proceed?"'$'\n''echo "1. Yes  2. Yes, do not ask again  3. No"'$'\n''exec cat >/dev/null')"
# boots, consumes the injected pointer, then presents a dialog that is NOT the
# tasks/Read one (no "~/code/tasks", no "Read" — a Bash tool prompt). Used in a
# deliberately NARROW pane where the injected pointer's echo WRAPS: the only
# source of "Read ~/code/tasks/..." tokens in the pane is the wrapped pointer
# itself, so the permission gate must strip it (via the poller's -J join) and
# NOT auto-approve this unrelated dialog. Regression guard for the wrapped-
# pointer strip fix.
STUB_WRAPPERM="$(mk_stub wrapperm \
  "$FILLER"$'\n''echo "? for shortcuts"'$'\n''read -r _'$'\n''echo "Bash(rm -rf /tmp/scratch)"'$'\n''echo "Do you want to proceed?"'$'\n''echo "1. Yes  2. Yes, allow all edits  3. No"'$'\n''exec cat >/dev/null')"

# mk_pane_session <session-name> <stub-dir> <fixture-cwd>  -> echoes fixture pane id
# Creates a throwaway session whose panes launch `bash --norc` with <stub-dir>
# on PATH first, then a fixture window cwd'd to <fixture-cwd>. The returned
# pane id is what tests pass as $TMUX_PANE to handoff.sh.
mk_pane_session() {
  local sess="$1" stub="$2" cwd="$3" width="${4:-200}"
  tmux new-session -d -s "$sess" -x "$width" -y 50
  SESSIONS_TO_KILL+=("$sess")
  # NOTE: set-option's -t takes a bare session name, NOT the `=name` exact form
  # (that form errors "no such session" here); the `=` form is only for
  # display/send/split targets below.
  tmux set-option -t "$sess" default-command "PATH=\"$stub:\$PATH\" exec bash --norc -i"
  tmux new-window -t "=$sess" -n fix -c "$cwd"
  sleep 2   # let the fixture pane's shell settle before it is used as a target
  tmux display -p -t "=$sess:fix" '#{pane_id}'
}

mk_worktree() { # <name> -> echoes a fresh git-worktree fixture dir
  local d="$WTROOT/$1"
  mkdir -p "$d"
  git -C "$d" init -q
  printf '%s\n' "$d"
}

run_pane() { # <fixture-pane-id> <handoff args...>
  local fix="$1"; shift
  out="$(TMUX_PANE="$fix" bash "$HANDOFF" "$@" 2>&1)"
  rc=$?
}

panes_in() { tmux list-panes -t "=$1:fix" 2>/dev/null | wc -l | tr -d ' '; }

echo "########## handoff-pane.test.sh ##########"

# ===========================================================================
# Flag parsing / regression
# ===========================================================================

# no --pane, two positionals -> unchanged switch/spawn path. A repo with no
# live session and no real checkout falls through to the spawn branch, where
# `wb new` fails loudly ("not a git repo") — proving the switch/spawn path was
# taken, NOT the pane branch (same technique handoff.test.sh uses).
export TASKS_DIR="$WTROOT/tasks-fixture"; mkdir -p "$TASKS_DIR"
out="$(bash "$HANDOFF" "panetest-norepo-$$" "feat/x" 2>&1)"; rc=$?
assert_eq "no --pane: two positionals still take the switch/spawn path (exit non-zero)" "1" "$rc"
assert "no --pane: reached the spawn branch (wb new), not the pane branch" "wb new:.*not a git repo" "$out"
refute "no --pane: never entered the pane branch" "split (a|the) helper pane" "$out"

# zero args -> usage, exit 1, and the original first usage line is preserved.
out="$(bash "$HANDOFF" 2>&1)"; rc=$?
assert_eq "no args: exits non-zero" "1" "$rc"
assert "no args: usage message preserves the switch/spawn line" "usage: handoff\.sh <repo> <slug>" "$out"
assert "no args: usage message also documents --pane" "handoff\.sh --pane \[--await-perm\] <payload>" "$out"

# --pane with no payload -> pane usage, exit 1, before any split.
out="$(bash "$HANDOFF" --pane 2>&1)"; rc=$?
assert_eq "--pane, no payload: exits non-zero" "1" "$rc"
assert "--pane, no payload: pane usage message" "usage: handoff\.sh --pane" "$out"

# ===========================================================================
# Guards (no split must occur)
# ===========================================================================

# $TMUX_PANE unset -> loud error, no split.
out="$(env -u TMUX_PANE bash "$HANDOFF" --pane "some prompt" 2>&1)"; rc=$?
assert_eq "\$TMUX_PANE unset: exits non-zero" "1" "$rc"
assert "\$TMUX_PANE unset: loud error naming \$TMUX_PANE" "needs \\\$TMUX_PANE" "$out"

# invoking pane's cwd is not a git worktree -> refuse, do not split (KTD3).
DRIFT_SESS="hp-drift-$$"
DRIFT_FIX="$(mk_pane_session "$DRIFT_SESS" "$STUB_BOOT" "$NONGIT")"
before="$(panes_in "$DRIFT_SESS")"
run_pane "$DRIFT_FIX" --pane "review this"
after="$(panes_in "$DRIFT_SESS")"
assert_eq "worktree drift: exits non-zero" "1" "$rc"
assert "worktree drift: loud 'not a git worktree' error" "is not a git worktree" "$out"
assert_eq "worktree drift: did NOT split (pane count unchanged)" "$before" "$after"

# ===========================================================================
# Happy pane branch: worktree resolution, split, boot, inject (ephemeral)
# ===========================================================================
WT1="$(mk_worktree wt1)"
S1="hp-eph-$$"
FIX1="$(mk_pane_session "$S1" "$STUB_BOOT" "$WT1")"
before1="$(panes_in "$S1")"
run_pane "$FIX1" --pane "PANE-INJECT-MARKER-eph review the uncommitted changes"
after1="$(panes_in "$S1")"

assert_eq "ephemeral: exits 0" "0" "$rc"
assert "ephemeral: reports splitting a helper pane and injecting" "split a helper pane .* injected the payload" "$out"
assert_eq "split: window pane count increased by exactly one" "$((before1 + 1))" "$after1"

# the new pane id is reported in the outcome line; use it to check cwd + injection.
NEWPANE1="$(printf '%s' "$out" | grep -oE '%[0-9]+' | head -1)"
assert "split: outcome line names a concrete new pane id" "%[0-9]+" "$out"
newcwd="$(tmux display -p -t "$NEWPANE1" '#{pane_current_path}' 2>/dev/null)"
assert_eq "worktree resolution: new pane's cwd equals the invoking pane's worktree" "$WT1" "$newcwd"

# injection landed in the new pane (the stub echoes injected stdin back).
sleep 1
panetext1="$(tmux capture-pane -ep -t "$NEWPANE1" 2>/dev/null | tail -n 20)"
assert "injection: payload text reached the new pane" "PANE-INJECT-MARKER-eph" "$panetext1"

# ephemeral path did NOT block on / enter the permission poll.
refute "ephemeral: no permission handshake was attempted" "permission prompt" "$out"

# ===========================================================================
# Split direction is the flippable constant (KTD6)
# ===========================================================================
# Default (-h): the two panes sit side-by-side -> same pane_top.
WTH="$(mk_worktree wth)"
SH="hp-hsplit-$$"
FIXH="$(mk_pane_session "$SH" "$STUB_BOOT" "$WTH")"
run_pane "$FIXH" --pane "horizontal default"
assert_eq "default split: exits 0" "0" "$rc"
mapfile -t tops_h < <(tmux list-panes -t "=$SH:fix" -F '#{pane_top}')
if [ "${#tops_h[@]}" -eq 2 ] && [ "${tops_h[0]}" = "${tops_h[1]}" ]; then
  echo "ok   - default split is horizontal (side-by-side: both panes share a top row)"
else
  echo "FAIL - default split expected horizontal (equal pane_top); got tops: ${tops_h[*]}"
  fail=1
fi

# HANDOFF_PANE_SPLIT=-v: the two panes stack -> different pane_top.
WTV="$(mk_worktree wtv)"
SV="hp-vsplit-$$"
FIXV="$(mk_pane_session "$SV" "$STUB_BOOT" "$WTV")"
out="$(TMUX_PANE="$FIXV" HANDOFF_PANE_SPLIT=-v bash "$HANDOFF" --pane "vertical override" 2>&1)"; rc=$?
assert_eq "HANDOFF_PANE_SPLIT=-v: exits 0" "0" "$rc"
mapfile -t tops_v < <(tmux list-panes -t "=$SV:fix" -F '#{pane_top}')
if [ "${#tops_v[@]}" -eq 2 ] && [ "${tops_v[0]}" != "${tops_v[1]}" ]; then
  echo "ok   - HANDOFF_PANE_SPLIT=-v produces a vertical split (stacked: panes differ in pane_top)"
else
  echo "FAIL - HANDOFF_PANE_SPLIT=-v expected vertical (differing pane_top); got tops: ${tops_v[*]}"
  fail=1
fi

# ===========================================================================
# Split mechanism (KTD3): plain pane + send-keys launch -> the pane's own
# shell survives when the launched command exits fast.
# ===========================================================================
WTX="$(mk_worktree wtx)"
SX="hp-survive-$$"
FIXX="$(mk_pane_session "$SX" "$STUB_EXIT" "$WTX")"
run_pane "$FIXX" --pane "fast-exit stub"
assert_eq "fast-exit stub: exits 0 (boot anchor still matched before the stub exited)" "0" "$rc"
NEWPANEX="$(printf '%s' "$out" | grep -oE '%[0-9]+' | head -1)"
# the split pane must still exist (a `split-window claude` would have closed it
# on the stub's exit — no remain-on-exit).
sleep 1
if tmux list-panes -t "=$SX:fix" -F '#{pane_id}' | grep -qF "$NEWPANEX"; then
  echo "ok   - split mechanism: the pane's shell survives the launched command exiting fast"
else
  echo "FAIL - split mechanism: the pane closed when the launched command exited (was it a split-window-trailing command?)"
  fail=1
fi
# and the surviving shell still responds.
tmux send-keys -t "$NEWPANEX" -l 'echo SHELL-STILL-ALIVE-marker'; tmux send-keys -t "$NEWPANEX" Enter
sleep 1
survtext="$(tmux capture-pane -ep -t "$NEWPANEX" 2>/dev/null | tail -n 20)"
assert "split mechanism: the surviving shell still executes input" "SHELL-STILL-ALIVE-marker" "$survtext"

# ===========================================================================
# Handshake gating (KTD5): --await-perm enters the poll; no flag does not.
# ===========================================================================
# child binding: --await-perm drives into the permission poll. With no dialog
# emitted here (STUB_BOOT), it exhausts the (short) permission timeout and says
# so — proof it entered the poll, which the ephemeral path never does.
WTA="$(mk_worktree wta)"
SA="hp-await-$$"
FIXA="$(mk_pane_session "$SA" "$STUB_BOOT" "$WTA")"
run_pane "$FIXA" --pane --await-perm "Read the task file at ~/code/tasks/dotfiles--child.md - it carries the full context and states the first action to take."
assert_eq "--await-perm: exits 0" "0" "$rc"
assert "--await-perm: entered the permission poll (no prompt seen within the timeout)" "no permission prompt seen within" "$out"

# ephemeral: no --await-perm -> never enters the poll (distinct outcome line,
# and it returns without a permission wait).
WTB="$(mk_worktree wtb)"
SB="hp-noawait-$$"
FIXB="$(mk_pane_session "$SB" "$STUB_BOOT" "$WTB")"
run_pane "$FIXB" --pane "Read the task file at ~/code/tasks/dotfiles--child.md - it carries the full context and states the first action to take."
assert_eq "no --await-perm: exits 0" "0" "$rc"
refute "no --await-perm: never entered the permission poll (gating is on the flag, not payload content)" "no permission prompt seen within" "$out"
assert "no --await-perm: ephemeral outcome line instead" "booted claude, and injected the payload" "$out"

# ===========================================================================
# Handshake positive path: --await-perm with a real tasks/Read dialog present
# -> the reused co-occurrence gate matches and the prompt is cleared.
# ===========================================================================
WTP="$(mk_worktree wtp)"
SP="hp-perm-$$"
FIXP="$(mk_pane_session "$SP" "$STUB_PERM" "$WTP")"
out="$(TMUX_PANE="$FIXP" HANDOFF_PERMISSION_TIMEOUT=8 bash "$HANDOFF" --pane --await-perm "Read the task file at ~/code/tasks/dotfiles--child.md - it carries the full context and states the first action to take." 2>&1)"; rc=$?
assert_eq "handshake: exits 0" "0" "$rc"
assert "handshake: cleared the tasks/ read permission prompt" "cleared the tasks/ read permission prompt" "$out"

# ===========================================================================
# Wrapped-pointer strip regression (KTD5 safety): in a NARROW pane the injected
# ~130-char pointer echo wraps across rows. The permission gate's pointer strip
# is line-oriented, so without the poller's -J join it would no-op and the
# wrapped pointer's own "Read ~/code/tasks/..." text would satisfy the
# co-occurrence check — auto-approving an UNRELATED dialog with the broad
# "allow all edits" grant. Here the dialog is a Bash tool prompt (no tasks/Read
# tokens of its own), so a match can ONLY come from a failure to strip the
# wrapped pointer. Expect the mismatch outcome (no '2' sent), NOT "cleared".
# This assertion fails if the -J join is ever removed from the poller.
WTW="$(mk_worktree wtw)"
SW="hp-wrap-$$"
# width 90 -> the -h split gives ~44-col panes, guaranteeing the pointer wraps.
FIXW="$(mk_pane_session "$SW" "$STUB_WRAPPERM" "$WTW" 90)"
out="$(TMUX_PANE="$FIXW" HANDOFF_PERMISSION_TIMEOUT=8 bash "$HANDOFF" --pane --await-perm "Read the task file at ~/code/tasks/dotfiles--feat-handoff-pane-review.md - it carries the full context and states the first action to take." 2>&1)"; rc=$?
assert_eq "wrapped-pointer strip: exits 0" "0" "$rc"
assert "wrapped-pointer strip: unrelated dialog NOT auto-approved (mismatch outcome)" "didn't match the expected tasks/Read shape" "$out"
refute "wrapped-pointer strip: did NOT falsely clear the prompt (would fire without -J)" "cleared the tasks/ read permission prompt" "$out"

# ===========================================================================
# Boot timeout: a pane that never shows a boot anchor fails loudly.
# ===========================================================================
WTT="$(mk_worktree wtt)"
ST="hp-boottimeout-$$"
FIXT="$(mk_pane_session "$ST" "$STUB_NOANCHOR" "$WTT")"
SECONDS=0
out="$(TMUX_PANE="$FIXT" HANDOFF_BOOT_TIMEOUT=3 bash "$HANDOFF" --pane "never boots" 2>&1)"; rc=$?
elapsed=$SECONDS
assert_eq "boot timeout: exits non-zero" "1" "$rc"
assert "boot timeout: loud message pointing at the pane" "never showed a boot-ready anchor" "$out"
if [ "$elapsed" -ge 3 ] && [ "$elapsed" -le 8 ]; then
  echo "ok   - boot timeout: completes near the (overridden 3s) timeout (${elapsed}s)"
else
  echo "FAIL - boot timeout: elapsed ${elapsed}s not within the expected 3-8s window"
  fail=1
fi

# ===========================================================================
# Source-level invariants (mirroring handoff-poller.test.sh's grep style) —
# the shape guarantees that don't need a live pane to prove.
# ===========================================================================
# split-window carries NO trailing command; claude is launched by a subsequent
# send-keys (KTD3). Assert the split line uses the flippable constant and that
# no split-window line embeds the word `claude`.
if grep -qF 'tmux split-window "$HANDOFF_PANE_SPLIT" -t "$TMUX_PANE"' "$HANDOFF"; then
  echo "ok   - split-window uses the HANDOFF_PANE_SPLIT constant, targeted at \$TMUX_PANE"
else
  echo "FAIL - expected a split-window using \"\$HANDOFF_PANE_SPLIT\" targeted at \$TMUX_PANE"
  fail=1
fi
# Scoped to the actual command line (`^[^#]*tmux split-window`), not comment
# prose — handoff.sh's KTD3 comment legitimately names `split-window ... 'claude'`
# to explain why it's forbidden, which a whole-line grep would false-positive on
# (same reason the /model check below is scoped to send-keys lines).
if grep -E '^[^#]*tmux split-window' "$HANDOFF" | grep -qF 'claude'; then
  echo "FAIL - the split-window command embeds a trailing 'claude' command (KTD3 forbids this)"
  fail=1
else
  echo "ok   - the split-window command carries no trailing 'claude' command"
fi
if grep -qF "tmux send-keys -t \"\$pane\" -l 'claude'" "$HANDOFF"; then
  echo "ok   - claude is launched via a separate send-keys into the new pane's shell"
else
  echo "FAIL - expected 'claude' launched via send-keys into the new pane"
  fail=1
fi

# injection shape: payload via one send-keys -l, Enter via a SEPARATE call.
if grep -qF 'tmux send-keys -t "$pane" -l "$payload"' "$HANDOFF" \
   && grep -qF 'tmux send-keys -t "$pane" Enter' "$HANDOFF"; then
  echo "ok   - pane injection: payload via send-keys -l, Enter via a separate call"
else
  echo "FAIL - pane injection: expected a separate '-l \"\$payload\"' line and an 'Enter' line"
  fail=1
fi

# no pane send-keys call combines -l and Enter on one line (embedded-newline risk).
if grep -F 'send-keys -t "$pane"' "$HANDOFF" | grep -Eq -- '-l.*Enter|Enter.*-l'; then
  echo "FAIL - a pane send-keys call combines -l and Enter on one line"
  fail=1
else
  echo "ok   - no pane send-keys call combines -l and Enter on one line"
fi

# resend-Enter guard: at least two Enter sends follow the payload injection.
enter_after_payload="$(awk '/-l "\$payload"/{f=1} f && /send-keys -t "\$pane" Enter/{c++} END{print c+0}' "$HANDOFF")"
if [ "$enter_after_payload" -ge 2 ]; then
  echo "ok   - pane injection resends Enter after a pause (dropped-first-Enter guard)"
else
  echo "FAIL - expected >=2 Enter sends after pane payload injection (got $enter_after_payload)"
  fail=1
fi

# R7 regression: no send-keys line in the pane branch (or anywhere) sends /model.
if grep -F 'send-keys' "$HANDOFF" | grep -qF '/model'; then
  echo "FAIL - R7: a send-keys line in handoff.sh embeds the literal string /model"
  fail=1
else
  echo "ok   - R7: no send-keys call in handoff.sh embeds the literal string /model"
fi

# KTD6: the split direction lives in exactly one env-overridable constant.
const_count="$(grep -cF 'HANDOFF_PANE_SPLIT="${HANDOFF_PANE_SPLIT:--h}"' "$HANDOFF")"
assert_eq "split direction is a single flippable constant (defined once)" "1" "$const_count"

echo
[ "$fail" -eq 0 ] && echo "ALL PASS" || echo "FAILURES"
exit "$fail"
