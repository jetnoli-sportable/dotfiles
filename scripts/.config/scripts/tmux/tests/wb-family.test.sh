#!/usr/bin/env bash
# Tests for `wb family` (cmd_family): the family enumeration (U1), the
# --sessions live-session scan, and --reseed (U2). Same fixture convention as
# tasks-concepts-seed.test.sh (mk_task fixtures, source wb.sh, a stub tmux on
# ONE fixed private -L socket started with -f /dev/null — never a shim that
# spawns per-exec sockets or runs tmux.conf). Everything is written under
# mktemp dirs.
#
# Run: bash scripts/.config/scripts/tmux/tests/wb-family.test.sh
set -uo pipefail

WB="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/wb.sh"
FIXTURE_CODE="$(mktemp -d -t wb-family-code.XXXXXX)"
FIXTURE_TASKS="$(mktemp -d -t wb-family-tasks.XXXXXX)"
FIXTURE_BIN="$(mktemp -d -t wb-family-bin.XXXXXX)"
FIXTURE_PROJECTS="$(mktemp -d -t wb-family-projects.XXXXXX)"
FIXTURE_SESSIONS="$(mktemp -d -t wb-family-sessions.XXXXXX)"
TMUX_LOG="$FIXTURE_BIN/tmux.log"
SOCK="wb-family-sock-$$"
REAL_TMUX="$(command -v tmux)"

# One fixed socket, no tmux.conf; every call is logged so the read-only
# tests can assert tmux was never touched.
cat > "$FIXTURE_BIN/tmux" <<SHIM
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$TMUX_LOG"
exec "$REAL_TMUX" -f /dev/null -L "$SOCK" "\$@"
SHIM
chmod +x "$FIXTURE_BIN/tmux"
PATH="$FIXTURE_BIN:$PATH"

cleanup() {
  "$REAL_TMUX" -L "$SOCK" kill-server 2>/dev/null || true
  chmod -R u+w "$FIXTURE_CODE" 2>/dev/null || true
  rm -rf "$FIXTURE_CODE" "$FIXTURE_TASKS" "$FIXTURE_BIN" "$FIXTURE_PROJECTS" "$FIXTURE_SESSIONS"
}
trap cleanup EXIT

fail=0
assert() { # <desc> <expected-regex> <actual>
  if printf '%s' "$3" | /usr/bin/grep -qE "$2"; then
    echo "ok   - $1"
  else
    echo "FAIL - $1"
    echo "       expected match: $2"
    echo "       got: $(printf '%s' "$3" | head -8)"
    fail=1
  fi
}
assert_eq() { # <desc> <expected> <actual>
  if [ "$2" = "$3" ]; then
    echo "ok   - $1"
  else
    echo "FAIL - $1 (expected '$2', got '$3')"
    fail=1
  fi
}
assert_file_missing() { # <desc> <path>
  if [ -e "$2" ]; then
    echo "FAIL - $1 (expected no file at $2)"
    fail=1
  else
    echo "ok   - $1"
  fi
}

mkdir -p "$FIXTURE_CODE/proj"

mk_task() { # <stem> <parent_ref> [<worktree>]
  printf -- '---\nstatus: doing\nrepo: proj\nbranch: %s\nworktree: %s\nparent: %s\ntags: []\ncreated: 2026-10-24\nclosed:\n---\n# Title of %s\n' \
    "${1#proj--}" "${3:-}" "$2" "$1" > "$FIXTURE_TASKS/$1.md"
}
mk_dossier() { # <stem>
  mkdir -p "$FIXTURE_TASKS/dossiers/$1"
  printf '# %s CONCEPTS\n\nsettled fact.\n' "$1" > "$FIXTURE_TASKS/dossiers/$1/CONCEPTS.md"
}

