#!/usr/bin/env bash
# replay-refusals.sh -- X7 read-only replay tool (concurrency-safety plan,
# unit U9). Standalone script, NOT a `wb` verb: no dispatch-table entry, no
# header usage line in wb.sh. Its only job is to approximate, retroactively
# against a real repo's reflog HISTORY, what the `reference-transaction`
# hook (U6, same directory) would have done live -- so a human can read its
# output and decide whether the git-side hook is safe to actually enable.
#
# THE GATE THIS SCRIPT SERVES: the git-side hook must never be enabled
# before this replay has been run against the real store and a human has
# confirmed the output looks right (see --record-pass below). This script
# cannot make that judgment itself -- it has no way to know which refusals
# are "the two known incidents" vs. some other legitimate refusal -- that
# read is a human's job every time.
#
# WHAT "REPLAYING" MEANS HERE, AND WHY IT IS ONLY AN APPROXIMATION:
# The live hook, at H12, asks "is this commit reachable from any OTHER ref,
# RIGHT NOW" via `git for-each-ref` -- a live snapshot. Replaying against
# history has no live snapshot from the past; the only per-ref record of
# where a ref pointed over time is that ref's OWN reflog. So for every
# refs/heads/* ref's own reflog, walked oldest-to-newest, each consecutive
# (old, new, timestamp) triple is one "transition" to evaluate -- and the
# central approximation is how to answer "where did every OTHER ref point
# at that historical moment" using only reflogs.
#
# PINNED METHOD -- per-ref reflog TIME-SLICES:
#   For a transition on ref R at time T (T = the reflog timestamp of the
#   entry that recorded R moving to `new` -- i.e. the moment this old->new
#   update actually happened), every OTHER ref X (of ANY kind -- heads,
#   tags, refs/remotes/* -- deliberately matching H12's own
#   `for-each-ref`-minus-self scope, not just other local branches) is
#   time-sliced: walk X's own reflog and take whichever entry's value X
#   held at-or-before T (the entry that would have been X's live position
#   if `git for-each-ref` had been run at moment T). The union of "reachable
#   from any of these historical time-sliced positions" is the "not
#   orphaned" set for that transition; anything in old's history not
#   reachable from that union is a would-be-orphan.
#
# BIAS-TOWARD-ALLOWING CHOICES (deliberate -- X7 pins false-negatives as
# acceptable and false-positives as NOT acceptable, since this replay is
# specifically validating that the hook will not be a false-positive
# machine before anyone flips it on):
#
#   1. Ref X has NO reflog entry at-or-before T (X's own reflog starts
#      later than T, or has no entries at all -- sparse data, an expired
#      reflog, whatever the cause): fall back to X's CURRENT (present-day)
#      live value rather than excluding X entirely. Current value can only
#      ADD commits to the reachable-from-other-refs union versus excluding
#      X outright (a ref's positions only ever accumulate more reachable
#      history as it moves forward in the common case) -- so this fallback
#      is a strict superset of the "exclude X" alternative and can only
#      turn a would-be REFUSE into an ALLOW, never the reverse. Verified
#      empirically (git 2.43.0): a ref with reflogs disabled/never enabled
#      (core.logAllRefUpdates=false) or a tag (which by default gets NO
#      reflog at all) produces a clean, silent, exit-0 empty result from
#      both `git reflog show` and `git log -g` -- there is no error case to
#      handle here, only an empty-data case, and the fallback covers it.
#
#   2. The EARLIEST reflog entry for any given ref is treated as a
#      creation/history-start BOUNDARY, not a transition to evaluate --
#      exactly like H14's "old is all-zero -> allow unconditionally"
#      handling in the live hook. This is deliberately ambiguous by
#      necessity: a ref's oldest surviving reflog entry might mean "this
#      ref was truly created here" (H14 genuinely applies) OR it might mean
#      "this ref existed earlier but its reflog was trimmed/expired before
#      this entry" (we simply cannot see further back). Both cases get the
#      SAME treatment -- skip evaluating a transition into that first
#      entry -- which is the wider, allow-biased choice in either reading:
#      if it really was a creation, H14 says allow outright; if it was a
#      gap, we have no `old` value to check reachability against anyway,
#      so silently not-flagging it (rather than inventing a bogus `old`)
#      is the only honest option that cannot manufacture a false refusal.
#
#   3. BRANCH DELETIONS ARE A KNOWN, DOCUMENTED BLIND SPOT OF THIS REPLAY
#      (not a bias that can go either direction -- a hard limitation):
#      verified empirically (git 2.43.0, "files" ref-storage backend) that
#      `git branch -D` deletes the ref's ENTIRE reflog file rather than
#      appending a final all-zero "new" line, and separately, even if a
#      zero-new line WERE present in a reflog file, both `git reflog show`
#      and `git log -g` silently SKIP it (they only walk valid revisions).
#      Net effect: a branch that no longer exists by the time this script
#      runs leaves no reflog trace to replay its deletion event against,
#      under any git command this script can use. This script still
#      contains a generic, symmetric branch for a zero "new" value (mirrors
#      H12's deletion form: reachability of the pre-deletion tip against
#      OTHER refs only, no `new` in the exclusion set) so the logic is
#      forward-compatible with a git version/backend where such a line
#      might surface -- but on git 2.43.0 with the standard "files" backend
#      this branch is provably dead code, verified live during this
#      script's own development. Deletions of branches that still exist
#      today obviously never hit this path either (their own reflog's
#      final entry is a real, non-zero value). This blind spot means a
#      historical deletion that SHOULD have been refused could go entirely
#      unreplayed (a false negative -- the acceptable failure mode) but it
#      can never manufacture a false REFUSE, since an unreplayed transition
#      simply produces no verdict line at all.
#
#      H13's *hardcoded* "refuse deleting refs/heads/development
#      unconditionally, reachability aside" special case is NOT replayed
#      here on purpose: that is a live-hook runtime POLICY carve-out, not
#      part of the H11/H12 reachability approximation this tool exists to
#      validate, and X7 only asks for "the H11/H12 (and H13/H14 zero-OID)
#      reachability logic," not the hardcoded branch-name policy layered on
#      top of it in the live hook.
#
# WHAT THIS SCRIPT DOES NOT REPLAY: H15/H16 (the /dev/tty prompt and the
# WB_ALLOW_REWIND sentinel) are runtime-only concerns of the LIVE hook --
# meaningless against static history, since there is no live "prepared"
# transaction and no operator sitting at a terminal to answer a prompt for
# a git command that already finished, possibly years ago.
#
# OUTPUT CONTRACT: one verdict line per NON-fast-forward transition (fast
# forwards are the overwhelming majority of ordinary history and are only
# ever reported as a single skipped-count, never one line each). A final
# summary line names totals, refusals (which ref/transition), and allows.
#
# --record-pass: the ONLY way this script ever writes the `replay-passed`
# marker file U8's `wb install-hooks` checks for
# (${XDG_STATE_HOME:-$HOME/.local/state}/wb/replay-passed). A plain run
# (no flag) NEVER writes it, no matter how clean the output looks -- this
# script has no way to independently verify WHICH transitions were "the
# known incidents" vs. some other legitimate refusal; that judgment belongs
# to a human reading the output above. Pass --record-pass only after you
# have read the output and confirmed it refuses exactly the expected
# incidents and allows everything else. Writing this marker does NOT
# enable the hook -- it only stops a future `wb install-hooks` re-run from
# re-creating the `disable-git-hook` switch file. The actual enablement act
# is a separate, manual, human `rm
# ${XDG_STATE_HOME:-$HOME/.local/state}/wb/disable-git-hook`.
#
# Usage:
#   replay-refusals.sh [--repo <path>] [--record-pass]
#   --repo <path>   Repo to replay against. Defaults to
#                   ${TASKS_DIR:-$HOME/code/tasks} (same override-safe
#                   convention as reference-transaction and wb.sh -- lets
#                   this be pointed at a throwaway fixture repo in tests).
#   --record-pass   After printing the normal replay output, write the
#                   replay-passed marker. See the header note above for
#                   exactly what this does and does not mean.
#
# Deliberately NOT `set -e`, matching every other script in this directory
# (pretooluse-guard.sh, reference-transaction): several checks below
# (`merge-base --is-ancestor`, `rev-parse --verify -q`) are expected to
# fail as ordinary control flow, not as script errors.
set -uo pipefail

