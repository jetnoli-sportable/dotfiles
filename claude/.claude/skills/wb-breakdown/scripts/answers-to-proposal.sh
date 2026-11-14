#!/usr/bin/env bash
# answers-to-proposal.sh — turn a /decide page's answers into the exact
# proposal `wb breakdown --apply` reads (SKILL.md step 5 grammar).
#
# Usage: answers-to-proposal.sh <spec.json> <answers.json> <parent-task-file> [out.md]
#
#   spec.json     the published verdicts-layout spec. Beside the page's own keys
#                 it carries a top-level `breakdown` object the page ignores
#                 (see SKILL.md, "Large proposals").
#   answers.json  {"answers": {"<item id>": <answers doc>, ...},
#                  "submitted": <meta/submitted doc>}  (assembled by the skill
#                 from ArtifactData; docs as in decide/references/page-spec.md)
#   parent file   the parent task file; its sha256 must equal spec.base.
#   out.md        default logs/breakdowns/<breakdown.parent>.md
#
# Exit 0: proposal written. Exit 1: refused (stale base, a row asking for
# more information, an unusable row); nothing is written.
set -euo pipefail

die() { echo "answers-to-proposal: $*" >&2; exit 1; }

[ $# -ge 3 ] || die "usage: answers-to-proposal.sh <spec.json> <answers.json> <parent-task-file> [out.md]"
spec=$1 answers=$2 parent_file=$3
for f in "$spec" "$answers" "$parent_file"; do [ -f "$f" ] || die "no such file: $f"; done

stem=$(jq -r '.breakdown.parent // empty' "$spec")
[ -n "$stem" ] || die "spec has no breakdown.parent"
out=${4:-logs/breakdowns/$stem.md}

# Staleness: spec.base is the parent file's sha256 at publish time.
base=$(jq -r '.base // empty' "$spec")
[ -n "$base" ] || die "spec has no base (the parent file's sha256 at publish)"
now=$(sha256sum "$parent_file" | cut -d' ' -f1)
[ "$base" = "$now" ] || die "parent task $stem changed since the page was published (base ${base:0:12}, now ${now:0:12}); nothing converted, publish a fresh round"

result=$(jq -n --slurpfile spec "$spec" --slurpfile ans "$answers" '
  def trim: sub("^\\s+"; "") | sub("\\s+$"; "");
  $spec[0] as $s | $ans[0] as $a
  | ($s.verdicts | map(.id)) as $vids
  | ($s.breakdown.plans // {}) as $plans
  | ($a.submitted.accept_remaining == true) as $accept
  # one resolved row per item, by the page-spec counting rules
  | [ $s.items[] | . as $it
      | ($a.answers[$it.id] // {}) as $d
      | ($d.choice // "") as $c
      | (if ($vids | index($c)) then "chosen"
         elif $d.fields_changed == true then "edited"
         elif $accept and $it.suggested then "suggestion"
         elif $it.suggested then "carried"
         else "unanswered" end) as $status
      | { id: $it.id, title: $it.title, status: $status,
          verdict: (if $status == "chosen" then $c
                    elif $status == "edited" or $status == "suggestion" then ($it.suggested // null)
                    else null end),
          note: (($d.note // "") | trim),
          plan: ($plans[$it.id] // ""),
          fields: (reduce ($it.fields // [])[] as $f ({}; .[$f.key] = (($d.fields // {})[$f.key] // $f.value))) } ] as $rows
  | ($rows | map(select(.verdict == null and .note != "")) | first) as $ask
  | if $ask then {error: "row \($ask.id) (\($ask.title)) asks for more information (note: \($ask.note)); nothing converted, answer it and publish a fresh round"}
    else
      ($rows | map(select(.verdict == "create"))) as $creates
      | ($creates | map(.fields.slug // "" | trim)) as $slugs
      | ([ $creates[] | select((.fields.slug // "" | trim) == "" or (.fields.slug | test("[\\s`]"))) ] | first) as $badslug
      | ([ $creates[] | select((.fields.goal // "") | test("\t")) ] | first) as $badgoal
      | ([ $creates[] | select(((.fields.size // "") | trim) as $z | ($z != "" and (["XS","S","M","L","XL"] | index($z) | not))) ] | first) as $badsize
      | if $badslug then {error: "row \($badslug.id) (\($badslug.title)): slug must be non-empty with no whitespace or backtick"}
        elif $badgoal then {error: "row \($badgoal.id) (\($badgoal.title)): goal contains a tab"}
        elif $badsize then {error: "row \($badsize.id) (\($badsize.title)): size must be XS, S, M, L, XL or blank"}
        else
          # a merge row folds its plan body into the child named by the first
          # backticked slug in its note
          ($creates | map({key: .id, value: (.fields.slug | trim)}) | from_entries) as $slugOf
          | [ $rows[] | select(.verdict == "merge")
              | . as $m
              | ([ $m.note | match("`([^`]+)`"; "g").captures[0].string ] | map(select(. as $t | $slugs | index($t))) | first) as $tgt
              | {id: $m.id, title: $m.title, plan: $m.plan, target: $tgt} ] as $merges
          | ($merges | map(select(.target == null)) | first) as $badmerge
          | if $badmerge then {error: "row \($badmerge.id) (\($badmerge.title)) is a merge but its note names no created child in backticks; nothing converted"}
            else
              ($creates | map(. as $c | $c + {slug: ($c.fields.slug | trim),
                  plan: ([$c.plan] + [ $merges[] | select(.target == ($c.fields.slug | trim)) | "Merged from \(.title):\n\n\(.plan)" ] | map(select(. != "")) | join("\n\n"))})) as $kids
              | ($s.breakdown.continuing // null) as $cont
              | (if $cont == null then null
                 else ($slugOf[$cont] // ([$merges[] | select(.id == $cont) | .target] | first)) end) as $contSlug
              | if $cont != null and $contSlug == null then {error: "continuing child (row \($cont)) is not created or merged; nothing converted"}
                else
                  def esc: gsub("\""; "\\\"");
                  def deps: split(",") | map(trim | select(. != "") | "`\(.)`") | join(", ");
                  ($s.breakdown.parent) as $stem | ($s.breakdown.repo) as $repo
                  | ($s.breakdown.rewrite_plan // null) as $rw
                  | ([ ($s.breakdown.moves // [])[] | . as $mv | ($slugOf[$mv.item] // null) as $t
                       | select($t != null) | "- [x] move follow-up: \"\($mv.text | esc)\" → child: `\($t)`" ]) as $moves
                  | ([ ($s.breakdown.moves // [])[] | select($slugOf[.item] == null) | .text ]) as $stayed
                  | { md: (([
                      "# wb breakdown — \($s.breakdown.branch // $stem) (\($stem))",
                      "",
                      "> Approved on the /decide page, converted by answers-to-proposal.sh. `wb breakdown --apply` executes exactly what is checked.",
                      "",
                      "<!-- wb-breakdown: block=approve parent=\($stem) -->",
                      "- [x] **Approve — apply everything ticked below**",
                      ""
                    ]
                    + ([ $kids | to_entries[] | .key as $i | .value as $k
                         | "## child \($i + 1) — \($k.title)\(if $k.slug == $contSlug then " (continuing)" else "" end)",
                           "<!-- wb-breakdown: block=child n=\($i + 1) parent=\($stem) repo=\($repo) -->",
                           "- [x] create child: `\($k.slug)`",
                           "- goal: \($k.fields.goal // "" | trim)",
                           ("- size: \($k.fields.size // "" | trim)" | sub("\\s+$"; "")),
                           ("- depends_on: \($k.fields.depends_on // "" | deps)" | sub("\\s+$"; "")),
                           "<!-- wb-breakdown: begin-plan n=\($i + 1) -->",
                           $k.plan,
                           "<!-- wb-breakdown: end-plan -->",
                           "" ] | flatten)
                    + [ "## parent edits", "<!-- wb-breakdown: block=parent parent=\($stem) -->" ]
                    + (if $contSlug != null then ["- [x] migrate branch/worktree + re-aim @task → continuing child: `\($contSlug)`"] else [] end)
                    + (if $rw != null then ["- [x] rewrite parent ## Plan as below", "<!-- wb-breakdown: begin-plan parent -->", $rw, "<!-- wb-breakdown: end-plan -->"] else [] end)
                    + $moves
                    | join("\n")) + "\n"),
                    report: ([ "created \($kids | length): " + ($kids | map(.slug) | join(", ")) ]
                      + ([ $rows[] | select(.status == "carried") | .id ] as $ca | if ($ca | length) > 0 then ["carried over (suggestion not accepted): " + ($ca | join(", "))] else [] end)
                      + ([ $rows[] | select(.verdict == "skip") | .id ] as $sk | if ($sk | length) > 0 then ["skipped: " + ($sk | join(", "))] else [] end)
                      + ([ $merges[] | "merged \(.id) into \(.target)" ])
                      + ([ $stayed[] | "follow-up stays on the parent (its child is not created): \(.)" ])) }
                end
            end
        end
    end')

if [ "$(jq -r '.error // empty' <<<"$result")" ]; then
  die "$(jq -r '.error' <<<"$result")"
fi
mkdir -p "$(dirname "$out")"
jq -j '.md' <<<"$result" > "$out"
jq -r '.report[]' <<<"$result"
echo "proposal written: $out"
