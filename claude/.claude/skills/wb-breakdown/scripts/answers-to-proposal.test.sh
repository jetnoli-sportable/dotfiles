#!/usr/bin/env bash
# Tests for answers-to-proposal.sh (R25): a /decide page's answers become the
# exact proposal `wb breakdown --apply` reads.
# Run: bash claude/.claude/skills/wb-breakdown/scripts/answers-to-proposal.test.sh
# shellcheck disable=SC2015,SC2016  # A && ok || bad is the test idiom; ok never fails
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../../../../.." && pwd)"
SCRIPT="$HERE/answers-to-proposal.sh"
FX="$HERE/fixtures"
WB="$REPO/scripts/.config/scripts/tmux/wb.sh"
T="$(mktemp -d -t a2p.XXXXXX)"
trap 'rm -rf "$T"' EXIT

fail=0
ok() { echo "ok   - $1"; }
bad() { echo "FAIL - $1"; [ -n "${2:-}" ] && echo "       $2"; fail=1; }
assert_eq() { [ "$2" = "$3" ] && ok "$1" || bad "$1" "expected '$2', got '$3'"; }
assert_match() { printf '%s' "$3" | grep -qE "$2" && ok "$1" || bad "$1" "expected match '$2' in: $3"; }

# --- 1. three children, one slug edited, one row skipped -> byte-exact proposal
out="$(bash "$SCRIPT" "$FX/spec.json" "$FX/answers.json" "$FX/parent.md" "$T/p1.md" 2>&1)"; rc=$?
assert_eq "convert exits 0" 0 "$rc"
if cmp -s "$T/p1.md" "$FX/expected-proposal.md"; then ok "proposal matches the expected fixture byte for byte"
else bad "proposal differs from fixture"; diff "$T/p1.md" "$FX/expected-proposal.md" | head -8; fi

# --- 2. wb breakdown --apply accepts it in a sandbox store
(
  CODE_DIR="$T/code"; TASKS_DIR="$T/tasks"; HOME="$T/home"
  mkdir -p "$CODE_DIR/proj" "$TASKS_DIR" "$HOME"
  git init -q "$CODE_DIR/proj"
  git -C "$CODE_DIR/proj" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
  printf -- '---\nstatus: planned\npath:\nrepo:\nbranch:\nworktree:\nparent:\ndepends_on:\nsize:\ntags: []\ncreated:\nclosed:\nreviewed:\n---\n# Title\n\n## Plan\n\n\n\n## Handoffs\n\n\n\n## Decisions\n\n\n\n## Done\n\n\n\n## Follow-ups\n' > "$TASKS_DIR/TEMPLATE.md"
  cp "$FX/parent.md" "$TASKS_DIR/proj--feat-big.md"
  export CODE_DIR TASKS_DIR HOME
  # shellcheck disable=SC1090
  source "$WB"
  set +e
  apply_out="$(cmd_breakdown --apply "$T/p1.md" 2>&1)"; apply_rc=$?
  { echo "$apply_rc"; echo "$apply_out"
    for s in feat-big-renamed feat-big-two feat-big-one feat-big-three; do
      [ -f "$TASKS_DIR/proj--$s.md" ] && echo "exists $s"; done; } > "$T/apply.txt"
)
apply="$(cat "$T/apply.txt")"
assert_eq "apply exits 0" 0 "$(head -1 "$T/apply.txt")"
assert_match "apply created the edited-slug child" '^exists feat-big-renamed$' "$apply"
assert_match "apply created the second child" '^exists feat-big-two$' "$apply"
if /usr/bin/grep -qE '^exists feat-big-(three|one)$' "$T/apply.txt"; then bad "apply created the skipped or unedited-slug child"; else ok "apply did not create the skipped or unedited-slug child"; fi

# --- 3. a changed parent checksum refuses, names the parent, writes nothing
cp "$FX/parent.md" "$T/parent-changed.md"; echo "- a new follow-up" >> "$T/parent-changed.md"
out="$(bash "$SCRIPT" "$FX/spec.json" "$FX/answers.json" "$T/parent-changed.md" "$T/p3.md" 2>&1)"; rc=$?
assert_eq "stale base exits non-zero" 1 "$rc"
assert_match "stale base names the parent" 'proj--feat-big changed since the page was published' "$out"
[ ! -e "$T/p3.md" ] && ok "stale base writes no proposal" || bad "stale base wrote a proposal"