usage() {
  cat <<'EOF'
Usage: replay-refusals.sh [--repo <path>] [--record-pass]

Read-only X7 replay: approximates, against a repo's real reflog history,
what the reference-transaction hook would have refused. Never mutates the
repo. See this script's own header comment for the full algorithm and its
documented bias-toward-allowing choices.

  --repo <path>    Repo to replay (default: ${TASKS_DIR:-$HOME/code/tasks})
  --record-pass    After printing output, write the replay-passed marker
                   at ${XDG_STATE_HOME:-$HOME/.local/state}/wb/replay-passed.
                   Only ever run this after YOU have read the output above
                   and confirmed it refuses only the expected incidents.
EOF
}

REPO=""
RECORD_PASS=0
while [ $# -gt 0 ]; do
  case "$1" in
    --repo)
      REPO="${2:-}"
      shift 2
      ;;
    --repo=*)
      REPO="${1#--repo=}"
      shift
      ;;
    --record-pass)
      RECORD_PASS=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "replay-refusals.sh: unknown argument: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

REPO="${REPO:-${TASKS_DIR:-$HOME/code/tasks}}"

if ! git -C "$REPO" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  echo "replay-refusals.sh: not a git repository: $REPO" >&2
  exit 2
fi
REPO="$(cd "$REPO" && git rev-parse --show-toplevel)"

