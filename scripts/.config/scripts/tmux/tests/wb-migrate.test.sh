#!/usr/bin/env bash
# Tests for U11: `wb migrate <task>|--all [--dry-run]` (wb-migrate.sh) — the
# one-off conversion of an old-shape task file into the dossier layout.
# Covers the AE7 fixture (30 decisions in four styles, 40 handoffs, 12 open
# and 5 ticked follow-ups, ## Done, ## Plan) and every U11 scenario: the
# no-loss rule (a line fitting no style leaves the task unmigrated), prose
# supersede markers, the "before" counts coming from the raw text, held locks,
# no-time/no-date stamping, _No decisions:_ markers, unknown sections,
# --dry-run, skipping an already-migrated task, the CONCEPTS.md rename, and the
# decision parsing under both gawk and mawk. All fixture text is made up.
#
# Run in the Docker sandbox (see tests/Dockerfile):
#   docker run --rm -v "$(pwd)":/repo:ro -w /repo wb-tests \
#     bash scripts/.config/scripts/tmux/tests/wb-migrate.test.sh
set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WB="$SELF_DIR/wb.sh"
AE7="$SELF_DIR/tests/fixtures/migrate/ae7-coordinator.md"

FIXTURE="$(mktemp -d -t wb-migrate-fixture.XXXXXX)"
trap 'rm -rf "$FIXTURE"' EXIT

fail=0
assert() { # <desc> <expected-regex> <actual>
  if printf '%s' "$3" | grep -qE "$2"; then echo "ok   - $1"
  else echo "FAIL - $1"; echo "       expected match: $2"; echo "       got: $(printf '%s' "$3" | head -8)"; fail=1; fi
}
assert_not() { # <desc> <regex> <actual>
  if printf '%s' "$3" | grep -qE "$2"; then echo "FAIL - $1"; echo "       unexpected match: $2"; fail=1
  else echo "ok   - $1"; fi
}
assert_eq() { # <desc> <expected> <actual>
  if [ "$2" = "$3" ]; then echo "ok   - $1"
  else echo "FAIL - $1 (expected '$2', got '$3')"; fail=1; fi
}

export XDG_STATE_HOME="$FIXTURE/state"
export HOME="$FIXTURE/home"
export CODE_DIR="$FIXTURE/code"
mkdir -p "$XDG_STATE_HOME" "$HOME" "$CODE_DIR"

# shellcheck disable=SC1090
source "$WB"
# wb.sh loads wb-migrate.sh only from its `migrate` dispatch.
source "$SELF_DIR/wb-migrate.sh"
set +e

STORE_N=0
# new_store — a fresh empty TASKS_DIR for the next scenario.
new_store() {
  STORE_N=$((STORE_N + 1))
  TASKS_DIR="$FIXTURE/store$STORE_N"
  export TASKS_DIR
  mkdir -p "$TASKS_DIR"
}
# store_sum — one checksum over every file in the store (path and bytes).
store_sum() { (cd "$TASKS_DIR" && find . -type f | LC_ALL=C sort | xargs -r md5sum | md5sum | cut -d' ' -f1); }
# mk_task <stem> [created] — an old-shape task file: frontmatter, "# Title",
# then stdin.
mk_task() {
  local stem="$1" created="${2:-2026-10-01}"
  { printf -- '---\nstatus: doing\nrepo: proj\nbranch: b\ntags: []\ncreated: %s\nclosed:\n---\n# Title\n' "$created"; cat; } > "$TASKS_DIR/$stem.md"
}
nfiles() { find "$1" -maxdepth 1 -type f -name '*.md' 2>/dev/null | wc -l | tr -d ' '; }

# =============================================================================
# AE7: the coordinator-shaped fixture
# =============================================================================
new_store
cp "$AE7" "$TASKS_DIR/proj--ae7.md"
T="$TASKS_DIR/proj--ae7.md"; D="$TASKS_DIR/dossiers/proj--ae7"
plan_before="$(_wb_section_text "$T" Plan)"
dry_sum="$(store_sum)"
out="$(cmd_migrate proj--ae7 --dry-run 2>&1)"; rc=$?
assert_eq "dry-run: exit 0" 0 "$rc"
assert "dry-run: count line shows AE7's counts" 'proj--ae7 +decisions 30/30 handoffs 40/40 open-items 12/12 history 5/5 exceptions [0-9]+$' "$out"
assert_eq "dry-run: store byte-identical afterwards" "$dry_sum" "$(store_sum)"
[ ! -e "$TASKS_DIR/dossiers" ] && echo "ok   - dry-run: no dossiers/ directory created" || { echo "FAIL - dry-run created dossiers/"; fail=1; }

