# quick-wins — learnings ratchet

Append-only. One dated line per calibration observation. Read at the top of
every run (SKILL.md step 1), written at the end of any run that acted (step 7).
This is how the skill's sense of "actually quick" improves with use: each run
that acts leaves behind whether its prediction held.

Format: `YYYY-MM-DD — observation — source`. When a mis-classification *shape*
recurs, graduate it from a line here into a `thresholds.md` knob or a clause in
SKILL.md's classifier, and note that you did.

---

## 2026-08-24 (seed — the originating calibration)

These six `be--monorepo` state-management defects are the classifier's honesty
check. They are the reference calibration; do not let a future run drift off
them without a deliberate reason.

- 2026-08-24 — `database_sink.go doUpdate` missing early-return is the archetypal
  QUICK-WIN: one line, and the sibling `doCreate` had already settled the shape,
  so there was no open "how". Shape-already-settled is the strongest quick signal.
  — originating /ce-simplify-code pass
- 2026-08-24 — The SW-6513 item was small *and* wrong to do here: it belonged to
  another PR's Jira, so acting would have silently closed someone else's ticket.
  "Small" never overrides ownership — ownership is a first-class axis, not a tie-
  breaker. — originating session
- 2026-08-24 — Four defects that look tractable were NEEDS-A-PLAN because each hid
  a decision, not a diff: the rugby nil-interface (the fix *is* a design choice),
  `TimeCorrector` lock granularity (hot-path concurrency), a double-persist
  semantic question, and a shelved delete-or-wire call. Failure signal: if a run
  ever calls the nil-interface or the `TimeCorrector` mutex "quick," the
  classifier has drifted. — originating session
- 2026-08-24 — General shape: "small diff" and "quick win" are not the same
  predicate. The disqualifier that catches the most false positives is *an open
  implementation choice* — if you'd have to pick between two reasonable
  approaches, it needs a plan no matter how few lines it is. — design of this skill

## 2026-08-24 (first run against the live store — ~80 planned tasks + 50 ledger items)

- 2026-08-24 — CROSS-REPO ACTION BOUNDARY: a quick-win is classified
  repo-agnostically, but nearly all genuine quick-wins in the store were in
  `be--monorepo`/`frontend` while the run happened from a `dotfiles` session.
  You cannot edit another repo from the wrong worktree. Only current-repo items
  are "do now here"; cross-repo picks route via `/handoff`. Folded into SKILL.md
  step 6 + the auto-lane gate the same day. — first run
- 2026-08-24 — Top genuine quick-win found: `frontend--pin-parentid-in-event-put-tests`
  (already tagged quick-win) — two one-line test assertions in named files,
  fixtures already supply the value, no depends_on, ownership none. High
  confidence; not auto-laned only because it is cross-repo from a dotfiles session.
- 2026-08-24 — `dotfiles--fix-wb-new-planned-depends-on-body` classified
  QUICK-WIN (medium conf): fix direction fully specified, single file (wb.sh),
  but touches a 5600-line script + needs a test, so not a one-liner → surface
  for a pick, don't auto-lane. Notable: it fixes the very verb this skill uses
  to create tasks.
- 2026-08-24 — `be--monorepo--download-files-nonfinite-cell-guard` is the
  archetype of "small but confirm-first": the fix is 3 lines OR a comment
  depending on a bounded reachability check. QUICK-WIN medium conf — a bounded
  factual confirm is not the same as an open implementation choice, so it stays
  a quick-win, but the confirm keeps it out of the auto-lane.
- 2026-08-24 — Correctly declined as NEEDS-A-PLAN despite small-looking titles:
  `exit-pitch-gridiron-exit-cell-renders-zero` (open "why nil for 221/224?"
  investigation gates one-line-vs-plumbing), `fix-check-docs-hook-missing-dirs`
  (delete-vs-fix decision first), `claude-working-stale-on-crash` (unconfirmed
  assumption + touches global settings.json). The "answer this before fixing"
  section is a reliable NEEDS-A-PLAN signal.
- 2026-08-24 — Ledger↔task-store dedup is real and necessary: several open
  ledger items are already promoted to planned tasks (e.g. the 2026-08-19
  "revoke laptop tokens" ledger line == `be--monorepo--revoke-laptop-tokens-on-unlink`;
  the CSV formula-injection line == `customer-download-files-csv-injection-guard`).
  Step-3 reconciliation must run before classifying or the shortlist double-counts.
- 2026-08-24 — Honesty check PASSED: applied to the six state-management
  defects the classifier yields 1 QUICK-WIN (doUpdate early-return), 1
  OWNED-ELSEWHERE (SW-6513), 4 NEEDS-A-PLAN (rugby nil-interface, TimeCorrector
  mutex, double-persist, delete-or-wire). It did NOT call the nil-interface or
  the mutex quick. — calibration
