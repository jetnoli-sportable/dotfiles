
# Set the directory we want to store zinit and plugins
ZINIT_HOME="${XDG_DATA_HOME:-${HOME}/.local/share}/zinit/zinit.git"
export XDG_CONFIG_HOME="$HOME/.config"
export PATH=$PATH:$HOME/.local/bin
export PATH=$PATH:/usr/local/go/bin
export PATH=$PATH:~/go/bin
export PATH=$PATH:/opt/nvim-linux-x86_64/bin

if [[ -f "/opt/homebrew/bin/brew" ]] then
  eval "$(/opt/homebrew/bin/brew shellenv)"
fi

export VISUAL=nvim
export EDITOR=nvim

# HISTORY — without these zsh keeps 30 lines in memory and saves none.
# inc_append writes each command as it runs (so new panes see it) but,
# unlike share_history, doesn't push it into shells that are already open,
# which would mix every wb agent pane's commands into each other's up-arrow.
HISTFILE=~/.zsh_history
HISTSIZE=50000
SAVEHIST=50000
setopt inc_append_history extended_history hist_ignore_dups hist_ignore_space hist_reduce_blanks

# Plugins, prompt and completion only make sense in an interactive shell.
# Claude Code's command shell is non-interactive and runs with
# nobareglobqual, under which zinit's `*.plugin.zsh(DN)` glob fails
# ("no matches found") and a `source ~/.zshrc && …` chain aborts.
if [[ -o interactive ]]; then
  # Download Zinit, if it's not there yet
  if [ ! -d "$ZINIT_HOME" ]; then
     mkdir -p "$(dirname $ZINIT_HOME)"
     git clone https://github.com/zdharma-continuum/zinit.git "$ZINIT_HOME"
  fi
  source "${ZINIT_HOME}/zinit.zsh"

  zinit light jeffreytse/zsh-vi-mode
  zvm_after_init() {
    bindkey '^y' autosuggest-accept
    # zsh-vi-mode rebuilds the keymaps on init, which drops fzf's ^R history
    # widget if fzf bound it first, so fzf's key bindings load here, after it.
    command -v fzf >/dev/null && source <(fzf --zsh)
  }

  # THEMING CONFIG
  eval "$(oh-my-posh init zsh --config ~/.config/ohmyposh/zen.json)"

  zinit light zsh-users/zsh-autosuggestions
  zinit light zsh-users/zsh-completions

  # Load completions
  autoload -Uz compinit && compinit

  zinit light zsh-users/zsh-syntax-highlighting

  eval "$(zoxide init zsh)"
fi

# FZF CONFIG
export FZF_DEFAULT_COMMAND='
  fd --type f --hidden \
     --exclude .git \
     --exclude node_modules \
'
export FZF_ALT_C_COMMAND='
  fd --type d --hidden \
     --exclude .git
'

export FZF_CTRL_T_COMMAND="$FZF_DEFAULT_COMMAND"

export FZF_DEFAULT_OPTS='--tiebreak=begin,length --algo=v2'
export FZF_DEFAULT_SORT=10000
[[ -d ~/.fzf/bin && :$PATH: != *:$HOME/.fzf/bin:* ]] && export PATH="$PATH:$HOME/.fzf/bin"

