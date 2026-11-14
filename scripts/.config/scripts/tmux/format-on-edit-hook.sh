#!/usr/bin/env bash
# PostToolUse hook (Write|Edit|MultiEdit): format the edited file with the
# formatter nvim's conform uses for its type (shfmt for shell). Never blocks:
# every path exits 0 with nothing on stdout.
#
# Two rules keep it from causing churn: a file whose committed version was not
# already formatter-clean is left alone, and while the work plugin is enabled
# a file its own format hook would format in this repo is skipped.
set -uo pipefail

command -v jq >/dev/null 2>&1 || exit 0
command -v git >/dev/null 2>&1 || exit 0

file="$(jq -r '.tool_input.file_path // empty' 2>/dev/null)" || exit 0
[ -n "$file" ] && [ -f "$file" ] || exit 0

case "$file" in
  *.md | "$HOME"/code/tasks/*) exit 0 ;;
esac

dir="$(dirname -- "$file")"
repo_root="$(git -C "$dir" rev-parse --show-toplevel 2>/dev/null)" || exit 0
[ -n "$repo_root" ] || exit 0

group=
case "$file" in
  *.lua) group=lua ;;
  *.go) group=go ;;
  *.js | *.jsx | *.ts | *.tsx | *.css | *.html | *.json | *.yaml | *.yml) group=prettier ;;
  *.sh | *.bash) group=shell ;;
  *)
    case "$(basename -- "$file")" in
      *.*) ;;
      *)
        IFS= read -r first <"$file" || true
        case "$first" in
          '#!/usr/bin/env bash' | '#!/bin/bash' | '#!/bin/sh' | '#!/usr/bin/env sh') group=shell ;;
        esac
        ;;
    esac
    ;;
esac
[ -n "$group" ] || exit 0

# Mirrors the work plugin's detect-formatter.sh first-match order, read from
# the git root: ruff, then go.mod, then prettier.
plugin_formatter() {
  if [ -f "$repo_root/pyproject.toml" ] && [ -f "$repo_root/uv.lock" ] &&
    grep -qE '^\[tool\.ruff(\.|\])' "$repo_root/pyproject.toml" 2>/dev/null; then
    echo ruff
  elif [ -f "$repo_root/go.mod" ]; then
    echo go
  elif [ -f "$repo_root/package.json" ] && grep -q '"prettier"' "$repo_root/package.json" 2>/dev/null; then
    local rc
    for rc in .prettierrc .prettierrc.json .prettierrc.yaml .prettierrc.yml .prettierrc.js \
      .prettierrc.cjs .prettierrc.mjs .prettierrc.ts prettier.config.js prettier.config.cjs \
      prettier.config.mjs prettier.config.ts; do
      if [ -f "$repo_root/$rc" ]; then
        echo prettier
        return
      fi
    done
  fi
}

if [ "$group" = go ] || [ "$group" = prettier ]; then
  if [ "$(jq -r '.enabledPlugins["sportable@sportabletech-harness"] // false' "$HOME/.claude/settings.json" 2>/dev/null)" = true ]; then
    [ "$(plugin_formatter)" = "$group" ] && exit 0
  fi
fi

find_bin() {
  if command -v "$1" 2>/dev/null; then
    return 0
  elif [ -x "$HOME/.local/share/nvim/mason/bin/$1" ]; then
    echo "$HOME/.local/share/nvim/mason/bin/$1"
  else
    return 1
  fi
}

bins=()
case "$group" in
  lua) tools=(stylua) ;;
  go) tools=(goimports gofumpt) ;;
  prettier) tools=(prettier) ;;
  shell) tools=(shfmt) ;;
esac
for t in "${tools[@]}"; do
  b="$(find_bin "$t")" || exit 0
  bins+=("$b")
done

# Formatter's stdin mode, given the real path so it finds the same config as
# the in-place run.
format_stdin() {
  case "$group" in
    lua) "${bins[0]}" --stdin-filepath "$file" - ;;
    prettier) "${bins[0]}" --stdin-filepath "$file" ;;
    shell) "${bins[0]}" --filename "$file" ;;
    go) "${bins[0]}" -srcdir "$dir" | "${bins[1]}" ;;
  esac
}
format_in_place() {
  case "$group" in
    lua) "${bins[0]}" "$file" ;;
    prettier) "${bins[0]}" --write "$file" ;;
    shell) "${bins[0]}" -w "$file" ;;
    go) "${bins[0]}" -w "$file" && "${bins[1]}" -w "$file" ;;
  esac
}

prefix="$(git -C "$dir" rev-parse --show-prefix 2>/dev/null)" || exit 0
rel="$prefix$(basename -- "$file")"
# $(...) drops trailing newlines, so compare through files.
tmp="$(mktemp)" || exit 0
trap 'rm -f "$tmp" "$tmp.fmt"' EXIT
# No HEAD version (a new or untracked file) counts as clean.
if git -C "$repo_root" cat-file blob "HEAD:$rel" >"$tmp" 2>/dev/null; then
  format_stdin <"$tmp" >"$tmp.fmt" 2>/dev/null || exit 0
  cmp -s "$tmp" "$tmp.fmt" || exit 0
fi

format_in_place >/dev/null 2>&1 || true
exit 0
