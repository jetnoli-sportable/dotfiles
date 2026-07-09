---
title: PR #1 recap — wb resume, wb pause, /board, wb reconcile
status: current
tile: All four wb workbench extensions shipped. What to verify yourself.
group: personal-workflow
kind: page
updated: 2026-07-09
---

Four features extending `scripts/.config/scripts/tmux/wb.sh`, scoped via
several decision-buffer rounds and one `ce-plan`, then built and tested
end-to-end. This page is the source; edit `docs/pr1-wb-workbench-recap.md`,
not the rendered `.html`.

**Roadmap:** PR #1 (this is the detail page) · **Branch:** `feat/wb-workbench-extensions` → `development` · **PR:** [#14](https://github.com/jetnoli-sportable/dotfiles/pull/14) · **Plan:** `docs/plans/2026-07-08-001-feat-wb-workbench-extensions-plan.md`

## What shipped

| Unit | What it does | Verify |
|---|---|---|
| U1 | `paused` status + `closed:` field | `wb done` stamps `closed:`; `wb board` ranks `paused` between `review` and `planned` |
| U2 | `wb pause [<session>]` + picker keybind `p` | Status flips to `paused`, worktree AND session both survive. `wb done` no longer kills the session either |
| U3 | `wb resume <task>` | Fuzzy-matches a task by repo--slug substring, recreates worktree+session via `cmd_new`'s existing idempotent path |
| U4/U5 | `wb board --html` → `logs/board.html` | 6 status tabs (All / In Progress / Upcoming / Paused / Deferred / Unclassified) × 2 timeline windows, CSS-only switching, live-session badges, untracked worktrees surfaced under Unclassified |
| U6 | `wb reconcile` | Detects orphaned worktrees and tasks with a missing worktree, cross-checks GitHub merge status per branch |
| U7 | `wb reconcile --review` / `--apply` | Persistent review doc, six checkbox actions per finding, two-phase confirm for merge survivor selection |

## Findings worth keeping

**A `head -1` in a pipeline can silently crash a `set -o pipefail` script
on real data even when every test passes.** `/board`'s detail-section
extraction used `wb_board_section ... | sed ... | head -1` to grab a
task's first Plan/Done line. Every test fixture had single-line sections,
so `head` never got to truncate early — no `SIGPIPE`, tests green. Real
task files have multi-line sections; `head` closing the pipe after line 1
sent `SIGPIPE` to the writer still producing lines 2+, and `pipefail`
turned that into a script-ending failure the moment `wb board --html` ran
against actual data. Fixed by capturing the section fully first, then
extracting the first non-blank line with a here-string loop — no live
process left to signal once it breaks early. Same shape as a real bug, not
a hypothetical: this class of "pipe truncation under `pipefail`" bug is
invisible to tests built from short fixtures.

**Bash's `${var/pattern/replacement}` treats an unescaped `&` in the
replacement as a backreference to the match — same as `sed`.**
`${s//</&lt;}` doesn't produce `&lt;`; it produces `<lt;` (the matched `<`,
followed by literal `lt;`), because `&` means "insert what matched."
`wb_board_html_escape`'s HTML-entity escaping silently produced broken
markup until a test with an actual `<`/`&` in a task title caught it.
Fixed with `\&` to force a literal ampersand.

**"Merge with task" needed a design not fully specified anywhere.** The
plan called for an explicit, pre-checked survivor choice instead of a
silent rule — but the target task isn't known until the user names it in
the same review doc being generated, so nothing can pre-compute a default
at generation time. Resolved with a two-phase confirm: the first `--apply`
that sees a named merge target with no survivor choice yet appends paired
sub-checkboxes (most-recently-active pre-checked) and reopens instead of
merging blind — the same append-then-reopen shape `wb done`'s own Sweep
flow already uses for gitignored-file survival, not a new pattern.

## Test / verify it yourself

- [ ] **`wb pause` a live session** — confirm status flips to `paused`,
      the worktree directory still exists, and the tmux session is still
      attached.
- [ ] **`wb done` a live session** — confirm the worktree is removed and
      status flips to `done`, but the tmux session survives (this changed
      from before — it used to kill the session).
- [ ] **`wb resume <fragment>`** on a task whose worktree you've removed
      by hand — confirm it comes back.
- [ ] **`wb board --html`**, then open `logs/board.html` — click through
      all 6 tabs and the Today/This week toggle; confirm live-session
      badges appear only on rows with an actual attached session, and any
      untracked worktree shows up under Unclassified.
- [ ] **`wb reconcile --review`**, then check a few boxes and save —
      confirm re-running `--review` before applying warns instead of
      overwriting your in-progress choices.
- [ ] **`wb reconcile --apply`** — confirm checked actions run (remove /
      create a task / attach) and a checked "merge with task" reopens the
      doc with a pre-picked survivor instead of merging immediately.

## What's NOT done yet

- **`Deferred` tab renders empty** — reserved for a future `pending`
  status once `/park` items become task-store entries in their own right;
  not this PR.
- **Same-commit duplicate-flagging** for `wb reconcile` (e.g. recognizing
  that an orphaned worktree and an existing task are actually the same
  work) — still requires the user to manually name the merge target.
- **Per-task HTML files, transcript-to-task matching, parent/sub-task
  artifact rollup** — all explicitly deferred in the plan's Scope
  Boundaries.

## Next steps

- **Review and merge [PR #14](https://github.com/jetnoli-sportable/dotfiles/pull/14)** once you've walked the checklist above.
- Per the session's roadmap sequencing: Hub v0 (meta-documentation bundle)
  is next, followed by the sub-task/parent-child relationship
  `/handoff` surfaced as a real gap, then `/handoff` itself.
