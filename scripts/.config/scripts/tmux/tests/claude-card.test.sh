#!/usr/bin/env bash
# Tests for claude-card.sh (the reply-log session context card). Each case
# builds a throwaway ~/.claude-like tree (replies, session registry, projects,
# status-line cache) from tests/fixtures/reply-log/card/ and checks the card's
# plain text. A live registry entry points at a `sleep` this test starts, so
# the pid + start-time check runs for real. tmux is cut off (no TMUX, private
# TMUX_TMPDIR) so nothing reads Jet's server.
#
# Run: bash scripts/.config/scripts/tmux/tests/claude-card.test.sh
set -uo pipefail
export LC_ALL=C.UTF-8   # character counts and regexes over "─"

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CARD="$HERE/../claude-card.sh"
FX="$HERE/fixtures/reply-log/card"
ROOT="$(mktemp -d -t claude-card.XXXXXX)"
sleep 300 & LIVE=$!
trap 'kill "$LIVE" 2>/dev/null; rm -rf "$ROOT"' EXIT

fail=0
assert() { # <desc> <expected-regex> <actual>
  if printf '%s' "$3" | grep -qE -- "$2"; then echo "ok   - $1"
  else echo "FAIL - $1"; echo "       expected match: $2"; echo "       got: $3" | head -40; fail=1; fi
}
refute() { # <desc> <unexpected-regex> <actual>
  if printf '%s' "$3" | grep -qE -- "$2"; then echo "FAIL - $1"; echo "       unexpected match: $2"; echo "       got: $3" | head -40; fail=1
  else echo "ok   - $1"; fi
}
plain() { sed 's/\x1b\[[0-9;]*m//g'; }
eq() { # <desc> <expected> <actual> — exact text
  if [ "$3" == "$2" ]; then echo "ok   - $1"
  else echo "FAIL - $1"; printf '       expected: %s\n       got:      %s\n' "${2//$'\n'/⏎}" "${3//$'\n'/⏎}"; fail=1; fi
}
# sect <label> — the non-blank lines of the card section headed "── <label>"
sect() { awk -v l="── $1" 'index($0, l) == 1 { on = 1; next } /^── / { on = 0 } on && NF' <<<"$out"; }

now=$(date +%s)
start_of() { local s; s="$(cat "/proc/$1/stat")"; s="${s##*) }"; set -- $s; printf '%s' "${20}"; }

# setup <case> — a fresh tree under $ROOT/<case>; sets D
setup() {
  D="$ROOT/$1"
  mkdir -p "$D/replies" "$D/sessions" "$D/projects/-work-demo" "$D/cache" "$D/tmux"
}
# reply <fixture> <sid> [task] — install a reply-file fixture as <sid>'s
reply() {
  sed -e "s|SID|$2|g" -e "s|^task: TASK$|task: ${3:-}|" "$FX/$1" >"$D/replies/$2.md"
}
# registry <pid> <sid> <pane> <status> <statusUpdatedAt epoch s>
registry() {
  local ps; ps="$(start_of "$1" 2>/dev/null || echo 0)"
  printf '{"pid":%s,"sessionId":"%s","procStart":"%s","tmux":"demo:@1.%s","status":"%s","statusUpdatedAt":%s,"updatedAt":%s}\n' \
    "$1" "$2" "$ps" "$3" "$4" "$(($5 * 1000))" "$(($5 * 1000))" >"$D/sessions/$1.json"
}
transcript() { # <fixture> <sid> <mtime epoch>
  cp "$FX/$1" "$D/projects/-work-demo/$2.jsonl"
  touch -d "@$3" "$D/projects/-work-demo/$2.jsonl"
}
card() { # <arg> [width] — the card's plain text
  env -u TMUX -u TMUX_PANE TMUX_TMPDIR="$D/tmux" REPLY_LOG_DIR="$D/replies" CLAUDE_SESSIONS_DIR="$D/sessions" \
    CLAUDE_PROJECTS_DIR="$D/projects" CLAUDE_STATUS_CACHE_DIR="$D/cache" FZF_PREVIEW_COLUMNS="${2:-100}" \
    bash "$CARD" "$1" 2>&1 | plain
}

