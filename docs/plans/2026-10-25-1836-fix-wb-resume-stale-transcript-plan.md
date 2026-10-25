---
title: wb resume stale transcript - Plan
type: fix
date: 2026-10-25
artifact_contract: ce-unified-plan/v1
product_contract_source: ce-plan-bootstrap
execution: code
---

# wb resume stale transcript - Plan

## Goal Capsule

- **Objective:** after a mass session kill, `wb resume` pre-types `claude --resume <id>` for the conversation Jet was actually in, never one from before their last `/clear`. Pressing Enter on the pre-typed line can't quietly bring back stale context.
- **Means:** `wb_resume_id` ranks a worktree's transcripts by the last `"timestamp"` written inside each file, falling back to mtime (KTD1, KTD2).
- **Authority:** Jet's global instructions (`~/.claude/CLAUDE.md`) > the task file's Decisions (`~/code/tasks/dotfiles--fix-wb-resume-stale-transcript.md`) > this plan's Requirements > KTDs > unit Approach.
- **Stop conditions:** stop and ask if any existing `wb_resume_id` or U4 warm-relaunch assertion changes outcome, or if real transcripts turn out to get `{"parentUuid":` activity lines written into a stale conversation at shutdown (that would undo KTD1).
- **Execution profile:** under half a day. About 30 lines changed in `wb.sh` plus about 5 test assertions.
- **Finishes and ships:** the implementing session commits on `fix/wb-resume-stale-transcript`. Push and PR wait for Jet's OK. Code review runs in a fresh context after `/wb-save`, per Jet's rule.

## Product Contract

### Summary

`wb_resume_id` stops trusting file mtime. It reads the last `"timestamp"` from the end of each transcript and picks the newest, falling back to mtime when a file has none. The `@primary` preference stays first. The picker and `wb_sessions_snapshot` keep their cheap mtime sort. Regression tests pin the exact tie and the inversion that misfired.

### Problem Frame

All 21 wb sessions died at once on 2026-10-25 at 18:07:43, when a subagent's test ran `tmux kill-server` against Jet's real tmux server. When the sessions were rebuilt with `wb resume`, 3 of the 21 (claude-reply-log, verify-behaviour, gnome-tiling) pre-typed the conversation from before Jet's last `/clear`. In claude-reply-log, pressing Enter would have abandoned a code review partway through.

`wb_resume_id` (`scripts/.config/scripts/tmux/wb.sh`) prefers the `@primary` id in `claude_sessions:`. That field was empty in all three task files because only `wb down` writes it. The function then took the head of `wb_transcripts`, which sorts by whole-second mtime. At shutdown Claude Code writes bookkeeping lines into older transcripts in the same folder too (`artifact-autoreact-ledger`, `artifact-comment-monitor`, `cost-state`, `last-prompt`), so every file got mtime 18:07:43. On a tie, GNU `sort -k2,2nr` falls back to comparing whole lines in ascending order, so the alphabetically lower id won. In all three tasks that was the stale conversation: 09088195 < 234a16c8, ee9a679b < faea8d10, 9ae11eaf < b2cf4a13.

### Key Decisions

- KD1. **Pick the conversation with the latest real activity, not the latest file write.** (session-settled: user-approved — chosen over fractional `%.Y` mtime: shutdown bookkeeping can land on an old transcript after the live one, so sub-second order is not guaranteed either.) Governs R1, R2.
- KD2. **Don't make the notify hook's `@claude_session_id` a live source.** (session-settled: user-approved — chosen over plan step 2: it is a tmux pane option, so `tmux kill-server` wipes it in exactly the crash this fixes, and R1 already covers the `/clear` case.) Governs R4.

### Requirements

**Resume choice**

- R1. With no usable `@primary`, `wb_resume_id` returns the transcript whose last timestamped entry is newest, whatever the files' mtimes are.
- R2. A transcript with no timestamped entry near its end is ranked by its mtime, on the same time scale as timestamped files.
- R3. An `@primary` id in `claude_sessions:` whose transcript still exists keeps winning, as today.

**Unchanged surfaces**

