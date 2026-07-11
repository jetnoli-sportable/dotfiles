---
title: "wb done --close: opt-in session kill - Plan"
type: feat
date: 2026-07-11
origin: ~/code/tasks/dotfiles--feat-wb-done-close.md (central task store, separate repo)
product_contract_source: ce-plan-bootstrap
artifact_contract: ce-unified-plan/v1
artifact_readiness: implementation-ready
execution: code
---

# wb done --close: opt-in session kill, default for the picker's ctrl+x

## Summary

Add an opt-in `--close` flag to `wb done` (`cmd_done`,
`scripts/.config/scripts/tmux/wb.sh:1461`) that kills the tmux session after a
successful wind-down. Without the flag, behavior is unchanged (session
survives). Wire the picker's `ctrl-x` bind on task rows — the only caller that
already implies "I'm done with this, close it out" — to pass `--close`.

### Problem Frame

`wb done` used to always kill the tmux session on wind-down. That was
deliberately removed when `wb pause` shipped (`cmd_pause`,
`scripts/.config/scripts/tmux/wb.sh:805`; `docs/roadmap.md:62`: "Also stopped
`wb done` from killing the tmux session — same instruction, both wind-down
paths") because the user wants windows/sessions to persist through wind-down
by default. But the picker's `ctrl-x` on a task row (`_ctrl_x`,
`scripts/.config/scripts/tmux/wb.sh:2046-2053`) still calls plain `cmd_done`
today, so pressing it leaves a stale, done session sitting in the picker with
no one-keystroke way to also close it. This plan makes the kill an explicit,
named opt-in rather than reverting the earlier decision.

### Requirements

- R1. `cmd_done` accepts a `--close` flag (any position, alongside the
  existing optional `<session>` positional). When present, after the
  existing wind-down (dirty check, sweep, worktree removal, frontmatter
  flip) completes successfully, kill the tmux session too.
- R2. Without `--close`, `cmd_done`'s behavior is byte-for-byte unchanged —
  the session survives wind-down, exactly as today.
- R3. The picker's `ctrl-x` bind on a task row (`_ctrl_x`'s `task)` case)
  calls the `--close` variant, so ctrl-x's task-row behavior becomes "mark
  done and close the session" in one keystroke.
