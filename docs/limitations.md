---
title: Limitations — standing, by-design workflow constraints
status: current
tile: Known gaps and caveats that explain otherwise-surprising behavior, one place.
group: roadmap
kind: page
updated: 2026-07-14
---

Standing, by-design properties of the workflow — not bugs, not deferred
decisions. Each entry explains behavior that would otherwise be surprising,
plus what would actually make it worth revisiting. Deferred *decisions*
(things deliberately left unresolved rather than accepted as-is) stay on
[Open Questions](roadmap-open-questions.html); this page is for the ones
that are settled as "acceptable for now."

## GPaste's GNOME Shell coupling

9g's clipboard-history config (`<Ctrl><Shift>G`) is a GNOME Shell extension
with no Sway equivalent — it isn't a config tweak away from the owner's
eventual Sway direction, it's a re-pick of the whole tool. **Revisit when**
the Sway migration is actually scheduled. Detail: [9g recap](9g-gpaste-recap.html).

## Credential guard is warn-only, not a hard block

The [`wb` design](roadmap-wb-design.html)'s credential guard is a
dismissible warning in the close-out review buffer, not an enforced block,
and it only matches filenames — it doesn't scan file *contents* for
secret-shaped strings. Acceptable while the task store stays local-only
and single-user. **Revisit when** the store ever gets a remote, or a
credential-shaped filename slips past the denylist.

## GPaste's clipboard history has no secrets policy

Clipboard history persists to disk indefinitely (`save-history true`) with
no expiry or secret-detection — copying a token or password puts it in the
history store with no automatic cleanup. Shipped as-is for a personal
single-user machine. **Revisit when** it turns out to be a real problem in
practice (e.g. add a max-age prune or a "don't persist this clip" gesture).
Detail: [9g recap](9g-gpaste-recap.html).

## Personal/employer boundary rule (interim state)

The classification rule for the task store and every aggregation surface
is deliberately the *last* follow-up decision in the whole push — made
only once everything else is in place, not before. Interim guardrails:
the task store gets no remote; generated `INDEX`/`HUB` output carries a
minimal work-reference redaction guard. Full writeup:
[Open Questions](roadmap-open-questions.html#personalemployer-boundary-rule-the-final-follow-up).

## Task-store schema migration is incomplete

PR #17 (`fc95c63`) added the `parent:` field to `tasks/README.md` and
`TEMPLATE.md` and the task parent/child relationship is live — but the
one-time pass to bring *existing* task files up to that schema hasn't run.
As of 2026-07-10, only the two files that PR itself touched carry
`parent:`/`closed:`; the rest don't, and in-practice `status:` values
(`doing`, `planned`) already drift from the schema doc's stated
`open|paused|done`. Expect task files in `~/code/tasks` to look
inconsistent until that migration lands. **Revisit trigger:** see the
"Task-store schema migration" row on [the roadmap](roadmap.html).

## Roadmap anchor/link integrity is manually verified, not machine-checked

`docs/roadmap.md`'s reshape (PR #18) introduced hand-typed
`id="detail-<slug>"` anchors and `href="#detail-<slug>"` references in its
"At a glance" visual. Nothing in the docgen pipeline validates that every
href resolves to a matching id, or that ids stay unique — a `ce-code-review`
pass (testing + maintainability, independently) flagged this. Three edits
(PR #22, #26, #29) landed between the 2026-07-11 check and this one without
the re-check this entry itself prescribes; re-verified now, as of
**2026-07-14**: 34 ids, 7 hrefs, zero orphans, zero duplicates. A future
edit to that page could silently break one. **Revisit trigger:** next time
`docs/roadmap.md`'s anchor/link structure gets a substantive edit, manually
re-run the duplicate-id + href-resolution check before merging; build a real
docgen lint step if that manual check is ever skipped and something actually
breaks (see U9 in `docs/plans/2026-07-14-001-feat-hub-roadmap-refresh-plan.md`
for exactly that lint being added, closing the gap this entry describes).