out="$(cmd_migrate proj--ae7 2>&1)"; rc=$?
assert_eq "migrate: exit 0" 0 "$rc"
assert "migrate: count line is exactly AE7's counts (decisions, handoffs, open items, history)" 'proj--ae7 +decisions 30/30 handoffs 40/40 open-items 12/12 history 5/5 exceptions' "$out"
assert_not "migrate: no mismatch reported" 'MISMATCH|NOT MIGRATED' "$out"
assert_eq "AE7: 30 decision files" 30 "$(nfiles "$D/decisions")"
assert_eq "AE7: 40 files in handoffs/ (39 moved + the migrated-history file)" 40 "$(nfiles "$D/handoffs")"
assert_eq "AE7: 12 open-items files" 12 "$(nfiles "$D/open-items")"
assert_eq "AE7: the task file keeps one handoff entry (the newest)" 1 "$(grep -c '^### ' <(_wb_section_text "$T" Handoffs))"
assert "AE7: the kept handoff is the newest (step 40)" 'step 40 finished' "$(_wb_section_text "$T" Handoffs)"
assert_eq "AE7: ## Plan untouched byte for byte" "$plan_before" "$(_wb_section_text "$T" Plan)"
assert "AE7: layout: dossier in the frontmatter" '^layout: dossier$' "$(sed -n '1,/^---$/p;' "$T" | head -30)"
assert "AE7: frontmatter still at byte 0" '^---$' "$(head -1 "$T")"
assert "AE7: empty ## Now above ## Plan" '^## Now$' "$(sed -n '1,/^## Plan/p' "$T")"
assert_eq "AE7: ## Now is empty" "" "$(_wb_section_text "$T" Now | tr -d '[:space:]')"
assert "AE7: title and intro kept above ## Now" 'First action when picked up' "$(sed -n '1,/^## Now/p' "$T")"
for h in Decisions Done Follow-ups; do
  assert_not "AE7: no '## $h' section left in the task file" "^## $h\$" "$(awk '/^```/{f=!f} !f' "$T")"