echo "# live pane: every section"
setup live
cp "$FX/task.md" "$D/task.md"
reply needs.md sess-a "$D/task.md"
registry "$LIVE" sess-a %901 idle $((now - 90))
transcript recap-auto.jsonl sess-a $((now - 200))
printf '{"session_id":"sess-a","model":"Opus 5.5","cost_usd":1.25,"context_pct":34,"ts":%s}\n' $((now - 150)) >"$D/cache/sess-a.json"
out="$(card %901)"
assert "state: idle with its age" '^idle 1m' "$out"
assert "state line: model, context %, cost and the cache's age" 'Opus 5\.5 · 34% ctx · \$1\.25 · as of 2m' "$out"
assert "task named" 'task: task$' "$out"
assert "recap shown with its age" '── Recap · [0-9]+d ago' "$out"
assert "recap text, without the config hint" '^You are wiring the parser into the CLI\. Next: pick a flag name\.$' "$out"
assert "last prompt, with its time" '── You asked · 10:30' "$out"
eq "last prompt: every line, unquoted, then the one before" $'Now wire it into the CLI and tell me what\'s left\nKeep the flags short.\nbefore that: Set up the widget parser' "$(sect 'You asked')"
assert "reply excerpt: headings unmarked, in order" '^The CLI calls the parser$' "$(sect 'Claude replied' | head -1)"
eq "Needs you section, stopping at the next heading" $'- Pick the flag name: `-w` or `-p`?\n- Approve deleting the old path.' "$(sect 'Needs you')"
refute "no possibly-open list beside Needs you" 'Possibly open' "$out"
eq "artifacts: unique, newest use last" $'- https://claude.ai/artifact/AAAA1111\n- edited: /work/demo/cli.sh\n- wrote: /work/demo/parser.sh' "$(sect Artifacts)"
assert "decisions: the last three titles" '^- 2026-10-19 — Second decision ?- 2026-10-20 — Third decision ?- 2026-10-21 — Fourth' "$(sect Decisions | tr '\n' ' ')"
refute "decisions: nothing from other sections" 'First decision|Not a decision' "$out"
printf '{"session_id":"sess-a","model":"Opus 5.5","cost_usd":1.25,"context_pct":null,"ts":%s}\n' $((now - 150)) >"$D/cache/sess-a.json"
nullctx="$(card %901)"
assert "a null field in the cache: the others still show" 'Opus 5\.5 · \$1\.25 · as of 2m' "$nullctx"
refute "a null context %: no ctx figure" 'ctx' "$nullctx"
printf '{"session_id":"sess-a","model":"Opus 5.5","cost_usd":1.25,"context_pct":34,"ts":%s}\n' $((now - 150)) >"$D/cache/sess-a.json"

echo "# the same card by session id"
out="$(card sess-a)"
assert "session id input: same state line" '^idle 1m' "$out"

