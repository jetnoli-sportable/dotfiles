#!/usr/bin/env bash
# Tests for `wb decide-spec-check` (wb-decide.sh): the /decide page spec rules
# of claude/.claude/skills/decide/references/page-spec.md, on the three shipped
# fixtures and on mutated copies of them.
#
# Run: bash scripts/.config/scripts/tmux/tests/wb-decide-spec.test.sh
set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WB="$SELF_DIR/wb.sh"
REPO_ROOT="$(cd "$SELF_DIR/../../../.." && pwd)"
FIXD="$REPO_ROOT/claude/.claude/skills/decide/fixtures"

FIX="$(mktemp -d -t wb-decide-spec-fixture.XXXXXX)"
trap 'rm -rf "$FIX"' EXIT
export HOME="$FIX/home" XDG_STATE_HOME="$FIX/state" CODE_DIR="$FIX/code" TASKS_DIR="$FIX/tasks"
mkdir -p "$HOME" "$XDG_STATE_HOME" "$CODE_DIR" "$TASKS_DIR"
unset TMUX TMUX_PANE

fail=0
assert() { # <desc> <expected-regex> <actual>
  if printf '%s' "$3" | grep -qE "$2"; then echo "ok   - $1"
  else echo "FAIL - $1"; echo "       expected match: $2"; echo "       got: $(printf '%s' "$3" | head -8)"; fail=1; fi
}
assert_eq() { # <desc> <expected> <actual>
  if [ "$2" = "$3" ]; then echo "ok   - $1"
  else echo "FAIL - $1 (expected '$2', got '$3')"; fail=1; fi
}

check() { bash "$WB" decide-spec-check "$@" 2>&1; }
# mutate <fixture> <jq filter> — write the changed copy and print its path.
mutate() {
  local out="$FIX/m$RANDOM.json"
  jq "$2" "$FIXD/$1.json" > "$out" || echo "mutate failed: $2" >&2
  printf '%s\n' "$out"
}

# The three shipped fixtures pass.
for f in items verdicts triage; do
  out="$(check "$FIXD/$f.json")"; rc=$?
  assert_eq "fixture $f: exit 0" 0 "$rc"
  assert "fixture $f: prints ok with a count" '^ok: [0-9]+ items$' "$out"
done
assert "items fixture count is the real item count" "^ok: $(jq '.items|length' "$FIXD/items.json") items\$" "$(check "$FIXD/items.json")"

# Failures, each naming the item.
m="$(mutate items 'del(.items[0].id)')"; out="$(check "$m")"; rc=$?
assert_eq "missing item id: exit 1" 1 "$rc"
assert "missing item id: names the item by position" 'item #1: .*id' "$out"

first="$(jq -r '.items[0].id' "$FIXD/items.json")"
m="$(mutate items '.items[1].id = .items[0].id')"; out="$(check "$m")"; rc=$?
assert_eq "duplicate id: exit 1" 1 "$rc"
assert "duplicate id: names the id" "item $first: .*not unique" "$out"

vfirst="$(jq -r '.items[0].id' "$FIXD/verdicts.json")"
m="$(mutate verdicts '.items[0].suggested = "nonsense"')"; out="$(check "$m")"; rc=$?
assert_eq "suggestion that is not a verdict: exit 1" 1 "$rc"
assert "suggestion that is not a verdict: names the item" "item $vfirst: .*suggested.*nonsense" "$out"

m="$(mutate items '.items[0].blocks = [{"type":"script","text":"alert(1)"}]')"; out="$(check "$m")"; rc=$?
assert_eq "unknown block type: exit 1" 1 "$rc"
assert "unknown block type: names the item and the type" "item $first: .*block type .script." "$out"

m="$(mutate items '.items[0].blocks = [{"type":"svg","svg":"<svg viewBox=\"0 0 1 1\" onload=\"x()\"></svg>"}]')"; out="$(check "$m")"; rc=$?
assert_eq "svg with onload: exit 1" 1 "$rc"
assert "svg with onload: names the item" "item $first: .*svg" "$out"
m="$(mutate items '.items[0].blocks = [{"type":"svg","svg":"<svg><foreignObject></foreignObject></svg>"}]')"; out="$(check "$m")"
assert "svg with foreignObject: rejected" "item $first: .*svg" "$out"
m="$(mutate items '.items[0].blocks = [{"type":"svg","svg":"<svg><script>1</script></svg>"}]')"; out="$(check "$m")"
assert "svg with script: rejected" "item $first: .*svg" "$out"
m="$(mutate items '.items[0].blocks = [{"type":"svg","svg":"<svg viewBox=\"0 0 1 1\"><circle r=\"1\"/></svg>"}]')"; out="$(check "$m")"; rc=$?
assert_eq "clean svg: passes" 0 "$rc"