done
assert "AE7: the fenced '## Decisions' line inside ## Plan is still plan text" '^## Decisions$' "$(_wb_section_text "$T" Plan)"
# the two prose supersede markers: raw text, still in force, listed as exceptions
sup="$(grep -l '(supersedes:' "$D"/decisions/*.md | wc -l | tr -d ' ')"
assert_eq "AE7: two decision files carry a raw (supersedes: …) marker" 2 "$sup"
assert_eq "AE7: every decision is in-force" 30 "$(grep -l '^status: in-force$' "$D"/decisions/*.md | wc -l | tr -d ' ')"
assert_eq "AE7: both markers listed as exceptions" 2 "$(printf '%s\n' "$out" | grep -c 'prose (supersedes')"
# migrated-history file
H0="$D/handoffs/2026-08-03-0000.md"
[ -f "$H0" ] && echo "ok   - AE7: history file is handoffs/<created>-0000.md" || { echo "FAIL - AE7: no $H0"; fail=1; }
assert "AE7: history file: source: migrate" '^source: migrate$' "$(cat "$H0" 2>/dev/null)"
assert "AE7: history file: auto: true" '^auto: true$' "$(cat "$H0" 2>/dev/null)"
assert_eq "AE7: history file holds the 5 ticked items" 5 "$(grep -c '^- \[x\]' "$H0" 2>/dev/null)"
assert "AE7: history file holds ## Done's text" 'Kickoff finished' "$(cat "$H0" 2>/dev/null)"
# open items: dated item keeps its own date, others the task's created date
assert "AE7: dated open item: since = its own date" '^since: 2026-09-03$' "$(cat "$D"/open-items/2026-09-03-*.md)"
assert "AE7: undated open item: since = the task's created date" '^since: 2026-08-03$' "$(cat "$D/open-items/2026-08-03-follow-up-1-without-a-date.md")"
assert "AE7: open item: who and kind empty, status open" '^who:$' "$(cat "$D/open-items/2026-08-03-follow-up-1-without-a-date.md")"
assert "AE7: open item: indented sub-point stays with its item" 'sub-point for 3' "$(cat "$D"/open-items/2026-09-03-*.md)"
# views rebuilt
assert "AE7: decisions.md generated" '^<!-- generated by wb from dossiers/proj--ae7/decisions' "$(head -1 "$D/decisions.md")"
assert "AE7: handoffs.md generated" '^<!-- generated by wb from dossiers/proj--ae7/handoffs' "$(head -1 "$D/handoffs.md")"
[ -f "$D/index.md" ] && echo "ok   - AE7: index.md generated" || { echo "FAIL - AE7: no index.md"; fail=1; }
# the four styles: titles and file names
ls_dec="$(ls "$D/decisions")"
assert "style A: bold lead is the title" '^2026-08-01-0000-decision-1-lead\.md$' "$ls_dec"
assert "style B: heading time kept, title from the heading" '^2026-08-02-1002-decision-2-title\.md$' "$ls_dec"
assert "style C: decision-page slug is the title" '^2026-08-03-0000-topic-3-r1\.md$' "$ls_dec"
assert "style D: bold title of the bullet" '^2026-08-04-0000-decision-4-title\.md$' "$ls_dec"
assert "style D: indented lines kept in the body" 'detail line two for 4' "$(cat "$D/decisions/2026-08-04-0000-decision-4-title.md")"
assert "style B: Decided/Rejected/Why bullets kept in the body" '^- Why: simpler to run\.$' "$(cat "$D/decisions/2026-08-02-1002-decision-2-title.md")"
assert "style A: continuation lines (numbered list) kept" '^2\. second consequence\.$' "$(cat "$D/decisions/2026-08-05-0000-decision-5-lead.md")"
# the record files are shaped exactly like the live writers' (compare to one made by wb append)
new_store
printf -- '---\nstatus: doing\nrepo: proj\nlayout: dossier\ncreated: 2026-08-03\n---\n# Live\n' > "$TASKS_DIR/proj--live.md"
printf '### 2026-08-02 10:02 — Decision 2 title\n- Decided (Jet): option 2 wins.\n- Rejected: option 2-b, which costs more.\n- Why: simpler to run.\n' | cmd_append proj--live Decisions - >/dev/null 2>&1
# (the migrated file also keeps the source `###` heading as its first body line)
sed '/^# Decision 2 title$/{n;a\
### 2026-08-02 10:02 — Decision 2 title
}' "$TASKS_DIR/dossiers/proj--live/decisions/2026-08-02-1002-decision-2-title.md" > "$FIXTURE/live-expected.md"
if cmp -s "$FIXTURE/live-expected.md" "$D/decisions/2026-08-02-1002-decision-2-title.md"; then
  echo "ok   - migrated decision file matches one written by wb append, plus the kept heading line"
else echo "FAIL - migrated decision file differs from the live writer's"; diff "$FIXTURE/live-expected.md" "$D/decisions/2026-08-02-1002-decision-2-title.md" | head; fail=1; fi

# second run: byte-identical (checksum of the whole store)
TASKS_DIR="$FIXTURE/store1"; export TASKS_DIR
sum1="$(store_sum)"
out="$(cmd_migrate proj--ae7 2>&1)"; rc=$?
assert_eq "second run: store byte-identical" "$sum1" "$(store_sum)"
assert "second run: reported as already migrated" 'already layout: dossier' "$out"
out="$(cmd_migrate --all 2>&1)"
assert_eq "second run with --all: store byte-identical" "$sum1" "$(store_sum)"
# and the migrated task works with the live writers
printf '### 2026-11-01 09:00 — Fresh\nnew entry\n' | cmd_append proj--ae7 Decisions - >/dev/null 2>&1
assert_eq "after migration: wb append Decisions writes a 31st decision file" 31 "$(nfiles "$TASKS_DIR/dossiers/proj--ae7/decisions")"

