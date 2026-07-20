---
title: Shell & terminal setup
status: current
tile: zsh, Ghostty, oh-my-posh, git — what's configured and why.
group: start-here
kind: page
updated: 2026-07-07
---

The pieces of the stack that live *under* the workflow tooling. For every
alias, keybind, and script with its source line, use the INDEX
(`prefix+?` in tmux, or `docs/INDEX.md`); for the tmux/Claude tooling
itself, see the [wb guide](wb-guide.html) and the
[roadmap](roadmap.html)'s Origins section for why it was built.

## zsh — `zsh/.zshrc`

Prompt (oh-my-posh), zsh-vi-mode, zinit plugins (autosuggestions,
completions, syntax highlighting), zoxide, and the aliases/functions that
drive the rest of this stack — `s`, `N`, `ca`, `wb`, `pgh`, `note`, and
friends are all defined here. Every one of them is in the INDEX with its
line number and a one-liner; `prefix+?` previews the surrounding comment
context.

Machine-local overrides go in `~/.zshrc.local` (sourced last, lives
outside the repo).

## Ghostty — `ghostty/.config/ghostty/config`

Terminal emulator config, kept **alongside** GNOME Terminal rather than
replacing it — Ghostty is used for inline image support GNOME Terminal
lacks. Catppuccin Mocha palette, `MesloLGL Nerd Font`,
`minimum-contrast = 1.6`. Known limitation (see the decision record via
`prefix+?`): the grayscale-AA glyph rendering is softer than GNOME
Terminal's and isn't fixable via config — don't re-add render knobs
chasing this, it's been tried.

## oh-my-posh — `ohmyposh/.config/ohmyposh/zen.json`

The prompt theme (`zen` segment set), sourced from `.zshrc`.

## git — `git/.gitconfig`

Minimal: identity (`jetnoli-sportable`) and a `gh auth git-credential`
helper scoped separately for `github.com` and `gist.github.com`. No
aliases defined — if you're looking for a `git` shortcut and it's not in
`.zshrc`, it doesn't exist yet. For non-Sportable repos, `pgh` wraps `gh`
with the personal-account PAT from the keyring.

## nvim — `nvim/.config/nvim/`

Own git history, own docs: `nvim/.config/nvim/README.md` and
`instructions.md` (both indexed). The piece relevant to the workflow is
the `lua/claude-tmux/` bridge — `<leader>a` maps to grab/pick/follow
Claude's transcript into a buffer and reply from nvim; the full keymap
table lives in `nvim/.config/nvim/instructions.md`.
