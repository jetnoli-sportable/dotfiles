#!/usr/bin/env bash
# wb-done-sweep.sh — `wb done`'s sweep classifier: reads wb-done-sweep.list and
# sorts a worktree's untracked and ignored paths into keep / throwaway / unknown
# before teardown. Sourced by wb.sh as a sibling module, split out of wb.sh verbatim
# (dotfiles--wb-sweep-own-file).
# wb.sh sources it only if present, so every other wb command keeps working
# between a merge and the re-stow that links this file.

# wb_sweep_lists — print the `wb done` sweep rules as `keep<TAB>glob` /
# `throwaway<TAB>glob`, from wb-done-sweep.list next to wb.sh (resolved through
# symlinks, since the stowed script is a link), then from this machine's own
# list, ~/.config/wb/sweep.local.list. The local list is never committed, so
# rules naming one repo's paths stay out of the dotfiles repo. $WB_SWEEP_LIST
# and $WB_SWEEP_LOCAL_LIST override the paths for tests; setting only
# $WB_SWEEP_LIST skips the local list, so a test never reads the real one.
wb_sweep_lists() {
  local list="${WB_SWEEP_LIST:-$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/wb-done-sweep.list}"
  local local_list="${WB_SWEEP_LOCAL_LIST-}"
  [ -n "$local_list" ] || [ -n "${WB_SWEEP_LIST-}" ] ||
    local_list="${XDG_CONFIG_HOME:-$HOME/.config}/wb/sweep.local.list"
  _wb_sweep_read_list "$list"
  [ -z "$local_list" ] || _wb_sweep_read_list "$local_list"
  return 0
}

_wb_sweep_read_list() {
  local list="$1"
  [ -f "$list" ] || return 0
  local line cls glob
  while IFS= read -r line || [ -n "$line" ]; do
    line="${line#"${line%%[![:space:]]*}"}"
    line="${line%"${line##*[![:space:]]}"}"
    case "$line" in
      ''|'#'*) continue ;;
      keep:*) cls=keep; glob="${line#keep:}" ;;
      throwaway:*) cls=throwaway; glob="${line#throwaway:}" ;;
      *) continue ;;
    esac
    glob="${glob#"${glob%%[![:space:]]*}"}"
    [ -n "$glob" ] && printf '%s\t%s\n' "$cls" "$glob"
  done < "$list"
  return 0
}

# _wb_sweep_glob_hit <glob> <rel> <isdir> — gitignore-style match: no inner `/`
# matches the last path component, otherwise the whole relative path; a
# trailing `/` needs a directory.
_wb_sweep_glob_hit() {
  local g="$1" rel="$2" isdir="$3"
  if [[ $g == */ ]]; then
    [ "$isdir" = 1 ] || return 1
    g="${g%/}"
  fi
  g="${g#/}"
  if [[ $g == */* ]]; then
    # shellcheck disable=SC2053
    [[ $rel == $g ]]
  else
    # shellcheck disable=SC2053
    [[ ${rel##*/} == $g ]]
  fi
}