# umbrella -> child -> grandchild, umbrella -> sibling -> cousin
mk_task proj--umbrella ""             .worktrees/umbrella
mk_task proj--child proj--umbrella    .worktrees/child
mk_task proj--grandchild proj--child  .worktrees/grandchild
mk_task proj--sibling proj--umbrella  .worktrees/sibling
mk_task proj--cousin proj--sibling    .worktrees/cousin
mk_task proj--outsider ""             .worktrees/outsider
# lone task, no parent, no children
mk_task proj--lone ""
# cycles and self-parent
mk_task proj--cyclea proj--cycleb
mk_task proj--cycleb proj--cyclea
mk_task proj--selfp proj--selfp
# parent file does not exist
mk_task proj--orphan proj--gone
# prefix-substring stems
mk_task proj--foo ""
mk_task proj--foo-bar ""
mk_task proj--ambig-one ""
mk_task proj--ambig-two ""

export CODE_DIR="$FIXTURE_CODE"
export TASKS_DIR="$FIXTURE_TASKS"
export CLAUDE_PROJECTS_DIR="$FIXTURE_PROJECTS"
# Never the real registry: its live pids and pane ids would match this socket's.
export CLAUDE_SESSIONS_DIR="$FIXTURE_SESSIONS"

# shellcheck disable=SC1090
source "$WB"
set +e   # wb.sh sets -e; this test intentionally captures non-zero exits

fam() { # <args...> — run cmd_family in a subshell (it may exit), stdout only
  ( cmd_family "$@" ) 2>/dev/null
}
sorted() { printf '%s\n' "$1" | sort; }

# ============================================================================
# U1: enumeration
# ============================================================================
: > "$TMUX_LOG"

out="$(fam proj--grandchild)"
assert_eq "grandchild: umbrella is printed first" "proj--umbrella" "$(printf '%s\n' "$out" | head -1)"
assert_eq "grandchild: the five family stems, each once" \
  "$(sorted 'proj--child
proj--cousin
proj--grandchild
proj--sibling
proj--umbrella')" "$(sorted "$out")"
assert_eq "grandchild: depth-first, child's subtree before sibling's" \
  "proj--umbrella
proj--child
proj--grandchild
proj--sibling
proj--cousin" "$out"

out2="$(fam proj--umbrella)"
assert_eq "umbrella: same family as from the grandchild" "$out" "$out2"

out="$(fam proj--lone; echo "rc=$?")"
assert_eq "no parent, no children: only itself, exit 0" "proj--lone
rc=0" "$out"

out="$(timeout 5 bash -c 'source "'"$WB"'" >/dev/null 2>&1; cmd_family proj--cyclea 2>/dev/null'; echo "rc=$?")"
assert "mutual cycle: terminates" "rc=0" "$out"
assert_eq "mutual cycle: each stem once" "proj--cyclea
proj--cycleb" "$(sorted "$(printf '%s\n' "$out" | /usr/bin/grep -v '^rc=')")"

assert_eq "self-parent: itself once" "proj--selfp" "$(fam proj--selfp)"
assert_eq "missing parent file: the last existing stem is the root" "proj--orphan" "$(fam proj--orphan)"

assert_eq "exact stem resolves despite a longer sibling stem" "proj--foo" "$(fam proj--foo)"
out="$( ( cmd_family ambig ) 2>&1 >/dev/null; echo "rc=$?")"
assert "ambiguous fuzzy query: exit 1, candidates on stderr" "proj--ambig-one" "$out"
assert "ambiguous fuzzy query: exit 1" "rc=1" "$out"
out="$( ( cmd_family nosuchtask ) 2>/dev/null; echo "rc=$?")"
assert_eq "unknown task: exit 1, nothing on stdout" "rc=1" "$out"

assert_eq "without --sessions, tmux is never called" "0" "$(wc -l < "$TMUX_LOG" | tr -d ' ')"