# =============================================================================
# decision parsing under both gawk and mawk produces identical stores
# =============================================================================
for flavour in gawk mawk; do
  real="$(command -v "$flavour" || true)"
  if [ -z "$real" ]; then echo "FAIL - $flavour not installed in the sandbox"; fail=1; continue; fi
  new_store; cp "$AE7" "$TASKS_DIR/proj--ae7.md"
  AWKDIR="$FIXTURE/awkshim-$flavour"; rm -rf "$AWKDIR"; mkdir -p "$AWKDIR"; ln -s "$real" "$AWKDIR/awk"
  out="$( PATH="$AWKDIR:$PATH"; hash -r; cmd_migrate proj--ae7 2>&1 )"
  assert "AE7 under $flavour: AE7's counts" 'decisions 30/30 handoffs 40/40 open-items 12/12 history 5/5' "$out"
  eval "SUM_$flavour=\"\$(store_sum)\""
done
assert_eq "AE7: store identical whether awk is gawk or mawk" "$SUM_gawk" "$SUM_mawk"

# =============================================================================
# dated top-level bullets with indented follow-on lines
# =============================================================================
new_store
mk_task proj--bul 2026-10-01 <<'EOF'

## Handoffs

## Decisions

- **2026-10-18 (Jet): Use the shared queue.** Everything goes through one queue.
  - first indented line
  - second indented line
- 2026-10-19 — Retire the old cron job. It is replaced by the queue worker.
  - detail

- **2026-10-20 (Jet, via buffer): Keep both formats.** Reads stay the same.

## Follow-ups
EOF
out="$(cmd_migrate proj--bul 2>&1)"
BD="$TASKS_DIR/dossiers/proj--bul"
assert "bullets: 3 decisions, counts match" 'decisions 3/3' "$out"
assert_eq "bullets: three decision files" 3 "$(nfiles "$BD/decisions")"
assert "bullets: bold title 'Use the shared queue'" '^# Use the shared queue$' "$(cat "$BD/decisions/2026-10-18-0000-use-the-shared-queue.md")"
assert "bullets: indented lines stay with their bullet" 'second indented line' "$(cat "$BD/decisions/2026-10-18-0000-use-the-shared-queue.md")"
assert "bullets: plain bullet takes its first clause as the title" '^# Retire the old cron job$' "$(cat "$BD/decisions/2026-10-19-0000-retire-the-old-cron-job.md")"
assert "bullets: (Jet, via buffer) paren stripped from the title" '^# Keep both formats$' "$(cat "$BD/decisions/2026-10-20-0000-keep-both-formats.md")"

# =============================================================================
# ### headings: kept verbatim in the body (the title is cleaned and clipped)
# =============================================================================
new_store
LONGH='### 2026-10-18 09:15 — **Adopt the shared queue for every worker, and retire the per-worker cron jobs, the lock files and the polling scripts entirely!**'
{ printf -- '---\nstatus: doing\nrepo: proj\nbranch: b\ntags: []\ncreated: 2026-10-01\nclosed:\n---\n# Title\n\n## Decisions\n\n%s\n\n- Decided: one queue.\n- Why: simpler.\n\n### 2026-10-19 11:00 — Short heading.\n\n- Decided: keep it.\n\n## Follow-ups\n' "$LONGH"; } > "$TASKS_DIR/proj--hd.md"
out="$(cmd_migrate proj--hd 2>&1)"
HD="$TASKS_DIR/dossiers/proj--hd"
assert "heading: counts match" 'decisions 2/2' "$out"
assert_not "heading: task not blocked" 'NOT MIGRATED' "$out"
hf="$(ls "$HD"/decisions/2026-10-18-*.md)"
assert_eq "heading: the full source heading is in the body byte for byte" 1 "$(grep -cxF -- "$LONGH" "$hf")"
assert_eq "heading: the title was clipped (at most 100 chars after '# ')" 1 "$(grep -c '^# .\{1,100\}$' "$hf")"
assert_eq "heading: a short heading is kept too" 1 "$(grep -cxF -- '### 2026-10-19 11:00 — Short heading.' "$HD"/decisions/2026-10-19-*.md)"

# a record file whose body differs from its source entry blocks the task
new_store
mk_task proj--lossy 2026-10-01 <<'EOF'

## Decisions

### 2026-10-18 09:15 — Heading.

