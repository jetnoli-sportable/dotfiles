---
type: feat
status: draft
origin: docs/roadmap.md §4 + §8 item 4b, as amended by the 2026-07-06
  ce-doc-review; gated on 4a's usage window (Decision 1A) — do NOT start
  ce-work on this until that gate is called
---

# Slice 4b — notes-tui integration: per-capture corpus, --context, wb hooks

## Summary

The real notes-tui integration, executable only after (a) 4a's ~1-week
capture window confirms digest-at-close is the right review moment and
(b) slice 5 has landed. The review's verified blocker shapes this plan:
`corpus.Load` parses one note per FILE (first ctx stamp wins), so the whole
inbox reads as a single note — the `--context` flag is meaningless without
per-capture splitting first. Two repos are touched: `~/code/notes-tui`
(Go) and `~/code/dotfiles` (`wb.sh`).

## Gate (read before executing)

- 4a review happened (check the follow-up entry in
  `~/code/tasks/dotfiles--agent-task-workflow.md`): is capture actually
  being used? Is task-end the review moment, or did day-end win? If day-end
  won, U3's hook moves to the future `wb down` instead of `wb done` —
  re-shape U3 before dispatching, don't execute as written.
- Captures made before U1 lands cannot be retro-digested per-session;
  accept or reprocess raw stamps as a one-off (out of scope here).

## Scope Boundaries (non-goals)

- No Bubble Tea TUI (notes-tui roadmap Phase 2), no AI layer.
- No topic-ledger work; Denote tags stay as-is.
- No `wb up`/`wb down` (9b) — only the digest hook contract is designed to
  compose with it.
- No changes to `notes.sh` (the nvim daily-note flow keeps working).

## Implementation Units

### U1: Per-capture inbox parsing (notes-tui, Go)

- **Goal:** `corpus.Load` splits `inbox.md` into one Note per capture
  block, each carrying its own timestamp and ctx (cwd, repo, branch, tmux
  session) — the review-verified prerequisite for everything else.
- **Files:** `~/code/notes-tui/internal/corpus/corpus.go` (+ tests).
- **Approach:** detect capture-block boundaries as written by
  `scripts/note.sh` (`## <timestamp>` heading + `<!-- ctx: ... -->` stamp);
  inbox-shaped files yield N Notes, Denote files keep the one-note-per-file
  path unchanged. Time from the block timestamp, not mtime.
- **Execution note:** test-first — fixture inbox with 3 captures across 2
  sessions; single-capture inbox; malformed block (no ctx stamp) falls back
  gracefully.
- **Verification:** `go test ./...` green; `notes digest day --by context`
  against the real corpus shows multiple rows where it showed one.

### U2: --context filter + session-aware grouping (notes-tui, Go)

- **Goal:** `notes digest --context <tmux-session>` filters to one
  session's captures; `--by context` grouping gains the session dimension
  (fixing the documented repo:branch-only behavior).
- **Files:** `~/code/notes-tui/cmd/notes/digest.go` (+ tests),
  `notes-guide.html` (or its .md source if slice 5 converted it) + README
  flag docs.
- **Approach:** filter on `Context.Session`; group key becomes
  repo:branch(:session when --context absent and sessions differ). Update
  the usage guide so the docs never again claim grouping the code doesn't do.
- **Test scenarios:** filter hits/misses; empty result prints an explicit
  "no captures for session X in window" (not a blank digest).
- **Verification:** capture in two tmux sessions, digest each — only the
  right rows appear.

### U3: wb done digest injection (dotfiles, bash)

- **Goal:** the close-out buffer opens with the session's digest inline, so
  keepers are promoted deliberately.
- **Files:** `scripts/.config/scripts/tmux/wb.sh` (`cmd_done`).
- **Approach:** before opening the review buffer, run
  `notes digest --by context --context "$session"` and inject the output as
  a `## Notes digest (generated — stripped on close)` section **ABOVE the
  `## Sweep` heading** — the sweep-strip awk truncates the file AT the Sweep
  heading (review residual: anything after it is silently deleted; anything
  before it persists unless stripped), so the digest section needs its own
  strip pass mirroring `wb_sweep_section`'s. Keepers marked `- [x] keep`
  inside the digest section promote into the task file's `## Follow-ups`
  (recommended target — matches the store-centric model; the alternative,
  new Denote notes, is the one open call below). Degrade gracefully when
  `notes` isn't on PATH: skip the section, no error.
- **Test scenarios:** dirty-abort path unchanged; digest section stripped
  after close (file byte-identical modulo promotions); `notes` absent.
- **Verification:** full `wb new` → capture 2 notes → `wb done` cycle: the
  buffer shows both captures; a kept one lands in Follow-ups; the task file
  carries no generated residue.

### U4: Retire the interim, update the docs

- **Goal:** consistency after integration.
- **Approach:** roadmap §4/§8 status notes; wb-guide + guide pages gain the
  digest step in the `wb done` flow; the 4a follow-up entry in the task
  store closes with the verdict that gated this slice.
- **Verification:** repo-wide grep shows no doc still describing `wb done`
  without the digest step.

## Deferred to Implementation

- Promotion target if the 4a window contradicts the recommendation
  (task-file Follow-ups vs new Denote notes).
- Whether `--by context` adds session to the group key by default or only
  under a flag (pick at U2 based on how noisy real data looks).

## Verification (slice level)

The full lifecycle on a real task: `wb new` → work + `note` captures →
`wb done` shows the digest → keeper promotes → worktree removed → `wb board`
shows done. notes-tui tests green; `notes.sh` daily flow untouched.