- R4. `wb_transcripts` output and its callers (the picker's dormant rows, `wb-board.sh`, `wb_sessions_snapshot`) are unchanged.

### Scope Boundaries

- Not built: a durable record of the live conversation written on every hook event (KD2). Two Claude panes active in the same worktree at once may still resume whichever spoke last. That's rare, and evidence it bites would change the call.
- Not built: re-ranking the picker's age-in-days by timestamp. Age only needs day resolution, and that path runs once per dormant row per render.
- Not built: millisecond tie-breaking between two timestamped files. Real entries carry millisecond timestamps, so an exact tie needs two conversations writing in the same millisecond.

## Planning Contract

### Key Technical Decisions

- KTD1. **Rank key = last `"timestamp":"…"` on an activity line in the final 256 KiB of the file, read with `tail -c` and fixed-string patterns.** (session-settled: user-approved — chosen over parsing each line with `jq`: no new dependency, and `jq` aborts on the partial first line a byte-offset `tail` produces.) Governs R1.
  - An activity line is one that starts with `{"parentUuid":` (user, assistant, system, attachment).
  - Bookkeeping lines start with `{"type":` and are skipped. Some carry no timestamp. Others (`frame-link`, `queue-operation`, `api-request`, `pr-link`) carry one and can be written at shutdown into conversations idle for days: the 16:07:43Z crash stamped a `frame-link` line into a conversation whose last turn was 2026-10-19.
  - Drop the partial first line that a byte-offset `tail` produces before filtering.
  - `tail -c` seeks, so a 15 MB transcript costs the same as a small one: about 38 ms measured for a 4-file folder.
  - A `"timestamp"` inside message content is JSON-escaped (`\"timestamp\"`), so the pattern doesn't match it.
- KTD2. **Fallback key = mtime rendered in the same shape as a real timestamp (`YYYY-MM-DDTHH:MM:SS.000Z`), via bash's builtin `printf '%(…)T'` with `TZ=UTC` as a command prefix.** One string shape lets a plain reverse sort order timestamped and untimestamped files together without a `date` fork per file. It also keeps every existing fixture (empty `{}` files ranked by `touch -d`) behaving as before.
  - The `.000` fractional part matters. Without it, `Z` sorts above `.`, so an mtime key would beat real activity later in the same second.
  - Only the prefix form (or `local -x TZ=UTC`) renders UTC. A plain `local TZ=UTC` is not exported, so `printf` silently renders local time, verified on bash 5.2. That would rank fallback files 1-2 hours ahead on Jet's CET/CEST host.

  Governs R2.
- KTD3. **Ranking lives only in `wb_resume_id`.** `wb_transcripts` keeps its one-`stat` contract because the picker calls it once per dormant-row candidate. `wb_resume_id` runs once per `wb new`/`wb resume`. Governs R4.

### Assumptions

- Claude Code writes conversation turns as lines starting `{"parentUuid":` with a `"timestamp":"<ISO-8601 Z>"`, and only into the conversation they belong to. Bookkeeping lines start `{"type":` and may carry crash-time timestamps, which KTD1 ignores. Checked on 2026-10-25: all 170 transcripts on disk have an activity-line timestamp in their last 256 KiB. If a future Claude Code version changes the line prefix, ranking degrades to the mtime fallback and the tie bug can return.

## Implementation Units

### U1. Rank resume candidates by last in-file timestamp

**Goal:** `wb_resume_id`'s non-primary branch returns the transcript with the newest real activity.

**Requirements:** R1, R2, R3, R4. KTD1, KTD2, KTD3.

**Dependencies:** none.

**Files:**
- `scripts/.config/scripts/tmux/wb.sh` (modify: new small helper near `wb_transcripts`, plus the fallback branch of `wb_resume_id`)
- `scripts/.config/scripts/tmux/tests/wb-schema.test.sh` (test)

**Approach:**
1. Add a helper that takes a transcript path and its mtime epoch and prints the rank key from KTD1, or the KTD2 fallback when no timestamp is found.
2. In `wb_resume_id`, keep the `@primary` check exactly as is. Replace the final `head -n1` of the mtime-sorted list with a pass over the same ids: build "key<TAB>id" per transcript, reverse-sort on the key, take the first id.
3. Update the header comments on `wb_transcripts` and `wb_resume_id`, plus the U2 block comment above them, to say mtime is not trusted for the resume choice and why (shutdown bookkeeping writes). Match the existing comment density.

**Patterns to follow:** `wb_transcripts`'s single-pass loop and its no-fork rationale. The `CLAUDE_PROJECTS_DIR` override for fixtures.

**Test scenarios** (beside the existing `wb_resume_id` block in `wb-schema.test.sh`, with fixture lines shaped like the real ones: activity lines starting `{"parentUuid":` and carrying `"timestamp":"…Z"`, followed by `{"type":"cost-state",…}` / `{"type":"artifact-comment-monitor",…}` lines with no timestamp):
- Tie: `aaa-stale` (last activity 15:24Z) and `bbb-live` (last activity 16:07:41Z), both touched to the same second, no `claude_sessions:` → returns `bbb-live`. This is the incident shape: the lower id is the stale one.
- Crash-stamped bookkeeping: as Tie, but `aaa-stale` ends with `{"type":"frame-link",…,"timestamp":"…T16:07:43.267Z"}` and `{"type":"queue-operation",…,"timestamp":"…T16:07:43.279Z"}` after its last activity line → still returns `bbb-live`.
- Inversion: `bbb-live` has the older mtime, `aaa-stale` the newer one, timestamps as above → returns `bbb-live`.
- Mixed fallback: a timestamped file with last activity 2026-09-01 and an empty `{}` file touched 2026-09-05 → returns the empty file's id. With the dates swapped → returns the timestamped id. Run both under `TZ=XXX-2` (a POSIX TZ string, which needs no tzdata in the Docker image) so a fallback key rendered in local time fails.
- Primary preserved: `claude_sessions:` marks `aaa-stale@…@primary` while `bbb-live` has newer activity → returns `aaa-stale`.
- Window edge: a file whose last 256 KiB has no timestamp (one long bookkeeping line after the last activity line) → ranked by mtime, without error.

**Verification:** the new assertions report `ok`. The existing `wb_resume_id` and `wb_transcripts` assertions in `wb-schema.test.sh` keep their outcomes, as do the U4 warm-relaunch assertions in `wb-new.test.sh`. The real-data check in the Verification Contract passes.

## Verification Contract

| Gate | How | Pass signal |
|---|---|---|
| New and existing resume tests | `wb-schema.test.sh` and `wb-new.test.sh`, run **only inside the Docker sandbox** (`docker run --rm -v "$(pwd)":/repo:ro -w /repo wb-tests`), never on the host tmux server | New assertions print `ok - …`, and no previously passing assertion turns to `FAIL` |
| No regression across the suite | Full Docker suite on the branch vs. the same suite on a clean-room `development` copy under `~/.cleanroom/wb-resume-stale-transcript-baseline/` | Identical per-file `^FAIL` line sets (both currently sit on a ~12-file environment floor). Judge by `grep '^FAIL'`, never by the wrapper's exit code or a final `ALL PASS` line |
| Real-data check, with the crash tie rebuilt | Copy the three affected transcript folders (claude-reply-log, verify-behaviour, gnome-tiling) into `~/.cleanroom/wb-resume-stale-transcript-realdata/`, leaving the originals untouched. `touch -d '2026-10-25 18:07:43'` every copied `.jsonl` to rebuild the shutdown tie. The live files have been resumed since the crash, so without this the old code already picks them and the check proves nothing. Call `wb_resume_id` with `CLAUDE_PROJECTS_DIR` pointed at the copy and a fixture task file with no `claude_sessions:` | The branch returns 234a16c8, faea8d10 and b2cf4a13. The same call with `development`'s `wb.sh` returns the alphabetically lowest id in each folder, all stale: 09088195, adfbcda8 and 9ae11eaf |

## Definition of Done

- U1's test scenarios exist and pass in the Docker sandbox, and the suite's FAIL set matches the clean-room baseline.
- `wb_transcripts` output is byte-for-byte unchanged for the same inputs (R4).
- Comments in `wb.sh` no longer call mtime the newest-conversation signal for resume.
- No leftover experimental code or debug output in the diff.
