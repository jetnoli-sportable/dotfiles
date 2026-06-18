# Dotfiles centralization + GNU Stow migration

A single reference for moving `zsh`, `oh-my-posh`, `tmux`, `nvim`, and the custom
tmux/Claude scripts into one `~/dotfiles` git repo, symlinked into place with GNU
Stow.

> Status of the environment as inventoried (2026-06-11):
>
> - **`stow` is NOT installed** → `sudo apt install stow` first.
> - **`~/.config/nvim` is already its own git repo** with real history (lazy.nvim,
>   the `claude-tmux` bridge, DAP, LSP). Don't clobber it — see §4.
> - A stale `~/temp-clone-dotfiles/` exists (Oct 2025 clone attempt). Verify and
>   remove once this migration lands.
> - `~/.config` itself is NOT a git repo. Good — we centralize selectively.

---

## 1. What we've built (context)

Recent work across these configs, so the doc captures the whole picture:

- **`claude-sessions.sh`** — fzf picker (`ca`) + live dashboard (`cad`, `prefix+a`)
  that lists every running Claude Code agent across all tmux sessions, classifies
  each as waiting/working/idle from the pane-title glyph (`✳` vs braille spinner),
  and jumps to it. Human-facing observe-and-jump tool.
- **`lib.sh`** — shared tmux helpers extracted from the scripts:
  `tmux_ensure_session`, `tmux_focus`, `tmux_attach_or_create`, `tmux_goto_pane`,
  `tmux_find_claude_pane`, plus `FD_BIN` (resolves `fdfind` vs `fd`).
- **`session.sh`** — repo sessionizer. Fixed: `fd`→`fdfind` resolution, anchored
  `^\.git$` discovery (old `.git` accidentally matched `.github/`), vendor-dir
  excludes, git-status `--preview`, clean Esc-cancel.
- **`notes.sh`** — daily notes in a single persistent `notes` session, one window
  per note (no more send-keys-into-a-running-editor bug, no per-day session sprawl).
- **`instructions.md`** — reference for the above (lives in `scripts/tmux/`).
- **nvim `lua/claude-tmux/` module** — the "Claude ⇄ tmux/nvim bridge": reads
  Claude session JSONL, renders markdown buffers, sends replies back, jumps to
  panes. References `~/.config/scripts/tmux/lib.sh` (`tmux_find_claude_pane`).