# ============================================================================
# U1: --sessions
# ============================================================================
tmux new-session -d -s proj--child
tmux set-option -t "=proj--child:" @task "$FIXTURE_TASKS/proj--child.md"
# migrated-breakdown case (AE2): parent's name, @task on the grandchild
tmux new-session -d -s proj--umbrella
tmux set-option -t "=proj--umbrella:" @task "$FIXTURE_TASKS/proj--grandchild.md"
tmux new-session -d -s proj--outsider
tmux set-option -t "=proj--outsider:" @task "$FIXTURE_TASKS/proj--outsider.md"

out="$(fam proj--umbrella --sessions)"
assert_eq "--sessions: two lines (outsider excluded)" "2" "$(printf '%s\n' "$out" | wc -l | tr -d ' ')"
assert_eq "--sessions: @task-matched session, with its title and no Claude" \
  "proj--child	proj--child	Title of proj--child	" "$(printf '%s\n' "$out" | /usr/bin/grep '^proj--child	')"
assert_eq "--sessions: migrated session reported under the grandchild (AE2)" \
  "proj--grandchild	proj--umbrella	Title of proj--grandchild	" "$(printf '%s\n' "$out" | /usr/bin/grep '^proj--grandchild	')"
assert_eq "--sessions: nothing reported under the umbrella's stem" "0" \
  "$(printf '%s\n' "$out" | /usr/bin/grep -c '^proj--umbrella	')"

# @task unset: the session name is the fallback
tmux new-session -d -s proj--cousin
out="$(fam proj--umbrella --sessions)"
assert_eq "--sessions: session name matches when @task is unset" \
  "proj--cousin	proj--cousin	Title of proj--cousin	" "$(printf '%s\n' "$out" | /usr/bin/grep '^proj--cousin	')"
tmux kill-session -t "=proj--cousin"

# 4th column: the SendMessage name from Claude Code's session registry, joined
# on the pane id. Registry files are one line of JSON with no trailing newline.
mk_reg() { # <file-stem> <pid> <tmux binding> <name>
  printf '{"pid":%s,"sessionId":"s-%s","tmux":"%s","name":"%s","status":"idle"}' \
    "$2" "$1" "$3" "$4" > "$FIXTURE_SESSIONS/$1.json"
}
pane_of() { tmux list-panes -s -t "=$1" -F '#{pane_id}' | head -1; }
sleep 0 & dead_pid=$!; wait "$dead_pid"

long="proj--sibling-with-a-session-name-long-enough-to-lose-its-listagents-field"
tmux new-session -d -s "$long"
tmux set-option -t "=$long:" @task "$FIXTURE_TASKS/proj--sibling.md"
mk_reg 101 "$$" "$long:@1.$(pane_of "$long")" sibling-claude
# child: a dead entry, plus a live one written under the session's old name
mk_reg 102 "$dead_pid" "proj--child:@2.$(pane_of proj--child)" child-dead
mk_reg 103 "$$" "proj--old-name:@2.$(pane_of proj--child)" child-claude
# the umbrella session (working on the grandchild) holds two Claudes
tmux split-window -d -t "=proj--umbrella:"
mk_reg 104 "$$" "proj--umbrella:@3.$(tmux list-panes -s -t =proj--umbrella -F '#{pane_id}' | sed -n 1p)" gc-one
mk_reg 105 "$$" "proj--umbrella:@3.$(tmux list-panes -s -t =proj--umbrella -F '#{pane_id}' | sed -n 2p)" gc-two
mk_reg 106 "$$" "proj--outsider:@4.$(pane_of proj--outsider)" outsider-claude
# a half-written file that sorts before every other one
printf '{"pid":%s,"tmux":"proj--child:@2.' "$$" > "$FIXTURE_SESSIONS/100.json"

out="$(fam proj--umbrella --sessions)"
assert_eq "--sessions: a long session name still gets its Claude's name" \
  "proj--sibling	$long	Title of proj--sibling	sibling-claude" \
  "$(printf '%s\n' "$out" | /usr/bin/grep '^proj--sibling	')"
