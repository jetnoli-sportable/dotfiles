---
title: docgen — how the docs get generated
status: current
tile: The generator's own pipeline, source locations, and a real worked example.
group: workflow
kind: page
updated: 2026-07-07
---

Every page you're reading in this dashboard — including this one — is
rendered by a small Go tool called `docgen`, not written as HTML by hand.
This page explains the pipeline itself: where it reads from, what it
writes, and a real before/after of it doing that.

## The pipeline

`docgen.sh` (stowed to `~/.config/scripts/docgen.sh`) wraps the tool: it
rebuilds the `docgen` binary from `~/code/docgen`'s Go source if that
source changed, then runs it with `-root ~/code/dotfiles`. Three
subcommands, `docgen.sh [build|index|all]` (`all` is the default):

1. **Load policy** — read `docs/docgen.json`: which directories hold page
   sources, the HUB's groups/sidecar tiles, the INDEX's scan sources, the
   redaction denylist.
2. **Scan pages** — read every `*.md` in the declared page directories,
   parse its frontmatter (fails loudly on anything malformed — missing
   title, unknown `kind`/`status`, an unterminated block), render its body
   through goldmark, and walk the result for `h2`/`h3` headings.
3. **Render** (`build`) — run each page through `docs/_templates/*.html`
   (a shared `html/template` layout with `page`/`guide`/`hub` blocks) and
   write the `.html` sibling. Separately, aggregate every page's
   frontmatter — plus the config's sidecar entries — into `HUB.html`'s tile
   grid.
4. **Scan everything else** (`index`) — walk the config's declared INDEX
   sources (tmux binds, zsh aliases/functions, skill descriptions, scripts,
   decision records, `MEMORY.md`, TUI READMEs, the task store) into one
   `Entry` per finding, alongside a `doc` entry for every page from step 2,
   and write `INDEX.md`: a fenced JSONL block, then a human table.
5. **Write, or don't** — every output goes through `writeIfChanged`: if the
   new content byte-matches what's already on disk, the file isn't
   touched. That's what makes a second `docgen.sh` run with no source
   changes a true no-op — nothing to diff, nothing to review.

A `.githooks/pre-commit` hook runs this automatically now whenever a commit
touches a tracked source (see [the slice 5 recap](slice-5-recap.html) for
what triggers it) — but the pipeline above is the same either way, by hand
or by hook.

## Where the source files live

| What | Lives at | Feeds |
|---|---|---|
| Page sources | `docs/*.md`, `docs/guides/*.md` | Their own rendered `.html`, a HUB tile, and an INDEX `doc` entry |
| Policy | `docs/docgen.json` | Which dirs get scanned, HUB layout, INDEX sources, the redaction denylist |
| Templates | `docs/_templates/*.html` | The shared Catppuccin design system + the `page`/`guide`/`hub` layouts every generated page uses |
| The tool | `~/code/docgen` — a separate git repo (stdlib + goldmark only) | The `docgen` binary `docgen.sh` builds and runs |
| Non-rendered INDEX inputs | `tmux/.config/tmux/tmux.conf`, `zsh/.zshrc`, `claude/.claude/skills/*/SKILL.md`, `scripts/.config/scripts/**/*.sh`, `logs/decisions/*.md`, `~/code/tasks`, `~/code/notes-tui` and `~/code/replay-tui`'s READMEs | Only `INDEX.md` entries — these are scanned for provenance, never rendered into a page |

The split matters: editing a page source or the templates and running
`docgen.sh build` regenerates pages and the HUB; editing anything in the
right-hand column of that last row only shows up after `docgen.sh index`
(or `all`, which does both).

## A worked example

Take the real source at `docs/guides/park.md` — its frontmatter and opening
line:

```markdown
---
title: park
status: current
tile: <10s capture of a "deal with this later" item.
group: skills
kind: guide
updated: 2026-07-07
---

## Overview

Zero-ceremony deferral: one JSON line appended to a global ledger
```

Running `docgen.sh build` reads that file, and the corresponding lines in
the actual generated `docs/guides/park.html` come out as:

```html
<title>park</title>
...
<div class="brand">park</div>
...
<li><a href="#overview">Overview</a></li>
...
<h1>park</h1>
<div class="meta">
  <span class="chip ok">current</span>
</div>
...
<h2 id="overview">Overview</h2>
<p>Zero-ceremony deferral: one JSON line appended to a global ledger
(<code>~/.claude/parked-items/ledger.jsonl</code>), ...
```

The `title:`/`status:` frontmatter became the `<title>`, the sidebar
brand, and the `ok`-colored chip (goldmark's `WithAutoHeadingID` gave
`## Overview` its `#overview` anchor for free); the `kind: guide` value
picked the sticky-TOC shell template over the wide `page` one. The same
`docgen.sh index` run also produced a `skill-park` entry in `INDEX.md`
(skills get scanned from their `SKILL.md`, separately from pages) and a
tile under "Claude skills" on the HUB — both sourced from the same
frontmatter, no extra step required.

Everything else in this docs project — the page you started on, the HUB
dashboard, every guide — is the exact same four steps, just run over more
files.