- Decided: one queue.
EOF
_wb_mg_body_text() { echo tampered; }
out="$(cmd_migrate proj--lossy --dry-run 2>&1)"
assert "per-entry check: a differing body blocks the task" 'differs from its record file' "$out"
source "$SELF_DIR/wb-migrate.sh"

# =============================================================================
# a line that fits no style: task left unmigrated, line number listed
# =============================================================================
new_store
mk_task proj--stray 2026-10-01 <<'EOF'

## Plan

keep me

## Decisions

Some loose sentence before any entry.

2026-10-18 — **A real one.** Body.

## Follow-ups
EOF
before="$(store_sum)"
out="$(cmd_migrate proj--stray 2>&1)"; rc=$?
assert "stray line: NOT MIGRATED in the count line" 'proj--stray .*NOT MIGRATED' "$out"
assert "stray line: its task line number (17) is listed" 'fit no entry style \(task line numbers: 17\)' "$out"
assert_eq "stray line: nothing written (store byte-identical)" "$before" "$(store_sum)"
[ ! -e "$TASKS_DIR/dossiers" ] && echo "ok   - stray line: no dossiers/ directory" || { echo "FAIL - stray line: dossiers/ created"; fail=1; }
assert_eq "stray line: exit 1 (a task was left unmigrated)" 1 "$rc"
# a stray column-0 line after a bullet entry is also unattributed
new_store
mk_task proj--stray2 2026-10-01 <<'EOF'

## Decisions

- 2026-10-18 — A bullet entry.
  - indented, fine
not indented, not an entry
EOF
out="$(cmd_migrate proj--stray2 2>&1)"
assert "bullet entry then an unindented line: unmigrated, line 15 listed" 'task line numbers: 15' "$out"

# =============================================================================
# prose supersede marker: raw text, in force, exception
# =============================================================================
new_store
mk_task proj--sup 2026-10-01 <<'EOF'

## Decisions

2026-10-17 — **Keep the board.** It still works.

### 2026-10-20 09:15 — Drop the board
- Decided: drop it.
- Why: nobody reads it. (supersedes: 2026-10-17 "Probe 6")

## Follow-ups
EOF
out="$(cmd_migrate proj--sup 2>&1)"
SD="$TASKS_DIR/dossiers/proj--sup"
f="$SD/decisions/2026-10-20-0915-drop-the-board.md"
assert "supersede marker: kept as raw text in the body" '\(supersedes: 2026-10-17 "Probe 6"\)' "$(cat "$f")"
assert "supersede marker: decision stays in-force" '^status: in-force$' "$(cat "$f")"
assert "supersede marker: supersedes: [] (not linked)" '^supersedes: \[\]$' "$(cat "$f")"
assert "supersede marker: listed as an exception" 'prose \(supersedes: …\) marker' "$out"
assert "supersede marker: task still migrated" 'proj--sup +decisions 2/2' "$out"

# =============================================================================
# counts come from the raw text: a fenced dated line the parser folds in
# =============================================================================
new_store
mk_task proj--fence 2026-10-01 <<'EOF'

## Decisions

2026-10-17 — **An entry with a code sample.** The sample:

```text
2026-10-18 — this line is inside a fence
```

## Follow-ups
EOF
before="$(store_sum)"
out="$(cmd_migrate proj--fence 2>&1)"
assert "mismatch: the raw count (2) differs from the parsed one (1)" 'decisions 2/1\(MISMATCH\)' "$out"
assert "mismatch: NOT MIGRATED" 'NOT MIGRATED' "$out"
assert_eq "mismatch: nothing written" "$before" "$(store_sum)"

# =============================================================================
# a held lock skips the task and the --all report names it
# =============================================================================
new_store
mk_task proj--locked 2026-10-01 <<'EOF'

## Decisions

2026-10-17 — **Locked one.** Body.
EOF
mk_task proj--free 2026-10-01 <<'EOF'

## Decisions

