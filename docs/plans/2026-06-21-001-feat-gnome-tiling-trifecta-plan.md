---
title: "feat: GNOME tiling trifecta (focus-or-launch + Forge tiling + workspace moves)"
status: active
date: 2026-06-21
type: feat
origin: logs/decisions/2026-06-18-window-manager.md
---

# feat: GNOME tiling trifecta (focus-or-launch + Forge tiling + workspace moves)

## Summary

Bring the **basic i3/AeroSpace workflow** to the existing Ubuntu 24.04 / Wayland / GNOME session **without switching to Sway** — keyboard-driven focus-or-launch, window tiling via the **Forge** extension, and move-window-to-workspace — and capture it all as a reproducible, version-controlled GNOME config in the dotfiles repo. Everything binds to `Super` (never `ctrl+hjkl`, which `vim-tmux-navigator` owns).

One stretch goal is honored (letter-addressed workspaces); one is **documented as not achievable on GNOME** (workspace-pinned-to-monitor) rather than faked — see Scope Boundaries.

---

## Problem Frame

GNOME gives whole-app management via the mouse and a numbered-workspace model; it does not ship i3-style keyboard tiling. The user wants the AeroSpace muscle memory they had on macOS — jump to an app, tile windows by keyboard, throw windows to workspaces — but Sway was assessed as overkill (full shell rebuild, and GNOME already handles the hybrid Intel+NVIDIA GPU and Wayland clipboard for free; see `origin`). GNOME + the Forge extension covers the trifecta while keeping the whole working session intact.

