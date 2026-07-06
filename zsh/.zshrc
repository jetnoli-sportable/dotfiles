
# Set the directory we want to store zinit and plugins
ZINIT_HOME="${XDG_DATA_HOME:-${HOME}/.local/share}/zinit/zinit.git"
#. export XDG_CONFIG_HOME="${XDG_CONFIG_HOME:-~/.config}"
export XDG_CONFIG_HOME="$HOME/.config"
export PATH=$PATH:$HOME/.local/bin
export PATH=$PATH:/usr/local/go/bin
export PATH=$PATH:~/go/bin
export PATH=$PATH:/opt/nvim-linux-x86_64/bin
#export PATH=$PATH:$(go env GOPATH)/bin

# Download Zinit, if it's not there yet
if [ ! -d "$ZINIT_HOME" ]; then
   mkdir -p "$(dirname $ZINIT_HOME)"
   git clone https://github.com/zdharma-continuum/zinit.git "$ZINIT_HOME"
fi

if [[ -f "/opt/homebrew/bin/brew" ]] then
  eval "$(/opt/homebrew/bin/brew shellenv)"
fi

# Source/Load zinit
source "${ZINIT_HOME}/zinit.zsh"


# SET SHELL TO VIM MODE
# set -o vi
# zinit ice depth=1
zinit light jeffreytse/zsh-vi-mode

zvm_after_init() {
  bindkey '^y' autosuggest-accept
}
export VISUAL=nvim
export EDITOR=nvim


# THEMING CONFIG
eval "$(oh-my-posh init zsh --config ~/.config/ohmyposh/zen.json)"


# FZF CONFIG
# eval "$(fzf --zsh)"
# source <(fzf --zsh)
export FZF_DEFAULT_COMMAND='
  fd --type f --hidden \
     --exclude .git \
     --exclude node_modules \
'
# export FZF_DEFAULT_COMMAND='fd --type f'
#
export FZF_ALT_C_COMMAND='
  fd --type d --hidden \
     --exclude .git
'

export FZF_CTRL_T_COMMAND="$FZF_DEFAULT_COMMAND"