marker_dir="${XDG_STATE_HOME:-$HOME/.local/state}/wb"
marker_file="$marker_dir/replay-passed"

is_zero() { # <oid> -- true for the all-zeros OID (any hash length)
  [[ "$1" =~ ^0+$ ]]
}

TMP="$(mktemp -d -t replay-refusals.XXXXXX)"
cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT

# reflog_entries_to_file <ref> <outfile>
# Writes "<unix-ts>\t<sha>" lines, one per reflog entry, OLDEST FIRST, to
# <outfile>. Empty file (zero bytes) means "no reflog entries" -- verified
# empirically to be a clean, silent, exit-0 case for both a
# reflogs-never-enabled ref and a tag (tags get no reflog by default), not
# an error condition needing special-case handling.
#
# %gd's date representation (controlled by --date=unix) is the reflog
# ENTRY's own recorded timestamp -- i.e. the moment that ref moved to the
# value on that line -- not the commit's author/committer date, which is
# exactly the "when did this transition happen" moment X7 needs. Refnames
# cannot contain the literal sequence "@{" (git-check-ref-format forbids
# it), so extracting the trailing @{<digits>} out of %gd is unambiguous
# regardless of what the ref itself is named.
reflog_entries_to_file() {
  local ref="$1" outfile="$2"
  git -C "$REPO" log -g --date=unix --format='%H%x01%gd' "$ref" 2>/dev/null \
    | awk -F'\x01' '
        {
          gd = $2
          if (match(gd, /@\{[0-9]+\}$/)) {
            ts = substr(gd, RSTART + 2, RLENGTH - 3)
            print ts "\t" $1
          }
        }
      ' \
    | tac > "$outfile" 2>/dev/null || : > "$outfile"
}

# value_at <idx> <T> -- prints the ref at index <idx>'s value at-or-before
# unix timestamp <T>, per its own time-sliced reflog; falls back to that
# ref's CURRENT live value if no entry at-or-before T exists (bias #1
# above). Pure/read-only -- safe to call via command substitution.
#
# NOTE the two separate `local` statements below, deliberately not merged
# into one `local idx=... f="...$idx"` line: bash expands every word of a
# single `local a=X b=$a` command BEFORE any of that command's assignments
# take effect, so `$a` in `b`'s value would resolve against whatever `a`
# meant in the CALLER's scope, not the value this same statement is trying
# to assign it -- a real bug caught during this script's own development
# (an ambient caller-scope `idx` loop variable was silently leaking into
# every call here, making every "other ref" lookup secretly re-read the
# CALLER's own ref instead of the requested one). Splitting the
# declaration so `idx` is fully local before `f` reads it avoids the trap
# entirely, regardless of what variable names any future caller happens to
# use.
value_at() {
  local idx="$1" t="$2"
  local f="$TMP/rl_$idx" v=""
  if [ -s "$f" ]; then
    v="$(awk -F'\t' -v t="$t" '($1+0)<=t{v=$2} END{print v}' "$f")"
  fi
  if [ -z "$v" ]; then
    v="${CURVAL_ARR[$idx]:-}"
  fi
  printf '%s' "$v"
}

# --- build the ref universe (sorted for stable, legible output) -------------
mapfile -t ALL_REFS < <(git -C "$REPO" for-each-ref --format='%(refname)' | sort)

declare -A CURVAL_ARR
for i in "${!ALL_REFS[@]}"; do
  CURVAL_ARR[$i]="$(git -C "$REPO" rev-parse --verify -q "${ALL_REFS[$i]}" 2>/dev/null || true)"
  reflog_entries_to_file "${ALL_REFS[$i]}" "$TMP/rl_$i"
