#!/usr/bin/env bash
# lanes-check.sh — stop an unattended "spare-token lanes" work item before it
# collides with live work.
#
# Why it exists: a lanes run executes pre-approved items over a weekend, each
# becoming a branch + PR. If an item edits a file that some live work also
# changes, Jet comes back to a conflict or a broken branch. The rule (Jet,
# 2026-11): approve the weekend plan explicitly up front; before each item
# starts, and again before it commits, compare its files with everything that
# is live; on any possible overlap STOP that item — never serialize or guess.
# The first run (21 Nov) did this by hand and learned that local branches with
# no PR are real conflict sources, that branches whose PR already merged are
# noise, and that docgen-generated files change in nearly every PR.
#
# How it decides: the plan file lists items and the repo-relative paths each
# plans to touch (a path ending in / means everything under it). Live sources:
#   1. every worktree (the main checkout too): its uncommitted + untracked
#      files, and its branch's changes against the base;
#   2. every local branch not checked out anywhere (no worktree, maybe no PR);
#   3. every open PR's files (via `gh pr list`);
#   4. a branch whose PR already merged, and that has no open PR, is skipped
#      (and listed, so Jet can see it was considered).
# A file overlapping an item's paths stops the item. Generated files
# (docs/INDEX.md, docs/HUB.html, docs/try-it.*, and docs/**/*.html that has a
# .md sibling) never stop by name — they change in nearly every PR; `commit`
# mode instead runs a git merge dry run against the live branch and stops only
# on a real conflict. The PR lookups fail closed: if they can't be listed, an
# item that could conflict must stop, so the run exits 2 instead of guessing.
#
# Plan file:
#   approved: 2026-11-21 by Jet     # required, with text after the colon
#   # comments and blank lines are ignored
#   <item-id> <path> [<path> ...]
#
# Usage:
#   lanes-check.sh start  --plan FILE [--item ID] [--repo DIR] [--base REF]
#   lanes-check.sh commit --plan FILE --item ID --worktree DIR [--repo DIR] [--base REF]
# `commit` treats the item's files as its planned paths plus what DIR actually
# changed (committed vs base, uncommitted, untracked); DIR and its branch are
# not live sources; changed-but-unplanned files print as a NOTE.
# --repo defaults to the git toplevel of the cwd (of DIR for commit). --base
# defaults to origin/HEAD's target, else origin/development, else origin/main.
#
# Environment:
#   LANES_GH          gh-compatible command; default runs the `pgh` function
#                     from ~/.zshrc (gh for personal repos) through zsh -ic
#   LANES_STOW_ROOTS  roots scanned (start only) for config symlinks into a
#                     feature worktree; default "$HOME/.claude $HOME/.config"
#
# Output: per item `CLEAR <item>` or `STOP <item>` + indented `<file>  <- <label>`
# lines, then `NOTE <item>: ...` lines; `start` ends with a per-source
# blocked-items summary and any stowed-config WARN.
# Exit codes: 0 every checked item CLEAR, 1 some item STOP, 2 the check
# couldn't run (bad args, unapproved plan, no base, PR lookup failed).
set -uo pipefail

USAGE="usage: lanes-check.sh start --plan FILE [--item ID] [--repo DIR] [--base REF]
       lanes-check.sh commit --plan FILE --item ID --worktree DIR [--repo DIR] [--base REF]"
join_comma() {
  local IFS=,
  local s="$*"
  printf '%s' "${s//,/, }"
}
die() {
  echo "lanes-check: $*" >&2
  exit 2
}
die_usage() {
  echo "$USAGE" >&2
  die "$@"
}

gh_call() {
  if [ -n "${LANES_GH:-}" ]; then
    "$LANES_GH" "$@"
  else
    zsh -ic 'pgh "$@"' _ "$@"
  fi
}

