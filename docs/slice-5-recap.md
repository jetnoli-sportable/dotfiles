---
title: Slice 5 recap — the docs platform
status: current
tile: What shipped, what to verify yourself, and what's next. Start here after the PR.
group: personal-workflow
kind: page
updated: 2026-07-07
---

One generator, three outputs. Every hand-maintained doc surface in this
project — the two you're used to editing by hand, and the dashboard you
clicked through — is now rendered from markdown sources by a tool that
didn't exist a session ago. This page is itself one of those sources: edit
`docs/slice-5-recap.md`, not this rendered file.

**PR:** [#9](https://github.com/jetnoli-sportable/dotfiles/pull/9) ·
**Plan:** `docs/plans/2026-07-07-002-slice-5-docs-platform-plan.md` (now
`status: completed`) · **Branch:** `docs/dotfiles-overview` → `development`

## What we added

### The generator — `~/code/docgen`

A new, separate Go repo (stdlib + goldmark, no other dependencies). It reads
markdown-with-frontmatter and a small `docs/docgen.json` policy file from
*this* repo, and writes three things: rendered HTML pages, the `HUB.html`
tile dashboard, and `INDEX.md`. The templates and the policy live here in
dotfiles — the tool itself is generic enough to point at another repo later.

> **This repo is local-only — it has no git remote yet.** If the machine
> is lost before one gets pushed, the generator's source goes with it. Say
> the word and I'll create one.

### The three generated outputs

| Output | Replaces | Notes |
|---|---|---|
| `docs/roadmap.html`, `docs/wb-guide.html`, `docs/setup.html`, five pages under `docs/guides/` | Hand-edited HTML that drifted from its `.md`/source of truth | Never edit the `.html` — edit the `.md` and rerun `docgen.sh` |
| `docs/HUB.html` | The old hand-maintained dashboard | Tiles come from every page's frontmatter, plus a small sidecar for the findings audit and this recap |
| `docs/INDEX.md` | Nothing — this is new | 78 entries: every tmux bind, zsh alias/function, skill, script, doc, decision record, and the notes-tui pointer, each with a `file:line` |

### Two new ways to ask "what do I have"

- **`prefix+?`** in tmux opens an fzf picker over the INDEX. Enter jumps you
  to the thing (its rendered page, or its source at the right line);
  preview tells you about it first.
- **`/help <question>`** in any Claude Code session reads the same INDEX,
  follows the links (including decision records for "why" questions), and
  answers in chat with citations.

### Housekeeping that came with it

- The four hand-authored Claude skills (`decision-buffer`, `park`,
  `parked-items`, `pr-review-session`) are now tracked in a `claude/` stow
  package instead of living only on this machine.
- `overview.md` / `overview.html` and `HUB.md` are **deleted** — their
  content moved to the INDEX, the per-skill guide pages, and this repo's
  generated `setup.html`.
- A work-repo denylist keeps employer-repo names out of anything the
  scanner pulls from `MEMORY.md` or the task store, withheld with a log
  line rather than silently.

## Test / verify it yourself

- [ ] **Reload tmux**, then press <kbd>prefix</kbd>+<kbd>?</kbd>. Type a few
      letters of something you know exists (`wb`, `park`, `notes`) and
      confirm the preview pane shows something sensible; press Enter on a
      couple of different kinds (a bind, a skill, a doc) and check it takes
      you to the right place.
- [ ] **Ask `/help`** a real question — "why does prefix+m open wb", "what
      does the park skill do", "how do I use notes-tui" — and check the
      citations actually point at real files.
- [ ] **Open the HUB** (`prefix+h`, or `xdg-open ~/code/dotfiles/docs/HUB.html`)
      and click through a few tiles, including the four skill tiles under
      "Claude skills" — they should land on real guide pages now, not an
      anchor into a deleted file.
- [ ] **Skim the guide pages** at `docs/guides/*.html` for your own skills —
      flag anything that reads wrong; they were written from the SKILL.mds
      plus the old overview content, so drift is possible.
- [ ] **Regenerate and confirm it's a no-op**: run `docgen.sh` from the repo
      root twice in a row and check `git status` shows nothing changed.
- [x] **~~No freshness hook~~ — fixed.** A `.githooks/pre-commit` hook now
      runs `docgen.sh all` automatically whenever a commit touches a
      tracked docgen input (docs sources, `docgen.json`, templates,
      `tmux.conf`, `.zshrc`, skill files, or tmux/scripts scripts) and
      stages the regenerated output into the same commit. Installed via
      `git config core.hooksPath .githooks` (`install.sh` does this on a
      fresh clone). Non-blocking if `~/code/docgen` isn't cloned yet, and
      only reacts to what's *tracked in this repo* — `logs/decisions/`
      (gitignored) and the `~/code/tasks` store still need a manual
      `docgen.sh index` after editing.
- [ ] **Skim the PR** ([#9](https://github.com/jetnoli-sportable/dotfiles/pull/9))
      for anything that looks off before merging to `development`.

## Next steps

- **Decide on a remote for `~/code/docgen`.** Local-only right now; a
  five-minute `gh repo create` whenever it matters to you.
- **Three review findings are still parked** — `/parked-items` will surface
  them: two hardcoded-in-Go policy decisions that should move to
  `docgen.json` when they come up again, and a stale-worktree edge case in
  `pr-review-session`'s driver. (A fourth — no freshness hook — is done:
  see below.)
- **Merge PR #9** once you've walked the checklist above.
- Longer-term, unstarted: notes-tui slice 4b (the `--context` digest flag
  and `wb` integration), and roadmap 9e — task recall reusing this same
  INDEX-read machinery to resume work by name from any session.