# _wb_sweep_in_list <name> <rel> <isdir> — true when <rel>, or any ancestor
# directory of it, matches a glob in the array named <name>.
_wb_sweep_in_list() {
  local -n _globs="$1"
  local rel="$2" isdir="$3" g cand="$2"
  [ "${#_globs[@]}" -gt 0 ] || return 1
  while :; do
    for g in "${_globs[@]}"; do
      _wb_sweep_glob_hit "$g" "$cand" "$isdir" && return 0
    done
    case "$cand" in */*) cand="${cand%/*}"; isdir=1 ;; *) break ;; esac
  done
  return 1
}

# _wb_sweep_flagged <name> <rel> — true when <rel> is, or sits under, a path
# in the array named <name>. Flags name exact worktree paths, never globs.
_wb_sweep_flagged() {
  local -n _paths="$1"
  local p
  for p in ${_paths[@]+"${_paths[@]}"}; do
    [ "$2" = "$p" ] && return 0
    case "$2" in "$p"/*) return 0 ;; esac
  done
  return 1
}

# _wb_sweep_esc <s> — <s> with tab, newline and CR shown as \t \n \r and every
# other control byte (below 0x20, and 0x7f) as \xNN, so a file name can never
# break a `class<TAB>path<TAB>note` line apart, forge a second one, or send a
# terminal escape sequence to the screen. Pure bash: a name with no control
# byte (the usual case) costs one glob match; only one that has some is walked
# a character at a time, with the printf builtin (no subprocess).
_wb_sweep_esc() {
  local s="$1"
  if [[ $s == *[[:cntrl:]]* ]]; then
    local out="" c n i
    for ((i = 0; i < ${#s}; i++)); do
      c="${s:i:1}"
      case "$c" in
        $'\t') out+='\t' ;;
        $'\n') out+='\n' ;;
        $'\r') out+='\r' ;;
        *)
          LC_ALL=C printf -v n '%d' "'$c"
          if [ "$n" -lt 32 ] || [ "$n" -eq 127 ]; then
            printf -v n '\\x%02x' "$n"; out+="$n"
          else
            out+="$c"
          fi ;;
      esac
    done
    s="$out"
  fi
  printf '%s' "$s"
}

# _wb_sweep_keepcheck <worktree> <rel> — fail with a note on stdout when
# keeping <rel> is unsafe: any component of <rel> credential-shaped, a symlink
# resolving outside the worktree, or a directory holding a credential-shaped
# file or directory, or such a symlink, at any depth (walked with find -P, so
# symlinks are inspected, never followed).
_wb_sweep_keepcheck() {
  local wt="$1" rel="$2" wt_real f part rest="$2"
  # The dossier's own records live at its top level; a keeper by one of those
  # names would be copied over (or collide with) them.
  case "${rel%%/*}" in
    decisions|handoffs|open-items|brief.md|concepts.md|CONCEPTS.md|notes.md|index.md|decisions.md|handoffs.md)
      echo "a dossier record name; rename it first"; return 1 ;;
  esac
  while :; do
    part="${rest%%/*}"
    if wb_credential_shaped "$part"; then
      case "$rest" in
        */*) echo "inside credential-shaped $(_wb_sweep_esc "$part")/, copy it yourself" ;;
        *) echo "credential-shaped, copy it yourself" ;;
      esac
      return 1
    fi
    case "$rest" in */*) rest="${rest#*/}" ;; *) break ;; esac
  done
  wt_real="$(realpath -m -- "$wt")"
  if [ -L "$wt/$rel" ]; then
    case "$(realpath -m -- "$wt/$rel")" in
      "$wt_real"/*) ;;
      *) echo "symlink resolves outside the worktree"; return 1 ;;
    esac
  elif [ -d "$wt/$rel" ]; then
    while IFS= read -r -d '' f; do
      if wb_credential_shaped "$f"; then
        echo "holds credential-shaped $(_wb_sweep_esc "${f#"$wt"/}"), copy it yourself"; return 1
      fi
      if [ -L "$f" ]; then
        case "$(realpath -m -- "$f")" in
          "$wt_real"/*) ;;
          *) echo "holds symlink $(_wb_sweep_esc "${f#"$wt"/}") resolving outside the worktree"; return 1 ;;
        esac
        # A link that stays inside the worktree would dangle in the dossier
        # once the worktree is gone (keep copies are cp -a, never -L).
        echo "holds symlink $(_wb_sweep_esc "${f#"$wt"/}"); keep its target or remove the link"; return 1
      fi
    done < <(find -P "$wt/$rel" -mindepth 1 \( -type f -o -type l -o -type d \) -print0 2>/dev/null)
  fi
  return 0
}

# _wb_sweep_emit <class> <rel> <out> [note] — print one output line and record
# <rel>'s class in the caller's `seen` map, which the flag pass after the walk
# reads.
_wb_sweep_emit() {
  printf '%s\t%s\t%s\n' "$1" "$3" "${4:-}"
  seen["$2"]="$1"
}

# _wb_sweep_emit_keep <rel> <out> — a keep line for <rel> when _wb_sweep_keepcheck
# passes, else an unknown line carrying its note. Uses the caller's wt.
_wb_sweep_emit_keep() {
  local note
  if note="$(_wb_sweep_keepcheck "$wt" "$1")"; then
    _wb_sweep_emit keep "$1" "$2"
  else
    _wb_sweep_emit unknown "$1" "$2" "$note"
  fi
}

# _wb_sweep_ancestor <rel> — print the nearest recorded entry that <rel> sits
# under, as `class<TAB>path`; fail when there is none.
_wb_sweep_ancestor() {
  local cand="$1"
  while [[ $cand == */* ]]; do
    cand="${cand%/*}"
    if [ -n "${seen[$cand]+x}" ]; then printf '%s\t%s' "${seen[$cand]}" "$cand"; return 0; fi
  done
  return 1
}

