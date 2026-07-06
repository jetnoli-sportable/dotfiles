# Hub — the personal workflow

The index. When in doubt about which doc has what, start here. Manually
maintained — update on request, not automatically. Dashboard version with
the same content: [`HUB.html`](HUB.html) (open that one first if you're
browsing rather than grepping).

**Open it:** `prefix`+`h` from anywhere in tmux, or
`xdg-open ~/code/dotfiles/docs/HUB.html` directly — that's the command to use
if you want relative paths (like the notes-tui link below) to actually
resolve, since they won't inside a sandboxed Artifact preview.

## Personal workflow — `~/code/dotfiles`

| Doc | What it's for | Status |
|---|---|---|
| [`roadmap.md`](roadmap.md) / [`.html`](roadmap.html) | The plan: readback, decisions, build order, later additions. | Slices 1–3 done, 4–5 not started |
| [`overview.md`](overview.md) / [`.html`](overview.html) | Everything in the personal workflow — what it is, why it exists, how to use it. | WIP, manually maintained |
| [`agent-workbench-findings.html`](agent-workbench-findings.html) | Deep-dive audit of the tmux/Claude agent tooling: inventory, the `@claude_blocked` signal contract, gaps, target flows, decisions. | Updated as of PR #7 |
| [`wb-guide.html`](wb-guide.html) | How to use `wb`: session-per-worktree, the unified picker, wind-down. | Current |

## Claude skills — `~/.claude/skills/` (not version-controlled)

No dedicated page per skill yet — each links into `overview.html`'s skills
section: [decision-buffer](overview.html#decision-buffer),
[park](overview.html#park), [parked-items](overview.html#parked-items),
[pr-review-session](overview.html#pr-review-session). Standalone guide pages
per skill (and per TUI), with a tile-grid dashboard as their entry point, is
on the roadmap.

## TUIs — separate repos under `~/code/`

| Doc | What it's for |
|---|---|
| [`~/code/notes-tui/notes-guide.html`](../../notes-tui/notes-guide.html) | notes-tui's own committed usage guide (install/commands/global-flags/conventions/roadmap). Not linked from its own README — was genuinely easy to miss. |

## Other artifacts, other repos (found, not part of this project)

Two HTML docs turned up scanning `/tmp/claude-1000/*` on this machine — a
be--monorepo sprint doc and a lib--algorithms metrics plan. Not linked here:
they're work-project artifacts, unrelated to the personal workflow, and live
only in session scratch dirs that could be cleaned at any time. That
fragility — and the fact this sweep can only see what's on *this* machine
right now — is exactly the cross-repo/cross-session doc problem on the
roadmap (see below).

## Related, not in `docs/`

| Location | What it's for |
|---|---|
| `~/code/tasks/dotfiles--*.md` | The actual per-task build logs and backlogs — most detailed, most current record of any in-flight work. Central task store, its own git repo. |
| `logs/decisions/*.md` | Scratch decision records from decision-buffer sessions (gitignored — not tracked, cited by name from the docs above). |
| `readme.md` (repo root) | Original stow-migration plan (2026-06-11) — historical/setup context, not a living guide. |
| `nvim/.config/nvim/README.md` + `instructions.md` | nvim's own docs, including the `claude-tmux` bridge. Already maintained separately — not duplicated here. |
| `scripts/.config/scripts/tmux/instructions.md` | Known stale (predates the notification work) — flagged as a gap in the findings doc, not yet refreshed. |

## Where new docs should land

`docs/` in this repo, always (never `logs/` — that's gitignored scratch, see
`.gitignore`). Add a row to this page (and a tile to `HUB.html`) when you add
a doc. See `roadmap.md` §6 for the plan to stop doing this by hand.
