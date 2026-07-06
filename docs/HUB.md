# Hub — central overview of dotfiles documentation

The index. When in doubt about which doc has what, start here. Manually
maintained — update on request, not automatically.

## Live docs

| Doc | What it's for | Status |
|---|---|---|
| [`dotfiles-overview.md`](dotfiles-overview.md) / [`.html`](dotfiles-overview.html) | Everything in this repo — what it is, why it exists, how to use it. The catch-all project overview. | WIP, manually maintained |
| [`agent-workbench-findings.html`](agent-workbench-findings.html) | Deep-dive audit of the tmux/Claude agent tooling specifically: inventory, the `@claude_blocked` signal contract, gaps, target flows, decisions. Source of truth for that effort. | Updated as of PR #7 |
| [`2026-07-06-way-forward.md`](2026-07-06-way-forward.md) / [`.html`](2026-07-06-way-forward.html) | The synthesized plan that grew out of the findings doc: readback, decisions, build order, later additions. The roadmap for the agent-workbench project. | Slices 1–3 done, 4–5 not started |

## Related, not in `docs/`

| Location | What it's for |
|---|---|
| `~/code/tasks/dotfiles--*.md` | The actual per-task build logs and backlogs — most detailed, most current record of any in-flight work. Central task store, its own git repo. |
| `logs/decisions/*.md` | Scratch decision records from decision-buffer sessions (gitignored — not tracked, cited by name from the docs above). |
| `readme.md` (repo root) | Original stow-migration plan (2026-06-11) — historical/setup context, not a living guide. |
| `nvim/.config/nvim/README.md` + `instructions.md` | nvim's own docs, including the `claude-tmux` bridge. Already maintained separately — not duplicated here. |
| `scripts/.config/scripts/tmux/instructions.md` | Known stale (predates the notification work) — flagged as a gap in the findings doc, not yet refreshed. |
| `~/code/notes-tui/notes-guide.html` | notes-tui's own committed usage guide (install/commands/global-flags/conventions/roadmap). Not linked from its own README — easy to miss. |

## Where new docs should land

`docs/` in this repo, always (never `logs/` — that's gitignored scratch, see
`.gitignore`). Add a row to this table when you add a doc.
