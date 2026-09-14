# review-page learnings

One dated line per entry, in Jet's own words, plus the spec/answers path —
appended whenever Jet flags a review page as unhelpful, confusing, or in need
of a contract change, in-session. See `SKILL.md`'s Learnings ledger section.
Copied from `decision-buffer/learnings.md` where the entry concerns this
mechanism specifically (originals left in place there); new entries from here
on go in this file.

- 2026-09-14 — Jet, on the day's third big buffer (audit of 100+ pieces):
  "using the nvim buffer for this feels odd, I think we need a better flow
  (one that uses an html page and sensible defaults -> but we need a way to
  ask questions here and possibly tie items together)." GENERAL signal:
  nvim buffers are right for choice/interview/short triage, wrong for
  50+-row reviews. Direction: an HTML review page (pre-selected defaults,
  per-row ask/note, group tag to tie rows, filters, Submit → answers.json +
  tmux wait-for signal) as a seventh shape; B1's weekly review inherits it.
  This is the entry that led to review-page existing at all.
- 2026-09-14 — review-page v1 first run (piece audit, 157 rows): Jet
  reviewed everything but 80 rows read as untouched because agreeing with
  the pre-selected default required no click. Jet: "I thought I did them
  all." Fix shipped same day: per-row Agree ✓ (a / A), live untouched badge
  + submit confirm, spec flag accept_defaults_default. Rule: a default the
  user agrees with must be one explicit click, never inferred from
  silence — but silence must also be impossible to miss.
- 2026-09-14 — contract change, same day, after the above: Jet: "I think we
  can assume in this flow that no action means okay unless I add a note in
  the questions for agents stating otherwise." This *reverses* the previous
  entry's "silence is never consent" framing for review-page specifically
  (decision-buffer's nvim shapes keep the old rule) — no action on a row now
  means accept its suggestion; opt-out is a changed verdict, a row note, or
  the global questions box. `accept_defaults` now defaults to `true`
  (footer checkbox pre-ticked unless a spec sets
  `accept_defaults_default: false`); the submit warning only fires when the
  checkbox is off and rows are untouched. A row with no suggestion at all
  stays unresolved regardless — there's nothing to silently accept.
