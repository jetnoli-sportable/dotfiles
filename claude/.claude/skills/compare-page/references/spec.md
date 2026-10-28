# compare-page: spec format and diagram layout

The source of truth that `SKILL.md` summarises. The generator
(`scripts/compare-page.py`) validates the spec, then fills `templates/page.html`.
`fixtures/example-spec.json` is a full working example: three options, each with a
three-zone diagram, a comparison table and a recommendation that reverses an
earlier one.

## Command

```bash
python3 ~/.claude/skills/compare-page/scripts/compare-page.py \
  --spec <path.json> [--out <page.html>] [--no-open]
```

| Exit | Meaning |
|---|---|
| 0 | page written |
| 1 | template or the shared page kit (`decision-page/kit/pagekit.py`) missing; run `stow --no-folding -t "$HOME" claude` |
| 2 | bad input: unreadable file, invalid JSON, or invalid spec; nothing written |

On exit 2 every problem is listed on stderr, one `compare-page.py: ...` line each,
naming the option and diagram part. Warnings (`compare-page.py: warning: ...`) don't
stop the page: they flag node text likely to overflow its box.

stdout on success: `wrote: <abs path>`, then `opened: <path>` or `not opened:
<reason>` (`--no-open`, or a path under `/tmp` or a hidden directory, which snap
Chromium can't read).

## Text fields

Fields marked **HTML** are inserted as HTML: plain prose with inline tags only
(`<code>`, `<b>`, `<em>`, `<br>`, `<a>`). Write a literal `<` as `&lt;`. Fields
marked **plain** are escaped, so tags show literally. All diagram text is plain.

## Top level

| Field | Required | Notes |
|---|---|---|
| `slug` | yes | `[a-z0-9][a-z0-9-]*` |
| `title` | no | **plain**; the page title and `<h1>`; falls back to `slug` |
| `eyebrow` | no | **plain**; the small line above the title (ticket, context, date) |
| `lede` | no | **HTML**; one or two sentences: what's being decided and how many options |
| `sources` | no | **HTML**; where the facts come from, and what's unverified |
| `problem` | no | `{why, hard}`, both **HTML**: why the decision matters, then what makes it hard |
| `shared` | no | list of **HTML** bullets: facts true of every option, so the options only show what differs |
| `options` | yes | 2-5 options, below |
| `compare` | no | rows of the side-by-side table, below |
| `recommendation` | yes | `{summary, changed?}`, both **HTML**. `changed` says plainly when this reverses earlier advice and why |

## Options

| Field | Required | Notes |
|---|---|---|
| `id` | yes | unique; also the table's cell key and the section anchor (`#opt-<id>`) |
| `rec` | one option | `true` on exactly one |
| `name` | yes | **HTML**; the section heading |
| `short` | no | **plain**; label in the at-a-glance cards, the table header and the contents; falls back to `name` without tags |
| `tagline` | no | **plain**; one line under the name in the at-a-glance cards |
| `summary` | yes | **HTML**; what the option is, in a sentence or two |
| `diagram` | yes | below |
| `steps` | when edges are numbered | list of **HTML**, one per numbered edge, in number order: what happens along that arrow |
| `pros`, `cons` | yes | non-empty lists of **HTML**. Real ones only; never pad a list to match another |
| `wins_if` | no | **HTML**; alternatives only (refused on the recommended option). The conditions under which this option would be the better choice, rendered as "This wins if …" |

Options are lettered A-E in the order given. Put the recommended option first
unless the order carries meaning.

## Diagram

```json
{
  "alt": "optional accessible description; defaults to '<name>: component diagram'",
  "zones": [{"id": "laptop", "label": "Your laptop"}, {"id": "vpc", "label": "Inside the VPC", "tone": "accent"}],
  "nodes": [{"id": "job", "zone": "vpc", "row": 0, "title": "capture-live Job", "lines": ["DB user: app_ro"], "key": true}],
  "edges": [{"from": "cmd", "to": "job", "n": 1, "both": false, "dashed": false}]
}
```

| Part | Field | Notes |
|---|---|---|
| zone | `id`, `label` | 1-4 zones, drawn as columns left to right in list order; `label` is shown upper-case at the zone's foot |
| zone | `tone` | `"accent"` shades the zone (a trust boundary, a network, "the new thing"); otherwise omit |
| node | `id`, `zone`, `row` | `row` is an integer; rows are shared across zones, so row 1 is one band across the whole diagram. Two nodes can't share a zone and row. Unused row numbers are closed up |
| node | `title`, `lines` | **plain**; a bold title and up to a few mono sub-lines |
| node | `key` | `true` draws an accent border: the component the option adds or hinges on |
| edge | `from`, `to` | node ids; the arrow points at `to` |
| edge | `n` | optional step number, shown as a badge; numbers must run 1..k with no gaps, and `steps` must have k entries |
| edge | `both` | arrowheads at both ends (a request and its response) |
| edge | `dashed` | a dashed line (optional, later, or background flow) |

### How edges are routed

No coordinates go in the spec. The generator routes every edge at right angles:

- **Same zone, nothing between:** a straight vertical line.
- **Same zone, a node between:** out of the right side, down a lane beside the boxes, back into the right side.
- **Neighbouring zones:** side to side; straight when the heights line up, otherwise through the gutter between the zones. When one end is the only edge on its side of the box, the line is straightened to the other end's height.
- **Zones further apart:** out the side into the gutter, along the gap above the target's row (or a channel above row 0), and down into the target's top.

Edges sharing a side of a box are spread along it, ordered by where they go.
Several edges in one gutter or gap get their own lanes.

### Layout tips

- Arrange zones so most arrows go left to right, with the person or trigger on the left.
- Use the same zones and node names across options, so the diagrams compare at a glance; vary only what differs.
- Text room per box (the generator warns past it): about 40 title / 45 line characters with 2 zones, 23 / 26 with 3, 15 / 17 with 4.
- If two lines overlap or a badge lands on a box, move a node to another row. Rows are cheap.

## Comparison table

```json
"compare": [
  {"label": "Who can reach it", "cells": {"job": "people allowed to run the Job", "endpoint": "anyone in the IAP group"}}
]
```

`label` and each cell are **HTML**. Every row needs a cell for every option and no
others. The recommended option's column is shaded. Pick rows where the options
actually differ; a row where every cell says the same belongs in `shared`.