# --- arguments ---------------------------------------------------------------
[ $# -ge 1 ] || die_usage "missing mode"
mode="$1"
shift
case "$mode" in start | commit) ;; *) die_usage "unknown mode: $mode" ;; esac
plan="" item="" repo="" base="" wtdir=""
while [ $# -gt 0 ]; do
  case "$1" in
    --plan | --item | --repo | --base)
      [ $# -ge 2 ] || die_usage "$1 needs a value"
      case "$1" in --plan) plan="$2" ;; --item) item="$2" ;; --repo) repo="$2" ;; --base) base="$2" ;; esac
      shift 2
      ;;
    --worktree)
      [ "$mode" = commit ] || die_usage "--worktree only applies to commit"
      [ $# -ge 2 ] || die_usage "--worktree needs a value"
      wtdir="$2"
      shift 2
      ;;
    *) die_usage "unknown argument: $1" ;;
  esac
done
[ -n "$plan" ] || die_usage "--plan is required"
if [ "$mode" = commit ]; then
  [ -n "$item" ] || die_usage "commit needs --item"
  [ -n "$wtdir" ] || die_usage "commit needs --worktree"
fi

# --- plan --------------------------------------------------------------------
[ -f "$plan" ] || die "plan file not found: $plan"
approved=0
ITEM_IDS=()
declare -A ITEM_PATHS=()
while IFS= read -r line || [ -n "$line" ]; do
  line="${line#"${line%%[![:space:]]*}"}"
  [ -n "$line" ] || continue
  case "$line" in
    \#*) continue ;;
    approved:*)
      rest="${line#approved:}"
      [[ "$rest" == *[![:space:]]* ]] && approved=1
      continue
      ;;
  esac
  read -r id paths <<<"$line"
  [ -n "$paths" ] || die "plan item '$id' lists no paths; an item with no paths can't be checked"
  [ -z "${ITEM_PATHS[$id]+x}" ] || die "duplicate item id in plan: $id"
  ITEM_IDS+=("$id")
  ITEM_PATHS[$id]="$paths"
done <"$plan"
[ "$approved" = 1 ] || die "plan is not approved: add a line 'approved: <date> by <who>' once Jet signs off"
if [ -n "$item" ]; then
  [ -n "${ITEM_PATHS[$item]+x}" ] || die_usage "unknown item: $item"
  ITEM_IDS=("$item")
fi
[ "${#ITEM_IDS[@]}" -gt 0 ] || die "plan lists no items"

# --- repo and base -----------------------------------------------------------
if [ "$mode" = commit ]; then
  [ -d "$wtdir" ] || die "worktree not found: $wtdir"
  wtdir="$(cd "$wtdir" && pwd -P)"
  [ -n "$repo" ] || repo="$(git -C "$wtdir" rev-parse --show-toplevel 2>/dev/null)" || die "not a git worktree: $wtdir"
else
  [ -n "$repo" ] || repo="$(git rev-parse --show-toplevel 2>/dev/null)" || die "not in a git repo (use --repo)"
fi
[ -d "$repo" ] || die "repo not found: $repo"
repo="$(cd "$repo" && pwd -P)"
G() { git -C "$repo" "$@"; }

if [ -z "$base" ]; then
  head_ref="$(G symbolic-ref -q refs/remotes/origin/HEAD 2>/dev/null || true)"
  if [ -n "$head_ref" ]; then
    base="${head_ref#refs/remotes/}"
  elif G rev-parse --verify -q refs/remotes/origin/development >/dev/null; then
    base="origin/development"
  else
    base="origin/main"
  fi
fi
G rev-parse --verify -q "$base^{commit}" >/dev/null || die "base ref not found: $base"
base_local="${base#origin/}"

errf="$(mktemp)" tmp_index="$(mktemp -u)"
trap 'rm -f "$errf" "$tmp_index"' EXIT

own_branch="" item_head=""
if [ "$mode" = commit ]; then
  own_branch="$(git -C "$wtdir" symbolic-ref -q --short HEAD 2>/dev/null || true)"
  git -C "$wtdir" rev-parse -q --verify HEAD >/dev/null || die "no commits in $wtdir"
  # This runs before the item commits, so the merge dry run needs its
  # uncommitted and untracked edits too: snapshot the worktree into a commit
  # object through a throwaway index, leaving the item's own index as it is.
  item_head="$(cd "$wtdir" && export GIT_INDEX_FILE="$tmp_index" &&
    git read-tree HEAD && git add -A && git commit-tree "$(git write-tree)" -p HEAD -m "lanes-check snapshot")" ||
    die "couldn't snapshot the worktree for the merge dry run: $wtdir"
