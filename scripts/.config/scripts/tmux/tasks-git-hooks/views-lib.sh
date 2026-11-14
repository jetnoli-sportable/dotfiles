#!/usr/bin/env bash
# Shared by the post-merge and post-rewrite hooks (sourced, never run by git:
# its name is not a git hook name). Rebuilds the store's generated views
# (decisions.md, handoffs.md, index.md in each dossier; they are not in git)
# for the dossiers whose files a pull or rebase just changed.
#
# Contract: these hooks can never fail or block the git operation, so
# everything here returns 0, and the one thing worth saying on a failure is
# said on a single stderr line. Nothing happens when no wb can be found.
#
# Nothing happens either until the store has stopped tracking the views:
# its .gitignore must ignore them and no view may still be in the index.
# Before the store switch the views are committed files, and rebuilding them
# on a pull would leave tracked files modified (the next pull or rebase then
# refuses, and `git add -A` sweeps the churn into a commit). The hooks are
# live as soon as they are stowed, so this check, not the order of the
# switch steps, is what keeps a pull clean.
#
# Finding wb: `wb` is a shell alias in interactive shells, which a git hook
# cannot see, so the lookup is (1) an executable `wb` on PATH, (2) the
# wb.sh beside this hooks directory (hooks are stowed as links into the
# dotfiles checkout, so the real path of this file sits next to wb.sh).
# Neither found: do nothing.

# _wv_find_wb — print the command to run wb with, or nothing.
_wv_find_wb() {
  local p here
  p="$(command -v wb 2>/dev/null || true)"
  if [ -n "$p" ] && [ -f "$p" ] && [ -x "$p" ]; then printf '%s\n' "$p"; return 0; fi
  here="$(dirname -- "$(realpath -- "${BASH_SOURCE[0]}" 2>/dev/null || printf '%s' "${BASH_SOURCE[0]}")")"
  if [ -f "$here/../wb.sh" ]; then printf 'bash %s\n' "$here/../wb.sh"; fi
  return 0
}

# _wv_views_untracked <root> — true when the store ignores the generated views
# and none is still tracked (see the header). Each view name is probed at a
# dossier that cannot exist, so the answer is the .gitignore's, and tracked
# views are looked for with a strict glob (one directory level, like the
# .gitignore lines, so a page called index.md deeper down does not count).
_wv_views_untracked() {
  local root="$1" v
  for v in decisions.md handoffs.md index.md; do
    git -C "$root" check-ignore -q -- "dossiers/.wv-probe/$v" 2>/dev/null || return 1
  done
  [ -z "$(git -C "$root" ls-files -- ':(glob)dossiers/*/decisions.md' ':(glob)dossiers/*/handoffs.md' ':(glob)dossiers/*/index.md' 2>/dev/null)" ]
}

# _wv_stems — stdin: changed paths (store-relative); stdout: the stems of the
# dossiers they sit in that have a task file, one per line.
_wv_stems() {
  local root="$1" path stem
  while IFS= read -r path; do
    case "$path" in dossiers/*/*) ;; *) continue ;; esac
    stem="${path#dossiers/}"; stem="${stem%%/*}"
    [ -f "$root/$stem.md" ] || continue
    printf '%s\n' "$stem"
  done | LC_ALL=C sort -u
}

# _wv_refresh <hook-name> <changed|-> — <changed> is a newline list of changed
# store-relative paths, or "-" when the set could not be worked out (then
# every dossier is rebuilt).
_wv_refresh() {
  local hook="$1" changed="$2" root wb rc=0
  root="$(git rev-parse --show-toplevel 2>/dev/null)" || return 0
  [ -n "$root" ] || return 0
  _wv_views_untracked "$root" || return 0
  wb="$(_wv_find_wb)"
  [ -n "$wb" ] || return 0
  local -a stems=()
  if [ "$changed" = "-" ]; then
    stems=(--all)
  else
    mapfile -t stems < <(printf '%s\n' "$changed" | _wv_stems "$root")
    [ "${#stems[@]}" -gt 0 ] || return 0
  fi
  # shellcheck disable=SC2086  # $wb is "bash <path>" or one path
  TASKS_DIR="$root" $wb views "${stems[@]}" >/dev/null 2>&1 || rc=$?
  if [ "$rc" -ne 0 ]; then
    echo "$hook: wb views ${stems[*]} failed (exit $rc); run it by hand to rebuild the generated views" >&2
  fi
  return 0
}