GNOME settings are not files — they live in **dconf**. So unlike the other stow packages, this config is captured as dconf dumps plus a load script, not a symlink (anticipated in the migration guide's WM note).

---

## Requirements

- **R1.** Focus-or-launch an app by keyboard; launch if not running, focus if it is.
- **R2.** Keyboard window tiling (focus + move tiles directionally).
- **R3.** Move the focused window to a chosen workspace by keyboard.
- **R4.** All bindings use `Super`; none collide with `ctrl+hjkl` (vim-tmux-navigator, `tmux/.config/tmux/tmux.conf`) or with each other.
- **R5.** The whole setup is reproducible from the repo on a fresh machine via one bootstrap step.
- **R6 (stretch).** Switch to / move windows to workspaces addressed by **letter** (A/S/D/F).
- **R7 (stretch, documented-infeasible).** Pin workspaces to specific monitors (AeroSpace model). See Scope Boundaries.

---

## Key Technical Decisions

- **Forge** is the tiler — i3-style auto-tiling, actively maintained for GNOME 46 Wayland. (Alternatives PaperWM/Tactile are a different interaction model; rejected for not matching the i3 muscle memory.)
- **Config-as-code via dconf dump/load, not stow symlink.** GNOME/Forge settings live in dconf; the `gnome/` package holds `.dconf` fragments + an idempotent `install.sh` that `dconf load`s them. This is the one package that intentionally breaks the pure-symlink stow model.
- **Modifier map (resolves the Super+number collision).** `Super+1..9` is already GNOME's `switch-to-application-N` (focus-or-launch by dock order) — so workspaces must NOT also use `Super+number`. The user's letter-workspace wish resolves this cleanly:

  | Binding | Action | Mechanism |
  |---|---|---|
  | `Super+1..9` | focus-or-launch app (dock order) | built-in `switch-to-application-N` |
  | `Super+h/j/k/l` | focus tile left/down/up/right | Forge |
  | `Super+Shift+h/j/k/l` | move tile | Forge |
  | `Super+A/S/D/F` | switch to workspace 1–4 | `wm.keybindings` (letter→numbered) |
  | `Super+Shift+A/S/D/F` | move window to workspace 1–4 | `wm.keybindings` |

  `ctrl+hjkl` stays reserved for tmux/vim. (R4)
- **Fixed workspaces for stable letter mapping.** Set `dynamic-workspaces=false` + `num-workspaces=4` so A/S/D/F address stable targets (GNOME has no *named* workspaces — letters map to numbers via keybind).

---

## Output Structure

```
gnome/
  install.sh                 # idempotent: installs Forge, loads all dconf fragments
  README.md                  # what this does + the one manual step
  dconf/
    01-launch.dconf          # dock favourites order + optional Super+letter app shortcuts
    02-forge.dconf           # Forge tiling keybinds (Super+hjkl / Super+Shift+hjkl)
    03-workspaces.dconf      # fixed workspaces + Super+letter switch/move
```

Tracked in git; **not** stow-symlinked (activation is `dconf load`, run by `install.sh`).

---

## Implementation Units

### U1. Install + enable the Forge extension

- **Goal:** Forge installed and enabled on GNOME 46 Wayland, reproducibly.
- **Requirements:** R2, R5
- **Dependencies:** none
- **Files:** `gnome/install.sh` (Forge-install step), `gnome/README.md`
- **Approach:** Prefer scripted install via the `gnome-extensions` CLI (46.0, confirmed present) — download the GNOME 46 release zip and `gnome-extensions install --force`, then enable. Document the **one manual fallback** (Extension Manager GUI) in README, since EGO installs sometimes need a Shell reload (`Alt+F2 r` on Xorg / re-login on Wayland).
- **Patterns to follow:** other bootstrap scripts under `scripts/.config/scripts/`.
- **Test scenarios:**
  - After running the install step, `gnome-extensions list --enabled` includes `forge@jmmaranan.com`.
  - Re-running `install.sh` is a no-op (idempotent) — already-installed Forge isn't reinstalled or errored.
- **Verification:** windows tile automatically after enabling; `gnome-extensions info forge@jmmaranan.com` shows ENABLED.

### U2. Focus-or-launch bindings (dock reorder + optional letter shortcuts)

- **Goal:** `Super+1..9` reliably focuses-or-launches the user's real apps; optional `Super+letter` for top apps.
- **Requirements:** R1, R4
- **Dependencies:** none
- **Files:** `gnome/dconf/01-launch.dconf`
- **Approach:** Reorder `org.gnome.shell favorite-apps` so target apps occupy positions 1–9 (Slack is currently at 12, unreachable). `switch-to-application-N` is already bound to `Super+N` — no new binding needed for the core requirement. Optionally add `media-keys custom-keybindings` for `Super+V`=Code etc.; document that letter shortcuts only *focus* (vs launch-new) for single-instance apps.
- **Test scenarios:**
  - `Super+1` focuses the app in favourites slot 1; pressing again with it focused is a no-op (stays focused), not a second launch.
  - With the target app closed, `Super+<n>` launches it.
  - `Test expectation: behavioural verification is manual (GNOME Shell keybinds); dconf fragment correctness covered by U6 load test.`
- **Verification:** all of the user's daily apps reachable within `Super+1..9`.

### U3. Forge tiling keybinds (Super+hjkl)

- **Goal:** directional focus + move of tiles on `Super+hjkl` / `Super+Shift+hjkl`, with zero `ctrl+hjkl` overlap.
- **Requirements:** R2, R4
- **Dependencies:** U1
- **Files:** `gnome/dconf/02-forge.dconf`
- **Approach:** Set Forge's keybindings under `org.gnome.shell.extensions.forge.keybindings` — `window-focus-{left,down,up,right}` → `Super+{h,j,k,l}`, `window-move-{...}` → `Super+Shift+{h,j,k,l}`. Explicitly clear any Forge default that would land on `ctrl+hjkl`.
- **Test scenarios:**
  - `Super+l` moves focus to the tile on the right; `Super+Shift+l` swaps the window rightward.
  - Inside a tmux/nvim pane, `ctrl+h/j/k/l` still navigates panes/splits (no WM interception). (R4)
  - `Test expectation: keybind behaviour is manual; fragment loads cleanly per U6.`
- **Verification:** tiling navigation works; tmux/vim navigation unaffected.

### U4. Workspace switch + move-to-workspace

- **Goal:** switch workspaces and throw the focused window to a workspace by keyboard.
- **Requirements:** R3, R4
- **Dependencies:** none
- **Files:** `gnome/dconf/03-workspaces.dconf`
- **Approach:** `dynamic-workspaces=false`, `num-workspaces=4`. Bind `org.gnome.desktop.wm.keybindings switch-to-workspace-{1..4}` and `move-to-workspace-{1..4}`. Core binding here is numeric/Shift+numeric is taken by apps — so this unit wires the **number-free** path and U5 layers the letters. (Keep number keys for apps; workspaces are letter-addressed.)
- **Test scenarios:**
  - Moving a window to workspace 2 then switching to workspace 2 shows the window there.
  - Switching away and back preserves window placement.
  - `Test expectation: manual behavioural check; fragment load covered by U6.`
- **Verification:** 4 fixed workspaces, keyboard switch + move both work.

### U5. Stretch — letter-addressed workspaces (Super+A/S/D/F)

- **Goal:** `Super+A/S/D/F` switch to workspaces 1–4; `Super+Shift+A/S/D/F` move the window there.
- **Requirements:** R6
- **Dependencies:** U4
- **Files:** `gnome/dconf/03-workspaces.dconf`
- **Approach:** Map the letters onto the numbered `switch-to-workspace-N` / `move-to-workspace-N` actions (GNOME has no named workspaces; the letter is purely the keybind). Mirrors the user's old AeroSpace `alt-a/s/d/f`.
- **Test scenarios:**
  - `Super+D` switches to workspace 3; `Super+Shift+D` moves the focused window to workspace 3.
  - Letters don't collide with Forge's `Super+hjkl` or app `Super+1..9`. (R4)
  - `Test expectation: manual behavioural check.`
- **Verification:** letter workspace switching matches AeroSpace muscle memory.

### U6. Bootstrap script + capture + docs

- **Goal:** one command applies the whole setup on a fresh machine; the repo holds the canonical dconf state.
- **Requirements:** R5
- **Dependencies:** U1–U5
- **Files:** `gnome/install.sh`, `gnome/README.md`, `gnome/dconf/*.dconf`
- **Approach:** `install.sh` = install Forge (U1) → `dconf load` each fragment into its subtree (`/org/gnome/shell/extensions/forge/`, `/org/gnome/desktop/wm/keybindings/`, etc.) → reorder favourites. Capture current good state via scoped `dconf dump <subtree>` into the fragments. Idempotent and re-runnable. README documents the single manual step (Forge enable may need a re-login on Wayland) and that this package is dconf-load, not stow-symlink.
- **Test scenarios:**
  - Fresh run on a clean dconf subtree reproduces all keybinds (spot-check 3 bindings via `gsettings get`).
  - Second run is a no-op / non-destructive.
  - `Covers R5.`
- **Verification:** `bash gnome/install.sh` from a clean state yields the full trifecta.

---

## Scope Boundaries

### In scope
The trifecta (R1–R3), Super-based bindings (R4), reproducible bootstrap (R5), letter workspaces (R6).

### Documented limitation — workspace-pinned-to-monitor is NOT achievable on GNOME (R7)
The user asked, as a stretch goal, for "workspaces that belong to certain desktops/monitors" (the AeroSpace model where workspace A always lives on monitor 2). **GNOME does not support this.** Its model is `workspaces-only-on-primary` (currently `true`) — workspaces span only the primary monitor; secondary monitors hold a fixed set of windows outside the workspace system. There is no per-monitor workspace set and no extension that reliably adds one on GNOME 46 Wayland. This is precisely the capability that standalone compositors (Sway, niri, AeroSpace) provide and GNOME does not. **If monitor-pinned workspaces becomes a hard requirement, the path is a compositor switch (Sway/niri), re-opening the parked decision in `origin` — not a GNOME workaround.**

### Deferred to follow-up work
- Per-app auto-assignment to workspaces (`assign`-style rules) — Forge has limited support; revisit if wanted.
- Capturing the GNOME config into the repo's top-level bootstrap once the `gnome/` package proves stable.

---

## Risks & Dependencies

- **GNOME/Forge version churn** — extension keybinding schema can change across GNOME releases; pin to the GNOME 46 Forge release and re-verify on upgrade.
- **dconf load is destructive within a subtree** — `dconf load /path/` replaces that subtree. Scope fragments narrowly and document, so a load doesn't wipe unrelated GNOME settings.
- **Wayland enable timing** — newly installed Shell extensions often need a re-login on Wayland before they activate; README must call this out so the bootstrap isn't seen as broken.

---

## Verification

End state: on a fresh login, `Super+1..9` focuses-or-launches apps, `Super+hjkl` tiles, `Super+A/S/D/F` drives workspaces, `ctrl+hjkl` is untouched inside tmux/vim, and `bash gnome/install.sh` reproduces it all from the repo.
