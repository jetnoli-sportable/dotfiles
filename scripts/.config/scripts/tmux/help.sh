#!/usr/bin/env bash
# help.sh — fzf over the generated INDEX (docs/INDEX.md): every bind, alias,
# function, script, skill, doc, decision and TUI the personal workflow
# provides, with provenance.
#
#   prefix+?             open the picker (tmux.conf binds it in a new window)
#   Enter  = "take me to it": doc/guide -> xdg-open the rendered HTML;
#            everything else -> nvim at the source line, in a new tmux window.
#   Preview = "tell me about it" (per-kind: source context, description,
#            decision options, README head).
#
# No kind ever executes/launches the thing — running it is what the entry's
# own `invoke` column documents. For questions instead of lookup, ask
# `/help <question>` in any Claude Code session (same INDEX, plus reasoning).
#
# The INDEX-read + source-follow helpers (index_jsonl, resolve_path) are
# deliberately self-contained: future consumers (roadmap 9e task-recall)
# should reuse them rather than re-parsing INDEX.md.
set -euo pipefail

DOTFILES="${DOTFILES:-$HOME/code/dotfiles}"
INDEX="$DOTFILES/docs/INDEX.md"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SELF="$SCRIPT_DIR/$(basename "${BASH_SOURCE[0]}")"

# index_jsonl: emit the machine half of INDEX.md, one JSON object per line.
index_jsonl() {
  [ -f "$INDEX" ] || { echo "help.sh: no INDEX at $INDEX — run docgen.sh index" >&2; exit 1; }
  awk '/^```jsonl$/{on=1;next} /^```$/{on=0} on' "$INDEX"
}

# resolve_path <path>: repo-relative INDEX paths resolve under $DOTFILES,
# ~-form paths under $HOME; absolute paths pass through.
resolve_path() {
  case "$1" in
    "~/"*) printf '%s\n' "$HOME/${1#\~/}" ;;
    /*)    printf '%s\n' "$1" ;;
    *)     printf '%s\n' "$DOTFILES/$1" ;;
  esac
}

preview() {
  local json="$1" kind src guide path line
  IFS=$'\t' read -r kind src guide < <(jq -r '[.kind, .source, .guide] | @tsv' <<<"$json")
  path="$(resolve_path "${src%:*}")"
  line="${src##*:}"
  [ -f "$path" ] || { echo "(source missing: $path)"; return 0; }

  case "$kind" in
    doc|guide)
      sed -n '1,40p' "$path"
      ;;
    skill)
      # frontmatter description, then the When-to-use prose if present
      awk '/^description:/{sub(/^description: */,""); print; print ""}' "$path"
      awk 'tolower($0) ~ /^#+ when/{on=1} on && NR>1 && /^## /&& tolower($0) !~ /^#+ when/{exit} on' "$path" | head -25
      ;;
    bind|alias|function|script)
      # the source line ± 5 lines of comment context, target marked
      awk -v t="$line" 'NR>=t-5 && NR<=t+5 {printf "%s %4d  %s\n", (NR==t ? ">" : " "), NR, $0}' "$path"
      ;;
    tui)
      sed -n '1,40p' "$path"
      ;;
    decision)
      # title + the options list
      grep -E '^#{1,3} |^- \[.\]' "$path" | head -30
      ;;
    *)
      sed -n '1,20p' "$path"
      ;;
  esac
}

open_entry() {
  local json="$1" kind src guide path line
  IFS=$'\t' read -r kind src guide < <(jq -r '[.kind, .source, .guide] | @tsv' <<<"$json")
  case "$kind" in
    doc|guide)
      if [ -n "$guide" ]; then
        xdg-open "$(resolve_path "$guide")" >/dev/null 2>&1 &
        return 0
      fi
      ;;& # docs with no rendered page (memory, instructions) fall through
    *)
      path="$(resolve_path "${src%:*}")"
      line="${src##*:}"
      tmux new-window -n "help:$(jq -r .name <<<"$json")" "nvim +$line '$path'"
      ;;
  esac
}

case "${1-}" in
  preview)
    preview "$2"
    exit 0
    ;;
  --ask)
    cat <<'EOF'
help.sh is the deterministic lookup half (no LLM in bash).
For questions — "why do I have binding X", "what does Y do", "how do I
use Z" — run /help <question> inside any Claude Code session: it reads
the same docs/INDEX.md, follows source/guide links (including decision
records), and answers with file:line citations.
EOF
    exit 0
    ;;
esac

rows="$(index_jsonl | jq -r '. as $e | ([
    ($e.name + "                              ")[0:30],
    ($e.kind + "          ")[0:9],
    $e.oneliner
  ] | join(" ")) + "\t" + ($e | tostring)' 2>/dev/null)" || {
  echo "help.sh: INDEX parse failed — regenerate with docgen.sh index" >&2
  exit 1
}

selection="$(printf '%s\n' "$rows" | fzf \
  --ansi --delimiter '\t' --with-nth 1 \
  --prompt='help> ' \
  --header='Enter: take me to it · preview: about it · /help <q> for Q&A (--ask)' \
  --preview "$SELF preview {2}" \
  --preview-window 'right,55%,wrap' \
  --query="${1-}")" || exit 0
[ -n "$selection" ] || exit 0

open_entry "${selection#*$'\t'}"