fi

# --- PR lookups (fail closed) ------------------------------------------------
pr_list() { # <state> <json fields> <limit> -> JSON on stdout, or exit 2
  local out
  if ! out="$(cd "$repo" && gh_call pr list --state "$1" --json "$2" --limit "$3" 2>"$errf" </dev/null)"; then
    die "couldn't list $1 PRs ($(head -c 300 "$errf" | tr '\n' ' ')); an item that could possibly conflict must stop"
  fi
  jq -e 'type == "array"' >/dev/null 2>&1 <<<"$out" ||
    die "couldn't list $1 PRs (invalid JSON); an item that could possibly conflict must stop"
  printf '%s' "$out"
}
open_json="$(pr_list open number,headRefName,files 200)" || exit 2
merged_json="$(pr_list merged headRefName 300)" || exit 2

declare -A OPEN_HEAD=() MERGED_HEAD=()
while IFS= read -r h; do [ -n "$h" ] && OPEN_HEAD[$h]=1; done < <(jq -r '.[].headRefName' <<<"$open_json")
while IFS= read -r h; do [ -n "$h" ] && MERGED_HEAD[$h]=1; done < <(jq -r '.[].headRefName' <<<"$merged_json")

SKIPPED=()
is_merged_skip() { # <branch>: merged PR and no open PR; remembers it for the report
  [ -n "${MERGED_HEAD[$1]+x}" ] && [ -z "${OPEN_HEAD[$1]+x}" ] || return 1
  case " ${SKIPPED[*]:-} " in *" $1 "*) ;; *) SKIPPED+=("$1") ;; esac
  return 0
}

# --- live sources ------------------------------------------------------------
SRC_LABEL=() SRC_KIND=() SRC_REF=() SRC_FILES=()
add_source() { # <label> <kind wt|branch|pr> <ref for a dry run or ""> <files, newline separated>
  [ -n "$4" ] || return 0
  SRC_LABEL+=("$1")
  SRC_KIND+=("$2")
  SRC_REF+=("$3")
  SRC_FILES+=("$4")
}

# Uncommitted + untracked files of a worktree. -z keeps odd names intact; a
# rename or copy record is followed by the old path, and both count.
uncommitted_files() { # <dir>
  local rec status
  local -a recs=()
  mapfile -d '' recs < <(git -C "$1" status --porcelain -z --untracked-files=all 2>/dev/null)
  local i=0
  while [ "$i" -lt "${#recs[@]}" ]; do
    rec="${recs[$i]}"
    status="${rec:0:2}"
    printf '%s\n' "${rec:3}"
    case "$status" in *R* | *C*)
      i=$((i + 1))
      [ "$i" -lt "${#recs[@]}" ] && printf '%s\n' "${recs[$i]}"
      ;;
    esac
    i=$((i + 1))
  done
}
branch_files() { # <dir-or-empty> <ref>: files changed vs base
  git -C "${1:-$repo}" diff --name-only "$base...$2" 2>/dev/null
}

declare -A CHECKED_OUT=()
wt_paths=() wt_branches=() wt_heads=()
cur_path="" cur_branch="" cur_head="" cur_bare=0
flush_wt() {
  if [ -n "$cur_path" ] && [ "$cur_bare" = 0 ]; then
    wt_paths+=("$cur_path")
    wt_branches+=("$cur_branch")
    wt_heads+=("$cur_head")
    [ -n "$cur_branch" ] && CHECKED_OUT[$cur_branch]=1
  fi
  cur_path="" cur_branch="" cur_head="" cur_bare=0
}
while IFS= read -r l; do
  case "$l" in
    "worktree "*)
      flush_wt
      cur_path="${l#worktree }"
      ;;
    "HEAD "*) cur_head="${l#HEAD }" ;;
    "branch "*) cur_branch="${l#branch refs/heads/}" ;;
    bare) cur_bare=1 ;;
  esac
