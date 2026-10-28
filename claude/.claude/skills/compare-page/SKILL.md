---
name: compare-page
description: Build a self-contained HTML page that compares 2-5 options for one
  decision, each with its own auto-drawn component diagram, numbered steps, pros
  and cons, plus a side-by-side table and a recommendation. Use when Jet asks to
  "compare these options", "show me a diagram of each option", "component diagram
  of your recommendation and an alternative", "pros and cons with diagrams", "a
  comparison page", or when one decision's options differ in structure (which
  components exist, where they run, how data flows) and prose can't show it. NOT
  for collecting answers to a batch of decisions (use `decision-page`; a compare
  page is often linked from one of its items), nor for comparing visual styles
  (use `visual-explore`).
---

# compare-page

One decision, 2-5 options, one page. The page opens with an at-a-glance strip of
the options, then the problem, what every option shares, one section per option
(summary, component diagram, numbered steps along its arrows, pros and cons, and
for alternatives "this wins if …"), a side-by-side table, and the recommendation.
The source is a JSON spec; one command draws the diagrams and writes the page.

It shows the comparison; it doesn't collect an answer. The choice is made in
chat, in a `decision-buffer` doc, or as an item on a `decision-page` that links
here.

## When to use

- **Options that differ in structure:** which components exist, where they run,
  who calls whom, where data lands. That's when a diagram per option carries
  weight.
- **Options that differ only in a value or a policy** (a threshold, a name, who
  approves) don't need a page: a `decision-buffer` choice doc or a decision-page
  item is enough.
- **More than 5 options:** cut to the real contenders first, and list the rest in
  `sources` or a sentence in `shared`, with why they're out.
- Build when Jet asks for a comparison or diagrams. When a decision you're
  presenting has structurally different options and Jet hasn't asked, offer the
  page in one line instead of building it.

## Where it lives

- **A durable path, never only the scratchpad or `/tmp`:** the task's dossier
  (`~/code/tasks/dossiers/<repo>--<slug>/<YYYY-MM-DD>-<name>.json`), or the repo's
  `docs/` when it's worth tracking there. Employer-repo (Sportable) content never
  goes in personal surfaces.
- **The spec is the source, and the HTML is generated beside it.** Never edit the
  HTML. Change the spec, regenerate, and republish to the same URL. If the dossier
  has a `tools/README.md`, add the command to it.

## Write the spec

Load `references/spec.md` before writing one; it's the field-by-field source of
truth, including how edges are routed. The rules that matter most:

- **Lead with why it matters.** `problem.why` says what goes wrong or what's at
  stake; `problem.hard` says what makes it hard. Define each term at first use;
  the page is read without the chat.
- **Put what every option shares in `shared`,** so each option's section shows
  only what differs.
- **Draw every option on the same zones with the same node names** where you
  can, so the diagrams compare at a glance. Mark the component each option adds
  or hinges on with `key`.
- **Number the arrows that carry the story,** and write one step per number. A
  step says what happens along that arrow, not what the box is.
- **Pros and cons must be real.** Never pad a list to match another option's
  length, and mark anything unchecked as unverified.
- **Exactly one recommended option.** Give each alternative a `wins_if`: the
  conditions under which it would be the better choice. It's what makes the
  recommendation checkable.
- **Comparison rows only where the options differ.**
- **When the recommendation reverses earlier advice,** say so in
  `recommendation.changed`, plainly, with the reason.
- Escape a literal `<` as `&lt;` in **HTML** fields. Diagram text is plain and is
  escaped for you.

## Generate and check

```bash
python3 ~/.claude/skills/compare-page/scripts/compare-page.py --spec <path.json>
```

- stdout: `wrote: <path>`, then `opened: <path>` or `not opened: <reason>`. It
  opens snap Chromium, else `xdg-open`, and refuses paths under `/tmp` or in a
  hidden directory.
- Exit 2 lists every problem, one `compare-page.py: ...` line each. Fix them all
  and rerun. Exit 1 means a missing template or page kit: run
  `stow --no-folding -t "$HOME" claude`.
- Warnings name node text likely to overflow its box: shorten it, or use fewer
  zones.
- **Look at the diagrams before handing the page over.** The routing is
  automatic, so check for an arrow crossing a box or a badge covering text. Take
  a headless screenshot from a non-hidden path under `$HOME`:
  `/snap/bin/chromium --headless --disable-gpu --window-size=1200,4000
  --screenshot=$HOME/<dir>/shot.png file://<page>`. Then read it. If something
  overlaps, move a node to another row.

## Publish (optional)

To share it or read it on another device, publish the same dossier file as a
private Artifact (the template already carries the title, the light and dark
tokens and the phone layout). Name the durable path alongside the URL.

## Tests

`scripts/compare-page.test.sh` covers validation, escaping, determinism, the
2- and 5-option bounds, and routing on awkward layouts (four zones, skips both
ways, a same-zone detour, unnumbered and dashed edges). Run it after changing the
generator.

## Learnings ledger

When Jet flags a compare page as unhelpful, confusing, or in need of a change,
add one dated line to `learnings.md` beside this file, in Jet's own words, with
the spec path.