done

# --- global tallies ----------------------------------------------------------
refs_examined=0
refs_empty_reflog=0
creation_boundaries=0
ff_skipped=0
nonff_examined=0
refuse_count=0
allow_count=0
uneval_count=0
REFUSE_SUMMARY=()
ALLOW_SUMMARY=()
UNEVAL_SUMMARY=()

short() { git -C "$REPO" rev-parse --short "$1" 2>/dev/null || printf '%s' "$1"; }
human_ts() { date -d "@$1" '+%Y-%m-%dT%H:%M:%S%z' 2>/dev/null || printf '@%s' "$1"; }

# evaluate_transition <ref> <self_idx> <old> <new> <T>
# Prints one verdict line (H12's non-fast-forward reachability check,
# time-sliced per the header's pinned method) and updates global tallies.
# Not called via command substitution -- it must mutate the caller's
# globals directly, which a `$(...)` subshell would silently discard.
evaluate_transition() {
  local ref="$1" self_idx="$2" old="$3" new="$4" T="$5"
  local other_vals=() v j
  for ((j = 0; j < ${#ALL_REFS[@]}; j++)); do
    [ "$j" -eq "$self_idx" ] && continue
    v="$(value_at "$j" "$T")"
    [ -n "$v" ] && other_vals+=("$v")
  done

  local old_s new_s ts_h desc
  old_s="$(short "$old")"; new_s="$(short "$new")"; ts_h="$(human_ts "$T")"
  desc="$ref  ${old_s}..${new_s}  @${T} ($ts_h)"

  # Distinguish "computed zero orphans" (rev-list succeeded, printed
  # nothing) from "could not compute at all" (rev-list itself failed) --
  # a prior version piped both through `2>/dev/null || true`, so a genuine
  # internal failure during replay silently read as a clean ALLOW in the
  # report a human uses to decide whether to enable the live hook. This
  # tool's whole purpose is to surface exactly this kind of gap before
  # that decision, not hide it behind a fabricated-looking ALLOW reason.
  local orphaned="" rev_list_err
  if [ "${#other_vals[@]}" -gt 0 ]; then
    if ! orphaned="$(git -C "$REPO" rev-list "$old" --not "$new" "${other_vals[@]}" 2>&1)"; then
      rev_list_err="$orphaned"; orphaned=""
      uneval_count=$((uneval_count + 1))
      UNEVAL_SUMMARY+=("$desc")
      echo "NOTICE - $desc"
      echo "         reason: could not evaluate (git rev-list failed: $rev_list_err) -- NOT represented in the REFUSE/ALLOW counts above; treat this transition as unaudited, not as a passing ALLOW"
      return
    fi
  else
    if ! orphaned="$(git -C "$REPO" rev-list "$old" --not "$new" 2>&1)"; then
      rev_list_err="$orphaned"; orphaned=""
      uneval_count=$((uneval_count + 1))
      UNEVAL_SUMMARY+=("$desc")
      echo "NOTICE - $desc"
      echo "         reason: could not evaluate (git rev-list failed: $rev_list_err) -- NOT represented in the REFUSE/ALLOW counts above; treat this transition as unaudited, not as a passing ALLOW"
      return
    fi
  fi

  if [ -n "$orphaned" ]; then
    refuse_count=$((refuse_count + 1))
    REFUSE_SUMMARY+=("$desc")
    local n_orphaned
    n_orphaned="$(printf '%s\n' "$orphaned" | grep -c .)"
    echo "REFUSE - $desc"
    echo "         reason: $n_orphaned commit(s) orphaned, none reachable from any other ref's time-sliced position"
    printf '%s\n' "$orphaned" | sed -n '1,10p' | while IFS= read -r c; do
      [ -z "$c" ] && continue
      git -C "$REPO" log -1 --format='           %h %s' "$c" 2>/dev/null || printf '           %s\n' "$c"
    done
  else
    allow_count=$((allow_count + 1))
    ALLOW_SUMMARY+=("$desc")
    # Find a single covering ref for a legible message: if old is an
    # ancestor of some other ref's time-sliced value, that ref's history
    # alone covers everything reachable from old (a superset relationship
    # -- see header comment), which is always at least as much as the
    # actual would-be-orphan candidate set.
    local covering="" cov_j cov_v
    for ((cov_j = 0; cov_j < ${#ALL_REFS[@]}; cov_j++)); do
      [ "$cov_j" -eq "$self_idx" ] && continue
      cov_v="$(value_at "$cov_j" "$T")"
      [ -z "$cov_v" ] && continue
      if git -C "$REPO" merge-base --is-ancestor "$old" "$cov_v" 2>/dev/null; then
        covering="${ALL_REFS[$cov_j]}"
        break
      fi
    done
    echo "ALLOW  - $desc"
    if [ -n "$covering" ]; then
      echo "         reason: reachable via $covering at time-slice @${T} ($ts_h)"
    else
      echo "         reason: union of other refs' time-sliced positions covers the would-be-orphaned commit(s) (no single ref alone)"
    fi
  fi
}

echo "=== replay-refusals: $REPO ==="
echo "(read-only; approximates reference-transaction's H11/H12 logic against reflog history -- see this script's header for the algorithm and its documented biases)"
echo

# Deliberately named `ref_idx`, not `idx` -- `value_at`'s own parameter is
# named `idx`, and the bash `local a=X b=$a` gotcha documented above this
# function bites hardest when an outer (non-local, top-level-script)
# variable happens to share a callee's parameter name: any accidental
# regression back to a combined `local` declaration inside a helper would
# then silently start reading THIS loop's current ref instead of whatever
# index was actually passed in. Different names make that class of bug
# structurally impossible to reintroduce by accident here.
for ref_idx in "${!ALL_REFS[@]}"; do
  ref="${ALL_REFS[$ref_idx]}"
  case "$ref" in
    refs/heads/*) ;;
    *) continue ;;
  esac
  refs_examined=$((refs_examined + 1))

  if [ ! -s "$TMP/rl_$ref_idx" ]; then
    refs_empty_reflog=$((refs_empty_reflog + 1))
    echo "NOTICE - $ref has no reflog entries at all (reflogs disabled/never enabled, or expired) -- 0 transitions can be examined for this ref. This replay approximation biases toward ALLOWING when history is invisible, so this ref contributes zero refusals by construction; a real rewind hidden behind this gap would be a false negative (acceptable), never a false positive."
    continue
  fi

  first=1
  prev_new=""
  ff_this_ref=0
  nonff_this_ref=0
  creation_this_ref=0

  while IFS=$'\t' read -r ts new; do
    [ -z "$ts" ] && continue
    if [ "$first" -eq 1 ]; then
      first=0
      creation_this_ref=$((creation_this_ref + 1))
      creation_boundaries=$((creation_boundaries + 1))
      prev_new="$new"
      continue
    fi
    old="$prev_new"
    T="$ts"

    if is_zero "$new"; then
      # H12's deletion form, mirrored: reachability of the pre-deletion tip
      # against OTHER refs only (no `new` in the exclusion set, since `new`
      # is literally zero here). Documented dead code on git 2.43.0's
      # "files" backend (see header bias #3) -- kept for symmetry with the
      # live hook and forward-compatibility, never expected to trigger.
      nonff_this_ref=$((nonff_this_ref + 1))
      nonff_examined=$((nonff_examined + 1))
      other_vals=()
      for ((j = 0; j < ${#ALL_REFS[@]}; j++)); do
        [ "$j" -eq "$ref_idx" ] && continue
        v="$(value_at "$j" "$T")"
        [ -n "$v" ] && other_vals+=("$v")
      done
      old_s="$(short "$old")"; ts_h="$(human_ts "$T")"
      desc="$ref  ${old_s}..(deleted)  @${T} ($ts_h)"
      # Same rev-list-failure-vs-empty-result distinction as
      # evaluate_transition above -- see that function's comment. This
      # whole branch is documented dead code on git 2.43.0's "files"
      # backend (bias #3 in this script's header), but the fix costs
      # nothing and keeps the two mirrored reachability computations from
      # silently drifting apart if this path ever becomes live on a
      # different backend.
      rev_list_ok=1
      if [ "${#other_vals[@]}" -gt 0 ]; then
        orphaned="$(git -C "$REPO" rev-list "$old" --not "${other_vals[@]}" 2>&1)" || rev_list_ok=0
      else
        orphaned="$(git -C "$REPO" rev-list "$old" 2>&1)" || rev_list_ok=0
      fi
      if [ "$rev_list_ok" -eq 0 ]; then
        uneval_count=$((uneval_count + 1))
        UNEVAL_SUMMARY+=("$desc")
        echo "NOTICE - $desc"
        echo "         reason: could not evaluate (git rev-list failed: $orphaned) -- NOT represented in the REFUSE/ALLOW counts above; treat this transition as unaudited, not as a passing ALLOW"
        prev_new="$new"
        continue
      fi
      if [ -n "$orphaned" ]; then
        refuse_count=$((refuse_count + 1))
        REFUSE_SUMMARY+=("$desc")
        echo "REFUSE - $desc"
        echo "         reason: deletion would orphan commit(s) reachable from no other ref's time-sliced position"
      else
        allow_count=$((allow_count + 1))
        ALLOW_SUMMARY+=("$desc")
        echo "ALLOW  - $desc"
        echo "         reason: pre-deletion tip remains reachable via another ref's time-sliced position"
      fi
      prev_new="$new"
      continue
    fi

    if [ "$old" = "$new" ]; then
      ff_this_ref=$((ff_this_ref + 1)); ff_skipped=$((ff_skipped + 1))
    elif git -C "$REPO" merge-base --is-ancestor "$old" "$new" 2>/dev/null; then
      ff_this_ref=$((ff_this_ref + 1)); ff_skipped=$((ff_skipped + 1))
    else
      nonff_this_ref=$((nonff_this_ref + 1))
      nonff_examined=$((nonff_examined + 1))
      evaluate_transition "$ref" "$ref_idx" "$old" "$new" "$T"
    fi
    prev_new="$new"
  done < "$TMP/rl_$ref_idx"

  n_entries=$((creation_this_ref + ff_this_ref + nonff_this_ref))
  echo "[ref $ref] $n_entries reflog entries: $creation_this_ref creation/history-start (skipped), $ff_this_ref fast-forward (skipped), $nonff_this_ref non-fast-forward examined"
done

echo
echo "=== SUMMARY ==="
echo "refs/heads/* examined: $refs_examined"
echo "refs with empty/no reflog (bias-allow no-op): $refs_empty_reflog"
echo "creation/history-start boundaries skipped (bias-allow, ambiguous root cause): $creation_boundaries"
echo "fast-forwards skipped (not printed individually): $ff_skipped"
echo "non-fast-forward transitions examined: $nonff_examined"
echo "  REFUSE: $refuse_count"
for s in "${REFUSE_SUMMARY[@]:-}"; do
  [ -n "$s" ] && echo "    - $s"
done
echo "  ALLOW: $allow_count"
for s in "${ALLOW_SUMMARY[@]:-}"; do
  [ -n "$s" ] && echo "    - $s"
done
if [ "$uneval_count" -gt 0 ]; then
  echo "  COULD NOT EVALUATE: $uneval_count (git rev-list itself failed -- NOT counted as ALLOW; read these before trusting the counts above)"
  for s in "${UNEVAL_SUMMARY[@]:-}"; do
    [ -n "$s" ] && echo "    - $s"
  done
fi
echo
echo "KNOWN BLIND SPOT: branch DELETIONS are not fully represented above."
echo "On git's \"files\" ref-storage backend (the default; verified 2026-07-11"
echo "on git 2.43.0), \`git branch -D\` deletes the ref's reflog file outright"
echo "instead of appending a final entry, so a historical branch deletion"
echo "this repo's history actually contains may leave NO reflog trace for"
echo "this replay to walk at all -- it would not appear as a REFUSE, an"
echo "ALLOW, or even a NOTICE line above; it is simply invisible to this"
echo "audit. This can only produce a false negative (a real past deletion"
echo "silently unaudited), never a false ALLOW on a transition this script"
echo "did examine. See this script's own header (bias #3) for the full"
echo "reasoning. Do not read a clean report above as proof no dangerous"
echo "branch deletion ever happened in this repo's history."
echo
echo "This script never enables the git hook and never judges whether the"
echo "refusals above are the expected known incidents -- that read is yours."
echo "Enablement, once you're satisfied, is a manual:"
echo "  rm $marker_dir/disable-git-hook"

if [ "$RECORD_PASS" -eq 1 ]; then
  mkdir -p "$marker_dir"
  {
    echo "recorded: $(date -u '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || date -u)"
    echo "repo: $REPO"
    echo "refuse_count: $refuse_count"
    echo "allow_count: $allow_count"
  } > "$marker_file"
  echo
  echo "--record-pass: wrote $marker_file"
  echo "(this only stops a future 'wb install-hooks' re-run from re-creating"
  echo "the disable-git-hook switch file -- it does NOT enable the hook)"
fi

exit 0