done < <(
  G worktree list --porcelain
  echo
)
flush_wt

for i in "${!wt_paths[@]}"; do
  p="${wt_paths[$i]}"
  b="${wt_branches[$i]}"
  [ -d "$p" ] || continue
  rp="$(cd "$p" && pwd -P)"
  [ "$mode" = commit ] && [ "$rp" = "$wtdir" ] && continue
  add_source "worktree $p (uncommitted)" wt "" "$(uncommitted_files "$p" | sort -u)"
  if [ -n "$b" ]; then
    [ "$b" = "$base_local" ] && continue
    is_merged_skip "$b" && continue
    add_source "branch $b (worktree $p)" branch "refs/heads/$b" "$(branch_files "$p" HEAD)"
  else
    add_source "HEAD detached (worktree $p)" branch "${wt_heads[$i]}" "$(branch_files "$p" HEAD)"
  fi
done

while IFS= read -r b; do
  [ -n "$b" ] || continue
  [ -z "${CHECKED_OUT[$b]+x}" ] || continue
  [ "$b" = "$base_local" ] && continue
  [ "$b" = "$own_branch" ] && continue
  is_merged_skip "$b" && continue
  add_source "branch $b" branch "refs/heads/$b" "$(branch_files "" "refs/heads/$b")"
done < <(G for-each-ref --format='%(refname:short)' refs/heads)

n_prs="$(jq 'length' <<<"$open_json")"
for ((i = 0; i < n_prs; i++)); do
  num="$(jq -r ".[$i].number" <<<"$open_json")"
  head="$(jq -r ".[$i].headRefName" <<<"$open_json")"
  [ "$head" = "$own_branch" ] && [ -n "$own_branch" ] && continue
  ref=""
  if G rev-parse --verify -q "refs/heads/$head" >/dev/null; then
    ref="refs/heads/$head"
  elif G rev-parse --verify -q "refs/remotes/origin/$head" >/dev/null; then ref="refs/remotes/origin/$head"; fi
  add_source "PR #$num ($head)" pr "$ref" "$(jq -r ".[$i].files[]?.path" <<<"$open_json")"
done