# --- 4. a row asking for more information stops the conversion, names the row
jq '.answers.c2 = {choice:"", note:"what does this depend on?", fields:{}, fields_changed:false}' "$FX/answers.json" > "$T/a4.json"
out="$(bash "$SCRIPT" "$FX/spec.json" "$T/a4.json" "$FX/parent.md" "$T/p4.md" 2>&1)"; rc=$?
assert_eq "a note with no verdict exits non-zero" 1 "$rc"
assert_match "it names the row" 'row c2 \(Second slice\) asks for more information' "$out"
[ ! -e "$T/p4.md" ] && ok "no proposal written" || bad "proposal written despite a question"

# --- 5. accept box unticked: an untouched suggested row is carried over
jq 'del(.answers.c2)' "$FX/answers.json" > "$T/a5.json"
out="$(bash "$SCRIPT" "$FX/spec.json" "$T/a5.json" "$FX/parent.md" "$T/p5.md" 2>&1)"; rc=$?
assert_eq "unticked box converts" 0 "$rc"
assert_match "untouched row reported as carried over" 'carried over.*: c2' "$out"
assert_match "only one child created" '^created 1: feat-big-renamed$' "$out"
/usr/bin/grep -q 'feat-big-two' "$T/p5.md" && bad "carried row became a child" || ok "carried row is not in the proposal"
#     ... and ticked: the suggestion is taken
jq '.submitted.accept_remaining = true' "$T/a5.json" > "$T/a5b.json"
out="$(bash "$SCRIPT" "$FX/spec.json" "$T/a5b.json" "$FX/parent.md" "$T/p5b.md" 2>&1)"
assert_match "ticked box creates the suggested row" '^created 2: feat-big-renamed, feat-big-two$' "$out"

# --- 5c. a field edit with no verdict (an older page rev) is no verdict: carried, not taken
jq '.answers.c2 = {choice:"", note:"", fields:{slug:"feat-big-two-x"}, fields_changed:true}' "$FX/answers.json" > "$T/a5c.json"
out="$(bash "$SCRIPT" "$FX/spec.json" "$T/a5c.json" "$FX/parent.md" "$T/p5c.md" 2>&1)"; rc=$?
assert_eq "fields_changed with no choice converts" 0 "$rc"
assert_match "that row is carried over, not created" 'carried over.*: c2' "$out"
/usr/bin/grep -q 'feat-big-two-x' "$T/p5c.md" && bad "an edit with no verdict became a child" || ok "an edit with no verdict is not in the proposal"

# --- 6. merge folds the plan into the child named in the note; continuing child migrates
jq '.answers.c3 = {choice:"merge", note:"fold into `feat-big-renamed`", fields:{}, fields_changed:false}' "$FX/answers.json" > "$T/a6.json"
jq '.breakdown.continuing = "c1"' "$FX/spec.json" > "$T/s6.json"
out="$(bash "$SCRIPT" "$T/s6.json" "$T/a6.json" "$FX/parent.md" "$T/p6.md" 2>&1)"; rc=$?
assert_eq "merge converts" 0 "$rc"
assert_match "merged plan body lands in the target child" 'plan body for child three' "$(sed -n '/begin-plan n=1/,/end-plan/p' "$T/p6.md")"
assert_match "continuing child gets the migration line with its edited slug" 'migrate branch/worktree .* continuing child: `feat-big-renamed`' "$(cat "$T/p6.md")"
jq '.answers.c3 = {choice:"merge", note:"", fields:{}, fields_changed:false}' "$FX/answers.json" > "$T/a6b.json"
out="$(bash "$SCRIPT" "$FX/spec.json" "$T/a6b.json" "$FX/parent.md" "$T/p6b.md" 2>&1)"; rc=$?
assert_eq "merge with no target named refuses" 1 "$rc"

exit "$fail"
