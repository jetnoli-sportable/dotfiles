# shellcheck shell=bash
# Sourced, never executed: the review-target rule shared by haircut-gate-hook.sh
# and the review-stamp hook. No set -e, no exit, no globals: everything is
# local and functions are prefixed review_target_, so sourcing it cannot
# clobber a caller's variables.

# review_target_default_branch <repo-dir>
# Prints the default branch as origin/<name>, resolved as /haircut does:
# origin/HEAD, then asking the remote. Prints nothing when it can't.
review_target_default_branch() {
  local base def
  base="$(git -C "$1" symbolic-ref -q --short refs/remotes/origin/HEAD 2>/dev/null)"
  if [ -z "$base" ]; then
    # origin/HEAD is set by clone but not by `git remote add`.
    def="$(timeout 5 git -C "$1" ls-remote --symref origin HEAD 2>/dev/null |
      awk '$1 == "ref:" { sub("^refs/heads/", "", $2); print $2; exit }')"
    [ -n "$def" ] && base="origin/$def"
  fi
  printf '%s' "$base"
}

# review_target_is_other <repo-dir> <args>
# Returns 0 when the review arguments target something other than the current
# branch (a PR number, a GitHub PR URL, or another existing branch), 1 when
# they target the current branch or name nothing.
review_target_is_other() {
  local repo="$1" args="$2" tok cur up def defshort
  local -a toks
  # -d '' reads past newlines: typed and Skill args can span lines. It returns
  # 1 at end of input, having filled the array anyway.
  read -r -d '' -a toks <<<"$args" || true
  [ "${#toks[@]}" -gt 0 ] || return 1
  # ce-code-review refuses base: together with a PR or branch target, so a
  # base: run always reviews the current checkout, whatever its prose names.
  for tok in "${toks[@]}"; do
    [[ "$tok" == base:* ]] && return 1
  done
  cur="$(git -C "$repo" symbolic-ref -q --short HEAD 2>/dev/null)"
  up="$(git -C "$repo" rev-parse --abbrev-ref '@{u}' 2>/dev/null)"
  def="$(review_target_default_branch "$repo")"
  defshort="${def#origin/}"
  for tok in "${toks[@]}"; do
    [[ "$tok" == --* ]] && continue
    # Quotes, backticks and sentence punctuation come from prose arguments.
    tok="${tok#"${tok%%[!\"\'\`(\[]*}"}"
    tok="${tok%"${tok##*[!\"\'\`)\].,;:!?]}"}"
    [ -n "$tok" ] || continue
    # The PR URL has a "word:" prefix, so it is tested before key:value tokens are dropped.
    [[ "$tok" =~ ^https://github\.com/[^/]+/[^/]+/pull/[0-9]+ ]] && return 0
    [[ "$tok" =~ ^[A-Za-z][A-Za-z0-9_-]*: ]] && continue
    tok="${tok##*..}"
    [ -n "$tok" ] || continue
    [[ "$tok" =~ ^#?[0-9]+$ ]] && return 0
    [ "$tok" = "$cur" ] && continue
    [ -n "$up" ] && [ "$tok" = "$up" ] && continue
    [ -n "$def" ] && { [ "$tok" = "$def" ] || [ "$tok" = "$defshort" ]; } && continue
    git -C "$repo" show-ref --verify --quiet "refs/heads/$tok" && return 0
    git -C "$repo" show-ref --verify --quiet "refs/remotes/$tok" && return 0
    # ce-code-review resolves a bare branch name as origin/<name>.
    git -C "$repo" show-ref --verify --quiet "refs/remotes/origin/$tok" && return 0
  done
  return 1
}