# --- matching ----------------------------------------------------------------
overlaps() { # <file> <planned path>...: equal, or under a planned dir ending in /
  local f="$1" p
  shift
  for p in "$@"; do
    case "$p" in
      */) [[ "$f" == "$p"* ]] && return 0 ;;
      *) [ "$f" = "$p" ] && return 0 ;;
    esac
  done
  return 1
}
is_generated() { # <file>
  case "$1" in
    docs/INDEX.md | docs/HUB.html | docs/try-it.*) return 0 ;;
    docs/*.html) G cat-file -e "$base:${1%.html}.md" 2>/dev/null && return 0 ;;
  esac
  return 1
}

declare -A BLK_COUNT=() BLK_FILES=() BLK_SEEN=()
overall=0

check_item() { # <id>
  local id="$1" f s label ref rc out conflicts
  local -a planned files stops=() notes=() gen=() actual=()
  read -ra planned <<<"${ITEM_PATHS[$id]}"
  files=("${planned[@]}")
  if [ "$mode" = commit ]; then
    mapfile -t actual < <({
      branch_files "$wtdir" HEAD
      uncommitted_files "$wtdir"
    } | sort -u)
    for f in "${actual[@]}"; do
      [ -n "$f" ] || continue
      overlaps "$f" "${planned[@]}" || notes+=("changed file not in plan: $f")
      files+=("$f")
    done
  fi

  for s in "${!SRC_LABEL[@]}"; do
    label="${SRC_LABEL[$s]}"
    gen=()
    local blocked=0
    while IFS= read -r f; do
      [ -n "$f" ] || continue
      overlaps "$f" "${files[@]}" || continue
      if is_generated "$f"; then
        gen+=("$f")
        continue
      fi
      stops+=("  $f  <- $label")
      blocked=1
      [ -z "${BLK_SEEN[$s | $f]+x}" ] && {
        BLK_SEEN[$s | $f]=1
        BLK_FILES[$s]+="${BLK_FILES[$s]:+, }$f"
      }
    done <<<"${SRC_FILES[$s]}"

    if [ "${#gen[@]}" -gt 0 ]; then
      local genlist
      genlist="$(join_comma "${gen[@]}")"
      ref="${SRC_REF[$s]}"
      if [ "$mode" = start ]; then
        notes+=("$genlist also changed by $label (generated; checked by merge dry run at commit)")
      elif [ "${SRC_KIND[$s]}" = wt ]; then
        notes+=("$genlist also edited, uncommitted, in $label (generated; not blocking)")
      elif [ -z "$ref" ]; then
        for f in "${gen[@]}"; do stops+=("  $f  <- $label (can't dry-run: no local ref for this PR)"); done
        blocked=1
      else
        out="$(G merge-tree --write-tree --name-only "$item_head" "$ref" 2>/dev/null)"
        rc=$?
        if [ "$rc" = 0 ]; then
          notes+=("$genlist also changed by $label; merge dry run is clean")
        else
          if [ "$rc" = 1 ]; then
            conflicts="$(sed -n '2,/^$/p' <<<"$out" | grep -v '^$' | tr '\n' ',' | sed 's/,$//; s/,/, /g')"
          else conflicts="dry run failed"; fi
          for f in "${gen[@]}"; do stops+=("  $f  <- merge dry run vs $label conflicts: $conflicts"); done
          blocked=1
        fi
      fi
    fi
    if [ "$blocked" = 1 ]; then BLK_COUNT[$s]=$((${BLK_COUNT[$s]:-0} + 1)); fi
  done

  if [ "${#stops[@]}" -gt 0 ]; then
    echo "STOP $id"
    printf '%s\n' "${stops[@]}"
    overall=1
  else
    echo "CLEAR $id"
  fi
  local n
  for n in "${notes[@]}"; do echo "NOTE $id: $n"; done
}

# --- run ---------------------------------------------------------------------
if [ "${#SKIPPED[@]}" -gt 0 ]; then
  echo "Skipped (PR already merged): $(join_comma "${SKIPPED[@]}")"
fi
for id in "${ITEM_IDS[@]}"; do check_item "$id"; done

if [ "$mode" = start ]; then
  if [ "${#BLK_COUNT[@]}" -gt 0 ]; then
    echo "Blocks per live source:"
    for s in "${!BLK_COUNT[@]}"; do
      printf '%s\t  %s: blocks %s item(s) via %s\n' "${BLK_COUNT[$s]}" "${SRC_LABEL[$s]}" "${BLK_COUNT[$s]}" "${BLK_FILES[$s]}"
    done | sort -t$'\t' -k1,1nr -k2,2 | cut -f2-
  fi

  # Live config symlinked from a feature worktree stays on old code after the
  # branch merges, until it's re-stowed from the main checkout.
  declare -A STOWED=()
  for root in ${LANES_STOW_ROOTS:-$HOME/.claude $HOME/.config}; do
    [ -d "$root" ] || continue
    while IFS= read -r link; do
      raw="$(readlink "$link")"
      res="$(readlink -f "$link" 2>/dev/null || true)"
      for cand in "$res" "$raw"; do
        case "$cand" in
          */.worktrees/*)
            pre="${cand%%/.worktrees/*}"
            rest="${cand#*/.worktrees/}"
            key="$pre/.worktrees/${rest%%/*}"
            STOWED[$key]=$((${STOWED[$key]:-0} + 1))
            break
            ;;
        esac
      done
    done < <(find "$root" -maxdepth 6 -type l 2>/dev/null)
  done
  if [ "${#STOWED[@]}" -gt 0 ]; then
    parts=""
    while IFS= read -r d; do parts+="${parts:+, }${STOWED[$d]} link(s) into $d"; done < <(printf '%s\n' "${!STOWED[@]}" | sort)
    echo "WARN live config stowed from a feature worktree: $parts — merged work won't go live until a re-stow from the main checkout"
  fi
fi

exit "$overall"
