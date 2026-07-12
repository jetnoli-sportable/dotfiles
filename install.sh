#!/usr/bin/env bash
# New-machine bootstrap: symlink every stow package into $HOME and restore
# plugin state. Idempotent — safe to re-run after adding a package.
set -euo pipefail
cd "$(dirname "$0")"

command -v stow >/dev/null || sudo apt install -y stow

# Auto-regenerate the docs platform (docgen) on commits that touch its
# tracked inputs — see .githooks/pre-commit for what triggers it.
git config core.hooksPath .githooks

# -t "$HOME" is required: this repo lives at ~/code/dotfiles, so stow's
# default target (the parent directory) would be ~/code, not $HOME.
stow -t "$HOME" zsh git ohmyposh tmux scripts nvim ghostty

# claude needs --no-folding: ~/.claude/ holds live untracked state (projects/,
# todos/, parked-items ledger) that a folded dir-symlink would shadow.
stow --no-folding -t "$HOME" claude

# tmux plugins — tpm lives under the XDG tree (tmux.conf sets
# TMUX_PLUGIN_MANAGER_PATH accordingly); the rest install with prefix+I.
[ -d ~/.config/tmux/plugins/tpm ] || \
  git clone https://github.com/tmux-plugins/tpm ~/.config/tmux/plugins/tpm
echo "Open tmux and press <prefix> + I to install tmux plugins."

# nvim plugins restore to the committed lockfile
command -v nvim >/dev/null && nvim --headless "+Lazy! restore" +qa || true

# Correct + lock default browser MIME/scheme associations against Slack's
# xdg-settings bug re-hijacking text/html on every launch — see the script
# for details. Needs sudo (chattr +i); safe/expected to prompt here.
~/.config/scripts/setup/default-browser.sh

echo "Done. Start a new shell. Machine-local extras go in ~/.zshrc.local."
echo "Still needed by hand: fdfind, fzf, zoxide, oh-my-posh, lazygit, nvm/pyenv/tfenv as desired."
echo "Docs auto-regenerate on commit once ~/code/docgen is cloned (see docs/slice-5-recap.html)."