2026-10-17 — **Free one.** Body.
EOF
wb_task_lock_acquire "$TASKS_DIR/proj--locked.md" >/dev/null 2>&1
locked_before="$(md5sum < "$TASKS_DIR/proj--locked.md")"
out="$(cmd_migrate --all 2>&1)"; rc=$?
wb_task_lock_release "$TASKS_DIR/proj--locked.md"
assert "lock held: the task is skipped on its count-line slot" 'proj--locked  SKIPPED, lock held' "$out"
assert "lock held: --all ends with a report naming it" '^Skipped, lock held' "$out"
assert "lock held: the report line names the task" '^  proj--locked$' "$out"
assert "lock held: the other task still migrated" 'proj--free +decisions 1/1' "$out"
assert_eq "lock held: the locked task file is untouched" "$locked_before" "$(md5sum < "$TASKS_DIR/proj--locked.md")"
[ ! -e "$TASKS_DIR/dossiers/proj--locked" ] && echo "ok   - lock held: no dossier written" || { echo "FAIL - lock held: dossier written"; fail=1; }
assert_eq "lock held: exit 1" 1 "$rc"
out="$(cmd_migrate --all 2>&1)"; rc=$?
assert "after the lock is released a rerun migrates it" 'proj--locked +decisions 1/1' "$out"
assert_eq "rerun: exit 0" 0 "$rc"

# =============================================================================
# no time / no date: 0000, 0001 stamps and inherited dates, each an exception
# =============================================================================
new_store
mk_task proj--stamp 2026-10-05 <<'EOF'

## Decisions

2026-10-18 — **First same-day.** One.
2026-10-18 — **Second same-day.** Two.

### Dateless heading
- Decided: it inherits the date above.

### 2026-10-19 08:30 — Timed
- Decided: has a time.

## Handoffs

### 2026-10-18 RESAVE — wb-save
**Done:** a loosely headed save.

### 2026-10-18 17:00 — wb-save
**Done:** a normal save.
EOF
out="$(cmd_migrate proj--stamp 2>&1)"
ST="$TASKS_DIR/dossiers/proj--stamp"
ls_dec="$(ls "$ST/decisions")"
assert "no time: first entry of the day is 0000" '^2026-10-18-0000-first-same-day\.md$' "$ls_dec"
assert "no time: second entry of the day is 0001" '^2026-10-18-0001-second-same-day\.md$' "$ls_dec"
assert "no date: heading takes the previous entry's date, next stamp 0002" '^2026-10-18-0002-dateless-heading\.md$' "$ls_dec"
assert "timed entry keeps its own time" '^2026-10-19-0830-timed\.md$' "$ls_dec"
assert "no time: listed as an exception" 'decisions with no time were stamped' "$out"
assert "no date: listed as an exception" 'decisions with no date took the previous entry' "$out"
assert "loose handoff heading: gets a deterministic stamp (date from the heading, 0000)" '^2026-10-18-0000\.md$' "$(ls "$ST/handoffs")"
assert "loose handoff heading: heading kept verbatim in the body" '^### 2026-10-18 RESAVE — wb-save$' "$(cat "$ST/handoffs/2026-10-18-0000.md")"
assert "loose handoff heading: listed as an exception" 'handoffs whose heading has no HH:MM' "$out"
assert "newest handoff stays in the task file" 'a normal save' "$(_wb_section_text "$TASKS_DIR/proj--stamp.md" Handoffs)"
# first entry with no date at all: the task's created date
new_store
mk_task proj--nodate1 2026-10-05 <<'EOF'

## Decisions

### Untimed and undated first
- Decided: it takes the created date.
EOF
cmd_migrate proj--nodate1 >/dev/null 2>&1
assert "first entry without a date: takes created: (2026-10-05), stamp 0000" '^2026-10-05-0000-untimed-and-undated-first\.md$' "$(ls "$TASKS_DIR/dossiers/proj--nodate1/decisions")"

# =============================================================================
# _No decisions:_ markers go to the migrated-history file
# =============================================================================
new_store
mk_task proj--nodec 2026-10-02 <<'EOF'

## Decisions

_No decisions: the session only read code._

## Handoffs

### 2026-10-03 10:00 — wb-save
**Done:** read.
EOF
out="$(cmd_migrate proj--nodec 2>&1)"
ND="$TASKS_DIR/dossiers/proj--nodec"
assert "marker: 0 decisions, 1 history item" 'decisions 0/0 handoffs 1/1 open-items 0/0 history 1/1' "$out"
assert_eq "marker: decisions/ is not created" "0" "$(nfiles "$ND/decisions")"
assert "marker: lives in the history file" '_No decisions: the session only read code\._' "$(cat "$ND/handoffs/2026-10-02-0000.md")"
assert "marker: under its own sub-heading" '^#### No decisions$' "$(cat "$ND/handoffs/2026-10-02-0000.md")"

