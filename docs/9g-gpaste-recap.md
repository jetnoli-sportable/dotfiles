---
title: 9g recap — GPaste clipboard-history manager
status: current
tile: GPaste configured, Ctrl+Shift+G opens history. What to verify yourself.
group: personal-workflow
kind: page
updated: 2026-07-08
---

GPaste configured as a Flycut-style clipboard-history manager, executed
exactly per the owner-authored runbook below. This page is the source; edit
`docs/9g-gpaste-recap.md`, not the rendered `.html`. The full runbook lives
here now (moved from `docs/roadmap.md` during the 2026-07-08 roadmap
restructure) since it's the provenance record for a task that's done, not
an active plan.

**Roadmap:** 9g (superseded — this page is the detail) · **Branch:** `feat/gpaste-clipboard-setup` → `development`

## The owner-authored runbook (preserved verbatim)

> **Goal:** configure GPaste as a Flycut-style clipboard-history manager,
> settings captured in a dotfiles-friendly dconf file. Target: a keyboard
> shortcut that opens clipboard history to pick and paste an old clip.
> **Shortcut: `<Ctrl><Shift>G`** (owner call, 2026-07-07 review, Decision 1 —
> supersedes the earlier `<Ctrl><Shift>V` pick and the original
> `<Ctrl><Alt>V` spec draft before that. Confirmed real collision, not just a
> theoretical one: Ghostty ships `<Ctrl><Shift>V` as its built-in paste bind
> and this repo's `ghostty/.config/ghostty/config` never overrides it;
> GNOME custom shortcuts registered via `gsettings` intercept at the
> shell/compositor level before the combo ever reaches the focused terminal,
> so binding GPaste to `V` would have silently broken terminal paste
> repo-wide. `<Ctrl><Shift>G` is free.)

> **Window manager:** this whole runbook assumes GNOME Shell (GPaste's
> extension is a GNOME Shell extension). That's correct for now but not
> permanent: `logs/decisions/2026-06-18-window-manager.md` records the
> owner's intended direction as Sway, at a later, unscheduled date. No
> conflict today — just recording the pointer here so a future WM switch
> knows to revisit this dependency (GPaste's extension model doesn't carry
> over to Sway; a wl-clipboard-based history manager would replace it).
>
> 1. **Precondition check** — confirm the prior install/enable actually
>    took before configuring anything:
>    `which gpaste-client || echo "MISSING: gpaste-client not found"`
>    `gpaste-client daemon-version 2>/dev/null || echo "MISSING: daemon not responding"`
>    If either is missing: stop, report to the user. Do NOT reinstall or
>    restart gnome-shell on Wayland — ask the user to re-check instead.
> 2. **Verify the engine works** — `echo "test-clip-1" | gpaste-client add`,
>    same for a second clip, then `gpaste-client history` and confirm both
>    appear.
> 3. **Discover exact gsettings keys (version-safe)** — do not hardcode key
>    names from memory; run `gsettings list-recursively org.gnome.GPaste`
>    first and confirm real key names (expect `show-history`, `launch-ui`,
>    and sync/upload accelerators) before setting anything.
> 4. **Configure via dconf** — `show-history` is a scalar string key (type
>    `s`, confirmed via `gsettings range`), not a GVariant array — no
>    brackets:
>    `gsettings set org.gnome.GPaste show-history '<Ctrl><Shift>G'`.
>    Also: `max-history-size 200`, `images-support true`,
>    `save-history true`. Only set keys confirmed to exist in step 3; skip
>    and report any that differ.
> 5. **Check shortcut conflicts** before finalizing — inspect
>    `gsettings list-recursively org.gnome.settings-daemon.plugins.media-keys`
>    and `...org.gnome.desktop.wm.keybindings`. If `<Ctrl><Shift>G`
>    collides, warn the user and suggest an alternative — don't change it
>    without confirmation.
> 6. **Export to dotfiles** — `dconf dump /org/gnome/GPaste/ >
>    ~/dotfiles/gpaste.dconf` (adjust path to this repo's actual location,
>    `~/code/dotfiles`), show the restore command
>    (`dconf load /org/gnome/GPaste/ < .../gpaste.dconf`) for future
>    machines. If it's a git repo, stage but do NOT commit unless asked.
>
> **Constraints:** no gnome-shell restart, no reinstall — those steps are
> done. Wayland reserves some Super-key combos, but `<Ctrl><Shift>G` avoids
> that class of conflict; if a conflict shows up anyway in step 5 it's
> almost certainly a different app already owning that combo, not a bad
> install. Setting `show-history` via dconf takes effect on the running
> daemon live, no restart needed.
>
> **Final verification:** `gsettings get org.gnome.GPaste show-history` →
> expect `'<Ctrl><Shift>G'` (scalar string, not a list). Report what was
> configured, the active shortcut, and the dconf export path; ask the user
> to test the shortcut themselves and confirm the history popup appears.

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

- **Unify copy/paste** so terminal-level paste is never needed — deliberately
  out of scope for this task, tracked in `docs/roadmap.md`'s overview table
  as its own design pass.
- **Window manager dependency** — this whole setup assumes GNOME Shell;
  revisit if/when the Sway migration (parked, no date) happens.

## Next steps

- **Confirm the shortcut works for you live** — press `<Ctrl><Shift>G` and
  check the history menu appears.
- **Merge this PR** once you've walked the checklist above.
- With 9f (pending your review) and 9g both wrapped, the next roadmap items
  needing a pickup decision are slice 4b (gated on the 4a usage-window
  verdict, ~2026-07-14) and `/board`'s full HTML feature (`wb board`
  interim is already live).
