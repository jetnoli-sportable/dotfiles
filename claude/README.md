# claude — curated ~/.claude config (skills subset)

Version-controls the hand-authored, portable skills under `~/.claude/skills/`
so the docs INDEX can scan durable sources and a fresh machine reproduces them.

Stow with `--no-folding` (install.sh does this): `~/.claude/` holds live
untracked state, so individual files are symlinked into the existing real
directory instead of replacing it.

## Tracked

- `skills/decision-buffer/` — design decisions via nvim buffer docs
- `skills/park/` — capture "later" items to the ledger
- `skills/parked-items/` — weekly review of parked items
- `skills/pr-review-session/` — PR review worktree/tmux sessions

## Deliberately NOT tracked (this pass)

- `~/.claude/settings.json` — mixes machine-local state (enabled plugins,
  theme, permission allowlists) with portable config; needs its own
  curation + secret audit (see `~/code/tasks/dotfiles--stow-claude-config.md`).
- `~/.claude/parked-items/ledger.jsonl` — state, not config.
- `~/.claude/projects/`, `todos/`, caches, telemetry — machine state,
  never track.
