#!/usr/bin/env bash
# docgen.sh — regenerate the docs platform (pages + HUB + INDEX) for this
# dotfiles repo. Thin wrapper around ~/code/docgen: rebuilds the binary when
# its Go sources changed, then runs it with -root pointed here.
#
#   docgen.sh            # build + index (everything)
#   docgen.sh build      # pages + HUB only
#   docgen.sh index      # INDEX.md only
set -euo pipefail

DOCGEN_SRC="${DOCGEN_SRC:-$HOME/code/docgen}"
# same root variable help.sh uses, so the two can never disagree about
# where the repo (and its INDEX) lives
DOCGEN_ROOT="${DOCGEN_ROOT:-${DOTFILES:-$HOME/code/dotfiles}}"
BIN="$HOME/.local/bin/docgen"

[ -d "$DOCGEN_SRC" ] || { echo "docgen.sh: no tool at $DOCGEN_SRC" >&2; exit 1; }

# sources sit at the repo root (-maxdepth 1 keeps .git/ out of the walk);
# go.mod/go.sum count as sources — a dependency bump must trigger a rebuild
if [ ! -x "$BIN" ] || [ -n "$(find "$DOCGEN_SRC" -maxdepth 1 \( -name '*.go' -o -name 'go.mod' -o -name 'go.sum' \) -newer "$BIN" -print -quit 2>/dev/null)" ]; then
  mkdir -p "$(dirname "$BIN")"
  (cd "$DOCGEN_SRC" && go build -o "$BIN" .)
fi

cmd="${1:-all}"
[ $# -gt 0 ] && shift
exec "$BIN" "$cmd" -root "$DOCGEN_ROOT" "$@"