# _wb_sweep_covered <rel> — true when an entry equal to <rel>, or under it, was
# printed (so a flag on <rel> already applied during the walk).
_wb_sweep_covered() {
  local k
  [ -n "${seen[$1]+x}" ] && return 0
  for k in "${!seen[@]}"; do
    [[ $k == "$1"/* ]] && return 0
  done
  return 1
}

# _wb_sweep_one <rel> <out> — classify one entry and print its line. Uses the
# caller's (wb_sweep_classify's) locals: wt, main, the flag arrays, the globs
# and the bootstrap list.
_wb_sweep_one() {
  local rel="$1" out="$2" isdir=0 note f
  case "$rel" in
    *$'\t'*|*$'\n'*|*$'\r'*)
      _wb_sweep_emit unknown "$rel" "$(_wb_sweep_esc "$out")" 'name holds a tab or line break, handle it yourself'
      return 0 ;;
  esac
  [ -d "$wt/$rel" ] && isdir=1
  if _wb_sweep_flagged tw_flags "$rel"; then
    _wb_sweep_emit throwaway "$rel" "$out"; return 0
  fi
  if _wb_sweep_flagged keep_flags "$rel"; then
    # A refused --keep is unknown even if the file matches main: the user asked
    # to keep it, so silently discarding it would surprise.
    _wb_sweep_emit_keep "$rel" "$out"
    return 0
  fi
  for f in ${boot[@]+"${boot[@]}"}; do
    [ "$f" = "$rel" ] || continue
    if [ -L "$wt/$rel" ]; then
      _wb_sweep_emit throwaway "$rel" "$out"; return 0
    elif [ -f "$wt/$rel" ] && [ -f "$main/$rel" ] && cmp -s "$wt/$rel" "$main/$rel"; then
      _wb_sweep_emit throwaway "$rel" "$out"; return 0
    fi
  done
  if wb_credential_shaped "$rel"; then
    _wb_sweep_emit unknown "$rel" "$out" 'credential-shaped, copy it yourself'; return 0
  fi
  if _wb_sweep_in_list keep_globs "$rel" "$isdir"; then
    _wb_sweep_emit_keep "$rel" "$out"
    return 0
  fi
  if _wb_sweep_in_list tw_globs "$rel" "$isdir"; then
    _wb_sweep_emit throwaway "$rel" "$out"; return 0
  fi
  if [ "$isdir" = 1 ] && [ ! -L "$wt/$rel" ]; then
    # One level at a time, so a nested directory (a cloned project's
    # node_modules/) meets the lists as a directory and is classified whole,
    # instead of each file inside it being judged on its own name.
    local n=0 child
    while IFS= read -r -d '' f; do
      n=$((n + 1))
      child="${f#"$wt"/}"
      if [ -d "$f" ] && [ ! -L "$f" ]; then
        _wb_sweep_one "$child" "$child/"
      else
        _wb_sweep_one "$child" "$child"
      fi
    done < <(find -P "$wt/$rel" -mindepth 1 -maxdepth 1 -print0 2>/dev/null | sort -z)
    # Nothing listed: an empty directory loses nothing when removed, but one
    # find could not read may hold anything.
    if [ "$n" -eq 0 ]; then
      if [ -r "$wt/$rel" ] && [ -x "$wt/$rel" ]; then
        _wb_sweep_emit throwaway "$rel" "$out" 'empty directory'
      else
        _wb_sweep_emit unknown "$rel" "$out" 'cannot read this directory'
      fi
    fi
    return 0
  fi
  _wb_sweep_emit unknown "$rel" "$out"
}

# wb_sweep_classify <worktree> <main_checkout> [--keep <p>]... [--throwaway <p>]...
# — sort the worktree's gitignored entries into keep / throwaway / unknown,
# one `class<TAB>path<TAB>note` line each (directories keep their trailing
# `/`). Rows are tried in the order of the plan's "Sweep classification" table.
# The flags classify a named path for this run only; one naming a missing path
# or an unsafe one warns on stderr and is ignored.
wb_sweep_classify() {
  [ "$#" -ge 2 ] || { echo "wb_sweep_classify: usage: <worktree> <main> [--keep p]... [--throwaway p]..." >&2; return 2; }
  local wt="$1" main="$2"; shift 2
  local -a keep_flags=() tw_flags=() keep_globs=() tw_globs=() boot=()
  local p safe
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --keep|--throwaway)
        [ "$#" -ge 2 ] || { echo "wb_sweep_classify: $1 needs a path" >&2; return 2; }
        p="${2%/}"
        if [ "$1" = --keep ]; then
          # Containment-check the PARENT directory only and keep the last
          # component as written, so `--keep scratch/ln` keeps the link itself
          # (what the walk sees), not the file it points at. _wb_sweep_keepcheck
          # still refuses a link resolving outside the worktree.
          local pd="${p%/*}" pl="${p##*/}" sd=""
          [ "$pd" = "$p" ] && pd="."
          case "$pl" in ''|.|..) pl="" ;; esac
          if [ -n "$pl" ] && { [ "$pd" = "." ] || sd="$(wb_safe_rel "$wt" "$pd")"; }; then
            safe="${sd:+$sd/}$pl"
            if [ -e "$wt/$safe" ] || [ -L "$wt/$safe" ]; then keep_flags+=("$safe")
            else echo "wb: --keep $p: no such path, ignored" >&2; fi
          else
            echo "wb: --keep $p: outside the worktree, ignored" >&2
          fi
        else
          # Lexical check only: bootstrap symlinks point into the main checkout.
          case "$p" in
            /*|..|../*|*/..|*/../*) echo "wb: --throwaway $p: outside the worktree, ignored" >&2 ;;
            *) if [ -e "$wt/$p" ] || [ -L "$wt/$p" ]; then tw_flags+=("$p")
               else echo "wb: --throwaway $p: no such path, ignored" >&2; fi ;;
          esac
        fi
        shift 2 ;;
      *) echo "wb_sweep_classify: unknown argument: $1" >&2; return 2 ;;
    esac
  done
  local cls glob
  while IFS=$'\t' read -r cls glob; do
    if [ "$cls" = keep ]; then keep_globs+=("$glob"); else tw_globs+=("$glob"); fi
  done < <(wb_sweep_lists)
  mapfile -d '' boot < <(wb_bootstrap_entries "$main")
  # Read git's whole answer before classifying anything: an empty answer must
  # mean "nothing ignored", never "git failed" — W6 removes the worktree on
  # an empty, unknown-free result. --untracked-files=normal overrides a
  # status.showUntrackedFiles=no config, which would otherwise hide every
  # ignored entry too.
  local -a recs=()
  if [ ! -d "$wt" ]; then
    echo "wb_sweep_classify: $wt is not a directory" >&2; return 1
  fi
  mapfile -d '' recs < <(git -C "$wt" status --porcelain=v1 -z --ignored=traditional --untracked-files=normal)
  if ! wait "$!"; then
    echo "wb_sweep_classify: git status failed in $wt, nothing classified" >&2; return 1
  fi
  local rec rel
  local -A seen=()
  for rec in ${recs[@]+"${recs[@]}"}; do
    case "$rec" in '!! '*) ;; *) continue ;; esac
    rel="${rec#'!! '}"
    _wb_sweep_one "${rel%/}" "$rel"
  done
  # Flags the walk never reached. Git reports a fully ignored directory once
  # (`logs/`), so a --keep on a file inside it gets its own extra line here —
  # W6 copies keep lines before removing the worktree, so `throwaway logs/`
  # and `keep logs/notes.log` together keep that one file.
  local anc note out
  for p in ${keep_flags[@]+"${keep_flags[@]}"}; do
    _wb_sweep_covered "$p" && continue
    if anc="$(_wb_sweep_ancestor "$p")"; then
      [ "${anc%%$'\t'*}" = keep ] && continue
      out="$p"; [ -d "$wt/$p" ] && [ ! -L "$wt/$p" ] && out="$p/"
      case "$p" in
        *$'\t'*|*$'\n'*|*$'\r'*)
          _wb_sweep_emit unknown "$p" "$(_wb_sweep_esc "$out")" 'name holds a tab or line break, handle it yourself' ;;
        *)
          _wb_sweep_emit_keep "$p" "$out" ;;
      esac
    else
      echo "wb: --keep $(_wb_sweep_esc "$p"): matched no ignored entry, ignored" >&2
    fi
  done
  for p in ${tw_flags[@]+"${tw_flags[@]}"}; do
    _wb_sweep_covered "$p" && continue
    if anc="$(_wb_sweep_ancestor "$p")"; then
      [ "${anc%%$'\t'*}" = keep ] &&
        echo "wb: --throwaway $(_wb_sweep_esc "$p"): inside kept ${anc#*$'\t'}/, kept with it" >&2
    else
      echo "wb: --throwaway $(_wb_sweep_esc "$p"): matched no ignored entry, ignored" >&2
    fi
  done
  return 0
}