- R4. The distinction between `wb done`'s default (session survives) and
  `--close` (session killed) is legible both in code (a comment at the
  gating conditional, mirroring `cmd_pause`'s existing rationale comment)
  and in user-facing help text (the top-of-file usage banner and the
  picker's footer hint).

### Scope Boundaries

- Not a revert of the `wb pause`-era change — `wb done`'s default stays
  session-preserving. `--close` is additive.
- No change to `wb pause`, `_ctrl_x`'s `repo)`/`agent)` cases, or any other
  wind-down path.
- No change to the sweep/dossier/dirty-check machinery inside `cmd_done` —
  `--close` only adds a final, conditional kill after that machinery
  finishes.
- This is the only lane touching `wb.sh` right now (`feat/handoff-v1` is
  hard-forbidden from it; `feat/hub-v0` is docs/config only) — diff stays
  scoped to `cmd_done`, `_ctrl_x`, the usage banner, the picker hint, and
  the test files listed below.

---

## Planning Contract

### Key Technical Decisions

- **Flag parsing mirrors `cmd_new`'s index/shift `case` loop, not a
  single-token `for`.** `cmd_done` currently reads its one optional
  positional as `local session="${1:-}"` directly. Introducing a `--close`
  boolean flag that can appear before, after, or without the session
  argument needs the same order-independent parser `cmd_new` already uses
  for `--agent`/`--parent` (`scripts/.config/scripts/tmux/wb.sh:268-280`) —
  collect recognized flags into a variable, everything else into a
  positional array, so `wb done --close`, `wb done SESSION --close`, and
  `wb done --close SESSION` all resolve the same way.
- **The kill happens last, after every existing side effect, and is
  best-effort (`|| true`).** By the time `--close` fires, the dirty check,
  sweep, worktree removal, and frontmatter flip have already succeeded and
  been echoed — those are the state changes that matter and must not be
  rolled back or masked by a kill failure. `wb.sh` runs under `set -euo
  pipefail`; killing a session that's already gone (a race, or a caller
  passing a stale name) would otherwise abort the script after the real
  work is done and reported. `|| true` on the kill call keeps that failure
  silent and non-fatal, matching the standing convention of not
  hard-failing on cleanup-after-the-fact.
- **`wb-schema.test.sh`'s existing regression guard
  (scripts/.config/scripts/tmux/tests/wb-schema.test.sh:51-65) is updated,
  not left as-is.** That test does a literal source-text grep for `tmux
  kill-session` anywhere inside `cmd_done`'s function body and fails if
  found — it was written to lock in the `wb pause`-era removal. Adding a
  gated kill call inside `cmd_done` makes that blanket string match a false
  positive the moment `--close` exists, even though the default (no-flag)
  behavior it was actually guarding is preserved. The assertion is
  rewritten to check the real invariant: a `tmux kill-session` call exists
  in the body, but only reachable when the close flag is set (grepped as
  gated behind the flag variable, not bare). This is in-scope, not creep —
  it's the same function body this plan changes and the same behavioral
  contract this plan is required to preserve.
- **New dedicated `wb-done.test.sh`, not more schema-file assertions.**
  `cmd_done` has never had a live-session/live-worktree behavioral test
  (today's schema-file coverage is source-text only, with a comment
  explicitly noting full exercise was "disproportionate to unit-test
  here"). The task's own Testing section asks for real assertions —
  session alive after plain `wb done`, killed after `wb done --close` — so
  this plan adds the real fixture-backed test the one-file-per-feature
  convention calls for (`wb-pause.test.sh`, `wb-parent-child.test.sh`),
  combining `wb-pause.test.sh`'s real-tmux-session fixture with
  `wb-reconcile.test.sh`'s real-git-worktree fixture (`git init` + `git
  worktree add`), since `cmd_done` — unlike `cmd_pause` — actually removes
  the worktree.
- **The new test stubs `wb_open_buffer`.** `cmd_done` unconditionally calls
  `wb_open_buffer` (scripts/.config/scripts/tmux/wb.sh:834-844), which opens
  a real `nvim` when `$TMUX` is unset — exactly the non-interactive test
  environment here. `wb-reconcile-review.test.sh:84` already establishes the
  fix (`wb_open_buffer() { :; }` after sourcing `wb.sh`); the new test
  follows the same convention rather than rediscovering it.
- **Picker hint text gets a minimal wording tweak, not a redesign.** The
  footer hint (`wb_status_line`,
  scripts/.config/scripts/tmux/wb.sh:1944-1953) currently reads `ctrl-x
  done/kill` — generic across task/repo/agent rows. Since task-row ctrl-x
  now also closes the session, the hint changes to `ctrl-x done+close/kill`
  so the picker's own help text doesn't silently go stale, per R4.
- **The self-resolve-plus-`--close` path (no session arg, run from inside
  the session being closed) is verified manually, not by an automated
  fixture assertion.** `tmux kill-session` on the pane's own session sends
  SIGHUP to whatever is running in that pane — confirmed directly against
  this repo's tmux — so the exact command substitution the rest of this
  suite relies on (`out="$(cmd_done ... 2>&1)"; rc=$?`, used throughout
  `wb-pause.test.sh`/`wb-schema.test.sh`) cannot survive being the thing
  that gets killed mid-capture; a caller can't reliably read output or an
  exit code back from a process that just SIGHUP'd itself. This combination
  is lower-risk than it looks despite being untested by fixture: the
  self-resolution logic (`tmux display-message -p '#S'`) is pre-existing
  and unchanged by this plan (R2), and the closing logic is already
  covered by U3's explicit-session scenarios — composing two
  independently-verified paths is not the same risk class as either one
  being untested alone. A `send-keys`-into-a-live-pane-plus-external-poll
  technique could simulate it, but that's a new fixture pattern this test
  suite has never needed before, disproportionate to add for one opt-in
  flag on top of pre-existing, already-relied-upon self-resolution
  behavior.

### Sequencing

U1 (the flag itself) has no dependency but is the prerequisite for U2 (the
picker wiring, which just passes the new flag). U3 (tests) depends on both —
it exercises the flag directly and, for the picker-wiring assertion, the
updated `_ctrl_x` body.

---

## Implementation Units

### U1. `cmd_done --close` flag

**Goal:** add an opt-in `--close` flag to `cmd_done` that kills the tmux
session after a successful wind-down, leaving the no-flag default unchanged.

**Requirements:** R1, R2, R4 (code-comment + usage-banner half).

**Dependencies:** none.

**Files:**
- `scripts/.config/scripts/tmux/wb.sh` (`cmd_done`, top-of-file usage
  banner)
- `scripts/.config/scripts/tmux/tests/wb-schema.test.sh` (update the stale
  regression-guard assertion)

**Approach:** replace `cmd_done`'s current `local session="${1:-}"` with an
index/shift `case` loop matching `cmd_new`'s (wb.sh:268-280): a `close=0`
flag flipped by `--close`, everything else collected into a positional
array, `session="${args[0]:-}"` read from that array afterward. At the very
end of `cmd_done` — after the existing worktree-removal, frontmatter-flip,
and follow-up-count echo lines (wb.sh:1578-1589) — add:
`[ "$close" -eq 1 ] && tmux kill-session -t "=$session" 2>/dev/null || true`.
Add a short comment at that line naming the `wb pause`-era decision it makes
opt-in (mirroring `cmd_pause`'s own comment at wb.sh:798-804), so a future
reader sees the "opt-in, not a revert" rationale in the same place as the
original removal's rationale. Update the top-of-file usage banner
(`wb.sh:7`) from `wb done [<session>]` to `wb done [--close]
[<session>]` with a one-clause note that `--close` also kills the session.

Rewrite the `wb-schema.test.sh:58-65` assertion block: instead of failing
whenever `tmux kill-session` appears anywhere in `cmd_done`'s body, assert
(a) the call exists, and (b) it's gated behind the close-flag variable
(e.g. a regex requiring the flag check immediately precedes `tmux
kill-session` on the same line/guard), keeping the original intent —
default behavior never kills — while allowing the new opt-in path.

**Test scenarios:**
- Happy path: `cmd_done SESSION` (no flag) against a clean fixture
  worktree — worktree removed, task file flips to `done`, tmux session
  still alive afterward.
- Happy path: `cmd_done SESSION --close` — same wind-down, plus the tmux
  session no longer exists afterward.
- Manual verification only (see the self-resolve note under Key Technical
  Decisions): `wb done --close`, no session arg, typed inside the target
  session, still closes it.
- Regression: dirty-worktree check, sweep-of-ignored-files flow, and the
  `done_block` source-text assertions for `status done` / `closed:` in
  `wb-schema.test.sh` are unaffected.
- Regression: the rewritten `wb-schema.test.sh` assertion still fails loud
  if a future edit reintroduces an *unconditional* kill-session call.

**Verification:** `bash scripts/.config/scripts/tmux/tests/wb-schema.test.sh`
passes; new scenarios also covered end-to-end by U3's `wb-done.test.sh`.

---

### U2. Picker: ctrl-x on a task row closes the session

**Goal:** make the picker's `ctrl-x` on a task row invoke `--close`, so one
keystroke both marks the task done and closes its session.

**Requirements:** R3, R4 (footer-hint half).

**Dependencies:** U1 (needs the flag to exist).

**Files:**
- `scripts/.config/scripts/tmux/wb.sh` (`_ctrl_x`, `wb_status_line`)

**Approach:** change `_ctrl_x`'s `task)` case (wb.sh:2049) from `cmd_done
"$session"` to `cmd_done "$session" --close`. No other case in `_ctrl_x`
changes. Update the footer hint string in `wb_status_line`
(wb.sh:1949) from `ctrl-x done/kill` to `ctrl-x done+close/kill` so the
picker's own help text reflects the new task-row behavior.

**Test scenarios:**
- Happy path: `_ctrl_x task SESSION ""` against a fixture ends the wind-down
  with the session killed (verifies the dispatch wiring, not just `cmd_done`
  in isolation).
- Regression: `_ctrl_x repo SESSION ""` and `_ctrl_x agent "" TARGET` are
  unchanged (still a raw session kill / pane kill respectively).
- Regression: the hint string change doesn't break
  `wb_status_line`'s existing `mode`/`ctx` branching (search-mode hint
  untouched).
- Manual smoke-check: pressing `ctrl-x` on a task row from inside a live
  picker session, including the case where that row is the picker's own
  hosting session — `become()` replaces the fzf process in place, so
  `_ctrl_x` (and the `tmux kill-session` it now reaches via `--close`) runs
  in whatever pane launched the picker.

**Verification:** `wb-done.test.sh` (U3) exercises the `_ctrl_x task` path
end-to-end via the Dockerfile runner; the own-session ctrl-x case above is
a manual smoke-check.

---

### U3. `wb-done.test.sh` — behavioral coverage

**Goal:** add the real, fixture-backed test the task's Testing section asks
for: plain `wb done` leaves the session alive, `wb done --close` kills it,
and the picker's `ctrl-x` path invokes the close variant.

**Requirements:** R1, R2, R3 (verification).

**Dependencies:** U1, U2.

**Files:**
- `scripts/.config/scripts/tmux/tests/wb-done.test.sh` (new)

**Approach:** follow `wb-pause.test.sh`'s structure (source `wb.sh`, `set +e`
to capture non-zero exits, a `fail=0`/`assert` harness, real throwaway tmux
sessions cleaned up via `trap`) combined with `wb-reconcile.test.sh`'s real
git fixture (`git init` + `git -c user.email=... -c user.name=... commit
--allow-empty` + `git worktree add`), since `cmd_done` removes the worktree
and needs a real one to remove. Set `TASKS_DIR`/`CODE_DIR` to fixture
directories, stub `wb_open_buffer() { :; }` right after sourcing (per
`wb-reconcile-review.test.sh:84`'s established pattern), and create one
clean (non-dirty) fixture worktree per scenario so the dirty-check guard
doesn't short-circuit the wind-down before it reaches `--close`. Run inside
the project's test Dockerfile
(`scripts/.config/scripts/tmux/tests/Dockerfile`) rather than the host shell
— `cmd_done` calls real `git worktree remove` and `tmux kill-session`, and
the sandboxed runner exists specifically to contain a repeat of the
2026-07-10 `CODE_DIR` incident this suite's own comment references.

**Test scenarios:**
- Happy path: `cmd_done "$SESSION"` (no flag) on a clean fixture worktree —
  exits 0, worktree gone, task file's `status:` is `done`, and
  `tmux has-session -t "=$SESSION"` still succeeds afterward.
- Happy path: `cmd_done "$SESSION2" --close` on a second clean fixture
  worktree/session — same wind-down succeeds, and `tmux has-session -t
  "=$SESSION2"` fails afterward (session gone).
- Integration: `_ctrl_x task "$SESSION3" ""` on a third fixture — ends with
  the session killed, proving the picker's dispatch (not just `cmd_done`
  called directly) takes the close path.
- Regression: a dirty fixture worktree still fails fast (non-zero exit,
  "is dirty" message) before any kill happens, `--close` or not — the
  existing safety check is untouched by this plan.
- Manual verification only, not part of the automated suite (see the
  self-resolve note under Key Technical Decisions): typing `wb done
  --close` inside the target session closes that session. Automating this
  would require a new `send-keys`-into-a-live-pane fixture technique this
  suite doesn't otherwise use, since the existing `out="$(...)"; rc=$?`
  capture pattern can't survive the capturing process being the one
  `tmux kill-session` SIGHUPs.

**Verification:** run inside the project's test Dockerfile (mandatory, not
optional — see the Verification Contract note below); prints `ALL PASS`.
The self-resolve scenario above is confirmed by hand once per change to
this area, not by the automated suite.

---

## Verification Contract

| Command | Applicability | Done signal |
|---|---|---|
| `bash scripts/.config/scripts/tmux/tests/wb-schema.test.sh` | U1 (regression + rewritten guard) | `ALL PASS` |
| `scripts/.config/scripts/tmux/tests/wb-done.test.sh` **run only via the Dockerfile runner below — never bare on the host** (it does real `git worktree remove` + `tmux kill-session`) | U1, U2, U3 | `ALL PASS` |
| `bash scripts/.config/scripts/tmux/tests/wb-pause.test.sh` | Regression only — no change intended | `ALL PASS` |
| Full suite via `scripts/.config/scripts/tmux/tests/Dockerfile` (`docker run --rm -v "$(pwd)":/repo:ro -w /repo wb-tests`, the image's default CMD loops every `*.test.sh`) | All units, sandboxed | every `*.test.sh` prints `ALL PASS` |

## Definition of Done

- `cmd_done` supports `--close` in any position alongside the optional
  session argument; the no-flag default is unchanged.
- `_ctrl_x`'s `task)` case passes `--close`; `repo)`/`agent)` cases
  untouched.
- Usage banner (wb.sh:7) and picker footer hint (wb.sh:1949) both name the
  distinction.
- `wb-schema.test.sh`'s regression guard checks the new gated invariant
  (kill exists, but only behind the flag) instead of a blanket "no kill at
  all" check.
- New `wb-done.test.sh` passes **when run via the Dockerfile runner**
  (never bare on the host), covering plain `wb done`, `wb done --close`,
  and the picker's `ctrl-x` task-row path; the self-resolve edge case is
  confirmed by hand (see U3).
- Every other `*.test.sh` passes via plain `bash` (unaffected by the
  Dockerfile requirement, which is specific to `wb-done.test.sh`'s
  destructive operations).

---

## Sources / Research

- `~/code/tasks/dotfiles--feat-wb-done-close.md` — origin task file (central
  task store), fully specifying this change.
- `scripts/.config/scripts/tmux/wb.sh:798-804` (`cmd_pause`'s rationale
  comment) and `docs/roadmap.md:62` — the deliberate history this plan
  makes opt-in rather than reverting.
- `scripts/.config/scripts/tmux/wb.sh:263-330` (`cmd_new`) — the
  order-independent flag-parsing convention U1 mirrors.
- `scripts/.config/scripts/tmux/wb.sh:1461-1590` (`cmd_done`),
  `:2043-2053` (`_ctrl_x`), `:1944-1953` (`wb_status_line`) — the exact
  code this plan changes.
- `scripts/.config/scripts/tmux/tests/wb-schema.test.sh:51-65` — the
  existing source-text regression guard this plan updates in place.
- `scripts/.config/scripts/tmux/tests/wb-pause.test.sh`,
  `wb-reconcile.test.sh:50-63`, `wb-reconcile-review.test.sh:84` — the
  real-tmux-session, real-git-worktree, and `wb_open_buffer` stub
  conventions U3's new test combines.
- `scripts/.config/scripts/tmux/tests/Dockerfile` — sandboxed test runner;
  its own comment documents the 2026-07-10 `CODE_DIR` incident this plan's
  worktree-removing test must run inside, not against the host.