- **tmux.conf** — earlier Wayland fix (copy-mode pipes to `wl-copy`, not `xclip`).
- **Ideated, not built:** worktree-aware automatic window labelling (a
  `window-status-format` `#()` hook deriving the branch from each window's cwd).

---

## 2. What's in each config

### zsh — `~/.zshrc` (177 lines)

- **Plugin manager:** zinit (`$ZINIT_HOME` under `~/.local/share/zinit`, auto-cloned).
  Plugins: `zsh-vi-mode`, `zsh-autosuggestions`, `zsh-completions`,
  `zsh-syntax-highlighting`.
- **Prompt:** `oh-my-posh init zsh --config ~/.config/ohmyposh/zen.json` (line 39).
- **Tools wired:** `zoxide`, `fzf` (custom `FZF_DEFAULT_COMMAND` using `fd`), `nvm`
  (XDG path), `pyenv`, `tfenv`, gcloud SDK, npm completion, homebrew (if present).
- **Aliases:** `vim→nvim`, `fd→fdfind`, `lz→lazygit`, `ld→lazydocker`, and the
  script aliases `s` / `N` / `ca` / `cad` (+ `n` → a go-notes binary).
- **Machine-specific lines** (portability hazards): hardcoded `/home/jetnoli/.local/bin`
  (line 6), absolute gcloud SDK paths (lines 100, 103), `EDITOR=nvim`. See §6.

### oh-my-posh — `~/.config/ohmyposh/zen.json` (~1.7 KB, JSON)

- Custom Catppuccin-flavoured theme: OS icon · session · `agnoster_short` path ·
  git segment · prompt char. Single file, no runtime artifacts. Commit as-is.

### tmux — `~/.config/tmux/tmux.conf` (+ `plugins/`)

- Prefix `C-Space`; base-index 1; mouse on; Wayland clipboard; vi copy-mode;
  vim-tmux-navigator pane switching; catppuccin (frappe).
- **Keybinds:** `m`→session.sh, `a`→claude-sessions.sh, `N`/`M`→notes.sh,
  `g`→lazygit, `A`→lazydocker, `r`→reload.
- **tpm:** `set -g @plugin` for tpm / tmux-sensible / vim-tmux-navigator /
  catppuccin-tmux. `run '~/.tmux/plugins/tpm/tpm'` (line 113).
- **⚠ tpm path inconsistency:** tpm is _run_ from `~/.tmux/plugins/tpm`, but the
  other plugins are installed under `~/.config/tmux/plugins/`. No
  `TMUX_PLUGIN_MANAGER_PATH` is set. Consolidate during migration — see §5.
- **`plugins/` are tpm-cloned git repos → never commit them.**

### nvim — `~/.config/nvim/` (its own git repo)

- **Plugin manager:** lazy.nvim, bootstrapped in `lua/plugins/index.lua`. Installed
  plugins live in `~/.local/share/nvim/lazy/` (outside the config tree — not our
  concern to ignore). `lazy-lock.json` **is** committed (reproducible versions).
- **Layout:** `init.lua` → `lua/core` (remaps, autocommands, markdown paste),
  `lua/plugins` (specs + per-plugin `config/`), `lua/plugins/lsp` (gopls, ts_ls,
  lua_ls, clangd, bash, emmet, html, go-templ), `lua/snippets`, and
  `lua/claude-tmux/` (the bridge module).
- **Hardcoded paths inside it:** `~/.claude/projects` and
  `~/.config/scripts/tmux/lib.sh` (in `lua/claude-tmux/config.lua`) — both survive
  stow since the symlinked locations are unchanged.

### scripts — `~/.config/scripts/tmux/`

| File                 | Mode | Purpose                                                                 |
| -------------------- | ---- | ----------------------------------------------------------------------- |
| `lib.sh`             | 755  | Shared tmux helpers + `FD_BIN`; sourced by the others via `SCRIPT_DIR`. |
| `session.sh`         | 755  | Fuzzy-pick a repo under `~/code`, attach/create its session.            |
| `notes.sh`           | 755  | Daily/any note in nvim inside a persistent `notes` session.             |
| `claude-sessions.sh` | 755  | Overview + dashboard of all Claude agents; jump to one.                 |
| `instructions.md`    | 644  | Reference doc for the above.                                            |

All scripts source `lib.sh` via `SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"`
(portable). Only `$HOME/code`-relative paths inside (`~/code/notes`, `~/code/daemon`).

---

## 3. Target repo layout (one Stow package per tool)

Stow's model: the repo lives at `~/dotfiles`, you run `stow` from inside it, and
the **default target is the parent dir (`$HOME`)**. Each top-level dir is a
_package_ whose internal structure mirrors the path relative to `$HOME`.

```
~/dotfiles/
├── zsh/
│   └── .zshrc                              → ~/.zshrc
├── git/
│   └── .gitconfig                          → ~/.gitconfig
├── ohmyposh/
│   └── .config/ohmyposh/zen.json           → ~/.config/ohmyposh/zen.json
├── tmux/
│   └── .config/tmux/tmux.conf              → ~/.config/tmux/tmux.conf   (NOT plugins/)
├── scripts/
│   └── .config/scripts/tmux/*.sh + instructions.md
│                                           → ~/.config/scripts/tmux/...
├── nvim/
│   └── .config/nvim/                       → ~/.config/nvim  (git submodule — see §4)
├── .gitignore
├── install.sh                              (bootstrap for a new machine)
└── README.md                              (this doc, trimmed)
```

Then: `cd ~/dotfiles && stow zsh git ohmyposh tmux scripts nvim`.

Per-package (not one big package) so you can `stow`/`stow -D` each tool
independently and skip ones that don't apply on a given machine.

---

## 4. The nvim decision (it already has git history)

Because `~/.config/nvim` is its own repo, pick one — **recommended: git submodule**:

**A. Submodule (recommended — preserves history + independent versioning)**

1. Give the nvim repo a remote and push it (e.g. a `nvim-config` GitHub repo):
   `git -C ~/.config/nvim remote add origin <url> && git -C ~/.config/nvim push -u origin <branch>`
2. Move the working copy aside, then add it as a submodule **at the stow path**:
   ```bash
   mv ~/.config/nvim ~/.config/nvim.bak
   git -C ~/dotfiles submodule add <url> nvim/.config/nvim
   cd ~/dotfiles && stow nvim          # ~/.config/nvim → submodule checkout
   # verify, then rm -rf ~/.config/nvim.bak
   ```
   `stow nvim` symlinks `~/.config/nvim` to the submodule. nvim stays pushable on
   its own; `git -C ~/dotfiles submodule update --remote` pulls config updates.

**B. Absorb into the monorepo (simpler, one history)**

- Copy the files in (`nvim/.config/nvim/…`), commit, and keep `~/.config/nvim.bak`
  as the history archive (or `git subtree add` to graft history). One repo to
  manage, but nvim is no longer independently versioned.

Either way: nvim's installed plugins (`~/.local/share/nvim/lazy/`) are **outside**
the repo tree — nothing to ignore, just `:Lazy restore` on a new machine using the
committed `lazy-lock.json`.

---

## 5. `.gitignore` and the tpm plugin question

`~/dotfiles/.gitignore`:

```gitignore
# tpm-managed tmux plugins (reinstalled with prefix+I)
tmux/.config/tmux/plugins/

# editor/OS noise
*.swp
.DS_Store
```

**Resolve the tpm path inconsistency** (currently split between `~/.tmux/plugins`
and `~/.config/tmux/plugins`). Recommended: pin tpm to the XDG location so
everything is under one tree:

```tmux
# add near the top of tmux.conf, before the @plugin lines
set-environment -g TMUX_PLUGIN_MANAGER_PATH '~/.config/tmux/plugins'
run '~/.config/tmux/plugins/tpm/tpm'   # was ~/.tmux/plugins/tpm/tpm
```

Then on a new machine: `git clone https://github.com/tmux-plugins/tpm
~/.config/tmux/plugins/tpm` and `prefix + I` to install the rest. After this,
`~/.tmux/` can be removed.

---

## 6. Optional: make `.zshrc` portable

`.zshrc` has machine-specific lines (hardcoded `/home/jetnoli/.local/bin`, absolute
gcloud SDK paths). Keep the committed `.zshrc` generic and push host-specific bits
to a gitignored local file sourced at the end:

```zsh
# end of ~/.zshrc
[ -f ~/.zshrc.local ] && source ~/.zshrc.local
```

Put gcloud/pyenv/host PATH tweaks in `~/.zshrc.local` (gitignored). Optional — skip
if you only ever run one machine.

---

## 7. Migration steps

```bash
# 0. Prereqs
sudo apt install stow
mkdir -p ~/dotfiles && cd ~/dotfiles && git init

# 1. Create package dirs
mkdir -p zsh git ohmyposh/.config/ohmyposh \
         tmux/.config/tmux scripts/.config/scripts/tmux

# 2. MOVE real files into the repo (move-first avoids stow --adopt surprises).
#    Stow only creates a symlink when the target no longer exists.
mv ~/.zshrc                         zsh/.zshrc
mv ~/.gitconfig                     git/.gitconfig
mv ~/.config/ohmyposh/zen.json      ohmyposh/.config/ohmyposh/zen.json
mv ~/.config/tmux/tmux.conf         tmux/.config/tmux/tmux.conf
mv ~/.config/scripts/tmux/*.sh ~/.config/scripts/tmux/instructions.md \
                                    scripts/.config/scripts/tmux/

# 3. nvim — see §4 (submodule or absorb). Do this before stowing nvim.

# 4. .gitignore (see §5), then stow each package
printf 'tmux/.config/tmux/plugins/\n*.swp\n.DS_Store\n' > .gitignore
stow zsh git ohmyposh tmux scripts        # add: nvim   (after §4)

# 5. Verify symlinks point into ~/dotfiles
ls -l ~/.zshrc ~/.gitconfig ~/.config/ohmyposh/zen.json \
      ~/.config/tmux/tmux.conf ~/.config/scripts/tmux/session.sh ~/.config/nvim

# 6. Commit
git add -A && git commit -m "Centralize dotfiles + stow"
# git remote add origin <url> && git push -u origin main
```

**Conflict note:** if `stow <pkg>` reports a conflict, a real file still exists at
the target — move it into the package (or back it up) and re-run. Avoid
`stow --adopt` unless you understand it pulls the existing file _into_ the repo,
overwriting the repo's copy.

---

## 8. New-machine bootstrap (`install.sh`)

```bash
#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"

command -v stow >/dev/null || sudo apt install -y stow
git submodule update --init --recursive            # nvim, if submoduled

stow zsh git ohmyposh tmux scripts nvim

# tmux plugins
[ -d ~/.config/tmux/plugins/tpm ] || \
  git clone https://github.com/tmux-plugins/tpm ~/.config/tmux/plugins/tpm
echo "Open tmux and press <prefix> + I to install tmux plugins."

# nvim plugins restore to committed lockfile
command -v nvim >/dev/null && nvim --headless "+Lazy! restore" +qa || true

echo "Done. Start a new shell. Tools still needed: fdfind, fzf, zoxide, oh-my-posh, nvm/pyenv/tfenv as desired."
```

---

## 9. Verification checklist

- [ ] `ls -l ~/.zshrc` (and the others) shows `-> ~/dotfiles/...` symlinks.
- [ ] New shell: prompt renders (oh-my-posh), `s`/`ca`/`cad` aliases resolve.
- [ ] `tmux kill-server` then start tmux: reload clean, `prefix+a` opens the Claude
      picker, `prefix+m` the sessionizer; status bar themed (catppuccin).
- [ ] `nvim` launches, lazy.nvim loads, `:checkhealth` ok, claude-tmux module loads.
- [ ] `claude-sessions.sh` still lists agents (lib.sh resolved through the symlink).
- [ ] Repo is clean: `git -C ~/dotfiles status` shows no `plugins/` or installed
      plugin dirs tracked.
- [ ] (If submodule) `git -C ~/dotfiles submodule status` shows nvim pinned.

---

## 10. Optional: pick a terminal (Ghostty vs. alternatives)

**Verdict: any GPU/Wayland-native terminal is a good, low-risk fit — and because
your whole workflow lives in tmux, the choice is almost pure preference.** tmux owns
sessions/windows/panes/keybinds, so the terminal is just a renderer + font + colours;
swapping it disturbs nothing. The shared upside over **GNOME Terminal** (VTE, your
current daily driver): GPU/Wayland-native rendering, true 24-bit colour + undercurl
(nicer nvim diagnostics), Catppuccin themes that match your tmux/oh-my-posh, and a
single config file that stows cleanly.

> **Environment update (re-inventoried 2026-06-18):** the friction this section
> originally cited against Ghostty is **gone**. Ghostty **1.3.1 is already installed**
> (`/usr/bin/ghostty`) and is now **apt-installable** via PPA (`ghostty
1.3.1-0~ppa2`) — no snap, no `zig` build. The `xterm-ghostty` terminfo entry **is
> present locally** (the earlier "missing — verified" note is stale). The only
> remaining Ghostty caveat is the SSH-terminfo one below, which applies equally to
> kitty/alacritty/foot.

### Alternatives — all in the 24.04 apt repos (verified)

For a _terminal-is-just-a-renderer_ tmux user, the most minimal renderer is arguably
the best fit. All four below `apt install` cleanly on 24.04 (no snap/build) and
support truecolor + a single stowable config:

| Terminal      | apt version | Rendering                   | Splits/tabs           | Ligatures | Notes for this setup                                                                                                                                         |
| ------------- | ----------- | --------------------------- | --------------------- | --------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| **foot**      | 1.16.2      | Wayland-native (no GPU dep) | none                  | no        | Tiny, Wayland-only, fastest cold-start. Purest "renderer only" fit; pairs perfectly with your `wl-copy` setup. **No fallback if you ever use an X session.** |
| **alacritty** | 0.13.2      | GPU (OpenGL)                | none (tmux's job)     | no        | Minimalist, cross-platform, TOML config. Philosophically the closest match to "tmux owns everything."                                                        |
| **kitty**     | 0.32.2      | GPU                         | yes (unused)          | yes       | Mature, batteries-included, excellent Wayland + undercurl + image protocol. Heavier than you need, but rock-solid.                                           |
| **Ghostty**   | 1.3.1 (PPA) | GPU                         | yes (unused)          | yes       | Already installed. Best-in-class defaults, built-in Catppuccin. PPA not an official Ubuntu repo (trust/upkeep consideration).                                |
| **WezTerm**   | not in apt  | GPU                         | yes + **multiplexer** | yes       | Skip: its headline feature (built-in multiplexing) duplicates tmux, and it needs a PPA/build.                                                                |

**Recommendation:** since Ghostty is _already installed and working_ and its install
friction has evaporated, the lowest-effort path is to **keep Ghostty** and just stow
its config (below). If you'd rather lean into the minimalist "pure renderer"
philosophy, **foot** (Wayland-native, tiniest) or **alacritty** (cross-platform) are
the strongest swaps — both `apt install` in one line. Reach for **kitty** only if you
want the extra features (image protocol, etc.). The tmux truecolor/undercurl config
below is terminal-agnostic — only the `TERM` name in the override changes.

### Stow package

```
ghostty/.config/ghostty/config      → ~/.config/ghostty/config
```

Add `ghostty` to the `stow` line. The config is one file, no runtime artifacts.

### Suggested `~/.config/ghostty/config`

```ini
theme = catppuccin-frappe          # matches tmux (frappe) + oh-my-posh
font-family = <your Nerd Font>     # MUST be a Nerd Font — oh-my-posh/catppuccin use glyphs
font-size = 12
cursor-style = block
clipboard-read = allow             # Wayland clipboard (pairs with your wl-copy tmux binding)
clipboard-write = allow
# tmux owns splits/tabs/sessions — no need to configure Ghostty's own.
```

### tmux gotchas (the only real work)

Ghostty advertises `TERM=xterm-ghostty`. Your current
`terminal-overrides ",*256col*:Tc"` won't match it, so add explicit entries to
`tmux.conf` (keep `default-terminal` as `tmux-256color`):

```tmux
set -g  default-terminal "tmux-256color"
set -ga terminal-overrides ",xterm-ghostty:Tc"     # truecolor for Ghostty's TERM
# colored/undercurl underlines passthrough (nvim LSP)
set -as terminal-overrides ',*:Smulx=\E[4::%p1%dm'
set -as terminal-overrides ',*:Setulc=\E[58::2::%p1%{65536}%/%d::%p2%{256}%/%d::%p3%d m'
```

### Install + terminfo (Ubuntu 24.04, re-verified 2026-06-18)

- **Ghostty:** already installed (`/usr/bin/ghostty` 1.3.1) and apt-available via PPA
  (`ghostty 1.3.1-0~ppa2`) — no snap/zig needed. `xterm-ghostty` terminfo **is present
  locally**.
- **foot / alacritty / kitty:** `sudo apt install foot` (or `alacritty` / `kitty`).
  Each ships its own terminfo (`foot`, `alacritty`, `xterm-kitty`); none of those
  three are present locally yet, so they get installed with the package.
- **SSH-terminfo caveat (applies to ALL of them, not just Ghostty):** remote hosts
  won't have the custom terminfo → either copy it once
  (`infocmp -x $TERM | ssh HOST tic -x -`) or export `TERM=xterm-256color` for
  remote sessions. Without this, remote TUIs render garbled. (GNOME Terminal avoids
  this only because `xterm-256color` is universal.)

### Stow + rollout

Do the terminal swap **after** the dotfiles+stow migration lands, as its own small
package — not bundled into the same change. Keep GNOME Terminal installed as a
fallback until you've confirmed colours/undercurl/clipboard all behave inside tmux.
Whichever you pick, the config is a single file that stows the same way (swap the
`ghostty/` package dir for `foot/.config/foot/foot.ini`, `alacritty/.config/
alacritty/alacritty.toml`, or `kitty/.config/kitty/kitty.conf`).

---

## 11. Optional: window managers on Ubuntu

You're on **Ubuntu 24.04.3 / Wayland / `ubuntu:GNOME`** (Mutter as compositor). A
window manager is the layer _above_ tmux: tmux tiles panes **inside** a terminal;
the WM tiles **whole apps** (terminal vs. browser vs. Slack). **Because tmux already
does your in-terminal multiplexing, a full tiling WM is polish, not a transformation
— its only new job is keyboard-driven, gridded placement of top-level windows.** Pick
the tier that matches how much of GNOME you're willing to give up.

> **Stow angle:** Sway/Hyprland/niri configs are plain text files → clean new stow
> packages (`sway/.config/sway/config`, `waybar/.config/waybar/…`). GNOME extension
> settings live in **dconf, not files** → not stow-able; capture them with
> `dconf dump /org/gnome/shell/extensions/ > extensions.dconf` and reload with
> `dconf load` in `install.sh` instead.

### Tier 1 — Stay on GNOME, add tiling (recommended; lowest risk)

Keeps your entire session: Wayland clipboard (`wl-copy` binding intact), all apps,
the GNOME shell/network/screenshot conveniences, your login. You just add an
extension via **Extension Manager** (`sudo apt install gnome-shell-extension-manager`).

- **PaperWM** — scrollable tiling (windows in an infinite horizontal strip). Wayland-
  native on GNOME 46, very popular, keyboard-driven. The most "different" feel without
  leaving GNOME.
- **Forge** — i3-style automatic tiling tree with keyboard resize/move; actively
  maintained for Wayland GNOME. Closest to a real tiler while staying on GNOME.
- **Tactile** — minimal grid snapping (keyboard-driven layout zones). Lightest touch
  if you mostly want "throw the terminal to a half/quadrant."
- _(Skip **Pop Shell** — it's still effectively X11-oriented and flaky on stock GNOME
  46 Wayland.)_

Biggest ergonomic gain for near-zero risk — and reversible (toggle the extension off).

### Tier 2 — Sway (full tiling, Wayland-native, in apt)

`sudo apt install sway` (1.9 in 24.04). i3-compatible config syntax, Wayland-native,
**keeps your `wl-copy` clipboard**. This is the natural endgame for a keyboard-driven
tmux user who wants the WM to match the tmux philosophy (config-as-code, no mouse).

Cost: you leave the GNOME shell, so you rebuild the conveniences yourself —
status bar (**waybar**), launcher (**wofi/fuzzel**), notifications (**mako**),
screenshots (**grim/slurp**), idle/lock (**swayidle/swaylock**). All apt-installable,
all stow as plain configs. A coherent but real weekend project; log out of GNOME and
pick "Sway" at the GDM session chooser to try it without uninstalling anything.

### Tier 3 — Adventurous (not in 24.04 apt → PPA/build, more upkeep)

- **Hyprland** — dynamic tiling + animations; the flashy modern Wayland choice.
  Needs a PPA or source build and tracks fast-moving releases (more maintenance).
- **niri** — scrollable tiling as a standalone compositor (PaperWM's model without
  GNOME). Clean and modern; also not packaged for 24.04.

### Avoid: i3 (X11-only)

`i3` (4.23) is in apt and mature, **but it's Xorg-only** — running it drops you out of
Wayland, which **breaks your `wl-copy` tmux clipboard binding** (you'd revert to
`xclip`/`xsel`) and loses Wayland's fractional-scaling/input niceties. Sway is the
Wayland successor; prefer it over i3 on this machine.

### Recommendation

Since tmux already gives you splitting, start at **Tier 1 (PaperWM or Forge)** — the
big ergonomic win for whole-app management with near-zero risk and full reversibility.
Only graduate to **Sway** if you find yourself wanting the _entire_ desktop to be
keyboard-driven config-as-code and you're up for rebuilding the GNOME-shell bits.
Either way it's **out of scope for the stow migration itself** — land dotfiles first,
then treat the WM as a separate experiment.

---

## 12. Decisions to confirm before executing

1. **Repo location:** `~/dotfiles` (assumed) vs `~/code/dotfiles` (fits your
   `session.sh` discovery + `s` alias). I'd lean `~/code/dotfiles` so it shows up
   in your sessionizer.
2. **nvim:** submodule (recommended, §4-A) vs absorb (§4-B).
3. **tpm consolidation + `~/.zshrc.local` split:** do now (cleaner) or defer.
4. **The stale `~/temp-clone-dotfiles/`:** inspect for anything worth keeping, then
   remove.
5. **Terminal (§10):** keep the already-installed **Ghostty** (zero extra work) vs.
   swap to the minimalist **foot**/**alacritty** vs. stay on GNOME Terminal. Do it
   _after_ the stow migration regardless.
6. **Window manager (§11):** stay on GNOME + a tiling extension (**PaperWM/Forge**,
   recommended) vs. go full **Sway** vs. leave windowing as-is. Separate experiment
   from the dotfiles migration.

```

```