# =============================================================================
# unknown section kept in place and listed
# =============================================================================
new_store
mk_task proj--unk 2026-10-02 <<'EOF'

## Plan

the plan

## Notes for later

keep this text where it is

## Decisions

2026-10-18 — **One.** Body.
EOF
out="$(cmd_migrate proj--unk 2>&1)"
UT="$TASKS_DIR/proj--unk.md"
assert "unknown section: kept in the task file" 'keep this text where it is' "$(cat "$UT")"
assert "unknown section: sits between ## Plan and the end, in place" '^## Notes for later$' "$(cat "$UT")"
assert "unknown section: listed as an exception" "section '## Notes for later'" "$out"
assert "unknown section: task still migrated" 'proj--unk +decisions 1/1' "$out"
assert_not "unknown section: ## Decisions removed" '^## Decisions$' "$(cat "$UT")"

# =============================================================================
# follow-ups: stray lines, ticked vs open, intro lines
# =============================================================================
new_store
mk_task proj--fol 2026-10-02 <<'EOF'

## Follow-ups

Some note before any checkbox.

- [ ] Open one, with detail:
  - nested detail
A loose top-level line under the open item.

- [x] Ticked one.
  - nested under ticked
- [ ] **2026-10-12:** Dated open one.
EOF
out="$(cmd_migrate proj--fol 2>&1)"
FD="$TASKS_DIR/dossiers/proj--fol"
assert "follow-ups: 2 open, 1 ticked, counts match" 'open-items 2/2 history 1/1' "$out"
assert "follow-ups: loose top-level line attached to the item above (listed)" 'top-level line\(s\) that are not checkbox items were attached' "$out"
assert "follow-ups: the attached line is in the open item's file" 'A loose top-level line' "$(cat "$FD"/open-items/2026-10-02-open-one*.md)"
assert "follow-ups: line before the first checkbox goes to the history file (listed)" 'before the first checkbox item moved to the migrated-history file' "$out"
assert "follow-ups: that line is in the history file" 'Some note before any checkbox' "$(cat "$FD/handoffs/2026-10-02-0000.md")"
assert "follow-ups: ticked item in the history file with its nested line" 'nested under ticked' "$(cat "$FD/handoffs/2026-10-02-0000.md")"
assert "follow-ups: dated item uses its own date" '^since: 2026-10-12$' "$(cat "$FD"/open-items/2026-10-12-*.md)"

# =============================================================================
# handoffs: single entry stays, none moved; handoffs-only task
# =============================================================================
new_store
mk_task proj--hand 2026-10-02 <<'EOF'

## Handoffs

### 2026-10-03 10:00 — wb-save
**Done:** only one.
EOF
out="$(cmd_migrate proj--hand 2>&1)"
assert "one handoff: 1/1, nothing moved" 'handoffs 1/1' "$out"
assert_eq "one handoff: no handoff files, no history file" 0 "$(nfiles "$TASKS_DIR/dossiers/proj--hand/handoffs")"
assert "one handoff: stays under ## Handoffs" 'only one' "$(_wb_section_text "$TASKS_DIR/proj--hand.md" Handoffs)"

# =============================================================================
# --dry-run on a store with several tasks writes nothing; --all walks only task stems
# =============================================================================
new_store
mk_task proj--a 2026-10-02 <<'EOF'

## Decisions

2026-10-18 — **A.** Body.
EOF
mk_task proj--b 2026-10-02 <<'EOF'

## Decisions