assert_eq "--sessions: dead pid skipped; a renamed session still matches by pane" \
  "proj--child	proj--child	Title of proj--child	child-claude" \
  "$(printf '%s\n' "$out" | /usr/bin/grep '^proj--child	')"
assert_eq "--sessions: two Claudes in one session give two lines" \
  "proj--grandchild	proj--umbrella	Title of proj--grandchild	gc-one
proj--grandchild	proj--umbrella	Title of proj--grandchild	gc-two" \
  "$(printf '%s\n' "$out" | /usr/bin/grep '^proj--grandchild	' | sort)"
assert_eq "--sessions: a non-family Claude never appears" "0" \
  "$(printf '%s\n' "$out" | /usr/bin/grep -c 'outsider-claude')"
tmux kill-session -t "=$long"
tmux kill-session -t "=proj--outsider"
tmux kill-session -t "=proj--umbrella"
tmux kill-session -t "=proj--child"

# ============================================================================
# U2: --reseed
# ============================================================================
: > "$TMUX_LOG"
for d in umbrella child grandchild sibling; do mkdir -p "$FIXTURE_CODE/proj/.worktrees/$d"; done
# cousin's worktree dir deliberately absent
printf 'hand written\n' > "$FIXTURE_CODE/proj/.worktrees/child/CLAUDE.local.md"

out="$(fam proj--lone --reseed; echo "rc=$?")"
assert "no worktree: field: skipped, exit 0" "skipped proj--lone .*
rc=0" "$out"

out="$(fam proj--grandchild --reseed; echo "rc=$?")"
assert "no CONCEPTS.md anywhere: every member skipped (no concepts file), exit 0" "rc=0" "$out"
assert_eq "no CONCEPTS.md anywhere: five skipped lines" "5" \
  "$(printf '%s\n' "$out" | /usr/bin/grep -c '^skipped .*(no concepts file)')"
assert_file_missing "no CONCEPTS.md anywhere: nothing written" "$FIXTURE_CODE/proj/.worktrees/umbrella/CLAUDE.local.md"

mk_dossier proj--umbrella
mk_task proj--nowt proj--umbrella
out="$(fam proj--grandchild --reseed; echo "rc=$?")"
assert "reseed: exit 0" "rc=0" "$out"
for d in umbrella child grandchild sibling; do
  assert "reseed: $d worktree gets the managed block" \
    "@$FIXTURE_TASKS/dossiers/proj--umbrella/CONCEPTS.md" "$(cat "$FIXTURE_CODE/proj/.worktrees/$d/CLAUDE.local.md" 2>/dev/null)"
  assert "reseed: $d reported" "reseeded proj--$d $FIXTURE_CODE/proj/.worktrees/$d" "$out"
done
assert "reseed: hand-written line outside the block survives" "hand written" \
  "$(cat "$FIXTURE_CODE/proj/.worktrees/child/CLAUDE.local.md")"
assert "reseed: missing worktree dir is skipped" "skipped proj--cousin" "$out"
assert "reseed: member with no worktree: field is skipped" "skipped proj--nowt \(no worktree" "$out"
assert_file_missing "reseed: missing dir not created" "$FIXTURE_CODE/proj/.worktrees/cousin"
assert_eq "reseed: tmux never called" "0" "$(wc -l < "$TMUX_LOG" | tr -d ' ')"

# unsafe worktree: value
mk_task proj--esc proj--umbrella ../escape
mkdir -p "$FIXTURE_CODE/escape"
out="$(fam proj--umbrella --reseed; echo "rc=$?")"
assert "unsafe worktree: skipped" "skipped proj--esc " "$out"
assert "unsafe worktree: exit 0" "rc=0" "$out"
assert_file_missing "unsafe worktree: nothing written outside the fixture" "$FIXTURE_CODE/escape/CLAUDE.local.md"
assert_file_missing "unsafe worktree: nothing written at the repo's parent" "$FIXTURE_CODE/proj/../escape/CLAUDE.local.md"
rm -f "$FIXTURE_TASKS/proj--esc.md" "$FIXTURE_TASKS/proj--nowt.md"

