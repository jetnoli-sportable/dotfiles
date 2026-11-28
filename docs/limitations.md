---
title: Limitations — standing, by-design workflow constraints
status: current
tile: Known gaps and caveats that explain otherwise-surprising behavior, one place.
group: workflow
kind: page
updated: 2026-11-28
---

Standing, by-design properties of the workflow — not bugs, not deferred
decisions. Each entry explains behavior that would otherwise be surprising,
plus what would actually make it worth revisiting. Deferred *decisions*
(things deliberately left unresolved rather than accepted as-is) stay on
[Open Questions](archive/roadmap-open-questions.html); this page is for the ones
that are settled as "acceptable for now."

## GPaste's GNOME Shell coupling

9g's clipboard-history config (`<Ctrl><Shift>G`) is a GNOME Shell extension
with no Sway equivalent — it isn't a config tweak away from the owner's
eventual Sway direction, it's a re-pick of the whole tool. **Revisit when**
the Sway migration is actually scheduled. Detail: [9g recap](archive/9g-gpaste-recap.html).

## Credential guard is warn-only, not a hard block

The [`wb` design](archive/roadmap-wb-design.html)'s credential guard is a
dismissible warning in the close-out review buffer, not an enforced block,
and it only matches filenames — it doesn't scan file *contents* for
secret-shaped strings. It was accepted while the task store was local-only
and single-user. The store has had a private remote since 2026-07-10, so
that trigger has fired and this needs a fresh look. **Revisit when**
next touching the close-out buffer, or a credential-shaped filename slips
past the denylist.

## GPaste's clipboard history has no secrets policy

Clipboard history persists to disk indefinitely (`save-history true`) with
no expiry or secret-detection — copying a token or password puts it in the
history store with no automatic cleanup. Shipped as-is for a personal
single-user machine. **Revisit when** it turns out to be a real problem in
practice (e.g. add a max-age prune or a "don't persist this clip" gesture).
Detail: [9g recap](archive/9g-gpaste-recap.html).

## Personal/employer boundary rule (interim state)

The classification rule for the task store and every aggregation surface
is deliberately the *last* follow-up decision in the whole push — made
only once everything else is in place, not before. Interim guardrails:
the task store's remote is private;
generated `INDEX`/`HUB` output carries a minimal work-reference redaction
guard. Full writeup:
[Open Questions](archive/roadmap-open-questions.html#personalemployer-boundary-rule-the-final-follow-up).

## Task-store schema migration (resolved)

Resolved. Every task file has been on the dossier layout since 2026-11-08
(`layout: dossier`, records in `dossiers/<stem>/`), and `wb new` and the
other seeding paths backfill blank schema keys. The one-off converter,
`wb migrate`, was removed on 2026-11-28 once nothing was left to convert.

## Roadmap anchor/link integrity (moot)

`docs/roadmap.md` was retired on 2026-11-28 and no longer changes, so its
hand-typed `id="detail-<slug>"` anchors can no longer drift. The last check,
on 2026-07-14, found 34 ids, 7 hrefs, zero orphans and zero duplicates.