# NVM
# `nvm use default` at load cost ~185ms of every shell start; --no-use skips
# it and the default alias's newest matching install goes on PATH directly.
# Aliases a glob can't resolve (lts/*, node) fall back to `nvm use`.
export NVM_DIR="$([ -z "${XDG_CONFIG_HOME-}" ] && printf %s "${HOME}/.nvm" || printf %s "${XDG_CONFIG_HOME}/nvm")"
if [ -s "$NVM_DIR/nvm.sh" ]; then
  \. "$NVM_DIR/nvm.sh" --no-use
  () {
    setopt localoptions bareglobqual extendedglob
    local alias_file=$NVM_DIR/alias/default
    local -a bins
    [[ -r $alias_file ]] && bins=( $NVM_DIR/versions/node/v${$(<$alias_file)#v}*/bin(N/nOn) )
    if (( $#bins )); then
      export PATH="$bins[1]:$PATH"
    else
      nvm use default --silent >/dev/null 2>&1
    fi
  }
fi
## ALIASES
alias vim="nvim"
alias fd=fdfind
alias lz="lazygit"
alias ld="lazydocker"

## Script Aliases
# legacy repo sessionizer — kept as a fallback; wb absorbed it on prefix+m
alias s="~/.config/scripts/tmux/session.sh"
# notes picker / daily note in the persistent notes session (notes.sh)
alias N="~/.config/scripts/tmux/notes.sh"
# legacy claude-agent picker — kept as a fallback; wb's agents mode absorbed it
alias ca="~/.config/scripts/tmux/claude-sessions.sh"
# the workbench: wb new / wb (picker) / wb done / wb board — docs/wb-guide.html
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

# wb agent isolation (docs/plans/2026-08-24-001-feat-wb-session-cgroup-isolation-plan.md):
# every wb launch site (wb.sh, handoff.sh, ask.sh) types the bare word `claude`
# into a pane's zsh, so gating one shell function here is the single chokepoint
# that covers both scripted AND manually-typed launches (the `wb resume` case)
# — see KTD1. Isolating each agent in its own systemd --user scope means oomd
# kills one runaway agent instead of the shared Ghostty scope that also holds
# the tmux server and every other session (2026-08-24 crash, recurred despite
# PR #40's lazy-nvim). ~/.zshrc.local (sourced below) is the override seam for
# these three defaults.
# wb-claude-wrapper:begin — markers let wb-claude-wrapper.test.sh extract just
# this block rather than sourcing the whole .zshrc (which does a network
# zinit clone on a cold cache).
: ${WB_AGENT_MEM_HIGH:=14G} ${WB_AGENT_MEM_MAX:=18G} ${WB_AGENT_WARN_AT:=8}
# Exported so wb.sh (a separate bash process — the picker, `wb board`) reads
# the same live threshold this wrapper warns at, instead of a second
# hardcoded copy that could drift from whatever ~/.zshrc.local overrides.
export WB_AGENT_MEM_HIGH WB_AGENT_MEM_MAX WB_AGENT_WARN_AT
claude() {
  [[ -n $TMUX ]] || { command claude "$@"; return }
  # One round-trip for both the gate and the session name (#{@wb_repo}
  # expands to "" when the option is unset, same as show-options -q).
  local repo sess
  IFS='|' read -r repo sess <<< "$(tmux display-message -p '#{@wb_repo}|#{session_name}' 2>/dev/null)"
  [[ -n $repo ]] || { command claude "$@"; return }
  local n; n="$(tmux list-panes -a -F '#{pane_current_command}' 2>/dev/null | grep -cx claude)"
  if (( n >= WB_AGENT_WARN_AT )); then
    echo "wb: ${n} claude agents already running (warn >= ${WB_AGENT_WARN_AT}); starting another. Ctrl-C to abort." >&2
  fi
  # printf, not a <<< here-string: a here-string appends its own trailing
  # newline, which tr then turns into a spurious trailing '-' (outside the
  # allowed charset) since it isn't stripped the way command-substitution
  # would strip an actual trailing newline.
  sess="$(printf '%s' "$sess" | tr -c 'A-Za-z0-9_-' '-')"
  sess="${sess:0:50}"
  # `command` is a shell builtin systemd-run can't exec, and `exec`ing the real
  # binary would replace the pane's shell (breaking quit->prompt, R5) — resolve
  # the real path and hand it to systemd-run as a plain argv (KTD5).
  local real; real="$(whence -p claude)"
  # Fail OPEN to passthrough, never closed: without this, a machine missing
  # systemd-run (or a claude shadowed only by this very function, so
  # `whence -p` finds nothing on PATH) would silently launch no agent at all
  # in every wb pane, with no recovery — this wrapper is the sole chokepoint
  # every launch site depends on.
  if [[ -z $real ]] || ! command -v systemd-run >/dev/null 2>&1; then
    command claude "$@"
    return
  fi
  # --collect: without it, a scope killed by its own MemoryMax (the exact
  # event this wrapper exists to contain) leaves a "failed" unit registered
  # under this exact name — and since there's no `exec` above, $$ (the
  # pane's shell PID) is stable for the pane's whole lifetime, so the very
  # next `claude` typed into the SAME pane would fail to start at all
  # ("Unit wb-agent-...-$$.scope was already loaded"). Verified live: an
  # OOM-killed scope without --collect blocks reuse of its unit name;
  # with --collect it's auto-unloaded and the name is immediately reusable.
  # The per-launch timestamp suffix covers what --collect can't: a detached
  # child (e.g. `wl-copy`, which outlives its parent to keep serving the
  # selection) keeps the scope's cgroup non-empty, so the unit stays ACTIVE
  # long after claude exits and --collect (inactive/failed only) never fires.
  # Verified live: an orphaned wl-copy-only scope blocked a same-pane relaunch.
  systemd-run --user --scope --quiet --collect \
    --unit="wb-agent-${sess}-$$-$(date +%s%N)" \
    -p MemoryHigh="$WB_AGENT_MEM_HIGH" -p MemoryMax="$WB_AGENT_MEM_MAX" \
    "$real" "$@"
}
# wb-claude-wrapper:end

# replay — typed daemon-replay launcher (github.com/jetnoli-sportable/replay-tui)
# Rebuild with: cd ~/code/replay-tui* && go build -o "$HOME/go/bin/replay" ./cmd/replay
alias replay="$HOME/go/bin/replay"

# msconfig — open the Metrics Server's local config.hjson (Env / Region / SportType …)
alias msconfig="nvim $HOME/code/be--monorepo/apps/metrics_server/config.hjson"

# Completion scripts (nvm, gcloud, npm below) register through compdef, which
# needs the compinit run in the interactive block above; in a
# non-interactive shell their compdef calls fail and abort the sourcing.
[[ -o interactive && -s $NVM_DIR/bash_completion ]] && \. "$NVM_DIR/bash_completion"
export PYENV_ROOT="$HOME/.pyenv"
[[ -d $PYENV_ROOT/bin ]] && export PATH="$PYENV_ROOT/bin:$PATH"
eval "$(pyenv init - zsh)"

# The next line updates PATH for the Google Cloud SDK.
if [ -f "$HOME/google-cloud-sdk/path.zsh.inc" ]; then . "$HOME/google-cloud-sdk/path.zsh.inc"; fi

# The next line enables shell command completion for gcloud.
if [[ -o interactive && -f $HOME/google-cloud-sdk/completion.zsh.inc ]]; then . "$HOME/google-cloud-sdk/completion.zsh.inc"; fi
export PATH="$HOME/.tfenv/bin:$PATH"

export PATH="$HOME/.config/tmux/plugins/tpm/bin:$PATH"
if [[ -o interactive ]]; then
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
fi

# Machine-local overrides (gitignored by location — lives in ~, not the repo).
# Host-specific PATH tweaks, SDK paths, secrets-adjacent config go here.
# An `if`, not `[ -f ] &&`: as the last line, a failed test made every
# `source ~/.zshrc` return 1 on machines without the file.
if [ -f ~/.zshrc.local ]; then source ~/.zshrc.local; fi