# an unwritable worktree fails its seed; the others are still seeded
rm -f "$FIXTURE_CODE/proj/.worktrees/sibling/CLAUDE.local.md" "$FIXTURE_CODE/proj/.worktrees/grandchild/CLAUDE.local.md"
if [ "$(id -u)" = 0 ]; then
  echo "skip - unwritable-directory scenario needs a non-root user"
else
  chmod 555 "$FIXTURE_CODE/proj/.worktrees/grandchild"
  out="$(fam proj--umbrella --reseed; echo "rc=$?")"
  chmod 755 "$FIXTURE_CODE/proj/.worktrees/grandchild"
  assert "unwritable worktree: non-zero exit" "rc=[1-9]" "$out"
  assert "unwritable worktree: failure reported" "failed proj--grandchild" "$out"
  assert "unwritable worktree: sibling still seeded" "@$FIXTURE_TASKS/dossiers/proj--umbrella/CONCEPTS.md" \
    "$(cat "$FIXTURE_CODE/proj/.worktrees/sibling/CLAUDE.local.md" 2>/dev/null)"
fi

# ============================================================================
# --concepts: the promotion target walk (_wb_concepts_paths), nearest first
# ============================================================================
: > "$TMUX_LOG"
out="$(fam proj--grandchild --concepts)"
assert_eq "concepts: only the umbrella's file" "$FIXTURE_TASKS/dossiers/proj--umbrella/CONCEPTS.md" "$out"
mk_dossier proj--child
out="$(fam proj--grandchild --concepts)"
assert_eq "concepts: nearest first" \
  "$FIXTURE_TASKS/dossiers/proj--child/CONCEPTS.md
$FIXTURE_TASKS/dossiers/proj--umbrella/CONCEPTS.md" "$out"
out="$(fam proj--cousin --concepts)"
assert_eq "concepts: a child-level file doesn't reach a cousin" \
  "$FIXTURE_TASKS/dossiers/proj--umbrella/CONCEPTS.md" "$out"
rm -rf "$FIXTURE_TASKS/dossiers/proj--child"
# a missing parent file stops the walk, even if that parent's dossier exists
mk_dossier proj--gone
out="$(fam proj--orphan --concepts; echo "rc=$?")"
assert_eq "concepts: missing parent file stops the walk" "rc=0" "$out"
rm -rf "$FIXTURE_TASKS/dossiers/proj--gone"
# a `parent:` line in the body is not the frontmatter parent
mk_task proj--bodyp ""
printf 'parent: proj--umbrella\n' >> "$FIXTURE_TASKS/proj--bodyp.md"
out="$(fam proj--bodyp --concepts; echo "rc=$?")"
assert_eq "concepts: a body parent: line is ignored" "rc=0" "$out"
rm -f "$FIXTURE_TASKS/proj--bodyp.md"
assert_eq "concepts: tmux never called" "0" "$(wc -l < "$TMUX_LOG" | tr -d ' ')"

# ============================================================================
# usage errors
# ============================================================================
out="$( (cmd_family proj--umbrella --bogus) 2>&1; echo "rc=$?")"
assert "usage: an unknown flag exits 1 with usage" "usage: wb family .*
rc=1" "$out"
out="$( (cmd_family proj--umbrella --sessions extra) 2>&1; echo "rc=$?")"
assert "usage: too many arguments exit 1 with usage" "usage: wb family .*
rc=1" "$out"
out="$( (cmd_family) 2>&1; echo "rc=$?")"
assert "usage: no task exits 1 with usage" "usage: wb family .*
rc=1" "$out"

# ============================================================================
# wb help lists the verb (also covered by wb-help.test.sh)
# ============================================================================
out="$(bash "$WB" help 2>/dev/null)"
assert "wb help lists wb family" "wb family" "$out"

[ "$fail" -eq 0 ] && echo "ALL PASS" || echo "FAILURES"
exit "$fail"