export FZF_DEFAULT_OPTS='--tiebreak=begin,length --algo=v2'
export FZF_DEFAULT_SORT=10000
#
# NVM  
export NVM_DIR="$([ -z "${XDG_CONFIG_HOME-}" ] && printf %s "${HOME}/.nvm" || printf %s "${XDG_CONFIG_HOME}/nvm")"
[ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh" 

#export NVM_DIR="$HOME/.nvm"
#[ -s "$HOMEBREW_PREFIX/opt/nvm/nvm.sh" ] && \. "$HOMEBREW_PREFIX/opt/nvm/nvm.sh" # This loads nvm
#[ -s "$HOMEBREW_PREFIX/opt/nvm/etc/bash_completion.d/nvm" ] && \. "$HOMEBREW_PREFIX/opt/nvm/etc/bash_completion.d/nvm" # This loads nvm bash_completion

# PLUGINS
zinit light zsh-users/zsh-autosuggestions
zinit light zsh-users/zsh-completions

# Load completions
autoload -Uz compinit && compinit

zinit light zsh-users/zsh-syntax-highlighting

eval "$(zoxide init zsh)"

## ALIASES
alias vim="nvim"
alias fd=fdfind
alias lz="lazygit"
alias ld="lazydocker"

#Script Aliases
alias s="~/.config/scripts/tmux/session.sh"
alias N="~/.config/scripts/tmux/notes.sh"
alias ca="~/.config/scripts/tmux/claude-sessions.sh"
alias wb="~/.config/scripts/tmux/wb.sh"

# notes-tui capture hot-path (roadmap slice 4a, started 2026-07-07):
# `note "thought"` / `cmd | note` — sub-second append to ~/code/notes/inbox.md,
# ctx-stamped with cwd + repo:branch + tmux session. The N/notes.sh daily flow
# above is untouched; the full wb integration is slice 4b, gated on this
# capture window's verdict.
[ -f ~/code/notes-tui/scripts/note.sh ] && source ~/code/notes-tui/scripts/note.sh

# Personal-account gh: the default `gh` uses the Sportable-scoped PAT in the
# keyring; `pgh ...` runs gh against the personal-account PAT instead (e.g. for
# repos owned by your personal user). Token is read from the system keyring at
# call time (never stored here). Set it up once with:
#   secret-tool store --label='gh personal PAT' service gh account personal
pgh() { GH_TOKEN="$(secret-tool lookup service gh account personal)" command gh "$@"; }

# replay — typed daemon-replay launcher (github.com/jetnoli-sportable/replay-tui)
# Rebuild with: cd ~/code/replay-tui* && go build -o "$HOME/go/bin/replay" ./cmd/replay
alias replay="$HOME/go/bin/replay"

# msconfig — open the Metrics Server's local config.hjson (Env / Region / SportType …)
alias msconfig="nvim $HOME/code/be--monorepo/apps/metrics_server/config.hjson"

[ -s "$NVM_DIR/bash_completion" ] && \. "$NVM_DIR/bash_completion"  # This loads nvm bash_completion
export PYENV_ROOT="$HOME/.pyenv"
[[ -d $PYENV_ROOT/bin ]] && export PATH="$PYENV_ROOT/bin:$PATH"
eval "$(pyenv init - zsh)"

# The next line updates PATH for the Google Cloud SDK.
if [ -f "$HOME/google-cloud-sdk/path.zsh.inc" ]; then . "$HOME/google-cloud-sdk/path.zsh.inc"; fi

# The next line enables shell command completion for gcloud.
if [ -f "$HOME/google-cloud-sdk/completion.zsh.inc" ]; then . "$HOME/google-cloud-sdk/completion.zsh.inc"; fi
export PATH="$HOME/.tfenv/bin:$PATH"

[ -f ~/.fzf.zsh ] && source ~/.fzf.zsh
export PATH="$HOME/.config/tmux/plugins/tpm/bin:$PATH"
###-begin-npm-completion-###
#
# npm command completion script
#
# Installation: npm completion >> ~/.bashrc  (or ~/.zshrc)
# Or, maybe: npm completion > /usr/local/etc/bash_completion.d/npm
#

if type complete &>/dev/null; then
  _npm_completion () {
    local words cword
    if type _get_comp_words_by_ref &>/dev/null; then
      _get_comp_words_by_ref -n = -n @ -n : -w words -i cword
    else
      cword="$COMP_CWORD"
      words=("${COMP_WORDS[@]}")
    fi

    local si="$IFS"
    if ! IFS=$'\n' COMPREPLY=($(COMP_CWORD="$cword" \
                           COMP_LINE="$COMP_LINE" \
                           COMP_POINT="$COMP_POINT" \
                           npm completion -- "${words[@]}" \
                           2>/dev/null)); then
      local ret=$?
      IFS="$si"
      return $ret
    fi
    IFS="$si"
    if type __ltrim_colon_completions &>/dev/null; then
      __ltrim_colon_completions "${words[cword]}"
    fi
  }
  complete -o default -F _npm_completion npm
elif type compdef &>/dev/null; then
  _npm_completion() {
    local si=$IFS
    compadd -- $(COMP_CWORD=$((CURRENT-1)) \
                 COMP_LINE=$BUFFER \
                 COMP_POINT=0 \
                 npm completion -- "${words[@]}" \
                 2>/dev/null)
    IFS=$si
  }
  compdef _npm_completion npm
elif type compctl &>/dev/null; then
  _npm_completion () {
    local cword line point words si
    read -Ac words
    read -cn cword
    let cword-=1
    read -l line
    read -ln point
    si="$IFS"
    if ! IFS=$'\n' reply=($(COMP_CWORD="$cword" \
                       COMP_LINE="$line" \
                       COMP_POINT="$point" \
                       npm completion -- "${words[@]}" \
                       2>/dev/null)); then

      local ret=$?
      IFS="$si"
      return $ret
    fi
    IFS="$si"
  }
  compctl -K _npm_completion npm
fi
###-end-npm-completion-###

# Machine-local overrides (gitignored by location — lives in ~, not the repo).
# Host-specific PATH tweaks, SDK paths, secrets-adjacent config go here.
[ -f ~/.zshrc.local ] && source ~/.zshrc.local
