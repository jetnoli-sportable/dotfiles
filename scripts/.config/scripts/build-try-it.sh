#!/usr/bin/env bash
# build-try-it.sh — regenerate docs/try-it.md from docs/roadmap.md.
#
# Walks roadmap.md's five status buckets (Up next / Live / Parked / Not
# doing / Shipped — the ones already marked with <a id="detail-...">
# anchors), follows each item's first linked doc(s), and greps that doc's
# own "## Try it" / "## Test it" section for the first fenced command plus
# the line right after it (an "expect"). Nothing here is hand-typed: a
# feature only gets a row if a real doc carries a real runnable example.
# Run before docgen.sh (wired into .githooks/pre-commit) so try-it.md is
# current before docgen renders it like any other page.
set -euo pipefail

ROOT="${DOTFILES:-$HOME/code/dotfiles}"
ROADMAP="$ROOT/docs/roadmap.md"
OUT="$ROOT/docs/try-it.md"

bucket_status() {
  case "$1" in
    Shipped) echo Built ;;
    "Up next") echo Discussed ;;
    Live) echo Doing ;;
    Parked|"Not doing") echo Deferred ;;
  esac
}

# $1 = doc path relative to docs/ (e.g. wb-guide.md). Prints "cmd<TAB>expect"
# on success, exits non-zero if the doc has no Try-it/Test-it section with a
# fenced command.
extract_try_it() {
  local f="$ROOT/docs/$1"
  [ -f "$f" ] || return 1
  awk '
    /^## (Try it|Try it now|Try it in the next five minutes|Test it|Test \/ verify it yourself)([[:space:]]|$)/ { insec=1; next }
    insec && /^## / { exit }
    {
      line=$0
      sub(/^[[:space:]]+/, "", line)
      sub(/[[:space:]]+$/, "", line)
    }
    insec && line ~ /^```/ { fence++; if (fence==2) afterfence=1; next }
    insec && fence==1 && cmd=="" && line!="" { cmd=line }
    insec && afterfence && expect=="" && line!="" {
      if (line ~ /^([0-9]+\.|-|\*)[[:space:]]/) { expect="\001none" } else { expect=line }
    }
    cmd!="" && expect!="" { print cmd "\t" expect; found=1; exit }
    END { exit(found?0:1) }
  ' "$f"
}

# Roadmap items, one per output line: bucket<TAB>raw-item-text (Up-next's
# wrapped continuation lines get joined into one).
items="$(awk '
  function flush() { if (cur!="") { print b "\t" cur; cur="" } }
  /^## Up next/  { flush(); b="Up next"; next }
  /^## Live/     { flush(); b="Live"; next }
  /^## Parked/   { flush(); b="Parked"; next }
  /^## Not doing/{ flush(); b="Not doing"; next }
  /^## Shipped/  { flush(); b="Shipped"; next }
  /^## Window management/ { flush(); b=""; next }
  b=="" { next }
  b=="Up next" {
    if ($0 ~ /^[0-9]+\.[[:space:]]*<a id="detail-/) { flush(); cur=$0 }
    else if (cur!="") cur = cur " " $0
    next
  }
  /<a id="detail-/ { flush(); cur=$0; next }
  END { flush() }
' "$ROADMAP")"

rows=""
count=0
while IFS=$'\t' read -r bucket text; do
  [ -z "$bucket" ] && continue
  status="$(bucket_status "$bucket")"
  [ -z "$status" ] && continue
  title="$(grep -oP '<a id="detail-[^"]*"></a>\s*\*\*[^*]+\*\*' <<<"$text" | head -1 | sed -E 's/.*\*\*(.*)\*\*/\1/')"
  [ -z "$title" ] && continue
  mapfile -t hrefs < <(grep -oP '(?<=\]\()[^)]*\.html[^)]*(?=\))' <<<"$text")
  for href in "${hrefs[@]}"; do
    src="${href%%#*}"
    src="${src%.html}.md"
    if out="$(extract_try_it "$src")"; then
      cmd="${out%%$'\t'*}"
      expect="${out#*$'\t'}"
      [ "$expect" = $'\001none' ] && expect="—"
      rows+="| ${title} | ${status} | \`${cmd}\` | ${expect} |"$'\n'
      count=$((count + 1))
      break
    fi
  done
done <<<"$items"

{
  cat <<EOF
---
title: Try it — a live catalog of what you can actually run
status: current
tile: One row per roadmap feature that has a real, runnable example — command and expected result lifted straight from that feature's own guide or recap. Auto-generated; never hand-edit — rerun build-try-it.sh + docgen.sh.
group: where-we-are
kind: page
updated: $(date +%F)
---

Generated from [the roadmap](roadmap.html): every item there that links to a
doc carrying its own \`## Try it\` / \`## Test it\` section contributes one
row here, with the command and the one-line "expect" lifted verbatim from
that doc — nothing below is hand-typed. Regenerate with
\`scripts/.config/scripts/build-try-it.sh\` (runs automatically before
\`docgen.sh\` via \`.githooks/pre-commit\`). A feature missing here just
means its linked doc doesn't carry a fenced Try-it command yet, not that it
isn't real — check the roadmap for its actual status.

| Feature | Status | Try it | Expect |
|---|---|---|---|
EOF
  printf '%s' "$rows"
} > "$OUT"

echo "build-try-it.sh: wrote $OUT ($count rows)"
