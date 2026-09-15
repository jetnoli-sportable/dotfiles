#!/usr/bin/env bash
# skill-usage.sh — reproducible per-skill usage counts over the local
# Claude Code transcript store (KTD6, U4 of
# docs/plans/2026-09-15-001-feat-weekly-review-loop-plan.md).
#
# Counts two textual patterns per transcript file:
#   - the slash-command tag:      <command-name>/<skill></command-name>
#   - the Skill-tool invocation:  "name":"Skill","input":{"skill":"<name>"
# A plugin- or path-prefixed name ("plugin:skill", "apps/web:deploy")
# normalizes to its bare trailing segment, so both invocation shapes and
# both prefix forms merge into one count per skill.
#
# BLIND SPOT — stated here AND in every run's own output, not just this
# comment: a skill invoked by natural-language description alone (no
# `/name`, no Skill-tool call) surfaces neither pattern. A zero count means
# NOT DETECTED, never "unused" — this method cannot tell the difference
# (the same mistake the 2026-09-14 skill inventory flagged against /park
# itself, run ad hoc and not reproducible — the reason this script exists).
#
# Never JSON-parses a transcript line — matches are plain `grep -oE` over
# the raw file, so a malformed or truncated JSONL line simply fails to
# match instead of aborting the scan.
#
# Usage:
#   skill-usage.sh [--dir <transcripts-dir>] [--skills-dir <skills-root>] [--since <YYYY-MM-DD>]
#
#   --dir <path>          transcript store root (default: ~/.claude/projects),
#                          scanned recursively for *.jsonl files.
#   --skills-dir <path>   a directory of <skill-name>/SKILL.md entries (e.g.
#                          claude/.claude/skills) — when given, EVERY skill
#                          found there is reported, including a zero count
#                          for one this run never detected. Omitted: only
#                          skills this run actually detected are listed.
#   --since <YYYY-MM-DD>  only scan transcript files modified on/after this
#                          date (whole-file granularity, via mtime — not
#                          per-line: a long-lived transcript that was ever
#                          touched on/after this date is scanned in full).
set -uo pipefail

TRANSCRIPTS_DIR="$HOME/.claude/projects"
SKILLS_DIR=""
SINCE=""

while [ $# -gt 0 ]; do
  case "$1" in
    --dir)
      [ $# -ge 2 ] || { echo "skill-usage.sh: --dir requires a value" >&2; exit 1; }
      TRANSCRIPTS_DIR="$2"; shift 2 ;;
    --skills-dir)
      [ $# -ge 2 ] || { echo "skill-usage.sh: --skills-dir requires a value" >&2; exit 1; }
      SKILLS_DIR="$2"; shift 2 ;;
    --since)
      [ $# -ge 2 ] || { echo "skill-usage.sh: --since requires a value" >&2; exit 1; }
      SINCE="$2"; shift 2 ;;
    -h|--help)
      sed -n '/^# Usage:/,/^set -uo/p' "$0" | sed '$d; s/^# \{0,1\}//'
      exit 0 ;;
    *)
      echo "skill-usage.sh: unknown argument '$1'" >&2
      exit 1 ;;
  esac
done

# _skill_usage_normalize <raw-name> — strip a plugin- or path-prefixed
# "prefix:skill" down to the bare trailing segment.
_skill_usage_normalize() {
  printf '%s' "${1##*:}"
}

declare -A COUNT=()
declare -A FIRST_SEEN=()
declare -A LAST_SEEN=()

_skill_usage_record() { # <name> <file-date>
  local name="$1" fdate="$2"
  COUNT["$name"]=$(( ${COUNT["$name"]:-0} + 1 ))
  if [ -z "${FIRST_SEEN["$name"]:-}" ] || [[ "$fdate" < "${FIRST_SEEN["$name"]}" ]]; then
    FIRST_SEEN["$name"]="$fdate"
  fi
  if [ -z "${LAST_SEEN["$name"]:-}" ] || [[ "$fdate" > "${LAST_SEEN["$name"]}" ]]; then
    LAST_SEEN["$name"]="$fdate"
  fi
}

if [ -d "$TRANSCRIPTS_DIR" ]; then
  mapfile -d '' -t _SKILL_USAGE_FILES < <(
    if [ -n "$SINCE" ]; then
      find "$TRANSCRIPTS_DIR" -type f -name '*.jsonl' -newermt "$SINCE" -print0 2>/dev/null
    else
      find "$TRANSCRIPTS_DIR" -type f -name '*.jsonl' -print0 2>/dev/null
    fi
  )

  for f in "${_SKILL_USAGE_FILES[@]}"; do
    [ -f "$f" ] || continue
    fdate="$(date -r "$f" +%F 2>/dev/null)" || continue

    while IFS= read -r raw; do
      [ -n "$raw" ] || continue
      _skill_usage_record "$(_skill_usage_normalize "$raw")" "$fdate"
    done < <(grep -oE '<command-name>/[A-Za-z0-9_./:-]+</command-name>' "$f" 2>/dev/null \
               | sed -E 's#^<command-name>/##; s#</command-name>$##')

    while IFS= read -r raw; do
      [ -n "$raw" ] || continue
      _skill_usage_record "$(_skill_usage_normalize "$raw")" "$fdate"
    done < <(grep -oE '"name":"Skill","input":\{"skill":"[A-Za-z0-9_./:-]+"' "$f" 2>/dev/null \
               | sed -E 's#.*"skill":"##; s#"$##')
  done
fi

# Known-skill roster: when --skills-dir is given, every skill found there
# gets a row (zero count included) — the whole point of the not-detected
# caveat is to make an absence visible, not just count what happened to hit.
declare -a KNOWN=()
if [ -n "$SKILLS_DIR" ] && [ -d "$SKILLS_DIR" ]; then
  while IFS= read -r -d '' smd; do
    KNOWN+=("$(basename "$(dirname "$smd")")")
  done < <(find "$SKILLS_DIR" -mindepth 2 -maxdepth 2 -name 'SKILL.md' -print0 2>/dev/null | sort -z)
fi

declare -a ALL_NAMES=()
declare -A SEEN_NAME=()
for n in "${KNOWN[@]}" "${!COUNT[@]}"; do
  [ -n "${SEEN_NAME["$n"]:-}" ] && continue
  SEEN_NAME["$n"]=1
  ALL_NAMES+=("$n")
done
IFS=$'\n' ALL_NAMES=($(printf '%s\n' "${ALL_NAMES[@]}" | sort)); unset IFS

echo "# skill-usage: counts two textual patterns (the /<skill> slash-command"
echo "# tag and the Skill-tool invocation block) over $TRANSCRIPTS_DIR${SINCE:+ (since $SINCE)}."
echo "# CAVEAT: a skill invoked only by natural-language description (no"
echo "# /name, no Skill-tool call) is invisible to this method — a zero"
echo "# count below means NOT DETECTED, never \"unused\"."
printf '#\n# %s\t%s\t%s\t%s\t%s\n' skill count first-seen last-seen status

for n in "${ALL_NAMES[@]}"; do
  c="${COUNT["$n"]:-0}"
  if [ "$c" -gt 0 ]; then
    printf '%s\t%s\t%s\t%s\t%s\n' "$n" "$c" "${FIRST_SEEN["$n"]}" "${LAST_SEEN["$n"]}" "detected"
  else
    printf '%s\t%s\t%s\t%s\t%s\n' "$n" 0 "-" "-" "not-detected (no /name or Skill-tool hit — not evidence of non-use)"
  fi
done

exit 0
