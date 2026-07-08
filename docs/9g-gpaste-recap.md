---
title: 9g recap — GPaste clipboard-history manager
status: current
tile: GPaste configured, Ctrl+Shift+G opens history. What to verify yourself.
group: personal-workflow
kind: page
updated: 2026-07-08
---

GPaste configured as a Flycut-style clipboard-history manager, executed
exactly per the owner-authored runbook in `docs/roadmap.md` §9g. This page
is the source; edit `docs/9g-gpaste-recap.md`, not the rendered `.html`.

**Roadmap:** §9g (`docs/roadmap.md`) · **Branch:** `feat/gpaste-clipboard-setup` → `development`

## What we did

All 6 runbook steps, in order, each verified before moving to the next:

| # | Step | Result |
|---|---|---|
| 1 | Precondition check | `gpaste-client` present, daemon v45 responding — install/enable from before this task already took |
| 2 | Verify the engine | Two test clips added and confirmed in `gpaste-client history` |
| 3 | Discover real gsettings keys | `show-history`, `launch-ui`, and a third key `pop` — not in the runbook, see finding below |
| 4 | Configure via dconf | `show-history` → `<Ctrl><Shift>G`; `max-history-size` → 200; `images-support`/`save-history` confirmed `true` |
| 5 | Check shortcut conflicts | None found — checked `media-keys`, `wm.keybindings`, custom keybindings, and a full `dconf dump /` sweep |
| 6 | Export to dotfiles | `gpaste.dconf` written to repo root — **staged, not committed**, per the runbook's own instruction |

## Finding worth keeping: the `pop` key is not a paste action

Step 3's key discovery turned up a key the runbook didn't mention:
`org.gnome.GPaste pop` (default `<Ctrl><Alt>V`). Before assuming anything,
checked the actual schema (`/usr/share/glib-2.0/schemas/org.gnome.GPaste.gschema.xml`):

```
<key name="pop" type="s">
  <summary>The keyboard shortcut to delete the first element in history</summary>
```

`pop` **deletes** the most recent history entry — it isn't a paste shortcut
at all, despite the name and its `V`-shaped default suggesting otherwise.
Left untouched at its default. If this had been bound to something a future
"quick paste" shortcut collided with, the symptom would have been silent
data loss (history entries vanishing), not a paste failure — worth knowing
before anyone reaches for `pop` assuming it's a paste action.

`show-history` was confirmed correct by the same method: its schema summary
is literally "The keyboard shortcut to display the menu" — the actual
Flycut-style history picker this task wanted.

## Test / verify it yourself

- [ ] **Press `<Ctrl><Shift>G`** anywhere — confirm the GPaste history menu
      pops up.
- [ ] **Select an old entry** from the menu — confirm it pastes correctly
      wherever your cursor is.
- [ ] **Copy several things**, then check the history holds more than one
      (up to the new `max-history-size` of 200) — confirm images are
      captured too (`images-support` is on).
- [ ] **Check `gpaste.dconf`** (repo root, currently staged not committed)
      — confirm it matches what `dconf dump /org/gnome/GPaste/` shows live.
- [ ] **On a future machine**: `dconf load /org/gnome/GPaste/ < gpaste.dconf`
      restores this exact config.

## What's NOT done yet

- **Commit `gpaste.dconf`** — staged per the runbook's explicit "stage but
  do NOT commit unless asked" instruction. Say the word and it's committed
  + a PR opened.
- **Unify copy/paste** so terminal-level paste is never needed (roadmap 9g
  follow-up note) — deliberately out of scope for this task, tracked in
  §10 as its own design pass.
- **Window manager dependency** — this whole setup assumes GNOME Shell;
  revisit if/when the Sway migration (parked, no date) happens.

## Next steps

- **Confirm the shortcut works for you live**, then say the word to commit
  `gpaste.dconf` and open a PR.
- With 9f and 9g both done, the next roadmap items needing a pickup
  decision are slice 4b (gated on the 4a usage-window verdict, ~2026-07-14)
  and `/board`'s full HTML feature (`wb board` interim is already live).