2026-10-18 — **B.** Body.
EOF
printf '# Agents\n\nrules\n' > "$TASKS_DIR/AGENTS.md"
printf '# Claude\n' > "$TASKS_DIR/CLAUDE.md"
printf '# Readme\n' > "$TASKS_DIR/README.md"
printf -- '---\nstatus: x\n---\n# Template\n' > "$TASKS_DIR/TEMPLATE.md"
before="$(store_sum)"
out="$(cmd_migrate --all --dry-run 2>&1)"
assert_eq "--all --dry-run: store byte-identical" "$before" "$(store_sum)"
assert "--all --dry-run: both tasks listed" 'proj--a +decisions 1/1' "$out"
assert "--all --dry-run: second task listed" 'proj--b +decisions 1/1' "$out"
assert "--all --dry-run: 2 would migrate" '2 would migrate' "$out"
assert_not "--all: AGENTS.md / CLAUDE.md / README.md / TEMPLATE.md are never touched" 'AGENTS|CLAUDE|README|TEMPLATE' "$out"
out="$(cmd_migrate --all 2>&1)"
assert "--all: 2 migrated" '2 migrated' "$out"
assert_eq "--all: AGENTS.md untouched" "# Agents" "$(head -1 "$TASKS_DIR/AGENTS.md")"
assert_eq "--all: only two dossiers created" 2 "$(ls "$TASKS_DIR/dossiers" | wc -l | tr -d ' ')"

# =============================================================================
# CONCEPTS.md -> concepts.md (KTD24)
# =============================================================================
new_store
mk_task proj--con 2026-10-02 <<'EOF'

## Decisions

2026-10-18 — **C.** Body.
EOF
mkdir -p "$TASKS_DIR/dossiers/proj--con"; printf '# concepts\n' > "$TASKS_DIR/dossiers/proj--con/CONCEPTS.md"
mkdir -p "$TASKS_DIR/dossiers/proj--con/notes-dir"; printf 'keep\n' > "$TASKS_DIR/dossiers/proj--con/brief.md"
out="$(cmd_migrate proj--con 2>&1)"
CD="$TASKS_DIR/dossiers/proj--con"
assert "concepts: lower-case file exists" '^concepts\.md$' "$(ls "$CD")"
assert_not "concepts: upper-case name gone" '^CONCEPTS\.md$' "$(ls "$CD")"
assert_eq "concepts: content preserved" "# concepts" "$(cat "$CD/concepts.md")"
assert "concepts: other dossier files untouched" 'keep' "$(cat "$CD/brief.md")"
assert "concepts: the report tells Jet to reseed" 'wb family <task> --reseed' "$out"
# dry-run does not rename
new_store
mk_task proj--con2 2026-10-02 <<'EOF'

## Decisions

2026-10-18 — **C.** Body.
EOF
mkdir -p "$TASKS_DIR/dossiers/proj--con2"; printf '# concepts\n' > "$TASKS_DIR/dossiers/proj--con2/CONCEPTS.md"
cmd_migrate proj--con2 --dry-run >/dev/null 2>&1
assert "concepts: dry-run leaves CONCEPTS.md alone" '^CONCEPTS\.md$' "$(ls "$TASKS_DIR/dossiers/proj--con2")"

# =============================================================================
# a dossier that already holds records blocks the move
# =============================================================================
new_store
mk_task proj--pre 2026-10-02 <<'EOF'

## Decisions

2026-10-18 — **P.** Body.
EOF
mkdir -p "$TASKS_DIR/dossiers/proj--pre/decisions"; printf 'x\n' > "$TASKS_DIR/dossiers/proj--pre/decisions/old.md"
before="$(store_sum)"
out="$(cmd_migrate proj--pre 2>&1)"
assert "existing records: unmigrated with a clear reason" 'decisions/ already holds files' "$out"
assert_eq "existing records: nothing changed" "$before" "$(store_sum)"

# =============================================================================
# the CLI dispatch and wb help
# =============================================================================
new_store
mk_task proj--cli 2026-10-02 <<'EOF'

## Decisions

2026-10-18 — **CLI.** Body.
EOF
out="$(TASKS_DIR="$TASKS_DIR" bash "$WB" migrate proj--cli --dry-run 2>&1)"; rc=$?
assert_eq "dispatch: wb migrate exits 0" 0 "$rc"
assert "dispatch: wb migrate prints the count line" 'proj--cli +decisions 1/1' "$out"
out="$(bash "$WB" migrate 2>&1)"; rc=$?
assert_eq "no argument: usage, exit 1" 1 "$rc"
assert "no argument: usage text" 'usage: wb migrate <task>\|--all \[--dry-run\]' "$out"
assert "wb help lists migrate" '^  wb migrate ' "$(cmd_help)"

echo
[ "$fail" -eq 0 ] && echo "ALL PASS" || echo "FAILURES"
exit "$fail"