m="$(mutate triage 'del(.items[0].options[] | select(.id=="defer"))')"; out="$(check "$m")"; rc=$?
assert_eq "triage without defer: exit 1" 1 "$rc"
assert "triage without defer: names the item and defer" "item t1: .*defer" "$out"
m="$(mutate triage '.items[0].options[0].recommended = false')"; out="$(check "$m")"
assert "triage without a recommended option: rejected" "item t1: .*recommended" "$out"
m="$(mutate triage '.items[0].options |= (.[2:4] + .[0:2])')"; out="$(check "$m")"
assert "triage with defer and skip not last: rejected" "item t1: .*last" "$out"

m="$(mutate verdicts 'del(.items[0].reason) | .items[0].suggested = .verdicts[0].id')"; out="$(check "$m")"; rc=$?
assert_eq "suggested without reason: exit 1" 1 "$rc"
assert "suggested without reason: names the item" "item $vfirst: .*reason" "$out"

m="$(mutate items '.items[0].options = [.items[0].options[0]]')"; out="$(check "$m")"
assert "items layout with one option: rejected" "item $first: .*two options" "$out"
m="$(mutate items 'del(.layout)')"; out="$(check "$m")"
assert "missing layout: rejected" 'layout' "$out"

# Every problem is printed, not just the first.
m="$(mutate items '.items[1].id = .items[0].id | .items[0].blocks = [{"type":"nope"}]')"; out="$(check "$m")"
assert_eq "several problems: one line each" 2 "$(printf '%s\n' "$out" | grep -c '^item ')"

# --previous: same id with changed options fails; a context-only change passes.
m="$(mutate items '.items[0].options[0].id = "changed"')"; out="$(check --previous "$FIXD/items.json" "$m")"; rc=$?
assert_eq "previous, options changed: exit 1" 1 "$rc"
assert "previous, options changed: names the item" "item $first: .*options" "$out"
m="$(mutate items '.items[0].title = "A different question"')"; out="$(check --previous "$FIXD/items.json" "$m")"; rc=$?
assert_eq "previous, question changed: exit 1" 1 "$rc"
assert "previous, question changed: names the item" "item $first: .*question" "$out"
m="$(mutate items '.items[0].context = "Only the evidence changed."')"; out="$(check --previous "$FIXD/items.json" "$m")"; rc=$?
assert_eq "previous, context-only change: exit 0" 0 "$rc"
m="$(mutate items '.items[0].id = "brand-new"')"; out="$(check --previous "$FIXD/items.json" "$m")"; rc=$?
assert_eq "previous, a renamed (new) id passes" 0 "$rc"
out="$(check "$FIXD/items.json" --previous "$FIXD/items.json")"; rc=$?
assert_eq "previous given after the spec: also accepted" 0 "$rc"

# A spec with an extra top-level `breakdown` object (/wb-breakdown's) passes:
# the page ignores keys it doesn't know.
m="$(mutate items '. + {breakdown: {parent: "x--y", repo: "x", continuing: false, plans: [], moves: []}}')"; out="$(check "$m")"; rc=$?
assert_eq "unknown top-level breakdown key: exit 0" 0 "$rc"
BD="$REPO_ROOT/claude/.claude/skills/wb-breakdown/scripts/fixtures/spec.json"
if [ -f "$BD" ]; then
  out="$(check "$BD")"; rc=$?
  assert_eq "wb-breakdown's own fixture spec: exit 0" 0 "$rc"
  assert "wb-breakdown's own fixture spec: ok" '^ok: ' "$out"
fi

# Usage and bad input.
out="$(check)"; rc=$?
assert_eq "no spec: exit 1" 1 "$rc"; assert "no spec: usage" 'usage: wb decide-spec-check' "$out"
printf 'not json' > "$FIX/bad.json"; out="$(check "$FIX/bad.json")"; rc=$?
assert_eq "invalid JSON: exit 1" 1 "$rc"; assert "invalid JSON: says so" 'not valid JSON' "$out"

[ "$fail" -eq 0 ] && echo "ALL PASS" || { echo "SOME FAILED"; exit 1; }