echo "# width"
out="$(card %901 60)"
# prose (prompt, reply, recap) is left for the preview to wrap; the rest is cut
long="$(while IFS= read -r l; do case "$l" in "── "*|"- "*|task:*|"before that:"*) [ "${#l}" -gt 60 ] && printf '%s\n' "$l" ;; esac; done <<<"$out")"
eq "60 columns: no rule, list or one-line field is wider" '' "$long"
assert "60 columns: long decision title cut with an ellipsis" '^- 2026-10-21 — Fourth decision with a long title that runs…$' "$out"
out="$(card %901 100)"
assert "100 columns: rules fill the width" '^── Decisions ─{87}$' "$out"

echo "# recap variants"
transcript recap-stale.jsonl sess-a $((now - 200))
out="$(card %901)"
refute "a recap older than the last prompt is left out" 'Recap|An old recap' "$out"
transcript recap-manual.jsonl sess-a $((now - 200))
out="$(card %901)"
eq "a manual /recap is shown, past a later /model" 'Goal: a manual recap.' "$(sect Recap)"
refute "another local command's output is not a recap" 'Set model to Haiku' "$out"

echo "# dead pid"
setup dead
reply needs.md sess-d
registry 999999999 sess-d %902 busy "$now"
out="$(card sess-d)"
assert "a registry entry whose pid is gone: state unknown" '^state unknown' "$out"
assert "the rest of the card still renders" 'Needs you' "$out"
registry "$LIVE" sess-d %902 busy "$now"
sed -i 's/"procStart":"[0-9]*"/"procStart":"1"/' "$D/sessions/$LIVE.json"
out="$(card sess-d)"
assert "a live pid with another start time (reused pid): state unknown" '^state unknown' "$out"

echo "# busy vs quiet"
setup quiet
reply plain.md sess-q
registry "$LIVE" sess-q %903 busy $((now - 660))
transcript recap-stale.jsonl sess-q $((now - 660))
out="$(card %903)"
assert "busy, nothing changed for 11 minutes: quiet 11m" '^quiet 11m' "$out"
registry "$LIVE" sess-q %903 busy $((now - 540))
out="$(card %903)"
assert "busy, last change 9 minutes ago: busy" '^busy 9m' "$out"
registry "$LIVE" sess-q %903 busy $((now - 900))
transcript recap-stale.jsonl sess-q $((now - 30))
out="$(card %903)"
assert "a recent transcript write keeps it busy" '^busy <1m' "$out"

echo "# shell status, no cache, no task"
registry "$LIVE" sess-q %903 shell "$now"
out="$(card %903)"
assert "status shell (a live Claude running a command): running a command" '^running a command <1m' "$out"
refute "no statusline cache: no model/context/cost line" 'ctx|as of|\$' "$out"
refute "no task: no task line or decisions" 'task:|Decisions' "$out"
transcript recap-stale.jsonl sess-q $((now - 660))
registry "$LIVE" sess-q %903 shell $((now - 660))
assert "a command with nothing changed for 11 minutes: quiet 11m" '^quiet 11m \(running a command, no activity\)' "$(card %903)"
registry "$LIVE" sess-q %903 shell "$now"

echo "# open-question rules"
assert "plain reply: possibly-open list" '── Possibly open' "$out"
eq "plain reply: up to five ? lines; heading, italic and code lines skipped" $'The build passes. Want me to push it?\nShall I also tag a release?\nOr open the PR now?\nQ3?\nQ4?' "$(sect 'Possibly open')"
setup points
reply points.md sess-p
registry "$LIVE" sess-p %904 waiting "$now"
out="$(card %904)"
assert "waiting status" '^waiting on you <1m' "$out"
eq "heading-per-point layout: no open questions" 'no open questions' "$(sect 'Open questions')"
refute "heading-per-point layout: no possibly-open list" 'Possibly open' "$out"

echo "# task file without decisions"
setup nodec
printf -- '---\nstatus: doing\n---\n# T\n\n## Plan\n### step\n' >"$D/task.md"
reply needs.md sess-n "$D/task.md"
registry "$LIVE" sess-n %905 idle "$now"
out="$(card %905)"
refute "no ## Decisions: no decisions block" 'Decisions|step' "$out"
printf -- '---\nstatus: doing\n---\n# T\n\n## Decisions\n\n- 2026-10-01 — **Old bullet**\n### 2026-10-02 — A titled entry\n- an undated body bullet\n- **2026-10-03** — Bold-dated bullet\n- 2026-10-04 — Newest bullet\n' >"$D/task.md"
eq "dated bullets count as decisions, in file order; undated bullets don't" \
  $'- 2026-10-02 — A titled entry\n- 2026-10-03 — Bold-dated bullet\n- 2026-10-04 — Newest bullet' \
  "$(out="$(card %905)"; sect Decisions)"

echo "# live session without its own reply file"
setup borrow
cp "$FX/task.md" "$D/task.md"
reply needs.md sess-prev "$D/task.md"
touch -d "@$((now - 7200))" "$D/replies/sess-prev.md"
registry "$LIVE" sess-new %906 idle "$now"
# the pane's @task, through a stub tmux (the session itself has no reply file yet)
mkdir -p "$D/bin"; printf '#!/bin/sh\necho %s\n' "$D/task.md" >"$D/bin/tmux"; chmod +x "$D/bin/tmux"
out="$(PATH="$D/bin:$PATH" card %906)"
assert "after /clear: the task's newest exchange, marked as borrowed" '── You asked[^⏎]*⏎from an earlier session on this task · 2h ago' "${out//$'\n'/⏎}"
assert "after /clear: the borrowed exchange's content" 'Needs you' "$out"
refute "a session's own file is not marked" 'earlier session' "$(D="$ROOT/live"; card sess-a)"
setup nolog
registry "$LIVE" sess-z %907 busy "$now"
env -u TMUX -u TMUX_PANE TMUX_TMPDIR="$D/tmux" REPLY_LOG_DIR="$D/replies" CLAUDE_SESSIONS_DIR="$D/sessions" \
  CLAUDE_PROJECTS_DIR="$D/projects" CLAUDE_STATUS_CACHE_DIR="$D/cache" bash "$CARD" %907 >/dev/null 2>&1
eq "a live session with no logged turns: exit 3, so the picker adds the pane's screen" 3 "$?"
assert "a live session with no logged turns: state, then 'no turns logged yet'" '^busy <1m.*⏎⏎no turns logged yet$' "$(card %907 | sed ':a;N;$!ba;s/\n/⏎/g')"

echo "# empty replies folder"
setup emptyreplies
cp "$FX/task.md" "$D/task.md"
eq "a task with no reply folder content: nothing, not an awk error" '' "$(card "$D/task.md")"

echo "# dormant task"
setup dormant
cp "$FX/task.md" "$D/task.md"
reply needs.md sess-old "$D/task.md"
touch -d "@$((now - 7200))" "$D/replies/sess-old.md"
out="$(card "$D/task.md")"
assert "dormant: state line with the last turn's age" '^dormant · last turn 2h ago' "$out"
assert "dormant: built from the reply file" 'Needs you' "$out"
refute "dormant: no live-only sections" 'Recap|as of' "$out"
cp "$FX/task.md" "$D/other-task.md"
out="$(card "$D/other-task.md")"
eq "dormant, no reply files: nothing (the picker shows the task file)" '' "$out"

echo "# no Claude session"
setup none
out="$(card %999)"
eq "a pane with no Claude session prints nothing" '' "$out"
out="$(card not/a/file.md)"
eq "a missing task file prints nothing" '' "$out"
out="$(card "$ROOT")"
eq "a directory (a repo row's {9}) prints nothing" '' "$out"

echo "# speed"
D="$ROOT/live"
t0=$(date +%s%N)
for _ in 1 2 3 4 5; do card %901 >/dev/null; done
ms=$(( ($(date +%s%N) - t0) / 5000000 ))
if [ "$ms" -lt 150 ]; then echo "ok   - renders in ${ms} ms (< 150)"; else echo "FAIL - renders in ${ms} ms (>= 150)"; fail=1; fi

[ "$fail" = 0 ] && echo "ALL PASSED"
exit "$fail"
